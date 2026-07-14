unit ActiveAppView.RenameJournal;

interface

uses
  System.IniFiles, System.SysUtils,
  Winapi.Windows,
  CancelToken;

type
  TRenameJournalConfig = record
    DatabaseFileName: string;
    Enabled: Boolean;
  end;

  TRenameJournalWriteResult = (rjwrDisabled, rjwrSaved, rjwrFailed);
  TRenameJournalEnqueueResult = (rjerDisabled, rjerQueued, rjerFull, rjerStopped);

  TRenameJournalDiagnostics = record
    Accepted: Int64;
    Dequeued: Int64;
    Dropped: Int64;
    Pending: Integer;
    Persisted: Int64;
  end;

  TRenameJournalWriter = class
  private
    fEnabled: Boolean;
    fStopped: Integer;
    fWorker: TObject;
  public
    constructor Create(const aConfig: TRenameJournalConfig; const aCancelToken: iCancelToken);
    destructor Destroy; override;
    function Enqueue(const aWnd: HWND; const aProcessId: Cardinal; const aRenamedAt: Int64;
      const aNewCaption: string): TRenameJournalEnqueueResult;
    function GetDiagnostics: TRenameJournalDiagnostics;
    procedure StopAndWait;
  end;

function TryRecordWindowRename(
  const aConfig: TRenameJournalConfig;
  const aWnd: HWND;
  const aProcessId: Cardinal;
  const aRenamedAt: Int64;
  const aNewCaption: string;
  out aErrorMessage: string
): TRenameJournalWriteResult;
function LoadRenameJournalConfig(const aIniFile: TCustomIniFile): TRenameJournalConfig;
function RenameJournalWorkerConstructionFailureIsSafeForSelfTest: Boolean;

implementation

uses
  System.Classes, System.Diagnostics, System.Generics.Collections, System.IOUtils, System.SyncObjs,
  AutoFree,
  FireDAC.Comp.Client, FireDAC.DApt, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.Async, FireDAC.Stan.Def,
  FireDAC.VCLUI.Wait;

const
  cRenameJournalBusyTimeoutMs = 250;
  cRenameJournalDrainTimeoutMs = 250;
  cRenameJournalQueueDepth = 64;
  cRenameJournalSettingsSection = 'save-renames-to-journal';

procedure ConfigureRenameJournalConnection(const aDatabaseFileName: string;
  const aConnection: TFDConnection); forward;

type
  TRenameJournalEvent = record
  strict private
    fHwnd: Int64;
    fNewCaption: string;
    fProcessId: Cardinal;
    fRenamedAt: Int64;
    fValid: Boolean;
  public
    constructor Create(const aWnd: HWND; const aProcessId: Cardinal; const aRenamedAt: Int64;
      const aNewCaption: string);
    property Hwnd: Int64 read fHwnd;
    property NewCaption: string read fNewCaption;
    property ProcessId: Cardinal read fProcessId;
    property RenamedAt: Int64 read fRenamedAt;
    property Valid: Boolean read fValid;
  end;

  TRenameJournalWorker = class(TThread)
  private
    fAccepted: Int64;
    fCancelToken: iCancelToken;
    fConfig: TRenameJournalConfig;
    fDequeued: Int64;
    fDropped: Int64;
    fExited: Integer;
    fOverflowCount: Integer;
    fPersisted: Int64;
    fQueue: TThreadedQueue<TRenameJournalEvent>;
    fStateLock: TCriticalSection;
    fStopping: Integer;
    fWorkerStarted: Integer;
    procedure DebugLogFailure(const aMessage: string);
    procedure FinishExecution;
    procedure FlushOverflowDiagnostics;
    procedure LogFailure(const aMessage: string);
    procedure ProcessEvents;
    procedure WriteEvent(const aConnection: TFDConnection; const aQuery: TFDQuery;
      const aEvent: TRenameJournalEvent);
  protected
    procedure Execute; override;
  public
    constructor Create(const aConfig: TRenameJournalConfig; const aCancelToken: iCancelToken;
      const aFailAfterThreadCreateForSelfTest: Boolean = False);
    destructor Destroy; override;
    function Enqueue(const aEvent: TRenameJournalEvent): TRenameJournalEnqueueResult;
    function GetDiagnostics: TRenameJournalDiagnostics;
    procedure StartWorker;
    procedure StopAndWait;
  end;

function TryRecordWindowRenameUsingConnection(const aConfig: TRenameJournalConfig;
  const aConnection: TFDConnection; const aQuery: TFDQuery; const aEvent: TRenameJournalEvent;
  out aErrorMessage: string): TRenameJournalWriteResult; forward;

constructor TRenameJournalEvent.Create(const aWnd: HWND; const aProcessId: Cardinal;
  const aRenamedAt: Int64; const aNewCaption: string);
begin
  fHwnd := Int64(NativeUInt(aWnd));
  fNewCaption := aNewCaption;
  fProcessId := aProcessId;
  fRenamedAt := aRenamedAt;
  fValid := True;
end;

constructor TRenameJournalWorker.Create(const aConfig: TRenameJournalConfig;
  const aCancelToken: iCancelToken; const aFailAfterThreadCreateForSelfTest: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  if aFailAfterThreadCreateForSelfTest then
    raise EThread.Create('Self-test worker construction failure');
  fCancelToken := aCancelToken;
  if not Assigned(fCancelToken) then
    fCancelToken := TCancelToken.Create;
  fConfig := aConfig;
  fStateLock := TCriticalSection.Create;
  fQueue := TThreadedQueue<TRenameJournalEvent>.Create(cRenameJournalQueueDepth, 0, INFINITE);
end;

destructor TRenameJournalWorker.Destroy;
begin
  if TInterlocked.CompareExchange(fWorkerStarted, 0, 0) <> 0 then
    StopAndWait;
  FreeAndNil(fQueue);
  FreeAndNil(fStateLock);
  fCancelToken := nil;
  inherited;
end;

procedure TRenameJournalWorker.FlushOverflowDiagnostics;
var
  lOverflowCount: Integer;
begin
  lOverflowCount := TInterlocked.Exchange(fOverflowCount, 0);
  if lOverflowCount > 0 then
    LogFailure(Format(
      'queue overflow; %d rename event(s) rejected',
      [lOverflowCount]));
end;

procedure TRenameJournalWorker.DebugLogFailure(const aMessage: string);
var
  lMessage: string;
begin
  lMessage := 'ActiveAppView RenameJournal: ' + aMessage;
  OutputDebugStringW(PWideChar(lMessage));
end;

procedure TRenameJournalWorker.FinishExecution;
begin
  if Assigned(fStateLock) then
  begin
    fStateLock.Acquire;
    try
      if Assigned(fQueue) and (fQueue.QueueSize > 0) then
        TInterlocked.Add(fDropped, fQueue.QueueSize);
      TInterlocked.Exchange(fExited, 1);
      if Assigned(fQueue) then
        fQueue.DoShutDown;
    finally
      fStateLock.Release;
    end;
  end else
    TInterlocked.Exchange(fExited, 1);
  FlushOverflowDiagnostics;
end;

procedure TRenameJournalWorker.ProcessEvents;
var
  g: TGarbos;
  lConnection: TFDConnection;
  lDrainStarted: Boolean;
  lDrainStopwatch: TStopwatch;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lEvent: TRenameJournalEvent;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  lDrainStarted := False;
  lDrainStopwatch := Default(TStopwatch);
  try
    GC(lConnection, TFDConnection.Create(nil), g);
    lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
    lDriverLink.DriverID := 'SQLite';
    GC(lQuery, TFDQuery.Create(nil), g);
    ConfigureRenameJournalConnection(fConfig.DatabaseFileName, lConnection);
    lQuery.Connection := lConnection;

    while True do
    begin
      if Assigned(fCancelToken) and fCancelToken.Canceled then
      begin
        if not lDrainStarted then
        begin
          lDrainStopwatch := TStopwatch.StartNew;
          lDrainStarted := True;
        end;
        if lDrainStopwatch.ElapsedMilliseconds >= cRenameJournalDrainTimeoutMs then
        begin
          LogFailure(Format(
            'shutdown drain deadline reached; %d accepted event(s) dropped',
            [fQueue.QueueSize]));
          Break;
        end;
      end;

      lEvent := Default(TRenameJournalEvent);
      fQueue.PopItem(lEvent);
      if not lEvent.Valid then
        Break;
      TInterlocked.Increment(fDequeued);
      WriteEvent(lConnection, lQuery, lEvent);
      FlushOverflowDiagnostics;
    end;
  finally
    g.Clear;
  end;
end;

procedure TRenameJournalWorker.Execute;
begin
  if Terminated then
    Exit;

  try
    try
      ProcessEvents;
    except
      on EOutOfMemory do
        raise;
      on EAccessViolation do
        raise;
      on lException: Exception do
        LogFailure(lException.ClassName + ': ' + lException.Message);
    end;
  finally
    FinishExecution;
  end;
end;

function TRenameJournalWorker.Enqueue(
  const aEvent: TRenameJournalEvent): TRenameJournalEnqueueResult;
begin
  fStateLock.Acquire;
  try
    if (TInterlocked.CompareExchange(fStopping, 0, 0) <> 0) or
      (TInterlocked.CompareExchange(fExited, 0, 0) <> 0) then
      Exit(rjerStopped);

    if fQueue.PushItem(aEvent) <> wrSignaled then
    begin
      TInterlocked.Increment(fOverflowCount);
      DebugLogFailure('queue overflow; rename event rejected');
      Exit(rjerFull);
    end;
    TInterlocked.Increment(fAccepted);
    Result := rjerQueued;
  finally
    fStateLock.Release;
  end;
end;

function TRenameJournalWorker.GetDiagnostics: TRenameJournalDiagnostics;
var
  lPending: Int64;
begin
  Result.Accepted := TInterlocked.CompareExchange(fAccepted, 0, 0);
  Result.Dequeued := TInterlocked.CompareExchange(fDequeued, 0, 0);
  Result.Dropped := TInterlocked.CompareExchange(fDropped, 0, 0);
  Result.Persisted := TInterlocked.CompareExchange(fPersisted, 0, 0);
  lPending := Result.Accepted - Result.Dropped - Result.Persisted;
  if lPending > High(Integer) then
    Result.Pending := High(Integer)
  else if lPending > 0 then
    Result.Pending := Integer(lPending)
  else
    Result.Pending := 0;
end;

procedure TRenameJournalWorker.LogFailure(const aMessage: string);
var
  lMessage: string;
begin
  lMessage := 'ActiveAppView RenameJournal: ' + aMessage;
  OutputDebugStringW(PWideChar(lMessage));
  try
    TFile.AppendAllText(
      ChangeFileExt(fConfig.DatabaseFileName, '.rename-journal.log'),
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now) + ' ' + lMessage + sLineBreak,
      TEncoding.UTF8);
  except
    on lException: Exception do
      DebugLogFailure('diagnostic log failed: ' + lException.ClassName + ': ' + lException.Message);
  end;
end;

procedure TRenameJournalWorker.StopAndWait;
begin
  fStateLock.Acquire;
  try
    if TInterlocked.Exchange(fStopping, 1) = 0 then
    begin
      if Assigned(fCancelToken) then
        fCancelToken.Cancel;
      fQueue.DoShutDown;
    end;
  finally
    fStateLock.Release;
  end;
  WaitFor;
end;

procedure TRenameJournalWorker.StartWorker;
begin
  Start;
  TInterlocked.Exchange(fWorkerStarted, 1);
end;

procedure TRenameJournalWorker.WriteEvent(const aConnection: TFDConnection;
  const aQuery: TFDQuery; const aEvent: TRenameJournalEvent);
var
  lErrorMessage: string;
begin
  if TryRecordWindowRenameUsingConnection(
    fConfig,
    aConnection,
    aQuery,
    aEvent,
    lErrorMessage) = rjwrSaved then
    TInterlocked.Increment(fPersisted)
  else
  begin
    if aConnection.InTransaction then
    begin
      try
        aConnection.Rollback;
      except
        on lException: Exception do
          LogFailure(
            'failed write rollback failed: ' + lException.ClassName + ': ' + lException.Message);
      end;
    end;
    if aConnection.Connected then
    begin
      try
        aConnection.Connected := False;
      except
        on lException: Exception do
          LogFailure(
            'failed write disconnect failed: ' + lException.ClassName + ': ' + lException.Message);
      end;
    end;
    LogFailure(lErrorMessage);
    TInterlocked.Increment(fDropped);
  end;
end;

function TryCreateRenameJournalWorker(const aConfig: TRenameJournalConfig;
  const aCancelToken: iCancelToken; const aFailAfterThreadCreateForSelfTest: Boolean;
  out aWorker: TObject): Boolean;
var
  lWorker: TRenameJournalWorker;
begin
  aWorker := nil;
  lWorker := nil;
  try
    lWorker := TRenameJournalWorker.Create(
      aConfig,
      aCancelToken,
      aFailAfterThreadCreateForSelfTest);
    lWorker.StartWorker;
    aWorker := lWorker;
    Result := True;
  except
    on lException: EThread do
    begin
      FreeAndNil(lWorker);
      OutputDebugStringW(PWideChar(
        'ActiveAppView RenameJournal: worker startup failed: ' + lException.Message));
      Result := False;
    end;
  end;
end;

constructor TRenameJournalWriter.Create(const aConfig: TRenameJournalConfig;
  const aCancelToken: iCancelToken);
begin
  inherited Create;
  fEnabled := aConfig.Enabled;
  if fEnabled and not TryCreateRenameJournalWorker(aConfig, aCancelToken, False, fWorker) then
    fEnabled := False;
end;

destructor TRenameJournalWriter.Destroy;
begin
  StopAndWait;
  FreeAndNil(fWorker);
  inherited;
end;

function TRenameJournalWriter.Enqueue(const aWnd: HWND; const aProcessId: Cardinal;
  const aRenamedAt: Int64; const aNewCaption: string): TRenameJournalEnqueueResult;
begin
  if not fEnabled then
    Exit(rjerDisabled);
  if (TInterlocked.CompareExchange(fStopped, 0, 0) <> 0) or (not Assigned(fWorker)) then
    Exit(rjerStopped);
  Result := TRenameJournalWorker(fWorker).Enqueue(
    TRenameJournalEvent.Create(aWnd, aProcessId, aRenamedAt, aNewCaption));
end;

procedure TRenameJournalWriter.StopAndWait;
begin
  TInterlocked.Exchange(fStopped, 1);
  if Assigned(fWorker) then
    TRenameJournalWorker(fWorker).StopAndWait;
end;

function TRenameJournalWriter.GetDiagnostics: TRenameJournalDiagnostics;
begin
  if Assigned(fWorker) then
    Result := TRenameJournalWorker(fWorker).GetDiagnostics
  else
    Result := Default(TRenameJournalDiagnostics);
end;

function RenameJournalWorkerConstructionFailureIsSafeForSelfTest: Boolean;
var
  lConfig: TRenameJournalConfig;
  lWorker: TObject;
begin
  lConfig := Default(TRenameJournalConfig);
  lConfig.Enabled := True;
  lConfig.DatabaseFileName := 'self-test.db';
  Result := not TryCreateRenameJournalWorker(lConfig, nil, True, lWorker) and
    (not Assigned(lWorker));
end;

function LoadRenameJournalConfig(const aIniFile: TCustomIniFile): TRenameJournalConfig;
begin
  Result.Enabled := aIniFile.ReadBool(cRenameJournalSettingsSection, 'enabled', False);
  Result.DatabaseFileName := Trim(aIniFile.ReadString(cRenameJournalSettingsSection, 'db-file', ''));
end;

procedure ConfigureRenameJournalConnection(
  const aDatabaseFileName: string;
  const aConnection: TFDConnection
);
begin
  aConnection.LoginPrompt := False;
  aConnection.ResourceOptions.SilentMode := True;
  aConnection.UpdateOptions.LockWait := True;
  aConnection.Params.Values['DriverID'] := 'SQLite';
  aConnection.Params.Values['Database'] := aDatabaseFileName;
  aConnection.Params.Values['OpenMode'] := 'ReadWrite';
  aConnection.Params.Values['LockingMode'] := 'Normal';
  aConnection.Params.Values['Synchronous'] := 'Normal';
  aConnection.Params.Values['JournalMode'] := 'WAL';
  aConnection.Params.Values['SharedCache'] := 'False';
  aConnection.Params.Values['BusyTimeout'] := IntToStr(cRenameJournalBusyTimeoutMs);
end;

function TryRecordWindowRenameUsingConnection(const aConfig: TRenameJournalConfig;
  const aConnection: TFDConnection; const aQuery: TFDQuery; const aEvent: TRenameJournalEvent;
  out aErrorMessage: string): TRenameJournalWriteResult;
begin
  aErrorMessage := '';
  if not aConfig.Enabled then
    Exit(rjwrDisabled);

  try
    if not TFile.Exists(aConfig.DatabaseFileName) then
    begin
      aErrorMessage := 'Shadow Journal database does not exist: ' + aConfig.DatabaseFileName;
      Exit(rjwrFailed);
    end;

    if not aConnection.Connected then
      aConnection.Connected := True;
    aQuery.SQL.Text :=
      'INSERT INTO window_rename_events (renamed_at, hwnd, pid, new_caption) ' +
      'VALUES (:renamed_at, :hwnd, :pid, :new_caption);';
    aQuery.ParamByName('renamed_at').AsLargeInt := aEvent.RenamedAt;
    aQuery.ParamByName('hwnd').AsLargeInt := aEvent.Hwnd;
    aQuery.ParamByName('pid').AsLargeInt := aEvent.ProcessId;
    aQuery.ParamByName('new_caption').AsWideString := aEvent.NewCaption;
    aQuery.ExecSQL;
    Result := rjwrSaved;
  except
    on lException: Exception do
    begin
      aErrorMessage := lException.ClassName + ': ' + lException.Message;
      Result := rjwrFailed;
    end;
  end;
end;

function TryRecordWindowRename(
  const aConfig: TRenameJournalConfig;
  const aWnd: HWND;
  const aProcessId: Cardinal;
  const aRenamedAt: Int64;
  const aNewCaption: string;
  out aErrorMessage: string
): TRenameJournalWriteResult;
var
  g: TGarbos;
  lConnection: TFDConnection;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  aErrorMessage := '';
  if not aConfig.Enabled then
    Exit(rjwrDisabled);

  GC(lConnection, TFDConnection.Create(nil), g);
  lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
  lDriverLink.DriverID := 'SQLite';
  GC(lQuery, TFDQuery.Create(nil), g);
  ConfigureRenameJournalConnection(aConfig.DatabaseFileName, lConnection);
  lQuery.Connection := lConnection;
  Result := TryRecordWindowRenameUsingConnection(
    aConfig,
    lConnection,
    lQuery,
    TRenameJournalEvent.Create(aWnd, aProcessId, aRenamedAt, aNewCaption),
    aErrorMessage);
end;

end.

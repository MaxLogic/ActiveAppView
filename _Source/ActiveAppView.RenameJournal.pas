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
    fCancelToken: iCancelToken;
    fConfig: TRenameJournalConfig;
    fExited: Integer;
    fQueue: TThreadedQueue<TRenameJournalEvent>;
    fStopping: Integer;
    procedure LogFailure(const aMessage: string);
    procedure WriteEvent(const aConnection: TFDConnection; const aQuery: TFDQuery;
      const aEvent: TRenameJournalEvent);
  protected
    procedure Execute; override;
  public
    constructor Create(const aConfig: TRenameJournalConfig; const aCancelToken: iCancelToken);
    destructor Destroy; override;
    function Enqueue(const aEvent: TRenameJournalEvent): TRenameJournalEnqueueResult;
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
  const aCancelToken: iCancelToken);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  fCancelToken := aCancelToken;
  if not Assigned(fCancelToken) then
    fCancelToken := TCancelToken.Create;
  fConfig := aConfig;
  fQueue := TThreadedQueue<TRenameJournalEvent>.Create(cRenameJournalQueueDepth, 0, INFINITE);
end;

destructor TRenameJournalWorker.Destroy;
begin
  StopAndWait;
  FreeAndNil(fQueue);
  fCancelToken := nil;
  inherited;
end;

procedure TRenameJournalWorker.Execute;
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
          Break;
      end;

      lEvent := Default(TRenameJournalEvent);
      fQueue.PopItem(lEvent);
      if not lEvent.Valid then
        Break;
      WriteEvent(lConnection, lQuery, lEvent);
    end;
  except
    on lException: Exception do
      LogFailure(lException.ClassName + ': ' + lException.Message);
  end;
  g.Clear;
  TInterlocked.Exchange(fExited, 1);
end;

function TRenameJournalWorker.Enqueue(
  const aEvent: TRenameJournalEvent): TRenameJournalEnqueueResult;
begin
  if (TInterlocked.CompareExchange(fStopping, 0, 0) <> 0) or
    (TInterlocked.CompareExchange(fExited, 0, 0) <> 0) then
    Exit(rjerStopped);

  if fQueue.PushItem(aEvent) = wrTimeout then
  begin
    LogFailure('queue overflow; rename event dropped');
    Exit(rjerFull);
  end;
  Result := rjerQueued;
end;

procedure TRenameJournalWorker.LogFailure(const aMessage: string);
var
  lMessage: string;
begin
  lMessage := 'ActiveAppView RenameJournal: ' + aMessage;
  OutputDebugStringW(PWideChar(lMessage));
end;

procedure TRenameJournalWorker.StopAndWait;
begin
  if TInterlocked.Exchange(fStopping, 1) = 0 then
  begin
    if Assigned(fCancelToken) then
      fCancelToken.Cancel;
    fQueue.DoShutDown;
  end;
  WaitFor;
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
    lErrorMessage) <> rjwrSaved then
    LogFailure(lErrorMessage);
end;

constructor TRenameJournalWriter.Create(const aConfig: TRenameJournalConfig;
  const aCancelToken: iCancelToken);
begin
  inherited Create;
  fEnabled := aConfig.Enabled;
  if fEnabled then
    fWorker := TRenameJournalWorker.Create(aConfig, aCancelToken);
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
  if TInterlocked.Exchange(fStopped, 1) = 0 then
  begin
    if Assigned(fWorker) then
      TRenameJournalWorker(fWorker).StopAndWait;
  end;
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

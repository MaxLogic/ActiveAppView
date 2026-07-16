unit ActiveAppView.RenameJournal;

interface

uses
  System.IniFiles, System.SysUtils,
  Winapi.Windows,
  CancelToken,
  ActiveAppView.CaptionOverrideState;

type
  TRenameJournalConfig = record
    DatabaseFileName: string;
    Enabled: Boolean;
    OverrideStateFileName: string;
  end;

  TRenameJournalWriteResult = (rjwrDisabled, rjwrSaved, rjwrFailed);
  TRenameJournalEnqueueResult = (rjerDisabled, rjerQueued, rjerFull, rjerStopped);

  TRenameJournalDiagnostics = record
    Accepted: Int64;
    Dequeued: Int64;
    Dropped: Int64;
    Pending: Integer;
    Persisted: Int64;
    ActiveWorkerCount: Integer;
    LastStatePersistThreadId: Cardinal;
    LastStateSubmitThreadId: Cardinal;
    StateSnapshotsCoalesced: Int64;
    StateSnapshotsPersisted: Int64;
    StateSnapshotsSubmitted: Int64;
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
    function SubmitOverrideState(const aState: TCaptionOverrideState): Boolean;
    procedure StopAndWait;
    function TryTakeLoadedOverrideState(out aState: TCaptionOverrideState;
      out aStatus: TCaptionOverrideStateLoadStatus): Boolean;
    function WaitForOverrideStatePersistence(const aTimeoutMilliseconds: Cardinal): Boolean;
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
  MaxLogic.Windows.Identity,
  AutoFree,
  FireDAC.Comp.Client, FireDAC.DApt, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.Async, FireDAC.Stan.Def,
  FireDAC.VCLUI.Wait;

const
  cRenameJournalBusyTimeoutMs = 250;
  cRenameJournalDrainTimeoutMs = 2000;
  cRenameJournalPollTimeoutMs = 20;
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
    fActiveWorkerCount: Integer;
    fLastStatePersistThreadId: Int64;
    fLastStateSubmitThreadId: Int64;
    fLoadedState: TCaptionOverrideState;
    fLoadedStateReady: Boolean;
    fLoadedStateStatus: TCaptionOverrideStateLoadStatus;
    fPendingState: TCaptionOverrideState;
    fPendingStateSequence: Int64;
    fPersistedOverrideState: TCaptionOverrideState;
    fQueue: TThreadedQueue<TRenameJournalEvent>;
    fStatePersistedEvent: TEvent;
    fStateLock: TCriticalSection;
    fStateSnapshotsCoalesced: Int64;
    fStateSnapshotsPersisted: Int64;
    fStateSnapshotsSubmitted: Int64;
    fPersistedStateSequence: Int64;
    fStopping: Integer;
    fWorkerStarted: Integer;
    procedure DebugLogFailure(const aMessage: string);
    procedure CreateJournalDependencies(var aGarbos: TGarbos;
      out aConnection: TFDConnection; out aQuery: TFDQuery);
    procedure FinishExecution;
    procedure FlushOverflowDiagnostics;
    procedure LogFailure(const aMessage: string);
    procedure EnrichOverrideState(var aState: TCaptionOverrideState);
    function FindPersistedIdentity(const aState: TCaptionOverrideState;
      const aRecord: TCaptionOverrideRecord): TCaptionOverrideIdentity;
    function HasPendingOverrideState: Boolean;
    procedure LoadInitialOverrideState(const aBootIdentity: TWindowsBootIdentity;
      const aHasBootIdentity: Boolean);
    procedure PersistLatestOverrideState;
    function ProcessNextQueueItem(const aConnection: TFDConnection;
      const aQuery: TFDQuery): Boolean;
    procedure ProcessEvents;
    function ResolveProcessIdentity(const aWnd: HWND;
      const aProcessId: Cardinal): TCaptionOverrideResolvedProcess;
    function ShouldStopForCancellation(var aDrainStarted: Boolean;
      var aDrainStopwatch: TStopwatch): Boolean;
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
    function SubmitOverrideState(const aState: TCaptionOverrideState): Boolean;
    procedure StartWorker;
    procedure StopAndWait;
    function TryTakeLoadedOverrideState(out aState: TCaptionOverrideState;
      out aStatus: TCaptionOverrideStateLoadStatus): Boolean;
    function WaitForOverrideStatePersistence(const aTimeoutMilliseconds: Cardinal): Boolean;
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

procedure TRenameJournalWorker.CreateJournalDependencies(var aGarbos: TGarbos;
  out aConnection: TFDConnection; out aQuery: TFDQuery);
var
  lDriverLink: TFDPhysSQLiteDriverLink;
begin
  aConnection := nil;
  aQuery := nil;
  if not fConfig.Enabled then
    Exit;
  GC(aConnection, TFDConnection.Create(nil), aGarbos);
  lDriverLink := TFDPhysSQLiteDriverLink.Create(aConnection);
  lDriverLink.DriverID := 'SQLite';
  GC(aQuery, TFDQuery.Create(nil), aGarbos);
  ConfigureRenameJournalConnection(fConfig.DatabaseFileName, aConnection);
  aQuery.Connection := aConnection;
end;

procedure TRenameJournalWorker.EnrichOverrideState(var aState: TCaptionOverrideState);
var
  i: Integer;
  lBootIdentity: TWindowsBootIdentity;
  lKnownIdentity: TCaptionOverrideIdentity;
  lKnownState: TCaptionOverrideState;
  lResolved: TCaptionOverrideResolvedProcess;
begin
  fStateLock.Acquire;
  try
    lKnownState := Copy(fPersistedOverrideState);
  finally
    fStateLock.Release;
  end;
  for i := 0 to High(aState) do
  begin
    if (not aState[i].Identity.HasBootId) and
      TryGetCachedWindowsBootIdentity(lBootIdentity) then
    begin
      aState[i].Identity.HasBootId := True;
      aState[i].Identity.BootId := lBootIdentity.UtcMilliseconds;
    end;
    if not aState[i].Identity.HasProcessStartedAt then
    begin
      lResolved := ResolveProcessIdentity(
        HWND(NativeUInt(aState[i].Identity.Hwnd)),
        aState[i].Identity.ProcessId);
      if lResolved.Current and lResolved.HasProcessStartedAt then
      begin
        aState[i].Identity.HasProcessStartedAt := True;
        aState[i].Identity.ProcessStartedAt := lResolved.ProcessStartedAt;
      end else
      begin
        lKnownIdentity := FindPersistedIdentity(lKnownState, aState[i]);
        if lKnownIdentity.ProcessId = 0 then
          Continue;
        if not aState[i].Identity.HasBootId then
        begin
          aState[i].Identity.HasBootId := lKnownIdentity.HasBootId;
          aState[i].Identity.BootId := lKnownIdentity.BootId;
        end;
        aState[i].Identity.HasProcessStartedAt := lKnownIdentity.HasProcessStartedAt;
        aState[i].Identity.ProcessStartedAt := lKnownIdentity.ProcessStartedAt;
      end;
    end;
  end;
end;

function TRenameJournalWorker.FindPersistedIdentity(
  const aState: TCaptionOverrideState;
  const aRecord: TCaptionOverrideRecord): TCaptionOverrideIdentity;
var
  lRecord: TCaptionOverrideRecord;
begin
  Result := Default(TCaptionOverrideIdentity);
  for lRecord in aState do
    if (lRecord.Identity.Hwnd = aRecord.Identity.Hwnd) and
      (lRecord.Identity.ProcessId = aRecord.Identity.ProcessId) then
    begin
      Exit(lRecord.Identity);
    end;
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
  fStatePersistedEvent := TEvent.Create(nil, True, False, '');
  fQueue := TThreadedQueue<TRenameJournalEvent>.Create(
    cRenameJournalQueueDepth,
    0,
    cRenameJournalPollTimeoutMs);
end;

destructor TRenameJournalWorker.Destroy;
begin
  if TInterlocked.CompareExchange(fWorkerStarted, 0, 0) <> 0 then
    StopAndWait;
  FreeAndNil(fQueue);
  FreeAndNil(fStatePersistedEvent);
  FreeAndNil(fStateLock);
  fCancelToken := nil;
  inherited;
end;

function TRenameJournalWorker.HasPendingOverrideState: Boolean;
begin
  fStateLock.Acquire;
  try
    Result := fPendingStateSequence > fPersistedStateSequence;
  finally
    fStateLock.Release;
  end;
end;

procedure TRenameJournalWorker.LoadInitialOverrideState(
  const aBootIdentity: TWindowsBootIdentity; const aHasBootIdentity: Boolean);
var
  lErrorMessage: string;
  lState: TCaptionOverrideState;
  lStatus: TCaptionOverrideStateLoadStatus;
begin
  if fConfig.OverrideStateFileName = '' then
    Exit;
  if not TryLoadCaptionOverrideState(
    fConfig.OverrideStateFileName,
    aBootIdentity.UtcMilliseconds,
    aHasBootIdentity,
    ResolveProcessIdentity,
    lState,
    lStatus,
    lErrorMessage) then
    LogFailure('caption override state load failed: ' + lErrorMessage);
  fStateLock.Acquire;
  try
    fLoadedState := Copy(lState);
    fPersistedOverrideState := Copy(lState);
    fLoadedStateStatus := lStatus;
    fLoadedStateReady := True;
  finally
    fStateLock.Release;
  end;
end;

procedure TRenameJournalWorker.PersistLatestOverrideState;
var
  lErrorMessage: string;
  lSequence: Int64;
  lState: TCaptionOverrideState;
begin
  if fConfig.OverrideStateFileName = '' then
    Exit;

  fStateLock.Acquire;
  try
    if fPendingStateSequence <= fPersistedStateSequence then
      Exit;
    lSequence := fPendingStateSequence;
    lState := Copy(fPendingState);
  finally
    fStateLock.Release;
  end;

  EnrichOverrideState(lState);
  TInterlocked.Exchange(fLastStatePersistThreadId, Int64(GetCurrentThreadId));
  if TrySaveCaptionOverrideStateAtomic(fConfig.OverrideStateFileName, lState, lErrorMessage) then
  begin
    TInterlocked.Increment(fStateSnapshotsPersisted);
    fStateLock.Acquire;
    try
      if lSequence > fPersistedStateSequence then
        fPersistedStateSequence := lSequence;
      fPersistedOverrideState := Copy(lState);
      if fPendingStateSequence = lSequence then
        fPendingState := nil;
      fStatePersistedEvent.SetEvent;
    finally
      fStateLock.Release;
    end;
  end else
  begin
    LogFailure('caption override state save failed: ' + lErrorMessage);
    fStateLock.Acquire;
    try
      if lSequence > fPersistedStateSequence then
        fPersistedStateSequence := lSequence;
      fStatePersistedEvent.SetEvent;
    finally
      fStateLock.Release;
    end;
  end;
end;

function TRenameJournalWorker.ProcessNextQueueItem(
  const aConnection: TFDConnection; const aQuery: TFDQuery): Boolean;
var
  lEvent: TRenameJournalEvent;
  lWaitResult: TWaitResult;
begin
  Result := True;
  lEvent := Default(TRenameJournalEvent);
  lWaitResult := fQueue.PopItem(lEvent);
  if lWaitResult = wrSignaled then
  begin
    if not lEvent.Valid then
      Exit;
    TInterlocked.Increment(fDequeued);
    if fConfig.Enabled then
      WriteEvent(aConnection, aQuery, lEvent)
    else
      TInterlocked.Increment(fDropped);
  end else if (lWaitResult = wrAbandoned) and
    (TInterlocked.CompareExchange(fStopping, 0, 0) <> 0) and
    (not HasPendingOverrideState) then
    Result := False;
end;

function TRenameJournalWorker.ResolveProcessIdentity(const aWnd: HWND;
  const aProcessId: Cardinal): TCaptionOverrideResolvedProcess;
var
  lProcessStartedAt: Int64;
  lWindowProcessId: Cardinal;
begin
  Result := Default(TCaptionOverrideResolvedProcess);
  Result.Current := (aWnd <> 0) and (aProcessId <> 0) and IsWindow(aWnd);
  if not Result.Current then
    Exit;
  GetWindowThreadProcessId(aWnd, lWindowProcessId);
  Result.Current := lWindowProcessId = aProcessId;
  if not Result.Current then
    Exit;
  Result.HasProcessStartedAt := TryGetProcessStartedAtUtcMilliseconds(aProcessId, lProcessStartedAt);
  if Result.HasProcessStartedAt then
    Result.ProcessStartedAt := lProcessStartedAt;
end;

function TRenameJournalWorker.ShouldStopForCancellation(
  var aDrainStarted: Boolean; var aDrainStopwatch: TStopwatch): Boolean;
begin
  Result := False;
  if (not Assigned(fCancelToken)) or (not fCancelToken.Canceled) then
    Exit;
  if not aDrainStarted then
  begin
    aDrainStopwatch := TStopwatch.StartNew;
    aDrainStarted := True;
  end;
  if (fQueue.QueueSize = 0) and (not HasPendingOverrideState) then
    Exit(True);
  Result := aDrainStopwatch.ElapsedMilliseconds >= cRenameJournalDrainTimeoutMs;
  if Result then
    LogFailure(Format(
      'shutdown drain deadline reached; %d accepted event(s) dropped',
      [fQueue.QueueSize]));
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
  lBootIdentity: TWindowsBootIdentity;
  lConnection: TFDConnection;
  lDrainStarted: Boolean;
  lDrainStopwatch: TStopwatch;
  lHasBootIdentity: Boolean;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  lDrainStarted := False;
  lDrainStopwatch := Default(TStopwatch);
  try
    lHasBootIdentity := TryGetWindowsBootIdentity(1000, False, lBootIdentity);
    LoadInitialOverrideState(lBootIdentity, lHasBootIdentity);
    CreateJournalDependencies(g, lConnection, lQuery);

    while True do
    begin
      PersistLatestOverrideState;
      if ShouldStopForCancellation(lDrainStarted, lDrainStopwatch) or
        (not ProcessNextQueueItem(lConnection, lQuery)) then
        Break;
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

  TInterlocked.Increment(fActiveWorkerCount);
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
    TInterlocked.Decrement(fActiveWorkerCount);
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
  Result.ActiveWorkerCount := TInterlocked.CompareExchange(fActiveWorkerCount, 0, 0);
  Result.LastStatePersistThreadId := Cardinal(
    TInterlocked.CompareExchange(fLastStatePersistThreadId, 0, 0));
  Result.LastStateSubmitThreadId := Cardinal(
    TInterlocked.CompareExchange(fLastStateSubmitThreadId, 0, 0));
  Result.StateSnapshotsCoalesced := TInterlocked.CompareExchange(fStateSnapshotsCoalesced, 0, 0);
  Result.StateSnapshotsPersisted := TInterlocked.CompareExchange(fStateSnapshotsPersisted, 0, 0);
  Result.StateSnapshotsSubmitted := TInterlocked.CompareExchange(fStateSnapshotsSubmitted, 0, 0);
  lPending := Result.Accepted - Result.Dropped - Result.Persisted;
  if lPending > High(Integer) then
    Result.Pending := High(Integer)
  else if lPending > 0 then
    Result.Pending := Integer(lPending)
  else
    Result.Pending := 0;
end;

function TRenameJournalWorker.SubmitOverrideState(
  const aState: TCaptionOverrideState): Boolean;
begin
  fStateLock.Acquire;
  try
    if (fConfig.OverrideStateFileName = '') or
      (TInterlocked.CompareExchange(fStopping, 0, 0) <> 0) or
      (TInterlocked.CompareExchange(fExited, 0, 0) <> 0) then
      Exit(False);
    if fPendingStateSequence > fPersistedStateSequence then
      TInterlocked.Increment(fStateSnapshotsCoalesced);
    fPendingState := Copy(aState);
    fPendingStateSequence := TInterlocked.Increment(fStateSnapshotsSubmitted);
    TInterlocked.Exchange(fLastStateSubmitThreadId, Int64(GetCurrentThreadId));
    fStatePersistedEvent.ResetEvent;
    Result := True;
  finally
    fStateLock.Release;
  end;
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

function TRenameJournalWorker.TryTakeLoadedOverrideState(
  out aState: TCaptionOverrideState;
  out aStatus: TCaptionOverrideStateLoadStatus): Boolean;
begin
  aState := nil;
  aStatus := coslsMissing;
  fStateLock.Acquire;
  try
    Result := fLoadedStateReady;
    if not Result then
      Exit;
    aState := Copy(fLoadedState);
    aStatus := fLoadedStateStatus;
    fLoadedState := nil;
    fLoadedStateReady := False;
  finally
    fStateLock.Release;
  end;
end;

procedure TRenameJournalWorker.StartWorker;
begin
  Start;
  TInterlocked.Exchange(fWorkerStarted, 1);
end;

function TRenameJournalWorker.WaitForOverrideStatePersistence(
  const aTimeoutMilliseconds: Cardinal): Boolean;
var
  lStopwatch: TStopwatch;
  lTargetSequence: Int64;
begin
  fStateLock.Acquire;
  try
    lTargetSequence := fPendingStateSequence;
    Result := fPersistedStateSequence >= lTargetSequence;
  finally
    fStateLock.Release;
  end;
  if Result then
    Exit;

  lStopwatch := TStopwatch.StartNew;
  repeat
    fStatePersistedEvent.WaitFor(cRenameJournalPollTimeoutMs);
    fStateLock.Acquire;
    try
      Result := fPersistedStateSequence >= lTargetSequence;
    finally
      fStateLock.Release;
    end;
    if Result then
      Exit;
  until lStopwatch.ElapsedMilliseconds >= aTimeoutMilliseconds;
  Result := False;
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
  if (fEnabled or (aConfig.OverrideStateFileName <> '')) and
    (not TryCreateRenameJournalWorker(aConfig, aCancelToken, False, fWorker)) then
  begin
    fEnabled := False;
  end;
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

function TRenameJournalWriter.SubmitOverrideState(
  const aState: TCaptionOverrideState): Boolean;
begin
  Result := (TInterlocked.CompareExchange(fStopped, 0, 0) = 0) and Assigned(fWorker) and
    TRenameJournalWorker(fWorker).SubmitOverrideState(aState);
end;

function TRenameJournalWriter.WaitForOverrideStatePersistence(
  const aTimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := Assigned(fWorker) and
    TRenameJournalWorker(fWorker).WaitForOverrideStatePersistence(aTimeoutMilliseconds);
end;

function TRenameJournalWriter.TryTakeLoadedOverrideState(
  out aState: TCaptionOverrideState;
  out aStatus: TCaptionOverrideStateLoadStatus): Boolean;
begin
  aState := nil;
  aStatus := coslsMissing;
  Result := Assigned(fWorker) and
    TRenameJournalWorker(fWorker).TryTakeLoadedOverrideState(aState, aStatus);
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

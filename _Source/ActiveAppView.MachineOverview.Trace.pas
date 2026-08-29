unit ActiveAppView.MachineOverview.Trace;

interface

uses
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewTraceConfig = record
    Enabled: Boolean;
    CaptureDurationMs: Cardinal;
    CommandTimeoutMs: Cardinal;
    MaximumOutputBytes: Cardinal;
    MaximumTraceCount: Integer;
    MaximumTraceBytes: UInt64;
    OutputDirectory: string;
    WprFileName: string;
    class function Defaults: TMachineOverviewTraceConfig; static;
  end;

  TMachineOverviewTraceCommand = record
    CancelArguments: string;
    FallbackStartArguments: string;
    InstanceName: string;
    StartArguments: string;
    StopArguments: string;
    TraceFileName: string;
  end;

  TMachineOverviewTraceDiagnostics = record
    ActiveWorkerCount: Integer;
    Requested: Int64;
    Captured: Int64;
    Failed: Int64;
    Unavailable: Int64;
    LastCaptureDurationMs: UInt64;
    LastTraceFileName: string;
    LastError: string;
  end;

  TMachineOverviewTraceService = class
  private
    fState: TObject;
  public
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aConfig: TMachineOverviewTraceConfig);
    destructor Destroy; override;
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function WaitUntilRunning(const aTimeoutMs: Cardinal): Boolean;
    function Diagnostics: TMachineOverviewTraceDiagnostics;
  end;

function ShouldCaptureMachineOverviewTrace(
  const aIncident: TMachineOverviewIncident): Boolean;
function BuildMachineOverviewTraceCommand(
  const aConfig: TMachineOverviewTraceConfig;
  const aIncident: TMachineOverviewIncident; const aProcessId: Cardinal):
  TMachineOverviewTraceCommand;
function SanitizeMachineOverviewTraceDiagnostic(const aValue: string): string;
function EnforceMachineOverviewTraceRetention(
  const aConfig: TMachineOverviewTraceConfig;
  out aRemovedCount: Integer; out aErrorText: string): Boolean;

implementation

uses
  System.Character, System.Classes, System.DateUtils, System.IOUtils,
  System.StrUtils, System.SyncObjs, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.MachineOverview.BoundedProcess;

const
  cMachineOverviewTraceCaptureDurationMs = 15000;
  cMachineOverviewTraceCommandTimeoutMs = 5000;
  cMachineOverviewTraceMaximumCount = 10;
  cMachineOverviewTraceMaximumOutputBytes = 64 * 1024;
  cMachineOverviewTraceMaximumBytes = UInt64(2) * 1024 * 1024 * 1024;
  cMachineOverviewTraceNameMaximumLength = 64;
  cMachineOverviewTraceDiagnosticMaximumLength = 512;

type
  TMachineOverviewTraceFileInfo = record
    Deleted: Boolean;
    FileName: string;
    LastWriteTimeUtc: TDateTime;
    Size: UInt64;
  end;

  TMachineOverviewTraceServiceState = class;

  TMachineOverviewTraceThread = class(TThread)
  private
    fServiceState: TMachineOverviewTraceServiceState;
    procedure CaptureTrace(
      const aChange: TMachineOverviewIncidentChange);
    procedure PublishOutcome(var aChange: TMachineOverviewIncidentChange;
      const aStatus: TMachineOverviewIncidentTraceStatus;
      const aDurationMs: UInt64; const aTraceFileName,
      aErrorText: string);
  protected
    procedure Execute; override;
  public
    constructor Create(
      const aServiceState: TMachineOverviewTraceServiceState);
  end;

  TMachineOverviewTraceServiceState = class
  public
    ActiveWorkerCount: Integer;
    Captured: Int64;
    Config: TMachineOverviewTraceConfig;
    DiagnosticsLock: TCriticalSection;
    Failed: Int64;
    LastCaptureDurationMs: UInt64;
    LastError: string;
    LastTraceFileName: string;
    LifecycleLock: TCriticalSection;
    Pipeline: TMachineOverviewPipeline;
    Requested: Int64;
    StartedEvent: TEvent;
    StopEvent: TEvent;
    Unavailable: Int64;
    Worker: TThread;
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aConfig: TMachineOverviewTraceConfig);
    destructor Destroy; override;
    procedure RecordOutcome(
      const aStatus: TMachineOverviewIncidentTraceStatus;
      const aDurationMs: UInt64; const aTraceFileName,
      aErrorText: string);
  end;

function GetTraceServiceState(const aState: TObject):
  TMachineOverviewTraceServiceState;
begin
  Result := aState as TMachineOverviewTraceServiceState;
end;

constructor TMachineOverviewTraceServiceState.Create(
  const aPipeline: TMachineOverviewPipeline;
  const aConfig: TMachineOverviewTraceConfig);
begin
  inherited Create;
  if not Assigned(aPipeline) then
    raise EArgumentNilException.Create('Machine Overview trace pipeline is required');
  if aConfig.Enabled and
    ((aConfig.CaptureDurationMs = 0) or
     (aConfig.CaptureDurationMs > 30000) or
     (aConfig.CommandTimeoutMs = 0) or
     (aConfig.MaximumOutputBytes = 0) or
     (aConfig.MaximumTraceCount <= 0) or
     (aConfig.MaximumTraceBytes = 0)) then
    raise EArgumentException.Create('Invalid Machine Overview trace configuration');
  Config := aConfig;
  Pipeline := aPipeline;
  DiagnosticsLock := TCriticalSection.Create;
  try
    LifecycleLock := TCriticalSection.Create;
    try
      StartedEvent := TEvent.Create(nil, True, False, '');
      try
        StopEvent := TEvent.Create(nil, True, False, '');
      except
        FreeAndNil(StartedEvent);
        raise;
      end;
    except
      FreeAndNil(LifecycleLock);
      raise;
    end;
  except
    FreeAndNil(DiagnosticsLock);
    raise;
  end;
end;

destructor TMachineOverviewTraceServiceState.Destroy;
begin
  FreeAndNil(StopEvent);
  FreeAndNil(StartedEvent);
  FreeAndNil(LifecycleLock);
  FreeAndNil(DiagnosticsLock);
  inherited Destroy;
end;

procedure TMachineOverviewTraceServiceState.RecordOutcome(
  const aStatus: TMachineOverviewIncidentTraceStatus;
  const aDurationMs: UInt64; const aTraceFileName,
  aErrorText: string);
begin
  case aStatus of
    TMachineOverviewIncidentTraceStatus.Captured:
      TInterlocked.Increment(Captured);
    TMachineOverviewIncidentTraceStatus.Failed:
      TInterlocked.Increment(Failed);
    TMachineOverviewIncidentTraceStatus.Unavailable:
      TInterlocked.Increment(Unavailable);
  else
    Exit;
  end;
  DiagnosticsLock.Acquire;
  try
    LastCaptureDurationMs := aDurationMs;
    LastTraceFileName := aTraceFileName;
    LastError := SanitizeMachineOverviewTraceDiagnostic(aErrorText);
  finally
    DiagnosticsLock.Release;
  end;
end;

function ProcessFailureText(
  const aResult: TMachineOverviewProcessResult): string;
begin
  Result := Trim(aResult.ErrorText);
  if not Trim(aResult.OutputText).IsEmpty then
  begin
    if not Result.IsEmpty then
      Result := Result + ': ';
    Result := Result + Trim(aResult.OutputText);
  end;
  if Result.IsEmpty then
    Result := Format('WPR exited with code %d', [aResult.ExitCode]);
  Result := SanitizeMachineOverviewTraceDiagnostic(Result);
end;

function TraceFailureIsUnavailable(const aValue: string): Boolean;
begin
  Result := ContainsText(aValue, 'access is denied') or
    ContainsText(aValue, 'administrator') or
    ContainsText(aValue, 'elevation') or
    ContainsText(aValue, 'privilege') or
    ContainsText(aValue, 'profile system performance') or
    ContainsText(aValue, '0xc5585011');
end;

constructor TMachineOverviewTraceThread.Create(
  const aServiceState: TMachineOverviewTraceServiceState);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fServiceState := aServiceState;
end;

procedure TMachineOverviewTraceThread.PublishOutcome(
  var aChange: TMachineOverviewIncidentChange;
  const aStatus: TMachineOverviewIncidentTraceStatus;
  const aDurationMs: UInt64; const aTraceFileName,
  aErrorText: string);
begin
  aChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  aChange.Incident.TraceStatus := aStatus;
  fServiceState.Pipeline.PublishDetailedTraceResult(aChange);
  fServiceState.RecordOutcome(aStatus, aDurationMs, aTraceFileName,
    aErrorText);
end;

procedure TMachineOverviewTraceThread.CaptureTrace(
  const aChange: TMachineOverviewIncidentChange);
var
  lCancelResult: TMachineOverviewProcessResult;
  lChange: TMachineOverviewIncidentChange;
  lCommand: TMachineOverviewTraceCommand;
  lDurationMs: UInt64;
  lErrorText: string;
  lRemovedCount: Integer;
  lResult: TMachineOverviewProcessResult;
  lStartedAtMs: UInt64;
  lStatus: TMachineOverviewIncidentTraceStatus;
  lTraceFileName: string;
begin
  lChange := aChange;
  TInterlocked.Increment(fServiceState.Requested);
  lStartedAtMs := GetTickCount64;
  lStatus := TMachineOverviewIncidentTraceStatus.Failed;
  lTraceFileName := '';
  lErrorText := '';
  try
    try
    if not TFile.Exists(fServiceState.Config.WprFileName) then
    begin
      lStatus := TMachineOverviewIncidentTraceStatus.Unavailable;
      lErrorText := 'Windows Performance Recorder is unavailable: ' +
        fServiceState.Config.WprFileName;
      Exit;
    end;
    if not EnforceMachineOverviewTraceRetention(fServiceState.Config,
        lRemovedCount, lErrorText) then
      Exit;
    lCommand := BuildMachineOverviewTraceCommand(fServiceState.Config,
      lChange.Incident, GetCurrentProcessId);
    lTraceFileName := lCommand.TraceFileName;
    lResult := RunMachineOverviewBoundedProcessCancelable(
      fServiceState.Config.WprFileName, lCommand.StartArguments,
      fServiceState.Config.CommandTimeoutMs,
      fServiceState.Config.MaximumOutputBytes,
      NativeUInt(fServiceState.StopEvent.Handle));
    if lResult.Cancelled then
    begin
      lErrorText := 'Trace capture cancelled during shutdown';
      lCancelResult := RunMachineOverviewBoundedProcess(
        fServiceState.Config.WprFileName, lCommand.CancelArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes);
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      Exit;
    end;
    if (not lResult.Started) or lResult.TimedOut or
      (lResult.ExitCode <> 0) then
    begin
      lErrorText := ProcessFailureText(lResult);
      lCancelResult := RunMachineOverviewBoundedProcess(
        fServiceState.Config.WprFileName, lCommand.CancelArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes);
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      lResult := RunMachineOverviewBoundedProcessCancelable(
        fServiceState.Config.WprFileName,
        lCommand.FallbackStartArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes,
        NativeUInt(fServiceState.StopEvent.Handle));
      if lResult.Cancelled then
      begin
        lErrorText := 'Trace capture cancelled during shutdown';
        lCancelResult := RunMachineOverviewBoundedProcess(
          fServiceState.Config.WprFileName, lCommand.CancelArguments,
          fServiceState.Config.CommandTimeoutMs,
          fServiceState.Config.MaximumOutputBytes);
        if (not lCancelResult.Started) or lCancelResult.TimedOut or
          (lCancelResult.ExitCode <> 0) then
          lErrorText := lErrorText + '; WPR cleanup: ' +
            ProcessFailureText(lCancelResult);
        Exit;
      end;
      if (not lResult.Started) or lResult.TimedOut or
        (lResult.ExitCode <> 0) then
      begin
        lErrorText := ProcessFailureText(lResult);
        lCancelResult := RunMachineOverviewBoundedProcess(
          fServiceState.Config.WprFileName, lCommand.CancelArguments,
          fServiceState.Config.CommandTimeoutMs,
          fServiceState.Config.MaximumOutputBytes);
        if (not lCancelResult.Started) or lCancelResult.TimedOut or
          (lCancelResult.ExitCode <> 0) then
          lErrorText := lErrorText + '; WPR cleanup: ' +
            ProcessFailureText(lCancelResult);
        if TraceFailureIsUnavailable(lErrorText) then
          lStatus := TMachineOverviewIncidentTraceStatus.Unavailable;
        Exit;
      end;
    end;
    if fServiceState.StopEvent.WaitFor(
        fServiceState.Config.CaptureDurationMs) = wrSignaled then
    begin
      lCancelResult := RunMachineOverviewBoundedProcess(
        fServiceState.Config.WprFileName, lCommand.CancelArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes);
      lErrorText := 'Trace capture cancelled during shutdown';
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      Exit;
    end;
    lResult := RunMachineOverviewBoundedProcessCancelable(
      fServiceState.Config.WprFileName, lCommand.StopArguments,
      fServiceState.Config.CommandTimeoutMs,
      fServiceState.Config.MaximumOutputBytes,
      NativeUInt(fServiceState.StopEvent.Handle));
    if lResult.Cancelled then
    begin
      lCancelResult := RunMachineOverviewBoundedProcess(
        fServiceState.Config.WprFileName, lCommand.CancelArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes);
      lErrorText := 'Trace finalization cancelled during shutdown';
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      Exit;
    end;
    if (not lResult.Started) or lResult.TimedOut or
      (lResult.ExitCode <> 0) then
    begin
      lErrorText := ProcessFailureText(lResult);
      lCancelResult := RunMachineOverviewBoundedProcess(
        fServiceState.Config.WprFileName, lCommand.CancelArguments,
        fServiceState.Config.CommandTimeoutMs,
        fServiceState.Config.MaximumOutputBytes);
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      Exit;
    end;
    if (not TFile.Exists(lTraceFileName)) or
      (TFile.GetSize(lTraceFileName) <= 0) then
    begin
      lErrorText := 'WPR completed without a non-empty ETL trace';
      Exit;
    end;
    if not EnforceMachineOverviewTraceRetention(fServiceState.Config,
        lRemovedCount, lErrorText) then
      Exit;
    if not TFile.Exists(lTraceFileName) then
    begin
      lErrorText := 'Captured trace exceeded the configured retention cap';
      Exit;
    end;
    lStatus := TMachineOverviewIncidentTraceStatus.Captured;
    except
      on lException: Exception do
        lErrorText := lException.ClassName + ': ' + lException.Message;
    end;
  finally
    lDurationMs := GetTickCount64 - lStartedAtMs;
    if lStatus <> TMachineOverviewIncidentTraceStatus.Captured then
      lTraceFileName := '';
    PublishOutcome(lChange, lStatus, lDurationMs, lTraceFileName,
      lErrorText);
  end;
end;

procedure TMachineOverviewTraceThread.Execute;
var
  lChange: TMachineOverviewIncidentChange;
begin
  TInterlocked.Increment(fServiceState.ActiveWorkerCount);
  try
    fServiceState.StartedEvent.SetEvent;
    while not Terminated do
    begin
      if fServiceState.StopEvent.WaitFor(0) = wrSignaled then
        Break;
      if fServiceState.Pipeline.TryTakeDetailedTrace(lChange) then
        CaptureTrace(lChange)
      else
        fServiceState.StopEvent.WaitFor(20);
    end;
    while fServiceState.Pipeline.TryTakeDetailedTrace(lChange) do
      PublishOutcome(lChange,
        TMachineOverviewIncidentTraceStatus.Failed, 0, '',
        'Trace request cancelled during shutdown');
  finally
    TInterlocked.Decrement(fServiceState.ActiveWorkerCount);
  end;
end;

constructor TMachineOverviewTraceService.Create(
  const aPipeline: TMachineOverviewPipeline;
  const aConfig: TMachineOverviewTraceConfig);
begin
  inherited Create;
  fState := TMachineOverviewTraceServiceState.Create(aPipeline, aConfig);
end;

destructor TMachineOverviewTraceService.Destroy;
var
  lServiceState: TMachineOverviewTraceServiceState;
  lStopResult: TMachineOverviewShutdownResult;
  lWorker: TThread;
begin
  if not Assigned(fState) then
  begin
    inherited Destroy;
    Exit;
  end;
  lStopResult := Stop(5000);
  if lStopResult = TMachineOverviewShutdownResult.TimedOut then
  begin
    lServiceState := GetTraceServiceState(fState);
    lServiceState.LifecycleLock.Acquire;
    try
      lWorker := lServiceState.Worker;
    finally
      lServiceState.LifecycleLock.Release;
    end;
    if Assigned(lWorker) then
    begin
      lWorker.WaitFor;
      lServiceState.LifecycleLock.Acquire;
      try
        if lServiceState.Worker = lWorker then
          lServiceState.Worker := nil;
      finally
        lServiceState.LifecycleLock.Release;
      end;
      lWorker.Free;
    end;
  end;
  fState.Free;
  inherited Destroy;
end;

function TMachineOverviewTraceService.Diagnostics:
  TMachineOverviewTraceDiagnostics;
var
  lServiceState: TMachineOverviewTraceServiceState;
begin
  Result := Default(TMachineOverviewTraceDiagnostics);
  lServiceState := GetTraceServiceState(fState);
  Result.ActiveWorkerCount := TInterlocked.CompareExchange(
    lServiceState.ActiveWorkerCount, 0, 0);
  Result.Requested := TInterlocked.CompareExchange(
    lServiceState.Requested, 0, 0);
  Result.Captured := TInterlocked.CompareExchange(
    lServiceState.Captured, 0, 0);
  Result.Failed := TInterlocked.CompareExchange(
    lServiceState.Failed, 0, 0);
  Result.Unavailable := TInterlocked.CompareExchange(
    lServiceState.Unavailable, 0, 0);
  lServiceState.DiagnosticsLock.Acquire;
  try
    Result.LastCaptureDurationMs := lServiceState.LastCaptureDurationMs;
    Result.LastTraceFileName := lServiceState.LastTraceFileName;
    Result.LastError := lServiceState.LastError;
  finally
    lServiceState.DiagnosticsLock.Release;
  end;
end;

procedure TMachineOverviewTraceService.Start;
var
  lServiceState: TMachineOverviewTraceServiceState;
begin
  lServiceState := GetTraceServiceState(fState);
  if not lServiceState.Config.Enabled then
    Exit;
  lServiceState.LifecycleLock.Acquire;
  try
    if Assigned(lServiceState.Worker) then
      Exit;
    lServiceState.StartedEvent.ResetEvent;
    lServiceState.StopEvent.ResetEvent;
    lServiceState.Worker := TMachineOverviewTraceThread.Create(
      lServiceState);
    try
      lServiceState.Worker.Start;
    except
      FreeAndNil(lServiceState.Worker);
      raise;
    end;
  finally
    lServiceState.LifecycleLock.Release;
  end;
end;

function TMachineOverviewTraceService.Stop(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
var
  lServiceState: TMachineOverviewTraceServiceState;
  lWaitResult: Cardinal;
  lWorker: TThread;
begin
  lServiceState := GetTraceServiceState(fState);
  lServiceState.LifecycleLock.Acquire;
  try
    lServiceState.StopEvent.SetEvent;
    lWorker := lServiceState.Worker;
    if not Assigned(lWorker) then
      Exit(TMachineOverviewShutdownResult.Stopped);
    lWorker.Terminate;
    lWaitResult := WaitForSingleObject(lWorker.Handle, aTimeoutMs);
    if lWaitResult <> WAIT_OBJECT_0 then
      Exit(TMachineOverviewShutdownResult.TimedOut);
    lServiceState.Worker := nil;
  finally
    lServiceState.LifecycleLock.Release;
  end;
  lWorker.Free;
  Result := TMachineOverviewShutdownResult.Stopped;
end;

function TMachineOverviewTraceService.WaitUntilRunning(
  const aTimeoutMs: Cardinal): Boolean;
var
  lServiceState: TMachineOverviewTraceServiceState;
begin
  lServiceState := GetTraceServiceState(fState);
  Result := TInterlocked.CompareExchange(
    lServiceState.ActiveWorkerCount, 0, 0) <> 0;
  if not Result then
    Result := (lServiceState.StartedEvent.WaitFor(aTimeoutMs) = wrSignaled) and
      (TInterlocked.CompareExchange(
       lServiceState.ActiveWorkerCount, 0, 0) <> 0);
end;

function SanitizeTraceName(const aValue: string): string;
var
  c: Char;
begin
  Result := '';
  for c in Trim(aValue) do
  begin
    if c.IsLetterOrDigit or (c = '-') or (c = '_') then
      Result := Result + c
    else
      Result := Result + '-';
    if Length(Result) >= cMachineOverviewTraceNameMaximumLength then
      Break;
  end;
  while ContainsText(Result, '--') do
    Result := StringReplace(Result, '--', '-', [rfReplaceAll]);
  while StartsText('-', Result) do
    Delete(Result, 1, 1);
  while EndsText('-', Result) do
    Delete(Result, Length(Result), 1);
  if Result.IsEmpty then
    Result := 'incident';
end;

function QuoteTraceArgument(const aValue: string): string;
begin
  if ContainsText(aValue, '"') then
    raise EArgumentException.Create('Trace path contains an invalid quote');
  Result := '"' + aValue + '"';
end;

function RedactUserProfilePaths(const aValue: string): string;
var
  lEndIndex: Integer;
  lMarkerIndex: Integer;
begin
  Result := aValue;
  repeat
    lMarkerIndex := Pos(':\users\', LowerCase(Result));
    if lMarkerIndex <= 1 then
      Break;
    lEndIndex := PosEx('\', Result, lMarkerIndex + Length(':\users\'));
    if lEndIndex = 0 then
      lEndIndex := Length(Result) + 1;
    Delete(Result, lMarkerIndex - 1, lEndIndex - lMarkerIndex + 1);
    Insert('<user-profile>', Result, lMarkerIndex - 1);
  until False;
end;

class function TMachineOverviewTraceConfig.Defaults:
  TMachineOverviewTraceConfig;
var
  lExecutableDirectory: string;
begin
  Result := Default(TMachineOverviewTraceConfig);
  Result.Enabled := False;
  Result.CaptureDurationMs := cMachineOverviewTraceCaptureDurationMs;
  Result.CommandTimeoutMs := cMachineOverviewTraceCommandTimeoutMs;
  Result.MaximumOutputBytes := cMachineOverviewTraceMaximumOutputBytes;
  Result.MaximumTraceCount := cMachineOverviewTraceMaximumCount;
  Result.MaximumTraceBytes := cMachineOverviewTraceMaximumBytes;
  lExecutableDirectory := ExtractFileDir(ParamStr(0));
  Result.OutputDirectory := TPath.Combine(lExecutableDirectory,
    'MachineOverviewTraces');
  Result.WprFileName := TPath.Combine(GetEnvironmentVariable('WINDIR'),
    'System32\wpr.exe');
end;

function ShouldCaptureMachineOverviewTrace(
  const aIncident: TMachineOverviewIncident): Boolean;
begin
  Result :=
    (aIncident.Origin = TMachineOverviewIncidentOrigin.UserMarked) or
    (aIncident.Category = TMachineOverviewIncidentCategory.DpcInterrupt) or
    (aIncident.Severity = TMachineOverviewSeverity.Critical);
end;

function BuildMachineOverviewTraceCommand(
  const aConfig: TMachineOverviewTraceConfig;
  const aIncident: TMachineOverviewIncident; const aProcessId: Cardinal):
  TMachineOverviewTraceCommand;
begin
  Result := Default(TMachineOverviewTraceCommand);
  if Trim(aConfig.OutputDirectory).IsEmpty then
    raise EArgumentException.Create('Trace output directory is required');
  if aProcessId = 0 then
    raise EArgumentException.Create('Trace process ID is required');
  Result.InstanceName := 'ActiveAppViewMachineOverview_' +
    UIntToStr(aProcessId);
  Result.TraceFileName := TPath.Combine(
    TPath.GetFullPath(aConfig.OutputDirectory),
    FormatDateTime('yyyymmdd-hhnnss-zzz', aIncident.StartedAtUtc,
      TFormatSettings.Invariant) + '-' +
    SanitizeTraceName(aIncident.StableId) + '.etl');
  Result.StartArguments := '-start GeneralProfile.light -start GPU.light ' +
    '-filemode -recordtempto ' +
    QuoteTraceArgument(TPath.GetFullPath(aConfig.OutputDirectory)) +
    ' -instancename ' + Result.InstanceName;
  Result.FallbackStartArguments := '-start GeneralProfile.light -filemode ' +
    '-recordtempto ' +
    QuoteTraceArgument(TPath.GetFullPath(aConfig.OutputDirectory)) +
    ' -instancename ' + Result.InstanceName;
  Result.StopArguments := '-stop ' +
    QuoteTraceArgument(Result.TraceFileName) + ' ' +
    QuoteTraceArgument('ActiveAppView Machine Overview incident ' +
      SanitizeTraceName(aIncident.StableId)) +
    ' -skipPdbGen -compress -instancename ' + Result.InstanceName;
  Result.CancelArguments := '-cancel -instancename ' + Result.InstanceName;
end;

function SanitizeMachineOverviewTraceDiagnostic(const aValue: string): string;
begin
  Result := StringReplace(aValue, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := RedactUserProfilePaths(Result);
  if not GetEnvironmentVariable('TEMP').IsEmpty then
    Result := StringReplace(Result, GetEnvironmentVariable('TEMP'),
      '<temp>', [rfReplaceAll, rfIgnoreCase]);
  Result := Trim(Result);
  while ContainsText(Result, '  ') do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  if Length(Result) > cMachineOverviewTraceDiagnosticMaximumLength then
    SetLength(Result, cMachineOverviewTraceDiagnosticMaximumLength);
end;

function EnforceMachineOverviewTraceRetention(
  const aConfig: TMachineOverviewTraceConfig;
  out aRemovedCount: Integer; out aErrorText: string): Boolean;
var
  lDirectory: string;
  lFileNames: TArray<string>;
  lFiles: TArray<TMachineOverviewTraceFileInfo>;
  lFileSize: Int64;
  lOldestIndex: Integer;
  lRemainingCount: Integer;
  lTotalBytes: UInt64;
  i: Integer;
begin
  aRemovedCount := 0;
  aErrorText := '';
  Result := False;
  if Trim(aConfig.OutputDirectory).IsEmpty or
    (aConfig.MaximumTraceCount <= 0) or
    (aConfig.MaximumTraceBytes = 0) then
  begin
    aErrorText := 'Invalid trace retention configuration';
    Exit;
  end;
  try
    lDirectory := ExcludeTrailingPathDelimiter(
      TPath.GetFullPath(aConfig.OutputDirectory));
    if SameText(lDirectory,
        ExcludeTrailingPathDelimiter(TPath.GetPathRoot(lDirectory))) then
    begin
      aErrorText := 'Trace retention directory cannot be a volume root';
      Exit;
    end;
    if not TDirectory.Exists(lDirectory) then
      TDirectory.CreateDirectory(lDirectory);
    lFileNames := TDirectory.GetFiles(lDirectory, '*.etl',
      TSearchOption.soTopDirectoryOnly);
    SetLength(lFiles, Length(lFileNames));
    lTotalBytes := 0;
    lRemainingCount := Length(lFileNames);
    for i := 0 to High(lFileNames) do
    begin
      lFiles[i].FileName := lFileNames[i];
      lFiles[i].LastWriteTimeUtc := TFile.GetLastWriteTimeUtc(lFileNames[i]);
      lFileSize := TFile.GetSize(lFileNames[i]);
      if lFileSize > 0 then
        lFiles[i].Size := UInt64(lFileSize);
      if lFiles[i].Size > High(UInt64) - lTotalBytes then
        lTotalBytes := High(UInt64)
      else
        lTotalBytes := lTotalBytes + lFiles[i].Size;
    end;
    while (lRemainingCount > aConfig.MaximumTraceCount) or
      (lTotalBytes > aConfig.MaximumTraceBytes) do
    begin
      lOldestIndex := -1;
      for i := 0 to High(lFiles) do
        if (not lFiles[i].Deleted) and
          ((lOldestIndex < 0) or
           (lFiles[i].LastWriteTimeUtc <
            lFiles[lOldestIndex].LastWriteTimeUtc) or
           ((lFiles[i].LastWriteTimeUtc =
             lFiles[lOldestIndex].LastWriteTimeUtc) and
            (CompareText(lFiles[i].FileName,
              lFiles[lOldestIndex].FileName) < 0))) then
          lOldestIndex := i;
      if lOldestIndex < 0 then
        Break;
      TFile.Delete(lFiles[lOldestIndex].FileName);
      lFiles[lOldestIndex].Deleted := True;
      Dec(lRemainingCount);
      if lTotalBytes >= lFiles[lOldestIndex].Size then
        lTotalBytes := lTotalBytes - lFiles[lOldestIndex].Size
      else
        lTotalBytes := 0;
      Inc(aRemovedCount);
    end;
    Result := True;
  except
    on lException: Exception do
      aErrorText := SanitizeMachineOverviewTraceDiagnostic(
        lException.ClassName + ': ' + lException.Message);
  end;
end;

end.

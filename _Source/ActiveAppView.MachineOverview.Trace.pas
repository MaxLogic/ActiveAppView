unit ActiveAppView.MachineOverview.Trace;

interface

uses
  System.SysUtils,
  ActiveAppView.MachineOverview.BoundedProcess,
  ActiveAppView.MachineOverview.EtlInfo,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewOnsetTraceState = (Off, Unavailable, Busy, Starting, Recording, Saving, Failed);
  TMachineOverviewWprRunner = reference to function(const aArguments: string;
    const aTimeoutMs: Cardinal; const aCancelHandle: NativeUInt): TMachineOverviewProcessResult;
  TMachineOverviewTraceStatusWriter = procedure(const aKey, aText: string) of object;
  TMachineOverviewTraceConfig = record
    OnsetEnabled: Boolean;
    OnsetBufferMB, OnsetCooldownMs, StopTimeoutMs, BusyRecheckMs, FailureRetryMs: Cardinal;
    Runner: TMachineOverviewWprRunner;
    IsElevated: TFunc<Boolean>;
    InspectEtl: TFunc<string, TMachineOverviewEtlInfo>;
    FreeBytes: TFunc<string, Int64>;
    StatusText: TMachineOverviewTraceStatusWriter;
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
    OnsetState: TMachineOverviewOnsetTraceState;
    OnsetStateText: string;
    RingStartedUtc: TDateTime;
    OnsetSaved, OnsetSkipped: Int64;
    LastEventsLost, LastBuffersLost: Cardinal;
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
function ShouldSaveMachineOverviewOnsetTrace(const aIncident: TMachineOverviewIncident): Boolean;
function BuildMachineOverviewOnsetProfile(const aBufferMB: Cardinal): string;
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
  System.JSON, System.Math, System.StrUtils, System.SyncObjs,
  Winapi.Windows;

const
  cOnsetReconcileMinimumMs: Cardinal = 20;
  cOnsetReconcileInitialMs: Cardinal = 30000;
  cOnsetReconcileMaximumMs: Cardinal = 300000;
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

  TMachineOverviewOnsetMarker = record
    InstanceName, State: string;
    CreatedUtc: TDateTime;
    PreexistingAtStart: Boolean;
    BufferMB: Cardinal;
  end;

  TMachineOverviewTraceServiceState = class;

  TMachineOverviewTraceThread = class(TThread)
  private
    fServiceState: TMachineOverviewTraceServiceState;
    fOnsetMutex: THandle;
    fNextReconcileMs: UInt64;
    fReconcileDelayMs: Cardinal;
    fStartAttempts: Integer;
    fNextStartMs, fLastSaveMs: UInt64;
    function RunWpr(const aArguments: string; const aTimeoutMs: Cardinal;
      const aCancelHandle: NativeUInt = 0): TMachineOverviewProcessResult;
    procedure SetOnsetState(const aState: TMachineOverviewOnsetTraceState; const aText: string);
    procedure StartOnset;
    function OnsetElevated: Boolean;
    function EnsureOnsetAccess: Boolean;
    function QueryOnsetRecording: Boolean;
    function ReconcileOnset(const aCancel: Boolean): Boolean;
    procedure ScheduleOnsetReconcile(const aBackoff: Boolean);
    procedure CaptureOnset(const aChange: TMachineOverviewIncidentChange);
    function OnsetMarker: string;
    function ReadOnsetOwnership(out aMarker: TMachineOverviewOnsetMarker): Boolean;
    procedure PersistOnsetOwnership(const aMarker: TMachineOverviewOnsetMarker);
    function StaleOnsetBufferMB: Cardinal;
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
    OnsetDiagnostics: TMachineOverviewTraceDiagnostics;
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

function QuoteTraceArgument(const aValue: string): string; forward;
function SanitizeTraceName(const aValue: string): string; forward;

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
  if aConfig.OnsetEnabled and ((aConfig.CommandTimeoutMs = 0) or (aConfig.StopTimeoutMs = 0) or
    (aConfig.BusyRecheckMs = 0) or (aConfig.FailureRetryMs = 0) or
    (aConfig.MaximumOutputBytes = 0) or (aConfig.MaximumTraceCount <= 0) or
    (aConfig.MaximumTraceBytes = 0)) then
    raise EArgumentException.Create('Invalid onset trace configuration');
  Config := aConfig;
  Config.OnsetBufferMB := EnsureRange(Config.OnsetBufferMB, Cardinal(64), Cardinal(1024));
  OnsetDiagnostics.OnsetStateText := 'Onset recording off';
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
  aChange.Incident.TraceFile := aTraceFileName;
  aChange.Incident.TraceDetail := SanitizeMachineOverviewTraceDiagnostic(aErrorText);
  if (not fServiceState.Config.OnsetEnabled) and (not aChange.Incident.TraceDetail.IsEmpty) then
    aChange.Incident.TraceDetail := SanitizeMachineOverviewTraceDiagnostic(
      'Post-detection trace: ' + aChange.Incident.TraceDetail);
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
    if (not Assigned(fServiceState.Config.Runner)) and
      (not TFile.Exists(fServiceState.Config.WprFileName)) then
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
    lResult := RunWpr(lCommand.StartArguments, fServiceState.Config.CommandTimeoutMs,
        NativeUInt(fServiceState.StopEvent.Handle));
    if lResult.Cancelled then
    begin
      lErrorText := 'Trace capture cancelled during shutdown';
      lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
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
      lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      lResult := RunWpr(lCommand.FallbackStartArguments, fServiceState.Config.CommandTimeoutMs,
        NativeUInt(fServiceState.StopEvent.Handle));
      if lResult.Cancelled then
      begin
        lErrorText := 'Trace capture cancelled during shutdown';
        lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
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
        lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
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
      lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
      lErrorText := 'Trace capture cancelled during shutdown';
      if (not lCancelResult.Started) or lCancelResult.TimedOut or
        (lCancelResult.ExitCode <> 0) then
        lErrorText := lErrorText + '; WPR cleanup: ' +
          ProcessFailureText(lCancelResult);
      Exit;
    end;
    lResult := RunWpr(lCommand.StopArguments, fServiceState.Config.CommandTimeoutMs,
        NativeUInt(fServiceState.StopEvent.Handle));
    if lResult.Cancelled then
    begin
      lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
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
      lCancelResult := RunWpr(lCommand.CancelArguments, fServiceState.Config.CommandTimeoutMs);
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

function ShouldSaveMachineOverviewOnsetTrace(const aIncident: TMachineOverviewIncident): Boolean;
begin
  Result := (aIncident.Origin = TMachineOverviewIncidentOrigin.UserMarked) or
    (aIncident.Category in [TMachineOverviewIncidentCategory.HighCpu,
      TMachineOverviewIncidentCategory.DpcInterrupt]) or
    ((aIncident.Category = TMachineOverviewIncidentCategory.ForegroundResponse) and
      (aIncident.Severity = TMachineOverviewSeverity.Critical));
end;

function BuildMachineOverviewOnsetProfile(const aBufferMB: Cardinal): string;
begin
  Result := '<?xml version="1.0" encoding="utf-8"?>' + sLineBreak +
    '<WindowsPerformanceRecorder Version="1.0" Author="ActiveAppView">' +
    '<Profiles><SystemCollector Id="AAVCollector" Name="ActiveAppView onset">' +
    '<BufferSize Value="1024"/><Buffers Value="' +
    UIntToStr(EnsureRange(aBufferMB, Cardinal(64), Cardinal(1024))) + '"/>' +
    '</SystemCollector><SystemProvider Id="AAVSystem"><Keywords>' +
    '<Keyword Value="ProcessThread"/><Keyword Value="Loader"/>' +
    '<Keyword Value="SampledProfile"/><Keyword Value="DPC"/><Keyword Value="Interrupt"/>' +
    '</Keywords><Stacks><Stack Value="SampledProfile"/></Stacks></SystemProvider>' +
    '<Profile Id="AAVOnset.Light.Memory" Name="AAVOnset" Description="ActiveAppView onset CPU ring" ' +
    'LoggingMode="Memory" DetailLevel="Light"><Collectors>' +
    '<SystemCollectorId Value="AAVCollector"><SystemProviderId Value="AAVSystem"/>' +
    '</SystemCollectorId></Collectors></Profile></Profiles></WindowsPerformanceRecorder>';
end;

function TraceProcessElevated: Boolean;
var
  lToken: THandle;
  lElevation, lSize: Cardinal;
begin
  Result := False;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, lToken) then
    Exit;
  try
    Result := GetTokenInformation(lToken, TokenElevation, @lElevation, SizeOf(lElevation), lSize);
    if Result then
      Result := (lSize >= SizeOf(lElevation)) and (lElevation <> 0);
  finally
    CloseHandle(lToken);
  end;
end;

function WprSucceeded(const aResult: TMachineOverviewProcessResult): Boolean;
begin
  Result := aResult.Started and (not aResult.TimedOut) and (not aResult.Cancelled) and
    (aResult.ExitCode = 0);
end;

function TMachineOverviewTraceThread.RunWpr(const aArguments: string;
  const aTimeoutMs: Cardinal; const aCancelHandle: NativeUInt): TMachineOverviewProcessResult;
begin
  if Assigned(fServiceState.Config.Runner) then
    Exit(fServiceState.Config.Runner(aArguments, aTimeoutMs, aCancelHandle));
  Result := RunMachineOverviewBoundedProcessCancelable(fServiceState.Config.WprFileName,
    aArguments, aTimeoutMs, fServiceState.Config.MaximumOutputBytes, aCancelHandle);
end;

function TMachineOverviewTraceThread.OnsetMarker: string;
begin
  Result := TPath.Combine(fServiceState.Config.OutputDirectory, 'onset-session.active');
end;

function TMachineOverviewTraceThread.ReadOnsetOwnership(
  out aMarker: TMachineOverviewOnsetMarker): Boolean;
var
  lJson: TJSONValue;
begin
  aMarker := Default(TMachineOverviewOnsetMarker);
  Result := TFile.Exists(OnsetMarker);
  if not Result then
    Exit;
  if TFile.GetSize(OnsetMarker) > 4096 then
    raise EInvalidOpException.Create('Invalid onset ownership marker; session left untouched');
  lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(OnsetMarker, TEncoding.UTF8));
  try
    if not (lJson is TJSONObject) then
      raise EInvalidOpException.Create('Invalid onset ownership marker; session left untouched');
    aMarker.InstanceName := lJson.GetValue<string>('instance');
    aMarker.State := lJson.GetValue<string>('state');
    aMarker.CreatedUtc := ISO8601ToDate(lJson.GetValue<string>('createdUtc'), True);
    aMarker.PreexistingAtStart := lJson.GetValue<Boolean>('PreexistingAtStart');
    aMarker.BufferMB := lJson.GetValue<Cardinal>('bufferMB');
    if (aMarker.InstanceName <> 'ActiveAppViewOnset') or
      ((aMarker.State <> 'Pending') and (aMarker.State <> 'Owned')) or
      (aMarker.BufferMB < 64) or (aMarker.BufferMB > 1024) then
      raise EInvalidOpException.Create('Invalid onset ownership marker; session left untouched');
  finally
    lJson.Free;
  end;
end;

procedure TMachineOverviewTraceThread.PersistOnsetOwnership(const aMarker: TMachineOverviewOnsetMarker);
var
  lStream: TFileStream;
  lBytes: TBytes;
  lTemp: string;
begin
  lBytes := TEncoding.UTF8.GetBytes('{"instance":"' + aMarker.InstanceName +
    '","state":"' + aMarker.State + '","createdUtc":"' + DateToISO8601(aMarker.CreatedUtc, True) +
    '","PreexistingAtStart":' + LowerCase(BoolToStr(aMarker.PreexistingAtStart, True)) +
    ',"bufferMB":' + UIntToStr(aMarker.BufferMB) + '}');
  lTemp := OnsetMarker + '.tmp';
  try
    lStream := TFileStream.Create(lTemp, fmCreate);
    try
      lStream.WriteBuffer(lBytes[0], Length(lBytes));
      if not FlushFileBuffers(lStream.Handle) then
        RaiseLastOSError;
    finally
      lStream.Free;
    end;
    // Replacement preserves the flushed Pending record if an Owned update is interrupted.
    if not MoveFileEx(PChar(lTemp), PChar(OnsetMarker), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  finally
    if TFile.Exists(lTemp) then
      TFile.Delete(lTemp);
  end;
end;

function TMachineOverviewTraceThread.StaleOnsetBufferMB: Cardinal;
var
  lMarker: TMachineOverviewOnsetMarker;
begin
  Result := 1024;
  try
    if ReadOnsetOwnership(lMarker) then
      Result := lMarker.BufferMB;
  except
    // An unreadable/legacy marker must not understate possibly retained memory.
    Result := 1024;
  end;
end;

procedure TMachineOverviewTraceThread.SetOnsetState(const aState: TMachineOverviewOnsetTraceState;
  const aText: string);
var
  lText: string;
begin
  lText := aText;
  if TFile.Exists(OnsetMarker) and (aState <> TMachineOverviewOnsetTraceState.Recording) and
    (not ContainsText(lText, 'may still hold')) then
    lText := Format('An onset recording session may still hold up to %d MB; ', [StaleOnsetBufferMB]) + lText;
  lText := SanitizeMachineOverviewTraceDiagnostic(lText);
  fServiceState.DiagnosticsLock.Acquire;
  try
    fServiceState.OnsetDiagnostics.OnsetState := aState;
    fServiceState.OnsetDiagnostics.OnsetStateText := lText;
    if aState = TMachineOverviewOnsetTraceState.Recording then
      fServiceState.OnsetDiagnostics.RingStartedUtc := TTimeZone.Local.ToUniversalTime(Now);
  finally
    fServiceState.DiagnosticsLock.Release;
  end;
  if Assigned(fServiceState.Config.StatusText) then
    fServiceState.Config.StatusText('onset-trace', lText);
end;

function TMachineOverviewTraceThread.OnsetElevated: Boolean;
begin
  if Assigned(fServiceState.Config.IsElevated) then
    Result := fServiceState.Config.IsElevated()
  else
    Result := TraceProcessElevated;
end;

function TMachineOverviewTraceThread.QueryOnsetRecording: Boolean;
var
  lResult: TMachineOverviewProcessResult;
begin
  lResult := RunWpr('-status -instancename ActiveAppViewOnset', fServiceState.Config.CommandTimeoutMs);
  if lResult.Started and (not lResult.TimedOut) and (not lResult.Cancelled) and
    ContainsText(lResult.OutputText, 'not recording') then
    Exit(False);
  if WprSucceeded(lResult) and ContainsText(lResult.OutputText, 'recording') then
    Exit(True);
  raise EInvalidOpException.Create('Onset instance status unknown: ' + ProcessFailureText(lResult));
end;

procedure TMachineOverviewTraceThread.ScheduleOnsetReconcile(const aBackoff: Boolean);
begin
  if (not aBackoff) or (fReconcileDelayMs = 0) then
  begin
    fReconcileDelayMs := fServiceState.Config.FailureRetryMs;
    if fReconcileDelayMs < cOnsetReconcileMinimumMs then
      fReconcileDelayMs := cOnsetReconcileMinimumMs
    else if fReconcileDelayMs > cOnsetReconcileInitialMs then
      fReconcileDelayMs := cOnsetReconcileInitialMs;
  end else if fReconcileDelayMs >= cOnsetReconcileMaximumMs div 2 then
    fReconcileDelayMs := cOnsetReconcileMaximumMs
  else
    Inc(fReconcileDelayMs, fReconcileDelayMs);
  fNextReconcileMs := GetTickCount64 + fReconcileDelayMs;
end;

function TMachineOverviewTraceThread.ReconcileOnset(const aCancel: Boolean): Boolean;
var
  lMarker: TMachineOverviewOnsetMarker;
  lResult: TMachineOverviewProcessResult;
begin
  Result := not TFile.Exists(OnsetMarker);
  if Result then
    Exit;
  try
    if not EnsureOnsetAccess then
      Exit;
    // Confirm absence before interpreting provenance: an idle stale marker needs no cancellation.
    if QueryOnsetRecording then
    begin
      if not ReadOnsetOwnership(lMarker) then
        Exit;
      if lMarker.PreexistingAtStart then
      begin
        SetOnsetState(TMachineOverviewOnsetTraceState.Busy, 'Onset instance name in use by another session');
        ScheduleOnsetReconcile(True);
        Exit;
      end;
      if (not aCancel) and (lMarker.State = 'Owned') then
      begin
        ScheduleOnsetReconcile(False);
        Exit;
      end;
      lResult := RunWpr('-cancel -instancename ActiveAppViewOnset', fServiceState.Config.CommandTimeoutMs);
      if QueryOnsetRecording then
        raise EInvalidOpException.Create('Onset cleanup did not confirm absence: ' + ProcessFailureText(lResult));
    end;
    TFile.Delete(OnsetMarker);
    fNextReconcileMs := High(UInt64);
    fReconcileDelayMs := 0;
    SetOnsetState(TMachineOverviewOnsetTraceState.Off, 'Onset recording off');
    Result := True;
  except
    on lException: Exception do
    begin
      SetOnsetState(TMachineOverviewOnsetTraceState.Failed, 'Onset cleanup failed: ' + lException.Message);
      ScheduleOnsetReconcile(True);
    end;
  end;
end;

function TMachineOverviewTraceThread.EnsureOnsetAccess: Boolean;
var
  lMutexResult: Cardinal;
begin
  Result := False;
  if not OnsetElevated then
  begin
    SetOnsetState(TMachineOverviewOnsetTraceState.Unavailable,
      'Onset recording needs administrator; restart ActiveAppView elevated (no elevation is requested)');
    ScheduleOnsetReconcile(True);
    Exit;
  end;
  if fOnsetMutex = 0 then
  begin
    fOnsetMutex := CreateMutex(nil, False, 'Local\ActiveAppView.MachineOverview.OnsetTrace');
    if fOnsetMutex = 0 then
      RaiseLastOSError;
    lMutexResult := WaitForSingleObject(fOnsetMutex, 0);
    if (lMutexResult <> WAIT_OBJECT_0) and (lMutexResult <> WAIT_ABANDONED) then
    begin
      CloseHandle(fOnsetMutex);
      fOnsetMutex := 0;
      SetOnsetState(TMachineOverviewOnsetTraceState.Busy, 'Another ActiveAppView owns onset recording');
      ScheduleOnsetReconcile(True);
      Exit;
    end;
  end;
  Result := True;
end;

procedure TMachineOverviewTraceThread.StartOnset;
var
  lResult: TMachineOverviewProcessResult;
  lMarker: TMachineOverviewOnsetMarker;
  lProfile, lError: string;
begin
  fNextStartMs := High(UInt64);
  try
    if not EnsureOnsetAccess then
    begin
      if (not TFile.Exists(OnsetMarker)) and
        (fServiceState.OnsetDiagnostics.OnsetState = TMachineOverviewOnsetTraceState.Busy) then
        fNextStartMs := GetTickCount64 + fServiceState.Config.BusyRecheckMs;
      Exit;
    end;
    if TFile.Exists(OnsetMarker) and (not ReconcileOnset(True)) then
      Exit;
    // A matching name alone never establishes ownership.
    if QueryOnsetRecording then
    begin
      fNextStartMs := GetTickCount64 + fServiceState.Config.BusyRecheckMs;
      SetOnsetState(TMachineOverviewOnsetTraceState.Busy, 'Onset instance name in use by another session');
      Exit;
    end;
    lResult := RunWpr('-status', fServiceState.Config.CommandTimeoutMs);
    if lResult.TimedOut or lResult.Cancelled or (not lResult.Started) or
      (not ContainsText(lResult.OutputText, 'not recording')) then
    begin
      if WprSucceeded(lResult) and ContainsText(lResult.OutputText, 'recording') then
      begin
        fNextStartMs := GetTickCount64 + fServiceState.Config.BusyRecheckMs;
        SetOnsetState(TMachineOverviewOnsetTraceState.Busy, 'Another WPR recording is active; onset recording waits');
        Exit;
      end;
      raise EInvalidOpException.Create(ProcessFailureText(lResult));
    end;
    if fServiceState.StopEvent.WaitFor(0) = wrSignaled then
      Exit;
    SetOnsetState(TMachineOverviewOnsetTraceState.Starting, 'Starting onset recording');
    TDirectory.CreateDirectory(fServiceState.Config.OutputDirectory);
    lProfile := TPath.Combine(fServiceState.Config.OutputDirectory, 'ActiveAppViewOnset.wprp');
    TFile.WriteAllText(lProfile, BuildMachineOverviewOnsetProfile(fServiceState.Config.OnsetBufferMB), TEncoding.UTF8);
    lMarker := Default(TMachineOverviewOnsetMarker);
    lMarker.InstanceName := 'ActiveAppViewOnset';
    lMarker.State := 'Pending';
    lMarker.CreatedUtc := TTimeZone.Local.ToUniversalTime(Now);
    lMarker.BufferMB := fServiceState.Config.OnsetBufferMB;
    PersistOnsetOwnership(lMarker);
    lResult := RunWpr('-start ' + QuoteTraceArgument(lProfile + '!AAVOnset') +
      ' -instancename ActiveAppViewOnset', fServiceState.Config.CommandTimeoutMs);
    if not WprSucceeded(lResult) then
    begin
      // A definite rejection plus confirmed absence needs no cancellation.
      if lResult.Started and (not lResult.TimedOut) and (not lResult.Cancelled) then
      begin
        try
          if not QueryOnsetRecording then
            TFile.Delete(OnsetMarker);
        except
          on lException: Exception do
            lResult.OutputText := lResult.OutputText + '; ' + lException.Message;
        end;
      end;
      raise EInvalidOpException.Create(ProcessFailureText(lResult));
    end;
    lMarker.State := 'Owned';
    PersistOnsetOwnership(lMarker);
    ScheduleOnsetReconcile(False);
    SetOnsetState(TMachineOverviewOnsetTraceState.Recording, 'Recording onset CPU trace (memory circular)');
  except
    on lException: Exception do
    begin
      Inc(fStartAttempts);
      lError := SanitizeMachineOverviewTraceDiagnostic(lException.Message);
      if TFile.Exists(OnsetMarker) then
        ScheduleOnsetReconcile(True);
      if TraceFailureIsUnavailable(lError) then
        SetOnsetState(TMachineOverviewOnsetTraceState.Unavailable, lError)
      else
      begin
        if (not TFile.Exists(OnsetMarker)) and (fStartAttempts < 3) then
          fNextStartMs := GetTickCount64 + fServiceState.Config.FailureRetryMs;
        SetOnsetState(TMachineOverviewOnsetTraceState.Failed, lError);
      end;
    end;
  end;
end;

procedure TMachineOverviewTraceThread.CaptureOnset(const aChange: TMachineOverviewIncidentChange);
var
  lChange, lPending: TMachineOverviewIncidentChange;
  lCommand: TMachineOverviewTraceCommand;
  lResult: TMachineOverviewProcessResult;
  lInfo: TMachineOverviewEtlInfo;
  lState: TMachineOverviewOnsetTraceState;
  lStatus: TMachineOverviewIncidentTraceStatus;
  lDetail, lFileName, lError: string;
  lFree: Int64;
  lAvailable, lTotal, lTotalFree: UInt64;
  lRemoved: Integer;
  lSaveStarted: Boolean;
  lMarker: TMachineOverviewOnsetMarker;
  lNowMs: UInt64;
begin
  lChange := aChange;
  lFileName := '';
  lDetail := '';
  lStatus := TMachineOverviewIncidentTraceStatus.Skipped;
  lSaveStarted := False;
  TInterlocked.Increment(fServiceState.Requested);
  try
  try
    fServiceState.DiagnosticsLock.Acquire;
    try
      lState := fServiceState.OnsetDiagnostics.OnsetState;
      lDetail := fServiceState.OnsetDiagnostics.OnsetStateText;
    finally
      fServiceState.DiagnosticsLock.Release;
    end;
    if (lState <> TMachineOverviewOnsetTraceState.Recording) or
      (not ReadOnsetOwnership(lMarker)) or lMarker.PreexistingAtStart or
      (lMarker.State <> 'Owned') then
    begin
      if lState = TMachineOverviewOnsetTraceState.Unavailable then
        lStatus := TMachineOverviewIncidentTraceStatus.Unavailable
      else if lState = TMachineOverviewOnsetTraceState.Failed then
        lStatus := TMachineOverviewIncidentTraceStatus.Failed;
      Exit;
    end;
    lNowMs := GetTickCount64;
    if (aChange.Incident.Origin <> TMachineOverviewIncidentOrigin.UserMarked) and
      (fLastSaveMs <> 0) and
      (lNowMs - fLastSaveMs < fServiceState.Config.OnsetCooldownMs) then
    begin
      lDetail := 'Onset trace skipped: cooldown until ' + FormatDateTime('hh:nn:ss',
        Now + ((fServiceState.Config.OnsetCooldownMs - (lNowMs - fLastSaveMs)) / 86400000.0));
      Exit;
    end;
    if Assigned(fServiceState.Config.FreeBytes) then
      lFree := fServiceState.Config.FreeBytes(fServiceState.Config.OutputDirectory)
    else
    begin
      if not GetDiskFreeSpaceEx(PChar(fServiceState.Config.OutputDirectory), lAvailable, lTotal, @lTotalFree) then
        RaiseLastOSError;
      if lAvailable > UInt64(High(Int64)) then
        lFree := High(Int64)
      else
        lFree := Int64(lAvailable);
    end;
    if lFree < (Int64(2) * fServiceState.Config.OnsetBufferMB + 1024) * 1024 * 1024 then
    begin
      lDetail := 'Onset trace skipped: not enough free space on ' +
        ExtractFileDrive(fServiceState.Config.OutputDirectory);
      Exit;
    end;
    if not EnforceMachineOverviewTraceRetention(fServiceState.Config, lRemoved, lError) then
      raise EInvalidOpException.Create(lError);
    lCommand := BuildMachineOverviewTraceCommand(fServiceState.Config, aChange.Incident, GetCurrentProcessId);
    lFileName := lCommand.TraceFileName;
    lSaveStarted := True;
    lStatus := TMachineOverviewIncidentTraceStatus.Failed;
    SetOnsetState(TMachineOverviewOnsetTraceState.Saving, 'Saving onset trace; recording was restarting');
    // Shutdown waits for this bounded stop, then cancels our instance. It must not kill WPR mid-save.
    lResult := RunWpr('-stop ' + QuoteTraceArgument(lFileName) + ' ' +
      QuoteTraceArgument('ActiveAppView onset ' + SanitizeTraceName(aChange.Incident.StableId)) +
      ' -skipPdbGen -instancename ActiveAppViewOnset', fServiceState.Config.StopTimeoutMs);
    if not WprSucceeded(lResult) then
      raise EInvalidOpException.Create(ProcessFailureText(lResult));
    if QueryOnsetRecording then
      raise EInvalidOpException.Create('Onset save did not confirm session absence');
    TFile.Delete(OnsetMarker);
    if (not TFile.Exists(lFileName)) or (TFile.GetSize(lFileName) = 0) then
      raise EInvalidOpException.Create('WPR completed without a non-empty ETL trace');
    if Assigned(fServiceState.Config.InspectEtl) then
      lInfo := fServiceState.Config.InspectEtl(lFileName)
    else
      lInfo := ReadMachineOverviewEtlInfo(lFileName);
    if not lInfo.Readable then
      raise EInvalidOpException.Create('Cannot inspect onset ETL: ' + lInfo.ErrorText);
    lDetail := 'Onset trace ' + ExtractFileName(lFileName) + ': events ' +
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', lInfo.FirstEventUtc) + ' - ' +
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', lInfo.LastEventUtc) + ', ';
    if lInfo.FirstEventUtc <= aChange.Incident.StartedAtUtc then
      lDetail := lDetail + Format('includes onset (%d s before incident start)',
        [SecondsBetween(lInfo.FirstEventUtc, aChange.Incident.StartedAtUtc)])
    else
      lDetail := lDetail + Format('starts %d s after incident start, onset not included',
        [SecondsBetween(lInfo.FirstEventUtc, aChange.Incident.StartedAtUtc)]);
    lDetail := lDetail + Format('; events lost %d; buffers lost %d', [lInfo.EventsLost, lInfo.BuffersLost]);
    lStatus := TMachineOverviewIncidentTraceStatus.Captured;
  except
    on lException: Exception do
    begin
      lStatus := TMachineOverviewIncidentTraceStatus.Failed;
      lDetail := SanitizeMachineOverviewTraceDiagnostic(lException.Message);
      if TraceFailureIsUnavailable(lDetail) then
        lStatus := TMachineOverviewIncidentTraceStatus.Unavailable;
    end;
  end;
  finally
    try
      if lSaveStarted then
      begin
        // Even a failed stop/inspection can leave a partial ETL. Always enforce both caps.
        if not EnforceMachineOverviewTraceRetention(fServiceState.Config, lRemoved, lError) then
        begin
          lStatus := TMachineOverviewIncidentTraceStatus.Failed;
          lDetail := Copy(lDetail, 1, 240) + '; Trace retention failed: ' + Copy(lError, 1, 240);
        end else if (lStatus = TMachineOverviewIncidentTraceStatus.Captured) and
          (not TFile.Exists(lFileName)) then
        begin
          lStatus := TMachineOverviewIncidentTraceStatus.Failed;
          lDetail := 'Captured trace exceeded the configured retention cap';
        end;
        if lStatus = TMachineOverviewIncidentTraceStatus.Captured then
        begin
          fLastSaveMs := GetTickCount64;
          fServiceState.DiagnosticsLock.Acquire;
          try
            Inc(fServiceState.OnsetDiagnostics.OnsetSaved);
            fServiceState.OnsetDiagnostics.LastEventsLost := lInfo.EventsLost;
            fServiceState.OnsetDiagnostics.LastBuffersLost := lInfo.BuffersLost;
          finally
            fServiceState.DiagnosticsLock.Release;
          end;
        end;
        if TFile.Exists(OnsetMarker) and (not ReconcileOnset(True)) then
          lDetail := lDetail + '; ' + fServiceState.OnsetDiagnostics.OnsetStateText;
        while fServiceState.Pipeline.TryTakeDetailedTrace(lPending) do
        begin
          PublishOutcome(lPending, TMachineOverviewIncidentTraceStatus.Skipped, 0, '',
            'Onset trace skipped: recording was restarting');
          fServiceState.DiagnosticsLock.Acquire;
          try
            Inc(fServiceState.OnsetDiagnostics.OnsetSkipped);
          finally
            fServiceState.DiagnosticsLock.Release;
          end;
        end;
        if (not TFile.Exists(OnsetMarker)) and (fServiceState.StopEvent.WaitFor(0) <> wrSignaled) then
          StartOnset;
      end;
    finally
      if lStatus = TMachineOverviewIncidentTraceStatus.Skipped then
      begin
        fServiceState.DiagnosticsLock.Acquire;
        try
          Inc(fServiceState.OnsetDiagnostics.OnsetSkipped);
        finally
          fServiceState.DiagnosticsLock.Release;
        end;
      end;
      if lStatus <> TMachineOverviewIncidentTraceStatus.Captured then
        lFileName := '';
      PublishOutcome(lChange, lStatus, 0, lFileName, lDetail);
    end;
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
      // Cleanup follows durable markers even when recording is disabled.
      if TFile.Exists(OnsetMarker) and (GetTickCount64 >= fNextReconcileMs) then
      begin
        if ReconcileOnset((not fServiceState.Config.OnsetEnabled) or
          (fServiceState.OnsetDiagnostics.OnsetState <> TMachineOverviewOnsetTraceState.Recording)) and
          fServiceState.Config.OnsetEnabled then
        begin
          if fStartAttempts < 3 then
            fNextStartMs := GetTickCount64
          else
            SetOnsetState(TMachineOverviewOnsetTraceState.Failed,
              'Onset start failed after three attempts; restart ActiveAppView to retry');
        end;
      end;
      if fServiceState.Config.OnsetEnabled and (not TFile.Exists(OnsetMarker)) and
        (GetTickCount64 >= fNextStartMs) then
        StartOnset;
      if fServiceState.Pipeline.TryTakeDetailedTrace(lChange) then
      begin
        if fServiceState.Config.OnsetEnabled then
          CaptureOnset(lChange)
        else
          CaptureTrace(lChange);
      end else
        fServiceState.StopEvent.WaitFor(20);
    end;
    while fServiceState.Pipeline.TryTakeDetailedTrace(lChange) do
      PublishOutcome(lChange,
        TMachineOverviewIncidentTraceStatus.Failed, 0, '',
        'Trace request cancelled during shutdown');
  finally
    try
      if not ReconcileOnset(True) then
      begin
        fServiceState.DiagnosticsLock.Acquire;
        try
          fServiceState.LastError := fServiceState.OnsetDiagnostics.OnsetStateText;
        finally
          fServiceState.DiagnosticsLock.Release;
        end;
      end;
    finally
      if fOnsetMutex <> 0 then
      begin
        ReleaseMutex(fOnsetMutex);
        CloseHandle(fOnsetMutex);
        fOnsetMutex := 0;
      end;
    end;
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
    Result.OnsetState := lServiceState.OnsetDiagnostics.OnsetState;
    Result.OnsetStateText := lServiceState.OnsetDiagnostics.OnsetStateText;
    Result.RingStartedUtc := lServiceState.OnsetDiagnostics.RingStartedUtc;
    Result.OnsetSaved := lServiceState.OnsetDiagnostics.OnsetSaved;
    Result.OnsetSkipped := lServiceState.OnsetDiagnostics.OnsetSkipped;
    Result.LastEventsLost := lServiceState.OnsetDiagnostics.LastEventsLost;
    Result.LastBuffersLost := lServiceState.OnsetDiagnostics.LastBuffersLost;
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
  if not (lServiceState.Config.Enabled or lServiceState.Config.OnsetEnabled or
    TFile.Exists(TPath.Combine(lServiceState.Config.OutputDirectory, 'onset-session.active'))) then
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
  Result.OnsetEnabled := False;
  Result.OnsetBufferMB := 256;
  Result.OnsetCooldownMs := 15 * 60 * 1000;
  Result.StopTimeoutMs := 120000;
  Result.BusyRecheckMs := 60000;
  Result.FailureRetryMs := 5 * 60 * 1000;
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

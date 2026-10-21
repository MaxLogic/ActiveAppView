unit ActiveAppView.MachineOverview.Trace.SelfTests;

interface

function RunMachineOverviewTraceSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.DateUtils, System.IOUtils, System.StrUtils, System.SyncObjs,
  System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.BoundedProcess,
  ActiveAppView.MachineOverview.EtlInfo,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Service,
  ActiveAppView.MachineOverview.Settings,
  ActiveAppView.MachineOverview.Trace,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewTraceSelfTestArg =
    '--self-test-machine-overview-tracing';
  cMachineOverviewTraceTimeoutChildArg =
    '--machine-overview-trace-timeout-child';

function RunTraceDefaultsSelfTest: Integer;
var
  lConfig: TMachineOverviewTraceConfig;
begin
  Result := 1;
  lConfig := TMachineOverviewTraceConfig.Defaults;
  if lConfig.Enabled or
    (lConfig.CaptureDurationMs < 15000) or
    (lConfig.CaptureDurationMs > 30000) or
    (lConfig.CommandTimeoutMs = 0) or
    (lConfig.MaximumOutputBytes = 0) or
    (lConfig.MaximumTraceCount <= 0) or
    (lConfig.MaximumTraceBytes = 0) or
    lConfig.OutputDirectory.IsEmpty or lConfig.WprFileName.IsEmpty then
  begin
    Writeln('SELFTEST FAILED: detailed trace defaults are not disabled, bounded, and executable-local');
    Exit;
  end;
  Result := 0;
end;

function RunTracePolicySelfTest: Integer;
var
  lIncident: TMachineOverviewIncident;
begin
  Result := 1;
  lIncident := Default(TMachineOverviewIncident);
  lIncident.Category := TMachineOverviewIncidentCategory.UserMarked;
  lIncident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
  lIncident.Severity := TMachineOverviewSeverity.Notice;
  if not ShouldCaptureMachineOverviewTrace(lIncident) then
  begin
    Writeln('SELFTEST FAILED: a user-marked incident did not qualify for a trace');
    Exit;
  end;
  lIncident.Origin := TMachineOverviewIncidentOrigin.Automatic;
  lIncident.Category := TMachineOverviewIncidentCategory.DpcInterrupt;
  lIncident.Severity := TMachineOverviewSeverity.Warning;
  if not ShouldCaptureMachineOverviewTrace(lIncident) then
  begin
    Writeln('SELFTEST FAILED: a DPC/ISR incident did not qualify for diagnostic tracing');
    Exit;
  end;
  lIncident.Category := TMachineOverviewIncidentCategory.ForegroundResponse;
  lIncident.Severity := TMachineOverviewSeverity.Critical;
  if not ShouldCaptureMachineOverviewTrace(lIncident) then
  begin
    Writeln('SELFTEST FAILED: a critical incident did not qualify for a trace');
    Exit;
  end;
  lIncident.Category := TMachineOverviewIncidentCategory.HighCpu;
  lIncident.Severity := TMachineOverviewSeverity.Warning;
  if ShouldCaptureMachineOverviewTrace(lIncident) then
  begin
    Writeln('SELFTEST FAILED: an ordinary warning triggered an expensive trace');
    Exit;
  end;
  Result := 0;
end;

function RunTraceCommandSelfTest: Integer;
var
  lCommand: TMachineOverviewTraceCommand;
  lConfig: TMachineOverviewTraceConfig;
  lIncident: TMachineOverviewIncident;
begin
  Result := 1;
  lConfig := TMachineOverviewTraceConfig.Defaults;
  lConfig.OutputDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview trace output');
  lIncident := Default(TMachineOverviewIncident);
  lIncident.StableId := '..\bad " incident / id';
  lIncident.StartedAtUtc := EncodeDate(2026, 8, 29) +
    EncodeTime(9, 8, 7, 654);
  lCommand := BuildMachineOverviewTraceCommand(lConfig, lIncident, 4242);
  if (lCommand.InstanceName <> 'ActiveAppViewMachineOverview_4242') or
    (not StartsText(IncludeTrailingPathDelimiter(
      TPath.GetFullPath(lConfig.OutputDirectory)),
      TPath.GetFullPath(lCommand.TraceFileName))) or
    (not SameText(ExtractFileExt(lCommand.TraceFileName), '.etl')) or
    ContainsText(ExtractFileName(lCommand.TraceFileName), '..') or
    ContainsText(ExtractFileName(lCommand.TraceFileName), '"') or
    ContainsText(ExtractFileName(lCommand.TraceFileName), '/') or
    (not ContainsText(lCommand.StartArguments, 'GeneralProfile.light')) or
    (not ContainsText(lCommand.StartArguments, 'GPU.light')) or
    (not ContainsText(lCommand.StartArguments, '-filemode')) or
    (not ContainsText(lCommand.StartArguments, '-recordtempto')) or
    (not EndsText('-instancename ActiveAppViewMachineOverview_4242',
      lCommand.StartArguments)) or
    ContainsText(lCommand.FallbackStartArguments, 'GPU.light') or
    (not ContainsText(lCommand.StopArguments, '-skipPdbGen')) or
    (not EndsText('-instancename ActiveAppViewMachineOverview_4242',
      lCommand.StopArguments)) or
    (lCommand.CancelArguments <>
      '-cancel -instancename ActiveAppViewMachineOverview_4242') then
  begin
    Writeln('SELFTEST FAILED: WPR arguments or trace path were not safely constructed');
    Exit;
  end;
  Result := 0;
end;

function RunTraceDiagnosticSelfTest: Integer;
var
  lDiagnostic: string;
begin
  Result := 1;
  lDiagnostic := SanitizeMachineOverviewTraceDiagnostic(
    'first'#13#10'second "secret" C:\Users\private\token');
  if ContainsText(lDiagnostic, #13) or ContainsText(lDiagnostic, #10) or
    ContainsText(lDiagnostic, 'C:\Users\private') or
    (Length(lDiagnostic) > 512) then
  begin
    Writeln('SELFTEST FAILED: trace diagnostics retained multiline or private path content');
    Exit;
  end;
  Result := 0;
end;

function RunTraceRetentionSelfTest: Integer;
const
  cMinutesPerDay = 24 * 60;
var
  lConfig: TMachineOverviewTraceConfig;
  lErrorText: string;
  lFiles: TArray<string>;
  lRemovedCount: Integer;
  lRoot: string;
  i: Integer;
begin
  Result := 1;
  lRoot := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-retention.' +
    IntToStr(GetCurrentProcessId));
  if TDirectory.Exists(lRoot) then
    TDirectory.Delete(lRoot, True);
  TDirectory.CreateDirectory(lRoot);
  try
    for i := 1 to 4 do
    begin
      TFile.WriteAllBytes(TPath.Combine(lRoot, Format('trace-%d.etl', [i])),
        TBytes.Create(i, i, i, i));
      TFile.SetLastWriteTimeUtc(TPath.Combine(lRoot,
        Format('trace-%d.etl', [i])),
        Now + ((i - 10) / cMinutesPerDay));
    end;
    TFile.WriteAllText(TPath.Combine(lRoot, 'keep.txt'), 'not a trace');
    lConfig := TMachineOverviewTraceConfig.Defaults;
    lConfig.OutputDirectory := lRoot;
    lConfig.MaximumTraceCount := 2;
    lConfig.MaximumTraceBytes := 8;
    if (not EnforceMachineOverviewTraceRetention(lConfig,
        lRemovedCount, lErrorText)) or (lRemovedCount <> 2) or
      (not lErrorText.IsEmpty) then
    begin
      Writeln('SELFTEST FAILED: trace retention did not report exact bounded cleanup');
      Exit;
    end;
    lFiles := TDirectory.GetFiles(lRoot, '*.etl',
      TSearchOption.soTopDirectoryOnly);
    if (Length(lFiles) <> 2) or
      (not TFile.Exists(TPath.Combine(lRoot, 'trace-3.etl'))) or
      (not TFile.Exists(TPath.Combine(lRoot, 'trace-4.etl'))) or
      (not TFile.Exists(TPath.Combine(lRoot, 'keep.txt'))) then
    begin
      Writeln('SELFTEST FAILED: trace retention did not remove oldest ETL files only');
      Exit;
    end;
  finally
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
  Result := 0;
end;

function CreateTraceIncident(const aStableId: string;
  const aKind: TMachineOverviewIncidentChangeKind):
  TMachineOverviewIncidentChange;
begin
  Result := Default(TMachineOverviewIncidentChange);
  Result.Kind := aKind;
  Result.Incident.StableId := aStableId;
  Result.Incident.Category := TMachineOverviewIncidentCategory.DpcInterrupt;
  Result.Incident.Origin := TMachineOverviewIncidentOrigin.Automatic;
  Result.Incident.Severity := TMachineOverviewSeverity.Warning;
  Result.Incident.StartedAtUtc := EncodeDate(2026, 8, 29) +
    EncodeTime(9, 30, 0, 0);
  Result.Incident.TraceStatus :=
    TMachineOverviewIncidentTraceStatus.NotRequested;
end;

function RunTracePipelineQueueSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lDiagnostics: TMachineOverviewPipelineDiagnostics;
  lPipeline: TMachineOverviewPipeline;
  lPublished: TMachineOverviewIncidentChange;
  lTaken: TMachineOverviewIncidentChange;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  lChange := CreateTraceIncident('disabled',
    TMachineOverviewIncidentChangeKind.Started);
  if lPipeline.TryRequestDetailedTrace(lChange) or
    (lChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.NotRequested) then
  begin
    Writeln('SELFTEST FAILED: disabled detailed tracing accepted a request');
    Exit;
  end;
  lPipeline.SetDetailedTraceEnabled(True);
  lChange := CreateTraceIncident('update',
    TMachineOverviewIncidentChangeKind.Updated);
  if lPipeline.TryRequestDetailedTrace(lChange) then
  begin
    Writeln('SELFTEST FAILED: a non-start incident update requested a second trace');
    Exit;
  end;
  lChange := CreateTraceIncident('accepted',
    TMachineOverviewIncidentChangeKind.Started);
  if (not lPipeline.TryRequestDetailedTrace(lChange)) or
    (lChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Requested) or
    (not lPipeline.TryTakeDetailedTrace(lTaken)) or
    (lTaken.Incident.StableId <> 'accepted') then
  begin
    Writeln('SELFTEST FAILED: a qualifying trace request was not transported exactly once');
    Exit;
  end;
  lPublished := lTaken;
  lPublished.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lPublished.HasEvidenceUpdate := True;
  lPublished.Incident.Evidence.State := TMachineOverviewEvidenceState.Collecting;
  lPublished.Incident.Evidence.ProcessIntervalMs := 5000;
  lPublished.Incident.TraceStatus :=
    TMachineOverviewIncidentTraceStatus.Captured;
  lPipeline.PublishDetailedTraceResult(lPublished);
  if (not lPipeline.TryTakeIncident(lTaken)) or
    (lTaken.Incident.StableId <> 'accepted') or
    (lTaken.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Captured) or
    lTaken.HasEvidenceUpdate or (lTaken.Incident.Evidence.ProcessIntervalMs <> 0) or
    (lPipeline.IncidentCount <> 1) then
  begin
    Writeln('SELFTEST FAILED: a trace result was not published for history and presentation');
    Exit;
  end;
  for i := 1 to 16 do
  begin
    lChange := CreateTraceIncident('queued-' + IntToStr(i),
      TMachineOverviewIncidentChangeKind.Started);
    if not lPipeline.TryRequestDetailedTrace(lChange) then
    begin
      Writeln('SELFTEST FAILED: trace queue rejected an item before its fixed capacity');
      Exit;
    end;
  end;
  lChange := CreateTraceIncident('overflow',
    TMachineOverviewIncidentChangeKind.Started);
  if lPipeline.TryRequestDetailedTrace(lChange) or
    (lChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Failed) then
  begin
    Writeln('SELFTEST FAILED: trace queue overflow was not bounded and explicit');
    Exit;
  end;
  lDiagnostics := lPipeline.Diagnostics;
  if (lDiagnostics.TraceAccepted <> 17) or
    (lDiagnostics.TraceDequeued <> 1) or
    (lDiagnostics.TraceDropped <> 1) or
    (lDiagnostics.TraceQueueDepth <> 16) then
  begin
    Writeln(Format(
      'SELFTEST FAILED: trace queue accounting accepted=%d dequeued=%d dropped=%d depth=%d',
      [lDiagnostics.TraceAccepted, lDiagnostics.TraceDequeued,
       lDiagnostics.TraceDropped, lDiagnostics.TraceQueueDepth]));
    Exit;
  end;
  Result := 0;
end;

function CreateTraceDpcSample(const aUtc: TDateTime;
  const aMonotonicMs: UInt64): IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := 'windows-core';
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtUtc := aUtc;
  lSample.State.CapturedAtMonotonicMs := aMonotonicMs;
  SetLength(lSample.Measurements, 2);
  lSample.Measurements[0].Name := 'dpc_percent';
  lSample.Measurements[0].Available := True;
  lSample.Measurements[0].Value := 20;
  lSample.Measurements[1].Name := 'interrupt_percent';
  lSample.Measurements[1].Available := True;
  lSample.Measurements[1].Value := 2;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function RunTraceAggregatorIntegrationSelfTest: Integer;
var
  g: TGarbos;
  lHistoryChange: TMachineOverviewIncidentChange;
  lPipeline: TMachineOverviewPipeline;
  lTraceChange: TMachineOverviewIncidentChange;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  lPipeline.SetDetailedTraceEnabled(True);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(1000) then
    Exit;
  lUtc := EncodeDate(2026, 8, 29) + EncodeTime(10, 0, 0, 0);
  if (lPipeline.EnqueueRaw(CreateTraceDpcSample(lUtc, 1000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (lPipeline.EnqueueRaw(CreateTraceDpcSample(IncSecond(lUtc, 6), 7000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (not lPipeline.WaitForSequence(2, 5000)) or
    (not lPipeline.TryTakeIncident(lHistoryChange)) or
    (not lPipeline.TryTakeDetailedTrace(lTraceChange)) or
    (lHistoryChange.Kind <> TMachineOverviewIncidentChangeKind.Started) or
    (lHistoryChange.Incident.Category <>
      TMachineOverviewIncidentCategory.DpcInterrupt) or
    (lHistoryChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Requested) or
    (lTraceChange.Incident.StableId <>
      lHistoryChange.Incident.StableId) or
    (lTraceChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Requested) then
  begin
    Writeln('SELFTEST FAILED: aggregator did not publish and queue the requested DPC trace state');
    Exit;
  end;
  if lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: trace-enabled aggregator did not stop within its bound');
    Exit;
  end;
  Result := 0;
end;

function RunTraceProcessCancellationSelfTest: Integer;
var
  g: TGarbos;
  lCancellationEvent: TEvent;
  lProcessHandle: THandle;
  lResult: TMachineOverviewProcessResult;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lCancellationEvent, TEvent.Create(nil, True, True, ''), g);
  lResult := RunMachineOverviewBoundedProcessCancelable(ParamStr(0),
    cMachineOverviewTraceTimeoutChildArg, 2000, 4096,
    NativeUInt(lCancellationEvent.Handle));
  if (not lResult.Started) or (not lResult.Cancelled) or lResult.TimedOut or
    (lResult.DurationMs >= 1000) or (lResult.ProcessId = 0) then
  begin
    Writeln(Format(
      'SELFTEST FAILED: trace helper cancellation started=%d cancelled=%d timedout=%d duration=%d pid=%d',
      [Ord(lResult.Started), Ord(lResult.Cancelled), Ord(lResult.TimedOut),
       lResult.DurationMs, lResult.ProcessId]));
    Exit;
  end;
  lProcessHandle := OpenProcess(SYNCHRONIZE, False, lResult.ProcessId);
  if lProcessHandle <> 0 then
  try
    if WaitForSingleObject(lProcessHandle, 0) <> WAIT_OBJECT_0 then
    begin
      Writeln('SELFTEST FAILED: cancelled trace helper process remained alive');
      Exit;
    end;
  finally
    CloseHandle(lProcessHandle);
  end;
  Result := 0;
end;

function WaitForTraceOutcome(const aService: TMachineOverviewTraceService;
  const aTimeoutMs: Cardinal;
  out aDiagnostics: TMachineOverviewTraceDiagnostics): Boolean;
var
  g: TGarbos;
  lDeadlineMs: UInt64;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := False;
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  lDeadlineMs := GetTickCount64 + aTimeoutMs;
  repeat
    aDiagnostics := aService.Diagnostics;
    if aDiagnostics.Captured + aDiagnostics.Failed +
      aDiagnostics.Unavailable > 0 then
      Exit(True);
    lWaitEvent.WaitFor(10);
  until GetTickCount64 >= lDeadlineMs;
end;

function RunDisabledTraceServiceSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewTraceConfig;
  lPipeline: TMachineOverviewPipeline;
  lService: TMachineOverviewTraceService;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  lConfig := TMachineOverviewTraceConfig.Defaults;
  GC(lService, TMachineOverviewTraceService.Create(lPipeline, lConfig), g);
  lService.Start;
  if lService.WaitUntilRunning(100) or
    (lService.Diagnostics.ActiveWorkerCount <> 0) or
    (lService.Stop(100) <> TMachineOverviewShutdownResult.Stopped) then
  begin
    Writeln('SELFTEST FAILED: disabled detailed tracing started a worker');
    Exit;
  end;
  Result := 0;
end;

function RunUnavailableTraceServiceSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewTraceConfig;
  lDiagnostics: TMachineOverviewTraceDiagnostics;
  lPipeline: TMachineOverviewPipeline;
  lPublished: TMachineOverviewIncidentChange;
  lRoot: string;
  lService: TMachineOverviewTraceService;
begin
  g := Default(TGarbos);
  Result := 1;
  lRoot := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-unavailable.' +
    IntToStr(GetCurrentProcessId));
  if TDirectory.Exists(lRoot) then
    TDirectory.Delete(lRoot, True);
  try
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lPipeline.SetDetailedTraceEnabled(True);
    lChange := CreateTraceIncident('missing-wpr',
      TMachineOverviewIncidentChangeKind.Started);
    if not lPipeline.TryRequestDetailedTrace(lChange) then
      raise EInvalidOpException.Create('Trace request setup failed');
    lConfig := TMachineOverviewTraceConfig.Defaults;
    lConfig.Enabled := True;
    lConfig.CaptureDurationMs := 100;
    lConfig.CommandTimeoutMs := 500;
    lConfig.OutputDirectory := lRoot;
    lConfig.WprFileName := TPath.Combine(lRoot, 'missing-wpr.exe');
    GC(lService, TMachineOverviewTraceService.Create(lPipeline, lConfig), g);
    lService.Start;
    if (not lService.WaitUntilRunning(1000)) or
      (not WaitForTraceOutcome(lService, 2000, lDiagnostics)) or
      (lDiagnostics.Unavailable <> 1) or
      (lDiagnostics.Requested <> 1) or
      lDiagnostics.LastError.IsEmpty or
      (not lPipeline.TryTakeIncident(lPublished)) or
      (lPublished.Incident.TraceStatus <>
        TMachineOverviewIncidentTraceStatus.Unavailable) then
    begin
      Writeln('SELFTEST FAILED: missing WPR did not publish an explicit unavailable trace result');
      Exit;
    end;
    if (lService.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) or
      (lService.Diagnostics.ActiveWorkerCount <> 0) then
    begin
      Writeln('SELFTEST FAILED: unavailable trace worker did not stop within its bound');
      Exit;
    end;
  finally
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
  Result := 0;
end;

function RunFailedTraceStartSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewTraceConfig;
  lDiagnostics: TMachineOverviewTraceDiagnostics;
  lPipeline: TMachineOverviewPipeline;
  lRoot: string;
  lService: TMachineOverviewTraceService;
begin
  g := Default(TGarbos);
  Result := 1;
  lRoot := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-start-failure.' +
    IntToStr(GetCurrentProcessId));
  if TDirectory.Exists(lRoot) then
    TDirectory.Delete(lRoot, True);
  try
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lPipeline.SetDetailedTraceEnabled(True);
    lChange := CreateTraceIncident('start-failure',
      TMachineOverviewIncidentChangeKind.Started);
    if not lPipeline.TryRequestDetailedTrace(lChange) then
      raise EInvalidOpException.Create('Trace request setup failed');
    lConfig := TMachineOverviewTraceConfig.Defaults;
    lConfig.Enabled := True;
    lConfig.CaptureDurationMs := 100;
    lConfig.CommandTimeoutMs := 500;
    lConfig.OutputDirectory := lRoot;
    lConfig.WprFileName := TPath.Combine(GetEnvironmentVariable('WINDIR'),
      'System32\where.exe');
    GC(lService, TMachineOverviewTraceService.Create(lPipeline, lConfig), g);
    lService.Start;
    if (not lService.WaitUntilRunning(1000)) or
      (not WaitForTraceOutcome(lService, 3000, lDiagnostics)) or
      (lDiagnostics.Failed <> 1) or lDiagnostics.LastError.IsEmpty then
    begin
      Writeln('SELFTEST FAILED: WPR start failure did not publish a failed trace result');
      Exit;
    end;
    if lService.Stop(2000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: failed trace worker did not stop within its bound');
      Exit;
    end;
  finally
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
  Result := 0;
end;

function RunEnabledTraceServiceOwnershipSelfTest: Integer;
var
  g: TGarbos;
  lDatabaseFileName: string;
  lDeadlineMs: UInt64;
  lService: IMachineOverviewService;
  lSettings: TMachineOverviewSettings;
  lTraceConfig: TMachineOverviewTraceConfig;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lDatabaseFileName := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-service.' +
    IntToStr(GetCurrentProcessId) + '.db');
  if TFile.Exists(lDatabaseFileName) then
    TFile.Delete(lDatabaseFileName);
  lSettings := TMachineOverviewSettings.Defaults;
  lSettings.Enabled := True;
  lSettings.DetailedTraceEnabled := True;
  lSettings.HistoryDatabaseFileName := lDatabaseFileName;
  lSettings.HistoryCommitIntervalMs := 50;
  lSettings.ProcessSampleIntervalMs := 100;
  lSettings.SystemSampleIntervalMs := 100;
  lSettings.TemperatureSampleIntervalMs := 100;
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  lTraceConfig := TMachineOverviewTraceConfig.Defaults;
  lTraceConfig.OutputDirectory := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.trace-owner.' + TGUID.NewGuid.ToString);
  lTraceConfig.Runner := function(const aArgs: string; const aTimeout: Cardinal;
    const aCancel: NativeUInt): TMachineOverviewProcessResult
    begin
      Result := Default(TMachineOverviewProcessResult);
      Result.Started := True;
      Result.ExitCode := 1;
      Result.OutputText := 'injected access is denied';
    end;
  lService := CreateMachineOverviewService(lSettings, lTraceConfig);
  try
    lService.Start;
    lDeadlineMs := GetTickCount64 + 3000;
    while (lService.ActiveWorkerCount < 8) and
      (GetTickCount64 < lDeadlineMs) do
      lWaitEvent.WaitFor(10);
    if lService.ActiveWorkerCount <> 8 then
    begin
      Writeln(Format(
        'SELFTEST FAILED: enabled trace coordinator worker count was %d instead of 8',
        [lService.ActiveWorkerCount]));
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: trace-enabled service shutdown exceeded its shared bound');
      Exit;
    end;
    if lService.ActiveWorkerCount <> 0 then
    begin
      Writeln('SELFTEST FAILED: trace coordinator survived service shutdown');
      Exit;
    end;
  finally
    lService := nil;
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TDirectory.Exists(lTraceConfig.OutputDirectory) then
      TDirectory.Delete(lTraceConfig.OutputDirectory, True);
  end;
  Result := 0;
end;

procedure WriteFakeTraceFile(const aArgs: string);
var
  lEnd: Integer;
begin
  lEnd := PosEx('"', aArgs, 8);
  TFile.WriteAllText(Copy(aArgs, 8, lEnd - 8), 'fake ETL; never a recording');
end;

function RunFakeWprTraceSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewTraceConfig;
  lDiagnostics: TMachineOverviewTraceDiagnostics;
  lPipeline: TMachineOverviewPipeline;
  lPublished: TMachineOverviewIncidentChange;
  lRoot: string;
  lService: TMachineOverviewTraceService;
begin
  g := Default(TGarbos);
  Result := 1;
  lConfig := TMachineOverviewTraceConfig.Defaults;
  lRoot := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-live.' +
    IntToStr(GetCurrentProcessId));
  if TDirectory.Exists(lRoot) then
    TDirectory.Delete(lRoot, True);
  try
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lPipeline.SetDetailedTraceEnabled(True);
    lChange := CreateTraceIncident('live-wpr',
      TMachineOverviewIncidentChangeKind.Started);
    if not lPipeline.TryRequestDetailedTrace(lChange) then
      raise EInvalidOpException.Create('Trace request setup failed');
    lConfig.Runner := function(const aArgs: string; const aTimeout: Cardinal;
      const aCancel: NativeUInt): TMachineOverviewProcessResult
      begin
        Result := Default(TMachineOverviewProcessResult);
        Result.Started := True;
        if StartsText('-stop ', aArgs) then
        begin
          WriteFakeTraceFile(aArgs);
        end;
      end;
    lConfig.Enabled := True;
    lConfig.CaptureDurationMs := 1000;
    lConfig.CommandTimeoutMs := 15000;
    lConfig.MaximumTraceCount := 2;
    lConfig.MaximumTraceBytes := UInt64(512) * 1024 * 1024;
    lConfig.OutputDirectory := lRoot;
    GC(lService, TMachineOverviewTraceService.Create(lPipeline, lConfig), g);
    lService.Start;
    if (not lService.WaitUntilRunning(1000)) or
      (not WaitForTraceOutcome(lService, 30000, lDiagnostics)) or
      (not lPipeline.TryTakeIncident(lPublished)) then
    begin
      Writeln('SELFTEST FAILED: installed WPR did not produce a bounded explicit outcome');
      Exit;
    end;
    if lPublished.Incident.TraceStatus =
      TMachineOverviewIncidentTraceStatus.Captured then
    begin
      if (lDiagnostics.Captured <> 1) or
        lDiagnostics.LastTraceFileName.IsEmpty or
        (not TFile.Exists(lDiagnostics.LastTraceFileName)) or
        (TFile.GetSize(lDiagnostics.LastTraceFileName) <= 0) or
        (not lDiagnostics.LastError.IsEmpty) then
      begin
        Writeln('SELFTEST FAILED: WPR reported captured without a clean non-empty ETL');
        Exit;
      end;
    end else if lPublished.Incident.TraceStatus =
      TMachineOverviewIncidentTraceStatus.Unavailable then
    begin
      if (lDiagnostics.Unavailable <> 1) or
        ((not ContainsText(lDiagnostics.LastError, 'access')) and
         (not ContainsText(lDiagnostics.LastError, 'administrator')) and
         (not ContainsText(lDiagnostics.LastError, 'elevation')) and
         (not ContainsText(lDiagnostics.LastError, 'privilege')) and
         (not ContainsText(lDiagnostics.LastError,
           'profile system performance'))) then
      begin
        Writeln('SELFTEST FAILED: WPR unavailability was not an explicit least-privilege result');
        Exit;
      end;
    end else
    begin
      Writeln('SELFTEST FAILED: installed WPR failed instead of capturing or degrading for privilege');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: live WPR coordinator did not stop within its bound');
      Exit;
    end;
  finally
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
  Result := 0;
end;

function RunTraceHistoryPersistenceSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewTraceConfig;
  lDatabaseConfig: TMachineOverviewHistoryConfig;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewTraceDiagnostics;
  lErrorText: string;
  lHistory: TMachineOverviewHistoryService;
  lHistoryDiagnostics: TMachineOverviewHistoryDiagnostics;
  lIncidents: TArray<TMachineOverviewIncident>;
  lPipeline: TMachineOverviewPipeline;
  lRoot: string;
  lService: TMachineOverviewTraceService;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lRoot := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.machine-overview.trace-history.' +
    IntToStr(GetCurrentProcessId));
  lDatabaseFileName := TPath.Combine(lRoot, 'trace-history.db');
  if TDirectory.Exists(lRoot) then
    TDirectory.Delete(lRoot, True);
  TDirectory.CreateDirectory(lRoot);
  lPipeline := nil;
  lHistory := nil;
  lService := nil;
  try
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lPipeline.SetDetailedTraceEnabled(True);
    lDatabaseConfig := Default(TMachineOverviewHistoryConfig);
    lDatabaseConfig.Enabled := True;
    lDatabaseConfig.DatabaseFileName := lDatabaseFileName;
    lDatabaseConfig.CommitIntervalMs := 50;
    lDatabaseConfig.QueueCapacity := 32;
    lDatabaseConfig.RawRetentionHours := 48;
    lDatabaseConfig.Rollup10sRetentionDays := 30;
    lDatabaseConfig.Rollup1mRetentionDays := 365;
    lDatabaseConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lDatabaseConfig.BusyTimeoutMs := 100;
    GC(lHistory, TMachineOverviewHistoryService.Create(lPipeline,
      lDatabaseConfig), g);
    lConfig := TMachineOverviewTraceConfig.Defaults;
    lConfig.Enabled := True;
    lConfig.CaptureDurationMs := 100;
    lConfig.CommandTimeoutMs := 500;
    lConfig.OutputDirectory := TPath.Combine(lRoot, 'traces');
    lConfig.WprFileName := TPath.Combine(lRoot, 'missing-wpr.exe');
    GC(lService, TMachineOverviewTraceService.Create(lPipeline, lConfig), g);
    lPipeline.Start;
    lHistory.Start;
    lService.Start;
    if (not lPipeline.WaitUntilRunning(1000)) or
      (not lHistory.WaitUntilInitialized(5000)) or
      (not lHistory.Diagnostics.Available) or
      (not lService.WaitUntilRunning(1000)) then
      Exit;
    lUtc := EncodeDate(2026, 8, 29) + EncodeTime(11, 0, 0, 0);
    if (lPipeline.EnqueueRaw(CreateTraceDpcSample(lUtc, 1000)) <>
        TMachineOverviewEnqueueResult.Queued) or
      (lPipeline.EnqueueRaw(CreateTraceDpcSample(IncSecond(lUtc, 6), 7000)) <>
        TMachineOverviewEnqueueResult.Queued) or
      (not lPipeline.WaitForSequence(2, 5000)) or
      (not WaitForTraceOutcome(lService, 3000, lDiagnostics)) or
      (lDiagnostics.Unavailable <> 1) then
    begin
      Writeln('SELFTEST FAILED: trace persistence fixture did not reach unavailable outcome');
      Exit;
    end;
    if not lHistory.Flush(5000) then
    begin
      lHistoryDiagnostics := lHistory.Diagnostics;
      Writeln(Format(
        'SELFTEST FAILED: trace persistence flush timed out: queue=%d accepted=%d persisted=%d error=%s',
        [lHistoryDiagnostics.QueueDepth, lHistoryDiagnostics.Accepted,
         lHistoryDiagnostics.Persisted, lHistoryDiagnostics.LastError]));
      Exit;
    end;
    lPipeline.SetDetailedTraceEnabled(False);
    if (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (lHistory.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
    begin
      Writeln('SELFTEST FAILED: persisted trace integration did not shut down cleanly');
      Exit;
    end;
    if (not TryLoadMachineOverviewIncidents(lDatabaseFileName, 0, 10,
        lIncidents, lErrorText)) or (Length(lIncidents) <> 1) then
    begin
      Writeln(Format(
        'SELFTEST FAILED: trace persistence query count=%d error=%s',
        [Length(lIncidents), lErrorText]));
      Exit;
    end;
    if lIncidents[0].TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Unavailable then
    begin
      Writeln(Format(
        'SELFTEST FAILED: persisted trace status=%d instead of unavailable',
        [Ord(lIncidents[0].TraceStatus)]));
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lPipeline) then
      lPipeline.SetDetailedTraceEnabled(False);
    if Assigned(lService) and
      (lService.Stop(5000) = TMachineOverviewShutdownResult.TimedOut) then
      Writeln('SELFTEST INFO: trace cleanup timed out');
    if Assigned(lPipeline) and
      (lPipeline.Stop(5000) = TMachineOverviewShutdownResult.TimedOut) then
      Writeln('SELFTEST INFO: pipeline cleanup timed out');
    if Assigned(lHistory) and
      (lHistory.Stop(5000) = TMachineOverviewShutdownResult.TimedOut) then
      Writeln('SELFTEST INFO: history cleanup timed out');
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
end;

type
  TTraceSelfTest = function: Integer;
  TOnsetFixture = class
  private
    fLock: TCriticalSection;
    fCommands: TStringList;
    fRoot: string;
    fPipeline: TMachineOverviewPipeline;
    fService: TMachineOverviewTraceService;
    fStarts, fStops, fCancels, fBusyChecks: Integer;
    fStartError: string;
    fSessionPresent, fStartTimeout, fCancelFails, fPendingAtStart: Boolean;
    fLockRetention: Boolean;
    fRetentionHandle, fMarkerHandle: THandle;
    fUnknownStatus, fLegacyEnabled: Boolean;
    fFailureRetryMs: Cardinal;
    fCancelFailures: Integer;
    fStopFails, fLowDisk, fUnreadable, fGapRequest, fBlockStop: Boolean;
    fStopEntered, fStopRelease: TEvent;
    function Run(const aArgs: string; const aTimeout: Cardinal;
      const aCancel: NativeUInt): TMachineOverviewProcessResult;
    function Inspect(const aFileName: string): TMachineOverviewEtlInfo;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const aElevated: Boolean = True; const aEnabled: Boolean = True;
      const aStale: Boolean = False);
    function WaitState(const aState: TMachineOverviewOnsetTraceState): Boolean;
    function Request(const aKey: string; const aUser: Boolean = False): TMachineOverviewIncidentChange;
    function Count(const aPrefix: string): Integer;
    procedure CheckCommands;
    procedure WriteMarker(const aState: string; const aPreexisting: Boolean = False);
  end;

procedure TraceCheck(const aCondition: Boolean; const aMessage: string);
begin
  if not aCondition then
    raise EInvalidOpException.Create('SELFTEST FAILED: ' + aMessage);
end;

constructor TOnsetFixture.Create;
begin
  inherited Create;
  fFailureRetryMs := 100;
  fLock := TCriticalSection.Create;
  fCommands := TStringList.Create;
  fStopEntered := TEvent.Create(nil, True, False, '');
  fStopRelease := TEvent.Create(nil, True, False, '');
  fRoot := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.onset.' + TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(fRoot);
  fPipeline := TMachineOverviewPipeline.Create(16, 32);
end;

destructor TOnsetFixture.Destroy;
begin
  fStopRelease.SetEvent;
  fService.Free;
  if fMarkerHandle <> 0 then
    CloseHandle(fMarkerHandle);
  if fRetentionHandle <> 0 then
    CloseHandle(fRetentionHandle);
  fPipeline.Free;
  fStopEntered.Free;
  fStopRelease.Free;
  fCommands.Free;
  fLock.Free;
  TDirectory.Delete(fRoot, True);
  inherited Destroy;
end;

function TOnsetFixture.Run(const aArgs: string; const aTimeout: Cardinal;
  const aCancel: NativeUInt): TMachineOverviewProcessResult;
var
  lChange: TMachineOverviewIncidentChange;
begin
  fLock.Acquire;
  try
    fCommands.Add(aArgs);
    Result := Default(TMachineOverviewProcessResult);
    Result.Started := True;
    if aArgs = '-status' then
    begin
      if fBusyChecks > 0 then
      begin
        Dec(fBusyChecks);
        Result.OutputText := 'WPR is recording';
      end else
        Result.OutputText := 'WPR is not recording';
    end else if StartsText('-status ', aArgs) then
    begin
      if fUnknownStatus then
        Result.OutputText := 'injected unknown status'
      else if fSessionPresent then
        Result.OutputText := 'WPR is recording'
      else
        Result.OutputText := 'WPR is not recording';
    end
    else if StartsText('-start ', aArgs) then
    begin
      Inc(fStarts);
      fPendingAtStart := TFile.Exists(TPath.Combine(fRoot, 'onset-session.active'));
      if fPendingAtStart then
        fPendingAtStart := ContainsText(TFile.ReadAllText(TPath.Combine(fRoot, 'onset-session.active')),
          'ActiveAppViewOnset') and ContainsText(TFile.ReadAllText(
          TPath.Combine(fRoot, 'onset-session.active')), 'Pending');
      if fStartError.IsEmpty then
        fSessionPresent := True;
      Result.TimedOut := fStartTimeout;
      Result.OutputText := fStartError;
      if not fStartError.IsEmpty then
        Result.ExitCode := 1;
    end else if StartsText('-cancel ', aArgs) then
    begin
      Inc(fCancels);
      if fCancelFails or (fCancelFailures > 0) then
      begin
        if fCancelFailures > 0 then
          Dec(fCancelFailures);
        Result.ExitCode := 1;
        Result.OutputText := 'injected cancel failure';
      end else
        fSessionPresent := False;
    end
    else if StartsText('-stop ', aArgs) then
    begin
      Inc(fStops);
      TraceCheck((aTimeout = 120000) and (aCancel = 0), 'save must be bounded and not cancelled mid-stop');
      if fBlockStop then
      begin
        fStopEntered.SetEvent;
        TraceCheck(fStopRelease.WaitFor(3000) = wrSignaled, 'shutdown save fixture release timed out');
      end;
      if fGapRequest then
      begin
        lChange := CreateTraceIncident('during-save', TMachineOverviewIncidentChangeKind.Started);
        lChange.Incident.Category := TMachineOverviewIncidentCategory.HighCpu;
        TraceCheck(fPipeline.TryRequestDetailedTrace(lChange), 'save-gap fixture request');
      end;
      WriteFakeTraceFile(aArgs);
      if fLockRetention then
      begin
        fRetentionHandle := CreateFile(PChar(TPath.Combine(fRoot, 'old-00.etl')),
          GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
        TraceCheck(fRetentionHandle <> INVALID_HANDLE_VALUE, 'retention fixture lock');
      end;
      if fStopFails then
      begin
        Result.ExitCode := 1;
        Result.OutputText := 'injected'#13#10'save failure';
      end else
        fSessionPresent := False;
    end else
      raise EInvalidOpException.Create('Unexpected fake WPR command: ' + aArgs);
  finally
    fLock.Release;
  end;
end;

function TOnsetFixture.Inspect(const aFileName: string): TMachineOverviewEtlInfo;
begin
  Result := Default(TMachineOverviewEtlInfo);
  Result.Readable := not fUnreadable;
  Result.FirstEventUtc := IncSecond(TTimeZone.Local.ToUniversalTime(Now), -20);
  Result.LastEventUtc := TTimeZone.Local.ToUniversalTime(Now);
  Result.EventsLost := 3;
  Result.BuffersLost := 2;
  Result.ErrorText := 'injected unreadable ETL';
end;

procedure TOnsetFixture.Start(const aElevated, aEnabled, aStale: Boolean);
var
  lConfig: TMachineOverviewTraceConfig;
begin
  lConfig := TMachineOverviewTraceConfig.Defaults;
  lConfig.OnsetEnabled := aEnabled;
  lConfig.Enabled := fLegacyEnabled;
  lConfig.OutputDirectory := fRoot;
  lConfig.BusyRecheckMs := 50;
  lConfig.FailureRetryMs := fFailureRetryMs;
  lConfig.Runner := function(const aArgs: string; const aTimeout: Cardinal;
    const aCancel: NativeUInt): TMachineOverviewProcessResult
    begin
      Result := Run(aArgs, aTimeout, aCancel);
    end;
  lConfig.IsElevated := function: Boolean
    begin
      Result := aElevated;
    end;
  lConfig.InspectEtl := function(aFileName: string): TMachineOverviewEtlInfo
    begin
      Result := Inspect(aFileName);
    end;
  lConfig.FreeBytes := function(aPath: string): Int64
    begin
      if fLowDisk then
        Result := 1
      else
        Result := Int64(10) * 1024 * 1024 * 1024;
    end;
  if aStale then
  begin
    fSessionPresent := True;
    WriteMarker('Owned');
  end;
  fPipeline.SetDetailedTraceEnabled(aEnabled);
  fPipeline.SetOnsetTraceEnabled(aEnabled);
  fService := TMachineOverviewTraceService.Create(fPipeline, lConfig);
  fService.Start;
end;

function TOnsetFixture.WaitState(const aState: TMachineOverviewOnsetTraceState): Boolean;
var
  lDeadline: UInt64;
begin
  lDeadline := GetTickCount64 + 3000;
  repeat
    if fService.Diagnostics.OnsetState = aState then
      Exit(True);
    Sleep(5);
  until GetTickCount64 >= lDeadline;
  Result := False;
end;

function TOnsetFixture.Request(const aKey: string; const aUser: Boolean): TMachineOverviewIncidentChange;
var
  lChange: TMachineOverviewIncidentChange;
  lDeadline: UInt64;
  lDetector: TMachineOverviewIncidentDetector;
  lSignals: TMachineOverviewIncidentSignals;
begin
  lChange := CreateTraceIncident(aKey, TMachineOverviewIncidentChangeKind.Started);
  lChange.Incident.Category := TMachineOverviewIncidentCategory.HighCpu;
  lChange.Incident.Severity := TMachineOverviewSeverity.Warning;
  lChange.Incident.StartedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
  if aUser then
  begin
    lDetector := TMachineOverviewIncidentDetector.Create(TMachineOverviewIncidentThresholds.Defaults);
    try
      lSignals := Default(TMachineOverviewIncidentSignals);
      lSignals.CapturedAtUtc := lChange.Incident.StartedAtUtc;
      lChange := lDetector.MarkUserSlowdown(lSignals, aKey);
    finally
      lDetector.Free;
    end;
  end;
  TraceCheck(fPipeline.TryRequestDetailedTrace(lChange), 'onset policy did not queue ' + aKey);
  lDeadline := GetTickCount64 + 3000;
  repeat
    if fPipeline.TryTakeIncident(Result) then
      Exit;
    Sleep(5);
  until GetTickCount64 >= lDeadline;
  raise EInvalidOpException.Create('No onset result for ' + aKey);
end;

function TOnsetFixture.Count(const aPrefix: string): Integer;
var
  lCommand: string;
begin
  Result := 0;
  fLock.Acquire;
  try
    for lCommand in fCommands do
      if StartsText(aPrefix, lCommand) then
        Inc(Result);
  finally
    fLock.Release;
  end;
end;

procedure TOnsetFixture.WriteMarker(const aState: string; const aPreexisting: Boolean);
begin
  TFile.WriteAllText(TPath.Combine(fRoot, 'onset-session.active'),
    '{"instance":"ActiveAppViewOnset","state":"' + aState +
    '","createdUtc":"2026-10-21T22:00:00Z","PreexistingAtStart":' +
    LowerCase(BoolToStr(aPreexisting, True)) + ',"bufferMB":256}', TEncoding.ASCII);
end;

procedure TOnsetFixture.CheckCommands;
var
  lCommand: string;
begin
  fLock.Acquire;
  try
    for lCommand in fCommands do
      TraceCheck((lCommand = '-status') or EndsText('-instancename ActiveAppViewOnset', lCommand),
        'command escaped our WPR instance: ' + lCommand);
  finally
    fLock.Release;
  end;
end;

function RunOnsetTraceDisabledSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.Start(True, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Off) and (lFixture.Count('') = 0), 'onset default off');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'disabled shutdown');
  TraceCheck(lFixture.Count('') = 0, 'disabled without marker never queries or mutates WPR, including shutdown');
  Writeln('PASS onset disabled/no marker/no WPR commands');

end;

function RunOnsetTraceNotElevatedSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.Start(False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Unavailable), 'non-elevated state');
  lChange := lFixture.Request('not-elevated');
  TraceCheck((lFixture.Count('') = 0) and
    (lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Unavailable) and
    ContainsText(lChange.Incident.TraceDetail, 'needs administrator'), 'non-elevated outcome without WPR');
  Writeln('PASS onset not elevated');
  g.Clear;
  GC(lFixture, TOnsetFixture.Create, g);
  TFile.WriteAllText(TPath.Combine(lFixture.fRoot, 'onset-session.active'), '1024', TEncoding.ASCII);
  lFixture.Start(False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Unavailable) and
    (lFixture.Count('') = 0) and ContainsText(lFixture.fService.Diagnostics.OnsetStateText, '1024 MB'),
    'stale marker reports previous buffer size without WPR or elevation');

end;

function RunOnsetTraceBusySelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fBusyChecks := 2;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Busy) and (lFixture.Count('-start') = 0), 'busy waits');
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'busy recheck starts later');
  lFixture.CheckCommands;
  Writeln('PASS onset busy/recheck');

end;

function RunOnsetTraceStartSaveRestartSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'ring starts');
  lChange := lFixture.Request('save');
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Captured) and
    (not lChange.Incident.TraceFile.IsEmpty) and ContainsText(lChange.Incident.TraceDetail, 'includes onset') and
    ContainsText(lChange.Incident.TraceDetail, 'events lost 3') and
    ContainsText(lChange.Incident.TraceDetail, 'buffers lost 2') and
    (lFixture.Count('-start') = 2), 'save includes onset, losses, restart');
  lChange := lFixture.Request('cooldown');
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Skipped) and
    ContainsText(lChange.Incident.TraceDetail, 'cooldown') and (lFixture.Count('-stop') = 1), 'automatic cooldown');
  lChange := lFixture.Request('user', True);
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Captured) and
    (lFixture.Count('-stop') = 2), 'user mark bypasses cooldown');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'stop bounded');
  TraceCheck((lFixture.Count('-cancel') = 1) and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))), 'stop cancels owned ring and marker');
  lFixture.CheckCommands;
  Writeln('PASS onset start/save/restart/cooldown/user/cleanup');

end;

function RunOnsetTraceSaveFailureSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStopFails := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'failure fixture starts');
  lChange := lFixture.Request('save-failure');
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Failed) and
    ContainsText(lChange.Incident.TraceDetail, 'injected save failure') and
    (not ContainsText(lChange.Incident.TraceDetail, #13)) and (lFixture.Count('-start') = 2) and
    lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'save failure sanitized and restarts');
  lFixture.CheckCommands;
  Writeln('PASS onset save failure/restart');

end;

function RunOnsetTracePermissionFailureSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStartError := 'access is denied';
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Unavailable), 'access denied maps unavailable');
  Sleep(150);
  TraceCheck(lFixture.Count('-start') = 1, 'privilege failure no retry');
  Writeln('PASS onset start permission failure');

end;

function RunOnsetTraceStartFailureSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lDeadline: UInt64;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStartError := 'injected start failure';
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed) and
    (lFixture.Count('-start') = 1), 'start failure before retry delay');
  lDeadline := GetTickCount64 + 3000;
  while (lFixture.Count('-start') < 3) and (GetTickCount64 < lDeadline) do
    Sleep(5);
  TraceCheck(lFixture.Count('-start') = 3, 'three bounded start attempts');
  Sleep(150);
  TraceCheck(lFixture.Count('-start') = 3, 'no fourth start after the retry horizon');
  lFixture.CheckCommands;
  Writeln('PASS onset start failure retry bound');

end;

function RunOnsetTraceStaleSessionSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.Start(True, True, True);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording) and
    (lFixture.Count('-cancel') = 1) and (lFixture.Count('-start') = 1), 'stale owned session cancelled before restart');
  lFixture.CheckCommands;
  Writeln('PASS onset stale-session recovery');

end;

function RunOnsetTraceLowDiskSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fLowDisk := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'low disk starts ring');
  lChange := lFixture.Request('low-disk');
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Skipped) and
    ContainsText(lChange.Incident.TraceDetail, 'not enough free space') and (lFixture.Count('-stop') = 0), 'low disk skips save');
  Writeln('PASS onset low disk');

end;

function RunOnsetTraceUnreadableEtlSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fUnreadable := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'unreadable fixture starts');
  lChange := lFixture.Request('unreadable');
  TraceCheck((lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Failed) and
    ContainsText(lChange.Incident.TraceDetail, 'Cannot inspect onset ETL') and
    lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'unreadable ETL failure and restart');
  Writeln('PASS onset unreadable ETL/restart');

end;

function RunOnsetTraceSaveGapSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
  lPending: TMachineOverviewIncidentChange;
  lDeadline: UInt64;
  lDelivered: Boolean;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fGapRequest := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'save-gap fixture starts');
  lChange := lFixture.Request('gap');
  TraceCheck(lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Skipped,
    'incident queued during saving must be skipped');
  TraceCheck(ContainsText(lChange.Incident.TraceDetail, 'recording was restarting'), 'save-gap reason');
  lDeadline := GetTickCount64 + 3000;
  repeat
    lDelivered := lFixture.fPipeline.TryTakeIncident(lPending);
    if not lDelivered then
      Sleep(5);
  until lDelivered or (GetTickCount64 >= lDeadline);
  TraceCheck(lDelivered and
    (lPending.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Captured), 'original save still captured');
  Writeln('PASS onset save-gap incident');

end;

function RunOnsetTraceShutdownSaveSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fBlockStop := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'shutdown fixture starts');
  lChange := CreateTraceIncident('shutdown-save', TMachineOverviewIncidentChangeKind.Started);
  TraceCheck(lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'queue shutdown save');
  TraceCheck(lFixture.fStopEntered.WaitFor(3000) = wrSignaled, 'stop entered before shutdown');
  TraceCheck(lFixture.fService.Stop(10) = TMachineOverviewShutdownResult.TimedOut, 'bounded save waits on shutdown');
  lFixture.fStopRelease.SetEvent;
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'shutdown finishes bounded save');
  TraceCheck((lFixture.Count('-start') = 1) and (lFixture.Count('-cancel') = 0) and
    (not lFixture.fSessionPresent) and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))),
    'successful bounded stop confirms shutdown cleanup without restarting or redundant cancel');
  lFixture.CheckCommands;
  Writeln('PASS onset shutdown during save');

end;

function RunOnsetTraceProfileSelfTest: Integer;
var
  lInfo: TMachineOverviewEtlInfo;
  lConfig: TMachineOverviewTraceConfig;
  lProfile: string;
begin
  Result := 0;
  lConfig := TMachineOverviewTraceConfig.Defaults;
  lProfile := BuildMachineOverviewOnsetProfile(lConfig.OnsetBufferMB);
  TraceCheck(ContainsText(lProfile, 'Buffers Value="256"') and ContainsText(lProfile, 'LoggingMode="Memory"') and
    (not ContainsText(lProfile, 'CSwitch')) and ContainsText(BuildMachineOverviewOnsetProfile(32), 'Buffers Value="64"') and
    ContainsText(BuildMachineOverviewOnsetProfile(4096), 'Buffers Value="1024"'), 'bounded generated memory profile');
  lInfo := ReadMachineOverviewEtlInfo(TPath.Combine(TPath.GetTempPath, TGUID.NewGuid.ToString + '.etl'));
  TraceCheck((not lInfo.Readable) and (not lInfo.ErrorText.IsEmpty) and
    (not ContainsText(lInfo.ErrorText, 'layout mismatch')), 'ETL unreadable file fails explicitly with SDK-compatible layout');
  Writeln('PASS onset profile/clamp/ETL read failure');
end;
function RunOnsetPendingOwnershipSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStartTimeout := True;
  lFixture.fFailureRetryMs := 60000;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed), 'timed-out start failed state');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'timeout shutdown');
  TraceCheck(lFixture.fPendingAtStart and (lFixture.Count('-start') = 1) and
    (lFixture.Count('-status -instancename') >= 1) and (lFixture.Count('-cancel') = 1) and
    (not lFixture.fSessionPresent) and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))),
    'timeout after session creation must persist intent before start and cancel only the owned session');
  lFixture.CheckCommands;
  Writeln('PASS onset pending start timeout/shutdown ownership');
end;

function RunOnsetPendingRecoverySelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lCancels: Integer;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStartTimeout := True;
  lFixture.fCancelFails := True;
  lFixture.fFailureRetryMs := 60000;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed), 'uncertain start state');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'uncertain start shutdown');
  TraceCheck(lFixture.fSessionPresent and TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')),
    'unconfirmed cancellation must retain durable pending ownership for crash recovery');
  FreeAndNil(lFixture.fService);
  lCancels := lFixture.Count('-cancel');
  lFixture.fStartTimeout := False;
  lFixture.fCancelFails := False;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording) and
    (lFixture.Count('-cancel') = lCancels + 1) and (lFixture.Count('-start') = 2),
    'next start reconciles and cancels exactly the pending owned session before a new start');
  lFixture.CheckCommands;
  Writeln('PASS onset retained pending marker/next-start recovery');
end;

function RunOnsetRealUserMarkReplaySelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lDetector: TMachineOverviewIncidentDetector;
  lSignals: TMachineOverviewIncidentSignals;
  lOriginal, lChange, lTaken: TMachineOverviewIncidentChange;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  GC(lDetector, TMachineOverviewIncidentDetector.Create(TMachineOverviewIncidentThresholds.Defaults), g);
  lFixture.fPipeline.SetDetailedTraceEnabled(True);
  lFixture.fPipeline.SetOnsetTraceEnabled(True);
  lSignals := Default(TMachineOverviewIncidentSignals);
  lSignals.CapturedAtUtc := EncodeDate(2026, 10, 21);
  lOriginal := lDetector.MarkUserSlowdown(lSignals, 'real user mark');
  TraceCheck(lOriginal.Kind = TMachineOverviewIncidentChangeKind.Ended, 'actual detector terminal shape');
  lChange := lOriginal;
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'user update cannot trigger capture');
  lChange := lOriginal;
  lChange.Incident.Origin := TMachineOverviewIncidentOrigin.Automatic;
  TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'automatic terminal shape rejected');
  lChange := lOriginal;
  lChange.Incident.Category := TMachineOverviewIncidentCategory.HighCpu;
  TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'non-user category terminal rejected');
  lChange := lOriginal;
  lChange.Incident.EndedAtUtc := IncSecond(lChange.Incident.StartedAtUtc, 1);
  TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'non-instant terminal shape rejected');
  lChange := lOriginal;
  TraceCheck(lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'actual terminal user mark must queue');
  TraceCheck(lFixture.fPipeline.TryTakeDetailedTrace(lTaken), 'actual mark delivered');
  lTaken.Incident.TraceStatus := TMachineOverviewIncidentTraceStatus.Captured;
  lFixture.fPipeline.PublishDetailedTraceResult(lTaken);
  lChange := lOriginal;
  TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'terminal replay must not save twice');
  // The finalized-key contract retains exactly 4096 requests independently of headline pruning.
  for i := 1 to 4096 do
  begin
    lSignals.CapturedAtUtc := IncSecond(lSignals.CapturedAtUtc, 1);
    lChange := lDetector.MarkUserSlowdown(lSignals, 'bounded key');
    TraceCheck(lFixture.fPipeline.TryRequestDetailedTrace(lChange) and
      lFixture.fPipeline.TryTakeDetailedTrace(lTaken) and
      (lTaken.Incident.StableId = lChange.Incident.StableId), 'bounded request FIFO');
    if i = 4095 then
    begin
      lChange := lOriginal;
      TraceCheck(not lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'key survives through FIFO horizon');
    end;
  end;
  lChange := lOriginal;
  TraceCheck(lFixture.fPipeline.TryRequestDetailedTrace(lChange), 'old replay allowed after 4096-key horizon');
  Writeln('PASS onset real detector terminal user mark/replay/4096-key bound');
end;

function CheckOnsetFailedSaveRetention(const aPartial, aLocked: Boolean): Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lChange: TMachineOverviewIncidentChange;
  lName: string;
  lBytes: Int64;
  lStream: TFileStream;
  lOldWriteUtc: TDateTime;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fUnreadable := True;
  lFixture.fStopFails := aPartial;
  lFixture.fLockRetention := aLocked;
  lOldWriteUtc := EncodeDate(2026, 1, 1);
  for i := 0 to 9 do
  begin
    lName := TPath.Combine(lFixture.fRoot, Format('old-%.2d.etl', [i]));
    lStream := TFileStream.Create(lName, fmCreate);
    try
      lStream.Size := (Int64(2) * 1024 * 1024 * 1024) div 10;
      if i = 0 then
        lStream.Size := lStream.Size + (Int64(2) * 1024 * 1024 * 1024) mod 10;
    finally
      lStream.Free;
    end;
    TFile.SetLastWriteTimeUtc(lName, lOldWriteUtc);
    lOldWriteUtc := IncSecond(lOldWriteUtc);
  end;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording), 'retention fixture starts');
  lChange := lFixture.Request('failed-save-retention');
  TraceCheck(lChange.Incident.TraceStatus = TMachineOverviewIncidentTraceStatus.Failed, 'save failure status');
  if aPartial then
    TraceCheck(ContainsText(lChange.Incident.TraceDetail, 'injected save failure'), 'partial save error preserved')
  else
    TraceCheck(ContainsText(lChange.Incident.TraceDetail, 'Cannot inspect onset ETL'), 'parse error preserved');
  if aLocked then
    TraceCheck(ContainsText(lChange.Incident.TraceDetail, 'retention'),
      'parse/save error AND post-save retention failure must both be reported')
  else
  begin
    var lFiles := TDirectory.GetFiles(lFixture.fRoot, '*.etl');
    lBytes := 0;
    for lName in lFiles do
      Inc(lBytes, TFile.GetSize(lName));
    TraceCheck((Length(lFiles) <= 10) and (lBytes <= Int64(2) * 1024 * 1024 * 1024),
      'failed save at count and byte limits must enforce retention');
  end;
  Writeln(Format('PASS onset failed-save retention partial=%s locked=%s',
    [BoolToStr(aPartial, True), BoolToStr(aLocked, True)]));
end;

function RunOnsetUnreadableRetentionSelfTest: Integer;
begin
  Result := CheckOnsetFailedSaveRetention(False, False);
end;

function RunOnsetPartialRetentionSelfTest: Integer;
begin
  Result := CheckOnsetFailedSaveRetention(True, False);
end;

function RunOnsetRetentionErrorsSelfTest: Integer;
begin
  Result := CheckOnsetFailedSaveRetention(False, True);
end;

function RunOnsetPartialRetentionErrorsSelfTest: Integer;
begin
  Result := CheckOnsetFailedSaveRetention(True, True);
end;

function RunOnsetForeignSessionSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fSessionPresent := True;
  lFixture.fStartError := 'instance already exists';
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Busy), 'foreign instance must be reported');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'foreign fixture shutdown');
  TraceCheck(lFixture.fSessionPresent and (lFixture.Count('-start') = 0) and
    (lFixture.Count('-cancel') = 0) and (lFixture.Count('-stop') = 0) and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'instance name in use by another session') and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))),
    'foreign same-name recording must never be claimed, started over, stopped or cancelled');
  lFixture.CheckCommands;
  Writeln('PASS onset foreign same-name session/rejected-start protection');
end;

function RunOnsetCleanupTimerSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Owned');
  lFixture.fSessionPresent := True;
  lFixture.fCancelFailures := 1;
  lFixture.fFailureRetryMs := 200;
  lFixture.fStartError := 'access is denied';
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed) and
    TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')), 'failed cleanup retains marker');
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Unavailable),
    'marker retry timer must recover in the same service without an incident');
  TraceCheck((lFixture.Count('-cancel') = 2) and (lFixture.Count('-start') = 1) and
    (not lFixture.fSessionPresent) and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))),
    'timer retries cleanup to confirmed absence; definite rejection removes pending marker without cancel');
  lFixture.CheckCommands;
  Writeln('PASS onset marker-driven cleanup retry/definite rejection');
end;

function RunOnsetUncertainCrashMarkerSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lMarker: string;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.fStartTimeout := True;
  lFixture.fFailureRetryMs := 60000;
  lFixture.fCancelFails := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed), 'uncertain start state');
  lMarker := TFile.ReadAllText(TPath.Combine(lFixture.fRoot, 'onset-session.active'));
  TraceCheck(ContainsText(lMarker, '"state":"Pending"') and
    ContainsText(lMarker, '"PreexistingAtStart":false') and ContainsText(lMarker, '"createdUtc":') and
    (lFixture.Count('-cancel') = 0), 'uncertain completion retains structured Pending intent without immediate cancellation');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'crash model teardown');
  FreeAndNil(lFixture.fService);
  lFixture.fStartTimeout := False;
  lFixture.fCancelFails := False;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Recording) and
    (lFixture.Count('-cancel') = 2), 'fresh service reconciles only owned pending session after crash');
  lMarker := TFile.ReadAllText(TPath.Combine(lFixture.fRoot, 'onset-session.active'));
  TraceCheck(ContainsText(lMarker, '"state":"Owned"'), 'successful start persists Owned state');
  lFixture.CheckCommands;
  Writeln('PASS onset uncertain start/crash marker/next-start reconciliation');
end;

function RunOnsetStaleMarkerProvenanceSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Pending', True);
  lFixture.fSessionPresent := True;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Busy) and
    (lFixture.Count('-cancel') = 0) and lFixture.fSessionPresent,
    'PreexistingAtStart marker must never authorize cancellation');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'provenance fixture stop');
  FreeAndNil(lFixture.fService);
  lFixture.fSessionPresent := False;
  lFixture.fBusyChecks := 100;
  lFixture.Start;
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Busy) and
    (not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))) and
    (lFixture.Count('-cancel') = 0) and (lFixture.Count('-start') = 0),
    'confirmed no session plus stale marker removes marker without cancel');
  lFixture.CheckCommands;
  Writeln('PASS onset preexisting provenance/stale absent-session marker');
end;


function RunOnsetDisabledPendingSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lDeadline: UInt64;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Pending');
  lFixture.fSessionPresent := True;
  lFixture.Start(True, False);
  lDeadline := GetTickCount64 + 3000;
  while TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')) and
    (GetTickCount64 < lDeadline) do
    Sleep(5);
  TraceCheck((not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))) and
    (not lFixture.fSessionPresent) and (lFixture.Count('-cancel') = 1) and
    (lFixture.Count('-status ') = 2) and (lFixture.Count('-start') = 0) and (lFixture.Count('-stop') = 0),
    'disabled startup must reconcile Pending session to confirmed absence without starting a ring');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'disabled pending shutdown');
  lFixture.CheckCommands;
  Writeln('PASS onset disabled Pending startup recovery');
end;

function RunOnsetDisabledRetrySelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lDeadline: UInt64;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Owned');
  lFixture.fSessionPresent := True;
  lFixture.fCancelFailures := 2;
  lFixture.fFailureRetryMs := 100;
  lFixture.fLegacyEnabled := True;
  lFixture.Start(True, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed) and
    TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')) and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'may still hold') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, '256 MB') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'injected cancel failure'),
    'disabled cleanup failure must retain marker and report retained memory plus failure');
  lDeadline := GetTickCount64 + 3000;
  while TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')) and
    (GetTickCount64 < lDeadline) do
    Sleep(5);
  TraceCheck((not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))) and
    (not lFixture.fSessionPresent) and (lFixture.Count('-cancel') = 3) and
    (lFixture.Count('-start') = 0) and (lFixture.Count('-stop') = 0),
    'disabled timer retries failed cleanup until success, independently of legacy capture');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'disabled retry shutdown');
  lFixture.CheckCommands;
  Writeln('PASS onset disabled Owned cleanup retry/retained-memory diagnostic/legacy enabled');
end;

function RunOnsetDisabledShutdownSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Owned');
  lFixture.fSessionPresent := True;
  lFixture.fCancelFails := True;
  lFixture.fFailureRetryMs := 60000;
  lFixture.Start(True, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed), 'disabled startup cleanup failure');
  lFixture.fLock.Acquire;
  try
    lFixture.fCancelFails := False;
  finally
    lFixture.fLock.Release;
  end;
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'disabled shutdown cleanup');
  TraceCheck((not TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active'))) and
    (not lFixture.fSessionPresent) and (lFixture.Count('-cancel') = 2) and (lFixture.Count('-start') = 0),
    'disabled shutdown must reconcile marker without waiting for timer deadline');
  lFixture.CheckCommands;
  Writeln('PASS onset disabled shutdown reconciliation before retry deadline');
end;

function CheckOnsetDisabledInvalidMarker(const aUnreadable: Boolean): Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
  lMarkerName: string;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Owned');
  lMarkerName := TPath.Combine(lFixture.fRoot, 'onset-session.active');
  if aUnreadable then
  begin
    lFixture.fMarkerHandle := CreateFile(PChar(lMarkerName), GENERIC_READ, 0, nil, OPEN_EXISTING, 0, 0);
    TraceCheck(lFixture.fMarkerHandle <> INVALID_HANDLE_VALUE, 'unreadable marker fixture lock');
  end else
    TFile.WriteAllText(lMarkerName, '{invalid marker', TEncoding.ASCII);
  lFixture.fSessionPresent := True;
  lFixture.Start(True, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed) and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'may still hold') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, '1024 MB') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'cleanup failed'),
    'invalid marker must surface failure and conservative retained-memory diagnostic');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'invalid marker shutdown');
  TraceCheck(TFile.Exists(lMarkerName) and lFixture.fSessionPresent and
    (lFixture.Count('-status ') >= 2) and (lFixture.Count('-cancel') = 0) and
    (lFixture.Count('-start') = 0) and (lFixture.Count('-stop') = 0),
    'malformed/unreadable marker must fail closed at startup and shutdown, with no mutating commands');
  lFixture.CheckCommands;
  Writeln('PASS onset disabled invalid-marker fail-closed unreadable=' + BoolToStr(aUnreadable, True));
end;

function RunOnsetDisabledMalformedMarkerSelfTest: Integer;
begin
  Result := CheckOnsetDisabledInvalidMarker(False);
end;

function RunOnsetDisabledUnreadableMarkerSelfTest: Integer;
begin
  Result := CheckOnsetDisabledInvalidMarker(True);
end;

function RunOnsetDisabledUnknownStatusSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Pending');
  lFixture.fSessionPresent := True;
  lFixture.fUnknownStatus := True;
  lFixture.Start(True, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Failed) and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'status unknown') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'may still hold'),
    'unknown status must be reported with retained-memory diagnostic');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'unknown status shutdown');
  TraceCheck(TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')) and
    lFixture.fSessionPresent and (lFixture.Count('-status ') >= 2) and
    (lFixture.Count('-cancel') = 0) and (lFixture.Count('-start') = 0) and (lFixture.Count('-stop') = 0),
    'unknown status must preserve marker/session without cancel at startup and shutdown');
  lFixture.CheckCommands;
  Writeln('PASS onset disabled unknown-status fail-closed');
end;

function RunOnsetDisabledNotElevatedSelfTest: Integer;
var
  g: TGarbos;
  lFixture: TOnsetFixture;
begin
  g := Default(TGarbos);
  Result := 0;
  GC(lFixture, TOnsetFixture.Create, g);
  lFixture.WriteMarker('Owned');
  lFixture.fSessionPresent := True;
  lFixture.Start(False, False);
  TraceCheck(lFixture.WaitState(TMachineOverviewOnsetTraceState.Unavailable) and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, 'may still hold') and
    ContainsText(lFixture.fService.Diagnostics.OnsetStateText, '256 MB'), 'disabled non-elevated retained memory');
  TraceCheck(lFixture.fService.Stop(3000) = TMachineOverviewShutdownResult.Stopped, 'non-elevated disabled shutdown');
  TraceCheck(TFile.Exists(TPath.Combine(lFixture.fRoot, 'onset-session.active')) and
    lFixture.fSessionPresent and (lFixture.Count('') = 0), 'no WPR commands or elevation when cleanup unavailable');
  Writeln('PASS onset disabled non-elevated retained-memory diagnostic/no WPR');
end;

function RunOnsetTraceLifecycleSelfTests: Integer;
var
  lTest: TTraceSelfTest;
  lTests: TArray<TTraceSelfTest>;
begin
  Result := 0;
  lTests := [@RunOnsetDisabledPendingSelfTest, @RunOnsetDisabledRetrySelfTest, @RunOnsetDisabledShutdownSelfTest, @RunOnsetDisabledMalformedMarkerSelfTest, @RunOnsetDisabledUnreadableMarkerSelfTest, @RunOnsetDisabledUnknownStatusSelfTest, @RunOnsetDisabledNotElevatedSelfTest, @RunOnsetForeignSessionSelfTest, @RunOnsetCleanupTimerSelfTest, @RunOnsetUncertainCrashMarkerSelfTest, @RunOnsetStaleMarkerProvenanceSelfTest, @RunOnsetPendingOwnershipSelfTest, @RunOnsetPendingRecoverySelfTest, @RunOnsetRealUserMarkReplaySelfTest, @RunOnsetUnreadableRetentionSelfTest, @RunOnsetPartialRetentionSelfTest, @RunOnsetRetentionErrorsSelfTest, @RunOnsetPartialRetentionErrorsSelfTest, @RunOnsetTraceDisabledSelfTest, @RunOnsetTraceNotElevatedSelfTest, @RunOnsetTraceBusySelfTest, @RunOnsetTraceStartSaveRestartSelfTest, @RunOnsetTraceSaveFailureSelfTest, @RunOnsetTracePermissionFailureSelfTest, @RunOnsetTraceStartFailureSelfTest, @RunOnsetTraceStaleSessionSelfTest, @RunOnsetTraceLowDiskSelfTest, @RunOnsetTraceUnreadableEtlSelfTest, @RunOnsetTraceSaveGapSelfTest, @RunOnsetTraceShutdownSaveSelfTest, @RunOnsetTraceProfileSelfTest];
  for lTest in lTests do
  begin
    try
      Inc(Result, lTest());
    except
      on lException: Exception do
      begin
        Writeln(lException.Message);
        Inc(Result);
      end;
    end;
  end;
  Writeln(Format('Onset tracing: %d tests, %d failed, 0 skipped', [Length(lTests), Result]));
end;

function RunTraceStatusStickySelfTest: Integer;
var
  g: TGarbos;
  lPipeline: TMachineOverviewPipeline;
  lHistory: TMachineOverviewHistoryService;
  lConfig: TMachineOverviewHistoryConfig;
  lChange: TMachineOverviewIncidentChange;
  lStored: TMachineOverviewIncident;
  lHealth: TMachineOverviewHistoryHealth;
  lIncidents: TArray<TMachineOverviewIncident>;
  lRoot, lError: string;
begin
  g := Default(TGarbos);
  Result := 1;
  lRoot := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.trace-sticky.' + TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(lRoot);
  try
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lConfig := TMachineOverviewHistoryConfig.FromSettings(TMachineOverviewSettings.Defaults,
      TPath.Combine(lRoot, 'history.db'));
    lConfig.CommitIntervalMs := 50;
    GC(lHistory, TMachineOverviewHistoryService.Create(lPipeline, lConfig), g);
    lHistory.Start;
    if not lHistory.WaitUntilInitialized(5000) then
      raise EInvalidOpException.Create('Sticky fixture initialization failed');
    lChange := CreateTraceIncident('sticky', TMachineOverviewIncidentChangeKind.Updated);
    lChange.Incident.StartedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
    lChange.Incident.TraceStatus := TMachineOverviewIncidentTraceStatus.Captured;
    lChange.Incident.TraceFile := 'captured.etl';
    lChange.Incident.TraceDetail := 'includes onset; events lost 3';
    lPipeline.PublishDetailedTraceResult(lChange);
    lChange.Incident.TraceStatus := TMachineOverviewIncidentTraceStatus.NotRequested;
    lChange.Incident.TraceFile := '';
    lChange.Incident.TraceDetail := '';
    lPipeline.PublishDetailedTraceResult(lChange);
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.Incident.EndedAtUtc := IncSecond(lChange.Incident.StartedAtUtc, 30);
    lPipeline.PublishDetailedTraceResult(lChange);
    Result := 0;
    TraceCheck(lPipeline.TryGetIncident(lChange.Incident.StableId, lStored) and
      (lStored.TraceStatus = TMachineOverviewIncidentTraceStatus.Captured) and
      (lStored.TraceFile = 'captured.etl') and
      (lStored.TraceDetail = 'includes onset; events lost 3'), 'sticky trace in memory after Updated and Ended');
    lHistory.SetStatusText('onset-trace', 'Recording onset CPU trace');
    if not lHistory.Flush(5000) then
      raise EInvalidOpException.Create('Sticky fixture flush failed');
    if lHistory.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise EInvalidOpException.Create('Sticky fixture stop failed');
    TraceCheck(TryLoadMachineOverviewHistoryHealth(lConfig.DatabaseFileName, lHealth, lError) and
      ContainsText(lHealth.ProviderStatus, 'onset-trace=Recording onset CPU trace'), 'onset state persisted in health');
    if not TryLoadMachineOverviewIncidents(lConfig.DatabaseFileName, 0, 10, lIncidents, lError) then
      raise EInvalidOpException.Create(lError);
    if (Length(lIncidents) <> 1) or
      (lIncidents[0].TraceStatus <> TMachineOverviewIncidentTraceStatus.Captured) or
      (lIncidents[0].TraceFile <> 'captured.etl') or
      (lIncidents[0].TraceDetail <> 'includes onset; events lost 3') then
    begin
      Writeln('SELFTEST FAILED: detector updates reset captured trace fields in history');
      Result := 1;
    end;
    g.Clear;
  finally
    g.Clear;
    TDirectory.Delete(lRoot, True);
  end;
end;

function RunMachineOverviewTraceSelfTests(const aArg: string): Integer;
var
  lTestResult: Integer;
begin
  if SameText(aArg, '--self-test-machine-overview-tracing-profile') then
  begin
    Writeln(BuildMachineOverviewOnsetProfile(256));
    Exit(0);
  end;
  if SameText(aArg, '--self-test-machine-overview-tracing-sticky') then
  begin
    try
      Exit(RunTraceStatusStickySelfTest);
    except
      on lException: Exception do
      begin
        Writeln(lException.Message);
        Exit(1);
      end;
    end;
  end;
  if SameText(aArg, '--self-test-machine-overview-tracing-onset') then
    Exit(RunOnsetTraceLifecycleSelfTests);
  if SameText(aArg, cMachineOverviewTraceTimeoutChildArg) then
  begin
    Sleep(5000);
    Exit(0);
  end;
  if not SameText(aArg, cMachineOverviewTraceSelfTestArg) then
    Exit(-1);
  Result := 0;
  try
    lTestResult := RunTraceDefaultsSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTracePolicySelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceCommandSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceDiagnosticSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceRetentionSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTracePipelineQueueSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceAggregatorIntegrationSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceProcessCancellationSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunDisabledTraceServiceSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunUnavailableTraceServiceSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunFailedTraceStartSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunEnabledTraceServiceOwnershipSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunFakeWprTraceSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunOnsetTraceLifecycleSelfTests;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceStatusStickySelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
    lTestResult := RunTraceHistoryPersistenceSelfTest;
    if lTestResult <> 0 then
      Result := lTestResult;
  except
    on lException: Exception do
    begin
      Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
        lException.Message]));
      Result := 1;
    end;
  end;
end;

end.

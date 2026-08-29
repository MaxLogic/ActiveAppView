unit ActiveAppView.MachineOverview.Trace.SelfTests;

interface

function RunMachineOverviewTraceSelfTests(const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.IOUtils, System.StrUtils, System.SyncObjs,
  System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.BoundedProcess,
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
  lPublished.Incident.TraceStatus :=
    TMachineOverviewIncidentTraceStatus.Captured;
  lPipeline.PublishDetailedTraceResult(lPublished);
  if (not lPipeline.TryTakeIncident(lTaken)) or
    (lTaken.Incident.StableId <> 'accepted') or
    (lTaken.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.Captured) or
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
  lService := CreateMachineOverviewService(lSettings);
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
  end;
  Result := 0;
end;

function RunLiveWprTraceSelfTest: Integer;
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
  if not TFile.Exists(lConfig.WprFileName) then
    Exit(0);
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

function RunMachineOverviewTraceSelfTests(const aArg: string): Integer;
var
  lTestResult: Integer;
begin
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
    lTestResult := RunLiveWprTraceSelfTest;
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

unit ActiveAppView.MachineOverview.Incidents.SelfTests;

interface

function RunMachineOverviewIncidentSelfTests(const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.IOUtils, System.Math, System.StrUtils,
  System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewIncidentSelfTestArg = '--self-test-machine-overview-incidents';

function CreateCpuSignals(const aUtc: TDateTime;
  const aMonotonicMs: UInt64; const aCpuPercent: Double;
  const aSummary: string): TMachineOverviewIncidentSignals;
begin
  Result := Default(TMachineOverviewIncidentSignals);
  Result.CapturedAtUtc := aUtc;
  Result.CapturedAtMonotonicMs := aMonotonicMs;
  Result.TotalCpu.Available := True;
  Result.TotalCpu.Value := aCpuPercent;
  Result.ProviderId := 'windows-core';
  Result.ProviderFreshnessMs := 25;
  Result.ContextSummary := aSummary;
end;

function RunHighCpuIncidentSelfTest: Integer;
var
  g: TGarbos;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lDetector: TMachineOverviewIncidentDetector;
  lFirstId: string;
  lThresholds: TMachineOverviewIncidentThresholds;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lThresholds := TMachineOverviewIncidentThresholds.Defaults;
  GC(lDetector, TMachineOverviewIncidentDetector.Create(lThresholds), g);
  lUtc := EncodeDate(2026, 8, 28) + EncodeTime(23, 0, 0, 0);
  lChanges := lDetector.Accept(CreateCpuSignals(lUtc, 1000, 40,
    'normal pre-context'));
  if Length(lChanges) <> 0 then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(IncSecond(lUtc, 1), 2000,
    95, 'high begins'));
  if Length(lChanges) <> 0 then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, 1000 + lThresholds.HighCpuActivationDurationMs - 1),
    2000 + lThresholds.HighCpuActivationDurationMs - 1, 96,
    'high below activation duration'));
  if Length(lChanges) <> 0 then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, 1000 + lThresholds.HighCpuActivationDurationMs),
    2000 + lThresholds.HighCpuActivationDurationMs, 97,
    'high activates'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Started) or
    (lChanges[0].Incident.Category <>
      TMachineOverviewIncidentCategory.HighCpu) or
    (lChanges[0].Incident.Severity <> TMachineOverviewSeverity.Warning) or
    lChanges[0].Incident.StableId.IsEmpty or
    (not SameValue(lChanges[0].Incident.PeakValue, 97, 0.001)) or
    (Length(lChanges[0].Incident.PreContext) <> 4) or
    (lChanges[0].Incident.ProviderId <> 'windows-core') or
    (lChanges[0].Incident.ProviderFreshnessMs <> 25) or
    (lChanges[0].Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.NotRequested) or
    (lChanges[0].Incident.Origin <>
      TMachineOverviewIncidentOrigin.Automatic) or
    lChanges[0].Incident.LocalDisplayTime.IsEmpty then
  begin
    Writeln('SELFTEST FAILED: sustained high CPU did not create a complete incident');
    Exit;
  end;
  lFirstId := lChanges[0].Incident.StableId;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncSecond(lUtc, 20), 21000, 99, 'higher sustained peak'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Updated) or
    (lChanges[0].Incident.StableId <> lFirstId) or
    (not SameValue(lChanges[0].Incident.PeakValue, 99, 0.001)) then
  begin
    Writeln('SELFTEST FAILED: sustained high CPU duplicated or lost its peak');
    Exit;
  end;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncSecond(lUtc, 21), 22000, 74, 'recovery begins'));
  if Length(lChanges) <> 0 then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, 21000 + lThresholds.HighCpuRecoveryDurationMs),
    22000 + lThresholds.HighCpuRecoveryDurationMs, 70,
    'recovery complete'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Ended) or
    (lChanges[0].Incident.StableId <> lFirstId) or
    (lChanges[0].Incident.EndedAtUtc = 0) or
    (Length(lChanges[0].Incident.PostContext) <> 2) then
  begin
    Writeln('SELFTEST FAILED: high CPU recovery did not end the original incident');
    Exit;
  end;
  lDetector.Accept(CreateCpuSignals(IncMinute(lUtc, 1), 61000, 95,
    'second high episode begins'));
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, 60000 + lThresholds.HighCpuActivationDurationMs),
    61000 + lThresholds.HighCpuActivationDurationMs, 95,
    'second high episode activates'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Incident.StableId = lFirstId) then
  begin
    Writeln('SELFTEST FAILED: recovered high CPU could not create a new stable incident');
    Exit;
  end;
  Result := 0;
end;

function RunPostContextContinuationSelfTest: Integer;
var
  g: TGarbos;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lDetector: TMachineOverviewIncidentDetector;
  lEndedAtMs: UInt64;
  lIncidentId: string;
  lThresholds: TMachineOverviewIncidentThresholds;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lThresholds := TMachineOverviewIncidentThresholds.Defaults;
  GC(lDetector, TMachineOverviewIncidentDetector.Create(lThresholds), g);
  lUtc := EncodeDate(2026, 8, 29) + EncodeTime(1, 0, 0, 0);
  lDetector.Accept(CreateCpuSignals(lUtc, 1000, 95, 'activation begins'));
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, lThresholds.HighCpuActivationDurationMs),
    1000 + lThresholds.HighCpuActivationDurationMs, 95,
    'activation complete'));
  if Length(lChanges) <> 1 then
    Exit;
  lIncidentId := lChanges[0].Incident.StableId;
  lEndedAtMs := 2000 + lThresholds.HighCpuActivationDurationMs +
    lThresholds.HighCpuRecoveryDurationMs;
  lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, 1000 + lThresholds.HighCpuActivationDurationMs),
    2000 + lThresholds.HighCpuActivationDurationMs, 60,
    'recovery begins'));
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, lEndedAtMs - 1000), lEndedAtMs, 60,
    'incident ends'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Ended) then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, lEndedAtMs +
      lThresholds.PostContextDurationMs - 1),
    lEndedAtMs + lThresholds.PostContextDurationMs - 1, 40,
    'post context before boundary'));
  if Length(lChanges) <> 0 then
    Exit;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, lEndedAtMs + lThresholds.PostContextDurationMs),
    lEndedAtMs + lThresholds.PostContextDurationMs, 40,
    'post context boundary'));
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Updated) or
    (lChanges[0].Incident.StableId <> lIncidentId) or
    (Length(lChanges[0].Incident.PostContext) <> 4) then
  begin
    Writeln('SELFTEST FAILED: ten-minute post-incident context was not completed');
    Exit;
  end;
  lChanges := lDetector.Accept(CreateCpuSignals(
    IncMilliSecond(lUtc, lEndedAtMs +
      lThresholds.PostContextDurationMs + 1),
    lEndedAtMs + lThresholds.PostContextDurationMs + 1, 40,
    'after post context'));
  if Length(lChanges) <> 0 then
  begin
    Writeln('SELFTEST FAILED: completed incident kept accepting post context');
    Exit;
  end;
  Result := 0;
end;

function CreateCategorySignals(const aCategory: TMachineOverviewIncidentCategory;
  const aUtc: TDateTime; const aMonotonicMs: UInt64;
  const aTriggered: Boolean): TMachineOverviewIncidentSignals;
begin
  Result := CreateCpuSignals(aUtc, aMonotonicMs, 40, 'category replay');
  Result.ProviderStatus := TMachineOverviewProviderStatus.Available;
  Result.DpcPercent.Available := True;
  Result.InterruptPercent.Available := True;
  Result.ForegroundReplyMs.Available := True;
  Result.PhysicalUsedPercent.Available := True;
  Result.PagingBytesPerSecond.Available := True;
  Result.DiskActivePercent.Available := True;
  Result.DiskLatencyMs.Available := True;
  Result.DiskQueueLength.Available := True;
  Result.GpuPercent.Available := True;
  Result.TemperatureCelsius.Available := True;
  Result.RelatedEntityIds := ['physical:0', '4242:9876543210'];
  Result.RelatedExecutablePaths := ['C:\Test\load.exe'];
  if not aTriggered then
  begin
    Result.ForegroundReplyMs.Value := 10;
    Result.PhysicalUsedPercent.Value := 50;
    Result.DiskActivePercent.Value := 10;
    Result.DiskLatencyMs.Value := 2;
    Result.GpuPercent.Value := 10;
    Result.TemperatureCelsius.Value := 50;
    Exit;
  end;
  case aCategory of
    TMachineOverviewIncidentCategory.HotLogicalProcessors:
      Result.HotLogicalProcessorCount := 4;
    TMachineOverviewIncidentCategory.DpcInterrupt:
      Result.DpcPercent.Value := 20;
    TMachineOverviewIncidentCategory.ForegroundResponse:
      Result.ForegroundReplyMs.Value := 2000;
    TMachineOverviewIncidentCategory.DwmFrames:
      Result.DwmMissedFrames := 10;
    TMachineOverviewIncidentCategory.MemoryPressure:
      Result.PhysicalUsedPercent.Value := 97;
    TMachineOverviewIncidentCategory.DiskPressure:
      begin
        Result.DiskActivePercent.Value := 90;
        Result.DiskLatencyMs.Value := 60;
        Result.DiskQueueLength.Value := 5;
      end;
    TMachineOverviewIncidentCategory.GpuSaturation:
      Result.GpuPercent.Value := 99;
    TMachineOverviewIncidentCategory.ThermalWarning:
      Result.TemperatureCelsius.Value := 95;
    TMachineOverviewIncidentCategory.ProviderHealth:
      Result.ProviderStatus := TMachineOverviewProviderStatus.Failed;
    TMachineOverviewIncidentCategory.PipelineOverload:
      begin
        Result.RecordsDroppedDelta := 3;
        Result.SQLiteCommitDurationMs := 1500;
      end;
  end;
end;

function RunAutomaticCategoryReplaySelfTest: Integer;
const
  cCategories: array[0..9] of TMachineOverviewIncidentCategory = (
    TMachineOverviewIncidentCategory.HotLogicalProcessors,
    TMachineOverviewIncidentCategory.DpcInterrupt,
    TMachineOverviewIncidentCategory.ForegroundResponse,
    TMachineOverviewIncidentCategory.DwmFrames,
    TMachineOverviewIncidentCategory.MemoryPressure,
    TMachineOverviewIncidentCategory.DiskPressure,
    TMachineOverviewIncidentCategory.GpuSaturation,
    TMachineOverviewIncidentCategory.ThermalWarning,
    TMachineOverviewIncidentCategory.ProviderHealth,
    TMachineOverviewIncidentCategory.PipelineOverload);
var
  lCategory: TMachineOverviewIncidentCategory;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lDetector: TMachineOverviewIncidentDetector;
  lThresholds: TMachineOverviewIncidentThresholds;
  lUtc: TDateTime;
begin
  Result := 1;
  lThresholds := TMachineOverviewIncidentThresholds.Defaults;
  lUtc := EncodeDate(2026, 8, 29);
  for lCategory in cCategories do
  begin
    lDetector := TMachineOverviewIncidentDetector.Create(lThresholds);
    try
      lChanges := lDetector.Accept(CreateCategorySignals(lCategory, lUtc,
        1000, True));
      if Length(lChanges) <> 0 then
        Exit;
      lChanges := lDetector.Accept(CreateCategorySignals(lCategory,
        IncMilliSecond(lUtc, lThresholds.SignalActivationDurationMs),
        1000 + lThresholds.SignalActivationDurationMs, True));
      if (Length(lChanges) <> 1) or
        (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Started) or
        (lChanges[0].Incident.Category <> lCategory) or
        lChanges[0].Incident.Summary.IsEmpty or
        lChanges[0].Incident.ThresholdText.IsEmpty or
        (Length(lChanges[0].Incident.RelatedEntityIds) <> 2) or
        (Length(lChanges[0].Incident.RelatedExecutablePaths) <> 1) then
      begin
        Writeln('SELFTEST FAILED: automatic incident category did not activate completely');
        Exit;
      end;
      lChanges := lDetector.Accept(CreateCategorySignals(lCategory,
        IncSecond(lUtc, 6), 7000, True));
      if Length(lChanges) <> 0 then
      begin
        Writeln('SELFTEST FAILED: sustained automatic condition duplicated an incident');
        Exit;
      end;
      lDetector.Accept(CreateCategorySignals(lCategory, IncSecond(lUtc, 7),
        8000, False));
      lChanges := lDetector.Accept(CreateCategorySignals(lCategory,
        IncMilliSecond(lUtc, 7000 + lThresholds.SignalRecoveryDurationMs),
        8000 + lThresholds.SignalRecoveryDurationMs, False));
      if (Length(lChanges) <> 1) or
        (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Ended) or
        (lChanges[0].Incident.Category <> lCategory) then
      begin
        Writeln('SELFTEST FAILED: automatic incident category did not recover');
        Exit;
      end;
    finally
      lDetector.Free;
    end;
  end;
  Result := 0;
end;

function RunUserMarkedIncidentSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lDetector: TMachineOverviewIncidentDetector;
  lSignals: TMachineOverviewIncidentSignals;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lDetector, TMachineOverviewIncidentDetector.Create(
    TMachineOverviewIncidentThresholds.Defaults), g);
  lSignals := CreateCategorySignals(
    TMachineOverviewIncidentCategory.UserMarked, EncodeDate(2026, 8, 29),
    5000, False);
  lChange := lDetector.MarkUserSlowdown(lSignals, 'User marked slowdown');
  if (lChange.Kind <> TMachineOverviewIncidentChangeKind.Ended) or
    (lChange.Incident.Category <> TMachineOverviewIncidentCategory.UserMarked) or
    (lChange.Incident.Origin <> TMachineOverviewIncidentOrigin.UserMarked) or
    (lChange.Incident.StartedAtUtc <> lChange.Incident.EndedAtUtc) or
    (lChange.Incident.StableId <> 'user-marked-1787961600000') or
    (lChange.Incident.Summary <> 'User marked slowdown') then
  begin
    Writeln('SELFTEST FAILED: user-marked incident contract is incomplete');
    Exit;
  end;
  Result := 0;
end;

function RunProviderStaleIncidentSelfTest: Integer;
var
  g: TGarbos;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lDetector: TMachineOverviewIncidentDetector;
  lSignals: TMachineOverviewIncidentSignals;
  lThresholds: TMachineOverviewIncidentThresholds;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lThresholds := TMachineOverviewIncidentThresholds.Defaults;
  GC(lDetector, TMachineOverviewIncidentDetector.Create(lThresholds), g);
  lUtc := EncodeDate(2026, 8, 29) + EncodeTime(1, 30, 0, 0);
  lSignals := CreateCategorySignals(
    TMachineOverviewIncidentCategory.ProviderHealth, lUtc, 1000, False);
  lSignals.ProviderFreshnessMs := lThresholds.ProviderStaleMs + 1;
  lDetector.Accept(lSignals);
  lSignals.CapturedAtUtc := IncMilliSecond(lUtc,
    lThresholds.SignalActivationDurationMs);
  lSignals.CapturedAtMonotonicMs := 1000 +
    lThresholds.SignalActivationDurationMs;
  lChanges := lDetector.Accept(lSignals);
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Started) or
    (lChanges[0].Incident.Category <>
     TMachineOverviewIncidentCategory.ProviderHealth) then
  begin
    Writeln('SELFTEST FAILED: stale provider did not create a health incident');
    Exit;
  end;
  lSignals.ProviderFreshnessMs := 0;
  lSignals.CapturedAtUtc := IncSecond(lUtc, 6);
  lSignals.CapturedAtMonotonicMs := 7000;
  lDetector.Accept(lSignals);
  lSignals.CapturedAtUtc := IncMilliSecond(lUtc, 6000 +
    lThresholds.SignalRecoveryDurationMs);
  lSignals.CapturedAtMonotonicMs := 7000 +
    lThresholds.SignalRecoveryDurationMs;
  lChanges := lDetector.Accept(lSignals);
  if (Length(lChanges) <> 1) or
    (lChanges[0].Kind <> TMachineOverviewIncidentChangeKind.Ended) then
  begin
    Writeln('SELFTEST FAILED: fresh provider data did not recover its incident');
    Exit;
  end;
  Result := 0;
end;

function RunIncidentPersistenceRestartSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewHistoryConfig;
  lDatabaseFileName: string;
  lDetector: TMachineOverviewIncidentDetector;
  lDirectory: string;
  lError: string;
  lIncidents: TArray<TMachineOverviewIncident>;
  lRestartService: TMachineOverviewHistoryService;
  lService: TMachineOverviewHistoryService;
  lSignals: TMachineOverviewIncidentSignals;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\incident-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('incident-%d-%d.db', [GetCurrentProcessId, GetTickCount64]));
  lService := nil;
  lRestartService := nil;
  try
    GC(lDetector, TMachineOverviewIncidentDetector.Create(
      TMachineOverviewIncidentThresholds.Defaults), g);
    lSignals := CreateCategorySignals(
      TMachineOverviewIncidentCategory.UserMarked,
      EncodeDate(2026, 8, 29) + EncodeTime(2, 0, 0, 0), 5000, False);
    lChange := lDetector.MarkUserSlowdown(lSignals,
      'Initial persisted summary');
    lChange.Incident.PeakValue := 42.5;
    lChange.Incident.PostContext := Copy(lChange.Incident.PreContext);
    lConfig := Default(TMachineOverviewHistoryConfig);
    lConfig.Enabled := True;
    lConfig.DatabaseFileName := lDatabaseFileName;
    lConfig.CommitIntervalMs := 60000;
    lConfig.QueueCapacity := 16;
    lConfig.RawRetentionHours := 48;
    lConfig.Rollup10sRetentionDays := 30;
    lConfig.Rollup1mRetentionDays := 365;
    lConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lConfig.BusyTimeoutMs := 100;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) or
      (lService.EnqueueIncident(lChange) <>
       TMachineOverviewHistoryEnqueueResult.Queued) then
      Exit;
    lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
    lChange.Incident.Summary := 'Updated persisted summary';
    lChange.Incident.PeakValue := 55.5;
    if lService.EnqueueIncident(lChange) <>
      TMachineOverviewHistoryEnqueueResult.Queued then
      Exit;
    if not lService.Flush(5000) then
    begin
      Writeln('SELFTEST FAILED: incident history flush: ' +
        lService.Diagnostics.LastError);
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      Exit;
    lRestartService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lRestartService.Start;
    if (not lRestartService.WaitUntilInitialized(5000)) or
      (not lRestartService.Diagnostics.Available) or
      (lRestartService.Stop(5000) <>
       TMachineOverviewShutdownResult.Stopped) then
      Exit;
    if (not TryLoadMachineOverviewIncidents(lDatabaseFileName, 0, 10,
        lIncidents, lError)) or (Length(lIncidents) <> 1) or
      (lIncidents[0].StableId <> lChange.Incident.StableId) or
      (not SameValue(lIncidents[0].StartedAtUtc,
       lChange.Incident.StartedAtUtc, 1 / MSecsPerDay)) or
      (lIncidents[0].Summary <> 'Updated persisted summary') or
      (not SameValue(lIncidents[0].PeakValue, 55.5, 0.001)) or
      (lIncidents[0].Category <>
       TMachineOverviewIncidentCategory.UserMarked) or
      (lIncidents[0].Origin <>
       TMachineOverviewIncidentOrigin.UserMarked) or
      (Length(lIncidents[0].RelatedEntityIds) <> 2) or
      (Length(lIncidents[0].RelatedExecutablePaths) <> 1) or
      (Length(lIncidents[0].PreContext) <> 1) or
      (Length(lIncidents[0].PostContext) <> 1) then
    begin
      Writeln(Format('SELFTEST FAILED: incident did not survive persistence ' +
        'restart and stable-ID upsert: count=%d error=%s',
        [Length(lIncidents), lError]));
      Exit;
    end;
    Result := 0;
  finally
    lRestartService.Free;
    lService.Free;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function CreatePipelineIncidentSample(const aUtc: TDateTime;
  const aMonotonicMs: UInt64; const aCpuPercent: Double):
  IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := 'windows-core';
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtUtc := aUtc;
  lSample.State.CapturedAtMonotonicMs := aMonotonicMs;
  SetLength(lSample.Measurements, 1);
  lSample.Measurements[0].Name := 'cpu_total_percent';
  lSample.Measurements[0].Available := True;
  lSample.Measurements[0].Value := aCpuPercent;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function RunIncidentPipelineFreezeSelfTest: Integer;
var
  g: TGarbos;
  lChange: TMachineOverviewIncidentChange;
  lCursor: TMachineOverviewSnapshotCursor;
  lFoundIncidentRow: Boolean;
  lPipeline: TMachineOverviewPipeline;
  lPresentation: TMachineOverviewPresentation;
  lRow: TMachineOverviewRow;
  lSnapshot: IMachineOverviewSnapshot;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  GC(lCursor, TMachineOverviewSnapshotCursor.Create, g);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(5000) then
    Exit;
  lUtc := EncodeDate(2026, 8, 29) + EncodeTime(4, 0, 0, 0);
  lPipeline.EnqueueRaw(CreatePipelineIncidentSample(lUtc, 1000, 40));
  if (not lPipeline.WaitForSequence(1, 5000)) or
    (not lCursor.TryRead(lPipeline, lSnapshot)) then
    Exit;
  lCursor.SetFrozen(True);
  lPipeline.EnqueueRaw(CreatePipelineIncidentSample(IncSecond(lUtc, 1),
    2000, 95));
  lPipeline.EnqueueRaw(CreatePipelineIncidentSample(IncSecond(lUtc, 16),
    17000, 97));
  if not lPipeline.WaitForSequence(3, 5000) then
    Exit;
  if (not lPipeline.TryTakeIncident(lChange)) or
    (lChange.Kind <> TMachineOverviewIncidentChangeKind.Started) or
    (lChange.Incident.Category <>
     TMachineOverviewIncidentCategory.HighCpu) then
  begin
    Writeln('SELFTEST FAILED: aggregator did not publish a detected incident');
    Exit;
  end;
  if lCursor.TryRead(lPipeline, lSnapshot) then
  begin
    Writeln('SELFTEST FAILED: frozen cursor rendered an incident update');
    Exit;
  end;
  lCursor.SetFrozen(False);
  if not lCursor.TryRead(lPipeline, lSnapshot) then
    Exit;
  lPresentation := lSnapshot.Presentation;
  lFoundIncidentRow := False;
  for lRow in lPresentation.Rows do
    if lRow.RowId = 'incidents' then
    begin
      lFoundIncidentRow := StartsText('1. Latest:', lRow.ValueText);
      Break;
    end;
  if not lFoundIncidentRow then
  begin
    Writeln('SELFTEST FAILED: resume did not expose the latest incident count');
    Exit;
  end;
  if lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    Exit;
  Result := 0;
end;

function IncidentRowHasCount(const aSnapshot: IMachineOverviewSnapshot;
  const aCount: Integer): Boolean;
var
  lPresentation: TMachineOverviewPresentation;
  lRow: TMachineOverviewRow;
begin
  Result := False;
  if not Assigned(aSnapshot) then
    Exit;
  lPresentation := aSnapshot.Presentation;
  for lRow in lPresentation.Rows do
    if lRow.RowId = 'incidents' then
      Exit(StartsText(IntToStr(aCount) + '.', lRow.ValueText));
end;

function RunIncidentPresentationOrderingSelfTest: Integer;
var
  g: TGarbos;
  i: Integer;
  lBaseUtc: TDateTime;
  lIncidents: TArray<TMachineOverviewIncident>;
  lPipeline: TMachineOverviewPipeline;
  lPresentation: TMachineOverviewPresentation;
  lRow: TMachineOverviewRow;
  lSnapshot: IMachineOverviewSnapshot;
  lValueText: string;
begin
  g := Default(TGarbos);
  Result := 1;
  lBaseUtc := EncodeDate(2026, 8, 29) + EncodeTime(12, 0, 0, 0);
  SetLength(lIncidents, 5);
  for i := 0 to High(lIncidents) do
  begin
    lIncidents[i].StableId := 'ordering-' + IntToStr(i);
    lIncidents[i].Severity := TMachineOverviewSeverity.Notice;
  end;
  lIncidents[0].StartedAtUtc := IncHour(lBaseUtc, -25);
  lIncidents[0].Summary := 'outside-window';
  lIncidents[1].StartedAtUtc := IncHour(lBaseUtc, -3);
  lIncidents[1].Summary := 'fourth-latest';
  lIncidents[2].StartedAtUtc := IncHour(lBaseUtc, -1);
  lIncidents[2].Summary := 'second-latest';
  lIncidents[3].StartedAtUtc := IncHour(lBaseUtc, -2);
  lIncidents[3].Summary := 'third-latest';
  lIncidents[4].StartedAtUtc := IncMinute(lBaseUtc, -30);
  lIncidents[4].Summary := 'latest';
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  lPipeline.MergePersistedIncidents(lIncidents);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(5000) then
    Exit;
  lPipeline.EnqueueRaw(CreatePipelineIncidentSample(lBaseUtc, 1000, 40));
  if (not lPipeline.WaitForSequence(1, 5000)) or
    (not lPipeline.TryReadLatest(0, lSnapshot)) then
    Exit;
  lPresentation := lSnapshot.Presentation;
  lValueText := '';
  for lRow in lPresentation.Rows do
    if lRow.RowId = 'incidents' then
    begin
      lValueText := lRow.ValueText;
      Break;
    end;
  if (not StartsText('4. Latest:', lValueText)) or
    (Pos('latest', lValueText) = 0) or
    (Pos('second-latest', lValueText) <= Pos('latest', lValueText)) or
    (Pos('third-latest', lValueText) <= Pos('second-latest', lValueText)) or
    (Pos('fourth-latest', lValueText) > 0) or
    (Pos('outside-window', lValueText) > 0) then
  begin
    Writeln('SELFTEST FAILED: incident last-24-hour count or latest-three ordering is wrong');
    Exit;
  end;
  if lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    Exit;
  Result := 0;
end;

function RunIncidentPipelinePersistenceRestartSelfTest: Integer;
var
  lConfig: TMachineOverviewHistoryConfig;
  lDatabaseFileName: string;
  lDirectory: string;
  lError: string;
  lHistory: TMachineOverviewHistoryService;
  lHistoryDiagnostics: TMachineOverviewHistoryDiagnostics;
  lIncidents: TArray<TMachineOverviewIncident>;
  lPipeline: TMachineOverviewPipeline;
  lPresentation: TMachineOverviewPresentation;
  lRestartHistory: TMachineOverviewHistoryService;
  lRestartPipeline: TMachineOverviewPipeline;
  lSnapshot: IMachineOverviewSnapshot;
  lRow: TMachineOverviewRow;
  lUtc: TDateTime;
begin
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\incident-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('pipeline-incident-%d-%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  lPipeline := nil;
  lHistory := nil;
  lRestartPipeline := nil;
  lRestartHistory := nil;
  try
    lConfig := Default(TMachineOverviewHistoryConfig);
    lConfig.Enabled := True;
    lConfig.DatabaseFileName := lDatabaseFileName;
    lConfig.CommitIntervalMs := 60000;
    lConfig.QueueCapacity := 32;
    lConfig.RawRetentionHours := 48;
    lConfig.Rollup10sRetentionDays := 30;
    lConfig.Rollup1mRetentionDays := 365;
    lConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lConfig.BusyTimeoutMs := 100;
    lPipeline := TMachineOverviewPipeline.Create(16, 16);
    lHistory := TMachineOverviewHistoryService.Create(lPipeline, lConfig);
    lPipeline.Start;
    lHistory.Start;
    if (not lPipeline.WaitUntilRunning(5000)) or
      (not lHistory.WaitUntilInitialized(5000)) or
      (not lHistory.Diagnostics.Available) then
      Exit;
    if not lHistory.Diagnostics.LastError.IsEmpty then
    begin
      Writeln('SELFTEST FAILED: incident hydration reported an error: ' +
        lHistory.Diagnostics.LastError);
      Exit;
    end;
    lUtc := EncodeDate(2026, 8, 29) + EncodeTime(5, 0, 0, 0);
    lPipeline.EnqueueRaw(CreatePipelineIncidentSample(lUtc, 1000, 95));
    lPipeline.EnqueueRaw(CreatePipelineIncidentSample(IncSecond(lUtc, 15),
      16000, 97));
    if (not lPipeline.WaitForSequence(2, 5000)) or
      (not lHistory.Flush(5000)) or
      (lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (lHistory.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      Exit;
    if (not TryLoadMachineOverviewIncidents(lDatabaseFileName, 0, 10,
        lIncidents, lError)) or (Length(lIncidents) <> 1) then
    begin
      lHistoryDiagnostics := lHistory.Diagnostics;
      Writeln(Format('SELFTEST FAILED: aggregator incident was not ' +
        'persisted: load=%s accepted=%d persisted=%d queue=%d error=%s',
        [lError, lHistoryDiagnostics.Accepted,
         lHistoryDiagnostics.Persisted, lHistoryDiagnostics.QueueDepth,
         lHistoryDiagnostics.LastError]));
      Exit;
    end;
    lRestartPipeline := TMachineOverviewPipeline.Create(16, 16);
    lRestartHistory := TMachineOverviewHistoryService.Create(
      lRestartPipeline, lConfig);
    lRestartPipeline.Start;
    lRestartHistory.Start;
    if (not lRestartPipeline.WaitUntilRunning(5000)) or
      (not lRestartHistory.WaitUntilInitialized(5000)) or
      (not lRestartHistory.Diagnostics.Available) then
      Exit;
    lRestartPipeline.EnqueueRaw(CreatePipelineIncidentSample(
      IncHour(lUtc, 1), 100000, 40));
    if (not lRestartPipeline.WaitForSequence(1, 5000)) or
      (not lRestartPipeline.TryReadLatest(0, lSnapshot)) or
      (not IncidentRowHasCount(lSnapshot, 1)) then
    begin
      Writeln('SELFTEST FAILED: persisted incident did not hydrate the ' +
        'restart snapshot: hydrated=' +
        IntToStr(lRestartHistory.Diagnostics.HydratedIncidentCount) +
        ' merged=' + IntToStr(lRestartPipeline.IncidentCount) +
        ' error=' + lRestartHistory.Diagnostics.LastError);
      if Assigned(lSnapshot) then
      begin
        lPresentation := lSnapshot.Presentation;
        for lRow in lPresentation.Rows do
          if lRow.RowId = 'incidents' then
            Writeln('SELFTEST INFO: restart incident row=' + lRow.ValueText);
      end;
      Exit;
    end;
    if (lRestartPipeline.Stop(5000) <>
        TMachineOverviewShutdownResult.Stopped) or
      (lRestartHistory.Stop(5000) <>
       TMachineOverviewShutdownResult.Stopped) then
      Exit;
    Result := 0;
  finally
    lRestartHistory.Free;
    lRestartPipeline.Free;
    lHistory.Free;
    lPipeline.Free;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function RunMachineOverviewIncidentSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if not SameText(aArg, cMachineOverviewIncidentSelfTestArg) then
    Exit;
  try
    Result := RunHighCpuIncidentSelfTest;
    if Result = 0 then
      Result := RunPostContextContinuationSelfTest;
    if Result = 0 then
      Result := RunAutomaticCategoryReplaySelfTest;
    if Result = 0 then
      Result := RunUserMarkedIncidentSelfTest;
    if Result = 0 then
      Result := RunProviderStaleIncidentSelfTest;
    if Result = 0 then
      Result := RunIncidentPersistenceRestartSelfTest;
    if Result = 0 then
      Result := RunIncidentPipelineFreezeSelfTest;
    if Result = 0 then
      Result := RunIncidentPresentationOrderingSelfTest;
    if Result = 0 then
      Result := RunIncidentPipelinePersistenceRestartSelfTest;
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

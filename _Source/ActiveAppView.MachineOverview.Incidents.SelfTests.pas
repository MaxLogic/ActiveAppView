unit ActiveAppView.MachineOverview.Incidents.SelfTests;

interface

function RunMachineOverviewIncidentSelfTests(const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.Diagnostics, System.Generics.Collections, System.IOUtils, System.Math, System.StrUtils,
  System.SysUtils,
  Winapi.Windows,
  AutoFree, FireDAC.Comp.Client,
  ActiveAppView.MachineOverview.Evidence,
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
    (lChanges[0].Incident.EndedAtUtc = 0) then
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

function CheckIncidentLegacyContext(const aDatabaseFileName: string;
  const aStableId, aOperation: string): Boolean;
var
  g: TGarbos;
  lConnection: TFDConnection;
  lContextText: string;
  lPostContext: string;
  lPreContext: string;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  GC(lConnection, TFDConnection.Create(nil), g);
  lConnection.LoginPrompt := False;
  lConnection.ResourceOptions.SilentMode := True;
  lConnection.Params.Values['DriverID'] := 'SQLite';
  lConnection.Params.Values['Database'] := aDatabaseFileName;
  lConnection.Params.Values['OpenMode'] := 'ReadOnly';
  lConnection.Params.Values['LockingMode'] := 'Normal';
  lConnection.Params.Values['JournalMode'] := 'WAL';
  lConnection.Params.Values['SharedCache'] := 'False';
  lConnection.Params.Values['BusyTimeout'] := '100';
  lConnection.Connected := True;
  lConnection.ExecSQL('PRAGMA query_only=ON');
  GC(lQuery, TFDQuery.Create(nil), g);
  lQuery.Connection := lConnection;
  lQuery.SQL.Text := 'SELECT pre_context_json, post_context_json, ' +
    'context_text FROM incident WHERE incident_key=:stable_id';
  lQuery.ParamByName('stable_id').AsWideString := aStableId;
  lQuery.Open;
  if lQuery.Eof then
  begin
    Writeln('SELFTEST FAILED: raw incident missing after ' + aOperation);
    Exit(False);
  end;
  lPreContext := lQuery.FieldByName('pre_context_json').AsWideString;
  lPostContext := lQuery.FieldByName('post_context_json').AsWideString;
  lContextText := lQuery.FieldByName('context_text').AsWideString;
  Result := (lPreContext = '[]') and (lPostContext = '[]') and
    (lContextText = '');
  if Result then
    Writeln('Raw incident legacy context empty after ' + aOperation)
  else begin
    Writeln(Format('SELFTEST FAILED: raw incident legacy context after %s: ' +
      'pre=%s post=%s context_text_length=%d',
      [aOperation, lPreContext, lPostContext, Length(lContextText)]));
  end;
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
  lInsertContextEmpty: Boolean;
  lRestartService: TMachineOverviewHistoryService;
  lService: TMachineOverviewHistoryService;
  lSignals: TMachineOverviewIncidentSignals;
  lUpsertContextEmpty: Boolean;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
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
    lConfig := Default(TMachineOverviewHistoryConfig);
    lConfig.DiskFreeBytesOverride := -1;
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
    if not lService.Flush(5000) then
    begin
      Writeln('SELFTEST FAILED: incident INSERT flush: ' +
        lService.Diagnostics.LastError);
      Exit;
    end;
    lInsertContextEmpty := CheckIncidentLegacyContext(lDatabaseFileName,
      lChange.Incident.StableId, 'INSERT');
    lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
    lChange.Incident.Explanation := 'Updated nonempty incident explanation';
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
    lUpsertContextEmpty := CheckIncidentLegacyContext(lDatabaseFileName,
      lChange.Incident.StableId, 'UPSERT');
    if (not lInsertContextEmpty) or (not lUpsertContextEmpty) then
      Exit;
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
      (Length(lIncidents[0].RelatedExecutablePaths) <> 1) then
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
  g: TGarbos;
  i: Int64;
  lMonotonicMs: UInt64;
  lSequence: UInt64;
  lProcessSample: TMachineOverviewProviderSample;
  lConnection: TFDConnection;
  lQuery: TFDQuery;
  lEvidence: TMachineOverviewIncidentEvidence;
  lFoundExited: Boolean;
  lContribution: TMachineOverviewProcessContribution;
  lPipelineDiagnostics: TMachineOverviewPipelineDiagnostics;
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
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
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
    lConfig.DiskFreeBytesOverride := -1;
    lConfig.Enabled := True;
    lConfig.DatabaseFileName := lDatabaseFileName;
    lConfig.CommitIntervalMs := 60000;
    lConfig.QueueCapacity := 4096;
    lConfig.RawRetentionHours := 48;
    lConfig.Rollup10sRetentionDays := 30;
    lConfig.Rollup1mRetentionDays := 365;
    lConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lConfig.BusyTimeoutMs := 100;
    lPipeline := TMachineOverviewPipeline.Create(32, 4096);
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
    // Restart hydration loads the wall-clock last 24 hours; keep this fixture recent.
    lUtc := IncMinute(TTimeZone.Local.ToUniversalTime(Now), -120);
    lSequence := 0;
    lMonotonicMs := 1000;
    for i := 0 to 631 do
    begin
      if (i >= 1) and (i <= 20) then
      begin
        if lPipeline.EnqueueRaw(CreatePipelineIncidentSample(IncSecond(lUtc, i),
          lMonotonicMs, 97)) <> TMachineOverviewEnqueueResult.Queued then
          raise Exception.Create('High CPU sample was not queued');
      end else begin
        if lPipeline.EnqueueRaw(CreatePipelineIncidentSample(IncSecond(lUtc, i),
          lMonotonicMs, 40)) <> TMachineOverviewEnqueueResult.Queued then
          raise Exception.Create('Normal CPU sample was not queued');
      end;
      Inc(lSequence);
      if not lPipeline.WaitForSequence(lSequence, 5000) then
        raise Exception.CreateFmt('Pipeline system sequence timed out at %d', [i]);
      if (i mod 5) = 0 then
      begin
        lProcessSample := Default(TMachineOverviewProviderSample);
        lProcessSample.State.ProviderId := 'processes';
        lProcessSample.State.Status := TMachineOverviewProviderStatus.Available;
        lProcessSample.State.CapturedAtUtc := IncSecond(lUtc, i);
        lProcessSample.State.CapturedAtMonotonicMs := lMonotonicMs;
        SetLength(lProcessSample.Measurements, 4 + Ord(i <= 10));
        lProcessSample.Measurements[0].Name := 'logical_processor_count';
        lProcessSample.Measurements[0].Value := 32;
        lProcessSample.Measurements[1].Name := 'process_cpu_interval_ms';
        lProcessSample.Measurements[1].Value := 5000;
        lProcessSample.Measurements[2].Name := 'process_cpu_measured_total_percent';
        lProcessSample.Measurements[2].Value := 12.5 + 3.125 * Ord(i <= 10);
        lProcessSample.Measurements[3].Name := 'process_cpu_process:1';
        lProcessSample.Measurements[3].Value := 12.5;
        lProcessSample.Measurements[3].EntityId := '100:1234';
        lProcessSample.Measurements[3].DisplayText := 'survivor.exe';
        if i <= 10 then
        begin
          lProcessSample.Measurements[4].Name := 'process_cpu_process:2';
          lProcessSample.Measurements[4].Value := 3.125;
          lProcessSample.Measurements[4].EntityId := '200:5678';
          lProcessSample.Measurements[4].DisplayText := 'exited-worker.exe';
        end;
        for var j := 0 to High(lProcessSample.Measurements) do
          lProcessSample.Measurements[j].Available := True;
        if lPipeline.EnqueueRaw(CreateMachineOverviewRawSample(lProcessSample)) <>
          TMachineOverviewEnqueueResult.Queued then
          raise Exception.Create('Process sample was not queued');
        Inc(lSequence);
        if not lPipeline.WaitForSequence(lSequence, 5000) then
          raise Exception.CreateFmt('Pipeline process sequence timed out at %d', [i]);
      end;
      lMonotonicMs := lMonotonicMs + 1000;
    end;
    if (not lPipeline.WaitForSequence(lSequence, 5000)) or
      (not lHistory.Flush(5000)) or
      (lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (lHistory.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Pipeline evidence flush/stop failed: ' + lHistory.Diagnostics.LastError);
    lPipelineDiagnostics := lPipeline.Diagnostics;
    Writeln(Format('PIPELINE RECORDER COST Debug Win64 samples=%d total_us=%.3f mean_us_per_sample=%.3f',
      [lPipelineDiagnostics.EvidenceSampleCount,
       lPipelineDiagnostics.EvidenceElapsedTicks * 1000000.0 / TStopwatch.Frequency,
       lPipelineDiagnostics.EvidenceElapsedTicks * 1000000.0 /
         TStopwatch.Frequency / lPipelineDiagnostics.EvidenceSampleCount]));
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
    GC(lConnection, TFDConnection.Create(nil), g);
    lConnection.Params.Values['DriverID'] := 'SQLite';
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.LoginPrompt := False;
    lConnection.Connected := True;
    lConnection.ExecSQL('PRAGMA query_only=ON');
    GC(lQuery, TFDQuery.Create(nil), g);
    lQuery.Connection := lConnection;
    lQuery.SQL.Text := 'SELECT evidence_json, state FROM incident_evidence WHERE incident_key=:key';
    lQuery.ParamByName('key').AsWideString := lIncidents[0].StableId;
    lQuery.Open;
    if lQuery.Eof then
    begin
      Writeln('SELFTEST FAILED: pipeline did not persist measured incident evidence');
      Exit;
    end;
    if (lQuery.FieldByName('state').AsInteger <> Ord(TMachineOverviewEvidenceState.Complete)) or
      (not TryMachineOverviewEvidenceFromJson(lQuery.FieldByName('evidence_json').AsWideString,
        lEvidence, lError)) then
    begin
      Writeln('SELFTEST FAILED: final post-window evidence was not Complete: ' + lError);
      Exit;
    end;
    lFoundExited := False;
    for lContribution in lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes do
      if (lContribution.ProcessId = 200) and (lContribution.CreationTime100ns = 5678) and
        (lContribution.DisplayName = 'exited-worker.exe') and (lContribution.AverageCpuPercent > 0) and
        (Abs(lContribution.LastSeenUtc - IncSecond(lUtc, 10)) < 0.0000001) then
        lFoundExited := True;
    if not lFoundExited then
    begin
      Writeln('SELFTEST FAILED: exited process was lost from persisted During contributors');
      Exit;
    end;
    g.Clear;
    lRestartPipeline := TMachineOverviewPipeline.Create(16, 16);
    lRestartHistory := TMachineOverviewHistoryService.Create(
      lRestartPipeline, lConfig);
    lRestartPipeline.Start;
    lRestartHistory.Start;
    if (not lRestartPipeline.WaitUntilRunning(5000)) or
      (not lRestartHistory.WaitUntilInitialized(5000)) or
      (not lRestartHistory.Diagnostics.Available) then
      Exit;
    if (not TryLoadMachineOverviewIncidentEvidence(lDatabaseFileName, lIncidents[0].StableId,
        lEvidence, lError)) or (lEvidence.State <> TMachineOverviewEvidenceState.Complete) then
      raise Exception.Create('Restart evidence reader failed: ' + lError);
    lFoundExited := False;
    for lContribution in lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes do
      if (lContribution.ProcessId = 200) and (lContribution.CreationTime100ns = 5678) and
        (lContribution.DisplayName = 'exited-worker.exe') and (lContribution.AverageCpuPercent > 0) then
        lFoundExited := True;
    if not lFoundExited then
      raise Exception.Create('Restart reader lost exited process B');
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
    Writeln('SELFTEST PASS: pipeline incident evidence survives process exit, post window and restart');
  finally
    g.Clear;
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

function EvidenceSecond(const aUtc: TDateTime; const aSeconds: Integer): TDateTime;
var
  lSeconds: Int64;
begin
  lSeconds := aSeconds; //PALOFF Our small integer fixture offsets widen exactly to Int64.
  Result := IncSecond(aUtc, lSeconds);
end;

procedure EvidenceCheck(const aCondition: Boolean; const aMessage: string);
begin
  if not aCondition then
    raise Exception.Create('Evidence: ' + aMessage);
end;

procedure AddEvidenceMeasurement(var aSample: TMachineOverviewProviderSample;
  const aName: string; const aValue: Double; const aIdentity: string = '';
  const aDisplay: string = '');
var
  n: Integer;
begin
  n := Length(aSample.Measurements);
  SetLength(aSample.Measurements, n + 1);
  aSample.Measurements[n].Name := aName;
  aSample.Measurements[n].Value := aValue;
  aSample.Measurements[n].Available := True;
  aSample.Measurements[n].EntityId := aIdentity;
  aSample.Measurements[n].DisplayText := aDisplay;
  aSample.Measurements[n].DetailText := 'C:\Test\worker.exe';
  aSample.Measurements[n].StatusText := 'Available';
end;

function EvidenceSample(const aUtc: TDateTime; const aProcess: Boolean;
  const aFirst: Integer = 1; const aCount: Integer = 2): TMachineOverviewProviderSample;
var
  i: Integer;
begin
  Result := Default(TMachineOverviewProviderSample);
  Result.State.Status := TMachineOverviewProviderStatus.Available;
  Result.State.CapturedAtUtc := aUtc;
  if aProcess then
  begin
    Result.State.ProviderId := 'processes';
    AddEvidenceMeasurement(Result, 'logical_processor_count', 32);
    AddEvidenceMeasurement(Result, 'process_cpu_interval_ms', 5000);
    AddEvidenceMeasurement(Result, 'process_cpu_measured_total_percent', aCount * 3.125);
    for i := 0 to aCount - 1 do
      AddEvidenceMeasurement(Result, 'process_cpu_process:' + IntToStr(i + 1),
        3.125, '42:' + IntToStr(aFirst + i), 'worker.exe');
    AddEvidenceMeasurement(Result, 'process_cpu_rank:1', aCount * 3.125, '', 'worker.exe');
    AddEvidenceMeasurement(Result, 'process_cpu_pids:1', aCount);
  end else begin
    Result.State.ProviderId := 'windows-core';
    AddEvidenceMeasurement(Result, 'cpu_total_percent', 25);
    AddEvidenceMeasurement(Result, 'dpc_percent', 2);
    AddEvidenceMeasurement(Result, 'interrupt_percent', 1);
  end;
end;

function EvidenceChange(const aUtc: TDateTime; const aId: string): TMachineOverviewIncidentChange;
begin
  Result := Default(TMachineOverviewIncidentChange);
  Result.Kind := TMachineOverviewIncidentChangeKind.Started;
  Result.Incident.StableId := aId;
  Result.Incident.StartedAtUtc := aUtc;
end;

procedure AssertEvidencePayloadValid(const aEvidence: TMachineOverviewIncidentEvidence);
var
  lDecoded: TMachineOverviewIncidentEvidence;
  lError: string;
begin
  EvidenceCheck(TryMachineOverviewEvidenceFromJson(MachineOverviewEvidenceToJson(aEvidence), lDecoded, lError),
    'every emitted payload must decode: ' + lError);
end;

function EvidencePayloadEmpty(const aEvidence: TMachineOverviewIncidentEvidence): Boolean;
var
  lKind: TMachineOverviewEvidencePhaseKind;
begin
  Result := (aEvidence.State = TMachineOverviewEvidenceState.Legacy) and
    (aEvidence.ProcessIntervalMs = 0) and (aEvidence.SystemIntervalMs = 0) and
    (Length(aEvidence.Gaps) = 0) and not aEvidence.Truncated;
  for lKind := Low(lKind) to High(lKind) do
    Result := Result and (Length(aEvidence.Phases[lKind].Processes) = 0) and
      (Length(aEvidence.Phases[lKind].Applications) = 0) and
      (aEvidence.Phases[lKind].ProcessSampleCount = 0) and
      (aEvidence.Phases[lKind].SystemSampleCount = 0);
end;

procedure ApplyEvidence(const aRecorder: TMachineOverviewEvidenceRecorder;
  var aChange: TMachineOverviewIncidentChange);
begin
  aRecorder.Apply(aChange);
  if aChange.HasEvidenceUpdate then
    AssertEvidencePayloadValid(aChange.Incident.Evidence)
  else
    EvidenceCheck(EvidencePayloadEmpty(aChange.Incident.Evidence), 'headline-only change has no payload');
end;

function CompleteEvidence(const aRecorder: TMachineOverviewEvidenceRecorder;
  const aNowUtc: TDateTime): TArray<TMachineOverviewIncidentChange>;
var
  lChange: TMachineOverviewIncidentChange;
begin
  Result := aRecorder.TakeCompleted(aNowUtc);
  for lChange in Result do
  begin
    EvidenceCheck(lChange.HasEvidenceUpdate, 'completion explicitly carries evidence');
    AssertEvidencePayloadValid(lChange.Incident.Evidence);
  end;
end;

function CaptureEvidence(const aRecorder: TMachineOverviewEvidenceRecorder;
  const aChange: TMachineOverviewIncidentChange): TMachineOverviewIncidentEvidence;
var
  lChange: TMachineOverviewIncidentChange;
begin
  lChange := aChange;
  ApplyEvidence(aRecorder, lChange);
  Result := lChange.Incident.Evidence;
end;

procedure RunEvidenceAttributionSelfTest;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lPhase: TMachineOverviewEvidencePhase;
  lUtc: TDateTime;
  i: Integer;
begin
  lChange := Default(TMachineOverviewIncidentChange);
  g := Default(TGarbos);
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(TMachineOverviewEvidenceConfig.Defaults), g);
  lUtc := EncodeDate(2026, 10, 20);
  lChange := EvidenceChange(lUtc, 'attribution');
  lEvidence := CaptureEvidence(lRecorder, lChange);
  for i := 0 to 14 do
  begin
    lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, i), False));
    if (i > 0) and ((i mod 5) = 0) then
      lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, i), True, 1 + Ord(i = 10), 2));
  end;
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 15);
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lPhase := lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During];
  EvidenceCheck(lEvidence.LogicalProcessorCount = 32, 'LP count');
  EvidenceCheck((lPhase.ProcessSampleCount = 2) and (lPhase.SystemSampleCount = 15), 'sample counts');
  EvidenceCheck(Length(lPhase.Processes) = 3, 'PID reuse must retain exited identity');
  EvidenceCheck((lPhase.Processes[0].CreationTime100ns = 2) and
    SameValue(lPhase.Processes[0].AverageCpuPercent, 3.125, 0.001), 'normalization / phase denominator');
  EvidenceCheck(SameValue(lPhase.Processes[0].PeakCpuPercent, 3.125, 0.001) and
    SameValue(lPhase.Processes[0].PeakAtUtc, EvidenceSecond(lUtc, 5), 0.0000001), 'process peak time');
  EvidenceCheck(SameValue(lPhase.Processes[1].LastSeenUtc, EvidenceSecond(lUtc, 5), 0.0000001), 'exited last seen');
  EvidenceCheck((Length(lPhase.Applications) = 1) and (lPhase.Applications[0].ProcessCount = 2) and
    SameValue(lPhase.Applications[0].AverageCpuPercent, 6.25, 0.001) and
    SameValue(lPhase.Applications[0].PeakCpuPercent, 6.25, 0.001) and
    SameValue(lPhase.Applications[0].PeakAtUtc, EvidenceSecond(lUtc, 5), 0.0000001), 'application grouping');
  EvidenceCheck(SameValue(lPhase.SystemCpu.Average, 25, 0.001) and
    SameValue(lPhase.Dpc.Average, 2, 0.001) and SameValue(lPhase.Interrupt.Average, 1, 0.001) and
    SameValue(lPhase.MeasuredProcessCpu.Average, 6.25, 0.001) and
    SameValue(lPhase.UnattributedCpu.Average, 18.75, 0.001),
    Format('system / residual attribution cpu=%.4f dpc=%.4f irq=%.4f measured=%.4f residual=%.4f',
      [lPhase.SystemCpu.Average, lPhase.Dpc.Average, lPhase.Interrupt.Average,
       lPhase.MeasuredProcessCpu.Average, lPhase.UnattributedCpu.Average]));
  Writeln('SELFTEST PASS: evidence attribution');
end;

procedure RunEvidenceGapSelfTest;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lSample: TMachineOverviewProviderSample;
  lGap: TMachineOverviewEvidenceGap;
  lReasons: set of TMachineOverviewEvidenceGapReason;
  lUtc: TDateTime;
  i: Integer;
begin
  lChange := Default(TMachineOverviewIncidentChange);
  g := Default(TGarbos);
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(TMachineOverviewEvidenceConfig.Defaults), g);
  lUtc := EncodeDate(2026, 10, 20);
  lRecorder.ObserveSample(EvidenceSample(lUtc, False));
  lRecorder.ObserveSample(EvidenceSample(lUtc, True));
  lChange := EvidenceChange(lUtc, 'gaps');
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 15), True));
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 5), False));
  lSample := EvidenceSample(EvidenceSecond(lUtc, 16), True);
  lSample.State.Status := TMachineOverviewProviderStatus.Unavailable;
  lRecorder.ObserveSample(lSample);
  lSample.State.CapturedAtUtc := EvidenceSecond(lUtc, 17);
  lRecorder.ObserveSample(lSample);
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lReasons := [];
  for lGap in lEvidence.Gaps do
  begin
    Include(lReasons, lGap.Reason);
    if lGap.Reason = TMachineOverviewEvidenceGapReason.ProviderUnavailable then
      EvidenceCheck(lGap.EndUtc >= EvidenceSecond(lUtc, 17), 'adjacent unavailable gaps must merge');
  end;
  EvidenceCheck([TMachineOverviewEvidenceGapReason.ProcessSamplesMissing,
    TMachineOverviewEvidenceGapReason.SystemSamplesMissing,
    TMachineOverviewEvidenceGapReason.ProviderUnavailable,
    TMachineOverviewEvidenceGapReason.CollectionStartedLate] <= lReasons, 'gap reasons');
  for i := 1 to 40 do
  begin
    lSample := EvidenceSample(EvidenceSecond(lUtc, 20 + i * 20), True);
    if Odd(i) then
      lSample.State.Status := TMachineOverviewProviderStatus.Unavailable;
    lRecorder.ObserveSample(lSample);
  end;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  EvidenceCheck((Length(lEvidence.Gaps) = 16) and
    (lEvidence.GapsOmitted > 0), 'gap overflow counted');
  Writeln('SELFTEST PASS: evidence gaps');
end;

procedure RunEvidenceBoundsSelfTest;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lCompleted: TArray<TMachineOverviewIncidentChange>;
  lUtc: TDateTime;
  lShortBytes, lLongBytes: Integer;
  i: Integer;
begin
  lChange := Default(TMachineOverviewIncidentChange);
  g := Default(TGarbos);
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(TMachineOverviewEvidenceConfig.Defaults), g);
  lUtc := EncodeDate(2026, 10, 20);
  lChange := EvidenceChange(lUtc, 'bounds');
  lEvidence := CaptureEvidence(lRecorder, lChange);
  for i := 1 to 36 do
    lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, i * 5), True, i * 10, 10));
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lShortBytes := TEncoding.UTF8.GetByteCount(MachineOverviewEvidenceToJson(lEvidence));
  for i := 37 to 4320 do
    lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, i * 5), True, i * 10, 10));
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lLongBytes := TEncoding.UTF8.GetByteCount(MachineOverviewEvidenceToJson(lEvidence));
  EvidenceCheck(lEvidence.Truncated and (lLongBytes <= 16384) and
    (lLongBytes < lShortBytes + 1024), 'six-hour bounded summary');
  EvidenceCheck(Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes) <= 10,
    'During row bound');
  EvidenceCheck((Length(lEvidence.Gaps) <= 16) and
    (Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes) <= 5) and
    (Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.After].Processes) <= 5), 'other bounds');
  for i := 1 to 70 do
  begin
    lChange := EvidenceChange(EvidenceSecond(lUtc, i), 'concurrent-' + IntToStr(i));
    ApplyEvidence(lRecorder, lChange);
  end;
  EvidenceCheck(lRecorder.TrackedIncidentCount <= 64, 'incident bound');
  lCompleted := CompleteEvidence(lRecorder, lUtc);
  EvidenceCheck(Length(lCompleted) = 7, 'overflow incidents finalized early');
  for i := 0 to High(lCompleted) do
    EvidenceCheck((lCompleted[i].Incident.Evidence.State = TMachineOverviewEvidenceState.Partial) and
      lCompleted[i].Incident.Evidence.Truncated and (Length(lCompleted[i].Incident.Evidence.Gaps) > 0),
      'overflow must publish partial truncated evidence');
  EvidenceCheck(Length(CompleteEvidence(lRecorder, lUtc)) = 0, 'early completion emitted once');
  lChange := EvidenceChange(lUtc, 'unknown-update');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lChange.Incident.Evidence.LogicalProcessorCount := 123;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  EvidenceCheck(EvidencePayloadEmpty(lEvidence), 'unknown update explicitly carries no evidence');
  for i := 71 to 220 do
  begin
    lChange := EvidenceChange(EvidenceSecond(lUtc, i), 'concurrent-' + IntToStr(i));
    lEvidence := CaptureEvidence(lRecorder, lChange);
  end;
  EvidenceCheck((lRecorder.TrackedIncidentCount = 64) and
    (lEvidence.State = TMachineOverviewEvidenceState.Partial) and lEvidence.Truncated and
    (lEvidence.ProcessIntervalMs = 5000), 'saturated completion queue refuses admission with valid partial evidence');
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck((not lChange.HasEvidenceUpdate) and (lRecorder.TrackedIncidentCount = 64),
    'terminal admission refusal also finalizes its key');
  EvidenceCheck(Length(CompleteEvidence(lRecorder, lUtc)) = 64, 'completion queue bounded at 64');
  Writeln(Format('SELFTEST PASS: evidence bounds short=%d long=%d bytes', [lShortBytes, lLongBytes]));
end;

procedure RunEvidencePostWindowSelfTest(const aUserMarked: Boolean);
var
  g: TGarbos;
  lConfig: TMachineOverviewEvidenceConfig;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lCompleted: TArray<TMachineOverviewIncidentChange>;
  lUtc: TDateTime;
begin
  lChange := Default(TMachineOverviewIncidentChange);
  g := Default(TGarbos);
  lConfig := TMachineOverviewEvidenceConfig.Defaults;
  lConfig.PostWindowMs := 10000;
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
  lUtc := EncodeDate(2026, 10, 20);
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, -5), True));
  lChange := EvidenceChange(lUtc, 'post');
  if not aUserMarked then
    lEvidence := CaptureEvidence(lRecorder, lChange);
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 5), True));
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 5);
  if aUserMarked then
    lChange.Incident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  EvidenceCheck(Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes) = 2,
    'Before ring replay');
  EvidenceCheck((lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].ProcessSampleCount = 0) and
    (lEvidence.Phases[TMachineOverviewEvidencePhaseKind.After].ProcessSampleCount = 1),
    'interval ending at incident end belongs to After');
  EvidenceCheck(Length(CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 14))) = 0, 'post not early');
  EvidenceCheck(Length(CompleteEvidence(lRecorder, IncMilliSecond(lUtc, 14999))) = 0, 'post deadline minus one ms');
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 15), True));
  lCompleted := CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 15));
  EvidenceCheck((Length(lCompleted) = 1) and
    (lCompleted[0].Kind = TMachineOverviewIncidentChangeKind.Updated) and
    (lCompleted[0].Incident.Evidence.State = TMachineOverviewEvidenceState.Complete), 'post completes');
  EvidenceCheck((Length(CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 16))) = 0) and
    (lRecorder.TrackedIncidentCount = 0), 'post emits exactly once');
  Writeln('SELFTEST PASS: evidence post window user-marked=', aUserMarked);
end;

procedure RunEvidenceJsonRoundTripSelfTest;
var
  lEvidence, lDecoded: TMachineOverviewIncidentEvidence;
  lText, lError: string;
  lKind: TMachineOverviewEvidencePhaseKind;
  i: Integer;
begin
  lEvidence := Default(TMachineOverviewIncidentEvidence);
  lEvidence.LogicalProcessorCount := 32;
  lEvidence.ProcessIntervalMs := 5000;
  lEvidence.SystemIntervalMs := 1000;
  for lKind := Low(lKind) to High(lKind) do
    lEvidence.Phases[lKind].Kind := lKind;
  lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].SystemCpu.Available := True;
  lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].SystemCpu.Average := 3.125;
  lText := MachineOverviewEvidenceToJson(lEvidence);
  EvidenceCheck(TryMachineOverviewEvidenceFromJson(lText, lDecoded, lError), 'JSON decode: ' + lError);
  EvidenceCheck((lDecoded.LogicalProcessorCount = 32) and
    SameValue(lDecoded.Phases[TMachineOverviewEvidencePhaseKind.During].SystemCpu.Average, 3.13, 0.001) and
    (MachineOverviewEvidenceToJson(lDecoded) = lText), 'JSON round trip');
  EvidenceCheck((not TryMachineOverviewEvidenceFromJson('{broken', lDecoded, lError)) and
    (lError <> ''), 'invalid JSON error');
  EvidenceCheck(not TryMachineOverviewEvidenceFromJson('{}', lDecoded, lError), 'invalid schema');
  EvidenceCheck(not TryMachineOverviewEvidenceFromJson(lText + 'garbage', lDecoded, lError), 'trailing garbage');
  EvidenceCheck(not TryMachineOverviewEvidenceFromJson(StringReplace(lText, '"lp":32', '"lp":32,"lp":-1', []),
    lDecoded, lError), 'duplicate members');
  EvidenceCheck(not TryMachineOverviewEvidenceFromJson(StringReplace(lText, '"lp":32', '"lp":-1', []),
    lDecoded, lError), 'invalid LP count');
  EvidenceCheck((lError <> '') and (lDecoded.LogicalProcessorCount = 0), 'invalid decode clears result');
  for lKind := Low(lKind) to High(lKind) do
  begin
    SetLength(lEvidence.Phases[lKind].Processes, 5);
    SetLength(lEvidence.Phases[lKind].Applications, 5);
    for i := 0 to 4 do
    begin
      lEvidence.Phases[lKind].Processes[i].CreationTime100ns := High(UInt64);
      lEvidence.Phases[lKind].Processes[i].DisplayName := StringOfChar(WideChar($6F22), 256);
      lEvidence.Phases[lKind].Processes[i].ImagePath := StringOfChar(WideChar($6F22), 1024);
      lEvidence.Phases[lKind].Processes[i].PathStatus := 'Available';
      lEvidence.Phases[lKind].Applications[i].DisplayName := StringOfChar(WideChar($6F22), 256);
    end;
  end;
  lText := MachineOverviewEvidenceToJson(lEvidence);
  EvidenceCheck(TEncoding.UTF8.GetByteCount(lText) <= 16384, 'UTF-8 JSON size under long Unicode names and paths');
  EvidenceCheck(TryMachineOverviewEvidenceFromJson(lText, lDecoded, lError), 'trimmed JSON decode: ' + lError);
  EvidenceCheck(lDecoded.Truncated and
    (lDecoded.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].CreationTime100ns = High(UInt64)) and
    (Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes) = 5) and
    (Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes[0].ImagePath) = 1024),
    'trimmed JSON preserves UInt64 and does not mutate caller arrays');
  Writeln('SELFTEST PASS: evidence JSON');
end;

procedure RunEvidenceCostMeasurement(const aIncidentCount: Integer);
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lChange: TMachineOverviewIncidentChange;
  lSamples: array[0..199] of TMachineOverviewProviderSample;
  lTimes: TArray<Double>;
  lStopwatch: TStopwatch;
  lUtc: TDateTime;
  i, j: Integer;
begin
  lChange := Default(TMachineOverviewIncidentChange);
  g := Default(TGarbos);
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(TMachineOverviewEvidenceConfig.Defaults), g);
  lUtc := EncodeDate(2026, 10, 20);
  for i := 1 to aIncidentCount do
  begin
    lChange := EvidenceChange(lUtc, 'cost-' + IntToStr(i));
    ApplyEvidence(lRecorder, lChange);
  end;
  SetLength(lTimes, 21);
  for j := -1 to High(lTimes) do
  begin
    for i := 0 to High(lSamples) do
      lSamples[i] := EvidenceSample(EvidenceSecond(lUtc, (j + 1) * 200 + i), (i mod 5) = 4, 1, 10);
    lStopwatch := TStopwatch.StartNew;
    for i := 0 to High(lSamples) do
      lRecorder.ObserveSample(lSamples[i]);
    lStopwatch.Stop;
    if j >= 0 then
    begin
      lTimes[j] := lStopwatch.ElapsedTicks * 1000000.0 / TStopwatch.Frequency / Length(lSamples);
      Writeln(Format('EVIDENCE COST raw incidents=%d batch=%d us_per_sample=%.3f',
        [aIncidentCount, j, lTimes[j]]));
    end;
  end;
  TArray.Sort<Double>(lTimes);
  Writeln(Format('EVIDENCE COST Debug Win64 incidents=%d samples=4200 min_us=%.3f median_us=%.3f p95_us=%.3f max_us=%.3f',
    [aIncidentCount, lTimes[0], lTimes[10], lTimes[19], lTimes[20]]));
  EvidenceCheck(lRecorder.TrackedIncidentCount = aIncidentCount, 'cost workload consumed');
end;

procedure EvidenceReviewCheck(const aCondition: Boolean; const aMessage: string; var aFailures: Integer);
begin
  if not aCondition then
  begin
    Inc(aFailures);
    Writeln('REVIEW REGRESSION FAILED: ' + aMessage);
  end;
end;

procedure RunEvidenceFinalizedLifecycleSelfTest;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lConfig: TMachineOverviewEvidenceConfig;
  lChange, lFinalized: TMachineOverviewIncidentChange;
  lCompleted: TArray<TMachineOverviewIncidentChange>;
  lKind: TMachineOverviewIncidentChangeKind;
  lDecoded, lStoredEvidence: TMachineOverviewIncidentEvidence;
  lGap: TMachineOverviewEvidenceGap;
  lUtc: TDateTime;
  lPayload, lError: string;
  lEvictionGap: Boolean;
  lUser, lSupplied: Boolean;
  i, lMode, lFailures: Integer;
begin
  g := Default(TGarbos);
  lFailures := 0;
  lUtc := EncodeDate(2026, 10, 20);
  for lMode := 0 to 2 do
  begin
    lConfig := TMachineOverviewEvidenceConfig.Defaults;
    lConfig.PreWindowMs := 5000;
    if lMode = 2 then
      lConfig.PostWindowMs := 0;
    GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
    lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, -5), True));
    lChange := EvidenceChange(lUtc, 'finalized');
    if lMode = 1 then
    begin
      lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
      lChange.Incident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
      lChange.Incident.EndedAtUtc := lUtc;
    end;
    ApplyEvidence(lRecorder, lChange);
    lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 5), True));
    if lMode = 2 then
    begin
      lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
      lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 10);
      ApplyEvidence(lRecorder, lChange);
    end else begin
      for i := 1 to 64 do
      begin
        lChange := EvidenceChange(EvidenceSecond(lUtc, i), 'other-' + IntToStr(i));
        ApplyEvidence(lRecorder, lChange);
      end;
    end;
    lCompleted := CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 65));
    EvidenceCheck((Length(lCompleted) = 1) and (lCompleted[0].Incident.StableId = 'finalized'),
      'lifecycle fixture finalized target once');
    lFinalized := lCompleted[0];
    AssertEvidencePayloadValid(lFinalized.Incident.Evidence);
    lPayload := MachineOverviewEvidenceToJson(lFinalized.Incident.Evidence);
    lStoredEvidence := lFinalized.Incident.Evidence;
    lEvictionGap := False;
    for lGap in lFinalized.Incident.Evidence.Gaps do
      lEvictionGap := lEvictionGap or (lGap.Reason = TMachineOverviewEvidenceGapReason.Truncated);
    if lMode <> 2 then
      EvidenceCheck(lEvictionGap, 'eviction includes a valid truncation gap');
    if lMode <> 2 then
      EvidenceCheck(lFinalized.Incident.Evidence.Truncated and
        (lFinalized.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.Before].ProcessSampleCount = 1),
        'eviction preserves pre-window samples and truncation');
    if lMode = 0 then
      EvidenceCheck(lFinalized.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].ProcessSampleCount = 1,
        'eviction preserves During sample');
    lChange := EvidenceChange(lUtc, 'finalized');
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 70);
    ApplyEvidence(lRecorder, lChange);
    EvidenceReviewCheck((not lChange.HasEvidenceUpdate) and EvidencePayloadEmpty(lChange.Incident.Evidence),
      'fresh automatic Ended for finalized key returns no payload', lFailures);
    if not EvidencePayloadEmpty(lChange.Incident.Evidence) then
      EvidenceReviewCheck(TryMachineOverviewEvidenceFromJson(
        MachineOverviewEvidenceToJson(lChange.Incident.Evidence), lDecoded, lError),
        'fresh automatic Ended must never emit invalid zero-interval Partial: ' + lError, lFailures);
    for lKind := Low(lKind) to High(lKind) do
      for lUser := False to True do
        for lSupplied := False to True do
        begin
          lChange := EvidenceChange(lUtc, 'finalized');
          lChange.Kind := lKind;
          lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 70);
          if lUser then
            lChange.Incident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
          if lSupplied then
          begin
            lChange.Incident.Evidence := lFinalized.Incident.Evidence;
            lChange.HasEvidenceUpdate := True;
          end;
          ApplyEvidence(lRecorder, lChange);
          // Our S4 caller persists evidence only when this output flag is set.
          if lChange.HasEvidenceUpdate then
            lStoredEvidence := lChange.Incident.Evidence;
          AssertEvidencePayloadValid(lStoredEvidence);
          EvidenceReviewCheck(MachineOverviewEvidenceToJson(lStoredEvidence) = lPayload,
            'headline-only output preserves persisted finalized payload', lFailures);
          EvidenceReviewCheck((not lChange.HasEvidenceUpdate) and EvidencePayloadEmpty(lChange.Incident.Evidence),
            Format('finalized key returns headline only mode=%d kind=%d user=%s supplied=%s',
              [lMode, Ord(lKind), BoolToStr(lUser, True), BoolToStr(lSupplied, True)]), lFailures);
          if not EvidencePayloadEmpty(lChange.Incident.Evidence) then
            EvidenceReviewCheck(TryMachineOverviewEvidenceFromJson(
              MachineOverviewEvidenceToJson(lChange.Incident.Evidence), lDecoded, lError),
              'unexpected emitted lifecycle payload must still decode: ' + lError, lFailures);
          EvidenceReviewCheck(lRecorder.TrackedIncidentCount = IfThen(lMode = 2, 0, 64),
            'finalized key never recreates tracking', lFailures);
          lCompleted := CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 1000));
          EvidenceReviewCheck(Length(lCompleted) = 0, 'finalized key never emits replacement evidence', lFailures);
          EvidenceReviewCheck(MachineOverviewEvidenceToJson(lFinalized.Incident.Evidence) = lPayload,
            'finalized payload preserved byte-for-byte', lFailures);
        end;
  end;
  EvidenceCheck(lFailures = 0, 'finalized lifecycle regression failures: ' + IntToStr(lFailures));
  Writeln('SELFTEST PASS: finalized evidence lifecycle');
end;

procedure RunEvidenceFinalizedFifoSelfTest;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lConfig: TMachineOverviewEvidenceConfig;
  lChange: TMachineOverviewIncidentChange;
  lUtc: TDateTime;
  i: Integer;
begin
  g := Default(TGarbos);
  lUtc := EncodeDate(2026, 10, 20);
  lConfig := TMachineOverviewEvidenceConfig.Defaults;
  lConfig.PreWindowMs := 0;
  lConfig.PostWindowMs := 0;
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
  // We prove both sides of our documented 4096-key FIFO retention boundary.
  for i := 0 to 4096 do
  begin
    lChange := EvidenceChange(lUtc, 'fifo-' + IntToStr(i));
    ApplyEvidence(lRecorder, lChange);
    EvidenceCheck(lChange.HasEvidenceUpdate, 'fresh FIFO key admitted');
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.Incident.EndedAtUtc := lUtc;
    ApplyEvidence(lRecorder, lChange);
    EvidenceCheck(Length(CompleteEvidence(lRecorder, lUtc)) = 1, 'FIFO key finalized once');
  end;
  lChange := EvidenceChange(lUtc, 'fifo-1');
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck((not lChange.HasEvidenceUpdate) and (lRecorder.TrackedIncidentCount = 0),
    'oldest retained key rejects replay');
  lChange := EvidenceChange(lUtc, 'fifo-4096');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck((not lChange.HasEvidenceUpdate) and (lRecorder.TrackedIncidentCount = 0),
    'newest retained key rejects UserMarked replay');
  lChange := EvidenceChange(lUtc, 'fifo-0');
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck(lChange.HasEvidenceUpdate and (lRecorder.TrackedIncidentCount = 1),
    'expired oldest key may be admitted after bounded FIFO pruning');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := lUtc;
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck(Length(CompleteEvidence(lRecorder, lUtc)) = 1, 'expired key finalized afresh');
  lChange := EvidenceChange(lUtc, 'never-seen-ended');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := lUtc;
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck(not lChange.HasEvidenceUpdate, 'unknown automatic Ended is headline-only');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Started;
  ApplyEvidence(lRecorder, lChange);
  EvidenceCheck((not lChange.HasEvidenceUpdate) and (lRecorder.TrackedIncidentCount = 0) and
    (Length(CompleteEvidence(lRecorder, lUtc)) = 0), 'unknown automatic terminal path finalizes key');
  Writeln('SELFTEST PASS: finalized key FIFO bound');
end;

procedure RunEvidenceReviewRegressionSelfTests;
var
  g: TGarbos;
  lRecorder: TMachineOverviewEvidenceRecorder;
  lConfig: TMachineOverviewEvidenceConfig;
  lChange, lEvicted: TMachineOverviewIncidentChange;
  lCompleted: TArray<TMachineOverviewIncidentChange>;
  lEvidence, lDecoded: TMachineOverviewIncidentEvidence;
  lSample: TMachineOverviewProviderSample;
  lGap: TMachineOverviewEvidenceGap;
  lKind: TMachineOverviewEvidencePhaseKind;
  lUtc: TDateTime;
  lText, lError, lPair: string;
  i, lFailures, lGapCount: Integer;
begin
  g := Default(TGarbos);
  lFailures := 0;
  lUtc := EncodeDate(2026, 10, 20);
  lConfig := TMachineOverviewEvidenceConfig.Defaults;
  lConfig.PreWindowMs := 0;
  lConfig.PostWindowMs := 0;
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
  lChange := EvidenceChange(lUtc, 'evicted');
  ApplyEvidence(lRecorder, lChange);
  lRecorder.ObserveSample(EvidenceSample(EvidenceSecond(lUtc, 5), True));
  for i := 2 to 65 do
  begin
    lChange := EvidenceChange(EvidenceSecond(lUtc, i), 'eviction-' + IntToStr(i));
    ApplyEvidence(lRecorder, lChange);
  end;
  lCompleted := CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 65));
  EvidenceCheck(Length(lCompleted) = 1, 'eviction fixture finalized once');
  lEvicted := lCompleted[0];
  EvidenceCheck(lEvicted.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].ProcessSampleCount = 1,
    'eviction fixture retained During sample');
  lChange := EvidenceChange(lUtc, 'evicted');
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 70);
  ApplyEvidence(lRecorder, lChange);
  EvidenceReviewCheck((not lChange.HasEvidenceUpdate) and EvidencePayloadEmpty(lChange.Incident.Evidence),
    'evicted automatic Ended returns no evidence update', lFailures);
  lCompleted := CompleteEvidence(lRecorder, EvidenceSecond(lUtc, 70));
  EvidenceReviewCheck(Length(lCompleted) = 0, 'evicted automatic Ended never completes again', lFailures);
  // Our caller may already have the finalized snapshot when a late change arrives.
  AssertEvidencePayloadValid(lEvicted.Incident.Evidence);
  lText := MachineOverviewEvidenceToJson(lEvicted.Incident.Evidence);
  lChange := lEvicted;
  lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
  lChange.Incident.EndedAtUtc := EvidenceSecond(lUtc, 71);
  ApplyEvidence(lRecorder, lChange);
  EvidenceReviewCheck((not lChange.HasEvidenceUpdate) and EvidencePayloadEmpty(lChange.Incident.Evidence),
    'replayed finalized snapshot returns no evidence update', lFailures);
  AssertEvidencePayloadValid(lEvicted.Incident.Evidence);
  EvidenceReviewCheck((MachineOverviewEvidenceToJson(lEvicted.Incident.Evidence) = lText) and
    (lEvicted.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].ProcessSampleCount = 1),
    'late Ended preserves finalized payload and During evidence', lFailures);

  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
  lRecorder.ObserveSample(EvidenceSample(lUtc, True));
  lChange := EvidenceChange(lUtc, 'gap-boundary');
  ApplyEvidence(lRecorder, lChange);
  lRecorder.ObserveSample(EvidenceSample(lUtc + 10500 / Double(86400000), True));
  lRecorder.ObserveSample(EvidenceSample(lUtc + 21500 / Double(86400000), True));
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lGapCount := 0;
  for lGap in lEvidence.Gaps do
    if lGap.Reason = TMachineOverviewEvidenceGapReason.ProcessSamplesMissing then
      Inc(lGapCount);
  EvidenceReviewCheck(lGapCount = 0, '10.5s and exact 11s are within process gap tolerance', lFailures);
  lRecorder.ObserveSample(EvidenceSample(lUtc + 32501 / Double(86400000), True));
  lEvidence := CaptureEvidence(lRecorder, lChange);
  lGapCount := 0;
  for lGap in lEvidence.Gaps do
    if lGap.Reason = TMachineOverviewEvidenceGapReason.ProcessSamplesMissing then
      Inc(lGapCount);
  EvidenceReviewCheck(lGapCount = 1, '11.001s exceeds process gap tolerance', lFailures);

  // We apply the same threshold when completing without another process sample.
  for i := 0 to 2 do
  begin
    case i of
      0: lConfig.PostWindowMs := 10500;
      1: lConfig.PostWindowMs := 11000;
      2: lConfig.PostWindowMs := 11001;
    end;
    GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
    lRecorder.ObserveSample(EvidenceSample(lUtc, True));
    lChange := EvidenceChange(lUtc, 'trailing-gap-' + IntToStr(i));
    ApplyEvidence(lRecorder, lChange);
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.Incident.EndedAtUtc := lUtc;
    ApplyEvidence(lRecorder, lChange);
    lCompleted := CompleteEvidence(lRecorder, lUtc + lConfig.PostWindowMs / Double(86400000));
    EvidenceCheck(Length(lCompleted) = 1, 'trailing gap fixture completes');
    lGapCount := 0;
    for lGap in lCompleted[0].Incident.Evidence.Gaps do
      if lGap.Reason = TMachineOverviewEvidenceGapReason.ProcessSamplesMissing then
        Inc(lGapCount);
    EvidenceReviewCheck((lGapCount = 1) = (i = 2),
      'trailing process gap boundary ' + IntToStr(i), lFailures);
  end;
  lConfig.PostWindowMs := 0;

  lPair := WideChar($D83D) + WideChar($DE00);
  GC(lRecorder, TMachineOverviewEvidenceRecorder.Create(lConfig), g);
  lChange := EvidenceChange(lUtc, 'unicode-boundary');
  ApplyEvidence(lRecorder, lChange);
  lSample := EvidenceSample(EvidenceSecond(lUtc, 5), True, 1, 1);
  for i := 0 to High(lSample.Measurements) do
    if lSample.Measurements[i].Name = 'process_cpu_process:1' then
    begin
      lSample.Measurements[i].DisplayText := StringOfChar('n', 255) + lPair;
      lSample.Measurements[i].DetailText := StringOfChar('p', 1023) + lPair;
    end else if lSample.Measurements[i].Name = 'process_cpu_rank:1' then
      lSample.Measurements[i].DisplayText := StringOfChar('a', 255) + lPair;
  lRecorder.ObserveSample(lSample);
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lEvidence := CaptureEvidence(lRecorder, lChange);
  EvidenceReviewCheck(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].DisplayName =
    StringOfChar('n', 255), 'capture name cut preserves surrogate pair', lFailures);
  EvidenceReviewCheck(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].ImagePath =
    StringOfChar('p', 1023), 'capture path cut preserves surrogate pair', lFailures);
  EvidenceReviewCheck(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Applications[0].DisplayName =
    StringOfChar('a', 255), 'capture application name cut preserves surrogate pair', lFailures);
  lEvidence := Default(TMachineOverviewIncidentEvidence);
  lEvidence.ProcessIntervalMs := 5000;
  lEvidence.SystemIntervalMs := 1000;
  for lKind := Low(lKind) to High(lKind) do
  begin
    SetLength(lEvidence.Phases[lKind].Processes, 5);
    SetLength(lEvidence.Phases[lKind].Applications, 5);
    for i := 0 to 4 do
    begin
      lText := StringOfChar(WideChar($6F22), 63) + lPair + StringOfChar(WideChar($6F22), 191);
      lEvidence.Phases[lKind].Processes[i].DisplayName := lText;
      lEvidence.Phases[lKind].Processes[i].ImagePath := StringOfChar(WideChar($6F22), 1024);
      lEvidence.Phases[lKind].Applications[i].DisplayName := lText;
    end;
  end;
  lText := MachineOverviewEvidenceToJson(lEvidence);
  EvidenceCheck(TryMachineOverviewEvidenceFromJson(lText, lDecoded, lError), 'unicode budget JSON decodes: ' + lError);
  EvidenceReviewCheck(lDecoded.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].DisplayName =
    StringOfChar(WideChar($6F22), 63), 'JSON budget name cut preserves surrogate pair', lFailures);
  EvidenceReviewCheck(lDecoded.Phases[TMachineOverviewEvidencePhaseKind.During].Applications[0].DisplayName =
    StringOfChar(WideChar($6F22), 63), 'JSON budget application cut preserves surrogate pair', lFailures);
  EvidenceCheck(lFailures = 0, 'review regression failures: ' + IntToStr(lFailures));
  Writeln('Evidence review regressions passed');
end;

function RunMachineOverviewIncidentSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if not SameText(aArg, cMachineOverviewIncidentSelfTestArg) then
    Exit;
  try
    RunEvidenceFinalizedLifecycleSelfTest;
    RunEvidenceFinalizedFifoSelfTest;
    RunEvidenceReviewRegressionSelfTests;
    RunEvidenceAttributionSelfTest;
    RunEvidenceGapSelfTest;
    RunEvidenceBoundsSelfTest;
    RunEvidencePostWindowSelfTest(False);
    RunEvidencePostWindowSelfTest(True);
    RunEvidenceJsonRoundTripSelfTest;
    RunEvidenceCostMeasurement(1);
    RunEvidenceCostMeasurement(64);
    Result := RunHighCpuIncidentSelfTest;
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

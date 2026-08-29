unit ActiveAppView.MachineOverview.Incidents;

interface

{$SCOPEDENUMS ON}

uses
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewIncidentCategory = (HighCpu, HotLogicalProcessors,
    DpcInterrupt, ForegroundResponse, DwmFrames, MemoryPressure,
    DiskPressure, GpuSaturation, ThermalWarning, ProviderHealth,
    PipelineOverload, UserMarked);
  TMachineOverviewIncidentOrigin = (Automatic, UserMarked);
  TMachineOverviewIncidentTraceStatus = (NotRequested, Requested, Captured,
    Failed, Unavailable);
  TMachineOverviewIncidentChangeKind = (Started, Updated, Ended);

  TMachineOverviewIncidentContext = record
    CapturedAtUtc: TDateTime;
    CapturedAtMonotonicMs: UInt64;
    ProviderId: string;
    Summary: string;
  end;

  TMachineOverviewIncident = record
    StableId: string;
    Category: TMachineOverviewIncidentCategory;
    Severity: TMachineOverviewSeverity;
    Origin: TMachineOverviewIncidentOrigin;
    StartedAtUtc: TDateTime;
    PeakAtUtc: TDateTime;
    EndedAtUtc: TDateTime;
    LocalDisplayTime: string;
    Summary: string;
    Explanation: string;
    ThresholdText: string;
    PeakValue: Double;
    ProviderId: string;
    ProviderFreshnessMs: UInt64;
    RelatedEntityIds: TArray<string>;
    RelatedExecutablePaths: TArray<string>;
    TraceStatus: TMachineOverviewIncidentTraceStatus;
    PreContext: TArray<TMachineOverviewIncidentContext>;
    PostContext: TArray<TMachineOverviewIncidentContext>;
  end;

  TMachineOverviewIncidentChange = record
    Kind: TMachineOverviewIncidentChangeKind;
    Incident: TMachineOverviewIncident;
  end;

  TMachineOverviewIncidentSignals = record
    CapturedAtUtc: TDateTime;
    CapturedAtMonotonicMs: UInt64;
    TotalCpu: TMachineOverviewOptionalDouble;
    HotLogicalProcessorCount: Integer;
    DpcPercent: TMachineOverviewOptionalDouble;
    InterruptPercent: TMachineOverviewOptionalDouble;
    ForegroundReplyMs: TMachineOverviewOptionalDouble;
    ForegroundTimedOut: Boolean;
    DwmMissedFrames: Integer;
    PhysicalUsedPercent: TMachineOverviewOptionalDouble;
    PagingBytesPerSecond: TMachineOverviewOptionalDouble;
    DiskActivePercent: TMachineOverviewOptionalDouble;
    DiskLatencyMs: TMachineOverviewOptionalDouble;
    DiskQueueLength: TMachineOverviewOptionalDouble;
    GpuPercent: TMachineOverviewOptionalDouble;
    TemperatureCelsius: TMachineOverviewOptionalDouble;
    ProviderId: string;
    ProviderStatus: TMachineOverviewProviderStatus;
    ProviderFreshnessMs: UInt64;
    RecordsDroppedDelta: Int64;
    SQLiteCommitDurationMs: UInt64;
    SQLiteError: string;
    RelatedEntityIds: TArray<string>;
    RelatedExecutablePaths: TArray<string>;
    ContextSummary: string;
  end;

  TMachineOverviewIncidentThresholds = record
    HighCpuActivationPercent: Double;
    HighCpuRecoveryPercent: Double;
    HighCpuActivationDurationMs: UInt64;
    HighCpuRecoveryDurationMs: UInt64;
    PreContextDurationMs: UInt64;
    PostContextDurationMs: UInt64;
    SignalActivationDurationMs: UInt64;
    SignalRecoveryDurationMs: UInt64;
    HotLogicalProcessorCount: Integer;
    DpcInterruptPercent: Double;
    ForegroundReplyMs: Double;
    DwmMissedFrames: Integer;
    PhysicalUsedPercent: Double;
    PagingBytesPerSecond: Double;
    DiskActivePercent: Double;
    DiskLatencyMs: Double;
    DiskQueueLength: Double;
    GpuPercent: Double;
    TemperatureCelsius: Double;
    ProviderStaleMs: UInt64;
    SQLiteSlowCommitMs: UInt64;
    class function Defaults: TMachineOverviewIncidentThresholds; static;
  end;

  TMachineOverviewIncidentDetector = class
  private
    fState: TObject;
  public
    constructor Create(const aThresholds: TMachineOverviewIncidentThresholds);
    destructor Destroy; override;
    function Accept(const aSignals: TMachineOverviewIncidentSignals):
      TArray<TMachineOverviewIncidentChange>;
    function MarkUserSlowdown(const aSignals: TMachineOverviewIncidentSignals;
      const aSummary: string): TMachineOverviewIncidentChange;
  end;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.Math, System.SysUtils;

type
  TMachineOverviewIncidentRuleState = record
    Active: Boolean;
    CandidateSinceMs: UInt64;
    Incident: TMachineOverviewIncident;
    RecoverySinceMs: UInt64;
  end;

  TMachineOverviewPendingIncident = record
    CaptureUntilMonotonicMs: UInt64;
    Incident: TMachineOverviewIncident;
  end;

  TMachineOverviewIncidentRuleEvaluation = record
    Explanation: string;
    PeakValue: Double;
    Recovered: Boolean;
    Severity: TMachineOverviewSeverity;
    Summary: string;
    ThresholdText: string;
    Triggered: Boolean;
  end;

  TMachineOverviewIncidentDetectorState = class
  public
    Context: TList<TMachineOverviewIncidentContext>;
    PendingIncidents: TList<TMachineOverviewPendingIncident>;
    Rules: array[TMachineOverviewIncidentCategory] of
      TMachineOverviewIncidentRuleState;
    Thresholds: TMachineOverviewIncidentThresholds;
    constructor Create(const aThresholds: TMachineOverviewIncidentThresholds);
    destructor Destroy; override;
  end;

constructor TMachineOverviewIncidentDetectorState.Create(
  const aThresholds: TMachineOverviewIncidentThresholds);
begin
  inherited Create;
  Thresholds := aThresholds;
  Context := TList<TMachineOverviewIncidentContext>.Create;
  PendingIncidents := TList<TMachineOverviewPendingIncident>.Create;
end;

destructor TMachineOverviewIncidentDetectorState.Destroy;
begin
  PendingIncidents.Free;
  Context.Free;
  inherited Destroy;
end;

function GetIncidentDetectorState(const aState: TObject):
  TMachineOverviewIncidentDetectorState;
begin
  Result := aState as TMachineOverviewIncidentDetectorState;
end;

function CreateIncidentContext(
  const aSignals: TMachineOverviewIncidentSignals):
  TMachineOverviewIncidentContext;
begin
  Result := Default(TMachineOverviewIncidentContext);
  Result.CapturedAtUtc := aSignals.CapturedAtUtc;
  Result.CapturedAtMonotonicMs := aSignals.CapturedAtMonotonicMs;
  Result.ProviderId := aSignals.ProviderId;
  Result.Summary := aSignals.ContextSummary;
end;

procedure AppendIncidentContext(
  var aValues: TArray<TMachineOverviewIncidentContext>;
  const aValue: TMachineOverviewIncidentContext);
var
  lIndex: Integer;
begin
  lIndex := Length(aValues);
  SetLength(aValues, lIndex + 1);
  aValues[lIndex] := aValue;
end;

procedure AppendIncidentChange(
  var aChanges: TArray<TMachineOverviewIncidentChange>;
  const aKind: TMachineOverviewIncidentChangeKind;
  const aIncident: TMachineOverviewIncident);
var
  lIndex: Integer;
begin
  lIndex := Length(aChanges);
  SetLength(aChanges, lIndex + 1);
  aChanges[lIndex].Kind := aKind;
  aChanges[lIndex].Incident := aIncident;
end;

procedure AddCurrentContext(
  const aState: TMachineOverviewIncidentDetectorState;
  const aSignals: TMachineOverviewIncidentSignals);
var
  lContext: TMachineOverviewIncidentContext;
begin
  lContext := CreateIncidentContext(aSignals);
  aState.Context.Add(lContext);
  while (aState.Context.Count > 0) and
    (aSignals.CapturedAtMonotonicMs >=
      aState.Context[0].CapturedAtMonotonicMs) and
    ((aSignals.CapturedAtMonotonicMs -
      aState.Context[0].CapturedAtMonotonicMs) >
      aState.Thresholds.PreContextDurationMs) do
    aState.Context.Delete(0);
end;

function IncidentCategoryKey(
  const aCategory: TMachineOverviewIncidentCategory): string;
begin
  case aCategory of
    TMachineOverviewIncidentCategory.HighCpu:
      Result := 'high-cpu';
    TMachineOverviewIncidentCategory.HotLogicalProcessors:
      Result := 'hot-logical-processors';
    TMachineOverviewIncidentCategory.DpcInterrupt:
      Result := 'dpc-interrupt';
    TMachineOverviewIncidentCategory.ForegroundResponse:
      Result := 'foreground-response';
    TMachineOverviewIncidentCategory.DwmFrames:
      Result := 'dwm-frames';
    TMachineOverviewIncidentCategory.MemoryPressure:
      Result := 'memory-pressure';
    TMachineOverviewIncidentCategory.DiskPressure:
      Result := 'disk-pressure';
    TMachineOverviewIncidentCategory.GpuSaturation:
      Result := 'gpu-saturation';
    TMachineOverviewIncidentCategory.ThermalWarning:
      Result := 'thermal-warning';
    TMachineOverviewIncidentCategory.ProviderHealth:
      Result := 'provider-health';
    TMachineOverviewIncidentCategory.PipelineOverload:
      Result := 'pipeline-overload';
    TMachineOverviewIncidentCategory.UserMarked:
      Result := 'user-marked';
  else
    Result := 'unknown';
  end;
end;

function IncidentUtcMilliseconds(const aValue: TDateTime): Int64;
begin
  Result := (DateTimeToUnix(aValue, True) * 1000) + MilliSecondOf(aValue);
end;

function BuildRuleEvaluation(
  const aCategory: TMachineOverviewIncidentCategory;
  const aThresholds: TMachineOverviewIncidentThresholds;
  const aSignals: TMachineOverviewIncidentSignals):
  TMachineOverviewIncidentRuleEvaluation;
var
  lDpcValue: Double;
  lPagingMegabytes: Double;
begin
  Result := Default(TMachineOverviewIncidentRuleEvaluation);
  Result.Severity := TMachineOverviewSeverity.Warning;
  case aCategory of
    TMachineOverviewIncidentCategory.HighCpu:
      begin
        Result.Triggered := aSignals.TotalCpu.Available and
          (aSignals.TotalCpu.Value >= aThresholds.HighCpuActivationPercent);
        Result.Recovered := aSignals.TotalCpu.Available and
          (aSignals.TotalCpu.Value <= aThresholds.HighCpuRecoveryPercent);
        Result.PeakValue := aSignals.TotalCpu.Value;
        Result.Summary := Format('Sustained total CPU %.1f%%',
          [aSignals.TotalCpu.Value], TFormatSettings.Invariant);
        Result.Explanation :=
          'Total CPU remained above the activation threshold';
        Result.ThresholdText := Format('activate >= %.1f%% for %d ms; ' +
          'recover <= %.1f%% for %d ms',
          [aThresholds.HighCpuActivationPercent,
           aThresholds.HighCpuActivationDurationMs,
           aThresholds.HighCpuRecoveryPercent,
           aThresholds.HighCpuRecoveryDurationMs],
          TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.HotLogicalProcessors:
      begin
        Result.Triggered := aSignals.HotLogicalProcessorCount >=
          aThresholds.HotLogicalProcessorCount;
        Result.Recovered := aSignals.HotLogicalProcessorCount = 0;
        Result.PeakValue := aSignals.HotLogicalProcessorCount;
        Result.Summary := Format('%d logical processors are hot',
          [aSignals.HotLogicalProcessorCount]);
        Result.Explanation :=
          'Several logical processors remained locally saturated';
        Result.ThresholdText := Format('activate >= %d hot processors; ' +
          'recover at 0', [aThresholds.HotLogicalProcessorCount]);
      end;
    TMachineOverviewIncidentCategory.DpcInterrupt:
      begin
        lDpcValue := 0;
        if aSignals.DpcPercent.Available then
          lDpcValue := aSignals.DpcPercent.Value;
        if aSignals.InterruptPercent.Available then
          lDpcValue := Max(lDpcValue, aSignals.InterruptPercent.Value);
        Result.Triggered :=
          (aSignals.DpcPercent.Available or
           aSignals.InterruptPercent.Available) and
          (lDpcValue >= aThresholds.DpcInterruptPercent);
        Result.Recovered := aSignals.DpcPercent.Available and
          aSignals.InterruptPercent.Available and
          (aSignals.DpcPercent.Value <= 5) and
          (aSignals.InterruptPercent.Value <= 5);
        Result.PeakValue := lDpcValue;
        Result.Summary := Format('DPC or interrupt time reached %.1f%%',
          [lDpcValue], TFormatSettings.Invariant);
        Result.Explanation :=
          'DPC or interrupt processing remained elevated';
        Result.ThresholdText := Format('activate >= %.1f%%; recover <= 5.0%%',
          [aThresholds.DpcInterruptPercent], TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.ForegroundResponse:
      begin
        Result.Triggered := aSignals.ForegroundTimedOut or
          (aSignals.ForegroundReplyMs.Available and
           (aSignals.ForegroundReplyMs.Value >=
            aThresholds.ForegroundReplyMs));
        Result.Recovered := (not aSignals.ForegroundTimedOut) and
          aSignals.ForegroundReplyMs.Available and
          (aSignals.ForegroundReplyMs.Value <= 250);
        if aSignals.ForegroundReplyMs.Available then
          Result.PeakValue := aSignals.ForegroundReplyMs.Value;
        if aSignals.ForegroundTimedOut then
        begin
          Result.Severity := TMachineOverviewSeverity.Critical;
          Result.Summary := 'Foreground application stopped responding';
        end else
          Result.Summary := Format(
            'Foreground application reply reached %.0f ms',
            [aSignals.ForegroundReplyMs.Value], TFormatSettings.Invariant);
        Result.Explanation :=
          'The foreground window did not answer a bounded responsiveness probe';
        Result.ThresholdText := Format('activate on timeout or >= %.0f ms; ' +
          'recover <= 250 ms', [aThresholds.ForegroundReplyMs],
          TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.DwmFrames:
      begin
        Result.Triggered := aSignals.DwmMissedFrames >=
          aThresholds.DwmMissedFrames;
        Result.Recovered := aSignals.DwmMissedFrames = 0;
        Result.PeakValue := aSignals.DwmMissedFrames;
        Result.Summary := Format('DWM missed-frame burst reached %d frames',
          [aSignals.DwmMissedFrames]);
        Result.Explanation :=
          'Desktop composition reported a burst of missed frames';
        Result.ThresholdText := Format('activate >= %d missed frames; ' +
          'recover at 0', [aThresholds.DwmMissedFrames]);
      end;
    TMachineOverviewIncidentCategory.MemoryPressure:
      begin
        lPagingMegabytes := 0;
        if aSignals.PagingBytesPerSecond.Available then
          lPagingMegabytes := aSignals.PagingBytesPerSecond.Value /
            (1024 * 1024);
        Result.Triggered :=
          (aSignals.PhysicalUsedPercent.Available and
           (aSignals.PhysicalUsedPercent.Value >=
            aThresholds.PhysicalUsedPercent)) or
          (aSignals.PagingBytesPerSecond.Available and
           (aSignals.PagingBytesPerSecond.Value >=
            aThresholds.PagingBytesPerSecond));
        Result.Recovered := aSignals.PhysicalUsedPercent.Available and
          aSignals.PagingBytesPerSecond.Available and
          (aSignals.PhysicalUsedPercent.Value <= 90) and
          (aSignals.PagingBytesPerSecond.Value <= 10 * 1024 * 1024);
        if aSignals.PhysicalUsedPercent.Available and
          (aSignals.PhysicalUsedPercent.Value >=
           aThresholds.PhysicalUsedPercent) then
        begin
          Result.PeakValue := aSignals.PhysicalUsedPercent.Value;
          Result.Summary := Format('Physical memory use reached %.1f%%',
            [aSignals.PhysicalUsedPercent.Value], TFormatSettings.Invariant);
        end else
        begin
          Result.PeakValue := lPagingMegabytes;
          Result.Summary := Format('Paging reached %.1f MB/s',
            [lPagingMegabytes], TFormatSettings.Invariant);
        end;
        Result.Severity := TMachineOverviewSeverity.Critical;
        Result.Explanation :=
          'Physical-memory pressure or paging remained severe';
        Result.ThresholdText := Format(
          'activate >= %.1f%% used or >= %.0f MB/s paging',
          [aThresholds.PhysicalUsedPercent,
           aThresholds.PagingBytesPerSecond / (1024 * 1024)],
          TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.DiskPressure:
      begin
        Result.Triggered := aSignals.DiskActivePercent.Available and
          (aSignals.DiskActivePercent.Value >=
           aThresholds.DiskActivePercent) and
          ((aSignals.DiskLatencyMs.Available and
            (aSignals.DiskLatencyMs.Value >= aThresholds.DiskLatencyMs)) or
           (aSignals.DiskQueueLength.Available and
            (aSignals.DiskQueueLength.Value >=
             aThresholds.DiskQueueLength)));
        Result.Recovered := aSignals.DiskLatencyMs.Available and
          aSignals.DiskQueueLength.Available and
          (aSignals.DiskLatencyMs.Value <= 20) and
          (aSignals.DiskQueueLength.Value <= 1.5);
        if aSignals.DiskLatencyMs.Available then
          Result.PeakValue := aSignals.DiskLatencyMs.Value;
        Result.Summary := Format('Disk latency reached %.1f ms',
          [Result.PeakValue], TFormatSettings.Invariant);
        Result.Explanation :=
          'Disk latency or queue remained elevated with supporting activity';
        Result.ThresholdText := Format('activate with >= %.1f%% active and ' +
          '>= %.1f ms latency or >= %.1f queue',
          [aThresholds.DiskActivePercent, aThresholds.DiskLatencyMs,
           aThresholds.DiskQueueLength], TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.GpuSaturation:
      begin
        Result.Triggered := aSignals.GpuPercent.Available and
          (aSignals.GpuPercent.Value >= aThresholds.GpuPercent);
        Result.Recovered := aSignals.GpuPercent.Available and
          (aSignals.GpuPercent.Value <= 85);
        Result.PeakValue := aSignals.GpuPercent.Value;
        Result.Summary := Format('GPU use reached %.1f%%',
          [aSignals.GpuPercent.Value], TFormatSettings.Invariant);
        Result.Explanation := 'GPU use remained saturated';
        Result.ThresholdText := Format('activate >= %.1f%%; recover <= 85.0%%',
          [aThresholds.GpuPercent], TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.ThermalWarning:
      begin
        Result.Triggered := aSignals.TemperatureCelsius.Available and
          (aSignals.TemperatureCelsius.Value >=
           aThresholds.TemperatureCelsius);
        Result.Recovered := aSignals.TemperatureCelsius.Available and
          (aSignals.TemperatureCelsius.Value <= 80);
        Result.PeakValue := aSignals.TemperatureCelsius.Value;
        Result.Severity := TMachineOverviewSeverity.Critical;
        Result.Summary := Format('Temperature reached %.1f C',
          [aSignals.TemperatureCelsius.Value], TFormatSettings.Invariant);
        Result.Explanation :=
          'A temperature provider reported a sustained thermal warning';
        Result.ThresholdText := Format('activate >= %.1f C; recover <= 80.0 C',
          [aThresholds.TemperatureCelsius], TFormatSettings.Invariant);
      end;
    TMachineOverviewIncidentCategory.ProviderHealth:
      begin
        Result.Triggered :=
          (aSignals.ProviderStatus <> TMachineOverviewProviderStatus.Available) or
          (aSignals.ProviderFreshnessMs > aThresholds.ProviderStaleMs);
        Result.Recovered :=
          (aSignals.ProviderStatus = TMachineOverviewProviderStatus.Available) and
          (aSignals.ProviderFreshnessMs <= 5000);
        Result.PeakValue := aSignals.ProviderFreshnessMs;
        if aSignals.ProviderStatus = TMachineOverviewProviderStatus.Failed then
          Result.Severity := TMachineOverviewSeverity.Critical;
        Result.Summary := Format('Provider %s is unavailable or stale',
          [aSignals.ProviderId]);
        Result.Explanation :=
          'Monitoring data stopped, failed, or exceeded its freshness budget';
        Result.ThresholdText := Format('activate on failure or age > %d ms; ' +
          'recover available with age <= 5000 ms',
          [aThresholds.ProviderStaleMs]);
      end;
    TMachineOverviewIncidentCategory.PipelineOverload:
      begin
        Result.Triggered := (aSignals.RecordsDroppedDelta > 0) or
          (not aSignals.SQLiteError.IsEmpty) or
          (aSignals.SQLiteCommitDurationMs >=
           aThresholds.SQLiteSlowCommitMs);
        Result.Recovered := (aSignals.RecordsDroppedDelta = 0) and
          aSignals.SQLiteError.IsEmpty and
          (aSignals.SQLiteCommitDurationMs < 500);
        Result.PeakValue := Max(Double(aSignals.RecordsDroppedDelta),
          Double(aSignals.SQLiteCommitDurationMs));
        if not aSignals.SQLiteError.IsEmpty then
          Result.Severity := TMachineOverviewSeverity.Critical;
        Result.Summary := Format(
          'Monitoring backlog dropped %d records; SQLite commit %d ms',
          [aSignals.RecordsDroppedDelta, aSignals.SQLiteCommitDurationMs]);
        Result.Explanation :=
          'Collection or history persistence exceeded its bounded capacity';
        Result.ThresholdText := Format(
          'activate on drops, database error, or commit >= %d ms',
          [aThresholds.SQLiteSlowCommitMs]);
      end;
    TMachineOverviewIncidentCategory.UserMarked:
      Result.Triggered := False;
  end;
end;

function CreateAutomaticIncident(
  const aState: TMachineOverviewIncidentDetectorState;
  const aCategory: TMachineOverviewIncidentCategory;
  const aEvaluation: TMachineOverviewIncidentRuleEvaluation;
  const aSignals: TMachineOverviewIncidentSignals;
  const aStartedAtUtc: TDateTime): TMachineOverviewIncident;
var
  lStartedUtcMs: Int64;
begin
  Result := Default(TMachineOverviewIncident);
  lStartedUtcMs := IncidentUtcMilliseconds(aStartedAtUtc);
  Result.StableId := IncidentCategoryKey(aCategory) + '-' +
    IntToStr(lStartedUtcMs);
  Result.Category := aCategory;
  Result.Severity := aEvaluation.Severity;
  Result.Origin := TMachineOverviewIncidentOrigin.Automatic;
  Result.StartedAtUtc := aStartedAtUtc;
  Result.PeakAtUtc := aSignals.CapturedAtUtc;
  Result.LocalDisplayTime := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    TTimeZone.Local.ToLocalTime(aStartedAtUtc));
  Result.Summary := aEvaluation.Summary;
  Result.Explanation := aEvaluation.Explanation;
  Result.ThresholdText := aEvaluation.ThresholdText;
  Result.PeakValue := aEvaluation.PeakValue;
  Result.ProviderId := aSignals.ProviderId;
  Result.ProviderFreshnessMs := aSignals.ProviderFreshnessMs;
  Result.RelatedEntityIds := Copy(aSignals.RelatedEntityIds);
  Result.RelatedExecutablePaths := Copy(aSignals.RelatedExecutablePaths);
  Result.TraceStatus := TMachineOverviewIncidentTraceStatus.NotRequested;
  Result.PreContext := aState.Context.ToArray;
end;

function ActivationDurationMs(
  const aState: TMachineOverviewIncidentDetectorState;
  const aCategory: TMachineOverviewIncidentCategory): UInt64;
begin
  if aCategory = TMachineOverviewIncidentCategory.HighCpu then
    Result := aState.Thresholds.HighCpuActivationDurationMs
  else
    Result := aState.Thresholds.SignalActivationDurationMs;
end;

function RecoveryDurationMs(
  const aState: TMachineOverviewIncidentDetectorState;
  const aCategory: TMachineOverviewIncidentCategory): UInt64;
begin
  if aCategory = TMachineOverviewIncidentCategory.HighCpu then
    Result := aState.Thresholds.HighCpuRecoveryDurationMs
  else
    Result := aState.Thresholds.SignalRecoveryDurationMs;
end;

procedure CapturePendingPostContext(
  const aState: TMachineOverviewIncidentDetectorState;
  const aSignals: TMachineOverviewIncidentSignals;
  var aChanges: TArray<TMachineOverviewIncidentChange>);
var
  i: Integer;
  lContext: TMachineOverviewIncidentContext;
  lPending: TMachineOverviewPendingIncident;
begin
  lContext := CreateIncidentContext(aSignals);
  for i := aState.PendingIncidents.Count - 1 downto 0 do
  begin
    lPending := aState.PendingIncidents[i];
    if aSignals.CapturedAtMonotonicMs <=
      lPending.CaptureUntilMonotonicMs then
      AppendIncidentContext(lPending.Incident.PostContext, lContext);
    if aSignals.CapturedAtMonotonicMs >=
      lPending.CaptureUntilMonotonicMs then
    begin
      AppendIncidentChange(aChanges,
        TMachineOverviewIncidentChangeKind.Updated, lPending.Incident);
      aState.PendingIncidents.Delete(i);
    end else
      aState.PendingIncidents[i] := lPending;
  end;
end;

class function TMachineOverviewIncidentThresholds.Defaults:
  TMachineOverviewIncidentThresholds;
begin
  Result := Default(TMachineOverviewIncidentThresholds);
  Result.HighCpuActivationPercent := 90;
  Result.HighCpuRecoveryPercent := 75;
  Result.HighCpuActivationDurationMs := 15000;
  Result.HighCpuRecoveryDurationMs := 10000;
  Result.PreContextDurationMs := 5 * 60 * 1000;
  Result.PostContextDurationMs := 10 * 60 * 1000;
  Result.SignalActivationDurationMs := 5000;
  Result.SignalRecoveryDurationMs := 5000;
  Result.HotLogicalProcessorCount := 2;
  Result.DpcInterruptPercent := 15;
  Result.ForegroundReplyMs := 1000;
  Result.DwmMissedFrames := 5;
  Result.PhysicalUsedPercent := 95;
  Result.PagingBytesPerSecond := 100 * 1024 * 1024;
  Result.DiskActivePercent := 70;
  Result.DiskLatencyMs := 50;
  Result.DiskQueueLength := 4;
  Result.GpuPercent := 98;
  Result.TemperatureCelsius := 90;
  Result.ProviderStaleMs := 10000;
  Result.SQLiteSlowCommitMs := 1000;
end;

constructor TMachineOverviewIncidentDetector.Create(
  const aThresholds: TMachineOverviewIncidentThresholds);
begin
  inherited Create;
  if (aThresholds.HighCpuActivationDurationMs = 0) or
    (aThresholds.HighCpuRecoveryDurationMs = 0) or
    (aThresholds.PreContextDurationMs = 0) or
    (aThresholds.PostContextDurationMs = 0) or
    (aThresholds.SignalActivationDurationMs = 0) or
    (aThresholds.SignalRecoveryDurationMs = 0) then
    raise EArgumentException.Create('Incident durations must be positive');
  fState := TMachineOverviewIncidentDetectorState.Create(aThresholds);
end;

destructor TMachineOverviewIncidentDetector.Destroy;
begin
  fState.Free;
  inherited Destroy;
end;

function TMachineOverviewIncidentDetector.Accept(
  const aSignals: TMachineOverviewIncidentSignals):
  TArray<TMachineOverviewIncidentChange>;
var
  lActivationDurationMs: UInt64;
  lCategory: TMachineOverviewIncidentCategory;
  lContext: TMachineOverviewIncidentContext;
  lEvaluation: TMachineOverviewIncidentRuleEvaluation;
  lPending: TMachineOverviewPendingIncident;
  lRecoveryDurationMs: UInt64;
  lRule: TMachineOverviewIncidentRuleState;
  lStartedAtUtc: TDateTime;
  lState: TMachineOverviewIncidentDetectorState;
begin
  Result := nil;
  lState := GetIncidentDetectorState(fState);
  CapturePendingPostContext(lState, aSignals, Result);
  AddCurrentContext(lState, aSignals);
  lContext := CreateIncidentContext(aSignals);
  for lCategory := TMachineOverviewIncidentCategory.HighCpu to
    TMachineOverviewIncidentCategory.PipelineOverload do
  begin
    lRule := lState.Rules[lCategory];
    lEvaluation := BuildRuleEvaluation(lCategory, lState.Thresholds,
      aSignals);
    lActivationDurationMs := ActivationDurationMs(lState, lCategory);
    lRecoveryDurationMs := RecoveryDurationMs(lState, lCategory);
    if not lRule.Active then
    begin
      if not lEvaluation.Triggered then
      begin
        lRule.CandidateSinceMs := 0;
        lState.Rules[lCategory] := lRule;
        Continue;
      end;
      if lRule.CandidateSinceMs = 0 then
      begin
        lRule.CandidateSinceMs := aSignals.CapturedAtMonotonicMs;
        lState.Rules[lCategory] := lRule;
        Continue;
      end;
      if (aSignals.CapturedAtMonotonicMs < lRule.CandidateSinceMs) or
        ((aSignals.CapturedAtMonotonicMs - lRule.CandidateSinceMs) <
         lActivationDurationMs) then
      begin
        lState.Rules[lCategory] := lRule;
        Continue;
      end;
      lStartedAtUtc := IncMilliSecond(aSignals.CapturedAtUtc,
        -Int64(aSignals.CapturedAtMonotonicMs -
          lRule.CandidateSinceMs));
      lRule.Incident := CreateAutomaticIncident(lState, lCategory,
        lEvaluation, aSignals, lStartedAtUtc);
      lRule.Active := True;
      lRule.RecoverySinceMs := 0;
      lState.Rules[lCategory] := lRule;
      AppendIncidentChange(Result,
        TMachineOverviewIncidentChangeKind.Started, lRule.Incident);
      Continue;
    end;
    if lEvaluation.Triggered then
    begin
      lRule.RecoverySinceMs := 0;
      if lEvaluation.PeakValue > lRule.Incident.PeakValue then
      begin
        lRule.Incident.PeakValue := lEvaluation.PeakValue;
        lRule.Incident.PeakAtUtc := aSignals.CapturedAtUtc;
        lRule.Incident.Summary := lEvaluation.Summary;
        lRule.Incident.ProviderFreshnessMs :=
          aSignals.ProviderFreshnessMs;
        AppendIncidentChange(Result,
          TMachineOverviewIncidentChangeKind.Updated, lRule.Incident);
      end;
      lState.Rules[lCategory] := lRule;
      Continue;
    end;
    if not lEvaluation.Recovered then
    begin
      lRule.RecoverySinceMs := 0;
      lState.Rules[lCategory] := lRule;
      Continue;
    end;
    AppendIncidentContext(lRule.Incident.PostContext, lContext);
    if lRule.RecoverySinceMs = 0 then
    begin
      lRule.RecoverySinceMs := aSignals.CapturedAtMonotonicMs;
      lState.Rules[lCategory] := lRule;
      Continue;
    end;
    if (aSignals.CapturedAtMonotonicMs < lRule.RecoverySinceMs) or
      ((aSignals.CapturedAtMonotonicMs - lRule.RecoverySinceMs) <
       lRecoveryDurationMs) then
    begin
      lState.Rules[lCategory] := lRule;
      Continue;
    end;
    lRule.Incident.EndedAtUtc := aSignals.CapturedAtUtc;
    AppendIncidentChange(Result, TMachineOverviewIncidentChangeKind.Ended,
      lRule.Incident);
    lPending := Default(TMachineOverviewPendingIncident);
    lPending.Incident := lRule.Incident;
    lPending.CaptureUntilMonotonicMs :=
      aSignals.CapturedAtMonotonicMs +
      lState.Thresholds.PostContextDurationMs;
    lState.PendingIncidents.Add(lPending);
    lRule := Default(TMachineOverviewIncidentRuleState);
    lState.Rules[lCategory] := lRule;
  end;
end;

function TMachineOverviewIncidentDetector.MarkUserSlowdown(
  const aSignals: TMachineOverviewIncidentSignals;
  const aSummary: string): TMachineOverviewIncidentChange;
var
  lIncident: TMachineOverviewIncident;
  lState: TMachineOverviewIncidentDetectorState;
begin
  lState := GetIncidentDetectorState(fState);
  AddCurrentContext(lState, aSignals);
  lIncident := Default(TMachineOverviewIncident);
  lIncident.StableId := 'user-marked-' +
    IntToStr(IncidentUtcMilliseconds(aSignals.CapturedAtUtc));
  lIncident.Category := TMachineOverviewIncidentCategory.UserMarked;
  lIncident.Severity := TMachineOverviewSeverity.Notice;
  lIncident.Origin := TMachineOverviewIncidentOrigin.UserMarked;
  lIncident.StartedAtUtc := aSignals.CapturedAtUtc;
  lIncident.PeakAtUtc := aSignals.CapturedAtUtc;
  lIncident.EndedAtUtc := aSignals.CapturedAtUtc;
  lIncident.LocalDisplayTime := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    TTimeZone.Local.ToLocalTime(aSignals.CapturedAtUtc));
  lIncident.Summary := Trim(aSummary);
  if lIncident.Summary.IsEmpty then
    lIncident.Summary := 'User marked slowdown';
  lIncident.Explanation :=
    'The user marked this point in time for later investigation';
  lIncident.ThresholdText := 'user marked';
  lIncident.ProviderId := aSignals.ProviderId;
  lIncident.ProviderFreshnessMs := aSignals.ProviderFreshnessMs;
  lIncident.RelatedEntityIds := Copy(aSignals.RelatedEntityIds);
  lIncident.RelatedExecutablePaths :=
    Copy(aSignals.RelatedExecutablePaths);
  lIncident.TraceStatus := TMachineOverviewIncidentTraceStatus.NotRequested;
  lIncident.PreContext := lState.Context.ToArray;
  Result.Kind := TMachineOverviewIncidentChangeKind.Ended;
  Result.Incident := lIncident;
end;

end.

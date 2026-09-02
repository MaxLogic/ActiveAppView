unit ActiveAppView.MachineOverview.Domain;

interface

uses
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewRollingMeasurements = class
  private
    fState: TObject;
  public
    constructor Create(const aRetentionMs: UInt64);
    destructor Destroy; override;
    procedure Observe(const aSeriesId: string;
      const aMonotonicMs: UInt64;
      const aValue: TMachineOverviewOptionalDouble);
    procedure Prune(const aNowMonotonicMs: UInt64);
    function Statistics(const aSeriesId: string;
      const aNowMonotonicMs, aWindowMs: UInt64;
      const aExpectedIntervalMs: Cardinal;
      const aMinimumCoveragePercent: Double): TMachineOverviewWindowStatistics;
    function TryMinimum(const aSeriesId: string;
      const aNowMonotonicMs, aWindowMs: UInt64;
      out aMinimum: Double): Boolean;
    function RetainedValueCount: Integer;
  end;

  TMachineOverviewDomainAggregator = class
  private
    fState: TObject;
  public
    constructor Create(const aExpectedIntervalMs: Cardinal;
      const aMinimumCoveragePercent: Double);
    destructor Destroy; override;
    procedure AcceptCpuSample(const aSample: IMachineOverviewCpuSample);
    function BuildCpuAggregate(
      const aNowMonotonicMs: UInt64): TMachineOverviewCpuAggregate;
    function RetainedCpuValueCount: Integer;
  end;

function CreateMachineOverviewCpuSample(const aCapturedAtMonotonicMs: UInt64;
  const aCapturedAtUtc: TDateTime; const aTotalCpu: TMachineOverviewOptionalDouble;
  const aLogicalProcessors: TArray<TMachineOverviewOptionalDouble>): IMachineOverviewCpuSample;
function MachineOverviewProviderStatusAt(const aState: TMachineOverviewProviderState;
  const aNowMonotonicMs, aStaleAfterMs: UInt64): TMachineOverviewProviderStatus;
function MachineOverviewWindowStatusText(
  const aStatistics: TMachineOverviewWindowStatistics): string;
function MachineOverviewProcessIdentityKey(
  const aIdentity: TMachineOverviewProcessIdentity): string;
function MachineOverviewDiskIdentityKey(
  const aIdentity: TMachineOverviewDiskIdentity): string;
function TryNormalizeMachineOverviewProcessCpu(const aRawPercent: Double;
  const aLogicalProcessorCount: Integer; out aNormalizedPercent: Double): Boolean;
function RankMachineOverviewProcesses(const aMetrics: TArray<TMachineOverviewProcessMetric>;
  const aMaximumCount: Integer): TArray<TMachineOverviewRankedProcess>;
function TrySelectWorstMachineOverviewDisk(const aMetrics: TArray<TMachineOverviewDiskMetric>;
  out aSelection: TMachineOverviewDiskSelection): Boolean;

implementation

uses
  System.Classes, System.Generics.Collections, System.Generics.Defaults, System.Math,
  System.SysUtils,
  Winapi.Windows;

type
  TMachineOverviewTimedValue = record
    MonotonicMs: UInt64;
    Value: Double;
  end;

  TMachineOverviewValueSeries = class
  private
    fFirstObservationMs: UInt64;
    fHasObservation: Boolean;
    fLastObservationMs: UInt64;
    fValues: TList<TMachineOverviewTimedValue>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Observe(const aMonotonicMs: UInt64;
      const aValue: TMachineOverviewOptionalDouble);
    procedure PruneBeforeOrAt(const aMonotonicMs: UInt64);
  end;

  TMachineOverviewRollingState = class
  public
    OwnerThreadId: Cardinal;
    RetentionMs: UInt64;
    Series: TObjectDictionary<string, TMachineOverviewValueSeries>;
    constructor Create(const aRetentionMs: UInt64);
    destructor Destroy; override;
  end;

  TMachineOverviewDomainState = class
  public
    ExpectedIntervalMs: Cardinal;
    LastAcceptedMonotonicMs: UInt64;
    LatestLogicalProcessorCount: Integer;
    LogicalProcessorSeries: TObjectList<TMachineOverviewValueSeries>;
    MinimumCoveragePercent: Double;
    OwnerThreadId: Cardinal;
    TotalCpuSeries: TMachineOverviewValueSeries;
    constructor Create(const aExpectedIntervalMs: Cardinal;
      const aMinimumCoveragePercent: Double);
    destructor Destroy; override;
  end;

  TMachineOverviewCpuSample = class(TInterfacedObject, IMachineOverviewCpuSample)
  private
    fCapturedAtMonotonicMs: UInt64;
    fCapturedAtUtc: TDateTime;
    fLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
    fTotalCpu: TMachineOverviewOptionalDouble;
  public
    constructor Create(const aCapturedAtMonotonicMs: UInt64;
      const aCapturedAtUtc: TDateTime; const aTotalCpu: TMachineOverviewOptionalDouble;
      const aLogicalProcessors: TArray<TMachineOverviewOptionalDouble>);
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function TotalCpu: TMachineOverviewOptionalDouble;
    function LogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  end;

const
  cMachineOverviewCriticalDiskLatencyMs = 100.0;
  cMachineOverviewWarningDiskLatencyMs = 30.0;
  cMachineOverviewWarningDiskQueueLength = 4.0;
  cMachineOverviewWarningDiskQueueLatencyMs = 15.0;
  cMachineOverviewWarningDiskActivePercent = 95.0;
  cMachineOverviewBusyDiskActivePercent = 90.0;
  cMachineOverviewBusyDiskThroughputMBPerSecond = 100.0;
  cMachineOverviewLowDiskThroughputMBPerSecond = 10.0;
  cMachineOverviewLowDiskLatencyMs = 10.0;

function CalculateWindowStatistics(const aSeries: TMachineOverviewValueSeries;
  const aNowMonotonicMs, aWindowMs: UInt64;
  const aExpectedIntervalMs: Cardinal;
  const aMinimumCoveragePercent: Double): TMachineOverviewWindowStatistics;
  forward;

constructor TMachineOverviewValueSeries.Create;
begin
  inherited Create;
  fValues := TList<TMachineOverviewTimedValue>.Create;
end;

destructor TMachineOverviewValueSeries.Destroy;
begin
  fValues.Free;
  inherited Destroy;
end;

procedure TMachineOverviewValueSeries.Observe(const aMonotonicMs: UInt64;
  const aValue: TMachineOverviewOptionalDouble);
var
  lTimedValue: TMachineOverviewTimedValue;
begin
  if fHasObservation and (aMonotonicMs < fLastObservationMs) then
    raise EArgumentException.Create(
      'Machine Overview rolling samples must be monotonic');
  if not fHasObservation then
  begin
    fFirstObservationMs := aMonotonicMs;
    fHasObservation := True;
  end;
  fLastObservationMs := aMonotonicMs;

  if not aValue.Available then
    Exit;

  lTimedValue.MonotonicMs := aMonotonicMs;
  lTimedValue.Value := aValue.Value;
  fValues.Add(lTimedValue);
end;

constructor TMachineOverviewRollingState.Create(const aRetentionMs: UInt64);
begin
  inherited Create;
  OwnerThreadId := GetCurrentThreadId;
  RetentionMs := aRetentionMs;
  Series := TObjectDictionary<string,
    TMachineOverviewValueSeries>.Create([doOwnsValues]);
end;

destructor TMachineOverviewRollingState.Destroy;
begin
  Series.Free;
  inherited Destroy;
end;

function GetRollingState(const aState: TObject): TMachineOverviewRollingState;
begin
  Result := aState as TMachineOverviewRollingState;
end;

procedure EnsureRollingOwner(const aState: TMachineOverviewRollingState);
begin
  if GetCurrentThreadId <> aState.OwnerThreadId then
    raise EInvalidOperation.Create(
      'Machine Overview rolling state accessed by a non-owner thread');
end;

constructor TMachineOverviewRollingMeasurements.Create(
  const aRetentionMs: UInt64);
begin
  inherited Create;
  if aRetentionMs = 0 then
    raise EArgumentException.Create(
      'Machine Overview rolling retention must be greater than zero');
  fState := TMachineOverviewRollingState.Create(aRetentionMs);
end;

destructor TMachineOverviewRollingMeasurements.Destroy;
begin
  fState.Free;
  inherited Destroy;
end;

procedure TMachineOverviewRollingMeasurements.Observe(const aSeriesId: string;
  const aMonotonicMs: UInt64;
  const aValue: TMachineOverviewOptionalDouble);
var
  lSeries: TMachineOverviewValueSeries;
  lState: TMachineOverviewRollingState;
  lValue: TMachineOverviewOptionalDouble;
begin
  if aSeriesId.IsEmpty then
    raise EArgumentException.Create(
      'Machine Overview rolling series ID is required');
  lState := GetRollingState(fState);
  EnsureRollingOwner(lState);
  if not lState.Series.TryGetValue(aSeriesId, lSeries) then
  begin
    lSeries := TMachineOverviewValueSeries.Create;
    lState.Series.Add(aSeriesId, lSeries);
  end;
  lValue := aValue;
  if lValue.Available and
    (IsNan(lValue.Value) or IsInfinite(lValue.Value)) then
    lValue.Available := False;
  lSeries.Observe(aMonotonicMs, lValue);
end;

procedure TMachineOverviewRollingMeasurements.Prune(
  const aNowMonotonicMs: UInt64);
var
  lCutoffMs: UInt64;
  lKey: string;
  lRemoveKeys: TList<string>;
  lSeries: TMachineOverviewValueSeries;
  lState: TMachineOverviewRollingState;
begin
  lState := GetRollingState(fState);
  EnsureRollingOwner(lState);
  if aNowMonotonicMs > lState.RetentionMs then
    lCutoffMs := aNowMonotonicMs - lState.RetentionMs
  else
    lCutoffMs := 0;
  lRemoveKeys := TList<string>.Create;
  try
    for lKey in lState.Series.Keys do
    begin
      lSeries := lState.Series[lKey];
      lSeries.PruneBeforeOrAt(lCutoffMs);
      if lSeries.fHasObservation and
        (lSeries.fLastObservationMs <= lCutoffMs) then
        lRemoveKeys.Add(lKey);
    end;
    for lKey in lRemoveKeys do
      lState.Series.Remove(lKey);
  finally
    lRemoveKeys.Free;
  end;
end;

function TMachineOverviewRollingMeasurements.Statistics(
  const aSeriesId: string; const aNowMonotonicMs, aWindowMs: UInt64;
  const aExpectedIntervalMs: Cardinal;
  const aMinimumCoveragePercent: Double): TMachineOverviewWindowStatistics;
var
  lSeries: TMachineOverviewValueSeries;
  lState: TMachineOverviewRollingState;
begin
  Result := Default(TMachineOverviewWindowStatistics);
  lState := GetRollingState(fState);
  EnsureRollingOwner(lState);
  if not lState.Series.TryGetValue(aSeriesId, lSeries) then
    Exit;
  Result := CalculateWindowStatistics(lSeries, aNowMonotonicMs, aWindowMs,
    aExpectedIntervalMs, aMinimumCoveragePercent);
end;

function TMachineOverviewRollingMeasurements.TryMinimum(
  const aSeriesId: string; const aNowMonotonicMs, aWindowMs: UInt64;
  out aMinimum: Double): Boolean;
var
  lSeries: TMachineOverviewValueSeries;
  lStartMs: UInt64;
  lState: TMachineOverviewRollingState;
  lValue: TMachineOverviewTimedValue;
begin
  aMinimum := 0;
  Result := False;
  lState := GetRollingState(fState);
  EnsureRollingOwner(lState);
  if not lState.Series.TryGetValue(aSeriesId, lSeries) then
    Exit;
  if aNowMonotonicMs > aWindowMs then
    lStartMs := aNowMonotonicMs - aWindowMs
  else
    lStartMs := 0;
  for lValue in lSeries.fValues do
    if (lValue.MonotonicMs > lStartMs) and
      (lValue.MonotonicMs <= aNowMonotonicMs) then
      if (not Result) or (lValue.Value < aMinimum) then
      begin
        aMinimum := lValue.Value;
        Result := True;
      end;
end;

function TMachineOverviewRollingMeasurements.RetainedValueCount: Integer;
var
  lSeries: TMachineOverviewValueSeries;
  lState: TMachineOverviewRollingState;
begin
  Result := 0;
  lState := GetRollingState(fState);
  EnsureRollingOwner(lState);
  for lSeries in lState.Series.Values do
    Result := Result + lSeries.fValues.Count;
end;

procedure TMachineOverviewValueSeries.PruneBeforeOrAt(const aMonotonicMs: UInt64);
begin
  while (fValues.Count > 0) and (fValues[0].MonotonicMs <= aMonotonicMs) do
    fValues.Delete(0);
end;

constructor TMachineOverviewDomainState.Create(const aExpectedIntervalMs: Cardinal;
  const aMinimumCoveragePercent: Double);
begin
  inherited Create;
  ExpectedIntervalMs := aExpectedIntervalMs;
  MinimumCoveragePercent := aMinimumCoveragePercent;
  OwnerThreadId := GetCurrentThreadId;
  TotalCpuSeries := TMachineOverviewValueSeries.Create;
  LogicalProcessorSeries := TObjectList<TMachineOverviewValueSeries>.Create(True);
end;

destructor TMachineOverviewDomainState.Destroy;
begin
  LogicalProcessorSeries.Free;
  TotalCpuSeries.Free;
  inherited Destroy;
end;

function GetDomainState(const aState: TObject): TMachineOverviewDomainState;
begin
  Result := aState as TMachineOverviewDomainState;
end;

procedure EnsureDomainOwner(const aState: TMachineOverviewDomainState);
begin
  if GetCurrentThreadId <> aState.OwnerThreadId then
    raise EInvalidOperation.Create('Machine Overview domain state accessed by a non-owner thread');
end;

procedure EnsureLogicalProcessorSeries(const aState: TMachineOverviewDomainState;
  const aCount: Integer);
begin
  while aState.LogicalProcessorSeries.Count < aCount do
    aState.LogicalProcessorSeries.Add(TMachineOverviewValueSeries.Create);
end;

function ValidCpuPercentage(
  const aValue: TMachineOverviewOptionalDouble): TMachineOverviewOptionalDouble;
begin
  Result := aValue;
  if Result.Available and ((Result.Value < 0) or (Result.Value > 100) or
    IsNan(Result.Value) or IsInfinite(Result.Value)) then
    Result.Available := False;
end;

function MachineOverviewWindowStatusText(
  const aStatistics: TMachineOverviewWindowStatistics): string;
var
  lCoverageText: string;
begin
  if not aStatistics.Available then
    Exit('Unavailable');
  lCoverageText := FormatFloat('0.#', aStatistics.CoveragePercent,
    TFormatSettings.Invariant) + '%';
  if aStatistics.CoverageSufficient then
    Result := 'Available; coverage ' + lCoverageText
  else
    Result := 'Stale; coverage ' + lCoverageText;
end;

function CalculateWindowStatistics(const aSeries: TMachineOverviewValueSeries;
  const aNowMonotonicMs, aWindowMs: UInt64; const aExpectedIntervalMs: Cardinal;
  const aMinimumCoveragePercent: Double): TMachineOverviewWindowStatistics;
var
  lExpectedCount: UInt64;
  lFirstIncluded: Boolean;
  lMaximumExpectedCount: UInt64;
  lStartMs: UInt64;
  lSum: Double;
  lValue: TMachineOverviewTimedValue;
begin
  Result := Default(TMachineOverviewWindowStatistics);
  if (not aSeries.fHasObservation) or (aExpectedIntervalMs = 0) then
    Exit;

  if aNowMonotonicMs > aWindowMs then
    lStartMs := aNowMonotonicMs - aWindowMs
  else
    lStartMs := 0;

  lMaximumExpectedCount := aWindowMs div aExpectedIntervalMs;
  if lMaximumExpectedCount = 0 then
    lMaximumExpectedCount := 1;
  if aSeries.fFirstObservationMs > aNowMonotonicMs then
    lExpectedCount := 0
  else if aSeries.fFirstObservationMs <= lStartMs then
    lExpectedCount := lMaximumExpectedCount
  else
    lExpectedCount := ((aNowMonotonicMs - aSeries.fFirstObservationMs) div
      aExpectedIntervalMs) + 1;
  if lExpectedCount > lMaximumExpectedCount then
    lExpectedCount := lMaximumExpectedCount;
  Result.ExpectedSampleCount := lExpectedCount;

  lFirstIncluded := True;
  lSum := 0;
  for lValue in aSeries.fValues do
  begin
    if (lValue.MonotonicMs <= lStartMs) or (lValue.MonotonicMs > aNowMonotonicMs) then
      Continue;

    Inc(Result.ValidSampleCount);
    lSum := lSum + lValue.Value;
    if lFirstIncluded or (lValue.Value > Result.Peak) then
    begin
      Result.Peak := lValue.Value;
      lFirstIncluded := False;
    end;
  end;

  Result.Available := Result.ValidSampleCount > 0;
  if Result.Available then
    Result.Average := lSum / Result.ValidSampleCount;
  if Result.ExpectedSampleCount > 0 then
    Result.CoveragePercent := Result.ValidSampleCount * 100.0 /
      Result.ExpectedSampleCount;
  if Result.CoveragePercent > 100 then
    Result.CoveragePercent := 100;
  Result.CoverageSufficient := Result.Available and
    (Result.CoveragePercent >= aMinimumCoveragePercent);
end;

constructor TMachineOverviewCpuSample.Create(const aCapturedAtMonotonicMs: UInt64;
  const aCapturedAtUtc: TDateTime; const aTotalCpu: TMachineOverviewOptionalDouble;
  const aLogicalProcessors: TArray<TMachineOverviewOptionalDouble>);
begin
  inherited Create;
  fLogicalProcessors := Copy(aLogicalProcessors);
  fCapturedAtMonotonicMs := aCapturedAtMonotonicMs;
  fCapturedAtUtc := aCapturedAtUtc;
  fTotalCpu := aTotalCpu;
end;

function TMachineOverviewCpuSample.CapturedAtMonotonicMs: UInt64;
begin
  Result := fCapturedAtMonotonicMs;
end;

function TMachineOverviewCpuSample.CapturedAtUtc: TDateTime;
begin
  Result := fCapturedAtUtc;
end;

function TMachineOverviewCpuSample.LogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
begin
  Result := Copy(fLogicalProcessors);
end;

function TMachineOverviewCpuSample.TotalCpu: TMachineOverviewOptionalDouble;
begin
  Result := fTotalCpu;
end;

constructor TMachineOverviewDomainAggregator.Create(const aExpectedIntervalMs: Cardinal;
  const aMinimumCoveragePercent: Double);
begin
  inherited Create;
  if aExpectedIntervalMs = 0 then
    raise EArgumentException.Create('Machine Overview expected interval must be greater than zero');
  if (aMinimumCoveragePercent < 0) or (aMinimumCoveragePercent > 100) then
    raise EArgumentException.Create('Machine Overview minimum coverage must be between 0 and 100');

  fState := TMachineOverviewDomainState.Create(aExpectedIntervalMs,
    aMinimumCoveragePercent);
end;

destructor TMachineOverviewDomainAggregator.Destroy;
begin
  fState.Free;
  inherited Destroy;
end;

procedure TMachineOverviewDomainAggregator.AcceptCpuSample(
  const aSample: IMachineOverviewCpuSample);
var
  lCpuValue: TMachineOverviewOptionalDouble;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lMonotonicMs: UInt64;
  lState: TMachineOverviewDomainState;
  i: Integer;
begin
  if not Assigned(aSample) then
    Exit;

  lState := GetDomainState(fState);
  EnsureDomainOwner(lState);
  lMonotonicMs := aSample.CapturedAtMonotonicMs;
  if (lState.LastAcceptedMonotonicMs <> 0) and
    (lMonotonicMs < lState.LastAcceptedMonotonicMs) then
    raise EArgumentException.Create('Machine Overview CPU samples must be monotonic');

  lState.LastAcceptedMonotonicMs := lMonotonicMs;
  lCpuValue := ValidCpuPercentage(aSample.TotalCpu);
  lState.TotalCpuSeries.Observe(lMonotonicMs, lCpuValue);
  lLogicalProcessors := aSample.LogicalProcessors;
  lState.LatestLogicalProcessorCount := Length(lLogicalProcessors);
  EnsureLogicalProcessorSeries(lState, Length(lLogicalProcessors));
  for i := 0 to High(lLogicalProcessors) do
  begin
    lCpuValue := ValidCpuPercentage(lLogicalProcessors[i]);
    lState.LogicalProcessorSeries[i].Observe(lMonotonicMs, lCpuValue);
  end;
end;

function TMachineOverviewDomainAggregator.BuildCpuAggregate(
  const aNowMonotonicMs: UInt64): TMachineOverviewCpuAggregate;
var
  lHotStatistics: TMachineOverviewWindowStatistics;
  lPruneBeforeOrAtMs: UInt64;
  lState: TMachineOverviewDomainState;
  lValue: TMachineOverviewTimedValue;
  i: Integer;
begin
  Result := Default(TMachineOverviewCpuAggregate);
  lState := GetDomainState(fState);
  EnsureDomainOwner(lState);
  if aNowMonotonicMs > 60000 then
  begin
    lPruneBeforeOrAtMs := aNowMonotonicMs - 60000;
    lState.TotalCpuSeries.PruneBeforeOrAt(lPruneBeforeOrAtMs);
    for i := 0 to lState.LogicalProcessorSeries.Count - 1 do
      lState.LogicalProcessorSeries[i].PruneBeforeOrAt(lPruneBeforeOrAtMs);
  end;
  Result.LogicalProcessorCount := lState.LatestLogicalProcessorCount;
  Result.Window5Seconds := CalculateWindowStatistics(lState.TotalCpuSeries,
    aNowMonotonicMs, 5000, lState.ExpectedIntervalMs, lState.MinimumCoveragePercent);
  Result.Window15Seconds := CalculateWindowStatistics(lState.TotalCpuSeries,
    aNowMonotonicMs, 15000, lState.ExpectedIntervalMs, lState.MinimumCoveragePercent);
  Result.Window60Seconds := CalculateWindowStatistics(lState.TotalCpuSeries,
    aNowMonotonicMs, 60000, lState.ExpectedIntervalMs, lState.MinimumCoveragePercent);

  for i := lState.TotalCpuSeries.fValues.Count - 1 downto 0 do
  begin
    lValue := lState.TotalCpuSeries.fValues[i];
    if lValue.MonotonicMs <= aNowMonotonicMs then
    begin
      Result.NowValue.Available := True;
      Result.NowValue.Value := lValue.Value;
      Result.NowCapturedAtMonotonicMs := lValue.MonotonicMs;
      Break;
    end;
  end;

  for i := 0 to lState.LatestLogicalProcessorCount - 1 do
  begin
    lHotStatistics := CalculateWindowStatistics(lState.LogicalProcessorSeries[i],
      aNowMonotonicMs, 5000, lState.ExpectedIntervalMs, lState.MinimumCoveragePercent);
    if lHotStatistics.CoverageSufficient and (lHotStatistics.Average >= 80) then
      Inc(Result.HotLogicalProcessorCount);
  end;
end;

function TMachineOverviewDomainAggregator.RetainedCpuValueCount: Integer;
var
  lState: TMachineOverviewDomainState;
begin
  lState := GetDomainState(fState);
  EnsureDomainOwner(lState);
  Result := lState.TotalCpuSeries.fValues.Count;
end;

function CreateMachineOverviewCpuSample(const aCapturedAtMonotonicMs: UInt64;
  const aCapturedAtUtc: TDateTime; const aTotalCpu: TMachineOverviewOptionalDouble;
  const aLogicalProcessors: TArray<TMachineOverviewOptionalDouble>): IMachineOverviewCpuSample;
begin
  Result := TMachineOverviewCpuSample.Create(aCapturedAtMonotonicMs, aCapturedAtUtc,
    aTotalCpu, aLogicalProcessors);
end;

function MachineOverviewProviderStatusAt(const aState: TMachineOverviewProviderState;
  const aNowMonotonicMs, aStaleAfterMs: UInt64): TMachineOverviewProviderStatus;
begin
  Result := aState.Status;
  if (Result = TMachineOverviewProviderStatus.Available) and
    (aNowMonotonicMs > aState.CapturedAtMonotonicMs) and
    ((aNowMonotonicMs - aState.CapturedAtMonotonicMs) > aStaleAfterMs) then
    Result := TMachineOverviewProviderStatus.Stale;
end;

function MachineOverviewProcessIdentityKey(
  const aIdentity: TMachineOverviewProcessIdentity): string;
begin
  Result := UIntToStr(aIdentity.ProcessId) + ':' + UIntToStr(aIdentity.CreationTime100ns);
end;

function MachineOverviewDiskIdentityKey(
  const aIdentity: TMachineOverviewDiskIdentity): string;
begin
  Result := LowerCase(Trim(aIdentity.StableId));
end;

function ComparableDiskIdentityKey(
  const aIdentity: TMachineOverviewDiskIdentity): string;
begin
  Result := LowerCase(Trim(aIdentity.StableId));
end;

function TryNormalizeMachineOverviewProcessCpu(const aRawPercent: Double;
  const aLogicalProcessorCount: Integer; out aNormalizedPercent: Double): Boolean;
begin
  aNormalizedPercent := 0;
  Result := (aLogicalProcessorCount > 0) and (aRawPercent >= 0) and
    (not IsNan(aRawPercent)) and (not IsInfinite(aRawPercent));
  if not Result then
    Exit;

  aNormalizedPercent := aRawPercent / aLogicalProcessorCount;
  if aNormalizedPercent > 100 then
    aNormalizedPercent := 100;
end;

function CompareMachineOverviewProcessIdentities(
  const aLeft, aRight: TMachineOverviewProcessIdentity): Integer;
begin
  if aLeft.ProcessId < aRight.ProcessId then
    Exit(-1);
  if aLeft.ProcessId > aRight.ProcessId then
    Exit(1);
  if aLeft.CreationTime100ns < aRight.CreationTime100ns then
    Exit(-1);
  if aLeft.CreationTime100ns > aRight.CreationTime100ns then
    Exit(1);
  Result := 0;
end;

procedure AddMachineOverviewProcessIdentity(
  var aIdentities: TArray<TMachineOverviewProcessIdentity>;
  const aIdentity: TMachineOverviewProcessIdentity);
var
  lIndex: Integer;
begin
  lIndex := Length(aIdentities);
  SetLength(aIdentities, lIndex + 1);
  aIdentities[lIndex] := aIdentity;
end;

function RankMachineOverviewProcesses(const aMetrics: TArray<TMachineOverviewProcessMetric>;
  const aMaximumCount: Integer): TArray<TMachineOverviewRankedProcess>;
var
  lCount: Integer;
  lGroupIndex: Integer;
  lGroupIndexes: TDictionary<string, Integer>;
  lGroupKey: string;
  lGroupedMetric: TMachineOverviewProcessMetric;
  lIdentityComparer: IComparer<TMachineOverviewProcessIdentity>;
  lMetric: TMachineOverviewProcessMetric;
  lMetricValid: Boolean;
  lSorted: TList<TMachineOverviewProcessMetric>;
  i: Integer;
begin
  Result := nil;
  if aMaximumCount <= 0 then
    Exit;

  lSorted := TList<TMachineOverviewProcessMetric>.Create;
  lGroupIndexes := TDictionary<string, Integer>.Create;
  try
    for lMetric in aMetrics do
    begin
      lMetricValid := lMetric.MetricAvailable and (lMetric.MetricValue >= 0) and
        (not IsNan(lMetric.MetricValue)) and
        (not IsInfinite(lMetric.MetricValue));
      lGroupKey := LowerCase(Trim(lMetric.DisplayName));
      if lGroupKey.IsEmpty then
        lGroupKey := 'process:' +
          MachineOverviewProcessIdentityKey(lMetric.Identity)
      else
        lGroupKey := 'application:' + lGroupKey;
      if lGroupIndexes.TryGetValue(lGroupKey, lGroupIndex) then
      begin
        lGroupedMetric := lSorted[lGroupIndex];
        AddMachineOverviewProcessIdentity(lGroupedMetric.Identities,
          lMetric.Identity);
        if lMetricValid then
        begin
          if lGroupedMetric.MetricAvailable then
            lGroupedMetric.MetricValue := lGroupedMetric.MetricValue +
              lMetric.MetricValue
          else
            lGroupedMetric.MetricValue := lMetric.MetricValue;
          lGroupedMetric.MetricAvailable := True;
        end;
        lSorted[lGroupIndex] := lGroupedMetric;
      end else
      begin
        lGroupedMetric := lMetric;
        SetLength(lGroupedMetric.Identities, 1);
        lGroupedMetric.Identities[0] := lMetric.Identity;
        if not lMetricValid then
        begin
          lGroupedMetric.MetricAvailable := False;
          lGroupedMetric.MetricValue := 0;
        end;
        lGroupIndexes.Add(lGroupKey, lSorted.Count);
        lSorted.Add(lGroupedMetric);
      end;
    end;
    for i := lSorted.Count - 1 downto 0 do
      if not lSorted[i].MetricAvailable then
        lSorted.Delete(i);
    lIdentityComparer := TComparer<TMachineOverviewProcessIdentity>.Construct(
      function(const aLeft, aRight: TMachineOverviewProcessIdentity): Integer
      begin
        Result := CompareMachineOverviewProcessIdentities(aLeft, aRight);
      end);
    for i := 0 to lSorted.Count - 1 do
    begin
      lMetric := lSorted[i];
      TArray.Sort<TMachineOverviewProcessIdentity>(lMetric.Identities,
        lIdentityComparer);
      lMetric.Identity := lMetric.Identities[0];
      lSorted[i] := lMetric;
    end;
    lSorted.Sort(TComparer<TMachineOverviewProcessMetric>.Construct(
      function(const aLeft, aRight: TMachineOverviewProcessMetric): Integer
      begin
        if aLeft.MetricValue > aRight.MetricValue then
          Exit(-1);
        if aLeft.MetricValue < aRight.MetricValue then
          Exit(1);
        if aLeft.Identity.ProcessId < aRight.Identity.ProcessId then
          Exit(-1);
        if aLeft.Identity.ProcessId > aRight.Identity.ProcessId then
          Exit(1);
        if aLeft.Identity.CreationTime100ns < aRight.Identity.CreationTime100ns then
          Exit(-1);
        if aLeft.Identity.CreationTime100ns > aRight.Identity.CreationTime100ns then
          Exit(1);
        Result := CompareStr(aLeft.DisplayName, aRight.DisplayName);
      end));

    lCount := lSorted.Count;
    if lCount > aMaximumCount then
      lCount := aMaximumCount;
    SetLength(Result, lCount);
    for i := 0 to lCount - 1 do
    begin
      Result[i].Rank := i + 1;
      Result[i].Metric := lSorted[i];
    end;
  finally
    lGroupIndexes.Free;
    lSorted.Free;
  end;
end;

function TrySelectWorstMachineOverviewDisk(const aMetrics: TArray<TMachineOverviewDiskMetric>;
  out aSelection: TMachineOverviewDiskSelection): Boolean;
var
  lCandidate: TMachineOverviewDiskSelection;
  lCandidateKey: string;
  lCurrentKey: string;
  lMetric: TMachineOverviewDiskMetric;
  lThroughput: Double;
begin
  aSelection := Default(TMachineOverviewDiskSelection);
  Result := False;
  for lMetric in aMetrics do
  begin
    if (not lMetric.Available) or IsNan(lMetric.SustainedActivePercent) or
      IsInfinite(lMetric.SustainedActivePercent) or IsNan(lMetric.ReadMBPerSecond) or
      IsInfinite(lMetric.ReadMBPerSecond) or IsNan(lMetric.WriteMBPerSecond) or
      IsInfinite(lMetric.WriteMBPerSecond) or IsNan(lMetric.SustainedLatencyMs) or
      IsInfinite(lMetric.SustainedLatencyMs) or IsNan(lMetric.SustainedQueueLength) or
      IsInfinite(lMetric.SustainedQueueLength) or (lMetric.SustainedActivePercent < 0) or
      (lMetric.ReadMBPerSecond < 0) or (lMetric.WriteMBPerSecond < 0) or
      (lMetric.SustainedLatencyMs < 0) or (lMetric.SustainedQueueLength < 0) then
      Continue;

    lCandidate := Default(TMachineOverviewDiskSelection);
    lCandidate.Metric := lMetric;
    lCandidate.Severity := TMachineOverviewSeverity.Normal;
    lCandidate.Reason := TMachineOverviewDiskReason.None;
    lThroughput := lMetric.ReadMBPerSecond + lMetric.WriteMBPerSecond;
    if lMetric.SustainedLatencyMs >= cMachineOverviewCriticalDiskLatencyMs then
    begin
      lCandidate.Severity := TMachineOverviewSeverity.Critical;
      lCandidate.Reason := TMachineOverviewDiskReason.Latency;
    end else if lMetric.SustainedLatencyMs >= cMachineOverviewWarningDiskLatencyMs then
    begin
      lCandidate.Severity := TMachineOverviewSeverity.Warning;
      lCandidate.Reason := TMachineOverviewDiskReason.Latency;
    end else if (lMetric.SustainedQueueLength >= cMachineOverviewWarningDiskQueueLength) and
      (lMetric.SustainedLatencyMs >= cMachineOverviewWarningDiskQueueLatencyMs) then
    begin
      lCandidate.Severity := TMachineOverviewSeverity.Warning;
      lCandidate.Reason := TMachineOverviewDiskReason.QueueLength;
    end else if (lMetric.SustainedActivePercent >= cMachineOverviewWarningDiskActivePercent) and
      (lThroughput < cMachineOverviewLowDiskThroughputMBPerSecond) and
      (lMetric.SustainedLatencyMs >= cMachineOverviewWarningDiskQueueLatencyMs) then
    begin
      lCandidate.Severity := TMachineOverviewSeverity.Warning;
      lCandidate.Reason := TMachineOverviewDiskReason.ActiveTime;
    end else if (lMetric.SustainedActivePercent >= cMachineOverviewBusyDiskActivePercent) and
      (lThroughput >= cMachineOverviewBusyDiskThroughputMBPerSecond) and
      (lMetric.SustainedLatencyMs < cMachineOverviewLowDiskLatencyMs) then
    begin
      lCandidate.Severity := TMachineOverviewSeverity.Notice;
      lCandidate.Reason := TMachineOverviewDiskReason.ThroughputContext;
    end;

    if not Result then
    begin
      aSelection := lCandidate;
      Result := True;
      Continue;
    end;

    if Ord(lCandidate.Severity) > Ord(aSelection.Severity) then
      aSelection := lCandidate
    else if lCandidate.Severity = aSelection.Severity then
    begin
      if lCandidate.Metric.SustainedLatencyMs > aSelection.Metric.SustainedLatencyMs then
        aSelection := lCandidate
      else if lCandidate.Metric.SustainedLatencyMs = aSelection.Metric.SustainedLatencyMs then
      begin
        if lCandidate.Metric.SustainedQueueLength > aSelection.Metric.SustainedQueueLength then
          aSelection := lCandidate
        else if lCandidate.Metric.SustainedQueueLength = aSelection.Metric.SustainedQueueLength then
        begin
          lCandidateKey := ComparableDiskIdentityKey(lCandidate.Metric.Identity);
          lCurrentKey := ComparableDiskIdentityKey(aSelection.Metric.Identity);
          if CompareStr(lCandidateKey, lCurrentKey) < 0 then
            aSelection := lCandidate;
        end;
      end;
    end;
  end;
end;

end.

unit ActiveAppView.MachineOverview.Presentation;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewIncidentPresentation = record
    OccurredAtLocal: TDateTime;
    Summary: string;
    DiagnosticText: string;
    Severity: TMachineOverviewSeverity;
  end;

  TMachineOverviewNamedDiagnostic = record
    Name: string;
    ValueText: string;
  end;

  TMachineOverviewPresentationSource = record
    CapturedAtUtc: TDateTime;
    CapturedAtMonotonicMs: UInt64;
    Sequence: UInt64;
    OverallSeverity: TMachineOverviewSeverity;
    OverallReason: string;
    IncidentCountLast24Hours: Integer;
    Incidents: TArray<TMachineOverviewIncidentPresentation>;
    CpuAggregate: TMachineOverviewCpuAggregate;
    LogicalProcessorValues: TArray<TMachineOverviewOptionalDouble>;
    Measurements: TArray<TMachineOverviewMeasurement>;
    ProviderStates: TArray<TMachineOverviewProviderState>;
    RawQueueDepth: Integer;
    RawSamplesDropped: Int64;
    HistoryQueueDepth: Integer;
    HistoryRecordsDropped: Int64;
    LastSQLiteCommitAvailable: Boolean;
    LastSQLiteCommitDurationMs: UInt64;
    LastSQLiteError: string;
    SelfMetricsAvailable: Boolean;
    MonitorCpuPercent: Double;
    MonitorPrivateBytes: UInt64;
    MonitorWriteBytesPerSecond: Double;
    AdditionalDiagnostics: TArray<TMachineOverviewNamedDiagnostic>;
  end;

function BuildMachineOverviewPresentation(
  const aSource: TMachineOverviewPresentationSource): TMachineOverviewPresentation;
function MachineOverviewSelectedRowCopy(
  const aRow: TMachineOverviewRow): string;
function TryFindMachineOverviewRow(
  const aPresentation: TMachineOverviewPresentation; const aRowId: string;
  out aRow: TMachineOverviewRow): Boolean;

implementation

uses
  System.StrUtils, System.SysUtils;

function InvariantFormat(const aFormat: string; const aValue: Double): string;
begin
  Result := FormatFloat(aFormat, aValue, TFormatSettings.Invariant);
end;

function SeverityText(const aSeverity: TMachineOverviewSeverity): string;
begin
  case aSeverity of
    TMachineOverviewSeverity.Normal:
      Result := 'Normal';
    TMachineOverviewSeverity.Notice:
      Result := 'Notice';
    TMachineOverviewSeverity.Warning:
      Result := 'Warning';
    TMachineOverviewSeverity.Critical:
      Result := 'Critical';
  else
    Result := 'Unavailable';
  end;
end;

function ProviderStatusText(const aStatus: TMachineOverviewProviderStatus): string;
begin
  case aStatus of
    TMachineOverviewProviderStatus.Available:
      Result := 'Available';
    TMachineOverviewProviderStatus.Stale:
      Result := 'Stale';
    TMachineOverviewProviderStatus.Unavailable:
      Result := 'Unavailable';
  else
    Result := 'Failed';
  end;
end;

function SeverityFromText(const aValue: string): TMachineOverviewSeverity;
begin
  if SameText(aValue, 'Critical') then
    Exit(TMachineOverviewSeverity.Critical);
  if SameText(aValue, 'Warning') then
    Exit(TMachineOverviewSeverity.Warning);
  if SameText(aValue, 'Notice') then
    Exit(TMachineOverviewSeverity.Notice);
  if SameText(aValue, 'Unavailable') then
    Exit(TMachineOverviewSeverity.Unavailable);
  Result := TMachineOverviewSeverity.Normal;
end;

function FormatPercent(const aValue: Double): string;
begin
  Result := InvariantFormat('0.#', aValue) + '%';
end;

function FormatCount(const aValue: Double): string;
begin
  Result := InvariantFormat('#,##0', aValue);
end;

function FormatBytes(const aValue: Double): string;
const
  cKilobyte = 1024.0;
  cMegabyte = 1024.0 * 1024.0;
  cGigabyte = 1024.0 * 1024.0 * 1024.0;
begin
  if aValue >= cGigabyte then
    Result := InvariantFormat('0.#', aValue / cGigabyte) + ' GB'
  else if aValue >= cMegabyte then
    Result := InvariantFormat('0.#', aValue / cMegabyte) + ' MB'
  else if aValue >= cKilobyte then
    Result := InvariantFormat('0.#', aValue / cKilobyte) + ' KB'
  else
    Result := InvariantFormat('0', aValue) + ' bytes';
end;

function FormatBytesPerSecond(const aValue: Double): string;
begin
  Result := FormatBytes(aValue) + '/s';
end;

function FormatMegabytesPerSecond(const aValue: Double): string;
begin
  Result := InvariantFormat('0.#', aValue) + ' MB/s';
end;

function FormatMilliseconds(const aValue: Double): string;
begin
  if aValue >= 1000 then
    Result := InvariantFormat('0.#', aValue / 1000) + ' s'
  else
    Result := InvariantFormat('0.#', aValue) + ' ms';
end;

function FormatAge(const aAgeMs: UInt64): string;
begin
  Result := FormatMilliseconds(aAgeMs);
end;

function MeasurementFreshnessSuffix(
  const aMeasurement: TMachineOverviewMeasurement): string;
begin
  if StartsText('Stale', aMeasurement.StatusText) then
    Result := ' (' + aMeasurement.StatusText + ')'
  else
    Result := '';
end;

function TryFindMeasurement(
  const aMeasurements: TArray<TMachineOverviewMeasurement>;
  const aName: string; out aMeasurement: TMachineOverviewMeasurement): Boolean;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  for lMeasurement in aMeasurements do
    if SameText(lMeasurement.Name, aName) then
    begin
      aMeasurement := lMeasurement;
      Exit(True);
    end;
  aMeasurement := Default(TMachineOverviewMeasurement);
  Result := False;
end;

function TryFindProviderState(
  const aStates: TArray<TMachineOverviewProviderState>;
  const aProviderId: string; out aState: TMachineOverviewProviderState): Boolean;
var
  lState: TMachineOverviewProviderState;
begin
  for lState in aStates do
    if SameText(lState.ProviderId, aProviderId) then
    begin
      aState := lState;
      Exit(True);
    end;
  aState := Default(TMachineOverviewProviderState);
  Result := False;
end;

function MeasurementPercent(
  const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available then
    Result := FormatPercent(lMeasurement.Value) +
      MeasurementFreshnessSuffix(lMeasurement)
  else
    Result := 'Unavailable';
end;

function MeasurementCount(
  const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available then
    Result := FormatCount(lMeasurement.Value)
  else
    Result := 'Unavailable';
end;

function MeasurementBytes(
  const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available then
    Result := FormatBytes(lMeasurement.Value) +
      MeasurementFreshnessSuffix(lMeasurement)
  else
    Result := 'Unavailable';
end;

function MeasurementBytesPerSecond(
  const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available then
    Result := FormatBytesPerSecond(lMeasurement.Value) +
      MeasurementFreshnessSuffix(lMeasurement)
  else
    Result := 'Unavailable';
end;

function MeasurementMilliseconds(
  const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available then
    Result := FormatMilliseconds(lMeasurement.Value) +
      MeasurementFreshnessSuffix(lMeasurement)
  else
    Result := 'Unavailable';
end;

function WindowText(const aWindowName: string;
  const aWindow: TMachineOverviewWindowStatistics): string;
begin
  if aWindow.Available then
  begin
    Result := Format('%s average %s; peak %s', [aWindowName,
      FormatPercent(aWindow.Average), FormatPercent(aWindow.Peak)]);
    if (aWindow.ExpectedSampleCount > 0) and
      (not aWindow.CoverageSufficient) then
      Result := Result + '; Stale; coverage ' +
        InvariantFormat('0.#', aWindow.CoveragePercent) + '%';
  end else
    Result := aWindowName + ' average and peak Unavailable';
end;

procedure AddRow(var aPresentation: TMachineOverviewPresentation;
  const aRowId: string; const aCategory: string; const aLabelText: string;
  const aValueText: string; const aSeverity: TMachineOverviewSeverity;
  const aAction: TMachineOverviewAction);
var
  lIndex: Integer;
begin
  lIndex := Length(aPresentation.Rows);
  SetLength(aPresentation.Rows, lIndex + 1);
  aPresentation.Rows[lIndex].RowId := aRowId;
  aPresentation.Rows[lIndex].Category := aCategory;
  aPresentation.Rows[lIndex].LabelText := aLabelText;
  aPresentation.Rows[lIndex].ValueText := aValueText;
  aPresentation.Rows[lIndex].Severity := aSeverity;
  aPresentation.Rows[lIndex].Action := aAction;
end;

function BuildOverallText(
  const aSource: TMachineOverviewPresentationSource): string;
begin
  if aSource.OverallReason.IsEmpty then
    Result := 'Unavailable; current bottleneck has not been determined'
  else
    Result := SeverityText(aSource.OverallSeverity) + '; ' +
      aSource.OverallReason;
end;

function BuildIncidentText(
  const aSource: TMachineOverviewPresentationSource): string;
var
  lCount: Integer;
  lIndex: Integer;
begin
  Result := Format('%d', [aSource.IncidentCountLast24Hours]);
  lCount := Length(aSource.Incidents);
  if lCount > 3 then
    lCount := 3;
  if lCount > 0 then
  begin
    Result := Result + '. Latest: ';
    for lIndex := 0 to lCount - 1 do
    begin
      if lIndex > 0 then
        Result := Result + '; ';
      Result := Result + FormatDateTime('hh:nn',
        aSource.Incidents[lIndex].OccurredAtLocal) + ' ' +
        aSource.Incidents[lIndex].Summary;
    end;
  end;
end;

function BuildCpuText(
  const aSource: TMachineOverviewPresentationSource): string;
var
  lTemperature: TMachineOverviewMeasurement;
begin
  if not aSource.CpuAggregate.NowValue.Available then
    Exit('Unavailable; CPU provider has no current sample');
  Result := Format('%s now; %d of %d logical processors hot; %s; %s; %s',
    [FormatPercent(aSource.CpuAggregate.NowValue.Value),
     aSource.CpuAggregate.HotLogicalProcessorCount,
     aSource.CpuAggregate.LogicalProcessorCount,
     WindowText('5 s', aSource.CpuAggregate.Window5Seconds),
     WindowText('15 s', aSource.CpuAggregate.Window15Seconds),
     WindowText('60 s', aSource.CpuAggregate.Window60Seconds)]);
  if TryFindMeasurement(aSource.Measurements, 'cpu_package_temperature_c',
    lTemperature) and lTemperature.Available then
  begin
    Result := Result + '; package temperature ' +
      InvariantFormat('0.#', lTemperature.Value) + ' C';
    if not lTemperature.StatusText.IsEmpty then
      Result := Result + ' (' + lTemperature.StatusText + ')';
  end else
    Result := Result + '; package temperature Unavailable';
end;

function TopProcessName(const aSource: TMachineOverviewPresentationSource;
  const aName: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
    lMeasurement.Available and (not lMeasurement.DisplayText.IsEmpty) then
    Result := lMeasurement.DisplayText
  else
    Result := 'Unavailable';
end;

function BuildMemoryText(
  const aSource: TMachineOverviewPresentationSource): string;
var
  lAvailable: TMachineOverviewMeasurement;
  lTotal: TMachineOverviewMeasurement;
begin
  if not (TryFindMeasurement(aSource.Measurements, 'physical_total_bytes',
      lTotal) and lTotal.Available and
    TryFindMeasurement(aSource.Measurements, 'physical_available_bytes',
      lAvailable) and lAvailable.Available) then
    Exit('Unavailable; memory provider has no current sample');
  Result := Format('%s physical used; %s used; %s commit; paging %s now; '+
    '60 s peak %s; 15 minute lowest available %s; top memory process %s',
    [FormatBytes(lTotal.Value - lAvailable.Value),
     MeasurementPercent(aSource, 'physical_used_percent'),
     MeasurementPercent(aSource, 'commit_percent'),
     MeasurementBytesPerSecond(aSource, 'paging_bytes_per_sec'),
     MeasurementBytesPerSecond(aSource, 'paging_bytes_per_sec_peak_60s'),
     MeasurementBytes(aSource, 'physical_available_bytes_low_15m'),
     TopProcessName(aSource, 'process_ram_rank:1')]);
end;

function BuildGpuText(
  const aSource: TMachineOverviewPresentationSource): string;
var
  lMeasurement: TMachineOverviewMeasurement;
  lState: TMachineOverviewProviderState;
begin
  if not (TryFindMeasurement(aSource.Measurements, 'gpu_overall_percent',
      lMeasurement) and lMeasurement.Available) then
    Exit('Unavailable; GPU provider has no current sample');
  Result := Format('%s now; busiest engine %s; 5 s average %s; peak %s; '+
    '15 s average %s; peak %s; 60 s average %s; peak %s; dedicated memory %s',
    [FormatPercent(lMeasurement.Value), lMeasurement.DisplayText,
     MeasurementPercent(aSource, 'gpu_average_5s'),
     MeasurementPercent(aSource, 'gpu_peak_5s'),
     MeasurementPercent(aSource, 'gpu_average_15s'),
     MeasurementPercent(aSource, 'gpu_peak_15s'),
     MeasurementPercent(aSource, 'gpu_average_60s'),
     MeasurementPercent(aSource, 'gpu_peak_60s'),
     MeasurementBytes(aSource, 'gpu_dedicated_bytes')]);
  if TryFindMeasurement(aSource.Measurements, 'gpu_temperature_c',
    lMeasurement) and lMeasurement.Available then
  begin
    Result := Result + '; temperature ' + InvariantFormat('0.#',
      lMeasurement.Value) + ' C';
    if not lMeasurement.StatusText.IsEmpty then
      Result := Result + ' (' + lMeasurement.StatusText + ')';
  end else
    Result := Result + '; temperature Unavailable';
  if TryFindMeasurement(aSource.Measurements, 'gpu_power_w',
    lMeasurement) and lMeasurement.Available then
    Result := Result + '; power ' + InvariantFormat('0.#',
      lMeasurement.Value) + ' W';
  if TryFindProviderState(aSource.ProviderStates, 'gpu', lState) then
    Result := Result + '; provider ' + LowerCase(ProviderStatusText(
      lState.Status)) + '; age ' + FormatAge(lState.DataAgeMs)
  else
    Result := Result + '; provider status Unavailable';
  if TryFindProviderState(aSource.ProviderStates, 'temperature', lState) then
    Result := Result + '; optional temperature provider ' +
      LowerCase(ProviderStatusText(lState.Status)) + '; age ' +
      FormatAge(lState.DataAgeMs);
end;

function BuildResponsivenessText(
  const aSource: TMachineOverviewPresentationSource): string;
begin
  Result := Format('foreground reply %s now; 60 s max %s; DPC %s now; '+
    '60 s max %s; interrupts %s; DWM missed frames %s; processor queue %s',
    [MeasurementMilliseconds(aSource, 'foreground_reply_ms'),
     MeasurementMilliseconds(aSource, 'foreground_reply_max_60s'),
     MeasurementPercent(aSource, 'dpc_percent'),
     MeasurementPercent(aSource, 'dpc_percent_max_60s'),
     MeasurementPercent(aSource, 'interrupt_percent'),
     MeasurementCount(aSource, 'dwm_frames_missed_delta'),
     MeasurementCount(aSource, 'processor_queue_length')]);
end;

function BuildSystemCountsText(
  const aSource: TMachineOverviewPresentationSource): string;
begin
  Result := Format('%s processes; %s threads; %s handles',
    [MeasurementCount(aSource, 'process_count'),
     MeasurementCount(aSource, 'thread_count'),
     MeasurementCount(aSource, 'handle_count')]);
end;

function BuildDiskSummaryText(
  const aSource: TMachineOverviewPresentationSource;
  out aSeverity: TMachineOverviewSeverity): string;
var
  lOrdinal: Integer;
  lMeasurement: TMachineOverviewMeasurement;
  lReason: TMachineOverviewDiskReason;
  lReasonText: string;
begin
  if not (TryFindMeasurement(aSource.Measurements, 'disk_worst', lMeasurement)
      and lMeasurement.Available) then
  begin
    aSeverity := TMachineOverviewSeverity.Unavailable;
    Exit('Unavailable; disk condition has not been determined');
  end;
  if SameText(lMeasurement.UnitText, 'severity') and
    (lMeasurement.Value >= Ord(Low(TMachineOverviewSeverity))) and
    (lMeasurement.Value <= Ord(High(TMachineOverviewSeverity))) then
    aSeverity := TMachineOverviewSeverity(Trunc(lMeasurement.Value))
  else
    aSeverity := SeverityFromText(lMeasurement.StatusText);
  lReasonText := lMeasurement.DetailText;
  if lReasonText.IsEmpty and TryStrToInt(lMeasurement.StatusText, lOrdinal) and
    (lOrdinal >= Ord(Low(TMachineOverviewDiskReason))) and
    (lOrdinal <= Ord(High(TMachineOverviewDiskReason))) then
  begin
    lReason := TMachineOverviewDiskReason(lOrdinal);
    case lReason of
      TMachineOverviewDiskReason.ThroughputContext:
        lReasonText := 'throughput context';
      TMachineOverviewDiskReason.ActiveTime:
        lReasonText := 'active time';
      TMachineOverviewDiskReason.Latency:
        lReasonText := 'latency';
      TMachineOverviewDiskReason.QueueLength:
        lReasonText := 'queue length';
    else
      lReasonText := 'current disk condition';
    end;
  end;
  if lReasonText.IsEmpty then
    lReasonText := 'current disk condition';
  Result := lMeasurement.DisplayText + '; selected by ' + lReasonText;
  if SameText(lMeasurement.UnitText, 'milliseconds') then
    Result := Result + '; ' + FormatMilliseconds(lMeasurement.Value)
  else if (not lMeasurement.UnitText.IsEmpty) and
    (not SameText(lMeasurement.UnitText, 'severity')) then
    Result := Result + '; ' + InvariantFormat('0.#', lMeasurement.Value) +
      ' ' + lMeasurement.UnitText;
end;

procedure AddUniqueDiskId(var aDiskIds: TArray<string>; const aDiskId: string);
var
  lDiskId: string;
  lIndex: Integer;
begin
  if aDiskId.IsEmpty or (not StartsText('physical:', aDiskId)) then
    Exit;
  for lDiskId in aDiskIds do
    if SameText(lDiskId, aDiskId) then
      Exit;
  lIndex := Length(aDiskIds);
  SetLength(aDiskIds, lIndex + 1);
  aDiskIds[lIndex] := aDiskId;
end;

procedure SortDiskIds(var aDiskIds: TArray<string>);
var
  i: Integer;
  j: Integer;
  s: string;
begin
  for i := 1 to High(aDiskIds) do
  begin
    s := aDiskIds[i];
    j := i - 1;
    while (j >= 0) and (CompareText(aDiskIds[j], s) > 0) do
    begin
      aDiskIds[j + 1] := aDiskIds[j];
      Dec(j);
    end;
    aDiskIds[j + 1] := s;
  end;
end;

function DiskDisplayName(const aSource: TMachineOverviewPresentationSource;
  const aDiskId: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  for lMeasurement in aSource.Measurements do
    if SameText(lMeasurement.EntityId, aDiskId) and
      (not lMeasurement.DisplayText.IsEmpty) then
      Exit(lMeasurement.DisplayText);
  Result := aDiskId;
end;

function DiskMetric(const aSource: TMachineOverviewPresentationSource;
  const aPrefix: string; const aDiskId: string; const aKind: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if not (TryFindMeasurement(aSource.Measurements, aPrefix + ':' + aDiskId,
      lMeasurement) and lMeasurement.Available) then
    Exit('Unavailable');
  if aKind = 'percent' then
    Result := FormatPercent(lMeasurement.Value)
  else if aKind = 'mbps' then
    Result := FormatMegabytesPerSecond(lMeasurement.Value)
  else if aKind = 'ms' then
    Result := FormatMilliseconds(lMeasurement.Value)
  else
    Result := InvariantFormat('0.#', lMeasurement.Value);
end;

function BuildDiskVolumesText(
  const aSource: TMachineOverviewPresentationSource;
  const aDiskId: string): string;
var
  lFree: TMachineOverviewMeasurement;
  lFreeName: string;
  lMeasurement: TMachineOverviewMeasurement;
  lUsedPercent: Double;
begin
  Result := '';
  for lMeasurement in aSource.Measurements do
    if SameText(lMeasurement.EntityId, aDiskId) and
      StartsText('disk_volume_total_bytes:', lMeasurement.Name) then
    begin
      lFreeName := StringReplace(lMeasurement.Name,
        'disk_volume_total_bytes:', 'disk_volume_free_bytes:', []);
      if lMeasurement.Available and (lMeasurement.Value > 0) and
        TryFindMeasurement(aSource.Measurements, lFreeName, lFree) and
        lFree.Available then
      begin
        lUsedPercent := 100 * (lMeasurement.Value - lFree.Value) /
          lMeasurement.Value;
        Result := Result + '; volume ' + lMeasurement.DisplayText + ' ' +
          FormatPercent(lUsedPercent) + ' used';
      end else
        Result := Result + '; volume ' + lMeasurement.DisplayText +
          ' fullness Unavailable';
    end;
  if Result.IsEmpty then
    Result := '; mapped volume fullness Unavailable';
end;

function BuildDiskText(const aSource: TMachineOverviewPresentationSource;
  const aDiskId: string): string;
begin
  Result := Format('%s; active %s; read %s; write %s; latency %s now; '+
    '60 s max %s; queue %s%s', [DiskDisplayName(aSource, aDiskId),
     DiskMetric(aSource, 'disk_active_percent', aDiskId, 'percent'),
     DiskMetric(aSource, 'disk_read_mb_per_sec', aDiskId, 'mbps'),
     DiskMetric(aSource, 'disk_write_mb_per_sec', aDiskId, 'mbps'),
     DiskMetric(aSource, 'disk_latency_ms', aDiskId, 'ms'),
     DiskMetric(aSource, 'disk_latency_max_60s', aDiskId, 'ms'),
     DiskMetric(aSource, 'disk_queue_length', aDiskId, 'count'),
     BuildDiskVolumesText(aSource, aDiskId)]);
end;

function ProcessIdText(const aIdentity: string): string;
var
  lSeparator: Integer;
begin
  lSeparator := Pos(':', aIdentity);
  if lSeparator > 1 then
    Result := Copy(aIdentity, 1, lSeparator - 1)
  else
    Result := aIdentity;
  if Result.IsEmpty then
    Result := 'Unavailable';
end;

function RankedMetricText(const aSource: TMachineOverviewPresentationSource;
  const aName: string; const aKind: string): string;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  if not (TryFindMeasurement(aSource.Measurements, aName, lMeasurement) and
      lMeasurement.Available) then
    Exit('Unavailable');
  if aKind = 'percent' then
    Result := FormatPercent(lMeasurement.Value)
  else if aKind = 'bytes' then
    Result := FormatBytes(lMeasurement.Value)
  else if aKind = 'bytes_per_second' then
    Result := FormatBytesPerSecond(lMeasurement.Value)
  else
    Result := FormatMegabytesPerSecond(lMeasurement.Value);
  Result := Result + MeasurementFreshnessSuffix(lMeasurement);
end;

function BuildRankedProcessText(
  const aSource: TMachineOverviewPresentationSource;
  const aMetricPrefix: string; const aAveragePrefix: string;
  const aPeakPrefix: string; const aKind: string; const aRank: Integer): string;
var
  lMeasurement: TMachineOverviewMeasurement;
  lName: string;
  lRankText: string;
begin
  lRankText := IntToStr(aRank);
  lName := aMetricPrefix + ':' + lRankText;
  if not (TryFindMeasurement(aSource.Measurements, lName, lMeasurement) and
      lMeasurement.Available) then
    Exit('Unavailable; no ranked process');
  if aKind = 'bytes' then
    Result := Format('%s; %s private working set; %s recent peak; PID %s',
      [lMeasurement.DisplayText, FormatBytes(lMeasurement.Value),
       RankedMetricText(aSource, aPeakPrefix + ':' + lRankText, aKind),
       ProcessIdText(lMeasurement.EntityId)])
  else
    Result := Format('%s; %s now; %s average over 15 seconds; '+
      '%s peak over 60 seconds; PID %s', [lMeasurement.DisplayText,
       RankedMetricText(aSource, lName, aKind),
       RankedMetricText(aSource, aAveragePrefix + ':' + lRankText, aKind),
       RankedMetricText(aSource, aPeakPrefix + ':' + lRankText, aKind),
       ProcessIdText(lMeasurement.EntityId)]);
  if SameText(lMeasurement.StatusText, 'Available') and
    (not lMeasurement.DetailText.IsEmpty) then
    Result := Result + '; ' + lMeasurement.DetailText;
end;

function OneLine(const aValue: string): string;
begin
  Result := StringReplace(aValue, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
end;

function ContainsRestrictedContext(const aValue: string): Boolean;
begin
  Result := ContainsText(aValue, 'window title') or
    ContainsText(aValue, 'command line') or ContainsText(aValue, 'clipboard') or
    ContainsText(aValue, 'keystroke') or ContainsText(aValue, 'typed text') or
    ContainsText(aValue, 'token=') or ContainsText(aValue, 'password=') or
    ContainsText(aValue, 'secret=');
end;

function SanitizedError(const aValue: string): string;
begin
  if aValue.IsEmpty then
    Exit('none');
  if ContainsRestrictedContext(aValue) then
    Exit('[redacted restricted context]');
  Result := OneLine(aValue);
end;

function DiagnosticNameAllowed(const aName: string): Boolean;
const
  cAllowedPrefixes: array[0..10] of string = ('collector_', 'provider_',
    'queue_', 'history_', 'sqlite_', 'monitor_', 'etw_', 'sample_', 'disk_',
    'process_', 'gpu_');
var
  lPrefix: string;
begin
  Result := False;
  if ContainsRestrictedContext(aName) then
    Exit;
  for lPrefix in cAllowedPrefixes do
    if StartsText(lPrefix, aName) then
      Exit(True);
end;

function BuildDiagnosticText(
  const aSource: TMachineOverviewPresentationSource;
  const aPresentation: TMachineOverviewPresentation): string;
var
  lDiagnostic: TMachineOverviewNamedDiagnostic;
  lIncident: TMachineOverviewIncidentPresentation;
  lIndex: Integer;
  lMeasurement: TMachineOverviewMeasurement;
  lProvider: TMachineOverviewProviderState;
  lRow: TMachineOverviewRow;
begin
  Result := 'Machine Overview diagnostic snapshot' + sLineBreak +
    'Captured at UTC: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz',
      aSource.CapturedAtUtc, TFormatSettings.Invariant) + sLineBreak +
    'Sequence: ' + UIntToStr(aSource.Sequence) + sLineBreak + sLineBreak +
    'Visible rows' + sLineBreak;
  for lRow in aPresentation.Rows do
    Result := Result + MachineOverviewSelectedRowCopy(lRow) + sLineBreak;
  Result := Result + sLineBreak + 'Logical processors' + sLineBreak;
  for lIndex := 0 to High(aSource.LogicalProcessorValues) do
    if aSource.LogicalProcessorValues[lIndex].Available then
      Result := Result + Format('Logical processor %d: %s', [lIndex,
        FormatPercent(aSource.LogicalProcessorValues[lIndex].Value)]) + sLineBreak
    else
      Result := Result + Format('Logical processor %d: Unavailable',
        [lIndex]) + sLineBreak;
  Result := Result + sLineBreak + 'Providers' + sLineBreak;
  for lProvider in aSource.ProviderStates do
    Result := Result + lProvider.ProviderId + ': ' +
      ProviderStatusText(lProvider.Status) + '; age=' +
      FormatAge(lProvider.DataAgeMs) + '; error=' +
      SanitizedError(lProvider.ErrorText) + sLineBreak;
  Result := Result + sLineBreak + 'Queues and persistence' + sLineBreak +
    Format('raw queue depth=%d; dropped=%d', [aSource.RawQueueDepth,
      aSource.RawSamplesDropped]) + sLineBreak +
    Format('history queue depth=%d; dropped=%d', [aSource.HistoryQueueDepth,
      aSource.HistoryRecordsDropped]) + sLineBreak;
  if aSource.LastSQLiteCommitAvailable then
    Result := Result + Format('SQLite commit: %d ms; error=%s',
      [aSource.LastSQLiteCommitDurationMs,
       SanitizedError(aSource.LastSQLiteError)]) + sLineBreak
  else
    Result := Result + 'SQLite commit: Unavailable; error=' +
      SanitizedError(aSource.LastSQLiteError) + sLineBreak;
  if aSource.SelfMetricsAvailable then
    Result := Result + Format('monitor CPU=%s; private memory=%s; write rate=%s',
      [InvariantFormat('0.##', aSource.MonitorCpuPercent) + '%',
       FormatBytes(aSource.MonitorPrivateBytes),
       FormatBytesPerSecond(aSource.MonitorWriteBytesPerSecond)]) + sLineBreak
  else
    Result := Result + 'monitor CPU=Unavailable; private memory=Unavailable; '+
      'write rate=Unavailable' + sLineBreak;
  Result := Result + sLineBreak + 'Incidents' + sLineBreak;
  for lIncident in aSource.Incidents do
    Result := Result + FormatDateTime('yyyy-mm-dd hh:nn:ss',
      lIncident.OccurredAtLocal) + '; ' + SeverityText(lIncident.Severity) +
      '; ' + OneLine(lIncident.Summary) + '; ' +
      SanitizedError(lIncident.DiagnosticText) + sLineBreak;
  Result := Result + sLineBreak + 'Process path availability' + sLineBreak;
  for lMeasurement in aSource.Measurements do
    if StartsText('process_', lMeasurement.Name) and
      ContainsText(lMeasurement.Name, '_rank:') then
      Result := Result + lMeasurement.Name + ' path status=' +
        OneLine(lMeasurement.StatusText) + sLineBreak;
  Result := Result + sLineBreak + 'Provider collection latency' + sLineBreak;
  for lMeasurement in aSource.Measurements do
    if StartsText('collector_duration_ms:', lMeasurement.Name) and
      lMeasurement.Available then
      Result := Result + OneLine(lMeasurement.Name) + '=' +
        InvariantFormat('0', lMeasurement.Value) + ' ms' + sLineBreak;
  Result := Result + sLineBreak + 'Additional diagnostics' + sLineBreak;
  for lDiagnostic in aSource.AdditionalDiagnostics do
    if DiagnosticNameAllowed(lDiagnostic.Name) and
      (not ContainsRestrictedContext(lDiagnostic.ValueText)) then
      Result := Result + OneLine(lDiagnostic.Name) + '=' +
        OneLine(lDiagnostic.ValueText) + sLineBreak;
end;

function BuildMachineOverviewPresentation(
  const aSource: TMachineOverviewPresentationSource): TMachineOverviewPresentation;
var
  lDiskIds: TArray<string>;
  lDiskId: string;
  lMeasurement: TMachineOverviewMeasurement;
  lSeverity: TMachineOverviewSeverity;
  i: Integer;
begin
  Result := Default(TMachineOverviewPresentation);
  Result.CapturedAtUtc := aSource.CapturedAtUtc;
  Result.Sequence := aSource.Sequence;
  if aSource.OverallReason.IsEmpty then
    lSeverity := TMachineOverviewSeverity.Unavailable
  else
    lSeverity := aSource.OverallSeverity;
  AddRow(Result, 'overall', 'Status', 'Overall', BuildOverallText(aSource),
    lSeverity, TMachineOverviewAction.None);
  if aSource.IncidentCountLast24Hours > 0 then
    lSeverity := TMachineOverviewSeverity.Notice
  else
    lSeverity := TMachineOverviewSeverity.Normal;
  AddRow(Result, 'incidents', 'Status', 'Incidents, last 24 hours',
    BuildIncidentText(aSource), lSeverity,
    TMachineOverviewAction.OpenIncidentHistory);
  if aSource.CpuAggregate.NowValue.Available then
    lSeverity := TMachineOverviewSeverity.Normal
  else
    lSeverity := TMachineOverviewSeverity.Unavailable;
  AddRow(Result, 'cpu', 'System', 'CPU', BuildCpuText(aSource), lSeverity,
    TMachineOverviewAction.None);
  if TryFindMeasurement(aSource.Measurements, 'physical_total_bytes',
      lMeasurement) and lMeasurement.Available then
    lSeverity := TMachineOverviewSeverity.Normal
  else
    lSeverity := TMachineOverviewSeverity.Unavailable;
  AddRow(Result, 'memory', 'System', 'Memory', BuildMemoryText(aSource),
    lSeverity, TMachineOverviewAction.None);
  if TryFindMeasurement(aSource.Measurements, 'gpu_overall_percent',
      lMeasurement) and lMeasurement.Available then
    lSeverity := TMachineOverviewSeverity.Normal
  else
    lSeverity := TMachineOverviewSeverity.Unavailable;
  AddRow(Result, 'gpu', 'System', 'GPU', BuildGpuText(aSource), lSeverity,
    TMachineOverviewAction.None);
  if TryFindMeasurement(aSource.Measurements, 'foreground_reply_ms',
      lMeasurement) and lMeasurement.Available then
    lSeverity := TMachineOverviewSeverity.Normal
  else
    lSeverity := TMachineOverviewSeverity.Unavailable;
  AddRow(Result, 'responsiveness', 'System', 'Responsiveness',
    BuildResponsivenessText(aSource), lSeverity, TMachineOverviewAction.None);
  if TryFindMeasurement(aSource.Measurements, 'process_count', lMeasurement)
      and lMeasurement.Available then
    lSeverity := TMachineOverviewSeverity.Normal
  else
    lSeverity := TMachineOverviewSeverity.Unavailable;
  AddRow(Result, 'system-counts', 'System', 'System counts',
    BuildSystemCountsText(aSource), lSeverity, TMachineOverviewAction.None);
  AddRow(Result, 'disk-summary', 'Storage', 'Disk summary',
    BuildDiskSummaryText(aSource, lSeverity), lSeverity,
    TMachineOverviewAction.None);

  for lMeasurement in aSource.Measurements do
    if StartsText('disk_', lMeasurement.Name) then
      AddUniqueDiskId(lDiskIds, lMeasurement.EntityId);
  SortDiskIds(lDiskIds);
  for lDiskId in lDiskIds do
    AddRow(Result, 'disk:' + lDiskId, 'Storage',
      DiskDisplayName(aSource, lDiskId), BuildDiskText(aSource, lDiskId),
      TMachineOverviewSeverity.Normal, TMachineOverviewAction.None);

  for i := 1 to 5 do
  begin
    if TryFindMeasurement(aSource.Measurements,
        'process_cpu_rank:' + IntToStr(i), lMeasurement) and
      lMeasurement.Available then
      lSeverity := TMachineOverviewSeverity.Normal
    else
      lSeverity := TMachineOverviewSeverity.Unavailable;
    AddRow(Result, 'top-cpu:' + IntToStr(i), 'Processes',
      'CPU ' + IntToStr(i), BuildRankedProcessText(aSource,
        'process_cpu_rank', 'process_cpu_average_15s',
        'process_cpu_peak_60s', 'percent', i), lSeverity,
      TMachineOverviewAction.None);
  end;
  for i := 1 to 5 do
  begin
    if TryFindMeasurement(aSource.Measurements,
        'process_ram_rank:' + IntToStr(i), lMeasurement) and
      lMeasurement.Available then
      lSeverity := TMachineOverviewSeverity.Normal
    else
      lSeverity := TMachineOverviewSeverity.Unavailable;
    AddRow(Result, 'top-ram:' + IntToStr(i), 'Processes',
      'RAM ' + IntToStr(i), BuildRankedProcessText(aSource,
        'process_ram_rank', '', 'process_ram_peak_60s', 'bytes', i),
      lSeverity, TMachineOverviewAction.None);
  end;
  for i := 1 to 5 do
  begin
    if TryFindMeasurement(aSource.Measurements,
        'process_io_rank:' + IntToStr(i), lMeasurement) and
      lMeasurement.Available then
      lSeverity := TMachineOverviewSeverity.Normal
    else
      lSeverity := TMachineOverviewSeverity.Unavailable;
    AddRow(Result, 'top-io:' + IntToStr(i), 'Processes',
      'I/O ' + IntToStr(i), BuildRankedProcessText(aSource,
        'process_io_rank', 'process_io_average_15s',
        'process_io_peak_60s', 'bytes_per_second', i), lSeverity,
      TMachineOverviewAction.None);
  end;
  Result.DiagnosticText := BuildDiagnosticText(aSource, Result);
end;

function MachineOverviewSelectedRowCopy(
  const aRow: TMachineOverviewRow): string;
begin
  Result := aRow.LabelText + ': ' + aRow.ValueText;
end;

function TryFindMachineOverviewRow(
  const aPresentation: TMachineOverviewPresentation; const aRowId: string;
  out aRow: TMachineOverviewRow): Boolean;
var
  lRow: TMachineOverviewRow;
begin
  for lRow in aPresentation.Rows do
    if SameText(lRow.RowId, aRowId) then
    begin
      aRow := lRow;
      Exit(True);
    end;
  aRow := Default(TMachineOverviewRow);
  Result := False;
end;

end.

unit ActiveAppView.MachineOverview.Evidence;

interface

uses
  System.SysUtils,
  ActiveAppView.MachineOverview.Incidents, ActiveAppView.MachineOverview.Providers;

type
  TMachineOverviewEvidenceRow = record
    Phase, Kind, Name, Identity, Average, Peak, PeakTime, Measured, AccessibleText: string;
  end;

  TMachineOverviewEvidenceConfig = record
    PreWindowMs, PostWindowMs, RingRetentionMs: UInt64;
    ProcessIntervalMs, SystemIntervalMs: Cardinal;
    class function Defaults: TMachineOverviewEvidenceConfig; static;
  end;

  // Our aggregator thread owns this recorder; snapshots never share mutable accumulators.
  TMachineOverviewEvidenceRecorder = class
  private
    fState: TObject;
  public
    constructor Create(const aConfig: TMachineOverviewEvidenceConfig);
    destructor Destroy; override;
    procedure ObserveSample(const aSample: TMachineOverviewProviderSample);
    // Apply/TakeCompleted set HasEvidenceUpdate only when supplying a payload. False
    // means headline-only: Evidence is empty and callers must preserve stored evidence.
    // Finalized keys reject every change kind/origin before admission. We retain the
    // latest 4096 finalized keys in FIFO order; older keys may be admitted after expiry.
    procedure Apply(var aChange: TMachineOverviewIncidentChange);
    function TakeCompleted(const aNowUtc: TDateTime): TArray<TMachineOverviewIncidentChange>;
    function TrackedIncidentCount: Integer;
  end;

function MachineOverviewEvidenceToJson(const aEvidence: TMachineOverviewIncidentEvidence): string;
function MachineOverviewEvidenceRows(const aEvidence: TMachineOverviewIncidentEvidence):
  TArray<TMachineOverviewEvidenceRow>;
function MachineOverviewEvidenceText(const aEvidence: TMachineOverviewIncidentEvidence): string; overload;
function MachineOverviewEvidenceText(const aEvidence: TMachineOverviewIncidentEvidence;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): string; overload;
function MachineOverviewEvidenceStateText(const aState: TMachineOverviewEvidenceState): string;
function MachineOverviewEvidenceTimeText(const aUtc: TDateTime): string; overload;
function MachineOverviewEvidenceTimeText(const aUtc: TDateTime;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): string; overload;
function TryMachineOverviewEvidenceFromJson(const aText: string;
  out aEvidence: TMachineOverviewIncidentEvidence; out aError: string): Boolean;

implementation

uses
  System.Classes, System.DateUtils, System.Generics.Collections, System.JSON, System.Math, System.StrUtils,
  AutoFree, maxLogic.StrUtils,
  ActiveAppView.MachineOverview.Types;

const
  cDayMs: Double = 86400000.0;
  cMaximumJsonBytes = 16384;
  cMaximumFinalizedKeys = 4096;
  cPhaseNames: array[TMachineOverviewEvidencePhaseKind] of string = ('before', 'during', 'after');
  cGapNames: array[TMachineOverviewEvidenceGapReason] of string = ('process-missing', 'system-missing',
    'provider-unavailable', 'started-late', 'stopped', 'truncated');
  cEvidenceDisplayPhases: array[0..2] of TMachineOverviewEvidencePhaseKind =
    (TMachineOverviewEvidencePhaseKind.During, TMachineOverviewEvidencePhaseKind.Before,
    TMachineOverviewEvidencePhaseKind.After);

type
  TEvidenceSample = record
    AtUtc, PreviousUtc: TDateTime;
    IsProcess, IsDisk, Available, Truncated, RamTruncated, IoTruncated: Boolean;
    IntervalMs: Cardinal;
    LogicalProcessors, Inaccessible, ProcessCount, ApplicationCount: Integer;
    Cpu, Dpc, Interrupt, Residual: TMachineOverviewOptionalDouble;
    PhysicalUsed, Commit, Paging, DiskActive, DiskLatency, DiskQueue, DiskThroughput,
      MeasuredIo: TMachineOverviewOptionalDouble;
    DiskIdentity, DiskName: string;
    RamProcesses, IoProcesses: TArray<TMachineOverviewResourceContribution>;
    Processes: TArray<TMachineOverviewProcessContribution>;
    Applications: TArray<TMachineOverviewApplicationContribution>;
  end;

  TEvidenceTotal = record
    Sum, Weight: Double;
    Value: TMachineOverviewEvidenceStatistic;
    procedure Add(const aValue: Double; const aWeight: Double; const aAtUtc: TDateTime;
      const aPeakSourceName: string = '');
    function Snapshot: TMachineOverviewEvidenceStatistic;
  end;

  TResourceAccumulator = record
    Items: array[0..63] of TMachineOverviewResourceContribution;
    Count: Integer;
    procedure Add(const aValue: TMachineOverviewResourceContribution; const aWeight: Double;
      const aIo: Boolean; var aTruncated: Boolean);
    function Snapshot(const aWeight: Double; const aMaximum: Integer;
      const aIo: Boolean): TArray<TMachineOverviewResourceContribution>;
  end;

  TEvidencePhaseAccumulator = record
    Value: TMachineOverviewEvidencePhase;
    Cpu, Dpc, Interrupt, Measured, Residual: TEvidenceTotal;
    PhysicalUsed, Commit, Paging, DiskActive, DiskLatency, DiskQueue, DiskThroughput, MeasuredIo: TEvidenceTotal;
    Ram, Io: TResourceAccumulator;
    DiskIdentity: string;
    HasDisk: Boolean;
    ProcessWeight: Double;
    ProcessCount, ApplicationCount: Integer;
    Processes: array[0..63] of TMachineOverviewProcessContribution;
    Applications: array[0..31] of TMachineOverviewApplicationContribution;
    procedure AddProcess(const aValue: TMachineOverviewProcessContribution; const aWeight: Double;
      var aTruncated: Boolean);
    procedure AddApplication(const aValue: TMachineOverviewApplicationContribution; const aWeight: Double;
      var aTruncated: Boolean);
    procedure Add(const aSample: TEvidenceSample; var aTruncated: Boolean; const aRam, aIo: Boolean);
    function Snapshot(const aEndUtc: TDateTime; const aProcessMs, aSystemMs: Cardinal): TMachineOverviewEvidencePhase;
  end;

  TEvidencePhaseAccumulators = array[TMachineOverviewEvidencePhaseKind] of TEvidencePhaseAccumulator;

  TEvidenceIncident = class
  public
    Headline: TMachineOverviewIncident;
    Config: TMachineOverviewEvidenceConfig;
    Value: TMachineOverviewIncidentEvidence;
    Phases: TEvidencePhaseAccumulators;
    Pending: array[0..2] of TEvidenceSample;
    HasPending: array[0..2] of Boolean;
    LatestUtc: TDateTime;
    constructor Create(const aIncident: TMachineOverviewIncident; const aConfig: TMachineOverviewEvidenceConfig);
    procedure AddGap(const aStart, aEnd: TDateTime; const aReason: TMachineOverviewEvidenceGapReason);
    procedure Observe(const aSample: TEvidenceSample);
    function Snapshot(const aState: TMachineOverviewEvidenceState): TMachineOverviewIncidentEvidence;
  end;

  TEvidenceRecorderState = class
  public
    Config: TMachineOverviewEvidenceConfig;
    Ring: array[0..1023] of TEvidenceSample;
    RingFirst, RingCount: Integer;
    LastProcessUtc, LastSystemUtc, LastDiskUtc, LatestUtc: TDateTime;
    Entries: TObjectList<TEvidenceIncident>;
    Ready: TList<TMachineOverviewIncidentChange>;
    FinalizedKeys: THashSet<string>;
    FinalizedOrder: TQueue<string>;
    constructor Create(const aConfig: TMachineOverviewEvidenceConfig);
    destructor Destroy; override;
    function Compact(const aSample: TMachineOverviewProviderSample): TEvidenceSample;
    procedure Replay(const aEntry: TEvidenceIncident);
    procedure EvictOldest;
    procedure RememberFinalized(const aStableId: string);
  end;

resourcestring
  rsEvidenceComplete = 'complete';
  rsEvidenceCollecting = 'collecting';
  rsEvidencePartial = 'incomplete (ActiveAppView stopped before the after-window ended)';
  rsEvidenceTrimmed = 'removed by the storage budget';
  rsEvidenceLegacy = 'not recorded (incident predates measured evidence)';
  rsEvidenceUnavailable = 'Unavailable';
  rsEvidenceHeading = 'Evidence: %s';
  rsEvidenceMeasurement = 'Measurement: CPU %% is the share of the whole machine (100%% = %d logical processors; ' +
    'one fully busy logical processor = %s%%). Process CPU is kernel+user time per sampling interval ' +
    '(processes %d ms, system %d ms). CPU of processes that exit or start and end between samples, ' +
    'of inaccessible processes, and DPC/interrupt time is shown as not attributed. ' +
    'Process lists are measurements, not proof of cause.';
  rsEvidenceNoMeasurement = 'Measurement: not recorded. Sampling intervals and logical processor count are unavailable.';
  rsEvidenceOneCore = '%s%% of machine (= %s logical processors busy)';
  rsEvidenceShare = '%s%% of machine';
  rsEvidenceNoMeasurementRow = 'no measurement';
  rsEvidenceProcessListIdentity = 'PID %d, started %s';
  rsEvidenceProcessIdentity = 'PID %d, started %s; last seen %s; %s';
  rsEvidenceApplicationIdentity = '%d processes (same executable name, from the 5 busiest per sample)';
  rsEvidenceSampleCount = '%d of %d samples';
  rsEvidencePhaseHeading = '%s %s - %s, %d of %d process samples, %d of %d system samples:';
  rsEvidenceFact = '  %s %s; %s: average %s; peak %s at %s; %s';
  rsEvidenceGaps = 'Gaps:';
  rsEvidenceNoGaps = 'Gaps: none recorded';
  rsEvidenceLimits = 'Coverage: inaccessible processes up to %d; %s; additional gaps omitted %d.';
  rsEvidenceListsComplete = 'lists complete';
  rsEvidenceListsShortened = 'lists shortened';
  rsEvidenceAccessibleFact = '%s, %s %s%s: average %s, peak %s at %s, %s';
  rsEvidenceAccessibleUnmeasured = '%s, %s %s: no measurement, %s';
  rsEvidenceUnmeasuredFact = '  %s %s: no measurement; %s';
  rsEvidenceAccessibleGap = 'Gap, %s, %s';
  rsEvidenceBefore = 'Before';
  rsEvidenceDuring = 'During';
  rsEvidenceAfter = 'After';
  rsEvidenceSystem = 'System';
  rsEvidenceProcess = 'Process';
  rsEvidenceApplication = 'Application';
  rsEvidenceGap = 'Gap';
  rsEvidenceMemory = 'Memory';
  rsEvidenceDisk = 'Disk';
  rsEvidenceMultipleDisks = 'Multiple busiest disks';
  rsEvidenceUnknownDisk = 'Unknown disk';
  rsEvidenceProcessRam = 'Process RAM';
  rsEvidenceProcessIo = 'Process I/O';
  rsEvidencePhysicalUsed = 'Physical used';
  rsEvidenceCommit = 'Commit';
  rsEvidencePaging = 'Paging';
  rsEvidenceActive = 'Active';
  rsEvidenceLatency = 'Latency';
  rsEvidenceQueue = 'Queue';
  rsEvidenceThroughput = 'Throughput';
  rsEvidenceMeasuredIo = 'Measured process I/O';
  rsEvidencePrivate = '%s private';
  rsEvidenceGrowth = '%s; grew %s';
  rsEvidenceIoBytes = '%s; transferred %s';
  rsEvidenceResourceMeasurement = 'RAM is each process''s private bytes at each %d ms process sample, ' +
    'from the 10 largest per sample; growth is the last minus the first value in the phase. ' +
    'I/O is read+write bytes per second from process I/O counters (file, network and device I/O). ' +
    'Paging and memory-mapped file reads are not attributed to processes. Disk values are for the busiest disk.';
  rsEvidenceCpu = 'CPU';
  rsEvidenceDpc = 'DPC';
  rsEvidenceInterrupt = 'Interrupt';
  rsEvidenceMeasured = 'Measured processes';
  rsEvidenceUnattributed = 'Not attributed';
  rsEvidenceProcessMissing = 'process samples missing';
  rsEvidenceSystemMissing = 'system samples missing';
  rsEvidenceProviderUnavailable = 'provider unavailable';
  rsEvidenceStartedLate = 'collection started late';
  rsEvidenceStopped = 'collection stopped';
  rsEvidenceTruncated = 'truncated';

function MachineOverviewEvidenceStateText(const aState: TMachineOverviewEvidenceState): string;
begin
  case aState of
    TMachineOverviewEvidenceState.Collecting: Result := rsEvidenceCollecting;
    TMachineOverviewEvidenceState.Complete: Result := rsEvidenceComplete;
    TMachineOverviewEvidenceState.Partial: Result := rsEvidencePartial;
    TMachineOverviewEvidenceState.Trimmed: Result := rsEvidenceTrimmed;
  else
    Result := rsEvidenceLegacy;
  end;
end;

function MachineOverviewEvidenceTimeText(const aUtc: TDateTime): string;
begin
  Result := MachineOverviewEvidenceTimeText(aUtc, nil);
end;

function MachineOverviewEvidenceTimeText(const aUtc: TDateTime;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): string;
var
  lLocal: TDateTime;
  lOffsetMinutes: Int64;
  lSign: string;
begin
  if aUtc <= 0 then
    Exit(rsEvidenceUnavailable);
  if Assigned(aUtcToLocal) then
    lLocal := aUtcToLocal(aUtc)
  else
    lLocal := TTimeZone.Local.ToLocalTime(aUtc);
  lOffsetMinutes := Round((lLocal - aUtc) * MinsPerDay);
  lSign := '+';
  if lOffsetMinutes < 0 then
    lSign := '-';
  lOffsetMinutes := Abs(lOffsetMinutes);
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', lLocal, TFormatSettings.Invariant) +
    Format(' %s%.2d:%.2d', [lSign, lOffsetMinutes div 60, lOffsetMinutes mod 60]) +
    ' (' + FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz"Z"', aUtc, TFormatSettings.Invariant) + ')';
end;

function EvidenceNumber(const aValue: Double): string;
begin
  Result := FormatFloat('0.###', aValue, TFormatSettings.Invariant);
end;

function EvidenceRowTime(const aUtc: TDateTime; const aExport: Boolean;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): string;
begin
  if aExport or (aUtc <= 0) then
    Exit(MachineOverviewEvidenceTimeText(aUtc, aUtcToLocal));
  Result := FormatDateTime('hh:nn:ss', TTimeZone.Local.ToLocalTime(aUtc), TFormatSettings.Invariant);
end;

function EvidencePhaseText(const aKind: TMachineOverviewEvidencePhaseKind): string;
begin
  case aKind of
    TMachineOverviewEvidencePhaseKind.Before: Result := rsEvidenceBefore;
    TMachineOverviewEvidencePhaseKind.During: Result := rsEvidenceDuring;
    TMachineOverviewEvidencePhaseKind.After: Result := rsEvidenceAfter;
  end;
end;

function EvidenceGapText(const aReason: TMachineOverviewEvidenceGapReason): string;
begin
  case aReason of
    TMachineOverviewEvidenceGapReason.ProcessSamplesMissing: Result := rsEvidenceProcessMissing;
    TMachineOverviewEvidenceGapReason.SystemSamplesMissing: Result := rsEvidenceSystemMissing;
    TMachineOverviewEvidenceGapReason.ProviderUnavailable: Result := rsEvidenceProviderUnavailable;
    TMachineOverviewEvidenceGapReason.CollectionStartedLate: Result := rsEvidenceStartedLate;
    TMachineOverviewEvidenceGapReason.CollectionStopped: Result := rsEvidenceStopped;
    TMachineOverviewEvidenceGapReason.Truncated: Result := rsEvidenceTruncated;
  end;
end;

function EvidenceStatisticRow(const aPhase: TMachineOverviewEvidencePhase; const aName: string;
  const aValue: TMachineOverviewEvidenceStatistic; const aProcess, aExport: Boolean;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): TMachineOverviewEvidenceRow;
begin
  Result := Default(TMachineOverviewEvidenceRow);
  Result.Phase := EvidencePhaseText(aPhase.Kind);
  Result.Kind := rsEvidenceSystem;
  Result.Name := aName;
  Result.Average := rsEvidenceNoMeasurementRow;
  if aValue.Available then
  begin
    Result.Average := Format(rsEvidenceShare, [EvidenceNumber(aValue.Average)]);
    Result.Peak := Format(rsEvidenceShare, [EvidenceNumber(aValue.Peak)]);
    Result.PeakTime := EvidenceRowTime(aValue.PeakAtUtc, aExport, aUtcToLocal);
  end;
  if aProcess then
    Result.Measured := Format(rsEvidenceSampleCount, [aPhase.ProcessSampleCount, aPhase.ExpectedProcessSampleCount])
  else
    Result.Measured := Format(rsEvidenceSampleCount, [aPhase.SystemSampleCount, aPhase.ExpectedSystemSampleCount]);
end;

function EvidenceBytes(const aValue: Double; const aRate: Boolean): string;
begin
  if Abs(aValue) >= 1073741824 then
    Result := FormatFloat('0.0', aValue / 1073741824, TFormatSettings.Invariant) + ' GB'
  else if Abs(aValue) >= 1048576 then
    Result := FormatFloat('0.0', aValue / 1048576, TFormatSettings.Invariant) + ' MB'
  else if Abs(aValue) >= 1024 then
    Result := FormatFloat('0.0', aValue / 1024, TFormatSettings.Invariant) + ' KB'
  else
    Result := FormatFloat('0.0', aValue, TFormatSettings.Invariant) + ' B';
  if aRate then
    Result := Result + '/s';
end;

function ResourceStatisticRow(const aPhase: TMachineOverviewEvidencePhase;
  const aKind, aName, aUnit: string; const aValue: TMachineOverviewEvidenceStatistic;
  const aExport: Boolean; const aUtcToLocal: TFunc<TDateTime, TDateTime>): TMachineOverviewEvidenceRow;
begin
  Result := Default(TMachineOverviewEvidenceRow);
  Result.Phase := EvidencePhaseText(aPhase.Kind);
  Result.Kind := aKind;
  Result.Name := aName;
  Result.Average := rsEvidenceNoMeasurementRow;
  if aValue.Available then
  begin
    Result.Average := FormatFloat('0.0', aValue.Average, TFormatSettings.Invariant) + aUnit;
    Result.Peak := FormatFloat('0.0', aValue.Peak, TFormatSettings.Invariant) + aUnit;
    if not aValue.PeakSourceName.IsEmpty then
      Result.Peak := Result.Peak + ' (' + aValue.PeakSourceName + ')';
    Result.PeakTime := EvidenceRowTime(aValue.PeakAtUtc, aExport, aUtcToLocal);
  end;
end;

procedure AddResourceEvidenceRows(const aRows: TList<TMachineOverviewEvidenceRow>;
  const aEvidence: TMachineOverviewIncidentEvidence; const aPhase: TMachineOverviewEvidencePhase;
  const aExport: Boolean; const aUtcToLocal: TFunc<TDateTime, TDateTime>);
var
  lResource: TMachineOverviewResourceKind;
  lItems: TArray<TMachineOverviewResourceContribution>;
  lItem: TMachineOverviewResourceContribution;
  lRow: TMachineOverviewEvidenceRow;
  lStartUtc, lIncidentUtc: TDateTime;
  lIdentity: string;
begin
  if TMachineOverviewResourceKind.Ram in aEvidence.Resources then
  begin
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceMemory, rsEvidencePhysicalUsed, '%', aPhase.PhysicalUsed, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceMemory, rsEvidenceCommit, '%', aPhase.Commit, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceMemory, rsEvidencePaging, ' MB/s', aPhase.Paging, aExport, aUtcToLocal));
  end;
  if TMachineOverviewResourceKind.Io in aEvidence.Resources then
  begin
    var lDiskName := aPhase.DiskName;
    if lDiskName.IsEmpty then
      lDiskName := aEvidence.DiskName; // Our earlier v2 payloads have only the incident-wide name.
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceDisk, lDiskName + ' ' + rsEvidenceActive, '%', aPhase.DiskActive, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceDisk, lDiskName + ' ' + rsEvidenceLatency, ' ms', aPhase.DiskLatency, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceDisk, lDiskName + ' ' + rsEvidenceQueue, '', aPhase.DiskQueue, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceDisk, lDiskName + ' ' + rsEvidenceThroughput, ' MB/s', aPhase.DiskThroughput, aExport, aUtcToLocal));
    aRows.Add(ResourceStatisticRow(aPhase, rsEvidenceDisk, rsEvidenceMeasuredIo, ' MB/s', aPhase.MeasuredProcessIo, aExport, aUtcToLocal));
  end;
  for lResource := Low(lResource) to High(lResource) do
  begin
    if not (lResource in aEvidence.Resources) then
      Continue;
    if lResource = TMachineOverviewResourceKind.Ram then
      lItems := aPhase.RamProcesses
    else
      lItems := aPhase.IoProcesses;
    for lItem in lItems do
    begin
      lRow := Default(TMachineOverviewEvidenceRow);
      lRow.Phase := EvidencePhaseText(aPhase.Kind);
      lRow.Kind := rsEvidenceProcessRam;
      if lResource = TMachineOverviewResourceKind.Io then
        lRow.Kind := rsEvidenceProcessIo;
      lRow.Name := lItem.DisplayName;
      lStartUtc := EncodeDate(1601, 1, 1) + lItem.CreationTime100ns / 864000000000.0;
      if aExport then
        lRow.Identity := Format(rsEvidenceProcessIdentity, [lItem.ProcessId,
          EvidenceRowTime(lStartUtc, True, aUtcToLocal), EvidenceRowTime(lItem.LastSeenUtc, True, aUtcToLocal),
          lItem.ImagePath])
      else
      begin
        lIdentity := EvidenceRowTime(lStartUtc, False, aUtcToLocal);
        lIncidentUtc := aEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].StartUtc;
        if Trunc(TTimeZone.Local.ToLocalTime(lStartUtc)) <> Trunc(TTimeZone.Local.ToLocalTime(lIncidentUtc)) then
          lIdentity := FormatDateTime('yyyy-mm-dd', TTimeZone.Local.ToLocalTime(lStartUtc), TFormatSettings.Invariant) +
            ' ' + lIdentity;
        lRow.Identity := Format(rsEvidenceProcessListIdentity, [lItem.ProcessId, lIdentity]);
      end;
      lRow.PeakTime := EvidenceRowTime(lItem.PeakAtUtc, aExport, aUtcToLocal);
      lRow.Measured := Format(rsEvidenceSampleCount, [lItem.SampleCount, aPhase.ExpectedProcessSampleCount]);
      if lResource = TMachineOverviewResourceKind.Ram then
      begin
        lRow.Average := Format(rsEvidencePrivate, [EvidenceBytes(lItem.AverageValue, False)]);
        lRow.Peak := Format(rsEvidencePrivate, [EvidenceBytes(lItem.PeakValue, False)]);
        lRow.Measured := Format(rsEvidenceGrowth, [lRow.Measured, EvidenceBytes(lItem.LastValue - lItem.FirstValue, False)]);
      end else begin
        lRow.Average := EvidenceBytes(lItem.AverageValue, True);
        lRow.Peak := EvidenceBytes(lItem.PeakValue, True);
        lRow.Measured := Format(rsEvidenceIoBytes, [lRow.Measured, EvidenceBytes(lItem.TotalBytes, False)]);
      end;
      aRows.Add(lRow);
    end;
  end;
end;

function BuildEvidenceRows(const aEvidence: TMachineOverviewIncidentEvidence; const aExport: Boolean;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>):
  TArray<TMachineOverviewEvidenceRow>;
var
  g: TGarbos;
  lRows: TList<TMachineOverviewEvidenceRow>;
  lKind: TMachineOverviewEvidencePhaseKind;
  lPhase: TMachineOverviewEvidencePhase;
  lProcess: TMachineOverviewProcessContribution;
  lApplication: TMachineOverviewApplicationContribution;
  lGap: TMachineOverviewEvidenceGap;
  lRow: TMachineOverviewEvidenceRow;
  i: Integer;
  lIdentity: string;
  lProcessStartUtc, lIncidentStartUtc: TDateTime;
begin
  g := Default(TGarbos);
  GC(lRows, TList<TMachineOverviewEvidenceRow>.Create, g);
  if aEvidence.State in [TMachineOverviewEvidenceState.Collecting, TMachineOverviewEvidenceState.Complete,
    TMachineOverviewEvidenceState.Partial] then
  begin
    for lKind in cEvidenceDisplayPhases do
    begin
      lPhase := aEvidence.Phases[lKind];
      lPhase.Kind := lKind;
      if lPhase.StartUtc <= 0 then
        Continue;
      if aEvidence.Resources <> [] then
        AddResourceEvidenceRows(lRows, aEvidence, lPhase, aExport, aUtcToLocal);
      lRows.Add(EvidenceStatisticRow(lPhase, rsEvidenceCpu, lPhase.SystemCpu, False, aExport, aUtcToLocal));
      lRows.Add(EvidenceStatisticRow(lPhase, rsEvidenceDpc, lPhase.Dpc, False, aExport, aUtcToLocal));
      lRows.Add(EvidenceStatisticRow(lPhase, rsEvidenceInterrupt, lPhase.Interrupt, False, aExport, aUtcToLocal));
      lRows.Add(EvidenceStatisticRow(lPhase, rsEvidenceMeasured, lPhase.MeasuredProcessCpu, True, aExport, aUtcToLocal));
      lRows.Add(EvidenceStatisticRow(lPhase, rsEvidenceUnattributed, lPhase.UnattributedCpu, True, aExport, aUtcToLocal));
      for lProcess in lPhase.Processes do
      begin
        lRow := Default(TMachineOverviewEvidenceRow);
        lRow.Phase := EvidencePhaseText(lKind);
        lRow.Kind := rsEvidenceProcess;
        lRow.Name := lProcess.DisplayName;
        if aExport then
          lRow.Identity := Format(rsEvidenceProcessIdentity, [lProcess.ProcessId,
            EvidenceRowTime(EncodeDate(1601, 1, 1) + lProcess.CreationTime100ns / 864000000000.0, True, aUtcToLocal),
            EvidenceRowTime(lProcess.LastSeenUtc, True, aUtcToLocal), lProcess.ImagePath])
        else
        begin
          lProcessStartUtc := EncodeDate(1601, 1, 1) + lProcess.CreationTime100ns / 864000000000.0;
          lIncidentStartUtc := aEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].StartUtc;
          if lIncidentStartUtc <= 0 then
            lIncidentStartUtc := lPhase.StartUtc;
          lIdentity := EvidenceRowTime(lProcessStartUtc, False, aUtcToLocal);
          if Trunc(TTimeZone.Local.ToLocalTime(lProcessStartUtc)) <>
            Trunc(TTimeZone.Local.ToLocalTime(lIncidentStartUtc)) then
            lIdentity := FormatDateTime('yyyy-mm-dd', TTimeZone.Local.ToLocalTime(lProcessStartUtc),
              TFormatSettings.Invariant) + ' ' + lIdentity;
          lRow.Identity := Format(rsEvidenceProcessListIdentity, [lProcess.ProcessId, lIdentity]);
        end;
        if aExport then
        begin
          lRow.Average := Format(rsEvidenceOneCore, [EvidenceNumber(lProcess.AverageCpuPercent),
            EvidenceNumber(lProcess.AverageCpuPercent * aEvidence.LogicalProcessorCount / 100)]);
          lRow.Peak := Format(rsEvidenceOneCore, [EvidenceNumber(lProcess.PeakCpuPercent),
            EvidenceNumber(lProcess.PeakCpuPercent * aEvidence.LogicalProcessorCount / 100)]);
        end else begin
          lRow.Average := Format(rsEvidenceShare, [EvidenceNumber(lProcess.AverageCpuPercent)]);
          lRow.Peak := Format(rsEvidenceShare, [EvidenceNumber(lProcess.PeakCpuPercent)]);
        end;
        lRow.PeakTime := EvidenceRowTime(lProcess.PeakAtUtc, aExport, aUtcToLocal);
        lRow.Measured := Format(rsEvidenceSampleCount, [lProcess.SampleCount, lPhase.ExpectedProcessSampleCount]);
        lRows.Add(lRow);
      end;
      for lApplication in lPhase.Applications do
      begin
        lRow := Default(TMachineOverviewEvidenceRow);
        lRow.Phase := EvidencePhaseText(lKind);
        lRow.Kind := rsEvidenceApplication;
        lRow.Name := lApplication.DisplayName;
        lRow.Identity := Format(rsEvidenceApplicationIdentity, [lApplication.ProcessCount]);
        lRow.Average := Format(rsEvidenceShare, [EvidenceNumber(lApplication.AverageCpuPercent)]);
        lRow.Peak := Format(rsEvidenceShare, [EvidenceNumber(lApplication.PeakCpuPercent)]);
        lRow.PeakTime := EvidenceRowTime(lApplication.PeakAtUtc, aExport, aUtcToLocal);
        lRow.Measured := Format(rsEvidenceSampleCount, [lPhase.ProcessSampleCount, lPhase.ExpectedProcessSampleCount]);
        lRows.Add(lRow);
      end;
    end;
    for lGap in aEvidence.Gaps do
    begin
      lRow := Default(TMachineOverviewEvidenceRow);
      lRow.Kind := rsEvidenceGap;
      lRow.Name := EvidenceGapText(lGap.Reason);
      lRow.Identity := EvidenceRowTime(lGap.StartUtc, aExport, aUtcToLocal) + ' - ' +
        EvidenceRowTime(lGap.EndUtc, aExport, aUtcToLocal);
      lRows.Add(lRow);
    end;
  end;
  Result := lRows.ToArray;
  for i := 0 to High(Result) do
  begin
    lRow := Result[i];
    lIdentity := '';
    if not lRow.Identity.IsEmpty then
      lIdentity := ', ' + lRow.Identity;
    if lRow.Kind = rsEvidenceGap then
      Result[i].AccessibleText := Format(rsEvidenceAccessibleGap, [lRow.Name, lRow.Identity])
    else if lRow.Average = rsEvidenceNoMeasurementRow then
      Result[i].AccessibleText := Format(rsEvidenceAccessibleUnmeasured,
        [lRow.Phase, LowerCase(lRow.Kind), lRow.Name, lRow.Measured])
    else
      Result[i].AccessibleText := Format(rsEvidenceAccessibleFact, [lRow.Phase, LowerCase(lRow.Kind),
        lRow.Name, lIdentity, lRow.Average, lRow.Peak, lRow.PeakTime, lRow.Measured]);
  end;
end;

function MachineOverviewEvidenceRows(const aEvidence: TMachineOverviewIncidentEvidence):
  TArray<TMachineOverviewEvidenceRow>;
begin
  Result := BuildEvidenceRows(aEvidence, False, nil);
end;

function MachineOverviewEvidenceText(const aEvidence: TMachineOverviewIncidentEvidence): string;
begin
  Result := MachineOverviewEvidenceText(aEvidence, nil);
end;

function MachineOverviewEvidenceText(const aEvidence: TMachineOverviewIncidentEvidence;
  const aUtcToLocal: TFunc<TDateTime, TDateTime>): string;
var
  g: TGarbos;
  lLines: TStringList;
  lRows: TArray<TMachineOverviewEvidenceRow>;
  lRow: TMachineOverviewEvidenceRow;
  lKind: TMachineOverviewEvidencePhaseKind;
  lPhase: TMachineOverviewEvidencePhase;
  lCoverage: string;
begin
  g := Default(TGarbos);
  GC(lLines, TStringList.Create, g);
  lLines.Add(Format(rsEvidenceHeading, [MachineOverviewEvidenceStateText(aEvidence.State)]));
  if not (aEvidence.State in [TMachineOverviewEvidenceState.Collecting, TMachineOverviewEvidenceState.Complete,
    TMachineOverviewEvidenceState.Partial]) then
    Exit(lLines.Text.TrimRight);
  if aEvidence.LogicalProcessorCount > 0 then
    lLines.Add(Format(rsEvidenceMeasurement, [aEvidence.LogicalProcessorCount,
      EvidenceNumber(100 / aEvidence.LogicalProcessorCount), aEvidence.ProcessIntervalMs, aEvidence.SystemIntervalMs]))
  else
    lLines.Add(rsEvidenceNoMeasurement);
  if aEvidence.Resources <> [] then
    lLines.Add(Format(rsEvidenceResourceMeasurement, [aEvidence.ProcessIntervalMs]));
  lRows := BuildEvidenceRows(aEvidence, True, aUtcToLocal);
  for lKind in cEvidenceDisplayPhases do
  begin
    lPhase := aEvidence.Phases[lKind];
    if (lPhase.StartUtc <= 0) or (Length(lRows) = 0) then
      Continue;
    lLines.Add(Format(rsEvidencePhaseHeading, [EvidencePhaseText(lKind),
      MachineOverviewEvidenceTimeText(lPhase.StartUtc, aUtcToLocal),
      MachineOverviewEvidenceTimeText(lPhase.EndUtc, aUtcToLocal),
      lPhase.ProcessSampleCount, lPhase.ExpectedProcessSampleCount, lPhase.SystemSampleCount, lPhase.ExpectedSystemSampleCount]));
    for lRow in lRows do
      if lRow.Phase = EvidencePhaseText(lKind) then
      begin
        if lRow.Average = rsEvidenceNoMeasurementRow then
          lLines.Add(Format(rsEvidenceUnmeasuredFact, [lRow.Kind, lRow.Name, lRow.Measured]))
        else
          lLines.Add(Format(rsEvidenceFact, [lRow.Kind, lRow.Name, lRow.Identity,
            lRow.Average, lRow.Peak, lRow.PeakTime, lRow.Measured]));
      end;
  end;
  if Length(aEvidence.Gaps) = 0 then
    lLines.Add(rsEvidenceNoGaps)
  else
  begin
    lLines.Add(rsEvidenceGaps);
    for lRow in lRows do
      if lRow.Kind = rsEvidenceGap then
        lLines.Add('  ' + lRow.Identity + ': ' + lRow.Name);
  end;
  lCoverage := rsEvidenceListsComplete;
  if aEvidence.Truncated then
    lCoverage := rsEvidenceListsShortened;
  lLines.Add(Format(rsEvidenceLimits, [aEvidence.InaccessibleProcessCountMax, lCoverage, aEvidence.GapsOmitted]));
  Result := lLines.Text.TrimRight;
end;

function EvidenceTextPrefix(const aText: string; const aMaximumUnits: Integer): string;
var
  lCount: Integer;
begin
  lCount := Length(aText);
  if lCount > aMaximumUnits then
    lCount := aMaximumUnits;
  // We keep UTF-16 pairs together when a bounded prefix ends inside a character.
  if (lCount > 0) and (lCount < Length(aText)) and
    (Ord(aText[lCount]) >= $D800) and (Ord(aText[lCount]) <= $DBFF) and
    (Ord(aText[lCount + 1]) >= $DC00) and (Ord(aText[lCount + 1]) <= $DFFF) then
    Dec(lCount);
  Result := Copy(aText, 1, lCount);
end;

function EvidenceGapThresholdMs(const aIntervalMs: Cardinal; const aProcess: Boolean): Double;
begin
  if aProcess then
    Result := Double(aIntervalMs) * 2 + 1000
  else
    Result := Double(aIntervalMs) * 3;
end;

function FindMeasurement(const aSample: TMachineOverviewProviderSample; const aName: string;
  out aValue: TMachineOverviewMeasurement): Boolean;
var
  lValue: TMachineOverviewMeasurement;
begin
  for lValue in aSample.Measurements do
    if lValue.Name = aName then
    begin
      aValue := lValue;
      Exit(lValue.Available and not IsNan(lValue.Value) and not IsInfinite(lValue.Value));
    end;
  aValue := Default(TMachineOverviewMeasurement);
  Result := False;
end;

function OptionalMeasurement(const aSample: TMachineOverviewProviderSample;
  const aName: string): TMachineOverviewOptionalDouble;
var
  lValue: TMachineOverviewMeasurement;
begin
  Result := Default(TMachineOverviewOptionalDouble);
  Result.Available := FindMeasurement(aSample, aName, lValue) and (lValue.Value >= 0) and (lValue.Value <= 100);
  if Result.Available then
    Result.Value := lValue.Value;
end;

procedure TEvidenceTotal.Add(const aValue: Double; const aWeight: Double; const aAtUtc: TDateTime;
  const aPeakSourceName: string);
begin
  if (aWeight <= 0) or IsNan(aValue) or IsInfinite(aValue) then
    Exit;
  Sum := Sum + aValue * aWeight;
  Weight := Weight + aWeight;
  if not Value.Available or (aValue > Value.Peak) then
  begin
    Value.Peak := aValue;
    Value.PeakAtUtc := aAtUtc;
    Value.PeakSourceName := aPeakSourceName;
  end;
  Value.Available := True;
end;

function TEvidenceTotal.Snapshot: TMachineOverviewEvidenceStatistic;
begin
  Result := Value;
  if Weight > 0 then
    Result.Average := Sum / Weight;
end;

procedure TResourceAccumulator.Add(const aValue: TMachineOverviewResourceContribution;
  const aWeight: Double; const aIo: Boolean; var aTruncated: Boolean);
var
  i, n, lLowest: Integer;
  lScore, lLowestScore: Double;
begin
  n := -1;
  lLowest := 0;
  lLowestScore := MaxDouble;
  for i := 0 to Count - 1 do
  begin
    if (Items[i].ProcessId = aValue.ProcessId) and (Items[i].CreationTime100ns = aValue.CreationTime100ns) then
      n := i;
    lScore := Items[i].PeakValue;
    if aIo then
      lScore := Items[i].TotalBytes;
    if lScore < lLowestScore then
    begin
      lLowest := i;
      lLowestScore := lScore;
    end;
  end;
  if n < 0 then
  begin
    if Count < Length(Items) then
    begin
      n := Count;
      Inc(Count);
    end else begin
      aTruncated := True;
      lScore := aValue.PeakValue;
      if aIo then
        lScore := aValue.AverageValue * aWeight / 1000;
      if lScore <= lLowestScore then
        Exit;
      n := lLowest;
    end;
    Items[n] := aValue;
    Items[n].AverageValue := 0;
    Items[n].TotalBytes := 0;
    Items[n].SampleCount := 0;
    Items[n].FirstValue := aValue.AverageValue;
  end;
  Items[n].AverageValue := Items[n].AverageValue + aValue.AverageValue;
  Items[n].TotalBytes := Items[n].TotalBytes + aValue.AverageValue * aWeight / 1000;
  if aValue.PeakValue > Items[n].PeakValue then
  begin
    Items[n].PeakValue := aValue.PeakValue;
    Items[n].PeakAtUtc := aValue.PeakAtUtc;
  end;
  Items[n].LastValue := aValue.AverageValue;
  Items[n].LastSeenUtc := aValue.LastSeenUtc;
  Inc(Items[n].SampleCount);
end;

function TResourceAccumulator.Snapshot(const aWeight: Double; const aMaximum: Integer;
  const aIo: Boolean): TArray<TMachineOverviewResourceContribution>;
var
  i, j: Integer;
  lItem: TMachineOverviewResourceContribution;
  lScore, lOther: Double;
begin
  SetLength(Result, Count);
  for i := 0 to Count - 1 do
  begin
    Result[i] := Items[i];
    if aIo then
    begin
      if aWeight > 0 then
        Result[i].AverageValue := Items[i].TotalBytes * 1000 / aWeight;
    end else
      Result[i].AverageValue := Items[i].AverageValue / Items[i].SampleCount;
  end;
  for i := 1 to High(Result) do
  begin
    lItem := Result[i];
    lScore := lItem.PeakValue;
    if aIo then
      lScore := lItem.TotalBytes;
    j := i - 1;
    while j >= 0 do
    begin
      lOther := Result[j].PeakValue;
      if aIo then
        lOther := Result[j].TotalBytes;
      if (lOther > lScore) or ((lOther = lScore) and
        ((Result[j].ProcessId < lItem.ProcessId) or ((Result[j].ProcessId = lItem.ProcessId) and
        (Result[j].CreationTime100ns <= lItem.CreationTime100ns)))) then
        Break;
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := lItem;
  end;
  SetLength(Result, Min(aMaximum, Length(Result)));
end;

procedure TEvidencePhaseAccumulator.AddProcess(const aValue: TMachineOverviewProcessContribution;
  const aWeight: Double; var aTruncated: Boolean);
var
  i, n, lLowest: Integer;
begin
  n := -1;
  lLowest := 0;
  for i := 0 to ProcessCount - 1 do
  begin
    if (Processes[i].ProcessId = aValue.ProcessId) and
      (Processes[i].CreationTime100ns = aValue.CreationTime100ns) then
      n := i;
    if Processes[i].AverageCpuPercent < Processes[lLowest].AverageCpuPercent then
      lLowest := i;
  end;
  if n < 0 then
  begin
    if ProcessCount < Length(Processes) then
    begin
      n := ProcessCount;
      Inc(ProcessCount);
    end else begin
      n := lLowest;
      aTruncated := True;
      if aValue.AverageCpuPercent * aWeight <= Processes[n].AverageCpuPercent then
        Exit;
    end;
    Processes[n] := aValue;
    Processes[n].AverageCpuPercent := 0;
    Processes[n].SampleCount := 0;
  end;
  Processes[n].AverageCpuPercent := Processes[n].AverageCpuPercent + aValue.AverageCpuPercent * aWeight;
  if aValue.PeakCpuPercent > Processes[n].PeakCpuPercent then
  begin
    Processes[n].PeakCpuPercent := aValue.PeakCpuPercent;
    Processes[n].PeakAtUtc := aValue.PeakAtUtc;
  end;
  Processes[n].LastSeenUtc := aValue.LastSeenUtc;
  Inc(Processes[n].SampleCount);
end;

procedure TEvidencePhaseAccumulator.AddApplication(const aValue: TMachineOverviewApplicationContribution;
  const aWeight: Double; var aTruncated: Boolean);
var
  i, n, lLowest: Integer;
begin
  n := -1;
  lLowest := 0;
  for i := 0 to ApplicationCount - 1 do
  begin
    if SameText(Applications[i].DisplayName, aValue.DisplayName) then
      n := i;
    if Applications[i].AverageCpuPercent < Applications[lLowest].AverageCpuPercent then
      lLowest := i;
  end;
  if n < 0 then
  begin
    if ApplicationCount < Length(Applications) then
    begin
      n := ApplicationCount;
      Inc(ApplicationCount);
    end else begin
      n := lLowest;
      aTruncated := True;
      if aValue.AverageCpuPercent * aWeight <= Applications[n].AverageCpuPercent then
        Exit;
    end;
    Applications[n] := aValue;
    Applications[n].AverageCpuPercent := 0;
  end;
  Applications[n].AverageCpuPercent := Applications[n].AverageCpuPercent + aValue.AverageCpuPercent * aWeight;
  Applications[n].ProcessCount := Max(Applications[n].ProcessCount, aValue.ProcessCount);
  if aValue.PeakCpuPercent > Applications[n].PeakCpuPercent then
  begin
    Applications[n].PeakCpuPercent := aValue.PeakCpuPercent;
    Applications[n].PeakAtUtc := aValue.PeakAtUtc;
  end;
end;

procedure TEvidencePhaseAccumulator.Add(const aSample: TEvidenceSample; var aTruncated: Boolean;
  const aRam, aIo: Boolean);
var
  i: Integer;
begin
  if not aSample.Available then
    Exit;
  if aSample.IsDisk then
  begin
    if not (aSample.DiskActive.Available or aSample.DiskLatency.Available or
      aSample.DiskQueue.Available or aSample.DiskThroughput.Available) then
      Exit;
    if not HasDisk then
    begin
      HasDisk := True;
      DiskIdentity := aSample.DiskIdentity;
      Value.DiskName := aSample.DiskName;
    end else if DiskIdentity <> aSample.DiskIdentity then
      Value.DiskName := rsEvidenceMultipleDisks;
    if aSample.DiskActive.Available then
      DiskActive.Add(aSample.DiskActive.Value, 1, aSample.AtUtc, aSample.DiskName);
    if aSample.DiskLatency.Available then
      DiskLatency.Add(aSample.DiskLatency.Value, 1, aSample.AtUtc, aSample.DiskName);
    if aSample.DiskQueue.Available then
      DiskQueue.Add(aSample.DiskQueue.Value, 1, aSample.AtUtc, aSample.DiskName);
    if aSample.DiskThroughput.Available then
      DiskThroughput.Add(aSample.DiskThroughput.Value, 1, aSample.AtUtc, aSample.DiskName);
    Exit;
  end;
  if aSample.IsProcess then
  begin
    if aSample.IntervalMs = 0 then
      Exit;
    Inc(Value.ProcessSampleCount);
    ProcessWeight := ProcessWeight + aSample.IntervalMs;
    if aSample.Cpu.Available then
      Measured.Add(aSample.Cpu.Value, aSample.IntervalMs, aSample.AtUtc);
    if aSample.MeasuredIo.Available then
      MeasuredIo.Add(aSample.MeasuredIo.Value, aSample.IntervalMs, aSample.AtUtc);
    if aRam then
      for i := 0 to High(aSample.RamProcesses) do
        Ram.Add(aSample.RamProcesses[i], aSample.IntervalMs, False, aTruncated);
    if aIo then
      for i := 0 to High(aSample.IoProcesses) do
        Io.Add(aSample.IoProcesses[i], aSample.IntervalMs, True, aTruncated);
    if aSample.Residual.Available then
      Residual.Add(aSample.Residual.Value, aSample.IntervalMs, aSample.AtUtc);
    for i := 0 to aSample.ProcessCount - 1 do
      AddProcess(aSample.Processes[i], aSample.IntervalMs, aTruncated);
    for i := 0 to aSample.ApplicationCount - 1 do
      AddApplication(aSample.Applications[i], aSample.IntervalMs, aTruncated);
  end else begin
    if aSample.PhysicalUsed.Available then
      PhysicalUsed.Add(aSample.PhysicalUsed.Value, 1, aSample.AtUtc);
    if aSample.Commit.Available then
      Commit.Add(aSample.Commit.Value, 1, aSample.AtUtc);
    if aSample.Paging.Available then
      Paging.Add(aSample.Paging.Value, 1, aSample.AtUtc);
    if aSample.Cpu.Available then
    begin
      Inc(Value.SystemSampleCount);
      Cpu.Add(aSample.Cpu.Value, 1, aSample.AtUtc);
    end;
    if aSample.Dpc.Available then
      Dpc.Add(aSample.Dpc.Value, 1, aSample.AtUtc);
    if aSample.Interrupt.Available then
      Interrupt.Add(aSample.Interrupt.Value, 1, aSample.AtUtc);
  end;
end;

function ProcessBefore(const aLeft, aRight: TMachineOverviewProcessContribution): Boolean;
begin
  Result := (aLeft.AverageCpuPercent > aRight.AverageCpuPercent) or
    ((aLeft.AverageCpuPercent = aRight.AverageCpuPercent) and
    ((aLeft.ProcessId < aRight.ProcessId) or ((aLeft.ProcessId = aRight.ProcessId) and
    (aLeft.CreationTime100ns < aRight.CreationTime100ns))));
end;

function TEvidencePhaseAccumulator.Snapshot(const aEndUtc: TDateTime;
  const aProcessMs, aSystemMs: Cardinal): TMachineOverviewEvidencePhase;
var
  i, j, lMaximum: Integer;
  lProcess: TMachineOverviewProcessContribution;
  lApplication: TMachineOverviewApplicationContribution;
  lDuration: Double;
begin
  Result := Value;
  Result.EndUtc := Max(Result.StartUtc, aEndUtc);
  lDuration := Max(0, (Result.EndUtc - Result.StartUtc) * cDayMs);
  Result.ExpectedProcessSampleCount := Round(Min(Double(MaxInt), Int((lDuration + 0.01) / aProcessMs)));
  Result.ExpectedSystemSampleCount := Round(Min(Double(MaxInt), Int((lDuration + 0.01) / aSystemMs)));
  Result.SystemCpu := Cpu.Snapshot;
  Result.Dpc := Dpc.Snapshot;
  Result.Interrupt := Interrupt.Snapshot;
  Result.MeasuredProcessCpu := Measured.Snapshot;
  Result.UnattributedCpu := Residual.Snapshot;
  SetLength(Result.Processes, ProcessCount);
  for i := 0 to ProcessCount - 1 do
  begin
    Result.Processes[i] := Processes[i];
    if ProcessWeight > 0 then
      Result.Processes[i].AverageCpuPercent := Processes[i].AverageCpuPercent / ProcessWeight;
  end;
  // Our small bounded arrays use insertion sort only when publishing a snapshot.
  for i := 1 to High(Result.Processes) do
  begin
    lProcess := Result.Processes[i];
    j := i - 1;
    while (j >= 0) and ProcessBefore(lProcess, Result.Processes[j]) do
    begin
      Result.Processes[j + 1] := Result.Processes[j];
      Dec(j);
    end;
    Result.Processes[j + 1] := lProcess;
  end;
  lMaximum := 5;
  if Value.Kind = TMachineOverviewEvidencePhaseKind.During then
    lMaximum := 10;
  SetLength(Result.Processes, Min(lMaximum, Length(Result.Processes)));
  Result.RamProcesses := Ram.Snapshot(ProcessWeight, lMaximum, False);
  Result.IoProcesses := Io.Snapshot(ProcessWeight, lMaximum, True);
  Result.PhysicalUsed := PhysicalUsed.Snapshot;
  Result.Commit := Commit.Snapshot;
  Result.Paging := Paging.Snapshot;
  Result.DiskActive := DiskActive.Snapshot;
  Result.DiskLatency := DiskLatency.Snapshot;
  Result.DiskQueue := DiskQueue.Snapshot;
  Result.DiskThroughput := DiskThroughput.Snapshot;
  Result.MeasuredProcessIo := MeasuredIo.Snapshot;
  SetLength(Result.Applications, ApplicationCount);
  for i := 0 to ApplicationCount - 1 do
  begin
    Result.Applications[i] := Applications[i];
    if ProcessWeight > 0 then
      Result.Applications[i].AverageCpuPercent := Applications[i].AverageCpuPercent / ProcessWeight;
  end;
  for i := 1 to High(Result.Applications) do
  begin
    lApplication := Result.Applications[i];
    j := i - 1;
    while (j >= 0) and (lApplication.AverageCpuPercent > Result.Applications[j].AverageCpuPercent) do
    begin
      Result.Applications[j + 1] := Result.Applications[j];
      Dec(j);
    end;
    Result.Applications[j + 1] := lApplication;
  end;
  SetLength(Result.Applications, Min(5, Length(Result.Applications)));
end;

constructor TEvidenceIncident.Create(const aIncident: TMachineOverviewIncident;
  const aConfig: TMachineOverviewEvidenceConfig);
var
  lKind: TMachineOverviewEvidencePhaseKind;
begin
  inherited Create;
  Headline := aIncident;
  // Context belongs to the detector until S4; our recorder never duplicates it.
  Headline.Evidence := Default(TMachineOverviewIncidentEvidence);
  Config := aConfig;
  Value.State := TMachineOverviewEvidenceState.Collecting;
  case aIncident.Category of
    TMachineOverviewIncidentCategory.MemoryPressure: Value.Resources := [TMachineOverviewResourceKind.Ram];
    TMachineOverviewIncidentCategory.DiskPressure: Value.Resources := [TMachineOverviewResourceKind.Io];
    TMachineOverviewIncidentCategory.UserMarked:
      Value.Resources := [TMachineOverviewResourceKind.Ram, TMachineOverviewResourceKind.Io];
  else
    Value.Resources := [];
  end;
  Value.ProcessIntervalMs := Config.ProcessIntervalMs;
  Value.SystemIntervalMs := Config.SystemIntervalMs;
  LatestUtc := aIncident.StartedAtUtc;
  for lKind := Low(lKind) to High(lKind) do
    Phases[lKind].Value.Kind := lKind;
  Phases[TMachineOverviewEvidencePhaseKind.Before].Value.StartUtc :=
    aIncident.StartedAtUtc - Config.PreWindowMs / cDayMs;
  Phases[TMachineOverviewEvidencePhaseKind.During].Value.StartUtc := aIncident.StartedAtUtc;
  Phases[TMachineOverviewEvidencePhaseKind.After].Value.StartUtc := aIncident.EndedAtUtc;
end;

procedure TEvidenceIncident.AddGap(const aStart, aEnd: TDateTime;
  const aReason: TMachineOverviewEvidenceGapReason);
var
  i, n: Integer;
  lStart, lEnd, lLimit: TDateTime;
begin
  lStart := Max(aStart, Phases[TMachineOverviewEvidencePhaseKind.Before].Value.StartUtc);
  lLimit := LatestUtc;
  if Headline.EndedAtUtc > 0 then
    lLimit := Headline.EndedAtUtc + Config.PostWindowMs / cDayMs;
  lEnd := Min(aEnd, lLimit);
  if lEnd < lStart then
    Exit;
  n := Length(Value.Gaps);
  i := 0;
  while i < n do
  begin
    if (Value.Gaps[i].Reason = aReason) and
      (lStart <= Value.Gaps[i].EndUtc + 0.5 / cDayMs) and
      (lEnd >= Value.Gaps[i].StartUtc - 0.5 / cDayMs) then
    begin
      lStart := Min(lStart, Value.Gaps[i].StartUtc);
      lEnd := Max(lEnd, Value.Gaps[i].EndUtc);
      Delete(Value.Gaps, i, 1);
      Dec(n);
      i := 0;
    end else begin
      Inc(i);
    end;
  end;
  if n = 16 then
  begin
    Inc(Value.GapsOmitted);
    Exit;
  end;
  SetLength(Value.Gaps, n + 1);
  Value.Gaps[n].StartUtc := lStart;
  Value.Gaps[n].EndUtc := lEnd;
  Value.Gaps[n].Reason := aReason;
end;

procedure TEvidenceIncident.Observe(const aSample: TEvidenceSample);
var
  lKind: TMachineOverviewEvidencePhaseKind;
  lExpected: Cardinal;
  lStream: Integer;
begin
  if aSample.IsDisk and not (TMachineOverviewResourceKind.Io in Value.Resources) then
    Exit;
  if aSample.AtUtc < Phases[TMachineOverviewEvidencePhaseKind.Before].Value.StartUtc then
    Exit;
  if (Headline.EndedAtUtc > 0) and
    (aSample.AtUtc > Headline.EndedAtUtc + Config.PostWindowMs / cDayMs + 0.5 / cDayMs) then
    Exit;
  // Our window guards precede every incident metadata or accumulator update.
  lStream := Ord(aSample.IsProcess);
  if aSample.IsDisk then
    lStream := 2;
  LatestUtc := Max(LatestUtc, aSample.AtUtc);
  lKind := TMachineOverviewEvidencePhaseKind.Before;
  if aSample.AtUtc >= Headline.StartedAtUtc then
    lKind := TMachineOverviewEvidencePhaseKind.During;
  if (Headline.EndedAtUtc > 0) and (aSample.AtUtc >= Headline.EndedAtUtc) then
    lKind := TMachineOverviewEvidencePhaseKind.After;
  lExpected := Config.SystemIntervalMs;
  if aSample.IsProcess then
  begin
    lExpected := Config.ProcessIntervalMs;
  end;
  if (aSample.PreviousUtc > 0) and
    (Round((aSample.AtUtc - aSample.PreviousUtc) * cDayMs) >
      EvidenceGapThresholdMs(lExpected, aSample.IsProcess)) then
  begin
    if aSample.IsProcess then
      AddGap(aSample.PreviousUtc + lExpected / cDayMs, aSample.AtUtc,
        TMachineOverviewEvidenceGapReason.ProcessSamplesMissing)
    else
      AddGap(aSample.PreviousUtc + lExpected / cDayMs, aSample.AtUtc,
        TMachineOverviewEvidenceGapReason.SystemSamplesMissing);
  end;
  if not aSample.Available or (not aSample.IsDisk and not aSample.Cpu.Available) then
    AddGap(aSample.AtUtc - lExpected / cDayMs, aSample.AtUtc,
      TMachineOverviewEvidenceGapReason.ProviderUnavailable);
  Value.LogicalProcessorCount := Max(Value.LogicalProcessorCount, aSample.LogicalProcessors);
  Value.InaccessibleProcessCountMax := Max(Value.InaccessibleProcessCountMax, aSample.Inaccessible);
  Value.Truncated := Value.Truncated or aSample.Truncated or
    ((TMachineOverviewResourceKind.Ram in Value.Resources) and aSample.RamTruncated) or
    ((TMachineOverviewResourceKind.Io in Value.Resources) and aSample.IoTruncated);
  if HasPending[lStream] then
  begin
    lKind := TMachineOverviewEvidencePhaseKind.Before;
    if Pending[lStream].AtUtc >= Headline.StartedAtUtc then
      lKind := TMachineOverviewEvidencePhaseKind.During;
    if (Headline.EndedAtUtc > 0) and (Pending[lStream].AtUtc >= Headline.EndedAtUtc) then
      lKind := TMachineOverviewEvidencePhaseKind.After;
    Phases[lKind].Add(Pending[lStream], Value.Truncated,
      TMachineOverviewResourceKind.Ram in Value.Resources, TMachineOverviewResourceKind.Io in Value.Resources);
  end;
  Pending[lStream] := aSample;
  HasPending[lStream] := True;
end;

function TEvidenceIncident.Snapshot(const aState: TMachineOverviewEvidenceState): TMachineOverviewIncidentEvidence;
var
  lEnd: TDateTime;
  lPhases: TEvidencePhaseAccumulators;
  lKind: TMachineOverviewEvidencePhaseKind;
  lStream: Integer;
begin
  lPhases := Phases;
  for lStream := 0 to 2 do
    if HasPending[lStream] then
    begin
      lKind := TMachineOverviewEvidencePhaseKind.Before;
      if Pending[lStream].AtUtc >= Headline.StartedAtUtc then
        lKind := TMachineOverviewEvidencePhaseKind.During;
      if (Headline.EndedAtUtc > 0) and (Pending[lStream].AtUtc >= Headline.EndedAtUtc) then
        lKind := TMachineOverviewEvidencePhaseKind.After;
      lPhases[lKind].Add(Pending[lStream], Value.Truncated,
      TMachineOverviewResourceKind.Ram in Value.Resources, TMachineOverviewResourceKind.Io in Value.Resources);
    end;
  if Value.Truncated then
    AddGap(Headline.StartedAtUtc, LatestUtc, TMachineOverviewEvidenceGapReason.Truncated);
  Result := Value;
  Result.Gaps := Copy(Value.Gaps);
  Result.State := aState;
  Result.Phases[TMachineOverviewEvidencePhaseKind.Before] :=
    lPhases[TMachineOverviewEvidencePhaseKind.Before].Snapshot(Headline.StartedAtUtc,
      Config.ProcessIntervalMs, Config.SystemIntervalMs);
  lEnd := Headline.EndedAtUtc;
  if lEnd = 0 then
    lEnd := LatestUtc;
  Result.Phases[TMachineOverviewEvidencePhaseKind.During] :=
    lPhases[TMachineOverviewEvidencePhaseKind.During].Snapshot(lEnd, Config.ProcessIntervalMs, Config.SystemIntervalMs);
  lEnd := Headline.EndedAtUtc;
  if lEnd > 0 then
    lEnd := Min(LatestUtc, lEnd + Config.PostWindowMs / cDayMs);
  Result.Phases[TMachineOverviewEvidencePhaseKind.After] :=
    lPhases[TMachineOverviewEvidencePhaseKind.After].Snapshot(lEnd, Config.ProcessIntervalMs, Config.SystemIntervalMs);
  Result.DiskName := '';
  for lKind := Low(lKind) to High(lKind) do
  begin
    if TMachineOverviewResourceKind.Io in Result.Resources then
    begin
      if not Result.Phases[lKind].DiskName.IsEmpty then
        if Result.DiskName.IsEmpty then
          Result.DiskName := Result.Phases[lKind].DiskName
        else if Result.DiskName <> Result.Phases[lKind].DiskName then
          Result.DiskName := rsEvidenceMultipleDisks;
    end else
      Result.Phases[lKind].DiskName := '';
    if not (TMachineOverviewResourceKind.Ram in Result.Resources) then
    begin
      Result.Phases[lKind].RamProcesses := nil;
      Result.Phases[lKind].PhysicalUsed := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].Commit := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].Paging := Default(TMachineOverviewEvidenceStatistic);
    end;
    if not (TMachineOverviewResourceKind.Io in Result.Resources) then
    begin
      Result.Phases[lKind].IoProcesses := nil;
      Result.Phases[lKind].DiskActive := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].DiskLatency := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].DiskQueue := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].DiskThroughput := Default(TMachineOverviewEvidenceStatistic);
      Result.Phases[lKind].MeasuredProcessIo := Default(TMachineOverviewEvidenceStatistic);
    end;
  end;
end;

constructor TEvidenceRecorderState.Create(const aConfig: TMachineOverviewEvidenceConfig);
begin
  inherited Create;
  Config := aConfig;
  if (Config.ProcessIntervalMs = 0) or (Config.SystemIntervalMs = 0) then
    raise EArgumentException.Create('Evidence sampling intervals must be positive');
  Entries := TObjectList<TEvidenceIncident>.Create;
  Ready := TList<TMachineOverviewIncidentChange>.Create;
  FinalizedKeys := THashSet<string>.Create(cMaximumFinalizedKeys, TFastCaseAwareComparer.Ordinal);
  FinalizedOrder := TQueue<string>.Create;
end;

destructor TEvidenceRecorderState.Destroy;
begin
  FinalizedOrder.Free;
  FinalizedKeys.Free;
  Ready.Free;
  Entries.Free;
  inherited;
end;

function ResourceMeasurement(const aSample: TMachineOverviewProviderSample;
  const aName: string; const aDivisor: Double = 1; const aEntity: string = ''): TMachineOverviewOptionalDouble;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  Result := Default(TMachineOverviewOptionalDouble);
  for lMeasurement in aSample.Measurements do
    if (lMeasurement.Name = aName) and ((aEntity = '') or (lMeasurement.EntityId = aEntity)) then
    begin
      Result.Available := lMeasurement.Available and not IsNan(lMeasurement.Value) and
        not IsInfinite(lMeasurement.Value) and (lMeasurement.Value >= 0) and (lMeasurement.Value <= 1E18);
      if Result.Available then
        Result.Value := lMeasurement.Value / aDivisor;
      Exit;
    end;
end;

function CompactResourceProcesses(const aSample: TMachineOverviewProviderSample; const aPrefix: string;
  var aTruncated: Boolean): TArray<TMachineOverviewResourceContribution>;
var
  i, n, lColon: Integer;
  lMeasurement: TMachineOverviewMeasurement;
  lItem: TMachineOverviewResourceContribution;
  lPid: Cardinal;
  lCreation: UInt64;
begin
  Result := nil;
  for i := 1 to 10 do
    if FindMeasurement(aSample, aPrefix + IntToStr(i), lMeasurement) and
      (lMeasurement.Value >= 0) and (lMeasurement.Value <= 1E18) then
    begin
      lItem := Default(TMachineOverviewResourceContribution);
      lColon := Pos(':', lMeasurement.EntityId);
      if (lColon < 2) or not TryStrToUInt(Copy(lMeasurement.EntityId, 1, lColon - 1), lPid) or
        not TryStrToUInt64(Copy(lMeasurement.EntityId, lColon + 1), lCreation) then
        Continue;
      lItem.ProcessId := lPid;
      lItem.CreationTime100ns := lCreation;
      lItem.DisplayName := EvidenceTextPrefix(lMeasurement.DisplayText, 256);
      lItem.ImagePath := EvidenceTextPrefix(lMeasurement.DetailText, 1024);
      lItem.PathStatus := EvidenceTextPrefix(lMeasurement.StatusText, 64);
      aTruncated := aTruncated or (Length(lMeasurement.DisplayText) > 256) or
        (Length(lMeasurement.DetailText) > 1024) or (Length(lMeasurement.StatusText) > 64);
      lItem.AverageValue := lMeasurement.Value;
      lItem.PeakValue := lMeasurement.Value;
      lItem.FirstValue := lMeasurement.Value;
      lItem.LastValue := lMeasurement.Value;
      lItem.PeakAtUtc := aSample.State.CapturedAtUtc;
      lItem.LastSeenUtc := aSample.State.CapturedAtUtc;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := lItem;
    end;
end;

function TEvidenceRecorderState.Compact(const aSample: TMachineOverviewProviderSample): TEvidenceSample;
var
  i, n, lColon: Integer;
  lPid: Cardinal;
  lCreation: UInt64;
  lMeasurement, lCount: TMachineOverviewMeasurement;
  lSample: TEvidenceSample;
  lTotal: TEvidenceTotal;
begin
  Result := Default(TEvidenceSample);
  Result.AtUtc := aSample.State.CapturedAtUtc;
  Result.IsProcess := aSample.State.ProviderId = 'processes';
  Result.IsDisk := aSample.State.ProviderId = 'disks';
  Result.Available := aSample.State.Status = TMachineOverviewProviderStatus.Available;
  if Result.IsDisk then
  begin
    Result.PreviousUtc := LastDiskUtc;
    LastDiskUtc := Result.AtUtc;
    if FindMeasurement(aSample, 'disk_worst', lMeasurement) then
    begin
      Result.DiskIdentity := EvidenceTextPrefix(lMeasurement.EntityId, 256);
      Result.DiskName := EvidenceTextPrefix(lMeasurement.DisplayText, 256);
      if Result.DiskName.IsEmpty then
        Result.DiskName := Result.DiskIdentity;
      if Result.DiskName.IsEmpty then
        Result.DiskName := rsEvidenceUnknownDisk;
      if Result.DiskIdentity.IsEmpty then
        Result.DiskIdentity := Result.DiskName;
      Result.Truncated := (Length(lMeasurement.DisplayText) > 256) or (Length(lMeasurement.EntityId) > 256);
      Result.DiskActive := ResourceMeasurement(aSample, 'disk_active_percent', 1, lMeasurement.EntityId);
      Result.DiskLatency := ResourceMeasurement(aSample, 'disk_latency_ms', 1, lMeasurement.EntityId);
      Result.DiskQueue := ResourceMeasurement(aSample, 'disk_queue_length', 1, lMeasurement.EntityId);
      Result.DiskThroughput := ResourceMeasurement(aSample, 'disk_read_mb_per_sec', 1, lMeasurement.EntityId);
      Result.Paging := ResourceMeasurement(aSample, 'disk_write_mb_per_sec', 1, lMeasurement.EntityId);
      Result.DiskThroughput.Available := Result.DiskThroughput.Available and Result.Paging.Available;
      Result.DiskThroughput.Value := Result.DiskThroughput.Value + Result.Paging.Value;
      Result.Paging := Default(TMachineOverviewOptionalDouble);
    end;
    Exit;
  end;
  if not Result.IsProcess then
  begin
    Result.PhysicalUsed := OptionalMeasurement(aSample, 'physical_used_percent');
    Result.Commit := OptionalMeasurement(aSample, 'commit_percent');
    Result.Paging := ResourceMeasurement(aSample, 'paging_bytes_per_sec', 1048576);
    Result.PreviousUtc := LastSystemUtc;
    LastSystemUtc := Result.AtUtc;
    Result.Cpu := OptionalMeasurement(aSample, 'cpu_total_percent');
    Result.Dpc := OptionalMeasurement(aSample, 'dpc_percent');
    Result.Interrupt := OptionalMeasurement(aSample, 'interrupt_percent');
    Exit;
  end;
  Result.PreviousUtc := LastProcessUtc;
  LastProcessUtc := Result.AtUtc;
  if FindMeasurement(aSample, 'process_cpu_interval_ms', lMeasurement) and
    (lMeasurement.Value >= 0) and (lMeasurement.Value <= High(Cardinal)) then
    Result.IntervalMs := Round(lMeasurement.Value);
  if FindMeasurement(aSample, 'logical_processor_count', lMeasurement) and
    (lMeasurement.Value > 0) and (lMeasurement.Value <= 65536) then
    Result.LogicalProcessors := Round(lMeasurement.Value);
  if FindMeasurement(aSample, 'process_access_denied_count', lMeasurement) then
    Result.Inaccessible := Round(EnsureRange(lMeasurement.Value, 0.0, MaxInt * 1.0));
  Result.Cpu := OptionalMeasurement(aSample, 'process_cpu_measured_total_percent');
  Result.RamProcesses := CompactResourceProcesses(aSample, 'process_ram_process:', Result.RamTruncated);
  Result.IoProcesses := CompactResourceProcesses(aSample, 'process_io_process:', Result.IoTruncated);
  Result.MeasuredIo := ResourceMeasurement(aSample, 'process_io_measured_total_bytes_per_second', 1048576);
  SetLength(Result.Processes, 10);
  SetLength(Result.Applications, 5);
  for i := 1 to 10 do
    if FindMeasurement(aSample, 'process_cpu_process:' + IntToStr(i), lMeasurement) and
      (lMeasurement.Value > 0) and (lMeasurement.Value <= 100) then
    begin
      lColon := Pos(':', lMeasurement.EntityId);
      if (lColon < 2) or not TryStrToUInt(Copy(lMeasurement.EntityId, 1, lColon - 1), lPid) or
        not TryStrToUInt64(Copy(lMeasurement.EntityId, lColon + 1), lCreation) then
        Continue;
      n := Result.ProcessCount;
      Result.Processes[n].ProcessId := lPid;
      Result.Processes[n].CreationTime100ns := lCreation;
      Result.Processes[n].DisplayName := EvidenceTextPrefix(lMeasurement.DisplayText, 256);
      Result.Processes[n].ImagePath := EvidenceTextPrefix(lMeasurement.DetailText, 1024);
      Result.Processes[n].PathStatus := EvidenceTextPrefix(lMeasurement.StatusText, 64);
      Result.Truncated := Result.Truncated or (Length(lMeasurement.DisplayText) > 256) or
        (Length(lMeasurement.DetailText) > 1024) or (Length(lMeasurement.StatusText) > 64);
      Result.Processes[n].AverageCpuPercent := lMeasurement.Value;
      Result.Processes[n].PeakCpuPercent := lMeasurement.Value;
      Result.Processes[n].PeakAtUtc := Result.AtUtc;
      Result.Processes[n].LastSeenUtc := Result.AtUtc;
      Inc(Result.ProcessCount);
    end;
  for i := 1 to 5 do
    if FindMeasurement(aSample, 'process_cpu_rank:' + IntToStr(i), lMeasurement) and
      (lMeasurement.Value > 0) and (lMeasurement.Value <= 100) then
    begin
      n := Result.ApplicationCount;
      Result.Applications[n].DisplayName := EvidenceTextPrefix(lMeasurement.DisplayText, 256);
      Result.Applications[n].AverageCpuPercent := lMeasurement.Value;
      Result.Applications[n].PeakCpuPercent := lMeasurement.Value;
      Result.Applications[n].PeakAtUtc := Result.AtUtc;
      if FindMeasurement(aSample, 'process_cpu_pids:' + IntToStr(i), lCount) then
        Result.Applications[n].ProcessCount := Round(EnsureRange(lCount.Value, 0.0, MaxInt * 1.0));
      Inc(Result.ApplicationCount);
    end;
  SetLength(Result.Processes, Result.ProcessCount);
  SetLength(Result.Applications, Result.ApplicationCount);
  lTotal := Default(TEvidenceTotal);
  for i := 0 to RingCount - 1 do
  begin
    lSample := Ring[(RingFirst + i) mod Length(Ring)];
    if not lSample.IsProcess and not lSample.IsDisk and lSample.Available and lSample.Cpu.Available and
      (lSample.AtUtc > Result.AtUtc - Result.IntervalMs / cDayMs) and (lSample.AtUtc <= Result.AtUtc) then
      lTotal.Add(lSample.Cpu.Value, 1, lSample.AtUtc);
  end;
  Result.Residual.Available := lTotal.Value.Available and Result.Cpu.Available;
  if Result.Residual.Available then
    Result.Residual.Value := Max(0, lTotal.Snapshot.Average - Result.Cpu.Value);

end;

procedure TEvidenceRecorderState.Replay(const aEntry: TEvidenceIncident);
var
  i: Integer;
  lFirstProcess, lFirstSystem, lStart: TDateTime;
  lSample: TEvidenceSample;
begin
  lFirstProcess := 0;
  lFirstSystem := 0;
  for i := 0 to RingCount - 1 do
  begin
    lSample := Ring[(RingFirst + i) mod Length(Ring)];
    if lSample.IsProcess and (lFirstProcess = 0) then
      lFirstProcess := lSample.AtUtc;
    if not lSample.IsProcess and not lSample.IsDisk and (lFirstSystem = 0) then
      lFirstSystem := lSample.AtUtc;
    // An Ended change without a tracked start has no measured During accumulator.
    if (aEntry.Headline.EndedAtUtc <= 0) or (lSample.AtUtc < aEntry.Headline.StartedAtUtc) or
      (lSample.AtUtc >= aEntry.Headline.EndedAtUtc) then
      aEntry.Observe(lSample);
  end;
  lStart := aEntry.Phases[TMachineOverviewEvidencePhaseKind.Before].Value.StartUtc;
  if lFirstProcess = 0 then
    lFirstProcess := aEntry.Headline.StartedAtUtc;
  if lFirstSystem = 0 then
    lFirstSystem := aEntry.Headline.StartedAtUtc;
  if Max(lFirstProcess, lFirstSystem) > lStart then
    aEntry.AddGap(lStart, Max(lFirstProcess, lFirstSystem), TMachineOverviewEvidenceGapReason.CollectionStartedLate);
end;

procedure TEvidenceRecorderState.RememberFinalized(const aStableId: string);
begin
  if FinalizedKeys.Contains(aStableId) then
    Exit;
  if FinalizedOrder.Count = cMaximumFinalizedKeys then
    if not FinalizedKeys.Remove(FinalizedOrder.Dequeue) then
      raise EInvalidOpException.Create('Finalized evidence key queue is inconsistent');
  if FinalizedKeys.Add(aStableId) then
    FinalizedOrder.Enqueue(aStableId);
end;

procedure TEvidenceRecorderState.EvictOldest;
var
  i, n, lCount: NativeInt;
  lChange: TMachineOverviewIncidentChange;
begin
  n := 0;
  lCount := Entries.Count;
  for i := 1 to lCount - 1 do
    if Entries[i].Headline.StartedAtUtc < Entries[n].Headline.StartedAtUtc then
      n := i;
  Entries[n].Value.Truncated := True;
  lChange := Default(TMachineOverviewIncidentChange);
  lChange.Kind := TMachineOverviewIncidentChangeKind.Updated;
  lChange.Incident := Entries[n].Headline;
  lChange.Incident.Evidence := Entries[n].Snapshot(TMachineOverviewEvidenceState.Partial);
  lChange.HasEvidenceUpdate := True;
  RememberFinalized(lChange.Incident.StableId);
  Ready.Add(lChange);
  Entries.Delete(n);
end;

class function TMachineOverviewEvidenceConfig.Defaults: TMachineOverviewEvidenceConfig;
begin
  Result := Default(TMachineOverviewEvidenceConfig);
  Result.PreWindowMs := 300000;
  Result.PostWindowMs := 600000;
  Result.RingRetentionMs := 360000;
  Result.ProcessIntervalMs := 5000;
  Result.SystemIntervalMs := 1000;
end;

constructor TMachineOverviewEvidenceRecorder.Create(const aConfig: TMachineOverviewEvidenceConfig);
begin
  inherited Create;
  fState := TEvidenceRecorderState.Create(aConfig);
end;

destructor TMachineOverviewEvidenceRecorder.Destroy;
begin
  fState.Free;
  inherited;
end;

procedure TMachineOverviewEvidenceRecorder.ObserveSample(const aSample: TMachineOverviewProviderSample);
var
  lState: TEvidenceRecorderState;
  lSample: TEvidenceSample;
  lEntry: TEvidenceIncident;
begin
  if (aSample.State.ProviderId <> 'processes') and (aSample.State.ProviderId <> 'windows-core') and
    (aSample.State.ProviderId <> 'disks') then
    Exit;
  if (aSample.State.CapturedAtUtc <= 0) or IsNan(aSample.State.CapturedAtUtc) or
    IsInfinite(aSample.State.CapturedAtUtc) then
    Exit;
  lState := (fState as TEvidenceRecorderState);
  // Duplicate or backwards timestamps cannot add CPU twice or reorder our ring.
  if ((aSample.State.ProviderId = 'processes') and (aSample.State.CapturedAtUtc <= lState.LastProcessUtc)) or
    ((aSample.State.ProviderId = 'windows-core') and (aSample.State.CapturedAtUtc <= lState.LastSystemUtc)) or
    ((aSample.State.ProviderId = 'disks') and (aSample.State.CapturedAtUtc <= lState.LastDiskUtc)) then
    Exit;
  lSample := lState.Compact(aSample);
  lState.LatestUtc := Max(lState.LatestUtc, lSample.AtUtc);
  while (lState.RingCount > 0) and ((lState.RingCount = Length(lState.Ring)) or
    ((lState.LatestUtc - lState.Ring[lState.RingFirst].AtUtc) * cDayMs > lState.Config.RingRetentionMs)) do
  begin
    lState.Ring[lState.RingFirst] := Default(TEvidenceSample);
    lState.RingFirst := (lState.RingFirst + 1) mod Length(lState.Ring);
    Dec(lState.RingCount);
  end;
  lState.Ring[(lState.RingFirst + lState.RingCount) mod Length(lState.Ring)] := lSample;
  Inc(lState.RingCount);
  for lEntry in lState.Entries do
    lEntry.Observe(lSample);
end;

procedure TMachineOverviewEvidenceRecorder.Apply(var aChange: TMachineOverviewIncidentChange);
var
  lState: TEvidenceRecorderState;
  lEntry, lFound: TEvidenceIncident;
  lChange: TMachineOverviewIncidentChange;
begin
  lChange := aChange;
  lChange.HasEvidenceUpdate := False;
  lChange.Incident.Evidence := Default(TMachineOverviewIncidentEvidence);
  aChange := lChange;
  lState := (fState as TEvidenceRecorderState);
  if lState.FinalizedKeys.Contains(lChange.Incident.StableId) then
    Exit;
  lFound := nil;
  for lEntry in lState.Entries do
    if lEntry.Headline.StableId = lChange.Incident.StableId then
      lFound := lEntry;
  if not Assigned(lFound) then
  begin
    if lChange.Kind = TMachineOverviewIncidentChangeKind.Updated then
      Exit;
    // Only user-marked incidents first arrive as Ended. An unknown automatic
    // terminal change has no samples to emit; retain its key and preserve stored evidence.
    if (lChange.Kind = TMachineOverviewIncidentChangeKind.Ended) and
      (lChange.Incident.Origin <> TMachineOverviewIncidentOrigin.UserMarked) then
    begin
      lState.RememberFinalized(lChange.Incident.StableId);
      Exit;
    end;
    if lState.Entries.Count = 64 then
    begin
      // Our completion queue is bounded too. A caller must drain it before further admission.
      if lState.Ready.Count = 64 then
      begin
        lFound := TEvidenceIncident.Create(lChange.Incident, lState.Config);
        try
          lFound.Value.Truncated := True;
          lChange.Incident.Evidence := lFound.Snapshot(TMachineOverviewEvidenceState.Partial);
          lChange.HasEvidenceUpdate := True;
          lState.RememberFinalized(lChange.Incident.StableId);
        finally
          lFound.Free;
        end;
        aChange := lChange;
        Exit;
      end;
      lState.EvictOldest;
    end;
    lFound := TEvidenceIncident.Create(lChange.Incident, lState.Config);
    lState.Entries.Add(lFound);
    lState.Replay(lFound);
  end;
  lFound.Headline := lChange.Incident;
  lFound.Headline.Evidence := Default(TMachineOverviewIncidentEvidence);
  if lChange.Kind = TMachineOverviewIncidentChangeKind.Ended then
    lFound.Phases[TMachineOverviewEvidencePhaseKind.After].Value.StartUtc := lChange.Incident.EndedAtUtc;
  lChange.Incident.Evidence := lFound.Snapshot(TMachineOverviewEvidenceState.Collecting);
  lChange.HasEvidenceUpdate := True;
  aChange := lChange;
end;

function TMachineOverviewEvidenceRecorder.TakeCompleted(const aNowUtc: TDateTime): TArray<TMachineOverviewIncidentChange>;
var
  lState: TEvidenceRecorderState;
  lEntry: TEvidenceIncident;
  i, n: NativeInt;
  lProcess: Boolean;
  lLastUtc: TDateTime;
  lInterval: Cardinal;
begin
  lState := (fState as TEvidenceRecorderState);
  Result := lState.Ready.ToArray;
  lState.Ready.Clear;
  for i := lState.Entries.Count - 1 downto 0 do
  begin
    lEntry := lState.Entries[i];
    if (lEntry.Headline.EndedAtUtc <= 0) or
      (aNowUtc + 0.5 / cDayMs < lEntry.Headline.EndedAtUtc + lState.Config.PostWindowMs / cDayMs) then
      Continue;
    lEntry.LatestUtc := lEntry.Headline.EndedAtUtc + lState.Config.PostWindowMs / cDayMs;
    for lProcess := False to True do
    begin
      lLastUtc := lEntry.Headline.StartedAtUtc;
      if lEntry.HasPending[Ord(lProcess)] then
        lLastUtc := Max(lLastUtc, lEntry.Pending[Ord(lProcess)].AtUtc);
      lInterval := lState.Config.SystemIntervalMs;
      if lProcess then
        lInterval := lState.Config.ProcessIntervalMs;
      if Round((lEntry.LatestUtc - lLastUtc) * cDayMs) > EvidenceGapThresholdMs(lInterval, lProcess) then
      begin
        if lProcess then
          lEntry.AddGap(lLastUtc + lInterval / cDayMs, lEntry.LatestUtc,
            TMachineOverviewEvidenceGapReason.ProcessSamplesMissing)
        else
          lEntry.AddGap(lLastUtc + lInterval / cDayMs, lEntry.LatestUtc,
            TMachineOverviewEvidenceGapReason.SystemSamplesMissing);
      end;
    end;
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Kind := TMachineOverviewIncidentChangeKind.Updated;
    Result[n].Incident := lEntry.Headline;
    Result[n].Incident.Evidence := lEntry.Snapshot(TMachineOverviewEvidenceState.Complete);
    Result[n].HasEvidenceUpdate := True;
    lState.RememberFinalized(lEntry.Headline.StableId);
    lState.Entries.Delete(i);
  end;
end;

function TMachineOverviewEvidenceRecorder.TrackedIncidentCount: Integer;
begin
  Result := Integer((fState as TEvidenceRecorderState).Entries.Count); //PALOFF Our admission limit proves Count <= 64.
end;

function EvidenceUtcMs(const aUtc: TDateTime): Int64;
begin
  if aUtc = 0 then
    Exit(0);
  Result := Round((aUtc - UnixDateDelta) * cDayMs);
end;

function EvidenceFromMs(const aValue: Int64): TDateTime;
begin
  if aValue = 0 then
    Exit(0);
  Result := UnixDateDelta + aValue / cDayMs;
end;

procedure JsonInteger(const aObject: TJSONObject; const aKey: string; const aValue: Int64); overload;
begin
  aObject.AddPair(aKey, TJSONNumber.Create(aValue));
end;

procedure JsonInteger(const aObject: TJSONObject; const aKey: string; const aValue: Integer); overload;
begin
  aObject.AddPair(aKey, TJSONNumber.Create(aValue));
end;

procedure JsonInteger(const aObject: TJSONObject; const aKey: string; const aValue: Cardinal); overload;
begin
  aObject.AddPair(aKey, TJSONNumber.Create(aValue));
end;

procedure JsonPercent(const aObject: TJSONObject; const aKey: string; const aValue: Double);
begin
  aObject.AddPair(aKey, TJSONNumber.Create(FormatFloat('0.00', Floor(aValue * 100 + 0.5) / 100,
    TFormatSettings.Invariant)));
end;

procedure JsonStatistic(const aObject: TJSONObject; const aKey: string;
  const aValue: TMachineOverviewEvidenceStatistic; const aPeakSource: Boolean = False);
var
  lObject: TJSONObject;
begin
  if not aValue.Available then
    Exit;
  lObject := TJSONObject.Create;
  aObject.AddPair(aKey, lObject);
  JsonPercent(lObject, 'a', aValue.Average);
  JsonPercent(lObject, 'p', aValue.Peak);
  JsonInteger(lObject, 't', EvidenceUtcMs(aValue.PeakAtUtc));
  if aPeakSource and not aValue.PeakSourceName.IsEmpty then
    lObject.AddPair('n', aValue.PeakSourceName);
end;

procedure JsonResourceRows(const aObject: TJSONObject; const aKey: string;
  const aItems: TArray<TMachineOverviewResourceContribution>; const aIo: Boolean);
var
  lRows: TJSONArray;
  lRow: TJSONObject;
  lItem: TMachineOverviewResourceContribution;
begin
  lRows := TJSONArray.Create;
  aObject.AddPair(aKey, lRows);
  for lItem in aItems do
  begin
    lRow := TJSONObject.Create;
    lRows.AddElement(lRow);
    JsonInteger(lRow, 'pid', lItem.ProcessId);
    lRow.AddPair('ct', TJSONNumber.Create(UIntToStr(lItem.CreationTime100ns)));
    lRow.AddPair('n', lItem.DisplayName);
    lRow.AddPair('pa', lItem.ImagePath);
    lRow.AddPair('st', lItem.PathStatus);
    lRow.AddPair('a', TJSONNumber.Create(FormatFloat('0', lItem.AverageValue, TFormatSettings.Invariant)));
    lRow.AddPair('p', TJSONNumber.Create(FormatFloat('0', lItem.PeakValue, TFormatSettings.Invariant)));
    if aIo then
      lRow.AddPair('b', TJSONNumber.Create(FormatFloat('0', lItem.TotalBytes, TFormatSettings.Invariant)))
    else
    begin
      lRow.AddPair('f', TJSONNumber.Create(FormatFloat('0', lItem.FirstValue, TFormatSettings.Invariant)));
      lRow.AddPair('l', TJSONNumber.Create(FormatFloat('0', lItem.LastValue, TFormatSettings.Invariant)));
    end;
    JsonInteger(lRow, 't', EvidenceUtcMs(lItem.PeakAtUtc));
    JsonInteger(lRow, 'ls', EvidenceUtcMs(lItem.LastSeenUtc));
    JsonInteger(lRow, 'c', lItem.SampleCount);
  end;
end;

procedure JsonResourcePhase(const aObject: TJSONObject; const aPhase: TMachineOverviewEvidencePhase;
  const aEvidence: TMachineOverviewIncidentEvidence);
var
  lObject: TJSONObject;
begin
  if TMachineOverviewResourceKind.Ram in aEvidence.Resources then
  begin
    lObject := TJSONObject.Create;
    aObject.AddPair('mem', lObject);
    JsonStatistic(lObject, 'pu', aPhase.PhysicalUsed);
    JsonStatistic(lObject, 'cm', aPhase.Commit);
    JsonStatistic(lObject, 'pg', aPhase.Paging);
    JsonResourceRows(aObject, 'rm', aPhase.RamProcesses, False);
  end;
  if TMachineOverviewResourceKind.Io in aEvidence.Resources then
  begin
    lObject := TJSONObject.Create;
    aObject.AddPair('dk', lObject);
    if not aPhase.DiskName.IsEmpty then
      lObject.AddPair('dn', aPhase.DiskName);
    JsonStatistic(lObject, 'ac', aPhase.DiskActive, True);
    JsonStatistic(lObject, 'lt', aPhase.DiskLatency, True);
    JsonStatistic(lObject, 'q', aPhase.DiskQueue, True);
    JsonStatistic(lObject, 'tp', aPhase.DiskThroughput, True);
    JsonStatistic(aObject, 'mio', aPhase.MeasuredProcessIo);
    JsonResourceRows(aObject, 'io', aPhase.IoProcesses, True);
  end;
end;

function EncodeEvidence(const aEvidence: TMachineOverviewIncidentEvidence): string;
var
  g: TGarbos;
  lRoot, lObject, lRow: TJSONObject;
  lPhases, lRows, lGaps: TJSONArray;
  lKind: TMachineOverviewEvidencePhaseKind;
  lPhase: TMachineOverviewEvidencePhase;
  lProcess: TMachineOverviewProcessContribution;
  lApplication: TMachineOverviewApplicationContribution;
  lGap: TMachineOverviewEvidenceGap;
begin
  g := Default(TGarbos);
  GC(lRoot, TJSONObject.Create, g);
  if aEvidence.Resources = [] then
    JsonInteger(lRoot, 'v', 1)
  else
  begin
    JsonInteger(lRoot, 'v', 2);
    lRows := TJSONArray.Create;
    lRoot.AddPair('rs', lRows);
    if TMachineOverviewResourceKind.Ram in aEvidence.Resources then
      lRows.Add('ram');
    if TMachineOverviewResourceKind.Io in aEvidence.Resources then
      lRows.Add('io');
    lRoot.AddPair('dn', aEvidence.DiskName);
  end;
  JsonInteger(lRoot, 'lp', aEvidence.LogicalProcessorCount);
  JsonInteger(lRoot, 'pms', aEvidence.ProcessIntervalMs);
  JsonInteger(lRoot, 'sms', aEvidence.SystemIntervalMs);
  JsonInteger(lRoot, 'den', aEvidence.InaccessibleProcessCountMax);
  lRoot.AddPair('tr', TJSONBool.Create(aEvidence.Truncated));
  JsonInteger(lRoot, 'go', aEvidence.GapsOmitted);
  lPhases := TJSONArray.Create;
  lRoot.AddPair('ph', lPhases);
  for lKind := Low(lKind) to High(lKind) do
  begin
    lPhase := aEvidence.Phases[lKind];
    lObject := TJSONObject.Create;
    lPhases.AddElement(lObject);
    lObject.AddPair('k', cPhaseNames[lKind]);
    JsonInteger(lObject, 's', EvidenceUtcMs(lPhase.StartUtc));
    JsonInteger(lObject, 'e', EvidenceUtcMs(lPhase.EndUtc));
    JsonInteger(lObject, 'ps', lPhase.ProcessSampleCount);
    JsonInteger(lObject, 'pe', lPhase.ExpectedProcessSampleCount);
    JsonInteger(lObject, 'ss', lPhase.SystemSampleCount);
    JsonInteger(lObject, 'se', lPhase.ExpectedSystemSampleCount);
    JsonStatistic(lObject, 'cpu', lPhase.SystemCpu);
    JsonStatistic(lObject, 'dpc', lPhase.Dpc);
    JsonStatistic(lObject, 'irq', lPhase.Interrupt);
    JsonStatistic(lObject, 'mp', lPhase.MeasuredProcessCpu);
    JsonStatistic(lObject, 'un', lPhase.UnattributedCpu);
    if aEvidence.Resources <> [] then
      JsonResourcePhase(lObject, lPhase, aEvidence);
    lRows := TJSONArray.Create;
    lObject.AddPair('pr', lRows);
    for lProcess in lPhase.Processes do
    begin
      lRow := TJSONObject.Create;
      lRows.AddElement(lRow);
      JsonInteger(lRow, 'pid', lProcess.ProcessId);
      lRow.AddPair('ct', TJSONNumber.Create(UIntToStr(lProcess.CreationTime100ns)));
      lRow.AddPair('n', lProcess.DisplayName);
      lRow.AddPair('pa', lProcess.ImagePath);
      lRow.AddPair('st', lProcess.PathStatus);
      JsonPercent(lRow, 'a', lProcess.AverageCpuPercent);
      JsonPercent(lRow, 'p', lProcess.PeakCpuPercent);
      JsonInteger(lRow, 't', EvidenceUtcMs(lProcess.PeakAtUtc));
      JsonInteger(lRow, 'ls', EvidenceUtcMs(lProcess.LastSeenUtc));
      JsonInteger(lRow, 'c', lProcess.SampleCount);
    end;
    lRows := TJSONArray.Create;
    lObject.AddPair('ap', lRows);
    for lApplication in lPhase.Applications do
    begin
      lRow := TJSONObject.Create;
      lRows.AddElement(lRow);
      lRow.AddPair('n', lApplication.DisplayName);
      JsonInteger(lRow, 'pc', lApplication.ProcessCount);
      JsonPercent(lRow, 'a', lApplication.AverageCpuPercent);
      JsonPercent(lRow, 'p', lApplication.PeakCpuPercent);
      JsonInteger(lRow, 't', EvidenceUtcMs(lApplication.PeakAtUtc));
    end;
  end;
  lGaps := TJSONArray.Create;
  lRoot.AddPair('gp', lGaps);
  for lGap in aEvidence.Gaps do
  begin
    lRow := TJSONObject.Create;
    lGaps.AddElement(lRow);
    JsonInteger(lRow, 's', EvidenceUtcMs(lGap.StartUtc));
    JsonInteger(lRow, 'e', EvidenceUtcMs(lGap.EndUtc));
    lRow.AddPair('r', cGapNames[lGap.Reason]);
  end;
  Result := lRoot.ToJSON;
end;

function MachineOverviewEvidenceToJson(const aEvidence: TMachineOverviewIncidentEvidence): string;
var
  lEvidence: TMachineOverviewIncidentEvidence;
  lKind: TMachineOverviewEvidencePhaseKind;
  i, j, lStep, lAction: Integer;
  lResource: TMachineOverviewResourceKind;
  lItems: TArray<TMachineOverviewResourceContribution>;
begin
  lEvidence := aEvidence;
  // Our copy must own every dynamic array before applying the serialization budget.
  lEvidence.Gaps := Copy(aEvidence.Gaps, 0, 16);
  if Length(aEvidence.Gaps) > 16 then
  begin
    lEvidence.Truncated := True;
    lEvidence.GapsOmitted := lEvidence.GapsOmitted + Length(aEvidence.Gaps) - 16;
  end;
  for lKind := Low(lKind) to High(lKind) do
  begin
    i := 5;
    if lKind = TMachineOverviewEvidencePhaseKind.During then
      i := 10;
    lEvidence.Phases[lKind].RamProcesses := Copy(aEvidence.Phases[lKind].RamProcesses, 0, i);
    lEvidence.Phases[lKind].IoProcesses := Copy(aEvidence.Phases[lKind].IoProcesses, 0, i);
    lEvidence.Truncated := lEvidence.Truncated or (Length(aEvidence.Phases[lKind].RamProcesses) > i) or
      (Length(aEvidence.Phases[lKind].IoProcesses) > i);
    lEvidence.Phases[lKind].Processes := Copy(aEvidence.Phases[lKind].Processes, 0, i);
    lEvidence.Phases[lKind].Applications := Copy(aEvidence.Phases[lKind].Applications, 0, 5);
    lEvidence.Truncated := lEvidence.Truncated or (Length(aEvidence.Phases[lKind].Processes) > i) or
      (Length(aEvidence.Phases[lKind].Applications) > 5);
  end;
  for lStep := 0 to 10 do
  begin
    Result := EncodeEvidence(lEvidence);
    if TEncoding.UTF8.GetByteCount(Result) <= cMaximumJsonBytes then
      Exit;
    lEvidence.Truncated := True;
    lAction := lStep;
    if aEvidence.Resources <> [] then
    begin
      lAction := lStep - 2;
      if lStep < 2 then
      begin
        lKind := TMachineOverviewEvidencePhaseKind.After;
        if lStep = 1 then
          lKind := TMachineOverviewEvidencePhaseKind.Before;
        SetLength(lEvidence.Phases[lKind].RamProcesses, Min(3, Length(lEvidence.Phases[lKind].RamProcesses)));
        SetLength(lEvidence.Phases[lKind].IoProcesses, Min(3, Length(lEvidence.Phases[lKind].IoProcesses)));
        Continue;
      end;
      if lAction = 7 then
      begin
        SetLength(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].RamProcesses,
          Min(5, Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].RamProcesses)));
        SetLength(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].IoProcesses,
          Min(5, Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].IoProcesses)));
        Continue;
      end;
      if lAction = 5 then
      begin
        lEvidence.DiskName := EvidenceTextPrefix(lEvidence.DiskName, 64);
        for lKind := Low(lKind) to High(lKind) do
        begin
          lEvidence.Phases[lKind].DiskName := EvidenceTextPrefix(lEvidence.Phases[lKind].DiskName, 64);
          lEvidence.Phases[lKind].DiskActive.PeakSourceName := EvidenceTextPrefix(lEvidence.Phases[lKind].DiskActive.PeakSourceName, 64);
          lEvidence.Phases[lKind].DiskLatency.PeakSourceName := EvidenceTextPrefix(lEvidence.Phases[lKind].DiskLatency.PeakSourceName, 64);
          lEvidence.Phases[lKind].DiskQueue.PeakSourceName := EvidenceTextPrefix(lEvidence.Phases[lKind].DiskQueue.PeakSourceName, 64);
          lEvidence.Phases[lKind].DiskThroughput.PeakSourceName := EvidenceTextPrefix(lEvidence.Phases[lKind].DiskThroughput.PeakSourceName, 64);
        end;
      end;
      if lAction in [3, 5] then
        for lKind := Low(lKind) to High(lKind) do
          for lResource := Low(lResource) to High(lResource) do
          begin
            if lResource = TMachineOverviewResourceKind.Ram then
              lItems := lEvidence.Phases[lKind].RamProcesses
            else
              lItems := lEvidence.Phases[lKind].IoProcesses;
            for j := 0 to High(lItems) do
              if lAction = 3 then
                lItems[j].ImagePath := ''
              else
              begin
                lItems[j].DisplayName := EvidenceTextPrefix(lItems[j].DisplayName, 64);
                lItems[j].PathStatus := EvidenceTextPrefix(lItems[j].PathStatus, 32);
              end;
          end;
    end;
    case lAction of
      0: SetLength(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.After].Processes,
        Min(3, Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.After].Processes)));
      1: SetLength(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes,
        Min(3, Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.Before].Processes)));
      2: SetLength(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes,
        Min(5, Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes)));
      3: for lKind := Low(lKind) to High(lKind) do
           for i := 0 to High(lEvidence.Phases[lKind].Processes) do
             lEvidence.Phases[lKind].Processes[i].ImagePath := '';
      4: begin
           lEvidence.GapsOmitted := lEvidence.GapsOmitted + Max(0, Length(lEvidence.Gaps) - 4);
           SetLength(lEvidence.Gaps, Min(4, Length(lEvidence.Gaps)));
         end;
      5: for lKind := Low(lKind) to High(lKind) do
         begin
           for i := 0 to High(lEvidence.Phases[lKind].Processes) do
           begin
             lEvidence.Phases[lKind].Processes[i].DisplayName := EvidenceTextPrefix(lEvidence.Phases[lKind].Processes[i].DisplayName, 64);
             lEvidence.Phases[lKind].Processes[i].PathStatus := EvidenceTextPrefix(lEvidence.Phases[lKind].Processes[i].PathStatus, 32);
           end;
           for i := 0 to High(lEvidence.Phases[lKind].Applications) do
             lEvidence.Phases[lKind].Applications[i].DisplayName := EvidenceTextPrefix(lEvidence.Phases[lKind].Applications[i].DisplayName, 64);
         end;
      6: for lKind := Low(lKind) to High(lKind) do
         begin
           lEvidence.Phases[lKind].Processes := nil;
           lEvidence.Phases[lKind].Applications := nil;
         end;
    end;
  end;
  raise EArgumentException.Create('Evidence statistics exceed the JSON budget');
end;

function ReadInteger(const aObject: TJSONObject; const aKey: string; const aMaximum: Int64): Int64;
var
  lValue: TJSONValue;
begin
  lValue := aObject.GetValue(aKey);
  if not (lValue is TJSONNumber) or not TryStrToInt64(lValue.Value, Result) or
    (Result < 0) or (Result > aMaximum) then
    raise EConvertError.Create('Invalid evidence integer: ' + aKey);
end;

function ReadCount(const aObject: TJSONObject; const aKey: string): Integer;
begin
  Result := Integer(ReadInteger(aObject, aKey, Int64(MaxInt)));
end;

function ReadCardinal(const aObject: TJSONObject; const aKey: string): Cardinal;
begin
  Result := Cardinal(ReadInteger(aObject, aKey, Int64(High(Cardinal))));
end;

function ReadText(const aObject: TJSONObject; const aKey: string; const aMaximum: Integer): string;
var
  lValue: TJSONValue;
begin
  lValue := aObject.GetValue(aKey);
  if not (lValue is TJSONString) or (Length(lValue.Value) > aMaximum) then
    raise EConvertError.Create('Invalid evidence text: ' + aKey);
  Result := lValue.Value;
end;

function ReadPercent(const aObject: TJSONObject; const aKey: string): Double;
var
  lValue: TJSONValue;
begin
  lValue := aObject.GetValue(aKey);
  if not (lValue is TJSONNumber) or
    not TryStrToFloat(lValue.Value, Result, TFormatSettings.Invariant) or
    IsNan(Result) or IsInfinite(Result) or (Result < 0) or (Result > 100) then
    raise EConvertError.Create('Invalid evidence percentage: ' + aKey);
end;

function ReadUtc(const aObject: TJSONObject; const aKey: string): TDateTime;
begin
  Result := EvidenceFromMs(ReadInteger(aObject, aKey, 253402300799999));
end;

procedure ValidateObject(const aObject: TJSONObject);
var
  i, j: Integer;
begin
  if aObject.Count > 32 then
    raise EConvertError.Create('Too many evidence object members');
  for i := 0 to aObject.Count - 1 do
    for j := 0 to i - 1 do
      if aObject.Pairs[i].JsonString.Value = aObject.Pairs[j].JsonString.Value then
        raise EConvertError.Create('Duplicate evidence member');
end;

function ReadResourceNumber(const aObject: TJSONObject; const aKey: string): Double;
var
  lValue: TJSONValue;
begin
  lValue := aObject.GetValue(aKey);
  if not (lValue is TJSONNumber) or
    not TryStrToFloat(lValue.Value, Result, TFormatSettings.Invariant) or IsNan(Result) or
    IsInfinite(Result) or (Result < 0) or (Result > 1E30) then
    raise EConvertError.Create('Invalid evidence resource number: ' + aKey);
end;

function ReadStatistic(const aObject: TJSONObject; const aKey: string; const aResource: Boolean = False): TMachineOverviewEvidenceStatistic;
var
  lValue: TJSONValue;
begin
  Result := Default(TMachineOverviewEvidenceStatistic);
  lValue := aObject.GetValue(aKey);
  if not Assigned(lValue) then
    Exit;
  if not (lValue is TJSONObject) then
    raise EConvertError.Create('Invalid evidence statistic: ' + aKey);
  ValidateObject(lValue as TJSONObject);
  Result.Available := True;
  if aResource then
    Result.Average := ReadResourceNumber((lValue as TJSONObject), 'a')
  else
    Result.Average := ReadPercent((lValue as TJSONObject), 'a');
  // Peak is optional for measured and residual aggregates in format v1.
  if Assigned((lValue as TJSONObject).GetValue('p')) then
    if aResource then
      Result.Peak := ReadResourceNumber((lValue as TJSONObject), 'p')
    else
      Result.Peak := ReadPercent((lValue as TJSONObject), 'p');
  if Assigned((lValue as TJSONObject).GetValue('t')) then
    Result.PeakAtUtc := ReadUtc((lValue as TJSONObject), 't');
  if aResource and Assigned((lValue as TJSONObject).GetValue('n')) then
    Result.PeakSourceName := ReadText((lValue as TJSONObject), 'n', 256);
end;

function ReadArray(const aObject: TJSONObject; const aKey: string; const aMaximum: Integer): TJSONArray;
var
  lValue: TJSONValue;
begin
  lValue := aObject.GetValue(aKey);
  if not (lValue is TJSONArray) or ((lValue as TJSONArray).Count > aMaximum) then
    raise EConvertError.Create('Invalid evidence array: ' + aKey);
  Result := (lValue as TJSONArray);
end;

function ArrayObject(const aArray: TJSONArray; const aIndex: Integer): TJSONObject;
begin
  if not (aArray.Items[aIndex] is TJSONObject) then
    raise EConvertError.Create('Invalid evidence row');
  Result := TJSONObject(aArray.Items[aIndex]);
  ValidateObject(Result);
end;

function ReadResourceRows(const aObject: TJSONObject; const aKey: string;
  const aIo: Boolean): TArray<TMachineOverviewResourceContribution>;
var
  lArray: TJSONArray;
  lRow: TJSONObject;
  lCreation: TJSONValue;
  i: Integer;
begin
  Result := nil;
  if not Assigned(aObject.GetValue(aKey)) then
    Exit;
  lArray := ReadArray(aObject, aKey, 10);
  SetLength(Result, lArray.Count);
  for i := 0 to lArray.Count - 1 do
  begin
    lRow := ArrayObject(lArray, i);
    Result[i].ProcessId := ReadCardinal(lRow, 'pid');
    lCreation := lRow.GetValue('ct');
    if not (lCreation is TJSONNumber) or
      not TryStrToUInt64(lCreation.Value, Result[i].CreationTime100ns) then
      raise EConvertError.Create('Invalid evidence creation time');
    Result[i].DisplayName := ReadText(lRow, 'n', 256);
    Result[i].ImagePath := ReadText(lRow, 'pa', 1024);
    Result[i].PathStatus := ReadText(lRow, 'st', 64);
    Result[i].AverageValue := ReadResourceNumber(lRow, 'a');
    Result[i].PeakValue := ReadResourceNumber(lRow, 'p');
    if aIo then
      Result[i].TotalBytes := ReadResourceNumber(lRow, 'b')
    else
    begin
      Result[i].FirstValue := ReadResourceNumber(lRow, 'f');
      Result[i].LastValue := ReadResourceNumber(lRow, 'l');
    end;
    Result[i].PeakAtUtc := ReadUtc(lRow, 't');
    Result[i].LastSeenUtc := ReadUtc(lRow, 'ls');
    Result[i].SampleCount := ReadCount(lRow, 'c');
  end;
end;

procedure ReadResourcePhase(const aObject: TJSONObject; var aPhase: TMachineOverviewEvidencePhase);
var
  lValue: TJSONValue;
  lObject: TJSONObject;
begin
  lValue := aObject.GetValue('mem');
  if Assigned(lValue) then
  begin
    if not (lValue is TJSONObject) then
      raise EConvertError.Create('Invalid memory statistics');
    lObject := lValue as TJSONObject;
    ValidateObject(lObject);
    aPhase.PhysicalUsed := ReadStatistic(lObject, 'pu');
    aPhase.Commit := ReadStatistic(lObject, 'cm');
    aPhase.Paging := ReadStatistic(lObject, 'pg', True);
  end;
  lValue := aObject.GetValue('dk');
  if Assigned(lValue) then
  begin
    if not (lValue is TJSONObject) then
      raise EConvertError.Create('Invalid disk statistics');
    lObject := lValue as TJSONObject;
    ValidateObject(lObject);
    if Assigned(lObject.GetValue('dn')) then
      aPhase.DiskName := ReadText(lObject, 'dn', 256);
    aPhase.DiskActive := ReadStatistic(lObject, 'ac', True);
    aPhase.DiskLatency := ReadStatistic(lObject, 'lt', True);
    aPhase.DiskQueue := ReadStatistic(lObject, 'q', True);
    aPhase.DiskThroughput := ReadStatistic(lObject, 'tp', True);
  end;
  aPhase.MeasuredProcessIo := ReadStatistic(aObject, 'mio', True);
  aPhase.RamProcesses := ReadResourceRows(aObject, 'rm', False);
  aPhase.IoProcesses := ReadResourceRows(aObject, 'io', True);
end;

function ReadPhase(const aObject: TJSONObject; const aKind: TMachineOverviewEvidencePhaseKind): TMachineOverviewEvidencePhase;
var
  i: Integer;
  lArray: TJSONArray;
  lRow: TJSONObject;
  lCreation: TJSONValue;
begin
  Result := Default(TMachineOverviewEvidencePhase);
  Result.Kind := aKind;
  if ReadText(aObject, 'k', 6) <> cPhaseNames[aKind] then
    raise EConvertError.Create('Invalid evidence phase order');
  Result.StartUtc := ReadUtc(aObject, 's');
  Result.EndUtc := ReadUtc(aObject, 'e');
  if Result.EndUtc < Result.StartUtc then
    raise EConvertError.Create('Invalid evidence phase range');
  Result.ProcessSampleCount := ReadCount(aObject, 'ps');
  Result.ExpectedProcessSampleCount := ReadCount(aObject, 'pe');
  Result.SystemSampleCount := ReadCount(aObject, 'ss');
  Result.ExpectedSystemSampleCount := ReadCount(aObject, 'se');
  Result.SystemCpu := ReadStatistic(aObject, 'cpu');
  Result.Dpc := ReadStatistic(aObject, 'dpc');
  Result.Interrupt := ReadStatistic(aObject, 'irq');
  Result.MeasuredProcessCpu := ReadStatistic(aObject, 'mp');
  Result.UnattributedCpu := ReadStatistic(aObject, 'un');
  i := 5;
  if aKind = TMachineOverviewEvidencePhaseKind.During then
    i := 10;
  lArray := ReadArray(aObject, 'pr', i);
  SetLength(Result.Processes, lArray.Count);
  for i := 0 to lArray.Count - 1 do
  begin
    lRow := ArrayObject(lArray, i);
    Result.Processes[i].ProcessId := ReadCardinal(lRow, 'pid');
    lCreation := lRow.GetValue('ct');
    if not (lCreation is TJSONNumber) or
      not TryStrToUInt64(lCreation.Value, Result.Processes[i].CreationTime100ns) then
      raise EConvertError.Create('Invalid evidence creation time');
    Result.Processes[i].DisplayName := ReadText(lRow, 'n', 256);
    Result.Processes[i].ImagePath := ReadText(lRow, 'pa', 1024);
    Result.Processes[i].PathStatus := ReadText(lRow, 'st', 64);
    Result.Processes[i].AverageCpuPercent := ReadPercent(lRow, 'a');
    Result.Processes[i].PeakCpuPercent := ReadPercent(lRow, 'p');
    Result.Processes[i].PeakAtUtc := ReadUtc(lRow, 't');
    Result.Processes[i].LastSeenUtc := ReadUtc(lRow, 'ls');
    Result.Processes[i].SampleCount := ReadCount(lRow, 'c');
  end;
  lArray := ReadArray(aObject, 'ap', 5);
  SetLength(Result.Applications, lArray.Count);
  for i := 0 to lArray.Count - 1 do
  begin
    lRow := ArrayObject(lArray, i);
    Result.Applications[i].DisplayName := ReadText(lRow, 'n', 256);
    Result.Applications[i].ProcessCount := ReadCount(lRow, 'pc');
    Result.Applications[i].AverageCpuPercent := ReadPercent(lRow, 'a');
    Result.Applications[i].PeakCpuPercent := ReadPercent(lRow, 'p');
    Result.Applications[i].PeakAtUtc := ReadUtc(lRow, 't');
  end;
end;

function TryMachineOverviewEvidenceFromJson(const aText: string;
  out aEvidence: TMachineOverviewIncidentEvidence; out aError: string): Boolean;
var
  g: TGarbos;
  lValue, lBoolean: TJSONValue;
  lRoot, lRow: TJSONObject;
  lPhases, lGaps, lResources: TJSONArray;
  lKind: TMachineOverviewEvidencePhaseKind;
  lReason: TMachineOverviewEvidenceGapReason;
  lCode: string;
  i, lVersion: Integer;
  lFound: Boolean;
begin
  Result := False;
  aEvidence := Default(TMachineOverviewIncidentEvidence);
  aError := '';
  g := Default(TGarbos);
  try
    if (Length(aText) > cMaximumJsonBytes) or (TEncoding.UTF8.GetByteCount(aText) > cMaximumJsonBytes) then
      raise EConvertError.Create('Evidence exceeds the JSON budget');
    lValue := TJSONObject.ParseJSONValue(aText);
    GC(lValue, g);
    if not (lValue is TJSONObject) then
      raise EConvertError.Create('Evidence must be a JSON object');
    lRoot := (lValue as TJSONObject);
    ValidateObject(lRoot);
    lVersion := ReadCount(lRoot, 'v');
    if not (lVersion in [1, 2]) then
      raise EConvertError.Create('Unsupported evidence version');
    if lVersion = 2 then
    begin
      if Assigned(lRoot.GetValue('rs')) then
      begin
        lResources := ReadArray(lRoot, 'rs', 2);
        for i := 0 to lResources.Count - 1 do
        begin
          if not (lResources.Items[i] is TJSONString) then
            raise EConvertError.Create('Invalid resource kind');
          if lResources.Items[i].Value = 'ram' then
            Include(aEvidence.Resources, TMachineOverviewResourceKind.Ram)
          else if lResources.Items[i].Value = 'io' then
            Include(aEvidence.Resources, TMachineOverviewResourceKind.Io)
          else
            raise EConvertError.Create('Invalid resource kind');
        end;
      end;
      if Assigned(lRoot.GetValue('dn')) then
        aEvidence.DiskName := ReadText(lRoot, 'dn', 256);
    end;
    aEvidence.LogicalProcessorCount := ReadCount(lRoot, 'lp');
    if aEvidence.LogicalProcessorCount > 65536 then
      raise EConvertError.Create('Invalid evidence logical processor count');
    aEvidence.ProcessIntervalMs := ReadCardinal(lRoot, 'pms');
    aEvidence.SystemIntervalMs := ReadCardinal(lRoot, 'sms');
    if (aEvidence.ProcessIntervalMs = 0) or (aEvidence.SystemIntervalMs = 0) then
      raise EConvertError.Create('Evidence intervals must be positive');
    aEvidence.InaccessibleProcessCountMax := ReadCount(lRoot, 'den');
    aEvidence.GapsOmitted := ReadCount(lRoot, 'go');
    lBoolean := lRoot.GetValue('tr');
    if not (lBoolean is TJSONBool) then
      raise EConvertError.Create('Invalid evidence truncation flag');
    aEvidence.Truncated := TJSONBool(lBoolean).AsBoolean;
    lPhases := ReadArray(lRoot, 'ph', 3);
    if lPhases.Count <> 3 then
      raise EConvertError.Create('Evidence must contain three phases');
    for lKind := Low(lKind) to High(lKind) do
    begin
      aEvidence.Phases[lKind] := ReadPhase(ArrayObject(lPhases, Ord(lKind)), lKind);
      if lVersion = 2 then
        ReadResourcePhase(ArrayObject(lPhases, Ord(lKind)), aEvidence.Phases[lKind]);
    end;
    lGaps := ReadArray(lRoot, 'gp', 16);
    SetLength(aEvidence.Gaps, lGaps.Count);
    for i := 0 to lGaps.Count - 1 do
    begin
      lRow := ArrayObject(lGaps, i);
      aEvidence.Gaps[i].StartUtc := ReadUtc(lRow, 's');
      aEvidence.Gaps[i].EndUtc := ReadUtc(lRow, 'e');
      if aEvidence.Gaps[i].EndUtc < aEvidence.Gaps[i].StartUtc then
        raise EConvertError.Create('Invalid evidence gap range');
      lCode := ReadText(lRow, 'r', 24);
      lFound := False;
      for lReason := Low(lReason) to High(lReason) do
        if lCode = cGapNames[lReason] then
        begin
          aEvidence.Gaps[i].Reason := lReason;
          lFound := True;
        end;
      if not lFound then
        raise EConvertError.Create('Invalid evidence gap reason');
    end;
    Result := True;
  except
    on lException: Exception do
    begin
      aEvidence := Default(TMachineOverviewIncidentEvidence);
      aError := lException.Message;
    end;
  end;
end;

end.

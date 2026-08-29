unit ActiveAppView.MachineOverview.Pipeline;

interface

uses
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewEnqueueResult = (Queued, Full, Stopped);

  TMachineOverviewPipelineDiagnostics = record
    RawAccepted: Int64;
    RawDequeued: Int64;
    RawDropped: Int64;
    RawQueueDepth: Integer;
    HistoryAccepted: Int64;
    HistoryDequeued: Int64;
    HistoryDropped: Int64;
    HistoryQueueDepth: Integer;
    TraceAccepted: Int64;
    TraceDequeued: Int64;
    TraceDropped: Int64;
    TraceQueueDepth: Integer;
    ActiveWorkerCount: Integer;
    AggregatorThreadId: Cardinal;
  end;

  IMachineOverviewRawSample = interface(IInterface)
    ['{A4FD370E-785F-4CC0-A30A-F9D5249CC910}']
    function ProviderId: string;
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function ProviderSample: TMachineOverviewProviderSample;
  end;

  IMachineOverviewSnapshot = interface(IInterface)
    ['{B65A0CF2-2FE5-45F3-B7FE-01D4D5E84CED}']
    function Sequence: UInt64;
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function LastProviderId: string;
    function RawSamplesConsumed: Int64;
    function RawSamplesDropped: Int64;
    function HistoryRecordsDropped: Int64;
    function AggregatorThreadId: Cardinal;
    function Presentation: TMachineOverviewPresentation;
  end;

  TMachineOverviewMonotonicSchedule = record
  private
    fIntervalMs: UInt64;
    fNextDueMs: UInt64;
  public
    class function Create(const aFirstDueMs, aIntervalMs: UInt64):
      TMachineOverviewMonotonicSchedule; static;
    function IsDue(const aNowMonotonicMs: UInt64): Boolean;
    procedure MarkCompleted(const aNowMonotonicMs: UInt64);
    function NextDueMs: UInt64;
  end;

  TMachineOverviewPipeline = class;

  TMachineOverviewSnapshotCursor = class
  private
    fFrozen: Boolean;
    fLastSequence: UInt64;
  public
    function TryRead(const aPipeline: TMachineOverviewPipeline;
      out aSnapshot: IMachineOverviewSnapshot): Boolean;
    procedure SetFrozen(const aValue: Boolean);
    function Frozen: Boolean;
    function LastSequence: UInt64;
  end;

  TMachineOverviewPipeline = class
  private
    fState: TObject;
    function IsWorkerRunning: Boolean;
    function StopInternal(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function TryReadLatestInternal(const aAfterSequence: UInt64;
      out aSnapshot: IMachineOverviewSnapshot): Boolean;
  public
    constructor Create(const aRawQueueCapacity, aHistoryQueueCapacity: Integer);
    destructor Destroy; override;
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function EnqueueRaw(const aSample: IMachineOverviewRawSample):
      TMachineOverviewEnqueueResult;
    function TryReadLatest(const aAfterSequence: UInt64;
      out aSnapshot: IMachineOverviewSnapshot): Boolean;
    function TryTakeHistory(out aSample: IMachineOverviewRawSample): Boolean;
    function TryTakeIncident(
      out aChange: TMachineOverviewIncidentChange): Boolean;
    function TryTakeDetailedTrace(
      out aChange: TMachineOverviewIncidentChange): Boolean;
    function TryRequestDetailedTrace(
      var aChange: TMachineOverviewIncidentChange): Boolean;
    procedure PublishDetailedTraceResult(
      const aChange: TMachineOverviewIncidentChange);
    procedure SetDetailedTraceEnabled(const aEnabled: Boolean);
    procedure SetHistoryEnabled(const aEnabled: Boolean);
    procedure MergePersistedIncidents(
      const aIncidents: TArray<TMachineOverviewIncident>);
    function WaitUntilRunning(const aTimeoutMs: Cardinal): Boolean;
    function WaitForSequence(const aSequence: UInt64;
      const aTimeoutMs: Cardinal): Boolean;
    function Diagnostics: TMachineOverviewPipelineDiagnostics;
    function RawDroppedForProvider(const aProviderId: string): Int64;
    function IsRunning: Boolean;
    function IncidentCount: Integer;
    procedure UpdateHistoryWriterDiagnostics(const aQueueDepth: Integer;
      const aDropped: Int64; const aLastCommitAvailable: Boolean;
      const aLastCommitDurationMs: UInt64; const aLastError: string);
  end;

function CreateMachineOverviewRawSample(
  const aSample: TMachineOverviewProviderSample): IMachineOverviewRawSample;

implementation

uses
  System.Classes, System.DateUtils, System.Generics.Collections, System.Math,
  System.StrUtils, System.SyncObjs, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.MachineOverview.Domain,
  ActiveAppView.MachineOverview.Presentation,
  ActiveAppView.MachineOverview.TemperatureProvider,
  ActiveAppView.MachineOverview.Trace,
  ActiveAppView.MachineOverview.WindowsProviders;

const
  cMachineOverviewTraceQueueCapacity = 16;

type
  TMachineOverviewPipelineState = class
  public
    ActiveWorkerCount: Integer;
    AggregatorThreadId: Integer;
    CounterLock: TCriticalSection;
    DetailedTraceEnabled: Integer;
    HistoryAccepted: Int64;
    HistoryDequeued: Int64;
    HistoryDropped: Int64;
    HistoryEnabled: Integer;
    HistoryQueue: TThreadedQueue<IMachineOverviewRawSample>;
    IncidentQueue: TThreadedQueue<TMachineOverviewIncidentChange>;
    IncidentLock: TCriticalSection;
    Incidents: TDictionary<string, TMachineOverviewIncident>;
    HistoryWriterDropped: Int64;
    HistoryWriterQueueDepth: Integer;
    LastSQLiteCommitAvailable: Boolean;
    LastSQLiteCommitDurationMs: UInt64;
    LastSQLiteError: string;
    LifecycleLock: TCriticalSection;
    LatestSnapshot: IMachineOverviewSnapshot;
    MailboxLock: TCriticalSection;
    ProviderDrops: TDictionary<string, Int64>;
    RawAccepted: Int64;
    RawDequeued: Int64;
    RawDropped: Int64;
    RawQueue: TThreadedQueue<IMachineOverviewRawSample>;
    SnapshotEvent: TEvent;
    SnapshotSequence: Int64;
    StartedEvent: TEvent;
    Stopping: Integer;
    TraceAccepted: Int64;
    TraceDequeued: Int64;
    TraceDropped: Int64;
    TraceQueue: TThreadedQueue<TMachineOverviewIncidentChange>;
    Worker: TThread;
    constructor Create(const aRawQueueCapacity, aHistoryQueueCapacity: Integer);
    destructor Destroy; override;
    procedure ApplyIncident(const aIncident: TMachineOverviewIncident);
    procedure PublishIncidentChange(
      const aChange: TMachineOverviewIncidentChange);
    procedure RequestDetailedTrace(
      var aChange: TMachineOverviewIncidentChange);
    procedure FillIncidentPresentation(
      var aSource: TMachineOverviewPresentationSource;
      const aCapturedAtUtc: TDateTime);
    function TryReadLatest(const aAfterSequence: UInt64;
      out aSnapshot: IMachineOverviewSnapshot): Boolean;
  end;

  TMachineOverviewRawSample = class(TInterfacedObject, IMachineOverviewRawSample)
  private
    fSample: TMachineOverviewProviderSample;
  public
    constructor Create(const aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function ProviderSample: TMachineOverviewProviderSample;
  end;

  TMachineOverviewSnapshot = class(TInterfacedObject, IMachineOverviewSnapshot)
  private
    fAggregatorThreadId: Cardinal;
    fCapturedAtMonotonicMs: UInt64;
    fCapturedAtUtc: TDateTime;
    fHistoryRecordsDropped: Int64;
    fLastProviderId: string;
    fPresentation: TMachineOverviewPresentation;
    fRawSamplesConsumed: Int64;
    fRawSamplesDropped: Int64;
    fSequence: UInt64;
  public
    constructor Create(const aSequence, aCapturedAtMonotonicMs: UInt64;
      const aCapturedAtUtc: TDateTime; const aLastProviderId: string;
      const aRawSamplesConsumed, aRawSamplesDropped,
      aHistoryRecordsDropped: Int64; const aAggregatorThreadId: Cardinal;
      const aPresentation: TMachineOverviewPresentation);
    function Sequence: UInt64;
    function CapturedAtMonotonicMs: UInt64;
    function CapturedAtUtc: TDateTime;
    function LastProviderId: string;
    function RawSamplesConsumed: Int64;
    function RawSamplesDropped: Int64;
    function HistoryRecordsDropped: Int64;
    function AggregatorThreadId: Cardinal;
    function Presentation: TMachineOverviewPresentation;
  end;

  TMachineOverviewAggregatorThread = class(TThread)
  private
    fCpuAggregator: TMachineOverviewDomainAggregator;
    fIncidentDetector: TMachineOverviewIncidentDetector;
    fLastRecordsDropped: Int64;
    fLastCpuMonotonicMs: UInt64;
    fLatestLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
    fPipelineState: TMachineOverviewPipelineState;
    fProviderIds: TList<string>;
    fProviderSamples: TDictionary<string, TMachineOverviewProviderSample>;
    function BuildPresentation(const aSequence: UInt64;
      const aSample: IMachineOverviewRawSample): TMachineOverviewPresentation;
    function BuildIncidentSignals(
      const aSource: TMachineOverviewPresentationSource;
      const aSample: IMachineOverviewRawSample):
      TMachineOverviewIncidentSignals;
    procedure ProcessSample(const aSample: IMachineOverviewRawSample);
  protected
    procedure Execute; override;
  public
    constructor Create(const aPipelineState: TMachineOverviewPipelineState);
  end;

constructor TMachineOverviewPipelineState.Create(
  const aRawQueueCapacity, aHistoryQueueCapacity: Integer);
begin
  inherited Create;
  CounterLock := TCriticalSection.Create;
  IncidentLock := TCriticalSection.Create;
  Incidents := TDictionary<string, TMachineOverviewIncident>.Create;
  LifecycleLock := TCriticalSection.Create;
  MailboxLock := TCriticalSection.Create;
  ProviderDrops := TDictionary<string, Int64>.Create;
  StartedEvent := TEvent.Create(nil, True, False, '');
  SnapshotEvent := TEvent.Create(nil, False, False, '');
  HistoryEnabled := 1;
  RawQueue := TThreadedQueue<IMachineOverviewRawSample>.Create(
    aRawQueueCapacity, 0, 20);
  HistoryQueue := TThreadedQueue<IMachineOverviewRawSample>.Create(
    aHistoryQueueCapacity, 0, 0);
  IncidentQueue := TThreadedQueue<TMachineOverviewIncidentChange>.Create(
    aHistoryQueueCapacity, 0, 0);
  TraceQueue := TThreadedQueue<TMachineOverviewIncidentChange>.Create(
    cMachineOverviewTraceQueueCapacity, 0, 0);
end;

destructor TMachineOverviewPipelineState.Destroy;
begin
  if Assigned(RawQueue) then
    RawQueue.DoShutDown;
  if Assigned(HistoryQueue) then
    HistoryQueue.DoShutDown;
  if Assigned(IncidentQueue) then
    IncidentQueue.DoShutDown;
  if Assigned(TraceQueue) then
    TraceQueue.DoShutDown;
  FreeAndNil(TraceQueue);
  FreeAndNil(IncidentQueue);
  FreeAndNil(HistoryQueue);
  FreeAndNil(RawQueue);
  FreeAndNil(SnapshotEvent);
  FreeAndNil(StartedEvent);
  FreeAndNil(ProviderDrops);
  FreeAndNil(Incidents);
  FreeAndNil(IncidentLock);
  FreeAndNil(MailboxLock);
  FreeAndNil(LifecycleLock);
  FreeAndNil(CounterLock);
  inherited Destroy;
end;

procedure InsertLatestIncident(
  var aValues: TArray<TMachineOverviewIncident>;
  const aIncident: TMachineOverviewIncident);
var
  i: Integer;
  lInsertAt: Integer;
  lMaximumIndex: Integer;
begin
  lInsertAt := Length(aValues);
  for i := 0 to High(aValues) do
    if (aIncident.StartedAtUtc > aValues[i].StartedAtUtc) or
      ((aIncident.StartedAtUtc = aValues[i].StartedAtUtc) and
       (CompareText(aIncident.StableId, aValues[i].StableId) < 0)) then
    begin
      lInsertAt := i;
      Break;
    end;
  if (Length(aValues) >= 3) and (lInsertAt >= 3) then
    Exit;
  if Length(aValues) < 3 then
    SetLength(aValues, Length(aValues) + 1);
  lMaximumIndex := High(aValues);
  for i := lMaximumIndex downto lInsertAt + 1 do
    aValues[i] := aValues[i - 1];
  aValues[lInsertAt] := aIncident;
end;

procedure TMachineOverviewPipelineState.ApplyIncident(
  const aIncident: TMachineOverviewIncident);
begin
  if aIncident.StableId.IsEmpty then
    Exit;
  IncidentLock.Acquire;
  try
    Incidents.AddOrSetValue(aIncident.StableId, aIncident);
  finally
    IncidentLock.Release;
  end;
end;

procedure TMachineOverviewPipelineState.PublishIncidentChange(
  const aChange: TMachineOverviewIncidentChange);
begin
  ApplyIncident(aChange.Incident);
  if TInterlocked.CompareExchange(HistoryEnabled, 0, 0) = 0 then
    Exit;
  if IncidentQueue.PushItem(aChange) = wrSignaled then
    TInterlocked.Increment(HistoryAccepted)
  else
    TInterlocked.Increment(HistoryDropped);
end;

procedure TMachineOverviewPipelineState.RequestDetailedTrace(
  var aChange: TMachineOverviewIncidentChange);
begin
  if (TInterlocked.CompareExchange(DetailedTraceEnabled, 0, 0) = 0) or
    (aChange.Kind <> TMachineOverviewIncidentChangeKind.Started) or
    (aChange.Incident.TraceStatus <>
      TMachineOverviewIncidentTraceStatus.NotRequested) or
    (not ShouldCaptureMachineOverviewTrace(aChange.Incident)) then
    Exit;
  aChange.Incident.TraceStatus :=
    TMachineOverviewIncidentTraceStatus.Requested;
  if (TInterlocked.CompareExchange(Stopping, 0, 0) = 0) and
    (TraceQueue.PushItem(aChange) = wrSignaled) then
  begin
    TInterlocked.Increment(TraceAccepted);
    Exit;
  end;
  aChange.Incident.TraceStatus := TMachineOverviewIncidentTraceStatus.Failed;
  TInterlocked.Increment(TraceDropped);
end;

procedure TMachineOverviewPipelineState.FillIncidentPresentation(
  var aSource: TMachineOverviewPresentationSource;
  const aCapturedAtUtc: TDateTime);
var
  i: Integer;
  lCutoffUtc: TDateTime;
  lIncident: TMachineOverviewIncident;
  lLatest: TArray<TMachineOverviewIncident>;
begin
  aSource.IncidentCountLast24Hours := 0;
  aSource.Incidents := nil;
  lCutoffUtc := IncHour(aCapturedAtUtc, -24);
  IncidentLock.Acquire;
  try
    for lIncident in Incidents.Values do
      if lIncident.StartedAtUtc >= lCutoffUtc then
      begin
        Inc(aSource.IncidentCountLast24Hours);
        InsertLatestIncident(lLatest, lIncident);
      end;
  finally
    IncidentLock.Release;
  end;
  SetLength(aSource.Incidents, Length(lLatest));
  for i := 0 to High(lLatest) do
  begin
    aSource.Incidents[i].OccurredAtLocal :=
      TTimeZone.Local.ToLocalTime(lLatest[i].StartedAtUtc);
    aSource.Incidents[i].Summary := lLatest[i].Summary;
    aSource.Incidents[i].DiagnosticText := lLatest[i].Explanation +
      '; threshold ' + lLatest[i].ThresholdText;
    aSource.Incidents[i].Severity := lLatest[i].Severity;
  end;
end;

function TMachineOverviewPipelineState.TryReadLatest(
  const aAfterSequence: UInt64;
  out aSnapshot: IMachineOverviewSnapshot): Boolean;
begin
  aSnapshot := nil;
  MailboxLock.Acquire;
  try
    Result := Assigned(LatestSnapshot) and
      (LatestSnapshot.Sequence > aAfterSequence);
    if Result then
      aSnapshot := LatestSnapshot;
  finally
    MailboxLock.Release;
  end;
end;

function GetPipelineState(const aState: TObject): TMachineOverviewPipelineState;
begin
  Result := aState as TMachineOverviewPipelineState;
end;

constructor TMachineOverviewSnapshot.Create(
  const aSequence, aCapturedAtMonotonicMs: UInt64;
  const aCapturedAtUtc: TDateTime; const aLastProviderId: string;
  const aRawSamplesConsumed, aRawSamplesDropped,
  aHistoryRecordsDropped: Int64; const aAggregatorThreadId: Cardinal;
  const aPresentation: TMachineOverviewPresentation);
begin
  inherited Create;
  fSequence := aSequence;
  fCapturedAtMonotonicMs := aCapturedAtMonotonicMs;
  fCapturedAtUtc := aCapturedAtUtc;
  fLastProviderId := aLastProviderId;
  fRawSamplesConsumed := aRawSamplesConsumed;
  fRawSamplesDropped := aRawSamplesDropped;
  fHistoryRecordsDropped := aHistoryRecordsDropped;
  fAggregatorThreadId := aAggregatorThreadId;
  fPresentation := aPresentation;
  fPresentation.Rows := Copy(aPresentation.Rows);
end;

function TMachineOverviewSnapshot.AggregatorThreadId: Cardinal;
begin
  Result := fAggregatorThreadId;
end;

function TMachineOverviewSnapshot.CapturedAtMonotonicMs: UInt64;
begin
  Result := fCapturedAtMonotonicMs;
end;

function TMachineOverviewSnapshot.CapturedAtUtc: TDateTime;
begin
  Result := fCapturedAtUtc;
end;

function TMachineOverviewSnapshot.HistoryRecordsDropped: Int64;
begin
  Result := fHistoryRecordsDropped;
end;

function TMachineOverviewSnapshot.LastProviderId: string;
begin
  Result := fLastProviderId;
end;

function TMachineOverviewSnapshot.RawSamplesConsumed: Int64;
begin
  Result := fRawSamplesConsumed;
end;

function TMachineOverviewSnapshot.RawSamplesDropped: Int64;
begin
  Result := fRawSamplesDropped;
end;

function TMachineOverviewSnapshot.Presentation: TMachineOverviewPresentation;
begin
  Result := fPresentation;
  Result.Rows := Copy(fPresentation.Rows);
end;

function TMachineOverviewSnapshot.Sequence: UInt64;
begin
  Result := fSequence;
end;

function TryBuildCpuSample(const aSample: TMachineOverviewProviderSample;
  out aTotalCpu: TMachineOverviewOptionalDouble;
  out aLogicalProcessors: TArray<TMachineOverviewOptionalDouble>): Boolean;
var
  lCount: Integer;
  lIndex: Integer;
  lMeasurement: TMachineOverviewMeasurement;
begin
  aTotalCpu := Default(TMachineOverviewOptionalDouble);
  SetLength(aLogicalProcessors, 0);
  lCount := 0;
  for lMeasurement in aSample.Measurements do
    if StartsText('cpu_logical:', lMeasurement.Name) then
      Inc(lCount);
  SetLength(aLogicalProcessors, lCount);
  lIndex := 0;
  for lMeasurement in aSample.Measurements do
  begin
    if SameText(lMeasurement.Name, 'cpu_total_percent') then
    begin
      aTotalCpu.Available := lMeasurement.Available;
      aTotalCpu.Value := lMeasurement.Value;
    end else if StartsText('cpu_logical:', lMeasurement.Name) then
    begin
      aLogicalProcessors[lIndex].Available := lMeasurement.Available;
      aLogicalProcessors[lIndex].Value := lMeasurement.Value;
      Inc(lIndex);
    end;
  end;
  Result := aTotalCpu.Available or (lCount > 0);
end;

function TryFindPresentationMeasurement(
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

function QueueDepth(const aAccepted, aDequeued: Int64): Integer;
var
  lDepth: Int64;
begin
  lDepth := aAccepted - aDequeued;
  if lDepth <= 0 then
    Exit(0);
  if lDepth > High(Integer) then
    Exit(High(Integer));
  Result := Int64Rec(lDepth).Lo;
end;

function ProviderStaleAfterMs(const aProviderId: string): UInt64;
begin
  if SameText(aProviderId, 'processes') then
    Result := 6000
  else if SameText(aProviderId, 'temperature') then
    Result := 9000
  else if SameText(aProviderId, 'windows-core') or
    SameText(aProviderId, 'disks') or SameText(aProviderId, 'gpu') then
    Result := 3000
  else
    Result := 5000;
end;

procedure ConsiderOverallSeverity(var aSeverity: TMachineOverviewSeverity;
  var aReason: string; const aCandidate: TMachineOverviewSeverity;
  const aCandidateReason: string);
begin
  if Ord(aCandidate) > Ord(aSeverity) then
  begin
    aSeverity := aCandidate;
    aReason := aCandidateReason;
  end;
end;

procedure DetermineOverall(
  var aSource: TMachineOverviewPresentationSource);
var
  lHasSignal: Boolean;
  lMeasurement: TMachineOverviewMeasurement;
  lSeverity: TMachineOverviewSeverity;
begin
  lHasSignal := aSource.CpuAggregate.NowValue.Available;
  lSeverity := TMachineOverviewSeverity.Normal;
  aSource.OverallReason := 'no current warning threshold crossed';
  if aSource.CpuAggregate.NowValue.Available then
  begin
    if aSource.CpuAggregate.NowValue.Value >= 95 then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Critical, 'CPU load is critically high')
    else if aSource.CpuAggregate.NowValue.Value >= 85 then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Warning, 'CPU load is elevated');
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
      'foreground_reply_ms', lMeasurement) and lMeasurement.Available then
  begin
    lHasSignal := True;
    if lMeasurement.Value >= 1000 then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Critical,
        'foreground application response is stalled')
    else if lMeasurement.Value >= 250 then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Warning,
        'foreground application response is slow');
  end;
  if TryFindPresentationMeasurement(aSource.Measurements, 'disk_worst',
      lMeasurement) and lMeasurement.Available and
    SameText(lMeasurement.UnitText, 'severity') then
  begin
    lHasSignal := True;
    if Trunc(lMeasurement.Value) = Ord(TMachineOverviewSeverity.Critical) then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Critical,
        lMeasurement.DisplayText + ' is in a critical condition')
    else if Trunc(lMeasurement.Value) = Ord(TMachineOverviewSeverity.Warning) then
      ConsiderOverallSeverity(lSeverity, aSource.OverallReason,
        TMachineOverviewSeverity.Warning,
        lMeasurement.DisplayText + ' condition is elevated');
  end;
  if lHasSignal then
    aSource.OverallSeverity := lSeverity
  else
  begin
    aSource.OverallSeverity := TMachineOverviewSeverity.Unavailable;
    aSource.OverallReason := 'providers are warming up';
  end;
end;

procedure AddUniqueIncidentText(const aValue: string;
  const aValues: TList<string>);
begin
  if (not aValue.IsEmpty) and (not aValues.Contains(aValue)) then
    aValues.Add(aValue);
end;

function TryFindPipelineProviderState(
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

function TMachineOverviewAggregatorThread.BuildIncidentSignals(
  const aSource: TMachineOverviewPresentationSource;
  const aSample: IMachineOverviewRawSample):
  TMachineOverviewIncidentSignals;
var
  lCurrentDropped: Int64;
  lDiskId: string;
  lEntityIds: TList<string>;
  lExecutablePaths: TList<string>;
  lMeasurement: TMachineOverviewMeasurement;
  lProviderSample: TMachineOverviewProviderSample;
  lTemperatureCurrent: Boolean;
  lTemperatureState: TMachineOverviewProviderState;
begin
  Result := Default(TMachineOverviewIncidentSignals);
  Result.CapturedAtUtc := aSample.CapturedAtUtc;
  Result.CapturedAtMonotonicMs := aSample.CapturedAtMonotonicMs;
  Result.TotalCpu := aSource.CpuAggregate.NowValue;
  Result.HotLogicalProcessorCount :=
    aSource.CpuAggregate.HotLogicalProcessorCount;
  if TryFindPresentationMeasurement(aSource.Measurements, 'dpc_percent',
    lMeasurement) then
  begin
    Result.DpcPercent.Available := lMeasurement.Available;
    Result.DpcPercent.Value := lMeasurement.Value;
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
    'interrupt_percent', lMeasurement) then
  begin
    Result.InterruptPercent.Available := lMeasurement.Available;
    Result.InterruptPercent.Value := lMeasurement.Value;
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
    'foreground_reply_ms', lMeasurement) then
  begin
    Result.ForegroundReplyMs.Available := lMeasurement.Available;
    Result.ForegroundReplyMs.Value := lMeasurement.Value;
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
      'foreground_status', lMeasurement) and lMeasurement.Available then
    Result.ForegroundTimedOut := Round(lMeasurement.Value) =
      Ord(TMachineOverviewForegroundProbeStatus.TimedOut);
  if TryFindPresentationMeasurement(aSource.Measurements,
      'dwm_frames_missed_delta', lMeasurement) and lMeasurement.Available then
    Result.DwmMissedFrames := Max(0, Round(lMeasurement.Value));
  if TryFindPresentationMeasurement(aSource.Measurements,
    'physical_used_percent', lMeasurement) then
  begin
    Result.PhysicalUsedPercent.Available := lMeasurement.Available;
    Result.PhysicalUsedPercent.Value := lMeasurement.Value;
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
    'paging_bytes_per_sec', lMeasurement) then
  begin
    Result.PagingBytesPerSecond.Available := lMeasurement.Available;
    Result.PagingBytesPerSecond.Value := lMeasurement.Value;
  end;
  lDiskId := '';
  if TryFindPresentationMeasurement(aSource.Measurements, 'disk_worst',
    lMeasurement) then
    lDiskId := lMeasurement.EntityId;
  if not lDiskId.IsEmpty then
  begin
    if TryFindPresentationMeasurement(aSource.Measurements,
      'disk_active_percent:' + lDiskId, lMeasurement) then
    begin
      Result.DiskActivePercent.Available := lMeasurement.Available;
      Result.DiskActivePercent.Value := lMeasurement.Value;
    end;
    if TryFindPresentationMeasurement(aSource.Measurements,
      'disk_latency_ms:' + lDiskId, lMeasurement) then
    begin
      Result.DiskLatencyMs.Available := lMeasurement.Available;
      Result.DiskLatencyMs.Value := lMeasurement.Value;
    end;
    if TryFindPresentationMeasurement(aSource.Measurements,
      'disk_queue_length:' + lDiskId, lMeasurement) then
    begin
      Result.DiskQueueLength.Available := lMeasurement.Available;
      Result.DiskQueueLength.Value := lMeasurement.Value;
    end;
  end;
  if TryFindPresentationMeasurement(aSource.Measurements,
    'gpu_overall_percent', lMeasurement) then
  begin
    Result.GpuPercent.Available := lMeasurement.Available;
    Result.GpuPercent.Value := lMeasurement.Value;
  end;
  lTemperatureCurrent :=
    TryFindPipelineProviderState(aSource.ProviderStates, 'temperature',
      lTemperatureState) and
    MachineOverviewTemperatureIsCurrent(lTemperatureState.Status);
  if lTemperatureCurrent and TryFindPresentationMeasurement(aSource.Measurements,
    'gpu_temperature_c', lMeasurement) then
  begin
    Result.TemperatureCelsius.Available := lMeasurement.Available;
    Result.TemperatureCelsius.Value := lMeasurement.Value;
  end;
  if lTemperatureCurrent and TryFindPresentationMeasurement(aSource.Measurements,
      'cpu_package_temperature_c', lMeasurement) and
    lMeasurement.Available and
    ((not Result.TemperatureCelsius.Available) or
     (lMeasurement.Value > Result.TemperatureCelsius.Value)) then
  begin
    Result.TemperatureCelsius.Available := True;
    Result.TemperatureCelsius.Value := lMeasurement.Value;
  end;
  lProviderSample := aSample.ProviderSample;
  Result.ProviderId := aSample.ProviderId;
  Result.ProviderStatus := lProviderSample.State.Status;
  Result.ProviderFreshnessMs := lProviderSample.State.DataAgeMs;
  if SameText(Result.ProviderId, 'temperature') and
    (not MachineOverviewTemperatureAffectsProviderHealth(
      Result.ProviderStatus)) then
  begin
    Result.ProviderStatus := TMachineOverviewProviderStatus.Available;
    Result.ProviderFreshnessMs := 0;
  end;
  lCurrentDropped := aSource.RawSamplesDropped +
    aSource.HistoryRecordsDropped;
  if lCurrentDropped >= fLastRecordsDropped then
    Result.RecordsDroppedDelta := lCurrentDropped - fLastRecordsDropped;
  fLastRecordsDropped := lCurrentDropped;
  Result.SQLiteCommitDurationMs := aSource.LastSQLiteCommitDurationMs;
  Result.SQLiteError := aSource.LastSQLiteError;
  lEntityIds := TList<string>.Create;
  lExecutablePaths := TList<string>.Create;
  try
    for lMeasurement in aSource.Measurements do
    begin
      if lEntityIds.Count < 16 then
        AddUniqueIncidentText(lMeasurement.EntityId, lEntityIds);
      if (lExecutablePaths.Count < 16) and
        ((not ExtractFileDrive(lMeasurement.DetailText).IsEmpty) or
         StartsText('\\', lMeasurement.DetailText)) then
        AddUniqueIncidentText(lMeasurement.DetailText, lExecutablePaths);
    end;
    Result.RelatedEntityIds := lEntityIds.ToArray;
    Result.RelatedExecutablePaths := lExecutablePaths.ToArray;
  finally
    lExecutablePaths.Free;
    lEntityIds.Free;
  end;
  Result.ContextSummary := Result.ProviderId + '; ' +
    aSource.OverallReason;
end;

function TMachineOverviewAggregatorThread.BuildPresentation(
  const aSequence: UInt64;
  const aSample: IMachineOverviewRawSample): TMachineOverviewPresentation;
var
  lChange: TMachineOverviewIncidentChange;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lIncidentSignals: TMachineOverviewIncidentSignals;
  lMeasurement: TMachineOverviewMeasurement;
  lMeasurementCount: Integer;
  lMeasurementIndex: Integer;
  lProviderId: string;
  lProviderIndex: Integer;
  lProviderSample: TMachineOverviewProviderSample;
  lProviderState: TMachineOverviewProviderState;
  lSource: TMachineOverviewPresentationSource;
  lTransportAgeMs: UInt64;
  lTargetIndex: Integer;
  i: Integer;
begin
  lSource := Default(TMachineOverviewPresentationSource);
  lSource.CapturedAtUtc := aSample.CapturedAtUtc;
  lSource.CapturedAtMonotonicMs := aSample.CapturedAtMonotonicMs;
  lSource.Sequence := aSequence;
  lSource.CpuAggregate := fCpuAggregator.BuildCpuAggregate(
    aSample.CapturedAtMonotonicMs);
  lSource.LogicalProcessorValues := Copy(fLatestLogicalProcessors);
  SetLength(lSource.ProviderStates, fProviderIds.Count);
  lMeasurementCount := 0;
  for lProviderId in fProviderIds do
  begin
    lProviderSample := fProviderSamples[lProviderId];
    Inc(lMeasurementCount, Length(lProviderSample.Measurements));
  end;
  SetLength(lSource.Measurements, lMeasurementCount);
  lTargetIndex := 0;
  for lProviderIndex := 0 to fProviderIds.Count - 1 do
  begin
    lProviderId := fProviderIds[lProviderIndex];
    lProviderSample := fProviderSamples[lProviderId];
    lProviderState := lProviderSample.State;
    lProviderState.ProviderId := lProviderId;
    if aSample.CapturedAtMonotonicMs >=
      lProviderState.CapturedAtMonotonicMs then
      lTransportAgeMs := aSample.CapturedAtMonotonicMs -
        lProviderState.CapturedAtMonotonicMs
    else
      lTransportAgeMs := 0;
    if lTransportAgeMs > lProviderState.DataAgeMs then
      lProviderState.DataAgeMs := lTransportAgeMs;
    lProviderState.Status := MachineOverviewProviderStatusAt(lProviderState,
      aSample.CapturedAtMonotonicMs, ProviderStaleAfterMs(lProviderId));
    lSource.ProviderStates[lProviderIndex] := lProviderState;
    for lMeasurementIndex := 0 to High(lProviderSample.Measurements) do
    begin
      lSource.Measurements[lTargetIndex] :=
        lProviderSample.Measurements[lMeasurementIndex];
      Inc(lTargetIndex);
    end;
  end;
  lSource.RawQueueDepth := QueueDepth(
    TInterlocked.CompareExchange(fPipelineState.RawAccepted, 0, 0),
    TInterlocked.CompareExchange(fPipelineState.RawDequeued, 0, 0));
  lSource.RawSamplesDropped := TInterlocked.CompareExchange(
    fPipelineState.RawDropped, 0, 0);
  lSource.HistoryQueueDepth := QueueDepth(
    TInterlocked.CompareExchange(fPipelineState.HistoryAccepted, 0, 0),
    TInterlocked.CompareExchange(fPipelineState.HistoryDequeued, 0, 0));
  lSource.HistoryRecordsDropped := TInterlocked.CompareExchange(
    fPipelineState.HistoryDropped, 0, 0);
  lSource.SelfMetricsAvailable :=
    TryFindPresentationMeasurement(lSource.Measurements,
      'monitor_cpu_percent', lMeasurement) and lMeasurement.Available;
  if lSource.SelfMetricsAvailable then
    lSource.MonitorCpuPercent := lMeasurement.Value;
  lSource.SelfMetricsAvailable := lSource.SelfMetricsAvailable and
    TryFindPresentationMeasurement(lSource.Measurements,
      'monitor_private_bytes', lMeasurement) and lMeasurement.Available;
  if lSource.SelfMetricsAvailable then
    lSource.MonitorPrivateBytes := Round(lMeasurement.Value);
  lSource.SelfMetricsAvailable := lSource.SelfMetricsAvailable and
    TryFindPresentationMeasurement(lSource.Measurements,
      'monitor_write_bytes_per_second', lMeasurement) and
    lMeasurement.Available;
  if lSource.SelfMetricsAvailable then
    lSource.MonitorWriteBytesPerSecond := lMeasurement.Value;
  fPipelineState.CounterLock.Acquire;
  try
    Inc(lSource.HistoryQueueDepth,
      fPipelineState.HistoryWriterQueueDepth);
    lSource.HistoryRecordsDropped := lSource.HistoryRecordsDropped +
      fPipelineState.HistoryWriterDropped;
    lSource.LastSQLiteCommitAvailable :=
      fPipelineState.LastSQLiteCommitAvailable;
    lSource.LastSQLiteCommitDurationMs :=
      fPipelineState.LastSQLiteCommitDurationMs;
    lSource.LastSQLiteError := fPipelineState.LastSQLiteError;
  finally
    fPipelineState.CounterLock.Release;
  end;
  DetermineOverall(lSource);
  lIncidentSignals := BuildIncidentSignals(lSource, aSample);
  lChanges := fIncidentDetector.Accept(lIncidentSignals);
  for i := 0 to High(lChanges) do
  begin
    lChange := lChanges[i];
    fPipelineState.RequestDetailedTrace(lChange);
    fPipelineState.PublishIncidentChange(lChange);
  end;
  fPipelineState.FillIncidentPresentation(lSource, aSample.CapturedAtUtc);
  Result := BuildMachineOverviewPresentation(lSource);
end;

constructor TMachineOverviewAggregatorThread.Create(
  const aPipelineState: TMachineOverviewPipelineState);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fPipelineState := aPipelineState;
end;

procedure TMachineOverviewAggregatorThread.Execute;
var
  lSample: IMachineOverviewRawSample;
  lWaitResult: TWaitResult;
begin
  fCpuAggregator := nil;
  fIncidentDetector := nil;
  fProviderIds := nil;
  fProviderSamples := nil;
  TInterlocked.Increment(fPipelineState.ActiveWorkerCount);
  TInterlocked.Exchange(fPipelineState.AggregatorThreadId, Integer(GetCurrentThreadId));
  try
    fCpuAggregator := TMachineOverviewDomainAggregator.Create(1000, 80);
    fIncidentDetector := TMachineOverviewIncidentDetector.Create(
      TMachineOverviewIncidentThresholds.Defaults);
    fProviderIds := TList<string>.Create;
    fProviderSamples := TDictionary<string,
      TMachineOverviewProviderSample>.Create;
    fPipelineState.StartedEvent.SetEvent;
    while not Terminated do
    begin
      lSample := nil;
      lWaitResult := fPipelineState.RawQueue.PopItem(lSample);
      if (lWaitResult = wrSignaled) and Assigned(lSample) then
      begin
        TInterlocked.Increment(fPipelineState.RawDequeued);
        ProcessSample(lSample);
      end else if lWaitResult = wrAbandoned then
        Break;
    end;
  finally
    TInterlocked.Decrement(fPipelineState.ActiveWorkerCount);
    FreeAndNil(fProviderSamples);
    FreeAndNil(fProviderIds);
    FreeAndNil(fIncidentDetector);
    FreeAndNil(fCpuAggregator);
  end;
end;

procedure TMachineOverviewAggregatorThread.ProcessSample(
  const aSample: IMachineOverviewRawSample);
var
  lCpuSample: IMachineOverviewCpuSample;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lPresentation: TMachineOverviewPresentation;
  lProviderSample: TMachineOverviewProviderSample;
  lSnapshot: IMachineOverviewSnapshot;
  lSequence: Int64;
  lTotalCpu: TMachineOverviewOptionalDouble;
begin
  if TInterlocked.CompareExchange(
      fPipelineState.HistoryEnabled, 0, 0) <> 0 then
    if fPipelineState.HistoryQueue.PushItem(aSample) = wrSignaled then
      TInterlocked.Increment(fPipelineState.HistoryAccepted)
    else
      TInterlocked.Increment(fPipelineState.HistoryDropped);
  lProviderSample := aSample.ProviderSample;
  if not fProviderSamples.ContainsKey(aSample.ProviderId) then
  begin
    fProviderIds.Add(aSample.ProviderId);
    fProviderIds.Sort;
  end;
  fProviderSamples.AddOrSetValue(aSample.ProviderId, lProviderSample);
  if (aSample.CapturedAtMonotonicMs > fLastCpuMonotonicMs) and
    TryBuildCpuSample(lProviderSample, lTotalCpu, lLogicalProcessors) then
  begin
    lCpuSample := CreateMachineOverviewCpuSample(
      aSample.CapturedAtMonotonicMs, aSample.CapturedAtUtc, lTotalCpu,
      lLogicalProcessors);
    fCpuAggregator.AcceptCpuSample(lCpuSample);
    fLastCpuMonotonicMs := aSample.CapturedAtMonotonicMs;
    fLatestLogicalProcessors := Copy(lLogicalProcessors);
  end;
  lSequence := TInterlocked.CompareExchange(
    fPipelineState.SnapshotSequence, 0, 0) + 1;
  lPresentation := BuildPresentation(UInt64(lSequence), aSample);
  lSnapshot := TMachineOverviewSnapshot.Create(
    UInt64(lSequence),
    aSample.CapturedAtMonotonicMs,
    aSample.CapturedAtUtc,
    aSample.ProviderId,
    TInterlocked.CompareExchange(fPipelineState.RawDequeued, 0, 0),
    TInterlocked.CompareExchange(fPipelineState.RawDropped, 0, 0),
    TInterlocked.CompareExchange(fPipelineState.HistoryDropped, 0, 0),
    Cardinal(TInterlocked.CompareExchange(fPipelineState.AggregatorThreadId, 0, 0)),
    lPresentation);
  fPipelineState.MailboxLock.Acquire;
  try
    fPipelineState.LatestSnapshot := lSnapshot;
  finally
    fPipelineState.MailboxLock.Release;
  end;
  TInterlocked.Exchange(fPipelineState.SnapshotSequence, lSequence);
  fPipelineState.SnapshotEvent.SetEvent;
end;

constructor TMachineOverviewRawSample.Create(
  const aSample: TMachineOverviewProviderSample);
begin
  inherited Create;
  fSample := aSample;
  fSample.Measurements := Copy(aSample.Measurements);
end;

function TMachineOverviewRawSample.CapturedAtMonotonicMs: UInt64;
begin
  Result := fSample.State.CapturedAtMonotonicMs;
end;

function TMachineOverviewRawSample.CapturedAtUtc: TDateTime;
begin
  Result := fSample.State.CapturedAtUtc;
end;

function TMachineOverviewRawSample.ProviderId: string;
begin
  Result := fSample.State.ProviderId;
end;

function TMachineOverviewRawSample.ProviderSample: TMachineOverviewProviderSample;
begin
  Result := fSample;
  Result.Measurements := Copy(fSample.Measurements);
end;

class function TMachineOverviewMonotonicSchedule.Create(
  const aFirstDueMs, aIntervalMs: UInt64): TMachineOverviewMonotonicSchedule;
begin
  if aIntervalMs = 0 then
    raise EArgumentException.Create('Machine Overview schedule interval must be greater than zero');
  Result := Default(TMachineOverviewMonotonicSchedule);
  Result.fIntervalMs := aIntervalMs;
  Result.fNextDueMs := aFirstDueMs;
end;

function TMachineOverviewMonotonicSchedule.IsDue(
  const aNowMonotonicMs: UInt64): Boolean;
begin
  Result := aNowMonotonicMs >= fNextDueMs;
end;

procedure TMachineOverviewMonotonicSchedule.MarkCompleted(
  const aNowMonotonicMs: UInt64);
var
  lAdvanceCount: UInt64;
begin
  if aNowMonotonicMs < fNextDueMs then
    Exit;

  lAdvanceCount := ((aNowMonotonicMs - fNextDueMs) div fIntervalMs) + 1;
  if lAdvanceCount > (High(UInt64) - fNextDueMs) div fIntervalMs then
    fNextDueMs := High(UInt64)
  else
    fNextDueMs := fNextDueMs + (lAdvanceCount * fIntervalMs);
end;

function TMachineOverviewMonotonicSchedule.NextDueMs: UInt64;
begin
  Result := fNextDueMs;
end;

constructor TMachineOverviewPipeline.Create(
  const aRawQueueCapacity, aHistoryQueueCapacity: Integer);
begin
  inherited Create;
  if (aRawQueueCapacity <= 0) or (aHistoryQueueCapacity <= 0) then
    raise EArgumentException.Create('Machine Overview queue capacity must be greater than zero');
  fState := TMachineOverviewPipelineState.Create(aRawQueueCapacity, aHistoryQueueCapacity);
end;

destructor TMachineOverviewPipeline.Destroy;
var
  lState: TMachineOverviewPipelineState;
  lStopResult: TMachineOverviewShutdownResult;
  lWorker: TThread;
begin
  if not Assigned(fState) then
  begin
    inherited Destroy;
    Exit;
  end;
  lStopResult := StopInternal(5000);
  if lStopResult = TMachineOverviewShutdownResult.TimedOut then
  begin
    lState := GetPipelineState(fState);
    lState.LifecycleLock.Acquire;
    try
      lWorker := lState.Worker;
    finally
      lState.LifecycleLock.Release;
    end;
    if Assigned(lWorker) then
    begin
      lWorker.WaitFor;
      lState.LifecycleLock.Acquire;
      try
        if lState.Worker = lWorker then
          lState.Worker := nil;
      finally
        lState.LifecycleLock.Release;
      end;
      lWorker.Free;
    end;
  end;
  fState.Free;
  inherited Destroy;
end;

function TMachineOverviewPipeline.Diagnostics: TMachineOverviewPipelineDiagnostics;
var
  lState: TMachineOverviewPipelineState;
begin
  Result := Default(TMachineOverviewPipelineDiagnostics);
  lState := GetPipelineState(fState);
  Result.RawAccepted := TInterlocked.CompareExchange(lState.RawAccepted, 0, 0);
  Result.RawDequeued := TInterlocked.CompareExchange(lState.RawDequeued, 0, 0);
  Result.RawDropped := TInterlocked.CompareExchange(lState.RawDropped, 0, 0);
  Result.RawQueueDepth := lState.RawQueue.QueueSize;
  Result.HistoryQueueDepth := lState.HistoryQueue.QueueSize +
    lState.IncidentQueue.QueueSize;
  Result.HistoryAccepted := TInterlocked.CompareExchange(lState.HistoryAccepted, 0, 0);
  Result.HistoryDequeued := TInterlocked.CompareExchange(lState.HistoryDequeued, 0, 0);
  Result.HistoryDropped := TInterlocked.CompareExchange(lState.HistoryDropped, 0, 0);
  Result.TraceAccepted := TInterlocked.CompareExchange(lState.TraceAccepted, 0, 0);
  Result.TraceDequeued := TInterlocked.CompareExchange(lState.TraceDequeued, 0, 0);
  Result.TraceDropped := TInterlocked.CompareExchange(lState.TraceDropped, 0, 0);
  Result.TraceQueueDepth := lState.TraceQueue.QueueSize;
  Result.ActiveWorkerCount := TInterlocked.CompareExchange(lState.ActiveWorkerCount, 0, 0);
  Result.AggregatorThreadId := Cardinal(
    TInterlocked.CompareExchange(lState.AggregatorThreadId, 0, 0));
end;

function TMachineOverviewPipeline.EnqueueRaw(
  const aSample: IMachineOverviewRawSample): TMachineOverviewEnqueueResult;
var
  lDropped: Int64;
  lProviderId: string;
  lState: TMachineOverviewPipelineState;
begin
  if not Assigned(aSample) then
    raise EArgumentNilException.Create('Machine Overview raw sample is required');

  lState := GetPipelineState(fState);
  if TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0 then
    Exit(TMachineOverviewEnqueueResult.Stopped);
  if lState.RawQueue.PushItem(aSample) = wrSignaled then
  begin
    TInterlocked.Increment(lState.RawAccepted);
    Exit(TMachineOverviewEnqueueResult.Queued);
  end;
  if TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0 then
    Exit(TMachineOverviewEnqueueResult.Stopped);

  TInterlocked.Increment(lState.RawDropped);
  lProviderId := LowerCase(Trim(aSample.ProviderId));
  if lProviderId.IsEmpty then
    lProviderId := '<unknown>';
  lState.CounterLock.Acquire;
  try
    if not lState.ProviderDrops.TryGetValue(lProviderId, lDropped) then
      lDropped := 0;
    lState.ProviderDrops.AddOrSetValue(lProviderId, lDropped + 1);
  finally
    lState.CounterLock.Release;
  end;
  Result := TMachineOverviewEnqueueResult.Full;
end;

function TMachineOverviewPipeline.IsRunning: Boolean;
begin
  Result := IsWorkerRunning;
end;

function TMachineOverviewPipeline.IncidentCount: Integer;
var
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  lState.IncidentLock.Acquire;
  try
    Result := lState.Incidents.Count;
  finally
    lState.IncidentLock.Release;
  end;
end;

procedure TMachineOverviewPipeline.MergePersistedIncidents(
  const aIncidents: TArray<TMachineOverviewIncident>);
var
  lIncident: TMachineOverviewIncident;
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  for lIncident in aIncidents do
    lState.ApplyIncident(lIncident);
end;

function TMachineOverviewPipeline.IsWorkerRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(
    GetPipelineState(fState).ActiveWorkerCount, 0, 0) <> 0;
end;

function TMachineOverviewPipeline.RawDroppedForProvider(
  const aProviderId: string): Int64;
var
  lProviderId: string;
  lState: TMachineOverviewPipelineState;
begin
  Result := 0;
  lProviderId := LowerCase(Trim(aProviderId));
  if lProviderId.IsEmpty then
    lProviderId := '<unknown>';
  lState := GetPipelineState(fState);
  lState.CounterLock.Acquire;
  try
    lState.ProviderDrops.TryGetValue(lProviderId, Result);
  finally
    lState.CounterLock.Release;
  end;
end;

procedure TMachineOverviewPipeline.Start;
var
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  lState.LifecycleLock.Acquire;
  try
    if (TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0) or
      Assigned(lState.Worker) then
      Exit;
    lState.StartedEvent.ResetEvent;
    lState.Worker := TMachineOverviewAggregatorThread.Create(lState);
    try
      lState.Worker.Start;
    except
      lState.Worker.Free;
      lState.Worker := nil;
      raise;
    end;
  finally
    lState.LifecycleLock.Release;
  end;
end;

function TMachineOverviewPipeline.Stop(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
begin
  Result := StopInternal(aTimeoutMs);
end;

function TMachineOverviewPipeline.StopInternal(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
var
  lState: TMachineOverviewPipelineState;
  lWaitResult: Cardinal;
  lWorker: TThread;
begin
  lState := GetPipelineState(fState);
  lState.LifecycleLock.Acquire;
  try
    if TInterlocked.Exchange(lState.Stopping, 1) = 0 then
    begin
      lState.RawQueue.DoShutDown;
      lState.TraceQueue.DoShutDown;
    end;
    lWorker := lState.Worker;
    if not Assigned(lWorker) then
      Exit(TMachineOverviewShutdownResult.Stopped);
    lWorker.Terminate;
    lWaitResult := WaitForSingleObject(lWorker.Handle, aTimeoutMs);
    if lWaitResult <> WAIT_OBJECT_0 then
      Exit(TMachineOverviewShutdownResult.TimedOut);
    lState.Worker := nil;
  finally
    lState.LifecycleLock.Release;
  end;
  lWorker.Free;
  Result := TMachineOverviewShutdownResult.Stopped;
end;

function TMachineOverviewPipeline.TryReadLatest(const aAfterSequence: UInt64;
  out aSnapshot: IMachineOverviewSnapshot): Boolean;
begin
  Result := TryReadLatestInternal(aAfterSequence, aSnapshot);
end;

function TMachineOverviewPipeline.TryReadLatestInternal(
  const aAfterSequence: UInt64;
  out aSnapshot: IMachineOverviewSnapshot): Boolean;
var
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  Result := lState.TryReadLatest(aAfterSequence, aSnapshot);
end;

function TMachineOverviewPipeline.TryTakeHistory(
  out aSample: IMachineOverviewRawSample): Boolean;
var
  lState: TMachineOverviewPipelineState;
begin
  aSample := nil;
  lState := GetPipelineState(fState);
  Result := lState.HistoryQueue.PopItem(aSample) = wrSignaled;
  if Result then
    TInterlocked.Increment(lState.HistoryDequeued);
end;

function TMachineOverviewPipeline.TryTakeIncident(
  out aChange: TMachineOverviewIncidentChange): Boolean;
var
  lState: TMachineOverviewPipelineState;
begin
  aChange := Default(TMachineOverviewIncidentChange);
  lState := GetPipelineState(fState);
  Result := lState.IncidentQueue.PopItem(aChange) = wrSignaled;
  if Result then
    TInterlocked.Increment(lState.HistoryDequeued);
end;

function TMachineOverviewPipeline.TryTakeDetailedTrace(
  out aChange: TMachineOverviewIncidentChange): Boolean;
var
  lState: TMachineOverviewPipelineState;
begin
  aChange := Default(TMachineOverviewIncidentChange);
  lState := GetPipelineState(fState);
  Result := lState.TraceQueue.PopItem(aChange) = wrSignaled;
  if Result then
    TInterlocked.Increment(lState.TraceDequeued);
end;

function TMachineOverviewPipeline.TryRequestDetailedTrace(
  var aChange: TMachineOverviewIncidentChange): Boolean;
var
  lWasNotRequested: Boolean;
begin
  lWasNotRequested := aChange.Incident.TraceStatus =
    TMachineOverviewIncidentTraceStatus.NotRequested;
  GetPipelineState(fState).RequestDetailedTrace(aChange);
  Result := lWasNotRequested and
    (aChange.Incident.TraceStatus =
     TMachineOverviewIncidentTraceStatus.Requested);
end;

procedure TMachineOverviewPipeline.PublishDetailedTraceResult(
  const aChange: TMachineOverviewIncidentChange);
begin
  GetPipelineState(fState).PublishIncidentChange(aChange);
end;

procedure TMachineOverviewPipeline.SetDetailedTraceEnabled(
  const aEnabled: Boolean);
begin
  TInterlocked.Exchange(GetPipelineState(fState).DetailedTraceEnabled,
    Ord(aEnabled));
end;

procedure TMachineOverviewPipeline.SetHistoryEnabled(
  const aEnabled: Boolean);
begin
  TInterlocked.Exchange(GetPipelineState(fState).HistoryEnabled,
    Ord(aEnabled));
end;

procedure TMachineOverviewPipeline.UpdateHistoryWriterDiagnostics(
  const aQueueDepth: Integer; const aDropped: Int64;
  const aLastCommitAvailable: Boolean;
  const aLastCommitDurationMs: UInt64; const aLastError: string);
var
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  lState.CounterLock.Acquire;
  try
    lState.HistoryWriterQueueDepth := Max(0, aQueueDepth);
    lState.HistoryWriterDropped := Max(Int64(0), aDropped);
    lState.LastSQLiteCommitAvailable := aLastCommitAvailable;
    lState.LastSQLiteCommitDurationMs := aLastCommitDurationMs;
    lState.LastSQLiteError := aLastError;
  finally
    lState.CounterLock.Release;
  end;
end;

function TMachineOverviewPipeline.WaitForSequence(const aSequence: UInt64;
  const aTimeoutMs: Cardinal): Boolean;
var
  lElapsedMs: Cardinal;
  lRemainingMs: Cardinal;
  lSequence: Int64;
  lStartedAtMs: Cardinal;
  lState: TMachineOverviewPipelineState;
begin
  Result := False;
  if aSequence > UInt64(High(Int64)) then
    Exit;
  lState := GetPipelineState(fState);
  lStartedAtMs := GetTickCount;
  repeat
    lSequence := TInterlocked.CompareExchange(lState.SnapshotSequence, 0, 0);
    if UInt64(lSequence) >= aSequence then
      Exit(True);
    lElapsedMs := GetTickCount - lStartedAtMs;
    if lElapsedMs >= aTimeoutMs then
      Exit;
    lRemainingMs := aTimeoutMs - lElapsedMs;
  until lState.SnapshotEvent.WaitFor(lRemainingMs) <> wrSignaled;
end;

function TMachineOverviewPipeline.WaitUntilRunning(
  const aTimeoutMs: Cardinal): Boolean;
var
  lState: TMachineOverviewPipelineState;
begin
  lState := GetPipelineState(fState);
  Result := IsWorkerRunning;
  if not Result then
    Result := (lState.StartedEvent.WaitFor(aTimeoutMs) = wrSignaled) and
      IsWorkerRunning;
end;

function TMachineOverviewSnapshotCursor.Frozen: Boolean;
begin
  Result := fFrozen;
end;

function TMachineOverviewSnapshotCursor.LastSequence: UInt64;
begin
  Result := fLastSequence;
end;

procedure TMachineOverviewSnapshotCursor.SetFrozen(const aValue: Boolean);
begin
  fFrozen := aValue;
end;

function TMachineOverviewSnapshotCursor.TryRead(
  const aPipeline: TMachineOverviewPipeline;
  out aSnapshot: IMachineOverviewSnapshot): Boolean;
begin
  aSnapshot := nil;
  Result := (not fFrozen) and Assigned(aPipeline) and
    aPipeline.TryReadLatestInternal(fLastSequence, aSnapshot);
  if Result then
    fLastSequence := aSnapshot.Sequence;
end;

function CreateMachineOverviewRawSample(
  const aSample: TMachineOverviewProviderSample): IMachineOverviewRawSample;
begin
  Result := TMachineOverviewRawSample.Create(aSample);
end;

end.

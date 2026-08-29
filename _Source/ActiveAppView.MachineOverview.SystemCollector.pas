unit ActiveAppView.MachineOverview.SystemCollector;

interface

uses
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewProviderFactory = function: IMachineOverviewProvider;

  TMachineOverviewSystemCollectorDiagnostics = record
    ActiveWorkerCount: Integer;
    WorkerThreadId: Cardinal;
    SamplesCollected: Int64;
    SamplesQueued: Int64;
    SamplesDropped: Int64;
    SamplesStopped: Int64;
    LastCollectDurationMs: UInt64;
  end;

  TMachineOverviewSystemCollector = class
  private
    fActiveWorkerCount: Integer;
    fIntervalMs: UInt64;
    fLastCollectDurationMs: Int64;
    fLifecycleLock: TObject;
    fPipeline: TMachineOverviewPipeline;
    fSamplesCollected: Int64;
    fSamplesDropped: Int64;
    fSamplesQueued: Int64;
    fSamplesStopped: Int64;
    fStartedEvent: TObject;
    fStopEvent: TObject;
    fStopping: Integer;
    fWorker: TObject;
    fWorkerThreadId: Integer;
    fProviderFactory: TMachineOverviewProviderFactory;
    procedure CollectOnce(var aProvider: IMachineOverviewProvider);
    procedure Initialize(const aPipeline: TMachineOverviewPipeline;
      const aIntervalMs: UInt64;
      const aProviderFactory: TMachineOverviewProviderFactory);
    function IsRunning: Boolean;
    function StopInternal(const aTimeoutMs: Cardinal):
      TMachineOverviewShutdownResult;
  public
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aIntervalMs: UInt64); overload;
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aIntervalMs: UInt64;
      const aProviderFactory: TMachineOverviewProviderFactory); overload;
    destructor Destroy; override;
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function WaitUntilRunning(const aTimeoutMs: Cardinal): Boolean;
    function Diagnostics: TMachineOverviewSystemCollectorDiagnostics;
  end;

implementation

uses
  System.Classes, System.DateUtils, System.SyncObjs, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.MachineOverview.WindowsProviders;

type
  TMachineOverviewSystemCollectorThread = class(TThread)
  private
    fCollector: TMachineOverviewSystemCollector;
  protected
    procedure Execute; override;
  public
    constructor Create(const aCollector: TMachineOverviewSystemCollector);
  end;

function GetCollectorLock(const aLock: TObject): TCriticalSection;
begin
  Result := aLock as TCriticalSection;
end;

function GetCollectorEvent(const aEvent: TObject): TEvent;
begin
  Result := aEvent as TEvent;
end;

function GetCollectorThread(const aThread: TObject): TThread;
begin
  Result := aThread as TThread;
end;

constructor TMachineOverviewSystemCollectorThread.Create(
  const aCollector: TMachineOverviewSystemCollector);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fCollector := aCollector;
end;

procedure TMachineOverviewSystemCollectorThread.Execute;
var
  lDifferenceMs: UInt64;
  lNowMs: UInt64;
  lProvider: IMachineOverviewProvider;
  lSchedule: TMachineOverviewMonotonicSchedule;
  lWaitMs: Cardinal;
begin
  TInterlocked.Increment(fCollector.fActiveWorkerCount);
  TInterlocked.Exchange(fCollector.fWorkerThreadId, Integer(GetCurrentThreadId));
  GetCollectorEvent(fCollector.fStartedEvent).SetEvent;
  try
    lSchedule := TMachineOverviewMonotonicSchedule.Create(GetTickCount64,
      fCollector.fIntervalMs);
    while (not Terminated) and
      (TInterlocked.CompareExchange(fCollector.fStopping, 0, 0) = 0) do
    begin
      lNowMs := GetTickCount64;
      if lSchedule.IsDue(lNowMs) then
      begin
        fCollector.CollectOnce(lProvider);
        lSchedule.MarkCompleted(GetTickCount64);
      end;
      if Terminated or
        (TInterlocked.CompareExchange(fCollector.fStopping, 0, 0) <> 0) then
        Break;
      lNowMs := GetTickCount64;
      if lSchedule.NextDueMs <= lNowMs then
        lWaitMs := 0
      else
      begin
        lDifferenceMs := lSchedule.NextDueMs - lNowMs;
        if lDifferenceMs > High(Cardinal) then
          lWaitMs := High(Cardinal)
        else
          lWaitMs := Int64Rec(lDifferenceMs).Lo;
      end;
      if GetCollectorEvent(fCollector.fStopEvent).WaitFor(lWaitMs) = wrSignaled then
        Break;
    end;
  finally
    TInterlocked.Decrement(fCollector.fActiveWorkerCount);
  end;
end;

constructor TMachineOverviewSystemCollector.Create(
  const aPipeline: TMachineOverviewPipeline; const aIntervalMs: UInt64);
begin
  inherited Create;
  Initialize(aPipeline, aIntervalMs, CreateMachineOverviewWindowsProvider);
end;

constructor TMachineOverviewSystemCollector.Create(
  const aPipeline: TMachineOverviewPipeline; const aIntervalMs: UInt64;
  const aProviderFactory: TMachineOverviewProviderFactory);
begin
  inherited Create;
  Initialize(aPipeline, aIntervalMs, aProviderFactory);
end;

procedure TMachineOverviewSystemCollector.Initialize(
  const aPipeline: TMachineOverviewPipeline; const aIntervalMs: UInt64;
  const aProviderFactory: TMachineOverviewProviderFactory);
var
  lLifecycleLock: TCriticalSection;
  lStartedEvent: TEvent;
  lStopEvent: TEvent;
begin
  if not Assigned(aPipeline) then
    raise EArgumentNilException.Create('Machine Overview pipeline is required');
  if aIntervalMs = 0 then
    raise EArgumentOutOfRangeException.Create(
      'Machine Overview system interval must be greater than zero');
  if not Assigned(aProviderFactory) then
    raise EArgumentNilException.Create(
      'Machine Overview provider factory is required');
  fPipeline := aPipeline;
  fIntervalMs := aIntervalMs;
  fProviderFactory := aProviderFactory;
  lLifecycleLock := TCriticalSection.Create;
  try
    lStartedEvent := TEvent.Create(nil, True, False, '');
    try
      lStopEvent := TEvent.Create(nil, True, False, '');
    except
      lStartedEvent.Free;
      raise;
    end;
  except
    lLifecycleLock.Free;
    raise;
  end;
  fLifecycleLock := lLifecycleLock;
  fStartedEvent := lStartedEvent;
  fStopEvent := lStopEvent;
end;

destructor TMachineOverviewSystemCollector.Destroy;
var
  lThread: TThread;
begin
  if Assigned(fLifecycleLock) and
    (StopInternal(5000) = TMachineOverviewShutdownResult.TimedOut) then
  begin
    GetCollectorLock(fLifecycleLock).Acquire;
    try
      lThread := GetCollectorThread(fWorker);
      if Assigned(lThread) then
      begin
        lThread.Terminate;
        GetCollectorEvent(fStopEvent).SetEvent;
      end;
    finally
      GetCollectorLock(fLifecycleLock).Release;
    end;
    if Assigned(lThread) then
    begin
      lThread.WaitFor;
      GetCollectorLock(fLifecycleLock).Acquire;
      try
        if fWorker = lThread then
          fWorker := nil;
      finally
        GetCollectorLock(fLifecycleLock).Release;
      end;
      lThread.Free;
    end;
  end;
  fStopEvent.Free;
  fStartedEvent.Free;
  fLifecycleLock.Free;
  inherited Destroy;
end;

procedure TMachineOverviewSystemCollector.CollectOnce(
  var aProvider: IMachineOverviewProvider);
var
  lDurationMs: UInt64;
  lEnqueueResult: TMachineOverviewEnqueueResult;
  lMeasurement: TMachineOverviewMeasurement;
  lMeasurementIndex: Integer;
  lProviderId: string;
  lSample: TMachineOverviewProviderSample;
  lStartedMs: UInt64;
begin
  lStartedMs := GetTickCount64;
  lProviderId := 'unknown';
  try
    if not Assigned(aProvider) then
      aProvider := fProviderFactory();
    lProviderId := aProvider.ProviderId;
    if lProviderId.IsEmpty then
      lProviderId := 'unknown';
    aProvider.Collect(lSample);
  except
    on lException: Exception do
    begin
      aProvider := nil;
      lSample := Default(TMachineOverviewProviderSample);
      lSample.State.ProviderId := lProviderId;
      lSample.State.Status := TMachineOverviewProviderStatus.Failed;
      lSample.State.CapturedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
      lSample.State.CapturedAtMonotonicMs := GetTickCount64;
      lSample.State.ErrorText := Format('%s: %s',
        [lException.ClassName, lException.Message]);
    end;
  end;
  lDurationMs := GetTickCount64 - lStartedMs;
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := 'collector_duration_ms:' + lProviderId;
  lMeasurement.UnitText := 'milliseconds';
  lMeasurement.Available := True;
  lMeasurement.Value := lDurationMs;
  lMeasurementIndex := Length(lSample.Measurements);
  SetLength(lSample.Measurements, lMeasurementIndex + 1);
  lSample.Measurements[lMeasurementIndex] := lMeasurement;
  TInterlocked.Exchange(fLastCollectDurationMs, Int64(lDurationMs));
  TInterlocked.Increment(fSamplesCollected);
  lEnqueueResult := fPipeline.EnqueueRaw(CreateMachineOverviewRawSample(lSample));
  case lEnqueueResult of
    TMachineOverviewEnqueueResult.Queued:
      TInterlocked.Increment(fSamplesQueued);
    TMachineOverviewEnqueueResult.Full:
      TInterlocked.Increment(fSamplesDropped);
    TMachineOverviewEnqueueResult.Stopped:
      TInterlocked.Increment(fSamplesStopped);
  end;
end;

function TMachineOverviewSystemCollector.Diagnostics:
  TMachineOverviewSystemCollectorDiagnostics;
begin
  Result := Default(TMachineOverviewSystemCollectorDiagnostics);
  Result.ActiveWorkerCount := TInterlocked.CompareExchange(
    fActiveWorkerCount, 0, 0);
  Result.WorkerThreadId := Cardinal(TInterlocked.CompareExchange(
    fWorkerThreadId, 0, 0));
  Result.SamplesCollected := TInterlocked.CompareExchange(
    fSamplesCollected, 0, 0);
  Result.SamplesQueued := TInterlocked.CompareExchange(fSamplesQueued, 0, 0);
  Result.SamplesDropped := TInterlocked.CompareExchange(fSamplesDropped, 0, 0);
  Result.SamplesStopped := TInterlocked.CompareExchange(fSamplesStopped, 0, 0);
  Result.LastCollectDurationMs := UInt64(TInterlocked.CompareExchange(
    fLastCollectDurationMs, 0, 0));
end;

function TMachineOverviewSystemCollector.IsRunning: Boolean;
begin
  Result := TInterlocked.CompareExchange(fActiveWorkerCount, 0, 0) > 0;
end;

procedure TMachineOverviewSystemCollector.Start;
var
  lThread: TThread;
begin
  if not Assigned(fLifecycleLock) then
    Exit;
  GetCollectorLock(fLifecycleLock).Acquire;
  try
    if (TInterlocked.CompareExchange(fStopping, 0, 0) <> 0) or
      Assigned(fWorker) then
      Exit;
    GetCollectorEvent(fStartedEvent).ResetEvent;
    GetCollectorEvent(fStopEvent).ResetEvent;
    lThread := TMachineOverviewSystemCollectorThread.Create(Self);
    fWorker := lThread;
    try
      lThread.Start;
    except
      fWorker := nil;
      lThread.Free;
      raise;
    end;
  finally
    GetCollectorLock(fLifecycleLock).Release;
  end;
end;

function TMachineOverviewSystemCollector.Stop(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
begin
  Result := StopInternal(aTimeoutMs);
end;

function TMachineOverviewSystemCollector.StopInternal(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
var
  lThread: TThread;
  lWaitResult: Cardinal;
begin
  if not Assigned(fLifecycleLock) then
    Exit(TMachineOverviewShutdownResult.Stopped);
  GetCollectorLock(fLifecycleLock).Acquire;
  try
    if TInterlocked.Exchange(fStopping, 1) = 0 then
      GetCollectorEvent(fStopEvent).SetEvent;
    lThread := GetCollectorThread(fWorker);
    if not Assigned(lThread) then
      Exit(TMachineOverviewShutdownResult.Stopped);
    lThread.Terminate;
    lWaitResult := WaitForSingleObject(lThread.Handle, aTimeoutMs);
    if lWaitResult <> WAIT_OBJECT_0 then
      Exit(TMachineOverviewShutdownResult.TimedOut);
    fWorker := nil;
  finally
    GetCollectorLock(fLifecycleLock).Release;
  end;
  lThread.Free;
  Result := TMachineOverviewShutdownResult.Stopped;
end;

function TMachineOverviewSystemCollector.WaitUntilRunning(
  const aTimeoutMs: Cardinal): Boolean;
begin
  Result := IsRunning;
  if not Result then
    Result := (GetCollectorEvent(fStartedEvent).WaitFor(aTimeoutMs) = wrSignaled) and
      IsRunning;
end;

end.

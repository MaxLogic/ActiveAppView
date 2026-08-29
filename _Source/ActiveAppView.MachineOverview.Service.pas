unit ActiveAppView.MachineOverview.Service;

interface

uses
  ActiveAppView.MachineOverview.Settings, ActiveAppView.MachineOverview.Types;

type
  IMachineOverviewService = interface(IInterface)
    ['{706D68D5-04A8-40C9-B773-7D94483DE8BD}']
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function IsRunning: Boolean;
    function ActiveWorkerCount: Integer;
    function TryReadLatestPresentation(const aAfterSequence: UInt64;
      out aPresentation: TMachineOverviewPresentation): Boolean;
  end;

function CreateMachineOverviewService(
  const aSettings: TMachineOverviewSettings): IMachineOverviewService;

implementation

uses
  Winapi.Windows,
  ActiveAppView.MachineOverview.DiskProvider,
  ActiveAppView.MachineOverview.GpuProvider,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.ProcessProvider,
  ActiveAppView.MachineOverview.SystemCollector,
  ActiveAppView.MachineOverview.TemperatureProvider,
  ActiveAppView.MachineOverview.Trace;

type
  TMachineOverviewService = class(TInterfacedObject, IMachineOverviewService)
  private
    fDiskCollector: TMachineOverviewSystemCollector;
    fGpuCollector: TMachineOverviewSystemCollector;
    fHistory: TMachineOverviewHistoryService;
    fPipeline: TMachineOverviewPipeline;
    fProcessCollector: TMachineOverviewSystemCollector;
    fRunning: Boolean;
    fSystemCollector: TMachineOverviewSystemCollector;
    fTemperatureCollector: TMachineOverviewSystemCollector;
    fTrace: TMachineOverviewTraceService;
  public
    constructor Create(const aSettings: TMachineOverviewSettings);
    destructor Destroy; override;
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function IsRunning: Boolean;
    function ActiveWorkerCount: Integer;
    function TryReadLatestPresentation(const aAfterSequence: UInt64;
      out aPresentation: TMachineOverviewPresentation): Boolean;
  end;

constructor TMachineOverviewService.Create(const aSettings: TMachineOverviewSettings);
var
  lHistoryConfig: TMachineOverviewHistoryConfig;
  lProcessIntervalMs: UInt64;
  lSystemIntervalMs: UInt64;
  lTemperatureIntervalMs: UInt64;
  lTraceConfig: TMachineOverviewTraceConfig;
begin
  inherited Create;
  if aSettings.Enabled then
  begin
    fPipeline := TMachineOverviewPipeline.Create(256, 4096);
    try
      fPipeline.SetHistoryEnabled(aSettings.HistoryEnabled);
      lHistoryConfig := TMachineOverviewHistoryConfig.FromSettings(aSettings,
        aSettings.HistoryDatabaseFileName);
      fHistory := TMachineOverviewHistoryService.Create(fPipeline,
        lHistoryConfig);
      lTraceConfig := TMachineOverviewTraceConfig.Defaults;
      lTraceConfig.Enabled := aSettings.DetailedTraceEnabled;
      fPipeline.SetDetailedTraceEnabled(lTraceConfig.Enabled);
      fTrace := TMachineOverviewTraceService.Create(fPipeline, lTraceConfig);
      if aSettings.SystemSampleIntervalMs > 0 then
        lSystemIntervalMs := UInt64(aSettings.SystemSampleIntervalMs)
      else
        lSystemIntervalMs := UInt64(
          TMachineOverviewSettings.Defaults.SystemSampleIntervalMs);
      if aSettings.ProcessSampleIntervalMs > 0 then
        lProcessIntervalMs := UInt64(aSettings.ProcessSampleIntervalMs)
      else
        lProcessIntervalMs := UInt64(
          TMachineOverviewSettings.Defaults.ProcessSampleIntervalMs);
      if aSettings.TemperatureSampleIntervalMs > 0 then
        lTemperatureIntervalMs := UInt64(aSettings.TemperatureSampleIntervalMs)
      else
        lTemperatureIntervalMs := UInt64(
          TMachineOverviewSettings.Defaults.TemperatureSampleIntervalMs);
      fSystemCollector := TMachineOverviewSystemCollector.Create(fPipeline,
        lSystemIntervalMs);
      fDiskCollector := TMachineOverviewSystemCollector.Create(fPipeline,
        lSystemIntervalMs, CreateMachineOverviewDiskProvider);
      fGpuCollector := TMachineOverviewSystemCollector.Create(fPipeline,
        lSystemIntervalMs, CreateMachineOverviewGpuProvider);
      fTemperatureCollector := TMachineOverviewSystemCollector.Create(
        fPipeline, lTemperatureIntervalMs,
        CreateMachineOverviewTemperatureProvider);
      fProcessCollector := TMachineOverviewSystemCollector.Create(fPipeline,
        lProcessIntervalMs, CreateMachineOverviewProcessProvider);
    except
      fHistory.Free;
      fHistory := nil;
      fTrace.Free;
      fTrace := nil;
      fProcessCollector.Free;
      fProcessCollector := nil;
      fTemperatureCollector.Free;
      fTemperatureCollector := nil;
      fGpuCollector.Free;
      fGpuCollector := nil;
      fDiskCollector.Free;
      fDiskCollector := nil;
      fSystemCollector.Free;
      fSystemCollector := nil;
      fPipeline.Free;
      fPipeline := nil;
      raise;
    end;
  end;
end;

destructor TMachineOverviewService.Destroy;
var
  lShutdownResult: TMachineOverviewShutdownResult;
begin
  lShutdownResult := Stop(5000);
  if lShutdownResult = TMachineOverviewShutdownResult.TimedOut then
    OutputDebugString('Machine Overview service destructor shutdown timed out');
  fProcessCollector.Free;
  fTemperatureCollector.Free;
  fGpuCollector.Free;
  fDiskCollector.Free;
  fSystemCollector.Free;
  fTrace.Free;
  fHistory.Free;
  fPipeline.Free;
  inherited Destroy;
end;

function TMachineOverviewService.ActiveWorkerCount: Integer;
begin
  Result := 0;
  if Assigned(fSystemCollector) then
    Inc(Result, fSystemCollector.Diagnostics.ActiveWorkerCount);
  if Assigned(fDiskCollector) then
    Inc(Result, fDiskCollector.Diagnostics.ActiveWorkerCount);
  if Assigned(fProcessCollector) then
    Inc(Result, fProcessCollector.Diagnostics.ActiveWorkerCount);
  if Assigned(fGpuCollector) then
    Inc(Result, fGpuCollector.Diagnostics.ActiveWorkerCount);
  if Assigned(fTemperatureCollector) then
    Inc(Result, fTemperatureCollector.Diagnostics.ActiveWorkerCount);
  if Assigned(fPipeline) then
    Inc(Result, fPipeline.Diagnostics.ActiveWorkerCount);
  if Assigned(fHistory) then
    Inc(Result, fHistory.Diagnostics.ActiveWorkerCount);
  if Assigned(fTrace) then
    Inc(Result, fTrace.Diagnostics.ActiveWorkerCount);
end;

function TMachineOverviewService.IsRunning: Boolean;
begin
  Result := fRunning;
end;

procedure TMachineOverviewService.Start;
var
  lShutdownResult: TMachineOverviewShutdownResult;
begin
  if not Assigned(fPipeline) or fRunning then
    Exit;

  fPipeline.Start;
  try
    fHistory.Start;
    fTrace.Start;
    fSystemCollector.Start;
    fDiskCollector.Start;
    fGpuCollector.Start;
    fTemperatureCollector.Start;
    fProcessCollector.Start;
  except
    lShutdownResult := Stop(5000);
    if lShutdownResult = TMachineOverviewShutdownResult.TimedOut then
      OutputDebugString('Machine Overview pipeline cleanup timed out after collector start failure');
    raise;
  end;
  fRunning := True;
end;

function TMachineOverviewService.Stop(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
var
  lDiskResult: TMachineOverviewShutdownResult;
  lElapsedMs: Cardinal;
  lHistoryResult: TMachineOverviewShutdownResult;
  lPipelineResult: TMachineOverviewShutdownResult;
  lProcessResult: TMachineOverviewShutdownResult;
  lRemainingMs: Cardinal;
  lStartedMs: Cardinal;
  lSystemResult: TMachineOverviewShutdownResult;
  lGpuResult: TMachineOverviewShutdownResult;
  lTemperatureResult: TMachineOverviewShutdownResult;
  lTraceResult: TMachineOverviewShutdownResult;
begin
  fRunning := False;
  if Assigned(fPipeline) then
    fPipeline.SetDetailedTraceEnabled(False);
  lStartedMs := GetTickCount;
  lTemperatureResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fTemperatureCollector) then
    lTemperatureResult := fTemperatureCollector.Stop(aTimeoutMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lGpuResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fGpuCollector) then
    lGpuResult := fGpuCollector.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lProcessResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fProcessCollector) then
    lProcessResult := fProcessCollector.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lDiskResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fDiskCollector) then
    lDiskResult := fDiskCollector.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lSystemResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fSystemCollector) then
    lSystemResult := fSystemCollector.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lTraceResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fTrace) then
    lTraceResult := fTrace.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lPipelineResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fPipeline) then
    lPipelineResult := fPipeline.Stop(lRemainingMs);
  lElapsedMs := GetTickCount - lStartedMs;
  if lElapsedMs >= aTimeoutMs then
    lRemainingMs := 0
  else
    lRemainingMs := aTimeoutMs - lElapsedMs;
  lHistoryResult := TMachineOverviewShutdownResult.Stopped;
  if Assigned(fHistory) then
    lHistoryResult := fHistory.Stop(lRemainingMs);
  if (lTemperatureResult = TMachineOverviewShutdownResult.Stopped) and
    (lGpuResult = TMachineOverviewShutdownResult.Stopped) and
    (lProcessResult = TMachineOverviewShutdownResult.Stopped) and
    (lDiskResult = TMachineOverviewShutdownResult.Stopped) and
    (lSystemResult = TMachineOverviewShutdownResult.Stopped) and
    (lTraceResult = TMachineOverviewShutdownResult.Stopped) and
    (lPipelineResult = TMachineOverviewShutdownResult.Stopped) and
    (lHistoryResult = TMachineOverviewShutdownResult.Stopped) then
    Result := TMachineOverviewShutdownResult.Stopped
  else
    Result := TMachineOverviewShutdownResult.TimedOut;
end;

function TMachineOverviewService.TryReadLatestPresentation(
  const aAfterSequence: UInt64;
  out aPresentation: TMachineOverviewPresentation): Boolean;
var
  lSnapshot: IMachineOverviewSnapshot;
begin
  aPresentation := Default(TMachineOverviewPresentation);
  Result := Assigned(fPipeline) and
    fPipeline.TryReadLatest(aAfterSequence, lSnapshot);
  if Result then
    aPresentation := lSnapshot.Presentation;
end;

function CreateMachineOverviewService(
  const aSettings: TMachineOverviewSettings): IMachineOverviewService;
begin
  Result := TMachineOverviewService.Create(aSettings);
end;

end.

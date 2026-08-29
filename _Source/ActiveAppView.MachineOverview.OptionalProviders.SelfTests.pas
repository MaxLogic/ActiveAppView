unit ActiveAppView.MachineOverview.OptionalProviders.SelfTests;

interface

function RunMachineOverviewOptionalProviderSelfTests(
  const aArg: string): Integer;

implementation

uses
  System.Classes, System.DateUtils, System.IOUtils, System.Math, System.StrUtils,
  System.SyncObjs, System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.BoundedProcess,
  ActiveAppView.MachineOverview.GpuProvider,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Service,
  ActiveAppView.MachineOverview.Settings,
  ActiveAppView.MachineOverview.TemperatureProvider,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewOptionalProviderSelfTestArg =
    '--self-test-machine-overview-optional-providers';
  cMachineOverviewOptionalProviderTimeoutChildArg =
    '--machine-overview-optional-provider-timeout-child';

function OptionalValue(const aValue: Double): TMachineOverviewOptionalDouble;
begin
  Result := Default(TMachineOverviewOptionalDouble);
  Result.Available := True;
  Result.Value := aValue;
end;

function FindMeasurement(const aSample: TMachineOverviewProviderSample;
  const aName: string; out aMeasurement: TMachineOverviewMeasurement): Boolean;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  for lMeasurement in aSample.Measurements do
    if SameText(lMeasurement.Name, aName) then
    begin
      aMeasurement := lMeasurement;
      Exit(True);
    end;
  aMeasurement := Default(TMachineOverviewMeasurement);
  Result := False;
end;

function RunGpuFixtureSelfTest: Integer;
var
  lReadings: TArray<TMachineOverviewGpuCounterReading>;
  lSamples: TArray<TMachineOverviewTimedGpuSample>;
  lSummary: TMachineOverviewGpuSummary;
  lWindow: TMachineOverviewWindowStatistics;
  lBytes: Double;
  i: Integer;
begin
  Result := 1;
  SetLength(lReadings, 4);
  lReadings[0].Available := True;
  lReadings[0].InstanceName := 'luid_0x1_phys_0_eng_0_engtype_3D';
  lReadings[0].Value := 40;
  lReadings[1].Available := True;
  lReadings[1].InstanceName := 'luid_0x2_phys_0_eng_1_engtype_Compute_0';
  lReadings[1].Value := 75;
  lReadings[2].Available := True;
  lReadings[2].InstanceName := 'luid_0x3_phys_0_eng_2_engtype_Copy';
  lReadings[2].Value := 175;
  lReadings[3].Available := True;
  lReadings[3].InstanceName := 'invalid';
  lReadings[3].Value := NaN;
  lSummary := SummarizeMachineOverviewGpuEngines(lReadings);
  if (not lSummary.Available) or (Abs(lSummary.Percent - 100) > 0.0001) or
    (lSummary.BusiestEngine <> 'Copy') then
  begin
    Writeln('SELFTEST FAILED: WDDM busiest-engine fixture was summed, unclamped, or mislabeled');
    Exit;
  end;

  SetLength(lReadings, 2);
  lReadings[0].Available := True;
  lReadings[0].InstanceName := 'luid_0x9_phys_0_eng_0_engtype_VideoDecode';
  lReadings[0].Value := 60;
  lReadings[1].Available := True;
  lReadings[1].InstanceName := 'luid_0x8_phys_0_eng_0_engtype_3D';
  lReadings[1].Value := 60;
  lSummary := SummarizeMachineOverviewGpuEngines(lReadings);
  if (not lSummary.Available) or (lSummary.BusiestEngine <> '3D') then
  begin
    Writeln('SELFTEST FAILED: WDDM tie order or instance churn handling is not deterministic');
    Exit;
  end;

  SetLength(lReadings, 3);
  lReadings[0].Available := True;
  lReadings[0].Value := Int64(8) * 1024 * 1024 * 1024;
  lReadings[1].Available := True;
  lReadings[1].Value := Int64(12) * 1024 * 1024 * 1024;
  lReadings[2].Available := True;
  lReadings[2].Value := -1;
  if (not SumMachineOverviewGpuDedicatedMemory(lReadings, lBytes)) or
    (Abs(lBytes - (Int64(20) * 1024 * 1024 * 1024)) > 0.5) then
  begin
    Writeln('SELFTEST FAILED: multi-GPU dedicated memory was not summed safely');
    Exit;
  end;
  SetLength(lReadings, 2);
  lReadings[0].Available := True;
  lReadings[0].Value := MaxDouble;
  lReadings[1].Available := True;
  lReadings[1].Value := MaxDouble;
  if SumMachineOverviewGpuDedicatedMemory(lReadings, lBytes) or
    (lBytes <> 0) then
  begin
    Writeln('SELFTEST FAILED: overflowing GPU memory counters were published');
    Exit;
  end;

  SetLength(lSamples, 60);
  for i := 0 to High(lSamples) do
  begin
    lSamples[i].CapturedAtMonotonicMs := UInt64(i + 1) * 1000;
    lSamples[i].Percent := i + 1;
  end;
  lWindow := CalculateMachineOverviewGpuWindow(lSamples, 60000, 5000, 1000);
  if (not lWindow.Available) or (lWindow.ValidSampleCount <> 5) or
    (Abs(lWindow.Average - 58) > 0.0001) or
    (Abs(lWindow.Peak - 60) > 0.0001) or
    (lWindow.ExpectedSampleCount <> 5) then
  begin
    Writeln('SELFTEST FAILED: WDDM rolling window used the wrong boundary or statistics');
    Exit;
  end;
  Result := 0;
end;

function RunCpuTemperatureSelectionSelfTest: Integer;
var
  lProviderName: string;
  lTemperatureCelsius: Double;
  lZones: TArray<TMachineOverviewThermalZoneReading>;
begin
  Result := 1;
  SetLength(lZones, 3);
  lZones[0].Available := True;
  lZones[0].InstanceName := 'TZ00';
  lZones[0].TemperatureKelvin := 323.15;
  lZones[1].Available := True;
  lZones[1].InstanceName := 'CPU Package';
  lZones[1].TemperatureKelvin := 334.15;
  lZones[2].Available := True;
  lZones[2].InstanceName := 'CPU Core';
  lZones[2].TemperatureKelvin := 329.15;
  if (not TrySelectMachineOverviewCpuTemperature(lZones,
      lTemperatureCelsius, lProviderName)) or
    (Abs(lTemperatureCelsius - 61) > 0.0001) or
    (not ContainsText(lProviderName, 'CPU Package')) then
  begin
    Writeln('SELFTEST FAILED: CPU package thermal zone was not selected conservatively');
    Exit;
  end;

  SetLength(lZones, 1);
  lZones[0].Available := True;
  lZones[0].InstanceName := 'TZ00';
  lZones[0].TemperatureKelvin := 323.15;
  if TrySelectMachineOverviewCpuTemperature(lZones,
      lTemperatureCelsius, lProviderName) then
  begin
    Writeln('SELFTEST FAILED: ambiguous ACPI thermal zone was mislabeled as CPU package');
    Exit;
  end;
  Result := 0;
end;

function RunOptionalProviderIncidentPolicySelfTest: Integer;
begin
  Result := 1;
  if not MachineOverviewTemperatureIsCurrent(
      TMachineOverviewProviderStatus.Available) or
    MachineOverviewTemperatureIsCurrent(
      TMachineOverviewProviderStatus.Stale) or
    MachineOverviewTemperatureIsCurrent(
      TMachineOverviewProviderStatus.Failed) then
  begin
    Writeln('SELFTEST FAILED: stale optional temperatures remained incident inputs');
    Exit;
  end;
  if MachineOverviewTemperatureAffectsProviderHealth(
      TMachineOverviewProviderStatus.Unavailable) or
    (not MachineOverviewTemperatureAffectsProviderHealth(
      TMachineOverviewProviderStatus.Failed)) then
  begin
    Writeln('SELFTEST FAILED: normal optional-provider absence became a health incident');
    Exit;
  end;
  Result := 0;
end;

function RunBoundedVendorHelperSelfTest: Integer;
var
  lProcessResult: TMachineOverviewProcessResult;
  lStartedAtMs: UInt64;
begin
  Result := 1;
  lStartedAtMs := GetTickCount64;
  lProcessResult := RunMachineOverviewBoundedProcess(ParamStr(0),
    cMachineOverviewOptionalProviderTimeoutChildArg, 150, 4096);
  if (not lProcessResult.Started) or (not lProcessResult.TimedOut) or
    (lProcessResult.DurationMs < 100) or
    (lProcessResult.DurationMs > 1500) or
    (GetTickCount64 - lStartedAtMs > 1500) then
  begin
    Writeln('SELFTEST FAILED: optional vendor helper execution was not time-bounded');
    Exit;
  end;
  Result := 0;
end;

function RunNvidiaSmiParserSelfTest: Integer;
var
  lErrorText: string;
  lGpuPowerWatts: TMachineOverviewOptionalDouble;
  lGpuTemperatureCelsius: TMachineOverviewOptionalDouble;
begin
  Result := 1;
  if (not TryParseMachineOverviewNvidiaSmiOutput(
      '72, 320.50' + sLineBreak + '61, 210.25',
      lGpuTemperatureCelsius, lGpuPowerWatts, lErrorText)) or
    (not lGpuTemperatureCelsius.Available) or
    (Abs(lGpuTemperatureCelsius.Value - 72) > 0.0001) or
    (not lGpuPowerWatts.Available) or
    (Abs(lGpuPowerWatts.Value - 530.75) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: multi-GPU NVIDIA helper output was not parsed safely');
    Exit;
  end;
  if TryParseMachineOverviewNvidiaSmiOutput('not telemetry',
      lGpuTemperatureCelsius, lGpuPowerWatts, lErrorText) or
    lErrorText.IsEmpty then
  begin
    Writeln('SELFTEST FAILED: malformed NVIDIA helper output was accepted');
    Exit;
  end;
  Result := 0;
end;

function RunLiveProviderShapeSelfTest: Integer;
var
  lMeasurement: TMachineOverviewMeasurement;
  lProvider: IMachineOverviewProvider;
  lSample: TMachineOverviewProviderSample;
  i: Integer;
begin
  Result := 1;
  lProvider := CreateMachineOverviewGpuProvider;
  lProvider.Collect(lSample);
  if (lProvider.ProviderId <> 'gpu') or
    (lSample.State.CapturedAtMonotonicMs = 0) or
    (Length(lSample.Measurements) <> 9) then
  begin
    Writeln('SELFTEST FAILED: live WDDM provider did not return the complete sample shape');
    Exit;
  end;
  if FindMeasurement(lSample, 'gpu_overall_percent', lMeasurement) and
    lMeasurement.Available and
    ((lMeasurement.Value < 0) or (lMeasurement.Value > 100) or
     lMeasurement.DisplayText.IsEmpty) then
  begin
    Writeln('SELFTEST FAILED: live WDDM provider published invalid busiest-engine data');
    Exit;
  end;
  lProvider := nil;

  lProvider := CreateMachineOverviewTemperatureProvider;
  lProvider.Collect(lSample);
  if (lProvider.ProviderId <> 'temperature') or
    (lSample.State.CapturedAtMonotonicMs = 0) or
    (Length(lSample.Measurements) <> 3) then
  begin
    Writeln('SELFTEST FAILED: live optional temperature provider did not degrade safely');
    Exit;
  end;
  for i := 0 to High(lSample.Measurements) do
    if lSample.Measurements[i].Available and
      (IsNan(lSample.Measurements[i].Value) or
       IsInfinite(lSample.Measurements[i].Value) or
       lSample.Measurements[i].StatusText.IsEmpty) then
    begin
      Writeln('SELFTEST FAILED: live optional provider published invalid telemetry');
      Exit;
    end;
  lProvider := nil;
  Result := 0;
end;

function RunOptionalCollectorShutdownSelfTest: Integer;
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
    'ActiveAppView.machine-overview.optional-providers.' +
    IntToStr(GetCurrentProcessId) + '.db');
  if TFile.Exists(lDatabaseFileName) then
    TFile.Delete(lDatabaseFileName);
  lSettings := TMachineOverviewSettings.Defaults;
  lSettings.Enabled := True;
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
    while (lService.ActiveWorkerCount < 7) and
      (GetTickCount64 < lDeadlineMs) do
      lWaitEvent.WaitFor(10);
    if lService.ActiveWorkerCount < 7 then
    begin
      Writeln('SELFTEST FAILED: optional providers were not isolated on collector workers');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: optional provider collector shutdown exceeded its bound');
      Exit;
    end;
    if lService.ActiveWorkerCount <> 0 then
    begin
      Writeln('SELFTEST FAILED: optional provider worker survived service shutdown');
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

function RunTemperatureRetentionSelfTest: Integer;
var
  lCache: TMachineOverviewTemperatureCache;
  lMeasurement: TMachineOverviewMeasurement;
  lProbe: TMachineOverviewTemperatureProbe;
  lSample: TMachineOverviewProviderSample;
begin
  Result := 1;
  lCache := Default(TMachineOverviewTemperatureCache);
  lProbe := Default(TMachineOverviewTemperatureProbe);
  lProbe.Status := TMachineOverviewProviderStatus.Unavailable;
  lProbe.ProviderName := 'missing runtime';
  lProbe.ErrorText := 'NVIDIA NVML is not installed';
  BuildMachineOverviewTemperatureSample(lProbe, 1, 1000, 3000, lCache,
    lSample);
  if (lSample.State.Status <> TMachineOverviewProviderStatus.Unavailable) or
    (Length(lSample.Measurements) <> 3) then
  begin
    Writeln('SELFTEST FAILED: missing optional runtime did not degrade explicitly');
    Exit;
  end;

  lProbe.Status := TMachineOverviewProviderStatus.Failed;
  lProbe.ProviderName := 'NVIDIA NVML';
  lProbe.ErrorText := 'initialization failed';
  BuildMachineOverviewTemperatureSample(lProbe, 2, 2000, 3000, lCache,
    lSample);
  if lSample.State.Status <> TMachineOverviewProviderStatus.Failed then
  begin
    Writeln('SELFTEST FAILED: optional provider initialization failure was hidden');
    Exit;
  end;

  lProbe.Status := TMachineOverviewProviderStatus.Available;
  lProbe.ErrorText := '';
  lProbe.GpuTemperatureCelsius := OptionalValue(72);
  lProbe.GpuPowerWatts := OptionalValue(335.5);
  lProbe.CpuPackageTemperatureCelsius := OptionalValue(61);
  BuildMachineOverviewTemperatureSample(lProbe, 3, 3000, 3000, lCache,
    lSample);
  if (lSample.State.Status <> TMachineOverviewProviderStatus.Available) or
    (lSample.State.DataAgeMs <> 0) or
    (not FindMeasurement(lSample, 'gpu_temperature_c', lMeasurement)) or
    (not lMeasurement.Available) or (Abs(lMeasurement.Value - 72) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: optional provider success did not publish current values');
    Exit;
  end;

  lProbe := Default(TMachineOverviewTemperatureProbe);
  lProbe.Status := TMachineOverviewProviderStatus.Failed;
  lProbe.ProviderName := 'NVIDIA NVML';
  lProbe.ErrorText := 'device disappeared';
  BuildMachineOverviewTemperatureSample(lProbe, 7, 7001, 3000, lCache,
    lSample);
  if (lSample.State.Status <> TMachineOverviewProviderStatus.Stale) or
    (lSample.State.DataAgeMs <> 4001) or
    (not FindMeasurement(lSample, 'gpu_temperature_c', lMeasurement)) or
    (not lMeasurement.Available) or
    (not ContainsText(lMeasurement.StatusText, 'Stale')) then
  begin
    Writeln('SELFTEST FAILED: optional provider did not retain and age stale values');
    Exit;
  end;

  lProbe.Status := TMachineOverviewProviderStatus.Available;
  lProbe.ProviderName := 'NVIDIA NVML';
  lProbe.GpuTemperatureCelsius := OptionalValue(68);
  lProbe.GpuPowerWatts := OptionalValue(300);
  lProbe.CpuPackageTemperatureCelsius := OptionalValue(58);
  BuildMachineOverviewTemperatureSample(lProbe, 8, 8000, 3000, lCache,
    lSample);
  if (lSample.State.Status <> TMachineOverviewProviderStatus.Available) or
    (lSample.State.DataAgeMs <> 0) or
    (not FindMeasurement(lSample, 'gpu_temperature_c', lMeasurement)) or
    (Abs(lMeasurement.Value - 68) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: optional provider did not recover without restart');
    Exit;
  end;
  Result := 0;
end;

function RunMachineOverviewOptionalProviderSelfTests(
  const aArg: string): Integer;
begin
  if SameText(aArg, cMachineOverviewOptionalProviderTimeoutChildArg) then
  begin
    Sleep(5000);
    Exit(0);
  end;
  if not SameText(aArg, cMachineOverviewOptionalProviderSelfTestArg) then
    Exit(-1);
  try
    Result := RunGpuFixtureSelfTest;
    if Result = 0 then
      Result := RunTemperatureRetentionSelfTest;
    if Result = 0 then
      Result := RunCpuTemperatureSelectionSelfTest;
    if Result = 0 then
      Result := RunOptionalProviderIncidentPolicySelfTest;
    if Result = 0 then
      Result := RunNvidiaSmiParserSelfTest;
    if Result = 0 then
      Result := RunBoundedVendorHelperSelfTest;
    if Result = 0 then
      Result := RunLiveProviderShapeSelfTest;
    if Result = 0 then
      Result := RunOptionalCollectorShutdownSelfTest;
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

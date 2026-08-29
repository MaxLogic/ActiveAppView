unit ActiveAppView.MachineOverview.TemperatureProvider;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewThermalZoneReading = record
    InstanceName: string;
    TemperatureKelvin: Double;
    Available: Boolean;
  end;

  TMachineOverviewTemperatureProbe = record
    Status: TMachineOverviewProviderStatus;
    ProviderName: string;
    CpuProviderName: string;
    ErrorText: string;
    GpuTemperatureCelsius: TMachineOverviewOptionalDouble;
    GpuPowerWatts: TMachineOverviewOptionalDouble;
    CpuPackageTemperatureCelsius: TMachineOverviewOptionalDouble;
  end;

  TMachineOverviewRetainedTemperature = record
    Available: Boolean;
    Value: Double;
    CapturedAtMonotonicMs: UInt64;
    ProviderName: string;
  end;

  TMachineOverviewTemperatureCache = record
    GpuTemperatureCelsius: TMachineOverviewRetainedTemperature;
    GpuPowerWatts: TMachineOverviewRetainedTemperature;
    CpuPackageTemperatureCelsius: TMachineOverviewRetainedTemperature;
  end;

procedure BuildMachineOverviewTemperatureSample(
  const aProbe: TMachineOverviewTemperatureProbe;
  const aCapturedAtUtc: TDateTime; const aNowMonotonicMs, aStaleAfterMs: UInt64;
  var aCache: TMachineOverviewTemperatureCache;
  out aSample: TMachineOverviewProviderSample);
function TrySelectMachineOverviewCpuTemperature(
  const aReadings: TArray<TMachineOverviewThermalZoneReading>;
  out aTemperatureCelsius: Double; out aProviderName: string): Boolean;
function TryParseMachineOverviewNvidiaSmiOutput(const aText: string;
  out aGpuTemperatureCelsius, aGpuPowerWatts: TMachineOverviewOptionalDouble;
  out aErrorText: string): Boolean;
function MachineOverviewTemperatureIsCurrent(
  const aStatus: TMachineOverviewProviderStatus): Boolean;
function MachineOverviewTemperatureAffectsProviderHealth(
  const aStatus: TMachineOverviewProviderStatus): Boolean;
function CreateMachineOverviewTemperatureProvider: IMachineOverviewProvider;

implementation

uses
  System.Classes, System.DateUtils, System.Generics.Collections, System.Math,
  System.StrUtils, System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.BoundedProcess,
  ActiveAppView.MachineOverview.WindowsProviders;

procedure AppendError(var aText: string; const aErrorText: string); forward;

function TryParseNvidiaValue(const aText: string; const aMinimum,
  aMaximum: Double; out aValue: Double): Boolean;
begin
  Result := TryStrToFloat(Trim(aText), aValue, TFormatSettings.Invariant) and
    (not IsNan(aValue)) and (not IsInfinite(aValue)) and
    (aValue >= aMinimum) and (aValue <= aMaximum);
end;

function TryParseMachineOverviewNvidiaSmiOutput(const aText: string;
  out aGpuTemperatureCelsius, aGpuPowerWatts: TMachineOverviewOptionalDouble;
  out aErrorText: string): Boolean;
var
  g: TGarbos;
  lCommaPosition: Integer;
  lLine: string;
  lLines: TStringList;
  lPower: Double;
  lTemperature: Double;
begin
  g := Default(TGarbos);
  aGpuTemperatureCelsius := Default(TMachineOverviewOptionalDouble);
  aGpuPowerWatts := Default(TMachineOverviewOptionalDouble);
  aErrorText := '';
  GC(lLines, TStringList.Create, g);
  lLines.Text := aText;
  for lLine in lLines do
  begin
    if Trim(lLine).IsEmpty then
      Continue;
    lCommaPosition := Pos(',', lLine);
    if lCommaPosition = 0 then
    begin
      AppendError(aErrorText, 'Malformed NVIDIA telemetry row');
      Continue;
    end;
    if TryParseNvidiaValue(Copy(lLine, 1, lCommaPosition - 1), -50, 200,
        lTemperature) then
    begin
      if (not aGpuTemperatureCelsius.Available) or
        (lTemperature > aGpuTemperatureCelsius.Value) then
        aGpuTemperatureCelsius.Value := lTemperature;
      aGpuTemperatureCelsius.Available := True;
    end;
    if TryParseNvidiaValue(Copy(lLine, lCommaPosition + 1, MaxInt), 0, 2000,
        lPower) then
    begin
      lPower := aGpuPowerWatts.Value + lPower;
      if (not IsInfinite(lPower)) and (lPower <= 10000) then
      begin
        aGpuPowerWatts.Value := lPower;
        aGpuPowerWatts.Available := True;
      end else
        AppendError(aErrorText, 'NVIDIA power total exceeded the supported range');
    end;
  end;
  Result := aGpuTemperatureCelsius.Available or aGpuPowerWatts.Available;
  if (not Result) and aErrorText.IsEmpty then
    aErrorText := 'NVIDIA telemetry returned no supported values';
end;

type
  TPdhQueryHandle = NativeUInt;
  TPdhCounterHandle = NativeUInt;

  TPdhFormattedCounterValue = record
    Status: Cardinal;
    case Integer of
      0: (LongValue: Longint);
      1: (DoubleValue: Double);
      2: (LargeValue: Int64);
      3: (AnsiStringValue: PAnsiChar);
      4: (WideStringValue: PWideChar);
  end;

  PPdhFormattedCounterValueItem = ^TPdhFormattedCounterValueItem;
  TPdhFormattedCounterValueItem = record
    Name: PWideChar;
    Value: TPdhFormattedCounterValue;
  end;

  TMachineOverviewTemperatureProvider = class(TInterfacedObject,
    IMachineOverviewProvider)
  private
    fCache: TMachineOverviewTemperatureCache;
    fNvidiaSmiPath: string;
    fThermalCounter: TPdhCounterHandle;
    fThermalError: string;
    fThermalQuery: TPdhQueryHandle;
    procedure CollectNvidiaSmi(out aProbe: TMachineOverviewTemperatureProbe);
    function TryCollectCpuTemperature(out aTemperatureCelsius: Double;
      out aProviderName, aErrorText: string): Boolean;
    function TryReadThermalZones(
      out aReadings: TArray<TMachineOverviewThermalZoneReading>): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

const
  cPdhFormatDouble = $00000200;
  cPdhMoreData = Longint($800007D2);
  cNvidiaSmiMaximumOutputBytes = 65536;
  cNvidiaSmiTimeoutMs = 1500;
  cTemperatureStaleAfterMs = 10000;

function PdhOpenQueryW(const aDataSource: PWideChar; const aUserData: NativeUInt;
  var aQuery: TPdhQueryHandle): Longint; stdcall; external 'pdh.dll';
function PdhAddEnglishCounterW(const aQuery: TPdhQueryHandle;
  const aCounterPath: PWideChar; const aUserData: NativeUInt;
  var aCounter: TPdhCounterHandle): Longint; stdcall; external 'pdh.dll';
function PdhCollectQueryData(const aQuery: TPdhQueryHandle): Longint; stdcall;
  external 'pdh.dll';
function PdhGetFormattedCounterArrayW(const aCounter: TPdhCounterHandle;
  const aFormat: Cardinal; var aBufferSize, aItemCount: Cardinal;
  const aItems: Pointer): Longint; stdcall; external 'pdh.dll';
function PdhCloseQuery(const aQuery: TPdhQueryHandle): Longint; stdcall;
  external 'pdh.dll';

procedure AppendError(var aText: string; const aErrorText: string);
begin
  if aErrorText.IsEmpty then
    Exit;
  if aText.IsEmpty then
    aText := aErrorText
  else
    aText := aText + '; ' + aErrorText;
end;

function OptionalValueIsValid(const aValue: TMachineOverviewOptionalDouble;
  const aMinimum, aMaximum: Double): Boolean;
begin
  Result := aValue.Available and (not IsNan(aValue.Value)) and
    (not IsInfinite(aValue.Value)) and (aValue.Value >= aMinimum) and
    (aValue.Value <= aMaximum);
end;

procedure ResolveRetainedTemperature(
  const aCurrent: TMachineOverviewOptionalDouble;
  const aProviderName, aUnavailableText, aMeasurementName, aUnitText,
  aDetailText: string; const aMinimum, aMaximum: Double;
  const aNowMonotonicMs, aStaleAfterMs: UInt64;
  var aRetained: TMachineOverviewRetainedTemperature;
  out aMeasurement: TMachineOverviewMeasurement;
  out aCurrentAvailable: Boolean; out aAgeMs: UInt64);
begin
  aCurrentAvailable := OptionalValueIsValid(aCurrent, aMinimum, aMaximum);
  if aCurrentAvailable then
  begin
    aRetained.Available := True;
    aRetained.Value := aCurrent.Value;
    aRetained.CapturedAtMonotonicMs := aNowMonotonicMs;
    aRetained.ProviderName := aProviderName;
  end;
  aMeasurement := Default(TMachineOverviewMeasurement);
  aMeasurement.Name := aMeasurementName;
  aMeasurement.UnitText := aUnitText;
  aMeasurement.DetailText := aDetailText;
  aMeasurement.Available := aRetained.Available;
  aMeasurement.Value := aRetained.Value;
  if aRetained.Available then
    aAgeMs := aNowMonotonicMs - aRetained.CapturedAtMonotonicMs
  else
    aAgeMs := 0;
  if aCurrentAvailable then
    aMeasurement.StatusText := aRetained.ProviderName +
      '; current; age 0 ms'
  else if aRetained.Available and (aAgeMs > aStaleAfterMs) then
    aMeasurement.StatusText := Format('Stale; %s; age %d ms',
      [aRetained.ProviderName, aAgeMs])
  else if aRetained.Available then
    aMeasurement.StatusText := Format('Last good; %s; age %d ms',
      [aRetained.ProviderName, aAgeMs])
  else
    aMeasurement.StatusText := aUnavailableText;
end;

procedure BuildMachineOverviewTemperatureSample(
  const aProbe: TMachineOverviewTemperatureProbe;
  const aCapturedAtUtc: TDateTime; const aNowMonotonicMs, aStaleAfterMs: UInt64;
  var aCache: TMachineOverviewTemperatureCache;
  out aSample: TMachineOverviewProviderSample);
var
  lAnyCurrent: Boolean;
  lAnyRetained: Boolean;
  lCpuAgeMs: UInt64;
  lCpuCurrent: Boolean;
  lCpuProviderName: string;
  lGpuAgeMs: UInt64;
  lGpuCurrent: Boolean;
  lMaximumAgeMs: UInt64;
  lPowerAgeMs: UInt64;
  lPowerCurrent: Boolean;
  lUnavailableText: string;
begin
  aSample := Default(TMachineOverviewProviderSample);
  aSample.State.ProviderId := 'temperature';
  aSample.State.CapturedAtUtc := aCapturedAtUtc;
  aSample.State.CapturedAtMonotonicMs := aNowMonotonicMs;
  aSample.State.ErrorText := aProbe.ErrorText;
  if aProbe.ErrorText.IsEmpty then
    lUnavailableText := aProbe.ProviderName + ' unavailable'
  else
    lUnavailableText := aProbe.ErrorText;
  if aProbe.CpuProviderName.IsEmpty then
    lCpuProviderName := aProbe.ProviderName
  else
    lCpuProviderName := aProbe.CpuProviderName;
  SetLength(aSample.Measurements, 3);
  ResolveRetainedTemperature(aProbe.GpuTemperatureCelsius,
    aProbe.ProviderName, lUnavailableText, 'gpu_temperature_c', 'C',
    'Maximum current NVIDIA GPU temperature', -50, 200,
    aNowMonotonicMs, aStaleAfterMs, aCache.GpuTemperatureCelsius,
    aSample.Measurements[0], lGpuCurrent, lGpuAgeMs);
  ResolveRetainedTemperature(aProbe.GpuPowerWatts,
    aProbe.ProviderName, lUnavailableText, 'gpu_power_w', 'W',
    'Sum of current NVIDIA GPU board power readings', 0, 2000,
    aNowMonotonicMs, aStaleAfterMs, aCache.GpuPowerWatts,
    aSample.Measurements[1], lPowerCurrent, lPowerAgeMs);
  ResolveRetainedTemperature(aProbe.CpuPackageTemperatureCelsius,
    lCpuProviderName, lUnavailableText, 'cpu_package_temperature_c', 'C',
    'Conservatively identified Windows CPU package thermal zone', -50, 200,
    aNowMonotonicMs, aStaleAfterMs,
    aCache.CpuPackageTemperatureCelsius, aSample.Measurements[2],
    lCpuCurrent, lCpuAgeMs);
  lAnyCurrent := lGpuCurrent or lPowerCurrent or lCpuCurrent;
  lAnyRetained := aCache.GpuTemperatureCelsius.Available or
    aCache.GpuPowerWatts.Available or
    aCache.CpuPackageTemperatureCelsius.Available;
  lMaximumAgeMs := lGpuAgeMs;
  if lPowerAgeMs > lMaximumAgeMs then
    lMaximumAgeMs := lPowerAgeMs;
  if lCpuAgeMs > lMaximumAgeMs then
    lMaximumAgeMs := lCpuAgeMs;
  aSample.State.DataAgeMs := lMaximumAgeMs;
  if lAnyCurrent then
    aSample.State.Status := TMachineOverviewProviderStatus.Available
  else if lAnyRetained and (lMaximumAgeMs > aStaleAfterMs) then
    aSample.State.Status := TMachineOverviewProviderStatus.Stale
  else if aProbe.Status = TMachineOverviewProviderStatus.Available then
    aSample.State.Status := TMachineOverviewProviderStatus.Unavailable
  else
    aSample.State.Status := aProbe.Status;
end;

function TrySelectMachineOverviewCpuTemperature(
  const aReadings: TArray<TMachineOverviewThermalZoneReading>;
  out aTemperatureCelsius: Double; out aProviderName: string): Boolean;
var
  lCelsius: Double;
  lReading: TMachineOverviewThermalZoneReading;
begin
  aTemperatureCelsius := 0;
  aProviderName := '';
  Result := False;
  for lReading in aReadings do
  begin
    if (not lReading.Available) or IsNan(lReading.TemperatureKelvin) or
      IsInfinite(lReading.TemperatureKelvin) or
      (lReading.TemperatureKelvin < 200) or
      (lReading.TemperatureKelvin > 500) or
      (not ContainsText(lReading.InstanceName, 'cpu')) or
      (not ContainsText(lReading.InstanceName, 'package')) then
      Continue;
    lCelsius := lReading.TemperatureKelvin - 273.15;
    if (not Result) or (lCelsius > aTemperatureCelsius) or
      ((Abs(lCelsius - aTemperatureCelsius) <= 0.0001) and
       (CompareText(lReading.InstanceName,
         Copy(aProviderName, Pos(': ', aProviderName) + 2, MaxInt)) < 0)) then
    begin
      Result := True;
      aTemperatureCelsius := lCelsius;
      aProviderName := 'Windows Thermal Zone Information: ' +
        lReading.InstanceName;
    end;
  end;
end;

function MachineOverviewTemperatureIsCurrent(
  const aStatus: TMachineOverviewProviderStatus): Boolean;
begin
  Result := aStatus = TMachineOverviewProviderStatus.Available;
end;

function MachineOverviewTemperatureAffectsProviderHealth(
  const aStatus: TMachineOverviewProviderStatus): Boolean;
begin
  Result := aStatus <> TMachineOverviewProviderStatus.Unavailable;
end;

constructor TMachineOverviewTemperatureProvider.Create;
var
  lBuffer: array[0..MAX_PATH] of Char;
  lLength: Cardinal;
  lStatus: Longint;
begin
  inherited Create;
  lLength := GetSystemDirectory(lBuffer, Length(lBuffer));
  if (lLength > 0) and (lLength < Cardinal(Length(lBuffer))) then
  begin
    SetString(fNvidiaSmiPath, lBuffer, lLength);
    fNvidiaSmiPath := IncludeTrailingPathDelimiter(fNvidiaSmiPath) +
      'nvidia-smi.exe';
    if GetFileAttributes(PChar(fNvidiaSmiPath)) = INVALID_FILE_ATTRIBUTES then
      fNvidiaSmiPath := '';
  end;
  lStatus := PdhOpenQueryW(nil, 0, fThermalQuery);
  if lStatus <> 0 then
  begin
    fThermalQuery := 0;
    fThermalError := Format('Windows thermal PDH query unavailable: 0x%.8x',
      [Cardinal(lStatus)]);
    Exit;
  end;
  lStatus := PdhAddEnglishCounterW(fThermalQuery,
    '\Thermal Zone Information(*)\Temperature', 0, fThermalCounter);
  if lStatus <> 0 then
  begin
    fThermalCounter := 0;
    fThermalError := Format('Windows CPU package thermal counter unavailable: 0x%.8x',
      [Cardinal(lStatus)]);
  end else
    PdhCollectQueryData(fThermalQuery);
end;

destructor TMachineOverviewTemperatureProvider.Destroy;
var
  lStatus: Longint;
begin
  if fThermalQuery <> 0 then
  begin
    lStatus := PdhCloseQuery(fThermalQuery);
    if lStatus <> 0 then
      OutputDebugString(PChar(Format(
        'Machine Overview thermal PDH query close failed: 0x%.8x',
        [Cardinal(lStatus)])));
  end;
  inherited Destroy;
end;

procedure TMachineOverviewTemperatureProvider.CollectNvidiaSmi(
  out aProbe: TMachineOverviewTemperatureProbe);
var
  lErrorText: string;
  lProcessResult: TMachineOverviewProcessResult;
begin
  aProbe := Default(TMachineOverviewTemperatureProbe);
  aProbe.ProviderName := 'NVIDIA nvidia-smi (NVML)';
  if fNvidiaSmiPath.IsEmpty then
  begin
    aProbe.Status := TMachineOverviewProviderStatus.Unavailable;
    aProbe.ErrorText := 'NVIDIA nvidia-smi helper is not installed';
    Exit;
  end;
  lProcessResult := RunMachineOverviewBoundedProcess(fNvidiaSmiPath,
    '--query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits',
    cNvidiaSmiTimeoutMs, cNvidiaSmiMaximumOutputBytes);
  if not lProcessResult.Started then
  begin
    aProbe.Status := TMachineOverviewProviderStatus.Failed;
    aProbe.ErrorText := lProcessResult.ErrorText;
    Exit;
  end;
  if lProcessResult.TimedOut then
  begin
    aProbe.Status := TMachineOverviewProviderStatus.Failed;
    aProbe.ErrorText := lProcessResult.ErrorText;
    Exit;
  end;
  if lProcessResult.ExitCode <> 0 then
  begin
    aProbe.Status := TMachineOverviewProviderStatus.Failed;
    aProbe.ErrorText := Format('NVIDIA telemetry helper exited with code %d',
      [lProcessResult.ExitCode]);
    if not Trim(lProcessResult.OutputText).IsEmpty then
      AppendError(aProbe.ErrorText, Trim(lProcessResult.OutputText));
    Exit;
  end;
  if not TryParseMachineOverviewNvidiaSmiOutput(lProcessResult.OutputText,
      aProbe.GpuTemperatureCelsius, aProbe.GpuPowerWatts, lErrorText) then
  begin
    aProbe.Status := TMachineOverviewProviderStatus.Unavailable;
    aProbe.ErrorText := lErrorText;
    Exit;
  end;
  aProbe.Status := TMachineOverviewProviderStatus.Available;
  aProbe.ErrorText := lErrorText;
end;

function TMachineOverviewTemperatureProvider.TryReadThermalZones(
  out aReadings: TArray<TMachineOverviewThermalZoneReading>): Boolean;
var
  g: TGarbos;
  lBuffer: TBytes;
  lBufferSize: Cardinal;
  lItem: PPdhFormattedCounterValueItem;
  lItemCount: Cardinal;
  lLastIndex: Cardinal;
  lList: TList<TMachineOverviewThermalZoneReading>;
  lReading: TMachineOverviewThermalZoneReading;
  lStatus: Longint;
  lValue: Double;
  i: Cardinal;
begin
  g := Default(TGarbos);
  SetLength(aReadings, 0);
  Result := False;
  if fThermalCounter = 0 then
    Exit;
  lBufferSize := 0;
  lItemCount := 0;
  lStatus := PdhGetFormattedCounterArrayW(fThermalCounter,
    cPdhFormatDouble, lBufferSize, lItemCount, nil);
  if (lStatus <> cPdhMoreData) or (lBufferSize = 0) then
    Exit;
  SetLength(lBuffer, lBufferSize);
  lStatus := PdhGetFormattedCounterArrayW(fThermalCounter,
    cPdhFormatDouble, lBufferSize, lItemCount, @lBuffer[0]);
  if (lStatus <> 0) or
    (not TryMachineOverviewCounterIndexBounds(lItemCount, lLastIndex)) then
    Exit;
  GC(lList, TList<TMachineOverviewThermalZoneReading>.Create, g);
  lItem := Pointer(lBuffer);
  i := 0;
  while i <= lLastIndex do
  begin
    if (not SameText(string(lItem^.Name), '_Total')) and
      TryAcceptMachineOverviewPdhValue(lItem^.Value.Status,
        lItem^.Value.DoubleValue, 200, 500, lValue) then
    begin
      lReading := Default(TMachineOverviewThermalZoneReading);
      lReading.InstanceName := string(lItem^.Name);
      lReading.TemperatureKelvin := lValue;
      lReading.Available := True;
      lList.Add(lReading);
    end;
    Inc(lItem);
    Inc(i);
  end;
  aReadings := lList.ToArray;
  Result := Length(aReadings) > 0;
end;

function TMachineOverviewTemperatureProvider.TryCollectCpuTemperature(
  out aTemperatureCelsius: Double;
  out aProviderName, aErrorText: string): Boolean;
var
  lReadings: TArray<TMachineOverviewThermalZoneReading>;
  lStatus: Longint;
begin
  aTemperatureCelsius := 0;
  aProviderName := '';
  aErrorText := '';
  Result := False;
  if (fThermalQuery = 0) or (fThermalCounter = 0) then
  begin
    aErrorText := fThermalError;
    Exit;
  end;
  lStatus := PdhCollectQueryData(fThermalQuery);
  if lStatus <> 0 then
  begin
    aErrorText := Format('Windows thermal PDH collection failed: 0x%.8x',
      [Cardinal(lStatus)]);
    Exit;
  end;
  if not TryReadThermalZones(lReadings) then
  begin
    aErrorText := 'Windows CPU package thermal zone is unavailable';
    Exit;
  end;
  Result := TrySelectMachineOverviewCpuTemperature(lReadings,
    aTemperatureCelsius, aProviderName);
  if not Result then
    aErrorText := 'Windows thermal zones do not identify a CPU package sensor';
end;

procedure TMachineOverviewTemperatureProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
var
  lCpuError: string;
  lCpuProviderName: string;
  lCpuTemperature: Double;
  lNowMonotonicMs: UInt64;
  lProbe: TMachineOverviewTemperatureProbe;
begin
  CollectNvidiaSmi(lProbe);
  if TryCollectCpuTemperature(lCpuTemperature, lCpuProviderName,
      lCpuError) then
  begin
    lProbe.CpuPackageTemperatureCelsius.Available := True;
    lProbe.CpuPackageTemperatureCelsius.Value := lCpuTemperature;
    lProbe.CpuProviderName := lCpuProviderName;
    lProbe.Status := TMachineOverviewProviderStatus.Available;
  end else
    AppendError(lProbe.ErrorText, lCpuError);
  lNowMonotonicMs := GetTickCount64;
  BuildMachineOverviewTemperatureSample(lProbe,
    TTimeZone.Local.ToUniversalTime(Now), lNowMonotonicMs,
    cTemperatureStaleAfterMs, fCache, aSample);
end;

function TMachineOverviewTemperatureProvider.ProviderId: string;
begin
  Result := 'temperature';
end;

function CreateMachineOverviewTemperatureProvider: IMachineOverviewProvider;
begin
  Result := TMachineOverviewTemperatureProvider.Create;
end;

end.

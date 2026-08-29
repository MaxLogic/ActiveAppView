unit ActiveAppView.MachineOverview.GpuProvider;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewGpuCounterReading = record
    InstanceName: string;
    Value: Double;
    Available: Boolean;
  end;

  TMachineOverviewGpuSummary = record
    Available: Boolean;
    BusiestEngine: string;
    Percent: Double;
    ValidEngineCount: Integer;
  end;

  TMachineOverviewTimedGpuSample = record
    CapturedAtMonotonicMs: UInt64;
    Percent: Double;
  end;

function SummarizeMachineOverviewGpuEngines(
  const aReadings: TArray<TMachineOverviewGpuCounterReading>):
  TMachineOverviewGpuSummary;
function SumMachineOverviewGpuDedicatedMemory(
  const aReadings: TArray<TMachineOverviewGpuCounterReading>;
  out aBytes: Double): Boolean;
function CalculateMachineOverviewGpuWindow(
  const aSamples: TArray<TMachineOverviewTimedGpuSample>;
  const aNowMonotonicMs, aWindowMs: UInt64;
  const aExpectedIntervalMs: Cardinal): TMachineOverviewWindowStatistics;
function CreateMachineOverviewGpuProvider: IMachineOverviewProvider;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.Math, System.StrUtils,
  System.SysUtils,
  Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.Domain,
  ActiveAppView.MachineOverview.WindowsProviders;

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

  TMachineOverviewGpuProvider = class(TInterfacedObject,
    IMachineOverviewProvider)
  private
    fDedicatedCounter: TPdhCounterHandle;
    fEngineCounter: TPdhCounterHandle;
    fExpectedIntervalMs: Cardinal;
    fInitializationError: string;
    fLastDedicatedBytes: Double;
    fLastDedicatedCapturedAtMonotonicMs: UInt64;
    fLastDedicatedAvailable: Boolean;
    fLastSummary: TMachineOverviewGpuSummary;
    fLastSummaryCapturedAtMonotonicMs: UInt64;
    fQuery: TPdhQueryHandle;
    fSamples: TList<TMachineOverviewTimedGpuSample>;
    procedure AddCounter(const aPath, aName: string;
      out aCounter: TPdhCounterHandle);
    procedure AddMeasurement(var aSample: TMachineOverviewProviderSample;
      const aIndex: Integer; const aName, aUnitText: string;
      const aValue: Double; const aAvailable: Boolean;
      const aDisplayText, aDetailText, aStatusText: string);
    procedure PruneSamples(const aNowMonotonicMs: UInt64);
    procedure PublishSample(out aSample: TMachineOverviewProviderSample;
      const aCapturedAtUtc: TDateTime; const aNowMonotonicMs: UInt64;
      const aStatus: TMachineOverviewProviderStatus;
      const aErrorText: string);
    function TryReadCounterArray(const aCounter: TPdhCounterHandle;
      out aReadings: TArray<TMachineOverviewGpuCounterReading>): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

const
  cPdhFormatDouble = $00000200;
  cPdhMoreData = Longint($800007D2);
  cMachineOverviewGpuRetentionMs = 60000;
  cMachineOverviewGpuExpectedIntervalMs = 1000;

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

function GpuEngineDisplayName(const aInstanceName: string): string;
var
  lLowerName: string;
  lPosition: Integer;
begin
  lLowerName := LowerCase(aInstanceName);
  lPosition := Pos('engtype_', lLowerName);
  if lPosition > 0 then
    Result := Copy(aInstanceName, lPosition + Length('engtype_'), MaxInt)
  else
    Result := Trim(aInstanceName);
  Result := StringReplace(Result, '_', ' ', [rfReplaceAll]);
  if Result.IsEmpty then
    Result := 'unnamed engine';
end;

function SummarizeMachineOverviewGpuEngines(
  const aReadings: TArray<TMachineOverviewGpuCounterReading>):
  TMachineOverviewGpuSummary;
var
  lBestInstance: string;
  lReading: TMachineOverviewGpuCounterReading;
  lValue: Double;
begin
  Result := Default(TMachineOverviewGpuSummary);
  lBestInstance := '';
  for lReading in aReadings do
  begin
    if (not lReading.Available) or IsNan(lReading.Value) or
      IsInfinite(lReading.Value) or (lReading.Value < 0) then
      Continue;
    lValue := EnsureRange(lReading.Value, 0.0, 100.0);
    Inc(Result.ValidEngineCount);
    if (not Result.Available) or (lValue > Result.Percent) or
      ((Abs(lValue - Result.Percent) <= 0.0001) and
       (CompareText(lReading.InstanceName, lBestInstance) < 0)) then
    begin
      Result.Available := True;
      Result.Percent := lValue;
      Result.BusiestEngine := GpuEngineDisplayName(lReading.InstanceName);
      lBestInstance := lReading.InstanceName;
    end;
  end;
end;

function SumMachineOverviewGpuDedicatedMemory(
  const aReadings: TArray<TMachineOverviewGpuCounterReading>;
  out aBytes: Double): Boolean;
var
  lReading: TMachineOverviewGpuCounterReading;
  lTotal: Double;
begin
  aBytes := 0;
  Result := False;
  for lReading in aReadings do
    if lReading.Available and (not IsNan(lReading.Value)) and
      (not IsInfinite(lReading.Value)) and (lReading.Value >= 0) then
    begin
      lTotal := aBytes + lReading.Value;
      if IsNan(lTotal) or IsInfinite(lTotal) then
      begin
        aBytes := 0;
        Exit(False);
      end;
      aBytes := lTotal;
      Result := True;
    end;
end;

function CalculateMachineOverviewGpuWindow(
  const aSamples: TArray<TMachineOverviewTimedGpuSample>;
  const aNowMonotonicMs, aWindowMs: UInt64;
  const aExpectedIntervalMs: Cardinal): TMachineOverviewWindowStatistics;
var
  lMaximum: Double;
  lSample: TMachineOverviewTimedGpuSample;
  lStartMs: UInt64;
  lSum: Double;
begin
  Result := Default(TMachineOverviewWindowStatistics);
  if (aWindowMs = 0) or (aExpectedIntervalMs = 0) then
    Exit;
  Result.ExpectedSampleCount := aWindowMs div aExpectedIntervalMs;
  if Result.ExpectedSampleCount = 0 then
    Result.ExpectedSampleCount := 1;
  if aNowMonotonicMs > aWindowMs then
    lStartMs := aNowMonotonicMs - aWindowMs
  else
    lStartMs := 0;
  lMaximum := 0;
  lSum := 0;
  for lSample in aSamples do
    if (lSample.CapturedAtMonotonicMs > lStartMs) and
      (lSample.CapturedAtMonotonicMs <= aNowMonotonicMs) and
      (not IsNan(lSample.Percent)) and (not IsInfinite(lSample.Percent)) and
      (lSample.Percent >= 0) and (lSample.Percent <= 100) then
    begin
      if (Result.ValidSampleCount = 0) or (lSample.Percent > lMaximum) then
        lMaximum := lSample.Percent;
      lSum := lSum + lSample.Percent;
      Inc(Result.ValidSampleCount);
    end;
  if Result.ValidSampleCount = 0 then
    Exit;
  Result.Available := True;
  Result.Average := lSum / Result.ValidSampleCount;
  Result.Peak := lMaximum;
  Result.CoveragePercent := EnsureRange(
    (Result.ValidSampleCount * 100.0) / Result.ExpectedSampleCount, 0.0, 100.0);
  Result.CoverageSufficient := Result.CoveragePercent >= 80;
end;

constructor TMachineOverviewGpuProvider.Create;
var
  lStatus: Longint;
begin
  inherited Create;
  fExpectedIntervalMs := cMachineOverviewGpuExpectedIntervalMs;
  fSamples := TList<TMachineOverviewTimedGpuSample>.Create;
  lStatus := PdhOpenQueryW(nil, 0, fQuery);
  if lStatus <> 0 then
  begin
    fQuery := 0;
    fInitializationError := Format('WDDM PDH query unavailable: 0x%.8x',
      [Cardinal(lStatus)]);
    Exit;
  end;
  AddCounter('\GPU Engine(*)\Utilization Percentage', 'GPU Engine',
    fEngineCounter);
  AddCounter('\GPU Adapter Memory(*)\Dedicated Usage',
    'GPU Adapter Memory', fDedicatedCounter);
  if fEngineCounter <> 0 then
    PdhCollectQueryData(fQuery);
end;

destructor TMachineOverviewGpuProvider.Destroy;
var
  lStatus: Longint;
begin
  if fQuery <> 0 then
  begin
    lStatus := PdhCloseQuery(fQuery);
    if lStatus <> 0 then
      OutputDebugString(PChar(Format(
        'Machine Overview GPU PDH query close failed: 0x%.8x',
        [Cardinal(lStatus)])));
  end;
  fSamples.Free;
  inherited Destroy;
end;

procedure TMachineOverviewGpuProvider.AddCounter(const aPath, aName: string;
  out aCounter: TPdhCounterHandle);
var
  lErrorText: string;
  lStatus: Longint;
begin
  aCounter := 0;
  if fQuery = 0 then
    Exit;
  lStatus := PdhAddEnglishCounterW(fQuery, PWideChar(aPath), 0, aCounter);
  if lStatus = 0 then
    Exit;
  aCounter := 0;
  lErrorText := Format('%s unavailable: 0x%.8x',
    [aName, Cardinal(lStatus)]);
  if fInitializationError.IsEmpty then
    fInitializationError := lErrorText
  else
    fInitializationError := fInitializationError + '; ' + lErrorText;
end;

procedure TMachineOverviewGpuProvider.AddMeasurement(
  var aSample: TMachineOverviewProviderSample; const aIndex: Integer;
  const aName, aUnitText: string; const aValue: Double;
  const aAvailable: Boolean;
  const aDisplayText, aDetailText, aStatusText: string);
begin
  aSample.Measurements[aIndex] := Default(TMachineOverviewMeasurement);
  aSample.Measurements[aIndex].Name := aName;
  aSample.Measurements[aIndex].UnitText := aUnitText;
  aSample.Measurements[aIndex].Value := aValue;
  aSample.Measurements[aIndex].Available := aAvailable;
  aSample.Measurements[aIndex].DisplayText := aDisplayText;
  aSample.Measurements[aIndex].DetailText := aDetailText;
  aSample.Measurements[aIndex].StatusText := aStatusText;
end;

procedure TMachineOverviewGpuProvider.PruneSamples(
  const aNowMonotonicMs: UInt64);
var
  lCutoffMs: UInt64;
begin
  if aNowMonotonicMs > cMachineOverviewGpuRetentionMs then
    lCutoffMs := aNowMonotonicMs - cMachineOverviewGpuRetentionMs
  else
    lCutoffMs := 0;
  while (fSamples.Count > 0) and
    (fSamples[0].CapturedAtMonotonicMs <= lCutoffMs) do
    fSamples.Delete(0);
end;

procedure TMachineOverviewGpuProvider.PublishSample(
  out aSample: TMachineOverviewProviderSample;
  const aCapturedAtUtc: TDateTime; const aNowMonotonicMs: UInt64;
  const aStatus: TMachineOverviewProviderStatus; const aErrorText: string);
var
  lDedicatedAgeMs: UInt64;
  lDedicatedStatus: string;
  lSamples: TArray<TMachineOverviewTimedGpuSample>;
  lSummaryAgeMs: UInt64;
  lSummaryStatus: string;
  lWindow15: TMachineOverviewWindowStatistics;
  lWindow5: TMachineOverviewWindowStatistics;
  lWindow60: TMachineOverviewWindowStatistics;
begin
  aSample := Default(TMachineOverviewProviderSample);
  aSample.State.ProviderId := ProviderId;
  aSample.State.Status := aStatus;
  aSample.State.CapturedAtUtc := aCapturedAtUtc;
  aSample.State.CapturedAtMonotonicMs := aNowMonotonicMs;
  aSample.State.ErrorText := aErrorText;
  if fLastSummary.Available then
    lSummaryAgeMs := aNowMonotonicMs - fLastSummaryCapturedAtMonotonicMs
  else
    lSummaryAgeMs := 0;
  aSample.State.DataAgeMs := lSummaryAgeMs;
  if aStatus = TMachineOverviewProviderStatus.Available then
    lSummaryStatus := 'WDDM GPU Engine; current'
  else if fLastSummary.Available then
    lSummaryStatus := Format('WDDM GPU Engine; Stale; age %d ms',
      [lSummaryAgeMs])
  else
    lSummaryStatus := aErrorText;

  lSamples := fSamples.ToArray;
  lWindow5 := CalculateMachineOverviewGpuWindow(lSamples,
    aNowMonotonicMs, 5000, fExpectedIntervalMs);
  lWindow15 := CalculateMachineOverviewGpuWindow(lSamples,
    aNowMonotonicMs, 15000, fExpectedIntervalMs);
  lWindow60 := CalculateMachineOverviewGpuWindow(lSamples,
    aNowMonotonicMs, 60000, fExpectedIntervalMs);
  SetLength(aSample.Measurements, 9);
  AddMeasurement(aSample, 0, 'gpu_overall_percent', '%',
    fLastSummary.Percent, fLastSummary.Available,
    fLastSummary.BusiestEngine,
    'Busiest valid WDDM engine; engine percentages are never summed',
    lSummaryStatus);
  AddMeasurement(aSample, 1, 'gpu_average_5s', '%', lWindow5.Average,
    lWindow5.Available, '', '', MachineOverviewWindowStatusText(lWindow5));
  AddMeasurement(aSample, 2, 'gpu_peak_5s', '%', lWindow5.Peak,
    lWindow5.Available, '', '', MachineOverviewWindowStatusText(lWindow5));
  AddMeasurement(aSample, 3, 'gpu_average_15s', '%', lWindow15.Average,
    lWindow15.Available, '', '', MachineOverviewWindowStatusText(lWindow15));
  AddMeasurement(aSample, 4, 'gpu_peak_15s', '%', lWindow15.Peak,
    lWindow15.Available, '', '', MachineOverviewWindowStatusText(lWindow15));
  AddMeasurement(aSample, 5, 'gpu_average_60s', '%', lWindow60.Average,
    lWindow60.Available, '', '', MachineOverviewWindowStatusText(lWindow60));
  AddMeasurement(aSample, 6, 'gpu_peak_60s', '%', lWindow60.Peak,
    lWindow60.Available, '', '', MachineOverviewWindowStatusText(lWindow60));
  if fLastDedicatedAvailable then
    lDedicatedAgeMs := aNowMonotonicMs -
      fLastDedicatedCapturedAtMonotonicMs
  else
    lDedicatedAgeMs := 0;
  if fLastDedicatedAvailable and (lDedicatedAgeMs = 0) then
    lDedicatedStatus := 'WDDM GPU Adapter Memory; current'
  else if fLastDedicatedAvailable then
    lDedicatedStatus := Format('WDDM GPU Adapter Memory; Stale; age %d ms',
      [lDedicatedAgeMs])
  else if fInitializationError.IsEmpty then
    lDedicatedStatus := 'WDDM dedicated memory unavailable'
  else
    lDedicatedStatus := fInitializationError;
  AddMeasurement(aSample, 7, 'gpu_dedicated_bytes', 'bytes',
    fLastDedicatedBytes, fLastDedicatedAvailable, '',
    'Sum of valid WDDM dedicated usage for current GPU adapters',
    lDedicatedStatus);
  AddMeasurement(aSample, 8, 'gpu_engine_instance_count', 'count',
    fLastSummary.ValidEngineCount, fLastSummary.Available, '',
    'Valid WDDM GPU Engine instances in the current sample', lSummaryStatus);
end;

function TMachineOverviewGpuProvider.TryReadCounterArray(
  const aCounter: TPdhCounterHandle;
  out aReadings: TArray<TMachineOverviewGpuCounterReading>): Boolean;
var
  g: TGarbos;
  lBuffer: TBytes;
  lBufferSize: Cardinal;
  lItem: PPdhFormattedCounterValueItem;
  lItemCount: Cardinal;
  lLastIndex: Cardinal;
  lList: TList<TMachineOverviewGpuCounterReading>;
  lReading: TMachineOverviewGpuCounterReading;
  lStatus: Longint;
  lValue: Double;
  i: Cardinal;
begin
  g := Default(TGarbos);
  SetLength(aReadings, 0);
  Result := False;
  if aCounter = 0 then
    Exit;
  lBufferSize := 0;
  lItemCount := 0;
  lStatus := PdhGetFormattedCounterArrayW(aCounter, cPdhFormatDouble,
    lBufferSize, lItemCount, nil);
  if (lStatus <> cPdhMoreData) or (lBufferSize = 0) then
    Exit;
  SetLength(lBuffer, lBufferSize);
  lStatus := PdhGetFormattedCounterArrayW(aCounter, cPdhFormatDouble,
    lBufferSize, lItemCount, @lBuffer[0]);
  if (lStatus <> 0) or
    (not TryMachineOverviewCounterIndexBounds(lItemCount, lLastIndex)) then
    Exit;
  GC(lList, TList<TMachineOverviewGpuCounterReading>.Create, g);
  lItem := Pointer(lBuffer);
  i := 0;
  while i <= lLastIndex do
  begin
    if (not SameText(string(lItem^.Name), '_Total')) and
      TryAcceptMachineOverviewPdhValue(lItem^.Value.Status,
        lItem^.Value.DoubleValue, 0, MaxDouble, lValue) then
    begin
      lReading := Default(TMachineOverviewGpuCounterReading);
      lReading.InstanceName := string(lItem^.Name);
      lReading.Value := lValue;
      lReading.Available := True;
      lList.Add(lReading);
    end;
    Inc(lItem);
    Inc(i);
  end;
  aReadings := lList.ToArray;
  Result := Length(aReadings) > 0;
end;

procedure TMachineOverviewGpuProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
var
  lCapturedAtUtc: TDateTime;
  lDedicatedBytes: Double;
  lDedicatedReadings: TArray<TMachineOverviewGpuCounterReading>;
  lEngineReadings: TArray<TMachineOverviewGpuCounterReading>;
  lErrorText: string;
  lNowMonotonicMs: UInt64;
  lStatus: Longint;
  lSummary: TMachineOverviewGpuSummary;
  lTimedSample: TMachineOverviewTimedGpuSample;
begin
  lCapturedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
  lNowMonotonicMs := GetTickCount64;
  if (fQuery = 0) or (fEngineCounter = 0) then
  begin
    PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
      TMachineOverviewProviderStatus.Unavailable, fInitializationError);
    Exit;
  end;
  lStatus := PdhCollectQueryData(fQuery);
  if lStatus <> 0 then
  begin
    lErrorText := Format('WDDM PDH collection failed: 0x%.8x',
      [Cardinal(lStatus)]);
    if fLastSummary.Available then
      PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
        TMachineOverviewProviderStatus.Stale, lErrorText)
    else
      PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
        TMachineOverviewProviderStatus.Failed, lErrorText);
    Exit;
  end;
  if TryReadCounterArray(fEngineCounter, lEngineReadings) then
    lSummary := SummarizeMachineOverviewGpuEngines(lEngineReadings)
  else
    lSummary := Default(TMachineOverviewGpuSummary);
  if not lSummary.Available then
  begin
    lErrorText := 'WDDM GPU Engine returned no valid instances';
    if fLastSummary.Available then
      PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
        TMachineOverviewProviderStatus.Stale, lErrorText)
    else
      PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
        TMachineOverviewProviderStatus.Unavailable, lErrorText);
    Exit;
  end;
  fLastSummary := lSummary;
  fLastSummaryCapturedAtMonotonicMs := lNowMonotonicMs;
  lTimedSample.CapturedAtMonotonicMs := lNowMonotonicMs;
  lTimedSample.Percent := lSummary.Percent;
  fSamples.Add(lTimedSample);
  PruneSamples(lNowMonotonicMs);
  if TryReadCounterArray(fDedicatedCounter, lDedicatedReadings) and
    SumMachineOverviewGpuDedicatedMemory(lDedicatedReadings,
      lDedicatedBytes) then
  begin
    fLastDedicatedAvailable := True;
    fLastDedicatedBytes := lDedicatedBytes;
    fLastDedicatedCapturedAtMonotonicMs := lNowMonotonicMs;
  end;
  PublishSample(aSample, lCapturedAtUtc, lNowMonotonicMs,
    TMachineOverviewProviderStatus.Available, fInitializationError);
end;

function TMachineOverviewGpuProvider.ProviderId: string;
begin
  Result := 'gpu';
end;

function CreateMachineOverviewGpuProvider: IMachineOverviewProvider;
begin
  Result := TMachineOverviewGpuProvider.Create;
end;

end.

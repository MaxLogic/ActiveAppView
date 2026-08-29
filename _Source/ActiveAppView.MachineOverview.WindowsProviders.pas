unit ActiveAppView.MachineOverview.WindowsProviders;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewForegroundProbeStatus = (Responsive, TimedOut, PermissionDenied,
    WindowGone, Unavailable, Failed);

  TMachineOverviewForegroundProbeResult = record
    Status: TMachineOverviewForegroundProbeStatus;
    ResponseMs: TMachineOverviewOptionalDouble;
    ErrorCode: Cardinal;
  end;

function TryAcceptMachineOverviewPdhValue(const aCounterStatus: Cardinal;
  const aValue, aMinimum, aMaximum: Double; out aAcceptedValue: Double): Boolean;
function TryMachineOverviewCounterDelta(const aCurrentValue, aPreviousValue: UInt64;
  const aHasPreviousValue: Boolean; out aDelta: UInt64): Boolean;
function TryMachineOverviewPageCountToBytes(const aPageCount, aPageSize: UInt64;
  out aBytes: UInt64): Boolean;
function TryMachineOverviewCounterIndexBounds(const aItemCount: Cardinal;
  out aLastIndex: Cardinal): Boolean;
function ClassifyMachineOverviewWindowsProviderStatus(const aCoreAvailable,
  aPdhAvailable: Boolean): TMachineOverviewProviderStatus;
function ClassifyMachineOverviewForegroundProbe(const aWindowWasValid,
  aWindowIsValid, aSendSucceeded: Boolean; const aLastError: Cardinal;
  const aElapsedMs, aTimeoutMs: UInt64): TMachineOverviewForegroundProbeResult;
function CreateMachineOverviewWindowsProvider: IMachineOverviewProvider;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.Math, System.StrUtils,
  System.SysUtils,
  Winapi.DwmApi, Winapi.Messages, Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.Domain;

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

  TMachineOverviewPerformanceInformation = record
    Size: Cardinal;
    CommitTotal: NativeUInt;
    CommitLimit: NativeUInt;
    CommitPeak: NativeUInt;
    PhysicalTotal: NativeUInt;
    PhysicalAvailable: NativeUInt;
    SystemCache: NativeUInt;
    KernelTotal: NativeUInt;
    KernelPaged: NativeUInt;
    KernelNonPaged: NativeUInt;
    PageSize: NativeUInt;
    HandleCount: Cardinal;
    ProcessCount: Cardinal;
    ThreadCount: Cardinal;
  end;

  TMachineOverviewWindowsProvider = class(TInterfacedObject, IMachineOverviewProvider)
  private
    fCpuLogicalCounter: TPdhCounterHandle;
    fCpuTotalCounter: TPdhCounterHandle;
    fDpcCounter: TPdhCounterHandle;
    fDpcRateCounter: TPdhCounterHandle;
    fHasPreviousDwm: Boolean;
    fInitializationError: string;
    fInterruptCounter: TPdhCounterHandle;
    fInterruptRateCounter: TPdhCounterHandle;
    fPagesInputCounter: TPdhCounterHandle;
    fPagesOutputCounter: TPdhCounterHandle;
    fPreviousDwmDropped: UInt64;
    fPreviousDwmLate: UInt64;
    fPreviousDwmMissed: UInt64;
    fPreviousDwmRefresh: UInt64;
    fProcessorQueueCounter: TPdhCounterHandle;
    fQuery: TPdhQueryHandle;
    fRolling: TObject;
    procedure AddCounter(const aPath, aName: string;
      out aCounter: TPdhCounterHandle);
    procedure AddLogicalCpuMeasurements(
      const aMeasurements: TList<TMachineOverviewMeasurement>);
    procedure AddMeasurement(const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aName, aUnitText: string; const aAvailable: Boolean;
      const aValue: Double; const aStatusText: string = '');
    procedure AddPdhMeasurement(const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aCounter: TPdhCounterHandle; const aName, aUnitText: string;
      const aMinimum, aMaximum: Double);
    procedure CollectDwm(const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aWindow: HWND);
    function CollectPerformanceInformation(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      out aPageSize: UInt64): Boolean;
    procedure CollectForeground(const aMeasurements: TList<TMachineOverviewMeasurement>;
      out aWindow: HWND);
    procedure UpdateRollingMeasurements(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aNowMonotonicMs: UInt64);
    function TryReadPdhValue(const aCounter: TPdhCounterHandle;
      const aMinimum, aMaximum: Double; out aValue: Double): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

const
  cPdhFormatDouble = $00000200;
  cPdhMoreData = Longint($800007D2);
  cForegroundProbeTimeoutMs = 50;
  cRollingRetentionMs = 15 * 60 * 1000;
  cSystemExpectedIntervalMs = 1000;
  cMinimumCoveragePercent = 80.0;

function PdhOpenQueryW(const aDataSource: PWideChar; const aUserData: NativeUInt;
  var aQuery: TPdhQueryHandle): Longint; stdcall; external 'pdh.dll';
function PdhAddEnglishCounterW(const aQuery: TPdhQueryHandle;
  const aCounterPath: PWideChar; const aUserData: NativeUInt;
  var aCounter: TPdhCounterHandle): Longint; stdcall; external 'pdh.dll';
function PdhCollectQueryData(const aQuery: TPdhQueryHandle): Longint; stdcall;
  external 'pdh.dll';
function PdhGetFormattedCounterValue(const aCounter: TPdhCounterHandle;
  const aFormat: Cardinal; const aCounterType: PCardinal;
  var aValue: TPdhFormattedCounterValue): Longint; stdcall; external 'pdh.dll';
function PdhGetFormattedCounterArrayW(const aCounter: TPdhCounterHandle;
  const aFormat: Cardinal; var aBufferSize, aItemCount: Cardinal;
  const aItems: Pointer): Longint; stdcall; external 'pdh.dll';
function PdhCloseQuery(const aQuery: TPdhQueryHandle): Longint; stdcall;
  external 'pdh.dll';
function GetPerformanceInfo(var aInformation: TMachineOverviewPerformanceInformation;
  const aSize: Cardinal): BOOL; stdcall; external 'psapi.dll';

function TryAcceptMachineOverviewPdhValue(const aCounterStatus: Cardinal;
  const aValue, aMinimum, aMaximum: Double; out aAcceptedValue: Double): Boolean;
begin
  aAcceptedValue := 0;
  Result := ((aCounterStatus = 0) or (aCounterStatus = 1)) and
    (aMinimum <= aMaximum) and (not IsNan(aValue)) and
    (not IsInfinite(aValue)) and (aValue >= aMinimum) and (aValue <= aMaximum);
  if Result then
    aAcceptedValue := aValue;
end;

function TryMachineOverviewCounterDelta(const aCurrentValue, aPreviousValue: UInt64;
  const aHasPreviousValue: Boolean; out aDelta: UInt64): Boolean;
begin
  aDelta := 0;
  Result := aHasPreviousValue and (aCurrentValue >= aPreviousValue);
  if Result then
    aDelta := aCurrentValue - aPreviousValue;
end;

function TryMachineOverviewPageCountToBytes(const aPageCount, aPageSize: UInt64;
  out aBytes: UInt64): Boolean;
begin
  aBytes := 0;
  Result := (aPageSize > 0) and
    ((aPageCount = 0) or (aPageCount <= High(UInt64) div aPageSize));
  if Result then
    aBytes := aPageCount * aPageSize;
end;

function TryMachineOverviewCounterIndexBounds(const aItemCount: Cardinal;
  out aLastIndex: Cardinal): Boolean;
begin
  Result := aItemCount > 0;
  if Result then
    aLastIndex := aItemCount - 1
  else
    aLastIndex := 0;
end;

function ClassifyMachineOverviewWindowsProviderStatus(const aCoreAvailable,
  aPdhAvailable: Boolean): TMachineOverviewProviderStatus;
begin
  if aCoreAvailable or aPdhAvailable then
    Result := TMachineOverviewProviderStatus.Available
  else
    Result := TMachineOverviewProviderStatus.Unavailable;
end;

function ClassifyMachineOverviewForegroundProbe(const aWindowWasValid,
  aWindowIsValid, aSendSucceeded: Boolean; const aLastError: Cardinal;
  const aElapsedMs, aTimeoutMs: UInt64): TMachineOverviewForegroundProbeResult;
begin
  Result := Default(TMachineOverviewForegroundProbeResult);
  Result.ErrorCode := aLastError;
  if not aWindowWasValid then
    Result.Status := TMachineOverviewForegroundProbeStatus.Unavailable
  else if aSendSucceeded then
  begin
    Result.Status := TMachineOverviewForegroundProbeStatus.Responsive;
    Result.ResponseMs.Available := True;
    Result.ResponseMs.Value := aElapsedMs;
  end else if not aWindowIsValid then
    Result.Status := TMachineOverviewForegroundProbeStatus.WindowGone
  else if aLastError = ERROR_ACCESS_DENIED then
    Result.Status := TMachineOverviewForegroundProbeStatus.PermissionDenied
  else if (aElapsedMs >= aTimeoutMs) or (aLastError = ERROR_TIMEOUT) then
    Result.Status := TMachineOverviewForegroundProbeStatus.TimedOut
  else
    Result.Status := TMachineOverviewForegroundProbeStatus.Failed;
end;

constructor TMachineOverviewWindowsProvider.Create;
var
  lStatus: Longint;
begin
  inherited Create;
  fRolling := TMachineOverviewRollingMeasurements.Create(cRollingRetentionMs);
  fQuery := 0;
  lStatus := PdhOpenQueryW(nil, 0, fQuery);
  if lStatus <> 0 then
  begin
    fInitializationError := Format('PDH query open failed: 0x%.8x', [Cardinal(lStatus)]);
    Exit;
  end;
  AddCounter('\Processor Information(_Total)\% Processor Time',
    'cpu_total_percent', fCpuTotalCounter);
  AddCounter('\Processor Information(*)\% Processor Time',
    'cpu_logical', fCpuLogicalCounter);
  AddCounter('\Processor Information(_Total)\% DPC Time',
    'dpc_percent', fDpcCounter);
  AddCounter('\Processor Information(_Total)\DPC Rate',
    'dpc_rate', fDpcRateCounter);
  AddCounter('\Processor Information(_Total)\% Interrupt Time',
    'interrupt_percent', fInterruptCounter);
  AddCounter('\Processor Information(_Total)\Interrupts/sec',
    'interrupts_per_sec', fInterruptRateCounter);
  AddCounter('\Memory\Pages Input/sec', 'pages_input_per_sec', fPagesInputCounter);
  AddCounter('\Memory\Pages Output/sec', 'pages_output_per_sec', fPagesOutputCounter);
  AddCounter('\System\Processor Queue Length',
    'processor_queue_length', fProcessorQueueCounter);
end;

destructor TMachineOverviewWindowsProvider.Destroy;
var
  lStatus: Longint;
begin
  if fQuery <> 0 then
  begin
    lStatus := PdhCloseQuery(fQuery);
    if lStatus <> 0 then
      OutputDebugString(PChar(Format(
        'Machine Overview PDH query close failed: 0x%.8x', [Cardinal(lStatus)])));
  end;
  fRolling.Free;
  inherited Destroy;
end;

procedure TMachineOverviewWindowsProvider.AddCounter(const aPath, aName: string;
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
  lErrorText := Format('%s unavailable: 0x%.8x', [aName, Cardinal(lStatus)]);
  if fInitializationError.IsEmpty then
    fInitializationError := lErrorText
  else
    fInitializationError := fInitializationError + '; ' + lErrorText;
end;

procedure TMachineOverviewWindowsProvider.AddMeasurement(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aName, aUnitText: string; const aAvailable: Boolean;
  const aValue: Double; const aStatusText: string);
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := aName;
  lMeasurement.UnitText := aUnitText;
  lMeasurement.Available := aAvailable;
  lMeasurement.StatusText := aStatusText;
  if aAvailable then
    lMeasurement.Value := aValue;
  aMeasurements.Add(lMeasurement);
end;

procedure TMachineOverviewWindowsProvider.AddPdhMeasurement(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aCounter: TPdhCounterHandle; const aName, aUnitText: string;
  const aMinimum, aMaximum: Double);
var
  lValue: Double;
begin
  if TryReadPdhValue(aCounter, aMinimum, aMaximum, lValue) then
    AddMeasurement(aMeasurements, aName, aUnitText, True, lValue)
  else
    AddMeasurement(aMeasurements, aName, aUnitText, False, 0);
end;

function FindMeasurement(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
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

procedure TMachineOverviewWindowsProvider.UpdateRollingMeasurements(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aNowMonotonicMs: UInt64);
const
  cSourceNames: array[0..3] of string = ('paging_bytes_per_sec',
    'physical_available_bytes', 'foreground_reply_ms', 'dpc_percent');
var
  lMeasurement: TMachineOverviewMeasurement;
  lMinimum: Double;
  lMinimumAvailable: Boolean;
  lOptional: TMachineOverviewOptionalDouble;
  lRolling: TMachineOverviewRollingMeasurements;
  lSourceName: string;
  lStatistics: TMachineOverviewWindowStatistics;
begin
  lRolling := fRolling as TMachineOverviewRollingMeasurements;
  for lSourceName in cSourceNames do
  begin
    lOptional := Default(TMachineOverviewOptionalDouble);
    if FindMeasurement(aMeasurements, lSourceName, lMeasurement) then
    begin
      lOptional.Available := lMeasurement.Available;
      lOptional.Value := lMeasurement.Value;
    end;
    lRolling.Observe(lSourceName, aNowMonotonicMs, lOptional);
  end;
  lRolling.Prune(aNowMonotonicMs);

  lStatistics := lRolling.Statistics('paging_bytes_per_sec',
    aNowMonotonicMs, 60000, cSystemExpectedIntervalMs,
    cMinimumCoveragePercent);
  AddMeasurement(aMeasurements, 'paging_bytes_per_sec_peak_60s',
    'bytes_per_second', lStatistics.Available, lStatistics.Peak,
    MachineOverviewWindowStatusText(lStatistics));
  lStatistics := lRolling.Statistics('physical_available_bytes',
    aNowMonotonicMs, cRollingRetentionMs, cSystemExpectedIntervalMs,
    cMinimumCoveragePercent);
  lMinimumAvailable := lRolling.TryMinimum('physical_available_bytes',
    aNowMonotonicMs, cRollingRetentionMs, lMinimum);
  AddMeasurement(aMeasurements, 'physical_available_bytes_low_15m', 'bytes',
    lMinimumAvailable, lMinimum,
    MachineOverviewWindowStatusText(lStatistics));
  lStatistics := lRolling.Statistics('foreground_reply_ms',
    aNowMonotonicMs, 60000, cSystemExpectedIntervalMs,
    cMinimumCoveragePercent);
  AddMeasurement(aMeasurements, 'foreground_reply_max_60s', 'milliseconds',
    lStatistics.Available, lStatistics.Peak,
    MachineOverviewWindowStatusText(lStatistics));
  lStatistics := lRolling.Statistics('dpc_percent', aNowMonotonicMs, 60000,
    cSystemExpectedIntervalMs, cMinimumCoveragePercent);
  AddMeasurement(aMeasurements, 'dpc_percent_max_60s', 'percent',
    lStatistics.Available, lStatistics.Peak,
    MachineOverviewWindowStatusText(lStatistics));
end;

function TMachineOverviewWindowsProvider.TryReadPdhValue(
  const aCounter: TPdhCounterHandle; const aMinimum, aMaximum: Double;
  out aValue: Double): Boolean;
var
  lFormattedValue: TPdhFormattedCounterValue;
  lStatus: Longint;
begin
  aValue := 0;
  if aCounter = 0 then
    Exit(False);
  lFormattedValue := Default(TPdhFormattedCounterValue);
  lStatus := PdhGetFormattedCounterValue(aCounter, cPdhFormatDouble, nil,
    lFormattedValue);
  Result := (lStatus = 0) and TryAcceptMachineOverviewPdhValue(
    lFormattedValue.Status, lFormattedValue.DoubleValue, aMinimum, aMaximum, aValue);
end;

procedure TMachineOverviewWindowsProvider.AddLogicalCpuMeasurements(
  const aMeasurements: TList<TMachineOverviewMeasurement>);
var
  g: TGarbos;
  lBuffer: TBytes;
  lBufferSize: Cardinal;
  lExpectedCount: Cardinal;
  lItem: PPdhFormattedCounterValueItem;
  lItemCount: Cardinal;
  lLastIndex: Cardinal;
  lLogicalMeasurements: TList<TMachineOverviewMeasurement>;
  lMeasurement: TMachineOverviewMeasurement;
  lName: string;
  lStatus: Longint;
  lValue: Double;
  i: Cardinal;
begin
  g := Default(TGarbos);
  GC(lLogicalMeasurements, TList<TMachineOverviewMeasurement>.Create, g);
  lBufferSize := 0;
  lItemCount := 0;
  if fCpuLogicalCounter <> 0 then
  begin
    lStatus := PdhGetFormattedCounterArrayW(fCpuLogicalCounter, cPdhFormatDouble,
      lBufferSize, lItemCount, nil);
    if (lStatus = cPdhMoreData) and (lBufferSize > 0) then
    begin
      SetLength(lBuffer, lBufferSize);
      lStatus := PdhGetFormattedCounterArrayW(fCpuLogicalCounter, cPdhFormatDouble,
        lBufferSize, lItemCount, Pointer(lBuffer));
      if lStatus = 0 then
      begin
        lItem := Pointer(lBuffer);
        if TryMachineOverviewCounterIndexBounds(lItemCount, lLastIndex) then
        begin
          i := 0;
          while i <= lLastIndex do
          begin
            lName := string(lItem^.Name);
            if (not SameText(lName, '_Total')) and
              (not EndsText(',_Total', lName)) then
            begin
              lMeasurement := Default(TMachineOverviewMeasurement);
              lMeasurement.Name := 'cpu_logical:' + lName;
              lMeasurement.UnitText := 'percent';
              lMeasurement.Available := TryAcceptMachineOverviewPdhValue(
                lItem^.Value.Status, lItem^.Value.DoubleValue, 0, 100, lValue);
              if lMeasurement.Available then
                lMeasurement.Value := lValue;
              lLogicalMeasurements.Add(lMeasurement);
            end;
            Inc(lItem);
            Inc(i);
          end;
        end;
      end;
    end;
  end;

  lExpectedCount := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  if lLogicalMeasurements.Count < Integer(lExpectedCount) then
  begin
    lLogicalMeasurements.Clear;
    if TryMachineOverviewCounterIndexBounds(lExpectedCount, lLastIndex) then
      for i := 0 to lLastIndex do
        AddMeasurement(lLogicalMeasurements, 'cpu_logical:' + UIntToStr(i),
          'percent', False, 0);
  end;
  for lMeasurement in lLogicalMeasurements do
    aMeasurements.Add(lMeasurement);
end;

function TMachineOverviewWindowsProvider.CollectPerformanceInformation(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  out aPageSize: UInt64): Boolean;
var
  lAvailableBytes: UInt64;
  lCommitLimitBytes: UInt64;
  lCommitTotalBytes: UInt64;
  lInformation: TMachineOverviewPerformanceInformation;
  lPhysicalTotalBytes: UInt64;
  lUsedPercent: Double;
begin
  aPageSize := 0;
  lInformation := Default(TMachineOverviewPerformanceInformation);
  lInformation.Size := SizeOf(lInformation);
  Result := GetPerformanceInfo(lInformation, SizeOf(lInformation));
  if Result then
    Result := TryMachineOverviewPageCountToBytes(lInformation.PhysicalTotal,
      lInformation.PageSize, lPhysicalTotalBytes);
  if Result then
    Result := TryMachineOverviewPageCountToBytes(lInformation.PhysicalAvailable,
      lInformation.PageSize, lAvailableBytes);
  if Result then
    Result := TryMachineOverviewPageCountToBytes(lInformation.CommitTotal,
      lInformation.PageSize, lCommitTotalBytes);
  if Result then
    Result := TryMachineOverviewPageCountToBytes(lInformation.CommitLimit,
      lInformation.PageSize, lCommitLimitBytes);
  if Result then
    Result := lAvailableBytes <= lPhysicalTotalBytes;
  if not Result then
  begin
    AddMeasurement(aMeasurements, 'physical_total_bytes', 'bytes', False, 0);
    AddMeasurement(aMeasurements, 'physical_available_bytes', 'bytes', False, 0);
    AddMeasurement(aMeasurements, 'physical_used_percent', 'percent', False, 0);
    AddMeasurement(aMeasurements, 'commit_total_bytes', 'bytes', False, 0);
    AddMeasurement(aMeasurements, 'commit_limit_bytes', 'bytes', False, 0);
    AddMeasurement(aMeasurements, 'commit_percent', 'percent', False, 0);
    AddMeasurement(aMeasurements, 'process_count', 'count', False, 0);
    AddMeasurement(aMeasurements, 'thread_count', 'count', False, 0);
    AddMeasurement(aMeasurements, 'handle_count', 'count', False, 0);
    Exit;
  end;

  aPageSize := lInformation.PageSize;
  AddMeasurement(aMeasurements, 'physical_total_bytes', 'bytes', True,
    lPhysicalTotalBytes);
  AddMeasurement(aMeasurements, 'physical_available_bytes', 'bytes', True,
    lAvailableBytes);
  if lPhysicalTotalBytes > 0 then
  begin
    lUsedPercent := (lPhysicalTotalBytes - lAvailableBytes) * 100.0 /
      lPhysicalTotalBytes;
    AddMeasurement(aMeasurements, 'physical_used_percent', 'percent', True,
      lUsedPercent);
  end else
    AddMeasurement(aMeasurements, 'physical_used_percent', 'percent', False, 0);
  AddMeasurement(aMeasurements, 'commit_total_bytes', 'bytes', True,
    lCommitTotalBytes);
  AddMeasurement(aMeasurements, 'commit_limit_bytes', 'bytes', True,
    lCommitLimitBytes);
  if lCommitLimitBytes > 0 then
    AddMeasurement(aMeasurements, 'commit_percent', 'percent', True,
      lCommitTotalBytes * 100.0 / lCommitLimitBytes)
  else
    AddMeasurement(aMeasurements, 'commit_percent', 'percent', False, 0);
  AddMeasurement(aMeasurements, 'process_count', 'count', True,
    lInformation.ProcessCount);
  AddMeasurement(aMeasurements, 'thread_count', 'count', True,
    lInformation.ThreadCount);
  AddMeasurement(aMeasurements, 'handle_count', 'count', True,
    lInformation.HandleCount);
end;

procedure TMachineOverviewWindowsProvider.CollectForeground(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  out aWindow: HWND);
var
  lElapsedMs: UInt64;
  lLastError: Cardinal;
  lProbe: TMachineOverviewForegroundProbeResult;
  lSendSucceeded: Boolean;
  lStartedMs: UInt64;
  lWindowIsValid: Boolean;
  lWindowWasValid: Boolean;
begin
  aWindow := GetForegroundWindow;
  lWindowWasValid := (aWindow <> 0) and IsWindow(aWindow);
  lSendSucceeded := False;
  lLastError := 0;
  lStartedMs := GetTickCount64;
  if lWindowWasValid then
  begin
    SetLastError(ERROR_SUCCESS);
    lSendSucceeded := SendMessageTimeoutW(aWindow, WM_NULL, 0, 0,
      SMTO_ABORTIFHUNG or SMTO_BLOCK or SMTO_ERRORONEXIT,
      cForegroundProbeTimeoutMs, nil) <> 0;
    if not lSendSucceeded then
      lLastError := GetLastError;
  end;
  lElapsedMs := GetTickCount64 - lStartedMs;
  lWindowIsValid := (aWindow <> 0) and IsWindow(aWindow);
  lProbe := ClassifyMachineOverviewForegroundProbe(lWindowWasValid,
    lWindowIsValid, lSendSucceeded, lLastError, lElapsedMs,
    cForegroundProbeTimeoutMs);
  AddMeasurement(aMeasurements, 'foreground_status', 'enum', True,
    Ord(lProbe.Status));
  AddMeasurement(aMeasurements, 'foreground_reply_ms', 'milliseconds',
    lProbe.ResponseMs.Available, lProbe.ResponseMs.Value);
  AddMeasurement(aMeasurements, 'foreground_error_code', 'win32_error',
    lProbe.ErrorCode <> 0, lProbe.ErrorCode);
end;

procedure TMachineOverviewWindowsProvider.CollectDwm(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aWindow: HWND);
var
  lDelta: UInt64;
  lInfo: TDwmTimingInfo;
  lResult: HResult;
begin
  lInfo := Default(TDwmTimingInfo);
  lInfo.cbSize := SizeOf(lInfo);
  lResult := DwmGetCompositionTimingInfo(aWindow, lInfo);
  if lResult < 0 then
  begin
    fHasPreviousDwm := False;
    AddMeasurement(aMeasurements, 'dwm_refresh_delta', 'count', False, 0);
    AddMeasurement(aMeasurements, 'dwm_frames_late_delta', 'count', False, 0);
    AddMeasurement(aMeasurements, 'dwm_frames_dropped_delta', 'count', False, 0);
    AddMeasurement(aMeasurements, 'dwm_frames_missed_delta', 'count', False, 0);
    Exit;
  end;

  if TryMachineOverviewCounterDelta(lInfo.cRefresh, fPreviousDwmRefresh,
    fHasPreviousDwm, lDelta) then
    AddMeasurement(aMeasurements, 'dwm_refresh_delta', 'count', True, lDelta)
  else
    AddMeasurement(aMeasurements, 'dwm_refresh_delta', 'count', False, 0);
  if TryMachineOverviewCounterDelta(lInfo.cFramesLate, fPreviousDwmLate,
    fHasPreviousDwm, lDelta) then
    AddMeasurement(aMeasurements, 'dwm_frames_late_delta', 'count', True, lDelta)
  else
    AddMeasurement(aMeasurements, 'dwm_frames_late_delta', 'count', False, 0);
  if TryMachineOverviewCounterDelta(lInfo.cFramesDropped, fPreviousDwmDropped,
    fHasPreviousDwm, lDelta) then
    AddMeasurement(aMeasurements, 'dwm_frames_dropped_delta', 'count', True, lDelta)
  else
    AddMeasurement(aMeasurements, 'dwm_frames_dropped_delta', 'count', False, 0);
  if TryMachineOverviewCounterDelta(lInfo.cFramesMissed, fPreviousDwmMissed,
    fHasPreviousDwm, lDelta) then
    AddMeasurement(aMeasurements, 'dwm_frames_missed_delta', 'count', True, lDelta)
  else
    AddMeasurement(aMeasurements, 'dwm_frames_missed_delta', 'count', False, 0);
  fPreviousDwmRefresh := lInfo.cRefresh;
  fPreviousDwmLate := lInfo.cFramesLate;
  fPreviousDwmDropped := lInfo.cFramesDropped;
  fPreviousDwmMissed := lInfo.cFramesMissed;
  fHasPreviousDwm := True;
end;

procedure TMachineOverviewWindowsProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
var
  g: TGarbos;
  lCoreAvailable: Boolean;
  lErrorText: string;
  lMeasurements: TList<TMachineOverviewMeasurement>;
  lNowMonotonicMs: UInt64;
  lPageSize: UInt64;
  lPagesInput: Double;
  lPagesOutput: Double;
  lPdhStatus: Longint;
  lPdhWorking: Boolean;
  lWindow: HWND;
begin
  g := Default(TGarbos);
  aSample := Default(TMachineOverviewProviderSample);
  aSample.State.ProviderId := ProviderId;
  aSample.State.CapturedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
  lNowMonotonicMs := GetTickCount64;
  aSample.State.CapturedAtMonotonicMs := lNowMonotonicMs;
  GC(lMeasurements, TList<TMachineOverviewMeasurement>.Create, g);
  lPdhStatus := -1;
  lPdhWorking := False;
  if fQuery <> 0 then
  begin
    lPdhStatus := PdhCollectQueryData(fQuery);
    lPdhWorking := lPdhStatus = 0;
  end;
  if lPdhWorking then
  begin
    AddPdhMeasurement(lMeasurements, fCpuTotalCounter, 'cpu_total_percent',
      'percent', 0, 100);
    AddLogicalCpuMeasurements(lMeasurements);
    AddPdhMeasurement(lMeasurements, fDpcCounter, 'dpc_percent',
      'percent', 0, 100);
    AddPdhMeasurement(lMeasurements, fInterruptCounter, 'interrupt_percent',
      'percent', 0, 100);
    AddPdhMeasurement(lMeasurements, fInterruptRateCounter,
      'interrupts_per_sec', 'count_per_second', 0, MaxDouble);
    AddPdhMeasurement(lMeasurements, fDpcRateCounter, 'dpc_rate',
      'count_per_second', 0, MaxDouble);
    AddPdhMeasurement(lMeasurements, fProcessorQueueCounter,
      'processor_queue_length', 'count', 0, MaxDouble);
  end else
  begin
    AddMeasurement(lMeasurements, 'cpu_total_percent', 'percent', False, 0);
    AddLogicalCpuMeasurements(lMeasurements);
    AddMeasurement(lMeasurements, 'dpc_percent', 'percent', False, 0);
    AddMeasurement(lMeasurements, 'interrupt_percent', 'percent', False, 0);
    AddMeasurement(lMeasurements, 'interrupts_per_sec',
      'count_per_second', False, 0);
    AddMeasurement(lMeasurements, 'dpc_rate', 'count_per_second', False, 0);
    AddMeasurement(lMeasurements, 'processor_queue_length', 'count', False, 0);
  end;

  lCoreAvailable := CollectPerformanceInformation(lMeasurements, lPageSize);
  if lPdhWorking and TryReadPdhValue(fPagesInputCounter, 0, MaxDouble,
    lPagesInput) and TryReadPdhValue(fPagesOutputCounter, 0, MaxDouble,
    lPagesOutput) and (lPageSize > 0) then
    AddMeasurement(lMeasurements, 'paging_bytes_per_sec', 'bytes_per_second',
      True, (lPagesInput + lPagesOutput) * lPageSize)
  else
    AddMeasurement(lMeasurements, 'paging_bytes_per_sec',
      'bytes_per_second', False, 0);
  CollectForeground(lMeasurements, lWindow);
  CollectDwm(lMeasurements, lWindow);
  UpdateRollingMeasurements(lMeasurements, lNowMonotonicMs);
  aSample.Measurements := lMeasurements.ToArray;
  aSample.State.Status := ClassifyMachineOverviewWindowsProviderStatus(
    lCoreAvailable, lPdhWorking);
  lErrorText := fInitializationError;
  if (not lPdhWorking) and (lPdhStatus <> 0) then
  begin
    if not lErrorText.IsEmpty then
      lErrorText := lErrorText + '; ';
    lErrorText := lErrorText + Format('PDH collection failed: 0x%.8x',
      [Cardinal(lPdhStatus)]);
  end;
  aSample.State.ErrorText := lErrorText;
end;

function TMachineOverviewWindowsProvider.ProviderId: string;
begin
  Result := 'windows-core';
end;

function CreateMachineOverviewWindowsProvider: IMachineOverviewProvider;
begin
  Result := TMachineOverviewWindowsProvider.Create;
end;

end.

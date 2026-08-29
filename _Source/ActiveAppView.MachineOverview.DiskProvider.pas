unit ActiveAppView.MachineOverview.DiskProvider;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewVolumeFixture = record
    RootPath: string;
    DiskNumbers: TArray<Cardinal>;
    CapacityAvailable: Boolean;
    TotalBytes: UInt64;
    FreeBytes: UInt64;
  end;

  TMachineOverviewDiskVolume = record
    DiskNumber: Cardinal;
    RootPath: string;
    CapacityAvailable: Boolean;
    TotalBytes: UInt64;
    FreeBytes: UInt64;
  end;

  TMachineOverviewTimedDiskLatency = record
    CapturedAtMonotonicMs: UInt64;
    Available: Boolean;
    LatencyMs: Double;
  end;

function TryParseMachineOverviewPhysicalDiskInstance(const aInstanceName: string;
  out aDiskNumber: Cardinal): Boolean;
function BuildMachineOverviewDiskVolumes(
  const aVolumes: TArray<TMachineOverviewVolumeFixture>):
  TArray<TMachineOverviewDiskVolume>;
function TryCalculateMachineOverviewDiskMetric(const aDiskNumber: Cardinal;
  const aActivePercent, aReadBytesPerSecond, aWriteBytesPerSecond,
  aLatencySeconds, aQueueLength: Double;
  out aMetric: TMachineOverviewDiskMetric): Boolean;
function TryCalculateMachineOverviewDiskLatencyMaximum(
  const aSamples: TArray<TMachineOverviewTimedDiskLatency>;
  const aNowMonotonicMs, aWindowMs: UInt64; out aMaximumMs: Double): Boolean;
function CreateMachineOverviewDiskProvider: IMachineOverviewProvider;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.Generics.Defaults,
  System.Math, System.SysUtils,
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

  PMachineOverviewDiskExtent = ^TMachineOverviewDiskExtent;
  TMachineOverviewDiskExtent = record
    DiskNumber: Cardinal;
    AlignmentPadding: Cardinal;
    StartingOffset: Int64;
    ExtentLength: Int64;
  end;

  TMachineOverviewDiskProvider = class(TInterfacedObject,
    IMachineOverviewProvider)
  private
    fActiveCounter: TPdhCounterHandle;
    fCachedVolumes: TArray<TMachineOverviewDiskVolume>;
    fInitializationError: string;
    fLatencyCounter: TPdhCounterHandle;
    fLatencyHistory: TObjectDictionary<Cardinal,
      TList<TMachineOverviewTimedDiskLatency>>;
    fQueueCounter: TPdhCounterHandle;
    fQuery: TPdhQueryHandle;
    fReadCounter: TPdhCounterHandle;
    fVolumesCapturedAtMonotonicMs: UInt64;
    fWriteCounter: TPdhCounterHandle;
    procedure AddCounter(const aPath, aName: string;
      out aCounter: TPdhCounterHandle);
    procedure AddDiskMeasurement(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aMetric: TMachineOverviewDiskMetric; const aName, aUnitText: string;
      const aValue: Double);
    procedure AddVolumeMeasurements(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aDiskNumber: Cardinal);
    function GetLatencyMaximum(const aDiskNumber: Cardinal;
      const aNowMonotonicMs: UInt64; const aLatencyMs: Double;
      out aMaximumMs: Double): Boolean;
    procedure RefreshVolumes(const aNowMonotonicMs: UInt64);
    function TryReadCounterArray(const aCounter: TPdhCounterHandle;
      const aValues: TDictionary<string, Double>): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

const
  cPdhFormatDouble = $00000200;
  cPdhMoreData = Longint($800007D2);
  cMachineOverviewDiskLatencyWindowMs = 60000;
  cMachineOverviewVolumeRefreshIntervalMs = 30000;
  cMachineOverviewMaximumVolumeExtentBytes = 65536;

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

function TryParseMachineOverviewPhysicalDiskInstance(const aInstanceName: string;
  out aDiskNumber: Cardinal): Boolean;
var
  i: Integer;
  lName: string;
  lNumberText: string;
begin
  aDiskNumber := 0;
  lName := Trim(aInstanceName);
  i := 1;
  while (i <= Length(lName)) and CharInSet(lName[i], ['0'..'9']) do
    Inc(i);
  Result := (i > 1) and ((i > Length(lName)) or (lName[i] = ' '));
  if not Result then
    Exit;
  lNumberText := Copy(lName, 1, i - 1);
  Result := TryStrToUInt(lNumberText, aDiskNumber);
end;

function BuildMachineOverviewDiskVolumes(
  const aVolumes: TArray<TMachineOverviewVolumeFixture>):
  TArray<TMachineOverviewDiskVolume>;
var
  g: TGarbos;
  lDiskNumber: Cardinal;
  lKey: string;
  lList: TList<TMachineOverviewDiskVolume>;
  lSeen: TDictionary<string, Boolean>;
  lVolume: TMachineOverviewDiskVolume;
  lVolumeFixture: TMachineOverviewVolumeFixture;
begin
  g := Default(TGarbos);
  GC(lList, TList<TMachineOverviewDiskVolume>.Create, g);
  GC(lSeen, TDictionary<string, Boolean>.Create, g);
  for lVolumeFixture in aVolumes do
    for lDiskNumber in lVolumeFixture.DiskNumbers do
    begin
      lKey := UIntToStr(lDiskNumber) + '|' +
        LowerCase(Trim(lVolumeFixture.RootPath));
      if lSeen.ContainsKey(lKey) then
        Continue;
      lSeen.Add(lKey, True);
      lVolume := Default(TMachineOverviewDiskVolume);
      lVolume.DiskNumber := lDiskNumber;
      lVolume.RootPath := lVolumeFixture.RootPath;
      lVolume.CapacityAvailable := lVolumeFixture.CapacityAvailable and
        (lVolumeFixture.FreeBytes <= lVolumeFixture.TotalBytes);
      if lVolume.CapacityAvailable then
      begin
        lVolume.TotalBytes := lVolumeFixture.TotalBytes;
        lVolume.FreeBytes := lVolumeFixture.FreeBytes;
      end;
      lList.Add(lVolume);
    end;
  lList.Sort(TComparer<TMachineOverviewDiskVolume>.Construct(
    function(const aLeft, aRight: TMachineOverviewDiskVolume): Integer
    begin
      if aLeft.DiskNumber < aRight.DiskNumber then
        Exit(-1);
      if aLeft.DiskNumber > aRight.DiskNumber then
        Exit(1);
      Result := CompareText(aLeft.RootPath, aRight.RootPath);
    end));
  Result := lList.ToArray;
end;

function TryCalculateMachineOverviewDiskMetric(const aDiskNumber: Cardinal;
  const aActivePercent, aReadBytesPerSecond, aWriteBytesPerSecond,
  aLatencySeconds, aQueueLength: Double;
  out aMetric: TMachineOverviewDiskMetric): Boolean;
begin
  aMetric := Default(TMachineOverviewDiskMetric);
  Result := (aActivePercent >= 0) and (aReadBytesPerSecond >= 0) and
    (aWriteBytesPerSecond >= 0) and (aLatencySeconds >= 0) and
    (aQueueLength >= 0) and (not IsNan(aActivePercent)) and
    (not IsInfinite(aActivePercent)) and (not IsNan(aReadBytesPerSecond)) and
    (not IsInfinite(aReadBytesPerSecond)) and
    (not IsNan(aWriteBytesPerSecond)) and
    (not IsInfinite(aWriteBytesPerSecond)) and
    (not IsNan(aLatencySeconds)) and (not IsInfinite(aLatencySeconds)) and
    (not IsNan(aQueueLength)) and (not IsInfinite(aQueueLength));
  if not Result then
    Exit;
  aMetric.Identity.StableId := 'physical:' + UIntToStr(aDiskNumber);
  aMetric.Identity.DisplayName := 'Disk ' + UIntToStr(aDiskNumber);
  aMetric.Available := True;
  aMetric.SustainedActivePercent := Min(aActivePercent, 100);
  aMetric.ReadMBPerSecond := aReadBytesPerSecond / 1048576;
  aMetric.WriteMBPerSecond := aWriteBytesPerSecond / 1048576;
  aMetric.SustainedLatencyMs := aLatencySeconds * 1000;
  aMetric.SustainedQueueLength := aQueueLength;
  Result := not IsInfinite(aMetric.SustainedLatencyMs);
  if not Result then
    aMetric := Default(TMachineOverviewDiskMetric);
end;

function TryCalculateMachineOverviewDiskLatencyMaximum(
  const aSamples: TArray<TMachineOverviewTimedDiskLatency>;
  const aNowMonotonicMs, aWindowMs: UInt64; out aMaximumMs: Double): Boolean;
var
  lSample: TMachineOverviewTimedDiskLatency;
begin
  aMaximumMs := 0;
  Result := False;
  if aWindowMs = 0 then
    Exit;
  for lSample in aSamples do
    if lSample.Available and (lSample.LatencyMs >= 0) and
      (not IsNan(lSample.LatencyMs)) and (not IsInfinite(lSample.LatencyMs)) and
      (aNowMonotonicMs >= lSample.CapturedAtMonotonicMs) and
      ((aNowMonotonicMs - lSample.CapturedAtMonotonicMs) <= aWindowMs) then
    begin
      if (not Result) or (lSample.LatencyMs > aMaximumMs) then
        aMaximumMs := lSample.LatencyMs;
      Result := True;
    end;
end;

function TryGetVolumeDiskNumbers(const aRootPath: string;
  out aDiskNumbers: TArray<Cardinal>): Boolean;
var
  lBuffer: TBytes;
  lBytesReturned: Cardinal;
  lDeviceHandle: THandle;
  lDevicePath: string;
  lExtent: PMachineOverviewDiskExtent;
  lExtentCount: Cardinal;
  lMaximumExtentCount: Cardinal;
  i: Cardinal;
begin
  aDiskNumbers := nil;
  Result := False;
  if Length(aRootPath) < 2 then
    Exit;
  if Copy(aRootPath, 1, 4) = '\\?\' then
  begin
    lDevicePath := aRootPath;
    if lDevicePath.EndsWith('\') then
      Delete(lDevicePath, Length(lDevicePath), 1);
  end else
    lDevicePath := '\\.\' + Copy(aRootPath, 1, 2);
  lDeviceHandle := CreateFileW(PWideChar(lDevicePath), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if lDeviceHandle = INVALID_HANDLE_VALUE then
    Exit;
  try
    SetLength(lBuffer, cMachineOverviewMaximumVolumeExtentBytes);
    lBytesReturned := 0;
    if not DeviceIoControl(lDeviceHandle, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,
      nil, 0, @lBuffer[0], Length(lBuffer), lBytesReturned, nil) or
      (lBytesReturned < 8) then
      Exit;
    lExtentCount := PCardinal(@lBuffer[0])^;
    lMaximumExtentCount := (lBytesReturned - 8) div
      SizeOf(TMachineOverviewDiskExtent);
    if (lExtentCount = 0) or (lExtentCount > lMaximumExtentCount) then
      Exit;
    SetLength(aDiskNumbers, lExtentCount);
    lExtent := Pointer(NativeUInt(@lBuffer[0]) + 8);
    for i := 0 to lExtentCount - 1 do
    begin
      aDiskNumbers[i] := lExtent^.DiskNumber;
      Inc(lExtent);
    end;
    Result := True;
  finally
    CloseHandle(lDeviceHandle);
  end;
end;

function GetMachineOverviewVolumeDisplayPath(
  const aVolumeName: string): string;
var
  g: TGarbos;
  lBuffer: TArray<WideChar>;
  lPath: string;
  lPaths: TList<string>;
  lPosition: Cardinal;
  lRequiredChars: Cardinal;
begin
  g := Default(TGarbos);
  Result := aVolumeName;
  lRequiredChars := 0;
  GetVolumePathNamesForVolumeNameW(PWideChar(aVolumeName), nil, 0,
    lRequiredChars);
  if lRequiredChars = 0 then
    Exit;
  SetLength(lBuffer, lRequiredChars);
  if not GetVolumePathNamesForVolumeNameW(PWideChar(aVolumeName),
    @lBuffer[0], Length(lBuffer), lRequiredChars) then
    Exit;
  GC(lPaths, TList<string>.Create, g);
  lPosition := 0;
  while (lPosition < Cardinal(Length(lBuffer))) and
    (lBuffer[lPosition] <> #0) do
  begin
    lPath := PWideChar(@lBuffer[lPosition]);
    Inc(lPosition, Length(lPath) + 1);
    if not lPath.IsEmpty then
      lPaths.Add(lPath);
  end;
  if lPaths.Count = 0 then
    Exit;
  lPaths.Sort;
  Result := string.Join('; ', lPaths.ToArray);
end;

function LoadMachineOverviewDiskVolumes:
  TArray<TMachineOverviewDiskVolume>;
var
  g: TGarbos;
  lBuffer: TArray<WideChar>;
  lDiskNumbers: TArray<Cardinal>;
  lDriveType: Cardinal;
  lFindHandle: THandle;
  lFreeAvailable: TULargeInteger;
  lFreeTotal: TULargeInteger;
  lTotal: TULargeInteger;
  lVolume: TMachineOverviewVolumeFixture;
  lVolumeName: string;
  lVolumes: TList<TMachineOverviewVolumeFixture>;
begin
  g := Default(TGarbos);
  GC(lVolumes, TList<TMachineOverviewVolumeFixture>.Create, g);
  SetLength(lBuffer, MAX_PATH + 1);
  lFindHandle := FindFirstVolumeW(@lBuffer[0], Length(lBuffer));
  if lFindHandle = INVALID_HANDLE_VALUE then
    Exit(nil);
  try
    repeat
    begin
      lVolumeName := PWideChar(@lBuffer[0]);
      lDriveType := GetDriveTypeW(PWideChar(lVolumeName));
      if (lDriveType in [DRIVE_FIXED, DRIVE_REMOVABLE]) and
        TryGetVolumeDiskNumbers(lVolumeName, lDiskNumbers) then
      begin
        lVolume := Default(TMachineOverviewVolumeFixture);
        lVolume.RootPath := GetMachineOverviewVolumeDisplayPath(lVolumeName);
        lVolume.DiskNumbers := lDiskNumbers;
        lFreeAvailable := Default(TULargeInteger);
        lFreeTotal := Default(TULargeInteger);
        lTotal := Default(TULargeInteger);
        lVolume.CapacityAvailable := GetDiskFreeSpaceExW(
          PWideChar(lVolumeName), lFreeAvailable, lTotal, @lFreeTotal);
        if lVolume.CapacityAvailable then
        begin
          lVolume.TotalBytes := lTotal;
          lVolume.FreeBytes := lFreeTotal;
        end;
        lVolumes.Add(lVolume);
      end;
    end;
    until not FindNextVolumeW(lFindHandle, @lBuffer[0], Length(lBuffer));
  finally
    FindVolumeClose(lFindHandle);
  end;
  Result := BuildMachineOverviewDiskVolumes(lVolumes.ToArray);
end;

constructor TMachineOverviewDiskProvider.Create;
var
  lStatus: Longint;
begin
  inherited Create;
  fLatencyHistory := TObjectDictionary<Cardinal,
    TList<TMachineOverviewTimedDiskLatency>>.Create([doOwnsValues]);
  fQuery := 0;
  lStatus := PdhOpenQueryW(nil, 0, fQuery);
  if lStatus <> 0 then
  begin
    fInitializationError := Format('PDH disk query open failed: 0x%.8x',
      [Cardinal(lStatus)]);
    Exit;
  end;
  AddCounter('\PhysicalDisk(*)\% Disk Time', 'disk_active_percent',
    fActiveCounter);
  AddCounter('\PhysicalDisk(*)\Disk Read Bytes/sec', 'disk_read_bytes',
    fReadCounter);
  AddCounter('\PhysicalDisk(*)\Disk Write Bytes/sec', 'disk_write_bytes',
    fWriteCounter);
  AddCounter('\PhysicalDisk(*)\Avg. Disk sec/Transfer', 'disk_latency',
    fLatencyCounter);
  AddCounter('\PhysicalDisk(*)\Current Disk Queue Length', 'disk_queue',
    fQueueCounter);
end;

destructor TMachineOverviewDiskProvider.Destroy;
var
  lStatus: Longint;
begin
  if fQuery <> 0 then
  begin
    lStatus := PdhCloseQuery(fQuery);
    if lStatus <> 0 then
      OutputDebugString(PChar(Format(
        'Machine Overview disk PDH query close failed: 0x%.8x',
        [Cardinal(lStatus)])));
  end;
  fLatencyHistory.Free;
  inherited Destroy;
end;

procedure TMachineOverviewDiskProvider.AddCounter(const aPath, aName: string;
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

function TMachineOverviewDiskProvider.TryReadCounterArray(
  const aCounter: TPdhCounterHandle;
  const aValues: TDictionary<string, Double>): Boolean;
var
  lBuffer: TBytes;
  lBufferSize: Cardinal;
  lItem: PPdhFormattedCounterValueItem;
  lItemCount: Cardinal;
  lLastIndex: Cardinal;
  lName: string;
  lStatus: Longint;
  lValue: Double;
  i: Cardinal;
begin
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
  lItem := Pointer(lBuffer);
  i := 0;
  while i <= lLastIndex do
  begin
    lName := string(lItem^.Name);
    if (not SameText(lName, '_Total')) and
      TryAcceptMachineOverviewPdhValue(lItem^.Value.Status,
        lItem^.Value.DoubleValue, 0, MaxDouble, lValue) then
      aValues.AddOrSetValue(lName, lValue);
    Inc(lItem);
    Inc(i);
  end;
  Result := aValues.Count > 0;
end;

procedure TMachineOverviewDiskProvider.AddDiskMeasurement(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aMetric: TMachineOverviewDiskMetric; const aName, aUnitText: string;
  const aValue: Double);
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := aName + ':' + aMetric.Identity.StableId;
  lMeasurement.EntityId := aMetric.Identity.StableId;
  lMeasurement.DisplayText := aMetric.Identity.DisplayName;
  lMeasurement.UnitText := aUnitText;
  lMeasurement.Available := True;
  lMeasurement.Value := aValue;
  aMeasurements.Add(lMeasurement);
end;

procedure TMachineOverviewDiskProvider.AddVolumeMeasurements(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aDiskNumber: Cardinal);
var
  lMeasurement: TMachineOverviewMeasurement;
  lVolume: TMachineOverviewDiskVolume;
  lVolumeIndex: Integer;
begin
  lVolumeIndex := 0;
  for lVolume in fCachedVolumes do
    if lVolume.DiskNumber = aDiskNumber then
    begin
      Inc(lVolumeIndex);
      lMeasurement := Default(TMachineOverviewMeasurement);
      lMeasurement.Name := 'disk_volume_total_bytes:' + UIntToStr(aDiskNumber) +
        ':' + IntToStr(lVolumeIndex);
      lMeasurement.EntityId := 'physical:' + UIntToStr(aDiskNumber);
      lMeasurement.DisplayText := lVolume.RootPath;
      lMeasurement.UnitText := 'bytes';
      lMeasurement.Available := lVolume.CapacityAvailable;
      if lMeasurement.Available then
        lMeasurement.Value := lVolume.TotalBytes;
      aMeasurements.Add(lMeasurement);
      lMeasurement.Name := 'disk_volume_free_bytes:' + UIntToStr(aDiskNumber) +
        ':' + IntToStr(lVolumeIndex);
      if lMeasurement.Available then
        lMeasurement.Value := lVolume.FreeBytes;
      aMeasurements.Add(lMeasurement);
    end;
end;

function TMachineOverviewDiskProvider.GetLatencyMaximum(
  const aDiskNumber: Cardinal; const aNowMonotonicMs: UInt64;
  const aLatencyMs: Double; out aMaximumMs: Double): Boolean;
var
  lHistory: TList<TMachineOverviewTimedDiskLatency>;
  lSample: TMachineOverviewTimedDiskLatency;
  i: Integer;
begin
  if not fLatencyHistory.TryGetValue(aDiskNumber, lHistory) then
  begin
    lHistory := TList<TMachineOverviewTimedDiskLatency>.Create;
    fLatencyHistory.Add(aDiskNumber, lHistory);
  end;
  lSample := Default(TMachineOverviewTimedDiskLatency);
  lSample.CapturedAtMonotonicMs := aNowMonotonicMs;
  lSample.Available := True;
  lSample.LatencyMs := aLatencyMs;
  lHistory.Add(lSample);
  for i := lHistory.Count - 1 downto 0 do
    if (aNowMonotonicMs >= lHistory[i].CapturedAtMonotonicMs) and
      ((aNowMonotonicMs - lHistory[i].CapturedAtMonotonicMs) >
        cMachineOverviewDiskLatencyWindowMs) then
      lHistory.Delete(i);
  Result := TryCalculateMachineOverviewDiskLatencyMaximum(lHistory.ToArray,
    aNowMonotonicMs, cMachineOverviewDiskLatencyWindowMs, aMaximumMs);
end;

procedure TMachineOverviewDiskProvider.RefreshVolumes(
  const aNowMonotonicMs: UInt64);
begin
  if (fVolumesCapturedAtMonotonicMs > 0) and
    (aNowMonotonicMs >= fVolumesCapturedAtMonotonicMs) and
    ((aNowMonotonicMs - fVolumesCapturedAtMonotonicMs) <
      cMachineOverviewVolumeRefreshIntervalMs) then
    Exit;
  fCachedVolumes := LoadMachineOverviewDiskVolumes;
  fVolumesCapturedAtMonotonicMs := aNowMonotonicMs;
end;

procedure TMachineOverviewDiskProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
var
  g: TGarbos;
  lActive: Double;
  lActiveValues: TDictionary<string, Double>;
  lDiskInstances: TDictionary<Cardinal, string>;
  lDiskNumber: Cardinal;
  lInstanceName: string;
  lInstances: TDictionary<string, Boolean>;
  lLatency: Double;
  lLatencyMaximum: Double;
  lLatencyValues: TDictionary<string, Double>;
  lMeasurement: TMachineOverviewMeasurement;
  lMeasurements: TList<TMachineOverviewMeasurement>;
  lMetric: TMachineOverviewDiskMetric;
  lMetrics: TList<TMachineOverviewDiskMetric>;
  lNowMonotonicMs: UInt64;
  lPdhStatus: Longint;
  lQueue: Double;
  lQueueValues: TDictionary<string, Double>;
  lRead: Double;
  lReadValues: TDictionary<string, Double>;
  lSelection: TMachineOverviewDiskSelection;
  lWrite: Double;
  lWriteValues: TDictionary<string, Double>;
begin
  g := Default(TGarbos);
  aSample := Default(TMachineOverviewProviderSample);
  aSample.State.ProviderId := ProviderId;
  aSample.State.CapturedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
  lNowMonotonicMs := GetTickCount64;
  aSample.State.CapturedAtMonotonicMs := lNowMonotonicMs;
  RefreshVolumes(lNowMonotonicMs);
  GC(lActiveValues, TDictionary<string, Double>.Create, g);
  GC(lReadValues, TDictionary<string, Double>.Create, g);
  GC(lWriteValues, TDictionary<string, Double>.Create, g);
  GC(lLatencyValues, TDictionary<string, Double>.Create, g);
  GC(lQueueValues, TDictionary<string, Double>.Create, g);
  GC(lInstances, TDictionary<string, Boolean>.Create, g);
  GC(lDiskInstances, TDictionary<Cardinal, string>.Create, g);
  GC(lMeasurements, TList<TMachineOverviewMeasurement>.Create, g);
  GC(lMetrics, TList<TMachineOverviewDiskMetric>.Create, g);
  lPdhStatus := -1;
  if fQuery <> 0 then
    lPdhStatus := PdhCollectQueryData(fQuery);
  if lPdhStatus = 0 then
  begin
    TryReadCounterArray(fActiveCounter, lActiveValues);
    TryReadCounterArray(fReadCounter, lReadValues);
    TryReadCounterArray(fWriteCounter, lWriteValues);
    TryReadCounterArray(fLatencyCounter, lLatencyValues);
    TryReadCounterArray(fQueueCounter, lQueueValues);
  end;
  for lInstanceName in lActiveValues.Keys do
    lInstances.AddOrSetValue(lInstanceName, True);
  for lInstanceName in lReadValues.Keys do
    lInstances.AddOrSetValue(lInstanceName, True);
  for lInstanceName in lInstances.Keys do
    if TryParseMachineOverviewPhysicalDiskInstance(lInstanceName,
      lDiskNumber) then
      if (not lDiskInstances.ContainsKey(lDiskNumber)) or
        (CompareText(lInstanceName, lDiskInstances[lDiskNumber]) < 0) then
        lDiskInstances.AddOrSetValue(lDiskNumber, lInstanceName);

  for lDiskNumber in lDiskInstances.Keys do
  begin
    lInstanceName := lDiskInstances[lDiskNumber];
    if lActiveValues.TryGetValue(lInstanceName, lActive) and
      lReadValues.TryGetValue(lInstanceName, lRead) and
      lWriteValues.TryGetValue(lInstanceName, lWrite) and
      lLatencyValues.TryGetValue(lInstanceName, lLatency) and
      lQueueValues.TryGetValue(lInstanceName, lQueue) and
      TryCalculateMachineOverviewDiskMetric(lDiskNumber, lActive, lRead,
        lWrite, lLatency, lQueue, lMetric) then
    begin
      lMetrics.Add(lMetric);
      AddDiskMeasurement(lMeasurements, lMetric, 'disk_active_percent',
        'percent', lMetric.SustainedActivePercent);
      AddDiskMeasurement(lMeasurements, lMetric, 'disk_read_mb_per_sec',
        'megabytes_per_second', lMetric.ReadMBPerSecond);
      AddDiskMeasurement(lMeasurements, lMetric, 'disk_write_mb_per_sec',
        'megabytes_per_second', lMetric.WriteMBPerSecond);
      AddDiskMeasurement(lMeasurements, lMetric, 'disk_latency_ms',
        'milliseconds', lMetric.SustainedLatencyMs);
      AddDiskMeasurement(lMeasurements, lMetric, 'disk_queue_length',
        'count', lMetric.SustainedQueueLength);
      if GetLatencyMaximum(lDiskNumber, lNowMonotonicMs,
        lMetric.SustainedLatencyMs, lLatencyMaximum) then
        AddDiskMeasurement(lMeasurements, lMetric, 'disk_latency_max_60s',
          'milliseconds', lLatencyMaximum);
      AddVolumeMeasurements(lMeasurements, lDiskNumber);
    end;
  end;
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := 'disk_count';
  lMeasurement.UnitText := 'count';
  lMeasurement.Available := True;
  lMeasurement.Value := lDiskInstances.Count;
  lMeasurements.Add(lMeasurement);
  lMeasurement.Name := 'disk_volume_count';
  lMeasurement.Value := Length(fCachedVolumes);
  lMeasurements.Add(lMeasurement);
  if TrySelectWorstMachineOverviewDisk(lMetrics.ToArray, lSelection) then
  begin
    lMeasurement := Default(TMachineOverviewMeasurement);
    lMeasurement.Name := 'disk_worst';
    lMeasurement.EntityId := lSelection.Metric.Identity.StableId;
    lMeasurement.DisplayText := lSelection.Metric.Identity.DisplayName;
    lMeasurement.StatusText := IntToStr(Ord(lSelection.Reason));
    lMeasurement.UnitText := 'severity';
    lMeasurement.Available := True;
    lMeasurement.Value := Ord(lSelection.Severity);
    lMeasurements.Add(lMeasurement);
  end;
  aSample.Measurements := lMeasurements.ToArray;
  if lMetrics.Count > 0 then
    aSample.State.Status := TMachineOverviewProviderStatus.Available
  else
  begin
    aSample.State.Status := TMachineOverviewProviderStatus.Unavailable;
    aSample.State.ErrorText := fInitializationError;
    if (lPdhStatus <> 0) and aSample.State.ErrorText.IsEmpty then
      aSample.State.ErrorText := Format(
        'PDH disk collection unavailable: 0x%.8x', [Cardinal(lPdhStatus)]);
  end;
end;

function TMachineOverviewDiskProvider.ProviderId: string;
begin
  Result := 'disks';
end;

function CreateMachineOverviewDiskProvider: IMachineOverviewProvider;
begin
  Result := TMachineOverviewDiskProvider.Create;
end;

end.

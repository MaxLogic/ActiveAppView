unit ActiveAppView.MachineOverview.ProcessProvider;

interface

uses
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewProcessPathStatus = (Available, PermissionDenied, Exited,
    Unavailable);

  TMachineOverviewProcessDelta = record
    CpuAvailable: Boolean;
    CpuPercent: Double;
    RawCpuPercent: Double;
    RawProcessTimeDelta100ns: UInt64;
    IoAvailable: Boolean;
    IoBytesPerSecond: Double;
    RawIoDeltaBytes: UInt64;
  end;

function TryCalculateMachineOverviewProcessDelta(
  const aCurrentProcessTime100ns, aPreviousProcessTime100ns,
  aCurrentIoBytes, aPreviousIoBytes, aElapsedMs: UInt64;
  const aLogicalProcessorCount: Cardinal;
  out aDelta: TMachineOverviewProcessDelta): Boolean;
function TryCalculateMachineOverviewFirstProcessDelta( //PALOFF Our process-disk fixture calls this pure first-observation seam.
  const aCreationTime100ns, aPreviousCapturedAt100ns, aCapturedAt100ns,
  aProcessTime100ns, aElapsedMs: UInt64; const aLogicalProcessorCount: Cardinal;
  out aDelta: TMachineOverviewProcessDelta): Boolean;

function ShouldReuseMachineOverviewProcessPath(
  const aCachedIdentity, aCurrentIdentity: TMachineOverviewProcessIdentity;
  const aLastSeenMonotonicMs, aNowMonotonicMs,
  aInactivityTimeoutMs: UInt64): Boolean;
function ClassifyMachineOverviewProcessPathFailure(const aErrorCode: Cardinal;
  const aProcessStillExists: Boolean): TMachineOverviewProcessPathStatus;
function TryCalculateMachineOverviewPrivateWorkingSet(
  const aWorkingSetFlags: TArray<NativeUInt>; const aPageSize: Cardinal;
  out aPrivateBytes: UInt64): Boolean;
function SelectMachineOverviewResourceProcesses(const aMetrics: TArray<TMachineOverviewProcessMetric>; //PALOFF Our process-disk fixture uses the same bounded selector as live collection.
  const aIo: Boolean; out aMeasuredTotal: Double): TArray<TMachineOverviewProcessMetric>;
function CreateMachineOverviewProcessProvider: IMachineOverviewProvider;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.Math, System.SysUtils,
  Winapi.PsAPI, Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.Domain;

type
  TMachineOverviewProcessMemoryCountersEx2 = record
    cb: Cardinal;
    PageFaultCount: Cardinal;
    PeakWorkingSetSize: NativeUInt;
    WorkingSetSize: NativeUInt;
    QuotaPeakPagedPoolUsage: NativeUInt;
    QuotaPagedPoolUsage: NativeUInt;
    QuotaPeakNonPagedPoolUsage: NativeUInt;
    QuotaNonPagedPoolUsage: NativeUInt;
    PagefileUsage: NativeUInt;
    PeakPagefileUsage: NativeUInt;
    PrivateUsage: NativeUInt;
    PrivateWorkingSetSize: NativeUInt;
    SharedCommitUsage: UInt64;
  end;

  TMachineOverviewPreviousProcess = record
    Identity: TMachineOverviewProcessIdentity;
    IoAvailable: Boolean;
    IoBytes: UInt64;
    ProcessTime100ns: UInt64;
    WriteBytes: UInt64;
  end;

  TMachineOverviewProcessPathCacheEntry = record
    Identity: TMachineOverviewProcessIdentity;
    LastSeenMonotonicMs: UInt64;
    Path: string;
    Status: TMachineOverviewProcessPathStatus;
  end;

  TMachineOverviewCollectedProcess = record
    Delta: TMachineOverviewProcessDelta;
    DisplayName: string;
    HandleCount: Cardinal;
    HandleCountAvailable: Boolean;
    Identity: TMachineOverviewProcessIdentity;
    Path: string;
    PathStatus: TMachineOverviewProcessPathStatus;
    PrivateBytes: UInt64;
    PrivateUsageBytes: UInt64;
    PrivateBytesAvailable: Boolean;
    WriteBytesPerSecond: Double;
    WriteBytesPerSecondAvailable: Boolean;
    WorkingSetBytes: UInt64;
    WorkingSetBytesAvailable: Boolean;
  end;

  TMachineOverviewTopProcesses = array[0..9] of TMachineOverviewCollectedProcess;

  TMachineOverviewProcessProvider = class(TInterfacedObject,
    IMachineOverviewProvider)
  private
    fPathCache: TDictionary<string, TMachineOverviewProcessPathCacheEntry>;
    fPreviousCapturedAtMonotonicMs: UInt64;
    fPreviousCapturedAtFileTime: UInt64;
    fPreviousProcesses: TDictionary<string, TMachineOverviewPreviousProcess>;
    fRolling: TObject;
    procedure AddDiagnostic(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aName, aUnitText: string; const aValue: Double);
    procedure AddRankedMeasurements(
      const aMeasurements: TList<TMachineOverviewMeasurement>;
      const aPrefix, aUnitText: string;
      const aRanked: TArray<TMachineOverviewRankedProcess>;
      const aProcesses: TList<TMachineOverviewCollectedProcess>;
      const aNowMonotonicMs: UInt64);
    function CollectProcess(const aProcessId: Cardinal;
      const aNowMonotonicMs, aElapsedMs, aCapturedAtFileTime: UInt64;
      const aLogicalProcessorCount: Cardinal;
      const aSeenIdentities: TDictionary<string, Boolean>;
      out aProcess: TMachineOverviewCollectedProcess;
      out aAccessDenied: Boolean): Boolean;
    procedure ExpireMissingProcesses(
      const aSeenIdentities: TDictionary<string, Boolean>);
    procedure UpdateRollingMeasurements(
      const aCpuRanked, aRamRanked,
      aIoRanked: TArray<TMachineOverviewRankedProcess>;
      const aNowMonotonicMs: UInt64);
    function ResolveProcessPath(const aProcessHandle: THandle;
      const aIdentity: TMachineOverviewProcessIdentity;
      const aNowMonotonicMs: UInt64; out aPath: string;
      out aStatus: TMachineOverviewProcessPathStatus): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

const
  cMachineOverviewMaximumProcessCount = 65536;
  cMachineOverviewMaximumProcessPathChars = 32768;
  cMachineOverviewPathInactivityTimeoutMs = 300000;
  cMachineOverviewProcessRollingRetentionMs = 60000;
  // matches the default ProcessSampleIntervalMs; drives window coverage checks
  cMachineOverviewProcessExpectedIntervalMs = 5000;
  cMachineOverviewMinimumCoveragePercent = 80.0;
  cProcessQueryLimitedInformation = $1000;

function QueryFullProcessImageNameW(const aProcess: THandle;
  const aFlags: Cardinal; const aFileName: PWideChar;
  var aSize: Cardinal): BOOL; stdcall; external 'kernel32.dll';

function FileTimeToUInt64(const aValue: TFileTime): UInt64;
begin
  Result := (UInt64(aValue.dwHighDateTime) shl 32) or
    UInt64(aValue.dwLowDateTime);
end;

function TryReadMachineOverviewProcessMemory(const aProcessHandle: THandle;
  out aWorkingSetBytes, aPrivateWorkingSetBytes, aPrivateUsageBytes: UInt64;
  out aPrivateWorkingSetAvailable: Boolean): Boolean;
var
  lCounters: TProcessMemoryCountersEx;
  lCountersEx2: TMachineOverviewProcessMemoryCountersEx2;
begin
  aWorkingSetBytes := 0;
  aPrivateWorkingSetBytes := 0;
  aPrivateUsageBytes := 0;
  aPrivateWorkingSetAvailable := False;
  lCountersEx2 := Default(TMachineOverviewProcessMemoryCountersEx2);
  lCountersEx2.cb := SizeOf(lCountersEx2);
  Result := GetProcessMemoryInfo(aProcessHandle,
    PPROCESS_MEMORY_COUNTERS(@lCountersEx2), SizeOf(lCountersEx2));
  if Result then
  begin
    aWorkingSetBytes := lCountersEx2.WorkingSetSize;
    aPrivateUsageBytes := lCountersEx2.PrivateUsage;
    aPrivateWorkingSetBytes := lCountersEx2.PrivateWorkingSetSize;
    aPrivateWorkingSetAvailable := True;
    Exit;
  end;
  lCounters := Default(TProcessMemoryCountersEx);
  lCounters.cb := SizeOf(lCounters);
  Result := GetProcessMemoryInfo(aProcessHandle,
    PPROCESS_MEMORY_COUNTERS(@lCounters), SizeOf(lCounters));
  if Result then
  begin
    aWorkingSetBytes := lCounters.WorkingSetSize;
    aPrivateUsageBytes := lCounters.PrivateUsage;
  end;
end;

function ProcessPathStatusText(
  const aStatus: TMachineOverviewProcessPathStatus): string;
begin
  case aStatus of
    TMachineOverviewProcessPathStatus.Available:
      Result := 'Available';
    TMachineOverviewProcessPathStatus.PermissionDenied:
      Result := 'Permission denied';
    TMachineOverviewProcessPathStatus.Exited:
      Result := 'Exited';
  else
    Result := 'Unavailable';
  end;
end;

// EnumProcesses instead of a Toolhelp snapshot: the snapshot walks every
// thread in the system and cost ~70 ms CPU per sample on a 600-process box.
// Names come from the cached image path of each process we can open.
function TryEnumerateProcesses(out aProcessIds: TArray<Cardinal>;
  out aErrorCode: Cardinal): Boolean;
var
  lBytesReturned: Cardinal;
  lCapacity: Integer;
  lCount: Integer;
  lIds: TArray<Cardinal>;
  i: Integer;
begin
  aProcessIds := nil;
  aErrorCode := ERROR_SUCCESS;
  lCapacity := 1024;
  repeat
    SetLength(lIds, lCapacity);
    if not EnumProcesses(PDWORD(lIds), lCapacity * SizeOf(Cardinal),
      lBytesReturned) then
    begin
      aErrorCode := GetLastError;
      Exit(False);
    end;
    if lBytesReturned < Cardinal(lCapacity * SizeOf(Cardinal)) then
      Break;
    if lCapacity >= cMachineOverviewMaximumProcessCount then
    begin
      aErrorCode := ERROR_INSUFFICIENT_BUFFER;
      Exit(False);
    end;
    lCapacity := lCapacity * 2;
  until False;
  SetLength(aProcessIds, lBytesReturned div SizeOf(Cardinal));
  lCount := 0;
  for i := 0 to High(aProcessIds) do
    if lIds[i] <> 0 then
    begin
      aProcessIds[lCount] := lIds[i];
      Inc(lCount);
    end;
  SetLength(aProcessIds, lCount);
  Result := True;
end;

function TryCalculateMachineOverviewProcessDelta(
  const aCurrentProcessTime100ns, aPreviousProcessTime100ns,
  aCurrentIoBytes, aPreviousIoBytes, aElapsedMs: UInt64;
  const aLogicalProcessorCount: Cardinal;
  out aDelta: TMachineOverviewProcessDelta): Boolean;
begin
  aDelta := Default(TMachineOverviewProcessDelta);
  Result := (aElapsedMs > 0) and (aLogicalProcessorCount > 0);
  if not Result then
    Exit;
  if aCurrentProcessTime100ns >= aPreviousProcessTime100ns then
  begin
    aDelta.RawProcessTimeDelta100ns :=
      aCurrentProcessTime100ns - aPreviousProcessTime100ns;
    aDelta.RawCpuPercent :=
      aDelta.RawProcessTimeDelta100ns * 100.0 /
      (aElapsedMs * 10000.0);
    aDelta.CpuAvailable := TryNormalizeMachineOverviewProcessCpu(
      aDelta.RawCpuPercent, aLogicalProcessorCount, aDelta.CpuPercent);
  end;
  if aCurrentIoBytes >= aPreviousIoBytes then
  begin
    aDelta.RawIoDeltaBytes := aCurrentIoBytes - aPreviousIoBytes;
    aDelta.IoBytesPerSecond := aDelta.RawIoDeltaBytes * 1000.0 / aElapsedMs;
    aDelta.IoAvailable := True;
  end;
  Result := aDelta.CpuAvailable or aDelta.IoAvailable;
end;

function TryCalculateMachineOverviewFirstProcessDelta(
  const aCreationTime100ns, aPreviousCapturedAt100ns, aCapturedAt100ns,
  aProcessTime100ns, aElapsedMs: UInt64; const aLogicalProcessorCount: Cardinal;
  out aDelta: TMachineOverviewProcessDelta): Boolean;
begin
  aDelta := Default(TMachineOverviewProcessDelta);
  Result := (aPreviousCapturedAt100ns > 0) and
    (aCreationTime100ns >= aPreviousCapturedAt100ns) and
    (aCreationTime100ns <= aCapturedAt100ns) and
    (aCapturedAt100ns > aPreviousCapturedAt100ns) and (aElapsedMs > 0) and (aLogicalProcessorCount > 0);
  if not Result then
    Exit;
  Result := TryCalculateMachineOverviewProcessDelta(aProcessTime100ns, 0, 0, 0,
    aElapsedMs, aLogicalProcessorCount, aDelta);
  aDelta.IoAvailable := False;
end;

constructor TMachineOverviewProcessProvider.Create;
begin
  inherited Create;
  fPathCache := TDictionary<string,
    TMachineOverviewProcessPathCacheEntry>.Create;
  fPreviousProcesses := TDictionary<string,
    TMachineOverviewPreviousProcess>.Create;
  fRolling := TMachineOverviewRollingMeasurements.Create(
    cMachineOverviewProcessRollingRetentionMs);
end;

destructor TMachineOverviewProcessProvider.Destroy;
begin
  fRolling.Free;
  fPreviousProcesses.Free;
  fPathCache.Free;
  inherited Destroy;
end;

procedure TMachineOverviewProcessProvider.AddDiagnostic(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aName, aUnitText: string; const aValue: Double);
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := aName;
  lMeasurement.UnitText := aUnitText;
  lMeasurement.Available := True;
  lMeasurement.Value := aValue;
  aMeasurements.Add(lMeasurement);
end;

function FindCollectedProcess(
  const aProcesses: TList<TMachineOverviewCollectedProcess>;
  const aIdentity: TMachineOverviewProcessIdentity;
  out aProcess: TMachineOverviewCollectedProcess): Boolean;
var
  lProcess: TMachineOverviewCollectedProcess;
begin
  for lProcess in aProcesses do
    if (lProcess.Identity.ProcessId = aIdentity.ProcessId) and
      (lProcess.Identity.CreationTime100ns = aIdentity.CreationTime100ns) then
    begin
      aProcess := lProcess;
      Exit(True);
    end;
  aProcess := Default(TMachineOverviewCollectedProcess);
  Result := False;
end;

function MachineOverviewApplicationKey(const aDisplayName: string): string;
begin
  Result := 'application:' + LowerCase(Trim(aDisplayName));
end;

function MachineOverviewProcessIdsText(
  const aIdentities: TArray<TMachineOverviewProcessIdentity>): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(aIdentities) do
  begin
    if not Result.IsEmpty then
      Result := Result + ', ';
    Result := Result + UIntToStr(aIdentities[i].ProcessId);
  end;
end;

procedure LimitRankedProcesses(
  var aRanked: TArray<TMachineOverviewRankedProcess>;
  const aMaximumCount: Integer);
begin
  if Length(aRanked) > aMaximumCount then
    SetLength(aRanked, aMaximumCount);
end;

procedure TMachineOverviewProcessProvider.AddRankedMeasurements(
  const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aPrefix, aUnitText: string;
  const aRanked: TArray<TMachineOverviewRankedProcess>;
  const aProcesses: TList<TMachineOverviewCollectedProcess>;
  const aNowMonotonicMs: UInt64);
var
  lApplicationKey: string;
  lIdentityKey: string;
  lMeasurement: TMachineOverviewMeasurement;
  lPidMeasurement: TMachineOverviewMeasurement;
  lProcess: TMachineOverviewCollectedProcess;
  lRankedProcess: TMachineOverviewRankedProcess;
  lRolling: TMachineOverviewRollingMeasurements;
  lStatistics: TMachineOverviewWindowStatistics;
begin
  lRolling := fRolling as TMachineOverviewRollingMeasurements;
  for lRankedProcess in aRanked do
  begin
    if not FindCollectedProcess(aProcesses, lRankedProcess.Metric.Identity,
      lProcess) then
      Continue;
    lMeasurement := Default(TMachineOverviewMeasurement);
    lMeasurement.Name := aPrefix + ':' + IntToStr(lRankedProcess.Rank);
    lIdentityKey := MachineOverviewProcessIdentityKey(lProcess.Identity);
    lApplicationKey := MachineOverviewApplicationKey(
      lRankedProcess.Metric.DisplayName);
    lMeasurement.EntityId := lIdentityKey;
    lMeasurement.DisplayText := lRankedProcess.Metric.DisplayName;
    lMeasurement.DetailText := lProcess.Path;
    lMeasurement.StatusText := ProcessPathStatusText(lProcess.PathStatus);
    lMeasurement.UnitText := aUnitText;
    lMeasurement.Available := True;
    lMeasurement.Value := lRankedProcess.Metric.MetricValue;
    aMeasurements.Add(lMeasurement);
    lPidMeasurement := Default(TMachineOverviewMeasurement);
    lPidMeasurement.Name := StringReplace(aPrefix, '_rank', '_pids', []) + ':' +
      IntToStr(lRankedProcess.Rank);
    lPidMeasurement.EntityId := lIdentityKey;
    lPidMeasurement.DisplayText := MachineOverviewProcessIdsText(
      lRankedProcess.Metric.Identities);
    lPidMeasurement.UnitText := 'process_ids';
    lPidMeasurement.Available := True;
    lPidMeasurement.Value := Length(lRankedProcess.Metric.Identities);
    aMeasurements.Add(lPidMeasurement);
    if aPrefix = 'process_cpu_rank' then
    begin
      lStatistics := lRolling.Statistics('cpu:' + lApplicationKey,
        aNowMonotonicMs, 15000, cMachineOverviewProcessExpectedIntervalMs,
        cMachineOverviewMinimumCoveragePercent);
      lMeasurement.Name := 'process_cpu_average_15s:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.UnitText := 'percent';
      lMeasurement.Available := lStatistics.Available;
      lMeasurement.Value := lStatistics.Average;
      lMeasurement.StatusText := MachineOverviewWindowStatusText(lStatistics);
      aMeasurements.Add(lMeasurement);
      lStatistics := lRolling.Statistics('cpu:' + lApplicationKey,
        aNowMonotonicMs, 60000, cMachineOverviewProcessExpectedIntervalMs,
        cMachineOverviewMinimumCoveragePercent);
      lMeasurement.Name := 'process_cpu_peak_60s:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.Available := lStatistics.Available;
      lMeasurement.Value := lStatistics.Peak;
      lMeasurement.StatusText := MachineOverviewWindowStatusText(lStatistics);
      aMeasurements.Add(lMeasurement);
      lMeasurement.Name := 'process_cpu_raw_percent:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.UnitText := 'raw_percent';
      lMeasurement.Available := True;
      lMeasurement.Value := lProcess.Delta.RawCpuPercent;
      lMeasurement.StatusText := '';
      aMeasurements.Add(lMeasurement);
      lMeasurement.Name := 'process_cpu_time_delta_100ns:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.UnitText := '100_nanoseconds';
      lMeasurement.Value := lProcess.Delta.RawProcessTimeDelta100ns;
      aMeasurements.Add(lMeasurement);
      if lProcess.HandleCountAvailable then
      begin
        lMeasurement.Name := 'process_handle_count:' +
          IntToStr(lRankedProcess.Rank);
        lMeasurement.UnitText := 'count';
        lMeasurement.Value := lProcess.HandleCount;
        aMeasurements.Add(lMeasurement);
      end;
    end else if aPrefix = 'process_ram_rank' then
    begin
      lStatistics := lRolling.Statistics('ram:' + lApplicationKey,
        aNowMonotonicMs, 60000, cMachineOverviewProcessExpectedIntervalMs,
        cMachineOverviewMinimumCoveragePercent);
      lMeasurement.Name := 'process_ram_peak_60s:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.UnitText := 'private_working_set_bytes';
      lMeasurement.Available := lStatistics.Available;
      lMeasurement.Value := lStatistics.Peak;
      lMeasurement.StatusText := MachineOverviewWindowStatusText(lStatistics);
      aMeasurements.Add(lMeasurement);
    end else if aPrefix = 'process_io_rank' then
    begin
      lStatistics := lRolling.Statistics('io:' + lApplicationKey,
        aNowMonotonicMs, 15000, cMachineOverviewProcessExpectedIntervalMs,
        cMachineOverviewMinimumCoveragePercent);
      lMeasurement.Name := 'process_io_average_15s:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.UnitText := 'bytes_per_second';
      lMeasurement.Available := lStatistics.Available;
      lMeasurement.Value := lStatistics.Average;
      lMeasurement.StatusText := MachineOverviewWindowStatusText(lStatistics);
      aMeasurements.Add(lMeasurement);
      lStatistics := lRolling.Statistics('io:' + lApplicationKey,
        aNowMonotonicMs, 60000, cMachineOverviewProcessExpectedIntervalMs,
        cMachineOverviewMinimumCoveragePercent);
      lMeasurement.Name := 'process_io_peak_60s:' +
        IntToStr(lRankedProcess.Rank);
      lMeasurement.Available := lStatistics.Available;
      lMeasurement.Value := lStatistics.Peak;
      lMeasurement.StatusText := MachineOverviewWindowStatusText(lStatistics);
      aMeasurements.Add(lMeasurement);
    end;
  end;
end;

procedure TMachineOverviewProcessProvider.UpdateRollingMeasurements(
  const aCpuRanked, aRamRanked,
  aIoRanked: TArray<TMachineOverviewRankedProcess>;
  const aNowMonotonicMs: UInt64);
var
  lOptional: TMachineOverviewOptionalDouble;
  lRankedProcess: TMachineOverviewRankedProcess;
  lRolling: TMachineOverviewRollingMeasurements;
begin
  lRolling := fRolling as TMachineOverviewRollingMeasurements;
  for lRankedProcess in aCpuRanked do
  begin
    lOptional := Default(TMachineOverviewOptionalDouble);
    lOptional.Available := True;
    lOptional.Value := lRankedProcess.Metric.MetricValue;
    lRolling.Observe('cpu:' + MachineOverviewApplicationKey(
      lRankedProcess.Metric.DisplayName), aNowMonotonicMs, lOptional);
  end;
  for lRankedProcess in aRamRanked do
  begin
    lOptional := Default(TMachineOverviewOptionalDouble);
    lOptional.Available := True;
    lOptional.Value := lRankedProcess.Metric.MetricValue;
    lRolling.Observe('ram:' + MachineOverviewApplicationKey(
      lRankedProcess.Metric.DisplayName), aNowMonotonicMs, lOptional);
  end;
  for lRankedProcess in aIoRanked do
  begin
    lOptional := Default(TMachineOverviewOptionalDouble);
    lOptional.Available := True;
    lOptional.Value := lRankedProcess.Metric.MetricValue;
    lRolling.Observe('io:' + MachineOverviewApplicationKey(
      lRankedProcess.Metric.DisplayName), aNowMonotonicMs, lOptional);
  end;
  lRolling.Prune(aNowMonotonicMs);
end;

function TMachineOverviewProcessProvider.ResolveProcessPath(
  const aProcessHandle: THandle;
  const aIdentity: TMachineOverviewProcessIdentity;
  const aNowMonotonicMs: UInt64; out aPath: string;
  out aStatus: TMachineOverviewProcessPathStatus): Boolean;
var
  lCacheEntry: TMachineOverviewProcessPathCacheEntry;
  lErrorCode: Cardinal;
  lExitCode: Cardinal;
  lKey: string;
  lPathBuffer: TArray<WideChar>;
  lPathLength: Cardinal;
  lProcessStillExists: Boolean;
begin
  lKey := MachineOverviewProcessIdentityKey(aIdentity);
  if fPathCache.TryGetValue(lKey, lCacheEntry) and
    ShouldReuseMachineOverviewProcessPath(lCacheEntry.Identity, aIdentity,
      lCacheEntry.LastSeenMonotonicMs, aNowMonotonicMs,
      cMachineOverviewPathInactivityTimeoutMs) then
  begin
    lCacheEntry.LastSeenMonotonicMs := aNowMonotonicMs;
    fPathCache.AddOrSetValue(lKey, lCacheEntry);
    aPath := lCacheEntry.Path;
    aStatus := lCacheEntry.Status;
    Exit(aStatus = TMachineOverviewProcessPathStatus.Available);
  end;

  SetLength(lPathBuffer, cMachineOverviewMaximumProcessPathChars);
  lPathLength := Length(lPathBuffer);
  SetLastError(ERROR_SUCCESS);
  Result := QueryFullProcessImageNameW(aProcessHandle, 0,
    @lPathBuffer[0], lPathLength);
  if Result then
  begin
    SetString(aPath, PWideChar(@lPathBuffer[0]), lPathLength);
    aStatus := TMachineOverviewProcessPathStatus.Available;
  end else
  begin
    lErrorCode := GetLastError;
    lExitCode := 0;
    lProcessStillExists := GetExitCodeProcess(aProcessHandle, lExitCode) and
      (lExitCode = STILL_ACTIVE);
    aPath := '';
    aStatus := ClassifyMachineOverviewProcessPathFailure(lErrorCode,
      lProcessStillExists);
  end;
  lCacheEntry := Default(TMachineOverviewProcessPathCacheEntry);
  lCacheEntry.Identity := aIdentity;
  lCacheEntry.LastSeenMonotonicMs := aNowMonotonicMs;
  lCacheEntry.Path := aPath;
  lCacheEntry.Status := aStatus;
  fPathCache.AddOrSetValue(lKey, lCacheEntry);
end;

function TMachineOverviewProcessProvider.CollectProcess(
  const aProcessId: Cardinal; const aNowMonotonicMs, aElapsedMs, aCapturedAtFileTime: UInt64;
  const aLogicalProcessorCount: Cardinal;
  const aSeenIdentities: TDictionary<string, Boolean>;
  out aProcess: TMachineOverviewCollectedProcess;
  out aAccessDenied: Boolean): Boolean;
var
  lCreationTime: TFileTime;
  lExitTime: TFileTime;
  lHandle: THandle;
  lHandleCount: Cardinal;
  lIoBytes: UInt64;
  lIoCounters: TIOCounters;
  lIoAvailable: Boolean;
  lKernelTime: TFileTime;
  lKey: string;
  lMemoryHandle: THandle;
  lPrevious: TMachineOverviewPreviousProcess;
  lProcessTime100ns: UInt64;
  lUserTime: TFileTime;
begin
  aProcess := Default(TMachineOverviewCollectedProcess);
  aAccessDenied := False;
  lHandle := OpenProcess(cProcessQueryLimitedInformation, False, aProcessId);
  if lHandle = 0 then
  begin
    aAccessDenied := GetLastError = ERROR_ACCESS_DENIED;
    Exit(False);
  end;
  try
    lCreationTime := Default(TFileTime);
    lExitTime := Default(TFileTime);
    lKernelTime := Default(TFileTime);
    lUserTime := Default(TFileTime);
    if not GetProcessTimes(lHandle, lCreationTime, lExitTime, lKernelTime,
      lUserTime) then
      Exit(False);
    aProcess.Identity.ProcessId := aProcessId;
    aProcess.Identity.CreationTime100ns := FileTimeToUInt64(lCreationTime);
    lKey := MachineOverviewProcessIdentityKey(aProcess.Identity);
    aSeenIdentities.AddOrSetValue(lKey, True);

    lProcessTime100ns := FileTimeToUInt64(lKernelTime) +
      FileTimeToUInt64(lUserTime);
    lIoCounters := Default(TIOCounters);
    lIoAvailable := GetProcessIoCounters(lHandle, lIoCounters) and
      (lIoCounters.ReadTransferCount <=
        High(UInt64) - lIoCounters.WriteTransferCount);
    if lIoAvailable then
      lIoBytes := lIoCounters.ReadTransferCount + lIoCounters.WriteTransferCount
    else
      lIoBytes := 0;

    if (aElapsedMs > 0) and fPreviousProcesses.TryGetValue(lKey, lPrevious) then
    begin
      if not TryCalculateMachineOverviewProcessDelta(lProcessTime100ns,
        lPrevious.ProcessTime100ns, lIoBytes, lPrevious.IoBytes, aElapsedMs,
        aLogicalProcessorCount, aProcess.Delta) then
        aProcess.Delta := Default(TMachineOverviewProcessDelta);
      if not (lIoAvailable and lPrevious.IoAvailable) then
      begin
        aProcess.Delta.IoAvailable := False;
        aProcess.Delta.IoBytesPerSecond := 0;
        aProcess.Delta.RawIoDeltaBytes := 0;
      end;
      if lIoAvailable and lPrevious.IoAvailable and
        (lIoCounters.WriteTransferCount >= lPrevious.WriteBytes) then
      begin
        aProcess.WriteBytesPerSecondAvailable := True;
        aProcess.WriteBytesPerSecond :=
          (lIoCounters.WriteTransferCount - lPrevious.WriteBytes) * 1000.0 /
          aElapsedMs;
      end;
    end;
    if not fPreviousProcesses.ContainsKey(lKey) then
      if not TryCalculateMachineOverviewFirstProcessDelta(aProcess.Identity.CreationTime100ns,
        fPreviousCapturedAtFileTime, aCapturedAtFileTime, lProcessTime100ns,
        aElapsedMs, aLogicalProcessorCount, aProcess.Delta) then
        aProcess.Delta := Default(TMachineOverviewProcessDelta);
    lPrevious := Default(TMachineOverviewPreviousProcess);
    lPrevious.Identity := aProcess.Identity;
    lPrevious.IoAvailable := lIoAvailable;
    lPrevious.IoBytes := lIoBytes;
    lPrevious.ProcessTime100ns := lProcessTime100ns;
    lPrevious.WriteBytes := lIoCounters.WriteTransferCount;
    fPreviousProcesses.AddOrSetValue(lKey, lPrevious);

    aProcess.WorkingSetBytesAvailable := TryReadMachineOverviewProcessMemory(
      lHandle, aProcess.WorkingSetBytes, aProcess.PrivateBytes, aProcess.PrivateUsageBytes,
      aProcess.PrivateBytesAvailable);
    if not aProcess.WorkingSetBytesAvailable then
    begin
      lMemoryHandle := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ,
        False, aProcessId);
      if lMemoryHandle <> 0 then
      try
        aProcess.WorkingSetBytesAvailable :=
          TryReadMachineOverviewProcessMemory(lMemoryHandle,
            aProcess.WorkingSetBytes, aProcess.PrivateBytes, aProcess.PrivateUsageBytes,
            aProcess.PrivateBytesAvailable);
      finally
        CloseHandle(lMemoryHandle);
      end;
    end;
    lHandleCount := 0;
    aProcess.HandleCountAvailable := GetProcessHandleCount(lHandle, lHandleCount);
    if aProcess.HandleCountAvailable then
      aProcess.HandleCount := lHandleCount;
    if ResolveProcessPath(lHandle, aProcess.Identity, aNowMonotonicMs,
      aProcess.Path, aProcess.PathStatus) then
      aProcess.DisplayName := ExtractFileName(aProcess.Path)
    else
      aProcess.DisplayName := 'PID ' + UIntToStr(aProcessId);
    Result := True;
  finally
    CloseHandle(lHandle);
  end;
end;

procedure TMachineOverviewProcessProvider.ExpireMissingProcesses(
  const aSeenIdentities: TDictionary<string, Boolean>);
var
  g: TGarbos;
  lKey: string;
  lRemoveKeys: TList<string>;
begin
  g := Default(TGarbos);
  GC(lRemoveKeys, TList<string>.Create, g);
  for lKey in fPreviousProcesses.Keys do
    if not aSeenIdentities.ContainsKey(lKey) then
      lRemoveKeys.Add(lKey);
  for lKey in lRemoveKeys do
    fPreviousProcesses.Remove(lKey);
  lRemoveKeys.Clear;
  for lKey in fPathCache.Keys do
    if not aSeenIdentities.ContainsKey(lKey) then
      lRemoveKeys.Add(lKey);
  for lKey in lRemoveKeys do
    fPathCache.Remove(lKey);
end;

procedure AddIndividualCpuMeasurements(const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aProcesses: TList<TMachineOverviewCollectedProcess>);
var
  lTop: TMachineOverviewTopProcesses;
  lProcess: TMachineOverviewCollectedProcess;
  lMeasurement: TMachineOverviewMeasurement;
  lTotal: Double;
  i, j, n: Integer;
begin
  lTop := Default(TMachineOverviewTopProcesses);
  n := 0;
  lTotal := 0;
  for lProcess in aProcesses do
  begin
    if not lProcess.Delta.CpuAvailable then
      Continue;
    lTotal := lTotal + lProcess.Delta.CpuPercent;
    if lProcess.Delta.CpuPercent <= 0 then
      Continue;
    i := 0;
    while (i < n) and ((lTop[i].Delta.CpuPercent > lProcess.Delta.CpuPercent) or
      ((lTop[i].Delta.CpuPercent = lProcess.Delta.CpuPercent) and
      (lTop[i].Identity.ProcessId < lProcess.Identity.ProcessId))) do
      Inc(i);
    if i = Length(lTop) then
      Continue;
    if n < Length(lTop) then
      Inc(n);
    for j := n - 1 downto i + 1 do
      lTop[j] := lTop[j - 1];
    lTop[i] := lProcess;
  end;
  for i := 0 to n - 1 do
  begin
    lMeasurement := Default(TMachineOverviewMeasurement);
    lMeasurement.Name := 'process_cpu_process:' + IntToStr(i + 1);
    lMeasurement.EntityId := MachineOverviewProcessIdentityKey(lTop[i].Identity);
    lMeasurement.DisplayText := lTop[i].DisplayName;
    lMeasurement.DetailText := lTop[i].Path;
    lMeasurement.StatusText := ProcessPathStatusText(lTop[i].PathStatus);
    lMeasurement.Available := True;
    lMeasurement.UnitText := 'percent';
    lMeasurement.Value := lTop[i].Delta.CpuPercent;
    aMeasurements.Add(lMeasurement);
  end;
  lMeasurement := Default(TMachineOverviewMeasurement);
  lMeasurement.Name := 'process_cpu_measured_total_percent';
  lMeasurement.UnitText := 'percent';
  lMeasurement.Available := True;
  // Our collection spans time; tiny scheduling skew must not claim over 100% machine capacity.
  if lTotal > 100 then
    lTotal := 100;
  lMeasurement.Value := lTotal;
  aMeasurements.Add(lMeasurement);
end;

function SelectMachineOverviewResourceProcesses(const aMetrics: TArray<TMachineOverviewProcessMetric>;
  const aIo: Boolean; out aMeasuredTotal: Double): TArray<TMachineOverviewProcessMetric>;
var
  lTop: array[0..9] of TMachineOverviewProcessMetric;
  lMetric: TMachineOverviewProcessMetric;
  i, j, n: Integer;
begin
  for i := Low(lTop) to High(lTop) do
    lTop[i] := Default(TMachineOverviewProcessMetric);
  n := 0;
  aMeasuredTotal := 0;
  for lMetric in aMetrics do
  begin
    if not lMetric.MetricAvailable or IsNan(lMetric.MetricValue) or IsInfinite(lMetric.MetricValue) or
      (lMetric.MetricValue < 0) then
      Continue;
    aMeasuredTotal := aMeasuredTotal + lMetric.MetricValue;
    if aIo and (lMetric.MetricValue = 0) then
      Continue;
    i := 0;
    while (i < n) and ((lTop[i].MetricValue > lMetric.MetricValue) or
      ((lTop[i].MetricValue = lMetric.MetricValue) and
      (lTop[i].Identity.ProcessId < lMetric.Identity.ProcessId))) do
      Inc(i);
    if i = Length(lTop) then
      Continue;
    if n < Length(lTop) then
      Inc(n);
    for j := n - 1 downto i + 1 do
      lTop[j] := lTop[j - 1];
    lTop[i] := lMetric;
  end;
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := lTop[i];
end;

procedure AddIndividualResourceMeasurements(const aMeasurements: TList<TMachineOverviewMeasurement>;
  const aMetrics: TArray<TMachineOverviewProcessMetric>;
  const aProcesses: TList<TMachineOverviewCollectedProcess>; const aIo: Boolean);
var
  lTop: TArray<TMachineOverviewProcessMetric>;
  lProcess: TMachineOverviewCollectedProcess;
  lMeasurement: TMachineOverviewMeasurement;
  lTotal: Double;
  i: Integer;
begin
  lTop := SelectMachineOverviewResourceProcesses(aMetrics, aIo, lTotal);
  for i := 0 to High(lTop) do
  begin
    if not FindCollectedProcess(aProcesses, lTop[i].Identity, lProcess) then
      raise EInvalidOpException.Create('Ranked process identity missing from our collected snapshot');
    lMeasurement := Default(TMachineOverviewMeasurement);
    if aIo then
      lMeasurement.Name := 'process_io_process:' + IntToStr(i + 1)
    else
      lMeasurement.Name := 'process_ram_process:' + IntToStr(i + 1);
    lMeasurement.EntityId := MachineOverviewProcessIdentityKey(lProcess.Identity);
    lMeasurement.DisplayText := lProcess.DisplayName;
    lMeasurement.DetailText := lProcess.Path;
    lMeasurement.StatusText := ProcessPathStatusText(lProcess.PathStatus);
    lMeasurement.Available := True;
    lMeasurement.UnitText := 'bytes';
    if aIo then
      lMeasurement.UnitText := 'bytes_per_second';
    lMeasurement.Value := lTop[i].MetricValue;
    aMeasurements.Add(lMeasurement);
  end;
  if aIo then
  begin
    lMeasurement := Default(TMachineOverviewMeasurement);
    lMeasurement.Name := 'process_io_measured_total_bytes_per_second';
    lMeasurement.UnitText := 'bytes_per_second';
    lMeasurement.Available := True;
    lMeasurement.Value := lTotal;
    aMeasurements.Add(lMeasurement);
  end;
end;

procedure TMachineOverviewProcessProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
var
  g: TGarbos;
  lAccessDenied: Boolean;
  lAccessDeniedCount: Integer;
  lCapturedAtFileTime: TFileTime;
  lCpuMetrics: TArray<TMachineOverviewProcessMetric>;
  lCpuRanked: TArray<TMachineOverviewRankedProcess>;
  lElapsedMs: UInt64;
  lErrorCode: Cardinal;
  lIoMetrics: TArray<TMachineOverviewProcessMetric>;
  lIoRanked: TArray<TMachineOverviewRankedProcess>;
  lLogicalProcessorCount: Cardinal;
  lMeasurementList: TList<TMachineOverviewMeasurement>;
  lNowMonotonicMs: UInt64;
  lProcess: TMachineOverviewCollectedProcess;
  lProcessIds: TArray<Cardinal>;
  lProcessList: TList<TMachineOverviewCollectedProcess>;
  lRamMetrics: TArray<TMachineOverviewProcessMetric>;
  lRamRanked: TArray<TMachineOverviewRankedProcess>;
  lSeenIdentities: TDictionary<string, Boolean>;
  i: Integer;
begin
  g := Default(TGarbos);
  aSample := Default(TMachineOverviewProviderSample);
  aSample.State.ProviderId := ProviderId;
  aSample.State.CapturedAtUtc := TTimeZone.Local.ToUniversalTime(Now);
  lNowMonotonicMs := GetTickCount64;
  aSample.State.CapturedAtMonotonicMs := lNowMonotonicMs;
  GetSystemTimeAsFileTime(lCapturedAtFileTime);
  if not TryEnumerateProcesses(lProcessIds, lErrorCode) then
  begin
    aSample.State.Status := TMachineOverviewProviderStatus.Unavailable;
    aSample.State.ErrorText := Format(
      'Process enumeration unavailable: Win32 error %d', [lErrorCode]);
    Exit;
  end;
  GC(lMeasurementList, TList<TMachineOverviewMeasurement>.Create, g);
  GC(lProcessList, TList<TMachineOverviewCollectedProcess>.Create, g);
  GC(lSeenIdentities, TDictionary<string, Boolean>.Create, g);
  if (fPreviousCapturedAtMonotonicMs > 0) and
    (lNowMonotonicMs >= fPreviousCapturedAtMonotonicMs) then
    lElapsedMs := lNowMonotonicMs - fPreviousCapturedAtMonotonicMs
  else
    lElapsedMs := 0;
  lLogicalProcessorCount := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  lAccessDeniedCount := 0;
  for i := 0 to High(lProcessIds) do
  begin
    lAccessDenied := False;
    if CollectProcess(lProcessIds[i], lNowMonotonicMs, lElapsedMs, FileTimeToUInt64(lCapturedAtFileTime),
      lLogicalProcessorCount, lSeenIdentities, lProcess, lAccessDenied) then
      lProcessList.Add(lProcess)
    else if lAccessDenied then
      Inc(lAccessDeniedCount);
  end;
  ExpireMissingProcesses(lSeenIdentities);
  fPreviousCapturedAtFileTime := FileTimeToUInt64(lCapturedAtFileTime);
  AddIndividualCpuMeasurements(lMeasurementList, lProcessList);
  AddDiagnostic(lMeasurementList, 'process_cpu_interval_ms', 'milliseconds', lElapsedMs);
  AddDiagnostic(lMeasurementList, 'logical_processor_count', 'count', lLogicalProcessorCount);
  fPreviousCapturedAtMonotonicMs := lNowMonotonicMs;

  SetLength(lCpuMetrics, lProcessList.Count);
  SetLength(lRamMetrics, lProcessList.Count);
  SetLength(lIoMetrics, lProcessList.Count);
  for i := 0 to lProcessList.Count - 1 do
  begin
    lProcess := lProcessList[i];
    lCpuMetrics[i].Identity := lProcess.Identity;
    lCpuMetrics[i].DisplayName := lProcess.DisplayName;
    lCpuMetrics[i].MetricAvailable := lProcess.Delta.CpuAvailable;
    lCpuMetrics[i].MetricValue := lProcess.Delta.CpuPercent;
    lRamMetrics[i].Identity := lProcess.Identity;
    lRamMetrics[i].DisplayName := lProcess.DisplayName;
    lRamMetrics[i].MetricAvailable := lProcess.PrivateBytesAvailable;
    lRamMetrics[i].MetricValue := lProcess.PrivateBytes;
    lIoMetrics[i].Identity := lProcess.Identity;
    lIoMetrics[i].DisplayName := lProcess.DisplayName;
    lIoMetrics[i].MetricAvailable := lProcess.Delta.IoAvailable;
    lIoMetrics[i].MetricValue := lProcess.Delta.IoBytesPerSecond;
  end;
  lCpuRanked := RankMachineOverviewProcesses(lCpuMetrics, lProcessList.Count);
  lRamRanked := RankMachineOverviewProcesses(lRamMetrics, lProcessList.Count);
  lIoRanked := RankMachineOverviewProcesses(lIoMetrics, lProcessList.Count);
  UpdateRollingMeasurements(lCpuRanked, lRamRanked, lIoRanked,
    lNowMonotonicMs);
  // Our live RAM ranking retains private working set; evidence ranks private usage.
  for i := 0 to lProcessList.Count - 1 do
  begin
    lRamMetrics[i].MetricAvailable := lProcessList[i].WorkingSetBytesAvailable;
    lRamMetrics[i].MetricValue := lProcessList[i].PrivateUsageBytes;
  end;
  AddIndividualResourceMeasurements(lMeasurementList, lRamMetrics, lProcessList, False);
  AddIndividualResourceMeasurements(lMeasurementList, lIoMetrics, lProcessList, True);
  LimitRankedProcesses(lCpuRanked, 5);
  LimitRankedProcesses(lRamRanked, 5);
  LimitRankedProcesses(lIoRanked, 5);
  AddRankedMeasurements(lMeasurementList, 'process_cpu_rank', 'percent',
    lCpuRanked, lProcessList, lNowMonotonicMs);
  AddRankedMeasurements(lMeasurementList, 'process_ram_rank',
    'private_working_set_bytes', lRamRanked, lProcessList,
    lNowMonotonicMs);
  AddRankedMeasurements(lMeasurementList, 'process_io_rank',
    'bytes_per_second', lIoRanked, lProcessList, lNowMonotonicMs);
  for lProcess in lProcessList do
    if lProcess.Identity.ProcessId = GetCurrentProcessId then
    begin
      if lProcess.Delta.CpuAvailable and lProcess.PrivateBytesAvailable and
        lProcess.WriteBytesPerSecondAvailable then
      begin
        AddDiagnostic(lMeasurementList, 'monitor_cpu_percent', 'percent',
          lProcess.Delta.CpuPercent);
        AddDiagnostic(lMeasurementList, 'monitor_private_bytes', 'bytes',
          lProcess.PrivateBytes);
        AddDiagnostic(lMeasurementList, 'monitor_write_bytes_per_second',
          'bytes_per_second', lProcess.WriteBytesPerSecond);
      end;
      Break;
    end;
  AddDiagnostic(lMeasurementList, 'process_enumerated_count', 'count',
    lProcessList.Count);
  AddDiagnostic(lMeasurementList, 'process_access_denied_count', 'count',
    lAccessDeniedCount);
  AddDiagnostic(lMeasurementList, 'process_path_cache_count', 'count',
    fPathCache.Count);
  aSample.Measurements := lMeasurementList.ToArray;
  aSample.State.Status := TMachineOverviewProviderStatus.Available;
end;

function TMachineOverviewProcessProvider.ProviderId: string;
begin
  Result := 'processes';
end;

function ShouldReuseMachineOverviewProcessPath(
  const aCachedIdentity, aCurrentIdentity: TMachineOverviewProcessIdentity;
  const aLastSeenMonotonicMs, aNowMonotonicMs,
  aInactivityTimeoutMs: UInt64): Boolean;
begin
  Result := (aCachedIdentity.ProcessId = aCurrentIdentity.ProcessId) and
    (aCachedIdentity.CreationTime100ns = aCurrentIdentity.CreationTime100ns) and
    (aInactivityTimeoutMs > 0) and
    (aNowMonotonicMs >= aLastSeenMonotonicMs) and
    ((aNowMonotonicMs - aLastSeenMonotonicMs) <= aInactivityTimeoutMs);
end;

function ClassifyMachineOverviewProcessPathFailure(const aErrorCode: Cardinal;
  const aProcessStillExists: Boolean): TMachineOverviewProcessPathStatus;
begin
  if not aProcessStillExists then
    Result := TMachineOverviewProcessPathStatus.Exited
  else if aErrorCode = ERROR_ACCESS_DENIED then
    Result := TMachineOverviewProcessPathStatus.PermissionDenied
  else
    Result := TMachineOverviewProcessPathStatus.Unavailable;
end;

function TryCalculateMachineOverviewPrivateWorkingSet(
  const aWorkingSetFlags: TArray<NativeUInt>; const aPageSize: Cardinal;
  out aPrivateBytes: UInt64): Boolean;
var
  lFlag: NativeUInt;
  lPrivatePageCount: UInt64;
begin
  aPrivateBytes := 0;
  if aPageSize = 0 then
    Exit(False);
  lPrivatePageCount := 0;
  for lFlag in aWorkingSetFlags do
    if (lFlag and $100) = 0 then
      Inc(lPrivatePageCount);
  Result := (lPrivatePageCount = 0) or
    (lPrivatePageCount <= High(UInt64) div aPageSize);
  if Result then
    aPrivateBytes := lPrivatePageCount * aPageSize;
end;

function CreateMachineOverviewProcessProvider: IMachineOverviewProvider;
begin
  Result := TMachineOverviewProcessProvider.Create;
end;

end.

unit ActiveAppView.MachineOverview.Recording;

interface

uses
  System.SysUtils,
  ActiveAppView.MachineOverview.Evidence, ActiveAppView.MachineOverview.Incidents;

type
  TMachineOverviewRecordedProcess = record
    ProcessId: Cardinal;
    CreatedUtc: TDateTime;
    DisplayName, InstanceName: string;
    AverageCpuPercent, PeakCpuPercent: Double;
    PeakAtUtc, LastSeenUtc: TDateTime;
    SampleCount: Integer;
  end;
  TMachineOverviewRecordingPhase = record
    Kind: TMachineOverviewEvidencePhaseKind;
    StartUtc, EndUtc: TDateTime;
    SampleCount, ExpectedSampleCount, InvalidValueCount: Integer;
    SystemCpu: TMachineOverviewEvidenceStatistic;
    Processes: TArray<TMachineOverviewRecordedProcess>;
  end;
  TMachineOverviewRecordingCoverage = (Full, Partial, None);
  TMachineOverviewRecording = record
    FileNames: TArray<string>;
    MachineName: string;
    LogStartUtc, LogEndUtc: TDateTime;
    IntervalMs: Cardinal;
    LogicalProcessorCount: Integer;
    Coverage: TMachineOverviewRecordingCoverage;
    Phases: array[TMachineOverviewEvidencePhaseKind] of TMachineOverviewRecordingPhase;
    Truncated: Boolean;
    Notes: TArray<string>;
  end;

type
  // Completion publishes immutable result fields with an interlocked barrier.
  // The UI and detached reader each retain a reference; neither owns the other.
  IMachineOverviewRecordingRequest = interface
    ['{E484F6AA-A5BE-45E7-BE79-8232F02FF966}']
    procedure Cancel;
    procedure Execute;
    function TryResult(out aRecording: TMachineOverviewRecording; out aError: string;
      out aSucceeded: Boolean; out aThreadId: Cardinal): Boolean;
  end;

function TryStartMachineOverviewRecordingRead(const aFiles: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aCollect: TFunc<NativeUInt, Cardinal>;
  out aRequest: IMachineOverviewRecordingRequest; out aError: string): Boolean;
// Main-thread lifecycle boundary. A zero timeout only reaps finished native threads.
function WaitForMachineOverviewRecordingReaders(const aTimeoutMs: Cardinal): Boolean; //PALOFF Fixture teardown and process exit use this boundary.
function MachineOverviewRecordingOutstandingRequests: Integer; //PALOFF Fixture ownership assertion.

function TryReadMachineOverviewRecording(const aFileNames: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aLogicalProcessorCount: Integer;
  const aCancelled: TFunc<Boolean>; out aRecording: TMachineOverviewRecording; out aError: string): Boolean;
function MachineOverviewRecordingRows(const aRecording: TMachineOverviewRecording):
  TArray<TMachineOverviewEvidenceRow>;
function MachineOverviewRecordingText(const aRecording: TMachineOverviewRecording): string;

implementation

uses
  System.Classes, System.DateUtils, System.Diagnostics, System.Generics.Collections,
  System.Generics.Defaults, System.Math, System.StrUtils, System.SyncObjs,
  Winapi.Windows,
  AutoFree;

const
  cMoreData = Cardinal($800007D2);
  cNoMoreData = Cardinal($C0000BCC);
  cMaxBufferChars = 8 * 1024 * 1024;
  cMaxInstances = 8192;
  cMaxIdentities = 65536;
  cMaxSelectedBytes = Int64(2) * 1024 * 1024 * 1024;
  cMaxReadMs = 120000;
  cPhaseOrder: array[0..2] of TMachineOverviewEvidencePhaseKind =
    (TMachineOverviewEvidencePhaseKind.During, TMachineOverviewEvidencePhaseKind.Before,
     TMachineOverviewEvidencePhaseKind.After);

resourcestring
  rsRecordingBusy = 'Previous recording reads are still finishing. Try again after storage responds.';
  rsActiveRecording = 'This is the collector''s active circular log. Windows cannot read it while recording. ' +
    'Preserve it with the elevated stop/copy/restart in PC-Maintenance docs\performance-recording.md, ' +
    'then open the preserved copy.';
  rsClosedRecording = 'Select a closed BLG recording. The file is open for writing or unavailable: %s (%s).';
  rsRecordingError = '%s: PDH error 0x%s.';
  rsRecordingCancelled = 'Reading recording cancelled.';
  rsRecordingTimeout = 'Reading stopped after 120 s; results are truncated.';
  rsRecordingSize = 'Select at most 32 closed BLG files with a combined size of at most 2 GB.';
  rsRecordingMachine = 'The selected recording must contain exactly one machine.';
  rsRecordingInstanceLimit = 'Only the first 8,192 process instances were read.';
  rsRecordingIdentityLimit = 'Reading stopped at 65,536 process identities; results are truncated.';
  rsRecordingNames = 'Counters resolved by index: %s; %s; %s; %s; %s.';
  rsRecordingRemote = 'The log machine differs from this computer. Normalization uses the incident/local LP count; verify it for the recorded machine.';
  rsRecordingTimeNote = 'Log timestamps are local Windows FILETIMEs, converted to UTC with local time-zone rules. The repeated hour at the DST fall-back is ambiguous.';
  rsRecordingCoverage = 'Coverage: %s. This recording covers %s - %s; the incident window is %s - %s.';
  rsRecordingUncovered = 'Uncovered range: %s - %s.';
  rsRecordingHeader = 'Windows performance recording';
  rsRecordingMeta = 'Files: %s'#13#10'Machine: %s'#13#10'Log range: %s - %s'#13#10'Interval: %d ms; normalization: %d logical processors; one fully busy LP = %s%% of machine.';
  rsRecordingPrecision = 'CPU is %% of machine. Identity is PID + elapsed time; creation time precision +/- %s s. Idle and _Total are excluded. First/invalid samples are excluded; absent processes contribute zero during valid sample time. Lists are measurements, not proof of cause.';
  rsRecordingPhase = 'Recording %s';
  rsRecordedSystem = 'Recorded system';
  rsRecordedProcess = 'Recorded process';
  rsRecordingStatus = 'Recording status';
  rsRecordingSamples = '%d of %d samples; %d invalid values';
  rsRecordingProcessSamples = '%d samples; last seen %s';
  rsRecordingIdentity = 'PID %d, started %s (+/- %s s)';
  rsRecordingPhaseRange = '%s - %s';
  rsRecordingFull = 'Full';
  rsRecordingPartial = 'Partial';
  rsRecordingNone = 'None';
  rsRecordingNoData = 'No valid samples';

type
  // Windows SDK Pdh.h: FILETIME starts at byte 4, Int64 members at byte 16.
  TPdhRaw = packed record
    Status: Cardinal;
    Stamp: TFileTime;
    Padding: Cardinal;
    FirstValue, SecondValue: Int64;
    MultiCount, TailPadding: Cardinal;
  end;
  TPdhValue = record
    Status: Cardinal;
    Value: Double;
  end;
  TPdhTimeInfo = record
    StartTime, EndTime: Int64;
    SampleCount: Cardinal;
  end;
  TRecordingCounters = record
    Instance: string;
    Cpu, Pid, Elapsed: NativeUInt;
  end;
  TRecordingProcessAccumulator = record
    Value: TMachineOverviewRecordedProcess;
    CpuTime: Double;
  end;
  TRecordingIdentity = record
    CreatedUtc: TDateTime;
    Phases: array[TMachineOverviewEvidencePhaseKind] of TRecordingProcessAccumulator;
  end;
  TRecordingReader = class
  private
    fFiles: TArray<string>;
    fLocks: TArray<THandle>;
    fIncident: TMachineOverviewIncident;
    fCancelled: TFunc<Boolean>;
    fClock: TStopwatch;
    fLog, fQuery, fSystem: NativeUInt;
    fCounters: TArray<TRecordingCounters>;
    fIdentities: TList<TRecordingIdentity>;
    fPids: TDictionary<Cardinal, NativeInt>;
    fWeights: array[TMachineOverviewEvidencePhaseKind] of Double;
    fWindowStart, fWindowEnd, fIncidentEnd: TDateTime;
    fValue: TMachineOverviewRecording;
    fError: string;
    fCollect: TFunc<NativeUInt, Cardinal>;
    function Check(const aStatus: Cardinal; const aOperation: string): Boolean;
    function ClosePdh: Boolean;
    function ContinueReading: Boolean;
    procedure Note(const aText: string);
    function LockFiles: Boolean;
    function Prepare: Boolean;
    function AddCounters: Boolean;
    function ReadSamples: Boolean;
    procedure ObserveProcess(const aCounters: TRecordingCounters; const aPhase: TMachineOverviewEvidencePhaseKind;
      const aAtUtc: TDateTime; const aWeight: Double);
    procedure Finish;
    function CoverageText: string;
  public
    constructor Create(const aFiles: TArray<string>; const aIncident: TMachineOverviewIncident;
      const aLp: Integer; const aCancelled: TFunc<Boolean>);
    destructor Destroy; override;
    function Read(out aValue: TMachineOverviewRecording; out aError: string): Boolean;
  end;

function TryReadMachineOverviewRecordingWithCollector(const aFileNames: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aLogicalProcessorCount: Integer;
  const aCancelled: TFunc<Boolean>; const aCollect: TFunc<NativeUInt, Cardinal>;
  out aRecording: TMachineOverviewRecording; out aError: string): Boolean;
forward;

type
  TRecordingRequest = class(TInterfacedObject, IMachineOverviewRecordingRequest)
  private
    fCancelled, fCompleted: Integer;
    fFiles: TArray<string>;
    fIncident: TMachineOverviewIncident;
    fCollect: TFunc<NativeUInt, Cardinal>;
    fValue: TMachineOverviewRecording;
    fError: string;
    fSucceeded: Boolean;
    fThreadId: Cardinal;
  public
    constructor Create(const aFiles: TArray<string>; const aIncident: TMachineOverviewIncident;
      const aCollect: TFunc<NativeUInt, Cardinal>);
    destructor Destroy; override;
    procedure Cancel;
    procedure Execute;
    function TryResult(out aRecording: TMachineOverviewRecording; out aError: string;
      out aSucceeded: Boolean; out aThreadId: Cardinal): Boolean;
  end;

  TRecordingWorker = class(TThread)
  private
    fRequest: IMachineOverviewRecordingRequest;
  protected
    procedure Execute; override;
  public
    constructor Create(const aRequest: IMachineOverviewRecordingRequest);
  end;

var
  // Main-thread-only registry holds duplicate native handles, never TThread objects.
  // A signaled handle proves Execute, FreeOnTerminate and RTL thread teardown ended.
  RecordingThreadHandles: TList<THandle>;
  RecordingOutstandingRequests: Integer;

constructor TRecordingRequest.Create(const aFiles: TArray<string>; const aIncident: TMachineOverviewIncident;
  const aCollect: TFunc<NativeUInt, Cardinal>);
begin
  inherited Create;
  fFiles := Copy(aFiles);
  fIncident := aIncident;
  fCollect := aCollect;
  TInterlocked.Increment(RecordingOutstandingRequests);
end;

destructor TRecordingRequest.Destroy;
begin
  TInterlocked.Decrement(RecordingOutstandingRequests);
  inherited;
end;

function MachineOverviewRecordingOutstandingRequests: Integer;
begin
  Result := TInterlocked.CompareExchange(RecordingOutstandingRequests, 0, 0);
end;

procedure TRecordingRequest.Cancel;
begin
  TInterlocked.Exchange(fCancelled, 1);
end;

procedure TRecordingRequest.Execute;
begin
  fThreadId := GetCurrentThreadId;
  try
    fSucceeded := TryReadMachineOverviewRecordingWithCollector(fFiles, fIncident,
      fIncident.Evidence.LogicalProcessorCount,
      function: Boolean
      begin
        Result := TInterlocked.CompareExchange(fCancelled, 0, 0) <> 0;
      end, fCollect, fValue, fError);
  except
    on lException: Exception do
    begin
      fSucceeded := False;
      fError := lException.Message;
    end;
  end;
  TInterlocked.Exchange(fCompleted, 1);
end;

function TRecordingRequest.TryResult(out aRecording: TMachineOverviewRecording; out aError: string;
  out aSucceeded: Boolean; out aThreadId: Cardinal): Boolean;
begin
  aRecording := Default(TMachineOverviewRecording);
  aError := '';
  aSucceeded := False;
  aThreadId := 0;
  Result := TInterlocked.CompareExchange(fCompleted, 0, 0) <> 0;
  if not Result then
    Exit;
  aRecording := fValue;
  aError := fError;
  aSucceeded := fSucceeded;
  aThreadId := fThreadId;
end;

constructor TRecordingWorker.Create(const aRequest: IMachineOverviewRecordingRequest);
begin
  inherited Create(True);
  fRequest := aRequest;
  FreeOnTerminate := True;
end;

procedure TRecordingWorker.Execute;
begin
  fRequest.Execute;
end;

function WaitForMachineOverviewRecordingReaders(const aTimeoutMs: Cardinal): Boolean;
var
  lClock: TStopwatch;
  i: NativeInt;
begin
  Result := False;
  lClock := TStopwatch.StartNew;
  repeat
    for i := RecordingThreadHandles.Count - 1 downto 0 do
      if WaitForSingleObject(RecordingThreadHandles[i], 0) = WAIT_OBJECT_0 then
      begin
        CloseHandle(RecordingThreadHandles[i]);
        RecordingThreadHandles.Delete(i);
      end;
    if RecordingThreadHandles.Count = 0 then
      Exit(True);
    if lClock.ElapsedMilliseconds >= aTimeoutMs then
      Exit(False);
    Sleep(1);
  until False;
end;

function TryStartMachineOverviewRecordingRead(const aFiles: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aCollect: TFunc<NativeUInt, Cardinal>;
  out aRequest: IMachineOverviewRecordingRequest; out aError: string): Boolean;
var
  lWorker: TRecordingWorker;
  lHandle: THandle;
begin
  aRequest := nil;
  aError := '';
  // Reopening forms cannot accumulate unbounded threads on stalled storage.
  if not WaitForMachineOverviewRecordingReaders(0) and (RecordingThreadHandles.Count >= 4) then
  begin
    aError := rsRecordingBusy;
    Exit(False);
  end;
  aRequest := TRecordingRequest.Create(aFiles, aIncident, aCollect);
  lWorker := TRecordingWorker.Create(aRequest);
  try
    if not DuplicateHandle(GetCurrentProcess, lWorker.Handle, GetCurrentProcess, @lHandle,
      SYNCHRONIZE, False, 0) then
      RaiseLastOSError;
    try
      RecordingThreadHandles.Add(lHandle);
    except
      CloseHandle(lHandle);
      raise;
    end;
  except
    lWorker.FreeOnTerminate := False;
    lWorker.Free;
    aRequest := nil;
    raise;
  end;
  lWorker.Start;
  Result := True;
end;

function PdhBindInputDataSourceW(aLog: PNativeUInt; aFiles: PWideChar): Cardinal; stdcall; external 'pdh.dll';
function PdhEnumMachinesHW(aLog: NativeUInt; aBuffer: PWideChar; var aLength: Cardinal): Cardinal; stdcall; external 'pdh.dll';
function PdhLookupPerfNameByIndexW(aMachine: PWideChar; aIndex: Cardinal;
  aBuffer: PWideChar; var aLength: Cardinal): Cardinal; stdcall; external 'pdh.dll';
function PdhGetDataSourceTimeRangeH(aLog: NativeUInt; aEntries: PCardinal;
  aInfo: Pointer; aSize: PCardinal): Cardinal; stdcall; external 'pdh.dll';
function PdhExpandWildCardPathHW(aLog: NativeUInt; aPath, aBuffer: PWideChar;
  var aLength: Cardinal; aFlags: Cardinal): Cardinal; stdcall; external 'pdh.dll';
function PdhOpenQueryH(aLog, aUserData: NativeUInt; aQuery: PNativeUInt): Cardinal; stdcall; external 'pdh.dll';
function PdhAddCounterW(aQuery: NativeUInt; aPath: PWideChar; aData: NativeUInt;
  aCounter: PNativeUInt): Cardinal; stdcall; external 'pdh.dll';
function PdhSetQueryTimeRange(aQuery: NativeUInt; var aInfo: TPdhTimeInfo): Cardinal; stdcall; external 'pdh.dll';
function PdhCollectQueryData(aQuery: NativeUInt): Cardinal; stdcall; external 'pdh.dll';
function PdhGetRawCounterValue(aCounter: NativeUInt; aType: Pointer;
  out aValue: TPdhRaw): Cardinal; stdcall; external 'pdh.dll';
function PdhGetFormattedCounterValue(aCounter: NativeUInt; aFormat: Cardinal; aType: Pointer;
  out aValue: TPdhValue): Cardinal; stdcall; external 'pdh.dll';
function PdhCloseQuery(aQuery: NativeUInt): Cardinal; stdcall; external 'pdh.dll';
function PdhCloseLog(aLog: NativeUInt; aFlags: Cardinal): Cardinal; stdcall; external 'pdh.dll';

function RecordingCounterName(const aIndex: Cardinal): string;
var
  lLength: Cardinal;
begin
  lLength := 0;
  if PdhLookupPerfNameByIndexW(nil, aIndex, nil, lLength) <> cMoreData then
    Exit('');
  if (lLength = 0) or (lLength > 65536) then
    Exit('');
  SetLength(Result, lLength);
  if PdhLookupPerfNameByIndexW(nil, aIndex, PWideChar(Result), lLength) <> 0 then
    Exit('');
  Result := PWideChar(Result);
end;

function RecordingMultiStrings(const aBuffer: string): TArray<string>;
var
  g: TGarbos;
  lValues: TList<string>;
  i, j: Integer;
begin
  g := Default(TGarbos);
  GC(lValues, TList<string>.Create, g);
  i := 1;
  while (i <= Length(aBuffer)) and (aBuffer[i] <> #0) do
  begin
    j := i;
    while (j <= Length(aBuffer)) and (aBuffer[j] <> #0) do
      Inc(j);
    lValues.Add(Copy(aBuffer, i, j - i));
    i := j + 1;
  end;
  Result := lValues.ToArray;
end;

function RecordingUtc(const aStamp: Int64): TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(EncodeDate(1601, 1, 1) + aStamp / 864000000000.0);
end;

function RecordingStamp(const aUtc: TDateTime): Int64;
begin
  Result := Round((TTimeZone.Local.ToLocalTime(aUtc) - EncodeDate(1601, 1, 1)) * 864000000000.0);
end;

function RecordingValue(const aCounter: NativeUInt; out aValue: Double): Boolean;
var
  lValue: TPdhValue;
begin
  aValue := 0;
  Result := (aCounter <> 0) and
    (PdhGetFormattedCounterValue(aCounter, $200 or $8000, nil, lValue) = 0);
  if Result then
  begin
    Result := (lValue.Status <= 1) and not IsNan(lValue.Value) and not IsInfinite(lValue.Value) and
      (lValue.Value >= 0);
    if Result then
      aValue := lValue.Value;
  end;
end;

constructor TRecordingReader.Create(const aFiles: TArray<string>; const aIncident: TMachineOverviewIncident;
  const aLp: Integer; const aCancelled: TFunc<Boolean>);
var
  lPhase: TMachineOverviewEvidencePhaseKind;
begin
  inherited Create;
  fFiles := Copy(aFiles);
  fIncident := aIncident;
  fCancelled := aCancelled;
  fClock := TStopwatch.StartNew;
  fValue := Default(TMachineOverviewRecording);
  fValue.FileNames := Copy(aFiles);
  fValue.LogicalProcessorCount := aLp;
  if aLp <= 0 then
    fValue.LogicalProcessorCount := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  fValue.LogicalProcessorCount := Max(1, fValue.LogicalProcessorCount);
  fValue.IntervalMs := 1000;
  fIdentities := TList<TRecordingIdentity>.Create;
  fPids := TDictionary<Cardinal, NativeInt>.Create;
  fIncidentEnd := aIncident.EndedAtUtc;
  if fIncidentEnd <= 0 then
    fIncidentEnd := Max(aIncident.StartedAtUtc, aIncident.PeakAtUtc);
  fWindowStart := IncMinute(aIncident.StartedAtUtc, -5);
  fWindowEnd := IncMinute(fIncidentEnd, 10);
  for lPhase := Low(lPhase) to High(lPhase) do
  begin
    fValue.Phases[lPhase].Kind := lPhase;
    case lPhase of
      TMachineOverviewEvidencePhaseKind.Before:
        begin
          fValue.Phases[lPhase].StartUtc := fWindowStart;
          fValue.Phases[lPhase].EndUtc := aIncident.StartedAtUtc;
        end;
      TMachineOverviewEvidencePhaseKind.During:
        begin
          fValue.Phases[lPhase].StartUtc := aIncident.StartedAtUtc;
          fValue.Phases[lPhase].EndUtc := fIncidentEnd;
        end;
      TMachineOverviewEvidencePhaseKind.After:
        begin
          fValue.Phases[lPhase].StartUtc := fIncidentEnd;
          fValue.Phases[lPhase].EndUtc := fWindowEnd;
        end;
    end;
  end;
end;

destructor TRecordingReader.Destroy;
var
  lHandle: THandle;
begin
  if not ClosePdh then
    OutputDebugString(PChar(fError));
  for lHandle in fLocks do
    if lHandle <> INVALID_HANDLE_VALUE then
      CloseHandle(lHandle);
  fPids.Free;
  fIdentities.Free;
  inherited;
end;

function TRecordingReader.ClosePdh: Boolean;
begin
  Result := True;
  if fQuery <> 0 then
  begin
    Result := Check(PdhCloseQuery(fQuery), 'Close recording query');
    fQuery := 0;
  end;
  if fLog <> 0 then
  begin
    if not Check(PdhCloseLog(fLog, 0), 'Close recording source') then
      Result := False;
    fLog := 0;
  end;
end;

procedure TRecordingReader.Note(const aText: string);
begin
  fValue.Notes := fValue.Notes + [aText];
end;

function TRecordingReader.Check(const aStatus: Cardinal; const aOperation: string): Boolean;
begin
  Result := aStatus = 0;
  if not Result then
    fError := Format(rsRecordingError, [aOperation, IntToHex(aStatus, 8)]);
end;

function TRecordingReader.ContinueReading: Boolean;
begin
  Result := False;
  if Assigned(fCancelled) and fCancelled() then
  begin
    fError := rsRecordingCancelled;
    Exit;
  end;
  if fClock.ElapsedMilliseconds >= cMaxReadMs then
  begin
    fValue.Truncated := True;
    Note(rsRecordingTimeout);
    Exit;
  end;
  Result := True;
end;

function TRecordingReader.LockFiles: Boolean;
var
  fn: string;
  lHandle: THandle;
  lSize, lTotal: Int64;
begin
  Result := False;
  // Check every name before opening any file, including later MULTI_SZ entries.
  for fn in fFiles do
    if SameText(ExtractFileName(fn), 'current.blg') then
    begin
      fError := rsActiveRecording;
      Exit;
    end;
  if (Length(fFiles) = 0) or (Length(fFiles) > 32) then
  begin
    fError := rsRecordingSize;
    Exit;
  end;
  lTotal := 0;
  for fn in fFiles do
  begin
    if not ContinueReading then
      Exit;
    // Deny existing and future writers/deleters while PDH reads this closed input.
    lHandle := CreateFile(PChar(fn), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0);
    if lHandle = INVALID_HANDLE_VALUE then
    begin
      fError := Format(rsClosedRecording, [fn, SysErrorMessage(GetLastError)]);
      Exit;
    end;
    fLocks := fLocks + [lHandle];
    if not GetFileSizeEx(lHandle, lSize) then
    begin
      fError := Format(rsClosedRecording, [fn, SysErrorMessage(GetLastError)]);
      Exit;
    end;
    if (lSize < 1) or (lSize > cMaxSelectedBytes - lTotal) then
    begin
      fError := rsRecordingSize;
      Exit;
    end;
    lTotal := lTotal + lSize;
  end;
  Result := True;
end;

function TRecordingReader.Prepare: Boolean;
var
  lMulti, lBuffer: string;
  lMachines: TArray<string>;
  fn: string;
  lLength, lEntries, lSize: Cardinal;
  lRange: TPdhTimeInfo;
  lComputer: array[0..MAX_COMPUTERNAME_LENGTH] of Char;
begin
  Result := False;
  if not LockFiles then
    Exit;
  lMulti := '';
  for fn in fFiles do
    lMulti := lMulti + fn + #0;
  lMulti := lMulti + #0;
  if not Check(PdhBindInputDataSourceW(@fLog, PWideChar(lMulti)), 'Open closed recording') then
    Exit;
  if not ContinueReading then
    Exit;
  lLength := 0;
  if PdhEnumMachinesHW(fLog, nil, lLength) <> cMoreData then
    lLength := 0;
  if (lLength < 2) or (lLength > cMaxBufferChars) then
  begin
    fError := rsRecordingMachine;
    Exit;
  end;
  SetLength(lBuffer, lLength);
  if not Check(PdhEnumMachinesHW(fLog, PWideChar(lBuffer), lLength), 'Read log machine') then
    Exit;
  lMachines := RecordingMultiStrings(lBuffer);
  if Length(lMachines) <> 1 then
  begin
    fError := rsRecordingMachine;
    Exit;
  end;
  fValue.MachineName := lMachines[0];
  lLength := Length(lComputer);
  if GetComputerName(lComputer, lLength) and
    not SameText(fValue.MachineName.TrimLeft(['\']), string(lComputer)) then
    Note(rsRecordingRemote);
  lSize := SizeOf(lRange);
  if not Check(PdhGetDataSourceTimeRangeH(fLog, @lEntries, @lRange, @lSize), 'Read log range') then
    Exit;
  if (lEntries <> 1) or (lRange.EndTime < lRange.StartTime) then
  begin
    fError := 'The log time range is invalid.';
    Exit;
  end;
  fValue.LogStartUtc := RecordingUtc(lRange.StartTime);
  fValue.LogEndUtc := RecordingUtc(lRange.EndTime);
  if (lRange.SampleCount > 1) and (lRange.EndTime > lRange.StartTime) then
    fValue.IntervalMs := Max(1, Round((lRange.EndTime - lRange.StartTime) / 10000 / (lRange.SampleCount - 1)));
  Note(rsRecordingTimeNote);
  if (fValue.LogEndUtc < fWindowStart) or (fValue.LogStartUtc > fWindowEnd) then
    fValue.Coverage := TMachineOverviewRecordingCoverage.None
  else if (fValue.LogStartUtc <= fWindowStart) and (fValue.LogEndUtc >= fWindowEnd) then
    fValue.Coverage := TMachineOverviewRecordingCoverage.Full
  else
    fValue.Coverage := TMachineOverviewRecordingCoverage.Partial;
  Note(CoverageText);
  if fValue.Coverage = TMachineOverviewRecordingCoverage.Partial then
  begin
    if fValue.LogStartUtc > fWindowStart then
      Note(Format(rsRecordingUncovered, [MachineOverviewEvidenceTimeText(fWindowStart),
        MachineOverviewEvidenceTimeText(Min(fWindowEnd, fValue.LogStartUtc))]));
    if fValue.LogEndUtc < fWindowEnd then
      Note(Format(rsRecordingUncovered, [MachineOverviewEvidenceTimeText(Max(fWindowStart, fValue.LogEndUtc)),
        MachineOverviewEvidenceTimeText(fWindowEnd)]));
  end;
  Result := True;
end;

function TRecordingReader.CoverageText: string;
var
  lName: string;
begin
  case fValue.Coverage of
    TMachineOverviewRecordingCoverage.Full: lName := rsRecordingFull;
    TMachineOverviewRecordingCoverage.Partial: lName := rsRecordingPartial;
  else
    lName := rsRecordingNone;
  end;
  Result := Format(rsRecordingCoverage, [lName, MachineOverviewEvidenceTimeText(fValue.LogStartUtc),
    MachineOverviewEvidenceTimeText(fValue.LogEndUtc), MachineOverviewEvidenceTimeText(fWindowStart),
    MachineOverviewEvidenceTimeText(fWindowEnd)]);
end;

function TRecordingReader.AddCounters: Boolean;
var
  lProcess, lCpu, lPid, lElapsed, lProcessor, lPath, lBuffer, lPrefix, lInstance: string;
  lPaths: TArray<string>;
  lLength: Cardinal;
  lRange: TPdhTimeInfo;
  lCounter: TRecordingCounters;
  i, j: Integer;
begin
  Result := False;
  lProcess := RecordingCounterName(230); lCpu := RecordingCounterName(6);
  lPid := RecordingCounterName(784); lElapsed := RecordingCounterName(684);
  lProcessor := RecordingCounterName(238);
  if lProcess.IsEmpty or lCpu.IsEmpty or lPid.IsEmpty or lElapsed.IsEmpty or lProcessor.IsEmpty then
  begin
    fError := 'Windows could not resolve the required counter names by index.';
    Exit;
  end;
  Note(Format(rsRecordingNames, [lProcess, lCpu, lPid, lElapsed, lProcessor]));
  if not Check(PdhOpenQueryH(fLog, 0, @fQuery), 'Open recording query') then
    Exit;
  lPath := fValue.MachineName + '\' + lProcessor + '(_Total)\' + lCpu;
  if not Check(PdhAddCounterW(fQuery, PWideChar(lPath), 0, @fSystem), 'Add recorded system CPU') then
    Exit;
  lPath := fValue.MachineName + '\' + lProcess + '(*)\' + lCpu;
  lLength := 0;
  if PdhExpandWildCardPathHW(fLog, PWideChar(lPath), nil, lLength, 0) <> cMoreData then
    lLength := 0;
  if (lLength < 2) or (lLength > cMaxBufferChars) then
  begin
    fError := 'No readable process CPU counters in the recording (or counter catalogue exceeds 8 MB).';
    Exit;
  end;
  SetLength(lBuffer, lLength);
  if not Check(PdhExpandWildCardPathHW(fLog, PWideChar(lPath), PWideChar(lBuffer), lLength, 0),
    'Expand recorded process instances') then
    Exit;
  lPaths := RecordingMultiStrings(lBuffer);
  for lPath in lPaths do
  begin
    if not ContinueReading then
      Exit;
    lPrefix := Copy(lPath, 1, LastDelimiter('\', lPath));
    i := Pos('(', lPrefix); j := LastDelimiter(')', lPrefix);
    if (i < 1) or (j <= i) then
      Continue;
    lInstance := Copy(lPath, i + 1, j - i - 1);
    if SameText(lInstance, 'Idle') or SameText(lInstance, '_Total') then
      Continue;
    if Length(fCounters) = cMaxInstances then
    begin
      fValue.Truncated := True;
      Note(rsRecordingInstanceLimit);
      Break;
    end;
    lCounter := Default(TRecordingCounters);
    lCounter.Instance := lInstance;
    if not Check(PdhAddCounterW(fQuery, PWideChar(lPath), 0, @lCounter.Cpu), 'Add process CPU') or
      not Check(PdhAddCounterW(fQuery, PWideChar(lPrefix + lPid), 0, @lCounter.Pid), 'Add process PID') or
      not Check(PdhAddCounterW(fQuery, PWideChar(lPrefix + lElapsed), 0, @lCounter.Elapsed), 'Add process elapsed time') then
      Exit;
    fCounters := fCounters + [lCounter];
  end;
  lRange := Default(TPdhTimeInfo);
  // Include one priming sample for rate counters, but never accumulate it outside the window.
  lRange.StartTime := RecordingStamp(fWindowStart - fValue.IntervalMs / MSecsPerDay);
  lRange.EndTime := RecordingStamp(fWindowEnd);
  Result := Check(PdhSetQueryTimeRange(fQuery, lRange), 'Set incident window');
end;

procedure TRecordingReader.ObserveProcess(const aCounters: TRecordingCounters;
  const aPhase: TMachineOverviewEvidencePhaseKind; const aAtUtc: TDateTime; const aWeight: Double);
var
  lCpu, lPid, lElapsed: Double;
  lCreated: TDateTime;
  lIdentity: TRecordingIdentity;
  lProcess: TRecordingProcessAccumulator;
  lIndex: NativeInt;
  i: Integer;
  id: Cardinal;
begin
  if not RecordingValue(aCounters.Cpu, lCpu) or not RecordingValue(aCounters.Pid, lPid) or
    not RecordingValue(aCounters.Elapsed, lElapsed) or (lPid < 1) or (lPid > High(Cardinal)) or
    (lElapsed > 365250.0 * SecsPerDay) then
  begin
    Inc(fValue.Phases[aPhase].InvalidValueCount);
    Exit;
  end;
  id := Round(lPid);
  lCreated := aAtUtc - lElapsed / SecsPerDay;
  if not fPids.TryGetValue(id, lIndex) or
    (Abs(fIdentities[lIndex].CreatedUtc - lCreated) * MSecsPerDay > 2 * fValue.IntervalMs + 1000) then
  begin
    if fIdentities.Count >= cMaxIdentities then
    begin
      fValue.Truncated := True;
      Exit;
    end;
    lIdentity := Default(TRecordingIdentity);
    lIdentity.CreatedUtc := lCreated;
    lIndex := fIdentities.Add(lIdentity);
    fPids.AddOrSetValue(id, lIndex);
  end;
  lIdentity := fIdentities[lIndex];
  lProcess := lIdentity.Phases[aPhase];
  lProcess.Value.ProcessId := id;
  lProcess.Value.CreatedUtc := lIdentity.CreatedUtc;
  lProcess.Value.InstanceName := aCounters.Instance;
  i := Pos('#', aCounters.Instance);
  if i > 0 then
    lProcess.Value.DisplayName := Copy(aCounters.Instance, 1, i - 1)
  else
    lProcess.Value.DisplayName := aCounters.Instance;
  lCpu := lCpu / fValue.LogicalProcessorCount;
  if (lProcess.Value.SampleCount = 0) or (lCpu > lProcess.Value.PeakCpuPercent) then
  begin
    lProcess.Value.PeakCpuPercent := lCpu;
    lProcess.Value.PeakAtUtc := aAtUtc;
  end;
  lProcess.CpuTime := lProcess.CpuTime + lCpu * aWeight;
  Inc(lProcess.Value.SampleCount);
  lProcess.Value.LastSeenUtc := aAtUtc;
  lIdentity.Phases[aPhase] := lProcess;
  fIdentities[lIndex] := lIdentity;
end;

function TRecordingReader.ReadSamples: Boolean;
var
  lStatus: Cardinal;
  lRaw: TPdhRaw;
  lStamp: Int64;
  lAtUtc, lPreviousUtc: TDateTime;
  lCpu, lWeight: Double;
  lPhase: TMachineOverviewEvidencePhaseKind;
  lCounter: TRecordingCounters;
begin
  Result := False;
  lPreviousUtc := 0;
  while ContinueReading do
  begin
    if Assigned(fCollect) then
      lStatus := fCollect(fQuery)
    else
      lStatus := PdhCollectQueryData(fQuery);
    if not ContinueReading then
      Exit;
    if lStatus = cNoMoreData then
      Break;
    if not Check(lStatus, 'Collect recorded sample') then
      Exit;
    if not Check(PdhGetRawCounterValue(fSystem, nil, lRaw), 'Read recorded timestamp') then
      Exit;
    Move(lRaw.Stamp, lStamp, SizeOf(lStamp));
    lAtUtc := RecordingUtc(lStamp);
    if lAtUtc > fWindowEnd then
      Break;
    if (lAtUtc < fWindowStart) or ((lPreviousUtc > 0) and (lAtUtc <= lPreviousUtc)) then
    begin
      lPreviousUtc := lAtUtc;
      Continue;
    end;
    lWeight := fValue.IntervalMs / 1000;
    if lPreviousUtc > 0 then
      lWeight := Min(lWeight, (lAtUtc - lPreviousUtc) * SecsPerDay);
    lPreviousUtc := lAtUtc;
    if lAtUtc <= fIncident.StartedAtUtc then
      lPhase := TMachineOverviewEvidencePhaseKind.Before
    else if lAtUtc <= fIncidentEnd then
      lPhase := TMachineOverviewEvidencePhaseKind.During
    else
      lPhase := TMachineOverviewEvidencePhaseKind.After;
    if not RecordingValue(fSystem, lCpu) then
    begin
      Inc(fValue.Phases[lPhase].InvalidValueCount);
      Continue;
    end;
    lWeight := Min(lWeight, Max(0, (lAtUtc - fValue.Phases[lPhase].StartUtc) * SecsPerDay));
    if lWeight <= 0 then
      Continue;
    Inc(fValue.Phases[lPhase].SampleCount);
    fWeights[lPhase] := fWeights[lPhase] + lWeight;
    fValue.Phases[lPhase].SystemCpu.Average := fValue.Phases[lPhase].SystemCpu.Average + lCpu * lWeight;
    if not fValue.Phases[lPhase].SystemCpu.Available or (lCpu > fValue.Phases[lPhase].SystemCpu.Peak) then
    begin
      fValue.Phases[lPhase].SystemCpu.Peak := lCpu;
      fValue.Phases[lPhase].SystemCpu.PeakAtUtc := lAtUtc;
    end;
    fValue.Phases[lPhase].SystemCpu.Available := True;
    for lCounter in fCounters do
      ObserveProcess(lCounter, lPhase, lAtUtc, lWeight);
    if fIdentities.Count >= cMaxIdentities then
    begin
      Note(rsRecordingIdentityLimit);
      Break;
    end;
  end;
  Result := fError.IsEmpty;
end;

function CompareRecordedProcess(const aLeft, aRight: TMachineOverviewRecordedProcess): Integer;
begin
  Result := CompareValue(aRight.AverageCpuPercent, aLeft.AverageCpuPercent);
  if Result = 0 then
    Result := CompareValue(aLeft.ProcessId, aRight.ProcessId);
  if Result = 0 then
    Result := CompareValue(aLeft.CreatedUtc, aRight.CreatedUtc);
end;

procedure TRecordingReader.Finish;
var
  g: TGarbos;
  lProcesses: TList<TMachineOverviewRecordedProcess>;
  lPhase: TMachineOverviewEvidencePhaseKind;
  lIdentity: TRecordingIdentity;
  lProcess: TMachineOverviewRecordedProcess;
  lLimit: Integer;
begin
  g := Default(TGarbos);
  GC(lProcesses, TList<TMachineOverviewRecordedProcess>.Create, g);
  for lPhase := Low(lPhase) to High(lPhase) do
  begin
    lProcesses.Clear;
    fValue.Phases[lPhase].ExpectedSampleCount := Ceil(Max(0,
      (fValue.Phases[lPhase].EndUtc - fValue.Phases[lPhase].StartUtc) * MSecsPerDay / fValue.IntervalMs) - 0.0001);
    if fWeights[lPhase] <= 0 then
      Continue;
    fValue.Phases[lPhase].SystemCpu.Average := fValue.Phases[lPhase].SystemCpu.Average / fWeights[lPhase];
    for lIdentity in fIdentities do
    begin
      lProcess := lIdentity.Phases[lPhase].Value;
      if lProcess.SampleCount = 0 then
        Continue;
      lProcess.AverageCpuPercent := lIdentity.Phases[lPhase].CpuTime / fWeights[lPhase];
      lProcesses.Add(lProcess);
    end;
    lProcesses.Sort(TComparer<TMachineOverviewRecordedProcess>.Construct(CompareRecordedProcess));
    lLimit := 5;
    if lPhase = TMachineOverviewEvidencePhaseKind.During then
      lLimit := 10;
    while lProcesses.Count > lLimit do
      lProcesses.Delete(lProcesses.Count - 1);
    fValue.Phases[lPhase].Processes := lProcesses.ToArray;
  end;
end;

function TRecordingReader.Read(out aValue: TMachineOverviewRecording; out aError: string): Boolean;
begin
  aValue := Default(TMachineOverviewRecording);
  Result := Prepare;
  if Result and (fValue.Coverage <> TMachineOverviewRecordingCoverage.None) then
    Result := AddCounters and ReadSamples;
  if Result then
  begin
    Finish;
  end;
  if not ClosePdh then
    Result := False;
  if Result then
    aValue := fValue;
  aError := fError;
  if not Result and aError.IsEmpty then
    aError := rsRecordingTimeout;
end;

function TryReadMachineOverviewRecording(const aFileNames: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aLogicalProcessorCount: Integer;
  const aCancelled: TFunc<Boolean>; out aRecording: TMachineOverviewRecording; out aError: string): Boolean;
begin
  Result := TryReadMachineOverviewRecordingWithCollector(aFileNames, aIncident, aLogicalProcessorCount,
    aCancelled, nil, aRecording, aError);
end;

function TryReadMachineOverviewRecordingWithCollector(const aFileNames: TArray<string>;
  const aIncident: TMachineOverviewIncident; const aLogicalProcessorCount: Integer;
  const aCancelled: TFunc<Boolean>; const aCollect: TFunc<NativeUInt, Cardinal>;
  out aRecording: TMachineOverviewRecording; out aError: string): Boolean;
var
  g: TGarbos;
  lReader: TRecordingReader;
begin
  aRecording := Default(TMachineOverviewRecording);
  aError := '';
  g := Default(TGarbos);
  try
    GC(lReader, TRecordingReader.Create(aFileNames, aIncident, aLogicalProcessorCount, aCancelled), g);
    lReader.fCollect := aCollect;
  Result := lReader.Read(aRecording, aError);
  except
    on lException: Exception do
    begin
      Result := False;
      aRecording := Default(TMachineOverviewRecording);
      aError := lException.Message;
    end;
  end;
end;

function RecordingPercent(const aValue: Double): string;
begin
  Result := FormatFloat('0.###', aValue, TFormatSettings.Invariant) + '% of machine';
end;

function RecordingPrecision(const aRecording: TMachineOverviewRecording): string;
begin
  Result := FormatFloat('0.###', aRecording.IntervalMs / 1000, TFormatSettings.Invariant);
end;

function RecordingRow(const aPhase, aKind, aName, aIdentity, aAverage, aPeak, aAt, aMeasured: string): TMachineOverviewEvidenceRow;
begin
  Result := Default(TMachineOverviewEvidenceRow);
  Result.Phase := aPhase; Result.Kind := aKind; Result.Name := aName;
  Result.Identity := aIdentity; Result.Average := aAverage; Result.Peak := aPeak;
  Result.PeakTime := aAt; Result.Measured := aMeasured;
  Result.AccessibleText := Format('Phase %s, kind %s, name %s, identity %s, average %s, peak %s, peak time %s, measured %s',
    [aPhase, aKind, aName, aIdentity, aAverage, aPeak, aAt, aMeasured]);
end;

function MachineOverviewRecordingRows(const aRecording: TMachineOverviewRecording):
  TArray<TMachineOverviewEvidenceRow>;
const
  cNames: array[TMachineOverviewEvidencePhaseKind] of string = ('before', 'during', 'after');
var
  lKind: TMachineOverviewEvidencePhaseKind;
  lPhase: TMachineOverviewRecordingPhase;
  lProcess: TMachineOverviewRecordedProcess;
  lName, lRange, lMeasured: string;
begin
  Result := nil;
  for lKind in cPhaseOrder do
  begin
    lPhase := aRecording.Phases[lKind];
    lName := Format(rsRecordingPhase, [cNames[lKind]]);
    lRange := Format(rsRecordingPhaseRange, [MachineOverviewEvidenceTimeText(lPhase.StartUtc),
      MachineOverviewEvidenceTimeText(lPhase.EndUtc)]);
    lMeasured := Format(rsRecordingSamples, [lPhase.SampleCount, lPhase.ExpectedSampleCount, lPhase.InvalidValueCount]);
    if lPhase.SystemCpu.Available then
      Result := Result + [RecordingRow(lName, rsRecordedSystem, 'CPU', lRange,
        RecordingPercent(lPhase.SystemCpu.Average), RecordingPercent(lPhase.SystemCpu.Peak),
        MachineOverviewEvidenceTimeText(lPhase.SystemCpu.PeakAtUtc), lMeasured)]
    else
      Result := Result + [RecordingRow(lName, rsRecordedSystem, 'CPU', lRange, rsRecordingNoData, '', '', lMeasured)];
    for lProcess in lPhase.Processes do
      Result := Result + [RecordingRow(lName, rsRecordedProcess, lProcess.DisplayName,
        Format(rsRecordingIdentity, [lProcess.ProcessId, MachineOverviewEvidenceTimeText(lProcess.CreatedUtc),
          RecordingPrecision(aRecording)]), RecordingPercent(lProcess.AverageCpuPercent),
        RecordingPercent(lProcess.PeakCpuPercent), MachineOverviewEvidenceTimeText(lProcess.PeakAtUtc),
        Format(rsRecordingProcessSamples, [lProcess.SampleCount, MachineOverviewEvidenceTimeText(lProcess.LastSeenUtc)]))];
  end;
  Result := Result + [RecordingRow(rsRecordingStatus, '', '', '', '', '', '', string.Join(' ', aRecording.Notes))];
end;

function MachineOverviewRecordingText(const aRecording: TMachineOverviewRecording): string;
var
  lRow: TMachineOverviewEvidenceRow;
begin
  Result := rsRecordingHeader + sLineBreak + Format(rsRecordingMeta, [string.Join('; ', aRecording.FileNames),
    aRecording.MachineName, MachineOverviewEvidenceTimeText(aRecording.LogStartUtc),
    MachineOverviewEvidenceTimeText(aRecording.LogEndUtc), aRecording.IntervalMs, aRecording.LogicalProcessorCount,
    FormatFloat('0.###', 100 / Max(1, aRecording.LogicalProcessorCount), TFormatSettings.Invariant)]) + sLineBreak +
    Format(rsRecordingPrecision, [RecordingPrecision(aRecording)]) + sLineBreak;
  for lRow in MachineOverviewRecordingRows(aRecording) do
    Result := Result + lRow.AccessibleText + sLineBreak;
end;

initialization
  RecordingThreadHandles := TList<THandle>.Create;

finalization
  // Never finalize RTL/PDH dependencies beneath a reader still in native I/O.
  // Normal completed reads retain full cleanup/leak reporting. At process exit
  // only, give detached readers 250 ms, then terminate this process without DLL
  // detach/finalizers. Windows reclaims the remaining private memory and handles.
  // TerminateProcess avoids ExitProcess's DLL-detach lock deadlock risk.
  if not WaitForMachineOverviewRecordingReaders(250) then
    TerminateProcess(GetCurrentProcess, Cardinal(System.ExitCode));
  RecordingThreadHandles.Free;

end.

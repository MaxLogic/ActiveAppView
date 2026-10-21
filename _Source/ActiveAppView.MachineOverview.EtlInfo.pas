unit ActiveAppView.MachineOverview.EtlInfo;

interface

type
  TMachineOverviewEtlInfo = record
    Readable: Boolean;
    FirstEventUtc, LastEventUtc: TDateTime;
    EventsLost, BuffersLost: Cardinal;
    ErrorText: string;
  end;

function ReadMachineOverviewEtlInfo(const aFileName: string): TMachineOverviewEtlInfo;

implementation

uses
  System.SysUtils,
  Winapi.Windows;

{$ALIGN 8}
type
  // SDK 10.0.26100.0 evntrace.h / evntcons.h, pack(8). No managed data crosses the ABI.
  TLocalEventTrace = record
    Header: array[0..47] of Byte;
    InstanceId, ParentInstanceId: Cardinal;
    ParentGuid: TGUID;
    MofData: Pointer;
    MofLength, ClientContext: Cardinal;
  end;
  TLocalLogfileHeader = record
    BufferSize, Version, ProviderVersion, NumberOfProcessors: Cardinal;
    EndTime: Int64;
    TimerResolution, MaximumFileSize, LogFileMode, BuffersWritten: Cardinal;
    StartBuffers, PointerSize, EventsLost, CpuSpeedInMHz: Cardinal;
    LoggerName, LogFileName: PWideChar;
    TimeZone: TTimeZoneInformation;
    BootTime, PerfFreq, StartTime: Int64;
    ReservedFlags, BuffersLost: Cardinal;
  end;
  PLocalLogfile = ^TLocalLogfile;
  TLocalBufferCallback = function(const aLog: PLocalLogfile): Cardinal; stdcall;
  PLocalEventRecord = ^TLocalEventRecord;
  TLocalEventRecord = record
    Size, HeaderType, Flags, EventProperty: Word;
    ThreadId, ProcessId: Cardinal;
    TimeStamp: Int64;
    RestOfHeader: array[0..55] of Byte;
    BufferContext: Cardinal;
    ExtendedDataCount, UserDataLength: Word;
    ExtendedData, UserData, UserContext: Pointer;
  end;
  TLocalEventCallback = procedure(const aEvent: PLocalEventRecord); stdcall;
  TLocalLogfile = record
    LogFileName, LoggerName: PWideChar;
    CurrentTime: Int64;
    BuffersRead, ProcessTraceMode: Cardinal;
    CurrentEvent: TLocalEventTrace;
    LogfileHeader: TLocalLogfileHeader;
    BufferCallback: TLocalBufferCallback;
    BufferSize, Filled, EventsLost: Cardinal;
    EventRecordCallback: TLocalEventCallback;
    IsKernelTrace: Cardinal;
    Context: Pointer;
  end;
  PEtlReadContext = ^TEtlReadContext;
  TEtlReadContext = record
    FirstTimestamp: Int64;
    BufferCount: Cardinal;
  end;

function LocalOpenTraceW(var aLog: TLocalLogfile): UInt64; stdcall;
  external 'advapi32.dll' name 'OpenTraceW';
function LocalProcessTrace(const aHandles: Pointer; const aCount: Cardinal;
  const aStart, aEnd: Pointer): Cardinal; stdcall;
  external 'advapi32.dll' name 'ProcessTrace';
function LocalCloseTrace(const aHandle: UInt64): Cardinal; stdcall;
  external 'advapi32.dll' name 'CloseTrace';

procedure EtlEvent(const aEvent: PLocalEventRecord); stdcall;
var
  lContext: PEtlReadContext;
begin
  lContext := aEvent.UserContext;
  if (aEvent.TimeStamp > 0) and
    ((lContext.FirstTimestamp = 0) or (aEvent.TimeStamp < lContext.FirstTimestamp)) then
    lContext.FirstTimestamp := aEvent.TimeStamp;
end;

function EtlBuffer(const aLog: PLocalLogfile): Cardinal; stdcall;
var
  lContext: PEtlReadContext;
begin
  lContext := aLog.Context;
  Inc(lContext.BufferCount);
  Result := Ord(lContext.BufferCount < 64);
end;

function EtlTimestampUtc(const aValue: Int64): TDateTime;
begin
  Result := (aValue / 864000000000.0) - 109205.0;
end;

function ReadMachineOverviewEtlInfo(const aFileName: string): TMachineOverviewEtlInfo;
var
  lLog: TLocalLogfile;
  lContext: TEtlReadContext;
  lHandle: UInt64;
  lStatus, lCloseStatus: Cardinal;
begin
  Result := Default(TMachineOverviewEtlInfo);
  try
    lLog := Default(TLocalLogfile);
    lContext := Default(TEtlReadContext);
    {$IFDEF WIN64}
    if (SizeOf(lLog) <> 448) or (SizeOf(TLocalLogfileHeader) <> 280) or
      (NativeUInt(@lLog.LogfileHeader) - NativeUInt(@lLog) <> 120) or
      (SizeOf(TLocalEventRecord) <> 112) then
      raise EInvalidOpException.Create('ETL consumer SDK layout mismatch');
    {$ENDIF}
    lLog.LogFileName := PWideChar(aFileName);
    lLog.ProcessTraceMode := $10000000; // EVENT_RECORD; timestamps converted to FILETIME by ProcessTrace.
    lLog.EventRecordCallback := EtlEvent;
    lLog.BufferCallback := EtlBuffer;
    lLog.Context := @lContext;
    lHandle := LocalOpenTraceW(lLog);
    if lHandle = High(UInt64) then
      raise EOSError.CreateFmt('OpenTrace: %s', [SysErrorMessage(GetLastError)]);
    try
      lStatus := LocalProcessTrace(@lHandle, 1, nil, nil);
    finally
      lCloseStatus := LocalCloseTrace(lHandle);
    end;
    if (lStatus <> ERROR_SUCCESS) and
      ((lStatus <> ERROR_CANCELLED) or (lContext.BufferCount < 64)) then
      raise EOSError.CreateFmt('ProcessTrace: %s', [SysErrorMessage(lStatus)]);
    if lCloseStatus <> ERROR_SUCCESS then
      raise EOSError.CreateFmt('CloseTrace: %s', [SysErrorMessage(lCloseStatus)]);
    if (lContext.FirstTimestamp <= 0) or (lLog.LogfileHeader.EndTime <= 0) then
      raise EInvalidOpException.Create('ETL contains no readable event span');
    Result.FirstEventUtc := EtlTimestampUtc(lContext.FirstTimestamp);
    Result.LastEventUtc := EtlTimestampUtc(lLog.LogfileHeader.EndTime);
    Result.EventsLost := lLog.LogfileHeader.EventsLost;
    Result.BuffersLost := lLog.LogfileHeader.BuffersLost;
    Result.Readable := True;
  except
    on lException: Exception do
      Result.ErrorText := lException.ClassName + ': ' + lException.Message;
  end;
end;

end.

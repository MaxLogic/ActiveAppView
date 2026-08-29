unit ActiveAppView.MachineOverview.BoundedProcess;

interface

type
  TMachineOverviewProcessResult = record
    Cancelled: Boolean;
    Started: Boolean;
    TimedOut: Boolean;
    ExitCode: Cardinal;
    ProcessId: Cardinal;
    DurationMs: UInt64;
    OutputText: string;
    ErrorText: string;
  end;

function RunMachineOverviewBoundedProcess(const aApplicationName,
  aArguments: string; const aTimeoutMs, aMaximumOutputBytes: Cardinal):
  TMachineOverviewProcessResult;
function RunMachineOverviewBoundedProcessCancelable(const aApplicationName,
  aArguments: string; const aTimeoutMs, aMaximumOutputBytes: Cardinal;
  const aCancellationHandle: NativeUInt): TMachineOverviewProcessResult;

implementation

uses
  System.SysUtils,
  Winapi.Windows;

const
  cMachineOverviewProcessTimeoutExitCode = 1460;
  cMachineOverviewProcessTerminationWaitMs = 1000;

procedure AppendPipeOutput(const aReadPipe: THandle;
  const aMaximumOutputBytes: Cardinal; var aOutput: TBytes);
var
  lAvailable: Cardinal;
  lBuffer: array[0..4095] of Byte;
  lCopyCount: Cardinal;
  lOldLength: Integer;
  lReadCount: Cardinal;
  lRemaining: Cardinal;
begin
  repeat
    if not PeekNamedPipe(aReadPipe, nil, 0, nil, @lAvailable, nil) then
      Exit;
    if lAvailable = 0 then
      Exit;
    if lAvailable > Cardinal(Length(lBuffer)) then
      lAvailable := Length(lBuffer);
    if not ReadFile(aReadPipe, lBuffer[0], lAvailable, lReadCount, nil) then
      Exit;
    if lReadCount = 0 then
      Exit;
    if Cardinal(Length(aOutput)) >= aMaximumOutputBytes then
      Continue;
    lRemaining := aMaximumOutputBytes - Cardinal(Length(aOutput));
    lCopyCount := lReadCount;
    if lCopyCount > lRemaining then
      lCopyCount := lRemaining;
    lOldLength := Length(aOutput);
    SetLength(aOutput, lOldLength + Integer(lCopyCount));
    if lCopyCount > 0 then
      Move(lBuffer[0], aOutput[lOldLength], lCopyCount);
  until False;
end;

function RunMachineOverviewBoundedProcessInternal(const aApplicationName,
  aArguments: string; const aTimeoutMs, aMaximumOutputBytes: Cardinal;
  const aCancellationHandle: NativeUInt): TMachineOverviewProcessResult;
var
  lCancellationWaitResult: Cardinal;
  lCommandLine: string;
  lOutput: TBytes;
  lProcessInfo: TProcessInformation;
  lReadPipe: THandle;
  lSecurity: TSecurityAttributes;
  lStartedAtMs: UInt64;
  lStartupInfo: TStartupInfo;
  lWaitResult: Cardinal;
  lWritePipe: THandle;
begin
  Result := Default(TMachineOverviewProcessResult);
  Result.ExitCode := Cardinal(-1);
  if aApplicationName.IsEmpty or (aTimeoutMs = 0) or
    (Pos('"', aApplicationName) > 0) then
  begin
    Result.ErrorText := 'Invalid bounded process arguments';
    Exit;
  end;
  lReadPipe := 0;
  lWritePipe := 0;
  lSecurity := Default(TSecurityAttributes);
  lSecurity.nLength := SizeOf(lSecurity);
  lSecurity.bInheritHandle := True;
  if not CreatePipe(lReadPipe, lWritePipe, @lSecurity, 0) then
  begin
    Result.ErrorText := 'Output pipe creation failed: ' +
      SysErrorMessage(GetLastError);
    Exit;
  end;
  try
    if not SetHandleInformation(lReadPipe, HANDLE_FLAG_INHERIT, 0) then
    begin
      Result.ErrorText := 'Output pipe isolation failed: ' +
        SysErrorMessage(GetLastError);
      Exit;
    end;
    lCommandLine := '"' + aApplicationName + '"';
    if not aArguments.IsEmpty then
      lCommandLine := lCommandLine + ' ' + aArguments;
    lProcessInfo := Default(TProcessInformation);
    lStartupInfo := Default(TStartupInfo);
    lStartupInfo.cb := SizeOf(lStartupInfo);
    lStartupInfo.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    lStartupInfo.wShowWindow := SW_HIDE;
    lStartupInfo.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    lStartupInfo.hStdOutput := lWritePipe;
    lStartupInfo.hStdError := lWritePipe;
    if not CreateProcess(PChar(aApplicationName), PChar(lCommandLine), nil, nil,
        True, CREATE_NO_WINDOW, nil, nil, lStartupInfo, lProcessInfo) then
    begin
      Result.ErrorText := 'Process creation failed: ' +
        SysErrorMessage(GetLastError);
      Exit;
    end;
    Result.Started := True;
    Result.ProcessId := lProcessInfo.dwProcessId;
    CloseHandle(lWritePipe);
    lWritePipe := 0;
    lStartedAtMs := GetTickCount64;
    try
      repeat
        AppendPipeOutput(lReadPipe, aMaximumOutputBytes, lOutput);
        lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, 0);
        if lWaitResult = WAIT_OBJECT_0 then
        begin
          if not GetExitCodeProcess(lProcessInfo.hProcess, Result.ExitCode) then
            Result.ErrorText := 'Process exit-code query failed: ' +
              SysErrorMessage(GetLastError);
          Break;
        end;
        if lWaitResult = WAIT_FAILED then
        begin
          Result.ErrorText := 'Process wait failed: ' +
            SysErrorMessage(GetLastError);
          TerminateProcess(lProcessInfo.hProcess,
            cMachineOverviewProcessTimeoutExitCode);
          Break;
        end;
        if aCancellationHandle <> 0 then
        begin
          lCancellationWaitResult := WaitForSingleObject(
            THandle(aCancellationHandle), 0);
          if lCancellationWaitResult = WAIT_OBJECT_0 then
          begin
            Result.Cancelled := True;
            Result.ExitCode := ERROR_CANCELLED;
            Result.ErrorText := 'Process cancelled';
            if not TerminateProcess(lProcessInfo.hProcess, ERROR_CANCELLED) then
              Result.ErrorText := Result.ErrorText +
                '; termination failed: ' + SysErrorMessage(GetLastError);
            WaitForSingleObject(lProcessInfo.hProcess,
              cMachineOverviewProcessTerminationWaitMs);
            Break;
          end;
          if lCancellationWaitResult = WAIT_FAILED then
          begin
            Result.ErrorText := 'Cancellation wait failed: ' +
              SysErrorMessage(GetLastError);
            TerminateProcess(lProcessInfo.hProcess, ERROR_CANCELLED);
            WaitForSingleObject(lProcessInfo.hProcess,
              cMachineOverviewProcessTerminationWaitMs);
            Break;
          end;
        end;
        if GetTickCount64 - lStartedAtMs >= aTimeoutMs then
        begin
          Result.TimedOut := True;
          Result.ExitCode := cMachineOverviewProcessTimeoutExitCode;
          Result.ErrorText := Format('Process timed out after %d ms',
            [aTimeoutMs]);
          if not TerminateProcess(lProcessInfo.hProcess,
              cMachineOverviewProcessTimeoutExitCode) then
            Result.ErrorText := Result.ErrorText + '; termination failed: ' +
              SysErrorMessage(GetLastError);
          WaitForSingleObject(lProcessInfo.hProcess,
            cMachineOverviewProcessTerminationWaitMs);
          Break;
        end;
        Sleep(10);
      until False;
      AppendPipeOutput(lReadPipe, aMaximumOutputBytes, lOutput);
      Result.DurationMs := GetTickCount64 - lStartedAtMs;
      if Length(lOutput) > 0 then
        Result.OutputText := TEncoding.UTF8.GetString(lOutput);
    finally
      CloseHandle(lProcessInfo.hThread);
      CloseHandle(lProcessInfo.hProcess);
    end;
  finally
    if lWritePipe <> 0 then
      CloseHandle(lWritePipe);
    if lReadPipe <> 0 then
      CloseHandle(lReadPipe);
  end;
end;

function RunMachineOverviewBoundedProcess(const aApplicationName,
  aArguments: string; const aTimeoutMs, aMaximumOutputBytes: Cardinal):
  TMachineOverviewProcessResult;
begin
  Result := RunMachineOverviewBoundedProcessInternal(aApplicationName,
    aArguments, aTimeoutMs, aMaximumOutputBytes, 0);
end;

function RunMachineOverviewBoundedProcessCancelable(const aApplicationName,
  aArguments: string; const aTimeoutMs, aMaximumOutputBytes: Cardinal;
  const aCancellationHandle: NativeUInt): TMachineOverviewProcessResult;
begin
  Result := RunMachineOverviewBoundedProcessInternal(aApplicationName,
    aArguments, aTimeoutMs, aMaximumOutputBytes, aCancellationHandle);
end;

end.

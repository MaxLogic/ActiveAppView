unit ActiveAppView.Launcher;

interface

uses
  System.SysUtils;

const
  cLaunchClassificationSelfTestArg = '--self-test-launch-classification';
  cLaunchHelperCrashIsolatedSelfTestArg = '--self-test-launch-helper-crash-isolated';
  cLaunchHelperPathsSelfTestArg = '--self-test-launch-helper-paths';

function IsLaunchMissingTargetExitCode(const aExitCode: Cardinal): Boolean;
function IsLaunchSuccessExitCode(const aExitCode: Cardinal): Boolean;
function RunLauncherHelperFromCommandLine: Integer;
function RunLauncherSelfTests(const aArg: string): Integer;
function TryLaunchPathIsolated(const aPath: string; const aParams: string; out aExitCode: Cardinal): Boolean;

implementation

uses
  System.Classes, System.IOUtils, System.StrUtils, System.Win.ComObj,
  Winapi.ActiveX, Winapi.ShellAPI, Winapi.ShlObj, Winapi.Windows;

const
  cLaunchHelperArg = '--launch-helper';
  cLaunchHelperProbeArg = '--launch-helper-probe';
  cLaunchHelperTestFailArg = '--launch-helper-test-fail';
  cLaunchExitProcessCreateFailed = 30;
  cLaunchExitShellFallbackFailed = 31;
  cLaunchExitTargetMissing = 32;
  cLaunchExitTimeout = 33;
  cLaunchExitTestFailure = 47;
  cLaunchProbeDirectory = 61;
  cLaunchProbeExecutable = 62;
  cLaunchProbeShellFallback = 63;
  cLaunchWaitTimeoutMs = 5000;

type
  TLaunchMode = (lmMissing, lmDirectory, lmExecutable, lmShellFallback);

function QuoteCommandLineArgument(const aValue: string): string;
var
  lBuilder: TStringBuilder;
  lBackslashCount: Integer;
  lCh: Char;
  i: Integer;
begin
  if aValue = '' then
    Exit('""');

  if (Pos(' ', aValue) = 0) and (Pos(#9, aValue) = 0) and (Pos('"', aValue) = 0) then
    Exit(aValue);

  lBuilder := TStringBuilder.Create;
  try
    lBuilder.Append('"');
    lBackslashCount := 0;
    for i := 1 to Length(aValue) do
    begin
      lCh := aValue[i];
      if lCh = '\' then
      begin
        Inc(lBackslashCount);
        Continue;
      end;

      if lCh = '"' then
      begin
        lBuilder.Append(StringOfChar('\', (lBackslashCount * 2) + 1));
        lBuilder.Append('"');
        lBackslashCount := 0;
        Continue;
      end;

      if lBackslashCount > 0 then
      begin
        lBuilder.Append(StringOfChar('\', lBackslashCount));
        lBackslashCount := 0;
      end;
      lBuilder.Append(lCh);
    end;

    if lBackslashCount > 0 then
      lBuilder.Append(StringOfChar('\', lBackslashCount * 2));
    lBuilder.Append('"');
    Result := lBuilder.ToString;
  finally
    lBuilder.Free;
  end;
end;

function BuildCommandLine(const aExecutablePath: string; const aParams: string): string;
begin
  if aParams = '' then
    Exit(aExecutablePath);

  Result := aExecutablePath + ' ' + aParams;
end;

function BuildHelperCommandLine(const aMode: string; const aPath: string; const aParams: string): string;
begin
  Result := Format(
    '%s %s %s %s',
    [
      QuoteCommandLineArgument(ParamStr(0)),
      aMode,
      QuoteCommandLineArgument(aPath),
      QuoteCommandLineArgument(aParams)
    ]);
end;

function DetermineLaunchMode(
  const aPath: string;
  const aParams: string;
  out aLaunchPath: string;
  out aLaunchParams: string;
  out aWorkingDirectory: string): TLaunchMode;
var
  lArgumentsBuffer: array[0..2047] of Char;
  lExtension: string;
  lFindData: TWin32FindDataW;
  lPathBuffer: array[0..2047] of Char;
  lPersistFile: IPersistFile;
  lResolvedArguments: string;
  lResolvedPath: string;
  lShellLink: IShellLinkW;
  lWorkingDirectoryBuffer: array[0..2047] of Char;
begin
  aLaunchPath := '';
  aLaunchParams := '';
  aWorkingDirectory := '';
  if aPath = '' then
    Exit(TLaunchMode.lmMissing);

  if DirectoryExists(aPath) then
  begin
    aLaunchPath := aPath;
    Exit(TLaunchMode.lmDirectory);
  end;

  if StartsText('\\', aPath) then
  begin
    aLaunchPath := aPath;
    aLaunchParams := aParams;
    Exit(TLaunchMode.lmShellFallback);
  end;

  if not FileExists(aPath) then
    Exit(TLaunchMode.lmMissing);

  lExtension := TPath.GetExtension(aPath);
  if SameText(lExtension, '.lnk') then
  begin
    lShellLink := CreateComObject(CLSID_ShellLink) as IShellLinkW;
    lPersistFile := lShellLink as IPersistFile;
    OleCheck(lPersistFile.Load(PWideChar(WideString(aPath)), STGM_READ));

    FillChar(lPathBuffer, SizeOf(lPathBuffer), 0);
    FillChar(lArgumentsBuffer, SizeOf(lArgumentsBuffer), 0);
    FillChar(lWorkingDirectoryBuffer, SizeOf(lWorkingDirectoryBuffer), 0);
    lFindData := Default(TWin32FindDataW);
    lShellLink.GetPath(@lPathBuffer[0], Length(lPathBuffer), lFindData, SLGP_UNCPRIORITY);
    lShellLink.GetArguments(@lArgumentsBuffer[0], Length(lArgumentsBuffer));
    lShellLink.GetWorkingDirectory(@lWorkingDirectoryBuffer[0], Length(lWorkingDirectoryBuffer));

    lResolvedPath := PChar(@lPathBuffer[0]);
    lResolvedArguments := PChar(@lArgumentsBuffer[0]);
    aWorkingDirectory := PChar(@lWorkingDirectoryBuffer[0]);
    if lResolvedPath = '' then
    begin
      aLaunchPath := aPath;
      aLaunchParams := aParams;
      Exit(TLaunchMode.lmShellFallback);
    end;

    if aParams <> '' then
      aLaunchParams := aParams
    else
      aLaunchParams := lResolvedArguments;

    if DirectoryExists(lResolvedPath) then
    begin
      aLaunchPath := lResolvedPath;
      aLaunchParams := '';
      Exit(TLaunchMode.lmDirectory);
    end;

    if StartsText('\\', lResolvedPath) then
    begin
      aLaunchPath := lResolvedPath;
      Exit(TLaunchMode.lmShellFallback);
    end;

    if not FileExists(lResolvedPath) then
      Exit(TLaunchMode.lmMissing);

    aLaunchPath := lResolvedPath;
    if aWorkingDirectory = '' then
      aWorkingDirectory := ExtractFileDir(lResolvedPath);
    if MatchText(TPath.GetExtension(lResolvedPath), ['.com', '.exe']) then
      Exit(TLaunchMode.lmExecutable);
    Exit(TLaunchMode.lmShellFallback);
  end;

  aLaunchPath := aPath;
  aLaunchParams := aParams;
  aWorkingDirectory := ExtractFileDir(aPath);
  if MatchText(lExtension, ['.com', '.exe']) then
    Exit(TLaunchMode.lmExecutable);

  Result := TLaunchMode.lmShellFallback;
end;

function ExecuteDirectoryLaunch(const aPath: string): Integer;
var
  lCommandLine: string;
  lProcessInfo: TProcessInformation;
  lStartupInfo: TStartupInfo;
begin
  lCommandLine := 'explorer.exe ' + QuoteCommandLineArgument(aPath);
  lProcessInfo := Default(TProcessInformation);
  lStartupInfo := Default(TStartupInfo);
  lStartupInfo.cb := SizeOf(TStartupInfo);
  lStartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  lStartupInfo.wShowWindow := SW_SHOWNORMAL;
  if not CreateProcess(nil, PChar(lCommandLine), nil, nil, False, 0, nil, nil, lStartupInfo, lProcessInfo) then
    Exit(cLaunchExitProcessCreateFailed);
  try
    Result := ERROR_SUCCESS;
  finally
    CloseHandle(lProcessInfo.hThread);
    CloseHandle(lProcessInfo.hProcess);
  end;
end;

function ExecuteProcessLaunch(const aPath: string; const aParams: string; const aWorkingDirectory: string): Integer;
var
  lCommandLine: string;
  lCurrentDirectory: PChar;
  lProcessInfo: TProcessInformation;
  lStartupInfo: TStartupInfo;
begin
  lCommandLine := BuildCommandLine('"' + aPath + '"', aParams);
  lProcessInfo := Default(TProcessInformation);
  lStartupInfo := Default(TStartupInfo);
  lStartupInfo.cb := SizeOf(TStartupInfo);
  lStartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  lStartupInfo.wShowWindow := SW_SHOWNORMAL;
  if aWorkingDirectory = '' then
    lCurrentDirectory := nil
  else
    lCurrentDirectory := PChar(aWorkingDirectory);
  if not CreateProcess(PChar(aPath), PChar(lCommandLine), nil, nil, False, 0, nil, lCurrentDirectory, lStartupInfo, lProcessInfo) then
    Exit(cLaunchExitProcessCreateFailed);
  try
    Result := ERROR_SUCCESS;
  finally
    CloseHandle(lProcessInfo.hThread);
    CloseHandle(lProcessInfo.hProcess);
  end;
end;

function ExecuteShellFallback(const aPath: string; const aParams: string; const aWorkingDirectory: string): Integer;
var
  lInfo: TShellExecuteInfo;
begin
  lInfo := Default(TShellExecuteInfo);
  lInfo.cbSize := SizeOf(TShellExecuteInfo);
  lInfo.fMask := SEE_MASK_FLAG_DDEWAIT or SEE_MASK_FLAG_NO_UI or SEE_MASK_NOCLOSEPROCESS or SEE_MASK_NOASYNC;
  lInfo.Wnd := 0;
  lInfo.lpVerb := 'open';
  lInfo.lpFile := PChar(aPath);
  if aParams <> '' then
    lInfo.lpParameters := PChar(aParams);
  if aWorkingDirectory <> '' then
    lInfo.lpDirectory := PChar(aWorkingDirectory);
  lInfo.nShow := SW_SHOWNORMAL;
  if not ShellExecuteEx(@lInfo) then
    Exit(cLaunchExitShellFallbackFailed);
  if lInfo.hProcess <> 0 then
    CloseHandle(lInfo.hProcess);
  Result := ERROR_SUCCESS;
end;

function ExecuteLaunchPath(const aPath: string; const aParams: string): Integer;
var
  lLaunchPath: string;
  lLaunchParams: string;
  lMode: TLaunchMode;
  lShouldUninitialize: Boolean;
  lWorkingDirectory: string;
begin
  lShouldUninitialize := False;
  case CoInitializeEx(nil, COINIT_APARTMENTTHREADED or COINIT_DISABLE_OLE1DDE) of
    S_OK, S_FALSE:
      lShouldUninitialize := True;
  else
    Exit(cLaunchExitProcessCreateFailed);
  end;

  try
    lMode := DetermineLaunchMode(aPath, aParams, lLaunchPath, lLaunchParams, lWorkingDirectory);
    case lMode of
      TLaunchMode.lmDirectory:
        Result := ExecuteDirectoryLaunch(lLaunchPath);
      TLaunchMode.lmExecutable:
        Result := ExecuteProcessLaunch(lLaunchPath, lLaunchParams, lWorkingDirectory);
      TLaunchMode.lmShellFallback:
        Result := ExecuteShellFallback(lLaunchPath, lLaunchParams, lWorkingDirectory);
    else
      Result := cLaunchExitTargetMissing;
    end;
  finally
    if lShouldUninitialize then
      CoUninitialize;
  end;
end;

function GetProbeExitCode(const aMode: TLaunchMode): Integer;
begin
  case aMode of
    TLaunchMode.lmDirectory:
      Result := cLaunchProbeDirectory;
    TLaunchMode.lmExecutable:
      Result := cLaunchProbeExecutable;
    TLaunchMode.lmMissing:
      Result := cLaunchExitTargetMissing;
  else
    Result := cLaunchProbeShellFallback;
  end;
end;

function IsLaunchMissingTargetExitCode(const aExitCode: Cardinal): Boolean;
begin
  Result := aExitCode = cLaunchExitTargetMissing;
end;

function IsLaunchSuccessExitCode(const aExitCode: Cardinal): Boolean;
begin
  Result := aExitCode = ERROR_SUCCESS;
end;

function RunLaunchHelperProbe: Integer;
var
  lLaunchPath: string;
  lLaunchParams: string;
  lMode: TLaunchMode;
  lShouldUninitialize: Boolean;
  lWorkingDirectory: string;
begin
  lShouldUninitialize := False;
  case CoInitializeEx(nil, COINIT_APARTMENTTHREADED or COINIT_DISABLE_OLE1DDE) of
    S_OK, S_FALSE:
      lShouldUninitialize := True;
  else
    Exit(cLaunchExitProcessCreateFailed);
  end;
  try
    lMode := DetermineLaunchMode(ParamStr(2), ParamStr(3), lLaunchPath, lLaunchParams, lWorkingDirectory);
    Result := GetProbeExitCode(lMode);
  finally
    if lShouldUninitialize then
      CoUninitialize;
  end;
end;

function RunLaunchHelperExecute: Integer;
begin
  Result := ExecuteLaunchPath(ParamStr(2), ParamStr(3));
end;

function RunLaunchHelperTestFail: Integer;
begin
  Result := cLaunchExitTestFailure;
end;

function RunLauncherHelperFromCommandLine: Integer;
var
  lMode: string;
begin
  Result := -1;
  lMode := ParamStr(1);
  if SameText(lMode, cLaunchHelperProbeArg) then
    Exit(RunLaunchHelperProbe);
  if SameText(lMode, cLaunchHelperArg) then
    Exit(RunLaunchHelperExecute);
  if SameText(lMode, cLaunchHelperTestFailArg) then
    Exit(RunLaunchHelperTestFail);
end;

function TryRunHelper(const aMode: string; const aPath: string; const aParams: string; out aExitCode: Cardinal): Boolean;
var
  lCommandLine: string;
  lProcessInfo: TProcessInformation;
  lStartupInfo: TStartupInfo;
  lWaitResult: Cardinal;
begin
  lCommandLine := BuildHelperCommandLine(aMode, aPath, aParams);
  lProcessInfo := Default(TProcessInformation);
  lStartupInfo := Default(TStartupInfo);
  lStartupInfo.cb := SizeOf(TStartupInfo);
  lStartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  lStartupInfo.wShowWindow := SW_HIDE;

  Result := CreateProcess(
    PChar(ParamStr(0)),
    PChar(lCommandLine),
    nil,
    nil,
    False,
    CREATE_NO_WINDOW,
    nil,
    nil,
    lStartupInfo,
    lProcessInfo);
  if not Result then
  begin
    aExitCode := cLaunchExitProcessCreateFailed;
    Exit;
  end;

  try
    lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, cLaunchWaitTimeoutMs);
    if lWaitResult <> WAIT_OBJECT_0 then
    begin
      TerminateProcess(lProcessInfo.hProcess, cLaunchExitTimeout);
      aExitCode := cLaunchExitTimeout;
      Exit(True);
    end;

    GetExitCodeProcess(lProcessInfo.hProcess, aExitCode);
    Result := True;
  finally
    CloseHandle(lProcessInfo.hThread);
    CloseHandle(lProcessInfo.hProcess);
  end;
end;

function TryLaunchPathIsolated(const aPath: string; const aParams: string; out aExitCode: Cardinal): Boolean;
begin
  Result := TryRunHelper(cLaunchHelperArg, aPath, aParams, aExitCode);
end;

function RunLaunchHelperCrashIsolatedSelfTest: Integer;
var
  lExitCode: Cardinal;
begin
  Result := 0;
  if not TryRunHelper(cLaunchHelperTestFailArg, '', '', lExitCode) then
  begin
    Writeln('SELFTEST FAILED: launch helper test process could not be created');
    Exit(1);
  end;
  if lExitCode <> cLaunchExitTestFailure then
  begin
    Writeln(Format(
      'SELFTEST FAILED: helper failure exit expected=%d actual=%d',
      [cLaunchExitTestFailure, lExitCode]));
    Exit(1);
  end;
end;

function GetGuidToken: string;
var
  lGuid: TGUID;
begin
  OleCheck(CreateGUID(lGuid));
  Result := GuidToString(lGuid);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

function RunLaunchHelperPathsSelfTest: Integer;
var
  lDir: string;
  lExeFileName: string;
  lExitCode: Cardinal;
  lProbeFileName: string;
  lRootDir: string;
begin
  Result := 0;
  lRootDir := TPath.Combine(
    TPath.GetTempPath,
    'ActiveAppView.selftest.launch.' + GetGuidToken);
  lDir := TPath.Combine(lRootDir, 'Folder');
  lExeFileName := TPath.Combine(lRootDir, 'tool.exe');
  lProbeFileName := TPath.Combine(lRootDir, 'doc.txt');

  ForceDirectories(lDir);
  TFile.WriteAllText(lExeFileName, 'stub', TEncoding.ASCII);
  TFile.WriteAllText(lProbeFileName, 'stub', TEncoding.ASCII);
  try
    if not TryRunHelper(cLaunchHelperProbeArg, lDir, '', lExitCode) then
    begin
      Writeln('SELFTEST FAILED: helper probe could not classify folder path');
      Exit(1);
    end;
    if lExitCode <> cLaunchProbeDirectory then
    begin
      Writeln(Format(
        'SELFTEST FAILED: folder route expected=%d actual=%d',
        [cLaunchProbeDirectory, lExitCode]));
      Exit(1);
    end;

    if not TryRunHelper(cLaunchHelperProbeArg, lExeFileName, '', lExitCode) then
    begin
      Writeln('SELFTEST FAILED: helper probe could not classify executable path');
      Exit(1);
    end;
    if lExitCode <> cLaunchProbeExecutable then
    begin
      Writeln(Format(
        'SELFTEST FAILED: executable route expected=%d actual=%d',
        [cLaunchProbeExecutable, lExitCode]));
      Exit(1);
    end;

    if not TryRunHelper(cLaunchHelperProbeArg, lProbeFileName, '', lExitCode) then
    begin
      Writeln('SELFTEST FAILED: helper probe could not classify shell fallback path');
      Exit(1);
    end;
    if lExitCode <> cLaunchProbeShellFallback then
    begin
      Writeln(Format(
        'SELFTEST FAILED: shell fallback route expected=%d actual=%d',
        [cLaunchProbeShellFallback, lExitCode]));
      Exit(1);
    end;
  finally
    if TFile.Exists(lProbeFileName) then
      TFile.Delete(lProbeFileName);
    if TFile.Exists(lExeFileName) then
      TFile.Delete(lExeFileName);
    if TDirectory.Exists(lRootDir) then
      TDirectory.Delete(lRootDir, True);
  end;
end;

function DetermineLaunchModeForSelfTest(const aPath: string; const aParams: string): TLaunchMode;
var
  lLaunchPath: string;
  lLaunchParams: string;
  lShouldUninitialize: Boolean;
  lWorkingDirectory: string;
begin
  lShouldUninitialize := False;
  case CoInitializeEx(nil, COINIT_APARTMENTTHREADED or COINIT_DISABLE_OLE1DDE) of
    S_OK, S_FALSE:
      lShouldUninitialize := True;
  else
    OleCheck(E_UNEXPECTED);
  end;

  try
    Result := DetermineLaunchMode(aPath, aParams, lLaunchPath, lLaunchParams, lWorkingDirectory);
  finally
    if lShouldUninitialize then
      CoUninitialize;
  end;
end;

procedure CreateShortcutFile(
  const aShortcutPath: string;
  const aTargetPath: string;
  const aArguments: string;
  const aWorkingDirectory: string);
var
  lPersistFile: IPersistFile;
  lShellLink: IShellLinkW;
  lShouldUninitialize: Boolean;
begin
  lShouldUninitialize := False;
  case CoInitializeEx(nil, COINIT_APARTMENTTHREADED or COINIT_DISABLE_OLE1DDE) of
    S_OK, S_FALSE:
      lShouldUninitialize := True;
  else
    OleCheck(E_UNEXPECTED);
  end;

  try
    lShellLink := CreateComObject(CLSID_ShellLink) as IShellLinkW;
    OleCheck(lShellLink.SetPath(PWideChar(WideString(aTargetPath))));
    if aArguments <> '' then
      OleCheck(lShellLink.SetArguments(PWideChar(WideString(aArguments))));
    if aWorkingDirectory <> '' then
      OleCheck(lShellLink.SetWorkingDirectory(PWideChar(WideString(aWorkingDirectory))));
    lPersistFile := lShellLink as IPersistFile;
    OleCheck(lPersistFile.Save(PWideChar(WideString(aShortcutPath)), True));
  finally
    if lShouldUninitialize then
      CoUninitialize;
  end;
end;

function RunLaunchClassificationSelfTest: Integer;
var
  lComSpec: string;
  lDir: string;
  lDocFileName: string;
  lDocShortcutFileName: string;
  lExitCode: Cardinal;
  lExeShortcutFileName: string;
  lLaunchMode: TLaunchMode;
  lMissingFileName: string;
  lRootDir: string;
begin
  Result := 0;
  lComSpec := GetEnvironmentVariable('ComSpec');
  if lComSpec = '' then
  begin
    Writeln('SELFTEST FAILED: ComSpec is empty');
    Exit(1);
  end;

  lRootDir := TPath.Combine(
    TPath.GetTempPath,
    'ActiveAppView.selftest.launch.classification.' + GetGuidToken);
  lDir := TPath.Combine(lRootDir, 'Folder');
  lDocFileName := TPath.Combine(lRootDir, 'doc.txt');
  lDocShortcutFileName := TPath.Combine(lRootDir, 'doc-shortcut.lnk');
  lExeShortcutFileName := TPath.Combine(lRootDir, 'exe-shortcut.lnk');
  lMissingFileName := TPath.Combine(lRootDir, 'missing.exe');

  ForceDirectories(lDir);
  TFile.WriteAllText(lDocFileName, 'stub', TEncoding.ASCII);
  CreateShortcutFile(lExeShortcutFileName, lComSpec, '/c exit 0', ExtractFileDir(lComSpec));
  CreateShortcutFile(lDocShortcutFileName, lDocFileName, '', ExtractFileDir(lDocFileName));
  try
    lLaunchMode := DetermineLaunchModeForSelfTest(lDir, '');
    if lLaunchMode <> TLaunchMode.lmDirectory then
    begin
      Writeln(Format('SELFTEST FAILED: folder classification expected=%s actual=%s', ['directory', 'other']));
      Exit(1);
    end;

    lLaunchMode := DetermineLaunchModeForSelfTest(lComSpec, '');
    if lLaunchMode <> TLaunchMode.lmExecutable then
    begin
      Writeln(Format('SELFTEST FAILED: executable classification expected=%s actual=%s', ['executable', 'other']));
      Exit(1);
    end;

    lLaunchMode := DetermineLaunchModeForSelfTest(lExeShortcutFileName, '');
    if lLaunchMode <> TLaunchMode.lmExecutable then
    begin
      Writeln(Format('SELFTEST FAILED: executable shortcut classification expected=%s actual=%s', ['executable', 'other']));
      Exit(1);
    end;

    lLaunchMode := DetermineLaunchModeForSelfTest(lDocShortcutFileName, '');
    if lLaunchMode <> TLaunchMode.lmShellFallback then
    begin
      Writeln(Format('SELFTEST FAILED: document shortcut classification expected=%s actual=%s', ['shell-fallback', 'other']));
      Exit(1);
    end;

    lLaunchMode := DetermineLaunchModeForSelfTest('\\server\share\tool.exe', '');
    if lLaunchMode <> TLaunchMode.lmShellFallback then
    begin
      Writeln(Format('SELFTEST FAILED: UNC classification expected=%s actual=%s', ['shell-fallback', 'other']));
      Exit(1);
    end;

    lLaunchMode := DetermineLaunchModeForSelfTest(lMissingFileName, '');
    if lLaunchMode <> TLaunchMode.lmMissing then
    begin
      Writeln(Format('SELFTEST FAILED: missing classification expected=%s actual=%s', ['missing', 'other']));
      Exit(1);
    end;

    if not TryLaunchPathIsolated(lComSpec, '/c exit 0', lExitCode) then
    begin
      Writeln('SELFTEST FAILED: launch classification could not execute helper process route');
      Exit(1);
    end;
    if lExitCode <> ERROR_SUCCESS then
    begin
      Writeln(Format('SELFTEST FAILED: helper execute expected=%d actual=%d', [ERROR_SUCCESS, lExitCode]));
      Exit(1);
    end;

    if not TryLaunchPathIsolated(lMissingFileName, '', lExitCode) then
    begin
      Writeln('SELFTEST FAILED: launch classification could not execute helper missing-target route');
      Exit(1);
    end;
    if lExitCode <> cLaunchExitTargetMissing then
    begin
      Writeln(Format('SELFTEST FAILED: helper missing-target expected=%d actual=%d', [cLaunchExitTargetMissing, lExitCode]));
      Exit(1);
    end;
  finally
    if TDirectory.Exists(lRootDir) then
      TDirectory.Delete(lRootDir, True);
  end;
end;

function RunLauncherSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cLaunchClassificationSelfTestArg) then
  begin
    try
      Result := RunLaunchClassificationSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;

  if SameText(aArg, cLaunchHelperCrashIsolatedSelfTestArg) then
  begin
    try
      Result := RunLaunchHelperCrashIsolatedSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;

  if SameText(aArg, cLaunchHelperPathsSelfTestArg) then
  begin
    try
      Result := RunLaunchHelperPathsSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end;
end;

end.

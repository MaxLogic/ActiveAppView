unit ActiveAppView.SelfTests;

interface

function RunSelfTests: Integer;

implementation

uses
  System.Classes, System.Diagnostics, System.IniFiles, System.IOUtils, System.SyncObjs, System.SysUtils,
  Winapi.Messages, Winapi.Windows,
  ActiveAppView.CaptionOverrideState.SelfTests, ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache,
  ActiveAppView.FocusSound, ActiveAppView.MachineOverview.SelfTests, ActiveAppViewCore, ActiveAppView.Launcher,
  ActiveAppView.RenameJournal.SelfTests,
  ActiveAppViewMainForm, maxLogic.Windows.Desktop;

const
  cConfigCacheParseBenchmarkSelfTestArg = '--self-test-config-cache-parse-benchmark';
  cConfigCacheRuleSpacingSelfTestArg = '--self-test-config-cache-rule-spacing';
  cInvalidWndMetadataSelfTestArg = '--self-test-chat-monitor-invalid-wnd';
  cWindowEnumerationSelfTestArg = '--self-test-window-enumeration';
  cWindowRestoreCommandSelfTestArg = '--self-test-window-restore-command';

// ShowWindow cannot restore a window of an elevated process while we run non-elevated, and a test
// cannot create an elevated window. So we prove the fallback alone restores a real minimized window
// that lives on another thread, the way a foreign window does.
function RunWindowRestoreCommandSelfTest: Integer;
var
  lReady: TEvent;
  lThread: TThread;
  lWnd: HWND;
begin
  Result := 0;
  lWnd := 0;
  lReady := TEvent.Create(nil, True, False, '');
  try
    lThread := TThread.CreateAnonymousThread(
      procedure
      var
        lMsg: TMsg;
      begin
        lWnd := CreateWindowEx(WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE, 'STATIC', 'RestoreCommandSelfTest',
          WS_POPUP or WS_MINIMIZE, 0, 0, 1, 1, 0, 0, HInstance, nil);
        lReady.SetEvent;
        if lWnd = 0 then
          Exit;
        try
          while GetMessage(lMsg, 0, 0, 0) do
          begin
            TranslateMessage(lMsg);
            DispatchMessage(lMsg);
          end;
        finally
          DestroyWindow(lWnd);
        end;
      end);
    lThread.FreeOnTerminate := False;
    lThread.Start;
    try
      if (lReady.WaitFor(5000) <> wrSignaled) or (lWnd = 0) then
      begin
        Writeln('SELFTEST FAILED: restore-command host window was not created');
        Exit(1);
      end;
      try
        if not IsIconic(lWnd) then
        begin
          Writeln('SELFTEST FAILED: restore-command host window did not start minimized');
          Exit(1);
        end;

        if not maxLogic.Windows.Desktop.RestoreMinimizedWindowByCommand(lWnd, 2000) then
        begin
          Writeln('SELFTEST FAILED: restore command did not report a restored window');
          Exit(1);
        end;
        if IsIconic(lWnd) then
        begin
          Writeln('SELFTEST FAILED: window is still minimized after the restore command');
          Exit(1);
        end;
      finally
        PostThreadMessage(lThread.ThreadID, WM_QUIT, 0, 0);
      end;
    finally
      lThread.WaitFor;
      lThread.Free;
    end;

    if maxLogic.Windows.Desktop.RestoreMinimizedWindowByCommand(lWnd, 100) then
    begin
      Writeln('SELFTEST FAILED: restore command reported success for a destroyed window');
      Exit(1);
    end;
  finally
    lReady.Free;
  end;
end;

function RunWindowEnumerationSelfTest: Integer;
var
  lWindows: maxLogic.Windows.Desktop.TWndList;
begin
  Result := 0;
  lWindows := maxLogic.Windows.Desktop.TWndList.Create;
  try
    maxLogic.Windows.Desktop.GetWndList(lWindows);
  finally
    lWindows.Free;
  end;
end;

function RunInvalidWndMetadataSelfTest: Integer;
var
  lApps: TArray<TChatAppSnapshot>;
  lIniFile: TMemIniFile;
  lMaskFileName: string;
  lMonitor: TChatMonitor;
  lSettingsFileName: string;
begin
  Result := 0;

  lMaskFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.review-mask.txt');
  lSettingsFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.settings.ini');

  TFile.WriteAllText(lMaskFileName, 'filename=*', TEncoding.UTF8);

  lIniFile := TMemIniFile.Create(lSettingsFileName, TEncoding.UTF8, False);
  try
    lIniFile.WriteBool('ChatMonitor', 'Enabled', True);
    lIniFile.WriteBool('ChatMonitor', 'SoundEnabled', False);
    lIniFile.WriteString('ChatMonitor', 'ReviewMaskFile', lMaskFileName);
    lIniFile.UpdateFile;

    lMonitor := TChatMonitor.Create(lIniFile);
    try
      SetLength(lApps, 1);
      lApps[0].Wnd := HWND(1);
      lApps[0].Caption := 'self-test';
      lMonitor.ProcessSnapshot(lApps);
    finally
      lMonitor.Free;
    end;
  finally
    lIniFile.Free;
    TFile.Delete(lMaskFileName);
    TFile.Delete(lSettingsFileName);
  end;
end;

function RunConfigCacheRuleSpacingSelfTest: Integer;
var
  lConfigCache: TConfigCache;
  lPrefixFileName: string;
  lPrefixRules: TPrefixRuleArray;
  lReviewFileName: string;
  lReviewRules: TReviewRuleArray;
begin
  Result := 0;
  lPrefixFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.prefix-spacing.txt');
  lReviewFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.review-spacing.txt');

  TFile.WriteAllText(
    lPrefixFileName,
    'prefix=TERM, filename=*cmd.exe, AppUserModelID=*edge*, CmdParams=*--profile*',
    TEncoding.UTF8);
  TFile.WriteAllText(
    lReviewFileName,
    'caption=*Teams*, filename=*msedge.exe, excludefilename=*notepad.exe, excludecmdparams=*--mute*',
    TEncoding.UTF8);

  lConfigCache := TConfigCache.Create(TPath.GetTempPath);
  try
    lPrefixRules := lConfigCache.GetPrefixRules(lPrefixFileName);
    if Length(lPrefixRules) <> 1 then
    begin
      Writeln(Format('SELFTEST FAILED: prefix spacing expected 1 rule, got %d', [Length(lPrefixRules)]));
      Exit(1);
    end;
    if not SameText(lPrefixRules[0].FileNameMask, '*cmd.exe') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: prefix spacing filename expected "%s", got "%s"',
        ['*cmd.exe', lPrefixRules[0].FileNameMask]));
      Exit(1);
    end;
    if not SameText(lPrefixRules[0].AppUserModelIDMask, '*edge*') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: prefix spacing appUserModelId expected "%s", got "%s"',
        ['*edge*', lPrefixRules[0].AppUserModelIDMask]));
      Exit(1);
    end;
    if not SameText(lPrefixRules[0].CmdParamsMask, '*--profile*') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: prefix spacing cmdParams expected "%s", got "%s"',
        ['*--profile*', lPrefixRules[0].CmdParamsMask]));
      Exit(1);
    end;

    lReviewRules := lConfigCache.GetReviewRules(lReviewFileName);
    if Length(lReviewRules) <> 1 then
    begin
      Writeln(Format('SELFTEST FAILED: review spacing expected 1 rule, got %d', [Length(lReviewRules)]));
      Exit(1);
    end;
    if not SameText(lReviewRules[0].FileNameMask, '*msedge.exe') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: review spacing filename expected "%s", got "%s"',
        ['*msedge.exe', lReviewRules[0].FileNameMask]));
      Exit(1);
    end;
    if not SameText(lReviewRules[0].ExcludeFileNameMask, '*notepad.exe') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: review spacing excludeFilename expected "%s", got "%s"',
        ['*notepad.exe', lReviewRules[0].ExcludeFileNameMask]));
      Exit(1);
    end;
    if not SameText(lReviewRules[0].ExcludeCmdParamsMask, '*--mute*') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: review spacing excludeCmdParams expected "%s", got "%s"',
        ['*--mute*', lReviewRules[0].ExcludeCmdParamsMask]));
      Exit(1);
    end;
  finally
    lConfigCache.Free;
    TFile.Delete(lPrefixFileName);
    TFile.Delete(lReviewFileName);
  end;
end;

function RunConfigCacheParseBenchmarkSelfTest: Integer;
const
  cBenchmarkIterations = 5;
  cBenchmarkRuleCount = 5000;
var
  lCache: TConfigCache;
  lElapsedMs: Int64;
  lExpectedCount: Integer;
  lIndex: Integer;
  lIteration: Integer;
  lLineBreak: string;
  lPrefixBuilder: TStringBuilder;
  lPrefixFileName: string;
  lPrefixRules: TPrefixRuleArray;
  lReviewBuilder: TStringBuilder;
  lReviewFileName: string;
  lReviewRules: TReviewRuleArray;
  lShortCutBuilder: TStringBuilder;
  lShortCutFileName: string;
  lShortCuts: TNamedValueArray;
  lWatch: TStopwatch;
begin
  Result := 0;
  lExpectedCount := cBenchmarkRuleCount;
  lLineBreak := sLineBreak;
  lPrefixFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.bench.prefix.txt');
  lReviewFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.bench.review.txt');
  lShortCutFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.bench.shortcuts.txt');

  lPrefixBuilder := TStringBuilder.Create;
  lReviewBuilder := TStringBuilder.Create;
  lShortCutBuilder := TStringBuilder.Create;
  try
    for lIndex := 1 to cBenchmarkRuleCount do
    begin
      lPrefixBuilder.Append('prefix=P');
      lPrefixBuilder.Append(lIndex);
      lPrefixBuilder.Append(', caption=*Chat');
      lPrefixBuilder.Append(lIndex);
      lPrefixBuilder.Append('*');
      lPrefixBuilder.Append(', filename=*tool');
      lPrefixBuilder.Append(lIndex);
      lPrefixBuilder.Append('.exe');
      lPrefixBuilder.Append(', AppUserModelID=*pwa');
      lPrefixBuilder.Append(lIndex);
      lPrefixBuilder.Append('*');
      lPrefixBuilder.Append(', CmdParams=*--profile-');
      lPrefixBuilder.Append(lIndex);
      lPrefixBuilder.Append('*');
      lPrefixBuilder.Append(lLineBreak);

      lReviewBuilder.Append('caption=*Teams');
      lReviewBuilder.Append(lIndex);
      lReviewBuilder.Append('*');
      lReviewBuilder.Append(', filename=*msedge');
      lReviewBuilder.Append(lIndex);
      lReviewBuilder.Append('.exe');
      lReviewBuilder.Append(', excludecmdparams=*--mute-');
      lReviewBuilder.Append(lIndex);
      lReviewBuilder.Append('*');
      lReviewBuilder.Append(lLineBreak);

      lShortCutBuilder.Append('shortcut');
      lShortCutBuilder.Append(lIndex);
      lShortCutBuilder.Append('=');
      lShortCutBuilder.Append('"C:\Tools\tool');
      lShortCutBuilder.Append(lIndex);
      lShortCutBuilder.Append('.exe" --arg ');
      lShortCutBuilder.Append(lIndex);
      lShortCutBuilder.Append(lLineBreak);
    end;

    TFile.WriteAllText(lPrefixFileName, lPrefixBuilder.ToString, TEncoding.UTF8);
    TFile.WriteAllText(lReviewFileName, lReviewBuilder.ToString, TEncoding.UTF8);
    TFile.WriteAllText(lShortCutFileName, lShortCutBuilder.ToString, TEncoding.UTF8);

    lWatch := TStopwatch.StartNew;
    for lIteration := 1 to cBenchmarkIterations do
    begin
      lCache := TConfigCache.Create(TPath.GetTempPath);
      try
        lPrefixRules := lCache.GetPrefixRules(lPrefixFileName);
        lReviewRules := lCache.GetReviewRules(lReviewFileName);
        lShortCuts := lCache.GetShortCuts(lShortCutFileName);
      finally
        lCache.Free;
      end;

      if Length(lPrefixRules) <> lExpectedCount then
      begin
        Writeln(Format(
          'SELFTEST FAILED: benchmark prefix expected=%d actual=%d',
          [lExpectedCount, Length(lPrefixRules)]));
        Exit(1);
      end;
      if Length(lReviewRules) <> lExpectedCount then
      begin
        Writeln(Format(
          'SELFTEST FAILED: benchmark review expected=%d actual=%d',
          [lExpectedCount, Length(lReviewRules)]));
        Exit(1);
      end;
      if Length(lShortCuts) <> lExpectedCount then
      begin
        Writeln(Format(
          'SELFTEST FAILED: benchmark shortcuts expected=%d actual=%d',
          [lExpectedCount, Length(lShortCuts)]));
        Exit(1);
      end;
    end;
    lElapsedMs := lWatch.ElapsedMilliseconds;
    Writeln(Format(
      'SELFTEST BENCHMARK: config-cache-parse rules=%d iterations=%d elapsedMs=%d',
      [lExpectedCount, cBenchmarkIterations, lElapsedMs]));
  finally
    lPrefixBuilder.Free;
    lReviewBuilder.Free;
    lShortCutBuilder.Free;
    TFile.Delete(lPrefixFileName);
    TFile.Delete(lReviewFileName);
    TFile.Delete(lShortCutFileName);
  end;
end;

function RunSelfTests: Integer;
begin
  Result := RunMachineOverviewSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunCaptionOverrideStateSelfTests(ParamStr(1));
  if Result <> -1 then
  begin
    if Result = 0 then
      Result := RunMainFormSelfTests(ParamStr(1));
    Exit;
  end;

  Result := RunCoreSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunLauncherSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunFocusSoundSelfTests(ParamStr(1));
  if Result <> -1 then
  begin
    if Result = 0 then
      Result := RunMainFormSelfTests(ParamStr(1));
    Exit;
  end;

  Result := RunMainFormSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunChatMonitorSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunRenameJournalSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := -1;
  if SameText(ParamStr(1), cConfigCacheParseBenchmarkSelfTestArg) then
  begin
    try
      Result := RunConfigCacheParseBenchmarkSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end else if SameText(ParamStr(1), cConfigCacheRuleSpacingSelfTestArg) then
  begin
    try
      Result := RunConfigCacheRuleSpacingSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end else if SameText(ParamStr(1), cInvalidWndMetadataSelfTestArg) then
  begin
    try
      Result := RunInvalidWndMetadataSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end else if SameText(ParamStr(1), cWindowEnumerationSelfTestArg) then
  begin
    try
      Result := RunWindowEnumerationSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end else if SameText(ParamStr(1), cWindowRestoreCommandSelfTestArg) then
  begin
    try
      Result := RunWindowRestoreCommandSelfTest;
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

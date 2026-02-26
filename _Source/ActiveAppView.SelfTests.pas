unit ActiveAppView.SelfTests;

interface

function RunSelfTests: Integer;

implementation

uses
  System.Classes, System.Diagnostics, System.IniFiles, System.IOUtils, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache, ActiveAppViewCore,
  ActiveAppViewMainForm;

const
  cConfigCacheParseBenchmarkSelfTestArg = '--self-test-config-cache-parse-benchmark';
  cConfigCacheRuleSpacingSelfTestArg = '--self-test-config-cache-rule-spacing';
  cInvalidWndMetadataSelfTestArg = '--self-test-chat-monitor-invalid-wnd';

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
  Result := RunCoreSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunMainFormSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunChatMonitorSelfTests(ParamStr(1));
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
  end;
end;

end.

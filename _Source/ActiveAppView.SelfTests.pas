unit ActiveAppView.SelfTests;

interface

function RunSelfTests: Integer;

implementation

uses
  System.Classes, System.IniFiles, System.IOUtils, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache, ActiveAppViewMainForm;

const
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

function RunSelfTests: Integer;
begin
  Result := RunMainFormSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := RunChatMonitorSelfTests(ParamStr(1));
  if Result <> -1 then
    Exit;

  Result := -1;
  if SameText(ParamStr(1), cConfigCacheRuleSpacingSelfTestArg) then
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

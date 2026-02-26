unit ActiveAppView.ChatMonitor;

interface

uses
  Winapi.Windows, System.Classes, System.Generics.Collections, System.IniFiles, System.SysUtils,
  MaxLogic.Cache,
  ActiveAppView.ConfigCache;

function RunChatMonitorSelfTests(const aArg: string): Integer;

type
  TChatAppSnapshot = record
    Wnd: hWnd;
    Caption: string;
  end;

  IChatAppMetadata = interface(IInterface)
    ['{AC67D233-026B-49A9-9828-6508E7C478E1}']
    function GetAppUserModelID: string;
    function GetCommandLineParams: string;
    function GetFileName: string;
    property AppUserModelID: string read GetAppUserModelID;
    property CommandLineParams: string read GetCommandLineParams;
    property FileName: string read GetFileName;
  end;

  TChatMonitor = class
  private
    type
      TMonitoredAppState = record
        HasUnreadMessages: Boolean;
        IsPwa: Boolean;
        LastSoundPlayed: TDateTime;
      end;
  private
    fConfigCache: TConfigCache;
    fEnabled: Boolean;
    fMetadataCache: IMaxCache;
    fMonitoredApps: TDictionary<hWnd, TMonitoredAppState>;
    fOwnConfigCache: Boolean;
    fPwaClosedSound: string;
    fReviewMaskFileName: string;
    fSoundEnabled: Boolean;
    fSoundThrottling: TDictionary<string, TDateTime>;
    fUnreadMessageSound: string;
    fUnreadMessageSoundInterval: Integer;

    class function AnyRuleNeedsMetadata(const aRules: TReviewRuleArray): Boolean; static;
    class function HasUnreadMessageCountInCaption(const aCaption: string): Boolean; static;
    class function IsUnreadCounterPaddingChar(aChar: Char): Boolean; static;
    class function IsUnreadCounterStartChar(aChar: Char): Boolean; static;
    class function IsUnreadCounterTerminatorChar(aChar: Char): Boolean; static;
    class function ParseCommandLineParams(const aCommandLine: string): string; static;
    function GetMetadataCached(const aWnd: hWnd): IChatAppMetadata;
    procedure LoadConfiguration(aIni: TMemIniFile);
    function MatchesReviewRule(
      const aAppCaption: string;
      const aMetadata: IChatAppMetadata;
      const aRule: TReviewRule): Boolean;
    function MatchesReviewExcludeRule(
      const aAppCaption: string;
      const aMetadata: IChatAppMetadata;
      const aRule: TReviewRule): Boolean;
    procedure PlaySoundFile(const aFileName: string);
    function PrefetchMetadataInParallel(
      const aApps: TArray<TChatAppSnapshot>): TArray<IChatAppMetadata>;
    procedure SetSoundEnabled(const aValue: Boolean);
    function ShouldReviewApp(
      const aAppCaption: string;
      const aMetadata: IChatAppMetadata;
      const aRules: TReviewRuleArray): Boolean;
  public
    constructor Create(aSettings: TMemIniFile);
    destructor Destroy; override;

    procedure Process;
    procedure ProcessSnapshot(const aApps: TArray<TChatAppSnapshot>);
    procedure UseConfigCache(aConfigCache: TConfigCache);
    property SoundEnabled: Boolean read fSoundEnabled write SetSoundEnabled;
  end;

implementation

uses
  System.DateUtils, System.IOUtils, System.StrUtils, System.Threading,
  Winapi.MMSystem,
  maxLogic.StrUtils, srDesktop,
  ActiveAppViewCore;

type
  TChatAppMetadata = class(TInterfacedObject, IChatAppMetadata)
  private
    fAppUserModelID: string;
    fCommandLineParams: string;
    fFileName: string;
  public
    constructor Create(
      const aFileName: string;
      const aAppUserModelID: string;
      const aCommandLineParams: string);
    function GetAppUserModelID: string;
    function GetCommandLineParams: string;
    function GetFileName: string;
  end;

const
  cMetadataCacheNamespace = 'activeappview.chat-monitor.metadata';
  cSoundFallbackSelfTestArg = '--self-test-chat-monitor-sound-fallback';
  cUnreadCaptionSelfTestArg = '--self-test-chat-monitor-unread-caption';

type
  TPlaySoundProc = function(aSoundName: PChar; aModule: HMODULE; aFlags: DWORD): BOOL; stdcall;
  TMessageBeepProc = function(aType: UINT): BOOL; stdcall;

var
  gPlaySoundProc: TPlaySoundProc = Winapi.MMSystem.PlaySound;
  gMessageBeepProc: TMessageBeepProc = Winapi.Windows.MessageBeep;
  gSelfTestMessageBeepCount: Integer = 0;

function SelfTestMessageBeep(aType: UINT): BOOL; stdcall;
begin
  Inc(gSelfTestMessageBeepCount);
  Result := True;
end;

function BoolToText(aValue: Boolean): string;
begin
  if aValue then
    Result := 'true'
  else
    Result := 'false';
end;

function CheckUnreadCaptionCase(const aCaseName: string; const aCaption: string;
  aExpected: Boolean): string;
var
  lActual: Boolean;
begin
  lActual := TChatMonitor.HasUnreadMessageCountInCaption(aCaption);
  if lActual = aExpected then
    Exit('');

  Result := Format('SELFTEST FAILED: %s expected=%s actual=%s caption="%s"',
    [aCaseName, BoolToText(aExpected), BoolToText(lActual), aCaption]);
end;

function RunUnreadCaptionSelfTest: Integer;
var
  lFailure: string;
begin
  Result := 0;

  lFailure := CheckUnreadCaptionCase('classic-parentheses', 'Teams (1)', True);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;

  lFailure := CheckUnreadCaptionCase('broken-closing-parenthesis', 'Teams (1(', False);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;

  lFailure := CheckUnreadCaptionCase('bidi-marks-padding',
    'Teams (' + #$200E + '12' + #$200F + ')', True);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;

  lFailure := CheckUnreadCaptionCase('fullwidth-parentheses',
    'Teams ' + #$FF08 + '3' + #$FF09, True);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;

  lFailure := CheckUnreadCaptionCase('empty-parentheses', 'Teams ()', False);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;

  lFailure := CheckUnreadCaptionCase('non-digit-content', 'Teams (abc)', False);
  if lFailure <> '' then
  begin
    Writeln(lFailure);
    Exit(1);
  end;
end;

function RunSoundFallbackSelfTest: Integer;
var
  lIniFile: TMemIniFile;
  lMissingSoundFileName: string;
  lMonitor: TChatMonitor;
  lOriginalMessageBeepProc: TMessageBeepProc;
  lSettingsFileName: string;
begin
  Result := 0;
  lMissingSoundFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.missing.wav');
  lSettingsFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.sound.ini');
  if TFile.Exists(lMissingSoundFileName) then
    TFile.Delete(lMissingSoundFileName);

  lIniFile := TMemIniFile.Create(lSettingsFileName, TEncoding.UTF8, False);
  try
    lIniFile.WriteBool('ChatMonitor', 'Enabled', True);
    lIniFile.WriteBool('ChatMonitor', 'SoundEnabled', True);
    lIniFile.UpdateFile;

    lMonitor := TChatMonitor.Create(lIniFile);
    try
      lOriginalMessageBeepProc := gMessageBeepProc;
      gSelfTestMessageBeepCount := 0;
      gMessageBeepProc := SelfTestMessageBeep;
      try
        lMonitor.PlaySoundFile(lMissingSoundFileName);
      finally
        gMessageBeepProc := lOriginalMessageBeepProc;
      end;
    finally
      lMonitor.Free;
    end;
  finally
    lIniFile.Free;
    if TFile.Exists(lSettingsFileName) then
      TFile.Delete(lSettingsFileName);
  end;

  if gSelfTestMessageBeepCount <> 1 then
  begin
    Writeln(Format('SELFTEST FAILED: fallback beep expected=1 actual=%d', [gSelfTestMessageBeepCount]));
    Result := 1;
  end;
end;

function RunChatMonitorSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cUnreadCaptionSelfTestArg) then
  begin
    try
      Result := RunUnreadCaptionSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end else if SameText(aArg, cSoundFallbackSelfTestArg) then
  begin
    try
      Result := RunSoundFallbackSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end;
end;

{ TChatAppMetadata }

constructor TChatAppMetadata.Create(
  const aFileName: string;
  const aAppUserModelID: string;
  const aCommandLineParams: string);
begin
  inherited Create;
  fFileName := aFileName;
  fAppUserModelID := aAppUserModelID;
  fCommandLineParams := aCommandLineParams;
end;

function TChatAppMetadata.GetAppUserModelID: string;
begin
  Result := fAppUserModelID;
end;

function TChatAppMetadata.GetCommandLineParams: string;
begin
  Result := fCommandLineParams;
end;

function TChatAppMetadata.GetFileName: string;
begin
  Result := fFileName;
end;

{ TChatMonitor }

class function TChatMonitor.AnyRuleNeedsMetadata(const aRules: TReviewRuleArray): Boolean;
var
  lRule: TReviewRule;
begin
  for lRule in aRules do
    if (lRule.FileNameMask <> '') or (lRule.AppUserModelIDMask <> '') or (lRule.CmdParamsMask <> '')
      or (lRule.ExcludeFileNameMask <> '') or (lRule.ExcludeAppUserModelIDMask <> '') or (lRule.ExcludeCmdParamsMask <> '') then
      Exit(True);

  Result := False;
end;

constructor TChatMonitor.Create(aSettings: TMemIniFile);
var
  lCacheConfig: TMaxCacheConfig;
begin
  inherited Create;
  fMonitoredApps := TDictionary<hWnd, TMonitoredAppState>.Create;
  fSoundThrottling := TDictionary<string, TDateTime>.Create;
  fOwnConfigCache := True;
  fConfigCache := TConfigCache.Create(ExtractFilePath(ParamStr(0)));

  lCacheConfig := TMaxCacheConfig.Default;
  lCacheConfig.CaseSensitiveKeys := False;
  lCacheConfig.SweepIntervalMs := 0;
  fMetadataCache := TMaxCache.New(lCacheConfig);

  LoadConfiguration(aSettings);
end;

destructor TChatMonitor.Destroy;
begin
  fSoundThrottling.Free;
  fMonitoredApps.Free;
  if fOwnConfigCache and Assigned(fConfigCache) then
    fConfigCache.Free;
  inherited;
end;

function TChatMonitor.GetMetadataCached(const aWnd: hWnd): IChatAppMetadata;
var
  lCacheValue: IInterface;
  lMetadata: IChatAppMetadata;
  lOptions: TMaxCacheOptions;
  lPid: Cardinal;
  lWndKey: string;
begin
  lWndKey := IntToHex(NativeInt(aWnd), SizeOf(NativeInt) * 2);
  lOptions := TMaxCacheOptions.Create;
  try
    lOptions.TtlMs := 15000;
    lOptions.ValidateIntervalMs := 2500;
    try
      lCacheValue := fMetadataCache.GetOrCreate(
        cMetadataCacheNamespace,
        lWndKey,
        function: IInterface
        var
          lAppUserModelID: string;
          lCommandLine: string;
          lCommandLineParams: string;
          lFileName: string;
        begin
          lFileName := '';
          lAppUserModelID := '';
          lCommandLine := '';
          lCommandLineParams := '';

          try
            lFileName := srDesktop.GetFileName(aWnd);
          except
            lFileName := '';
          end;

          try
            lAppUserModelID := RetrieveAppUserModelID(aWnd);
          except
            lAppUserModelID := '';
          end;

          try
            lPid := RetrievePID(aWnd);
            if lPid = 0 then
              lCommandLine := ''
            else
              lCommandLine := RetrieveCommandLine(lPid);
          except
            lCommandLine := '';
          end;

          lCommandLineParams := ParseCommandLineParams(lCommandLine);
          Result := TChatAppMetadata.Create(lFileName, lAppUserModelID, lCommandLineParams);
        end,
        lOptions);
    except
      lCacheValue := nil;
    end;
  finally
    lOptions.Free;
  end;

  if Supports(lCacheValue, IChatAppMetadata, lMetadata) then
    Result := lMetadata
  else
    Result := nil;
end;

class function TChatMonitor.HasUnreadMessageCountInCaption(const aCaption: string): Boolean;
var
  lDigitCount: Integer;
  lIndex: Integer;
  lLen: Integer;
  lScanIndex: Integer;
begin
  Result := False;
  lLen := Length(aCaption);
  if lLen < 2 then
    Exit;

  for lIndex := 1 to lLen do
  begin
    if IsUnreadCounterStartChar(aCaption[lIndex]) then
    begin
      lScanIndex := lIndex + 1;
      while (lScanIndex <= lLen) and IsUnreadCounterPaddingChar(aCaption[lScanIndex]) do
        Inc(lScanIndex);

      lDigitCount := 0;
      while (lScanIndex <= lLen) and CharInSet(aCaption[lScanIndex], ['0'..'9']) do
      begin
        Inc(lDigitCount);
        Inc(lScanIndex);
      end;

      if lDigitCount > 0 then
      begin
        while (lScanIndex <= lLen) and IsUnreadCounterPaddingChar(aCaption[lScanIndex]) do
          Inc(lScanIndex);
        if (lScanIndex <= lLen) and IsUnreadCounterTerminatorChar(aCaption[lScanIndex]) then
          Exit(True);
      end;
    end;
  end;
end;

class function TChatMonitor.IsUnreadCounterPaddingChar(aChar: Char): Boolean;
begin
  case aChar of
    #9, #10, #13, ' ':
      Exit(True);
  end;

  Result := (aChar = #$200B) or (aChar = #$200C) or (aChar = #$200D)
    or (aChar = #$200E) or (aChar = #$200F)
    or (aChar = #$202A) or (aChar = #$202B) or (aChar = #$202C)
    or (aChar = #$202D) or (aChar = #$202E)
    or (aChar = #$2066) or (aChar = #$2067) or (aChar = #$2068) or (aChar = #$2069)
    or (aChar = #$FEFF);
end;

class function TChatMonitor.IsUnreadCounterStartChar(aChar: Char): Boolean;
begin
  Result := (aChar = '(') or (aChar = #$FF08);
end;

class function TChatMonitor.IsUnreadCounterTerminatorChar(aChar: Char): Boolean;
begin
  Result := (aChar = ')') or (aChar = #$FF09);
end;

procedure TChatMonitor.LoadConfiguration(aIni: TMemIniFile);
begin
  fEnabled := aIni.ReadBool('ChatMonitor', 'Enabled', False);
  fSoundEnabled := aIni.ReadBool('ChatMonitor', 'SoundEnabled', True);
  if not fEnabled then
    Exit;

  fUnreadMessageSound := aIni.ReadString('ChatMonitor', 'UnreadMessageSound', '');
  fUnreadMessageSoundInterval := aIni.ReadInteger('ChatMonitor', 'UnreadMessageSoundIntervalSeconds', 30);
  fPwaClosedSound := aIni.ReadString('ChatMonitor', 'PwaClosedSound', '');
  fReviewMaskFileName := aIni.ReadString('ChatMonitor', 'ReviewMaskFile', 'ChatReviewMask.txt');
end;

function TChatMonitor.MatchesReviewRule(
  const aAppCaption: string;
  const aMetadata: IChatAppMetadata;
  const aRule: TReviewRule): Boolean;
begin
  Result := ((aRule.CaptionMask <> '') and StringMatches(aAppCaption, aRule.CaptionMask, False));
  if Result then
    Exit(True);

  if not Assigned(aMetadata) then
    Exit(False);

  Result := ((aRule.FileNameMask <> '') and StringMatches(aMetadata.FileName, aRule.FileNameMask, False))
    or ((aRule.AppUserModelIDMask <> '') and StringMatches(aMetadata.AppUserModelID, aRule.AppUserModelIDMask, False))
    or ((aRule.CmdParamsMask <> '') and StringMatches(aMetadata.CommandLineParams, aRule.CmdParamsMask, False));
end;

function TChatMonitor.MatchesReviewExcludeRule(
  const aAppCaption: string;
  const aMetadata: IChatAppMetadata;
  const aRule: TReviewRule): Boolean;
begin
  Result := ((aRule.ExcludeCaptionMask <> '') and StringMatches(aAppCaption, aRule.ExcludeCaptionMask, False));
  if Result then
    Exit(True);

  if not Assigned(aMetadata) then
    Exit(False);

  Result := ((aRule.ExcludeFileNameMask <> '') and StringMatches(aMetadata.FileName, aRule.ExcludeFileNameMask, False))
    or ((aRule.ExcludeAppUserModelIDMask <> '') and StringMatches(aMetadata.AppUserModelID, aRule.ExcludeAppUserModelIDMask, False))
    or ((aRule.ExcludeCmdParamsMask <> '') and StringMatches(aMetadata.CommandLineParams, aRule.ExcludeCmdParamsMask, False));
end;

class function TChatMonitor.ParseCommandLineParams(const aCommandLine: string): string;
var
  lCommandLine: string;
  lSplitIndex: Integer;
begin
  lCommandLine := Trim(aCommandLine);
  if lCommandLine = '' then
    Exit('');

  if StartsText('"', lCommandLine) then
    lSplitIndex := PosEx('"', lCommandLine, 2)
  else
    lSplitIndex := PosEx(' ', lCommandLine, 1);

  if lSplitIndex <= 0 then
    Exit('');

  Result := Trim(Copy(lCommandLine, lSplitIndex + 1, MaxInt));
end;

procedure TChatMonitor.PlaySoundFile(const aFileName: string);
var
  lHasSoundFile: Boolean;
  lFullPath: string;
  lKey: string;
  lLastPlayedTime: TDateTime;
  lPlayStarted: BOOL;
begin
  if not fSoundEnabled then
    Exit;

  if aFileName = '' then
    Exit;

  lFullPath := aFileName;
  if TPath.IsRelativePath(lFullPath) then
    lFullPath := TPath.Combine(ExtractFilePath(ParamStr(0)), aFileName);

  lKey := lFullPath.ToLower;
  if fSoundThrottling.TryGetValue(lKey, lLastPlayedTime) then
    if SecondsBetween(Now, lLastPlayedTime) < 5 then
      Exit;
  fSoundThrottling.AddOrSetValue(lKey, Now);

  lHasSoundFile := TFile.Exists(lFullPath);
  lPlayStarted := False;
  if lHasSoundFile then
    lPlayStarted := gPlaySoundProc(PChar(lFullPath), 0, SND_FILENAME or SND_ASYNC);

  if (not lHasSoundFile) or (not lPlayStarted) then
    gMessageBeepProc(MB_ICONASTERISK);
end;

function TChatMonitor.PrefetchMetadataInParallel(
  const aApps: TArray<TChatAppSnapshot>): TArray<IChatAppMetadata>;
var
  lMetadata: TArray<IChatAppMetadata>;
begin
  SetLength(lMetadata, Length(aApps));
  if Length(aApps) = 0 then
    Exit(lMetadata);

  TParallel.&For(0, High(aApps),
    procedure(aIndex: Integer)
    begin
      lMetadata[aIndex] := GetMetadataCached(aApps[aIndex].Wnd);
    end);
  Result := lMetadata;
end;

procedure TChatMonitor.Process;
var
  lAppList: TAppList;
  lApps: TArray<TChatAppSnapshot>;
  lIndex: Integer;
begin
  if not fEnabled then
    Exit;

  lAppList := TAppList.Create;
  try
    lAppList.Update;
    SetLength(lApps, lAppList.Count);
    for lIndex := 0 to lAppList.Count - 1 do
    begin
      lApps[lIndex].Wnd := lAppList[lIndex].Wnd;
      lApps[lIndex].Caption := lAppList[lIndex].Caption;
    end;
  finally
    lAppList.Free;
  end;

  ProcessSnapshot(lApps);
end;

procedure TChatMonitor.ProcessSnapshot(const aApps: TArray<TChatAppSnapshot>);
var
  lFoundApps: TDictionary<hWnd, TMonitoredAppState>;
  lIndex: Integer;
  lMetadata: TArray<IChatAppMetadata>;
  lNewState: TMonitoredAppState;
  lOldState: TMonitoredAppState;
  lRequiresMetadata: Boolean;
  lReviewRules: TReviewRuleArray;
  lWnd: hWnd;
begin
  if not fEnabled then
    Exit;

  lReviewRules := fConfigCache.GetReviewRules(fReviewMaskFileName);
  lRequiresMetadata := AnyRuleNeedsMetadata(lReviewRules);
  SetLength(lMetadata, 0);
  if lRequiresMetadata then
    lMetadata := PrefetchMetadataInParallel(aApps);

  lFoundApps := TDictionary<hWnd, TMonitoredAppState>.Create;
  try
    for lIndex := 0 to High(aApps) do
    begin
      if lRequiresMetadata and (Length(lMetadata) > lIndex) then
      begin
        if not ShouldReviewApp(aApps[lIndex].Caption, lMetadata[lIndex], lReviewRules) then
          Continue;
      end else begin
        if not ShouldReviewApp(aApps[lIndex].Caption, nil, lReviewRules) then
          Continue;
      end;

      lNewState.HasUnreadMessages := HasUnreadMessageCountInCaption(aApps[lIndex].Caption);
      lNewState.IsPwa := lRequiresMetadata and (Length(lMetadata) > lIndex)
        and Assigned(lMetadata[lIndex])
        and SameText(ExtractFileName(lMetadata[lIndex].FileName), 'msedge.exe');

      if fMonitoredApps.TryGetValue(aApps[lIndex].Wnd, lOldState) then
        lNewState.LastSoundPlayed := lOldState.LastSoundPlayed
      else
        lNewState.LastSoundPlayed := 0;

      lFoundApps.AddOrSetValue(aApps[lIndex].Wnd, lNewState);
    end;

    for lWnd in fMonitoredApps.Keys do
      if not lFoundApps.ContainsKey(lWnd) then
        if fMonitoredApps[lWnd].IsPwa then
          PlaySoundFile(fPwaClosedSound);

    for lWnd in lFoundApps.Keys do
    begin
      lNewState := lFoundApps[lWnd];
      if lNewState.HasUnreadMessages then
      begin
        if SecondsBetween(Now, lNewState.LastSoundPlayed) > fUnreadMessageSoundInterval then
        begin
          PlaySoundFile(fUnreadMessageSound);
          lNewState.LastSoundPlayed := Now;
          lFoundApps[lWnd] := lNewState;
        end;
      end;
    end;

    fMonitoredApps.Free;
    fMonitoredApps := lFoundApps;
    lFoundApps := nil;
  finally
    if Assigned(lFoundApps) then
      lFoundApps.Free;
  end;
end;

procedure TChatMonitor.SetSoundEnabled(const aValue: Boolean);
begin
  fSoundEnabled := aValue;
end;

function TChatMonitor.ShouldReviewApp(
  const aAppCaption: string;
  const aMetadata: IChatAppMetadata;
  const aRules: TReviewRuleArray): Boolean;
var
  lRule: TReviewRule;
  lExcludeMatches: Boolean;
  lIncludeMatches: Boolean;
begin
  if Length(aRules) = 0 then
    Exit(False);

  lExcludeMatches := False;
  lIncludeMatches := False;

  for lRule in aRules do
  begin
    if MatchesReviewExcludeRule(aAppCaption, aMetadata, lRule) then
      lExcludeMatches := True;

    if MatchesReviewRule(aAppCaption, aMetadata, lRule) then
      lIncludeMatches := True;
  end;

  Result := lIncludeMatches and not lExcludeMatches;
end;

procedure TChatMonitor.UseConfigCache(aConfigCache: TConfigCache);
begin
  if not Assigned(aConfigCache) then
    Exit;

  if fOwnConfigCache and Assigned(fConfigCache) then
    fConfigCache.Free;
  fConfigCache := aConfigCache;
  fOwnConfigCache := False;
end;

end.

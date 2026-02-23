unit ActiveAppView.ChatMonitor;

interface

uses
  Winapi.Windows, System.Classes, System.Generics.Collections, System.IniFiles, System.SysUtils,
  MaxLogic.Cache,
  ActiveAppView.ConfigCache;

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
    class function ParseCommandLineParams(const aCommandLine: string): string; static;
    function GetMetadataCached(const aWnd: hWnd): IChatAppMetadata;
    procedure LoadConfiguration(aIni: TMemIniFile);
    function MatchesReviewRule(
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
  maxLogic.StrUtils, srDesktop;

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
    if (lRule.FileNameMask <> '') or (lRule.AppUserModelIDMask <> '') or (lRule.CmdParamsMask <> '') then
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
        lFileName := srDesktop.GetFileName(aWnd);
        lAppUserModelID := RetrieveAppUserModelID(aWnd);

        lPid := RetrievePID(aWnd);
        if lPid = 0 then
          lCommandLine := ''
        else
          lCommandLine := RetrieveCommandLine(lPid);
        lCommandLineParams := ParseCommandLineParams(lCommandLine);
        Result := TChatAppMetadata.Create(lFileName, lAppUserModelID, lCommandLineParams);
      end,
      lOptions);
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
  lIndex: Integer;
  lLen: Integer;
begin
  Result := False;
  lLen := Length(aCaption);
  if lLen < 3 then
    Exit;

  lIndex := 1;
  while lIndex <= lLen - 2 do
  begin
    if aCaption[lIndex] = '(' then
    begin
      Inc(lIndex);
      if (lIndex <= lLen) and CharInSet(aCaption[lIndex], ['0'..'9']) then
      begin
        while (lIndex <= lLen) and CharInSet(aCaption[lIndex], ['0'..'9']) do
          Inc(lIndex);
        if (lIndex <= lLen) and (aCaption[lIndex] = ')') then
          Exit(True);
      end;
    end;
    Inc(lIndex);
  end;
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
  lFullPath: string;
  lKey: string;
  lLastPlayedTime: TDateTime;
begin
  if not fSoundEnabled then
    Exit;

  if aFileName = '' then
    Exit;

  lFullPath := aFileName;
  if TPath.IsRelativePath(lFullPath) then
    lFullPath := TPath.Combine(ExtractFilePath(ParamStr(0)), aFileName);

  if not TFile.Exists(lFullPath) then
    Exit;

  lKey := lFullPath.ToLower;
  if fSoundThrottling.TryGetValue(lKey, lLastPlayedTime) then
    if SecondsBetween(Now, lLastPlayedTime) < 5 then
      Exit;
  fSoundThrottling.AddOrSetValue(lKey, Now);

  Winapi.MMSystem.PlaySound(PChar(lFullPath), 0, SND_FILENAME or SND_ASYNC);
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
  lApps: TArray<TChatAppSnapshot>;
begin
  SetLength(lApps, 0);
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
begin
  if Length(aRules) = 0 then
    Exit(False);

  for lRule in aRules do
    if MatchesReviewRule(aAppCaption, aMetadata, lRule) then
      Exit(True);

  Result := False;
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

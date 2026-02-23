unit ActiveAppView.ChatMonitor;

interface

uses
  winApi.windows, System.Classes, System.SysUtils, System.Generics.Collections, System.IniFiles,
  ActiveAppViewCore;

type
  TChatMonitor = class
  private
    type
      // Holds the runtime state of a monitored application window
      TMonitoredAppState = record
        AppInfo: TAppInfo;
        HasUnreadMessages: Boolean;
        LastSoundPlayed: TDateTime;
        IsPwa: Boolean;
      end;

  private
    fApps: TAppList;
    fMonitoredApps: TDictionary<hWnd, TMonitoredAppState>;
    fReviewRules: TObjectList<TStringList>;

    // Configuration
    fEnabled: Boolean;
    fSoundEnabled: Boolean;
    fUnreadMessageSound: string;
    fUnreadMessageSoundInterval: Integer;
    fPwaClosedSound: string;
    fSoundThrottling: TDictionary<String, TDateTime>;

    procedure LoadConfiguration(aIni: TmemIniFile);
    procedure LoadReviewRules(const aFileName: string);
    function MatchesReviewRule(const aApp: TAppInfo; const aRule: TStringList): Boolean;
    function ShouldReviewApp(const aApp: TAppInfo): Boolean;
    procedure PlaySoundFile(const aFileName: string);
    procedure SetSoundEnabled(const aValue: Boolean);

  public
    constructor Create(aSettings: TMemIniFile);
    destructor Destroy; override;

    procedure Process;
    property SoundEnabled: Boolean read fSoundEnabled write SetSoundEnabled;
  end;

implementation

uses
  Winapi.MMSystem, System.RegularExpressions, System.IOUtils, system.DateUtils, System.StrUtils,
  maxLogic.StrUtils, AutoFree;

const
  cUnreadMessagesPattern = '\(\d+\)';

{ TChatMonitor }

constructor TChatMonitor.Create(aSettings: TMemIniFile);
begin
  inherited Create;
  fSoundThrottling:= TDictionary<String, TDateTime>.Create;
  fApps := TAppList.Create;
  fMonitoredApps := TDictionary<hWnd, TMonitoredAppState>.Create;
  fReviewRules := TObjectList<TStringList>.Create;
  LoadConfiguration(aSettings);
end;

destructor TChatMonitor.Destroy;
begin
  fReviewRules.Free;
  fMonitoredApps.Free;
  fApps.Free;
  fSoundThrottling.Free;
  inherited;
end;

procedure TChatMonitor.LoadConfiguration(aIni: TMemIniFile);
var
  lReviewMaskFileName: string;
begin
  fEnabled := aIni.ReadBool('ChatMonitor', 'Enabled', False);
  fSoundEnabled := aIni.ReadBool('ChatMonitor', 'SoundEnabled', True);
  if not fEnabled then
    Exit;

  fUnreadMessageSound := aIni.ReadString('ChatMonitor', 'UnreadMessageSound', '');
  fUnreadMessageSoundInterval := aIni.ReadInteger('ChatMonitor', 'UnreadMessageSoundIntervalSeconds', 30);
  fPwaClosedSound := aIni.ReadString('ChatMonitor', 'PwaClosedSound', '');
  lReviewMaskFileName := aIni.ReadString('ChatMonitor', 'ReviewMaskFile', 'ChatReviewMask.txt');
  if TPath.IsRelativePath(lReviewMaskFileName) then
    lReviewMaskFileName := TPath.Combine(ExtractFilePath(ParamStr(0)), lReviewMaskFileName);
  LoadReviewRules(lReviewMaskFileName);
end;

procedure TChatMonitor.LoadReviewRules(const aFileName: string);
var
  lLine: string;
  lLines: TStringList;
  lRule: TStringList;
  X: Integer;
begin
  fReviewRules.Clear;
  if not TFile.Exists(aFileName) then
    Exit;

  gc(lLines, TStringList.Create);
  lLines.LoadFromFile(aFileName, TEncoding.Utf8);
  for X := 0 to lLines.Count - 1 do
  begin
    lLine := lLines[X].Trim;
    if (lLine = '') or StartsText(';', lLine) or StartsText('#', lLine) then
      Continue;

    lRule := TStringList.Create;
    lRule.CaseSensitive := False;
    lRule.StrictDelimiter := True;
    lRule.CommaText := lLine;
    fReviewRules.Add(lRule);
  end;
end;

function TChatMonitor.MatchesReviewRule(const aApp: TAppInfo; const aRule: TStringList): Boolean;
var
  lAppUserModelIDMask: string;
  lCaptionMask: string;
  lCmdParamsMask: string;
  lFileNameMask: string;
begin
  aRule.CaseSensitive := False;
  lCaptionMask := aRule.Values['caption'];
  lFileNameMask := aRule.Values['filename'];
  lAppUserModelIDMask := aRule.Values['AppUserModelID'];
  lCmdParamsMask := aRule.Values['CmdParams'];

  Result := ((lCaptionMask <> '') and StringMatches(aApp.Caption, lCaptionMask, False))
    or ((lFileNameMask <> '') and StringMatches(aApp.FileName, lFileNameMask, False))
    or ((lAppUserModelIDMask <> '') and StringMatches(aApp.AppUserModelID, lAppUserModelIDMask, False))
    or ((lCmdParamsMask <> '') and StringMatches(aApp.CommandLineParams, lCmdParamsMask, False));
end;

function TChatMonitor.ShouldReviewApp(const aApp: TAppInfo): Boolean;
var
  lRule: TStringList;
begin
  if fReviewRules.Count = 0 then
    Exit(False);

  for lRule in fReviewRules do
    if MatchesReviewRule(aApp, lRule) then
      Exit(True);

  Result := False;
end;

procedure TChatMonitor.PlaySoundFile(const aFileName: string);
var
  lKey, lFullPath: string;
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

  // prevent playing the same sound simultanously multiple times
  lKey:= lFullPath.ToLower;
  if fSoundThrottling.TryGetValue(lKey, lLastPlayedTime) then
    if secondsBetween(now, lLastPlayedTime) < 5 then
      exit;
  fSoundThrottling.addOrSetValue(lKey, now);

  Winapi.MMSystem.PlaySound(PChar(lFullPath), 0, SND_FILENAME or SND_ASYNC);
end;

procedure TChatMonitor.SetSoundEnabled(const aValue: Boolean);
begin
  fSoundEnabled := aValue;
end;

procedure TChatMonitor.Process;
var
  lApp: TAppInfo;
  lFoundApps: TDictionary<hWnd, TMonitoredAppState>;
  lNewState: TMonitoredAppState;
  lOldState: TMonitoredAppState;
  lWnd: hWnd;
begin
  if not fEnabled then
    Exit;

  fApps.Update;
  lFoundApps := TDictionary<hWnd, TMonitoredAppState>.Create;
  try
    // 1. Identify all currently running apps that match review-mask rules
    for var x:=0 to fApps.Count -1 do
    begin
      lApp:= fApps[x];
      if not ShouldReviewApp(lApp) then
        Continue;

      lNewState.AppInfo := lApp;
      lNewState.HasUnreadMessages := TRegEx.IsMatch(lApp.Caption, cUnreadMessagesPattern);
      lNewState.IsPwa := SameText(ExtractFileName(lApp.FileName), 'msedge.exe');

      // Preserve the last sound played time if the app was already monitored
      if fMonitoredApps.TryGetValue(lApp.Wnd, lOldState) then
        lNewState.LastSoundPlayed := lOldState.LastSoundPlayed
      else
        lNewState.LastSoundPlayed := 0; // Far in the past

      lFoundApps.AddOrsetValue(lApp.Wnd, lNewState);
    end;

    // 2. Check for newly closed PWAs
    for lWnd in fMonitoredApps.Keys do
    begin
      if not lFoundApps.ContainsKey(lWnd) then
      begin
        // This app was monitored but is now gone
        if fMonitoredApps[lWnd].IsPwa then
        begin
          PlaySoundFile(fPwaClosedSound);
        end;
      end;
    end;

    // 3. Check for new unread messages and play sounds
    for lWnd in lFoundApps.Keys do
    begin
      lNewState := lFoundApps[lWnd];
      if lNewState.HasUnreadMessages then
      begin
        if SecondsBetween(Now, lNewState.LastSoundPlayed) > fUnreadMessageSoundInterval then
        begin
          PlaySoundFile(fUnreadMessageSound);
          lNewState.LastSoundPlayed := Now;
          lFoundApps[lWnd] := lNewState; // Update the state with the new timestamp
        end;
      end;
    end;

    // 4. Swap the old state with the new state
    fMonitoredApps.Free;
    fMonitoredApps := lFoundApps;
    lFoundApps := nil; // Ownership transferred

  finally
    if Assigned(lFoundApps) then
      lFoundApps.Free;
  end;
end;

end.

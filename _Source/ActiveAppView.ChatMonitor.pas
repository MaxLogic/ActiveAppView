unit ActiveAppView.ChatMonitor;

interface

uses
  winApi.windows, System.Classes, System.SysUtils, System.Generics.Collections, System.IniFiles,
  ActiveAppViewCore;

type
  TChatMonitor = class
  private
    type
      // Rule for identifying a specific chat application
      TChatAppRule = record
        ExeNameMask: string;
        CaptionMask: string;
        UnreadPattern: string;
      end;

      // Holds the runtime state of a monitored application window
      TMonitoredAppState = record
        AppInfo: TAppInfo;
        HasUnreadMessages: Boolean;
        LastSoundPlayed: TDateTime;
        IsPwa: Boolean;
      end;

  private
    fApps: TAppList;
    fRules: TList<TChatAppRule>;
    fMonitoredApps: TDictionary<hWnd, TMonitoredAppState>;

    // Configuration
    fEnabled: Boolean;
    fUnreadMessageSound: string;
    fUnreadMessageSoundInterval: Integer;
    fPwaClosedSound: string;
    fSoundThrottling: TDictionary<String, TDateTime>;

    procedure LoadConfiguration(aIni: TmemIniFile);
    procedure PlaySoundFile(const aFileName: string);

  public
    constructor Create(aSettings: TMemIniFile);
    destructor Destroy; override;

    procedure Process;
  end;

implementation

uses
  Winapi.MMSystem, System.RegularExpressions, System.IOUtils, system.DateUtils,
  maxLogic.StrUtils, AutoFree;

{ TChatMonitor }

constructor TChatMonitor.Create(aSettings: TMemIniFile);
begin
  inherited Create;
  fSoundThrottling:= TDictionary<String, TDateTime>.Create;
  fApps := TAppList.Create;
  fRules := TList<TChatAppRule>.Create;
  fMonitoredApps := TDictionary<hWnd, TMonitoredAppState>.Create;
  LoadConfiguration(aSettings);
end;

destructor TChatMonitor.Destroy;
begin
  fRules.Free;
  fMonitoredApps.Free;
  fApps.Free;
  fSoundThrottling.Free;
  inherited;
end;

procedure TChatMonitor.LoadConfiguration;
var
  lRuleRecord: TChatAppRule;
  lRuleStrings: TArray<String>;
  i: Integer;
  lRuleKey: string;
  lKeys: TStringList;
  s: String;
begin
  fEnabled := aIni.ReadBool('ChatMonitor', 'Enabled', False);
  if not fEnabled then
    Exit;

  fUnreadMessageSound := aIni.ReadString('ChatMonitor', 'UnreadMessageSound', '');
  fUnreadMessageSoundInterval := aIni.ReadInteger('ChatMonitor', 'UnreadMessageSoundIntervalSeconds', 30);
  fPwaClosedSound := aIni.ReadString('ChatMonitor', 'PwaClosedSound', '');

  fRules.Clear;
  gc(lKeys, TStringList.Create);
  aIni.ReadSection('ChatMonitor.Rules', lKeys);
  for lRuleKey in lKeys do
  begin
    lRuleRecord:= default(TChatAppRule);
    s:= aIni.ReadString('ChatMonitor.Rules', lRuleKey, '');
    if s.Trim = '' then
      continue;
    lRuleStrings := s.Split(['|']);
    if Length(lRuleStrings) < 3 then
      continue;
    lRuleRecord.ExeNameMask := lRuleStrings[0];
    lRuleRecord.CaptionMask := lRuleStrings[1];
    lRuleRecord.UnreadPattern := lRuleStrings[2];

    fRules.Add(lRuleRecord);
  end;
end;

procedure TChatMonitor.PlaySoundFile(const aFileName: string);
var
  lKey, lFullPath: string;
  dt: TDateTime;
begin
  if aFileName = '' then
    Exit;

  lFullPath := aFileName;
  if TPath.IsRelativePath(lFullPath) then
    lFullPath := TPath.Combine(ExtractFilePath(ParamStr(0)), aFileName);

  if not TFile.Exists(lFullPath) then
    Exit;

  // prevent playing the same sound simultanously multiple times
  lKey:= lFullPath.ToLower;
  if fSoundThrottling.TryGetValue(lKey, dt) then
    if secondsBetween(now, dt) < 5 then
      exit;
  fSoundThrottling.addOrSetValue(lKey, now);

  Winapi.MMSystem.PlaySound(PChar(lFullPath), 0, SND_FILENAME or SND_ASYNC);
end;

procedure TChatMonitor.Process;
var
  lApp: TAppInfo;
  lRule: TChatAppRule;
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
    // 1. Identify all currently running apps that match our rules
    for var x:=0 to fApps.Count -1 do
    begin
      lApp:= fApps[x];

      for lRule in fRules do
      begin
        if StringMatches(ExtractFileName(lApp.FileName), lRule.ExeNameMask, false) then
        if StringMatches(lApp.Caption, lRule.CaptionMask, false) then
        begin
          // Found a matching app, determine its state
          lNewState.AppInfo := lApp;
          lNewState.HasUnreadMessages := TRegEx.IsMatch(lApp.Caption, lRule.UnreadPattern);
          lNewState.IsPwa := SameText(ExtractFileName(lApp.FileName), 'msedge.exe');

          // Preserve the last sound played time if the app was already monitored
          if fMonitoredApps.TryGetValue(lApp.Wnd, lOldState) then
            lNewState.LastSoundPlayed := lOldState.LastSoundPlayed
          else
            lNewState.LastSoundPlayed := 0; // Far in the past

          lFoundApps.AddOrsetValue(lApp.Wnd, lNewState);
          Break; // Move to the next app once a rule matches
        end;
      end;
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

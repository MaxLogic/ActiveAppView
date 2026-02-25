unit ActiveAppViewMainForm;

interface

uses
  System.Classes, System.Generics.Collections, System.SysUtils, System.Variants,
  Winapi.Messages, Winapi.Windows,
  Vcl.Buttons, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms, Vcl.Graphics, Vcl.StdCtrls,
  maxAsync,
  ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache, ActiveAppViewCore;

type
  TAppsViewMainFrm = class(TForm)
    lbApps: TListBox;
    pnlApps: TPanel;
    labAppTitle: TStaticText;
    Splitter1: TSplitter;
    pnlExplorer: TPanel;
    labExplorerTitle: TStaticText;
    lbExplorer: TListBox;
    pnlAppFocusLeft: TPanel;
    pnlExplorerFocusLeft: TPanel;
    pnlAppsFocusRight: TPanel;
    pnlExplorerFocusRight: TPanel;
    pnlAppDetails: TPanel;
    imgAppScreenshot: TImage;
    pnlAppDetailInfo: TPanel;
    edAppFileName: TEdit;
    lapAppCaption: TStaticText;
    edAppCaption: TEdit;
    labAppFileName: TStaticText;
    Splitter2: TSplitter;
    pnlScripts: TPanel;
    labScriptsTitle: TStaticText;
    lbScripts: TListBox;
    pnlScriptsFocusLeft: TPanel;
    pnlScriptsFocusRight: TPanel;
    Splitter3: TSplitter;
    Splitter4: TSplitter;
    Splitter5: TSplitter;
    Splitter6: TSplitter;
    pnlConsole: TPanel;
    labConsoleTitle: TStaticText;
    lbConsole: TListBox;
    pnlConsoleFocusLeft: TPanel;
    pnlConsoleFocusRight: TPanel;
    pnlDesktop: TPanel;
    labDesktopTitle: TStaticText;
    lbDesktop: TListBox;
    pnlDesktopFocusLeft: TPanel;
    pnlDesktopFocusRight: TPanel;
    pnlShortCuts: TPanel;
    labShortCutsTitle: TStaticText;
    lbShortCuts: TListBox;
    pnlShortCutsFocusLeft: TPanel;
    pnlShortCutsFocusRight: TPanel;
    tmrChatMonitor: TTimer;
    Panel1: TPanel;
    labTemplateActiv: TStaticText;
    labTemplateInActiv: TStaticText;
    edCommandLineParams: TEdit;
    labCommandLineParams: TStaticText;
    edPID: TEdit;
    labPid: TStaticText;
    edAppUserModelID: TEdit;
    labAppUserModelID: TStaticText;
    edRelaunchCommand: TEdit;
    labRelaunchCommand: TStaticText;
    chkChatNotificationSound: TCheckBox;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure lbAppsDblClick(Sender: TObject);
    procedure lbAppsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbScriptsDblClick(Sender: TObject);
    procedure lbAppsClick(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure lbScriptsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbDesktopDblClick(Sender: TObject);
    procedure lbDesktopKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbShortCutsDblClick(Sender: TObject);
    procedure lbShortCutsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure tmrChatMonitorTimer(Sender: TObject);
    procedure chkChatNotificationSoundClick(aSender: TObject);
  private

    fApps: TAppList;
    fAuxListRefresh: iAsync;
    fAuxListRefreshBusy: Integer;
    fAuxListRefreshPending: Integer;
    fChatMonitorBusy: Integer;
    fChatMonitorPending: Integer;
    fChatMonitorTask: iAsync;
    fConfigCache: TConfigCache;
    fOrgAppOnActivate: TNotifyEvent;
    fChatMonitor: TChatMonitor;
    fGuiRefreshQueued: Integer;
    fLastFormFocusTick: UInt64;
    fPendingAuxSnapshot: TObject;
    fSharedAppsSnapshot: TArray<TChatAppSnapshot>;
    fSharedAppsSnapshotTick: UInt64;
    procedure AppOnActivate(Sender: TObject);
    procedure ApplyAuxListsSnapshot(aSnapshotObject: TObject);
    procedure ApplyDesktopSnapshot(const aItems: TNamedValueArray);
    procedure ApplyScriptsSnapshot(const aScripts: TStringArray);
    procedure ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
    function BuildAuxListsSnapshot: TObject;
    procedure MarkFormFocused;
    procedure OnAuxListsRefreshDone;
    procedure OnChatMonitorDone;
    procedure QueueGuiRefresh;
    procedure RebuildSharedAppsSnapshot;
    procedure RunAuxListsRefresh;
    procedure RunChatMonitorSnapshot;
    procedure StartAuxListsRefresh;
    procedure StartChatMonitorProcessing;
    procedure EnsureSharedAppsSnapshotFresh(const aMaxAgeMs: UInt64);
    procedure UpdateGui;

    procedure BringToFrontFocusedApp(lb: TListBox);
    procedure UpdateAppDetail;
    procedure CheckPrefixRule(var s: string; app: TAppInfo; const aRules: TPrefixRuleArray);
    function ExcludeByMask(app: TAppInfo; const aMasks: TStringArray): boolean;
    procedure RestoreItemIndex(lb: TListBox; wnd: hwnd; oldItemIndex: integer; const aOldItemCaption: string);
    function GetWnd(lb: TListBox): hwnd;
    procedure ActiveControlChanged(Sender: TObject);
    procedure ClearListBoxItemData(lb: TListBox);
    procedure UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
    function IsTerminalApp(const aFileName: string; const aPatterns: TStringArray): boolean;
    function TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
    procedure AddDesktopItemsFromFolder(const aFolder: string; var aItems: TNamedValueArray);
    function TryParseShortCutValue(const aValue: string; out aTargetPath: string;
      out aParams: string): boolean;
    procedure ActivateDesktopItem;
    procedure ActivateShortCutItem;
    procedure RestoreSelectedItem(lb: TListBox; const aCaption: string);
  public

  end;

var
  AppsViewMainFrm: TAppsViewMainFrm;

function RunMainFormSelfTests(const aArg: string): Integer;

implementation

uses
  System.IniFiles, System.IOUtils, System.StrUtils, System.SyncObjs,
  Winapi.ActiveX, Winapi.KnownFolders, Winapi.MMSystem, Winapi.ShellAPI, Winapi.ShlObj,
  AutoFree, bsUtils, maxLogic.AutoStart, maxLogic.IOUtils, maxLogic.StrUtils,
  srDesktop;

{$R *.dfm}

type
  TListBoxItemData = class
  public
    Value: string;
    constructor Create(const aValue: string);
  end;

  TAuxListsSnapshot = class
  public
    DesktopItems: TNamedValueArray;
    Scripts: TStringArray;
    ShortCuts: TNamedValueArray;
  end;

const
  cShortCutsFileName = 'ShortCuts.txt';
  cTerminalPatternsFileName = 'TerminalPatterns.txt';
  cScriptsFolderName = 'Scripts';
  cHideMaskFileName = 'HideMask.txt';
  cPrefixMaskFileName = 'PrefixMask.txt';
  cSettingsFileName = 'settings.ini';
  cRestoreItemIndexSelfTestArg = '--self-test-restore-item-index';
  cIgnoreF4AfterFocusMs = 200;

resourcestring
  rsShortCutTargetMissing = 'ShortCut target not found: %s';

function FindSortedCaptionIndex(const aItems: TStrings; const aOldItemCaption: string): Integer;
var
  lItems: TStringList;
  lIndex: Integer;
begin
  Result := -1;
  if aOldItemCaption = '' then
    Exit;

  gc(lItems, TStringList.Create);
  lItems.Assign(aItems);
  lItems.Sorted := True;
  if lItems.Find(aOldItemCaption, lIndex) then
    Result := lIndex;
end;

{ TListBoxItemData }

constructor TListBoxItemData.Create(const aValue: string);
begin
  inherited Create;
  Value := aValue;
end;

procedure TAppsViewMainFrm.ActiveControlChanged(Sender: TObject);
var
  lActive: TWinControl;
  lPrefix: string;
var
  lListBoxes: TArray<TListBox>;
  lTitles: TArray<TStaticText>;
  lLeftPanels: TArray<TPanel>;
  lRightPanels: TArray<TPanel>;
  lIsActive: boolean;
  X: integer;
begin
  lActive := self.ActiveControl;

  lPrefix := copy(labTemplateActiv.caption, 1, 2);
  lListBoxes := [lbApps, lbExplorer, lbScripts, lbConsole, lbDesktop, lbShortCuts];
  lTitles := [labAppTitle, labExplorerTitle, labScriptsTitle, labConsoleTitle, labDesktopTitle, labShortCutsTitle];
  lLeftPanels := [pnlAppFocusLeft, pnlExplorerFocusLeft, pnlScriptsFocusLeft, pnlConsoleFocusLeft,
    pnlDesktopFocusLeft, pnlShortCutsFocusLeft];
  lRightPanels := [pnlAppsFocusRight, pnlExplorerFocusRight, pnlScriptsFocusRight, pnlConsoleFocusRight,
    pnlDesktopFocusRight, pnlShortCutsFocusRight];

  for X := 0 to High(lTitles) do
  begin
    lIsActive := lActive = lListBoxes[X];
    UpdateTitlePrefix(lTitles[X], lPrefix, lIsActive);
    if lIsActive then
    begin
      lTitles[X].Font.Assign(labTemplateActiv.Font);
      lLeftPanels[X].Color := clBlack;
    end
    else
    begin
      lTitles[X].Font.Assign(labTemplateInActiv.Font);
      lLeftPanels[X].Color := self.Color;
    end;
    lRightPanels[X].Color := lLeftPanels[X].Color;
  end;
end;

procedure TAppsViewMainFrm.AppOnActivate(Sender: TObject);
begin
  MarkFormFocused;
  QueueGuiRefresh;
  if assigned(fOrgAppOnActivate) then
    fOrgAppOnActivate(Sender);
end;

procedure TAppsViewMainFrm.BringToFrontFocusedApp(lb: TListBox);
var
  app: TAppInfo;
  wnd: hwnd;
begin
  wnd := 0;
  if lb = lbApps then
    UpdateAppDetail;

  wnd := GetWnd(lb);

  if fApps.TryGetApp(wnd, app) then
    app.SHOW;
end;

procedure TAppsViewMainFrm.ClearListBoxItemData(lb: TListBox);
var
  i: integer;
  lItem: TObject;
begin
  for i := 0 to lb.Items.Count - 1 do
  begin
    lItem := lb.Items.Objects[i];
    if lItem is TListBoxItemData then
      lItem.Free;
  end;
  lb.Items.Clear;
end;

procedure TAppsViewMainFrm.UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
var
  lCaption: string;
begin
  lCaption := st.Caption;
  if aEnabled then
  begin
    if not StartsText(aPrefix, lCaption) then
      st.Caption := aPrefix + lCaption;
  end
  else
  begin
    if StartsText(aPrefix, lCaption) then
      st.Caption := Trim(Copy(lCaption, Length(aPrefix) + 1, Length(lCaption)));
  end;
end;

function TAppsViewMainFrm.IsTerminalApp(const aFileName: string; const aPatterns: TStringArray): boolean;
var
  lPattern: string;
begin
  Result := False;
  if aFileName = '' then
    Exit;

  for lPattern in aPatterns do
    if maxLogic.StrUtils.StringMatches(aFileName, lPattern, False) then
      Exit(True);
end;

function TAppsViewMainFrm.TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
var
  lPtr: PWideChar;
begin
  aPath := '';
  lPtr := nil;
  Result := SHGetKnownFolderPath(aFolderId, 0, 0, lPtr) = S_OK;
  if Result then
    aPath := lPtr;

  if lPtr <> nil then
    CoTaskMemFree(lPtr);
end;

procedure TAppsViewMainFrm.AddDesktopItemsFromFolder(const aFolder: string; var aItems: TNamedValueArray);
var
  lDir: string;
  lFile: string;
  lItem: TNamedValue;
begin
  if not DirectoryExists(aFolder) then
    Exit;

  for lDir in TDirectory.GetDirectories(aFolder) do
  begin
    lItem.Name := ExtractFileName(lDir);
    if lItem.Name = '' then
      lItem.Name := lDir;
    lItem.Value := lDir;
    SetLength(aItems, Length(aItems) + 1);
    aItems[High(aItems)] := lItem;
  end;

  for lFile in TDirectory.GetFiles(aFolder, '*.*') do
  begin
    lItem.Name := ExtractFileName(lFile);
    if lItem.Name = '' then
      lItem.Name := lFile;
    lItem.Value := lFile;
    SetLength(aItems, Length(aItems) + 1);
    aItems[High(aItems)] := lItem;
  end;
end;

function TAppsViewMainFrm.BuildAuxListsSnapshot: TObject;
var
  lExt: string;
  lItem: TNamedValue;
  lScriptFile: string;
  lScriptsDir: string;
  lPublicDesktop: string;
  lSnapshot: TAuxListsSnapshot;
  lUserDesktop: string;
begin
  lSnapshot := TAuxListsSnapshot.Create;
  try
    SetLength(lSnapshot.DesktopItems, 0);
    if TryGetKnownFolderPath(FOLDERID_Desktop, lUserDesktop) then
      AddDesktopItemsFromFolder(lUserDesktop, lSnapshot.DesktopItems);
    if TryGetKnownFolderPath(FOLDERID_PublicDesktop, lPublicDesktop) then
      if not SameText(lUserDesktop, lPublicDesktop) then
        AddDesktopItemsFromFolder(lPublicDesktop, lSnapshot.DesktopItems);

    lSnapshot.ShortCuts := fConfigCache.GetShortCuts(cShortCutsFileName);

    SetLength(lSnapshot.Scripts, 0);
    lScriptsDir := CombinePath([GetInstallDir, cScriptsFolderName]);
    if TDirectory.Exists(lScriptsDir) then
    begin
      for lScriptFile in TDirectory.GetFiles(lScriptsDir, '*.*') do
      begin
        lExt := ExtractFileExt(lScriptFile);
        if System.StrUtils.MatchText(lExt, ['.cmd', '.bat', '.ps1', '.exe', '.py']) then
        begin
          lItem.Name := ExtractFileName(lScriptFile);
          lItem.Value := '';
          SetLength(lSnapshot.Scripts, Length(lSnapshot.Scripts) + 1);
          lSnapshot.Scripts[High(lSnapshot.Scripts)] := lItem.Name;
        end;
      end;
    end;

    Result := lSnapshot;
  except
    lSnapshot.Free;
    raise;
  end;
end;

procedure TAppsViewMainFrm.ApplyDesktopSnapshot(const aItems: TNamedValueArray);
var
  lIndex: Integer;
  lItem: TListBoxItemData;
  lPrevCaption: string;
begin
  lPrevCaption := '';
  if lbDesktop.ItemIndex <> -1 then
    lPrevCaption := lbDesktop.Items[lbDesktop.ItemIndex];

  lbDesktop.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbDesktop);
    for lIndex := 0 to High(aItems) do
    begin
      lItem := TListBoxItemData.Create(aItems[lIndex].Value);
      lbDesktop.Items.AddObject(aItems[lIndex].Name, lItem);
    end;
  finally
    lbDesktop.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbDesktop, lPrevCaption);
end;

procedure TAppsViewMainFrm.ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
var
  lIndex: Integer;
  lItem: TListBoxItemData;
  lPrevCaption: string;
begin
  lPrevCaption := '';
  if lbShortCuts.ItemIndex <> -1 then
    lPrevCaption := lbShortCuts.Items[lbShortCuts.ItemIndex];

  lbShortCuts.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbShortCuts);
    for lIndex := 0 to High(aItems) do
    begin
      lItem := TListBoxItemData.Create(aItems[lIndex].Value);
      lbShortCuts.Items.AddObject(aItems[lIndex].Name, lItem);
    end;
  finally
    lbShortCuts.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbShortCuts, lPrevCaption);
end;

procedure TAppsViewMainFrm.ApplyScriptsSnapshot(const aScripts: TStringArray);
var
  lIndex: Integer;
  lItemIndex: Integer;
  lScriptName: string;
  lPrevFocused: string;
begin
  lPrevFocused := '';
  if lbScripts.ItemIndex <> -1 then
    lPrevFocused := lbScripts.Items[lbScripts.ItemIndex];

  lbScripts.Items.BeginUpdate;
  try
    lbScripts.ItemIndex := -1;
    lbScripts.Items.Clear;
    for lIndex := 0 to High(aScripts) do
    begin
      lScriptName := aScripts[lIndex];
      lItemIndex := lbScripts.Items.Add(lScriptName);
      if (lbScripts.ItemIndex = -1) and SameText(lPrevFocused, lScriptName) then
        lbScripts.ItemIndex := lItemIndex;
    end;
  finally
    lbScripts.Items.EndUpdate;
  end;
end;

procedure TAppsViewMainFrm.ApplyAuxListsSnapshot(aSnapshotObject: TObject);
var
  lSnapshot: TAuxListsSnapshot;
begin
  if not (aSnapshotObject is TAuxListsSnapshot) then
    Exit;

  lSnapshot := TAuxListsSnapshot(aSnapshotObject);
  ApplyScriptsSnapshot(lSnapshot.Scripts);
  ApplyDesktopSnapshot(lSnapshot.DesktopItems);
  ApplyShortCutsSnapshot(lSnapshot.ShortCuts);
end;

procedure TAppsViewMainFrm.RunAuxListsRefresh;
begin
  fPendingAuxSnapshot := BuildAuxListsSnapshot;
end;

procedure TAppsViewMainFrm.OnAuxListsRefreshDone;
begin
  try
    if Assigned(fPendingAuxSnapshot) then
    begin
      ApplyAuxListsSnapshot(fPendingAuxSnapshot);
      FreeAndNil(fPendingAuxSnapshot);
    end;
  finally
    TInterlocked.Exchange(fAuxListRefreshBusy, 0);
    if TInterlocked.Exchange(fAuxListRefreshPending, 0) = 1 then
      StartAuxListsRefresh;
  end;
end;

procedure TAppsViewMainFrm.StartAuxListsRefresh;
begin
  if TInterlocked.CompareExchange(fAuxListRefreshBusy, 1, 0) <> 0 then
  begin
    TInterlocked.Exchange(fAuxListRefreshPending, 1);
    Exit;
  end;

  fAuxListRefresh := SimpleAsyncCall(RunAuxListsRefresh, 'ActiveAppView.AuxListRefresh', OnAuxListsRefreshDone);
end;

procedure TAppsViewMainFrm.QueueGuiRefresh;
begin
  if TInterlocked.CompareExchange(fGuiRefreshQueued, 1, 0) <> 0 then
    Exit;

  TThread.Queue(nil,
    procedure
    begin
      TInterlocked.Exchange(fGuiRefreshQueued, 0);
      if csDestroying in ComponentState then
        Exit;
      UpdateGui;
    end);
end;

function TAppsViewMainFrm.TryParseShortCutValue(const aValue: string; out aTargetPath: string;
  out aParams: string): boolean;
var
  lValue: string;
  lPos: integer;
begin
  aTargetPath := '';
  aParams := '';
  lValue := aValue.Trim;
  if lValue = '' then
    Exit(False);

  if StartsText('"', lValue) then
  begin
    lPos := PosEx('"', lValue, 2);
    if lPos > 1 then
    begin
      aTargetPath := Copy(lValue, 2, lPos - 2);
      aParams := Trim(Copy(lValue, lPos + 1, MaxInt));
    end
    else
      aTargetPath := lValue;
  end
  else
  begin
    lPos := PosEx(' ', lValue, 1);
    if lPos > 0 then
    begin
      aTargetPath := Copy(lValue, 1, lPos - 1);
      aParams := Trim(Copy(lValue, lPos + 1, MaxInt));
    end
    else
      aTargetPath := lValue;
  end;

  Result := aTargetPath <> '';
end;

procedure TAppsViewMainFrm.ActivateDesktopItem;
var
  lItem: TListBoxItemData;
  lPath: string;
begin
  if lbDesktop.ItemIndex < 0 then
    Exit;

  if not (lbDesktop.Items.Objects[lbDesktop.ItemIndex] is TListBoxItemData) then
    Exit;

  lItem := TListBoxItemData(lbDesktop.Items.Objects[lbDesktop.ItemIndex]);
  lPath := lItem.Value;
  if lPath = '' then
    Exit;

  if DirectoryExists(lPath) or FileExists(lPath) then
    ShellExecute(Handle, 'open', PChar(lPath), nil, nil, SW_SHOWNORMAL);
end;

procedure TAppsViewMainFrm.ActivateShortCutItem;
var
  lItem: TListBoxItemData;
  lTargetPath: string;
  lParams: string;
  lResult: HINST;
begin
  if lbShortCuts.ItemIndex < 0 then
    Exit;

  if not (lbShortCuts.Items.Objects[lbShortCuts.ItemIndex] is TListBoxItemData) then
    Exit;

  lItem := TListBoxItemData(lbShortCuts.Items.Objects[lbShortCuts.ItemIndex]);
  if not TryParseShortCutValue(lItem.Value, lTargetPath, lParams) then
    Exit;

  if StartsText('\\', lTargetPath) then
  begin
    lResult := ShellExecute(Handle, 'open', PChar(lTargetPath), PChar(lParams), nil, SW_SHOWNORMAL);
    if lResult <= 32 then
      MessageDlg(Format(rsShortCutTargetMissing, [lTargetPath]), mtWarning, [mbOK], 0);
    Exit;
  end;

  if DirectoryExists(lTargetPath) then
  begin
    ShellExecute(Handle, 'open', PChar(lTargetPath), nil, nil, SW_SHOWNORMAL);
    Exit;
  end;

  if FileExists(lTargetPath) then
  begin
    ShellExecute(Handle, 'open', PChar(lTargetPath), PChar(lParams), nil, SW_SHOWNORMAL);
    Exit;
  end;

  MessageDlg(Format(rsShortCutTargetMissing, [lTargetPath]), mtWarning, [mbOK], 0);
end;

procedure TAppsViewMainFrm.RestoreSelectedItem(lb: TListBox; const aCaption: string);
var
  lIndex: integer;
begin
  if lb.Items.Count = 0 then
  begin
    lb.ItemIndex := -1;
    Exit;
  end;

  if aCaption <> '' then
  begin
    lIndex := lb.Items.IndexOf(aCaption);
    if lIndex >= 0 then
    begin
      lb.ItemIndex := lIndex;
      Exit;
    end;
  end;

  if lb.ItemIndex < 0 then
    lb.ItemIndex := 0;
end;

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; app: TAppInfo; const aRules: TPrefixRuleArray);
var
  lRule: TPrefixRule;
begin
  for lRule in aRules do
  begin
    if ((lRule.CaptionMask <> '') and maxLogic.StrUtils.StringMatches(app.caption, lRule.CaptionMask, False))
      or ((lRule.FileNameMask <> '') and maxLogic.StrUtils.StringMatches(app.FileName, lRule.FileNameMask, False))
      or ((lRule.AppUserModelIDMask <> '') and maxLogic.StrUtils.StringMatches(app.AppUserModelID, lRule.AppUserModelIDMask, False))
      or ((lRule.CmdParamsMask <> '') and maxLogic.StrUtils.StringMatches(app.CommandLineParams, lRule.CmdParamsMask, False)) then
    begin
      if lRule.Prefix <> '' then
        s := lRule.Prefix + ' - ' + s;
      Exit;
    end;
  end;
end;

function TAppsViewMainFrm.ExcludeByMask(app: TAppInfo; const aMasks: TStringArray): boolean;
var
  lMask: string;
begin
  Result := False;
  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(app.caption, lMask, False) then
      Exit(True);
  end;

  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(app.FileName, lMask, False) then
      Exit(True);
  end;
end;

procedure TAppsViewMainFrm.FormActivate(Sender: TObject);
begin
  MarkFormFocused;
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.FormCreate(Sender: TObject);
var
  lIniFile: TMemIniFile;
begin
  fApps := TAppList.Create;
  fConfigCache := TConfigCache.Create(GetInstallDir);
  AddToAutoStart;
  Screen.OnActiveControlChange := ActiveControlChanged;
  labAppTitle.Height := labTemplateActiv.Height;
  labExplorerTitle.Height := labTemplateActiv.Height;
  labScriptsTitle.Height := labTemplateActiv.Height;
  labConsoleTitle.Height := labTemplateActiv.Height;
  labDesktopTitle.Height := labTemplateActiv.Height;
  labShortCutsTitle.Height := labTemplateActiv.Height;
  ActiveControlChanged(nil);
  fOrgAppOnActivate := application.OnActivate;
  application.OnActivate := AppOnActivate;

  gc(lIniFile, TMemIniFile.Create(CombinePath([GetInstallDir, cSettingsFileName]), TEncoding.Utf8, False));
  fChatMonitor := TChatMonitor.Create(lIniFile);
  fChatMonitor.UseConfigCache(fConfigCache);
  chkChatNotificationSound.Checked := lIniFile.ReadBool('ChatMonitor', 'SoundEnabled', True);
  chkChatNotificationSound.Enabled := lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
  fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;
  tmrChatMonitor.Interval := lIniFile.ReadInteger('ChatMonitor', 'CheckIntervalSeconds', 5) * 1000;
  tmrChatMonitor.Enabled:= lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
  SetLength(fSharedAppsSnapshot, 0);
  fSharedAppsSnapshotTick := 0;
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
begin
  tmrChatMonitor.Enabled := False;
  TInterlocked.Exchange(fChatMonitorPending, 0);
  TInterlocked.Exchange(fAuxListRefreshPending, 0);
  TInterlocked.Exchange(fChatMonitorBusy, 0);
  TInterlocked.Exchange(fAuxListRefreshBusy, 0);

  if Assigned(fAuxListRefresh) then
    TWaiter.WaitFor([fAuxListRefresh], INFINITE, True);
  if Assigned(fChatMonitorTask) then
    TWaiter.WaitFor([fChatMonitorTask], INFINITE, True);

  FreeAndNil(fPendingAuxSnapshot);
  fAuxListRefresh := nil;
  fChatMonitorTask := nil;

  application.OnActivate := fOrgAppOnActivate;
  ClearListBoxItemData(lbDesktop);
  ClearListBoxItemData(lbShortCuts);
  FreeAndNil(fChatMonitor);
  FreeAndNil(fConfigCache);
  fApps.Free;
  Screen.OnActiveControlChange := nil;
end;

procedure TAppsViewMainFrm.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_F4) and ((GetTickCount64 - fLastFormFocusTick) < cIgnoreF4AfterFocusMs) then
  begin
    Key := 0;
    Exit;
  end;

  if Key = VK_F5 then
    UpdateGui
  else if Key = vk_F1 then
    lbApps.SetFocus
  else if Key = vk_F2 then
    lbExplorer.SetFocus
  else if Key = vk_F3 then
    lbScripts.SetFocus
  else if Key = vk_F4 then
    lbConsole.SetFocus
  else if Key = vk_F6 then
    lbDesktop.SetFocus
  else if Key = vk_F7 then
    lbShortCuts.SetFocus
end;

procedure TAppsViewMainFrm.FormShow(Sender: TObject);
begin
  QueueGuiRefresh;
end;

function TAppsViewMainFrm.GetWnd(lb: TListBox): hwnd;
begin
  Result := 0;
  if lb.Items.Count <> 0 then
    if lb.ItemIndex <> -1 then
      Result := hwnd(lb.Items.Objects[lb.ItemIndex]);
end;

procedure TAppsViewMainFrm.lbAppsClick(Sender: TObject);
begin
  if Sender = lbApps then
    UpdateAppDetail;
end;

procedure TAppsViewMainFrm.lbAppsDblClick(Sender: TObject);
begin
  BringToFrontFocusedApp(Sender as TListBox);
end;

procedure TAppsViewMainFrm.lbAppsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    BringToFrontFocusedApp(Sender as TListBox)
  else if Sender = lbApps then
    UpdateAppDetail;
end;

procedure TAppsViewMainFrm.lbScriptsDblClick(Sender: TObject);
var
  i: Integer;
  fn: String;
begin
  i:= lbScripts.ItemIndex;
  if i = -1 then
    exit;
  fn := CombinePath([GetInstallDir, cScriptsFolderName, lbScripts.Items[i]]);
  if TFile.Exists(fn) then
    TThread.CreateAnonymousThread(
      procedure begin
        exec(fn);
      end).Start;

end;

procedure TAppsViewMainFrm.lbScriptsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    lbScriptsDblClick(sender);
end;

procedure TAppsViewMainFrm.lbDesktopDblClick(Sender: TObject);
begin
  ActivateDesktopItem;
end;

procedure TAppsViewMainFrm.lbDesktopKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    ActivateDesktopItem;
end;

procedure TAppsViewMainFrm.lbShortCutsDblClick(Sender: TObject);
begin
  ActivateShortCutItem;
end;

procedure TAppsViewMainFrm.lbShortCutsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    ActivateShortCutItem;
end;

procedure TAppsViewMainFrm.chkChatNotificationSoundClick(aSender: TObject);
var
  lIniFile: TMemIniFile;
begin
  if Assigned(fChatMonitor) then
    fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;

  gc(lIniFile, TMemIniFile.Create(CombinePath([GetInstallDir, cSettingsFileName]), TEncoding.Utf8, False));
  lIniFile.WriteBool('ChatMonitor', 'SoundEnabled', chkChatNotificationSound.Checked);
  lIniFile.UpdateFile;
end;

procedure TAppsViewMainFrm.MarkFormFocused;
begin
  fLastFormFocusTick := GetTickCount64;
end;

procedure TAppsViewMainFrm.EnsureSharedAppsSnapshotFresh(const aMaxAgeMs: UInt64);
var
  lNowTick: UInt64;
begin
  lNowTick := GetTickCount64;
  if (fSharedAppsSnapshotTick <> 0) and (aMaxAgeMs <> 0)
    and ((lNowTick - fSharedAppsSnapshotTick) < aMaxAgeMs) then
    Exit;

  fApps.Update;
  RebuildSharedAppsSnapshot;
end;

procedure TAppsViewMainFrm.RebuildSharedAppsSnapshot;
var
  lIndex: Integer;
begin
  SetLength(fSharedAppsSnapshot, fApps.Count);
  for lIndex := 0 to fApps.Count - 1 do
  begin
    fSharedAppsSnapshot[lIndex].Wnd := fApps[lIndex].Wnd;
    fSharedAppsSnapshot[lIndex].Caption := fApps[lIndex].Caption;
  end;
  fSharedAppsSnapshotTick := GetTickCount64;
end;

procedure TAppsViewMainFrm.RunChatMonitorSnapshot;
begin
  if Assigned(fChatMonitor) then
    fChatMonitor.ProcessSnapshot(fSharedAppsSnapshot);
end;

procedure TAppsViewMainFrm.OnChatMonitorDone;
begin
  TInterlocked.Exchange(fChatMonitorBusy, 0);
  if (TInterlocked.Exchange(fChatMonitorPending, 0) = 1) and (not (csDestroying in ComponentState)) then
    StartChatMonitorProcessing;
end;

procedure TAppsViewMainFrm.StartChatMonitorProcessing;
begin
  if not Assigned(fChatMonitor) then
    Exit;

  if TInterlocked.CompareExchange(fChatMonitorBusy, 1, 0) <> 0 then
  begin
    TInterlocked.Exchange(fChatMonitorPending, 1);
    Exit;
  end;

  EnsureSharedAppsSnapshotFresh(900);
  fChatMonitorTask := SimpleAsyncCall(RunChatMonitorSnapshot, 'ActiveAppView.ChatMonitor', OnChatMonitorDone);
end;

procedure TAppsViewMainFrm.RestoreItemIndex(lb: TListBox; wnd: hwnd;
  oldItemIndex: integer; const aOldItemCaption: string);
var
  lIndex: integer;
  X: integer;
begin
  if lb.Items.Count = 0 then
  begin
    lb.ItemIndex := -1;
    exit;
  end;
  for X := 0 to lb.Items.Count - 1 do
    if wnd = hwnd(lb.Items.Objects[X]) then
    begin
      lb.ItemIndex := X;
      exit;
    end;

  if (aOldItemCaption <> '') and lb.Sorted then
  begin
    lIndex := FindSortedCaptionIndex(lb.Items, aOldItemCaption);
    if lIndex <> -1 then
    begin
      lb.ItemIndex := lIndex;
      exit;
    end;
  end;

  if (oldItemIndex >= 0) and (oldItemIndex < lb.Items.Count) then
    lb.ItemIndex := oldItemIndex
  else if oldItemIndex >= lb.Items.Count then
    lb.ItemIndex := lb.Items.Count - 1
  else if oldItemIndex < 0 then
    lb.ItemIndex := 0;

end;

function RunMainFormSelfTests(const aArg: string): Integer;
var
  lItems: TStringList;
  lResultIndex: Integer;
begin
  Result := -1;
  if not SameText(aArg, cRestoreItemIndexSelfTestArg) then
    Exit;

  Result := 0;
  lItems := TStringList.Create;
  try
    lItems.Sorted := True;
    lItems.Add('A');
    lItems.Add('C');
    lResultIndex := FindSortedCaptionIndex(lItems, 'Z');
    if lResultIndex <> -1 then
    begin
      Writeln(Format('SELFTEST FAILED: expected missing caption index=-1, got %d', [lResultIndex]));
      Result := 1;
    end;
  finally
    lItems.Free;
  end;
end;

procedure TAppsViewMainFrm.tmrChatMonitorTimer(Sender: TObject);
begin
  StartChatMonitorProcessing;
end;

procedure TAppsViewMainFrm.UpdateAppDetail;
var
  app: TAppInfo;
begin
  if not fApps.TryGetApp(GetWnd(lbApps), app) then
    pnlAppDetails.Visible := False
  else
  begin
    pnlAppDetails.Visible := True;
    imgAppScreenshot.Picture.Graphic := app.Icon;
    edAppCaption.Text := app.caption;
    edAppFileName.Text := app.FileName;
    edCommandLineParams.Text := app.CommandLineParams;
    edPid.Text := app.PID.ToString;
    edRelaunchCommand.Text:= app.RelaunchCommand;
    edAppUserModelID.Text:= app.AppUserModelID;
  end;

end;

procedure TAppsViewMainFrm.UpdateGui;
var
  lApp: TAppInfo;
  lAppsFocusedCaption: string;
  lAppsWnd: hWnd;
  lConsoleFocusedCaption: string;
  lConsoleWnd: hWnd;
  lExcludeMasks: TStringArray;
  lExplorers: TList<TAppInfo>;
  lExplorerFocusedCaption: string;
  lExplorerWnd: hWnd;
  lOldAppsIndex: Integer;
  lOldConsoleIndex: Integer;
  lOldExplorerIndex: Integer;
  lPrefixRules: TPrefixRuleArray;
  lTerminalPatterns: TStringArray;
  lTitle: string;
  lIndex: Integer;
begin
  EnsureSharedAppsSnapshotFresh(250);

  lExcludeMasks := fConfigCache.GetHideMasks(cHideMaskFileName);
  lPrefixRules := fConfigCache.GetPrefixRules(cPrefixMaskFileName);
  lTerminalPatterns := fConfigCache.GetTerminalPatterns(cTerminalPatternsFileName);

  gc(lExplorers, TList<TAppInfo>.Create);

  lOldAppsIndex := lbApps.ItemIndex;
  lAppsFocusedCaption := '';
  if lOldAppsIndex <> -1 then
    lAppsFocusedCaption := lbApps.Items[lOldAppsIndex];
  lAppsWnd := GetWnd(lbApps);

  lOldConsoleIndex := lbConsole.ItemIndex;
  lConsoleFocusedCaption := '';
  if lOldConsoleIndex <> -1 then
    lConsoleFocusedCaption := lbConsole.Items[lOldConsoleIndex];
  lConsoleWnd := GetWnd(lbConsole);

  lbApps.Items.BeginUpdate;
  lbConsole.Items.BeginUpdate;
  try
    lbApps.Items.Clear;
    lbConsole.Items.Clear;
    for lIndex := 0 to fApps.Count - 1 do
    begin
      lApp := fApps[lIndex];

      if (lApp.wnd = application.Handle)
        or (lApp.wnd = self.Handle) then
        Continue;

      if lApp.caption <> '' then
        if (not ExcludeByMask(lApp, lExcludeMasks)) then
          if SameText('explorer.exe', ExtractFileName(lApp.FileName)) then
            lExplorers.Add(lApp)
          else
          begin
            lTitle := Trim(lApp.DisplayCaption);
            CheckPrefixRule(lTitle, lApp, lPrefixRules);
            if IsTerminalApp(lApp.FileName, lTerminalPatterns) then
              lbConsole.Items.AddObject(lTitle, TObject(lApp.wnd))
            else
              lbApps.Items.AddObject(lTitle, TObject(lApp.wnd));
          end;
    end;
  finally
    lbConsole.Items.EndUpdate;
    lbApps.Items.EndUpdate;
  end;
  RestoreItemIndex(lbApps, lAppsWnd, lOldAppsIndex, lAppsFocusedCaption);
  RestoreItemIndex(lbConsole, lConsoleWnd, lOldConsoleIndex, lConsoleFocusedCaption);
  UpdateAppDetail;

  lExplorerWnd := GetWnd(lbExplorer);
  lOldExplorerIndex := lbExplorer.ItemIndex;
  lExplorerFocusedCaption := '';
  if lOldExplorerIndex <> -1 then
    lExplorerFocusedCaption := lbExplorer.Items[lOldExplorerIndex];
  lbExplorer.Items.BeginUpdate;
  try
    lbExplorer.Items.Clear;
    for lApp in lExplorers do
      lbExplorer.Items.addObject(lApp.caption, TObject(lApp.wnd));
  finally
    lbExplorer.Items.EndUpdate;
  end;
  RestoreItemIndex(lbExplorer, lExplorerWnd, lOldExplorerIndex, lExplorerFocusedCaption);

  StartAuxListsRefresh;
end;

end.


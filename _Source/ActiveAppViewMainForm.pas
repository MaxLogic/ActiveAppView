unit ActiveAppViewMainForm;

interface

uses
  System.Classes, System.Generics.Collections, System.SysUtils, System.Variants,
  Winapi.Messages, Winapi.Windows,
  Vcl.Buttons, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms, Vcl.Graphics, Vcl.StdCtrls,
  ActiveAppView.ChatMonitor, ActiveAppViewCore; // Add this new unit,

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
    fOrgAppOnActivate: TNotifyEvent;
    fChatMonitor: TChatMonitor;
    fLastFormFocusTick: UInt64;
    procedure AppOnActivate(Sender: TObject);
    procedure MarkFormFocused;
    procedure UpdateGui;
    procedure UpdateScriptsList;

    procedure BringToFrontFocusedApp(lb: TListBox);
    procedure UpdateAppDetail;
    procedure LoadPrefixRules(l: TObjectList<TStringList>);
    procedure CheckPrefixRule(var s: string; app: TAppInfo; l: TObjectList<TStringList>);
    function ExcludeByMask(app: TAppInfo; l: TStringList): boolean;
    procedure RestoreItemIndex(lb: TListBox; wnd: hwnd; oldItemIndex: integer; const aOldItemCaption: string);
    function GetWnd(lb: TListBox): hwnd;
    procedure ActiveControlChanged(Sender: TObject);
    procedure ClearListBoxItemData(lb: TListBox);
    procedure UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
    function IsTerminalApp(const aFileName: string; aPatterns: TStringList): boolean;
    procedure LoadTerminalPatterns(l: TStringList);
    function TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
    procedure AddDesktopItemsFromFolder(const aFolder: string);
    procedure UpdateDesktopList;
    procedure UpdateShortCutsList;
    function TryParseShortCutValue(const aValue: string; out aTargetPath: string;
      out aParams: string): boolean;
    procedure ActivateDesktopItem;
    procedure ActivateShortCutItem;
    procedure RestoreSelectedItem(lb: TListBox; const aCaption: string);
  public

  end;

var
  AppsViewMainFrm: TAppsViewMainFrm;

implementation

uses
  System.IniFiles, System.IOUtils, System.StrUtils,
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

const
  cShortCutsFileName = 'ShortCuts.txt';
  cTerminalPatternsFileName = 'TerminalPatterns.txt';
  cScriptsFolderName = 'Scripts';
  cHideMaskFileName = 'HideMask.txt';
  cPrefixMaskFileName = 'PrefixMask.txt';
  cSettingsFileName = 'settings.ini';
  cIgnoreF4AfterFocusMs = 200;

resourcestring
  rsShortCutTargetMissing = 'ShortCut target not found: %s';

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
  UpdateGui;
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

function TAppsViewMainFrm.IsTerminalApp(const aFileName: string; aPatterns: TStringList): boolean;
var
  lPattern: string;
begin
  Result := False;
  if (aFileName = '') or (aPatterns = nil) then
    Exit;

  for lPattern in aPatterns do
    if maxLogic.StrUtils.StringMatches(aFileName, lPattern, False) then
      Exit(True);
end;

procedure TAppsViewMainFrm.LoadTerminalPatterns(l: TStringList);
var
  lFileName: string;
  X: integer;
  s: string;
begin
  l.Clear;
  lFileName := CombinePath([GetInstallDir, cTerminalPatternsFileName]);
  if not TFile.Exists(lFileName) then
    Exit;

  l.LoadFromFile(lFileName, TEncoding.Utf8);
  for X := l.Count - 1 downto 0 do
  begin
    s := l[X].Trim;
    if (s = '') or StartsText('#', s) or StartsText(';', s) then
      l.Delete(X)
    else
      l[X] := s;
  end;
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

procedure TAppsViewMainFrm.AddDesktopItemsFromFolder(const aFolder: string);
var
  lDir: string;
  lFile: string;
  lName: string;
  lItem: TListBoxItemData;
begin
  if not DirectoryExists(aFolder) then
    Exit;

  for lDir in TDirectory.GetDirectories(aFolder) do
  begin
    lName := ExtractFileName(lDir);
    if lName = '' then
      lName := lDir;
    lItem := TListBoxItemData.Create(lDir);
    lbDesktop.Items.AddObject(lName, lItem);
  end;

  for lFile in TDirectory.GetFiles(aFolder, '*.*') do
  begin
    lName := ExtractFileName(lFile);
    if lName = '' then
      lName := lFile;
    lItem := TListBoxItemData.Create(lFile);
    lbDesktop.Items.AddObject(lName, lItem);
  end;
end;

procedure TAppsViewMainFrm.UpdateDesktopList;
var
  lUserDesktop: string;
  lPublicDesktop: string;
  lPrevCaption: string;
begin
  if lbDesktop.ItemIndex <> -1 then
    lPrevCaption := lbDesktop.Items[lbDesktop.ItemIndex];

  lbDesktop.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbDesktop);
    if TryGetKnownFolderPath(FOLDERID_Desktop, lUserDesktop) then
      AddDesktopItemsFromFolder(lUserDesktop);
    if TryGetKnownFolderPath(FOLDERID_PublicDesktop, lPublicDesktop) then
      if not SameText(lUserDesktop, lPublicDesktop) then
        AddDesktopItemsFromFolder(lPublicDesktop);
  finally
    lbDesktop.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbDesktop, lPrevCaption);
end;

procedure TAppsViewMainFrm.UpdateShortCutsList;
var
  lFileName: string;
  lPrevCaption: string;
  lLines: TStringList;
  lLine: string;
  lKey: string;
  lValue: string;
  lPos: integer;
  lItem: TListBoxItemData;
  X: integer;
begin
  if lbShortCuts.ItemIndex <> -1 then
    lPrevCaption := lbShortCuts.Items[lbShortCuts.ItemIndex];

  lbShortCuts.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbShortCuts);
    lFileName := CombinePath([GetInstallDir, cShortCutsFileName]);
    if TFile.Exists(lFileName) then
    begin
      gc(lLines, TStringList.Create);
      lLines.LoadFromFile(lFileName, TEncoding.Utf8);
      for X := 0 to lLines.Count - 1 do
      begin
        lLine := lLines[X].Trim;
        if (lLine = '') or StartsText('#', lLine) or StartsText(';', lLine) then
          Continue;
        lPos := Pos('=', lLine);
        if lPos <= 0 then
          Continue;

        lKey := Trim(Copy(lLine, 1, lPos - 1));
        lValue := Trim(Copy(lLine, lPos + 1, MaxInt));
        if (lKey = '') or (lValue = '') then
          Continue;

        lItem := TListBoxItemData.Create(lValue);
        lbShortCuts.Items.AddObject(lKey, lItem);
      end;
    end;
  finally
    lbShortCuts.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbShortCuts, lPrevCaption);
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

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; app: TAppInfo;
  l: TObjectList<TStringList>);
var
  ls: TStringList;
  lCmdParams, lAppUserModelID, lCaption, lFileName: string;
begin
  for ls in l do
  begin
    ls.CaseSensitive:= False;
    lCaption := ls.Values['caption'];
    lFileName := ls.Values['filename'];
    lAppUserModelID:= ls.Values['AppUserModelID'];
    lCmdParams:= ls.Values['CmdParams'];

    if ((lCaption <> '') and maxLogic.StrUtils.StringMatches(app.caption, lCaption, False))
      or ((lFileName <> '') and maxLogic.StrUtils.StringMatches(app.FileName, lFileName, False))
      or ((lAppUserModelID <> '') and maxLogic.StrUtils.StringMatches(app.AppUserModelID, lAppUserModelID, False))
      or ((lCmdParams<> '') and maxLogic.StrUtils.StringMatches(app.CommandLineParams, lCmdParams, False)) then
    begin
      s := ls.Values['prefix'] + ' - ' + s;
      exit;
    end;
  end;
end;

function TAppsViewMainFrm.ExcludeByMask(app: TAppInfo;
  l: TStringList): boolean;
var
  X: integer;
  m: string;
begin
  Result := False;
  // first only the caption
  for X := 0 to l.Count - 1 do
  begin
    m := l[X];
    if maxLogic.StrUtils.StringMatches(app.caption, m, False) then
      exit(True);
  end;

  // if the caption is ok, then go by the file name
  // but note, that retriving the file name takes a bit longer, so if we are lucky, we already excluded the item
  for X := 0 to l.Count - 1 do
  begin
    m := l[X];
    if maxLogic.StrUtils.StringMatches(app.FileName, m, False) then
      exit(True);
  end;
end;

procedure TAppsViewMainFrm.FormActivate(Sender: TObject);
begin
  MarkFormFocused;
  UpdateGui;
end;

procedure TAppsViewMainFrm.FormCreate(Sender: TObject);
var
  lIniFile: TMemIniFile;
begin
  fApps := TAppList.Create;
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
  chkChatNotificationSound.Checked := lIniFile.ReadBool('ChatMonitor', 'SoundEnabled', True);
  chkChatNotificationSound.Enabled := lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
  fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;
  tmrChatMonitor.Interval := lIniFile.ReadInteger('ChatMonitor', 'CheckIntervalSeconds', 5) * 1000;
  tmrChatMonitor.Enabled:= lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
begin
  application.OnActivate := fOrgAppOnActivate;
  ClearListBoxItemData(lbDesktop);
  ClearListBoxItemData(lbShortCuts);
  FreeAndNil(fChatMonitor);
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
  UpdateGui;
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

procedure TAppsViewMainFrm.LoadPrefixRules(l: TObjectList<TStringList>);
var
  l1, l2: TStringList;
  X: integer;
begin
  gc(l1, TStringList.Create);

  l1.LoadFromFile(CombinePath([GetInstallDir, cPrefixMaskFileName]), TEncoding.Utf8);
  for X := 0 to l1.Count - 1 do
  begin
    if l1[X] <> '' then
      if l1[X][1] <> ';' then
      begin
        l2 := TStringList.Create;
        l2.CaseSensitive := False;
        l2.StrictDelimiter:= True;
        l2.Commatext := l1[X];
        l.Add(l2);
      end;
  end;
end;

procedure TAppsViewMainFrm.RestoreItemIndex(lb: TListBox; wnd: hwnd;
  oldItemIndex: integer; const aOldItemCaption: string);
var
  i, X: integer;
  l: TStringList;
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
    gc(l, TStringList.Create);
    l.Assign(lb.Items);
    l.Sorted := True;
    l.find(aOldItemCaption, i);
    if i <> -1 then
    begin
      lb.ItemIndex := i;
      exit;
    end;
  end;

  if oldItemIndex >= lb.Items.Count then
    lb.ItemIndex := lb.Items.Count - 1
  else if oldItemIndex < 0 then
    lb.ItemIndex := 0;

end;

procedure TAppsViewMainFrm.tmrChatMonitorTimer(Sender: TObject);
begin
  if Assigned(fChatMonitor) then
    fChatMonitor.Process;
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
  lOldAppsIndex: integer;
  lOldConsoleIndex: integer;
  lOldExplorerIndex: integer;
  lAppsFocusedCaption: string;
  lConsoleFocusedCaption: string;
  lExplorerFocusedCaption: string;
  lAppsWnd: hwnd;
  lConsoleWnd: hwnd;
  lExplorerWnd: hwnd;
  lApp: TAppInfo;
  lExcludeList: TStringList;
  lPrefixRules: TObjectList<TStringList>;
  lTerminalPatterns: TStringList;
  s: string;
  lExplorers: TList<TAppInfo>;
  X: integer;
begin
  gc(lExcludeList, TStringList.Create);
  gc(lPrefixRules, TObjectList<TStringList>.Create);
  gc(lExplorers, TList<TAppInfo>.Create);
  gc(lTerminalPatterns, TStringList.Create);
  LoadPrefixRules(lPrefixRules);
  LoadTerminalPatterns(lTerminalPatterns);
  lExcludeList.LoadFromFile(CombinePath([GetInstallDir, cHideMaskFileName]));

  // preprocess and remove irrelevant items
  for X := lExcludeList.Count - 1 downto 0 do
    if (lExcludeList[X].Trim = '') or StartsText(';', lExcludeList[X].Trim) then
      lExcludeList.delete(X);

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
    fApps.Update;
    lbApps.Items.Clear;
    lbConsole.Items.Clear;
    for X := 0 to fApps.Count - 1 do
    begin
      lApp := fApps[X];

      if (lApp.wnd = application.Handle)
        or (lApp.wnd = self.Handle) then
        Continue;

      if lApp.caption <> '' then
        if (not ExcludeByMask(lApp, lExcludeList)) then
          if SameText('explorer.exe', ExtractFileName(lApp.FileName)) then
            lExplorers.Add(lApp)
          else
          begin
            s := Trim(lApp.DisplayCaption);
            CheckPrefixRule(s, lApp, lPrefixRules);
            if IsTerminalApp(lApp.FileName, lTerminalPatterns) then
              lbConsole.Items.AddObject(s, TObject(lApp.wnd))
            else
              lbApps.Items.AddObject(s, TObject(lApp.wnd));
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

  UpdateScriptsList;
  UpdateDesktopList;
  UpdateShortCutsList;
end;

procedure TAppsViewMainFrm.UpdateScriptsList;
var
  lExt: string;
  s, lPrevFocused: string;
  i: integer;
  lScriptsDir: string;
begin
  if lbScripts.ItemIndex <> -1 then
    lPrevFocused := lbScripts.Items[lbScripts.ItemIndex];
  lbScripts.Items.BeginUpdate;
  try
    lbScripts.ItemIndex := -1;
    lbScripts.Items.Clear;
    lScriptsDir := CombinePath([GetInstallDir, cScriptsFolderName]);
    for var fn in TDirectory.GetFiles(lScriptsDir, '*.*') do
    begin
      lExt := ExtractFileExt(fn);
      if System.StrUtils.MatchText(lExt, ['.cmd', '.bat', '.ps1', '.exe', '.py']) then
      begin
        s := ExtractFileName(fn);
        i := lbScripts.Items.Add(s);
        if lbScripts.ItemIndex = -1 then
          if SameText(lPrevFocused, s) then
            lbScripts.ItemIndex := i;

      end;
    end;
  finally
    lbScripts.Items.EndUpdate;
  end;

end;

end.


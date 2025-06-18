unit ActiveAppViewMainForm;

interface

uses
  ActiveAppViewCore, ActiveAppView.ChatMonitor, // Add this new unit,
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, vcl.Graphics,
  vcl.Controls, vcl.Forms, vcl.Dialogs, vcl.ExtCtrls, vcl.StdCtrls, generics.collections,
  vcl.Buttons;

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
    labTemplateActiv: TStaticText;
    labTemplateInActiv: TStaticText;
    Splitter2: TSplitter;
    pnlScripts: TPanel;
    labScriptsTitle: TStaticText;
    lbScripts: TListBox;
    pnlScriptsFocusLeft: TPanel;
    pnlScriptsFocusRight: TPanel;
    Splitter3: TSplitter;
    tmrChatMonitor: TTimer;
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
    procedure tmrChatMonitorTimer(Sender: TObject);
  private

    fApps: TAppList;
    fOrgAppOnActivate: TNotifyEvent;
    fChatMonitor: TChatMonitor;
    procedure AppOnActivate(Sender: TObject);
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
  public

  end;

var
  AppsViewMainFrm: TAppsViewMainFrm;

implementation

uses
  AutoFree, bsUtils, maxLogic.AutoStart, srDesktop, StrUtils, maxLogic.StrUtils, IOUtils,
  System.IniFiles, Winapi.MMSystem,
  maxLogic.IOUtils;

{$R *.dfm}

procedure TAppsViewMainFrm.ActiveControlChanged(Sender: TObject);
var
  lActive: TWinControl;
  lPrefix: string;

  procedure UpdatePrefix(st: TStaticText; aEnabled: boolean);
  begin
    if aEnabled then
    begin
      if not startsText(lPrefix, st.caption) then
        st.caption := lPrefix + st.caption;
    end
    else
    begin
      if startsText(lPrefix, st.caption) then
        st.caption := Trim(copy(st.caption, length(lPrefix) + 1, length(st.caption)));
    end;
  end;

var
  lTitles: TArray<TStaticText>;
  lPanels: TArray<TPanel>;
  lIndex: integer;
begin
  lActive := self.ActiveControl;

  lPrefix := copy(labTemplateActiv.caption, 1, 2);
  UpdatePrefix(labAppTitle, lActive = lbApps);
  UpdatePrefix(labExplorerTitle, lActive = lbApps);

  lTitles := [labAppTitle, labExplorerTitle, labScriptsTitle];
  lPanels := [pnlAppFocusLeft, pnlExplorerFocusLeft, pnlScriptsFocusLeft];
  if lActive = lbApps then
    lIndex := 0
  else if lActive = lbExplorer then
    lIndex := 1
  else if lActive = lbScripts then
    lIndex := 2
  else
    lIndex := -1;

  if lindex <> -1 then
  begin
    lTitles[lIndex].Font.Assign(labTemplateActiv.Font);
    lPanels[lIndex].Color := clBlack;
  end;

  for var X := 0 to 2 do
    if X <> lIndex then
    begin
      lTitles[X].Font.Assign(labTemplateInActiv.Font);
      lPanels[X].Color := self.Color;
    end;

  pnlAppsFocusRight.Color := pnlAppFocusLeft.Color;
  pnlExplorerFocusRight.Color := pnlExplorerFocusLeft.Color;
  pnlScriptsFocusRight.Color := pnlScriptsFocusLeft.Color;
end;

procedure TAppsViewMainFrm.AppOnActivate(Sender: TObject);
begin
  UpdateGui;
  if assigned(fOrgAppOnActivate) then
    fOrgAppOnActivate(Sender);
end;

procedure TAppsViewMainFrm.BringToFrontFocusedApp;
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

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; app: TAppInfo;
  l: TObjectList<TStringList>);
var
  ls: TStringList;
  V1, V2: string;
begin
  for ls in l do
  begin
    V1 := ls.Values['caption'];
    V2 := ls.Values['filename'];
    if ((V1 <> '') and maxLogic.StrUtils.StringMatches(app.caption, V1, False))
      or ((V2 <> '') and maxLogic.StrUtils.StringMatches(app.FileName, V2, False)) then
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
  ActiveControlChanged(nil);
  fOrgAppOnActivate := application.OnActivate;
  application.OnActivate := AppOnActivate;

  gc(lIniFile, TMemIniFile.Create(GetInstallDir + 'settings.ini', TEncoding.Utf8, False));
  fChatMonitor := TChatMonitor.Create(lIniFile);
  tmrChatMonitor.Interval := lIniFile.ReadInteger('ChatMonitor', 'CheckIntervalSeconds', 5) * 1000;
  tmrChatMonitor.Enabled:= lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
begin
  application.OnActivate := fOrgAppOnActivate;
  FreeAndNil(fChatMonitor);
  fApps.Free;
  Screen.OnActiveControlChange := nil;
end;

procedure TAppsViewMainFrm.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_F5 then
    UpdateGui
  else if Key = vk_F1 then
    lbApps.SetFocus
  else if Key = vk_F2 then
    lbExplorer.SetFocus
  else if Key = vk_F3 then
    lbScripts.SetFocus
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
  fn := getInstallDir + 'Scripts\'+ lbScripts.Items[i];
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

procedure TAppsViewMainFrm.LoadPrefixRules(l: TObjectList<TStringList>);
var
  l1, l2: TStringList;
  X: integer;
begin
  gc(l1, TStringList.Create);

  l1.LoadFromFile(getInstallDir + 'PrefixMask.txt');
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
  end;

end;

procedure TAppsViewMainFrm.UpdateGui;
var
  lOldItemIndex: integer;
  app: TAppInfo;
  lExcludeList: TStringList;
  lPrefixRules: TObjectList<TStringList>;
  s, lFocusedCaption: string;
  lExplorers: TList<TAppInfo>;
  wnd: hwnd;
begin
  gc(lExcludeList, TStringList.Create);
  gc(lPrefixRules, TObjectList<TStringList>.Create);
  gc(lExplorers, TList<TAppInfo>.Create);
  LoadPrefixRules(lPrefixRules);
  lExcludeList.LoadFromFile(getInstallDir + 'hideMask.txt');

  // preprocess and remove irrelevant items
  for var X := lExcludeList.Count - 1 downto 0 do
    if (lExcludeList[X].Trim = '') or startsText(';', lExcludeList[X].Trim) then
      lExcludeList.delete(X);

  lOldItemIndex := lbApps.ItemIndex;
  if lOldItemIndex <> -1 then
    lFocusedCaption := lbApps.Items[lOldItemIndex];
  wnd := GetWnd(lbApps);
  lbApps.Items.BeginUpdate;
  try
    fApps.Update;
    lbApps.Items.Clear;
    for var X := 0 to fApps.Count - 1 do
    begin
      app := fApps[X];

      if (app.wnd = application.Handle)
        or (app.wnd = self.Handle) then
        Continue;

      if app.caption <> '' then
        if (not ExcludeByMask(app, lExcludeList)) then
          if SameText('explorer.exe', ExtractFileName(app.FileName)) then
            lExplorers.Add(app)
          else
          begin
            s := Trim(app.DisplayCaption);
            CheckPrefixRule(s, app, lPrefixRules);
            lbApps.Items.addObject(s, TObject(app.wnd));
          end;
    end;
  finally
    lbApps.Items.EndUpdate;
  end;
  RestoreItemIndex(lbApps, wnd, lOldItemIndex, lFocusedCaption);
  UpdateAppDetail;

  wnd := GetWnd(lbExplorer);
  lOldItemIndex := lbExplorer.ItemIndex;
  lFocusedCaption := '';
  if lOldItemIndex <> -1 then
    lFocusedCaption := lbExplorer.Items[lOldItemIndex];
  lbExplorer.Items.BeginUpdate;
  try
    lbExplorer.Items.Clear;
    for app in lExplorers do
      lbExplorer.Items.addObject(app.caption, TObject(app.wnd));
  finally
    lbExplorer.Items.EndUpdate;
  end;
  RestoreItemIndex(lbExplorer, wnd, lOldItemIndex, lFocusedCaption);

  UpdateScriptsList;
end;

procedure TAppsViewMainFrm.UpdateScriptsList;
var
  lExt: string;
  s, lPrevFocused: string;
  i: integer;
begin
  if lbScripts.ItemIndex <> -1 then
    lPrevFocused := lbScripts.Items[lbScripts.ItemIndex];
  lbScripts.Items.BeginUpdate;
  try
    lbScripts.ItemIndex := -1;
    lbScripts.Items.Clear;
    for var fn in TDirectory.GetFiles(getInstallDir + 'Scripts', '*.*') do
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


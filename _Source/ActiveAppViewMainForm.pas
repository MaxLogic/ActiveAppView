unit ActiveAppViewMainForm;

interface

uses
  ActiveAppViewCore,
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.StdCtrls, generics.Collections,
  Vcl.Buttons;

type
  TAppsViewMainFrm = class(TForm)
    lbApps: TListBox;
    pnlAppDetails: TPanel;
    pnlAppDetailInfo: TPanel;
    imgAppScreenshot: TImage;
    edAppFileName: TEdit;
    lapAppCaption: TStaticText;
    edAppCaption: TEdit;
    labAppFileName: TStaticText;
    pnlApps: TPanel;
    labAppTitle: TStaticText;
    Splitter1: TSplitter;
    pnlExplorer: TPanel;
    labExplorerTitle: TStaticText;
    lbExplorer: TListBox;
    labTemplateActiv: TStaticText;
    labTemplateInActiv: TStaticText;
    pnlAppFocusLeft: TPanel;
    pnlExplorerFocusLeft: TPanel;
    pnlAppsFocusRight: TPanel;
    pnlExplorerFocusRight: TPanel;
    btnRestartNvda: TBitBtn;
    btnRestartExplorer: TBitBtn;
    btnKillDelphi: TBitBtn;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure lbAppsDblClick(Sender: TObject);
    procedure lbAppsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbAppsClick(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure btnRestartNvdaClick(Sender: TObject);
    procedure btnKillDelphiClick(Sender: TObject);
    procedure btnRestartExplorerClick(Sender: TObject);
  private

    fApps: TAppList;
    procedure UpdateGui;

    procedure BringToFrontFocusedApp(lb: TListBox);
    procedure UpdateAppDetail;
    procedure LoadPrefixRules(l: TObjectList<TStringList>);
    procedure CheckPrefixRule(var s: string; app: TAppInfo; l: TObjectList<TStringList>);
    function ExcludeByMask(app: TAppInfo; l: TStringList): Boolean;
    Procedure RestoreItemIndex(lb: TListBox; wnd: hwnd; oldItemIndex: Integer);
    Function GetWnd(lb: TListBox): hwnd;
    procedure ActiveControlChanged(Sender: TObject);
  public

  end;

var
  AppsViewMainFrm: TAppsViewMainFrm;

implementation

uses
  autoFree, bsUtils, MaxLogic.AutoStart, srDesktop, strUtils, MaxLogic.strUtils, ioUtils,
  MaxLogic.ioUtils;

{$R *.dfm}


procedure TAppsViewMainFrm.ActiveControlChanged(Sender: TObject);
var
  lActive: TWinControl;
  lPrefix: String;

  procedure UpdatePrefix(st: TStaticText; aEnabled: Boolean);
  begin
    if aEnabled then
    begin
      if not startsText(lPrefix, st.Caption) then
        st.Caption := lPrefix + st.Caption;
    end else begin
      if startsText(lPrefix, st.Caption) then
        st.Caption := trim(copy(st.Caption, length(lPrefix) + 1, length(st.Caption)));
    end;
  end;

begin
  lActive := self.ActiveControl;

  lPrefix := copy(labTemplateActiv.Caption, 1, 2);
  UpdatePrefix(labAppTitle, lActive = lbApps);
  UpdatePrefix(labExplorerTitle, lActive = lbApps);

  if lActive = lbApps then
  begin
    labAppTitle.Font.assign(labTemplateActiv.Font);
    pnlAppFocusLeft.Color := clBlack;
  end else begin
    labAppTitle.Font.assign(labTemplateInActiv.Font);
    pnlAppFocusLeft.Color := self.Color;
  end;

  if lActive = lbExplorer then
  begin
    labExplorerTitle.Font.assign(labTemplateActiv.Font);
    pnlExplorerFocusLeft.Color := clBlack;
  end else begin
    labExplorerTitle.Font.assign(labTemplateInActiv.Font);
    pnlExplorerFocusLeft.Color := self.Color;
  end;

  pnlAppsFocusRight.Color := pnlAppFocusLeft.Color;
  pnlExplorerFocusRight.Color := pnlExplorerFocusLeft.Color;
end;

procedure TAppsViewMainFrm.btnKillDelphiClick(Sender: TObject);
begin
  exec(getInstallDir + 'dkill - kill bds.exe.cmd');
end;

procedure TAppsViewMainFrm.btnRestartExplorerClick(Sender: TObject);
begin
  exec(getInstallDir + 'RestartExplorer.cmd');
end;

procedure TAppsViewMainFrm.btnRestartNvdaClick(Sender: TObject);
begin
  exec(getInstallDir + 'restartNvda.cmd');
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
    app.Show;
end;

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; app: TAppInfo;
  l: TObjectList<TStringList>);
var
  ls: TStringList;
  v1, v2: string;
begin
  for ls in l do
  begin
    v1 := ls.Values['caption'];
    v2 := ls.Values['filename'];
    if ((v1 <> '') and MaxLogic.strUtils.StringMatches(app.Caption, v1, false))
      or ((v2 <> '') and MaxLogic.strUtils.StringMatches(app.FileName, v2, false)) then
    begin
      s := ls.Values['prefix'] + ' - ' + s;
      Exit;
    end;
  end;
end;

function TAppsViewMainFrm.ExcludeByMask(app: TAppInfo;
  l: TStringList): Boolean;
var
  x: Integer;
  m: string;
begin
  Result := false;
  // first only the caption
  for x := 0 to l.Count - 1 do
  begin
    m := l[x];
    if m <> '' then
      if m[1] <> ';' then
        if MaxLogic.strUtils.StringMatches(app.Caption, m, false) then
          Exit(true);
  end;

  // if the caption is ok, the go by the file name
  // but note, taht retriving the file name takes a bit longer, so if we are lucky, we already excluded the item
  for x := 0 to l.Count - 1 do
  begin
    m := l[x];
    if m <> '' then
      if m[1] <> ';' then
        if MaxLogic.strUtils.StringMatches(app.FileName, m, false) then
          Exit(true);
  end;
end;

procedure TAppsViewMainFrm.FormActivate(Sender: TObject);
begin
  UpdateGui;
end;

procedure TAppsViewMainFrm.FormCreate(Sender: TObject);
begin
  fApps := TAppList.Create;
  AddToAutoStart;
  Screen.OnActiveControlChange := ActiveControlChanged;
  labAppTitle.height := labTemplateActiv.height;
  labExplorerTitle.height := labTemplateActiv.height;
  ActiveControlChanged(nil);
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
begin
  fApps.Free;
  Screen.OnActiveControlChange := nil;
end;

procedure TAppsViewMainFrm.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_F5 then
    UpdateGui;
  if Key = vk_F1 then
    lbApps.SetFocus
  else if Key = vk_F2 then
    lbExplorer.SetFocus
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

procedure TAppsViewMainFrm.LoadPrefixRules(l: TObjectList<TStringList>);
var
  l1, l2: TStringList;
  x: Integer;
begin
  gc(l1, TStringList.Create);

  l1.LoadFromFile(getInstallDir + 'PrefixMask.txt');
  for x := 0 to l1.Count - 1 do
  begin
    if l1[x] <> '' then
      if l1[x][1] <> ';' then
      begin
        l2 := TStringList.Create;
        l2.commaText := l1[x];
        l.add(l2);
      end;
  end;
end;

procedure TAppsViewMainFrm.RestoreItemIndex(lb: TListBox; wnd: hwnd;
  oldItemIndex: Integer);
var
  x: Integer;
begin
  if lb.Items.Count = 0 then
  begin
    lb.ItemIndex := -1;
    Exit;
  end;
  for x := 0 to lb.Items.Count - 1 do
    if wnd = hwnd(lb.Items.Objects[x]) then
    begin
      lb.ItemIndex := x;
      Exit;
    end;

  if oldItemIndex >= lb.Items.Count then
    lb.ItemIndex := lb.Items.Count - 1
  else if oldItemIndex < 0 then
    lb.ItemIndex := 0;

end;

procedure TAppsViewMainFrm.UpdateAppDetail;
var
  app: TAppInfo;
begin
  if not fApps.TryGetApp(GetWnd(lbApps), app) then
    pnlAppDetails.Visible := false
  else
  begin
    pnlAppDetails.Visible := true;
    imgAppScreenshot.Picture.Graphic := app.Icon;
    edAppCaption.Text := app.Caption;
    edAppFileName.Text := app.FileName;
  end;

end;

procedure TAppsViewMainFrm.UpdateGui;
var
  oldItemIndex, x: Integer;
  app: TAppInfo;
  ExcludeList: TStringList;
  PrefixRules: TObjectList<TStringList>;
  s: string;
  Explorers: TList<TAppInfo>;
  wnd: hwnd;
begin
  gc(ExcludeList, TStringList.Create);
  gc(PrefixRules, TObjectList<TStringList>.Create);
  gc(Explorers, TList<TAppInfo>.Create);
  LoadPrefixRules(PrefixRules);

  oldItemIndex := lbApps.ItemIndex;
  wnd := GetWnd(lbApps);
  lbApps.Items.beginUpdate;
  try
    fApps.update;
    ExcludeList.LoadFromFile(getInstallDir + 'hideMask.txt');
    lbApps.Items.Clear;
    for x := 0 to fApps.Count - 1 do
    begin
      app := fApps[x];

      if (app.wnd = application.Handle)
        or (app.wnd = self.Handle) then
        Continue;

      if app.Caption <> '' then
        if (not ExcludeByMask(app, ExcludeList)) then
          if SameText('explorer.exe', ExtractFileName(app.FileName)) then
            Explorers.add(app)
          else
          begin
            s := trim(app.DisplayCaption);
            CheckPrefixRule(s, app, PrefixRules);
            lbApps.Items.addObject(s, TObject(app.wnd));
          end;
    end;
  finally
    lbApps.Items.endupdate;
  end;
  RestoreItemIndex(lbApps, wnd, oldItemIndex);
  UpdateAppDetail;

  wnd := GetWnd(lbExplorer);
  oldItemIndex := lbExplorer.ItemIndex;
  lbExplorer.Items.beginUpdate;
  try
    lbExplorer.Items.Clear;
    for app in Explorers do
      lbExplorer.Items.addObject(app.Caption, TObject(app.wnd));
  finally
    lbExplorer.Items.endupdate;
  end;
  RestoreItemIndex(lbExplorer, wnd, oldItemIndex);
end;

end.

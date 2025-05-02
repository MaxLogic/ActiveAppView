unit ActiveAppViewCore;

interface

uses
  winApi.Windows, system.Classes, system.SysUtils, generics.collections, maxLogic.FastList, Graphics;

type
  TAppInfo = class
  private
    fFileNameRetrived: boolean;
    fFileName: string;
    FAlife: boolean;
    fWnd: hWnd;
    fIcon: TIcon;

    fCaption: string;
    function GetIcon: TIcon;
    procedure SetAlife(const Value: boolean);
    function GetDisplayCaption: string;
    function GetFileName: string;
  public
    constructor Create(aWnd: hWnd);
    destructor Destroy; override;

    procedure Update;
    procedure ScreenShoot(aBitMap: TBitmap);
    procedure SHOW;

    property Wnd: hWnd read fWnd;
    property caption: string read fCaption;
    property FileName: string read GetFileName;
    property DisplayCaption: string read GetDisplayCaption;
    property Icon: TIcon read GetIcon;
    property Alife: boolean read FAlife write SetAlife;
  end;

  TAppList = class
  private
    fApps: TSortedList<hWnd, TAppInfo>;
    function getApp(aIndex: integer): TAppInfo;
    function GetCount: integer;
  public
    constructor Create;
    destructor Destroy; override;
    function TryGetApp(Wnd: hWnd; out App: TAppInfo): boolean;

    procedure Update;
    procedure Clear;
    property Count: integer read GetCount;
    property Item[aIndex: integer]: TAppInfo read getApp; default;
  end;

implementation

uses
  AutoFree, bsUtils, maxLogic.StrUtils, srDesktop, StrUtils;

{ TAppInfo }

constructor TAppInfo.Create(aWnd: hWnd);
begin
  inherited Create;
  self.fWnd := aWnd;
  FAlife := True;
  Update;
end;

destructor TAppInfo.Destroy;
begin
  if assigned(fIcon) then
    FreeAndNil(fIcon);

  inherited;
end;

function TAppInfo.GetDisplayCaption: string;
begin
  if (fCaption <> '') and (fFileName <> '') then
    Result := fCaption + ' | ' + ExtractFileName(fFileName) + ' (' + fFileName + ')'
  else if fCaption <> '' then
    Result := fCaption
  else if fFileName <> '' then
    Result := ExtractFileName(fFileName) + ' (' + fFileName + ')'
  else
    Result := '';
end;

function TAppInfo.GetFileName: string;
begin
  if not fFileNameRetrived then
  begin
    fFileNameRetrived := True;
    fFileName := srDesktop.GetFileName(Wnd);
  end;
  Result := fFileName;
end;

function TAppInfo.GetIcon: TIcon;
begin
  if not assigned(fIcon) then
  begin
    fIcon := TIcon.Create;
    srDesktop.CopyIconFromWindowHandle(fWnd, fIcon);
  end;
  Result := fIcon;
end;

procedure TAppInfo.ScreenShoot(aBitMap: TBitmap);
begin
  srDesktop.PrintWindow(Wnd, aBitMap);
end;

procedure TAppInfo.SetAlife(const Value: boolean);
begin
  FAlife := Value;
end;

procedure TAppInfo.SHOW;
begin
  if winApi.Windows.IsWindow(Wnd) then
  begin
    // ShowWindow( Wnd, SW_SHOW);
    // r43dWindows.SetWindowPlacement(wnd, @wp);
    TThread.CreateAnonymousThread(procedure begin
        srDesktop.ForceForegroundWindow(Wnd);
      end).start;
  end;
end;

procedure TAppInfo.Update;
begin
  fCaption := srDesktop.GetWinCaption(Wnd);
end;

{ TAppList }

procedure TAppList.Clear;
var
  X: integer;
begin
  for X := 0 to fApps.Count - 1 do
    fApps[X].Free;
  fApps.Clear;
end;

constructor TAppList.Create;
begin
  inherited Create;
  fApps := TSortedList<hWnd, TAppInfo>.Create;
end;

destructor TAppList.Destroy;
begin
  Clear;
  fApps.Free;
  inherited;
end;

function TAppList.getApp(aIndex: integer): TAppInfo;
begin
  Result := fApps[aIndex];
end;

function TAppList.GetCount: integer;
begin
  Result := fApps.Count;
end;

function TAppList.TryGetApp(Wnd: hWnd; out App: TAppInfo): boolean;
var
  i: integer;
begin
  if fApps.find(Wnd, i) then
  begin
    Result := True;
    App := fApps[i];
  end
  else
    Result := False;
end;

procedure TAppList.Update;
var
  l: TWndList;
  Wnd: hWnd;
  App: TAppInfo;
  i, X: integer;
begin
  gc(l, TWndList.Create);
  srDesktop.GetWndList(l);

  // mark all as dead for now...
  for X := 0 to fApps.Count - 1 do
    fApps[X].Alife := False;

  for Wnd in l do
  begin
    if not fApps.find(Wnd, i) then
    begin
      App := TAppInfo.Create(Wnd);
      if App.DisplayCaption <> '' then
        fApps.add(App, Wnd)
      else
        App.Free;
    end
    else
    begin
      fApps[i].Alife := True;
      fApps[i].Update;
    end;
  end;

  // now remove all that are no longer alife
  for X := fApps.Count - 1 downto 0 do
    if not fApps[X].Alife then
    begin
      fApps[X].Free;
      fApps.delete(X);
    end;

end;

end.


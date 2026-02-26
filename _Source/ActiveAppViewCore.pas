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
    fCommandLine: String;
    fCommandLineRetrieved: Boolean;
    fCommandLineParams: String;
    fCommandLineParamsRetrieved: Boolean;
    fAppUserModelID: String;
    fAppUserModelIDRetrieved: Boolean;
    fRelaunchCommand: String;
    fRelaunchCommandRetrieved: Boolean;

    fCaption: string;
    function GetIcon: TIcon;
    procedure SetAlife(const Value: boolean);
    function GetDisplayCaption: string;
    function GetFileName: string;
    function GetCommandLine: String;
    function GetCommandLineParams: String;
    function GetPID: Cardinal;
    function GetAppUserModelID: String;
    function GetRelaunchCommand: String;
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
    property CommandLine: String read GetCommandLine;
    property CommandLineParams: String read GetCommandLineParams;
    property PID: Cardinal read GetPID;

    // Edge PWA specific
    property AppUserModelID: String read GetAppUserModelID;
    property RelaunchCommand: String read GetRelaunchCommand;

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

function RunCoreSelfTests(const aArg: string): Integer;

implementation

uses
  AutoFree, bsUtils, maxLogic.StrUtils, srDesktop, StrUtils;

const
  cCoreCommandLineParamsSelfTestArg = '--self-test-core-command-line-params';

function RunCoreCommandLineParamsSelfTest: Integer;
var
  lActualParams: string;
  lApp: TAppInfo;
begin
  Result := 0;
  lApp := TAppInfo.Create(0);
  try
    lApp.fCommandLineRetrieved := True;
    lApp.fCommandLine := 'C:\Tools\tool.exe'#9'--profile prod';
    lApp.fCommandLineParamsRetrieved := False;
    lActualParams := lApp.CommandLineParams;
    if lActualParams <> '--profile prod' then
    begin
      Writeln(Format(
        'SELFTEST FAILED: core command-line params expected="%s" actual="%s"',
        ['--profile prod', lActualParams]));
      Exit(1);
    end;
  finally
    lApp.Free;
  end;
end;

function RunCoreSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cCoreCommandLineParamsSelfTestArg) then
  begin
    try
      Result := RunCoreCommandLineParamsSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end;
end;

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

function TAppInfo.GetAppUserModelID: String;
begin
  if not fAppUserModelIDRetrieved then
  begin
    fAppUserModelIDRetrieved := True;
    fAppUserModelID := RetrieveAppUserModelID(fWnd);
  end;
  Result := fAppUserModelID;
end;

function TAppInfo.GetCommandLine: String;
var
  lPid: Cardinal;
begin
  if not fCommandLineRetrieved then
  begin
    fCommandLineRetrieved:= True;
    lPid:= RetrievePID(fWnd);
    fCommandLine:= RetrieveCommandLine(lPid);
  end;
  Result:= fCommandLine;
end;

function TAppInfo.GetCommandLineParams: String;
var
  lLen: Integer;
  s: String;
  i: Integer;
begin
  if not fCommandLineParamsRetrieved then
  begin
    fCommandLineParamsRetrieved := True;
    s := Self.CommandLine.Trim;
    if s = '' then
      fCommandLineParams := ''
    else
    begin
      if startsStr('"', s) then
      begin
        i := posEx('"', s, 2);
        if i > 0 then
          Inc(i);
      end
      else
      begin
        i := 1;
        lLen := Length(s);
        while (i <= lLen) and (not CharInSet(s[i], [#9, #10, #13, ' '])) do
          Inc(i);
        if i > lLen then
          i := 0;
      end;

      if i <= 0 then
        fCommandLineParams := ''
      else
      begin
        lLen := Length(s);
        while (i <= lLen) and CharInSet(s[i], [#9, #10, #13, ' ']) do
          Inc(i);
        fCommandLineParams := Copy(s, i, Length(s)).Trim;
      end;
    end;
  end;

  Result := fCommandLineParams;
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
    if srDesktop.isWndValid(Wnd) then
    begin
      fFileName := srDesktop.GetFileName(Wnd);
      fFileNameRetrived := True;
    end;
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

function TAppInfo.GetPID: Cardinal;
begin
  Result:= RetrievePID(fWnd);
end;

function TAppInfo.GetRelaunchCommand: String;
begin
  if not fRelaunchCommandRetrieved then
  begin
    fRelaunchCommandRetrieved := True;
    fRelaunchCommand := RetrieveRelaunchCommand(fWnd);
  end;
  Result := fRelaunchCommand;
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
var
  lWnd: hWnd;
begin
  lWnd := fWnd;
  if winApi.Windows.IsWindow(lWnd) then
  begin
    // ShowWindow( Wnd, SW_SHOW);
    // r43dWindows.SetWindowPlacement(wnd, @wp);
    TThread.CreateAnonymousThread(
      procedure
      begin
        srDesktop.ForceForegroundWindow(lWnd);
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


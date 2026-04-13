program ActiveAppView;

uses
  Winapi.Windows,
  Vcl.Forms,
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
  ActiveAppView.Launcher in 'ActiveAppView.Launcher.pas',
  ActiveAppView.ChatMonitor in 'ActiveAppView.ChatMonitor.pas',
  ActiveAppViewCore in 'ActiveAppViewCore.pas',
  ActiveAppViewMainForm in 'ActiveAppViewMainForm.pas' {AppsViewMainFrm},
  ActiveAppView.SelfTests in 'ActiveAppView.SelfTests.pas',
  MaxLogic.StrUtils in '..\..\myPas\MaxLogic.StrUtils.pas',
  srDeskTop in '..\..\myPas\srDeskTop.pas';

{$R *.res}

const
  cSingleInstanceMutexName = 'Local\ActiveAppView.SingleInstance';

function FindExistingInstanceWindow: HWND;
var
  lClassName: string;
  lCurrentProcessId: DWORD;
  lWindowProcessId: DWORD;
  lWnd: HWND;
begin
  Result := 0;
  lClassName := TAppsViewMainFrm.ClassName;
  lCurrentProcessId := GetCurrentProcessId;
  lWnd := FindWindow(PChar(lClassName), nil);
  while lWnd <> 0 do
  begin
    lWindowProcessId := 0;
    GetWindowThreadProcessId(lWnd, @lWindowProcessId);
    if lWindowProcessId <> lCurrentProcessId then
    begin
      Exit(lWnd);
    end;
    lWnd := FindWindowEx(0, lWnd, PChar(lClassName), nil);
  end;
end;

procedure ActivateExistingInstance;
var
  lExistingWnd: HWND;
  i: Integer;
begin
  lExistingWnd := 0;
  for i := 0 to 20 do
  begin
    lExistingWnd := FindExistingInstanceWindow;
    if lExistingWnd <> 0 then
    begin
      Break;
    end;
    Sleep(100);
  end;

  if lExistingWnd <> 0 then
  begin
    if IsIconic(lExistingWnd) then
    begin
      ShowWindow(lExistingWnd, SW_RESTORE);
    end;
    ForceForegroundWindow(lExistingWnd);
  end;
end;

var
  lLaunchHelperResult: Integer;
  lSelfTestResult: Integer;
  lSingleInstanceMutex: THandle;

begin
  lLaunchHelperResult := RunLauncherHelperFromCommandLine;
  if lLaunchHelperResult <> -1 then
  begin
    Halt(lLaunchHelperResult);
  end;

  lSelfTestResult := RunSelfTests;
  if lSelfTestResult <> -1 then
  begin
    Halt(lSelfTestResult);
  end;

  lSingleInstanceMutex := CreateMutex(nil, False, PChar(cSingleInstanceMutexName));
  if (lSingleInstanceMutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    ActivateExistingInstance;
    CloseHandle(lSingleInstanceMutex);
    Exit;
  end;

  try
    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.CreateForm(TAppsViewMainFrm, AppsViewMainFrm);
    Application.Run;
  finally
    if lSingleInstanceMutex <> 0 then
    begin
      CloseHandle(lSingleInstanceMutex);
    end;
  end;
end.

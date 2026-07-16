program ActiveAppView;

uses
  System.SysUtils,
  Winapi.Windows,
  Vcl.Forms,
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
  ActiveAppView.Launcher in 'ActiveAppView.Launcher.pas',
  ActiveAppView.ChatMonitor in 'ActiveAppView.ChatMonitor.pas',
  ActiveAppView.CaptionOverrideState in 'ActiveAppView.CaptionOverrideState.pas',
  ActiveAppView.CaptionOverrideState.SelfTests in 'ActiveAppView.CaptionOverrideState.SelfTests.pas',
  ActiveAppViewCore in 'ActiveAppViewCore.pas',
  ActiveAppViewMainForm in 'ActiveAppViewMainForm.pas' {AppsViewMainFrm},
  ActiveAppView.SelfTests in 'ActiveAppView.SelfTests.pas',
  ActiveAppView.RenameJournal in 'ActiveAppView.RenameJournal.pas',
  ActiveAppView.RenameJournal.SelfTests in 'ActiveAppView.RenameJournal.SelfTests.pas',
  MaxLogic.MadExcept.AiRunner in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.MadExcept.AiRunner.pas',
  MaxLogic.StrUtils in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.StrUtils.pas',
  MaxLogic.Windows.Identity in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.Windows.Identity.pas',
  maxLogic.Windows.Desktop in '..\..\MaxLogic\MaxLogicFoundation\maxLogic.Windows.Desktop.pas';

{$R *.res}

const
  cSingleInstanceMutexName = 'Local\ActiveAppView.SingleInstance';

function GetSingleInstanceMutexName: string;
begin
  Result := cSingleInstanceMutexName;
  {$IF DEFINED(madExcept) AND DEFINED(DEBUG)}
  if MaxLogic.MadExcept.AiRunner.EnvironmentValueEnablesAiRunner(
    System.SysUtils.GetEnvironmentVariable(MaxLogic.MadExcept.AiRunner.cMadExceptAiRunnerEnvironmentVariable)) then
  begin
    Result := Result + '.AiRunner';
  end;
  {$IFEND}
end;

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
    maxLogic.Windows.Desktop.ForceForegroundWindow(lExistingWnd);
  end;
end;

var
  lLaunchHelperResult: Integer;
  lSelfTestResult: Integer;
  lSingleInstanceMutex: THandle;

begin
  {$IF DEFINED(madExcept) AND DEFINED(DEBUG)}
  MaxLogic.MadExcept.AiRunner.ConfigureFromEnvironment;
  {$IFEND}

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

  lSingleInstanceMutex := CreateMutex(nil, False, PChar(GetSingleInstanceMutexName));
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

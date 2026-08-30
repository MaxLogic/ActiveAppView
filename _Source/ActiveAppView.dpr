program ActiveAppView;

uses
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
  System.SysUtils,
  Winapi.Windows,
  Vcl.Forms,
  MaxLogic.MadExcept.AiRunner in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.MadExcept.AiRunner.pas',
  MaxLogic.StrUtils in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.StrUtils.pas',
  maxLogic.Windows.Desktop in '..\..\MaxLogic\MaxLogicFoundation\maxLogic.Windows.Desktop.pas',
  MaxLogic.Windows.Identity in '..\..\MaxLogic\MaxLogicFoundation\MaxLogic.Windows.Identity.pas',
  ActiveAppView.CaptionOverrideState in 'ActiveAppView.CaptionOverrideState.pas',
  ActiveAppView.CaptionOverrideState.SelfTests in 'ActiveAppView.CaptionOverrideState.SelfTests.pas',
  ActiveAppView.ChatMonitor in 'ActiveAppView.ChatMonitor.pas',
  ActiveAppView.ConfigCache in 'ActiveAppView.ConfigCache.pas',
  ActiveAppView.FocusSound in 'ActiveAppView.FocusSound.pas',
  ActiveAppView.Launcher in 'ActiveAppView.Launcher.pas',
  ActiveAppView.MachineOverview.BoundedProcess in 'ActiveAppView.MachineOverview.BoundedProcess.pas',
  ActiveAppView.MachineOverview.Commands in 'ActiveAppView.MachineOverview.Commands.pas',
  ActiveAppView.MachineOverview.DiskProvider in 'ActiveAppView.MachineOverview.DiskProvider.pas',
  ActiveAppView.MachineOverview.Domain in 'ActiveAppView.MachineOverview.Domain.pas',
  ActiveAppView.MachineOverview.GpuProvider in 'ActiveAppView.MachineOverview.GpuProvider.pas',
  ActiveAppView.MachineOverview.HelpForm in 'ActiveAppView.MachineOverview.HelpForm.pas' {MachineOverviewHelpFrm},
  ActiveAppView.MachineOverview.History in 'ActiveAppView.MachineOverview.History.pas',
  ActiveAppView.MachineOverview.History.SelfTests in 'ActiveAppView.MachineOverview.History.SelfTests.pas',
  ActiveAppView.MachineOverview.HistoryForm in 'ActiveAppView.MachineOverview.HistoryForm.pas' {MachineOverviewHistoryFrm},
  ActiveAppView.MachineOverview.HistoryForm.SelfTests in 'ActiveAppView.MachineOverview.HistoryForm.SelfTests.pas',
  ActiveAppView.MachineOverview.Incidents in 'ActiveAppView.MachineOverview.Incidents.pas',
  ActiveAppView.MachineOverview.Incidents.SelfTests in 'ActiveAppView.MachineOverview.Incidents.SelfTests.pas',
  ActiveAppView.MachineOverview.Layout in 'ActiveAppView.MachineOverview.Layout.pas',
  ActiveAppView.MachineOverview.OptionalProviders.SelfTests in 'ActiveAppView.MachineOverview.OptionalProviders.SelfTests.pas',
  ActiveAppView.MachineOverview.Pipeline in 'ActiveAppView.MachineOverview.Pipeline.pas',
  ActiveAppView.MachineOverview.Presentation in 'ActiveAppView.MachineOverview.Presentation.pas',
  ActiveAppView.MachineOverview.ProcessProvider in 'ActiveAppView.MachineOverview.ProcessProvider.pas',
  ActiveAppView.MachineOverview.Providers in 'ActiveAppView.MachineOverview.Providers.pas',
  ActiveAppView.MachineOverview.SelfTests in 'ActiveAppView.MachineOverview.SelfTests.pas',
  ActiveAppView.MachineOverview.Service in 'ActiveAppView.MachineOverview.Service.pas',
  ActiveAppView.MachineOverview.Settings in 'ActiveAppView.MachineOverview.Settings.pas',
  ActiveAppView.MachineOverview.SystemCollector in 'ActiveAppView.MachineOverview.SystemCollector.pas',
  ActiveAppView.MachineOverview.TemperatureProvider in 'ActiveAppView.MachineOverview.TemperatureProvider.pas',
  ActiveAppView.MachineOverview.Trace in 'ActiveAppView.MachineOverview.Trace.pas',
  ActiveAppView.MachineOverview.Trace.SelfTests in 'ActiveAppView.MachineOverview.Trace.SelfTests.pas',
  ActiveAppView.MachineOverview.Types in 'ActiveAppView.MachineOverview.Types.pas',
  ActiveAppView.MachineOverview.View in 'ActiveAppView.MachineOverview.View.pas',
  ActiveAppView.MachineOverview.WindowsProviders in 'ActiveAppView.MachineOverview.WindowsProviders.pas',
  ActiveAppView.RenameJournal in 'ActiveAppView.RenameJournal.pas',
  ActiveAppView.RenameJournal.SelfTests in 'ActiveAppView.RenameJournal.SelfTests.pas',
  ActiveAppView.SelfTests in 'ActiveAppView.SelfTests.pas',
  ActiveAppViewCore in 'ActiveAppViewCore.pas',
  ActiveAppViewMainForm in 'ActiveAppViewMainForm.pas' {AppsViewMainFrm};

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

program ActiveAppView;

uses
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
  Vcl.Forms,
  ActiveAppViewMainForm in 'ActiveAppViewMainForm.pas' {AppsViewMainFrm},
  ActiveAppViewCore in 'ActiveAppViewCore.pas',
  srDeskTop in '..\..\myPas\srDeskTop.pas',
  MaxLogic.StrUtils in '..\..\myPas\MaxLogic.StrUtils.pas',
  ActiveAppView.ChatMonitor in 'ActiveAppView.ChatMonitor.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TAppsViewMainFrm, AppsViewMainFrm);
  Application.Run;
end.

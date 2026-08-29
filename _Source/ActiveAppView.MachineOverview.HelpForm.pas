unit ActiveAppView.MachineOverview.HelpForm;

interface

uses
  System.Classes,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.Forms, Vcl.StdCtrls;

const
  cMachineOverviewHelpFileName = 'MachineOverviewHelp.txt';

type
  TMachineOverviewHelpFrm = class(TForm)
    btnClose: TButton;
    memHelp: TMemo;
    pnlButtons: TPanel;
    procedure FormShow(aSender: TObject);
  end;

function MachineOverviewHelpPath(const aInstallDirectory: string): string;
function LoadMachineOverviewHelpText(const aFileName: string): string;
procedure ShowMachineOverviewHelp(const aOwner: TComponent;
  const aInstallDirectory: string);

implementation

uses
  System.IOUtils, System.SysUtils,
  AutoFree;

{$R *.dfm}

resourcestring
  rsMachineOverviewHelpUnavailable =
    'Machine Overview help is unavailable.' + sLineBreak + sLineBreak +
    'Expected file: %s';

function MachineOverviewHelpPath(const aInstallDirectory: string): string;
begin
  Result := TPath.Combine(aInstallDirectory, cMachineOverviewHelpFileName);
end;

function LoadMachineOverviewHelpText(const aFileName: string): string;
begin
  try
    if TFile.Exists(aFileName) then
      Result := TFile.ReadAllText(aFileName, TEncoding.UTF8)
    else
      Result := '';
  except
    on Exception do
      Result := '';
  end;
  if Result.Trim.IsEmpty then
    Result := Format(rsMachineOverviewHelpUnavailable, [aFileName]);
end;

procedure ShowMachineOverviewHelp(const aOwner: TComponent;
  const aInstallDirectory: string);
var
  g: TGarbos;
  lForm: TMachineOverviewHelpFrm;
begin
  g := Default(TGarbos);
  GC(lForm, TMachineOverviewHelpFrm.Create(aOwner), g);
  lForm.memHelp.Lines.Text := LoadMachineOverviewHelpText(
    MachineOverviewHelpPath(aInstallDirectory));
  lForm.ShowModal;
end;

procedure TMachineOverviewHelpFrm.FormShow(aSender: TObject);
begin
  memHelp.SelStart := 0;
  memHelp.SelLength := 0;
  if memHelp.CanFocus then
    memHelp.SetFocus;
end;

end.

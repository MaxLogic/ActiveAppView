unit ActiveAppView.MachineOverview.Commands;

interface

uses
  System.Classes,
  ActiveAppView.MachineOverview.Types;

function ResolveMachineOverviewCommand(const aKey: Word;
  const aShift: TShiftState): TMachineOverviewCommand;

implementation

uses
  Winapi.Windows;

function ResolveMachineOverviewCommand(const aKey: Word;
  const aShift: TShiftState): TMachineOverviewCommand;
begin
  Result := TMachineOverviewCommand.None;
  if (aKey = VK_F8) and (aShift = []) then
    Result := TMachineOverviewCommand.FocusPanel
  else if (aKey = VK_F8) and (aShift = [ssShift]) then
    Result := TMachineOverviewCommand.ToggleFullView
  else if (aKey = Ord('E')) and (aShift = [ssCtrl]) then
    Result := TMachineOverviewCommand.ToggleDisplayFrozen
  else if (aKey = Ord('C')) and (aShift = [ssCtrl]) then
    Result := TMachineOverviewCommand.CopySelectedRow
  else if (aKey = Ord('C')) and (aShift = [ssCtrl, ssShift]) then
    Result := TMachineOverviewCommand.CopyFullDiagnostics;
end;

end.

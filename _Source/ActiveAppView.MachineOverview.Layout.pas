unit ActiveAppView.MachineOverview.Layout;

interface

uses
  Vcl.Controls, Vcl.ExtCtrls;

type
  TMachineOverviewControlLayoutState = record
    Control: TControl;
    Visible: Boolean;
    Width: Integer;
  end;

  TMachineOverviewLayoutController = class
  private
    fCapturedControls: TArray<TMachineOverviewControlLayoutState>;
    fFocusControl: TWinControl;
    fFullView: Boolean;
    fMachinePanelAlign: TAlign;
    fMachinePanel: TPanel;
    fMachineSplitter: TSplitter;
    fMachineSplitterVisible: Boolean;
    fMachineSplitterWidth: Integer;
    fNormalPanelWidth: Integer;
    fOtherControls: TArray<TControl>;
    procedure EnterFullView;
    procedure RestoreView;
  public
    constructor Create(const aOtherControls: array of TControl;
      const aMachinePanel: TPanel; const aMachineSplitter: TSplitter;
      const aFocusControl: TWinControl);
    function FullView: Boolean;
    function PanelWidthForPersistence: Integer;
    procedure ToggleFullView;
  end;

implementation

uses
  System.SysUtils;

constructor TMachineOverviewLayoutController.Create(
  const aOtherControls: array of TControl; const aMachinePanel: TPanel;
  const aMachineSplitter: TSplitter; const aFocusControl: TWinControl);
var
  i: Integer;
begin
  inherited Create;
  if not Assigned(aMachinePanel) or not Assigned(aMachineSplitter) or
    not Assigned(aFocusControl) then
    raise EArgumentNilException.Create('Machine Overview layout controls are required');
  fMachinePanel := aMachinePanel;
  fMachineSplitter := aMachineSplitter;
  fFocusControl := aFocusControl;
  fNormalPanelWidth := aMachinePanel.Width;
  SetLength(fOtherControls, Length(aOtherControls));
  for i := 0 to High(aOtherControls) do
  begin
    if not Assigned(aOtherControls[i]) then
      raise EArgumentNilException.Create(
        'Machine Overview captured layout controls are required');
    fOtherControls[i] := aOtherControls[i];
  end;
end;

procedure TMachineOverviewLayoutController.EnterFullView;
var
  lParent: TWinControl;
  i: Integer;
begin
  if fFullView then
    Exit;
  lParent := fMachinePanel.Parent;
  if not Assigned(lParent) then
    raise EInvalidOpException.Create('Machine Overview panel requires a parent');
  SetLength(fCapturedControls, Length(fOtherControls));
  for i := 0 to High(fOtherControls) do
  begin
    fCapturedControls[i].Control := fOtherControls[i];
    fCapturedControls[i].Visible := fOtherControls[i].Visible;
    fCapturedControls[i].Width := fOtherControls[i].Width;
  end;
  fMachinePanelAlign := fMachinePanel.Align;
  fMachineSplitterVisible := fMachineSplitter.Visible;
  fMachineSplitterWidth := fMachineSplitter.Width;
  fNormalPanelWidth := fMachinePanel.Width;
  fFullView := True;
  lParent.DisableAlign;
  try
    for i := 0 to High(fOtherControls) do
      fOtherControls[i].Visible := False;
    fMachineSplitter.Visible := False;
    fMachinePanel.Align := alClient;
  finally
    lParent.EnableAlign;
  end;
  if fFocusControl.CanFocus then
    fFocusControl.SetFocus;
end;

function TMachineOverviewLayoutController.FullView: Boolean;
begin
  Result := fFullView;
end;

function TMachineOverviewLayoutController.PanelWidthForPersistence: Integer;
begin
  if fFullView then
    Result := fNormalPanelWidth
  else
    Result := fMachinePanel.Width;
end;

procedure TMachineOverviewLayoutController.RestoreView;
var
  lParent: TWinControl;
  i: Integer;
begin
  if not fFullView then
    Exit;
  lParent := fMachinePanel.Parent;
  if not Assigned(lParent) then
    raise EInvalidOpException.Create('Machine Overview panel requires a parent');
  fFullView := False;
  lParent.DisableAlign;
  try
    fMachinePanel.Align := fMachinePanelAlign;
    fMachinePanel.Width := fNormalPanelWidth;
    for i := 0 to High(fCapturedControls) do
    begin
      fCapturedControls[i].Control.Width := fCapturedControls[i].Width;
      fCapturedControls[i].Control.Visible := fCapturedControls[i].Visible;
    end;
    fMachineSplitter.Width := fMachineSplitterWidth;
    fMachineSplitter.Visible := fMachineSplitterVisible;
  finally
    lParent.EnableAlign;
  end;
end;

procedure TMachineOverviewLayoutController.ToggleFullView;
begin
  if fFullView then
    RestoreView
  else
    EnterFullView;
end;

end.

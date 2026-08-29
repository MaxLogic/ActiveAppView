unit ActiveAppView.MachineOverview.View;

interface

uses
  Vcl.ComCtrls,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewDisplayController = class
  private
    fFrozen: Boolean;
    fHasLatest: Boolean;
    fHasRendered: Boolean;
    fLatest: TMachineOverviewPresentation;
    fRendered: TMachineOverviewPresentation;
    fView: IMachineOverviewView;
    procedure RenderLatest;
  public
    constructor Create(const aView: IMachineOverviewView);
    procedure Publish(const aPresentation: TMachineOverviewPresentation);
    procedure SetFrozen(const aValue: Boolean);
    function Frozen: Boolean;
    function LastRenderedSequence: UInt64;
    function SelectedRowCopyText: string;
    function FullDiagnosticCopyText: string;
  end;

function CreateMachineOverviewView(
  const aListView: TListView): IMachineOverviewView;

implementation

uses
  System.Classes, System.SysUtils, System.Win.ComObj,
  Winapi.CommCtrl, Winapi.Messages, Winapi.oleacc, Winapi.Windows,
  ActiveAppView.MachineOverview.Presentation;

resourcestring
  rsMachineOverviewListName = 'Machine Overview';

type
  // Delphi 12 imports HWND as a 32-bit remotable record in IAccPropServices.
  // The native Win64 COM ABI passes the pointer-sized HWND value directly.
  IAccPropServicesNative = interface(IUnknown)
    ['{6E26E776-04F0-495D-80E4-3330352E3169}']
    function SetPropValue(var aIdString: Byte; aIdStringLength: LongWord;
      aPropId: TGUID; aValue: OleVariant): HResult; stdcall;
    function SetPropServer(var aIdString: Byte; aIdStringLength: LongWord;
      var aPropIds: TGUID; aPropCount: NativeInt;
      const aServer: IAccPropServer; aScope: AnnoScope): HResult; stdcall;
    function ClearProps(var aIdString: Byte; aIdStringLength: LongWord;
      var aPropIds: TGUID; aPropCount: NativeInt): HResult; stdcall;
    function SetHwndProp(aHandle: HWND; aObjectId: LongWord;
      aChildId: LongWord; aPropId: TGUID; aValue: OleVariant): HResult; stdcall;
    function SetHwndPropStr(aHandle: HWND; aObjectId: LongWord;
      aChildId: LongWord; aPropId: TGUID; aText: PWideChar): HResult; stdcall;
  end;

  TMachineOverviewListViewAdapter = class(TInterfacedObject,
    IMachineOverviewView)
  private
    fDisplayFrozen: Boolean;
    fListView: TListView;
    fOriginalWindowProc: TWndMethod;
    fPresentation: TMachineOverviewPresentation;
    function FindRowIndex(const aRowId: string): NativeInt;
    procedure ListViewWindowProc(var aMessage: TMessage);
    procedure RestoreTopRow(const aRowId: string);
  public
    constructor Create(const aListView: TListView);
    destructor Destroy; override;
    procedure Render(const aPresentation: TMachineOverviewPresentation);
    function SelectedRowId: string;
    procedure SetDisplayFrozen(const aValue: Boolean);
  end;

procedure SetMachineOverviewAccessibleName(const aListView: TListView);
var
  lPropertyServices: IAccPropServicesNative;
begin
  SetWindowText(aListView.Handle, PChar(rsMachineOverviewListName));
  try
    lPropertyServices := CreateComObject(CLSID_AccPropServices) as
      IAccPropServicesNative;
    if lPropertyServices.SetHwndPropStr(aListView.Handle,
      Cardinal(OBJID_CLIENT), CHILDID_SELF, PROPID_ACC_NAME,
      PWideChar(rsMachineOverviewListName)) < 0 then
      OutputDebugString('Machine Overview could not annotate the list accessible name');
  except
    on lException: Exception do
      OutputDebugString(PChar('Machine Overview accessible-name annotation failed: ' +
        lException.Message));
  end;
end;

constructor TMachineOverviewListViewAdapter.Create(const aListView: TListView);
var
  lColumn: TListColumn;
begin
  inherited Create;
  if not Assigned(aListView) then
    raise EArgumentNilException.Create('Machine Overview list view is required');
  fListView := aListView;
  fListView.HideSelection := False;
  fListView.ReadOnly := True;
  fListView.RowSelect := True;
  fListView.ViewStyle := vsReport;
  SetMachineOverviewAccessibleName(fListView);
  fOriginalWindowProc := fListView.WindowProc;
  fListView.WindowProc := ListViewWindowProc;
  fListView.Columns.Clear;
  lColumn := fListView.Columns.Add;
  lColumn.Caption := 'Machine status';
  lColumn.Width := fListView.ClientWidth;
end;

destructor TMachineOverviewListViewAdapter.Destroy;
begin
  if Assigned(fListView) then
    fListView.WindowProc := fOriginalWindowProc;
  inherited Destroy;
end;

function TMachineOverviewListViewAdapter.FindRowIndex(
  const aRowId: string): NativeInt;
var
  i: Integer;
begin
  for i := 0 to High(fPresentation.Rows) do
    if SameText(fPresentation.Rows[i].RowId, aRowId) then
      Exit(i);
  Result := -1;
end;

procedure TMachineOverviewListViewAdapter.ListViewWindowProc(
  var aMessage: TMessage);
begin
  fOriginalWindowProc(aMessage);
  if aMessage.Msg = WM_SETFOCUS then
    NotifyWinEvent(EVENT_OBJECT_FOCUS, fListView.Handle, OBJID_CLIENT,
      CHILDID_SELF);
end;

procedure TMachineOverviewListViewAdapter.Render(
  const aPresentation: TMachineOverviewPresentation);
var
  lColumnWidth: Integer;
  lItem: TListItem;
  lSelectedIndex: NativeInt;
  lSelectedRowId: string;
  lTopIndex: NativeInt;
  lTopRowId: string;
  i: Integer;
begin
  lSelectedRowId := SelectedRowId;
  lTopRowId := '';
  if fListView.HandleAllocated then
  begin
    lTopIndex := SendMessage(fListView.Handle, LVM_GETTOPINDEX, 0, 0);
    if (lTopIndex >= 0) and (lTopIndex <= High(fPresentation.Rows)) then
      lTopRowId := fPresentation.Rows[lTopIndex].RowId;
  end;

  fListView.Items.BeginUpdate;
  try
    for i := 0 to High(aPresentation.Rows) do
    begin
      if i < fListView.Items.Count then
        lItem := fListView.Items[i]
      else
        lItem := fListView.Items.Add;
      lItem.Caption := aPresentation.Rows[i].LabelText + ': ' +
        aPresentation.Rows[i].ValueText;
    end;
    while fListView.Items.Count > Length(aPresentation.Rows) do
      fListView.Items.Delete(fListView.Items.Count - 1);
    fPresentation := aPresentation;
    fPresentation.Rows := Copy(aPresentation.Rows);
    lSelectedIndex := FindRowIndex(lSelectedRowId);
    if (lSelectedIndex < 0) and (fListView.Items.Count > 0) then
      lSelectedIndex := 0;
    if lSelectedIndex >= 0 then
    begin
      fListView.Selected := fListView.Items[lSelectedIndex];
      fListView.Items[lSelectedIndex].Focused := True;
    end;
    if fListView.Columns.Count > 0 then
    begin
      lColumnWidth := fListView.ClientWidth - GetSystemMetrics(SM_CXVSCROLL) - 4;
      if lColumnWidth < 80 then
        lColumnWidth := 80;
      fListView.Columns[0].Width := lColumnWidth;
    end;
  finally
    fListView.Items.EndUpdate;
  end;
  RestoreTopRow(lTopRowId);
end;

procedure TMachineOverviewListViewAdapter.RestoreTopRow(const aRowId: string);
var
  lCurrentTopIndex: NativeInt;
  lItemHeight: NativeInt;
  lScrollDistance: NativeInt;
  lTargetIndex: NativeInt;
begin
  if aRowId.IsEmpty or (not fListView.HandleAllocated) or
    (fListView.Items.Count = 0) then
    Exit;
  lTargetIndex := FindRowIndex(aRowId);
  if lTargetIndex < 0 then
    Exit;
  lCurrentTopIndex := SendMessage(fListView.Handle, LVM_GETTOPINDEX, 0, 0);
  if lCurrentTopIndex = lTargetIndex then
    Exit;
  lItemHeight := fListView.Items[0].DisplayRect(drBounds).Height;
  if lItemHeight <= 0 then
    Exit;
  lScrollDistance := (lTargetIndex - lCurrentTopIndex) * lItemHeight;
  SendMessage(fListView.Handle, LVM_SCROLL, 0, lScrollDistance);
end;

function TMachineOverviewListViewAdapter.SelectedRowId: string;
var
  lIndex: Integer;
begin
  Result := '';
  if not Assigned(fListView.Selected) then
    Exit;
  lIndex := fListView.Selected.Index;
  if (lIndex >= 0) and (lIndex <= High(fPresentation.Rows)) then
    Result := fPresentation.Rows[lIndex].RowId;
end;

procedure TMachineOverviewListViewAdapter.SetDisplayFrozen(
  const aValue: Boolean);
begin
  fDisplayFrozen := aValue;
end;

constructor TMachineOverviewDisplayController.Create(
  const aView: IMachineOverviewView);
begin
  inherited Create;
  if not Assigned(aView) then
    raise EArgumentNilException.Create('Machine Overview view is required');
  fView := aView;
end;

function TMachineOverviewDisplayController.Frozen: Boolean;
begin
  Result := fFrozen;
end;

function TMachineOverviewDisplayController.FullDiagnosticCopyText: string;
begin
  if fHasRendered then
    Result := fRendered.DiagnosticText
  else
    Result := '';
end;

function TMachineOverviewDisplayController.LastRenderedSequence: UInt64;
begin
  if fHasRendered then
    Result := fRendered.Sequence
  else
    Result := 0;
end;

procedure TMachineOverviewDisplayController.Publish(
  const aPresentation: TMachineOverviewPresentation);
begin
  if fHasLatest and (aPresentation.Sequence <= fLatest.Sequence) then
    Exit;
  fLatest := aPresentation;
  fLatest.Rows := Copy(aPresentation.Rows);
  fHasLatest := True;
  if not fFrozen then
    RenderLatest;
end;

procedure TMachineOverviewDisplayController.RenderLatest;
begin
  if not fHasLatest then
    Exit;
  fView.Render(fLatest);
  fRendered := fLatest;
  fRendered.Rows := Copy(fLatest.Rows);
  fHasRendered := True;
end;

function TMachineOverviewDisplayController.SelectedRowCopyText: string;
var
  lRow: TMachineOverviewRow;
begin
  Result := '';
  if fHasRendered and TryFindMachineOverviewRow(fRendered,
    fView.SelectedRowId, lRow) then
    Result := MachineOverviewSelectedRowCopy(lRow);
end;

procedure TMachineOverviewDisplayController.SetFrozen(const aValue: Boolean);
begin
  if fFrozen = aValue then
    Exit;
  fFrozen := aValue;
  fView.SetDisplayFrozen(aValue);
  if not fFrozen and fHasLatest and
    ((not fHasRendered) or (fLatest.Sequence > fRendered.Sequence)) then
    RenderLatest;
end;

function CreateMachineOverviewView(
  const aListView: TListView): IMachineOverviewView;
begin
  Result := TMachineOverviewListViewAdapter.Create(aListView);
end;

end.

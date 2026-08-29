unit ActiveAppView.MachineOverview.HistoryForm;

interface

uses
  System.Classes,
  Winapi.Messages,
  Vcl.ComCtrls, Vcl.Controls, Vcl.ExtCtrls, Vcl.Forms, Vcl.StdCtrls,
  ActiveAppView.MachineOverview.Incidents;

type
  TMachineOverviewIncidentHistoryFilter = (Last24Hours, Last7Days, All);

  TMachineOverviewHistoryFrm = class(TForm)
    btnClose: TButton;
    btnRefresh: TButton;
    cbFilter: TComboBox;
    labFilter: TStaticText;
    labStatus: TStaticText;
    lvIncidents: TListView;
    memDetails: TMemo;
    pnlButtons: TPanel;
    pnlFilter: TPanel;
    splDetails: TSplitter;
    procedure btnRefreshClick(aSender: TObject);
    procedure cbFilterChange(aSender: TObject);
    procedure FormDestroy(aSender: TObject);
    procedure FormShow(aSender: TObject);
    procedure lvIncidentsSelectItem(aSender: TObject; aItem: TListItem;
      aSelected: Boolean);
  private
    fApplyingResults: Boolean;
    fClosing: Boolean;
    fDatabaseFileName: string;
    fIncidents: TArray<TMachineOverviewIncident>;
    fLastApplyThreadId: Cardinal;
    fLastQueryThreadId: Cardinal;
    fLastRefreshSucceeded: Boolean;
    fPendingInitialOpen: Boolean;
    fReferenceUtc: TDateTime;
    fRefreshPending: Boolean;
    fWorker: TThread;
    procedure ApplyQueryResult;
    procedure BeginRefresh(const aInitialOpen: Boolean);
    procedure CloseWorker;
    function CurrentReferenceUtc: TDateTime;
    function FindIncidentIndex(const aStableId: string): Integer;
    procedure RenderIncidents(const aSelectedId, aTopId: string;
      const aSelectNewest: Boolean);
    procedure RestoreTopIncident(const aStableId: string);
    function TopIncidentId: string;
    procedure WMHistoryQueryComplete(var aMessage: TMessage);
      message WM_APP + 146;
  public
    procedure Configure(const aDatabaseFileName: string;
      const aReferenceUtc: TDateTime = 0);
    function IncidentAt(const aIndex: Integer): TMachineOverviewIncident;
    function IncidentCount: Integer;
    function LastApplyThreadId: Cardinal;
    function LastQueryThreadId: Cardinal;
    function RefreshAndWaitForTest(const aInitialOpen: Boolean;
      const aTimeoutMs: Cardinal): Boolean;
    function SelectedIncidentId: string;
    procedure SetFilter(const aFilter: TMachineOverviewIncidentHistoryFilter);
    function StatusText: string;
  end;

function FormatMachineOverviewIncidentDetails(
  const aIncident: TMachineOverviewIncident): string;
function MachineOverviewIncidentHistoryEarliestUtc(
  const aFilter: TMachineOverviewIncidentHistoryFilter;
  const aNowUtc: TDateTime): TDateTime;
function ShouldOpenMachineOverviewIncidentHistory(const aRowId: string): Boolean;
procedure ShowMachineOverviewIncidentHistory(const aOwner: TComponent;
  const aDatabaseFileName: string);

implementation

uses
  System.DateUtils, System.SysUtils,
  Winapi.CommCtrl, Winapi.Windows,
  AutoFree,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.Types;

{$R *.dfm}

resourcestring
  rsIncidentHistoryCount = '%d incidents, newest first.';
  rsIncidentHistoryEmpty = 'No incidents in this period.';
  rsIncidentHistoryLoading = 'Loading incident history...';
  rsIncidentHistoryUnavailable = 'Incident history is temporarily unavailable: %s';

type
  TMachineOverviewIncidentHistoryWorker = class(TThread)
  private
    fDatabaseFileName: string;
    fEarliestUtc: TDateTime;
    fError: string;
    fIncidents: TArray<TMachineOverviewIncident>;
    fPreviousSelectedId: string;
    fPreviousTopId: string;
    fSelectNewest: Boolean;
    fSucceeded: Boolean;
    fTargetWindow: HWND;
    fQueryThreadId: Cardinal;
  protected
    procedure Execute; override;
  public
    constructor Create(const aTargetWindow: HWND;
      const aDatabaseFileName: string; const aEarliestUtc: TDateTime;
      const aPreviousSelectedId, aPreviousTopId: string;
      const aSelectNewest: Boolean);
  end;

constructor TMachineOverviewIncidentHistoryWorker.Create(
  const aTargetWindow: HWND; const aDatabaseFileName: string;
  const aEarliestUtc: TDateTime; const aPreviousSelectedId,
  aPreviousTopId: string; const aSelectNewest: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fTargetWindow := aTargetWindow;
  fDatabaseFileName := aDatabaseFileName;
  fEarliestUtc := aEarliestUtc;
  fPreviousSelectedId := aPreviousSelectedId;
  fPreviousTopId := aPreviousTopId;
  fSelectNewest := aSelectNewest;
end;

procedure TMachineOverviewIncidentHistoryWorker.Execute;
begin
  fQueryThreadId := GetCurrentThreadId;
  fSucceeded := TryLoadMachineOverviewIncidents(fDatabaseFileName,
    fEarliestUtc, 0, fIncidents, fError);
  if not Terminated then
    PostMessage(fTargetWindow, WM_APP + 146, 0, 0);
end;

function IncidentCategoryText(
  const aCategory: TMachineOverviewIncidentCategory): string;
begin
  case aCategory of
    TMachineOverviewIncidentCategory.HighCpu: Result := 'High CPU';
    TMachineOverviewIncidentCategory.HotLogicalProcessors:
      Result := 'Hot logical processors';
    TMachineOverviewIncidentCategory.DpcInterrupt:
      Result := 'DPC or interrupt';
    TMachineOverviewIncidentCategory.ForegroundResponse:
      Result := 'Foreground response';
    TMachineOverviewIncidentCategory.DwmFrames: Result := 'DWM frames';
    TMachineOverviewIncidentCategory.MemoryPressure:
      Result := 'Memory pressure';
    TMachineOverviewIncidentCategory.DiskPressure:
      Result := 'Disk pressure';
    TMachineOverviewIncidentCategory.GpuSaturation:
      Result := 'GPU saturation';
    TMachineOverviewIncidentCategory.ThermalWarning:
      Result := 'Thermal warning';
    TMachineOverviewIncidentCategory.ProviderHealth:
      Result := 'Provider health';
    TMachineOverviewIncidentCategory.PipelineOverload:
      Result := 'Pipeline overload';
    TMachineOverviewIncidentCategory.UserMarked: Result := 'User marked';
  end;
end;

function IncidentOriginText(
  const aOrigin: TMachineOverviewIncidentOrigin): string;
begin
  case aOrigin of
    TMachineOverviewIncidentOrigin.Automatic: Result := 'Automatic';
    TMachineOverviewIncidentOrigin.UserMarked: Result := 'User marked';
  end;
end;

function IncidentSeverityText(
  const aSeverity: TMachineOverviewSeverity): string;
begin
  case aSeverity of
    TMachineOverviewSeverity.Normal: Result := 'Normal';
    TMachineOverviewSeverity.Notice: Result := 'Notice';
    TMachineOverviewSeverity.Warning: Result := 'Warning';
    TMachineOverviewSeverity.Critical: Result := 'Critical';
    TMachineOverviewSeverity.Unavailable: Result := 'Unavailable';
  end;
end;

function IncidentTraceStatusText(
  const aStatus: TMachineOverviewIncidentTraceStatus): string;
begin
  case aStatus of
    TMachineOverviewIncidentTraceStatus.NotRequested:
      Result := 'Not requested';
    TMachineOverviewIncidentTraceStatus.Requested: Result := 'Requested';
    TMachineOverviewIncidentTraceStatus.Captured: Result := 'Captured';
    TMachineOverviewIncidentTraceStatus.Failed: Result := 'Failed';
    TMachineOverviewIncidentTraceStatus.Unavailable: Result := 'Unavailable';
  end;
end;

function IncidentUtcText(const aValue: TDateTime): string;
begin
  if aValue <= 0 then
    Exit('Ongoing');
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', aValue,
    TFormatSettings.Invariant);
end;

procedure AddIncidentContexts(const aLines: TStrings; const aHeading: string;
  const aContexts: TArray<TMachineOverviewIncidentContext>);
var
  lContext: TMachineOverviewIncidentContext;
begin
  aLines.Add(aHeading + ':');
  if Length(aContexts) = 0 then
  begin
    aLines.Add('  None');
    Exit;
  end;
  for lContext in aContexts do
    aLines.Add(Format('  %s | %s | %s',
      [IncidentUtcText(lContext.CapturedAtUtc), lContext.ProviderId,
       lContext.Summary]));
end;

procedure AddIncidentStrings(const aLines: TStrings; const aHeading: string;
  const aValues: TArray<string>);
var
  lValue: string;
begin
  aLines.Add(aHeading + ':');
  if Length(aValues) = 0 then
  begin
    aLines.Add('  None');
    Exit;
  end;
  for lValue in aValues do
    aLines.Add('  ' + lValue);
end;

function FormatMachineOverviewIncidentDetails(
  const aIncident: TMachineOverviewIncident): string;
var
  g: TGarbos;
  lLines: TStringList;
begin
  g := Default(TGarbos);
  GC(lLines, TStringList.Create, g);
  lLines.Add('Summary: ' + aIncident.Summary);
  lLines.Add('Category: ' + IncidentCategoryText(aIncident.Category));
  lLines.Add('Severity: ' + IncidentSeverityText(aIncident.Severity));
  lLines.Add('Origin: ' + IncidentOriginText(aIncident.Origin));
  lLines.Add('Local time: ' + aIncident.LocalDisplayTime);
  lLines.Add('Started UTC: ' + IncidentUtcText(aIncident.StartedAtUtc));
  lLines.Add('Peak UTC: ' + IncidentUtcText(aIncident.PeakAtUtc));
  lLines.Add('Ended UTC: ' + IncidentUtcText(aIncident.EndedAtUtc));
  lLines.Add('Explanation: ' + aIncident.Explanation);
  lLines.Add('Threshold: ' + aIncident.ThresholdText);
  lLines.Add('Peak value: ' + FormatFloat('0.###', aIncident.PeakValue,
    TFormatSettings.Invariant));
  lLines.Add('Provider: ' + aIncident.ProviderId);
  lLines.Add('Provider freshness: ' +
    UIntToStr(aIncident.ProviderFreshnessMs) + ' ms');
  lLines.Add('Trace: ' + IncidentTraceStatusText(aIncident.TraceStatus));
  AddIncidentStrings(lLines, 'Related entities',
    aIncident.RelatedEntityIds);
  AddIncidentStrings(lLines, 'Related executable paths',
    aIncident.RelatedExecutablePaths);
  AddIncidentContexts(lLines, 'Pre-context', aIncident.PreContext);
  AddIncidentContexts(lLines, 'Post-context', aIncident.PostContext);
  Result := lLines.Text.TrimRight;
end;

function MachineOverviewIncidentHistoryEarliestUtc(
  const aFilter: TMachineOverviewIncidentHistoryFilter;
  const aNowUtc: TDateTime): TDateTime;
begin
  Result := 0;
  case aFilter of
    TMachineOverviewIncidentHistoryFilter.Last24Hours:
      Result := IncHour(aNowUtc, -24);
    TMachineOverviewIncidentHistoryFilter.Last7Days:
      Result := IncDay(aNowUtc, -7);
    TMachineOverviewIncidentHistoryFilter.All:
      Result := 0;
  end;
end;

function ShouldOpenMachineOverviewIncidentHistory(
  const aRowId: string): Boolean;
begin
  Result := SameText(aRowId, 'incidents');
end;

procedure TMachineOverviewHistoryFrm.ApplyQueryResult;
var
  lError: string;
  lIncidents: TArray<TMachineOverviewIncident>;
  lPreviousSelectedId: string;
  lPreviousTopId: string;
  lSelectNewest: Boolean;
  lSucceeded: Boolean;
  lWorker: TMachineOverviewIncidentHistoryWorker;
begin
  if not Assigned(fWorker) then
    Exit;
  lWorker := fWorker as TMachineOverviewIncidentHistoryWorker;
  lWorker.WaitFor;
  lError := lWorker.fError;
  lIncidents := Copy(lWorker.fIncidents);
  lPreviousSelectedId := lWorker.fPreviousSelectedId;
  lPreviousTopId := lWorker.fPreviousTopId;
  lSelectNewest := lWorker.fSelectNewest;
  lSucceeded := lWorker.fSucceeded;
  fLastQueryThreadId := lWorker.fQueryThreadId;
  FreeAndNil(fWorker);
  fLastApplyThreadId := GetCurrentThreadId;
  fLastRefreshSucceeded := lSucceeded;

  if fRefreshPending and (not fClosing) then
  begin
    fRefreshPending := False;
    BeginRefresh(fPendingInitialOpen);
    fPendingInitialOpen := False;
    Exit;
  end;
  if not lSucceeded then
  begin
    labStatus.Caption := Format(rsIncidentHistoryUnavailable, [lError]);
    Exit;
  end;
  fIncidents := lIncidents;
  RenderIncidents(lPreviousSelectedId, lPreviousTopId, lSelectNewest);
  if Length(fIncidents) = 0 then
    labStatus.Caption := rsIncidentHistoryEmpty
  else
    labStatus.Caption := Format(rsIncidentHistoryCount,
      [Length(fIncidents)]);
end;

procedure TMachineOverviewHistoryFrm.BeginRefresh(
  const aInitialOpen: Boolean);
var
  lEarliestUtc: TDateTime;
  lFilter: TMachineOverviewIncidentHistoryFilter;
begin
  if fClosing then
    Exit;
  if Assigned(fWorker) then
  begin
    fRefreshPending := True;
    fPendingInitialOpen := fPendingInitialOpen or aInitialOpen;
    Exit;
  end;
  if (cbFilter.ItemIndex < Ord(Low(TMachineOverviewIncidentHistoryFilter))) or
    (cbFilter.ItemIndex > Ord(High(TMachineOverviewIncidentHistoryFilter))) then
    cbFilter.ItemIndex := Ord(TMachineOverviewIncidentHistoryFilter.Last24Hours);
  lFilter := TMachineOverviewIncidentHistoryFilter(cbFilter.ItemIndex);
  lEarliestUtc := MachineOverviewIncidentHistoryEarliestUtc(lFilter,
    CurrentReferenceUtc);
  labStatus.Caption := rsIncidentHistoryLoading;
  fLastRefreshSucceeded := False;
  fWorker := TMachineOverviewIncidentHistoryWorker.Create(Handle,
    fDatabaseFileName, lEarliestUtc, SelectedIncidentId, TopIncidentId,
    aInitialOpen);
  fWorker.Start;
end;

procedure TMachineOverviewHistoryFrm.btnRefreshClick(aSender: TObject);
begin
  BeginRefresh(False);
end;

procedure TMachineOverviewHistoryFrm.cbFilterChange(aSender: TObject);
begin
  BeginRefresh(False);
end;

procedure TMachineOverviewHistoryFrm.CloseWorker;
begin
  if not Assigned(fWorker) then
    Exit;
  fWorker.Terminate;
  fWorker.WaitFor;
  FreeAndNil(fWorker);
end;

procedure TMachineOverviewHistoryFrm.Configure(const aDatabaseFileName: string;
  const aReferenceUtc: TDateTime);
begin
  fDatabaseFileName := aDatabaseFileName;
  fReferenceUtc := aReferenceUtc;
end;

function TMachineOverviewHistoryFrm.CurrentReferenceUtc: TDateTime;
begin
  if fReferenceUtc > 0 then
    Result := fReferenceUtc
  else
    Result := TTimeZone.Local.ToUniversalTime(Now);
end;

function TMachineOverviewHistoryFrm.FindIncidentIndex(
  const aStableId: string): Integer;
var
  i: Integer;
begin
  if aStableId.IsEmpty then
    Exit(-1);
  for i := 0 to High(fIncidents) do
    if SameText(fIncidents[i].StableId, aStableId) then
      Exit(i);
  Result := -1;
end;

procedure TMachineOverviewHistoryFrm.FormDestroy(aSender: TObject);
begin
  fClosing := True;
  CloseWorker;
end;

procedure TMachineOverviewHistoryFrm.FormShow(aSender: TObject);
begin
  BeginRefresh(True);
  if lvIncidents.CanFocus then
    lvIncidents.SetFocus;
end;

function TMachineOverviewHistoryFrm.IncidentAt(
  const aIndex: Integer): TMachineOverviewIncident;
begin
  if (aIndex < 0) or (aIndex > High(fIncidents)) then
    raise EArgumentOutOfRangeException.Create('Incident index is out of range');
  Result := fIncidents[aIndex];
end;

function TMachineOverviewHistoryFrm.IncidentCount: Integer;
begin
  Result := Length(fIncidents);
end;

function TMachineOverviewHistoryFrm.LastApplyThreadId: Cardinal;
begin
  Result := fLastApplyThreadId;
end;

function TMachineOverviewHistoryFrm.LastQueryThreadId: Cardinal;
begin
  Result := fLastQueryThreadId;
end;

procedure TMachineOverviewHistoryFrm.lvIncidentsSelectItem(aSender: TObject;
  aItem: TListItem; aSelected: Boolean);
begin
  if fApplyingResults then
    Exit;
  if aSelected and Assigned(aItem) and (aItem.Index >= 0) and
    (aItem.Index <= High(fIncidents)) then
    memDetails.Text := FormatMachineOverviewIncidentDetails(
      fIncidents[aItem.Index])
  else if not Assigned(lvIncidents.Selected) then
    memDetails.Clear;
end;

function TMachineOverviewHistoryFrm.RefreshAndWaitForTest(
  const aInitialOpen: Boolean; const aTimeoutMs: Cardinal): Boolean;
var
  lWaitResult: Cardinal;
begin
  BeginRefresh(aInitialOpen);
  if not Assigned(fWorker) then
    Exit(False);
  lWaitResult := WaitForSingleObject(fWorker.Handle, aTimeoutMs);
  if lWaitResult <> WAIT_OBJECT_0 then
    Exit(False);
  ApplyQueryResult;
  Result := fLastRefreshSucceeded;
end;

procedure TMachineOverviewHistoryFrm.RenderIncidents(const aSelectedId,
  aTopId: string; const aSelectNewest: Boolean);
var
  lIncident: TMachineOverviewIncident;
  lItem: TListItem;
  lSelectedIndex: Integer;
begin
  fApplyingResults := True;
  lvIncidents.Items.BeginUpdate;
  try
    lvIncidents.Items.Clear;
    for lIncident in fIncidents do
    begin
      lItem := lvIncidents.Items.Add;
      lItem.Caption := lIncident.LocalDisplayTime;
      lItem.SubItems.Add(IncidentSeverityText(lIncident.Severity));
      lItem.SubItems.Add(lIncident.Summary);
    end;
    lSelectedIndex := FindIncidentIndex(aSelectedId);
    if (lSelectedIndex < 0) and aSelectNewest and
      (lvIncidents.Items.Count > 0) then
      lSelectedIndex := 0;
    if lSelectedIndex >= 0 then
    begin
      lvIncidents.Selected := lvIncidents.Items[lSelectedIndex];
      lvIncidents.Items[lSelectedIndex].Focused := True;
    end;
  finally
    lvIncidents.Items.EndUpdate;
    fApplyingResults := False;
  end;
  RestoreTopIncident(aTopId);
  if Assigned(lvIncidents.Selected) then
    memDetails.Text := FormatMachineOverviewIncidentDetails(
      fIncidents[lvIncidents.Selected.Index])
  else
    memDetails.Clear;
end;

procedure TMachineOverviewHistoryFrm.RestoreTopIncident(
  const aStableId: string);
var
  lIndex: Integer;
begin
  lIndex := FindIncidentIndex(aStableId);
  if (lIndex >= 0) and (lIndex < lvIncidents.Items.Count) then
    lvIncidents.Items[lIndex].MakeVisible(False);
end;

function TMachineOverviewHistoryFrm.SelectedIncidentId: string;
var
  lIndex: Integer;
begin
  Result := '';
  if not Assigned(lvIncidents.Selected) then
    Exit;
  lIndex := lvIncidents.Selected.Index;
  if (lIndex >= 0) and (lIndex <= High(fIncidents)) then
    Result := fIncidents[lIndex].StableId;
end;

procedure TMachineOverviewHistoryFrm.SetFilter(
  const aFilter: TMachineOverviewIncidentHistoryFilter);
begin
  cbFilter.ItemIndex := Ord(aFilter);
end;

procedure ShowMachineOverviewIncidentHistory(const aOwner: TComponent;
  const aDatabaseFileName: string);
var
  g: TGarbos;
  lForm: TMachineOverviewHistoryFrm;
begin
  g := Default(TGarbos);
  GC(lForm, TMachineOverviewHistoryFrm.Create(aOwner), g);
  lForm.Configure(aDatabaseFileName);
  lForm.ShowModal;
end;

function TMachineOverviewHistoryFrm.StatusText: string;
begin
  Result := labStatus.Caption;
end;

function TMachineOverviewHistoryFrm.TopIncidentId: string;
var
  lIndex: NativeInt;
begin
  Result := '';
  if (not lvIncidents.HandleAllocated) or (lvIncidents.Items.Count = 0) then
    Exit;
  lIndex := SendMessage(lvIncidents.Handle, LVM_GETTOPINDEX, 0, 0);
  if (lIndex >= 0) and (lIndex <= High(fIncidents)) then
    Result := fIncidents[lIndex].StableId;
end;

procedure TMachineOverviewHistoryFrm.WMHistoryQueryComplete(
  var aMessage: TMessage);
begin
  ApplyQueryResult;
  aMessage.Result := 0;
end;

end.

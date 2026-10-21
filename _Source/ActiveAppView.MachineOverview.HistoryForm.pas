unit ActiveAppView.MachineOverview.HistoryForm;

interface

uses
  System.Classes, System.SysUtils, System.Types,
  Winapi.Messages,
  Vcl.ComCtrls, Vcl.Controls, Vcl.ExtCtrls, Vcl.Forms, Vcl.StdCtrls,
  ActiveAppView.MachineOverview.History, ActiveAppView.MachineOverview.Incidents;

type
  TMachineOverviewIncidentHistoryFilter = (Last24Hours, Last7Days, All);

  TMachineOverviewHistoryFrm = class(TForm)
    btnClose: TButton;
    btnCopyEvidence: TButton;
    btnRefresh: TButton;
    cbFilter: TComboBox;
    labFilter: TStaticText;
    labStatus: TStaticText;
    labEvidence: TStaticText;
    lvEvidence: TListView;
    lvIncidents: TListView;
    memDetails: TMemo;
    pnlButtons: TPanel;
    pnlFilter: TPanel;
    gridDetails: TGridPanel;
    procedure btnCopyEvidenceClick(aSender: TObject);
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
    fEvidenceWorker: TThread;
    fEvidenceRequest: Cardinal;
    fRequestedEvidenceKey: string;
    fHealth: TMachineOverviewHistoryHealth;
    fLastEvidenceQueryThreadId: Cardinal;
    fEvidenceNamedCount, fIncidentNamedCount: Integer;
    fEvidenceRowNames: TArray<string>;
    procedure ApplyEvidenceResult;
    procedure BeginEvidenceRefresh;
    procedure StartEvidenceWorker;
    procedure RenderEvidence;
    procedure SetEvidenceCaption(const aState: string);
    procedure RefreshAccessibleNames;
    procedure RenderDetails(const aIndex: Integer; const aEvidenceStateLine: string = '');
    procedure WMHistoryEvidenceComplete(var aMessage: TMessage);
      message WM_APP + 147;
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
  protected
    procedure CMShowingChanged(var aMessage: TMessage); message CM_SHOWINGCHANGED;
    function InitialWorkArea: TRect; virtual;
    procedure DoAfterMonitorDpiChanged(aOldDpi, aNewDpi: Integer); override;
  public
    destructor Destroy; override;
    procedure ScaleForPPI(aNewPpi: Integer); override;
    function LastEvidenceQueryThreadId: Cardinal;
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
  const aIncident: TMachineOverviewIncident): string; overload;
function FormatMachineOverviewIncidentDetails(const aIncident: TMachineOverviewIncident;
  const aTimeZoneName: string; const aUtcToLocal: TFunc<TDateTime, TDateTime>): string; overload;
function FormatMachineOverviewHistoryHealth(const aHealth: TMachineOverviewHistoryHealth;
  const aNowUtc: TDateTime): string;
function MachineOverviewIncidentHistoryEarliestUtc(
  const aFilter: TMachineOverviewIncidentHistoryFilter;
  const aNowUtc: TDateTime): TDateTime;
function ShouldOpenMachineOverviewIncidentHistory(const aRowId: string): Boolean;
procedure ShowMachineOverviewIncidentHistory(const aOwner: TComponent;
  const aDatabaseFileName: string);

implementation

uses
  System.DateUtils, System.Math, System.Win.ComObj,
  Winapi.CommCtrl, Winapi.oleacc, Winapi.Windows,
  Vcl.Clipbrd,
  AutoFree,
  ActiveAppView.MachineOverview.Evidence,
  ActiveAppView.MachineOverview.Types;

{$R *.dfm}

resourcestring
  rsIncidentHistoryCount = '%d incidents, newest first.';
  rsIncidentHistoryEmpty = 'No incidents in this period.';
  rsIncidentHistoryLoading = 'Loading incident history...';
  rsIncidentHistoryUnavailable = 'Incident history is temporarily unavailable: %s';
  rsEvidenceLoading = 'Loading evidence...';
  rsEvidenceLoadFailed = 'Evidence could not be read (recorded data unavailable: %s)';
  rsEvidenceLoadingText = 'Evidence: loading...';
  rsEvidenceCopied = 'Evidence copied to the clipboard.';
  rsEvidenceCopyFailed = 'Could not copy evidence to the clipboard: %s';
  rsEvidenceNoSelection = 'no incident selected';
  rsEvidenceListsShortened = 'lists shortened';
  rsEvidenceDetailsName = 'Incident details and evidence export';
  rsFilterName = 'Show incidents';
  rsEvidenceExportHeader = 'ActiveAppView incident evidence. Times are local with their UTC offset; Z times are authoritative.';
  rsEvidenceExportIncident = 'Incident: %s | %s | %s | %s | key %s';
  rsEvidenceExportTimes = 'Started %s; peak %s value %s; %s';
  rsEvidenceEnded = 'Ended: %s';
  rsEvidenceEndedUnknown = 'Ended: not recorded (collection stopped)';
  rsEvidenceOngoing = 'Ongoing';
  rsEvidenceExportThreshold = 'Threshold: %s';
  rsEvidenceExportTrace = 'Detailed trace: %s.';
  rsEvidenceTraceOnset = 'Trace starts after detection and does not include the onset.';
  rsEvidenceRawReference = 'Raw evidence: %s, table incident_evidence, incident_key %s';
  rsHealthHeading = 'Recording health: %s; last write %s';
  rsHealthStorage = 'Storage: %s of %s MB used; WAL %s MB not counted; file %s MB; evidence %s MB; %s. %s';
  rsHealthNever = 'never';
  rsHealthSecondsAgo = '%d s ago';
  rsHealthMinutesAgo = '%d min ago';
  rsHealthRange = '%s: oldest %s; newest %s';
  rsHealthIncidents = 'Incidents';
  rsHealthEvidence = 'Evidence';
  rsHealthProcess = 'Newest process sample: %s';
  rsHealthCounts = 'Totals: evidence trimmed %d; incidents deleted %d; samples deleted %d; records dropped this session %d';
  rsHealthSampling = 'Sampling: processes %d ms; system %d ms; commit %d ms; %d logical processors; provider status: %s';
  rsHealthPaths = 'Database: %s'#13#10'Pre-migration backup: %s';
  rsHealthError = 'Error: %s';
  rsStorageWithinBudget = 'Within budget';
  rsStorageTrimming = 'Trimming';
  rsStorageFloorBreached = 'Minimum retention exceeds the storage budget';
  rsStorageOverBudget = 'Over budget';
  rsStorageMigrationBlocked = 'Migration blocked';
  rsIncidentListName = 'Recorded incidents';
  rsEvidenceListName = 'Measured incident evidence';

type
  // As in our overview adapter, use the native HWND ABI on Win64. The Delphi
  // oleacc import incorrectly declares HWND as a 32-bit remotable record.
  IHistoryAccPropServices = interface(IUnknown)
    ['{6E26E776-04F0-495D-80E4-3330352E3169}']
    function SetPropValue(var aId: Byte; aLength: LongWord; aProperty: TGUID;
      aValue: OleVariant): HResult; stdcall;
    function SetPropServer(var aId: Byte; aLength: LongWord; var aProperties: TGUID;
      aCount: NativeInt; const aServer: IAccPropServer; aScope: AnnoScope): HResult; stdcall;
    function ClearProps(var aId: Byte; aLength: LongWord; var aProperties: TGUID;
      aCount: NativeInt): HResult; stdcall;
    function SetHwndProp(aWindow: HWND; aObjectId, aChildId: LongWord;
      aProperty: TGUID; aValue: OleVariant): HResult; stdcall;
    function SetHwndPropStr(aWindow: HWND; aObjectId, aChildId: LongWord;
      aProperty: TGUID; aValue: PWideChar): HResult; stdcall;
    function SetHwndPropServer(aWindow: HWND; aObjectId, aChildId: LongWord;
      var aProperties: TGUID; aCount: NativeInt; const aServer: IAccPropServer;
      aScope: AnnoScope): HResult; stdcall;
    function ClearHwndProps(aWindow: HWND; aObjectId, aChildId: LongWord;
      var aProperties: TGUID; aCount: NativeInt): HResult; stdcall;
  end;

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
    fHealth: TMachineOverviewHistoryHealth;
    fCompleted: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const aTargetWindow: HWND;
      const aDatabaseFileName: string; const aEarliestUtc: TDateTime;
      const aPreviousSelectedId, aPreviousTopId: string;
      const aSelectNewest: Boolean);
  end;

  TMachineOverviewIncidentEvidenceWorker = class(TThread)
  public
    DatabaseFileName, IncidentKey, Error: string;
    Evidence: TMachineOverviewIncidentEvidence;
    Request, QueryThreadId: Cardinal;
    TargetWindow: HWND;
    Succeeded, Completed: Boolean;
    constructor Create(const aTarget: HWND; const aDatabase, aKey: string; const aRequest: Cardinal);
    procedure Execute; override;
  end;

procedure SetHistoryAccessibleName(const aControl: TWinControl; const aName: string);
var
  lServices: IHistoryAccPropServices;
begin
  lServices := CreateComObject(CLSID_AccPropServices) as IHistoryAccPropServices;
  OleCheck(lServices.SetHwndPropStr(aControl.Handle, Cardinal(OBJID_CLIENT), CHILDID_SELF,
    PROPID_ACC_NAME, PWideChar(aName)));
end;

procedure UpdateHistoryAccessibleRows(const aList: TListView; const aName: string;
  var aPreviousCount: Integer; const aRowNames: TArray<string> = nil);
var
  lServices: IHistoryAccPropServices;
  lProperty: TGUID;
  lText: string;
  i: Integer;
begin
  lServices := CreateComObject(CLSID_AccPropServices) as IHistoryAccPropServices;
  OleCheck(lServices.SetHwndPropStr(aList.Handle, Cardinal(OBJID_CLIENT), CHILDID_SELF,
    PROPID_ACC_NAME, PWideChar(aName)));
  for i := 0 to aList.Items.Count - 1 do
  begin
    lText := aList.Items[i].Caption + '; ' +
      StringReplace(aList.Items[i].SubItems.Text.TrimRight, sLineBreak, '; ', [rfReplaceAll]);
    if i < Length(aRowNames) then
      lText := aRowNames[i]
    else if aList.Items[i].SubItems.Count = 0 then
      lText := aList.Items[i].Caption;
    OleCheck(lServices.SetHwndPropStr(aList.Handle, Cardinal(OBJID_CLIENT), i + 1,
      PROPID_ACC_NAME, PWideChar(lText)));
  end;
  lProperty := PROPID_ACC_NAME;
  for i := aList.Items.Count to aPreviousCount - 1 do
    OleCheck(lServices.ClearHwndProps(aList.Handle, Cardinal(OBJID_CLIENT), i + 1, lProperty, 1));
  aPreviousCount := aList.Items.Count;
end;

constructor TMachineOverviewIncidentEvidenceWorker.Create(const aTarget: HWND;
  const aDatabase, aKey: string; const aRequest: Cardinal);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  TargetWindow := aTarget;
  DatabaseFileName := aDatabase;
  IncidentKey := aKey;
  Request := aRequest;
end;

procedure TMachineOverviewIncidentEvidenceWorker.Execute;
begin
  QueryThreadId := GetCurrentThreadId;
  Succeeded := TryLoadMachineOverviewIncidentEvidence(DatabaseFileName, IncidentKey, Evidence, Error);
  Completed := True;
  if not Terminated then
    PostMessage(TargetWindow, WM_APP + 147, 0, 0);
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
var
  lHealthError: string;
begin
  fQueryThreadId := GetCurrentThreadId;
  fSucceeded := TryLoadMachineOverviewIncidents(fDatabaseFileName,
    fEarliestUtc, 0, fIncidents, fError);
  if not TryLoadMachineOverviewHistoryHealth(fDatabaseFileName, fHealth, lHealthError) then
  begin
    if not fError.IsEmpty then
      fError := fError + '. ';
    fError := fError + lHealthError;
  end;
  fCompleted := True;
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

function FormatIncidentDetails(const aIncident: TMachineOverviewIncident;
  const aEvidenceStateLine: string; const aUtcToLocal: TFunc<TDateTime, TDateTime>): string;
var
  g: TGarbos;
  lLines: TStringList;
  lEnded: string;
begin
  g := Default(TGarbos);
  GC(lLines, TStringList.Create, g);
  lLines.Add(rsEvidenceExportHeader);
  lLines.Add(Format(rsEvidenceExportIncident, [aIncident.Summary, IncidentCategoryText(aIncident.Category),
    IncidentSeverityText(aIncident.Severity), IncidentOriginText(aIncident.Origin), aIncident.StableId]));
  lEnded := Format(rsEvidenceEnded, [MachineOverviewEvidenceTimeText(aIncident.EndedAtUtc, aUtcToLocal)]);
  if aIncident.EndedAtUtc <= 0 then
  begin
    if aIncident.Evidence.State = TMachineOverviewEvidenceState.Partial then
      lEnded := rsEvidenceEndedUnknown
    else
      lEnded := Format(rsEvidenceEnded, [rsEvidenceOngoing]);
  end;
  lLines.Add(Format(rsEvidenceExportTimes, [MachineOverviewEvidenceTimeText(aIncident.StartedAtUtc, aUtcToLocal),
    MachineOverviewEvidenceTimeText(aIncident.PeakAtUtc, aUtcToLocal),
    FormatFloat('0.###', aIncident.PeakValue, TFormatSettings.Invariant), lEnded]));
  lLines.Add(Format(rsEvidenceExportThreshold, [aIncident.ThresholdText]));
  if aEvidenceStateLine.IsEmpty then
    lLines.Add(MachineOverviewEvidenceText(aIncident.Evidence, aUtcToLocal))
  else
    lLines.Add(aEvidenceStateLine);
  lLines.Add(Format(rsEvidenceExportTrace, [IncidentTraceStatusText(aIncident.TraceStatus)]));
  if aIncident.TraceStatus = TMachineOverviewIncidentTraceStatus.Captured then
    lLines.Add(rsEvidenceTraceOnset);
  Result := lLines.Text.TrimRight;
end;

function FormatMachineOverviewIncidentDetails(
  const aIncident: TMachineOverviewIncident): string;
begin
  Result := FormatIncidentDetails(aIncident, '', nil);
end;

function FormatMachineOverviewIncidentDetails(const aIncident: TMachineOverviewIncident;
  const aTimeZoneName: string; const aUtcToLocal: TFunc<TDateTime, TDateTime>): string;
begin
  // Keep the existing signature; per-timestamp offsets replace the zone name.
  Result := FormatIncidentDetails(aIncident, '', aUtcToLocal);
end;

function FormatMachineOverviewHistoryHealth(const aHealth: TMachineOverviewHistoryHealth;
  const aNowUtc: TDateTime): string;
var
  g: TGarbos;
  lLines: TStringList;
  lStorage, lAge: string;
  lSeconds: Int64;
begin
  g := Default(TGarbos);
  GC(lLines, TStringList.Create, g);
  lAge := rsHealthNever;
  if aHealth.LastWriteUtc > 0 then
  begin
    lSeconds := 0;
    if aNowUtc > aHealth.LastWriteUtc then
      lSeconds := Round((aNowUtc - aHealth.LastWriteUtc) * SecsPerDay);
    if lSeconds < 60 then
      lAge := Format(rsHealthSecondsAgo, [lSeconds])
    else
      lAge := Format(rsHealthMinutesAgo, [lSeconds div 60]);
  end;
  lLines.Add(Format(rsHealthHeading, [MachineOverviewRecordingState(aHealth, aNowUtc), lAge]));
  case aHealth.StorageState of
    TMachineOverviewStorageState.WithinBudget: lStorage := rsStorageWithinBudget;
    TMachineOverviewStorageState.Trimming: lStorage := rsStorageTrimming;
    TMachineOverviewStorageState.FloorBreached: lStorage := rsStorageFloorBreached;
    TMachineOverviewStorageState.OverBudget: lStorage := rsStorageOverBudget;
    TMachineOverviewStorageState.MigrationBlocked: lStorage := rsStorageMigrationBlocked;
  end;
  lLines.Add(Format(rsHealthStorage, [FormatFloat('0.###', aHealth.UsedBytes / 1048576, TFormatSettings.Invariant),
    FormatFloat('0.###', aHealth.BudgetBytes / 1048576, TFormatSettings.Invariant),
    FormatFloat('0.###', aHealth.WalBytes / 1048576, TFormatSettings.Invariant),
    FormatFloat('0.###', aHealth.FileBytes / 1048576, TFormatSettings.Invariant),
    FormatFloat('0.###', aHealth.EvidenceBytes / 1048576, TFormatSettings.Invariant),
    lStorage, aHealth.StorageMessage]));
  lLines.Add(Format(rsHealthRange, [rsHealthIncidents, MachineOverviewEvidenceTimeText(aHealth.OldestIncidentUtc),
    MachineOverviewEvidenceTimeText(aHealth.NewestIncidentUtc)]));
  lLines.Add(Format(rsHealthRange, [rsHealthEvidence, MachineOverviewEvidenceTimeText(aHealth.OldestEvidenceUtc),
    MachineOverviewEvidenceTimeText(aHealth.NewestEvidenceUtc)]));
  lLines.Add(Format(rsHealthProcess, [MachineOverviewEvidenceTimeText(aHealth.NewestProcessSampleUtc)]));
  lLines.Add(Format(rsHealthCounts, [aHealth.EvidenceTrimmedTotal, aHealth.IncidentsDeletedTotal,
    aHealth.SamplesDeletedTotal, aHealth.SessionDroppedRecords]));
  lLines.Add(Format(rsHealthSampling, [aHealth.ProcessIntervalMs, aHealth.SystemIntervalMs,
    aHealth.CommitIntervalMs, aHealth.LogicalProcessorCount, aHealth.ProviderStatus]));
  lLines.Add(Format(rsHealthPaths, [aHealth.DatabaseFileName, aHealth.BackupFileName]));
  if not aHealth.LastError.IsEmpty then
    lLines.Add(Format(rsHealthError, [aHealth.LastError]));
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
  if not lWorker.fCompleted then
    Exit;
  lWorker.WaitFor;
  lError := lWorker.fError;
  lIncidents := Copy(lWorker.fIncidents);
  // The user may select or scroll while the query runs. Preserve that current
  // context rather than restoring the selection captured when refresh began.
  lPreviousSelectedId := SelectedIncidentId;
  lPreviousTopId := TopIncidentId;
  lSelectNewest := lWorker.fSelectNewest;
  lSucceeded := lWorker.fSucceeded;
  fLastQueryThreadId := lWorker.fQueryThreadId;
  fHealth := lWorker.fHealth;
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
    if SelectedIncidentId.IsEmpty then
      memDetails.Text := FormatMachineOverviewHistoryHealth(fHealth, CurrentReferenceUtc);
    Exit;
  end;
  fIncidents := lIncidents;
  RenderIncidents(lPreviousSelectedId, lPreviousTopId, lSelectNewest);
  if Length(fIncidents) = 0 then
    labStatus.Caption := rsIncidentHistoryEmpty
  else
    labStatus.Caption := Format(rsIncidentHistoryCount,
      [Length(fIncidents)]);
  if not lError.IsEmpty then
    labStatus.Caption := labStatus.Caption + '. ' + lError;
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
var
  lMessage: TMsg;
begin
  if Assigned(fWorker) then
    fWorker.Terminate;
  if Assigned(fEvidenceWorker) then
    fEvidenceWorker.Terminate;
  if Assigned(fWorker) then
  begin
    fWorker.WaitFor;
    FreeAndNil(fWorker);
  end;
  if Assigned(fEvidenceWorker) then
  begin
    fEvidenceWorker.WaitFor;
    FreeAndNil(fEvidenceWorker);
  end;
  if HandleAllocated then
    // Completion messages carry no owned payload. Both workers have stopped.
    while PeekMessage(lMessage, Handle, WM_APP + 146, WM_APP + 147, PM_REMOVE) do
      Continue;
end;

destructor TMachineOverviewHistoryFrm.Destroy;
begin
  fClosing := True;
  // Join while our target HWND still exists, before TCustomForm destroys it.
  CloseWorker;
  inherited;
end;

function TMachineOverviewHistoryFrm.LastEvidenceQueryThreadId: Cardinal;
begin
  Result := fLastEvidenceQueryThreadId;
end;

procedure TMachineOverviewHistoryFrm.btnCopyEvidenceClick(aSender: TObject);
begin
  try
    Clipboard.AsText := memDetails.Text;
    labStatus.Caption := rsEvidenceCopied;
  except
    on lException: Exception do
      labStatus.Caption := Format(rsEvidenceCopyFailed, [lException.Message]);
  end;
end;

procedure TMachineOverviewHistoryFrm.SetEvidenceCaption(const aState: string);
begin
  labEvidence.Caption := rsEvidenceListName + ': ' + aState;
  SetHistoryAccessibleName(lvEvidence, labEvidence.Caption);
end;

procedure TMachineOverviewHistoryFrm.RefreshAccessibleNames;
begin
  // Scaling can recreate native child HWNDs, which discards their annotations.
  if fClosing or not Assigned(cbFilter) or not Assigned(memDetails) or
    not Assigned(lvIncidents) or not Assigned(lvEvidence) or not Assigned(labEvidence) then
    Exit;
  SetHistoryAccessibleName(memDetails, rsEvidenceDetailsName);
  SetHistoryAccessibleName(cbFilter, rsFilterName);
  UpdateHistoryAccessibleRows(lvIncidents, rsIncidentListName, fIncidentNamedCount);
  UpdateHistoryAccessibleRows(lvEvidence, labEvidence.Caption, fEvidenceNamedCount, fEvidenceRowNames);
end;

procedure TMachineOverviewHistoryFrm.ScaleForPPI(aNewPpi: Integer);
begin
  inherited;
  RefreshAccessibleNames;
end;

procedure TMachineOverviewHistoryFrm.DoAfterMonitorDpiChanged(aOldDpi, aNewDpi: Integer);
begin
  inherited;
  RefreshAccessibleNames;
end;

procedure TMachineOverviewHistoryFrm.BeginEvidenceRefresh;
var
  lIndex: Integer;
begin
  if fClosing then
    Exit;
  Inc(fEvidenceRequest);
  fRequestedEvidenceKey := SelectedIncidentId;
  fEvidenceRowNames := nil;
  lvEvidence.Items.Clear;
  btnCopyEvidence.Enabled := False;
  lIndex := FindIncidentIndex(fRequestedEvidenceKey);
  if lIndex < 0 then
  begin
    SetEvidenceCaption(rsEvidenceNoSelection);
    UpdateHistoryAccessibleRows(lvEvidence, labEvidence.Caption, fEvidenceNamedCount);
    memDetails.Text := FormatMachineOverviewHistoryHealth(fHealth, CurrentReferenceUtc);
    Exit;
  end;
  RenderDetails(lIndex, rsEvidenceLoadingText);
  btnCopyEvidence.Enabled := True;
  lvEvidence.Items.Add.Caption := rsEvidenceLoading;
  SetEvidenceCaption(rsEvidenceLoading);
  UpdateHistoryAccessibleRows(lvEvidence, labEvidence.Caption, fEvidenceNamedCount);
  StartEvidenceWorker;
end;

procedure TMachineOverviewHistoryFrm.StartEvidenceWorker;
begin
  if fClosing or Assigned(fEvidenceWorker) or fRequestedEvidenceKey.IsEmpty then
    Exit;
  fEvidenceWorker := TMachineOverviewIncidentEvidenceWorker.Create(Handle,
    fDatabaseFileName, fRequestedEvidenceKey, fEvidenceRequest);
  fEvidenceWorker.Start;
end;

procedure TMachineOverviewHistoryFrm.ApplyEvidenceResult;
var
  lWorker: TMachineOverviewIncidentEvidenceWorker;
  lIndex: Integer;
  lCurrent: Boolean;
  lError, lFailureText: string;
  lSucceeded: Boolean;
begin
  if fClosing or not Assigned(fEvidenceWorker) then
    Exit;
  lWorker := fEvidenceWorker as TMachineOverviewIncidentEvidenceWorker;
  if not lWorker.Completed then
    Exit;
  lWorker.WaitFor;
  lCurrent := (lWorker.Request = fEvidenceRequest) and (lWorker.IncidentKey = SelectedIncidentId);
  lIndex := FindIncidentIndex(lWorker.IncidentKey);
  lSucceeded := lWorker.Succeeded;
  lError := lWorker.Error;
  fLastEvidenceQueryThreadId := lWorker.QueryThreadId;
  if lCurrent and (lIndex >= 0) and lSucceeded then
    fIncidents[lIndex].Evidence := lWorker.Evidence;
  FreeAndNil(fEvidenceWorker);
  if not lCurrent then
  begin
    StartEvidenceWorker;
    Exit;
  end;
  if (lIndex < 0) then
    Exit;
  if not lSucceeded then
  begin
    lFailureText := Format(rsEvidenceLoadFailed, [lError]);
    lvEvidence.Items.Clear;
    lvEvidence.Items.Add.Caption := lFailureText;
    SetEvidenceCaption(lFailureText);
    UpdateHistoryAccessibleRows(lvEvidence, labEvidence.Caption, fEvidenceNamedCount);
    RenderDetails(lIndex, lFailureText);
    btnCopyEvidence.Enabled := True;
    Exit;
  end;
  RenderEvidence;
  RenderDetails(lIndex);
  if not lError.IsEmpty then
    memDetails.Lines.Add(lError);
  btnCopyEvidence.Enabled := True;
end;

procedure TMachineOverviewHistoryFrm.RenderDetails(const aIndex: Integer; const aEvidenceStateLine: string);
begin
  memDetails.Text := FormatIncidentDetails(fIncidents[aIndex], aEvidenceStateLine, nil) +
    sLineBreak + FormatMachineOverviewHistoryHealth(fHealth, CurrentReferenceUtc) +
    sLineBreak + Format(rsEvidenceRawReference, [fDatabaseFileName, fIncidents[aIndex].StableId]);
end;

procedure TMachineOverviewHistoryFrm.RenderEvidence;
var
  lRow: TMachineOverviewEvidenceRow;
  lItem: TListItem;
  lIndex: Integer;
  lCaption: string;
begin
  lIndex := FindIncidentIndex(SelectedIncidentId);
  if lIndex < 0 then
    Exit;
  lvEvidence.Items.BeginUpdate;
  try
    lvEvidence.Items.Clear;
    fEvidenceRowNames := nil;
    for lRow in MachineOverviewEvidenceRows(fIncidents[lIndex].Evidence) do
    begin
      lItem := lvEvidence.Items.Add;
      lItem.Caption := Trim(lRow.Phase + ' ' + lRow.Kind + ' ' + lRow.Name);
      lItem.SubItems.Add(lRow.Identity);
      lItem.SubItems.Add(lRow.Average);
      lItem.SubItems.Add(lRow.Peak);
      lItem.SubItems.Add(lRow.PeakTime);
      lItem.SubItems.Add(lRow.Measured);
      SetLength(fEvidenceRowNames, Length(fEvidenceRowNames) + 1);
      fEvidenceRowNames[High(fEvidenceRowNames)] := lRow.AccessibleText;
    end;
    if lvEvidence.Items.Count = 0 then
      lvEvidence.Items.Add.Caption := MachineOverviewEvidenceStateText(fIncidents[lIndex].Evidence.State);
  finally
    lvEvidence.Items.EndUpdate;
  end;
  lCaption := MachineOverviewEvidenceStateText(fIncidents[lIndex].Evidence.State);
  if fIncidents[lIndex].Evidence.Truncated then
    lCaption := lCaption + ', ' + rsEvidenceListsShortened;
  SetEvidenceCaption(lCaption);
  UpdateHistoryAccessibleRows(lvEvidence, labEvidence.Caption, fEvidenceNamedCount, fEvidenceRowNames);
end;

procedure TMachineOverviewHistoryFrm.WMHistoryEvidenceComplete(var aMessage: TMessage);
begin
  ApplyEvidenceResult;
  aMessage.Result := 0;
end;

procedure TMachineOverviewHistoryFrm.Configure(const aDatabaseFileName: string;
  const aReferenceUtc: TDateTime);
begin
  fDatabaseFileName := aDatabaseFileName;
  fReferenceUtc := aReferenceUtc;
  RefreshAccessibleNames;
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

procedure TMachineOverviewHistoryFrm.CMShowingChanged(var aMessage: TMessage);
var
  lWorkArea: TRect;
  lWidth, lHeight: Integer;
begin
  inherited;
  if not Showing or fClosing or (csDesigning in ComponentState) then
    Exit;
  // Bounds and monitor work area are physical pixels after VCL DPI scaling.
  // VCL owner-centering happens after OnShow; constrain the resulting bounds.
  lWorkArea := InitialWorkArea;
  lWidth := Max(Constraints.MinWidth, Min(Width, lWorkArea.Width));
  lHeight := Max(Constraints.MinHeight, Min(Height, lWorkArea.Height));
  if (lWidth > lWorkArea.Width) or (lHeight > lWorkArea.Height) then
  begin
    // Keep the title bar reachable when the fixed minimum cannot fit.
    SetBounds(lWorkArea.Left, lWorkArea.Top, lWidth, lHeight);
    Exit;
  end;
  SetBounds(EnsureRange(Left, lWorkArea.Left, lWorkArea.Right - lWidth),
    EnsureRange(Top, lWorkArea.Top, lWorkArea.Bottom - lHeight), lWidth, lHeight);
end;

procedure TMachineOverviewHistoryFrm.FormShow(aSender: TObject);
begin
  RefreshAccessibleNames;
  BeginRefresh(True);
  if lvIncidents.CanFocus then
    lvIncidents.SetFocus;
end;

function TMachineOverviewHistoryFrm.InitialWorkArea: TRect;
begin
  Result := Monitor.WorkareaRect;
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
  if aSelected or not Assigned(lvIncidents.Selected) then
    BeginEvidenceRefresh;
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
  UpdateHistoryAccessibleRows(lvIncidents, rsIncidentListName, fIncidentNamedCount);
  BeginEvidenceRefresh;
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

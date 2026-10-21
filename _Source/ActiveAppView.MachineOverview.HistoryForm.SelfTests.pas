unit ActiveAppView.MachineOverview.HistoryForm.SelfTests;

interface

function RunMachineOverviewIncidentHistorySelfTests(
  const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.Diagnostics, System.IOUtils, System.StrUtils, System.SysUtils, System.Types, System.Win.ComObj,
  Winapi.ActiveX, Winapi.Messages, Winapi.oleacc, Winapi.Windows,
  Vcl.ComCtrls, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls,
  AutoFree, FireDAC.Comp.Client, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper.Stat,
  ActiveAppView.MachineOverview.Evidence, ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.HistoryForm,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewIncidentHistorySelfTestArg =
    '--self-test-machine-overview-incident-view';

type
  TWorkAreaHistoryFrm = class(TMachineOverviewHistoryFrm)
  protected
    function InitialWorkArea: TRect; override;
  public
    WorkArea: TRect;
  end;

function TWorkAreaHistoryFrm.InitialWorkArea: TRect;
begin
  if not WorkArea.IsEmpty then
    Exit(WorkArea);
  // Physical pixels: 1920x1080 at 150%, with a 72-pixel taskbar.
  Result := Rect(0, 0, 1920, 1008);
end;

function CreateIncidentChange(const aId: string; const aUtc: TDateTime;
  const aSummary: string): TMachineOverviewIncidentChange;
begin
  Result := Default(TMachineOverviewIncidentChange);
  Result.Kind := TMachineOverviewIncidentChangeKind.Ended;
  Result.Incident.StableId := aId;
  Result.Incident.Category := TMachineOverviewIncidentCategory.DiskPressure;
  Result.Incident.Severity := TMachineOverviewSeverity.Warning;
  Result.Incident.Origin := TMachineOverviewIncidentOrigin.Automatic;
  Result.Incident.StartedAtUtc := aUtc;
  Result.Incident.PeakAtUtc := IncSecond(aUtc, 1);
  Result.Incident.EndedAtUtc := IncSecond(aUtc, 2);
  Result.Incident.LocalDisplayTime := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    TTimeZone.Local.ToLocalTime(aUtc));
  Result.Incident.Summary := aSummary;
  Result.Incident.Explanation := 'Recorded explanation for ' + aId;
  Result.Incident.ThresholdText := 'recorded threshold';
  Result.Incident.PeakValue := 42.5;
  Result.Incident.ProviderId := 'test-provider';
  Result.Incident.ProviderFreshnessMs := 25;
  Result.Incident.RelatedEntityIds := TArray<string>.Create('physical:0');
  Result.Incident.RelatedExecutablePaths :=
    TArray<string>.Create('C:\Test\history.exe');
  Result.Incident.TraceStatus :=
    TMachineOverviewIncidentTraceStatus.Captured;

end;

function CreateHistoryConfig(const aDatabaseFileName: string):
  TMachineOverviewHistoryConfig;
begin
  Result := Default(TMachineOverviewHistoryConfig);
  Result.DiskFreeBytesOverride := -1;
  Result.Enabled := True;
  Result.DatabaseFileName := aDatabaseFileName;
  Result.CommitIntervalMs := 60000;
  Result.QueueCapacity := 32;
  Result.RawRetentionHours := 48;
  Result.Rollup10sRetentionDays := 30;
  Result.Rollup1mRetentionDays := 365;
  Result.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
  Result.BusyTimeoutMs := 100;
end;

procedure DeleteHistoryFiles(const aDatabaseFileName: string);
begin
  if TFile.Exists(aDatabaseFileName + '-shm') then
    TFile.Delete(aDatabaseFileName + '-shm');
  if TFile.Exists(aDatabaseFileName + '-wal') then
    TFile.Delete(aDatabaseFileName + '-wal');
  if TFile.Exists(aDatabaseFileName) then
    TFile.Delete(aDatabaseFileName);
end;

function PersistIncidents(const aDatabaseFileName: string;
  const aChanges: TArray<TMachineOverviewIncidentChange>): Boolean;
var
  lChange: TMachineOverviewIncidentChange;
  lService: TMachineOverviewHistoryService;
begin
  Result := False;
  lService := TMachineOverviewHistoryService.Create(nil,
    CreateHistoryConfig(aDatabaseFileName));
  try
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) then
      Exit;
    for lChange in aChanges do
      if lService.EnqueueIncident(lChange) <>
        TMachineOverviewHistoryEnqueueResult.Queued then
        Exit;
    if not lService.Flush(5000) then
      Exit;
    Result := lService.Stop(5000) =
      TMachineOverviewShutdownResult.Stopped;
  finally
    lService.Free;
  end;
end;

procedure ConfigureLockConnection(const aDatabaseFileName: string;
  const aConnection: TFDConnection);
var
  lDriverLink: TFDPhysSQLiteDriverLink;
begin
  lDriverLink := TFDPhysSQLiteDriverLink.Create(aConnection);
  lDriverLink.DriverID := 'SQLite';
  aConnection.LoginPrompt := False;
  aConnection.ResourceOptions.SilentMode := True;
  aConnection.Params.Values['DriverID'] := 'SQLite';
  aConnection.Params.Values['Database'] := aDatabaseFileName;
  aConnection.Params.Values['OpenMode'] := 'ReadWrite';
  aConnection.Params.Values['LockingMode'] := 'Normal';
  aConnection.Params.Values['JournalMode'] := 'Delete';
  aConnection.Params.Values['SharedCache'] := 'False';
  aConnection.Params.Values['BusyTimeout'] := '100';
  aConnection.Connected := True;
end;

function FindIncidentItemIndex(const aForm: TMachineOverviewHistoryFrm;
  const aStableId: string): Integer;
var
  i: Integer;
begin
  for i := 0 to aForm.IncidentCount - 1 do
    if SameText(aForm.IncidentAt(i).StableId, aStableId) then
      Exit(i);
  Result := -1;
end;

procedure PumpEvidence(const aForm: TMachineOverviewHistoryFrm); forward;

function RunIncidentHistoryFormSelfTest: Integer;
var
  g: TGarbos;
  lChanges: TArray<TMachineOverviewIncidentChange>;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDetails: string;
  lDirectory: string;
  lErrorDatabaseFileName: string;
  lForm: TMachineOverviewHistoryFrm;
  lIndex: Integer;
  lNowUtc: TDateTime;
  lSelectedId: string;
begin
  g := Default(TGarbos);
  Result := 1;
  lNowUtc := EncodeDate(2026, 8, 29) + EncodeTime(12, 0, 0, 0);
  if (MachineOverviewIncidentHistoryEarliestUtc(
      TMachineOverviewIncidentHistoryFilter.Last24Hours, lNowUtc) <>
      IncHour(lNowUtc, -24)) or
    (MachineOverviewIncidentHistoryEarliestUtc(
      TMachineOverviewIncidentHistoryFilter.Last7Days, lNowUtc) <>
      IncDay(lNowUtc, -7)) or
    (MachineOverviewIncidentHistoryEarliestUtc(
      TMachineOverviewIncidentHistoryFilter.All, lNowUtc) <> 0) or
    (not ShouldOpenMachineOverviewIncidentHistory('incidents')) or
    ShouldOpenMachineOverviewIncidentHistory('cpu') then
  begin
    Writeln('SELFTEST FAILED: incident history filter or Enter routing contract is wrong');
    Exit;
  end;

  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('incident-view-%d-%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  lErrorDatabaseFileName := lDatabaseFileName + '.invalid';
  try
    SetLength(lChanges, 7);
    lChanges[0] := CreateIncidentChange('old', IncDay(lNowUtc, -8), 'Old');
    lChanges[1] := CreateIncidentChange('week', IncDay(lNowUtc, -6), 'Week');
    lChanges[2] := CreateIncidentChange('outside',
      IncMilliSecond(IncHour(lNowUtc, -24), -1), 'Outside');
    lChanges[3] := CreateIncidentChange('boundary',
      IncHour(lNowUtc, -24), 'Boundary');
    lChanges[4] := CreateIncidentChange('beta', IncHour(lNowUtc, -2),
      'Beta details');
    lChanges[5] := CreateIncidentChange('alpha', IncHour(lNowUtc, -2),
      'Alpha');
    lChanges[6] := CreateIncidentChange('recent', IncHour(lNowUtc, -1),
      'Recent');
    if not PersistIncidents(lDatabaseFileName, lChanges) then
      Exit;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureLockConnection(lDatabaseFileName, lConnection);
    lConnection.ExecSQL('PRAGMA user_version=2');
    lConnection.ExecSQL('UPDATE incident SET pre_context_json=''invalid legacy context''');
    lConnection.Connected := False;

    GC(lForm, TMachineOverviewHistoryFrm.Create(nil), g);
    if (Trim(lForm.Caption) = '') or
      (lForm.Constraints.MinHeight <> 420) or
      (lForm.cbFilter.Style <> csDropDownList) or
      (lForm.cbFilter.Items.Count <> 3) or
      (lForm.cbFilter.TabOrder <> 0) or
      (lForm.lvIncidents.TabOrder <> 0) or
      (lForm.memDetails.TabOrder <> 2) or
      (not Assigned(lForm.FindComponent('lvEvidence'))) or
      (not Assigned(lForm.FindComponent('btnCopyEvidence'))) or
      (lForm.lvEvidence.TabOrder <> 1) or
      (lForm.btnCopyEvidence.TabOrder <> 0) or (lForm.btnClose.TabOrder <> 1) or
      (lForm.btnCopyEvidence.Caption <> '&Copy evidence') or
      (lForm.lvEvidence.Columns.Count <> 6) or not lForm.lvEvidence.ReadOnly or
      not lForm.lvEvidence.RowSelect or lForm.lvEvidence.HideSelection or
      lForm.lvEvidence.ColumnClick or (lForm.lvEvidence.ViewStyle <> vsReport) or
      (lForm.lvEvidence.ComponentIndex >= lForm.labEvidence.ComponentIndex) or
      (not lForm.lvIncidents.ReadOnly) or
      (not lForm.lvIncidents.RowSelect) or lForm.lvIncidents.HideSelection or
      (lForm.lvIncidents.ViewStyle <> vsReport) or
      (lForm.lvIncidents.Columns.Count <> 3) or
      (not lForm.memDetails.ReadOnly) or
      (lForm.memDetails.ScrollBars <> ssVertical) or
      (not lForm.btnClose.Cancel) or (lForm.btnClose.ModalResult <> 2) or
      (lForm.cbFilter.ComponentIndex >= lForm.labFilter.ComponentIndex) then
    begin
      Writeln('SELFTEST FAILED: incident history accessibility or keyboard contract is wrong');
      Exit;
    end;
    lForm.Configure(lDatabaseFileName, lNowUtc);
    lForm.SetFilter(TMachineOverviewIncidentHistoryFilter.Last24Hours);
    if (not lForm.RefreshAndWaitForTest(True, 5000)) or
      (lForm.IncidentCount <> 4) or
      (lForm.IncidentAt(0).StableId <> 'recent') or
      (lForm.IncidentAt(1).StableId <> 'alpha') or
      (lForm.IncidentAt(2).StableId <> 'beta') or
      (lForm.IncidentAt(3).StableId <> 'boundary') or
      (lForm.SelectedIncidentId <> 'recent') or
      (not ContainsText(lForm.labStatus.Caption, 'History upgrade pending')) or
      (lForm.LastQueryThreadId = GetCurrentThreadId) or
      (lForm.LastApplyThreadId <> GetCurrentThreadId) then
    begin
      Writeln('SELFTEST FAILED: initial history filter, ordering, selection, or thread ownership is wrong');
      Exit;
    end;
    lIndex := FindIncidentItemIndex(lForm, 'beta');
    if lIndex < 0 then
      Exit;
    lForm.lvIncidents.Selected := lForm.lvIncidents.Items[lIndex];
    lSelectedId := lForm.SelectedIncidentId;
    PumpEvidence(lForm);
    lDetails := lForm.memDetails.Text;
    if (lSelectedId <> 'beta') or
      (not ContainsText(lDetails, 'Beta details')) or
      ContainsText(lDetails, 'Related executable paths') or
      ContainsText(lDetails, 'C:\Test\history.exe') or
      ContainsText(lDetails, 'before beta') or
      ContainsText(lDetails, 'after beta') then
    begin
      Writeln('SELFTEST FAILED: incident details are incomplete');
      Exit;
    end;

    SetLength(lChanges, 1);
    lChanges[0] := CreateIncidentChange('newest', IncMinute(lNowUtc, -30),
      'Newest');
    lConnection.Connected := True;
    lConnection.ExecSQL('PRAGMA user_version=3');
    lConnection.Connected := False;
    if (not PersistIncidents(lDatabaseFileName, lChanges)) or
      (not lForm.RefreshAndWaitForTest(False, 5000)) or
      (lForm.IncidentAt(0).StableId <> 'newest') or
      (lForm.SelectedIncidentId <> lSelectedId) then
    begin
      Writeln('SELFTEST FAILED: refresh did not preserve the selected stable incident');
      Exit;
    end;

    PumpEvidence(lForm);
    ConfigureLockConnection(lDatabaseFileName, lConnection);
    lConnection.ExecSQL('BEGIN EXCLUSIVE');
    try
      lConnection.ExecSQL('UPDATE schema_info SET value=value WHERE key=''version''');
      if lForm.RefreshAndWaitForTest(False, 2000) or
        (lForm.IncidentCount <> 5) or
        (lForm.SelectedIncidentId <> lSelectedId) or
        (not ContainsText(lForm.StatusText, 'unavailable')) then
      begin
        Writeln('SELFTEST FAILED: busy history did not preserve the current view and report degradation');
        Exit;
      end;
    finally
      lConnection.ExecSQL('ROLLBACK');
      lConnection.Connected := False;
    end;
    if not lForm.RefreshAndWaitForTest(False, 5000) then
      Exit;

    lForm.SetFilter(TMachineOverviewIncidentHistoryFilter.Last7Days);
    if (not lForm.RefreshAndWaitForTest(False, 5000)) or
      (lForm.IncidentCount <> 7) or
      (lForm.SelectedIncidentId <> lSelectedId) then
    begin
      Writeln('SELFTEST FAILED: seven-day history boundary or selection is wrong');
      Exit;
    end;
    lForm.SetFilter(TMachineOverviewIncidentHistoryFilter.All);
    if (not lForm.RefreshAndWaitForTest(False, 5000)) or
      (lForm.IncidentCount <> 8) or
      (lForm.SelectedIncidentId <> lSelectedId) then
    begin
      Writeln('SELFTEST FAILED: all-history filter or selection is wrong');
      Exit;
    end;

    lForm.Configure(lDatabaseFileName + '.missing', lNowUtc);
    if (not lForm.RefreshAndWaitForTest(False, 5000)) or
      (lForm.IncidentCount <> 0) or
      (not ContainsText(lForm.StatusText, 'No incidents')) then
    begin
      Writeln('SELFTEST FAILED: empty incident history state is wrong');
      Exit;
    end;
    TFile.WriteAllText(lErrorDatabaseFileName, 'not a SQLite database',
      TEncoding.ASCII);
    lForm.Configure(lErrorDatabaseFileName, lNowUtc);
    if lForm.RefreshAndWaitForTest(False, 5000) or
      (not ContainsText(lForm.StatusText, 'unavailable')) then
    begin
      Writeln('SELFTEST FAILED: invalid incident database state is wrong');
      Exit;
    end;
    Result := 0;
  finally
    // Join our evidence reader before deleting its fixture and WAL sidecars.
    g.Clear;
    DeleteHistoryFiles(lDatabaseFileName);
    if TFile.Exists(lErrorDatabaseFileName) then
      TFile.Delete(lErrorDatabaseFileName);
  end;
end;

function EvidenceFixture(const aKey: string; const aUtc: TDateTime): TMachineOverviewIncidentChange;
var
  lPhase: TMachineOverviewEvidencePhase;
  lProcess: TMachineOverviewProcessContribution;
  lApplication: TMachineOverviewApplicationContribution;
  lGap: TMachineOverviewEvidenceGap;
begin
  Result := CreateIncidentChange(aKey, aUtc, aKey);
  Result.HasEvidenceUpdate := True;
  Result.Incident.Evidence.State := TMachineOverviewEvidenceState.Complete;
  Result.Incident.Evidence.LogicalProcessorCount := 32;
  Result.Incident.Evidence.ProcessIntervalMs := 5000;
  Result.Incident.Evidence.SystemIntervalMs := 1000;
  lPhase := Default(TMachineOverviewEvidencePhase);
  lPhase.Kind := TMachineOverviewEvidencePhaseKind.During;
  lPhase.StartUtc := aUtc;
  lPhase.EndUtc := IncSecond(aUtc, 10);
  lPhase.ProcessSampleCount := 2;
  lPhase.ExpectedProcessSampleCount := 2;
  lPhase.SystemSampleCount := 10;
  lPhase.ExpectedSystemSampleCount := 10;
  lPhase.SystemCpu.Available := True;
  lPhase.SystemCpu.Average := 50;
  lPhase.SystemCpu.Peak := 60;
  lPhase.SystemCpu.PeakAtUtc := IncSecond(aUtc, 5);
  lProcess := Default(TMachineOverviewProcessContribution);
  lProcess.DisplayName := aKey + '.exe';
  lProcess.ProcessId := 1234;
  lProcess.CreationTime100ns := UInt64(DateTimeToUnix(IncDay(aUtc, -1), True) + 11644473600) * UInt64(10000000);
  lProcess.AverageCpuPercent := 12.5;
  lProcess.PeakCpuPercent := 25;
  lProcess.PeakAtUtc := IncSecond(aUtc, 5);
  lProcess.LastSeenUtc := IncSecond(aUtc, 10);
  lProcess.SampleCount := 2;
  lProcess.ImagePath := 'C:\Tools\' + aKey + '.exe';
  lPhase.Processes := [lProcess];
  lApplication := Default(TMachineOverviewApplicationContribution);
  lApplication.DisplayName := aKey + '.exe';
  lApplication.ProcessCount := 2;
  lApplication.AverageCpuPercent := 20;
  lApplication.PeakCpuPercent := 30;
  lApplication.PeakAtUtc := IncSecond(aUtc, 5);
  lPhase.Applications := [lApplication];
  Result.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During] := lPhase;
  lGap := Default(TMachineOverviewEvidenceGap);
  lGap.StartUtc := aUtc;
  lGap.EndUtc := IncSecond(aUtc, 5);
  lGap.Reason := TMachineOverviewEvidenceGapReason.ProcessSamplesMissing;
  Result.Incident.Evidence.Gaps := [lGap];
end;

function EvidenceListText(const aForm: TMachineOverviewHistoryFrm): string;
var
  lList: TListView;
  lItem: TListItem;
begin
  Result := '';
  lList := aForm.FindComponent('lvEvidence') as TListView;
  if not Assigned(lList) then
    Exit;
  for lItem in lList.Items do
    Result := Result + lItem.Caption + ' ' + lItem.SubItems.Text;
end;

function EvidenceAccessibleRowsMatch(const aForm: TMachineOverviewHistoryFrm): Boolean;
var
  lAccessible: IAccessible;
  lChild: OleVariant;
  lName: WideString;
  i: Integer;
  lItem: TListItem;
begin
  Result := False;
  if AccessibleObjectFromWindow(aForm.lvEvidence.Handle, OBJID_CLIENT, IID_IAccessible, lAccessible) < 0 then
    Exit;
  for i := 0 to aForm.lvEvidence.Items.Count - 1 do
  begin
    lChild := i + 1;
    if lAccessible.Get_accName(lChild, lName) < 0 then
      Exit;
    lItem := aForm.lvEvidence.Items[i];
    if (lItem.SubItems.Count > 0) and
      (not ContainsText(string(lName), 'average ') or
      not ContainsText(string(lName), ' of machine') or
      not ContainsText(string(lName), 'peak ') or ContainsText(string(lName), '; ;')) and
      not ContainsText(string(lName), 'Gap, ') and not ContainsText(string(lName), 'no measurement') then
      Exit;
  end;
  Result := aForm.lvEvidence.Items.Count > 0;
end;

procedure PumpEvidence(const aForm: TMachineOverviewHistoryFrm);
var
  lTimer: TStopwatch;
begin
  lTimer := TStopwatch.StartNew;
  repeat
    Application.ProcessMessages;
    if not ContainsText(EvidenceListText(aForm), 'Loading evidence') then
      Exit;
    Sleep(1);
  until lTimer.ElapsedMilliseconds > 5000;
end;

procedure WriteUiProofMarker(const aPath, aText: string);
begin
  if TFile.Exists(aPath) then
    Exit;
  TFile.WriteAllText(aPath + '.tmp', aText, TEncoding.ASCII);
  TFile.Move(aPath + '.tmp', aPath);
end;

procedure HoldEvidenceFormForUiProof(const aForm: TMachineOverviewHistoryFrm; const aState: string);
var
  lRoot: string;
  lTimer: TStopwatch;
  lPpi: Integer;
  lMessage: TMsg;
  lHeld: Boolean;
begin
  lRoot := GetEnvironmentVariable('ACV_S5_UI_PROOF');
  if lRoot.IsEmpty or (GetEnvironmentVariable('ACV_S5_UI_STATE') <> aState) then
    Exit;
  lPpi := StrToIntDef(GetEnvironmentVariable('ACV_S5_UI_PPI'), 96);
  aForm.Show;
  aForm.ScaleForPPI(lPpi);
  // Re-show after scaling so production FormShow performs the work-area clamp.
  aForm.Hide;
  aForm.Show;
  aForm.ActiveControl := aForm.cbFilter;
  lTimer := TStopwatch.StartNew;
  lHeld := False;
  while (lTimer.ElapsedMilliseconds < 120000) and not TFile.Exists(TPath.Combine(lRoot, 'stop.txt')) do
  begin
    if aState = 'loading' then
    begin
      // Keep painting/keyboard live while retaining the completed evidence request.
      while PeekMessage(lMessage, 0, 0, 0, PM_REMOVE) do
        if (lMessage.hwnd = aForm.Handle) and (lMessage.message = WM_APP + 147) then
          lHeld := True
        else
        begin
          TranslateMessage(lMessage);
          DispatchMessage(lMessage);
        end;
      if TFile.Exists(TPath.Combine(lRoot, 'release-load.txt')) then
      begin
        if lHeld then
        begin
          PostMessage(aForm.Handle, WM_APP + 147, 0, 0);
          lHeld := False;
        end;
        Application.ProcessMessages;
      if aForm.btnCopyEvidence.Enabled and not ContainsText(EvidenceListText(aForm), 'Loading evidence') then
          WriteUiProofMarker(TPath.Combine(lRoot, 'loaded.txt'), aForm.ActiveControl.Name);
      end;
    end else begin
      Application.ProcessMessages;
    end;
    if ((aState <> 'loading') and aForm.btnCopyEvidence.Enabled and
      not ContainsText(EvidenceListText(aForm), 'Loading evidence')) or
      ((aState = 'loading') and lHeld and ContainsText(EvidenceListText(aForm), 'Loading evidence')) then
      WriteUiProofMarker(TPath.Combine(lRoot, 'ready.txt'), Format('%d %d %d',
        [GetCurrentProcessId, aForm.Handle, aForm.CurrentPPI]));
    Sleep(20);
  end;
  if lHeld then
    PostMessage(aForm.Handle, WM_APP + 147, 0, 0);
  aForm.Hide;
end;

procedure CheckHeldEvidenceSelection(const aForm: TMachineOverviewHistoryFrm);
var
  lMessage: TMsg;
  lTimer: TStopwatch;
begin
  // A is queried successfully, but its completion is held in the message queue.
  aForm.lvIncidents.Selected := aForm.lvIncidents.Items[1];
  lTimer := TStopwatch.StartNew;
  while not PeekMessage(lMessage, aForm.Handle, WM_APP + 147, WM_APP + 147, PM_NOREMOVE) do
  begin
    if lTimer.ElapsedMilliseconds > 5000 then
      raise Exception.Create('Held evidence request A did not complete');
    Sleep(1);
  end;
  // B becomes current before A is released. Observe immediately after A alone.
  aForm.lvIncidents.Selected := aForm.lvIncidents.Items[0];
  if not PeekMessage(lMessage, aForm.Handle, WM_APP + 147, WM_APP + 147, PM_REMOVE) then
    raise Exception.Create('Held evidence request A disappeared');
  DispatchMessage(lMessage);
  if not ContainsText(EvidenceListText(aForm), 'Loading evidence') or
    ContainsText(aForm.memDetails.Text, 'Incident: first') then
    raise Exception.Create('Stale request A rendered after selection B');
  PumpEvidence(aForm);
  if not ContainsText(EvidenceListText(aForm), 'latest.exe') then
    raise Exception.Create('Latest request B did not render after held A');
end;

function AccessibleControlName(const aControl: TWinControl): string;
var
  lAccessible: IAccessible;
  lName: WideString;
  lChild: OleVariant;
begin
  OleCheck(AccessibleObjectFromWindow(aControl.Handle, OBJID_CLIENT, IID_IAccessible, lAccessible));
  lChild := CHILDID_SELF;
  OleCheck(lAccessible.Get_accName(lChild, lName));
  Result := string(lName);
end;

procedure CheckEvidenceStartDates;
var
  lIncident: TMachineOverviewIncident;
  lRow: TMachineOverviewEvidenceRow;
  lUtc, lStartUtc: TDateTime;
  i: Int64;
  lFound: Integer;
begin
  lUtc := TTimeZone.Local.ToUniversalTime(EncodeDate(2026, 10, 20) + EncodeTime(0, 1, 0, 0));
  lIncident := EvidenceFixture('local-midnight', lUtc).Incident;
  for i := 0 to 1 do
  begin
    lStartUtc := IncMinute(lUtc, -2 * i);
    lIncident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].CreationTime100ns :=
      UInt64(DateTimeToUnix(lStartUtc, True) + 11644473600) * UInt64(10000000);
    lFound := 0;
    for lRow in MachineOverviewEvidenceRows(lIncident.Evidence) do
      if lRow.Kind = 'Process' then
      begin
        Inc(lFound);
        if ((i = 0) and ContainsText(lRow.Identity, '2026-')) or
          ((i = 1) and (not ContainsText(lRow.Identity, '2026-10-19 23:59:00') or
            not ContainsText(lRow.AccessibleText, '2026-10-19 23:59:00'))) then
          raise Exception.Create('Process start dates must follow the incident local day, including local midnight');
      end;
    if lFound <> 1 then
      raise Exception.Create('Local-day process fixture did not yield one process row');
  end;
  Writeln('PASS CheckEvidenceStartDates: same local day time-only; previous local day dated in identity and accessible name');
end;

procedure CheckEvidencePresentation(const aForm: TMachineOverviewHistoryFrm);
var
  i, lWidth, lOldHeight, lListHeight: Integer;
  lAccessible: IAccessible;
  lName: WideString;
  lChild: OleVariant;
begin
  try
    aForm.ScaleForPPI(144);
    if AccessibleControlName(aForm.cbFilter) <> 'Show incidents' then
      raise Exception.Create('Scaling must preserve the filter accessible name');
  finally
    aForm.ScaleForPPI(96);
  end;
  if (AccessibleControlName(aForm.cbFilter) <> 'Show incidents') or
    (AccessibleControlName(aForm.memDetails) <> 'Incident details and evidence export') or
    not ContainsText(AccessibleControlName(aForm.lvEvidence), 'complete') then
    raise Exception.Create('Evidence memo, filter, or state accessible name is missing');
  OleCheck(AccessibleObjectFromWindow(aForm.lvEvidence.Handle, OBJID_CLIENT, IID_IAccessible, lAccessible));
  lChild := 6;
  OleCheck(lAccessible.Get_accName(lChild, lName));
  if not string(lName).StartsWith('During, process latest.exe, PID 1234, started ') or
    not ContainsText(string(lName), ': average 12.5%') or not ContainsText(string(lName), 'peak 25%') or
    not ContainsText(string(lName), '2 of 2 samples') or not ContainsText(string(lName), '2026-10-19') then
    raise Exception.Create('Evidence process row must include its cross-day start date');
  lWidth := 0;
  for i := 0 to aForm.lvEvidence.Columns.Count - 1 do
    Inc(lWidth, aForm.lvEvidence.Columns[i].Width);
  if (lWidth > aForm.lvEvidence.ClientWidth) or
    (aForm.lvEvidence.Columns[2].Caption <> 'Average') or
    (aForm.lvEvidence.Columns[3].Caption <> 'Peak') then
    raise Exception.Create('Evidence peak time and measured columns do not fit the default width');
  aForm.Canvas.Font.Assign(aForm.lvEvidence.Font);
  for i := 2 to 3 do
    if (aForm.Canvas.TextWidth(aForm.lvEvidence.Columns[i].Caption) + 16 > aForm.lvEvidence.Columns[i].Width) or
      (aForm.Canvas.TextWidth(aForm.lvEvidence.Items[5].SubItems[i - 1]) + 16 >
        aForm.lvEvidence.Columns[i].Width) or
      not ContainsText(aForm.lvEvidence.Items[5].SubItems[i - 1], 'of machine') then
      raise Exception.CreateFmt('Evidence Average/Peak must fit at 100%%: column=%d width=%d text=%d value=%s',
        [i, aForm.lvEvidence.Columns[i].Width,
        aForm.Canvas.TextWidth(aForm.lvEvidence.Items[5].SubItems[i - 1]) + 16,
        aForm.lvEvidence.Items[5].SubItems[i - 1]]);
  lOldHeight := aForm.Height;
  lListHeight := aForm.lvEvidence.Height;
  try
    aForm.Height := aForm.Constraints.MinHeight;
    if (aForm.Constraints.MinHeight <> 420) or (aForm.Height <> 420) or (aForm.memDetails.Height < 60) or
      (aForm.lvEvidence.Height >= lListHeight) or (aForm.lvIncidents.Height < 60) then
      raise Exception.Create('Evidence lists and memo must shrink at the minimum height');
  finally
    aForm.Height := lOldHeight;
  end;
end;

function RunIncidentEvidenceViewSelfTest: Integer;
var
  lForm: TMachineOverviewHistoryFrm;
  lConnection: TFDConnection;
  lDatabase: string;
  lNow: TDateTime;
  lText: string;
  lLoading: Boolean;
  lTimer: TStopwatch;
begin
  Result := 1;
  lDatabase := TPath.Combine(TPath.GetTempPath, Format('acv-s5-view-%d.db', [GetCurrentProcessId]));
  lNow := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
  lForm := nil;
  lConnection := nil;
  try
    CheckEvidenceStartDates;
    if not PersistIncidents(lDatabase, [EvidenceFixture('first', lNow),
      EvidenceFixture('latest', IncMinute(lNow, 1))]) then
      Exit;
    lForm := TMachineOverviewHistoryFrm.Create(nil);
    lForm.Configure(lDatabase, IncHour(lNow, 1));
    if not lForm.RefreshAndWaitForTest(True, 5000) then
      Exit;
    lLoading := ContainsText(EvidenceListText(lForm), 'Loading evidence') and
      ContainsText(lForm.memDetails.Text, 'Evidence: loading') and
      ContainsText(lForm.memDetails.Text, 'Incident: latest') and
      ContainsText(lForm.memDetails.Text, 'Started ') and
      ContainsText(lForm.memDetails.Text, 'Threshold:') and
      ContainsText(lForm.memDetails.Text, 'Times are local') and
      ContainsText(lForm.memDetails.Text, 'Recording health:') and
      ContainsText(lForm.memDetails.Text, 'Raw evidence: ' + lDatabase) and
      ContainsText(lForm.memDetails.Text, 'incident_key latest') and
      lForm.btnCopyEvidence.Enabled and
      not ContainsText(lForm.memDetails.Text, 'Measurement:') and
      not ContainsText(lForm.memDetails.Text, 'Gaps:') and
      not ContainsText(lForm.memDetails.Text, 'Coverage:');
    if not lLoading then
      Writeln('SELFTEST FAILED: S5 loading must preserve headline, health, raw reference, and Copy');
    lForm.ActiveControl := lForm.cbFilter;
    lForm.lvIncidents.Selected := lForm.lvIncidents.Items[1];
    lForm.lvIncidents.Selected := lForm.lvIncidents.Items[0];
    PumpEvidence(lForm);
    lText := EvidenceListText(lForm);
    if not lLoading or not ContainsText(lText, 'latest.exe') or
      ContainsText(lText, 'first.exe') or not ContainsText(lText, 'PID 1234, started') or
      not ContainsText(lText, '12.5% of machine') or not ContainsText(lText, '2 processes') or
      ContainsText(lText, 'C:\Tools\') or not ContainsText(lText, '2026-10-19') or
      not ContainsText(lText, 'Gap') or (lForm.ActiveControl <> lForm.cbFilter) or
      (lForm.SelectedIncidentId <> 'latest') or
      (lForm.LastEvidenceQueryThreadId = GetCurrentThreadId) or
      (lForm.LastEvidenceQueryThreadId = 0) or not EvidenceAccessibleRowsMatch(lForm) then
      Writeln('SELFTEST FAILED: S5 evidence rows, latest selection, or focus preservation')
    else
      Result := 0;
    if Result = 0 then
    begin
      CheckHeldEvidenceSelection(lForm);
      CheckEvidencePresentation(lForm);
      HoldEvidenceFormForUiProof(lForm, 'normal');
      HoldEvidenceFormForUiProof(lForm, 'loading');
    end;
    if Result = 0 then
    begin
      lForm.btnRefresh.Click;
      lForm.lvIncidents.Selected := lForm.lvIncidents.Items[1];
      lTimer := TStopwatch.StartNew;
      repeat
        Application.ProcessMessages;
        Sleep(1);
      until ((lForm.LastApplyThreadId = GetCurrentThreadId) and
        not ContainsText(lForm.StatusText, 'Loading')) or (lTimer.ElapsedMilliseconds > 5000);
      PumpEvidence(lForm);
      if lForm.SelectedIncidentId <> 'first' then
      begin
        Writeln('SELFTEST FAILED: S5 list refresh restored stale selection');
        Result := 1;
      end;
    end;
    // Hold the fixture exclusively so destruction must join an in-flight reader,
    // rather than merely freeing a worker that already finished its fast query.
    lConnection := TFDConnection.Create(nil);
    ConfigureLockConnection(lDatabase, lConnection);
    lConnection.ExecSQL('BEGIN EXCLUSIVE');
    try
      lForm.lvIncidents.Selected := lForm.lvIncidents.Items[0];
      if not ContainsText(EvidenceListText(lForm), 'Loading evidence') then
      begin
        Writeln('SELFTEST FAILED: S5 close test did not start a new evidence request');
        Result := 1;
      end;
      FreeAndNil(lForm);
      Application.ProcessMessages;
    finally
      lConnection.ExecSQL('ROLLBACK');
      lConnection.Connected := False;
    end;
  finally
    lForm.Free;
    lConnection.Free;
    Application.ProcessMessages;
    DeleteHistoryFiles(lDatabase);
  end;
end;

function RunIncidentLegacyEvidenceViewSelfTest: Integer;
var
  lIncident: TMachineOverviewIncident;
  lText: string;
  lDatabase: string;
  lConnection: TFDConnection;
  lForm: TMachineOverviewHistoryFrm;
  lNow: TDateTime;
  lIndex: Integer;
  lKey: string;
  lKeys: TArray<string>;
  lTextFailed, lStateFailed: Boolean;
begin
  Result := 1;
  lIncident := CreateIncidentChange('legacy', Now, 'Legacy').Incident;
  lIncident.Evidence.State := TMachineOverviewEvidenceState.NotRecorded;
  lText := FormatMachineOverviewIncidentDetails(lIncident);
  if not ContainsText(lText, 'not recorded (incident predates measured evidence') or
    ContainsText(lText, 'Measurement:') or ContainsText(lText, 'Gaps:') or ContainsText(lText, 'Coverage:') then
    Writeln('SELFTEST FAILED: S5 legacy evidence state text')
  else
  begin
    lIncident.Evidence.State := TMachineOverviewEvidenceState.Trimmed;
    lText := FormatMachineOverviewIncidentDetails(lIncident);
    if not ContainsText(lText, 'removed by the storage budget') or
      ContainsText(lText, 'Measurement:') or ContainsText(lText, 'Gaps:') or ContainsText(lText, 'Coverage:') then
      Writeln('SELFTEST FAILED: S5 trimmed evidence state text')
    else
    begin
      lIncident.Evidence.State := TMachineOverviewEvidenceState.Partial;
      lIncident.EndedAtUtc := 0;
      lText := FormatMachineOverviewIncidentDetails(lIncident);
      if not ContainsText(lText, '; Ended: not recorded (collection stopped)') or
        ContainsText(lText, 'ended Ended:') or not ContainsText(lText, 'incomplete') then
        Writeln('SELFTEST FAILED: S5 partial evidence state text')
      else
        Result := 0;
    end;
  end;
  lTextFailed := Result <> 0;
  Result := 1;
  lDatabase := TPath.Combine(TPath.GetTempPath, Format('acv-s5-states-%d.db', [GetCurrentProcessId]));
  lNow := EncodeDate(2026, 10, 20);
  lConnection := TFDConnection.Create(nil);
  lForm := nil;
  try
    if not PersistIncidents(lDatabase, [EvidenceFixture('legacy', lNow), EvidenceFixture('trimmed', lNow),
      EvidenceFixture('partial', lNow), EvidenceFixture('failed', lNow)]) then
      Exit;
    ConfigureLockConnection(lDatabase, lConnection);
    lConnection.ExecSQL('UPDATE incident SET evidence_state=5 WHERE incident_key=''legacy''');
    lConnection.ExecSQL('UPDATE incident SET evidence_state=4 WHERE incident_key=''trimmed''');
    lConnection.ExecSQL('DELETE FROM incident_evidence WHERE incident_key IN (''legacy'',''trimmed'')');
    lConnection.ExecSQL('UPDATE incident SET evidence_state=3, ended_utc_ms=0 WHERE incident_key=''partial''');
    lConnection.ExecSQL('UPDATE incident_evidence SET state=3 WHERE incident_key=''partial''');
    lConnection.ExecSQL('UPDATE incident_evidence SET evidence_json=''invalid'' WHERE incident_key=''failed''');
    lConnection.Connected := False;
    lForm := TMachineOverviewHistoryFrm.Create(nil);
    lForm.Configure(lDatabase, lNow);
    if not lForm.RefreshAndWaitForTest(True, 5000) then
      Exit;
    lKeys := ['legacy', 'trimmed', 'partial', 'failed'];
    lStateFailed := False;
    for lKey in lKeys do
    begin
      lIndex := FindIncidentItemIndex(lForm, lKey);
      lForm.lvIncidents.Selected := lForm.lvIncidents.Items[lIndex];
      PumpEvidence(lForm);
      lText := lForm.memDetails.Text;
      if (lKey = 'legacy') or (lKey = 'trimmed') then
      begin
        lForm.Canvas.Font.Assign(lForm.lvEvidence.Font);
        if (lForm.lvEvidence.Items.Count <> 1) or
          (lForm.Canvas.TextWidth(lForm.lvEvidence.Items[0].Caption) + 16 > lForm.lvEvidence.Columns[0].Width) then
          raise Exception.Create('Single evidence state row must fit at 100%');
      end;
      if ((lKey = 'legacy') and not ContainsText(lText, 'not recorded (incident predates measured evidence')) or
        ((lKey = 'trimmed') and not ContainsText(lText, 'removed by the storage budget')) or
        ((lKey = 'partial') and not ContainsText(lText, 'Ended: not recorded')) or
        ((lKey = 'failed') and (not ContainsText(lText, 'Evidence could not be read (recorded data unavailable:') or
          not ContainsText(lForm.labEvidence.Caption, 'Evidence could not be read') or
          (lForm.lvEvidence.Items[0].Caption <> 'Evidence unavailable') or
          ContainsText(lText, 'Measurement:') or ContainsText(lText, 'Coverage:') or ContainsText(lText, 'Gaps:'))) or
        ContainsText(lForm.labEvidence.Caption, 'legacy:') or ContainsText(lForm.labEvidence.Caption, 'trimmed:') or
        not ContainsText(lText, 'Incident: ' + lKey) or not ContainsText(lText, 'Threshold:') or
        not ContainsText(lText, 'Times are local') or not ContainsText(lText, 'Started ') or
        not ContainsText(lText, 'Recording health:') or not ContainsText(lText, 'incident_key ' + lKey) or
        not lForm.btnCopyEvidence.Enabled or
        ((lKey <> 'partial') and ContainsText(lText, 'Measurement:')) or
        ((lKey = 'partial') and not ContainsText(lForm.labEvidence.Caption, 'incomplete')) then
      begin
        Writeln('SELFTEST FAILED: S5 persisted evidence state ' + lKey);
        lStateFailed := True;
      end;
      HoldEvidenceFormForUiProof(lForm, lKey);
    end;
    if not lTextFailed and not lStateFailed then
      Result := 0;
  finally
    lForm.Free;
    lConnection.Free;
    DeleteHistoryFiles(lDatabase);
  end;
end;

function RunIncidentHealthViewSelfTest: Integer;
var
  lForm: TMachineOverviewHistoryFrm;
  lHealth: TMachineOverviewHistoryHealth;
  lConnection: TFDConnection;
  lDatabase, lError, lText: string;
  lNow: TDateTime;
begin
  Result := 1;
  lNow := EncodeDate(2026, 10, 20);
  lHealth := Default(TMachineOverviewHistoryHealth);
  lText := FormatMachineOverviewHistoryHealth(lHealth, lNow);
  if not ContainsText(lText, 'Session started unknown') then
    raise Exception.Create('Unknown session start must be explicit in recording health');
  if not ContainsText(lText, 'last write never') or ContainsText(lText, '0 min ago') then
  begin
    Writeln('SELFTEST FAILED: S5 unavailable last write must say never');
    Exit;
  end;
  if MachineOverviewRecordingState(lHealth, lNow) <> 'Unavailable' then
    Exit;
  lHealth.Available := True;
  lHealth.CommitIntervalMs := 1000;
  lHealth.LastWriteUtc := lNow;
  if (MachineOverviewRecordingState(lHealth, IncMilliSecond(lNow, 2999)) <> 'Recording') or
    (MachineOverviewRecordingState(lHealth, IncMilliSecond(lNow, 3000)) <> 'Recording') or
    (MachineOverviewRecordingState(lHealth, IncMilliSecond(lNow, 3001)) <> 'Stale') then
  begin
    Writeln('SELFTEST FAILED: S5 recording health three-interval boundary');
    Exit;
  end;
  lText := FormatMachineOverviewHistoryHealth(lHealth, IncSecond(lNow, 4));
  if not ContainsText(lText, 'Recording health: Stale; last write 4 s ago') then
    raise Exception.Create('Stale recording health must show seconds');
  lHealth.LastError := 'fixture failure';
  if MachineOverviewRecordingState(lHealth, lNow) <> 'Error' then
    Exit;
  lForm := TMachineOverviewHistoryFrm.Create(nil);
  lConnection := TFDConnection.Create(nil);
  lDatabase := TPath.Combine(TPath.GetTempPath, Format('acv-s5-health-%d.db', [GetCurrentProcessId]));
  try
    lForm.Configure(TPath.Combine(TPath.GetTempPath, 'acv-s5-no-database.db'));
    if lForm.RefreshAndWaitForTest(True, 5000) and
      ContainsText(lForm.memDetails.Text, 'Recording health: Unavailable') then
      Result := 0
    else
      Writeln('SELFTEST FAILED: S5 history health when database unavailable');
    if Result <> 0 then
      Exit;
    Result := 1;
    if not PersistIncidents(lDatabase, [EvidenceFixture('health', lNow)]) then
      Exit;
    if not TryLoadMachineOverviewHistoryHealth(lDatabase, lHealth, lError) then
      raise Exception.Create('Persisted session health could not be loaded: ' + lError);
    lText := FormatMachineOverviewHistoryHealth(lHealth, lNow);
    if (not ContainsText(lText, 'records dropped this session 0')) or
      (not ContainsText(lText, 'No provider samples received this session.')) then
      raise Exception.Create('Health text lost persisted new-session drop/provider values: ' + lText);
    ConfigureLockConnection(lDatabase, lConnection);
    lConnection.ExecSQL('UPDATE history_status SET session_started_utc_ms=1792454400000, ' +
      'updated_utc_ms=1792454400000, commit_interval_ms=1000, ' +
      'used_bytes=1234, budget_bytes=5678, wal_bytes=90, file_bytes=6000, storage_state=3, ' +
      'storage_message=''fixture pressure'', process_interval_ms=5000, system_interval_ms=1000, ' +
      'logical_processor_count=32, migration_backup_path=''C:\fixture-backup.db'', ' +
      'provider_status_text=''Available'', evidence_trimmed_total=5000000000, incidents_deleted_total=3, ' +
      'samples_deleted_total=4, session_dropped_records=5 WHERE id=1');
    lConnection.ExecSQL('INSERT INTO process_top_sample(utc_ms,monotonic_ms,category,rank_value,entity_id,' +
      'process_id,creation_time_100ns,display_name,image_path,path_status,metric_value) VALUES ' +
      '(1792454400000,1,''cpu'',1,''fixture'',1234,0,''fixture.exe'','''',''unavailable'',12.5)');
    lConnection.Connected := False;
    if not TryLoadMachineOverviewHistoryHealth(lDatabase, lHealth, lError) or not lHealth.Available or
      (lHealth.LastWriteUtc <> lNow) or
      (lHealth.NewestProcessSampleUtc <> lNow) or (lHealth.EvidenceTrimmedTotal <> 5000000000) or
      (lHealth.OldestIncidentUtc <> lNow) or (lHealth.NewestIncidentUtc <> lNow) or
      (lHealth.OldestEvidenceUtc <> lNow) or (lHealth.NewestEvidenceUtc <> lNow) then
      Exit;
    lText := FormatMachineOverviewHistoryHealth(lHealth, IncMinute(lNow, 5));
    if lHealth.SessionStartedUtc <> lNow then
      raise Exception.Create('Health reader lost the 64-bit session timestamp');
    if not ContainsText(lText, 'Session started ' +
      Copy(MachineOverviewEvidenceTimeText(lNow), 12, MaxInt)) then
      raise Exception.Create('Persisted 64-bit session start missing from recording health: ' + lText);
    if not ContainsText(lText, 'MB') or ContainsText(lText, 'U/B') or
      not ContainsText(lText, '5 min ago') or not ContainsText(lText, 'WAL') or
      not ContainsText(lText, 'Over budget. fixture pressure') or
      not ContainsText(lText, 'oldest') or not ContainsText(lText, 'newest') or
      not ContainsText(lText, '5000 ms') or not ContainsText(lText, '1000 ms') or
      not ContainsText(lText, '32 logical processors') or not ContainsText(lText, 'Available') or
      not ContainsText(lText, lDatabase) or not ContainsText(lText, 'C:\fixture-backup.db') or
      not ContainsText(lText, 'records dropped this session 5') then
    begin
      Writeln('SELFTEST FAILED: S5 loaded history health fields');
      Exit;
    end;
    lConnection.Connected := True;
    lConnection.ExecSQL('UPDATE history_status SET session_started_utc_ms=0');
    lConnection.Connected := False;
    if (not TryLoadMachineOverviewHistoryHealth(lDatabase, lHealth, lError)) or
      (lHealth.SessionStartedUtc <> 0) or
      (not ContainsText(FormatMachineOverviewHistoryHealth(lHealth, lNow), 'Session started unknown')) then
      raise Exception.Create('Persisted zero session start must remain unknown');
    lConnection.Connected := True;
    lConnection.ExecSQL('UPDATE history_status SET session_started_utc_ms=1792454400000');
    lConnection.Connected := False;
    // Finish fixture writes before refresh starts the asynchronous evidence reader.
    lForm.Configure(lDatabase, lNow);
    if (not lForm.RefreshAndWaitForTest(True, 5000)) or
      (not ContainsText(lForm.memDetails.Text, 'Session started ' +
      Copy(MachineOverviewEvidenceTimeText(lNow), 12, MaxInt))) then
      raise Exception.Create('Displayed health omitted the persisted session start');
    Result := 0;
  finally
    lForm.Free;
    lConnection.Free;
    DeleteHistoryFiles(lDatabase);
  end;
end;

procedure RejectUnexpectedEvidenceCopy(const aText: string);
begin
  raise Exception.Create('Unexpected copy outside the clipboard fake assertion');
end;

procedure FailEvidenceCopy(const aText: string);
begin
  raise Exception.Create('in-memory clipboard failure');
end;

procedure CheckEvidenceClipboard(const aForm: TMachineOverviewHistoryFrm);
var
  lCopiedText: string;
  lCalls: Integer;
begin
  lCalls := 0;
  MachineOverviewEvidenceClipboardWriter :=
    procedure(aText: string)
    begin
      Inc(lCalls);
      lCopiedText := aText;
    end;
  try
    if GetEnvironmentVariable('ACV_S5_UI_STATE') = 'keyboard' then
      HoldEvidenceFormForUiProof(aForm, 'keyboard')
    else
      aForm.btnCopyEvidence.Click;
    if (lCalls <> 1) or (lCopiedText <> aForm.memDetails.Text) then
      raise Exception.Create('Copy evidence must call the fake once with the exact full memo');
    if (not ContainsText(lCopiedText, 'Session started ')) or
      ContainsText(lCopiedText, 'Session started unknown') then
      raise Exception.Create('Copy evidence omitted the persisted session start');
    if aForm.StatusText <> 'Evidence copied to the clipboard.' then
      raise Exception.Create('Copy evidence does not report success');
    MachineOverviewEvidenceClipboardWriter :=
      procedure(aText: string)
      begin
        FailEvidenceCopy(aText);
      end;
    aForm.btnCopyEvidence.Click;
    if aForm.StatusText <> 'Could not copy evidence to the clipboard: in-memory clipboard failure' then
      raise Exception.Create('Copy evidence must surface the adapter failure');
  finally
    MachineOverviewEvidenceClipboardWriter :=
      procedure(aText: string)
      begin
        RejectUnexpectedEvidenceCopy(aText);
      end;
  end;
end;

function RunIncidentEvidenceExportSelfTest: Integer;
var
  lText: string;
  lDatabase: string;
  lForm: TMachineOverviewHistoryFrm;
  lIncident: TMachineOverviewIncident;
  lRows: TArray<TMachineOverviewEvidenceRow>;
  lRow: TMachineOverviewEvidenceRow;
begin
  Result := 0;
  lIncident := EvidenceFixture('dst', EncodeDate(2026, 10, 25) + EncodeTime(0, 55, 0, 0)).Incident;
  lIncident.EndedAtUtc := EncodeDate(2026, 10, 25) + EncodeTime(1, 5, 0, 0);
  lIncident.PeakAtUtc := lIncident.EndedAtUtc;
  lIncident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].SystemCpu.PeakAtUtc := lIncident.EndedAtUtc;
  lText := FormatMachineOverviewIncidentDetails(lIncident, 'Injected standard-time name',
    function(aUtc: TDateTime): TDateTime
    begin
      if aUtc < EncodeDate(2026, 10, 25) + EncodeTime(1, 0, 0, 0) then
        Result := IncHour(aUtc, 2)
      else
        Result := IncHour(aUtc, 1);
    end);
  if not ContainsText(lText, 'Times are local with their UTC offset; Z times are authoritative.') or
    ContainsText(lText, 'Injected standard-time name') or
    not ContainsText(lText, '2026-10-25 02:55:00 +02:00 (2026-10-25 00:55:00.000Z)') or
    not ContainsText(lText, '2026-10-25 02:05:00 +01:00 (2026-10-25 01:05:00.000Z)') or
    not ContainsText(lText, 'peak 60% of machine at 2026-10-25 02:05:00 +01:00 (2026-10-25 01:05:00.000Z)') then
  begin
    Writeln('SELFTEST FAILED: S5 DST-crossing export must not claim one offset for all local times');
    Inc(Result);
  end;
  lIncident := EvidenceFixture('dst', EncodeDate(2026, 10, 25) + EncodeTime(0, 55, 0, 0)).Incident;
  lRows := MachineOverviewEvidenceRows(lIncident.Evidence);
  for lRow in lRows do
  begin
    if (ContainsText(lRow.AccessibleText, 'average Unavailable') or
      ContainsText(lRow.AccessibleText, 'peak Unavailable') or
      ((lRow.Average = 'Unavailable') and not ContainsText(lRow.AccessibleText, 'no measurement')) or
      ((lRow.Kind = 'Process') and not ContainsText(lRow.AccessibleText,
        '12.5% of machine')) or
      ContainsText(lRow.Phase + ' ' + lRow.Kind + ' ' + lRow.Name, 'System System')) then
    begin
      Writeln('SELFTEST FAILED: S5 measured and unmeasured row wording: ' + lRow.AccessibleText);
      Result := 1;
    end;
  end;
  if Result <> 0 then
    Exit;
  lText := FormatMachineOverviewIncidentDetails(EvidenceFixture('export',
    EncodeDate(2026, 10, 20)).Incident);
  Result := 1;
  if ContainsText(lText, 'Times are local with their UTC offset; Z times are authoritative.') and
    not ContainsText(lText, TTimeZone.Local.ID) and ContainsText(lText, 'Z)') and
    ContainsText(lText, '32 logical processors') and ContainsText(lText, '3.125%') and
    ContainsText(lText, '5000 ms') and ContainsText(lText, '1000 ms') and
    ContainsText(lText, 'measurements, not proof of cause') and ContainsText(lText, 'Gaps:') and
    ContainsText(lText, 'Detailed trace:') and not ContainsText(lText, 'Related executable paths') and
    ContainsText(lText, '= 4 logical processors busy') and ContainsText(lText, 'C:\Tools\export.exe') and
    not ContainsText(lText, 'truncated False') then
    Result := 0
  else
    Writeln('SELFTEST FAILED: S5 evidence export measurement, time, gap, trace, or privacy contract');
  if Result <> 0 then
    Exit;
  Result := 1;
  lDatabase := TPath.Combine(TPath.GetTempPath, Format('acv-s5-export-%d.db', [GetCurrentProcessId]));
  lForm := nil;
  try
    if not PersistIncidents(lDatabase, [EvidenceFixture('export', EncodeDate(2026, 10, 20))]) then
      Exit;
    lForm := TMachineOverviewHistoryFrm.Create(nil);
    lForm.Configure(lDatabase, EncodeDate(2026, 10, 20));
    if not lForm.RefreshAndWaitForTest(True, 5000) then
      Exit;
    PumpEvidence(lForm);
    if not lForm.btnCopyEvidence.Enabled or not ContainsText(lForm.memDetails.Text, 'Recording health:') or
      not ContainsText(lForm.memDetails.Text, 'Raw evidence: ' + lDatabase) or
      not ContainsText(lForm.memDetails.Text, 'table incident_evidence, incident_key export') then
      Exit;
    CheckEvidenceClipboard(lForm);
    Result := 0;
  finally
    lForm.Free;
    DeleteHistoryFiles(lDatabase);
  end;
end;

function RunIncidentWorkAreaSelfTest: Integer;
var
  lForm: TWorkAreaHistoryFrm;
  lDatabase: string;
  lButtonBottom: Integer;
  lWorkArea: TRect;
  lFailed: Boolean;
begin
  Result := 1;
  lDatabase := TPath.Combine(TPath.GetTempPath, Format('acv-s5-workarea-%d.db', [GetCurrentProcessId]));
  lForm := nil;
  try
    if not PersistIncidents(lDatabase, [EvidenceFixture('workarea', EncodeDate(2026, 10, 20))]) then
      Exit;
    lFailed := False;
    for lWorkArea in TArray<TRect>.Create(Rect(0, 0, 1920, 1008), Rect(0, 0, 1280, 680)) do
    begin
      lForm := TWorkAreaHistoryFrm.Create(nil);
      lForm.WorkArea := lWorkArea;
      lForm.Configure(lDatabase, EncodeDate(2026, 10, 20));
      lForm.ScaleForPPI(144);
      lForm.Show;
      lButtonBottom := lForm.btnClose.ClientToScreen(Point(0, lForm.btnClose.Height)).Y;
      if (lForm.BoundsRect.Left < lWorkArea.Left) or (lForm.BoundsRect.Top < lWorkArea.Top) or
        (lForm.BoundsRect.Right > lWorkArea.Right) or (lForm.BoundsRect.Bottom > lWorkArea.Bottom) or
        (lButtonBottom > lWorkArea.Bottom) then
      begin
        Writeln(Format('SELFTEST FAILED: S5 initial bounds and buttons must fit %dx%d at 144 PPI; ' +
          'bounds %d,%d,%d,%d; minimum %dx%d; button bottom %d', [lWorkArea.Width, lWorkArea.Height,
          lForm.Left, lForm.Top, lForm.BoundsRect.Right, lForm.BoundsRect.Bottom,
          lForm.Constraints.MinWidth, lForm.Constraints.MinHeight, lButtonBottom]));
        lFailed := True;
      end;
      if (lForm.Constraints.MinWidth <> 1020) or (lForm.Constraints.MinHeight <> 630) then
      begin
        Writeln('SELFTEST FAILED: S5 minimum must stay fixed at 1020x630 at 144 PPI');
        lFailed := True;
      end;
      FreeAndNil(lForm);
    end;

    lForm := TWorkAreaHistoryFrm.Create(nil);
    lForm.WorkArea := Rect(0, 0, 1280, 480);
    lForm.Configure(lDatabase, EncodeDate(2026, 10, 20));
    lForm.Show;
    if (lForm.Constraints.MinWidth <> 680) or (lForm.Constraints.MinHeight <> 420) then
    begin
      Writeln('SELFTEST FAILED: S5 show must preserve fixed minimum 680x420 at 96 PPI');
      lFailed := True;
    end;
    // Reproduce the same-DPI move with no DPI callback or re-show.
    lForm.WorkArea := Rect(0, 0, 1920, 1008);
    lForm.SetBounds(100, 100, 900, 700);
    if (lForm.Constraints.MinWidth <> 680) or (lForm.Constraints.MinHeight <> 420) then
    begin
      Writeln('SELFTEST FAILED: S5 same-DPI move must preserve fixed minimum 680x420');
      lFailed := True;
    end;
    FreeAndNil(lForm);

    lForm := TWorkAreaHistoryFrm.Create(nil);
    lForm.WorkArea := Rect(200, 100, 600, 400);
    lForm.Configure(lDatabase, EncodeDate(2026, 10, 20));
    lForm.Show;
    if (lForm.Left <> 200) or (lForm.Top <> 100) or
      (lForm.Width <> 680) or (lForm.Height <> 420) or
      (lForm.Constraints.MinWidth <> 680) or (lForm.Constraints.MinHeight <> 420) then
    begin
      Writeln('SELFTEST FAILED: S5 work area below fixed minimum must keep title bar reachable without changing constraints');
      lFailed := True;
    end;
    if not lFailed then
      Result := 0;
  finally
    lForm.Free;
    DeleteHistoryFiles(lDatabase);
  end;
end;

function RunMachineOverviewIncidentHistorySelfTests(
  const aArg: string): Integer;
var
  lProductionWriter: TProc<string>;
begin
  Result := -1;
  if not SameText(aArg, cMachineOverviewIncidentHistorySelfTestArg) then
    Exit;
  lProductionWriter := MachineOverviewEvidenceClipboardWriter;
  if not Assigned(lProductionWriter) then
    raise Exception.Create('The production clipboard adapter must be configured');
  MachineOverviewEvidenceClipboardWriter :=
    procedure(aText: string)
    begin
      RejectUnexpectedEvidenceCopy(aText);
    end;
  try
    try
      Result := RunIncidentEvidenceViewSelfTest;
      Result := Result + RunIncidentLegacyEvidenceViewSelfTest;
      Result := Result + RunIncidentHealthViewSelfTest;
      Result := Result + RunIncidentEvidenceExportSelfTest;
      Result := Result + RunIncidentHistoryFormSelfTest;
      Result := Result + RunIncidentWorkAreaSelfTest;
      Writeln(Format('Incident view: 6 tests, %d failed', [Result]));
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
  finally
    MachineOverviewEvidenceClipboardWriter := lProductionWriter;
  end;
end;

end.

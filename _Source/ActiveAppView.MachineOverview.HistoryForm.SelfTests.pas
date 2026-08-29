unit ActiveAppView.MachineOverview.HistoryForm.SelfTests;

interface

function RunMachineOverviewIncidentHistorySelfTests(
  const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.IOUtils, System.StrUtils, System.SysUtils,
  Winapi.Windows,
  Vcl.ComCtrls, Vcl.StdCtrls,
  AutoFree, FireDAC.Comp.Client, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper.Stat,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.HistoryForm,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewIncidentHistorySelfTestArg =
    '--self-test-machine-overview-incident-view';

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
  SetLength(Result.Incident.PreContext, 1);
  Result.Incident.PreContext[0].CapturedAtUtc := IncSecond(aUtc, -1);
  Result.Incident.PreContext[0].ProviderId := 'test-provider';
  Result.Incident.PreContext[0].Summary := 'before ' + aId;
  SetLength(Result.Incident.PostContext, 1);
  Result.Incident.PostContext[0].CapturedAtUtc := IncSecond(aUtc, 3);
  Result.Incident.PostContext[0].ProviderId := 'test-provider';
  Result.Incident.PostContext[0].Summary := 'after ' + aId;
end;

function CreateHistoryConfig(const aDatabaseFileName: string):
  TMachineOverviewHistoryConfig;
begin
  Result := Default(TMachineOverviewHistoryConfig);
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
    'ActiveAppView-MachineOverview\incident-view-tests');
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

    GC(lForm, TMachineOverviewHistoryFrm.Create(nil), g);
    if (Trim(lForm.Caption) = '') or
      (lForm.cbFilter.Style <> csDropDownList) or
      (lForm.cbFilter.Items.Count <> 3) or
      (lForm.cbFilter.TabOrder <> 0) or
      (lForm.lvIncidents.TabOrder <> 1) or
      (lForm.memDetails.TabOrder <> 2) or
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
    lDetails := lForm.memDetails.Text;
    if (lSelectedId <> 'beta') or
      (not ContainsText(lDetails, 'Beta details')) or
      (not ContainsText(lDetails, 'physical:0')) or
      (not ContainsText(lDetails, 'C:\Test\history.exe')) or
      (not ContainsText(lDetails, 'before beta')) or
      (not ContainsText(lDetails, 'after beta')) then
    begin
      Writeln('SELFTEST FAILED: incident details are incomplete');
      Exit;
    end;

    SetLength(lChanges, 1);
    lChanges[0] := CreateIncidentChange('newest', IncMinute(lNowUtc, -30),
      'Newest');
    if (not PersistIncidents(lDatabaseFileName, lChanges)) or
      (not lForm.RefreshAndWaitForTest(False, 5000)) or
      (lForm.IncidentAt(0).StableId <> 'newest') or
      (lForm.SelectedIncidentId <> lSelectedId) then
    begin
      Writeln('SELFTEST FAILED: refresh did not preserve the selected stable incident');
      Exit;
    end;

    GC(lConnection, TFDConnection.Create(nil), g);
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
    DeleteHistoryFiles(lDatabaseFileName);
    if TFile.Exists(lErrorDatabaseFileName) then
      TFile.Delete(lErrorDatabaseFileName);
  end;
end;

function RunMachineOverviewIncidentHistorySelfTests(
  const aArg: string): Integer;
begin
  Result := -1;
  if not SameText(aArg, cMachineOverviewIncidentHistorySelfTestArg) then
    Exit;
  try
    Result := RunIncidentHistoryFormSelfTest;
  except
    on lException: Exception do
    begin
      Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
        lException.Message]));
      Result := 1;
    end;
  end;
end;

end.

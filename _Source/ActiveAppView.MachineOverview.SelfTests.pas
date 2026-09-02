unit ActiveAppView.MachineOverview.SelfTests;

interface

function RunMachineOverviewSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.DateUtils, System.Diagnostics, System.IniFiles,
  System.IOUtils, System.Math, System.StrUtils, System.SyncObjs, System.SysUtils,
  System.Variants,
  Winapi.ActiveX, Winapi.CommCtrl, Winapi.oleacc, Winapi.PsAPI, Winapi.Windows,
  Vcl.ComCtrls, Vcl.Controls, Vcl.ExtCtrls, Vcl.Forms, Vcl.StdCtrls,
  AutoFree,
  ActiveAppView.MachineOverview.Commands, ActiveAppView.MachineOverview.DiskProvider,
  ActiveAppView.MachineOverview.Domain,
  ActiveAppView.MachineOverview.HelpForm,
  ActiveAppView.MachineOverview.History.SelfTests,
  ActiveAppView.MachineOverview.HistoryForm.SelfTests,
  ActiveAppView.MachineOverview.Incidents.SelfTests,
  ActiveAppView.MachineOverview.Layout,
  ActiveAppView.MachineOverview.OptionalProviders.SelfTests,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Presentation,
  ActiveAppView.MachineOverview.ProcessProvider,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Service,
  ActiveAppView.MachineOverview.Settings,
  ActiveAppView.MachineOverview.SystemCollector,
  ActiveAppView.MachineOverview.Trace.SelfTests,
  ActiveAppView.MachineOverview.Types,
  ActiveAppView.MachineOverview.View,
  ActiveAppView.MachineOverview.WindowsProviders;

const
  cMachineOverviewDomainSelfTestArg = '--self-test-machine-overview-domain';
  cMachineOverviewHelpSelfTestArg = '--self-test-machine-overview-help';
  cMachineOverviewLayoutSelfTestArg = '--self-test-machine-overview-layout';
  cMachineOverviewPipelineSelfTestArg = '--self-test-machine-overview-pipeline';
  cMachineOverviewPresentationSelfTestArg = '--self-test-machine-overview-presentation';
  cMachineOverviewProcessDiskSelfTestArg = '--self-test-machine-overview-process-disk';
  cMachineOverviewSettingsSelfTestArg = '--self-test-machine-overview-settings';
  cMachineOverviewSoakSelfTestArg = '--self-test-machine-overview-soak';
  cMachineOverviewSQLiteVersionSelfTestArg = '--self-test-machine-overview-sqlite-version';
  cMachineOverviewSystemProvidersSelfTestArg = '--self-test-machine-overview-system-providers';
  cMachineOverviewViewSelfTestArg = '--self-test-machine-overview-view';

type
  TSQLiteLibVersionFunction = function: PAnsiChar; cdecl;
  TSQLiteLibVersionNumberFunction = function: Integer; cdecl;

  TMachineOverviewSoakStats = record
    CpuTime100ns: UInt64;
    PrivateBytes: UInt64;
    WriteBytes: UInt64;
  end;

function MachineOverviewSoakFileTimeToUInt64(
  const aValue: TFileTime): UInt64;
begin
  Result := (UInt64(aValue.dwHighDateTime) shl 32) or
    UInt64(aValue.dwLowDateTime);
end;

function TryReadMachineOverviewSoakStats(
  out aStats: TMachineOverviewSoakStats): Boolean;
var
  lCounters: TProcessMemoryCountersEx;
  lCreationTime: TFileTime;
  lExitTime: TFileTime;
  lIoCounters: TIOCounters;
  lKernelTime: TFileTime;
  lUserTime: TFileTime;
begin
  aStats := Default(TMachineOverviewSoakStats);
  lCounters := Default(TProcessMemoryCountersEx);
  lCounters.cb := SizeOf(lCounters);
  lCreationTime := Default(TFileTime);
  lExitTime := Default(TFileTime);
  lIoCounters := Default(TIOCounters);
  lKernelTime := Default(TFileTime);
  lUserTime := Default(TFileTime);
  Result := GetProcessTimes(GetCurrentProcess, lCreationTime, lExitTime,
    lKernelTime, lUserTime) and
    GetProcessMemoryInfo(GetCurrentProcess,
      PPROCESS_MEMORY_COUNTERS(@lCounters), SizeOf(lCounters)) and
    GetProcessIoCounters(GetCurrentProcess, lIoCounters);
  if not Result then
    Exit;
  aStats.CpuTime100ns := MachineOverviewSoakFileTimeToUInt64(lKernelTime) +
    MachineOverviewSoakFileTimeToUInt64(lUserTime);
  aStats.PrivateBytes := lCounters.PrivateUsage;
  aStats.WriteBytes := lIoCounters.WriteTransferCount;
end;

function TryReadMachineOverviewSoakSeconds(out aSeconds: UInt64): Boolean;
const
  cDefaultSoakSeconds = 30;
  cMaximumSoakSeconds = 86400;
var
  lText: string;
begin
  lText := Trim(GetEnvironmentVariable('MACHINE_OVERVIEW_SOAK_SECONDS'));
  if lText.IsEmpty then
  begin
    aSeconds := cDefaultSoakSeconds;
    Exit(True);
  end;
  Result := TryStrToUInt64(lText, aSeconds) and (aSeconds > 0) and
    (aSeconds <= cMaximumSoakSeconds);
end;

function MachineOverviewSoakHistoryEnabled: Boolean;
var
  lText: string;
begin
  lText := Trim(GetEnvironmentVariable('MACHINE_OVERVIEW_SOAK_HISTORY'));
  Result := lText.IsEmpty or ((not SameText(lText, '0')) and
    (not SameText(lText, 'false')) and (not SameText(lText, 'no')));
end;

function TryExtractMachineOverviewDiagnosticValue(const aText,
  aPrefix: string; out aValue: UInt64): Boolean;
var
  lDigitCount: Integer;
  lStart: Integer;
  lValueText: string;
begin
  aValue := 0;
  lStart := Pos(aPrefix, aText);
  if lStart = 0 then
    Exit(False);
  Inc(lStart, Length(aPrefix));
  lDigitCount := 0;
  while (lStart + lDigitCount <= Length(aText)) and
    CharInSet(aText[lStart + lDigitCount], ['0'..'9']) do
    Inc(lDigitCount);
  if lDigitCount = 0 then
    Exit(False);
  lValueText := Copy(aText, lStart, lDigitCount);
  Result := TryStrToUInt64(lValueText, aValue);
end;

function TryExtractMachineOverviewQueueDiagnostics(const aText,
  aPrefix: string; out aDepth, aDropped: UInt64): Boolean;
var
  lLine: string;
  lLineEnd: Integer;
  lLineStart: Integer;
begin
  aDepth := 0;
  aDropped := 0;
  lLineStart := Pos(aPrefix, aText);
  if lLineStart = 0 then
    Exit(False);
  lLine := Copy(aText, lLineStart, MaxInt);
  lLineEnd := Pos(sLineBreak, lLine);
  if lLineEnd > 0 then
    lLine := Copy(lLine, 1, lLineEnd - 1);
  Result := TryExtractMachineOverviewDiagnosticValue(lLine, aPrefix,
    aDepth) and TryExtractMachineOverviewDiagnosticValue(lLine, 'dropped=',
    aDropped);
end;

function MachineOverviewSoakFileBytes(const aFileName: string): UInt64;
var
  lSize: Int64;
begin
  Result := 0;
  if not TFile.Exists(aFileName) then
    Exit;
  lSize := TFile.GetSize(aFileName);
  if lSize > 0 then
    Result := UInt64(lSize);
end;

function MachineOverviewSoakStorageBytes(const aDatabaseFileName: string): UInt64;
begin
  Result := MachineOverviewSoakFileBytes(aDatabaseFileName) +
    MachineOverviewSoakFileBytes(aDatabaseFileName + '-wal') +
    MachineOverviewSoakFileBytes(aDatabaseFileName + '-shm');
end;

procedure DeleteMachineOverviewSoakStorage(const aDatabaseFileName: string);
begin
  if TFile.Exists(aDatabaseFileName + '-shm') then
    TFile.Delete(aDatabaseFileName + '-shm');
  if TFile.Exists(aDatabaseFileName + '-wal') then
    TFile.Delete(aDatabaseFileName + '-wal');
  if TFile.Exists(aDatabaseFileName) then
    TFile.Delete(aDatabaseFileName);
end;

function BuildMachineOverviewViewPresentation(const aSequence: UInt64;
  const aSuffix: string): TMachineOverviewPresentation;
var
  i: Integer;
begin
  Result := Default(TMachineOverviewPresentation);
  Result.CapturedAtUtc := EncodeDate(2026, 8, 28) + EncodeTime(16, 0, 0, 0);
  Result.Sequence := aSequence;
  Result.DiagnosticText := 'diagnostic ' + aSuffix;
  SetLength(Result.Rows, 20);
  for i := 0 to High(Result.Rows) do
  begin
    Result.Rows[i].RowId := 'row:' + IntToStr(i + 1);
    Result.Rows[i].Category := 'Test';
    Result.Rows[i].LabelText := 'Label ' + IntToStr(i + 1);
    Result.Rows[i].ValueText := 'Value ' + aSuffix + ' ' + IntToStr(i + 1) +
      '; complete clipped detail C:\Program Files\Machine Overview\tool.exe';
    Result.Rows[i].Severity := TMachineOverviewSeverity.Normal;
    Result.Rows[i].Action := TMachineOverviewAction.None;
  end;
end;

function RunMachineOverviewHelpSelfTest: Integer;
const
  cRequiredTopics: array[0..31] of string = (
    'purpose', 'limitations', 'sampling', 'display refresh', 'Ctrl+E',
    'Shift+F8', 'Alt+H', 'Enter', 'Ctrl+C', 'Ctrl+Shift+C',
    '5, 15, and 60 seconds', 'hot logical processors', 'physical memory',
    'commit', 'available memory', 'paging', 'GPU engine',
    'dedicated memory', 'provider availability', 'disk active time',
    'latency', 'queue length', 'DPC', 'interrupts',
    'foreground reply time', 'DWM missed frames', 'private working set',
    'information not stored', '15-second WPR trace',
    'Profile system performance', '10 ETL traces', '2 GB total');
var
  g: TGarbos;
  lCloseButton: TButton;
  lComponent: TComponent;
  lExpectedPath: string;
  lForm: TMachineOverviewHelpFrm;
  lHelpFileName: string;
  lHelpText: string;
  lMemo: TMemo;
  lMissingFileName: string;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  lExpectedPath := TPath.Combine('C:\Program Files\ActiveAppView',
    cMachineOverviewHelpFileName);
  if MachineOverviewHelpPath('C:\Program Files\ActiveAppView') <>
    lExpectedPath then
  begin
    Writeln('SELFTEST FAILED: Machine Overview help path is not executable-local');
    Exit;
  end;

  lMissingFileName := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-Missing-Help-' + IntToStr(GetCurrentProcessId) + '.txt');
  lHelpText := LoadMachineOverviewHelpText(lMissingFileName);
  if (not ContainsText(lHelpText, 'help is unavailable')) or
    (not ContainsText(lHelpText, lMissingFileName)) then
  begin
    Writeln('SELFTEST FAILED: missing help fallback is not usable or does not name the path');
    Exit;
  end;

  lHelpFileName := MachineOverviewHelpPath(ExtractFilePath(ParamStr(0)));
  if not TFile.Exists(lHelpFileName) then
  begin
    Writeln('SELFTEST FAILED: MachineOverviewHelp.txt is not deployed beside the executable');
    Exit;
  end;
  lHelpText := LoadMachineOverviewHelpText(lHelpFileName);
  for i := Low(cRequiredTopics) to High(cRequiredTopics) do
    if not ContainsText(lHelpText, cRequiredTopics[i]) then
    begin
      Writeln('SELFTEST FAILED: Machine Overview help is missing topic: ' +
        cRequiredTopics[i]);
      Exit;
    end;

  GC(lForm, TMachineOverviewHelpFrm.Create(nil), g);
  lComponent := lForm.FindComponent('memHelp');
  if not (lComponent is TMemo) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview help has no standard memo');
    Exit;
  end;
  lMemo := TMemo(lComponent);
  lComponent := lForm.FindComponent('btnClose');
  if not (lComponent is TButton) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview help has no standard Close button');
    Exit;
  end;
  lCloseButton := TButton(lComponent);
  if (not lMemo.ReadOnly) or (lMemo.ScrollBars <> ssVertical) or
    (lMemo.Align <> alClient) or (lMemo.TabOrder <> 0) or
    (not lCloseButton.Cancel) or (lCloseButton.ModalResult = mrNone) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview help control contract is incomplete');
    Exit;
  end;
  lForm.Show;
  if lForm.ActiveControl <> lMemo then
  begin
    Writeln('SELFTEST FAILED: Machine Overview help did not focus the memo');
    Exit;
  end;
  Result := 0;
end;

function RunMachineOverviewLayoutSelfTest: Integer;
var
  g: TGarbos;
  lControl: TControl;
  lControls: TArray<TControl>;
  lForm: TForm;
  lIniFile: TMemIniFile;
  lLayout: TMachineOverviewLayoutController;
  lListView: TListView;
  lMachinePanel: TPanel;
  lMachineSplitter: TSplitter;
  lSettings: TMachineOverviewSettings;
  lWidths: TArray<Integer>;
  lVisibility: TArray<Boolean>;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lForm, TForm.CreateNew(nil), g);
  lForm.Width := 1200;
  lForm.Height := 400;
  SetLength(lControls, 11);
  SetLength(lWidths, Length(lControls));
  SetLength(lVisibility, Length(lControls));
  for i := 0 to High(lControls) do
  begin
    if Odd(i) then
      lControl := TSplitter.Create(lForm)
    else
      lControl := TPanel.Create(lForm);
    lControl.Parent := lForm;
    lControl.Align := alNone;
    lControl.Width := 80 + i;
    lControl.Visible := i <> 4;
    lControls[i] := lControl;
    lWidths[i] := lControl.Width;
    lVisibility[i] := lControl.Visible;
  end;
  lMachinePanel := TPanel.Create(lForm);
  lMachinePanel.Parent := lForm;
  lMachinePanel.Align := alRight;
  lMachinePanel.Width := 460;
  lMachineSplitter := TSplitter.Create(lForm);
  lMachineSplitter.Parent := lForm;
  lMachineSplitter.Align := alRight;
  lListView := TListView.Create(lForm);
  lListView.Parent := lMachinePanel;
  lListView.Align := alClient;
  GC(lLayout, TMachineOverviewLayoutController.Create(lControls,
    lMachinePanel, lMachineSplitter, lListView), g);
  lForm.Show;
  lLayout.ToggleFullView;
  lMachineSplitter.Width := 17;
  if (not lLayout.FullView) or (lMachinePanel.Align <> alClient) or
    lMachineSplitter.Visible or (lForm.ActiveControl <> lListView) then
  begin
    Writeln('SELFTEST FAILED: Full View did not fill and focus Machine Overview');
    Exit;
  end;
  for i := 0 to High(lControls) do
    if lControls[i].Visible then
    begin
      Writeln('SELFTEST FAILED: Full View left another panel or splitter visible');
      Exit;
    end;
  if lLayout.PanelWidthForPersistence <> 460 then
  begin
    Writeln('SELFTEST FAILED: Full View replaced the normal persisted width');
    Exit;
  end;
  lLayout.ToggleFullView;
  if lLayout.FullView or (lMachinePanel.Align <> alRight) or
    (lMachinePanel.Width <> 460) or (not lMachineSplitter.Visible) or
    (lMachineSplitter.Width <> 3) then
  begin
    Writeln('SELFTEST FAILED: Restore View did not restore Machine Overview');
    Exit;
  end;
  for i := 0 to High(lControls) do
    if (lControls[i].Visible <> lVisibility[i]) or
      (lControls[i].Width <> lWidths[i]) then
    begin
      Writeln('SELFTEST FAILED: Restore View changed prior layout state');
      Exit;
    end;

  if (ScaleMachineOverviewPanelWidth(420, 96) <> 420) or
    (ScaleMachineOverviewPanelWidth(420, 144) <> 630) or
    (ScaleMachineOverviewPanelWidth(420, 192) <> 840) then
  begin
    Writeln('SELFTEST FAILED: persisted panel width did not scale for DPI');
    Exit;
  end;
  GC(lIniFile, TMemIniFile.Create(''), g);
  SaveMachineOverviewPanelWidth(lIniFile, 630, 144);
  if lIniFile.ReadInteger('MachineOverview', 'PanelWidth', 0) <> 420 then
  begin
    Writeln('SELFTEST FAILED: scaled panel width did not persist as a logical width');
    Exit;
  end;
  lIniFile.WriteInteger('MachineOverview', 'PanelWidth', -1);
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if lSettings.PanelWidth <> TMachineOverviewSettings.Defaults.PanelWidth then
  begin
    Writeln('SELFTEST FAILED: invalid negative panel width did not use the default');
    Exit;
  end;
  lIniFile.WriteInteger('MachineOverview', 'PanelWidth', 9000);
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if lSettings.PanelWidth <> TMachineOverviewSettings.Defaults.PanelWidth then
  begin
    Writeln('SELFTEST FAILED: invalid oversized panel width did not use the default');
    Exit;
  end;
  Result := 0;
end;

function RunMachineOverviewViewSelfTest: Integer;
var
  g: TGarbos;
  lController: TMachineOverviewDisplayController;
  lAccessible: IAccessible;
  lAccessibleChild: OleVariant;
  lAccessibleName: WideString;
  lAccessibleResult: HResult;
  lNameResult: HResult;
  lFirstItem: TListItem;
  lForm: TForm;
  lListView: TListView;
  lOldTopIndex: Integer;
  lPresentation: TMachineOverviewPresentation;
  lView: IMachineOverviewView;
  lWindowText: array[0..255] of Char;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lForm, TForm.CreateNew(nil), g);
  lForm.Width := 640;
  lForm.Height := 220;
  lListView := TListView.Create(lForm);
  lListView.Parent := lForm;
  lListView.Align := alClient;
  lView := CreateMachineOverviewView(lListView);
  if not Assigned(lView) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview view factory returned nil');
    Exit;
  end;
  if (GetWindowText(lListView.Handle, lWindowText, Length(lWindowText)) = 0) or
    (string(lWindowText) <> 'Machine Overview') then
  begin
    Writeln('SELFTEST FAILED: Machine Overview list has no unambiguous accessible name');
    Exit;
  end;
  lAccessibleChild := CHILDID_SELF;
  lAccessibleResult := AccessibleObjectFromWindow(lListView.Handle,
    OBJID_CLIENT, IID_IAccessible, lAccessible);
  if (lAccessibleResult < 0) or (not Assigned(lAccessible)) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview MSAA name is unavailable');
    Exit;
  end;
  lNameResult := lAccessible.Get_accName(lAccessibleChild, lAccessibleName);
  if (lNameResult < 0) or (lAccessibleName <> 'Machine Overview') then
  begin
    Writeln('SELFTEST FAILED: Machine Overview MSAA name is unavailable');
    Exit;
  end;
  GC(lController, TMachineOverviewDisplayController.Create(lView), g);
  lPresentation := BuildMachineOverviewViewPresentation(1, 'A');
  lController.Publish(lPresentation);
  if (lListView.ViewStyle <> vsReport) or (not lListView.ReadOnly) or
    (not lListView.RowSelect) or lListView.HideSelection or
    (lListView.Columns.Count <> 1) or (lListView.Items.Count <> 20) or
    (lView.SelectedRowId <> 'row:1') or
    (lListView.Items[0].Caption <> lPresentation.Rows[0].LabelText + ': ' +
      lPresentation.Rows[0].ValueText) then
  begin
    Writeln('SELFTEST FAILED: standard list configuration or complete accessible row text is wrong');
    Exit;
  end;

  lForm.Show;
  lListView.SetFocus;
  lListView.Selected := lListView.Items[4];
  lListView.Selected.Focused := True;
  lFirstItem := lListView.Items[0];
  SendMessage(lListView.Handle, LVM_ENSUREVISIBLE, 12, 0);
  Application.ProcessMessages;
  lOldTopIndex := SendMessage(lListView.Handle, LVM_GETTOPINDEX, 0, 0);
  if lOldTopIndex <= 0 then
  begin
    Writeln('SELFTEST FAILED: view fixture did not establish a nonzero scroll position');
    Exit;
  end;

  lPresentation := BuildMachineOverviewViewPresentation(2, 'B');
  lController.Publish(lPresentation);
  if (lListView.Items[0] <> lFirstItem) or
    (lView.SelectedRowId <> 'row:5') or
    (lForm.ActiveControl <> lListView) or
    (SendMessage(lListView.Handle, LVM_GETTOPINDEX, 0, 0) <> lOldTopIndex) or
    (lController.LastRenderedSequence <> 2) or
    (not ContainsText(lListView.Selected.Caption, 'Value B 5')) then
  begin
    Writeln('SELFTEST FAILED: refresh replaced items or reset selection, focus, scroll, or sequence');
    Exit;
  end;

  lController.SetFrozen(True);
  lPresentation := BuildMachineOverviewViewPresentation(3, 'C');
  lController.Publish(lPresentation);
  if (not lController.Frozen) or (lController.LastRenderedSequence <> 2) or
    (not ContainsText(lListView.Selected.Caption, 'Value B 5')) or
    (lController.FullDiagnosticCopyText <> 'diagnostic B') then
  begin
    Writeln('SELFTEST FAILED: Freeze replaced the visible snapshot or copied hidden data');
    Exit;
  end;
  lController.SetFrozen(False);
  if lController.Frozen or (lController.LastRenderedSequence <> 3) or
    (not ContainsText(lListView.Selected.Caption, 'Value C 5')) or
    (lView.SelectedRowId <> 'row:5') or
    (not ContainsText(lController.SelectedRowCopyText,
      'Label 5: Value C 5; complete clipped detail')) then
  begin
    Writeln('SELFTEST FAILED: Resume did not render the newest snapshot or preserve copy/selection');
    Exit;
  end;

  lPresentation := BuildMachineOverviewViewPresentation(2, 'older');
  lController.Publish(lPresentation);
  if (lController.LastRenderedSequence <> 3) or
    ContainsText(lListView.Selected.Caption, 'older') then
  begin
    Writeln('SELFTEST FAILED: regressive presentation sequence replaced the latest view');
    Exit;
  end;
  Result := 0;
end;

procedure AddPresentationMeasurement(
  var aMeasurements: TArray<TMachineOverviewMeasurement>;
  const aName: string; const aEntityId: string; const aDisplayText: string;
  const aDetailText: string; const aStatusText: string; const aValue: Double;
  const aUnitText: string; const aAvailable: Boolean);
var
  lIndex: Integer;
begin
  lIndex := Length(aMeasurements);
  SetLength(aMeasurements, lIndex + 1);
  aMeasurements[lIndex] := Default(TMachineOverviewMeasurement);
  aMeasurements[lIndex].Name := aName;
  aMeasurements[lIndex].EntityId := aEntityId;
  aMeasurements[lIndex].DisplayText := aDisplayText;
  aMeasurements[lIndex].DetailText := aDetailText;
  aMeasurements[lIndex].StatusText := aStatusText;
  aMeasurements[lIndex].Value := aValue;
  aMeasurements[lIndex].UnitText := aUnitText;
  aMeasurements[lIndex].Available := aAvailable;
end;

procedure AddPresentationProviderState(
  var aStates: TArray<TMachineOverviewProviderState>; const aProviderId: string;
  const aStatus: TMachineOverviewProviderStatus; const aDataAgeMs: UInt64;
  const aErrorText: string);
var
  lIndex: Integer;
begin
  lIndex := Length(aStates);
  SetLength(aStates, lIndex + 1);
  aStates[lIndex] := Default(TMachineOverviewProviderState);
  aStates[lIndex].ProviderId := aProviderId;
  aStates[lIndex].Status := aStatus;
  aStates[lIndex].CapturedAtUtc := EncodeDate(2026, 8, 28) +
    EncodeTime(15, 30, 0, 0);
  aStates[lIndex].CapturedAtMonotonicMs := 119000;
  aStates[lIndex].DataAgeMs := aDataAgeMs;
  aStates[lIndex].ErrorText := aErrorText;
end;

procedure AddPresentationDiagnostic(
  var aDiagnostics: TArray<TMachineOverviewNamedDiagnostic>;
  const aName: string; const aValueText: string);
var
  lIndex: Integer;
begin
  lIndex := Length(aDiagnostics);
  SetLength(aDiagnostics, lIndex + 1);
  aDiagnostics[lIndex].Name := aName;
  aDiagnostics[lIndex].ValueText := aValueText;
end;

function PresentationContains(const aValue: string;
  const aExpected: array of string): Boolean;
var
  lExpected: string;
begin
  for lExpected in aExpected do
    if not ContainsText(aValue, lExpected) then
      Exit(False);
  Result := True;
end;

function RunMachineOverviewPresentationSelfTest: Integer;
var
  lExpectedIds: TArray<string>;
  lIndex: Integer;
  lPresentation: TMachineOverviewPresentation;
  lRow: TMachineOverviewRow;
  lSource: TMachineOverviewPresentationSource;
  lUnavailable: TMachineOverviewPresentation;
begin
  Result := 1;
  lSource := Default(TMachineOverviewPresentationSource);
  lSource.CapturedAtUtc := EncodeDate(2026, 8, 28) + EncodeTime(15, 30, 0, 0);
  lSource.CapturedAtMonotonicMs := 120000;
  lSource.Sequence := 42;
  lSource.OverallSeverity := TMachineOverviewSeverity.Warning;
  lSource.OverallReason := 'foreground response is slow; Disk 1 latency is elevated';
  lSource.IncidentCountLast24Hours := 7;
  SetLength(lSource.Incidents, 2);
  lSource.Incidents[0].OccurredAtLocal := EncodeDate(2026, 8, 28) +
    EncodeTime(7, 41, 0, 0);
  lSource.Incidents[0].Summary := 'Disk 1 latency reached 132 ms';
  lSource.Incidents[0].DiagnosticText := 'latency=132 ms; queue=3.4';
  lSource.Incidents[0].Severity := TMachineOverviewSeverity.Warning;
  lSource.Incidents[1].OccurredAtLocal := EncodeDate(2026, 8, 28) +
    EncodeTime(6, 55, 0, 0);
  lSource.Incidents[1].Summary := 'foreground application stalled for 1.4 s';
  lSource.Incidents[1].DiagnosticText := 'reply=1400 ms';
  lSource.Incidents[1].Severity := TMachineOverviewSeverity.Critical;
  lSource.CpuAggregate.NowValue.Available := True;
  lSource.CpuAggregate.NowValue.Value := 28.5;
  lSource.CpuAggregate.HotLogicalProcessorCount := 2;
  lSource.CpuAggregate.LogicalProcessorCount := 32;
  lSource.CpuAggregate.Window5Seconds.Available := True;
  lSource.CpuAggregate.Window5Seconds.Average := 24.1;
  lSource.CpuAggregate.Window5Seconds.Peak := 45.2;
  lSource.CpuAggregate.Window5Seconds.ValidSampleCount := 2;
  lSource.CpuAggregate.Window5Seconds.ExpectedSampleCount := 5;
  lSource.CpuAggregate.Window5Seconds.CoveragePercent := 40;
  lSource.CpuAggregate.Window5Seconds.CoverageSufficient := False;
  lSource.CpuAggregate.Window15Seconds.Available := True;
  lSource.CpuAggregate.Window15Seconds.Average := 21.2;
  lSource.CpuAggregate.Window15Seconds.Peak := 49.3;
  lSource.CpuAggregate.Window60Seconds.Available := True;
  lSource.CpuAggregate.Window60Seconds.Average := 18.4;
  lSource.CpuAggregate.Window60Seconds.Peak := 53.6;
  SetLength(lSource.LogicalProcessorValues, 2);
  lSource.LogicalProcessorValues[0].Available := True;
  lSource.LogicalProcessorValues[0].Value := 12.5;
  lSource.LogicalProcessorValues[1].Available := False;

  AddPresentationMeasurement(lSource.Measurements, 'disk_queue_length:physical:1',
    'physical:1', 'Disk 1', '', '', 3.4, 'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'physical_total_bytes', '', '',
    '', '', 64 * 1024 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'physical_available_bytes', '',
    '', '', '', 16 * 1024 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'physical_used_percent', '', '',
    '', '', 75, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'commit_percent', '', '', '',
    '', 68.2, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'paging_bytes_per_sec', '', '',
    '', '', 2 * 1024 * 1024, 'bytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements, 'paging_bytes_per_sec_peak_60s',
    '', '', '', '', 5 * 1024 * 1024, 'bytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements,
    'physical_available_bytes_low_15m', '', '', '', '',
    8 * 1024 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'cpu_package_temperature_c', '',
    '', '', 'ACPI', 61.5, 'celsius', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_overall_percent', '',
    '3D', '', '', 42, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_average_5s', '', '', '',
    'Stale; coverage 40%', 35, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_peak_5s', '', '', '', '',
    55, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_average_15s', '', '', '',
    '', 31, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_peak_15s', '', '', '', '',
    60, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_average_60s', '', '', '',
    '', 27, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_peak_60s', '', '', '', '',
    72, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_dedicated_bytes', '', '', '',
    '', 3 * 1024 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'gpu_temperature_c', '', '', '',
    'NVAPI', 58, 'celsius', True);
  AddPresentationMeasurement(lSource.Measurements, 'foreground_reply_ms', '', '', '',
    '', 84, 'milliseconds', True);
  AddPresentationMeasurement(lSource.Measurements, 'foreground_reply_max_60s', '', '',
    '', 'Stale; coverage 50%', 1400, 'milliseconds', True);
  AddPresentationMeasurement(lSource.Measurements, 'dpc_percent', '', '', '', '', 3.2,
    'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'dpc_percent_max_60s', '', '', '',
    '', 12.4, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'interrupt_percent', '', '', '', '',
    1.7, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'dwm_frames_missed_delta', '', '', '',
    '', 3, 'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'processor_queue_length', '', '', '',
    '', 2, 'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_count', '', '', '', '', 212,
    'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'thread_count', '', '', '', '', 3112,
    'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'handle_count', '', '', '', '', 98214,
    'count', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_worst', 'physical:1', 'Disk 1',
    '', IntToStr(Ord(TMachineOverviewDiskReason.Latency)),
    Ord(TMachineOverviewSeverity.Warning), 'severity', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_active_percent:physical:1',
    'physical:1', 'Disk 1', '', '', 92, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_read_mb_per_sec:physical:1',
    'physical:1', 'Disk 1', '', '', 114, 'megabytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_write_mb_per_sec:physical:1',
    'physical:1', 'Disk 1', '', '', 31, 'megabytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_latency_ms:physical:1',
    'physical:1', 'Disk 1', '', '', 16.2, 'milliseconds', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_latency_max_60s:physical:1',
    'physical:1', 'Disk 1', '', '', 132, 'milliseconds', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_active_percent:physical:0',
    'physical:0', 'System SSD', '', '', 4, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_volume_total_bytes:1:1',
    'physical:1', 'D:\', '', '', 1024 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'disk_volume_free_bytes:1:1',
    'physical:1', 'D:\', '', '', 256 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_cpu_rank:1', '1234:99',
    'cl.exe', 'C:\Tools\cl.exe', 'Available', 18, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_cpu_average_15s:1',
    '1234:99', 'cl.exe', '', 'Stale; coverage 50%', 12, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_cpu_peak_60s:1',
    '1234:99', 'cl.exe', '', '', 44, 'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_cpu_pids:1',
    '1234:99', '1234, 2345, 3456, 4567, 5678, 6789, 7890, 8901', '', '', 8,
    'process_ids', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_cpu_rank:2', '5678:100',
    'protected.exe', 'C:\Secret\protected.exe', 'Permission denied', 9,
    'percent', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_ram_rank:1', '2345:101',
    'database.exe', 'C:\Apps\database.exe', 'Available', 768 * 1024 * 1024.0,
    'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_ram_peak_60s:1',
    '2345:101', 'database.exe', '', '', 900 * 1024 * 1024.0, 'bytes', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_io_rank:1', '3456:102',
    'copy.exe', 'C:\Tools\copy.exe', 'Available', 22 * 1024 * 1024,
    'bytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_io_average_15s:1',
    '3456:102', 'copy.exe', '', '', 18 * 1024 * 1024,
    'bytes_per_second', True);
  AddPresentationMeasurement(lSource.Measurements, 'process_io_peak_60s:1',
    '3456:102', 'copy.exe', '', '', 35 * 1024 * 1024,
    'bytes_per_second', True);

  AddPresentationProviderState(lSource.ProviderStates, 'windows-core',
    TMachineOverviewProviderStatus.Available, 1000, '');
  AddPresentationProviderState(lSource.ProviderStates, 'gpu',
    TMachineOverviewProviderStatus.Stale, 6200, 'PDH counter set unavailable');
  AddPresentationProviderState(lSource.ProviderStates, 'unsafe',
    TMachineOverviewProviderStatus.Failed, 10,
    'window title: Secret Caption; command line: --token=secret');
  lSource.RawQueueDepth := 3;
  lSource.RawSamplesDropped := 2;
  lSource.HistoryQueueDepth := 4;
  lSource.HistoryRecordsDropped := 1;
  lSource.LastSQLiteCommitAvailable := True;
  lSource.LastSQLiteCommitDurationMs := 17;
  lSource.LastSQLiteError := 'database is locked';
  lSource.SelfMetricsAvailable := True;
  lSource.MonitorCpuPercent := 0.21;
  lSource.MonitorPrivateBytes := 42 * 1024 * 1024;
  lSource.MonitorWriteBytesPerSecond := 4096;
  AddPresentationDiagnostic(lSource.AdditionalDiagnostics,
    'collector_interval_ms', '1000');
  AddPresentationDiagnostic(lSource.AdditionalDiagnostics,
    'window_title', 'Secret Caption');
  AddPresentationDiagnostic(lSource.AdditionalDiagnostics,
    'command_line', '--token=secret');
  AddPresentationDiagnostic(lSource.AdditionalDiagnostics,
    'clipboard_contents', 'private text');

  lPresentation := BuildMachineOverviewPresentation(lSource);
  lExpectedIds := TArray<string>.Create('overall', 'incidents', 'cpu', 'memory',
    'gpu', 'responsiveness', 'system-counts', 'disk-summary',
    'disk:physical:0', 'disk:physical:1', 'top-cpu:1', 'top-cpu:2',
    'top-cpu:3', 'top-cpu:4', 'top-cpu:5', 'top-ram:1', 'top-ram:2',
    'top-ram:3', 'top-ram:4', 'top-ram:5', 'top-io:1', 'top-io:2',
    'top-io:3', 'top-io:4', 'top-io:5');
  if Length(lPresentation.Rows) <> Length(lExpectedIds) then
  begin
    Writeln(Format('SELFTEST FAILED: presentation row count expected=%d actual=%d',
      [Length(lExpectedIds), Length(lPresentation.Rows)]));
    Exit;
  end;
  for lIndex := 0 to High(lExpectedIds) do
    if lPresentation.Rows[lIndex].RowId <> lExpectedIds[lIndex] then
    begin
      Writeln(Format('SELFTEST FAILED: presentation row %d expected=%s actual=%s',
        [lIndex, lExpectedIds[lIndex], lPresentation.Rows[lIndex].RowId]));
      Exit;
    end;
  for lIndex := 0 to High(lPresentation.Rows) do
    if (lPresentation.Rows[lIndex].RowId = 'incidents') <>
      (lPresentation.Rows[lIndex].Action =
        TMachineOverviewAction.OpenIncidentHistory) then
    begin
      Writeln('SELFTEST FAILED: only the incidents row must be actionable');
      Exit;
    end;

  if (not TryFindMachineOverviewRow(lPresentation, 'overall', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['Warning', 'foreground response is slow', 'Disk 1'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'incidents', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['7', '07:41', 'Disk 1 latency', '06:55', 'stalled'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'cpu', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['28.5%', '2 of 32', '5 s', '24.1%', '45.2%', 'Stale', 'coverage 40%',
       '15 s', '60 s', '61.5'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'memory', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['48 GB', '75%', '68.2%', '2 MB/s', '5 MB/s', '8 GB', 'database.exe'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'gpu', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['42%', '3D', '5 s', 'coverage 40%', '15 s', '60 s', '3 GB', '58',
       'stale', '6.2 s'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'responsiveness', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['84 ms', '1.4 s', 'coverage 50%', '3.2%', '12.4%', '1.7%', '3', '2'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'system-counts', lRow)) or
    (not PresentationContains(lRow.ValueText, ['212', '3,112', '98,214'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'disk-summary', lRow)) or
    (not PresentationContains(lRow.ValueText, ['Disk 1', 'latency'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'disk:physical:1', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['92%', '114 MB/s', '31 MB/s', '16.2 ms', '132 ms', '3.4', 'D:\', '75%'])) then
  begin
    Writeln('SELFTEST FAILED: one or more fixed or disk rows omitted required content');
    Exit;
  end;
  if (not TryFindMachineOverviewRow(lPresentation, 'top-cpu:1', lRow)) or
    (not SameText(lRow.Category, 'Applications')) or
    (not PresentationContains(lRow.ValueText,
      ['cl.exe', '18%', '12%', 'coverage 50%', '44%',
       'PIDs 1234, 2345, 3456, 4567, 5678 (3 more)',
       'C:\Tools\cl.exe'])) or
    ContainsText(lRow.ValueText, '6789') or
    (MachineOverviewSelectedRowCopy(lRow) <> lRow.LabelText + ': ' +
      lRow.ValueText) or
    (not TryFindMachineOverviewRow(lPresentation, 'top-cpu:2', lRow)) or
    ContainsText(lRow.ValueText, 'C:\Secret\protected.exe') or
    (not ContainsText(lRow.ValueText, 'protected.exe')) or
    (not TryFindMachineOverviewRow(lPresentation, 'top-ram:1', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['database.exe', '768 MB', '900 MB', 'PID 2345', 'C:\Apps\database.exe'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'top-io:1', lRow)) or
    (not PresentationContains(lRow.ValueText,
      ['copy.exe', '22 MB/s', '18 MB/s', '35 MB/s', 'PID 3456'])) or
    (not TryFindMachineOverviewRow(lPresentation, 'top-io:5', lRow)) or
    (not ContainsText(lRow.ValueText, 'Unavailable')) then
  begin
    Writeln('SELFTEST FAILED: ranked process rows, path omission, copy, or placeholders are wrong');
    Exit;
  end;

  if not PresentationContains(lPresentation.DiagnosticText,
    ['Captured at UTC', 'Sequence: 42', 'Logical processor 0: 12.5%',
     'Logical processor 1: Unavailable', 'windows-core: Available',
     'gpu: Stale; age=6.2 s; error=PDH counter set unavailable',
     'raw queue depth=3; dropped=2', 'history queue depth=4; dropped=1',
     'SQLite commit: 17 ms; error=database is locked',
     'monitor CPU=0.21%', 'private memory=42 MB', 'write rate=4 KB/s',
     'latency=132 ms; queue=3.4',
     'process_cpu_rank:1 PIDs=1234, 2345, 3456, 4567, 5678, 6789, 7890, 8901',
     'process_cpu_rank:2 path status=Permission denied',
     'collector_interval_ms=1000']) or
    ContainsText(lPresentation.DiagnosticText, 'Secret Caption') or
    ContainsText(lPresentation.DiagnosticText, '--token=secret') or
    ContainsText(lPresentation.DiagnosticText, 'private text') then
  begin
    Writeln('SELFTEST FAILED: full diagnostics are incomplete or expose forbidden data');
    Exit;
  end;

  lSource := Default(TMachineOverviewPresentationSource);
  lUnavailable := BuildMachineOverviewPresentation(lSource);
  if (Length(lUnavailable.Rows) <> 23) or
    (not TryFindMachineOverviewRow(lUnavailable, 'gpu', lRow)) or
    (not ContainsText(lRow.ValueText, 'Unavailable')) or
    (lRow.Severity <> TMachineOverviewSeverity.Unavailable) or
    (not TryFindMachineOverviewRow(lUnavailable, 'top-cpu:5', lRow)) or
    (not ContainsText(lRow.ValueText, 'Unavailable')) then
  begin
    Writeln('SELFTEST FAILED: unavailable fixed/ranked rows were removed or ambiguous');
    Exit;
  end;

  Result := 0;
end;

type
  TFailingMachineOverviewProvider = class(TInterfacedObject,
    IMachineOverviewProvider)
  public
    procedure Collect(out aSample: TMachineOverviewProviderSample);
    function ProviderId: string;
  end;

procedure TFailingMachineOverviewProvider.Collect(
  out aSample: TMachineOverviewProviderSample);
begin
  aSample := Default(TMachineOverviewProviderSample);
  raise Exception.Create('deterministic provider failure');
end;

function TFailingMachineOverviewProvider.ProviderId: string;
begin
  Result := 'failing-provider';
end;

function CreateFailingMachineOverviewProvider: IMachineOverviewProvider;
begin
  Result := TFailingMachineOverviewProvider.Create;
end;

function RunSQLiteVersionSelfTest: Integer;
var
  lActualPath: string;
  lExpectedPath: string;
  lLibVersion: TSQLiteLibVersionFunction;
  lLibVersionNumber: TSQLiteLibVersionNumberFunction;
  lModule: HMODULE;
  lPathLength: Cardinal;
  lPathBuffer: array[0..MAX_PATH - 1] of Char;
  lVersion: string;
  lVersionNumber: Integer;
begin
  Result := 1;
  lExpectedPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sqlite3.dll');
  lModule := LoadLibrary(PChar(lExpectedPath));
  if lModule = 0 then
  begin
    Writeln('SELFTEST FAILED: packaged SQLite runtime module is unavailable');
    Exit;
  end;
  try
    lPathLength := GetModuleFileName(lModule, lPathBuffer,
      Length(lPathBuffer));
    if lPathLength = 0 then
    begin
      Writeln('SELFTEST FAILED: packaged SQLite runtime path is unavailable');
      Exit;
    end;
    SetString(lActualPath, lPathBuffer, lPathLength);
    if not SameFileName(lActualPath, lExpectedPath) then
    begin
      Writeln(Format('SELFTEST FAILED: SQLite loaded from %s instead of %s',
        [lActualPath, lExpectedPath]));
      Exit;
    end;
    lLibVersion := TSQLiteLibVersionFunction(GetProcAddress(lModule,
      'sqlite3_libversion'));
    lLibVersionNumber := TSQLiteLibVersionNumberFunction(GetProcAddress(lModule,
      'sqlite3_libversion_number'));
    if (not Assigned(lLibVersion)) or (not Assigned(lLibVersionNumber)) then
    begin
      Writeln('SELFTEST FAILED: packaged SQLite version exports are unavailable');
      Exit;
    end;
    lVersion := string(AnsiString(lLibVersion()));
    lVersionNumber := lLibVersionNumber();
    if lVersion.IsEmpty or (lVersionNumber < 3051030) then
    begin
      Writeln(Format(
        'SELFTEST FAILED: SQLite 3.51.3 or newer is required; actual=%s (%d)',
        [lVersion, lVersionNumber]));
      Exit;
    end;

    Writeln(Format(
      'SQLITE VERSION: %s (%d); binding=FireDAC dynamic; mode=packaged Win64 DLL; path=%s',
      [lVersion, lVersionNumber, lActualPath]));
    Result := 0;
  finally
    FreeLibrary(lModule);
  end;
end;

function TryFindSystemProviderMeasurement(const aSample: TMachineOverviewProviderSample;
  const aName: string; out aMeasurement: TMachineOverviewMeasurement): Boolean; forward;
function CountSystemProviderMeasurements(const aSample: TMachineOverviewProviderSample;
  const aPrefix: string): Integer; forward;
function HasRecentUtcTimestamp(
  const aSample: TMachineOverviewProviderSample): Boolean; forward;

function RunProcessProviderFixtureSelfTest: Integer;
var
  lCachedIdentity: TMachineOverviewProcessIdentity;
  lCurrentIdentity: TMachineOverviewProcessIdentity;
  lDelta: TMachineOverviewProcessDelta;
  lPrivateBytes: UInt64;
  lWorkingSetFlags: TArray<NativeUInt>;
begin
  Result := 1;
  if (not TryCalculateMachineOverviewProcessDelta(18000000, 2000000,
      12582912, 2097152, 2000, 32, lDelta)) or
    (not lDelta.CpuAvailable) or (Abs(lDelta.RawCpuPercent - 80) > 0.0001) or
    (Abs(lDelta.CpuPercent - 2.5) > 0.0001) or
    (not lDelta.IoAvailable) or
    (Abs(lDelta.IoBytesPerSecond - 5242880) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: process CPU/I/O delta units or machine normalization are wrong');
    Exit;
  end;
  if TryCalculateMachineOverviewProcessDelta(100, 200, 300, 400, 1000, 32,
    lDelta) or TryCalculateMachineOverviewProcessDelta(200, 100, 400, 300, 0,
    32, lDelta) or TryCalculateMachineOverviewProcessDelta(200, 100, 400, 300,
    1000, 0, lDelta) then
  begin
    Writeln('SELFTEST FAILED: process reset, zero interval, or zero CPU width was accepted');
    Exit;
  end;

  lCachedIdentity.ProcessId := 100;
  lCachedIdentity.CreationTime100ns := 1000;
  lCurrentIdentity := lCachedIdentity;
  if not ShouldReuseMachineOverviewProcessPath(lCachedIdentity,
    lCurrentIdentity, 10000, 20000, 15000) then
  begin
    Writeln('SELFTEST FAILED: live PID/creation-time path cache entry was not reused');
    Exit;
  end;
  lCurrentIdentity.CreationTime100ns := 1001;
  if ShouldReuseMachineOverviewProcessPath(lCachedIdentity, lCurrentIdentity,
    10000, 11000, 15000) then
  begin
    Writeln('SELFTEST FAILED: PID reuse inherited the previous process path');
    Exit;
  end;
  lCurrentIdentity := lCachedIdentity;
  if ShouldReuseMachineOverviewProcessPath(lCachedIdentity, lCurrentIdentity,
    10000, 26000, 15000) or
    ShouldReuseMachineOverviewProcessPath(lCachedIdentity, lCurrentIdentity,
      20000, 10000, 15000) then
  begin
    Writeln('SELFTEST FAILED: expired or non-monotonic path cache entry was reused');
    Exit;
  end;
  if (ClassifyMachineOverviewProcessPathFailure(ERROR_ACCESS_DENIED, True) <>
      TMachineOverviewProcessPathStatus.PermissionDenied) or
    (ClassifyMachineOverviewProcessPathFailure(ERROR_INVALID_PARAMETER, False) <>
      TMachineOverviewProcessPathStatus.Exited) or
    (ClassifyMachineOverviewProcessPathFailure(ERROR_NOT_SUPPORTED, True) <>
      TMachineOverviewProcessPathStatus.Unavailable) then
  begin
    Writeln('SELFTEST FAILED: process path failure status was misclassified');
    Exit;
  end;
  lWorkingSetFlags := [0, $100, $80];
  if (not TryCalculateMachineOverviewPrivateWorkingSet(lWorkingSetFlags, 4096,
      lPrivateBytes)) or (lPrivateBytes <> 8192) or
    TryCalculateMachineOverviewPrivateWorkingSet(lWorkingSetFlags, 0,
      lPrivateBytes) then
  begin
    Writeln('SELFTEST FAILED: private working-set page flags or byte width are wrong');
    Exit;
  end;
  Result := 0;
end;

function RunProcessProviderLiveSelfTest: Integer;
var
  g: TGarbos;
  lCollectStartedMs: UInt64;
  lFirstCollectDurationMs: UInt64;
  lCpuCount: Integer;
  lIoCount: Integer;
  lMeasurement: TMachineOverviewMeasurement;
  lProvider: IMachineOverviewProvider;
  lRamCount: Integer;
  lSample: TMachineOverviewProviderSample;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lCollectStartedMs := GetTickCount64;
  lProvider := CreateMachineOverviewProcessProvider;
  if (not Assigned(lProvider)) or (lProvider.ProviderId <> 'processes') then
  begin
    Writeln('SELFTEST FAILED: process provider factory returned the wrong provider');
    Exit;
  end;
  lProvider.Collect(lSample);
  lFirstCollectDurationMs := GetTickCount64 - lCollectStartedMs;
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  if lWaitEvent.WaitFor(250) <> wrTimeout then
  begin
    Writeln('SELFTEST FAILED: process provider warm-up wait was unexpectedly signaled');
    Exit;
  end;
  lCollectStartedMs := GetTickCount64;
  lProvider.Collect(lSample);
  if (lFirstCollectDurationMs > 1500) or
    (GetTickCount64 - lCollectStartedMs > 1500) or
    (lSample.State.Status <> TMachineOverviewProviderStatus.Available) or
    (not HasRecentUtcTimestamp(lSample)) then
  begin
    Writeln(Format(
      'SELFTEST FAILED: live process enumeration was unavailable or exceeded its budget (first=%d ms)',
      [lFirstCollectDurationMs]));
    Exit;
  end;
  lCpuCount := CountSystemProviderMeasurements(lSample, 'process_cpu_rank:');
  lRamCount := CountSystemProviderMeasurements(lSample, 'process_ram_rank:');
  lIoCount := CountSystemProviderMeasurements(lSample, 'process_io_rank:');
  if (lCpuCount < 1) or (lCpuCount > 5) or (lRamCount < 1) or
    (lRamCount > 5) or (lIoCount < 1) or (lIoCount > 5) then
  begin
    Writeln('SELFTEST FAILED: process provider did not produce bounded top-five application rankings');
    Exit;
  end;
  if (CountSystemProviderMeasurements(lSample,
      'process_cpu_average_15s:') <> lCpuCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_cpu_peak_60s:') <> lCpuCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_cpu_pids:') <> lCpuCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_ram_peak_60s:') <> lRamCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_ram_pids:') <> lRamCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_io_average_15s:') <> lIoCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_io_peak_60s:') <> lIoCount) or
    (CountSystemProviderMeasurements(lSample,
      'process_io_pids:') <> lIoCount) then
  begin
    Writeln('SELFTEST FAILED: ranked application rolling metrics or PID lists are missing');
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample,
      'process_cpu_average_15s:1', lMeasurement)) or
    (not ContainsText(lMeasurement.StatusText, 'coverage')) then
  begin
    Writeln('SELFTEST FAILED: process rolling coverage status is missing');
    Exit;
  end;
  for lMeasurement in lSample.Measurements do
    if StartsText('process_cpu_rank:', lMeasurement.Name) or
      StartsText('process_ram_rank:', lMeasurement.Name) or
      StartsText('process_io_rank:', lMeasurement.Name) then
      if (not lMeasurement.Available) or (lMeasurement.Value < 0) or
        lMeasurement.EntityId.IsEmpty or lMeasurement.DisplayText.IsEmpty or
        lMeasurement.StatusText.IsEmpty then
      begin
        Writeln('SELFTEST FAILED: ranked application omitted identity, name, path status, or metric');
        Exit;
      end;
  if (not TryFindSystemProviderMeasurement(lSample, 'process_enumerated_count',
      lMeasurement)) or (not lMeasurement.Available) or
    (lMeasurement.Value < lCpuCount) or
    (not TryFindSystemProviderMeasurement(lSample, 'process_access_denied_count',
      lMeasurement)) or (not lMeasurement.Available) or
    (not TryFindSystemProviderMeasurement(lSample, 'process_path_cache_count',
      lMeasurement)) or (not lMeasurement.Available) then
  begin
    Writeln('SELFTEST FAILED: process provider diagnostics are incomplete');
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample, 'monitor_cpu_percent',
      lMeasurement)) or (not lMeasurement.Available) or
    (lMeasurement.Value < 0) or (lMeasurement.Value > 100) or
    (not TryFindSystemProviderMeasurement(lSample, 'monitor_private_bytes',
      lMeasurement)) or (not lMeasurement.Available) or
    (lMeasurement.Value <= 0) or
    (not TryFindSystemProviderMeasurement(lSample,
      'monitor_write_bytes_per_second', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value < 0) then
  begin
    Writeln('SELFTEST FAILED: process provider omitted live monitor overhead metrics');
    Exit;
  end;
  Result := 0;
end;

function RunDiskProviderFixtureSelfTest: Integer;
var
  lDiskNumber: Cardinal;
  lLatencies: TArray<TMachineOverviewTimedDiskLatency>;
  lMaximumMs: Double;
  lMetric: TMachineOverviewDiskMetric;
  lVolumes: TArray<TMachineOverviewVolumeFixture>;
  lMappedVolumes: TArray<TMachineOverviewDiskVolume>;
begin
  Result := 1;
  if (not TryParseMachineOverviewPhysicalDiskInstance('12 C: D:',
      lDiskNumber)) or (lDiskNumber <> 12) or
    TryParseMachineOverviewPhysicalDiskInstance('_Total', lDiskNumber) or
    TryParseMachineOverviewPhysicalDiskInstance('HarddiskVolume3', lDiskNumber) then
  begin
    Writeln('SELFTEST FAILED: physical-disk instance identity parsing is unstable');
    Exit;
  end;
  SetLength(lVolumes, 3);
  lVolumes[0].RootPath := 'C:\';
  lVolumes[0].DiskNumbers := [0];
  lVolumes[0].CapacityAvailable := True;
  lVolumes[0].TotalBytes := 100;
  lVolumes[0].FreeBytes := 40;
  lVolumes[1].RootPath := 'D:\';
  lVolumes[1].DiskNumbers := [1, 0, 1];
  lVolumes[1].CapacityAvailable := True;
  lVolumes[1].TotalBytes := 200;
  lVolumes[1].FreeBytes := 50;
  lVolumes[2].RootPath := 'E:\';
  lVolumes[2].DiskNumbers := [2];
  lMappedVolumes := BuildMachineOverviewDiskVolumes(lVolumes);
  if (Length(lMappedVolumes) <> 4) or
    (lMappedVolumes[0].DiskNumber <> 0) or
    (lMappedVolumes[0].RootPath <> 'C:\') or
    (lMappedVolumes[1].DiskNumber <> 0) or
    (lMappedVolumes[1].RootPath <> 'D:\') or
    (lMappedVolumes[2].DiskNumber <> 1) or
    (lMappedVolumes[2].RootPath <> 'D:\') or
    (lMappedVolumes[3].DiskNumber <> 2) or
    lMappedVolumes[3].CapacityAvailable then
  begin
    Writeln('SELFTEST FAILED: multi-volume or multi-extent disk mapping is incorrect');
    Exit;
  end;
  if (not TryCalculateMachineOverviewDiskMetric(3, 120, 10485760,
      5242880, 0.0125, 2, lMetric)) or
    (lMetric.Identity.StableId <> 'physical:3') or
    (Abs(lMetric.SustainedActivePercent - 100) > 0.0001) or
    (Abs(lMetric.ReadMBPerSecond - 10) > 0.0001) or
    (Abs(lMetric.WriteMBPerSecond - 5) > 0.0001) or
    (Abs(lMetric.SustainedLatencyMs - 12.5) > 0.0001) or
    (Abs(lMetric.SustainedQueueLength - 2) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: physical-disk units or active-time cap are wrong');
    Exit;
  end;
  if TryCalculateMachineOverviewDiskMetric(3, -1, 0, 0, 0, 0, lMetric) or
    TryCalculateMachineOverviewDiskMetric(3, 1, NaN, 0, 0, 0, lMetric) then
  begin
    Writeln('SELFTEST FAILED: invalid physical-disk counter was accepted');
    Exit;
  end;
  SetLength(lLatencies, 5);
  lLatencies[0].CapturedAtMonotonicMs := 39000;
  lLatencies[0].Available := True;
  lLatencies[0].LatencyMs := 999;
  lLatencies[1].CapturedAtMonotonicMs := 40000;
  lLatencies[1].Available := True;
  lLatencies[1].LatencyMs := 10;
  lLatencies[2].CapturedAtMonotonicMs := 70000;
  lLatencies[2].Available := False;
  lLatencies[3].CapturedAtMonotonicMs := 99000;
  lLatencies[3].Available := True;
  lLatencies[3].LatencyMs := 80;
  lLatencies[4].CapturedAtMonotonicMs := 100001;
  lLatencies[4].Available := True;
  lLatencies[4].LatencyMs := 500;
  if (not TryCalculateMachineOverviewDiskLatencyMaximum(lLatencies, 100000,
      60000, lMaximumMs)) or (Abs(lMaximumMs - 80) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: 60-second disk latency maximum used stale, future, or missing data');
    Exit;
  end;
  Result := 0;
end;

function CountMachineOverviewLocalVolumes: Integer;
var
  lBuffer: TArray<WideChar>;
  lDriveType: Cardinal;
  lFindHandle: THandle;
begin
  Result := 0;
  SetLength(lBuffer, MAX_PATH + 1);
  lFindHandle := FindFirstVolumeW(@lBuffer[0], Length(lBuffer));
  if lFindHandle = INVALID_HANDLE_VALUE then
    Exit;
  try
    repeat
      lDriveType := GetDriveTypeW(@lBuffer[0]);
      if lDriveType in [DRIVE_FIXED, DRIVE_REMOVABLE] then
        Inc(Result);
    until not FindNextVolumeW(lFindHandle, @lBuffer[0], Length(lBuffer));
  finally
    FindVolumeClose(lFindHandle);
  end;
end;

function RunDiskProviderLiveSelfTest: Integer;
var
  g: TGarbos;
  lActiveCount: Integer;
  lExpectedVolumeCount: Integer;
  lMeasurement: TMachineOverviewMeasurement;
  lProvider: IMachineOverviewProvider;
  lSample: TMachineOverviewProviderSample;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lProvider := CreateMachineOverviewDiskProvider;
  if (not Assigned(lProvider)) or (lProvider.ProviderId <> 'disks') then
  begin
    Writeln('SELFTEST FAILED: disk provider factory returned the wrong provider');
    Exit;
  end;
  lProvider.Collect(lSample);
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  if lWaitEvent.WaitFor(250) <> wrTimeout then
  begin
    Writeln('SELFTEST FAILED: disk provider warm-up wait was unexpectedly signaled');
    Exit;
  end;
  lProvider.Collect(lSample);
  if (lSample.State.Status <> TMachineOverviewProviderStatus.Available) or
    (not HasRecentUtcTimestamp(lSample)) then
  begin
    Writeln('SELFTEST FAILED: live physical-disk collection was unavailable');
    Exit;
  end;
  lActiveCount := CountSystemProviderMeasurements(lSample,
    'disk_active_percent:');
  lExpectedVolumeCount := CountMachineOverviewLocalVolumes;
  if lActiveCount < 1 then
  begin
    Writeln('SELFTEST FAILED: live provider omitted physical-disk rows');
    Exit;
  end;
  for lMeasurement in lSample.Measurements do
    if StartsText('disk_active_percent:', lMeasurement.Name) then
      if (not lMeasurement.Available) or (lMeasurement.Value < 0) or
        (lMeasurement.Value > 100) or lMeasurement.EntityId.IsEmpty or
        lMeasurement.DisplayText.IsEmpty then
      begin
        Writeln('SELFTEST FAILED: physical-disk row identity or active time is invalid');
        Exit;
      end;
  if (CountSystemProviderMeasurements(lSample, 'disk_read_mb_per_sec:') <
      lActiveCount) or
    (CountSystemProviderMeasurements(lSample, 'disk_write_mb_per_sec:') <
      lActiveCount) or
    (CountSystemProviderMeasurements(lSample, 'disk_latency_ms:') <
      lActiveCount) or
    (CountSystemProviderMeasurements(lSample, 'disk_queue_length:') <
      lActiveCount) or
    (CountSystemProviderMeasurements(lSample, 'disk_latency_max_60s:') <
      lActiveCount) then
  begin
    Writeln('SELFTEST FAILED: physical-disk row omitted a required metric');
    Exit;
  end;
  if (CountSystemProviderMeasurements(lSample, 'disk_volume_total_bytes:') < 1) or
    (not TryFindSystemProviderMeasurement(lSample, 'disk_count', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value < lActiveCount) or
    (not TryFindSystemProviderMeasurement(lSample, 'disk_volume_count',
      lMeasurement)) or (not lMeasurement.Available) or
    (lMeasurement.Value < lExpectedVolumeCount) or
    (not TryFindSystemProviderMeasurement(lSample, 'disk_worst', lMeasurement)) or
    (not lMeasurement.Available) or lMeasurement.EntityId.IsEmpty then
  begin
    Writeln('SELFTEST FAILED: disk capacity, worst-disk, or count diagnostics are incomplete');
    Exit;
  end;
  Result := 0;
end;

function RunProcessDiskCollectorPipelineSelfTest: Integer;
var
  g: TGarbos;
  lDeadlineMs: UInt64;
  lDiskCollector: TMachineOverviewSystemCollector;
  lDiskSeen: Boolean;
  lHistorySample: IMachineOverviewRawSample;
  lPipeline: TMachineOverviewPipeline;
  lProcessCollector: TMachineOverviewSystemCollector;
  lProcessSeen: Boolean;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lDiskSeen := False;
  lProcessSeen := False;
  GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
  GC(lDiskCollector, TMachineOverviewSystemCollector.Create(lPipeline, 100,
    CreateMachineOverviewDiskProvider), g);
  GC(lProcessCollector, TMachineOverviewSystemCollector.Create(lPipeline, 100,
    CreateMachineOverviewProcessProvider), g);
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(2000) then
  begin
    Writeln('SELFTEST FAILED: process/disk collector pipeline did not start');
    Exit;
  end;
  lDiskCollector.Start;
  lProcessCollector.Start;
  if (not lDiskCollector.WaitUntilRunning(2000)) or
    (not lProcessCollector.WaitUntilRunning(2000)) then
  begin
    Writeln('SELFTEST FAILED: process/disk collectors did not start on schedule');
    Exit;
  end;
  lDeadlineMs := GetTickCount64 + 5000;
  repeat
  begin
    while lPipeline.TryTakeHistory(lHistorySample) do
    begin
      if lHistorySample.ProviderId = 'disks' then
        lDiskSeen := True
      else if lHistorySample.ProviderId = 'processes' then
        lProcessSeen := True;
    end;
    if lDiskSeen and lProcessSeen then
      Break;
    lWaitEvent.WaitFor(10);
  end;
  until GetTickCount64 >= lDeadlineMs;
  if (not lDiskSeen) or (not lProcessSeen) then
  begin
    Writeln('SELFTEST FAILED: process/disk collectors did not both publish within bounds');
    Exit;
  end;
  if (lDiskCollector.Diagnostics.ActiveWorkerCount <> 1) or
    (lProcessCollector.Diagnostics.ActiveWorkerCount <> 1) then
  begin
    Writeln('SELFTEST FAILED: process/disk provider factory or worker ownership is wrong');
    Exit;
  end;
  if (lProcessCollector.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) or
    (lDiskCollector.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) or
    (lPipeline.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) then
  begin
    Writeln('SELFTEST FAILED: process/disk collectors did not stop within bounds');
    Exit;
  end;
  Result := 0;
end;

function RunCollectorFailureAttributionSelfTest: Integer;
var
  g: TGarbos;
  lCollector: TMachineOverviewSystemCollector;
  lHistorySample: IMachineOverviewRawSample;
  lPipeline: TMachineOverviewPipeline;
  lProviderSample: TMachineOverviewProviderSample;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(4, 4), g);
  GC(lCollector, TMachineOverviewSystemCollector.Create(lPipeline, 100,
    CreateFailingMachineOverviewProvider), g);
  lPipeline.Start;
  lCollector.Start;
  if (not lPipeline.WaitUntilRunning(2000)) or
    (not lCollector.WaitUntilRunning(2000)) or
    (not lPipeline.WaitForSequence(1, 2000)) or
    (not lPipeline.TryTakeHistory(lHistorySample)) then
  begin
    Writeln('SELFTEST FAILED: failing collector did not publish its degraded sample');
    Exit;
  end;
  lProviderSample := lHistorySample.ProviderSample;
  if (lHistorySample.ProviderId <> 'failing-provider') or
    (lProviderSample.State.ProviderId <> 'failing-provider') or
    (lProviderSample.State.Status <> TMachineOverviewProviderStatus.Failed) or
    lProviderSample.State.ErrorText.IsEmpty then
  begin
    Writeln('SELFTEST FAILED: collector failure was attributed to the wrong provider');
    Exit;
  end;
  if (lCollector.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) or
    (lPipeline.Stop(2000) <> TMachineOverviewShutdownResult.Stopped) then
  begin
    Writeln('SELFTEST FAILED: failing collector did not stop within bounds');
    Exit;
  end;
  Result := 0;
end;

function RunSystemProviderFixtureSelfTest: Integer;
var
  lDelta: UInt64;
  lLastIndex: Cardinal;
  lProbe: TMachineOverviewForegroundProbeResult;
  lValue: Double;
  lValueBytes: UInt64;
begin
  Result := 1;
  if (not TryAcceptMachineOverviewPdhValue(0, 42.5, 0, 100, lValue)) or
    (Abs(lValue - 42.5) > 0.0001) or
    (not TryAcceptMachineOverviewPdhValue(1, 100, 0, 100, lValue)) or
    TryAcceptMachineOverviewPdhValue(2, 50, 0, 100, lValue) or
    TryAcceptMachineOverviewPdhValue(0, NaN, 0, 100, lValue) or
    TryAcceptMachineOverviewPdhValue(0, Infinity, 0, 100, lValue) or
    TryAcceptMachineOverviewPdhValue(0, 101, 0, 100, lValue) then
  begin
    Writeln('SELFTEST FAILED: PDH fixture status or finite-range validation failed');
    Exit;
  end;
  if (not TryMachineOverviewCounterDelta(150, 100, True, lDelta)) or
    (lDelta <> 50) or TryMachineOverviewCounterDelta(50, 100, True, lDelta) or
    TryMachineOverviewCounterDelta(150, 100, False, lDelta) then
  begin
    Writeln('SELFTEST FAILED: cumulative counter delta did not reject warm-up or reset');
    Exit;
  end;
  if (not TryMachineOverviewPageCountToBytes(100, 4096, lValueBytes)) or
    (lValueBytes <> 409600) or
    TryMachineOverviewPageCountToBytes(High(UInt64), 2, lValueBytes) then
  begin
    Writeln('SELFTEST FAILED: page-count conversion overflowed or used the wrong width');
    Exit;
  end;
  if TryMachineOverviewCounterIndexBounds(0, lLastIndex) or
    (not TryMachineOverviewCounterIndexBounds(2, lLastIndex)) or
    (lLastIndex <> 1) then
  begin
    Writeln('SELFTEST FAILED: zero-length PDH array bounds were not rejected');
    Exit;
  end;
  if (ClassifyMachineOverviewWindowsProviderStatus(False, False) <>
      TMachineOverviewProviderStatus.Unavailable) or
    (ClassifyMachineOverviewWindowsProviderStatus(True, False) <>
      TMachineOverviewProviderStatus.Available) or
    (ClassifyMachineOverviewWindowsProviderStatus(False, True) <>
      TMachineOverviewProviderStatus.Available) then
  begin
    Writeln('SELFTEST FAILED: provider unavailable-to-available recovery was misclassified');
    Exit;
  end;

  lProbe := ClassifyMachineOverviewForegroundProbe(True, True, True, 0, 12, 50);
  if (lProbe.Status <> TMachineOverviewForegroundProbeStatus.Responsive) or
    (not lProbe.ResponseMs.Available) or (Abs(lProbe.ResponseMs.Value - 12) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: successful foreground response was not classified as responsive');
    Exit;
  end;
  lProbe := ClassifyMachineOverviewForegroundProbe(True, True, False,
    ERROR_ACCESS_DENIED, 1, 50);
  if lProbe.Status <> TMachineOverviewForegroundProbeStatus.PermissionDenied then
  begin
    Writeln('SELFTEST FAILED: foreground access denial was reported as a stall');
    Exit;
  end;
  lProbe := ClassifyMachineOverviewForegroundProbe(True, False, False, 0, 1, 50);
  if lProbe.Status <> TMachineOverviewForegroundProbeStatus.WindowGone then
  begin
    Writeln('SELFTEST FAILED: destroyed foreground window was reported as a stall');
    Exit;
  end;
  lProbe := ClassifyMachineOverviewForegroundProbe(False, False, False, 0, 0, 50);
  if lProbe.Status <> TMachineOverviewForegroundProbeStatus.Unavailable then
  begin
    Writeln('SELFTEST FAILED: missing foreground window was not reported unavailable');
    Exit;
  end;
  lProbe := ClassifyMachineOverviewForegroundProbe(True, True, False, 0, 50, 50);
  if lProbe.Status <> TMachineOverviewForegroundProbeStatus.TimedOut then
  begin
    Writeln('SELFTEST FAILED: bounded foreground timeout was not distinguished from failure');
    Exit;
  end;

  Result := 0;
end;

function TryFindSystemProviderMeasurement(const aSample: TMachineOverviewProviderSample;
  const aName: string; out aMeasurement: TMachineOverviewMeasurement): Boolean;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  aMeasurement := Default(TMachineOverviewMeasurement);
  for lMeasurement in aSample.Measurements do
    if SameText(lMeasurement.Name, aName) then
    begin
      aMeasurement := lMeasurement;
      Exit(True);
    end;
  Result := False;
end;

function CountSystemProviderMeasurements(const aSample: TMachineOverviewProviderSample;
  const aPrefix: string): Integer;
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  Result := 0;
  for lMeasurement in aSample.Measurements do
    if StartsText(aPrefix, lMeasurement.Name) then
      Inc(Result);
end;

function HasRecentUtcTimestamp(
  const aSample: TMachineOverviewProviderSample): Boolean;
begin
  Result := MilliSecondsBetween(aSample.State.CapturedAtUtc,
    TTimeZone.Local.ToUniversalTime(Now)) <= 5000;
end;

function RunSystemProviderLiveSelfTest: Integer;
var
  g: TGarbos;
  lCollectStartedMs: UInt64;
  lExpectedLogicalCount: Cardinal;
  lMeasurement: TMachineOverviewMeasurement;
  lProvider: IMachineOverviewProvider;
  lSample: TMachineOverviewProviderSample;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lProvider := CreateMachineOverviewWindowsProvider;
  if (not Assigned(lProvider)) or (lProvider.ProviderId <> 'windows-core') then
  begin
    Writeln('SELFTEST FAILED: Windows provider factory returned the wrong provider');
    Exit;
  end;
  lProvider.Collect(lSample);
  GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
  if lWaitEvent.WaitFor(250) <> wrTimeout then
  begin
    Writeln('SELFTEST FAILED: provider warm-up wait was unexpectedly signaled');
    Exit;
  end;
  lCollectStartedMs := GetTickCount64;
  lProvider.Collect(lSample);
  if (GetTickCount64 - lCollectStartedMs > 1000) or
    (lSample.State.Status <> TMachineOverviewProviderStatus.Available) or
    (not HasRecentUtcTimestamp(lSample)) then
  begin
    Writeln('SELFTEST FAILED: Windows provider failed or exceeded its bounded collection time');
    Exit;
  end;

  if (not TryFindSystemProviderMeasurement(lSample, 'cpu_total_percent', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value < 0) or
    (lMeasurement.Value > 100) then
  begin
    Writeln('SELFTEST FAILED: English PDH total CPU counter was unavailable or out of range');
    Exit;
  end;
  lExpectedLogicalCount := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  if (lExpectedLogicalCount = 0) or
    (CountSystemProviderMeasurements(lSample, 'cpu_logical:') <>
      Integer(lExpectedLogicalCount)) then
  begin
    Writeln(Format('SELFTEST FAILED: logical processor count expected=%d actual=%d',
      [lExpectedLogicalCount,
       CountSystemProviderMeasurements(lSample, 'cpu_logical:')]));
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample, 'physical_total_bytes', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value <= 0) or
    (not TryFindSystemProviderMeasurement(lSample, 'physical_available_bytes', lMeasurement)) or
    (not lMeasurement.Available) or
    (not TryFindSystemProviderMeasurement(lSample, 'process_count', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value <= 0) or
    (not TryFindSystemProviderMeasurement(lSample, 'thread_count', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value <= 0) or
    (not TryFindSystemProviderMeasurement(lSample, 'handle_count', lMeasurement)) or
    (not lMeasurement.Available) or (lMeasurement.Value <= 0) then
  begin
    Writeln('SELFTEST FAILED: GetPerformanceInfo memory or system counts were unavailable');
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample, 'paging_bytes_per_sec', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample, 'dpc_percent', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample, 'interrupt_percent', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample, 'processor_queue_length', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample, 'foreground_status', lMeasurement)) or
    (not lMeasurement.Available) or
    (not TryFindSystemProviderMeasurement(lSample, 'dwm_frames_late_delta', lMeasurement)) then
  begin
    Writeln('SELFTEST FAILED: provider omitted a required unavailable-capable field');
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample,
      'paging_bytes_per_sec_peak_60s', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample,
      'physical_available_bytes_low_15m', lMeasurement)) or
    (not lMeasurement.Available) or
    (not TryFindSystemProviderMeasurement(lSample,
      'foreground_reply_max_60s', lMeasurement)) or
    (not TryFindSystemProviderMeasurement(lSample,
      'dpc_percent_max_60s', lMeasurement)) then
  begin
    Writeln('SELFTEST FAILED: Windows rolling peak or minimum measurements are missing');
    Exit;
  end;
  if (not TryFindSystemProviderMeasurement(lSample,
      'paging_bytes_per_sec_peak_60s', lMeasurement)) or
    (not ContainsText(lMeasurement.StatusText, 'coverage')) or
    (not TryFindSystemProviderMeasurement(lSample,
      'foreground_reply_max_60s', lMeasurement)) or
    (not ContainsText(lMeasurement.StatusText, 'coverage')) or
    (not TryFindSystemProviderMeasurement(lSample,
      'dpc_percent_max_60s', lMeasurement)) or
    (not ContainsText(lMeasurement.StatusText, 'coverage')) then
  begin
    Writeln('SELFTEST FAILED: Windows rolling coverage status is missing');
    Exit;
  end;

  Result := 0;
end;

function RunSystemCollectorPipelineSelfTest: Integer;
var
  g: TGarbos;
  lCollector: TMachineOverviewSystemCollector;
  lDiagnostics: TMachineOverviewSystemCollectorDiagnostics;
  lMainThreadId: Cardinal;
  lPipeline: TMachineOverviewPipeline;
  lPresentation: TMachineOverviewPresentation;
  lSnapshot: IMachineOverviewSnapshot;
begin
  g := Default(TGarbos);
  Result := 1;
  lMainThreadId := GetCurrentThreadId;
  GC(lPipeline, TMachineOverviewPipeline.Create(8, 8), g);
  GC(lCollector, TMachineOverviewSystemCollector.Create(lPipeline, 100), g);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(2000) then
  begin
    Writeln('SELFTEST FAILED: system collector pipeline did not start');
    Exit;
  end;
  lCollector.Start;
  if not lCollector.WaitUntilRunning(2000) then
  begin
    Writeln('SELFTEST FAILED: system collector worker did not start');
    Exit;
  end;
  if not lPipeline.WaitForSequence(2, 5000) or
    (not lPipeline.TryReadLatest(0, lSnapshot)) or
    (lSnapshot.LastProviderId <> 'windows-core') then
  begin
    Writeln('SELFTEST FAILED: system collector did not publish real provider samples');
    Exit;
  end;
  lDiagnostics := lCollector.Diagnostics;
  lPresentation := lSnapshot.Presentation;
  if (lDiagnostics.ActiveWorkerCount <> 1) or
    (lDiagnostics.WorkerThreadId = 0) or
    (lDiagnostics.WorkerThreadId = lMainThreadId) or
    (lDiagnostics.WorkerThreadId = lSnapshot.AggregatorThreadId) or
    (lDiagnostics.SamplesCollected < 2) or
    (lDiagnostics.SamplesQueued < 2) or
    (lDiagnostics.SamplesDropped <> 0) or
    (lDiagnostics.SamplesStopped <> 0) or
    (lDiagnostics.LastCollectDurationMs > 1000) then
  begin
    Writeln('SELFTEST FAILED: system collector ownership or diagnostics are inconsistent');
    Exit;
  end;
  if not ContainsText(lPresentation.DiagnosticText,
    'collector_duration_ms:windows-core=') then
  begin
    Writeln('SELFTEST FAILED: full diagnostics omitted provider collection latency');
    Exit;
  end;
  if lCollector.Stop(2000) <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: system collector did not stop within its bound');
    Exit;
  end;
  if lPipeline.Stop(2000) <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: system collector pipeline did not stop within its bound');
    Exit;
  end;
  if (lCollector.Diagnostics.ActiveWorkerCount <> 0) or
    (lPipeline.Diagnostics.ActiveWorkerCount <> 0) then
  begin
    Writeln('SELFTEST FAILED: system collector left a worker after shutdown');
    Exit;
  end;
  Result := 0;
end;

function RunEnabledSystemServiceSelfTest: Integer;
var
  g: TGarbos;
  lDeadlineMs: UInt64;
  lDatabaseFileName: string;
  lLatestSequence: UInt64;
  lPresentation: TMachineOverviewPresentation;
  lSawMergedPresentation: Boolean;
  lService: IMachineOverviewService;
  lSettings: TMachineOverviewSettings;
  lWaitEvent: TEvent;
begin
  g := Default(TGarbos);
  Result := 1;
  lService := nil;
  lDatabaseFileName := TPath.Combine(TPath.GetTempPath,
    Format('ActiveAppView.MachineOverview.Service.%d.%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  try
    lSettings := TMachineOverviewSettings.Defaults;
    lSettings.Enabled := True;
    lSettings.HistoryCommitIntervalMs := 100;
    lSettings.HistoryDatabaseFileName := lDatabaseFileName;
    lSettings.ProcessSampleIntervalMs := 100;
    lSettings.SystemSampleIntervalMs := 100;
    lService := CreateMachineOverviewService(lSettings);
    GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
    lService.Start;
  lDeadlineMs := GetTickCount64 + 2000;
  while (lService.ActiveWorkerCount < 7) and (GetTickCount64 < lDeadlineMs) do
    lWaitEvent.WaitFor(10);
  if (not lService.IsRunning) or (lService.ActiveWorkerCount <> 7) then
  begin
    Writeln('SELFTEST FAILED: enabled service did not own collectors, aggregator, and history writer');
    Exit;
  end;
  lDeadlineMs := GetTickCount64 + 3000;
  while (not lService.TryReadLatestPresentation(0, lPresentation)) and
    (GetTickCount64 < lDeadlineMs) do
    lWaitEvent.WaitFor(10);
  if (lPresentation.Sequence = 0) or (Length(lPresentation.Rows) < 23) or
    (not ContainsText(lPresentation.DiagnosticText, 'Providers')) then
  begin
    Writeln('SELFTEST FAILED: enabled service did not expose its immutable presentation');
    Exit;
  end;
  lLatestSequence := lPresentation.Sequence;
  lSawMergedPresentation := False;
  lDeadlineMs := GetTickCount64 + 5000;
  repeat
    if lService.TryReadLatestPresentation(lLatestSequence, lPresentation) then
    begin
      lLatestSequence := lPresentation.Sequence;
      lSawMergedPresentation :=
        ContainsText(lPresentation.DiagnosticText, 'windows-core:') and
        ContainsText(lPresentation.DiagnosticText, 'disks:') and
        ContainsText(lPresentation.DiagnosticText, 'gpu:') and
        ContainsText(lPresentation.DiagnosticText, 'processes:') and
        ContainsText(lPresentation.DiagnosticText, 'temperature:') and
        (not ContainsText(lPresentation.DiagnosticText,
          'SQLite commit: Unavailable')) and
        (not ContainsText(lPresentation.DiagnosticText,
          'monitor CPU=Unavailable'));
    end;
    if not lSawMergedPresentation then
      lWaitEvent.WaitFor(10);
  until lSawMergedPresentation or (GetTickCount64 >= lDeadlineMs);
  if not lSawMergedPresentation then
  begin
    Writeln('SELFTEST FAILED: enabled service did not retain and merge all provider snapshots');
    Exit;
  end;
  if lService.Stop(2000) <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: enabled service did not stop within its shared bound');
    Exit;
  end;
  if lService.IsRunning or (lService.ActiveWorkerCount <> 0) then
  begin
    Writeln('SELFTEST FAILED: enabled service left workers after shutdown');
    Exit;
  end;
  if not TFile.Exists(lDatabaseFileName) then
  begin
    Writeln('SELFTEST FAILED: enabled service created no history database');
    Exit;
  end;
  Result := 0;
  finally
    lService := nil;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function RunMachineOverviewSoakSelfTest: Integer;
const
  cMaximumSteadyMemoryGrowthBytes = 32 * 1024 * 1024;
  cMinimumBudgetDurationSeconds = 300;
var
  g: TGarbos;
  lBaselinePrivateBytes: UInt64;
  lBaselineSet: Boolean;
  lCpuDelta100ns: UInt64;
  lCpuPercent: Double;
  lDatabaseBytes: UInt64;
  lDatabaseFileName: string;
  lElapsedMs: UInt64;
  lExpectedWorkers: Integer;
  lFinalStats: TMachineOverviewSoakStats;
  lHistoryDepth: UInt64;
  lHistoryDropped: UInt64;
  lHistoryEnabled: Boolean;
  lInitialStats: TMachineOverviewSoakStats;
  lLastProgressSeconds: UInt64;
  lLatestSequence: UInt64;
  lMaximumCommitMs: UInt64;
  lMaximumDatabaseBytes: UInt64;
  lMaximumHistoryDepth: UInt64;
  lMaximumPrivateBytes: UInt64;
  lMaximumRawDepth: UInt64;
  lMemoryGrowthBytes: Int64;
  lNowStats: TMachineOverviewSoakStats;
  lPresentation: TMachineOverviewPresentation;
  lPresentationCount: UInt64;
  lProcessorCount: Cardinal;
  lRawDepth: UInt64;
  lRawDropped: UInt64;
  lSawCommit: Boolean;
  lSawSelfMetrics: Boolean;
  lSeconds: UInt64;
  lService: IMachineOverviewService;
  lSettings: TMachineOverviewSettings;
  lShutdownResult: TMachineOverviewShutdownResult;
  lShutdownWatch: TStopwatch;
  lSoakWatch: TStopwatch;
  lWaitEvent: TEvent;
  lWarmupMs: UInt64;
  lWriteDeltaBytes: UInt64;
  lWriteRate: Double;
begin
  g := Default(TGarbos);
  Result := 1;
  lService := nil;
  if not TryReadMachineOverviewSoakSeconds(lSeconds) then
  begin
    Writeln('SELFTEST FAILED: MACHINE_OVERVIEW_SOAK_SECONDS must be from 1 through 86400');
    Exit;
  end;
  lHistoryEnabled := MachineOverviewSoakHistoryEnabled;
  lDatabaseFileName := TPath.Combine(TPath.GetTempPath,
    Format('ActiveAppView.MachineOverview.Soak.%d.%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  try
    lSettings := TMachineOverviewSettings.Defaults;
    lSettings.Enabled := True;
    lSettings.DetailedTraceEnabled := False;
    lSettings.HistoryDatabaseFileName := lDatabaseFileName;
    lSettings.HistoryEnabled := lHistoryEnabled;
    lSettings.HistoryCommitIntervalMs := 10000;
    lService := CreateMachineOverviewService(lSettings);
    GC(lWaitEvent, TEvent.Create(nil, True, False, ''), g);
    if not TryReadMachineOverviewSoakStats(lInitialStats) then
    begin
      Writeln('SELFTEST FAILED: process CPU, private-memory, or write counters are unavailable');
      Exit;
    end;
    lBaselinePrivateBytes := lInitialStats.PrivateBytes;
    lMaximumPrivateBytes := lInitialStats.PrivateBytes;
    lBaselineSet := False;
    lMaximumCommitMs := 0;
    lMaximumDatabaseBytes := 0;
    lMaximumHistoryDepth := 0;
    lMaximumRawDepth := 0;
    lRawDropped := 0;
    lHistoryDropped := 0;
    lLatestSequence := 0;
    lPresentationCount := 0;
    lSawCommit := False;
    lSawSelfMetrics := False;
    lLastProgressSeconds := 0;
    lWarmupMs := (lSeconds * 1000) div 4;
    if lWarmupMs > 60000 then
      lWarmupMs := 60000;
    lExpectedWorkers := 6;
    if lHistoryEnabled then
      Inc(lExpectedWorkers);
    lService.Start;
    lSoakWatch := TStopwatch.StartNew;
    while (lService.ActiveWorkerCount < lExpectedWorkers) and
      (lSoakWatch.ElapsedMilliseconds < 5000) do
      lWaitEvent.WaitFor(10);
    if (not lService.IsRunning) or
      (lService.ActiveWorkerCount <> lExpectedWorkers) then
    begin
      Writeln(Format('SELFTEST FAILED: soak workers expected=%d actual=%d',
        [lExpectedWorkers, lService.ActiveWorkerCount]));
      Exit;
    end;
    repeat
      lWaitEvent.WaitFor(1000);
      lElapsedMs := UInt64(lSoakWatch.ElapsedMilliseconds);
      if lService.TryReadLatestPresentation(lLatestSequence,
          lPresentation) then
      begin
        lLatestSequence := lPresentation.Sequence;
        Inc(lPresentationCount);
        lSawSelfMetrics := lSawSelfMetrics or
          (not ContainsText(lPresentation.DiagnosticText,
            'monitor CPU=Unavailable'));
        if TryExtractMachineOverviewQueueDiagnostics(
            lPresentation.DiagnosticText, 'raw queue depth=', lRawDepth,
            lRawDropped) and (lRawDepth > lMaximumRawDepth) then
          lMaximumRawDepth := lRawDepth;
        if TryExtractMachineOverviewQueueDiagnostics(
            lPresentation.DiagnosticText, 'history queue depth=',
            lHistoryDepth, lHistoryDropped) and
          (lHistoryDepth > lMaximumHistoryDepth) then
          lMaximumHistoryDepth := lHistoryDepth;
        if TryExtractMachineOverviewDiagnosticValue(
            lPresentation.DiagnosticText, 'SQLite commit: ',
            lDatabaseBytes) then
        begin
          lSawCommit := True;
          if lDatabaseBytes > lMaximumCommitMs then
            lMaximumCommitMs := lDatabaseBytes;
        end;
      end;
      if not TryReadMachineOverviewSoakStats(lNowStats) then
      begin
        Writeln('SELFTEST FAILED: process counters became unavailable during soak');
        Exit;
      end;
      if (not lBaselineSet) and (lElapsedMs >= lWarmupMs) then
      begin
        lBaselinePrivateBytes := lNowStats.PrivateBytes;
        lBaselineSet := True;
      end;
      if lNowStats.PrivateBytes > lMaximumPrivateBytes then
        lMaximumPrivateBytes := lNowStats.PrivateBytes;
      lDatabaseBytes := MachineOverviewSoakStorageBytes(lDatabaseFileName);
      if lDatabaseBytes > lMaximumDatabaseBytes then
        lMaximumDatabaseBytes := lDatabaseBytes;
      if ((lElapsedMs div 1000) >= lLastProgressSeconds + 60) then
      begin
        lLastProgressSeconds := lElapsedMs div 1000;
        Writeln(Format(
          'SOAK PROGRESS: seconds=%d; sequence=%d; private_bytes=%d; database_bytes=%d',
          [lLastProgressSeconds, lLatestSequence, lNowStats.PrivateBytes,
           lDatabaseBytes]));
      end;
    until lElapsedMs >= lSeconds * 1000;
    lSoakWatch.Stop;
    if not TryReadMachineOverviewSoakStats(lFinalStats) then
    begin
      Writeln('SELFTEST FAILED: final process counters are unavailable');
      Exit;
    end;
    lElapsedMs := UInt64(lSoakWatch.ElapsedMilliseconds);
    lShutdownWatch := TStopwatch.StartNew;
    lShutdownResult := lService.Stop(5000);
    lShutdownWatch.Stop;
    if lFinalStats.CpuTime100ns >= lInitialStats.CpuTime100ns then
      lCpuDelta100ns := lFinalStats.CpuTime100ns -
        lInitialStats.CpuTime100ns
    else
      lCpuDelta100ns := 0;
    if lFinalStats.WriteBytes >= lInitialStats.WriteBytes then
      lWriteDeltaBytes := lFinalStats.WriteBytes - lInitialStats.WriteBytes
    else
      lWriteDeltaBytes := 0;
    lProcessorCount := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    if (lElapsedMs > 0) and (lProcessorCount > 0) then
    begin
      lCpuPercent := lCpuDelta100ns * 100.0 /
        (lElapsedMs * 10000.0 * lProcessorCount);
      lWriteRate := lWriteDeltaBytes * 1000.0 / lElapsedMs;
    end else
    begin
      lCpuPercent := 0;
      lWriteRate := 0;
    end;
    lMemoryGrowthBytes := Int64(lFinalStats.PrivateBytes) -
      Int64(lBaselinePrivateBytes);
    Writeln(Format(
      'SOAK RESULT: seconds=%d; history=%s; cpu_percent=%.4f; private_start_bytes=%d; private_baseline_bytes=%d; private_max_bytes=%d; private_end_bytes=%d; memory_growth_bytes=%d; write_bytes_per_second=%.2f; database_max_bytes=%d; presentations=%d; final_sequence=%d; raw_queue_max=%d; raw_dropped=%d; history_queue_max=%d; history_dropped=%d; sqlite_commit_max_ms=%d; shutdown_ms=%d; workers_after=%d',
      [lElapsedMs div 1000, BoolToStr(lHistoryEnabled, True), lCpuPercent,
       lInitialStats.PrivateBytes, lBaselinePrivateBytes,
       lMaximumPrivateBytes, lFinalStats.PrivateBytes, lMemoryGrowthBytes,
       lWriteRate, lMaximumDatabaseBytes, lPresentationCount,
       lLatestSequence, lMaximumRawDepth, lRawDropped,
       lMaximumHistoryDepth, lHistoryDropped, lMaximumCommitMs,
       lShutdownWatch.ElapsedMilliseconds, lService.ActiveWorkerCount],
      TFormatSettings.Invariant));
    if (lShutdownResult <> TMachineOverviewShutdownResult.Stopped) or
      (lShutdownWatch.ElapsedMilliseconds > 5000) or lService.IsRunning or
      (lService.ActiveWorkerCount <> 0) then
    begin
      Writeln('SELFTEST FAILED: bounded soak shutdown did not stop every worker');
      Exit;
    end;
    if (lPresentationCount = 0) or (lLatestSequence = 0) or
      (not lSawSelfMetrics) then
    begin
      Writeln('SELFTEST FAILED: soak produced no progressing presentation or self metrics');
      Exit;
    end;
    if (lRawDropped <> 0) or (lHistoryDropped <> 0) or
      (lMaximumRawDepth > 256) or (lMaximumHistoryDepth > 4096) then
    begin
      Writeln('SELFTEST FAILED: soak exceeded a queue bound or dropped samples');
      Exit;
    end;
    if (not lHistoryEnabled) and (lMaximumHistoryDepth <> 0) then
    begin
      Writeln('SELFTEST FAILED: disabled history accumulated an unwritten queue');
      Exit;
    end;
    if lHistoryEnabled and (lSeconds >= 15) and (not lSawCommit) then
    begin
      Writeln('SELFTEST FAILED: history soak observed no batched SQLite commit');
      Exit;
    end;
    if lMaximumDatabaseBytes > UInt64(lSettings.MaxDatabaseSizeMB) *
      1024 * 1024 then
    begin
      Writeln('SELFTEST FAILED: soak history storage exceeded its configured cap');
      Exit;
    end;
    if (lSeconds >= cMinimumBudgetDurationSeconds) and
      (lCpuPercent >= 0.5) then
    begin
      Writeln('SELFTEST FAILED: average monitor CPU exceeded 0.5 percent of the machine');
      Exit;
    end;
    if (lSeconds >= cMinimumBudgetDurationSeconds) and
      (lMemoryGrowthBytes > cMaximumSteadyMemoryGrowthBytes) then
    begin
      Writeln('SELFTEST FAILED: steady private-memory growth exceeded 32 MiB');
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lService) and lService.IsRunning then
      lService.Stop(5000);
    lService := nil;
    DeleteMachineOverviewSoakStorage(lDatabaseFileName);
  end;
end;

function CreatePipelineSelfTestSample(const aProviderId: string;
  const aMonotonicMs: UInt64): IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := aProviderId;
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtMonotonicMs := aMonotonicMs;
  lSample.State.CapturedAtUtc := aMonotonicMs / MSecsPerDay;
  SetLength(lSample.Measurements, 1);
  lSample.Measurements[0].Name := 'value';
  lSample.Measurements[0].Available := True;
  lSample.Measurements[0].Value := aMonotonicMs;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function RunPipelineQueueOverflowSelfTest: Integer;
var
  g: TGarbos;
  lDiagnostics: TMachineOverviewPipelineDiagnostics;
  lPipeline: TMachineOverviewPipeline;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lPipeline, TMachineOverviewPipeline.Create(2, 1), g);
  if (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 1000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 2000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 3000)) <>
      TMachineOverviewEnqueueResult.Full) then
  begin
    Writeln('SELFTEST FAILED: bounded raw queue did not reject only the overflow sample');
    Exit;
  end;
  lDiagnostics := lPipeline.Diagnostics;
  if (lDiagnostics.RawAccepted <> 2) or (lDiagnostics.RawDropped <> 1) or
    (lDiagnostics.RawQueueDepth <> 2) or
    (lPipeline.RawDroppedForProvider('system') <> 1) or
    (lPipeline.RawDroppedForProvider('process') <> 0) then
  begin
    Writeln('SELFTEST FAILED: raw queue overflow was not fully and per-provider accounted');
    Exit;
  end;

  Result := 0;
end;

function RunPipelineInvalidCapacitySelfTest: Integer;
var
  lPipeline: TMachineOverviewPipeline;
  lRejected: Boolean;
begin
  Result := 1;
  lPipeline := nil;
  lRejected := False;
  try
    try
      lPipeline := TMachineOverviewPipeline.Create(0, 1);
    except
      on EArgumentException do
        lRejected := True;
    end;
  finally
    lPipeline.Free;
  end;
  if not lRejected then
  begin
    Writeln('SELFTEST FAILED: invalid queue capacity did not preserve EArgumentException');
    Exit;
  end;

  Result := 0;
end;

function RunPipelineScheduleSelfTest: Integer;
var
  lRejected: Boolean;
  lSchedule: TMachineOverviewMonotonicSchedule;
begin
  Result := 1;
  lSchedule := TMachineOverviewMonotonicSchedule.Create(1000, 1000);
  if lSchedule.IsDue(999) or (not lSchedule.IsDue(1000)) then
  begin
    Writeln('SELFTEST FAILED: monotonic schedule used the wrong due boundary');
    Exit;
  end;
  lSchedule.MarkCompleted(1000);
  if (lSchedule.NextDueMs <> 2000) or lSchedule.IsDue(1999) then
  begin
    Writeln('SELFTEST FAILED: monotonic schedule did not advance one interval');
    Exit;
  end;
  lSchedule.MarkCompleted(3500);
  if lSchedule.NextDueMs <> 4000 then
  begin
    Writeln('SELFTEST FAILED: delayed provider schedule drifted instead of skipping missed intervals');
    Exit;
  end;
  lSchedule.MarkCompleted(3999);
  if lSchedule.NextDueMs <> 4000 then
  begin
    Writeln('SELFTEST FAILED: early completion changed the next provider deadline');
    Exit;
  end;

  lRejected := False;
  try
    lSchedule := TMachineOverviewMonotonicSchedule.Create(0, 0);
  except
    on EArgumentException do
      lRejected := True;
  end;
  if not lRejected then
  begin
    Writeln('SELFTEST FAILED: monotonic schedule accepted a zero interval');
    Exit;
  end;

  Result := 0;
end;

function RunPipelinePublicationSelfTest: Integer;
var
  g: TGarbos;
  lCursor: TMachineOverviewSnapshotCursor;
  lDiagnostics: TMachineOverviewPipelineDiagnostics;
  lHistorySample: IMachineOverviewRawSample;
  lMainThreadId: Cardinal;
  lPipeline: TMachineOverviewPipeline;
  lPresentation: TMachineOverviewPresentation;
  lSnapshot: IMachineOverviewSnapshot;
begin
  g := Default(TGarbos);
  Result := 1;
  lMainThreadId := GetCurrentThreadId;
  GC(lPipeline, TMachineOverviewPipeline.Create(8, 1), g);
  GC(lCursor, TMachineOverviewSnapshotCursor.Create, g);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(5000) then
  begin
    Writeln('SELFTEST FAILED: pipeline aggregator did not report a running worker');
    Exit;
  end;
  if (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 1000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (not lPipeline.WaitForSequence(1, 5000)) or
    (not lPipeline.TryReadLatest(0, lSnapshot)) or
    (lSnapshot.Sequence <> 1) or (lSnapshot.LastProviderId <> 'system') or
    (lSnapshot.RawSamplesConsumed <> 1) or
    (lSnapshot.AggregatorThreadId = 0) or
    (lSnapshot.AggregatorThreadId = lMainThreadId) then
  begin
    Writeln('SELFTEST FAILED: aggregator did not publish the first immutable worker snapshot');
    Exit;
  end;
  lPresentation := lSnapshot.Presentation;
  if (lPresentation.Sequence <> 1) or (Length(lPresentation.Rows) <> 23) or
    (not ContainsText(lPresentation.DiagnosticText, 'system: Available')) then
  begin
    Writeln('SELFTEST FAILED: first pipeline snapshot omitted its presentation/provider state');
    Exit;
  end;
  if (not lPipeline.TryTakeHistory(lHistorySample)) or
    (lHistorySample.ProviderId <> 'system') or
    (not lCursor.TryRead(lPipeline, lSnapshot)) or (lCursor.LastSequence <> 1) then
  begin
    Writeln('SELFTEST FAILED: first history/display consumers did not receive sequence one');
    Exit;
  end;

  lCursor.SetFrozen(True);
  if (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('process', 10000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (not lPipeline.WaitForSequence(2, 5000)) or lCursor.TryRead(lPipeline, lSnapshot) or
    (lCursor.LastSequence <> 1) then
  begin
    Writeln('SELFTEST FAILED: frozen display cursor advanced or stopped pipeline publication');
    Exit;
  end;
  lCursor.SetFrozen(False);
  if (not lCursor.TryRead(lPipeline, lSnapshot)) or (lSnapshot.Sequence <> 2) or
    (lCursor.LastSequence <> 2) then
  begin
    Writeln('SELFTEST FAILED: resumed display cursor did not jump to the latest snapshot');
    Exit;
  end;
  lPresentation := lSnapshot.Presentation;
  if (not ContainsText(lPresentation.DiagnosticText,
      'system: Stale; age=9 s')) or
    (not ContainsText(lPresentation.DiagnosticText, 'process: Available')) then
  begin
    Writeln('SELFTEST FAILED: latest presentation discarded or did not age another provider snapshot');
    Exit;
  end;

  if (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 11000)) <>
      TMachineOverviewEnqueueResult.Queued) or
    (not lPipeline.WaitForSequence(3, 5000)) or
    (not lPipeline.TryReadLatest(2, lSnapshot)) or (lSnapshot.Sequence <> 3) or
    (lSnapshot.HistoryRecordsDropped <> 1) or
    (not lPipeline.TryTakeHistory(lHistorySample)) or
    (lHistorySample.ProviderId <> 'process') then
  begin
    Writeln('SELFTEST FAILED: full history queue blocked or corrupted latest snapshot publication');
    Exit;
  end;

  if (lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
    lPipeline.IsRunning or
    (lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('system', 12000)) <>
      TMachineOverviewEnqueueResult.Stopped) then
  begin
    Writeln('SELFTEST FAILED: pipeline did not cooperatively stop and reject later intake');
    Exit;
  end;
  lDiagnostics := lPipeline.Diagnostics;
  if (lDiagnostics.ActiveWorkerCount <> 0) or (lDiagnostics.RawDequeued <> 3) or
    (lDiagnostics.HistoryAccepted <> 2) or (lDiagnostics.HistoryDequeued <> 2) or
    (lDiagnostics.HistoryDropped <> 1) then
  begin
    Writeln(Format(
      'SELFTEST FAILED: pipeline lifecycle/queue diagnostics active=%d raw=%d history=%d/%d/%d',
      [lDiagnostics.ActiveWorkerCount, lDiagnostics.RawDequeued,
      lDiagnostics.HistoryAccepted, lDiagnostics.HistoryDequeued,
      lDiagnostics.HistoryDropped]));
    Exit;
  end;

  Result := 0;
end;

function RunPipelineConcurrentProducerSelfTest: Integer;
var
  g: TGarbos;
  lDiagnostics: TMachineOverviewPipelineDiagnostics;
  lPipeline: TMachineOverviewPipeline;
  lProducerFailures: Integer;
  lSnapshot: IMachineOverviewSnapshot;
  lStartEvent: TEvent;
  lThreadA: TThread;
  lThreadB: TThread;
begin
  g := Default(TGarbos);
  Result := 1;
  lProducerFailures := 0;
  GC(lPipeline, TMachineOverviewPipeline.Create(64, 1), g);
  GC(lStartEvent, TEvent.Create(nil, True, False, ''), g);
  lPipeline.Start;
  if not lPipeline.WaitUntilRunning(5000) then
  begin
    Writeln('SELFTEST FAILED: concurrent pipeline aggregator did not start');
    Exit;
  end;

  GC(lThreadA, TThread.CreateAnonymousThread(
    procedure
    var
      i: UInt64;
    begin
      if lStartEvent.WaitFor(5000) <> wrSignaled then
      begin
        TInterlocked.Increment(lProducerFailures);
        Exit;
      end;
      for i := 1 to 10 do
        if lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('producer-a', 1000 + i)) <>
          TMachineOverviewEnqueueResult.Queued then
          TInterlocked.Increment(lProducerFailures);
    end), g);
  lThreadA.FreeOnTerminate := False;
  GC(lThreadB, TThread.CreateAnonymousThread(
    procedure
    var
      i: UInt64;
    begin
      if lStartEvent.WaitFor(5000) <> wrSignaled then
      begin
        TInterlocked.Increment(lProducerFailures);
        Exit;
      end;
      for i := 1 to 10 do
        if lPipeline.EnqueueRaw(CreatePipelineSelfTestSample('producer-b', 2000 + i)) <>
          TMachineOverviewEnqueueResult.Queued then
          TInterlocked.Increment(lProducerFailures);
    end), g);
  lThreadB.FreeOnTerminate := False;
  lThreadA.Start;
  lThreadB.Start;
  lStartEvent.SetEvent;
  if (WaitForSingleObject(lThreadA.Handle, 5000) <> WAIT_OBJECT_0) or
    (WaitForSingleObject(lThreadB.Handle, 5000) <> WAIT_OBJECT_0) or
    (lProducerFailures <> 0) or
    (not lPipeline.WaitForSequence(20, 5000)) or
    (not lPipeline.TryReadLatest(0, lSnapshot)) or
    (lSnapshot.Sequence <> 20) or (lSnapshot.RawSamplesConsumed <> 20) then
  begin
    Writeln('SELFTEST FAILED: multi-producer samples were lost or latest publication replayed backlog');
    Exit;
  end;
  lDiagnostics := lPipeline.Diagnostics;
  if (lDiagnostics.RawAccepted <> 20) or (lDiagnostics.RawDequeued <> 20) or
    (lDiagnostics.RawDropped <> 0) or (lDiagnostics.HistoryDropped <> 19) or
    (lDiagnostics.ActiveWorkerCount <> 1) then
  begin
    Writeln('SELFTEST FAILED: concurrent queue or history overflow diagnostics are inconsistent');
    Exit;
  end;
  if lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: concurrent pipeline did not stop within its bound');
    Exit;
  end;

  Result := 0;
end;

function RunDomainRollingWindowSelfTest: Integer;
var
  g: TGarbos;
  lAggregate: TMachineOverviewCpuAggregate;
  lAggregator: TMachineOverviewDomainAggregator;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
  i: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  SetLength(lLogicalProcessors, 0);
  for i := 1 to 5 do
  begin
    lTotalCpu.Available := i <> 2;
    lTotalCpu.Value := i * 10;
    lSample := CreateMachineOverviewCpuSample(i * 1000, 0, lTotalCpu,
      lLogicalProcessors);
    lAggregator.AcceptCpuSample(lSample);
  end;

  lAggregate := lAggregator.BuildCpuAggregate(5000);
  if (not lAggregate.NowValue.Available) or (Abs(lAggregate.NowValue.Value - 50) > 0.0001) or
    (lAggregate.NowCapturedAtMonotonicMs <> 5000) or
    (not lAggregate.Window5Seconds.Available) or
    (Abs(lAggregate.Window5Seconds.Average - 32.5) > 0.0001) or
    (Abs(lAggregate.Window5Seconds.Peak - 50) > 0.0001) or
    (lAggregate.Window5Seconds.ValidSampleCount <> 4) or
    (lAggregate.Window5Seconds.ExpectedSampleCount <> 5) or
    (Abs(lAggregate.Window5Seconds.CoveragePercent - 80) > 0.0001) or
    (not lAggregate.Window5Seconds.CoverageSufficient) then
  begin
    Writeln('SELFTEST FAILED: CPU rolling window treated missing samples as zero or misreported coverage');
    Exit;
  end;

  Result := 0;
end;

function RunDomainGenericRollingSelfTest: Integer;
var
  g: TGarbos;
  lMinimum: Double;
  lOptional: TMachineOverviewOptionalDouble;
  lRejected: Boolean;
  lRolling: TMachineOverviewRollingMeasurements;
  lStatistics: TMachineOverviewWindowStatistics;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lRolling, TMachineOverviewRollingMeasurements.Create(60000), g);
  lOptional.Available := True;
  lOptional.Value := 10;
  lRolling.Observe('metric:one', 1000, lOptional);
  lOptional.Available := False;
  lRolling.Observe('metric:one', 2000, lOptional);
  lOptional.Available := True;
  lOptional.Value := 30;
  lRolling.Observe('metric:one', 3000, lOptional);
  lOptional.Value := 20;
  lRolling.Observe('metric:one', 4000, lOptional);
  lStatistics := lRolling.Statistics('metric:one', 4000, 5000, 1000, 80);
  if (not lStatistics.Available) or
    (Abs(lStatistics.Average - 20) > 0.0001) or
    (Abs(lStatistics.Peak - 30) > 0.0001) or
    (lStatistics.ValidSampleCount <> 3) or
    (lStatistics.ExpectedSampleCount <> 4) or
    (Abs(lStatistics.CoveragePercent - 75) > 0.0001) or
    lStatistics.CoverageSufficient or
    (not lRolling.TryMinimum('metric:one', 4000, 5000, lMinimum)) or
    (Abs(lMinimum - 10) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: generic rolling average, peak, minimum, or coverage is wrong');
    Exit;
  end;
  lOptional.Value := 99;
  lRolling.Observe('metric:one', 5000, lOptional);
  lStatistics := lRolling.Statistics('metric:one', 4000, 5000, 1000, 80);
  if (lStatistics.ValidSampleCount <> 3) or
    (Abs(lStatistics.Peak - 30) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: generic rolling window included a future sample');
    Exit;
  end;
  lRejected := False;
  try
    lRolling.Observe('metric:one', 4500, lOptional);
  except
    on EArgumentException do
      lRejected := True;
  end;
  if not lRejected then
  begin
    Writeln('SELFTEST FAILED: generic rolling series accepted non-monotonic input');
    Exit;
  end;
  lRolling.Prune(65001);
  if (lRolling.RetainedValueCount <> 0) or
    lRolling.Statistics('metric:one', 65001, 60000, 1000, 80).Available then
  begin
    Writeln('SELFTEST FAILED: generic rolling state retained expired values');
    Exit;
  end;
  Result := 0;
end;

function RunDomainFullWindowSelfTest: Integer;
var
  g: TGarbos;
  lAggregate: TMachineOverviewCpuAggregate;
  lAggregator: TMachineOverviewDomainAggregator;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
  i: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  SetLength(lLogicalProcessors, 0);
  lTotalCpu.Available := True;
  for i := 1 to 60 do
  begin
    lTotalCpu.Value := i;
    lSample := CreateMachineOverviewCpuSample(i * 1000, 0, lTotalCpu,
      lLogicalProcessors);
    lAggregator.AcceptCpuSample(lSample);
  end;
  lAggregate := lAggregator.BuildCpuAggregate(60000);
  if (Abs(lAggregate.Window5Seconds.Average - 58) > 0.0001) or
    (Abs(lAggregate.Window15Seconds.Average - 53) > 0.0001) or
    (Abs(lAggregate.Window60Seconds.Average - 30.5) > 0.0001) or
    (Abs(lAggregate.Window5Seconds.Peak - 60) > 0.0001) or
    (Abs(lAggregate.Window15Seconds.Peak - 60) > 0.0001) or
    (Abs(lAggregate.Window60Seconds.Peak - 60) > 0.0001) or
    (lAggregate.Window5Seconds.ValidSampleCount <> 5) or
    (lAggregate.Window15Seconds.ValidSampleCount <> 15) or
    (lAggregate.Window60Seconds.ValidSampleCount <> 60) then
  begin
    Writeln('SELFTEST FAILED: 5, 15, or 60-second CPU window used the wrong boundary');
    Exit;
  end;

  lTotalCpu.Available := False;
  lSample := CreateMachineOverviewCpuSample(61000, 0, lTotalCpu, lLogicalProcessors);
  lAggregator.AcceptCpuSample(lSample);
  lAggregate := lAggregator.BuildCpuAggregate(61000);
  if (not lAggregate.NowValue.Available) or (Abs(lAggregate.NowValue.Value - 60) > 0.0001) or
    (lAggregate.NowCapturedAtMonotonicMs <> 60000) or
    (lAggregate.Window60Seconds.ValidSampleCount <> 59) or
    (lAggregate.Window60Seconds.ExpectedSampleCount <> 60) then
  begin
    Writeln('SELFTEST FAILED: latest missing CPU sample replaced the last valid value');
    Exit;
  end;

  Result := 0;
end;

function RunDomainMonotonicSelfTest: Integer;
var
  g: TGarbos;
  lAggregator: TMachineOverviewDomainAggregator;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lRejected: Boolean;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  SetLength(lLogicalProcessors, 0);
  lTotalCpu.Available := True;
  lTotalCpu.Value := 25;
  lSample := CreateMachineOverviewCpuSample(2000, 0, lTotalCpu, lLogicalProcessors);
  lAggregator.AcceptCpuSample(lSample);
  lSample := CreateMachineOverviewCpuSample(1000, 0, lTotalCpu, lLogicalProcessors);
  lRejected := False;
  try
    lAggregator.AcceptCpuSample(lSample);
  except
    on EArgumentException do
      lRejected := True;
  end;
  if not lRejected then
  begin
    Writeln('SELFTEST FAILED: CPU aggregator accepted a sample older than its latest sample');
    Exit;
  end;

  Result := 0;
end;

function RunDomainRetentionSelfTest: Integer;
var
  g: TGarbos;
  lAggregate: TMachineOverviewCpuAggregate;
  lAggregator: TMachineOverviewDomainAggregator;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
  i: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  SetLength(lLogicalProcessors, 0);
  lTotalCpu.Available := True;
  lTotalCpu.Value := 50;
  for i := 1 to 180 do
  begin
    lSample := CreateMachineOverviewCpuSample(i * 1000, 0, lTotalCpu,
      lLogicalProcessors);
    lAggregator.AcceptCpuSample(lSample);
  end;

  lAggregate := lAggregator.BuildCpuAggregate(180000);
  if (lAggregator.RetainedCpuValueCount > 60) or
    (lAggregate.Window60Seconds.ValidSampleCount > 60) then
  begin
    Writeln('SELFTEST FAILED: CPU rolling state retained values outside the 60-second horizon');
    Exit;
  end;

  Result := 0;
end;

function RunDomainImmutableAndHotCpuSelfTest: Integer;
var
  g: TGarbos;
  lAggregate: TMachineOverviewCpuAggregate;
  lAggregator: TMachineOverviewDomainAggregator;
  lCopy: TArray<TMachineOverviewOptionalDouble>;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
  i: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  SetLength(lLogicalProcessors, 3);
  for i := 0 to High(lLogicalProcessors) do
    lLogicalProcessors[i].Available := True;
  lLogicalProcessors[0].Value := 80;
  lLogicalProcessors[1].Value := 79;
  lLogicalProcessors[2].Value := 100;
  lTotalCpu.Available := True;
  lTotalCpu.Value := 50;

  lSample := CreateMachineOverviewCpuSample(1000, 0, lTotalCpu, lLogicalProcessors);
  lLogicalProcessors[0].Value := 10;
  lCopy := lSample.LogicalProcessors;
  if Abs(lCopy[0].Value - 80) > 0.0001 then
  begin
    Writeln('SELFTEST FAILED: immutable CPU sample retained the caller array');
    Exit;
  end;
  lCopy[0].Value := 20;
  lCopy := lSample.LogicalProcessors;
  if Abs(lCopy[0].Value - 80) > 0.0001 then
  begin
    Writeln('SELFTEST FAILED: immutable CPU sample exposed its owned array');
    Exit;
  end;

  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  for i := 1 to 5 do
  begin
    lLogicalProcessors[0].Available := True;
    lLogicalProcessors[0].Value := 80;
    lLogicalProcessors[1].Available := True;
    lLogicalProcessors[1].Value := 79;
    lLogicalProcessors[2].Available := i <= 3;
    lLogicalProcessors[2].Value := 100;
    lSample := CreateMachineOverviewCpuSample(i * 1000, 0, lTotalCpu,
      lLogicalProcessors);
    lAggregator.AcceptCpuSample(lSample);
  end;
  lAggregate := lAggregator.BuildCpuAggregate(5000);
  if (lAggregate.LogicalProcessorCount <> 3) or
    (lAggregate.HotLogicalProcessorCount <> 1) then
  begin
    Writeln('SELFTEST FAILED: hot logical processor count ignored average or coverage');
    Exit;
  end;

  Result := 0;
end;

function RunDomainInvalidCpuSampleSelfTest: Integer;
var
  g: TGarbos;
  lAggregate: TMachineOverviewCpuAggregate;
  lAggregator: TMachineOverviewDomainAggregator;
  lLogicalProcessors: TArray<TMachineOverviewOptionalDouble>;
  lSample: IMachineOverviewCpuSample;
  lTotalCpu: TMachineOverviewOptionalDouble;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lAggregator, TMachineOverviewDomainAggregator.Create(1000, 80), g);
  SetLength(lLogicalProcessors, 1);
  lLogicalProcessors[0].Available := True;
  lLogicalProcessors[0].Value := -1;
  lTotalCpu.Available := True;
  lTotalCpu.Value := 150;
  lSample := CreateMachineOverviewCpuSample(1000, 0, lTotalCpu, lLogicalProcessors);
  lAggregator.AcceptCpuSample(lSample);
  lAggregate := lAggregator.BuildCpuAggregate(1000);
  if lAggregate.NowValue.Available or lAggregate.Window5Seconds.Available or
    (lAggregate.Window5Seconds.ValidSampleCount <> 0) or
    (lAggregate.Window5Seconds.ExpectedSampleCount <> 1) or
    (lAggregate.HotLogicalProcessorCount <> 0) then
  begin
    Writeln('SELFTEST FAILED: invalid CPU percentages entered rolling state');
    Exit;
  end;

  Result := 0;
end;

function RunDomainFreshnessSelfTest: Integer;
var
  lState: TMachineOverviewProviderState;
begin
  Result := 1;
  lState := Default(TMachineOverviewProviderState);
  lState.Status := TMachineOverviewProviderStatus.Available;
  lState.CapturedAtMonotonicMs := 1000;
  if MachineOverviewProviderStatusAt(lState, 3000, 2000) <>
    TMachineOverviewProviderStatus.Available then
  begin
    Writeln('SELFTEST FAILED: provider became stale at the inclusive freshness boundary');
    Exit;
  end;
  if MachineOverviewProviderStatusAt(lState, 3001, 2000) <>
    TMachineOverviewProviderStatus.Stale then
  begin
    Writeln('SELFTEST FAILED: aged provider data was not marked stale');
    Exit;
  end;
  lState.Status := TMachineOverviewProviderStatus.Unavailable;
  if MachineOverviewProviderStatusAt(lState, 9000, 2000) <>
    TMachineOverviewProviderStatus.Unavailable then
  begin
    Writeln('SELFTEST FAILED: unavailable provider status was overwritten by freshness');
    Exit;
  end;

  Result := 0;
end;

function RunDomainIdentitySelfTest: Integer;
var
  lDiskA: TMachineOverviewDiskIdentity;
  lDiskB: TMachineOverviewDiskIdentity;
  lProcessA: TMachineOverviewProcessIdentity;
  lProcessB: TMachineOverviewProcessIdentity;
begin
  Result := 1;
  lProcessA.ProcessId := 42;
  lProcessA.CreationTime100ns := 100;
  lProcessB := lProcessA;
  lProcessB.CreationTime100ns := 101;
  if MachineOverviewProcessIdentityKey(lProcessA) =
    MachineOverviewProcessIdentityKey(lProcessB) then
  begin
    Writeln('SELFTEST FAILED: process identity used PID without creation time');
    Exit;
  end;

  lDiskA.StableId := '  PHYSICAL:ABC  ';
  lDiskA.DisplayName := 'Disk 0';
  lDiskB.StableId := 'physical:abc';
  lDiskB.DisplayName := 'Renamed disk';
  if MachineOverviewDiskIdentityKey(lDiskA) <>
    MachineOverviewDiskIdentityKey(lDiskB) then
  begin
    Writeln('SELFTEST FAILED: disk identity depended on display name or casing');
    Exit;
  end;

  Result := 0;
end;

function RunDomainNormalizationSelfTest: Integer;
var
  lNormalizedPercent: Double;
begin
  Result := 1;
  if (not TryNormalizeMachineOverviewProcessCpu(3200, 32, lNormalizedPercent)) or
    (Abs(lNormalizedPercent - 100) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: whole-machine CPU normalization failed at 32 busy cores');
    Exit;
  end;
  if (not TryNormalizeMachineOverviewProcessCpu(100, 32, lNormalizedPercent)) or
    (Abs(lNormalizedPercent - 3.125) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: one busy core was not normalized across 32 logical processors');
    Exit;
  end;
  if (not TryNormalizeMachineOverviewProcessCpu(4000, 32, lNormalizedPercent)) or
    (Abs(lNormalizedPercent - 100) > 0.0001) or
    TryNormalizeMachineOverviewProcessCpu(100, 0, lNormalizedPercent) then
  begin
    Writeln('SELFTEST FAILED: CPU normalization did not clamp or reject an invalid processor count');
    Exit;
  end;

  Result := 0;
end;

function RunDomainRankingSelfTest: Integer;
var
  lMetrics: TArray<TMachineOverviewProcessMetric>;
  lRanked: TArray<TMachineOverviewRankedProcess>;
begin
  Result := 1;
  SetLength(lMetrics, 5);
  lMetrics[0].Identity.ProcessId := 20;
  lMetrics[0].MetricAvailable := True;
  lMetrics[0].MetricValue := 50;
  lMetrics[1].Identity.ProcessId := 10;
  lMetrics[1].MetricAvailable := True;
  lMetrics[1].MetricValue := 50;
  lMetrics[2].Identity.ProcessId := 30;
  lMetrics[2].MetricAvailable := True;
  lMetrics[2].MetricValue := 60;
  lMetrics[3].Identity.ProcessId := 1;
  lMetrics[3].MetricAvailable := False;
  lMetrics[3].MetricValue := 1000;
  lMetrics[4].Identity.ProcessId := 2;
  lMetrics[4].MetricAvailable := True;
  lMetrics[4].MetricValue := -1;
  lRanked := RankMachineOverviewProcesses(lMetrics, 4);
  if (Length(lRanked) <> 3) or (lRanked[0].Rank <> 1) or
    (lRanked[0].Metric.Identity.ProcessId <> 30) or
    (lRanked[1].Metric.Identity.ProcessId <> 10) or
    (lRanked[2].Metric.Identity.ProcessId <> 20) then
  begin
    Writeln('SELFTEST FAILED: process ranking was unstable for ties or included missing metrics');
    Exit;
  end;

  SetLength(lMetrics, 5);
  lMetrics[0] := Default(TMachineOverviewProcessMetric);
  lMetrics[0].Identity.ProcessId := 30;
  lMetrics[0].DisplayName := 'firefox.exe';
  lMetrics[0].MetricAvailable := True;
  lMetrics[0].MetricValue := 10;
  lMetrics[1] := Default(TMachineOverviewProcessMetric);
  lMetrics[1].Identity.ProcessId := 10;
  lMetrics[1].DisplayName := 'FIREFOX.EXE';
  lMetrics[1].MetricAvailable := True;
  lMetrics[1].MetricValue := 20;
  lMetrics[2] := Default(TMachineOverviewProcessMetric);
  lMetrics[2].Identity.ProcessId := 20;
  lMetrics[2].DisplayName := 'taskmgr.exe';
  lMetrics[2].MetricAvailable := True;
  lMetrics[2].MetricValue := 25;
  lMetrics[3] := Default(TMachineOverviewProcessMetric);
  lMetrics[3].Identity.ProcessId := 40;
  lMetrics[3].DisplayName := 'firefox.exe';
  lMetrics[3].MetricAvailable := True;
  lMetrics[3].MetricValue := 5;
  lMetrics[4] := Default(TMachineOverviewProcessMetric);
  lMetrics[4].Identity.ProcessId := 50;
  lMetrics[4].DisplayName := 'firefox.exe';
  lMetrics[4].MetricAvailable := False;
  lMetrics[4].MetricValue := 1000;
  lRanked := RankMachineOverviewProcesses(lMetrics, 5);
  if (Length(lRanked) <> 2) or
    (not SameText(lRanked[0].Metric.DisplayName, 'firefox.exe')) or
    (Abs(lRanked[0].Metric.MetricValue - 35) > 0.0001) or
    (lRanked[0].Metric.Identity.ProcessId <> 10) or
    (Length(lRanked[0].Metric.Identities) <> 4) or
    (lRanked[0].Metric.Identities[0].ProcessId <> 10) or
    (lRanked[0].Metric.Identities[1].ProcessId <> 30) or
    (lRanked[0].Metric.Identities[2].ProcessId <> 40) or
    (lRanked[0].Metric.Identities[3].ProcessId <> 50) or
    (not SameText(lRanked[1].Metric.DisplayName, 'taskmgr.exe')) or
    (Abs(lRanked[1].Metric.MetricValue - 25) > 0.0001) then
  begin
    Writeln('SELFTEST FAILED: application ranking did not group names, sum valid metrics, or retain all PIDs');
    Exit;
  end;

  Result := 0;
end;

function RunDomainDiskSelectionSelfTest: Integer;
var
  lMetrics: TArray<TMachineOverviewDiskMetric>;
  lSelection: TMachineOverviewDiskSelection;
begin
  Result := 1;
  SetLength(lMetrics, 3);
  lMetrics[0].Identity.StableId := 'disk-a';
  lMetrics[0].Available := True;
  lMetrics[0].SustainedActivePercent := 99;
  lMetrics[0].ReadMBPerSecond := 500;
  lMetrics[0].SustainedLatencyMs := 4;
  lMetrics[0].SustainedQueueLength := 2;
  lMetrics[1].Identity.StableId := 'disk-b';
  lMetrics[1].Available := True;
  lMetrics[1].SustainedActivePercent := 70;
  lMetrics[1].ReadMBPerSecond := 5;
  lMetrics[1].SustainedLatencyMs := 35;
  lMetrics[1].SustainedQueueLength := 2;
  lMetrics[2].Identity.StableId := 'disk-unavailable';
  lMetrics[2].Available := False;
  lMetrics[2].SustainedLatencyMs := 1000;
  if (not TrySelectWorstMachineOverviewDisk(lMetrics, lSelection)) or
    (lSelection.Metric.Identity.StableId <> 'disk-b') or
    (lSelection.Severity <> TMachineOverviewSeverity.Warning) or
    (lSelection.Reason <> TMachineOverviewDiskReason.Latency) then
  begin
    Writeln('SELFTEST FAILED: worst-disk selection ignored latency or provider availability');
    Exit;
  end;

  SetLength(lMetrics, 1);
  lMetrics[0].Identity.StableId := 'disk-a';
  lMetrics[0].Available := True;
  lMetrics[0].SustainedActivePercent := 99;
  lMetrics[0].ReadMBPerSecond := 500;
  lMetrics[0].SustainedLatencyMs := 4;
  if (not TrySelectWorstMachineOverviewDisk(lMetrics, lSelection)) or
    (lSelection.Severity in [TMachineOverviewSeverity.Warning,
      TMachineOverviewSeverity.Critical]) or
    (lSelection.Reason <> TMachineOverviewDiskReason.ThroughputContext) then
  begin
    Writeln('SELFTEST FAILED: healthy high-throughput disk was reported as unhealthy');
    Exit;
  end;

  lMetrics[0].SustainedActivePercent := 10;
  lMetrics[0].ReadMBPerSecond := 1;
  lMetrics[0].SustainedLatencyMs := 100;
  if (not TrySelectWorstMachineOverviewDisk(lMetrics, lSelection)) or
    (lSelection.Severity <> TMachineOverviewSeverity.Critical) or
    (lSelection.Reason <> TMachineOverviewDiskReason.Latency) then
  begin
    Writeln('SELFTEST FAILED: critical disk latency did not select critical severity');
    Exit;
  end;

  lMetrics[0].SustainedLatencyMs := 15;
  lMetrics[0].SustainedQueueLength := 4;
  if (not TrySelectWorstMachineOverviewDisk(lMetrics, lSelection)) or
    (lSelection.Severity <> TMachineOverviewSeverity.Warning) or
    (lSelection.Reason <> TMachineOverviewDiskReason.QueueLength) then
  begin
    Writeln('SELFTEST FAILED: sustained disk queue did not select warning severity');
    Exit;
  end;

  lMetrics[0].Available := False;
  if TrySelectWorstMachineOverviewDisk(lMetrics, lSelection) then
  begin
    Writeln('SELFTEST FAILED: unavailable disk produced a worst-disk selection');
    Exit;
  end;

  lMetrics[0].Available := True;
  lMetrics[0].SustainedActivePercent := 10;
  lMetrics[0].ReadMBPerSecond := 1;
  lMetrics[0].WriteMBPerSecond := 0;
  lMetrics[0].SustainedLatencyMs := -1;
  lMetrics[0].SustainedQueueLength := 0;
  if TrySelectWorstMachineOverviewDisk(lMetrics, lSelection) then
  begin
    Writeln('SELFTEST FAILED: negative disk counter remained eligible for selection');
    Exit;
  end;

  Result := 0;
end;

function RunMissingSettingsSelfTest: Integer;
var
  g: TGarbos;
  lFileName: string;
  lIniFile: TMemIniFile;
  lSettings: TMachineOverviewSettings;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.MachineOverview.Settings.SelfTest.ini');
  if TFile.Exists(lFileName) then
    TFile.Delete(lFileName);

  GC(lIniFile, TMemIniFile.Create(lFileName, TEncoding.UTF8, False), g);
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if not lSettings.Enabled then
  begin
    Writeln('SELFTEST FAILED: Machine Overview must default to enabled after release acceptance');
    Exit;
  end;

  Result := 0;
end;

function RunConfiguredSettingsSelfTest: Integer;
var
  g: TGarbos;
  lFileName: string;
  lIniFile: TMemIniFile;
  lSettings: TMachineOverviewSettings;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.MachineOverview.Configured.SelfTest.ini');
  if TFile.Exists(lFileName) then
    TFile.Delete(lFileName);

  GC(lIniFile, TMemIniFile.Create(lFileName, TEncoding.UTF8, False), g);
  lIniFile.WriteBool('MachineOverview', 'Enabled', True);
  lIniFile.WriteInteger('MachineOverview', 'DisplayRefreshIntervalMs', 12000);
  lIniFile.WriteInteger('MachineOverview', 'PanelWidth', 460);
  lIniFile.WriteInteger('MachineOverview', 'SystemSampleIntervalMs', 1100);
  lIniFile.WriteInteger('MachineOverview', 'ProcessSampleIntervalMs', 2200);
  lIniFile.WriteInteger('MachineOverview', 'TemperatureSampleIntervalMs', 3300);
  lIniFile.WriteInteger('MachineOverview', 'HistoryCommitIntervalMs', 14000);
  lIniFile.WriteBool('MachineOverview', 'HistoryEnabled', False);
  lIniFile.WriteInteger('MachineOverview', 'RawRetentionHours', 36);
  lIniFile.WriteInteger('MachineOverview', 'Rollup10sRetentionDays', 20);
  lIniFile.WriteInteger('MachineOverview', 'Rollup1mRetentionDays', 180);
  lIniFile.WriteInteger('MachineOverview', 'MaxDatabaseSizeMB', 1024);
  lIniFile.WriteBool('MachineOverview', 'DetailedTraceEnabled', True);

  lSettings := LoadMachineOverviewSettings(lIniFile);
  if (not lSettings.Enabled) or (lSettings.DisplayRefreshIntervalMs <> 12000) or
    (lSettings.PanelWidth <> 460) or (lSettings.SystemSampleIntervalMs <> 1100) or
    (lSettings.ProcessSampleIntervalMs <> 2200) or (lSettings.TemperatureSampleIntervalMs <> 3300) or
    (lSettings.HistoryCommitIntervalMs <> 14000) or lSettings.HistoryEnabled or
    (lSettings.RawRetentionHours <> 36) or (lSettings.Rollup10sRetentionDays <> 20) or
    (lSettings.Rollup1mRetentionDays <> 180) or (lSettings.MaxDatabaseSizeMB <> 1024) or
    (not lSettings.DetailedTraceEnabled) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview did not load the configured settings');
    Exit;
  end;

  Result := 0;
end;

function RunSettingsCommentPreservationSelfTest: Integer;
const
  cOriginalText = '; preserve this comment'#13#10 +
    '[ChatMonitor]'#13#10 +
    '; preserve this setting comment'#13#10 +
    'Enabled=1'#13#10;
var
  lFileName: string;
  lText: string;
begin
  Result := 1;
  lFileName := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView.MachineOverview.CommentPreservation.SelfTest.ini');
  if TFile.Exists(lFileName) then
    TFile.Delete(lFileName);
  TFile.WriteAllText(lFileName, cOriginalText, TEncoding.UTF8);
  try
    SaveMachineOverviewPanelWidthToFile(lFileName, 630, 144);
    lText := TFile.ReadAllText(lFileName, TEncoding.UTF8);
    if (Pos('; preserve this comment', lText) = 0) or
      (Pos('; preserve this setting comment', lText) = 0) then
    begin
      Writeln('SELFTEST FAILED: saving Machine Overview width removed existing INI comments');
      Exit;
    end;
    if (Pos('Enabled=1', lText) = 0) or
      (Pos('PanelWidth=420', lText) = 0) then
    begin
      Writeln('SELFTEST FAILED: saving Machine Overview width changed existing settings or scale');
      Exit;
    end;
    Result := 0;
  finally
    if TFile.Exists(lFileName) then
      TFile.Delete(lFileName);
  end;
end;

function RunClampedSettingsSelfTest: Integer;
var
  g: TGarbos;
  lFileName: string;
  lIniFile: TMemIniFile;
  lSettings: TMachineOverviewSettings;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.MachineOverview.Clamped.SelfTest.ini');
  if TFile.Exists(lFileName) then
    TFile.Delete(lFileName);

  GC(lIniFile, TMemIniFile.Create(lFileName, TEncoding.UTF8, False), g);
  lIniFile.WriteInteger('MachineOverview', 'DisplayRefreshIntervalMs', 500);
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if lSettings.DisplayRefreshIntervalMs <> 2000 then
  begin
    Writeln('SELFTEST FAILED: Machine Overview display refresh was not clamped to 2000 ms');
    Exit;
  end;

  lIniFile.WriteInteger('MachineOverview', 'DisplayRefreshIntervalMs', 61000);
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if lSettings.DisplayRefreshIntervalMs <> 60000 then
  begin
    Writeln('SELFTEST FAILED: Machine Overview display refresh was not clamped to 60000 ms');
    Exit;
  end;

  Result := 0;
end;

function RunMalformedSettingsSelfTest: Integer;
var
  g: TGarbos;
  lDefaults: TMachineOverviewSettings;
  lFileName: string;
  lIniFile: TMemIniFile;
  lSettings: TMachineOverviewSettings;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.MachineOverview.Malformed.SelfTest.ini');
  if TFile.Exists(lFileName) then
    TFile.Delete(lFileName);

  GC(lIniFile, TMemIniFile.Create(lFileName, TEncoding.UTF8, False), g);
  lIniFile.WriteString('MachineOverview', 'Enabled', 'broken');
  lIniFile.WriteString('MachineOverview', 'DisplayRefreshIntervalMs', 'broken');
  lIniFile.WriteString('MachineOverview', 'PanelWidth', 'broken');
  lIniFile.WriteString('MachineOverview', 'SystemSampleIntervalMs', 'broken');
  lIniFile.WriteString('MachineOverview', 'ProcessSampleIntervalMs', 'broken');
  lIniFile.WriteString('MachineOverview', 'TemperatureSampleIntervalMs', 'broken');
  lIniFile.WriteString('MachineOverview', 'HistoryCommitIntervalMs', 'broken');
  lIniFile.WriteString('MachineOverview', 'HistoryEnabled', 'broken');
  lIniFile.WriteString('MachineOverview', 'RawRetentionHours', 'broken');
  lIniFile.WriteString('MachineOverview', 'Rollup10sRetentionDays', 'broken');
  lIniFile.WriteString('MachineOverview', 'Rollup1mRetentionDays', 'broken');
  lIniFile.WriteString('MachineOverview', 'MaxDatabaseSizeMB', 'broken');
  lIniFile.WriteString('MachineOverview', 'DetailedTraceEnabled', 'broken');

  lDefaults := TMachineOverviewSettings.Defaults;
  lSettings := LoadMachineOverviewSettings(lIniFile);
  if (lSettings.Enabled <> lDefaults.Enabled) or
    (lSettings.DisplayRefreshIntervalMs <> lDefaults.DisplayRefreshIntervalMs) or
    (lSettings.PanelWidth <> lDefaults.PanelWidth) or
    (lSettings.SystemSampleIntervalMs <> lDefaults.SystemSampleIntervalMs) or
    (lSettings.ProcessSampleIntervalMs <> lDefaults.ProcessSampleIntervalMs) or
    (lSettings.TemperatureSampleIntervalMs <> lDefaults.TemperatureSampleIntervalMs) or
    (lSettings.HistoryCommitIntervalMs <> lDefaults.HistoryCommitIntervalMs) or
    (lSettings.HistoryEnabled <> lDefaults.HistoryEnabled) or
    (lSettings.RawRetentionHours <> lDefaults.RawRetentionHours) or
    (lSettings.Rollup10sRetentionDays <> lDefaults.Rollup10sRetentionDays) or
    (lSettings.Rollup1mRetentionDays <> lDefaults.Rollup1mRetentionDays) or
    (lSettings.MaxDatabaseSizeMB <> lDefaults.MaxDatabaseSizeMB) or
    (lSettings.DetailedTraceEnabled <> lDefaults.DetailedTraceEnabled) then
  begin
    Writeln('SELFTEST FAILED: Machine Overview malformed settings did not preserve defaults');
    Exit;
  end;

  Result := 0;
end;

function RunDisabledServiceSelfTest: Integer;
var
  lService: IMachineOverviewService;
  lSettings: TMachineOverviewSettings;
  lShutdownResult: TMachineOverviewShutdownResult;
begin
  Result := 1;
  lSettings := TMachineOverviewSettings.Defaults;
  lSettings.Enabled := False;
  lService := CreateMachineOverviewService(lSettings);
  lService.Start;
  if lService.IsRunning or (lService.ActiveWorkerCount <> 0) then
  begin
    Writeln('SELFTEST FAILED: disabled Machine Overview started workers');
    Exit;
  end;

  lShutdownResult := lService.Stop(50);
  if lShutdownResult <> TMachineOverviewShutdownResult.Stopped then
  begin
    Writeln('SELFTEST FAILED: disabled Machine Overview did not stop within its bounded shutdown');
    Exit;
  end;

  Result := 0;
end;

function RunCommandRoutingSelfTest: Integer;
begin
  Result := 1;
  if ResolveMachineOverviewCommand(VK_F8, []) <> TMachineOverviewCommand.FocusPanel then
  begin
    Writeln('SELFTEST FAILED: F8 did not resolve to Machine Overview focus');
    Exit;
  end;

  if ResolveMachineOverviewCommand(VK_F8, [ssShift]) <>
    TMachineOverviewCommand.ToggleFullView then
  begin
    Writeln('SELFTEST FAILED: Shift+F8 did not resolve to Machine Overview Full View');
    Exit;
  end;

  if ResolveMachineOverviewCommand(Ord('E'), [ssCtrl]) <>
    TMachineOverviewCommand.ToggleDisplayFrozen then
  begin
    Writeln('SELFTEST FAILED: Ctrl+E did not resolve to Machine Overview display freeze');
    Exit;
  end;

  if ResolveMachineOverviewCommand(Ord('C'), [ssCtrl]) <>
      TMachineOverviewCommand.CopySelectedRow then
  begin
    Writeln('SELFTEST FAILED: Ctrl+C did not resolve to selected-row copy');
    Exit;
  end;

  if ResolveMachineOverviewCommand(Ord('C'), [ssCtrl, ssShift]) <>
      TMachineOverviewCommand.CopyFullDiagnostics then
  begin
    Writeln('SELFTEST FAILED: Ctrl+Shift+C did not resolve to full diagnostic copy');
    Exit;
  end;

  if ResolveMachineOverviewCommand(VK_F5, []) <> TMachineOverviewCommand.None then
  begin
    Writeln('SELFTEST FAILED: Machine Overview commandeered the existing F5 command');
    Exit;
  end;

  Result := 0;
end;

function RunMachineOverviewSelfTests(const aArg: string): Integer;
var
  lTestResult: Integer;
begin
  Result := -1;
  Result := RunMachineOverviewIncidentSelfTests(aArg);
  if Result >= 0 then
    Exit;
  Result := RunMachineOverviewHistorySelfTests(aArg);
  if Result <> -1 then
    Exit;
  Result := RunMachineOverviewIncidentHistorySelfTests(aArg);
  if Result <> -1 then
    Exit;
  Result := RunMachineOverviewOptionalProviderSelfTests(aArg);
  if Result <> -1 then
    Exit;
  Result := RunMachineOverviewTraceSelfTests(aArg);
  if Result <> -1 then
    Exit;
  if SameText(aArg, cMachineOverviewSoakSelfTestArg) then
  begin
    try
      Result := RunMachineOverviewSoakSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewHelpSelfTestArg) then
  begin
    try
      Result := RunMachineOverviewHelpSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewLayoutSelfTestArg) then
  begin
    try
      Result := RunMachineOverviewLayoutSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewViewSelfTestArg) then
  begin
    try
      Result := RunMachineOverviewViewSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewPresentationSelfTestArg) then
  begin
    try
      Result := RunMachineOverviewPresentationSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewProcessDiskSelfTestArg) then
  begin
    try
      Result := RunProcessProviderFixtureSelfTest;
      lTestResult := RunProcessProviderLiveSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunDiskProviderFixtureSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunDiskProviderLiveSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunProcessDiskCollectorPipelineSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunCollectorFailureAttributionSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunEnabledSystemServiceSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName,
          lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewSystemProvidersSelfTestArg) then
  begin
    try
      Result := RunSystemProviderFixtureSelfTest;
      lTestResult := RunSystemProviderLiveSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunSystemCollectorPipelineSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunEnabledSystemServiceSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewPipelineSelfTestArg) then
  begin
    try
      Result := RunPipelineQueueOverflowSelfTest;
      lTestResult := RunPipelineInvalidCapacitySelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunPipelineScheduleSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunPipelinePublicationSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
      lTestResult := RunPipelineConcurrentProducerSelfTest;
      if lTestResult <> 0 then
        Result := lTestResult;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, cMachineOverviewDomainSelfTestArg) then
  begin
    try
      Result := RunDomainRollingWindowSelfTest;
      if Result = 0 then
      Result := RunDomainGenericRollingSelfTest;
      if Result = 0 then
      Result := RunDomainFullWindowSelfTest;
      if Result = 0 then
        Result := RunDomainMonotonicSelfTest;
      if Result = 0 then
        Result := RunDomainRetentionSelfTest;
      if Result = 0 then
        Result := RunDomainImmutableAndHotCpuSelfTest;
      if Result = 0 then
        Result := RunDomainInvalidCpuSampleSelfTest;
      if Result = 0 then
        Result := RunDomainFreshnessSelfTest;
      if Result = 0 then
        Result := RunDomainIdentitySelfTest;
      if Result = 0 then
        Result := RunDomainNormalizationSelfTest;
      if Result = 0 then
        Result := RunDomainRankingSelfTest;
      if Result = 0 then
        Result := RunDomainDiskSelectionSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;

  if SameText(aArg, cMachineOverviewSQLiteVersionSelfTestArg) then
  begin
    try
      Result := RunSQLiteVersionSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    Exit;
  end;

  if not SameText(aArg, cMachineOverviewSettingsSelfTestArg) then
    Exit;

  try
    Result := RunMissingSettingsSelfTest;
    if Result = 0 then
      Result := RunConfiguredSettingsSelfTest;
    if Result = 0 then
      Result := RunSettingsCommentPreservationSelfTest;
    if Result = 0 then
      Result := RunClampedSettingsSelfTest;
    if Result = 0 then
      Result := RunMalformedSettingsSelfTest;
    if Result = 0 then
      Result := RunDisabledServiceSelfTest;
    if Result = 0 then
      Result := RunCommandRoutingSelfTest;
  except
    on lException: Exception do
    begin
      Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
      Result := 1;
    end;
  end;
end;

end.

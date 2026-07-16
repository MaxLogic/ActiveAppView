unit ActiveAppView.CaptionOverrideState.SelfTests;

interface

function RunCaptionOverrideStateSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.IniFiles, System.IOUtils, System.SysUtils,
  Winapi.Windows,
  CancelToken, MaxLogic.Windows.Identity,
  ActiveAppView.CaptionOverrideState, ActiveAppView.RenameJournal;

const
  cCaptionOverrideStateSelfTestArg = '--self-test-window-caption-overrides';
  cSelfTestBootId = Int64(1777777000000);
  cSelfTestProcessStartedAt = Int64(1777777111222);

function FailSelfTest(const aMessage: string): Integer;
begin
  Writeln('SELFTEST FAILED: ' + aMessage);
  Result := 1;
end;

function BuildSampleState: TCaptionOverrideState;
begin
  SetLength(Result, 1);
  Result[0].Caption := 'Zażółć 💻';
  Result[0].CreatedAt := 1777777777001;
  Result[0].UpdatedAt := 1777777777999;
  Result[0].Reason := 'user_rename';
  Result[0].Identity.HasBootId := True;
  Result[0].Identity.BootId := cSelfTestBootId;
  Result[0].Identity.HasProcessStartedAt := True;
  Result[0].Identity.ProcessStartedAt := cSelfTestProcessStartedAt;
  Result[0].Identity.ProcessId := 4294967000;
  Result[0].Identity.Hwnd := UInt64($1234567887654321);
end;

function RunRoundTripSelfTest(const aRoot: string; const aFileName: string): Integer;
var
  lErrorMessage: string;
  lIniFile: TMemIniFile;
  lLoaded: TCaptionOverrideState;
  lState: TCaptionOverrideState;
  lStatus: TCaptionOverrideStateLoadStatus;
begin
  lState := BuildSampleState;
  if not TrySaveCaptionOverrideStateAtomic(aFileName, lState, lErrorMessage) then
    Exit(FailSelfTest('state-v2 atomic save unavailable: ' + lErrorMessage));
  if not TryLoadCaptionOverrideState(aFileName, cSelfTestBootId, True, nil,
    lLoaded, lStatus, lErrorMessage) then
    Exit(FailSelfTest('state-v2 reload failed: ' + lErrorMessage));
  if (lStatus <> coslsLoaded) or (Length(lLoaded) <> 1) or
    (lLoaded[0].Caption <> lState[0].Caption) or
    (lLoaded[0].Identity.Hwnd <> lState[0].Identity.Hwnd) or
    (lLoaded[0].Identity.ProcessId <> lState[0].Identity.ProcessId) or
    (lLoaded[0].Identity.ProcessStartedAt <> lState[0].Identity.ProcessStartedAt) then
    Exit(FailSelfTest('state-v2 Unicode/64-bit round-trip mismatch'));
  lIniFile := TMemIniFile.Create(aFileName, TEncoding.UTF8, False);
  try
    if (lIniFile.ReadInteger('Metadata', 'StateVersion', 0) <> 2) or
      (lIniFile.ReadInteger('Metadata', 'Count', -1) <> 1) then
      Exit(FailSelfTest('state-v2 metadata was not persisted'));
  finally
    lIniFile.Free;
  end;
  if Length(TDirectory.GetFiles(aRoot, '*.tmp.*')) <> 0 then
    Exit(FailSelfTest('atomic state replacement left a temporary file'));
  Result := 0;
end;

function RunLegacyUpgradeSelfTest(const aFileName: string): Integer;
var
  lErrorMessage: string;
  lIniFile: TMemIniFile;
  lLegacyBootId: Int64;
  lLoaded: TCaptionOverrideState;
  lStatus: TCaptionOverrideStateLoadStatus;
begin
  lIniFile := TMemIniFile.Create(aFileName, TEncoding.UTF8, False);
  try
    lIniFile.Clear;
    lLegacyBootId := (cSelfTestBootId div 1000) + 11644473600;
    lIniFile.WriteString('Metadata', 'BootId', IntToStr(lLegacyBootId));
    lIniFile.WriteString('Overrides', '200:100', 'Legacy żółć');
    lIniFile.UpdateFile;
  finally
    lIniFile.Free;
  end;
  if not TryLoadCaptionOverrideState(aFileName, cSelfTestBootId, True,
    function(const aWnd: HWND; const aProcessId: Cardinal): TCaptionOverrideResolvedProcess
    begin
      Result := Default(TCaptionOverrideResolvedProcess);
      Result.Current := (aWnd = HWND(100)) and (aProcessId = 200);
      Result.HasProcessStartedAt := True;
      Result.ProcessStartedAt := cSelfTestProcessStartedAt;
    end,
    lLoaded, lStatus, lErrorMessage) or (lStatus <> coslsUpgraded) or
    (Length(lLoaded) <> 1) or (lLoaded[0].Caption <> 'Legacy żółć') then
    Exit(FailSelfTest('version-1-to-version-2 upgrade failed: ' + lErrorMessage));
  Result := 0;
end;

function SubmitSnapshotsAndCheck(const aWriter: TRenameJournalWriter;
  var aState: TCaptionOverrideState): Integer;
var
  i: Integer;
  lDiagnostics: TRenameJournalDiagnostics;
begin
  for i := 1 to 100 do
  begin
    aState[0].Caption := 'Latest ' + IntToStr(i);
    Inc(aState[0].UpdatedAt);
    if not aWriter.SubmitOverrideState(aState) then
      Exit(FailSelfTest('background state snapshot was rejected'));
  end;
  if not aWriter.WaitForOverrideStatePersistence(5000) then
    Exit(FailSelfTest('background state persistence timed out'));
  lDiagnostics := aWriter.GetDiagnostics;
  if (lDiagnostics.ActiveWorkerCount <> 1) or
    (lDiagnostics.StateSnapshotsSubmitted <> 100) or
    (lDiagnostics.StateSnapshotsCoalesced = 0) or
    (lDiagnostics.StateSnapshotsPersisted = 0) or
    (lDiagnostics.LastStateSubmitThreadId = lDiagnostics.LastStatePersistThreadId) then
    Exit(FailSelfTest('state persistence was not coalesced on one background worker'));
  Result := 0;
end;

function CheckPersistedEnrichedState(const aFileName: string;
  const aExpectedCaption: string): Integer;
var
  lBootIdentity: TWindowsBootIdentity;
  lErrorMessage: string;
  lLoaded: TCaptionOverrideState;
  lStatus: TCaptionOverrideStateLoadStatus;
begin
  if not TryGetWindowsBootIdentity(1000, False, lBootIdentity) then
    Exit(FailSelfTest('canonical boot identity was not prewarmed by the worker'));
  if not TryLoadCaptionOverrideState(aFileName, lBootIdentity.UtcMilliseconds, True, nil,
    lLoaded, lStatus, lErrorMessage) or (Length(lLoaded) <> 1) or
    (lLoaded[0].Caption <> aExpectedCaption) or (not lLoaded[0].Identity.HasBootId) or
    (not lLoaded[0].Identity.HasProcessStartedAt) then
    Exit(FailSelfTest('coalesced latest enriched state was not persisted: ' + lErrorMessage));
  Result := 0;
end;

function RunBackgroundWorkerSelfTest(const aFileName: string): Integer;
var
  lCancelToken: iCancelToken;
  lConfig: TRenameJournalConfig;
  lState: TCaptionOverrideState;
  lTestWnd: HWND;
  lWriter: TRenameJournalWriter;
begin
  lTestWnd := CreateWindowEx(0, 'STATIC', 'CaptionOverrideStateSelfTest', 0,
    0, 0, 0, 0, 0, 0, HInstance, nil);
  if lTestWnd = 0 then
    Exit(FailSelfTest('could not create identity test window'));
  try
    lState := BuildSampleState;
    lState[0].Identity := Default(TCaptionOverrideIdentity);
    lState[0].Identity.Hwnd := UInt64(NativeUInt(lTestWnd));
    lState[0].Identity.ProcessId := GetCurrentProcessId;
    lConfig := Default(TRenameJournalConfig);
    lConfig.OverrideStateFileName := aFileName;
    lCancelToken := TCancelToken.Create;
    lWriter := TRenameJournalWriter.Create(lConfig, lCancelToken);
    try
      Result := SubmitSnapshotsAndCheck(lWriter, lState);
      if Result = 0 then
      begin
        DestroyWindow(lTestWnd);
        lTestWnd := 0;
        lState[0].Caption := 'Retained after exit';
        if (not lWriter.SubmitOverrideState(lState)) or
          (not lWriter.WaitForOverrideStatePersistence(5000)) then
          Result := FailSelfTest('post-exit state snapshot was not persisted');
      end;
    finally
      lWriter.Free;
      lCancelToken := nil;
    end;
    if Result = 0 then
      Result := CheckPersistedEnrichedState(aFileName, 'Retained after exit');
  finally
    if lTestWnd <> 0 then
      DestroyWindow(lTestWnd);
  end;
end;

function RunCaptionOverrideStateSelfTests(const aArg: string): Integer;
var
  lFileName: string;
  lRoot: string;
begin
  Result := -1;
  if not SameText(aArg, cCaptionOverrideStateSelfTestArg) then
    Exit;
  lRoot := TPath.Combine(TPath.GetTempPath, 'ActiveAppView-CaptionOverrideState-' +
    UIntToStr(TThread.GetTickCount64));
  TDirectory.CreateDirectory(lRoot);
  lFileName := TPath.Combine(lRoot, 'WindowCaptionOverrides.ini');
  try
    Result := RunRoundTripSelfTest(lRoot, lFileName);
    if Result = 0 then
      Result := RunLegacyUpgradeSelfTest(lFileName);
    if Result = 0 then
      Result := RunBackgroundWorkerSelfTest(lFileName);
  finally
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
end;

end.

unit ActiveAppView.MachineOverview.Recording.SelfTests;

interface

uses
  System.SysUtils, ActiveAppView.MachineOverview.Incidents;

function RunMachineOverviewRecordingSelfTests(const aArg: string): Integer;
function CreateMachineOverviewRecordingFixture(const aDirectory, aCase: string;
  out aIncident: TMachineOverviewIncident): string;

implementation

uses
  System.Classes, System.DateUtils, System.Diagnostics, System.IOUtils, System.Math, System.StrUtils,
  Winapi.Windows,
  AutoFree, maxLogic.IOUtils,
  ActiveAppView.MachineOverview.BoundedProcess, ActiveAppView.MachineOverview.Evidence,
  ActiveAppView.MachineOverview.Recording;

function PdhLookupPerfNameByIndexW(aMachine: PWideChar; aIndex: Cardinal;
  aBuffer: PWideChar; var aLength: Cardinal): Cardinal; stdcall; external 'pdh.dll';

function FixtureCounterName(const aIndex: Cardinal): string;
var
  lLength, lStatus: Cardinal;
begin
  lLength := 0;
  lStatus := PdhLookupPerfNameByIndexW(nil, aIndex, nil, lLength);
  if lStatus <> $800007D2 then
    raise Exception.CreateFmt('Fixture counter size %d: PDH %x', [aIndex, lStatus]);
  SetLength(Result, lLength);
  lStatus := PdhLookupPerfNameByIndexW(nil, aIndex, PWideChar(Result), lLength);
  if lStatus <> 0 then
    raise Exception.CreateFmt('Fixture counter %d: PDH %x', [aIndex, lStatus]);
  Result := PWideChar(Result);
end;

function CsvLine(const aValues: TArray<string>): string;
begin
  Result := '"' + string.Join('","', aValues) + '"';
end;

function CreateMachineOverviewRecordingFixture(const aDirectory, aCase: string;
  out aIncident: TMachineOverviewIncident): string;
var
  g: TGarbos;
  lLines: TStringList;
  lCsv, lCpu, lProcess, lPid, lElapsed, lMachine, lBase, lOther: string;
  lNames, lValues: TArray<string>;
  lResult: TMachineOverviewProcessResult;
  lStart: TDateTime;
  i, lLastSample: Int64;
  j: Integer;
begin
  g := Default(TGarbos);
  ForceDirectories(aDirectory);
  lCsv := TPath.Combine(aDirectory, aCase + '.csv');
  Result := TPath.Combine(aDirectory, aCase + '.blg');
  lCpu := FixtureCounterName(6);
  lProcess := FixtureCounterName(230);
  lPid := FixtureCounterName(784);
  lElapsed := FixtureCounterName(684);
  lMachine := '\\FIXTURE';
  lBase := lMachine + '\' + lProcess;
  lOther := lMachine;
  if aCase = 'machines' then
    lOther := '\\OTHER';
  lNames := ['(PDH-CSV 4.0) (UTC)(0)',
    lMachine + '\' + FixtureCounterName(238) + '(_Total)\' + lCpu,
    lBase + '(worker)\' + lCpu, lBase + '(worker)\' + lPid, lBase + '(worker)\' + lElapsed,
    lOther + '\' + lProcess + '(worker#1)\' + lCpu,
    lOther + '\' + lProcess + '(worker#1)\' + lPid,
    lOther + '\' + lProcess + '(worker#1)\' + lElapsed,
    lBase + '(Idle)\' + lCpu, lBase + '(Idle)\' + lPid, lBase + '(Idle)\' + lElapsed,
    lBase + '(_Total)\' + lCpu, lBase + '(_Total)\' + lPid, lBase + '(_Total)\' + lElapsed];
  GC(lLines, TStringList.Create, g);
  lLines.Add(CsvLine(lNames));
  lStart := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
  aIncident := Default(TMachineOverviewIncident);
  aIncident.StableId := 'recording-fixture';
  aIncident.StartedAtUtc := TTimeZone.Local.ToUniversalTime(IncSecond(lStart, 2));
  aIncident.EndedAtUtc := TTimeZone.Local.ToUniversalTime(IncSecond(lStart, 6));
  aIncident.PeakAtUtc := aIncident.StartedAtUtc;
  aIncident.Evidence.LogicalProcessorCount := 32;
  lLastSample := 8;
  if aCase = 'window' then
  begin
    lLastSample := 910;
    aIncident.StartedAtUtc := IncSecond(aIncident.StartedAtUtc, 300);
    aIncident.EndedAtUtc := IncSecond(aIncident.EndedAtUtc, 300);
  end;
  for i := 0 to lLastSample do
  begin
    lValues := [FormatDateTime('mm/dd/yyyy hh:nn:ss.zzz', IncSecond(lStart, i)),
      '50', '320', '42', IntToStr(100 + i), '32', '84', IntToStr(200 + i),
      '2800', '0', IntToStr(10000 + i), '3200', '999', IntToStr(10000 + i)];
    if (aCase = 'renumber') and (i >= 4) then
    begin
      lValues[2] := '32'; lValues[3] := '84'; lValues[4] := IntToStr(200 + i);
      lValues[5] := '320'; lValues[6] := '42'; lValues[7] := IntToStr(100 + i);
    end;
    if (aCase = 'reuse') and (i >= 4) then
      lValues[4] := IntToStr(i - 3);
    if (aCase = 'exit') and (i > 3) then
      for j := 2 to 4 do
        lValues[j] := ' ';
    if (aCase = 'invalid') and (i = 0) then
      // relog discards a CSV row with no system timestamp/value. Keep that
      // timestamp carrier valid and blank the process observations instead.
      for j := 2 to High(lValues) do
        lValues[j] := ' ';
    if (aCase = 'window') and ((i < 2) or (i > 906)) then
      lValues[2] := '3200';
    lLines.Add(CsvLine(lValues));
  end;
  lLines.SaveToFile(lCsv, TEncoding.Default);
  lResult := RunMachineOverviewBoundedProcess(
    CombinePath([GetEnvironmentVariable('WINDIR'), 'System32', 'relog.exe']),
    '"' + lCsv + '" -f bin -o "' + Result + '" -y', 30000, 32768);
  if not lResult.Started or lResult.TimedOut or (lResult.ExitCode <> 0) or not TFile.Exists(Result) then
    raise Exception.Create('Fixture relog failed: ' + lResult.ErrorText + ' ' + lResult.OutputText);
end;

procedure RecordingCheck(const aCondition: Boolean; const aText: string);
begin
  if not aCondition then
    raise Exception.Create(aText);
end;

procedure CheckRecordingCase(const aDirectory, aCase: string);
var
  lIncident: TMachineOverviewIncident;
  lRecording: TMachineOverviewRecording;
  lFile, lError, lText: string;
  lPhase: TMachineOverviewEvidencePhaseKind;
  lProcess: TMachineOverviewRecordedProcess;
  lFound, lReuse, lCalls: Integer;
  lHandle: THandle;
  lTimer: TStopwatch;
  lSucceeded: Boolean;
begin
  lFile := CreateMachineOverviewRecordingFixture(aDirectory, aCase, lIncident);
  if aCase = 'refusal' then
  begin
    lFile := TPath.Combine(aDirectory, 'current.blg');
    TFile.Copy(TPath.Combine(aDirectory, aCase + '.blg'), lFile, True);
    lSucceeded := TryReadMachineOverviewRecording([lFile], lIncident, 32, nil, lRecording, lError);
    RecordingCheck(not lSucceeded and ContainsText(lError, 'active circular log'), 'current.blg must be refused');
    lHandle := CreateFile(PChar(lFile), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
    RecordingCheck(lHandle <> INVALID_HANDLE_VALUE, 'Refusal left an open handle');
    CloseHandle(lHandle);
    Exit;
  end;
  if aCase = 'open' then
  begin
    lHandle := CreateFile(PChar(lFile), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    RecordingCheck(lHandle <> INVALID_HANDLE_VALUE, 'Open-file fixture handle failed');
    try
      lSucceeded := TryReadMachineOverviewRecording([lFile], lIncident, 32, nil, lRecording, lError);
      RecordingCheck(not lSucceeded and ContainsText(lError, 'closed'), 'Writable open BLG must be refused');
    finally
      CloseHandle(lHandle);
    end;
    Exit;
  end;
  if aCase = 'cancel' then
  begin
    lCalls := 0;
    lTimer := TStopwatch.StartNew;
    lSucceeded := TryReadMachineOverviewRecording([lFile], lIncident, 32,
      function: Boolean
      begin
        Inc(lCalls);
        Result := lCalls >= 9;
      end, lRecording, lError);
    RecordingCheck(not lSucceeded and ContainsText(lError, 'cancel') and (lTimer.ElapsedMilliseconds < 2000),
      'Cancellation must abort the production read promptly');
    Exit;
  end;
  lSucceeded := TryReadMachineOverviewRecording([lFile], lIncident, 32, nil, lRecording, lError);
  if aCase = 'machines' then
  begin
    RecordingCheck(not lSucceeded and ContainsText(lError, 'one machine'), 'Mixed-machine recording must fail');
    Exit;
  end;
  RecordingCheck(lSucceeded, 'Read fixture: ' + lError);
  RecordingCheck(lRecording.LogicalProcessorCount = 32, 'LP normalization metadata');
  lText := MachineOverviewRecordingText(lRecording);
  RecordingCheck(ContainsText(lText, 'Windows performance recording') and ContainsText(lText, '+02:00 (2026-') and
    ContainsText(lText, '% of machine') and (Length(MachineOverviewRecordingRows(lRecording)) > 0), 'Accessible text and rows');
  if aCase = 'polish' then
  begin
    RecordingCheck(ContainsText(lText, FixtureCounterName(6)) and ContainsText(lText, FixtureCounterName(230)),
      'Read must expose the names actually resolved by index');
    if (GetUserDefaultUILanguage and $3FF) = LANG_POLISH then
      RecordingCheck(FixtureCounterName(6) = 'Czas procesora (%)', 'Polish counter resolution');
  end;
  lFound := 0;
  lReuse := 0;
  for lProcess in lRecording.Phases[TMachineOverviewEvidencePhaseKind.During].Processes do
  begin
    RecordingCheck((lProcess.ProcessId <> 0) and (lProcess.ProcessId <> 999), 'Idle/_Total excluded');
    if lProcess.ProcessId = 42 then
    begin
      Inc(lFound);
      if aCase = 'renumber' then
        RecordingCheck(SameValue(lProcess.AverageCpuPercent, 10, 0.02), 'Renumbering followed instance instead of PID');
      if aCase = 'normalization' then
        RecordingCheck(SameValue(lProcess.PeakCpuPercent, 10, 0.02), '320 / 32 must equal 10% of machine');
      if aCase = 'exit' then
        RecordingCheck((lProcess.SampleCount < lRecording.Phases[TMachineOverviewEvidencePhaseKind.During].SampleCount) and
          (lProcess.LastSeenUtc < lIncident.EndedAtUtc) and
          SameValue(lProcess.AverageCpuPercent, 2.5, 0.02), 'Exited process must retain last seen and absent-zero average');
      Inc(lReuse);
    end;
  end;
  RecordingCheck(lFound > 0, 'PID 42 must remain in the incident phase');
  if aCase = 'reuse' then
    RecordingCheck(lReuse = 2, 'Reset elapsed time must create a second PID identity')
  else
    RecordingCheck(lFound = 1, 'A stable PID/elapsed identity must join');
  if aCase = 'invalid' then
  begin
    lFound := 0;
    for lPhase := Low(lPhase) to High(lPhase) do
      Inc(lFound, lRecording.Phases[lPhase].InvalidValueCount);
    RecordingCheck(lFound > 0, 'Invalid first samples must be reported');
  end;
  if aCase = 'window' then
  begin
    RecordingCheck(lRecording.Coverage = TMachineOverviewRecordingCoverage.Full, 'Complete window coverage');
    for lPhase := Low(lPhase) to High(lPhase) do
      for lProcess in lRecording.Phases[lPhase].Processes do
        RecordingCheck(lProcess.PeakCpuPercent <= 10.01, 'Out-of-window samples must be ignored');
    lIncident.StartedAtUtc := IncHour(lIncident.StartedAtUtc, 2);
    lIncident.EndedAtUtc := IncHour(lIncident.EndedAtUtc, 2);
    RecordingCheck(TryReadMachineOverviewRecording([lFile], lIncident, 32, nil, lRecording, lError) and
      (lRecording.Coverage = TMachineOverviewRecordingCoverage.None) and
      ContainsText(MachineOverviewRecordingText(lRecording), 'incident window'), 'No overlap must be explicit');
  end;
end;

function RunMachineOverviewRecordingSelfTests(const aArg: string): Integer;
const
  cCases: array[0..10] of string = ('polish', 'renumber', 'reuse', 'exit', 'invalid', 'normalization',
    'window', 'refusal', 'open', 'machines', 'cancel');
var
  lDirectory, lCase, lProbe: string;
  lError: string; //PALOFF Our conventions require non-loop locals in the var section.
  lIncident: TMachineOverviewIncident;
  lRecording: TMachineOverviewRecording;
  lTimer: TStopwatch;
begin
  Result := -1;
  if not SameText(aArg, '--self-test-machine-overview-recording') then
    Exit;
  Result := 0;
  lProbe := GetEnvironmentVariable('ACV_RECORDING_PROBE');
  if not lProbe.IsEmpty then
  begin
    lIncident := Default(TMachineOverviewIncident);
    lIncident.StartedAtUtc := EncodeDate(2026, 10, 20);
    lIncident.EndedAtUtc := IncDay(lIncident.StartedAtUtc);
    lTimer := TStopwatch.StartNew;
    if not TryReadMachineOverviewRecording([lProbe], lIncident, 32, nil, lRecording, lError) then
    begin
      Writeln('PROBE FAILED: ' + lError);
      Exit(1);
    end;
    Writeln(Format('PROBE elapsed_ms=%d bytes=%d', [lTimer.ElapsedMilliseconds, TFile.GetSize(lProbe)]));
    Writeln(MachineOverviewRecordingText(lRecording));
    Exit;
  end;
  lDirectory := CombinePath([TPath.GetTempPath, 'ActiveAppView-MachineOverview', 'recording-tests',
    IntToStr(GetCurrentProcessId)]);
  ForceDirectories(lDirectory);
  try
    for lCase in cCases do
    begin
      try
        CheckRecordingCase(lDirectory, lCase);
        Writeln('PASS recording ' + lCase);
      except
        on lException: Exception do
        begin
          Inc(Result);
          Writeln('FAIL recording ' + lCase + ': ' + lException.Message);
        end;
      end;
    end;
    Writeln(Format('Recording: %d tests, %d failed, 0 skipped', [Length(cCases), Result]));
  finally
    // Only our PID-scoped fixture root, created above, is disposable.
    TDirectory.Delete(lDirectory, True);
  end;
end;

end.

unit ActiveAppView.HarnessSetup;

{ Adds AgentStateHook.exe to the Claude Code and Codex hook configuration on Windows and in WSL. }

interface

uses
  System.SysUtils;

type
  THarnessKind = (hkClaude, hkCodex);

  THarnessChange = record
    Kind: THarnessKind;
    Title: string;
    FileName: string;
    Command: string;
    FileExists: Boolean;
    OldText: string;
    NewText: string;
    Changed: Boolean;
    ErrorText: string;
  end;
  THarnessChanges = TArray<THarnessChange>;

function ApplyHarnessChanges(var aChanges: THarnessChanges): string;
function DescribeHarnessChanges(const aChanges: THarnessChanges): string;
function MergeHarnessHooks(const aJson: string; const aKind: THarnessKind; const aCommand: string;
  out aNewJson: string): Boolean;
function PlanHarnessSetup(const aHookExe: string): THarnessChanges;
function RunHarnessSetupSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.Generics.Collections, System.IOUtils, System.JSON, System.StrUtils,
  System.Win.Registry,
  Winapi.Windows,
  ActiveAppView.MachineOverview.BoundedProcess;

const
  cHarnessSetupPreviewArg = '--harness-setup-preview';
  cHarnessSetupSelfTestArg = '--self-test-harness-setup';
  cHookMarker = 'AgentStateHook';
  cHookTimeoutSeconds = 10;
  cHarnessNames: array[THarnessKind] of string = ('claude', 'codex');
  cHarnessTitles: array[THarnessKind] of string = ('Claude Code', 'Codex');
  cClaudeEvents: array[0..9] of string = ('SessionStart', 'UserPromptSubmit', 'PostToolUse',
    'PostToolUseFailure', 'PermissionRequest', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure',
    'SessionEnd');
  cCodexEvents: array[0..6] of string = ('SessionStart', 'UserPromptSubmit', 'PostToolUse',
    'PermissionRequest', 'Stop', 'Interrupt', 'SessionEnd');
  cWslProbeTimeoutMs = 15000;

function HarnessEvents(const aKind: THarnessKind): TArray<string>;
var
  lEvent: string;
begin
  Result := nil;
  if aKind = hkClaude then
    for lEvent in cClaudeEvents do
      Result := Result + [lEvent]
  else
    for lEvent in cCodexEvents do
      Result := Result + [lEvent];
end;

function QuoteIfNeeded(const aPath: string): string;
begin
  if Pos(' ', aPath) > 0 then
    Result := '"' + aPath + '"'
  else
    Result := aPath;
end;

function IsOurHook(aValue: TJSONValue): Boolean;
begin
  Result := (aValue is TJSONObject) and
    ContainsText(TJSONObject(aValue).GetValue<string>('command', ''), cHookMarker);
end;

function MergeHarnessHooks(const aJson: string; const aKind: THarnessKind; const aCommand: string;
  out aNewJson: string): Boolean;
var
  lEvent: string;
  lEventHooks: TJSONArray;
  lGroup: TJSONObject;
  lGroupHooks: TJSONValue;
  lHook: TJSONObject;
  lHooks: TJSONObject;
  lOriginal: string;
  lRoot: TJSONValue;
  i: Integer;
  j: Integer;
  k: Integer;
begin
  if Trim(aJson) = '' then
    lRoot := TJSONObject.Create
  else
    lRoot := TJSONObject.ParseJSONValue(aJson);
  if not (lRoot is TJSONObject) then
  begin
    lRoot.Free;
    raise Exception.Create('The file is not a JSON object');
  end;
  try
    lOriginal := lRoot.ToJSON;
    if TJSONObject(lRoot).GetValue('hooks') = nil then
      TJSONObject(lRoot).AddPair('hooks', TJSONObject.Create);
    if not (TJSONObject(lRoot).GetValue('hooks') is TJSONObject) then
      raise Exception.Create('"hooks" is not a JSON object');
    lHooks := TJSONObject(TJSONObject(lRoot).GetValue('hooks'));

    // Remove our previous entries everywhere so a moved executable or dropped event leaves nothing behind.
    for i := lHooks.Count - 1 downto 0 do
    begin
      if not (lHooks.Pairs[i].JsonValue is TJSONArray) then
        Continue;
      lEventHooks := TJSONArray(lHooks.Pairs[i].JsonValue);
      for j := lEventHooks.Count - 1 downto 0 do
      begin
        if not (lEventHooks.Items[j] is TJSONObject) then
          Continue;
        lGroupHooks := TJSONObject(lEventHooks.Items[j]).GetValue('hooks');
        if not (lGroupHooks is TJSONArray) then
          Continue;
        for k := TJSONArray(lGroupHooks).Count - 1 downto 0 do
          if IsOurHook(TJSONArray(lGroupHooks).Items[k]) then
            TJSONArray(lGroupHooks).Remove(k).Free;
        if TJSONArray(lGroupHooks).Count = 0 then
          lEventHooks.Remove(j).Free;
      end;
      if lEventHooks.Count = 0 then
        lHooks.RemovePair(lHooks.Pairs[i].JsonString.Value).Free;
    end;

    for lEvent in HarnessEvents(aKind) do
    begin
      if lHooks.GetValue(lEvent) = nil then
        lHooks.AddPair(lEvent, TJSONArray.Create);
      if not (lHooks.GetValue(lEvent) is TJSONArray) then
        raise Exception.CreateFmt('"hooks.%s" is not a JSON array', [lEvent]);
      lHook := TJSONObject.Create;
      lHook.AddPair('type', 'command');
      lHook.AddPair('command', aCommand);
      lHook.AddPair('timeout', TJSONNumber.Create(cHookTimeoutSeconds));
      lGroup := TJSONObject.Create;
      lGroup.AddPair('hooks', TJSONArray.Create(lHook));
      TJSONArray(lHooks.GetValue(lEvent)).AddElement(lGroup);
    end;

    Result := lRoot.ToJSON <> lOriginal;
    // Format escapes every '/' as '\/'; both are valid JSON, but settings files are read by people too.
    aNewJson := ReplaceStr(lRoot.Format(2), '\/', '/');
  finally
    lRoot.Free;
  end;
end;

function DetectLineBreak(const aText, aDefault: string): string;
begin
  if Pos(#13#10, aText) > 0 then
    Result := #13#10
  else if Pos(#10, aText) > 0 then
    Result := #10
  else
    Result := aDefault;
end;

procedure PlanTarget(const aKind: THarnessKind; const aTitle, aConfigDir, aCommand, aLineBreak: string;
  var aChanges: THarnessChanges);
var
  lChange: THarnessChange;
begin
  // A harness that was never started on this side has no config folder; we do not create one.
  if not TDirectory.Exists(aConfigDir) then
    Exit;
  lChange := Default(THarnessChange);
  lChange.Kind := aKind;
  lChange.Title := aTitle;
  lChange.Command := aCommand;
  if aKind = hkClaude then
    lChange.FileName := TPath.Combine(aConfigDir, 'settings.json')
  else
    lChange.FileName := TPath.Combine(aConfigDir, 'hooks.json');
  try
    lChange.FileExists := TFile.Exists(lChange.FileName);
    if lChange.FileExists then
      lChange.OldText := TFile.ReadAllText(lChange.FileName, TEncoding.UTF8);
    lChange.Changed := MergeHarnessHooks(lChange.OldText, aKind, aCommand, lChange.NewText);
    lChange.NewText := ReplaceStr(lChange.NewText, #13#10, #10);
    lChange.NewText := ReplaceStr(lChange.NewText, #10, DetectLineBreak(lChange.OldText, aLineBreak)) +
      DetectLineBreak(lChange.OldText, aLineBreak);
  except
    on lException: Exception do
      lChange.ErrorText := lException.Message;
  end;
  aChanges := aChanges + [lChange];
end;

function WslDistributions: TArray<string>;
var
  lKeys: TStringList;
  lName: string;
  lRegistry: TRegistry;
  lSubKey: string;
begin
  Result := nil;
  lRegistry := TRegistry.Create(KEY_READ);
  lKeys := TStringList.Create;
  try
    lRegistry.RootKey := HKEY_CURRENT_USER;
    if not lRegistry.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Lxss') then
      Exit;
    lRegistry.GetKeyNames(lKeys);
    lRegistry.CloseKey;
    for lSubKey in lKeys do
      if lRegistry.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Lxss\' + lSubKey) then
      begin
        lName := lRegistry.ReadString('DistributionName');
        lRegistry.CloseKey;
        // Docker's internal distributions are not user shells.
        if (lName <> '') and not StartsText('docker-desktop', lName) then
          Result := Result + [lName];
      end;
  finally
    lKeys.Free;
    lRegistry.Free;
  end;
end;

function PlanHarnessSetup(const aHookExe: string): THarnessChanges;
var
  lDistro: string;
  lHome: string;
  lKind: THarnessKind;
  lLines: TArray<string>;
  lProbe: TMachineOverviewProcessResult;
  lRoot: string;
  lWslExe: string;
begin
  Result := nil;
  // Claude runs Windows hooks through Git Bash, Codex through cmd.exe.
  PlanTarget(hkClaude, 'Windows ' + cHarnessTitles[hkClaude],
    TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.claude'),
    QuoteIfNeeded(ReplaceStr(aHookExe, '\', '/')) + ' claude', #13#10, Result);
  PlanTarget(hkCodex, 'Windows ' + cHarnessTitles[hkCodex],
    TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.codex'),
    QuoteIfNeeded(aHookExe) + ' codex', #13#10, Result);
  lWslExe := TPath.Combine(TPath.GetDirectoryName(GetEnvironmentVariable('ComSpec')), 'wsl.exe');
  if not TFile.Exists(lWslExe) then
    Exit;
  for lDistro in WslDistributions do
  begin
    // Distribution names contain no spaces, and wsl.exe would keep quotes as part of the name.
    // One call yields the Linux home and the hook path as that distribution mounts Windows drives.
    lProbe := RunMachineOverviewBoundedProcess(lWslExe,
      Format('-d %s -e sh -c "echo \"$HOME\"; wslpath -u \"$0\"" "%s"', [lDistro, aHookExe]),
      cWslProbeTimeoutMs, 64 * 1024);
    lLines := Trim(lProbe.OutputText).Split([#10]);
    if (not lProbe.Started) or lProbe.TimedOut or (lProbe.ExitCode <> 0) or (Length(lLines) < 2) then
      Continue;
    lHome := Trim(lLines[0]);
    lRoot := '\\wsl.localhost\' + lDistro + ReplaceStr(lHome, '/', '\');
    for lKind := Low(THarnessKind) to High(THarnessKind) do
      PlanTarget(lKind, 'WSL ' + lDistro + ' ' + cHarnessTitles[lKind],
        TPath.Combine(lRoot, '.' + cHarnessNames[lKind]),
        QuoteIfNeeded(Trim(lLines[1])) + ' ' + cHarnessNames[lKind], #10, Result);
  end;
end;

function DescribeHarnessChanges(const aChanges: THarnessChanges): string;
var
  lChange: THarnessChange;
  lLines: TStringList;
begin
  lLines := TStringList.Create;
  try
    if Length(aChanges) = 0 then
      lLines.Add('No Claude Code or Codex configuration folder was found on Windows or in WSL.');
    for lChange in aChanges do
    begin
      lLines.Add(lChange.Title + ':');
      lLines.Add('  ' + lChange.FileName);
      if lChange.ErrorText <> '' then
        lLines.Add('  Skipped: ' + lChange.ErrorText)
      else if not lChange.Changed then
        lLines.Add('  Already set up.')
      else if lChange.FileExists then
        lLines.Add(Format('  Add state hooks for %d events; a backup copy is kept.',
          [Length(HarnessEvents(lChange.Kind))]))
      else
        lLines.Add(Format('  Create the file with state hooks for %d events.', [Length(HarnessEvents(lChange.Kind))]));
      if lChange.Changed and (lChange.ErrorText = '') then
        lLines.Add('  Runs: ' + lChange.Command);
    end;
    Result := lLines.Text;
  finally
    lLines.Free;
  end;
end;

function ApplyHarnessChanges(var aChanges: THarnessChanges): string;
var
  lBackup: string;
  lEncoding: TEncoding;
  lLines: TStringList;
  i: Integer;
begin
  lEncoding := TUTF8Encoding.Create(False);
  lLines := TStringList.Create;
  try
    for i := 0 to High(aChanges) do
    begin
      if (aChanges[i].ErrorText <> '') or not aChanges[i].Changed then
        Continue;
      try
        if aChanges[i].FileExists then
        begin
          // Never overwrite a file that changed after the preview was built.
          if TFile.ReadAllText(aChanges[i].FileName, TEncoding.UTF8) <> aChanges[i].OldText then
            raise Exception.Create('the file changed after the preview; run the setup again');
          lBackup := aChanges[i].FileName + '.bak-activeappview-' + FormatDateTime('yyyymmdd-hhnnss', Now);
          TFile.Copy(aChanges[i].FileName, lBackup, False);
        end;
        TFile.WriteAllText(aChanges[i].FileName, aChanges[i].NewText, lEncoding);
        lLines.Add('Updated ' + aChanges[i].Title + '.');
      except
        on lException: Exception do
        begin
          aChanges[i].ErrorText := lException.Message;
          lLines.Add('Failed ' + aChanges[i].Title + ': ' + lException.Message);
        end;
      end;
    end;
    if lLines.Count = 0 then
      lLines.Add('Nothing to change.');
    Result := lLines.Text;
  finally
    lLines.Free;
    lEncoding.Free;
  end;
end;

function RunHarnessSetupSelfTests(const aArg: string): Integer;
const
  cExisting = '{"note":"a \u2014 b","statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh"},' +
    '"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},' +
    '{"type":"command","command":"C:/old/AgentStateHook.exe claude"}]}],' +
    '"Interrupt":[{"hooks":[{"type":"command","command":"C:/old/AgentStateHook.exe claude"}]}]}}';
var
  lAgain: string;
  lChange: THarnessChange;
  lChanges: THarnessChanges;
  lMerged: string;
  lRoot: TJSONValue;
  lStop: TJSONArray;
begin
  // Read-only: shows what the Setup harnesses button would write.
  if SameText(aArg, cHarnessSetupPreviewArg) then
  begin
    lChanges := PlanHarnessSetup(TPath.Combine(ExtractFilePath(ParamStr(0)), 'AgentStateHook.exe'));
    for lChange in lChanges do
      if lChange.Changed and (lChange.ErrorText = '') then
        Writeln('=== ', lChange.FileName, sLineBreak, lChange.NewText);
    Writeln(DescribeHarnessChanges(lChanges));
    Exit(0);
  end;
  if not SameText(aArg, cHarnessSetupSelfTestArg) then
    Exit(-1);
  Result := 0;
  try
    if not MergeHarnessHooks(cExisting, hkClaude, 'F:/app/AgentStateHook.exe claude', lMerged) then
      raise Exception.Create('The first merge reported no change');
    if MergeHarnessHooks(lMerged, hkClaude, 'F:/app/AgentStateHook.exe claude', lAgain) or (lAgain <> lMerged) then
      raise Exception.Create('The merge is not idempotent');
    if ContainsText(lMerged, '\/') or not ContainsText(lMerged, '"bash ~/.claude/statusline.sh"') or
      not ContainsText(lMerged, '"a ' + Char($2014) + ' b"') then
      raise Exception.Create('Unrelated settings were not preserved verbatim');
    lRoot := TJSONObject.ParseJSONValue(lMerged);
    try
      lStop := lRoot.GetValue<TJSONArray>('hooks.Stop');
      if (lStop.Count <> 2) or
        (lStop.Items[0].GetValue<TJSONArray>('hooks').Count <> 1) or
        (lStop.Items[0].GetValue<string>('hooks[0].command') <> 'say done') or
        (lStop.Items[1].GetValue<string>('hooks[0].command') <> 'F:/app/AgentStateHook.exe claude') then
        raise Exception.Create('Stop hooks were not merged correctly: ' + lStop.ToJSON);
      if (lRoot.FindValue('hooks.Interrupt') <> nil) or
        (lRoot.GetValue<TJSONArray>('hooks.PermissionRequest').Count <> 1) then
        raise Exception.Create('Stale entries were kept or new events are missing');
    finally
      lRoot.Free;
    end;
    if not MergeHarnessHooks('', hkCodex, 'x\AgentStateHook.exe codex', lMerged) or
      not ContainsText(lMerged, '"Interrupt"') or ContainsText(lMerged, '"Notification"') then
      raise Exception.Create('The Codex event set is wrong');
    try
      MergeHarnessHooks('[]', hkCodex, 'x', lMerged);
      raise Exception.Create('A non-object file was accepted');
    except
      on lException: Exception do
        if not ContainsText(lException.Message, 'not a JSON object') then
          raise;
    end;
    if QuoteIfNeeded('C:/Program Files/a.exe') <> '"C:/Program Files/a.exe"' then
      raise Exception.Create('Paths with spaces must be quoted');
    Writeln('HARNESS SETUP PASS');
  except
    on lException: Exception do
    begin
      Writeln('SELFTEST FAILED: ' + lException.Message);
      Result := 1;
    end;
  end;
end;

end.

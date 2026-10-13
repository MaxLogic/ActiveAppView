unit ActiveAppView.AgentState;

{ Codex/Claude session state for terminal windows. Sources, strongest first: Claude's own session
  registry (%USERPROFILE%\.claude\sessions\<pid>.json), harness hooks (AgentStateHook.exe) matched
  through the hook's Windows process ancestry, and a harness process seen below the terminal. }

interface

uses
  System.Generics.Collections, System.SysUtils,
  Winapi.Messages, Winapi.Windows;

const
  // AgentStateHook.exe posts this to ActiveAppView so a state change shows without waiting for polling.
  cAgentStateRefreshMessage = WM_APP + 182;
  cAgentStateMainWindowClass = 'TAppsViewMainFrm';

type
  // Ordered by precedence when several sessions share one terminal window.
  TAgentState = (asNone, asAgent, asIdle, asWorking, asActionRequired);

  TAgentProcessInfo = record
    PID: Cardinal;
    ParentPID: Cardinal;
    Name: string;
  end;

  TAgentChainEntry = record
    PID: Cardinal;
    StartedAt: Int64;
    Name: string;
  end;

  TAgentStateRecord = record
    FileName: string;
    State: TAgentState;
    Anchor: TAgentChainEntry;
    Chain: TArray<TAgentChainEntry>;
  end;

  TAgentTerminal = record
    PID: Cardinal;
    StartedAt: Int64;
  end;

  TAgentWindowState = record
    State: TAgentState;
    // Reported by the harness itself for this very process; beats title markers.
    Authoritative: Boolean;
  end;

  TAgentProcessAlive = reference to function(const aEntry: TAgentChainEntry): Boolean;
  TAgentSessionLookup = reference to function(const aPid: Cardinal; out aState: TAgentState): Boolean;

function AgentStateDir: string;
function ClaudeStatusToAgentState(const aStatus: string): TAgentState;
function CollectTerminalAgentStates(const aTerminals: TArray<TAgentTerminal>): TArray<TAgentWindowState>;
function HookEventToAgentState(const aEvent, aNotificationType, aSource: string;
  out aState: TAgentState; out aEndsSession: Boolean): Boolean;
function ReadAgentStateFiles(const aStateDir: string): TArray<TAgentStateRecord>;
function ResolveAgentStates(const aTerminals: TArray<TAgentTerminal>;
  const aProcesses: TArray<TAgentProcessInfo>; const aStates: TArray<TAgentStateRecord>;
  const aIsAlive: TAgentProcessAlive; const aSessionState: TAgentSessionLookup;
  aStaleFiles: TList<string>): TArray<TAgentWindowState>;
function RunAgentStateHook: Integer;
function RunAgentStateSelfTests(const aArg: string): Integer;
function WriteAgentHookState(const aHarness, aInput, aStateDir: string;
  const aChain: TArray<TAgentChainEntry>): Boolean;

implementation

uses
  System.Classes, System.DateUtils, System.IOUtils, System.JSON, System.StrUtils,
  Winapi.TlHelp32,
  MaxLogic.Windows.Identity;

const
  cAgentStateDumpArg = '--agent-state-dump';
  cAgentStateSelfTestArg = '--self-test-agent-state';
  cFileTimeUnixEpoch = 116444736000000000;
  cMaxAncestorDepth = 32;
  cProcessQueryLimitedInformation = $1000; // PROCESS_QUERY_LIMITED_INFORMATION
  cStateNames: array[TAgentState] of string = ('none', 'agent', 'idle', 'working', 'action');

function AgentStateDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'ActiveAppView\AgentState');
end;

function IsClaudeProcessName(const aName: string): Boolean;
begin
  // A self-updating Claude keeps running as claude.exe.old.<id>.
  Result := StartsText('claude.exe', aName);
end;

function IsHarnessProcessName(const aName: string): Boolean;
begin
  Result := IsClaudeProcessName(aName) or StartsText('codex.exe', aName);
end;

function ClaudeStatusToAgentState(const aStatus: string): TAgentState;
begin
  if SameText(aStatus, 'busy') then
    Result := asWorking
  else if SameText(aStatus, 'waiting') then
    Result := asActionRequired
  // "shell": idle at the prompt while a background shell keeps running.
  else if SameText(aStatus, 'idle') or SameText(aStatus, 'shell') then
    Result := asIdle
  else
    Result := asNone;
end;

function JsonText(aJson: TJSONValue; const aName: string): string;
var
  lValue: TJSONValue;
begin
  lValue := aJson.FindValue(aName);
  if Assigned(lValue) then
    Result := lValue.Value
  else
    Result := '';
end;

function ClaudeSessionState(const aPid: Cardinal; out aState: TAgentState): Boolean;
var
  lFileName: string;
  lJson: TJSONValue;
  lProcStart: Int64;
  lStartedAt: Int64;
begin
  Result := False;
  aState := asNone;
  lFileName := TPath.Combine(GetEnvironmentVariable('USERPROFILE'),
    '.claude\sessions\' + UIntToStr(aPid) + '.json');
  if not TFile.Exists(lFileName) then
    Exit;
  try
    lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(lFileName, TEncoding.UTF8));
  except
    // Claude may be replacing the file right now; the next refresh reads it.
    on EFOpenError do
      Exit;
    on EFileNotFoundException do
      Exit;
  end;
  try
    if not (lJson is TJSONObject) or (StrToInt64Def(JsonText(lJson, 'pid'), 0) <> aPid) then
      Exit;
    // procStart is the process creation FILETIME; a mismatch means a reused PID and a stale file.
    lProcStart := StrToInt64Def(JsonText(lJson, 'procStart'), 0);
    if (lProcStart > 0) and TryGetProcessStartedAtUtcMilliseconds(aPid, lStartedAt) and
      (Abs((lProcStart - cFileTimeUnixEpoch) div 10000 - lStartedAt) > 1) then
      Exit;
    aState := ClaudeStatusToAgentState(JsonText(lJson, 'status'));
    Result := aState <> asNone;
  finally
    lJson.Free;
  end;
end;

function HookEventToAgentState(const aEvent, aNotificationType, aSource: string;
  out aState: TAgentState; out aEndsSession: Boolean): Boolean;
begin
  aState := asNone;
  aEndsSession := SameText(aEvent, 'SessionEnd');
  if aEndsSession then
    Exit(True);
  if SameText(aEvent, 'UserPromptSubmit') or SameText(aEvent, 'PostToolUse') or
    SameText(aEvent, 'PostToolUseFailure') or SameText(aEvent, 'PermissionDenied') then
    aState := asWorking
  else if SameText(aEvent, 'PermissionRequest') or SameText(aEvent, 'Elicitation') then
    aState := asActionRequired
  else if SameText(aEvent, 'Stop') or SameText(aEvent, 'StopFailure') or SameText(aEvent, 'Interrupt') then
    aState := asIdle
  // Compaction can restart a session in the middle of a turn.
  else if SameText(aEvent, 'SessionStart') and not SameText(aSource, 'compact') then
    aState := asIdle
  else if SameText(aEvent, 'Notification') then
  begin
    if SameText(aNotificationType, 'idle_prompt') then
      aState := asIdle
    else if SameText(aNotificationType, 'permission_prompt') or
      SameText(aNotificationType, 'elicitation_dialog') or
      SameText(aNotificationType, 'elicitation_url_dialog') or
      SameText(aNotificationType, 'agent_needs_input') then
      aState := asActionRequired;
  end;
  Result := aState <> asNone;
end;

function StateFromName(const aName: string): TAgentState;
var
  lState: TAgentState;
begin
  for lState := Low(TAgentState) to High(TAgentState) do
    if SameText(cStateNames[lState], aName) then
      Exit(lState);
  Result := asNone;
end;

function SnapshotProcesses: TArray<TAgentProcessInfo>;
var
  lEntry: TProcessEntry32;
  lList: TList<TAgentProcessInfo>;
  lProcess: TAgentProcessInfo;
  lSnapshot: THandle;
begin
  Result := nil;
  lSnapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if lSnapshot = INVALID_HANDLE_VALUE then
    Exit;
  lList := TList<TAgentProcessInfo>.Create;
  try
    lEntry := Default(TProcessEntry32);
    lEntry.dwSize := SizeOf(lEntry);
    if Process32First(lSnapshot, lEntry) then
      repeat
        lProcess.PID := lEntry.th32ProcessID;
        lProcess.ParentPID := lEntry.th32ParentProcessID;
        lProcess.Name := lEntry.szExeFile;
        lList.Add(lProcess);
      until not Process32Next(lSnapshot, lEntry);
    Result := lList.ToArray;
  finally
    lList.Free;
    CloseHandle(lSnapshot);
  end;
end;

function CurrentProcessChain: TArray<TAgentChainEntry>;
var
  lByPid: TDictionary<Cardinal, TAgentProcessInfo>;
  lEntry: TAgentChainEntry;
  lList: TList<TAgentChainEntry>;
  lPid: Cardinal;
  lProcess: TAgentProcessInfo;
begin
  lByPid := TDictionary<Cardinal, TAgentProcessInfo>.Create;
  lList := TList<TAgentChainEntry>.Create;
  try
    for lProcess in SnapshotProcesses do
      lByPid.AddOrSetValue(lProcess.PID, lProcess);
    if not lByPid.TryGetValue(GetCurrentProcessId, lProcess) then
      Exit(nil);
    lPid := lProcess.ParentPID;
    while (lList.Count < cMaxAncestorDepth) and lByPid.TryGetValue(lPid, lProcess) do
    begin
      lEntry.PID := lProcess.PID;
      lEntry.Name := lProcess.Name;
      // A parent that exited and whose PID was reused can start after its "child"; stop there.
      if not TryGetProcessStartedAtUtcMilliseconds(lPid, lEntry.StartedAt) then
        lEntry.StartedAt := 0;
      if (lList.Count > 0) and (lEntry.StartedAt > lList.Last.StartedAt) and (lList.Last.StartedAt > 0) then
        Break;
      lList.Add(lEntry);
      lPid := lProcess.ParentPID;
    end;
    Result := lList.ToArray;
  finally
    lList.Free;
    lByPid.Free;
  end;
end;

function SelectAnchor(const aChain: TArray<TAgentChainEntry>): TAgentChainEntry;
var
  i: Integer;
  j: Integer;
begin
  // The harness process decides liveness; inside WSL the outermost wsl.exe stands in for it.
  Result := Default(TAgentChainEntry);
  for i := 0 to High(aChain) do
    if IsHarnessProcessName(aChain[i].Name) then
      Exit(aChain[i]);
  for i := 0 to High(aChain) do
    if SameText(aChain[i].Name, 'wsl.exe') then
    begin
      j := i;
      while (j < High(aChain)) and SameText(aChain[j + 1].Name, 'wsl.exe') do
        Inc(j);
      Exit(aChain[j]);
    end;
  if Length(aChain) > 0 then
    Result := aChain[0];
end;

function ChainEntryToJson(const aEntry: TAgentChainEntry): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('pid', TJSONNumber.Create(aEntry.PID));
  Result.AddPair('started', TJSONNumber.Create(aEntry.StartedAt));
  Result.AddPair('name', aEntry.Name);
end;

function JsonToChainEntry(aValue: TJSONValue): TAgentChainEntry;
begin
  Result := Default(TAgentChainEntry);
  if not (aValue is TJSONObject) then
    Exit;
  Result.PID := Cardinal(TJSONObject(aValue).GetValue<Int64>('pid', 0));
  Result.StartedAt := TJSONObject(aValue).GetValue<Int64>('started', 0);
  Result.Name := TJSONObject(aValue).GetValue<string>('name', '');
end;

function SafeFilePart(const aValue: string): string;
var
  c: Char;
begin
  Result := '';
  for c in aValue do
    if CharInSet(c, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Result := Result + c;
end;

function WriteAgentHookState(const aHarness, aInput, aStateDir: string;
  const aChain: TArray<TAgentChainEntry>): Boolean;
var
  lChainJson: TJSONArray;
  lEndsSession: Boolean;
  lEntry: TAgentChainEntry;
  lFileName: string;
  lInput: TJSONValue;
  lOutput: TJSONObject;
  lSession: string;
  lState: TAgentState;
  lTempName: string;
begin
  Result := False;
  lInput := TJSONObject.ParseJSONValue(aInput);
  try
    if not (lInput is TJSONObject) then
      Exit;
    lSession := SafeFilePart(lInput.GetValue<string>('session_id', ''));
    if (lSession = '') or (SafeFilePart(aHarness) = '') then
      Exit;
    if not HookEventToAgentState(lInput.GetValue<string>('hook_event_name', ''),
      lInput.GetValue<string>('notification_type', ''), lInput.GetValue<string>('source', ''),
      lState, lEndsSession) then
      Exit(True);
    lFileName := TPath.Combine(aStateDir, SafeFilePart(aHarness) + '-' + lSession + '.json');
    if lEndsSession then
    begin
      System.SysUtils.DeleteFile(lFileName);
      Exit(True);
    end;
    lOutput := TJSONObject.Create;
    try
      lOutput.AddPair('harness', aHarness);
      lOutput.AddPair('session', lInput.GetValue<string>('session_id', ''));
      lOutput.AddPair('state', cStateNames[lState]);
      lOutput.AddPair('event', lInput.GetValue<string>('hook_event_name', ''));
      lOutput.AddPair('cwd', lInput.GetValue<string>('cwd', ''));
      lOutput.AddPair('transcript_path', lInput.GetValue<string>('transcript_path', ''));
      lOutput.AddPair('updated', DateToISO8601(TTimeZone.Local.ToUniversalTime(Now), True));
      lOutput.AddPair('anchor', ChainEntryToJson(SelectAnchor(aChain)));
      lChainJson := TJSONArray.Create;
      lOutput.AddPair('chain', lChainJson);
      for lEntry in aChain do
        lChainJson.AddElement(ChainEntryToJson(lEntry));
      ForceDirectories(aStateDir);
      // Readers must never see a half-written file.
      lTempName := lFileName + '.' + IntToStr(GetCurrentProcessId) + '.tmp';
      TFile.WriteAllText(lTempName, lOutput.ToJSON, TEncoding.UTF8);
      Result := MoveFileEx(PChar(lTempName), PChar(lFileName), MOVEFILE_REPLACE_EXISTING);
      if not Result then
        System.SysUtils.DeleteFile(lTempName);
    finally
      lOutput.Free;
    end;
  finally
    lInput.Free;
  end;
end;

function ReadStdIn: string;
var
  lBytes: TBytesStream;
  lStdIn: THandleStream;
begin
  lStdIn := THandleStream.Create(GetStdHandle(STD_INPUT_HANDLE));
  lBytes := TBytesStream.Create;
  try
    lBytes.CopyFrom(lStdIn, 0);
    Result := TEncoding.UTF8.GetString(lBytes.Bytes, 0, lBytes.Size);
  finally
    lBytes.Free;
    lStdIn.Free;
  end;
end;

function RunAgentStateHook: Integer;
var
  lWnd: HWND;
begin
  // Hooks must never disturb the harness: no stdout, always exit 0, problems go to stderr.
  Result := 0;
  try
    if WriteAgentHookState(ParamStr(1), ReadStdIn, AgentStateDir, CurrentProcessChain) then
    begin
      lWnd := FindWindow(cAgentStateMainWindowClass, nil);
      if lWnd <> 0 then
        PostMessage(lWnd, cAgentStateRefreshMessage, 0, 0);
    end;
  except
    on lException: Exception do
      Writeln(ErrOutput, 'AgentStateHook: ', lException.ClassName, ': ', lException.Message);
  end;
end;

function FindCodexTranscript(aJson: TJSONValue): string;
var
  lDate: TDateTime;
  lDirectory: string;
  lFiles: TArray<string>;
  lHome: string;
  lMilliseconds: Int64;
  lSession: string;
  i: Integer;
begin
  Result := JsonText(aJson, 'transcript_path');
  lSession := JsonText(aJson, 'session');
  if Result <> '' then
  begin
    if not EndsText('-' + lSession + '.jsonl', Result) then
      Result := '';
    Exit;
  end;
  // Older hook files lack a path. UUIDv7 identifies the session creation day,
  // so we can find its rollout without walking the entire session archive.
  if (Length(lSession) <> 36) or (SafeFilePart(lSession) <> lSession) or
    (lSession[15] <> '7') or
    not TryStrToInt64('$' + Copy(lSession, 1, 8) + Copy(lSession, 10, 4), lMilliseconds) or
    (lMilliseconds < 0) or (lMilliseconds > 253402214400000) then
    Exit;
  lHome := GetEnvironmentVariable('CODEX_HOME');
  if lHome = '' then
    lHome := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.codex');
  lDate := UnixToDateTime(lMilliseconds div 1000, True);
  try
    for i := 0 to 1 do
    begin
      lDirectory := TPath.Combine(TPath.Combine(lHome, 'sessions'), FormatDateTime('yyyy\mm\dd', lDate));
      if TDirectory.Exists(lDirectory) then
      begin
        lFiles := TDirectory.GetFiles(lDirectory, 'rollout-*-' + lSession + '.jsonl');
        if Length(lFiles) = 1 then
          Exit(lFiles[0]);
      end;
      if i = 0 then
        lDate := TTimeZone.Local.ToLocalTime(lDate);
    end;
  except
    // Missing or inaccessible session directories leave the hook state intact.
    on EInOutError do
      Exit('');
    on EOSError do
      Exit('');
  end;
end;

function CodexTranscriptTail(const aFileName: string): string;
const
  cMaxTailBytes = 256 * 1024;
var
  lBytes: TBytes;
  lFirst: Integer;
  lOffset: Int64;
  lSize: Int64;
  lStream: TFileStream;
begin
  Result := '';
  try
    lStream := TFileStream.Create(aFileName, fmOpenRead or fmShareDenyNone);
    try
      lSize := lStream.Size;
      lOffset := lSize - cMaxTailBytes;
      if lOffset < 0 then
        lOffset := 0;
      lStream.Position := lOffset;
      SetLength(lBytes, lSize - lOffset);
      if Length(lBytes) = 0 then
        Exit;
      lStream.ReadBuffer(lBytes[0], Length(lBytes));
    finally
      lStream.Free;
    end;
  except
    // A live writer may replace or truncate the rollout. Retry on the next poll.
    on EStreamError do
      Exit;
  end;
  // Do not let an older completion win while a newer record is half-written.
  if lBytes[High(lBytes)] <> 10 then
    Exit;
  lFirst := 0;
  if lOffset > 0 then
  begin
    // The bounded read can start inside a UTF-8 scalar. Drop the partial JSONL record before decoding.
    while (lFirst < Length(lBytes)) and (lBytes[lFirst] <> 10) do
      Inc(lFirst);
    if lFirst = Length(lBytes) then
      Exit;
    Inc(lFirst);
  end;
  Result := TEncoding.UTF8.GetString(lBytes, lFirst, Length(lBytes) - lFirst);
end;

function TryCodexTranscriptState(const aFileName, aUpdated: string; out aState: TAgentState): Boolean;
var
  lEvent: string;
  lEventDate: TDateTime;
  lHookDate: TDateTime;
  lJson: TJSONValue;
  lLines: TArray<string>;
  i: Integer;
begin
  Result := False;
  aState := asNone;
  if (aFileName = '') or not TryISO8601ToDate(aUpdated, lHookDate, True) then
    Exit;
  lLines := CodexTranscriptTail(aFileName).Split([#10]);
  for i := High(lLines) downto 0 do
  begin
    if Trim(lLines[i]) = '' then
      Continue;
    lJson := TJSONObject.ParseJSONValue(lLines[i]);
    try
      if not (lJson is TJSONObject) then
        Exit;
      if JsonText(lJson, 'type') <> 'event_msg' then
        Continue;
      lEvent := JsonText(lJson, 'payload.type');
      if (lEvent <> 'task_started') and (lEvent <> 'task_complete') and (lEvent <> 'turn_aborted') then
        Continue;
      if not TryISO8601ToDate(JsonText(lJson, 'timestamp'), lEventDate, True) or (lEventDate <= lHookDate) then
        Exit;
      if lEvent = 'task_started' then
        aState := asWorking
      else
        aState := asIdle;
      Exit(True);
    finally
      lJson.Free;
    end;
  end;
end;

function ReadAgentStateFiles(const aStateDir: string): TArray<TAgentStateRecord>;
var
  lFileName: string;
  lItem: TJSONValue;
  lJson: TJSONValue;
  lList: TList<TAgentStateRecord>;
  lRecord: TAgentStateRecord;
  lTranscriptState: TAgentState;
  lValue: TJSONValue;
begin
  if not TDirectory.Exists(aStateDir) then
    Exit(nil);
  lList := TList<TAgentStateRecord>.Create;
  try
    for lFileName in TDirectory.GetFiles(aStateDir, '*.json') do
    begin
      try
        lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(lFileName, TEncoding.UTF8));
      except
        // Another hook may be replacing the file right now; the next refresh reads it.
        on EFOpenError do
          Continue;
        on EFileNotFoundException do
          Continue;
      end;
      try
        if not (lJson is TJSONObject) then
          Continue;
        lRecord := Default(TAgentStateRecord);
        lRecord.FileName := lFileName;
        lRecord.State := StateFromName(lJson.GetValue<string>('state', ''));
        if SameText(JsonText(lJson, 'harness'), 'codex') and
          TryCodexTranscriptState(FindCodexTranscript(lJson), JsonText(lJson, 'updated'), lTranscriptState) then
          lRecord.State := lTranscriptState;
        lRecord.Anchor := JsonToChainEntry(TJSONObject(lJson).GetValue('anchor'));
        lValue := TJSONObject(lJson).GetValue('chain');
        if lValue is TJSONArray then
          for lItem in TJSONArray(lValue) do
            lRecord.Chain := lRecord.Chain + [JsonToChainEntry(lItem)];
        lList.Add(lRecord);
      finally
        lJson.Free;
      end;
    end;
    Result := lList.ToArray;
  finally
    lList.Free;
  end;
end;

function ResolveAgentStates(const aTerminals: TArray<TAgentTerminal>;
  const aProcesses: TArray<TAgentProcessInfo>; const aStates: TArray<TAgentStateRecord>;
  const aIsAlive: TAgentProcessAlive; const aSessionState: TAgentSessionLookup;
  aStaleFiles: TList<string>): TArray<TAgentWindowState>;
var
  lDepth: Integer;
  lEntry: TAgentChainEntry;
  lParents: TDictionary<Cardinal, Cardinal>;
  lPid: Cardinal;
  lProcess: TAgentProcessInfo;
  lRecord: TAgentStateRecord;
  lRegistry: TArray<TAgentState>;
  lSessionState: TAgentState;
  lStates: TArray<TAgentState>;
  lTerminalIndex: TDictionary<Cardinal, Integer>;
  i: Integer;
begin
  SetLength(Result, Length(aTerminals));
  SetLength(lStates, Length(aTerminals));
  SetLength(lRegistry, Length(aTerminals));
  lParents := TDictionary<Cardinal, Cardinal>.Create;
  lTerminalIndex := TDictionary<Cardinal, Integer>.Create;
  try
    for i := 0 to High(aTerminals) do
    begin
      lStates[i] := asNone;
      lRegistry[i] := asNone;
      lTerminalIndex.AddOrSetValue(aTerminals[i].PID, i);
    end;
    for lProcess in aProcesses do
      lParents.AddOrSetValue(lProcess.PID, lProcess.ParentPID);
    // A harness running below a terminal marks it as an agent even before any hook reports.
    for lProcess in aProcesses do
      if IsHarnessProcessName(lProcess.Name) then
      begin
        lPid := lProcess.ParentPID;
        lDepth := 0;
        while lDepth < cMaxAncestorDepth do
        begin
          Inc(lDepth);
          if lTerminalIndex.TryGetValue(lPid, i) then
          begin
            if lStates[i] < asAgent then
              lStates[i] := asAgent;
            if IsClaudeProcessName(lProcess.Name) and Assigned(aSessionState) and
              aSessionState(lProcess.PID, lSessionState) and (lRegistry[i] < lSessionState) then
              lRegistry[i] := lSessionState;
            Break;
          end;
          if (not lParents.TryGetValue(lPid, lPid)) or (lPid = 0) then
            Break;
        end;
      end;
    for lRecord in aStates do
    begin
      if not aIsAlive(lRecord.Anchor) then
      begin
        if Assigned(aStaleFiles) then
          aStaleFiles.Add(lRecord.FileName);
        Continue;
      end;
      for lEntry in lRecord.Chain do
        if lTerminalIndex.TryGetValue(lEntry.PID, i) and
          (lEntry.StartedAt = aTerminals[i].StartedAt) and (lStates[i] < lRecord.State) then
          lStates[i] := lRecord.State;
    end;
    // The registry describes the live session; a hook's "action required" may predate an approval.
    for i := 0 to High(aTerminals) do
    begin
      Result[i].Authoritative := lRegistry[i] <> asNone;
      if Result[i].Authoritative then
        Result[i].State := lRegistry[i]
      else
        Result[i].State := lStates[i];
    end;
  finally
    lTerminalIndex.Free;
    lParents.Free;
  end;
end;

function IsChainEntryAlive(const aEntry: TAgentChainEntry): Boolean;
var
  lExitCode: Cardinal;
  lProcess: THandle;
  lStartedAt: Int64;
begin
  if aEntry.PID = 0 then
    Exit(False);
  lProcess := OpenProcess(cProcessQueryLimitedInformation, False, aEntry.PID);
  if lProcess = 0 then
    // Access denied still proves the process exists; only a missing PID is stale.
    Exit(GetLastError = ERROR_ACCESS_DENIED);
  try
    Result := GetExitCodeProcess(lProcess, lExitCode) and (lExitCode = STILL_ACTIVE) and
      TryGetProcessStartedAtUtcMilliseconds(aEntry.PID, lStartedAt) and (lStartedAt = aEntry.StartedAt);
  finally
    CloseHandle(lProcess);
  end;
end;

function CollectTerminalAgentStates(const aTerminals: TArray<TAgentTerminal>): TArray<TAgentWindowState>;
var
  lFileName: string;
  lStale: TList<string>;
begin
  if Length(aTerminals) = 0 then
    Exit(nil);
  lStale := TList<string>.Create;
  try
    Result := ResolveAgentStates(aTerminals, SnapshotProcesses, ReadAgentStateFiles(AgentStateDir),
      IsChainEntryAlive, ClaudeSessionState, lStale);
    for lFileName in lStale do
      System.SysUtils.DeleteFile(lFileName);
  finally
    lStale.Free;
  end;
end;

function TestEntry(const aPid: Cardinal; const aStartedAt: Int64; const aName: string): TAgentChainEntry;
begin
  Result.PID := aPid;
  Result.StartedAt := aStartedAt;
  Result.Name := aName;
end;

function TestProcess(const aPid, aParentPid: Cardinal; const aName: string): TAgentProcessInfo;
begin
  Result.PID := aPid;
  Result.ParentPID := aParentPid;
  Result.Name := aName;
end;

procedure Check(const aCondition: Boolean; const aMessage: string);
begin
  if not aCondition then
    raise Exception.Create(aMessage);
end;

procedure TestCodexCompletionFallback(const aDir: string);
const
  cComplete = '{"timestamp":"2026-10-04T05:08:06.098Z","type":"event_msg","payload":' +
    '{"type":"task_complete","last_agent_message":null,"error":{"codex_error_info":"cyber_policy"}}}';
  cStarted = '{"timestamp":"2026-10-04T05:09:00.000Z","type":"event_msg","payload":{"type":"task_started"}}';
var
  lHookDir: string;
  lHome: string;
  lInput: TJSONObject;
  lJson: TJSONObject;
  lRecords: TArray<TAgentStateRecord>;
  lSessionDir: string;
  lStateFile: string;
  lTranscript: string;

  procedure CheckState(const aText: string; const aExpected: TAgentState; const aMessage: string);
  begin
    TFile.WriteAllText(lTranscript, aText, TEncoding.UTF8);
    lRecords := ReadAgentStateFiles(lHookDir);
    Check((Length(lRecords) = 1) and (lRecords[0].State = aExpected), aMessage);
  end;

begin
  lHookDir := TPath.Combine(aDir, 'completion');
  lTranscript := TPath.Combine(lHookDir, 'rollout-fallback.jsonl');
  lInput := TJSONObject.Create;
  try
    lInput.AddPair('session_id', 'fallback');
    lInput.AddPair('hook_event_name', 'PostToolUse');
    lInput.AddPair('transcript_path', lTranscript);
    Check(WriteAgentHookState('codex', lInput.ToJSON, lHookDir,
      [TestEntry(41, 800, 'codex.exe'), TestEntry(600, 600, 'alacritty.exe')]), 'Fallback hook fixture failed');
  finally
    lInput.Free;
  end;
  lStateFile := TPath.Combine(lHookDir, 'codex-fallback.json');
  lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(lStateFile)) as TJSONObject;
  try
    Check(JsonText(lJson, 'transcript_path') = lTranscript, 'The hook must retain its transcript path');
    lJson.RemovePair('updated').Free;
    lJson.AddPair('updated', '2026-10-04T05:06:33.845Z');
    TFile.WriteAllText(lStateFile, lJson.ToJSON, TEncoding.UTF8);
  finally
    lJson.Free;
  end;
  CheckState(cComplete + #10, asIdle, 'A cyber_policy completion must clear a stale working hook');
  CheckState(cComplete + #10 + cStarted + #10, asWorking, 'A subsequent turn must restore working');
  CheckState(StringReplace(cComplete, '05:08:06.098', '05:05:00.000', []) + #10,
    asWorking, 'An older completion must not override a newer hook');
  CheckState(cComplete + #10 + '{"timestamp":', asWorking, 'A partial latest record must preserve the hook');
  CheckState(cComplete + #10 + 'invalid json' + #10, asWorking, 'Malformed latest input must preserve the hook');
  CheckState(StringReplace(cComplete, 'task_complete', 'turn_aborted', []) + #10,
    asIdle, 'An aborted turn must clear a stale working hook');
  CheckState(StringOfChar('x', 300 * 1024) + #10 + cComplete + #10,
    asIdle, 'A large transcript must resolve from its bounded tail');
  CheckState(StringOfChar('x', 300 * 1024) + #$20AC +
    StringOfChar('x', 256 * 1024 - Length(cComplete) - 4) + #10 + cComplete + #10,
    asIdle, 'A tail starting inside a UTF-8 character must resolve the next complete record');
  CheckState(cComplete + #10 + '{"type":"event_msg","payload":{"type":"token_count","padding":"' +
    StringOfChar('x', 300 * 1024) + '"}}' + #10, asWorking,
    'A completion outside the read limit must preserve the hook');
  TFile.Delete(lTranscript);
  lRecords := ReadAgentStateFiles(lHookDir);
  Check((Length(lRecords) = 1) and (lRecords[0].State = asWorking), 'A missing transcript must preserve the hook');
  lHome := GetEnvironmentVariable('CODEX_HOME');
  try
    SetEnvironmentVariable('CODEX_HOME', PChar(lHookDir));
    lSessionDir := TPath.Combine(lHookDir, 'sessions\2026\10\02');
    ForceDirectories(lSessionDir);
    lTranscript := TPath.Combine(lSessionDir, 'rollout-2026-10-02T22-20-35-01a0fe46-99c0-7650-8f66-94983191d8a7.jsonl');
    lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(lStateFile)) as TJSONObject;
    try
      lJson.RemovePair('session').Free;
      lJson.AddPair('session', '01a0fe46-99c0-7650-8f66-94983191d8a7');
      lJson.RemovePair('transcript_path').Free;
      TFile.WriteAllText(lStateFile, lJson.ToJSON, TEncoding.UTF8);
    finally
      lJson.Free;
    end;
    CheckState(cComplete + #10, asIdle, 'A legacy hook must find its own session rollout');
    lJson := TJSONObject.ParseJSONValue(TFile.ReadAllText(lStateFile)) as TJSONObject;
    try
      lJson.RemovePair('transcript_path').Free;
      lJson.AddPair('transcript_path', TPath.Combine(lSessionDir, 'rollout-other-session.jsonl'));
      TFile.WriteAllText(JsonText(lJson, 'transcript_path'), cComplete + #10, TEncoding.UTF8);
      TFile.WriteAllText(lStateFile, lJson.ToJSON, TEncoding.UTF8);
    finally
      lJson.Free;
    end;
    CheckState(cComplete + #10, asWorking, 'A different session path must not override the hook');
  finally
    if lHome = '' then
      SetEnvironmentVariable('CODEX_HOME', nil)
    else
      SetEnvironmentVariable('CODEX_HOME', PChar(lHome));
  end;
end;

function RunAgentStateSelfTests(const aArg: string): Integer;
var
  lChain: TArray<TAgentChainEntry>;
  lDir: string;
  lEnds: Boolean;
  lRecords: TArray<TAgentStateRecord>;
  lStale: TList<string>;
  lState: TAgentState;
  lProcess: TAgentProcessInfo;
  lStates: TArray<TAgentWindowState>;
  lTerminals: TArray<TAgentTerminal>;
  i: Integer;
begin
  // Read-only diagnostics: what every running terminal host resolves to right now.
  if SameText(aArg, cAgentStateDumpArg) then
  begin
    for lProcess in SnapshotProcesses do
      if SameText(lProcess.Name, 'alacritty.exe') or SameText(lProcess.Name, 'WindowsTerminal.exe') then
      begin
        SetLength(lTerminals, Length(lTerminals) + 1);
        lTerminals[High(lTerminals)].PID := lProcess.PID;
        if not TryGetProcessStartedAtUtcMilliseconds(lProcess.PID, lTerminals[High(lTerminals)].StartedAt) then
          lTerminals[High(lTerminals)].StartedAt := 0;
      end;
    lStates := CollectTerminalAgentStates(lTerminals);
    for i := 0 to High(lStates) do
      Writeln(lTerminals[i].PID, ' ', cStateNames[lStates[i].State], ' authoritative=',
        BoolToStr(lStates[i].Authoritative, True));
    Exit(0);
  end;
  if not SameText(aArg, cAgentStateSelfTestArg) then
    Exit(-1);
  Result := 0;
  lDir := TPath.Combine(TPath.GetTempPath, 'ActiveAppView-AgentState-' + IntToStr(GetCurrentProcessId));
  lStale := TList<string>.Create;
  try
    try
      Check(HookEventToAgentState('UserPromptSubmit', '', '', lState, lEnds) and (lState = asWorking),
        'UserPromptSubmit must mean working');
      Check(HookEventToAgentState('PermissionRequest', '', '', lState, lEnds) and (lState = asActionRequired),
        'PermissionRequest must mean action required');
      Check(HookEventToAgentState('Notification', 'permission_prompt', '', lState, lEnds) and
        (lState = asActionRequired), 'permission_prompt must mean action required');
      Check(HookEventToAgentState('Stop', '', '', lState, lEnds) and (lState = asIdle), 'Stop must mean idle');
      Check(HookEventToAgentState('Interrupt', '', '', lState, lEnds) and (lState = asIdle),
        'Codex Interrupt must mean idle');
      Check(not HookEventToAgentState('SessionStart', '', 'compact', lState, lEnds),
        'SessionStart after compaction must not change the state');
      Check(not HookEventToAgentState('PreToolUse', '', '', lState, lEnds), 'PreToolUse must be ignored');
      Check(not HookEventToAgentState('Notification', 'auth_success', '', lState, lEnds),
        'Unrelated notifications must be ignored');
      Check(HookEventToAgentState('SessionEnd', '', '', lState, lEnds) and lEnds and (lState = asNone),
        'SessionEnd must end the session without reporting an active state');

      // Windows Claude: hook <- bash <- claude.exe <- pwsh <- alacritty (terminal 500).
      lChain := [TestEntry(10, 900, 'bash.exe'), TestEntry(20, 800, 'claude.exe'), TestEntry(30, 700, 'pwsh.exe'),
        TestEntry(500, 600, 'alacritty.exe')];
      Check(SelectAnchor(lChain).PID = 20, 'The harness process must anchor a Windows session');
      Check(SelectAnchor([TestEntry(11, 900, 'wsl.exe'), TestEntry(12, 800, 'wsl.exe'),
        TestEntry(13, 700, 'pwsh.exe')]).PID = 12, 'The outermost wsl.exe must anchor a WSL session');
      Check(WriteAgentHookState('claude', '{"session_id":"s-1","hook_event_name":"PermissionRequest","cwd":"C:\\x"}',
        lDir, lChain), 'Writing the state file failed');
      Check(WriteAgentHookState('codex', '{"session_id":"s/2","hook_event_name":"Stop"}', lDir,
        [TestEntry(40, 900, 'cmd.exe'), TestEntry(41, 800, 'codex.exe'), TestEntry(600, 600, 'alacritty.exe')]),
        'Writing the Codex state file failed');
      Check(not WriteAgentHookState('claude', 'not json', lDir, lChain), 'Invalid input must be rejected');
      lRecords := ReadAgentStateFiles(lDir);
      Check(Length(lRecords) = 2, 'Expected two state files, got ' + IntToStr(Length(lRecords)));

      Check((ClaudeStatusToAgentState('busy') = asWorking) and
        (ClaudeStatusToAgentState('waiting') = asActionRequired) and (ClaudeStatusToAgentState('idle') = asIdle) and
        (ClaudeStatusToAgentState('shell') = asIdle) and (ClaudeStatusToAgentState('') = asNone),
        'Claude session status mapping is wrong');
      SetLength(lTerminals, 5);
      lTerminals[0].PID := 500;
      lTerminals[0].StartedAt := 600;
      lTerminals[1].PID := 600;
      lTerminals[1].StartedAt := 600;
      lTerminals[2].PID := 700;
      lTerminals[2].StartedAt := 1;
      lTerminals[3].PID := 800;
      lTerminals[3].StartedAt := 1;
      lTerminals[4].PID := 900;
      lTerminals[4].StartedAt := 1;
      lStates := ResolveAgentStates(lTerminals,
        [TestProcess(500, 1, 'alacritty.exe'), TestProcess(30, 500, 'pwsh.exe'), TestProcess(20, 30, 'claude.exe'),
         TestProcess(700, 1, 'alacritty.exe'), TestProcess(71, 700, 'pwsh.exe'), TestProcess(72, 71, 'codex.exe'),
         TestProcess(800, 1, 'alacritty.exe'), TestProcess(81, 800, 'pwsh.exe'),
         TestProcess(900, 1, 'alacritty.exe'), TestProcess(91, 900, 'pwsh.exe'),
         TestProcess(92, 91, 'claude.exe.old.1790372997736.91680')],
        lRecords,
        function(const aEntry: TAgentChainEntry): Boolean
        begin
          Result := aEntry.PID <> 41;
        end,
        function(const aPid: Cardinal; out aState: TAgentState): Boolean
        begin
          aState := asIdle;
          Result := aPid = 92;
        end, lStale);
      Check((lStates[0].State = asActionRequired) and not lStates[0].Authoritative,
        'Hook state must win over the process tree');
      Check(lStates[1].State = asNone, 'A dead harness must not report a state');
      Check((lStale.Count = 1) and ContainsText(lStale[0], 'codex-s2.json'), 'The dead Codex file must be stale');
      Check(lStates[2].State = asAgent, 'A harness below a terminal must mark it as an agent');
      Check(lStates[3].State = asNone, 'A plain shell must stay a non-agent');
      Check((lStates[4].State = asIdle) and lStates[4].Authoritative,
        'A renamed Claude binary must be found, and its session registry must be authoritative');

      Check(WriteAgentHookState('claude', '{"session_id":"s-1","hook_event_name":"SessionEnd"}', lDir, lChain) and
        (Length(ReadAgentStateFiles(lDir)) = 1), 'SessionEnd must remove the state file');
      TestCodexCompletionFallback(lDir);
      Writeln('AGENT STATE PASS');
    except
      on lException: Exception do
      begin
        Writeln('SELFTEST FAILED: ' + lException.Message);
        Result := 1;
      end;
    end;
  finally
    lStale.Free;
    if TDirectory.Exists(lDir) then
      TDirectory.Delete(lDir, True);
  end;
end;

end.

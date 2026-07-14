unit ActiveAppView.RenameJournal.SelfTests;

interface

function RunRenameJournalSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.Diagnostics, System.IniFiles, System.IOUtils, System.SyncObjs, System.SysUtils,
  Winapi.Windows,
  Vcl.Forms,
  AutoFree,
  FireDAC.Comp.Client, FireDAC.Comp.Script, FireDAC.Comp.ScriptCommands,
  FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.Async, FireDAC.Stan.Def,
  FireDAC.VCLUI.Wait,
  ActiveAppView.RenameJournal, CancelToken;

const
  cMigrationDescriptions: array[0..3] of string = (
    'Initial schema',
    'Capture codec modes',
    'Focus page URL',
    'Window rename events');
  cMigrationFileNames: array[0..3] of string = (
    '001_initial.sql',
    '002_capture_codec_modes.sql',
    '003_focus_page_url.sql',
    '004_window_rename_events.sql');
  cRenameJournalWriteSelfTestArg = '--self-test-rename-journal';

procedure ConfigureTestConnection(const aDatabaseFileName: string; const aConnection: TFDConnection);
begin
  aConnection.LoginPrompt := False;
  aConnection.Params.Values['DriverID'] := 'SQLite';
  aConnection.Params.Values['Database'] := aDatabaseFileName;
  aConnection.Params.Values['OpenMode'] := 'CreateUTF8';
end;

procedure ApplyCanonicalShadowJournalMigration(const aConnection: TFDConnection;
  const aScript: TFDScript; const aMigrationDirectory: string;
  const aMigrationIndex: Integer);
var
  lMigrationFileName: string;
begin
  lMigrationFileName := TPath.Combine(
    aMigrationDirectory,
    cMigrationFileNames[aMigrationIndex]);
  if not TFile.Exists(lMigrationFileName) then
    raise EFileNotFoundException.Create(
      'Migration file does not exist: ' + lMigrationFileName);

  aScript.SQLScripts.Clear;
  aScript.SQLScripts.Add.SQL.LoadFromFile(lMigrationFileName, TEncoding.UTF8);
  aScript.ValidateAll;
  aConnection.StartTransaction;
  try
    aScript.ExecuteAll;
    aConnection.ExecSQL(
      'INSERT INTO schema_version (version, description, applied_at) VALUES (?, ?, ?);',
      [aMigrationIndex + 1, cMigrationDescriptions[aMigrationIndex], 0]);
    aConnection.Commit;
  except
    if aConnection.InTransaction then
      aConnection.Rollback;
    raise;
  end;
end;

function ApplyCanonicalShadowJournalMigrations(const aConnection: TFDConnection;
  const aMigrationDirectory: string; const aFirstVersion: Integer;
  const aLastVersion: Integer; out aErrorMessage: string): Boolean;
var
  g: TGarbos;
  i: Integer;
  lScript: TFDScript;
begin
  g := Default(TGarbos);
  aErrorMessage := '';
  Result := False;
  try
    try
      if not TDirectory.Exists(aMigrationDirectory) then
      begin
        aErrorMessage := 'Migration directory does not exist: ' + aMigrationDirectory;
        Exit;
      end;

      if (aFirstVersion < 1) or (aLastVersion > Length(cMigrationFileNames)) or
        (aFirstVersion > aLastVersion) then
      begin
        aErrorMessage := 'Invalid canonical migration range';
        Exit;
      end;

      aConnection.Connected := True;
      aConnection.ExecSQL(
        'CREATE TABLE IF NOT EXISTS schema_version (' +
        'version INTEGER PRIMARY KEY, description TEXT NOT NULL, applied_at INTEGER NOT NULL);');
      GC(lScript, TFDScript.Create(nil), g);
      lScript.Connection := aConnection;
      for i := aFirstVersion - 1 to aLastVersion - 1 do
        ApplyCanonicalShadowJournalMigration(
          aConnection,
          lScript,
          aMigrationDirectory,
          i);
      Result := True;
    except
      on lException: Exception do
        aErrorMessage := lException.ClassName + ': ' + lException.Message;
    end;
  finally
    g.Clear;
  end;
end;

function FindCanonicalMigrationDirectory: string;
var
  lProjectsDirectory: string;
begin
  Result := Trim(GetEnvironmentVariable('SHADOW_JOURNAL_MIGRATIONS_DIR'));
  if Result <> '' then
    Exit;

  lProjectsDirectory := TPath.GetDirectoryName(TPath.GetDirectoryName(ParamStr(0)));
  Result := TPath.Combine(
    lProjectsDirectory,
    'MaxLogic\PawelsPersonalShadowJourney\migrations');
end;

function WaitForWriterProgress(const aWriter: TRenameJournalWriter;
  const aMinimumDequeued: Int64; const aMinimumDropped: Int64;
  const aMinimumPersisted: Int64): Boolean;
var
  lDiagnostics: TRenameJournalDiagnostics;
  lStopwatch: TStopwatch;
begin
  lStopwatch := TStopwatch.StartNew;
  repeat
    lDiagnostics := aWriter.GetDiagnostics;
    if (lDiagnostics.Dequeued >= aMinimumDequeued) and
      (lDiagnostics.Dropped >= aMinimumDropped) and
      (lDiagnostics.Persisted >= aMinimumPersisted) then
      Exit(True);
    Sleep(1);
  until lStopwatch.ElapsedMilliseconds >= 3000;
  Result := False;
end;

function WriterDiagnosticsMatch(const aWriter: TRenameJournalWriter;
  const aExpectedAccepted: Int64; const aExpectedDropped: Int64;
  const aExpectedPending: Integer; const aExpectedPersisted: Int64;
  out aErrorMessage: string): Boolean;
var
  lDiagnostics: TRenameJournalDiagnostics;
begin
  lDiagnostics := aWriter.GetDiagnostics;
  Result := (lDiagnostics.Accepted = aExpectedAccepted) and
    (lDiagnostics.Dropped = aExpectedDropped) and
    (lDiagnostics.Pending = aExpectedPending) and
    (lDiagnostics.Persisted = aExpectedPersisted);
  if not Result then
    aErrorMessage := Format(
      'accepted=%d dropped=%d pending=%d persisted=%d',
      [lDiagnostics.Accepted, lDiagnostics.Dropped, lDiagnostics.Pending,
      lDiagnostics.Persisted]);
end;

function ConcurrentStopJoins(const aWriter: TRenameJournalWriter; const aWnd: HWND;
  const aProcessId: Cardinal; const aRenamedAt: Int64; const aCaption: string;
  out aErrorMessage: string): Boolean;
var
  g: TGarbos;
  lCompleted: Integer;
  lQueueResult: TRenameJournalEnqueueResult;
  lStopThread: TThread;
  lStopwatch: TStopwatch;
begin
  g := Default(TGarbos);
  Result := False;
  aErrorMessage := '';
  lCompleted := 0;
  try
    lStopThread := TThread.CreateAnonymousThread(
      procedure
      begin
        aWriter.StopAndWait;
        TInterlocked.Exchange(lCompleted, 1);
      end);
    lStopThread.FreeOnTerminate := False;
    GC(lStopThread, g);
    lStopThread.Start;
    lStopwatch := TStopwatch.StartNew;
    repeat
      lQueueResult := aWriter.Enqueue(aWnd, aProcessId, aRenamedAt, aCaption);
      if lQueueResult = rjerStopped then
        Break;
      Sleep(0);
    until lStopwatch.ElapsedMilliseconds >= 1000;
    if lQueueResult <> rjerStopped then
    begin
      aErrorMessage := 'concurrent shutdown did not stop the producer';
      Exit;
    end;

    aWriter.StopAndWait;
    if TInterlocked.CompareExchange(lCompleted, 0, 0) = 0 then
    begin
      aErrorMessage := 'concurrent StopAndWait returned before the worker joined';
      Exit;
    end;
    lStopThread.WaitFor;
    Result := True;
  finally
    g.Clear;
  end;
end;

function RunRenameJournalWriteSelfTest: Integer;
const
  cExpectedCaption = 'Żółć 東京';
  cExpectedHwnd: UInt64 = $0000000100000001;
  cExpectedPid = 4321;
  cExpectedRenamedAt = 1783900800123;
var
  g: TGarbos;
  i: Integer;
  lCancelToken: iCancelToken;
  lConfig: TRenameJournalConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lErrorMessage: string;
  lFifoWriter: TRenameJournalWriter;
  lIniFile: TMemIniFile;
  lLockedWriter: TRenameJournalWriter;
  lOverflowWriter: TRenameJournalWriter;
  lQuery: TFDQuery;
  lQueueResult: TRenameJournalEnqueueResult;
  lRoot: string;
  lSettingsFileName: string;
  lStopwatch: TStopwatch;
  lUnavailableDatabaseFileName: string;
  lWriter: TRenameJournalWriter;
begin
  g := Default(TGarbos);
  Result := 1;
  Application.Initialize;
  lRoot := TPath.Combine(TPath.GetTempPath, 'ActiveAppView-RenameJournal-' + UIntToStr(GetTickCount64));
  TDirectory.CreateDirectory(lRoot);
  lDatabaseFileName := TPath.Combine(lRoot, 'shadow_journal.db');
  lSettingsFileName := TPath.Combine(lRoot, 'settings.ini');
  lUnavailableDatabaseFileName := TPath.Combine(lRoot, 'unavailable.db');
  try
    if not RenameJournalWorkerConstructionFailureIsSafeForSelfTest then
    begin
      Writeln('SELFTEST FAILED: rename journal worker construction failure cleanup is unsafe');
      Exit;
    end;

    GC(lIniFile, TMemIniFile.Create(lSettingsFileName, TEncoding.UTF8, False), g);
    lIniFile.WriteBool('save-renames-to-journal', 'enabled', True);
    lIniFile.WriteString('save-renames-to-journal', 'db-file', lDatabaseFileName);
    lConfig := LoadRenameJournalConfig(lIniFile);
    if not lConfig.Enabled then
    begin
      Writeln('SELFTEST FAILED: configured rename journal should be enabled');
      Exit;
    end;
    if not SameText(lConfig.DatabaseFileName, lDatabaseFileName) then
    begin
      Writeln('SELFTEST FAILED: configured rename journal database path mismatch');
      Exit;
    end;

    lIniFile.EraseSection('save-renames-to-journal');
    lConfig := LoadRenameJournalConfig(lIniFile);
    if lConfig.Enabled then
    begin
      Writeln('SELFTEST FAILED: rename journal must default to disabled');
      Exit;
    end;
    if lConfig.DatabaseFileName <> '' then
    begin
      Writeln('SELFTEST FAILED: rename journal database path must default to empty');
      Exit;
    end;

    lConfig.Enabled := False;
    lConfig.DatabaseFileName := lUnavailableDatabaseFileName;
    if TryRecordWindowRename(
      lConfig,
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt,
      cExpectedCaption,
      lErrorMessage) <> rjwrDisabled then
    begin
      Writeln('SELFTEST FAILED: disabled rename journal should not write');
      Exit;
    end;
    if TFile.Exists(lUnavailableDatabaseFileName) then
    begin
      Writeln('SELFTEST FAILED: disabled rename journal created a database');
      Exit;
    end;

    lConfig.Enabled := True;
    if TryRecordWindowRename(
      lConfig,
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt,
      cExpectedCaption,
      lErrorMessage) <> rjwrFailed then
    begin
      Writeln('SELFTEST FAILED: missing rename journal database should fail');
      Exit;
    end;
    if (lErrorMessage = '') or TFile.Exists(lUnavailableDatabaseFileName) then
    begin
      Writeln('SELFTEST FAILED: missing rename journal database failure was unsafe');
      Exit;
    end;

    GC(lConnection, TFDConnection.Create(nil), g);
    lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
    lDriverLink.DriverID := 'SQLite';
    ConfigureTestConnection(lDatabaseFileName, lConnection);
    lConnection.Connected := True;
    lConnection.Connected := False;

    lConfig.DatabaseFileName := lDatabaseFileName;
    if TryRecordWindowRename(
      lConfig,
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt,
      cExpectedCaption,
      lErrorMessage) <> rjwrFailed then
    begin
      Writeln('SELFTEST FAILED: rename journal without migration should fail');
      Exit;
    end;

    if not ApplyCanonicalShadowJournalMigrations(
      lConnection,
      FindCanonicalMigrationDirectory,
      1,
      3,
      lErrorMessage) then
    begin
      Writeln(
        'SELFTEST FAILED: canonical Shadow Journal migrations 001-003 were not applied: ' +
        lErrorMessage);
      Exit;
    end;
    lConnection.Connected := False;

    lCancelToken := TCancelToken.Create;
    GC(lWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    lQueueResult := lWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt - 1,
      cExpectedCaption + ' before migration');
    if lQueueResult <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: pre-migration rename event was not accepted');
      Exit;
    end;
    if not WaitForWriterProgress(lWriter, 1, 1, 0) then
    begin
      Writeln('SELFTEST FAILED: writer did not report the pre-migration failure');
      Exit;
    end;
    if not TFile.Exists(ChangeFileExt(lDatabaseFileName, '.rename-journal.log')) or
      (Pos(
        'window_rename_events',
        TFile.ReadAllText(
          ChangeFileExt(lDatabaseFileName, '.rename-journal.log'),
          TEncoding.UTF8)) = 0) then
    begin
      Writeln('SELFTEST FAILED: database failure was not written to the diagnostic log');
      Exit;
    end;

    if not ApplyCanonicalShadowJournalMigrations(
      lConnection,
      FindCanonicalMigrationDirectory,
      4,
      4,
      lErrorMessage) then
    begin
      Writeln(
        'SELFTEST FAILED: canonical Shadow Journal migration 004 was not applied: ' +
        lErrorMessage);
      Exit;
    end;
    lConnection.Connected := False;

    lQueueResult := lWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt,
      cExpectedCaption);
    if lQueueResult <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: post-migration rename event was not accepted');
      Exit;
    end;
    lWriter.StopAndWait;
    if not WriterDiagnosticsMatch(lWriter, 2, 1, 0, 1, lErrorMessage) then
    begin
      Writeln('SELFTEST FAILED: schema-recovery diagnostics ' + lErrorMessage);
      Exit;
    end;

    lConnection.Connected := True;
    GC(lQuery, TFDQuery.Create(nil), g);
    lQuery.Connection := lConnection;
    lQuery.SQL.Text :=
      'SELECT renamed_at, hwnd, pid, new_caption, ' +
      '(SELECT COUNT(*) FROM window_rename_events) AS event_count ' +
      'FROM window_rename_events ORDER BY id DESC LIMIT 1;';
    lQuery.Open;
    if lQuery.FieldByName('event_count').AsInteger <> 1 then
    begin
      Writeln('SELFTEST FAILED: canonical writer path did not persist exactly one row');
      Exit;
    end;
    if lQuery.FieldByName('renamed_at').AsLargeInt <> cExpectedRenamedAt then
    begin
      Writeln(Format(
        'SELFTEST FAILED: rename journal timestamp expected=%d actual=%d',
        [cExpectedRenamedAt, lQuery.FieldByName('renamed_at').AsLargeInt]));
      Exit;
    end;
    if lQuery.FieldByName('hwnd').AsLargeInt <> Int64(cExpectedHwnd) then
    begin
      Writeln('SELFTEST FAILED: rename journal HWND mismatch');
      Exit;
    end;
    if lQuery.FieldByName('pid').AsLargeInt <> cExpectedPid then
    begin
      Writeln('SELFTEST FAILED: rename journal PID mismatch');
      Exit;
    end;
    if lQuery.FieldByName('new_caption').AsWideString <> cExpectedCaption then
    begin
      Writeln('SELFTEST FAILED: rename journal Unicode caption mismatch');
      Exit;
    end;

    lQuery.Close;
    lConnection.ExecSQL('DELETE FROM window_rename_events;');
    lConnection.Connected := False;
    lCancelToken := TCancelToken.Create;
    GC(lFifoWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    for i := 1 to 3 do
    begin
      if lFifoWriter.Enqueue(
        HWND(NativeUInt(cExpectedHwnd)),
        cExpectedPid,
        cExpectedRenamedAt + 10 + i,
        Format('FIFO %d', [i])) <> rjerQueued then
      begin
        Writeln('SELFTEST FAILED: rename journal FIFO event was not queued');
        Exit;
      end;
    end;
    lFifoWriter.StopAndWait;

    lConnection.Connected := True;
    lQuery.SQL.Text := 'SELECT new_caption FROM window_rename_events ORDER BY id;';
    lQuery.Open;
    for i := 1 to 3 do
    begin
      if lQuery.Eof or (lQuery.FieldByName('new_caption').AsWideString <> Format('FIFO %d', [i])) then
      begin
        Writeln('SELFTEST FAILED: rename journal events were not persisted FIFO');
        Exit;
      end;
      lQuery.Next;
    end;
    if not lQuery.Eof then
    begin
      Writeln('SELFTEST FAILED: rename journal FIFO persisted an unexpected extra row');
      Exit;
    end;

    lQuery.Close;
    lConnection.ExecSQL('DELETE FROM window_rename_events;');
    lConnection.StartTransaction;
    lConnection.ExecSQL(
      'UPDATE schema_version SET description = description WHERE version = 4;');
    lCancelToken := TCancelToken.Create;
    GC(lLockedWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    if lLockedWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 2,
      cExpectedCaption + ' locked') <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: locked rename journal event was not queued fail-open');
      Exit;
    end;
    if not WaitForWriterProgress(lLockedWriter, 1, 1, 0) then
    begin
      Writeln('SELFTEST FAILED: locked database failure was not observed');
      Exit;
    end;
    lConnection.Rollback;
    lConnection.Connected := False;
    if lLockedWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 3,
      cExpectedCaption + ' recovered') <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: recovered rename journal event was not queued');
      Exit;
    end;
    lLockedWriter.StopAndWait;
    if not WriterDiagnosticsMatch(lLockedWriter, 2, 1, 0, 1, lErrorMessage) then
    begin
      Writeln('SELFTEST FAILED: locked recovery diagnostics ' + lErrorMessage);
      Exit;
    end;
    lConnection.Connected := True;
    lQuery.SQL.Text :=
      'SELECT COUNT(*) AS event_count, MIN(new_caption) AS new_caption ' +
      'FROM window_rename_events;';
    lQuery.Open;
    if (lQuery.FieldByName('event_count').AsInteger <> 1) or
      (lQuery.FieldByName('new_caption').AsWideString <> cExpectedCaption + ' recovered') then
    begin
      Writeln('SELFTEST FAILED: same writer did not recover after the database lock');
      Exit;
    end;

    lQuery.Close;
    lConnection.ExecSQL('DELETE FROM window_rename_events;');
    lConnection.StartTransaction;
    lConnection.ExecSQL(
      'UPDATE schema_version SET description = description WHERE version = 4;');
    lCancelToken := TCancelToken.Create;
    GC(lOverflowWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    if lOverflowWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 100,
      cExpectedCaption + ' in flight') <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: in-flight overflow setup event was not queued');
      Exit;
    end;
    if not WaitForWriterProgress(lOverflowWriter, 1, 0, 0) then
    begin
      Writeln('SELFTEST FAILED: overflow setup event was not dequeued');
      Exit;
    end;

    lStopwatch := TStopwatch.StartNew;
    for i := 1 to 64 do
    begin
      lQueueResult := lOverflowWriter.Enqueue(
        HWND(NativeUInt(cExpectedHwnd)),
        cExpectedPid,
        cExpectedRenamedAt + 100 + i,
        cExpectedCaption + ' overflow');
      if lQueueResult <> rjerQueued then
      begin
        Writeln(Format(
          'SELFTEST FAILED: bounded queue rejected capacity slot %d',
          [i]));
        Exit;
      end;
    end;
    lQueueResult := lOverflowWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 1000,
      cExpectedCaption + ' rejected');
    lStopwatch.Stop;
    if lQueueResult <> rjerFull then
    begin
      Writeln('SELFTEST FAILED: bounded queue accepted event 65');
      Exit;
    end;
    if lStopwatch.ElapsedMilliseconds >= 1000 then
    begin
      Writeln('SELFTEST FAILED: rename journal queue overflow blocked the producer');
      Exit;
    end;
    if not ConcurrentStopJoins(
      lOverflowWriter,
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 1001,
      cExpectedCaption + ' concurrent stop',
      lErrorMessage) then
    begin
      Writeln('SELFTEST FAILED: ' + lErrorMessage);
      Exit;
    end;
    lConnection.Rollback;
    if not WriterDiagnosticsMatch(lOverflowWriter, 65, 65, 0, 0, lErrorMessage) then
    begin
      Writeln('SELFTEST FAILED: overflow diagnostics ' + lErrorMessage);
      Exit;
    end;
    if Pos(
      'queue overflow',
      TFile.ReadAllText(
        ChangeFileExt(lDatabaseFileName, '.rename-journal.log'),
        TEncoding.UTF8)) = 0 then
    begin
      Writeln('SELFTEST FAILED: queue overflow was not written to the diagnostic log');
      Exit;
    end;
    if lOverflowWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 1002,
      cExpectedCaption + ' after stop') <> rjerStopped then
    begin
      Writeln('SELFTEST FAILED: stopped writer accepted an event');
      Exit;
    end;
    Result := 0;
  finally
    g.Clear;
    if TDirectory.Exists(lRoot) then
      TDirectory.Delete(lRoot, True);
  end;
end;

function RunRenameJournalSelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cRenameJournalWriteSelfTestArg) then
    Result := RunRenameJournalWriteSelfTest;
end;

end.

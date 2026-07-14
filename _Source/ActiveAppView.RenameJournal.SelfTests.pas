unit ActiveAppView.RenameJournal.SelfTests;

interface

function RunRenameJournalSelfTests(const aArg: string): Integer;

implementation

uses
  System.Diagnostics, System.IniFiles, System.IOUtils, System.SysUtils,
  Winapi.Windows,
  Vcl.Forms,
  AutoFree,
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.Async, FireDAC.Stan.Def,
  FireDAC.VCLUI.Wait,
  ActiveAppView.RenameJournal, CancelToken;

const
  cRenameJournalWriteSelfTestArg = '--self-test-rename-journal';

procedure ConfigureTestConnection(const aDatabaseFileName: string; const aConnection: TFDConnection);
begin
  aConnection.LoginPrompt := False;
  aConnection.Params.Values['DriverID'] := 'SQLite';
  aConnection.Params.Values['Database'] := aDatabaseFileName;
  aConnection.Params.Values['OpenMode'] := 'CreateUTF8';
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
  lOverflowCount: Integer;
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

    lConnection.Connected := True;
    lConnection.ExecSQL(
      'CREATE TABLE window_rename_events (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, renamed_at BIGINT NOT NULL, hwnd BIGINT NOT NULL, ' +
      'pid BIGINT NOT NULL, new_caption TEXT NOT NULL);'
    );
    lConnection.Connected := False;

    if TryRecordWindowRename(
      lConfig,
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt,
      cExpectedCaption,
      lErrorMessage) <> rjwrSaved then
    begin
      Writeln('SELFTEST FAILED: rename journal write failed: ' + lErrorMessage);
      Exit;
    end;

    lConnection.Connected := True;
    GC(lQuery, TFDQuery.Create(nil), g);
    lQuery.Connection := lConnection;
    lQuery.SQL.Text :=
      'SELECT renamed_at, hwnd, pid, new_caption FROM window_rename_events ORDER BY id DESC LIMIT 1;';
    lQuery.Open;
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
    GC(lWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    if lWriter.Enqueue(
      HWND(NativeUInt(cExpectedHwnd)),
      cExpectedPid,
      cExpectedRenamedAt + 1,
      cExpectedCaption + ' queued') <> rjerQueued then
    begin
      Writeln('SELFTEST FAILED: rename journal writer did not queue the event');
      Exit;
    end;
    lWriter.StopAndWait;

    lConnection.Connected := True;
    lQuery.SQL.Text :=
      'SELECT COUNT(*) AS event_count, MIN(renamed_at) AS renamed_at, MIN(hwnd) AS hwnd, ' +
      'MIN(pid) AS pid, MIN(new_caption) AS new_caption FROM window_rename_events;';
    lQuery.Open;
    if lQuery.FieldByName('event_count').AsInteger <> 1 then
    begin
      Writeln('SELFTEST FAILED: rename journal writer did not persist exactly one row');
      Exit;
    end;
    if lQuery.FieldByName('renamed_at').AsLargeInt <> cExpectedRenamedAt + 1 then
    begin
      Writeln('SELFTEST FAILED: rename journal writer timestamp mismatch');
      Exit;
    end;
    if lQuery.FieldByName('hwnd').AsLargeInt <> Int64(cExpectedHwnd) then
    begin
      Writeln('SELFTEST FAILED: rename journal writer truncated the 64-bit HWND');
      Exit;
    end;
    if lQuery.FieldByName('pid').AsLargeInt <> cExpectedPid then
    begin
      Writeln('SELFTEST FAILED: rename journal writer PID mismatch');
      Exit;
    end;
    if lQuery.FieldByName('new_caption').AsWideString <> cExpectedCaption + ' queued' then
    begin
      Writeln('SELFTEST FAILED: rename journal writer Unicode caption mismatch');
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
    lConnection.ExecSQL('BEGIN EXCLUSIVE;');
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
    lLockedWriter.StopAndWait;
    lConnection.ExecSQL('ROLLBACK;');
    lQuery.SQL.Text := 'SELECT COUNT(*) AS event_count FROM window_rename_events;';
    lQuery.Open;
    if lQuery.FieldByName('event_count').AsInteger <> 0 then
    begin
      Writeln('SELFTEST FAILED: locked rename journal write changed persisted rows');
      Exit;
    end;

    lQuery.Close;
    lConnection.ExecSQL('BEGIN EXCLUSIVE;');
    lCancelToken := TCancelToken.Create;
    GC(lOverflowWriter, TRenameJournalWriter.Create(lConfig, lCancelToken), g);
    lOverflowCount := 0;
    lStopwatch := TStopwatch.StartNew;
    for i := 1 to 66 do
    begin
      lQueueResult := lOverflowWriter.Enqueue(
        HWND(NativeUInt(cExpectedHwnd)),
        cExpectedPid,
        cExpectedRenamedAt + 100 + i,
        cExpectedCaption + ' overflow');
      if lQueueResult = rjerFull then
        Inc(lOverflowCount)
      else if lQueueResult <> rjerQueued then
      begin
        Writeln('SELFTEST FAILED: rename journal queue stopped before overflow');
        Exit;
      end;
    end;
    lStopwatch.Stop;
    if lOverflowCount = 0 then
    begin
      Writeln('SELFTEST FAILED: rename journal queue did not enforce its 64-event bound');
      Exit;
    end;
    if lStopwatch.ElapsedMilliseconds >= 1000 then
    begin
      Writeln('SELFTEST FAILED: rename journal queue overflow blocked the producer');
      Exit;
    end;
    lOverflowWriter.StopAndWait;
    lConnection.ExecSQL('ROLLBACK;');
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

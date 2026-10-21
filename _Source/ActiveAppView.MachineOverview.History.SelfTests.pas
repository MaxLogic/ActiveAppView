unit ActiveAppView.MachineOverview.History.SelfTests;

interface

function RunMachineOverviewHistorySelfTests(const aArg: string): Integer;

implementation

uses
  System.DateUtils, System.IOUtils, System.Math, System.StrUtils,
  System.SysUtils,
  Winapi.Windows,
  AutoFree, FireDAC.Comp.Client, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper.Stat,
  FireDAC.Stan.Async, FireDAC.Stan.Def,
  ActiveAppView.MachineOverview.Evidence,
  ActiveAppView.MachineOverview.History,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Providers,
  ActiveAppView.MachineOverview.Settings,
  ActiveAppView.MachineOverview.Types;

const
  cMachineOverviewHistorySelfTestArg = '--self-test-machine-overview-history';
  cMachineOverviewSQLiteBindingSelfTestArg =
    '--self-test-machine-overview-sqlite-binding';

function TryLoadedSQLiteModulePath(out aPath: string): Boolean;
var
  lLength: Cardinal;
  lModule: HMODULE;
  lPathBuffer: array[0..MAX_PATH - 1] of Char;
begin
  aPath := '';
  lModule := GetModuleHandle(PChar('sqlite3.dll'));
  lLength := 0;
  if lModule <> 0 then
    lLength := GetModuleFileName(lModule, lPathBuffer, Length(lPathBuffer));
  Result := lLength <> 0;
  if Result then
    SetString(aPath, lPathBuffer, lLength);
end;

function RunSQLiteBindingSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lError: string;
  lExpectedPath: string;
  lIncidents: TArray<TMachineOverviewIncident>;
  lLoadedPath: string;
  lPackagedRuntimeExists: Boolean;
  lPipeline: TMachineOverviewPipeline;
  lQueryDatabaseFileName: string;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lExpectedPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'sqlite3.dll');
  lPackagedRuntimeExists := TFile.Exists(lExpectedPath);
  lDatabaseFileName := TPath.Combine(TPath.GetTempPath, Format(
    'ActiveAppView-MachineOverview-sqlite-binding-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lQueryDatabaseFileName := lDatabaseFileName + '.query.db';
  lPipeline := nil;
  lService := nil;
  try
    if not lPackagedRuntimeExists then
    begin
      TFile.WriteAllText(lQueryDatabaseFileName, 'not a SQLite database',
        TEncoding.ASCII);
      if TryLoadMachineOverviewIncidents(lQueryDatabaseFileName, 0, 10,
        lIncidents, lError) or lError.IsEmpty then
      begin
        Writeln('SELFTEST FAILED: invalid incident database did not fail explicitly');
        Exit;
      end;
      if TryLoadedSQLiteModulePath(lLoadedPath) then
      begin
        Writeln(Format(
          'SELFTEST FAILED: incident query loaded fallback SQLite runtime %s',
          [lLoadedPath]));
        Exit;
      end;
    end;
    GC(lPipeline, TMachineOverviewPipeline.Create(16, 16), g);
    lConfig := TMachineOverviewHistoryConfig.FromSettings(
      TMachineOverviewSettings.Defaults, lDatabaseFileName);
    GC(lService, TMachineOverviewHistoryService.Create(lPipeline, lConfig), g);
    lService.Start;
    if not lService.WaitUntilInitialized(5000) then
    begin
      Writeln('SELFTEST FAILED: SQLite binding initialization timed out');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if lPackagedRuntimeExists then
    begin
      if (not lDiagnostics.Available) or
        (not TryLoadedSQLiteModulePath(lLoadedPath)) or
        (not SameFileName(lLoadedPath, lExpectedPath)) then
      begin
        Writeln(Format(
          'SELFTEST FAILED: history SQLite runtime path expected=%s actual=%s error=%s',
          [lExpectedPath, lLoadedPath, lDiagnostics.LastError]));
        Exit;
      end;
    end else
    begin
      if lDiagnostics.Available or lDiagnostics.LastError.IsEmpty then
      begin
        Writeln('SELFTEST FAILED: missing packaged SQLite runtime did not degrade history');
        Exit;
      end;
      if TryLoadedSQLiteModulePath(lLoadedPath) then
      begin
        Writeln(Format(
          'SELFTEST FAILED: history loaded fallback SQLite runtime %s',
          [lLoadedPath]));
        Exit;
      end;
    end;
    if lService.Stop(2000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: SQLite binding service did not stop');
      Exit;
    end;
    Result := 0;
  finally
    g.Clear;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
    if TFile.Exists(lQueryDatabaseFileName) then
      TFile.Delete(lQueryDatabaseFileName);
  end;
end;

function RunLogicalProcessorBlobSelfTest: Integer;
var
  lData: TBytes;
  lDecoded: TArray<TMachineOverviewOptionalDouble>;
  lValues: TArray<TMachineOverviewOptionalDouble>;
begin
  Result := 1;
  SetLength(lValues, 4);
  lValues[0].Available := True;
  lValues[0].Value := 12.34;
  lValues[1].Available := False;
  lValues[2].Available := True;
  lValues[2].Value := 100;
  lValues[3].Available := True;
  lValues[3].Value := 0;
  lData := PackMachineOverviewLogicalProcessors(lValues);
  if (Length(lData) <> 16) or (lData[0] <> Ord('M')) or
    (lData[1] <> Ord('O')) or (lData[2] <> Ord('C')) or
    (lData[3] <> Ord('P')) or (lData[4] <> 1) or
    (lData[5] <> 2) or (lData[6] <> 4) or (lData[7] <> 0) or
    (lData[8] <> $D2) or (lData[9] <> $04) or
    (lData[10] <> $FF) or (lData[11] <> $FF) then
  begin
    Writeln('SELFTEST FAILED: logical-processor BLOB header, scale, count, or byte order is wrong');
    Exit;
  end;
  if (not TryUnpackMachineOverviewLogicalProcessors(lData, lDecoded)) or
    (Length(lDecoded) <> Length(lValues)) or
    (not lDecoded[0].Available) or
    (not SameValue(lDecoded[0].Value, 12.34, 0.001)) or
    lDecoded[1].Available or (not lDecoded[2].Available) or
    (not SameValue(lDecoded[2].Value, 100, 0.001)) or
    (not lDecoded[3].Available) or
    (not SameValue(lDecoded[3].Value, 0, 0.001)) then
  begin
    Writeln('SELFTEST FAILED: logical-processor BLOB did not round trip');
    Exit;
  end;
  SetLength(lData, Length(lData) - 1);
  if TryUnpackMachineOverviewLogicalProcessors(lData, lDecoded) or
    (Length(lDecoded) <> 0) then
  begin
    Writeln('SELFTEST FAILED: truncated logical-processor BLOB was accepted');
    Exit;
  end;
  Result := 0;
end;

function RunHistoryConfigSelfTest: Integer;
var
  lConfig: TMachineOverviewHistoryConfig;
  lDefaults: TMachineOverviewSettings;
  lSettings: TMachineOverviewSettings;
begin
  Result := 1;
  lDefaults := TMachineOverviewSettings.Defaults;
  lSettings := lDefaults;
  lSettings.Enabled := True;
  lSettings.HistoryEnabled := True;
  lSettings.HistoryCommitIntervalMs := -1;
  lSettings.RawRetentionHours := 0;
  lSettings.Rollup10sRetentionDays := -1;
  lSettings.Rollup1mRetentionDays := 0;
  lSettings.MaxDatabaseSizeMB := -1;
  lConfig := TMachineOverviewHistoryConfig.FromSettings(lSettings,
    'C:\Temp\MachineOverviewHistory.db');
  if (not lConfig.Enabled) or
    (lConfig.CommitIntervalMs <> Cardinal(
      lDefaults.HistoryCommitIntervalMs)) or
    (lConfig.RawRetentionHours <> lDefaults.RawRetentionHours) or
    (lConfig.Rollup10sRetentionDays <>
      lDefaults.Rollup10sRetentionDays) or
    (lConfig.Rollup1mRetentionDays <> lDefaults.Rollup1mRetentionDays) or
    (lConfig.MaxDatabaseSizeBytes <> UInt64(lDefaults.MaxDatabaseSizeMB) *
      1024 * 1024) then
  begin
    Writeln('SELFTEST FAILED: invalid history settings did not use safe defaults');
    Exit;
  end;
  lConfig := TMachineOverviewHistoryConfig.FromSettings(lSettings, '   ');
  if lConfig.Enabled then
  begin
    Writeln('SELFTEST FAILED: blank history database path enabled persistence');
    Exit;
  end;
  Result := 0;
end;

function CreateHistoryQueueTestSample(const aProviderId: string;
  const aMonotonicMs: UInt64): IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := aProviderId;
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtMonotonicMs := aMonotonicMs;
  lSample.State.CapturedAtUtc := EncodeDate(2026, 8, 28) +
    EncodeTime(20, 0, 0, 0);
  Result := CreateMachineOverviewRawSample(lSample);
end;

function RunHistoryBacklogSelfTest: Integer;
var
  g: TGarbos;
  lBatch: TArray<TMachineOverviewHistoryItem>;
  lBacklog: TMachineOverviewHistoryBacklog;
  lDiagnostics: TMachineOverviewHistoryBacklogDiagnostics;
begin
  g := Default(TGarbos);
  Result := 1;
  GC(lBacklog, TMachineOverviewHistoryBacklog.Create(3), g);
  if (lBacklog.Enqueue(TMachineOverviewHistoryItem.CreateRaw(
      CreateHistoryQueueTestSample('raw-a', 1))) <>
      TMachineOverviewHistoryEnqueueResult.Queued) or
    (lBacklog.Enqueue(TMachineOverviewHistoryItem.CreateRaw(
      CreateHistoryQueueTestSample('raw-b', 2))) <>
      TMachineOverviewHistoryEnqueueResult.Queued) or
    (lBacklog.Enqueue(TMachineOverviewHistoryItem.CreateIncidentMarker) <>
      TMachineOverviewHistoryEnqueueResult.Queued) or
    (lBacklog.Enqueue(TMachineOverviewHistoryItem.CreateRaw(
      CreateHistoryQueueTestSample('raw-c', 3))) <>
      TMachineOverviewHistoryEnqueueResult.Queued) then
  begin
    Writeln('SELFTEST FAILED: bounded history backlog rejected a replaceable raw item');
    Exit;
  end;
  lBatch := lBacklog.PeekBatch(3);
  if (Length(lBatch) <> 3) or
    (lBatch[0].Sample.ProviderId <> 'raw-b') or
    (lBatch[1].Kind <> TMachineOverviewHistoryItemKind.Incident) or
    (lBatch[2].Sample.ProviderId <> 'raw-c') then
  begin
    Writeln('SELFTEST FAILED: history backlog did not drop the oldest raw item first');
    Exit;
  end;
  if lBacklog.Enqueue(TMachineOverviewHistoryItem.CreateIncidentMarker) <>
    TMachineOverviewHistoryEnqueueResult.Queued then
  begin
    Writeln('SELFTEST FAILED: history backlog did not preserve a new incident over raw data');
    Exit;
  end;
  lBatch := lBacklog.PeekBatch(3);
  if (lBatch[0].Kind <> TMachineOverviewHistoryItemKind.Incident) or
    (lBatch[1].Sample.ProviderId <> 'raw-c') or
    (lBatch[2].Kind <> TMachineOverviewHistoryItemKind.Incident) then
  begin
    Writeln('SELFTEST FAILED: incident preference changed FIFO ordering');
    Exit;
  end;
  lBacklog.RemoveFirst(3);
  if lBacklog.Diagnostics.Count <> 0 then
  begin
    Writeln('SELFTEST FAILED: history backlog batch removal left residue');
    Exit;
  end;
  lDiagnostics := lBacklog.Diagnostics;
  if (lDiagnostics.RawDropped <> 2) or
    (lDiagnostics.IncidentDropped <> 0) then
  begin
    Writeln('SELFTEST FAILED: history backlog drop diagnostics are wrong');
    Exit;
  end;
  Result := 0;
end;

procedure ConfigureHistoryTestConnection(const aDatabaseFileName: string;
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
  aConnection.Params.Values['Synchronous'] := 'Normal';
  aConnection.Params.Values['JournalMode'] := 'WAL';
  aConnection.Params.Values['SharedCache'] := 'False';
  aConnection.Params.Values['BusyTimeout'] := '100';
  aConnection.Connected := True;
end;

function QueryHistoryInt64(const aConnection: TFDConnection;
  const aSql: string): Int64;
var
  g: TGarbos;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  GC(lQuery, TFDQuery.Create(nil), g);
  lQuery.Connection := aConnection;
  lQuery.Open(aSql);
  Result := lQuery.Fields[0].AsLargeInt;
end;

function CreateHistorySystemTestSample(const aCapturedAtUtc: TDateTime;
  const aMonotonicMs: UInt64; const aCpuValue: Double):
  IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := 'windows-core';
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtMonotonicMs := aMonotonicMs;
  lSample.State.CapturedAtUtc := aCapturedAtUtc;
  SetLength(lSample.Measurements, 4);
  lSample.Measurements[0].Name := 'cpu_total_percent';
  lSample.Measurements[0].Available := True;
  lSample.Measurements[0].Value := aCpuValue;
  lSample.Measurements[1].Name := 'cpu_logical:0';
  lSample.Measurements[1].Available := True;
  lSample.Measurements[1].Value := 25.25;
  lSample.Measurements[2].Name := 'cpu_logical:1';
  lSample.Measurements[2].Available := False;
  lSample.Measurements[3].Name := 'physical_available_bytes';
  lSample.Measurements[3].Available := True;
  lSample.Measurements[3].Value := 123456789;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function CreateHistoryDiskTestSample(const aCapturedAtUtc: TDateTime):
  IMachineOverviewRawSample;
var
  lSample: TMachineOverviewProviderSample;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := 'disks';
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtMonotonicMs := 123460;
  lSample.State.CapturedAtUtc := aCapturedAtUtc;
  SetLength(lSample.Measurements, 7);
  lSample.Measurements[0].Name := 'disk_active_percent:physical:0';
  lSample.Measurements[0].EntityId := 'physical:0';
  lSample.Measurements[0].DisplayText := 'Disk 0';
  lSample.Measurements[0].Available := True;
  lSample.Measurements[0].Value := 91.5;
  lSample.Measurements[1] := lSample.Measurements[0];
  lSample.Measurements[1].Name := 'disk_read_mb_per_sec:physical:0';
  lSample.Measurements[1].Value := 12.25;
  lSample.Measurements[2] := lSample.Measurements[0];
  lSample.Measurements[2].Name := 'disk_write_mb_per_sec:physical:0';
  lSample.Measurements[2].Value := 7.75;
  lSample.Measurements[3] := lSample.Measurements[0];
  lSample.Measurements[3].Name := 'disk_latency_ms:physical:0';
  lSample.Measurements[3].Value := 22.5;
  lSample.Measurements[4] := lSample.Measurements[0];
  lSample.Measurements[4].Name := 'disk_latency_max_60s:physical:0';
  lSample.Measurements[4].Value := 45;
  lSample.Measurements[5] := lSample.Measurements[0];
  lSample.Measurements[5].Name := 'disk_queue_length:physical:0';
  lSample.Measurements[5].Value := 3.5;
  lSample.Measurements[6] := lSample.Measurements[0];
  lSample.Measurements[6].Name := 'disk_volume_free_bytes:0:1';
  lSample.Measurements[6].DisplayText := 'C:\';
  lSample.Measurements[6].Value := 987654321;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function CreateHistoryProcessTestSample(const aCapturedAtUtc: TDateTime):
  IMachineOverviewRawSample;
const
  cNames: array[0..2] of string = ('process_cpu_rank:1',
    'process_ram_rank:1', 'process_io_rank:1');
  cValues: array[0..2] of Double = (8.5, 456789012, 3.25);
var
  lSample: TMachineOverviewProviderSample;
  i: Integer;
begin
  lSample := Default(TMachineOverviewProviderSample);
  lSample.State.ProviderId := 'processes';
  lSample.State.Status := TMachineOverviewProviderStatus.Available;
  lSample.State.CapturedAtMonotonicMs := 123461;
  lSample.State.CapturedAtUtc := aCapturedAtUtc;
  SetLength(lSample.Measurements, Length(cNames) + 2);
  for i := 0 to High(cNames) do
  begin
    lSample.Measurements[i].Name := cNames[i];
    lSample.Measurements[i].EntityId := '4242:9876543210';
    lSample.Measurements[i].DisplayText := 'history-test.exe';
    lSample.Measurements[i].DetailText := 'C:\Test\history-test.exe';
    lSample.Measurements[i].StatusText := 'Available';
    lSample.Measurements[i].Available := True;
    lSample.Measurements[i].Value := cValues[i];
  end;
  lSample.Measurements[3].Name := 'process_cpu_interval_ms';
  lSample.Measurements[3].Available := True;
  lSample.Measurements[3].Value := 5000;
  lSample.Measurements[4].Name := 'logical_processor_count';
  lSample.Measurements[4].Available := True;
  lSample.Measurements[4].Value := 32;
  Result := CreateMachineOverviewRawSample(lSample);
end;

function VerifyHistoryDatabase(const aDatabaseFileName: string): Boolean;
var
  g: TGarbos;
  lConnection: TFDConnection;
  lData: TBytes;
  lQuery: TFDQuery;
  lValues: TArray<TMachineOverviewOptionalDouble>;
begin
  g := Default(TGarbos);
  Result := False;
  GC(lConnection, TFDConnection.Create(nil), g);
  ConfigureHistoryTestConnection(aDatabaseFileName, lConnection);
  GC(lQuery, TFDQuery.Create(nil), g);
  lQuery.Connection := lConnection;
  lQuery.Open('PRAGMA journal_mode');
  if not SameText(lQuery.Fields[0].AsString, 'wal') then
    Exit;
  lQuery.Close;
  lQuery.Open('PRAGMA synchronous');
  if lQuery.Fields[0].AsInteger <> 1 then
    Exit;
  lQuery.Close;
  lQuery.Open('PRAGMA user_version');
  if lQuery.Fields[0].AsInteger <> 3 then
    Exit;
  lQuery.Close;
  lQuery.Open('SELECT cpu_total, logical_cpu_blob FROM system_sample_raw ' +
    'ORDER BY utc_ms');
  if lQuery.RecordCount <> 3 then
    Exit;
  if not SameValue(lQuery.Fields[0].AsFloat, 37.5, 0.001) then
    Exit;
  lData := lQuery.Fields[1].AsBytes;
  if (not TryUnpackMachineOverviewLogicalProcessors(lData, lValues)) or
    (Length(lValues) <> 2) or (not lValues[0].Available) or
    (not SameValue(lValues[0].Value, 25.25, 0.001)) or
    lValues[1].Available then
    Exit;
  if (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM disk_sample_raw') <> 1) or
    (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM process_top_sample') <> 3) or
    (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM rollup_10s') <> 2) or
    (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM rollup_1m') <> 1) then
    Exit;
  if QueryHistoryInt64(lConnection,
      'SELECT MIN(utc_ms) FROM system_sample_raw') <> 1787948130125 then
  begin
    Writeln('SELFTEST FAILED: UTC sample timestamp was persisted as local time');
    Exit;
  end;
  lQuery.Close;
  lQuery.Open('SELECT active_percent, read_mb_per_sec, volume_summary ' +
    'FROM disk_sample_raw');
  if (not SameValue(lQuery.Fields[0].AsFloat, 91.5, 0.001)) or
    (not SameValue(lQuery.Fields[1].AsFloat, 12.25, 0.001)) or
    (Pos('C:\', lQuery.Fields[2].AsString) = 0) then
    Exit;
  lQuery.Close;
  lQuery.Open('SELECT category, entity_id, image_path FROM ' +
    'process_top_sample ORDER BY category');
  if (lQuery.RecordCount <> 3) or
    (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM process_top_sample WHERE entity_id=' +
      '''4242:9876543210'' AND image_path=''C:\Test\history-test.exe'' ' +
      'AND interval_ms=5000 AND logical_processor_count=32') <> 3) then
    Exit;
  lQuery.Close;
  lQuery.Open('SELECT sample_count, cpu_sum, cpu_count, cpu_max FROM ' +
    'rollup_1m');
  if (lQuery.Fields[0].AsInteger <> 3) or
    (not SameValue(lQuery.Fields[1].AsFloat, 127.5, 0.001)) or
    (lQuery.Fields[2].AsInteger <> 3) or
    (not SameValue(lQuery.Fields[3].AsFloat, 50, 0.001)) then
    Exit;
  Result := True;
end;

function RunHistoryStoreSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lDirectory: string;
  lRestartService: TMachineOverviewHistoryService;
  lService: TMachineOverviewHistoryService;
  lStage: string;
  lTestUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('history-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lService := nil;
  lRestartService := nil;
  try
    try
      lStage := 'configure';
      lConfig := Default(TMachineOverviewHistoryConfig);
    lConfig.DiskFreeBytesOverride := -1;
    lConfig.Enabled := True;
    lConfig.DatabaseFileName := lDatabaseFileName;
    lConfig.CommitIntervalMs := 60000;
    lConfig.QueueCapacity := 64;
    lConfig.RawRetentionHours := 48;
    lConfig.Rollup10sRetentionDays := 30;
    lConfig.Rollup1mRetentionDays := 365;
    lConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lConfig.BusyTimeoutMs := 100;
      lService := TMachineOverviewHistoryService.Create(nil, lConfig);
      lStage := 'start';
      lService.Start;
    if not lService.WaitUntilInitialized(5000) then
    begin
      Writeln('SELFTEST FAILED: history SQLite initialization did not complete');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if (not lDiagnostics.Available) or (not lDiagnostics.Initialized) or
      (lDiagnostics.ActiveWorkerCount <> 1) or
      (lDiagnostics.WriterThreadId = 0) or
      (lDiagnostics.WriterThreadId = GetCurrentThreadId) then
    begin
      Writeln(Format('SELFTEST FAILED: history writer ownership diagnostics are wrong: available=%d initialized=%d workers=%d writer=%d current=%d error=%s',
        [Ord(lDiagnostics.Available), Ord(lDiagnostics.Initialized),
         lDiagnostics.ActiveWorkerCount, lDiagnostics.WriterThreadId,
         GetCurrentThreadId, lDiagnostics.LastError]));
      Exit;
    end;
      lStage := 'enqueue';
      lTestUtc := EncodeDate(2026, 8, 28) + EncodeTime(20, 15, 30, 125);
      // Our expired row belongs to an earlier commit; the current batch is protected.
      if lService.EnqueueRaw(CreateHistorySystemTestSample(IncDay(lTestUtc, -400), 1, 1)) <>
        TMachineOverviewHistoryEnqueueResult.Queued then
        raise Exception.Create('Expired fixture enqueue failed');
      if not lService.Flush(5000) then
        raise Exception.Create('Expired fixture batch did not flush');
      if lService.EnqueueRaw(CreateHistorySystemTestSample(lTestUtc,
        123456, 37.5)) <>
      TMachineOverviewHistoryEnqueueResult.Queued then
    begin
      Writeln('SELFTEST FAILED: history writer rejected a raw sample');
      Exit;
    end;
      lStage := 'pre-flush read connection';
      GC(lConnection, TFDConnection.Create(nil), g);
      ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
      lStage := 'pre-flush row count';
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM system_sample_raw') <> 1 then
    begin
      Writeln('SELFTEST FAILED: history writer bypassed transactional batching');
      Exit;
    end;
      lConnection.Connected := False;
      lStage := 'enqueue provider and retention samples';
      if (lService.EnqueueRaw(CreateHistorySystemTestSample(
          IncSecond(lTestUtc, 5), 123457, 40)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistorySystemTestSample(
          IncSecond(lTestUtc, 15), 123458, 50)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistoryDiskTestSample(lTestUtc)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistoryProcessTestSample(lTestUtc)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) then
      begin
        Writeln('SELFTEST FAILED: history writer rejected provider or retention samples');
        Exit;
      end;
      lStage := 'flush';
    if not lService.Flush(5000) then
    begin
      Writeln('SELFTEST FAILED: history writer did not flush its batch');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.Accepted <> 6) or (lDiagnostics.Persisted <> 6) or
      (lDiagnostics.QueueDepth <> 0) or
      (not lDiagnostics.LastCommitAvailable) or
      (not lDiagnostics.LastError.IsEmpty) then
    begin
      Writeln('SELFTEST FAILED: successful history diagnostics are wrong');
      Exit;
    end;
      lStage := 'first stop';
      if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: history writer did not stop cleanly');
      Exit;
    end;
      lStage := 'first verification';
      if not VerifyHistoryDatabase(lDatabaseFileName) then
    begin
      Writeln('SELFTEST FAILED: history schema, pragmas, raw BLOB, or rollups are wrong');
      Exit;
    end;
      lStage := 'restart';
      lRestartService := TMachineOverviewHistoryService.Create(nil, lConfig);
      lRestartService.Start;
    if (not lRestartService.WaitUntilInitialized(5000)) or
      (lRestartService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (not VerifyHistoryDatabase(lDatabaseFileName)) then
    begin
      Writeln('SELFTEST FAILED: history database did not survive writer restart');
      Exit;
    end;
      Result := 0;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: history store stage %s: %s: %s',
          [lStage, lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  finally
    lRestartService.Free;
    lService.Free;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function RunHistoryMigrationSelfTest: Integer;
var
  g: TGarbos;
  lBackupFileName: string;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDirectory: string;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('migration-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lBackupFileName := lDatabaseFileName + '.pre-migration-v0.bak';
  lConnection := nil;
  lService := nil;
  try
    GC(lConnection, TFDConnection.Create(nil), g);
    lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
    lDriverLink.DriverID := 'SQLite';
    lConnection.LoginPrompt := False;
    lConnection.Params.Values['DriverID'] := 'SQLite';
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.Params.Values['OpenMode'] := 'CreateUTF8';
    lConnection.Params.Values['SharedCache'] := 'False';
    lConnection.Connected := True;
    lConnection.ExecSQL('CREATE TABLE legacy_sentinel(value TEXT NOT NULL)');
    lConnection.ExecSQL('INSERT INTO legacy_sentinel(value) VALUES ' +
      '(''preserve-me'')');
    lConnection.ExecSQL('PRAGMA user_version=0');
    lConnection.Connected := False;
    lConfig := Default(TMachineOverviewHistoryConfig);
    lConfig.DiskFreeBytesOverride := -1;
    lConfig.Enabled := True;
    lConfig.DatabaseFileName := lDatabaseFileName;
    lConfig.CommitIntervalMs := 10000;
    lConfig.QueueCapacity := 16;
    lConfig.RawRetentionHours := 48;
    lConfig.Rollup10sRetentionDays := 30;
    lConfig.Rollup1mRetentionDays := 365;
    lConfig.MaxDatabaseSizeBytes := 32 * 1024 * 1024;
    lConfig.BusyTimeoutMs := 100;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
    begin
      Writeln('SELFTEST FAILED: schema-v0 history migration did not complete');
      Exit;
    end;
    lBackupFileName := TDirectory.GetFiles(lDirectory,
      ExtractFileName(lDatabaseFileName) + '.pre-migration-*.bak')[0];
    if not TFile.Exists(lBackupFileName) then
    begin
      Writeln('SELFTEST FAILED: schema-v0 history migration made no prior-file backup');
      Exit;
    end;
    lConnection.Connected := False;
    lConnection.Params.Values['Database'] := lBackupFileName;
    lConnection.Params.Values['OpenMode'] := 'ReadWrite';
    lConnection.Connected := True;
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM legacy_sentinel WHERE value=''preserve-me''') <> 1 then
    begin
      Writeln('SELFTEST FAILED: migration backup does not preserve the prior database');
      Exit;
    end;
    lConnection.Connected := False;
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 3) or
      (QueryHistoryInt64(lConnection,
        'SELECT COUNT(*) FROM legacy_sentinel WHERE value=''preserve-me''') <> 1) then
    begin
      Writeln('SELFTEST FAILED: migration lost legacy data or did not set schema v2');
      Exit;
    end;
    Result := 0;
  finally
    lService.Free;
    if Assigned(lConnection) then
      lConnection.Connected := False;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lBackupFileName) then
      TFile.Delete(lBackupFileName);
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function CreateHistoryReliabilityConfig(const aDatabaseFileName: string;
  const aQueueCapacity: Integer; const aMaximumBytes: UInt64):
  TMachineOverviewHistoryConfig;
begin
  Result := Default(TMachineOverviewHistoryConfig);
  Result.DiskFreeBytesOverride := -1;
  Result.Enabled := True;
  Result.DatabaseFileName := aDatabaseFileName;
  Result.CommitIntervalMs := 60000;
  Result.QueueCapacity := aQueueCapacity;
  Result.RawRetentionHours := 48;
  Result.Rollup10sRetentionDays := 30;
  Result.Rollup1mRetentionDays := 365;
  Result.MaxDatabaseSizeBytes := aMaximumBytes;
  Result.BusyTimeoutMs := 50;
end;

procedure DeleteHistoryReliabilityFiles(const aDatabaseFileName: string);
var
  lFileName: string;
begin
  if TFile.Exists(aDatabaseFileName + '-shm') then
    TFile.Delete(aDatabaseFileName + '-shm');
  if TFile.Exists(aDatabaseFileName + '-wal') then
    TFile.Delete(aDatabaseFileName + '-wal');
  if TFile.Exists(aDatabaseFileName) then
    TFile.Delete(aDatabaseFileName);
  for lFileName in TDirectory.GetFiles(ExtractFilePath(aDatabaseFileName),
    ExtractFileName(aDatabaseFileName) + '.pre-migration-*') do
    TFile.Delete(lFileName);
end;

function RunHistoryBusyBacklogSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lDirectory: string;
  lService: TMachineOverviewHistoryService;
  lTestUtc: TDateTime;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('busy-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 4,
      32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) then
    begin
      Writeln('SELFTEST FAILED: busy-history writer did not initialize');
      Exit;
    end;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    lConnection.StartTransaction;
    lConnection.ExecSQL('INSERT OR REPLACE INTO schema_info(key, value) ' +
      'VALUES (''lock-test'', ''held'')');
    lTestUtc := EncodeDate(2026, 8, 28) + EncodeTime(21, 0, 0, 0);
    lService.EnqueueRaw(CreateHistorySystemTestSample(lTestUtc, 200000, 10));
    if lService.Flush(700) then
    begin
      Writeln('SELFTEST FAILED: locked history database reported a successful flush');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.RetryCount = 0) or lDiagnostics.LastError.IsEmpty or
      (lDiagnostics.QueueDepth > lConfig.QueueCapacity) then
    begin
      Writeln('SELFTEST FAILED: locked history retry diagnostics are wrong');
      Exit;
    end;
    for i := 1 to 20 do
      lService.EnqueueRaw(CreateHistorySystemTestSample(
        IncSecond(lTestUtc, i), 200000 + i, 10 + i));
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.QueueDepth > lConfig.QueueCapacity) or
      (lDiagnostics.RawDropped = 0) or
      (lDiagnostics.IncidentDropped <> 0) then
    begin
      Writeln('SELFTEST FAILED: locked history backlog was not bounded or preferential');
      Exit;
    end;
    lConnection.Rollback;
    lConnection.Connected := False;
    if not lService.Flush(5000) then
    begin
      Writeln('SELFTEST FAILED: history writer did not recover after lock release');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.RetryCount = 0) or
      (lDiagnostics.Persisted = 0) or (lDiagnostics.QueueDepth <> 0) or
      (not lDiagnostics.LastCommitAvailable) or
      (not lDiagnostics.LastError.IsEmpty) then
    begin
      Writeln('SELFTEST FAILED: recovered history diagnostics are wrong');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: recovered history writer did not stop');
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lConnection) then
    begin
      if lConnection.InTransaction then
        lConnection.Rollback;
      lConnection.Connected := False;
    end;
    lService.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
  end;
end;

function RunHistoryV1IncidentMigrationSelfTest: Integer;
var
  g: TGarbos;
  lBackupFileName: string;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDirectory: string;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lError: string;
  lIncidents: TArray<TMachineOverviewIncident>;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('migration-v1-%d-%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  lBackupFileName := lDatabaseFileName + '.pre-migration-v1.bak';
  lConnection := nil;
  lService := nil;
  try
    GC(lConnection, TFDConnection.Create(nil), g);
    lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
    lDriverLink.DriverID := 'SQLite';
    lConnection.LoginPrompt := False;
    lConnection.Params.Values['DriverID'] := 'SQLite';
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.Params.Values['OpenMode'] := 'CreateUTF8';
    lConnection.Params.Values['SharedCache'] := 'False';
    lConnection.Connected := True;
    lConnection.ExecSQL('CREATE TABLE incident (' +
      'id INTEGER PRIMARY KEY, incident_key TEXT NOT NULL, ' +
      'started_utc_ms INTEGER NOT NULL, ended_utc_ms INTEGER, ' +
      'severity INTEGER NOT NULL, summary TEXT NOT NULL, ' +
      'context_text TEXT NOT NULL)');
    lConnection.ExecSQL('INSERT INTO incident(incident_key, ' +
      'started_utc_ms, ended_utc_ms, severity, summary, context_text) ' +
      'VALUES (''legacy-v1'', 1787972400000, NULL, 2, ' +
      '''legacy summary'', ''legacy context'')');
    lConnection.ExecSQL('PRAGMA user_version=1');
    lConnection.Connected := False;
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 16,
      32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      Exit;
    lBackupFileName := TDirectory.GetFiles(lDirectory,
      ExtractFileName(lDatabaseFileName) + '.pre-migration-*.bak')[0];
    if not TFile.Exists(lBackupFileName) then
    begin
      Writeln('SELFTEST FAILED: schema-v1 migration made no prior-file backup');
      Exit;
    end;
    lConnection.Params.Values['Database'] := lBackupFileName;
    lConnection.Params.Values['OpenMode'] := 'ReadWrite';
    lConnection.Connected := True;
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM incident WHERE incident_key=''legacy-v1''') <> 1 then
      Exit;
    lConnection.Connected := False;
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 3) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM ' +
       'pragma_table_info(''incident'') WHERE name=''pre_context_json''') <> 1) then
    begin
      Writeln('SELFTEST FAILED: schema-v1 incident migration is incomplete');
      Exit;
    end;
    lConnection.Connected := False;
    if (not TryLoadMachineOverviewIncidents(lDatabaseFileName, 0, 10,
        lIncidents, lError)) or (Length(lIncidents) <> 1) or
      (lIncidents[0].StableId <> 'legacy-v1') or
      (lIncidents[0].Summary <> 'legacy summary') then
    begin
      Writeln('SELFTEST FAILED: schema-v1 incident did not survive migration: ' +
        lError);
      Exit;
    end;
    Result := 0;
  finally
    lService.Free;
    if Assigned(lConnection) then
      lConnection.Connected := False;
    if TFile.Exists(lDatabaseFileName + '-shm') then
      TFile.Delete(lDatabaseFileName + '-shm');
    if TFile.Exists(lDatabaseFileName + '-wal') then
      TFile.Delete(lDatabaseFileName + '-wal');
    if TFile.Exists(lBackupFileName) then
      TFile.Delete(lBackupFileName);
    if TFile.Exists(lDatabaseFileName) then
      TFile.Delete(lDatabaseFileName);
  end;
end;

function RunHistoryLockedShutdownSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDirectory: string;
  lElapsedMs: UInt64;
  lService: TMachineOverviewHistoryService;
  lStartedMs: UInt64;
  lStopResult: TMachineOverviewShutdownResult;
  lTestUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('locked-stop-%d-%d.db',
      [GetCurrentProcessId, GetTickCount64]));
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 8,
      32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) then
      Exit;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    lConnection.StartTransaction;
    lConnection.ExecSQL('INSERT OR REPLACE INTO schema_info(key, value) ' +
      'VALUES (''locked-stop'', ''held'')');
    lTestUtc := EncodeDate(2026, 8, 29) + EncodeTime(3, 0, 0, 0);
    if lService.EnqueueRaw(CreateHistorySystemTestSample(lTestUtc,
      300000, 25)) <> TMachineOverviewHistoryEnqueueResult.Queued then
      Exit;
    lService.Flush(300);
    lStartedMs := GetTickCount64;
    lStopResult := lService.Stop(1000);
    lElapsedMs := GetTickCount64 - lStartedMs;
    lConnection.Rollback;
    lConnection.Connected := False;
    if lStopResult <> TMachineOverviewShutdownResult.Stopped then
      lService.Stop(5000);
    if (lStopResult <> TMachineOverviewShutdownResult.Stopped) or
      (lElapsedMs > 1500) then
    begin
      Writeln(Format('SELFTEST FAILED: locked history shutdown result=%d ' +
        'duration=%d ms', [Ord(lStopResult), lElapsedMs]));
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lConnection) then
    begin
      if lConnection.InTransaction then
        lConnection.Rollback;
      lConnection.Connected := False;
    end;
    lService.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
  end;
end;

function RunHistoryCorruptionSelfTest: Integer;
var
  lBefore: string;
  lConfig: TMachineOverviewHistoryConfig;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lDirectory: string;
  lService: TMachineOverviewHistoryService;
  lTestUtc: TDateTime;
  i: Integer;
begin
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('corrupt-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lBefore := 'not a SQLite database';
  TFile.WriteAllText(lDatabaseFileName, lBefore, TEncoding.UTF8);
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 4,
      32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if not lService.WaitUntilInitialized(5000) then
    begin
      Writeln('SELFTEST FAILED: corrupt history initialization did not complete');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if lDiagnostics.Available or (not lDiagnostics.Initialized) or
      lDiagnostics.LastError.IsEmpty then
    begin
      Writeln('SELFTEST FAILED: corrupt history did not degrade explicitly');
      Exit;
    end;
    lTestUtc := EncodeDate(2026, 8, 28) + EncodeTime(21, 30, 0, 0);
    for i := 1 to 12 do
      lService.EnqueueRaw(CreateHistorySystemTestSample(lTestUtc, i, i));
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.QueueDepth <> 4) or (lDiagnostics.RawDropped <> 8) then
    begin
      Writeln('SELFTEST FAILED: failed history database backlog is not bounded');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
    begin
      Writeln('SELFTEST FAILED: corrupt history service did not stop cleanly');
      Exit;
    end;
    if TFile.ReadAllText(lDatabaseFileName, TEncoding.UTF8) <> lBefore then
    begin
      Writeln('SELFTEST FAILED: corrupt history database was modified');
      Exit;
    end;
    Result := 0;
  finally
    lService.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
  end;
end;

function RunHistoryStorageCapSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lDirectory: string;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('cap-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 16, 1);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) then
    begin
      Writeln('SELFTEST FAILED: capped history writer did not initialize');
      Exit;
    end;
    lService.EnqueueRaw(CreateHistorySystemTestSample(
      EncodeDate(2026, 8, 28), 1, 25));
    if not lService.Flush(5000) then
    begin
      Writeln('SELFTEST FAILED: capped history writer did not flush');
      Exit;
    end;
    lDiagnostics := lService.Diagnostics;
    if lDiagnostics.StorageState <> TMachineOverviewStorageState.OverBudget then
    begin
      Writeln('SELFTEST FAILED: protected batch did not report OverBudget');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      Exit;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM system_sample_raw') <> 1 then
    begin
      Writeln('SELFTEST FAILED: storage cap deleted the protected batch');
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
  end;
end;

function RunHistoryPipelineIntegrationSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lCursor: TMachineOverviewSnapshotCursor;
  lDatabaseFileName: string;
  lDirectory: string;
  lHistory: TMachineOverviewHistoryService;
  lPipeline: TMachineOverviewPipeline;
  lSnapshot: IMachineOverviewSnapshot;
  lTestUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory, Format('pipeline-%d-%d.db',
    [GetCurrentProcessId, GetTickCount64]));
  lConnection := nil;
  lCursor := nil;
  lHistory := nil;
  lPipeline := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 16,
      32 * 1024 * 1024);
    lPipeline := TMachineOverviewPipeline.Create(16, 16);
    lHistory := TMachineOverviewHistoryService.Create(lPipeline, lConfig);
    lCursor := TMachineOverviewSnapshotCursor.Create;
    lPipeline.Start;
    lHistory.Start;
    if (not lPipeline.WaitUntilRunning(5000)) or
      (not lHistory.WaitUntilInitialized(5000)) or
      (not lHistory.Diagnostics.Available) then
    begin
      Writeln('SELFTEST FAILED: pipeline-history integration did not initialize');
      Exit;
    end;
    lCursor.SetFrozen(True);
    lTestUtc := EncodeDate(2026, 8, 28) + EncodeTime(22, 0, 0, 0);
    if (lPipeline.EnqueueRaw(CreateHistorySystemTestSample(lTestUtc,
        300000, 20)) <> TMachineOverviewEnqueueResult.Queued) or
      (not lPipeline.WaitForSequence(1, 5000)) or
      (not lHistory.Flush(5000)) or
      lCursor.TryRead(lPipeline, lSnapshot) then
    begin
      Writeln('SELFTEST FAILED: frozen display blocked history or advanced its cursor');
      Exit;
    end;
    if (lPipeline.EnqueueRaw(CreateHistorySystemTestSample(
        IncSecond(lTestUtc, 1), 301000, 30)) <>
        TMachineOverviewEnqueueResult.Queued) or
      (not lPipeline.WaitForSequence(2, 5000)) or
      (not lHistory.Flush(5000)) then
    begin
      Writeln('SELFTEST FAILED: pipeline history did not accept the second sample');
      Exit;
    end;
    lCursor.SetFrozen(False);
    if (not lCursor.TryRead(lPipeline, lSnapshot)) or
      ContainsText(lSnapshot.Presentation.DiagnosticText,
        'SQLite commit: Unavailable') then
    begin
      Writeln('SELFTEST FAILED: immutable snapshot did not expose history commit state');
      Exit;
    end;
    if (lPipeline.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (lHistory.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
    begin
      Writeln('SELFTEST FAILED: pipeline-history shutdown order timed out');
      Exit;
    end;
    if (lPipeline.Diagnostics.ActiveWorkerCount <> 0) or
      (lHistory.Diagnostics.ActiveWorkerCount <> 0) then
    begin
      Writeln('SELFTEST FAILED: pipeline-history shutdown left a worker');
      Exit;
    end;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM system_sample_raw') <> 2 then
    begin
      Writeln('SELFTEST FAILED: shutdown did not drain pipeline history records');
      Exit;
    end;
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lHistory.Free;
    lPipeline.Free;
    lCursor.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
  end;
end;

procedure CreateHistoryV2Fixture(const aFileName: string; const aCount: Integer);
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  lConfig := CreateHistoryReliabilityConfig(aFileName, 16, 32 * 1024 * 1024);
  GC(lService, TMachineOverviewHistoryService.Create(nil, lConfig), g);
  lService.Start;
  if (not lService.WaitUntilInitialized(5000)) or
    (not lService.Diagnostics.Available) or
    (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
    raise Exception.Create('v2 fixture initialization failed: ' + lService.Diagnostics.LastError);
  GC(lConnection, TFDConnection.Create(nil), g);
  ConfigureHistoryTestConnection(aFileName, lConnection);
  lConnection.ExecSQL('WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL ' +
    'SELECT n+1 FROM rows WHERE n<?) INSERT INTO incident(' +
    'incident_key, started_utc_ms, peak_utc_ms, ended_utc_ms, category, severity, origin, ' +
    'local_display_time, summary, explanation, threshold_text, peak_value, provider_id, ' +
    'provider_freshness_ms, related_entity_ids_json, related_executable_paths_json, ' +
    'trace_status, pre_context_json, post_context_json, context_text, evidence_state) ' +
    'SELECT ''legacy-''||n, 1792519200000+n, 1792519200000+n, 1792519201000+n, ' +
    '0,2,0,'''',''headline-''||n,''explanation'',''threshold'',42,''test'',0,' +
    '''[]'',''[]'',2,''["original"]'',''[]'',''original legacy context'',0 FROM rows', [aCount]);
  lConnection.ExecSQL('DROP TABLE incident_evidence');
  lConnection.ExecSQL('DROP TABLE history_status');
  lConnection.ExecSQL('PRAGMA user_version=2');
  lConnection.ExecSQL('PRAGMA wal_checkpoint(TRUNCATE)');
  lConnection.Connected := False;
end;

function NewHistoryMigrationFile(const aPrefix: string): string;
var
  lDirectory: string;
begin
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  Result := TPath.Combine(lDirectory, Format('%s-%d-%d.db',
    [aPrefix, GetCurrentProcessId, GetTickCount64]));
end;

procedure AssertHistoryBackupSourceUnchanged(const aFileName: string; const aCount: Integer);
var
  g: TGarbos;
  lConnection: TFDConnection;
begin
  g := Default(TGarbos);
  GC(lConnection, TFDConnection.Create(nil), g);
  lConnection.Params.Values['DriverID'] := 'SQLite';
  lConnection.Params.Values['Database'] := aFileName;
  lConnection.Params.Values['OpenMode'] := 'ReadOnly';
  lConnection.Params.Values['JournalMode'] := 'WAL';
  lConnection.Params.Values['LockingMode'] := 'Normal';
  lConnection.Params.Values['SharedCache'] := 'False';
  lConnection.LoginPrompt := False;
  lConnection.Connected := True;
  lConnection.ExecSQL('PRAGMA query_only=ON');
  if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 2) or
    (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident') <> aCount) or
    (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE ' +
      'summary=''headline-''||id AND explanation=''explanation'' AND threshold_text=''threshold'' ' +
      'AND peak_value=42 AND trace_status=2 AND context_text=''original legacy context''') <> aCount) then
    raise Exception.Create('Source incidents changed before backup verification');
end;

function RunHistoryMigrationBackupSpaceSelfTest: Integer;
var
  lBefore: TBytes;
  lAfter: TBytes;
  lConfig: TMachineOverviewHistoryConfig;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lStamp: TDateTime;
begin
  Result := 1;
  lFileName := NewHistoryMigrationFile('backup-space');
  lService := nil;
  try
    CreateHistoryV2Fixture(lFileName, 3);
    lBefore := TFile.ReadAllBytes(lFileName);
    lStamp := TFile.GetLastWriteTimeUtc(lFileName);
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 32 * 1024 * 1024);
    lConfig.DiskFreeBytesOverride := Length(lBefore) + 256 * 1024 * 1024 - 1;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or lService.Diagnostics.Available or
      (not ContainsText(lService.Diagnostics.LastError, 'MigrationBlocked')) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Insufficient backup space was not refused: ' + lService.Diagnostics.LastError);
    lAfter := TFile.ReadAllBytes(lFileName);
    if (Length(lAfter) <> Length(lBefore)) or
      (not CompareMem(@lBefore[0], @lAfter[0], Length(lBefore))) or
      (lStamp <> TFile.GetLastWriteTimeUtc(lFileName)) or
      (Length(TDirectory.GetFiles(ExtractFilePath(lFileName),
        ExtractFileName(lFileName) + '.pre-migration-*')) <> 0) then
      raise Exception.Create('Backup space refusal changed source bytes/time or created backup');
    Writeln('PASS RunHistoryMigrationBackupSpaceSelfTest: source bytes/time unchanged, no backup');
    Result := 0;
  finally
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryMigrationResumeSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lVerified: Boolean;
  lChunks: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('migration-resume');
  lService := nil;
  lVerified := False;
  lChunks := 0;
  try
    CreateHistoryV2Fixture(lFileName, 450);
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 32 * 1024 * 1024);
    lConfig.MigrationObserver :=
      procedure(aStage: string)
      begin
        if aStage = 'BackupVerified' then
        begin
          AssertHistoryBackupSourceUnchanged(lFileName, 450);
          lVerified := True;
        end;
        if aStage = 'CleanupChunkCommitted' then
        begin
          Inc(lChunks);
          if not Assigned(lService) then
            raise Exception.Create('Cleanup observer has no active service');
          if lService.Stop(0) <> TMachineOverviewShutdownResult.TimedOut then
            raise Exception.Create('Writer cancellation did not set the stopping state');
        end;
      end;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(10000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      (not lVerified) or (lChunks <> 1) then
      raise Exception.Create('Migration did not stop after one verified cleanup chunk');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 3) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE evidence_state=5') <> 200) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE evidence_state=0') <> 250) then
      raise Exception.Create('Migration chunk was not durable and bounded at 200 rows');
    lConnection.Connected := False;
    lConfig.MigrationObserver := nil;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(10000)) or (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Migration resume failed: ' + lService.Diagnostics.LastError);
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE evidence_state=5 ' +
      'AND summary=''headline-''||id AND context_text='''' AND trace_status=2') <> 450) or
      (Length(TDirectory.GetFiles(ExtractFilePath(lFileName),
        ExtractFileName(lFileName) + '.pre-migration-*.bak')) <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM history_status WHERE migration_backup_path<>''''') <> 1) then
      raise Exception.Create('Migration resume lost headlines/backup path or made a second backup');
    lConnection.Connected := False;
    Writeln('PASS RunHistoryMigrationResumeSelfTest: verified source unchanged, 200+250 rows, one backup');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryMigrationCopyCancelSelfTest: Integer;
var
  lConfig: TMachineOverviewHistoryConfig;
  lFileName: string;
  lSentinel: string;
  lService: TMachineOverviewHistoryService;
  lCancelled: Boolean;
begin
  Result := 1;
  lFileName := NewHistoryMigrationFile('migration-copy-cancel');
  lService := nil;
  lCancelled := False;
  lSentinel := lFileName + '.pre-migration-v2-existing.bak';
  try
    CreateHistoryV2Fixture(lFileName, 3);
    TFile.WriteAllText(lSentinel, 'existing backup must remain');
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 32 * 1024 * 1024);
    lConfig.MigrationObserver :=
      procedure(aStage: string)
      begin
        if aStage = 'CopyProgress' then
        begin
          lCancelled := True;
          if not Assigned(lService) then
            raise Exception.Create('Copy observer has no active service');
          if lService.Stop(0) <> TMachineOverviewShutdownResult.TimedOut then
            raise Exception.Create('Writer cancellation did not set the stopping state');
        end;
      end;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(10000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) or
      lService.Diagnostics.Available or (not lCancelled) then
      raise Exception.Create('CopyFileEx cancellation did not abort migration');
    AssertHistoryBackupSourceUnchanged(lFileName, 3);
    if (TFile.ReadAllText(lSentinel) <> 'existing backup must remain') or
      (Length(TDirectory.GetFiles(ExtractFilePath(lFileName),
        ExtractFileName(lFileName) + '.pre-migration-*')) <> 1) then
      raise Exception.Create('Cancellation retained a partial file or touched an existing backup');
    Writeln('PASS RunHistoryMigrationCopyCancelSelfTest: partial copy removed, prior backup preserved');
    Result := 0;
  finally
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryReopenPartialSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('reopen-partial');
  lService := nil;
  try
    CreateHistoryV2Fixture(lFileName, 3);
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Partial fixture migration failed');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lConnection.ExecSQL('UPDATE incident SET evidence_state=1 WHERE id=1');
    lConnection.ExecSQL('UPDATE incident SET ended_utc_ms=0 WHERE id=2');
    lConnection.ExecSQL('INSERT INTO incident_evidence VALUES ' +
      '(''legacy-1'',1,1,1,2,''{}''),(''legacy-2'',2,2,2,2,''{}''),(''legacy-3'',3,3,2,2,''{}'')');
    lConnection.Connected := False;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Partial recovery reopen failed');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE evidence_state=3') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE state=3') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE state=2') <> 1) then
      raise Exception.Create('Collecting/unended recovery damaged completion states');
    lConnection.Connected := False;
    Writeln('PASS RunHistoryReopenPartialSelfTest: Collecting/unended Partial, Complete preserved');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryIncidentHeavyLegacySelfTest: Integer;
var
  g: TGarbos;
  i: Int64;
  lBackupFiles: TArray<string>;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lDatabaseFileName: string;
  lDirectory: string;
  lFileBytes: Int64;
  lService: TMachineOverviewHistoryService;
  lTestUtc: TDateTime;
  lUsedBytes: Int64;
begin
  g := Default(TGarbos);
  Result := 1;
  lDirectory := TPath.Combine(TPath.GetTempPath,
    'ActiveAppView-MachineOverview\history-tests');
  TDirectory.CreateDirectory(lDirectory);
  lDatabaseFileName := TPath.Combine(lDirectory,
    Format('heavy-legacy-%d-%d.db', [GetCurrentProcessId, GetTickCount64]));
  lService := nil;
  lConnection := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lDatabaseFileName, 64,
      32 * 1024 * 1024);
    lTestUtc := EncodeDate(2026, 10, 20) + EncodeTime(18, 0, 0, 0);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or
      (not lService.Diagnostics.Available) then
      raise Exception.Create('heavy legacy fixture initialization failed: ' +
        lService.Diagnostics.LastError);
    for i := 1 to 40 do
    begin
      lChange := Default(TMachineOverviewIncidentChange);
      lChange.Incident.StableId := 'heavy-legacy-' + IntToStr(i);
      lChange.Incident.StartedAtUtc := IncMinute(lTestUtc, -i);
      lChange.Incident.EndedAtUtc := IncSecond(lTestUtc, -i);
      lChange.Incident.Summary := 'preserved headline ' + IntToStr(i);
      if lService.EnqueueIncident(lChange) <>
        TMachineOverviewHistoryEnqueueResult.Queued then
        raise Exception.Create('heavy legacy incident enqueue failed');
    end;
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('heavy legacy fixture flush failed');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    lConnection.ExecSQL('UPDATE incident SET pre_context_json=' +
      '''["'' || replace(hex(zeroblob(131070)), ''00'', ''x'') || ''"]'', ' +
      'post_context_json=''[]'', evidence_state=0, context_text=' +
      'replace(hex(zeroblob(131070)), ''00'', ''x'')');
    lConnection.ExecSQL('WITH RECURSIVE samples(n) AS (SELECT 1 UNION ALL ' +
      'SELECT n+1 FROM samples WHERE n<3600) ' +
      'INSERT INTO system_sample_raw(utc_ms, monotonic_ms, provider_status, ' +
      'provider_error, cpu_available, cpu_total, physical_available_bytes, ' +
      'logical_cpu_blob) SELECT 1792519200000-n*1000, n, 0, '''', 1, 20, ' +
      '1000000, X'''' FROM samples');
    lConnection.ExecSQL('PRAGMA user_version=2');
    lConnection.ExecSQL('PRAGMA wal_checkpoint(TRUNCATE)');
    lFileBytes := QueryHistoryInt64(lConnection, 'PRAGMA page_count') *
      QueryHistoryInt64(lConnection, 'PRAGMA page_size');
    lConnection.Connected := False;
    lConfig.MaxDatabaseSizeBytes := 4 * 1024 * 1024;
    lConfig.CompactionMinimumFreeBytes := 1024 * 1024;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(10000)) or
      (not lService.Diagnostics.Available) then
      raise Exception.Create('heavy legacy reopen failed: ' +
        lService.Diagnostics.LastError);
    for i := 1 to 20 do
      if lService.EnqueueRaw(CreateHistorySystemTestSample(
        IncSecond(lTestUtc, i), 900000 + UInt64(i), 42)) <>
        TMachineOverviewHistoryEnqueueResult.Queued then
        raise Exception.Create('heavy legacy new sample enqueue failed');
    if (not lService.Flush(10000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('heavy legacy new sample flush failed');
    FreeAndNil(lService);
    lConnection.Connected := True;
    lUsedBytes := (QueryHistoryInt64(lConnection, 'PRAGMA page_count') -
      QueryHistoryInt64(lConnection, 'PRAGMA freelist_count')) *
      QueryHistoryInt64(lConnection, 'PRAGMA page_size');
    Writeln(Format('RunHistoryIncidentHeavyLegacySelfTest: used=%d budget=%d initial_file=%d new_samples=%d',
      [lUsedBytes, lConfig.MaxDatabaseSizeBytes, lFileBytes,
       QueryHistoryInt64(lConnection,
         'SELECT COUNT(*) FROM system_sample_raw WHERE monotonic_ms>900000')]));
    if (lUsedBytes > Int64(lConfig.MaxDatabaseSizeBytes)) or
      (QueryHistoryInt64(lConnection,
        'SELECT COUNT(*) FROM system_sample_raw WHERE monotonic_ms>900000') <> 20) then
    begin
      Writeln('SELFTEST FAILED: heavy legacy history exceeds budget or erases new samples');
      Exit;
    end;
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM incident WHERE evidence_state=5 AND ' +
      'pre_context_json=''[]'' AND post_context_json=''[]'' AND context_text=''''') <> 40 then
      raise Exception.Create('heavy legacy headlines or cleanup state lost');
    lConnection.Connected := False;
    lBackupFiles := TDirectory.GetFiles(lDirectory,
      ExtractFileName(lDatabaseFileName) + '.pre-migration-v2-*.bak');
    if Length(lBackupFiles) <> 1 then
      raise Exception.Create('heavy legacy verified backup missing');
    lConnection.Params.Values['Database'] := lBackupFiles[0];
    lConnection.Params.Values['OpenMode'] := 'ReadOnly';
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident') <> 40) or
      (QueryHistoryInt64(lConnection,
        'SELECT COUNT(*) FROM incident WHERE length(context_text)>100000') <> 40) then
      raise Exception.Create('heavy legacy backup did not preserve context');
    lConnection.Connected := False;
    if TFile.GetSize(lDatabaseFileName) >= lFileBytes then
      raise Exception.Create('heavy legacy startup compaction did not shrink file');
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(10000)) or
      (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('heavy legacy migrated reopen failed');
    lConnection.Params.Values['Database'] := lDatabaseFileName;
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM incident WHERE evidence_state=5') <> 40) or
      (QueryHistoryInt64(lConnection,
        'SELECT COUNT(*) FROM system_sample_raw WHERE monotonic_ms>900000') <> 20) then
      raise Exception.Create('heavy legacy migrated reopen lost rows');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lDatabaseFileName);
    for lDatabaseFileName in TDirectory.GetFiles(lDirectory,
      ExtractFileName(lDatabaseFileName) + '.pre-migration-*') do
      TFile.Delete(lDatabaseFileName);
  end;
end;

function RunHistoryCompactionSpaceSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
begin
  g := Default(TGarbos);
  Result := 1;
  lConnection := nil;
  lService := nil;
  lFileName := NewHistoryMigrationFile('compaction-space');
  try
    CreateHistoryV2Fixture(lFileName, 3);
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 32 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Compaction fixture migration failed');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lConnection.ExecSQL('UPDATE incident SET evidence_state=0, context_text=hex(zeroblob(524288))');
    lConnection.Connected := False;
    lConfig.CompactionMinimumFreeBytes := 1024;
    lConfig.DiskFreeBytesOverride := 0;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) or
      (not ContainsText(lService.Diagnostics.LastError, 'compaction deferred')) then
      raise Exception.Create('Compaction space refusal was fatal or missing diagnostics');
    if (lService.EnqueueRaw(CreateHistorySystemTestSample(
      EncodeDate(2026, 10, 20), 1, 42)) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Compaction space refusal stopped history recording');
    FreeAndNil(lService);
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM history_status WHERE ' +
      'last_error LIKE ''%compaction deferred%'' AND last_compaction_utc_ms=0') <> 1) or
      (QueryHistoryInt64(lConnection, 'PRAGMA freelist_count') = 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> 1) then
      raise Exception.Create('Deferred compaction status/free pages/sample not preserved');
    lConnection.ExecSQL('PRAGMA user_version=4');
    lConnection.Connected := False;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or lService.Diagnostics.Available or
      (not ContainsText(lService.Diagnostics.LastError, 'newer than supported')) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Newer schema was not refused');
    lConnection.Connected := True;
    if QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 4 then
      raise Exception.Create('Newer schema changed during refused open');
    lConnection.Connected := False;
    Writeln('PASS RunHistoryCompactionSpaceSelfTest: deferred nonfatal, recording continues, newer schema refused');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

procedure EnqueueHistoryBudgetRaw(const aService: TMachineOverviewHistoryService;
  const aSample: IMachineOverviewRawSample);
begin
  if aService.EnqueueRaw(aSample) <> TMachineOverviewHistoryEnqueueResult.Queued then
    raise Exception.Create('Budget raw sample enqueue failed');
end;

procedure SeedHistoryBudgetIncident(const aConnection: TFDConnection;
  const aKey: string; const aStartedUtcMs: Int64);
begin
  aConnection.ExecSQL('INSERT INTO incident(incident_key, started_utc_ms, peak_utc_ms, ended_utc_ms, ' +
    'category, severity, origin, local_display_time, summary, explanation, threshold_text, peak_value, ' +
    'provider_id, provider_freshness_ms, related_entity_ids_json, related_executable_paths_json, ' +
    'trace_status, pre_context_json, post_context_json, context_text, evidence_state) ' +
    'VALUES (?,?,?, ?,0,2,0,'''',''headline'','''','''',42,''test'',0,''[]'',''[]'',2,''[]'',''[]'','''',2)',
    [aKey, aStartedUtcMs, aStartedUtcMs, aStartedUtcMs + 1]);
  aConnection.ExecSQL('INSERT INTO incident_evidence VALUES (?,?,?,2,16384,hex(zeroblob(8192)))',
    [aKey, aStartedUtcMs, aStartedUtcMs]);
end;

function StartHistoryBudgetService(const aConfig: TMachineOverviewHistoryConfig): TMachineOverviewHistoryService;
begin
  Result := TMachineOverviewHistoryService.Create(nil, aConfig);
  try
    Result.Start;
    if (not Result.WaitUntilInitialized(5000)) or (not Result.Diagnostics.Available) then
      raise Exception.Create('Budget writer initialization failed: ' + Result.Diagnostics.LastError);
  except
    Result.Free;
    raise;
  end;
end;

function RunHistoryBudgetFloorBreachSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc: TDateTime;
  lUtcMs: Int64;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('budget-floors');
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 1);
    lService := StartHistoryBudgetService(lConfig);
    lUtc := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncMinute(lUtc, -10), 1, 42));
    EnqueueHistoryBudgetRaw(lService, CreateHistoryDiskTestSample(IncMinute(lUtc, -10)));
    EnqueueHistoryBudgetRaw(lService, CreateHistoryProcessTestSample(IncMinute(lUtc, -10)));
    if not lService.Flush(5000) then
      raise Exception.Create('Floor telemetry fixture did not flush');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Floor fixture did not stop');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lUtc := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
    lUtcMs := DateTimeToUnix(lUtc, True) * 1000;
    SeedHistoryBudgetIncident(lConnection, 'recent-complete', lUtcMs - 3600000);
    SeedHistoryBudgetIncident(lConnection, 'collecting-evidence', lUtcMs - 7200000);
    SeedHistoryBudgetIncident(lConnection, 'collecting-headline', lUtcMs - 7200001);
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    lConnection.Connected := True;
    lConnection.ExecSQL('UPDATE incident_evidence SET state=1 WHERE incident_key=''collecting-evidence''');
    lConnection.ExecSQL('UPDATE incident SET evidence_state=1 WHERE incident_key=''collecting-headline''');
    lConnection.Connected := False;
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 1, 42));
    if (not lService.Flush(5000)) or
      (lService.Diagnostics.StorageState <> TMachineOverviewStorageState.FloorBreached) then
      raise Exception.Create('Small budget did not report a floor breach');
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 2, 43));
    if (not lService.Flush(5000)) or (not lService.Diagnostics.LastCommitAvailable) or
      (lService.Diagnostics.StorageState <> TMachineOverviewStorageState.OverBudget) or
      (lService.Diagnostics.RetryCount <> 0) then
      raise Exception.Create('OverBudget stopped recording or retried a committed batch');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Floor writer did not stop');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM disk_sample_raw') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM process_top_sample') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM rollup_10s') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM rollup_1m') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <> 32768) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM history_status WHERE storage_state=3 ' +
      'AND length(storage_message)>0 AND last_floor_breach_utc_ms>0') <> 1) then
      raise Exception.Create('Floor/OverBudget state or Collecting protection not persisted');
    Writeln('PASS RunHistoryBudgetFloorBreachSelfTest: FloorBreached then OverBudget; Collecting and batches protected');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryIncidentAgeOnlySelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc: TDateTime;
  lUtcMs: Int64;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('incident-age-only');
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 64 * 1024 * 1024);
    lConfig.MaximumIncidentCount := 10;
    lService := StartHistoryBudgetService(lConfig);
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Age-only fixture did not stop');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lUtc := EncodeDate(2026, 10, 20);
    lUtcMs := DateTimeToUnix(lUtc, True) * 1000;
    // Our two incidents cannot reach the count cap or the storage budget.
    SeedHistoryBudgetIncident(lConnection, 'age-expired', lUtcMs - Int64(366) * 86400000);
    SeedHistoryBudgetIncident(lConnection, 'age-retained', lUtcMs - Int64(364) * 86400000);
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 1, 42));
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Age-only writer did not flush/stop');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE incident_key=''age-expired''') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE incident_key=''age-expired''') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE incident_key=''age-retained''') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE incident_key=''age-retained''') <> 1) then
      raise Exception.Create('Age-only retention did not delete the 366-day incident/evidence and retain the 364-day pair');
    Writeln('PASS RunHistoryIncidentAgeOnlySelfTest: 366-day pair deleted, 364-day pair retained, two incidents below cap 10');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryIncidentRetentionSelfTest: Integer;
var
  g: TGarbos;
  i: Integer;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc: TDateTime;
  lUtcMs, lStartedUtcMs: Int64;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('incident-retention');
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 64 * 1024 * 1024);
    lConfig.MaximumIncidentCount := 10;
    lService := StartHistoryBudgetService(lConfig);
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Retention fixture did not stop');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lUtc := EncodeDate(2026, 10, 20);
    lUtcMs := DateTimeToUnix(lUtc, True) * 1000;
    SeedHistoryBudgetIncident(lConnection, 'expired', lUtcMs - Int64(366) * 86400000);
    for i := 1 to 13 do
    begin
      lStartedUtcMs := lUtcMs - Int64(14-i) * 86400000;
      SeedHistoryBudgetIncident(lConnection, 'retention-' + IntToStr(i), lStartedUtcMs);
    end;
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 1, 42));
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Retention writer did not flush/stop');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident') <> 10) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence') <> 10) or
      (QueryHistoryInt64(lConnection, 'SELECT MIN(started_utc_ms) FROM incident') <> lUtcMs - Int64(10)*86400000) or
      (QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <> 10*16384) or
      (QueryHistoryInt64(lConnection, 'SELECT incidents_deleted_total FROM history_status') <> 4) then
      raise Exception.Create('Incident age/count retention did not remove oldest rows and dependent evidence');
    Writeln('PASS RunHistoryIncidentRetentionSelfTest: 365 day age, 10 row fixture cap, evidence accounting');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryMaintenanceFailureSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('maintenance-failure');
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 64 * 1024 * 1024);
    lService := StartHistoryBudgetService(lConfig);
    lUtc := EncodeDate(2026, 10, 20);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncDay(lUtc, -3), 1, 42));
    if not lService.Flush(5000) then
      raise Exception.Create('Maintenance failure fixture did not flush');
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lConnection.ExecSQL('CREATE TRIGGER fail_maintenance BEFORE DELETE ON system_sample_raw ' +
      'BEGIN SELECT RAISE(ABORT,''injected maintenance failure''); END');
    lConnection.Connected := False;
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 2, 43));
    if (not lService.Flush(5000)) or (not lService.Diagnostics.LastCommitAvailable) or
      (lService.Diagnostics.Persisted <> 2) or (lService.Diagnostics.RetryCount <> 0) or
      (not ContainsText(lService.Diagnostics.LastMaintenanceError, 'injected maintenance failure')) then
      raise Exception.Create('Maintenance failure requeued or hid a durable batch');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM history_status WHERE last_error ' +
      'LIKE ''%injected maintenance failure%''') <> 1) then
      raise Exception.Create('Maintenance rollback/error status was not retained');
    lConnection.ExecSQL('DROP TRIGGER fail_maintenance');
    lConnection.Connected := False;
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncSecond(lUtc, 1), 3, 44));
    if (not lService.Flush(5000)) or (lService.Diagnostics.Persisted <> 3) or
      (not lService.Diagnostics.LastMaintenanceError.IsEmpty) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Writer did not recover after maintenance failure');
    Writeln('PASS RunHistoryMaintenanceFailureSelfTest: durable batch, diagnostics/status error, later recovery');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryMaintenanceBoundSelfTest: Integer;
var
  g: TGarbos;
  i: Integer;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc: TDateTime;
  lRemaining: Int64;
  lSequence: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('maintenance-bound');
  lConnection := nil;
  lService := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 1);
    lService := StartHistoryBudgetService(lConfig);
    lUtc := EncodeDate(2026, 10, 20);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncDay(lUtc, -3), 1, 42));
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Bound fixture did not flush/stop');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lConnection.ExecSQL('WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM rows ' +
      'WHERE n<40000) INSERT INTO system_sample_raw(utc_ms,monotonic_ms,provider_status,' +
      'provider_error,cpu_available,cpu_total,physical_available_bytes,logical_cpu_blob) ' +
      'SELECT s.utc_ms,n,s.provider_status,s.provider_error,s.cpu_available,s.cpu_total,' +
      's.physical_available_bytes,s.logical_cpu_blob FROM rows CROSS JOIN system_sample_raw s');
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    lRemaining := 40001;
    i := 0;
    lSequence := 0;
    while (lRemaining > 0) and (i < 20) do
    begin
      Inc(i);
      Inc(lSequence);
      EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, lSequence, 43));
      if (not lService.Flush(5000)) or (lService.Diagnostics.LastMaintenanceDeleteStatements > 64) then
        raise Exception.Create('Maintenance did not respect the DELETE bound');
      lConnection.Connected := True;
      lRemaining := QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw WHERE utc_ms<' +
        IntToStr(DateTimeToUnix(lUtc, True)*1000));
      if QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw WHERE utc_ms=' +
        IntToStr(DateTimeToUnix(lUtc, True)*1000)) <> i then
        raise Exception.Create('Bounded pass removed its committed batch');
      if (i = 1) and ((lRemaining = 0) or
        (lService.Diagnostics.StorageState <> TMachineOverviewStorageState.Trimming)) then
        raise Exception.Create('Bound did not defer work with Trimming state');
      Writeln(Format('Bound cycle %d: remaining=%d deletes=%d duration_ms=%d',
        [i, lRemaining, lService.Diagnostics.LastMaintenanceDeleteStatements,
        lService.Diagnostics.LastMaintenanceDurationMs]));
      lConnection.Connected := False;
    end;
    if lRemaining <> 0 then
      raise Exception.Create('Deferred maintenance did not converge');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Bounded writer did not stop');
    Writeln('PASS RunHistoryMaintenanceBoundSelfTest: 40001 expired rows, bounded passes, continuation');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryBudgetSteadyStateSelfTest: Integer;
var
  g: TGarbos;
  i: Integer;
  lChange: TMachineOverviewIncidentChange;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lFileName: string;
  lService: TMachineOverviewHistoryService;
  lUtc, lCycleUtc: TDateTime;
  lOffset: Int64;
  lSequence: UInt64;
  lUtcMs, lUsed, lLastUsed: Int64;
  lStatus: string;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('budget-steady');
  lConnection := nil;
  lService := nil;
  try
    lUtc := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
    lConfig := CreateHistoryReliabilityConfig(lFileName, 32, 2 * 1024 * 1024);
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) then
      raise Exception.Create('Budget fixture unavailable');
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncHour(lUtc, -2), 1, 42));
    EnqueueHistoryBudgetRaw(lService, CreateHistoryDiskTestSample(IncHour(lUtc, -2)));
    EnqueueHistoryBudgetRaw(lService, CreateHistoryProcessTestSample(IncHour(lUtc, -2)));
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Budget fixture initialization failed');
    FreeAndNil(lService);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    lUtc := EncodeDate(2026, 10, 20) + EncodeTime(12, 0, 0, 0);
    lUtcMs := DateTimeToUnix(lUtc, True) * 1000;
    lConnection.ExecSQL('WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL ' +
      'SELECT n+1 FROM rows WHERE n<300) INSERT INTO incident(' +
      'incident_key, started_utc_ms, peak_utc_ms, ended_utc_ms, category, severity, origin, ' +
      'local_display_time, summary, explanation, threshold_text, peak_value, provider_id, ' +
      'provider_freshness_ms, related_entity_ids_json, related_executable_paths_json, ' +
      'trace_status, pre_context_json, post_context_json, context_text, evidence_state) ' +
      'SELECT ''budget-''||n, ? - CASE WHEN n>280 THEN 1000+n ELSE (301-n)*17280000 END, ' +
      '1,1,0,2,0,'''',''headline'','''','''',42,''test'',0,''[]'',''[]'',2,''[]'',''[]'','''',2 FROM rows',
      [lUtcMs]);
    lConnection.ExecSQL('INSERT INTO incident_evidence SELECT incident_key, started_utc_ms, ' +
      'started_utc_ms,2,16384,hex(zeroblob(8192)) FROM incident');
    lConnection.Connected := False;
    lService := TMachineOverviewHistoryService.Create(nil, lConfig);
    lService.Start;
    if (not lService.WaitUntilInitialized(5000)) or (not lService.Diagnostics.Available) then
      raise Exception.Create('Budget writer unavailable');
    lLastUsed := 0;
    lSequence := 0;
    lOffset := 0;
    for i := 1 to 20 do
    begin
      Inc(lOffset);
      Inc(lSequence);
      lCycleUtc := IncSecond(lUtc, lOffset);
      EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lCycleUtc, lSequence, 42));
      lChange := Default(TMachineOverviewIncidentChange);
      lChange.Incident.StableId := 'batch-' + IntToStr(i);
      lChange.Incident.StartedAtUtc := lCycleUtc;
      lChange.Incident.EndedAtUtc := lCycleUtc;
      if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
        raise Exception.Create('Budget incident enqueue failed');
      if not lService.Flush(5000) then
        raise Exception.Create('Budget writer did not flush');
      if lService.Diagnostics.LastMaintenanceDeleteStatements > 64 then
        raise Exception.Create('Maintenance exceeded 64 DELETE statements');
      Writeln(Format('Maintenance cycle %d: deletes=%d duration_ms=%d', [i,
        lService.Diagnostics.LastMaintenanceDeleteStatements, lService.Diagnostics.LastMaintenanceDurationMs]));
      lConnection.Connected := True;
      lUsed := (QueryHistoryInt64(lConnection, 'PRAGMA page_count') -
        QueryHistoryInt64(lConnection, 'PRAGMA freelist_count')) *
        QueryHistoryInt64(lConnection, 'PRAGMA page_size');
      Writeln(Format('Budget cycle %d: used=%d budget=%d', [i, lUsed, lConfig.MaxDatabaseSizeBytes]));
      if (i >= 5) and (lUsed > Int64(lConfig.MaxDatabaseSizeBytes)) then
        raise Exception.Create('RunHistoryBudgetSteadyStateSelfTest: evidence exceeds the shared budget');
      if QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> i + 1 then
        raise Exception.Create('Budget maintenance deleted a committed batch');
      if (i > 16) and (lUsed > lLastUsed) then
        raise Exception.Create('Last five budget passes are still growing');
      lLastUsed := lUsed;
      lConnection.Connected := False;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Budget writer did not stop');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM disk_sample_raw') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM process_top_sample') <> 3) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident') <> 320) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE incident_key=''budget-1'' AND evidence_state=4') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE incident_key=''budget-1''') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE incident_key IN ' +
      '(SELECT incident_key FROM incident WHERE incident_key LIKE ''budget-%'' ORDER BY started_utc_ms DESC LIMIT 20)') <> 20) then
      raise Exception.Create('Budget did not preserve headlines and newest evidence');
    if QueryHistoryInt64(lConnection, 'SELECT used_bytes FROM history_status') <> lUsed then
      raise Exception.Create('Budget status does not match used pages');
    GC(lQuery, TFDQuery.Create(nil), g);
    lQuery.Connection := lConnection;
    lQuery.Open('SELECT * FROM history_status');
    lStatus := lQuery.FieldByName('budget_bytes').AsWideString + ':' + lQuery.FieldByName('used_bytes').AsWideString + ':' +
      lQuery.FieldByName('storage_state').AsWideString + ':' + lQuery.FieldByName('evidence_trimmed_total').AsWideString;
    lQuery.Close;
    lConnection.Connected := False;
    FreeAndNil(lService);
    lService := StartHistoryBudgetService(lConfig);
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Budget reopen did not stop');
    lConnection.Connected := True;
    lQuery.Open('SELECT * FROM history_status');
    if lStatus <> lQuery.FieldByName('budget_bytes').AsWideString + ':' + lQuery.FieldByName('used_bytes').AsWideString + ':' +
      lQuery.FieldByName('storage_state').AsWideString + ':' + lQuery.FieldByName('evidence_trimmed_total').AsWideString then
      raise Exception.Create('Budget status did not survive reopen');
    lQuery.Close;
    Writeln('PASS RunHistoryBudgetSteadyStateSelfTest: bounded evidence, committed batches, status survives reopen');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryBackwardUtcBatchSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lService: TMachineOverviewHistoryService;
  lFileName: string;
  lUtc: TDateTime;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('backward-utc-batch');
  lService := nil;
  lConnection := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 16, 1);
    lService := StartHistoryBudgetService(lConfig);
    lUtc := TTimeZone.Local.ToUniversalTime(Now);
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(lUtc, 1000, 40));
    EnqueueHistoryBudgetRaw(lService, CreateHistorySystemTestSample(IncHour(lUtc, -2), 2000, 41));
    if not lService.Flush(5000) then
      raise Exception.Create('Backward UTC batch did not flush: ' + lService.Diagnostics.LastError);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    if QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> 2 then
      raise Exception.Create('Backward UTC step deleted a committed batch row');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Backward UTC writer did not stop');
    Writeln('PASS RunHistoryBackwardUtcBatchSelfTest: both clock-step batch rows survive a one-byte budget');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    g.Clear;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryStopWithoutFlushSelfTest: Integer;
const
  cSampleCount = 100;
  cAcceptedCount = cSampleCount * 3 + 1;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lService: TMachineOverviewHistoryService;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lFileName, lError: string;
  lUtc: TDateTime;
  i: UInt64;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('stop-without-flush');
  lService := nil;
  lConnection := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 512, 32 * 1024 * 1024);
    // Keep all accepted records pending until Stop starts our two-batch drain.
    lConfig.CommitIntervalMs := 60000;
    lService := StartHistoryBudgetService(lConfig);
    lUtc := IncMinute(TTimeZone.Local.ToUniversalTime(Now), -10);
    i := 1;
    while i <= cSampleCount do
    begin
      lUtc := IncSecond(lUtc);
      if (lService.EnqueueRaw(CreateHistorySystemTestSample(lUtc, i, 42)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistoryDiskTestSample(lUtc)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistoryProcessTestSample(lUtc)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) then
        raise Exception.Create('Stop-without-flush fixture enqueue failed');
      Inc(i);
    end;
    lChange := Default(TMachineOverviewIncidentChange);
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.HasEvidenceUpdate := True;
    lChange.Incident.StableId := 'stop-drain-evidence';
    lChange.Incident.StartedAtUtc := lUtc;
    lChange.Incident.PeakAtUtc := IncSecond(lUtc, 30);
    lChange.Incident.EndedAtUtc := IncSecond(lUtc, 60);
    lChange.Incident.Summary := 'Accepted headline survives Stop';
    lChange.Incident.Evidence.State := TMachineOverviewEvidenceState.Complete;
    lChange.Incident.Evidence.LogicalProcessorCount := 32;
    lChange.Incident.Evidence.ProcessIntervalMs := 5000;
    lChange.Incident.Evidence.SystemIntervalMs := 1000;
    SetLength(lChange.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes, 1);
    lChange.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].Kind :=
      TMachineOverviewEvidencePhaseKind.During;
    lChange.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].ProcessId := 4242;
    lChange.Incident.Evidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].CreationTime100ns := 9876543210;
    if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
      raise Exception.Create('Stop-without-flush incident enqueue failed');
    lDiagnostics := lService.Diagnostics;
    if (lDiagnostics.Accepted <> cAcceptedCount) or (lDiagnostics.Persisted <> 0) then
      raise Exception.Create('Stop-without-flush fixture did not retain all records for shutdown');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Stop-without-flush writer did not stop');
    lDiagnostics := lService.Diagnostics;
    FreeAndNil(lService);
    // Reopen through the production writer and read the committed rows/evidence.
    lService := StartHistoryBudgetService(lConfig);
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM system_sample_raw') <> cSampleCount) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM disk_sample_raw') <> cSampleCount) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM process_top_sample') <> cSampleCount * 3) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident ' +
        'WHERE incident_key=''stop-drain-evidence'' AND summary=''Accepted headline survives Stop''') <> 1) then
      raise Exception.CreateFmt('Stop without Flush lost accepted records: persisted=%d/%d queue=%d error=%s',
        [lDiagnostics.Persisted, lDiagnostics.Accepted, lDiagnostics.QueueDepth, lDiagnostics.LastError]);
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'stop-drain-evidence', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Complete) or
      (lEvidence.LogicalProcessorCount <> 32) or
      (Length(lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes) <> 1) or
      (lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].ProcessId <> 4242) or
      (lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].CreationTime100ns <> 9876543210) then
      raise Exception.Create('Stop without Flush lost accepted evidence: ' + lError);
    if (lDiagnostics.Persisted <> lDiagnostics.Accepted) or (lDiagnostics.QueueDepth <> 0) or
      (lDiagnostics.RetryCount <> 0) or (lDiagnostics.ActiveWorkerCount <> 0) or
      (not lDiagnostics.LastError.IsEmpty) or (not lDiagnostics.LastMaintenanceError.IsEmpty) then
      raise Exception.Create('Stop without Flush reported an incomplete drain or writer error: ' + lDiagnostics.LastError);
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Stop-without-flush reopened writer did not stop');
    Writeln('PASS RunHistoryStopWithoutFlushSelfTest: 301 accepted records, two batches, samples/headline/evidence durable, no writer error');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    g.Clear;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryEvidenceRetrySelfTest(const aFailCommit: Boolean): Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lService: TMachineOverviewHistoryService;
  lChange, lComplete: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lFileName, lError: string;
  lCommits, i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('evidence-retry-' + BoolToStr(aFailCommit, True));
  lService := nil;
  lConnection := nil;
  lCommits := 0;
  try
    try
      lConfig := CreateHistoryReliabilityConfig(lFileName, 1024, 32 * 1024 * 1024);
      lConfig.CommitIntervalMs := 60000;
      lChange := Default(TMachineOverviewIncidentChange);
      lChange.HasEvidenceUpdate := True;
      lChange.Incident.StableId := 'retry-key';
      lChange.Incident.StartedAtUtc := IncMinute(TTimeZone.Local.ToUniversalTime(Now), -5);
      lChange.Incident.EndedAtUtc := IncMinute(lChange.Incident.StartedAtUtc, 1);
      lChange.Incident.Summary := 'old collecting';
      lChange.Incident.Evidence.State := TMachineOverviewEvidenceState.Collecting;
      lChange.Incident.Evidence.ProcessIntervalMs := 5000;
      lChange.Incident.Evidence.SystemIntervalMs := 1000;
      lComplete := lChange;
      lComplete.Incident.Summary := 'new complete';
      lComplete.Incident.Evidence.State := TMachineOverviewEvidenceState.Complete;
      lComplete.Incident.Evidence.LogicalProcessorCount := 32;
      if aFailCommit then
        lConfig.MigrationObserver :=
          procedure(aStage: string)
          begin
            if aStage <> 'BeforeBatchCommit' then
              Exit;
            Inc(lCommits);
            if lCommits = 1 then
            begin
              if lService.EnqueueIncident(lComplete) <> TMachineOverviewHistoryEnqueueResult.Queued then
                raise Exception.Create('Fault fixture could not enqueue newer completion');
              raise Exception.Create('Injected one batch commit failure');
            end;
          end;
      lService := StartHistoryBudgetService(lConfig);
      if aFailCommit then
      begin
        if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
          raise Exception.Create('Could not enqueue initial evidence');
        // Fill the failed batch so the newer completion must cross a batch boundary.
        lChange.HasEvidenceUpdate := False;
        for i := 1 to 255 do
        begin
          lChange.Incident.StableId := 'filler-' + IntToStr(i);
          if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
            raise Exception.Create('Could not enqueue retry batch filler');
        end;
      end else begin
        if (lService.EnqueueIncident(lComplete) <> TMachineOverviewHistoryEnqueueResult.Queued) or
          (not lService.Flush(5000)) then
          raise Exception.Create('Could not persist initial completion');
        if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
          raise Exception.Create('Could not enqueue stale Collecting');
      end;
      if not lService.Flush(10000) then
        raise Exception.Create('Retry fixture did not flush: ' + lService.Diagnostics.LastError);
      GC(lConnection, TFDConnection.Create(nil), g);
      ConfigureHistoryTestConnection(lFileName, lConnection);
      if aFailCommit then
      begin
        if (lService.Diagnostics.RetryCount <> 1) or (lCommits <> 3) then
          raise Exception.Create('One failed batch was not retried exactly once');
        if QueryHistoryInt64(lConnection,
          'SELECT COUNT(*) FROM incident WHERE incident_key=''retry-key'' AND summary=''new complete''') <> 1 then
          raise Exception.Create('Failed batch retried behind newer work');
      end;
      if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'retry-key', lEvidence, lError)) or
        (lEvidence.State <> TMachineOverviewEvidenceState.Complete) or (lEvidence.LogicalProcessorCount <> 32) then
        raise Exception.Create('Stale Collecting replaced Complete evidence: ' + lError);
      if QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <>
        QueryHistoryInt64(lConnection, 'SELECT SUM(byte_count) FROM incident_evidence') then
        raise Exception.Create('Evidence byte total drifted after rollback/retry or rejected upsert');
      if not aFailCommit then
      begin
        // A stored future revision must reject even a terminal payload and preserve byte totals/state.
        lConnection.ExecSQL('UPDATE incident_evidence SET updated_utc_ms=updated_utc_ms+3600000');
        lComplete.Incident.Evidence.LogicalProcessorCount := 16;
        if (lService.EnqueueIncident(lComplete) <> TMachineOverviewHistoryEnqueueResult.Queued) or
          (not lService.Flush(5000)) then
          raise Exception.Create('Older terminal update did not flush');
        if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'retry-key', lEvidence, lError)) or
          (lEvidence.LogicalProcessorCount <> 32) then
          raise Exception.Create('Older UTC revision replaced newer evidence');
        if QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <>
          QueryHistoryInt64(lConnection, 'SELECT SUM(byte_count) FROM incident_evidence') then
          raise Exception.Create('Rejected older revision changed evidence accounting');
      end;
      if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
        raise Exception.Create('Retry fixture did not stop');
      Writeln('PASS RunHistoryEvidenceRetrySelfTest fail_commit=' + BoolToStr(aFailCommit, True));
      Result := 0;
    except
      on lException: Exception do
        Writeln('SELFTEST FAILED: evidence retry fail_commit=' + BoolToStr(aFailCommit, True) + ': ' + lException.Message);
    end;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    g.Clear;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunHistoryEvidenceRoundTripSelfTest: Integer;
var
  g: TGarbos;
  lConfig: TMachineOverviewHistoryConfig;
  lConnection: TFDConnection;
  lQuery: TFDQuery;
  lService: TMachineOverviewHistoryService;
  lChange: TMachineOverviewIncidentChange;
  lEvidence: TMachineOverviewIncidentEvidence;
  lKind: TMachineOverviewEvidencePhaseKind;
  lFileName, lError, lOriginalJson, lRecoveredJson: string;
  lUtc: TDateTime;
  i: Integer;
begin
  g := Default(TGarbos);
  Result := 1;
  lFileName := NewHistoryMigrationFile('evidence-roundtrip');
  lService := nil;
  lConnection := nil;
  try
    lConfig := CreateHistoryReliabilityConfig(lFileName, 512, 32 * 1024 * 1024);
    lConfig.ProcessSampleIntervalMs := 7000;
    lConfig.SystemSampleIntervalMs := 2000;
    lService := StartHistoryBudgetService(lConfig);
    lUtc := TTimeZone.Local.ToUniversalTime(Now);
    lChange := Default(TMachineOverviewIncidentChange);
    lChange.Kind := TMachineOverviewIncidentChangeKind.Ended;
    lChange.HasEvidenceUpdate := True;
    lChange.Incident.StableId := 'complete';
    lChange.Incident.StartedAtUtc := IncMinute(lUtc, -10);
    lChange.Incident.PeakAtUtc := IncMinute(lUtc, -9);
    lChange.Incident.EndedAtUtc := IncMinute(lUtc, -8);
    lChange.Incident.Evidence.State := TMachineOverviewEvidenceState.Complete;
    lChange.Incident.Evidence.ProcessIntervalMs := 7000;
    lChange.Incident.Evidence.SystemIntervalMs := 2000;
    lChange.Incident.Evidence.LogicalProcessorCount := 32;
    for lKind := Low(lKind) to High(lKind) do
    begin
      lChange.Incident.Evidence.Phases[lKind].Kind := lKind;
      SetLength(lChange.Incident.Evidence.Phases[lKind].Processes, 10);
      for i := 0 to 9 do
      begin
        lChange.Incident.Evidence.Phases[lKind].Processes[i].ProcessId := Cardinal(i + 1);
        lChange.Incident.Evidence.Phases[lKind].Processes[i].CreationTime100ns := 100;
        lChange.Incident.Evidence.Phases[lKind].Processes[i].DisplayName := WideChar($0141) + 'odz-worker.exe';
        lChange.Incident.Evidence.Phases[lKind].Processes[i].ImagePath := StringOfChar(WideChar($6F22), 10000);
      end;
    end;
    if (lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) then
      raise Exception.Create('Evidence INSERT failed: ' + lService.Diagnostics.LastError);
    if not TryLoadMachineOverviewIncidentEvidence(lFileName, 'complete', lEvidence, lError) then
      raise Exception.Create('Evidence read failed: ' + lError);
    if (lEvidence.State <> TMachineOverviewEvidenceState.Complete) or
      (not lEvidence.Truncated) or (lEvidence.ProcessIntervalMs <> 7000) or
      (lEvidence.Phases[TMachineOverviewEvidencePhaseKind.During].Processes[0].DisplayName <>
        WideChar($0141) + 'odz-worker.exe') then
      raise Exception.Create('Evidence Unicode/cap/interval roundtrip failed');
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lFileName, lConnection);
    GC(lQuery, TFDQuery.Create(nil), g);
    lQuery.Connection := lConnection;
    lQuery.Open('SELECT evidence_json FROM incident_evidence WHERE incident_key=''complete''');
    lOriginalJson := lQuery.Fields[0].AsWideString;
    lQuery.Close;
    if (QueryHistoryInt64(lConnection, 'SELECT MAX(byte_count) FROM incident_evidence') > 16384) or
      (QueryHistoryInt64(lConnection, 'SELECT byte_count-length(CAST(evidence_json AS BLOB)) FROM incident_evidence') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <>
       QueryHistoryInt64(lConnection, 'SELECT SUM(byte_count) FROM incident_evidence')) then
      raise Exception.Create('Store evidence byte cap/accounting failed');
    lChange.HasEvidenceUpdate := False;
    lChange.Incident.Summary := 'headline-only updated';
    lChange.Incident.Evidence := Default(TMachineOverviewIncidentEvidence);
    lChange.Incident.Evidence.State := TMachineOverviewEvidenceState.Collecting;
    if (lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) then
      raise Exception.Create('Headline-only update failed');
    lQuery.Open('SELECT evidence_json FROM incident_evidence WHERE incident_key=''complete''');
    if lQuery.Fields[0].AsWideString <> lOriginalJson then
      raise Exception.Create('Headline-only update rewrote finalized evidence');
    lQuery.Close;
    if (QueryHistoryInt64(lConnection, 'SELECT evidence_state FROM incident WHERE incident_key=''complete''') <> 2) or
      (QueryHistoryInt64(lConnection, 'SELECT state FROM incident_evidence WHERE incident_key=''complete''') <> 2) then
      raise Exception.Create('Headline-only update changed finalized state');
    lChange.Incident.StableId := 'collecting';
    lChange.Incident.EndedAtUtc := 0;
    lChange.HasEvidenceUpdate := True;
    lChange.Incident.Evidence.ProcessIntervalMs := 5000;
    lChange.Incident.Evidence.SystemIntervalMs := 1000;
    if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
      raise Exception.Create('Collecting persistence failed');
    // Cross the 200-row recovery chunk, include the gap cap and malformed bytes.
    for i := 0 to 200 do
    begin
      lChange.Incident.StableId := 'recovery-' + IntToStr(i);
      lChange.Incident.Evidence.Gaps := nil;
      if i = 0 then
      begin
        SetLength(lChange.Incident.Evidence.Gaps, 16);
        for var j := 0 to 15 do
        begin
          lChange.Incident.Evidence.Gaps[j].StartUtc := lUtc;
          lChange.Incident.Evidence.Gaps[j].EndUtc := lUtc;
          lChange.Incident.Evidence.Gaps[j].Reason := TMachineOverviewEvidenceGapReason.ProviderUnavailable;
        end;
      end;
      if lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued then
        raise Exception.Create('Recovery chunk fixture enqueue failed');
    end;
    if (not lService.Flush(5000)) or
      (lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped) then
      raise Exception.Create('Collecting persistence failed');
    FreeAndNil(lService);
    lConnection.ExecSQL('UPDATE incident_evidence SET evidence_json=''invalid'', byte_count=7 ' +
      'WHERE incident_key=''recovery-1''');
    lConnection.ExecSQL('UPDATE history_status SET evidence_bytes=' +
      '(SELECT SUM(byte_count) FROM incident_evidence)');
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'collecting', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Partial) then
      raise Exception.Create('Evidence reopen state recovery failed: ' + lError);
    if (Length(lEvidence.Gaps) <> 1) or
      (lEvidence.Gaps[0].Reason <> TMachineOverviewEvidenceGapReason.CollectionStopped) or
      (lEvidence.Gaps[0].EndUtc < lEvidence.Gaps[0].StartUtc) then
      raise Exception.Create('Reopen omitted the CollectionStopped gap');
    lRecoveredJson := MachineOverviewEvidenceToJson(lEvidence);
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'complete', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Complete) then
      raise Exception.Create('Evidence reopen state recovery failed: ' + lError);
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'recovery-0', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Partial) or
      (Length(lEvidence.Gaps) <> 16) or (lEvidence.GapsOmitted <> 1) then
      raise Exception.Create('Reopen violated the 16-gap/gaps_omitted contract: ' + lError);
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'recovery-200', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Partial) or (Length(lEvidence.Gaps) <> 1) then
      raise Exception.Create('Recovery did not finish all bounded chunks: ' + lError);
    if TryLoadMachineOverviewIncidentEvidence(lFileName, 'recovery-1', lEvidence, lError) or
      lError.IsEmpty or (Pos('recovery-1', lService.Diagnostics.LastError) = 0) then
      raise Exception.Create('Malformed recovery payload did not surface explicit diagnostics');
    lConnection.Connected := True;
    if (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE state=1') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence ' +
        'WHERE incident_key=''recovery-1'' AND state=3 AND evidence_json=''invalid''') <> 1) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident WHERE evidence_state=1') <> 0) then
      raise Exception.Create('Recovery lost malformed bytes or left inconsistent Collecting states');
    if (QueryHistoryInt64(lConnection, 'SELECT MAX(byte_count) FROM incident_evidence') > 16384) or
      (QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence ' +
        'WHERE byte_count<>length(CAST(evidence_json AS BLOB))') <> 0) or
      (QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <>
       QueryHistoryInt64(lConnection, 'SELECT SUM(byte_count) FROM incident_evidence')) then
      raise Exception.Create('Recovery violated evidence size/byte accounting');
    lChange.Incident.StableId := 'collecting';
    if (lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) or
      (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'collecting', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Partial) then
      raise Exception.Create('Stale Collecting replaced recovered Partial: ' + lError);
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Evidence restart did not stop');
    FreeAndNil(lService);
    // Partial evidence must be stable across later opens, including the omitted-gap count.
    for i := 1 to 2 do
    begin
      lConnection.Connected := False;
      lService := StartHistoryBudgetService(lConfig);
      if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'collecting', lEvidence, lError)) or
        (lEvidence.State <> TMachineOverviewEvidenceState.Partial) or
        (Length(lEvidence.Gaps) <> 1) or (lEvidence.GapsOmitted <> 0) or
        (MachineOverviewEvidenceToJson(lEvidence) <> lRecoveredJson) then
        raise Exception.Create('Repeated reopen duplicated/changed CollectionStopped gap: ' + lError);
      if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'recovery-0', lEvidence, lError)) or
        (Length(lEvidence.Gaps) <> 16) or (lEvidence.GapsOmitted <> 1) then
        raise Exception.Create('Repeated reopen incremented omitted stopped gaps: ' + lError);
      lConnection.Connected := True;
      if QueryHistoryInt64(lConnection, 'SELECT evidence_bytes FROM history_status') <>
        QueryHistoryInt64(lConnection, 'SELECT SUM(byte_count) FROM incident_evidence') then
        raise Exception.Create('Repeated reopen changed evidence byte accounting');
      if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
        raise Exception.Create('Repeated-reopen writer did not stop');
      FreeAndNil(lService);
      Writeln(Format('Repeated reopen %d: gap and byte totals stable', [i]));
    end;
    Writeln('PASS repeated reopen: one unchanged CollectionStopped gap, no omitted-gap or byte-total drift');
    lConnection.Connected := True;
    // Model the exact S2 trimming transition; its deletion policy has its own retained tests.
    lConnection.ExecSQL('DELETE FROM incident_evidence WHERE incident_key=''complete''');
    lConnection.ExecSQL('UPDATE incident SET evidence_state=4 WHERE incident_key=''complete''');
    lConnection.Connected := False;
    lService := StartHistoryBudgetService(lConfig);
    lChange.Incident.StableId := 'complete';
    lChange.Incident.EndedAtUtc := IncMinute(lUtc, -8);
    lChange.HasEvidenceUpdate := False;
    if (lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) then
      raise Exception.Create('Trimmed headline update failed');
    if (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'complete', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Trimmed) then
      raise Exception.Create('Headline-only update undid Trimmed: ' + lError);
    lChange.HasEvidenceUpdate := True;
    if (lService.EnqueueIncident(lChange) <> TMachineOverviewHistoryEnqueueResult.Queued) or
      (not lService.Flush(5000)) or
      (not TryLoadMachineOverviewIncidentEvidence(lFileName, 'complete', lEvidence, lError)) or
      (lEvidence.State <> TMachineOverviewEvidenceState.Trimmed) then
      raise Exception.Create('Evidence-bearing replay undid Trimmed: ' + lError);
    lConnection.Connected := True;
    if QueryHistoryInt64(lConnection, 'SELECT COUNT(*) FROM incident_evidence WHERE incident_key=''complete''') <> 0 then
      raise Exception.Create('Headline-only update resurrected trimmed evidence');
    lConnection.ExecSQL('UPDATE incident_evidence SET evidence_json=''invalid'' WHERE incident_key=''collecting''');
    if TryLoadMachineOverviewIncidentEvidence(lFileName, 'collecting', lEvidence, lError) or lError.IsEmpty then
      raise Exception.Create('Invalid evidence did not return an explicit read error');
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      raise Exception.Create('Evidence service did not stop');
    Writeln('PASS RunHistoryEvidenceRoundTripSelfTest: Unicode, 16 KiB, state sync, headline-only, Trimmed, Partial/stopped gap, 202-row recovery, 16-gap cap, decode diagnostics');
    Result := 0;
  finally
    if Assigned(lConnection) then
      lConnection.Connected := False;
    lService.Free;
    g.Clear;
    DeleteHistoryReliabilityFiles(lFileName);
  end;
end;

function RunMachineOverviewHistorySelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cMachineOverviewSQLiteBindingSelfTestArg) then
    Exit(RunSQLiteBindingSelfTest);
  if not SameText(aArg, cMachineOverviewHistorySelfTestArg) then
    Exit;
  try
    Result := RunHistoryStopWithoutFlushSelfTest;
    if Result <> 0 then
      Exit;
    Result := RunHistoryEvidenceRetrySelfTest(True) + RunHistoryEvidenceRetrySelfTest(False);
    Result := Result + RunHistoryEvidenceRoundTripSelfTest;
    if Result <> 0 then
      Exit;
    Result := RunHistoryBackwardUtcBatchSelfTest;
    if Result = 0 then
      Result := RunHistoryBudgetSteadyStateSelfTest;
    if Result = 0 then
      Result := RunHistoryBudgetFloorBreachSelfTest;
    if Result = 0 then
      Result := RunHistoryIncidentAgeOnlySelfTest;
    if Result = 0 then
      Result := RunHistoryIncidentRetentionSelfTest;
    if Result = 0 then
      Result := RunHistoryMaintenanceFailureSelfTest;
    if Result = 0 then
      Result := RunHistoryMaintenanceBoundSelfTest;
    if Result = 0 then
      Result := RunHistoryIncidentHeavyLegacySelfTest;
    if Result = 0 then
      Result := RunHistoryMigrationBackupSpaceSelfTest;
    if Result = 0 then
      Result := RunHistoryMigrationResumeSelfTest;
    if Result = 0 then
      Result := RunHistoryMigrationCopyCancelSelfTest;
    if Result = 0 then
      Result := RunHistoryReopenPartialSelfTest;
    if Result = 0 then
      Result := RunHistoryCompactionSpaceSelfTest;
    if Result = 0 then
      Result := RunLogicalProcessorBlobSelfTest;
    if Result = 0 then
      Result := RunHistoryConfigSelfTest;
    if Result = 0 then
      Result := RunHistoryBacklogSelfTest;
    if Result = 0 then
      Result := RunHistoryStoreSelfTest;
    if Result = 0 then
      Result := RunHistoryMigrationSelfTest;
    if Result = 0 then
      Result := RunHistoryV1IncidentMigrationSelfTest;
    if Result = 0 then
      Result := RunHistoryBusyBacklogSelfTest;
    if Result = 0 then
      Result := RunHistoryLockedShutdownSelfTest;
    if Result = 0 then
      Result := RunHistoryCorruptionSelfTest;
    if Result = 0 then
      Result := RunHistoryStorageCapSelfTest;
    if Result = 0 then
      Result := RunHistoryPipelineIntegrationSelfTest;
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

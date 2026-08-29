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
  SetLength(lSample.Measurements, Length(cNames));
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
  if lQuery.Fields[0].AsInteger <> 2 then
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
      '''4242:9876543210'' AND image_path=''C:\Test\history-test.exe''') <> 3) then
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
      'SELECT COUNT(*) FROM system_sample_raw') <> 0 then
    begin
      Writeln('SELFTEST FAILED: history writer bypassed transactional batching');
      Exit;
    end;
      lConnection.Connected := False;
      lStage := 'enqueue provider and retention samples';
      if (lService.EnqueueRaw(CreateHistorySystemTestSample(
          IncDay(lTestUtc, -400), 1, 1)) <>
          TMachineOverviewHistoryEnqueueResult.Queued) or
        (lService.EnqueueRaw(CreateHistorySystemTestSample(
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
    if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 2) or
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
begin
  if TFile.Exists(aDatabaseFileName + '-shm') then
    TFile.Delete(aDatabaseFileName + '-shm');
  if TFile.Exists(aDatabaseFileName + '-wal') then
    TFile.Delete(aDatabaseFileName + '-wal');
  if TFile.Exists(aDatabaseFileName) then
    TFile.Delete(aDatabaseFileName);
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
    if (QueryHistoryInt64(lConnection, 'PRAGMA user_version') <> 2) or
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
    if lDiagnostics.StorageCapDropped = 0 then
    begin
      Writeln('SELFTEST FAILED: storage cap did not evict telemetry');
      Exit;
    end;
    if lService.Stop(5000) <> TMachineOverviewShutdownResult.Stopped then
      Exit;
    GC(lConnection, TFDConnection.Create(nil), g);
    ConfigureHistoryTestConnection(lDatabaseFileName, lConnection);
    if QueryHistoryInt64(lConnection,
      'SELECT COUNT(*) FROM system_sample_raw') <> 0 then
    begin
      Writeln('SELFTEST FAILED: storage cap left raw telemetry above the bound');
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

function RunMachineOverviewHistorySelfTests(const aArg: string): Integer;
begin
  Result := -1;
  if SameText(aArg, cMachineOverviewSQLiteBindingSelfTestArg) then
    Exit(RunSQLiteBindingSelfTest);
  if not SameText(aArg, cMachineOverviewHistorySelfTestArg) then
    Exit;
  try
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

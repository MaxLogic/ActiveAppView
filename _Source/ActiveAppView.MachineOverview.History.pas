unit ActiveAppView.MachineOverview.History;

interface

uses
  System.SysUtils,
  ActiveAppView.MachineOverview.Incidents,
  ActiveAppView.MachineOverview.Pipeline,
  ActiveAppView.MachineOverview.Settings,
  ActiveAppView.MachineOverview.Types;

type
  TMachineOverviewHistoryItemKind = (RawSample, Incident);
  TMachineOverviewHistoryEnqueueResult = (Queued, Dropped, Stopped);

  TMachineOverviewHistoryConfig = record
    Enabled: Boolean;
    DatabaseFileName: string;
    CommitIntervalMs: Cardinal;
    QueueCapacity: Integer;
    RawRetentionHours: Integer;
    Rollup10sRetentionDays: Integer;
    Rollup1mRetentionDays: Integer;
    MaxDatabaseSizeBytes: UInt64;
    BusyTimeoutMs: Cardinal;
    class function FromSettings(const aSettings: TMachineOverviewSettings;
      const aDatabaseFileName: string): TMachineOverviewHistoryConfig; static;
  end;

  TMachineOverviewHistoryItem = record
    IncidentChange: TMachineOverviewIncidentChange;
    Kind: TMachineOverviewHistoryItemKind;
    Sample: IMachineOverviewRawSample;
    class function CreateRaw(const aSample: IMachineOverviewRawSample):
      TMachineOverviewHistoryItem; static;
    class function CreateIncident(
      const aChange: TMachineOverviewIncidentChange):
      TMachineOverviewHistoryItem; static;
    class function CreateIncidentMarker: TMachineOverviewHistoryItem; static;
  end;

  TMachineOverviewHistoryBacklogDiagnostics = record
    Count: Integer;
    RawDropped: Int64;
    IncidentDropped: Int64;
  end;

  TMachineOverviewHistoryBacklog = class
  private
    fState: TObject;
  public
    constructor Create(const aCapacity: Integer);
    destructor Destroy; override;
    function Enqueue(const aItem: TMachineOverviewHistoryItem):
      TMachineOverviewHistoryEnqueueResult;
    function PeekBatch(const aMaximumCount: Integer):
      TArray<TMachineOverviewHistoryItem>;
    procedure RemoveFirst(const aCount: Integer);
    function Diagnostics: TMachineOverviewHistoryBacklogDiagnostics;
  end;

  TMachineOverviewHistoryDiagnostics = record
    Available: Boolean;
    Initialized: Boolean;
    ActiveWorkerCount: Integer;
    WriterThreadId: Cardinal;
    Accepted: Int64;
    Persisted: Int64;
    QueueDepth: Integer;
    RawDropped: Int64;
    IncidentDropped: Int64;
    RetryCount: Int64;
    StorageCapDropped: Int64;
    LastCommitAvailable: Boolean;
    LastCommitDurationMs: UInt64;
    LastError: string;
    HydratedIncidentCount: Integer;
  end;

  TMachineOverviewHistoryService = class
  private
    fState: TObject;
  public
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aConfig: TMachineOverviewHistoryConfig);
    destructor Destroy; override;
    procedure Start;
    function Stop(const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
    function EnqueueRaw(const aSample: IMachineOverviewRawSample):
      TMachineOverviewHistoryEnqueueResult;
    function EnqueueIncident(const aChange: TMachineOverviewIncidentChange):
      TMachineOverviewHistoryEnqueueResult;
    function Flush(const aTimeoutMs: Cardinal): Boolean;
    function WaitUntilInitialized(const aTimeoutMs: Cardinal): Boolean;
    function Diagnostics: TMachineOverviewHistoryDiagnostics;
  end;

function MachineOverviewHistoryDatabasePath(
  const aInstallDirectory: string): string;
function PackMachineOverviewLogicalProcessors(
  const aValues: TArray<TMachineOverviewOptionalDouble>): TBytes;
function TryUnpackMachineOverviewLogicalProcessors(const aData: TBytes;
  out aValues: TArray<TMachineOverviewOptionalDouble>): Boolean;
function TryLoadMachineOverviewIncidents(const aDatabaseFileName: string;
  const aEarliestUtc: TDateTime; const aMaximumCount: Integer;
  out aIncidents: TArray<TMachineOverviewIncident>;
  out aError: string): Boolean;

implementation

uses
  System.Classes, System.DateUtils, System.Generics.Collections, System.IOUtils,
  System.JSON, System.Math, System.StrUtils, System.SyncObjs,
  Winapi.Windows,
  Data.DB, FireDAC.Comp.Client, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef, FireDAC.Phys.SQLiteWrapper,
  FireDAC.Stan.Async, FireDAC.Stan.Def,
  ActiveAppView.MachineOverview.Providers;

type
  TMachineOverviewHistoryBacklogState = class
  private
    fCapacity: Integer;
    fIncidentDropped: Int64;
    fItems: TList<TMachineOverviewHistoryItem>;
    fLock: TCriticalSection;
    fRawDropped: Int64;
  public
    constructor Create(const aCapacity: Integer);
    destructor Destroy; override;
  end;

  TMachineOverviewHistoryDiskRow = record
    ActiveAvailable: Boolean;
    ActivePercent: Double;
    DiskId: string;
    DisplayName: string;
    LatencyAvailable: Boolean;
    LatencyMax60s: Double;
    LatencyMaxAvailable: Boolean;
    LatencyMs: Double;
    QueueAvailable: Boolean;
    QueueLength: Double;
    ReadAvailable: Boolean;
    ReadMBPerSecond: Double;
    VolumeSummary: string;
    WriteAvailable: Boolean;
    WriteMBPerSecond: Double;
  end;

  TMachineOverviewHistoryStore = class
  private
    fConfig: TMachineOverviewHistoryConfig;
    fConnection: TFDConnection;
    fDatabaseExisted: Boolean;
    fDiskInsert: TFDQuery;
    fDriverLink: TFDPhysSQLiteDriverLink;
    fIncidentUpsert: TFDQuery;
    fProcessInsert: TFDQuery;
    fRollup10s: TFDQuery;
    fRollup1m: TFDQuery;
    fSystemInsert: TFDQuery;
    procedure ApplyRetention(const aNowUtcMs: Int64);
    function ApplyStorageCap: Integer;
    procedure ConfigureConnection;
    procedure CreateOrMigrateSchema;
    procedure EnsureIncidentColumn(const aName, aDefinition: string);
    function LoadIncidents(const aEarliestUtc: TDateTime;
      const aMaximumCount: Integer): TArray<TMachineOverviewIncident>;
    procedure PrepareStatements;
    procedure WriteRollup(const aQuery: TFDQuery; const aBucketUtcMs: Int64;
      const aCpuAvailable: Boolean; const aCpuValue: Double;
      const aPhysicalAvailable: Double);
    procedure WriteDiskSample(const aSample: IMachineOverviewRawSample);
    procedure WriteIncident(const aIncident: TMachineOverviewIncident);
    procedure WriteProcessSample(const aSample: IMachineOverviewRawSample);
    procedure WriteSystemSample(const aSample: IMachineOverviewRawSample);
  public
    constructor Create(const aConfig: TMachineOverviewHistoryConfig);
    destructor Destroy; override;
    function WriteBatch(const aItems: TArray<TMachineOverviewHistoryItem>):
      Integer;
  end;

  TMachineOverviewHistoryServiceState = class;

  TMachineOverviewHistoryWorker = class(TThread)
  private
    fServiceState: TMachineOverviewHistoryServiceState;
  protected
    procedure Execute; override;
  public
    constructor Create(const aServiceState: TMachineOverviewHistoryServiceState);
  end;

  TMachineOverviewHistoryServiceState = class
  public
    Backlog: TMachineOverviewHistoryBacklog;
    Config: TMachineOverviewHistoryConfig;
    DiagnosticsData: TMachineOverviewHistoryDiagnostics;
    DiagnosticsLock: TCriticalSection;
    DrainedEvent: TEvent;
    FlushRequested: Integer;
    InitializedEvent: TEvent;
    InFlightCount: Integer;
    LifecycleLock: TCriticalSection;
    Pipeline: TMachineOverviewPipeline;
    Started: Boolean;
    StopDeadlineMs: UInt64;
    Stopping: Integer;
    WakeEvent: TEvent;
    Worker: TMachineOverviewHistoryWorker;
    constructor Create(const aPipeline: TMachineOverviewPipeline;
      const aConfig: TMachineOverviewHistoryConfig);
    destructor Destroy; override;
    procedure MarkAccepted;
    procedure MarkCommitFailure(const aError: string);
    procedure MarkCommitSuccess(const aCount: Integer;
      const aDurationMs: UInt64; const aStorageCapDropped: Integer);
    procedure MarkInitialized(const aAvailable: Boolean;
      const aError: string);
    procedure MarkIncidentHydration(const aCount: Integer);
    procedure MarkWorkerStarted;
    procedure MarkWorkerStopped;
    procedure PublishDiagnostics;
  end;

const
  cMachineOverviewHistoryDatabaseFileName = 'MachineOverviewHistory.db';
  cMachineOverviewHistorySchemaVersion = 2;
  cMachineOverviewHistoryWriteBatchSize = 256;
  cMachineOverviewHistoryRetryDelayMs = 250;
  cMachineOverviewSQLiteDriverId = 'SQLite_MachineOverview';

function GetHistoryBacklogState(const aState: TObject):
  TMachineOverviewHistoryBacklogState;
begin
  Result := aState as TMachineOverviewHistoryBacklogState;
end;

function GetHistoryServiceState(const aState: TObject):
  TMachineOverviewHistoryServiceState;
begin
  Result := aState as TMachineOverviewHistoryServiceState;
end;

procedure FindHistoryMeasurement(
  const aSample: TMachineOverviewProviderSample; const aName: string;
  out aMeasurement: TMachineOverviewMeasurement);
var
  lMeasurement: TMachineOverviewMeasurement;
begin
  for lMeasurement in aSample.Measurements do
    if SameText(lMeasurement.Name, aName) then
    begin
      aMeasurement := lMeasurement;
      Exit;
    end;
  aMeasurement := Default(TMachineOverviewMeasurement);
end;

function HistoryUtcMilliseconds(const aValue: TDateTime): Int64;
begin
  if aValue <= 0 then
    Exit(0);
  Result := (DateTimeToUnix(aValue, True) * 1000) + MilliSecondOf(aValue);
end;

function HistoryDateTimeFromMilliseconds(const aValue: Int64): TDateTime;
begin
  if aValue <= 0 then
    Exit(0);
  Result := IncMilliSecond(UnixToDateTime(aValue div 1000, True),
    aValue mod 1000);
end;

function HistoryIncidentCategoryFromOrdinal(const aOrdinal: Integer):
  TMachineOverviewIncidentCategory;
begin
  case aOrdinal of
    0: Result := TMachineOverviewIncidentCategory.HighCpu;
    1: Result := TMachineOverviewIncidentCategory.HotLogicalProcessors;
    2: Result := TMachineOverviewIncidentCategory.DpcInterrupt;
    3: Result := TMachineOverviewIncidentCategory.ForegroundResponse;
    4: Result := TMachineOverviewIncidentCategory.DwmFrames;
    5: Result := TMachineOverviewIncidentCategory.MemoryPressure;
    6: Result := TMachineOverviewIncidentCategory.DiskPressure;
    7: Result := TMachineOverviewIncidentCategory.GpuSaturation;
    8: Result := TMachineOverviewIncidentCategory.ThermalWarning;
    9: Result := TMachineOverviewIncidentCategory.ProviderHealth;
    10: Result := TMachineOverviewIncidentCategory.PipelineOverload;
    11: Result := TMachineOverviewIncidentCategory.UserMarked;
  else
    raise EConvertError.CreateFmt('Invalid incident category %d',
      [aOrdinal]);
  end;
end;

function HistorySeverityFromOrdinal(const aOrdinal: Integer):
  TMachineOverviewSeverity;
begin
  case aOrdinal of
    0: Result := TMachineOverviewSeverity.Normal;
    1: Result := TMachineOverviewSeverity.Notice;
    2: Result := TMachineOverviewSeverity.Warning;
    3: Result := TMachineOverviewSeverity.Critical;
    4: Result := TMachineOverviewSeverity.Unavailable;
  else
    raise EConvertError.CreateFmt('Invalid incident severity %d',
      [aOrdinal]);
  end;
end;

function HistoryIncidentOriginFromOrdinal(const aOrdinal: Integer):
  TMachineOverviewIncidentOrigin;
begin
  case aOrdinal of
    0: Result := TMachineOverviewIncidentOrigin.Automatic;
    1: Result := TMachineOverviewIncidentOrigin.UserMarked;
  else
    raise EConvertError.CreateFmt('Invalid incident origin %d', [aOrdinal]);
  end;
end;

function HistoryTraceStatusFromOrdinal(const aOrdinal: Integer):
  TMachineOverviewIncidentTraceStatus;
begin
  case aOrdinal of
    0: Result := TMachineOverviewIncidentTraceStatus.NotRequested;
    1: Result := TMachineOverviewIncidentTraceStatus.Requested;
    2: Result := TMachineOverviewIncidentTraceStatus.Captured;
    3: Result := TMachineOverviewIncidentTraceStatus.Failed;
    4: Result := TMachineOverviewIncidentTraceStatus.Unavailable;
  else
    raise EConvertError.CreateFmt('Invalid incident trace status %d',
      [aOrdinal]);
  end;
end;

function HistoryFieldInt64(const aField: TField): Int64;
begin
  if (not Assigned(aField)) or
    (not TryStrToInt64(aField.AsString, Result)) then
    raise EConvertError.Create('Invalid 64-bit history value');
end;

function HistoryNullableFieldInt64(const aField: TField): Int64;
begin
  if (not Assigned(aField)) or aField.IsNull or aField.AsString.IsEmpty then
    Exit(0);
  Result := HistoryFieldInt64(aField);
end;

function HistoryStringArrayToJson(const aValues: TArray<string>): string;
var
  lArray: TJSONArray;
  lValue: string;
begin
  lArray := TJSONArray.Create;
  try
    for lValue in aValues do
      lArray.Add(lValue);
    Result := lArray.ToJSON;
  finally
    lArray.Free;
  end;
end;

function TryHistoryStringArrayFromJson(const aText: string;
  out aValues: TArray<string>): Boolean;
var
  i: Integer;
  lArray: TJSONArray;
  lJsonValue: TJSONValue;
begin
  aValues := nil;
  lJsonValue := TJSONObject.ParseJSONValue(aText);
  try
    Result := lJsonValue is TJSONArray;
    if not Result then
      Exit;
    lArray := lJsonValue as TJSONArray;
    SetLength(aValues, lArray.Count);
    for i := 0 to lArray.Count - 1 do
      aValues[i] := lArray.Items[i].Value;
  finally
    lJsonValue.Free;
  end;
end;

function HistoryContextToJson(
  const aValues: TArray<TMachineOverviewIncidentContext>): string;
var
  lArray: TJSONArray;
  lObject: TJSONObject;
  lValue: TMachineOverviewIncidentContext;
begin
  lArray := TJSONArray.Create;
  try
    for lValue in aValues do
    begin
      lObject := TJSONObject.Create;
      lObject.AddPair('utc_ms',
        TJSONNumber.Create(HistoryUtcMilliseconds(lValue.CapturedAtUtc)));
      lObject.AddPair('monotonic_ms',
        TJSONNumber.Create(lValue.CapturedAtMonotonicMs));
      lObject.AddPair('provider_id', lValue.ProviderId);
      lObject.AddPair('summary', lValue.Summary);
      lArray.AddElement(lObject);
    end;
    Result := lArray.ToJSON;
  finally
    lArray.Free;
  end;
end;

function TryHistoryContextFromJson(const aText: string;
  out aValues: TArray<TMachineOverviewIncidentContext>): Boolean;
var
  i: Integer;
  lArray: TJSONArray;
  lJsonValue: TJSONValue;
  lMonotonicMs: UInt64;
  lObject: TJSONObject;
  lUtcMs: Int64;
  lValue: TJSONValue;
begin
  aValues := nil;
  lJsonValue := TJSONObject.ParseJSONValue(aText);
  try
    Result := lJsonValue is TJSONArray;
    if not Result then
      Exit;
    lArray := lJsonValue as TJSONArray;
    SetLength(aValues, lArray.Count);
    for i := 0 to lArray.Count - 1 do
    begin
      if not (lArray.Items[i] is TJSONObject) then
        Exit(False);
      lObject := lArray.Items[i] as TJSONObject;
      lValue := lObject.GetValue('utc_ms');
      if (not Assigned(lValue)) or
        (not TryStrToInt64(lValue.Value, lUtcMs)) then
        Exit(False);
      lValue := lObject.GetValue('monotonic_ms');
      if (not Assigned(lValue)) or
        (not TryStrToUInt64(lValue.Value, lMonotonicMs)) then
        Exit(False);
      aValues[i].CapturedAtUtc :=
        HistoryDateTimeFromMilliseconds(lUtcMs);
      aValues[i].CapturedAtMonotonicMs := lMonotonicMs;
      lValue := lObject.GetValue('provider_id');
      if Assigned(lValue) then
        aValues[i].ProviderId := lValue.Value;
      lValue := lObject.GetValue('summary');
      if Assigned(lValue) then
        aValues[i].Summary := lValue.Value;
    end;
    Result := True;
  finally
    lJsonValue.Free;
  end;
end;

function HistoryLogicalProcessors(
  const aSample: TMachineOverviewProviderSample):
  TArray<TMachineOverviewOptionalDouble>;
const
  cLogicalPrefix = 'cpu_logical:';
var
  lIndex: Integer;
  lMaximumIndex: Integer;
  lMeasurement: TMachineOverviewMeasurement;
begin
  lMaximumIndex := -1;
  for lMeasurement in aSample.Measurements do
    if StartsText(cLogicalPrefix, lMeasurement.Name) and
      TryStrToInt(Copy(lMeasurement.Name, Length(cLogicalPrefix) + 1,
        MaxInt), lIndex) and (lIndex >= 0) then
      lMaximumIndex := Max(lMaximumIndex, lIndex);
  SetLength(Result, lMaximumIndex + 1);
  for lMeasurement in aSample.Measurements do
    if StartsText(cLogicalPrefix, lMeasurement.Name) and
      TryStrToInt(Copy(lMeasurement.Name, Length(cLogicalPrefix) + 1,
        MaxInt), lIndex) and (lIndex >= 0) and
      (lIndex < Length(Result)) then
    begin
      Result[lIndex].Available := lMeasurement.Available;
      if lMeasurement.Available then
        Result[lIndex].Value := lMeasurement.Value;
    end;
end;

constructor TMachineOverviewHistoryStore.Create(
  const aConfig: TMachineOverviewHistoryConfig);
begin
  inherited Create;
  fConfig := aConfig;
  try
    ConfigureConnection;
    CreateOrMigrateSchema;
    PrepareStatements;
  except
    FreeAndNil(fRollup1m);
    FreeAndNil(fRollup10s);
    FreeAndNil(fIncidentUpsert);
    FreeAndNil(fProcessInsert);
    FreeAndNil(fDiskInsert);
    FreeAndNil(fSystemInsert);
    FreeAndNil(fConnection);
    fDriverLink := nil;
    raise;
  end;
end;

destructor TMachineOverviewHistoryStore.Destroy;
begin
  FreeAndNil(fRollup1m);
  FreeAndNil(fRollup10s);
  FreeAndNil(fIncidentUpsert);
  FreeAndNil(fProcessInsert);
  FreeAndNil(fDiskInsert);
  FreeAndNil(fSystemInsert);
  FreeAndNil(fConnection);
  fDriverLink := nil;
  inherited Destroy;
end;

procedure TMachineOverviewHistoryStore.ConfigureConnection;
var
  lDirectory: string;
  lOpenMode: string;
begin
  lDirectory := ExtractFilePath(fConfig.DatabaseFileName);
  if not lDirectory.IsEmpty then
    TDirectory.CreateDirectory(lDirectory);
  fDatabaseExisted := TFile.Exists(fConfig.DatabaseFileName);
  if fDatabaseExisted then
    lOpenMode := 'ReadWrite'
  else
    lOpenMode := 'CreateUTF8';
  fConnection := TFDConnection.Create(nil);
  fDriverLink := TFDPhysSQLiteDriverLink.Create(fConnection);
  fDriverLink.DriverID := cMachineOverviewSQLiteDriverId;
  fDriverLink.EngineLinkage := slDynamic;
  fDriverLink.VendorLib := TPath.Combine(ExtractFilePath(ParamStr(0)),
    'sqlite3.dll');
  fConnection.LoginPrompt := False;
  fConnection.ResourceOptions.SilentMode := True;
  fConnection.UpdateOptions.LockWait := True;
  fConnection.Params.Values['DriverID'] := cMachineOverviewSQLiteDriverId;
  fConnection.Params.Values['Database'] := fConfig.DatabaseFileName;
  fConnection.Params.Values['OpenMode'] := lOpenMode;
  fConnection.Params.Values['LockingMode'] := 'Normal';
  fConnection.Params.Values['SharedCache'] := 'False';
  fConnection.Params.Values['BusyTimeout'] := IntToStr(fConfig.BusyTimeoutMs);
  fConnection.Connected := True;
end;

procedure TMachineOverviewHistoryStore.EnsureIncidentColumn(
  const aName, aDefinition: string);
var
  lExists: Boolean;
  lQuery: TFDQuery;
begin
  lExists := False;
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := fConnection;
    lQuery.Open('PRAGMA table_info(incident)');
    while not lQuery.Eof do
    begin
      if SameText(lQuery.FieldByName('name').AsString, aName) then
      begin
        lExists := True;
        Break;
      end;
      lQuery.Next;
    end;
  finally
    lQuery.Free;
  end;
  if not lExists then
    fConnection.ExecSQL('ALTER TABLE incident ADD COLUMN ' + aName + ' ' +
      aDefinition);
end;

procedure TMachineOverviewHistoryStore.CreateOrMigrateSchema;
var
  lQuery: TFDQuery;
  lVersion: Integer;
begin
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := fConnection;
    lQuery.Open('PRAGMA user_version');
    lVersion := lQuery.Fields[0].AsInteger;
  finally
    lQuery.Free;
  end;
  if lVersion > cMachineOverviewHistorySchemaVersion then
    raise EInvalidOperation.CreateFmt(
      'Machine Overview history schema %d is newer than supported schema %d',
      [lVersion, cMachineOverviewHistorySchemaVersion]);
  if fDatabaseExisted and (lVersion < cMachineOverviewHistorySchemaVersion) then
  begin
    fConnection.Connected := False;
    TFile.Copy(fConfig.DatabaseFileName, fConfig.DatabaseFileName +
      '.pre-migration-v' + IntToStr(lVersion) + '.bak', True);
    if TFile.Exists(fConfig.DatabaseFileName + '-wal') then
      TFile.Copy(fConfig.DatabaseFileName + '-wal', fConfig.DatabaseFileName +
        '.pre-migration-v' + IntToStr(lVersion) + '.bak-wal', True);
    fConnection.Connected := True;
  end;
  fConnection.ExecSQL('PRAGMA journal_mode=WAL');
  fConnection.ExecSQL('PRAGMA synchronous=NORMAL');
  if lVersion = cMachineOverviewHistorySchemaVersion then
    Exit;
  fConnection.StartTransaction;
  try
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS schema_info (' +
      'key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS system_sample_raw (' +
      'id INTEGER PRIMARY KEY, utc_ms INTEGER NOT NULL, ' +
      'monotonic_ms INTEGER NOT NULL, provider_status INTEGER NOT NULL, ' +
      'provider_error TEXT NOT NULL, cpu_available INTEGER NOT NULL, ' +
      'cpu_total REAL NOT NULL, physical_available_bytes REAL NOT NULL, ' +
      'logical_cpu_blob BLOB NOT NULL)');
    fConnection.ExecSQL('CREATE INDEX IF NOT EXISTS ' +
      'idx_system_sample_raw_utc ON system_sample_raw(utc_ms)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS disk_sample_raw (' +
      'id INTEGER PRIMARY KEY, utc_ms INTEGER NOT NULL, ' +
      'monotonic_ms INTEGER NOT NULL, disk_id TEXT NOT NULL, ' +
      'display_name TEXT NOT NULL, active_available INTEGER NOT NULL, ' +
      'active_percent REAL NOT NULL, read_available INTEGER NOT NULL, ' +
      'read_mb_per_sec REAL NOT NULL, write_available INTEGER NOT NULL, ' +
      'write_mb_per_sec REAL NOT NULL, latency_available INTEGER NOT NULL, ' +
      'latency_ms REAL NOT NULL, latency_max_available INTEGER NOT NULL, ' +
      'latency_max_60s REAL NOT NULL, queue_available INTEGER NOT NULL, ' +
      'queue_length REAL NOT NULL, volume_summary TEXT NOT NULL, ' +
      'provider_status INTEGER NOT NULL, provider_error TEXT NOT NULL)');
    fConnection.ExecSQL('CREATE INDEX IF NOT EXISTS ' +
      'idx_disk_sample_raw_utc ON disk_sample_raw(utc_ms)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS process_top_sample (' +
      'id INTEGER PRIMARY KEY, utc_ms INTEGER NOT NULL, ' +
      'monotonic_ms INTEGER NOT NULL, category TEXT NOT NULL, ' +
      'rank_value INTEGER NOT NULL, entity_id TEXT NOT NULL, ' +
      'process_id INTEGER NOT NULL, creation_time_100ns INTEGER NOT NULL, ' +
      'display_name TEXT NOT NULL, image_path TEXT NOT NULL, ' +
      'path_status TEXT NOT NULL, metric_value REAL NOT NULL)');
    fConnection.ExecSQL('CREATE INDEX IF NOT EXISTS ' +
      'idx_process_top_sample_utc ON process_top_sample(utc_ms)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS rollup_10s (' +
      'bucket_utc_ms INTEGER PRIMARY KEY, sample_count INTEGER NOT NULL, ' +
      'cpu_sum REAL NOT NULL, cpu_count INTEGER NOT NULL, ' +
      'cpu_max REAL NOT NULL, physical_available_min REAL NOT NULL)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS rollup_1m (' +
      'bucket_utc_ms INTEGER PRIMARY KEY, sample_count INTEGER NOT NULL, ' +
      'cpu_sum REAL NOT NULL, cpu_count INTEGER NOT NULL, ' +
      'cpu_max REAL NOT NULL, physical_available_min REAL NOT NULL)');
    fConnection.ExecSQL('CREATE TABLE IF NOT EXISTS incident (' +
      'id INTEGER PRIMARY KEY, incident_key TEXT NOT NULL, ' +
      'started_utc_ms INTEGER NOT NULL, peak_utc_ms INTEGER NOT NULL, ' +
      'ended_utc_ms INTEGER NOT NULL, category INTEGER NOT NULL, ' +
      'severity INTEGER NOT NULL, origin INTEGER NOT NULL, ' +
      'local_display_time TEXT NOT NULL, summary TEXT NOT NULL, ' +
      'explanation TEXT NOT NULL, threshold_text TEXT NOT NULL, ' +
      'peak_value REAL NOT NULL, provider_id TEXT NOT NULL, ' +
      'provider_freshness_ms INTEGER NOT NULL, ' +
      'related_entity_ids_json TEXT NOT NULL, ' +
      'related_executable_paths_json TEXT NOT NULL, ' +
      'trace_status INTEGER NOT NULL, pre_context_json TEXT NOT NULL, ' +
      'post_context_json TEXT NOT NULL, context_text TEXT NOT NULL)');
    EnsureIncidentColumn('peak_utc_ms', 'INTEGER NOT NULL DEFAULT 0');
    EnsureIncidentColumn('category', 'INTEGER NOT NULL DEFAULT 0');
    EnsureIncidentColumn('origin', 'INTEGER NOT NULL DEFAULT 0');
    EnsureIncidentColumn('local_display_time',
      'TEXT NOT NULL DEFAULT ''''');
    EnsureIncidentColumn('explanation', 'TEXT NOT NULL DEFAULT ''''');
    EnsureIncidentColumn('threshold_text', 'TEXT NOT NULL DEFAULT ''''');
    EnsureIncidentColumn('peak_value', 'REAL NOT NULL DEFAULT 0');
    EnsureIncidentColumn('provider_id', 'TEXT NOT NULL DEFAULT ''''');
    EnsureIncidentColumn('provider_freshness_ms',
      'INTEGER NOT NULL DEFAULT 0');
    EnsureIncidentColumn('related_entity_ids_json',
      'TEXT NOT NULL DEFAULT ''[]''');
    EnsureIncidentColumn('related_executable_paths_json',
      'TEXT NOT NULL DEFAULT ''[]''');
    EnsureIncidentColumn('trace_status', 'INTEGER NOT NULL DEFAULT 0');
    EnsureIncidentColumn('pre_context_json',
      'TEXT NOT NULL DEFAULT ''[]''');
    EnsureIncidentColumn('post_context_json',
      'TEXT NOT NULL DEFAULT ''[]''');
    fConnection.ExecSQL('DELETE FROM incident WHERE id NOT IN (' +
      'SELECT MAX(id) FROM incident GROUP BY incident_key)');
    fConnection.ExecSQL('CREATE UNIQUE INDEX IF NOT EXISTS ' +
      'idx_incident_key ON incident(incident_key)');
    fConnection.ExecSQL('CREATE INDEX IF NOT EXISTS idx_incident_started ' +
      'ON incident(started_utc_ms DESC)');
    fConnection.ExecSQL('INSERT OR REPLACE INTO schema_info(key, value) ' +
      'VALUES (''logical_cpu_blob'', ' +
      '''MOCP v1, little-endian, UInt16 count/values, scale 0.01 percent, FFFF unavailable'')');
    fConnection.ExecSQL('INSERT OR REPLACE INTO schema_info(key, value) ' +
      'VALUES (''journal_mode'', ''WAL'')');
    fConnection.ExecSQL('INSERT OR REPLACE INTO schema_info(key, value) ' +
      'VALUES (''synchronous'', ''NORMAL'')');
    fConnection.ExecSQL('PRAGMA user_version=' +
      IntToStr(cMachineOverviewHistorySchemaVersion));
    fConnection.Commit;
  except
    if fConnection.InTransaction then
      fConnection.Rollback;
    raise;
  end;
end;

procedure TMachineOverviewHistoryStore.PrepareStatements;
const
  cRollupSql =
    'INSERT INTO %s(bucket_utc_ms, sample_count, cpu_sum, cpu_count, ' +
    'cpu_max, physical_available_min) VALUES (:bucket, 1, :cpu_sum, ' +
    ':cpu_count, :cpu_max, :physical_available) ON CONFLICT(bucket_utc_ms) ' +
    'DO UPDATE SET sample_count=sample_count+1, ' +
    'cpu_sum=cpu_sum+excluded.cpu_sum, ' +
    'cpu_count=cpu_count+excluded.cpu_count, ' +
    'cpu_max=MAX(cpu_max, excluded.cpu_max), ' +
    'physical_available_min=CASE WHEN physical_available_min=0 THEN ' +
    'excluded.physical_available_min WHEN excluded.physical_available_min=0 ' +
    'THEN physical_available_min ELSE MIN(physical_available_min, ' +
    'excluded.physical_available_min) END';
begin
  fSystemInsert := TFDQuery.Create(nil);
  fSystemInsert.Connection := fConnection;
  fSystemInsert.SQL.Text := 'INSERT INTO system_sample_raw(utc_ms, ' +
    'monotonic_ms, provider_status, provider_error, cpu_available, ' +
    'cpu_total, physical_available_bytes, logical_cpu_blob) VALUES ' +
    '(:utc_ms, :monotonic_ms, :provider_status, :provider_error, ' +
    ':cpu_available, :cpu_total, :physical_available_bytes, ' +
    ':logical_cpu_blob)';
  fSystemInsert.ParamByName('utc_ms').DataType := ftLargeint;
  fSystemInsert.ParamByName('monotonic_ms').DataType := ftLargeint;
  fSystemInsert.ParamByName('provider_status').DataType := ftInteger;
  fSystemInsert.ParamByName('provider_error').DataType := ftWideString;
  fSystemInsert.ParamByName('cpu_available').DataType := ftInteger;
  fSystemInsert.ParamByName('cpu_total').DataType := ftFloat;
  fSystemInsert.ParamByName('physical_available_bytes').DataType := ftFloat;
  fSystemInsert.ParamByName('logical_cpu_blob').DataType := ftBlob;
  fSystemInsert.Prepare;
  fDiskInsert := TFDQuery.Create(nil);
  fDiskInsert.Connection := fConnection;
  fDiskInsert.SQL.Text := 'INSERT INTO disk_sample_raw(utc_ms, ' +
    'monotonic_ms, disk_id, display_name, active_available, ' +
    'active_percent, read_available, read_mb_per_sec, write_available, ' +
    'write_mb_per_sec, latency_available, latency_ms, ' +
    'latency_max_available, latency_max_60s, queue_available, ' +
    'queue_length, volume_summary, provider_status, provider_error) VALUES ' +
    '(:utc_ms, :monotonic_ms, :disk_id, :display_name, ' +
    ':active_available, :active_percent, :read_available, ' +
    ':read_mb_per_sec, :write_available, :write_mb_per_sec, ' +
    ':latency_available, :latency_ms, :latency_max_available, ' +
    ':latency_max_60s, :queue_available, :queue_length, :volume_summary, ' +
    ':provider_status, :provider_error)';
  fDiskInsert.ParamByName('utc_ms').DataType := ftLargeint;
  fDiskInsert.ParamByName('monotonic_ms').DataType := ftLargeint;
  fDiskInsert.ParamByName('disk_id').DataType := ftWideString;
  fDiskInsert.ParamByName('display_name').DataType := ftWideString;
  fDiskInsert.ParamByName('active_available').DataType := ftInteger;
  fDiskInsert.ParamByName('active_percent').DataType := ftFloat;
  fDiskInsert.ParamByName('read_available').DataType := ftInteger;
  fDiskInsert.ParamByName('read_mb_per_sec').DataType := ftFloat;
  fDiskInsert.ParamByName('write_available').DataType := ftInteger;
  fDiskInsert.ParamByName('write_mb_per_sec').DataType := ftFloat;
  fDiskInsert.ParamByName('latency_available').DataType := ftInteger;
  fDiskInsert.ParamByName('latency_ms').DataType := ftFloat;
  fDiskInsert.ParamByName('latency_max_available').DataType := ftInteger;
  fDiskInsert.ParamByName('latency_max_60s').DataType := ftFloat;
  fDiskInsert.ParamByName('queue_available').DataType := ftInteger;
  fDiskInsert.ParamByName('queue_length').DataType := ftFloat;
  fDiskInsert.ParamByName('volume_summary').DataType := ftWideString;
  fDiskInsert.ParamByName('provider_status').DataType := ftInteger;
  fDiskInsert.ParamByName('provider_error').DataType := ftWideString;
  fDiskInsert.Prepare;
  fProcessInsert := TFDQuery.Create(nil);
  fProcessInsert.Connection := fConnection;
  fProcessInsert.SQL.Text := 'INSERT INTO process_top_sample(utc_ms, ' +
    'monotonic_ms, category, rank_value, entity_id, process_id, ' +
    'creation_time_100ns, display_name, image_path, path_status, ' +
    'metric_value) VALUES (:utc_ms, :monotonic_ms, :category, ' +
    ':rank_value, :entity_id, :process_id, :creation_time_100ns, ' +
    ':display_name, :image_path, :path_status, :metric_value)';
  fProcessInsert.ParamByName('utc_ms').DataType := ftLargeint;
  fProcessInsert.ParamByName('monotonic_ms').DataType := ftLargeint;
  fProcessInsert.ParamByName('category').DataType := ftWideString;
  fProcessInsert.ParamByName('rank_value').DataType := ftInteger;
  fProcessInsert.ParamByName('entity_id').DataType := ftWideString;
  fProcessInsert.ParamByName('process_id').DataType := ftLargeint;
  fProcessInsert.ParamByName('creation_time_100ns').DataType := ftLargeint;
  fProcessInsert.ParamByName('display_name').DataType := ftWideString;
  fProcessInsert.ParamByName('image_path').DataType := ftWideString;
  fProcessInsert.ParamByName('path_status').DataType := ftWideString;
  fProcessInsert.ParamByName('metric_value').DataType := ftFloat;
  fProcessInsert.Prepare;
  fRollup10s := TFDQuery.Create(nil);
  fRollup10s.Connection := fConnection;
  fRollup10s.SQL.Text := Format(cRollupSql, ['rollup_10s']);
  fRollup10s.ParamByName('bucket').DataType := ftLargeint;
  fRollup10s.ParamByName('cpu_sum').DataType := ftFloat;
  fRollup10s.ParamByName('cpu_count').DataType := ftInteger;
  fRollup10s.ParamByName('cpu_max').DataType := ftFloat;
  fRollup10s.ParamByName('physical_available').DataType := ftFloat;
  fRollup10s.Prepare;
  fRollup1m := TFDQuery.Create(nil);
  fRollup1m.Connection := fConnection;
  fRollup1m.SQL.Text := Format(cRollupSql, ['rollup_1m']);
  fRollup1m.ParamByName('bucket').DataType := ftLargeint;
  fRollup1m.ParamByName('cpu_sum').DataType := ftFloat;
  fRollup1m.ParamByName('cpu_count').DataType := ftInteger;
  fRollup1m.ParamByName('cpu_max').DataType := ftFloat;
  fRollup1m.ParamByName('physical_available').DataType := ftFloat;
  fRollup1m.Prepare;
  fIncidentUpsert := TFDQuery.Create(nil);
  fIncidentUpsert.Connection := fConnection;
  fIncidentUpsert.SQL.Text := 'INSERT INTO incident(incident_key, ' +
    'started_utc_ms, peak_utc_ms, ended_utc_ms, category, severity, origin, ' +
    'local_display_time, summary, explanation, threshold_text, peak_value, ' +
    'provider_id, provider_freshness_ms, related_entity_ids_json, ' +
    'related_executable_paths_json, trace_status, pre_context_json, ' +
    'post_context_json, context_text) VALUES (:incident_key, ' +
    ':started_utc_ms, :peak_utc_ms, :ended_utc_ms, :category, :severity, ' +
    ':origin, :local_display_time, :summary, :explanation, :threshold_text, ' +
    ':peak_value, :provider_id, :provider_freshness_ms, ' +
    ':related_entity_ids_json, :related_executable_paths_json, ' +
    ':trace_status, :pre_context_json, :post_context_json, :context_text) ' +
    'ON CONFLICT(incident_key) DO UPDATE SET ' +
    'peak_utc_ms=excluded.peak_utc_ms, ended_utc_ms=excluded.ended_utc_ms, ' +
    'category=excluded.category, severity=excluded.severity, ' +
    'origin=excluded.origin, local_display_time=excluded.local_display_time, ' +
    'summary=excluded.summary, explanation=excluded.explanation, ' +
    'threshold_text=excluded.threshold_text, peak_value=excluded.peak_value, ' +
    'provider_id=excluded.provider_id, ' +
    'provider_freshness_ms=excluded.provider_freshness_ms, ' +
    'related_entity_ids_json=excluded.related_entity_ids_json, ' +
    'related_executable_paths_json=excluded.related_executable_paths_json, ' +
    'trace_status=excluded.trace_status, ' +
    'pre_context_json=excluded.pre_context_json, ' +
    'post_context_json=excluded.post_context_json, ' +
    'context_text=excluded.context_text';
  fIncidentUpsert.ParamByName('incident_key').DataType := ftWideString;
  fIncidentUpsert.ParamByName('started_utc_ms').DataType := ftLargeint;
  fIncidentUpsert.ParamByName('peak_utc_ms').DataType := ftLargeint;
  fIncidentUpsert.ParamByName('ended_utc_ms').DataType := ftLargeint;
  fIncidentUpsert.ParamByName('category').DataType := ftInteger;
  fIncidentUpsert.ParamByName('severity').DataType := ftInteger;
  fIncidentUpsert.ParamByName('origin').DataType := ftInteger;
  fIncidentUpsert.ParamByName('local_display_time').DataType := ftWideString;
  fIncidentUpsert.ParamByName('summary').DataType := ftWideString;
  fIncidentUpsert.ParamByName('explanation').DataType := ftWideMemo;
  fIncidentUpsert.ParamByName('threshold_text').DataType := ftWideString;
  fIncidentUpsert.ParamByName('peak_value').DataType := ftFloat;
  fIncidentUpsert.ParamByName('provider_id').DataType := ftWideString;
  fIncidentUpsert.ParamByName('provider_freshness_ms').DataType := ftLargeint;
  fIncidentUpsert.ParamByName('related_entity_ids_json').DataType := ftWideMemo;
  fIncidentUpsert.ParamByName('related_executable_paths_json').DataType :=
    ftWideMemo;
  fIncidentUpsert.ParamByName('trace_status').DataType := ftInteger;
  fIncidentUpsert.ParamByName('pre_context_json').DataType := ftWideMemo;
  fIncidentUpsert.ParamByName('post_context_json').DataType := ftWideMemo;
  fIncidentUpsert.ParamByName('context_text').DataType := ftWideMemo;
  fIncidentUpsert.Prepare;
end;

procedure TMachineOverviewHistoryStore.WriteRollup(const aQuery: TFDQuery;
  const aBucketUtcMs: Int64; const aCpuAvailable: Boolean;
  const aCpuValue, aPhysicalAvailable: Double);
begin
  aQuery.ParamByName('bucket').AsLargeInt := aBucketUtcMs;
  if aCpuAvailable then
  begin
    aQuery.ParamByName('cpu_sum').AsFloat := aCpuValue;
    aQuery.ParamByName('cpu_count').AsInteger := 1;
    aQuery.ParamByName('cpu_max').AsFloat := aCpuValue;
  end else
  begin
    aQuery.ParamByName('cpu_sum').AsFloat := 0;
    aQuery.ParamByName('cpu_count').AsInteger := 0;
    aQuery.ParamByName('cpu_max').AsFloat := 0;
  end;
  aQuery.ParamByName('physical_available').AsFloat := aPhysicalAvailable;
  aQuery.ExecSQL;
end;

procedure TMachineOverviewHistoryStore.WriteDiskSample(
  const aSample: IMachineOverviewRawSample);
const
  cActivePrefix = 'disk_active_percent:';
  cLatencyMaxPrefix = 'disk_latency_max_60s:';
  cLatencyPrefix = 'disk_latency_ms:';
  cQueuePrefix = 'disk_queue_length:';
  cReadPrefix = 'disk_read_mb_per_sec:';
  cVolumePrefix = 'disk_volume_';
  cWritePrefix = 'disk_write_mb_per_sec:';
var
  lDiskRow: TMachineOverviewHistoryDiskRow;
  lDiskRows: TDictionary<string, TMachineOverviewHistoryDiskRow>;
  lMeasurement: TMachineOverviewMeasurement;
  lProviderSample: TMachineOverviewProviderSample;
  lVolumeItem: string;
begin
  lProviderSample := aSample.ProviderSample;
  lDiskRows := TDictionary<string,
    TMachineOverviewHistoryDiskRow>.Create;
  try
    for lMeasurement in lProviderSample.Measurements do
    begin
      if lMeasurement.EntityId.IsEmpty then
        Continue;
      if not lDiskRows.TryGetValue(lMeasurement.EntityId, lDiskRow) then
      begin
        lDiskRow := Default(TMachineOverviewHistoryDiskRow);
        lDiskRow.DiskId := lMeasurement.EntityId;
        lDiskRow.DisplayName := lMeasurement.DisplayText;
      end;
      if StartsText(cActivePrefix, lMeasurement.Name) then
      begin
        lDiskRow.ActiveAvailable := lMeasurement.Available;
        lDiskRow.ActivePercent := lMeasurement.Value;
      end else if StartsText(cReadPrefix, lMeasurement.Name) then
      begin
        lDiskRow.ReadAvailable := lMeasurement.Available;
        lDiskRow.ReadMBPerSecond := lMeasurement.Value;
      end else if StartsText(cWritePrefix, lMeasurement.Name) then
      begin
        lDiskRow.WriteAvailable := lMeasurement.Available;
        lDiskRow.WriteMBPerSecond := lMeasurement.Value;
      end else if StartsText(cLatencyMaxPrefix, lMeasurement.Name) then
      begin
        lDiskRow.LatencyMaxAvailable := lMeasurement.Available;
        lDiskRow.LatencyMax60s := lMeasurement.Value;
      end else if StartsText(cLatencyPrefix, lMeasurement.Name) then
      begin
        lDiskRow.LatencyAvailable := lMeasurement.Available;
        lDiskRow.LatencyMs := lMeasurement.Value;
      end else if StartsText(cQueuePrefix, lMeasurement.Name) then
      begin
        lDiskRow.QueueAvailable := lMeasurement.Available;
        lDiskRow.QueueLength := lMeasurement.Value;
      end else if StartsText(cVolumePrefix, lMeasurement.Name) then
      begin
        lVolumeItem := Format('%s=%s', [lMeasurement.DisplayText,
          FloatToStr(lMeasurement.Value, TFormatSettings.Invariant)]);
        if not lDiskRow.VolumeSummary.IsEmpty then
          lDiskRow.VolumeSummary := lDiskRow.VolumeSummary + '; ';
        lDiskRow.VolumeSummary := lDiskRow.VolumeSummary + lVolumeItem;
      end;
      lDiskRows.AddOrSetValue(lMeasurement.EntityId, lDiskRow);
    end;
    for lDiskRow in lDiskRows.Values do
    begin
      fDiskInsert.ParamByName('utc_ms').AsLargeInt :=
        HistoryUtcMilliseconds(lProviderSample.State.CapturedAtUtc);
      fDiskInsert.ParamByName('monotonic_ms').AsLargeInt :=
        lProviderSample.State.CapturedAtMonotonicMs;
      fDiskInsert.ParamByName('disk_id').AsWideString := lDiskRow.DiskId;
      fDiskInsert.ParamByName('display_name').AsWideString :=
        lDiskRow.DisplayName;
      fDiskInsert.ParamByName('active_available').AsInteger :=
        Ord(lDiskRow.ActiveAvailable);
      fDiskInsert.ParamByName('active_percent').AsFloat :=
        lDiskRow.ActivePercent;
      fDiskInsert.ParamByName('read_available').AsInteger :=
        Ord(lDiskRow.ReadAvailable);
      fDiskInsert.ParamByName('read_mb_per_sec').AsFloat :=
        lDiskRow.ReadMBPerSecond;
      fDiskInsert.ParamByName('write_available').AsInteger :=
        Ord(lDiskRow.WriteAvailable);
      fDiskInsert.ParamByName('write_mb_per_sec').AsFloat :=
        lDiskRow.WriteMBPerSecond;
      fDiskInsert.ParamByName('latency_available').AsInteger :=
        Ord(lDiskRow.LatencyAvailable);
      fDiskInsert.ParamByName('latency_ms').AsFloat := lDiskRow.LatencyMs;
      fDiskInsert.ParamByName('latency_max_available').AsInteger :=
        Ord(lDiskRow.LatencyMaxAvailable);
      fDiskInsert.ParamByName('latency_max_60s').AsFloat :=
        lDiskRow.LatencyMax60s;
      fDiskInsert.ParamByName('queue_available').AsInteger :=
        Ord(lDiskRow.QueueAvailable);
      fDiskInsert.ParamByName('queue_length').AsFloat :=
        lDiskRow.QueueLength;
      fDiskInsert.ParamByName('volume_summary').AsWideString :=
        lDiskRow.VolumeSummary;
      fDiskInsert.ParamByName('provider_status').AsInteger :=
        Ord(lProviderSample.State.Status);
      fDiskInsert.ParamByName('provider_error').AsWideString :=
        lProviderSample.State.ErrorText;
      fDiskInsert.ExecSQL;
    end;
  finally
    lDiskRows.Free;
  end;
end;

function TryParseHistoryRank(const aName: string; out aCategory: string;
  out aRank: Integer): Boolean;
const
  cCpuPrefix = 'process_cpu_rank:';
  cIoPrefix = 'process_io_rank:';
  cRamPrefix = 'process_ram_rank:';
var
  lPrefix: string;
begin
  aCategory := '';
  aRank := 0;
  if StartsText(cCpuPrefix, aName) then
  begin
    aCategory := 'cpu';
    lPrefix := cCpuPrefix;
  end else if StartsText(cRamPrefix, aName) then
  begin
    aCategory := 'ram';
    lPrefix := cRamPrefix;
  end else if StartsText(cIoPrefix, aName) then
  begin
    aCategory := 'io';
    lPrefix := cIoPrefix;
  end else
    Exit(False);
  Result := TryStrToInt(Copy(aName, Length(lPrefix) + 1, MaxInt), aRank) and
    (aRank > 0);
end;

procedure ParseHistoryProcessIdentity(const aEntityId: string;
  out aProcessId: Int64; out aCreationTime100ns: Int64);
var
  lSeparator: Integer;
begin
  aProcessId := 0;
  aCreationTime100ns := 0;
  lSeparator := Pos(':', aEntityId);
  if lSeparator <= 1 then
    Exit;
  TryStrToInt64(Copy(aEntityId, 1, lSeparator - 1), aProcessId);
  TryStrToInt64(Copy(aEntityId, lSeparator + 1, MaxInt),
    aCreationTime100ns);
end;

procedure TMachineOverviewHistoryStore.WriteProcessSample(
  const aSample: IMachineOverviewRawSample);
var
  lCategory: string;
  lCreationTime100ns: Int64;
  lMeasurement: TMachineOverviewMeasurement;
  lProcessId: Int64;
  lProviderSample: TMachineOverviewProviderSample;
  lRank: Integer;
begin
  lProviderSample := aSample.ProviderSample;
  for lMeasurement in lProviderSample.Measurements do
    if TryParseHistoryRank(lMeasurement.Name, lCategory, lRank) then
    begin
      ParseHistoryProcessIdentity(lMeasurement.EntityId, lProcessId,
        lCreationTime100ns);
      fProcessInsert.ParamByName('utc_ms').AsLargeInt :=
        HistoryUtcMilliseconds(lProviderSample.State.CapturedAtUtc);
      fProcessInsert.ParamByName('monotonic_ms').AsLargeInt :=
        lProviderSample.State.CapturedAtMonotonicMs;
      fProcessInsert.ParamByName('category').AsWideString := lCategory;
      fProcessInsert.ParamByName('rank_value').AsInteger := lRank;
      fProcessInsert.ParamByName('entity_id').AsWideString :=
        lMeasurement.EntityId;
      fProcessInsert.ParamByName('process_id').AsLargeInt := lProcessId;
      fProcessInsert.ParamByName('creation_time_100ns').AsLargeInt :=
        lCreationTime100ns;
      fProcessInsert.ParamByName('display_name').AsWideString :=
        lMeasurement.DisplayText;
      fProcessInsert.ParamByName('image_path').AsWideString :=
        lMeasurement.DetailText;
      fProcessInsert.ParamByName('path_status').AsWideString :=
        lMeasurement.StatusText;
      fProcessInsert.ParamByName('metric_value').AsFloat :=
        lMeasurement.Value;
      fProcessInsert.ExecSQL;
    end;
end;

procedure TMachineOverviewHistoryStore.WriteSystemSample(
  const aSample: IMachineOverviewRawSample);
var
  lCpu: TMachineOverviewMeasurement;
  lLogicalData: TBytes;
  lPhysicalAvailable: TMachineOverviewMeasurement;
  lProviderSample: TMachineOverviewProviderSample;
  lStream: TBytesStream;
  lUtcMs: Int64;
begin
  lProviderSample := aSample.ProviderSample;
  lUtcMs := HistoryUtcMilliseconds(lProviderSample.State.CapturedAtUtc);
  FindHistoryMeasurement(lProviderSample, 'cpu_total_percent', lCpu);
  FindHistoryMeasurement(lProviderSample, 'physical_available_bytes',
    lPhysicalAvailable);
  lLogicalData := PackMachineOverviewLogicalProcessors(
    HistoryLogicalProcessors(lProviderSample));
  fSystemInsert.ParamByName('utc_ms').AsLargeInt := lUtcMs;
  fSystemInsert.ParamByName('monotonic_ms').AsLargeInt :=
    lProviderSample.State.CapturedAtMonotonicMs;
  fSystemInsert.ParamByName('provider_status').AsInteger :=
    Ord(lProviderSample.State.Status);
  fSystemInsert.ParamByName('provider_error').AsWideString :=
    lProviderSample.State.ErrorText;
  fSystemInsert.ParamByName('cpu_available').AsInteger := Ord(lCpu.Available);
  fSystemInsert.ParamByName('cpu_total').AsFloat := lCpu.Value;
  fSystemInsert.ParamByName('physical_available_bytes').AsFloat :=
    lPhysicalAvailable.Value;
  lStream := TBytesStream.Create(lLogicalData);
  try
    fSystemInsert.ParamByName('logical_cpu_blob').LoadFromStream(lStream,
      ftBlob);
  finally
    lStream.Free;
  end;
  fSystemInsert.ExecSQL;
  WriteRollup(fRollup10s, (lUtcMs div 10000) * 10000, lCpu.Available,
    lCpu.Value, lPhysicalAvailable.Value);
  WriteRollup(fRollup1m, (lUtcMs div 60000) * 60000, lCpu.Available,
    lCpu.Value, lPhysicalAvailable.Value);
end;

procedure TMachineOverviewHistoryStore.WriteIncident(
  const aIncident: TMachineOverviewIncident);
begin
  if aIncident.StableId.IsEmpty then
    Exit;
  fIncidentUpsert.ParamByName('incident_key').AsWideString :=
    aIncident.StableId;
  fIncidentUpsert.ParamByName('started_utc_ms').AsLargeInt :=
    HistoryUtcMilliseconds(aIncident.StartedAtUtc);
  fIncidentUpsert.ParamByName('peak_utc_ms').AsLargeInt :=
    HistoryUtcMilliseconds(aIncident.PeakAtUtc);
  fIncidentUpsert.ParamByName('ended_utc_ms').AsLargeInt :=
    HistoryUtcMilliseconds(aIncident.EndedAtUtc);
  fIncidentUpsert.ParamByName('category').AsInteger :=
    Ord(aIncident.Category);
  fIncidentUpsert.ParamByName('severity').AsInteger :=
    Ord(aIncident.Severity);
  fIncidentUpsert.ParamByName('origin').AsInteger :=
    Ord(aIncident.Origin);
  fIncidentUpsert.ParamByName('local_display_time').AsWideString :=
    aIncident.LocalDisplayTime;
  fIncidentUpsert.ParamByName('summary').AsWideString := aIncident.Summary;
  fIncidentUpsert.ParamByName('explanation').Value :=
    aIncident.Explanation;
  fIncidentUpsert.ParamByName('threshold_text').AsWideString :=
    aIncident.ThresholdText;
  fIncidentUpsert.ParamByName('peak_value').AsFloat := aIncident.PeakValue;
  fIncidentUpsert.ParamByName('provider_id').AsWideString :=
    aIncident.ProviderId;
  fIncidentUpsert.ParamByName('provider_freshness_ms').AsLargeInt :=
    aIncident.ProviderFreshnessMs;
  fIncidentUpsert.ParamByName('related_entity_ids_json').Value :=
    HistoryStringArrayToJson(aIncident.RelatedEntityIds);
  fIncidentUpsert.ParamByName(
    'related_executable_paths_json').Value :=
    HistoryStringArrayToJson(aIncident.RelatedExecutablePaths);
  fIncidentUpsert.ParamByName('trace_status').AsInteger :=
    Ord(aIncident.TraceStatus);
  fIncidentUpsert.ParamByName('pre_context_json').Value :=
    HistoryContextToJson(aIncident.PreContext);
  fIncidentUpsert.ParamByName('post_context_json').Value :=
    HistoryContextToJson(aIncident.PostContext);
  fIncidentUpsert.ParamByName('context_text').Value :=
    aIncident.Explanation;
  fIncidentUpsert.ExecSQL;
end;

procedure TMachineOverviewHistoryStore.ApplyRetention(
  const aNowUtcMs: Int64);
begin
  fConnection.ExecSQL('DELETE FROM system_sample_raw WHERE id IN ' +
    '(SELECT id FROM system_sample_raw WHERE utc_ms < :cutoff ' +
    'ORDER BY utc_ms LIMIT 256)',
    [aNowUtcMs - (Int64(fConfig.RawRetentionHours) * 60 * 60 * 1000)]);
  fConnection.ExecSQL('DELETE FROM disk_sample_raw WHERE id IN ' +
    '(SELECT id FROM disk_sample_raw WHERE utc_ms < :cutoff ' +
    'ORDER BY utc_ms LIMIT 256)',
    [aNowUtcMs - (Int64(fConfig.RawRetentionHours) * 60 * 60 * 1000)]);
  fConnection.ExecSQL('DELETE FROM process_top_sample WHERE id IN ' +
    '(SELECT id FROM process_top_sample WHERE utc_ms < :cutoff ' +
    'ORDER BY utc_ms LIMIT 256)',
    [aNowUtcMs - (Int64(fConfig.RawRetentionHours) * 60 * 60 * 1000)]);
  fConnection.ExecSQL('DELETE FROM rollup_10s WHERE bucket_utc_ms IN ' +
    '(SELECT bucket_utc_ms FROM rollup_10s WHERE bucket_utc_ms < :cutoff ' +
    'ORDER BY bucket_utc_ms LIMIT 256)',
    [aNowUtcMs - (Int64(fConfig.Rollup10sRetentionDays) * 24 * 60 * 60 *
      1000)]);
  fConnection.ExecSQL('DELETE FROM rollup_1m WHERE bucket_utc_ms IN ' +
    '(SELECT bucket_utc_ms FROM rollup_1m WHERE bucket_utc_ms < :cutoff ' +
    'ORDER BY bucket_utc_ms LIMIT 256)',
    [aNowUtcMs - (Int64(fConfig.Rollup1mRetentionDays) * 24 * 60 * 60 *
      1000)]);
end;

function TMachineOverviewHistoryStore.ApplyStorageCap: Integer;
var
  lFreePages: Int64;
  lPageCount: Int64;
  lPageSize: Int64;
  lQuery: TFDQuery;
  lUsedBytes: UInt64;
begin
  Result := 0;
  if fConfig.MaxDatabaseSizeBytes = 0 then
    Exit;
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := fConnection;
    lQuery.Open('PRAGMA page_count');
    lPageCount := lQuery.Fields[0].AsLargeInt;
    lQuery.Close;
    lQuery.Open('PRAGMA freelist_count');
    lFreePages := lQuery.Fields[0].AsLargeInt;
    lQuery.Close;
    lQuery.Open('PRAGMA page_size');
    lPageSize := lQuery.Fields[0].AsLargeInt;
  finally
    lQuery.Free;
  end;
  lUsedBytes := UInt64(Max(Int64(0), lPageCount - lFreePages)) *
    UInt64(Max(Int64(0), lPageSize));
  if lUsedBytes <= fConfig.MaxDatabaseSizeBytes then
    Exit;
  Inc(Result, fConnection.ExecSQL(
    'DELETE FROM system_sample_raw WHERE id IN (SELECT id FROM ' +
    'system_sample_raw ORDER BY utc_ms LIMIT 256)'));
  Inc(Result, fConnection.ExecSQL(
    'DELETE FROM disk_sample_raw WHERE id IN (SELECT id FROM ' +
    'disk_sample_raw ORDER BY utc_ms LIMIT 256)'));
  Inc(Result, fConnection.ExecSQL(
    'DELETE FROM process_top_sample WHERE id IN (SELECT id FROM ' +
    'process_top_sample ORDER BY utc_ms LIMIT 256)'));
  Inc(Result, fConnection.ExecSQL(
    'DELETE FROM rollup_10s WHERE bucket_utc_ms IN (SELECT bucket_utc_ms ' +
    'FROM rollup_10s ORDER BY bucket_utc_ms LIMIT 256)'));
  Inc(Result, fConnection.ExecSQL(
    'DELETE FROM rollup_1m WHERE bucket_utc_ms IN (SELECT bucket_utc_ms ' +
    'FROM rollup_1m ORDER BY bucket_utc_ms LIMIT 256)'));
end;

function TMachineOverviewHistoryStore.WriteBatch(
  const aItems: TArray<TMachineOverviewHistoryItem>): Integer;
var
  lItem: TMachineOverviewHistoryItem;
  lNowUtcMs: Int64;
begin
  Result := 0;
  if Length(aItems) = 0 then
    Exit;
  lNowUtcMs := 0;
  fConnection.StartTransaction;
  try
    for lItem in aItems do
      if (lItem.Kind = TMachineOverviewHistoryItemKind.RawSample) and
        Assigned(lItem.Sample) then
      begin
        if SameText(lItem.Sample.ProviderId, 'disks') then
          WriteDiskSample(lItem.Sample)
        else if SameText(lItem.Sample.ProviderId, 'processes') then
          WriteProcessSample(lItem.Sample)
        else if SameText(lItem.Sample.ProviderId, 'windows-core') then
          WriteSystemSample(lItem.Sample);
        lNowUtcMs := Max(lNowUtcMs,
          HistoryUtcMilliseconds(lItem.Sample.CapturedAtUtc));
      end else if lItem.Kind = TMachineOverviewHistoryItemKind.Incident then
        WriteIncident(lItem.IncidentChange.Incident);
    if lNowUtcMs > 0 then
      ApplyRetention(lNowUtcMs);
    Result := ApplyStorageCap;
    fConnection.Commit;
  except
    if fConnection.InTransaction then
      fConnection.Rollback;
    raise;
  end;
end;

function TMachineOverviewHistoryStore.LoadIncidents(
  const aEarliestUtc: TDateTime; const aMaximumCount: Integer):
  TArray<TMachineOverviewIncident>;
var
  lIncident: TMachineOverviewIncident;
  lIndex: Integer;
  lOrdinal: Integer;
  lQuery: TFDQuery;
begin
  Result := nil;
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := fConnection;
    lQuery.SQL.Text := 'SELECT incident_key, ' +
      'CAST(started_utc_ms AS TEXT) AS started_utc_ms_text, severity, ' +
      'summary, explanation, threshold_text FROM incident ' +
      'WHERE started_utc_ms >= :earliest ORDER BY started_utc_ms DESC, ' +
      'incident_key ASC LIMIT :maximum';
    lQuery.ParamByName('earliest').AsLargeInt :=
      HistoryUtcMilliseconds(aEarliestUtc);
    if aMaximumCount > 0 then
      lQuery.ParamByName('maximum').AsInteger := aMaximumCount
    else
      lQuery.ParamByName('maximum').AsInteger := MaxInt;
    lQuery.Open;
    while not lQuery.Eof do
    begin
      lIncident := Default(TMachineOverviewIncident);
      lIncident.StableId := lQuery.FieldByName('incident_key').AsString;
      lIncident.StartedAtUtc := HistoryDateTimeFromMilliseconds(
        HistoryFieldInt64(lQuery.FieldByName('started_utc_ms_text')));
      lOrdinal := lQuery.FieldByName('severity').AsInteger;
      lIncident.Severity := HistorySeverityFromOrdinal(lOrdinal);
      lIncident.Summary := lQuery.FieldByName('summary').AsString;
      lIncident.Explanation := lQuery.FieldByName('explanation').AsString;
      lIncident.ThresholdText :=
        lQuery.FieldByName('threshold_text').AsString;
      lIndex := Length(Result);
      SetLength(Result, lIndex + 1);
      Result[lIndex] := lIncident;
      lQuery.Next;
    end;
  finally
    lQuery.Free;
  end;
end;

class function TMachineOverviewHistoryConfig.FromSettings(
  const aSettings: TMachineOverviewSettings;
  const aDatabaseFileName: string): TMachineOverviewHistoryConfig;
var
  lDefaults: TMachineOverviewSettings;
begin
  lDefaults := TMachineOverviewSettings.Defaults;
  Result := Default(TMachineOverviewHistoryConfig);
  Result.Enabled := aSettings.Enabled and aSettings.HistoryEnabled and
    (not aDatabaseFileName.Trim.IsEmpty);
  Result.DatabaseFileName := aDatabaseFileName;
  if aSettings.HistoryCommitIntervalMs > 0 then
    Result.CommitIntervalMs := Cardinal(aSettings.HistoryCommitIntervalMs)
  else
    Result.CommitIntervalMs := Cardinal(lDefaults.HistoryCommitIntervalMs);
  Result.QueueCapacity := 4096;
  if aSettings.RawRetentionHours > 0 then
    Result.RawRetentionHours := aSettings.RawRetentionHours
  else
    Result.RawRetentionHours := lDefaults.RawRetentionHours;
  if aSettings.Rollup10sRetentionDays > 0 then
    Result.Rollup10sRetentionDays := aSettings.Rollup10sRetentionDays
  else
    Result.Rollup10sRetentionDays := lDefaults.Rollup10sRetentionDays;
  if aSettings.Rollup1mRetentionDays > 0 then
    Result.Rollup1mRetentionDays := aSettings.Rollup1mRetentionDays
  else
    Result.Rollup1mRetentionDays := lDefaults.Rollup1mRetentionDays;
  if aSettings.MaxDatabaseSizeMB > 0 then
    Result.MaxDatabaseSizeBytes := UInt64(aSettings.MaxDatabaseSizeMB) *
      1024 * 1024
  else
    Result.MaxDatabaseSizeBytes := UInt64(lDefaults.MaxDatabaseSizeMB) *
      1024 * 1024;
  Result.BusyTimeoutMs := 100;
end;

class function TMachineOverviewHistoryItem.CreateRaw(
  const aSample: IMachineOverviewRawSample): TMachineOverviewHistoryItem;
begin
  Result := Default(TMachineOverviewHistoryItem);
  Result.Kind := TMachineOverviewHistoryItemKind.RawSample;
  Result.Sample := aSample;
end;

class function TMachineOverviewHistoryItem.CreateIncident(
  const aChange: TMachineOverviewIncidentChange):
  TMachineOverviewHistoryItem;
begin
  Result := Default(TMachineOverviewHistoryItem);
  Result.Kind := TMachineOverviewHistoryItemKind.Incident;
  Result.IncidentChange := aChange;
end;

class function TMachineOverviewHistoryItem.CreateIncidentMarker:
  TMachineOverviewHistoryItem;
begin
  Result := Default(TMachineOverviewHistoryItem);
  Result.Kind := TMachineOverviewHistoryItemKind.Incident;
end;

constructor TMachineOverviewHistoryBacklog.Create(const aCapacity: Integer);
begin
  inherited Create;
  fState := TMachineOverviewHistoryBacklogState.Create(aCapacity);
end;

destructor TMachineOverviewHistoryBacklog.Destroy;
begin
  fState.Free;
  inherited Destroy;
end;

function TMachineOverviewHistoryBacklog.Diagnostics:
  TMachineOverviewHistoryBacklogDiagnostics;
var
  lState: TMachineOverviewHistoryBacklogState;
begin
  lState := GetHistoryBacklogState(fState);
  lState.fLock.Acquire;
  try
    Result := Default(TMachineOverviewHistoryBacklogDiagnostics);
    Result.Count := lState.fItems.Count;
    Result.RawDropped := lState.fRawDropped;
    Result.IncidentDropped := lState.fIncidentDropped;
  finally
    lState.fLock.Release;
  end;
end;

function TMachineOverviewHistoryBacklog.Enqueue(
  const aItem: TMachineOverviewHistoryItem):
  TMachineOverviewHistoryEnqueueResult;
var
  lDropIndex: Integer;
  lState: TMachineOverviewHistoryBacklogState;
  i: Integer;
begin
  lState := GetHistoryBacklogState(fState);
  lState.fLock.Acquire;
  try
    if lState.fItems.Count < lState.fCapacity then
    begin
      lState.fItems.Add(aItem);
      Exit(TMachineOverviewHistoryEnqueueResult.Queued);
    end;
    lDropIndex := -1;
    for i := 0 to lState.fItems.Count - 1 do
      if lState.fItems[i].Kind = TMachineOverviewHistoryItemKind.RawSample then
      begin
        lDropIndex := i;
        Break;
      end;
    if lDropIndex >= 0 then
    begin
      lState.fItems.Delete(lDropIndex);
      Inc(lState.fRawDropped);
      lState.fItems.Add(aItem);
      Exit(TMachineOverviewHistoryEnqueueResult.Queued);
    end;
    if aItem.Kind = TMachineOverviewHistoryItemKind.RawSample then
      Inc(lState.fRawDropped)
    else
      Inc(lState.fIncidentDropped);
    Result := TMachineOverviewHistoryEnqueueResult.Dropped;
  finally
    lState.fLock.Release;
  end;
end;

function TMachineOverviewHistoryBacklog.PeekBatch(
  const aMaximumCount: Integer): TArray<TMachineOverviewHistoryItem>;
var
  lCopyCount: Integer;
  lState: TMachineOverviewHistoryBacklogState;
  i: Integer;
begin
  if aMaximumCount <= 0 then
    raise EArgumentOutOfRangeException.Create(
      'History backlog batch size must be positive');
  lState := GetHistoryBacklogState(fState);
  lState.fLock.Acquire;
  try
    lCopyCount := aMaximumCount;
    if lState.fItems.Count < lCopyCount then
      lCopyCount := lState.fItems.Count;
    SetLength(Result, lCopyCount);
    for i := 0 to lCopyCount - 1 do
      Result[i] := lState.fItems[i];
  finally
    lState.fLock.Release;
  end;
end;

procedure TMachineOverviewHistoryBacklog.RemoveFirst(const aCount: Integer);
var
  lRemainingCount: Integer;
  lState: TMachineOverviewHistoryBacklogState;
begin
  if aCount < 0 then
    raise EArgumentOutOfRangeException.Create(
      'History backlog removal count cannot be negative');
  lState := GetHistoryBacklogState(fState);
  lState.fLock.Acquire;
  try
    if aCount > lState.fItems.Count then
      raise EArgumentOutOfRangeException.Create(
        'History backlog removal exceeds the queued item count');
    lRemainingCount := aCount;
    while lRemainingCount > 0 do
    begin
      lState.fItems.Delete(0);
      Dec(lRemainingCount);
    end;
  finally
    lState.fLock.Release;
  end;
end;

constructor TMachineOverviewHistoryBacklogState.Create(
  const aCapacity: Integer);
begin
  inherited Create;
  if aCapacity <= 0 then
    raise EArgumentOutOfRangeException.Create(
      'History backlog capacity must be positive');
  fCapacity := aCapacity;
  fItems := TList<TMachineOverviewHistoryItem>.Create;
  fLock := TCriticalSection.Create;
end;

destructor TMachineOverviewHistoryBacklogState.Destroy;
begin
  fLock.Free;
  fItems.Free;
  inherited Destroy;
end;

constructor TMachineOverviewHistoryServiceState.Create(
  const aPipeline: TMachineOverviewPipeline;
  const aConfig: TMachineOverviewHistoryConfig);
begin
  inherited Create;
  Config := aConfig;
  Pipeline := aPipeline;
  Backlog := TMachineOverviewHistoryBacklog.Create(Max(1,
    aConfig.QueueCapacity));
  DiagnosticsLock := TCriticalSection.Create;
  DrainedEvent := TEvent.Create(nil, True, True, '');
  InitializedEvent := TEvent.Create(nil, True, False, '');
  LifecycleLock := TCriticalSection.Create;
  WakeEvent := TEvent.Create(nil, False, False, '');
end;

destructor TMachineOverviewHistoryServiceState.Destroy;
begin
  Worker.Free;
  WakeEvent.Free;
  LifecycleLock.Free;
  InitializedEvent.Free;
  DrainedEvent.Free;
  DiagnosticsLock.Free;
  Backlog.Free;
  inherited Destroy;
end;

procedure TMachineOverviewHistoryServiceState.MarkAccepted;
begin
  DiagnosticsLock.Acquire;
  try
    Inc(DiagnosticsData.Accepted);
  finally
    DiagnosticsLock.Release;
  end;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.MarkCommitFailure(
  const aError: string);
begin
  DiagnosticsLock.Acquire;
  try
    Inc(DiagnosticsData.RetryCount);
    DiagnosticsData.LastCommitAvailable := False;
    DiagnosticsData.LastError := aError;
  finally
    DiagnosticsLock.Release;
  end;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.MarkCommitSuccess(
  const aCount: Integer; const aDurationMs: UInt64;
  const aStorageCapDropped: Integer);
begin
  DiagnosticsLock.Acquire;
  try
    Inc(DiagnosticsData.Persisted, aCount);
    DiagnosticsData.LastCommitAvailable := True;
    DiagnosticsData.LastCommitDurationMs := aDurationMs;
    DiagnosticsData.LastError := '';
    Inc(DiagnosticsData.StorageCapDropped, aStorageCapDropped);
  finally
    DiagnosticsLock.Release;
  end;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.MarkInitialized(
  const aAvailable: Boolean; const aError: string);
begin
  DiagnosticsLock.Acquire;
  try
    DiagnosticsData.Available := aAvailable;
    DiagnosticsData.Initialized := True;
    DiagnosticsData.LastError := aError;
  finally
    DiagnosticsLock.Release;
  end;
  InitializedEvent.SetEvent;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.MarkIncidentHydration(
  const aCount: Integer);
begin
  DiagnosticsLock.Acquire;
  try
    DiagnosticsData.HydratedIncidentCount := Max(0, aCount);
  finally
    DiagnosticsLock.Release;
  end;
end;

procedure TMachineOverviewHistoryServiceState.MarkWorkerStarted;
begin
  DiagnosticsLock.Acquire;
  try
    DiagnosticsData.ActiveWorkerCount := 1;
    DiagnosticsData.WriterThreadId := GetCurrentThreadId;
  finally
    DiagnosticsLock.Release;
  end;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.MarkWorkerStopped;
begin
  DiagnosticsLock.Acquire;
  try
    DiagnosticsData.ActiveWorkerCount := 0;
  finally
    DiagnosticsLock.Release;
  end;
  PublishDiagnostics;
end;

procedure TMachineOverviewHistoryServiceState.PublishDiagnostics;
var
  lBacklog: TMachineOverviewHistoryBacklogDiagnostics;
  lDiagnostics: TMachineOverviewHistoryDiagnostics;
begin
  if not Assigned(Pipeline) then
    Exit;
  DiagnosticsLock.Acquire;
  try
    lDiagnostics := DiagnosticsData;
  finally
    DiagnosticsLock.Release;
  end;
  lBacklog := Backlog.Diagnostics;
  Pipeline.UpdateHistoryWriterDiagnostics(lBacklog.Count,
    lBacklog.RawDropped + lBacklog.IncidentDropped,
    lDiagnostics.LastCommitAvailable,
    lDiagnostics.LastCommitDurationMs, lDiagnostics.LastError);
end;

constructor TMachineOverviewHistoryWorker.Create(
  const aServiceState: TMachineOverviewHistoryServiceState);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fServiceState := aServiceState;
end;

procedure TMachineOverviewHistoryWorker.Execute;
var
  lBatch: TArray<TMachineOverviewHistoryItem>;
  lChange: TMachineOverviewIncidentChange;
  lCommitStartedMs: UInt64;
  lCommitFailed: Boolean;
  lDiagnostics: TMachineOverviewHistoryBacklogDiagnostics;
  lEnqueueResult: TMachineOverviewHistoryEnqueueResult;
  lFlushRequested: Boolean;
  lIncidentError: string;
  lIncidents: TArray<TMachineOverviewIncident>;
  lItem: TMachineOverviewHistoryItem;
  lNextCommitMs: UInt64;
  lNowMs: UInt64;
  lSample: IMachineOverviewRawSample;
  lStore: TMachineOverviewHistoryStore;
  lStopping: Boolean;
  lStorageCapDropped: Integer;
  lWaitMs: Cardinal;
begin
  lStore := nil;
  fServiceState.MarkWorkerStarted;
  try
    try
      lStore := TMachineOverviewHistoryStore.Create(fServiceState.Config);
      if Assigned(fServiceState.Pipeline) then
      begin
        lIncidentError := '';
        try
          lIncidents := lStore.LoadIncidents(
            IncHour(TTimeZone.Local.ToUniversalTime(Now), -24), 10000);
          fServiceState.Pipeline.MergePersistedIncidents(lIncidents);
          fServiceState.MarkIncidentHydration(Length(lIncidents));
        except
          on lException: Exception do
            lIncidentError := lException.Message;
        end;
        if not lIncidentError.IsEmpty then
          OutputDebugString(PChar('Machine Overview incident hydration: ' +
            lIncidentError));
      end;
      fServiceState.MarkInitialized(True, lIncidentError);
    except
      on lException: Exception do
      begin
        fServiceState.MarkInitialized(False, lException.Message);
        while TInterlocked.CompareExchange(fServiceState.Stopping, 0, 0) = 0 do
          fServiceState.WakeEvent.WaitFor(250);
        Exit;
      end;
    end;
    lNextCommitMs := GetTickCount64 + fServiceState.Config.CommitIntervalMs;
    while True do
    begin
      while Assigned(fServiceState.Pipeline) and
        fServiceState.Pipeline.TryTakeHistory(lSample) do
      begin
        lEnqueueResult := fServiceState.Backlog.Enqueue(
          TMachineOverviewHistoryItem.CreateRaw(lSample));
        if lEnqueueResult = TMachineOverviewHistoryEnqueueResult.Queued then
          fServiceState.MarkAccepted;
        fServiceState.DrainedEvent.ResetEvent;
      end;
      while Assigned(fServiceState.Pipeline) and
        fServiceState.Pipeline.TryTakeIncident(lChange) do
      begin
        lEnqueueResult := fServiceState.Backlog.Enqueue(
          TMachineOverviewHistoryItem.CreateIncident(lChange));
        if lEnqueueResult = TMachineOverviewHistoryEnqueueResult.Queued then
          fServiceState.MarkAccepted;
        fServiceState.DrainedEvent.ResetEvent;
      end;
      fServiceState.PublishDiagnostics;
      lNowMs := GetTickCount64;
      lStopping := TInterlocked.CompareExchange(fServiceState.Stopping,
        0, 0) <> 0;
      lFlushRequested := TInterlocked.CompareExchange(
        fServiceState.FlushRequested, 0, 0) <> 0;
      lDiagnostics := fServiceState.Backlog.Diagnostics;
      if (lDiagnostics.Count > 0) and (lFlushRequested or lStopping or
        (lNowMs >= lNextCommitMs)) then
      begin
        lBatch := fServiceState.Backlog.PeekBatch(
          cMachineOverviewHistoryWriteBatchSize);
        TInterlocked.Exchange(fServiceState.InFlightCount, Length(lBatch));
        fServiceState.Backlog.RemoveFirst(Length(lBatch));
        lCommitStartedMs := GetTickCount64;
        lCommitFailed := False;
        try
          lStorageCapDropped := lStore.WriteBatch(lBatch);
          fServiceState.MarkCommitSuccess(Length(lBatch),
            GetTickCount64 - lCommitStartedMs, lStorageCapDropped);
          TInterlocked.Exchange(fServiceState.InFlightCount, 0);
          lNextCommitMs := GetTickCount64 +
            fServiceState.Config.CommitIntervalMs;
        except
          on lException: Exception do
          begin
            for lItem in lBatch do
            begin
              lEnqueueResult := fServiceState.Backlog.Enqueue(lItem);
              if lEnqueueResult = TMachineOverviewHistoryEnqueueResult.Dropped then
                fServiceState.PublishDiagnostics;
            end;
            TInterlocked.Exchange(fServiceState.InFlightCount, 0);
            fServiceState.MarkCommitFailure(lException.Message);
            lCommitFailed := True;
            lNextCommitMs := GetTickCount64 +
              cMachineOverviewHistoryRetryDelayMs;
          end;
        end;
        lStopping := TInterlocked.CompareExchange(fServiceState.Stopping,
          0, 0) <> 0;
        if lCommitFailed and lStopping then
          Break;
        Continue;
      end;
      if (lDiagnostics.Count = 0) and
        (TInterlocked.CompareExchange(fServiceState.InFlightCount, 0, 0) = 0) then
      begin
        TInterlocked.Exchange(fServiceState.FlushRequested, 0);
        fServiceState.DrainedEvent.SetEvent;
        if lStopping then
          Break;
      end;
      if lStopping and (fServiceState.StopDeadlineMs > 0) and
        (lNowMs >= fServiceState.StopDeadlineMs) then
        Break;
      lWaitMs := 250;
      if (not lStopping) and (lNextCommitMs > lNowMs) then
        lWaitMs := Cardinal(Min(UInt64(lWaitMs), lNextCommitMs - lNowMs));
      fServiceState.WakeEvent.WaitFor(lWaitMs);
    end;
  finally
    lStore.Free;
    fServiceState.DrainedEvent.SetEvent;
    fServiceState.MarkWorkerStopped;
  end;
end;

constructor TMachineOverviewHistoryService.Create(
  const aPipeline: TMachineOverviewPipeline;
  const aConfig: TMachineOverviewHistoryConfig);
begin
  inherited Create;
  fState := TMachineOverviewHistoryServiceState.Create(aPipeline, aConfig);
end;

destructor TMachineOverviewHistoryService.Destroy;
var
  lState: TMachineOverviewHistoryServiceState;
  lStopResult: TMachineOverviewShutdownResult;
begin
  lState := GetHistoryServiceState(fState);
  if Assigned(lState) and Assigned(lState.Worker) then
  begin
    lStopResult := Stop(5000);
    if (lStopResult = TMachineOverviewShutdownResult.TimedOut) or
      (WaitForSingleObject(lState.Worker.Handle, 0) <> WAIT_OBJECT_0) then
    begin
      lState.StopDeadlineMs := GetTickCount64;
      lState.WakeEvent.SetEvent;
      lState.Worker.WaitFor;
    end;
  end;
  fState.Free;
  inherited Destroy;
end;

function TMachineOverviewHistoryService.Diagnostics:
  TMachineOverviewHistoryDiagnostics;
var
  lBacklog: TMachineOverviewHistoryBacklogDiagnostics;
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  lState.DiagnosticsLock.Acquire;
  try
    Result := lState.DiagnosticsData;
  finally
    lState.DiagnosticsLock.Release;
  end;
  lBacklog := lState.Backlog.Diagnostics;
  Result.QueueDepth := lBacklog.Count;
  Result.RawDropped := lBacklog.RawDropped;
  Result.IncidentDropped := lBacklog.IncidentDropped;
end;

function TMachineOverviewHistoryService.EnqueueRaw(
  const aSample: IMachineOverviewRawSample):
  TMachineOverviewHistoryEnqueueResult;
var
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  if (not Assigned(aSample)) or (not lState.Config.Enabled) or
    (not lState.Started) or
    (TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0) then
    Exit(TMachineOverviewHistoryEnqueueResult.Stopped);
  Result := lState.Backlog.Enqueue(
    TMachineOverviewHistoryItem.CreateRaw(aSample));
  if Result = TMachineOverviewHistoryEnqueueResult.Queued then
    lState.MarkAccepted;
  lState.DrainedEvent.ResetEvent;
  lState.WakeEvent.SetEvent;
  lState.PublishDiagnostics;
end;

function TMachineOverviewHistoryService.EnqueueIncident(
  const aChange: TMachineOverviewIncidentChange):
  TMachineOverviewHistoryEnqueueResult;
var
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  if aChange.Incident.StableId.IsEmpty or (not lState.Config.Enabled) or
    (not lState.Started) or
    (TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0) then
    Exit(TMachineOverviewHistoryEnqueueResult.Stopped);
  Result := lState.Backlog.Enqueue(
    TMachineOverviewHistoryItem.CreateIncident(aChange));
  if Result = TMachineOverviewHistoryEnqueueResult.Queued then
    lState.MarkAccepted;
  lState.DrainedEvent.ResetEvent;
  lState.WakeEvent.SetEvent;
  lState.PublishDiagnostics;
end;

function TMachineOverviewHistoryService.Flush(
  const aTimeoutMs: Cardinal): Boolean;
var
  lDeadlineMs: UInt64;
  lDiagnostics: TMachineOverviewHistoryBacklogDiagnostics;
  lPipelineDepth: Integer;
  lRemainingMs: Cardinal;
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  if not lState.Config.Enabled then
    Exit(True);
  if (not lState.Started) or
    (TInterlocked.CompareExchange(lState.Stopping, 0, 0) <> 0) then
    Exit(False);
  lDeadlineMs := GetTickCount64 + aTimeoutMs;
  TInterlocked.Exchange(lState.FlushRequested, 1);
  lState.DrainedEvent.ResetEvent;
  lState.WakeEvent.SetEvent;
  repeat
    if GetTickCount64 >= lDeadlineMs then
      Exit(False);
    lRemainingMs := Cardinal(Min(UInt64(250),
      lDeadlineMs - GetTickCount64));
    lState.DrainedEvent.WaitFor(lRemainingMs);
    lDiagnostics := lState.Backlog.Diagnostics;
    lPipelineDepth := 0;
    if Assigned(lState.Pipeline) then
      lPipelineDepth := lState.Pipeline.Diagnostics.HistoryQueueDepth;
    Result := (lDiagnostics.Count = 0) and
      (lPipelineDepth = 0) and
      (TInterlocked.CompareExchange(lState.InFlightCount, 0, 0) = 0);
    if not Result then
    begin
      lState.DrainedEvent.ResetEvent;
      lState.WakeEvent.SetEvent;
    end;
  until Result;
end;

procedure TMachineOverviewHistoryService.Start;
var
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  lState.LifecycleLock.Acquire;
  try
    if lState.Started then
      Exit;
    lState.Started := True;
    if not lState.Config.Enabled then
    begin
      lState.MarkInitialized(False, 'History is disabled');
      Exit;
    end;
    lState.Worker := TMachineOverviewHistoryWorker.Create(lState);
    lState.Worker.Start;
  finally
    lState.LifecycleLock.Release;
  end;
end;

function TMachineOverviewHistoryService.Stop(
  const aTimeoutMs: Cardinal): TMachineOverviewShutdownResult;
var
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  lState.LifecycleLock.Acquire;
  try
    if not Assigned(lState.Worker) then
      Exit(TMachineOverviewShutdownResult.Stopped);
    TInterlocked.Exchange(lState.Stopping, 1);
    lState.StopDeadlineMs := GetTickCount64 + aTimeoutMs;
    lState.WakeEvent.SetEvent;
  finally
    lState.LifecycleLock.Release;
  end;
  if WaitForSingleObject(lState.Worker.Handle, aTimeoutMs) = WAIT_OBJECT_0 then
  begin
    lState.Worker.WaitFor;
    Result := TMachineOverviewShutdownResult.Stopped;
  end else
    Result := TMachineOverviewShutdownResult.TimedOut;
end;

function TMachineOverviewHistoryService.WaitUntilInitialized(
  const aTimeoutMs: Cardinal): Boolean;
var
  lState: TMachineOverviewHistoryServiceState;
begin
  lState := GetHistoryServiceState(fState);
  Result := lState.InitializedEvent.WaitFor(aTimeoutMs) = wrSignaled;
end;

function MachineOverviewHistoryDatabasePath(
  const aInstallDirectory: string): string;
begin
  Result := TPath.Combine(aInstallDirectory,
    cMachineOverviewHistoryDatabaseFileName);
end;

function PackMachineOverviewLogicalProcessors(
  const aValues: TArray<TMachineOverviewOptionalDouble>): TBytes;
var
  lEncoded: Integer;
  lScaled: Integer;
  i: Integer;
begin
  if Length(aValues) > High(Word) then
    raise EArgumentOutOfRangeException.Create(
      'Logical-processor history count exceeds the packed format');
  SetLength(Result, 8 + (Length(aValues) * 2));
  Result[0] := Ord('M');
  Result[1] := Ord('O');
  Result[2] := Ord('C');
  Result[3] := Ord('P');
  Result[4] := 1;
  Result[5] := 2;
  Result[6] := Byte(Length(aValues) and $FF);
  Result[7] := Byte((Length(aValues) shr 8) and $FF);
  for i := 0 to High(aValues) do
  begin
    if not aValues[i].Available then
      lEncoded := High(Word)
    else
    begin
      lScaled := Round(EnsureRange(aValues[i].Value, 0.0, 100.0) * 100);
      lEncoded := lScaled;
    end;
    Result[8 + (i * 2)] := Byte(lEncoded and $FF);
    Result[9 + (i * 2)] := Byte((lEncoded shr 8) and $FF);
  end;
end;

function TryUnpackMachineOverviewLogicalProcessors(const aData: TBytes;
  out aValues: TArray<TMachineOverviewOptionalDouble>): Boolean;
var
  lCount: Integer;
  lEncoded: Word;
  lValues: TArray<TMachineOverviewOptionalDouble>;
  i: Integer;
begin
  aValues := nil;
  Result := (Length(aData) >= 8) and
    (aData[0] = Ord('M')) and (aData[1] = Ord('O')) and
    (aData[2] = Ord('C')) and (aData[3] = Ord('P')) and
    (aData[4] = 1) and (aData[5] = 2);
  if not Result then
    Exit;
  lCount := aData[6] or (Integer(aData[7]) shl 8);
  Result := Length(aData) = 8 + (lCount * 2);
  if not Result then
    Exit;
  SetLength(lValues, lCount);
  for i := 0 to lCount - 1 do
  begin
    lEncoded := Word(aData[8 + (i * 2)]) or
      (Word(aData[9 + (i * 2)]) shl 8);
    if lEncoded = High(Word) then
      Continue;
    if lEncoded > 10000 then
      Exit(False);
    lValues[i].Available := True;
    lValues[i].Value := lEncoded / 100.0;
  end;
  aValues := lValues;
end;

function TryLoadMachineOverviewIncidents(const aDatabaseFileName: string;
  const aEarliestUtc: TDateTime; const aMaximumCount: Integer;
  out aIncidents: TArray<TMachineOverviewIncident>;
  out aError: string): Boolean;
var
  lConnection: TFDConnection;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lIncident: TMachineOverviewIncident;
  lIndex: Integer;
  lOrdinal: Integer;
  lQuery: TFDQuery;
  lStage: string;
begin
  aIncidents := nil;
  aError := '';
  if aDatabaseFileName.Trim.IsEmpty or
    (not TFile.Exists(aDatabaseFileName)) then
    Exit(True);
  lConnection := nil;
  lQuery := nil;
  try
    try
      lStage := 'create connection';
      lConnection := TFDConnection.Create(nil);
      lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
      lDriverLink.DriverID := cMachineOverviewSQLiteDriverId;
      lDriverLink.EngineLinkage := slDynamic;
      lDriverLink.VendorLib := TPath.Combine(ExtractFilePath(ParamStr(0)),
        'sqlite3.dll');
      lConnection.LoginPrompt := False;
      lConnection.ResourceOptions.SilentMode := True;
      lConnection.Params.Values['DriverID'] := cMachineOverviewSQLiteDriverId;
      lConnection.Params.Values['Database'] := aDatabaseFileName;
      lConnection.Params.Values['OpenMode'] := 'ReadWrite';
      lConnection.Params.Values['LockingMode'] := 'Normal';
      lConnection.Params.Values['SharedCache'] := 'False';
      lConnection.Params.Values['BusyTimeout'] := '100';
      lStage := 'open dedicated query connection';
      lConnection.Connected := True;
      lStage := 'set query-only mode';
      lConnection.ExecSQL('PRAGMA query_only=ON');
      lStage := 'prepare incident query';
      lQuery := TFDQuery.Create(nil);
      lQuery.Connection := lConnection;
      lQuery.SQL.Text := 'SELECT incident_key, ' +
        'CAST(started_utc_ms AS TEXT) AS started_utc_ms_text, ' +
        'CAST(peak_utc_ms AS TEXT) AS peak_utc_ms_text, ' +
        'CAST(ended_utc_ms AS TEXT) AS ended_utc_ms_text, ' +
        'category, severity, origin, local_display_time, ' +
        'summary, explanation, threshold_text, peak_value, provider_id, ' +
        'CAST(provider_freshness_ms AS TEXT) AS provider_freshness_ms_text, ' +
        'related_entity_ids_json, ' +
        'related_executable_paths_json, trace_status, pre_context_json, ' +
        'post_context_json FROM incident WHERE started_utc_ms >= :earliest ' +
        'ORDER BY started_utc_ms DESC, incident_key ASC LIMIT :maximum';
      lQuery.ParamByName('earliest').AsLargeInt :=
        HistoryUtcMilliseconds(aEarliestUtc);
      if aMaximumCount > 0 then
        lQuery.ParamByName('maximum').AsInteger := aMaximumCount
      else
        lQuery.ParamByName('maximum').AsInteger := MaxInt;
      lStage := 'open incident query';
      lQuery.Open;
      lStage := 'read incident rows';
      while not lQuery.Eof do
      begin
        lIncident := Default(TMachineOverviewIncident);
        lIncident.StableId := lQuery.FieldByName('incident_key').AsString;
        lIncident.StartedAtUtc := HistoryDateTimeFromMilliseconds(
          HistoryFieldInt64(lQuery.FieldByName('started_utc_ms_text')));
        lIncident.PeakAtUtc := HistoryDateTimeFromMilliseconds(
          HistoryFieldInt64(lQuery.FieldByName('peak_utc_ms_text')));
        lIncident.EndedAtUtc := HistoryDateTimeFromMilliseconds(
          HistoryNullableFieldInt64(
            lQuery.FieldByName('ended_utc_ms_text')));
        lOrdinal := lQuery.FieldByName('category').AsInteger;
        lIncident.Category := HistoryIncidentCategoryFromOrdinal(lOrdinal);
        lOrdinal := lQuery.FieldByName('severity').AsInteger;
        lIncident.Severity := HistorySeverityFromOrdinal(lOrdinal);
        lOrdinal := lQuery.FieldByName('origin').AsInteger;
        lIncident.Origin := HistoryIncidentOriginFromOrdinal(lOrdinal);
        lIncident.LocalDisplayTime :=
          lQuery.FieldByName('local_display_time').AsString;
        lIncident.Summary := lQuery.FieldByName('summary').AsString;
        lIncident.Explanation := lQuery.FieldByName('explanation').AsString;
        lIncident.ThresholdText :=
          lQuery.FieldByName('threshold_text').AsString;
        lIncident.PeakValue := lQuery.FieldByName('peak_value').AsFloat;
        lIncident.ProviderId := lQuery.FieldByName('provider_id').AsString;
        lIncident.ProviderFreshnessMs :=
          HistoryFieldInt64(
            lQuery.FieldByName('provider_freshness_ms_text'));
        if not TryHistoryStringArrayFromJson(
          lQuery.FieldByName('related_entity_ids_json').AsString,
          lIncident.RelatedEntityIds) then
          raise EConvertError.Create('Invalid incident related-entity data');
        if not TryHistoryStringArrayFromJson(
          lQuery.FieldByName('related_executable_paths_json').AsString,
          lIncident.RelatedExecutablePaths) then
          raise EConvertError.Create('Invalid incident executable-path data');
        lOrdinal := lQuery.FieldByName('trace_status').AsInteger;
        lIncident.TraceStatus := HistoryTraceStatusFromOrdinal(lOrdinal);
        if not TryHistoryContextFromJson(
          lQuery.FieldByName('pre_context_json').AsString,
          lIncident.PreContext) then
          raise EConvertError.Create('Invalid incident pre-context data');
        if not TryHistoryContextFromJson(
          lQuery.FieldByName('post_context_json').AsString,
          lIncident.PostContext) then
          raise EConvertError.Create('Invalid incident post-context data');
        lIndex := Length(aIncidents);
        SetLength(aIncidents, lIndex + 1);
        aIncidents[lIndex] := lIncident;
        lQuery.Next;
      end;
      Result := True;
    except
      on lException: Exception do
      begin
        aIncidents := nil;
        aError := lStage + ': ' + lException.Message;
        Result := False;
      end;
    end;
  finally
    lQuery.Free;
    lConnection.Free;
  end;
end;

end.

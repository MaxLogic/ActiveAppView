unit ActiveAppView.RenameJournal;

interface

uses
  System.IniFiles, System.SysUtils,
  Winapi.Windows;

type
  TRenameJournalConfig = record
    DatabaseFileName: string;
    Enabled: Boolean;
  end;

  TRenameJournalWriteResult = (rjwrDisabled, rjwrSaved, rjwrFailed);

function TryRecordWindowRename(
  const aConfig: TRenameJournalConfig;
  const aWnd: HWND;
  const aProcessId: Cardinal;
  const aRenamedAt: Int64;
  const aNewCaption: string;
  out aErrorMessage: string
): TRenameJournalWriteResult;
function LoadRenameJournalConfig(const aIniFile: TCustomIniFile): TRenameJournalConfig;

implementation

uses
  System.IOUtils,
  AutoFree,
  FireDAC.Comp.Client, FireDAC.DApt, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, FireDAC.Stan.Async, FireDAC.Stan.Def,
  FireDAC.VCLUI.Wait;

const
  cRenameJournalBusyTimeoutMs = 250;
  cRenameJournalSettingsSection = 'save-renames-to-journal';

function LoadRenameJournalConfig(const aIniFile: TCustomIniFile): TRenameJournalConfig;
begin
  Result.Enabled := aIniFile.ReadBool(cRenameJournalSettingsSection, 'enabled', False);
  Result.DatabaseFileName := Trim(aIniFile.ReadString(cRenameJournalSettingsSection, 'db-file', ''));
end;

procedure ConfigureRenameJournalConnection(
  const aDatabaseFileName: string;
  const aConnection: TFDConnection
);
begin
  aConnection.LoginPrompt := False;
  aConnection.ResourceOptions.SilentMode := True;
  aConnection.UpdateOptions.LockWait := True;
  aConnection.Params.Values['DriverID'] := 'SQLite';
  aConnection.Params.Values['Database'] := aDatabaseFileName;
  aConnection.Params.Values['OpenMode'] := 'ReadWrite';
  aConnection.Params.Values['LockingMode'] := 'Normal';
  aConnection.Params.Values['Synchronous'] := 'Normal';
  aConnection.Params.Values['JournalMode'] := 'WAL';
  aConnection.Params.Values['SharedCache'] := 'False';
  aConnection.Params.Values['BusyTimeout'] := IntToStr(cRenameJournalBusyTimeoutMs);
end;

function TryRecordWindowRename(
  const aConfig: TRenameJournalConfig;
  const aWnd: HWND;
  const aProcessId: Cardinal;
  const aRenamedAt: Int64;
  const aNewCaption: string;
  out aErrorMessage: string
): TRenameJournalWriteResult;
var
  g: TGarbos;
  lConnection: TFDConnection;
  lDriverLink: TFDPhysSQLiteDriverLink;
  lQuery: TFDQuery;
begin
  g := Default(TGarbos);
  aErrorMessage := '';
  if not aConfig.Enabled then
    Exit(rjwrDisabled);

  try
    if not TFile.Exists(aConfig.DatabaseFileName) then
    begin
      aErrorMessage := 'Shadow Journal database does not exist: ' + aConfig.DatabaseFileName;
      Exit(rjwrFailed);
    end;

    GC(lConnection, TFDConnection.Create(nil), g);
    lDriverLink := TFDPhysSQLiteDriverLink.Create(lConnection);
    lDriverLink.DriverID := 'SQLite';
    GC(lQuery, TFDQuery.Create(nil), g);
    ConfigureRenameJournalConnection(aConfig.DatabaseFileName, lConnection);
    lConnection.Connected := True;
    lQuery.Connection := lConnection;
    lQuery.SQL.Text :=
      'INSERT INTO window_rename_events (renamed_at, hwnd, pid, new_caption) ' +
      'VALUES (:renamed_at, :hwnd, :pid, :new_caption);';
    lQuery.ParamByName('renamed_at').AsLargeInt := aRenamedAt;
    lQuery.ParamByName('hwnd').AsLargeInt := Int64(NativeUInt(aWnd));
    lQuery.ParamByName('pid').AsLargeInt := aProcessId;
    lQuery.ParamByName('new_caption').AsWideString := aNewCaption;
    lQuery.ExecSQL;
    Result := rjwrSaved;
  except
    on lException: Exception do
    begin
      aErrorMessage := lException.ClassName + ': ' + lException.Message;
      Result := rjwrFailed;
    end;
  end;
end;

end.

unit ActiveAppView.MachineOverview.Settings;

interface

uses
  System.IniFiles;

type
  TMachineOverviewSettings = record
    Enabled: Boolean;
    DisplayRefreshIntervalMs: Integer;
    PanelWidth: Integer;
    SystemSampleIntervalMs: Integer;
    ProcessSampleIntervalMs: Integer;
    TemperatureSampleIntervalMs: Integer;
    HistoryCommitIntervalMs: Integer;
    HistoryDatabaseFileName: string;
    HistoryEnabled: Boolean;
    RawRetentionHours: Integer;
    Rollup10sRetentionDays: Integer;
    Rollup1mRetentionDays: Integer;
    MaxDatabaseSizeMB: Integer;
    DetailedTraceEnabled: Boolean;
    class function Defaults: TMachineOverviewSettings; static;
  end;

function LoadMachineOverviewSettings(const aIniFile: TCustomIniFile): TMachineOverviewSettings;
function ScaleMachineOverviewPanelWidth(const aLogicalWidth,
  aPixelsPerInch: Integer): Integer;
procedure SaveMachineOverviewPanelWidth(const aIniFile: TCustomIniFile;
  const aPixelWidth, aPixelsPerInch: Integer);
procedure SaveMachineOverviewPanelWidthToFile(const aFileName: string;
  const aPixelWidth, aPixelsPerInch: Integer);

implementation

uses
  Winapi.Windows,
  AutoFree;

const
  cMachineOverviewSectionName = 'MachineOverview';
  cMinimumDisplayRefreshIntervalMs = 2000;
  cMaximumDisplayRefreshIntervalMs = 60000;
  cDefaultPixelsPerInch = 96;
  cMinimumPanelWidth = 240;
  cMaximumPanelWidth = 1200;

function ValidPanelWidth(const aValue, aDefault: Integer): Integer;
begin
  if (aValue < cMinimumPanelWidth) or (aValue > cMaximumPanelWidth) then
    Result := aDefault
  else
    Result := aValue;
end;

function ClampDisplayRefreshInterval(const aValue: Integer): Integer;
begin
  Result := aValue;
  if Result < cMinimumDisplayRefreshIntervalMs then
    Result := cMinimumDisplayRefreshIntervalMs
  else if Result > cMaximumDisplayRefreshIntervalMs then
    Result := cMaximumDisplayRefreshIntervalMs;
end;

class function TMachineOverviewSettings.Defaults: TMachineOverviewSettings;
begin
  Result := Default(TMachineOverviewSettings);
  Result.Enabled := True;
  Result.DisplayRefreshIntervalMs := 10000;
  Result.PanelWidth := 420;
  Result.SystemSampleIntervalMs := 1000;
  Result.ProcessSampleIntervalMs := 2000;
  Result.TemperatureSampleIntervalMs := 3000;
  Result.HistoryCommitIntervalMs := 10000;
  Result.HistoryEnabled := True;
  Result.RawRetentionHours := 48;
  Result.Rollup10sRetentionDays := 30;
  Result.Rollup1mRetentionDays := 365;
  Result.MaxDatabaseSizeMB := 2048;
  Result.DetailedTraceEnabled := False;
end;

function LoadMachineOverviewSettings(const aIniFile: TCustomIniFile): TMachineOverviewSettings;
begin
  Result := TMachineOverviewSettings.Defaults;
  if not Assigned(aIniFile) then
    Exit;

  Result.Enabled := aIniFile.ReadBool(cMachineOverviewSectionName, 'Enabled', Result.Enabled);
  Result.DisplayRefreshIntervalMs := ClampDisplayRefreshInterval(aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'DisplayRefreshIntervalMs', Result.DisplayRefreshIntervalMs));
  Result.PanelWidth := ValidPanelWidth(aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'PanelWidth', Result.PanelWidth),
    Result.PanelWidth);
  Result.SystemSampleIntervalMs := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'SystemSampleIntervalMs', Result.SystemSampleIntervalMs);
  Result.ProcessSampleIntervalMs := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'ProcessSampleIntervalMs', Result.ProcessSampleIntervalMs);
  Result.TemperatureSampleIntervalMs := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'TemperatureSampleIntervalMs', Result.TemperatureSampleIntervalMs);
  Result.HistoryCommitIntervalMs := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'HistoryCommitIntervalMs', Result.HistoryCommitIntervalMs);
  Result.HistoryEnabled := aIniFile.ReadBool(
    cMachineOverviewSectionName, 'HistoryEnabled', Result.HistoryEnabled);
  Result.RawRetentionHours := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'RawRetentionHours', Result.RawRetentionHours);
  Result.Rollup10sRetentionDays := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'Rollup10sRetentionDays', Result.Rollup10sRetentionDays);
  Result.Rollup1mRetentionDays := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'Rollup1mRetentionDays', Result.Rollup1mRetentionDays);
  Result.MaxDatabaseSizeMB := aIniFile.ReadInteger(
    cMachineOverviewSectionName, 'MaxDatabaseSizeMB', Result.MaxDatabaseSizeMB);
  Result.DetailedTraceEnabled := aIniFile.ReadBool(
    cMachineOverviewSectionName, 'DetailedTraceEnabled', Result.DetailedTraceEnabled);
end;

function ScaleMachineOverviewPanelWidth(const aLogicalWidth,
  aPixelsPerInch: Integer): Integer;
var
  lPixelsPerInch: Integer;
begin
  lPixelsPerInch := aPixelsPerInch;
  if lPixelsPerInch <= 0 then
    lPixelsPerInch := cDefaultPixelsPerInch;
  Result := MulDiv(ValidPanelWidth(aLogicalWidth,
    TMachineOverviewSettings.Defaults.PanelWidth), lPixelsPerInch,
    cDefaultPixelsPerInch);
end;

procedure SaveMachineOverviewPanelWidth(const aIniFile: TCustomIniFile;
  const aPixelWidth, aPixelsPerInch: Integer);
var
  lLogicalWidth: Integer;
  lPixelsPerInch: Integer;
begin
  if not Assigned(aIniFile) then
    Exit;
  lPixelsPerInch := aPixelsPerInch;
  if lPixelsPerInch <= 0 then
    lPixelsPerInch := cDefaultPixelsPerInch;
  lLogicalWidth := MulDiv(aPixelWidth, cDefaultPixelsPerInch,
    lPixelsPerInch);
  lLogicalWidth := ValidPanelWidth(lLogicalWidth,
    TMachineOverviewSettings.Defaults.PanelWidth);
  aIniFile.WriteInteger(cMachineOverviewSectionName, 'PanelWidth',
    lLogicalWidth);
end;

procedure SaveMachineOverviewPanelWidthToFile(const aFileName: string;
  const aPixelWidth, aPixelsPerInch: Integer);
var
  g: TGarbos;
  lIniFile: TIniFile;
begin
  g := Default(TGarbos);
  GC(lIniFile, TIniFile.Create(aFileName), g);
  SaveMachineOverviewPanelWidth(lIniFile, aPixelWidth, aPixelsPerInch);
end;

end.

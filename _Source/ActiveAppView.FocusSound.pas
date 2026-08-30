unit ActiveAppView.FocusSound;

interface

uses
  System.IniFiles;

function LoadFocusSoundFileName(const aBasePath: string;
  aIniFile: TCustomIniFile): string;
procedure PlayFocusSound(const aFileName: string);
function RunFocusSoundSelfTests(const aArg: string): Integer;

implementation

uses
  System.IOUtils, System.SysUtils,
  Winapi.MMSystem,
  AutoFree;

const
  cFocusSoundFileKey = 'File';
  cFocusSoundSection = 'FocusSound';
  cFocusSoundSelfTestArg = '--self-test-focus-sound';

function LoadFocusSoundFileName(const aBasePath: string;
  aIniFile: TCustomIniFile): string;
begin
  Result := Trim(aIniFile.ReadString(cFocusSoundSection, cFocusSoundFileKey, ''));
  if Result = '' then
    Exit;

  if TPath.IsRelativePath(Result) then
    Result := TPath.Combine(aBasePath, Result);
end;

function TryPlayFocusSound(const aFileName: string): Boolean;
begin
  if (aFileName = '') or (not TFile.Exists(aFileName)) then
    Exit(False);

  Result := Winapi.MMSystem.PlaySound(
    PChar(aFileName),
    0,
    SND_FILENAME or SND_ASYNC or SND_NODEFAULT);
end;

procedure PlayFocusSound(const aFileName: string);
begin
  if not TryPlayFocusSound(aFileName) then
    Exit;
end;

function RunFocusSoundSelfTests(const aArg: string): Integer;
var
  g: TGarbos;
  lBasePath: string;
  lExpectedFileName: string;
  lIniFile: TMemIniFile;
  lMissingFileName: string;
  lRelativeFileName: string;
  lResolvedFileName: string;
  lSettingsFileName: string;
begin
  if not SameText(aArg, cFocusSoundSelfTestArg) then
    Exit(-1);

  Result := 0;
  lBasePath := GetCurrentDir;
  lRelativeFileName := 'assets\wav\focus2.wav';
  lExpectedFileName := TPath.Combine(lBasePath, lRelativeFileName);
  lMissingFileName := TPath.Combine(lBasePath, 'missing-focus-sound.wav');
  lSettingsFileName := TPath.GetTempFileName;
  try
    GC(lIniFile, TMemIniFile.Create(lSettingsFileName, TEncoding.UTF8, False), g);

    if LoadFocusSoundFileName(lBasePath, lIniFile) <> '' then
    begin
      Writeln('SELFTEST FAILED: absent focus sound setting must stay silent');
      Exit(1);
    end;

    lIniFile.WriteString(cFocusSoundSection, cFocusSoundFileKey, '   ');
    if LoadFocusSoundFileName(lBasePath, lIniFile) <> '' then
    begin
      Writeln('SELFTEST FAILED: blank focus sound setting must stay silent');
      Exit(1);
    end;

    lIniFile.WriteString(cFocusSoundSection, cFocusSoundFileKey, lRelativeFileName);
    lIniFile.UpdateFile;
    lResolvedFileName := LoadFocusSoundFileName(lBasePath, lIniFile);
    if not SameText(lResolvedFileName, lExpectedFileName) then
    begin
      Writeln(Format(
        'SELFTEST FAILED: relative focus sound expected="%s" actual="%s"',
        [lExpectedFileName, lResolvedFileName]));
      Exit(1);
    end;
    if not TFile.Exists(lResolvedFileName) then
    begin
      Writeln(Format('SELFTEST FAILED: focus sound fixture is missing: "%s"',
        [lResolvedFileName]));
      Exit(1);
    end;
    if not TryPlayFocusSound(lResolvedFileName) then
    begin
      Writeln('SELFTEST FAILED: configured focus sound did not start playing');
      Exit(1);
    end;
    if TryPlayFocusSound(lMissingFileName) then
    begin
      Writeln('SELFTEST FAILED: missing focus sound file must stay silent');
      Exit(1);
    end;
  finally
    g.Clear;
    TFile.Delete(lSettingsFileName);
  end;
end;

end.

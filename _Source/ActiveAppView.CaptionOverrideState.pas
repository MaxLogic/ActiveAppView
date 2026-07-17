unit ActiveAppView.CaptionOverrideState;

interface

uses
  System.SysUtils,
  Winapi.Windows;

type
  TCaptionOverrideIdentity = record
    BootId: Int64;
    HasBootId: Boolean;
    HasProcessStartedAt: Boolean;
    Hwnd: UInt64;
    ProcessId: Cardinal;
    ProcessStartedAt: Int64;
  end;

  TCaptionOverrideRecord = record
    Caption: string;
    CreatedAt: Int64;
    Identity: TCaptionOverrideIdentity;
    Reason: string;
    UpdatedAt: Int64;
  end;

  TCaptionOverrideState = TArray<TCaptionOverrideRecord>;
  TCaptionOverrideStateLoadStatus = (coslsMissing, coslsLoaded, coslsUpgraded, coslsInvalid);

  TCaptionOverrideResolvedProcess = record
    Current: Boolean;
    HasProcessStartedAt: Boolean;
    ProcessStartedAt: Int64;
  end;

  TCaptionOverrideProcessResolver = reference to function(const aWnd: HWND;
    const aProcessId: Cardinal): TCaptionOverrideResolvedProcess;

function TryLoadCaptionOverrideState(const aFileName: string; const aCurrentBootId: Int64;
  const aHasCurrentBootId: Boolean; const aProcessResolver: TCaptionOverrideProcessResolver;
  out aState: TCaptionOverrideState; out aStatus: TCaptionOverrideStateLoadStatus;
  out aErrorMessage: string): Boolean;
function TrySaveCaptionOverrideStateAtomic(const aFileName: string;
  const aState: TCaptionOverrideState; out aErrorMessage: string): Boolean;

implementation

uses
  System.Classes, System.IniFiles, System.IOUtils,
  AutoFree;

const
  cLegacyFileTimeEpochSeconds = Int64(11644473600);
  cMaximumOverrideCount = 10000;
  cMetadataSection = 'Metadata';
  cOverrideSectionPrefix = 'Override.';
  cStateVersion = 2;

type
  TCaptionOverrideLoadContext = record
    CurrentBootId: Int64;
    FileName: string;
    HasCurrentBootId: Boolean;
    ProcessResolver: TCaptionOverrideProcessResolver;
  end;

function OverrideSectionName(const aIndex: Integer): string;
begin
  Result := cOverrideSectionPrefix + IntToStr(aIndex);
end;

function TryReadRequiredInt64(const aIniFile: TCustomIniFile; const aSection: string;
  const aKey: string; out aValue: Int64): Boolean;
var
  lText: string;
begin
  lText := Trim(aIniFile.ReadString(aSection, aKey, ''));
  Result := (lText <> '') and TryStrToInt64(lText, aValue);
end;

function TryReadRequiredUInt64(const aIniFile: TCustomIniFile; const aSection: string;
  const aKey: string; out aValue: UInt64): Boolean;
var
  lText: string;
begin
  lText := Trim(aIniFile.ReadString(aSection, aKey, ''));
  Result := (lText <> '') and TryStrToUInt64(lText, aValue);
end;

function TryReadRequiredCardinal(const aIniFile: TCustomIniFile; const aSection: string;
  const aKey: string; out aValue: Cardinal): Boolean;
var
  lText: string;
begin
  lText := Trim(aIniFile.ReadString(aSection, aKey, ''));
  Result := (lText <> '') and TryStrToUInt(lText, aValue) and (aValue > 0);
  if not Result then
    aValue := 0;
end;

function TryReadOptionalInt64(const aIniFile: TCustomIniFile; const aSection: string;
  const aKey: string; out aHasValue: Boolean; out aValue: Int64): Boolean;
var
  lText: string;
begin
  aHasValue := False;
  aValue := 0;
  lText := Trim(aIniFile.ReadString(aSection, aKey, ''));
  if lText = '' then
    Exit(True);
  Result := TryStrToInt64(lText, aValue);
  aHasValue := Result;
end;

function TryParseLegacyKey(const aKey: string; out aWnd: HWND;
  out aProcessId: Cardinal): Boolean;
var
  lDelimiterIndex: Integer;
  lProcessId: Cardinal;
  lWnd: UInt64;
begin
  aWnd := 0;
  aProcessId := 0;
  lDelimiterIndex := Pos(':', aKey);
  Result := (lDelimiterIndex > 1) and (lDelimiterIndex < Length(aKey)) and
    TryStrToUInt64(Copy(aKey, lDelimiterIndex + 1, MaxInt), lWnd) and
    TryStrToUInt(Copy(aKey, 1, lDelimiterIndex - 1), lProcessId) and
    (lProcessId > 0) and (lWnd > 0);
  if not Result then
    Exit;
  aWnd := HWND(NativeUInt(lWnd));
  aProcessId := lProcessId;
end;

function LegacyBootMatches(const aLegacyBootId: Int64;
  const aCurrentBootId: Int64): Boolean;
var
  lExpectedLegacyBootId: Int64;
begin
  lExpectedLegacyBootId := (aCurrentBootId div 1000) + cLegacyFileTimeEpochSeconds;
  Result := Abs(aLegacyBootId - lExpectedLegacyBootId) <= 5;
end;

type
  TVersion2RecordValues = record
    BootId: Int64;
    CreatedAt: Int64;
    HasBootId: Boolean;
    HasProcessStartedAt: Boolean;
    Hwnd: UInt64;
    ProcessId: Cardinal;
    ProcessStartedAt: Int64;
    UpdatedAt: Int64;
  end;

function TryReadVersion2Record(const aIniFile: TCustomIniFile; const aIndex: Integer;
  out aRecord: TCaptionOverrideRecord): Boolean;
var
  lSection: string;
  lValues: TVersion2RecordValues;
begin
  aRecord := Default(TCaptionOverrideRecord);
  lSection := OverrideSectionName(aIndex);
  aRecord.Caption := aIniFile.ReadString(lSection, 'Caption', '');
  Result := (Trim(aRecord.Caption) <> '') and
    TryReadRequiredInt64(aIniFile, lSection, 'CreatedAt', lValues.CreatedAt) and
    TryReadRequiredInt64(aIniFile, lSection, 'UpdatedAt', lValues.UpdatedAt) and
    TryReadRequiredUInt64(aIniFile, lSection, 'Hwnd', lValues.Hwnd) and
    TryReadRequiredCardinal(aIniFile, lSection, 'Pid', lValues.ProcessId) and
    TryReadOptionalInt64(aIniFile, lSection, 'BootId',
      lValues.HasBootId, lValues.BootId) and
    TryReadOptionalInt64(aIniFile, lSection, 'ProcessStartedAt',
      lValues.HasProcessStartedAt, lValues.ProcessStartedAt);
  if not Result then
    Exit;
  aRecord.CreatedAt := lValues.CreatedAt;
  aRecord.UpdatedAt := lValues.UpdatedAt;
  aRecord.Identity.BootId := lValues.BootId;
  aRecord.Identity.HasBootId := lValues.HasBootId;
  aRecord.Identity.HasProcessStartedAt := lValues.HasProcessStartedAt;
  aRecord.Identity.Hwnd := lValues.Hwnd;
  aRecord.Identity.ProcessId := lValues.ProcessId;
  aRecord.Identity.ProcessStartedAt := lValues.ProcessStartedAt;
  aRecord.Reason := aIniFile.ReadString(lSection, 'Reason', '');
  if aRecord.Reason = '' then
    aRecord.Reason := 'user_rename';
end;

function RecordAppliesToCurrentProcess(var aRecord: TCaptionOverrideRecord;
  const aCurrentBootId: Int64; const aHasCurrentBootId: Boolean;
  const aProcessResolver: TCaptionOverrideProcessResolver): Boolean;
var
  lResolved: TCaptionOverrideResolvedProcess;
begin
  Result := aHasCurrentBootId and aRecord.Identity.HasBootId and
    (aRecord.Identity.BootId = aCurrentBootId);
  if (not Result) or (not Assigned(aProcessResolver)) then
    Exit;
  lResolved := aProcessResolver(
    HWND(NativeUInt(aRecord.Identity.Hwnd)),
    aRecord.Identity.ProcessId);
  Result := lResolved.Current;
  if not Result then
    Exit;
  if aRecord.Identity.HasProcessStartedAt then
    Exit(lResolved.HasProcessStartedAt and
      (aRecord.Identity.ProcessStartedAt = lResolved.ProcessStartedAt));
  if lResolved.HasProcessStartedAt then
  begin
    aRecord.Identity.HasProcessStartedAt := True;
    aRecord.Identity.ProcessStartedAt := lResolved.ProcessStartedAt;
  end;
end;

function TryLoadVersion2(const aIniFile: TCustomIniFile; const aCurrentBootId: Int64;
  const aHasCurrentBootId: Boolean; const aProcessResolver: TCaptionOverrideProcessResolver;
  out aState: TCaptionOverrideState; out aErrorMessage: string): Boolean;
var
  lAcceptedCount: Integer;
  lIndex: Integer;
  lRecord: TCaptionOverrideRecord;
  lStoredCount: Integer;
begin
  aState := nil;
  aErrorMessage := '';
  lAcceptedCount := 0;
  lStoredCount := aIniFile.ReadInteger(cMetadataSection, 'Count', -1);
  if (lStoredCount < 0) or (lStoredCount > cMaximumOverrideCount) then
  begin
    aErrorMessage := 'invalid caption override count';
    Exit(False);
  end;

  SetLength(aState, lStoredCount);
  for lIndex := 0 to lStoredCount - 1 do
  begin
    if not TryReadVersion2Record(aIniFile, lIndex, lRecord) then
    begin
      aState := nil;
      aErrorMessage := 'invalid caption override record ' + IntToStr(lIndex);
      Exit(False);
    end;
    if RecordAppliesToCurrentProcess(
      lRecord,
      aCurrentBootId,
      aHasCurrentBootId,
      aProcessResolver) then
    begin
      aState[lAcceptedCount] := lRecord;
      Inc(lAcceptedCount);
    end;
  end;
  SetLength(aState, lAcceptedCount);
  Result := True;
end;

function TryCreateLegacyRecord(const aValues: TStrings; const aIndex: Integer;
  const aCurrentBootId: Int64; const aProcessResolver: TCaptionOverrideProcessResolver;
  out aRecord: TCaptionOverrideRecord): Boolean;
var
  lProcessId: Cardinal;
  lResolved: TCaptionOverrideResolvedProcess;
  lWnd: HWND;
begin
  aRecord := Default(TCaptionOverrideRecord);
  Result := (Trim(aValues.ValueFromIndex[aIndex]) <> '') and
    TryParseLegacyKey(aValues.Names[aIndex], lWnd, lProcessId);
  if not Result then
    Exit;
  lResolved := aProcessResolver(lWnd, lProcessId);
  Result := lResolved.Current and lResolved.HasProcessStartedAt;
  if not Result then
    Exit;

  aRecord.Caption := aValues.ValueFromIndex[aIndex];
  aRecord.Reason := 'user_rename';
  aRecord.Identity.HasBootId := True;
  aRecord.Identity.BootId := aCurrentBootId;
  aRecord.Identity.HasProcessStartedAt := True;
  aRecord.Identity.ProcessStartedAt := lResolved.ProcessStartedAt;
  aRecord.Identity.ProcessId := lProcessId;
  aRecord.Identity.Hwnd := UInt64(NativeUInt(lWnd));
end;

function TryLoadLegacy(const aFileName: string; const aIniFile: TCustomIniFile;
  const aCurrentBootId: Int64; const aHasCurrentBootId: Boolean;
  const aProcessResolver: TCaptionOverrideProcessResolver; out aState: TCaptionOverrideState;
  out aErrorMessage: string): Boolean;
var
  i: Integer;
  lAcceptedCount: Integer;
  lRecord: TCaptionOverrideRecord;
  lStoredBootId: Int64;
  lValues: TStringList;
begin
  aState := nil;
  aErrorMessage := '';
  if (not aHasCurrentBootId) or (not Assigned(aProcessResolver)) or
    (not TryStrToInt64(Trim(aIniFile.ReadString(cMetadataSection, 'BootId', '')), lStoredBootId)) or
    (not LegacyBootMatches(lStoredBootId, aCurrentBootId)) then
    Exit(TrySaveCaptionOverrideStateAtomic(aFileName, aState, aErrorMessage));

  lValues := TStringList.Create;
  try
    aIniFile.ReadSectionValues('Overrides', lValues);
    SetLength(aState, lValues.Count);
    lAcceptedCount := 0;
    for i := 0 to lValues.Count - 1 do
    begin
      if not TryCreateLegacyRecord(
        lValues,
        i,
        aCurrentBootId,
        aProcessResolver,
        lRecord) then
        Continue;
      aState[lAcceptedCount] := lRecord;
      Inc(lAcceptedCount);
    end;
    SetLength(aState, lAcceptedCount);
  finally
    lValues.Free;
  end;
  Result := TrySaveCaptionOverrideStateAtomic(aFileName, aState, aErrorMessage);
end;

function LoadCaptionOverrideStateFromIni(const aContext: TCaptionOverrideLoadContext;
  const aIniFile: TCustomIniFile;
  out aState: TCaptionOverrideState; out aStatus: TCaptionOverrideStateLoadStatus;
  out aErrorMessage: string): Boolean;
begin
  if aIniFile.ReadInteger(cMetadataSection, 'StateVersion', 0) = cStateVersion then
  begin
    Result := TryLoadVersion2(aIniFile, aContext.CurrentBootId, aContext.HasCurrentBootId,
      aContext.ProcessResolver, aState, aErrorMessage);
    if Result then
      aStatus := coslsLoaded
    else
      aStatus := coslsInvalid;
  end else
  begin
    Result := TryLoadLegacy(aContext.FileName, aIniFile, aContext.CurrentBootId,
      aContext.HasCurrentBootId, aContext.ProcessResolver, aState, aErrorMessage);
    if Result then
      aStatus := coslsUpgraded
    else
      aStatus := coslsInvalid;
  end;
end;

function TryLoadCaptionOverrideState(const aFileName: string; const aCurrentBootId: Int64;
  const aHasCurrentBootId: Boolean; const aProcessResolver: TCaptionOverrideProcessResolver;
  out aState: TCaptionOverrideState; out aStatus: TCaptionOverrideStateLoadStatus;
  out aErrorMessage: string): Boolean;
var
  lContext: TCaptionOverrideLoadContext;
  g: TGarbos;
  lIniFile: TMemIniFile;
begin
  g := Default(TGarbos);
  lContext := Default(TCaptionOverrideLoadContext);
  lContext.CurrentBootId := aCurrentBootId;
  lContext.FileName := aFileName;
  lContext.HasCurrentBootId := aHasCurrentBootId;
  lContext.ProcessResolver := aProcessResolver;
  aState := nil;
  aStatus := coslsMissing;
  aErrorMessage := '';
  if not TFile.Exists(aFileName) then
    Exit(True);

  try
    GC(lIniFile, TMemIniFile.Create(aFileName, TEncoding.UTF8, False), g);
    Result := LoadCaptionOverrideStateFromIni(
      lContext,
      lIniFile,
      aState,
      aStatus,
      aErrorMessage);
  except
    on EOutOfMemory do
      raise;
    on EAccessViolation do
      raise;
    on lException: Exception do
    begin
      aState := nil;
      aStatus := coslsInvalid;
      aErrorMessage := lException.ClassName + ': ' + lException.Message;
      Result := False;
    end;
  end;
end;

procedure WriteCaptionOverrideStateFile(const aFileName: string;
  const aState: TCaptionOverrideState);
var
  g: TGarbos;
  i: Integer;
  lIniFile: TMemIniFile;
  lRecord: TCaptionOverrideRecord;
  lSection: string;
begin
  g := Default(TGarbos);
  lIniFile := nil;
  GC(lIniFile, TMemIniFile.Create(aFileName, TEncoding.UTF8, False), g);
  lIniFile.WriteInteger(cMetadataSection, 'StateVersion', cStateVersion);
  lIniFile.WriteInteger(cMetadataSection, 'Count', Length(aState));
  for i := 0 to High(aState) do
  begin
    lRecord := aState[i];
    lSection := OverrideSectionName(i);
    lIniFile.WriteString(lSection, 'Caption', lRecord.Caption);
    lIniFile.WriteString(lSection, 'CreatedAt', IntToStr(lRecord.CreatedAt));
    lIniFile.WriteString(lSection, 'UpdatedAt', IntToStr(lRecord.UpdatedAt));
    lIniFile.WriteString(lSection, 'Pid', UIntToStr(lRecord.Identity.ProcessId));
    lIniFile.WriteString(lSection, 'Hwnd', UIntToStr(lRecord.Identity.Hwnd));
    lIniFile.WriteString(lSection, 'Reason', lRecord.Reason);
    if lRecord.Identity.HasBootId then
      lIniFile.WriteString(lSection, 'BootId', IntToStr(lRecord.Identity.BootId));
    if lRecord.Identity.HasProcessStartedAt then
      lIniFile.WriteString(
        lSection,
        'ProcessStartedAt',
        IntToStr(lRecord.Identity.ProcessStartedAt));
  end;
  lIniFile.UpdateFile;
end;

procedure CleanupTemporaryStateFile(const aFileName: string; var aResult: Boolean;
  var aErrorMessage: string);
begin
  if not TFile.Exists(aFileName) then
    Exit;
  try
    TFile.Delete(aFileName);
  except
    on lException: Exception do
      if aResult then
      begin
        aErrorMessage := lException.ClassName + ': ' + lException.Message;
        aResult := False;
      end;
  end;
end;

function TrySaveCaptionOverrideStateAtomic(const aFileName: string;
  const aState: TCaptionOverrideState; out aErrorMessage: string): Boolean;
var
  lDirectory: string;
  lTempFileName: string;
begin
  Result := False;
  aErrorMessage := '';
  lDirectory := ExtractFileDir(aFileName);
  lTempFileName := aFileName + '.tmp.' + UIntToStr(GetCurrentProcessId) + '.' +
    UIntToStr(GetCurrentThreadId) + '.' + UIntToStr(TThread.GetTickCount64);
  if (lDirectory <> '') and (not TDirectory.Exists(lDirectory)) then
  begin
    aErrorMessage := 'caption override state directory does not exist: ' + lDirectory;
    Exit(False);
  end;
  try
    try
      WriteCaptionOverrideStateFile(lTempFileName, aState);
      if not MoveFileExW(
        PWideChar(lTempFileName),
        PWideChar(aFileName),
        MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
        aErrorMessage := SysErrorMessage(GetLastError)
      else
        Result := True;
    except
      on EOutOfMemory do
        raise;
      on EAccessViolation do
        raise;
      on lException: Exception do
        aErrorMessage := lException.ClassName + ': ' + lException.Message;
    end;
  finally
    CleanupTemporaryStateFile(lTempFileName, Result, aErrorMessage);
  end;
end;

end.

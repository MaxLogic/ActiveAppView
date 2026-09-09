unit ActiveAppView.WindowSnapshots;

interface

uses
  System.Classes, System.SyncObjs, System.SysUtils,
  Winapi.Messages, Winapi.Windows,
  ActiveAppView.ConfigCache;

const
  cWindowSnapshotMessage = WM_APP + 181;
  cWindowRefreshMessage = WM_APP + 182;

type
  TWindowMetadataField = (wmIdentity, wmCommandLine, wmIcon);
  TWindowMetadataFields = set of TWindowMetadataField;

  TWindowSnapshot = record
    Wnd: HWND;
    PID: Cardinal;
    ProcessStartedAt: Int64;
    Caption: string;
    FileName: string;
    AppUserModelID: string;
    CommandLine: string;
    CommandLineParams: string;
    RelaunchCommand: string;
    IconBytes: TBytes;
    MetadataReady: Boolean;
    MetadataAttemptedAt: UInt64;
    MetadataError: string;
    CommandLineAttemptedAt: UInt64;
    CommandLineError: string;
    AvailableMetadata: TWindowMetadataFields;
    AttemptedMetadata: TWindowMetadataFields;
    RetryAfter: array[TWindowMetadataField] of UInt64;
  end;
  TWindowSnapshots = TArray<TWindowSnapshot>;

  TWindowSnapshotBatch = record
    CollectedAt: UInt64;
    Windows: TWindowSnapshots;
    HideMasks: TStringArray;
    PrefixRules: TPrefixRuleArray;
    TerminalPatterns: TStringArray;
    ErrorText: string;
  end;

  TWindowSnapshotService = class
  private
    fLock: TCriticalSection;
    fCancel: TEvent;
    fCollectWake: TEvent;
    fMetadataWake: TEvent;
    fCollector: TThread;
    fMetadataWorker: TThread;
    fBasePath: string;
    fNotifyWnd: HWND;
    fBatch: TWindowSnapshotBatch;
    fRefreshPending: Boolean;
    fNotifyPending: Boolean;
    fPrefixMetadata: TWindowMetadataFields;
    fGeneration: UInt64;
    fPriorityWnd: HWND;
    fPriorityPID: Cardinal;
    fCopyTarget: TWindowSnapshot;
    function SelectMetadata(out aWindow: TWindowSnapshot; out aFields: TWindowMetadataFields): Boolean;
    procedure ApplyMetadataResult(const aWindow: TWindowSnapshot; const aFields: TWindowMetadataFields);
    function PrefixMetadataFor(const aWindow: TWindowSnapshot): TWindowMetadataFields;
    procedure Collect;
    procedure Enrich;
    procedure NotifyLocked;
  public
    constructor Create(const aBasePath: string; const aNotifyWnd: HWND);
    destructor Destroy; override;
    procedure RequestRefresh;
    procedure RequestDetails(const aWnd: HWND; const aPID: Cardinal);
    procedure RequestCopyMetadata(const aWindow: TWindowSnapshot);
    procedure RemoveWindow(const aWnd: HWND);
    function TryTake(out aBatch: TWindowSnapshotBatch): Boolean;
  end;

function SameWindowSnapshotIdentity(const aLeft, aRight: TWindowSnapshot): Boolean;
function RunWindowMetadataHelper: Integer;
function RunWindowSnapshotSelfTests(const aArg: string): Integer;

implementation

uses
  System.Diagnostics, System.Generics.Collections, System.IOUtils, System.JSON,
  System.NetEncoding,
  Winapi.ActiveX,
  Vcl.Forms, Vcl.Graphics,
  maxLogic.StrUtils, maxLogic.Windows.Desktop, MaxLogic.Windows.Identity,
  ActiveAppView.MachineOverview.BoundedProcess, ActiveAppViewCore;

const
  cAllMetadata: TWindowMetadataFields = [wmIdentity, wmCommandLine, wmIcon];

function AvailableMetadata(const aWindow: TWindowSnapshot): TWindowMetadataFields;
begin
  if aWindow.MetadataReady then
    Result := cAllMetadata
  else
    Result := aWindow.AvailableMetadata;
end;

function SameSnapshotProcess(const aLeft, aRight: TWindowSnapshot): Boolean;
begin
  Result := (aLeft.PID <> 0) and (aLeft.PID = aRight.PID) and
    (aLeft.ProcessStartedAt > 0) and (aLeft.ProcessStartedAt = aRight.ProcessStartedAt);
end;

procedure CopyProcessCommandLine(const aSource: TWindowSnapshot; var aTarget: TWindowSnapshot);
begin
  aTarget.CommandLine := aSource.CommandLine;
  aTarget.CommandLineParams := aSource.CommandLineParams;
  aTarget.CommandLineAttemptedAt := aSource.CommandLineAttemptedAt;
  aTarget.CommandLineError := aSource.CommandLineError;
  aTarget.AvailableMetadata := AvailableMetadata(aTarget) + [wmCommandLine];
  aTarget.MetadataReady := aTarget.AvailableMetadata = cAllMetadata;
end;

procedure MergeMetadataFields(const aSource: TWindowSnapshot; const aFields: TWindowMetadataFields;
  var aTarget: TWindowSnapshot);
var
  lField: TWindowMetadataField;
begin
  aTarget.AvailableMetadata := AvailableMetadata(aTarget);
  aTarget.MetadataAttemptedAt := aSource.MetadataAttemptedAt;
  aTarget.AttemptedMetadata := aFields;
  aTarget.MetadataError := aSource.MetadataError;
  for lField in aFields do
    if aSource.MetadataError = '' then
      aTarget.RetryAfter[lField] := 0
    else
      aTarget.RetryAfter[lField] := aSource.MetadataAttemptedAt + 30000;
  if aSource.MetadataError = '' then
  begin
    if wmIdentity in aFields then
    begin
      aTarget.AppUserModelID := aSource.AppUserModelID;
      aTarget.RelaunchCommand := aSource.RelaunchCommand;
    end;
    if wmCommandLine in aFields then
      CopyProcessCommandLine(aSource, aTarget);
    if wmIcon in aFields then
      aTarget.IconBytes := aSource.IconBytes;
    aTarget.AvailableMetadata := aTarget.AvailableMetadata + aFields;
  end;
  if wmCommandLine in aFields then
  begin
    aTarget.CommandLineAttemptedAt := aSource.MetadataAttemptedAt;
    aTarget.CommandLineError := aSource.MetadataError;
  end;
  aTarget.MetadataReady := aTarget.AvailableMetadata = cAllMetadata;
end;

type
  TSnapshotWorker = class(TThread)
  private
    fService: TWindowSnapshotService;
    fMetadata: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(aService: TWindowSnapshotService; const aMetadata: Boolean);
  end;

  TWindowCollector = class
  public
    fWindows: TList<TWindowSnapshot>;
    fErrorText: string;
  end;

function SameWindowSnapshotIdentity(const aLeft, aRight: TWindowSnapshot): Boolean;
begin
  Result := (aLeft.Wnd = aRight.Wnd) and (aLeft.PID = aRight.PID) and
    (aLeft.ProcessStartedAt = aRight.ProcessStartedAt);
end;

procedure CopyMetadata(const aSource: TWindowSnapshot; var aTarget: TWindowSnapshot);
begin
  aTarget.AppUserModelID := aSource.AppUserModelID;
  aTarget.CommandLine := aSource.CommandLine;
  aTarget.CommandLineParams := aSource.CommandLineParams;
  aTarget.CommandLineAttemptedAt := aSource.CommandLineAttemptedAt;
  aTarget.CommandLineError := aSource.CommandLineError;
  aTarget.RelaunchCommand := aSource.RelaunchCommand;
  aTarget.IconBytes := aSource.IconBytes;
  aTarget.MetadataReady := aSource.MetadataReady;
  aTarget.MetadataAttemptedAt := aSource.MetadataAttemptedAt;
  aTarget.MetadataError := aSource.MetadataError;
  aTarget.AvailableMetadata := AvailableMetadata(aSource);
  aTarget.AttemptedMetadata := aSource.AttemptedMetadata;
  aTarget.RetryAfter := aSource.RetryAfter;
end;

function CollectWindow(aWnd: HWND; aParam: LPARAM): BOOL; stdcall;
var
  lCollector: TWindowCollector;
  lPID: Cardinal;
  lWindow: TWindowSnapshot;
begin
  Result := True;
  lCollector := TWindowCollector(aParam);
  try
    lWindow := Default(TWindowSnapshot);
    lWindow.Wnd := aWnd;
    if GetWindowThreadProcessId(aWnd, lPID) = 0 then
      Exit;
    lWindow.PID := lPID;
    // Do not send same-process caption messages while our VCL thread may be joining us.
    if (lWindow.PID = GetCurrentProcessId) or (not IsWindowVisible(aWnd)) or
      (not maxLogic.Windows.Desktop.IsWndValid(aWnd)) then
      Exit;
    lWindow.Caption := maxLogic.Windows.Desktop.GetWinCaption(aWnd);
    if lWindow.Caption = '' then
      Exit;
    lWindow.FileName := maxLogic.Windows.Desktop.GetFileName(aWnd);
    if not TryGetProcessStartedAtUtcMilliseconds(lWindow.PID, lWindow.ProcessStartedAt) then
      lWindow.ProcessStartedAt := 0;
    lCollector.fWindows.Add(lWindow);
  except
    on lException: Exception do
    begin
      lCollector.fErrorText := lException.ClassName + ': ' + lException.Message;
      Result := False;
    end;
  end;
end;

constructor TSnapshotWorker.Create(aService: TWindowSnapshotService; const aMetadata: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  fService := aService;
  fMetadata := aMetadata;
end;

procedure TSnapshotWorker.Execute;
begin
  if fMetadata then
    fService.Enrich
  else
    fService.Collect;
end;

constructor TWindowSnapshotService.Create(const aBasePath: string; const aNotifyWnd: HWND);
begin
  inherited Create;
  fBasePath := aBasePath;
  fNotifyWnd := aNotifyWnd;
  fLock := TCriticalSection.Create;
  fCancel := TEvent.Create(nil, True, False, '');
  fCollectWake := TEvent.Create(nil, False, False, '');
  fMetadataWake := TEvent.Create(nil, False, False, '');
  fCollector := TSnapshotWorker.Create(Self, False);
  fMetadataWorker := TSnapshotWorker.Create(Self, True);
  fCollector.Start;
  fMetadataWorker.Start;
end;

destructor TWindowSnapshotService.Destroy;
begin
  if Assigned(fCancel) then
    fCancel.SetEvent;
  if Assigned(fCollectWake) then
    fCollectWake.SetEvent;
  if Assigned(fMetadataWake) then
    fMetadataWake.SetEvent;
  FreeAndNil(fCollector);
  FreeAndNil(fMetadataWorker);
  fMetadataWake.Free;
  fCollectWake.Free;
  fCancel.Free;
  fLock.Free;
  inherited;
end;

procedure TWindowSnapshotService.NotifyLocked;
begin
  if fNotifyPending then
    Exit;
  fNotifyPending := True;
  if fNotifyWnd <> 0 then
    if not PostMessage(fNotifyWnd, cWindowSnapshotMessage, 0, 0) then
      fNotifyPending := False;
end;

procedure TWindowSnapshotService.RequestRefresh;
begin
  fLock.Enter;
  try
    if not fRefreshPending then
    begin
      Inc(fGeneration);
      fRefreshPending := True;
    end;
  finally
    fLock.Leave;
  end;
  fCollectWake.SetEvent;
end;

procedure TWindowSnapshotService.RequestDetails(const aWnd: HWND; const aPID: Cardinal);
begin
  fLock.Enter;
  try
    fPriorityWnd := aWnd;
    fPriorityPID := aPID;
  finally
    fLock.Leave;
  end;
  fMetadataWake.SetEvent;
end;

procedure TWindowSnapshotService.RequestCopyMetadata(const aWindow: TWindowSnapshot);
begin
  fLock.Enter;
  try
    fCopyTarget := aWindow;
  finally
    fLock.Leave;
  end;
  fMetadataWake.SetEvent;
end;

procedure TWindowSnapshotService.RemoveWindow(const aWnd: HWND);
var
  lWindows: TWindowSnapshots;
  lCount: Integer;
  lWindow: TWindowSnapshot;
begin
  fLock.Enter;
  try
    SetLength(lWindows, Length(fBatch.Windows));
    lCount := 0;
    for lWindow in fBatch.Windows do
      if lWindow.Wnd <> aWnd then
      begin
        lWindows[lCount] := lWindow;
        Inc(lCount);
      end;
    SetLength(lWindows, lCount);
    fBatch.Windows := lWindows;
    if fCopyTarget.Wnd = aWnd then
      fCopyTarget := Default(TWindowSnapshot);
    // Discard any inventory that began before our removal.
    Inc(fGeneration);
    NotifyLocked;
  finally
    fLock.Leave;
  end;
end;

function TWindowSnapshotService.PrefixMetadataFor(const aWindow: TWindowSnapshot): TWindowMetadataFields;
var
  lPattern: string;
begin
  Result := [];
  if (fPrefixMetadata = []) or (aWindow.Caption = '') or
    SameText(ExtractFileName(aWindow.FileName), 'explorer.exe') then
    Exit;
  for lPattern in fBatch.TerminalPatterns do
    if StringMatches(aWindow.FileName, lPattern, False) then
      Exit;
  for lPattern in fBatch.HideMasks do
    if StringMatches(aWindow.Caption, lPattern, False) or
      StringMatches(aWindow.FileName, lPattern, False) then
      Exit;
  if not (wmIdentity in AvailableMetadata(aWindow)) then
    Result := [wmIdentity]
  else if (aWindow.AppUserModelID = '') and (wmCommandLine in fPrefixMetadata) then
    Result := [wmCommandLine];
end;

function TWindowSnapshotService.SelectMetadata(out aWindow: TWindowSnapshot;
  out aFields: TWindowMetadataFields): Boolean;
var
  lIsCopy: Boolean;
  lIsPriority: Boolean;
  lNeeded: TWindowMetadataFields;
  lField: TWindowMetadataField;
  lNow: UInt64;
  lRank: Integer;
  lBestRank: Integer;
  i: Integer;
begin
  // Called with fLock held. Copy ownership survives replaceable selection requests.
  Result := False;
  aFields := [];
  aWindow := Default(TWindowSnapshot);
  lBestRank := -1;
  lNow := GetTickCount64;
  for i := 0 to High(fBatch.Windows) do
  begin
    lIsCopy := (fCopyTarget.Wnd <> 0) and SameWindowSnapshotIdentity(fBatch.Windows[i], fCopyTarget);
    lIsPriority := (fBatch.Windows[i].Wnd = fPriorityWnd) and (fBatch.Windows[i].PID = fPriorityPID);
    if lIsCopy then
    begin
      lNeeded := [wmCommandLine];
      lRank := 2;
    end else if lIsPriority then
    begin
      lNeeded := cAllMetadata;
      lRank := 1;
    end else begin
      lNeeded := PrefixMetadataFor(fBatch.Windows[i]);
      lRank := 0;
    end;
    lNeeded := lNeeded - AvailableMetadata(fBatch.Windows[i]);
    for lField in lNeeded do
      if (not lIsCopy) and (lNow < fBatch.Windows[i].RetryAfter[lField]) then
        Exclude(lNeeded, lField);
    // Publish fast fields before starting the independent WMI query.
    if lNeeded * [wmIdentity, wmIcon] <> [] then
      Exclude(lNeeded, wmCommandLine);
    if (lNeeded = []) or (lRank <= lBestRank) then
      Continue;
    aWindow := fBatch.Windows[i];
    aFields := lNeeded;
    lBestRank := lRank;
    Result := True;
    if lIsCopy then
      Break;
  end;
end;

procedure TWindowSnapshotService.ApplyMetadataResult(const aWindow: TWindowSnapshot;
  const aFields: TWindowMetadataFields);
var
  lChanged: Boolean;
  i: Integer;
begin
  // Process data is shared only for a known process lifetime; window fields stay local.
  lChanged := False;
  for i := 0 to High(fBatch.Windows) do
    if SameWindowSnapshotIdentity(fBatch.Windows[i], aWindow) then
    begin
      MergeMetadataFields(aWindow, aFields, fBatch.Windows[i]);
      lChanged := True;
    end else if (aWindow.MetadataError = '') and (wmCommandLine in aFields) and
      SameSnapshotProcess(fBatch.Windows[i], aWindow) then
    begin
      MergeMetadataFields(aWindow, [wmCommandLine], fBatch.Windows[i]);
      lChanged := True;
    end;
  if (wmCommandLine in aFields) and
    (SameWindowSnapshotIdentity(fCopyTarget, aWindow) or
     ((aWindow.MetadataError = '') and SameSnapshotProcess(fCopyTarget, aWindow))) then
    fCopyTarget := Default(TWindowSnapshot);
  if lChanged then
    NotifyLocked;
end;

function TWindowSnapshotService.TryTake(out aBatch: TWindowSnapshotBatch): Boolean;
var
  i: Integer;
begin
  aBatch := Default(TWindowSnapshotBatch);
  fLock.Enter;
  try
    Result := fNotifyPending;
    if not Result then
      Exit;
    aBatch := fBatch;
    aBatch.Windows := Copy(fBatch.Windows);
    for i := 0 to High(aBatch.Windows) do
      aBatch.Windows[i].IconBytes := Copy(aBatch.Windows[i].IconBytes);
    aBatch.HideMasks := Copy(fBatch.HideMasks);
    aBatch.PrefixRules := Copy(fBatch.PrefixRules);
    aBatch.TerminalPatterns := Copy(fBatch.TerminalPatterns);
    fNotifyPending := False;
  finally
    fLock.Leave;
  end;
end;

procedure TWindowSnapshotService.Collect;
var
  lBatch: TWindowSnapshotBatch;
  lCache: TConfigCache;
  lCollector: TWindowCollector;
  lGeneration: UInt64;
  lOldWindow: TWindowSnapshot;
  lRule: TPrefixRule;
  i: Integer;
begin
  lCache := TConfigCache.Create(fBasePath);
  try
    while fCancel.WaitFor(0) <> wrSignaled do
    begin
      fCollectWake.WaitFor(INFINITE);
      if fCancel.WaitFor(0) = wrSignaled then
        Break;
      fLock.Enter;
      try
        if not fRefreshPending then
          Continue;
        fRefreshPending := False;
        lGeneration := fGeneration;
      finally
        fLock.Leave;
      end;
      lBatch := Default(TWindowSnapshotBatch);
      try
        lBatch.HideMasks := lCache.GetHideMasks('HideMask.txt');
        lBatch.PrefixRules := lCache.GetPrefixRules('PrefixMask.txt');
        lBatch.TerminalPatterns := lCache.GetTerminalPatterns('TerminalPatterns.txt');
        lBatch.CollectedAt := GetTickCount64;
        lCollector := TWindowCollector.Create;
        try
          lCollector.fWindows := TList<TWindowSnapshot>.Create;
          EnumWindows(@CollectWindow, LPARAM(lCollector));
          if lCollector.fErrorText <> '' then
            raise Exception.Create(lCollector.fErrorText);
          lBatch.Windows := lCollector.fWindows.ToArray;
        finally
          lCollector.fWindows.Free;
          lCollector.Free;
        end;
      except
        on lException: Exception do
          lBatch.ErrorText := lException.ClassName + ': ' + lException.Message;
      end;
      fLock.Enter;
      try
        if lGeneration <> fGeneration then
          Continue;
        if lBatch.ErrorText = '' then
        begin
          for i := 0 to High(lBatch.Windows) do
            for lOldWindow in fBatch.Windows do
              if SameWindowSnapshotIdentity(lBatch.Windows[i], lOldWindow) then
              begin
                CopyMetadata(lOldWindow, lBatch.Windows[i]);
                Break;
              end else if SameSnapshotProcess(lBatch.Windows[i], lOldWindow) and
                (wmCommandLine in AvailableMetadata(lOldWindow)) then
                CopyProcessCommandLine(lOldWindow, lBatch.Windows[i]);
          fBatch := lBatch;
          fPrefixMetadata := [];
          for lRule in fBatch.PrefixRules do
          begin
            if (lRule.AppUserModelIDMask <> '') or (lRule.CmdParamsMask <> '') then
              Include(fPrefixMetadata, wmIdentity);
            if lRule.CmdParamsMask <> '' then
              Include(fPrefixMetadata, wmCommandLine);
          end;
        end else
          fBatch.ErrorText := lBatch.ErrorText;
        NotifyLocked;
      finally
        fLock.Leave;
      end;
      fMetadataWake.SetEvent;
    end;
  finally
    lCache.Free;
  end;
end;

procedure TWindowSnapshotService.Enrich;
var
  lFields: TWindowMetadataFields;
  lData: TJSONObject;
  lFound: Boolean;
  lResult: TMachineOverviewProcessResult;
  lWindow: TWindowSnapshot;
  lNow: UInt64;
begin
  while fCancel.WaitFor(0) <> wrSignaled do
  begin
    lFound := False;
    lWindow := Default(TWindowSnapshot);
    lNow := GetTickCount64;
    fLock.Enter;
    try
      lFound := SelectMetadata(lWindow, lFields);
    finally
      fLock.Leave;
    end;
    if not lFound then
    begin
      fMetadataWake.WaitFor(INFINITE);
      Continue;
    end;
    if lNow <= lWindow.MetadataAttemptedAt then
      lNow := lWindow.MetadataAttemptedAt + 1;
    lWindow.MetadataAttemptedAt := lNow;
    try
      lResult := RunMachineOverviewBoundedProcessCancelable(ParamStr(0),
        Format('--window-metadata %s %d %d %d', [UIntToStr(NativeUInt(lWindow.Wnd)),
          lWindow.PID, lWindow.ProcessStartedAt, Byte(lFields)]), 15000, 262144, fCancel.Handle);
      if lResult.Cancelled then
        Break;
      if lResult.Started and (lResult.ExitCode = 0) then
      begin
        lData := TJSONObject.ParseJSONValue(lResult.OutputText) as TJSONObject;
        try
          if not Assigned(lData) then
            raise Exception.Create('Invalid window metadata response');
          lWindow.CommandLine := lData.GetValue<string>('commandLine');
          lWindow.CommandLineParams := lData.GetValue<string>('commandLineParams');
          lWindow.AppUserModelID := lData.GetValue<string>('appUserModelId');
          lWindow.RelaunchCommand := lData.GetValue<string>('relaunchCommand');
          lWindow.IconBytes := TNetEncoding.Base64.DecodeStringToBytes(lData.GetValue<string>('icon'));
          lWindow.MetadataReady := True;
          lWindow.MetadataError := '';
        finally
          lData.Free;
        end;
      end else
        lWindow.MetadataError := Format('Metadata exit %d: %s',
          [lResult.ExitCode, lResult.ErrorText]);
    except
      on lException: Exception do
        lWindow.MetadataError := lException.ClassName + ': ' + lException.Message;
    end;
    fLock.Enter;
    try
      ApplyMetadataResult(lWindow, lFields);
    finally
      fLock.Leave;
    end;
  end;
end;

function RunWindowMetadataHelper: Integer;
var
  lApp: TAppInfo;
  lFields: TWindowMetadataFields;
  lMask: Integer;
  lMetadata: TWindowSnapshot;
  lComResult: HRESULT;
  lBytes: TBytes;
  lData: TJSONObject;
  lPID: Cardinal;
  lExpectedPID: Cardinal;
  lExpectedStart: Int64;
  lStart: Int64;
  lStream: TMemoryStream;
  lWnd: HWND;
  lWritten: Cardinal;
begin
  Result := -1;
  if SameText(ParamStr(1), '--window-metadata-test-wait') then
  begin
    Sleep(INFINITE);
    Exit(0);
  end;
  if not SameText(ParamStr(1), '--window-metadata') then
    Exit;
  Result := 1;
  lComResult := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      lMask := StrToIntDef(ParamStr(5), 7);
      if (lMask < 1) or (lMask > 7) then
        Exit;
      lFields := TWindowMetadataFields(Byte(lMask));
      lMetadata := Default(TWindowSnapshot);
      lWnd := HWND(StrToUInt64(ParamStr(2)));
      lExpectedPID := StrToUInt(ParamStr(3));
      lExpectedStart := StrToInt64(ParamStr(4));
      lPID := 0;
      GetWindowThreadProcessId(lWnd, lPID);
      lStart := 0;
      if not TryGetProcessStartedAtUtcMilliseconds(lPID, lStart) then
        lStart := 0;
      if (lPID = 0) or (lPID <> lExpectedPID) or (lStart <> lExpectedStart) then
        Exit;
      lApp := TAppInfo.Create(lWnd);
      try
        lData := TJSONObject.Create;
        try
          if wmIdentity in lFields then
          begin
            lMetadata.AppUserModelID := lApp.AppUserModelID;
            lMetadata.RelaunchCommand := lApp.RelaunchCommand;
          end;
          if wmCommandLine in lFields then
          begin
            lMetadata.CommandLine := lApp.CommandLine;
            lMetadata.CommandLineParams := lApp.CommandLineParams;
          end;
          lData.AddPair('commandLine', lMetadata.CommandLine);
          lData.AddPair('commandLineParams', lMetadata.CommandLineParams);
          lData.AddPair('appUserModelId', lMetadata.AppUserModelID);
          lData.AddPair('relaunchCommand', lMetadata.RelaunchCommand);
          lStream := TMemoryStream.Create;
          try
            if wmIcon in lFields then
              if not lApp.Icon.Empty then
                lApp.Icon.SaveToStream(lStream);
            SetLength(lBytes, lStream.Size);
            if Length(lBytes) > 0 then
              Move(lStream.Memory^, lBytes[0], Length(lBytes));
            lData.AddPair('icon', TNetEncoding.Base64.EncodeBytesToString(lBytes));
          finally
            lStream.Free;
          end;
          GetWindowThreadProcessId(lWnd, lPID);
          lStart := 0;
          if not TryGetProcessStartedAtUtcMilliseconds(lPID, lStart) then
            lStart := 0;
          if (not IsWindow(lWnd)) or (lPID <> lExpectedPID) or (lStart <> lExpectedStart) then
            Exit;
          lBytes := TEncoding.UTF8.GetBytes(lData.ToJSON);
          if WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), lBytes[0], Length(lBytes), lWritten, nil) and
            (lWritten = Cardinal(Length(lBytes))) then
            Result := 0;
        finally
          lData.Free;
        end;
      finally
        lApp.Free;
      end;
    except
      on lException: Exception do
      begin
        OutputDebugString(PChar('Window metadata: ' + lException.Message));
        Result := 1;
      end;
    end;
  finally
    if Succeeded(lComResult) then
      CoUninitialize;
  end;
end;

function RunMetadataPolicySelfTest: Integer;
var
  lService: TWindowSnapshotService;
  lWindow: TWindowSnapshot;
  lFields: TWindowMetadataFields;
  lFailures: Integer;
  procedure Check(const aCondition: Boolean; const aMessage: string);
  begin
    if aCondition then
      Exit;
    Inc(lFailures);
    Writeln('SELFTEST FAILED: ' + aMessage);
  end;
begin
  lFailures := 0;
  lService := TWindowSnapshotService.Create(TPath.GetTempPath, 0);
  try
    lService.fLock.Enter;
    try
      SetLength(lService.fBatch.Windows, 3);
      lService.fBatch.Windows[0].Wnd := 100;
      lService.fBatch.Windows[0].PID := 10;
      lService.fBatch.Windows[0].ProcessStartedAt := 1000;
      lService.fBatch.Windows[0].FileName := 'app.exe';
      lService.fBatch.Windows[0].Caption := 'first';
      lService.fBatch.Windows[1] := lService.fBatch.Windows[0];
      lService.fBatch.Windows[1].Wnd := 200;
      lService.fBatch.Windows[2] := lService.fBatch.Windows[0];
      lService.fBatch.Windows[2].Wnd := 300;
      lService.fBatch.Windows[2].ProcessStartedAt := 2000;
      lService.fPrefixMetadata := [wmIdentity, wmCommandLine];
      Check(lService.SelectMetadata(lWindow, lFields) and (lFields = [wmIdentity]),
        'prefix prefetch queried command lines or icons before window identity');
      lService.RequestDetails(100, 10);
      Check(lService.SelectMetadata(lWindow, lFields) and
        (lFields = [wmIdentity, wmIcon]), 'selected window fast fields wait for a command-line query');
      lService.RequestCopyMetadata(lService.fBatch.Windows[0]);
      Check(lService.SelectMetadata(lWindow, lFields) and (lFields = [wmCommandLine]),
        'command-line copy requested unrelated metadata');
      lWindow := lService.fBatch.Windows[0];
      lWindow.CommandLine := 'app.exe --one';
      lWindow.CommandLineParams := '--one';
      lWindow.MetadataAttemptedAt := GetTickCount64;
      lService.ApplyMetadataResult(lWindow, [wmCommandLine]);
      Check((wmCommandLine in lService.fBatch.Windows[1].AvailableMetadata) and
        (lService.fBatch.Windows[1].CommandLine = 'app.exe --one'),
        'same-process windows did not reuse the command line');
      Check(not (wmCommandLine in lService.fBatch.Windows[2].AvailableMetadata),
        'command-line cache crossed a process restart');
      Check(not (wmIcon in lService.fBatch.Windows[1].AvailableMetadata),
        'process cache shared window-specific fields');
      lService.fBatch.Windows[1].AvailableMetadata := [];
      lService.RequestCopyMetadata(lService.fBatch.Windows[1]);
      lWindow.MetadataError := 'source window disappeared';
      lService.ApplyMetadataResult(lWindow, [wmCommandLine]);
      Check(lService.fBatch.Windows[1].MetadataError = '',
        'window-specific failure contaminated another window of the same process');
      Check(lService.fCopyTarget.Wnd = 200,
        'failed helper for another window cancelled the pending copy');
      lService.RequestCopyMetadata(lService.fBatch.Windows[1]);
      lWindow.MetadataError := '';
      lService.ApplyMetadataResult(lWindow, [wmIdentity]);
      Check(lService.fCopyTarget.Wnd = 200, 'fast fields cancelled pending command-line work');
      Check((lService.fBatch.Windows[0].CommandLineError = 'source window disappeared') and
        (lService.fBatch.Windows[0].CommandLineAttemptedAt > 0),
        'coalesced fast fields erased command-line failure completion');
      lService.fBatch.Windows[1].ProcessStartedAt := 0;
      lWindow.ProcessStartedAt := 0;
      lService.ApplyMetadataResult(lWindow, [wmCommandLine]);
      Check(not (wmCommandLine in lService.fBatch.Windows[1].AvailableMetadata),
        'unknown process lifetime was treated as a cache identity');
      lService.fCopyTarget := Default(TWindowSnapshot);
      lService.fPriorityWnd := 0;
      SetLength(lService.fBatch.Windows, 1);
      lService.fBatch.Windows[0].AvailableMetadata := [wmIdentity];
      lService.fBatch.Windows[0].MetadataAttemptedAt := 0;
      lService.fBatch.Windows[0].RetryAfter[wmCommandLine] := 0;
      lService.fBatch.Windows[0].AppUserModelID := 'pwa.identity';
      Check(not lService.SelectMetadata(lWindow, lFields),
        'identified window still queried unused command-line prefix fallback');
      lService.fBatch.Windows[0].AppUserModelID := '';
      Check(lService.SelectMetadata(lWindow, lFields) and (lFields = [wmCommandLine]),
        'missing window identity did not request required command-line fallback');
      lService.fBatch.Windows[0].FileName := 'explorer.exe';
      Check(not lService.SelectMetadata(lWindow, lFields), 'Explorer received unused prefix metadata');
      lService.fBatch.Windows := nil;
    finally
      lService.fLock.Leave;
    end;
  finally
    lService.Free;
  end;
  Result := Ord(lFailures <> 0);
  if Result = 0 then
    Writeln('METADATA POLICY PASS selective-fields process-cache identity-isolation prefix-fallback');
end;

function RunWindowSnapshotSelfTests(const aArg: string): Integer;
var
  lBatch: TWindowSnapshotBatch;
  lCancel: TEvent;
  lData: TJSONObject;
  lFinished: TEvent;
  lFields: TWindowMetadataFields;
  lArguments: string;
  lProcessResult: TMachineOverviewProcessResult;
  lService: TWindowSnapshotService;
  lStartedAt: Int64;
  lThread: TThread;
  lWatch: TStopwatch;
  lWnd: HWND;
  lWindow: TWindowSnapshot;
  i: Integer;
begin
  if SameText(aArg, '--self-test-window-metadata-policy') then
    Exit(RunMetadataPolicySelfTest);
  Result := -1;
  if not SameText(aArg, '--self-test-window-snapshots') and
    not SameText(aArg, '--self-test-window-snapshot-ownership') and
    not SameText(aArg, '--self-test-window-metadata') and
    not SameText(aArg, '--self-test-window-metadata-fields') and
    not SameText(aArg, '--self-test-window-metadata-cancel') then
    Exit;
  Result := 0;
  try
    if SameText(aArg, '--self-test-window-snapshot-ownership') then
    begin
      lService := TWindowSnapshotService.Create(TPath.GetTempPath, 0);
      try
        lService.fLock.Enter;
        try
          SetLength(lService.fBatch.Windows, 2);
          lService.fBatch.Windows[0].Wnd := 100;
          lService.fBatch.Windows[0].PID := 10;
          lService.fBatch.Windows[0].MetadataError := 'Earlier timeout';
          lService.fBatch.Windows[0].MetadataAttemptedAt := GetTickCount64;
          lService.fBatch.Windows[1].Wnd := 200;
          lService.fBatch.Windows[1].PID := 20;
          lService.RequestCopyMetadata(lService.fBatch.Windows[0]);
          lService.RequestDetails(200, 20);
          if (not lService.SelectMetadata(lWindow, lFields)) or (lWindow.Wnd <> 100) then
          begin
            Writeln('SELFTEST FAILED: Selection displaced an explicit copy retry');
            Result := 1;
          end;
          lBatch := lService.fBatch;
          lService.RemoveWindow(100);
          if (Length(lService.fBatch.Windows) <> 1) or (lService.fBatch.Windows[0].Wnd <> 200) then
          begin
            Writeln('SELFTEST FAILED: Removed window remained in the published snapshot');
            Result := 1;
          end;
          if (Length(lBatch.Windows) <> 2) or (lBatch.Windows[0].Wnd <> 100) then
            raise Exception.Create('Removing a window mutated an earlier snapshot');
          if lService.fCopyTarget.Wnd <> 0 then
            raise Exception.Create('Removing a window retained its pending clipboard request');
          lService.fBatch.Windows := nil;
        finally
          lService.fLock.Leave;
        end;
        if Result = 0 then
          Writeln('SNAPSHOT OWNERSHIP PASS copy-priority retry removal immutable-publication');
      finally
        lService.Free;
      end;
      Exit;
    end;
    if not SameText(aArg, '--self-test-window-snapshots') then
    begin
      lWnd := CreateWindowEx(WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE, 'STATIC',
        'ActiveAppView metadata fixture', WS_POPUP, 0, 0, 0, 0, 0, 0, HInstance, nil);
      if lWnd = 0 then
        RaiseLastOSError;
      lCancel := TEvent.Create(nil, True, False, '');
      lFinished := TEvent.Create(nil, True, False, '');
      lThread := nil;
      try
        lStartedAt := 0;
        if not TryGetProcessStartedAtUtcMilliseconds(GetCurrentProcessId, lStartedAt) then
          raise Exception.Create('Could not obtain the fixture process start time');
        lArguments := Format('--window-metadata %s %d %d',
          [UIntToStr(NativeUInt(lWnd)), GetCurrentProcessId, lStartedAt]);
        if SameText(aArg, '--self-test-window-metadata-fields') then
          lArguments := lArguments + ' 1';
        if SameText(aArg, '--self-test-window-metadata-cancel') then
          lArguments := '--window-metadata-test-wait';
        lThread := TThread.CreateAnonymousThread(
          procedure
          begin
            try
              lProcessResult := RunMachineOverviewBoundedProcessCancelable(ParamStr(0),
                lArguments, 15000, 262144, lCancel.Handle);
            finally
              lFinished.SetEvent;
            end;
          end);
        lThread.FreeOnTerminate := False;
        lThread.Start;
        lWatch := TStopwatch.StartNew;
        while lFinished.WaitFor(0) <> wrSignaled do
        begin
          Application.ProcessMessages;
          if SameText(aArg, '--self-test-window-metadata-cancel') or
            (lWatch.ElapsedMilliseconds > 16000) then
            lCancel.SetEvent;
          Sleep(1);
        end;
        lThread.WaitFor;
        if Assigned(lThread.FatalException) then
          raise Exception.Create('Metadata test worker raised an exception');
        if SameText(aArg, '--self-test-window-metadata-cancel') then
        begin
          if (not lProcessResult.Cancelled) or (lWatch.ElapsedMilliseconds > 2000) then
            raise Exception.Create('Metadata cancellation did not join within two seconds');
          Writeln(Format('METADATA CANCEL PASS join-ms=%d child-pid=%d',
            [lWatch.ElapsedMilliseconds, lProcessResult.ProcessId]));
        end else begin
          if lProcessResult.ExitCode <> 0 then
            raise Exception.Create('Metadata helper failed: ' + lProcessResult.ErrorText);
          lData := TJSONObject.ParseJSONValue(lProcessResult.OutputText) as TJSONObject;
          try
            if not Assigned(lData) then
              raise Exception.Create('Metadata helper returned invalid JSON');
            if SameText(aArg, '--self-test-window-metadata-fields') then
            begin
              if (lData.GetValue<string>('commandLine') <> '') or
                (lData.GetValue<string>('icon') <> '') then
                raise Exception.Create('Identity-only helper retrieved command-line or icon data');
            end else if lData.GetValue<string>('commandLine') <> string(Winapi.Windows.GetCommandLine) then
              raise Exception.Create('Metadata helper did not return the real process command line');
            Writeln(Format('METADATA PASS duration-ms=%d child-pid=%d',
              [lWatch.ElapsedMilliseconds, lProcessResult.ProcessId]));
          finally
            lData.Free;
          end;
        end;
      finally
        lCancel.SetEvent;
        lThread.Free;
        lFinished.Free;
        lCancel.Free;
        DestroyWindow(lWnd);
      end;
      Exit;
    end;
    lService := TWindowSnapshotService.Create(TPath.GetTempPath, 0);
    try
      lWatch := TStopwatch.StartNew;
      for i := 1 to 100 do
      begin
        lService.RequestRefresh;
        if i = 100 then
          Writeln(Format('SNAPSHOT REQUEST count=%d duration-ms=%.3f', [i, lWatch.Elapsed.TotalMilliseconds]));
      end;
      if lWatch.ElapsedMilliseconds > 100 then
        raise Exception.Create('Refresh request batch blocked the caller');
      lWatch := TStopwatch.StartNew;
      while not lService.TryTake(lBatch) do
      begin
        if lWatch.ElapsedMilliseconds > 10000 then
          raise Exception.Create('No background snapshot published');
        Sleep(10);
      end;
      if lBatch.ErrorText <> '' then
        raise Exception.Create(lBatch.ErrorText);
      Writeln(Format('SNAPSHOT PASS windows=%d request-count=100', [Length(lBatch.Windows)]));
    finally
      lService.Free;
    end;
  except
    on lException: Exception do
    begin
      Writeln('SELFTEST FAILED: ' + lException.Message);
      Result := 1;
    end;
  end;
end;

end.

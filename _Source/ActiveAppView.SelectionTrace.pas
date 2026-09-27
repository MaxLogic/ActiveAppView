unit ActiveAppView.SelectionTrace;

// Appends rare selection-loss diagnostics to a size-bounded, rotated log. Writes run off the VCL thread.

interface

procedure ConfigureSelectionTrace(const aFileName: string; const aMaxBytes: Int64 = 1048576;
  const aKeepFiles: Integer = 2);
procedure TraceSelection(const aEvent: string; const aDetails: string);
function WaitSelectionTraceIdle(const aTimeoutMs: Cardinal): Boolean;
function RunSelectionTraceSelfTests(const aArg: string): Integer;

implementation

uses
  System.Classes, System.IOUtils, System.SyncObjs, System.SysUtils, System.Threading;

var
  gFileName: string;
  gIdle: TEvent;
  gKeepFiles: Integer;
  gLock: TCriticalSection;
  gMaxBytes: Int64;
  gPending: TStringList;
  gWriting: Boolean;

procedure ConfigureSelectionTrace(const aFileName: string; const aMaxBytes: Int64; const aKeepFiles: Integer);
begin
  WaitSelectionTraceIdle(2000);
  gLock.Enter;
  try
    gFileName := aFileName;
    gMaxBytes := aMaxBytes;
    gKeepFiles := aKeepFiles;
  finally
    gLock.Leave;
  end;
end;

procedure RotateTraceFiles(const aFileName: string; const aKeepFiles: Integer);
var
  i: Integer;
begin
  if aKeepFiles <= 0 then
  begin
    TFile.Delete(aFileName);
    Exit;
  end;
  if TFile.Exists(aFileName + '.' + IntToStr(aKeepFiles)) then
    TFile.Delete(aFileName + '.' + IntToStr(aKeepFiles));
  for i := aKeepFiles - 1 downto 1 do
    if TFile.Exists(aFileName + '.' + IntToStr(i)) then
      TFile.Move(aFileName + '.' + IntToStr(i), aFileName + '.' + IntToStr(i + 1));
  TFile.Move(aFileName, aFileName + '.1');
end;

procedure AppendTraceText(const aFileName: string; const aText: string; const aMaxBytes: Int64;
  const aKeepFiles: Integer);
var
  lBytes: TBytes;
  lStream: TFileStream;
begin
  lBytes := TEncoding.UTF8.GetBytes(aText);
  if TFile.Exists(aFileName) then
  begin
    lStream := TFileStream.Create(aFileName, fmOpenReadWrite or fmShareDenyWrite);
    if (lStream.Size > 0) and (lStream.Size + Length(lBytes) > aMaxBytes) then
    begin
      FreeAndNil(lStream);
      RotateTraceFiles(aFileName, aKeepFiles);
    end;
  end else
    lStream := nil;
  if not Assigned(lStream) then
    lStream := TFileStream.Create(aFileName, fmCreate or fmShareDenyWrite);
  try
    lStream.Seek(0, soEnd);
    lStream.WriteBuffer(lBytes, Length(lBytes));
  finally
    lStream.Free;
  end;
end;

procedure WritePendingTrace;
var
  lFileName: string;
  lKeepFiles: Integer;
  lLine: string;
  lLines: TArray<string>;
  lMaxBytes: Int64;
begin
  while True do
  begin
    gLock.Enter;
    try
      if gPending.Count = 0 then
      begin
        gWriting := False;
        gIdle.SetEvent;
        Exit;
      end;
      lLines := gPending.ToStringArray;
      gPending.Clear;
      lFileName := gFileName;
      lMaxBytes := gMaxBytes;
      lKeepFiles := gKeepFiles;
    finally
      gLock.Leave;
    end;
    // Line by line, so rotation keeps each file within its limit.
    for lLine in lLines do
      try
        AppendTraceText(lFileName, lLine + sLineBreak, lMaxBytes, lKeepFiles);
      except
        // Diagnostics must never disturb the UI; a locked or read-only log drops this line.
        on Exception do;
      end;
  end;
end;

procedure TraceSelection(const aEvent: string; const aDetails: string);
var
  lStart: Boolean;
begin
  gLock.Enter;
  try
    if gFileName = '' then
      Exit;
    gPending.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + aEvent + ' ' + aDetails);
    lStart := not gWriting;
    if lStart then
    begin
      gWriting := True;
      gIdle.ResetEvent;
    end;
  finally
    gLock.Leave;
  end;
  if lStart then
    try
      TTask.Run(WritePendingTrace);
    except
      // Without a writer the queue would grow forever; drop it and report idle again.
      gLock.Enter;
      try
        gPending.Clear;
        gWriting := False;
        gIdle.SetEvent;
      finally
        gLock.Leave;
      end;
    end;
end;

function WaitSelectionTraceIdle(const aTimeoutMs: Cardinal): Boolean;
begin
  Result := gIdle.WaitFor(aTimeoutMs) = wrSignaled;
end;

function RunSelectionTraceSelfTests(const aArg: string): Integer;
var
  lDir: string;
  lFileName: string;
  lText: string;
  i: Integer;
begin
  if not SameText(aArg, '--self-test-selection-trace-file') then
    Exit(-1);
  Result := 0;
  lDir := TPath.Combine(TPath.GetTempPath, 'ActiveAppView-SelectionTrace-' + TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(lDir);
  try
    try
      lFileName := TPath.Combine(lDir, 'selection-trace.log');
      ConfigureSelectionTrace(lFileName, 300, 2);
      TraceSelection('selection-lost', 'list=apps old=0x10');
      if not WaitSelectionTraceIdle(5000) then
        raise Exception.Create('Trace writer did not become idle');
      lText := TFile.ReadAllText(lFileName, TEncoding.UTF8);
      if (Pos(' selection-lost list=apps old=0x10', lText) = 0) or (Pos(sLineBreak, lText) = 0) then
        raise Exception.Create('Trace line format is wrong: ' + lText);
      for i := 1 to 40 do
        TraceSelection('selection-lost', Format('list=apps row=%d', [i]));
      if not WaitSelectionTraceIdle(5000) then
        raise Exception.Create('Trace writer did not become idle after rotation');
      if not TFile.Exists(lFileName + '.1') or not TFile.Exists(lFileName + '.2') or
        TFile.Exists(lFileName + '.3') then
        raise Exception.Create('Trace rotation did not keep exactly two old files');
      if TFile.GetSize(lFileName) > 300 then
        raise Exception.Create('Current trace file exceeded its size limit');
      if Pos('row=40', TFile.ReadAllText(lFileName, TEncoding.UTF8)) = 0 then
        raise Exception.Create('Newest trace line is missing from the current file');
      Writeln('SELECTION TRACE FILE PASS format rotation keep=2');
    except
      on lException: Exception do
      begin
        Writeln('SELFTEST FAILED: ' + lException.Message);
        Result := 1;
      end;
    end;
  finally
    ConfigureSelectionTrace('');
    TDirectory.Delete(lDir, True);
  end;
end;

initialization
  gLock := TCriticalSection.Create;
  gPending := TStringList.Create;
  gIdle := TEvent.Create(nil, True, True, '');
  gMaxBytes := 1048576;
  gKeepFiles := 2;

finalization
  // A writer still stuck on I/O after the wait keeps using these; we leak them rather than crash on exit.
  if WaitSelectionTraceIdle(2000) then
  begin
    // The writer signals idle while still holding the lock; wait until it has released it.
    gLock.Enter;
    gLock.Leave;
    FreeAndNil(gIdle);
    FreeAndNil(gPending);
    FreeAndNil(gLock);
  end;

end.

unit ActiveAppView.SelfTests;

interface

function RunSelfTests: Integer;

implementation

uses
  System.Classes, System.IniFiles, System.IOUtils, System.SysUtils,
  Winapi.Windows,
  ActiveAppView.ChatMonitor;

const
  cInvalidWndMetadataSelfTestArg = '--self-test-chat-monitor-invalid-wnd';

function RunInvalidWndMetadataSelfTest: Integer;
var
  lApps: TArray<TChatAppSnapshot>;
  lIniFile: TMemIniFile;
  lMaskFileName: string;
  lMonitor: TChatMonitor;
  lSettingsFileName: string;
begin
  Result := 0;

  lMaskFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.review-mask.txt');
  lSettingsFileName := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.settings.ini');

  TFile.WriteAllText(lMaskFileName, 'filename=*', TEncoding.UTF8);

  lIniFile := TMemIniFile.Create(lSettingsFileName, TEncoding.UTF8, False);
  try
    lIniFile.WriteBool('ChatMonitor', 'Enabled', True);
    lIniFile.WriteBool('ChatMonitor', 'SoundEnabled', False);
    lIniFile.WriteString('ChatMonitor', 'ReviewMaskFile', lMaskFileName);
    lIniFile.UpdateFile;

    lMonitor := TChatMonitor.Create(lIniFile);
    try
      SetLength(lApps, 1);
      lApps[0].Wnd := HWND(1);
      lApps[0].Caption := 'self-test';
      lMonitor.ProcessSnapshot(lApps);
    finally
      lMonitor.Free;
    end;
  finally
    lIniFile.Free;
    TFile.Delete(lMaskFileName);
    TFile.Delete(lSettingsFileName);
  end;
end;

function RunSelfTests: Integer;
begin
  Result := -1;
  if SameText(ParamStr(1), cInvalidWndMetadataSelfTestArg) then
  begin
    try
      Result := RunInvalidWndMetadataSelfTest;
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: %s: %s', [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
  end;
end;

end.

unit ActiveAppViewMainForm;

interface

uses
  System.Classes, System.Generics.Collections, System.SyncObjs, System.SysUtils, System.Variants,
  Winapi.Messages, Winapi.Windows,
  Vcl.Buttons, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms, Vcl.Graphics, Vcl.Menus,
  Vcl.StdCtrls,
  CancelToken, maxAsync,
  ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache, ActiveAppViewCore;

type
  TAppsViewMainFrm = class(TForm)
    lbApps: TListBox;
    pnlApps: TPanel;
    labAppTitle: TStaticText;
    Splitter1: TSplitter;
    pnlExplorer: TPanel;
    labExplorerTitle: TStaticText;
    lbExplorer: TListBox;
    pnlAppFocusLeft: TPanel;
    pnlExplorerFocusLeft: TPanel;
    pnlAppsFocusRight: TPanel;
    pnlExplorerFocusRight: TPanel;
    pnlAppDetails: TPanel;
    imgAppScreenshot: TImage;
    pnlAppDetailInfo: TPanel;
    edAppFileName: TEdit;
    lapAppCaption: TStaticText;
    edAppCaption: TEdit;
    labAppFileName: TStaticText;
    Splitter2: TSplitter;
    pnlScripts: TPanel;
    labScriptsTitle: TStaticText;
    lbScripts: TListBox;
    pnlScriptsFocusLeft: TPanel;
    pnlScriptsFocusRight: TPanel;
    Splitter3: TSplitter;
    Splitter4: TSplitter;
    Splitter5: TSplitter;
    Splitter6: TSplitter;
    pnlConsole: TPanel;
    labConsoleTitle: TStaticText;
    lbConsole: TListBox;
    pnlConsoleFocusLeft: TPanel;
    pnlConsoleFocusRight: TPanel;
    pnlDesktop: TPanel;
    labDesktopTitle: TStaticText;
    lbDesktop: TListBox;
    pnlDesktopFocusLeft: TPanel;
    pnlDesktopFocusRight: TPanel;
    pnlShortCuts: TPanel;
    labShortCutsTitle: TStaticText;
    lbShortCuts: TListBox;
    pnlShortCutsFocusLeft: TPanel;
    pnlShortCutsFocusRight: TPanel;
    tmrChatMonitor: TTimer;
    Panel1: TPanel;
    labTemplateActiv: TStaticText;
    labTemplateInActiv: TStaticText;
    edCommandLineParams: TEdit;
    labCommandLineParams: TStaticText;
    edPID: TEdit;
    labPid: TStaticText;
    edAppUserModelID: TEdit;
    labAppUserModelID: TStaticText;
    edRelaunchCommand: TEdit;
    labRelaunchCommand: TStaticText;
    chkChatNotificationSound: TCheckBox;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure lbAppsDblClick(Sender: TObject);
    procedure lbAppsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbScriptsDblClick(Sender: TObject);
    procedure lbAppsClick(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure lbScriptsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbDesktopDblClick(Sender: TObject);
    procedure lbDesktopKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbShortCutsDblClick(Sender: TObject);
    procedure lbShortCutsKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure tmrChatMonitorTimer(Sender: TObject);
    procedure chkChatNotificationSoundClick(aSender: TObject);
  private

    fApps: TAppList;
    fAuxListRefresh: iAsync;
    fAuxListRefreshBusy: Integer;
    fAuxListRefreshPending: Integer;
    fChatMonitorConfiguredEnabled: Boolean;
    fChatMonitorBusy: Integer;
    fChatMonitorPending: Integer;
    fChatMonitorTask: iAsync;
    fConfigCache: TConfigCache;
    fDeepPrefixLoadBusy: Integer;
    fDeepPrefixLoadTask: iAsync;
    fDeepPrefixReady: Integer;
    fOrgAppOnActivate: TNotifyEvent;
    fChatMonitor: TChatMonitor;
    fGuiRefreshQueued: Integer;
    fLastFormFocusTick: UInt64;
    fPendingAuxSnapshot: TObject;
    fChatMonitorSnapshot: TArray<TChatAppSnapshot>;
    fSharedAppsSnapshot: TArray<TChatAppSnapshot>;
    fSharedAppsSnapshotTick: UInt64;
    fStartupDataLoadBusy: Integer;
    fStartupDataLoadTask: iAsync;
    fStartupDataReady: Integer;
    fStartupSkipSharedRefreshOnce: Integer;
    fStartupProfileAuxReadyLogged: Integer;
    fStartupProfileFirstGuiLogged: Integer;
    fStartupProfileFullMetadataGuiLogged: Integer;
    fStartupProfileDeepPrefixGuiLogged: Integer;
    fStartupProfileLog: TStringList;
    fStartupProfileLogFileName: string;
    fStartupProfileLogSync: TCriticalSection;
    fStartupProfileStartTick: Int64;
    fStartupProfileWarmupDoneLogged: Integer;
    fWindowActionsPopupMenu: TPopupMenu;
    fCloseWindowMenuItem: TMenuItem;
    fTerminateWindowMenuItem: TMenuItem;
    fShutdownToken: iCancelToken;
    fShuttingDown: Integer;
    procedure AppOnActivate(Sender: TObject);
    procedure ApplyAuxListsSnapshot(aSnapshotObject: TObject);
    procedure ApplyDesktopSnapshot(const aItems: TNamedValueArray);
    procedure ApplyScriptsSnapshot(const aScripts: TStringArray);
    procedure ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
    function BuildAuxListsSnapshot: TObject;
    procedure MarkFormFocused;
    procedure OnAuxListsRefreshDone;
    procedure OnChatMonitorDone;
    procedure OnDeepPrefixLoadDone;
    procedure OnStartupDataLoadDone;
    procedure QueueGuiRefresh;
    procedure RebuildSharedAppsSnapshot;
    procedure RunAuxListsRefresh;
    procedure RunChatMonitorSnapshot;
    procedure RunDeepPrefixLoad;
    procedure RunStartupDataLoad;
    procedure StartAuxListsRefresh;
    procedure StartChatMonitorProcessing;
    procedure StartDeepPrefixLoad;
    procedure StartStartupDataLoad;
    procedure EnsureSharedAppsSnapshotFresh(const aMaxAgeMs: UInt64);
    procedure FlushStartupProfileLog;
    function GetStartupElapsedMs: Int64;
    function IsDeepPrefixReady: Boolean;
    function IsStartupDataReady: Boolean;
    function IsShuttingDown: Boolean;
    procedure LogStartupTiming(const aPhase: string; const aDetails: string = '');
    procedure RequestAsyncStop(const aAsync: iAsync);
    procedure WaitAsyncWithShutdown(const aAsync: iAsync; const aTimeoutMs: Cardinal);
    procedure UpdateGui;
    procedure CloseSelectedWindow(const aListBox: TListBox);
    procedure CreateWindowActionsPopupMenu;
    function GetPopupSourceListBox: TListBox;
    function IsProcessActive(const aProcessId: Cardinal): Boolean;
    procedure QuickValidateListBoxProcesses(const aListBox: TListBox);
    procedure QuickValidateProcessesOnRefocus;
    procedure RemoveWindowFromListBox(const aListBox: TListBox; const aWnd: hWnd);
    procedure RemoveWindowFromUiAndCache(const aWnd: hWnd);
    procedure RunWindowActionCleanupCheck(const aWnd: hWnd; const aProcessId: Cardinal;
      const aElapsedMs: Cardinal; const aDelayMs: Cardinal);
    procedure ScheduleWindowActionCleanup(const aWnd: hWnd; const aProcessId: Cardinal);
    procedure TerminateSelectedWindow(const aListBox: TListBox);
    procedure WindowActionsPopupMenuPopup(aSender: TObject);
    procedure WindowCloseMenuItemClick(aSender: TObject);
    procedure WindowTerminateMenuItemClick(aSender: TObject);

    procedure BringToFrontFocusedApp(lb: TListBox);
    procedure UpdateAppDetail(const aAllowExtendedMetadata: Boolean = True);
    procedure CheckPrefixRule(var s: string; app: TAppInfo; const aRules: TPrefixRuleArray;
      aAllowFileNameMatching: Boolean; aAllowDeepMetadata: Boolean);
    function ExcludeByMask(app: TAppInfo; const aMasks: TStringArray;
      aAllowFileNameMatching: Boolean): boolean;
    procedure RestoreItemIndex(lb: TListBox; wnd: hwnd; oldItemIndex: integer; const aOldItemCaption: string);
    function GetWnd(lb: TListBox): hwnd;
    procedure ActiveControlChanged(Sender: TObject);
    procedure ClearListBoxItemData(lb: TListBox);
    procedure UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
    function IsTerminalApp(const aFileName: string; const aPatterns: TStringArray): boolean;
    function TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
    procedure AddDesktopItemsFromFolder(const aFolder: string; var aItems: TNamedValueArray);
    function TryParseShortCutValue(const aValue: string; out aTargetPath: string;
      out aParams: string): boolean;
    procedure ActivateDesktopItem;
    procedure ActivateShortCutItem;
    procedure RestoreSelectedItem(lb: TListBox; const aCaption: string);
  public

  end;

var
  AppsViewMainFrm: TAppsViewMainFrm;

function RunMainFormSelfTests(const aArg: string): Integer;

implementation

uses
  System.Diagnostics, System.IniFiles, System.IOUtils, System.StrUtils, System.Threading,
  Winapi.ActiveX, Winapi.KnownFolders, Winapi.MMSystem, Winapi.ShellAPI, Winapi.ShlObj,
  AutoFree, bsUtils, maxCallMeLater, maxLogic.AutoStart, maxLogic.IOUtils, maxLogic.StrUtils,
  srDesktop;

{$R *.dfm}

type
  TListBoxItemData = class
  public
    Value: string;
    constructor Create(const aValue: string);
  end;

  TAuxListsSnapshot = class
  public
    DesktopItems: TNamedValueArray;
    Scripts: TStringArray;
    ShortCuts: TNamedValueArray;
  end;

  TAppPrefetchProc = reference to procedure(const aApp: TAppInfo);

const
  cShortCutsFileName = 'ShortCuts.txt';
  cTerminalPatternsFileName = 'TerminalPatterns.txt';
  cScriptsFolderName = 'Scripts';
  cHideMaskFileName = 'HideMask.txt';
  cPrefixMaskFileName = 'PrefixMask.txt';
  cSettingsFileName = 'settings.ini';
  cRestoreItemIndexSelfTestArg = '--self-test-restore-item-index';
  cWarmupPrefetchSelfTestArg = '--self-test-startup-warmup-prefetch';
  cWarmupShutdownCheckSelfTestArg = '--self-test-startup-warmup-shutdown-check';
  cIgnoreF4AfterFocusMs = 200;
  cShutdownTaskWaitTimeoutMs = 25;
  cWindowActionVerifyDelayMs = 350;
  cWindowActionVerifyDelayStepMs = 150;
  cWindowActionVerifyMaxDurationMs = 5000;

resourcestring
  rsWindowActionClose = 'Close';
  rsWindowActionTerminate = 'Terminate';
  rsShortCutTargetMissing = 'ShortCut target not found: %s';

function FindSortedCaptionIndex(const aItems: TStrings; const aOldItemCaption: string): Integer;
var
  lItems: TStringList;
  lIndex: Integer;
begin
  Result := -1;
  if aOldItemCaption = '' then
    Exit;

  gc(lItems, TStringList.Create);
  lItems.Assign(aItems);
  lItems.Sorted := True;
  if lItems.Find(aOldItemCaption, lIndex) then
    Result := lIndex;
end;

procedure PrefetchAppFileNamesInParallel(
  const aApps: TArray<TAppInfo>;
  const aCancelToken: iCancelToken;
  const aPrefetchProc: TAppPrefetchProc = nil);
var
  lPrefetchProc: TAppPrefetchProc;
begin
  if Length(aApps) = 0 then
    Exit;

  if Assigned(aCancelToken) and aCancelToken.Canceled then
    Exit;

  lPrefetchProc := aPrefetchProc;
  TParallel.&For(0, High(aApps),
    procedure(aIndex: Integer)
    var
      lApp: TAppInfo;
    begin
      try
        lApp := aApps[aIndex];
        if Assigned(lPrefetchProc) then
        begin
          lPrefetchProc(lApp);
          Exit;
        end;

        if (lApp = nil) or (lApp.Caption = '') then
          Exit;

        lApp.FileName;
      except
        // Window metadata can disappear while we prefetch in parallel; skip transient failures.
      end;
    end);
end;

{ TListBoxItemData }

constructor TListBoxItemData.Create(const aValue: string);
begin
  inherited Create;
  Value := aValue;
end;

procedure TAppsViewMainFrm.ActiveControlChanged(Sender: TObject);
var
  lActive: TWinControl;
  lPrefix: string;
var
  lListBoxes: TArray<TListBox>;
  lTitles: TArray<TStaticText>;
  lLeftPanels: TArray<TPanel>;
  lRightPanels: TArray<TPanel>;
  lIsActive: boolean;
  X: integer;
begin
  if IsShuttingDown then
    Exit;

  lActive := self.ActiveControl;

  lPrefix := copy(labTemplateActiv.caption, 1, 2);
  lListBoxes := [lbApps, lbExplorer, lbScripts, lbConsole, lbDesktop, lbShortCuts];
  lTitles := [labAppTitle, labExplorerTitle, labScriptsTitle, labConsoleTitle, labDesktopTitle, labShortCutsTitle];
  lLeftPanels := [pnlAppFocusLeft, pnlExplorerFocusLeft, pnlScriptsFocusLeft, pnlConsoleFocusLeft,
    pnlDesktopFocusLeft, pnlShortCutsFocusLeft];
  lRightPanels := [pnlAppsFocusRight, pnlExplorerFocusRight, pnlScriptsFocusRight, pnlConsoleFocusRight,
    pnlDesktopFocusRight, pnlShortCutsFocusRight];

  for X := 0 to High(lTitles) do
  begin
    lIsActive := lActive = lListBoxes[X];
    UpdateTitlePrefix(lTitles[X], lPrefix, lIsActive);
    if lIsActive then
    begin
      lTitles[X].Font.Assign(labTemplateActiv.Font);
      lLeftPanels[X].Color := clBlack;
    end
    else
    begin
      lTitles[X].Font.Assign(labTemplateInActiv.Font);
      lLeftPanels[X].Color := self.Color;
    end;
    lRightPanels[X].Color := lLeftPanels[X].Color;
  end;
end;

procedure TAppsViewMainFrm.AppOnActivate(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  MarkFormFocused;
  QuickValidateProcessesOnRefocus;
  if TInterlocked.CompareExchange(fStartupDataReady, 0, 0) = 0 then
    StartStartupDataLoad
  else
    QueueGuiRefresh;
  if assigned(fOrgAppOnActivate) then
    fOrgAppOnActivate(Sender);
end;

procedure TAppsViewMainFrm.CloseSelectedWindow(const aListBox: TListBox);
var
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  if not Assigned(aListBox) then
    Exit;

  lWnd := GetWnd(aListBox);
  if lWnd = 0 then
    Exit;

  lProcessId := 0;
  GetWindowThreadProcessId(lWnd, lProcessId);
  PostMessage(lWnd, WM_CLOSE, 0, 0);
  ScheduleWindowActionCleanup(lWnd, lProcessId);
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.CreateWindowActionsPopupMenu;
begin
  fWindowActionsPopupMenu := TPopupMenu.Create(Self);
  fWindowActionsPopupMenu.OnPopup := WindowActionsPopupMenuPopup;

  fCloseWindowMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fCloseWindowMenuItem.Caption := rsWindowActionClose;
  fCloseWindowMenuItem.OnClick := WindowCloseMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fCloseWindowMenuItem);

  fTerminateWindowMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fTerminateWindowMenuItem.Caption := rsWindowActionTerminate;
  fTerminateWindowMenuItem.OnClick := WindowTerminateMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fTerminateWindowMenuItem);

  lbApps.PopupMenu := fWindowActionsPopupMenu;
  lbExplorer.PopupMenu := fWindowActionsPopupMenu;
end;

function TAppsViewMainFrm.GetPopupSourceListBox: TListBox;
begin
  Result := nil;
  if Assigned(fWindowActionsPopupMenu) and (fWindowActionsPopupMenu.PopupComponent is TListBox) then
    Result := TListBox(fWindowActionsPopupMenu.PopupComponent);

  if (Result <> lbApps) and (Result <> lbExplorer) then
    Result := nil;
end;

function TAppsViewMainFrm.IsProcessActive(const aProcessId: Cardinal): Boolean;
var
  lLastError: Cardinal;
  lProcessHandle: THandle;
begin
  if aProcessId = 0 then
    Exit(False);

  lProcessHandle := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_INFORMATION, False, aProcessId);
  if lProcessHandle = 0 then
  begin
    lLastError := GetLastError;
    if lLastError = ERROR_ACCESS_DENIED then
      Exit(True);
    Exit(False);
  end;
  try
    Result := WaitForSingleObject(lProcessHandle, 0) = WAIT_TIMEOUT;
  finally
    CloseHandle(lProcessHandle);
  end;
end;

procedure TAppsViewMainFrm.QuickValidateListBoxProcesses(const aListBox: TListBox);
var
  lIndex: Integer;
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  if not Assigned(aListBox) then
    Exit;

  aListBox.Items.BeginUpdate;
  try
    for lIndex := aListBox.Items.Count - 1 downto 0 do
    begin
      lWnd := hWnd(aListBox.Items.Objects[lIndex]);
      if lWnd = 0 then
      begin
        aListBox.Items.Delete(lIndex);
        Continue;
      end;
      if not IsWindow(lWnd) then
      begin
        aListBox.Items.Delete(lIndex);
        Continue;
      end;

      lProcessId := 0;
      GetWindowThreadProcessId(lWnd, lProcessId);
      if (lProcessId = 0) or (not IsProcessActive(lProcessId)) then
        aListBox.Items.Delete(lIndex);
    end;
  finally
    aListBox.Items.EndUpdate;
  end;

  if aListBox.Items.Count = 0 then
    aListBox.ItemIndex := -1
  else if aListBox.ItemIndex < 0 then
    aListBox.ItemIndex := 0
  else if aListBox.ItemIndex >= aListBox.Items.Count then
    aListBox.ItemIndex := aListBox.Items.Count - 1;
end;

procedure TAppsViewMainFrm.QuickValidateProcessesOnRefocus;
begin
  QuickValidateListBoxProcesses(lbApps);
  QuickValidateListBoxProcesses(lbExplorer);
  QuickValidateListBoxProcesses(lbConsole);
  fSharedAppsSnapshotTick := 0;
  UpdateAppDetail(False);
end;

procedure TAppsViewMainFrm.RemoveWindowFromListBox(const aListBox: TListBox; const aWnd: hWnd);
var
  lIndex: Integer;
begin
  if (not Assigned(aListBox)) or (aWnd = 0) then
    Exit;

  aListBox.Items.BeginUpdate;
  try
    for lIndex := aListBox.Items.Count - 1 downto 0 do
    begin
      if hWnd(aListBox.Items.Objects[lIndex]) = aWnd then
        aListBox.Items.Delete(lIndex);
    end;
  finally
    aListBox.Items.EndUpdate;
  end;

  if aListBox.Items.Count = 0 then
    aListBox.ItemIndex := -1
  else if aListBox.ItemIndex < 0 then
    aListBox.ItemIndex := 0
  else if aListBox.ItemIndex >= aListBox.Items.Count then
    aListBox.ItemIndex := aListBox.Items.Count - 1;
end;

procedure TAppsViewMainFrm.RemoveWindowFromUiAndCache(const aWnd: hWnd);
begin
  if aWnd = 0 then
    Exit;

  fApps.Update;
  RebuildSharedAppsSnapshot;
  RemoveWindowFromListBox(lbApps, aWnd);
  RemoveWindowFromListBox(lbExplorer, aWnd);
  RemoveWindowFromListBox(lbConsole, aWnd);
  UpdateAppDetail(False);
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.ScheduleWindowActionCleanup(const aWnd: hWnd; const aProcessId: Cardinal);
begin
  if IsShuttingDown then
    Exit;

  RunWindowActionCleanupCheck(aWnd, aProcessId, 0, cWindowActionVerifyDelayMs);
end;

procedure TAppsViewMainFrm.RunWindowActionCleanupCheck(const aWnd: hWnd; const aProcessId: Cardinal;
  const aElapsedMs: Cardinal; const aDelayMs: Cardinal);
var
  lDelayMs: Cardinal;
begin
  if IsShuttingDown then
    Exit;

  lDelayMs := aDelayMs;
  if lDelayMs = 0 then
    lDelayMs := cWindowActionVerifyDelayMs;
  CallmeLater(
    procedure
    var
      lElapsedMs: Cardinal;
      lNextDelayMs: Cardinal;
    begin
      if IsShuttingDown then
        Exit;
      if (aWnd <> 0) and (not IsWindow(aWnd)) then
      begin
        RemoveWindowFromUiAndCache(aWnd);
        Exit;
      end;
      if not IsProcessActive(aProcessId) then
      begin
        RemoveWindowFromUiAndCache(aWnd);
        Exit;
      end;

      lElapsedMs := aElapsedMs + lDelayMs;
      if lElapsedMs >= cWindowActionVerifyMaxDurationMs then
        Exit;

      lNextDelayMs := lDelayMs + cWindowActionVerifyDelayStepMs;
      if (lElapsedMs + lNextDelayMs) > cWindowActionVerifyMaxDurationMs then
        lNextDelayMs := cWindowActionVerifyMaxDurationMs - lElapsedMs;
      RunWindowActionCleanupCheck(aWnd, aProcessId, lElapsedMs, lNextDelayMs);
    end,
    lDelayMs,
    Self);
end;

procedure TAppsViewMainFrm.BringToFrontFocusedApp(lb: TListBox);
var
  app: TAppInfo;
  wnd: hwnd;
begin
  wnd := 0;
  if lb = lbApps then
    UpdateAppDetail;

  wnd := GetWnd(lb);

  if fApps.TryGetApp(wnd, app) then
    app.SHOW;
end;

procedure TAppsViewMainFrm.TerminateSelectedWindow(const aListBox: TListBox);
var
  lProcessHandle: THandle;
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  if not Assigned(aListBox) then
    Exit;

  lWnd := GetWnd(aListBox);
  if lWnd = 0 then
    Exit;

  lProcessId := 0;
  GetWindowThreadProcessId(lWnd, lProcessId);
  if lProcessId = 0 then
    Exit;

  lProcessHandle := OpenProcess(PROCESS_TERMINATE, False, lProcessId);
  if lProcessHandle = 0 then
    Exit;
  try
    TerminateProcess(lProcessHandle, 1);
  finally
    CloseHandle(lProcessHandle);
  end;

  ScheduleWindowActionCleanup(lWnd, lProcessId);
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.WindowActionsPopupMenuPopup(aSender: TObject);
var
  lHasWindow: Boolean;
  lListBox: TListBox;
begin
  lListBox := GetPopupSourceListBox;
  lHasWindow := Assigned(lListBox) and (GetWnd(lListBox) <> 0);

  if Assigned(fCloseWindowMenuItem) then
    fCloseWindowMenuItem.Enabled := lHasWindow;
  if Assigned(fTerminateWindowMenuItem) then
    fTerminateWindowMenuItem.Enabled := lHasWindow;
end;

procedure TAppsViewMainFrm.WindowCloseMenuItemClick(aSender: TObject);
begin
  CloseSelectedWindow(GetPopupSourceListBox);
end;

procedure TAppsViewMainFrm.WindowTerminateMenuItemClick(aSender: TObject);
begin
  TerminateSelectedWindow(GetPopupSourceListBox);
end;

procedure TAppsViewMainFrm.ClearListBoxItemData(lb: TListBox);
var
  i: integer;
  lItem: TObject;
begin
  for i := 0 to lb.Items.Count - 1 do
  begin
    lItem := lb.Items.Objects[i];
    if lItem is TListBoxItemData then
      lItem.Free;
  end;
  lb.Items.Clear;
end;

procedure TAppsViewMainFrm.UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
var
  lCaption: string;
begin
  lCaption := st.Caption;
  if aEnabled then
  begin
    if not StartsText(aPrefix, lCaption) then
      st.Caption := aPrefix + lCaption;
  end
  else
  begin
    if StartsText(aPrefix, lCaption) then
      st.Caption := Trim(Copy(lCaption, Length(aPrefix) + 1, Length(lCaption)));
  end;
end;

function TAppsViewMainFrm.IsTerminalApp(const aFileName: string; const aPatterns: TStringArray): boolean;
var
  lPattern: string;
begin
  Result := False;
  if aFileName = '' then
    Exit;

  for lPattern in aPatterns do
    if maxLogic.StrUtils.StringMatches(aFileName, lPattern, False) then
      Exit(True);
end;

function TAppsViewMainFrm.TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
var
  lPtr: PWideChar;
begin
  aPath := '';
  lPtr := nil;
  Result := SHGetKnownFolderPath(aFolderId, 0, 0, lPtr) = S_OK;
  if Result then
    aPath := lPtr;

  if lPtr <> nil then
    CoTaskMemFree(lPtr);
end;

procedure TAppsViewMainFrm.AddDesktopItemsFromFolder(const aFolder: string; var aItems: TNamedValueArray);
var
  lDir: string;
  lFile: string;
  lItem: TNamedValue;
begin
  if not DirectoryExists(aFolder) then
    Exit;

  for lDir in TDirectory.GetDirectories(aFolder) do
  begin
    lItem.Name := ExtractFileName(lDir);
    if lItem.Name = '' then
      lItem.Name := lDir;
    lItem.Value := lDir;
    SetLength(aItems, Length(aItems) + 1);
    aItems[High(aItems)] := lItem;
  end;

  for lFile in TDirectory.GetFiles(aFolder, '*.*') do
  begin
    lItem.Name := ExtractFileName(lFile);
    if lItem.Name = '' then
      lItem.Name := lFile;
    lItem.Value := lFile;
    SetLength(aItems, Length(aItems) + 1);
    aItems[High(aItems)] := lItem;
  end;
end;

function TAppsViewMainFrm.BuildAuxListsSnapshot: TObject;
var
  lExt: string;
  lItem: TNamedValue;
  lScriptFile: string;
  lScriptsDir: string;
  lPublicDesktop: string;
  lSnapshot: TAuxListsSnapshot;
  lUserDesktop: string;
begin
  if IsShuttingDown then
    Exit(nil);

  lSnapshot := TAuxListsSnapshot.Create;
  try
    SetLength(lSnapshot.DesktopItems, 0);
    if IsShuttingDown then
    begin
      lSnapshot.Free;
      Exit(nil);
    end;

    if TryGetKnownFolderPath(FOLDERID_Desktop, lUserDesktop) then
      AddDesktopItemsFromFolder(lUserDesktop, lSnapshot.DesktopItems);
    if TryGetKnownFolderPath(FOLDERID_PublicDesktop, lPublicDesktop) then
      if not SameText(lUserDesktop, lPublicDesktop) then
        AddDesktopItemsFromFolder(lPublicDesktop, lSnapshot.DesktopItems);

    if IsShuttingDown then
    begin
      lSnapshot.Free;
      Exit(nil);
    end;

    lSnapshot.ShortCuts := fConfigCache.GetShortCuts(cShortCutsFileName);

    SetLength(lSnapshot.Scripts, 0);
    lScriptsDir := CombinePath([GetInstallDir, cScriptsFolderName]);
    if TDirectory.Exists(lScriptsDir) then
    begin
      for lScriptFile in TDirectory.GetFiles(lScriptsDir, '*.*') do
      begin
        if IsShuttingDown then
        begin
          lSnapshot.Free;
          Exit(nil);
        end;

        lExt := ExtractFileExt(lScriptFile);
        if System.StrUtils.MatchText(lExt, ['.cmd', '.bat', '.ps1', '.exe', '.py']) then
        begin
          lItem.Name := ExtractFileName(lScriptFile);
          lItem.Value := '';
          SetLength(lSnapshot.Scripts, Length(lSnapshot.Scripts) + 1);
          lSnapshot.Scripts[High(lSnapshot.Scripts)] := lItem.Name;
        end;
      end;
    end;

    Result := lSnapshot;
  except
    lSnapshot.Free;
    raise;
  end;
end;

procedure TAppsViewMainFrm.ApplyDesktopSnapshot(const aItems: TNamedValueArray);
var
  lIndex: Integer;
  lItem: TListBoxItemData;
  lPrevCaption: string;
begin
  lPrevCaption := '';
  if lbDesktop.ItemIndex <> -1 then
    lPrevCaption := lbDesktop.Items[lbDesktop.ItemIndex];

  lbDesktop.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbDesktop);
    for lIndex := 0 to High(aItems) do
    begin
      lItem := TListBoxItemData.Create(aItems[lIndex].Value);
      lbDesktop.Items.AddObject(aItems[lIndex].Name, lItem);
    end;
  finally
    lbDesktop.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbDesktop, lPrevCaption);
end;

procedure TAppsViewMainFrm.ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
var
  lIndex: Integer;
  lItem: TListBoxItemData;
  lPrevCaption: string;
begin
  lPrevCaption := '';
  if lbShortCuts.ItemIndex <> -1 then
    lPrevCaption := lbShortCuts.Items[lbShortCuts.ItemIndex];

  lbShortCuts.Items.BeginUpdate;
  try
    ClearListBoxItemData(lbShortCuts);
    for lIndex := 0 to High(aItems) do
    begin
      lItem := TListBoxItemData.Create(aItems[lIndex].Value);
      lbShortCuts.Items.AddObject(aItems[lIndex].Name, lItem);
    end;
  finally
    lbShortCuts.Items.EndUpdate;
  end;

  RestoreSelectedItem(lbShortCuts, lPrevCaption);
end;

procedure TAppsViewMainFrm.ApplyScriptsSnapshot(const aScripts: TStringArray);
var
  lIndex: Integer;
  lItemIndex: Integer;
  lScriptName: string;
  lPrevFocused: string;
begin
  lPrevFocused := '';
  if lbScripts.ItemIndex <> -1 then
    lPrevFocused := lbScripts.Items[lbScripts.ItemIndex];

  lbScripts.Items.BeginUpdate;
  try
    lbScripts.ItemIndex := -1;
    lbScripts.Items.Clear;
    for lIndex := 0 to High(aScripts) do
    begin
      lScriptName := aScripts[lIndex];
      lItemIndex := lbScripts.Items.Add(lScriptName);
      if (lbScripts.ItemIndex = -1) and SameText(lPrevFocused, lScriptName) then
        lbScripts.ItemIndex := lItemIndex;
    end;
  finally
    lbScripts.Items.EndUpdate;
  end;
end;

procedure TAppsViewMainFrm.ApplyAuxListsSnapshot(aSnapshotObject: TObject);
var
  lSnapshot: TAuxListsSnapshot;
begin
  if not (aSnapshotObject is TAuxListsSnapshot) then
    Exit;

  lSnapshot := TAuxListsSnapshot(aSnapshotObject);
  ApplyScriptsSnapshot(lSnapshot.Scripts);
  ApplyDesktopSnapshot(lSnapshot.DesktopItems);
  ApplyShortCutsSnapshot(lSnapshot.ShortCuts);
end;

procedure TAppsViewMainFrm.RunAuxListsRefresh;
begin
  if IsShuttingDown then
    Exit;

  fPendingAuxSnapshot := BuildAuxListsSnapshot;
end;

procedure TAppsViewMainFrm.OnAuxListsRefreshDone;
begin
  try
    if Assigned(fPendingAuxSnapshot) then
    begin
      if not IsShuttingDown then
      begin
        ApplyAuxListsSnapshot(fPendingAuxSnapshot);
        if TInterlocked.CompareExchange(fStartupProfileAuxReadyLogged, 1, 0) = 0 then
          LogStartupTiming(
            'AuxLists.Ready',
            Format(
              'scripts=%d desktop=%d shortcuts=%d',
              [lbScripts.Items.Count, lbDesktop.Items.Count, lbShortCuts.Items.Count]));
      end;
      FreeAndNil(fPendingAuxSnapshot);
    end;
  finally
    TInterlocked.Exchange(fAuxListRefreshBusy, 0);
    if (TInterlocked.Exchange(fAuxListRefreshPending, 0) = 1) and (not IsShuttingDown) then
      StartAuxListsRefresh;
  end;
end;

procedure TAppsViewMainFrm.StartAuxListsRefresh;
begin
  if IsShuttingDown then
    Exit;

  if TInterlocked.CompareExchange(fAuxListRefreshBusy, 1, 0) <> 0 then
  begin
    TInterlocked.Exchange(fAuxListRefreshPending, 1);
    Exit;
  end;

  fAuxListRefresh := SimpleAsyncCall(RunAuxListsRefresh, 'ActiveAppView.AuxListRefresh', OnAuxListsRefreshDone);
end;

procedure TAppsViewMainFrm.RunStartupDataLoad;
var
  lApps: TArray<TAppInfo>;
  lIndex: Integer;
  lParallelPrefetchMs: Int64;
  lRefreshSnapshotMs: Int64;
  lWarmupWatch: TStopwatch;
  lPhaseWatch: TStopwatch;
begin
  if IsShuttingDown then
    Exit;

  lWarmupWatch := TStopwatch.StartNew;

  fConfigCache.GetHideMasks(cHideMaskFileName);
  fConfigCache.GetPrefixRules(cPrefixMaskFileName);
  fConfigCache.GetTerminalPatterns(cTerminalPatternsFileName);

  lPhaseWatch := TStopwatch.StartNew;
  EnsureSharedAppsSnapshotFresh(0);
  lRefreshSnapshotMs := lPhaseWatch.ElapsedMilliseconds;
  if IsShuttingDown then
    Exit;

  SetLength(lApps, fApps.Count);
  for lIndex := 0 to fApps.Count - 1 do
    lApps[lIndex] := fApps[lIndex];

  if Length(lApps) = 0 then
    Exit;

  lPhaseWatch := TStopwatch.StartNew;
  PrefetchAppFileNamesInParallel(
    lApps,
    fShutdownToken);
  lParallelPrefetchMs := lPhaseWatch.ElapsedMilliseconds;

  if not IsShuttingDown then
  begin
    LogStartupTiming(
      'Warmup.ThreadDone',
      Format(
        'apps=%d refreshSnapshot=%dms fileNamePrefetch=%dms total=%dms',
        [Length(lApps), lRefreshSnapshotMs, lParallelPrefetchMs, lWarmupWatch.ElapsedMilliseconds]));
    if TInterlocked.CompareExchange(fStartupDataReady, 1, 0) = 0 then
    begin
      TInterlocked.Exchange(fStartupSkipSharedRefreshOnce, 1);
      TThread.Synchronize(nil,
        procedure
        begin
          if IsShuttingDown then
            Exit;

          LogStartupTiming('Warmup.SynchronizeUi');
          if TInterlocked.CompareExchange(fStartupProfileWarmupDoneLogged, 1, 0) = 0 then
            LogStartupTiming('Warmup.Done');
          tmrChatMonitor.Enabled := fChatMonitorConfiguredEnabled;
          StartDeepPrefixLoad;
          UpdateGui;
        end);
    end;
  end;
end;

procedure TAppsViewMainFrm.RunDeepPrefixLoad;
var
  lApps: TArray<TAppInfo>;
  lIndex: Integer;
  lNeedAppUserModelID: Boolean;
  lNeedCmdParams: Boolean;
  lPhaseWatch: TStopwatch;
  lPrefixPrefetchMs: Int64;
  lPrefixRules: TPrefixRuleArray;
  lRule: TPrefixRule;
begin
  if IsShuttingDown then
    Exit;

  lPrefixRules := fConfigCache.GetPrefixRules(cPrefixMaskFileName);
  lNeedAppUserModelID := False;
  lNeedCmdParams := False;
  for lRule in lPrefixRules do
  begin
    if lRule.AppUserModelIDMask <> '' then
      lNeedAppUserModelID := True;
    if lRule.CmdParamsMask <> '' then
      lNeedCmdParams := True;
    if lNeedAppUserModelID and lNeedCmdParams then
      Break;
  end;

  if not (lNeedAppUserModelID or lNeedCmdParams) then
  begin
    LogStartupTiming('DeepPrefix.ThreadDone', 'skipped no-deep-rules');
    Exit;
  end;

  SetLength(lApps, fApps.Count);
  for lIndex := 0 to fApps.Count - 1 do
    lApps[lIndex] := fApps[lIndex];

  if Length(lApps) = 0 then
  begin
    LogStartupTiming('DeepPrefix.ThreadDone', 'skipped no-apps');
    Exit;
  end;

  lPhaseWatch := TStopwatch.StartNew;
  TParallel.&For(0, High(lApps),
    procedure(aIndex: Integer)
    var
      lApp: TAppInfo;
    begin
      lApp := lApps[aIndex];
      if IsShuttingDown then
        Exit;

      if (lApp = nil) or (lApp.Caption = '') then
        Exit;

      if lNeedAppUserModelID then
      begin
        try
          lApp.AppUserModelID;
        except
        end;
      end;
      if lNeedCmdParams then
      begin
        try
          lApp.CommandLineParams;
        except
        end;
      end;
    end);
  lPrefixPrefetchMs := lPhaseWatch.ElapsedMilliseconds;

  if not IsShuttingDown then
    LogStartupTiming(
      'DeepPrefix.ThreadDone',
      Format(
        'apps=%d appUserModelId=%s cmdParams=%s prefetch=%dms',
        [Length(lApps), BoolToStr(lNeedAppUserModelID, True), BoolToStr(lNeedCmdParams, True),
         lPrefixPrefetchMs]));
end;

procedure TAppsViewMainFrm.OnDeepPrefixLoadDone;
begin
  TInterlocked.Exchange(fDeepPrefixLoadBusy, 0);
  TInterlocked.Exchange(fDeepPrefixReady, 1);

  if IsShuttingDown then
    Exit;

  LogStartupTiming('DeepPrefix.Done');
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.StartDeepPrefixLoad;
begin
  if IsShuttingDown then
    Exit;

  if TInterlocked.CompareExchange(fDeepPrefixReady, 0, 0) <> 0 then
    Exit;

  if TInterlocked.CompareExchange(fDeepPrefixLoadBusy, 1, 0) <> 0 then
    Exit;

  fDeepPrefixLoadTask := SimpleAsyncCall(
    RunDeepPrefixLoad,
    'ActiveAppView.DeepPrefixLoad',
    OnDeepPrefixLoadDone);
end;

procedure TAppsViewMainFrm.OnStartupDataLoadDone;
begin
  TInterlocked.Exchange(fStartupDataLoadBusy, 0);
  if TInterlocked.CompareExchange(fStartupDataReady, 1, 0) <> 0 then
    Exit;

  TInterlocked.Exchange(fStartupSkipSharedRefreshOnce, 1);

  if IsShuttingDown then
    Exit;

  if TInterlocked.CompareExchange(fStartupProfileWarmupDoneLogged, 1, 0) = 0 then
    LogStartupTiming('Warmup.Done');

  tmrChatMonitor.Enabled := fChatMonitorConfiguredEnabled;
  StartDeepPrefixLoad;
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.StartStartupDataLoad;
begin
  if IsShuttingDown then
    Exit;

  if TInterlocked.CompareExchange(fStartupDataReady, 0, 0) <> 0 then
  begin
    QueueGuiRefresh;
    Exit;
  end;

  if TInterlocked.CompareExchange(fStartupDataLoadBusy, 1, 0) <> 0 then
    Exit;

  fStartupDataLoadTask := SimpleAsyncCall(
    RunStartupDataLoad,
    'ActiveAppView.StartupDataLoad',
    OnStartupDataLoadDone);
end;

procedure TAppsViewMainFrm.QueueGuiRefresh;
begin
  if IsShuttingDown then
    Exit;

  if TInterlocked.CompareExchange(fGuiRefreshQueued, 1, 0) <> 0 then
    Exit;

  TThread.Queue(nil,
    procedure
    begin
      TInterlocked.Exchange(fGuiRefreshQueued, 0);
      if IsShuttingDown then
        Exit;
      UpdateGui;
    end);
end;

function TAppsViewMainFrm.TryParseShortCutValue(const aValue: string; out aTargetPath: string;
  out aParams: string): boolean;
var
  lValue: string;
  lPos: integer;
begin
  aTargetPath := '';
  aParams := '';
  lValue := aValue.Trim;
  if lValue = '' then
    Exit(False);

  if StartsText('"', lValue) then
  begin
    lPos := PosEx('"', lValue, 2);
    if lPos > 1 then
    begin
      aTargetPath := Copy(lValue, 2, lPos - 2);
      aParams := Trim(Copy(lValue, lPos + 1, MaxInt));
    end
    else
      aTargetPath := lValue;
  end
  else
  begin
    lPos := PosEx(' ', lValue, 1);
    if lPos > 0 then
    begin
      aTargetPath := Copy(lValue, 1, lPos - 1);
      aParams := Trim(Copy(lValue, lPos + 1, MaxInt));
    end
    else
      aTargetPath := lValue;
  end;

  Result := aTargetPath <> '';
end;

procedure TAppsViewMainFrm.ActivateDesktopItem;
var
  lItem: TListBoxItemData;
  lPath: string;
begin
  if lbDesktop.ItemIndex < 0 then
    Exit;

  if not (lbDesktop.Items.Objects[lbDesktop.ItemIndex] is TListBoxItemData) then
    Exit;

  lItem := TListBoxItemData(lbDesktop.Items.Objects[lbDesktop.ItemIndex]);
  lPath := lItem.Value;
  if lPath = '' then
    Exit;

  if DirectoryExists(lPath) or FileExists(lPath) then
    ShellExecute(Handle, 'open', PChar(lPath), nil, nil, SW_SHOWNORMAL);
end;

procedure TAppsViewMainFrm.ActivateShortCutItem;
var
  lItem: TListBoxItemData;
  lTargetPath: string;
  lParams: string;
  lResult: HINST;
begin
  if lbShortCuts.ItemIndex < 0 then
    Exit;

  if not (lbShortCuts.Items.Objects[lbShortCuts.ItemIndex] is TListBoxItemData) then
    Exit;

  lItem := TListBoxItemData(lbShortCuts.Items.Objects[lbShortCuts.ItemIndex]);
  if not TryParseShortCutValue(lItem.Value, lTargetPath, lParams) then
    Exit;

  if StartsText('\\', lTargetPath) then
  begin
    lResult := ShellExecute(Handle, 'open', PChar(lTargetPath), PChar(lParams), nil, SW_SHOWNORMAL);
    if lResult <= 32 then
      MessageDlg(Format(rsShortCutTargetMissing, [lTargetPath]), mtWarning, [mbOK], 0);
    Exit;
  end;

  if DirectoryExists(lTargetPath) then
  begin
    ShellExecute(Handle, 'open', PChar(lTargetPath), nil, nil, SW_SHOWNORMAL);
    Exit;
  end;

  if FileExists(lTargetPath) then
  begin
    ShellExecute(Handle, 'open', PChar(lTargetPath), PChar(lParams), nil, SW_SHOWNORMAL);
    Exit;
  end;

  MessageDlg(Format(rsShortCutTargetMissing, [lTargetPath]), mtWarning, [mbOK], 0);
end;

procedure TAppsViewMainFrm.RestoreSelectedItem(lb: TListBox; const aCaption: string);
var
  lIndex: integer;
begin
  if lb.Items.Count = 0 then
  begin
    lb.ItemIndex := -1;
    Exit;
  end;

  if aCaption <> '' then
  begin
    lIndex := lb.Items.IndexOf(aCaption);
    if lIndex >= 0 then
    begin
      lb.ItemIndex := lIndex;
      Exit;
    end;
  end;

  if lb.ItemIndex < 0 then
    lb.ItemIndex := 0;
end;

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; app: TAppInfo; const aRules: TPrefixRuleArray;
  aAllowFileNameMatching: Boolean; aAllowDeepMetadata: Boolean);
var
  lRule: TPrefixRule;
begin
  for lRule in aRules do
  begin
    if ((lRule.CaptionMask <> '') and maxLogic.StrUtils.StringMatches(app.caption, lRule.CaptionMask, False))
      or (aAllowFileNameMatching and (lRule.FileNameMask <> '')
      and maxLogic.StrUtils.StringMatches(app.FileName, lRule.FileNameMask, False))
      or (aAllowDeepMetadata and (lRule.AppUserModelIDMask <> '')
      and maxLogic.StrUtils.StringMatches(app.AppUserModelID, lRule.AppUserModelIDMask, False))
      or (aAllowDeepMetadata and (lRule.CmdParamsMask <> '')
      and maxLogic.StrUtils.StringMatches(app.CommandLineParams, lRule.CmdParamsMask, False)) then
    begin
      if lRule.Prefix <> '' then
        s := lRule.Prefix + ' - ' + s;
      Exit;
    end;
  end;
end;

function TAppsViewMainFrm.ExcludeByMask(app: TAppInfo; const aMasks: TStringArray;
  aAllowFileNameMatching: Boolean): boolean;
var
  lMask: string;
begin
  Result := False;
  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(app.caption, lMask, False) then
      Exit(True);
  end;

  if not aAllowFileNameMatching then
    Exit(False);

  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(app.FileName, lMask, False) then
      Exit(True);
  end;
end;

procedure TAppsViewMainFrm.FormActivate(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  MarkFormFocused;
  if TInterlocked.CompareExchange(fStartupDataReady, 0, 0) = 0 then
    StartStartupDataLoad
  else
    QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.FormCreate(Sender: TObject);
var
  lIniFile: TMemIniFile;
begin
  fStartupProfileLog := TStringList.Create;
  fStartupProfileLogSync := TCriticalSection.Create;
  fStartupProfileLogFileName := CombinePath([GetInstallDir, 'startup-profile.log']);
  fStartupProfileStartTick := TStopwatch.GetTimeStamp;
  TInterlocked.Exchange(fStartupProfileAuxReadyLogged, 0);
  TInterlocked.Exchange(fStartupProfileDeepPrefixGuiLogged, 0);
  TInterlocked.Exchange(fStartupProfileFirstGuiLogged, 0);
  TInterlocked.Exchange(fStartupProfileFullMetadataGuiLogged, 0);
  TInterlocked.Exchange(fStartupProfileWarmupDoneLogged, 0);
  fStartupProfileLog.Add('----------------------------------------');
  fStartupProfileLog.Add(Format('Run started at %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now)]));
  LogStartupTiming('FormCreate.Start');

  fApps := TAppList.Create;
  fConfigCache := TConfigCache.Create(GetInstallDir);
  CreateWindowActionsPopupMenu;
  AddToAutoStart;
  Screen.OnActiveControlChange := ActiveControlChanged;
  labAppTitle.Height := labTemplateActiv.Height;
  labExplorerTitle.Height := labTemplateActiv.Height;
  labScriptsTitle.Height := labTemplateActiv.Height;
  labConsoleTitle.Height := labTemplateActiv.Height;
  labDesktopTitle.Height := labTemplateActiv.Height;
  labShortCutsTitle.Height := labTemplateActiv.Height;
  ActiveControlChanged(nil);
  fOrgAppOnActivate := application.OnActivate;
  application.OnActivate := AppOnActivate;

  gc(lIniFile, TMemIniFile.Create(CombinePath([GetInstallDir, cSettingsFileName]), TEncoding.Utf8, False));
  fChatMonitor := TChatMonitor.Create(lIniFile);
  fChatMonitor.UseConfigCache(fConfigCache);
  chkChatNotificationSound.Checked := lIniFile.ReadBool('ChatMonitor', 'SoundEnabled', True);
  fChatMonitorConfiguredEnabled := lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
  chkChatNotificationSound.Enabled := fChatMonitorConfiguredEnabled;
  fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;
  tmrChatMonitor.Interval := lIniFile.ReadInteger('ChatMonitor', 'CheckIntervalSeconds', 5) * 1000;
  tmrChatMonitor.Enabled := False;
  SetLength(fSharedAppsSnapshot, 0);
  SetLength(fChatMonitorSnapshot, 0);
  fSharedAppsSnapshotTick := 0;
  TInterlocked.Exchange(fDeepPrefixLoadBusy, 0);
  TInterlocked.Exchange(fDeepPrefixReady, 0);
  TInterlocked.Exchange(fStartupDataReady, 0);
  TInterlocked.Exchange(fStartupSkipSharedRefreshOnce, 0);
  TInterlocked.Exchange(fShuttingDown, 0);
  fShutdownToken := TCancelToken.Create;
  LogStartupTiming(
    'FormCreate.Done',
    Format('chatMonitorEnabled=%s chatSoundEnabled=%s',
      [BoolToStr(fChatMonitorConfiguredEnabled, True), BoolToStr(chkChatNotificationSound.Checked, True)]));
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
begin
  LogStartupTiming('FormDestroy.Start');
  TInterlocked.Exchange(fShuttingDown, 1);
  if Assigned(fShutdownToken) then
    fShutdownToken.Cancel;
  tmrChatMonitor.Enabled := False;
  TInterlocked.Exchange(fChatMonitorPending, 0);
  TInterlocked.Exchange(fAuxListRefreshPending, 0);
  application.OnActivate := fOrgAppOnActivate;
  Screen.OnActiveControlChange := nil;

  RequestAsyncStop(fAuxListRefresh);
  RequestAsyncStop(fChatMonitorTask);
  RequestAsyncStop(fDeepPrefixLoadTask);
  RequestAsyncStop(fStartupDataLoadTask);

  WaitAsyncWithShutdown(fAuxListRefresh, cShutdownTaskWaitTimeoutMs);
  WaitAsyncWithShutdown(fChatMonitorTask, cShutdownTaskWaitTimeoutMs);
  WaitAsyncWithShutdown(fDeepPrefixLoadTask, cShutdownTaskWaitTimeoutMs);
  WaitAsyncWithShutdown(fStartupDataLoadTask, cShutdownTaskWaitTimeoutMs);

  FreeAndNil(fPendingAuxSnapshot);
  fAuxListRefresh := nil;
  fChatMonitorTask := nil;
  fDeepPrefixLoadTask := nil;
  fStartupDataLoadTask := nil;
  fShutdownToken := nil;
  ClearListBoxItemData(lbDesktop);
  ClearListBoxItemData(lbShortCuts);
  FreeAndNil(fChatMonitor);
  FreeAndNil(fConfigCache);
  fApps.Free;
  LogStartupTiming('FormDestroy.Flush');
  FlushStartupProfileLog;
  FreeAndNil(fStartupProfileLog);
  FreeAndNil(fStartupProfileLogSync);
end;

procedure TAppsViewMainFrm.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_F4) and ((GetTickCount64 - fLastFormFocusTick) < cIgnoreF4AfterFocusMs) then
  begin
    Key := 0;
    Exit;
  end;

  if Key = VK_F5 then
    UpdateGui
  else if Key = vk_F1 then
    lbApps.SetFocus
  else if Key = vk_F2 then
    lbExplorer.SetFocus
  else if Key = vk_F3 then
    lbScripts.SetFocus
  else if Key = vk_F4 then
    lbConsole.SetFocus
  else if Key = vk_F6 then
    lbDesktop.SetFocus
  else if Key = vk_F7 then
    lbShortCuts.SetFocus
end;

procedure TAppsViewMainFrm.FormShow(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  LogStartupTiming('FormShow');
  StartAuxListsRefresh;
  StartStartupDataLoad;
  QueueGuiRefresh;
end;

function TAppsViewMainFrm.GetWnd(lb: TListBox): hwnd;
begin
  Result := 0;
  if lb.Items.Count <> 0 then
    if lb.ItemIndex <> -1 then
      Result := hwnd(lb.Items.Objects[lb.ItemIndex]);
end;

procedure TAppsViewMainFrm.lbAppsClick(Sender: TObject);
begin
  if Sender = lbApps then
    UpdateAppDetail;
end;

procedure TAppsViewMainFrm.lbAppsDblClick(Sender: TObject);
begin
  BringToFrontFocusedApp(Sender as TListBox);
end;

procedure TAppsViewMainFrm.lbAppsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    BringToFrontFocusedApp(Sender as TListBox)
  else if (Key = Ord('W')) and (ssCtrl in Shift) and ((Sender = lbApps) or (Sender = lbExplorer)) then
  begin
    CloseSelectedWindow(Sender as TListBox);
    Key := 0;
  end
  else if Sender = lbApps then
    UpdateAppDetail;
end;

procedure TAppsViewMainFrm.lbScriptsDblClick(Sender: TObject);
var
  i: Integer;
  fn: String;
begin
  i:= lbScripts.ItemIndex;
  if i = -1 then
    exit;
  fn := CombinePath([GetInstallDir, cScriptsFolderName, lbScripts.Items[i]]);
  if TFile.Exists(fn) then
    TThread.CreateAnonymousThread(
      procedure begin
        exec(fn);
      end).Start;

end;

procedure TAppsViewMainFrm.lbScriptsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    lbScriptsDblClick(sender);
end;

procedure TAppsViewMainFrm.lbDesktopDblClick(Sender: TObject);
begin
  ActivateDesktopItem;
end;

procedure TAppsViewMainFrm.lbDesktopKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    ActivateDesktopItem;
end;

procedure TAppsViewMainFrm.lbShortCutsDblClick(Sender: TObject);
begin
  ActivateShortCutItem;
end;

procedure TAppsViewMainFrm.lbShortCutsKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
    ActivateShortCutItem;
end;

procedure TAppsViewMainFrm.chkChatNotificationSoundClick(aSender: TObject);
var
  lIniFile: TMemIniFile;
begin
  if Assigned(fChatMonitor) then
    fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;

  gc(lIniFile, TMemIniFile.Create(CombinePath([GetInstallDir, cSettingsFileName]), TEncoding.Utf8, False));
  lIniFile.WriteBool('ChatMonitor', 'SoundEnabled', chkChatNotificationSound.Checked);
  lIniFile.UpdateFile;
end;

procedure TAppsViewMainFrm.MarkFormFocused;
begin
  fLastFormFocusTick := GetTickCount64;
end;

function TAppsViewMainFrm.GetStartupElapsedMs: Int64;
var
  lNowTick: Int64;
begin
  if fStartupProfileStartTick = 0 then
    Exit(0);

  lNowTick := TStopwatch.GetTimeStamp;
  Result := ((lNowTick - fStartupProfileStartTick) * 1000) div TStopwatch.Frequency;
end;

procedure TAppsViewMainFrm.FlushStartupProfileLog;
begin
  if (not Assigned(fStartupProfileLog)) or (not Assigned(fStartupProfileLogSync)) then
    Exit;

  fStartupProfileLogSync.Enter;
  try
    fStartupProfileLog.SaveToFile(fStartupProfileLogFileName, TEncoding.UTF8);
  finally
    fStartupProfileLogSync.Leave;
  end;
end;

procedure TAppsViewMainFrm.LogStartupTiming(const aPhase: string; const aDetails: string);
var
  lMessage: string;
begin
  if (fStartupProfileStartTick = 0) or (not Assigned(fStartupProfileLog))
    or (not Assigned(fStartupProfileLogSync)) then
    Exit;

  if aDetails = '' then
    lMessage := Format('ActiveAppView startup +%dms [%s]', [GetStartupElapsedMs, aPhase])
  else
    lMessage := Format('ActiveAppView startup +%dms [%s] %s', [GetStartupElapsedMs, aPhase, aDetails]);

  fStartupProfileLogSync.Enter;
  try
    fStartupProfileLog.Add(lMessage);
  finally
    fStartupProfileLogSync.Leave;
  end;
end;

function TAppsViewMainFrm.IsShuttingDown: Boolean;
begin
  Result := (TInterlocked.CompareExchange(fShuttingDown, 0, 0) <> 0);
end;

function TAppsViewMainFrm.IsStartupDataReady: Boolean;
begin
  Result := (TInterlocked.CompareExchange(fStartupDataReady, 0, 0) <> 0);
end;

function TAppsViewMainFrm.IsDeepPrefixReady: Boolean;
begin
  Result := (TInterlocked.CompareExchange(fDeepPrefixReady, 0, 0) <> 0);
end;

procedure TAppsViewMainFrm.RequestAsyncStop(const aAsync: iAsync);
var
  lAsyncIntern: iAsyncIntern;
  lThreadData: iThreadData;
begin
  if not Assigned(aAsync) then
    Exit;

  if not Supports(aAsync, iAsyncIntern, lAsyncIntern) then
    Exit;

  lThreadData := lAsyncIntern.GetThreadData;
  if not Assigned(lThreadData) then
    Exit;

  lThreadData.KeepAlive := False;
  lThreadData.SetThreadToTerminated;
  lThreadData.WakeUpSignal.setSignaled;
  lThreadData.StartSignal.setSignaled;
end;

procedure TAppsViewMainFrm.WaitAsyncWithShutdown(const aAsync: iAsync; const aTimeoutMs: Cardinal);
var
  lAsyncIntern: iAsyncIntern;
  lThreadData: iThreadData;
  lThread: TThread;
begin
  if not Assigned(aAsync) then
    Exit;

  RequestAsyncStop(aAsync);
  if TWaiter.WaitFor([aAsync], aTimeoutMs, True) then
    Exit;

  if not Supports(aAsync, iAsyncIntern, lAsyncIntern) then
    Exit;

  lThreadData := lAsyncIntern.GetThreadData;
  if not Assigned(lThreadData) then
    Exit;

  lThread := lThreadData.Thread;
  if not Assigned(lThread) then
    Exit;

  if WaitForSingleObject(lThread.Handle, 0) = WAIT_OBJECT_0 then
    Exit;

  LogStartupTiming('Shutdown.TerminateThread', Format('threadId=%d', [lThread.ThreadID]));
  // Last-resort shutdown path: avoid zombie instances when a worker is stuck in blocking OS calls.
  TerminateThread(lThread.Handle, 1);
end;

procedure TAppsViewMainFrm.EnsureSharedAppsSnapshotFresh(const aMaxAgeMs: UInt64);
var
  lNowTick: UInt64;
begin
  if IsShuttingDown then
    Exit;

  lNowTick := GetTickCount64;
  if (fSharedAppsSnapshotTick <> 0) and (aMaxAgeMs <> 0)
    and ((lNowTick - fSharedAppsSnapshotTick) < aMaxAgeMs) then
    Exit;

  fApps.Update;
  RebuildSharedAppsSnapshot;
end;

procedure TAppsViewMainFrm.RebuildSharedAppsSnapshot;
var
  lIndex: Integer;
begin
  SetLength(fSharedAppsSnapshot, fApps.Count);
  for lIndex := 0 to fApps.Count - 1 do
  begin
    fSharedAppsSnapshot[lIndex].Wnd := fApps[lIndex].Wnd;
    fSharedAppsSnapshot[lIndex].Caption := fApps[lIndex].Caption;
  end;
  fSharedAppsSnapshotTick := GetTickCount64;
end;

procedure TAppsViewMainFrm.RunChatMonitorSnapshot;
begin
  if IsShuttingDown then
    Exit;

  if Assigned(fChatMonitor) then
    fChatMonitor.ProcessSnapshot(fChatMonitorSnapshot);
end;

procedure TAppsViewMainFrm.OnChatMonitorDone;
begin
  SetLength(fChatMonitorSnapshot, 0);
  TInterlocked.Exchange(fChatMonitorBusy, 0);
  if (TInterlocked.Exchange(fChatMonitorPending, 0) = 1) and (not IsShuttingDown) then
    StartChatMonitorProcessing;
end;

procedure TAppsViewMainFrm.StartChatMonitorProcessing;
begin
  if IsShuttingDown then
    Exit;

  if not Assigned(fChatMonitor) then
    Exit;

  if TInterlocked.CompareExchange(fChatMonitorBusy, 1, 0) <> 0 then
  begin
    TInterlocked.Exchange(fChatMonitorPending, 1);
    Exit;
  end;

  EnsureSharedAppsSnapshotFresh(900);
  fChatMonitorSnapshot := Copy(fSharedAppsSnapshot);
  fChatMonitorTask := SimpleAsyncCall(RunChatMonitorSnapshot, 'ActiveAppView.ChatMonitor', OnChatMonitorDone);
end;

procedure TAppsViewMainFrm.RestoreItemIndex(lb: TListBox; wnd: hwnd;
  oldItemIndex: integer; const aOldItemCaption: string);
var
  lIndex: integer;
  X: integer;
begin
  if lb.Items.Count = 0 then
  begin
    lb.ItemIndex := -1;
    exit;
  end;
  for X := 0 to lb.Items.Count - 1 do
    if wnd = hwnd(lb.Items.Objects[X]) then
    begin
      lb.ItemIndex := X;
      exit;
    end;

  if (aOldItemCaption <> '') and lb.Sorted then
  begin
    lIndex := FindSortedCaptionIndex(lb.Items, aOldItemCaption);
    if lIndex <> -1 then
    begin
      lb.ItemIndex := lIndex;
      exit;
    end;
  end;

  if (oldItemIndex >= 0) and (oldItemIndex < lb.Items.Count) then
    lb.ItemIndex := oldItemIndex
  else if oldItemIndex >= lb.Items.Count then
    lb.ItemIndex := lb.Items.Count - 1
  else if oldItemIndex < 0 then
    lb.ItemIndex := 0;

end;

function RunMainFormSelfTests(const aArg: string): Integer;
var
  lApps: TArray<TAppInfo>;
  lCancelToken: iCancelToken;
  lItems: TStringList;
  lResultIndex: Integer;
begin
  Result := -1;
  if SameText(aArg, cRestoreItemIndexSelfTestArg) then
  begin
    Result := 0;
    lItems := TStringList.Create;
    try
      lItems.Sorted := True;
      lItems.Add('A');
      lItems.Add('C');
      lResultIndex := FindSortedCaptionIndex(lItems, 'Z');
      if lResultIndex <> -1 then
      begin
        Writeln(Format('SELFTEST FAILED: expected missing caption index=-1, got %d', [lResultIndex]));
        Result := 1;
      end;
    finally
      lItems.Free;
    end;
    Exit;
  end;

  if not SameText(aArg, cWarmupPrefetchSelfTestArg) then
    if not SameText(aArg, cWarmupShutdownCheckSelfTestArg) then
      Exit;

  if SameText(aArg, cWarmupShutdownCheckSelfTestArg) then
  begin
    Result := 0;
    lCancelToken := TCancelToken.Create;
    lCancelToken.Cancel;
    SetLength(lApps, 1);
    try
      PrefetchAppFileNamesInParallel(
        lApps,
        lCancelToken,
        procedure(const aApp: TAppInfo)
        begin
          raise Exception.Create('canceled token should skip worker execution');
        end);
    except
      on lException: Exception do
      begin
        Writeln(Format('SELFTEST FAILED: startup warmup shutdown-check raised %s: %s',
          [lException.ClassName, lException.Message]));
        Result := 1;
      end;
    end;
    lCancelToken := nil;
    Exit;
  end;

  Result := 0;
  SetLength(lApps, 1);
  try
    PrefetchAppFileNamesInParallel(
      lApps,
      nil,
      procedure(const aApp: TAppInfo)
      begin
        raise Exception.Create('injected prefetch failure');
      end);
  except
    on lException: Exception do
    begin
      Writeln(Format('SELFTEST FAILED: startup warmup prefetch raised %s: %s',
        [lException.ClassName, lException.Message]));
      Result := 1;
    end;
  end;
end;

procedure TAppsViewMainFrm.tmrChatMonitorTimer(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  StartChatMonitorProcessing;
end;

procedure TAppsViewMainFrm.UpdateAppDetail(const aAllowExtendedMetadata: Boolean);
var
  app: TAppInfo;
begin
  if not fApps.TryGetApp(GetWnd(lbApps), app) then
    pnlAppDetails.Visible := False
  else
  begin
    pnlAppDetails.Visible := True;
    edAppCaption.Text := app.caption;
    edPid.Text := app.PID.ToString;
    if aAllowExtendedMetadata then
    begin
      imgAppScreenshot.Picture.Graphic := app.Icon;
      edAppFileName.Text := app.FileName;
      edCommandLineParams.Text := app.CommandLineParams;
      edRelaunchCommand.Text:= app.RelaunchCommand;
      edAppUserModelID.Text:= app.AppUserModelID;
    end
    else
    begin
      edAppFileName.Text := '';
      edCommandLineParams.Text := '';
      edRelaunchCommand.Text := '';
      edAppUserModelID.Text := '';
    end;
  end;

end;

procedure TAppsViewMainFrm.UpdateGui;
var
  lApp: TAppInfo;
  lAppsFocusedCaption: string;
  lAppsWnd: hWnd;
  lConsoleFocusedCaption: string;
  lConsoleWnd: hWnd;
  lExcludeMasks: TStringArray;
  lExplorers: TList<TAppInfo>;
  lExplorerFocusedCaption: string;
  lExplorerWnd: hWnd;
  lOldAppsIndex: Integer;
  lOldConsoleIndex: Integer;
  lOldExplorerIndex: Integer;
  lDeepPrefixReady: Boolean;
  lPrefixRules: TPrefixRuleArray;
  lSkipSharedRefreshOnce: Boolean;
  lStartupDataReady: Boolean;
  lTerminalPatterns: TStringArray;
  lTitle: string;
  lIsExplorer: Boolean;
  lIsTerminal: Boolean;
  lIndex: Integer;
begin
  if IsShuttingDown then
    Exit;

  lStartupDataReady := IsStartupDataReady;
  if not lStartupDataReady then
  begin
    StartStartupDataLoad;
    if TInterlocked.CompareExchange(fStartupProfileFirstGuiLogged, 0, 0) <> 0 then
      Exit;
  end;
  lDeepPrefixReady := IsDeepPrefixReady;

  lSkipSharedRefreshOnce := lStartupDataReady
    and (TInterlocked.CompareExchange(fStartupSkipSharedRefreshOnce, 0, 1) = 1);
  if not lSkipSharedRefreshOnce then
    EnsureSharedAppsSnapshotFresh(250);

  lExcludeMasks := fConfigCache.GetHideMasks(cHideMaskFileName);
  lPrefixRules := fConfigCache.GetPrefixRules(cPrefixMaskFileName);
  lTerminalPatterns := fConfigCache.GetTerminalPatterns(cTerminalPatternsFileName);

  gc(lExplorers, TList<TAppInfo>.Create);

  lOldAppsIndex := lbApps.ItemIndex;
  lAppsFocusedCaption := '';
  if lOldAppsIndex <> -1 then
    lAppsFocusedCaption := lbApps.Items[lOldAppsIndex];
  lAppsWnd := GetWnd(lbApps);

  lOldConsoleIndex := lbConsole.ItemIndex;
  lConsoleFocusedCaption := '';
  if lOldConsoleIndex <> -1 then
    lConsoleFocusedCaption := lbConsole.Items[lOldConsoleIndex];
  lConsoleWnd := GetWnd(lbConsole);

  lbApps.Items.BeginUpdate;
  lbConsole.Items.BeginUpdate;
  try
    lbApps.Items.Clear;
    lbConsole.Items.Clear;
    for lIndex := 0 to fApps.Count - 1 do
    begin
      lApp := fApps[lIndex];

      if (lApp.wnd = application.Handle)
        or (lApp.wnd = self.Handle) then
        Continue;

      if lApp.caption = '' then
        Continue;
      if ExcludeByMask(lApp, lExcludeMasks, lStartupDataReady) then
        Continue;

      lIsExplorer := False;
      lIsTerminal := False;
      if lStartupDataReady then
      begin
        lIsExplorer := SameText('explorer.exe', ExtractFileName(lApp.FileName));
        if not lIsExplorer then
          lIsTerminal := IsTerminalApp(lApp.FileName, lTerminalPatterns);
      end;

      if lIsExplorer then
      begin
        lExplorers.Add(lApp);
        Continue;
      end;

      if lStartupDataReady then
        lTitle := Trim(lApp.DisplayCaption)
      else
        lTitle := Trim(lApp.Caption);

      if lIsTerminal then
      begin
        CheckPrefixRule(lTitle, lApp, lPrefixRules, lStartupDataReady, False);
        lbConsole.Items.AddObject(lTitle, TObject(lApp.wnd));
      end
      else
      begin
        CheckPrefixRule(lTitle, lApp, lPrefixRules, lStartupDataReady, lDeepPrefixReady);
        lbApps.Items.AddObject(lTitle, TObject(lApp.wnd));
      end;
    end;
  finally
    lbConsole.Items.EndUpdate;
    lbApps.Items.EndUpdate;
  end;
  RestoreItemIndex(lbApps, lAppsWnd, lOldAppsIndex, lAppsFocusedCaption);
  RestoreItemIndex(lbConsole, lConsoleWnd, lOldConsoleIndex, lConsoleFocusedCaption);
  UpdateAppDetail(False);

  lExplorerWnd := GetWnd(lbExplorer);
  lOldExplorerIndex := lbExplorer.ItemIndex;
  lExplorerFocusedCaption := '';
  if lOldExplorerIndex <> -1 then
    lExplorerFocusedCaption := lbExplorer.Items[lOldExplorerIndex];
  lbExplorer.Items.BeginUpdate;
  try
    lbExplorer.Items.Clear;
    for lApp in lExplorers do
      lbExplorer.Items.addObject(lApp.caption, TObject(lApp.wnd));
  finally
    lbExplorer.Items.EndUpdate;
  end;
  RestoreItemIndex(lbExplorer, lExplorerWnd, lOldExplorerIndex, lExplorerFocusedCaption);

  if TInterlocked.CompareExchange(fStartupProfileFirstGuiLogged, 1, 0) = 0 then
    LogStartupTiming(
      'Gui.FirstPopulate',
      Format(
        'startupDataReady=%s skipRefresh=%s apps=%d console=%d explorer=%d',
        [BoolToStr(lStartupDataReady, True), BoolToStr(lSkipSharedRefreshOnce, True),
         lbApps.Items.Count, lbConsole.Items.Count, lbExplorer.Items.Count]));

  if lStartupDataReady and (TInterlocked.CompareExchange(fStartupProfileFullMetadataGuiLogged, 1, 0) = 0) then
    LogStartupTiming(
      'Gui.FullMetadata',
      Format(
        'skipRefresh=%s apps=%d console=%d explorer=%d',
        [BoolToStr(lSkipSharedRefreshOnce, True), lbApps.Items.Count, lbConsole.Items.Count, lbExplorer.Items.Count]));

  if lDeepPrefixReady and (TInterlocked.CompareExchange(fStartupProfileDeepPrefixGuiLogged, 1, 0) = 0) then
    LogStartupTiming(
      'Gui.DeepPrefixReady',
      Format(
        'apps=%d console=%d explorer=%d',
        [lbApps.Items.Count, lbConsole.Items.Count, lbExplorer.Items.Count]));

  StartAuxListsRefresh;
end;

end.


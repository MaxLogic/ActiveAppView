unit ActiveAppViewMainForm;

interface

uses
  System.Classes, System.Generics.Collections, System.SyncObjs, System.SysUtils, System.Variants,
  Winapi.Messages, Winapi.Windows,
  Vcl.Buttons, Vcl.ComCtrls, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms,
  Vcl.Graphics, Vcl.Menus, Vcl.StdCtrls,
  CancelToken, maxAsync,
  ActiveAppView.CaptionOverrideState, ActiveAppView.ChatMonitor, ActiveAppView.ConfigCache,
  ActiveAppView.FocusSound, ActiveAppView.MachineOverview.Commands, ActiveAppView.MachineOverview.HelpForm,
  ActiveAppView.MachineOverview.History, ActiveAppView.MachineOverview.HistoryForm,
  ActiveAppView.MachineOverview.Layout,
  ActiveAppView.MachineOverview.Service,
  ActiveAppView.MachineOverview.Settings, ActiveAppView.MachineOverview.Types,
  ActiveAppView.MachineOverview.View,
  ActiveAppViewCore, ActiveAppView.RenameJournal, ActiveAppView.WindowSnapshots;

type
  TWindowActionTarget = record
    DisplayCaption: string;
    ProcessId: Cardinal;
    Wnd: hWnd;
  end;

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
    splMachineOverview: TSplitter;
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
    pnlMachineOverview: TPanel;
    labMachineOverviewTitle: TStaticText;
    lvMachineOverview: TListView;
    pnlMachineOverviewButtons: TPanel;
    btnMachineOverviewFreeze: TButton;
    btnMachineOverviewFullView: TButton;
    btnMachineOverviewHelp: TButton;
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
    procedure FormResize(Sender: TObject);
    procedure btnMachineOverviewFreezeClick(aSender: TObject);
    procedure btnMachineOverviewFullViewClick(aSender: TObject);
    procedure btnMachineOverviewHelpClick(aSender: TObject);
  private

    fDisplayedDetail: TWindowSnapshot;
    fPendingCopy: TWindowSnapshot;
    fPendingClipboardSequence: DWORD;
    fWindowService: TWindowSnapshotService;
    fWindowBatch: TWindowSnapshotBatch;
    fAuxListRefresh: iAsync;
    fAuxListRefreshBusy: Integer;
    fAuxListRefreshPending: Integer;
    fChatMonitorConfiguredEnabled: Boolean;
    fChatMonitorBusy: Integer;
    fChatMonitorIntervalMs: Cardinal;
    fChatMonitorPending: Integer;
    fChatMonitorTask: iAsync;
    fConfigCache: TConfigCache;
    fFocusSoundFileName: string;
    fFocusSoundPlayer: TProc<string>;
    fOrgAppOnActivate: TNotifyEvent;
    fChatMonitor: TChatMonitor;
    fGuiRefreshQueued: Integer;
    fLastFormFocusTick: UInt64;
    fLastChatMonitorTick: UInt64;
    fLastWindowTitlePollingTick: UInt64;
    fMachineOverviewEnabled: Boolean;
    fMachineOverviewController: TMachineOverviewDisplayController;
    fMachineOverviewDisplayRefreshIntervalMs: Cardinal;
    fMachineOverviewHistoryDatabaseFileName: string;
    fMachineOverviewLayout: TMachineOverviewLayoutController;
    fLastMachineOverviewPublishedSequence: UInt64;
    fLastMachineOverviewRefreshTick: UInt64;
    fMachineOverviewService: IMachineOverviewService;
    fMachineOverviewView: IMachineOverviewView;
    fPendingAuxSnapshot: TObject;
    fChatMonitorSnapshot: TArray<TChatAppSnapshot>;
    fSharedAppsSnapshot: TArray<TChatAppSnapshot>;
    fSharedAppsSnapshotTick: UInt64;
    fStartupDataReady: Integer;
    fStartupProfileAuxReadyLogged: Integer;
    fStartupProfileFullMetadataGuiLogged: Integer;
    fStartupProfileDeepPrefixGuiLogged: Integer;
    fStartupProfileLog: TStringList;
    fStartupProfileLogFileName: string;
    fStartupProfileLogSync: TCriticalSection;
    fStartupProfileStartTick: Int64;
    fSlowUiSampleCount: Integer;
    fStartupProfileWarmupDoneLogged: Integer;
    fWindowTitlePollingIntervalMs: Cardinal;
    fWindowActionSourceListBox: TListBox;
    fWindowActionTarget: TWindowActionTarget;
    fWindowActionsPopupMenu: TPopupMenu;
    fCloseWindowMenuItem: TMenuItem;
    fCopyFullExeCommandLineMenuItem: TMenuItem;
    fCopyFullExeFileNameMenuItem: TMenuItem;
    fCopyHwndMenuItem: TMenuItem;
    fCopyPidMenuItem: TMenuItem;
    fRenameWindowMenuItem: TMenuItem;
    fRenameJournalConfig: TRenameJournalConfig;
    fRenameJournalWriter: TRenameJournalWriter;
    fTerminateWindowMenuItem: TMenuItem;
    fWindowActionClipboardWriter: TProc<string>;
    fWindowCaptionOverrideRecords: TDictionary<string, TCaptionOverrideRecord>;
    fWindowCaptionOverrides: TDictionary<string, string>;
    fSuppressNextReturnListBox: TListBox;
    fSuppressNextReturnUntilTick: UInt64;
    fShutdownToken: iCancelToken;
    fShuttingDown: Integer;
    procedure WMWindowRefresh(var aMessage: TMessage); message cWindowRefreshMessage;
    procedure WMWindowSnapshot(var aMessage: TMessage); message cWindowSnapshotMessage;
    procedure ResumeChatMonitorAfterSnapshot;
    function TryGetWindowSnapshot(const aWnd: HWND; out aWindow: TWindowSnapshot): Boolean;
    procedure AppOnActivate(Sender: TObject);
    procedure PlayConfiguredFocusSound;
    function ApplyExpiredWindowCaptionOverrides: Boolean;
    procedure ApplyLoadedWindowCaptionOverrideState;
    function BuildWindowCaptionOverrideIdentity(const aWnd: hWnd;
      const aProcessId: Cardinal): TCaptionOverrideIdentity;
    function BuildWindowCaptionOverrideState: TCaptionOverrideState;
    procedure ApplyAuxListsSnapshot(aSnapshotObject: TObject);
    procedure ApplyDesktopSnapshot(const aItems: TNamedValueArray);
    procedure ApplyScriptsSnapshot(const aScripts: TStringArray);
    procedure ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
    function BuildAuxListsSnapshot: TObject;
    procedure MarkFormFocused;
    procedure CopyMachineOverviewDiagnostics;
    procedure CopyMachineOverviewSelectedRow;
    function HandleMachineOverviewCommand(
      const aCommand: TMachineOverviewCommand): Boolean;
    procedure OpenMachineOverviewIncidentHistory;
    procedure RefreshMachineOverview;
    procedure SaveMachineOverviewLayout;
    procedure SetMachineOverviewFullView(const aValue: Boolean);
    procedure SetMachineOverviewFrozen(const aValue: Boolean);
    procedure OnAuxListsRefreshDone;
    procedure OnChatMonitorDone;
    procedure QueueGuiRefresh;
    procedure RebuildSharedAppsSnapshot;
    procedure RefreshConsoleList;
    procedure RunAuxListsRefresh;
    procedure RunChatMonitorSnapshot;
    procedure StartAuxListsRefresh;
    procedure StartChatMonitorProcessing;
    procedure StartStartupDataLoad;
    procedure FlushStartupProfileLog;
    function GetStartupElapsedMs: Int64;
    function IsStartupDataReady: Boolean;
    function IsShuttingDown: Boolean;
    procedure LogStartupTiming(const aPhase: string; const aDetails: string = '');
    procedure RecordSlowUiOperation(const aOperation: string; const aElapsedMs: Double);
    procedure RequestAsyncStop(const aAsync: iAsync);
    procedure WaitAsyncWithShutdown(const aAsync: iAsync; const aTimeoutMs: Cardinal);
    procedure UpdateGui;
    procedure ApplyProportionalColumnWidths;
    procedure ApplyWindowCaptionRename(const aWnd: hWnd;
      const aProcessId: Cardinal; const aCaption: string);
    procedure ApplyWindowCaptionReset(const aWnd: hWnd;
      const aProcessId: Cardinal);
    function CaptureWindowActionTarget(const aListBox: TListBox): Boolean;
    procedure ClearWindowActionTarget;
    function ColumnLayoutAvailableWidth: Integer;
    function ConsumeWindowActionTarget(out aListBox: TListBox;
      out aTarget: TWindowActionTarget): Boolean;
    procedure CloseWindowTarget(const aTarget: TWindowActionTarget);
    procedure CopyTextToWindowActionClipboard(const aText: string);
    function ControlLayoutWidth(const aControl: TControl): Integer;
    procedure CloseSelectedWindow(const aListBox: TListBox);
    procedure CreateWindowActionsPopupMenu;
    function GetPopupSourceListBox: TListBox;
    function GetSelectedWindowInfo(const aListBox: TListBox; out aWnd: hWnd;
      out aProcessId: Cardinal): Boolean;
    function IsCaptionOverrideListBox(const aListBox: TListBox): Boolean;
    function IsProcessActive(const aProcessId: Cardinal): Boolean;
    procedure JournalWindowCaptionOverride(
      const aEvent: TCaptionOverrideLifecycleEvent);
    function PrepareWindowActionTargetForPopup(
      const aListBox: TListBox): Boolean;
    function PruneWindowCaptionOverrides: Boolean;
    procedure RemoveStaleWindowCaptionOverrideRecords;
    procedure RestoreFocusAfterWindowCaptionDialog(const aListBox: TListBox);
    procedure SaveWindowCaptionOverrides;
    procedure WindowActionListBoxContextPopup(aSender: TObject; aMousePos: TPoint; var aHandled: Boolean);
    function ShouldConsumeSuppressedReturnKey(const aSender: TObject; const aKey: Word): Boolean;
    procedure SuppressNextReturnKey(const aListBox: TListBox);
    procedure QuickValidateListBoxProcesses(const aListBox: TListBox);
    procedure RemoveWindowFromSnapshots(const aWnd: hWnd);
    procedure RemoveWindowFromListBox(const aListBox: TListBox; const aWnd: hWnd);
    procedure RemoveWindowFromUiAndCache(const aWnd: hWnd);
    procedure SelectListBoxItemIndex(const aListBox: TListBox; const aItemIndex: Integer);
    procedure ScheduleWindowActionCleanup(const aWnd: hWnd; const aProcessId: Cardinal);
    procedure TerminateWindowTarget(const aTarget: TWindowActionTarget);
    procedure WindowActionsPopupMenuPopup(aSender: TObject);
    procedure WindowCloseMenuItemClick(aSender: TObject);
    procedure WindowCopyMenuItemClick(aSender: TObject);
    procedure TryPublishPendingWindowCopy;
    procedure WindowRenameMenuItemClick(aSender: TObject);
    procedure WindowTerminateMenuItemClick(aSender: TObject);

    procedure BringToFrontFocusedApp(lb: TListBox);
    procedure UpdateAppDetail(const aAllowExtendedMetadata: Boolean = True);
    procedure CheckPrefixRule(var s: string; const aApp: TWindowSnapshot; const aRules: TPrefixRuleArray;
      aAllowFileNameMatching: Boolean; aAllowDeepMetadata: Boolean);
    function ExcludeByMask(const aApp: TWindowSnapshot; const aMasks: TStringArray;
      aAllowFileNameMatching: Boolean): boolean;
    procedure RestoreItemIndex(lb: TListBox; wnd: hwnd; oldItemIndex: integer; const aOldItemCaption: string);
    function GetWnd(lb: TListBox): hwnd;
    procedure ActiveControlChanged(Sender: TObject);
    procedure ClearListBoxItemData(lb: TListBox);
    procedure UpdateTitlePrefix(st: TStaticText; const aPrefix: string; aEnabled: boolean);
    function IsTerminalApp(const aFileName: string; const aPatterns: TStringArray): boolean;
    function TryGetKnownFolderPath(const aFolderId: TGUID; out aPath: string): boolean;
    procedure AddDesktopItemsFromFolder(const aFolder: string; var aItems: TNamedValueArray);
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
  System.DateUtils, System.Diagnostics, System.IniFiles, System.IOUtils, System.StrUtils, System.Threading,
  Winapi.ActiveX, Winapi.KnownFolders, Winapi.MMSystem, Winapi.ShellAPI, Winapi.ShlObj,
  Vcl.Clipbrd,
  AutoFree, maxCallMeLater, maxLogic.AutoStart, maxLogic.IOUtils, maxLogic.StrUtils, maxLogic.Windows.Desktop,
  MaxLogic.Windows.Identity,
  ActiveAppView.Launcher;

{$R *.dfm}

type
  TObservedListBox = class(TListBox)
  public
    MutationCount: Integer;
    procedure WndProc(var aMessage: TMessage); override;
  end;

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
  TDeepPrefixPrefetchProc = reference to procedure(const aApp: TAppInfo;
    const aNeedAppUserModelID: Boolean; const aNeedCmdParams: Boolean);

const
  cShortCutsFileName = 'ShortCuts.txt';
  cWindowCaptionOverridesFileName = 'WindowCaptionOverrides.ini';
  cWindowCaptionOverridesMetadataSectionName = 'Metadata';
  cWindowCaptionOverridesSectionName = 'Overrides';
  cWindowCaptionOverridesBootIdKey = 'BootId';
  cScriptsFolderName = 'Scripts';
  cScriptsIgnoreFileName = '.ignore';
  cHideMaskFileName = 'HideMask.txt';
  cPrefixMaskFileName = 'PrefixMask.txt';
  cSettingsFileName = 'settings.ini';
  cChatMonitorSectionName = 'ChatMonitor';
  cCheckIntervalSecondsKey = 'CheckIntervalSeconds';
  cWindowTitlePollingSectionName = 'WindowTitlePolling';
  cWindowTitlePollingIntervalSecondsKey = 'RefreshIntervalSeconds';
  cDefaultIntervalSeconds = 5;
  cRestoreItemIndexSelfTestArg = '--self-test-restore-item-index';
  cResizeColumnWidthsSelfTestArg = '--self-test-resize-column-widths';
  cShortCutValueParsingSelfTestArg = '--self-test-shortcut-value-parsing';
  cWindowCaptionOverridesSelfTestArg = '--self-test-window-caption-overrides';
  cConsoleTitleSortSelfTestArg = '--self-test-console-title-sort';
  cConsolePollAppPurgeSelfTestArg = '--self-test-console-poll-app-purge';
  cFocusSoundSelfTestArg = '--self-test-focus-sound';
  cWindowActionCopySelfTestArg = '--self-test-window-action-copy';
  cWindowActionProbeSelfTestArg = '--self-test-window-action-probe';
  cWindowTitlePollingSelfTestArg = '--self-test-window-title-polling';
  cScriptsIgnoreSelfTestArg = '--self-test-scripts-ignore';
  cPrefixRuleAppUserModelIDPrecedenceSelfTestArg = '--self-test-prefix-rule-aumid-precedence';
  cPrefixRuleAppUserModelIDNoCmdFallbackSelfTestArg = '--self-test-prefix-rule-aumid-no-cmd-fallback';
  cPrefixRuleSinglePrefixSelfTestArg = '--self-test-prefix-rule-single-prefix';
  cWarmupPrefetchSelfTestArg = '--self-test-startup-warmup-prefetch';
  cWarmupShutdownCheckSelfTestArg = '--self-test-startup-warmup-shutdown-check';
  cAppsColumnDesignWidth = 506;
  cExplorerColumnDesignWidth = 500;
  cScriptsColumnDesignWidth = 403;
  cConsoleColumnDesignWidth = 350;
  cDesktopColumnDesignWidth = 350;
  cShortCutsColumnDesignWidth = 350;
  cTotalDesignColumnWidth = cAppsColumnDesignWidth + cExplorerColumnDesignWidth + cScriptsColumnDesignWidth +
    cConsoleColumnDesignWidth + cDesktopColumnDesignWidth + cShortCutsColumnDesignWidth;
  cIgnoreF4AfterFocusMs = 200;
  cShutdownTaskWaitTimeoutMs = 10000;
  cWindowActionProbeIntervalMs = 300;
  cWindowActionProbeMaxDurationMs = 15000;
  cWindowActionCopyExecutableFileNameTag = 1;
  cWindowActionCopyCommandLineTag = 2;
  cWindowActionCopyProcessIdTag = 3;
  cWindowActionCopyWindowHandleTag = 4;
  cSuppressReturnKeyAfterDialogMs = 1000;

resourcestring
  rsDialogCancel = 'Cancel';
  rsDialogOk = 'OK';
  rsLaunchFailed = 'Failed to launch item: %s';
  rsMachineOverviewFreeze = 'Freeze display (Ctrl+E)';
  rsMachineOverviewFullView = 'Full View (Shift+F8)';
  rsMachineOverviewResume = 'Resume display (Ctrl+E)';
  rsMachineOverviewRestoreView = 'Restore View (Shift+F8)';
  rsWindowActionClose = 'Close';
  rsWindowActionCopyCommandLine = 'Copy full EXE filename including command line switches';
  rsWindowActionCopyExecutableFileName = 'Copy full EXE filename';
  rsWindowActionCopyHwnd = 'Copy HWND';
  rsWindowActionCopyPid = 'Copy PID';
  rsWindowActionRename = 'Rename';
  rsWindowActionReset = 'Reset';
  rsWindowActionTerminate = 'Terminate';
  rsWindowRenamePrompt = 'New caption';
  rsShortCutTargetMissing = 'ShortCut target not found: %s';

type
  TCaptionOverrideDialogResult = (codCancel, codRename, codReset);
  TCaptionOverrideDialogOutcome = record
    Caption: string;
    DialogResult: TCaptionOverrideDialogResult;
  end;
  TCaptionOverrideDialogRunner = function(aOwner: TComponent; const aCaption: string;
    out aNewCaption: string): TCaptionOverrideDialogResult;
  TWindowCaptionOverrideIsAliveFunc = reference to function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean;
  TWindowCaptionDialogApplyResult = (wcdarNone, wcdarRenamed, wcdarReset, wcdarStale);

function BuildWindowCaptionOverrideKey(const aWnd: hWnd; const aProcessId: Cardinal): string;
begin
  Result := UIntToStr(aProcessId) + ':' + UIntToStr(NativeUInt(aWnd));
end;

function ApplyWindowCaptionDialogOutcome(const aOverrides: TDictionary<string, string>;
  const aWnd: hWnd; const aProcessId: Cardinal; const aOutcome: TCaptionOverrideDialogOutcome;
  const aIsCurrent: TWindowCaptionOverrideIsAliveFunc): TWindowCaptionDialogApplyResult;
var
  lKey: string;
begin
  Result := wcdarNone;
  lKey := BuildWindowCaptionOverrideKey(aWnd, aProcessId);
  case aOutcome.DialogResult of
    codRename:
    begin
      if (not Assigned(aIsCurrent)) or (not aIsCurrent(aWnd, aProcessId)) then
        Exit(wcdarStale);
      aOverrides.AddOrSetValue(lKey, aOutcome.Caption);
      Result := wcdarRenamed;
    end;
    codReset:
    begin
      if (not Assigned(aIsCurrent)) or (not aIsCurrent(aWnd, aProcessId)) then
        Exit(wcdarStale);
      aOverrides.Remove(lKey);
      Result := wcdarReset;
    end;
  end;
end;

function BuildRenameCaptionOverrideTransition(
  const aIdentity: TCaptionOverrideIdentity; const aCaption: string;
  const aOccurredAt: Int64; out aRecord: TCaptionOverrideRecord;
  out aEvent: TCaptionOverrideLifecycleEvent): Boolean;
begin
  aRecord := Default(TCaptionOverrideRecord);
  aEvent := Default(TCaptionOverrideLifecycleEvent);
  Result := (Trim(aCaption) <> '') and (aOccurredAt > 0) and
    (aIdentity.ProcessId <> 0) and (aIdentity.Hwnd <> 0);
  if not Result then
    Exit;
  aRecord.Caption := aCaption;
  aRecord.CreatedAt := aOccurredAt;
  aRecord.Identity := aIdentity;
  aRecord.Reason := 'user_rename';
  aRecord.UpdatedAt := aOccurredAt;
  aEvent := TCaptionOverrideLifecycleEvent.CreateRename(
    aIdentity,
    aOccurredAt,
    aCaption);
end;

function BuildEndCaptionOverrideTransition(
  const aRecord: TCaptionOverrideRecord;
  const aEventKind: TCaptionOverrideEventKind; const aOccurredAt: Int64;
  const aReason: string; out aEvent: TCaptionOverrideLifecycleEvent): Boolean;
begin
  aEvent := Default(TCaptionOverrideLifecycleEvent);
  Result := (aOccurredAt > 0) and (aRecord.Identity.ProcessId <> 0) and
    (aRecord.Identity.Hwnd <> 0) and
    (((aEventKind = TCaptionOverrideEventKind.coekReset) and
      (aReason = 'user_reset')) or
    ((aEventKind = TCaptionOverrideEventKind.coekExpired) and
      ((aReason = 'window_missing') or (aReason = 'process_exited') or
      (aReason = 'identity_changed') or (aReason = 'local_prune'))));
  if not Result then
    Exit;
  aEvent := TCaptionOverrideLifecycleEvent.CreateEnd(
    aEventKind,
    aRecord.Identity,
    aOccurredAt,
    aReason);
end;

function CurrentUtcUnixMilliseconds: Int64;
var
  lNow: TDateTime;
begin
  lNow := Now;
  Result := (DateTimeToUnix(lNow, False) * 1000) + MilliSecondOf(lNow);
end;

function SameCaptionOverrideIdentity(const aLeft: TCaptionOverrideIdentity;
  const aRight: TCaptionOverrideIdentity): Boolean;
begin
  Result := (aLeft.HasBootId = aRight.HasBootId) and
    ((not aLeft.HasBootId) or (aLeft.BootId = aRight.BootId)) and
    (aLeft.HasProcessStartedAt = aRight.HasProcessStartedAt) and
    ((not aLeft.HasProcessStartedAt) or
      (aLeft.ProcessStartedAt = aRight.ProcessStartedAt)) and
    (aLeft.ProcessId = aRight.ProcessId) and (aLeft.Hwnd = aRight.Hwnd);
end;

function SelectCurrentCaptionOverrideIdentity(
  const aStored: TCaptionOverrideIdentity;
  const aObserved: TCaptionOverrideIdentity): TCaptionOverrideIdentity;
begin
  if (aStored.ProcessId <> aObserved.ProcessId) or
    (aStored.Hwnd <> aObserved.Hwnd) or
    (aStored.HasBootId and aObserved.HasBootId and
      (aStored.BootId <> aObserved.BootId)) or
    (aStored.HasProcessStartedAt and aObserved.HasProcessStartedAt and
      (aStored.ProcessStartedAt <> aObserved.ProcessStartedAt)) then
    Exit(aObserved);
  Result := aStored;
  if (not Result.HasBootId) and aObserved.HasBootId then
  begin
    Result.HasBootId := True;
    Result.BootId := aObserved.BootId;
  end;
  if (not Result.HasProcessStartedAt) and aObserved.HasProcessStartedAt then
  begin
    Result.HasProcessStartedAt := True;
    Result.ProcessStartedAt := aObserved.ProcessStartedAt;
  end;
end;

function IsWindowIdentityCurrent(const aWnd: hWnd; const aProcessId: Cardinal): Boolean;
var
  lCurrentProcessId: Cardinal;
begin
  Result := False;
  if (aWnd = 0) or (aProcessId = 0) or (not IsWindow(aWnd)) then
    Exit;

  lCurrentProcessId := 0;
  GetWindowThreadProcessId(aWnd, lCurrentProcessId);
  Result := lCurrentProcessId = aProcessId;
end;

function TryResolveWindowActionTarget(const aTarget: TWindowActionTarget;
  const aIsCurrent: TWindowCaptionOverrideIsAliveFunc; out aWnd: hWnd;
  out aProcessId: Cardinal): Boolean;
begin
  aWnd := 0;
  aProcessId := 0;
  Result := (aTarget.Wnd <> 0) and (aTarget.ProcessId <> 0) and
    Assigned(aIsCurrent) and aIsCurrent(aTarget.Wnd, aTarget.ProcessId);
  if not Result then
    Exit;
  aWnd := aTarget.Wnd;
  aProcessId := aTarget.ProcessId;
end;

function TryParseWindowCaptionOverrideKey(const aKey: string; out aWnd: hWnd; out aProcessId: Cardinal): Boolean;
var
  lDelimiterIndex: Integer;
  lProcessId: Cardinal;
  lWnd: UInt64;
begin
  aWnd := 0;
  aProcessId := 0;
  lDelimiterIndex := Pos(':', aKey);
  Result := (lDelimiterIndex > 1) and (lDelimiterIndex < Length(aKey))
    and TryStrToUInt(Copy(aKey, 1, lDelimiterIndex - 1), lProcessId)
    and TryStrToUInt64(Copy(aKey, lDelimiterIndex + 1, MaxInt), lWnd)
    and (lProcessId > 0);
  if not Result then
    Exit;

  aWnd := hWnd(NativeUInt(lWnd));
  aProcessId := lProcessId;
end;

function HasWindowCaptionOverride(const aOverrides: TDictionary<string, string>;
  const aWnd: hWnd; const aProcessId: Cardinal): Boolean;
var
  lCaption: string;
begin
  Result := Assigned(aOverrides)
    and aOverrides.TryGetValue(BuildWindowCaptionOverrideKey(aWnd, aProcessId), lCaption);
end;

function ApplyWindowCaptionOverride(const aOverrides: TDictionary<string, string>;
  const aWnd: hWnd; const aProcessId: Cardinal; const aCaption: string): string;
var
  lCaption: string;
begin
  Result := aCaption;
  if Assigned(aOverrides) then
    if aOverrides.TryGetValue(BuildWindowCaptionOverrideKey(aWnd, aProcessId), lCaption) then
      Result := lCaption;
end;

function ExtractWindowRenameCaptionFromDisplayCaption(const aDisplayCaption: string): string;
var
  lDelimiterIndex: Integer;
begin
  Result := Trim(aDisplayCaption);
  lDelimiterIndex := Pos(' | ', Result);
  if lDelimiterIndex > 1 then
    Result := Trim(Copy(Result, 1, lDelimiterIndex - 1));
end;

function BuildWindowRenameDefaultCaption(const aOverrides: TDictionary<string, string>;
  const aWnd: hWnd; const aProcessId: Cardinal; const aLiveCaption: string;
  const aDisplayCaption: string): string;
begin
  Result := ExtractWindowRenameCaptionFromDisplayCaption(aDisplayCaption);
  if Result = '' then
    Result := ApplyWindowCaptionOverride(aOverrides, aWnd, aProcessId, aLiveCaption);
end;

function PruneWindowCaptionOverrides(const aOverrides: TDictionary<string, string>;
  const aIsAlive: TWindowCaptionOverrideIsAliveFunc): Boolean;
var
  lKeys: TArray<string>;
  lKey: string;
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  Result := False;
  if (not Assigned(aOverrides)) or (not Assigned(aIsAlive)) then
    Exit;

  lKeys := aOverrides.Keys.ToArray;
  for lKey in lKeys do
  begin
    if (not TryParseWindowCaptionOverrideKey(lKey, lWnd, lProcessId)) or (not aIsAlive(lWnd, lProcessId)) then
    begin
      aOverrides.Remove(lKey);
      Result := True;
    end;
  end;
end;

function GetCurrentWindowsBootId: Int64;
var
  lFileTime: TFileTime;
  lNowFileTime: UInt64;
begin
  GetSystemTimeAsFileTime(lFileTime);
  lNowFileTime := (UInt64(lFileTime.dwHighDateTime) shl 32) or UInt64(lFileTime.dwLowDateTime);
  Result := Int64((lNowFileTime - (GetTickCount64 * UInt64(10000))) div UInt64(10000000));
end;

function IsSameWindowsBootId(const aStoredBootId: Int64; const aCurrentBootId: Int64): Boolean;
begin
  Result := Abs(aStoredBootId - aCurrentBootId) <= 5;
end;

procedure SaveWindowCaptionOverridesToFile(const aFileName: string; const aOverrides: TDictionary<string, string>;
  const aBootId: Int64);
var
  lIniFile: TMemIniFile;
  lPair: TPair<string, string>;
begin
  if (not Assigned(aOverrides)) or (aOverrides.Count = 0) then
  begin
    if TFile.Exists(aFileName) then
      TFile.Delete(aFileName);
    Exit;
  end;

  if TFile.Exists(aFileName) then
    TFile.Delete(aFileName);
  lIniFile := TMemIniFile.Create(aFileName, TEncoding.UTF8, False);
  try
    lIniFile.WriteString(
      cWindowCaptionOverridesMetadataSectionName,
      cWindowCaptionOverridesBootIdKey,
      IntToStr(aBootId));
    for lPair in aOverrides do
      lIniFile.WriteString(cWindowCaptionOverridesSectionName, lPair.Key, lPair.Value);
    lIniFile.UpdateFile;
  finally
    lIniFile.Free;
  end;
end;

procedure LoadWindowCaptionOverridesFromFile(const aFileName: string; const aOverrides: TDictionary<string, string>;
  const aCurrentBootId: Int64);
var
  g: TGarbos;
  lIniFile: TMemIniFile;
  lStoredBootId: Int64;
  lValues: TStringList;
  i: Integer;
begin
  if (not Assigned(aOverrides)) or (not TFile.Exists(aFileName)) then
    Exit;

  GC(lIniFile, TMemIniFile.Create(aFileName, TEncoding.UTF8, False), g);
  lStoredBootId := StrToInt64Def(lIniFile.ReadString(
    cWindowCaptionOverridesMetadataSectionName,
    cWindowCaptionOverridesBootIdKey,
    ''),
    -1);
  if not IsSameWindowsBootId(lStoredBootId, aCurrentBootId) then
  begin
    TFile.Delete(aFileName);
    Exit;
  end;

  GC(lValues, TStringList.Create, g);
  lIniFile.ReadSectionValues(cWindowCaptionOverridesSectionName, lValues);
  aOverrides.Clear;
  for i := 0 to lValues.Count - 1 do
    if lValues.Names[i] <> '' then
      aOverrides.AddOrSetValue(lValues.Names[i], lValues.ValueFromIndex[i]);
end;

function BuildWindowDisplayCaption(const aCaption: string; const aFileName: string): string;
begin
  if (aCaption <> '') and (aFileName <> '') then
    Result := aCaption + ' | ' + ExtractFileName(aFileName) + ' (' + aFileName + ')'
  else
    Result := aCaption;
end;

procedure ApplyConsolePrefixRule(var aTitle: string; const aCaption: string; const aFileName: string;
  const aRules: TPrefixRuleArray);
var
  lRule: TPrefixRule;
begin
  for lRule in aRules do
  begin
    if ((lRule.CaptionMask <> '') and maxLogic.StrUtils.StringMatches(aCaption, lRule.CaptionMask, False))
      or ((lRule.FileNameMask <> '') and maxLogic.StrUtils.StringMatches(aFileName, lRule.FileNameMask, False)) then
    begin
      if lRule.Prefix <> '' then
        aTitle := lRule.Prefix + ' - ' + aTitle;
      Exit;
    end;
  end;
end;

function BuildConsoleDisplayCaption(const aCaption: string; const aFileName: string;
  const aRules: TPrefixRuleArray): string;
begin
  Result := Trim(BuildWindowDisplayCaption(aCaption, aFileName));
  ApplyConsolePrefixRule(Result, aCaption, aFileName, aRules);
end;

function ExecuteCaptionOverrideDialog(aOwner: TComponent; const aCaption: string;
  out aNewCaption: string): TCaptionOverrideDialogResult;
var
  lButtonTop: Integer;
  lCancelButton: TButton;
  lDialog: TForm;
  lEdit: TEdit;
  lLabel: TLabel;
  lOkButton: TButton;
  lResetButton: TButton;
begin
  Result := codCancel;
  aNewCaption := aCaption;

  lDialog := TForm.CreateNew(aOwner);
  try
    lDialog.BorderStyle := bsDialog;
    lDialog.Caption := rsWindowActionRename;
    lDialog.ClientHeight := 118;
    lDialog.ClientWidth := 420;
    lDialog.Position := poOwnerFormCenter;

    lLabel := TLabel.Create(lDialog);
    lLabel.Parent := lDialog;
    lLabel.Left := 12;
    lLabel.Top := 12;
    lLabel.Caption := rsWindowRenamePrompt;

    lEdit := TEdit.Create(lDialog);
    lEdit.Parent := lDialog;
    lEdit.Left := 12;
    lEdit.Top := 32;
    lEdit.Width := lDialog.ClientWidth - 24;
    lEdit.Text := aCaption;
    lEdit.SelectAll;

    lButtonTop := 78;

    lOkButton := TButton.Create(lDialog);
    lOkButton.Parent := lDialog;
    lOkButton.Left := lDialog.ClientWidth - 252;
    lOkButton.Top := lButtonTop;
    lOkButton.Width := 75;
    lOkButton.Caption := rsDialogOk;
    lOkButton.Default := True;
    lOkButton.ModalResult := mrOk;

    lResetButton := TButton.Create(lDialog);
    lResetButton.Parent := lDialog;
    lResetButton.Left := lDialog.ClientWidth - 171;
    lResetButton.Top := lButtonTop;
    lResetButton.Width := 75;
    lResetButton.Caption := rsWindowActionReset;
    lResetButton.ModalResult := mrRetry;

    lCancelButton := TButton.Create(lDialog);
    lCancelButton.Parent := lDialog;
    lCancelButton.Left := lDialog.ClientWidth - 90;
    lCancelButton.Top := lButtonTop;
    lCancelButton.Width := 75;
    lCancelButton.Cancel := True;
    lCancelButton.Caption := rsDialogCancel;
    lCancelButton.ModalResult := mrCancel;

    lDialog.ActiveControl := lEdit;
    case lDialog.ShowModal of
      mrOk:
      begin
        aNewCaption := Trim(lEdit.Text);
        if aNewCaption <> '' then
          Result := codRename;
      end;
      mrRetry:
        Result := codReset;
    end;
  finally
    lDialog.Free;
  end;
end;

function ExecuteCaptionOverrideDialogWithInitialCaption(aOwner: TComponent; const aCaption: string;
  const aDialogRunner: TCaptionOverrideDialogRunner): TCaptionOverrideDialogOutcome;
begin
  Result.Caption := aCaption;
  Result.DialogResult := aDialogRunner(aOwner, aCaption, Result.Caption);
end;

function CaptionOverrideDialogInputSelfTestRunner(aOwner: TComponent; const aCaption: string;
  out aNewCaption: string): TCaptionOverrideDialogResult;
begin
  aNewCaption := aCaption + ' edited';
  Result := codRename;
end;

function ScaleProportionalColumnWidth(const aTotalWidth: Integer; const aDesignWidth: Integer): Integer;
begin
  Result := Integer((Int64(aTotalWidth) * aDesignWidth) div cTotalDesignColumnWidth);
end;

procedure CalculateProportionalColumnWidths(const aTotalWidth: Integer; out aAppsWidth: Integer;
  out aExplorerWidth: Integer; out aScriptsWidth: Integer; out aConsoleWidth: Integer;
  out aDesktopWidth: Integer; out aShortCutsWidth: Integer);
var
  lConsumedDesignWidth: Integer;
  lConsumedWidth: Integer;
  lNextWidth: Integer;
begin
  if aTotalWidth <= 0 then
  begin
    aAppsWidth := 0;
    aExplorerWidth := 0;
    aScriptsWidth := 0;
    aConsoleWidth := 0;
    aDesktopWidth := 0;
    aShortCutsWidth := 0;
    Exit;
  end;

  lConsumedWidth := 0;
  lConsumedDesignWidth := cAppsColumnDesignWidth;
  lNextWidth := ScaleProportionalColumnWidth(aTotalWidth, lConsumedDesignWidth);
  aAppsWidth := lNextWidth - lConsumedWidth;
  lConsumedWidth := lNextWidth;

  Inc(lConsumedDesignWidth, cExplorerColumnDesignWidth);
  lNextWidth := ScaleProportionalColumnWidth(aTotalWidth, lConsumedDesignWidth);
  aExplorerWidth := lNextWidth - lConsumedWidth;
  lConsumedWidth := lNextWidth;

  Inc(lConsumedDesignWidth, cScriptsColumnDesignWidth);
  lNextWidth := ScaleProportionalColumnWidth(aTotalWidth, lConsumedDesignWidth);
  aScriptsWidth := lNextWidth - lConsumedWidth;
  lConsumedWidth := lNextWidth;

  Inc(lConsumedDesignWidth, cConsoleColumnDesignWidth);
  lNextWidth := ScaleProportionalColumnWidth(aTotalWidth, lConsumedDesignWidth);
  aConsoleWidth := lNextWidth - lConsumedWidth;
  lConsumedWidth := lNextWidth;

  Inc(lConsumedDesignWidth, cDesktopColumnDesignWidth);
  lNextWidth := ScaleProportionalColumnWidth(aTotalWidth, lConsumedDesignWidth);
  aDesktopWidth := lNextWidth - lConsumedWidth;
  lConsumedWidth := lNextWidth;

  aShortCutsWidth := aTotalWidth - lConsumedWidth;
end;

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

function IsCodexWorkingPrefixChar(const aChar: Char): Boolean;
begin
  Result := (Ord(aChar) >= $2800) and (Ord(aChar) <= $28FF);
end;

function NormalizeConsoleSortCaption(const aCaption: string): string;
var
  lIndex: Integer;
begin
  lIndex := 1;
  while (lIndex <= Length(aCaption)) and IsCodexWorkingPrefixChar(aCaption[lIndex]) do
    Inc(lIndex);

  Result := TrimLeft(Copy(aCaption, lIndex, MaxInt));
end;

function CompareNativeUInt(const aLeft: NativeUInt; const aRight: NativeUInt): Integer;
begin
  if aLeft < aRight then
    Exit(-1);
  if aLeft > aRight then
    Exit(1);
  Result := 0;
end;

function GetConsoleSortProcessId(aList: TStringList; const aIndex: Integer): NativeUInt;
var
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  Result := 0;
  if (not Assigned(aList)) or (aIndex < 0) or (aIndex >= aList.Count) then
    Exit;

  lWnd := hWnd(aList.Objects[aIndex]);
  if lWnd <> 0 then
  begin
    lProcessId := 0;
    GetWindowThreadProcessId(lWnd, lProcessId);
    if lProcessId <> 0 then
      Exit(lProcessId);
  end;

  Result := NativeUInt(aList.Objects[aIndex]);
end;

function WindowArrayContains(const aWindows: TArray<hWnd>; const aWnd: hWnd): Boolean;
var
  lWnd: hWnd;
begin
  Result := False;
  for lWnd in aWindows do
  begin
    if lWnd = aWnd then
      Exit(True);
  end;
end;

function RemoveWindowsFromItems(const aItems: TStrings; const aWindows: TArray<hWnd>): Boolean;
var
  lIndex: Integer;
  lWnd: hWnd;
begin
  Result := False;
  if (not Assigned(aItems)) or (Length(aWindows) = 0) then
    Exit;

  aItems.BeginUpdate;
  try
    for lIndex := aItems.Count - 1 downto 0 do
    begin
      lWnd := hWnd(aItems.Objects[lIndex]);
      if WindowArrayContains(aWindows, lWnd) then
      begin
        aItems.Delete(lIndex);
        Result := True;
      end;
    end;
  finally
    aItems.EndUpdate;
  end;
end;

function RemoveWindowsFromListBox(const aListBox: TListBox; const aWindows: TArray<hWnd>): Boolean;
begin
  Result := False;
  if not Assigned(aListBox) then
    Exit;

  Result := RemoveWindowsFromItems(aListBox.Items, aWindows);

  if aListBox.Items.Count = 0 then
    aListBox.ItemIndex := -1
  else if aListBox.ItemIndex < 0 then
    aListBox.ItemIndex := 0
  else if aListBox.ItemIndex >= aListBox.Items.Count then
    aListBox.ItemIndex := aListBox.Items.Count - 1;
end;

function FindWindowItemIndex(const aItems: TStrings; const aWnd: hWnd): Integer;
var
  lIndex: Integer;
begin
  Result := -1;
  if (not Assigned(aItems)) or (aWnd = 0) then
    Exit;

  for lIndex := 0 to aItems.Count - 1 do
  begin
    if hWnd(aItems.Objects[lIndex]) = aWnd then
      Exit(lIndex);
  end;
end;

function CalculateWindowItemIndexAfterRemoval(const aItems: TStrings; const aOldItemIndex: Integer;
  const aOldWnd: hWnd; const aRemovedWnd: hWnd): Integer;
begin
  Result := -1;
  if (not Assigned(aItems)) or (aItems.Count = 0) then
    Exit;
  if aOldItemIndex < 0 then
    Exit;

  if (aOldWnd <> 0) and (aOldWnd <> aRemovedWnd) then
  begin
    Result := FindWindowItemIndex(aItems, aOldWnd);
    if Result <> -1 then
      Exit;
  end;

  Result := aOldItemIndex;
  if Result >= aItems.Count then
    Result := aItems.Count - 1;
end;

function CalculateItemIndexAfterDeletingIndex(const aItemCount: Integer; const aDeletedItemIndex: Integer): Integer;
begin
  Result := -1;
  if aItemCount <= 0 then
    Exit;

  Result := aDeletedItemIndex;
  if Result >= aItemCount then
    Result := aItemCount - 1;
end;

function CalculateWindowItemIndexAfterValidation(const aItems: TStrings; const aOldItemIndex: Integer;
  const aOldWnd: hWnd): Integer;
begin
  Result := CalculateWindowItemIndexAfterRemoval(aItems, aOldItemIndex, aOldWnd, 0);
end;

function TitleHasDisplayPrefix(const aTitle: string; const aPrefix: string): Boolean;
begin
  Result := (aPrefix <> '') and StartsText(aPrefix + ' - ', aTitle);
end;

procedure ApplyDisplayPrefix(var aTitle: string; const aPrefix: string);
begin
  if (aPrefix = '') or TitleHasDisplayPrefix(aTitle, aPrefix) then
    Exit;

  aTitle := aPrefix + ' - ' + aTitle;
end;

function TitleHasKnownDisplayPrefix(const aTitle: string; const aRules: TPrefixRuleArray): Boolean;
var
  lRule: TPrefixRule;
begin
  Result := False;
  for lRule in aRules do
  begin
    if TitleHasDisplayPrefix(aTitle, lRule.Prefix) then
      Exit(True);
  end;
end;

function CalculateRestoredItemIndex(const aItems: TStrings; const aWnd: hWnd; const aOldItemIndex: Integer;
  const aOldItemCaption: string; const aSorted: Boolean): Integer;
var
  lIndex: Integer;
begin
  Result := -1;
  if (not Assigned(aItems)) or (aItems.Count = 0) then
    Exit;

  for lIndex := 0 to aItems.Count - 1 do
  begin
    if aWnd = hWnd(aItems.Objects[lIndex]) then
      Exit(lIndex);
  end;

  if (aOldItemCaption <> '') and aSorted then
  begin
    lIndex := FindSortedCaptionIndex(aItems, aOldItemCaption);
    if lIndex <> -1 then
      Exit(lIndex);
  end;

  if (aOldItemIndex >= 0) and (aOldItemIndex < aItems.Count) then
    Exit(aOldItemIndex);
  if aOldItemIndex >= aItems.Count then
    Exit(aItems.Count - 1);
end;

function IsWindowActionListBox(const aListBox: TObject; const aAppsListBox: TObject; const aExplorerListBox: TObject;
  const aConsoleListBox: TObject): Boolean;
begin
  Result := (aListBox = aAppsListBox) or (aListBox = aExplorerListBox) or (aListBox = aConsoleListBox);
end;

function RemoveWindowFromSnapshots(var aSnapshots: TArray<TChatAppSnapshot>; const aWnd: hWnd): Boolean;
var
  lIndex: Integer;
  lWriteIndex: Integer;
begin
  Result := False;
  if (aWnd = 0) or (Length(aSnapshots) = 0) then
    Exit;

  lWriteIndex := 0;
  for lIndex := 0 to High(aSnapshots) do
  begin
    if aSnapshots[lIndex].Wnd = aWnd then
    begin
      Result := True;
      Continue;
    end;
    if lWriteIndex <> lIndex then
      aSnapshots[lWriteIndex] := aSnapshots[lIndex];
    Inc(lWriteIndex);
  end;

  if Result then
    SetLength(aSnapshots, lWriteIndex);
end;

function IsEdgeBasedAppFileName(const aFileName: string): Boolean;
begin
  Result := SameText('msedge.exe', ExtractFileName(aFileName));
end;

procedure PrefetchDeepPrefixMetadataForApp(const aApp: TAppInfo; const aNeedAppUserModelID: Boolean;
  const aNeedCmdParams: Boolean);
begin
  if (aApp = nil) or (aApp.Caption = '') then
    Exit;

  if aNeedAppUserModelID then
  begin
    try
      aApp.AppUserModelID;
    except
      // Window metadata can disappear while we prefetch in the background; skip transient failures.
    end;
  end;
  if aNeedCmdParams then
  begin
    try
      aApp.CommandLineParams;
    except
      // Command-line metadata can be denied for some processes; prefix matching will just not use it.
    end;
  end;
end;

procedure PrefetchDeepPrefixMetadataForApps(const aApps: TArray<TAppInfo>; const aNeedAppUserModelID: Boolean;
  const aNeedCmdParams: Boolean; const aCancelToken: iCancelToken; const aPrefetchProc: TDeepPrefixPrefetchProc = nil);
var
  lIndex: Integer;
  lPrefetchProc: TDeepPrefixPrefetchProc;
begin
  lPrefetchProc := aPrefetchProc;
  for lIndex := 0 to High(aApps) do
  begin
    if Assigned(aCancelToken) and aCancelToken.Canceled then
      Exit;

    if Assigned(lPrefetchProc) then
      lPrefetchProc(aApps[lIndex], aNeedAppUserModelID, aNeedCmdParams)
    else
      PrefetchDeepPrefixMetadataForApp(aApps[lIndex], aNeedAppUserModelID, aNeedCmdParams);
  end;
end;

function ShouldForceTerminateAsyncOnShutdown: Boolean;
begin
  Result := False;
end;

function CompareConsoleSortItems(aList: TStringList; aIndex1: Integer; aIndex2: Integer): Integer;
var
  lLeft: string;
  lLeftProcessId: NativeUInt;
  lRight: string;
  lRightProcessId: NativeUInt;
begin
  lLeft := NormalizeConsoleSortCaption(aList[aIndex1]);
  lRight := NormalizeConsoleSortCaption(aList[aIndex2]);
  Result := CompareText(lLeft, lRight);
  if Result = 0 then
  begin
    lLeftProcessId := GetConsoleSortProcessId(aList, aIndex1);
    lRightProcessId := GetConsoleSortProcessId(aList, aIndex2);
    Result := CompareNativeUInt(lLeftProcessId, lRightProcessId);
  end;
  if Result = 0 then
    Result := CompareNativeUInt(NativeUInt(aList.Objects[aIndex1]), NativeUInt(aList.Objects[aIndex2]));
end;

procedure SortConsoleItems(const aItems: TStrings);
var
  lIndex: Integer;
  lItems: TStringList;
begin
  if aItems.Count <= 1 then
    Exit;

  gc(lItems, TStringList.Create);
  for lIndex := 0 to aItems.Count - 1 do
    lItems.AddObject(aItems[lIndex], aItems.Objects[lIndex]);

  lItems.CustomSort(CompareConsoleSortItems);
  aItems.Assign(lItems);
end;

function SecondsToIntervalMs(const aSeconds: Integer): Cardinal;
var
  lIntervalMs: Int64;
begin
  if aSeconds <= 0 then
    Exit(0);

  lIntervalMs := Int64(aSeconds) * 1000;
  if lIntervalMs > High(Cardinal) then
    Result := High(Cardinal)
  else
    Result := Cardinal(lIntervalMs);
end;

function CalculateSharedTimerIntervalMs(const aWindowTitlePollingIntervalMs: Cardinal;
  const aChatMonitorEnabled: Boolean; const aChatMonitorIntervalMs: Cardinal): Cardinal;
begin
  Result := aWindowTitlePollingIntervalMs;
  if not aChatMonitorEnabled then
    Exit;

  if aChatMonitorIntervalMs = 0 then
    Exit;

  if (Result = 0) or (aChatMonitorIntervalMs < Result) then
    Result := aChatMonitorIntervalMs;
end;

function ShouldEnableSharedTimer(const aWindowTitlePollingIntervalMs: Cardinal;
  const aChatMonitorEnabled: Boolean; const aChatMonitorIntervalMs: Cardinal;
  const aMachineOverviewEnabled: Boolean): Boolean;
begin
  Result := aMachineOverviewEnabled or
    (CalculateSharedTimerIntervalMs(aWindowTitlePollingIntervalMs,
      aChatMonitorEnabled, aChatMonitorIntervalMs) <> 0);
end;

function IsTimedActionDue(const aNowTick: UInt64; const aLastTick: UInt64;
  const aIntervalMs: Cardinal): Boolean;
begin
  Result := (aIntervalMs <> 0) and ((aLastTick = 0) or ((aNowTick - aLastTick) >= aIntervalMs));
end;

function ShouldEnablePeriodicWindowPolling(const aStartupDataReady: Boolean;
  const aIntervalMs: Cardinal): Boolean;
begin
  Result := aStartupDataReady and (aIntervalMs <> 0);
end;

function LoadScriptIgnoreList(const aScriptsDir: string): TStringList;
var
  lFileName: string;
  lIgnoreFileName: string;
  lLine: string;
  lLines: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;

  lIgnoreFileName := CombinePath([aScriptsDir, cScriptsIgnoreFileName]);
  if not TFile.Exists(lIgnoreFileName) then
    Exit;

  lLines := TStringList.Create;
  try
    lLines.LoadFromFile(lIgnoreFileName, TEncoding.UTF8);
    for lLine in lLines do
    begin
      lFileName := Trim(lLine);
      if (lFileName = '') or StartsText('#', lFileName) then
        Continue;

      Result.Add(ExtractFileName(lFileName));
    end;
  finally
    lLines.Free;
  end;
end;

function IsIgnoredScriptFile(const aScriptFileName: string; const aIgnoredScripts: TStrings): Boolean;
begin
  Result := Assigned(aIgnoredScripts) and (aIgnoredScripts.IndexOf(ExtractFileName(aScriptFileName)) <> -1);
end;

function BuildScriptsSnapshotForFolder(const aScriptsDir: string): TStringArray;
var
  lExt: string;
  lIgnoredScripts: TStringList;
  lScriptFile: string;
begin
  SetLength(Result, 0);
  if not TDirectory.Exists(aScriptsDir) then
    Exit;

  lIgnoredScripts := LoadScriptIgnoreList(aScriptsDir);
  try
    for lScriptFile in TDirectory.GetFiles(aScriptsDir, '*.*') do
    begin
      lExt := ExtractFileExt(lScriptFile);
      if System.StrUtils.MatchText(lExt, ['.cmd', '.bat', '.ps1', '.exe', '.py'])
        and not IsIgnoredScriptFile(lScriptFile, lIgnoredScripts) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := ExtractFileName(lScriptFile);
      end;
    end;
  finally
    lIgnoredScripts.Free;
  end;
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
        lApp.PrefetchProcessIdentity;
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
var
  lWatch: TStopwatch;
begin
  lWatch := TStopwatch.StartNew;
  try
    if IsShuttingDown then
      Exit;

    PlayConfiguredFocusSound;
    MarkFormFocused;
    StartAuxListsRefresh;

    if TInterlocked.CompareExchange(fStartupDataReady, 0, 0) = 0 then
      StartStartupDataLoad
    else
      QueueGuiRefresh;
    if assigned(fOrgAppOnActivate) then
      fOrgAppOnActivate(Sender);
  finally
    RecordSlowUiOperation('Foreground', lWatch.Elapsed.TotalMilliseconds);
  end;
end;

procedure TAppsViewMainFrm.PlayConfiguredFocusSound;
begin
  if Assigned(fFocusSoundPlayer) then
    fFocusSoundPlayer(fFocusSoundFileName)
  else
    PlayFocusSound(fFocusSoundFileName);
end;

function TAppsViewMainFrm.CaptureWindowActionTarget(
  const aListBox: TListBox): Boolean;
var
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  ClearWindowActionTarget;
  Result := GetSelectedWindowInfo(aListBox, lWnd, lProcessId);
  if not Result then
    Exit;

  fWindowActionSourceListBox := aListBox;
  fWindowActionTarget.ProcessId := lProcessId;
  fWindowActionTarget.Wnd := lWnd;
  if (aListBox.ItemIndex >= 0) and
    (aListBox.ItemIndex < aListBox.Items.Count) then
    fWindowActionTarget.DisplayCaption :=
      aListBox.Items[aListBox.ItemIndex];
end;

procedure TAppsViewMainFrm.ClearWindowActionTarget;
begin
  fWindowActionSourceListBox := nil;
  fWindowActionTarget := Default(TWindowActionTarget);
end;

procedure TAppsViewMainFrm.CloseSelectedWindow(const aListBox: TListBox);
var
  lTarget: TWindowActionTarget;
begin
  if not GetSelectedWindowInfo(
    aListBox,
    lTarget.Wnd,
    lTarget.ProcessId) then
    Exit;
  CloseWindowTarget(lTarget);
end;

procedure TAppsViewMainFrm.CloseWindowTarget(
  const aTarget: TWindowActionTarget);
var
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  if not TryResolveWindowActionTarget(
    aTarget,
    IsWindowIdentityCurrent,
    lWnd,
    lProcessId) then
    Exit;
  PostMessage(lWnd, WM_CLOSE, 0, 0);
  ScheduleWindowActionCleanup(lWnd, lProcessId);
end;

function TAppsViewMainFrm.ConsumeWindowActionTarget(
  out aListBox: TListBox; out aTarget: TWindowActionTarget): Boolean;
var
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  aListBox := fWindowActionSourceListBox;
  aTarget := fWindowActionTarget;
  ClearWindowActionTarget;
  Result := Assigned(aListBox) and TryResolveWindowActionTarget(
    aTarget,
    IsWindowIdentityCurrent,
    lWnd,
    lProcessId);
  if not Result then
    Exit;
  aTarget.ProcessId := lProcessId;
  aTarget.Wnd := lWnd;
end;

procedure TAppsViewMainFrm.CreateWindowActionsPopupMenu;
begin
  fWindowActionsPopupMenu := TPopupMenu.Create(Self);
  fWindowActionsPopupMenu.OnPopup := WindowActionsPopupMenuPopup;

  fRenameWindowMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fRenameWindowMenuItem.Caption := rsWindowActionRename;
  fRenameWindowMenuItem.OnClick := WindowRenameMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fRenameWindowMenuItem);

  fCopyFullExeFileNameMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fCopyFullExeFileNameMenuItem.Caption := rsWindowActionCopyExecutableFileName;
  fCopyFullExeFileNameMenuItem.Tag := cWindowActionCopyExecutableFileNameTag;
  fCopyFullExeFileNameMenuItem.OnClick := WindowCopyMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fCopyFullExeFileNameMenuItem);

  fCopyFullExeCommandLineMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fCopyFullExeCommandLineMenuItem.Caption := rsWindowActionCopyCommandLine;
  fCopyFullExeCommandLineMenuItem.Tag := cWindowActionCopyCommandLineTag;
  fCopyFullExeCommandLineMenuItem.OnClick := WindowCopyMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fCopyFullExeCommandLineMenuItem);

  fCopyPidMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fCopyPidMenuItem.Caption := rsWindowActionCopyPid;
  fCopyPidMenuItem.Tag := cWindowActionCopyProcessIdTag;
  fCopyPidMenuItem.OnClick := WindowCopyMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fCopyPidMenuItem);

  fCopyHwndMenuItem := TMenuItem.Create(fWindowActionsPopupMenu);
  fCopyHwndMenuItem.Caption := rsWindowActionCopyHwnd;
  fCopyHwndMenuItem.Tag := cWindowActionCopyWindowHandleTag;
  fCopyHwndMenuItem.OnClick := WindowCopyMenuItemClick;
  fWindowActionsPopupMenu.Items.Add(fCopyHwndMenuItem);

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
  lbConsole.PopupMenu := fWindowActionsPopupMenu;
  lbApps.OnContextPopup := WindowActionListBoxContextPopup;
  lbExplorer.OnContextPopup := WindowActionListBoxContextPopup;
  lbConsole.OnContextPopup := WindowActionListBoxContextPopup;
end;

function TAppsViewMainFrm.GetPopupSourceListBox: TListBox;
begin
  Result := nil;
  if Assigned(fWindowActionsPopupMenu) and (fWindowActionsPopupMenu.PopupComponent is TListBox) then
    Result := TListBox(fWindowActionsPopupMenu.PopupComponent);

  if (Result <> lbApps) and (Result <> lbExplorer) and (Result <> lbConsole) then
    Result := nil;
end;

function TAppsViewMainFrm.GetSelectedWindowInfo(const aListBox: TListBox; out aWnd: hWnd;
  out aProcessId: Cardinal): Boolean;
begin
  aWnd := 0;
  aProcessId := 0;
  Result := False;
  if not Assigned(aListBox) then
    Exit;

  aWnd := GetWnd(aListBox);
  if aWnd = 0 then
    Exit;

  GetWindowThreadProcessId(aWnd, aProcessId);
  Result := IsWindowIdentityCurrent(aWnd, aProcessId);
end;

function TAppsViewMainFrm.IsCaptionOverrideListBox(const aListBox: TListBox): Boolean;
begin
  Result := (aListBox = lbApps) or (aListBox = lbConsole);
end;

function TAppsViewMainFrm.ApplyExpiredWindowCaptionOverrides: Boolean;
var
  lExpiration: TCaptionOverrideExpiration;
  lExpirations: TCaptionOverrideExpirations;
  lKey: string;
  lRecord: TCaptionOverrideRecord;
begin
  Result := False;
  if (not Assigned(fRenameJournalWriter)) or
    (not fRenameJournalWriter.TryTakeExpiredOverrides(lExpirations)) then
    Exit;
  for lExpiration in lExpirations do
  begin
    lKey := BuildWindowCaptionOverrideKey(
      HWND(NativeUInt(lExpiration.Identity.Hwnd)),
      lExpiration.Identity.ProcessId);
    if fWindowCaptionOverrideRecords.TryGetValue(lKey, lRecord) and
      SameCaptionOverrideIdentity(lRecord.Identity, lExpiration.Identity) then
    begin
      fWindowCaptionOverrideRecords.Remove(lKey);
      fWindowCaptionOverrides.Remove(lKey);
      Result := True;
    end;
  end;
end;

function TAppsViewMainFrm.BuildWindowCaptionOverrideIdentity(const aWnd: hWnd;
  const aProcessId: Cardinal): TCaptionOverrideIdentity;
var
  lApp: TWindowSnapshot;
  lBootIdentity: TWindowsBootIdentity;
  lObserved: TCaptionOverrideIdentity;
  lRecord: TCaptionOverrideRecord;
begin
  lObserved := Default(TCaptionOverrideIdentity);
  lObserved.Hwnd := UInt64(NativeUInt(aWnd));
  lObserved.ProcessId := aProcessId;
  if TryGetCachedWindowsBootIdentity(lBootIdentity) then
  begin
    lObserved.HasBootId := True;
    lObserved.BootId := lBootIdentity.UtcMilliseconds;
  end;
  if TryGetWindowSnapshot(aWnd, lApp) and
    (lApp.ProcessStartedAt <> 0) then
  begin
    lObserved.HasProcessStartedAt := True;
    lObserved.ProcessStartedAt := lApp.ProcessStartedAt;
  end;
  if fWindowCaptionOverrideRecords.TryGetValue(
    BuildWindowCaptionOverrideKey(aWnd, aProcessId),
    lRecord) then
    Result := SelectCurrentCaptionOverrideIdentity(lRecord.Identity, lObserved)
  else
    Result := lObserved;
end;

procedure TAppsViewMainFrm.JournalWindowCaptionOverride(
  const aEvent: TCaptionOverrideLifecycleEvent);
var
  lEnqueueResult: TRenameJournalEnqueueResult;
begin
  lEnqueueResult := fRenameJournalWriter.EnqueueLifecycle(aEvent);
  case lEnqueueResult of
    rjerFull:
      LogStartupTiming('RenameJournal.QueueFull', 'lifecycle event dropped');
    rjerStopped:
      LogStartupTiming('RenameJournal.Stopped', 'lifecycle event dropped during shutdown');
  end;
end;

function TAppsViewMainFrm.PruneWindowCaptionOverrides: Boolean;
begin
  Result := ApplyExpiredWindowCaptionOverrides;
end;

procedure TAppsViewMainFrm.RestoreFocusAfterWindowCaptionDialog(const aListBox: TListBox);
begin
  if IsShuttingDown then
    Exit;

  ShowWindow(Handle, SW_SHOWNORMAL);
  BringToFront;
  SetForegroundWindow(Handle);
  if Assigned(aListBox) and aListBox.CanFocus then
    aListBox.SetFocus;
end;

function TAppsViewMainFrm.ShouldConsumeSuppressedReturnKey(const aSender: TObject; const aKey: Word): Boolean;
begin
  Result := False;
  if aKey <> VK_RETURN then
    Exit;

  if (aSender <> fSuppressNextReturnListBox)
    or (GetTickCount64 > fSuppressNextReturnUntilTick) then
  begin
    fSuppressNextReturnListBox := nil;
    fSuppressNextReturnUntilTick := 0;
    Exit;
  end;

  fSuppressNextReturnListBox := nil;
  fSuppressNextReturnUntilTick := 0;
  Result := True;
end;

procedure TAppsViewMainFrm.SuppressNextReturnKey(const aListBox: TListBox);
begin
  fSuppressNextReturnListBox := aListBox;
  fSuppressNextReturnUntilTick := GetTickCount64 + cSuppressReturnKeyAfterDialogMs;
end;

function TAppsViewMainFrm.BuildWindowCaptionOverrideState: TCaptionOverrideState;
var
  i: Integer;
  lNow: TDateTime;
  lNowMilliseconds: Int64;
  lPair: TPair<string, string>;
  lProcessId: Cardinal;
  lRecord: TCaptionOverrideRecord;
  lWnd: HWND;
begin
  lNow := Now;
  lNowMilliseconds := (DateTimeToUnix(lNow, False) * 1000) + MilliSecondOf(lNow);
  SetLength(Result, fWindowCaptionOverrides.Count);
  i := 0;
  for lPair in fWindowCaptionOverrides do
  begin
    if not TryParseWindowCaptionOverrideKey(lPair.Key, lWnd, lProcessId) then
      Continue;
    if not fWindowCaptionOverrideRecords.TryGetValue(lPair.Key, lRecord) then
    begin
      lRecord := Default(TCaptionOverrideRecord);
      lRecord.CreatedAt := lNowMilliseconds;
      lRecord.UpdatedAt := lNowMilliseconds;
      lRecord.Reason := 'user_rename';
      lRecord.Identity.Hwnd := UInt64(NativeUInt(lWnd));
      lRecord.Identity.ProcessId := lProcessId;
    end;
    lRecord.Caption := lPair.Value;
    fWindowCaptionOverrideRecords.AddOrSetValue(lPair.Key, lRecord);
    Result[i] := lRecord;
    Inc(i);
  end;
  SetLength(Result, i);
end;

procedure TAppsViewMainFrm.RemoveStaleWindowCaptionOverrideRecords;
var
  i: Integer;
  lKeys: TArray<string>;
begin
  lKeys := fWindowCaptionOverrideRecords.Keys.ToArray;
  for i := 0 to High(lKeys) do
    if not fWindowCaptionOverrides.ContainsKey(lKeys[i]) then
      fWindowCaptionOverrideRecords.Remove(lKeys[i]);
end;

procedure TAppsViewMainFrm.SaveWindowCaptionOverrides;
var
  lState: TCaptionOverrideState;
begin
  if (not Assigned(fRenameJournalWriter)) or
    (not Assigned(fWindowCaptionOverrideRecords)) or
    (not Assigned(fWindowCaptionOverrides)) then
    Exit;
  RemoveStaleWindowCaptionOverrideRecords;
  lState := BuildWindowCaptionOverrideState;
  if not fRenameJournalWriter.SubmitOverrideState(lState) then
    LogStartupTiming('CaptionOverride.StateRejected', 'state snapshot rejected during shutdown');
end;

procedure TAppsViewMainFrm.ApplyLoadedWindowCaptionOverrideState;
var
  lKey: string;
  lRecord: TCaptionOverrideRecord;
  lState: TCaptionOverrideState;
  lStatus: TCaptionOverrideStateLoadStatus;
begin
  if (not Assigned(fRenameJournalWriter)) or
    (not fRenameJournalWriter.TryTakeLoadedOverrideState(lState, lStatus)) then
    Exit;
  for lRecord in lState do
  begin
    lKey := BuildWindowCaptionOverrideKey(
      HWND(NativeUInt(lRecord.Identity.Hwnd)),
      lRecord.Identity.ProcessId);
    if not fWindowCaptionOverrides.ContainsKey(lKey) then
    begin
      fWindowCaptionOverrides.Add(lKey, lRecord.Caption);
      fWindowCaptionOverrideRecords.AddOrSetValue(lKey, lRecord);
    end;
  end;
  if lStatus = coslsUpgraded then
    LogStartupTiming('CaptionOverride.StateUpgraded', Format('count=%d', [Length(lState)]));
end;

procedure TAppsViewMainFrm.WindowActionListBoxContextPopup(aSender: TObject; aMousePos: TPoint;
  var aHandled: Boolean);
var
  lItemIndex: Integer;
  lListBox: TListBox;
begin
  if not (aSender is TListBox) then
    Exit;

  lListBox := TListBox(aSender);
  if (aMousePos.X >= 0) and (aMousePos.Y >= 0) then
  begin
    lItemIndex := lListBox.ItemAtPos(aMousePos, True);
    if lItemIndex < 0 then
    begin
      ClearWindowActionTarget;
      fWindowActionSourceListBox := lListBox;
      Exit;
    end;
    SelectListBoxItemIndex(lListBox, lItemIndex);
  end;
  if not CaptureWindowActionTarget(lListBox) then
    fWindowActionSourceListBox := lListBox;
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
  lOldItemIndex: Integer;
  lOldWnd: hWnd;
  lProcessId: Cardinal;
  lRemoved: Boolean;
  lWnd: hWnd;
begin
  if not Assigned(aListBox) then
    Exit;

  lOldItemIndex := aListBox.ItemIndex;
  lOldWnd := 0;
  if (lOldItemIndex >= 0) and (lOldItemIndex < aListBox.Items.Count) then
    lOldWnd := hWnd(aListBox.Items.Objects[lOldItemIndex]);
  lRemoved := False;

  aListBox.Items.BeginUpdate;
  try
    for lIndex := aListBox.Items.Count - 1 downto 0 do
    begin
      lWnd := hWnd(aListBox.Items.Objects[lIndex]);
      if lWnd = 0 then
      begin
        aListBox.Items.Delete(lIndex);
        lRemoved := True;
        Continue;
      end;
      if not IsWindow(lWnd) then
      begin
        aListBox.Items.Delete(lIndex);
        lRemoved := True;
        Continue;
      end;

      lProcessId := 0;
      GetWindowThreadProcessId(lWnd, lProcessId);
      if (lProcessId = 0) or (not IsProcessActive(lProcessId)) then
      begin
        aListBox.Items.Delete(lIndex);
        lRemoved := True;
      end;
    end;
  finally
    aListBox.Items.EndUpdate;
  end;

  if lRemoved then
    aListBox.ItemIndex := CalculateWindowItemIndexAfterValidation(aListBox.Items, lOldItemIndex, lOldWnd);
end;

procedure TAppsViewMainFrm.RemoveWindowFromListBox(const aListBox: TListBox; const aWnd: hWnd);
var
  lIndex: Integer;
  lItemIndex: Integer;
  lRemovedIndex: Integer;
begin
  if (not Assigned(aListBox)) or (aWnd = 0) then
    Exit;

  lRemovedIndex := -1;

  aListBox.Items.BeginUpdate;
  try
    for lIndex := aListBox.Items.Count - 1 downto 0 do
    begin
      if hWnd(aListBox.Items.Objects[lIndex]) = aWnd then
      begin
        aListBox.Items.Delete(lIndex);
        lRemovedIndex := lIndex;
      end;
    end;
  finally
    aListBox.Items.EndUpdate;
  end;

  if lRemovedIndex <> -1 then
  begin
    lItemIndex := CalculateItemIndexAfterDeletingIndex(aListBox.Items.Count, lRemovedIndex);
    SelectListBoxItemIndex(aListBox, lItemIndex);
    TThread.Queue(TThread(nil),
      procedure
      begin
        if not IsShuttingDown then
          SelectListBoxItemIndex(aListBox, lItemIndex);
      end);
  end;
end;

procedure TAppsViewMainFrm.RemoveWindowFromUiAndCache(const aWnd: hWnd);
begin
  if aWnd = 0 then
    Exit;

  RemoveWindowFromSnapshots(aWnd);
  RemoveWindowFromListBox(lbApps, aWnd);
  RemoveWindowFromListBox(lbExplorer, aWnd);
  RemoveWindowFromListBox(lbConsole, aWnd);
  UpdateAppDetail(False);
end;

procedure TAppsViewMainFrm.SelectListBoxItemIndex(const aListBox: TListBox; const aItemIndex: Integer);
var
  lItemIndex: Integer;
begin
  if not Assigned(aListBox) then
    Exit;

  lItemIndex := aItemIndex;
  if aListBox.Items.Count = 0 then
    lItemIndex := -1
  else if lItemIndex >= aListBox.Items.Count then
    lItemIndex := aListBox.Items.Count - 1;

  aListBox.ItemIndex := lItemIndex;
  if lItemIndex >= 0 then
    aListBox.TopIndex := lItemIndex;
end;

procedure TAppsViewMainFrm.RemoveWindowFromSnapshots(const aWnd: hWnd);
begin
  if aWnd = 0 then
    Exit;

  ActiveAppViewMainForm.RemoveWindowFromSnapshots(fSharedAppsSnapshot, aWnd);
  ActiveAppViewMainForm.RemoveWindowFromSnapshots(fChatMonitorSnapshot, aWnd);
  if Assigned(fWindowService) then
    fWindowService.RemoveWindow(aWnd);
end;

procedure TAppsViewMainFrm.ScheduleWindowActionCleanup(const aWnd: hWnd; const aProcessId: Cardinal);
var
  lThread: TThread;
begin
  if IsShuttingDown or (aWnd = 0) then
    Exit;

  lThread := TThread.CreateAnonymousThread(
    procedure
    var
      lElapsedMs: Cardinal;
    begin
      lElapsedMs := 0;
      while (not IsShuttingDown) and (lElapsedMs < cWindowActionProbeMaxDurationMs) do
      begin
        TThread.Sleep(cWindowActionProbeIntervalMs);
        Inc(lElapsedMs, cWindowActionProbeIntervalMs);
        if (not IsWindow(aWnd)) or ((aProcessId <> 0) and (not IsProcessActive(aProcessId))) then
        begin
          TThread.Synchronize(nil,
            procedure
            begin
              if not IsShuttingDown then
                RemoveWindowFromUiAndCache(aWnd);
            end);
          Exit;
        end;
      end;
    end);
  lThread.FreeOnTerminate := True;
  lThread.Start;
end;

procedure TAppsViewMainFrm.BringToFrontFocusedApp(lb: TListBox);
var
  lTarget: TWindowActionTarget;
begin
  if not GetSelectedWindowInfo(lb, lTarget.Wnd, lTarget.ProcessId) then
    Exit;
  TThread.CreateAnonymousThread(
    procedure
    begin
      if IsWindowIdentityCurrent(lTarget.Wnd, lTarget.ProcessId) then
        maxLogic.Windows.Desktop.ForceForegroundWindow(lTarget.Wnd);
    end).Start;
end;

procedure TAppsViewMainFrm.TerminateWindowTarget(
  const aTarget: TWindowActionTarget);
var
  lProcessHandle: THandle;
  lProcessId: Cardinal;
  lWnd: hWnd;
begin
  if not TryResolveWindowActionTarget(
    aTarget,
    IsWindowIdentityCurrent,
    lWnd,
    lProcessId) then
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
end;

procedure TAppsViewMainFrm.WindowActionsPopupMenuPopup(aSender: TObject);
var
  lCanCaptionOverride: Boolean;
  lCanWindowAction: Boolean;
  lHasWindow: Boolean;
  lListBox: TListBox;
begin
  lListBox := GetPopupSourceListBox;
  lHasWindow := PrepareWindowActionTargetForPopup(lListBox);
  lCanCaptionOverride := lHasWindow and
    IsCaptionOverrideListBox(lListBox);
  lCanWindowAction := lHasWindow and IsWindowActionListBox(lListBox, lbApps, lbExplorer, lbConsole);

  if Assigned(fCloseWindowMenuItem) then
    fCloseWindowMenuItem.Enabled := lCanWindowAction;
  if Assigned(fCopyFullExeCommandLineMenuItem) then
    fCopyFullExeCommandLineMenuItem.Enabled := lCanWindowAction;
  if Assigned(fCopyFullExeFileNameMenuItem) then
    fCopyFullExeFileNameMenuItem.Enabled := lCanWindowAction;
  if Assigned(fCopyHwndMenuItem) then
    fCopyHwndMenuItem.Enabled := lCanWindowAction;
  if Assigned(fCopyPidMenuItem) then
    fCopyPidMenuItem.Enabled := lCanWindowAction;
  if Assigned(fRenameWindowMenuItem) then
    fRenameWindowMenuItem.Enabled := lCanCaptionOverride;
  if Assigned(fTerminateWindowMenuItem) then
    fTerminateWindowMenuItem.Enabled := lCanWindowAction;
end;

function TAppsViewMainFrm.PrepareWindowActionTargetForPopup(
  const aListBox: TListBox): Boolean;
begin
  if not Assigned(aListBox) then
  begin
    ClearWindowActionTarget;
    Exit(False);
  end;
  if not Assigned(fWindowActionSourceListBox) then
    Exit(CaptureWindowActionTarget(aListBox));
  if fWindowActionSourceListBox <> aListBox then
  begin
    ClearWindowActionTarget;
    Exit(False);
  end;

  Result := (fWindowActionTarget.Wnd <> 0) and
    IsWindowIdentityCurrent(
      fWindowActionTarget.Wnd,
      fWindowActionTarget.ProcessId);
  if not Result then
    ClearWindowActionTarget;
end;

procedure TAppsViewMainFrm.WindowCloseMenuItemClick(aSender: TObject);
var
  lListBox: TListBox;
  lTarget: TWindowActionTarget;
begin
  if ConsumeWindowActionTarget(lListBox, lTarget) and
    Assigned(lListBox) then
    CloseWindowTarget(lTarget);
end;

procedure TAppsViewMainFrm.CopyTextToWindowActionClipboard(
  const aText: string);
begin
  if Assigned(fWindowActionClipboardWriter) then
    fWindowActionClipboardWriter(aText)
  else
    Clipboard.AsText := aText;
end;

procedure TAppsViewMainFrm.WindowCopyMenuItemClick(aSender: TObject);
var
  lListBox: TListBox;
  lTarget: TWindowActionTarget;
  lText: string;
  lWindow: TWindowSnapshot;
begin
  if not (aSender is TMenuItem) then
    Exit;
  if not ConsumeWindowActionTarget(lListBox, lTarget) then
    Exit;
  if not Assigned(lListBox) then
    Exit;
  fPendingCopy := Default(TWindowSnapshot);
  lText := '';
  case TMenuItem(aSender).Tag of
    cWindowActionCopyProcessIdTag:
      lText := lTarget.ProcessId.ToString;
    cWindowActionCopyWindowHandleTag:
      lText := UIntToStr(NativeUInt(lTarget.Wnd));
    cWindowActionCopyExecutableFileNameTag:
      if TryGetWindowSnapshot(lTarget.Wnd, lWindow) and (lWindow.PID = lTarget.ProcessId) then
        lText := lWindow.FileName
      else
        lText := maxLogic.Windows.Desktop.GetFileName(lTarget.Wnd);
    cWindowActionCopyCommandLineTag:
    begin
      fPendingCopy.Wnd := lTarget.Wnd;
      fPendingCopy.PID := lTarget.ProcessId;
      fPendingClipboardSequence := GetClipboardSequenceNumber;
      TryGetProcessStartedAtUtcMilliseconds(lTarget.ProcessId, fPendingCopy.ProcessStartedAt);
      if TryGetWindowSnapshot(lTarget.Wnd, lWindow) then
        fPendingCopy.CommandLineAttemptedAt := lWindow.CommandLineAttemptedAt;
      TryPublishPendingWindowCopy;
      if (fPendingCopy.Wnd <> 0) and Assigned(fWindowService) then
      begin
        fWindowService.RequestCopyMetadata(fPendingCopy);
        QueueGuiRefresh;
      end;
      Exit;
    end;
  else
    Exit;
  end;
  if (lText <> '') and IsWindowIdentityCurrent(lTarget.Wnd, lTarget.ProcessId) then
    CopyTextToWindowActionClipboard(lText);
end;

procedure TAppsViewMainFrm.TryPublishPendingWindowCopy;
var
  lWindow: TWindowSnapshot;
  lStartedAt: Int64;
begin
  if fPendingCopy.Wnd = 0 then
    Exit;
  if GetClipboardSequenceNumber <> fPendingClipboardSequence then
  begin
    fPendingCopy := Default(TWindowSnapshot);
    Exit;
  end;
  if not IsWindowIdentityCurrent(fPendingCopy.Wnd, fPendingCopy.PID) then
  begin
    fPendingCopy := Default(TWindowSnapshot);
    Exit;
  end;
  if not TryGetWindowSnapshot(fPendingCopy.Wnd, lWindow) then
    Exit;
  lStartedAt := 0;
  TryGetProcessStartedAtUtcMilliseconds(lWindow.PID, lStartedAt);
  if (not SameWindowSnapshotIdentity(fPendingCopy, lWindow)) or
    (lStartedAt <> fPendingCopy.ProcessStartedAt) then
  begin
    fPendingCopy := Default(TWindowSnapshot);
    Exit;
  end;
  if lWindow.MetadataReady or (wmCommandLine in lWindow.AvailableMetadata) then
  begin
    fPendingCopy := Default(TWindowSnapshot);
    if lWindow.CommandLine <> '' then
      CopyTextToWindowActionClipboard(lWindow.CommandLine);
  end else if (lWindow.CommandLineError <> '') and
    (lWindow.CommandLineAttemptedAt > fPendingCopy.CommandLineAttemptedAt) then
  begin
    LogStartupTiming('Clipboard.MetadataFailed', lWindow.CommandLineError);
    fPendingCopy := Default(TWindowSnapshot);
  end;
end;

procedure TAppsViewMainFrm.ApplyWindowCaptionRename(const aWnd: hWnd;
  const aProcessId: Cardinal; const aCaption: string);
var
  lEvent: TCaptionOverrideLifecycleEvent;
  lIdentity: TCaptionOverrideIdentity;
  lOccurredAt: Int64;
  lRecord: TCaptionOverrideRecord;
begin
  lOccurredAt := CurrentUtcUnixMilliseconds;
  lIdentity := BuildWindowCaptionOverrideIdentity(aWnd, aProcessId);
  if BuildRenameCaptionOverrideTransition(
    lIdentity,
    aCaption,
    lOccurredAt,
    lRecord,
    lEvent) then
  begin
    fWindowCaptionOverrideRecords.AddOrSetValue(
      BuildWindowCaptionOverrideKey(aWnd, aProcessId),
      lRecord);
    JournalWindowCaptionOverride(lEvent);
  end;
  SaveWindowCaptionOverrides;
end;

procedure TAppsViewMainFrm.ApplyWindowCaptionReset(const aWnd: hWnd;
  const aProcessId: Cardinal);
var
  lEvent: TCaptionOverrideLifecycleEvent;
  lKey: string;
  lRecord: TCaptionOverrideRecord;
begin
  lKey := BuildWindowCaptionOverrideKey(aWnd, aProcessId);
  if fWindowCaptionOverrideRecords.TryGetValue(lKey, lRecord) and
    BuildEndCaptionOverrideTransition(
      lRecord,
      TCaptionOverrideEventKind.coekReset,
      CurrentUtcUnixMilliseconds,
      'user_reset',
      lEvent) then
    JournalWindowCaptionOverride(lEvent);
  fWindowCaptionOverrideRecords.Remove(lKey);
  SaveWindowCaptionOverrides;
end;

procedure TAppsViewMainFrm.WindowRenameMenuItemClick(aSender: TObject);
var
  lCaption: string;
  lDialogOutcome: TCaptionOverrideDialogOutcome;
  lListBox: TListBox;
  lTarget: TWindowActionTarget;
begin
  if not ConsumeWindowActionTarget(lListBox, lTarget) then
    Exit;
  if not IsCaptionOverrideListBox(lListBox) then
    Exit;

  lCaption := BuildWindowRenameDefaultCaption(
    fWindowCaptionOverrides,
    lTarget.Wnd,
    lTarget.ProcessId,
    maxLogic.Windows.Desktop.GetWinCaption(lTarget.Wnd),
    lTarget.DisplayCaption);
  lDialogOutcome := Default(TCaptionOverrideDialogOutcome);
  try
    lDialogOutcome := ExecuteCaptionOverrideDialogWithInitialCaption(Self, lCaption, ExecuteCaptionOverrideDialog);
    case ApplyWindowCaptionDialogOutcome(
      fWindowCaptionOverrides,
      lTarget.Wnd,
      lTarget.ProcessId,
      lDialogOutcome,
      IsWindowIdentityCurrent) of
      wcdarRenamed:
      begin
        ApplyWindowCaptionRename(
          lTarget.Wnd,
          lTarget.ProcessId,
          lDialogOutcome.Caption);
        QueueGuiRefresh;
      end;
      wcdarReset:
      begin
        ApplyWindowCaptionReset(lTarget.Wnd, lTarget.ProcessId);
        QueueGuiRefresh;
      end;
      wcdarStale:
      begin
        LogStartupTiming(
          'RenameWindow.StaleIdentity',
          Format(
            'hwnd=%d pid=%d',
            [NativeUInt(lTarget.Wnd), lTarget.ProcessId]));
        QueueGuiRefresh;
      end;
    end;
  finally
    if lDialogOutcome.DialogResult <> codCancel then
      SuppressNextReturnKey(lListBox);
    RestoreFocusAfterWindowCaptionDialog(lListBox);
  end;
end;

procedure TAppsViewMainFrm.WindowTerminateMenuItemClick(aSender: TObject);
var
  lListBox: TListBox;
  lTarget: TWindowActionTarget;
begin
  if ConsumeWindowActionTarget(lListBox, lTarget) and
    Assigned(lListBox) then
    TerminateWindowTarget(lTarget);
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
    lSnapshot.Scripts := BuildScriptsSnapshotForFolder(lScriptsDir);

    Result := lSnapshot;
  except
    lSnapshot.Free;
    raise;
  end;
end;

function ListRowKey(const aItems: TStrings; const aIndex: Integer;
  const aOwnsData: Boolean): string;
begin
  if aOwnsData then
    Result := aItems[aIndex] + #0 + TListBoxItemData(aItems.Objects[aIndex]).Value
  else if Assigned(aItems.Objects[aIndex]) then
    Result := UIntToStr(NativeUInt(aItems.Objects[aIndex]))
  else
    Result := aItems[aIndex];
end;

procedure SynchronizeListItems(const aListBox: TListBox; const aDesired: TStrings;
  const aOwnsData: Boolean = False);
var
  lCounts: TDictionary<string, Integer>;
  lCount: Integer;
  lData: TObject;
  lKey: string;
  lSelectedKey: string;
  lTopKey: string;
  lOldIndex: Integer;
  lOldTop: Integer;
  lSelectedIndex: Integer;
  lTopIndex: Integer;
  lEqual: Boolean;
  i, j: Integer;
begin
  lEqual := aListBox.Items.Count = aDesired.Count;
  if lEqual then
    for i := 0 to aDesired.Count - 1 do
      if (aListBox.Items[i] <> aDesired[i]) or
        (ListRowKey(aListBox.Items, i, aOwnsData) <> ListRowKey(aDesired, i, aOwnsData)) then
      begin
        lEqual := False;
        Break;
      end;
  if lEqual then
    Exit;
  lOldIndex := aListBox.ItemIndex;
  lOldTop := aListBox.TopIndex;
  lSelectedKey := '';
  lTopKey := '';
  if lOldIndex >= 0 then
    lSelectedKey := ListRowKey(aListBox.Items, lOldIndex, aOwnsData);
  if (lOldTop >= 0) and (lOldTop < aListBox.Items.Count) then
    lTopKey := ListRowKey(aListBox.Items, lOldTop, aOwnsData);
  lCounts := TDictionary<string, Integer>.Create(TFastCaseAwareComparer.Ordinal);
  try
    for i := 0 to aDesired.Count - 1 do
    begin
      lKey := ListRowKey(aDesired, i, aOwnsData);
      if not lCounts.TryGetValue(lKey, lCount) then
        lCount := 0;
      lCounts.AddOrSetValue(lKey, lCount + 1);
    end;
    aListBox.Items.BeginUpdate;
    try
      for i := aListBox.Items.Count - 1 downto 0 do
      begin
        lKey := ListRowKey(aListBox.Items, i, aOwnsData);
        if lCounts.TryGetValue(lKey, lCount) and (lCount > 0) then
          lCounts[lKey] := lCount - 1
        else
        begin
          if aOwnsData then
            aListBox.Items.Objects[i].Free;
          aListBox.Items.Delete(i);
        end;
      end;
      for i := 0 to aDesired.Count - 1 do
      begin
        lKey := ListRowKey(aDesired, i, aOwnsData);
        j := i;
        while (j < aListBox.Items.Count) and
          (ListRowKey(aListBox.Items, j, aOwnsData) <> lKey) do
          Inc(j);
        if j < aListBox.Items.Count then
        begin
          if j <> i then
          begin
            lData := aListBox.Items.Objects[j];
            aListBox.Items.Delete(j);
            aListBox.Items.InsertObject(i, aDesired[i], lData);
          end else if aListBox.Items[i] <> aDesired[i] then
            aListBox.Items[i] := aDesired[i];
        end else begin
          if aOwnsData then
            lData := TListBoxItemData.Create(TListBoxItemData(aDesired.Objects[i]).Value)
          else
            lData := aDesired.Objects[i];
          aListBox.Items.InsertObject(i, aDesired[i], lData);
        end;
      end;
      lSelectedIndex := -1;
      lTopIndex := -1;
      for i := 0 to aListBox.Items.Count - 1 do
      begin
        lKey := ListRowKey(aListBox.Items, i, aOwnsData);
        if (lSelectedIndex < 0) and (lKey = lSelectedKey) then
          lSelectedIndex := i;
        if (lTopIndex < 0) and (lKey = lTopKey) then
          lTopIndex := i;
      end;
      if lSelectedIndex < 0 then
      begin
        lSelectedIndex := lOldIndex;
        if lSelectedIndex >= aListBox.Items.Count then
          lSelectedIndex := aListBox.Items.Count - 1;
      end;
      if aListBox.ItemIndex <> lSelectedIndex then
        aListBox.ItemIndex := lSelectedIndex;
      if lTopIndex < 0 then
        lTopIndex := lOldTop;
      if (lTopIndex >= 0) and (lTopIndex < aListBox.Items.Count) then
        aListBox.TopIndex := lTopIndex;
    finally
      aListBox.Items.EndUpdate;
    end;
  finally
    lCounts.Free;
  end;
end;

procedure ApplyNamedListSnapshot(const aListBox: TListBox; const aItems: TNamedValueArray);
var
  lDesired: TStringList;
  lItem: TNamedValue;
  i: Integer;
begin
  lDesired := TStringList.Create;
  try
    lDesired.Sorted := aListBox.Sorted;
    lDesired.Duplicates := dupAccept;
    for lItem in aItems do
      lDesired.AddObject(lItem.Name, TListBoxItemData.Create(lItem.Value));
    SynchronizeListItems(aListBox, lDesired, True);
  finally
    for i := 0 to lDesired.Count - 1 do
      lDesired.Objects[i].Free;
    lDesired.Free;
  end;
end;

procedure TAppsViewMainFrm.ApplyDesktopSnapshot(const aItems: TNamedValueArray);
begin
  ApplyNamedListSnapshot(lbDesktop, aItems);
end;

procedure TAppsViewMainFrm.ApplyShortCutsSnapshot(const aItems: TNamedValueArray);
begin
  ApplyNamedListSnapshot(lbShortCuts, aItems);
end;

procedure TAppsViewMainFrm.ApplyScriptsSnapshot(const aScripts: TStringArray);
var
  lDesired: TStringList;
  lScript: string;
begin
  lDesired := TStringList.Create;
  try
    lDesired.Sorted := lbScripts.Sorted;
    lDesired.Duplicates := dupAccept;
    for lScript in aScripts do
      lDesired.Add(lScript);
    SynchronizeListItems(lbScripts, lDesired);
  finally
    lDesired.Free;
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






procedure TAppsViewMainFrm.StartStartupDataLoad;
begin
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.QueueGuiRefresh;
begin
  if IsShuttingDown or (TInterlocked.CompareExchange(fGuiRefreshQueued, 1, 0) <> 0) then
    Exit;
  if not PostMessage(Handle, cWindowRefreshMessage, 0, 0) then
    TInterlocked.Exchange(fGuiRefreshQueued, 0);
end;

procedure TAppsViewMainFrm.WMWindowRefresh(var aMessage: TMessage);
begin
  TInterlocked.Exchange(fGuiRefreshQueued, 0);
  if IsShuttingDown then
    Exit;
  if Assigned(fWindowService) then
    fWindowService.RequestRefresh;
end;

procedure TAppsViewMainFrm.WMWindowSnapshot(var aMessage: TMessage);
var
  lBatch: TWindowSnapshotBatch;
  lOldWindow: TWindowSnapshot;
  lWindow: TWindowSnapshot;
  lWatch: TStopwatch;
begin
  lWatch := TStopwatch.StartNew;
  try
    if IsShuttingDown or (not Assigned(fWindowService)) then
      Exit;
    if not fWindowService.TryTake(lBatch) then
      Exit;
    if lBatch.ErrorText <> '' then
      LogStartupTiming('WindowSnapshot.Error', lBatch.ErrorText);
    for lWindow in lBatch.Windows do
      if (lWindow.MetadataError <> '') and
        ((not TryGetWindowSnapshot(lWindow.Wnd, lOldWindow)) or
         (lOldWindow.MetadataAttemptedAt <> lWindow.MetadataAttemptedAt)) then
        LogStartupTiming('WindowMetadata.Error', Format('pid=%d hwnd=%s %s',
          [lWindow.PID, UIntToStr(NativeUInt(lWindow.Wnd)), lWindow.MetadataError]));
    fWindowBatch := lBatch;
    TryPublishPendingWindowCopy;
    TInterlocked.Exchange(fStartupDataReady, 1);
    RebuildSharedAppsSnapshot;
    tmrChatMonitor.Enabled := ShouldEnableSharedTimer(fWindowTitlePollingIntervalMs,
      fChatMonitorConfiguredEnabled, fChatMonitorIntervalMs, fMachineOverviewEnabled);
    UpdateGui;
    ResumeChatMonitorAfterSnapshot;
  finally
    RecordSlowUiOperation('WindowSnapshot', lWatch.Elapsed.TotalMilliseconds);
  end;
end;

procedure TAppsViewMainFrm.ResumeChatMonitorAfterSnapshot;
begin
  if fWindowBatch.ErrorText <> '' then
    Exit;
  if (TInterlocked.CompareExchange(fChatMonitorPending, 0, 0) <> 0) and
    (TInterlocked.CompareExchange(fChatMonitorBusy, 0, 0) = 0) then
    StartChatMonitorProcessing;
end;

function TAppsViewMainFrm.TryGetWindowSnapshot(const aWnd: HWND;
  out aWindow: TWindowSnapshot): Boolean;
var
  lWindow: TWindowSnapshot;
begin
  for lWindow in fWindowBatch.Windows do
    if lWindow.Wnd = aWnd then
    begin
      aWindow := lWindow;
      Exit(True);
    end;
  aWindow := Default(TWindowSnapshot);
  Result := False;
end;

function ShortCutPathExists(const aPath: string): Boolean;
begin
  Result := FileExists(aPath) or DirectoryExists(aPath);
end;

function FindExistingUnquotedShortCutPathEnd(const aText: string): Integer;
var
  i: Integer;
  lCandidate: string;
begin
  if ShortCutPathExists(aText) then
    Exit(Length(aText));

  for i := Length(aText) downto 1 do
  begin
    if CharInSet(aText[i], [' ', #9]) then
    begin
      lCandidate := Trim(Copy(aText, 1, i - 1));
      if (lCandidate <> '') and ShortCutPathExists(lCandidate) then
        Exit(Length(lCandidate));
    end;
  end;

  Result := 0;
end;

function FindFirstShortCutWhitespace(const aText: string): Integer;
var
  i: Integer;
begin
  for i := 1 to Length(aText) do
  begin
    if CharInSet(aText[i], [' ', #9]) then
      Exit(i);
  end;

  Result := 0;
end;

function LooksLikeFileSystemPath(const aText: string): Boolean;
begin
  Result := (Pos(':', aText) > 0) or (Pos('\', aText) > 0) or (Pos('/', aText) > 0)
    or StartsText('.', aText);
end;

function TryParseShortCutValue(const aValue: string; out aTargetPath: string; out aParams: string): boolean;
var
  lFirstToken: string;
  lValue: string;
  lPathEnd: integer;
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
    lPathEnd := FindExistingUnquotedShortCutPathEnd(lValue);
    if lPathEnd > 0 then
    begin
      aTargetPath := Copy(lValue, 1, lPathEnd);
      aParams := Trim(Copy(lValue, lPathEnd + 1, MaxInt));
    end
    else
    begin
      lPos := FindFirstShortCutWhitespace(lValue);
      if lPos > 0 then
      begin
        lFirstToken := Copy(lValue, 1, lPos - 1);
        if not LooksLikeFileSystemPath(lFirstToken) then
        begin
          aTargetPath := lFirstToken;
          aParams := Trim(Copy(lValue, lPos + 1, MaxInt));
        end
        else
          aTargetPath := lValue;
      end else begin
        aTargetPath := lValue;
      end;
    end;
  end;

  Result := aTargetPath <> '';
end;

procedure TAppsViewMainFrm.ActivateDesktopItem;
var
  lExitCode: Cardinal;
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

  if not TryLaunchPathIsolated(lPath, '', lExitCode) then
  begin
    MessageDlg(Format(rsLaunchFailed, [lPath]), mtWarning, [mbOK], 0);
    Exit;
  end;

  if not IsLaunchSuccessExitCode(lExitCode) then
    MessageDlg(Format(rsLaunchFailed, [lPath]), mtWarning, [mbOK], 0);
end;

procedure TAppsViewMainFrm.ActivateShortCutItem;
var
  lExitCode: Cardinal;
  lItem: TListBoxItemData;
  lTargetPath: string;
  lParams: string;
begin
  if lbShortCuts.ItemIndex < 0 then
    Exit;

  if not (lbShortCuts.Items.Objects[lbShortCuts.ItemIndex] is TListBoxItemData) then
    Exit;

  lItem := TListBoxItemData(lbShortCuts.Items.Objects[lbShortCuts.ItemIndex]);
  if not TryParseShortCutValue(lItem.Value, lTargetPath, lParams) then
    Exit;

  if not TryLaunchPathIsolated(lTargetPath, lParams, lExitCode) then
  begin
    MessageDlg(Format(rsLaunchFailed, [lTargetPath]), mtWarning, [mbOK], 0);
    Exit;
  end;

  if IsLaunchSuccessExitCode(lExitCode) then
    Exit;

  if IsLaunchMissingTargetExitCode(lExitCode) then
  begin
    MessageDlg(Format(rsShortCutTargetMissing, [lTargetPath]), mtWarning, [mbOK], 0);
    Exit;
  end;

  MessageDlg(Format(rsLaunchFailed, [lTargetPath]), mtWarning, [mbOK], 0);
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

procedure ApplyPrefixRuleForMetadata(var aTitle: string; const aCaption: string; const aFileName: string;
  const aAppUserModelID: string; const aCommandLineParams: string; const aRules: TPrefixRuleArray;
  const aAllowFileNameMatching: Boolean; const aAllowDeepMetadata: Boolean);
var
  lHasWindowIdentity: Boolean;
  lRule: TPrefixRule;
begin
  lHasWindowIdentity := aAllowDeepMetadata and (aAppUserModelID <> '');
  if TitleHasKnownDisplayPrefix(aTitle, aRules) then
    Exit;

  if lHasWindowIdentity then
  begin
    for lRule in aRules do
    begin
      if (lRule.AppUserModelIDMask <> '')
        and maxLogic.StrUtils.StringMatches(aAppUserModelID, lRule.AppUserModelIDMask, False) then
      begin
        ApplyDisplayPrefix(aTitle, lRule.Prefix);
        Exit;
      end;
    end;
  end;

  for lRule in aRules do
  begin
    if ((lRule.CaptionMask <> '') and maxLogic.StrUtils.StringMatches(aCaption, lRule.CaptionMask, False))
      or (aAllowFileNameMatching and (lRule.FileNameMask <> '')
      and maxLogic.StrUtils.StringMatches(aFileName, lRule.FileNameMask, False))
      or ((not lHasWindowIdentity) and aAllowDeepMetadata and (lRule.CmdParamsMask <> '')
      and maxLogic.StrUtils.StringMatches(aCommandLineParams, lRule.CmdParamsMask, False)) then
    begin
      ApplyDisplayPrefix(aTitle, lRule.Prefix);
      Exit;
    end;
  end;
end;

procedure TAppsViewMainFrm.CheckPrefixRule(var s: string; const aApp: TWindowSnapshot; const aRules: TPrefixRuleArray;
  aAllowFileNameMatching: Boolean; aAllowDeepMetadata: Boolean);
var
  lAppUserModelID: string;
  lCommandLineParams: string;
begin
  lAppUserModelID := '';
  lCommandLineParams := '';
  if aAllowDeepMetadata then
  begin
    lAppUserModelID := aApp.AppUserModelID;
    lCommandLineParams := aApp.CommandLineParams;
  end;

  ApplyPrefixRuleForMetadata(
    s,
    aApp.Caption,
    aApp.FileName,
    lAppUserModelID,
    lCommandLineParams,
    aRules,
    aAllowFileNameMatching,
    aAllowDeepMetadata);
end;

function TAppsViewMainFrm.ExcludeByMask(const aApp: TWindowSnapshot; const aMasks: TStringArray;
  aAllowFileNameMatching: Boolean): boolean;
var
  lMask: string;
begin
  Result := False;
  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(aApp.caption, lMask, False) then
      Exit(True);
  end;

  if not aAllowFileNameMatching then
    Exit(False);

  for lMask in aMasks do
  begin
    if maxLogic.StrUtils.StringMatches(aApp.FileName, lMask, False) then
      Exit(True);
  end;
end;

procedure TAppsViewMainFrm.FormActivate(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  ApplyLoadedWindowCaptionOverrideState;
  MarkFormFocused;
  if TInterlocked.CompareExchange(fStartupDataReady, 0, 0) = 0 then
    StartStartupDataLoad
  else
    QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.ApplyProportionalColumnWidths;
var
  lAppsWidth: Integer;
  lConsoleWidth: Integer;
  lDesktopWidth: Integer;
  lExplorerWidth: Integer;
  lScriptsWidth: Integer;
  lShortCutsWidth: Integer;
begin
  CalculateProportionalColumnWidths(ColumnLayoutAvailableWidth, lAppsWidth, lExplorerWidth, lScriptsWidth,
    lConsoleWidth, lDesktopWidth, lShortCutsWidth);
  pnlApps.Width := lAppsWidth;
  pnlExplorer.Width := lExplorerWidth;
  pnlScripts.Width := lScriptsWidth;
  pnlConsole.Width := lConsoleWidth;
  pnlDesktop.Width := lDesktopWidth;
  pnlShortCuts.Width := lShortCutsWidth;
end;

function TAppsViewMainFrm.ColumnLayoutAvailableWidth: Integer;
begin
  Result := ClientWidth - ControlLayoutWidth(Splitter1) - ControlLayoutWidth(Splitter3) -
    ControlLayoutWidth(Splitter4) - ControlLayoutWidth(Splitter5) - ControlLayoutWidth(Splitter6);
  if pnlMachineOverview.Visible then
    Dec(Result, ControlLayoutWidth(splMachineOverview) +
      ControlLayoutWidth(pnlMachineOverview));
  if Result < 0 then
    Result := 0;
end;

function TAppsViewMainFrm.ControlLayoutWidth(const aControl: TControl): Integer;
begin
  Result := aControl.Width;
  if aControl.AlignWithMargins then
    Inc(Result, aControl.Margins.Left + aControl.Margins.Right);
end;

procedure TAppsViewMainFrm.btnMachineOverviewFreezeClick(aSender: TObject);
begin
  if Assigned(fMachineOverviewController) then
    SetMachineOverviewFrozen(not fMachineOverviewController.Frozen);
end;

procedure TAppsViewMainFrm.btnMachineOverviewFullViewClick(aSender: TObject);
begin
  if Assigned(fMachineOverviewLayout) then
    SetMachineOverviewFullView(not fMachineOverviewLayout.FullView);
end;

procedure TAppsViewMainFrm.btnMachineOverviewHelpClick(aSender: TObject);
begin
  ShowMachineOverviewHelp(Self, GetInstallDir);
end;

procedure TAppsViewMainFrm.CopyMachineOverviewDiagnostics;
var
  lText: string;
begin
  if not Assigned(fMachineOverviewController) then
    Exit;
  lText := fMachineOverviewController.FullDiagnosticCopyText;
  if not lText.IsEmpty then
    Clipboard.AsText := lText;
end;

procedure TAppsViewMainFrm.CopyMachineOverviewSelectedRow;
var
  lText: string;
begin
  if not Assigned(fMachineOverviewController) then
    Exit;
  lText := fMachineOverviewController.SelectedRowCopyText;
  if not lText.IsEmpty then
    Clipboard.AsText := lText;
end;

procedure TAppsViewMainFrm.OpenMachineOverviewIncidentHistory;
begin
  ShowMachineOverviewIncidentHistory(Self,
    fMachineOverviewHistoryDatabaseFileName);
  if lvMachineOverview.CanFocus then
    lvMachineOverview.SetFocus;
end;

function TAppsViewMainFrm.HandleMachineOverviewCommand(
  const aCommand: TMachineOverviewCommand): Boolean;
begin
  Result := fMachineOverviewEnabled and Assigned(fMachineOverviewController) and
    Assigned(fMachineOverviewLayout);
  if not Result then
    Exit;
  case aCommand of
    TMachineOverviewCommand.FocusPanel:
      lvMachineOverview.SetFocus;
    TMachineOverviewCommand.ToggleFullView:
      SetMachineOverviewFullView(not fMachineOverviewLayout.FullView);
    TMachineOverviewCommand.ToggleDisplayFrozen:
      SetMachineOverviewFrozen(not fMachineOverviewController.Frozen);
    TMachineOverviewCommand.CopySelectedRow:
    begin
      Result := pnlMachineOverview.ContainsControl(ActiveControl);
      if Result then
        CopyMachineOverviewSelectedRow;
    end;
    TMachineOverviewCommand.CopyFullDiagnostics:
    begin
      Result := pnlMachineOverview.ContainsControl(ActiveControl);
      if Result then
        CopyMachineOverviewDiagnostics;
    end;
  else
    Result := False;
  end;
end;

procedure TAppsViewMainFrm.RefreshMachineOverview;
var
  lPresentation: TMachineOverviewPresentation;
begin
  if (not fMachineOverviewEnabled) or
    (not Assigned(fMachineOverviewController)) or
    (not Assigned(fMachineOverviewService)) then
    Exit;
  if fMachineOverviewService.TryReadLatestPresentation(
    fLastMachineOverviewPublishedSequence, lPresentation) then
  begin
    fLastMachineOverviewPublishedSequence := lPresentation.Sequence;
    fMachineOverviewController.Publish(lPresentation);
  end;
end;

procedure TAppsViewMainFrm.SetMachineOverviewFrozen(const aValue: Boolean);
begin
  if not Assigned(fMachineOverviewController) then
    Exit;
  fMachineOverviewController.SetFrozen(aValue);
  if aValue then
    btnMachineOverviewFreeze.Caption := rsMachineOverviewResume
  else
    btnMachineOverviewFreeze.Caption := rsMachineOverviewFreeze;
end;

procedure TAppsViewMainFrm.SaveMachineOverviewLayout;
begin
  if (not fMachineOverviewEnabled) or
    (not Assigned(fMachineOverviewLayout)) then
    Exit;
  try
    SaveMachineOverviewPanelWidthToFile(CombinePath(
      [GetInstallDir, cSettingsFileName]),
      fMachineOverviewLayout.PanelWidthForPersistence, CurrentPPI);
  except
    on lException: Exception do
      LogStartupTiming('MachineOverview.LayoutSaveFailed',
        lException.ClassName + ': ' + lException.Message);
  end;
end;

procedure TAppsViewMainFrm.SetMachineOverviewFullView(const aValue: Boolean);
begin
  if not Assigned(fMachineOverviewLayout) then
    Exit;
  if aValue <> fMachineOverviewLayout.FullView then
    fMachineOverviewLayout.ToggleFullView;
  if aValue then
    btnMachineOverviewFullView.Caption := rsMachineOverviewRestoreView
  else
    btnMachineOverviewFullView.Caption := rsMachineOverviewFullView;
end;

procedure TAppsViewMainFrm.FormCreate(Sender: TObject);
var
  lChatMonitorCheckSeconds: Integer;
  lIniFile: TMemIniFile;
  lMachineOverviewSettings: TMachineOverviewSettings;
  lTimerIntervalMs: Cardinal;
  lWindowTitlePollingSeconds: Integer;
begin
  fStartupProfileLog := TStringList.Create;
  fStartupProfileLogSync := TCriticalSection.Create;
  fStartupProfileLogFileName := CombinePath([GetInstallDir, 'startup-profile.log']);
  fStartupProfileStartTick := TStopwatch.GetTimeStamp;
  TInterlocked.Exchange(fStartupProfileAuxReadyLogged, 0);
  TInterlocked.Exchange(fStartupProfileDeepPrefixGuiLogged, 0);
  TInterlocked.Exchange(fStartupProfileFullMetadataGuiLogged, 0);
  TInterlocked.Exchange(fStartupProfileWarmupDoneLogged, 0);
  fStartupProfileLog.Add('----------------------------------------');
  fStartupProfileLog.Add(Format('Run started at %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now)]));
  LogStartupTiming('FormCreate.Start');

  fConfigCache := TConfigCache.Create(GetInstallDir);
  fWindowCaptionOverrideRecords := TDictionary<string, TCaptionOverrideRecord>.Create;
  fWindowCaptionOverrides := TDictionary<string, string>.Create;
  fSuppressNextReturnListBox := nil;
  fSuppressNextReturnUntilTick := 0;
  CreateWindowActionsPopupMenu;
  AddToAutoStart;
  Screen.OnActiveControlChange := ActiveControlChanged;
  labAppTitle.Height := labTemplateActiv.Height;
  labExplorerTitle.Height := labTemplateActiv.Height;
  labScriptsTitle.Height := labTemplateActiv.Height;
  labConsoleTitle.Height := labTemplateActiv.Height;
  labDesktopTitle.Height := labTemplateActiv.Height;
  labShortCutsTitle.Height := labTemplateActiv.Height;
  labMachineOverviewTitle.Height := labTemplateActiv.Height;
  ActiveControlChanged(nil);
  ApplyProportionalColumnWidths;
  lbConsole.Sorted := False;
  fOrgAppOnActivate := application.OnActivate;
  application.OnActivate := AppOnActivate;

  gc(lIniFile, TMemIniFile.Create(CombinePath([GetInstallDir, cSettingsFileName]), TEncoding.Utf8, False));
  fFocusSoundFileName := LoadFocusSoundFileName(GetInstallDir, lIniFile);
  fShutdownToken := TCancelToken.Create;
  lMachineOverviewSettings := LoadMachineOverviewSettings(lIniFile);
  lMachineOverviewSettings.HistoryDatabaseFileName :=
    MachineOverviewHistoryDatabasePath(GetInstallDir);
  fMachineOverviewHistoryDatabaseFileName :=
    lMachineOverviewSettings.HistoryDatabaseFileName;
  fMachineOverviewEnabled := lMachineOverviewSettings.Enabled;
  fMachineOverviewDisplayRefreshIntervalMs := Cardinal(
    lMachineOverviewSettings.DisplayRefreshIntervalMs);
  fLastMachineOverviewPublishedSequence := 0;
  fLastMachineOverviewRefreshTick := 0;
  pnlMachineOverview.Width := ScaleMachineOverviewPanelWidth(
    lMachineOverviewSettings.PanelWidth, CurrentPPI);
  pnlMachineOverview.Visible := fMachineOverviewEnabled;
  splMachineOverview.Visible := fMachineOverviewEnabled;
  fMachineOverviewView := CreateMachineOverviewView(lvMachineOverview);
  fMachineOverviewController := TMachineOverviewDisplayController.Create(
    fMachineOverviewView);
  fMachineOverviewLayout := TMachineOverviewLayoutController.Create(
    [pnlApps, Splitter1, pnlExplorer, Splitter3, pnlScripts, Splitter4,
     pnlConsole, Splitter5, pnlDesktop, Splitter6, pnlShortCuts],
    pnlMachineOverview, splMachineOverview, lvMachineOverview);
  fMachineOverviewService := CreateMachineOverviewService(lMachineOverviewSettings);
  fMachineOverviewService.Start;
  fRenameJournalConfig := LoadRenameJournalConfig(lIniFile);
  fRenameJournalConfig.OverrideStateFileName := CombinePath(
    [GetInstallDir, cWindowCaptionOverridesFileName]);
  fRenameJournalWriter := TRenameJournalWriter.Create(fRenameJournalConfig, fShutdownToken);
  fChatMonitor := TChatMonitor.Create(lIniFile);
  fChatMonitor.UseConfigCache(fConfigCache);
  chkChatNotificationSound.Checked := lIniFile.ReadBool('ChatMonitor', 'SoundEnabled', True);
  fChatMonitorConfiguredEnabled := lIniFile.ReadBool('ChatMonitor', 'Enabled', False);
  chkChatNotificationSound.Enabled := fChatMonitorConfiguredEnabled;
  fChatMonitor.SoundEnabled := chkChatNotificationSound.Checked;
  lChatMonitorCheckSeconds := lIniFile.ReadInteger(
    cChatMonitorSectionName,
    cCheckIntervalSecondsKey,
    cDefaultIntervalSeconds);
  fChatMonitorIntervalMs := SecondsToIntervalMs(lChatMonitorCheckSeconds);
  lWindowTitlePollingSeconds := lIniFile.ReadInteger(
    cWindowTitlePollingSectionName,
    cWindowTitlePollingIntervalSecondsKey,
    cDefaultIntervalSeconds);
  fWindowTitlePollingIntervalMs := SecondsToIntervalMs(lWindowTitlePollingSeconds);
  lTimerIntervalMs := CalculateSharedTimerIntervalMs(
    fWindowTitlePollingIntervalMs,
    fChatMonitorConfiguredEnabled,
    fChatMonitorIntervalMs);
  if fMachineOverviewEnabled and
    ((lTimerIntervalMs = 0) or
     (fMachineOverviewDisplayRefreshIntervalMs < lTimerIntervalMs)) then
    lTimerIntervalMs := fMachineOverviewDisplayRefreshIntervalMs;
  if lTimerIntervalMs <> 0 then
    tmrChatMonitor.Interval := lTimerIntervalMs;
  tmrChatMonitor.Enabled := False;
  fLastChatMonitorTick := 0;
  fLastWindowTitlePollingTick := 0;
  SetLength(fSharedAppsSnapshot, 0);
  SetLength(fChatMonitorSnapshot, 0);
  fSharedAppsSnapshotTick := 0;
  TInterlocked.Exchange(fStartupDataReady, 0);
  TInterlocked.Exchange(fShuttingDown, 0);
  fWindowService := TWindowSnapshotService.Create(GetInstallDir, Handle);
  LogStartupTiming(
    'FormCreate.Done',
    Format('chatMonitorEnabled=%s chatSoundEnabled=%s',
      [BoolToStr(fChatMonitorConfiguredEnabled, True), BoolToStr(chkChatNotificationSound.Checked, True)]));
end;

procedure TAppsViewMainFrm.FormDestroy(Sender: TObject);
var
  lShutdownResult: TMachineOverviewShutdownResult;
begin
  LogStartupTiming('FormDestroy.Start');
  SaveMachineOverviewLayout;
  TInterlocked.Exchange(fShuttingDown, 1);
  if Assigned(fShutdownToken) then
    fShutdownToken.Cancel;
  tmrChatMonitor.Enabled := False;
  FreeAndNil(fWindowService);
  TInterlocked.Exchange(fChatMonitorPending, 0);
  TInterlocked.Exchange(fAuxListRefreshPending, 0);
  application.OnActivate := fOrgAppOnActivate;
  Screen.OnActiveControlChange := nil;

  RequestAsyncStop(fAuxListRefresh);
  RequestAsyncStop(fChatMonitorTask);
  if Assigned(fMachineOverviewService) then
  begin
    lShutdownResult := fMachineOverviewService.Stop(cShutdownTaskWaitTimeoutMs);
    if lShutdownResult = TMachineOverviewShutdownResult.TimedOut then
      LogStartupTiming('MachineOverview.Shutdown', 'bounded shutdown timed out');
  end;
  FreeAndNil(fRenameJournalWriter);

  WaitAsyncWithShutdown(fAuxListRefresh, cShutdownTaskWaitTimeoutMs);
  WaitAsyncWithShutdown(fChatMonitorTask, cShutdownTaskWaitTimeoutMs);

  FreeAndNil(fPendingAuxSnapshot);
  fAuxListRefresh := nil;
  fChatMonitorTask := nil;
  fMachineOverviewService := nil;
  FreeAndNil(fMachineOverviewLayout);
  FreeAndNil(fMachineOverviewController);
  fMachineOverviewView := nil;
  fShutdownToken := nil;
  ClearListBoxItemData(lbDesktop);
  ClearListBoxItemData(lbShortCuts);
  FreeAndNil(fChatMonitor);
  FreeAndNil(fConfigCache);
  FreeAndNil(fWindowCaptionOverrideRecords);
  FreeAndNil(fWindowCaptionOverrides);
  LogStartupTiming('FormDestroy.Flush');
  FlushStartupProfileLog;
  FreeAndNil(fStartupProfileLog);
  FreeAndNil(fStartupProfileLogSync);
end;

procedure TAppsViewMainFrm.FormKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  lMachineOverviewCommand: TMachineOverviewCommand;
begin
  if (Key = VK_F4) and ((GetTickCount64 - fLastFormFocusTick) < cIgnoreF4AfterFocusMs) then
  begin
    Key := 0;
    Exit;
  end;

  lMachineOverviewCommand := ResolveMachineOverviewCommand(Key, Shift);
  if (lMachineOverviewCommand <> TMachineOverviewCommand.None) and
    HandleMachineOverviewCommand(lMachineOverviewCommand) then
  begin
    Key := 0;
    Exit;
  end;

  if (Key = VK_RETURN) and (Shift = []) and fMachineOverviewEnabled and
    (ActiveControl = lvMachineOverview) and Assigned(fMachineOverviewView) and
    ShouldOpenMachineOverviewIncidentHistory(
      fMachineOverviewView.SelectedRowId) then
  begin
    OpenMachineOverviewIncidentHistory;
    Key := 0;
    Exit;
  end;

  if Key = VK_F5 then
  begin
    QueueGuiRefresh;
    StartAuxListsRefresh;
  end
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

procedure TAppsViewMainFrm.FormResize(Sender: TObject);
begin
  if Assigned(fMachineOverviewLayout) and fMachineOverviewLayout.FullView then
    Exit;
  ApplyProportionalColumnWidths;
end;

procedure TAppsViewMainFrm.FormShow(Sender: TObject);
begin
  if IsShuttingDown then
    Exit;

  LogStartupTiming('FormShow');
  ApplyProportionalColumnWidths;
  RefreshMachineOverview;
  StartAuxListsRefresh;
  StartStartupDataLoad;
  QueueGuiRefresh;
end;

function TAppsViewMainFrm.GetWnd(lb: TListBox): hwnd;
begin
  Result := 0;
  if not Assigned(lb) then
    Exit;
  if (lb.ItemIndex >= 0) and (lb.ItemIndex < lb.Items.Count) then
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
  if ShouldConsumeSuppressedReturnKey(Sender, Key) then
  begin
    Key := 0;
    Exit;
  end;

  if Key = VK_RETURN then
    BringToFrontFocusedApp(Sender as TListBox)
  else if (Key = Ord('W')) and (ssCtrl in Shift)
    and IsWindowActionListBox(Sender, lbApps, lbExplorer, lbConsole) then
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

procedure TAppsViewMainFrm.RecordSlowUiOperation(const aOperation: string; const aElapsedMs: Double);
const
  cSlowUiThresholdMs = 50;
  cMaxSlowUiSamples = 128;
begin
  if (aElapsedMs < cSlowUiThresholdMs) or (fSlowUiSampleCount > cMaxSlowUiSamples) or
    (fStartupProfileStartTick = 0) or (not Assigned(fStartupProfileLog)) or
    (not Assigned(fStartupProfileLogSync)) then
    Exit;
  Inc(fSlowUiSampleCount);
  if fSlowUiSampleCount > cMaxSlowUiSamples then
    LogStartupTiming('UI.Slow', 'sample limit reached')
  else
    LogStartupTiming('UI.Slow', Format('operation=%s durationMs=%d windows=%d',
      [aOperation, Round(aElapsedMs), Length(fWindowBatch.Windows)]));
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

  LogStartupTiming('Shutdown.WaitForAsync', Format('threadId=%d', [lThread.ThreadID]));
  TWaiter.WaitFor([aAsync], INFINITE, True);
end;

procedure TAppsViewMainFrm.RebuildSharedAppsSnapshot;
var
  i: Integer;
begin
  SetLength(fSharedAppsSnapshot, Length(fWindowBatch.Windows));
  for i := 0 to High(fWindowBatch.Windows) do
  begin
    fSharedAppsSnapshot[i].Wnd := fWindowBatch.Windows[i].Wnd;
    fSharedAppsSnapshot[i].Caption := fWindowBatch.Windows[i].Caption;
  end;
  fSharedAppsSnapshotTick := fWindowBatch.CollectedAt;
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

  if (fSharedAppsSnapshotTick = 0) or (GetTickCount64 - fSharedAppsSnapshotTick >= 900) then
  begin
    TInterlocked.Exchange(fChatMonitorPending, 1);
    QueueGuiRefresh;
    Exit;
  end;

  if TInterlocked.CompareExchange(fChatMonitorBusy, 1, 0) <> 0 then
  begin
    TInterlocked.Exchange(fChatMonitorPending, 1);
    Exit;
  end;

  TInterlocked.Exchange(fChatMonitorPending, 0);
  fChatMonitorSnapshot := Copy(fSharedAppsSnapshot);
  fChatMonitorTask := SimpleAsyncCall(RunChatMonitorSnapshot, 'ActiveAppView.ChatMonitor', OnChatMonitorDone);
end;

procedure TAppsViewMainFrm.RestoreItemIndex(lb: TListBox; wnd: hwnd;
  oldItemIndex: integer; const aOldItemCaption: string);
begin
  lb.ItemIndex := CalculateRestoredItemIndex(lb.Items, wnd, oldItemIndex, aOldItemCaption, lb.Sorted);
end;

procedure TObservedListBox.WndProc(var aMessage: TMessage);
begin
  case aMessage.Msg of
    LB_ADDSTRING, LB_INSERTSTRING, LB_DELETESTRING, LB_RESETCONTENT:
      Inc(MutationCount);
  end;
  inherited;
end;

function RunMainFormSelfTests(const aArg: string): Integer;
var
  lTestSettings: TMemIniFile;
  lObservedList: TObservedListBox;
  lDetailWatch: TStopwatch;
  lMaxApplyMs: Double;
  lApplyMs: Double;
  lNamedItems: TNamedValueArray;
  lOwnedData: TObject;
  lSample: Integer;
  lActualValue: string;
  lApps: TArray<TAppInfo>;
  lApplyResult: TWindowCaptionDialogApplyResult;
  lActionWnd: hWnd;
  lActionTarget: TWindowActionTarget;
  lAppsWidth: Integer;
  lCallCount: Integer;
  lCancelToken: iCancelToken;
  lCapturedListBox: TListBox;
  lConsoleWidth: Integer;
  lCopyPidMenuItem: TMenuItem;
  lDesktopWidth: Integer;
  lDialogOutcome: TCaptionOverrideDialogOutcome;
  lEvent: TCaptionOverrideLifecycleEvent;
  lExplorerWidth: Integer;
  lExpectedCaptions: TArray<string>;
  lExpectedValues: TArray<string>;
  lHandled: Boolean;
  lIndex: Integer;
  lItems: TStringList;
  lIdentity: TCaptionOverrideIdentity;
  lObservedIdentity: TCaptionOverrideIdentity;
  lOtherListBox: TListBox;
  lLoadedOverrides: TDictionary<string, string>;
  lMenuIndex: Integer;
  lMenuItem: TMenuItem;
  lMousePos: TPoint;
  lOverrideKey: string;
  lOverrides: TDictionary<string, string>;
  lParams: string;
  lPrefixRules: TPrefixRuleArray;
  lRecord: TCaptionOverrideRecord;
  lReplacementWnd: hWnd;
  lResultIndex: Integer;
  lResolvedProcessId: Cardinal;
  lResolvedWnd: hWnd;
  lScripts: TStringArray;
  lScriptsDir: string;
  lScriptNames: TStringList;
  lScriptsWidth: Integer;
  lShortCutsWidth: Integer;
  lSnapshots: TArray<TChatAppSnapshot>;
  lStateFileName: string;
  lTempDir: string;
  lTitle: string;
  lTargetPath: string;
  lTestForm: TAppsViewMainFrm;
  lTestListBox: TListBox;
  lTestOverrideKey: string;
  lTestApp: TAppInfo;
  lTestProcessId: Cardinal;
  lTestWnd: hWnd;
  lWasPruned: Boolean;
begin
  Result := -1;
  if SameText(aArg, '--self-test-ui-timing') then
  begin
    Result := 0;
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestForm.fStartupProfileLog := TStringList.Create;
      lTestForm.fStartupProfileLogSync := TCriticalSection.Create;
      lTestForm.fStartupProfileStartTick := TStopwatch.GetTimeStamp;
      lTestForm.RecordSlowUiOperation('Foreground', 49.9);
      if lTestForm.fStartupProfileLog.Count <> 0 then
        raise Exception.Create('Fast GUI operation was logged');
      lTestForm.RecordSlowUiOperation('Foreground', 50);
      if (lTestForm.fStartupProfileLog.Count <> 1) or
        (not ContainsText(lTestForm.fStartupProfileLog.Text, 'operation=Foreground durationMs=50 windows=0')) then
        raise Exception.Create('Slow GUI operation was not recorded with its duration and size');
      for lIndex := 1 to 200 do
        lTestForm.RecordSlowUiOperation('WindowSnapshot', 50 + lIndex);
      if (lTestForm.fStartupProfileLog.Count <> 129) or
        (not ContainsText(lTestForm.fStartupProfileLog[128], 'sample limit reached')) then
        raise Exception.Create('Slow GUI sample storage is not bounded');
      lTestForm.LogStartupTiming('OtherDiagnostic', 'still retained');
      if lTestForm.fStartupProfileLog.Count <> 130 then
        raise Exception.Create('Slow GUI budget affected other diagnostics');
      lTestForm.fStartupProfileLog.Clear;
      lTestForm.fSlowUiSampleCount := 0;
      lTestForm.fStartupDataReady := 1;
      lTestForm.fGuiRefreshQueued := 1;
      lTestForm.fAuxListRefreshBusy := 1;
      // Controlled foreground workload proves the real activation handler is timed.
      lTestForm.fFocusSoundPlayer :=
        procedure(aFileName: string)
        begin
          Sleep(60);
        end;
      lTestForm.AppOnActivate(lTestForm);
      if (lTestForm.fStartupProfileLog.Count <> 1) or
        (not ContainsText(lTestForm.fStartupProfileLog.Text, 'operation=Foreground')) then
        raise Exception.Create('Foreground handler did not record its slow workload');
      Writeln('UI TIMING PASS threshold=50ms samples=128 overflow=1 foreground=measured');
    except
      on E: Exception do
      begin
        Writeln('SELFTEST FAILED: ' + E.Message);
        Result := 1;
      end;
    end;
    FreeAndNil(lTestForm.fStartupProfileLog);
    FreeAndNil(lTestForm.fStartupProfileLogSync);
    lTestForm.Free;
    Exit;
  end;
  if SameText(aArg, '--self-test-window-details') then
  begin
    Result := 0;
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestForm.lbApps := TListBox.Create(lTestForm);
      lTestForm.lbApps.Parent := lTestForm;
      lTestForm.pnlAppDetails := TPanel.Create(lTestForm);
      lTestForm.imgAppScreenshot := TImage.Create(lTestForm);
      lTestForm.edAppCaption := TEdit.Create(lTestForm);
      lTestForm.edPid := TEdit.Create(lTestForm);
      lTestForm.edAppFileName := TEdit.Create(lTestForm);
      lTestForm.edCommandLineParams := TEdit.Create(lTestForm);
      lTestForm.edRelaunchCommand := TEdit.Create(lTestForm);
      lTestForm.edAppUserModelID := TEdit.Create(lTestForm);
      SetLength(lTestForm.fWindowBatch.Windows, 2);
      lTestForm.fWindowBatch.Windows[0].Wnd := 100;
      lTestForm.fWindowBatch.Windows[0].FileName := ParamStr(0);
      lTestForm.fWindowBatch.Windows[1].Wnd := 200;
      lTestForm.fWindowBatch.Windows[1].FileName := 'second.exe';
      lTestForm.lbApps.Items.AddObject('first', TObject(100));
      lTestForm.lbApps.Items.AddObject('second', TObject(200));
      lTestForm.lbApps.ItemIndex := 0;
      lDetailWatch := TStopwatch.StartNew;
      lTestForm.UpdateAppDetail;
      if (lTestForm.edAppFileName.Text <> ParamStr(0)) or
        (lDetailWatch.ElapsedMilliseconds > 50) then
      begin
        Writeln('SELFTEST FAILED: selection did not display the available snapshot promptly');
        Result := 1;
      end;
      lTestForm.lbApps.ItemIndex := 1;
      lTestForm.fWindowBatch.Windows[0].CommandLineParams := 'late result for first';
      lTestForm.fWindowBatch.Windows[0].MetadataReady := True;
      lTestForm.UpdateAppDetail(False);
      if (lTestForm.edAppFileName.Text <> 'second.exe') or
        (lTestForm.edCommandLineParams.Text <> '') then
      begin
        Writeln('SELFTEST FAILED: stale metadata replaced the current selection');
        Result := 1;
      end;
      lTestForm.lbExplorer := TListBox.Create(lTestForm);
      lTestForm.lbExplorer.Parent := lTestForm;
      lTestForm.lbConsole := TListBox.Create(lTestForm);
      lTestForm.lbConsole.Parent := lTestForm;
      // Foreground refresh applies to existing controls; time their creation separately.
      lDetailWatch := TStopwatch.StartNew;
      lTestForm.lbExplorer.HandleNeeded;
      lTestForm.lbConsole.HandleNeeded;
      Writeln(Format('GUI FIXTURE native-control-creation-ms=%.3f', [lDetailWatch.Elapsed.TotalMilliseconds]));
      lTestForm.fStartupDataReady := 1;
      SetLength(lTestForm.fWindowBatch.Windows, 500);
      for lIndex := 0 to High(lTestForm.fWindowBatch.Windows) do
      begin
        lTestForm.fWindowBatch.Windows[lIndex] := Default(TWindowSnapshot);
        lTestForm.fWindowBatch.Windows[lIndex].Wnd := HWND(NativeUInt(lIndex) + 1);
        lTestForm.fWindowBatch.Windows[lIndex].Caption := Format('Window %.3d', [lIndex]);
        lTestForm.fWindowBatch.Windows[lIndex].FileName := 'fixture.exe';
      end;
      lMaxApplyMs := 0;
      for lSample := 1 to 30 do
      begin
        lDetailWatch := TStopwatch.StartNew;
        lTestForm.UpdateGui;
        lApplyMs := lDetailWatch.Elapsed.TotalMilliseconds;
        if lSample <= 3 then
          Writeln(Format('GUI APPLY sample=%d ms=%.3f', [lSample, lApplyMs]));
        if (lSample = 1) or (lApplyMs > lMaxApplyMs) then
          lMaxApplyMs := lApplyMs;
      end;
      Writeln(Format('GUI APPLY windows=500 samples=30 max-ms=%.3f', [lMaxApplyMs]));
      if (lMaxApplyMs > 100) or (lTestForm.lbApps.Items.Count <> 500) then
      begin
        Writeln('SELFTEST FAILED: snapshot rendering exceeded the GUI budget or lost rows');
        Result := 1;
      end;
    finally
      lTestForm.Free;
    end;
    Exit;
  end;
  if SameText(aArg, '--self-test-list-sync') then
  begin
    Result := 0;
    try
      lTestForm := TAppsViewMainFrm.CreateNew(nil);
      try
        lObservedList := TObservedListBox.Create(lTestForm);
        lObservedList.Parent := lTestForm;
        lObservedList.Height := 60;
        lTestForm.lbScripts := lObservedList;
        SetLength(lExpectedCaptions, 80);
        for lIndex := 0 to High(lExpectedCaptions) do
          lExpectedCaptions[lIndex] := Format('Script %.3d', [lIndex]);
        lTestForm.ApplyScriptsSnapshot(lExpectedCaptions);
        lObservedList.ItemIndex := 40;
        lObservedList.TopIndex := 38;
        lObservedList.MutationCount := 0;
        lTestForm.ApplyScriptsSnapshot(lExpectedCaptions);
        if lObservedList.MutationCount <> 0 then
          raise Exception.Create('Unchanged snapshot mutated native list rows');
        if (lObservedList.ItemIndex <> 40) or (lObservedList.TopIndex <> 38) then
          raise Exception.Create('Unchanged snapshot moved selection or scroll');
        lExpectedCaptions[0] := 'Changed first script';
        lTestForm.ApplyScriptsSnapshot(lExpectedCaptions);
        if (lObservedList.ItemIndex <> 40) or (lObservedList.TopIndex <> 38) then
          raise Exception.Create('Changed snapshot moved an unaffected selection or top row');
        if lObservedList.MutationCount > 4 then
          raise Exception.Create('One changed row rebuilt unrelated rows');
        lTestForm.ApplyScriptsSnapshot(nil);
        if lObservedList.Items.Count <> 0 then
          raise Exception.Create('Empty snapshot retained stale rows');
        lItems := TStringList.Create;
        try
          lItems.AddObject('first', TObject(100));
          lItems.AddObject('second', TObject(200));
          SynchronizeListItems(lObservedList, lItems);
          lObservedList.ItemIndex := 1;
          lItems.Exchange(0, 1);
          lItems[0] := 'renamed second';
          SynchronizeListItems(lObservedList, lItems);
          if (lObservedList.ItemIndex <> 0) or (lObservedList.Items.Objects[0] <> TObject(200)) then
            raise Exception.Create('Reordering or renaming lost selected window identity');
          lItems.Clear;
          SynchronizeListItems(lObservedList, lItems);
        finally
          lItems.Free;
        end;
        SetLength(lNamedItems, 2);
        lNamedItems[0].Name := 'Same caption';
        lNamedItems[0].Value := 'first path';
        lNamedItems[1].Name := 'Same caption';
        lNamedItems[1].Value := 'second path';
        lObservedList.Sorted := True;
        try
          ApplyNamedListSnapshot(lObservedList, lNamedItems);
          for lIndex := 0 to lObservedList.Items.Count - 1 do
            if TListBoxItemData(lObservedList.Items.Objects[lIndex]).Value = 'second path' then
              lObservedList.ItemIndex := lIndex;
          lOwnedData := lObservedList.Items.Objects[lObservedList.ItemIndex];
          lNamedItems[0].Name := 'Changed caption';
          ApplyNamedListSnapshot(lObservedList, lNamedItems);
          if (lObservedList.Items.Objects[lObservedList.ItemIndex] <> lOwnedData) or
            (TListBoxItemData(lOwnedData).Value <> 'second path') then
            raise Exception.Create('Duplicate captions lost owned row identity');
        finally
          lTestForm.ClearListBoxItemData(lObservedList);
        end;
        SetLength(lExpectedCaptions, 500);
        for lIndex := 0 to High(lExpectedCaptions) do
          lExpectedCaptions[lIndex] := Format('Script %.3d', [lIndex]);
        lTestForm.ApplyScriptsSnapshot(lExpectedCaptions);
        lMaxApplyMs := 0;
        lObservedList.MutationCount := 0;
        for lSample := 1 to 30 do
        begin
          lDetailWatch := TStopwatch.StartNew;
          lTestForm.ApplyScriptsSnapshot(lExpectedCaptions);
          lApplyMs := lDetailWatch.Elapsed.TotalMilliseconds;
          if (lSample = 1) or (lApplyMs > lMaxApplyMs) then
            lMaxApplyMs := lApplyMs;
        end;
        if (lMaxApplyMs > 100) or (lObservedList.MutationCount <> 0) then
          raise Exception.Create('Repeated 500-row snapshot application blocked or mutated the list');
        Writeln(Format('LIST APPLY rows=500 samples=30 max-ms=%.3f', [lMaxApplyMs]));
        Writeln('LIST SYNC PASS unchanged-mutations=0 selection=preserved scroll=preserved');
      finally
        lTestForm.Free;
      end;
    except
      on lException: Exception do
      begin
        Writeln('SELFTEST FAILED: ' + lException.Message);
        Result := 1;
      end;
    end;
    Exit;
  end;
  if SameText(aArg, '--self-test-chat-refresh-handoff') then
  begin
    Result := 0;
    lTestSettings := TMemIniFile.Create('');
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestSettings.WriteBool('ChatMonitor', 'Enabled', False);
      lTestForm.fChatMonitor := TChatMonitor.Create(lTestSettings);
      lTestForm.fGuiRefreshQueued := 1;
      lTestForm.StartChatMonitorProcessing;
      if (lTestForm.fChatMonitorBusy <> 0) or (lTestForm.fChatMonitorPending <> 1) then
      begin
        Writeln('SELFTEST FAILED: chat processing started before fresh titles arrived');
        Result := 1;
      end;
      lTestForm.fGuiRefreshQueued := 0;
      lTestForm.fWindowBatch.ErrorText := 'Inventory failed';
      lTestForm.ResumeChatMonitorAfterSnapshot;
      if lTestForm.fGuiRefreshQueued <> 0 then
      begin
        Writeln('SELFTEST FAILED: failed collection immediately queued another collection');
        Result := 1;
      end;
      lTestForm.StartChatMonitorProcessing;
      if lTestForm.fGuiRefreshQueued <> 1 then
      begin
        Writeln('SELFTEST FAILED: later scheduled chat poll did not recover from an inventory error');
        Result := 1;
      end;
    finally
      lTestForm.fShuttingDown := 1;
      lTestForm.WaitAsyncWithShutdown(lTestForm.fChatMonitorTask, 1000);
      lTestForm.fChatMonitorTask := nil;
      lTestForm.fChatMonitor.Free;
      lTestForm.Free;
      lTestSettings.Free;
    end;
    Exit;
  end;
  if SameText(aArg, '--self-test-refresh-auxiliary') then
  begin
    Result := 0;
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestForm.fStartupDataReady := 1;
      lTestForm.fGuiRefreshQueued := 1;
      lTestForm.fAuxListRefreshBusy := 1;
      lTestForm.AppOnActivate(lTestForm);
      if lTestForm.fAuxListRefreshPending <> 1 then
      begin
        Writeln('SELFTEST FAILED: refocus lost the auxiliary-list refresh');
        Result := 1;
      end;
    finally
      lTestForm.Free;
    end;
    Exit;
  end;
  if SameText(aArg, '--self-test-window-refresh') then
  begin
    Result := 0;
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestForm.QueueGuiRefresh;
      lTestForm.QueueGuiRefresh;
      if lTestForm.fGuiRefreshQueued <> 1 then
      begin
        Writeln('SELFTEST FAILED: refresh executed inline instead of deferring and coalescing');
        Result := 1;
      end;
    finally
      lTestForm.fShuttingDown := 1;
      CheckSynchronize;
      lTestForm.Free;
    end;
    Exit;
  end;
  if SameText(aArg, cResizeColumnWidthsSelfTestArg) then
  begin
    Result := 0;
    CalculateProportionalColumnWidths(1230, lAppsWidth, lExplorerWidth, lScriptsWidth, lConsoleWidth,
      lDesktopWidth, lShortCutsWidth);
    if (lAppsWidth <> 253) or (lExplorerWidth <> 250) or (lScriptsWidth <> 201) or
      (lConsoleWidth <> 175) or (lDesktopWidth <> 175) or (lShortCutsWidth <> 176) then
    begin
      Writeln(Format('SELFTEST FAILED: resize column widths expected=253,250,201,175,175,176 actual=%d,%d,%d,%d,%d,%d',
        [lAppsWidth, lExplorerWidth, lScriptsWidth, lConsoleWidth, lDesktopWidth, lShortCutsWidth]));
      Result := 1;
    end;
    Exit;
  end;

  if SameText(aArg, cFocusSoundSelfTestArg) then
  begin
    Result := 0;
    lActualValue := '';
    lTestForm := TAppsViewMainFrm.CreateNew(nil);
    try
      lTestForm.lbApps := TListBox.Create(lTestForm);
      lTestForm.lbApps.Parent := lTestForm;
      lTestForm.pnlAppDetails := TPanel.Create(lTestForm);
      lTestForm.pnlAppDetails.Parent := lTestForm;
      lTestForm.fStartupDataReady := 1;
      lTestForm.fGuiRefreshQueued := 1;
      lTestForm.fFocusSoundFileName := 'activation-focus.wav';
      lTestForm.fAuxListRefreshBusy := 1;
      lTestForm.fFocusSoundPlayer :=
        procedure(aFileName: string)
        begin
          lActualValue := aFileName;
        end;

      lTestForm.AppOnActivate(lTestForm);
      if lActualValue <> lTestForm.fFocusSoundFileName then
      begin
        Writeln('SELFTEST FAILED: application activation did not request the configured focus sound');
        Result := 1;
      end;
    finally
      lTestForm.fFocusSoundPlayer := nil;
      lTestForm.Free;
    end;
    Exit;
  end;

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
      lItems.Sorted := False;
      lItems.Clear;
      lItems.AddObject('A', TObject(hWnd(10)));
      lItems.AddObject('B', TObject(hWnd(20)));
      lResultIndex := CalculateRestoredItemIndex(lItems, 0, -1, '', False);
      if lResultIndex <> -1 then
      begin
        Writeln(Format('SELFTEST FAILED: restore item index should preserve no selection actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
    finally
      lItems.Free;
    end;
    Exit;
  end;

  if SameText(aArg, cConsoleTitleSortSelfTestArg) then
  begin
    Result := 0;
    lItems := TStringList.Create;
    try
      lTitle := Char($280F) + ' ActiveAppView';
      lItems.AddObject('monitor-msgsend', TObject(3));
      lItems.AddObject(Char($2839) + ' te5', TObject(4));
      lItems.AddObject(lTitle, TObject(1));
      lItems.AddObject('Flexdoc-Group', TObject(2));

      SortConsoleItems(lItems);

      if lItems[0] <> lTitle then
      begin
        Writeln(Format('SELFTEST FAILED: console sort expected first="%s" actual="%s"', [lTitle, lItems[0]]));
        Result := 1;
      end;
      if lItems.Objects[0] <> TObject(1) then
      begin
        Writeln('SELFTEST FAILED: console sort did not preserve window object');
        Result := 1;
      end;
      if NormalizeConsoleSortCaption(Char($280F) + Char($2839) + '  ActiveAppView') <> 'ActiveAppView' then
      begin
        Writeln('SELFTEST FAILED: console sort normalizer did not strip Codex working prefix');
        Result := 1;
      end;

      lItems.Clear;
      lItems.AddObject(Char($28FF) + ' Terminal', TObject(100));
      lItems.AddObject(Char($2801) + ' Terminal', TObject(200));
      SortConsoleItems(lItems);
      if lItems.Objects[0] <> TObject(100) then
      begin
        Writeln('SELFTEST FAILED: console sort tie-breaker should use process id');
        Result := 1;
      end;
    finally
      lItems.Free;
    end;
    Exit;
  end;

  if SameText(aArg, cConsolePollAppPurgeSelfTestArg) then
  begin
    Result := 0;
    lItems := TStringList.Create;
    try
      lItems.AddObject('App', TObject(hWnd(10)));
      lItems.AddObject('Terminal', TObject(hWnd(20)));
      if not RemoveWindowsFromItems(lItems, [hWnd(20)]) then
      begin
        Writeln('SELFTEST FAILED: console poll app purge reported no removal');
        Result := 1;
      end;
      if lItems.Count <> 1 then
      begin
        Writeln(Format('SELFTEST FAILED: console poll app purge expected count=1 actual=%d',
          [lItems.Count]));
        Result := 1;
      end;
      if (lItems.Count > 0) and (hWnd(lItems.Objects[0]) <> hWnd(10)) then
      begin
        Writeln('SELFTEST FAILED: console poll app purge removed the wrong window');
        Result := 1;
      end;
    finally
      lItems.Free;
    end;
    Exit;
  end;

  if SameText(aArg, cWindowActionCopySelfTestArg) then
  begin
    Result := 0;
    lActionWnd := CreateWindowEx(
      0,
      'STATIC',
      'Window action copy target',
      WS_POPUP or WS_VISIBLE,
      0,
      0,
      0,
      0,
      0,
      0,
      HInstance,
      nil);
    if lActionWnd = 0 then
    begin
      Writeln('SELFTEST FAILED: could not create the window action copy target');
      Exit(1);
    end;
    try
      lTestForm := TAppsViewMainFrm.CreateNew(nil);
      try
        lTestForm.lbApps := TListBox.Create(lTestForm);
        lTestForm.lbApps.Parent := lTestForm;
        lTestForm.lbExplorer := TListBox.Create(lTestForm);
        lTestForm.lbExplorer.Parent := lTestForm;
        lTestForm.lbConsole := TListBox.Create(lTestForm);
        lTestForm.lbConsole.Parent := lTestForm;
        lTestForm.CreateWindowActionsPopupMenu;
        // The real clipboard is user-owned and may contain non-text data that this self-test cannot safely replace.
        lTestForm.fWindowActionClipboardWriter :=
          procedure(aText: string)
          begin
            lActualValue := aText;
          end;
        lTestForm.lbApps.Items.AddObject(
          'window action copy target',
          TObject(lActionWnd));
        lTestForm.lbApps.ItemIndex := 0;
        SetLength(lTestForm.fWindowBatch.Windows, 1);
        lTestForm.fWindowBatch.Windows[0].Wnd := lActionWnd;
        lTestForm.fWindowBatch.Windows[0].PID := GetCurrentProcessId;
        TryGetProcessStartedAtUtcMilliseconds(GetCurrentProcessId,
          lTestForm.fWindowBatch.Windows[0].ProcessStartedAt);
        lTestForm.fWindowBatch.Windows[0].FileName := ParamStr(0);
        lTestForm.fWindowBatch.Windows[0].CommandLine := string(Winapi.Windows.GetCommandLine);
        lTestForm.fWindowBatch.Windows[0].MetadataReady := True;

        lExpectedCaptions := TArray<string>.Create(
          'Copy full EXE filename',
          'Copy full EXE filename including command line switches',
          'Copy PID',
          'Copy HWND');
        lExpectedValues := TArray<string>.Create(
          ParamStr(0),
          string(Winapi.Windows.GetCommandLine),
          GetCurrentProcessId.ToString,
          UIntToStr(NativeUInt(lActionWnd)));
        lCopyPidMenuItem := nil;
        for lIndex := 0 to High(lExpectedCaptions) do
        begin
          lMenuItem := nil;
          for lMenuIndex := 0 to lTestForm.fWindowActionsPopupMenu.Items.Count - 1 do
            if SameText(
              lTestForm.fWindowActionsPopupMenu.Items[lMenuIndex].Caption,
              lExpectedCaptions[lIndex]) then
            begin
              lMenuItem := lTestForm.fWindowActionsPopupMenu.Items[lMenuIndex];
              Break;
            end;
          if not Assigned(lMenuItem) then
          begin
            Writeln(Format(
              'SELFTEST FAILED: missing window action menu item "%s"',
              [lExpectedCaptions[lIndex]]));
            Result := 1;
            Continue;
          end;
          if not Assigned(lMenuItem.OnClick) then
          begin
            Writeln(Format(
              'SELFTEST FAILED: window action menu item "%s" has no handler',
              [lExpectedCaptions[lIndex]]));
            Result := 1;
            Continue;
          end;
          if lIndex = 2 then
            lCopyPidMenuItem := lMenuItem;
          if not lTestForm.CaptureWindowActionTarget(lTestForm.lbApps) then
          begin
            Writeln(Format(
              'SELFTEST FAILED: could not capture target for "%s"',
              [lExpectedCaptions[lIndex]]));
            Result := 1;
            Continue;
          end;
          lActualValue := 'window-action-copy-not-set';
          lMenuItem.Click;
          if ((lIndex = 0) and
            (not SameText(lActualValue, lExpectedValues[lIndex]))) or
            ((lIndex <> 0) and (lActualValue <> lExpectedValues[lIndex])) then
          begin
            Writeln(Format(
              'SELFTEST FAILED: "%s" expected="%s" actual="%s"',
              [lExpectedCaptions[lIndex], lExpectedValues[lIndex], lActualValue]));
            Result := 1;
          end;
        end;

        lTestForm.fWindowBatch.Windows[0].MetadataReady := False;
        lTestForm.fWindowBatch.Windows[0].MetadataError := 'Earlier timeout';
        lTestForm.fWindowBatch.Windows[0].CommandLineError := 'Earlier timeout';
        lTestForm.fWindowBatch.Windows[0].CommandLineAttemptedAt := 1;
        lTestForm.fWindowBatch.Windows[0].MetadataAttemptedAt := 1;
        lTestForm.fPendingCopy := lTestForm.fWindowBatch.Windows[0];
        lTestForm.fPendingClipboardSequence := GetClipboardSequenceNumber;
        lTestForm.TryPublishPendingWindowCopy;
        if lTestForm.fPendingCopy.Wnd = 0 then
        begin
          Writeln('SELFTEST FAILED: cached metadata failure cancelled an explicit copy retry');
          Result := 1;
        end;

        lTestForm.fWindowBatch.Windows[0].MetadataAttemptedAt := 2;
        lTestForm.fWindowBatch.Windows[0].AttemptedMetadata := [wmIdentity];
        lTestForm.fWindowBatch.Windows[0].MetadataError := '';
        lTestForm.fWindowBatch.Windows[0].CommandLineAttemptedAt := 2;
        lTestForm.TryPublishPendingWindowCopy;
        if lTestForm.fPendingCopy.Wnd <> 0 then
        begin
          Writeln('SELFTEST FAILED: fresh metadata failure retained a pending copy');
          Result := 1;
        end;
        lTestForm.fWindowBatch.Windows[0].MetadataReady := True;
        lTestForm.fPendingCopy := lTestForm.fWindowBatch.Windows[0];
        // Exercise a stale sequence without changing the user-owned clipboard.
        lTestForm.fPendingClipboardSequence := GetClipboardSequenceNumber xor 1;
        lActualValue := 'newer clipboard content';
        lTestForm.TryPublishPendingWindowCopy;
        if lActualValue <> 'newer clipboard content' then
        begin
          Writeln('SELFTEST FAILED: late metadata overwrote newer clipboard content');
          Result := 1;
        end;

        if Assigned(lCopyPidMenuItem) and
          lTestForm.CaptureWindowActionTarget(lTestForm.lbApps) then
        begin
          lActualValue := 'stale-window-action-target';
          DestroyWindow(lActionWnd);
          lActionWnd := 0;
          lCopyPidMenuItem.Click;
          if lActualValue <> 'stale-window-action-target' then
          begin
            Writeln('SELFTEST FAILED: stale copy target changed the clipboard');
            Result := 1;
          end;
        end else begin
          Writeln('SELFTEST FAILED: could not prepare the stale copy target check');
          Result := 1;
        end;
      finally
        lTestForm.Free;
      end;
    finally
      if lActionWnd <> 0 then
        DestroyWindow(lActionWnd);
    end;
    Exit;
  end;

  if SameText(aArg, cWindowActionProbeSelfTestArg) then
  begin
    Result := 0;
    lActionTarget := Default(TWindowActionTarget);
    lActionTarget.ProcessId := 200;
    lActionTarget.Wnd := hWnd(20);
    if not TryResolveWindowActionTarget(
      lActionTarget,
      function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean
      begin
        Result := (aWnd = hWnd(20)) and (aProcessId = 200);
      end,
      lResolvedWnd,
      lResolvedProcessId) or
      (lResolvedWnd <> hWnd(20)) or (lResolvedProcessId <> 200) then
    begin
      Writeln('SELFTEST FAILED: window action did not retain the popup target');
      Result := 1;
    end;
    if TryResolveWindowActionTarget(
      lActionTarget,
      function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean
      begin
        Result := False;
      end,
      lResolvedWnd,
      lResolvedProcessId) then
    begin
      Writeln('SELFTEST FAILED: stale popup target was accepted');
      Result := 1;
    end;
    lActionWnd := CreateWindowEx(
      0,
      'STATIC',
      'Captured action target',
      WS_POPUP,
      0,
      0,
      0,
      0,
      0,
      0,
      HInstance,
      nil);
    lReplacementWnd := CreateWindowEx(
      0,
      'STATIC',
      'Replacement list target',
      WS_POPUP,
      0,
      0,
      0,
      0,
      0,
      0,
      HInstance,
      nil);
    if (lActionWnd = 0) or (lReplacementWnd = 0) then
    begin
      Writeln('SELFTEST FAILED: could not create popup target windows');
      Result := 1;
    end else begin
      lTestForm := TAppsViewMainFrm.CreateNew(nil);
      try
        lTestListBox := TListBox.Create(lTestForm);
        lTestListBox.Parent := lTestForm;
        lTestListBox.Height := 100;
        lTestListBox.Width := 100;
        lTestListBox.Items.AddObject(
          'captured target',
          TObject(lActionWnd));
        lTestListBox.ItemIndex := 0;
        lHandled := False;
        lMousePos.X := 1;
        lMousePos.Y := 1;
        lTestForm.WindowActionListBoxContextPopup(
          lTestListBox,
          lMousePos,
          lHandled);
        if lHandled then
        begin
          Writeln('SELFTEST FAILED: context target capture unexpectedly handled the popup');
          Result := 1;
        end;
        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'replacement target',
          TObject(lReplacementWnd));
        lTestListBox.ItemIndex := 0;
        lActionTarget := Default(TWindowActionTarget);
        if not lTestForm.PrepareWindowActionTargetForPopup(lTestListBox) or
          (not lTestForm.ConsumeWindowActionTarget(
          lCapturedListBox,
          lActionTarget)) or
          (lCapturedListBox <> lTestListBox) or
          (lActionTarget.Wnd <> lActionWnd) or
          (lActionTarget.ProcessId <> GetCurrentProcessId) then
        begin
          Writeln('SELFTEST FAILED: list refresh replaced the frozen popup target');
          Result := 1;
        end;

        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'captured source target',
          TObject(lActionWnd));
        lTestListBox.ItemIndex := 0;
        lMousePos.X := 1;
        lMousePos.Y := 1;
        lTestForm.WindowActionListBoxContextPopup(
          lTestListBox,
          lMousePos,
          lHandled);
        lOtherListBox := TListBox.Create(lTestForm);
        lOtherListBox.Parent := lTestForm;
        lOtherListBox.Items.AddObject(
          'mismatched source target',
          TObject(lReplacementWnd));
        lOtherListBox.ItemIndex := 0;
        if lTestForm.PrepareWindowActionTargetForPopup(lOtherListBox) then
        begin
          Writeln('SELFTEST FAILED: popup source mismatch captured another target');
          Result := 1;
        end;
        if lTestForm.ConsumeWindowActionTarget(
          lCapturedListBox,
          lActionTarget) then
        begin
          Writeln('SELFTEST FAILED: popup source mismatch remained actionable');
          Result := 1;
        end;

        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'selected target behind blank context area',
          TObject(lActionWnd));
        lTestListBox.ItemIndex := 0;
        lMousePos.X := 1;
        lMousePos.Y := lTestListBox.ClientHeight + 1;
        lTestForm.WindowActionListBoxContextPopup(
          lTestListBox,
          lMousePos,
          lHandled);
        if lTestForm.PrepareWindowActionTargetForPopup(lTestListBox) then
        begin
          Writeln('SELFTEST FAILED: blank context area retained the selected target');
          Result := 1;
        end;
        if lTestForm.ConsumeWindowActionTarget(
          lCapturedListBox,
          lActionTarget) then
        begin
          Writeln('SELFTEST FAILED: blank context area remained actionable');
          Result := 1;
        end;

        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'unselected keyboard context target',
          TObject(lActionWnd));
        lTestListBox.ItemIndex := -1;
        lMousePos.X := -1;
        lMousePos.Y := -1;
        lTestForm.WindowActionListBoxContextPopup(
          lTestListBox,
          lMousePos,
          lHandled);
        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'replacement after failed keyboard capture',
          TObject(lReplacementWnd));
        lTestListBox.ItemIndex := 0;
        if lTestForm.PrepareWindowActionTargetForPopup(lTestListBox) then
        begin
          Writeln('SELFTEST FAILED: failed keyboard context captured a later target');
          Result := 1;
        end;
        if lTestForm.ConsumeWindowActionTarget(
          lCapturedListBox,
          lActionTarget) then
        begin
          Writeln('SELFTEST FAILED: failed keyboard context remained actionable');
          Result := 1;
        end;

        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'stale captured target',
          TObject(lActionWnd));
        lTestListBox.ItemIndex := 0;
        if not lTestForm.CaptureWindowActionTarget(lTestListBox) then
        begin
          Writeln('SELFTEST FAILED: stale popup setup capture failed');
          Result := 1;
        end;
        DestroyWindow(lActionWnd);
        lActionWnd := 0;
        lTestListBox.Items.Clear;
        lTestListBox.Items.AddObject(
          'live replacement target',
          TObject(lReplacementWnd));
        lTestListBox.ItemIndex := 0;
        if lTestForm.ConsumeWindowActionTarget(
          lCapturedListBox,
          lActionTarget) then
        begin
          Writeln('SELFTEST FAILED: destroyed popup target switched to the replacement');
          Result := 1;
        end;
      finally
        lTestForm.Free;
      end;
    end;
    if lActionWnd <> 0 then
      DestroyWindow(lActionWnd);
    if lReplacementWnd <> 0 then
      DestroyWindow(lReplacementWnd);
    if not IsWindowActionListBox(TObject(3), TObject(1), TObject(2), TObject(3)) then
    begin
      Writeln('SELFTEST FAILED: console listbox should support window actions');
      Result := 1;
    end;
    SetLength(lSnapshots, 2);
    lSnapshots[0].Wnd := hWnd(10);
    lSnapshots[0].Caption := 'App';
    lSnapshots[1].Wnd := hWnd(20);
    lSnapshots[1].Caption := 'Terminal';
    if not RemoveWindowFromSnapshots(lSnapshots, hWnd(20)) then
    begin
      Writeln('SELFTEST FAILED: window-action probe should remove a closed window from snapshots');
      Result := 1;
    end;
    if Length(lSnapshots) <> 1 then
    begin
      Writeln(Format('SELFTEST FAILED: window-action probe expected snapshot count=1 actual=%d',
        [Length(lSnapshots)]));
      Result := 1;
    end;
    if (Length(lSnapshots) > 0) and (lSnapshots[0].Wnd <> hWnd(10)) then
    begin
      Writeln('SELFTEST FAILED: window-action probe removed the wrong snapshot');
      Result := 1;
    end;
    lItems := TStringList.Create;
    try
      lItems.AddObject('first', TObject(hWnd(10)));
      lItems.AddObject('selected', TObject(hWnd(20)));
      lItems.AddObject('third', TObject(hWnd(30)));
      lItems.Delete(0);
      lResultIndex := CalculateWindowItemIndexAfterRemoval(lItems, 1, hWnd(20), hWnd(10));
      if lResultIndex <> 0 then
      begin
        Writeln(Format('SELFTEST FAILED: window-action probe should preserve selected hwnd at index 0 actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lResultIndex := CalculateWindowItemIndexAfterRemoval(lItems, 0, hWnd(20), hWnd(20));
      if lResultIndex <> 0 then
      begin
        Writeln(Format('SELFTEST FAILED: window-action probe should select nearest surviving item actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lResultIndex := CalculateItemIndexAfterDeletingIndex(9, 6);
      if lResultIndex <> 6 then
      begin
        Writeln(Format('SELFTEST FAILED: deleting 7th listbox item should keep index 6 actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lResultIndex := CalculateItemIndexAfterDeletingIndex(6, 6);
      if lResultIndex <> 5 then
      begin
        Writeln(Format('SELFTEST FAILED: deleting last listbox item should clamp to previous actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lResultIndex := CalculateWindowItemIndexAfterRemoval(lItems, -1, 0, hWnd(10));
      if lResultIndex <> -1 then
      begin
        Writeln(Format('SELFTEST FAILED: window-action probe should preserve no selection actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lItems.Clear;
      lItems.AddObject('first', TObject(hWnd(10)));
      lItems.AddObject('selected', TObject(hWnd(20)));
      lItems.AddObject('third', TObject(hWnd(30)));
      lItems.Delete(0);
      lResultIndex := CalculateWindowItemIndexAfterValidation(lItems, 1, hWnd(20));
      if lResultIndex <> 0 then
      begin
        Writeln(Format('SELFTEST FAILED: refocus validation should preserve selected hwnd at index 0 actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
      lItems.Delete(0);
      lResultIndex := CalculateWindowItemIndexAfterValidation(lItems, 0, hWnd(20));
      if lResultIndex <> 0 then
      begin
        Writeln(Format('SELFTEST FAILED: refocus validation should select nearest surviving item actual=%d',
          [lResultIndex]));
        Result := 1;
      end;
    finally
      lItems.Free;
    end;
    Exit;
  end;

  if SameText(aArg, cWindowTitlePollingSelfTestArg) then
  begin
    Result := 0;
    SetLength(lPrefixRules, 1);
    lPrefixRules[0].Prefix := '*';
    lPrefixRules[0].CaptionMask := 'PowerShell*';
    lTitle := BuildConsoleDisplayCaption(
      'PowerShell - ActiveAppView',
      'C:\Windows\System32\WindowsTerminal.exe',
      lPrefixRules);
    if lTitle <> '* - PowerShell - ActiveAppView | WindowsTerminal.exe (C:\Windows\System32\WindowsTerminal.exe)' then
    begin
      Writeln(Format('SELFTEST FAILED: console poll title expected prefix/display actual="%s"', [lTitle]));
      Result := 1;
    end;
    if ShouldEnablePeriodicWindowPolling(False, 5000) then
    begin
      Writeln('SELFTEST FAILED: window title polling should stay disabled before startup data is ready');
      Result := 1;
    end;
    if ShouldEnablePeriodicWindowPolling(True, 0) then
    begin
      Writeln('SELFTEST FAILED: window title polling should stay disabled when interval is 0');
      Result := 1;
    end;
    if not ShouldEnablePeriodicWindowPolling(True, 5000) then
    begin
      Writeln('SELFTEST FAILED: window title polling should be enabled after startup data is ready');
      Result := 1;
    end;
    if CalculateSharedTimerIntervalMs(5000, True, 30000) <> 5000 then
    begin
      Writeln('SELFTEST FAILED: shared timer should use the shorter window-title interval');
      Result := 1;
    end;
    if CalculateSharedTimerIntervalMs(0, True, 30000) <> 30000 then
    begin
      Writeln('SELFTEST FAILED: shared timer should use chat interval when title polling is disabled');
      Result := 1;
    end;
    if CalculateSharedTimerIntervalMs(0, False, 30000) <> 0 then
    begin
      Writeln('SELFTEST FAILED: shared timer should be disabled when no timed feature is active');
      Result := 1;
    end;
    if not ShouldEnableSharedTimer(0, False, 30000, True) then
    begin
      Writeln('SELFTEST FAILED: Machine Overview should keep the shared timer enabled');
      Result := 1;
    end;
    if not IsTimedActionDue(10000, 4000, 5000) then
    begin
      Writeln('SELFTEST FAILED: timed action should be due after elapsed interval');
      Result := 1;
    end;
    if IsTimedActionDue(10000, 6000, 5000) then
    begin
      Writeln('SELFTEST FAILED: timed action should not be due before elapsed interval');
      Result := 1;
    end;
    Exit;
  end;

  if SameText(aArg, cScriptsIgnoreSelfTestArg) then
  begin
    Result := 0;
    lScriptsDir := TPath.Combine(TPath.GetTempPath, 'ActiveAppView.selftest.scripts-ignore');
    if TDirectory.Exists(lScriptsDir) then
      TDirectory.Delete(lScriptsDir, True);
    TDirectory.CreateDirectory(lScriptsDir);
    lScriptNames := TStringList.Create;
    try
      lScriptNames.CaseSensitive := False;
      lScriptNames.Sorted := True;
      TFile.WriteAllText(CombinePath([lScriptsDir, 'visible.cmd']), '', TEncoding.UTF8);
      TFile.WriteAllText(CombinePath([lScriptsDir, 'VisibleTool.PS1']), '', TEncoding.UTF8);
      TFile.WriteAllText(CombinePath([lScriptsDir, 'helper.ps1']), '', TEncoding.UTF8);
      TFile.WriteAllText(CombinePath([lScriptsDir, 'ignored.py']), '', TEncoding.UTF8);
      TFile.WriteAllText(CombinePath([lScriptsDir, 'notes.txt']), '', TEncoding.UTF8);
      TFile.WriteAllText(
        CombinePath([lScriptsDir, cScriptsIgnoreFileName]),
        '# helper scripts' + sLineBreak + 'HELPER.PS1' + sLineBreak + '.\ignored.py' + sLineBreak,
        TEncoding.UTF8);

      lScripts := BuildScriptsSnapshotForFolder(lScriptsDir);
      lScriptNames.AddStrings(lScripts);
      if lScriptNames.IndexOf('helper.ps1') <> -1 then
      begin
        Writeln('SELFTEST FAILED: scripts ignore should hide helper.ps1');
        Result := 1;
      end;
      if lScriptNames.IndexOf('ignored.py') <> -1 then
      begin
        Writeln('SELFTEST FAILED: scripts ignore should hide ignored.py from relative path entry');
        Result := 1;
      end;
      if lScriptNames.IndexOf('visible.cmd') = -1 then
      begin
        Writeln('SELFTEST FAILED: scripts ignore should keep visible.cmd');
        Result := 1;
      end;
      if lScriptNames.IndexOf('VisibleTool.PS1') = -1 then
      begin
        Writeln('SELFTEST FAILED: scripts ignore should keep VisibleTool.PS1');
        Result := 1;
      end;
      if lScriptNames.IndexOf('notes.txt') <> -1 then
      begin
        Writeln('SELFTEST FAILED: scripts snapshot should not include non-script files');
        Result := 1;
      end;
    finally
      lScriptNames.Free;
      if TDirectory.Exists(lScriptsDir) then
        TDirectory.Delete(lScriptsDir, True);
    end;
    Exit;
  end;

  if SameText(aArg, cPrefixRuleAppUserModelIDPrecedenceSelfTestArg) then
  begin
    Result := 0;
    SetLength(lPrefixRules, 2);
    lPrefixRules[0].Prefix := 'OEC';
    lPrefixRules[0].CmdParamsMask := '*OEC - Microsoft Teams (PWA).lnk*';
    lPrefixRules[1].Prefix := 'Osyon';
    lPrefixRules[1].AppUserModelIDMask := 'MSEdge.teams.micrt.com_/v2/.UserData.Profile1';
    lTitle := 'Czat | Max Dieckmann | Microsoft Teams';

    ApplyPrefixRuleForMetadata(
      lTitle,
      'Czat | Max Dieckmann | Microsoft Teams',
      'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      'MSEdge.teams.micrt.com_/v2/.UserData.Profile1',
      '--source-shortcut="C:\Users\pawel\Desktop\OEC - Microsoft Teams (PWA).lnk"',
      lPrefixRules,
      True,
      True);

    if not SameText(lTitle, 'Osyon - Czat | Max Dieckmann | Microsoft Teams') then
    begin
      Writeln(Format('SELFTEST FAILED: expected Osyon prefix, got "%s"', [lTitle]));
      Exit(1);
    end;
    Exit;
  end;

  if SameText(aArg, cPrefixRuleAppUserModelIDNoCmdFallbackSelfTestArg) then
  begin
    Result := 0;
    SetLength(lPrefixRules, 1);
    lPrefixRules[0].Prefix := 'OEC';
    lPrefixRules[0].CmdParamsMask := '*OEC - Microsoft Teams (PWA).lnk*';
    lTitle := 'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams';

    ApplyPrefixRuleForMetadata(
      lTitle,
      'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams',
      'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      'teams.live.com-FD8206EA_hwygv5gbeahhp!App',
      '--source-shortcut="C:\Users\pawel\Desktop\OEC - Microsoft Teams (PWA).lnk"',
      lPrefixRules,
      True,
      True);

    if not SameText(lTitle, 'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams') then
    begin
      Writeln(Format('SELFTEST FAILED: expected no fallback prefix, got "%s"', [lTitle]));
      Exit(1);
    end;
    Exit;
  end;

  if SameText(aArg, cPrefixRuleSinglePrefixSelfTestArg) then
  begin
    Result := 0;
    SetLength(lPrefixRules, 2);
    lPrefixRules[0].Prefix := 'OEC';
    lPrefixRules[0].CaptionMask := '*Microsoft Teams';
    lPrefixRules[1].Prefix := 'Skype-Teams';
    lPrefixRules[1].AppUserModelIDMask := 'teams.live.com-FD8206EA_hwygv5gbeahhp!App';
    lTitle := 'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams';

    ApplyPrefixRuleForMetadata(
      lTitle,
      'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams',
      'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      '',
      '',
      lPrefixRules,
      True,
      True);

    if not SameText(lTitle, 'Skype-Teams - Czat | Agnieszka Piotrowska | Microsoft Teams') then
    begin
      Writeln(Format('SELFTEST FAILED: expected a single prefix, got "%s"', [lTitle]));
      Exit(1);
    end;
    Exit;
  end;

  if SameText(aArg, cShortCutValueParsingSelfTestArg) then
  begin
    Result := 0;
    if not TryParseShortCutValue(
      'C:\some  folder with spaces\some exe with spaces.exe',
      lTargetPath,
      lParams) then
    begin
      Writeln('SELFTEST FAILED: shortcut parser rejected unquoted path with spaces');
      Exit(1);
    end;
    if (lTargetPath <> 'C:\some  folder with spaces\some exe with spaces.exe') or (lParams <> '') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: unquoted path expected target="%s" params="" actual target="%s" params="%s"',
        ['C:\some  folder with spaces\some exe with spaces.exe', lTargetPath, lParams]));
      Exit(1);
    end;

    if not TryParseShortCutValue(
      '"C:\some path with spaces\some exe with spaces.exe" -param1 -param2 -param3-with-value "some value for param3"',
      lTargetPath,
      lParams) then
    begin
      Writeln('SELFTEST FAILED: shortcut parser rejected quoted path with params');
      Exit(1);
    end;
    if (lTargetPath <> 'C:\some path with spaces\some exe with spaces.exe')
      or (lParams <> '-param1 -param2 -param3-with-value "some value for param3"') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: quoted path expected target="%s" params="%s" actual target="%s" params="%s"',
        ['C:\some path with spaces\some exe with spaces.exe',
         '-param1 -param2 -param3-with-value "some value for param3"', lTargetPath, lParams]));
      Exit(1);
    end;

    if not TryParseShortCutValue(
      'C:\some path with spaces\',
      lTargetPath,
      lParams) then
    begin
      Writeln('SELFTEST FAILED: shortcut parser rejected unquoted folder with trailing slash');
      Exit(1);
    end;
    if (lTargetPath <> 'C:\some path with spaces\') or (lParams <> '') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: unquoted folder expected target="%s" params="" actual target="%s" params="%s"',
        ['C:\some path with spaces\', lTargetPath, lParams]));
      Exit(1);
    end;

    if not TryParseShortCutValue(
      'wt -w new --title "PC-Maintenance"',
      lTargetPath,
      lParams) then
    begin
      Writeln('SELFTEST FAILED: shortcut parser rejected command alias with params');
      Exit(1);
    end;
    if (lTargetPath <> 'wt') or (lParams <> '-w new --title "PC-Maintenance"') then
    begin
      Writeln(Format(
        'SELFTEST FAILED: command alias expected target="%s" params="%s" actual target="%s" params="%s"',
        ['wt', '-w new --title "PC-Maintenance"', lTargetPath, lParams]));
      Exit(1);
    end;
    Exit;
  end;

  if SameText(aArg, cWindowCaptionOverridesSelfTestArg) then
  begin
    Result := 0;
    lIdentity := Default(TCaptionOverrideIdentity);
    lIdentity.HasBootId := True;
    lIdentity.BootId := 1783900000000;
    lIdentity.HasProcessStartedAt := True;
    lIdentity.ProcessStartedAt := 1783900000123;
    lIdentity.ProcessId := 200;
    lIdentity.Hwnd := 100;
    lObservedIdentity := lIdentity;
    Inc(lObservedIdentity.ProcessStartedAt);
    if SelectCurrentCaptionOverrideIdentity(
      lIdentity,
      lObservedIdentity).ProcessStartedAt <> lObservedIdentity.ProcessStartedAt then
    begin
      Writeln('SELFTEST FAILED: observed process reuse retained stale override identity');
      Exit(1);
    end;
    if not BuildRenameCaptionOverrideTransition(
      lIdentity,
      'First label',
      1783900800100,
      lRecord,
      lEvent) then
    begin
      Writeln('SELFTEST FAILED: rename lifecycle transition is unavailable');
      Exit(1);
    end;
    if (lRecord.Caption <> 'First label') or
      (lRecord.CreatedAt <> 1783900800100) or
      (lEvent.EventKind <> TCaptionOverrideEventKind.coekRename) or
      (lEvent.Identity.ProcessStartedAt <> lIdentity.ProcessStartedAt) then
    begin
      Writeln('SELFTEST FAILED: rename lifecycle transition payload mismatch');
      Exit(1);
    end;
    if not BuildRenameCaptionOverrideTransition(
      lIdentity,
      'Replacement label',
      1783900800200,
      lRecord,
      lEvent) or
      (lRecord.CreatedAt <> 1783900800200) or
      (lEvent.Caption <> 'Replacement label') then
    begin
      Writeln('SELFTEST FAILED: replacement lifecycle transition mismatch');
      Exit(1);
    end;
    if not BuildEndCaptionOverrideTransition(
      lRecord,
      TCaptionOverrideEventKind.coekReset,
      1783900800300,
      'user_reset',
      lEvent) or
      (lEvent.EventKind <> TCaptionOverrideEventKind.coekReset) or
      (lEvent.Identity.ProcessStartedAt <> lIdentity.ProcessStartedAt) or
      (lEvent.Caption <> '') then
    begin
      Writeln('SELFTEST FAILED: reset lifecycle transition mismatch');
      Exit(1);
    end;
    lTempDir := TPath.Combine(TPath.GetTempPath, 'ActiveAppViewCaptionOverrideSelfTest-' + UIntToStr(GetTickCount64));
    TDirectory.CreateDirectory(lTempDir);
    lStateFileName := TPath.Combine(lTempDir, cWindowCaptionOverridesFileName);
    lOverrides := TDictionary<string, string>.Create;
    lLoadedOverrides := TDictionary<string, string>.Create;
    try
      lOverrideKey := BuildWindowCaptionOverrideKey(hWnd(100), 200);
      lOverrides.Add(lOverrideKey, 'Custom caption');
      if BuildWindowDisplayCaption(
        ApplyWindowCaptionOverride(lOverrides, hWnd(100), 200, 'Normal caption'),
        'C:\Tools\cmd.exe') <> 'Custom caption | cmd.exe (C:\Tools\cmd.exe)' then
      begin
        Writeln('SELFTEST FAILED: window caption override did not preserve display suffix');
        Result := 1;
      end;
      if ApplyWindowCaptionOverride(lOverrides, hWnd(101), 200, 'Normal caption') <> 'Normal caption' then
      begin
        Writeln('SELFTEST FAILED: window caption override ignored HWND boundary');
        Result := 1;
      end;
      if ApplyWindowCaptionOverride(lOverrides, hWnd(100), 201, 'Normal caption') <> 'Normal caption' then
      begin
        Writeln('SELFTEST FAILED: window caption override ignored PID boundary');
        Result := 1;
      end;
      if not HasWindowCaptionOverride(lOverrides, hWnd(100), 200) then
      begin
        Writeln('SELFTEST FAILED: window caption override was not reported');
        Result := 1;
      end;
      if BuildWindowRenameDefaultCaption(
        lOverrides,
        hWnd(100),
        201,
        'Normal caption',
        'Custom caption | cmd.exe (C:\Tools\cmd.exe)') <> 'Custom caption' then
      begin
        Writeln('SELFTEST FAILED: window rename default did not fall back to displayed override caption');
        Result := 1;
      end;
      lDialogOutcome := ExecuteCaptionOverrideDialogWithInitialCaption(
        nil,
        'Custom caption',
        CaptionOverrideDialogInputSelfTestRunner);
      if (lDialogOutcome.DialogResult <> codRename) or (lDialogOutcome.Caption <> 'Custom caption edited') then
      begin
        Writeln('SELFTEST FAILED: window rename dialog input was cleared before showing');
        Result := 1;
      end;

      lCallCount := 0;
      lDialogOutcome.DialogResult := codCancel;
      lDialogOutcome.Caption := 'Canceled caption';
      lApplyResult := ApplyWindowCaptionDialogOutcome(
        lOverrides,
        hWnd(100),
        200,
        lDialogOutcome,
        function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean
        begin
          Inc(lCallCount);
          Result := False;
        end);
      if (lApplyResult <> wcdarNone) or (lCallCount <> 0) or
        (ApplyWindowCaptionOverride(lOverrides, hWnd(100), 200, '') <> 'Custom caption') then
      begin
        Writeln('SELFTEST FAILED: canceled window rename changed the override');
        Result := 1;
      end;

      lDialogOutcome.DialogResult := codReset;
      lApplyResult := ApplyWindowCaptionDialogOutcome(
        lOverrides,
        hWnd(100),
        200,
        lDialogOutcome,
        function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean
        begin
          Inc(lCallCount);
          Result := False;
        end);
      if (lApplyResult <> wcdarStale) or (lCallCount <> 1) or
        (not HasWindowCaptionOverride(lOverrides, hWnd(100), 200)) then
      begin
        Writeln('SELFTEST FAILED: stale window caption reset changed the override');
        Result := 1;
      end;

      lTestWnd := CreateWindowEx(0, 'STATIC', 'Identity self-test', WS_POPUP,
        0, 0, 0, 0, 0, 0, HInstance, nil);
      if lTestWnd = 0 then
      begin
        Writeln('SELFTEST FAILED: could not create a real window for identity validation');
        Result := 1;
      end else begin
        lTestProcessId := GetCurrentProcessId;
        lTestApp := TAppInfo.Create(lTestWnd);
        try
          SetLength(lApps, 1);
          lApps[0] := lTestApp;
          PrefetchAppFileNamesInParallel(lApps, nil);
          if not lTestApp.TryGetCachedProcessStartedAt(lRecord.Identity.ProcessStartedAt) then
          begin
            Writeln('SELFTEST FAILED: background snapshot did not cache process-start identity');
            Result := 1;
          end;
        finally
          lTestApp.Free;
          lApps := nil;
        end;
        lTestOverrideKey := BuildWindowCaptionOverrideKey(lTestWnd, lTestProcessId);
        lOverrides.AddOrSetValue(lTestOverrideKey, 'Original caption');
        lDialogOutcome.DialogResult := codRename;
        lDialogOutcome.Caption := 'Current caption';
        lApplyResult := ApplyWindowCaptionDialogOutcome(
          lOverrides,
          lTestWnd,
          lTestProcessId,
          lDialogOutcome,
          IsWindowIdentityCurrent);
        if (lApplyResult <> wcdarRenamed) or
          (ApplyWindowCaptionOverride(lOverrides, lTestWnd, lTestProcessId, '') <> 'Current caption') then
        begin
          Writeln('SELFTEST FAILED: current real window identity did not apply the rename');
          Result := 1;
        end;

        lDialogOutcome.Caption := 'Wrong process caption';
        lApplyResult := ApplyWindowCaptionDialogOutcome(
          lOverrides,
          lTestWnd,
          lTestProcessId + 1,
          lDialogOutcome,
          IsWindowIdentityCurrent);
        if (lApplyResult <> wcdarStale) or
          (ApplyWindowCaptionOverride(lOverrides, lTestWnd, lTestProcessId, '') <> 'Current caption') then
        begin
          Writeln('SELFTEST FAILED: live HWND with a different PID changed the override');
          Result := 1;
        end;

        DestroyWindow(lTestWnd);
        lDialogOutcome.Caption := 'Stale caption';
        lApplyResult := ApplyWindowCaptionDialogOutcome(
          lOverrides,
          lTestWnd,
          lTestProcessId,
          lDialogOutcome,
          IsWindowIdentityCurrent);
        if (lApplyResult <> wcdarStale) or
          (ApplyWindowCaptionOverride(lOverrides, lTestWnd, lTestProcessId, '') <> 'Current caption') then
        begin
          Writeln('SELFTEST FAILED: destroyed window identity changed the override');
          Result := 1;
        end;
        lOverrides.Remove(lTestOverrideKey);
      end;

      lOverrides.AddOrSetValue(lOverrideKey, 'Custom caption');
      SaveWindowCaptionOverridesToFile(lStateFileName, lOverrides, 12345);
      LoadWindowCaptionOverridesFromFile(lStateFileName, lLoadedOverrides, 12347);
      if ApplyWindowCaptionOverride(lLoadedOverrides, hWnd(100), 200, 'Normal caption') <> 'Custom caption' then
      begin
        Writeln('SELFTEST FAILED: window caption override did not reload within same boot');
        Result := 1;
      end;

      lLoadedOverrides.Clear;
      LoadWindowCaptionOverridesFromFile(lStateFileName, lLoadedOverrides, 22345);
      if HasWindowCaptionOverride(lLoadedOverrides, hWnd(100), 200) or TFile.Exists(lStateFileName) then
      begin
        Writeln('SELFTEST FAILED: window caption override survived simulated reboot');
        Result := 1;
      end;

      lOverrides.AddOrSetValue(lOverrideKey, 'Custom caption');
      lOverrides.AddOrSetValue(BuildWindowCaptionOverrideKey(hWnd(101), 200), 'Dead window caption');
      lWasPruned := PruneWindowCaptionOverrides(
        lOverrides,
        function(const aWnd: hWnd; const aProcessId: Cardinal): Boolean
        begin
          Result := (aWnd = hWnd(100)) and (aProcessId = 200);
        end);
      if (not lWasPruned) or HasWindowCaptionOverride(lOverrides, hWnd(101), 200) then
      begin
        Writeln('SELFTEST FAILED: window caption override prune did not remove dead entry');
        Result := 1;
      end;

      lOverrides.Remove(lOverrideKey);
      if HasWindowCaptionOverride(lOverrides, hWnd(100), 200) then
      begin
        Writeln('SELFTEST FAILED: window caption override reset did not remove override');
        Result := 1;
      end;
    finally
      lLoadedOverrides.Free;
      lOverrides.Free;
      if TDirectory.Exists(lTempDir) then
        TDirectory.Delete(lTempDir, True);
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
    if ShouldForceTerminateAsyncOnShutdown then
    begin
      Writeln('SELFTEST FAILED: startup shutdown policy must not force-terminate async worker threads');
      Result := 1;
    end;

    lCancelToken := TCancelToken.Create;
    lCallCount := 0;
    SetLength(lApps, 2);
    PrefetchDeepPrefixMetadataForApps(
      lApps,
      True,
      True,
      lCancelToken,
      procedure(const aApp: TAppInfo; const aNeedAppUserModelID: Boolean; const aNeedCmdParams: Boolean)
      begin
        Inc(lCallCount);
        lCancelToken.Cancel;
      end);
    if lCallCount <> 1 then
    begin
      Writeln(Format('SELFTEST FAILED: deep-prefix prefetch should stop after cancellation actual=%d',
        [lCallCount]));
      Result := 1;
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
var
  lNowTick: UInt64;
begin
  if IsShuttingDown then
    Exit;

  lNowTick := GetTickCount64;
  if fMachineOverviewEnabled and IsTimedActionDue(lNowTick,
    fLastMachineOverviewRefreshTick,
    fMachineOverviewDisplayRefreshIntervalMs) then
  begin
    fLastMachineOverviewRefreshTick := lNowTick;
    RefreshMachineOverview;
  end;
  if IsTimedActionDue(lNowTick, fLastWindowTitlePollingTick, fWindowTitlePollingIntervalMs) then
  begin
    fLastWindowTitlePollingTick := lNowTick;
    RefreshConsoleList;
  end;

  if fChatMonitorConfiguredEnabled and IsTimedActionDue(lNowTick, fLastChatMonitorTick, fChatMonitorIntervalMs) then
  begin
    fLastChatMonitorTick := lNowTick;
    StartChatMonitorProcessing;
  end;
end;

procedure TAppsViewMainFrm.RefreshConsoleList;
begin
  QueueGuiRefresh;
end;

procedure TAppsViewMainFrm.UpdateAppDetail(const aAllowExtendedMetadata: Boolean);
var
  lApp: TWindowSnapshot;
  lStream: TBytesStream;
begin
  if not TryGetWindowSnapshot(GetWnd(lbApps), lApp) then
  begin
    pnlAppDetails.Visible := False;
    fDisplayedDetail := Default(TWindowSnapshot);
    Exit;
  end;
  pnlAppDetails.Visible := True;
  edAppCaption.Text := ApplyWindowCaptionOverride(fWindowCaptionOverrides, lApp.Wnd, lApp.PID, lApp.Caption);
  edPid.Text := lApp.PID.ToString;
  edAppFileName.Text := lApp.FileName;
  edCommandLineParams.Text := lApp.CommandLineParams;
  edRelaunchCommand.Text := lApp.RelaunchCommand;
  edAppUserModelID.Text := lApp.AppUserModelID;
  if (not SameWindowSnapshotIdentity(lApp, fDisplayedDetail)) or
    (lApp.MetadataAttemptedAt <> fDisplayedDetail.MetadataAttemptedAt) then
  begin
    if Length(lApp.IconBytes) > 0 then
    begin
      lStream := TBytesStream.Create(lApp.IconBytes);
      try
        imgAppScreenshot.Picture.Icon.LoadFromStream(lStream);
      finally
        lStream.Free;
      end;
    end else
      imgAppScreenshot.Picture.Assign(nil);
  end;
  fDisplayedDetail := lApp;
  if aAllowExtendedMetadata and (not lApp.MetadataReady) and Assigned(fWindowService) then
    fWindowService.RequestDetails(lApp.Wnd, lApp.PID);
end;

procedure TAppsViewMainFrm.UpdateGui;
var
  lApp: TWindowSnapshot;
  lApps: TStringList;
  lConsole: TStringList;
  lExplorer: TStringList;
  lCaption: string;
  lTitle: string;
  lIsTerminal: Boolean;
begin
  if IsShuttingDown then
    Exit;
  ApplyLoadedWindowCaptionOverrideState;
  PruneWindowCaptionOverrides;
  if not IsStartupDataReady then
  begin
    QueueGuiRefresh;
    Exit;
  end;
  lApps := TStringList.Create;
  lConsole := TStringList.Create;
  lExplorer := TStringList.Create;
  try
    lApps.Sorted := True;
    lApps.Duplicates := dupAccept;
    lExplorer.Sorted := True;
    lExplorer.Duplicates := dupAccept;
    for lApp in fWindowBatch.Windows do
    begin
      if (lApp.Caption = '') or ExcludeByMask(lApp, fWindowBatch.HideMasks, True) then
        Continue;
      if SameText('explorer.exe', ExtractFileName(lApp.FileName)) then
      begin
        lExplorer.AddObject(lApp.Caption, TObject(lApp.Wnd));
        Continue;
      end;
      lIsTerminal := IsTerminalApp(lApp.FileName, fWindowBatch.TerminalPatterns);
      lCaption := ApplyWindowCaptionOverride(fWindowCaptionOverrides, lApp.Wnd, lApp.PID, lApp.Caption);
      lTitle := Trim(BuildWindowDisplayCaption(lCaption, lApp.FileName));
      CheckPrefixRule(lTitle, lApp, fWindowBatch.PrefixRules, True,
        (not lIsTerminal) and (lApp.MetadataReady or (wmIdentity in lApp.AvailableMetadata)));
      if lIsTerminal then
        lConsole.AddObject(lTitle, TObject(lApp.Wnd))
      else
        lApps.AddObject(lTitle, TObject(lApp.Wnd));
    end;
    SortConsoleItems(lConsole);
    SynchronizeListItems(lbApps, lApps);
    SynchronizeListItems(lbConsole, lConsole);
    SynchronizeListItems(lbExplorer, lExplorer);
    UpdateAppDetail(False);
  finally
    lExplorer.Free;
    lConsole.Free;
    lApps.Free;
  end;
end;

end.


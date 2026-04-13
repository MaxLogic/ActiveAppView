# Tasks
Next task ID: T-020

## Summary
Open tasks: 1 (In Progress: 0, Next Today: 1, Next This Week: 0, Next Later: 0, Blocked: 0)
Done tasks: 18

## In Progress

## Next – Today

### T-019 [TEST] Add regression coverage for launcher classification and crash containment
Outcome:
- Regression tests cover launcher decisions for folders, executables, `.lnk` targets, UNC paths, missing targets, and shell-fallback cases.
- The tests prove our normal launch path does not route folder or executable activation through in-process `ShellExecute`.
- Regression coverage keeps the helper-process crash boundary in place after the fix.
Proof:
- Run: `_build_verify/test-out-remediate/ActiveAppView.exe --self-test-launch-classification`
  Expect: exit code `0` with no `SELFTEST FAILED` output.
- Run: `rg -n -- "--self-test-launch-|ShellExecute|CreateProcess|IShellLink" _Source/ActiveAppView.SelfTests.pas _Source/ActiveAppViewMainForm.pas`
  Expect: launcher self-tests exist and the happy-path implementation is direct-launch oriented.
Touches: _Source/ActiveAppView.SelfTests.pas, _Source/ActiveAppViewMainForm.pas
Deps: T-018
Verify: unit-test, cli-proof
Notes: Keeps the shell-extension crash mitigation locked in after implementation.

## Next – This Week

## Next – Later

## Blocked

## Done

### T-018 [CORE] Isolate desktop and shortcut activation from in-process shell handlers
Outcome:
- Desktop and shortcut activation no longer invokes `ShellExecute` from the main VCL process for folders, executables, or resolved `.lnk` targets.
- Shell-dependent launch cases run through an isolated helper path with COM initialized before shell calls.
- Missing-target and unsupported-target handling still surfaces deterministic user feedback instead of crashing the main process.
Proof:
- Run: `_build_verify/test-out-remediate/ActiveAppView.exe --self-test-launch-helper-paths`
  Expect: exit code `0` with no `SELFTEST FAILED` output and coverage for folder, executable, `.lnk`, and shell-fallback classification.
- Run: `_build_verify/test-out-remediate/ActiveAppView.exe --self-test-launch-helper-crash-isolated`
  Expect: exit code `0` with no `SELFTEST FAILED` output and proof that helper launch failures do not terminate the main process.
Touches: _Source/ActiveAppView.dpr, _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppView.SelfTests.pas
Verify: integration-test, cli-proof
Notes: Based on the 2026-04-13 madExcept report showing `ActivateDesktopItem -> ShellExecuteW -> Windows.Storage -> TortoiseSVN32.dll`.

### T-017 [CHAT] Honor unread interval setting and accept all Unicode decimal unread digits
Outcome: `TChatMonitor` now treats all Unicode decimal digits (for example Devanagari digits) as valid unread counters, and unread notifications now honor `[ChatMonitor] UnreadMessageSoundIntervalSeconds` without a hidden 5-second minimum.
Proof:
- Command (RED): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-unread-caption
- Expect (RED): Exit code `1` with `SELFTEST FAILED: devanagari-digits expected=true actual=false ...`.
- Command (RED): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-interval-respected
- Expect (RED): Exit code `1` with `SELFTEST FAILED: sound interval expected=2 actual=1`.
- Command (GREEN): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-unread-caption
- Expect (GREEN): Exit code `0` with no `SELFTEST FAILED` output.
- Command (GREEN): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-interval-respected
- Expect (GREEN): Exit code `0` with no `SELFTEST FAILED` output.
- Command (pre-commit suite): run all self-test args (`core-command-line-params`, `chat-monitor-command-line-params`, `chat-monitor-review-rule-conjunction`, `chat-monitor-sound-fallback`, `chat-monitor-sound-toggle-throttle`, `chat-monitor-sound-throttle-failure-retry`, `chat-monitor-sound-interval-respected`, `chat-monitor-unread-caption`, `restore-item-index`, `startup-warmup-prefetch`, `startup-warmup-shutdown-check`, `config-cache-rule-spacing`, `chat-monitor-invalid-wnd`)
- Expect (pre-commit suite): `SUMMARY pass=13 fail=0`.
- Command (stress): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-config-cache-parse-benchmark
- Expect (stress): Exit code `0` and benchmark line output (`SELFTEST BENCHMARK: config-cache-parse ...`).
Touches: _Source/ActiveAppView.ChatMonitor.pas, CHANGELOG.md

### T-016 [CHAT] Accept Unicode unread counters and avoid throttling failed notifications
Outcome: `TChatMonitor` now treats Unicode decimal digits in unread counters (for example fullwidth digits) as valid unread counts, and `PlaySoundFile` now updates throttle state only when a notification sound/beep actually succeeds.
Proof:
- Command (RED): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-unread-caption
- Expect (RED): Exit code `1` with `SELFTEST FAILED: fullwidth-digits expected=true actual=false ...`.
- Command (RED): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-throttle-failure-retry
- Expect (RED): Exit code `1` with `SELFTEST FAILED: throttle failure retry expected=2 actual=1`.
- Command (GREEN): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-unread-caption
- Expect (GREEN): Exit code `0` with no `SELFTEST FAILED` output.
- Command (GREEN): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-throttle-failure-retry
- Expect (GREEN): Exit code `0` with no `SELFTEST FAILED` output.
- Command (pre-commit suite): run all self-test args (`core-command-line-params`, `chat-monitor-command-line-params`, `chat-monitor-review-rule-conjunction`, `chat-monitor-sound-fallback`, `chat-monitor-sound-toggle-throttle`, `chat-monitor-sound-throttle-failure-retry`, `chat-monitor-unread-caption`, `restore-item-index`, `startup-warmup-prefetch`, `startup-warmup-shutdown-check`, `config-cache-rule-spacing`, `chat-monitor-invalid-wnd`)
- Expect (pre-commit suite): `SUMMARY pass=12 fail=0`.
- Command (stress): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-config-cache-parse-benchmark
- Expect (stress): Exit code `0` and benchmark line output (`SELFTEST BENCHMARK: config-cache-parse ...`).
Touches: _Source/ActiveAppView.ChatMonitor.pas, CHANGELOG.md

### T-015 [CHAT] Preserve unread sound cooldown when sound is re-enabled
Outcome: `TChatMonitor` now updates `LastSoundPlayed` only when a sound/beep notification actually runs, so unread alerts can fire immediately after re-enabling sound.
Proof:
- Command (RED): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-toggle-throttle
- Expect (RED): Exit code `1` with `SELFTEST FAILED: sound toggle expected=1 actual=0`.
- Command (GREEN): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-sound-toggle-throttle
- Expect (GREEN): Exit code `0` with no `SELFTEST FAILED` output.
- Command (pre-commit suite): run all self-test args (`core-command-line-params`, `chat-monitor-command-line-params`, `chat-monitor-review-rule-conjunction`, `chat-monitor-sound-fallback`, `chat-monitor-sound-toggle-throttle`, `chat-monitor-unread-caption`, `restore-item-index`, `startup-warmup-prefetch`, `startup-warmup-shutdown-check`, `config-cache-rule-spacing`, `chat-monitor-invalid-wnd`)
- Expect (pre-commit suite): `SUMMARY pass=11 fail=0`.
- Command (stress): _build_verify/test-out-remediate/ActiveAppView.exe --self-test-config-cache-parse-benchmark
- Expect (stress): Exit code `0` and benchmark line output (`SELFTEST BENCHMARK: config-cache-parse ...`).
Touches: _Source/ActiveAppView.ChatMonitor.pas, CHANGELOG.md

### T-014 [CHAT] Require conjunctive include matching inside one review-mask rule line
Outcome: `TChatMonitor` now requires all populated include keys (`caption`, `filename`, `AppUserModelID`, `CmdParams`) from the same `ChatReviewMask.txt` rule line to match before the app is selected.
Proof:
- Command: _build_verify/test-out-remediate/ActiveAppView.exe --self-test-chat-monitor-review-rule-conjunction
- Expect: Exit code `0` with no `SELFTEST FAILED` output.
- Command: rg -n "RunReviewRuleConjunctionSelfTest|MatchesReviewRule\\(|all populated include keys" _Source/ActiveAppView.ChatMonitor.pas README.md ChatReviewMask.txt
- Expect: New regression self-test exists and docs state same-line include keys are conjunctive.
Touches: _Source/ActiveAppView.ChatMonitor.pas, README.md, ChatReviewMask.txt

### T-013 [CORE] Parse command-line params using whitespace delimiters in core metadata path
Outcome: `TAppInfo.CommandLineParams` now parses unquoted command lines using general whitespace delimiters (`space/tab/CR/LF`) so leading argument tokens are preserved.
Proof:
- Command: rg -n "GetCommandLineParams|CharInSet\\(s\\[i\\], \\[#9, #10, #13, ' '\\]\\)" _Source/ActiveAppViewCore.pas
- Expect: Parser scans unquoted executable tokens until any whitespace and then skips delimiter whitespace before copying params.
- Command: _build_verify/test-out-remediate/ActiveAppView.exe --self-test-core-command-line-params
- Expect: Exit code `0` with no `SELFTEST FAILED` output.
Touches: _Source/ActiveAppViewCore.pas, _Source/ActiveAppView.SelfTests.pas

### T-012 [CHAT] Add non-silent fallback when notification WAV cannot be played
Outcome: Chat notifications no longer fail silently when configured WAV files are missing or playback fails; the monitor falls back to a system beep while still honoring sound throttling.
Proof:
- Command: rg -n "PlaySoundFile|cFallbackSoundKey|MessageBeep|lHasSoundFile" _Source/ActiveAppView.ChatMonitor.pas
- Expect: `PlaySoundFile` resolves configured paths, keeps throttling, and calls `MessageBeep` when file playback cannot run.
- Command: rg -n "UnreadMessageSound|PwaClosedSound" settings.ini
- Expect: Default chat sound paths point to stable Windows media files.
Touches: _Source/ActiveAppView.ChatMonitor.pas, settings.ini, README.md

### T-005 [PERF] Deduplicate activation-triggered GUI refresh
Outcome: Form activation/focus events trigger at most one full `UpdateGui` run per activation burst, eliminating redundant back-to-back refreshes.
Proof:
- Command: rg -n "AppOnActivate|FormActivate|UpdateGui|MarkFormFocused" _Source/ActiveAppViewMainForm.pas
- Expect: Activation handlers contain a single refresh path or a guard that prevents duplicate `UpdateGui` calls for the same activation.
Touches: _Source/ActiveAppViewMainForm.pas

### T-006 [PERF] Move filesystem-heavy list refresh work off the UI thread
Outcome: Script/Desktop/ShortCuts scanning and parsing are built in a background snapshot and only final list assignment runs on the VCL main thread.
Proof:
- Command: rg -n "UpdateScriptsList|UpdateDesktopList|UpdateShortCutsList|SimpleAsyncCall|TThread\\.Queue|syncVclCall" _Source/ActiveAppViewMainForm.pas
- Expect: Expensive enumeration/parsing no longer runs inline in `UpdateGui`; UI updates are synchronized on the main thread.
Touches: _Source/ActiveAppViewMainForm.pas

### T-007 [PERF] Cache parsed mask and pattern files with file dependencies
Outcome: Prefix/Hide/Terminal/ShortCuts/ChatReview mask inputs are loaded via `MaxLogic.Cache` with file dependency stamps so unchanged files are not reparsed on each refresh.
Proof:
- Command: rg -n "MaxLogic\\.Cache|TMaxFileDependency|GetOrCreate|Dependency|ScopedTag" _Source/ActiveAppViewMainForm.pas _Source/ActiveAppView.ChatMonitor.pas
- Expect: Refresh and chat-monitor paths use cache-backed parsed snapshots with dependency-based invalidation.
Touches: _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppView.ChatMonitor.pas

### T-008 [PERF] Run chat monitor processing in background with overlap guard
Outcome: `tmrChatMonitor` schedules monitor work asynchronously and prevents overlapping scans when the previous cycle is still running.
Proof:
- Command: rg -n "tmrChatMonitorTimer|fChatMonitor|SimpleAsyncCall|TInterlocked|busy|overlap" _Source/ActiveAppViewMainForm.pas
- Expect: Timer handler no longer executes the full monitor scan inline and includes a non-overlap guard.
Touches: _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppView.ChatMonitor.pas

### T-009 [PERF] Parallelize expensive window metadata retrieval for matching
Outcome: Command-line/AppUserModelID/Relaunch metadata retrieval is prefetched in bounded worker batches so matching no longer blocks on serial WMI/COM calls.
Proof:
- Command: rg -n "CommandLineParams|AppUserModelID|RelaunchCommand|prefetch|parallel|worker|SimpleAsyncCall|TAsyncLoop" _Source/ActiveAppViewCore.pas _Source/ActiveAppView.ChatMonitor.pas
- Expect: Metadata-heavy fields are retrieved through a bounded parallel/prefetch flow before rule matching uses them.
Touches: _Source/ActiveAppViewCore.pas, _Source/ActiveAppView.ChatMonitor.pas

### T-010 [PERF] Share one window snapshot between GUI and chat monitor
Outcome: GUI refresh and chat monitoring consume a shared app snapshot per cycle instead of independently scanning windows with separate `TAppList` instances.
Proof:
- Command: rg -n "TAppList|Update\\(|snapshot|shared|ChatMonitor|AppsViewMainFrm" _Source/ActiveAppViewMainForm.pas _Source/ActiveAppView.ChatMonitor.pas _Source/ActiveAppViewCore.pas
- Expect: Duplicate full window scans are replaced by a shared snapshot/update pipeline.
Touches: _Source/ActiveAppViewCore.pas, _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppView.ChatMonitor.pas

### T-011 [PERF] Replace unread regex hot path with lightweight parser
Outcome: Unread-caption detection avoids `TRegEx.IsMatch` per app and uses a low-allocation parser for the `(<digits>)` pattern.
Proof:
- Command: rg -n "TRegEx\\.IsMatch|cUnreadMessagesPattern|HasUnreadMessages|ParseUnread|IsUnreadCaption" _Source/ActiveAppView.ChatMonitor.pas
- Expect: Monitor hot path uses a parser helper instead of regex matching for every candidate caption.
Touches: _Source/ActiveAppView.ChatMonitor.pas

### T-001 [CHAT] Add text-file filter for chat review entries
Outcome: Chat monitoring can be constrained by a text file (PrefixMask-style masks) so only selected app entries are reviewed for unread-message detection.
Proof:
- Command: rg -n "ChatReviewMask|LoadReview|ShouldReview" _Source/ActiveAppView.ChatMonitor.pas
- Expect: Chat monitor includes a loader and matcher for a new review-mask text file, and `Process` uses it before adding monitored app states.
- Command: rg -n "ChatMonitorMask|ChatReview" README.md settings.ini
- Expect: Config keys/files for review filtering are discoverable from project docs/config.
Touches: _Source/ActiveAppView.ChatMonitor.pas, README.md, settings.ini

### T-002 [UI] Add sound toggle checkbox for chat notifications
Outcome: The main form includes a checkbox that enables/disables chat notification sounds at runtime, with persisted value in `settings.ini`.
Proof:
- Command: rg -n "CheckBox|Sound|cbChat" _Source/ActiveAppViewMainForm.pas _Source/ActiveAppViewMainForm.dfm _Source/ActiveAppView.ChatMonitor.pas
- Expect: A checkbox exists in the form, wired to an event that updates monitor runtime behavior and persists the setting.
- Command: rg -n "SoundEnabled|NotificationsSound|ChatMonitor" settings.ini
- Expect: Chat monitor sound setting key is present in configuration.
Touches: _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppViewMainForm.dfm, _Source/ActiveAppView.ChatMonitor.pas, settings.ini

### T-003 [DOC] Add default review-mask file and feature notes
Outcome: Repository includes a default chat review mask text file and README notes explaining format, matching fields, and sound-toggle behavior.
Proof:
- Command: rg -n "ChatReviewMask|ChatMonitorMask|sound" README.md
- Expect: README describes the new mask file and sound toggle.
- Command: ls -la ChatReviewMask.txt
- Expect: Default chat review mask file exists at repo root.
Touches: README.md, ChatReviewMask.txt
Deps: T-001, T-002

### T-004 [CHAT] Replace INI rules with review-mask-only workflow
Outcome: Chat monitoring no longer uses `[ChatMonitor.Rules]`; apps are selected only by `ChatReviewMask.txt`, and unread detection uses the fixed caption pattern `(\d+)`.
Proof:
- Command: rg -n "ChatMonitor\\.Rules|UnreadPattern|TChatAppRule|fRules" _Source/ActiveAppView.ChatMonitor.pas settings.ini
- Expect: Legacy INI rule model is removed from monitor code and sample settings.
- Command: rg -n "cUnreadMessagesPattern|ShouldReviewApp|ChatReviewMask" _Source/ActiveAppView.ChatMonitor.pas README.md ChatReviewMask.txt
- Expect: Monitor uses review-mask-only selection and fixed unread pattern documentation.
Touches: _Source/ActiveAppView.ChatMonitor.pas, settings.ini, README.md, ChatReviewMask.txt

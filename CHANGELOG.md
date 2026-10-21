# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- `Scripts\x-mouse.ps1` toggles the MouseBeam executable at `F:\projects\MaxLogic\MouseBeam\xMouse.exe`, trying a graceful close before forced termination and ignoring instances at other paths (ACV-076).
- Machine Overview incident history now shows measured CPU contributors before, during, and after an incident, including exited processes, application groups, sampling gaps, recording health (session start, dropped records, and provider status), and a Copy evidence command (ACV-067, ACV-068).
- VMware Player and Workstation windows now have a `VM - ` prefix in Applications.
- Applications (F1) now has All, New messages, and Non-responsive filters, selected with Ctrl+1/2/3 while the list has focus.
- Console instances (F4) now has a Non-responsive filter (Ctrl+6).
- Machine Overview (F8) has a Temperatures row after GPU with CPU, GPU, and chassis readings; unavailable sensors say why. Rows that open more detail with Enter show `*` after their label.
- Machine Overview reads the CPU temperature from Core Temp when it is running (no elevation needed).
- Top CPU applications show both the share of the whole machine and the load in cores, e.g. `0.7% (23% of one core)`; a process using five cores shows `500% of one core`.

### Changed
- Machine Overview migration now backs up and verifies the current input for each schema upgrade; retained older backups are cleaned up after success. Memory-pressure recovery requires physical use strictly below 90%, keeping the exact 90% paging activation boundary distinct (ACV-071).
- Machine Overview reduces noisy hot-logical-processor and paging incidents with sustained machine-relative thresholds and a physical-memory pressure requirement. History schema v4 fixes per-processor CPU recording and stores paging and physical-use signals; a read-only replay command compares legacy and tuned rules (ACV-071).
- Machine Overview background sampling uses less than half the CPU it did (about 6% of one core instead of 15% on a 32-thread machine). The Responsiveness row no longer shows the processor queue length, which alone cost about 50 ms of CPU per second to read.
- Console instances now knows Claude sessions whose window title shows no marker, and Claude sessions waiting for input behind an idle title. It reads Claude Code's own session registry and finds `claude.exe`/`codex.exe` (also a self-updated `claude.exe.old.*`) below each terminal.
- A Setup harnesses... button adds a state hook to Claude Code and Codex on Windows and in WSL, after a preview and with a backup. Hooked sessions report working, idle, and permission waits directly instead of through title guesses.
- Console instances has a Non Codex/Claude filter (Ctrl+5) for terminals without an agent title marker. Switching any console filter now plays a short spoken confirmation of the selected filter.
- `Scripts\save-md.ps1` saves clipboard text as a temporary Markdown file and copies its full path back to the clipboard.
- Console instances has All, Idle Codex/Claude, Working Codex/Claude, and Action required filters. Ctrl+1 through Ctrl+4 switch filters only while the Console list has focus. Detection uses terminal title markers and the idle `task | project` heuristic; Action required selects idle entries containing that phrase.
- `Scripts\Copy-MarkdownAsRichText.ps1` now always converts clipboard markdown to HTML (CF_HTML with the original markdown as text fallback), without a format menu. The library still supports RTF and plain text (ACV-075).

### Fixed
- Incident-view self-tests use an in-memory clipboard adapter for exact-copy and failure checks, leaving the system clipboard untouched (ACV-077).
- Machine Overview history now deletes its verified migration backup after a successful upgrade and cleanup, including after a resumed migration. Failed migrations retain the backup; deletion failures are reported without stopping recording (ACV-074).
- Incident evidence rows now include the process start date when it differs from the incident's local day. Shorter Average/Peak cells and state rows fit at 100% scaling while retaining the machine-share units and full details (ACV-073).
- Machine Overview history now applies one storage budget to samples, incident evidence, and headlines, retaining incidents for up to 365 days and 50,000 entries. Older databases are backed up before migration; obsolete context is removed and startup can reclaim its disk space (ACV-067).
- Closing ActiveAppView now cancels chat-monitor metadata queries, so a stalled WMI provider cannot hold shutdown open.
- Applications and File Explorer lists now populate when a bounded Codex session-log read starts inside a UTF-8 character.
- Windows ghost windows now resolve to the original application HWND, PID, and filename, so unresponsive terminals stay in Console instances and do not create duplicate application rows.
- Console instances (F4) recovers idle Codex sessions after a refusal or other turn completion misses the Stop hook, using newer session-log events; a subsequent turn restores working state.
- Console instances (F4) now sorts Claude Code titles by their readable text when a Claude idle symbol or working spinner prefixes the title.
- Window list selection no longer jumps to an unrelated row after a refresh. A window whose title is briefly empty keeps its last known title and stays listed. When the selected window really disappears, the selection moves to another window of the same process, otherwise to the next row it had (or the previous one at the end of the list), instead of whatever row now sits at the old position. Selection-loss events are recorded in `selection-trace.log` (1 MB, two rotated copies kept).
- Closing a window with Ctrl+W or Terminate no longer moves the selection when the window finishes closing later and we have already moved to another row.
- Scripts, Desktop items, and ShortCuts now start with a clean user environment rebuilt from the registry instead of inheriting ActiveAppView's own. A terminal opened from the Desktop list had inherited `CLAUDE_CODE_CHILD_SESSION` from the shell that started ActiveAppView, which turned off transcript saving in the next Claude Code session. Scripts now go through the same isolated launch helper and run with the Scripts folder as working directory.
- Enter now brings a minimized elevated window, such as an elevated terminal, to the front while ActiveAppView runs non-elevated. Windows refused our restore call across the elevation boundary, so the window stayed minimized; we now fall back to a posted restore command.
- Elevated terminal windows now appear in Console instances while ActiveAppView runs non-elevated. The process path lookup asked for more access than it needed, so elevated windows had no file name and were never recognized as terminals.
- Window metadata now arrives by need: selected-window identity and icons can appear before command-line retrieval, and windows from the same process reuse its command line.
- Foreground refresh now collects window inventories and slow metadata in the background, with coalesced updates and cancellable metadata helpers.
- Window and auxiliary lists now preserve unchanged rows, selection, and scroll position during synchronization; selected-window details arrive asynchronously.
- Delayed command-line copy requests retain their window identity and cannot overwrite newer clipboard content.
- Focus sound playback now runs from application foreground activation, so returning to ActiveAppView triggers the configured WAV.
- Window-action context menus now freeze and revalidate the exact clicked HWND/PID, fail closed when the list refreshes or the popup source changes, and no longer crash or act on another row.
- Window-caption overrides now publish schema-v5 Rename, replacement Rename, Reset, and observed expiration lifecycle events with retained boot/process identity; the same bounded worker handles SQLite, process observation, atomic state persistence, and deterministic dropped-event diagnostics.
- Caption-override state loading, one-time legacy upgrade, process identity enrichment, and atomic persistence now run on the existing background writer; Rename and Reset no longer write the override INI on the UI thread.
- Window-caption rename journaling now uses one bounded FIFO background writer instead of opening and writing SQLite on the VCL thread; queue overflow and SQLite failures remain fail-open.
- Confirmed Rename actions now revalidate that the HWND still exists and belongs to the captured PID before saving the override or journaling it.
- Rename on an already-renamed Applications or Console item now opens with the current displayed caption selected instead of an empty edit box.
- Shutdown no longer calls `TThread.Terminate` through the async stop path, avoiding `EThread: Cannot terminate an externally created thread` during application exit.
- ShortCuts entries now open unquoted file/folder paths containing spaces, while still supporting quoted targets with arguments and command-style entries.
- Main form columns now resize proportionally to the form width, preserving the design-time column ratios on smaller screens.
- Desktop and shortcut activation now runs through an isolated helper process, so third-party shell extension crashes during item launch no longer terminate `ActiveAppView.exe`.
- Console window title polling now refreshes existing Console entries without forcing a full app scan on every timer tick.

### Added
- Foreground and snapshot operations taking at least 50 ms are recorded in a bounded memory buffer and saved to `startup-profile.log` at normal shutdown.
- ActiveAppView can now play the WAV file configured by `[FocusSound] File` when the application gains foreground focus; an absent, blank, or missing file stays silent.
- Applications, Explorer, and Console context menus can now copy the selected window's full executable path, full command line, PID, or HWND.
- Machine Overview can now capture an opt-in 15-second WPR incident trace with General and GPU profiles, unique-session cleanup, explicit requested/captured/failed/unavailable history state, and oldest-first 10-file/2-GB retention without blocking monitoring.
- Machine Overview now reports WDDM busiest-engine GPU load, rolling averages and peaks, dedicated GPU memory, and optional age-stamped NVIDIA temperature/power and conservatively identified CPU package temperature with bounded provider failure handling.
- Machine Overview's incident row now opens a keyboard-accessible 24-hour, 7-day, or complete history view with stable selection, full incident details, and explicit busy-database degradation.
- Machine Overview now detects sustained CPU, logical-processor, DPC/interrupt, foreground-response, DWM, memory, disk, GPU, thermal, provider-health, and pipeline incidents with bounded context, deduplication, recovery, restart-safe history, user-marked points, and latest-incident summaries.
- Machine Overview now keeps bounded executable-local SQLite history for system, disk, and ranked process samples, with 10-second/one-minute rollups, transactional migration backup, retention, storage caps, and fail-open diagnostics for locked or corrupt databases.
- Machine Overview includes executable-local plain-text help in a keyboard-accessible modal dialog, with an explicit missing-file fallback and Debug/Release Win64 packaging.
- A default-enabled Machine Overview panel now presents live machine health, CPU and memory context, responsiveness, disk status, and ranked processes in a named keyboard-accessible list with complete row and diagnostic copy commands plus display freeze/resume.
- Successful window-caption Rename actions can now be written to Shadow Journal with their UTC timestamp, PID, HWND, and Unicode caption through the opt-in `[save-renames-to-journal]` settings.
- Chat monitor now supports a PrefixMask-style review filter file (`ChatReviewMask.txt`), configured by `[ChatMonitor] ReviewMaskFile` in `settings.ini`.
- Main form now includes a `Play chat notification sounds` checkbox that toggles chat sounds at runtime and persists to `[ChatMonitor] SoundEnabled`.
- Applications and Console instances now support per-window caption overrides via context-menu Rename; overrides survive tool restarts within the current Windows boot, expire after reboot, and dialog Reset restores the live window title while preserving the normal filename/path display and preventing Enter-confirm from activating the selected window.
- Console window title polling is configurable with `[WindowTitlePolling] RefreshIntervalSeconds` in `settings.ini`.
- Scripts can now be hidden from the F3 Scripts list with a `Scripts\.ignore` file, one filename per line.

### Changed
- Machine Overview now ranks applications instead of individual processes by aggregating CPU, RAM, and I/O for matching executable names. Rows show up to five member PIDs plus the remaining count, while Ctrl+Shift+C diagnostics include every member PID.
- Machine Overview now reports real 5/15/60-second and 15-minute rolling values for system and ranked-process metrics, labels process I/O with byte-correct rates, marks insufficient window coverage stale, ages cached provider state, and includes per-provider collection latency in diagnostic copies.
- Machine Overview now packages the official Win64 SQLite 3.53.4 runtime and uses FireDAC dynamic linkage, satisfying the maintained-runtime requirement for WAL history.
- Machine Overview now restores its DPI-scaled panel width across restarts and offers a layout-preserving Full View that returns every prior panel and splitter exactly.
- Desktop recovery launchers now delegate to PowerShell scripts that discover NVDA, MouseBeam, and Logi Options+ paths at runtime instead of relying on fixed local paths.
- Applications and Explorer lists now support window actions via context menu (`Close`, `Terminate`) and `Ctrl+W` on focused list items for normal close.
- Post-close/post-terminate cleanup now retries process/window validation with increasing delays for up to 5 seconds, removing entries only after the target is actually gone; refocus still performs a quick stale-entry prune before full refresh.
- Unread caption parsing now accepts all Unicode decimal digits (including fullwidth, Arabic-Indic, and Devanagari digits) inside supported parentheses, preserving unread detection for localized counters.
- Unread notification playback now uses the configured `[ChatMonitor] UnreadMessageSoundIntervalSeconds` value directly, including intervals below 5 seconds.
- Chat notification sound throttling now updates only after a playback/beep succeeds, so failed notification attempts do not suppress immediate retry.
- Chat monitor now preserves unread-notification cooldown when sound is disabled, so re-enabling sound can notify immediately for already-unread apps.
- Chat monitor review-mask matching now treats multiple include keys on one rule line as conjunctive (all populated include keys must match), reducing false-positive monitoring for broad executable-only matches.
- Chat notification playback now falls back to a system beep when a configured WAV file is missing or cannot be played, preventing silent watchdog notifications.
- Default chat sound paths in `settings.ini` now use repo-relative `assets\wav\...` files instead of machine-specific project paths.
- Chat monitor worker now processes an immutable copied app snapshot per cycle, preventing range-check crashes caused by concurrent shared-snapshot updates.
- Chat app selection now comes only from `ChatReviewMask.txt`; legacy `[ChatMonitor.Rules]` matching is no longer used.
- Unread detection now uses a fixed caption counter pattern `(\d+)`.
- Unread counter parsing now tolerates directional-mark padding and fullwidth parentheses, but requires a closing parenthesis terminator (malformed `(\d+(` captions are ignored).
- Core app metadata command-line parameter parsing now recognizes tab/newline whitespace delimiters for unquoted executable paths, preserving the full leading argument token.
- GUI refresh activation bursts are now deduplicated to avoid back-to-back full redraws.
- Scripts/Desktop/ShortCuts refresh now runs through background snapshot workers, with only final UI assignment on the main thread.
- Mask and pattern parsing now uses cache-backed snapshots (`MaxLogic.Cache` + file dependencies) to avoid reparsing unchanged files.
- Chat monitor processing now runs asynchronously with overlap guards, uses shared app snapshots, and prefetches expensive metadata in parallel.
- Chat unread detection hot path now uses a lightweight caption parser instead of regex matching per app.
- Startup metadata warm-up now preloads only window file names first, defers deep prefix metadata to a second async phase, and keeps auxiliary list refresh immediate.
- Terminal and Explorer list routing is now filename-first before prefix checks, and skips deep metadata matching for those buckets to avoid slow first population.
- Shutdown now blocks new async scheduling, restores activation hooks early, and forcibly stops stuck background workers to avoid dangling `ActiveAppView.exe` processes.

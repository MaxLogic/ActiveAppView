# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Fixed
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

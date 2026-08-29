# ActiveAppView
Accessibility tool for active application / explorer quick selection

## Hotkeys
- F1: Applications
- F2: Explorer
- F3: Scripts
- F4: Console instances
- F6: Desktop
- F7: ShortCuts
- F8: Machine Overview
- F5: Refresh all lists

## Machine Overview

- The rightmost panel shows current CPU, memory, GPU, responsiveness, disk, process, and incident signals. It is enabled by default and can be disabled with `[MachineOverview] Enabled=0` in `settings.ini`.
- `F8` focuses the row list, `Ctrl+E` freezes or resumes display updates, and `Shift+F8` toggles Full View without changing the saved layout.
- `Ctrl+C` copies the complete selected row. `Ctrl+Shift+C` copies a timestamped diagnostic snapshot. Enter on Incidents opens history, and `Alt+H` opens the shipped help.
- Collection, incident detection, and bounded SQLite history run in the background. Freeze affects only visible updates; provider and history failures degrade to explicit stale/unavailable status without stopping live monitoring.

## TerminalPatterns.txt (next to ActiveAppView.exe)
- One wildcard pattern per line (`*` and `?`), case-insensitive.
- Lines starting with `#` or `;`, or empty lines, are ignored.
- Patterns match against the full executable path (e.g., `C:\Windows\System32\cmd.exe`).

## Window title polling
- Terminal window titles in the Console list are refreshed periodically.
- Configure the interval in `settings.ini` under `[WindowTitlePolling] RefreshIntervalSeconds`.
- Set `RefreshIntervalSeconds=0` to disable periodic title polling.

## Shadow Journal rename history
- Successful Applications and Console Rename, Reset, and observed expiration transitions can be appended to Shadow Journal's schema-v5 `window_caption_override_events` table.
- Configure `[save-renames-to-journal]` in `settings.ini` with `enabled=1` and the exact existing SQLite filename in `db-file`.
- ActiveAppView sends immutable lifecycle events to one background SQLite writer in FIFO order, with a 64-event non-blocking queue. Queue overflow is logged and leaves the local caption override intact.
- ActiveAppView does not create or migrate the journal database. Missing databases, missing migration 005, locked-database failures, and other SQLite write failures leave the local caption override intact.
- After the Rename dialog closes, ActiveAppView verifies that the HWND still exists and belongs to the captured PID before saving or journaling the new caption.
- Reset ends the current label with `user_reset`; the worker also emits `expired` for observed window disappearance, process exit, identity change, or local prune. The retained boot/process identity lets those end events identify a process after its window has gone.
- Local caption overrides use typed `StateVersion=2` records with boot, process-start, PID, HWND, caption, and lifecycle metadata. The existing caption-only INI is upgraded once when its boot and live process identity can be verified.
- The same owned background worker prewarms Windows identity, loads/upgrades the state file, coalesces rapid changes to one latest snapshot, and atomically replaces the state file. Rename and Reset handlers perform no filesystem or process-start identity queries.
- Windows has no durable HWND generation. The worker expires every observed disappearance or identity change, but same-process HWND reuse between observations remains a documented residual limitation.

## Scripts folder
- The Scripts list shows runnable files from `Scripts` next to `ActiveAppView.exe`.
- Supported runnable extensions are `.cmd`, `.bat`, `.ps1`, `.exe`, and `.py`.
- Add helper scripts to `Scripts\.ignore`, one filename per line, to keep them out of the F3 Scripts list.
- `.ignore` entries are matched case-insensitively by filename. Empty lines and `#` comments are ignored.

## ShortCuts.txt (next to ActiveAppView.exe)
- One mapping per line: `KEY=VALUE` (KEY may include spaces).
- VALUE is everything after the first `=`.
- Lines starting with `#` or `;`, or empty lines, are ignored.
- Unquoted file/folder paths with spaces are supported. If the unquoted value also has arguments,
  the parser uses the longest existing file/folder prefix as the target.
- Command aliases without path separators keep the traditional `command args` split.
- Double-quoted VALUE is supported for paths with spaces and explicit arguments, e.g.:
  - `putty="C:\Program Files\PuTTY\putty.exe" --start prod`

## ChatReviewMask.txt (next to ActiveAppView.exe)
- PrefixMask-style file used to select which apps are reviewed by chat monitoring.
- One comma-separated `key=value` rule per line.
- Supported include keys: `caption`, `filename`, `AppUserModelID`, `CmdParams`.
- Supported exclude keys: `excludeCaption`, `excludeFilename`, `excludeAppUserModelID`, `excludeCmdParams`.
- Exclude keys are checked against the same metadata and suppress review if they match.
- Lines starting with `#` or `;`, or empty lines, are ignored.
- Behavior:
  - This file is the only source for selecting monitored apps.
  - If file is missing or has no active rules, no apps are reviewed.
  - If rules exist, an app is reviewed only when it matches at least one rule.
- Within one rule line, all populated include keys (`caption`, `filename`, `AppUserModelID`, `CmdParams`) must match (conjunctive / logical AND).
  - Exclude rules can remove apps from selection even if another rule matches.
  - Unread state is detected by caption pattern `(\d+)` (number inside parentheses).

## Chat Notification Sound Toggle
- Main form includes `Play chat notification sounds` checkbox.
- Checkbox value is persisted to `settings.ini` under `[ChatMonitor] SoundEnabled`.
- Toggle applies immediately and controls unread + PWA-closed sound notifications.

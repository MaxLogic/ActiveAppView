# ActiveAppView
Accessibility tool for active application / explorer quick selection

## Hotkeys
- F1: Applications
- F2: Explorer
- F3: Scripts
- F4: Console instances
- F6: Desktop
- F7: ShortCuts
- F5: Refresh all lists

## TerminalPatterns.txt (next to ActiveAppView.exe)
- One wildcard pattern per line (`*` and `?`), case-insensitive.
- Lines starting with `#` or `;`, or empty lines, are ignored.
- Patterns match against the full executable path (e.g., `C:\Windows\System32\cmd.exe`).

## Window title polling
- Terminal window titles in the Console list are refreshed periodically.
- Configure the interval in `settings.ini` under `[WindowTitlePolling] RefreshIntervalSeconds`.
- Set `RefreshIntervalSeconds=0` to disable periodic title polling.

## Shadow Journal rename history
- Successful Applications and Console Rename actions can be appended to Shadow Journal's `window_rename_events` table.
- Configure `[save-renames-to-journal]` in `settings.ini` with `enabled=1` and the exact existing SQLite filename in `db-file`.
- ActiveAppView sends immutable rename events to one background SQLite writer in FIFO order, with a 64-event non-blocking queue. Queue overflow is logged and leaves the local caption override intact.
- ActiveAppView does not create or migrate the journal database. Missing databases, missing migration 004, locked-database failures, and other SQLite write failures leave the local caption override intact.
- After the Rename dialog closes, ActiveAppView verifies that the HWND still exists and belongs to the captured PID before saving or journaling the new caption.
- Reset actions are not journaled because they remove an ActiveAppView display override rather than assign a new caption.
- Local caption overrides use typed `StateVersion=2` records with boot, process-start, PID, HWND, caption, and lifecycle metadata. The existing caption-only INI is upgraded once when its boot and live process identity can be verified.
- The same owned background worker prewarms Windows identity, loads/upgrades the state file, coalesces rapid changes to one latest snapshot, and atomically replaces the state file. Rename and Reset handlers perform no filesystem or process-identity queries.

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

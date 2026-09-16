# ActiveAppView
Accessibility tool for active application / explorer quick selection

## Hotkeys
- F1: Applications
- F2: Explorer
- F3: Scripts
- F4: Console instances
- Ctrl+1 / Ctrl+2 / Ctrl+3 / Ctrl+4, while Console instances has focus: All / Idle Codex or Claude / Working Codex or Claude / Action required
- F6: Desktop
- F7: ShortCuts
- F8: Machine Overview
- F5: Refresh all lists

## Machine Overview

- The rightmost panel shows current CPU, memory, GPU, responsiveness, disk, application, and incident signals. CPU, RAM, and I/O ranks aggregate processes with the same executable name; each row shows up to five PIDs and Ctrl+Shift+C diagnostics include the complete PID lists. It is enabled by default and can be disabled with `[MachineOverview] Enabled=0` in `settings.ini`.
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

## Console activity filter
- The dropdown above Console instances starts at All. Ctrl+1 through Ctrl+4 work only while the Console list itself has focus, and preserve that focus. F4 returns to the list; the dropdown can also be operated directly.
- Filtering uses the original terminal title, before local Rename labels or display prefixes. Windows Terminal and Alacritty are included by the shipped `TerminalPatterns.txt`.
- Working includes leading Braille spinner characters and Claude's half-circle spinner. Idle includes Claude's asterisk markers, Codex's Action Required titles, and the approved `task | project` title-format heuristic. Unknown titles appear only in All.
- Action required shows the subset of idle Codex/Claude entries whose original title contains `action required`, ignoring case. These entries also remain in Idle.
- This is title-based detection: an unrelated terminal using those title formats can match, and disabled or custom titles can hide an agent's state. Windows Terminal exposes the current window title, so inactive tabs and split panes are not separately classified. Idle means the title is ready for input or needs attention; background jobs may still be running.
- Codex's [title implementation](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs) describes its activity prefix. Claude markers are based on reported behavior in [the older spinner report](https://github.com/anthropics/claude-code/issues/69306) and [the half-circle spinner report](https://github.com/anthropics/claude-code/issues/88360), rather than a guaranteed API.

## Focus sound
- ActiveAppView plays the WAV file configured by `[FocusSound] File` when the application gains foreground focus.
- Relative paths start from the executable directory. An absent, blank, or missing file stays silent.

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

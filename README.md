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

## ShortCuts.txt (next to ActiveAppView.exe)
- One mapping per line: `KEY=VALUE` (KEY may include spaces).
- VALUE is everything after the first `=`.
- Lines starting with `#` or `;`, or empty lines, are ignored.
- Double-quoted VALUE is supported for paths with spaces; arguments are allowed, e.g.:
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
  - Exclude rules can remove apps from selection even if another rule matches.
  - Unread state is detected by caption pattern `(\d+)` (number inside parentheses).

## Chat Notification Sound Toggle
- Main form includes `Play chat notification sounds` checkbox.
- Checkbox value is persisted to `settings.ini` under `[ChatMonitor] SoundEnabled`.
- Toggle applies immediately and controls unread + PWA-closed sound notifications.

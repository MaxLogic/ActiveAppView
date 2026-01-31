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

# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- Chat monitor now supports a PrefixMask-style review filter file (`ChatReviewMask.txt`), configured by `[ChatMonitor] ReviewMaskFile` in `settings.ini`.
- Main form now includes a `Play chat notification sounds` checkbox that toggles chat sounds at runtime and persists to `[ChatMonitor] SoundEnabled`.

### Changed
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

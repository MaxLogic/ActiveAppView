# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Fixed
- Main form columns now resize proportionally to the form width, preserving the design-time column ratios on smaller screens.
- Desktop and shortcut activation now runs through an isolated helper process, so third-party shell extension crashes during item launch no longer terminate `ActiveAppView.exe`.

### Added
- Chat monitor now supports a PrefixMask-style review filter file (`ChatReviewMask.txt`), configured by `[ChatMonitor] ReviewMaskFile` in `settings.ini`.
- Main form now includes a `Play chat notification sounds` checkbox that toggles chat sounds at runtime and persists to `[ChatMonitor] SoundEnabled`.

### Changed
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

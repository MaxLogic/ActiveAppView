# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- Chat monitor now supports a PrefixMask-style review filter file (`ChatReviewMask.txt`), configured by `[ChatMonitor] ReviewMaskFile` in `settings.ini`.
- Main form now includes a `Play chat notification sounds` checkbox that toggles chat sounds at runtime and persists to `[ChatMonitor] SoundEnabled`.

### Changed
- Chat app selection now comes only from `ChatReviewMask.txt`; legacy `[ChatMonitor.Rules]` matching is no longer used.
- Unread detection now uses a fixed caption counter pattern `(\d+)`.

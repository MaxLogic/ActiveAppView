# Tasks
Next task ID: T-005

## Summary
Open tasks: 0 (In Progress: 0, Next Today: 0, Next This Week: 0, Next Later: 0, Blocked: 0)
Done tasks: 4

## In Progress

## Next – Today

## Next – This Week

## Next – Later

## Blocked

## Done

### T-001 [CHAT] Add text-file filter for chat review entries
Outcome: Chat monitoring can be constrained by a text file (PrefixMask-style masks) so only selected app entries are reviewed for unread-message detection.
Proof:
- Command: rg -n "ChatReviewMask|LoadReview|ShouldReview" _Source/ActiveAppView.ChatMonitor.pas
- Expect: Chat monitor includes a loader and matcher for a new review-mask text file, and `Process` uses it before adding monitored app states.
- Command: rg -n "ChatMonitorMask|ChatReview" README.md settings.ini
- Expect: Config keys/files for review filtering are discoverable from project docs/config.
Touches: _Source/ActiveAppView.ChatMonitor.pas, README.md, settings.ini

### T-002 [UI] Add sound toggle checkbox for chat notifications
Outcome: The main form includes a checkbox that enables/disables chat notification sounds at runtime, with persisted value in `settings.ini`.
Proof:
- Command: rg -n "CheckBox|Sound|cbChat" _Source/ActiveAppViewMainForm.pas _Source/ActiveAppViewMainForm.dfm _Source/ActiveAppView.ChatMonitor.pas
- Expect: A checkbox exists in the form, wired to an event that updates monitor runtime behavior and persists the setting.
- Command: rg -n "SoundEnabled|NotificationsSound|ChatMonitor" settings.ini
- Expect: Chat monitor sound setting key is present in configuration.
Touches: _Source/ActiveAppViewMainForm.pas, _Source/ActiveAppViewMainForm.dfm, _Source/ActiveAppView.ChatMonitor.pas, settings.ini

### T-003 [DOC] Add default review-mask file and feature notes
Outcome: Repository includes a default chat review mask text file and README notes explaining format, matching fields, and sound-toggle behavior.
Proof:
- Command: rg -n "ChatReviewMask|ChatMonitorMask|sound" README.md
- Expect: README describes the new mask file and sound toggle.
- Command: ls -la ChatReviewMask.txt
- Expect: Default chat review mask file exists at repo root.
Touches: README.md, ChatReviewMask.txt
Deps: T-001, T-002

### T-004 [CHAT] Replace INI rules with review-mask-only workflow
Outcome: Chat monitoring no longer uses `[ChatMonitor.Rules]`; apps are selected only by `ChatReviewMask.txt`, and unread detection uses the fixed caption pattern `(\d+)`.
Proof:
- Command: rg -n "ChatMonitor\\.Rules|UnreadPattern|TChatAppRule|fRules" _Source/ActiveAppView.ChatMonitor.pas settings.ini
- Expect: Legacy INI rule model is removed from monitor code and sample settings.
- Command: rg -n "cUnreadMessagesPattern|ShouldReviewApp|ChatReviewMask" _Source/ActiveAppView.ChatMonitor.pas README.md ChatReviewMask.txt
- Expect: Monitor uses review-mask-only selection and fixed unread pattern documentation.
Touches: _Source/ActiveAppView.ChatMonitor.pas, settings.ini, README.md, ChatReviewMask.txt

# Console activity filter verification

The Console dropdown provides All, Idle Codex/Claude, Working Codex/Claude,
and Action required, selected with Ctrl+1 through Ctrl+4 only while the Console
list has focus. Action required is the idle subset containing that phrase,
ignoring case. The maintainer approved the idle
`task | project` heuristic. Classification uses original snapshot captions;
it performs no terminal-content reads or process enumeration on the UI thread.
See the README for title-marker sources and detection limits.

## Retained proof

Evidence directory: `%TEMP%\ActiveAppView-ConsoleFilterAction-20260913`.

- RED: `--self-test-console-filter` exited 1 with
  `Console shortcut was handled while another control had focus` before the
  focus guard. After that slice passed, the action-required slice exited 1 with
  `Action-required idle title was not recognized: [ ! ] Action Required`.
  Logs: `red-focus.out`, `green-focus.out`, `red-action.out`, `green-action.out`.
  Initial filter RED logs remain in `%TEMP%\ActiveAppView-ConsoleFilter-20260913`.
- GREEN: the same test exits 0. It covers unknown titles, title-format matching,
  Claude idle/working markers, Codex working/attention markers, all shortcuts,
  modifier rejection, native dropdown selection notification, selection/focus
  preservation, terminal-only routing, and working-to-idle refresh. The revision
  also covers every shortcut outside the Console list, case-insensitive action
  matching, working/unknown-title exclusion, Idle retaining actionable entries,
  and removal after the action-required phrase disappears.
- Owning checks passed: `--self-test-console-title-sort`,
  `--self-test-console-poll-app-purge`, `--self-test-list-sync`,
  `--self-test-window-details`, and `--self-test-window-refresh`.
- Normal root build passed with zero errors/warnings (94 hints):
  `& $env:DAK_EXE build --project "$PWD\_Source\ActiveAppView.dproj" --delphi 23.0 --platform Win64 --config Release --target Rebuild --show-warnings --ai`.
- DFM validation streamed all 3 resources with 0 failures:
  `$env:DAK_DFMCHECK_MSBUILD='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe'; & $env:DAK_EXE dfm-check --dproj "$PWD\_Source\ActiveAppView.dproj" --config Release --platform Win64 --delphi 23.0`.
- Project-context PAL 9.21.4.0 completed through
  `.agents\skills\dak-static-analysis\analyze-unit.bat` for
  `_Source\ActiveAppViewMainForm.pas` and `_Source\ActiveAppView.dproj`.
  Its report retains 210 actionable advisories across the reported owned scope;
  no finding identifies the added filter logic. Report-message comparison with
  the earlier three-filter candidate found no added findings after correcting
  a test-local integer assignment. This is advisory analysis, not a warning-free
  result. Reports are in `%TEMP%\ActiveAppView-ConsoleFilterAction-analysis-20260913`.
- EncodingFixTool: 2 Delphi files scanned, 0 failed. Both use CRLF;
  `git diff --check` passes.

## Root executable and live check

Root SHA-256:
`BEFA60D89BB993A7A3E18DF63BEDD1D93ABC02B6F72126A0A5FEEEB63BD23D98`.
Root timestamp advanced to `2026-09-13T16:23:41Z`.

An announced, leased foreground check verified F4 then Ctrl+4 selects index 3;
Ctrl+4 on Applications, Ctrl+1 on Explorer, and Ctrl+3 on the focused dropdown
leave the filter unchanged. Native reads showed 0 currently actionable rows,
6 idle rows, and 9 total rows. Positive actionable cases are covered by the
retained test fixture. External UIA reported the full Action required label
and confirmed the dropdown focus used for the negative shortcut test. It
exposes the VCL control as a Pane; this is not NVDA speech proof. The screenshot
was inspected at the current desktop DPI and the new label fits without clipping.
Additional DPI/theme combinations were not exercised. Evidence:
`live-keys.txt`, `action-uia.json`, `dropdown-focus-uia.json`, and `action-filter.png`.

The complete inventory of 63 retained self-test modes was extracted from
`_Source` and run serially against the root executable with captured stdout,
stderr, exit codes, and a 45-second per-process timeout. Result: 62 passed,
1 failed, no timeouts or skipped modes, 56.901 seconds total. The sole failure
is existing T-045, `--self-test-machine-overview-incidents`:
`persisted incident did not hydrate the restart snapshot: hydrated=0 merged=0`.
The full quality gate is therefore not green. Results: `root-results.json`
and `root--self-test-*.out`.

The root hash was unchanged after the suite. No test ActiveAppView processes
remained; the normal application was left running with All selected. No commit
or push was made.

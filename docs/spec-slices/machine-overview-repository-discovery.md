# Machine Overview repository discovery

This note resolves the repository-dependent prerequisites in Sections 17, 20, and 22 of the Machine Overview specification. It records the state inspected before Slice 1 implementation on 2026-08-28.

## Project and build

- Repository instructions are `agents.md`, `conventions.md`, `TASKS.md`, and hidden `.agents` guidance, in that order where the repository defines precedence.
- The application is a Delphi 12 VCL project: `_Source\ActiveAppView.dpr` and `_Source\ActiveAppView.dproj`.
- The project declares Win32 and Win64. Machine Overview acceptance uses Win64 Release; the final normal output is `ActiveAppView.exe` in the repository root.
- The verified interim command is:

  ```powershell
  & $env:DAK_EXE build --project "$PWD\_Source\ActiveAppView.dproj" --delphi 23.0 --platform Win64 --config Release --target Rebuild --test-output-dir "$env:TEMP\ActiveAppView-MachineOverview\current" --show-warnings --ai
  ```

- `--test-output-dir` redirects the executable and compiler outputs without replacing the running root executable.

## Main form, layout, and commands

- The main form is `TAppsViewMainFrm` in `_Source\ActiveAppViewMainForm.pas` and `_Source\ActiveAppViewMainForm.dfm`.
- Existing panels are Applications, Explorer, Scripts, Console, Desktop, and ShortCuts. They use aligned `TPanel` controls separated by `TSplitter` controls.
- The form routes keys in `TAppsViewMainFrm.FormKeyUp`. Existing assignments are F1, F2, F3, F4, F5, F6, and F7.
- F8, Shift+F8, and Ctrl+E had no source-level conflicts and are reserved for Machine Overview. F5 remains the existing refresh command. The Help button has no conflicting existing action or shortcut.

## Settings and executable-local files

- `settings.ini` is loaded from `GetInstallDir` with `TMemIniFile` using UTF-8. There is no separate settings wrapper and no existing panel-width persistence.
- Other data files and the `Scripts` directory are also resolved relative to `GetInstallDir`, which establishes the executable-local convention for `MachineOverviewHelp.txt`.
- The DPROJ deployment metadata currently declares only the executable as `ProjectOutput`. Slice 3 must add and verify explicit help-file deployment for Debug and Release instead of assuming repository-root presence is sufficient.

## Threading, queues, logging, and shutdown

- Existing background work uses `maxAsync`, `TCancelToken`, anonymous `TThread` workers, `TThreadedQueue`, `TCriticalSection`, and `TEvent` where appropriate.
- `TRenameJournalWorker` is the local example of an owned worker with a bounded queue, explicit cancellation, and deterministic shutdown.
- The main form already has one shared shutdown token and bounded async waits. Machine Overview has a separate service lifecycle so its collectors, aggregator, and writer can be stopped as one owner.
- Existing diagnostic sinks are `startup-profile.log`, `OutputDebugStringW`, and the rename-journal failure log. Machine Overview logging must use these established sinks rather than introduce an unrelated logging framework.

## SQLite

- The repository already links FireDAC SQLite statically through `FireDAC.Phys.SQLite`, `FireDAC.Phys.SQLiteWrapper.Stat`, and the Win64 `sqlite3_x64.obj` binding.
- Runtime self-test measurement reports SQLite `3.42.0` (`3042000`), embedded mode.
- Existing Shadow Journal code uses one FireDAC SQLite writer and versioned external migration files. Machine Overview history will use its own database and versioned schema while preserving the one-writer rule.
- Windows-native processes alone may access Shadow Journal databases. No WSL, Bash, or Linux-native SQLite process is permitted.

Release resolution:

- Machine Overview packages the official Win64 SQLite 3.53.4 `sqlite3.dll` under `_Source/ThirdParty/SQLite/Win64` and selects FireDAC dynamic linkage with the dedicated `SQLite_MachineOverview` driver ID. Existing Shadow Journal and rename-journal SQLite bindings remain unchanged.
- The official archive SHA3-256 is `deddee963c810d1eeac3ce5e15c7c41da21a1c54d7a39cf54fbf577d2f50de3a`; the packaged DLL SHA-256 is `AB57D0437795ECC757CB693F32EA224173FA9856594D95CFA6B5033E645CD1EC`.

## UI, accessibility, tests, and automation

- Runtime themes are enabled and Win64 uses PerMonitorV2 DPI awareness.
- The existing form uses standard windowed VCL controls, including `TListBox`, `TStaticText`, and `TEdit`; no owner-drawn list path was found.
- The retained test harness is command-line `--self-test-*` dispatch before normal application startup. Tests must be launched with `Start-Process -Wait -PassThru`; direct PowerShell invocation of the GUI-subsystem executable does not provide trustworthy exit-code evidence.
- No repository CI configuration was found. Supported local acceptance is Windows-native Delphi 12/DAK, DFM streaming validation, PAL/FixInsight analysis, and executable self-tests.

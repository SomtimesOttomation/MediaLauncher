# MediaLauncher starter pack

A framework for a desktop "launcher": one window, several modules as tabs down the left side, each module its own
repo that also runs on its own. It is the plumbing of a working launcher with its name and subject taken out, so a new
project can start from proven infrastructure and change everything else.

Windows PowerShell 5.1 + WebView2. No installer, no admin rights, no build step.

"MediaLauncher" and "SampleModule" are placeholder names. Run `Rename-Starter.ps1` to give them yours (see **Naming it**).

## What is kept intact

| Area | What it does | Where |
| --- | --- | --- |
| **Window and tabs** | One WinForms window, a tab rail (WebView2) and one WebView2 per module. Only the visible module runs; hidden ones are suspended. Drag to reorder (remembered), Ctrl+1..9, Ctrl+Tab. Themed title bar, light/dark/system theme pushed to every module. | `Start-MediaLauncher.ps1`, `ui/rail.html`, `ui/js/rail.js`, `ui/css/launcher.css` |
| **Module discovery** | Scans `modules\*\module.json` at start and on "Scan for modules"; validates every manifest (no paths outside the folder); asks before loading a module it does not know; notices a module folder disappearing. | `core/MediaLauncher.Manifest.psm1`, `schema/module.schema.json` |
| **Module contract** | A module = `module.json` + a backend `.psm1` with 8 functions (Initialize, Start/Suspend worker, Invoke command, Receive events, Get status, Stop traffic, Stop) + a page talking through `bridge.request(cmd, args)` and `{event, data}`. Same backend runs standalone or in the launcher. | `MODULE-CONTRACT.md`, `tools/Test-ModuleContract.ps1` |
| **Notice pages** | Locked (open in its own window), broken manifest, error, missing, not installed, update page. | `ui/panel.html`, `ui/js/panel.js` |
| **Status badges** | Every 2 s each module reports live count, sync progress, update available, error and traffic; the rail shows them. | `Get-ModuleStatus` in the contract |
| **Kill switch** | One button stops all data traffic in every module (update checks keep working). Each module also has its own pause switch. | `Stop-ModuleTraffic`, `traffic.stop` / `traffic.resume` |
| **MediaLauncher updates** | Checks GitHub (at most daily, can be turned off), downloads the release zip, verifies its `.sha256`, swaps its own files after closing, relaunches, rolls back if the new version does not start. Never touches `modules`. | `Update-MediaLauncher.ps1`, `Apply-Update.ps1`, `Restart-MediaLauncher.ps1` |
| **Module install and updates** | Modules listed in `catalog.json` show as greyed tabs once published; Install downloads, verifies and installs. Optional "also check my modules" updates selected modules with backup and rollback. | `catalog.json`, `core/MediaLauncher.Catalog.psm1`, `Install-MediaLauncherModule.ps1` |
| **Drop-in updates** | Drop a launcher or module zip (+ `.sha256`) into `updates\`; within ~5 s a toast offers to apply it. | `core/MediaLauncher.DropIn.psm1`, `updates/README.md` |
| **Restart & Reload** | Restarts the launcher on the same tab so changed module files load fresh. | `Restart-MediaLauncher.ps1` |
| **Release workflow** | On a published GitHub release: tag must match `VERSION`, scripts must be ASCII-only, builds and attaches `<Name>-vX.Y.Z.zip` + `.sha256`. | `.github/workflows/release.yml` |
| **Sample module** | A complete offline module with every piece of module plumbing: worker runspace, cache, failed-request rule, sync with progress, traffic counters, settings with opt-in auto refresh, its own updater and release workflow, update window, navigation bar, browser preview. | `samples/SampleModule` |
| **Tests** | Manifest rules, catalog logic, and the contract check for any module. | `tests/`, `tools/` |

## How it fits together

```
Start-MediaLauncher.bat -> Start-MediaLauncher.ps1 (STA, WinForms window)
  ├─ rail WebView2 (ui/rail.html)          tabs, badges, theme, stop, scan, restart, version
  ├─ panel WebView2 (ui/panel.html)        notice pages and the update page
  └─ one WebView2 per module               https://<id>.ui/  (+ https://<id>.cache/)
        page  <-- bridge.request / {event,data} -->  Context.Post / Invoke-ModuleCommand
        backend .psm1 (contract functions)  -->  worker runspace  -->  data sources
  timers: 250 ms Receive-ModuleEvents, 2 s Get-ModuleStatus, 2 s module.json watch, 5 s updates\ folder
```

Data and settings live outside the program folders (`%APPDATA%\<Name>`, `%LOCALAPPDATA%\<Name>`), so updates never
wipe them.

## Naming it

From the starter's folder in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-Starter.ps1 -Name MyLauncher -Owner MyGitHubName -SampleName MyModule -SampleId mymod
```

This renames `MediaLauncher` / `SampleModule` / `sample` in file names and contents, points both updaters at your GitHub
repos, and deletes itself. Afterwards, check `git diff` (or search for the old names) and adjust the wording in the
READMEs. Change the look freely: `ui/css/launcher.css` and the Sample's `ui/css/app.css`.

## First run

1. Put the folder anywhere, for example `C:\Tools\MyLauncher`.
2. Double-click `Start-MediaLauncher.bat` (renamed to yours). The first run downloads the WebView2 wrapper DLLs into `lib\`
   (no admin needed; the runtime ships with Edge).
3. Copy `samples\SampleModule` into `modules\` and press **Scan for modules**. Say yes to load it.
4. `Start-MediaLauncher.bat -Debug` turns on DevTools in every view.

## Checking

- `tools\Test-ModuleContract.ps1 -Path modules\SampleModule`: a module against the contract (no window, no network).
- `tests\Test-Manifest.ps1`, `tests\Test-Catalog.ps1`: the launcher's own rules.
- `ui/dev/preview.html` (launcher) and `samples/SampleModule/ui/index.html` (module) run in a normal browser from any
  local web server, with mock hosts in `ui/dev/mock.js`, for checking layouts without PowerShell.

## Rules the plumbing assumes

- Nothing contacts a third-party server on its own by default; automatic refresh is opt-in behind a warning.
- A hidden tab fetches nothing on a timer. The kill switch stops everything except update checks.
- A failed request waits for Refresh; it is never retried on a redraw.
- Scripts stay ASCII-only (Windows PowerShell 5.1 misreads other characters); the release workflow checks it.
- Every module also runs standalone from its own `.bat`.

## License

MIT. See [LICENSE](LICENSE).

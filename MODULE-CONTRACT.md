# Module contract (version 1)

How a module ("module") plugs into MediaLauncher while still running on its own.
A module that follows this document can be copied into MediaLauncher's `modules` folder and appears as a tab, with no launcher code changes.

Everything here targets Windows PowerShell 5.1 + WebView2, no installer, no admin rights, no build step.

## In one paragraph

A module ships two extra things: a `module.json` manifest in its root folder, and a backend PowerShell module that exports
the functions below. The backend never touches a window or a WebView2. Whoever hosts it (the module's own thin
`Start-*.ps1`, or MediaLauncher) creates the window and the WebView2, and hands the backend a **context** object to talk
through. The page code does not change: it keeps calling `bridge.request(cmd, args)` and listening for `{event, data}`.

## Folder layout

```
MediaLauncher\
  Start-MediaLauncher.bat
  core\                     the launcher's own PowerShell module
  modules\                  modules, one folder each
    ExampleModule\                a module
      module.json             required, read by the launcher
      Start-ExampleModule.bat     standalone entry point (thin host)
      modules\ExampleModule.Host.psm1   the backend module named in module.json
      ui\                   the page, served as https://<id>.ui/
```

The launcher looks one level deep in its `modules` folder for `*\module.json` when it starts and when the person presses
"Scan for modules" at the bottom of the tab rail. A module listed in the launcher's `catalog.json` is trusted once the
person installs it; any other module is loaded only after the person approves it, and the launcher asks the first time it
finds one. If a scan finds a running
module's folder (or its `module.json`) gone, the launcher calls its `Stop-Module` and removes its tab. Between scans, the launcher checks every 2 seconds
that each running module's `module.json` still exists; if not, it calls `Suspend-ModuleWorker` and covers the module with a
notice offering Close or Reload. A module still runs standalone
from its own `.bat`, wherever its folder sits, including inside `modules`.

## Getting listed in the launcher

MediaLauncher's `catalog.json` lists known modules by id and GitHub repo. A listed module that is not installed shows as a
greyed tab once its repo has a published release (not a draft or pre-release) at or above the catalog's `minVersion`;
its page has an Install button and manual steps. For that to work, the release zip must have `module.json` at its root (or
inside one top folder), and the release must attach `<zip name>.sha256`: Install downloads both, checks the checksum,
checks the `module.json` id matches the catalog, and puts the module in `modules\<repo name>`. An existing folder is never
replaced. If GitHub cannot be reached, the
last answer seen is used; `"published": true` in `catalog.json` shows a module regardless, and `false` hides it.

## module.json

```json
{
  "contract": 1,
  "id": "examplemodule",
  "name": "Example",
  "title": "Example",
  "versionFile": "VERSION",
  "icon": "ui/img/tab-icon.svg",
  "backend": "modules/ExampleModule.Host.psm1",
  "ui": "ui",
  "entry": "index.html",
  "standalone": "Start-ExampleModule.bat",
  "dataSources": [
    { "name": "ESPN public endpoints", "terms": "https://example.com/terms" }
  ]
}
```

| Field | Required | Rule |
| --- | --- | --- |
| `contract` | yes | Integer. The launcher refuses a module whose number is higher than it supports and says "needs a newer MediaLauncher". |
| `id` | yes | `^[a-z][a-z0-9]{1,19}$`, unique among installed modules. `launcher` is reserved. |
| `name` | yes | Tab label, 1 to 12 characters. |
| `title` | yes | Window title while the tab is active, 1 to 60 characters. |
| `versionFile` | yes | Relative path to a file whose trimmed content is `X.Y.Z`. |
| `icon` | yes | Relative path to an `.svg` or `.png`, drawn at 32 x 32. |
| `backend` | yes | Relative path to the `.psm1` backend module. |
| `ui` | yes | Relative path to the folder served as `https://<id>.ui/`. |
| `entry` | yes | File inside `ui` to open, normally `index.html`. |
| `standalone` | yes | Relative path to the module's own `.bat` entry point. |
| `dataSources` | no | Third-party sources the module fetches from, each with `name` and a `terms` URL. Shown on the launcher's About page. |

Every relative path must stay inside the module folder: no `..`, no leading `\` or `/`, no drive letter, no UNC path, and
the file or folder must exist. A manifest that breaks any rule is listed as broken with the reason, and none of its code
is loaded. Fields the launcher does not know are ignored, so optional fields added later in contract 1 do not
break older launchers. The machine-readable version of these rules is `schema/module.schema.json`.

## Host names

| Host name | Maps to | Who maps it |
| --- | --- | --- |
| `https://<id>.ui/` | the module's `ui` folder | the host |
| `https://<id>.cache/` | the `CacheDir` returned by `Initialize-Module` | the host |

The host cancels navigation to anything else and blocks pop-ups. These are the same names the module uses standalone, so
page code that builds `https://examplemodule.cache/...` URLs keeps working in the launcher.

## Backend module

The host imports the module named in `backend` and calls these functions. All except the worker run on the host's UI
thread, so each call must return quickly (aim for under 50 ms) and must never wait on the network. Slow work goes to the
module's worker runspace or a child process, as the Sample module does.

| Function | Called when | Must |
| --- | --- | --- |
| `Initialize-Module -Context $ctx` | The module is first needed (tab opened, or master sync) | Load settings, create folders, take the host lock. Return the init result below. Must not start fetching. |
| `Start-ModuleWorker` | The tab becomes visible | Start the worker, or resume it if paused, unless the kill switch stopped it. |
| `Suspend-ModuleWorker` | The tab is hidden | Stop timed fetching (live polling, auto refresh). Finish requests already queued. A sync the person started keeps running, with its progress reported through `Get-ModuleStatus`. |
| `Invoke-ModuleCommand -Message $msg` | The page sends `{id, cmd, args}` | Validate every argument and answer through `Context.Post` with `{id, ok, data}` or `{id, ok:false, error}`. |
| `Receive-ModuleEvents` | Every 250 ms while initialized | Return an array of JSON strings, each an `{event, data}` message for the page (worker output, sync and updater progress). Return at most 25 per call. |
| `Get-ModuleStatus` | Every 2 seconds while initialized | Return the status hashtable below. No network, no disk scans. |
| `Stop-ModuleTraffic` | The person presses the launcher's kill switch | Stop all traffic to the module's data sources: cancel running syncs and queued data requests, stop live refresh, and pause the worker, visible tab included. Update checks and downloads (GitHub) are not affected. Change no saved settings. Tell the page traffic was stopped; only the person resumes it, from inside the module. |
| `Stop-Module` | The host is closing | Stop child processes and the worker, release the host lock, within 2 seconds. |
| `Invoke-ModuleSync -Scope 'quick'` | Optional. The launcher's master sync runs (built but switched off for now; see below) | Start the module's own quick sync and return `$true`, or `$false` if one is already running. Progress shows through `Get-ModuleStatus`. A module without this function is skipped by the master sync. |

Several modules run in one launcher process, and every backend exports the same function names. So the launcher calls
each backend through its own module object, never by bare name, and a backend must not rely on being imported into the
global scope. Any helper module a backend imports must have a name unique to that module (for example `Example.Data`), because
PowerShell keeps one module per name per process.

### Init result

```powershell
@{
    Ok             = $true                 # $false when the module cannot start here
    Reason         = ''                    # 'locked' when the module is already open in another host, else a message
    CacheDir       = 'C:\Users\...\AppData\Local\ExampleModule\cache'
    WebViewDataDir = 'C:\Users\...\AppData\Local\ExampleModule\webview2'
}
```

The host maps `<id>.cache` to `CacheDir` and creates the module's WebView2 with `WebViewDataDir` as its profile folder,
so browser storage (sorts, filters) is the same standalone and in the launcher.

### Status hashtable

```powershell
@{
    Live            = 2          # items live right now (for example something playing or downloading); 0 when none
    Syncing         = $true
    SyncPct         = 40         # 0-100, or $null when unknown
    UpdateAvailable = '0.12.0'   # newer version found by the module's own updater, or $null
    Error           = $null      # short message when the backend is unhealthy
    Traffic         = @{ Requests = 412; Bytes = 3145728; Errors = 0 }   # the module's own counter, this session
}
```

The launcher shows `Traffic` per module, exactly as each module counts it. It adds no total and never changes a module's
counting.

## Kill switch

The launcher has one button that stops all traffic to data sources happening right now: it calls `Stop-ModuleTraffic`
on every initialized module. It is for the data sources only; update checks and downloads keep working. There is no matching "start all". After a stop, each module stays quiet until the person resumes it
inside that module; switching tabs does not resume it.

The same stop is also available from inside every module, so a person can pause one module without the launcher (ExampleModule
does it with the live-status button in its navigation bar, see `docs/NAVBAR-SPEC.md`). Every module handles two page
commands:

- `traffic.stop`: runs the module's own `Stop-ModuleTraffic`, exactly as the launcher's button does, then replies `ok`.
- `traffic.resume`: starts traffic again (only from inside the module), then replies `ok`.

After either one, and after the launcher's stop, the backend sends the page `{"event":"traffic","data":{"stopped":true|false}}`
so the page shows the same paused state whichever way it was stopped. Update checks keep running while stopped, and no
settings change. The launcher does not track the paused state itself.

## Context object

The host builds this before `Initialize-Module` and keeps it for the module's lifetime.

| Member | Type | Standalone host | MediaLauncher |
| --- | --- | --- | --- |
| `Mode` | string | `'standalone'` | `'launcher'` |
| `Root` | string | the module folder | the module folder |
| `Post` | scriptblock `{ param([string]$Json) }` | posts to its own WebView2 | posts to that module's WebView2 |
| `Close` | scriptblock | closes its window | closes the whole launcher |
| `Relaunch` | string | full command line: the module's quoted `.bat` path | full command line, arguments included: `"<launcher folder>\Start-MediaLauncher.bat" -Open <id>` |
| `HostPid` | int | its own process id | the launcher's process id |
| `Theme` | string | `''` (the module uses its own setting) | `'light'`, `'dark'` or `'system'` |
| `MediaLauncherVersion` | string | `''` | the launcher's version |
| `Debug` | bool | `-Debug` switch | `-Debug` switch |

`Post` may only be called on the UI thread, which is where `Invoke-ModuleCommand` and `Receive-ModuleEvents` run. The
worker runspace never calls it; it queues messages for `Receive-ModuleEvents` instead.

## Reserved for the launcher

- Messages whose `cmd` starts with `launcher.` are the launcher's own. In launcher mode it handles them and never passes
  them to `Invoke-ModuleCommand`, so a module must not use that prefix for its own commands.
- Ctrl+1 to Ctrl+9, Ctrl+Tab and Ctrl+Shift+Tab switch tabs. After each page load the launcher adds a small key
  listener to the module page that sends `launcher.key` messages, so a module should not use those shortcuts itself.

## Host events

The host also pushes these to the page. A page that ignores them still works.

| Event | Data | Sent when |
| --- | --- | --- |
| `host.visible` | `{}` | the tab is shown again after being hidden |
| `host.hidden` | `{}` | the tab is hidden |
| `host.theme` | `{ "theme": "dark" }` | the launcher theme changes, and once after load in launcher mode |

In launcher mode a module hides its own theme toggle and follows `host.theme`.
On `host.visible` a module refetches only if its own automatic refresh setting is on; otherwise it shows how old its data
is and waits for the person to refresh.

## Master sync (built, switched off)

The launcher contains the plumbing for a manual "Sync all": it would call `Invoke-ModuleSync` on each module in turn, one at a
time, behind a warning confirmed on every use. It is switched off: there is no button, and the setting that would show
it is not exposed. Modules may implement `Invoke-ModuleSync` now so they are ready, but nothing calls it until master sync
is switched on in a later release.

## Host lock

`Initialize-Module` takes a named mutex `Local\ModuleHost-<id>` and `Stop-Module` releases it. If the mutex is already held,
the module is open in another host (for example its own window), so `Initialize-Module` returns `Ok = $false` and
`Reason = 'locked'`. The launcher then shows "Example is open in its own window" instead of a second copy writing the same
cache and settings.

## Updates

Each module keeps its own updater. When an update is applied, the module calls `Context.Close`, and its apply helper waits
for `Context.HostPid` to exit and then runs the `Context.Relaunch` command line as given. Installed from the launcher,
an update therefore reopens the launcher with that module's tab already open (`-Open <id>`), so the module's page loads and
can confirm the new version started, exactly as it does standalone. If the module fails to initialize or its page never
loads, nothing confirms and the module's own updater rolls back.

A module confirms a new version when its page loads, not in `Initialize-Module`: page load proves the backend and the UI
both work. A module never edits the launcher's files. The launcher's own updater leaves the `modules` folder alone.

The one exception is when the person ticks "Also check my modules for updates" on the launcher's update page
(off by default) and chooses to update a module listed in `catalog.json` from there. The launcher then closes that module
(`Stop-Module`), downloads the module's latest release zip, checks it against its published `.sha256` and its `module.json` id,
backs up the files it replaces, and copies the package's files over the module's folder. It never touches the module's
`lib\`, `update\` or `.git\` folders or files the package does not have, and removes leftover files only inside folders
the package has. If anything fails, the backup is put back. Then the launcher restarts on the same tab. So that this is
safe, a module keeps its settings, cache and other data outside its own folder (the Sample module uses `%APPDATA%` and
`%LOCALAPPDATA%`), and its release zip is a complete copy of the module.

## Fetching rules

These are part of the contract, not suggestions.

1. Nothing contacts a third-party server on its own by default. Fetching happens when the person asks for it.
2. Automatic refresh, polling and scheduled syncs are opt-in, behind a plain warning and an acknowledgement, with every
   interval adjustable and clamped.
3. A hidden tab fetches nothing on a timer (`Suspend-ModuleWorker`).
4. A new data source's terms are read before the module uses it, and the source is listed in `dataSources`.
5. A module bundles no third-party data. It fetches on the person's own computer and caches locally.

## Versioning

This is contract version 1. Adding an optional function, field or event keeps the number. Changing or removing a
required one raises it, and the launcher keeps supporting the previous number for at least one release.

## Checklist for a new module

`samples\SampleModule` in the MediaLauncher repo is a complete, no-network example to copy.

- [ ] `module.json` passes `schema/module.schema.json`, and every path exists inside the folder.
- [ ] The backend exports the eight required functions; nothing in it creates a window or loads WebView2.
- [ ] The standalone `.bat` works with MediaLauncher absent.
- [ ] Opening the module in the launcher while it is open standalone shows the locked message.
- [ ] A hidden tab makes no timed requests.
- [ ] After the kill switch, no data source is contacted until the person resumes inside the module (update checks may still run).
- [ ] Settings, cache and other data live outside the module's folder, so an update from the launcher keeps them.
- [ ] The page commands `traffic.stop` and `traffic.resume` both work and reply `ok`, and each sends the `traffic` event to the page.
- [ ] Release workflow present: `.github/workflows/release.yml` (as in `samples\SampleModule`) builds and attaches
      `<Name>-vX.Y.Z.zip` and `.sha256` when a GitHub release is published, so the module's updater, the launcher's
      Install button and its module updates find a package.
- [ ] Updater present: `Update-<Name>.ps1` and `Apply-Update.ps1`, the `update.*` page commands and the version button
      with its update window (check, download, verify, swap, relaunch, roll back), as in `samples\SampleModule`.
- [ ] Its release zip has `module.json` at the root; extracted into MediaLauncher's `modules` folder, it appears as a tab after Scan for modules.
- [ ] Every data source is listed in `dataSources`, and its terms have been read.
- [ ] Helper module names are unique to the module (for example `Example.Data`, not `Data`).
- [ ] No `launcher.*` commands of its own, and no Ctrl+1 to Ctrl+9 or Ctrl+Tab shortcuts.
- [ ] Scripts are ASCII-only (Windows PowerShell 5.1 misreads other characters).
- [ ] The page uses the shared navigation bar in [docs/NAVBAR-SPEC.md](docs/NAVBAR-SPEC.md): same order, look and keys (Alt+Left/Right, mouse back/forward, F5) as the Sample module. The bar is a look-and-feel standard, not part of the contract: the launcher never checks it.

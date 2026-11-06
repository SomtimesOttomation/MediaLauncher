# Sample Module

A module that contacts nothing: its library and "servers" are made up. It has two jobs:

1. **Try the launcher without a real module.** Settings > Sample tools can pretend there are live items, an update or
   a problem (for the launcher's tab badges), or that downloads fail. A sync with a real progress bar runs against the
   fake servers, so the stop button, the rail's sync ring and tab switching can all be tested offline.
2. **Start a new module.** Every piece of module plumbing is in place, so a new module swaps in its own data and views.

## Try it

- In the launcher: copy this folder into the launcher's `modules` folder and press **Scan for modules**.
- On its own: double-click `Start-SampleModule.bat` (the first run downloads the WebView2 files into `lib\`).
- In a browser: serve `ui\` with any local web server and open `index.html`; `ui\dev\mock.js` answers instead of PowerShell.

## What is in it

| Piece | Where | What it does |
| --- | --- | --- |
| Manifest | `module.json` | What the launcher reads: id `sample`, name, title, paths, data sources. |
| Backend | `modules\SampleModule.Host.psm1` | The eight contract functions plus `Invoke-ModuleSync`. Keys checked in `Resolve-DataKey`; a worker runspace fetches one key at a time, caches it, counts traffic per server and kind (last 40 requests) and reports sync progress. |
| Standalone host | `Start-SampleModule.ps1` / `.bat` | Window, WebView2, context, 250 ms timer. The launcher does the same for its tab. |
| Page shell | `ui\index.html`, `ui\js\app.js` | Routing (`#/`, `#/item/<id>`), navigation bar (back, forward, home, refresh/F5, search, live status = pause switch, settings), kill-switch bar, sync strip, version button, toasts, 5 clicks on the brand = traffic panel. |
| State | `ui\js\store.js` | Settings, data from the host, `want()` with the failed-request rule, `notify`/`subscribe`, updates, pause, sync, host events (`host.theme`, `host.visible`, `host.hidden`). |
| Views | `ui\js\views\` | `home` (favourites first, then a card grid), `item` (detail), `settings` (General, Data, Sync, Sample tools), `traffic`, `update`. |
| Components | `ui\js\components.js` | Item art, favourite star, item card, banner with favourites first, empty/fail notes. |
| Hover cards | `ui\js\formulas.js` | `calc('rating')` makes any label explain itself on hover. Add your terms to `DEFS`. |
| Updater | `Update-SampleModule.ps1`, `Apply-Update.ps1`, `update.*` commands | Check, download, verify against `.sha256`, swap after closing, relaunch, roll back if the new version does not start. Page load confirms the new version works. |
| Release workflow | `.github\workflows\release.yml` | Builds and attaches `SampleModule-vX.Y.Z.zip` + `.sha256` when a release is published. |

Settings live in `%APPDATA%\SampleModule`, cache and the WebView2 profile in `%LOCALAPPDATA%\SampleModule`.

## Starting a real module from it

1. Copy this folder into a new repo, `.github` included. Rename `SampleModule`, `sample` and `Sample Module` everywhere
   (file names, `module.json`, the lock name `Local\ModuleHost-sample`, host names `sample.ui` / `sample.cache`, data
   folders, `SAMPLEMODULE_` test hooks) and set the updater's repo in `Update-<Name>.ps1`.
2. List every data source and its terms in `module.json` `dataSources` (keep the GitHub one for the updater).
3. Backend: replace `Invoke-FakeServer` in the worker with real downloads or local reads, and the keys in
   `Resolve-DataKey` with yours. Keep the rules: nothing fetched until the person asks, automatic refresh opt-in with a
   warning, a hidden tab fetches nothing on a timer, the pause switch stops everything but update checks.
4. Page: replace the views and components; keep `store.js`'s plumbing, the shell in `app.js` and the ids in `index.html`.
5. Turn `updateCheck` on by default in `New-DefaultSettings` (the Sample keeps it off so it contacts nothing). Remove the
   Sample tools tab and `sample.set`.
6. Check it with the launcher's `tools\Test-ModuleContract.ps1 -Path <folder>`: 0 problems.

## Release zip (drop-in update)

`<Name>-vX.Y.Z.zip` (a complete copy of the module at the release commit, `module.json` and `VERSION` at its root,
without `lib\`, `update\`, `.git\`) plus `<Name>-vX.Y.Z.zip.sha256` (the SHA-256 in lowercase hex). Dropped into the
launcher's `updates` folder, it is checked and installed. The release workflow builds the same pair on GitHub.

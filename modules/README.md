# Modules

Each module goes here in its own folder, for example:

```
modules\
  ExampleModule\
    module.json
```

Published modules show in MediaLauncher as greyed tabs: click one and press **Install**, and MediaLauncher puts it
here. Or download the zip yourself, extract it into a new folder here, and press Refresh.

MediaLauncher also looks in this folder every time it starts, and when you press Scan for modules. MediaLauncher's own
updates never change this folder.

Replaced a module with a newer version while MediaLauncher was open? Press **Restart & Reload** at the bottom of the tab
rail: MediaLauncher closes and starts again on the same tab, running the new files. (Scan only notices modules that were
added or removed; it does not reload one that is already running.)

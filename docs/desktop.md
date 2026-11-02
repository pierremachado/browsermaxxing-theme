# desktop colors / standalone

the theme reads noctalia's gtk or qt exports and generates its own palette.
it does not depend on the pages extension or native messaging.

## install

close the browser, then run from this repository:

```sh
python instalar.py --librewolf --mode desktop --source auto
```

automatic selection prefers the imported gtk export, then the active qt palette.
use `--source gtk` or `--source qt` to choose explicitly.
the original profile files remain backed up by the installer.

## open with current colors

```sh
python run.py
```

this synchronizes the palette and starts librewolf with the same profile.
the selected source is remembered by the theme installer and synchronizer.
for firefox, specify its profile:

```sh
python run.py --browser firefox --profile /path/to/profile
```

opening the browser through its usual icon still loads the last generated
palette. using this command refreshes it first. it does not replace launchers
or modify the desktop's default browser.

## synchronize without opening

```sh
python desktop/sync_colors.py
python desktop/sync_colors.py --source qt
```

the synchronizer changes only the managed palette and its backup metadata.
it refuses to overwrite files edited after installation.
if the export is invalid or unavailable, existing colors stay intact.

a userchrome stylesheet is loaded at browser startup. changes generated while
it is open take effect after closing and reopening it. this version does not
provide live stylesheet reload, privileged browser scripts or a background daemon.

## inspect or undo

```sh
python desktop/palette.py --source gtk
python instalar.py --librewolf --mode dark
```

upgrading from the previous extension bridge also requires reloading the updated
pages extension, or restarting the browser. its old interface controls and native
permissions have been removed. saved website choices are preserved; the former
real-desktop website mode migrates to browser-exposed system colors.

obsolete native messaging registrations can be removed with:

```sh
python desktop/remove_legacy_bridge.py
```

only registrations matching this repository's old reader are removed.

## verified

parser and contrast tests, invalid export handling, profile backup restoration,
atomic export replacement, standalone synchronization and extension migration.
actual browser rendering still needs an interactive check.

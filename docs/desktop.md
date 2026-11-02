# desktop colors

linux integration for the browsermaxxing theme and pages extension.
python standard library only. no desktop daemon or network service.

## install

from this repository, with the browser closed:

```sh
python native/install_host.py
python instalar.py --librewolf --mode desktop
```

reload the updated pages extension in `about:debugging`.
open its popup, enable the desktop interface switch, and allow native messaging.
the new permission connects only to the local palette reader.

for a website, select the desktop palette in that site's controls.
the interface switch is independent: it need not be on to style a website.

## sources

- automatic: an imported noctalia gtk export first, then the active qt palette.
- gtk: the noctalia gtk3 or gtk4 export.
- qt: the configured qt6ct or qt5ct palette, then the selected kde scheme.

the reader returns only validated colors, source type and light/dark mode.
requests accept fixed source names, not arbitrary file paths or shell commands.
only the companion extension id is allowed to connect.

while connected, file timestamps are checked every two seconds. changed exports
are parsed again, including files replaced atomically. unchanged palettes are
not sent again. the process exits when its browser connection closes.
there is no websocket, http server, per-page polling or process at login.

the theme consumes dynamic browser theme variables, so subsequent color changes
do not require another restart. shapes stay controlled by userchrome.
the first stylesheet update requires a browser restart.

## inspect

```sh
python native/palette_host.py --print --source auto
python native/palette_host.py --print --source qt
```

an unavailable or invalid export leaves the last valid palette intact.
the popup reports a disconnected reader; use its sync button to retry.
colors in private windows and accessibility modes still depend on browser rules.
this first reader targets linux; no windows registry installer is included.
flatpak or snap confinement may need a native messaging portal instead.

## undo

disable the desktop interface switch to reset this extension's dynamic theme.
to return to the fixed browsermaxxing palette, close the browser and run:

```sh
python instalar.py --librewolf --mode dark
```

remove the local reader registrations with:

```sh
python native/install_host.py --remove
```

this does not delete the browser profile, site choices or original theme backup.

## tests

```sh
python -m unittest discover -s tests
```

coverage includes gtk/qt parsing, color validation, contrast handling,
native message framing, atomic export replacement and live watch updates.
the browser theme mapping is checked against the installed gecko token map;
actual rendering and the browser-to-native connection need an interactive test.

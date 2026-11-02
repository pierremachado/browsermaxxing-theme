# browsermaxxing / theme

square corners. quiet surfaces. black, white, and the space between.

a userchrome theme for firefox and librewolf. dark, light, automatic, or desktop-synced.

close the browser, then:

```sh
python instalar.py --librewolf --mode dark
```

use `--mode light` or `--mode auto` to change the palette.
use `--profile /path/to/profile` for firefox or a specific profile.
use `--remove` to restore the previous files.

for live gtk/qt colors:

```sh
python native/install_host.py
python instalar.py --librewolf --mode desktop
```

then enable desktop colors in the companion pages extension.
see [desktop integration](docs/desktop.md).

backups stay inside the profile. websites keep their own appearance.

```sh
python -m unittest discover -s tests
```

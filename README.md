# browsermaxxing / theme

square corners. quiet surfaces. black, white, and the space between.

a standalone userchrome theme for firefox and librewolf.

close the browser, then:

```sh
python instalar.py --librewolf --mode desktop --source auto
```

to sync desktop colors before opening librewolf:

```sh
python run.py
```

use `--source gtk` or `--source qt` to select an export.
fixed palettes are available through `--mode dark`, `light`, or `auto`.
use `--profile /path/to/profile` for a specific profile.
use `--remove` to restore the previous files.

no companion extension. no resident process. new colors load at browser startup.
see [desktop colors](docs/desktop.md).

```sh
python -m unittest discover -s tests
```

# browsermaxxing / theme

square corners. quiet surfaces. black, white, and the space between.

a userchrome theme for firefox and librewolf. dark, light, or automatic.

close the browser, then:

```sh
python instalar.py --librewolf --mode dark
```

use `--mode light` or `--mode auto` to change the palette.
use `--profile /path/to/profile` for firefox or a specific profile.
use `--remove` to restore the previous files.

backups stay inside the profile. websites keep their own appearance.

```sh
python -m unittest discover -s tests
```

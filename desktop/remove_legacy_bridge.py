#!/usr/bin/env python3
"""Remove only this theme's obsolete native messaging registrations."""
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = Path.home()
config = Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
folders = [home / '.mozilla/native-messaging-hosts', config / 'mozilla/native-messaging-hosts',
           config / 'librewolf/native-messaging-hosts', config / 'librewolf/librewolf/native-messaging-hosts']
count = 0
for folder in dict.fromkeys(folders):
    path = folder / 'dev.browsermaxxing.palette.json'
    if not path.exists():
        continue
    data = json.loads(path.read_text())
    if (data.get('name') == 'dev.browsermaxxing.palette' and
        data.get('allowed_extensions') == ['pages@browsermaxxing.local'] and
        Path(data.get('path', '')).resolve() == root / 'native/palette_host.py'):
        path.unlink()
        count += 1
    else:
        raise SystemExit(f'Different registration preserved: {path}')
print(f'Removed {count} legacy palette registrations.')

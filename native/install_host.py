#!/usr/bin/env python3
"""Register the read-only palette host for the Browsermaxxing extension."""
import argparse
import json
import os
from pathlib import Path

NAME = 'dev.browsermaxxing.palette'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--remove', action='store_true')
args = parser.parse_args()
home = Path.home()
config = Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
# Mozilla compatibility fallback is checked by Gecko forks, including LibreWolf.
folders = [home / '.mozilla/native-messaging-hosts',
           config / 'mozilla/native-messaging-hosts',
           config / 'librewolf/native-messaging-hosts',
           config / 'librewolf/librewolf/native-messaging-hosts']
host = Path(__file__).resolve().with_name('palette_host.py')
manifest = {'name': NAME, 'description': 'Read-only GTK and Qt color export bridge',
            'path': str(host), 'type': 'stdio',
            'allowed_extensions': ['pages@browsermaxxing.local']}
for folder in dict.fromkeys(folders):
    target = folder / f'{NAME}.json'
    if target.exists() and json.loads(target.read_text()) != manifest:
        raise SystemExit(f'Existing different host registration preserved: {target}')
if not args.remove:
    host.chmod(0o700)
for folder in dict.fromkeys(folders):
    target = folder / f'{NAME}.json'
    if args.remove:
        target.unlink(missing_ok=True)
    else:
        folder.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(manifest, indent=2) + '\n')
        target.chmod(0o600)
print('Palette host removed.' if args.remove else 'Read-only palette host registered.')

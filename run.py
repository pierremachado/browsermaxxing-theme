#!/usr/bin/env python3
"""Sync the standalone theme before starting Firefox or LibreWolf."""
import argparse
import os
import shutil
import sys
from desktop.sync_colors import resolve_profile, sync

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--browser', choices=('librewolf', 'firefox'), default='librewolf')
parser.add_argument('--profile')
parser.add_argument('--source', choices=('auto', 'gtk', 'qt'))
args = parser.parse_args()
try:
    executable = shutil.which(args.browser)
    if not executable:
        raise ValueError('Browser executable not found.')
    profile = resolve_profile(args.profile)
    lock = profile / '.parentlock'
    if lock.exists() and sys.platform.startswith('linux'):
        import fcntl
        with lock.open('r+') as handle:
            try:
                fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise ValueError('Close this browser profile first; CSS is loaded on startup.')
    sync(profile, args.source)
    os.execv(executable, [executable, '-profile', str(profile)])
except (ValueError, OSError, KeyError) as error:
    parser.exit(1, f'Error: {error}\n')

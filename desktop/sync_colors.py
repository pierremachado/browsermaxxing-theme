#!/usr/bin/env python3
"""Generate profile-local desktop colors; browser restart loads the stylesheet."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import instalar
from desktop.palette import get_palette, SOURCES


def render_palette(palette):
    mapping = {'bg': 'background', 'surface': 'surface', 'text': 'text',
               'muted': 'muted', 'border': 'border', 'selected': 'accent',
               'selected-text': 'accentText'}
    lines = ['/* Generated from desktop exports. No extension required. */',
             '@import url("palette-static.css");', ':root {',
             f'  color-scheme: {palette["scheme"]} !important;']
    for token, field in mapping.items():
        lines.append(f'  --bmx-{token}: {palette[field]};')
    lines.append('  --bmx-hover: color-mix(in srgb, var(--bmx-text) 12%, var(--bmx-surface));')
    lines.append('}')
    return ('\n'.join(lines) + '\n').encode()


def resolve_profile(raw=None):
    if raw:
        profile = Path(raw).expanduser().resolve()
        if not profile.is_dir():
            raise ValueError('Profile directory not found.')
        return profile
    found = [p for p in instalar.profiles() if (p / 'prefs.js').exists()]
    if len(found) != 1:
        raise ValueError('Use --profile to select an initialized profile.')
    return found[0]


def sync(profile, source=None):
    state_path = instalar.checked_path(profile, 'chrome/browsermaxxing/state.json')
    state = json.loads(state_path.read_text())
    if state.get('version') != 1 or state.get('mode') != 'desktop':
        raise ValueError('Install the theme with --mode desktop first.')
    instalar.check_current(profile, state)
    source = source or state.get('desktop_source', 'auto')
    result = get_palette(source)
    if not result['ok']:
        raise ValueError(result['error'])
    data = render_palette(result['palette'])
    relative = 'chrome/browsermaxxing/palette-desktop.css'
    target = instalar.checked_path(profile, relative)
    changed = target.read_bytes() != data
    state['desktop_source'] = source
    state['files'][relative]['installed_sha256'] = instalar.digest(data)
    instalar.write_file(state_path, json.dumps(state, indent=2).encode())
    if changed:
        instalar.write_file(target, data)
    return result, changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile')
    parser.add_argument('--source', choices=SOURCES)
    args = parser.parse_args()
    try:
        result, changed = sync(resolve_profile(args.profile), args.source)
        print(f'Palette: {result["source"]}. ' +
              ('Updated; reopen the browser to load it.' if changed else 'Already up to date.'))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Error: {error}\n')

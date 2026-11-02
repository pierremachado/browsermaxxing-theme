#!/usr/bin/env python3
"""Read desktop color exports. Native messages accept source names, never paths."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import select
import struct
import sys

HOST = 'dev.browsermaxxing.palette'
SOURCES = ('auto', 'gtk', 'qt')


def config_root():
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')


def read_text(path):
    if path.stat().st_size > 1024 * 1024:
        raise ValueError('Color export too large')
    return path.read_text(encoding='utf-8')


def ini(path):
    result = configparser.ConfigParser(interpolation=None, strict=False)
    result.read_string(read_text(path))
    return result


def color(value):
    value = value.strip()
    if re.fullmatch(r'#[0-9a-fA-F]{3}', value):
        return '#' + ''.join(c * 2 for c in value[1:]).lower()
    if re.fullmatch(r'#[0-9a-fA-F]{6}', value):
        return value.lower()
    if re.fullmatch(r'\d{1,3},\s*\d{1,3},\s*\d{1,3}', value):
        channels = [int(c) for c in value.split(',')]
        if all(0 <= c <= 255 for c in channels):
            return '#' + ''.join(f'{c:02x}' for c in channels)
    raise ValueError('Unsupported color value')


def rgb(value):
    return [int(value[i:i + 2], 16) for i in (1, 3, 5)]


def mix(a, b, amount):
    return '#' + ''.join(f'{round(x * (1 - amount) + y * amount):02x}'
                         for x, y in zip(rgb(a), rgb(b)))


def luminance(value):
    def linear(c):
        c /= 255
        return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
    r, g, b = [linear(c) for c in rgb(value)]
    return .2126 * r + .7152 * g + .0722 * b


def contrast(a, b):
    low, high = sorted([luminance(a), luminance(b)])
    return (high + .05) / (low + .05)


def readable(background, foreground):
    if contrast(background, foreground) >= 4.5:
        return foreground
    return max(('#000000', '#ffffff'), key=lambda c: contrast(background, c))


def normalize(background, surface, text, accent, accent_text, border=None):
    background, surface, text, accent, accent_text = map(
        color, (background, surface, text, accent, accent_text))
    # Keep one text color legible on both main surfaces where possible.
    if min(contrast(background, text), contrast(surface, text)) < 4.5:
        text = max(('#000000', '#ffffff'),
                   key=lambda c: min(contrast(background, c), contrast(surface, c)))
    return {'background': background, 'surface': surface, 'text': text,
            'muted': mix(text, background, .25),
            'border': color(border) if border else mix(background, text, .30),
            'accent': accent, 'accentText': readable(accent, accent_text),
            'scheme': 'dark' if luminance(background) < .35 else 'light'}


def gtk(path):
    values = dict(re.findall(r'@define-color\s+(\w+)\s+([^;]+);', read_text(path)))
    def get(name):
        seen = set()
        while name not in seen:
            seen.add(name)
            value = values[name].strip()
            if not value.startswith('@'):
                return color(value)
            name = value[1:]
        raise ValueError('Circular GTK alias')
    return normalize(get('window_bg_color'), get('headerbar_bg_color'),
                     get('window_fg_color'), get('accent_bg_color'), get('accent_fg_color'))


def qt(path):
    values = [color(c) for c in ini(path)['ColorScheme']['active_colors'].split(',')]
    if len(values) < 17:
        raise ValueError('Incomplete Qt palette')
    # QPalette: Window, Button, WindowText, Highlight, HighlightedText, Mid.
    return normalize(values[10], values[1], values[0], values[12], values[13], values[5])


def kde(path):
    data = ini(path)
    return normalize(data['Colors:Window']['BackgroundNormal'],
                     data['Colors:Header']['BackgroundNormal'],
                     data['Colors:Window']['ForegroundNormal'],
                     data['Colors:Selection']['BackgroundNormal'],
                     data['Colors:Selection']['ForegroundNormal'])


def candidates(source):
    root = config_root()
    result = []
    if source in ('auto', 'gtk'):
        for version in ('3.0', '4.0'):
            folder = root / f'gtk-{version}'
            css = folder / 'gtk.css'
            # Automatic selection only uses a GTK export that is imported.
            active = source == 'gtk' or (css.exists() and 'noctalia.css' in read_text(css))
            if active:
                result.append((f'gtk{version[0]}', folder / 'noctalia.css', gtk))
    if source in ('auto', 'qt'):
        for version in ('6', '5'):
            folder = root / f'qt{version}ct'
            settings = folder / f'qt{version}ct.conf'
            if settings.exists():
                try:
                    appearance = ini(settings)['Appearance']
                    if appearance.getboolean('custom_palette', False):
                        path = Path(appearance['color_scheme_path']).expanduser()
                        if not path.is_absolute():
                            path = folder / path
                        result.append((f'qt{version}', path, qt))
                except (ValueError, KeyError, OSError):
                    pass
        globals_path = root / 'kdeglobals'
        if globals_path.exists():
            try:
                selected = ini(globals_path)['General'].get('ColorScheme', '')
                if re.fullmatch(r'[\w-]+', selected):
                    data_home = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
                    result.append(('kde', data_home / 'color-schemes' / f'{selected}.colors', kde))
            except (ValueError, KeyError, OSError):
                pass
    return result


def get_palette(source='auto'):
    if source not in SOURCES:
        raise ValueError('Unknown palette source')
    for label, path, parser in candidates(source):
        try:
            return {'ok': True, 'source': label, 'palette': parser(path)}
        except (OSError, ValueError, KeyError, configparser.Error):
            continue
    return {'ok': False, 'error': 'No supported active GTK/Qt export found.'}


def signature(source):
    root = config_root()
    paths = [root / f'gtk-{v}' / f for v in ('3.0', '4.0') for f in ('gtk.css', 'noctalia.css')]
    paths += [root / f'qt{v}ct/qt{v}ct.conf' for v in ('6', '5')]
    paths += [root / 'kdeglobals']
    try:
        paths += [path for _, path, _ in candidates(source)]
    except (OSError, ValueError):
        pass
    result = []
    for path in paths:
        try:
            stat = path.stat()
            result.append((str(path), stat.st_mtime_ns, stat.st_size, stat.st_ino))
        except OSError:
            result.append((str(path), None))
    return tuple(result)


def read_exact(stream, count):
    result = b''
    while len(result) < count:
        chunk = stream.read(count - len(result))
        if not chunk:
            if result:
                raise ValueError('Truncated message')
            return None
        result += chunk
    return result


def receive(stream):
    header = read_exact(stream, 4)
    if header is None:
        return None
    length = struct.unpack('=I', header)[0]
    if not 0 < length <= 4096:
        raise ValueError('Invalid message size')
    payload = read_exact(stream, length)
    if payload is None:
        raise ValueError('Truncated message')
    return json.loads(payload)


def send(value):
    message = json.dumps(value, separators=(',', ':')).encode()
    sys.stdout.buffer.write(struct.pack('=I', len(message)) + message)
    sys.stdout.buffer.flush()


def serve():
    source, watching, previous, last = 'auto', False, None, None
    # Unbuffered reads avoid selecting a pipe whose next message is buffered.
    stream = os.fdopen(os.dup(sys.stdin.fileno()), 'rb', buffering=0)
    while True:
        if select.select([stream], [], [], 2 if watching else None)[0]:
            request = receive(stream)
            if request is None:
                return
            if not isinstance(request, dict) or request.get('command') not in ('read', 'watch'):
                send({'ok': False, 'error': 'Unsupported command.'})
                continue
            if request.get('source', 'auto') not in SOURCES:
                send({'ok': False, 'error': 'Unsupported source.'})
                continue
            source = request.get('source', 'auto')
            watching = request['command'] == 'watch'
            previous, last = None, None
        state = signature(source)
        if state != previous:
            message = get_palette(source)
            fingerprint = hashlib.sha256(json.dumps(message, sort_keys=True).encode()).digest()
            if fingerprint != last:
                send(message)
                last = fingerprint
            previous = state


if __name__ == '__main__':
    if '--print' in sys.argv:
        parser = argparse.ArgumentParser()
        parser.add_argument('--print', action='store_true')
        parser.add_argument('--source', choices=SOURCES, default='auto')
        args = parser.parse_args()
        print(json.dumps(get_palette(args.source), indent=2))
    else:
        try:
            serve()
        except (OSError, ValueError, KeyError, configparser.Error):
            sys.exit(1)

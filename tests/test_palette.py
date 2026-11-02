import importlib.util
import io
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HOST = Path(__file__).resolve().parents[1] / 'native/palette_host.py'
spec = importlib.util.spec_from_file_location('palette_host', HOST)
palette = importlib.util.module_from_spec(spec)
spec.loader.exec_module(palette)
GTK = '''@define-color window_bg_color #15121a;
@define-color window_fg_color #e7e0ec;
@define-color headerbar_bg_color #211e26;
@define-color accent_bg_color #d3bbff;
@define-color accent_fg_color #40008d;
@define-color test_alias @accent_bg_color;
'''


class PaletteTest(unittest.TestCase):
    def test_gtk_qt_and_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'palette.css'
            file.write_text(GTK)
            result = palette.gtk(file)
            self.assertEqual(result['background'], '#15121a')
            self.assertEqual(result['text'], '#e7e0ec')
            self.assertGreaterEqual(palette.contrast(result['accent'], result['accentText']), 4.5)
            colors = ['#ffffff'] * 22
            colors[0] = '#e7e0ec'; colors[1] = colors[10] = '#15121a'
            colors[12] = '#a576fd'; colors[13] = '#1b0043'
            file.write_text('[ColorScheme]\nactive_colors=' + ', '.join(colors))
            self.assertEqual(palette.qt(file)['accent'], '#a576fd')
            for value in ('url(https://invalid)', '#123456; color:red', '#gg0000', '999,0,0'):
                with self.assertRaises(ValueError): palette.color(value)
            with self.assertRaises(ValueError): palette.get_palette('../../etc/passwd')
            with self.assertRaises(ValueError): palette.receive(io.BytesIO(struct.pack('=I', 4097)))

    def test_auto_source_and_live_watch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'gtk-3.0'; folder.mkdir()
            (folder / 'gtk.css').write_text('@import url("noctalia.css");')
            export = folder / 'noctalia.css'; export.write_text(GTK)
            with patch.dict(os.environ, {'XDG_CONFIG_HOME': directory}):
                self.assertEqual(palette.get_palette()['source'], 'gtk3')
            process = subprocess.Popen([sys.executable, str(HOST)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={**os.environ, 'XDG_CONFIG_HOME': directory})
            def message(value):
                data = json.dumps(value).encode()
                process.stdin.write(struct.pack('=I', len(data)) + data)
                process.stdin.flush()
            def read():
                self.assertTrue(select.select([process.stdout], [], [], 6)[0], 'native response timed out')
                return palette.receive(process.stdout)
            try:
                message({'command':'watch','source':'auto'})
                first = read(); self.assertEqual(first['palette']['accent'], '#d3bbff')
                replacement = folder / 'next.css'
                replacement.write_text(GTK.replace('#d3bbff', '#aabbcc'))
                replacement.replace(export)  # Atomic writes are used by theme exporters.
                second = read(); self.assertEqual(second['palette']['accent'], '#aabbcc')
                self.assertNotIn(directory, json.dumps(second))
                message({'command':'read','source':'../../etc/passwd'})
                self.assertFalse(read()['ok'])
                process.stdin.close()
                self.assertEqual(process.wait(timeout=4), 0)
            finally:
                if process.poll() is None: process.kill(); process.wait()
                process.stdout.close(); process.stderr.close()


if __name__ == '__main__':
    unittest.main()

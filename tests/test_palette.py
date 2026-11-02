import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from desktop import palette
from desktop.sync_colors import sync

GTK = '''@define-color window_bg_color #15121a;
@define-color window_fg_color #e7e0ec;
@define-color headerbar_bg_color #211e26;
@define-color accent_bg_color #d3bbff;
@define-color accent_fg_color #40008d;
'''


class PaletteTest(unittest.TestCase):
    def test_parsing_and_contrast(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'colors.css'
            file.write_text(GTK)
            result = palette.gtk(file)
            self.assertEqual(result['text'], '#e7e0ec')
            self.assertGreaterEqual(palette.contrast(result['accent'], result['accentText']), 4.5)
            values = ['#ffffff'] * 22
            values[0] = '#e7e0ec'; values[1] = values[10] = '#15121a'
            values[12] = '#a576fd'; values[13] = '#1b0043'
            file.write_text('[ColorScheme]\nactive_colors=' + ','.join(values))
            self.assertEqual(palette.qt(file)['accent'], '#a576fd')
            for value in ('url(https://invalid)', '#123456; color:red', '#gg0000'):
                with self.assertRaises(ValueError): palette.color(value)

    def test_standalone_sync_and_uninstall(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config'; folder = config / 'gtk-3.0'; folder.mkdir(parents=True)
            (folder / 'gtk.css').write_text('@import url("noctalia.css");')
            export = folder / 'noctalia.css'; export.write_text(GTK)
            profile = root / 'profile'; profile.mkdir(); (profile / 'prefs.js').write_text('// fixture')
            env = {**os.environ, 'XDG_CONFIG_HOME': str(config)}
            def install(*args):
                result = subprocess.run([sys.executable, str(ROOT / 'instalar.py'), '--profile', str(profile), *args],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            install('--mode', 'desktop')
            css = profile / 'chrome/browsermaxxing/palette-desktop.css'
            self.assertIn('#d3bbff', css.read_text())
            self.assertNotIn('--lwt-', css.read_text())
            self.assertNotIn('--toolbar-background-color', css.read_text())
            with patch.dict(os.environ, {'XDG_CONFIG_HOME': str(config)}):
                _, changed = sync(profile)
                self.assertFalse(changed)
                replacement = folder / 'next.css'
                replacement.write_text(GTK.replace('#d3bbff', '#aabbcc'))
                replacement.replace(export)
                _, changed = sync(profile)
                self.assertTrue(changed)
                self.assertIn('#aabbcc', css.read_text())
            install('--remove')
            self.assertFalse((profile / 'chrome/userChrome.css').exists())
            self.assertFalse((profile / 'user.js').exists())

    def test_invalid_palette_preserves_installed_css(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory); (profile / 'prefs.js').write_text('// fixture')
            env = {**os.environ, 'XDG_CONFIG_HOME': str(profile / 'missing')}
            result = subprocess.run([sys.executable, str(ROOT / 'instalar.py'), '--profile', directory,
                                     '--mode', 'desktop'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((profile / 'chrome/userChrome.css').exists())


if __name__ == '__main__':
    unittest.main()

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'instalar.py'


class ThemeInstallerTest(unittest.TestCase):
    def run_installer(self, profile, *args):
        return subprocess.run([sys.executable, str(INSTALLER), '--profile', str(profile), *args],
                              capture_output=True, text=True)

    def test_install_mode_change_and_exact_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / 'chrome').mkdir()
            (profile / 'prefs.js').write_text('// fixture')
            css = b':root { --existing: 1; }\n'
            prefs = b'user_pref("existing", true);\n'
            (profile / 'chrome/userChrome.css').write_bytes(css)
            (profile / 'user.js').write_bytes(prefs)
            for mode in ['dark', 'light', 'auto']:
                result = self.run_installer(profile, '--mode', mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'palette-{mode}.css', (profile / 'chrome/userChrome.css').read_text())
            self.assertEqual((profile / 'user.js').read_text().count('toolkit.legacy'), 1)
            result = self.run_installer(profile, '--remove')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((profile / 'chrome/userChrome.css').read_bytes(), css)
            self.assertEqual((profile / 'user.js').read_bytes(), prefs)

    def test_modified_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / 'prefs.js').write_text('// fixture')
            self.assertEqual(self.run_installer(profile).returncode, 0)
            target = profile / 'chrome/browsermaxxing/theme.css'
            edited = target.read_bytes() + b'/* local edit */'
            target.write_bytes(edited)
            self.assertNotEqual(self.run_installer(profile, '--remove').returncode, 0)
            self.assertEqual(target.read_bytes(), edited)

    def test_nested_xdg_profiles(self):
        spec = importlib.util.spec_from_file_location('bmx_installer', INSTALLER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'librewolf/librewolf'
            root.mkdir(parents=True)
            (root / 'test-profile').mkdir()
            (root / 'profiles.ini').write_text('[Profile0]\nIsRelative=1\nPath=test-profile\n')
            with patch.dict(os.environ, {'XDG_CONFIG_HOME': directory}):
                self.assertIn(root / 'test-profile', module.profiles())


if __name__ == '__main__':
    unittest.main()

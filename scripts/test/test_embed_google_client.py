"""embed-google-client.sh, run on a copy of the app's Info.plist as the CI and release builds run it."""

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(SCRIPTS, 'embed-google-client.sh')
INFO_PLIST = os.path.join(os.path.dirname(SCRIPTS), 'App', 'FalconMail', 'Info.plist')
# Made up: the shape of a client ID, and nobody's.
CLIENT_ID = '123-abc.apps.googleusercontent.com'
SCHEME = 'com.googleusercontent.apps.123-abc'


def committed_info_plist():
    """The Info.plist as committed. CI embeds the client into the working copy before these
    tests run, so the file on disk may already carry the Google scheme."""
    root = os.path.dirname(SCRIPTS)
    shown = subprocess.run(['git', '-C', root, 'show', 'HEAD:App/FalconMail/Info.plist'],
                           capture_output=True)
    if shown.returncode == 0:
        return shown.stdout
    with open(INFO_PLIST, 'rb') as f:
        return f.read()


class EmbedGoogleClientTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix='embed-google-client-')
        self.plist = os.path.join(self.folder, 'Info.plist')
        with open(self.plist, 'wb') as f:
            f.write(committed_info_plist())

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def run_script(self, client_id=CLIENT_ID, secret='not-a-secret'):
        env = {k: v for k, v in os.environ.items() if not k.startswith('GOOGLE_OAUTH_')}
        if client_id is not None:
            env['GOOGLE_OAUTH_CLIENT_ID'] = client_id
            env['GOOGLE_OAUTH_CLIENT_SECRET'] = secret
        return subprocess.run(['sh', SCRIPT, self.plist], capture_output=True, text=True, env=env, timeout=60, check=True)

    def read(self):
        with open(self.plist, 'rb') as f:
            return plistlib.load(f)

    def schemes(self):
        return [scheme for kind in self.read().get('CFBundleURLTypes', []) for scheme in kind['CFBundleURLSchemes']]

    def test_the_app_declares_mailto_before_anything_is_embedded(self):
        self.assertEqual(self.schemes(), ['mailto'])

    def test_google_sign_in_is_added_beside_mailto(self):
        self.run_script()
        self.assertEqual(self.schemes(), ['mailto', SCHEME], 'FalconMail can still be the default mail app')
        info = self.read()
        self.assertEqual(info['FalconGoogleClientID'], CLIENT_ID)
        self.assertEqual(info['FalconGoogleClientSecret'], 'not-a-secret')

    def test_running_twice_adds_the_scheme_once(self):
        self.run_script()
        self.run_script()
        self.assertEqual(self.schemes(), ['mailto', SCHEME])

    def test_without_a_client_the_plist_is_left_as_it_was(self):
        with open(self.plist, 'rb') as f:
            before = f.read()
        result = self.run_script(client_id=None)
        self.assertIn('no Google sign-in', result.stdout)
        with open(self.plist, 'rb') as f:
            self.assertEqual(f.read(), before)

    def test_a_plist_without_url_types_gets_the_google_one(self):
        info = self.read()
        del info['CFBundleURLTypes']
        with open(self.plist, 'wb') as f:
            plistlib.dump(info, f)
        self.run_script()
        self.assertEqual(self.schemes(), [SCHEME])


if __name__ == '__main__':
    unittest.main()

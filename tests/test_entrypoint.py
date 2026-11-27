import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.getuid() == 0, 'Non-root bootstrap tests; root permissions are tested in the container smoke test.')
class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-entrypoint-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user_home = self.root / 'home'
        self.seed = self.root / 'seed'
        self.seed.mkdir()
        (self.seed / 'node_modules').mkdir()
        (self.seed / 'package.json').write_text(json.dumps({'dependencies': {'seed-plugin': '1.0.0'}}))
        (self.seed / 'cordis.patch.yml').write_text('[]\n')
        (self.seed / 'node_modules' / 'real-package').mkdir()
        (self.seed / 'node_modules' / 'real-package' / 'index.js').write_text('export default 1;\n')
        (self.seed / 'node_modules' / 'linked-package').symlink_to('real-package', target_is_directory=True)
        self.binary_directory = self.root / 'bin'
        self.binary_directory.mkdir()
        dsh = self.binary_directory / 'dsh'
        dsh.write_text('#!/usr/bin/env python3\nimport json,os,sys\nopen(os.environ["DSH_TEST_ARGV"], "w").write(json.dumps(sys.argv[1:]))\n')
        dsh.chmod(0o755)
        self.environment = {
            **os.environ,
            'HOME': str(self.user_home),
            'DSH_HOME': str(self.user_home / '.dsh'),
            'DSH_AGENTS_HOME': str(self.user_home / '.agents'),
            'MNEMON_DATA_DIR': str(self.user_home / '.mnemon'),
            'DSH_SEED_DIR': str(self.seed),
            'DSH_DOCKER_LIB_DIR': str(REPOSITORY / 'scripts'),
            'DSH_TEST_ARGV': str(self.root / 'argv.json'),
            'DSH_BIND_HOST': '172.20.0.2',
            'DSH_PUBLIC_URL': 'http://localhost:3080/',
            'DSH_PORT': '3080',
            'DSH_TRUSTED_HOSTS': '',
            'PATH': str(self.binary_directory) + os.pathsep + os.environ['PATH'],
        }

    @property
    def profile(self):
        return self.user_home / '.dsh' / 'profiles' / 'web'

    def run_entrypoint(self, *arguments):
        return subprocess.run(
            ['bash', str(REPOSITORY / 'scripts' / 'entrypoint.sh'), *arguments],
            env=self.environment, cwd=self.root, text=True, capture_output=True, timeout=15,
        )

    def test_first_start_keeps_relative_package_links(self):
        result = self.run_entrypoint('true')
        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.profile / 'node_modules' / 'linked-package'
        self.assertEqual(os.readlink(link), 'real-package')
        self.assertTrue((link / 'index.js').is_file())
        self.assertTrue((self.user_home / '.agents' / 'skills').is_dir())

    def test_recreation_preserves_installed_plugins_and_user_configuration(self):
        self.assertEqual(self.run_entrypoint('true').returncode, 0)
        manifest = {'dependencies': {'seed-plugin': '1.0.0', 'user-plugin': '2.0.0'}}
        (self.profile / 'package.json').write_text(json.dumps(manifest))
        (self.profile / 'cordis.patch.yml').write_text('# user configuration\n[]\n')
        (self.seed / 'package.json').write_text(json.dumps({'dependencies': {'seed-plugin': '9.0.0'}}))
        result = self.run_entrypoint('true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.profile / 'package.json').read_text()), manifest)
        self.assertEqual((self.profile / 'cordis.patch.yml').read_text(), '# user configuration\n[]\n')

    def test_partial_existing_profile_is_preserved_and_reported(self):
        self.profile.mkdir(parents=True)
        marker = self.profile / 'user-file.txt'
        marker.write_text('keep me')
        result = self.run_entrypoint('true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('repair', result.stderr)
        self.assertEqual(marker.read_text(), 'keep me')
        self.assertFalse((self.profile / 'package.json').exists())

    def test_concurrent_initialization_produces_one_complete_profile(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.run_entrypoint('true'), range(2)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum('initialized' in result.stdout for result in results), 1)
        self.assertTrue((self.profile / 'node_modules' / 'linked-package' / 'index.js').exists())

    def test_web_flags_and_additional_patch_paths_are_forwarded(self):
        result = self.run_entrypoint('dsh', 'web', '--patch', '/home/node/my patches/custom.yml')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / 'argv.json').read_text()), [
            'web', '--no-open', '--host', '172.20.0.2', '--port', '3080',
            '--public-url', 'http://localhost:3080/', '--trusted-host', 'localhost:3080',
            '--patch', '/home/node/my patches/custom.yml',
        ])


if __name__ == '__main__':
    unittest.main()

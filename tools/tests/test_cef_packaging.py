# SPDX-License-Identifier: GPL-3.0-or-later
"""Dev-only CEF packing, notices, and release absence checks."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage = load('stage_cef', 'build/cef/stage-payload.py')
verify = load('verify_cef_ipa', 'build/verify-ipa.py')
artifacts = load('stage_cef_artifacts', 'build/stages/stage-artifacts.py')
notices = load('generate_cef_notices', 'build/cef/generate-notices.py')


class CEFPackaging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.notices = self.root / 'notices'
        self.app = self.root / 'app'
        self.dest = self.app / 'cef'
        self.record = self.root / 'payload.sha256'
        self.notice_record = self.root / 'notices.sha256'
        self.make_record(self.source, self.record, ['Release/libcef.dll', 'Release/libcef.lib',
                         'Release/v8_context_snapshot.bin', 'Resources/locales/en-US.pak'])
        self.make_record(self.notices, self.notice_record, ['CEF-LICENSE.txt', 'about_credits.html',
                         'FFmpeg-LICENSE.md', 'FFmpeg-COPYING.LGPLv2.1'])
        verify.failures.clear()
        self.addCleanup(verify.failures.clear)

    def make_record(self, root, record, names):
        lines = []
        for name in names:
            p = root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(name)
            lines.append(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {name}\n')
        record.write_text(''.join(lines))

    def pack(self):
        stage.stage(self.source, self.notices, self.dest, self.record, self.notice_record)

    def test_flatten_exact_set_no_import_library_or_unrecorded_extra(self):
        (self.source / 'Release/extra.dll').write_bytes(b'excluded')
        self.pack()
        tree = self.dest / '143.0.14'
        self.assertTrue((tree / 'locales/en-US.pak').is_file())
        self.assertTrue((tree / 'v8_context_snapshot.bin').is_file())
        self.assertFalse((tree / 'libcef.lib').exists())
        self.assertFalse((tree / 'extra.dll').exists())
        stage.payload.verify_runtime(tree, self.record, self.notice_record)
        (tree / 'extra.dll').write_bytes(b'excluded')
        with self.assertRaisesRegex(ValueError, 'file set'):
            stage.payload.verify_runtime(tree, self.record, self.notice_record)

    def test_missing_or_changed_inputs_do_not_replace_previous_stage(self):
        self.pack()
        (self.dest / 'sentinel').write_bytes(b'old')
        (self.notices / 'about_credits.html').unlink()
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.pack()
        self.assertTrue((self.dest / 'sentinel').exists())
        (self.source / 'Release/libcef.dll').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.pack()
        self.assertTrue((self.dest / 'sentinel').exists())

    def test_flattened_collision_rejected(self):
        self.make_record(self.source, self.record, ['Release/libcef.dll', 'Resources/LIBCEF.dll'])
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.pack()
        self.assertFalse(self.dest.exists())

    def test_runtime_changed_and_symlink_rejected(self):
        self.pack()
        tree = self.dest / '143.0.14'
        dll = tree / 'libcef.dll'
        dll.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            stage.payload.verify_runtime(tree, self.record, self.notice_record)
        dll.unlink()
        dll.symlink_to(self.source / 'Release/libcef.dll')
        with self.assertRaisesRegex(ValueError, 'file set'):
            stage.payload.verify_runtime(tree, self.record, self.notice_record)

    def test_release_resource_list_omits_cef(self):
        text = artifacts.release_xtool_yml((REPO / 'app/xtool.yml').read_text())
        self.assertNotIn('- Runtime/cef', text)
        self.assertIn('- Runtime/mono', text)

    def test_release_and_distribution_reject_payload_anywhere(self):
        self.pack()
        with contextlib.redirect_stdout(io.StringIO()):
            verify.cef_checks(self.app, self.app, 'release')
            verify.cef_checks(self.app, self.app, 'dev', distribution=True)
        self.assertEqual(len(verify.failures), 2)
        self.dest.rename(self.app / 'hidden')
        verify.failures.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            verify.cef_checks(self.app, self.app, 'release')
        self.assertEqual(len(verify.failures), 1)  # libcef.dll in a renamed directory

    def test_release_absent_passes_dev_missing_fails(self):
        self.app.mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            verify.cef_checks(self.app, self.app, 'release')
        self.assertFalse(verify.failures)
        with contextlib.redirect_stdout(io.StringIO()):
            verify.cef_checks(self.app, self.app, 'dev')
        self.assertEqual(len(verify.failures), 1)

    def test_dev_calls_exact_runtime_verifier(self):
        self.pack()
        with patch.object(verify.cef_payload, 'verify_runtime',
                          side_effect=lambda tree: stage.payload.verify_runtime(tree, self.record, self.notice_record)) as checked:
            with contextlib.redirect_stdout(io.StringIO()):
                verify.cef_checks(self.app, self.app, 'dev')
            checked.assert_called_once_with(self.dest / '143.0.14')
        self.assertFalse(verify.failures)

    def test_notices_record_carries_committed_build_notice(self):
        """The MSVC CRT and distribution statement (BUILD-NOTICE.txt) is packed."""
        record = stage.payload.read_record(stage.payload.NOTICES_RECORD, payload=False)
        digest = hashlib.sha256((REPO / 'build/cef/BUILD-NOTICE.txt').read_bytes()).hexdigest()
        self.assertEqual(record['Playport-BUILD-NOTICE.txt'], digest)
        self.assertLessEqual({'about_credits.html', 'CEF-LICENSE.txt', 'FFmpeg-LICENSE.md',
                              'FFmpeg-COPYING.LGPLv2.1'}, set(record))
        lines = stage.payload.NOTICES_RECORD.read_bytes().splitlines()
        self.assertEqual(lines, sorted(lines, key=lambda l: l.split(b'  ', 1)[1]))

    def test_notice_generator_rejects_wrong_pin_before_generation(self):
        with patch.object(notices.subprocess, 'check_output', return_value='wrong\n'), \
             patch.object(notices.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'pins.lock'):
                notices.generate(self.source, self.notices)
            run.assert_not_called()

    def test_notice_generator_propagates_failure(self):
        pins = dict(line.split()[:2] for line in (REPO / 'pins.lock').read_text().splitlines()
                    if line.strip() and not line.startswith('#'))
        import subprocess
        with patch.object(notices.subprocess, 'check_output', side_effect=[pins['chromium'], pins['cef']]), \
             patch.object(notices.subprocess, 'run', side_effect=subprocess.CalledProcessError(3, 'credits')):
            with self.assertRaises(subprocess.CalledProcessError):
                notices.generate(self.source, self.notices)
        self.assertTrue((self.notices / 'about_credits.html').is_file())


if __name__ == '__main__':
    unittest.main()

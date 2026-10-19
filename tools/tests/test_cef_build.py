# SPDX-License-Identifier: GPL-3.0-or-later
"""build/cef: prebuilt input integrity and cross-build wrapper exit status."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
ADAPTERS = REPO / 'build/cef'
spec = importlib.util.spec_from_file_location('cef_payload', ADAPTERS / 'verify-payload.py')
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


class Payload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.record = self.root / 'record.sha256'
        (self.root / 'Release').mkdir()
        (self.root / 'Release/libcef.dll').write_bytes(b'fixture')
        self.digest = hashlib.sha256(b'fixture').hexdigest()
        self.record.write_text(f'{self.digest}  Release/libcef.dll\n')

    @staticmethod
    def pe(section_alignment, file_alignment, sections):
        """A PE header with (rva, raw size, raw offset) sections."""
        import struct
        data = bytearray(0x400)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 0x80)
        data[0x80:0x84] = b'PE\0\0'
        struct.pack_into('<H12xH', data, 0x86, len(sections), 0xf0)
        struct.pack_into('<II', data, 0x98 + 32, section_alignment, file_alignment)
        for i, (rva, size, offset) in enumerate(sections):
            struct.pack_into('<8sIIII', data, 0x98 + 0xf0 + 40 * i, b'.s%d' % i, size, rva, size, offset)
        return bytes(data)

    def test_16k_sections(self):
        good = self.pe(0x4000, 0x4000, [(0x4000, 0x4000, 0x4000), (0x8000, 0, 0)])
        self.assertEqual(payload.unaligned_sections(good), [])
        self.assertEqual(payload.unaligned_sections(self.pe(0x1000, 0x200, [(0x1000, 0x200, 0x400)])),
                         ['alignment 0x1000/0x200', '.s0 rva 0x1000 file 0x400'])
        self.assertEqual(payload.unaligned_sections(self.pe(0x4000, 0x4000, [(0x4000, 0x200, 0x4200)])),
                         ['.s0 rva 0x4000 file 0x4200'])
        (self.root / 'Release/libcef.dll').write_bytes(good)
        self.assertEqual(payload.verify_16k_sections(self.root, ('Release/libcef.dll',)), ['Release/libcef.dll'])
        (self.root / 'Release/libcef.dll').write_bytes(self.pe(0x1000, 0x200, []))
        with self.assertRaisesRegex(ValueError, 'not 16 KiB-aligned: Release/libcef.dll: alignment'):
            payload.verify_16k_sections(self.root, ('Release/libcef.dll',))
        with self.assertRaisesRegex(ValueError, 'not a PE image'):
            payload.unaligned_sections(b'fixture')

    def test_verified(self):
        self.assertEqual(payload.verify_payload(self.root, self.record), ['Release/libcef.dll'])

    def test_missing(self):
        (self.root / 'Release/libcef.dll').unlink()
        with self.assertRaisesRegex(ValueError, 'payload missing'):
            payload.verify_payload(self.root, self.record)

    def test_mismatched(self):
        (self.root / 'Release/libcef.dll').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            payload.verify_payload(self.root, self.record)

    def test_bad_records(self):
        for name in ('/absolute', '../escape', 'Release/../escape', 'Release//libcef.dll', 'Other/file'):
            with self.subTest(name=name):
                self.record.write_text(f'{self.digest}  {name}\n')
                with self.assertRaisesRegex(ValueError, 'invalid CEF payload path'):
                    payload.verify_payload(self.root, self.record)
        for text, error in (('', 'empty'), ('bad\n', 'malformed'),
                            ((f'{self.digest}  Release/libcef.dll\n') * 2, 'invalid')):
            self.record.write_text(text)
            with self.assertRaisesRegex(ValueError, error):
                payload.verify_payload(self.root, self.record)


class Wrappers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / 'cef-src'
        self.env = dict(os.environ, PLAYPORT_BUILD=str(self.root))

    def fake_tool(self, path, status):
        path = self.work / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#!/bin/sh\nexit {status}\n')
        path.chmod(0o755)

    def test_ninja_propagates_failure_and_success(self):
        for status in (23, 0):
            self.fake_tool('src/third_party/ninja/ninja', status)
            result = subprocess.run(['bash', str(ADAPTERS / 'run-ninja-lowva.sh'), 'test', '1'],
                                    env=self.env, capture_output=True)
            self.assertEqual(result.returncode, status)
            self.assertEqual((self.work / 'logs/lowva-test.exit').read_text(), f'{status}\n')

    def test_ninja_rejects_invalid_arguments(self):
        for args in ([], ['../escape'], ['test', '0']):
            result = subprocess.run(['bash', str(ADAPTERS / 'run-ninja-lowva.sh'), *args],
                                    env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_gn_args_and_exit_status(self):
        for status in (17, 0):
            self.fake_tool('src/buildtools/linux64/gn', status)
            result = subprocess.run(['bash', str(ADAPTERS / 'run-project-files.sh')],
                                    env=self.env, capture_output=True)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual((self.work / 'logs/project-files-lowva.exit').read_text(), f'{status}\n')
            args = (self.work / 'src/out/Release_GN_x64_lowva/args.gn').read_text()
            self.assertTrue(args.startswith((ADAPTERS / 'args.gn').read_text()))
            self.assertIn(f'visual_studio_path="{self.work}/tools/vs-xwin"', args)
            self.assertIn('v8_enable_pointer_compression=false', args)
            self.assertIn('partition_alloc_low_va=true', args)


if __name__ == '__main__':
    unittest.main()

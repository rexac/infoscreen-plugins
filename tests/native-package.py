#!/usr/bin/env python3
"""Exercise the reviewed-native exception and actual archive bytes/modes without running ELF code."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import check
import build


class NativePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plugin = Path(self.temp.name) / 'ipv6-fix'
        shutil.copytree(ROOT / 'plugins/ipv6-fix', self.plugin)

    def errors(self):
        return check.check(str(self.plugin))[0]

    def test_reviewed_payload_passes(self):
        self.assertEqual(self.errors(), [])

    def test_replaced_binary_fails_digest(self):
        binary = self.plugin / 'bin/rdisc6'
        binary.write_bytes(binary.read_bytes() + b'changed')
        self.assertTrue(any('SHA-256' in error for error in self.errors()))

    def test_unreviewed_binary_is_not_allowed(self):
        shutil.copy2(self.plugin / 'bin/rdisc6', self.plugin / 'bin/other')
        self.assertTrue(any('bin/other: file type' in error for error in self.errors()))

    def test_missing_executable_mode_is_rejected(self):
        (self.plugin / 'bin/rdisc6').chmod(0o644)
        self.assertTrue(any('0755' in error for error in self.errors()))

    def test_changed_source_archive_is_rejected(self):
        archive = self.plugin / 'sources/ndisc6-1.0.8.tar.bz2'
        archive.write_bytes(b'changed')
        self.assertTrue(any('SHA-256' in error for error in self.errors()))

    def test_package_preserves_reviewed_binary_and_source(self):
        manifest = json.loads((self.plugin / 'manifest.json').read_text())
        data = build.package(str(self.plugin), 'ipv6-fix', manifest['version'])
        self.assertEqual(data, build.package(str(self.plugin), 'ipv6-fix', manifest['version']))
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            for (_, rel), digest in {**check.NATIVE_FILES, **check.SOURCE_ARCHIVES}.items():
                info = archive.getmember('ipv6-fix/' + rel)
                expected_mode = 0o755 if ('ipv6-fix', rel) in check.NATIVE_FILES else 0o644
                self.assertEqual(info.mode, expected_mode)
                self.assertEqual(hashlib.sha256(archive.extractfile(info).read()).hexdigest(), digest)
            self.assertEqual(archive.getmember('ipv6-fix/worker.uc').mode, 0o644)
            self.assertGreater(archive.getmember('ipv6-fix/COPYING.ndisc6.txt').size, 1000)


if __name__ == '__main__':
    unittest.main()

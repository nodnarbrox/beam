"""Release packaging must reject missing or changed source/native inputs."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from check_public_release import check, source_digest


class PackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'release-review').mkdir()
        (self.root / 'native.so').write_bytes(b'native test input')
        (self.root / 'NOTICES.txt').write_text('test license notice')
        with zipfile.ZipFile(self.root / 'release-review/source.zip', 'w') as bundle:
            bundle.writestr('test-source.txt', 'source test input')
        def entry(path):
            return {'path': path, 'sha256': hashlib.sha256((self.root / path).read_bytes()).hexdigest()}
        self.record = {
            'schemaVersion': 2, 'sourceDigest': source_digest(self.root),
            'nativeSourceBundle': entry('release-review/source.zip'),
            'licenseNotices': entry('NOTICES.txt'),
            'nativeArtifacts': [dict(entry('native.so'), sourceComponent='test-source.txt',
                                     license='MIT', provenance='test build')],
        }
        self.save()

    def save(self):
        (self.root / 'release-review/packaging.json').write_text(json.dumps(self.record))

    def test_matching_inputs_pass(self):
        self.assertEqual(check(self.root), self.record['sourceDigest'])

    def test_changed_corresponding_source_rejected(self):
        (self.root / 'release-review/source.zip').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Changed nativeSourceBundle'):
            check(self.root)

    def test_native_without_provenance_rejected(self):
        del self.record['nativeArtifacts'][0]['provenance']
        self.save()
        with self.assertRaisesRegex(ValueError, 'Native binary review'):
            check(self.root)

    def test_unrecorded_native_rejected(self):
        (self.root / 'extra.so').write_bytes(b'new native input')
        self.record['sourceDigest'] = source_digest(self.root)
        self.save()
        with self.assertRaisesRegex(ValueError, 'Native binary review'):
            check(self.root)


if __name__ == '__main__':
    unittest.main()

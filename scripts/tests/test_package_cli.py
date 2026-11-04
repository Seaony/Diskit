import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_cli', Path(__file__).resolve().parents[1] / 'package-cli.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageCLITests(unittest.TestCase):
    def fixture(self, source):
        for language in ('en', 'zh-Hans'):
            folder = source / 'Core_Core.bundle/Contents/Resources' / f'{language}.lproj'
            folder.mkdir(parents=True)
            for name in ('Localizable.strings', 'Localizable.stringsdict'):
                (folder / name).write_text('fixture')
        (source / 'kayoi-dev').write_bytes(b'local fixture')

    def test_executable_alone_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)
            (source / 'kayoi-dev').write_bytes(b'local fixture')
            with self.assertRaises(ValueError):
                module.verify_resources(source)

    def test_bundles_survive_relocation(self):
        with tempfile.TemporaryDirectory() as folder:
            source, destination = Path(folder) / 'build', Path(folder) / 'bin'
            self.fixture(source)
            other = source / 'Dependency.bundle/Contents/Resources'
            other.mkdir(parents=True)
            (other / 'PrivacyInfo.xcprivacy').write_text('fixture')
            module.package(source, destination)
            import shutil
            shutil.rmtree(source)
            module.verify_resources(destination)
            self.assertTrue((destination / 'Dependency.bundle/Contents/Resources/PrivacyInfo.xcprivacy').is_file())

    def test_missing_plural_resource_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)
            self.fixture(source)
            (source / 'Core_Core.bundle/Contents/Resources/en.lproj/Localizable.stringsdict').unlink()
            with self.assertRaises(ValueError):
                module.verify_resources(source)

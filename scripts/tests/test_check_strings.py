import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_strings import extract_keys, format_signature, inventory, validate_catalog


def entry(zh, en, plural=False):
    def language(value):
        unit = {"stringUnit": {"state": "translated", "value": value}}
        return {"variations": {"plural": {"one": unit, "other": unit}}} if plural else unit
    return {"localizations": {"zh-Hans": language(zh), "en": language(en)}}


class StringGateTests(unittest.TestCase):
    def test_comments_verbatim_and_dynamic_values_are_not_keys(self):
        source = '''
          // L("comment")
          /* Text("block") /* L("nested comment") */ */
          let fixture = "L(\\"fake\\")"
          Text(userName)
          Text(verbatim: "filename")
          Text(L("title"))
          Button("action") {}
          func L(_ value: String) -> String { value }
        '''
        keys, issues = extract_keys(source, "App/View.swift")
        self.assertEqual(set(keys), {"title", "action"})
        self.assertEqual(issues, [])

    def test_swift_escapes_raw_strings_and_interpolation(self):
        source = r'''
          L("line\nquote\"end")
          L(#"raw "quoted" text"#)
          Text("\(value)")
          Text("\(L("nested"))")
          Text("Hello \(name)")
        '''
        keys, issues = extract_keys(source, "App/View.swift")
        self.assertEqual(set(keys), {'line\nquote"end', 'raw "quoted" text', 'nested'})
        self.assertEqual(len(issues), 1)
        self.assertIn("LF", issues[0])

    def test_computed_localization_keys_are_rejected(self):
        keys, issues = extract_keys('L("prefix" + name); LF(key, value)', "App/View.swift")
        self.assertEqual(keys, {})
        self.assertEqual(len(issues), 2)

    def test_format_argument_reordering_preserves_type(self):
        self.assertEqual(format_signature("%@ has %d files"), format_signature("%2$d files for %1$@"))
        self.assertNotEqual(format_signature("%d files"), format_signature("%@ files"))
        self.assertEqual(format_signature("100%% %@"), format_signature("%@, 100%%"))

    def test_missing_unused_translation_format_and_plural_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps({"strings": {
                "unused": entry("unused", "unused"),
                "%d files": entry("%d files", "%@ files"),
                "incomplete": {"localizations": {"zh-Hans": entry("x", "x")["localizations"]["zh-Hans"]}},
            }}))
            issues = validate_catalog(path, {"%d files": ["test"], "incomplete": ["test"], "missing": ["test"]})
            for text in ["缺少键", "未使用", "缺少 en", "格式参数", "复数"]:
                self.assertTrue(any(text in issue for issue in issues), text)

    def test_complete_plural_catalog_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps({"strings": {"%d files": entry("%d 个文件", "%d files", plural=True)}}))
            self.assertEqual(validate_catalog(path, {"%d files": ["test"]}), [])

    def test_multiple_numbers_require_explicit_substitutions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            key = "%lld / %lld files"
            value = entry(key, key, plural=True)
            path.write_text(json.dumps({"strings": {key: value}}))
            self.assertTrue(any("显式" in item for item in validate_catalog(path, {key: ["test"]})))
            for language in value["localizations"]:
                value["localizations"][language] = {
                    "stringUnit": {"state": "translated", "value": "%#@done@ / %#@total@ files"},
                    "substitutions": {name: {
                        "argNum": index, "formatSpecifier": "lld",
                        "variations": {"plural": {category: {"stringUnit": {"state": "translated", "value": "%arg"}} for category in ["one", "other"]}},
                    } for name, index in [("done", 1), ("total", 2)]},
                }
            path.write_text(json.dumps({"strings": {key: value}}))
            self.assertEqual(validate_catalog(path, {key: ["test"]}), [])
            value["localizations"]["en"]["substitutions"]["total"]["argNum"] = 1
            path.write_text(json.dumps({"strings": {key: value}}))
            self.assertTrue(any("格式参数" in item for item in validate_catalog(path, {key: ["test"]})))

    def test_app_and_package_keys_belong_to_distinct_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "App").mkdir()
            (root / "App/View.swift").write_text('Text(L("app")); LF("%d rows", count)')
            package = root / "Packages/Drive/Sources/Drive"
            package.mkdir(parents=True)
            (package / "Error.swift").write_text('L("package")')
            (root / "project.yml").write_text('    NSCameraUsageDescription: camera')
            values, issues = inventory(root)
            self.assertEqual(set(values["App/Localizable.xcstrings"]), {"app", "%d rows"})
            self.assertEqual(set(values["Packages/Core/Sources/Core/Resources/Localizable.xcstrings"]), {"package"})
            self.assertEqual(set(values["App/InfoPlist.xcstrings"]), {"NSCameraUsageDescription"})
            self.assertEqual(issues, [])


if __name__ == "__main__":
    unittest.main()

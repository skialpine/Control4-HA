"""Exercise the release archive outside the source checkout."""

from pathlib import Path
import re
from tempfile import TemporaryDirectory
import unittest
from zipfile import ZipFile

from setup_skill import NAME, setup_skill


class SetupSkillTest(unittest.TestCase):
    def test_receipt_and_manual_map_survive_standalone_extraction(self):
        with TemporaryDirectory() as scratch:
            root = Path(scratch)
            revision = "2026111912"
            first = setup_skill(root, revision)
            second = setup_skill(root / "repeat", revision)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(setup_skill(root, revision, verify=True), first)
            with self.assertRaisesRegex(ValueError, "does not match"):
                setup_skill(root, "2026111913", verify=True)
            with ZipFile(first) as package:
                package.extractall(root / "standalone")
            standalone = root / "standalone" / NAME
            entry = (standalone / "SKILL.md").read_text()
            (reference,) = re.findall(r"\]\((references/[^)]+)\)", entry)
            manual_map = standalone / reference
            manuals = re.findall(
                r"\]\((release/[^)#]+)(?:#[^)]+)?\)", manual_map.read_text()
            )
            self.assertEqual(len(manuals), 8)
            self.assertTrue(
                all((manual_map.parent / manual).is_file() for manual in manuals)
            )
            self.assertEqual(
                (manual_map.parent / "release/VERSION").read_text().strip(), revision
            )


if __name__ == "__main__":
    unittest.main()

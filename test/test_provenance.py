import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "provenance", Path(__file__).resolve().parents[1] / "tools/check_provenance.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvenanceTest(unittest.TestCase):
    def test_unresolved_reference_cannot_become_a_copy(self):
        source = {
            "id": "bp-switch",
            "credit": "BP / bphillips09",
            "revision": "abc",
            "permission": "unresolved",
            "copies": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(module.check({"sources": [source]}, root), [])
            source["copies"] = [
                {
                    "path": "copied.lua",
                    "source_path": "driver.lua",
                    "changes": "adapted",
                }
            ]
            self.assertTrue(
                any(
                    "unresolved reuse" in e
                    for e in module.check({"sources": [source]}, root)
                )
            )

    def test_unrecorded_vendor_file_blocks_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "vendor").mkdir()
            (root / "vendor/unrecorded.lua").write_text("return {}")
            self.assertTrue(
                any(
                    "missing source inventory" in e
                    for e in module.check({"sources": []}, root)
                )
            )


if __name__ == "__main__":
    unittest.main()

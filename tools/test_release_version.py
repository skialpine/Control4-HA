"""Version and tag checks for this project's releases, leaving template helpers intact."""

import unittest

from release_version import tag_version, validate


class ReleaseVersionTests(unittest.TestCase):
    def test_increasing_same_day_revisions(self):
        self.assertGreater(int(validate("2026111802")), int(validate("2026111801")))
        self.assertGreater(int(validate("2026111801")), 20261118)
        self.assertGreater(int(validate("2026111900")), int(validate("2026111899")))

    def test_tag_matches_packaged_numeric_core(self):
        for tag in ("v2026111801", "v2026111801-beta.1", "v2026111801-rc1"):
            self.assertEqual(tag_version(tag, "2026111801"), "2026111801")

    def test_preview_tag_fits_the_coordinator_limit(self):
        revision = "2026111816"
        tag = "v" + revision + "-" + "x" * 38
        self.assertEqual(tag_version(tag, revision), revision)
        with self.assertRaisesRegex(ValueError, "50 characters"):
            tag_version(tag + "x", revision)

    def test_invalid_or_mismatched_tags(self):
        for tag in (
            "v20261118",
            "v2026111802",
            "2026111801",
            "v2026111801-",
            "v2026111801+local",
        ):
            with self.assertRaises(ValueError):
                tag_version(tag, "2026111801")

    def test_invalid_calendar_dates_and_controller_range(self):
        for value in ("2026023001", "2026130101", "SENTINEL", "9999110101"):
            with self.assertRaises(ValueError):
                validate(value)

    def test_releases_cannot_regress_or_reuse_a_prerelease_core(self):
        self.assertEqual(
            tag_version("v2026111802-beta.1", "2026111802", ["v2026111801-beta.1"]),
            "2026111802",
        )
        for tag in ("v2026111801", "v2026111801-beta.2"):
            with self.assertRaises(ValueError):
                tag_version(tag, "2026111801", ["v2026111801-beta.1"])
        self.assertEqual(
            tag_version("v2026111801-beta.1", "2026111801", ["v2026111801-beta.1"]),
            "2026111801",
        )


if __name__ == "__main__":
    unittest.main()

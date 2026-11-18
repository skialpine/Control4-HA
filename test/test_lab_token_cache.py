"""Offline credential-cache boundary checks; never reads real credentials."""

import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lab"))
import client


class TokenCache(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cache = Path(self.directory.name) / "credentials/token.json"
        self.setting = patch.object(client, "TOKEN_CACHE", self.cache)
        self.setting.start()
        self.addCleanup(self.setting.stop)
        self.inventory = {
            "lab_id": "test-only",
            "base_url": "http://lab.invalid:8124",
            "credential_item_id": "lab-item",
        }

    def test_first_read_is_private_and_following_process_reuses_it_without_1password(
        self,
    ):
        with patch.object(
            client, "op_json", return_value={"value": "fixture-token"}
        ) as op:
            self.assertEqual(client.api_token(self.inventory), "fixture-token")
        self.assertEqual(op.call_count, 1)
        self.assertIn("label=Lab API Token", op.call_args.args[0])
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache.parent.stat().st_mode), 0o700)
        with patch.object(
            client, "op_json", side_effect=AssertionError("unexpected read")
        ):
            self.assertEqual(client.api_token(self.inventory), "fixture-token")

    def test_different_lab_or_origin_cannot_reuse_old_credential(self):
        client._cache_token(client._token_identity(self.inventory), "old-fixture")
        for field in ("lab_id", "base_url", "credential_item_id"):
            other = {**self.inventory, field: "another-value"}
            with patch.object(
                client, "op_json", side_effect=RuntimeError("access required")
            ) as op:
                with self.assertRaises(RuntimeError):
                    client.api_token(other)
                op.assert_called_once()
        self.assertEqual(client.api_token(self.inventory), "old-fixture")

    def test_failed_refresh_or_failed_atomic_replace_preserves_working_cache(self):
        client._cache_token(client._token_identity(self.inventory), "working-fixture")
        with patch.object(client, "op_json", side_effect=RuntimeError("access denied")):
            with self.assertRaises(RuntimeError):
                client.api_token(self.inventory, refresh=True)
        with patch.object(
            client, "op_json", return_value={"value": "replacement"}
        ), patch.object(client.os, "replace", side_effect=OSError("write failed")):
            with self.assertRaises(OSError):
                client.api_token(self.inventory, refresh=True)
        self.assertEqual(client.api_token(self.inventory), "working-fixture")
        self.assertEqual(list(self.cache.parent.glob(".token-*")), [])

    def test_explicit_refresh_replaces_token_and_cache_contents_are_minimal(self):
        client._cache_token(client._token_identity(self.inventory), "old-fixture")
        with patch.object(client, "op_json", return_value=[{"value": "new-fixture"}]):
            self.assertEqual(
                client.api_token(self.inventory, refresh=True), "new-fixture"
            )
        contents = json.loads(self.cache.read_text())
        self.assertEqual(set(contents), {"identity", "token"})
        self.assertEqual(contents["identity"], self.inventory)

    def test_symlink_cache_is_refused_without_reading_1password_or_overwriting_target(
        self,
    ):
        self.cache.parent.mkdir()
        outside = self.cache.parent / "outside"
        outside.write_text("must stay unchanged")
        self.cache.symlink_to(outside)
        with patch.object(
            client, "op_json", side_effect=AssertionError("unexpected read")
        ):
            with self.assertRaises(OSError):
                client.api_token(self.inventory)
        self.assertEqual(outside.read_text(), "must stay unchanged")

    def test_repository_ignores_cache_directory(self):
        self.assertIn("/.cache", (client.ROOT / ".gitignore").read_text().splitlines())


if __name__ == "__main__":
    unittest.main()

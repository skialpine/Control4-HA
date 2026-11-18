"""Offline tests for the companion upgrade and read-only contract checks."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lab"))
from install_companion import DOMAIN, REVISION, VERSION, install, verify_catalog


class CompanionInstall(unittest.TestCase):
    def setUp(self):
        self.lab = MagicMock()
        self.portainer = MagicMock()
        self.inventory = {"container_id": "isolated-lab", "ha_version": "2026.11.1"}
        self.reply = {"version": "2026.11.1", "state": "RUNNING"}
        self.entry = [{"domain": DOMAIN, "entry_id": "retained-entry"}]
        self.contract = {"version": 1, "eligibility_version": 1}

    def upgrade(self):
        manifest = json.dumps({"domain": DOMAIN, "version": VERSION})
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("install_companion.Lab", return_value=self.lab),
            patch("install_companion.assert_container"),
            patch("install_companion.verify_catalog", return_value=self.contract),
            patch(
                "install_companion.subprocess.check_output",
                side_effect=[manifest, b"tar"],
            ),
        ):
            inventory_path = Path(directory) / "inventory.json"
            install(
                self.inventory,
                self.portainer,
                Path("helper"),
                inventory_path,
                token="test",
            )
            return json.loads(inventory_path.read_text())

    def test_existing_entry_is_preserved_without_starting_a_config_flow(self):
        self.lab.request.side_effect = [self.entry, self.reply, self.entry]
        updated = self.upgrade()
        self.assertEqual(updated["companion_revision"], REVISION)
        self.assertEqual(updated["companion_eligibility_version"], 1)
        self.assertEqual(
            [call.args[0] for call in self.lab.request.call_args_list],
            ["GET", "GET", "GET"],
        )
        self.assertEqual(
            [call.args[0] for call in self.portainer.call.call_args_list],
            ["GET", "PUT", "POST"],
        )

    def test_fresh_install_uses_the_normal_config_flow(self):
        self.lab.request.side_effect = [
            [],
            self.reply,
            [],
            {"type": "form", "flow_id": "new-entry-flow"},
            {"type": "create_entry"},
            self.entry,
        ]
        self.assertEqual(self.upgrade()["companion_revision"], REVISION)
        self.assertEqual(
            [call.args[0] for call in self.lab.request.call_args_list],
            ["GET", "GET", "GET", "POST", "POST", "GET"],
        )

    def test_dropped_entry_during_restart_is_never_recreated(self):
        self.lab.request.side_effect = [self.entry, self.reply, []]
        with self.assertRaisesRegex(RuntimeError, "config entry changed"):
            self.upgrade()
        self.assertEqual(
            [call.args[0] for call in self.lab.request.call_args_list],
            ["GET", "GET", "GET"],
        )

    def test_revision_confirmation_requires_the_same_eligibility_contract(self):
        cold = self.contract | {
            "revision": "a" * 64,
            "unchanged": False,
            "entities": [],
        }
        warm = self.contract | {"revision": "a" * 64, "unchanged": True}
        with patch(
            "install_companion.command",
            side_effect=[{"response": cold}, {"response": warm}],
        ):
            self.assertEqual(
                verify_catalog(self.lab, "test")["revision_confirmed"], True
            )
        warm.pop("eligibility_version")
        with (
            patch(
                "install_companion.command",
                side_effect=[{"response": cold}, {"response": warm}],
            ),
            self.assertRaisesRegex(RuntimeError, "eligibility version"),
        ):
            verify_catalog(self.lab, "test")

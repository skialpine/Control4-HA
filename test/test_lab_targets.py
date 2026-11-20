"""No live endpoints: prove target checks refuse before credentials or mutations."""

import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lab"))
from client import Lab, require_c4_target
from provision import (
    LABEL,
    NoRedirect,
    assert_container,
    assert_owned,
    provision,
    restored_archive,
    seed_archive,
)
import tarfile
import tempfile


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class Opener:
    def __init__(self, marker):
        self.marker = marker
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        if request.full_url.endswith("/local/control4-ha-lab.json"):
            return Response(json.dumps(self.marker).encode())
        return Response(b"{}")


class LabTargets(unittest.TestCase):
    def setUp(self):
        self.inventory = {
            "base_url": "http://lab.invalid:8124",
            "published_port": 8124,
            "lab_id": "project-owned-lab",
        }

    def test_missing_or_other_target_is_rejected_without_a_request(self):
        opener = Opener({})
        for patch in ({"lab_id": ""}, {"base_url": ""}, {"published_port": 8123}):
            with self.assertRaises(ValueError):
                Lab({**self.inventory, **patch}, opener=opener)
        with self.assertRaises(ValueError):
            Lab(
                self.inventory, base_url="http://production.invalid:8123", opener=opener
            )
        self.assertEqual(opener.requests, [])

    def test_foreign_or_production_marker_never_receives_a_token_or_write(self):
        for marker in (
            {"lab_id": "production", "purpose": "test-only"},
            {"lab_id": "project-owned-lab", "purpose": "production"},
            {},
        ):
            opener = Opener(marker)
            lab = Lab(self.inventory, opener=opener)
            with self.assertRaises(ValueError):
                lab.request(
                    "POST",
                    "/api/services/light/turn_on",
                    {"entity_id": "light.demo"},
                    token="test-secret",
                )
            self.assertEqual(len(opener.requests), 1)
            self.assertEqual(opener.requests[0].method, "GET")
            self.assertNotIn("Authorization", opener.requests[0].headers)

    def test_positive_identity_precedes_every_credentialed_operation(self):
        opener = Opener({"lab_id": "project-owned-lab", "purpose": "test-only"})
        lab = Lab(self.inventory, opener=opener)
        lab.request(
            "POST",
            "/api/services/switch/turn_off",
            {"entity_id": "switch.demo"},
            token="test-secret",
        )
        self.assertEqual([r.method for r in opener.requests], ["GET", "POST"])
        self.assertEqual(
            opener.requests[1].headers["Authorization"], "Bearer test-secret"
        )
        opener.marker = {"lab_id": "replacement", "purpose": "test-only"}
        with self.assertRaises(ValueError):
            lab.request(
                "POST", "/api/services/switch/turn_off", {}, token="test-secret"
            )
        self.assertEqual([r.method for r in opener.requests], ["GET", "POST", "GET"])

    def test_redirects_are_refused(self):
        with self.assertRaises(RuntimeError):
            NoRedirect().redirect_request(
                None, None, 302, "redirect", {}, "http://foreign.invalid/"
            )

    def test_native_c4_requires_explicit_approved_pair(self):
        inv = {
            "approved_c4_targets": [{"controller": "test-controller", "project": "lab"}]
        }
        for controller, project in (
            (None, "lab"),
            ("test-controller", None),
            ("production", "lab"),
            ("test-controller", "house"),
        ):
            with self.assertRaises(ValueError):
                require_c4_target(inv, controller, project)
        self.assertEqual(
            require_c4_target(inv, "test-controller", "lab"),
            inv["approved_c4_targets"][0],
        )

    def test_container_isolation_rejects_foreign_resources_and_mounts(self):
        inv = {
            "lab_id": "lab",
            "network": "lab-net",
            "volume": "lab-config",
            "memory_limit_bytes": 2147483648,
            "published_port": 8124,
        }
        container = {
            "Config": {
                "Labels": {
                    LABEL: "lab",
                    "com.centurylinklabs.watchtower.enable": "false",
                }
            },
            "HostConfig": {
                "NetworkMode": "lab-net",
                "Memory": 2147483648,
                "PortBindings": {"8123/tcp": [{"HostPort": "8124"}]},
            },
            "Mounts": [{"Name": "lab-config", "Destination": "/config"}],
        }
        assert_container(container, inv)
        for patch in (
            {"Privileged": True},
            {"NetworkMode": "host"},
            {"Devices": [{"PathOnHost": "/dev/ttyUSB0"}]},
            {"Binds": ["/var/run/docker.sock:/var/run/docker.sock"]},
        ):
            changed = copy.deepcopy(container)
            changed["HostConfig"].update(patch)
            with self.assertRaises(ValueError):
                assert_container(changed, inv)
        with self.assertRaises(ValueError):
            assert_owned({"Labels": {LABEL: "production"}}, inv)

    def test_only_a_lab_owned_seed_can_be_restored_to_a_new_volume(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "seed.tar"
            path.write_bytes(seed_archive(self.inventory))
            normalized = restored_archive(path, self.inventory)
            self.assertTrue(normalized)
            with self.assertRaises(ValueError):
                restored_archive(path, {**self.inventory, "lab_id": "another-lab"})

    def test_conflicting_seed_is_rejected_before_allocating_docker_resources(self):
        inventory = {
            **self.inventory,
            "container": "qualification",
            "volume": "qualification-config",
            "network": "lab-net",
            "ha_version": "2026.11.1",
        }

        def read_docker(method, path, **_):
            self.assertEqual(method, "GET", f"Attempted to write {path}")
            return {} if path == "/volumes" else []

        client = Mock(call=Mock(side_effect=read_docker))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backup = (
                root / ".cache/lab-backups/project-owned-lab-qualification-seed.tar"
            )
            backup.parent.mkdir(parents=True)
            backup.write_bytes(b"previous seed")
            with patch("provision.ROOT", root), patch(
                "provision.seed_archive", return_value=b"modified seed"
            ):
                with self.assertRaisesRegex(
                    ValueError, "Existing private seed archive differs"
                ):
                    provision(client, inventory, root / "inventory.json")
            self.assertEqual(backup.read_bytes(), b"previous seed")

    def test_recovery_rejects_path_traversal_and_links_without_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            for name, kind in (
                ("../outside", tarfile.REGTYPE),
                ("/absolute", tarfile.REGTYPE),
                ("link", tarfile.SYMTYPE),
            ):
                path = Path(directory) / "unsafe.tar"
                with tarfile.open(path, "w") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/outside"
                    archive.addfile(member)
                with self.assertRaises(ValueError):
                    restored_archive(path, self.inventory)


if __name__ == "__main__":
    unittest.main()

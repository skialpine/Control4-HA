import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from check_first_demo import compare, contract, digest, inventory_paths, match_evidence


def archive(path, model, version, interface, *, proxy="", actions=()):
    action_xml = "".join(f"<action><command>{key}</command><name>{key}</name></action>" for key in actions)
    xml = f"""
    <devicedata>
      <name>{model}</name><model>{model}</model><manufacturer>Example</manufacturer>
      <version>{version}</version><proxy>{proxy}</proxy>
      <config><script file="runtime.lua" />
      <properties>
        <property><name>HA Token</name><type>STRING</type><password>true</password></property>
        <property><name>Long Lived Access Token</name><type>STRING</type><password>true</password></property>
        <property><name>Mode</name><type>LIST</type><items><item>Manual</item></items></property>
      </properties>
      <commands><command><name>Call</name><params><param><name>Target</name><type>STRING</type></param></params></command></commands>
      <actions>{action_xml}</actions></config>{interface}
    </devicedata>
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(path, "w") as package:
        package.writestr("driver.xml", ET.tostring(ET.fromstring(xml)))
        package.writestr("runtime.lua", "-- Fixture")
    return digest(path.read_bytes())


def edge(identifier, kind, role, *classes):
    classes = "".join(
        f"<class><classname>{name}</classname></class>" for name in classes
    )
    return (
        f"<connection><id>{identifier}</id><type>{kind}</type><consumer>{role}</consumer>"
        f"<classes>{classes}</classes></connection>"
    )


def bindings(*edges):
    return "<connections>" + "".join(edges) + "</connections>"


class FirstDemoPackageTests(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.references = self.root / "references"
        self.pins = {"schema_version": 1, "companion": {}, "packages": []}
        self.candidates = {}
        for family, identifier, consumer in (
            ("coordinator", "1", "false"),
            ("light", "999", "true"),
        ):
            model = f"HA {family.title()}"
            filename = f"HA.{family.title()}.c4z"
            for origin, version in (("bp", "113"), ("prototype", "114")):
                self.pin(
                    origin,
                    family,
                    filename,
                    model,
                    version,
                    bindings(edge(identifier, "1", consumer, "HA_DEVICE")),
                )
            self.candidate(
                family,
                filename,
                model,
                "115",
                bindings(
                    edge(
                        identifier, "1", consumer, "HA_DEVICE", "SKIALPINE_HA_SUITE_V1"
                    )
                ),
            )
        for origin, version in (("bp", "106"), ("prototype", "107")):
            self.pin(
                origin,
                "switch",
                "HA.Switch.c4z",
                "HA Switch",
                version,
                bindings(edge("1", "1", "false", "RELAY")),
                proxy="other",
            )
        self.candidate(
            "switch",
            "Control4.HA.Switch.c4z",
            "Control4.HA.Switch",
            "115",
            bindings(
                edge("1", "1", "true", "SKIALPINE_HA_SUITE_V1"),
                edge("2", "1", "false", "RELAY"),
                edge("5001", "2", "false", "UIBUTTON"),
            )
            + '<proxies><proxy proxybindingid="5001">uibutton</proxy></proxies>',
        )

    def test_mixed_candidate_evidence_rejected_even_when_both_consumers_match(self):
        hashes = {"coordinator": "a" * 64, "light": "b" * 64, "switch": "c" * 64}
        candidates = {name: {"candidate": {"filename": name, "sha256": value, "identity": {"version": "17"}}} for name, value in hashes.items()}
        installed = {"packages": hashes, "verified_utc": "controller-run", "coordinator_revision": "17",
                     "setup": [{"filename": name, "revision": "17"} for name in ("light", "switch")]}
        rows = [{"family": name.title(), "sha256": hashes[name], "coordinator_sha256": hashes["coordinator"],
                 "checks_passed": 1} for name in ("light", "switch")]
        docker = {"families": rows, "verified_utc": "docker-run"}
        self.assertEqual(match_evidence(candidates, docker, installed)["checks"], {"Light": 1, "Switch": 1})
        current = {key: value for key, value in installed.items() if key != "packages"}
        current["package_hashes"] = hashes
        self.assertEqual(match_evidence(candidates, docker, current)["checks"], {"Light": 1, "Switch": 1})
        for changed in ({"setup": []}, {"setup": [installed["setup"][0], {"filename": "switch", "revision": "16"}]},
                        {"coordinator_revision": "16"}):
            with self.assertRaisesRegex(ValueError, "Installed"):
                match_evidence(candidates, docker, {**installed, **changed})
        rows[1]["coordinator_sha256"] = "d" * 64
        with self.assertRaisesRegex(ValueError, "Docker Switch"):
            match_evidence(candidates, docker, installed)
        with self.assertRaisesRegex(ValueError, "Installed driver"):
            match_evidence(candidates, docker, {**installed, "packages": {}})

    def test_revisioned_archive_version_stays_in_controller_integer_range(self):
        path = self.root / "revision.c4z"
        for value in ("20261118", "2026111801", "2026111802"):
            archive(path, "Example", value, "")
            self.assertEqual(contract(path)["identity"]["version"], value)
        archive(path, "Example", "2147483648", "")
        with self.assertRaisesRegex(ValueError, "unexpected driver version"):
            contract(path)

    def test_archive_inventory_records_declared_native_capabilities(self):
        path = self.root / "example.c4z"
        archive(
            path,
            "Example",
            "115",
            "<capabilities><dimmer>True</dimmer><brightness_rate_min>0</brightness_rate_min></capabilities>",
        )
        self.assertEqual(
            contract(path)["capabilities"], {"dimmer": "True", "brightness_rate_min": "0"}
        )

    def pin(self, origin, family, filename, model, version, interface, **kwargs):
        identifier = f"{origin}-{family}"
        sha = archive(
            self.references / identifier / filename, model, version, interface, **kwargs
        )
        self.pins["packages"].append(
            {
                "id": identifier,
                "family": family,
                "filename": filename,
                "version": version,
                "sha256": sha,
            }
        )

    def candidate(self, family, filename, model, version, interface):
        path = self.root / "c4z" / filename
        self.candidates[family] = (path, archive(path, model, version, interface))

    def compare(self):
        return compare(self.pins, self.references, self.candidates, None)

    def test_explicit_archives_must_share_one_revision(self):
        self.candidate(
            "coordinator",
            "HA.Coordinator.c4z",
            "HA Coordinator",
            "116",
            bindings(edge("1", "1", "false", "HA_DEVICE", "SKIALPINE_HA_SUITE_V1")),
        )
        with self.assertRaisesRegex(ValueError, "must share one revision"):
            self.compare()

    def test_additive_legacy_classes_and_deliberate_switch_migration(self):
        report = self.compare()
        self.assertEqual(report["archive_contract"], "passed")
        self.assertEqual(
            report["first_demo_readiness"], "requires_runtime_and_native_evidence"
        )
        self.assertEqual(len(report["comparisons"]), 6)
        for result in report["comparisons"]:
            if result["reference"]["family"] == "switch":
                self.assertEqual(result["path"], "explicit_migration")
                self.assertIn(
                    ("proxy", "migration_mapping_required"),
                    {
                        (finding["key"], finding["status"])
                        for finding in result["differences"]
                    },
                )
            else:
                self.assertEqual(result["differences"], [])

    def test_distinct_suite_binding_preserves_the_legacy_provider(self):
        self.candidate(
            "coordinator",
            "HA.Coordinator.c4z",
            "HA Coordinator",
            "115",
            bindings(
                edge("1", "1", "false", "HA_DEVICE"),
                edge("2", "1", "false", "SKIALPINE_HA_SUITE_V1"),
            ),
        )
        self.assertEqual(self.compare()["archive_contract"], "passed")

    def test_only_retired_prototype_visibility_actions_are_exempt(self):
        self.pins["packages"] = [
            item for item in self.pins["packages"] if item["id"] != "prototype-light"
        ]
        self.pin(
            "prototype", "light", "HA.Light.c4z", "HA Light", "114",
            bindings(edge("999", "1", "true", "HA_DEVICE")),
            actions=("ShowAdvancedProperties", "HideAdvancedProperties", "Refresh"),
        )
        report = self.compare()
        self.assertEqual(report["archive_contract"], "blocked")
        prototype = next(
            row for row in report["comparisons"] if row["reference"]["id"] == "prototype-light"
        )
        self.assertEqual(
            {row["key"]: row["status"] for row in prototype["differences"] if row["scope"] == "actions"},
            {
                "ShowAdvancedProperties": "applicable_properties_always_visible",
                "HideAdvancedProperties": "applicable_properties_always_visible",
                "Refresh": "gap",
            },
        )

    def test_loss_of_legacy_binding_event_and_protected_default_blocks(self):
        self.pins["packages"].pop(1)
        self.pin(
            "prototype",
            "coordinator",
            "HA.Coordinator.c4z",
            "HA Coordinator",
            "115",
            bindings(edge("1", "1", "false", "HA_DEVICE"))
            + "<events><event><id>2</id><name>Disconnected</name></event></events>",
        )
        self.candidate(
            "coordinator",
            "HA.Coordinator.c4z",
            "HA Coordinator",
            "115",
            bindings(edge("1", "1", "false", "SKIALPINE_HA_SUITE_V1"))
            + "<events><event><id>2</id><name>Connected</name></event></events>",
        )
        path, _ = self.candidates["coordinator"]
        with ZipFile(path) as package:
            members = {name: package.read(name) for name in package.namelist()}
        default = b"<default>secret-fixture</default>"
        members["driver.xml"] = members["driver.xml"].replace(
            b"<name>HA Token</name>", b"<name>HA Token</name>" + default
        )
        with ZipFile(path, "w") as package:
            for name, data in members.items():
                package.writestr(name, data)
        self.candidates["coordinator"] = (path, digest(path.read_bytes()))
        report = self.compare()
        self.assertEqual(report["archive_contract"], "blocked")
        self.assertTrue(
            any(
                "higher than 115" in item
                for item in report["candidates"]["coordinator"]["issues"]
            )
        )
        self.assertTrue(
            any(
                "HA Token" in item
                for item in report["candidates"]["coordinator"]["issues"]
            )
        )
        self.assertNotIn("secret-fixture", json.dumps(report))
        prototype = next(
            row
            for row in report["comparisons"]
            if row["reference"]["id"] == "prototype-coordinator"
        )
        self.assertEqual(
            {
                (item["scope"], item["key"])
                for item in prototype["differences"]
                if item["status"] == "gap"
            },
            {("binding", "1.HA_DEVICE"), ("events", "2")},
        )

    def test_inventory_uses_only_named_archives_and_checks_both_digests(self):
        inventory = self.root / "inventory.json"
        encoded = json.dumps(
            {
                "schema_version": 1,
                "version": "115",
                "packages": [
                    {"name": path.name, "sha256": sha}
                    for path, sha in self.candidates.values()
                ],
            }
        ).encode()
        inventory.write_bytes(encoded)
        receipt = inventory.with_suffix(".sha256")
        receipt.write_text(f"{digest(encoded)}  inventory.json\n")
        (inventory.parent / "c4z" / "unrelated.c4z").write_text("ignore")
        candidates, version = inventory_paths(inventory)
        self.assertEqual(candidates, self.candidates)
        self.assertEqual(
            compare(self.pins, self.references, candidates, version)[
                "archive_contract"
            ],
            "passed",
        )
        path, sha = candidates["switch"]
        path.write_bytes(path.read_bytes() + b"changed since the build")
        with self.assertRaisesRegex(ValueError, "differs from pinned"):
            contract(path, sha)
        inventory.write_bytes(encoded + b" ")
        with self.assertRaisesRegex(ValueError, "inventory SHA-256"):
            inventory_paths(inventory)

    def test_mutated_baseline_and_incomplete_reference_set_fail_closed(self):
        ref = next(row for row in self.pins["packages"] if row["id"] == "bp-light")
        path = self.references / ref["id"] / ref["filename"]
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "differs from pinned"):
            self.compare()
        self.pins["packages"].remove(ref)
        with self.assertRaisesRegex(ValueError, "all six baseline archives"):
            self.compare()


if __name__ == "__main__":
    unittest.main()

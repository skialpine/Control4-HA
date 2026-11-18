"""Compare exact built C4Z archives with the pinned first-demo baselines."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
from xml.etree import ElementTree as ET
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parents[1]
BASELINES = ROOT / "provenance/first-demo-baselines.json"
INVENTORY = ROOT / "dist/oss/inventory.json"
FAMILIES = ("coordinator", "light", "switch")
CANDIDATE_NAMES = {
    f"Control4.HA.{family.title()}.c4z": family for family in FAMILIES
} | {"HA.Coordinator.c4z": "coordinator", "HA.Light.c4z": "light"}
SUITE_CLASS = "SKIALPINE_HA_SUITE_V1"
SHA256 = re.compile(r"[0-9a-f]{64}")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def xml_text(node, field, default=""):
    return (node.findtext(field) or default).strip()


def entries(xml, path, key, project):
    result = {}
    for node in xml.findall(path):
        identity = key(node)
        if not identity or identity in result:
            raise ValueError(f"missing or duplicate {path} identifier {identity!r}")
        result[identity] = project(node)
    return result


def properties(xml):
    return entries(
        xml,
        "config/properties/property",
        lambda item: xml_text(item, "name"),
        lambda item: {
            "type": xml_text(item, "type"),
            "readonly": xml_text(item, "readonly", "false").lower(),
            "password": xml_text(item, "password", "false").lower(),
            # Only record whether a default is filled in. A package can carry
            # a sensitive default, and packed defaults never prove saved values.
            "has_default": bool(xml_text(item, "default")),
            "options": [value.text or "" for value in item.findall("items/item")],
        },
    )


def connection(item):
    details = {key: xml_text(item, key) for key in ("type", "facing")}
    for key in ("consumer", "audiosource", "videosource", "linelevel"):
        value = xml_text(item, key).lower()
        if value:
            details[key] = value
    return {
        **details,
        "name": xml_text(item, "connectionname"),
        "classes": entries(
            item,
            "classes/class",
            lambda cls: xml_text(cls, "classname"),
            lambda cls: xml_text(cls, "autobind", "false").lower(),
        ),
    }


def commands(xml):
    return entries(
        xml,
        "config/commands/command",
        lambda command: xml_text(command, "name"),
        lambda command: [
            {key: xml_text(param, key) for key in ("name", "type", "variabletype")}
            for param in command.findall("params/param")
        ],
    )


def contract(path, expected_hash=None, expected_version=None):
    raw = path.read_bytes()
    sha256 = digest(raw)
    if expected_hash is not None and sha256 != expected_hash:
        raise ValueError(
            f"{path}: SHA-256 {sha256} differs from pinned {expected_hash}"
        )
    with ZipFile(io.BytesIO(raw)) as archive:
        members = archive.namelist()
        if members.count("driver.xml") != 1 or len(members) != len(set(members)):
            raise ValueError(f"{path}: missing driver.xml or duplicate archive members")
        xml = ET.fromstring(archive.read("driver.xml"))
        script = xml.find("config/script")
        entrypoint = script.get("file") if script is not None else None
        if (
            xml.tag != "devicedata"
            or not entrypoint
            or entrypoint not in members
            or archive.getinfo(entrypoint).file_size == 0
        ):
            raise ValueError(f"{path}: missing declared runtime entry point")
    identity = {
        field: xml_text(xml, field)
        for field in (
            "name",
            "model",
            "manufacturer",
            "version",
            "minimum_os_version",
            "control",
            "controlmethod",
            "driver",
            "combo",
            "proxy",
        )
    }
    version = identity["version"]
    if (
        not re.fullmatch(r"[0-9]{1,10}", version)
        or int(version) > 2147483647
        or (expected_version is not None and version != expected_version)
    ):
        raise ValueError(f"{path}: unexpected driver version {version!r}")
    return {
        "filename": path.name,
        "sha256": sha256,
        "entrypoint": entrypoint,
        "identity": identity,
        "proxies": entries(
            xml,
            "proxies/proxy",
            lambda item: item.get("proxybindingid"),
            lambda item: (item.text or "").strip().lower(),
        ),
        "bindings": entries(
            xml, "connections/connection", lambda item: xml_text(item, "id"), connection
        ),
        "properties": properties(xml),
        "commands": commands(xml),
        "actions": entries(
            xml,
            "config/actions/action",
            lambda item: xml_text(item, "command"),
            lambda item: xml_text(item, "name"),
        ),
        **{
            section: entries(
                xml,
                f"{section}/{element}",
                lambda item: xml_text(item, "id"),
                lambda item: xml_text(item, "name"),
            )
            for section, element in (
                ("events", "event"),
                ("conditionals", "conditional"),
                ("variables", "variable"),
            )
        },
    }


def differences(baseline, candidate):
    report = []

    def note(scope, key, expected, actual, status="gap"):
        if actual != expected:
            report.append(
                {
                    "scope": scope,
                    "key": key,
                    "baseline": expected,
                    "candidate": actual,
                    "status": status,
                }
            )

    note("identity", "filename", baseline["filename"], candidate["filename"])
    old_id, new_id = baseline["identity"], candidate["identity"]
    for key in ("model", "control", "controlmethod", "driver", "combo", "proxy"):
        if old_id[key]:
            note("identity", key, old_id[key], new_id[key])
    for key in ("name", "manufacturer", "minimum_os_version"):
        note("identity", key, old_id[key], new_id[key], "native_review")
    for scope in (
        "proxies",
        "commands",
        "actions",
        "events",
        "conditionals",
        "variables",
    ):
        for key, expected in baseline[scope].items():
            actual = candidate[scope].get(key)
            note(
                scope,
                key,
                expected,
                actual,
                "native_review" if scope == "actions" and actual else "gap",
            )
    for key, expected in baseline["bindings"].items():
        actual = candidate["bindings"].get(key)
        if actual is None:
            note("binding", key, expected, None)
            continue
        for field, value in expected.items():
            if field not in ("classes", "name"):
                note("binding", f"{key}.{field}", value, actual.get(field))
        note(
            "binding", f"{key}.name", expected["name"], actual["name"], "native_review"
        )
        for cls, autobind in expected["classes"].items():
            note("binding", f"{key}.{cls}", autobind, actual["classes"].get(cls))
    for key, expected in baseline["properties"].items():
        actual = candidate["properties"].get(key)
        if actual is None:
            note("property", key, expected, None)
            continue
        for field in ("type", "readonly"):
            note("property", f"{key}.{field}", expected[field], actual[field])
        if expected["password"] == "true":
            note("property", f"{key}.password", "true", actual["password"])
        missing = [
            item for item in expected["options"] if item not in actual["options"]
        ]
        if missing:
            note("property", f"{key}.options", expected["options"], actual["options"])
        note(
            "property",
            f"{key}.has_default",
            expected["has_default"],
            actual["has_default"],
            "native_review",
        )
    return report


def enforce(family, candidate, references):
    issues = []
    newest = max(int(item["version"]) for item in references)
    if int(candidate["identity"]["version"]) <= newest:
        issues.append(f"Version must be higher than {newest} for {family}")
    if family == "switch":
        if (
            candidate["filename"] != "Control4.HA.Switch.c4z"
            or candidate["identity"]["model"] != "Control4.HA.Switch"
        ):
            issues.append(
                "Switch migration target must be Control4.HA.Switch.c4z / Control4.HA.Switch"
            )
        if candidate["proxies"].get("5001") != "uibutton":
            issues.append("Switch migration target must expose uibutton on proxy 5001")
        for identifier, name, kind, role in (
            ("1", SUITE_CLASS, "1", "true"),
            ("2", "RELAY", "1", "false"),
            ("5001", "UIBUTTON", "2", "false"),
        ):
            edge = candidate["bindings"].get(identifier, {})
            if (
                edge.get("type") != kind
                or edge.get("consumer") != role
                or name not in edge.get("classes", {})
            ):
                issues.append(
                    f"Switch migration target must declare {name} on binding {identifier}"
                )
        return issues
    direction = "false" if family == "coordinator" else "true"
    if not any(
        edge.get("type") == "1"
        and edge.get("consumer") == direction
        and SUITE_CLASS in edge.get("classes", {})
        for edge in candidate["bindings"].values()
    ):
        issues.append(f"{family.title()} is missing its {SUITE_CLASS} connection")
    if family == "coordinator":
        for key in ("Long Lived Access Token", "HA Token"):
            if key == "HA Token" and key not in candidate["properties"]:
                continue
            property_config = candidate["properties"].get(key, {})
            if property_config.get("password") != "true" or property_config.get(
                "has_default"
            ):
                issues.append(
                    f"Coordinator {key} must be password-protected with a blank default"
                )
    return issues


def inventory_paths(inventory):
    data = inventory.read_bytes()
    recorded = inventory.with_suffix(".sha256").read_text().split()
    if recorded != [digest(data), inventory.name]:
        raise ValueError(f"{inventory}: build inventory SHA-256 does not match")
    decoded = json.loads(data)
    if decoded.get("schema_version") != 1:
        raise ValueError(f"{inventory}: unsupported build inventory")
    candidates = {}
    for item in decoded["packages"]:
        name, sha256 = item["name"], item["sha256"]
        family = CANDIDATE_NAMES.get(name)
        if not family or family in candidates or not SHA256.fullmatch(sha256):
            raise ValueError(
                f"{inventory}: unknown, duplicate or unpinned package {name!r}"
            )
        candidates[family] = (inventory.parent / "c4z" / name, sha256)
    if set(candidates) != set(FAMILIES):
        raise ValueError(
            f"{inventory}: expected one candidate for each of {', '.join(FAMILIES)}"
        )
    return candidates, decoded["version"]


def compare(pins, baseline_directory, candidates, expected_version):
    expected = {
        (f"{source}-{family}", family)
        for source in ("bp", "prototype")
        for family in FAMILIES
    }
    references = pins["packages"]
    if (
        pins.get("schema_version") != 1
        or len(references) != len(expected)
        or {(item["id"], item["family"]) for item in references} != expected
        or not all(SHA256.fullmatch(item["sha256"]) for item in references)
    ):
        raise ValueError("expected exact SHA-256 pins for all six baseline archives")
    candidate_contracts = {
        family: contract(path, sha256, expected_version)
        for family, (path, sha256) in candidates.items()
    }
    comparisons = []
    families = {}
    for family in FAMILIES:
        family_references = [item for item in references if item["family"] == family]
        candidate = candidate_contracts[family]
        family_issues = enforce(family, candidate, family_references)
        families[family] = {"candidate": candidate, "issues": family_issues}
        for reference in family_references:
            path = (
                baseline_directory / reference["id"] / reference["filename"]
                if baseline_directory is not None
                else ROOT / reference["local_path"]
            )
            baseline = contract(path, reference["sha256"], reference["version"])
            drift = differences(baseline, candidate)
            for finding in drift:
                if (
                    reference["id"] in ("prototype-light", "prototype-switch")
                    and finding["scope"] == "actions"
                    and finding["key"]
                    in ("ShowAdvancedProperties", "HideAdvancedProperties")
                    and finding["candidate"] is None
                ):
                    finding["status"] = "applicable_properties_always_visible"
                elif family == "switch" and finding["status"] == "gap":
                    finding["status"] = "migration_mapping_required"
            comparisons.append(
                {
                    "reference": {
                        key: value
                        for key, value in reference.items()
                        if key != "local_path"
                    },
                    "baseline": baseline,
                    "path": "explicit_migration" if family == "switch" else "in_place",
                    "differences": drift,
                }
            )
    blocked = any(item["issues"] for item in families.values()) or any(
        finding["status"] == "gap"
        for result in comparisons
        for finding in result["differences"]
    )
    return {
        "schema_version": 1,
        "archive_contract": "blocked" if blocked else "passed",
        "first_demo_readiness": "requires_runtime_and_native_evidence",
        "companion_source_pin": pins["companion"],
        "candidates": families,
        "comparisons": comparisons,
    }


def match_evidence(candidates, family_run, installed):
    """Require Docker and Director receipts to describe the archives being compared."""
    hashes = {family: row["candidate"]["sha256"] for family, row in candidates.items()}
    files = {
        row["candidate"]["filename"]: row["candidate"]["sha256"]
        for row in candidates.values()
    }
    if installed.get("package_hashes", installed.get("packages")) != files:
        raise ValueError("Installed driver receipt belongs to a different package set")
    if (
        installed["coordinator_revision"]
        != candidates["coordinator"]["candidate"]["identity"]["version"]
    ):
        raise ValueError("Installed Coordinator revision differs from the candidate")
    consumers = [candidates[name]["candidate"] for name in ("light", "switch")]
    expected = {(item["filename"], item["identity"]["version"]) for item in consumers}
    observed = installed["setup"]
    if (
        len(observed) != 2
        or {(item["filename"], item["revision"]) for item in observed} != expected
    ):
        raise ValueError(
            "Installed Light or Switch readback is missing or belongs to another revision"
        )
    rows = family_run["families"]
    if len(rows) != 2 or {row["family"] for row in rows} != {"Light", "Switch"}:
        raise ValueError("Docker receipt must include both Light and Switch")
    for row in rows:
        if (
            row["sha256"] != hashes[row["family"].lower()]
            or row["coordinator_sha256"] != hashes["coordinator"]
        ):
            raise ValueError(
                f"Docker {row['family']} receipt belongs to a different package set"
            )
    return {
        "docker_verified_utc": family_run["verified_utc"],
        "controller_verified_utc": installed["verified_utc"],
        "checks": {row["family"]: row["checks_passed"] for row in rows},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=INVENTORY)
    parser.add_argument(
        "--baseline-dir",
        type=Path,
        help="Private directory of pinned <reference-id>/<filename> archives",
    )
    parser.add_argument("--version", help="Expected candidate driver XML version")
    for family in FAMILIES:
        parser.add_argument(
            f"--{family}", type=Path, help=f"Explicit {family} candidate file"
        )
    parser.add_argument(
        "--match-evidence",
        action="store_true",
        help="Check that recorded Docker and controller runs used these exact archives",
    )
    parser.add_argument(
        "--controller-receipt",
        type=Path,
        default=ROOT / "lab/installed-setup-readback.json",
    )
    parser.add_argument(
        "--docker-receipt",
        type=Path,
        action="append",
        help="Docker receipt to match, repeat for each run",
    )
    args = parser.parse_args()
    overrides = {
        family: getattr(args, family) for family in FAMILIES if getattr(args, family)
    }
    if overrides and set(overrides) != set(FAMILIES):
        parser.error(
            "provide all three explicit candidate paths or use the built inventory"
        )
    try:
        if overrides:
            candidates = {family: (path, None) for family, path in overrides.items()}
            version = args.version
        else:
            candidates, version = inventory_paths(args.inventory)
            if args.version and version != args.version:
                raise ValueError(
                    f"Inventory version {version!r} differs from expected {args.version!r}"
                )
        pins = json.loads(BASELINES.read_text())
        result = compare(pins, args.baseline_dir, candidates, version)
        if args.match_evidence:
            installed = json.loads(args.controller_receipt.read_text())
            receipts = args.docker_receipt or [
                ROOT / "lab" / filename
                for filename in (
                    "family-evidence.json",
                    "picker-round-trip-evidence.json",
                )
            ]
            result["matched_evidence"] = {
                str(path): match_evidence(
                    result["candidates"], json.loads(path.read_text()), installed
                )
                for path in receipts
            }
    except (BadZipFile, ET.ParseError, KeyError, OSError, ValueError) as error:
        parser.exit(2, f"First-demo inputs unavailable or invalid: {error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result["archive_contract"] == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())

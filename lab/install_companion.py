"""Install the independently versioned companion pin only on the verified lab."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import time

from client import Lab, api_token, command, load_inventory
from provision import Portainer, ROOT, assert_container

REVISION = "47690472bbca38de320056f9c368e677e8ff42f7"
VERSION = "0.1.3"
DOMAIN = "ha_gesture_bridge"
COMPONENT = "custom_components/" + DOMAIN


def companion_entry(lab, token):
    entries = lab.request(
        "GET", "/api/config/config_entries/entry?domain=" + DOMAIN, token=token
    )
    if not isinstance(entries, list) or len(entries) > 1:
        raise RuntimeError("Expected at most one lab companion config entry")
    if not entries:
        return None
    entry = entries[0]
    if (
        not isinstance(entry, dict)
        or entry.get("domain") != DOMAIN
        or not isinstance(entry.get("entry_id"), str)
        or not entry["entry_id"]
    ):
        raise RuntimeError("Lab companion config entry identity could not be verified")
    return entry["entry_id"]


def verify_catalog(lab, token):
    def request(socket, ident, data):
        result = command(
            socket,
            {
                "id": ident,
                "type": "call_service",
                "domain": DOMAIN,
                "service": "get_devices",
                "service_data": data,
                "return_response": True,
            },
        )
        catalog = result.get("response") if isinstance(result, dict) else None
        if (
            not isinstance(catalog, dict)
            or type(catalog.get("version")) is not int
            or catalog["version"] != 1
            or type(catalog.get("eligibility_version")) is not int
            or catalog["eligibility_version"] != 1
        ):
            raise RuntimeError(
                "Installed companion did not expose picker eligibility version 1"
            )
        return catalog

    with lab.websocket(token) as socket:
        cold = request(socket, 1, {"page": 1})
        revision = cold.get("revision")
        if (
            not isinstance(revision, str)
            or re.fullmatch(r"[a-f0-9]{64}", revision) is None
            or cold.get("unchanged") is not False
            or not isinstance(cold.get("entities"), list)
        ):
            raise RuntimeError("Companion cold catalog response is invalid")
        confirmed = request(socket, 2, {"page": 1, "revision": revision})
        if (
            confirmed.get("revision") != revision
            or confirmed.get("unchanged") is not True
            or "entities" in confirmed
        ):
            raise RuntimeError(
                "Companion did not confirm its unchanged catalog revision"
            )
    return {
        "version": 1,
        "eligibility_version": 1,
        "cold": True,
        "revision_confirmed": True,
    }


def install(
    inventory, portainer, source, inventory_path=ROOT / "lab/inventory.json", token=None
):
    inspected = portainer.call(
        "GET", "/containers/" + inventory["container_id"] + "/json"
    )
    assert_container(inspected, inventory)
    lab = Lab(inventory)
    lab.verify()
    token = token or api_token(inventory)
    manifest = json.loads(
        subprocess.check_output(
            [
                "git",
                "-C",
                str(source),
                "show",
                REVISION + ":" + COMPONENT + "/manifest.json",
            ]
        )
    )
    if manifest["version"] != VERSION or manifest["domain"] != DOMAIN:
        raise ValueError("Companion pin does not match its reviewed version")
    existing = companion_entry(lab, token)
    if inventory.get("companion_revision") != REVISION:
        archive = subprocess.check_output(
            ["git", "-C", str(source), "archive", "--format=tar", REVISION, COMPONENT]
        )
        portainer.call(
            "PUT",
            "/containers/" + inventory["container_id"] + "/archive?path=/config",
            archive,
            raw=True,
        )
        # Restart the verified lab after updating only the integration files.
        portainer.call(
            "POST",
            "/containers/" + inventory["container_id"] + "/restart?t=60",
            raw=True,
            timeout=75,
        )
        for _ in range(60):
            try:
                config = lab.request("GET", "/api/config", token=token)
                if (
                    config.get("version") == inventory["ha_version"]
                    and config.get("state") == "RUNNING"
                ):
                    break
            except (OSError, ValueError, RuntimeError):
                pass
            time.sleep(1)
        else:
            raise RuntimeError(
                "Companion install restarted the lab but it has not become ready"
            )
        if existing != companion_entry(lab, token):
            raise RuntimeError("Lab companion config entry changed during restart")
    if existing is None:
        flow = lab.request(
            "POST",
            "/api/config/config_entries/flow",
            {"handler": DOMAIN, "show_advanced_options": False},
            token=token,
        )
        if flow.get("type") == "form":
            flow = lab.request(
                "POST",
                "/api/config/config_entries/flow/" + flow["flow_id"],
                {"import_yaml": False},
                token=token,
            )
        if (
            flow.get("type") != "create_entry"
            and flow.get("reason") != "single_instance_allowed"
        ):
            raise RuntimeError("Companion configuration flow did not finish")
        if companion_entry(lab, token) is None:
            raise RuntimeError(
                "Companion configuration flow did not persist a config entry"
            )
    contract = verify_catalog(lab, token)
    inventory["companion_revision"] = REVISION
    inventory["companion_version"] = manifest["version"]
    inventory["companion_catalog_version"] = contract["version"]
    inventory["companion_eligibility_version"] = contract["eligibility_version"]
    inventory["companion_gesture_contract"] = "1.0"
    inventory_path.write_text(json.dumps(inventory, indent=2) + "\n")
    print(
        "Separate companion pin installed and catalog contract verified:",
        manifest["version"],
        REVISION,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portainer-config", type=Path, required=True)
    parser.add_argument("--source-repo", type=Path, required=True)
    args = parser.parse_args()
    inventory = load_inventory()
    install(inventory, Portainer(args.portainer_config, inventory), args.source_repo)


if __name__ == "__main__":
    main()

"""Qualify fresh Home Assistant Demo seeds using disposable local containers."""

import argparse
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

from client import Lab, ROOT, command
from verify_endpoint_scopes import SCOPES, template

VERSIONS = ("2026.11.1", "2026.11.2")
CONTACT = "binary_sensor.lab_reset_contact"
TEMPERATURE = "sensor.lab_reset_temperature"


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def start_session(lab):
    deadline = time.monotonic() + 120
    while True:
        try:
            lab.verify()
            break
        except (OSError, RuntimeError):
            if time.monotonic() >= deadline:
                raise RuntimeError("The disposable HA instance did not start") from None
            time.sleep(1)
    client_id = lab.url + "/"
    code = lab.request(
        "POST",
        "/api/onboarding/users",
        {
            "name": "Demo Reset Lab",
            "username": "demo_reset_lab",
            "password": secrets.token_urlsafe(32),
            "client_id": client_id,
            "language": "en",
        },
    )["auth_code"]
    return lab.request(
        "POST",
        "/auth/token",
        {"grant_type": "authorization_code", "code": code, "client_id": client_id},
        form=True,
    )["access_token"]


def catalog(lab, token, projections):
    demo = set(
        lab.request(
            "POST",
            "/api/template",
            {"template": "{{ integration_entities('demo') | to_json }}"},
            token,
        )
    )
    eligible = {}
    for family, projection in projections.items():
        page = lab.request("POST", "/api/template", {"template": projection}, token)
        wanted = SCOPES[family] + "."
        if any(not entity.startswith(wanted) for entity in page["ids"]):
            raise ValueError(f"Catalog returned another domain for {family}")
        eligible[family] = sorted(
            row["entity_id"]
            for row in page["rows"]
            if row["entity_id"] in demo
            and row["available"]
            and not row["c4_exported"]
            and not row["device_disabled"]
        )
        if not eligible[family]:
            raise ValueError(f"No eligible Demo entities for {family}")
    if set(eligible["blinds"]) & set(eligible["garage"]):
        raise ValueError("Blinds and garage doors have overlapping catalogs")
    return eligible


def exercise(lab, token, eligible):
    states = {
        row["entity_id"]: row for row in lab.request("GET", "/api/states", token=token)
    }

    def choose(family, condition):
        for entity in eligible[family]:
            if entity in states and condition(states[entity]):
                return entity
        raise ValueError(f"Demo has no usable fixture for {family}")

    fan = choose("fan", lambda row: row["state"] in {"on", "off"})
    shade = choose(
        "blinds", lambda row: row["attributes"].get("current_position") is not None
    )
    door = choose("garage", lambda row: row["state"] in {"open", "closed"})
    thermostat = choose(
        "climate",
        lambda row: "off" in row["attributes"].get("hvac_modes", [])
        and row["state"] != "off",
    )
    lock = choose("lock", lambda row: row["state"] == "locked")
    panel = choose("alarm_control_panel", lambda row: row["state"] == "disarmed")
    player = choose(
        "media_player",
        lambda row: row["state"] == "playing"
        and row["attributes"].get("supported_features", 0) & 1,
    )
    position = 30 if states[shade]["attributes"]["current_position"] != 30 else 60
    fan_action, fan_state = (
        ("turn_on", "on") if states[fan]["state"] == "off" else ("turn_off", "off")
    )
    door_action, door_state = (
        ("open_cover", "open")
        if states[door]["state"] == "closed"
        else ("close_cover", "closed")
    )
    trials = (
        (
            "input_boolean",
            "turn_on",
            "input_boolean.lab_reset_contact",
            {},
            CONTACT,
            "state",
            "on",
        ),
        (
            "input_number",
            "set_value",
            "input_number.lab_reset_temperature",
            {"value": 0},
            TEMPERATURE,
            "state",
            0,
        ),
        ("fan", fan_action, fan, {}, fan, "state", fan_state),
        (
            "cover",
            "set_cover_position",
            shade,
            {"position": position},
            shade,
            "current_position",
            position,
        ),
        ("cover", door_action, door, {}, door, "state", door_state),
        (
            "climate",
            "set_hvac_mode",
            thermostat,
            {"hvac_mode": "off"},
            thermostat,
            "state",
            "off",
        ),
        (
            "select",
            "select_option",
            "select.lab_reset_comfort_mode",
            {"option": "Away"},
            "select.lab_reset_comfort_mode",
            "state",
            "Away",
        ),
        (
            "button",
            "press",
            "button.lab_reset_clear_hold",
            {},
            "input_boolean.lab_reset_hold",
            "state",
            "off",
        ),
        ("lock", "unlock", lock, {}, lock, "state", "unlocked"),
        # The built-in Demo panel uses this synthetic PIN.
        (
            "alarm_control_panel",
            "alarm_arm_home",
            panel,
            {"code": "1234"},
            panel,
            "state",
            "armed_home",
        ),
        ("media_player", "media_pause", player, {}, player, "state", "paused"),
    )

    def read(row, key):
        if row["entity_id"] == TEMPERATURE:
            return float(row["state"])
        return row["state"] if key == "state" else row["attributes"].get(key)

    baseline = {}
    with lab.websocket(token) as ws:
        command(
            ws, {"id": 1, "type": "subscribe_events", "event_type": "state_changed"}
        )
        for domain, service, target, params, entity, key, expected in trials:
            baseline[entity] = read(states[entity], key)
            if baseline[entity] == expected:
                raise ValueError(f"The {domain} seed already has the requested value")
            lab.request(
                "POST",
                f"/api/services/{domain}/{service}",
                {"entity_id": target, **params},
                token,
            )
            deadline = time.monotonic() + 15
            matched = False
            while (remaining := deadline - time.monotonic()) > 0:
                try:
                    event = (
                        json.loads(ws.recv(timeout=remaining))
                        .get("event", {})
                        .get("data", {})
                    )
                except TimeoutError:
                    break
                changed = event.get("new_state")
                if (
                    event.get("entity_id") == entity
                    and changed
                    and read(changed, key) == expected
                ):
                    matched = True
                    break
            if not matched:
                raise RuntimeError(f"No matching state event for {domain}.{service}")
            confirmed = lab.request("GET", f"/api/states/{entity}", token=token)
            if read(confirmed, key) != expected:
                raise RuntimeError(f"State readback differed for {domain}.{service}")
    climate = lab.request("GET", f"/api/states/{thermostat}", token=token)
    if climate["state"] != "off":
        raise RuntimeError("The explicit helper actions changed the primary thermostat mode")
    return baseline


def fresh_seed(context, image, version, projections):
    lab_id = secrets.token_hex(8)
    seed = ROOT / "lab/seed"
    with tempfile.TemporaryDirectory(
        prefix="demo-reset-", dir=ROOT / ".cache"
    ) as scratch:
        config = Path(scratch)
        (config / "www").mkdir()
        (config / "configuration.yaml").write_text(
            (seed / "configuration.yaml").read_text()
            + "\n"
            + (seed / "demo-reset.yaml").read_text()
        )
        (config / "www/control4-ha-lab.json").write_text(
            json.dumps({"lab_id": lab_id, "purpose": "test-only"})
        )
        container = docker(
            "--context",
            context,
            "run",
            "--detach",
            "--rm",
            "--pull",
            "never",
            "--label",
            "control4-ha.demo-reset=" + lab_id,
            "--cpus",
            "1",
            "--memory",
            "1536m",
            "--publish",
            "127.0.0.1::8123",
            "--mount",
            f"type=bind,source={config},target=/config",
            image,
        )
        try:
            binding = docker("--context", context, "port", container, "8123/tcp")
            host, port = binding.rsplit(":", 1)
            if host != "127.0.0.1":
                raise ValueError("The Demo rehearsal must bind only to loopback")
            inventory = {
                "lab_id": lab_id,
                "base_url": f"http://{host}:{port}",
                "published_port": int(port),
                "ha_version": version,
            }
            lab = Lab(inventory)
            token = start_session(lab)
            deadline = time.monotonic() + 90
            while True:
                info = lab.request("GET", "/api/config", token=token)
                if info["version"] != version:
                    raise ValueError("Unexpected Home Assistant version")
                if info.get("state") == "RUNNING" and {"demo", "template"} <= set(
                    info.get("components", [])
                ):
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        "Home Assistant did not finish loading Demo and template fixtures"
                    )
                time.sleep(1)
            eligible = catalog(lab, token, projections)
            return eligible, exercise(lab, token, eligible)
        finally:
            docker("--context", context, "stop", "--time", "10", container)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="append", choices=VERSIONS)
    args = parser.parse_args()
    context = docker("context", "show")
    host = docker(
        "context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"
    )
    if not host.startswith("unix://"):
        raise ValueError("Use a local Docker context")
    (ROOT / ".cache").mkdir(exist_ok=True)
    projections = {family: template(family) for family in SCOPES}
    for version in args.version or VERSIONS:
        image = f"ghcr.io/home-assistant/home-assistant:{version}"
        digest = docker(
            "--context",
            context,
            "image",
            "inspect",
            image,
            "--format",
            "{{index .RepoDigests 0}}",
        )
        first = fresh_seed(context, digest, version, projections)
        second = fresh_seed(context, digest, version, projections)
        if first != second:
            raise RuntimeError(
                f"Recreating HA {version} changed its eligible fixtures or initial readings"
            )
        counts = ", ".join(
            f"{family}={len(entities)}" for family, entities in first[0].items()
        )
        print(
            f"HA {version}: two fresh seeds, {len(first[1])} confirmed transitions per seed. {counts}",
            flush=True,
        )
        print(digest, flush=True)


if __name__ == "__main__":
    main()

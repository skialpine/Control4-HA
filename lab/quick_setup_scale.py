"""Add or remove bounded synthetic states in the verified HA qualification lab."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import re
import secrets

from client import Lab, ROOT, api_token, load_inventory

RECEIPT = ROOT / ".cache/ha-quick-setup-scale.json"
MARKER = "control4_qualification_fixture"
EXAMPLES = (
    ("light", "off", {"supported_color_modes": ["onoff"]}),
    ("fan", "off", {"supported_features": 1, "percentage": 0}),
    ("sensor", "18", {"device_class": "temperature", "unit_of_measurement": "°C"}),
    ("cover", "closed", {"device_class": "shade", "supported_features": 15}),
    ("cover", "closed", {"device_class": "garage", "supported_features": 3}),
    ("climate", "heat", {"hvac_modes": ["off", "heat"], "supported_features": 1}),
)


def owned_states(lab, token, marker):
    if not re.fullmatch(r"[0-9a-f]{12}", marker):
        raise ValueError("The scale receipt has an invalid marker")
    return lab.request(
        "POST",
        "/api/template",
        {
            "template": (
                "{% set result = namespace(ids=[]) %}"
                "{% for item in states if item.entity_id.split('.')[1].startswith('c4_scale_"
                + marker
                + "_') "
                "and item.attributes.get('" + MARKER + "') == '" + marker + "' %}"
                "{% set result.ids = result.ids + [item.entity_id] %}"
                "{% endfor %}{{ result.ids | to_json }}"
            )
        },
        token,
    )


def fixtures(count, marker):
    for index in range(count):
        domain, state, details = EXAMPLES[index % len(EXAMPLES)]
        entity = f"{domain}.c4_scale_{marker}_{index:03d}"
        yield entity, {
            "state": state,
            "attributes": {
                **details,
                MARKER: marker,
                "friendly_name": f"Qualification {domain} {index:03d}",
            },
        }


def remove(lab, token, marker):
    owned = owned_states(lab, token, marker)
    lab.verify()
    with ThreadPoolExecutor(max_workers=12) as pool:
        list(
            pool.map(
                lambda entity: lab._request(
                    "DELETE", "/api/states/" + entity, token=token
                ),
                owned,
            )
        )
    if owned_states(lab, token, marker):
        raise RuntimeError("Some synthetic states still need cleanup")
    RECEIPT.unlink()
    print(f"Removed {len(owned)} synthetic lab states")


def add(lab, token, count):
    marker = secrets.token_hex(6)
    RECEIPT.parent.mkdir(exist_ok=True)
    with RECEIPT.open("x", encoding="utf-8") as stream:
        json.dump({"lab": lab.inventory["lab_id"], "marker": marker}, stream)
    rows = dict(fixtures(count, marker))
    try:
        lab.verify()
        with ThreadPoolExecutor(max_workers=12) as pool:
            list(
                pool.map(
                    lambda entity: lab._request(
                        "POST", "/api/states/" + entity, rows[entity], token
                    ),
                    rows,
                )
            )
        if set(owned_states(lab, token, marker)) != set(rows):
            raise RuntimeError("The lab did not confirm the whole synthetic cohort")
    except Exception:
        remove(lab, token, marker)
        raise
    print(f"Confirmed {count} synthetic states across six Quick Setup scopes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("add", "remove"))
    parser.add_argument("--count", type=int, choices=(50, 250, 500), default=250)
    args = parser.parse_args()
    inventory = load_inventory()
    lab, token = Lab(inventory), api_token(inventory)
    if args.action == "add":
        add(lab, token, args.count)
    else:
        saved = json.loads(RECEIPT.read_text())
        if saved["lab"] != inventory["lab_id"]:
            raise ValueError("The scale receipt belongs to a different lab")
        remove(lab, token, saved["marker"])


if __name__ == "__main__":
    main()

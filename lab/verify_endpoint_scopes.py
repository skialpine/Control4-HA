"""Check the production catalog templates against the allowlisted Home Assistant lab."""

import argparse
from collections import Counter
import os
from statistics import median
import subprocess
from time import perf_counter_ns

from client import Lab, ROOT, api_token, load_inventory

SCOPES = {
    "binary_sensor": "binary_sensor",
    "sensor": "sensor",
    "fan": "fan",
    "blinds": "cover",
    "garage": "cover",
    "climate": "climate",
    "lock": "lock",
    "alarm_control_panel": "alarm_control_panel",
    "media_player": "media_player",
}


def template(family):
    env = os.environ.copy()
    env["LUA_PATH"] = (
        "test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua;vendor/?/init.lua;;"
    )
    return subprocess.check_output(
        [
            "luajit",
            "-e",
            'local report = print; print = function() end; require("c4_shim"); print = report; '
            'io.write(require("ha.native-catalog").template(nil, 0, "' + family + '"))',
        ],
        text=True,
        env=env,
        cwd=ROOT,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", default=5, type=int, choices=range(1, 21))
    args = parser.parse_args()
    inventory = load_inventory()
    lab = Lab(inventory)
    token = api_token(inventory)
    config = lab.request("GET", "/api/config", token=token)
    assert config.get("version") == inventory["ha_version"]
    demo = set(
        lab.request(
            "POST",
            "/api/template",
            {"template": "{{ integration_entities('demo') | to_json }}"},
            token,
        )
    )
    demo_counts = Counter(entity.split(".", 1)[0] for entity in demo)
    assert all(demo_counts[domain] for domain in SCOPES.values())
    print(
        f"HA {config['version']}, Demo present in {len(set(SCOPES.values()))} domains"
    )
    print("scope | matching Demo rows | samples | first ms | median ms | max ms")
    for family, domain in SCOPES.items():
        request = {"template": template(family)}
        samples = []
        demo_rows = None
        for _ in range(args.samples):
            # Check the marker before each request and time only the projection.
            lab.verify()
            started = perf_counter_ns()
            page = lab._request("POST", "/api/template", request, token)
            samples.append((perf_counter_ns() - started) / 1e6)
            assert page["ids"] == sorted(page["ids"])
            assert all(entity.startswith(domain + ".") for entity in page["ids"])
            assert [row["entity_id"] for row in page["rows"]] == page["ids"][
                : len(page["rows"])
            ]
            if domain == "cover":
                assert all(
                    (row["attributes"]["device_class"] == "garage")
                    == (family == "garage")
                    for row in page["rows"]
                )
            present = sum(row["entity_id"] in demo for row in page["rows"])
            if demo_rows is not None:
                assert present == demo_rows
            demo_rows = present
        print(
            f"{family} | {demo_rows} | {len(samples)} | {samples[0]:.1f} | "
            f"{median(samples):.1f} | {max(samples):.1f}"
        )


if __name__ == "__main__":
    main()

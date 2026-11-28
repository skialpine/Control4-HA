"""Write or verify the small manifest consumed by the Coordinator release check."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from xml.etree import ElementTree as ET
from zipfile import ZIP_STORED, ZipFile

from check_packages import ENDPOINT_PROXIES, PACKAGE_MODELS
from release_version import validate

NAME = "ha-suite-release.json"
DRIVER_BUNDLE = "control4-ha-drivers.zip"
PROXIES = {
    "HA.Coordinator.c4z": {},
    "HA.Light.c4z": {"5001": "light_v2"},
    "Control4.HA.Switch.c4z": {"5001": "uibutton"},
}
PROXIES.update(
    {
        f"Control4.HA.{name}.c4z": proxies
        for name, proxies in ENDPOINT_PROXIES.items()
        if name not in {"BinarySensor", "Sensor"}
    }
)
PROXIES["HA.Binary.Sensor.c4z"] = ENDPOINT_PROXIES["BinarySensor"]
PROXIES["HA.Generic.Sensor.c4z"] = ENDPOINT_PROXIES["Sensor"]


def manifest(directory, revision):
    revision = validate(revision)
    packages = directory / "c4z"
    if {path.name for path in packages.glob("*.c4z")} != set(PACKAGE_MODELS):
        raise ValueError("The packages do not match the suite inventory")
    assets = {}
    for name, model in sorted(PACKAGE_MODELS.items()):
        path = packages / name
        with ZipFile(path) as archive:
            members = archive.infolist()
            if (
                not 2 <= len(members) <= 64
                or sum(item.filename == "driver.xml" for item in members) != 1
                or sum(item.filename == "driver.lua" for item in members) != 1
            ):
                raise ValueError(
                    f"{name} must contain one driver.xml and one driver.lua"
                )
            xml_entry = members[0]
            script = archive.getinfo("driver.lua")
            if (
                xml_entry.filename != "driver.xml"
                or xml_entry.compress_type != ZIP_STORED
                or xml_entry.header_offset != 0
                or xml_entry.flag_bits != 0
                or not 0 < xml_entry.file_size <= 65536
            ):
                raise ValueError(f"{name} must begin with an uncompressed driver.xml")
            if script.flag_bits != 0 or script.compress_size == 0:
                raise ValueError(f"{name} contains an invalid driver.lua member")
            xml = ET.fromstring(archive.read("driver.xml"))
            proxies = xml.findall("proxies/proxy")
            proxy_map = {
                node.get("proxybindingid"): (node.text or "").strip()
                for node in proxies
            }
            minimum = xml.findtext("minimum_os_version")
            if (
                xml.findtext("model") != model
                or xml.findtext("version") != revision
                or len(proxies) != len(proxy_map)
                or proxy_map != PROXIES[name]
                or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", minimum or "")
                or len(minimum) > 15
                or not 0 < path.stat().st_size <= 4 * 1024 * 1024
            ):
                raise ValueError(
                    f"{name} has an unexpected revision or driver identity"
                )
        assets[name] = {
            "model": model,
            "minimum_os": minimum,
            "proxies": proxy_map,
            "size": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    return {"schema": 1, "revision": revision, "assets": assets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("dist/oss"))
    parser.add_argument("--revision", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    path = args.directory / NAME
    expected = manifest(args.directory, args.revision)
    if args.verify:
        if json.loads(path.read_text()) != expected:
            parser.error("The release manifest does not describe the selected archives")
        assets = expected["assets"]
        with ZipFile(args.directory / DRIVER_BUNDLE) as bundle:
            if sorted(bundle.namelist()) != sorted(assets) or any(
                bundle.getinfo(name).file_size != asset["size"]
                or hashlib.sha256(bundle.read(name)).hexdigest() != asset["sha256"]
                for name, asset in assets.items()
            ):
                parser.error(
                    "The driver bundle must contain the exact release packages"
                )
    else:
        path.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()

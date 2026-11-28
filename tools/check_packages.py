"""Inspect the built free suite packages without accessing a controller."""

from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_NOTICES = {
    "www/NOTICE.txt": ROOT / "NOTICE",
    "www/License-xml2lua.txt": ROOT / "vendor/xml/LICENSE",
}
PACKAGE_MODELS = {
    "HA.Coordinator.c4z": "HA Coordinator",
    "HA.Light.c4z": "HA Light",
    "Control4.HA.Switch.c4z": "Control4.HA.Switch",
}
ENDPOINT_PROXIES = {
    "BinarySensor": {},
    "Sensor": {},
    "Fan": {"5001": "fan"},
    "Blinds": {"5001": "blind"},
    "GarageDoor": {"5001": "blind"},
    "Thermostat": {"5001": "thermostatV2"},
    "Lock": {"5001": "lock"},
    "AlarmPanel": {"5001": "securitypanel", "5002": "security"},
    "MediaPlayer": {"5001": "media_service"},
}
ENDPOINT_MODELS = {
    f"Control4.HA.{name}.c4z": f"Control4.HA.{name}"
    for name in ENDPOINT_PROXIES
    if name not in {"BinarySensor", "Sensor"}
}
ENDPOINT_MODELS["HA.Binary.Sensor.c4z"] = "HA Binary Sensor"
ENDPOINT_MODELS["HA.Generic.Sensor.c4z"] = "HA Generic Sensor"
PACKAGE_MODELS.update(ENDPOINT_MODELS)
FORBIDDEN_MODULES = (
    "lib.drivercentral",
    "cloud-client-byte",
    "lib.diagnostics",
    "lib.expressions",
    "lib.expression-sandbox",
    "auth_code_grant",
    'package.preload["crypto"]',
    'package.preload["protobuf"]',
    'package.preload["noiseprotocol"]',
)


def boot(lua, xml, version, *, exercise_controls=True):
    config = {child.tag: child.text or "" for child in xml if not list(child)}
    config["config"] = ET.tostring(xml.find("config"), encoding="unicode")
    properties = {
        p.findtext("name"): p.findtext("default") or ""
        for p in xml.findall("config/properties/property")
    }

    def table(values):
        return (
            "{"
            + ",".join(
                f"[{json.dumps(k)}]={json.dumps(v, ensure_ascii=False)}"
                for k, v in values.items()
            )
            + "}"
        )

    setup = f"""
require('c4_shim')
Properties = {table(properties)}
local config = {table(config)}
function C4:GetDriverConfigInfo(key) return config[key] end
function C4:GetVersionInfo() return {{version={json.dumps(version)}}} end
function C4:UpdateProperty(key, value) Properties[key] = value end
if arg[2] == 'connection' then
  dofile('test/packaged_initial_connection.lua')(arg[1], config.model, arg[3])
  return
end
if arg[2] then
  dofile('test/packaged_light_properties.lua')(arg[1], arg[2], arg[3])
  return
end
local forbidden = {{}}
local pageProperties
function C4:SendDataToUI(command, params)
  if command == 'PROPERTIES' then pageProperties = JSON:decode(params.json).properties end
end
function C4:SendToDevice() table.insert(forbidden, 'outgoing device command') end
function C4:SendToProxy(binding, command, params, kind)
  local offlineLight = config.model == 'HA Light' and tonumber(binding) == 5001
    and command == 'ONLINE_CHANGED' and kind == 'NOTIFY' and (params.STATE == false or params.STATE == '0')
  local offlineSwitch = config.model == 'Control4.HA.Switch' and tonumber(binding) == 5001
    and command == 'ICON_CHANGED' and params.icon == 'unavailable'
  local newEndpoint = {json.dumps(config["model"] in ENDPOINT_MODELS.values())}
  local offlineMedia = config.model == 'Control4.HA.MediaPlayer' and tonumber(binding) == 5001
    and kind == 'COMMAND' and (command == 'UPDATE_MEDIA_INFO' or command == 'SEND_EVENT')
  if (not newEndpoint or kind ~= 'NOTIFY') and not offlineLight and not offlineSwitch and not offlineMedia then
    table.insert(forbidden, tostring(command))
  end
end
assert(loadfile(arg[1]))()
OnDriverInit()
OnDriverLateInit()
local status = Properties['Driver Status'] or ''
if {json.dumps(version)} == '3.2.4' then
  assert(status:find('requires at least C4 OS 3.3.0', 1, true), status)
else
  if config.model == 'HA Coordinator' then
    assert(status == 'Enter the Home Assistant hostname or IP address in HA Host.', status)
  else
    assert(status:find('Not configured', 1, true), status)
    UIRequest('_GET_PROPERTIES', {{}})
    local found = false
    for _, property in ipairs(pageProperties or {{}}) do
      if property.name == 'Manual entity ID' and property.readonly == false then found = true end
    end
    assert(found, 'Device Setup did not return its writable manual device field')
    if {json.dumps(exercise_controls)} then
      dofile('test/packaged_picker.lua')(config.model == 'HA Light' and 'light' or 'switch')
    end
  end
end
if OnDriverDestroyed then OnDriverDestroyed() end
assert(#forbidden == 0, table.concat(forbidden, ', '))
"""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "driver.lua"
        path.write_text(lua)
        runner = Path(directory) / "boot.lua"
        runner.write_text(setup)
        env = os.environ.copy()
        env["LUA_PATH"] = str(ROOT / "test/?.lua") + ";;"
        subprocess.run(
            ["luajit", str(runner), str(path)],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        if (
            exercise_controls
            and config["model"] != "HA Coordinator"
            and version == "3.3.0"
        ):
            for scenario in (
                "unique",
                "missing",
                "incompatible",
                "ambiguous",
                "existing",
            ):
                subprocess.run(
                    ["luajit", str(runner), str(path), "connection", scenario],
                    cwd=ROOT,
                    env=env,
                    check=True,
                )
        if exercise_controls and config["model"] == "HA Light" and version == "3.3.0":
            store = Path(directory) / "director-persist.txt"
            for phase in ("edit", "reload"):
                subprocess.run(
                    ["luajit", str(runner), str(path), phase, str(store)],
                    cwd=ROOT,
                    env=env,
                    check=True,
                )


def check(directory=ROOT / "dist/oss/c4z"):
    expected = set(PACKAGE_MODELS)
    actual = {p.name for p in directory.glob("*.c4z")}
    if expected != actual:
        raise ValueError(f"Expected exactly {sorted(expected)}, found {sorted(actual)}")
    for name in sorted(expected):
        with zipfile.ZipFile(directory / name) as package:
            names = package.namelist()
            carried = {
                member
                for member in names
                if member.startswith("c4z/") and not member.endswith("/")
            }
            if name == "HA.Coordinator.c4z":
                standalone = expected - {name}
                if carried != {f"c4z/{child}" for child in standalone} or any(
                    package.read(f"c4z/{child}") != (directory / child).read_bytes()
                    for child in standalone
                ):
                    raise ValueError(
                        f"{name}: bundled drivers must match the standalone packages"
                    )
            elif carried:
                raise ValueError(f"{name}: only the Coordinator carries drivers")
            if any(
                n.startswith(("lab/", "test/", "vendor/", ".env", ".git"))
                for n in names
            ):
                raise ValueError(f"{name}: non-runtime files bundled")
            xml = ET.fromstring(package.read("driver.xml"))
            if xml.findtext("model") != PACKAGE_MODELS[name]:
                raise ValueError(f"{name}: package/model identity mismatch")
            update_controls = {
                "Update channel",
                "Driver update status",
                "CheckDriverUpdates",
            }
            declared = {
                item.findtext("name")
                for item in xml.findall("config/properties/property")
            } | {
                item.findtext("command")
                for item in xml.findall("config/actions/action")
            }
            expected_updates = (
                update_controls if name == "HA.Coordinator.c4z" else set()
            )
            if update_controls & declared != expected_updates:
                raise ValueError(
                    f"{name}: driver update controls belong only to the Coordinator"
                )
            if (
                len(xml.findall("capabilities")) > 1
                or name not in ENDPOINT_MODELS
                and xml.find("capabilities") is None
            ):
                raise ValueError(f"{name}: expected exactly one capabilities section")
            if name == "Control4.HA.GarageDoor.c4z":
                proxy = xml.find("proxies/proxy")
                for tag, size in (("small", 16), ("large", 32)):
                    icon = xml.find(tag)
                    if (
                        icon is None
                        or icon.get("image_source") != "c4z"
                        or proxy is None
                        or proxy.get("image_source") != "c4z"
                        or proxy.get(f"{tag}_image") != icon.text
                    ):
                        raise ValueError(
                            f"{name}: missing {tag} Composer icon declaration"
                        )
                    data = package.read(f"www/{icon.text}")
                    dimensions = size.to_bytes(2, "little") * 2
                    if (
                        data[:6] not in (b"GIF87a", b"GIF89a")
                        or data[6:10] != dimensions
                    ):
                        raise ValueError(
                            f"{name}: wrong format or size for {tag} Composer icon"
                        )
                outputs = {
                    node.findtext("id"): node.findtext("classes/class/classname")
                    for node in xml.findall("connections/connection")
                    if (node.findtext("consumer") or "").lower() == "false"
                }
                expected_outputs = {
                    "2": "CONTACT_SENSOR",
                    "3": "CONTACT_SENSOR",
                    "4": "RELAY",
                    "5": "RELAY",
                    "6": "RELAY",
                    "7": "RELAY",
                    "203": "BUTTON_LINK",
                    "5001": "BLIND",
                }
                if any(
                    outputs.get(binding) != cls
                    for binding, cls in expected_outputs.items()
                ):
                    raise ValueError(
                        f"{name}: expected the door relay and limit outputs"
                    )
                if {
                    binding for binding, cls in outputs.items() if cls == "BUTTON_LINK"
                } != {"203"}:
                    raise ValueError(
                        f"{name}: only Step-by-Step should be declared alongside native keypad links"
                    )
            tabs = xml.findall("config/tabs/tab")
            title = "Quick Setup" if name == "HA.Coordinator.c4z" else "Device Setup"
            if not any(
                tab.get("name") == title and tab.get("file") == "html/index.html"
                for tab in tabs
            ):
                raise ValueError(f"{name}: expected a {title} tab for html/index.html")
            if name == "HA.Light.c4z":
                native = xml.find("capabilities")
                for key, expected_value in {
                    "hide_proxy_properties": "false",
                    "dimmer": "true",
                    "has_leds": "true",
                    "supports_default_on": "true",
                    "brightness_on_mode_preset": "true",
                    "brightness_on_mode_previous": "true",
                    "click_rates": "true",
                    "hold_rates": "true",
                }.items():
                    if (native.findtext(key) or "").lower() != expected_value:
                        raise ValueError(
                            f"{name}: native light editor requires {key}={expected_value}"
                        )
            if name == "Control4.HA.Switch.c4z":
                power_names = {"Turn On", "Turn Off", "Toggle", "TurnOn", "TurnOff"}
                power_commands = [
                    (command.findtext("name"), command.findtext("description"))
                    for command in xml.findall("config/commands/command")
                    if command.findtext("name") in power_names
                ]
                if sorted(power_commands) != sorted(
                    [
                        ("Turn On", "Turn NAME On"),
                        ("Turn Off", "Turn NAME Off"),
                        ("Toggle", "Toggle NAME"),
                    ]
                ):
                    raise ValueError(
                        f"{name}: Composer power actions must show their target device"
                    )
            for tab in tabs:
                if "www/" + tab.get("file", "") not in names:
                    raise ValueError(f"{name}: missing packaged setup page")
            if name == "HA.Coordinator.c4z":
                if xml.findtext("combo") != "true":
                    raise ValueError(
                        "Proxy-free Coordinator must be selectable in Composer"
                    )
                token = xml.find("config/properties/property[name='HA Token']")
                if token is None or token.findtext("password") != "true":
                    raise ValueError("Coordinator access token must be protected")
            lua = package.read("driver.lua").decode()
            for module in FORBIDDEN_MODULES:
                if module in lua:
                    raise ValueError(f"{name}: unexpected module {module}")
            if "Control4-HA-Base" in lua or "Control4-HA-Base" in str(names):
                raise ValueError(f"{name}: legacy Base dependency")
            for member, source in PACKAGE_NOTICES.items():
                if member not in names or package.read(member) != source.read_bytes():
                    raise ValueError(f"{name}: missing or changed notice {member}")
            for version in ("3.2.4", "3.3.0"):
                boot(lua, xml, version, exercise_controls=name not in ENDPOINT_MODELS)
    print(
        f"{len(expected)} free suite packages inspected: no Base or commercial runtime dependency."
    )
    print(
        "Built-package startup: rejects OS 3.2.4; accepts baseline OS 3.3.0 without control traffic."
    )
    print(
        "Built Light preserves native presets, click and hold rates, and linked keypad colors across reload."
    )


def retire_interim_outputs(directory, archive):
    """Keep previous side-by-side builds out of incremental package output."""
    for family in ("Coordinator", "Light"):
        old = directory / f"Control4.HA.{family}.c4z"
        if old.is_file():
            bucket = archive / hashlib.sha256(old.read_bytes()).hexdigest()
            bucket.mkdir(parents=True, exist_ok=True)
            old.replace(bucket / old.name)


if __name__ == "__main__":
    if sys.argv[1:] == ["--retire-interim"]:
        retire_interim_outputs(ROOT / "dist/oss/c4z", ROOT / ".cache/interim-packages")
    elif len(sys.argv) == 1:
        try:
            check()
        except subprocess.CalledProcessError as error:
            detail = error.stderr or error.stdout or str(error)
            raise SystemExit(detail.rstrip()) from None
    else:
        raise SystemExit("Usage: check_packages.py [--retire-interim]")

"""Provision only the positively identified, project-owned HA Container lab."""

import argparse
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import ssl
import tarfile
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LABEL = "io.control4-ha.lab.id"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError(
            "Redirect refused; credentials stay on the configured origin"
        )


class Portainer:
    def __init__(self, config, inventory):
        env = json.loads(config.read_text())["mcpServers"]["portainer"]["env"]
        if env["PORTAINER_URL"].rstrip("/") != inventory["portainer_url"]:
            raise ValueError(
                "Portainer origin does not match the reviewed lab inventory"
            )
        self.base = (
            inventory["portainer_url"]
            + f'/api/endpoints/{inventory["portainer_endpoint_id"]}/docker'
        )
        self.key = env["PORTAINER_API_KEY"]
        context = ssl.create_default_context()
        if env.get("PORTAINER_TLS_VERIFY") == "0":
            context = ssl._create_unverified_context()
        self.opener = urllib.request.build_opener(
            NoRedirect(), urllib.request.HTTPSHandler(context=context)
        )
        info = self.call("GET", "/info")
        if (
            info.get("ID") != inventory["docker_host_id"]
            or info.get("Name") != inventory["docker_host_name"]
        ):
            raise ValueError("Docker host identity mismatch; refusing mutation")

    def call(self, method, path, data=None, raw=False, timeout=30):
        headers = {"X-API-Key": self.key}
        if data is not None and not isinstance(data, bytes):
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        elif data is not None:
            headers["Content-Type"] = "application/x-tar"
        request = urllib.request.Request(
            self.base + path, data=data, method=method, headers=headers
        )
        try:
            with self.opener.open(request, timeout=timeout) as response:
                content = response.read()
                return content if raw or not content else json.loads(content)
        except urllib.error.HTTPError as error:
            # Do not print response bodies, credentials or request payloads.
            raise RuntimeError(
                f"Docker API HTTP {error.code} on {method} {path.split('?')[0]}"
            ) from None


def assert_owned(resource, inventory):
    if (resource.get("Labels") or {}).get(LABEL) != inventory["lab_id"]:
        raise ValueError(
            "Existing resource is not owned by this lab; refusing adoption"
        )


def assert_container(container, inventory):
    if (
        inventory.get("container_id")
        and container.get("Id") != inventory["container_id"]
    ):
        raise ValueError("Docker container identity does not match the recorded lab")
    if (
        inventory.get("image_digest")
        and container["Config"].get("Image") != inventory["image_digest"]
    ):
        raise ValueError("Lab image differs from its pinned digest")
    assert_owned(container["Config"], inventory)
    host = container["HostConfig"]
    if host.get("Privileged") or host.get("Devices") or host.get("Binds"):
        raise ValueError(
            "Unexpected privileges, devices or bind mounts on lab container"
        )
    if host.get("NetworkMode") != inventory["network"]:
        raise ValueError("Lab must use only its dedicated bridge network")
    mounts = container.get("Mounts", [])
    if (
        len(mounts) != 1
        or mounts[0].get("Name") != inventory["volume"]
        or mounts[0].get("Destination") != "/config"
    ):
        raise ValueError("Lab configuration volume is not its sole mount")
    if host.get("Memory") != inventory["memory_limit_bytes"]:
        raise ValueError("Lab memory limit does not match reviewed allocation")
    ports = host.get("PortBindings") or {}
    if set(ports) != {"8123/tcp"} or ports["8123/tcp"][0].get("HostPort") != str(
        inventory["published_port"]
    ):
        raise ValueError("Lab port does not match reviewed allocation")
    if (
        container["Config"]
        .get("Labels", {})
        .get("com.centurylinklabs.watchtower.enable")
        != "false"
    ):
        raise ValueError(
            "Lab image must remain pinned; Watchtower exclusion is missing"
        )


def seed_archive(inventory):
    files = {
        "configuration.yaml": (ROOT / "lab/seed/configuration.yaml").read_bytes(),
        "www/control4-ha-lab.json": json.dumps(
            {"lab_id": inventory["lab_id"], "purpose": "test-only"}
        ).encode(),
    }
    content = io.BytesIO()
    with tarfile.open(fileobj=content, mode="w") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(data))
    return content.getvalue()


def save_private(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)


def restored_archive(path, inventory):
    """Normalize an owned cold archive for a fresh empty volume; never extract locally."""
    output = io.BytesIO()
    marker = None
    with tarfile.open(path, "r:*") as source, tarfile.open(
        fileobj=output, mode="w"
    ) as target:
        for member in source.getmembers():
            name = member.name.removeprefix("config/")
            if name == "config":
                continue
            relative = Path(name)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not (member.isfile() or member.isdir())
            ):
                raise ValueError("Recovery archive has unsafe or unsupported members")
            member.name = name
            data = source.extractfile(member) if member.isfile() else None
            if name == "www/control4-ha-lab.json":
                content = data.read()
                marker = json.loads(content)
                data = io.BytesIO(content)
            target.addfile(member, data)
    if marker != {"lab_id": inventory["lab_id"], "purpose": "test-only"}:
        raise ValueError("Recovery archive does not belong to this lab")
    return output.getvalue()


def provision(
    client, inventory, inventory_path=ROOT / "lab/inventory.json", restore=None
):
    seed = restored_archive(restore, inventory) if restore else seed_archive(inventory)
    labels = {LABEL: inventory["lab_id"], "io.control4-ha.purpose": "test-only"}
    containers = client.call("GET", "/containers/json?all=1")
    existing = next(
        (c for c in containers if "/" + inventory["container"] in c["Names"]), None
    )
    if existing:
        inspected = client.call("GET", "/containers/" + existing["Id"] + "/json")
        assert_container(inspected, inventory)
        if inventory.get("container_id") != inspected["Id"]:
            raise ValueError(
                "Existing container ID differs from recorded lab; inspect before resuming"
            )
        print("Existing owned lab preserved; no configuration or credential changes.")
        return
    volumes = client.call("GET", "/volumes").get("Volumes", [])
    volume = next((v for v in volumes if v["Name"] == inventory["volume"]), None)
    if volume:
        # A new allocation never imports or overwrites any existing volume.
        raise ValueError(
            "Configuration volume already exists; inspect the interrupted allocation before provisioning"
        )
    networks = client.call("GET", "/networks")
    network = next((n for n in networks if n["Name"] == inventory["network"]), None)
    if network:
        assert_owned(network, inventory)
    backup = (
        ROOT
        / ".cache/lab-backups"
        / (inventory["lab_id"] + "-" + inventory["container"] + "-seed.tar")
    )
    if backup.exists():
        if backup.read_bytes() != seed:
            raise ValueError(
                "Existing private seed archive differs; refusing overwrite"
            )
    else:
        save_private(backup, seed)
    image = "ghcr.io/home-assistant/home-assistant:" + inventory["ha_version"]
    print(
        "Pulling the explicit HA image onto the Docker host (not this Mac).", flush=True
    )
    query = urllib.parse.urlencode({"fromImage": image})
    pulled = client.call("POST", "/images/create?" + query, raw=True, timeout=300)
    for line in pulled.splitlines():
        event = json.loads(line)
        if "error" in event:
            raise RuntimeError(
                "Docker image pull failed; no lab resources were created"
            )
    image_info = client.call(
        "GET", "/images/" + urllib.parse.quote(image, safe="/:") + "/json"
    )
    digests = image_info.get("RepoDigests", [])
    digest = next(
        (
            d
            for d in digests
            if d.startswith("ghcr.io/home-assistant/home-assistant@sha256:")
        ),
        None,
    )
    if not digest:
        raise ValueError("Pulled HA image has no immutable repository digest")
    client.call(
        "POST", "/volumes/create", {"Name": inventory["volume"], "Labels": labels}
    )
    if not network:
        client.call(
            "POST",
            "/networks/create",
            {
                "Name": inventory["network"],
                "Driver": "bridge",
                "CheckDuplicate": True,
                "Labels": labels,
            },
        )
    config = {
        "Image": digest,
        "Labels": {**labels, "com.centurylinklabs.watchtower.enable": "false"},
        "Env": ["TZ=America/Denver"],
        "ExposedPorts": {"8123/tcp": {}},
        "HostConfig": {
            "NetworkMode": inventory["network"],
            "Privileged": False,
            "Memory": inventory["memory_limit_bytes"],
            "MemorySwap": inventory["memory_limit_bytes"],
            "NanoCpus": inventory["nano_cpus"],
            "PidsLimit": 512,
            "CapDrop": ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"],
            "RestartPolicy": {"Name": "unless-stopped"},
            "PortBindings": {
                "8123/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": str(inventory["published_port"])}
                ]
            },
            "Mounts": [
                {"Type": "volume", "Source": inventory["volume"], "Target": "/config"}
            ],
            "LogConfig": {
                "Type": "json-file",
                "Config": {"max-size": "10m", "max-file": "2"},
            },
        },
    }
    created = client.call(
        "POST",
        "/containers/create?"
        + urllib.parse.urlencode({"name": inventory["container"]}),
        config,
    )
    container_id = created["Id"]
    inspected = client.call("GET", "/containers/" + container_id + "/json")
    assert_container(inspected, inventory)
    client.call(
        "PUT", "/containers/" + container_id + "/archive?path=/config", seed, raw=True
    )
    inventory["container_id"] = container_id
    inventory["image_digest"] = digest
    inventory["seed_backup"] = backup.relative_to(ROOT).as_posix()
    inventory["provisioned_utc"] = datetime.now(timezone.utc).isoformat()
    inventory_path.write_text(json.dumps(inventory, indent=2) + "\n")
    client.call("POST", "/containers/" + container_id + "/start", raw=True)
    print("Started owned lab:", inventory["base_url"], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portainer-config", required=True, type=Path)
    parser.add_argument("--inventory", type=Path, default=ROOT / "lab/inventory.json")
    parser.add_argument("--restore-to-new-volume", type=Path)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    client = Portainer(args.portainer_config, inventory)
    provision(client, inventory, args.inventory, args.restore_to_new_volume)


if __name__ == "__main__":
    main()

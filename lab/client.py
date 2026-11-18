"""Explicit lab-target checks shared by HA integration runners; never production."""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from provision import NoRedirect, ROOT

TOKEN_CACHE = ROOT / ".cache/lab-credentials/ha-api-token.json"


def _token_identity(inventory):
    identity = {
        key: inventory.get(key) for key in ("lab_id", "base_url", "credential_item_id")
    }
    if not all(isinstance(value, str) and value for value in identity.values()):
        raise ValueError("Lab identity and credential reference are required")
    return identity


def _cached_token(identity):
    try:
        fd = os.open(TOKEN_CACHE, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    with os.fdopen(fd) as cached:
        info = os.fstat(cached.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError(
                "Lab token cache must be a regular file owned by this user"
            )
        os.fchmod(cached.fileno(), 0o600)
        try:
            value = json.loads(cached.read(16384))
        except ValueError:
            raise RuntimeError(
                "Invalid lab token cache; explicitly refresh it"
            ) from None
    if not isinstance(value, dict) or value.get("identity") != identity:
        return None
    token = value.get("token")
    if not isinstance(token, str) or not token or any(c.isspace() for c in token):
        raise RuntimeError("Invalid lab token cache; explicitly refresh it")
    return token


def _cache_token(identity, token):
    directory = TOKEN_CACHE.parent
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    if directory.is_symlink():
        raise RuntimeError("Lab credential directory must not be a symbolic link")
    directory.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix=".token-", dir=directory)
    try:
        with os.fdopen(fd, "w") as cached:
            os.fchmod(cached.fileno(), 0o600)
            json.dump({"identity": identity, "token": token}, cached)
            cached.flush()
            os.fsync(cached.fileno())
        os.replace(temporary, TOKEN_CACHE)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def op_json(arguments, data=None):
    result = subprocess.run(
        ["op", *arguments, "--format=json"],
        input=None if data is None else json.dumps(data),
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            "1Password operation failed; no credential values were logged"
        )
    return json.loads(result.stdout)


def credentials(inventory):
    item_id = inventory.get("credential_item_id")
    if not item_id:
        raise ValueError("Lab credential item is not configured")
    item = op_json(["item", "get", item_id])
    return item, {f.get("id"): f.get("value", "") for f in item["fields"]}


def api_token(inventory, *, refresh=False):
    """Reuse the user-authorized private local cache; never cache the Login password."""
    identity = _token_identity(inventory)
    if not refresh:
        cached = _cached_token(identity)
        if cached:
            return cached
    item_id = identity["credential_item_id"]
    field = op_json(
        ["item", "get", item_id, "--fields", "label=Lab API Token", "--reveal"]
    )
    if isinstance(field, list) and len(field) == 1:
        field = field[0]
    token = field.get("value") if isinstance(field, dict) else None
    if not isinstance(token, str) or not token or any(c.isspace() for c in token):
        raise RuntimeError("The dedicated lab API token field is missing")
    _cache_token(identity, token)
    return token


class Lab:
    def __init__(self, inventory, base_url=None, opener=None):
        self.inventory = inventory
        self.url = base_url or inventory.get("base_url")
        if (
            not self.url
            or self.url != inventory.get("base_url")
            or not inventory.get("lab_id")
        ):
            raise ValueError(
                "An exact allowlisted lab URL and lab identity are required"
            )
        parsed = urllib.parse.urlsplit(self.url)
        if (
            parsed.scheme not in ("http", "https")
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path
        ):
            raise ValueError(
                "Lab URL must be an explicit origin without credentials or paths"
            )
        if parsed.port != inventory.get("published_port"):
            raise ValueError("Lab URL port does not match the reviewed allocation")
        self.opener = opener or urllib.request.build_opener(NoRedirect())

    def _request(self, method, path, data=None, token=None, form=False):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("Requests must stay on the allowlisted lab origin")
        headers = {}
        if token:
            headers["Authorization"] = "Bearer " + token
        if data is not None:
            if form:
                data = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.url + path, data=data, headers=headers, method=method
        )
        try:
            with self.opener.open(request, timeout=15) as response:
                return json.loads(response.read(2 * 1024 * 1024))
        except urllib.error.HTTPError as error:
            raise RuntimeError(
                f"Lab API HTTP {error.code} on {method} {path.split('?')[0]}"
            ) from None

    def verify(self):
        marker = self._request("GET", "/local/control4-ha-lab.json")
        if marker != {"lab_id": self.inventory["lab_id"], "purpose": "test-only"}:
            raise ValueError(
                "HA lab identity mismatch; refusing credentials and mutations"
            )

    def request(self, method, path, data=None, token=None, form=False):
        # Verify before credentials leave this process, for reads as well as writes.
        self.verify()
        return self._request(method, path, data, token, form)

    def websocket(self, token):
        from websockets.sync.client import connect

        self.verify()
        url = (
            ("wss" if self.url.startswith("https:") else "ws")
            + self.url[self.url.index(":") :]
            + "/api/websocket"
        )
        socket = connect(url, proxy=None, open_timeout=15, close_timeout=3)
        try:
            if (
                socket.request.headers.get("Host")
                != urllib.parse.urlsplit(self.url).netloc
            ):
                raise ValueError(
                    "WebSocket redirected to another origin; refusing credentials"
                )
            required = json.loads(socket.recv(timeout=15))
            if (
                required.get("type") != "auth_required"
                or required.get("ha_version") != self.inventory["ha_version"]
            ):
                raise ValueError("Lab WebSocket identity/version handshake mismatch")
            socket.send(json.dumps({"type": "auth", "access_token": token}))
            if json.loads(socket.recv(timeout=15)).get("type") != "auth_ok":
                raise ValueError("Lab WebSocket authentication rejected")
            return socket
        except Exception:
            socket.close()
            raise


def command(socket, message):
    socket.send(json.dumps(message))
    while True:
        reply = json.loads(socket.recv(timeout=15))
        if reply.get("id") == message["id"]:
            if reply.get("success") is not True:
                raise RuntimeError("Lab WebSocket command rejected: " + message["type"])
            return reply.get("result")


def load_inventory():
    return json.loads((ROOT / "lab/inventory.json").read_text())


def require_c4_target(inventory, controller, project):
    if not controller or not project:
        raise ValueError(
            "Native C4 tests require an explicitly selected controller and project"
        )
    wanted = {"controller": controller, "project": project}
    if wanted not in inventory.get("approved_c4_targets", []):
        raise ValueError(
            "C4 controller/project pair is not explicitly approved for lab tests"
        )
    return wanted

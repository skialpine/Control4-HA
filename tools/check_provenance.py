"""Validate recorded source copies before distribution (standard library only)."""

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(inventory, root):
    errors = []
    seen = set()
    for source in inventory["sources"]:
        if not source.get("credit") or not source.get("revision"):
            errors.append(f"{source['id']}: missing author credit or revision")
        copies = source.get("copies", [])
        if copies and source.get("permission") != "established":
            errors.append(f"{source['id']}: copied material has unresolved reuse terms")
        for notice in source.get("required_notices", []) if copies else []:
            if not (root / notice).is_file():
                errors.append(f"{source['id']}: missing required notice {notice}")
        for item in copies:
            path = Path(item["path"])
            if path.is_absolute() or ".." in path.parts or path.as_posix() in seen:
                errors.append(f"{source['id']}: invalid/duplicate copy {path}")
                continue
            seen.add(path.as_posix())
            target = root / path
            if not item.get("source_path") or not item.get("changes"):
                errors.append(f"{path}: missing source path or adaptation record")
            if not target.is_file() or hashlib.sha256(
                target.read_bytes()
            ).hexdigest() != item.get("sha256"):
                errors.append(f"{path}: missing file or unreviewed content hash")
    # All template-owned runtime libraries must have an explicit source record.
    for directory in ("vendor", "src/lib"):
        for path in (root / directory).rglob("*"):
            if path.is_file() and path.relative_to(root).as_posix() not in seen:
                errors.append(f"{path.relative_to(root)}: missing source inventory")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--inventory", type=Path, default=ROOT / "provenance/sources.json"
    )
    args = parser.parse_args()
    errors = check(json.loads(args.inventory.read_text()), ROOT)
    if errors:
        print("Public distribution blocked:\n" + "\n".join(f"- {e}" for e in errors))
        return 1
    print("Recorded provenance checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

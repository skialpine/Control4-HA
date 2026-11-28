"""Reproducible OSS build using the pinned template's own pipeline."""

import argparse
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
from shutil import copyfile
import subprocess
import sys
import tempfile
import zipfile

from check_packages import PACKAGE_NOTICES
from package import make_zip
from release_manifest import DRIVER_BUNDLE, NAME as RELEASE_MANIFEST, manifest
from release_version import current, validate
from setup_skill import setup_skill

ROOT = Path(__file__).resolve().parents[1]
PACKAGER_REVISION = "465ecc1cf73a85a4fdaf62fb688e9aed83e6d530"


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def write_canonical_archive(source, destination):
    """Normalize ZIP metadata and ordering, including carried packages."""
    with zipfile.ZipFile(source) as package:
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Archive contains duplicate entries")
        with zipfile.ZipFile(
            destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as output:
            for name in sorted(names, key=lambda name: (name != "driver.xml", name)):
                content = package.read(name)
                if name.startswith("c4z/") and name.endswith(".c4z"):
                    carried = BytesIO()
                    write_canonical_archive(BytesIO(content), carried)
                    content = carried.getvalue()
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                # The release check reads the actual identity without extracting files.
                entry.compress_type = (
                    zipfile.ZIP_STORED if name == "driver.xml" else zipfile.ZIP_DEFLATED
                )
                output.writestr(entry, content, compresslevel=9)


def canonicalize(path):
    with tempfile.TemporaryDirectory(dir=path.parent) as directory:
        output = Path(directory) / path.name
        write_canonical_archive(path, output)
        output.replace(path)


def inventory(version, epoch):
    packages = []
    for path in sorted((ROOT / "dist/oss/c4z").glob("*.c4z")):
        with zipfile.ZipFile(path) as package:
            members = {
                name: hashlib.sha256(package.read(name)).hexdigest()
                for name in sorted(package.namelist())
            }
        packages.append(
            {
                "name": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "members": members,
            }
        )
    return {
        "schema_version": 1,
        "version": version,
        "source_date_epoch": epoch,
        "template": json.loads((ROOT / "provenance/template-lock.json").read_text()),
        "packager_revision": PACKAGER_REVISION,
        "qualification": "development-foundation",
        "packages": packages,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=current(), type=validate)
    parser.add_argument(
        "--epoch", type=int, default=os.environ.get("SOURCE_DATE_EPOCH")
    )
    args = parser.parse_args()
    if args.epoch is None or args.epoch < 0:
        parser.error(
            "set SOURCE_DATE_EPOCH or --epoch to the source revision's timestamp"
        )
    packager = ROOT / "dist/driverpackager"
    revision = subprocess.check_output(
        ["git", "-C", str(packager), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != PACKAGER_REVISION:
        raise SystemExit(
            f"driverpackager must be {PACKAGER_REVISION}; run the documented pinned initialization"
        )
    if subprocess.check_output(
        ["git", "-C", str(packager), "status", "--porcelain"], text=True
    ).strip():
        raise SystemExit("driverpackager contains unreviewed local modifications")
    # Discovery and squish are the template's; there is no second bundler here.
    run(
        "make",
        "check-deps",
        "preprocess",
        "gen-squishy",
        "update-xml-version",
        f"DRIVER_VERSION={args.version}",
    )
    modified = datetime.fromtimestamp(args.epoch, timezone.utc).strftime(
        "%m/%d/%Y %I:%M %p"
    )
    for path in sorted((ROOT / "build/oss/drivers").glob("*/driver.xml")):
        for member, source in PACKAGE_NOTICES.items():
            copyfile(source, path.parent / member)
        run(
            str(ROOT / ".venv/bin/python3"),
            "tools/package.py",
            "xml-set",
            str(path),
            "modified",
            modified,
        )
    if (ROOT / "build/oss/.encrypted").exists():
        raise SystemExit(
            "OSS release unexpectedly substituted a secret; inspect local build inputs"
        )
    run("make", "docs-html", "package")
    for path in sorted((ROOT / "dist/oss/c4z").glob("*.c4z")):
        canonicalize(path)
    run(sys.executable, "tools/check_packages.py")
    data = (
        json.dumps(inventory(args.version, args.epoch), indent=2, sort_keys=True) + "\n"
    )
    output = ROOT / "dist/oss/inventory.json"
    setup_skill(output.parent, args.version)
    output.write_text(data)
    digest = hashlib.sha256(data.encode()).hexdigest()
    (ROOT / "dist/oss/inventory.sha256").write_text(f"{digest}  inventory.json\n")
    release = manifest(output.parent, args.version)
    bundle = output.parent / DRIVER_BUNDLE
    make_zip(bundle, [str(output.parent / "c4z" / name) for name in release["assets"]])
    canonicalize(bundle)
    (output.parent / RELEASE_MANIFEST).write_text(
        json.dumps(release, indent=2, sort_keys=True) + "\n"
    )
    print(f"Inventory SHA-256: {digest}")


if __name__ == "__main__":
    main()

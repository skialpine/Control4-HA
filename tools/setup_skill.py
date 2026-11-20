"""Build or verify the release's portable setup skill and matching manuals."""

import argparse
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from release_version import current, validate

ROOT = Path(__file__).resolve().parents[1]
NAME = "control4-ha-setup"
ARCHIVE = f"{NAME}.zip"
MANUALS = (
    "documentation/installation.md",
    "documentation/compatibility.md",
    "documentation/connection.md",
    "documentation/device-setup.md",
    "documentation/connected-control4-lighting.md",
    "documentation/first-demo-packages.md",
    "documentation/build.md",
    "drivers/coordinator/www/documentation/index.md",
)


def members(revision):
    skill = ROOT / "skills" / NAME
    files = {
        f"{NAME}/{relative}": (skill / relative).read_bytes()
        for relative in ("SKILL.md", "references/manuals.md")
    }
    release = f"{NAME}/references/release"
    files[f"{release}/VERSION"] = f"{validate(revision)}\n".encode()
    for source in (*MANUALS, "LICENSE", "NOTICE"):
        files[f"{release}/{source}"] = (ROOT / source).read_bytes()
    return files


def setup_skill(directory, revision, verify=False):
    archive = directory / ARCHIVE
    expected = members(revision)
    if verify:
        with ZipFile(archive) as package:
            if sorted(package.namelist()) != sorted(expected) or any(
                package.read(name) != contents for name, contents in expected.items()
            ):
                raise ValueError(
                    "Setup skill archive does not match the release sources"
                )
        return archive
    directory.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=directory) as temporary:
        candidate = Path(temporary) / ARCHIVE
        with ZipFile(candidate, "w") as package:
            for name, contents in sorted(expected.items()):
                entry = ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                package.writestr(
                    entry, contents, compress_type=ZIP_DEFLATED, compresslevel=9
                )
        candidate.replace(archive)
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "dist/oss")
    parser.add_argument("--revision", default=current(), type=validate)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    print(setup_skill(args.directory, args.revision, verify=args.verify))

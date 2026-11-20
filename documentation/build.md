# Building the development suite

These commands create development foundations, not qualified feedback packages.
Run Python 3.15, LuaJIT 2.1, Node and StyLua 2.6.0. Python build dependencies
are constrained by `requirements-build.lock`; runtime Lua dependencies come from
the Copier pin in `provenance/template-lock.json`.

Initialize with the template's `make init`. Pin its driverpackager checkout:

```sh
git -C dist/driverpackager checkout 465ecc1cf73a85a4fdaf62fb688e9aed83e6d530
```

The suite is OSS-only through `Makefile.local`. A build requires no HA
credentials, lab configuration, commercial licensing keys or support secrets.
The root `VERSION` file sets the suite revision. Use the source commit's
timestamp for reproducible builds.

```sh
SOURCE_DATE_EPOCH=1794972898 make suite-build
make suite-verify
```

For a first-demo candidate, run the additional archive comparison against the
six pinned predecessors. [First-demo package comparison](first-demo-packages.md)

`suite-build` invokes the template's dependency check, preprocessor, actual-use
module discovery, version stamping, HTML documentation and driverpackager. The
suite wrapper supplies a deterministic modified timestamp, canonical ZIP
metadata and `dist/oss/inventory.json` with package/member SHA-256 hashes. The
release manifest `dist/oss/ha-suite-release.json` records exact package
filenames, hashes, sizes, driver models, minimum OS and proxy bindings. Archives
start with an uncompressed `driver.xml` so the Coordinator can verify that the
declared identity matches the downloaded package. `inventory.sha256` covers the
inventory itself. It rejects a changed packager revision, unexpected secret
substitution, extra families and forbidden modules. Versions use the Group
Lighting convention `YYYYMMDDRR`. Increment the last two digits for each
same-day release. For example, `2026111801` upgrades a driver at `20261118`, and
`2026111802` upgrades `2026111801`. Builds from unchanged inputs keep the same
version. For a release, commit the new revision in `VERSION` and tag it with the
matching numeric core, such as `v2026111801-rc1`. Production promotion needs a
higher revision because Composer stores the numeric version. CI checks the full
tag history for reuse and regression.

For reproducibility, repeat the exact command and compare every `.c4z` and both
inventory files. These files must be byte-identical. Reuse the same pinned
sources, dependency lock, version and timestamp; an unrecorded source edit is a
new input. Generated runtime packages contain only their script, XML and
explicit web assets. No lab or test tree is a packaging input.

Run focused project tests with `make test-project`, the template suites with
`make test`, and formatting checks with `make check`. The Light packaged-driver
conformance rig is added with its actual HA adapter; foundation packages alone
cannot pass device-control conformance. See the Light qualification report for
the library-level results already exercised.

CI uses the same suite build and inspection commands and the commit timestamp.
`suite-verify` runs the Coordinator's release qualification against the built
archives and verifies the manifest against the exact version and file digests.
It verifies that `control4-ha-drivers.zip` contains the same three C4Z packages
GitHub publishes individually and that `control4-ha-setup.zip` contains the
skill, version and canonical manuals from the same build. CI checks provenance
before uploading artifacts. The source inventory records the applicable notices
and permissions. Development builds still require the release-readiness checks
before a qualified feedback handoff.

## Check for a driver release

In Composer, open the Coordinator's **Properties** to choose an **Update
channel**. Production selects stable releases and Pre-release includes previews.
In **Actions**, run **Check for driver updates** and read **Driver update
status** in Properties. **Driver Version** shows the installed revision. The
update status shows the newest eligible release or explains why the check could
not finish. The check compares the exact installed suite packages with the
GitHub release and verifies the required downloads. It preserves the running
driver versions and Home Assistant connections.

The configured GitHub repository is `skialpine/Control4-HA`. When a compatible
release is available, the status reports its revision. A partial release or
failed integrity check should be corrected in the release before installing. The
current payload check is separate from automatic installation. To update a lab
manually, use exact matching packages, update installed children first and
Coordinator last, then verify each original selection and binding.

If an installation stops partway through, read each installed driver version in
Composer before retrying. Use the same complete package set to finish the
update. Recheck selection, connections, control and feedback on each affected
driver. If the update changed project settings or links and recovery cannot be
verified, use the saved Control4 project backup and the corresponding driver
packages to restore the working setup.

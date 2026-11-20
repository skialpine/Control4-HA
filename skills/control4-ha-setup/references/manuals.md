# Release manuals and tools

The skill archive includes a **release** folder beside this reference. Read its
`VERSION` first. The manuals below come from the same source tree as the driver
packages. In a source checkout, read the same paths from the repository root.

| Task | Manual in the skill archive |
| --- | --- |
| Start a fresh installation, select driver packages, or hand off to an installer | [Installation](release/documentation/installation.md) |
| Check supported versions, original driver identities, and migration types | [Compatibility](release/documentation/compatibility.md) |
| Set the Coordinator address, authentication, or certificate properties | [Connection](release/documentation/connection.md) |
| Choose a native or companion device, recover selection, or program buttons and indicators | [Device Setup](release/documentation/device-setup.md) |
| Connect a paddle to an existing Control4 light or group | [Connected lighting](release/documentation/connected-control4-lighting.md) |
| Review the exact Quick Setup and switch migration steps in Composer | [Coordinator Documentation](release/drivers/coordinator/www/documentation/index.md) |
| Check the current release channel and update behavior | [Driver releases](release/documentation/build.md#check-for-a-driver-release) |
| See which checks ran on HA, Director and physical hardware | [Qualification](release/documentation/first-demo-packages.md) |

The archive includes the installer references and the qualification summary.
Engineering source, test inputs and lab receipts cited by those manuals are
kept with the project. For public source and test documentation, use the same
release tag in the [Control4-HA repository](https://github.com/skialpine/Control4-HA/releases).

Use an assistant that loads Agent Skills, such as Codex or Claude Code. To
inspect or configure Home Assistant from the assistant, connect an
[HA-MCP server](https://github.com/homeassistant-ai/ha-mcp) to the intended HA
instance using its documented client setup. The connector's credentials and
the Coordinator's Home Assistant token are configured separately. With no HA
connection, use the manuals for guidance and ask the user for the verified
settings and readback. A Control4 connection is optional for guidance.
Composer Pro and a Control4 installer are required when an installation or
project operation has no supported connected tool.

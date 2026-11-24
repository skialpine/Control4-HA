require("c4_shim")
local T = require("testlib")
local F = require("c4_fixtures")
local Installer = require("ha.release-install")
local ids = require("ha.identities")
local light, switch, coordinator = ids.packages.light, ids.packages.switch, ids.packages.coordinator
local sandbox, root = ShimFiles("SANDBOX"), ShimFiles("C4Z_ROOT")
local previous, target = 2026112107, 2026112108
local versions, liveVersions, rows, ownVersion
local function setup()
  for key in pairs(sandbox) do
    sandbox[key] = nil
  end
  Properties = {}
  versions = { [10] = previous, [11] = previous, [20] = previous, [40] = previous }
  liveVersions = { [10] = previous, [11] = previous, [20] = previous }
  ownVersion = previous
  rows = {
    [light.file] = { [10] = light, [11] = light },
    [switch.file] = { [20] = switch },
    [coordinator.file] = { [40] = coordinator },
  }
  local assets = {}
  for name, devices in pairs(rows) do
    root[name] = "previous " .. name
    local members = {}
    for id in pairs(devices) do
      members[id] = previous
    end
    assets[#assets + 1] = { name = name, instances = members, body = "qualified " .. name }
  end
  return { revision = target, prerelease = false, assets = assets }
end

ShimSetUIRequest(function(device, request)
  assert(request == "HA_SUITE_RUNNING_VERSION")
  local version = liveVersions[device]
  return version and "<version>" .. version .. "</version>"
end)

function C4:GetDevicesByC4iName(filename)
  return rows[filename]
end

function C4:GetDeviceData(id, key)
  for _, devices in pairs(rows) do
    if devices[id] then
      return key == "version" and versions[id] or devices[id].model
    end
  end
end

function C4:GetDeviceID()
  return 40
end

function C4:GetDriverConfigInfo(key)
  if key == "version" then
    return ownVersion
  end
end

local function sent(tcp)
  local names = {}
  for _, request in ipairs(tcp.writes) do
    names[#names + 1] = request:match("([%w_.]+%.c4z)")
  end
  return names
end

local function newInstaller()
  return Installer.new(function()
    return Properties["CA Certificate Path"] ~= nil and Properties["CA Certificate Path"] ~= ""
  end)
end

T.section("one owner, protected local trust and exact inventory")
local result = setup()
local installer = newInstaller()
Properties["CA Certificate Path"] = "./fixture-ca.pem"
T.eq("driver-local trust blocks replacement", installer:prepare(result), false)
T.eq("the Coordinator file is unchanged", root[coordinator.file], "previous " .. coordinator.file)
Properties["CA Certificate Path"] = ""
rows[coordinator.file][39], versions[39] = coordinator, previous
T.eq("a second Coordinator cannot stage packages", installer:prepare(result), false)
rows[coordinator.file][39] = nil
rows[coordinator.file][41], versions[41] = coordinator, previous
T.eq("the owner cannot replace a shared Coordinator with unknown trust settings", installer:prepare(result), false)
rows[coordinator.file][41] = nil
versions[10] = target
T.eq("inventory changed since verification", installer:prepare(result), false)
T.eq("there is no pending write", installer:pending(), false)

T.section("all packages staged before installation and exact bytes resumed")
result = setup()
installer = newInstaller()
T.truthy("prepare stages the verified batch", installer:prepare(result))
T.eq("stage leaves installed archive untouched", root[light.file], "previous " .. light.file)
T.eq("stage backs up exact previous bytes", sandbox["previous-" .. switch.file], root[switch.file])
local tcp = F.captureTcpClient({ holdReplies = true })
local status, revision, progress
local replies = 0
local function allowWrites()
  return true
end
local function done(value, number, report)
  replies = replies + 1
  status, revision, progress = value, number, report
end
T.truthy("execute starts the first package", installer:runPending(allowWrites, done))
T.eq("Light is submitted before other packages", sent(tcp), { light.file })
T.eq("Director will read the qualified bytes", root[light.file], "qualified " .. light.file)
versions[10] = target
versions[11] = target
liveVersions[10] = target
tcp.reply()
ShimFireTimers()
T.eq("target metadata does not advance until both running Lights confirm", sent(tcp), { light.file })
versions[11] = previous
liveVersions[11] = target
ShimFireTimers()
T.eq("both live Lights can advance despite lagging metadata", sent(tcp), { light.file, switch.file })
installer:stop()
tcp.restore()
local resumed = newInstaller()
tcp = F.captureTcpClient({ holdReplies = true })
T.truthy("cold restart reads the journal without applying", resumed:runPending(nil, done))
T.eq("read-only restart reports an incomplete suite", status, "attention")
T.eq("read-only restart reports verified and pending packages", progress, {
  completed = { "Light" },
  pending = { "Switch", "Connection" },
})
T.eq("read-only restart sends no reload", sent(tcp), {})
status = nil
T.truthy("explicit check resumes the saved release", resumed:runPending(allowWrites, done))
T.eq("resume keeps already verified Light and resumes Switch", sent(tcp), { switch.file })
Properties["CA Certificate Path"] = "./fixture-ca.pem"
versions[20] = target
liveVersions[20] = target
tcp.reply()
ShimFireTimers()
T.eq(
  "newly configured trust stops before replacing the Coordinator",
  { status, sent(tcp) },
  { "driver_local_trust", { switch.file } }
)
T.eq("the archive that supplies trust is retained", root[coordinator.file], "previous " .. coordinator.file)
T.truthy("the saved release also checks trust on resume", resumed:runPending(allowWrites, done))
T.eq("resume leaves the archive in place while trust depends on it", status, "driver_local_trust")
Properties["CA Certificate Path"] = ""
status = nil
T.truthy("the same release can resume after trust is moved", resumed:runPending(allowWrites, done))
T.eq("Coordinator goes last", sent(tcp), { switch.file, coordinator.file })
T.eq("submitting self-update cannot report success", status, nil)
resumed:stop()
tcp.restore()
versions[40] = target
T.truthy("new metadata alone cannot complete a Coordinator reload", newInstaller():runPending(nil, done))
T.eq("current Lua version remains authoritative for self", status, "attention")
ownVersion = target
T.truthy("the new Coordinator verifies the saved job", newInstaller():runPending(nil, done))
T.eq("all drivers share the target revision", { status, revision }, { "updated", target })
T.eq("successful completion removes the journal", next(sandbox), nil)

T.section("corrupt or externally changed artifacts prevent more writes")
installer = newInstaller()
T.truthy("stage again", installer:prepare(setup()))
root[switch.file] = "external replacement"
tcp = F.captureTcpClient()
T.truthy("inspect the saved operation", installer:runPending(allowWrites, done))
T.eq("external changes stop the entire next attempt", sent(tcp), {})
T.eq(
  "known old and new files remain available",
  sandbox["previous-" .. coordinator.file],
  "previous " .. coordinator.file
)
tcp.restore()

T.section("timeout and a failed replacement leave recoverable bytes")
installer = newInstaller()
T.truthy("stage the batch again", installer:prepare(setup()))
tcp = F.captureTcpClient({ holdReplies = true })
installer:runPending(allowWrites, done)
ShimFireTimers()
T.eq("a missing Director response times out", status, "attention")
T.eq("a timeout never submits the next package", sent(tcp), { light.file })
tcp.restore()
tcp = F.captureTcpClient({ holdReplies = true })
status, revision, progress = nil, nil, nil
local beforeRejection = replies
installer:runPending(allowWrites, done)
tcp.reply('<c4soap name="UpdateProjectC4i" result="0"/>\0')
T.eq("Director rejection completes this attempt once", replies, beforeRejection + 1)
T.eq("Director rejection reports attention immediately", status, "attention")
T.eq(
  "Director rejection leaves every unverified package pending",
  progress.pending,
  { "Light", "Switch", "Connection" }
)
T.eq("Director rejection stops the installation", sent(tcp), { light.file })
tcp.restore()
local write = C4.FileWrite
C4.FileWrite = function(self, handle, count, bytes)
  if bytes == "qualified " .. light.file then
    return -1
  end
  return write(self, handle, count, bytes)
end
tcp = F.captureTcpClient({ holdReplies = true })
installer:runPending(allowWrites, done)
C4.FileWrite = write
T.eq("a failed rewrite restores the saved prior archive", root[light.file], "previous " .. light.file)
T.eq("failed file write is never submitted to Director", sent(tcp), {})
T.truthy("the operation remains available for a later retry", installer:pending())
tcp.restore()

-- A controller interruption can stop FileWrite before the archive exists or
-- after transferring only part of the queued archive.
for _, incomplete in ipairs({ false, "qualified " }) do
  root[light.file] = incomplete or nil
  tcp = F.captureTcpClient({ holdReplies = true })
  local afterCrash = newInstaller()
  local intent = sandbox["writing-" .. light.file]
  C4.FileWrite = function(self, handle, count, bytes)
    if bytes == intent then
      return -1
    end
    return write(self, handle, count, bytes)
  end
  afterCrash:runPending(allowWrites, done)
  C4.FileWrite = write
  T.eq("retry preserves the existing write intent", sandbox["writing-" .. light.file], intent)
  T.eq("saved write intent permits the identical archive after interruption", sent(tcp), { light.file })
  T.eq("the entire archive has been recovered", root[light.file], "qualified " .. light.file)
  afterCrash:stop()
  tcp.restore()
end
root[light.file] = "different archive"
tcp = F.captureTcpClient()
newInstaller():runPending(allowWrites, done)
T.eq("write intent cannot overwrite unrelated bytes", sent(tcp), {})
tcp.restore()

T.finish()

-- Apply one already-qualified release through the template updater.
local updater = require("lib.github-updater")
local codec = require("ha.codec")
local inventory = require("ha.installed-suite")
local ids = require("ha.identities")
local families = require("ha.endpoint-families")
require("lib.utils")

local Installer = {}
Installer.__index = Installer
local JOURNAL = "ha-suite-update.json"
local TIMER = "HA.SuiteUpdate"
local ROOT, STAGING = "C4Z_ROOT", "SANDBOX"
local COORDINATOR = ids.packages.coordinator.file
local ORDER = { ids.packages.light.file, ids.packages.switch.file }
local labels = {
  [ids.packages.light.file] = "Light",
  [ids.packages.switch.file] = "Switch",
  [COORDINATOR] = "Connection",
}
for _, family in ipairs(families.order) do
  local package = families[family]
  ORDER[#ORDER + 1], labels[package.file] = package.file, package.name
end
ORDER[#ORDER + 1] = COORDINATOR
local MAX_BYTES = 4 * 1024 * 1024

local function digest(bytes)
  if type(bytes) == "string" and #bytes > 0 and #bytes <= MAX_BYTES then
    return C4:Hash("SHA256", bytes, { return_encoding = "HEX" }):lower()
  end
end

local function installed()
  local rows = inventory.read()
  if not rows then
    return
  end
  local result = {}
  for _, row in ipairs(rows) do
    result[row.package.file] = row.instances
  end
  return result
end

function Installer.owner()
  local coordinators = installed()
  coordinators = coordinators and coordinators[COORDINATOR]
  local owner
  for device in pairs(coordinators or {}) do
    owner = math.min(owner or device, device)
  end
  return owner
end

function Installer.isOwner()
  local owner = Installer.owner()
  return owner ~= nil and owner == C4:GetDeviceID()
end

local function hasOneCoordinator(running)
  local coordinators = running and running[COORDINATOR]
  local first = coordinators and next(coordinators)
  return first ~= nil and next(coordinators, first) == nil
end

local function withMembers(row, members, revision)
  if not members then
    return nil
  end
  local remaining, current = {}, true
  for device, previous in pairs(row.members) do
    local id = tonumber(device)
    if not id or not members[id] or (members[id] ~= previous and members[id] ~= revision) then
      return nil
    end
    remaining[id] = true
    current = current and members[id] == revision
  end
  for id in pairs(members) do
    if not remaining[id] then
      return nil
    end
  end
  return next(remaining) ~= nil and current
end

local function matchesWriteIntent(row, bytes, qualified, previous)
  if updater:readArchive(STAGING, "writing-" .. row.name) ~= row.old .. ":" .. row.new then
    return false
  end
  -- The template deletes the archive before opening the replacement. A
  -- restart may leave it missing or at any prefix of the attempted write.
  if bytes == nil or bytes == "" then
    return true
  end
  return #bytes < #qualified and qualified:sub(1, #bytes) == bytes
    or #bytes < #previous and previous:sub(1, #bytes) == bytes
end

local function packageRunning(name, members, revision)
  if name == COORDINATOR then
    return tonumber(C4:GetDriverConfigInfo("version")) == revision
  end
  local expected = "<version>" .. revision .. "</version>"
  for device in pairs(members) do
    local ok, reply = pcall(SendUIRequest, device, "HA_SUITE_RUNNING_VERSION", {})
    if not ok or reply ~= expected then
      return false
    end
  end
  return true
end

function Installer.new(usesDriverLocalTrust)
  return setmetatable({ usesDriverLocalTrust = usesDriverLocalTrust }, Installer)
end

function Installer:stop()
  local run = self.run
  self.run = nil
  CancelTimer(TIMER)
  if run and run.cancelReload then
    run.cancelReload()
  end
end

local function readJournal()
  local bytes = updater:readArchive(STAGING, JOURNAL)
  if bytes == nil then
    return nil
  end
  local ok, job = pcall(codec.decode, bytes)
  if
    not ok
    or not codec.isObject(job)
    or not codec.isArray(job.archives)
    or type(job.revision) ~= "number"
    or job.revision ~= math.floor(job.revision)
    or job.revision < 1000000000
    or job.revision > 2147483647
  then
    return false
  end
  local index, previous = {}, 0
  for position, name in ipairs(ORDER) do
    index[name] = position
  end
  for _, row in ipairs(job.archives) do
    local position = codec.isObject(row) and index[row.name]
    if
      not position
      or position <= previous
      or not codec.isObject(row.members)
      or not next(row.members)
      or type(row.old) ~= "string"
      or type(row.new) ~= "string"
    then
      return false
    end
    previous = position
  end
  return previous == #ORDER and job or false
end

function Installer:pending()
  return readJournal() ~= nil
end

function Installer:prepare(result)
  if not Installer.isOwner() or self:pending() then
    return false
  end
  if self.usesDriverLocalTrust and self.usesDriverLocalTrust() then
    return false, "This Coordinator uses a certificate file stored with its driver. Ask your installer to update it."
  end
  local running, assets = installed(), {}
  if not hasOneCoordinator(running) then
    return false, "More than one Home Assistant Coordinator is installed. Ask your installer to update the suite."
  end
  for _, asset in ipairs(result.assets or {}) do
    assets[asset.name] = asset
  end
  local job = { revision = result.revision, prerelease = result.prerelease, archives = codec.array({}) }
  for _, name in ipairs(ORDER) do
    local members, asset = running and running[name], assets[name]
    if (members ~= nil) ~= (asset ~= nil) then
      return false
    end
    if asset then
      local row = { name = name, members = {} }
      for id, rev in pairs(asset.instances) do
        row.members[tostring(id)] = rev
      end
      if withMembers(row, members) == nil then
        return false
      end
      local previous = updater:readArchive(ROOT, name)
      row.old, row.new = digest(previous), digest(asset.body)
      if
        not row.old
        or not row.new
        or not updater:writeArchive(STAGING, "previous-" .. name, previous)
        or not updater:writeArchive(STAGING, "qualified-" .. name, asset.body)
      then
        return false
      end
      job.archives[#job.archives + 1] = row
    end
  end
  return updater:writeArchive(STAGING, JOURNAL, codec.encode(job))
end

-- After restart the Coordinator observes the saved operation. A manual check
-- can resume writes. The other packages are always handled before self.
function Installer:runPending(mayWrite, onDone)
  if self.run or not Installer.isOwner() then
    return false
  end
  local job = readJournal()
  if job == nil then
    return false
  end
  local run = { attempted = {}, checks = {}, verified = {} }
  self.run = run
  local function finish(status)
    if self.run == run then
      self:stop()
      onDone(status, job and job.revision or nil, run.progress)
    end
  end
  local function check()
    if self.run ~= run then
      return
    end
    local running = installed()
    local pending, archives, installedCount = nil, {}, 0
    run.progress = nil
    if not job or not hasOneCoordinator(running) or not Installer.isOwner() then
      return finish("blocked")
    end
    for _ in pairs(running) do
      installedCount = installedCount + 1
    end
    if installedCount ~= #job.archives then
      return finish("blocked")
    end
    local progress = { completed = {}, pending = {} }
    local blocked = false
    for _, row in ipairs(job.archives) do
      local current = withMembers(row, running[row.name], job.revision)
      local bytes = updater:readArchive(ROOT, row.name)
      local onDisk = digest(bytes)
      local qualified = updater:readArchive(STAGING, "qualified-" .. row.name)
      local previous = updater:readArchive(STAGING, "previous-" .. row.name)
      if current == nil or digest(qualified) ~= row.new or digest(previous) ~= row.old then
        blocked = true
      elseif onDisk ~= row.old and onDisk ~= row.new and not matchesWriteIntent(row, bytes, qualified, previous) then
        blocked = true
      end
      archives[row.name] = qualified
      if current ~= nil and onDisk == row.new and not run.verified[row.name] then
        run.verified[row.name] = packageRunning(row.name, running[row.name], job.revision)
      end
      if current ~= nil and onDisk == row.new and run.verified[row.name] then
        progress.completed[#progress.completed + 1] = labels[row.name]
      else
        run.verified[row.name] = nil
        progress.pending[#progress.pending + 1] = labels[row.name]
        pending = pending or row
      end
    end
    run.progress = progress
    if blocked then
      return finish("blocked")
    end
    if not pending then
      if C4:FileSetDir(STAGING) == false then
        return finish("attention")
      end
      C4:FileDelete(JOURNAL)
      if C4:FileExists(JOURNAL) then
        return finish("attention")
      end
      for _, row in ipairs(job.archives) do
        C4:FileDelete("previous-" .. row.name)
        C4:FileDelete("qualified-" .. row.name)
        C4:FileDelete("writing-" .. row.name)
      end
      return finish("updated")
    end
    if not mayWrite then
      return finish("attention")
    end
    local checked, allowed, reason = pcall(mayWrite, job)
    if not checked or not allowed then
      return finish(reason or "attention")
    end
    local name = pending.name
    if name == COORDINATOR and self.usesDriverLocalTrust and self.usesDriverLocalTrust() then
      return finish("driver_local_trust")
    end
    if run.attempted[name] then
      run.checks[name] = (run.checks[name] or 0) + 1
      if run.checks[name] >= 15 then
        return finish("attention")
      end
      SetTimer(TIMER, 1000, check)
      return
    end
    run.attempted[name] = true
    local marker = "writing-" .. name
    local intent = pending.old .. ":" .. pending.new
    if updater:readArchive(STAGING, marker) ~= intent and not updater:writeArchive(STAGING, marker, intent) then
      return finish("attention")
    end
    if not updater:writeArchive(ROOT, name, archives[name]) then
      updater:writeArchive(ROOT, name, updater:readArchive(STAGING, "previous-" .. name))
      return finish("attention")
    end
    SetTimer(TIMER, 20000, function()
      finish("attention")
    end)
    local reload, cancel = ReloadDriverArchive(name, name == COORDINATOR)
    run.cancelReload = cancel
    reload:next(function()
      if self.run == run and name ~= COORDINATOR then
        SetTimer(TIMER, 1000, check)
      end
    end, function()
      finish("attention")
    end)
  end
  check()
  return true
end

return Installer

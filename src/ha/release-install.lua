-- Apply one already-qualified release through the template updater.
local updater = require("lib.github-updater")
local codec = require("ha.codec")
local inventory = require("ha.installed-suite")
local ids = require("ha.identities")

local Installer = {}
Installer.__index = Installer
local JOURNAL = "ha-suite-update.json"
local TIMER = "HA.SuiteUpdate"
local ROOT, STAGING = "C4Z_ROOT", "SANDBOX"
local COORDINATOR = ids.packages.coordinator.file
local ORDER = { ids.packages.light.file, ids.packages.switch.file, COORDINATOR }
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

function Installer.new()
  return setmetatable({}, Installer)
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
  if Properties["Directory Start Path"] == "Driver" then
    for _, name in ipairs({ "CA Certificate Path", "Certificate Path", "Private Key Path" }) do
      local path = Properties[name]
      if type(path) == "string" and path ~= "" then
        return false,
          "This Coordinator uses a certificate file stored with its driver. Ask your installer to update it."
      end
    end
  end
  local running, assets = installed(), {}
  if not hasOneCoordinator(running) then
    return false, "More than one Home Assistant Coordinator is installed. Ask your installer to update the suite."
  end
  for _, asset in ipairs(result.assets or {}) do
    assets[asset.name] = asset
  end
  local job = { revision = result.revision, archives = codec.array({}) }
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

-- After a restart, observe the saved operation. Only an explicitly enabled
-- check may resume writes. The other packages are always handled before self.
function Installer:runPending(allowWrites, onDone)
  if self.run or not Installer.isOwner() then
    return false
  end
  local job = readJournal()
  if job == nil then
    return false
  end
  local run = { attempted = {}, checks = {} }
  self.run = run
  local function finish(status)
    if self.run == run then
      self:stop()
      onDone(status, job and job.revision or nil)
    end
  end
  local function check()
    if self.run ~= run then
      return
    end
    local running = installed()
    local pending, archives, installedCount = nil, {}, 0
    if not job or not hasOneCoordinator(running) or not Installer.isOwner() then
      return finish("blocked")
    end
    for _ in pairs(running) do
      installedCount = installedCount + 1
    end
    if installedCount ~= #job.archives then
      return finish("blocked")
    end
    for _, row in ipairs(job.archives) do
      local current = withMembers(row, running[row.name], job.revision)
      if current and row.name == COORDINATOR then
        current = tonumber(C4:GetDriverConfigInfo("version")) == job.revision
      end
      local bytes = updater:readArchive(ROOT, row.name)
      local onDisk = digest(bytes)
      local qualified = updater:readArchive(STAGING, "qualified-" .. row.name)
      local previous = updater:readArchive(STAGING, "previous-" .. row.name)
      if current == nil or digest(qualified) ~= row.new or digest(previous) ~= row.old then
        return finish("blocked")
      end
      if onDisk ~= row.old and onDisk ~= row.new and not matchesWriteIntent(row, bytes, qualified, previous) then
        return finish("blocked")
      end
      archives[row.name] = qualified
      if not pending and (not current or onDisk ~= row.new) then
        pending = row
      end
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
    if not allowWrites then
      return finish("attention")
    end
    local name = pending.name
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
    local reload, cancel = updater:reloadArchive(name, name == COORDINATOR)
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

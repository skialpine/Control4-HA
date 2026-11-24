-- Running release identity shared by update qualification and migration.
local ids = require("ha.identities")

local M = {}
local packages = {
  { family = "Coordinator", file = ids.packages.coordinator.file, model = ids.packages.coordinator.model },
  { family = "Light", file = ids.packages.light.file, model = ids.packages.light.model, proxy = "light_v2" },
  { family = "Switch", file = ids.packages.switch.file, model = ids.packages.switch.model, proxy = "uibutton" },
}

function M.read()
  local installed, summary = {}, {}
  for _, package in ipairs(packages) do
    local instances = {}
    local low, high
    for key in pairs(C4:GetDevicesByC4iName(package.file) or {}) do
      local device = tonumber(key)
      if
        not device
        or device < 1
        or device ~= math.floor(device)
        or C4:GetDeviceData(device, "model") ~= package.model
      then
        return nil
      end
      local rev = tonumber(C4:GetDeviceData(device, "version"))
      if not rev or rev < 1 or rev > 2147483647 or rev ~= math.floor(rev) then
        return nil
      end
      instances[device] = rev
      low, high = math.min(low or rev, rev), math.max(high or rev, rev)
    end
    if low then
      installed[#installed + 1] = { package = package, low = low, high = high, instances = instances }
      summary[#summary + 1] = package.family .. " " .. (low == high and tostring(low) or low .. "–" .. high)
    end
  end
  return #installed > 0 and installed or nil, table.concat(summary, ", ")
end

-- Inspect the running versions of every installed suite instance, including
-- unbound ones. The replacement and Coordinator must both be in this set.
local function aligned(coordinatorId, replacement, family)
  local inventory = M.read()
  local revision, coordinator, child
  for _, row in ipairs(inventory or {}) do
    if row.low ~= row.high or #tostring(row.high) ~= 10 or (revision and revision ~= row.high) then
      return nil
    end
    revision = row.high
    coordinator = coordinator
      or (row.package.family == "Coordinator" and (not coordinatorId or row.instances[coordinatorId] ~= nil))
    child = child
      or (row.package.family == (family == "light" and "Light" or "Switch") and row.instances[replacement] ~= nil)
  end
  return coordinator and (not replacement or child) and revision or nil
end

function M.migrationRevision(replacement)
  return aligned(nil, replacement)
end

function M.upgradeRevision(coordinator, replacement, family)
  return aligned(coordinator, replacement, family)
end

return M

-- Fresh Control4 inventory and exact project matching for explicit deployment.
local contract = require("ha.contract")
local ids = require("ha.identities")
local assessment = require("ha.migration-assessment")
local M = {}
local light, interimLight, switch = ids.packages.light, ids.packages.interimLight, ids.packages.switch
local packages = { [light.file] = light, [interimLight.file] = interimLight, [switch.file] = switch }
local projectFiles = table.concat({ light.file, interimLight.file, switch.file, "HA.Switch.c4z" }, ",")

function M.file(family)
  local package = (family == "light" or family == "switch") and ids.packages[family]
  return package and package.file
end

function M.lightPackageReady(devices)
  -- AddDevice resolves by filename. Existing legacy/opaque rows under that
  -- name require an update unless a positively identified suite row exists.
  local found = false
  for _, device in ipairs(devices) do
    if device.file == light.file then
      if device.family == "light" and not device.legacy then
        return true
      end
      found = true
    end
  end
  return not found
end

function M.rooms()
  local rooms = {}
  for key, name in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    local id = tonumber(key)
    if contract.integer(id) and type(name) == "string" and name ~= "" then
      rooms[#rooms + 1] = { id = id, name = name }
    end
  end
  table.sort(rooms, function(a, b)
    return a.name == b.name and a.id < b.id or a.name < b.name
  end)
  return rooms
end

local function stringVariable(id, name)
  local selected
  for _, item in pairs(C4:GetDeviceVariables(id) or {}) do
    if item.name == name then
      if selected ~= nil or (item.type ~= "STRING" and item.type ~= "1") or type(item.value) ~= "string" then
        return nil, true
      end
      selected = item.value
    end
  end
  return selected
end

local function identified(id, row)
  local package = packages[row.driverFileName]
  if not package or C4:GetDeviceData(id, "model") ~= package.model then
    return nil
  end
  local input, binding = contract.consumerInput(id)
  local expected = package == light and ids.lightCoordinatorBinding or ids.coordinatorBinding
  if input ~= expected then
    return nil
  end
  local provider = tonumber(C4:GetBoundProviderDevice(id, input))
  if provider ~= 0 then
    -- Missing, one-directional or foreign-looking ownership is never free.
    provider = contract.provider(id) or false
  elseif binding.isbound or (binding.boundprovider and binding.boundprovider.bound) then
    provider = false
  end
  return {
    id = id,
    file = package.file,
    input = input,
    family = package == switch and "switch" or "light",
    room_id = tonumber(row.roomId),
    name = row.deviceName,
    selected = stringVariable(id, "Selected Endpoint"),
    provider = provider,
  }
end

local function legacySelection(id)
  local ok, variable, invalid = pcall(stringVariable, id, "ENTITY_ID")
  local fromVariable = ok and variable or nil
  local readable, properties = pcall(GetDeviceProperties, id)
  local fromProperty = readable and type(properties) == "table" and properties["Entity ID"] or nil
  if invalid or (fromProperty and fromVariable and fromProperty ~= fromVariable) then
    return nil
  end
  local entity = fromProperty or fromVariable
  return (entity == "" or contract.entity(entity)) and entity or nil
end

local function legacyDevice(id, row, origin)
  local binding = GetDeviceBindings(id, nil, false, nil, ids.legacyCoordinatorClass)[ids.lightCoordinatorBinding]
  local provider = binding and tonumber(C4:GetBoundProviderDevice(id, ids.lightCoordinatorBinding))
  return {
    id = id,
    file = row.driverFileName,
    family = origin.family,
    room_id = tonumber(row.roomId),
    name = row.deviceName,
    selected = binding and legacySelection(id) or nil,
    legacy = true,
    legacy_provider = provider,
    -- A legacy binding describes the old project device. Only identified
    -- suite consumers can establish ownership or resume a previous add.
    provider = false,
  }
end

function M.device(id)
  local rows = C4:GetDevices({ DeviceIds = tostring(id) }) or {}
  local row = rows[id] or rows[tostring(id)]
  return row and not assessment.source(id, row) and identified(id, row) or nil
end

function M.inventory()
  local devices = {}
  local found = C4:GetDevices({ C4iNames = projectFiles })
  assert(type(found) == "table")
  for raw, row in pairs(found) do
    local id = tonumber(raw)
    if
      contract.integer(id)
      and (packages[row.driverFileName] or row.driverFileName == "HA.Switch.c4z")
      and not (type(row.protocol) == "table" and next(row.protocol))
    then
      local origin = assessment.source(id, row)
      local device = origin and legacyDevice(id, row, origin) or identified(id, row)
      devices[#devices + 1] = device
        or { id = id, file = row.driverFileName, room_id = tonumber(row.roomId), name = row.deviceName }
    end
  end
  return devices
end

function M.roomName(rooms, id)
  for _, room in ipairs(rooms) do
    if room.id == id then
      return room.name
    end
  end
end

function M.matches(device, item)
  return device.family == item.family and device.room_id == item.room_id and device.name == item.name
end

function M.roomAndName(device)
  if contract.integer(device.room_id) and type(device.name) == "string" then
    return device.room_id .. "\n" .. device.name:lower()
  end
end

function M.unfinished(candidate, receipt, coordinator, selectedKeys)
  return candidate
    and not candidate.legacy
    and M.matches(candidate, receipt)
    and (candidate.provider == 0 or candidate.provider == coordinator)
    and (
      candidate.selected == ""
      or receipt.phase == "added"
        and candidate.id == receipt.device_id
        and selectedKeys
        and selectedKeys[candidate.selected]
    )
end

function M.decide(item, devices, receipt, coordinator)
  local selected, named, unreadable, recorded = {}, {}, {}, nil
  local roomAndName = M.roomAndName(item)
  for _, device in ipairs(devices) do
    if device.selected == nil then
      unreadable[#unreadable + 1] = device
    elseif item.keys[device.selected] or (device.legacy and device.selected == item.legacy_gesture) then
      selected[#selected + 1] = device
    end
    if M.roomAndName(device) == roomAndName then
      named[#named + 1] = device
    end
    if receipt and device.id == receipt.device_id then
      recorded = device
    end
  end
  local match = selected[1]
  if #selected > 1 then
    return "review", nil, "multiple_matches"
  elseif match then
    if match.legacy then
      return "review", match.id, "legacy_" .. match.family .. "_match"
    elseif match.family == item.family and match.provider == coordinator then
      if receipt and (receipt.device_id ~= match.id or receipt.phase ~= "complete") then
        if receipt.device_id ~= match.id then
          return "review", nil, "unresolved_add"
        end
        return "resume", match.id
      end
      return "keep", match.id
    elseif recorded == match and match.family == item.family and match.provider == 0 then
      return "resume", match.id
    end
    return "review", match.id, "different_device_or_coordinator"
  elseif receipt then
    if receipt.phase == "complete" and not recorded and #named == 0 and #unreadable == 0 then
      -- A completed add can be requested again after the installer removes it.
      -- Director can still report a live connection while the device is absent from inventory.
      local remaining = C4:GetDevices({ DeviceIds = tostring(receipt.device_id) })
      local bound = C4:GetBoundConsumerDevices(coordinator, ids.coordinatorBinding) or {}
      if
        type(remaining) == "table"
        and next(remaining) == nil
        and not bound[receipt.device_id]
        and not bound[tostring(receipt.device_id)]
        and tonumber(C4:GetBoundProviderDevice(receipt.device_id, ids.coordinatorBinding)) == 0
        and (
          receipt.family ~= "light"
          or tonumber(C4:GetBoundProviderDevice(receipt.device_id, ids.lightCoordinatorBinding)) == 0
        )
      then
        return "add"
      end
    end
    local candidate = recorded or (receipt.phase == "pending" and #named == 1 and named[1])
    if receipt.phase ~= "complete" and M.unfinished(candidate, receipt, coordinator) and M.matches(receipt, item) then
      return "resume", candidate.id, not recorded and "recovered_candidate" or nil
    end
    return "review", nil, "unresolved_add"
  elseif #unreadable == 1 and unreadable[1].legacy and (#named == 0 or (#named == 1 and named[1] == unreadable[1])) then
    return "review", unreadable[1].id, "legacy_" .. unreadable[1].family .. "_unconfirmed"
  elseif #named > 0 then
    return "review", nil, "name_in_use"
  elseif #unreadable > 0 then
    return "review", nil, "project_identity_unreadable"
  end
  return "add"
end

return M

-- Fresh Control4 inventory and exact project matching for explicit deployment.
local contract = require("ha.contract")
local ids = require("ha.identities")
local families = require("ha.endpoint-families")
local assessment = require("ha.migration-assessment")
local legacyProfile = require("ha.legacy-driver-profile")
local legacyEndpoints = require("ha.legacy-endpoints")
local selection = require("ha.migration-selection")
local prototype = require("ha.prototype-selection")
local deferred = require("deferred")
require("lib.utils")
local M = {}
local light, interimLight, switch = ids.packages.light, ids.packages.interimLight, ids.packages.switch
local packages = { [light.file] = "light", [interimLight.file] = "interimLight", [switch.file] = "switch" }
local files = { light.file, interimLight.file, switch.file, "HA.Switch.c4z" }
for _, family in ipairs(families.order) do
  local file = families[family].file
  packages[file], files[#files + 1] = family, file
end
local projectFiles = table.concat(files, ",")

function M.file(family)
  local package = contract.family(family) and ids.packages[family]
  return package and package.file
end

function M.stageMissingPackage(family)
  local file = M.file(family)
  local inspected, exists = pcall(function()
    UnlockC4ZRoot()
    assert(C4:FileSetDir("C4Z_ROOT") ~= false)
    return C4:FileExists(file)
  end)
  if not inspected or exists or next(C4:GetDevicesByC4iName(file) or {}) then
    -- Director can still use its existing files when it denies driver-store
    -- access. Keep established project drivers on the normal update path.
    return deferred.new():resolve(true)
  end
  return InstallDrivers({ { name = file } }):next(function(installed)
    return installed[1] == file
  end)
end

function M.requiresPackageCheck(family)
  local package = ids.packages[family]
  return package and (family == "light" or package.retainsLegacyInput) or false
end

function M.retainedPackageReady(family, devices)
  -- AddDevice resolves by filename. Existing legacy/opaque rows under that
  -- name require an update unless a positively identified suite row exists.
  local found = false
  for _, device in ipairs(devices) do
    if device.file == M.file(family) then
      if device.family == family and not device.legacy then
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

local function identified(id, row, outputs)
  local family = packages[row.driverFileName]
  local package = ids.packages[family]
  if not package or C4:GetDeviceData(id, "model") ~= package.model then
    return nil
  end
  local input, provider = contract.consumerBinding(id, outputs)
  local expected = (package == light or package.retainsLegacyInput) and ids.lightCoordinatorBinding
    or ids.coordinatorBinding
  if input ~= expected then
    return nil
  end
  return {
    id = id,
    file = package.file,
    input = input,
    family = family == "interimLight" and "light" or family,
    room_id = tonumber(row.roomId),
    room = row.roomName,
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
  local mode = readable and type(properties) == "table" and prototype.mode(properties["Operation Mode"]) or nil
  if invalid or (fromProperty and fromVariable and fromProperty ~= fromVariable) then
    return nil
  end
  local entity = fromProperty or fromVariable
  return (entity == "" or contract.entity(entity)) and entity or nil, mode
end

local function legacyDevice(id, row, origin)
  local binding = GetDeviceBindings(id, nil, false, nil, ids.legacyCoordinatorClass)[ids.lightCoordinatorBinding]
  local provider = binding and tonumber(C4:GetBoundProviderDevice(id, ids.lightCoordinatorBinding))
  local selected, mode
  if binding then
    selected, mode = legacySelection(id)
  end
  return {
    id = id,
    file = row.driverFileName,
    family = origin.family,
    room_id = tonumber(row.roomId),
    room = row.roomName,
    name = row.deviceName,
    selected = selected,
    legacy = true,
    legacy_mode = mode,
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

local function additionalLegacyDevice(id, row)
  local report = assessment.assess(id, { skipPrograms = true, skipLighting = true })
  local provider = report and report.interfaces and legacyProfile.gateway(report) or nil
  return {
    id = id,
    name = row.deviceName,
    room = row.roomName,
    room_id = tonumber(row.roomId),
    file = row.driverFileName,
    family = report and report.family,
    selected = provider == 0 and "" or provider and report.entity or nil,
    legacy_provider = provider,
    legacy = true,
    provider = false,
  }
end

function M.inventory(includeAdditionalLegacy)
  local devices, outputs = {}, {}
  local names = includeAdditionalLegacy
      and (projectFiles .. "," .. legacyProfile.files() .. "," .. legacyEndpoints.files())
    or projectFiles
  local found = C4:GetDevices({ C4iNames = names })
  assert(type(found) == "table")
  for raw, row in pairs(found) do
    local id = tonumber(raw)
    if contract.integer(id) and not (type(row.protocol) == "table" and next(row.protocol)) then
      local legacy = includeAdditionalLegacy and legacyEndpoints.inspect(id, row.driverFileName)
      if legacy then
        legacy.id, legacy.file, legacy.name = id, row.driverFileName, row.deviceName
        legacy.room_id, legacy.room = tonumber(row.roomId), row.roomName
        devices[#devices + 1] = legacy
      elseif packages[row.driverFileName] or row.driverFileName == "HA.Switch.c4z" then
        local origin = assessment.source(id, row)
        local device = origin and legacyDevice(id, row, origin) or identified(id, row, outputs)
        devices[#devices + 1] = device
          or { id = id, file = row.driverFileName, room_id = tonumber(row.roomId), name = row.deviceName }
      elseif includeAdditionalLegacy and legacyProfile.contains(row.driverFileName) then
        devices[#devices + 1] = additionalLegacyDevice(id, row)
      end
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

function M.buttonMatch(device, choice, coordinator)
  if
    not choice
    or device.legacy
    or device.provider ~= coordinator
    or type(device.selected) ~= "string"
    or device.selected:match("^device:([a-f0-9]+):[a-f0-9]+$") ~= choice.device_id
  then
    return false
  end
  local current = selection.read(device.id)
  return current
    and current.stable
    and current.buttons
    and current.key == device.selected
    and current.device == choice.device_id
    and current.gesture == choice.gesture_entity_id
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
  local buttonMatches = {}
  local roomAndName = M.roomAndName(item)
  for _, device in ipairs(devices) do
    if not device.other_installation then
      if device.selected == nil then
        local family = families[device.family]
        if not device.review_only or device.family == item.family or family and family.domain == item.domain then
          unreadable[#unreadable + 1] = device
        end
      elseif
        item.keys[device.selected]
        or (device.legacy and device.selected == item.legacy_gesture)
        or (device.selected == item.gesture_match and (device.provider == coordinator or device.provider == 0))
      then
        selected[#selected + 1] = device
      elseif M.buttonMatch(device, item.button_choice, coordinator) then
        selected[#selected + 1] = device
        buttonMatches[device] = true
      end
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
    elseif buttonMatches[match] or not item.keys[match.selected] and match.selected == item.gesture_match then
      -- A shared physical control accounts for the button device in the
      -- picker, but does not establish that the installed driver owns its load.
      return "review", match.id, "button_device_match"
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
    if
      (receipt.phase == "added" or receipt.phase == "complete")
      and not recorded
      and #named == 0
      and #unreadable == 0
    then
      -- A known add can be requested again after the installer removes it, even if setup was interrupted.
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
  elseif
    #unreadable == 1
    and unreadable[1].legacy
    and unreadable[1].family
    and (#named == 0 or (#named == 1 and named[1] == unreadable[1]))
  then
    return "review", unreadable[1].id, "legacy_" .. unreadable[1].family .. "_unconfirmed"
  elseif #named > 0 then
    return "review", nil, "name_in_use"
  elseif #unreadable > 0 then
    return "review", nil, "project_identity_unreadable"
  end
  return "add"
end

return M

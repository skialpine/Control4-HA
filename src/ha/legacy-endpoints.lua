-- Read-only candidate identities. Detection never grants a migration or service lease.
local ids = require("ha.identities")
local contract = require("ha.contract")
local legacy = require("ha.legacy-driver-profile")
local M = {}
local originals = {}
local function original(family, model, versions, files)
  local row = { family = family, model = model, versions = versions, manufacturer = "BP" }
  for _, file in ipairs(files or { model:gsub(" ", ".") .. ".c4z" }) do
    originals[file] = row
  end
end
original("alarm_control_panel", "HA Alarm Panel", { ["101"] = true, ["102"] = true })
original("binary_sensor", "HA Binary Sensor", { ["102"] = true })
original("blinds", "HA Blinds", { ["102"] = true })
original("fan", "HA Fan", { ["102"] = true, ["104"] = true })
original("fan", "HA Fan", { ["103"] = true }, {
  "HA.Fan.3-speed.c4z",
  "HA.Fan.4-speed.c4z",
  "HA.Fan.5-speed.c4z",
  "HA.Fan.6-speed.c4z",
})
original("fan", "HA Fan", { ["104"] = true }, { "HA.Fan.9-speed.c4z" })
original("garage", "HA Garage Door", { ["101"] = true })
original("sensor", "HA Generic Sensor", { ["110"] = true })
original("lock", "HA Lock", { ["102"] = true })
original("media_player", "HA Media Player", { ["102"] = true })
original("climate", "HA Thermostat", { ["108"] = true })

local function external(suffix, family, model, manufacturer)
  originals["chowmain_homeassistant_" .. suffix .. ".c4z"] = {
    family = family,
    model = model,
    manufacturer = manufacturer or "Home Assistant",
    versions = { ["20261008"] = true },
    separateGateway = true,
  }
end
external("alarm", "alarm_control_panel", "Home Assistant Alarm Control Panel", "Chowmain")
external("binarysensor", "binary_sensor", "Home Assistant Binary Sensor")
external("blind", "blinds", "Home Assistant Blind")
external("climate", "climate", "Home Assistant Climate")
external("lock", "lock", "Home Assistant Lock")
external("sensor", "sensor", "Home Assistant Sensor")
external("media_player_androidtv", "media_player", "Home Assistant Media Player - AndroidTV", "Chowmain")
external("media_player_appletv", "media_player", "Home Assistant Media Player - AppleTV", "Chowmain")
for count = 2, 6 do
  external("fan_" .. count .. "_speed", "fan", "Home Assistant", "Chowmain")
end

function M.files()
  local matches = {}
  for file in pairs(originals) do
    matches[#matches + 1] = file
  end
  table.sort(matches)
  return table.concat(matches, ",")
end

function M.inspect(id, file)
  local profile = originals[file]
  if not profile then
    return nil
  end
  local model = C4:GetDeviceData(id, "model")
  local version = C4:GetDeviceData(id, "version")
  if
    type(model) ~= "string"
    or model:match("^%s*(.-)%s*$") ~= profile.model
    or not profile.versions[tostring(version)]
    or C4:GetDeviceData(id, "manufacturer") ~= profile.manufacturer
  then
    return nil
  end
  local scope = ids.packages[profile.family]
  local ok, properties = pcall(GetDeviceProperties, id)
  local entity = ok and type(properties) == "table" and properties["Entity ID"]
  if profile.separateGateway and ok and type(properties) == "table" then
    local selected = properties["Entity ID Selected"]
    if contract.endpointDomain(selected) and contract.endpointDomain(entity) and selected ~= entity then
      entity = nil
    elseif contract.endpointDomain(selected) then
      entity = selected
    end
  end
  local provider
  if profile.separateGateway then
    provider = legacy.gatewayAt(id, 5)
  else
    local input = GetDeviceBindings(id, nil, false, nil, ids.legacyCoordinatorClass)[ids.lightCoordinatorBinding]
    local peer = input and tonumber(C4:GetBoundProviderDevice(id, ids.lightCoordinatorBinding))
    provider = peer == 0 and not input.isbound and 0
      or (peer == C4:GetDeviceID() and tonumber(Select(input, "boundprovider", "bound", "deviceid")) == peer and peer)
      or nil
  end
  return {
    selected = provider == 0 and "" or contract.endpointDomain(entity) == scope.domain and entity or nil,
    family = profile.family,
    legacy = true,
    review_only = true,
    legacy_gateway_profile = profile.separateGateway,
    legacy_provider = provider,
    provider = false,
  }
end

return M

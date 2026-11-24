-- Declared interfaces for legacy HA drivers that require staged replacement.
local ids = require("ha.identities")
local contract = require("ha.contract")
local Connection = require("ha.connection")

local input = { class = "HOMEASSISTANT_DEVICES", name = "Home Assistant connection", provider = false }
local lightRoles = {
  [5] = input,
  [5001] = { class = "LIGHT_V2", name = "Light", provider = true },
}
for _, aspect in ipairs({ { "Brightness", 81 }, { "White temperature", 82 }, { "Hue", 83 } }) do
  for _, action in ipairs({ { "off", 0 }, { "on", 5 }, { "toggle", 10 } }) do
    lightRoles[aspect[2] + action[2]] = { class = "BUTTON_LINK", name = aspect[1] .. " " .. action[1], provider = true }
  end
end

local profiles = {
  ["chowmain_homeassistant_light.c4z"] = {
    family = "light",
    model = "Home Assistant Light",
    manufacturer = "Home Assistant",
    version = "20261008",
    proxy = "light_v2.c4i",
    input = 5,
    bindings = lightRoles,
    events = { [1] = ids.lightUnavailableEvent },
  },
  ["chowmain_homeassistant_switch.c4z"] = {
    family = "switch",
    model = "Home Assistant Switch",
    manufacturer = "Home Assistant",
    version = "20261008",
    proxy = "uibutton.c4i",
    input = 5,
    bindings = {
      [5] = input,
      [10] = { class = "RELAY", name = "Relay", provider = true, new = ids.relay },
      [5001] = { class = "UIBUTTON", name = "Switch", provider = true },
    },
    events = { [1] = ids.events.stateOn, [2] = ids.events.stateOff, [3] = ids.events.unavailable },
  },
}

local M = {}
local gatewayFile = "chowmain_homeassistant_gateway.c4z"

function M.contains(filename)
  return profiles[filename] ~= nil
end

function M.forSource(source)
  return source and source.origin == "Legacy HA" and profiles[source.file] or nil
end

-- The old gateway link is a separate connection from the suite Coordinator.
-- A missing or inconsistent edge cannot prove that the old load is detached.
function M.gateway(source)
  local profile = M.forSource(source)
  if not profile then
    return
  end
  local id, input = source.id, profile.input
  local rows = GetDeviceBindings(id, nil, false, nil, "HOMEASSISTANT_DEVICES")
  local row = type(rows) == "table" and rows[input]
  if not row or tonumber(row.deviceid) ~= id then
    return
  end
  local peer = Select(row, "boundprovider", "bound")
  local bound = tonumber(C4:GetBoundProviderDevice(id, input))
  if bound == 0 and not peer and not row.isbound then
    return 0
  end
  if
    not contract.integer(bound)
    or tonumber(Select(peer, "deviceid")) ~= bound
    or tonumber(Select(peer, "bindingid")) ~= 5
  then
    return
  end
  local gateways = C4:GetDevicesByC4iName(gatewayFile) or {}
  if gateways[bound] or gateways[tostring(bound)] then
    return bound
  end
end

function M.networkAddresses()
  local ok, addresses = pcall(function()
    -- Director exposes the live gateway address here. Project XML returned by
    -- DriverWorks can omit the network bindings present in a Composer backup.
    local connections = C4:GetNetworkConnections()
    assert(type(connections) == "table")
    local result, remaining = {}, 4096
    local function collect(row, depth)
      if type(row) ~= "table" or depth == 0 then
        return
      end
      local device = tonumber(row.deviceid)
      if not contract.integer(device) or not tonumber(row.bindingid) then
        for _, child in pairs(row) do
          remaining = remaining - 1
          assert(remaining >= 0)
          collect(child, depth - 1)
        end
      elseif tonumber(row.bindingid) == 6000 then
        local address = row.address
        local valid = type(address) == "string" and #address <= 253 and address:match("^[%w%.%-]+$")
        result[device] = result[device] == nil and valid or false
      end
    end
    collect(connections, 4)
    return result
  end)
  return ok and addresses or {}
end

function M.canonicalOrigin(url)
  local authority, scheme = Connection.authority(url)
  if authority then
    local host, port = authority:match("^([^:]+):(%d+)$")
    return scheme
      .. "://"
      .. (host or authority):lower()
      .. ":"
      .. (tonumber(port) or (scheme == "https" and 443 or 80))
  end
end

function M.gatewayOrigin(gateway, addresses)
  local address = addresses[gateway]
  local ok, properties = pcall(GetDeviceProperties, gateway)
  if not address or not ok or type(properties) ~= "table" then
    return nil
  end
  local port = tonumber(properties.Port)
  local tls = properties["Use SSL"]
  if not port or port ~= math.floor(port) or (tls ~= "True" and tls ~= "False") then
    return nil
  end
  return M.canonicalOrigin((tls == "True" and "https://" or "http://") .. address .. ":" .. port)
end

function M.identify(filename, model, manufacturer, version)
  local profile = profiles[filename]
  if
    profile
    and type(model) == "string"
    and model:match("^%s*(.-)%s*$") == profile.model
    and manufacturer == profile.manufacturer
    and tostring(version) == profile.version
  then
    return profile
  end
end

function M.files()
  local result = {}
  for filename in pairs(profiles) do
    result[#result + 1] = filename
  end
  table.sort(result)
  return table.concat(result, ",")
end

function M.selection(properties, family)
  if type(properties) ~= "table" then
    return
  end
  local mode = properties["Device Address Selection"]
  local manual, automatic = properties["Entity ID"], properties["Entity ID Selected"]
  if automatic == "[No Devices Selected]" then
    automatic = nil
  end
  local name
  if type(automatic) == "string" and #automatic <= 512 then
    local id, label = automatic:match("^%[([a-z_]+%.[a-z0-9_]+)%]%s+(.+)$")
    if id then
      automatic = id
      name = #label <= 160 and not label:find("%c") and label or nil
    end
  end
  local value = mode == "Manual" and manual or mode == "Automatic" and automatic or nil
  local domain = contract.loadDomain(value)
  if domain and (family == "light" or domain == "switch" or domain == "input_boolean") then
    if mode == "Manual" and automatic ~= nil and automatic ~= "" and automatic ~= value then
      return nil, true
    end
    return value, nil, name
  end
end

local lightTypes = {
  ["Auto Detect"] = "Automatic",
  ["On/Off Only"] = "On/off",
  Dimmable = "Dimmable",
  ["Dimmable (CCT)"] = "Dimmable with white temperature",
  ["Color Only"] = "Color",
  ["Color / CCT"] = "Color and white temperature",
}

function M.lightSettings(properties)
  if type(properties) ~= "table" then
    return
  end
  local kind, format = lightTypes[properties["Light Type"]], properties["Preferred Color Mode"]
  local low = tonumber(properties["Color Temperature (K) - Minimum"])
  local high = tonumber(properties["Color Temperature (K) - Maximum"])
  if
    kind
    and (format == "HS" or format == "RGB" or format == "XY")
    and low
    and high
    and low >= 1000
    and high <= 9000
    and low < high
    and low == math.floor(low)
    and high == math.floor(high)
  then
    return { kind = kind, format = format, minK = low, maxK = high }
  end
end

return M

-- Optional HA adapter settings. Native Light settings remain owned by lib.light.
local persist = require("lib.persist")
local codec = require("ha.codec")
local contract = require("ha.contract")
local Color = require("lib.light.color")
local capabilities = require("ha.light-capabilities")

local key = "HA.LightCompatibility.v2"
local legacyKey = "HA.LightCompatibility.v1"
local automatic = "Automatic"
local types =
  { automatic, "On/off", "Dimmable", "Dimmable with white temperature", "Color", "Color and white temperature" }
local modes = { automatic, "HS", "RGB", "XY" }
local typeFacts = {
  ["On/off"] = {},
  Dimmable = { dims = true },
  ["Dimmable with white temperature"] = { dims = true, temperature = true },
  Color = { dims = true, color = true },
  ["Color and white temperature"] = { dims = true, color = true, temperature = true },
}
local fields = {
  {
    name = "Light type override",
    key = "kind",
    choices = types,
    description = "Use Automatic unless the device reports the wrong light type.",
  },
  {
    name = "Color format override",
    key = "format",
    choices = modes,
    description = "Choose the format sent to Home Assistant for color changes.",
  },
  {
    name = "White temperature limits (K)",
    key = "range",
    description = "Enter a range such as 2700-6500. Clear it to use the device limits.",
  },
}

local M = {}

local function inRange(value, low, high)
  return type(value) == "number" and value >= low and value <= high
end

function M.nativeRange(attrs)
  local min, max = attrs.min_color_temp_kelvin, attrs.max_color_temp_kelvin
  if min == nil and max == nil then
    if inRange(attrs.min_mireds, 10, 1000000) and inRange(attrs.max_mireds, attrs.min_mireds, 1000000) then
      min, max = Color.miredsToKelvin(attrs.max_mireds), Color.miredsToKelvin(attrs.min_mireds)
    end
  end
  if inRange(min, 1, 99999) and inRange(max, min, 99999) then
    return { minK = math.floor(min + 0.5), maxK = math.floor(max + 0.5) }
  end
end

function M.range(raw)
  local low, high
  if type(raw) == "string" then
    low, high = raw:match("^%s*(%d%d%d%d)%s*%-%s*(%d%d%d%d)%s*$")
  end
  low, high = tonumber(low), tonumber(high)
  if low and high and low >= 1000 and high <= 9000 and low < high then
    return { minK = low, maxK = high }
  end
end

local function readOverrides(storage)
  local current = codec.storedObject(storage:get(key))
  if current then
    return current
  end
  local legacy = codec.storedObject(storage:get(legacyKey))
  local overrides = codec.object({})
  if legacy and contract.loadDomain(legacy.entity) == "light" and (legacy.kind or legacy.format or legacy.range) then
    overrides[legacy.entity] = codec.object({ kind = legacy.kind, format = legacy.format, range = legacy.range })
  end
  return overrides
end

function M.read(entity)
  local saved = readOverrides(persist)[entity]
  return codec.isObject(saved) and saved or {}
end

function M.kind(saved)
  return typeFacts[saved.kind]
end

local function validMigration(entity, settings)
  if contract.loadDomain(entity) ~= "light" or not codec.isObject(settings) then
    return false
  end
  local kind = M.kind(settings)
  if not kind then
    return false
  end
  local format = settings.format
  if kind.color and format ~= "HS" and format ~= "RGB" and format ~= "XY" then
    return false
  end
  if kind.temperature and not M.range(settings.range) then
    return false
  end
  for field in pairs(settings) do
    if field ~= "kind" and not (field == "format" and kind.color) and not (field == "range" and kind.temperature) then
      return false
    end
  end
  return true
end

function M.migrationSettings(entity, source)
  if type(source) ~= "table" then
    return
  end
  local kind = M.kind(source)
  if not kind then
    return
  end
  local settings = codec.object({
    kind = source.kind,
    format = kind.color and source.format or nil,
    range = kind.temperature and (tostring(source.minK) .. "-" .. tostring(source.maxK)) or nil,
  })
  if validMigration(entity, settings) then
    return settings
  end
end

function M.migrationFeedback(entity, settings, state)
  if
    not validMigration(entity, settings)
    or not contract.state(state, entity)
    or (state.state ~= "on" and state.state ~= "off")
  then
    return false
  end
  local kind, attrs = M.kind(settings), state.attributes
  local dims, color, temperature = capabilities.fromModes(attrs.supported_color_modes)
  local range = M.range(settings.range)
  local native = range and M.nativeRange(attrs)
  return (not kind.dims or dims)
    and (not kind.dims or state.state == "off" or inRange(attrs.brightness, 1, 255))
    and (not kind.color or color)
    and (not kind.temperature or (temperature and native and range.minK >= native.minK and range.maxK <= native.maxK))
end

function M.sameStoredMigration(entity, settings)
  if not validMigration(entity, settings) then
    return false
  end
  local saved = readOverrides(getmetatable(persist):new())[entity]
  return codec.isObject(saved) and codec.encode(saved) == codec.encode(settings)
end

function M.stageMigration(entity, settings, done)
  if not validMigration(entity, settings) then
    return done(false)
  end
  local overrides = readOverrides(persist)
  local prior = overrides[entity]
  if prior and codec.encode(prior) ~= codec.encode(settings) then
    return done(false)
  end
  if M.sameStoredMigration(entity, settings) then
    return done(true)
  end
  overrides[entity] = settings
  persist:set(key, codec.encode(overrides))
  -- Director's persistence write lands asynchronously, about 50 ms after
  -- the call in the controller measurement modeled by the template shim.
  SetTimer("HA.Light.CompatibilityReadback", 100, function()
    done(M.sameStoredMigration(entity, settings))
  end)
  return true
end

function M.supported(field, device, modesAvailable)
  return field == "kind" or (field == "format" and device and device.color) or (field == "range" and modesAvailable)
end

function M.properties(saved, device, temperature)
  local result = {}
  for _, field in ipairs(fields) do
    if M.supported(field.key, device, temperature) or saved[field.key] then
      local description = field.description
      local range = field.key == "range" and device and device.cct
      if range then
        description = description .. (" Current range is %d to %d K."):format(range.minK, range.maxK)
      end
      result[#result + 1] = {
        name = field.name,
        value = saved[field.key] or (field.choices and automatic or ""),
        choices = field.choices,
        description = description,
      }
    end
  end
  return result
end

function M.field(name)
  for _, field in ipairs(fields) do
    if field.name == name then
      return field
    end
  end
end

function M.save(entity, saved, field, value, device, temperature)
  if type(value) ~= "string" or #value > 60 then
    return "Enter a valid setting."
  end
  if field.choices then
    local found
    for _, choice in ipairs(field.choices) do
      if value == choice then
        found = true
        break
      end
    end
    if not found then
      return "Choose one of the listed options."
    end
    value = value ~= automatic and value or nil
  elseif value == "" then
    value = nil
  else
    local range = M.range(value)
    if not range then
      return "Enter two temperatures from 1000 to 9000 K, with the lower value first."
    end
    value = range.minK .. "-" .. range.maxK
  end
  if value and not M.supported(field.key, device, temperature) then
    return "Choose a light that supports this setting."
  end
  local nextSettings = codec.object({ kind = saved.kind, format = saved.format, range = saved.range })
  nextSettings[field.key] = value
  local overrides = readOverrides(persist)
  overrides[entity] = next(nextSettings) and nextSettings or nil
  persist:set(key, codec.encode(overrides))
  return nil, nextSettings
end

return M

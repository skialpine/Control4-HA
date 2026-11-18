-- Versioned indicator capability projection and explicit single-setting writes.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gesture = require("ha.gesture-contract")
local M = {}

local behaviors = { always_on = true, always_off = true, follow_load = true, follow_load_inverted = true }

local function key(value)
  return type(value) == "string" and #value <= 64 and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function color(value)
  return type(value) == "string" and #value == 6 and value:match("^[A-F0-9]+$") ~= nil
end

local function percent(value)
  return type(value) == "number" and value >= 0 and value <= 100 and value == math.floor(value)
end

local function contains(items, value)
  for _, item in ipairs(items) do
    if item == value then
      return true
    end
  end
  return false
end

local function values(raw, max, valid)
  if not codec.isArray(raw) or #raw > max then
    return nil
  end
  local result, seen = {}, {}
  for _, item in ipairs(raw) do
    if not valid(item) or seen[item] then
      return nil
    end
    seen[item] = true
    result[#result + 1] = item
  end
  return result
end

local function behavior(value)
  return type(value) == "string" and behaviors[value] == true
end

function M.metadata(data, entity, device, control)
  if
    not contract.entity(entity)
    or not entity:match("^event%.")
    or not contract.state(data, entity)
    or data.state == "unavailable"
    or not gesture.identity(device)
    or not gesture.identity(control)
  then
    return nil
  end
  local attrs = data.attributes
  if
    attrs.bridge_source_device_id ~= device
    or attrs.bridge_control_id ~= control
    or not gesture.identity(attrs.bridge_session_id)
    or (attrs.bridge_contract_version ~= "1.0" and attrs.bridge_contract_version ~= "1.1")
    or attrs.bridge_led_version ~= 1
    or attrs.bridge_led_command_version ~= 2
    or not codec.isArray(attrs.bridge_leds)
    or #attrs.bridge_leds > 16
  then
    return nil
  end
  return attrs
end

local function project(raw)
  if
    raw.available ~= true
    or type(raw.label) ~= "string"
    or #raw.label > 512
    or raw.label:find("%c")
    or not raw.label:match("%S")
  then
    return nil
  end
  local row = { id = raw.id, label = raw.label }
  if raw.color_supported == true then
    local palette = values(raw.colors, 65, color)
    if palette then
      row.colors = {}
      for _, entry in ipairs(palette) do
        -- Black is a power command in v2. Do not offer it as a color.
        if entry ~= "000000" then
          row.colors[#row.colors + 1] = entry
        end
      end
      row.color = contains(row.colors, raw.color) and raw.color or nil
    end
  end
  row.behaviors = values(raw.behaviors, 4, behavior)
  row.behavior = row.behaviors and contains(row.behaviors, raw.behavior) and raw.behavior or nil
  if raw.brightness_supported == true then
    -- Earlier v2 bridges guarantee 0–100 and can quantize to their backend.
    -- When a bridge supplies its discrete levels, accept exactly those.
    row.levels = raw.brightness_levels ~= nil and values(raw.brightness_levels, 101, percent) or nil
    row.brightness_supported = raw.brightness_levels == nil or (row.levels ~= nil and #row.levels > 0)
    row.brightness = row.brightness_supported and percent(raw.brightness) and raw.brightness or nil
  end
  if (row.colors and #row.colors > 0) or (row.behaviors and #row.behaviors > 0) or row.brightness_supported then
    return row
  end
end

function M.project(attrs, only)
  local result, seen = {}, {}
  for _, raw in ipairs(attrs and attrs.bridge_leds or {}) do
    if not codec.isObject(raw) or not key(raw.id) or seen[raw.id] then
      return {}
    end
    seen[raw.id] = true
    if not only or raw.id == only then
      local row = project(raw)
      if row then
        result[#result + 1] = row
      end
    end
  end
  return result
end

-- Composer saves role names and, for additional indicators, a label ending in
-- the stable channel ID. Keep the full tracking palette (including black)
-- separate from the writable colors offered by the setup page.
function M.programmingRows(attrs)
  local rows, ids, roles = {}, {}, {}
  for _, raw in ipairs(attrs.bridge_leds) do
    if not codec.isObject(raw) or not key(raw.id) or not key(raw.button_id) or ids[raw.id] or roles[raw.button_id] then
      return {}
    end
    ids[raw.id], roles[raw.button_id] = true, true
    if raw.available == true then
      local row = project(raw)
      local palette = values(raw.colors, 65, color)
      if not row or not palette then
        return {}
      end
      row.role, row.palette = raw.button_id, palette
      row.confirmed_color = contains(palette, raw.color) and raw.color or nil
      table.sort(palette)
      rows[#rows + 1] = row
    end
  end
  return rows
end

function M.allowed(attrs, id, field, value)
  local row = M.project(attrs, id)[1]
  if not row then
    return false
  elseif field == "tracking_color" then
    local behavior = value == "000000" and "always_off" or "always_on"
    if not row.behaviors or not contains(row.behaviors, behavior) then
      return false
    end
    for _, raw in ipairs(attrs.bridge_leds) do
      if raw.id == id then
        local palette = values(raw.colors, 65, color)
        return palette ~= nil
          and contains(palette, value)
          and (value == "000000" or raw.color_supported == true or (raw.color_supported == false and value == "FFFFFF"))
      end
    end
    return false
  elseif field == "color" then
    return row.colors ~= nil and contains(row.colors, value)
  elseif field == "behavior" then
    return row.behaviors ~= nil and contains(row.behaviors, value)
  end
  return field == "brightness"
    and row.brightness_supported
    and percent(value)
    and (not row.levels or contains(row.levels, value))
end

function M.command(entity, args)
  if
    not codec.isObject(args)
    or not contract.entity(entity)
    or not entity:match("^event%.")
    or not key(args.id)
    or not gesture.identity(args.device)
    or not gesture.identity(args.control)
    or not gesture.identity(args.session)
  then
    return nil
  end
  for field in pairs(args) do
    if
      field ~= "id"
      and field ~= "device"
      and field ~= "control"
      and field ~= "session"
      and field ~= "field"
      and field ~= "value"
    then
      return nil
    end
  end
  local field, value = args.field, args.value
  if
    not (
      (field == "color" and color(value) and value ~= "000000")
      or (field == "tracking_color" and color(value))
      or (field == "behavior" and behavior(value))
      or (field == "brightness" and percent(value))
    )
  then
    return nil
  end
  local data = { entity_id = entity, led_id = args.id }
  if field == "tracking_color" then
    data.color = value
    data.behavior = value == "000000" and "always_off" or "always_on"
  else
    data[field] = value
  end
  return {
    type = "call_service",
    domain = "ha_gesture_bridge",
    service = "set_led",
    service_data = data,
  }
end

return M

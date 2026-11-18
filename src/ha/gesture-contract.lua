-- The bridge's optional load and indicator data have separate consumers.
local codec = require("ha.codec")

local M = {}
local KINDS = { press = true, hold_start = true, hold_repeat = true, release = true, custom = true }
local AVAILABILITY = { available = true, unavailable = true, unknown = true }
local ROLES = { top = true, bottom = true, toggle = true }

local monthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function leapDays(year)
  return math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
end

-- HA revisions use RFC3339, with varying precision and zone offsets. Keep
-- fractional digits separate so rounding cannot reorder nearby UTC revisions.
function M.timestamp(value)
  if type(value) ~= "string" or #value > 40 then
    return nil
  end
  local year, month, day, hour, minute, second, zone =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.+)$")
  if not year then
    return nil
  end
  year, month, day, hour, minute, second =
    tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute), tonumber(second)
  local fractions = ""
  if zone:sub(1, 1) == "." then
    fractions, zone = zone:match("^%.(%d+)(.+)$")
    if not fractions or #fractions > 9 then
      return nil
    end
  end
  if year < 1 or not monthDays[month] or hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  local leap = leapDays(year) > leapDays(year - 1)
  local lastDay = monthDays[month] + ((month == 2 and leap) and 1 or 0)
  if day < 1 or day > lastDay then
    return nil
  end
  local days = 365 * (year - 1) + leapDays(year - 1) + day - 1
  for i = 1, month - 1 do
    days = days + monthDays[i]
  end
  if leap and month > 2 then
    days = days + 1
  end
  local utc = days * 86400 + hour * 3600 + minute * 60 + second
  if zone ~= "Z" then
    local sign, hours, minutes = zone:match("^([+-])(%d%d):(%d%d)$")
    hours, minutes = tonumber(hours), tonumber(minutes)
    if not sign or hours > 23 or minutes > 59 then
      return nil
    end
    local offset = hours * 3600 + minutes * 60
    utc = utc + (sign == "+" and -offset or offset)
  end
  return string.format("%012.0f", utc + 86400) .. (fractions .. "000000000"):sub(1, 9)
end

function M.identity(value)
  return type(value) == "string" and #value <= 128 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function key(value)
  return type(value) == "string" and #value <= 64 and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function label(value)
  if type(value) ~= "string" or not value:match("%S") or value:find("%c") then
    return false
  end
  local _, bytes = value:gsub("[^\128-\191]", "")
  return bytes <= 128
end

function M.sequence(value)
  return type(value) == "number" and value >= 1 and value <= 9007199254740991 and value == math.floor(value)
end

-- The prototype allocated custom Composer event IDs from 1000 through 65535.
-- Validate its complete saved map before reusing an ID for existing programming.
function M.savedLightEvents(store)
  if store == nil or (type(store) == "table" and next(store) == nil) then
    return {}
  end
  if
    type(store) ~= "table"
    or store.version ~= 1
    or type(store.allocations) ~= "table"
    or not M.sequence(store.next_event_id)
    or store.next_event_id < 1000
    or store.next_event_id > 65536
  then
    return nil
  end
  local seen = {}
  for name, id in pairs(store.allocations) do
    if type(name) ~= "string" or not M.sequence(id) or id < 1000 or id >= store.next_event_id or seen[id] then
      return nil
    end
    local owner, button, gesture = name:match("^([^/]+)/([^/]+)/([^/]+)$")
    if not M.identity(owner) or not key(button) or not key(gesture) then
      return nil
    end
    seen[id] = true
  end
  return store.allocations
end

function M.matchesSource(attrs, device, control)
  return device ~= nil
    and control ~= nil
    and (attrs.bridge_contract_version == "1.0" or attrs.bridge_contract_version == "1.1")
    and attrs.bridge_source_device_id == device
    and attrs.bridge_control_id == control
end

function M.anySourceReady(attrs)
  if not codec.isArray(attrs.bridge_sources) then
    return false
  end
  for _, source in ipairs(attrs.bridge_sources) do
    if codec.isObject(source) and source.ready == true and source.availability ~= "unavailable" then
      return true
    end
  end
  return false
end

function M.sourceReady(attrs, device, control)
  return M.matchesSource(attrs, device, control) and M.anySourceReady(attrs)
end

local function action(id, kind, count)
  if not key(id) or not KINDS[kind] then
    return false
  end
  if kind == "press" then
    return M.sequence(count) and id == "press_" .. string.format("%.0f", count)
  end
  return count == nil and not id:match("^press_")
end

local maxProgrammingTaps = 3

function M.programmable(gesture)
  return gesture.kind ~= "press" or gesture.press_count <= maxProgrammingTaps
end

function M.retiredTap(key)
  local count = type(key) == "string" and tonumber(key:match("/press_(%d+)$"))
  return count and count > maxProgrammingTaps
end

local standardButtonLabels = { ["Top Button"] = "Top", ["Bottom Button"] = "Bottom", ["Toggle Button"] = "Toggle" }
local standardTapLabels = { "single", "double", "triple" }

local function programmingName(button, gesture, occupied)
  local short = standardButtonLabels[button.label] or button.label:match("^Extra Button (%d+)$")
  if short and not standardButtonLabels[button.label] then
    short = "Extra " .. short
  end
  local buttonName = short and not occupied[short] and short or button.label
  local actionName = gesture.label
  if gesture.kind == "press" then
    local count = gesture.press_count
    local taps = string.format("%.0f %s", count, count == 1 and "tap" or "taps")
    local conventional = standardTapLabels[count]
    local name = actionName:lower()
    local custom = name ~= taps
      and not (conventional and (name == conventional .. " tap" or name == conventional .. " press"))
    actionName = custom and (taps .. " (" .. actionName .. ")") or taps
  end
  return buttonName .. " - " .. actionName
end

function M.capabilities(attrs)
  local buttons, sources = attrs.bridge_buttons, attrs.bridge_sources
  if
    not codec.isArray(buttons)
    or #buttons == 0
    or #buttons > 32
    or not codec.isArray(sources)
    or #sources == 0
    or #sources > 32
  then
    return nil
  end
  local definitions, buttonIDs, releases, occupied = {}, {}, {}, {}
  for _, button in ipairs(buttons) do
    if codec.isObject(button) and label(button.label) then
      occupied[button.label] = true
    end
  end
  for _, button in ipairs(buttons) do
    if
      not codec.isObject(button)
      or not key(button.id)
      or buttonIDs[button.id]
      or not label(button.label)
      or not codec.isArray(button.gestures)
      or #button.gestures == 0
      or #button.gestures > 128
    then
      return nil
    end
    buttonIDs[button.id] = true
    for _, gesture in ipairs(button.gestures) do
      if
        not codec.isObject(gesture)
        or not action(gesture.id, gesture.kind, gesture.press_count)
        or not label(gesture.label)
      then
        return nil
      end
      local event = button.id .. "/" .. gesture.id
      if definitions[event] then
        return nil
      end
      if gesture.kind == "release" then
        releases[button.id] = true
      end
      definitions[event] = {
        name = programmingName(button, gesture, occupied),
        button_id = button.id,
        gesture_id = gesture.id,
        role = ROLES[button.id] and button.id or nil,
        kind = gesture.kind,
        press_count = gesture.press_count,
      }
    end
  end
  local ready, sourceIDs, sharedReady = {}, {}, false
  for _, source in ipairs(sources) do
    if
      not codec.isObject(source)
      or not M.identity(source.id)
      or sourceIDs[source.id]
      or type(source.ready) ~= "boolean"
      or not AVAILABILITY[source.availability]
      or (source.button_id ~= nil and not buttonIDs[source.button_id])
    then
      return nil
    end
    sourceIDs[source.id] = true
    if source.ready and source.availability ~= "unavailable" then
      if source.button_id then
        ready[source.button_id] = true
      else
        sharedReady = true
      end
    end
  end
  if sharedReady then
    for id in pairs(buttonIDs) do
      ready[id] = true
    end
  end
  return definitions, ready, releases
end

function M.history(data, definitions, live)
  local attrs = data.attributes
  if attrs.gesture_event_id == nil or attrs.gesture_event_id == codec.null then
    if live or (data.state ~= "unknown" and data.state ~= "unavailable") then
      return nil
    end
    for _, field in ipairs({
      "event_type",
      "button_id",
      "gesture_id",
      "press_count",
      "gesture_session_id",
      "gesture_sequence",
      "gesture_occurred_at",
    }) do
      if attrs[field] ~= nil and attrs[field] ~= codec.null then
        return nil
      end
    end
    return 0
  end
  local session, sequence = attrs.gesture_session_id, attrs.gesture_sequence
  local count = attrs.press_count
  if count == codec.null then
    count = nil
  end
  local occurred = M.timestamp(attrs.gesture_occurred_at)
  if
    not M.identity(session)
    or not M.sequence(sequence)
    or not key(attrs.button_id)
    or not action(attrs.gesture_id, attrs.event_type, count)
    or attrs.gesture_event_id ~= session .. ":" .. string.format("%.0f", sequence)
    or not occurred
    or (data.state ~= "unavailable" and data.state ~= "unknown" and not M.timestamp(data.state))
  then
    return nil
  end
  if not live then
    return session == attrs.bridge_session_id and sequence or 0
  end
  local event = attrs.button_id .. "/" .. attrs.gesture_id
  local definition = definitions[event]
  if
    session ~= attrs.bridge_session_id
    or data.state == "unavailable"
    or data.state == "unknown"
    or not definition
    or definition.kind ~= attrs.event_type
    or definition.press_count ~= count
  then
    return nil
  end
  return sequence, event
end

return M

-- Contact output and programming for a selected Home Assistant binary sensor.
local Adapter = require("ha.endpoint-adapter")
local values = require("lib.values")

local contact = 1
local roles = {
  door = { "Open", "Closed" },
  garage_door = { "Open", "Closed" },
  opening = { "Open", "Closed" },
  window = { "Open", "Closed" },
  motion = { "Motion detected", "No motion" },
  occupancy = { "Occupied", "Unoccupied" },
  presence = { "Present", "Away" },
  moisture = { "Wet", "Dry" },
  smoke = { "Smoke detected", "Clear" },
  connectivity = { "Connected", "Disconnected" },
  battery = { "Battery low", "Battery normal" },
  problem = { "Problem detected", "Clear" },
}
local generic = { "Active", "Inactive" }
local definition = { family = "binary_sensor" }

function definition.supports(entity)
  return type(entity) == "string" and entity:match("^binary_sensor%.[a-z0-9_]+$") ~= nil
end

function definition.decode(raw, attributes)
  if raw ~= "on" and raw ~= "off" then
    return nil
  end
  local labels = roles[attributes.device_class] or generic
  local active = raw == "on"
  return { active = active, label = labels[active and 1 or 2] }
end

function definition.same(current, previous)
  return current.active == previous.active and current.label == previous.label
end

local function notifyContact(state, transition)
  local name = state.active and "OPENED" or "CLOSED"
  C4:SendToProxy(contact, transition and name or ("STATE_" .. name), {}, "NOTIFY")
end

function definition.install(adapter)
  adapter:handle(TC, "IS_ACTIVE", function()
    local state = adapter:confirmed()
    return state ~= nil and state.active
  end)
  adapter:handle(TC, "IS_INACTIVE", function()
    local state = adapter:confirmed()
    return state ~= nil and not state.active
  end)
  adapter:handle(TC, "IS_AVAILABLE", function()
    return adapter:confirmed() ~= nil
  end)
  adapter:handle(OBC, contact, function(_, _, isBound)
    local state = isBound and adapter:confirmed()
    if state then
      notifyContact(state, false)
    end
  end)
end

function definition.publish(state, previous, kind)
  if state then
    values:update("Signal Active", state.active, "BOOL")
    local changed = not previous or state.active ~= previous.active
    local transition = kind == "state" and previous ~= nil and changed
    if changed then
      notifyContact(state, transition)
    end
    if transition then
      C4:FireEventByID(state.active and 1000 or 1001)
    end
  elseif kind == "lost" then
    C4:FireEventByID(1002)
  end
end

return {
  new = function()
    return Adapter.new(definition)
  end,
}

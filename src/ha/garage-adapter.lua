-- Native Garage Door relay, limit contacts and Programming feedback.
local endpoint = require("ha.endpoint-adapter")
local cover = require("ha.cover-controls")
local values = require("lib.values")

local relay = 4
local directionalRelays = { [5] = "open_cover", [6] = "close_cover", [7] = "stop_cover" }
local contacts = { [2] = "closed", [3] = "open" }
local events = { open = 1000, closed = 1001, opening = 1002, closing = 1003 }
local relayActions = {
  OPEN = "open_cover",
  CLOSE = "close_cover",
  TOGGLE = "toggle",
  TRIGGER = "toggle",
  PULSE = "toggle",
}

local function publishContact(id, asserted, transition)
  -- With neither contact asserted, only the HA state identifies motion or loss.
  local command = asserted and "CLOSED" or "OPENED"
  C4:SendToProxy(id, transition and command or "STATE_" .. command, {}, "NOTIFY")
end

local function install(adapter)
  cover.installNative(adapter)
  local function command(action)
    return function()
      return cover.command(adapter, action)
    end
  end
  adapter:handle(EC, "Open", command("open_cover"))
  adapter:handle(EC, "Close", command("close_cover"))
  adapter:handle(EC, "Stop", command("stop_cover"))
  adapter:handle(EC, "Toggle", command("toggle"))
  adapter:handle(EC, "Set_Position", function(parameters)
    return cover.command(adapter, "set_cover_position", parameters.Percent)
  end)
  adapter:handle(RFP, relay, function(_, action)
    return cover.command(adapter, relayActions[action])
  end)
  for id in pairs(directionalRelays) do
    adapter:handle(RFP, id, function(binding, action)
      -- Relay closure or a pulse activates this input; reopening releases it.
      return (action == "CLOSE" or action == "PULSE") and cover.command(adapter, directionalRelays[binding])
    end)
  end
  local function initializeContact(id, _, connected)
    if connected then
      local state = adapter:confirmed()
      publishContact(id, state and state.limit == contacts[id], false)
    end
  end
  for id in pairs(contacts) do
    adapter:handle(OBC, id, initializeContact)
  end
  adapter:handle(TC, "IS_OPEN", function()
    local state = adapter:confirmed()
    return state ~= nil and state.limit == "open"
  end)
  adapter:handle(TC, "IS_CLOSED", function()
    local state = adapter:confirmed()
    return state ~= nil and state.limit == "closed"
  end)
  adapter:handle(TC, "IS_AVAILABLE", function()
    return adapter:confirmed() ~= nil
  end)
end

local function publish(state, previous, kind, adapter)
  values:update("Position", cover.publishNative(adapter, state, previous), "NUMBER")
  local limit, oldLimit = state and state.limit, previous and previous.limit
  local transition = kind == "state" and previous ~= nil
  UpdateProperty("Door status", state and state.label or "Unavailable")
  for id, active in pairs(contacts) do
    local asserted, wasAsserted = limit == active, oldLimit == active
    if not transition or asserted ~= wasAsserted then
      publishContact(id, asserted, transition)
    end
  end
  values:update("Open limit", limit == "open", "BOOL")
  values:update("Closed limit", limit == "closed", "BOOL")
  if transition and limit and limit ~= oldLimit then
    C4:FireEventByID(events[limit])
  elseif
    transition
    and state.status ~= previous.status
    and (state.status == "opening" or state.status == "closing")
  then
    C4:FireEventByID(events[state.status])
  elseif kind == "lost" then
    C4:FireEventByID(1004)
  end
end

local definition = {
  family = "garage",
  supports = cover.supports,
  decode = function(state, attributes)
    if attributes.device_class ~= "garage" then
      return nil
    end
    local result = cover.decode(state, attributes)
    if not result then
      return nil
    end
    if state == "closed" or (state == "open" and result.position == 100) then
      result.limit = state
    elseif state == "open" and result.position ~= nil then
      result.label = "Partly open"
    end
    return result
  end,
  install = install,
  offersProperty = cover.offersProperty,
  publish = publish,
  same = function(state, previous)
    return state.status == previous.status
      and state.flags == previous.flags
      and state.limit == previous.limit
      and state.label == previous.label
      and state.position == previous.position
  end,
}

return {
  new = function()
    return endpoint.new(definition)
  end,
}

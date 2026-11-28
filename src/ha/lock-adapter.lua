-- Native lock commands and state projection.
local contract = require("ha.contract")
local Endpoint = require("ha.endpoint-adapter")
local values = require("lib.values")

local LOCK = 5001
local states = {
  locked = { label = "Locked", native = "locked" },
  unlocked = { label = "Unlocked", native = "unlocked" },
  open = { label = "Open", native = "unlocked" },
  opening = { label = "Opening", native = "unknown" },
  locking = { label = "Locking", native = "unknown" },
  unlocking = { label = "Unlocking", native = "unknown" },
  jammed = { label = "Jammed", native = "fault" },
}

local function decode(state, attributes)
  local status = states[state]
  if not status then
    return nil
  end
  local battery = tonumber(attributes.lock_battery)
  local batteryStatus
  if battery and battery >= 0 and battery <= 100 then
    batteryStatus = battery > 50 and "normal" or battery > 25 and "warning" or "critical"
  end
  return {
    state = state,
    label = status.label,
    native = status.native,
    battery = batteryStatus,
    codeExpected = attributes.code_format == true,
  }
end

local function same(current, previous)
  return current.state == previous.state
    and current.battery == previous.battery
    and current.codeExpected == previous.codeExpected
end

local function publish(current, previous, kind)
  if not current or not previous or current.state ~= previous.state then
    C4:SendToProxy(LOCK, "LOCK_STATUS_CHANGED", {
      LOCK_STATUS = current and current.native or "unknown",
      LAST_ACTION_DESCRIPTION = current and current.label or "Unavailable",
    }, "NOTIFY")
  end
  if current and current.battery and (not previous or current.battery ~= previous.battery) then
    C4:SendToProxy(LOCK, "BATTERY_STATUS_CHANGED", { BATTERY_STATUS = current.battery }, "NOTIFY")
  end
  if current and previous and kind == "state" and current.state == "jammed" and previous.state ~= "jammed" then
    C4:FireEventByID(1000)
  end
end

local function control(owner, action)
  local state = owner:confirmed()
  if not state then
    return false
  end
  -- The Lock proxy has no per-action PIN field. Home Assistant can apply a
  -- default lock code configured on that entity without sharing it with C4.
  return owner:command(action, {}, function(status, latest)
    if latest and state.codeExpected and status == "rejected" then
      values:update("Last Command Result", "Check the lock and its default code in Home Assistant.", "STRING")
    end
  end)
end

local function install(owner)
  RFP.suppressDebug[LOCK] = RFP.suppressDebug[LOCK] or {}
  for _, command in ipairs({ "ADD_USER", "DELETE_USER", "EDIT_USER", "SET_ADMIN_CODE", "SET_CUSTOM_SETTINGS" }) do
    RFP.suppressDebug[LOCK][command] = true
  end
  owner:handle(RFP, LOCK, function(_, command)
    if command == "LOCK" or command == "UNLOCK" then
      return control(owner, command:lower())
    elseif command == "TOGGLE" then
      local state = owner:confirmed()
      if state and (state.state == "locked" or state.state == "unlocked" or state.state == "open") then
        return control(owner, state.state == "locked" and "unlock" or "lock")
      end
    end
  end)
  owner:handle(TC, "IS_JAMMED", function()
    local state = owner:confirmed()
    return state ~= nil and state.state == "jammed"
  end)
end

return {
  new = function()
    return Endpoint.new({
      family = "lock",
      supports = function(entity)
        return contract.endpointDomain(entity) == "lock"
      end,
      decode = decode,
      same = same,
      publish = publish,
      install = install,
    })
  end,
}

-- Installed only in the the controller lab Coordinator. Faults apply to one simulated load.
local codec = require("ha.codec")
local M = {}
local FIXTURE = "switch.ha_lab_switch_paddle"
local LIFETIME = "HA.Lab.SwitchOverlap"
local RESPONSE = LIFETIME .. ".response"

function M.install(current)
  local active
  EC.LabSwitchOverlap = function(params)
    local hub = current()
    local scenario = params and params.SCENARIO
    if active or not hub or not hub.online or (scenario ~= "supersede" and scenario ~= "drop") then
      return
    end

    local connection = hub.connection
    local send, receive = connection.send, connection.onMessage
    local first, held
    local function stop()
      connection.send, connection.onMessage = send, receive
      CancelTimer(LIFETIME)
      CancelTimer(RESPONSE)
      active = nil
    end
    active = SetTimer(LIFETIME, 18000, stop)
    if not active then
      return
    end

    connection.send = function(self, message)
      if
        message.type ~= "call_service"
        or message.domain ~= "switch"
        or not message.target
        or message.target.entity_id ~= FIXTURE
      then
        return send(self, message)
      end
      if not first then
        first = message.id
      elseif scenario == "supersede" then
        local superseded = first
        stop()
        receive(codec.object({
          type = "result",
          id = superseded,
          success = false,
          error = codec.object({ code = "home_assistant_error", message = "Simulated ZW0219" }),
        }))
      end
      return send(self, message)
    end
    connection.onMessage = function(message)
      if message.type ~= "result" or message.id ~= first then
        return receive(message)
      end
      if scenario == "drop" then
        stop()
        return
      end
      held = message
      SetTimer(RESPONSE, 2500, function()
        stop()
        receive(held)
      end)
    end
  end
end

return M

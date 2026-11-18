-- Run the template conformance cases through the shipped Light driver. This
-- substitutes a Coordinator and HA light at the private Director boundary.
local D = require("light_drivers")
local Color = require("lib.light.color")
local Range = require("lib.light.range")
local codec = require("ha.codec")
local ids = require("ha.identities")
local persist = require("lib.persist")

local function rig(name, entity, modes, rates)
  return {
    name = name,
    settleMs = 1500,
    load = function(h, initial)
      h.proxy.links = ids.lightLinks
      local c4 = C4
      local device = c4:GetDeviceID()
      local coordinator = device + 1
      local previousProvider, previousBindings = c4.GetBoundProviderDevice, c4.GetBindingsByDevice
      local previousProperty = c4.UpdateProperty
      local previousSend = SendSecretToDevice
      local lease
      local transport, epoch = true, 1
      local state = initial or { on = false, level = 0.6, color = { x = 0.4, y = 0.4, mode = "xy" } }
      local motion
      local function current()
        if not motion then
          return state
        end
        local fraction = math.min(1, (h.clock.now() - motion.start) / motion.duration)
        local level = motion.from + (motion.to - motion.from) * fraction
        return { on = level > 0, level = level, color = state.color }
      end

      function c4:GetBoundProviderDevice(consumer, binding)
        if consumer == device and binding == ids.lightCoordinatorBinding then
          return coordinator
        end
        return previousProvider(self, consumer, binding)
      end
      function c4:UpdateProperty(name, value)
        Properties[name] = value
      end
      function c4:GetBindingsByDevice(target)
        local existing = previousBindings(self, target)
        local bindings = (existing and existing.bindings) or {}
        if target == device or target == coordinator then
          bindings[#bindings + 1] = {
            provider = target == coordinator,
            bindingid = target == coordinator and ids.coordinatorBinding or ids.lightCoordinatorBinding,
            bindingclasses = { { class = ids.coordinatorClass } },
            boundprovider = target == device
                and { bound = { deviceid = coordinator, bindingid = 1, boundclasses = { ids.coordinatorClass } } }
              or nil,
            boundconsumers = target == coordinator and {
              {
                deviceid = device,
                bindingid = ids.lightCoordinatorBinding,
                boundclasses = { ids.coordinatorClass },
              },
            } or nil,
          }
        end
        return { bindings = bindings }
      end

      local function emit(kind, data)
        EC.HA_SUITE_V1({
          PAYLOAD = codec.encode({
            version = ids.api,
            coordinator = coordinator,
            boot = 1,
            epoch = epoch,
            session = lease.session,
            selection = lease.selection,
            kind = kind,
            data = data,
          }),
        })
      end
      local function readiness(snapshotted)
        emit("readiness", {
          entity_id = entity,
          transport = transport,
          subscription = transport,
          snapshot = transport and snapshotted,
          available = transport and snapshotted,
        })
      end
      local function snapshot(partial)
        local state = current()
        local attrs = codec.object({ supported_color_modes = modes, supported_features = rates and 32 or nil })
        if modes and not partial then
          attrs.brightness = state.on and Range.step(state.level, 255) or nil
          if state.on and state.color then
            attrs.color_mode = state.color.mode == "cct" and "color_temp" or "xy"
            attrs.color_temp_kelvin = state.color.kelvin
            attrs.xy_color = codec.array({ state.color.x, state.color.y })
          end
          attrs.min_color_temp_kelvin, attrs.max_color_temp_kelvin = 2000, 6500
        end
        return codec.object({ entity_id = entity, state = state.on and "on" or "off", attributes = attrs })
      end
      local function report(partial)
        if not transport or not lease then
          return
        end
        emit("state", snapshot(partial))
        readiness(true)
      end
      function SendSecretToDevice(target, cmd, params)
        if target ~= coordinator or cmd ~= "HA_SUITE_V1" then
          return previousSend(target, cmd, params)
        end
        local data = codec.decode(params.PAYLOAD)
        if data.op == "select" then
          lease = data
          emit("selected", codec.object({}))
          if data.entities[1] == entity then
            readiness(false)
            report()
          end
        elseif data.op == "request" and transport then
          assert(data.entity_id == entity)
          local reading = data.operation == "read_load"
          if data.operation == "verify_target" or reading then
            emit("result", {
              entity_id = entity,
              request_id = data.request_id,
              operation = data.operation,
              status = reading and "load_state" or "verified",
              load_state = reading and snapshot() or nil,
            })
            return
          end
          assert(data.operation == "service")
          local args = data.arguments
          local parameters = args.parameters
          local prior = current()
          motion = nil
          local on = args.action == "turn_on"
          local level = parameters.brightness and parameters.brightness / 255 or state.level
          local duration = 1000 * (parameters.transition or 0)
          if duration > 0 then
            local ramp = {
              from = prior.on and prior.level or 0,
              to = on and level or 0,
              start = h.clock.now(),
              duration = duration,
            }
            motion = ramp
            h.clock.at(duration, function()
              if motion ~= ramp then
                return
              end
              motion = nil
              state.on, state.level = on, level
              report()
            end)
          else
            state.on, state.level = on, level
          end
          if parameters.xy_color then
            state.color = { x = parameters.xy_color[1], y = parameters.xy_color[2], mode = "xy" }
          elseif parameters.color_temp_kelvin then
            local x, y = Color.kelvinToXY(parameters.color_temp_kelvin)
            state.color = { x = x, y = y, mode = "cct", kelvin = parameters.color_temp_kelvin }
          end
          emit("result", {
            entity_id = entity,
            request_id = data.request_id,
            operation = "service",
            status = "accepted",
          })
          if duration <= 0 then
            h.clock.at(1, report)
          end
        end
      end

      local restoreClock = h.clock.restore
      local destroy
      h.clock.restore = function()
        if destroy then
          destroy()
        end
        c4.GetBoundProviderDevice, c4.GetBindingsByDevice = previousProvider, previousBindings
        c4.UpdateProperty = previousProperty
        SendSecretToDevice = previousSend
        restoreClock()
      end
      if not initial then
        -- Independent cases share the shim's device ID and persisted values.
        -- Keep the committed choice only when this case restarts its driver.
        persist:delete("HA.DeviceSelection")
        ShimPersistLand()
      end
      h.light = assert(D.load(D.root(), "light"))
      destroy = OnDriverDestroyed
      OnDriverInit()
      OnDriverLateInit()
      if not initial then
        UpdateProperty("Manual entity ID", entity, true)
      end
      return {
        state = current,
        set = function(changes, partial)
          motion = nil
          for key, value in pairs(changes) do
            state[key] = value
          end
          report(partial)
          if partial then
            -- HA can publish a complete attribute update after an initial
            -- on-only change. The adapter waits for it without polling.
            h.clock.at(20, report)
          end
        end,
        drop = function()
          transport, epoch = false, epoch + 1
          readiness(false)
        end,
        back = function()
          transport, epoch = true, epoch + 1
          readiness(false)
          report()
        end,
      }
    end,
  }
end

return {
  version = require("light_rig").VERSION,
  rigs = {
    light = {
      rig("HA binary load", "switch.lamp"),
      rig("HA dimmer with color and CCT", "light.lamp", codec.array({ "xy", "color_temp" })),
      rig("HA dimmer with transition and replacement targets", "light.lamp", codec.array({ "brightness" }), true),
    },
  },
}

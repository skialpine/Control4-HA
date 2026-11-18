-- Run the archived startup hook with Director's candidate and binding records.
return function(runtime, model, scenario)
  local light = model == "HA Light"
  local cls = "SKIALPINE_HA_SUITE_V1"
  local me = C4:GetDeviceID()
  local input = light and 999 or 1
  local coordinator, second = 42, 59
  local bound = scenario == "existing" and second or 0
  local bindCalls = {}
  local existing = scenario ~= "missing"
  function C4:GetDevicesByC4iName(filename)
    if filename == "HA.Coordinator.c4z" and existing then
      return { [coordinator] = "HA Coordinator" }
    end
    if filename == "Control4.HA.Coordinator.c4z" and scenario == "ambiguous" then
      return { [second] = "Home Assistant Connection" }
    end
  end
  local deviceData = C4.GetDeviceData
  function C4:GetDeviceData(id, name)
    if name == "model" and id == coordinator then
      return "HA Coordinator"
    end
    if name == "model" and id == second then
      return "Control4.HA.Coordinator"
    end
    return deviceData(self, id, name)
  end
  function C4:GetBoundProviderDevice(device, binding)
    return device == me and binding == input and bound or 0
  end
  function C4:GetBoundConsumerDevices()
    return {}
  end
  function C4:GetBindingsByDevice(id)
    if id == me then
      return {
        bindings = {
          {
            bindingid = input,
            provider = false,
            bindingclasses = { { class = cls } },
            boundprovider = bound > 0 and { bound = { deviceid = bound, bindingid = 1, boundclasses = { cls } } }
              or nil,
          },
        },
      }
    end
    return {
      bindings = {
        {
          bindingid = 1,
          provider = true,
          bindingclasses = { { class = id == coordinator and scenario == "incompatible" and "HA_DEVICE" or cls } },
          boundconsumers = bound == id and { { deviceid = me, bindingid = input, boundclasses = { cls } } } or {},
        },
      },
    }
  end
  function C4:Bind(provider, providerBinding, consumer, consumerBinding, class)
    bindCalls[#bindCalls + 1] = { provider, providerBinding, consumer, consumerBinding, class }
    bound = provider
    OBC[input](input)
  end
  assert(loadfile(runtime))()
  OnDriverInit()
  OnDriverLateInit()
  if scenario == "unique" then
    assert(#bindCalls == 1 and table.concat(bindCalls[1], ":") == table.concat({ coordinator, 1, me, input, cls }, ":"))
    assert(Properties["Next step"]:find("choose the device", 1, true))
  else
    assert(
      #bindCalls == 0 and bound == (scenario == "existing" and second or 0),
      "Startup changed an explicit or ambiguous connection"
    )
  end
  if scenario == "unique" or scenario == "existing" then
    bound = 0
    OnDriverDestroyed()
    OnDriverInit()
    OnDriverLateInit()
    assert(bound == 0, "Startup recreated a deliberately removed connection")
  end
  OnDriverDestroyed()
end

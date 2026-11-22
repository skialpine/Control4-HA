-- Exercise the installed driver and its own module bundle through Director's UI
-- request and device-message entry points. Only the remote Coordinator is simulated.
return function(family)
  local codec = require("ha.codec")
  local ids = require("ha.identities")
  local device, coordinator = C4:GetDeviceID(), 42
  local input = family == "light" and ids.lightCoordinatorBinding or ids.coordinatorBinding
  local class = ids.coordinatorClass
  function C4:GetBoundProviderDevice(id, binding)
    return id == device and binding == input and coordinator or 0
  end
  function C4:GetBindingsByDevice(id)
    if id == device then
      return {
        bindings = {
          {
            bindingid = input,
            provider = false,
            bindingclasses = { { class = class } },
            boundprovider = { bound = { deviceid = coordinator, bindingid = 1, boundclasses = { class } } },
          },
        },
      }
    end
    if id == coordinator then
      return {
        bindings = {
          {
            bindingid = 1,
            provider = true,
            bindingclasses = { { class = class } },
            boundconsumers = { { deviceid = device, bindingid = input, boundclasses = { class } } },
          },
        },
      }
    end
    return { bindings = {} }
  end
  local sent, failure = {}, nil
  local revision = string.rep("a", 64)
  function C4:SendToDevice(id, command, params)
    local record = { target = id, command = command }
    sent[#sent + 1] = record
    assert(id == coordinator and command == "HA_SUITE_V1")
    local packet = codec.decode(params.PAYLOAD)
    record.op, record.operation = packet.op, packet.operation
    local reply = {
      version = 1,
      coordinator = id,
      boot = 1,
      epoch = 1,
      session = packet.session,
      selection = packet.selection,
      kind = "selected",
      data = codec.object({}),
    }
    if packet.op == "request" then
      assert(packet.operation == "catalog" and packet.arguments.family == family)
      assert(packet.arguments.names_sensor == nil, "default web browse unexpectedly read a secondary sensor")
      reply.kind = "result"
      reply.data = { request_id = packet.request_id, operation = "catalog", status = failure or "catalog" }
      if not failure then
        local cursor = packet.arguments.cursor or 1
        assert(cursor == 1 or (cursor == 2 and packet.arguments.revision == revision))
        local name = cursor == 1 and "Hallway" or "Kitchen"
        reply.data.catalog = {
          entities = codec.array({
            {
              entity_id = family .. "." .. name:lower(),
              domain = family,
              name = name,
              attributes = codec.object({}),
            },
          }),
          family = family,
          revision = revision,
          total = 2,
          source = "native",
          cursor = cursor,
          next_cursor = cursor == 1 and 2 or codec.null,
        }
      end
    elseif packet.op ~= "select" then
      return
    end
    ExecuteCommand(command, { PAYLOAD = codec.encode(reply) })
  end
  local answer
  function C4:SendDataToUI(command, params)
    if command == "HA_SETUP_PAGE" then
      answer = codec.decode(params.json)
    end
  end
  OBC[input](input)
  local function browse(tag, cursor)
    answer = nil
    local before = #sent
    local params = codec.object({ request = tag, cursor = cursor, revision = cursor and revision or nil })
    UIRequest("HA_SETUP_BROWSE", { DATA = C4:Base64Encode(codec.encode(params)) })
    assert(
      #sent == before + 1 and sent[#sent].op == "request" and sent[#sent].operation == "catalog",
      "Browsing must send only one catalog request"
    )
    assert(answer and answer.request == tag, "Packaged Device Setup did not return its correlated catalog response")
    return answer
  end
  local first = browse("page-one")
  assert(first.choices[1].name == "Hallway" and first.next_cursor == 2 and first.revision == revision)
  local second = browse("page-two", first.next_cursor)
  assert(second.choices[1].name == "Kitchen" and second.next_cursor == nil)
  for _, example in ipairs({
    { "permission_denied", "Home Assistant denied access" },
    { "disconnected", "Check the Home Assistant connection" },
  }) do
    failure = example[1]
    local response = browse(failure)
    assert(type(response.error) == "string" and response.error:find(example[2], 1, true))
    assert(response.choices == nil)
  end
  failure = nil
  assert(browse("retry").choices[1].name == "Hallway")

  local sendUIRequest = SendUIRequest
  SendUIRequest = function(id, command, params)
    assert(id == device and command == "HA_SELECTION_IDENTITY")
    local xml = UIRequest(command, params)
    assert(type(ParseXml(xml).selection) == "string", "The installed selection handler must return valid XML")
    return xml
  end
  local identity = require("ha.migration-selection").read(device)
  SendUIRequest = sendUIRequest
  assert(
    identity and identity.key == "" and not identity.buttons,
    "The migrated identity round trip must recognize an unconfigured installed driver"
  )
end

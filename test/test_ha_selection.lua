local T = require("testlib")
local codec = require("ha.codec")
local Selection = require("ha.selection")
local function wire(value)
  return codec.decode(codec.encode(value))
end
local revision, device, registry = string.rep("a", 64), string.rep("b", 32), string.rep("c", 32)
local native = wire({ entity_id = "light.native", domain = "light", name = "Native", attributes = {} })
local physical = wire({
  entity_id = "device:" .. device .. ":" .. registry,
  domain = "light",
  name = "Paddle",
  attributes = {
    device_choice = {
      type = "device_choice",
      version = 1,
      choice_id = "device:" .. device .. ":" .. registry,
      device_id = device,
      kind = "dimmer",
      source_load = { entity_id = "light.source", domain = "light", registry_id = registry },
    },
  },
})
local function run(row, patch)
  local active, requests = true, {}
  local catalog = {}
  function catalog:refresh()
    error("choosing a cached row should never refresh the catalog")
  end
  function catalog:choice(id, family, expected)
    if expected ~= revision then
      return nil, "revision_changed"
    end
    if id == row.entity_id and family == "light" then
      return row
    end
  end
  local arguments = { choice_id = row.entity_id, family = "light", revision = revision, prepare = false }
  for key, value in pairs(patch or {}) do
    arguments[key] = value
  end
  arguments = wire(arguments)
  local result = {}
  Selection.resolve(
    catalog,
    function(message, callback)
      requests[#requests + 1] = { message = message, callback = callback }
    end,
    arguments,
    function()
      return active
    end
  ):next(function(value)
    result.value = value
  end, function(error)
    result.failure = error.kind
  end)
  return result, requests, function()
    active = false
  end
end
T.section("read-only resolution never prepares or operates a load")
do
  local result, requests = run(native)
  T.eq("native load resolved exactly", result.value.controlled_load.entity_id, "light.native")
  T.eq("native operation needs no preparation", result.value.preparation, "not_required")
  T.eq("native resolution calls no service", #requests, 0)
  result, requests = run(physical)
  T.eq("physical metadata requests explicit preparation", result.value.preparation, "required")
  T.eq("source is not guessed as controlled load", result.value.controlled_load, nil)
  T.eq("read-only physical resolution calls no service", #requests, 0)
end
T.section("committed preparation uses identities from the verified choice")
do
  local result, requests = run(physical, { prepare = true })
  local call = requests[1]
  T.eq("only one preparation service", #requests, 1)
  T.eq("existing separate companion API", call.message.service, "prepare_device")
  T.eq(
    "exact device and registry source",
    call.message.service_data,
    { device_id = device, source_registry_id = registry }
  )
  call.callback(
    true,
    wire({
      response = {
        version = 1,
        device_id = device,
        input_ready = true,
        gesture_entity_id = "event.paddle",
        source_load = { entity_id = "light.source", domain = "light", registry_id = registry },
        controlled_load = { entity_id = "light.explicit_missing", domain = "light", available = false },
        controlled_load_origin = "explicit_link",
      },
    })
  )
  T.eq("unavailable explicit target preserved", result.value.controlled_load.entity_id, "light.explicit_missing")
  T.eq("unavailable target stays unavailable", result.value.controlled_load.available, false)
  T.eq("explicit target never falls through to source", result.value.controlled_load_origin, "explicit_link")
end
T.section("revision, identity, permission and version failures remain distinct")
do
  local result, requests = run(physical, { revision = string.rep("d", 64), prepare = true })
  T.eq("stale choice rejected", result.failure, "revision_changed")
  T.eq("stale choice cannot create controls", #requests, 0)
  result, requests = run(physical, { prepare = true })
  requests[1].callback(false, { kind = "permission_denied" })
  T.eq("permission refusal does not fabricate selection", result.value, nil)
  T.eq("permission failure actionable", result.failure, "permission_denied")
  result, requests = run(physical, { prepare = true })
  requests[1].callback(true, wire({ response = { version = 2 } }))
  T.eq("unsupported version explicit", result.failure, "unsupported_preparation_version")
  result, requests = run(physical, { prepare = true })
  requests[1].callback(
    true,
    wire({
      response = {
        version = 1,
        device_id = device,
        input_ready = false,
        source_load = { entity_id = "light.foreign", registry_id = registry },
      },
    })
  )
  T.eq("foreign source rejected", result.failure, "invalid_response")
end
T.section("retired replies and invalid load shapes cannot authorize replacements")
do
  local result, requests, retire = run(physical, { prepare = true })
  retire()
  requests[1].callback(
    true,
    wire({
      response = {
        version = 1,
        device_id = device,
        input_ready = false,
        source_load = { entity_id = "light.source", registry_id = registry },
      },
    })
  )
  T.eq("retired preparation cannot publish", result.value, nil)
  T.eq("retired preparation identified", result.failure, "retired")
  local bad = wire({
    version = 1,
    key = "light.native",
    family = "light",
    name = "Native",
    input_ready = false,
    preparation = "not_required",
    controlled_load = { entity_id = "light.native", domain = "[" },
    controlled_load_origin = "selected_endpoint",
  })
  local ok, valid = pcall(Selection.valid, bad, { choice_id = "light.native", family = "light" })
  T.truthy("malformed domain cannot throw", ok and not valid)
end
T.finish()

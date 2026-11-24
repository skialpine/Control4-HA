local T = require("testlib")
local codec = require("ha.codec")
local Choices = require("ha.choices")
local function wire(value)
  return codec.decode(codec.encode(value))
end
local function row(id, patch)
  local value = {
    entity_id = id,
    domain = id:match("^([^.]+)"),
    name = "Same name",
    device_id = string.rep("d", 32),
    attributes = codec.object({}),
  }
  for key, item in pairs(patch or {}) do
    value[key] = item
  end
  return wire(value)
end
local function entry(id, index, patch)
  local value = {
    entity_id = id,
    id = string.format("%032x", index or 1),
    platform = "lab",
    disabled_by = codec.null,
    hidden_by = codec.null,
    entity_category = codec.null,
    options = codec.object({}),
  }
  for key, item in pairs(patch or {}) do
    value[key] = item
  end
  return wire(value)
end
local function visible(rows, family)
  local result = {}
  for _, item in ipairs(rows) do
    for _, candidate in ipairs(item.families) do
      if candidate == family then
        result[#result + 1] = item.entity_id
      end
    end
  end
  table.sort(result)
  return result
end
local function keyed(rows)
  local result = {}
  for _, item in ipairs(rows) do
    result[item.entity_id] = item
  end
  return result
end
T.section("family choices preserve independent endpoints while excluding non-control metadata")
do
  local rows = codec.array({
    row("light.dimmer", { attributes = codec.object({ supported_color_modes = codec.array({ "brightness" }) }) }),
    row("light.binary", { attributes = codec.object({ supported_color_modes = codec.array({ "onoff" }) }) }),
    row("switch.a"),
    row("switch.b"),
    row("switch.configuration"),
    row("switch.diagnostic"),
    row("switch.hidden"),
    row("switch.disabled"),
    row("light.c4"),
    row("light.c4_group", { device_id = codec.null, is_group = true, c4_exported = true }),
    row("light.native_group", { device_id = codec.null, is_group = true }),
    row("light.helper", { device_id = codec.null }),
    row("switch.device_disabled", { device_disabled = true }),
    row("switch.owner_export", { c4_exported = true }),
  })
  local entries = {}
  for i, item in ipairs(rows) do
    entries[item.entity_id] = entry(item.entity_id, i)
  end
  entries["switch.configuration"].entity_category = "config"
  entries["switch.diagnostic"].entity_category = "diagnostic"
  entries["switch.hidden"].hidden_by = "user"
  entries["switch.disabled"].disabled_by = "integration"
  entries["light.c4"].platform = "control4"
  local result = assert(Choices.apply(rows, entries))
  T.eq(
    "Light retains independent switches, group and helper without a physical device",
    visible(result, "light"),
    { "light.binary", "light.dimmer", "light.helper", "light.native_group", "switch.a", "switch.b" }
  )
  T.eq(
    "Switch omits dimming-only choice and keeps binary targets",
    visible(result, "switch"),
    { "light.binary", "light.helper", "light.native_group", "switch.a", "switch.b" }
  )
  T.eq("identical names/device IDs did not merge endpoints", #visible(result, "light"), 6)
  T.eq("input metadata not mutated", rows[1].families, nil)
end
T.section("only proven non-inverted endpoint aliases collapse, independently of groups")
do
  local rows = codec.array({
    row("switch.relay"),
    row("light.wrapper_a"),
    row("light.wrapper_b"),
    row("light.inverted"),
    row("switch.other"),
    row("light.group", { is_group = true }),
    row("switch.foreign"),
    row("light.c4_wrapper"),
  })
  local entries = {}
  for i, item in ipairs(rows) do
    entries[item.entity_id] = entry(item.entity_id, i)
  end
  for _, id in ipairs({ "light.wrapper_a", "light.wrapper_b", "light.group", "light.inverted" }) do
    entries[id].platform = "switch_as_x"
    entries[id].options =
      wire({ switch_as_x = { entity_id = entries["switch.relay"].id, invert = id == "light.inverted" } })
  end
  entries["switch.foreign"].platform = "control4"
  entries["light.c4_wrapper"].platform = "switch_as_x"
  entries["light.c4_wrapper"].options = wire({ switch_as_x = { entity_id = "switch.foreign", invert = false } })
  local result = assert(Choices.apply(rows, entries))
  local by = keyed(result)
  T.eq(
    "one preferred wrapper replaces exact aliases",
    visible(result, "light"),
    { "light.group", "light.inverted", "light.wrapper_a", "switch.other" }
  )
  T.eq("binary aliases have consistent Switch choices", visible(result, "switch"), visible(result, "light"))
  T.eq(
    "preferred entry records exact aliases",
    by["light.wrapper_a"].entity_aliases,
    { "light.wrapper_b", "switch.relay" }
  )
  T.eq("group remains independent", by["light.group"].entity_aliases, {})
  T.eq("inverted relationship is never inferred equivalent", by["light.inverted"].entity_aliases, {})
  T.eq("wrapper cannot reimport a C4-exported load", by["light.c4_wrapper"].families, {})
  entries["switch.relay"].hidden_by = "integration"
  result = assert(Choices.apply(rows, entries))
  by = keyed(result)
  local _, aliases = Choices.endpointKeys(by["light.wrapper_a"])
  T.eq("the hidden base stays out of the picker", by["switch.relay"].families, {})
  T.eq("a non-inverted wrapper still identifies its hidden base for ownership checks", aliases["switch.relay"], true)
end
T.section("companion endpoint choices retain multiple functions and recheck native eligibility")
do
  local device = string.rep("a", 32)
  local function choice(id, registry, kind, load)
    local descriptor = {
      type = "device_choice",
      version = 1,
      device_id = device,
      choice_id = "device:" .. device .. ":" .. registry,
      kind = kind,
      source_load = load and { entity_id = load, registry_id = registry, domain = load:match("^([^.]+)") } or nil,
    }
    return row(id, {
      entity_id = descriptor.choice_id,
      domain = load and load:match("^([^.]+)") or "event",
      attributes = codec.object({ device_choice = descriptor }),
    })
  end
  local first, second = string.rep("1", 32), string.rep("2", 32)
  local rows = codec.array({
    choice("switch.a", first, "switch", "switch.a"),
    choice("light.b", second, "dimmer", "light.b"),
    choice("event.remote", "none", "remote"),
  })
  local entries = { ["switch.a"] = entry("switch.a", 1), ["light.b"] = entry("light.b", 2) }
  entries["switch.a"].id = first
  entries["light.b"].id = second
  local result = assert(Choices.apply(rows, entries))
  T.eq("two load functions plus remote remain usable in Light", #visible(result, "light"), 3)
  T.eq("Switch has binary function and remote", #visible(result, "switch"), 2)
  entries["switch.a"].entity_category = "config"
  result = assert(Choices.apply(rows, entries))
  T.eq("companion claim cannot override registry category", #visible(result, "switch"), 1)
  T.eq("source identity retained as metadata only", result[2].source_entity_id, "light.b")
end
T.section("Native discovery identifies a saved button source only for one eligible load")
do
  local device = string.rep("d", 32)
  local gesture = "event.wall_control"
  local rows = {
    row("switch.paddle", { bridge_gesture_entity_id = gesture, available = true }),
    row("switch.other_load", { bridge_gesture_entity_id = gesture, available = true }),
  }
  local entries = {
    ["switch.paddle"] = entry("switch.paddle", 1, { device_id = device, hidden_by = "user" }),
    ["switch.other_load"] = entry("switch.other_load", 2, { device_id = device }),
  }
  local both = keyed(Choices.apply(rows, entries, true))
  T.eq("one button with two eligible loads cannot hide either load", {
    Choices.gestureEntity(both["switch.paddle"]),
    Choices.gestureEntity(both["switch.other_load"]),
  }, {})
  entries["switch.other_load"].entity_category = "config"
  local filtered = keyed(Choices.apply(rows, entries, true))
  T.eq(
    "an enabled hidden load may account for the installed button source",
    Choices.gestureEntity(filtered["switch.paddle"]),
    gesture
  )
  T.eq(
    "a configuration-only switch is not paired with the button",
    Choices.gestureEntity(filtered["switch.other_load"]),
    nil
  )
end

T.section("scoped registry reads batch at fifty and reject extra or missing IDs")
do
  local rows = codec.array({})
  for i = 1, 51 do
    rows[i] = row("switch.endpoint_" .. i)
  end
  local requests = {}
  local pending = Choices.enrich(rows, function(message, callback)
    requests[#requests + 1] = { message = message, callback = callback }
  end, function()
    return true
  end)
  local result, problem
  pending:next(function(value)
    result = value
  end, function(error)
    problem = error.kind
  end)
  T.eq("first exact registry batch is bounded", #requests[1].message.entity_ids, 50)
  T.eq("only scoped registry operation", requests[1].message.type, "config/entity_registry/get_entries")
  local values = codec.object({})
  for i, id in ipairs(requests[1].message.entity_ids) do
    values[id] = entry(id, i)
  end
  requests[1].callback(true, values)
  T.eq("next batch contains only remainder", #requests[2].message.entity_ids, 1)
  local id = requests[2].message.entity_ids[1]
  requests[2].callback(true, codec.object({ [id] = entry(id, 51) }))
  T.eq("complete metadata yields all endpoints", #result, 51)
  T.eq("successful read has no failure", problem, nil)
  for _, bad in ipairs({ "extra", "missing", "permission" }) do
    local callback
    local work = Choices.enrich(codec.array({ row("switch.a") }), function(_, fn)
      callback = fn
    end, function()
      return true
    end)
    local failure
    work:next(nil, function(error)
      failure = error.kind
    end)
    if bad == "permission" then
      callback(false, { kind = "permission_denied" })
    elseif bad == "extra" then
      callback(true, codec.object({ ["switch.a"] = entry("switch.a"), ["switch.foreign"] = entry("switch.foreign") }))
    else
      callback(true, codec.object({}))
    end
    T.eq(
      bad .. " response fails without a broad retry",
      failure,
      bad == "permission" and "permission_denied" or "invalid_endpoint_metadata"
    )
  end
end
T.section("retired metadata callbacks cannot publish or read another batch")
do
  local active, callback, requests = true, nil, 0
  local pending = Choices.enrich(codec.array({ row("switch.a") }), function(_, fn)
    requests = requests + 1
    callback = fn
  end, function()
    return active
  end)
  local failure, value
  pending:next(function(result)
    value = result
  end, function(error)
    failure = error.kind
  end)
  active = false
  callback(true, codec.object({ ["switch.a"] = entry("switch.a") }))
  T.eq("old metadata is retired", failure, "retired")
  T.eq("old metadata cannot publish", value, nil)
  T.eq("old metadata creates no further resources", requests, 1)
end
T.finish()

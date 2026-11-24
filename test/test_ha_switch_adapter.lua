local T = require("testlib")
local clock = require("c4_fixtures").virtualClock()
local codec = require("ha.codec")
local deferred = require("deferred")
local ids = require("ha.identities")
local metrics = require("ha.performance").shared
local operations = require("ha.operations")
local Adapter = require("ha.switch-adapter")
local values = require("lib.values")

local adapter = Adapter.new()
local target, commands, notes, events, results = "switch.lab", {}, {}, {}, {}
local ready, current = false, true
local feedbackChanges = 0
local consumer = { readiness = {} }
function consumer.readiness:view(entity)
  return { evidence_ready = ready and entity == target }
end
function consumer:_current()
  if not current then
    adapter:lost()
    return false
  end
  return true
end
function consumer:request(operation, entity, arguments)
  local promise = deferred.new()
  if not self:_current() then
    promise:reject({ kind = "retired" })
    return promise
  end
  commands[#commands + 1] = {
    rpc = operation == "read_load" and { entity = entity, operation = operation }
      or assert(operations.build(operation, entity, arguments)),
    promise = promise,
  }
  return promise
end
function C4:SendToProxy(binding, command, params, direction)
  notes[#notes + 1] = { binding, command, params, direction }
end
function C4:FireEventByID(id)
  events[#events + 1] = id
end
local function bind(entity)
  adapter:bind(
    consumer,
    entity,
    function(status)
      results[#results + 1] = status
    end,
    false,
    function()
      feedbackChanges = feedbackChanges + 1
    end
  )
end
local function state(kind, value, entity)
  adapter:message(kind, { entity_id = entity or target, state = value, attributes = codec.object({}) })
end
local function icon(id, label)
  return { ids.proxy, "ICON_CHANGED", { icon = id, icon_description = label } }
end

T.section("Navigator and relay have no authority before selected feedback")
adapter:start()
T.eq("starting icon", notes, { icon("unavailable", "Unavailable") })
bind(target)
T.eq("On before snapshot", EC.TurnOn(), false)
T.eq("relay before snapshot", ReceivedFromProxy(ids.relay, "CLOSE"), false)
T.eq("Navigator before snapshot", ReceivedFromProxy(ids.proxy, "SELECT"), false)
T.eq("no commands before snapshot", #commands, 0)
T.eq("no On or Off assertion", { TestCondition("IS_ON"), TestCondition("IS_OFF") }, { false, false })

T.section("Only exact selected state publishes a native icon and confirmed relay")
ready = true
state("snapshot", "on", "switch.foreign")
T.eq("foreign state ignored", #notes, 1)
state("snapshot", "off")
T.eq("initial snapshot icon", notes[2], icon("off", "Off"))
T.eq("initial relay evidence", notes[3], { ids.relay, "STATE_OPENED", {}, "NOTIFY" })
T.eq("snapshot does not replay events", #events, 0)
T.eq("confirmed availability and state", { TestCondition("IS_AVAILABLE"), TestCondition("IS_OFF") }, { true, true })
T.eq("shared State variable", values:getValue("State").value, "Off")

T.section("Native command surfaces request exact services without optimistic feedback")
metrics:setEnabled(true)
ReceivedFromProxy(ids.proxy, "SELECT")
ReceivedFromProxy(ids.relay, "CLOSE")
ReceivedFromProxy(ids.links.bottom, "DO_CLICK")
EC.Toggle()
T.eq("button Push/Release does not double trigger a click", ReceivedFromProxy(ids.links.bottom, "DO_PUSH"), false)
T.eq("brightness not accepted", ReceivedFromProxy(ids.proxy, "SET_LEVEL", { LEVEL = "50" }), false)
T.eq("other bindings cannot issue relay commands", ReceivedFromProxy(42, "CLOSE"), nil)
T.eq("only supported native commands sent", #commands, 4)
for i, action in ipairs({ "toggle", "turn_on", "turn_off", "toggle" }) do
  T.eq("exact load " .. i, commands[i].rpc.target, { entity_id = target })
  T.eq("exact action " .. i, commands[i].rpc.service, action)
  T.eq("no guessed action parameters " .. i, commands[i].rpc.service_data, {})
end
commands[1].promise:resolve({})
commands[2].promise:reject({ kind = "timeout" })
T.eq("earlier completions do not replace the latest result", results, {})
T.eq("no icon or relay from acceptance and failure", #notes, 3)
state("state", "on")
T.eq("confirmed new icon", notes[4], icon("on", "On"))
T.eq("confirmed relay notification", notes[5], { ids.relay, "CLOSED", {}, "NOTIFY" })
T.eq("one real state transition fires one event", events, { ids.events.stateOn })
state("state", "on")
state("snapshot", "off")
T.eq("duplicates and new snapshots do not replay a transition", events, { ids.events.stateOn })
T.eq("a changed refresh is state-only relay feedback", notes[#notes], { ids.relay, "STATE_OPENED", {}, "NOTIFY" })
T.eq("local command timing counts", metrics:report().operations["switch.toggle"].count, 2)
T.eq(
  "local feedback timing captures distinct published states",
  metrics:report().operations["switch.feedback"].count,
  2
)
metrics:setEnabled(false)

T.section("Unavailable is not Open, and pending edits retire old relay authority")
state("state", "unavailable")
T.eq("unavailable icon", notes[#notes], icon("unavailable", "Unavailable"))
T.eq("native unavailable event", events[#events], ids.events.unavailable)
T.eq("no guessed Off on loss", TestCondition("IS_OFF"), false)
T.eq("no command on lost link", EC.TurnOff(), false)
T.eq("late acceptance suppressed", #results, 0)
commands[3].promise:resolve({})
T.eq("loss retired unresolved request result", #results, 0)

state("snapshot", "off")
current = false
T.eq("pending edit prevents native command", EC.TurnOn(), false)
T.eq("pending edit clears icon", notes[#notes], icon("unavailable", "Unavailable"))
T.eq("pending edit sends no service", #commands, 4)
current = true
bind(nil)
state("snapshot", "on")
T.eq("buttons-only/unbound selection has no load state", TestCondition("IS_ON"), false)
T.eq("buttons-only/unbound selection cannot control a load", EC.Toggle(), false)

T.section("Legacy click packets use the current relay and Button Link bindings")
bind(target)
local topClick = { ACTION = "2", BUTTON_ID = "0" }
T.eq("legacy click waits for selected feedback", ReceivedFromProxy(ids.links.top, "BUTTON_ACTION", topClick), false)
state("snapshot", "off")
local beforeCommands, beforeNotes = #commands, #notes
local packets = {
  { ids.links.top, topClick, "turn_on" },
  { ids.links.bottom, { ACTION = 2, BUTTON_ID = 1 }, "turn_off" },
  { ids.links.toggle, { ACTION = "2", BUTTON_ID = "2" }, "toggle" },
  { ids.links.toggle, { ACTION = "2", BUTTON_ID = "" }, "toggle" },
  { ids.relay, { ACTION = "2", BUTTON_ID = "3" }, "toggle" },
  { ids.links.top, { ACTION = 2, BUTTON_ID = 9 }, "toggle" },
  { ids.relay, topClick, "turn_on" },
}
for _, packet in ipairs(packets) do
  local count = #commands
  T.eq("binding permits the legacy click", ReceivedFromProxy(packet[1], "BUTTON_ACTION", packet[2]), true)
  T.eq("click sends one service for its reported button", { #commands, commands[#commands].rpc.service }, {
    count + 1,
    packet[3],
  })
end
for _, params in ipairs({
  { ACTION = "0", BUTTON_ID = "0" },
  { ACTION = "1", BUTTON_ID = "0" },
  { ACTION = "3", BUTTON_ID = "0" },
  { ACTION = "0x2", BUTTON_ID = "0" },
  { ACTION = "2" },
  { BUTTON_ID = "1" },
  { ACTION = "2", BUTTON_ID = "not a button" },
  { ACTION = "2", BUTTON_ID = false },
  { ACTION = true, BUTTON_ID = "0" },
  {},
}) do
  T.eq("non-click or malformed packet is ignored", ReceivedFromProxy(ids.relay, "BUTTON_ACTION", params), false)
end
for _, binding in ipairs({ ids.coordinatorBinding, ids.proxy, 200, 42 }) do
  T.falsy("unrelated binding cannot control the load", ReceivedFromProxy(binding, "BUTTON_ACTION", topClick))
end
T.eq("invalid and unrelated packets send no service", #commands, beforeCommands + #packets)
T.eq("legacy commands do not publish speculative feedback", #notes, beforeNotes)

T.section("Composer power actions and saved command IDs dispatch the same way")
local savedActions = {
  { "Turn On", "turn_on" },
  { "Turn Off", "turn_off" },
  { "Toggle", "toggle" },
  { "TurnOn", "turn_on" },
  { "TurnOff", "turn_off" },
}
for _, action in ipairs(savedActions) do
  local count = #commands
  T.eq("Composer dispatch accepts " .. action[1], ExecuteCommand(action[1], {}), true)
  T.eq("Composer dispatch targets the selected load", { #commands, commands[#commands].rpc.service }, {
    count + 1,
    action[2],
  })
end

T.section("An older success cannot replace the latest timeout")
bind(target)
state("snapshot", "off")
EC.TurnOn()
local older = commands[#commands].promise
EC.TurnOff()
commands[#commands].promise:reject({ kind = "timeout" })
older:resolve({})
T.eq("latest failure is the visible result", results[#results], "timeout")

T.section("An accepted service with missing feedback gets one exact recovery read")
bind(target)
state("snapshot", "off")
local start = #commands
local eventCount = #events
EC.TurnOn()
commands[#commands].promise:resolve({})
T.eq("service acceptance leaves confirmed power alone", TestCondition("IS_OFF"), true)
clock.run(2999)
T.eq("wait for normal push first", #commands, start + 1)
clock.run(1)
T.eq("read only the currently selected load", commands[#commands].rpc, { entity = target, operation = "read_load" })
if #commands > start + 1 then
  commands[#commands].promise:resolve(codec.object({ entity_id = target, state = "on", attributes = codec.object({}) }))
end
T.eq("an exact read restores relay feedback", TestCondition("IS_ON"), true)
T.eq("an exact read does not replay a programming event", #events, eventCount)
clock.run(10000)
T.eq("no follow-up polling", #commands, start + 2)

T.section("Matching pushes retire confirmation without a read")
bind(target)
state("snapshot", "off")
local healthyStart = #commands
EC.TurnOn()
state("state", "on")
commands[#commands].promise:resolve({})
EC.TurnOff()
commands[#commands].promise:resolve({})
state("state", "off")
EC.TurnOff()
commands[#commands].promise:resolve({})
clock.run(10000)
T.eq("early, late and idempotent confirmation stay on the usual path", #commands, healthyStart + 3)

T.section("Overlapping toggles wait for both results before one exact confirmation")
EC.Toggle()
local earlier = commands[#commands].promise
EC.Toggle()
local count = #commands
commands[count].promise:resolve({})
state("state", "on")
clock.run(3000)
T.eq("an earlier push does not finish the overlapping batch", #commands, count)
earlier:resolve({})
clock.run(3000)
T.eq("overlap uses only one exact read", #commands, count + 1)
local read = commands[#commands].promise
state("state", "off")
read:resolve(codec.object({ entity_id = target, state = "on", attributes = codec.object({}) }))
T.eq("a newer push wins over the outstanding read", TestCondition("IS_OFF"), true)

T.section("Failed feedback read retires control and clears on a fresh report")
EC.TurnOn()
commands[#commands].promise:reject({ kind = "timeout" })
T.eq("uncertain command result starts an exact read", commands[#commands].rpc.operation, "read_load")
commands[#commands].promise:reject({ kind = "timeout" })
T.eq("feedback loss is unavailable, not Off", { TestCondition("IS_AVAILABLE"), TestCondition("IS_OFF") }, {
  false,
  false,
})
T.eq("existing setup status is refreshed once", feedbackChanges, 1)
T.truthy("setup can distinguish a feedback failure", adapter.feedbackUnavailable)
state("snapshot", "on")
T.eq("fresh selected feedback restores control", TestCondition("IS_ON"), true)
T.falsy("fresh selected feedback clears the status", adapter.feedbackUnavailable)
EC.TurnOff()
commands[#commands].promise:reject({ kind = "permission_denied" })
clock.run(10000)
T.eq("definite rejection sends no read", commands[#commands].rpc.service, "turn_off")
T.eq("definite rejection retains confirmed state", TestCondition("IS_ON"), true)

T.section("A replacement selection ignores a late recovery read")
EC.TurnOff()
commands[#commands].promise:resolve({})
clock.run(3000)
local retiredRead = commands[#commands].promise
bind(target)
state("snapshot", "on")
retiredRead:resolve(codec.object({ entity_id = target, state = "off", attributes = codec.object({}) }))
T.eq("late read cannot alter the replacement lifetime", TestCondition("IS_ON"), true)
T.eq("no swallowed timer or deferred errors", clock.errors, {})

T.section("Permanent destruction retires old callbacks and preserves replacement handlers")
local old = RFP[ids.proxy]
local replacement = function() end
local beforeDestroy = #commands
RFP[ids.proxy] = replacement
adapter:destroy()
adapter:start()
old(ids.proxy, "SELECT")
T.eq("stale handler cannot send", #commands, beforeDestroy)
T.eq("replacement survives old cleanup", RFP[ids.proxy], replacement)
T.eq("owned relay and conditionals removed", { RFP[ids.relay], TC.IS_ON }, {})
T.finish()

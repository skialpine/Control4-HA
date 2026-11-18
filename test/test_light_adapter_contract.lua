-- Focused regressions against the pinned template library plus its narrow corrections.
local T = require("testlib")
local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local Light = require("lib.light")

local function rig(fade)
  local clock = F.virtualClock()
  local proxy = P.install(clock)
  local sent, reads = {}, 0
  local light
  local adapter = {
    send = function(_, command)
      sent[#sent + 1] = command
    end,
    refresh = function()
      reads = reads + 1
    end,
    show = function() end,
  }
  light = Light.new(adapter, {
    api = 1,
    dims = true,
    fades = true,
    defaultOn = false,
    links = { top = 300, toggle = 301, bottom = 302 },
    loadGroups = true,
  })
  light:declare({ dims = true, color = false, fade = fade, feedback = { refresh = false } })
  light:start()
  light:report({ kind = "push", on = false, level = 1 })
  return {
    light = light,
    clock = clock,
    proxy = proxy,
    sent = sent,
    adapter = adapter,
    reads = function()
      return reads
    end,
    done = function()
      light:destroy()
      proxy:restore()
      clock.restore()
    end,
  }
end

T.section("logical On differs from an explicit request for the same numeric level")
local h = rig({ kind = "device" })
h.proxy:send("ON")
T.eq("logical intent", h.sent[#h.sent].intent, "on")
T.eq("numeric full level carried", h.sent[#h.sent].level, 1)
h.proxy:send("SET_LEVEL", { LEVEL = "100" })
T.eq("explicit intent", h.sent[#h.sent].intent, "level")
T.eq("same number does not decide intent", h.sent[#h.sent].level, 1)
h.proxy:send("OFF")
T.eq("off intent", h.sent[#h.sent].intent, "off")
h.light:report({ kind = "push", on = false, level = 1 })
h.proxy:send("TOGGLE")
T.eq("toggle resolves to logical On", h.sent[#h.sent].intent, "on")
h.done()

T.section("destruction cancels walked work and old callbacks cannot refresh, send or publish")
h = rig({ kind = "walk", stepMs = 50 })
h.proxy:send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "5000" })
local staleHandler, staleStep = RFP[5001], h.light._walkStep
local sent, notes, reads = #h.sent, #h.proxy.notes, h.reads()
h.light:destroy()
h.light:destroy()
h.light:start()
h.light:reset()
h.light:report({ kind = "push", on = true, level = 0.8 })
staleHandler(5001, "ON", {}, {})
staleStep(h.light)
h.clock.run(20000)
T.eq("no future commands", #h.sent, sent)
T.eq("no notifications after destruction", #h.proxy.notes, notes)
T.eq("never refreshes on destruction or stale restart", h.reads(), reads)
T.eq("queue retired", h.light.waiting, {})
T.eq("proxy handler removed", RFP[5001], nil)
T.eq("group handler removed", EC.LIGHT_GROUP_JOIN, nil)
T.eq("no callback errors", h.clock.errors, {})
h.done()

T.section("cleanup continues if one part fails and replacement handlers remain registered")
h = rig({ kind = "device" })
h.proxy:send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "5000" })
local cleaned = false
h.light.motion.reset = function()
  error("injected cleanup failure")
end
h.light.scenes.reset = function()
  cleaned = true
end
local replacement = function() end
RFP[5001] = replacement
h.light:destroy()
T.eq("later cleanup still ran", cleaned, true)
local timers = {}
for name in pairs(Timer) do
  if type(name) == "string" and name:match("^Light%.") then
    timers[#timers + 1] = name
  end
end
T.eq("failed reset leaves no Light timers", timers, {})
T.eq("replacement keeps ownership", RFP[5001], replacement)
local n = #h.sent
h.light:command({ kind = "on", source = "proxy" })
h.clock.run(10000)
T.eq("failed cleanup cannot restore authority", #h.sent, n)
h.done()

T.section("destruction during send stops the remaining pre-on/change sequence")
h = rig({ kind = "device", preOn = true })
h.adapter.send = function(_, command)
  h.sent[#h.sent + 1] = command
  h.light:destroy()
end
h.proxy:send("RAMP_TO_LEVEL", { LEVEL = "80", TIME = "2000" })
T.eq("only the first command sent", #h.sent, 1)
T.eq("first was pre-on", h.sent[1].kind, "preOn")
h.done()
T.finish()

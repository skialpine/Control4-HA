local T = require("testlib")
local codec = require("ha.codec")
local deferred = require("deferred")
local metrics = require("ha.performance").shared
require("drivers-common-public.global.handlers")
require("lib.utils")
local testPath = debug.getinfo(1, "S").source:sub(2)
local labPath = (testPath:match("^(.*)test/[^/]+$") or "../") .. "lab/quick_setup_benchmark.lua"
local benchmark = dofile(labPath)

local refreshes, reads = 0, 0
local revision = string.rep("a", 64)
local catalog = {}
function catalog:refresh(force)
  T.truthy("first browse forces a fresh catalog", force)
  refreshes = refreshes + 1
  self.snapshot = {}
  return deferred.new():resolve({ revision = revision })
end
function catalog:read(requested, cursor, index)
  T.eq("browse reads the verified scope and revision", { requested, cursor, index }, { revision, nil, "quick_fan" })
  reads = reads + 1
  return { total = 25, entities = {}, revision = revision }
end
function catalog:hasVerifiedSnapshot(candidate)
  return candidate == revision
end
local owner = { online = true, commissioning = {} }
function owner:catalogFor(family)
  assert(family == "fan")
  return catalog
end
function owner.commissioning:browseChoices()
  return deferred.new():resolve({ existing = {}, staged = {} })
end

T.section("The lab probe runs normal Quick Setup browse and returns only aggregate timings")
metrics.enabled = true
benchmark.install(function()
  return owner
end)
local nonce = string.rep("a", 32)
local params = { NONCE = nonce, SETUP = "fan", COUNT = "3" }
local function report()
  local payload = assert(UIR.HA_LAB_QUICK_SETUP_RESULT(params):match("^<quick_setup>(.+)</quick_setup>$"))
  return codec.decode(C4:Base64Decode(payload))
end
T.eq(
  "a known family can schedule a bounded read-only measurement",
  UIR.HA_LAB_QUICK_SETUP(params),
  "<quick_setup>scheduled</quick_setup>"
)
local result = report()
T.eq("the first report is cold and correlated", { result.status, result.nonce, result.cold, result.total }, {
  "measured",
  nonce,
  true,
  25,
})
T.eq("warm samples use only the same verified revision", { refreshes, reads, #result.warm_ms }, { 1, 4, 3 })
T.eq(
  "a stale nonce cannot read this result",
  UIR.HA_LAB_QUICK_SETUP_RESULT({ NONCE = string.rep("b", 32) }),
  "<quick_setup>unknown</quick_setup>"
)
params.COUNT = "6"
T.eq("larger requests are refused", UIR.HA_LAB_QUICK_SETUP(params), "<quick_setup>unavailable</quick_setup>")
params.COUNT = "1"
T.eq(
  "a second run can measure a forced refresh",
  UIR.HA_LAB_QUICK_SETUP(params),
  "<quick_setup>scheduled</quick_setup>"
)
result = report()
T.eq("the repeat is labeled as an existing cache", { result.status, result.cold }, { "measured", false })

T.section("The fixture applies only an explicit current preview on the pinned HA connection")
local origin = "https://ha-lab.example.invalid:8123"
local archive = "fixture archive bytes"
local fixture = {
  origin_hash = C4:Hash("SHA256", origin, { return_encoding = "HEX" }):lower(),
  family = "fan",
  choice = "fan.qualification",
  room = 10,
  name = "Qualification Fan",
  file = "Qualification.Fan.c4z",
  archive_hash = C4:Hash("SHA256", archive, { return_encoding = "HEX" }):lower(),
}
owner.connection = { config = { origin = "https://another.example.invalid" } }
local baseRead, applied = catalog.read, 0
function catalog:read(...)
  local result = baseRead(self, ...)
  result.entities = { { entity_id = fixture.choice, attributes = {}, families = { "fan" } } }
  return result
end
function owner.commissioning:preview(request)
  local item = request.choices[1]
  return deferred.new():resolve({
    id = "fixture-plan",
    items = {
      { choice_id = item.choice_id, family = item.family, room_id = item.room_id, name = item.name, decision = "add" },
    },
  })
end
function owner.commissioning:execute(plan)
  T.eq("only the actual Quick Setup plan can apply", plan, "fixture-plan")
  applied = applied + 1
  ShimFiles("C4Z_ROOT")[fixture.file] = archive
  return deferred.new():resolve({ complete = true, items = { { device_id = 29, status = "added" } } })
end
benchmark.install(function()
  return owner
end, fixture)
params.SETUP = "fixture_preview"
T.eq(
  "a mismatched HA origin prevents even the fixture preview",
  UIR.HA_LAB_QUICK_SETUP(params),
  "<quick_setup>unavailable</quick_setup>"
)
owner.connection.config.origin = origin
T.eq("the pinned fixture can be previewed", UIR.HA_LAB_QUICK_SETUP(params), "<quick_setup>scheduled</quick_setup>")
T.eq("preview does not add a driver", { report().status, applied }, { "reviewed", 0 })
T.eq("the file is absent during preview", report().archive, "absent")
params.SETUP = "fixture_apply"
T.eq(
  "a different approval cannot apply",
  UIR.HA_LAB_QUICK_SETUP({ NONCE = string.rep("b", 32), SETUP = params.SETUP, COUNT = "1" }),
  "<quick_setup>unavailable</quick_setup>"
)
T.eq("the current approval applies once", UIR.HA_LAB_QUICK_SETUP(params), "<quick_setup>scheduled</quick_setup>")
T.eq("the added package matches the original archive", report().archive, "verified")
T.eq(
  "confirmed receipt identifies the created fixture",
  { report().status, report().device_id, applied },
  { "added", 29, 1 }
)
T.eq(
  "replaying an approval does not add another driver",
  UIR.HA_LAB_QUICK_SETUP(params),
  "<quick_setup>unavailable</quick_setup>"
)

T.finish()

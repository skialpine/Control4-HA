local T = require("testlib")
local codec = require("ha.codec")
local migration = require("ha.migration-lighting")
require("drivers-common-public.global.lib")

local function item(id, file, name, state, subitems)
  return ("<item><id>%d</id><c4i>%s</c4i><name>%s</name><state>%s</state>%s</item>"):format(
    id,
    file,
    name,
    XMLEncode(state),
    subitems or ""
  )
end

local function project(...)
  return "<systemitems>" .. table.concat({ ... }) .. "</systemitems>"
end

local function sceneXml(elements, active)
  return "<AdvScene><scene_id>0</scene_id><name>Outside</name><is_active>"
    .. (active or "False")
    .. "</is_active><all_members>"
    .. elements
    .. "</all_members></AdvScene>"
end

local function sceneAgent(elements, active)
  return item(
    30,
    "control4_agent_adv_lighting.c4i",
    "Advanced Lighting",
    "<State><all_scenes>" .. sceneXml(elements, active) .. "</all_scenes><all_off_toggle_scenes /></State>"
  )
end

local function sceneMember(id, rate)
  return (
    "<AdvSceneMember><device_id>%d</device_id><track_level_tracking>True</track_level_tracking>"
    .. "<ignore_ramp>False</ignore_ramp><all_elements><element><level>80</level><levelRate>%d</levelRate>"
    .. "</element></all_elements></AdvSceneMember>"
  ):format(id, rate)
end

local function read(raw, id)
  local groups, scope, groupMembers = migration.groups(raw, { [id] = true })
  local scenes, sceneMembers = migration.scenes(raw, scope)
  return { version = 2, scenes = scenes, groups = groups, members = { scenes = sceneMembers, groups = groupMembers } }
end

T.section("Advanced Lighting references come from live project state")
local first = read(project(sceneAgent(sceneMember(51, 750))), 51)
local second = read(project(sceneAgent(sceneMember(52, 750), "True")), 52)
local edited = read(project(sceneAgent(sceneMember(52, 500))), 52)
T.eq("scene ID zero and its name are retained", first.scenes[51][0].name, "Outside")
T.eq("the member settings compare across different device IDs", first.scenes[51][0].saved, second.scenes[52][0].saved)
T.neq("the ramp rate is part of verification", first.scenes[51][0].saved, edited.scenes[52][0].saved)
T.truthy("the member move verifies even as the scene active status changes", migration.compare(first, second, 51, 52))
T.falsy("an altered ramp rate prevents cutover", migration.compare(first, edited, 51, 52))
local checkpoint = codec.storedObject(codec.encode(migration.checkpoint(first)))
T.eq("the journal retains the sparse device and zero scene keys", checkpoint.scenes["51"]["0"].name, "Outside")
T.eq(
  "the journal retains the full member settings at scene zero",
  checkpoint.members.scenes["0"]["51"],
  first.scenes[51][0].saved
)
T.truthy(
  "readback still verifies after serializing and restoring the staged journal",
  migration.compare(checkpoint, second, 51, 52)
)
local untyped = codec.storedObject(JSON:decode(codec.encode(checkpoint)))
T.neq("decoded persistence drops the empty group map markers", codec.encode(untyped), codec.encode(checkpoint))
T.eq(
  "empty map markers do not affect the durable proof",
  migration.checkpointProof(untyped),
  migration.checkpointProof(checkpoint)
)
untyped.members.scenes["0"]["51"] = edited.members.scenes["0"]["52"]
T.neq(
  "a changed member still invalidates the durable proof",
  migration.checkpointProof(untyped),
  migration.checkpointProof(checkpoint)
)
untyped.members.groups = nil
T.eq("a missing group map cannot prove a scene checkpoint", migration.checkpointProof(untyped), nil)
T.falsy(
  "a missing group read is never treated as an empty group inventory",
  migration.compare(first, { version = 2, scenes = second.scenes }, 51, 52)
)
T.falsy(
  "a saved checkpoint from before complete member capture cannot verify the move",
  migration.compare({ scenes = checkpoint.scenes, groups = checkpoint.groups }, second, 51, 52)
)
T.raises("duplicate scene member is unresolved", function()
  migration.scenes(project(sceneAgent(sceneMember(51, 750) .. sceneMember(51, 750))), { [52] = true })
end)

T.section("Current scene verification uses the agent's reply when project XML is stale")
do
  local originalItems, originalRequest = C4.GetProjectItems, C4.SendUIRequest
  function C4:GetProjectItems()
    return project(sceneAgent(sceneMember(51, 750)))
  end
  local reply = sceneXml(sceneMember(52, 750), "True")
  function C4:SendUIRequest(agent, command, params)
    T.eq(
      "requests the saved scene ID from the native agent",
      { agent, command, params.SCENE_ID },
      { 30, "GET_SCENE", 0 }
    )
    return reply
  end
  local snapshot = migration.snapshot()
  local scope = { [51] = true, [52] = true }
  local saved = checkpoint.members.scenes
  local current = migration.read(scope, snapshot, saved)
  T.truthy("the live replacement verifies against the saved settings", migration.compare(checkpoint, current, 51, 52))
  T.truthy("the discovery snapshot still has its original membership", migration.read(scope, snapshot).scenes[51][0])
  reply = reply:gsub("<scene_id>0", "<scene_id>1")
  T.falsy("a reply for another scene blocks cutover", migration.complete(migration.read(scope, snapshot, saved)))
  C4.GetProjectItems, C4.SendUIRequest = originalItems, originalRequest
end

T.section("Verification reads each scene once and catches newly discovered membership")
do
  local readProject, readScene = C4.GetProjectItems, C4.SendUIRequest
  local source, replacement, unrelated = sceneMember(51, 750), sceneMember(52, 750), sceneMember(73, 800)
  local function catalog(first, second)
    return project(
      item(
        30,
        "control4_agent_adv_lighting.c4i",
        "Advanced Lighting",
        "<State><all_scenes>"
          .. sceneXml(first)
          .. sceneXml(second):gsub("<scene_id>0", "<scene_id>1"):gsub("<name>Outside", "<name>Hall")
          .. "</all_scenes></State>"
      )
    )
  end
  local reads, second = {}, unrelated
  function C4:SendUIRequest(_, command, params)
    T.eq("only native reads are issued", command, "GET_SCENE")
    local id = params.SCENE_ID
    reads[#reads + 1] = id
    return id == 0 and sceneXml(replacement)
      or sceneXml(second):gsub("<scene_id>0", "<scene_id>1"):gsub("<name>Outside", "<name>Hall")
  end
  local scope = { [51] = true, [52] = true }
  local approved = migration.checkpoint(read(catalog(source, unrelated), 51))
  function C4:GetProjectItems()
    return catalog(source, unrelated .. replacement)
  end
  second = unrelated .. replacement
  local discovered = migration.read(scope, nil, approved.members.scenes)
  table.sort(reads)
  T.eq("both the reviewed and newly discovered references get one native read", reads, { 0, 1 })
  T.falsy("an extra replacement reference blocks verification", migration.compare(approved, discovered, 51, 52))

  function C4:GetProjectItems()
    return catalog(source, unrelated)
  end
  reads = {}
  local current = migration.read(scope, nil, approved.members.scenes, true)
  table.sort(reads)
  T.eq("authorization reads each known scene once even when its projected membership lags", reads, { 0, 1 })
  T.falsy("native-only membership in a known scene blocks verification", migration.compare(approved, current, 51, 52))

  reads, second = {}, unrelated
  approved = migration.checkpoint(read(catalog(source, unrelated), 51))
  local plan = migration.directScenePlan(approved, 51)
  function C4:SendUIRequest(_, _, params)
    reads[#reads + 1] = params.SCENE_ID
    return sceneXml(source)
  end
  current = migration.read(scope, nil, approved.members.scenes)
  T.truthy(
    "preflight can reuse the native reply from reference discovery",
    migration.intactSceneStage(plan, 52, current)
  )
  T.eq("one native read serves both checks in the same boundary", reads, { 0 })
  C4.GetProjectItems, C4.SendUIRequest = readProject, readScene
end

T.section("Unused tracking coordinates may change for replacements and siblings")
do
  local function colorMember(id, tracked, enabled, x, y)
    return sceneMember(id, 750)
      :gsub(
        "<all_elements>",
        (
          "<track_color_tracking>%d</track_color_tracking>"
          .. "<track_color_x>%s</track_color_x><track_color_y>%s</track_color_y><all_elements>"
        ):format(tracked, x, y)
      )
      :gsub("<level>", "<colorEnabled>" .. enabled .. "</colorEnabled><level>")
  end
  for _, case in ipairs({
    { 0, "False", 0.31, true },
    { 1, "False", 0.31, false },
    { 0, "True", 0.31, false },
    { 0, "False", "invalid", false },
  }) do
    local before = read(project(sceneAgent(colorMember(51, case[1], case[2], 0, 0))), 51)
    local after = read(project(sceneAgent(colorMember(52, case[1], case[2], case[3], 0.32))), 52)
    T.eq(
      "replacement comparison tolerates only unused, valid tracking coordinates",
      migration.compare(before, after, 51, 52),
      case[4]
    )
    local staged = read(project(sceneAgent(sceneMember(51, 750) .. colorMember(73, case[1], case[2], 0, 0))), 51)
    local current =
      read(project(sceneAgent(sceneMember(52, 750) .. colorMember(73, case[1], case[2], case[3], 0.32))), 52)
    T.eq(
      "the same coordinate rule applies to an unchanged sibling",
      migration.compare(staged, current, 51, 52),
      case[4]
    )
  end
end

T.section("Native scene readback may include omitted values for an inactive color action")
do
  local function member(id, enabled, tracking, fields)
    local color = ("<colorEnabled>%s</colorEnabled>%s"):format(enabled, fields or "")
    return (
      sceneMember(id, 750)
        :gsub("<all_elements>", "<track_color_tracking>" .. tracking .. "</track_color_tracking><all_elements>")
        :gsub("</element>", color .. "</element>")
    )
  end
  local color = "<colorHue>50</colorHue><colorSaturation>20</colorSaturation><colorTemperature>2900</colorTemperature>"
  for _, case in ipairs({
    { "accept inactive readback-only color values", "False", 0, nil, color, true },
    {
      "preserve the saved color when both projections include it",
      "False",
      0,
      color,
      color:gsub(">50<", ">60<"),
      false,
    },
    { "check color when the scene action is enabled", "True", 0, nil, color, false },
    { "check color while the scene tracks it", "False", 1, nil, color, false },
    { "reject an invalid readback value", "False", 0, nil, "<colorHue>invalid</colorHue>", false },
    { "retain an explicit saved value if the readback omits it", "False", 0, color, nil, false },
    { "preserve unrecognized fields", "False", 0, nil, "<colorPresetID>4</colorPresetID>", false },
  }) do
    local label, enabled, tracking, beforeFields, afterFields, matches = unpack(case, 1, 6)
    local before = read(project(sceneAgent(member(51, enabled, tracking, beforeFields))), 51)
    local after = read(project(sceneAgent(member(52, enabled, tracking, afterFields))), 52)
    T.eq(label, migration.compare(before, after, 51, 52), matches)
  end
end

T.section("Scene comparison preserves ordered active steps and understands native representation")
do
  local function step(level, rate, enabled, extra)
    return ("<element><level>%s</level><levelRate>%s</levelRate><colorEnabled>%s</colorEnabled>%s</element>"):format(
      level,
      rate,
      enabled,
      extra or ""
    )
  end
  local function snapshot(id, steps, x)
    local sibling = (
      "<AdvSceneMember><device_id>73</device_id><track_color_tracking>0</track_color_tracking>"
      .. "<track_color_x>%s</track_color_x><track_color_y>0.3</track_color_y><all_elements>%s</all_elements>"
      .. "</AdvSceneMember>"
    ):format(x, steps)
    return read(project(sceneAgent(sceneMember(id, 750) .. sibling)), id)
  end
  local first, nextStep = step(20, 500, "False"), step(40, 750, "False")
  local spellings = step("20.0", "0500", "false", "<colorHue>25</colorHue>")
  local saved = codec.storedObject(codec.encode(migration.checkpoint(snapshot(51, first .. nextStep, 0.2))))
  T.truthy(
    "saved multi-step proof accepts equivalent fields on a disabled sibling",
    migration.compare(saved, snapshot(52, spellings .. nextStep, 0.4), 51, 52)
  )
  T.truthy(
    "the same proof compares a preview and its fresh recheck with no moves",
    migration.compare(saved, snapshot(51, spellings .. nextStep, 0.4))
  )
  T.falsy("step order remains significant", migration.compare(saved, snapshot(52, nextStep .. first, 0.2), 51, 52))
  T.falsy(
    "a real fade still differs",
    migration.compare(saved, snapshot(52, step(20, 501, "False") .. nextStep, 0.4), 51, 52)
  )
  T.falsy(
    "an unknown property remains significant",
    migration.compare(
      saved,
      snapshot(52, step(20, 500, "False", "<futureField>25</futureField>") .. nextStep, 0.2),
      51,
      52
    )
  )
  local active = step(40, 750, "True")
  local activeSaved = snapshot(51, first .. active, 0.2)
  T.falsy(
    "coordinate drift cannot be ignored if any step has active color",
    migration.compare(activeSaved, snapshot(52, spellings .. active, 0.4), 51, 52)
  )
  T.truthy(
    "an inactive step can still omit readback-only color beside an active step",
    migration.compare(activeSaved, snapshot(52, spellings .. active, 0.2), 51, 52)
  )
end

T.section("Saved-stage trace identifies the rejecting check before any scene write")
do
  local log = require("lib.logging")
  local originalItems, originalRequest, originalPrint = C4.GetProjectItems, C4.SendUIRequest, print
  local original, sibling = sceneMember(51, 750), sceneMember(73, 820)
  local snapshot = project(sceneAgent(original .. sibling))
  local plans = migration.directScenePlan(migration.checkpoint(read(snapshot, 51)), 51)
  function C4:GetProjectItems()
    return snapshot
  end
  local reply, calls, lines
  function C4:SendUIRequest(_, command)
    calls[#calls + 1] = command
    if reply == false then
      error("private response detail")
    end
    return reply
  end
  print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  local valid = sceneXml(original .. sibling)
  for _, case in ipairs({
    { false, "scene request raised an error" },
    { "", "scene reply size invalid (0 bytes)" },
    { "<invalid/>", "missing AdvScene root" },
    { "<AdvScene><scene_id>0</scene_id></AdvScene>", "scene reply settings invalid" },
    { valid:gsub("<scene_id>0", "<scene_id>5"), "scene reply ID differs" },
    { valid:gsub("Outside", "Private renamed scene"), "scene name changed" },
    { sceneXml(sibling), "original: missing" },
    { sceneXml(original .. sceneMember(73, 810)), "changed: 1, unexpected: 0 (element.levelRate)" },
    {
      sceneXml(original:gsub("<level>", "<presetOrigin>private setting</presetOrigin><level>") .. sibling),
      "element.presetOrigin (readback only)",
    },
    { sceneXml(original .. sibling .. sceneMember(74, 810)), "unexpected: 1" },
  }) do
    reply, calls, lines = case[1], {}, {}
    T.falsy("the scene check rejects a mismatching read", migration.intactSceneStage(plans, 52))
    local output = table.concat(lines, "\n")
    T.contains("the trace identifies the gate", output, "Scene 1 saved-stage check rejected")
    T.contains("the trace identifies the specific failure", output, case[2])
    T.eq("preflight issues only its native read", calls, { "GET_SCENE" })
    T.falsy("private response data is excluded", output:lower():find("private", 1, true))
  end
  reply, calls, lines = valid, {}, {}
  T.truthy("matching original membership is accepted", migration.intactSceneStage(plans, 52))
  T.contains("preflight success is visible", table.concat(lines, "\n"), "original membership verified")
  log:setLogMode("Off")
  log:setLogLevel("3 - Info")
  C4.GetProjectItems, C4.SendUIRequest, print = originalItems, originalRequest, originalPrint
end

T.section("Scene add readback distinguishes delay from a different scene")
do
  local log = require("lib.logging")
  local originalItems, originalRequest, originalTimer, originalClock, originalPrint =
    C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer, C4.GetTickCount, print
  local source, sibling = sceneMember(51, 750), sceneMember(73, 820)
  local plans = migration.directScenePlan(migration.checkpoint(read(project(sceneAgent(source .. sibling)), 51)), 51)
  local lastRead, calls, delays, trace, settled, now
  print = function(line)
    trace[#trace + 1] = tostring(line)
  end
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  function C4:GetTickCount()
    return now
  end
  function C4:GetProjectItems()
    return project(sceneAgent(source .. sibling))
  end
  function C4:SendUIRequest(_, command)
    if command == "GET_SCENE" then
      now = now + 5
      return lastRead
    end
    calls[#calls + 1] = command
    if command == "DELETE_MEMBER" then
      lastRead = sceneXml(sceneMember(52, 750) .. sibling)
    end
    return ""
  end
  local function transfer(afterAdd, visibleAfter, unavailableTimer)
    calls, delays, trace, now = {}, {}, {}, 0
    lastRead = sceneXml(source .. sibling)
    local send = C4.SendUIRequest
    function C4:SendUIRequest(agent, command, args)
      local response = send(self, agent, command, args)
      if command == "ADD_MEMBERS" and not visibleAfter then
        lastRead = afterAdd
      end
      return response
    end
    function C4:SetTimer(delay, callback)
      if unavailableTimer then
        return nil
      end
      delays[#delays + 1] = delay
      now = now + delay
      if #delays == visibleAfter then
        lastRead = afterAdd
      end
      callback()
      return true
    end
    migration
      .moveDirectScenes(
        plans,
        51,
        52,
        function()
          return true
        end,
        true,
        function()
          calls[#calls + 1] = "checkpoint"
        end
      )
      :next(function(result)
        settled = result
      end)
    C4.SendUIRequest = send
    return table.concat(trace, "\n")
  end
  local added = sceneXml(source .. sibling .. sceneMember(52, 750))
  local delayed = transfer(added, 10)
  T.truthy("the fixture publishes after the previous nine-read limit", settled.moved)
  T.eq("a slow readback uses the existing request once", calls, { "ADD_MEMBERS", "checkpoint", "DELETE_MEMBER" })
  T.eq("only an unchanged snapshot gets extra spaced reads", { delays[8], delays[9], delays[10] }, { 125, 1000, 1000 })
  T.contains(
    "Trace distinguishes an unchanged scene with an unpublished add",
    delayed,
    "original: matches, replacement: missing, other members missing: 0, changed: 0, unexpected: 0"
  )
  T.contains("Trace records the final successful check", delayed, "ADD_MEMBERS readback: verified after 11 checks")
  T.contains("Trace measures the elapsed time and Director read", delayed, "check 11 (3055 ms elapsed, 5 ms read)")

  local drift = transfer(sceneXml(source .. sceneMember(73, 900) .. sceneMember(52, 750)))
  T.eq("a sibling fade mismatch never removes any members or extends the read window", {
    settled.reason,
    calls,
    #delays,
  }, { "scene_add_not_verified", { "ADD_MEMBERS" }, 8 })
  T.contains(
    "Trace identifies the sibling's changed field",
    drift,
    "original: matches, replacement: matches, other members missing: 0, changed: 1, unexpected: 0 (element.levelRate)"
  )
  T.falsy("Trace excludes scene names", drift:find("Outside", 1, true))

  local unavailable = transfer("<invalid/>")
  T.eq(
    "an unreadable agent reply cannot authorize removal",
    { settled.reason, calls, #delays },
    { "scene_add_not_verified", { "ADD_MEMBERS" }, 8 }
  )
  T.contains("Trace distinguishes unreadable XML", unavailable, "scene reply invalid")

  transfer(sceneXml(source .. sibling), 99, true)
  T.eq(
    "a refused retry timer settles without deleting the original",
    { settled.reason, calls },
    { "scene_readback_timer_unavailable", { "ADD_MEMBERS" } }
  )

  local removed = transfer(sceneXml(sibling .. sceneMember(52, 750)))
  T.eq("an original disappearing outside the operation cannot authorize a write", calls, { "ADD_MEMBERS" })
  T.contains("Trace reports a missing original separately", removed, "original: missing, replacement: matches")

  local missing = transfer(sceneXml(source .. sibling), 99)
  T.eq(
    "permanently missing additions are bounded",
    { settled.reason, calls, #delays },
    { "scene_add_not_verified", { "ADD_MEMBERS" }, 12 }
  )
  T.contains(
    "Trace records the pending result at the new limit",
    missing,
    "ADD_MEMBERS readback: original: matches, replacement: missing, other members missing: 0, changed: 0, unexpected: 0 after 13 checks"
  )
  log:setLogMode("Off")
  log:setLogLevel("3 - Info")
  C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer, C4.GetTickCount, print =
    originalItems, originalRequest, originalTimer, originalClock, originalPrint
end

T.section("Direct scene transfer verifies settings before removing the original member")
do
  local plans = migration.directScenePlan(checkpoint, 51)
  T.eq("the reviewed level and rate are retained", plans and plans[1].element, { level = 80, level_rate = 750 })
  local target, source, calls, changeRate, delayedTarget
  local timers = {}
  local originalItems, originalRequest, originalTimer = C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer
  function C4:SetTimer(_, callback)
    timers[#timers + 1] = callback
    return true
  end
  function C4:GetProjectItems()
    return project(sceneAgent((source or "") .. (target or "")))
  end
  function C4:SendUIRequest(agent, command, params)
    T.eq("the command targets the saved scene", { agent, params.SCENE_ID }, { 30, 0 })
    if command == "GET_SCENE" then
      return sceneXml((source or "") .. (target or ""))
    end
    calls[#calls + 1] = command
    if command == "ADD_MEMBERS" then
      delayedTarget = sceneMember(52, changeRate and 500 or 750):gsub("<level>80", "<level>100")
    elseif command == "EDIT_ELEMENT" then
      T.eq("only the replacement receives the reviewed level", { params.MEMBER_ID, params.level }, { 52, 80 })
      T.eq("the saved ramp rate is included in the edit", params.level_rate, 750)
      target = target:gsub("<level>100", "<level>80")
    elseif params.MEMBER_ID == 51 then
      source = nil
    else
      target = nil
    end
    return ""
  end
  local function transfer(adopt)
    local result
    migration
      .moveDirectScenes(
        plans,
        51,
        52,
        function()
          return true
        end,
        adopt,
        function()
          calls[#calls + 1] = "checkpoint"
        end
      )
      :next(function(value)
        result = value
      end)
    while #timers > 0 do
      if delayedTarget then
        T.truthy("before the scene commit the original remains", source)
        target, delayedTarget = delayedTarget, nil
      end
      table.remove(timers, 1)()
    end
    return result and result.moved
  end
  for _, drift in ipairs({ true, false }) do
    target, source, calls, changeRate = nil, sceneMember(51, 750), {}, drift
    T.eq("the transfer passes only with identical other settings", transfer(), not drift)
    T.eq("the original remains when settings differ", source ~= nil, drift)
    T.eq("an incomplete replacement is removed", target == nil, drift)
    T.eq(
      "the settings edit is verified before original removal",
      calls,
      drift and { "ADD_MEMBERS", "EDIT_ELEMENT", "DELETE_MEMBER" }
        or { "ADD_MEMBERS", "EDIT_ELEMENT", "checkpoint", "DELETE_MEMBER" }
    )
  end
  calls = {}
  T.truthy("a verified move is safe to resume", transfer())
  T.eq("the already moved scene receives no writes", calls, {})
  source, target, calls = sceneMember(51, 750), sceneMember(52, 750), {}
  local intact, hasAddition = migration.intactSceneStage(plans, 52)
  T.eq("the journal can identify and carry forward a staged addition", { intact, hasAddition }, { true, true })
  T.truthy("a prior matching addition can be reused", transfer(true))
  T.eq("a recovered addition is not added twice", calls, { "checkpoint", "DELETE_MEMBER" })
  C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer = originalItems, originalRequest, originalTimer
end

T.section("Editing an Off scene can change the representation of a disabled color fade")
do
  local log = require("lib.logging")
  local function binaryMember(id, level, brightness, color, tracked, enabled)
    return (
      "<AdvSceneMember><device_id>%d</device_id><track_color_tracking>%d</track_color_tracking>"
      .. "<track_color_x>0</track_color_x><track_color_y>0</track_color_y><all_elements><element>"
      .. "<level>%d</level><levelRate>%d</levelRate><levelPresetID>%d</levelPresetID>"
      .. "<colorEnabled>%s</colorEnabled><colorRate>%d</colorRate></element></all_elements></AdvSceneMember>"
    ):format(id, tracked or 0, level, brightness, level == 0 and 0 or 1, enabled and "True" or "False", color)
  end
  for _, case in ipairs({
    { "disabled color rate copied from brightness", 800, 0, false, true },
    { "disabled color rate represented as zero", 0, 0, false, true },
    { "an unrelated color rate change", 900, 0, false, false },
    { "zero cannot discard the color fade when tracking is enabled", 0, 1, false, false },
    { "zero cannot discard an active color fade", 0, 0, true, false },
    { "color tracking remains enabled", 800, 1, false, false },
    { "the color action remains enabled", 800, 0, true, false },
  }) do
    local description, rate, tracking, enabled, passes = unpack(case)
    local before = read(project(sceneAgent(binaryMember(51, 0, 800, 1200, tracking, enabled))), 51)
    local after = read(project(sceneAgent(binaryMember(52, 0, 800, rate, tracking, enabled))), 52)
    T.eq(description, migration.compare(before, after, 51, 52), passes)
  end
  local source, replacement, writes, brightness, replacementColor, retries
  local GetProjectItems, SendUIRequest, SetTimer = C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer
  function C4:GetProjectItems()
    return project(sceneAgent((source or "") .. (replacement or "")))
  end
  function C4:SetTimer(_, callback)
    retries = retries + 1
    callback()
    return true
  end
  function C4:SendUIRequest(_, command, params)
    if command == "GET_SCENE" then
      return sceneXml((source or "") .. (replacement or ""))
    end
    writes[#writes + 1] = command
    if command == "ADD_MEMBERS" then
      replacement = binaryMember(52, 100, 800, 1200)
    elseif command == "EDIT_ELEMENT" then
      T.eq("Off is explicitly written", params.level, 0)
      replacement = binaryMember(52, 0, brightness, replacementColor or brightness)
    elseif params.MEMBER_ID == 51 then
      source = nil
    else
      replacement = nil
    end
    return ""
  end
  local originalPrint, trace = print, {}
  print = function(line)
    trace[#trace + 1] = tostring(line)
  end
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  for _, case in ipairs({
    { observedRate = 800 },
    { observedRate = 810 },
    { observedRate = 800, stagedRate = 800 },
    { observedRate = 810, stagedRate = 800 },
    { observedRate = 800, stagedRate = 820 },
    { observedRate = 800, observedColor = 0 },
    { observedRate = 810, observedColor = 0 },
    { observedRate = 800, observedColor = 900 },
  }) do
    local observedRate, stagedRate = case.observedRate, case.stagedRate
    source, replacement, writes, brightness = binaryMember(51, 0, 800, 1200), nil, {}, observedRate
    replacementColor, retries = case.observedColor, 0
    local saved = migration.checkpoint(read(C4:GetProjectItems(), 51))
    local plans = migration.directScenePlan(saved, 51)
    if stagedRate then
      replacement = binaryMember(52, 100, stagedRate, 1200):gsub("<track_color_x>0", "<track_color_x>0.32")
      local intact, added, reusable = migration.intactSceneStage(plans, 52)
      T.eq("only a matching default On addition is eligible to finish", { intact, added, reusable }, {
        true,
        true,
        stagedRate == 800,
      })
    end
    local outcome
    migration
      .moveDirectScenes(
        plans,
        51,
        52,
        function()
          return true
        end,
        stagedRate ~= nil,
        function()
          writes[#writes + 1] = "checkpoint"
        end
      )
      :next(function(result)
        outcome = result
      end)
    if stagedRate == 820 then
      T.eq("an unrelated active setting change causes no scene writes", writes, {})
      T.truthy("the original and staged replacement remain available to inspect", source and replacement)
    elseif observedRate == 800 and (not replacementColor or replacementColor == 0) then
      T.truthy("a qualified Off edit completes automatically", outcome.moved)
      T.eq("the first read proves the disabled fade without retrying", retries, 0)
      T.truthy(
        "final scene verification accepts the same representation",
        migration.compare(saved, read(C4:GetProjectItems(), 52), 51, 52)
      )
      T.eq(
        "only a verified scene edit allows original removal",
        writes,
        stagedRate and { "EDIT_ELEMENT", "checkpoint", "DELETE_MEMBER" }
          or { "ADD_MEMBERS", "EDIT_ELEMENT", "checkpoint", "DELETE_MEMBER" }
      )
    else
      T.truthy("an unmatched fade leaves the original present", source)
      T.eq("readback reports the failed check and the active field", { outcome.reason, outcome.fields }, {
        "scene_edit_not_verified",
        observedRate == 800 and "element.colorRate" or "element.levelRate",
      })
      T.eq(
        "failed edits clean up only members added by this attempt",
        writes,
        stagedRate and { "EDIT_ELEMENT" } or { "ADD_MEMBERS", "EDIT_ELEMENT", "DELETE_MEMBER" }
      )
    end
  end
  log:setLogMode("Off")
  log:setLogLevel("3 - Info")
  print = originalPrint
  local output = table.concat(trace, "\n")
  T.contains("Trace records the request", output, "Scene 1 EDIT_ELEMENT request: dispatched")
  T.contains("Trace records an immediate confirmation", output, "EDIT_ELEMENT readback: verified after 1 checks")
  T.contains(
    "Trace records the failed edit's changed field",
    output,
    "EDIT_ELEMENT readback: original: matches, replacement: changed (element.levelRate)"
  )
  T.contains("Trace names removal of an original", output, "remove original member request")
  T.contains("Trace distinguishes failed-stage cleanup", output, "discard staged replacement request")
  T.contains("Trace identifies reuse of an earlier scene addition", output, "reusing the staged replacement")
  local fadeMismatch = "edit fade readback: saved [level 0, levelRate 800 ms, colorRate 1200 ms, colorEnabled false, "
    .. "tracking 0, tracking XY valid true, flash unknown], "
    .. "replacement [level 0, levelRate 800 ms, colorRate 900 ms, colorEnabled false, "
    .. "tracking 0, tracking XY valid true, flash unknown]"
  T.contains("Trace reports exact fade values when only the disabled color rate differs", output, fadeMismatch)
  local _, mismatches = output:gsub(fadeMismatch:gsub("(%W)", "%%%1"), "")
  T.eq("only the first and final failed reads print the fade values", mismatches, 2)
  C4.GetProjectItems, C4.SendUIRequest, C4.SetTimer = GetProjectItems, SendUIRequest, SetTimer
end

T.section("Affected scenes preserve all member settings")
do
  local function scene(id, siblings)
    return read(project(sceneAgent(sceneMember(id, 750) .. siblings)), id)
  end
  local before = scene(51, sceneMember(72, 500))
  local log, originalPrint, lines = require("lib.logging"), print, {}
  print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  log:setLogMode("Print")
  log:setLogLevel("5 - Trace")
  T.truthy("an unchanged sibling verifies", migration.compare(before, scene(52, sceneMember(72, 500)), 51, 52))
  T.falsy("a removed sibling fails verification", migration.compare(before, scene(52, ""), 51, 52))
  T.falsy(
    "a changed sibling ramp fails verification",
    migration.compare(before, scene(52, sceneMember(72, 750)), 51, 52)
  )
  T.falsy(
    "an unapproved sibling replacement fails verification",
    migration.compare(before, scene(52, sceneMember(73, 500)), 51, 52)
  )
  local approved = { [72] = 73 }
  T.truthy(
    "both approved members may move in one edit",
    migration.compare(before, scene(52, sceneMember(73, 500)), 51, 52, nil, nil, approved)
  )
  T.falsy(
    "an approved sibling move must preserve that member's settings",
    migration.compare(before, scene(52, sceneMember(73, 501)), 51, 52, nil, nil, approved)
  )
  T.falsy(
    "an approved sibling move must leave exactly one membership",
    migration.compare(before, scene(52, sceneMember(72, 500) .. sceneMember(73, 500)), 51, 52, nil, nil, approved)
  )
  log:setLogMode("Off")
  log:setLogLevel("3 - Info")
  print = originalPrint
  local trace = table.concat(lines, "\n")
  T.contains(
    "recovery trace distinguishes a missing member",
    trace,
    "complete membership differs: expected member missing"
  )
  T.contains("recovery trace names the changed field", trace, "member settings differ (element.levelRate)")
  T.contains(
    "recovery trace distinguishes an extra member",
    trace,
    "complete membership differs: unexpected current member"
  )
  T.falsy(
    "recovery trace excludes scene names and values",
    trace:find("Outside", 1, true) or trace:find("501", 1, true)
  )
end

T.section("An automatic move preserves a sibling migrated earlier from the same snapshot")
do
  local readScene, readProject = C4.SendUIRequest, C4.GetProjectItems
  local original, sibling = sceneMember(51, 750), sceneMember(72, 500)
  local replacement, movedSibling = sceneMember(52, 750), sceneMember(73, 500)
  local saved = migration.checkpoint(read(project(sceneAgent(original .. sibling)), 51))
  local current, writes, outcome = original .. movedSibling, {}
  function C4:GetProjectItems()
    return project(sceneAgent(current))
  end
  function C4:SendUIRequest(_, command, params)
    if command == "GET_SCENE" then
      return sceneXml(current)
    end
    writes[#writes + 1] = command
    if command == "ADD_MEMBERS" then
      current = current .. replacement
    elseif command == "DELETE_MEMBER" and params.MEMBER_ID == 51 then
      current = movedSibling .. replacement
    end
    return ""
  end
  local function run(approved)
    migration
      .moveDirectScenes(
        migration.directScenePlan(saved, 51, approved),
        51,
        52,
        function()
          return true
        end,
        false,
        function()
          writes[#writes + 1] = "checkpoint"
        end
      )
      :next(function(result)
        outcome = result
      end)
  end
  run()
  T.eq("a changed sibling with no approval blocks writes", { outcome.moved, #writes }, { false, 0 })
  run({ [72] = 73 })
  T.eq("native readback verifies both moves and preserves their distinct fades", {
    outcome.moved,
    current,
    writes,
  }, { true, movedSibling .. replacement, { "ADD_MEMBERS", "checkpoint", "DELETE_MEMBER" } })
  C4.SendUIRequest, C4.GetProjectItems = readScene, readProject
end

T.section("Load groups can be nested under rooms")
local group = item(
  60,
  "light_group.c4z",
  "Outside group",
  "<lua_gen_persisting><properties><property><name>Lights</name><value>51,52</value></property>"
    .. "<property><name>Tracked Light</name><value>51</value></property>"
    .. "</properties></lua_gen_persisting>"
)
local native =
  item(61, "group_dimmer.c4i", "Native group", "<State><SPECIFIC_LOAD>51</SPECIFIC_LOAD><ALL_MEMBERS /></State>")
local room = item(3, "roomdevice.c4i", "Room", "", "<subitems>" .. group .. native .. "</subitems>")
local groups = migration.groups(project(room), { [51] = true, [53] = true })
T.eq("known Light Group references are retained", groups[51][60].name, "Outside group")
T.truthy("the Light Group's selected tracking device is detected", groups[51][60].role.tracking)
T.eq("a native group tracking its specific load is detected", groups[51][61].name, "Native group")
T.eq("unrelated entries are omitted", groups[53], nil)
T.raises("a group with unreadable membership cannot be treated as empty", function()
  migration.groups(project(item(60, "light_group.c4z", "Outside group", "")), { [51] = true })
end)

T.section("Scenes attached to a group are checked after updating membership")
do
  local function groupProject(member, rate, sibling, tracked)
    local group = item(
      60,
      "light_group.c4z",
      "Outside group",
      "<lua_gen_persisting><properties><property><name>Lights</name><value>"
        .. member
        .. (sibling and ("," .. sibling) or "")
        .. "</value></property></properties></lua_gen_persisting>",
      "<subitems>" .. item(61, "light_v2.c4i", "Outside group", "") .. "</subitems>"
    )
    local native = item(
      63,
      "group_dimmer.c4i",
      "Native group",
      "<State><SPECIFIC_LOAD>"
        .. (tracked or 72)
        .. "</SPECIFIC_LOAD><ALL_MEMBERS>"
        .. "<MEMBER><DEVICE_ID>"
        .. member
        .. "</DEVICE_ID><SYNC>True</SYNC></MEMBER>"
        .. "<MEMBER><DEVICE_ID>72</DEVICE_ID><SYNC>False</SYNC></MEMBER></ALL_MEMBERS></State>"
    )
    return project(group, native, sceneAgent(sceneMember(61, rate)))
  end
  local before = read(groupProject(51, 750, 72), 51)
  local after = read(groupProject(52, 750, 72), 52)
  T.truthy("the group scene remains unchanged with its new load", migration.compare(before, after, 51, 52))
  T.falsy(
    "changing an indirect scene also prevents cutover",
    migration.compare(before, read(groupProject(52, 500, 72), 52), 51, 52)
  )
  T.falsy(
    "a removed group sibling prevents cutover",
    migration.compare(before, read(groupProject(52, 750), 52), 51, 52)
  )
  T.falsy(
    "changing a native group's tracked member to another sibling prevents cutover",
    migration.compare(before, read(groupProject(52, 750, 72, 73), 52), 51, 52)
  )
end

T.section("One verified Director snapshot serves multiple candidates")
do
  local reads = {}
  local previous = C4.GetProjectItems
  function C4:GetProjectItems(kind)
    reads[#reads + 1] = kind
    return kind == "AGENTS" and project(sceneAgent(sceneMember(51, 750) .. sceneMember(72, 500))) or project(group)
  end
  local snapshot = migration.snapshot()
  local one = migration.read({ [51] = true }, snapshot)
  local other = migration.read({ [72] = true }, snapshot)
  C4.GetProjectItems = previous
  T.eq("the shared snapshot reads each Director projection once", reads, { "DEVICES", "AGENTS" })
  T.truthy("each candidate has complete saved proofs", migration.complete(one) and migration.complete(other))
  T.truthy(
    "both candidates keep all settings in their shared scene",
    one.members.scenes["0"]["72"] and other.members.scenes["0"]["51"]
  )
  T.eq("an unrelated group is projected only for its member", { one.groups[51][60].id, other.groups[72] }, { 60 })
end

T.finish()

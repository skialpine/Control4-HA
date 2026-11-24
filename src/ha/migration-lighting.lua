-- Discover lighting references in project snapshots and verify scene changes with the agent.
local codec = require("ha.codec")
local deferred = require("deferred")
local log = require("lib.logging")
local metrics = require("ha.performance").shared
require("lib.utils")
local M = {}
local AGENT = "control4_agent_adv_lighting.c4i"
local NATIVE_GROUP = "group_dimmer.c4i"
local LIGHT_GROUP = "light_group.c4z"
local MAX_XML = 8 * 1024 * 1024
local READBACK_CHECKS = 9
local ADD_SETTLE_CHECKS = 4

local function traceEnabled()
  return log:isEnabled() and log:getLogLevel() >= log.LogLevel.TRACE
end

local function state(item, root)
  local raw = item.state
  if type(raw) == "string" then
    return ParseXml(raw)[root]
  end
  return type(raw) == "table" and raw[root] or nil
end

local function list(value, field)
  assert(type(value) == "table", "Unrecognized lighting membership")
  local rows = value[field]
  assert(rows or not next(value), "Unrecognized lighting membership rows")
  rows = rows or {}
  return IsList(rows) and rows or { rows }
end

local function items(xml)
  assert(type(xml) == "string" and #xml > 0 and #xml <= MAX_XML, "Unavailable project items")
  local parsed = ParseXml(xml)
  local container = parsed.systemitems or Select(parsed, "currentstate", "systemitems")
  assert(type(container) == "table", "Unrecognized project items")
  local rows, index = {}, 1
  local function append(entries)
    for _, item in ipairs(entries) do
      assert(type(item) == "table" and #rows < 15000, "Unrecognized project device")
      rows[#rows + 1] = item
    end
  end
  append(list(container, "item"))
  while rows[index] do
    local children = rows[index].subitems
    if children then
      append(list(children, "item"))
    end
    index = index + 1
  end
  return rows
end

local function numeric(value, minimum)
  local n = tonumber(value)
  assert(n and n >= (minimum or 1) and n <= 2147483647 and n == math.floor(n), "Invalid lighting ID")
  return n
end

local function settings(member)
  local copy = {}
  for field, value in pairs(member) do
    if field ~= "device_id" then
      copy[field] = value
    end
  end
  return codec.encode(codec.object(copy))
end

local function sceneDefinition(scene)
  local id = numeric(scene.scene_id, 0)
  assert(type(scene.name) == "string" and #scene.name > 0, "Missing Advanced Lighting scene name")
  local saved = {}
  for _, member in ipairs(list(scene.all_members, "AdvSceneMember")) do
    local device = numeric(member.device_id)
    assert(not saved[device], "Duplicate scene member")
    saved[device] = settings(member)
  end
  return id, { name = scene.name, members = saved }
end

local function sceneDefinitions(xml)
  local definitions = {}
  local found
  for _, item in ipairs(items(xml)) do
    if item.c4i == AGENT then
      assert(not found, "Ambiguous Advanced Lighting agent")
      found = true
      local lighting = state(item, "State")
      assert(type(lighting) == "table" and type(lighting.all_scenes) == "table", "Unreadable Advanced Lighting state")
      for _, collection in ipairs({ lighting.all_scenes, lighting.all_off_toggle_scenes or {} }) do
        for _, scene in ipairs(list(collection, "AdvScene")) do
          local id, definition = sceneDefinition(scene)
          assert(not definitions[id], "Duplicate Advanced Lighting scene ID")
          definitions[id] = definition
        end
      end
    end
  end
  return definitions
end

local function readScene(agent, id)
  local sent, reply = pcall(SendUIRequest, agent, "GET_SCENE", { SCENE_ID = id })
  if not sent then
    return nil, "scene request raised an error"
  end
  if type(reply) ~= "string" then
    return nil, "scene reply type: " .. type(reply)
  end
  if #reply == 0 or #reply > MAX_XML then
    return nil, ("scene reply size invalid (%d bytes)"):format(#reply)
  end
  -- The project XML can lag the edits accepted by the agent.
  local parsed, document = pcall(ParseXml, reply)
  if not parsed then
    return nil, ("scene reply XML invalid (%d bytes)"):format(#reply)
  end
  if type(document.AdvScene) ~= "table" then
    return nil, ("scene reply invalid: missing AdvScene root (%d bytes)"):format(#reply)
  end
  local ok, sceneId, definition = pcall(sceneDefinition, document.AdvScene)
  if not ok then
    return nil, ("scene reply settings invalid (%d bytes)"):format(#reply)
  end
  if sceneId ~= id then
    return nil, "scene reply ID differs"
  end
  return definition
end

local function liveScene(agent, id)
  if not agent then
    return nil, "scene agent unavailable"
  end
  local span = metrics:start("migration.scene_read")
  local definition, reason = readScene(agent, id)
  metrics:finish(span, definition and "ok" or "rejected")
  return definition, reason
end

local function storedMembers(members, encode)
  local saved = codec.object({})
  for id, member in pairs(members) do
    saved[tostring(id)] = encode and codec.encode(codec.object(member)) or member
  end
  return saved
end

local function projectScenes(definitions, members)
  local byMember, complete = {}, codec.object({})
  for id, scene in pairs(definitions) do
    for member in pairs(members) do
      local saved = scene.members[member]
      if saved then
        byMember[member] = byMember[member] or {}
        byMember[member][id] = { id = id, name = scene.name, saved = saved }
        complete[tostring(id)] = complete[tostring(id)] or storedMembers(scene.members)
      end
    end
  end
  return byMember, complete
end

function M.scenes(xml, members)
  return projectScenes(sceneDefinitions(xml), members)
end

local function configuredLights(item)
  local configuration = state(item, "lua_gen_persisting")
  assert(type(configuration) == "table", "Unreadable Light Group state")
  local lights, tracked
  for _, property in ipairs(list(configuration.properties, "property")) do
    if property.name == "Lights" then
      lights = property.value
    elseif property.name == "Tracked Light" then
      tracked = property.value
    end
  end
  assert(type(lights) == "string" or type(lights) == "table" and not next(lights), "Unreadable Light Group targets")
  local members = {}
  for id in (type(lights) == "string" and lights or ""):gmatch("[^,]+") do
    local member = numeric(id)
    assert(not members[member], "Duplicate Light Group member")
    members[member] = { member = true, tracking = false }
  end
  if type(tracked) == "string" and tracked:match("%S") then
    local id = numeric(tracked)
    members[id] = members[id] or { member = false }
    members[id].tracking = true
  else
    assert(
      tracked == nil or tracked == "" or type(tracked) == "table" and not next(tracked),
      "Unreadable tracked light"
    )
  end
  return members
end

local function groupDefinitions(xml)
  local definitions, seen = {}, {}
  for _, item in ipairs(items(xml)) do
    if item.c4i == NATIVE_GROUP or item.c4i == LIGHT_GROUP then
      local id, groupMembers = numeric(item.id), {}
      assert(not seen[id], "Duplicate load group ID")
      seen[id] = true
      assert(type(item.name) == "string" and #item.name > 0, "Missing load group name")
      if item.c4i == LIGHT_GROUP then
        groupMembers = configuredLights(item)
      else
        local configuration = state(item, "State")
        assert(type(configuration) == "table", "Unreadable Control4 load group state")
        for _, entry in ipairs(list(configuration.ALL_MEMBERS, "MEMBER")) do
          assert(type(entry) == "table", "Unrecognized native load group member")
          local member = numeric(entry.DEVICE_ID)
          assert(not groupMembers[member], "Duplicate native load group member")
          local saved = codec.object({})
          for field, value in pairs(entry) do
            if field ~= "DEVICE_ID" then
              saved[field] = value
            end
          end
          groupMembers[member] = { member = true, tracking = false, saved = saved }
        end
        if tonumber(configuration.SPECIFIC_LOAD) and tonumber(configuration.SPECIFIC_LOAD) > 0 then
          local member = numeric(configuration.SPECIFIC_LOAD)
          groupMembers[member] = groupMembers[member] or { member = false }
          groupMembers[member].tracking = true
        end
      end
      local proxies = {}
      if item.subitems then
        for _, child in ipairs(list(item.subitems, "item")) do
          if child.c4i == "light_v2.c4i" then
            proxies[#proxies + 1] = numeric(child.id)
          end
        end
      end
      definitions[#definitions + 1] = {
        id = id,
        name = item.name,
        kind = item.c4i,
        members = groupMembers,
        proxies = proxies,
        saved = storedMembers(groupMembers, true),
      }
    end
  end
  return definitions
end

local function projectGroups(definitions, members)
  local result, scope, complete = {}, {}, codec.object({})
  for member in pairs(members) do
    scope[member] = true
  end
  local changed = true
  while changed do
    changed = false
    for _, group in ipairs(definitions) do
      for member, role in pairs(group.members) do
        if scope[member] then
          result[member] = result[member] or {}
          result[member][group.id] = { id = group.id, name = group.name, kind = group.kind, role = role }
          complete[tostring(group.id)] = group.saved
          if not scope[group.id] then
            scope[group.id], changed = true, true
            for _, proxy in ipairs(group.proxies) do
              scope[proxy] = true
            end
          end
        end
      end
    end
  end
  return result, scope, complete
end

function M.groups(xml, members)
  return projectGroups(groupDefinitions(xml), members)
end

function M.snapshot()
  local okGroups, groups = pcall(function()
    return groupDefinitions(C4:GetProjectItems("DEVICES"))
  end)
  local okScenes, scenes = pcall(function()
    return sceneDefinitions(C4:GetProjectItems("AGENTS"))
  end)
  return { scenes = okScenes and scenes or nil, groups = okGroups and groups or nil }
end

function M.read(members, snapshot, savedScenes, verifyAllScenes)
  snapshot = snapshot or M.snapshot()
  local groups, scope, groupMembers
  local scenes, sceneMembers, nativeScenes
  if snapshot.groups then
    groups, scope, groupMembers = projectGroups(snapshot.groups, members)
  end
  if snapshot.scenes then
    local definitions = snapshot.scenes
    if savedScenes then
      local ids = {}
      nativeScenes = {}
      for id in pairs(savedScenes) do
        local sceneId = tonumber(id)
        if not sceneId or sceneId < 0 or sceneId > 2147483647 or sceneId ~= math.floor(sceneId) then
          return { version = 2, groups = groups, members = { groups = groupMembers } }
        end
        ids[sceneId] = true
      end
      for id, definition in pairs(definitions) do
        if verifyAllScenes then
          ids[id] = true
        elseif not ids[id] then
          for member in pairs(scope or members) do
            if definition.members[member] then
              ids[id] = true
              break
            end
          end
        end
      end
      if next(ids) then
        local projected = {}
        for id, definition in pairs(definitions) do
          projected[id] = definition
        end
        local agent = GetAgentId(AGENT)
        -- A single native read per scene in this verification boundary.
        for id in pairs(ids) do
          local scene, reason = liveScene(agent, id)
          if not scene then
            pcall(log.trace, log, "Lighting verification failed reading current scene: %s", reason)
            projected = nil
            break
          end
          projected[id], nativeScenes[id] = scene, scene
        end
        definitions = projected
      end
    end
    if definitions then
      scenes, sceneMembers = projectScenes(definitions, scope or members)
    end
  end
  return {
    version = 2,
    scenes = scenes,
    groups = groups,
    members = { scenes = sceneMembers, groups = groupMembers },
    nativeScenes = nativeScenes,
  }
end

-- Persist stable object keys even when IDs happen to form a Lua array.
function M.checkpoint(snapshot)
  local result = { version = snapshot.version, members = snapshot.members }
  for _, kind in ipairs({ "scenes", "groups" }) do
    if snapshot[kind] then
      result[kind] = codec.object({})
      for member, references in pairs(snapshot[kind]) do
        local rows = codec.object({})
        for id, reference in pairs(references) do
          rows[tostring(id)] = reference
        end
        result[kind][tostring(member)] = rows
      end
    end
  end
  return result
end

function M.complete(snapshot)
  return type(snapshot) == "table"
    and snapshot.version == 2
    and type(snapshot.scenes) == "table"
    and type(snapshot.groups) == "table"
    and type(snapshot.members) == "table"
    and type(snapshot.members.scenes) == "table"
    and type(snapshot.members.groups) == "table"
end

function M.checkpointProof(snapshot)
  if not M.complete(snapshot) then
    return nil
  end
  -- Director can return decoded Lua tables without JSON object markers. These
  -- four fields are maps, so {} and [] represent the same empty inventory.
  local function copyMaps(root)
    local copy = {}
    for key, value in pairs(root) do
      copy[key] = value
    end
    for _, kind in ipairs({ "scenes", "groups" }) do
      if root[kind] ~= codec.null and not next(root[kind]) then
        copy[kind] = codec.object({})
      end
    end
    return copy
  end
  local proof = copyMaps(snapshot)
  proof.members = copyMaps(snapshot.members)
  return codec.encode(proof)
end

local function sceneSteps(member)
  local elements = Select(member, "all_elements", "element")
  if codec.isObject(elements) and next(elements) then
    return { elements }
  elseif codec.isArray(elements) and #elements > 0 then
    return elements
  end
end

local function colorDisabled(step)
  if codec.isObject(step) then
    local enabled = step.colorEnabled
    return enabled == false or type(enabled) == "string" and enabled:lower() == "false"
  end
end

local function inactiveColorStep(member)
  local steps = sceneSteps(member)
  if steps and #steps == 1 and tonumber(member.track_color_tracking) == 0 and colorDisabled(steps[1]) then
    return steps[1]
  end
end

local function validTrackingCoordinates(member)
  local x, y = tonumber(member.track_color_x), tonumber(member.track_color_y)
  return x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1
end

local function normalizeSteps(member, steps)
  if validTrackingCoordinates(member) then
    member.track_color_x, member.track_color_y = tonumber(member.track_color_x), tonumber(member.track_color_y)
  end
  for _, step in ipairs(steps) do
    if codec.isObject(step) then
      for _, field in ipairs({ "levelEnabled", "colorEnabled" }) do
        local value = step[field]
        if type(value) == "string" then
          value = value:lower()
          if value == "true" or value == "false" then
            step[field] = value == "true"
          end
        end
      end
      for field, limit in pairs({ level = 100, delay = 2147483647, levelRate = 2147483647, colorRate = 2147483647 }) do
        local value = tonumber(step[field])
        if value and value >= 0 and value <= limit and value == math.floor(value) then
          step[field] = value
        end
      end
    end
  end
end

local function sceneSettingsForComparison(expected, observed, exact)
  local saved, actual = codec.storedObject(expected), codec.storedObject(observed)
  local savedSteps, actualSteps = sceneSteps(saved), sceneSteps(actual)
  if not savedSteps or not actualSteps or #savedSteps ~= #actualSteps then
    return saved, actual
  end
  normalizeSteps(saved, savedSteps)
  normalizeSteps(actual, actualSteps)
  if tonumber(saved.track_color_tracking) ~= 0 or tonumber(actual.track_color_tracking) ~= 0 then
    return saved, actual
  end

  local allColorDisabled = true
  for index, sourceStep in ipairs(savedSteps) do
    local currentStep = actualSteps[index]
    if colorDisabled(sourceStep) and colorDisabled(currentStep) then
      -- Native readback can supply color values the project projection omitted.
      -- Retain any value explicitly saved, even for a disabled action.
      for _, field in ipairs({ "colorHue", "colorSaturation", "colorTemperature" }) do
        local value = tonumber(currentStep[field])
        if sourceStep[field] == nil and value and value >= 0 and value < math.huge then
          currentStep[field] = nil
        end
      end
    else
      allColorDisabled = false
    end
  end
  if allColorDisabled and validTrackingCoordinates(saved) and validTrackingCoordinates(actual) then
    -- These are cached tracking coordinates, shared across actions on this member.
    saved.track_color_x, saved.track_color_y = nil, nil
    actual.track_color_x, actual.track_color_y = nil, nil
    -- Keep the existing native Off edit rule specific to a single replacement action.
    local sourceStep, replacementStep = savedSteps[1], actualSteps[1]
    local colorRate, levelRate = tonumber(replacementStep.colorRate), tonumber(replacementStep.levelRate)
    local flash = saved.flash
    if
      not exact
      and #savedSteps == 1
      and (flash == nil or flash == false or type(flash) == "string" and flash:lower() == "false")
      and tonumber(sourceStep.level) == 0
      and tonumber(replacementStep.level) == 0
      -- Director emits either 0 or the level fade for this disabled action.
      -- The template's scene reader resolves a zero color fade to the level fade.
      and (colorRate ~= nil and (colorRate == levelRate or (colorRate == 0 and levelRate and levelRate > 0)))
      and tonumber(sourceStep.colorRate)
    then
      replacementStep.colorRate = sourceStep.colorRate
    end
  end
  return saved, actual
end

local function sameSceneSettings(expected, observed, exact)
  if expected == observed then
    return true
  end
  local saved, actual = sceneSettingsForComparison(expected, observed, exact)
  return saved ~= nil and actual ~= nil and codec.encode(saved) == codec.encode(actual)
end

local function sameReference(kind, saved, current, exact)
  if not current then
    return false
  end
  if kind == "scenes" then
    return current.id == saved.id
      and current.name == saved.name
      and sameSceneSettings(saved.saved, current.saved, exact)
  end
  return codec.encode(current) == codec.encode(saved)
end

local function canReuseStagedSettings(expected, observed)
  if sameSceneSettings(expected, observed) then
    return true
  end
  local saved, actual = sceneSettingsForComparison(expected, observed)
  local off, staged = inactiveColorStep(saved), inactiveColorStep(actual)
  if
    not off
    or not staged
    or tonumber(off.level) ~= 0
    or tonumber(off.levelPresetID) ~= 0
    or tonumber(staged.level) ~= 100
    or tonumber(staged.levelPresetID) ~= 1
  then
    return false
  end
  -- Resume an unfinished ADD_MEMBERS that left Director's default On step.
  -- Match every other field before editing, then verify the actual Off readback.
  staged.level, staged.levelPresetID = off.level, off.levelPresetID
  return codec.encode(saved) == codec.encode(actual)
end

local function differingFields(expected, observed, exact)
  local saved, actual = sceneSettingsForComparison(expected, observed, exact)
  if not saved or not actual then
    return nil
  end
  local changes = {}
  local function compare(before, after, path, remainingDepth)
    if before == after or #changes >= 12 then
      return
    end
    if remainingDepth == 0 or type(before) ~= "table" or type(after) ~= "table" then
      local field = path:gsub("^all_elements%.", "")
      if before == nil then
        field = field .. " (readback only)"
      elseif after == nil then
        field = field .. " (saved only)"
      elseif type(before) ~= type(after) then
        field = field .. (" (%s to %s)"):format(type(before), type(after))
      end
      changes[#changes + 1] = field
      return
    end
    local keys = {}
    for key in pairs(before) do
      keys[key] = true
    end
    for key in pairs(after) do
      keys[key] = true
    end
    for key in pairs(keys) do
      local name = tostring(key)
      if #name > 32 or not name:match("^[%w_]+$") then
        name = "[field]"
      end
      compare(before[key], after[key], (path == "" and "" or path .. ".") .. name, remainingDepth - 1)
    end
  end
  compare(saved, actual, "", 6)
  table.sort(changes)
  return #changes > 0 and table.concat(changes, ", "):sub(1, 384) or nil
end

local function resolvedMember(member, after, approved)
  local replacement = not after[member] and approved and approved[tonumber(member)]
  return replacement and tostring(replacement) or member
end

local function sameMembers(before, after, moves, approved, scenes, describe)
  if type(before) ~= "table" or type(after) ~= "table" or not next(before) then
    return false, "missing complete membership data"
  end
  local used = {}
  for member, saved in pairs(before) do
    local target = moves[member] or resolvedMember(member, after, approved)
    local matches = saved == after[target] or (scenes and sameSceneSettings(saved, after[target], target == member))
    if used[target] then
      return false, "two saved members resolve to the same current member"
    end
    if not matches then
      if not after[target] then
        return false, "expected member missing"
      end
      local fields = describe and scenes and differingFields(saved, after[target], target == member)
      return false, fields and ("member settings differ (%s)"):format(fields) or "member settings differ"
    end
    used[target] = true
  end
  for member in pairs(after) do
    if not used[member] then
      return false, "unexpected current member"
    end
  end
  return true
end

local function singleElement(saved)
  local member = type(saved) == "string" and codec.storedObject(saved)
  local element = Select(member, "all_elements", "element")
  local level = type(element) == "table" and tonumber(element.level)
  if level and level >= 0 and level <= 100 and level == math.floor(level) then
    local args = { level = level }
    for field, argument in pairs({ levelRate = "level_rate", colorRate = "color_rate" }) do
      if element[field] ~= nil then
        local rate = tonumber(element[field])
        if not rate or rate < 0 or rate > 2147483647 or rate ~= math.floor(rate) then
          return
        end
        args[argument] = rate
      end
    end
    return args
  end
end

function M.directScenePlan(snapshot, proxy, approvedMoves)
  if not M.complete(snapshot) or next(snapshot.groups) then
    return
  end
  local old = tostring(proxy)
  local references = snapshot.scenes[old]
  if not references or not next(references) then
    return
  end
  local plans = {}
  for member in pairs(snapshot.scenes) do
    if member ~= old then
      return
    end
  end
  for id, reference in pairs(references) do
    local members = snapshot.members.scenes[id]
    local element = singleElement(reference.saved)
    if not members or members[old] ~= reference.saved or not element then
      return
    end
    plans[#plans + 1] = {
      id = reference.id,
      name = reference.name,
      original = old,
      saved = reference.saved,
      element = element,
      members = members,
      approvedMoves = approvedMoves,
    }
  end
  table.sort(plans, function(a, b)
    return a.id < b.id
  end)
  return plans
end

local function currentScene(agent, plan, nativeScenes)
  local scene, status
  if nativeScenes then
    scene, status = nativeScenes[plan.id], "scene readback unavailable"
  else
    scene, status = liveScene(agent, plan.id)
  end
  if not scene then
    return nil, status
  end
  if scene.name ~= plan.name then
    return nil, "scene name changed"
  end
  return storedMembers(scene.members)
end

local function addedOnly(plan, current, replacement)
  if not current or not current[replacement] then
    return false
  end
  local source = CopyTable(current, true)
  source[replacement] = nil
  return sameMembers(plan.members, source, {}, plan.approvedMoves, true)
end

local function memberReadback(expected, observed, exact)
  if not observed then
    return "missing"
  end
  if sameSceneSettings(expected, observed, exact) then
    return "matches"
  end
  return "changed (" .. (differingFields(expected, observed, exact) or "other fields") .. ")"
end

local function readbackSummary(plan, current, old, new)
  local missing, changed, extra, fields, accounted = 0, 0, 0, {}, { [old] = true, [new] = true }
  for id, saved in pairs(plan.members) do
    if id ~= old then
      local target = resolvedMember(id, current, plan.approvedMoves)
      accounted[target] = true
      if not current[target] then
        missing = missing + 1
      elseif not sameSceneSettings(saved, current[target], target == id) then
        changed = changed + 1
        local diff = differingFields(saved, current[target], target == id) or "other fields"
        fields[diff] = true
      end
    end
  end
  for id in pairs(current) do
    if not accounted[id] then
      extra = extra + 1
    end
  end
  local changedFields = {}
  for field in pairs(fields) do
    changedFields[#changedFields + 1] = field
  end
  table.sort(changedFields)
  return ("original: %s, replacement: %s, other members missing: %d, changed: %d, unexpected: %d%s"):format(
    memberReadback(plan.saved, current[old], true),
    memberReadback(plan.saved, current[new], false),
    missing,
    changed,
    extra,
    #changedFields > 0 and " (" .. table.concat(changedFields, " / "):sub(1, 384) .. ")" or ""
  )
end

local function fadeReadback(saved)
  local member = saved and codec.storedObject(saved)
  local steps = member and sceneSteps(member)
  local step = steps and #steps == 1 and steps[1]
  if not codec.isObject(step) then
    return "single action unavailable"
  end
  local function integer(value, maximum)
    value = tonumber(value)
    return value and value >= 0 and value <= maximum and value == math.floor(value) and tostring(value) or "unknown"
  end
  local function flag(value)
    local representation = type(value) == "string" and value:lower() or tostring(value)
    return (representation == "true" or representation == "false") and representation or "unknown"
  end
  return ("level %s, levelRate %s ms, colorRate %s ms, colorEnabled %s, tracking %s, tracking XY valid %s, flash %s"):format(
    integer(step.level, 100),
    integer(step.levelRate, 2147483647),
    integer(step.colorRate, 2147483647),
    flag(step.colorEnabled),
    integer(member.track_color_tracking, 2147483647),
    tostring(not not validTrackingCoordinates(member)),
    flag(member.flash)
  )
end

local function traceScene(action, index, plan, current, replacement, detail)
  if traceEnabled() then
    pcall(function()
      log:trace(
        "Scene %d %s: %s%s",
        index,
        action,
        detail,
        current and ". " .. readbackSummary(plan, current, plan.original, replacement) or ""
      )
    end)
  end
end

function M.intactSceneStage(plans, destination, evidence)
  if evidence then
    if not M.complete(evidence) or next(evidence.groups) then
      return false
    end
    local planned = {}
    for _, plan in ipairs(plans) do
      planned[plan.id] = true
    end
    for _, references in pairs(evidence.scenes) do
      for id in pairs(references) do
        if not planned[tonumber(id)] then
          return false
        end
      end
    end
  end
  local replacement = tostring(destination)
  local nativeScenes = evidence and evidence.nativeScenes
  local agent = not nativeScenes and GetAgentId(AGENT)
  local hasAddition, compatible = false, true
  for index, plan in ipairs(plans) do
    local current, reason = currentScene(agent, plan, nativeScenes)
    if sameMembers(plan.members, current, {}, plan.approvedMoves, true) then
      traceScene("saved-stage check", index, plan, current, replacement, "original membership verified")
    elseif addedOnly(plan, current, replacement) then
      hasAddition = true
      local reusable = canReuseStagedSettings(plan.saved, current[replacement])
      compatible = compatible and reusable
      traceScene(
        "saved-stage check",
        index,
        plan,
        current,
        replacement,
        reusable and "staged member reusable" or "staged settings differ"
      )
    else
      traceScene("saved-stage check rejected", index, plan, current, replacement, reason or "saved membership differs")
      return false
    end
  end
  return true, hasAddition, compatible
end

local function readbackTime()
  local ok, now = pcall(C4.GetTickCount or C4.GetTime, C4)
  return ok and type(now) == "number" and now or nil
end

function M.moveDirectScenes(plans, source, destination, active, adopt, beforeRemoval, mayRemove)
  local agent = GetAgentId(AGENT)
  local chain = deferred.new()
  chain:resolve()
  if not agent or source == destination then
    return chain:next(function()
      return { moved = false, reason = "scene_agent_or_replacement_unavailable" }
    end)
  end
  local tracing = traceEnabled()
  local sceneOrder = {}
  if tracing then
    for index, plan in ipairs(plans) do
      sceneOrder[plan] = index
    end
    pcall(log.trace, log, "Scene migration started: %d scenes", #plans)
  end
  local old, new = tostring(source), tostring(destination)
  local function stop(plan, reason, settings)
    error({ scene = plan.name, reason = reason, fields = settings and differingFields(plan.saved, settings) }, 0)
  end
  local function send(plan, command, args, expected)
    local receipt = deferred.new()
    local started = tracing and readbackTime()
    local action = command
    if tracing and command == "DELETE_MEMBER" then
      action = args.MEMBER_ID == source and "remove original member" or "discard staged replacement"
    end
    local function check(count)
      local running = active()
      local current, sceneStatus
      local readAt = tracing and readbackTime()
      if running then
        current, sceneStatus = currentScene(agent, plan)
      end
      local now = tracing and readbackTime()
      local verified = running and expected(current)
      local delay
      if running and not verified then
        if count < READBACK_CHECKS then
          delay = 125
        elseif
          command == "ADD_MEMBERS"
          and count < READBACK_CHECKS + ADD_SETTLE_CHECKS
          and sameMembers(plan.members, current, {}, plan.approvedMoves, true)
        then
          -- Director can accept an add before publishing the updated scene.
          -- Re-read only while the original and all siblings still match.
          delay = 1000
        end
      end
      if tracing then
        local elapsed = now and started and math.max(now - started, 0)
        local duration = now and readAt and math.max(now - readAt, 0)
        pcall(function()
          local detail = current and readbackSummary(plan, current, old, new) or sceneStatus or "retired"
          log:trace(
            "Scene %d %s check %d (%s ms elapsed, %s ms read): %s%s",
            sceneOrder[plan],
            action,
            count,
            elapsed and tostring(elapsed) or "unknown",
            duration and tostring(duration) or "unknown",
            detail,
            delay and (", next read in " .. delay .. " ms") or ""
          )
          if not delay then
            local status = verified and "verified" or detail
            log:trace("Scene %d %s readback: %s after %d checks", sceneOrder[plan], action, status, count)
          end
          if command == "EDIT_ELEMENT" and not verified and current and current[new] and (count == 1 or not delay) then
            log:trace(
              "Scene %d edit fade readback: saved [%s], replacement [%s]",
              sceneOrder[plan],
              fadeReadback(plan.saved),
              fadeReadback(current[new])
            )
          end
        end)
      end
      if delay then
        local scheduled, timer = pcall(C4.SetTimer, C4, delay, function()
          check(count + 1)
        end)
        if not scheduled or not timer then
          receipt:reject({ scene = plan.name, reason = "scene_readback_timer_unavailable" })
        end
      else
        receipt:resolve(current or nil)
      end
    end
    if active() then
      args.SCENE_ID = plan.id
      local sent, response = pcall(SendUIRequest, agent, command, args)
      if tracing then
        local reply = not sent and "error" or type(response) == "string" and (#response .. " bytes") or type(response)
        pcall(
          log.trace,
          log,
          "Scene %d %s request: %s (reply: %s)",
          sceneOrder[plan],
          action,
          sent and "dispatched" or "failed",
          reply
        )
      end
    end
    check(1)
    return receipt
  end
  -- Keep every original member until all additions have been verified.
  local staged = {}
  local addedThisRun = {}
  local removalStarted = false
  local function stage(plan, current)
    if not addedOnly(plan, current, new) then
      stop(plan, "scene_add_not_verified")
    end
    staged[#staged + 1] = plan
    if sameSceneSettings(plan.saved, current[new]) then
      if tracing then
        pcall(log.trace, log, "Scene %d staged settings verified", sceneOrder[plan])
      end
      return
    end
    local actual, expected = singleElement(current[new]), plan.element
    if
      not actual
      or actual.level == expected.level
        and actual.level_rate == expected.level_rate
        and actual.color_rate == expected.color_rate
    then
      traceScene(
        "staged settings rejected",
        sceneOrder[plan],
        plan,
        current,
        new,
        actual and "non-editable settings differ" or "replacement action unreadable"
      )
      stop(plan, "scene_settings_differ", current[new])
    end
    local args = CopyTable(expected, true)
    args.MEMBER_ID, args.ELEMENT_ID = destination, 0
    local function matches(snapshot)
      return addedOnly(plan, snapshot, new) and sameSceneSettings(plan.saved, snapshot[new])
    end
    return send(plan, "EDIT_ELEMENT", args, matches):next(function(snapshot)
      if not matches(snapshot) then
        stop(plan, "scene_edit_not_verified", snapshot and snapshot[new])
      end
    end)
  end
  for index, plan in ipairs(plans) do
    chain = chain:next(function()
      local current, reason
      if active() then
        current, reason = currentScene(agent, plan)
      end
      if sameMembers(plan.members, current, { [old] = new }, plan.approvedMoves, true) then
        traceScene("transfer preflight", index, plan, current, new, "replacement already verified")
        return
      end
      if adopt and addedOnly(plan, current, new) and canReuseStagedSettings(plan.saved, current[new]) then
        if tracing then
          pcall(log.trace, log, "Scene %d reusing the staged replacement", sceneOrder[plan])
        end
        return stage(plan, current)
      end
      if not sameMembers(plan.members, current, {}, plan.approvedMoves, true) then
        traceScene(
          "transfer preflight rejected",
          index,
          plan,
          current,
          new,
          reason or (current and "original membership differs" or "operation retired")
        )
        stop(plan, "scene_members_changed")
      end
      return send(
        plan,
        "ADD_MEMBERS",
        { members = ("<MEMBER_ID>%d</MEMBER_ID>"):format(destination) },
        function(snapshot)
          return addedOnly(plan, snapshot, new)
        end
      ):next(function(snapshot)
        if addedOnly(plan, snapshot, new) then
          addedThisRun[#addedThisRun + 1] = plan
        end
        return stage(plan, snapshot)
      end)
    end)
  end
  return chain
    :next(function()
      local removal = deferred.new()
      removal:resolve()
      if #staged > 0 then
        removal = removal:next(beforeRemoval)
      end
      for _, plan in ipairs(staged) do
        removal = removal:next(function()
          local current, reason
          if active() then
            current, reason = currentScene(agent, plan)
          end
          if not addedOnly(plan, current, new) or not sameSceneSettings(plan.saved, current[new]) then
            traceScene(
              "pre-removal check rejected",
              sceneOrder[plan],
              plan,
              current,
              new,
              reason or (current and "staged membership or settings differ" or "operation retired")
            )
            stop(plan, "scene_stage_changed", current and current[new])
          end
          local function matches(snapshot)
            return sameMembers(plan.members, snapshot, { [old] = new }, plan.approvedMoves, true)
          end
          if mayRemove and not mayRemove() then
            stop(plan, "replacement_feedback_lost")
          end
          removalStarted = true
          return send(plan, "DELETE_MEMBER", { MEMBER_ID = source }, matches):next(function(snapshot)
            if not matches(snapshot) then
              stop(plan, "scene_removal_not_verified", snapshot and snapshot[new])
            end
          end)
        end)
      end
      return removal
    end)
    :next(function()
      if tracing then
        pcall(log.trace, log, "Scene migration verified")
      end
      return { moved = true }
    end, function(problem)
      local failure = { moved = false, reason = "scene_operation_failed" }
      if type(problem) == "table" and problem.reason then
        failure.scene, failure.reason, failure.fields = problem.scene, problem.reason, problem.fields
      end
      -- A delayed original removal could still land, so leave its replacement in the scene.
      if removalStarted then
        pcall(log.trace, log, "Scene migration stopped during original removal. Staged members retained.")
        return failure
      end
      local cleanup = deferred.new()
      cleanup:resolve()
      for _, plan in ipairs(addedThisRun) do
        cleanup = cleanup:next(function()
          if active() then
            local current, reason = currentScene(agent, plan)
            if addedOnly(plan, current, new) then
              return send(plan, "DELETE_MEMBER", { MEMBER_ID = destination }, function(snapshot)
                return sameMembers(plan.members, snapshot, {}, plan.approvedMoves, true)
              end)
            end
            traceScene(
              "cleanup skipped",
              sceneOrder[plan],
              plan,
              current,
              new,
              reason or "staged addition no longer matches"
            )
          end
        end)
      end
      return cleanup:next(function()
        if active() then
          local intact, added, compatible = M.intactSceneStage(plans, destination)
          failure.originalScenesVerified = intact and (not added or adopt and compatible)
          failure.stagedAddition = failure.originalScenesVerified and added
          pcall(
            log.trace,
            log,
            "Scene migration cleanup: original scenes %s",
            failure.originalScenesVerified and "verified" or "unverified"
          )
        end
        return failure
      end)
    end)
end

function M.compare(before, after, original, replacement, originalProtocol, replacementProtocol, approvedMoves)
  local function reject(check, message)
    pcall(log.trace, log, "Lighting comparison: %s", check)
    return false, message
  end
  if not M.complete(before) then
    return reject(
      "saved references incomplete",
      "The saved migration cannot verify the full lighting settings. Restore the project backup before trying again."
    )
  end
  if not M.complete(after) then
    return reject("current references incomplete", "Read the current lighting references again.")
  end
  before, after = M.checkpoint(before), M.checkpoint(after)
  local moves = {}
  if original and replacement then
    moves[tostring(original)] = tostring(replacement)
  end
  if originalProtocol then
    moves[tostring(originalProtocol)] = tostring(replacementProtocol)
  end
  local destinations = {}
  for _, target in pairs(moves) do
    destinations[target] = true
  end
  for _, kind in ipairs({ "scenes", "groups" }) do
    local changed = after[kind]
    local affected = {}
    for old, new in pairs(moves) do
      local expected, found = before[kind][old] or {}, changed[new] or {}
      if next(changed[old] or {}) then
        return reject(kind .. " still reference original", "A lighting reference still uses the original driver.")
      end
      for id, reference in pairs(expected) do
        local moved = found[id]
        if not sameReference(kind, reference, moved) then
          return reject(
            kind .. (moved and " replacement settings differ" or " replacement reference missing"),
            "Check the saved settings of " .. reference.name .. "."
          )
        end
        affected[id] = reference.name
      end
      for id in pairs(found) do
        if not expected[id] then
          return reject(
            kind .. " contains unreviewed replacement reference",
            "The replacement has an unreviewed lighting reference."
          )
        end
      end
    end
    -- Group-owned scenes remain on the same group proxy throughout cutover.
    for member, references in pairs(before[kind]) do
      if not moves[member] and not destinations[member] then
        local current = changed[member] or {}
        for id, reference in pairs(references) do
          if not sameReference(kind, reference, current[id], true) then
            return reject(
              kind .. " group-owned reference missing or changed",
              "Check the lighting references on " .. reference.name .. "."
            )
          end
          affected[id] = reference.name
        end
        for id in pairs(current) do
          if not references[id] then
            return reject(kind .. " gained a group-owned reference", "A related lighting reference changed.")
          end
        end
      end
    end
    for member in pairs(changed) do
      if not moves[member] and not destinations[member] and not before[kind][member] then
        return reject(
          kind .. " contains an unreviewed related reference",
          "The replacement has an unreviewed related lighting reference."
        )
      end
    end
    for id, name in pairs(affected) do
      local same, difference = sameMembers(
        before.members[kind][id],
        after.members[kind][id],
        moves,
        approvedMoves,
        kind == "scenes",
        traceEnabled()
      )
      if not same then
        return reject(
          kind .. " complete membership differs: " .. difference,
          "Check the other members and saved settings of " .. name .. "."
        )
      end
    end
  end
  pcall(log.trace, log, "Lighting comparison: current references verified")
  return true
end

return M

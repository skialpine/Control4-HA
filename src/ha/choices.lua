-- Shared picker policy; metadata is never load/gesture authority. The template
-- provides promises and table helpers; only exact registry IDs are inspected.
local codec = require("ha.codec")
local contract = require("ha.contract")
local lightCapabilities = require("ha.light-capabilities")
local families = require("ha.endpoint-families")
local deferred = require("deferred")
require("lib.utils")
local M = {}
-- Registry evidence travels with the in-memory row without changing its wire format.
local registryByRow = setmetatable({}, { __mode = "k" })
local hiddenMigrationByRow = setmetatable({}, { __mode = "k" })
M.setupTypes = {
  { id = "lighting", name = "Lights and switches" },
  { id = "light", name = "Lights" },
  { id = "switch", name = "Switches" },
}
for _, family in ipairs(families.order) do
  M.setupTypes[#M.setupTypes + 1] = { id = family, name = families[family].name }
end

-- A binary light can use either driver. Its Home Assistant domain decides
-- where it appears in Quick Setup; eligibility decides which driver can run it.
function M.suggestedFamily(row)
  local preferred = row.domain == "light" and "light" or "switch"
  for _, family in ipairs(row.families or {}) do
    if family == preferred then
      return preferred
    end
  end
  return row.families and row.families[1]
end

function M.endpointKeys(row)
  local choice = row.attributes.device_choice
  local load = choice and choice.source_load
  local canonical = load and load.entity_id or row.entity_id
  local keys = { [canonical] = true, [row.entity_id] = true }
  for _, alias in ipairs(row.entity_aliases or {}) do
    keys[alias] = true
  end
  return canonical, keys
end

function M.gestureEntity(row)
  local physical = row.attributes.device_choice
  local gesture = physical and physical.gesture_entity_id or row.inferred_gesture_entity_id
  return contract.entity(gesture) and gesture:match("^event%.") and gesture or nil
end

function M.standaloneRegistry(row)
  local observed = registryByRow[row]
  return observed or nil, observed ~= nil
end

function M.hiddenMigrationLoad(row)
  return hiddenMigrationByRow[row]
end

local function entity(value)
  return type(value) == "string" and value:match("^[a-z][a-z0-9_]*%.[a-z0-9_]+$") ~= nil
end
local registryId = contract.registryId
local function wrapperTarget(entry)
  if not codec.isObject(entry) or entry.platform ~= "switch_as_x" then
    return
  end
  local options = codec.isObject(entry.options) and (entry.options.switch_as_x or entry.options.light)
  if codec.isObject(options) and type(options.entity_id) == "string" then
    return options.entity_id, options.invert
  end
end

local function source(row)
  local choice = row.attributes.device_choice
  if choice then
    if choice.source_load then
      return codec.isObject(choice.source_load) and choice.source_load.entity_id or false
    end
    return choice.gesture_entity_id
  end
  return row.entity_id
end
local function enabled(entry, allowHidden)
  return codec.isObject(entry)
    and entry.disabled_by == codec.null
    and (entry.hidden_by == codec.null or allowHidden and (entry.hidden_by == "user" or entry.hidden_by == "integration"))
    and entry.entity_category == codec.null
    and type(entry.platform) == "string"
    and entry.platform ~= "control4"
end
function M.matchesLightWrapper(entry, entity, registry)
  local target, invert = wrapperTarget(entry)
  return enabled(entry) == true and target ~= nil and invert == false and (target == entity or target == registry)
end
-- A nil registry map means the supported companion projection already applied
-- eligibility and alias policy. Family capability rules remain shared.
function M.apply(rows, entries, native)
  local projected = entries == nil
  entries = entries or {}
  local result, byEntity, byRegistry, wrappers, candidates = codec.array({}), {}, {}, {}, {}
  local nativeGestures = {}
  for id, entry in pairs(entries) do
    if codec.isObject(entry) and registryId(entry.id) then
      byRegistry[entry.id] = id
    end
  end
  for _, row in ipairs(rows) do
    -- CopyTable strips nested codec identities; keep immutable descriptor
    -- containers and allocate only this record's derived picker fields.
    local item = codec.object(CopyTable(row, true))
    item.attributes = row.attributes
    item.entity_aliases, item.families, item.source_entity_id = codec.array({}), codec.array({}), nil
    item.bridge_gesture_entity_id, item.inferred_gesture_entity_id = nil, nil
    local choice, id = item.attributes.device_choice, source(item)
    local entry = id and entries[id]
    local eligible, dims = false, false
    if choice then
      if choice.kind ~= "switch" and choice.kind ~= "dimmer" and choice.kind ~= "remote" then
        return nil
      end
      if choice.source_load then
        local load = choice.source_load
        if
          not codec.isObject(load)
          or not entity(load.entity_id)
          or not registryId(load.registry_id)
          or load.domain ~= load.entity_id:match("^([^.]+)")
          or (load.domain ~= "light" and load.domain ~= "switch")
        then
          return nil
        end
        if
          projected
          and (item.entity_id ~= "device:" .. choice.device_id .. ":" .. load.registry_id or item.domain ~= load.domain)
        then
          return nil
        end
        eligible = projected or (enabled(entry) and entry.id == load.registry_id)
      elseif id then
        if not entity(id) or not id:match("^event%.") then
          return nil
        end
        eligible = projected or (enabled(entry) and entry.platform == "ha_gesture_bridge")
      else
        eligible = choice.kind == "remote"
      end
      if
        projected
        and not choice.source_load
        and (
          choice.kind ~= "remote"
          or item.domain ~= "event"
          or item.entity_id ~= "device:" .. choice.device_id .. ":none"
        )
      then
        return nil
      end
      dims = choice.kind == "dimmer"
      item.source_entity_id = id
    else
      if projected and (item.is_group ~= true or item.domain == "event") then
        return nil
      end
      eligible = (
        projected
        or enabled(entry)
        or (native and entry == codec.null and contract.endpointDomain(item.entity_id))
      )
        and item.c4_exported ~= true
        and item.device_disabled ~= true
      local modes = item.attributes.supported_color_modes
        or (codec.isObject(entry) and codec.isObject(entry.capabilities) and entry.capabilities.supported_color_modes)
      dims = lightCapabilities.fromModes(modes)
      if
        native
        and not eligible
        and enabled(entry, true)
        and entry.entity_id == id
        and registryId(entry.id)
        and item.available == true
        and item.c4_exported ~= true
        and item.device_disabled ~= true
        and contract.loadDomain(id)
      then
        hiddenMigrationByRow[item] = { light = true, switch = not dims }
        eligible = true
      end
      if eligible and codec.isObject(entry) and entry.entity_id == id and registryId(entry.id) then
        registryByRow[item] = entry.id
        local gesture = row.bridge_gesture_entity_id
        if
          native
          and registryId(entry.device_id)
          and entry.device_id == item.device_id
          and contract.entity(gesture)
          and gesture:match("^event%.")
        then
          nativeGestures[item.device_id] = gesture
        end
      elseif eligible and entry == codec.null then
        registryByRow[item] = false
      end
    end
    -- Metadata is projected to explicit family eligibility, not whole-device
    -- equality. A dimmer does not appear as a normal Switch choice.
    if eligible then
      if families.domains[item.domain] then
        for _, family in ipairs(families.order) do
          if families.eligible(family, item.domain, item.attributes) then
            item.families[#item.families + 1] = family
          end
        end
      else
        item.families[#item.families + 1] = "light"
        if not dims then
          item.families[#item.families + 1] = "switch"
        end
      end
    end
    result[#result + 1] = item
    byEntity[item.entity_id] = item
  end
  if projected then
    return result
  end
  local function has(item, family)
    for _, value in ipairs(item.families) do
      if value == family then
        return true
      end
    end
    return false
  end
  local function remove(item, family)
    for index = #item.families, 1, -1 do
      if item.families[index] == family then
        table.remove(item.families, index)
      end
    end
  end
  -- A non-inverted switch-as-light registry link proves one alias. Names,
  -- source-device IDs and separately linked loads never prove equivalence.
  for _, item in ipairs(result) do
    local entry = entries[item.entity_id]
    if item.domain == "light" and not item.is_group and codec.isObject(entry) and entry.platform == "switch_as_x" then
      local target, invert = wrapperTarget(entry)
      local base = target and byEntity[byRegistry[target] or target]
      if base and (base.domain == "switch" or base.domain == "input_boolean") and not base.is_group then
        local baseEntry = entries[base.entity_id]
        if base.c4_exported == true or (codec.isObject(baseEntry) and baseEntry.platform == "control4") then
          item.families = codec.array({})
          hiddenMigrationByRow[item], registryByRow[item] = nil, nil
        elseif invert == false and hiddenMigrationByRow[base] and item.available ~= true then
          item.families = codec.array({})
        elseif invert == false and hiddenMigrationByRow[item] and not hiddenMigrationByRow[base] then
          for _, family in ipairs({ "light", "switch" }) do
            if has(base, family) then
              remove(item, family)
            end
          end
        elseif invert == false and (not hiddenMigrationByRow[item] or hiddenMigrationByRow[base]) then
          local hiddenBase = codec.isObject(baseEntry)
            and baseEntry.disabled_by == codec.null
            and baseEntry.hidden_by ~= codec.null
            and baseEntry.entity_category == codec.null
          for _, family in ipairs({ "light", "switch" }) do
            if has(item, family) and (has(base, family) or hiddenBase) then
              local key = family .. ":" .. base.entity_id
              candidates[key] = candidates[key] or {}
              candidates[key][#candidates[key] + 1] = item
              local previous = wrappers[key]
              local hidden, previousHidden = hiddenMigrationByRow[item] ~= nil, hiddenMigrationByRow[previous] ~= nil
              if
                not previous
                or (previousHidden and not hidden)
                or (hidden == previousHidden and item.entity_id < previous.entity_id)
              then
                wrappers[key] = item
              end
            end
          end
        end
      elseif native then
        -- A loaded Switch as X on supported HA publishes its target in the
        -- entity registry. An unproven wrapper cannot establish eligibility.
        item.families = codec.array({})
        hiddenMigrationByRow[item], registryByRow[item] = nil, nil
      end
    end
  end
  for key, preferred in pairs(wrappers) do
    local family, id = key:match("^([^:]+):(.+)$")
    local base = byEntity[id]
    local uniqueVisible = not hiddenMigrationByRow[preferred]
    remove(base, family)
    for _, duplicate in ipairs(candidates[key]) do
      if duplicate ~= preferred then
        uniqueVisible = uniqueVisible and hiddenMigrationByRow[duplicate] ~= nil
        remove(duplicate, family)
        preferred.entity_aliases[#preferred.entity_aliases + 1] = duplicate.entity_id
      end
    end
    local hidden = hiddenMigrationByRow[base]
    if hidden and uniqueVisible and preferred.available == true and registryByRow[preferred] then
      hidden.wrappers = hidden.wrappers or {}
      hidden.wrappers[family] = preferred
    end
    local seen = false
    for _, alias in ipairs(preferred.entity_aliases) do
      if alias == id then
        seen = true
      end
    end
    if not seen then
      preferred.entity_aliases[#preferred.entity_aliases + 1] = id
    end
  end
  local loadByDevice = {}
  for _, item in ipairs(result) do
    if native then
      -- A prepared device and a native choice can represent the same exact
      -- registry load even when only the native choice is currently offered.
      for index = 0, #item.entity_aliases do
        local id = item.entity_aliases[index] or item.entity_id
        local candidate = byEntity[id]
        local registry = candidate and registryByRow[candidate]
        local entry = entries[id]
        if registryId(registry) and registryId(candidate.device_id) and entry.device_id == candidate.device_id then
          item.entity_aliases[#item.entity_aliases + 1] = "device:" .. candidate.device_id .. ":" .. registry
          if #item.families > 0 and item.is_group ~= true then
            local existing = loadByDevice[candidate.device_id]
            loadByDevice[candidate.device_id] = (existing == nil or existing == item) and item or false
          end
        end
      end
    end
    table.sort(item.entity_aliases)
    for index = #item.entity_aliases, 2, -1 do
      if item.entity_aliases[index] == item.entity_aliases[index - 1] then
        table.remove(item.entity_aliases, index)
      end
    end
  end
  -- A button event accounts for a device in the installer list only when the
  -- registered source has one eligible load after resolving exact aliases.
  for device, gesture in pairs(nativeGestures) do
    local item = loadByDevice[device]
    if item then
      local existing = item.inferred_gesture_entity_id
      item.inferred_gesture_entity_id = (existing == nil or existing == gesture) and gesture or false
    end
  end
  return result
end

-- The companion supplies the richer physical choice. Native discovery fills
-- independent loads and attaches aliases only when registry evidence proves
-- equivalence for this family.
function M.merge(preferred, native)
  local result, owners, byId = codec.array({}), {}, {}
  local function key(family, entity)
    return family .. ":" .. entity
  end
  local function names(row)
    local entities = { row.source_entity_id or row.entity_id }
    for _, id in ipairs(row.entity_aliases or {}) do
      entities[#entities + 1] = id
    end
    return entities
  end
  for _, row in ipairs(preferred) do
    local item = codec.object(CopyTable(row, true))
    item.attributes = row.attributes
    item.families, item.entity_aliases = row.families, codec.array({})
    registryByRow[item] = registryByRow[row]
    for _, id in ipairs(row.entity_aliases or {}) do
      item.entity_aliases[#item.entity_aliases + 1] = id
    end
    byId[item.entity_id] = item
    result[#result + 1] = item
    for _, family in ipairs(item.families) do
      for _, entity in ipairs(names(item)) do
        owners[key(family, entity)] = item
      end
    end
  end
  for _, row in ipairs(native) do
    if #row.families > 0 then
      local entities, families = names(row), codec.array({})
      for _, family in ipairs(row.families) do
        local matched
        for _, entity in ipairs(entities) do
          matched = owners[key(family, entity)]
          if matched then
            break
          end
        end
        if matched then
          matched.inferred_gesture_entity_id = matched.inferred_gesture_entity_id or row.inferred_gesture_entity_id
          if type(row.available) == "boolean" and not matched.attributes.device_choice then
            matched.available = row.available
          end
          if matched.entity_id == row.entity_id and not matched.attributes.device_choice then
            registryByRow[matched] = registryByRow[row]
          end
          local have = { [matched.entity_id] = true }
          for _, entity in ipairs(names(matched)) do
            have[entity] = true
          end
          for _, entity in ipairs(entities) do
            if not have[entity] then
              matched.entity_aliases[#matched.entity_aliases + 1] = entity
              have[entity] = true
            end
          end
        else
          families[#families + 1] = family
        end
      end
      if #families > 0 and not byId[row.entity_id] then
        row.families = families
        result[#result + 1] = row
      end
    end
  end
  for _, row in ipairs(result) do
    table.sort(row.entity_aliases)
  end
  return result
end

function M.enrich(rows, request, active, native)
  local pending, ids, wanted, entries = deferred.new(), {}, {}, {}
  for _, row in ipairs(rows) do
    local id = source(row)
    if id then
      if not entity(id) then
        pending:reject({ kind = "invalid_endpoint_metadata" })
        return pending
      end
      if not wanted[id] then
        wanted[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  table.sort(ids)
  local offset = 1
  local function fail(kind)
    pending:reject({ kind = kind or "filtered_registry_failed" })
  end
  local function batch()
    if not active() then
      fail("retired")
      return
    end
    if offset > #ids then
      local result = M.apply(rows, entries, native)
      if result then
        pending:resolve(result)
      else
        fail("invalid_endpoint_metadata")
      end
      return
    end
    local selected, permitted = codec.array({}), {}
    for _ = 1, 50 do
      local id = ids[offset]
      if not id then
        break
      end
      selected[#selected + 1] = id
      permitted[id] = true
      offset = offset + 1
    end
    local sent = pcall(
      request,
      { type = "config/entity_registry/get_entries", entity_ids = selected },
      function(ok, value)
        if not active() then
          fail("retired")
          return
        end
        if not ok then
          fail(value.kind)
          return
        end
        if not codec.isObject(value) or #codec.encode(value) > 1048576 then
          fail("invalid_endpoint_metadata")
          return
        end
        for id in pairs(value) do
          if not permitted[id] then
            fail("invalid_endpoint_metadata")
            return
          end
        end
        for id in pairs(permitted) do
          local entry = value[id]
          if entry ~= codec.null and (not codec.isObject(entry) or entry.entity_id ~= id) then
            fail("invalid_endpoint_metadata")
            return
          end
          entries[id] = entry
        end
        batch()
      end
    )
    if not sent then
      fail("filtered_registry_failed")
    end
  end
  batch()
  return pending
end
return M

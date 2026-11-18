-- Recover a prototype Light configured by its HA event entity alone. An
-- explicit linked load and a physical source are independent facts.
local codec = require("ha.codec")
local contract = require("ha.contract")
local gesture = require("ha.gesture-contract")
local M = {}

function M.new(entity, mode)
  if
    not contract.entity(entity)
    or not entity:match("^event%.")
    or (mode ~= "bridge" and mode ~= "buttons" and mode ~= "connected")
  then
    return nil
  end
  return codec.object({
    version = 1,
    family = "light",
    key = entity,
    name = "",
    preparation = "not_required",
    input_ready = false,
    manual_event = true,
    prototype_mode = mode,
    prototype_mode_override = false,
    gesture_entity_id = entity,
  })
end

function M.valid(config)
  if
    config.family ~= "light"
    or config.manual_event ~= true
    or config.prototype_picker
    or config.source_load
    or config.preparation ~= "not_required"
    or config.key ~= config.gesture_entity_id
    or not contract.entity(config.key)
    or not config.key:match("^event%.")
  then
    return false
  end
  if not config.event_registry_id then
    return not config.control_id and not config.device_id and not config.controlled_load
  end
  local load = config.controlled_load
  return contract.registryId(config.event_registry_id)
    and gesture.identity(config.control_id)
    and (config.device_id == nil or gesture.identity(config.device_id))
    and (
      not load
      or (
        contract.registryId(load.registry_id)
        and config.controlled_load_origin == "explicit_link"
        and load.domain == contract.loadDomain(load.entity_id)
        and (load.domain == "light" or load.domain == "switch")
      )
    )
end

local function source(config, data, useLoad)
  local attrs = data.attributes
  if
    data.state == "unavailable"
    or not codec.isObject(attrs)
    or not (attrs.bridge_contract_version == "1.0" or attrs.bridge_contract_version == "1.1")
    or not gesture.identity(attrs.bridge_control_id)
    or not gesture.identity(attrs.bridge_session_id)
    or not gesture.anySourceReady(attrs)
    or (config.control_id and config.control_id ~= attrs.bridge_control_id)
  then
    return nil
  end
  local physical = attrs.bridge_source_device_id
  if physical == codec.null then
    physical = nil
  end
  if (physical and not gesture.identity(physical)) or (config.event_registry_id and config.device_id ~= physical) then
    return nil
  end

  local link = useLoad and attrs.bridge_load or nil
  if link == codec.null then
    link = nil
  end
  if
    link
    and (
      not codec.isObject(link)
      or (link.domain ~= "light" and link.domain ~= "switch")
      or contract.loadDomain(link.entity_id) ~= link.domain
      or link.available ~= true
    )
  then
    return nil
  end
  if useLoad and config.controlled_load and (not link or link.entity_id ~= config.controlled_load.entity_id) then
    return nil
  end
  return attrs, physical, link
end

local function reject(owner)
  if owner.eventCheck then
    owner.eventCheck.nextBaseline = nil
  end
  owner.eventProof, owner.eventLoad = nil, nil
  owner.error = "saved_device_unverified"
end

local function suspend(owner)
  local config = owner.config
  owner.inputReady, owner.restoredSourceReady = nil, nil
  owner.indicatorMeta, owner.indicatorRows, owner.indicatorSignature = nil, nil, nil
  owner.gestures:lost()
  if owner.adapter and config.controlled_load then
    owner.adapter:lost(config.controlled_load.entity_id)
  end
end

-- Return true only when this message belongs to the registry-verified source
-- and session. A cached load snapshot can arrive before its source snapshot.
function M.allow(owner, kind, data, save)
  local config = owner.config
  if not config.manual_event then
    return true
  end
  local state = kind == "snapshot" or kind == "state"
  if data.entity_id ~= config.gesture_entity_id then
    if state and config.controlled_load and data.entity_id == config.controlled_load.entity_id then
      owner.eventLoad = data
      return owner.eventProof and owner.eventProof.verified and owner.restoredSourceReady == true
    end
    return true
  end
  if not state then
    if kind == "failure" then
      reject(owner)
      suspend(owner)
    end
    return true
  end
  local useLoad = owner:mode() == "Home Assistant device"
  local attrs, physical, link = source(config, data, useLoad)
  if not attrs then
    reject(owner)
    suspend(owner)
    owner:render()
    return false
  end
  local session, control, target = attrs.bridge_session_id, attrs.bridge_control_id, link and link.entity_id
  local proof = owner.eventProof
  if
    proof
    and proof.session == session
    and proof.control == control
    and proof.physical == physical
    and proof.target == target
    and not (proof.failed and kind == "snapshot")
  then
    if not proof.verified then
      -- A button occurrence that arrives during verification is never replayed.
      if kind == "snapshot" or attrs.bridge_update_kind ~= "gesture" then
        proof.baseline = data
      end
      return false
    end
    owner.restoredSourceReady = true
    return true
  end
  if not gesture.capabilities(attrs) then
    reject(owner)
    suspend(owner)
    owner:render()
    return false
  end
  suspend(owner)
  if owner.eventCheck then
    owner.eventCheck.nextBaseline = data
    owner.eventProof = nil
    return false
  end
  if owner.working then
    return false
  end
  proof = { session = session, control = control, physical = physical, target = target, baseline = data }
  owner.eventProof, owner.eventCheck = proof, proof
  local args = codec.object({
    event_control = control,
    event_registry_id = config.event_registry_id,
    load_entity = target,
    load_registry_id = target and config.controlled_load and config.controlled_load.registry_id or nil,
  })
  local function current()
    if owner.eventCheck ~= proof then
      return false
    end
    owner.eventCheck = nil
    if owner.config ~= config or not owner.consumer:_current() then
      return false
    end
    if owner.eventProof == proof and not owner.working then
      return true
    end
    owner.eventProof = nil
    if proof.nextBaseline and not owner.working then
      owner:message("snapshot", proof.nextBaseline)
    end
    return false
  end
  owner.consumer:request("verify_target", config.key, args):next(function(receipt)
    if not current() then
      return
    end
    proof.verified = true
    owner.error, owner.restoredSourceReady = nil, true
    if not config.event_registry_id or (target and not config.controlled_load) then
      config.event_registry_id, config.control_id, config.device_id = receipt.event_registry_id, control, physical
      if
        type(attrs.friendly_name) == "string"
        and #attrs.friendly_name <= 1024
        and not attrs.friendly_name:find("%c")
      then
        config.name = attrs.friendly_name
      end
      if target then
        config.controlled_load =
          codec.object({ entity_id = target, domain = link.domain, registry_id = receipt.load_registry_id })
        config.controlled_load_origin = "explicit_link"
      end
      save(config)
      -- The new selection generation owns all subscriptions and gesture IDs.
      owner:activate()
      return
    end
    owner:message("snapshot", proof.baseline)
    if owner.eventProof ~= proof or owner.config ~= config then
      return
    end
    if owner.eventLoad then
      owner:message("snapshot", owner.eventLoad)
    elseif target and owner.consumer.readiness:view(target).snapshot then
      owner.consumer:refreshSelected()
    end
  end, function()
    if current() then
      proof.failed = true
      owner.error = "saved_device_unverified"
      owner:render()
    end
  end)
  return false
end

return M

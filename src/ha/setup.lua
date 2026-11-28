-- Shared setup lifecycle. Committed records own routing. Pending picker and
-- manual edits hold no routing authority, including on boot.
local Consumer = require("ha.consumer")
local Selection = require("ha.selection")
local Prototype = require("ha.prototype-selection")
local EventSelection = require("ha.event-selection")
local codec = require("ha.codec")
local contract = require("ha.contract")
local loadCommand = require("ha.load-command")
local operations = require("ha.operations")
local ids = require("ha.identities")
local initialCoordinator = require("ha.initial-coordinator")
local persist = require("lib.persist")
local values = require("lib.values")
local setupPage = require("ha.setup-page")
local Gestures = require("ha.gestures")
local gestureContract = require("ha.gesture-contract")
local indicators = require("ha.indicators")
local indicatorPrograms = require("ha.indicator-programs")
local catalogNames = require("ha.catalog-names")
local migration = require("ha.switch-migration")
local foundation = require("ha.foundation")
local log = require("lib.logging")
local Setup = {}
Setup.__index = Setup
local KEY = "HA.DeviceSelection"
local CLEARED = "false"
local LEGACY_DEFAULT = "light.table_lamp"
local function saveRecord(record)
  persist:set(KEY, codec.encode(record), true)
end

function Setup:hasSavedSelection()
  local ok, raw = pcall(C4.PersistGetValue, C4, KEY, true)
  local saved = ok and codec.storedObject(raw)
  return not not (self.config and saved and codec.encode(saved) == codec.encode(self.config))
end
local AUTO, NATIVE, LOCAL, BUTTONS = "Automatic", "Home Assistant device", "Connected Control4 light", "Buttons only"
local LOAD_ONLY, LOAD_BUTTONS = "Control linked device only", "Control device and report presses"
Setup.explain = setupPage.explain

local function retainedEndpoint(family)
  local package = ids.packages[family]
  return package and package.retainsLegacyInput
end

local function clearSavedSelection(family)
  if
    retainedEndpoint(family)
    or family == "light"
      and ((Properties["Entity ID"] or "") ~= "" or type(PersistData) == "table" and PersistData.DeviceSelection ~= nil)
  then
    -- An explicit clear must survive startup with the old field still present.
    persist:set(KEY, CLEARED, true)
  else
    persist:delete(KEY)
  end
end

function Setup:legacyDirect()
  if self.family ~= "light" or self.linked or (self.override ~= AUTO and self.override ~= NATIVE) then
    return nil
  end
  local entity = Properties["Entity ID"]
  local domain = contract.loadDomain(entity)
  if (domain ~= "light" and domain ~= "switch") or entity == LEGACY_DEFAULT then
    return nil
  end
  if type(PersistData) == "table" and (PersistData.DeviceSelection ~= nil or PersistData.ControllerModeOverride) then
    -- The old picker and controller modes may route to a different target.
    return nil
  end
  local mode = Properties["Operation Mode"]
  local bp = Variables.ENTITY_ID ~= nil
  if
    (mode ~= "Control HA Device" and not (bp and (mode == nil or mode == "")))
    or (bp and (domain ~= "light" or Variables.ENTITY_ID ~= entity))
  then
    return nil
  end
  local device = C4:GetDeviceID()
  for _, binding in pairs(ids.targetLinks) do
    local peer = tonumber(C4:GetBoundProviderDevice(device, binding))
    if peer and peer > 0 then
      return nil
    end
  end
  return entity
end

function Setup.new(family, publish, adapter)
  local self = setmetatable({ family = family, publish = publish, adapter = adapter, generation = 0 }, Setup)
  self.gestureCount = 0
  self.gestures = Gestures.new({
    onDelivered = function(event, sequence)
      self.gestureCount = self.gestureCount + 1
      UpdateProperty("Last Gesture", event)
      UpdateProperty("Gesture Count", tostring(self.gestureCount))
      if foundation.canLogDiagnostic("Button events") then
        foundation.logDiagnostic("Button events", "Button event " .. sequence .. " delivered to Control4")
      end
    end,
    savedLightEvents = family == "light" and function()
      return type(PersistData) == "table" and PersistData.DimmerGestureEventIDs or nil
    end or nil,
    nativeAction = adapter and adapter.nativeAction,
    publishNative = adapter and adapter.publishNative and function(occurrence)
      if self.consumer:_current() then
        adapter:publishNative(occurrence)
      end
    end,
    onOccurrence = function(occurrence)
      if adapter and adapter.gesture and self.consumer:_current() then
        return adapter:gesture(occurrence)
      end
      return false
    end,
    onCleanup = function(button)
      if adapter and adapter.releaseGesture then
        adapter:releaseGesture(button)
      end
    end,
    onAcknowledge = function(data)
      self.consumer:acknowledge(data)
    end,
  })
  self.consumer = Consumer.new(function(kind, data)
    self:message(kind, data)
  end, {
    mayCommission = function(wantedFamily, key)
      return wantedFamily == family
        and type(key) == "string"
        and #key > 0
        and #key <= 255
        and self.manual == ""
        and (Properties["Manual entity ID"] or "") == ""
        and not self.working
        and not self.error
        and not self.config
        and (not self.pending or self.pending.choice_id == key)
    end,
    stageLightSettings = adapter and adapter.stageMigrationSettings,
    applyCommission = function(config, lightSettings)
      if
        lightSettings ~= nil
        and (
          not adapter
          or not adapter.verifyMigrationSettings
          or not adapter.verifyMigrationSettings(config.key, lightSettings)
        )
      then
        return false
      end
      self:commit(config, "")
      return true
    end,
    isCurrent = function()
      return self.override == (Properties["Button behavior"] or AUTO)
    end,
    cleanup = {
      function(reason, entity)
        if adapter then
          adapter:lost(entity)
        end
        local config = self.config
        if not entity or config and config.controlled_load and config.controlled_load.entity_id == entity then
          self.loadFeatures, self.registryProof = nil, nil
          if not entity then
            self.loadName = nil
          end
        end
        if not entity or config and config.gesture_entity_id == entity then
          local facts = entity and reason == "readiness" and self.consumer.readiness:view(entity)
          if not (facts and facts.transport and facts.subscription and facts.snapshot) then
            if reason ~= "entity" then
              self.eventProof, self.eventLoad, self.eventCheck = nil, nil, nil
              if config and config.manual_event and config.controlled_load and adapter then
                adapter:lost(config.controlled_load.entity_id)
              end
            end
            self.inputReady, self.restoredSourceReady = nil, nil
            if
              config
              and config.prototype_mode == "bridge"
              and self.registryProof
              and self.registryProof.verified
              and adapter
            then
              adapter:lost(config.controlled_load and config.controlled_load.entity_id)
            end
            self.indicatorMeta, self.indicatorRows, self.indicatorSignature = nil, nil, nil
            self.gestures:lost(entity)
          end
        end
      end,
    },
  })
  return self
end

function Setup:readLinks()
  self.linked = self.adapter and self.adapter.readLinks and self.adapter:readLinks() or false
end

local switchModes = {
  plain = { AUTO },
  buttons = { AUTO, BUTTONS },
  combined = { AUTO, LOAD_ONLY, LOAD_BUTTONS, BUTTONS },
}

function Setup:switchModes()
  local config = self.config
  local options = config
      and config.gesture_entity_id
      and (config.controlled_load and switchModes.combined or switchModes.buttons)
    or switchModes.plain
  local saved = self.override
  for _, option in ipairs(options) do
    if option == saved then
      return options
    end
  end
  -- Keep an earlier release's saved label, or an override for a device that
  -- has since changed, readable until the user chooses a new mode.
  if saved == NATIVE or saved == LOAD_ONLY or saved == LOAD_BUTTONS or saved == BUTTONS then
    if self.modeOptionsSource ~= options or self.modeOptionsSaved ~= saved then
      local custom = { unpack(options) }
      custom[#custom + 1] = saved
      self.modeOptionsSource, self.modeOptionsSaved, self.modeOptions = options, saved, custom
    end
    return self.modeOptions
  end
  return options
end

function Setup:usesButtons()
  return self.config
    and self.config.gesture_entity_id
    and self.override ~= LOAD_ONLY
    and not (self.config.prototype_mode == "direct" and self:mode() == NATIVE)
end

function Setup:mode(candidate)
  if self.override == LOAD_ONLY or self.override == LOAD_BUTTONS then
    return NATIVE
  end
  if self.override ~= AUTO then
    return self.override
  end
  local config = candidate or self.config
  local saved = config and config.prototype_mode
  if self.linked and not (saved and config.prototype_mode_override) then
    return LOCAL
  end
  if saved == "buttons" then
    return BUTTONS
  end
  if saved == "connected" then
    return LOCAL
  end
  if saved == "direct" or saved == "bridge" then
    return NATIVE
  end
  return config and config.controlled_load and NATIVE or BUTTONS
end

function Setup:buttonBehaviorTargets()
  local config = self.config
  local load = config and config.controlled_load
  local haName = load
    and (
      setupPage.friendlyName(self.loadName)
      or setupPage.friendlyName(load.name)
      or (
        (config.key == load.entity_id or config.controlled_load_origin == "selected_endpoint")
        and setupPage.friendlyName(config.name)
      )
    )
  local linked = self.adapter and self.adapter.targetState and self.adapter:targetState()
  return haName, linked and setupPage.friendlyName(linked.name)
end

function Setup:hasAppLinkChoices()
  return self.linked and self.adapter and self.adapter.appLinkChoices and self.adapter:appLinkChoices() ~= nil
end

function Setup:buttonBehaviorLabels()
  local haName, connectedName = self:buttonBehaviorTargets()
  local haTarget = haName or "the Home Assistant load"
  return {
    [LOAD_ONLY] = "Control " .. haTarget .. " only",
    [LOAD_BUTTONS] = "Control " .. haTarget .. " + presses",
    [NATIVE] = "Home Assistant · " .. (haName or "Linked load"),
    [LOCAL] = "Control4 · " .. (connectedName or "Linked light"),
    [BUTTONS] = "Button presses only",
  }
end

function Setup:buttonBehaviorSummary()
  local mode = self:mode()
  local haName, connectedName = self:buttonBehaviorTargets()
  local config = self.config
  local summary
  if mode == LOCAL then
    summary = connectedName and ("The app controls " .. connectedName .. " through Control4.")
      or "Choose which connected Control4 light or lighting group the app will control."
  elseif mode == BUTTONS then
    summary = "App control is off."
  elseif haName then
    summary = "The app controls " .. haName .. " through Home Assistant."
  elseif config and config.controlled_load then
    summary = "Home Assistant has not reported the controlled load’s name yet."
  else
    summary = "Choose a Home Assistant load to use app control."
  end
  if self:usesButtons() then
    local source = setupPage.friendlyName(config.name)
    return summary
      .. (
        source and (" Use button presses from " .. source .. " in Control4 Programming.")
        or " Button presses are available in Control4 Programming."
      )
  end
  if config and config.gesture_entity_id then
    return summary .. " This mode turns off button presses in Control4 Programming."
  end
  return summary
end

function Setup:activate()
  self.eventProof, self.eventLoad, self.eventCheck = nil, nil, nil
  self.registryProof = nil
  local entities, config = codec.array({}), self.config
  local activeButtons = self:usesButtons()
  self.gestures:bind(activeButtons and config or nil)
  if config then
    local load = config.controlled_load
    if load and self:mode() == NATIVE and contract.entity(load.entity_id) then
      entities[#entities + 1] = load.entity_id
    end
    if activeButtons then
      entities[#entities + 1] = config.gesture_entity_id
    end
  end
  values:update("Selected Endpoint", config and config.key or "", "STRING")
  if (retainedEndpoint(self.family) or self.family == "light" and Variables.ENTITY_ID ~= nil) and config then
    local target = config.controlled_load
    local entity = target and self:mode() == NATIVE and target.entity_id or ""
    values:update("ENTITY_ID", entity, "STRING")
  end
  self.failures = {}
  if self.adapter then
    local target = config and config.controlled_load
    local entity = target and self:mode() == NATIVE and contract.entity(target.entity_id) and target.entity_id or nil
    self.adapter:bind(
      self.consumer,
      entity,
      function(status)
        values:update(
          "Last Command Result",
          status == "accepted" and "Accepted by Home Assistant" or Setup.explain(status),
          "STRING"
        )
      end,
      self:mode() == LOCAL,
      function()
        self:render()
      end
    )
  end
  self.consumer:select(entities)
  self:render()
end

function Setup:start()
  self.originalEntity = Properties["Entity ID"]
  if self.family == "light" then
    local label = persist:get("HA.LightOperationMode")
    self.originalMode = Prototype.mode(label) and label or nil
  end
  if not contract.endpointFamily(self.family) then
    UpdateProperty("Last Gesture", "")
    UpdateProperty("Gesture Count", "0")
    UpdateProperty("Last Sequence", "0")
  end
  local legacyManual = Properties["Manual entity ID"] or ""
  self.manual, self.override = "", Properties["Button behavior"] or AUTO
  self:readLinks()
  local raw = persist:get(KEY, nil, true)
  if
    raw == nil
    and legacyManual == ""
    and ((self.originalEntity or "") == "" or self.originalEntity == LEGACY_DEFAULT)
    and not (type(PersistData) == "table" and PersistData.DeviceSelection ~= nil)
  then
    self.assigningCoordinator = true
    initialCoordinator.tryConnect(self.consumer.device)
    self.assigningCoordinator = nil
  end
  if (self.family == "light" or retainedEndpoint(self.family)) and (raw == CLEARED or raw == false) then
    -- A retained field from the old driver cannot reverse an explicit clear.
    UpdateProperty("Manual entity ID", "")
    self:activate()
    return
  end
  local record = codec.storedObject(raw)
  local saved = codec.isObject(record)
    and type(record.key) == "string"
    and Selection.valid(record, { choice_id = record.key, family = self.family })
  if saved and type(record.manual) == "boolean" then
    self.config = record
    self.manual = record.manual and record.key or ""
    UpdateProperty("Manual entity ID", self.manual)
  elseif legacyManual ~= "" then
    local config = Selection.directLoad(self.family, legacyManual)
    if config then
      self:commit(config, legacyManual)
      return
    end
    UpdateProperty("Manual entity ID", "")
    self.manualAttempt = #legacyManual <= 255 and legacyManual or nil
    self.manualStatus = Setup.explain("invalid_manual")
    self.manualFailed = true
    self.config = saved and record or nil
  elseif saved then
    self.config = record
  elseif Selection.query(record) and record.family == self.family and record.prepare then
    self.pending = record
  elseif raw == nil then
    if self.family == "light" and type(PersistData) == "table" and PersistData.DeviceSelection ~= nil then
      local restored = Prototype.restore(
        PersistData.DeviceSelection,
        Properties["Operation Mode"],
        Properties["Entity ID"],
        PersistData.ControllerModeOverride
      )
      if restored then
        self:commit(restored, "")
        return
      end
      self.error = "saved_device_unverified"
      self:activate()
      return
    end
    if self.family == "light" then
      local event = EventSelection.new(Properties["Entity ID"], Prototype.mode(Properties["Operation Mode"]))
      if event then
        event.prototype_mode_override = type(PersistData) == "table" and PersistData.ControllerModeOverride == true
        self:commit(event, event.key)
        return
      end
    end
    if retainedEndpoint(self.family) then
      local entity = self.originalEntity
      local savedEntity = Variables.ENTITY_ID
      if (entity or "") == "" then
        entity = savedEntity
      end
      local config = Selection.directLoad(self.family, entity)
      if config and (not savedEntity or savedEntity == "" or savedEntity == entity) then
        self:commit(config, entity)
        return
      end
    end
    local target = self:legacyDirect()
    if target then
      self:commit(Selection.directLoad(self.family, target), target)
      return
    end
  else
    self.error = "saved_selection_unreadable"
  end
  if self.config and self.config.manual == nil then
    -- Older selections used the raw property to choose precedence. Once
    -- normalized, only the saved record can grant routing authority on boot.
    self.config.manual = false
    saveRecord(self.config)
  end
  self:activate()
end

function Setup:commit(config, manual)
  if self.originalMode then
    config.prototype_mode = Prototype.mode(self.originalMode)
    config.prototype_mode_override = config.prototype_mode ~= "connected"
  end
  config.manual = manual ~= ""
  saveRecord(config)
  self.config, self.manual, self.pending, self.working, self.error = config, manual, nil, nil, nil
  self.manualStatus, self.manualFailed = nil, nil
  UpdateProperty("Manual entity ID", manual)
  if retainedEndpoint(self.family) then
    self.originalEntity = config.controlled_load.entity_id
    UpdateProperty("Entity ID", self.originalEntity)
  end
  self:activate()
end

-- The prototype exposes four modes through a saved native property. Only a
-- change callback is an override; the XML default on a fresh add is inert.
function Setup:originalModeChanged(label)
  local mode = Prototype.mode(label)
  if not mode then
    UpdateProperty("Operation Mode", self.originalMode or "Control HA Device")
    return
  end
  if self.originalMode == label or (not self.originalMode and self.config and self.config.prototype_mode == mode) then
    return
  end
  self.generation = self.generation + 1
  self.working, self.error, self.manualStatus, self.manualFailed = nil, nil, nil, nil
  self.originalMode = label
  persist:set("HA.LightOperationMode", label)
  self.override = ({ buttons = BUTTONS, connected = LOCAL, direct = NATIVE, bridge = NATIVE })[mode]
  UpdateProperty("Button behavior", self.override)
  if self.config then
    self.config.prototype_mode, self.config.prototype_mode_override = mode, mode ~= "connected"
    if self.config.prototype_picker then
      local target = self.config.controlled_load
      self.originalEntity = (mode ~= "direct" and self.config.gesture_entity_id) or (target and target.entity_id) or ""
      UpdateProperty("Entity ID", self.originalEntity)
    end
    saveRecord(self.config)
  end
  self:activate()
end

function Setup:currentEdit(generation)
  return self.generation == generation
    and self.manual == (Properties["Manual entity ID"] or "")
    and self.override == (Properties["Button behavior"] or AUTO)
end

function Setup:propertyChanged(original)
  local manual = original and Properties["Entity ID"] or Properties["Manual entity ID"] or ""
  local override = Properties["Button behavior"] or AUTO
  if original then
    -- Composer can replay the old displayed field. An unchanged picker identity
    -- must keep its button source and operating mode.
    if self.config and self.config.prototype_picker and manual == self.originalEntity and not self.working then
      return
    end
    -- A property write arrives before Home Assistant can verify it. Restore the
    -- last accepted field immediately so a reload cannot adopt the pending edit.
    UpdateProperty("Entity ID", self.originalEntity or "")
  end
  if not original and self.manual == manual and self.override == override then
    return
  end
  self.generation = self.generation + 1
  local generation = self.generation
  self.working, self.error = nil, nil
  self.manualStatus, self.manualFailed = nil, nil
  local edited = original or self.manual ~= manual
  local modeChanged = self.override ~= override
  self.override = override
  if modeChanged and self.originalMode then
    self.originalMode = nil
    persist:delete("HA.LightOperationMode")
  end
  if modeChanged and self.config and self.config.prototype_mode then
    self.config.prototype_mode, self.config.prototype_mode_override = nil, nil
    saveRecord(self.config)
  end
  if not edited then
    self:activate()
    return
  end
  if self.pending and not self.config then
    clearSavedSelection(self.family)
  end
  self.pending = nil
  UpdateProperty("Manual entity ID", self.manual)
  if manual == "" then
    self.manual, self.config = "", nil
    clearSavedSelection(self.family)
    if original then
      self.originalEntity = ""
      UpdateProperty("Entity ID", "")
    end
    if (self.family == "light" or retainedEndpoint(self.family)) and Variables.ENTITY_ID ~= nil then
      values:update("ENTITY_ID", "", "STRING")
    end
    if retainedEndpoint(self.family) then
      self.originalEntity = ""
      UpdateProperty("Entity ID", "")
    end
    UpdateProperty("Manual entity ID", "")
    self:activate()
    return
  end
  if modeChanged then
    self:activate()
  end
  self.manualAttempt = #manual <= 255 and manual or nil
  local config = Selection.directLoad(self.family, manual)
  if not config then
    self.manualStatus, self.manualFailed = Setup.explain("invalid_manual"), true
    self:render()
    return
  end
  self.working, self.manualStatus = "manual", "Checking the entity ID in Home Assistant…"
  self:render()
  local verify = codec.object({ family = contract.endpointFamily(self.family) and self.family or nil })
  self.consumer:request("verify_target", manual, verify):next(function()
    if self:currentEdit(generation) then
      if original then
        self.originalEntity = manual
        UpdateProperty("Entity ID", manual)
      end
      self:commit(config, manual)
    end
  end, function(err)
    if self:currentEdit(generation) then
      self.working, self.manualFailed = nil, true
      self.manualStatus = setupPage.explainManual(err.kind)
      self:render()
    end
  end)
end

function Setup:bindingsChanged(id)
  if id == ids.coordinatorBinding or id == ids.lightCoordinatorBinding then
    initialCoordinator.remember(self.consumer.device, id)
    if self.assigningCoordinator then
      return
    end
  end
  self.generation = self.generation + 1
  if self.working == "manual" then
    self.manualStatus, self.manualFailed = "The connection changed. Enter the entity ID again to retry.", true
  elseif self.working then
    self.error = "retired"
  end
  self.working = nil
  if id ~= ids.coordinatorBinding and id ~= ids.lightCoordinatorBinding then
    self:readLinks()
  end
  self:activate()
end

-- Hold the first usable state until the Coordinator checks the saved registry
-- records. Reuse that result until selection/transport/target evidence is lost.
function Setup:allowRestoredLoad(kind, data)
  local config = self.config
  local target = config.controlled_load
  local pin = contract.endpointFamily(self.family) and target and target.registry_id
  if
    config.manual_event
    or (not pin and not config.prototype_picker and config.prototype_mode ~= "bridge")
    or not target
    or data.entity_id ~= target.entity_id
    or self:mode() ~= NATIVE
    or (kind ~= "snapshot" and kind ~= "state")
    or (not pin and data.state ~= "on" and data.state ~= "off")
  then
    return true
  end
  if not pin and not config.prototype_picker and not self.registryProof then
    -- A modern selection is already resolved by the current Coordinator.
    -- Bridge mode still needs matching live button and linked-load metadata.
    self.registryProof = { verified = true }
  end
  if self.registryProof then
    if config.prototype_mode == "bridge" or not self.registryProof.verified then
      self.registryProof.latest = data
    end
    if self.registryProof.verified then
      return config.prototype_mode ~= "bridge" or self.restoredSourceReady == true
    end
    return false
  end
  local proof = { latest = data }
  self.registryProof = proof
  local arguments = pin and codec.object({ registry_id = pin }) or Prototype.proof(config)
  if not arguments then
    proof.failed = true
    self:render()
    return false
  end
  self.consumer:request("verify_target", data.entity_id, arguments):next(function()
    if self.registryProof == proof and self.config == config then
      proof.verified = true
      local latest = proof.latest
      proof.latest = nil
      self:message("snapshot", latest)
    end
  end, function()
    if self.registryProof == proof then
      proof.failed, proof.latest = true, nil
      self:render()
    end
  end)
  self:render()
  return false
end

function Setup:message(kind, data)
  local config = self.config
  local generation = self.generation
  if not config or not EventSelection.allow(self, kind, data, saveRecord) or not self:allowRestoredLoad(kind, data) then
    return
  end
  if kind == "failure" then
    self.failures[data.entity_id] = data.kind
  elseif kind == "snapshot" or kind == "state" then
    self.failures[data.entity_id] = nil
    local attrs = data.attributes
    local load = config.controlled_load
    if load and data.entity_id == load.entity_id then
      local friendly = setupPage.friendlyName(attrs.friendly_name)
      if friendly then
        self.loadName = friendly
        local named = config.key == load.entity_id and config or load
        if named.name ~= friendly then
          named.name = friendly
          saveRecord(config)
        end
      end
      self.loadFeatures = nil
      if self.family == "switch" and (data.state == "on" or data.state == "off") then
        self.loadFeatures = { "On and off" }
      end
    elseif data.entity_id == config.gesture_entity_id then
      -- An EventEntity has no timestamp before the first press. Its authenticated
      -- source metadata can still establish button readiness without an occurrence.
      local available = data.state ~= "unavailable"
      self.inputReady = false
      local meta = indicators.metadata(data, config.gesture_entity_id, config.device_id, config.control_id)
      if not meta then
        self.indicatorRows, self.indicatorSignature = nil, nil
      elseif
        not self.indicatorMeta
        or meta.bridge_session_id ~= self.indicatorMeta.bridge_session_id
        or kind == "snapshot"
        or meta.bridge_update_kind ~= "gesture"
      then
        local rows = indicators.project(meta)
        self.indicatorRows = rows
        self.indicatorSignature = codec.encode(rows)
      end
      self.indicatorMeta = meta
      self.inputReady = available and gestureContract.sourceReady(attrs, config.device_id, config.control_id)
      if config.manual_event and not config.device_id and self.eventProof and self.eventProof.verified then
        self.inputReady = available and gestureContract.anySourceReady(attrs)
      end
      if not config.manual_event and config.prototype_mode == "bridge" and self:mode() == NATIVE then
        local previous = self.restoredSourceReady
        local link = attrs.bridge_load
        local declared = link ~= nil and link ~= codec.null
        local target = config.controlled_load
        local matchingLink = declared
          and codec.isObject(link)
          and target
          and link.entity_id == target.entity_id
          and link.domain == target.domain
          and link.available == true
        self.restoredSourceReady = available
          and gestureContract.matchesSource(attrs, config.device_id, config.control_id)
          and gestureContract.identity(attrs.bridge_session_id)
          and (matchingLink or (not declared and config.controlled_load_origin ~= "explicit_link"))
        local proof = self.registryProof
        if proof and proof.verified and proof.latest then
          if self.restoredSourceReady and not previous then
            self:message("snapshot", proof.latest)
          elseif previous and not self.restoredSourceReady and self.adapter then
            self.adapter:lost(config.controlled_load.entity_id)
          end
        end
      end
    end
  end
  if self.adapter then
    self.adapter:message(kind, data)
  end
  if data.entity_id == config.gesture_entity_id then
    local facts = self.consumer.readiness:view(data.entity_id)
    self.gestures:message(kind, data, facts.transport and facts.subscription and facts.snapshot)
    if self.generation == generation and self.gestures.baseline then
      local sequence = tostring(self.gestures.sequence)
      if Properties["Last Sequence"] ~= sequence then
        UpdateProperty("Last Sequence", sequence)
      end
    end
  end
  if self.generation == generation then
    self:render()
  end
end

local function addLoadCapabilities(list, device)
  list[#list + 1] = "On and off"
  if device.dims then
    list[#list + 1] = "Brightness"
  end
  if device.color then
    list[#list + 1] = "Color"
  end
  if device.cct then
    list[#list + 1] = "White temperature"
  end
end

function Setup:connectedView(state)
  local target = self.adapter and self.adapter.targetState and self.adapter:targetState() or {}
  state.target = setupPage.friendlyName(target.name) or "Connected Control4 light"
  state.title = self.config and setupPage.basicNames(self.config, LOCAL, self.loadName)
    or setupPage.friendlyName(target.name)
  state.capabilities = state.capabilities or {}
  if target.ready then
    state.status, state.detail = "Device connected", "The app uses the connected Control4 light."
    addLoadCapabilities(state.capabilities, target.device)
    if not self.config and state.can_browse then
      state.detail = "Choose a Home Assistant device if you also want to use its buttons."
    end
  elseif target.reason == "waiting_target" then
    state.status, state.detail =
      "Waiting for connected light", "Check that the linked light or lighting group is available."
  elseif self:hasAppLinkChoices() then
    state.status, state.detail =
      "Choose a connected light", "Choose a destination under “Light controlled by the app” below."
  else
    state.status, state.detail =
      "Choose a connected light", "Connect one light or lighting group to the App Control Link."
  end
end

function Setup:deviceView()
  local config = self.config
  local state = {
    can_browse = self.consumer.provider ~= nil,
    helper = self.helper,
    native_endpoint = contract.endpointFamily(self.family) or nil,
  }
  local mode = self:mode()
  if not config then
    if mode == LOCAL then
      self:connectedView(state)
      return state
    end
    state.status = "Not configured"
    state.detail = state.can_browse and "Open Device Setup and choose the device you want to use."
      or Setup.explain("unbound")
    return state
  end
  local load = config.controlled_load
  state.selected_id = config.key
  state.title = setupPage.basicNames(config, mode, self.loadName)
  state.capabilities = {}
  if mode == NATIVE then
    if self.family == "light" then
      local device = self.adapter and self.adapter:loadDevice()
      if device then
        addLoadCapabilities(state.capabilities, device)
      end
    else
      for _, feature in ipairs(self.loadFeatures or {}) do
        state.capabilities[#state.capabilities + 1] = feature
      end
    end
  end
  if self:usesButtons() then
    state.capabilities[#state.capabilities + 1] = "Button presses"
  end
  local lease = self:indicatorLease()
  if lease and self.indicatorRows and #self.indicatorRows > 0 then
    state.capabilities[#state.capabilities + 1] = "Indicator lights"
    state.indicator_lease = lease
    state.indicator_policy = indicatorPrograms.pagePolicy(self)
    state.indicator_following = state.indicator_policy == "single" and indicatorPrograms.following(self) or nil
    state.indicators, state.indicator_signature = indicatorPrograms.pageRows(self)
  elseif config.device_id or config.gesture_entity_id then
    local facts = self.consumer.readiness:view(config.gesture_entity_id)
    if config.gesture_entity_id and not self:usesButtons() then
      state.indicator_hint =
        "Button reporting is off. In Button controls, choose a behavior that reports button presses to see indicator settings."
    elseif not facts.binding or not facts.transport then
      state.indicator_hint = "Reconnect to Home Assistant to check this device’s indicator settings."
    elseif config.gesture_entity_id and (not facts.subscription or not facts.snapshot) then
      state.indicator_hint = "Waiting for Home Assistant to report this device’s indicator settings."
    else
      state.indicator_hint =
        "Home Assistant hasn’t reported adjustable indicators for this device. If it has indicator lights, check its settings in HA Gesture Bridge."
    end
  end
  if mode == LOCAL then
    self:connectedView(state)
  elseif mode == BUTTONS then
    local facts = self.consumer.readiness:view(config.gesture_entity_id)
    state.target = "Buttons only"
    if not config.gesture_entity_id then
      state.status, state.detail =
        "No buttons found", "Choose a device with button support, or change Button behavior in Device Setup."
    elseif self.inputReady and facts.transport and facts.subscription and facts.snapshot then
      state.status, state.detail =
        "Buttons connected", "Use button presses in Control4 programming. App control is off in Buttons only mode."
      state.buttons_ready = true
    else
      state.status, state.detail =
        "Waiting for buttons", "Check the button device in Home Assistant. App control is off in Buttons only mode."
    end
  else
    state.target = self.loadName
      or (config.controlled_load_origin == "explicit_link" and "Linked Home Assistant device")
      or state.title
    if not load or not contract.entity(load.entity_id) then
      state.status, state.detail =
        "Check the linked device",
        contract.endpointFamily(self.family) and "Choose a device of this type in Home Assistant."
          or "Select a light or switch as the controlled device in Home Assistant."
    elseif not state.can_browse then
      state.status, state.detail = "Coordinator connection needed", Setup.explain("unbound")
    else
      local facts = self.consumer.readiness:view(load.entity_id)
      if self.registryProof and self.registryProof.failed then
        state.status, state.detail = "Check the saved device", Setup.explain("saved_device_unverified")
      elseif
        (config.prototype_picker or load.registry_id and contract.endpointFamily(self.family))
        and facts.evidence_ready
        and not (self.registryProof and self.registryProof.verified)
      then
        state.status, state.detail =
          "Checking the saved device", "Checking that Home Assistant still has the device you selected."
      elseif config.prototype_mode == "bridge" and facts.evidence_ready and not self.restoredSourceReady then
        state.status, state.detail =
          "Waiting for buttons", "Check the selected button device and HA Gesture Bridge in Home Assistant."
      elseif facts.evidence_ready and self.adapter and self.adapter.feedbackUnavailable then
        state.status = "Device unavailable"
        state.detail = "Home Assistant did not confirm the device’s state. Refresh to check the same device."
        state.feedback_retry, state.retry = true, true
      elseif facts.evidence_ready then
        state.status, state.detail = "Device connected", "Home Assistant is reporting its state."
      elseif facts.transport == false then
        state.status, state.detail = "Home Assistant disconnected", Setup.explain("disconnected")
      elseif self.failures[load.entity_id] == "permission_denied" then
        state.status, state.detail = "Device access denied", Setup.explain("permission_denied")
      elseif self.failures[load.entity_id] == "not_found" then
        state.status, state.detail =
          "Device unavailable", "Check that the controlled device still exists in Home Assistant."
      elseif facts.snapshot and not facts.available or load.available == false and not facts.snapshot then
        state.status, state.detail =
          "Device unavailable", "Check the selected device and its connection in Home Assistant."
      else
        state.status, state.detail = "Waiting for device", "Waiting for Home Assistant to report its current state."
      end
    end
  end
  if config.manual_event and state.can_browse and (not self.eventProof or not self.eventProof.verified) then
    if self.error then
      state.status, state.detail = "Check the saved device", Setup.explain(self.error)
    else
      state.status, state.detail =
        "Checking the saved device", "Checking that Home Assistant still has the device you selected."
    end
  end
  return state
end

function Setup:view()
  local state = self:deviceView()
  state.migration_available = migration.reviewAvailable(self.family, self.config ~= nil or self.linked == true)
  state.button_behavior_summary = self:buttonBehaviorSummary()
  local adapter = self.adapter
  local target = self:mode() == LOCAL and adapter and adapter.targetState and adapter:targetState()
  if target and target.device and target.device.dims then
    local rampTarget = adapter and adapter.bottomRampTarget and setupPage.friendlyName(adapter:bottomRampTarget())
    state.linked_settings_help = "App On uses the linked light’s Brightness On Mode."
      .. " Where available, edit Click Rates and Hold Ramp Rates on the light each paddle controls."
      .. (rampTarget and (" For this bottom paddle, edit Hold Ramp Rates → Down on " .. rampTarget .. ".") or "")
      .. " Explicit brightness or color changes can still use a requested transition rate."
  end
  state.app_link_available = self:mode() == LOCAL and self:hasAppLinkChoices() or nil
  state.separate_target = self.config ~= nil
    and (self:mode() == LOCAL or self.config.controlled_load_origin == "explicit_link")
  local connectedTarget = self.config or self:mode() == LOCAL
  state.manual_status = self.manualStatus
  state.manual_failed = self.manualFailed or nil
  state.rejected_manual = self.manualFailed and self.manualAttempt or nil
  if self.working == "manual" or self.manualFailed then
    if not connectedTarget then
      state.status = self.manualFailed and "Check the manual entry" or "Checking the manual entry"
    end
  elseif self.working then
    if connectedTarget then
      state.operation = "Checking the new device before switching."
    else
      state.status, state.detail = "Setting up your device", "Waiting for Home Assistant to finish."
    end
  elseif self.pending or self.error then
    state.retry = state.retry
      or (
        state.can_browse
        and self.pending ~= nil
        and self.error ~= "revision_changed"
        and self.error ~= "catalog_unverified"
      )
    local detail = self.error and Setup.explain(self.error) or "Choose Retry setup to finish setting up this device."
    if self.config and self.config.manual_event and self.error == "saved_device_unverified" and not self.pending then
      state.retry = state.can_browse
      state.detail = self:mode() == NATIVE
          and "Check the saved button device and its linked light in Home Assistant, then choose Retry setup."
        or "Check the saved button device in Home Assistant, then choose Retry setup."
      return state
    end
    if connectedTarget then
      state.operation = detail
    else
      state.status, state.detail = "Setup needs attention", detail
    end
  end
  return state
end

function Setup:refreshFeedback(done)
  local generation = self.generation
  local entity = self.config.controlled_load.entity_id
  local feedbackError =
    "Home Assistant could not confirm the current state. Check the device in Home Assistant and try again."
  local function finish(data)
    if generation ~= self.generation then
      done({ error = "The selected device changed. Check its current state." })
      return
    end
    if
      self.adapter.feedbackUnavailable
      and contract.state(data, entity)
      and (contract.endpointFamily(self.family) or data.state == "on" or data.state == "off")
    then
      self:message("snapshot", data)
    end
    if self.adapter.feedbackUnavailable then
      done({ error = feedbackError })
    else
      done({ message = "Device state refreshed." })
    end
  end
  loadCommand.read(self.consumer, entity):next(finish, function()
    finish(nil)
  end)
end

function Setup:indicatorLease()
  local entity = self.config and self.config.gesture_entity_id
  local meta = self.indicatorMeta
  if entity and meta and self:usesButtons() then
    local facts = self.consumer.readiness:view(entity)
    if facts.binding and facts.transport and facts.subscription and facts.snapshot then
      return self.consumer.session .. ":" .. self.consumer.selection .. ":" .. meta.bridge_session_id
    end
  end
end

function Setup:changeIndicator(params, done)
  if self.indicatorPending then
    done({ error = Setup.explain("busy") })
    return
  end
  local lease = self:indicatorLease()
  local meta = self.indicatorMeta
  if params.field == "on_color" or params.field == "off_color" then
    if indicatorPrograms.savePageColor(self, params) then
      self:render()
      done({ message = "Indicator color saved." })
    else
      done({ error = Setup.explain("indicator_unavailable") })
    end
    return
  end
  local singleBehavior = params.field == "behavior"
    and lease
    and lease == params.lease
    and self.consumer:_current()
    and indicatorPrograms.pagePolicy(self) == "single"
    and self.indicatorRows[1].id == params.id
  if singleBehavior and (params.value == "follow_bound" or params.value == "use_device_setting") then
    local policy = params.value == "follow_bound" and "Follow Bound Device" or "Use Device Setting"
    UpdateProperty("LED Behavior", policy, true)
    done({ message = "Indicator behavior saved." })
    return
  end
  if
    not lease
    or lease ~= params.lease
    or params.field == "tracking_color"
    or not indicators.allowed(meta, params.id, params.field, params.value)
  then
    done({ error = Setup.explain("indicator_unavailable") })
    return
  end
  local owner = { replaceFollow = singleBehavior and indicatorPrograms.following(self) }
  self.indicatorPending = owner
  local function complete(err)
    if self.indicatorPending == owner then
      self.indicatorPending = nil
    end
    if self:indicatorLease() ~= lease then
      done({ error = Setup.explain("indicator_unavailable") })
    elseif err then
      done({ error = Setup.explain(err.kind == "rejected" and "indicator_rejected" or err.kind) })
    else
      if owner.replaceFollow and Properties["LED Behavior"] == "Follow Bound Device" then
        UpdateProperty("LED Behavior", "Use Device Setting", true)
      end
      done({ message = "Change accepted. The settings shown follow device feedback." })
    end
  end
  self:sendIndicator(params.id, params.field, params.value):next(function()
    complete()
  end, complete)
end

function Setup:sendIndicator(id, field, value)
  return self.consumer:request(
    "indicator",
    self.config.gesture_entity_id,
    codec.object({
      device = self.config.device_id,
      control = self.config.control_id,
      session = self.indicatorMeta.bridge_session_id,
      id = id,
      field = field,
      value = value,
    })
  )
end

function Setup:render()
  local state = self:view()
  UpdateProperty("Driver Status", state.status)
  local nextStep = state.manual_status or state.operation or state.detail
  if state.feedback_retry then
    nextStep = "Open Device Setup and select Refresh device state."
  elseif
    state.status == "Device connected"
    and state.selected_id
    and not state.manual_status
    and not state.operation
  then
    nextStep = "To change this device, open Device Setup."
  end
  UpdateProperty("Next step", nextStep)
  if self.adapter and self.adapter.setButtonsReady then
    self.adapter:setButtonsReady(state.buttons_ready == true)
  end
  if self.publish then
    self.publish(state)
  end
end

local function browseDevices(self, params, done, nativePicker)
  local sensor = Properties["Discovery Catalog Entity ID"]
  -- The normal device list already includes names. Read a second source only for an explicit override or the legacy native picker.
  local useSensor = nativePicker or (sensor and sensor ~= "" and sensor ~= catalogNames.default)
  local invalidSensor = sensor and sensor ~= "" and not contract.catalogSensor(sensor)
  local args = codec.object({
    family = self.family,
    cursor = params.cursor,
    revision = params.revision,
    refresh = params.refresh == true and true or nil,
    names_sensor = useSensor and not invalidSensor and sensor or nil,
  })
  self.consumer:request("catalog", nil, args):next(function(page)
    self.helper = page.source == "companion"
    local ok, response = pcall(setupPage.choices, page, false, nativePicker)
    if not ok then
      log:error("Device Setup could not format the catalog page")
      done({ error = "The driver could not display the device list. Reload devices to try again." })
      return
    end
    response.catalogWarning = response.catalogWarning or invalidSensor or nil
    done(response)
  end, function(err)
    done({ error = Setup.explain(err.kind) })
  end)
end

function Setup:browse(params, done, nativePicker)
  if not pcall(browseDevices, self, params, done, nativePicker) then
    log:error("Device Setup could not start the catalog request")
    done({ error = "The driver could not request the device list. Reload devices to try again." })
  end
end

function Setup:choose(params, done)
  local query =
    codec.object({ family = self.family, revision = params.revision, choice_id = params.choice_id, prepare = true })
  if not Selection.query(query) then
    done({ error = "Open the device list and choose a device." })
    return
  end
  self.generation = self.generation + 1
  local generation = self.generation
  local replacing = self.config or self:mode() == LOCAL
  self.pending, self.working, self.error = query, "catalog", nil
  self.manualStatus, self.manualFailed = nil, nil
  if not self.config then
    persist:set(KEY, codec.encode(query), true)
  end
  self:render()
  local function failed(err)
    if self:currentEdit(generation) then
      self.error, self.working = err.kind, nil
      self:render()
    else
      err = { kind = "retired" }
    end
    done({ error = Setup.explain(err.kind) })
  end
  local function apply(config)
    if not self:currentEdit(generation) then
      failed({ kind = "retired" })
      return
    end
    self:commit(config, "")
    done({})
  end
  self.consumer:request("resolve", nil, query):next(function(config)
    if not self:currentEdit(generation) then
      failed({ kind = "retired" })
      return
    end
    local mode = self:mode(config)
    local load = config.controlled_load
    local gesture = mode ~= NATIVE and config.gesture_entity_id
    if replacing and not (gesture or (mode ~= BUTTONS and load)) then
      failed({ kind = mode == BUTTONS and "no_buttons" or "missing_load" })
      return
    end
    if self.config and ((gesture and not config.input_ready) or (not gesture and load and load.available == false)) then
      failed({ kind = "unavailable" })
      return
    end
    apply(config)
  end, failed)
end

function Setup:destroy()
  self.generation, self.publish = self.generation + 1, nil
  self.consumer:destroy()
  self.gestures:lost()
  if self.adapter then
    self.adapter:unbind()
  end
end
return Setup

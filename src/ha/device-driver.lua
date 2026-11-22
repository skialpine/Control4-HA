-- Wiring shared by each consumer family, one Lua environment per installed driver.
local Setup = require("ha.setup")
local foundation = require("ha.foundation")
local codec = require("ha.codec")
local ids = require("ha.identities")
local events = require("lib.events")
local page = require("lib.ui.page")
local setupPage = require("ha.setup-page")
local properties = require("lib.ui.tab-properties")
local migrationSelection = require("ha.migration-selection")
local metrics = require("ha.performance").shared
local M = {}

local indicatorBehaviorLabels = {
  ["Use Device Setting"] = "Keep current LED setting",
  ["Follow Load"] = "On when the device is on",
  ["Follow Load (Inverted)"] = "On when the device is off",
  ["Always On"] = "Always on",
  ["Always Off"] = "Always off",
  ["Follow Bound Device"] = "Follow the linked light",
}

function M.install(family, makeAdapter)
  local adapter = makeAdapter and makeAdapter()
  local connectionName = family == "light" and "Home Assistant Connection" or "HA Suite Coordinator"
  local setup, visible, previous, previousCapabilities
  local picker = family == "light" and require("ha.native-picker").install(function()
    return setup
  end)
  local programs = require("ha.indicator-programs")
  programs.install(family, function()
    return setup
  end)
  local function applicableChoices(name)
    if family == "switch" and name == "Button behavior" then
      return setup and setup:switchModes() or {}
    end
    if name == "LED Behavior" then
      return programs.policyChoices(setup)
    end
    if family == "light" and name == "LED Feedback Source" then
      return programs.sourceChoices(setup)
    end
  end
  local function offered(name)
    local options = applicableChoices(name)
    if options then
      return #options > 1 or (#options > 0 and Properties[name] ~= options[1])
    end
    if name == "Button behavior" then
      return setup
        and (setup.override ~= "Automatic" or setup.linked or setup.config and setup.config.gesture_entity_id ~= nil)
    end
    if name == "App Control Link" then
      return setup and setup:hasAppLinkChoices() and setup:mode() == "Connected Control4 light"
    end
    if name == "Debug Mode" and family == "light" then
      return setup and (setup.linked or setup:usesButtons() or Properties[name] ~= "Off")
    end
    if name == "Last Gesture" or name == "Gesture Count" or name == "Last Sequence" or name == "Debug Mode" then
      return setup and (setup:usesButtons() or Properties["Debug Mode"] == "On")
    end
    return name == "Discovery Catalog Entity ID"
      or name == "Manual entity ID"
      or name == "Driver Version"
      or name == "Log Level"
      or name == "Log Mode"
      or name == "Latency Diagnostics"
  end
  local list, set = properties.list, properties.set
  function properties:list()
    local result = {}
    for _, property in ipairs(list(self)) do
      -- Keep the linked Light selector in the page so it is reachable by Tab
      -- immediately when the new button mode makes it applicable.
      if offered(property.name) or (property.name == "App Control Link" and setup and setup:hasAppLinkChoices()) then
        property.choices = applicableChoices(property.name) or property.choices
        if property.name == "Button behavior" then
          property.choice_labels = setup:buttonBehaviorLabels()
          property.description = nil
        elseif property.name == "App Control Link" then
          local choices, devices = adapter:appLinkChoices()
          local labels, counts = { Automatic = "Automatic (when links match)" }, {}
          for _, value in ipairs(choices) do
            local device = devices[value]
            if device then
              local label = setupPage.friendlyName(C4:GetDeviceDisplayName(device))
                or ("Light on the " .. value .. " link")
              labels[value], counts[label] = label, (counts[label] or 0) + 1
            elseif value ~= "Automatic" then
              labels[value] = "Unavailable " .. value .. " link"
            end
          end
          for value, label in pairs(labels) do
            if (counts[label] or 0) > 1 then
              labels[value] = label .. " · " .. value
            end
          end
          property.choices, property.choice_labels = choices, labels
          property.description = "Choose which linked light or group the app controls."
        elseif property.name == "LED Behavior" then
          property.choice_labels = indicatorBehaviorLabels
          property.description = programs.pagePolicy(setup) == "all" and "Applies to every indicator light." or nil
        end
        result[#result + 1] = property
      end
    end
    if setup then
      local target = setup.config and setup.config.controlled_load
      local peer = setup.consumer.provider
      result[#result + 1] = {
        name = "Coordinator connection",
        readonly = true,
        value = peer and (C4:GetDeviceDisplayName(peer) or "Connected") or "Not connected",
        description = not peer and ("In Composer Connections, connect " .. connectionName .. ".") or nil,
      }
      if target and setup:mode() == "Home Assistant device" then
        local facts = setup.consumer.readiness:view(target.entity_id)
        result[#result + 1] = {
          name = "Device feedback",
          readonly = true,
          value = facts.evidence_ready and not (adapter and adapter.feedbackUnavailable) and "Receiving current state"
            or facts.snapshot and "Device unavailable"
            or facts.subscription and "Waiting for first state"
            or "Waiting for connection",
        }
      end
    end
    if setup and setup.config then
      result[#result + 1] = { name = "Selected device ID", readonly = true, value = setup.config.key }
      if setup.config.controlled_load and setup.config.controlled_load.entity_id ~= setup.config.key then
        result[#result + 1] =
          { name = "Controlled device ID", readonly = true, value = setup.config.controlled_load.entity_id }
      end
    end
    return result
  end
  function properties:set(name, value)
    if not offered(name) then
      return "This setting is unavailable for this device."
    end
    if name == "App Control Link" then
      local choices, devices = adapter:appLinkChoices()
      if choices and (value == "Automatic" or devices[value]) then
        return set(self, name, value)
      end
      return "Choose a light that is still linked."
    end
    local options = applicableChoices(name)
    if options then
      for _, option in ipairs(options) do
        if value == option then
          return set(self, name, value)
        end
      end
      return name == "Button behavior" and "Choose a mode available for this device."
        or "Choose an available indicator setting."
    end
    return set(self, name, value)
  end
  properties:serve()
  local function publish(state)
    if picker then
      picker:render()
    end
    local mode = setup:mode()
    local connected = mode == "Connected Control4 light" and adapter and adapter.targetState and adapter:targetState()
    local selected, target = setupPage.basicNames(setup.config, mode, setup.loadName, connected and connected.name)
    UpdateProperty("Selected Device", selected)
    SetPropertyVisible("Selected Device", true)
    UpdateProperty("Controls", target or "")
    SetPropertyVisible("Controls", target ~= nil)
    local legacyButtonMode = family == "light"
      and setup.config
      and setup.config.prototype_picker
      and setup.config.gesture_entity_id ~= nil
      and setup.config.prototype_mode ~= nil
      and setup.override == "Automatic"
    if family == "light" then
      SetPropertyVisible("Operation Mode", legacyButtonMode or false)
      local hasColors = programs.nativeColors(setup)
      for _, name in ipairs({ "LED Indicator", "LED On Color", "LED Off Color" }) do
        SetPropertyVisible(name, hasColors == true)
      end
      local capabilities = table.concat(state.capabilities or {}, ", ")
      UpdateProperty("Device Setup", state.detail)
      local description = mode == "Home Assistant device"
          and setup.config
          and setup.config.prototype_mode == "bridge"
          and "Control the Home Assistant device and use its button presses in Control4."
        or state.detail
      UpdateProperty("Mode Description", description)
      UpdateProperty(
        "Connected Light",
        mode == "Connected Control4 light" and state.target or "No connected Control4 light"
      )
      local stateValue = Variables.State
      local ready = state.status == "Device connected" and (stateValue == "On" or stateValue == "Off")
      UpdateProperty("Status", ready and stateValue or state.status)
      UpdateProperty("Selected Capabilities", capabilities ~= "" and capabilities or "Waiting for device information")
      UpdateProperty("Button Capabilities", setup.gestures.capabilitySummary or "No button presses available")
    end
    UpdateProperty("LED Status", programs.summary(setup))
    if family == "switch" then
      SetPropertyVisible("LED Status", state.indicator_lease ~= nil)
    end
    for _, name in ipairs({
      "Manual entity ID",
      "Driver Version",
      "Log Level",
      "Log Mode",
      "Latency Diagnostics",
      "Last Gesture",
      "Gesture Count",
      "Last Sequence",
      "Debug Mode",
      "Button behavior",
    }) do
      SetPropertyVisible(name, (name ~= "Button behavior" or not legacyButtonMode) and offered(name) or false)
    end
    if family == "light" then
      SetPropertyVisible("App Control Link", offered("App Control Link") or false)
    end
    setup.propertyLists = setup.propertyLists or {}
    setup.updatingIndicatorLists = true
    for _, name in ipairs({ "LED Behavior", "LED Feedback Source", "Button behavior" }) do
      local options = applicableChoices(name)
      if options then
        SetPropertyVisible(name, offered(name) or false)
        local joined = table.concat(options, ",")
        if #options > 0 and setup.propertyLists[name] ~= joined then
          setup.propertyLists[name] = joined
          C4:UpdatePropertyList(name, joined, Properties[name])
        end
      end
    end
    setup.updatingIndicatorLists = false
    if visible then
      -- Setup facts are strings and booleans except the short capability list.
      -- Compare only what is shown. Room/device IDs never decide control here.
      local capabilities = table.concat(state.capabilities or {}, ", ")
      local changed = previousCapabilities ~= capabilities
      for _, field in ipairs({
        "title",
        "status",
        "detail",
        "target",
        "selected_id",
        "separate_target",
        "operation",
        "manual_status",
        "manual_failed",
        "rejected_manual",
        "helper",
        "retry",
        "feedback_retry",
        "can_browse",
        "indicator_hint",
        "indicator_lease",
        "indicator_policy",
        "indicator_following",
        "indicator_signature",
        "button_behavior_summary",
        "linked_settings_help",
        "app_link_available",
        "migration_available",
      }) do
        if not previous or previous[field] ~= state[field] then
          changed = true
          break
        end
      end
      previous, previousCapabilities = state, capabilities
      if changed then
        local response = CopyTable(state)
        response.indicator_signature = nil
        response.buttons_ready = nil
        page.send("HA_SETUP_STATE", response)
      end
    end
  end
  local register = setupPage.commands(function()
    return setup
  end)
  require("ha.switch-migration").install(register, family, function()
    return setup
  end)
  register("HA_SETUP_GET", "HA_SETUP_STATE", function(owner, _, done)
    visible = true
    local state = owner:view()
    state.indicator_signature = nil
    state.buttons_ready = nil
    done(state)
  end)
  register("HA_SETUP_BROWSE", "HA_SETUP_PAGE", function(owner, params, done)
    owner:browse(params, done)
  end)
  register("HA_SETUP_CHOOSE", "HA_SETUP_RESULT", function(owner, params, done)
    owner:choose(params, done)
  end)
  register("HA_SETUP_RETRY", "HA_SETUP_RESULT", function(owner, params, done)
    local state = owner:view()
    if params.feedback == true then
      if state.feedback_retry then
        owner:refreshFeedback(done)
      else
        done({ error = "Device status changed. Check its current status before retrying." })
      end
      return
    end
    if not state.retry or state.feedback_retry then
      done({ error = "Open the device list to choose a device." })
      return
    end
    if owner.config and owner.config.manual_event and not owner.pending then
      owner.error = nil
      owner:render()
      if owner.consumer:refreshSelected() then
        done({ message = "Checking the saved Home Assistant device." })
      else
        owner.error = "saved_device_unverified"
        owner:render()
        done({ error = Setup.explain("unbound") })
      end
      return
    end
    owner:choose(owner.pending, done)
  end)
  register("HA_SETUP_INDICATOR", "HA_SETUP_RESULT", function(owner, params, done)
    owner:changeIndicator(params, done)
  end)
  register("HA_SETUP_ACTION", "HA_SETUP_RESULT", function(_, params, done)
    if params.action == "timing_report" then
      done({ report = codec.encode(metrics:report()) })
    elseif params.action == "timing_reset" then
      EC.ResetTiming()
      done({})
    else
      done({ error = "This action is unavailable." })
    end
  end)
  OPC.Manual_entity_ID = function()
    if setup then
      setup:propertyChanged()
    end
  end
  EC.PrintDiagnostics = function()
    if setup then
      print(
        "Home Assistant device | "
          .. (Properties["Driver Status"] or "Unknown")
          .. " | Button events: "
          .. tostring(setup.gestureCount)
          .. " | Last sequence: "
          .. tostring(setup.gestures.sequence)
      )
      local result = Variables["Last Command Result"]
      if type(result) == "string" and result ~= "" then
        print("Last command result | " .. result)
      end
    end
  end
  OPC.Debug_Mode = function()
    if family == "light" and adapter then
      adapter:setLinkedTrace(Properties["Debug Mode"] == "Trace")
    end
    if setup then
      setup.debugLines = 0
      setup:render()
    end
  end
  OPC.Button_behavior = OPC.Manual_entity_ID
  -- A mixed project can leave these receivers on the original broadcast
  -- wire. Ignore both BP payloads before the general handler can debug-log
  -- their parameters. The capability reply lets the Coordinator verify this
  -- behavior even on a fresh, unconfigured driver.
  local coordinatorInput = family == "light" and ids.lightCoordinatorBinding or ids.coordinatorBinding
  RFP.suppressDebug[coordinatorInput] = RFP.suppressDebug[coordinatorInput] or {}
  for _, command in ipairs({ "RECEIEVE_STATE", "RECEIEVE_EVENT" }) do
    RFP.suppressDebug[coordinatorInput][command] = true
    RFP[command] = function() end
  end
  UIR.HA_LEGACY_WIRE = function()
    return "<legacy_wire>ignore-v1</legacy_wire>"
  end
  UIR.suppressDebug.HA_SELECTION_IDENTITY = true
  UIR.HA_SELECTION_IDENTITY = function()
    return migrationSelection.encode(setup)
  end
  EC.suppressDebug.HA_SUITE_V1 = true
  EC.HA_SUITE_V1 = function(params)
    if setup then
      pcall(setup.consumer.receive, setup.consumer, params.PAYLOAD)
    end
  end
  local function bindingChanged(id)
    if setup then
      setup:bindingsChanged(id)
      if visible and family == "light" and id ~= ids.coordinatorBinding and id ~= ids.lightCoordinatorBinding then
        UIR._GET_PROPERTIES()
      end
    end
  end
  OBC[ids.coordinatorBinding] = bindingChanged
  if family == "light" then
    OPC.Operation_Mode = function(label)
      if setup then
        setup:originalModeChanged(label)
      end
    end
    OPC.Entity_ID = function()
      if setup then
        setup:propertyChanged(true)
      end
    end
    OBC[ids.lightCoordinatorBinding] = bindingChanged
    OPC.App_Control_Link = function()
      bindingChanged(ids.targetLinks.app)
    end
    for _, id in pairs(ids.targetLinks) do
      OBC[id] = bindingChanged
    end
  end
  local function retireOwner()
    local owner = setup
    setup, visible, previous = nil, false, nil
    if picker then
      picker:reset()
    end
    if owner then
      owner:destroy()
    end
  end
  function OnDriverDestroyed()
    foundation.destroy()
    retireOwner()
    if adapter then
      adapter:destroy()
    end
    adapter = nil
  end
  function OnDriverInit()
    retireOwner()
    if not adapter and makeAdapter then
      adapter = makeAdapter()
    end
    foundation.init(family)
  end
  function OnDriverLateInit()
    retireOwner()
    if foundation.lateInit() then
      events:restoreEvents()
      setup = Setup.new(family, publish, adapter)
      if adapter then
        if family == "light" then
          adapter:setLinkedTrace(Properties["Debug Mode"] == "Trace")
        end
        adapter:start()
      end
      setup:start()
    end
  end
end
return M

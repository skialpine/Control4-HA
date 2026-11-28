-- Shared UI message correlation and user-facing picker projection.
local page = require("lib.ui.page")
local pageParams = require("lib.ui.page-params")
local choices = require("ha.choices")
local contract = require("ha.contract")
local M = {}

function M.friendlyName(value)
  if type(value) ~= "string" or #value > 1024 then
    return nil
  end
  local name = value:match("^%s*(.-)%s*$")
  if
    name == ""
    or name:find("%c")
    or name:match("^[%l_]+%.[%l%d_]+$")
    or name:match("^device:")
    or (#name == 32 and name:match("^%x+$"))
  then
    return nil
  end
  return name
end

function M.basicNames(config, mode, loadName, connectedName)
  local selected, target = "Not selected", nil
  if config then
    local ownLoad = config.controlled_load and config.key == config.controlled_load.entity_id
    selected = M.friendlyName(config.name)
      or (ownLoad and M.friendlyName(loadName))
      or (config.manual and "Manually selected device" or "Home Assistant device")
    if mode == "Home Assistant device" and config.controlled_load and not ownLoad then
      target = M.friendlyName(loadName) or M.friendlyName(config.controlled_load.name)
    end
  end
  if mode == "Connected Control4 light" then
    target = M.friendlyName(connectedName)
  end
  -- A paddle and the separate light it controls can share a display name.
  local separate = mode == "Connected Control4 light" or (config and config.controlled_load_origin == "explicit_link")
  return selected, target and (separate or selected:lower() ~= target:lower()) and target or nil
end

local explanations = {
  saved_selection_unreadable = "This driver could not read its saved device selection. Choose the device again in Device Setup.",
  saved_device_unverified = "Choose the device again in Device Setup. Home Assistant could not confirm the saved selection.",
  permission_denied = "Home Assistant denied access. Check the account used by the Home Assistant Connection.",
  revision_changed = "The device list changed. Open the list again and choose your device.",
  catalog_unverified = "Open the device list again to get the current choices.",
  unsupported_endpoint = "This device is no longer available for this driver. Choose another device.",
  unsupported_preparation_version = "Update the driver and HA Gesture Bridge to compatible versions, then try again.",
  unsupported_catalog_version = "Update the driver and HA Gesture Bridge to compatible versions, then reopen the list.",
  not_found = "HA Gesture Bridge could not find the device or its setup service. Check it in Home Assistant.",
  unavailable = "The new device is unavailable. Check it in Home Assistant, then try again.",
  invalid_manual = "Enter a Home Assistant entity ID supported by this driver, or choose a device by name.",
  missing_load = "This device has no light or switch to control. Choose another device or check its settings in Home Assistant.",
  no_buttons = "This device has no buttons. Choose a device with buttons, or change Button behavior in Device Setup.",
  timeout = "Home Assistant took too long to respond. Check its connection and try again.",
  disconnected = "Check the Home Assistant connection, then try again.",
  unbound = "Connect this driver to the Home Assistant Connection.",
  busy = "The Coordinator is handling other requests. Try again in a moment.",
  retired = "Setup changed. Reopen the list to choose a device.",
  indicator_unavailable = "This indicator or setting is no longer available. Check the device and try again.",
  indicator_rejected = "Home Assistant rejected this indicator setting. Check its current settings before trying again.",
  connected_release_failed = "The driver could not send the button release. Check the linked light and its button connection in Composer.",
}
function M.explain(kind)
  return explanations[kind] or "Device setup could not finish. Check the device in Home Assistant and try again."
end

local manualExplanations = {
  unsupported_endpoint = "This device does not match the driver type. Enter a compatible Home Assistant entity ID to retry.",
  not_found = "Home Assistant could not find that entity. Enter the entity ID again to retry.",
  unavailable = "This entity is unavailable. Check it in Home Assistant, then enter the entity ID again.",
  timeout = "Home Assistant took too long to respond. Check its connection, then enter the entity ID again.",
  unbound = "Connect this driver to the Home Assistant Connection, then enter the entity ID again.",
}
function M.explainManual(kind)
  return manualExplanations[kind] or M.explain(kind)
end

function M.commands(current)
  local function register(command, answer, handler)
    UIR.suppressDebug[command] = true
    UIR[command] = function(raw)
      local params = pageParams(raw)
      if type(params.request) ~= "string" or #params.request < 1 or #params.request > 96 then
        return
      end
      local owner = current()
      local function done(response)
        if owner ~= current() then
          return
        end
        response.request = params.request
        page.send(answer, response)
      end
      if not owner then
        done({ error = "Setup is unavailable. Check Driver Status and Next step in Properties, then try again." })
        return
      end
      handler(owner, params, done)
    end
  end
  return register
end
function M.choices(page, includeFamilies, nativePicker)
  local result = {}
  for _, row in ipairs(page.entities) do
    local choice = row.attributes.device_choice
    local load = choice and choice.source_load
    local description = choice
      and ({ remote = "Button device", dimmer = "Dimmable light", switch = "On and off" })[choice.kind]
    local entityIDs
    if not nativePicker then
      entityIDs = {}
      local seen = { [row.entity_id] = true }
      local function addId(id)
        if contract.entity(id) and not seen[id] then
          seen[id] = true
          entityIDs[#entityIDs + 1] = id
        end
      end
      addId(row.source_entity_id or (type(load) == "table" and load.entity_id))
      addId(choice and choice.gesture_entity_id)
      for _, alias in ipairs(row.entity_aliases or {}) do
        addId(alias)
      end
    end
    local native
    if nativePicker then
      local dims = require("ha.light-capabilities").fromModes(row.attributes.supported_color_modes)
      native = {
        kind = choice and choice.kind or (dims and "dimmer" or "switch"),
        gestures = choice
          and (
            choice.kind == "remote"
            or choice.gesture_entity_id ~= nil
            or choice.gestures ~= nil and choice.gestures ~= "absent"
          ),
        load = choice and type(load) == "table" and load.entity_id or row.source_entity_id,
        event = choice and choice.gesture_entity_id,
      }
    end
    result[#result + 1] = {
      native = native,
      families = includeFamilies and row.families or nil,
      family = includeFamilies and choices.suggestedFamily(row) or nil,
      id = row.entity_id,
      entity_ids = entityIDs and #entityIDs > 0 and entityIDs or nil,
      name = row.picker_name or choice and choice.name or row.name,
      area = row.picker_area or choice and choice.area or (type(row.area_name) == "string" and row.area_name or nil),
      target = not includeFamilies
          and type(load) == "table"
          and type(load.name) == "string"
          and load.name ~= ""
          and load.name
        or nil,
      description = description or (row.is_group and "Group" or nil),
    }
  end
  return {
    choices = result,
    cursor = page.cursor,
    total = page.total,
    revision = page.revision,
    next_cursor = type(page.next_cursor) == "number" and page.next_cursor or nil,
    helper = page.source == "companion",
    catalogWarning = page.names_unavailable or nil,
  }
end
return M

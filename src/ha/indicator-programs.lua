-- Saved Composer programming keys and palette handling from the Light/Switch
-- prototype. The selected consumer owns every hardware write.
local indicators = require("ha.indicators")
local codec = require("ha.codec")
local ids = require("ha.identities")
local metrics = require("ha.performance").shared
local values = require("lib.values")
local M = {}

local roles = { top = "Top", bottom = "Bottom", toggle = "Toggle" }
local order = { top = 1, bottom = 2, toggle = 3 }
local native = { top = 0, bottom = 1, toggle = 2 }
local behaviorOrder = { "follow_load", "follow_load_inverted", "always_on", "always_off" }
local behaviors = {
  follow_load = "Follow Load",
  follow_load_inverted = "Follow Load (Inverted)",
  always_on = "Always On",
  always_off = "Always Off",
}
local fields = {
  Set_LED_Current_Color = "color",
  Set_All_LED_Colors = "all",
  Set_LED_Behavior = "behavior",
  Set_LED_Brightness = "brightness",
  Set_LED_On_Color = "ON_COLOR",
  Set_LED_Off_Color = "OFF_COLOR",
}

local function nearest(row, value)
  if type(value) ~= "string" or not value:match("^%x%x%x%x%x%x$") then
    return nil
  end
  local best, distance
  value = value:upper()
  for _, candidate in ipairs(row.palette) do
    if candidate == value then
      return value
    end
    if candidate ~= "000000" and value ~= "000000" then
      local sum = 0
      for pos = 1, 5, 2 do
        local delta = tonumber(candidate:sub(pos, pos + 1), 16) - tonumber(value:sub(pos, pos + 1), 16)
        sum = sum + delta * delta
      end
      if not distance or sum < distance then
        best, distance = candidate, sum
      end
    end
  end
  return best
end

local function label(row)
  return roles[row.role] or (row.label .. " [" .. row.id .. "]")
end

local function has(row, option)
  for _, behavior in ipairs(row.behaviors or {}) do
    if behavior == option then
      return true
    end
  end
  return false
end

local function canTrack(row)
  return #row.palette > 0 and has(row, "always_on") and has(row, "always_off")
end

local function choices(rows, field, parameter)
  local names = {}
  if field == "behavior" and parameter == "Behavior" then
    local supported = {}
    for _, row in ipairs(rows) do
      for _, behavior in ipairs(row.behaviors or {}) do
        supported[behavior] = true
      end
    end
    for _, behavior in ipairs(behaviorOrder) do
      if supported[behavior] then
        names[#names + 1] = behaviors[behavior]
      end
    end
  elseif parameter == "Button" then
    table.sort(rows, function(a, b)
      local ar, br = order[a.role] or 4, order[b.role] or 4
      return ar < br or (ar == br and label(a) < label(b))
    end)
    for _, row in ipairs(rows) do
      if
        (field ~= "brightness" or row.brightness_supported)
        and (field ~= "color" or row.colors and #row.colors > 0)
        and (field ~= "behavior" or row.behaviors and #row.behaviors > 0)
        and ((field ~= "ON_COLOR" and field ~= "OFF_COLOR") or canTrack(row))
      then
        names[#names + 1] = label(row)
      end
    end
  end
  return names
end

local function matches(row, button)
  if button == nil then
    return false
  end
  return button == row.role
    or button == roles[row.role]
    or (native[row.role] ~= nil and tostring(button) == tostring(native[row.role]))
    or (type(button) == "string" and row.id == button:match(" %[(%l[%l%d_]*)%]$"))
end

local function trackingColor(row, preferences, on)
  local color = preferences[on and "ON_COLOR" or "OFF_COLOR"]
  return nearest(row, color or (on and "FFFFFF" or "000000"))
end

local function preferences(owner, row)
  local store = type(PersistData) == "table" and PersistData.LEDColors
  local channels = type(store) == "table" and store[owner.config.control_id]
  local saved = type(channels) == "table" and channels[row.id]
  return type(saved) == "table" and saved or {}
end

local function save(owner, row, field, value)
  -- Retain the original per-control/per-indicator layout on an in-place update.
  PersistData = PersistData or {}
  if type(PersistData) ~= "table" then
    return false
  end
  PersistData.LEDColors = PersistData.LEDColors or {}
  local store, key = PersistData.LEDColors, owner.config.control_id
  if type(store) ~= "table" then
    return false
  end
  store[key] = store[key] or {}
  if type(store[key]) ~= "table" then
    return false
  end
  local saved = store[key][row.id] or {}
  if type(saved) ~= "table" then
    return false
  end
  local on = (field == "all" or field == "ON_COLOR") and value or trackingColor(row, saved, true)
  local off = (field == "all" or field == "OFF_COLOR") and value or trackingColor(row, saved, false)
  store[key][row.id] = { ON_COLOR = on, OFF_COLOR = off }
  owner.trackingRows, owner.nativeColorRows = nil, nil
  if native[row.role] ~= nil then
    SendToProxy(
      ids.proxy,
      "BUTTON_INFO",
      { BUTTON_ID = native[row.role], ON_COLOR = on, OFF_COLOR = off, CURRENT_COLOR = row.confirmed_color },
      "NOTIFY"
    )
  end
  return true
end

-- A service reply can arrive before the corresponding device feedback.
-- Preserve a newer opposing command even when it matches the old snapshot.
local function sendChange(owner, lease, plan, active)
  if not plan.write then
    return true
  end
  if owner.programWriteLease ~= lease then
    owner.programWriteLease = lease
    owner.programWrites = {}
  end
  local key = plan.row.id .. ":" .. plan.write
  local writes = owner.programWrites
  local last = writes[key]
  local confirmed = plan.row[plan.write] == plan.value
  if plan.write == "tracking_color" then
    confirmed = plan.row.confirmed_color == plan.value
      and plan.row.behavior == (plan.value == "000000" and "always_off" or "always_on")
  end
  if not confirmed or last and (last.value ~= plan.value or last.pending) then
    if not active() then
      return false
    end
    local write = { value = plan.value, pending = true }
    writes[key] = write
    local accepted = true
    local function finish(err)
      write.pending = false
      if err then
        accepted = false
        if owner:indicatorLease() == lease and owner.consumer:_current() then
          values:update(
            "Last Command Result",
            owner.explain(err.kind == "rejected" and "indicator_rejected" or err.kind),
            "STRING"
          )
        end
      end
    end
    owner:sendIndicator(plan.row.id, plan.write, plan.value):next(function()
      finish()
    end, finish)
    if not accepted then
      return false
    end
  end
  return true
end

local function run(owner, lease, rows, field, params, stillLinked)
  local function active()
    return owner:indicatorLease() == lease and owner.consumer:_current() and (not stillLinked or stillLinked())
  end
  local plans = {}
  for _, row in ipairs(rows) do
    if
      field == "all"
      or field == "tracking_color"
      or field == "all_behavior"
      or matches(row, params.Button or params.BUTTON_ID or params.NUMBER or params.Number)
    then
      local value, write
      if field == "tracking_color" then
        value, write = trackingColor(row, preferences(owner, row), params.state), field
      elseif field == "brightness" then
        value, write = indicators.programmedBrightness(row, tonumber(params.Brightness)), field
      elseif field == "behavior" or field == "all_behavior" then
        for id, name in pairs(behaviors) do
          if name == params.Behavior then
            value = id
          end
        end
        write = "behavior"
      elseif field == "ON_COLOR" or field == "OFF_COLOR" then
        value = canTrack(row) and nearest(row, params.Color) or nil
      else
        value = nearest(row, params.Color)
        if field == "all" or field == "color" then
          write = "color"
        end
      end
      if value == nil or (write and not indicators.allowed(owner.indicatorMeta, row.id, write, value)) then
        return false
      end
      plans[#plans + 1] = { row = row, value = value, write = write }
    end
  end
  table.sort(plans, function(a, b)
    return a.row.id < b.row.id
  end)
  for _, plan in ipairs(plans) do
    if not active() then
      return false
    end
    if owner.family == "light" and (not plan.write or field == "all") then
      if not save(owner, plan.row, field, plan.value) then
        return false
      end
    end
    if not sendChange(owner, lease, plan, active) then
      return false
    end
  end
  return #plans > 0
end

local function bound(owner, role)
  local target = owner and owner.adapter and owner.adapter.connected
  return target and role and target:feedbackLink(role)
end

function M.policyChoices(owner)
  if not owner or not owner:indicatorLease() then
    return {}
  end
  -- The page can render on every gesture. Reuse the capability projection
  -- until a snapshot or metadata update replaces it.
  local connected = owner.family == "light" and owner:mode() == "Connected Control4 light"
  if owner.policyRows == owner.indicatorRows and owner.policyConnected == connected and owner.policyChoices then
    return owner.policyChoices
  end
  local rows = indicators.programmingRows(owner.indicatorMeta)
  local names = { "Use Device Setting" }
  local common = {}
  for _, behavior in ipairs(behaviorOrder) do
    local supported = #rows > 0
    for _, row in ipairs(rows) do
      supported = supported and has(row, behavior)
    end
    if supported then
      names[#names + 1] = behaviors[behavior]
      common[behavior] = true
    end
  end
  if connected and common.always_on and common.always_off then
    names[#names + 1] = "Follow Bound Device"
  end
  owner.policyRows, owner.policyConnected, owner.policyChoices = owner.indicatorRows, connected, names
  return names
end

function M.following(owner)
  if Properties["LED Behavior"] ~= "Follow Bound Device" then
    return false
  end
  local options = M.policyChoices(owner)
  return options[#options] == "Follow Bound Device"
end

function M.pagePolicy(owner)
  local count = owner and owner.indicatorRows and #owner.indicatorRows or 0
  if count > 1 then
    return "all"
  end
  if count == 1 then
    local options = M.policyChoices(owner)
    if options[#options] == "Follow Bound Device" then
      return "single"
    end
  end
end

function M.sourceChoices(owner)
  if not M.following(owner) then
    return {}
  end
  local names = { "Disabled" }
  for _, role in ipairs({ "top", "bottom", "toggle" }) do
    if owner.adapter.connected.links[role] then
      names[#names + 1] = roles[role]
    end
  end
  return names
end

-- The immediate color and the colors used for bound-light feedback serve
-- different roles. Only the first sends a command to the hardware.
function M.summary(owner)
  if not owner.indicatorRows then
    return "No indicator lights available"
  end
  if owner.summaryRows == owner.indicatorRows then
    return owner.indicatorSummary
  end
  local summary = {}
  for _, row in ipairs(owner.indicatorRows) do
    local features = {}
    if row.colors and #row.colors > 0 then
      features[#features + 1] = "Color"
    end
    if row.brightness_supported then
      features[#features + 1] = "Brightness"
    end
    if behaviors[row.behavior] then
      features[#features + 1] = behaviors[row.behavior]
    end
    summary[#summary + 1] = row.label .. (#features > 0 and " (" .. table.concat(features, ", ") .. ")" or "")
  end
  owner.summaryRows = owner.indicatorRows
  owner.indicatorSummary = #summary > 0 and table.concat(summary, ". ") or "No indicator lights available"
  return owner.indicatorSummary
end

function M.pageRows(owner)
  if
    owner.family ~= "light"
    or not M.following(owner)
    or not bound(owner, (Properties["LED Feedback Source"] or ""):lower())
  then
    return owner.indicatorRows, owner.indicatorSignature
  end
  if owner.trackingSource == owner.indicatorRows and owner.trackingRows then
    return owner.trackingRows, owner.trackingSignature
  end
  local rows = indicators.programmingRows(owner.indicatorMeta)
  for _, row in ipairs(rows) do
    local palette = {}
    for _, color in ipairs(row.palette) do
      if indicators.allowed(owner.indicatorMeta, row.id, "tracking_color", color) then
        palette[#palette + 1] = color
      end
    end
    row.tracking_colors = palette
    row.on_color = trackingColor(row, preferences(owner, row), true)
    row.off_color = trackingColor(row, preferences(owner, row), false)
  end
  owner.trackingSource, owner.trackingRows = owner.indicatorRows, rows
  owner.trackingSignature = codec.encode(rows)
  return rows, owner.trackingSignature
end

function M.savePageColor(owner, params)
  if not owner.consumer:_current() or owner:indicatorLease() ~= params.lease or not owner:indicatorLease() then
    return false
  end
  local rows = M.pageRows(owner)
  for _, row in ipairs(rows or {}) do
    if row.id == params.id and row.tracking_colors then
      for _, color in ipairs(row.tracking_colors) do
        if color == params.value then
          return save(owner, row, params.field == "on_color" and "ON_COLOR" or "OFF_COLOR", color)
        end
      end
    end
  end
  return false
end

local function rgb(value)
  if value then
    return string.format(
      "%d,%d,%d",
      tonumber(value:sub(1, 2), 16),
      tonumber(value:sub(3, 4), 16),
      tonumber(value:sub(5, 6), 16)
    )
  end
end

function M.nativeColors(owner)
  if not owner:indicatorLease() then
    return
  end
  if
    owner.nativeColorSelection
    and owner.nativeColorRows == owner.indicatorRows
    and owner.nativeColorSelection == Properties["LED Indicator"]
  then
    return true
  end
  local rows = indicators.programmingRows(owner.indicatorMeta)
  local names = choices(rows, "ON_COLOR", "Button")
  if #names == 0 then
    return
  end
  local selected = Properties["LED Indicator"]
  local found
  for _, row in ipairs(rows) do
    if matches(row, selected) and canTrack(row) then
      found = row
    end
  end
  if not found then
    for _, row in ipairs(rows) do
      if label(row) == names[1] then
        found = row
        break
      end
    end
  end
  if not found then
    return
  end
  local current = label(found):gsub(",", " ")
  for i, name in ipairs(names) do
    names[i] = name:gsub(",", " ")
  end
  owner.nativeColorRows, owner.nativeColorSelection = owner.indicatorRows, current
  owner.updatingNativeColors = true
  local list = table.concat(names, ",")
  if owner.nativeColorList ~= list or Properties["LED Indicator"] ~= current then
    C4:UpdatePropertyList("LED Indicator", list, current)
    owner.nativeColorList = list
  end
  for field, on in pairs({ ["LED On Color"] = true, ["LED Off Color"] = false }) do
    local value = rgb(trackingColor(found, preferences(owner, found), on))
    if value then
      UpdateProperty(field, value)
    end
  end
  owner.updatingNativeColors = false
  return true
end

local function feedback(owner, binding, raw)
  if not M.following(owner) or not owner.consumer:_current() or (owner.indicatorPending or {}).replaceFollow then
    return false
  end
  local role = (Properties["LED Feedback Source"] or ""):lower()
  local link = bound(owner, role)
  if not link or (binding and link.binding ~= binding) then
    return false
  end
  if not binding then
    SendToProxy(link.binding, "REQUEST_BUTTON_COLORS", {}, "COMMAND")
    return true
  end
  if type(raw) == "string" then
    raw = raw:match("^%s*(.-)%s*$"):lower()
  end
  local flags = {
    [true] = true,
    [false] = false,
    [1] = true,
    [0] = false,
    ["1"] = true,
    ["0"] = false,
    ["true"] = true,
    ["false"] = false,
  }
  local state = flags[raw]
  if state == nil then
    return false
  end
  local lease = owner:indicatorLease()
  return run(
    owner,
    lease,
    indicators.programmingRows(owner.indicatorMeta),
    "tracking_color",
    { state = state },
    function()
      return Properties["LED Behavior"] == "Follow Bound Device"
        and Properties["LED Feedback Source"] == roles[role]
        and bound(owner, role) == link
    end
  )
end

local function policyChanged(owner)
  if not owner then
    return false
  end
  if M.following(owner) then
    local names = M.sourceChoices(owner)
    if Properties["LED Feedback Source"] == "Disabled" then
      local target, candidate
      for index = 2, #names do
        local link = bound(owner, names[index]:lower())
        if not link or target and target ~= link.device then
          candidate = nil
          break
        end
        target, candidate = link.device, candidate or names[index]
      end
      if candidate then
        UpdateProperty("LED Feedback Source", candidate)
      end
    end
    owner:render()
    return feedback(owner)
  end
  owner:render()
  local name = Properties["LED Behavior"]
  if name == "Use Device Setting" then
    return true
  end
  local lease = owner:indicatorLease()
  return lease
      and owner.consumer:_current()
      and run(owner, lease, indicators.programmingRows(owner.indicatorMeta), "all_behavior", { Behavior = name })
    or false
end

function M.install(family, current)
  OPC.LED_Behavior = function()
    local owner = current()
    if owner and not owner.updatingIndicatorLists then
      return policyChanged(owner)
    end
  end
  if family == "light" then
    OPC.LED_Indicator = function()
      local owner = current()
      if owner and not owner.updatingNativeColors then
        M.nativeColors(owner)
      end
    end
    for _, state in ipairs({ "On", "Off" }) do
      OPC["LED_" .. state .. "_Color"] = function(value)
        local owner = current()
        if not owner or owner.updatingNativeColors or not owner:indicatorLease() then
          return
        end
        local r, g, b = tostring(value):match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and r <= 255 and g <= 255 and b <= 255 then
          EC["Set_LED_" .. state .. "_Color"]({
            Button = owner.nativeColorSelection,
            Color = string.format("%02X%02X%02X", r, g, b),
          })
        end
        owner.nativeColorRows = nil
        M.nativeColors(owner)
      end
    end
    OPC.LED_Feedback_Source = function()
      local owner = current()
      if not owner or owner.updatingIndicatorLists then
        return false
      end
      owner:render()
      return feedback(owner)
    end
    EC.RefreshLEDFeedback = function()
      local owner = current()
      local ok = feedback(owner)
      if owner and not ok then
        values:update(
          "Last Command Result",
          "In Device Setup, choose Follow the linked light and select the paddle connected to it.",
          "STRING"
        )
      end
      return ok
    end
    for _, role in ipairs({ "top", "bottom", "toggle" }) do
      local id = ids.targetLinks[role]
      RFP[id] = function(binding, command, params)
        if command == "MATCH_LED_STATE" then
          return feedback(current(), binding, params.STATE)
        end
        return false
      end
    end
  end
  for command, field in pairs(fields) do
    if family == "light" or (field ~= "ON_COLOR" and field ~= "OFF_COLOR") then
      EC[command] = function(params)
        local owner = current()
        local lease = owner and owner:indicatorLease()
        if not lease or not owner.consumer:_current() then
          return false
        end
        local span = metrics:start("led.programming")
        local ok = run(owner, lease, indicators.programmingRows(owner.indicatorMeta), field, params)
        if ok and (field == "ON_COLOR" or field == "OFF_COLOR" or field == "all") then
          owner:render()
        end
        metrics:finish(span, ok and "ok" or "rejected")
        return ok
      end
      GCPL[command] = function(parameter)
        local owner = current()
        if owner and owner:indicatorLease() and owner.consumer:_current() then
          return choices(indicators.programmingRows(owner.indicatorMeta), field, parameter)
        end
        return {}
      end
    end
  end
end
return M

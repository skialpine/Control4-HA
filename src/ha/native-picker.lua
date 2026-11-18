-- Composer's native Light picker uses the same catalog and verified selection as Device Setup.
local codec = require("ha.codec")
local Picker = {}
Picker.__index = Picker
local manual = "Manual Entity ID"
local filters = {
  switch = "switch",
  switches = "switch",
  dimmer = "dimmer",
  dimmers = "dimmer",
  gesture = "gesture",
  gestures = "gesture",
  ["devices with buttons"] = "gesture",
}

local function send(callback, rows)
  if callback then
    pcall(callback, rows)
  end
end

function Picker:reset()
  self.serial = self.serial + 1
  local waiting = self.waiting
  self.waiting, self.rows, self.revision, self.display, self.visible = nil, {}, nil, nil, nil
  for _, callback in ipairs(waiting or {}) do
    send(callback, false)
  end
end

function Picker:render()
  if not self.visible then
    self.visible = true
    SetPropertyVisible("Entity Selection", true)
    SetPropertyVisible("Discovery Catalog Entity ID", true)
    SetPropertyVisible("Discovery Status", true)
  end
  local owner = self.current()
  local key = owner and owner.config and owner.config.key
  if self.renderedRows == self.rows and self.renderedKey == key then
    return
  end
  self.renderedRows, self.renderedKey = self.rows, key
  local placeholder = key and "Current device (saved)" or manual
  local values, selected = { placeholder }, placeholder
  for _, row in ipairs(self.rows) do
    values[#values + 1] = row.label
    if row.id == key then
      selected = row.label
    end
  end
  if key and selected ~= placeholder then
    values[1] = manual
  end
  local list = table.concat(values, ",")
  if list ~= self.display or selected ~= self.selected then
    self.display, self.selected = list, selected
    self.updating = true
    C4:UpdatePropertyList("Entity Selection", list, selected)
    self.updating = false
  end
end

function Picker:load(done)
  local owner = self.current()
  if not owner then
    send(done, false)
    return
  end
  if self.waiting then
    if done then
      self.waiting[#self.waiting + 1] = done
    end
    return
  end
  local serial, collected = self.serial, {}
  self.waiting = done and { done } or {}
  local function fetch(cursor, revision)
    owner:browse({ cursor = cursor, revision = revision }, function(page)
      if self.current() ~= owner or serial ~= self.serial then
        return
      end
      if not page.error then
        for _, row in ipairs(page.choices) do
          row.label = row.name:gsub("[,%c]", " ") .. " [" .. row.id .. "]"
          collected[#collected + 1] = row
        end
        if page.next_cursor then
          return fetch(page.next_cursor, page.revision)
        end
        table.sort(collected, function(a, b)
          return a.label:lower() < b.label:lower()
        end)
      end
      local waiting = self.waiting
      self.waiting = nil
      self.revision, self.rows = page.revision, page.error and {} or collected
      self:render()
      local status = page.error or tostring(#collected) .. " devices available"
      if page.catalogWarning then
        status = status .. ". Custom device names unavailable. Check the catalog sensor in Properties."
      end
      UpdateProperty("Discovery Status", status)
      if page.error then
        UpdateProperty("Next step", page.error)
      end
      for _, callback in ipairs(waiting) do
        send(callback, not page.error)
      end
    end, true)
  end
  fetch()
end

function Picker:results(search, filter)
  search = tostring(search or ""):lower()
  filter = filters[tostring(filter or ""):lower()]
  local rows = {}
  for _, row in ipairs(self.rows) do
    local facts = row.native
    local text = table.concat({ row.label, row.area or "", facts.load or "", facts.event or "" }, " "):lower()
    if
      (not filter or facts.kind == filter or filter == "gesture" and facts.gestures)
      and text:find(search, 1, true)
    then
      rows[#rows + 1] = { text = row.label, value = row.id }
    end
  end
  return rows
end

local function identity(raw)
  if type(raw) ~= "string" or #raw > 8192 then
    return nil
  end
  if raw:sub(1, 1) ~= "{" then
    return raw
  end
  local ok, record = pcall(codec.decode, raw)
  if not ok or not codec.isObject(record) or record.version ~= 1 then
    return nil
  end
  if record.type == "device_choice" then
    return record.choice_id
  end
  if record.type == "entity_selection" then
    return record.entity_id
  end
end

function Picker:select(raw)
  local key, owner = identity(raw), self.current()
  if not key or not owner then
    return
  end
  local function apply(ready)
    if not ready or self.current() ~= owner then
      return
    end
    local match, aliases = nil, 0
    for _, row in ipairs(self.rows) do
      if row.id == key then
        match = row
        break
      end
      if row.native.load == key or row.native.event == key then
        aliases = aliases + 1
        match = aliases == 1 and row or nil
      end
    end
    if not match then
      UpdateProperty("Discovery Status", "Refresh the device list and choose the device again.")
      return
    end
    owner:choose({ revision = self.revision, choice_id = match.id }, function(result)
      if result.error and self.current() == owner then
        UpdateProperty("Discovery Status", result.error)
      end
    end)
  end
  if self.revision and not self.waiting then
    apply(true)
  else
    self:load(apply)
  end
end

local M = {}
function M.install(current)
  local self = setmetatable({ current = current, serial = 0, rows = {} }, Picker)
  function BrowseHALightDevices(_, callback, search, filter)
    if type(callback) ~= "function" then
      if not self.revision and not self.waiting then
        self:load()
      end
      return self:results(search, filter)
    end
    self:load(function(ready)
      send(callback, ready and self:results(search, filter) or {})
    end)
  end
  EC.RefreshEntities = function()
    local owner = current()
    if owner and owner.adapter then
      owner.adapter:refresh(true)
      owner.consumer:refreshSelected()
    end
    self:load()
  end
  EC.SelectDevice = function(params)
    self:select(params and params.Device)
  end
  OPC.Entity_Selection = function(value)
    if self.updating or value == self.selected then
      return
    end
    -- Composer applies the edit before this callback. Keep the verified selection
    -- displayed until a successful verification renders its replacement.
    self.updating = true
    UpdateProperty("Entity Selection", self.selected or manual)
    self.updating = false
    if value == manual then
      UpdateProperty("Discovery Status", "Enter the device ID in Manual entity ID, or choose a device from the list.")
      return
    end
    for _, row in ipairs(self.rows) do
      if value == row.label then
        self:select(row.id)
        return
      end
    end
  end
  OPC.Discovery_Catalog_Entity_ID = function()
    self:reset()
    self:load()
  end
  return self
end
return M

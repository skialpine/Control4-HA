-- Shared readiness facts, independent of family state/gesture interpretation.
require("lib.utils")
local Readiness = {}
Readiness.__index = Readiness
function Readiness.new()
  return setmetatable({ entities = {}, binding = false }, Readiness)
end
function Readiness:select(wanted, binding)
  self.entities, self.binding = {}, binding == true
  for entity in pairs(wanted or {}) do
    self.entities[entity] = { preparation = "not_requested" }
  end
end
function Readiness:update(data)
  local row = self.entities[data.entity_id]
  if not row then
    return
  end
  for _, key in ipairs({ "transport", "subscription", "snapshot", "available" }) do
    row[key] = data[key]
  end
  if not data.transport then
    row.input_ready = false
  end
end
function Readiness:state(data)
  local row = self.entities[data.entity_id]
  if row then
    row.snapshot = true
    row.available = data.state ~= "unknown" and data.state ~= "unavailable"
  end
end
function Readiness:prepare(entity, status, detail, inputReady)
  local row = self.entities[entity]
  if row then
    row.preparation, row.preparation_error, row.input_ready = status, detail, inputReady == true
  end
end
function Readiness:view(entity)
  local row = TableDeepCopy(self.entities[entity] or {})
  row.binding = self.binding
  row.evidence_ready = row.binding
    and row.transport == true
    and row.subscription == true
    and row.snapshot == true
    and row.available == true
  return row
end
return Readiness

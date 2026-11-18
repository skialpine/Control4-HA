-- Translate the original Coordinator's saved Composer command into one HA request.
local codec = require("ha.codec")
local contract = require("ha.contract")
local M = {}

local function variable(params, name)
  local selector = params["${" .. name .. "}"]
  local device, id
  if type(selector) == "string" then
    device, id = selector:match("^(%d+),(%d+)$")
  end
  assert(contract.integer(tonumber(device)) and contract.integer(tonumber(id)), "missing selector")
  local value = C4:GetVariable(tonumber(device), tonumber(id))
  assert(type(value) == "string" or type(value) == "number" or type(value) == "boolean", "missing value")
  return tostring(value)
end

local function interpolate(raw, params)
  -- A selected variable in a JSON string is text. Outside a string it must
  -- supply a complete JSON value (e.g. a numeric level or a color array).
  local parts, copied, cursor = {}, 1, 1
  local quoted, escaped = false, false
  while cursor <= #raw do
    local char = raw:sub(cursor, cursor)
    local name = char == "$" and raw:sub(cursor, cursor + 6):match("^%${(VAR[123])%}$")
    if name then
      parts[#parts + 1] = raw:sub(copied, cursor - 1)
      local value = variable(params, name)
      if quoted then
        parts[#parts + 1] = codec.encode(value):sub(2, -2)
      else
        parts[#parts + 1] = codec.encode(codec.decode(value))
      end
      cursor = cursor + 7
      copied = cursor
    else
      if escaped then
        escaped = false
      elseif quoted and char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = not quoted
      end
      cursor = cursor + 1
    end
  end
  parts[#parts + 1] = raw:sub(copied)
  return table.concat(parts)
end

function M.request(params)
  local name = params.Service
  local domain, service
  if type(name) == "string" then
    domain, service = name:match("^([a-z0-9_]+)%.([a-z0-9_]+)$")
  end
  if not service then
    return nil, "Enter the Home Assistant action in Service, for example light.turn_on."
  end
  local data = params.Data or ""
  if type(data) ~= "string" then
    return nil, "Enter Data as a JSON object or leave it blank."
  end
  if data:find("${VAR", 1, true) then
    local ok, result = pcall(interpolate, data, params)
    if not ok then
      return nil, "Check the variables selected for Data and the values they supply."
    end
    data = result
  end
  local ok, decoded = pcall(codec.decode, data:match("^%s*$") and "{}" or data)
  if ok and decoded == "" then
    decoded = codec.object()
  end
  if not ok or not codec.isObject(decoded) then
    return nil, "Enter Data as a JSON object or leave it blank."
  end
  local request = { type = "call_service", domain = domain, service = service, service_data = decoded }
  local entity = params["Entity ID"]
  if entity and entity ~= "" then
    if type(entity) ~= "string" or (entity ~= "all" and not entity:match("^[a-z0-9_]+%.[a-z0-9_]+$")) then
      return nil, "Check Entity ID in the saved action or leave it blank."
    end
    request.target = { entity_id = entity }
  end
  return request
end

return M

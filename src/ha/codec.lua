-- Private JSON semantics over the template's JSON library, not a second parser.
local json = require("JSON"):new({ strictTypes = true, strictParsing = true })
local M = { null = {} }
local objectType = getmetatable(json:newObject())
local arrayType = getmetatable(json:newArray())
function M.object(value)
  return json:newObject(value)
end
function M.array(value)
  return json:newArray(value)
end
function M.isObject(value)
  return type(value) == "table" and getmetatable(value) == objectType
end
function M.isArray(value)
  return type(value) == "table" and getmetatable(value) == arrayType
end
function M.decode(raw)
  return json:decode(raw, nil, { null = M.null })
end
function M.encode(value)
  return json:encode(value, nil, { null = M.null })
end

-- Director can return stored JSON objects as Lua tables after a driver reload.
-- Restore the strict nested JSON types expected by the record-specific validator.
function M.storedObject(raw)
  local function normalize()
    if type(raw) == "table" then
      if M.isArray(raw) or raw == M.null then
        return nil
      end
      for key in pairs(raw) do
        if type(key) ~= "string" then
          return nil
        end
      end
      if next(raw) == nil then
        return M.object({})
      end
      raw = M.encode(raw)
    end
    if type(raw) == "string" then
      return M.decode(raw)
    end
  end
  local ok, record = pcall(normalize)
  return ok and M.isObject(record) and record or nil
end
return M

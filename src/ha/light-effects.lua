-- Navigator Extras uses XML attributes for both display names and command values.
local codec = require("ha.codec")
local M = {}
local entities = { ["&"] = "&amp;", ['"'] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["'"] = "&apos;" }

function M.valid(name)
  return type(name) == "string" and #name > 0 and #name <= 255 and not name:find("%c")
end

local function attribute(text)
  return (text:gsub("[&<>\"']", entities))
end

function M.read(attrs)
  local list = attrs.effect_list
  if not codec.isArray(list) or #list == 0 or #list > 256 then
    return
  end
  local items, allowed = {}, {}
  for _, name in ipairs(list) do
    if M.valid(name) and not allowed[name] then
      allowed[name] = true
      local escaped = attribute(name)
      items[#items + 1] = '<item text="' .. escaped .. '" value="' .. escaped .. '"/>'
    end
  end
  if #items > 0 then
    return {
      allowed = allowed,
      items = table.concat(items),
      value = allowed[attrs.effect] and attribute(attrs.effect) or "Select Effect",
    }
  end
end

function M.publish(proxy, current, previous)
  if not current and not previous then
    return
  end
  if not current or not previous or current.items ~= previous.items then
    local xml = "<extras_setup/>"
    if current then
      xml = '<extras_setup><extra><section label="Effects"><object type="list" id="effect" label="Effect" command="SELECT_LIGHT_EFFECT" value="'
        .. current.value
        .. '"><list maxselections="1" minselections="1">'
        .. current.items
        .. "</list></object></section></extra></extras_setup>"
    end
    C4:SendToProxy(proxy, "EXTRAS_SETUP_CHANGED", { XML = xml }, "NOTIFY")
  end
  if current and (not previous or current.value ~= previous.value or current.items ~= previous.items) then
    local xml = '<extras_state><extra><object id="effect" value="' .. current.value .. '"/></extra></extras_state>'
    C4:SendToProxy(proxy, "EXTRAS_STATE_CHANGED", { XML = xml }, "NOTIFY")
  end
end

return M

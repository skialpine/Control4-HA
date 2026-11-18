-- The prototype sensor's versioned names projection. It can label verified choices only.
local codec = require("ha.codec")
local contract = require("ha.contract")
local M = { default = "sensor.ha_gesture_bridge_catalog" }

function M.sensor(value)
  return contract.catalogSensor(value)
end

local function text(value)
  return type(value) == "string" and value ~= "" and #value <= 4096 and not value:find("%c")
end

function M.parse(state, sensor)
  if not contract.state(state, sensor) then
    return nil
  end
  local attrs = state.attributes
  local pages, total = attrs.catalog_names_pages, attrs.catalog_names_total
  if
    type(attrs.catalog_contract_version) ~= "string"
    or not attrs.catalog_contract_version:match("^1%.%d+$")
    or attrs.catalog_names_version ~= 1
    or attrs.catalog_names_error ~= nil
    or type(attrs.catalog_names_revision) ~= "string"
    or #attrs.catalog_names_revision ~= 64
    or not attrs.catalog_names_revision:match("^%x+$")
    or type(total) ~= "number"
    or total < 0
    or total > 10000
    or total ~= tonumber(state.state)
    or type(pages) ~= "number"
    or pages ~= math.floor(pages)
    or pages < 0
    or pages > math.min(64, total)
  then
    return nil
  end
  local names, seen, count = {}, {}, 0
  for page = 1, pages do
    local records = attrs[string.format("catalog_names_page_%03d", page)]
    if not codec.isArray(records) or #records == 0 then
      return nil
    end
    for _, item in ipairs(records) do
      if
        not codec.isObject(item)
        or not contract.entity(item.entity_id)
        or seen[item.entity_id]
        or item.domain ~= item.entity_id:match("^([^.]+)")
        or not text(item.friendly_name)
        or (item.area_name ~= nil and item.area_name ~= codec.null and not text(item.area_name))
      then
        return nil
      end
      seen[item.entity_id] = true
      names[item.entity_id] =
        { name = item.friendly_name, area = type(item.area_name) == "string" and item.area_name or nil }
      count = count + 1
    end
  end
  if count == total then
    return names
  end
end

function M.apply(page, names)
  local bytes = 512
  for index, original in ipairs(page.entities) do
    local choice = original.attributes.device_choice
    local id = choice and choice.source_load and choice.source_load.entity_id or original.entity_id
    local entry = names[id] or choice and names[choice.gesture_entity_id]
    if entry then
      -- Catalog:read returns shared rows. Allocate only this consumer's presentation.
      local row = codec.object({})
      for k, v in pairs(original) do
        row[k] = v
      end
      row.picker_name, row.picker_area = entry.name, entry.area
      page.entities[index] = row
    end
    bytes = bytes + #codec.encode(page.entities[index])
    if bytes > 16384 then
      -- A valid base row always fits; unusually long custom names may not.
      if index == 1 then
        page.entities[index] = original
        index = 2
      end
      page.next_cursor = page.cursor + index - 1
      while #page.entities >= index do
        table.remove(page.entities)
      end
      if page.next_cursor > page.total then
        page.next_cursor = codec.null
      end
      break
    end
  end
end
return M

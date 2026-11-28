-- Read the relevant ID list once, then project only the exact IDs in each page.
-- Only validated HA entity IDs can enter a follow-up template literal.
local codec = require("ha.codec")
local contract = require("ha.contract")
local families = require("ha.endpoint-families")
-- Leave room for candidates needed to prove aliases, including exported loads.
-- Catalog publication applies the separate 5,000 eligible-row limit.
local M = { pageSize = 128, indexSize = 512, maxCandidates = 10000 }

function M.entity(value, family)
  if family then
    return contract.endpointDomain(value) == families[family].domain
  end
  return contract.loadDomain(value) ~= nil
end

local scope = [=[
{% set ids = (states.light | map(attribute='entity_id') | list +
              states.switch | map(attribute='entity_id') | list +
              states.input_boolean | map(attribute='entity_id') | list) | sort %}
]=]

local projection = [=[
{% set result = namespace(rows=[], size=0) %}
{% set gestures = namespace(by_device={}) %}
{% if not native_endpoint %}
{% for event in states.event %}
{% set entry = config_entry_id(event.entity_id) %}
{% set source = event.attributes.get('bridge_source_device_id') %}
{% if source is string and entry and config_entry_attr(entry, 'domain') == 'ha_gesture_bridge' %}
{% set gesture = event.entity_id if source not in gestures.by_device and event.attributes.get('bridge_load') is none else none %}
{% set gestures.by_device = dict(gestures.by_device, **{source: gesture}) %}
{% endif %}
{% endfor %}
{% endif %}
{% for id in requested %}
{% set item = states[id] %}
{% if item is not none %}
{% set modes = item.attributes.get('supported_color_modes', []) %}
{% set attrs = {'supported_features': item.attributes.get('supported_features', 0)} %}
{% if native_endpoint %}
{% set attrs = dict(attrs, device_class=item.attributes.get('device_class', '')) %}
{% elif modes is iterable and modes is not string and modes is not mapping %}
{% set attrs = dict(attrs, supported_color_modes=modes|list) %}
{% endif %}
{% set owner = config_entry_id(item.entity_id) %}
{% set device = device_id(item.entity_id) %}
{% set policy = namespace(exported=owner and config_entry_attr(owner, 'domain') == 'control4') %}
{% if device %}
{% for identifier in device_attr(device, 'identifiers') | default([], true) %}
{% if identifier[0] == 'control4' %}{% set policy.exported = true %}{% endif %}
{% endfor %}
{% for entry in device_attr(device, 'config_entries') | default([], true) %}
{% if config_entry_attr(entry, 'domain') == 'control4' %}{% set policy.exported = true %}{% endif %}
{% endfor %}
{% endif %}
{% set members = item.attributes.get('entity_id') %}
{% set row = dict(entity_id=item.entity_id, domain=item.domain,
name=item.attributes.get('friendly_name', item.entity_id), device_id=device,
bridge_gesture_entity_id=gestures.by_device.get(device),
available=item.state not in ['unknown', 'unavailable'] if native_endpoint else item.state in ['on', 'off'],
area_name=area_name(item.entity_id), attributes=attrs, c4_exported=policy.exported or false,
device_disabled=device and device_attr(device, 'disabled_by') is not none or false,
is_group=members is iterable and members is not string and members is not mapping and members|list|length > 0) %}
{% set size = row|to_json(ensure_ascii=true)|length + 2 %}
{% if result.size + size > 98304 %}{% break %}{% endif %}
{% set result.rows = result.rows + [row] %}
{% set result.size = result.size + size %}
{% endif %}
{% endfor %}
]=]

function M.template(ids, offset, family)
  local prefix = "{% set native_endpoint = false %}\n"
  local indexScope = scope
  if family then
    assert(contract.endpointFamily(family))
    local domain = families[family].domain
    prefix = "{% set native_endpoint = true %}\n"
    -- Default the absent attribute before looking at any other properties.
    if domain == "cover" then
      local operator = family == "garage" and "==" or "!="
      indexScope = (
        "{%% set result = namespace(ids=[]) %%}{%% for item in states.cover %%}"
        .. "{%% if item.attributes.get('device_class', '') %s 'garage' %%}"
        .. "{%% set result.ids = result.ids + [item.entity_id] %%}{%% endif %%}{%% endfor %%}"
        .. "{%% set ids = result.ids | sort %%}\n"
      ):format(operator)
    else
      indexScope = ("{%% set ids = states.%s | map(attribute='entity_id') | list | sort %%}\n"):format(domain)
    end
  end
  if not ids then
    offset = offset or 0
    assert(type(offset) == "number" and offset >= 0 and offset < M.maxCandidates and offset % M.indexSize == 0)
    return prefix
      .. indexScope
      .. ("{%% set window = ids[%d:%d] if ids|length <= %d else [] %%}\n"):format(
        offset,
        offset + M.indexSize,
        M.maxCandidates
      )
      .. ("{%% set requested = window[:%d] %%}\n"):format(M.pageSize)
      .. projection
      .. "{{ dict(total=ids|length, ids=window, rows=result.rows, revision=window and (ids|join(',')|sha256) or '') | to_json(ensure_ascii=true) }}"
  end
  assert(#ids <= M.pageSize)
  for _, id in ipairs(ids) do
    assert(M.entity(id, family))
  end
  return prefix
    .. "{% set requested = "
    .. codec.encode(codec.array(ids))
    .. " %}\n"
    .. projection
    .. "{{ result.rows | to_json(ensure_ascii=true) }}"
end

return M

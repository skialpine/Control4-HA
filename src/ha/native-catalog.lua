-- Fixed domain/attribute projection; no caller strings become template source.
-- HA renders this read-only snapshot only when a picker explicitly requests it.
return [=[
{% set result = namespace(rows=[]) %}
{% for domain in ['light', 'switch'] %}
{% for item in states[domain] %}
{% set modes = item.attributes.get('supported_color_modes', []) %}
{% set attrs = {'supported_features': item.attributes.get('supported_features', 0)} %}
{% if modes is iterable and modes is not string and modes is not mapping %}
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
{% set result.rows = result.rows + [dict(entity_id=item.entity_id, domain=domain,
name=item.attributes.get('friendly_name', item.entity_id), device_id=device,
area_name=area_name(item.entity_id), attributes=attrs, c4_exported=policy.exported or false,
device_disabled=device and device_attr(device, 'disabled_by') is not none or false,
is_group=members is iterable and members is not string and members is not mapping and members|list|length > 0)] %}
{% endfor %}
{% endfor %}
{{ result.rows | to_json }}
]=]

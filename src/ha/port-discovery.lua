-- Check common Home Assistant ports on the single origin entered by an installer.
local Connection = require("ha.connection")
local M = {}

function M.search(origin, scheme, ca, done)
  local ports = { scheme == "https" and 443 or 80, 8123 }
  local probes, matches = {}, {}
  local remaining = #ports
  local cancelled = false
  for _, port in ipairs(ports) do
    local probe = Connection.new(function(state)
      if cancelled or (state ~= "verified" and state ~= "rejected" and state ~= "unconfigured") then
        return
      end
      if state == "verified" then
        matches[#matches + 1] = port
      end
      remaining = remaining - 1
      if remaining == 0 then
        done(#matches == 1 and matches[1] or nil, #matches)
      end
    end)
    probes[#probes + 1] = probe
    probe:probe(origin .. ":" .. port, ca)
  end
  return function()
    cancelled = true
    for _, probe in ipairs(probes) do
      probe:destroy()
    end
  end
end

return M

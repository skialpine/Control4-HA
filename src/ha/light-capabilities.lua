-- Home Assistant's advertised color modes describe capabilities even while a
-- light is off. The same interpretation drives discovery and selected setup.
local codec = require("ha.codec")
local M = {}
local fullColor = { hs = true, xy = true, rgb = true, rgbw = true, rgbww = true }
function M.fromModes(modes)
  local dims, color, temperature = false, false, false
  for _, mode in ipairs(codec.isArray(modes) and modes or {}) do
    if mode == "color_temp" then
      temperature = true
    elseif fullColor[mode] then
      color = true
    elseif mode == "brightness" or mode == "white" then
      dims = true
    end
  end
  return dims or color or temperature, color, temperature
end
return M

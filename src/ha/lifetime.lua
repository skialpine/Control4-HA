-- Monotonic per-driver lifetimes use the template's durable persistence helper.
local persist = require("lib.persist")
local contract = require("ha.contract")
local M = {}
function M.next(key)
  local previous = persist:get(key, 0)
  assert(previous == 0 or contract.integer(previous), "Invalid HA lifetime; restore saved configuration")
  assert(previous < 2147483646, "HA lifetime exhausted")
  persist:set(key, previous + 1)
  persist:flush(key)
  return previous + 1
end
return M

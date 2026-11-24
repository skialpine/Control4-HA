-- Embedded only in the dedicated lab Coordinator. All reads use a synthetic load.
local codec = require("ha.codec")
local metrics = require("ha.performance").shared
local SnapshotQueue = require("ha.snapshot-queue")
local values = require("lib.values")
local M = {}
local ENTITY = "light.ha_lab_binary_light"

function M.install(current)
  local active
  UIR.suppressDebug.HA_LAB_SNAPSHOT_BURST = true
  UIR.HA_LAB_SNAPSHOT_BURST = function(params)
    local owner = current()
    local count, limit, nonce = tonumber(params.COUNT), tonumber(params.CONCURRENCY), params.NONCE
    if
      not owner
      or not owner.online
      or owner.connection.state ~= "connected"
      or active
      or not metrics.enabled
      or not count
      or count < 1
      or count > 48
      or count % 1 ~= 0
      or not limit
      or limit < 1
      or limit > count
      or limit % 1 ~= 0
      or type(nonce) ~= "string"
      or #nonce ~= 32
      or not nonce:match("^%x+$")
    then
      return "unavailable"
    end
    active = nonce
    metrics:reset()
    local completed, failures, first = 0, 0, nil
    local since = metrics.clock()
    local queue = SnapshotQueue.new(limit)
    for _ = 1, count do
      local queued, ready = metrics:start("snapshot.queue"), metrics:start("snapshot.ready")
      local function finish(ok)
        completed = completed + 1
        if ok then
          first = first or metrics.clock() - since
        else
          failures = failures + 1
        end
        metrics:finish(ready, ok and "ok" or "failed")
        if completed == count then
          active = nil
          local report = metrics:report()
          report.lab_burst = {
            nonce = nonce,
            count = count,
            concurrency = limit,
            failures = failures,
            first_ok_ms = first,
            elapsed_ms = metrics.clock() - since,
          }
          values:update("Latency Report", codec.encode(report), "STRING")
        end
      end
      queue:push(function(release)
        metrics:finish(queued, "ok")
        owner.connection
          :readState(ENTITY)
          :next(function()
            finish(true)
          end, function()
            finish(false)
          end)
          :next(release, release)
      end, function()
        finish(false)
      end)
    end
    return "scheduled"
  end
end

return M

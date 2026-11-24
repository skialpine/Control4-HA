-- Optional lab Coordinator module. Run read-only probes over its real HA connection.
local Catalog = require("ha.catalog")
local Choices = require("ha.choices")
local codec = require("ha.codec")
local metrics = require("ha.performance").shared
local values = require("lib.values")
local M = {}

function M.install(current)
  local running
  EC.LabCatalogBenchmark = function(params)
    local owner = current()
    local count, nonce = tonumber(params and params.COUNT), params and params.NONCE
    if
      running
      or not owner
      or not owner.online
      or not metrics.enabled
      or not count
      or count % 1 ~= 0
      or count < 1
      or count > 10
      or type(nonce) ~= "string"
      or #nonce ~= 32
      or not nonce:match("^%x+$")
    then
      return
    end
    running = true
    local source = owner.catalog
    local requests, projections, registry = 0, 0, 0
    local catalog = Catalog.new(function(message, callback)
      requests = requests + 1
      registry = registry + (message.type == "config/entity_registry/get_entries" and 1 or 0)
      return source.request(message, callback)
    end, function()
      projections = projections + 1
      return source.native()
    end, function(rows, active, native)
      return Choices.enrich(rows, function(message, callback)
        requests, registry = requests + 1, registry + 1
        return source.request(message, callback)
      end, active, native)
    end, source.supplement)
    local samples = codec.array({})
    local function nextSample()
      local before, probes, pages, lookups = metrics.clock(), requests, projections, registry
      catalog:refresh(true):next(function(metadata)
        samples[#samples + 1] = {
          elapsed_ms = metrics.clock() - before,
          total = metadata.total,
          source = metadata.source,
          companion_proof = catalog.snapshot.nativeRevision ~= nil,
          queries = requests - probes,
          projections = projections - pages,
          registry_batches = registry - lookups,
        }
        if #samples < count and current() == owner and owner.online then
          nextSample()
        else
          running = false
          values:update("Latency Report", codec.encode({ nonce = nonce, catalog_benchmark = samples }), "STRING")
        end
      end, function(failure)
        running = false
        values:update(
          "Latency Report",
          codec.encode({ nonce = nonce, catalog_benchmark = samples, failure = failure.kind }),
          "STRING"
        )
      end)
    end
    nextSample()
  end
end

return M

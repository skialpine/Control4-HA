-- Offline Quick Setup scale benchmark. Uses production Lua and the Director shim.
local codec = require("ha.codec")
local Catalog = require("ha.catalog")
local Choices = require("ha.choices")
local Commissioning = require("ha.commissioning")
local Connection = require("ha.connection")
local fixtures = require("c4_fixtures")
local deferred = require("deferred")
local ids = require("ha.identities")
local http = require("lib.http")
local native = require("ha.native-catalog")
local persist = require("lib.persist")
local project = require("ha.commissioning-project")
local selection = require("ha.migration-selection")
local Upgrade = require("ha.switch-upgrade")

local clock = fixtures.virtualClock()
fixtures.captureTcpClient()
local coordinator = C4:GetDeviceID()
local packageInfo, input, class = ids.packages.switch, ids.coordinatorBinding, ids.coordinatorClass
local originalBindings, originalDevices = C4.GetBindingsByDevice, C4.GetDevices
local updates, counts

local function resolved(value)
  local promise = deferred.new()
  promise:resolve(value)
  return promise
end

local function result(promise)
  local report = {}
  promise:next(function(value)
    report.value = value
  end, function(failure)
    report.error = failure.kind
  end)
  return report
end

local function resetCounts()
  counts = { projections = 0, registry_batches = 0, catalog_probes = 0, inventories = 0, peer_reads = 0 }
  return counts
end

local function entity(index)
  return (index % 2 == 0 and "light" or "switch") .. (".benchmark_load_%05d"):format(index)
end

local function displayName(index, width)
  return ("Benchmark load %05d"):format(index) .. (width and string.rep("x", width) or "")
end

function C4:GetDevices(filter)
  if filter and filter.C4iNames and filter.C4iNames:find(packageInfo.file, 1, true) then
    counts.inventories = counts.inventories + 1
  end
  return originalDevices(self, filter)
end

function C4:GetDeviceData(_, tag)
  return tag == "model" and packageInfo.model or nil
end

function C4:GetDeviceVariables(id)
  return { { name = "Selected Endpoint", value = updates[id] or "", type = "STRING" } }
end

function C4:GetBindingsByDevice(id)
  if id == coordinator then
    return originalBindings(self, id)
  end
  local provider = self:GetBoundProviderDevice(id, input)
  local binding = { bindingid = input, provider = false, bindingclasses = { { class = class } } }
  if provider ~= 0 then
    binding.boundprovider = { bound = { deviceid = provider, bindingid = input, boundclasses = { class } } }
    binding.isbound = true
  end
  return { bindings = { binding } }
end

local function fixture(rowCount, peerCount, width, companion)
  resetCounts()
  updates = {}
  local rows, registry = codec.array({}), codec.object({})
  for index = 1, rowCount do
    local id = entity(index)
    local domain = id:match("^[^.]+")
    rows[index] = {
      entity_id = id,
      domain = domain,
      name = displayName(index, width),
      device_id = ("%032x"):format(index),
      available = true,
      area_name = "Benchmark room",
      attributes = codec.object({
        supported_features = 0,
        supported_color_modes = domain == "light" and codec.array({ "brightness" }) or nil,
      }),
      c4_exported = false,
      device_disabled = false,
      is_group = false,
    }
    registry[id] = codec.object({
      entity_id = id,
      id = ("%032x"):format(index + 100000),
      platform = "benchmark",
      disabled_by = codec.null,
      hidden_by = codec.null,
      entity_category = codec.null,
    })
  end
  local response = codec.encode(rows)
  table.sort(rows, function(a, b)
    return a.entity_id < b.entity_id
  end)
  local payloads = {}
  for offset = 0, rowCount - 1, native.indexSize do
    local window = codec.array({})
    for i = offset + 1, math.min(offset + native.indexSize, rowCount) do
      window[#window + 1] = rows[i].entity_id
    end
    for start = 0, #window - 1, native.pageSize do
      local page, pageIds = codec.array({}), codec.array({})
      for i = start + 1, math.min(start + native.pageSize, #window) do
        page[#page + 1], pageIds[#pageIds + 1] = rows[offset + i], window[i]
      end
      local template = start == 0 and native.template(nil, offset) or native.template(pageIds)
      payloads[template] = codec.encode(
        start == 0 and { ids = window, total = rowCount, rows = page, revision = string.rep("a", 64) } or page
      )
    end
  end
  local connection = Connection.new()
  connection.config = assert(Connection.validate("https://benchmark.test:8123", "benchmark-token"))
  connection.state = "connected"
  function http:post(_, payload, _, options)
    counts.projections = counts.projections + 1
    local body = assert(payloads[payload.template])
    assert(#body <= options.maxBytes, "template page exceeded the HTTP limit")
    return resolved({ body = body })
  end
  local revision = string.rep("a", 64)
  local function request(message, callback)
    if message.type == "call_service" then
      counts.catalog_probes = counts.catalog_probes + 1
      if companion then
        local unchanged = message.service_data.revision == revision
        callback(
          true,
          codec.object({
            response = codec.object({
              version = 1,
              eligibility_version = 1,
              revision = revision,
              native_revision = string.rep("b", 64),
              unchanged = unchanged,
              total = 0,
              pages = 0,
              page = 1,
              entities = not unchanged and codec.array({}) or nil,
            }),
          })
        )
      else
        callback(false, { kind = "not_found" })
      end
      return
    end
    assert(message.type == "config/entity_registry/get_entries")
    counts.registry_batches = counts.registry_batches + 1
    local entries = codec.object({})
    for _, id in ipairs(message.entity_ids) do
      entries[id] = assert(registry[id])
    end
    callback(true, codec.decode(codec.encode(entries)))
  end
  local catalog = Catalog.new(request, function()
    return connection:readCatalog()
  end, function(values, active, native)
    return Choices.enrich(values, request, active, native)
  end, true)

  ShimResetDynamicBindings()
  ShimSetStaticBindings({ { id = input, name = "Coordinator", provider = true, class = class, type = "CONTROL" } })
  local room, firstPeer = 10, 1000
  local devices = { [room] = { deviceName = "Benchmark room", driverFileName = "roomdevice.c4i" } }
  for index = 1, peerCount do
    local id = firstPeer + index
    devices[id] = { deviceName = "Existing load " .. index, driverFileName = packageInfo.file, roomId = room }
    updates[id] = entity(2 * index - 1)
  end
  ShimSetDevices(devices)
  for index = 1, peerCount do
    C4:Bind(coordinator, input, firstPeer + index, input)
  end
  ShimSetDriverFiles({ packageInfo.file })
  persist:delete("HA.Commissioning")
  local commissioning = Commissioning.new(catalog, function(id, query)
    updates[id] = query.choice_id
    return resolved({})
  end)
  return catalog, commissioning, #response, room
end

local function measure(run)
  local report = resetCounts()
  local start = os.clock()
  run(report)
  report.cpu_ms = (os.clock() - start) * 1000
  return report
end

local function run(rowCount, peerCount, batchSize, width, companion)
  local catalog, commissioning, bytes, room = fixture(rowCount, peerCount, width, companion)
  local report = codec.object({
    rows = rowCount,
    peers = peerCount,
    batch = batchSize,
    projection_bytes = bytes,
    companion = companion,
  })
  local metadata
  report.catalog = measure(function(sample)
    local opened = result(catalog:refresh(true))
    metadata = opened.value
    sample.outcome = opened.error or "ok"
  end)
  if not metadata or batchSize == 0 then
    return report
  end

  report.first_page = measure(function()
    local page = assert(catalog:read(metadata.revision, nil, "quick_lighting"))
    assert(#page.entities > 0)
    local listed = result(commissioning:browseChoices(page))
    assert(listed.value, listed.error)
  end)
  report.all_pages = measure(function(sample)
    local cursor, received = nil, 0
    sample.pages = 0
    repeat
      local page = assert(catalog:read(metadata.revision, cursor, "quick_lighting"))
      local listed = result(commissioning:browseChoices(page))
      assert(listed.value, listed.error)
      received = received + #page.entities
      sample.pages = sample.pages + 1
      cursor = page.next_cursor ~= codec.null and page.next_cursor or nil
    until not cursor
    assert(received == rowCount)
  end)
  local request, plan = { revision = metadata.revision, choices = {} }
  for index = 1, batchSize do
    request.choices[index] = { choice_id = entity(2 * (peerCount + index) - 1), family = "switch", room_id = room }
  end
  report.preview = measure(function()
    local preview = result(commissioning:preview(request))
    plan = assert(preview.value, preview.error)
    for _, item in ipairs(plan.items) do
      assert(item.decision == "add", item.reason)
    end
  end)
  report.migration_owner_checks = measure(function()
    local inventory = project.inventory(true)
    local wizard = setmetatable({ coordinator = coordinator, hub = { catalog = catalog } }, Upgrade)
    local oldRead = selection.read
    selection.read = function(id)
      counts.peer_reads = counts.peer_reads + 1
      local selected = assert(updates[id])
      return { stable = true, key = selected, load = selected, mode = "Home Assistant device" }
    end
    local cache = {}
    for _, choice in ipairs(request.choices) do
      local record = { source = { id = 99, entity = choice.choice_id } }
      assert(wizard:checkOwnership(record, nil, { entity_id = choice.choice_id }, nil, inventory, nil, cache))
    end
    selection.read = oldRead
  end)
  report.apply = measure(function()
    local deployed = result(commissioning:execute(plan.id))
    for _ = 1, batchSize do
      ShimAnswerAdds()
      clock.run(5000)
    end
    local value = assert(deployed.value, deployed.error)
    assert(value.complete, codec.encode(value))
    assert(#value.items == batchSize)
  end)
  return report
end

local rows, peers, batch, width = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
assert(rows and rows > 0 and peers and batch and peers * 2 + batch * 2 <= rows)
print(codec.encode(run(rows, peers, batch, width, arg[5] == "companion")))

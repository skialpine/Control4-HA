-- Installed only in the disposable Coordinator benchmark build.
local codec = require("ha.codec")
local metrics = require("ha.performance").shared
local Choices = require("ha.choices")
local M = {}

local function fixtureArchive(fixture, verify)
  local ok, status = pcall(function()
    UnlockC4ZRoot()
    assert(C4:FileSetDir("C4Z_ROOT") ~= false)
    if not C4:FileExists(fixture.file) then
      return "absent"
    end
    if verify then
      local archive = FileRead(fixture.file)
      local digest = C4:Hash("SHA256", archive, { return_encoding = "HEX" }):lower()
      return digest == fixture.archive_hash and "verified" or "mismatch"
    end
    return "present"
  end)
  C4:FileSetDir("C4Z")
  return ok and status or "unavailable"
end

function M.install(current, fixture)
  local setups, handlers, report, fixturePlan = {}, {}, nil, nil
  for _, setup in ipairs(Choices.setupTypes) do
    setups[setup.id] = true
  end
  require("ha.commission-page").install(current, function(command, _, handler)
    handlers[command] = handler
  end)
  local browse = handlers.HA_ADD_BROWSE

  local function testFixture(owner, setup, nonce, now)
    local config = fixture and owner.connection and owner.connection.config
    if
      not fixture
      or not config
      or not config.origin
      or C4:Hash("SHA256", config.origin, { return_encoding = "HEX" }):lower() ~= fixture.origin_hash
    then
      return false
    end
    local sample = { nonce = nonce, setup = setup, started = now, status = "pending" }
    if setup == "fixture_apply" then
      if
        not fixturePlan
        or fixturePlan.owner ~= owner
        or nonce ~= fixturePlan.nonce
        or now < fixturePlan.reviewed
        or now - fixturePlan.reviewed > 60000
        or fixture.file and fixtureArchive(fixture) ~= "absent"
      then
        return false
      end
      local plan = fixturePlan
      fixturePlan, report = nil, sample
      handlers.HA_ADD_APPLY(owner, { id = plan.id }, function(response)
        if report ~= sample or owner ~= current() then
          return
        end
        local row = response.complete and response.items[1]
        if row and row.status == "added" and type(row.device_id) == "number" then
          sample.device_id, sample.elapsed_ms = row.device_id, metrics.clock() - now
          sample.archive = fixture.file and fixtureArchive(fixture, true) or nil
          sample.status = (not fixture.file or sample.archive == "verified") and "added" or "added_archive_unverified"
        else
          sample.status = "apply_failed"
        end
      end)
      return true
    end

    fixturePlan, report = nil, sample
    browse(owner, { setup = fixture.family, refresh = true }, function(response)
      if report ~= sample or owner ~= current() then
        return
      end
      if response.error or not response.revision then
        sample.status = "browse_failed"
        return
      end
      local match
      for _, row in ipairs(response.choices) do
        if row.id == fixture.choice and row.family == fixture.family then
          match = row
          break
        end
      end
      if not match then
        sample.status = "fixture_missing"
        return
      end
      local started = metrics.clock()
      handlers.HA_ADD_PREVIEW(owner, {
        revision = response.revision,
        choices = {
          {
            choice_id = fixture.choice,
            family = fixture.family,
            room_id = fixture.room,
            name = fixture.name,
          },
        },
      }, function(review)
        if report ~= sample or owner ~= current() then
          return
        end
        local row = review.items and review.items[1]
        if row and row.choice_id == fixture.choice and row.family == fixture.family and row.room_id == fixture.room then
          sample.elapsed_ms = metrics.clock() - started
          if row.decision == "add" and row.name == fixture.name and type(review.id) == "string" then
            sample.archive = fixture.file and fixtureArchive(fixture) or nil
            if fixture.file and sample.archive ~= "absent" then
              sample.status = "archive_not_absent"
              return
            end
            fixturePlan = { owner = owner, nonce = nonce, id = review.id, reviewed = metrics.clock() }
            sample.status = "reviewed"
            return
          elseif row.decision == "keep" and row.name == fixture.name and type(row.device_id) == "number" then
            sample.status, sample.device_id = "kept", row.device_id
            return
          end
        end
        sample.status = "preview_failed"
      end)
    end)
    return true
  end

  UIR.suppressDebug.HA_LAB_QUICK_SETUP = true
  UIR.HA_LAB_QUICK_SETUP = function(params)
    local owner, now = current(), metrics.clock()
    local nonce, setup, count = params.NONCE, params.SETUP, tonumber(params.COUNT)
    if
      not owner
      or not owner.online
      or not metrics.enabled
      or type(nonce) ~= "string"
      or #nonce ~= 32
      or not nonce:match("^%x+$")
      or not count
      or count < 1
      or count > 5
      or count % 1 ~= 0
      or (report and report.status == "pending" and now - report.started < 45000)
    then
      return "<quick_setup>unavailable</quick_setup>"
    end
    if setup == "fixture_preview" or setup == "fixture_apply" then
      local status = count == 1 and testFixture(owner, setup, nonce, now) and "scheduled" or "unavailable"
      return "<quick_setup>" .. status .. "</quick_setup>"
    end
    if not setups[setup] then
      return "<quick_setup>unavailable</quick_setup>"
    end
    local catalog = owner:catalogFor(setup)
    local sample = {
      nonce = nonce,
      status = "pending",
      setup = setup,
      started = now,
      cold = catalog.snapshot == nil,
      warm_ms = codec.array({}),
    }
    report = sample
    local function measure(revision)
      local started = metrics.clock()
      browse(owner, { setup = setup, revision = revision, refresh = revision == nil }, function(response)
        if report ~= sample or owner ~= current() then
          return
        end
        local elapsed = metrics.clock() - started
        if response.error or type(response.revision) ~= "string" or elapsed < 0 then
          sample.status = "browse_failed"
        elseif not revision then
          sample.first_ms, sample.total, sample.page_rows = elapsed, response.total, #response.choices
          measure(response.revision)
        elseif response.revision ~= revision then
          sample.status = "revision_changed"
        else
          sample.warm_ms[#sample.warm_ms + 1] = elapsed
          if #sample.warm_ms == count then
            local context = metrics:report()
            sample.clock, sample.logging = context.clock, context.logging_at_export
            sample.status = "measured"
          else
            measure(revision)
          end
        end
      end)
    end
    measure()
    return "<quick_setup>scheduled</quick_setup>"
  end

  UIR.suppressDebug.HA_LAB_QUICK_SETUP_RESULT = true
  UIR.HA_LAB_QUICK_SETUP_RESULT = function(params)
    if report and report.nonce == params.NONCE then
      return "<quick_setup>" .. C4:Base64Encode(codec.encode(report)) .. "</quick_setup>"
    end
    return "<quick_setup>unknown</quick_setup>"
  end
end

return M

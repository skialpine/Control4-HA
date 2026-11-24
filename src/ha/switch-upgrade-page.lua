local Upgrade = require("ha.switch-upgrade")
local setupPage = require("ha.setup-page")
local page = require("lib.ui.page")
local installed = require("ha.installed-suite")
local project = require("ha.commissioning-project")
local log = require("lib.logging")
local metrics = require("ha.performance").shared
local M = {}

function M.install(current)
  local register = setupPage.commands(current)
  local function upgrade(owner)
    if not owner.switchUpgrade then
      owner.switchUpgrade = Upgrade.new(owner, function(result)
        page.send("HA_SWITCH_UPGRADE_PROGRESS", result)
      end)
    end
    return owner.switchUpgrade
  end
  UIR.HA_MIGRATION_RECHECK_STATUS = function()
    local owner = current()
    if not owner then
      return "<migration><issue>unavailable</issue></migration>"
    end
    local wizard = upgrade(owner)
    local revision = installed.upgradeRevision(wizard.coordinator)
    local issue, source = wizard:stagedReleaseIssue(revision)
    return ("<migration><issue>%s</issue><source>%d</source><revision>%d</revision></migration>"):format(
      issue or "ready",
      source or 0,
      revision or 0
    )
  end
  register("HA_SWITCH_UPGRADE", "HA_SWITCH_UPGRADE_REPLY", function(owner, params, done)
    local scan = params.action == "scan"
    local read = params.action == "availability" or params.action == "status"
    local wizard = not read and upgrade(owner)
    local function run(evidence)
      if read then
        wizard = upgrade(owner)
      end
      if params.action == "availability" then
        local result = wizard:availability()
        if result.pending and params.includeStatus == true then
          wizard:traceSavedRecovery()
          result.status = wizard:state()
        end
        return result
      elseif params.action == "status" then
        wizard:traceSavedRecovery()
        return wizard:state()
      elseif params.action == "scan" then
        local revision, waiting = wizard:scanReadiness()
        if waiting then
          return { waiting = waiting }
        end
        local rows = wizard:list(evidence, revision)
        return { rows = rows, pending = #rows == 0 and wizard:availability().pending or nil }
      elseif params.action == "review" then
        return wizard:review(params.selected, evidence)
      elseif params.action == "start" then
        return wizard:start(params.token, params.backup, evidence)
      elseif params.action == "resume" then
        return wizard:resume(params.token, params.reviewed)
      elseif params.action == "finish_names" then
        return wizard:finishNames(params.token, params.manual, params.tested, evidence)
      elseif params.action == "move_relays" then
        return wizard:moveManualRelays(params.token, params.manual, params.confirmed)
      elseif params.action == "approve_target" then
        return wizard:approveTarget(params.token, params.manual, params.key, params.accepted)
      elseif params.action == "recheck_connections" then
        return wizard:recheckConnections(params.token, params.manual)
      elseif params.action == "review_removal" then
        return wizard:reviewRemoval(params.tested, params.referencesReviewed, evidence, params.scope)
      end
      return { error = "Refresh the switch driver list to continue." }
    end
    local function respond(evidence)
      local span
      if read then
        span = metrics:start("migration." .. params.action)
        pcall(log.trace, log, "Quick Setup migration %s request received", params.action)
      end
      local ok, response = pcall(run, evidence)
      if read then
        metrics:finish(span, ok and "ok" or "failed")
        local result = not ok and "project read failed"
          or (response.pending or response.saved) and "saved migration"
          or "project checked"
        pcall(log.trace, log, "Quick Setup migration %s reply prepared (%s)", params.action, result)
      end
      done(
        ok and response
          or { error = "Control4 could not verify the project. Refresh the switch driver list to try again." }
      )
    end
    local reviewing = scan or params.action == "review" or params.action == "start"
    local scopeRequired = reviewing
    if params.action == "finish_names" or params.action == "review_removal" then
      for _, record in ipairs(wizard.batch and wizard.batch.records or {}) do
        if record.source.origin == "Legacy HA" and (record.phase == "naming" or record.phase == "upgraded") then
          scopeRequired = true
          break
        end
      end
    end
    local function prepare()
      if owner.online and scopeRequired and owner.installation then
        local ok, work = pcall(function()
          local inventory = project.inventory(true)
          return owner.installation:prepare(inventory):next(function(scope)
            scope.inventory = inventory
            return scope
          end)
        end)
        if ok then
          return work:next(respond, function()
            respond()
          end)
        end
      end
      respond()
    end
    if scan then
      local ok, _, waiting = pcall(wizard.scanReadiness, wizard)
      if not ok then
        done({ error = "Could not read the installed driver versions. Refresh the list to try again." })
        return
      elseif waiting then
        done({ waiting = waiting })
        return
      end
    end
    local refresh = scan and params.refresh == true
    local resume = params.action == "resume"
    local migration = params.action == "start" and wizard.preview or resume and wizard.batch
    for _, record in ipairs(migration and migration.records or {}) do
      if record.source.origin == "Legacy HA" and record.phase ~= "upgraded" and record.phase ~= "recovery" then
        refresh = not resume or not owner.catalog:hasVerifiedSnapshot()
        break
      end
    end
    if
      owner.online
      and (refresh or (scopeRequired and params.action ~= "start") and not owner.catalog:hasVerifiedSnapshot())
    then
      owner.catalog:refresh(refresh):next(prepare, function(problem)
        if scan and (not owner.online or type(problem) == "table" and problem.kind == "disconnected") then
          done({ waiting = "home_assistant" })
        else
          done({
            error = "Could not load the Home Assistant device list. Check the connection and try again.",
          })
        end
      end)
    else
      prepare()
    end
  end)
end

return M

local Upgrade = require("ha.switch-upgrade")
local setupPage = require("ha.setup-page")
local page = require("lib.ui.page")
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
  register("HA_SWITCH_UPGRADE", "HA_SWITCH_UPGRADE_REPLY", function(owner, params, done)
    local function run()
      local wizard = upgrade(owner)
      if params.action == "availability" then
        return wizard:availability()
      elseif params.action == "status" then
        return wizard:state()
      elseif params.action == "scan" then
        local rows = wizard:list()
        return { rows = rows, pending = #rows == 0 and wizard:availability().pending or nil }
      elseif params.action == "review" then
        return wizard:review(params.selected)
      elseif params.action == "start" then
        return wizard:start(params.token, params.backup)
      elseif params.action == "resume" then
        return wizard:resume(params.token, params.reviewed)
      elseif params.action == "finish_names" then
        return wizard:finishNames(params.token, params.manual, params.tested)
      elseif params.action == "move_relays" then
        return wizard:moveManualRelays(params.token, params.manual, params.confirmed)
      elseif params.action == "approve_target" then
        return wizard:approveTarget(params.token, params.manual, params.key, params.accepted)
      elseif params.action == "recheck_connections" then
        return wizard:recheckConnections(params.token, params.manual)
      elseif params.action == "review_removal" then
        return wizard:reviewRemoval(params.tested, params.referencesReviewed)
      end
      return { error = "Refresh the switch driver list to continue." }
    end
    local function respond()
      local ok, response = pcall(run)
      done(
        ok and response
          or { error = "Control4 could not verify the project. Refresh the switch driver list to try again." }
      )
    end
    if params.action == "review" and owner.online and not owner.catalog:hasVerifiedSnapshot() then
      owner.catalog:refresh(false):next(respond, respond)
    else
      respond()
    end
  end)
end

return M

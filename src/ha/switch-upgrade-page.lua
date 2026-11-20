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
    local ok, response = pcall(function()
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
        return wizard:finishNames()
      elseif params.action == "review_removal" then
        return wizard:reviewRemoval(params.tested)
      end
      return { error = "Refresh the switch driver list to continue." }
    end)
    done(
      ok and response
        or { error = "Control4 could not verify the project. Refresh the switch driver list to try again." }
    )
  end)
end

return M

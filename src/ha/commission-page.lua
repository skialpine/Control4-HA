-- Coordinator tab. List and preview have no project writes; only Apply consumes
-- a current preview. Each response belongs to the tab request that made it.
local codec = require("ha.codec")
local contract = require("ha.contract")
local page = require("ha.setup-page")
local Choices = require("ha.choices")
local M = {}
local errors = {
  preview_required = "Review your selection again before adding devices.",
  preview_changed = "The project changed. Review your selection again.",
  review_required = "Review the matching devices before adding anything.",
  room_changed = "The selected room changed. Choose a room and review your selection again.",
  duplicate_selection = "The same device was selected twice. Keep one entry and review your selection again.",
  invalid_request = "Choose a device, a room and a name, then review your selection again.",
  configuration_unconfirmed = "The new driver has not confirmed setup. Check the driver and review your selection again to finish setup.",
  retired = "The connection restarted. Review your selection again.",
}
function M.install(current)
  local register = page.commands(current)
  local function failed(done, err)
    local kind = type(err) == "table" and err.kind
    done({ error = errors[kind] or page.explain(kind) })
  end
  register("HA_ADD_GET", "HA_ADD_STATE", function(owner, _, done)
    done({
      rooms = owner.commissioning:rooms(),
      setups = Choices.setupTypes,
      can_browse = owner.online,
      status = owner.online and "Connected to Home Assistant" or "Check the connection to Home Assistant.",
    })
  end)
  register("HA_ADD_BROWSE", "HA_ADD_PAGE", function(owner, params, done)
    local query = codec.object({ family = params.family, cursor = params.cursor, revision = params.revision })
    -- Older open tabs sent a compatible family filter; new tabs choose a
    -- device type, including the combined lighting list.
    local index = query.family
    if params.setup then
      index = nil
      for _, setup in ipairs(Choices.setupTypes) do
        if params.setup == setup.id then
          index = "quick_" .. setup.id
          break
        end
      end
    end
    if not owner.online or not index or not contract.catalogQuery(query) then
      failed(done, { kind = owner.online and "invalid_request" or "disconnected" })
      return
    end
    local function read(revision)
      local result, err = owner.catalog:read(revision, query.cursor, index)
      if result then
        done(page.choices(result, true))
      else
        failed(done, { kind = err })
      end
    end
    if query.cursor or (params.setup and query.revision) then
      read(query.revision)
    else
      owner.catalog:refresh():next(function(metadata)
        read(metadata.revision)
      end, function(err)
        failed(done, err)
      end)
    end
  end)
  register("HA_ADD_PREVIEW", "HA_ADD_PREVIEWED", function(owner, params, done)
    owner.commissioning:preview(params):next(done, function(err)
      failed(done, err)
    end)
  end)
  register("HA_ADD_APPLY", "HA_ADD_RESULT", function(owner, params, done)
    owner.commissioning:execute(params.id):next(done, function(err)
      failed(done, err)
    end)
  end)
end
return M

-- Release asset eligibility through the template updater, including a mixed lab project.
local T = require("testlib")
require("c4_shim")
local deferred = require("deferred")
local http = require("lib.http")
local updater = require("lib.github-updater")
local ids = require("ha.identities").packages
local coordinator, light, switch = ids.coordinator.file, ids.light.file, ids.switch.file
local installed = {}
GetDriverVersion = function(filename)
  return installed[filename]
end

local function release(tag, prerelease)
  return {
    tag_name = tag,
    prerelease = prerelease,
    assets = {
      { name = coordinator },
      { name = light },
      { name = switch },
      { name = "inventory.json" },
    },
  }
end
function http:get()
  return deferred.new():resolve({ body = { release("v2026111802-rc1", true), release("v2026111801", false) } })
end
local function eligible(channel)
  local names = {}
  updater
    :getOutdatedDriverAssets("skialpine/Control4-HA", { coordinator, light, switch }, channel)
    :next(function(assets)
      for _, asset in ipairs(assets) do
        names[#names + 1] = asset.name
      end
    end, function(err)
      names = { tostring(err) }
    end)
  return names
end

installed = { [coordinator] = "20261118", [light] = "2026111801", [switch] = "2026111802" }
T.eq("production updates only the older archive in a mixed installation", eligible(false), { coordinator })
T.eq("prerelease has a higher same-day numeric core", eligible(true), { coordinator, light })
installed[coordinator], installed[light] = "2026111802", "2026111802"
T.eq("rechecking the same revision offers nothing", eligible(true), {})
T.eq("returning to production leaves newer prerelease members installed", eligible(false), {})
T.finish()

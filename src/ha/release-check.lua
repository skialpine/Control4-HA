-- Coordinator release selection and package integrity. Reads public GitHub assets only.
local updater = require("lib.github-updater")
local http = require("lib.http")
local codec = require("ha.codec")
local ids = require("ha.identities")
local deferred = require("deferred")
local version = require("version")

local M = {}
local REPOSITORY = "skialpine/Control4-HA"
local MANIFEST = "ha-suite-release.json"
local MAX_PACKAGE = 4 * 1024 * 1024
local packages = {
  { family = "Coordinator", file = ids.packages.coordinator.file, model = ids.packages.coordinator.model },
  { family = "Light", file = ids.packages.light.file, model = ids.packages.light.model, proxy = "light_v2" },
  { family = "Switch", file = ids.packages.switch.file, model = ids.packages.switch.model, proxy = "uibutton" },
}

local function revision(raw)
  return type(raw) == "string" and #raw == 10 and raw:match("^%d+$") and tonumber(raw) <= 2147483647 and tonumber(raw)
end

local function hash(value)
  return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$") ~= nil
end

local function newest(releases, preview)
  if not codec.isArray(releases) then
    return nil, "invalid_release_list"
  end
  local chosen, highest, collision
  for _, release in ipairs(releases) do
    local tag = type(release) == "table" and release.tag_name
    local core = type(tag) == "string"
      and #tag <= 50
      and (tag:match("^v(%d+)$") or (preview and tag:match("^v(%d+)%-[%w][%w.%-]*$")))
    local candidate = revision(core)
    if
      candidate
      and release.draft == false
      and release.prerelease == (tag ~= "v" .. core)
      and (preview or not release.prerelease)
    then
      if not highest or candidate > highest then
        chosen, highest, collision = release, candidate, false
      elseif candidate == highest then
        collision = true
      end
    end
  end
  if collision then
    return nil, "ambiguous_release"
  end
  return chosen, not chosen and "no_release" or nil
end

local function asset(release, name, bytes)
  if not codec.isArray(release.assets) then
    return nil
  end
  local matches
  for _, row in ipairs(release.assets) do
    if type(row) == "table" and row.name == name then
      if matches then
        return nil
      end
      matches = row
    end
  end
  local url = "https://github.com/" .. REPOSITORY .. "/releases/download/" .. release.tag_name .. "/" .. name
  if
    not matches
    or matches.state ~= "uploaded"
    or matches.browser_download_url ~= url
    or type(matches.size) ~= "number"
    or matches.size < 1
    or matches.size > bytes
    or matches.size ~= math.floor(matches.size)
    or type(matches.digest) ~= "string"
    or not hash(matches.digest:match("^sha256:(.+)$"))
  then
    return nil
  end
  return matches
end

local function githubAssetRedirect(location)
  return type(location) == "string"
    and (
      location:match("^https://release%-assets%.githubusercontent%.com/") ~= nil
      or location:match("^https://objects%.githubusercontent%.com/") ~= nil
    )
end

local function readDriverXML(archive)
  -- The build writes uncompressed driver.xml as the first local ZIP member.
  local function word(offset, length)
    local value = 0
    for index = length - 1, 0, -1 do
      value = 256 * value + archive:byte(offset + index)
    end
    return value
  end
  if
    #archive < 64
    or archive:sub(1, 4) ~= "PK\003\004"
    or archive:sub(-22, -19) ~= "PK\005\006"
    or word(7, 2) ~= 0
    or word(9, 2) ~= 0
    or word(27, 2) ~= 10
    or word(29, 2) ~= 0
    or archive:sub(31, 40) ~= "driver.xml"
  then
    return nil
  end
  local length = word(19, 4)
  local trailer = #archive - 21
  local count = word(trailer + 10, 2)
  local start = word(trailer + 16, 4) + 1
  if
    length == 0
    or length > 65536
    or length ~= word(23, 4)
    or start <= 40 + length
    or start >= trailer
    or start + word(trailer + 12, 4) ~= trailer
    or count < 2
    or count > 64
    or count ~= word(trailer + 8, 2)
    or word(trailer + 4, 4) ~= 0
    or word(trailer + 20, 2) ~= 0
  then
    return nil
  end
  local cursor, required = start, {}
  for _ = 1, count do
    if cursor + 46 > trailer or archive:sub(cursor, cursor + 3) ~= "PK\001\002" then
      return nil
    end
    local nameLength = word(cursor + 28, 2)
    local nextEntry = cursor + 46 + nameLength + word(cursor + 30, 2) + word(cursor + 32, 2)
    if nameLength == 0 or nextEntry > trailer or word(cursor + 34, 2) ~= 0 then
      return nil
    end
    local name = archive:sub(cursor + 46, cursor + 45 + nameLength)
    if name == "driver.xml" or name == "driver.lua" then
      local member = word(cursor + 42, 4) + 1
      local method, bytes = word(cursor + 10, 2), word(cursor + 20, 4)
      if
        required[name]
        or member + 30 + nameLength > start
        or (name == "driver.xml" and member ~= 1)
        or (name == "driver.lua" and member <= 40 + length)
        or archive:sub(member, member + 3) ~= "PK\003\004"
        or word(member + 26, 2) ~= nameLength
        or archive:sub(member + 30, member + 29 + nameLength) ~= name
        or word(member + 6, 2) ~= 0
        or word(cursor + 8, 2) ~= 0
        or (method ~= 0 and method ~= 8)
        or method ~= word(member + 8, 2)
        or bytes == 0
        or bytes ~= word(member + 18, 4)
        or word(cursor + 24, 4) ~= word(member + 22, 4)
        or word(cursor + 16, 4) ~= word(member + 14, 4)
        or member + 30 + nameLength + word(member + 28, 2) + bytes > start
      then
        return nil
      end
      required[name] = true
    end
    cursor = nextEntry
  end
  if cursor ~= trailer or not required["driver.xml"] or not required["driver.lua"] then
    return nil
  end
  local xml = archive:sub(41, 40 + length)
  if xml:find("<!DOCTYPE", 1, true) or xml:find("<!ENTITY", 1, true) then
    return nil
  end
  return Select(ParseXml(xml), "devicedata")
end

local function download(row)
  return http
    :get(row.browser_download_url, { Accept = "application/octet-stream" }, {
      rawBody = true,
      maxBytes = row.size,
      maxRedirects = 1,
      allowRedirect = githubAssetRedirect,
      privateUrl = true,
      timeout = 12,
      ssl_verify_host = true,
      ssl_verify_peer = true,
      cookies_enable = false,
    })
    :next(function(response)
      local body = response.body
      if
        type(body) ~= "string"
        or #body ~= row.size
        or "sha256:" .. C4:Hash("SHA256", body, { return_encoding = "HEX" }):lower() ~= row.digest
      then
        return reject("integrity")
      end
      return body
    end, function(problem)
      return reject(type(problem) == "table" and problem.tooLarge and "integrity" or "unreachable")
    end)
end

local function readInstalled()
  local installed, summary = {}, {}
  for _, package in ipairs(packages) do
    local instances = {}
    local low, high
    for key in pairs(C4:GetDevicesByC4iName(package.file) or {}) do
      local device = tonumber(key)
      if
        not device
        or device < 1
        or device ~= math.floor(device)
        or C4:GetDeviceData(device, "model") ~= package.model
      then
        return nil
      end
      local rev = tonumber(C4:GetDeviceData(device, "version"))
      if not rev or rev < 1 or rev > 2147483647 or rev ~= math.floor(rev) then
        return nil
      end
      instances[device] = rev
      low, high = math.min(low or rev, rev), math.max(high or rev, rev)
    end
    if low then
      installed[#installed + 1] = { package = package, low = low, high = high, instances = instances }
      summary[#summary + 1] = package.family .. " " .. (low == high and tostring(low) or low .. "–" .. high)
    end
  end
  return #installed > 0 and installed or nil, table.concat(summary, ", ")
end

local function installationMatches(installed, latest)
  if not latest or #latest ~= #installed then
    return false
  end
  for index, row in ipairs(installed) do
    local current = latest[index]
    if row.package ~= current.package then
      return false
    end
    for device, rev in pairs(row.instances) do
      if current.instances[device] ~= rev then
        return false
      end
    end
    for device in pairs(current.instances) do
      if not row.instances[device] then
        return false
      end
    end
  end
  return true
end

local function compatible(package, item, osVersion)
  if
    not codec.isObject(item)
    or item.model ~= package.model
    or not codec.isObject(item.proxies)
    or type(item.minimum_os) ~= "string"
    or not item.minimum_os:match("^%d+%.%d+%.%d+$")
    or #item.minimum_os > 15
    or not hash(item.sha256)
    or type(item.size) ~= "number"
    or item.proxies["5001"] ~= package.proxy
  then
    return false, "invalid_manifest"
  end
  for id in pairs(item.proxies) do
    if id ~= "5001" then
      return false, "invalid_manifest"
    end
  end
  local actual, actualError = version(osVersion)
  local required, requiredError = version(item.minimum_os)
  if actualError or requiredError then
    return false, "invalid_manifest"
  end
  if actual < required then
    return false, "incompatible", item.minimum_os
  end
  return true
end

local function qualify(release, installed, target, retainBytes)
  local manifestAsset = asset(release, MANIFEST, 16000)
  if not manifestAsset then
    return reject("invalid_manifest")
  end
  return download(manifestAsset):next(function(body)
    local ok, manifest = pcall(codec.decode, body)
    if
      not ok
      or not codec.isObject(manifest)
      or manifest.schema ~= 1
      or revision(manifest.revision) ~= target
      or not codec.isObject(manifest.assets)
    then
      return reject("invalid_manifest")
    end
    local archives = {}
    local os = C4:GetVersionInfo().version
    for _, entry in ipairs(installed) do
      local package = entry.package
      local item = manifest.assets[package.file]
      local candidate = asset(release, package.file, MAX_PACKAGE)
      if not item or not candidate then
        return reject({ kind = "incomplete", detail = package.family })
      end
      local accepted, errorKind, detail = compatible(package, item, os)
      if not accepted then
        return reject({ kind = errorKind, detail = detail })
      end
      if candidate.digest ~= "sha256:" .. item.sha256 or candidate.size ~= item.size then
        return reject("integrity")
      end
      archives[#archives + 1] = { asset = candidate, entry = entry, item = item }
    end
    -- Only hand a complete batch to the caller after every package passes.
    local qualified = {}
    local promise = deferred.new():resolve()
    for _, row in ipairs(archives) do
      local archive = row
      promise = promise:next(function()
        return download(archive.asset):next(function(bytes)
          local package = archive.entry.package
          local ok, xml = pcall(readDriverXML, bytes)
          local proxies = ok and xml and Select(xml, "proxies", "proxy")
          if
            not ok
            or type(xml) ~= "table"
            or xml.model ~= package.model
            or xml.version ~= manifest.revision
            or xml.minimum_os_version ~= archive.item.minimum_os
            or (package.proxy and (type(proxies) ~= "table" or proxies[1] ~= package.proxy or Select(
              proxies,
              "_attr",
              "proxybindingid"
            ) ~= "5001"))
            or (not package.proxy and proxies ~= nil)
          then
            return reject("invalid_archive")
          end
          if retainBytes then
            qualified[#qualified + 1] = { name = package.file, body = bytes, instances = archive.entry.instances }
          end
        end)
      end)
    end
    return promise:next(function()
      return qualified
    end)
  end)
end

local function releaseList(page, combined)
  return updater
    :listReleases(REPOSITORY, {
      rawBody = true,
      maxBytes = 512 * 1024,
      rejectRedirects = true,
      timeout = 12,
      ssl_verify_host = true,
      ssl_verify_peer = true,
      cookies_enable = false,
    }, page)
    :next(function(response)
      local ok, rows = pcall(codec.decode, response.body)
      if not ok or not codec.isArray(rows) then
        return reject("invalid_release_list")
      end
      for _, row in ipairs(rows) do
        combined[#combined + 1] = row
      end
      for name, value in pairs(response.headers or {}) do
        if
          type(name) == "string"
          and name:lower() == "link"
          and type(value) == "string"
          and value:find('rel="next"', 1, true)
        then
          if page >= 5 then
            return reject("partial_release_list")
          end
          return releaseList(page + 1, combined)
        end
      end
      return combined
    end, function(response)
      return reject(type(response) == "table" and response.code == 404 and "unavailable_repository" or "unreachable")
    end)
end

local function check(channel, retainBytes)
  return releaseList(1, codec.array({})):next(function(releases)
    local installed, summary = readInstalled()
    if not installed then
      return reject("installed_unknown")
    end
    local release, problem = newest(releases, channel == "Pre-release")
    if not release then
      return reject(problem)
    end
    local target = tonumber(release.tag_name:match("^v(%d+)"))
    local older = false
    for _, row in ipairs(installed) do
      if target < row.high then
        return { kind = "ahead", installed = summary, revision = target }
      elseif target > row.low then
        older = true
      end
    end
    if not older then
      return { kind = "current", installed = summary, revision = target }
    end
    return qualify(release, installed, target, retainBytes):next(function(qualified)
      if not installationMatches(installed, readInstalled()) then
        return reject("installed_changed")
      end
      return { kind = "available", installed = summary, revision = target, assets = retainBytes and qualified or nil }
    end, function(error)
      local result = type(error) == "table" and error or { kind = error }
      result.revision = target
      return reject(result)
    end)
  end)
end

function M.check(channel)
  return check(channel, false)
end

-- The installer can use these exact bytes without selecting a release again.
-- This step performs no writes. Apply immediately or recheck the inventory.
function M.prepare(channel)
  return check(channel, true)
end

local STATUS = "Driver update status"
local CHANNEL = "Update channel"
local HELP = "Use Actions → Check for driver updates."
local problems = {
  ambiguous_release = "GitHub has more than one release with the same revision. Ask your installer to check the release.",
  no_release = "There are no published releases on this channel.",
  invalid_release_list = "GitHub returned an unreadable release list. Try again later.",
  invalid_manifest = "The release manifest is incomplete or invalid. Ask your installer to check the release.",
  installed_unknown = "The installed driver versions could not be read. Ask your installer to check the suite.",
  installed_changed = "The installed driver versions changed during the check. Run the check again.",
  invalid_archive = "A driver file does not match the release manifest. Ask your installer to check the release.",
  partial_release_list = "GitHub has more releases than this check could read. Ask your installer to check the release.",
  integrity = "The release files failed verification. Ask your installer to check the release.",
  unavailable_repository = "The GitHub release repository is unavailable.",
  unreachable = "Couldn’t reach GitHub. Try again in a few minutes.",
}

function M.installActions(isReady)
  local running
  local function reset()
    -- One active request can settle after the channel changes. Its response
    -- still clears the request, but it no longer owns the status field.
    if running then
      running.stale = true
    end
    if Properties[STATUS] ~= nil then
      UpdateProperty(STATUS, running and "Waiting for the previous update check to finish…" or HELP)
    end
  end
  OPC.Update_channel = reset
  EC.CheckDriverUpdates = function()
    if running or not isReady() then
      return
    end
    local channel = Properties[CHANNEL] == "Pre-release" and "Pre-release" or "Production"
    local request = {}
    running = request
    UpdateProperty(STATUS, "Checking GitHub for driver updates…")
    local function complete(message)
      if running ~= request then
        return
      end
      running = nil
      if isReady() then
        UpdateProperty(STATUS, request.stale and HELP or message)
      end
    end
    local ok, promise = pcall(M.check, channel)
    if not ok then
      complete(problems.installed_unknown)
      return
    end
    promise:next(function(result)
      local current = " Installed: " .. result.installed .. "."
      if result.kind == "available" then
        complete(
          "Version " .. result.revision .. " is available. Ask your Control4 installer to update the suite." .. current
        )
      elseif result.kind == "ahead" then
        complete("An installed driver is newer than " .. channel .. " version " .. result.revision .. "." .. current)
      else
        complete("Installed drivers are current on " .. channel .. "." .. current)
      end
    end, function(error)
      local kind = type(error) == "table" and error.kind or error
      if kind == "incomplete" then
        complete(
          "Version "
            .. error.revision
            .. " is missing the "
            .. error.detail
            .. " driver. Check again after the release is fixed."
        )
      elseif kind == "incompatible" then
        complete(
          "Version "
            .. error.revision
            .. " requires Control4 OS "
            .. error.detail
            .. ". Ask your installer to check compatibility."
        )
      else
        complete(problems[kind] or problems.unreachable)
      end
    end)
  end
  return function()
    running = nil
    reset()
  end
end

return M

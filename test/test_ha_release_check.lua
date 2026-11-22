require("c4_shim")
local T = require("testlib")
local F = require("c4_fixtures")
local codec = require("ha.codec")
local deferred = require("deferred")
local http = require("lib.http")
local check = require("ha.release-check")
local RELEASE_BASE = "https://api.github.com/repos/skialpine/Control4-HA/releases?page="
local RELEASE_URL = RELEASE_BASE .. "1"
local ASSET_ROOT = "https://github.com/skialpine/Control4-HA/releases/download/"
local names = { "HA.Coordinator.c4z", "HA.Light.c4z", "Control4.HA.Switch.c4z" }
local models = { "HA Coordinator", "HA Light", "Control4.HA.Switch" }
local installed, payloads, requested, responseHeaders = {}, {}, {}, {}
local pausedURL, pausedDownload
local currentOS = "3.4.3"
local function digest(body)
  return C4:Hash("SHA256", body, { return_encoding = "HEX" }):lower()
end
local function reset()
  installed, payloads, requested, responseHeaders = {}, {}, {}, {}
  pausedURL, pausedDownload = nil, nil
  for i, name in ipairs(names) do
    installed[name] = { [i] = 2026111813 }
  end
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:GetVersionInfo()
  return { version = currentOS }
end
function C4:GetDevicesByC4iName(name)
  return installed[name]
end
function C4:GetDeviceData(id, tag)
  for index, name in ipairs(names) do
    local devices = installed[name]
    if devices and devices[id] then
      return tag == "model" and models[index] or devices[id]
    end
  end
end
function http:get(url, headers, options)
  requested[#requested + 1] = url
  T.truthy(
    "release transfer is bounded and uses verified TLS",
    options.maxBytes
      and options.ssl_verify_host == true
      and options.ssl_verify_peer == true
      and options.cookies_enable == false
  )
  T.eq("release never receives an Authorization header", headers.Authorization, nil)
  local promise = deferred.new()
  if url == pausedURL then
    pausedDownload = promise
    return promise
  end
  local response = payloads[url]
  if response then
    promise:resolve({ body = response, headers = responseHeaders[url] })
  else
    promise:reject({ code = 404 })
  end
  return promise
end

local function zipXML(text, missingScript)
  local function little(value, length)
    local bytes = {}
    for _ = 1, length do
      bytes[#bytes + 1] = string.char(value % 256)
      value = math.floor(value / 256)
    end
    return table.concat(bytes)
  end
  local members, directory = "", ""
  local function add(name, body)
    local offset, size, nameSize = little(#members, 4), little(#body, 4), little(#name, 2)
    local metadata = "\020\000" .. string.rep("\0", 12) .. size .. size .. nameSize .. "\000\000"
    members = members .. "PK\003\004" .. metadata .. name .. body
    directory = directory .. "PK\001\002\020\000" .. metadata .. string.rep("\0", 10) .. offset .. name
  end
  add("driver.xml", text)
  add(missingScript and "other.lua" or "driver.lua", "return true")
  return members
    .. directory
    .. "PK\005\006"
    .. "\000\000\000\000\002\000\002\000"
    .. little(#directory, 4)
    .. little(#members, 4)
    .. "\000\000"
end

local function draft(tag, options)
  options = options or {}
  local release =
    { tag_name = tag, draft = false, prerelease = tag:find("-", 1, true) ~= nil, assets = codec.array({}) }
  local assets = {}
  local function publishAsset(name, body)
    local url = ASSET_ROOT .. tag .. "/" .. name
    local info =
      { name = name, browser_download_url = url, state = "uploaded", digest = "sha256:" .. digest(body), size = #body }
    release.assets[#release.assets + 1] = info
    payloads[url] = body
    return info
  end
  for i, name in ipairs(names) do
    if options.skip ~= name then
      local proxies = codec.object({})
      if i > 1 then
        proxies["5001"] = i == 2 and "light_v2" or "uibutton"
      end
      local xmlModel = options.wrongModel == name and "Different driver" or models[i]
      local xml = "<devicedata><model>"
        .. xmlModel
        .. "</model><version>"
        .. tag:match("^v(%d+)")
        .. "</version><minimum_os_version>"
        .. (options.os or "3.3.0")
        .. "</minimum_os_version>"
        .. (i > 1 and '<proxies><proxy proxybindingid="5001">' .. proxies["5001"] .. "</proxy></proxies>" or "")
        .. "</devicedata>"
      local bytes = options.notZip == name and "Not an archive" or zipXML(xml, options.noScript == name)
      local row = publishAsset(name, bytes)
      assets[name] = {
        model = models[i],
        minimum_os = options.os or "3.3.0",
        proxies = proxies,
        size = #bytes,
        sha256 = digest(bytes),
      }
      if options.tamper == name then
        payloads[row.browser_download_url] = bytes:sub(1, -2) .. "!"
      end
    end
  end
  if not options.noManifest then
    publishAsset(
      "ha-suite-release.json",
      codec.encode({
        schema = options.manifestSchema or 1,
        revision = tag:match("^v(%d+)"),
        assets = codec.object(assets),
      })
    )
  end
  return release
end
local function outcome(channel, releases, checkRelease)
  if releases then
    payloads[RELEASE_URL] = codec.encode(codec.array(releases))
  end
  local result
  local inspect = checkRelease or check.check
  inspect(channel):next(function(res)
    result = res
  end, function(err)
    result = type(err) == "string" and { kind = err } or err
  end)
  return result
end

T.section("Newest compatible release selects a coherent installed family")
reset()
local preview, stable, older = draft("v2026111815-rc1"), draft("v2026111814"), draft("v2026111812")
local result = outcome("Production", { older, preview, stable })
T.eq(
  "Production excludes previews and ignores API list order",
  { result.kind, result.revision },
  { "available", 2026111814 }
)
T.eq("release list plus manifest and each installed archive", #requested, 5)
T.eq("read-only status needs no package buffers", result.assets, nil)
result = outcome("Pre-release", { older, preview, stable })
T.eq("Pre-release follows the higher revision", { result.kind, result.revision }, { "available", 2026111815 })

T.section("Production can see a stable release behind a page of previews")
reset()
preview, stable = draft("v2026111815-rc1"), draft("v2026111814")
responseHeaders[RELEASE_URL] = { Link = '<https://api.github.com/some/next>; rel="next"' }
payloads[RELEASE_BASE .. "2"] = codec.encode(codec.array({ stable }))
result = outcome("Production", { preview })
T.eq("pagination requests only the pinned API repository", requested[2], RELEASE_BASE .. "2")
T.eq("Production release remains discoverable", { result.kind, result.revision }, { "available", 2026111814 })

T.section("A mixed installation cannot be downgraded")
reset()
installed[names[1]][1] = 2026111816
result = outcome("Production", { draft("v2026111814") })
T.eq("no downloads planned when any installed driver is newer", { result.kind, #requested }, { "ahead", 1 })
result = outcome("Production", { draft("v2026111816") })
T.eq("same release can align a lagging child", result.kind, "available")

T.section("Leaving a pre-release channel waits for a newer production release")
reset()
for index, name in ipairs(names) do
  installed[name][index] = 2026111815
end
stable = draft("v2026111814")
preview = draft("v2026111815-rc1")
result = outcome("Production", { preview, stable }, check.prepare)
T.eq("leaving the preview channel offers no production downgrade", { result.kind, result.assets }, { "ahead" })
local promoted = draft("v2026111816")
result = outcome("Production", { preview, promoted, stable }, check.prepare)
T.eq(
  "the next same-day production revision can be installed",
  { result.kind, result.revision },
  { "available", 2026111816 }
)

T.section("Missing installed driver, malformed manifest, compatibility, and corrupted bytes fail closed")
local writes = {}
local function unexpectedWrite(api)
  return function()
    writes[#writes + 1] = api
    error("release preparation attempted " .. api)
  end
end
local originalAPI = {}
local guardedAPIs = { "FileWrite", "FileDelete", "AddDevice", "CreateTCPClient" }
for _, api in ipairs(guardedAPIs) do
  originalAPI[api], C4[api] = C4[api], unexpectedWrite(api)
end
for _, scenario in ipairs({
  { key = "invalid_manifest", opts = { noManifest = true }, reads = 1 },
  { key = "invalid_manifest", opts = { manifestSchema = 2 }, reads = 2 },
  { key = "incomplete", opts = { skip = names[3] }, reads = 2 },
  { key = "incompatible", opts = { os = "4.5.0" }, reads = 2 },
  { key = "integrity", opts = { tamper = names[3] }, reads = 5 },
  { key = "invalid_archive", opts = { notZip = names[3] }, reads = 5 },
  { key = "invalid_archive", opts = { noScript = names[3] }, reads = 5 },
  { key = "invalid_archive", opts = { wrongModel = names[3] }, reads = 5 },
}) do
  reset()
  result = outcome("Production", { draft("v2026111814", scenario.opts) }, check.prepare)
  T.eq(scenario.key .. " result", { result.kind, #requested }, { scenario.key, scenario.reads })
  T.eq(scenario.key .. " exposes no partial archive batch", result.assets, nil)
end
T.eq("rejected batches leave installed files, devices, and Director reloads untouched", writes, {})
reset()
local incomplete = draft("v2026111814", { skip = names[3] })
installed[names[3]] = nil
result = outcome("Production", { incomplete }, check.prepare)
T.eq(
  "uninstalled Switch is excluded from the batch and downloads",
  { result.kind, #result.assets, #requested },
  { "available", 2, 4 }
)
reset()
result = outcome("Production")
T.eq("unpublished repository gets a distinct result", result.kind, "unavailable_repository")

T.section("Installed package set is checked again after the last asset transfer")
reset()
local tag = "v2026111814"
local changingRelease = draft(tag, { skip = names[3] })
local newSwitch = installed[names[3]]
installed[names[3]] = nil
pausedURL = ASSET_ROOT .. tag .. "/" .. names[2]
payloads[RELEASE_URL] = codec.encode(codec.array({ changingRelease }))
result = nil
check.check("Production"):next(function(value)
  result = value
end, function(value)
  result = { kind = value }
end)
T.eq("status is pending while the package is downloading", result, nil)
installed[names[3]] = newSwitch
assert(pausedDownload):resolve({ body = payloads[pausedURL] })
T.eq("release is no longer qualified for the installation", result.kind, "installed_changed")

T.section("Preparation exposes the exact verified bytes together, including all installed instances")
reset()
installed[names[2]][12] = 2026111812
local complete = draft(tag)
pausedURL = ASSET_ROOT .. tag .. "/" .. names[3]
payloads[RELEASE_URL] = codec.encode(codec.array({ complete }))
result = nil
check.prepare("Production"):next(function(value)
  result = value
end)
T.eq("the first two verified files are never exposed ahead of the final transfer", result, nil)
assert(pausedDownload):resolve({ body = payloads[pausedURL] })
T.eq(
  "complete preparation includes all installed packages",
  { result.revision, #result.assets, #requested },
  { 2026111814, 3, 5 }
)
for index, name in ipairs(names) do
  T.eq("verified bytes and device revisions for " .. name, result.assets[index], {
    name = name,
    body = payloads[ASSET_ROOT .. tag .. "/" .. name],
    instances = installed[name],
  })
end

T.section("Replacing an instance at the same version invalidates preparation")
reset()
complete = draft(tag)
pausedURL = ASSET_ROOT .. tag .. "/" .. names[3]
payloads[RELEASE_URL] = codec.encode(codec.array({ complete }))
result = nil
check.prepare("Production"):next(function(value)
  result = value
end, function(value)
  result = { kind = value }
end)
installed[names[2]] = { [12] = 2026111813 }
assert(pausedDownload):resolve({ body = payloads[pausedURL] })
T.eq("matching version headlines cannot conceal replaced device IDs", result, { kind = "installed_changed" })
T.eq("preparation leaves all installation writes to the caller, including after a stale inventory", writes, {})
for _, api in ipairs(guardedAPIs) do
  C4[api] = originalAPI[api]
end

T.section("Coordinator action owns its status and ignores an older channel reply")
installed[names[1]] = { [1] = 2026111813 }
function C4:GetDeviceID()
  return 1
end
local old = check.check
local pending, calls = deferred.new(), 0
check.check = function(channel)
  T.eq("default channel", channel, "Production")
  calls = calls + 1
  return pending
end
local resetAction = check.installActions(function()
  return true
end)
Properties["Update channel"] = "Production"
Properties["Driver update status"] = ""
EC.CheckDriverUpdates()
EC.CheckDriverUpdates()
T.eq("repeat click shares current operation", calls, 1)
Properties["Update channel"] = "Pre-release"
OPC.Update_channel()
EC.CheckDriverUpdates()
T.eq("a recheck waits for the current transfer", calls, 1)
T.eq(
  "the pending state is visible",
  Properties["Driver update status"],
  "Waiting for the previous update check to finish…"
)
pending:resolve({ kind = "available", installed = "Coordinator 2026111813", revision = 2026111814 })
T.eq(
  "old channel cannot overwrite the new status",
  Properties["Driver update status"],
  "Use Actions → Check for driver updates."
)
resetAction()
check.check = old

if arg[1] then
  T.section("Production promotion qualifies the actual built packages")
  reset()
  local function read(name)
    local file = assert(io.open(arg[1] .. "/" .. name, "rb"))
    local data = file:read("*a")
    file:close()
    return data
  end
  local manifest = read("ha-suite-release.json")
  local published = codec.decode(manifest)
  local tag = "v" .. published.revision
  local release = { tag_name = tag, draft = false, prerelease = false, assets = codec.array({}) }
  local function add(name, body)
    local url = ASSET_ROOT .. tag .. "/" .. name
    release.assets[#release.assets + 1] = {
      name = name,
      browser_download_url = url,
      state = "uploaded",
      digest = "sha256:" .. digest(body),
      size = #body,
    }
    payloads[url] = body
  end
  local target = assert(tonumber(published.revision))
  local previous = draft("v" .. (target - 2))
  local preview = draft("v" .. (target - 1) .. "-beta.1")
  for index, name in ipairs(names) do
    installed[name][index] = target - 1
    add(name, read("c4z/" .. name))
  end
  add("ha-suite-release.json", manifest)
  result = outcome("Production", { preview, previous }, check.prepare)
  T.eq("changing from Pre-release to Production downloads no older assets", { result.kind, #requested }, { "ahead", 1 })
  result = outcome("Production", { preview, previous, release }, check.prepare)
  T.eq("all built C4Zs qualify for installation", { result.kind, #result.assets }, { "available", 3 })
  for index, name in ipairs(names) do
    T.truthy(
      "actual C4Z passed through unmodified for " .. name,
      result.assets[index].body == payloads[ASSET_ROOT .. tag .. "/" .. name]
    )
  end
  result = outcome("Pre-release", { previous, release, preview })
  T.eq(
    "the promoted revision is also the latest for Pre-release",
    { result.kind, result.revision },
    { "available", target }
  )

  T.section("the Coordinator applies the exact qualified archives only after opt-in")
  local root = ShimFiles("C4Z_ROOT")
  for _, name in ipairs(names) do
    root[name] = "existing " .. name
  end
  Properties["Update channel"], Properties["Automatic Updates"] = "Production", "Off"
  local endActions, startActions = check.installActions(function()
    return true
  end)
  local tcp = F.captureTcpClient({ holdReplies = true })
  EC.CheckDriverUpdates()
  T.eq("Off performs no write or reload", { root[names[2]], #tcp.writes }, { "existing " .. names[2], 0 })
  Properties["Automatic Updates"] = "On"
  startActions()
  ShimFireTimers()
  T.eq("automatic checks start the installer", #tcp.writes, 1)
  T.eq("first package is the exact qualified Light archive", root[names[2]], read("c4z/" .. names[2]))
  T.eq("the other archive stays in place before Light acknowledges", root[names[3]], "existing " .. names[3])
  endActions()
  tcp.restore()
end

T.finish()

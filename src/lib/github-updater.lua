--- A utility module for updating drivers from GitHub releases.
--- This module provides functionality to check for, download, and install driver updates from GitHub repositories.

local http = require("lib.http")
local log = require("lib.logging")
local deferred = require("deferred")
local version = require("version")

require("lib.utils")
require("drivers-common-public.global.lib")

--- Utility class for updating drivers from GitHub releases.
--- @class GitHubUpdater
local GitHubUpdater = {}
GitHubUpdater.__index = GitHubUpdater

--- Default headers for all HTTP requests to GitHub.
--- @type table<string, string>
local DEFAULT_HEADERS = {
  ["User-Agent"] = "curl/8.1.2",
  Accept = "*/*",
}

--- Create a new instance of GitHubUpdater.
--- @return GitHubUpdater updater A new GitHubUpdater instance.
function GitHubUpdater:new()
  local instance = setmetatable({}, self)
  return instance
end

--- Fetch the release list for a repository, using the caller's transfer bounds.
function GitHubUpdater:listReleases(repo, options, page)
  local url = "https://api.github.com/repos/" .. repo .. "/releases"
  if page then
    url = url .. "?page=" .. page
  end
  return http:get(url, DEFAULT_HEADERS, options)
end

--- Retrieve the latest release from a GitHub repository.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @return Deferred<table|nil, string> latestRelease Deferred resolving to the latest release table, or rejected with an error message.
--- @diagnostic disable-next-line: unused
function GitHubUpdater:getLatestRelease(repo, includePrereleases)
  log:trace("GitHubUpdater:getLatestRelease(%s, %s)", repo, includePrereleases)
  if IsEmpty(repo) then
    return reject("repo name is required")
  end
  return self:listReleases(repo):next(function(response)
    for _, release in pairs(response.body or {}) do
      local releaseVersion, err = version(release.tag_name)
      if IsEmpty(err) then
        if not release.draft and (toboolean(includePrereleases) or not release.prerelease) then
          release.version = releaseVersion
          return release
        end
      else
        log:warn("repo %s release '%s' has an invalid tag version '%s'", repo, release.name, release.tag_name)
      end
    end
    return reject(string.format("repo %s does not have any valid releases", repo))
  end, function(response)
    return reject(response.error)
  end)
end

--- Identify assets for driver files that are outdated compared to the latest GitHub release.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to check.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, all assets will be treated as outdated regardless of version (optional).
--- @return Deferred<table[], string> outdatedAssets Deferred resolving to a list of assets to be updated, or rejected with an error message.
function GitHubUpdater:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:getOutdatedDriverAssets(%s, %s, %s, %s)",
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  if IsEmpty(driverFilenames) then
    return reject(string.format("at least one driver filename is required to check for updates"))
  end
  local installed = {}
  for _, driverFilename in pairs(driverFilenames) do
    local driverVersion, err = version(GetDriverVersion(driverFilename))
    if not IsEmpty(err) then
      return reject(string.format("failed to determine the current %s driver version", driverFilename))
    end
    installed[driverFilename] = driverVersion
  end

  return self:getLatestRelease(repo, includePrereleases):next(function(latestRelease)
    --- @type table[]
    local assets = {}
    local driverFilenamesMap = {}
    for filename, installedVersion in pairs(installed) do
      if forceUpdate or latestRelease.version > installedVersion then
        driverFilenamesMap[filename] = true
      end
    end
    for _, asset in pairs(Select(latestRelease, "assets") or {}) do
      local assetName = Select(asset, "name")
      if driverFilenamesMap[assetName] ~= nil then
        driverFilenamesMap[assetName] = nil
        table.insert(assets, asset)
      end
    end
    if not IsEmpty(driverFilenamesMap) then
      return reject(
        string.format(
          "repo %s latest release does not have the following asset(s): %s",
          repo,
          table.concat(TableKeys(driverFilenamesMap), ", ")
        )
      )
    end
    return assets
  end)
end

local function selectArchiveDirectory(dir)
  -- Only the template's archive location needs the C4Z root alias.
  if dir == "C4Z_ROOT" then
    UnlockC4ZRoot()
  end
  return C4:FileSetDir(dir) ~= false
end

--- Read an archive from the selected DriverWorks file directory.
function GitHubUpdater:readArchive(dir, name)
  if selectArchiveDirectory(dir) and C4:FileExists(name) then
    return FileRead(name)
  end
end

--- Write caller-qualified bytes and confirm every byte before requesting a reload.
function GitHubUpdater:writeArchive(dir, name, body)
  if not selectArchiveDirectory(dir) then
    return false
  end
  FileWrite(name, body, true)
  return FileRead(name) == body
end

--- Request one Director reload. A self reload is submitted before this driver exits.
--- The caller verifies the running revision separately.
function GitHubUpdater:reloadArchive(name, selfReload)
  local promise = deferred.new()
  local client, closed = C4:CreateTCPClient(), false
  local function close()
    if not closed then
      closed = true
      client:Close()
    end
  end
  local request = XMLTag(
    "c4soap",
    XMLTag("param", name, nil, nil, { name = "name", type = "string" }),
    false,
    false,
    { name = "UpdateProjectC4i", session = "0", operation = "RWX", category = "composer", async = "0" }
  ) .. "\0"
  client
    :OnConnect(function(client)
      if closed then
        return
      end
      client:Write(request)
      client:ReadUntil("\0")
      if selfReload then
        promise:resolve("submitted")
      end
    end)
    :OnRead(function(_, reply)
      if closed then
        return
      end
      close()
      if not selfReload then
        local header = type(reply) == "string" and reply:match("<c4soap(%s[^>]+)>")
        if header and header:match("%sname=['\"]UpdateProjectC4i['\"]") and header:match("%sresult=['\"]1['\"]") then
          promise:resolve("replied")
        else
          promise:reject("Director did not acknowledge the driver reload")
        end
      end
    end)
    :OnError(function(_, code, message)
      if closed then
        return
      end
      close()
      promise:reject("Error " .. code .. ": " .. message)
    end)
    :Connect("127.0.0.1", 5020)
  return promise, close
end

--- Download outdated driver assets from GitHub and write them to the specified directory.
--- @param dir string Target directory to save downloaded driver assets.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean Optional. If true, downloads all drivers regardless of version (optional).
--- @return Deferred<string[], string|table<number, string>> outdatedDrivers Deferred resolving to a list of successfully downloaded driver filenames, or rejected with an error message or a table of them indexed by number.
function GitHubUpdater:downloadOutdatedDrivers(dir, repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:downloadOutdatedDrivers(%s, %s, %s, %s, %s)",
    dir,
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  return self:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate):next(function(assets)
    --- @type Deferred<table, string>[]
    local downloads = {}
    for _, asset in pairs(assets) do
      if IsEmpty(asset.browser_download_url) then
        return reject(string.format("repo %s latest release asset %s download is unavailable", repo, asset.name))
      end

      --- @type Deferred<table, string>
      local download = http:get(asset.browser_download_url, DEFAULT_HEADERS):next(function(response)
        local downloadSize = string.len(response.body)
        if downloadSize < 1 then
          return reject(string.format("asset %s download is empty", asset.name))
        end
        log:info("Downloaded asset %s (%d bytes)", asset.name, downloadSize)
        return { name = asset.name, body = response.body }
      end, function(response)
        return reject(response.error)
      end)

      table.insert(downloads, download)
    end
    -- Nothing is written until every asset has downloaded, so a failed download leaves
    -- every installed file as it was.
    return deferred.all(downloads):next(function(downloaded)
      --- @type string[]
      local written = {}
      for _, download in ipairs(downloaded) do
        local currentContents = self:readArchive(dir, download.name)
        if not self:writeArchive(dir, download.name, download.body) then
          if currentContents ~= nil then
            self:writeArchive(dir, download.name, currentContents)
          end
          return reject(string.format("failed to write asset %s", download.name))
        end
        table.insert(written, download.name)
      end
      return written
    end)
  end)
end

--- Update all given drivers to the latest release from GitHub.
--- Downloads new drivers, writes them, and sends them for update over TCP to the local system.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update: the repo's own is `require("lib.driver-filenames")`.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, runs update even if drivers are up to date (optional).
--- @return Deferred<string[], string|table<number, string>> updatedDrivers Deferred resolving to a list of updated driver filenames, or rejected with an error message or table.
function GitHubUpdater:updateAll(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace("GitHubUpdater:updateAll(%s, %s, %s, %s)", repo, driverFilenames, includePrereleases, forceUpdate)
  -- Only update drivers that are already installed.
  local installedDriverFilenames = {}
  for _, driverFilename in pairs(driverFilenames) do
    if not IsEmpty(C4:GetDevicesByC4iName(driverFilename) or {}) then
      table.insert(installedDriverFilenames, driverFilename)
    end
  end

  return self
    :downloadOutdatedDrivers("C4Z_ROOT", repo, installedDriverFilenames, includePrereleases, forceUpdate)
    :next(function(downloadedDriverFilenames)
      --- @type Deferred<string[], string|table<number, string>>
      local d = deferred.new()
      if IsEmpty(downloadedDriverFilenames) then
        return d:resolve(downloadedDriverFilenames)
      end

      -- Update the running driver's own c4z LAST: reloading it tears down this
      -- loop (and its socket) before the remaining companions are sent, which
      -- strands them a version behind.
      local ownFilename = C4.GetDriverFileName and C4:GetDriverFileName()
      local updateOrder = {}
      local ownFilenameToUpdate
      for _, driverFilename in pairs(downloadedDriverFilenames) do
        if driverFilename == ownFilename then
          ownFilenameToUpdate = driverFilename
        else
          table.insert(updateOrder, driverFilename)
        end
      end
      if ownFilenameToUpdate ~= nil then
        table.insert(updateOrder, ownFilenameToUpdate)
      end

      -- Director drops UpdateProjectC4i commands still queued on a socket that
      -- closes, so each update waits for Director's reply before the next is sent.
      local function sendUpdate(index)
        local driverFilename = updateOrder[index]
        if driverFilename == nil then
          return d:resolve(downloadedDriverFilenames)
        end
        self:reloadArchive(driverFilename, driverFilename == ownFilenameToUpdate):next(function()
          sendUpdate(index + 1)
        end, function(error)
          d:reject(error)
        end)
      end
      sendUpdate(1)
      return d
    end)
end

return GitHubUpdater:new()

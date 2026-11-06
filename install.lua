-- cc-ai installer
-- In-game:  wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
-- Options:  install [--full | --minimal] [--dir <folder>] [owner/repo] [branch] [folder]
-- Installs lib/, bin/, docs/ and this installer (--full adds examples/ and
-- tests/, and the Basalt UI's code, which cc-code otherwise downloads when
-- it is used) and adds a startup file that puts cc-code on the shell path.
-- The folder is the one given (--dir, or the third argument; a drive's own
-- folder, such as /hdd, means cc-ai on that drive). Otherwise it is the
-- install this installer belongs to (/hdd/cc-ai/install updates /hdd/cc-ai),
-- else an install that exists (the one the startup file names, /cc-ai, or
-- cc-ai on a hard drive). A new install goes to cc-ai on the hard drive
-- with the most free space (the CC-Harddisks mod) if the files fit there,
-- else to /cc-ai. An update keeps the previous choice of --full or
-- --minimal unless given another.
-- Every file comes from one commit: the branch is resolved to its commit
-- first, because raw.githubusercontent.com caches branch URLs for minutes
-- (an update right after a push could otherwise mix old and new files).

-- The options can be anywhere; the other arguments are read by position
local args, FULL, DIR_OPTION = {}, nil, nil
do
  local given = table.pack(...)
  local n = 0
  local function folderOption(value)
    if type(value) ~= "string" or value == "" or value:sub(1, 1) == "-" then
      error("--dir needs a folder, for example --dir /hdd/cc-ai", 0)
    end
    return value
  end
  local i = 1
  while i <= given.n do
    local value = given[i]
    if value == "--full" then
      FULL = true
    elseif value == "--minimal" then
      FULL = false
    elseif value == "--dir" then
      i = i + 1
      DIR_OPTION = folderOption(given[i])
    elseif type(value) == "string" and value:sub(1, 6) == "--dir=" then
      DIR_OPTION = folderOption(value:sub(7))
    elseif type(value) == "string" and value:sub(1, 1) == "-" then
      error("Unknown option " .. value .. " (use --full, --minimal or --dir <folder>)", 0)
    else
      n = n + 1
      args[n] = value
    end
    i = i + 1
  end
end
if DIR_OPTION and args[3] then
  error("Give the folder once: with --dir or as the third argument", 0)
end
local REPO = args[1] or "mindbound/cc-ai"
local BRANCH = args[2] or "master"
local DEFAULT_DIR = "/cc-ai"
local STARTUP = "/startup/cc-ai.lua"

-- Top-level entries (directories and files) that belong to an installation.
-- An update deletes all of them, also the ones it does not install.
local INSTALL = {
  lib = true, bin = true, docs = true, examples = true, tests = true,
  ["install.lua"] = true,
}
-- The entries only a full install has (about 380 KB). An update needs room
-- for the old and the new install at once, and a computer's disk holds
-- 1 MB by default, so the default is a minimal install.
local FULL_ONLY = { examples = true, tests = true }
-- Files in the installed entries that only a full install has: the Basalt
-- UI's code (a trial, about 58 KB). cc-code downloads them, from the
-- installed commit, the first time the Basalt UI runs (lib/cc-code/basalt/
-- load.lua, which has the same list). An update deletes them with lib/.
local FULL_ONLY_FILES = {
  ["lib/cc-code/basalt/app.lua"] = true,
  ["lib/cc-code/basalt/ui.lua"] = true,
  ["lib/cc-code/basalt/log.lua"] = true,
}
-- Not an installed entry: the Basalt UI downloads vendor/basalt.lua there
-- (143 KB) the first time it runs. An update leaves it in place, unless
-- the new files fit only without it: it can be downloaded again.
local VENDOR = "vendor"

if not http then
  printError("The HTTP API is disabled. Enable it in the ComputerCraft config.")
  return
end

local json = textutils.unserialiseJSON

-- The body of a GET request, or nil and the reason it failed
local function fetch(url, binary, headers)
  local response, err = http.get(url, headers, binary)
  if not response then
    return nil, tostring(err)
  end
  local body = response.readAll()
  response.close()
  return body or ""
end

local function get(url, binary, headers)
  local body, err = fetch(url, binary, headers)
  if not body then
    error("Download failed: " .. url .. " (" .. err .. ")", 0)
  end
  return body
end

-- A path as "/a/b" (fs.combine drops the leading slash)
local function absolute(path)
  return "/" .. fs.combine(path, "")
end

-- Whether a folder holds an install: one this installer made (.version),
-- or one an older installer or a copy by hand made (bin/cc-code.lua)
local function isInstall(dir)
  return fs.isDir(dir) and (fs.exists(fs.combine(dir, ".version")) or fs.exists(fs.combine(dir, "bin/cc-code.lua")))
end

-- The nearest folder at or above path that exists ("" is the root). A
-- path above the root ("../x") counts as the root: in CC: Tweaked it never
-- exists, and fs.getDir("..") is "../..".
local function existingAncestor(path)
  local current = fs.combine(path, "")
  while current ~= "" and not fs.exists(current) do
    if current == ".." or current:sub(1, 3) == "../" then
      return ""
    end
    current = fs.getDir(current)
  end
  return current
end

-- Whether a top-level folder is a drive of its own (a hard drive, a disk,
-- rom) rather than a folder on the computer's own drive
local function isDriveFolder(name)
  return fs.exists(name) and fs.getDrive(name) ~= fs.getDrive("")
end

-- A top-level name that CC: Tweaked gives a drive: hdd, hdd2, ... for a
-- hard drive's fixed platter, disk, disk2, ... for a disk or a cartridge
local function isDriveName(name)
  return name:match("^hdd%d*$") ~= nil or name:match("^disk%d*$") ~= nil
end

-- A folder's place within its drive, and whether that drive is not the
-- computer's own: "/hdd/cc-ai" is "cc-ai" on a drive. (A drive name that
-- is not mounted now counts as a drive: an older startup file may name it.)
local function placeOf(dir)
  local path = fs.combine(dir, "")
  local first, rest = path:match("^([^/]+)/(.+)$")
  if first and (isDriveFolder(first) or isDriveName(first)) then
    return rest, true
  end
  return path, false
end

-- Whether the drive of a folder on another drive is not mounted now (it
-- may be attached a moment later, as through a wired modem)
local function driveMissing(dir, onOtherDrive)
  local first = dir:match("^/([^/]+)/")
  return onOtherDrive and first ~= nil and not fs.exists(first)
end

-- Where an install that was in dir is now, looked for as the startup file
-- looks for it: in dir; else at the same place within a drive, under each
-- hard drive (hdd, hdd2, ...), each other drive (disks, cartridges), each
-- folder on the computer's own drive, with the computer's own root first
-- if the install was on it, else last. While dir's drive is not mounted
-- under its name, only on drives: it may be mounted under another name
-- (hdd2 is hdd when the other hard drive is gone), and a copy on the
-- computer's own drive is not the install. nil if it is nowhere. (dir
-- counts as an install by .version too, so an interrupted update is
-- found; elsewhere only bin/cc-code.lua counts, as for the startup file.)
local function findInstall(dir, within, onOtherDrive)
  if isInstall(dir) then
    return dir
  end
  local missing = driveMissing(dir, onOtherDrive)
  local own, hdds, others = {}, {}, {}
  for _, name in ipairs(fs.list("/")) do
    if not isDriveFolder(name) then
      table.insert(own, name)
    elseif name ~= "rom" then
      table.insert(name:match("^hdd%d*$") and hdds or others, name)
    end
  end
  local places = {}
  if not onOtherDrive then
    table.insert(places, "")
  end
  for _, list in ipairs(missing and { hdds, others } or { hdds, others, own }) do
    for _, name in ipairs(list) do
      table.insert(places, name)
    end
  end
  if onOtherDrive and not missing then
    table.insert(places, "")
  end
  for _, place in ipairs(places) do
    local found = "/" .. fs.combine(place, within)
    if fs.exists(found .. "/bin/cc-code.lua") then
      return found
    end
  end
  return nil
end

-- The entries of an install folder that an update replaces, which the
-- installer must never take from someone else (install.lua is left out:
-- a folder may hold just the downloaded installer)
local REPLACED = { "bin", "docs", "examples", "lib", "tests" }

-- Stop when dir holds files that are not an install's, which the install
-- would replace
local function checkFolder(dir)
  if not fs.isDir(dir) or isInstall(dir) then
    return
  end
  local found = {}
  for _, name in ipairs(REPLACED) do
    if fs.exists(fs.combine(dir, name)) then
      table.insert(found, name)
    end
  end
  if #found > 0 then
    error(dir .. " holds files that are not cc-ai's (" .. table.concat(found, ", ") ..
      "), which the install would replace. Choose a new or empty folder, such as " ..
      absolute(fs.combine(dir, "cc-ai")) .. ".", 0)
  end
end

-- Space in KB, as the messages show it
local function kb(bytes)
  return math.floor(bytes / 1000) .. " KB"
end

-- The hard drives attached (the CC-Harddisks mod: peripheral type
-- "hard_drive"; each drive's fixed platter is mounted at /hdd, /hdd2, ...),
-- as { path = "/hdd", free = bytes or nil }, the most free space first
local function hardDrives()
  local drives = {}
  if type(peripheral) ~= "table" or type(peripheral.find) ~= "function" then
    return drives
  end
  local ok, found = pcall(function() return table.pack(peripheral.find("hard_drive")) end)
  if not ok then
    return drives
  end
  for i = 1, found.n do
    local drive = found[i]
    local okMount, mount = pcall(function() return drive.getFixedMountPath() end)
    if okMount and type(mount) == "string" and fs.combine(mount, "") ~= "" then
      local okFree, free = pcall(fs.getFreeSpace, mount)
      table.insert(drives, { path = absolute(mount), free = okFree and type(free) == "number" and free or nil })
    end
  end
  table.sort(drives, function(a, b)
    if (a.free or -1) ~= (b.free or -1) then
      return (a.free or -1) > (b.free or -1)
    end
    return a.path < b.path
  end)
  return drives
end

-- Whether a path (as "/a/b") is on a drive found by hardDrives
local function onDrive(path, drive)
  return (path .. "/"):find(drive.path .. "/", 1, true) == 1
end

-- What the startup file says: the install folder it names (an older
-- installer wrote only its bin folder), and the install's place within its
-- drive (for an older startup file: worked out from the folder). nil if
-- there is no startup file of the installer's.
local STARTUP_DIR, STARTUP_WITHIN, STARTUP_ON_DRIVE
do
  local handle = fs.open(STARTUP, "r")
  if handle then
    local text = handle.readAll() or ""
    handle.close()
    local dir = text:match("\nlocal dir = \"(/[^\"\n]*)\"") or text:match("\nlocal binDir = \"(/[^\"\n]*)/bin\"")
    if dir then
      STARTUP_DIR = absolute(dir)
      local within, onDrive = text:match("\n  local within, onDrive = \"([^\"\n]*)\", (%a+)\n")
      if within then
        STARTUP_WITHIN, STARTUP_ON_DRIVE = within, onDrive == "true"
      else
        STARTUP_WITHIN, STARTUP_ON_DRIVE = placeOf(STARTUP_DIR)
      end
    end
  end
end
-- The install the startup file puts on the shell path now (nil if none)
local IN_USE = STARTUP_DIR and findInstall(STARTUP_DIR, STARTUP_WITHIN, STARTUP_ON_DRIVE)

-- The install's folder (see the top of this file). For a new install that
-- is not given one it stays nil until the file listing: the hard drive is
-- chosen by the space the files need. OWN: the running installer is the
-- install's own (so the installer in DIR is this version).
local DIR, OWN
do
  local given = DIR_OPTION or args[3]
  if given then
    -- (relative to the current folder, as other programs take paths)
    if type(shell) == "table" and type(shell.resolve) == "function" then
      given = shell.resolve(given)
    end
    DIR = absolute(given)
    local first = DIR:match("^/([^/]+)")
    if not first or first == ".." then
      error("Choose a folder to install into, such as " .. DEFAULT_DIR, 0)
    end
    if isDriveFolder(first) then
      if DIR == "/" .. first then
        DIR = absolute(fs.combine(first, "cc-ai"))
      end
    elseif isDriveName(first) then
      error("No drive is mounted at /" .. first .. ". Attach it (or turn on its wired modem) and run the" ..
        " installer again, or choose another folder.", 0)
    end
  else
    -- The installer of an install (shell.run loads it as "@/<path>")
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local file = info and type(info.source) == "string" and info.source:match("^@(.+)$")
    if file and fs.getName(file) == "install.lua" and fs.getDir(file) ~= "" and isInstall(fs.getDir(file)) then
      DIR, OWN = absolute(fs.getDir(file)), true
    else
      -- The install in use is on a drive that is not mounted: don't make
      -- a second one elsewhere
      if STARTUP_DIR and not IN_USE and driveMissing(STARTUP_DIR, STARTUP_ON_DRIVE) then
        error("The startup file names " .. STARTUP_DIR .. ", but no drive is mounted at /" ..
          STARTUP_DIR:match("^/([^/]+)/") .. ". Attach it (or turn on its wired modem) and run the installer" ..
          " again, or choose a folder with --dir.", 0)
      end
      local candidates = {}
      if IN_USE then
        table.insert(candidates, IN_USE)
      end
      table.insert(candidates, DEFAULT_DIR)
      for _, drive in ipairs(hardDrives()) do
        table.insert(candidates, absolute(fs.combine(drive.path, "cc-ai")))
      end
      for _, candidate in ipairs(candidates) do
        if isInstall(candidate) then
          DIR = candidate
          break
        end
      end
    end
  end
  if DIR then
    if fs.isReadOnly(existingAncestor(DIR)) then
      error("Cannot install to " .. DIR .. ": it is read-only.", 0)
    end
    checkFolder(DIR)
  end
end

-- What the previous install recorded in .version, or nil
local PREVIOUS
if DIR then
  local handle = fs.open(fs.combine(DIR, ".version"), "rb")
  if handle then
    local info = textutils.unserialize(handle.readAll() or "")
    handle.close()
    if type(info) == "table" then
      PREVIOUS = info
    end
  end
end

-- Without an option, an update keeps the previous choice. An install that
-- recorded none (none yet, or an older installer) becomes minimal.
if FULL == nil then
  FULL = PREVIOUS ~= nil and PREVIOUS.full == true
end
local SET = FULL and "full" or "minimal"

-- Whether this install puts a top-level entry in place
local function installs(name)
  return INSTALL[name] and (FULL or not FULL_ONLY[name])
end

-- Whether this install downloads a file of the repository (its path)
local function installsFile(path)
  local top = path:match("^[^/]+")
  return top ~= nil and installs(top) and (FULL or not FULL_ONLY_FILES[path])
end

print("Installing cc-ai (" .. SET .. ") from " .. REPO .. " (" .. BRANCH .. ")" .. (DIR and (" to " .. DIR) or ""))

-- The branch's current commit (or the branch itself if that fails: the
-- install still works, it is just not pinned)
local COMMIT
do
  local ok, body, reason = pcall(fetch, "https://api.github.com/repos/" .. REPO .. "/commits/" .. BRANCH, true,
    { Accept = "application/vnd.github.sha" })
  if not ok then
    -- Ctrl+T while waiting for the reply cancels the install
    if body == "Terminated" then error(body, 0) end
    reason, body = tostring(body), nil
  end
  local sha = type(body) == "string" and body:match("^%s*(%x+)%s*$")
  if sha and select(2, sha:find("$")) == 40 then
    COMMIT = sha:lower()
  else
    printError("Could not look up the commit of " .. BRANCH .. " (" .. (reason or "unexpected reply") ..
      "); downloading by branch name.")
  end
end
local REF = COMMIT or BRANCH

-- List the repository's files
local treeUrl = "https://api.github.com/repos/" .. REPO .. "/git/trees/" .. REF .. "?recursive=1"
local tree = json(get(treeUrl, true))
if type(tree) ~= "table" or type(tree.tree) ~= "table" then
  error("Unexpected response listing " .. REPO, 0)
end

-- The files to install, and the disk space they take as CC: Tweaked counts
-- it: each file at least 500 bytes and each directory 500 (the first 500
-- is the staging directory)
local files, needed, dirs = {}, 500, {}
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" and installsFile(entry.path) then
    table.insert(files, entry.path)
    needed = needed + math.max(tonumber(entry.size) or 0, 500)
    local dir = fs.getDir(entry.path)
    while dir ~= "" and not dirs[dir] do
      dirs[dir] = true
      needed = needed + 500
      dir = fs.getDir(dir)
    end
  end
end
if #files == 0 then
  error("No files found in " .. REPO .. " (" .. BRANCH .. ")", 0)
end

-- A new install: the hard drive with the most free space, if the files fit
-- (and its cc-ai folder is free: an install there would have been found)
if not DIR then
  for _, drive in ipairs(hardDrives()) do
    local target = absolute(fs.combine(drive.path, "cc-ai"))
    if drive.free and drive.free >= needed and not fs.exists(target) then
      DIR = target
      print("Installing to " .. DIR .. " (a hard drive with " .. kb(drive.free) .. " free).")
      break
    end
  end
  if not DIR then
    DIR = DEFAULT_DIR
    print("Installing to " .. DIR .. ".")
  end
  checkFolder(DIR)
end

-- Download everything into a staging directory first, so a failed download
-- (rate limit, network, full disk) leaves the previous install working
local STAGING = DIR .. ".download"
if fs.exists(STAGING) then
  fs.delete(STAGING)
end

-- The disk space a file or directory takes
local function diskSize(path)
  if not fs.isDir(path) then
    return math.max(fs.getSize(path), 500)
  end
  local total = 500
  for _, name in ipairs(fs.list(path)) do
    total = total + diskSize(fs.combine(path, name))
  end
  return total
end

-- The arguments an install in dir needs to update from the same source.
-- None for cc-ai's own: <dir>/install finds its own folder. For another
-- repository or branch, also the folder: its installer may be older.
local DEFAULT_SOURCE = REPO == "mindbound/cc-ai" and BRANCH == "master"
local function whereFor(dir)
  if DEFAULT_SOURCE then
    return ""
  end
  return " " .. REPO .. " " .. BRANCH .. (dir ~= DEFAULT_DIR and (" " .. dir) or "")
end
local where = whereFor(DIR)

-- A hard drive that DIR is not on, with size bytes free and no cc-ai
-- folder of that name yet: the drive and the folder cc-ai would move to
local function roomOnHardDrive(size)
  for _, drive in ipairs(hardDrives()) do
    if drive.free and drive.free >= size and not onDrive(DIR, drive) then
      local target = absolute(fs.combine(drive.path, fs.getName(DIR)))
      if not fs.exists(target) then
        return drive, target
      end
    end
  end
end

-- How to move this install to target (a folder on a hard drive). After
-- this install, its installer is this version, which finds its own folder
-- and has the set recorded. Before it (the not-enough-space error), the
-- installer in DIR is this version only when it is the one running: an
-- older one installs into /cc-ai unless given a folder, and an install
-- copied by hand has none. Then the command is this installer, from the
-- web, given the folder (a copy of an older one that GitHub may still
-- serve from its cache stops at the unknown --dir, changing nothing).
-- Not after this install: also this run's choice of --full or --minimal.
local function moveCommands(target, installed)
  local command
  if installed or OWN then
    command = target .. "/install" .. whereFor(target)
  else
    command = "wget run https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/install.lua"
    if not DEFAULT_SOURCE then
      command = command .. " " .. REPO .. " " .. BRANCH
    end
    command = command .. " --dir " .. target
  end
  if not installed and FULL ~= (PREVIOUS ~= nil and PREVIOUS.full == true) then
    command = command .. (FULL and " --full" or " --minimal")
  end
  return "mv " .. DIR .. " " .. target .. ", then " .. command
end

-- The previous install's entries that this one leaves out (examples/ and
-- tests/ when a full install becomes minimal). cc-code does not need them,
-- so they are deleted before the download and their space counts as free.
local dropped, freed = {}, 0
for name in pairs(INSTALL) do
  local path = fs.combine(DIR, name)
  if not installs(name) and fs.exists(path) then
    table.insert(dropped, path)
    freed = freed + diskSize(path)
  end
end

-- The skills folder. The installer records in .version what it put there
-- (its top-level entries), so the next update can tell cc-ai's files from
-- the user's.
local SKILLS = "lib/cc-code/skills"
local SKILLS_DIR = fs.combine(DIR, SKILLS)
local installedSkills = {}
do
  local seen = {}
  for _, path in ipairs(files) do
    local name = path:match("^lib/cc%-code/skills/([^/]+)")
    if name and not seen[name] then
      seen[name] = true
      table.insert(installedSkills, name)
    end
  end
  table.sort(installedSkills)
end

-- What the previous install put into the skills folder (a set), or nil if
-- it did not record it (an older installer, or no .version)
local function previousSkills()
  if not PREVIOUS or type(PREVIOUS.skills) ~= "table" then return nil end
  local set = {}
  for _, name in ipairs(PREVIOUS.skills) do
    if type(name) == "string" then
      set[name] = true
    end
  end
  return set
end

-- The disk space the user's files in the skills folder will take when
-- they are copied into the new install (see below)
do
  local before = previousSkills()
  local installed = {}
  for _, name in ipairs(installedSkills) do
    installed[name] = true
  end
  local kept = 0
  if fs.isDir(SKILLS_DIR) then
    for _, name in ipairs(fs.list(SKILLS_DIR)) do
      local fromCcAi
      if before then
        fromCcAi = before[name]
      else
        fromCcAi = installed[name]
      end
      if not fromCcAi then
        kept = kept + diskSize(fs.combine(SKILLS_DIR, name))
      end
    end
  end
  if kept > 0 then
    -- Folders on the way that the new install doesn't have yet
    local dir = SKILLS
    while dir ~= "" and not dirs[dir] do
      kept = kept + 500
      dir = fs.getDir(dir)
    end
  end
  needed = needed + kept
end

-- Stop before changing anything if the new files don't fit next to the
-- previous install (the download would fail with "Out of space"). When
-- they fit only without the Basalt UI's download (vendor/), that is
-- deleted too: as a last resort, because it is downloaded again.
local VENDOR_DIR = fs.combine(DIR, VENDOR)
local dropVendor = false
do
  local ok, free = pcall(fs.getFreeSpace, existingAncestor(fs.getDir(DIR)))
  if ok and type(free) == "number" and needed > free + freed then
    if fs.exists(VENDOR_DIR) and needed <= free + freed + diskSize(VENDOR_DIR) then
      dropVendor = true
    else
      local message = ("Not enough disk space: the %s install needs %d KB, but only %d KB are free."):format(
        SET, math.ceil(needed / 1000), math.floor((free + freed) / 1000))
      if FULL then
        message = message .. " Free some space, or leave out the tests and examples:" ..
          " run the installer with --minimal."
      else
        message = message .. " Free some space and run the installer again."
      end
      -- A hard drive with room: for the install and the new files, or for
      -- the new files of a new install
      if fs.exists(DIR) then
        local drive, target = roomOnHardDrive(diskSize(DIR) + needed)
        if drive then
          message = message .. " Or move cc-ai to the hard drive at " .. drive.path .. " (" .. kb(drive.free) ..
            " free): " .. moveCommands(target) .. "."
        end
      else
        local drive, target = roomOnHardDrive(needed)
        if drive then
          message = message .. " Or install it on the hard drive at " .. drive.path .. " (" .. kb(drive.free) ..
            " free): run the installer with --dir " .. target .. "."
        end
      end
      error(message .. " Nothing was changed.", 0)
    end
  end
end

for _, path in ipairs(dropped) do
  fs.delete(path)
end
if dropVendor then
  -- (named by the bundle in it, else by the folder: a partial download)
  local bundle = fs.combine(VENDOR_DIR, "basalt.lua")
  local deleted = "/" .. (fs.exists(bundle) and bundle or VENDOR_DIR)
  fs.delete(VENDOR_DIR)
  print("Deleted " .. deleted .. " to make room; the Basalt UI downloads it again.")
end

local rawBase = "https://raw.githubusercontent.com/" .. REPO .. "/" .. REF .. "/"
local ok, err = pcall(function()
  local _, y = term.getCursorPos()
  for i, path in ipairs(files) do
    term.setCursorPos(1, y)
    term.clearLine()
    write(("[%d/%d] %s"):format(i, #files, path))
    local content = get(rawBase .. path, true)
    local target = fs.combine(STAGING, path)
    fs.makeDir(fs.getDir(target))
    local handle, openErr = fs.open(target, "wb")
    if not handle then
      error("Cannot write " .. target .. ": " .. tostring(openErr), 0)
    end
    handle.write(content)
    handle.close()
    _, y = term.getCursorPos()
  end
end)
print()
if not ok then
  if fs.exists(STAGING) then
    fs.delete(STAGING)
  end
  error(err, 0)
end

-- Files the user put into the installed skills folder (older docs said
-- to) are copied into the new install instead of being deleted with the
-- old lib/: every entry the previous install did not put there. (Without
-- its list: every entry the new commit does not have.) A file whose name
-- cc-ai now uses itself is kept under a name that does not load as a skill.
local keptSkills, renamedSkills = {}, {}
local keepOk, keepErr = pcall(function()
  if not fs.isDir(SKILLS_DIR) then return end
  local before = previousSkills()
  local own, clashing = {}, {}
  local names = fs.list(SKILLS_DIR)
  table.sort(names)
  for _, name in ipairs(names) do
    local upstream = fs.exists(fs.combine(STAGING, SKILLS .. "/" .. name))
    local fromCcAi
    if before then
      fromCcAi = before[name]
    else
      fromCcAi = upstream
    end
    if not fromCcAi then
      table.insert(upstream and clashing or own, name)
    end
  end
  if #own + #clashing == 0 then return end
  fs.makeDir(fs.combine(STAGING, SKILLS))
  for _, name in ipairs(own) do
    fs.copy(fs.combine(SKILLS_DIR, name), fs.combine(STAGING, SKILLS .. "/" .. name))
    table.insert(keptSkills, name)
  end
  for _, name in ipairs(clashing) do
    local newName, n = name .. ".user", 1
    while fs.exists(fs.combine(STAGING, SKILLS .. "/" .. newName)) do
      n = n + 1
      newName = name .. ".user" .. n
    end
    fs.copy(fs.combine(SKILLS_DIR, name), fs.combine(STAGING, SKILLS .. "/" .. newName))
    table.insert(keptSkills, newName)
    table.insert(renamedSkills, { from = name, to = newName })
  end
end)
if not keepOk then
  if fs.exists(STAGING) then
    fs.delete(STAGING)
  end
  error("Could not keep your files in /" .. SKILLS_DIR .. ": " .. tostring(keepErr), 0)
end

-- Replace the previous install's managed entries (removes stale files)
fs.makeDir(DIR)
for name in pairs(INSTALL) do
  local path = fs.combine(DIR, name)
  if fs.exists(path) then
    fs.delete(path)
  end
  local staged = fs.combine(STAGING, name)
  if fs.exists(staged) then
    fs.move(staged, path)
  end
end
fs.delete(STAGING)

-- Startup file: cc-code on the shell path, with completion for its options.
-- When the install is not where it was (it was moved to another drive, or
-- its drive is mounted under another name, such as /hdd2 instead of /hdd),
-- it looks for it as findInstall does. (The installer reads the line with
-- within and onDrive back.)
local binDir = DIR .. "/bin"
local startup
do
  local within, onOtherDrive = placeOf(DIR)
  startup = ([[
-- Added by the cc-ai installer: makes `cc-code` runnable from anywhere
local dir = "%s"
-- Not there: moved, or its drive has another name now. While its drive
-- is not mounted under its name, look on drives only (a copy on this
-- computer's own drive is not it), and keep dir if it is on none: the
-- drive may be attached a moment later.
if not fs.exists(dir .. "/bin/cc-code.lua") then
  local within, onDrive = "%s", %s
  local drive = dir:match("^/([^/]+)/")
  local missing = onDrive and drive ~= nil and not fs.exists(drive)
  -- Hard drives, other drives, folders on this computer's own drive
  local own, hdds, others = {}, {}, {}
  for _, name in ipairs(fs.list("/")) do
    if fs.getDrive(name) == fs.getDrive("") then
      table.insert(own, name)
    elseif name ~= "rom" then
      table.insert(name:match("^hdd%%d*$") and hdds or others, name)
    end
  end
  local places = {}
  if not onDrive then
    table.insert(places, "")
  end
  for _, list in ipairs(missing and { hdds, others } or { hdds, others, own }) do
    for _, name in ipairs(list) do
      table.insert(places, name)
    end
  end
  if onDrive and not missing then
    table.insert(places, "")
  end
  for _, place in ipairs(places) do
    local found = "/" .. fs.combine(place, within)
    if fs.exists(found .. "/bin/cc-code.lua") then
      dir = found
      break
    end
  end
end
local binDir = dir .. "/bin"
if not (":" .. shell.path() .. ":"):find(":" .. binDir .. ":", 1, true) then
  shell.setPath(shell.path() .. ":" .. binDir)
end
local completion = require("cc.completion")
shell.setCompletionFunction(fs.combine(binDir, "cc-code.lua"), function(_, index, text)
  return completion.choice(text, { "--model ", "--terminal", "--basalt", "--tui", "--monochrome", "--help" })
end)
]]):format(DIR, within, tostring(onOtherDrive))
end

-- Which commit is installed (cc-code shows it at startup), and for the next
-- update: what the installer put into the skills folder, and whether the
-- install is full
do
  local handle = fs.open(fs.combine(DIR, ".version"), "wb")
  if handle then
    handle.write(textutils.serialize({
      repo = REPO,
      branch = BRANCH,
      commit = COMMIT,
      installed = os.date("!%Y-%m-%d %H:%M UTC"),
      skills = installedSkills,
      full = FULL,
    }))
    handle.close()
  end
end

-- The command that updates this install
local installer = "/" .. fs.combine(DIR, "install")
print("Installed " .. #files .. " files (" .. SET .. ")" .. (COMMIT and (" from commit " .. COMMIT:sub(1, 7)) or "") ..
  ". Update later with: " .. installer .. where)
if not FULL then
  print("The tests and examples were left out to save disk space. To install them: " ..
    installer .. " --full" .. where)
end
if #keptSkills > 0 then
  print("Kept your files in /" .. SKILLS_DIR .. ": " .. table.concat(keptSkills, ", "))
  for _, rename in ipairs(renamedSkills) do
    print("cc-ai now has its own " .. rename.from .. ", so yours is kept as " .. rename.to ..
      " (it does not load as a skill).")
  end
  print("Move them to /.cc-code/skills, which updates never touch.")
end

-- When the next update may not fit on this disk: a hard drive with room
do
  local okFree, free = pcall(fs.getFreeSpace, DIR)
  if okFree and type(free) == "number" and free < needed then
    local onHardDrive = false
    for _, drive in ipairs(hardDrives()) do
      if onDrive(DIR, drive) then
        onHardDrive = true
      end
    end
    local drive, target
    if not onHardDrive then
      drive, target = roomOnHardDrive(diskSize(DIR) + needed)
    end
    if drive then
      print("This disk has " .. kb(free) .. " free, and the next update needs about " ..
        math.ceil(needed / 1000) .. " KB" ..
        ". The hard drive at " .. drive.path .. " has " .. kb(drive.free) .. " free: to move cc-ai there, run " ..
        moveCommands(target, true))
    end
  end
end

if fs.exists("/startup") and not fs.isDir("/startup") then
  -- A plain /startup file exists, so there is no startup directory to add to
  printError("Not adding " .. STARTUP .. ": /startup is a file.")
  print("Add this line to your startup file instead:")
  print("  shell.setPath(shell.path() .. \":" .. binDir .. "\")")
else
  fs.makeDir(fs.getDir(STARTUP))
  local handle = fs.open(STARTUP, "w")
  handle.write(startup)
  handle.close()
  -- Apply it to this shell session too
  shell.run(STARTUP)
  -- The startup file named another install before: take its bin folder
  -- (the one it names, and the one it found) off this session's path, so
  -- `cc-code` runs this install
  local oldBins = {}
  for _, old in ipairs({ STARTUP_DIR or DIR, IN_USE or DIR }) do
    if old ~= DIR then
      oldBins[fs.combine(old, "bin")] = true
    end
  end
  if next(oldBins) then
    local entries = {}
    for entry in (shell.path() .. ":"):gmatch("([^:]*):") do
      if entry == "" or not oldBins[fs.combine(entry, "")] then
        table.insert(entries, entry)
      end
    end
    shell.setPath(table.concat(entries, ":"))
  end
  if IN_USE and IN_USE ~= DIR and isInstall(IN_USE) then
    print("The startup file now names " .. DIR .. " instead of " .. IN_USE .. ". The install in " .. IN_USE ..
      " is no longer used here. If no other computer uses it, delete it with rm " .. IN_USE)
    -- Files of the user's in its skills folder: what its installer did not
    -- put there (without its list: what cc-ai does not have)
    local oldSkills = fs.combine(IN_USE, SKILLS)
    if fs.isDir(oldSkills) then
      local recorded
      local handle = fs.open(fs.combine(IN_USE, ".version"), "rb")
      if handle then
        local info = textutils.unserialize(handle.readAll() or "")
        handle.close()
        if type(info) == "table" and type(info.skills) == "table" then
          recorded = {}
          for _, name in ipairs(info.skills) do
            recorded[name] = true
          end
        end
      end
      if not recorded then
        recorded = {}
        for _, name in ipairs(installedSkills) do
          recorded[name] = true
        end
      end
      local mine = {}
      for _, name in ipairs(fs.list(oldSkills)) do
        if not recorded[name] then
          table.insert(mine, name)
        end
      end
      table.sort(mine)
      if #mine > 0 then
        print("Before you delete it, move your files in /" .. oldSkills .. " to /.cc-code/skills: " ..
          table.concat(mine, ", "))
      end
    end
  end
end

print("")
print("Set an API key, then run cc-code:")
print("  set AI_GATEWAY_API_KEY <key>")
print("Or use a provider directly, e.g. Google:")
print("  set GOOGLE_GENERATIVE_AI_API_KEY <key>")
print("  then in cc-code: /model google gemini-flash-latest")

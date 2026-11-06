-- cc-ai installer
-- In-game:  wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
-- Options:  install [--full | --minimal] [owner/repo] [branch] [directory]
-- Installs lib/, bin/, docs/ and this installer into /cc-ai (--full adds
-- examples/ and tests/, and the Basalt UI's code, which cc-code otherwise
-- downloads when it is used) and adds a startup file that puts cc-code on
-- the shell path. Update later by running /cc-ai/install, which keeps the
-- previous choice of --full or --minimal unless given another.
-- Every file comes from one commit: the branch is resolved to its commit
-- first, because raw.githubusercontent.com caches branch URLs for minutes
-- (an update right after a push could otherwise mix old and new files).

-- The options can be anywhere; the other arguments are read by position
local args, FULL = {}, nil
do
  local given = table.pack(...)
  local n = 0
  for i = 1, given.n do
    local value = given[i]
    if value == "--full" then
      FULL = true
    elseif value == "--minimal" then
      FULL = false
    elseif type(value) == "string" and value:sub(1, 1) == "-" then
      error("Unknown option " .. value .. " (use --full or --minimal)", 0)
    else
      n = n + 1
      args[n] = value
    end
  end
end
local REPO = args[1] or "mindbound/cc-ai"
local BRANCH = args[2] or "master"
local DIR = "/" .. fs.combine(args[3] or "/cc-ai", "")
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

-- What the previous install recorded in .version, or nil
local PREVIOUS
do
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

print("Installing cc-ai (" .. SET .. ") from " .. REPO .. " (" .. BRANCH .. ") to " .. DIR)

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
  local ok, free = pcall(fs.getFreeSpace, fs.getDir(DIR))
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

-- Startup file: cc-code on the shell path, with completion for its options
local binDir = fs.combine(DIR, "bin")
local startup = ([[
-- Added by the cc-ai installer: makes `cc-code` runnable from anywhere
local binDir = "/%s"
if not (":" .. shell.path() .. ":"):find(":" .. binDir .. ":", 1, true) then
  shell.setPath(shell.path() .. ":" .. binDir)
end
local completion = require("cc.completion")
shell.setCompletionFunction(fs.combine(binDir, "cc-code.lua"), function(_, index, text)
  return completion.choice(text, { "--model ", "--terminal", "--basalt", "--tui", "--monochrome", "--help" })
end)
]]):format(binDir)

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

-- The command that updates this install (with its repository, branch and
-- directory when they are not the defaults, which a bare run would use)
local installer = "/" .. fs.combine(DIR, "install")
local where = ""
if REPO ~= "mindbound/cc-ai" or BRANCH ~= "master" or DIR ~= "/cc-ai" then
  where = " " .. REPO .. " " .. BRANCH .. " " .. DIR
end
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

if fs.exists("/startup") and not fs.isDir("/startup") then
  -- A plain /startup file exists, so there is no startup directory to add to
  printError("Not adding " .. STARTUP .. ": /startup is a file.")
  print("Add this line to your startup file instead:")
  print("  shell.setPath(shell.path() .. \":/" .. binDir .. "\")")
else
  fs.makeDir(fs.getDir(STARTUP))
  local handle = fs.open(STARTUP, "w")
  handle.write(startup)
  handle.close()
  -- Apply it to this shell session too
  shell.run(STARTUP)
end

print("")
print("Set an API key, then run cc-code:")
print("  set AI_GATEWAY_API_KEY <key>")
print("Or use a provider directly, e.g. Google:")
print("  set GOOGLE_GENERATIVE_AI_API_KEY <key>")
print("  then in cc-code: /model google gemini-flash-latest")

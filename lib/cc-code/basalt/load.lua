-- cc-code/basalt/load.lua
-- Gets what the Basalt UI (a trial) needs, and loads Basalt. A minimal
-- install has neither the Basalt bundle (vendor/basalt.lua; no install has
-- it) nor the Basalt UI's own files (app.lua, ui.lua and log.lua next to
-- this one): they are downloaded here the first time someone uses the
-- Basalt UI, from the commit of cc-ai that is installed. An update deletes
-- the UI's files with lib/, so they are downloaded again from the new
-- commit. It leaves the bundle in place, unless the new files fit on the
-- disk only without it.

local text = require("cmn-utils.text")

local M = {}

-- The bundle cc-code needs, as its header names it: the Basalt fork commit
-- it was built from ("-- Commit:"), and the "-- Elements:" and
-- "-- Modules:" lines, which tell builds of one commit apart. A rebuilt
-- vendor/basalt.lua needs these updated (a test checks that they match the
-- repository's bundle).
M.COMMIT = "d436223dd1fd74ab7bdb64694a680d972cc86357"
M.ELEMENTS = "Canvas, Collection, Frame, Input, Label, List"
M.MODULES = "none"

-- Where the bundle lives, relative to the install root
M.PATH = "vendor/basalt.lua"

-- The Basalt UI's files that a minimal install leaves out (install.lua
-- has the same list), relative to the install root
M.UI_FILES = {
  "lib/cc-code/basalt/app.lua",
  "lib/cc-code/basalt/ui.lua",
  "lib/cc-code/basalt/log.lua",
}

-- Where the files are downloaded from without a .version (a copy, not
-- installed by install.lua)
local DEFAULT_REPO = "mindbound/cc-ai"
local DEFAULT_BRANCH = "master"

-- The header (MIT notice included) is well inside this many bytes
local HEADER_BYTES = 2048

-- The install's root directory (".../cc-ai"), found from this file
local installRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/lib/cc%-code/basalt/load%.lua$")

-- The fork commit named in the start of a bundle, or nil. A build with
-- uncommitted changes ("-- Commit: <sha> (with uncommitted changes)") or
-- from a shallow clone names none.
local function headerCommit(head)
  if type(head) ~= "string" then return nil end
  return ("\n" .. head):match("\n%-%- Commit: (%x+)\r?\n")
end

-- The rest of the header line "-- <name>: ..." in the start of a bundle,
-- or nil
local function headerLine(head, name)
  if type(head) ~= "string" then return nil end
  return ("\n" .. head):match("\n%-%- " .. name .. ": ([^\r\n]*)\r?\n")
end

-- Why the start of a bundle is not the build cc-code needs (to follow "the
-- bundle"), or nil when it is
local function mismatch(head)
  local commit = headerCommit(head)
  if commit ~= M.COMMIT then
    return "is for Basalt " .. (commit and commit:sub(1, 7) or "(no commit)") .. ", not " .. M.COMMIT:sub(1, 7)
  end
  local elements = headerLine(head, "Elements")
  if elements ~= M.ELEMENTS then
    return "has the elements " .. (elements or "(none named)") .. ", not " .. M.ELEMENTS
  end
  local modules = headerLine(head, "Modules")
  if modules ~= M.MODULES then
    return "has the modules " .. (modules or "(none named)") .. ", not " .. M.MODULES
  end
  return nil
end

-- The start of a file, or nil
local function readHead(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local head = handle.read(HEADER_BYTES)
  handle.close()
  return head
end

-- The fork commit named in a bundle file's header, or nil
function M.fileCommit(path)
  return headerCommit(readHead(path))
end

-- Whether the bundle file at path is the build cc-code needs: its header
-- names COMMIT, ELEMENTS and MODULES
function M.fileMatches(path)
  local head = readHead(path)
  return head ~= nil and mismatch(head) == nil
end

-- The repository and ref to download from: what the installer recorded in
-- <root>/.version (the installed commit, else its branch), else cc-ai's
-- master branch
local function source(root)
  local repo, ref = DEFAULT_REPO, DEFAULT_BRANCH
  local handle = fs.open(fs.combine(root, ".version"), "rb")
  if not handle then return repo, ref end
  local info = textutils.unserialize(handle.readAll() or "")
  handle.close()
  if type(info) ~= "table" then return repo, ref end
  if type(info.repo) == "string" and info.repo:match("^[%w%-%._]+/[%w%-%._]+$") then
    repo = info.repo
  end
  if type(info.commit) == "string" and info.commit:match("^%x+$") then
    ref = info.commit
  elseif type(info.branch) == "string" and info.branch:match("^[%w%-%._/]+$") then
    ref = info.branch
  end
  return repo, ref
end

-- The body of a GET request, or nil and why it failed. Ctrl+T while
-- waiting is raised, so it ends the program.
local function download(url)
  local ok, response, err, failed = pcall(http.get, url, nil, true)
  if not ok then
    if response == "Terminated" then error(response, 0) end
    return nil, tostring(response)
  end
  if not response then
    local reason = tostring(err or "no reply")
    local code = failed and failed.getResponseCode and failed.getResponseCode()
    if failed and failed.close then pcall(failed.close) end
    if code and not reason:find(tostring(code), 1, true) then
      reason = code .. " " .. reason
    end
    return nil, reason
  end
  local body = response.readAll()
  response.close()
  return body or ""
end

-- Why a downloaded file can't be used, or nil when it can: the bundle must
-- be the build cc-code needs, and the UI's files must be Lua (not, say, an
-- error page)
local function problem(rel, body)
  if rel == M.PATH then
    local why = mismatch(body:sub(1, HEADER_BYTES))
    return why and ("the downloaded " .. rel .. " " .. why)
  end
  if not body:find("%S") then
    return "the downloaded " .. rel .. " is empty"
  end
  local chunk, err = load(body, "=" .. rel, "t", {})
  if not chunk then
    return "the downloaded " .. rel .. " is not Lua: " .. tostring(err)
  end
  return nil
end

-- Free bytes where path is, or nil when unknown or unlimited
local function freeSpace(path)
  local ok, free = pcall(fs.getFreeSpace, path)
  if ok and type(free) == "number" then return free end
  return nil
end

-- The disk space CC: Tweaked charges for a file of this many bytes
local function charged(size)
  return math.max(size, 500)
end

-- Download the files in list (paths relative to root) and put them in
-- place. Returns true, or nil and why not. Nothing is written unless every
-- file arrived and can be used and all of them fit on the disk. Each is
-- written under a temporary name, and the temporary files are moved into
-- place when all are written, so a failure leaves no partial file.
local function fetch(root, list, status)
  local paths, names = {}, {}
  for i, rel in ipairs(list) do
    local path = "/" .. fs.combine(root, rel)
    if fs.isReadOnly(path) then
      return nil, "/" .. fs.getDir(path) .. " is read-only"
    end
    if fs.isDir(path) then
      return nil, path .. " is a folder"
    end
    paths[i], names[i] = path, fs.getName(rel)
  end
  if type(http) ~= "table" or type(http.get) ~= "function" then
    return nil, "the HTTP API is disabled"
  end

  local repo, ref = source(root)
  local from = repo .. "@" .. (ref:match("^%x+$") and ref:sub(1, 7) or ref)
  if status then
    status("Downloading the Basalt UI (" .. table.concat(names, ", ") .. " from " .. from .. ")...")
  end
  local bodies, sizes = {}, {}
  for i, rel in ipairs(list) do
    local body, err = download("https://raw.githubusercontent.com/" .. repo .. "/" .. ref .. "/" .. rel)
    if not body then
      return nil, "download of " .. rel .. " from " .. from .. " failed: " .. err
    end
    local why = problem(rel, body)
    if why then
      return nil, why
    end
    bodies[i], sizes[i] = body, text.byteLen(body)
  end

  -- Temporary files left by an earlier attempt that was cut off
  local temps = {}
  for i, path in ipairs(paths) do
    temps[i] = path .. ".download"
    if fs.exists(temps[i]) then pcall(fs.delete, temps[i]) end
  end

  -- Room for the new files and the folders they need. A file already in
  -- place (a bundle of another build: the UI's files are downloaded only
  -- when missing) can't be used, so its space counts as free.
  local needed, old, newDirs, seen = 0, 0, {}, {}
  for i, path in ipairs(paths) do
    needed = needed + charged(sizes[i])
    if fs.exists(path) then
      old = old + charged(fs.getSize(path))
    end
    local dir = fs.getDir(path)
    while dir ~= "" and not fs.exists(dir) and not seen[dir] do
      seen[dir] = true
      newDirs[#newDirs + 1] = dir
      needed = needed + 500
      dir = fs.getDir(dir)
    end
  end
  -- (deepest first, for removing them again after a failure)
  table.sort(newDirs, function(a, b) return text.byteLen(a) > text.byteLen(b) end)
  local free = freeSpace(root)
  if free and free < needed then
    if free + old < needed then
      return nil, "not enough disk space for the Basalt UI (needs " .. needed .. " bytes, " ..
        (free + old) .. " free)"
    end
    for _, path in ipairs(paths) do
      if fs.exists(path) then fs.delete(path) end
    end
  end

  local current
  local saved, saveErr = pcall(function()
    for i, path in ipairs(paths) do
      current = list[i]
      fs.makeDir(fs.getDir(path))
      local handle, openErr = fs.open(temps[i], "wb")
      if not handle then
        error(openErr or ("can't open " .. temps[i]), 0)
      end
      local wrote, writeErr = pcall(handle.write, bodies[i])
      local closed, closeErr = pcall(handle.close)
      if not wrote then error(writeErr, 0) end
      if not closed then error(closeErr, 0) end
      if fs.getSize(temps[i]) ~= sizes[i] then
        error("the disk is full", 0)
      end
    end
    for i, path in ipairs(paths) do
      current = list[i]
      if fs.exists(path) then fs.delete(path) end
      fs.move(temps[i], path)
    end
  end)
  if not saved then
    for _, temp in ipairs(temps) do
      pcall(fs.delete, temp)
    end
    -- The folders made for them, when nothing else is in them
    for _, dir in ipairs(newDirs) do
      if fs.isDir(dir) and #fs.list(dir) == 0 then pcall(fs.delete, dir) end
    end
    return nil, "could not save " .. tostring(current) .. ": " .. tostring(saveErr)
  end
  return true
end

-- Load the bundle at path: the Basalt API, or nil and why not. The
-- bundle's modules run in this module's environment (the program's), so
-- they see the same globals as cc-code.
local function run(path)
  local handle = fs.open(path, "rb")
  if not handle then
    return nil, "can't read " .. path
  end
  local code = handle.readAll() or ""
  handle.close()
  local chunk, err = load(code, "@" .. path, "t", _ENV)
  if not chunk then
    return nil, "could not load " .. M.PATH .. ": " .. tostring(err)
  end
  local ok, basalt = pcall(chunk)
  if not ok then
    return nil, "could not load " .. M.PATH .. ": " .. tostring(basalt)
  end
  if type(basalt) ~= "table" or type(basalt.update) ~= "function" or type(basalt.cleanup) ~= "function"
    or type(basalt.setReactiveStrings) ~= "function" then
    return nil, M.PATH .. " is not the Basalt build cc-code needs"
  end
  -- Text in element properties is shown as given: "{...}" (which model
  -- replies contain) would otherwise be run as Lua
  basalt.setReactiveStrings(false)
  return basalt
end

-- The Basalt API from <install root>/vendor/basalt.lua. Downloaded first,
-- in one go: the bundle when it is missing or another build, and the
-- Basalt UI's files (M.UI_FILES) that are missing. Returns nil and a short
-- reason when it can't be had (no HTTP API, a failed download, a bundle of
-- another build, no disk space, a load error); nothing is written then.
-- opts.root: the install root (default: found from this file's path)
-- opts.status: called with a line to show before a download starts
function M.load(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("load: opts must be a table", 2)
  end
  opts = opts or {}
  local root = opts.root or installRoot
  if type(root) ~= "string" then
    return nil, "can't tell where cc-ai is installed"
  end
  local path = "/" .. fs.combine(root, M.PATH)
  local wanted = {}
  if not M.fileMatches(path) then
    wanted[#wanted + 1] = M.PATH
  end
  for _, rel in ipairs(M.UI_FILES) do
    if not fs.exists("/" .. fs.combine(root, rel)) then
      wanted[#wanted + 1] = rel
    end
  end
  if #wanted > 0 then
    local ok, err = fetch(root, wanted, opts.status)
    if not ok then
      return nil, err
    end
  end
  return run(path)
end

return M

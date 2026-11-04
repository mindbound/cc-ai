-- cmn-utils/path.lua
-- Path helpers for CraftOS (fs API paths have no leading slash; we return
-- absolute paths with one for readability)

local path = {}

-- Current shell directory as an absolute path ("/" for the root)
function path.cwd()
  local dir = shell and shell.dir() or ""
  return "/" .. dir
end

-- Resolve a path relative to the shell's working directory.
-- Returns an absolute path such as "/programs/foo.lua" ("/" for the root).
function path.resolve(p)
  if not p or p == "" or p == "." then
    return path.cwd()
  end
  local resolved
  if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then
    resolved = fs.combine(p, "")
  elseif shell then
    resolved = shell.resolve(p)
  else
    resolved = fs.combine(p, "")
  end
  return "/" .. resolved
end

-- Join a directory and an entry name into an absolute path
function path.join(dir, name)
  return "/" .. fs.combine(dir, name)
end

-- Yield briefly so long scans don't hit "Too long without yielding".
-- Call often; it only actually yields every few hundred calls.
local counter = 0
function path.maybeYield()
  counter = counter + 1
  if counter >= 200 then
    counter = 0
    os.queueEvent("cmn_utils_yield")
    os.pullEvent("cmn_utils_yield")
  end
end

-- Directories skipped when a recursive scan starts at the root, because they
-- are read-only system files (/rom) the user rarely means to search
path.rootSkip = { rom = true }

return path

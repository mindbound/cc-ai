-- cmn-utils/glob.lua
-- File pattern matching utility for CraftOS

local path = require("cmn-utils.path")

local glob = {}

local function escape(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
end

-- Convert glob pattern to a single Lua pattern ("**" = any characters)
local function globToPattern(globPat)
  local pat = escape(globPat)
  pat = pat:gsub("%*%*", "\001")
  pat = pat:gsub("%*", "[^/]*")
  pat = pat:gsub("\001", ".*")
  return "^" .. pat .. "$"
end

-- Convert a glob to the Lua patterns that together implement it. "**/" may
-- match zero or more directories ("**/*.lua" also matches "startup.lua"),
-- which one Lua pattern can't express, so each "**/" doubles the variants.
local function globToPatterns(globPat)
  local variants = { "" }
  local function append(s)
    for i = 1, #variants do
      variants[i] = variants[i] .. s
    end
  end
  local i = 1
  while i <= #globPat do
    if globPat:sub(i, i + 2) == "**/" then
      local nextVariants = {}
      for _, v in ipairs(variants) do
        table.insert(nextVariants, v)
        table.insert(nextVariants, v .. ".*/")
      end
      variants = nextVariants
      i = i + 3
    elseif globPat:sub(i, i + 1) == "**" then
      append(".*")
      i = i + 2
    elseif globPat:sub(i, i) == "*" then
      append("[^/]*")
      i = i + 1
    else
      append(escape(globPat:sub(i, i)))
      i = i + 1
    end
  end
  for j = 1, #variants do
    variants[j] = "^" .. variants[j] .. "$"
  end
  return variants
end

local function matchesAny(str, patterns)
  for _, pat in ipairs(patterns) do
    if str:match(pat) then
      return true
    end
  end
  return false
end

-- Find files matching a glob pattern
-- @param pattern string: Glob pattern (e.g., "*.lua", "lib/**/*.lua")
-- @param basePath string: Starting directory (default: current directory)
-- @return table: { path = basePath, pattern = pattern, matches = {...} }
function glob.find(pattern, basePath)
  basePath = path.resolve(basePath or ".")
  local matches = {}
  local patterns = globToPatterns(pattern)
  local fromRoot = basePath == "/"

  local function walk(dir, prefix)
    if not fs.isDir(dir) then return end
    for _, entry in ipairs(fs.list(dir)) do
      path.maybeYield()
      local fullPath = path.join(dir, entry)
      local relPath = prefix == "" and entry or (prefix .. "/" .. entry)
      if fs.isDir(fullPath) then
        -- Skip /rom when scanning from the root (read-only system files)
        if not (fromRoot and prefix == "" and path.rootSkip[entry]) then
          walk(fullPath, relPath)
        end
      elseif matchesAny(relPath, patterns) then
        table.insert(matches, relPath)
      end
    end
  end

  walk(basePath, "")
  table.sort(matches)
  return { path = basePath, pattern = pattern, matches = matches }
end

-- Check if a filename matches a glob pattern
-- @param name string: Filename to check
-- @param pattern string: Glob pattern (e.g., "*.lua")
-- @return boolean: True if matches
function glob.match(name, pattern)
  if not pattern then return true end
  local pat = escape(pattern)
  pat = pat:gsub("%*", ".*")
  return name:match("^" .. pat .. "$") ~= nil
end

-- Convert glob to Lua pattern (exposed for advanced use)
glob.toPattern = globToPattern

return glob

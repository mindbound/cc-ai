-- cmn-utils/glob.lua
-- File pattern matching utility for CraftOS

local path = require("cmn-utils.path")
local byteLen = require("cmn-utils.text").byteLen

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

-- Expand {a,b} alternatives: "*.{lua,txt}" gives "*.lua" and "*.txt".
-- Several groups multiply; groups don't nest. Braces without a comma in
-- them are plain text.
local function expandBraces(globPat)
  local open = globPat:find("{", 1, true)
  local close = open and globPat:find("}", open + 1, true)
  if not close then
    return { globPat }
  end
  local before, inner = globPat:sub(1, open - 1), globPat:sub(open + 1, close - 1)
  local tails = expandBraces(globPat:sub(close + 1))
  local alternatives = { "{" .. inner .. "}" }
  if inner:find(",", 1, true) then
    alternatives = {}
    for alternative in (inner .. ","):gmatch("([^,]*),") do
      alternatives[#alternatives + 1] = alternative
    end
  end
  local out = {}
  for _, alternative in ipairs(alternatives) do
    for _, tail in ipairs(tails) do
      out[#out + 1] = before .. alternative .. tail
    end
  end
  return out
end

-- Paths are matched relative to the search directory: a leading "./" or
-- "/" means that directory, and a trailing "/" everything under a folder
local function normalise(globPat)
  repeat
    local before = globPat
    globPat = globPat:gsub("^%./", ""):gsub("^/+", "")
  until globPat == before
  if globPat == "" or globPat == "." then
    return "**"
  end
  if globPat:sub(-1) == "/" then
    return globPat .. "**"
  end
  return globPat
end

-- Convert one glob alternative (no braces) to the Lua patterns that
-- together implement it. "**/" may match zero or more directories
-- ("**/*.lua" also matches "startup.lua"), which one Lua pattern can't
-- express, so each "**/" doubles the variants.
local function alternativeToPatterns(globPat)
  local variants = { "" }
  local function append(s)
    for i = 1, #variants do
      variants[i] = variants[i] .. s
    end
  end
  local i = 1
  local patLen = byteLen(globPat)
  while i <= patLen do
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
    elseif globPat:sub(i, i) == "?" then
      append("[^/]")
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

-- A glob's alternatives, each { patterns = {...}, path = bool }. path: the
-- alternative has a "/", so it is meant for paths, not file names.
local function compile(globPat)
  local alternatives = {}
  for _, alternative in ipairs(expandBraces(globPat)) do
    alternatives[#alternatives + 1] = {
      patterns = alternativeToPatterns(normalise(alternative)),
      path = alternative:find("/", 1, true) ~= nil,
    }
  end
  return alternatives
end

-- Convert a glob to the Lua patterns that together implement it (a path
-- matches the glob when it matches any of them)
local function globToPatterns(globPat)
  local patterns = {}
  for _, alternative in ipairs(compile(globPat)) do
    for _, pat in ipairs(alternative.patterns) do
      patterns[#patterns + 1] = pat
    end
  end
  return patterns
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
  if type(pattern) ~= "string" or pattern == "" then
    return { error = "pattern must be a non-empty string" }
  end
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

-- A function(relPath, name) that tells whether a file matches a glob, as
-- grep's filter: a glob with a "/" ("lib/**/*.lua") is matched against the
-- path relative to the search directory; one without ("*.lua") against the
-- file name, at any depth (like ripgrep). With {a,b}, each alternative is
-- matched its own way. No glob matches everything.
function glob.matcher(pattern)
  if not pattern or pattern == "" then
    return function() return true end
  end
  local alternatives = compile(pattern)
  return function(relPath, name)
    for _, alternative in ipairs(alternatives) do
      if matchesAny(alternative.path and relPath or name, alternative.patterns) then
        return true
      end
    end
    return false
  end
end

-- Convert glob to Lua pattern(s) (exposed for advanced use)
glob.toPattern = globToPattern
glob.toPatterns = globToPatterns

return glob

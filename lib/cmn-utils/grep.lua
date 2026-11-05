-- cmn-utils/grep.lua
-- File content search utility for CraftOS

local path = require("cmn-utils.path")
local cmnGlob = require("cmn-utils.glob")

local grep = {}

-- Escape special pattern characters for literal search
local function escapeLiteral(str)
  return (str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Iterate over the lines of a file (raw bytes, CR stripped)
local function fileLines(filePath)
  local handle = fs.open(filePath, "rb")
  if not handle then return nil end
  return function()
    if not handle then return nil end
    local line = handle.readLine()
    if line == nil then
      handle.close()
      handle = nil
      return nil
    end
    return (line:gsub("\r$", ""))
  end, function()
    if handle then
      handle.close()
      handle = nil
    end
  end
end

-- Search for pattern in files
-- @param pattern string: Lua pattern or literal string to search for
-- @param opts table: Options
--   - path: File or directory to search (default: current directory)
--   - glob: Only search files matching this glob pattern (e.g., "*.lua")
--   - literal: Treat pattern as literal string (default: false)
--   - maxResults: Maximum number of results (default: 50)
--   - maxLineLength: Maximum line length to return (default: 200)
-- @return table: { pattern, results = {...}, truncated = bool }
function grep.search(pattern, opts)
  opts = opts or {}
  local basePath = path.resolve(opts.path or ".")
  local maxResults = opts.maxResults or 50
  local maxLineLength = opts.maxLineLength or 200
  local results = {}
  local fromRoot = basePath == "/"
  local globPattern = opts.glob
  if globPattern ~= nil and type(globPattern) ~= "string" then
    return { error = "glob must be a string" }
  end
  if globPattern == "" then
    globPattern = nil
  end
  -- A glob with a "/" picks files by their path under a search directory;
  -- a search of one file ignores it
  if globPattern and globPattern:find("/", 1, true) and fs.exists(basePath) and not fs.isDir(basePath) then
    globPattern = nil
  end
  -- matches(relPath, name): the glob filter ("**/*.lua" or "*.lua")
  local globMatches = cmnGlob.matcher(globPattern)
  -- Files the glob let through, so a glob that matches nothing is told
  -- apart from a pattern that is not found
  local filesMatched = 0
  local function matches(relPath, name)
    if globMatches(relPath, name) then
      filesMatched = filesMatched + 1
      return true
    end
    return false
  end

  if opts.literal then
    pattern = escapeLiteral(pattern)
  end

  -- Validate the pattern once so a bad one gives a clear error
  local ok, err = pcall(string.find, "", pattern)
  if not ok then
    return { error = "Invalid Lua pattern: " .. tostring(err) }
  end

  local function searchFile(filePath, relPath)
    local nextLine, close = fileLines(filePath)
    if not nextLine then return end
    local lineNum = 0
    for line in nextLine do
      lineNum = lineNum + 1
      path.maybeYield() -- (it yields only every few hundred calls)
      -- Some malformed patterns ("a[") only fail once a line reaches them
      local okFind, found = pcall(string.find, line, pattern)
      if not okFind then
        close()
        error("Invalid Lua pattern: " .. (tostring(found):gsub("^.-:%d+: ", "")), 0)
      end
      if found then
        table.insert(results, {
          file = relPath,
          line = lineNum,
          content = line:sub(1, maxLineLength),
        })
        if #results >= maxResults then
          close()
          return true
        end
      end
    end
  end

  local function walk(dir, prefix)
    if not fs.isDir(dir) then
      -- Single file
      if matches(prefix, fs.getName(dir)) then
        searchFile(dir, prefix)
      end
      return
    end
    for _, entry in ipairs(fs.list(dir)) do
      path.maybeYield()
      local fullPath = path.join(dir, entry)
      local relPath = prefix == "" and entry or (prefix .. "/" .. entry)
      if fs.isDir(fullPath) then
        if not (fromRoot and prefix == "" and path.rootSkip[entry]) then
          walk(fullPath, relPath)
        end
      else
        if matches(relPath, entry) then
          if searchFile(fullPath, relPath) then
            return -- Max results reached
          end
        end
      end
      if #results >= maxResults then return end
    end
  end

  if not fs.exists(basePath) then
    return { error = "Path not found: " .. basePath }
  end
  local okWalk, walkErr = pcall(walk, basePath, fs.isDir(basePath) and "" or fs.getName(basePath))
  if not okWalk then
    if walkErr == "Terminated" then error(walkErr, 0) end
    return { error = tostring(walkErr) }
  end
  local note
  if globPattern and filesMatched == 0 then
    note = "No file matched the glob \"" .. globPattern .. "\", so no file was searched."
    if fromRoot then
      note = note .. " (A search from / skips /rom: search path /rom for it.)"
    end
  end
  return {
    pattern = opts.literal and ("literal: " .. pattern) or pattern,
    results = results,
    truncated = #results >= maxResults,
    note = note,
  }
end

-- Search in a single file
-- @param pattern string: Pattern to search for
-- @param filePath string: Path to file
-- @param opts table: Options (literal, maxResults, maxLineLength)
-- @return table: Array of { line, content } matches
function grep.searchFile(pattern, filePath, opts)
  opts = opts or {}
  local filePathAbs = path.resolve(filePath)
  local maxResults = opts.maxResults or 50
  local maxLineLength = opts.maxLineLength or 200
  local results = {}

  if opts.literal then
    pattern = escapeLiteral(pattern)
  end

  local nextLine, close = fileLines(filePathAbs)
  if not nextLine then
    return nil, "Cannot open file: " .. filePathAbs
  end

  local lineNum = 0
  for line in nextLine do
    lineNum = lineNum + 1
    if line:find(pattern) then
      table.insert(results, {
        line = lineNum,
        content = line:sub(1, maxLineLength),
      })
      if #results >= maxResults then
        break
      end
    end
  end
  close()
  return results
end

-- Expose helper for literal escaping
grep.escapeLiteral = escapeLiteral

return grep

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
      if lineNum % 200 == 0 then path.maybeYield() end
      if line:find(pattern) then
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
      if cmnGlob.match(fs.getName(dir), opts.glob) then
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
        if cmnGlob.match(entry, opts.glob) then
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
  walk(basePath, fs.isDir(basePath) and "" or fs.getName(basePath))
  return {
    pattern = opts.literal and ("literal: " .. pattern) or pattern,
    results = results,
    truncated = #results >= maxResults
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

-- cmn-utils/init.lua
-- Common utilities for CraftOS
-- Provides glob (file pattern matching), grep (content search), json,
-- text (UTF-8 <-> CC charset) and path helpers

local cmnUtils = {}

-- Lazy load submodules
local glob, grep, json

function cmnUtils.glob()
  if not glob then
    glob = require("cmn-utils.glob")
  end
  return glob
end

function cmnUtils.grep()
  if not grep then
    grep = require("cmn-utils.grep")
  end
  return grep
end

function cmnUtils.json()
  if not json then
    json = require("cmn-utils.json")
  end
  return json
end

function cmnUtils.text()
  return require("cmn-utils.text")
end

function cmnUtils.path()
  return require("cmn-utils.path")
end

-- Convenience shortcuts for common operations

-- Find files matching a glob pattern
-- @param pattern string: Glob pattern (e.g., "*.lua")
-- @param basePath string: Starting directory (optional)
-- @return table: { path, pattern, matches = {...} }
function cmnUtils.find(pattern, basePath)
  return cmnUtils.glob().find(pattern, basePath)
end

-- Search for pattern in files
-- @param pattern string: Search pattern
-- @param opts table: Options (path, glob, literal, maxResults)
-- @return table: { pattern, results = {...}, truncated }
function cmnUtils.search(pattern, opts)
  return cmnUtils.grep().search(pattern, opts)
end

-- Check if filename matches glob pattern
-- @param name string: Filename
-- @param pattern string: Glob pattern
-- @return boolean
function cmnUtils.match(name, pattern)
  return cmnUtils.glob().match(name, pattern)
end

-- JSON encode
-- @param val any: Value to encode
-- @return string: JSON string
function cmnUtils.encode(val)
  return cmnUtils.json().encode(val)
end

-- JSON decode
-- @param str string: JSON string to decode
-- @return any: Decoded value
function cmnUtils.decode(str)
  return cmnUtils.json().decode(str)
end

return cmnUtils

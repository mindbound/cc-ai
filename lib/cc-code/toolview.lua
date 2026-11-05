-- cc-code/toolview.lua
-- One-line summaries of tool calls for the UIs: what a call does
-- ("read foo.lua", "$ mine 3") and how it went ("120 lines", "failed: ...").
-- Arguments and results are UTF-8 (the UIs prepare them for display).

local json = require("cmn-utils.json")

local toolview = {}

-- A value as one line of text: newlines and tabs become spaces
local function oneLine(value)
  return (tostring(value):gsub("[\r\n\t]+", " "))
end

-- Compact JSON of a value, on one line
local function compact(value)
  if type(value) == "string" then
    return oneLine(value)
  end
  local ok, encoded = pcall(json.encode, value)
  return oneLine(ok and encoded or tostring(value))
end

-- "1 line", "2 lines"
local function count(n, singular, plural)
  n = tonumber(n) or 0
  return n .. " " .. (n == 1 and singular or plural)
end

-- "512 bytes", "1.2 KB"
local function size(bytes)
  bytes = tonumber(bytes)
  if not bytes then
    return "?"
  end
  if bytes < 1024 then
    return count(bytes, "byte", "bytes")
  end
  return ("%.1f KB"):format(bytes / 1024)
end

-- Is this a row the shell prints after an error message? It marks the
-- source context with a bullet ("\149", which is "?" in UTF-8, or U+2022)
-- and underlines with "\131" (also "?").
local function isErrorContext(line)
  local first = line:match("^%s*(.)")
  if not first then
    return false
  end
  local b = first:byte()
  return first == "?" or (b >= 128 and b <= 159) or line:find("^%s*\226\128\162") ~= nil
end

local function isBlank(line)
  return not line:find("%S")
end

-- The last line of output that is not blank. For a command that failed or
-- was stopped, the line that tells why. The shell's error printer shows
-- the message, then context rows (the source line and a marker, in CC
-- drawing characters), and sometimes a tip after them. So the reason is in
-- the group of lines right above the last block of context rows: its last
-- Lua error with a position ("/bad.lua:3: attempt to call ..."), else its
-- last line. Without context rows, the last line it printed.
local function lastLine(output, failure)
  if type(output) ~= "string" then
    return nil
  end
  local lines = {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local pick
  if failure then
    local block
    for i = #lines, 1, -1 do
      if not isBlank(lines[i]) and isErrorContext(lines[i]) then
        block = i
        break
      end
    end
    if block then
      -- Up to the first row of that block (blank lines don't end it)
      while block > 1 and (isErrorContext(lines[block - 1]) or isBlank(lines[block - 1])) do
        block = block - 1
      end
      local groupEnd = block - 1
      local i = groupEnd
      while i >= 1 and not isBlank(lines[i]) and not isErrorContext(lines[i]) do
        if not pick and lines[i]:find("^%s*%S+:%d+: ") then
          pick = lines[i]
        end
        i = i - 1
      end
      if not pick and groupEnd >= 1 then
        pick = lines[groupEnd]
      end
    end
  end
  if not pick then
    for i = #lines, 1, -1 do
      if not isBlank(lines[i]) and not (failure and isErrorContext(lines[i])) then
        pick = lines[i]
        break
      end
    end
  end
  return pick and (oneLine(pick):gsub("^%s+", "")) or nil
end

-- What a call does, e.g. "read foo.lua"
function toolview.call(name, args)
  if type(args) ~= "table" then
    args = {}
  end
  local function str(v)
    return v ~= nil and oneLine(v) or nil
  end
  local path = str(args.path)
  if name == "read_file" then
    return "read " .. (path or "?") .. (args.offset and (" from line " .. oneLine(args.offset)) or "")
  elseif name == "write_file" then
    return "write " .. (path or "?")
  elseif name == "edit_file" then
    return "edit " .. (path or "?")
  elseif name == "list_directory" then
    return "list " .. (path or ".")
  elseif name == "glob" then
    return "glob " .. (str(args.pattern) or "?") .. (path and (" in " .. path) or "")
  elseif name == "grep" then
    return "grep \"" .. (str(args.pattern) or "") .. "\"" .. (path and (" in " .. path) or "") ..
      (args.glob and (" (" .. oneLine(args.glob) .. ")") or "")
  elseif name == "shell" then
    return "$ " .. (str(args.command) or "?") .. ((args.screen == true or args.screen == "true") and " (screen)" or "")
  end
  local shown = next(args) ~= nil and (" " .. compact(args)) or ""
  return tostring(name) .. shown
end

-- The output line a shell result shows, if any (failure: the command
-- failed or was stopped)
local function shellLine(result, failure)
  local last = lastLine(result.output, failure)
  if last and last ~= "(no output)" and last ~= "(command failed, no output)" then
    return last
  end
  return nil
end

-- How a call went: the text, and whether it failed. A nil result (a tool
-- that returns nothing) is "done"; a result marked cancelled (the agent
-- marks a call stopped with Ctrl+T) is "stopped".
function toolview.result(name, result, args)
  if result == nil then
    return "done", false
  end
  if type(result) ~= "table" then
    return compact(result), false
  end
  if result.cancelled then
    local last = name == "shell" and shellLine(result, true)
    return "stopped (Ctrl+T)" .. (last and (": " .. last) or ""), false
  end
  if result.error ~= nil then
    return "error: " .. compact(result.error), true
  end
  if name == "read_file" then
    return count(result.totalLines, "line", "lines"), false
  elseif name == "write_file" then
    return size(result.bytesWritten), false
  elseif name == "edit_file" then
    return count(result.replacements, "replacement", "replacements"), false
  elseif name == "list_directory" then
    return count(type(result.entries) == "table" and #result.entries or 0, "entry", "entries"), false
  elseif name == "glob" then
    return count(type(result.matches) == "table" and #result.matches or 0, "file", "files"), false
  elseif name == "grep" then
    local n = type(result.results) == "table" and #result.results or 0
    return count(n, "match", "matches") .. (result.truncated and " (the limit)" or ""), false
  elseif name == "shell" then
    local screen = type(result.screen) == "table" and result.screen
    local status, failed
    if result.timedOut then
      status = "stopped at the timeout"
    elseif result.success == false then
      status, failed = "failed", true
    else
      status = "ok"
    end
    if screen then
      return status .. ", screen " .. tostring(screen.size), failed or false
    end
    local last = shellLine(result, status ~= "ok")
    if last then
      return status .. ": " .. last, failed or false
    end
    return status, failed or false
  end
  return compact(result), false
end

-- The whole line of a finished call: "read foo.lua - 120 lines" (a call
-- still running is shown with toolview.call alone)
function toolview.line(name, args, result)
  local outcome, failed = toolview.result(name, result, args)
  return toolview.call(name, args) .. " - " .. outcome, failed
end

-- The mark a tool line starts with: "!" for a failed call, so a failure
-- shows without colour too (basic computers), else "*"
function toolview.mark(failed)
  return failed and "!" or "*"
end

return toolview

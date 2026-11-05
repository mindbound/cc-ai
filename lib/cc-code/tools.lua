-- cc-code/tools.lua
-- Core tools for the cc-code agent (CraftOS compatible)

local ai = require("ai")
local cmnGlob = require("cmn-utils.glob")
local cmnGrep = require("cmn-utils.grep")
local cmnPath = require("cmn-utils.path")
local capture = require("cc-code.capture")
local secrets = require("cc-code.secrets")
local cctext = require("cmn-utils.text")
local byteLen = cctext.byteLen

local tools = {}

-- Shell tool limits: seconds a program may run (default and maximum), the
-- width of the terminal its output is recorded on, and how much output the
-- model gets (the start and the end: errors and summaries print last)
tools.SHELL_TIMEOUT = 20
tools.SHELL_MAX_TIMEOUT = 300
tools.SHELL_WIDTH = 160
local SHELL_HEAD_BYTES = 1000
local SHELL_TAIL_BYTES = 3000

-- How a screen=true result's colour rows read
tools.COLOUR_LEGEND = "One character per cell, as in term.blit: 0 white, 1 orange, 2 magenta, " ..
  "3 lightBlue, 4 yellow, 5 lime, 6 pink, 7 gray, 8 lightGray, 9 cyan, a purple, b blue, " ..
  "c brown, d green, e red, f black. background: rows of cell backgrounds, trailing black " ..
  "left out. textColour: the colour of each non-space character (spaces are blank). " ..
  "palette (if present): the slots the program set to another colour with " ..
  "term.setPaletteColour, as #rrggbb; for those slots the names above are wrong."

-- Tool results show secret values (API keys, tokens, passwords) as
-- secrets.REDACTED. Written back, that text would replace the secret.
local REDACTED = secrets.REDACTED
local REDACTED_MEANING = REDACTED .. " in tool results stands for a secret value " ..
  "(an API key, token or password) that is hidden from you."
local REDACTED_WRITE = " Writing it would put the text " .. REDACTED ..
  " in the file in place of the secret."

local function redactedError(what)
  if what == "command" then
    return "command contains " .. REDACTED .. ". " .. REDACTED_MEANING ..
      " Running the command would store or use the text " .. REDACTED .. " in place of the " ..
      "secret (`set NAME " .. REDACTED .. "` would replace the setting's value with it). " ..
      "To change a secret, ask the user. A program that needs a secret setting can read it " ..
      "with settings.get."
  elseif what == "old_string" then
    return "old_string contains " .. REDACTED .. ". " .. REDACTED_MEANING ..
      " The file has the real value there, so the text is not found. Use an old_string " ..
      "without " .. REDACTED .. ": edit only the text around the secret."
  elseif what == "new_string" then
    return "new_string contains " .. REDACTED .. ". " .. REDACTED_MEANING .. REDACTED_WRITE ..
      " Keep " .. REDACTED .. " out of old_string and new_string: edit only the text around the secret."
  end
  return "content contains " .. REDACTED .. ". " .. REDACTED_MEANING .. REDACTED_WRITE ..
    " To change a file that has a secret in it, use edit_file on the text around the secret. " ..
    "A program that needs a secret setting can read it with settings.get."
end

-- Helper: resolve path relative to working directory
local resolvePath = cmnPath.resolve

-- Helper: read a whole file as raw bytes (nil if it can't be opened)
local function readFile(path)
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local content = handle.readAll() or ""
  handle.close()
  return content
end

-- CC: Tweaked charges every file at least this much disk space
local MIN_FILE_SIZE = 500

-- Helper: write a whole file as raw bytes. Opening with "wb" empties the
-- file at once, and a write that then doesn't fit fails with nothing
-- written, so the space is checked first: a full disk must not leave the
-- user's file empty.
local function writeFile(path, content)
  local size = byteLen(content)
  local okFree, free = pcall(fs.getFreeSpace, fs.getDir(path))
  if okFree and type(free) == "number" then
    local oldSize = fs.exists(path) and not fs.isDir(path) and fs.getSize(path) or nil
    local growth = math.max(size, MIN_FILE_SIZE) - (oldSize and math.max(oldSize, MIN_FILE_SIZE) or 0)
    if growth > free then
      return false, ("not enough disk space: the file needs %d more bytes, %d are free"):format(growth, free)
    end
  end
  local handle, err = fs.open(path, "wb")
  if not handle then return false, err end
  local ok, writeErr = pcall(handle.write, content)
  handle.close()
  if not ok then return false, tostring(writeErr) end
  return true
end

-- Start positions of the non-overlapping occurrences of a plain string
local function findAll(content, str)
  local found, pos = {}, 1
  local len = byteLen(str)
  while true do
    local start = content:find(str, pos, true)
    if not start then return found end
    found[#found + 1] = start
    pos = start + len
  end
end

-- Convert line endings to LF
local function toLF(s)
  return (s:gsub("\r\n", "\n"))
end

-- A file as read_file shows it (the LF view: every "\r\n" as "\n"), and
-- the LF-view positions of the newlines that are "\r\n" in the file, in
-- order
local function lfView(content)
  local crlfAt = {}
  local pos = 1
  while true do
    local found = content:find("\r\n", pos, true)
    if not found then break end
    -- Each CRLF before this one lost its CR in the view
    crlfAt[#crlfAt + 1] = found - #crlfAt
    pos = found + 2
  end
  return toLF(content), crlfAt
end

-- Helper: read file with line numbers
local function readWithLineNumbers(content, offset, limit)
  local lines = {}
  local i = 0
  -- Make every line, including the last, end with "\n": this avoids
  -- gmatch's extra empty match at the end of the string
  local source = content:sub(-1) == "\n" and content or (content .. "\n")
  for line in source:gmatch("([^\n]*)\n") do
    i = i + 1
    if i >= offset then
      table.insert(lines, string.format("%4d\t%s", i, line))
    end
    if limit and #lines >= limit then
      break
    end
  end
  return table.concat(lines, "\n")
end

-- Helper: count lines in content
local function countLines(content)
  if content == "" then return 0 end
  local count = 0
  for _ in content:gmatch("\n") do
    count = count + 1
  end
  if content:sub(-1) ~= "\n" then
    count = count + 1
  end
  return count
end

-- Tool: Read file
tools.read_file = ai.tool({
  name = "read_file",
  description = "Read the contents of a file. Returns the file content with line numbers.",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Path to the file to read" },
      offset = { type = "number", description = "Line number to start reading from (default: 1)" },
      limit = { type = "number", description = "Maximum number of lines to read" },
    },
    required = { "path" },
  },
  execute = function(args)
    local path = resolvePath(args.path)
    if not fs.exists(path) then
      return { error = "File not found: " .. path }
    end
    if fs.isDir(path) then
      return { error = "Path is a directory: " .. path }
    end
    local content = readFile(path)
    if not content then
      return { error = "Cannot open file: " .. path }
    end
    content = content:gsub("\r\n", "\n")
    local offset = args.offset or 1
    local limit = args.limit
    return {
      path = path,
      content = readWithLineNumbers(content, offset, limit),
      totalLines = countLines(content)
    }
  end,
})

-- Tool: Write file
tools.write_file = ai.tool({
  name = "write_file",
  description = "Write content to a file, creating it if it doesn't exist or overwriting if it does.",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Path to the file to write" },
      content = { type = "string", description = "Content to write to the file" },
    },
    required = { "path", "content" },
  },
  execute = function(args)
    if type(args.content) ~= "string" then
      return { error = "content must be a string" }
    end
    local path = resolvePath(args.path)
    if fs.isReadOnly(path) then
      return { error = "Path is read-only: " .. path }
    end
    -- The model may copy the secret marker from a read result; that is
    -- only allowed when the file already has the marker text in it
    if args.content:find(REDACTED, 1, true) then
      local old = fs.exists(path) and not fs.isDir(path) and readFile(path) or nil
      if not (old and old:find(REDACTED, 1, true)) then
        return { error = redactedError("content") }
      end
    end
    -- Ensure parent directory exists
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= ".." and not fs.exists(dir) then
      fs.makeDir(dir)
    end
    local ok, err = writeFile(path, args.content)
    if not ok then
      return { error = "Cannot write to file: " .. path .. (err and (" (" .. err .. ")") or "") }
    end
    return { success = true, path = path, bytesWritten = byteLen(args.content) }
  end,
})

-- Tool: Edit file (string replacement)
tools.edit_file = ai.tool({
  name = "edit_file",
  description = "Edit a file by replacing an exact string match with new content. The old_string must be unique in the file.",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Path to the file to edit" },
      old_string = { type = "string", description = "The exact string to find and replace" },
      new_string = { type = "string", description = "The string to replace it with" },
      replace_all = { type = "boolean", description = "Replace all occurrences (default: false)" },
    },
    required = { "path", "old_string", "new_string" },
  },
  execute = function(args)
    local path = resolvePath(args.path)
    if not fs.exists(path) then
      return { error = "File not found: " .. path }
    end
    if fs.isDir(path) then
      return { error = "Path is a directory: " .. path }
    end
    if type(args.old_string) ~= "string" or type(args.new_string) ~= "string" then
      return { error = "old_string and new_string must be strings" }
    end
    if args.old_string == "" then
      return { error = "old_string must not be empty" }
    end
    -- (before the disk space check: a read-only disk has 0 bytes free)
    if fs.isReadOnly(path) then
      return { error = "Path is read-only: " .. path }
    end
    local content = readFile(path)
    if not content then
      return { error = "Cannot open file: " .. path }
    end
    local replaceAll = args.replace_all == true or args.replace_all == "true"

    -- The secret marker stands for text the model can't see: it can't be
    -- found, and written it would replace the secret (unless the file
    -- really has the marker text in it)
    if not content:find(REDACTED, 1, true) then
      if args.old_string:find(REDACTED, 1, true) then
        return { error = redactedError("old_string") }
      end
      if args.new_string:find(REDACTED, 1, true) then
        return { error = redactedError("new_string") }
      end
    end

    -- read_file shows "\r\n" line endings as "\n". In a file that has
    -- any, the strings are matched in that view (so a match may span both
    -- kinds of line, and uniqueness is judged on what the model saw), and
    -- each match is mapped back to the file's bytes
    local view, crlfAt = content, {}
    local oldString, newString = args.old_string, args.new_string
    local hasCRLF = content:find("\r\n", 1, true) ~= nil
    local newCRLF, majority
    if hasCRLF then
      view, crlfAt = lfView(content)
      oldString, newString = toLF(oldString), toLF(newString)
      newCRLF = newString:gsub("\n", "\r\n")
      majority = #crlfAt * 2 > #findAll(view, "\n") and "\r\n" or "\n"
    end

    local starts = findAll(view, oldString)
    local count = #starts
    if count == 0 then
      return { error = "String not found in file" }
    end
    if count > 1 and not replaceAll then
      return { error = "String found " .. count .. " times. Use replace_all=true or provide more context." }
    end

    local oldLen = byteLen(oldString)
    local out, last, k = {}, 1, 1
    for i = 1, replaceAll and count or 1 do
      local s = starts[i]
      local e = s + oldLen - 1
      -- File positions: one more byte for each CRLF newline before; a
      -- CRLF newline in the match takes its CR along
      while crlfAt[k] and crlfAt[k] < s do k = k + 1 end
      local from = s + k - 1
      while crlfAt[k] and crlfAt[k] <= e do k = k + 1 end
      local to = e + k - 1
      local replacement = newString
      if hasCRLF then
        -- The lines it adds get the line ending of the text it replaces,
        -- or the file's most common one
        local original = content:sub(from, to)
        local ending = majority
        if original:find("\r\n", 1, true) then
          ending = "\r\n"
        elseif original:find("\n", 1, true) then
          ending = "\n"
        end
        if ending == "\r\n" then
          replacement = newCRLF
        end
      end
      out[#out + 1] = content:sub(last, from - 1)
      out[#out + 1] = replacement
      last = to + 1
    end
    out[#out + 1] = content:sub(last)
    local newContent = table.concat(out)

    local ok, err = writeFile(path, newContent)
    if not ok then
      return { error = "Cannot write to file: " .. path .. (err and (" (" .. err .. ")") or "") }
    end
    return { success = true, path = path, replacements = replaceAll and count or 1 }
  end,
})

-- Tool: List directory
tools.list_directory = ai.tool({
  name = "list_directory",
  description = "List files and directories in a path.",
  parameters = {
    type = "object",
    properties = {
      path = { type = "string", description = "Directory path to list (default: current directory)" },
    },
    required = {},
  },
  execute = function(args)
    local path = resolvePath(args.path or ".")
    if not fs.exists(path) then
      return { error = "Path not found: " .. path }
    end
    if not fs.isDir(path) then
      return { error = "Path is not a directory: " .. path }
    end
    local entries = {}
    for _, entry in ipairs(fs.list(path)) do
      local fullPath = cmnPath.join(path, entry)
      local isDir = fs.isDir(fullPath)
      local size = 0
      if not isDir then
        size = fs.getSize(fullPath) or 0
      end
      table.insert(entries, {
        name = entry,
        type = isDir and "directory" or "file",
        size = size,
      })
    end
    table.sort(entries, function(a, b)
      if a.type ~= b.type then
        return a.type == "directory"
      end
      return a.name < b.name
    end)
    return { path = path, entries = entries }
  end,
})

-- Tool: Glob (file pattern matching)
tools.glob = ai.tool({
  name = "glob",
  description = "Find files matching a glob pattern, relative to `path`: '*.lua' (files in `path` " ..
    "itself), '**/*.lua' (at any depth), 'lib/**/*.{lua,txt}'. '*' and '?' match within one " ..
    "name, '**' across directories, {a,b} either alternative.",
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Glob pattern to match files" },
      path = { type = "string", description = "Starting directory (default: current directory)" },
    },
    required = { "pattern" },
  },
  execute = function(args)
    return cmnGlob.find(args.pattern, args.path)
  end,
})

-- Tool: Grep (search file contents)
tools.grep = ai.tool({
  name = "grep",
  description = "Search for a pattern in files. Returns matching lines with file paths and line numbers.",
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Lua pattern or literal string to search for" },
      path = { type = "string", description = "File or directory to search in (default: current directory)" },
      glob = {
        type = "string",
        description = "Only search matching files: a glob without '/' ('*.lua', '*.{lua,txt}') " ..
          "matches file names at any depth, one with '/' ('lib/**/*.lua') matches paths under " ..
          "the search directory. '?' is one character, {a,b} either alternative",
      },
      literal = { type = "boolean", description = "Treat pattern as literal string (default: false)" },
      max_results = { type = "number", description = "Maximum number of results (default: 50)" },
    },
    required = { "pattern" },
  },
  execute = function(args)
    return cmnGrep.search(args.pattern, {
      path = args.path,
      glob = args.glob,
      literal = args.literal,
      maxResults = args.max_results,
    })
  end,
})

-- Keep the first headBytes and the last tailBytes of output, cut at line
-- boundaries (so a multi-byte character is never split). Returns the text
-- and whether anything was left out. droppedBytes: what the recorder already
-- dropped from the middle (capture.run's info), counted in the note when
-- its "[... N lines left out ...]" marker is in the part cut here.
local function headAndTail(output, headBytes, tailBytes, droppedBytes)
  local total = byteLen(output)
  if total <= headBytes + tailBytes then
    return output, false
  end
  -- Head: up to the last newline within headBytes
  local head = output:sub(1, headBytes)
  local lastNl = head:match(".*()\n")
  if lastNl then
    head = head:sub(1, lastNl - 1)
  end
  -- Tail: from the first newline within the last tailBytes
  local tailStart = total - tailBytes + 1
  local firstNl = output:find("\n", tailStart, true)
  if firstNl then
    tailStart = firstNl + 1
  end
  local tail = output:sub(tailStart)
  -- The cut part starts and ends with a newline (between head and tail)
  local removed = output:sub(byteLen(head) + 1, tailStart - 1)
  local _, newlines = removed:gsub("\n", "")
  local omittedLines = math.max(1, newlines - 1)
  local omittedBytes = byteLen(removed) - 1
  local marker = removed:match("\n(%[%.%.%. %d+ lines left out %.%.%.%])\n")
  if marker then
    -- That one line stands for the lines the recorder dropped
    omittedLines = omittedLines - 1 + tonumber(marker:match("(%d+)"))
    omittedBytes = omittedBytes - byteLen(marker) - 1 + (droppedBytes or 0)
  end
  local note = string.format("[... %d lines (%d bytes) left out ...]", omittedLines, omittedBytes)
  return head .. "\n" .. note .. "\n" .. tail, true
end
tools.headAndTail = headAndTail

-- The secret values to blank in a screen's text. On vanilla CC the text
-- shows every byte as its own character (capture.cellText), so a value
-- with UTF-8 in it is also looked for in that form.
local function screenSecrets(list)
  if cctext.unicodeTerminal() then
    return list
  end
  local out, seen = {}, {}
  local function add(value)
    if not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  for _, value in ipairs(list) do
    add(value)
    add(capture.cellText(value))
  end
  -- Longest first, as secrets.values gives them
  table.sort(out, function(a, b) return byteLen(a) > byteLen(b) end)
  return out
end

-- Tool: Shell (execute CraftOS shell command)
tools.shell = ai.tool({
  name = "shell",
  description = "Execute a CraftOS shell command and capture what it prints. " ..
    "Programs: ls, cd, cp, mv, rm, mkdir, type, id, label, set, wget, pastebin, gps, peripherals. " ..
    "Run a Lua program by its path, with arguments (e.g. 'hello.lua' or 'mine 3'); there is no 'lua <file>' command. " ..
    "There is no cat, echo or grep: use read_file, write_file and grep. " ..
    "A program still running after `timeout` seconds is stopped and its output so far returned: " ..
    "normal for programs that loop forever. " ..
    "You can't give a program input, and keys pressed meanwhile are not passed on: one that " ..
    "waits for a key, typed text or a click (a menu, a game, a 'Press any key' prompt, read()) " ..
    "waits until the timeout, so give it a short one. " ..
    "With screen=true the program runs on a terminal the size of the real screen and the result " ..
    "is its final screen (text plus colours) instead of the printed output: use it to check " ..
    "full-screen programs such as dashboards, games, plots and menus, and to see what a program " ..
    "waits for. It shows this computer's own screen only, not monitors or term.native(). " ..
    "Never run the interactive programs edit, lua, shell or paint.",
  parameters = {
    type = "object",
    properties = {
      command = { type = "string", description = "The shell command to execute" },
      workdir = { type = "string", description = "Working directory (default: current directory)" },
      timeout = {
        type = "number",
        description = "Seconds before a still-running program is stopped (default " ..
          tools.SHELL_TIMEOUT .. ", max " .. tools.SHELL_MAX_TIMEOUT .. ")",
      },
      screen = {
        type = "boolean",
        description = "Return the final screen (taken when the program ends, or just before the " ..
          "timeout stops it) instead of the printed output (default false)",
      },
    },
    required = { "command" },
  },
  execute = function(args)
    if type(args.command) ~= "string" or args.command == "" then
      error("command must be a non-empty string", 0)
    end
    -- The secret marker stands for a value the model can't see (a command
    -- the user types with ! is not checked: it doesn't come through here)
    if args.command:find(REDACTED, 1, true) then
      return { error = redactedError("command") }
    end
    local workdir = args.workdir and resolvePath(args.workdir) or nil
    local timeout = tonumber(args.timeout) or tools.SHELL_TIMEOUT
    timeout = math.max(1, math.min(tools.SHELL_MAX_TIMEOUT, timeout))
    local screen = args.screen == true or args.screen == "true"

    local success, output, terminated, info = capture.run(args.command, workdir, {
      width = tools.SHELL_WIDTH,
      timeout = timeout,
      screen = screen,
      -- Nobody sees the program: keys the user presses are not meant for it
      noInput = true,
    })
    info = info or {}

    local result = {
      command = args.command,
      success = success,
    }
    -- Secret setting values are blanked here, before the output is
    -- shortened: a cut could leave a piece of one that no longer matches.
    -- (The agent checks every tool result again.)
    local secretList = secrets.values()
    if screen and info.screen then
      local shot = info.screen
      local text = output
      if text == "" and (shot.background or shot.textColour) then
        -- Drawn with background colours only (paintutils, bars, boxes)
        text = "(no text on the screen; the background rows show what is drawn)"
      elseif text == "" and shot.note then
        -- The colours were left out, so it may not be empty
        text = "(no text on the screen)"
      elseif text == "" then
        text = "(the screen is empty; output to monitors or term.native() is not captured)"
      else
        text = secrets.redact(text, screenSecrets(secretList))
      end
      result.screen = {
        size = shot.width .. "x" .. shot.height,
        text = text,
        background = shot.background,
        textColour = shot.textColour,
        palette = shot.palette,
        colours = (shot.background or shot.textColour or shot.palette) and tools.COLOUR_LEGEND or nil,
        note = shot.note,
      }
    else
      local truncated
      output = secrets.redact(output, secretList)
      output, truncated = headAndTail(output, SHELL_HEAD_BYTES, SHELL_TAIL_BYTES, info.droppedBytes)
      if output == "" then
        output = success and "(no output)" or "(command failed, no output)"
      end
      result.output = output
      result.truncated = truncated or nil
    end
    if info.timedOut then
      result.success = nil
      result.timedOut = true
    end
    local waitNote = "It was waiting for input (a key, typed text or a click), which programs " ..
      "run by this tool never get: you can't give input, and keys the user presses meanwhile " ..
      "are not passed on."
    if info.abandoned then
      result.note = (info.timedOut and ("Still running after " .. timeout .. "s; it") or "It") ..
        " did not end after the stop request (it ignores terminate, or its cleanup takes " ..
        "too long), so it was abandoned and will not run any further."
      if info.waitingForInput then
        result.note = result.note .. " " .. waitNote
      end
      if info.pullEventRestored then
        result.note = result.note .. " It had set os.pullEvent = os.pullEventRaw; that was put back."
      end
    elseif info.timedOut then
      result.note = "Still running after " .. timeout .. "s, so it was stopped. " ..
        (info.waitingForInput and waitNote or "That is expected for programs that loop forever.")
    end
    if screen and info.timedOut and result.screen then
      result.note = result.note .. (info.waitingForInput and " The screen shows what it was waiting on."
        or " The screen is from just before the stop.")
    end

    if terminated then
      -- The user stopped the program with Ctrl+T: that ends the turn too,
      -- but the output so far is still reported to the model
      error({ terminated = true, result = result }, 0)
    end
    return result
  end,
})

-- Get all tools as an array
function tools.getAll()
  return {
    tools.read_file,
    tools.write_file,
    tools.edit_file,
    tools.list_directory,
    tools.glob,
    tools.grep,
    tools.shell,
  }
end

-- Get tool by name
function tools.get(name)
  if tools[name] and tools[name]["function"] then
    return tools[name]
  end
  return nil
end

return tools

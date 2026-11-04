-- cc-code/tools.lua
-- Core tools for the cc-code agent (CraftOS compatible)

local ai = require("ai")
local cmnGlob = require("cmn-utils.glob")
local cmnGrep = require("cmn-utils.grep")
local cmnPath = require("cmn-utils.path")
local capture = require("cc-code.capture")
local byteLen = require("cmn-utils.text").byteLen

local tools = {}

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

-- Helper: write a whole file as raw bytes
local function writeFile(path, content)
  local handle, err = fs.open(path, "wb")
  if not handle then return false, err end
  handle.write(content)
  handle.close()
  return true
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
    local content = readFile(path)
    if not content then
      return { error = "Cannot open file: " .. path }
    end

    -- Count (non-overlapping) occurrences, as gsub will replace them
    local count = 0
    local pos = 1
    while true do
      local found = content:find(args.old_string, pos, true)
      if not found then break end
      count = count + 1
      pos = found + byteLen(args.old_string)
    end

    if count == 0 then
      return { error = "String not found in file" }
    end
    if count > 1 and not args.replace_all then
      return { error = "String found " .. count .. " times. Use replace_all=true or provide more context." }
    end

    local newContent
    if args.replace_all then
      -- Escape magic chars in pattern and % in replacement so both are literal
      -- (parentheses keep only gsub's first result: the count would
      -- otherwise become content:gsub's "max replacements" argument)
      newContent = content:gsub(
        (args.old_string:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")),
        (args.new_string:gsub("%%", "%%%%"))
      )
    else
      local idx = content:find(args.old_string, 1, true)
      newContent = content:sub(1, idx - 1) .. args.new_string .. content:sub(idx + byteLen(args.old_string))
    end

    local ok, err = writeFile(path, newContent)
    if not ok then
      return { error = "Cannot write to file: " .. path .. (err and (" (" .. err .. ")") or "") }
    end
    return { success = true, path = path, replacements = args.replace_all and count or 1 }
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
  description = "Find files matching a glob pattern (e.g., '*.lua', 'lib/**/*.lua').",
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
      glob = { type = "string", description = "Only search files matching this glob pattern (e.g., '*.lua')" },
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

-- Tool: Shell (execute CraftOS shell command)
tools.shell = ai.tool({
  name = "shell",
  description = "Execute a CraftOS shell command and capture what it prints. " ..
    "Programs: ls, cd, cp, mv, rm, mkdir, type, id, label, set, wget, pastebin, gps, peripherals. " ..
    "Run a Lua program by its path, with arguments (e.g. 'hello.lua' or 'mine 3'); there is no 'lua <file>' command. " ..
    "There is no cat, echo or grep: use read_file, write_file and grep. " ..
    "Never run interactive programs (edit, lua, shell, paint) or programs that wait for input: the agent blocks until they exit.",
  parameters = {
    type = "object",
    properties = {
      command = { type = "string", description = "The shell command to execute" },
      workdir = { type = "string", description = "Working directory (default: current directory)" },
    },
    required = { "command" },
  },
  execute = function(args)
    local workdir = args.workdir and resolvePath(args.workdir) or nil
    local success, output, terminated = capture.run(args.command, workdir)
    if terminated then
      -- Ctrl+T stops the agent too, not just the program it ran
      error("Terminated", 0)
    end
    if output == "" then
      output = success and "(no output)" or "(command failed, no output)"
    end

    return {
      command = args.command,
      output = output:sub(1, 4000),
      success = success,
      truncated = byteLen(output) > 4000,
    }
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

-- cc-ai installer
-- In-game:  wget run https://raw.githubusercontent.com/mindbound/cc-ai/main/install.lua
-- Options:  install [owner/repo] [branch] [directory]
-- Installs lib/, bin/, docs/, examples/ and tests/ into /cc-ai and adds a
-- startup file that puts cc-code on the shell path.

local args = { ... }
local REPO = args[1] or "mindbound/cc-ai"
local BRANCH = args[2] or "master"
local DIR = "/" .. fs.combine(args[3] or "/cc-ai", "")
local STARTUP = "/startup/cc-ai.lua"

-- Top-level entries that belong to an installation
local INSTALL = { lib = true, bin = true, docs = true, examples = true, tests = true }

if not http then
  printError("The HTTP API is disabled. Enable it in the ComputerCraft config.")
  return
end

local json = textutils.unserialiseJSON

local function get(url, binary)
  local response, err = http.get(url, nil, binary)
  if not response then
    error("Download failed: " .. url .. " (" .. tostring(err) .. ")", 0)
  end
  local body = response.readAll()
  response.close()
  return body
end

print("Installing cc-ai from " .. REPO .. " (" .. BRANCH .. ") to " .. DIR)

-- List the repository's files
local treeUrl = "https://api.github.com/repos/" .. REPO .. "/git/trees/" .. BRANCH .. "?recursive=1"
local tree = json(get(treeUrl))
if type(tree) ~= "table" or type(tree.tree) ~= "table" then
  error("Unexpected response listing " .. REPO, 0)
end

local files = {}
for _, entry in ipairs(tree.tree) do
  local top = entry.path:match("^([^/]+)/")
  if entry.type == "blob" and top and INSTALL[top] then
    table.insert(files, entry.path)
  end
end
if #files == 0 then
  error("No files found in " .. REPO .. " (" .. BRANCH .. ")", 0)
end

-- Download everything into a staging directory first, so a failed download
-- (rate limit, network, full disk) leaves the previous install working
local STAGING = DIR .. ".download"
if fs.exists(STAGING) then
  fs.delete(STAGING)
end

local rawBase = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/"
local ok, err = pcall(function()
  local _, y = term.getCursorPos()
  for i, path in ipairs(files) do
    term.setCursorPos(1, y)
    term.clearLine()
    write(("[%d/%d] %s"):format(i, #files, path))
    local content = get(rawBase .. path, true)
    local target = fs.combine(STAGING, path)
    fs.makeDir(fs.getDir(target))
    local handle, openErr = fs.open(target, "wb")
    if not handle then
      error("Cannot write " .. target .. ": " .. tostring(openErr), 0)
    end
    handle.write(content)
    handle.close()
    _, y = term.getCursorPos()
  end
end)
print()
if not ok then
  if fs.exists(STAGING) then
    fs.delete(STAGING)
  end
  error(err, 0)
end

-- Replace the previous install's managed directories (removes stale files)
fs.makeDir(DIR)
for name in pairs(INSTALL) do
  local path = fs.combine(DIR, name)
  if fs.exists(path) then
    fs.delete(path)
  end
  local staged = fs.combine(STAGING, name)
  if fs.exists(staged) then
    fs.move(staged, path)
  end
end
fs.delete(STAGING)

-- Startup file: cc-code on the shell path, with completion for its options
local binDir = fs.combine(DIR, "bin")
local startup = ([[
-- Added by the cc-ai installer: makes `cc-code` runnable from anywhere
local binDir = "/%s"
if not (":" .. shell.path() .. ":"):find(":" .. binDir .. ":", 1, true) then
  shell.setPath(shell.path() .. ":" .. binDir)
end
local completion = require("cc.completion")
shell.setCompletionFunction(fs.combine(binDir, "cc-code.lua"), function(_, index, text)
  return completion.choice(text, { "--model ", "--terminal", "--monochrome", "--help" })
end)
]]):format(binDir)

print("Installed " .. #files .. " files.")

if fs.exists("/startup") and not fs.isDir("/startup") then
  -- A plain /startup file exists, so there is no startup directory to add to
  printError("Not adding " .. STARTUP .. ": /startup is a file.")
  print("Add this line to your startup file instead:")
  print("  shell.setPath(shell.path() .. \":/" .. binDir .. "\")")
else
  fs.makeDir(fs.getDir(STARTUP))
  local handle = fs.open(STARTUP, "w")
  handle.write(startup)
  handle.close()
  -- Apply it to this shell session too
  shell.run(STARTUP)
end

print("")
print("Set an API key, then run cc-code:")
print("  set AI_GATEWAY_API_KEY <key>")
print("Or use a provider directly, e.g. Google:")
print("  set GOOGLE_GENERATIVE_AI_API_KEY <key>")
print("  then in cc-code: /model google gemini-flash-latest")

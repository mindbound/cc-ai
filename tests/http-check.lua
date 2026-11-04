-- tests/http-check.lua [model]
-- Checks whether an OpenAI-compatible endpoint's replies arrive complete in
-- CC: Tweaked, with and without streaming. Uses AI_CUSTOM_BASE_URL and
-- AI_CUSTOM_API_KEY. Background: a server that sends a Content-Length
-- counting characters instead of bytes gets its non-ASCII replies cut short.
--   /cc-ai/tests/http-check deepseek/deepseek-v4.1-flash:thinking
-- Prints a summary and writes it to /http-check.txt. Never prints the key.

local model = ... or "deepseek/deepseek-v4.1-flash:thinking"
local root = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
package.path = root .. "/lib/?.lua;" .. root .. "/lib/?/init.lua;" .. package.path
local json = require("cmn-utils.json")

local base = settings.get("AI_CUSTOM_BASE_URL")
if not base then
  printError("Run: set AI_CUSTOM_BASE_URL <url>")
  return
end
local url = tostring(base):gsub("/+$", ""):gsub("/chat/completions$", "") .. "/chat/completions"
local headers = { ["Content-Type"] = "application/json" }
local key = settings.get("AI_CUSTOM_API_KEY")
if key then
  headers["Authorization"] = "Bearer " .. tostring(key)
end

local lines = {}
local function out(s)
  table.insert(lines, s)
  print(s)
end

-- Asks for non-ASCII characters on purpose: em dashes and a degree sign
local prompt = "Reply with exactly this text and nothing else: " ..
  "caf\195\169 \226\128\148 17 \194\176C \226\128\148 done"

local function run(stream)
  local response, err, errResponse = http.post({
    url = url,
    headers = headers,
    body = json.encode({ model = model, stream = stream or nil, max_tokens = 1000,
      messages = { { role = "user", content = prompt } } }),
    timeout = 0,
  })
  local h = response or errResponse
  if not h then
    out("  request failed: " .. tostring(err))
    return
  end
  local code = h.getResponseCode()
  local framing = "unknown"
  for name, value in pairs(h.getResponseHeaders()) do
    if name:lower() == "content-length" then framing = "Content-Length " .. value end
    if name:lower() == "transfer-encoding" then framing = "Transfer-Encoding " .. value end
  end
  local body = h.readAll() or ""
  h.close()
  local nonAscii = select(2, body:gsub("[\128-\255]", ""))
  local complete
  if stream then
    -- Each "data:" line must be complete JSON, and the stream must finish
    complete = body:find("data: [DONE]", 1, true) ~= nil
    for line in body:gmatch("data: ([^\r\n]+)") do
      if line ~= "[DONE]" and not pcall(json.decode, line) then complete = false end
    end
  else
    complete = pcall(json.decode, body)
  end
  out(("  status %d, %s"):format(code, framing))
  out(("  %d bytes, %d non-ASCII, complete: %s"):format(#body, nonAscii, tostring(complete)))
  if not complete then
    out("  ends with: " .. body:sub(-40):gsub("%s+", " "))
  end
end

out("Endpoint: " .. url)
out("Model: " .. model)
out("Without streaming:")
run(false)
out("With streaming:")
run(true)

local f = fs.open("/http-check.txt", "w")
f.write(table.concat(lines, "\n") .. "\n")
f.close()
print("Saved to /http-check.txt")

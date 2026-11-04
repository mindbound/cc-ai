-- tests/http-check.lua [model]
-- Checks whether an OpenAI-compatible endpoint's replies arrive complete and
-- decode in CC: Tweaked, with and without streaming. Uses AI_CUSTOM_BASE_URL
-- and AI_CUSTOM_API_KEY. The prompt asks for non-ASCII text on purpose.
--   /cc-ai/tests/http-check deepseek/deepseek-v4.1-flash:thinking
-- Prints a summary (with the decode error and the bytes around it when a
-- reply doesn't decode) and saves it to /http-check.txt; the raw replies go
-- to /http-check-plain.json and /http-check-stream.txt. Never prints the key.

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

local function save(path, data)
  local f = fs.open(path, "wb")
  f.write(data)
  f.close()
end

-- Hex and printable view of the bytes around a position
local function around(str, pos)
  local from, to = math.max(1, pos - 8), math.min(#str, pos + 8)
  local hex, txt = {}, {}
  for i = from, to do
    local b = str:byte(i)
    table.insert(hex, (i == pos and ">" or "") .. ("%02x"):format(b))
    table.insert(txt, (b >= 32 and b < 127) and string.char(b) or ".")
  end
  return ("bytes %d-%d: %s |%s|"):format(from, to, table.concat(hex, " "), table.concat(txt))
end

-- Try to decode; on failure report the error and the bytes around it
local function check(str, label)
  local ok, err = pcall(json.decode, str)
  if ok then return true end
  err = tostring(err):gsub("^.-:%d+: ", "")
  out("  " .. label .. " decode error: " .. err)
  local col = tonumber(err:match("col (%d+)"))
  local line = tonumber(err:match("line (%d+)"))
  if col and line == 1 then
    out("  " .. around(str, col))
  end
  return false
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
  save(stream and "/http-check-stream.txt" or "/http-check-plain.json", body)
  local nonAscii = select(2, body:gsub("[\128-\255]", ""))
  out(("  status %d, %s, %d bytes, %d non-ASCII"):format(code, framing, #body, nonAscii))
  local complete
  if stream then
    -- Each "data:" line must decode, and the stream must finish
    complete = body:find("data: [DONE]", 1, true) ~= nil
    local n, bad = 0, 0
    for line in body:gmatch("data: ([^\r\n]+)") do
      if line ~= "[DONE]" then
        n = n + 1
        local hasNonAscii = line:find("[\128-\255]") ~= nil
        if not check(line, "line " .. n .. (hasNonAscii and " (non-ASCII)" or "")) then
          bad = bad + 1
          complete = false
        end
      end
    end
    out(("  %d data lines, %d failed to decode"):format(n, bad))
  else
    complete = check(body, "body")
  end
  out("  complete: " .. tostring(complete))
end

out("Endpoint: " .. url)
out("Model: " .. model)
out("Host: " .. tostring(_HOST))
out("Without streaming:")
run(false)
out("With streaming:")
run(true)

save("/http-check.txt", table.concat(lines, "\n") .. "\n")
print("Saved to /http-check.txt, raw replies to /http-check-plain.json and /http-check-stream.txt")

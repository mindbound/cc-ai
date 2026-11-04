-- tests/http-check.lua [model]
-- Checks whether an OpenAI-compatible endpoint's replies decode in
-- CC: Tweaked, in text and binary mode, with and without streaming. Uses
-- AI_CUSTOM_BASE_URL and AI_CUSTOM_API_KEY. The prompt asks for non-ASCII
-- text on purpose: in CC: Tweaked 1.120, a text-mode reply containing
-- multi-byte UTF-8 reported its length (#) in characters, not bytes.
--   /cc-ai/tests/http-check deepseek/deepseek-v4.1-flash:thinking
-- Prints a summary (decode errors with the bytes around them) and saves it
-- to /http-check.txt; raw replies go to /http-check-<mode>.txt. Never
-- prints the key.

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

-- Byte count without the length operator (gsub walks the real content)
local function counted(str)
  return select(2, str:gsub(".", ""))
end

-- "#s" next to the counted bytes, flagged when they differ
local function lengths(str)
  local a, b = #str, counted(str)
  return ("# %d, counted %d%s"):format(a, b, a == b and "" or " MISMATCH")
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
  out("    " .. label .. ": " .. err)
  local col = tonumber(err:match("col (%d+)"))
  if col and tonumber(err:match("line (%d+)")) == 1 then
    out("    " .. around(str, col))
  end
  return false
end

-- Asks for non-ASCII characters on purpose: em dashes and a degree sign
local sample = "caf\195\169 \226\128\148 17 \194\176C \226\128\148 done"
local prompt = "Reply with exactly this text and nothing else: " .. sample

local function run(stream, binary)
  local label = (stream and "stream" or "plain") .. "/" .. (binary and "binary" or "text")
  local response, err, errResponse = http.post({
    url = url,
    headers = headers,
    body = json.encode({ model = model, stream = stream or nil, max_tokens = 1000,
      messages = { { role = "user", content = prompt } } }),
    timeout = 0,
    binary = binary,
  })
  local h = response or errResponse
  if not h then
    out(label .. ": request failed: " .. tostring(err))
    return
  end
  local code = h.getResponseCode()
  local body = h.readAll() or ""
  h.close()
  save("/http-check-" .. label:gsub("/", "-") .. ".txt", body)
  out(("%s: status %d, %s"):format(label, code, lengths(body)))
  local ok
  if stream then
    local n, bad = 0, 0
    for line in body:gmatch("data: ([^\r\n]+)") do
      if line ~= "[DONE]" then
        n = n + 1
        if not check(line, "line " .. n .. " (" .. lengths(line) .. ")") then
          bad = bad + 1
        end
      end
    end
    ok = bad == 0 and body:find("data: [DONE]", 1, true) ~= nil
    out(("  %d data lines, %d failed to decode"):format(n, bad))
  else
    ok = check(body, "body")
  end
  out("  decodes: " .. tostring(ok))
end

out("Endpoint: " .. url)
out("Model: " .. model)
out("Host: " .. tostring(_HOST))
out("String literal: " .. lengths(sample))
run(false, false)
run(false, true)
run(true, false)
run(true, true)

save("/http-check.txt", table.concat(lines, "\n") .. "\n")
print("Saved to /http-check.txt")

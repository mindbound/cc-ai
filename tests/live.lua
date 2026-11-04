-- tests/live.lua <provider> <model>
-- Live checks against a real API: needs network and the provider's settings
-- (API key, and AI_CUSTOM_BASE_URL for "custom"). Providers: gateway,
-- google, openai, groq, custom. Results are printed and written to
-- /cc-ai-live-results.txt (never keys or headers).
--   /cc-ai/tests/live custom deepseek/deepseek-v4.1-flash:thinking
--   tests/live.ps1 -Provider custom -Model ...   (headless CraftOS-PC)

local args = { ... }
local providerName = args[1] or "custom"
local modelId = args[2]
if not modelId then
  printError("Usage: live <provider> <model>")
  return
end

local root = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
package.path = root .. "/lib/?.lua;" .. root .. "/lib/?/init.lua;" .. package.path

local ai = require("ai")
local json = require("cmn-utils.json")

local function makeModel()
  if providerName == "gateway" then
    return modelId
  end
  return require("ai." .. providerName)(modelId)
end

local log = {}
local function out(line)
  table.insert(log, line)
  print(line)
end

local function clip(s, n)
  s = tostring(s or "")
  n = n or 300
  if #s > n then return s:sub(1, n) .. "...(" .. #s .. " chars)" end
  return s
end

local passed, failed = 0, 0
local function check(name, fn)
  out("== " .. name)
  local started = os.epoch("utc")
  local ok, err = pcall(fn)
  local secs = (os.epoch("utc") - started) / 1000
  if ok then
    passed = passed + 1
    out(("   PASS (%.1fs)"):format(secs))
  else
    failed = failed + 1
    out(("   FAIL (%.1fs): %s"):format(secs, tostring(err)))
  end
end

local function expect(cond, msg)
  if not cond then error(msg, 2) end
end

out("provider: " .. providerName .. "  model: " .. modelId)
out("host: " .. tostring(_HOST))

-- timeout = 0: no idle timeout, so slow (thinking) models aren't cut off
check("generateText", function()
  local r = ai.generateText({
    model = makeModel(),
    prompt = "Reply with exactly the word: pong",
    maxOutputTokens = 2000,
    timeout = 0,
  })
  out("   text: " .. clip(r.text))
  out("   finishReason: " .. tostring(r.finishReason) .. "  usage: " .. json.encode(r.usage))
  expect(type(r.text) == "string" and r.text:lower():find("pong"), "reply does not contain pong")
end)

check("streamText", function()
  local chunks = 0
  local r = ai.streamText({
    model = makeModel(),
    prompt = "Count from 1 to 5, separated by spaces.",
    maxOutputTokens = 2000,
    timeout = 0,
    onChunk = function(c) if c.type == "text" then chunks = chunks + 1 end end,
  })
  out("   text: " .. clip(r.text) .. "  chunks: " .. chunks)
  out("   finishReason: " .. tostring(r.finishReason))
  expect(r.text:find("1") and r.text:find("5"), "missing numbers")
  expect(chunks > 0, "no chunks")
end)

check("tool calling", function()
  local calls = 0
  local weather = ai.tool({
    name = "get_weather",
    description = "Get the current weather in a city",
    parameters = {
      type = "object",
      properties = { location = { type = "string", description = "City name" } },
      required = { "location" },
    },
    execute = function(a)
      calls = calls + 1
      return { location = a.location, temperature = 17, unit = "C", condition = "rain" }
    end,
  })
  local r = ai.generateText({
    model = makeModel(),
    prompt = "What's the weather in Riga right now? Use the tool.",
    tools = { weather },
    maxSteps = 4,
    maxOutputTokens = 2000,
    timeout = 0,
  })
  out("   tool calls: " .. calls .. "  args: " .. clip(r.toolResults[1] and json.encode(r.toolResults[1].args)))
  out("   text: " .. clip(r.text))
  expect(calls >= 1, "tool was not called")
  expect(r.text:find("17"), "answer does not use the tool result")
end)

check("generateObject", function()
  local r = ai.generateObject({
    model = makeModel(),
    schema = {
      type = "object",
      properties = { name = { type = "string" }, age = { type = "number" } },
      required = { "name", "age" },
    },
    prompt = "Generate a fictional Minecraft player with a name and an age.",
    maxOutputTokens = 2000,
    timeout = 0,
  })
  out("   object: " .. json.encode(r.object))
  expect(type(r.object.name) == "string", "no name")
  expect(type(r.object.age) == "number", "no numeric age")
end)

check("cc-code agent: write and run a program", function()
  local agent = require("cc-code.agent")
  local dir = "/cc-ai-live-tmp"
  if fs.exists(dir) then fs.delete(dir) end
  fs.makeDir(dir)
  agent.init({ model = makeModel(), maxSteps = 10 })
  local toolLog = {}
  local r = agent.process(
    "Create " .. dir .. "/hello.lua that prints exactly: hello from cc. " ..
    "Then run it with the shell tool and tell me what it printed.", {
      onToolCall = function(name, a) table.insert(toolLog, name .. " " .. clip(json.encode(a), 120)) end,
    })
  for _, t in ipairs(toolLog) do out("   tool: " .. t) end
  out("   result: " .. tostring(r.type) .. ": " .. clip(r.text, 500))
  expect(r.type == "response", "agent returned " .. tostring(r.type))
  expect(fs.exists(dir .. "/hello.lua"), "hello.lua was not written")
  local ranShell = false
  for _, t in ipairs(toolLog) do
    if t:find("^shell") then ranShell = true end
  end
  expect(ranShell, "agent did not run the program with the shell tool")
  expect(r.text:lower():find("hello from cc", 1, true), "answer does not report the output")
end)

out("")
out(("%d passed, %d failed"):format(passed, failed))

local f = fs.open("/cc-ai-live-results.txt", "w")
f.write(table.concat(log, "\n") .. "\n")
f.close()

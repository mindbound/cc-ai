-- tests/run.lua
-- Offline test suite for cc-ai. Runs on any CC computer or in CraftOS-PC:
--   cc-ai/tests/run            (in-game or in the emulator shell)
--   tests/run.ps1              (from Windows: headless CraftOS-PC)
-- HTTP is replaced with a fake, so no API keys or network are needed.
-- Results are printed and written to /cc-ai-test-results.txt.

local args = { ... }
local root = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
package.path = root .. "/lib/?.lua;" .. root .. "/lib/?/init.lua;" .. package.path

-- The harness needs `require`, so load it with this program's environment
-- (CraftOS's dofile runs files in _G, which has no `require`)
local T = loadfile(root .. "/tests/harness.lua", "t", _ENV)()
-- The repository root, for suites that need files from it. (Computed once
-- here: shell.getRunningProgram() can't be trusted later, because a
-- capture test abandons a program, which leaves the shell's program stack
-- pointing at it.)
T.root = root

-- Swap in the fake HTTP API. Required modules share this program's
-- environment, so they see it too. Keep settings changes in memory only.
local realHttp = http
http = { post = T.http.post, get = T.http.get, request = T.http.request, checkURL = function() return true end }

-- Settings the suites change. They start unset (cc-code's saved model etc.
-- would change what the tests see) and are put back afterwards. Saving is
-- disabled meanwhile, so /model can't write test values to /.settings.
local savedSettings = {}
local SAVED = { "AI_GATEWAY_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY",
  "AI_CUSTOM_API_KEY", "AI_CUSTOM_BASE_URL", "ai.http_timeout",
  "cc-code.model", "cc-code.max_steps", "cc-code.max_output_tokens" }
for _, name in ipairs(SAVED) do
  savedSettings[name] = settings.get(name)
end
for _, name in ipairs({ "cc-code.model", "cc-code.max_steps", "cc-code.max_output_tokens" }) do
  settings.unset(name)
end
local realSave = settings.save
T.saves = 0
settings.save = function() T.saves = T.saves + 1 return true end

local suites = { "test_files", "test_capture", "test_ai", "test_agent", "test_install", "test_ui" }
local only = args[1]

for _, name in ipairs(suites) do
  if not only or only == name then
    local path = root .. "/tests/" .. name .. ".lua"
    if fs.exists(path) then
      T.print(name)
      local fn, err = loadfile(path, "t", _ENV)
      if not fn then
        T.failed = T.failed + 1
        table.insert(T.failures, name .. ": " .. tostring(err))
        T.print("  FAIL load: " .. tostring(err))
      else
        local ok, suiteErr = pcall(function() fn()(T) end)
        if not ok then
          T.failed = T.failed + 1
          table.insert(T.failures, name .. ": " .. tostring(suiteErr))
          T.print("  FAIL suite crashed: " .. tostring(suiteErr))
        end
      end
    end
  end
end

-- Restore the environment
http = realHttp
settings.save = realSave
-- (iterate the names: pairs() would skip settings that were unset before)
for _, name in ipairs(SAVED) do
  local value = savedSettings[name]
  if value == nil then settings.unset(name) else settings.set(name, value) end
end
if fs.exists(T.tmp) then fs.delete(T.tmp) end

local summary = string.format("%d passed, %d failed", T.passed, T.failed)
T.print("")
T.print(summary)
for _, f in ipairs(T.failures) do
  T.print("FAILED " .. f)
end

local out = fs.open("/cc-ai-test-results.txt", "w")
out.write(table.concat(T.log, "\n") .. "\n")
out.close()

term.setTextColour(T.failed == 0 and colours.lime or colours.red)
print(summary)
term.setTextColour(colours.white)
for _, f in ipairs(T.failures) do
  printError(f)
end

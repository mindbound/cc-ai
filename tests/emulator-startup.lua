-- tests/emulator-startup.lua
-- Startup script for headless CraftOS-PC runs (see tests/run.ps1): the repo
-- is mounted at /cc-ai, the suite runs, then the emulator shuts down.
local ok, err = pcall(shell.run, "/cc-ai/tests/run.lua", ...)
if not ok then
  local f = fs.open("/cc-ai-test-results.txt", "w")
  f.write("runner crashed: " .. tostring(err) .. "\n")
  f.close()
end
os.shutdown()

-- tests/emulator-live.lua
-- Startup script for headless live runs (see tests/live.ps1)
local ok, err = pcall(shell.run, "/cc-ai/tests/live.lua", ...)
if not ok then
  local f = fs.open("/cc-ai-live-results.txt", "w")
  f.write("live runner crashed: " .. tostring(err) .. "\n")
  f.close()
end
os.shutdown()

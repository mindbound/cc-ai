-- cc-code: AI Coding Agent for ComputerCraft
-- Usage: cc-code [options]
--   -m, --model <model>   Set the AI model for this run: <provider>:<model>
--                         (google, openai, groq, custom) or a gateway model
--                         like openai/gpt-4o. Default: the cc-code.model
--                         setting, which /model saves
--   -t, --terminal        Force terminal mode (line-based, no TUI)
--   -c, --monochrome      Use monochrome colors (auto on non-advanced computers)
--   -h, --help            Show this help message

-- Libraries live in ../lib relative to this program (require resolves
-- relative paths against the running program's directory)
package.path = "../lib/?.lua;../lib/?/init.lua;" .. package.path

-- Parse arguments: flags may come in any order, -m/--model takes a value
local args = { ... }
local opts = {}
local i = 1
while i <= #args do
  local arg = args[i]
  if arg == "-m" or arg == "--model" then
    opts.model = args[i + 1] or ""
    i = i + 1
  elseif arg:match("^%-%-model=") then
    opts.model = arg:match("^%-%-model=(.*)$")
  elseif arg == "-t" or arg == "--terminal" then
    opts.terminal = true
  elseif arg == "-c" or arg == "--monochrome" then
    opts.monochrome = true
  elseif arg == "-h" or arg == "--help" then
    opts.help = true
  else
    printError("Unknown option: " .. arg)
    opts.help = true
  end
  i = i + 1
end

-- Show help
if opts.help then
  print("cc-code - AI Coding Agent for ComputerCraft")
  print("")
  print("Usage: cc-code [options]")
  print("  -m, --model <model>   Model for this run, e.g.")
  print("                        custom:<model> or openai/gpt-4o")
  print("  -t, --terminal        Force terminal mode (no TUI)")
  print("  -c, --monochrome      Use monochrome colors")
  print("  -h, --help            Show this help message")
  print("")
  print("API keys (stored with the set program):")
  print("  set AI_GATEWAY_API_KEY <key>")
  print("  set GOOGLE_GENERATIVE_AI_API_KEY <key>")
  print("  set OPENAI_API_KEY <key>")
  print("  set GROQ_API_KEY <key>")
  print("  set AI_CUSTOM_BASE_URL <url>  (custom endpoint)")
  print("")
  print("Settings: cc-code.model (saved by /model),")
  print("  cc-code.max_steps, cc-code.max_output_tokens")
  print("")
  print("Inside cc-code: /help, /model, /clear, /exit")
  return
end

if opts.model == "" then
  printError("--model needs a value, e.g. -m custom:<model> or -m google/gemini-2.5-flash")
  return
end

-- An unknown model is an error here, rather than a silent fallback
if opts.model then
  local ok, agent = pcall(require, "cc-code.agent")
  if ok then
    local model, problem = agent.resolveModel(opts.model)
    if not model then
      printError("Unknown model: " .. problem)
      return
    end
  end
end

-- Build config
local config = {}

if opts.model then
  config.model = opts.model
end

if opts.terminal then
  config.forceTerminal = true
end

if opts.monochrome then
  config.monochrome = true
end

-- Run cc-code
local occode = require("cc-code")
occode.run(config)

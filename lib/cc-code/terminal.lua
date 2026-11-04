-- cc-code/terminal.lua
-- Simple line-mode interface (no full-screen TUI): prints to the current
-- terminal and reads input with CC's read()

local json = require("cmn-utils.json")
local cctext = require("cmn-utils.text")
local completion = require("cc.completion")

-- The CC colour API ("terminal.colors" below is the table of UI roles)
local ccColors = colors

local terminal = {}

-- Colors: UI role -> CC colour (default palette; only used on colour terminals)
terminal.colors = {
  background = ccColors.black,
  foreground = ccColors.white,
  prompt = ccColors.yellow,
  user = ccColors.lime,
  assistant = ccColors.lightBlue,
  tool = ccColors.yellow,
  toolName = ccColors.magenta,
  error = ccColors.red,
  success = ccColors.green,
  dim = ccColors.lightGray,
  border = ccColors.gray,
  highlight = ccColors.cyan,
  status = ccColors.gray,
}

-- Valid CC colour values
local validColors = {}
for i = 0, 15 do
  validColors[2 ^ i] = true
end

-- State
local state = {
  running = true,
  status = "Ready",
  showTools = true,
  monochrome = false,
}

-- Input history for read() (kept across calls)
local inputHistory = {}

-- Commands offered by Tab completion
local commandNames = { "/help", "/?", "/model", "/turtle", "/clear", "/exit", "/quit" }

-- Registered completion handlers: { prefix = { handler = fn, label = "Models" } }
local completionHandlers = {}

-- Reset terminal to default colours (white on black)
local function resetTerminalState()
  term.setTextColour(ccColors.white)
  term.setBackgroundColour(ccColors.black)
end

-- Use a text colour if the terminal can show it
local function setColor(color)
  if not state.monochrome and validColors[color] and term.isColour() then
    term.setTextColour(color)
  else
    term.setTextColour(ccColors.white)
  end
end

-- Print CC-charset text in a colour; print() wraps to the terminal width
local function printText(str, color)
  setColor(color)
  print(str)
  term.setTextColour(ccColors.white)
end

-- Convert a value to a display string (CC charset)
local function toDisplay(value)
  if type(value) ~= "string" then
    local ok, encoded = pcall(json.encode, value)
    value = ok and encoded or tostring(value)
  end
  return cctext.toCC(value)
end

-- Initialize terminal
function terminal.init(config)
  config = config or {}
  state.running = true
  state.status = "Ready"
  state.monochrome = config.monochrome and true or false
  -- Reset colours to prevent TUI color bleed
  resetTerminalState()
end

-- Print text (UTF-8 from the model is converted to the CC charset)
function terminal.print(msg, color)
  printText(cctext.toCC(tostring(msg)), color)
end

-- Print with role prefix
function terminal.printRole(role, msg)
  local prefix, color
  if role == "user" then
    prefix, color = "> ", terminal.colors.user
  elseif role == "assistant" then
    prefix, color = "", terminal.colors.assistant
  elseif role == "tool" then
    prefix, color = "  ", terminal.colors.tool
  elseif role == "error" then
    prefix, color = "[ERROR] ", terminal.colors.error
  else
    prefix, color = "", terminal.colors.foreground
  end
  terminal.print(prefix .. tostring(msg), color)
end

-- Print tool call
function terminal.printToolCall(name, args)
  if not state.showTools then return end
  printText(">> " .. cctext.toCC(tostring(name)), terminal.colors.toolName)
  if args then
    local argsStr = toDisplay(args)
    if #argsStr > 80 then
      argsStr = argsStr:sub(1, 77) .. "..."
    end
    printText("   " .. argsStr, terminal.colors.dim)
  end
end

-- Print tool result
function terminal.printToolResult(name, result)
  if not state.showTools then return end
  local resultStr = toDisplay(result)
  if #resultStr > 100 then
    resultStr = resultStr:sub(1, 97) .. "..."
  end
  printText("<< " .. resultStr, terminal.colors.dim)
  -- Reset terminal state after tool execution to prevent color bleed
  resetTerminalState()
end

-- Set status (stored only; terminal mode has no status bar)
function terminal.setStatus(msg)
  state.status = msg or "Ready"
end

-- Register a completion handler for a command prefix (same contract as
-- tui.registerCompletion: handler(args) returns { {cmd, desc}, ... })
function terminal.registerCompletion(prefix, handler, label)
  completionHandlers[prefix:lower()] = { handler = handler, label = label }
end

-- Completion function for read(): returns suffixes that complete the line
local function completeInput(line)
  if line:sub(1, 1) ~= "/" then
    return {}
  end

  -- Arguments of a command with a registered handler (e.g. "/model ...")
  for prefix, reg in pairs(completionHandlers) do
    local pattern = "^" .. prefix:gsub("([^%w])", "%%%1") .. "%s+(.*)$"
    local args = line:lower():match(pattern)
    if args then
      local ok, results = pcall(reg.handler, args)
      local choices = {}
      if ok and type(results) == "table" then
        for _, item in ipairs(results) do
          if type(item.cmd) == "string" then
            choices[#choices + 1] = item.cmd
          end
        end
      end
      return completion.choice(line, choices)
    end
  end

  -- Command names
  if line:find("%s") then
    return {}
  end
  return completion.choice(line, commandNames)
end

-- Read user input with CC's read() (cursor keys, history, paste, Tab
-- completion). Returns nil when the user terminates (Ctrl+T).
function terminal.readInput()
  -- Reset terminal state before showing prompt
  resetTerminalState()
  setColor(terminal.colors.prompt)
  write("> ")
  term.setTextColour(ccColors.white)

  local ok, line = pcall(read, nil, inputHistory, completeInput)
  if not ok then
    if line == "Terminated" or tostring(line):find("Terminated", 1, true) then
      print()
      return nil
    end
    error(line, 0)
  end

  if line and line ~= "" and inputHistory[#inputHistory] ~= line then
    table.insert(inputHistory, line)
  end
  return line
end

-- Clear (just prints separator)
function terminal.clear()
  print("---")
  print("Conversation cleared.")
  print("---")
end

-- Cleanup
function terminal.cleanup()
  resetTerminalState()
  term.setCursorBlink(false)
end

-- Check if running
function terminal.isRunning()
  return state.running
end

-- Stop running
function terminal.stop()
  state.running = false
end

-- Interface compatibility stubs (required for TUI/terminal interoperability)
-- These functions exist so init.lua can use either UI module interchangeably
function terminal.drawHeader() end
function terminal.drawStatus() end
function terminal.redrawContent() end
function terminal.drawInput() end

return terminal

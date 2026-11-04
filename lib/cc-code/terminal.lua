-- cc-code/terminal.lua
-- Simple line-mode interface (no full-screen TUI): prints to the current
-- terminal and reads input with CC's read()
--
-- Measuring is in screen cells (text.width / text.sub) and byte work uses
-- text.byteLen: the "CC: Tweaked Unicode Support" mod changes what # returns,
-- so # is never used on strings here.

local json = require("cmn-utils.json")
local cctext = require("cmn-utils.text")

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

-- Convert a value to a display string
local function toDisplay(value)
  if type(value) ~= "string" then
    local ok, encoded = pcall(json.encode, value)
    value = ok and encoded or tostring(value)
  end
  return cctext.forDisplay(value)
end

-- Shorten s to at most max cells, ending in "..." when cut
local function preview(s, max)
  if cctext.sub(s, max + 1, max + 1) == "" then
    return s
  end
  return cctext.sub(s, 1, max - 3) .. "..."
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

-- Print text (UTF-8 from the model, prepared for this terminal)
function terminal.print(msg, color)
  printText(cctext.forDisplay(tostring(msg)), color)
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
  printText(">> " .. cctext.forDisplay(tostring(name)), terminal.colors.toolName)
  if args then
    printText("   " .. preview(toDisplay(args), 80), terminal.colors.dim)
  end
end

-- Print tool result
function terminal.printToolResult(name, result)
  if not state.showTools then return end
  printText("<< " .. preview(toDisplay(result), 100), terminal.colors.dim)
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

-- Suffixes that complete line to one of choices (case-insensitive). A byte
-- prefix match: the suffix is whatever follows the typed bytes.
local function suffixes(line, choices)
  local lowerLine = line:lower()
  local lineLen = cctext.byteLen(line)
  local out = {}
  for _, choice in ipairs(choices) do
    if cctext.byteLen(choice) > lineLen and choice:sub(1, lineLen):lower() == lowerLine then
      out[#out + 1] = choice:sub(lineLen + 1)
    end
  end
  return out
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
          if type(item) == "table" and type(item.cmd) == "string" then
            choices[#choices + 1] = item.cmd
          end
        end
      end
      return suffixes(line, choices)
    end
  end

  -- Command names
  if line:find("%s") then
    return {}
  end
  return suffixes(line, commandNames)
end

-- Read user input with CC's read() (cursor keys, history, paste, Tab
-- completion). Ctrl+T clears a typed line; on an empty line it returns nil
-- (quit).
function terminal.readInput()
  -- A Ctrl+T held to cancel a request can land here if the reply came first.
  -- A fresh Ctrl+T sends a key event for T before the terminate, so quit
  -- only after one, or once the prompt has been up for a second.
  local startedAt = os.epoch("utc")
  local sawT = false

  while true do
    -- Reset terminal state before showing prompt
    resetTerminalState()
    setColor(terminal.colors.prompt)
    write("> ")
    term.setTextColour(ccColors.white)

    -- The line read() holds, or nil if unknown. read() passes it to the
    -- completion function after each edit with the cursor at the end (an
    -- empty line always qualifies), but not after Up/Down history recall.
    local current = ""
    local ok, line
    parallel.waitForAny(function()
      ok, line = pcall(read, nil, inputHistory, function(text)
        current = text
        return completeInput(text)
      end)
    end, function()
      -- pullEventRaw: this must survive the terminate
      while true do
        local _, key = os.pullEventRaw("key")
        if key == keys.up or key == keys.down then
          current = nil
        elseif key == keys.t then
          sawT = true
        end
      end
    end)

    if ok then
      if line and line ~= "" then
        -- read() left its echo on the row above; the caller prints the line
        -- again (printRole "user"), so remove read()'s copy
        local _, y = term.getCursorPos()
        if y > 1 then
          term.setCursorPos(1, y - 1)
          term.clearLine()
        end
        if inputHistory[#inputHistory] ~= line then
          table.insert(inputHistory, line)
        end
      end
      return line
    end

    if not tostring(line):find("Terminated", 1, true) then
      error(line, 0)
    end
    if current == "" and (sawT or os.epoch("utc") - startedAt >= 1000) then
      -- Ctrl+T at an empty prompt: quit
      print()
      return nil
    end
    -- Ctrl+T with text typed (or left over from cancelling the last
    -- request): clear the line and read again
    local _, y = term.getCursorPos()
    term.clearLine()
    term.setCursorPos(1, y)
  end
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

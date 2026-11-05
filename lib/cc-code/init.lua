-- cc-code/init.lua
-- Main module for cc-code: A Claude-like coding agent for ComputerCraft

local agent = require("cc-code.agent")
local tools = require("cc-code.tools")
local skills = require("cc-code.skills")
local capture = require("cc-code.capture")

local occode = {}

-- Re-export submodules
occode.agent = agent
occode.tools = tools
occode.skills = skills

-- Version
occode.version = "0.2.0"

-- Detect if we have TUI support. Every CC computer, turtle and pocket
-- computer has a terminal; the TUI just needs one at least this big.
function occode.hasTuiSupport()
  local w, h = term.getSize()
  return w >= 20 and h >= 8
end

-- Check if monochrome mode is needed (non-advanced computers are greyscale)
function occode.needsMonochrome()
  return not term.isColour()
end

-- Get the appropriate UI module
function occode.getUI(forceTerminal)
  if forceTerminal or not occode.hasTuiSupport() then
    return require("cc-code.terminal")
  else
    return require("cc-code.tui")
  end
end

-- Lazy load tui for backward compatibility
occode.tui = setmetatable({}, {
  __index = function(_, key)
    local tui = require("cc-code.tui")
    return tui[key]
  end
})

-- Lazy load terminal
occode.terminal = setmetatable({}, {
  __index = function(_, key)
    local terminal = require("cc-code.terminal")
    return terminal[key]
  end
})

-- "m:ss" for a number of seconds. The wait ticks come from 0.5 s timers,
-- which CC: Tweaked fires on 50 ms server ticks, so a sample can be a little
-- under the full second: round up from a quarter second short.
local function formatElapsed(seconds)
  seconds = math.floor(seconds + 0.25)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Callbacks for agent.process that keep the UI live during a turn: the
-- status bar shows how long the model has been thinking and the step, and
-- events that arrive while waiting (scrolling, resizes) reach the UI
local function turnCallbacks(ui)
  local step, maxSteps = 1, 1

  local function waitStatus(seconds)
    local parts = { "Thinking " .. formatElapsed(seconds) }
    if maxSteps > 1 then
      parts[#parts + 1] = "step " .. step .. "/" .. maxSteps
    end
    parts[#parts + 1] = "Ctrl+T cancels"
    ui.setStatus(parts)
  end

  return {
    onStepStart = function(s, m)
      step, maxSteps = s, m
      waitStatus(0)
    end,
    onWait = waitStatus,
    onEvent = function(...)
      if ui.handleEvent then
        ui.handleEvent(...)
      end
    end,
    onToolCall = function(name, args)
      ui.setStatus("Running " .. name .. "...")
      ui.printToolCall(name, args)
    end,
    onToolResult = function(name, result)
      ui.printToolResult(name, result)
    end,
  }
end

-- Internal run loop (shared between TUI and terminal modes)
local function runLoop(ui, config)
  -- Initialize agent
  agent.init(config)

  -- Initialize UI
  ui.init(config)

  -- Shell commands (! prefix and the shell tool) run with the UI's theme
  -- palette taken off, so programs they start don't inherit it
  if ui.suspendTheme then
    capture.hooks = { before = ui.suspendTheme, after = ui.resumeTheme }
  end

  ui.print("Welcome to cc-code v" .. occode.version, ui.colors and ui.colors.assistant)
  ui.print("Type /help for available commands.", ui.colors and ui.colors.dim)
  ui.print("Use !<command> to execute shell commands (e.g., !ls)", ui.colors and ui.colors.dim)
  if agent.state.modelWarning then
    -- The saved cc-code.model setting is not a model
    ui.print("cc-code.model: " .. agent.state.modelWarning, ui.colors and ui.colors.error)
  end
  ui.print("", ui.colors and ui.colors.foreground)

  -- Main loop
  while ui.isRunning() do
    ui.setStatus("Ready")

    local input = ui.readInput()

    if input == nil then
      -- Ctrl+T at an empty prompt: exit, like other CraftOS programs
      ui.stop()
    elseif input == "" then
      -- Empty input, do nothing
    else
      -- Show user input
      ui.printRole("user", input)

      -- Process input
      ui.setStatus("Thinking...")

      local result = agent.process(input, turnCallbacks(ui))

      -- Handle result
      if result.type == "command" then
        if result.command == "exit" then
          ui.stop()
        elseif result.command == "clear" then
          ui.clear()
          ui.print("Conversation cleared.", ui.colors and ui.colors.dim)
        end
      elseif result.type == "error" then
        ui.printRole("error", result.text)
      elseif result.type == "direct" then
        ui.print(result.text, ui.colors and ui.colors.foreground)
      elseif result.type == "response" then
        if result.text and result.text:find("%S") then
          ui.printRole("assistant", result.text)
        end
        -- Why the turn ended early (step limit, cut off, empty reply)
        if result.notice then
          ui.print("(" .. result.notice .. ")", ui.colors and ui.colors.dim)
        end
      end

      ui.print("", ui.colors and ui.colors.foreground)
    end
  end

  -- Cleanup
  capture.hooks = nil
  ui.cleanup()
  print("Goodbye!")
end

-- Run the loop, restoring the screen (palette, colours) if anything errors
local function runProtected(ui, config)
  local ok, err = pcall(runLoop, ui, config)
  if not ok then
    capture.hooks = nil
    pcall(ui.cleanup)
    error(err, 0)
  end
end

-- Run the interactive application (auto-detects TUI vs terminal)
function occode.run(config)
  config = config or {}

  -- Auto-detect monochrome mode for 1-bit displays (unless already set)
  if config.monochrome == nil and occode.needsMonochrome() then
    config.monochrome = true
  end

  local ui = occode.getUI(config.forceTerminal)
  runProtected(ui, config)
end

-- Run in TUI mode
function occode.runTui(config)
  local tui = require("cc-code.tui")
  runProtected(tui, config)
end

-- Run in terminal mode (line-based, for tiny screens or when forced)
function occode.runTerminal(config)
  local terminal = require("cc-code.terminal")
  runProtected(terminal, config)
end

-- Simple non-TUI mode for scripting
function occode.chat(prompt, config)
  agent.init(config)
  local result = agent.process(prompt)
  return result.text, result
end

-- One-shot command execution
function occode.exec(prompt, config)
  config = config or {}
  config.maxSteps = config.maxSteps or 5
  return occode.chat(prompt, config)
end

return occode

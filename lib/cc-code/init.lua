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

-- The install's root directory (".../cc-ai"), found from this file
local installRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/lib/cc%-code/init%.lua$")

-- What the installer recorded in <install root>/.version: { repo, branch,
-- commit, installed }, or nil (not installed by install.lua, e.g. a copy)
function occode.installInfo()
  if not installRoot then return nil end
  local path = installRoot .. "/.version"
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local content = handle.readAll()
  handle.close()
  local info = textutils.unserialize(content or "")
  return type(info) == "table" and info or nil
end

-- "v0.2.0" plus the installed commit when known: "v0.2.0 (f3e7a15)"
function occode.versionText()
  local info = occode.installInfo()
  local commit = info and type(info.commit) == "string" and info.commit:match("^%x+$") and info.commit
  return "v" .. occode.version .. (commit and (" (" .. commit:sub(1, 7) .. ")") or "")
end

-- Which full-screen UI cc-code uses: "tui" (the default) or "basalt" (the
-- trial UI built on Basalt, which is downloaded the first time it is used)
local UI_SETTING = "cc-code.ui"
if settings and settings.define then
  pcall(settings.define, UI_SETTING, {
    description = "cc-code's interface: tui (default) or basalt (trial; downloads Basalt on first use)",
    type = "string",
  })
end

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
-- events that arrive while waiting (scrolling, resizes) reach the UI.
-- ui.setStatus and ui.handleEvent are called from inside the SDK's HTTP
-- wait hooks, so they must not yield.
function occode.turnCallbacks(ui)
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
    onToolResult = function(name, result, args)
      ui.printToolResult(name, result, args)
    end,
  }
end

-- Problems to show with the welcome lines of the next session (the Basalt
-- UI that could not be loaded): the screen is cleared when a UI starts,
-- so a line printed before it would not be seen
local startupNotes = {}

-- How many sessions startSession has started. occode.run tells by it
-- whether the Basalt UI failed before its session started (it could not
-- start, e.g. a bundle without an element it needs: the TUI runs instead)
-- or in the session (the error is raised).
local sessionsStarted = 0

-- Start a session in a UI (every UI's first step): the agent and the UI
-- are initialised, shell commands get the UI's palette hooks, the UI learns
-- the tool display mode and the skill commands, and the welcome lines are
-- printed with any problems found while loading
function occode.startSession(ui, config)
  -- Initialize agent
  agent.init(config)

  -- Initialize UI
  ui.init(config)

  -- Shell commands (! prefix and the shell tool) run with the UI's theme
  -- palette taken off, so programs they start don't inherit it
  if ui.suspendTheme then
    capture.hooks = { before = ui.suspendTheme, after = ui.resumeTheme }
  end

  -- How tool calls are shown (/tools; agent.state.toolDisplay keeps the
  -- mode applied, which a bare /tools reports), and skill commands for
  -- completion
  if ui.setToolDisplay then
    agent.state.toolDisplay = agent.toolDisplay()
    ui.setToolDisplay(agent.state.toolDisplay)
  end
  if ui.addCommand then
    local skillList = skills.getAll()
    table.sort(skillList, function(a, b) return a.name < b.name end)
    for _, skill in ipairs(skillList) do
      for _, command in ipairs(skill.commands or {}) do
        ui.addCommand(command, skill.description)
      end
    end
  end

  ui.print("Welcome to cc-code " .. occode.versionText(), ui.colors and ui.colors.assistant)
  ui.print("Type /help for available commands.", ui.colors and ui.colors.dim)
  ui.print("Use !<command> to execute shell commands (e.g., !ls)", ui.colors and ui.colors.dim)
  if agent.state.modelWarning then
    -- The saved cc-code.model setting is not a model
    ui.print("cc-code.model: " .. agent.state.modelWarning, ui.colors and ui.colors.error)
  end
  -- Skills that did not load, commands one skill took over from another,
  -- skill commands that are built-in commands, skill tools that can't be
  -- used (the messages are complete as given)
  for _, problem in ipairs(agent.state.skillErrors or {}) do
    ui.print(problem, ui.colors and ui.colors.error)
  end
  local notes = startupNotes
  startupNotes = {}
  for _, note in ipairs(notes) do
    ui.print(note, ui.colors and ui.colors.error)
  end
  ui.print("", ui.colors and ui.colors.foreground)
  sessionsStarted = sessionsStarted + 1
end

-- Show what agent.process returned for a prompt: commands (/exit stops the
-- UI, /clear, /tools), an error, direct output (/help, /model, !cmd), or
-- the model's reply with why it ended early, then the turn's warnings and a
-- blank line
function occode.showResult(ui, result)
  if result.type == "command" then
    if result.command == "exit" then
      ui.stop()
    elseif result.command == "clear" then
      ui.clear()
      ui.print("Conversation cleared.", ui.colors and ui.colors.dim)
    elseif result.command == "tools" then
      if ui.setToolDisplay then
        agent.state.toolDisplay = result.mode
        ui.setToolDisplay(result.mode)
      end
      ui.print("Tool calls are now shown: " .. result.mode .. " (saved for next time)",
        ui.colors and ui.colors.dim)
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
  -- Problems the turn ran into that the user should know about (e.g.
  -- a skill whose systemPrompt failed)
  for _, warning in ipairs(result.warnings or {}) do
    ui.print(warning, ui.colors and ui.colors.error)
  end

  ui.print("", ui.colors and ui.colors.foreground)
end

-- End a session: shell commands lose the UI's hooks, the UI gives the
-- screen back, and the goodbye goes to the restored terminal
function occode.endSession(ui)
  capture.hooks = nil
  ui.cleanup()
  print("Goodbye!")
end

-- The run loop of the TUI and terminal UIs, which read a prompt with
-- ui.readInput and run its turn before reading the next
local function runLoop(ui, config)
  occode.startSession(ui, config)

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

      local result = agent.process(input, occode.turnCallbacks(ui))
      occode.showResult(ui, result)
    end
  end

  occode.endSession(ui)
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

-- Whether this run asks for the Basalt UI: config.basalt (cc-code --basalt
-- or --tui) decides, else the cc-code.ui setting
function occode.wantsBasalt(config)
  if config.basalt ~= nil then
    return config.basalt == true
  end
  local value = settings and settings.get(UI_SETTING)
  return type(value) == "string" and value:lower():match("^%s*(.-)%s*$") == "basalt"
end

-- The Basalt API and the Basalt UI's app module, or nil and why not (the
-- bundle or the UI's files, which a minimal install leaves out, could not
-- be found, downloaded or loaded). Ctrl+T during the download ends
-- cc-code, as it ends other programs.
local function loadBasaltUI()
  local ok, loader = pcall(require, "cc-code.basalt.load")
  if not ok then
    return nil, tostring(loader)
  end
  local loaded, basalt, reason = pcall(loader.load, { status = print })
  if not loaded then
    if basalt == "Terminated" then error(basalt, 0) end
    return nil, tostring(basalt)
  end
  if not basalt then
    return nil, tostring(reason or "unknown problem")
  end
  local appOk, app = pcall(require, "cc-code.basalt.app")
  if not appOk then
    return nil, tostring(app)
  end
  if type(app) ~= "table" or type(app.run) ~= "function" then
    return nil, "cc-code.basalt.app is not the Basalt UI's app module"
  end
  return basalt, nil, app
end

-- Run the Basalt UI. Returns true and app.run's result, or false and the
-- error when the UI failed before its session started. An error in the
-- session (or Ctrl+T's "Terminated") is raised.
local function runBasalt(app, config, basalt)
  local before = sessionsStarted
  local ok, result = pcall(app.run, config, basalt)
  if ok then
    return true, result
  end
  if sessionsStarted ~= before or result == "Terminated" then
    error(result, 0)
  end
  return false, result
end

-- Run the interactive application: the Basalt UI when asked for (and it
-- loads and starts), else the TUI, or the line-based terminal UI on
-- screens smaller than 20x8 or when forced
function occode.run(config)
  config = config or {}

  -- Auto-detect monochrome mode for 1-bit displays (unless already set)
  if config.monochrome == nil and occode.needsMonochrome() then
    config.monochrome = true
  end

  if not config.forceTerminal and occode.hasTuiSupport() and occode.wantsBasalt(config) then
    local basalt, reason, app = loadBasaltUI()
    if basalt then
      local ran, result = runBasalt(app, config, basalt)
      if ran then
        return result
      end
      -- It could not start: app.run gave the screen back
      reason = result
    end
    -- One line (the reason's first), here and with the TUI's welcome lines
    local note = "Basalt UI not available (" .. tostring(reason):match("^[^\n]*") .. "); using the standard UI."
    print(note)
    table.insert(startupNotes, note)
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

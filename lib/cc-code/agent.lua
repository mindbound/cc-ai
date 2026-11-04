-- cc-code/agent.lua
-- Core agent logic for cc-code

local ai = require("ai")
local aiUtils = require("ai.utils")
local tools = require("cc-code.tools")
local skills = require("cc-code.skills")
local capture = require("cc-code.capture")
local cmnPath = require("cmn-utils.path")
local text = require("cmn-utils.text")

local agent = {}

-- Directory this module was loaded from (".../lib/cc-code"), used to find
-- the built-in skills wherever cc-ai is installed
local moduleDir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/agent%.lua$")

-- Default configuration
agent.config = {
  model = "anthropic/claude-sonnet-4",
  maxSteps = 10,
  maxOutputTokens = 4096,
  temperature = 0.7,
  systemPrompt = nil,
  -- HTTP idle timeout in seconds. 0 = none: a non-streaming reply sends
  -- nothing until it is complete, and CC: Tweaked caps timeouts at 60s,
  -- which long answers can exceed. Hold Ctrl+T to cancel instead.
  timeout = 0,
}

-- Convert every string in a tool result to UTF-8 (file contents, shell
-- output and names on the computer are CC charset; JSON must be UTF-8)
local function toUtf8Deep(value)
  if type(value) == "string" then
    return text.fromCC(value)
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = toUtf8Deep(v)
    end
    return out
  end
  return value
end

-- Agent state
agent.state = {
  messages = {},
  workingDirectory = nil,
  context = {},
}

-- Build system prompt with context
local function buildSystemPrompt()
  local parts = {}

  local pwd = agent.state.workingDirectory or cmnPath.cwd()
  local w, h = term.getSize()
  local machine = turtle and "turtle" or (pocket and "pocket computer" or "computer")
  if term.isColour() then
    machine = "advanced " .. machine
  end

  -- Base system prompt
  table.insert(parts, [[
You are cc-code, an AI coding assistant running inside Minecraft ComputerCraft: Tweaked (CraftOS).
You help the user write, debug, and run Lua programs on this in-game computer by reading, writing, and editing files and running shell commands.

## Environment
- Platform: Minecraft ComputerCraft: Tweaked, CraftOS, Lua 5.2 (Cobalt VM)
- Lua 5.2 rules: no integer division `//`, no bitwise operators (use `bit32`), no `string.pack`. `goto` and the `utf8` library are available.
- CC APIs are globals (no require): `fs`, `term`, `colors`, `keys`, `os` (os.pullEvent, os.sleep, os.startTimer, os.epoch), `peripheral` (peripheral.find("monitor") etc.), `http` (if enabled), `textutils`, `settings`, `parallel`, `rednet`, `gps`, `redstone`, `window`, `turtle` (turtles only), `pocket` (pocket computers only). `require` loads modules relative to the running program's directory and from /rom/modules (e.g. `require("cc.strings")`).
- Programs are run by typing their path plus arguments (e.g. `hello` or `mine 3`); the `.lua` extension is optional. Arguments arrive as `...`.
- A program that runs ~7 seconds without yielding is killed with "Too long without yielding": in long loops call `os.sleep(0)` or pull an event. Turtle movement and sleep already yield.
- Screen: this is a ]] .. machine .. [[ with a ]] .. w .. "x" .. h .. [[ character screen (]] .. (term.isColour() and "16 colours" or "greyscale only") .. [[). Colours are `colors.*` constants.
- No package manager: extra code only via `wget <url> <file>` or `pastebin get <code> <file>`. Do not assume LuaRocks, io.popen or os.execute.
- Current directory: ]] .. pwd)

  -- Add working directory contents summary if available
  if fs.exists(pwd) and fs.isDir(pwd) then
    local entries = {}
    for _, entry in ipairs(fs.list(pwd)) do
      table.insert(entries, entry)
      if #entries >= 20 then
        table.insert(entries, "...")
        break
      end
    end
    if #entries > 0 then
      table.insert(parts, "\n- Directory contents: " .. table.concat(entries, ", "))
    end
  end

  -- Core instructions
  table.insert(parts, [[

## Tools
You have: read_file, write_file, edit_file, list_directory, glob, grep, shell.
- read_file before edit_file; edit_file (exact string match) for existing files, write_file only for new files or full rewrites
- Find files with glob and search content with grep instead of chains of shell ls calls
- shell runs CraftOS commands (ls, cp, mv, rm, mkdir, or a program path) and captures what they print; there is no cat/echo/grep, so prefer the file tools when one fits
- Verify your work: after writing a program, run it by its path via shell and check the output; fix errors before declaring done. Never run interactive programs (edit, lua, paint) or ones that wait for user input

## Writing Lua for this system
- Match repo style: 2-space indent, double quotes, `local` everything, modules return a table
- Wrap risky calls in pcall (JSON decode, peripheral calls, network); use error("message") for failures
- Use plain ASCII in strings and comments: the CC screen shows UTF-8 characters such as dashes, arrows or emoji as garbage
- Check a peripheral exists (peripheral.find / peripheral.isPresent) before using it
- Keep memory small: stream or process line-by-line, avoid building large strings/tables

## Interaction
- Terminal screen is tiny: answer in a few short lines, plain text, no markdown formatting
- Do the task, then state what you did in one or two lines; if genuinely ambiguous, ask one short question instead of guessing
- The user can bypass you with !<command> to run shell commands directly
]])

  -- Add active skill system prompts
  for _, skill in pairs(skills.registry) do
    if skill.systemPrompt then
      table.insert(parts, "\n## " .. skill.name .. " Skill\n" .. skill.systemPrompt)
    end
  end

  -- Add custom system prompt if configured
  if agent.config.systemPrompt then
    table.insert(parts, "\n## Custom Instructions\n" .. agent.config.systemPrompt)
  end

  -- Add project instructions: prefer .cc-code.md (written for this agent);
  -- fall back to CLAUDE.md, which may be host-side docs and is capped harder
  local instructionFiles = {
    { name = ".cc-code.md", cap = 4000 },
    { name = "CLAUDE.md", cap = 2000 },
  }
  for _, f in ipairs(instructionFiles) do
    local path = cmnPath.join(pwd, f.name)
    if fs.exists(path) and not fs.isDir(path) then
      local handle = fs.open(path, "rb")
      if handle then
        local content = handle.readAll()
        handle.close()
        if content and #content > 0 then
          local truncated = #content > f.cap
          table.insert(parts, "\n## Project Instructions (" .. f.name .. ")\n" ..
            content:sub(1, f.cap) .. (truncated and "\n[truncated]" or ""))
          break
        end
      end
    end
  end

  return table.concat(parts, "\n")
end

-- Get all available tools
local function getAllTools()
  local allTools = tools.getAll()
  local skillTools = skills.getAllTools()
  for _, tool in ipairs(skillTools) do
    table.insert(allTools, tool)
  end
  return allTools
end

-- Initialize agent
function agent.init(config)
  if config then
    for k, v in pairs(config) do
      agent.config[k] = v
    end
  end

  agent.state.workingDirectory = cmnPath.cwd()
  agent.state.messages = {}
  agent.state.context = {}

  -- Load built-in skills (lib/cc-code/skills next to this module)
  if moduleDir then
    local skillsDir = moduleDir .. "/skills"
    if fs.exists(skillsDir) then
      skills.loadFromDirectory(skillsDir)
    end
  end

  -- Also try local skills directory
  local localSkillsDir = cmnPath.join(agent.state.workingDirectory, ".cc-code/skills")
  if fs.exists(localSkillsDir) then
    skills.loadFromDirectory(localSkillsDir)
  end

  return agent
end

-- Check if API key is configured for the model
local function checkApiKey(model)
  -- Determine provider and required key
  local provider, requiredKey

  if type(model) == "string" then
    -- String models always use Vercel AI Gateway
    provider = "vercel"
    requiredKey = "AI_GATEWAY_API_KEY"
  elseif type(model) == "table" and model.provider then
    -- Direct provider model object - check provider-specific key
    provider = model.provider
    if provider == "openai" then
      requiredKey = "OPENAI_API_KEY"
    elseif provider == "google" then
      requiredKey = "GOOGLE_GENERATIVE_AI_API_KEY"
    elseif provider == "groq" then
      requiredKey = "GROQ_API_KEY"
    end
  else
    -- Unknown model type, can't check
    return true
  end

  if requiredKey then
    local apiKey = aiUtils.getEnv(requiredKey)
    if not apiKey or apiKey == "" then
      return false, requiredKey, provider
    end
  end

  return true
end

-- Process a user message
function agent.process(input, callbacks)
  callbacks = callbacks or {}
  local onToolCall = callbacks.onToolCall
  local onToolResult = callbacks.onToolResult

  -- Check for shell commands (! prefix)
  if input:sub(1, 1) == "!" then
    local command = input:sub(2):match("^%s*(.-)%s*$") -- trim whitespace
    if command == "" then
      return { type = "error", text = "No command specified" }
    end

    -- Execute shell command, capturing what it prints
    local success, output, terminated = capture.run(command)
    agent.state.workingDirectory = cmnPath.cwd() -- `cd` may have changed it

    if terminated then
      output = output .. (output ~= "" and "\n" or "") .. "(stopped with Ctrl+T)"
    end
    if output == "" then
      output = success and "(command executed, no output)" or "(command failed, no output)"
    end
    return {
      type = "direct",
      text = output
    }
  end

  -- Check for slash commands
  if input:sub(1, 1) == "/" then
    local parts = {}
    for part in input:gmatch("%S+") do
      table.insert(parts, part)
    end
    local command = parts[1]
    local args = table.concat(parts, " ", 2)

    -- Handle built-in commands
    if command == "/clear" then
      agent.state.messages = {}
      return { type = "command", command = "clear" }
    elseif command == "/exit" or command == "/quit" then
      return { type = "command", command = "exit" }
    end

    -- Check skills for command handler
    local skill = skills.findByCommand(command)
    if skill and skill.onActivate then
      local prompt, directResult = skill.onActivate(agent, args)
      if directResult then
        return { type = "direct", text = directResult }
      end
      if prompt then
        input = prompt
      end
    end
  end

  -- Add user message (snapshot first: the tool loop appends tool-call/result
  -- messages to this same table, so error recovery must trim back to here)
  local messageSnapshot = #agent.state.messages
  table.insert(agent.state.messages, { role = "user", content = text.fromCC(input) })

  -- Check if API key is configured
  local hasKey, requiredKey, provider = checkApiKey(agent.config.model)
  if not hasKey then
    local errorMsg = string.format(
      "No API key found. Please set your API key:\n\n" ..
      "1. Exit and run: set %s <key>\n" ..
      "2. Or use /model command to switch to a different provider\n\n" ..
      "Current model: %s (requires %s provider)",
      requiredKey,
      agent.config.model,
      provider
    )

    -- Remove the user message we just added since we're not processing it
    table.remove(agent.state.messages)

    return {
      type = "error",
      text = errorMsg,
      error = "missing_api_key",
    }
  end

  -- Build options
  local opts = {
    model = agent.config.model,
    messages = agent.state.messages,
    system = buildSystemPrompt(),
    tools = getAllTools(),
    maxSteps = agent.config.maxSteps,
    maxOutputTokens = agent.config.maxOutputTokens,
    temperature = agent.config.temperature,
    timeout = agent.config.timeout,
  }

  -- Use non-streaming mode
  local result
  local success, err

  -- Wrap tool execution to provide callbacks and convert results to UTF-8
  -- Create copies to avoid mutating original tools (prevents wrapper accumulation)
  do
    local wrappedTools = {}
    for _, tool in ipairs(opts.tools) do
      -- Create a shallow copy of the tool table
      local toolCopy = {}
      for k, v in pairs(tool) do
        toolCopy[k] = v
      end

      -- Copy the function table
      toolCopy["function"] = {}
      for k, v in pairs(tool["function"]) do
        toolCopy["function"][k] = v
      end

      -- Wrap the execute function
      local origExecute = tool["function"].execute
      toolCopy["function"].execute = function(args)
        if onToolCall then
          onToolCall(tool["function"].name, args)
        end
        local result = toUtf8Deep(origExecute(args))
        if onToolResult then
          onToolResult(tool["function"].name, result)
        end
        return result
      end

      table.insert(wrappedTools, toolCopy)
    end

    -- Use wrapped tools instead of mutated originals
    opts.tools = wrappedTools
  end

  success, err = pcall(function()
    result = ai.generateText(opts)
  end)
  agent.state.workingDirectory = cmnPath.cwd() -- a shell tool call may have run `cd`

  -- Handle errors from API calls
  if not success then
    -- Trim everything added this turn (user message plus any tool-call/result
    -- messages the tool loop appended before failing)
    while #agent.state.messages > messageSnapshot do
      table.remove(agent.state.messages)
    end

    local errorMsg = tostring(err)

    -- Check if it's an API key error
    if errorMsg == "Terminated" then
      errorMsg = "Request cancelled (Ctrl+T)."
    else
      for _, keyName in ipairs({ "OPENAI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", "GROQ_API_KEY", "AI_GATEWAY_API_KEY" }) do
        if errorMsg:match(keyName) then
          errorMsg = "No API key found. Please set your API key:\n\n" ..
                     "Exit and run: set " .. keyName .. " <key>\n" ..
                     "Or use /model command to switch to a different provider"
          break
        end
      end
    end

    return {
      type = "error",
      text = errorMsg,
      error = "api_call_failed",
    }
  end

  -- Add assistant response to history
  if result and result.text then
    table.insert(agent.state.messages, { role = "assistant", content = result.text })
  end

  return {
    type = "response",
    text = result and result.text or "",
    finishReason = result and result.finishReason,
    toolResults = result and result.toolResults,
    usage = result and result.usage,
  }
end

-- Get conversation history
function agent.getHistory()
  return agent.state.messages
end

-- Clear conversation
function agent.clearHistory()
  agent.state.messages = {}
end

-- Set working directory
function agent.setWorkingDirectory(path)
  local resolved = cmnPath.resolve(path)
  if fs.exists(resolved) and fs.isDir(resolved) then
    shell.setDir(fs.combine(resolved, ""))
    agent.state.workingDirectory = resolved
    return true
  end
  return false
end

-- Export for use
return agent

-- oc-code/agent.lua
-- Core agent logic for oc-code

local ai = require("ai")
local tools = require("oc-code.tools")
local skills = require("oc-code.skills")
local fs = require("filesystem")
local shell = require("shell")

local agent = {}

-- Default configuration
agent.config = {
  model = "anthropic/claude-sonnet-4",
  maxSteps = 10,
  maxOutputTokens = 4096,
  temperature = 0.7,
  systemPrompt = nil,
}

-- Agent state
agent.state = {
  messages = {},
  workingDirectory = nil,
  context = {},
}

-- Build system prompt with context
local function buildSystemPrompt()
  local parts = {}

  -- Base system prompt
  table.insert(parts, [[
You are oc-code, an AI coding assistant running inside Minecraft OpenComputers (OpenOS).
You help the user write, debug, and run Lua programs on this in-game computer by reading, writing, and editing files and running shell commands.

## Environment
- Platform: Minecraft OpenComputers, OpenOS, Lua 5.2 subset
- Lua 5.2 rules: no integer division `//`, no bitwise operators (use `bit32`), no `string.pack`. `goto` is available.
- OC APIs via require: `component`, `computer`, `filesystem`, `shell`, `term`, `event`, `internet` (needs internet card), `robot` (robots only), `sides`, `serialization`
- Hardware is limited: small RAM, small screen. Long loops must yield (`os.sleep(0)` or `event.pull`) or OpenOS kills the program with "too long without yielding".
- No package manager at runtime; extra libraries only via OPPM. Do not assume LuaRocks or io.popen.
- Current directory: ]] .. (agent.state.workingDirectory or shell.getWorkingDirectory() or "/home"))

  -- Add working directory contents summary if available
  local pwd = agent.state.workingDirectory or shell.getWorkingDirectory() or "/home"
  if fs.exists(pwd) and fs.isDirectory(pwd) then
    local entries = {}
    for entry in fs.list(pwd) do
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
- Find files with glob and search content with grep instead of shell ls/cat chains
- shell runs OpenOS commands (ls, cat, cp, mv, rm, mkdir, lua ...); stdout capture is limited, so prefer the file tools when one fits
- Verify your work: after writing a program, run it with `lua <file>` via shell and check the output; fix errors before declaring done

## Writing Lua for this system
- Match repo style: 2-space indent, double quotes, `local` everything, modules return a table
- Wrap risky calls in pcall (JSON decode, component access, network); use error("message") for failures
- Check a component exists (component.isAvailable) before using it
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

  -- Add project instructions: prefer .oc-code.md (written for this agent);
  -- fall back to CLAUDE.md, which may be host-side docs and is capped harder
  local instructionFiles = {
    { name = ".oc-code.md", cap = 4000 },
    { name = "CLAUDE.md", cap = 2000 },
  }
  for _, f in ipairs(instructionFiles) do
    local path = fs.concat(pwd, f.name)
    if fs.exists(path) then
      local handle = io.open(path, "r")
      if handle then
        local content = handle:read("*a")
        handle:close()
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

  agent.state.workingDirectory = shell.getWorkingDirectory() or "/home"
  agent.state.messages = {}
  agent.state.context = {}

  -- Load built-in skills
  local skillsDir = "/usr/lib/oc-code/skills"
  if fs.exists(skillsDir) then
    skills.loadFromDirectory(skillsDir)
  end

  -- Also try local skills directory
  local localSkillsDir = fs.concat(agent.state.workingDirectory, ".oc-code/skills")
  if fs.exists(localSkillsDir) then
    skills.loadFromDirectory(localSkillsDir)
  end

  return agent
end

-- Check if API key is configured for the model
local function checkApiKey(model)
  local os = require("os")

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
    local apiKey = os.getenv(requiredKey)
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

    -- Execute shell command using OpenOS shell.execute
    local tempFile = "/tmp/.oc-code-shell-out"
    local cmdWithRedirect = command .. " > " .. tempFile .. " 2>&1"

    local success, reason = shell.execute(cmdWithRedirect)

    local output = ""
    if fs.exists(tempFile) then
      local handle = io.open(tempFile, "r")
      if handle then
        output = handle:read("*a") or ""
        handle:close()
      end
      fs.remove(tempFile)
    end

    -- If redirect didn't work, try executing without redirect
    if output == "" and not success then
      success, reason = shell.execute(command)
      output = reason or (success and "Command completed" or "Command failed")
    end

    return {
      type = "direct",
      text = output ~= "" and output or "(command executed, no output)"
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
  table.insert(agent.state.messages, { role = "user", content = input })

  -- Check if API key is configured
  local hasKey, requiredKey, provider = checkApiKey(agent.config.model)
  if not hasKey then
    local errorMsg = string.format(
      "No API key found. Please set your API key:\n\n" ..
      "1. Set environment variable: %s\n" ..
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
  }

  -- Use non-streaming mode
  local result
  local success, err

  -- Wrap tool execution to provide callbacks
  -- Create copies to avoid mutating original tools (prevents wrapper accumulation)
  if onToolCall or onToolResult then
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
        local result = origExecute(args)
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

  -- Handle errors from API calls
  if not success then
    -- Trim everything added this turn (user message plus any tool-call/result
    -- messages the tool loop appended before failing)
    while #agent.state.messages > messageSnapshot do
      table.remove(agent.state.messages)
    end

    local errorMsg = tostring(err)

    -- Check if it's an API key error
    if errorMsg:match("API key is required") or errorMsg:match("OPENAI_API_KEY") then
      errorMsg = "No API key found. Please set your API key:\n\n" ..
                 "Set environment variable: OPENAI_API_KEY\n" ..
                 "Or use /model command to switch to a different provider"
    elseif errorMsg:match("GOOGLE_GENERATIVE_AI_API_KEY") then
      errorMsg = "No API key found. Please set your API key:\n\n" ..
                 "Set environment variable: GOOGLE_GENERATIVE_AI_API_KEY\n" ..
                 "Or use /model command to switch to a different provider"
    elseif errorMsg:match("GROQ_API_KEY") then
      errorMsg = "No API key found. Please set your API key:\n\n" ..
                 "Set environment variable: GROQ_API_KEY\n" ..
                 "Or use /model command to switch to a different provider"
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
  if fs.exists(path) and fs.isDirectory(path) then
    agent.state.workingDirectory = fs.canonical(path)
    shell.setWorkingDirectory(agent.state.workingDirectory)
    return true
  end
  return false
end

-- Export for use
return agent

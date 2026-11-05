-- cc-code/agent.lua
-- Core agent logic for cc-code

local ai = require("ai")
local aiUtils = require("ai.utils")
local tools = require("cc-code.tools")
local skills = require("cc-code.skills")
local capture = require("cc-code.capture")
local cmnPath = require("cmn-utils.path")
local text = require("cmn-utils.text")
local json = require("cmn-utils.json")
local secrets = require("cc-code.secrets")

local agent = {}

-- Directory this module was loaded from (".../lib/cc-code"), used to find
-- the built-in skills wherever cc-ai is installed
local moduleDir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/agent%.lua$")

-- Defaults used when neither the config nor a setting gives a value
local DEFAULT_MODEL = "anthropic/claude-sonnet-4"
local DEFAULT_MAX_STEPS = 25
-- Output token cap for providers that need one. The custom provider sends
-- none by default: thinking models count their reasoning against it.
local DEFAULT_MAX_OUTPUT_TOKENS = 4096

-- Settings (shown and changed with the `set` program)
local SETTINGS = {
  model = "cc-code.model",
  maxSteps = "cc-code.max_steps",
  maxOutputTokens = "cc-code.max_output_tokens",
  tools = "cc-code.tools",
}

-- How tool calls are shown (/tools): one line each, the arguments and
-- result as JSON previews, or not at all
local TOOL_DISPLAYS = { short = true, full = true, off = true }
local DEFAULT_TOOL_DISPLAY = "short"

-- Skills the user adds for every directory. Outside /cc-ai, so updates
-- (which replace /cc-ai/lib) leave them alone.
agent.USER_SKILLS_DIR = "/.cc-code/skills"

-- Commands handled here rather than by a skill
local BUILTIN_COMMANDS = { "/clear", "/exit", "/quit", "/tools" }

if settings and settings.define then
  pcall(settings.define, SETTINGS.model, {
    description = "cc-code's model, e.g. custom:<model id> or creator/model for the AI Gateway",
    type = "string",
  })
  pcall(settings.define, SETTINGS.maxSteps, {
    description = "cc-code: most model requests (tool steps) per prompt",
    type = "number",
  })
  pcall(settings.define, SETTINGS.maxOutputTokens, {
    description = "cc-code: output token cap per reply (default: none for custom, 4096 for others)",
    type = "number",
  })
  pcall(settings.define, SETTINGS.tools, {
    description = "cc-code: how tool calls are shown: short (one line), full (JSON previews) or off",
    type = "string",
  })
end

-- How tool calls are shown: "short", "full" or "off" (setting cc-code.tools)
function agent.toolDisplay()
  local value = settings and settings.get(SETTINGS.tools)
  if type(value) == "string" and TOOL_DISPLAYS[value:lower()] then
    return value:lower()
  end
  return DEFAULT_TOOL_DISPLAY
end

-- Default configuration (init fills in model, maxSteps and maxOutputTokens
-- from the config passed to it, then from settings)
agent.config = {
  model = DEFAULT_MODEL,
  maxSteps = DEFAULT_MAX_STEPS,
  maxOutputTokens = nil,
  temperature = 0.7,
  systemPrompt = nil,
  -- HTTP idle timeout in seconds. 0 = none: a non-streaming reply sends
  -- nothing until it is complete, and CC: Tweaked caps timeouts at 60s,
  -- which long answers can exceed. Hold Ctrl+T to cancel instead.
  timeout = 0,
}

-- A positive whole number from a setting, or nil
local function numberSetting(name)
  local value = settings and tonumber(settings.get(name))
  if value and value >= 1 then
    return math.floor(value)
  end
  return nil
end

-- Turn a model spec into a model: "custom:<id>" etc. (see ai.resolveModel)
-- or a gateway "creator/model" string. Returns nil and a message when the
-- spec is not a model (e.g. a bare provider name such as "custom").
function agent.resolveModel(spec)
  local ok, model = pcall(ai.resolveModel, spec)
  if ok and (type(model) == "table" or (type(model) == "string" and model:find("/", 1, true))) then
    return model
  end
  return nil, "'" .. tostring(spec) .. "' is not a model (use custom:<model>, " ..
    "google:<model> and so on, or creator/model for the AI Gateway)"
end

-- Save the model as the default for later runs (cc-code.model)
function agent.saveModel(model)
  if not settings then return end
  settings.set(SETTINGS.model, ai.modelSpec(model))
  pcall(settings.save)
end

-- The output token cap to send for a model (nil = none)
local function outputTokenCap(model)
  if agent.config.maxOutputTokens then
    return agent.config.maxOutputTokens
  end
  local fromSetting = numberSetting(SETTINGS.maxOutputTokens)
  if fromSetting then
    return fromSetting
  end
  if type(model) == "table" and model.provider == "custom" then
    return nil
  end
  return DEFAULT_MAX_OUTPUT_TOKENS
end

-- Convert every string in a tool result to UTF-8, table keys too (file
-- contents, shell output and names on the computer are CC charset; JSON
-- must be UTF-8)
local function toUtf8Deep(value)
  if type(value) == "string" then
    return text.fromCC(value)
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      if type(k) == "string" then
        k = text.fromCC(k)
      end
      out[k] = toUtf8Deep(v)
    end
    return out
  end
  return value
end

-- Why a tool result can't be sent as JSON, or nil. The encoder rejects a
-- list with gaps (such as the slots inventory.list() returns), mixed keys,
-- NaN, infinity and functions. The provider would only find out after the
-- tool ran, and end the turn (Google: keep the result in the history, so
-- every later request failed).
local function jsonProblem(result)
  local ok, err = pcall(json.encode, result)
  if ok then
    return nil
  end
  -- (without the "json.lua:88: " position)
  return "The tool's result can't be sent as JSON (" .. (tostring(err):gsub("^[^:]*:%d+: ", "")) ..
    "): return a table with string keys, or a list without gaps"
end

-- Secrets: the values of settings whose names say they are secret (API
-- keys, tokens, passwords) are blanked out of what the model is sent
-- (cc-code.secrets has the details)
agent.REDACTED = secrets.REDACTED
agent.secretValues = secrets.values
agent.redact = secrets.redact
local redactDeep = secrets.redactDeep

-- Cut s to at most cap bytes without splitting a UTF-8 sequence. Returns
-- the text and whether anything was cut.
local function capBytes(s, cap)
  if text.byteLen(s) <= cap then
    return s, false
  end
  local cut = cap
  -- Step back while the next byte continues a sequence that the cut splits
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut), true
end

-- Agent state
agent.state = {
  messages = {},
  workingDirectory = nil,
  context = {},
  warnings = {},
  failedPrompts = {},
}

-- A screen at least this big gets longer answers
local LARGE_SCREEN_WIDTH, LARGE_SCREEN_HEIGHT = 80, 30

-- How text works on this computer: with the "CC: Tweaked Unicode Support"
-- mod, UTF-8 displays, and # / string.len count characters while sub, byte
-- and find stay byte-based; without it, the screen has CC's own 256
-- characters (ASCII and Latin-1)
local function textRules()
  if text.unicodeTerminal() then
    return [[
- This computer has the "CC: Tweaked Unicode Support" mod: UTF-8 text displays correctly, one character per screen cell
- Lua strings are still bytes: string.sub, string.byte and string.find use byte positions, but # and string.len count characters (on valid UTF-8). Never mix them on non-ASCII text: for a byte length use select(2, s:find("$")); for characters use unicode.len(s) and unicode.sub(s, i, j)
- Open files with "rb"/"wb" when their bytes must stay exact (text-mode handles may convert characters)]]
  end
  return [[
- The screen shows only CC's own character set: ASCII and Latin-1. Other characters (dashes, arrows, emoji, non-Latin scripts) show as "?" here and as garbage in programs
- Use plain ASCII in replies, code and comments. In Lua strings, write Latin-1 characters as escapes: "\176" is the degree sign, "\233" is e-acute]]
end

-- A skill's systemPrompt: a string, or what its function returns. A
-- function that fails leaves the skill's instructions out, with a warning
-- (once per skill and session); Ctrl+T in it cancels the request.
local function skillPrompt(skill)
  local prompt = skill.systemPrompt
  if type(prompt) ~= "function" then
    return prompt
  end
  local ok, value = pcall(prompt, agent)
  if ok then
    return value
  end
  if value == "Terminated" then
    error(value, 0)
  end
  local failed = agent.state.failedPrompts
  if not failed[skill.name] then
    failed[skill.name] = true
    -- (UTF-8, like all text for the UI)
    table.insert(agent.state.warnings, text.fromCC("The " .. skill.name .. " skill's systemPrompt failed, " ..
      "so its instructions are left out: " .. tostring(value)))
  end
  return nil
end

-- Build system prompt with context. Secret values (secretList, from
-- agent.secretValues) are blanked out of the parts that come from the
-- computer: names of directories and files, the skills' prompts, the
-- custom prompt and the project instructions. cc-code's own text is left
-- as it is (a password that is an ordinary word must not blank it out).
local function buildSystemPrompt(secretList)
  secretList = secretList or {}
  -- A part from the computer, converted to UTF-8 first (as tool results
  -- are), so a secret written in the CC charset is found in its UTF-8 form
  local function hide(str)
    return agent.redact(text.fromCC(str), secretList)
  end
  local parts = {}

  local pwd = agent.state.workingDirectory or cmnPath.cwd()
  local w, h = term.getSize()
  local machine = turtle and "turtle" or (pocket and "pocket computer" or "computer")
  if term.isColour() then
    machine = "advanced " .. machine
  end
  local largeScreen = w >= LARGE_SCREEN_WIDTH and h >= LARGE_SCREEN_HEIGHT

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
- Current directory: ]] .. hide(pwd))

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
      table.insert(parts, "\n- Directory contents: " .. hide(table.concat(entries, ", ")))
    end
  end

  -- Core instructions
  table.insert(parts, [[

## Tools
You have: read_file, write_file, edit_file, list_directory, glob, grep, shell.
- read_file before edit_file; edit_file (exact string match) for existing files, write_file only for new files or full rewrites
- Find files with glob and search content with grep instead of chains of shell ls calls
- ]] .. agent.REDACTED .. [[ in a tool result stands for a secret value (an API key or a password) that is hidden from you. Never write it into a file: change the text around it with edit_file, and do not rewrite a file that contains it. Never put it into a shell command either: for example, `set name ]] .. agent.REDACTED .. [[` would store the marker in place of the secret
- shell runs CraftOS commands (ls, cp, mv, rm, mkdir, or a program path) and captures what they print; there is no cat/echo/grep, so prefer the file tools when one fits
- Verify your work: after writing a program, run it by its path via shell and check the output; fix errors before declaring done. Never run editors or prompts (edit, lua, paint, shell)
- shell stops a program that is still running after its `timeout` (seconds; default ]] .. tools.SHELL_TIMEOUT .. [[, max ]] .. tools.SHELL_MAX_TIMEOUT .. [[). Programs that loop forever (dashboards, servers, farm or redstone controllers) end that way, which is expected: test them with a short timeout. Give long turtle jobs a longer one
- A program gets no input from you: one that waits for a key, typed text or a click (menus, games, a "Press any key" prompt, read()) waits until the timeout, so give it a short one
- shell records printed output on a tall virtual terminal. For programs that draw a full screen (dashboards, games, plots, menus), call shell with `screen: true`: the program then runs on a ]] .. w .. "x" .. h .. [[ terminal like the real one, and you get its final screen with the colours (for a program that waits for input: the screen it waits on). It shows this computer's own terminal only: what a program draws on monitors (or on term.native()) is not captured]] ..
  (multishell and "\n- To leave a program running after testing it, start it with the shell command `bg <program> [args]`: it runs in its own multishell tab" or "") .. [[


## Writing Lua for this system
- Match repo style: 2-space indent, double quotes, `local` everything, modules return a table
- Wrap risky calls in pcall (JSON decode, peripheral calls, network); use error("message") for failures
]] .. textRules() .. [[

- Check a peripheral exists (peripheral.find / peripheral.isPresent) before using it
- Keep memory small: stream or process line-by-line, avoid building large strings/tables

## Interaction
]] .. (largeScreen and
  "- The screen is large: answers of up to about 20 lines are fine. Use plain text; simple '-' lists and short code snippets are fine, but no markdown tables, headers or bold"
  or "- The screen is small: answer in a few short lines, plain text, no markdown formatting") .. [[

- Do the task, then state what you did in one or two lines; if genuinely ambiguous, ask one short question instead of guessing
- The user can bypass you with !<command> to run shell commands directly
]])

  -- Add skill system prompts (a skill's systemPrompt may be a function of
  -- the agent, for context that comes and goes, such as /turtle's)
  local skillList = skills.getAll()
  table.sort(skillList, function(a, b) return a.name < b.name end)
  for _, skill in ipairs(skillList) do
    local prompt = skillPrompt(skill)
    if type(prompt) == "string" and prompt ~= "" then
      table.insert(parts, "\n## " .. hide(skill.name) .. " Skill\n" .. hide(prompt))
    end
  end

  -- Add custom system prompt if configured
  if agent.config.systemPrompt then
    table.insert(parts, "\n## Custom Instructions\n" .. hide(tostring(agent.config.systemPrompt)))
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
        local contentLen = content and text.byteLen(content) or 0
        if contentLen > 0 then
          -- Convert and blank secrets before the cut: a secret cut in two
          -- would no longer be found, and its start would be sent. (The
          -- cap counts UTF-8 bytes, what is sent.)
          local kept, truncated = capBytes(hide(content), f.cap)
          table.insert(parts, "\n## Project Instructions (" .. f.name .. ")\n" ..
            kept .. (truncated and "\n[truncated]" or ""))
          break
        end
      end
    end
  end

  -- (hide converted every part from the computer; this keeps the JSON
  -- valid UTF-8 even if a later part is added without it)
  return text.fromCC(table.concat(parts, "\n"))
end

-- The names of the built-in tools (a skill tool may not take one)
local function builtinToolNames()
  local names = {}
  for _, tool in ipairs(tools.getAll()) do
    names[#names + 1] = tool["function"].name
  end
  return names
end

-- Get all available tools: the built-in ones, then the skills' (without
-- those whose names are taken, which agent.init reports)
local function getAllTools()
  local allTools = tools.getAll()
  local skillTools = skills.getAllTools(builtinToolNames())
  for _, tool in ipairs(skillTools) do
    table.insert(allTools, tool)
  end
  return allTools
end

-- Initialize agent
function agent.init(config)
  config = config or {}
  agent.config.model = DEFAULT_MODEL
  agent.config.maxSteps = DEFAULT_MAX_STEPS
  agent.config.maxOutputTokens = nil
  for k, v in pairs(config) do
    agent.config[k] = v
  end

  -- Settings fill in what the config left out. The model may be a spec
  -- string ("custom:<id>"). One that is not a model (a gateway model is
  -- always "creator/model") falls back to the default, with a warning the
  -- UI shows at startup.
  agent.state.modelWarning = nil
  if config.model == nil and settings then
    local saved = settings.get(SETTINGS.model)
    if type(saved) == "string" and saved ~= "" then
      agent.config.model = saved
    end
  end
  local model, problem = agent.resolveModel(agent.config.model)
  if model then
    agent.config.model = model
  else
    agent.state.modelWarning = problem .. "; using " .. DEFAULT_MODEL
    agent.config.model = DEFAULT_MODEL
  end
  if config.maxSteps == nil then
    agent.config.maxSteps = numberSetting(SETTINGS.maxSteps) or DEFAULT_MAX_STEPS
  end

  agent.state.workingDirectory = cmnPath.cwd()
  agent.state.messages = {}
  agent.state.context = {}
  -- Messages for the user that agent.process hands over with its next
  -- result (result.warnings), and the skills whose systemPrompt failed
  agent.state.warnings = {}
  agent.state.failedPrompts = {}

  -- The mode the UI shows tool calls in, once the UI loop has applied one
  -- (a bare /tools reports it)
  agent.state.toolDisplay = nil

  -- Load skills: built-in (lib/cc-code/skills next to this module), then
  -- the user's (/.cc-code/skills), then the project's (.cc-code/skills in
  -- the current directory). A later skill with the same name replaces an
  -- earlier one. skillErrors gets messages ready to show: files that did
  -- not load, commands one skill took over from another, skill commands
  -- that are built-in commands, and skill tools that cannot be used. The
  -- skills an earlier init loaded go first (another directory's project
  -- skills must not stay); skills a program registered itself stay.
  agent.state.skillErrors = {}
  skills.unloadDirectories()
  local dirs = {}
  if moduleDir then
    table.insert(dirs, moduleDir .. "/skills")
  end
  table.insert(dirs, agent.USER_SKILLS_DIR)
  local localSkillsDir = cmnPath.join(agent.state.workingDirectory, ".cc-code/skills")
  if localSkillsDir ~= agent.USER_SKILLS_DIR then
    table.insert(dirs, localSkillsDir)
  end
  local function report(problems)
    for _, problem in ipairs(problems) do
      table.insert(agent.state.skillErrors, problem)
    end
  end
  -- Takeovers are reported once every folder has loaded, and only those
  -- that still hold (a later skill can replace the taker, or take the
  -- command again)
  local takeovers = {}
  for _, dir in ipairs(dirs) do
    report(skills.loadFromDirectory(dir, { takeovers = takeovers }))
  end
  report(skills.takeoverMessages(takeovers, BUILTIN_COMMANDS))
  report(skills.commandProblems(BUILTIN_COMMANDS))
  report(skills.toolProblems(builtinToolNames()))

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
    elseif provider == "custom" then
      -- The key is optional (local servers), but the endpoint is not
      requiredKey = "AI_CUSTOM_BASE_URL"
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

-- Every slash command: built-in and from skills
function agent.commandNames()
  local names, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(BUILTIN_COMMANDS) do
    add(name)
  end
  for _, skill in ipairs(skills.getAll()) do
    for _, command in ipairs(skill.commands or {}) do
      add(command)
    end
  end
  table.sort(names)
  return names
end

-- Edit distance between two short ASCII strings (for "did you mean")
local function editDistance(a, b)
  local la, lb = text.byteLen(a), text.byteLen(b)
  local prev = {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    local cur = { [0] = i }
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[lb]
end

-- Most commands offered as "did you mean" for a word that starts them
local MAX_SUGGESTIONS = 3

-- The known commands a word ("/mod") could be meant as: those it is the
-- start of ("/model"), else the closest one at most 2 edits away ("/hepl"
-- -> "/help"). The "/?" alias of /help is never offered, and a short name
-- only for a match closer than its length (two edits turn "/ls" into a
-- skill's "/go", which says nothing about what the user meant).
local function similarCommands(word)
  local lower = word:lower()
  local starts, best, bestDistance = {}, nil, nil
  if lower == "/" then
    return starts
  end
  for _, name in ipairs(agent.commandNames()) do
    if name ~= "/?" then
      if name:find(lower, 1, true) == 1 then
        if #starts < MAX_SUGGESTIONS then
          starts[#starts + 1] = name
        end
      else
        local distance = editDistance(lower, name)
        if distance <= 2 and distance < text.byteLen(name) - 1
          and (not bestDistance or distance < bestDistance) then
          best, bestDistance = name, distance
        end
      end
    end
  end
  if #starts > 0 then
    return starts
  end
  return best and { best } or {}
end

-- "/a", "/a or /b", "/a, /b or /c"
local function choiceList(names)
  if #names == 1 then
    return names[1]
  end
  return table.concat(names, ", ", 1, #names - 1) .. " or " .. names[#names]
end

-- The CraftOS program a word ("/ls") names without its "/", if any
local function programName(word)
  local name = word:sub(2)
  if name == "" or not (shell and shell.resolveProgram) then
    return nil
  end
  local ok, path = pcall(shell.resolveProgram, name)
  return ok and path and name or nil
end

-- Is the first word of an input a command typed wrong, rather than the
-- start of a question? A single word that is no command is ("/xyzzy"),
-- and "/" alone; in longer input only a word close to a command is
-- ("/modle openai/gpt-4o"), so "/farm should harvest wheat" goes to the
-- model.
local function isMistypedCommand(command, wordCount)
  if wordCount <= 1 or command == "/" then
    return true
  end
  return #similarCommands(command) > 0
end

-- The message for an unknown command, with the commands it could mean
function agent.unknownCommandText(command)
  local msg = "Unknown command " .. command
  local similar = similarCommands(command)
  if #similar > 0 then
    msg = msg .. " - did you mean " .. choiceList(similar) .. "?"
  else
    msg = msg .. "."
  end
  local program = programName(command)
  if program then
    msg = msg .. " To run the " .. program .. " program, type !" .. program .. "."
  end
  return msg .. " Type /help for the list."
end

-- Was a tool stopped with Ctrl+T? (as ai.generateText tells: the string
-- "Terminated", or a table that may carry the partial result)
local function isCancel(err)
  return err == "Terminated" or (type(err) == "table" and err.terminated == true)
end

local processInput

-- Process a user message. Optional callbacks:
--   onToolCall(name, args)
--   onToolResult(name, result, args)  after every call: a raised error is
--                                the result { error = ... }, and a call
--                                stopped with Ctrl+T gets cancelled = true
--                                (in its partial result, if it has one)
--   onStepStart(step, maxSteps)  before each model request
--   onWait(seconds)              about twice a second while waiting for the model
--   onEvent(event, ...)          other events that arrive while waiting
-- Every result can carry warnings: a list of messages for the user (such
-- as a skill's systemPrompt that failed).
function agent.process(input, callbacks)
  local result = processInput(input, callbacks or {})
  if #agent.state.warnings > 0 then
    result.warnings = agent.state.warnings
    agent.state.warnings = {}
  end
  return result
end

processInput = function(input, callbacks)
  local onToolCall = callbacks.onToolCall
  local onToolResult = callbacks.onToolResult

  -- Check for shell commands (! prefix)
  if input:sub(1, 1) == "!" then
    local command = input:sub(2):match("^%s*(.-)%s*$") -- trim whitespace
    if command == "" then
      return { type = "error", text = "No command specified" }
    end

    -- Execute shell command, capturing what it prints
    local success, output, terminated, info = capture.run(command)
    agent.state.workingDirectory = cmnPath.cwd() -- `cd` may have changed it

    if info and info.abandoned then
      output = output .. (output ~= "" and "\n" or "") ..
        "(it did not end after Ctrl+T, so it was abandoned)"
    elseif terminated then
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
      agent.state.context = {}
      return { type = "command", command = "clear" }
    elseif command == "/exit" or command == "/quit" then
      return { type = "command", command = "exit" }
    elseif command == "/tools" then
      local mode = args:lower()
      if mode == "" then
        -- The mode the UI uses (the setting can have changed since: !set)
        return { type = "direct", text = "Tool calls are shown: " .. (agent.state.toolDisplay or agent.toolDisplay()) ..
          "\nUsage: /tools short|full|off (one line each, JSON previews, hidden)" }
      end
      if not TOOL_DISPLAYS[mode] then
        return { type = "error", text = "Usage: /tools short|full|off" }
      end
      if settings then
        settings.set(SETTINGS.tools, mode)
        pcall(settings.save)
      end
      return { type = "command", command = "tools", mode = mode }
    end

    -- Check skills for command handler. A skill error ends this command,
    -- not cc-code (skills can come from the user or the project), and so
    -- does Ctrl+T while it runs (nothing is in the history yet).
    local skill = skills.findByCommand(command)
    if skill and skill.onActivate then
      local ok, prompt, directResult = pcall(skill.onActivate, agent, args)
      if not ok then
        if prompt == "Terminated" then
          return { type = "error", text = "Cancelled (Ctrl+T).", error = "cancelled" }
        end
        return { type = "error", text = "The " .. skill.name .. " skill failed: " .. tostring(prompt) }
      end
      if directResult then
        return { type = "direct", text = directResult }
      end
      if prompt then
        input = prompt
      end
    elseif not skill and command:match("^/[%w%?_%-]*$") and (command == "/" or not fs.exists(command))
      and isMistypedCommand(command, #parts) then
      -- A mistyped command would otherwise go to the model as a question.
      -- Paths such as "/startup is broken" still do, and so does a request
      -- about a new program ("/farm should harvest wheat").
      return { type = "error", text = agent.unknownCommandText(command) }
    end
  end

  -- Add user message (snapshot first: the tool loop appends tool-call/result
  -- messages to this same table, so error recovery must trim back to here)
  local messageSnapshot = #agent.state.messages
  table.insert(agent.state.messages, { role = "user", content = text.fromCC(input) })

  -- Check if API key is configured
  local hasKey, requiredKey, provider = checkApiKey(agent.config.model)
  if not hasKey then
    local model = agent.config.model
    local modelName = type(model) == "table" and ((model.provider or "?") .. ":" .. tostring(model.modelId)) or tostring(model)
    local isKey = requiredKey:match("_KEY$") ~= nil
    local errorMsg = string.format(
      "%s Please set it:\n\n" ..
      "1. Exit and run: set %s %s\n" ..
      "2. Or use /model command to switch to a different provider\n\n" ..
      "Current model: %s (requires %s provider)",
      isKey and "No API key found." or ("No " .. requiredKey .. " set."),
      requiredKey,
      isKey and "<key>" or "<url>",
      modelName,
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

  -- The history is valid for the next request after each completed step
  -- (every tool call has its result); an error trims back to that point
  local consistentLength = messageSnapshot
  -- Whether Ctrl+T stopped one of the last step's tools (that step is kept
  -- with its partial and skipped results, but it did not complete)
  local stoppedStep = false

  -- Secret setting values, blanked out of what the model is sent
  local secrets = agent.secretValues()

  -- The system prompt. Ctrl+T while a skill's systemPrompt function runs
  -- cancels the request before anything is sent.
  local promptOk, system = pcall(buildSystemPrompt, secrets)
  if not promptOk then
    while #agent.state.messages > messageSnapshot do
      table.remove(agent.state.messages)
    end
    if system == "Terminated" then
      return { type = "error", text = "Request cancelled (Ctrl+T).", error = "cancelled", keptSteps = 0 }
    end
    error(system, 0)
  end

  -- Build options
  local opts = {
    model = agent.config.model,
    messages = agent.state.messages,
    system = system,
    tools = getAllTools(),
    maxSteps = agent.config.maxSteps,
    maxOutputTokens = outputTokenCap(agent.config.model),
    temperature = agent.config.temperature,
    timeout = agent.config.timeout,
    onStepStart = callbacks.onStepStart,
    onWait = callbacks.onWait,
    onEvent = callbacks.onEvent,
    onStepFinish = function(info)
      consistentLength = #agent.state.messages
      stoppedStep = info and info.cancelled or false
    end,
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

      -- Wrap the execute function. Results are converted to UTF-8 and
      -- have secrets blanked out (the settings are read again for each
      -- call: a shell command may have just set one), and one JSON can't
      -- hold becomes an error. The UI hears about every call's end, also
      -- one that failed or was stopped.
      local name = tool["function"].name
      local origExecute = tool["function"].execute
      toolCopy["function"].execute = function(args)
        if onToolCall then
          onToolCall(name, args)
        end
        local ok, result = pcall(origExecute, args)
        if not ok then
          if isCancel(result) then
            -- Ctrl+T: a partial result (CC charset too) still goes to the
            -- model; the cancel is raised on, so ai.generateText ends the
            -- turn as before
            -- (checked before it is converted: converting a table that
            -- refers to itself would never end)
            local shown = {}
            if type(result) == "table" then
              local partial = result.result
              if type(partial) == "table" then
                -- ai.generateText sends a table partial with a cancel mark,
                -- which a list can't hold
                local marked = {}
                for k, v in pairs(partial) do
                  marked[k] = v
                end
                marked.cancelled = true
                local problem = jsonProblem(marked)
                if problem then
                  partial = { error = problem }
                end
              end
              result.result = redactDeep(toUtf8Deep(partial), agent.secretValues())
              if type(result.result) == "table" then
                for k, v in pairs(result.result) do
                  shown[k] = v
                end
              end
            end
            shown.cancelled = true
            if onToolResult then
              onToolResult(name, shown, args)
            end
            error(result, 0)
          end
          -- Any other error is the call's result, as ai.generateText would
          -- make it, but converted and blanked out like any other result
          -- (the message can hold a URL with a key, or CC charset text)
          result = { error = tostring(result) }
        end
        -- Checked before it is converted (see above); converting and
        -- blanking strings can't make a sendable value unsendable
        local problem = jsonProblem(result)
        if problem then
          result = { error = problem }
        end
        result = redactDeep(toUtf8Deep(result), agent.secretValues())
        if onToolResult then
          onToolResult(name, result, args)
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
    local cancelled = err == "Terminated"
    local errorMsg = agent.redact(tostring(err), secrets)

    -- Trim back to the last completed step. When no step completed, the
    -- user message goes too (it can be sent again); otherwise the steps stay
    -- (their file changes are on disk) and a note ends the turn, so the
    -- model knows what happened if the user says "continue".
    local keep = consistentLength > messageSnapshot and consistentLength or messageSnapshot
    while #agent.state.messages > keep do
      table.remove(agent.state.messages)
    end
    -- Completed steps kept (a step stopped by Ctrl+T is kept but not counted)
    local keptSteps = 0
    local keptStopped = keep > messageSnapshot and stoppedStep
    if keep > messageSnapshot then
      for i = messageSnapshot + 1, keep do
        local msg = agent.state.messages[i]
        if msg.role == "assistant" or msg.role == "model" then
          keptSteps = keptSteps + 1
        end
      end
      if keptStopped then
        keptSteps = keptSteps - 1
      end
      local note
      if keptStopped then
        note = "[The user cancelled this turn with Ctrl+T during the last tool step; " ..
          "its stopped and skipped calls are marked in their results" ..
          (keptSteps > 0 and "; the tool steps before it were completed" or "") .. ".]"
      elseif cancelled then
        note = "[The user cancelled this turn with Ctrl+T. The tool steps above were completed.]"
      else
        note = "[This turn stopped with an error: " .. text.fromCC(errorMsg) ..
          ". The tool steps above were completed.]"
      end
      table.insert(agent.state.messages, { role = "assistant", content = note })
    end

    if cancelled then
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

    if keptSteps > 0 then
      errorMsg = errorMsg .. "\n" .. (keptSteps == 1 and "The completed tool step was kept."
        or ("The " .. keptSteps .. " completed tool steps were kept."))
    end
    if keptStopped then
      errorMsg = errorMsg .. "\nThe stopped step was kept with its output so far."
    end

    return {
      type = "error",
      text = errorMsg,
      error = cancelled and "cancelled" or "api_call_failed",
      keptSteps = keptSteps,
      keptStoppedStep = keptStopped or nil,
    }
  end

  -- Add the reply to the history. It is never left empty (strict APIs
  -- reject empty assistant messages), and a note says why a turn ended
  -- early, so the model knows what happened if the user says "continue".
  local replyText = result.text or ""
  local notice
  if result.stepLimitReached then
    -- The last step's text is already in the history with its tool calls
    notice = "Stopped after " .. result.steps .. " tool steps (the limit). Type 'continue' to go on."
    table.insert(agent.state.messages, {
      role = "assistant",
      content = "[Stopped after " .. result.steps .. " tool steps, the limit for one prompt. " ..
        "The user can say 'continue'.]",
    })
  else
    local content = replyText
    if result.finishReason == "length" then
      notice = "The reply was cut off at the output token limit."
      content = content .. (content ~= "" and "\n" or "") .. "[cut off at the output token limit]"
    elseif result.finishReason == "incomplete" then
      notice = "The reply ended early: the server stopped sending before the end."
      content = content .. (content ~= "" and "\n" or "") .. "[the reply ended early]"
    elseif not replyText:find("%S") then
      notice = "The model sent an empty reply."
      content = "[empty reply]"
    end
    table.insert(agent.state.messages, { role = "assistant", content = content })
  end

  return {
    type = "response",
    text = replyText,
    notice = notice,
    finishReason = result.finishReason,
    stepLimitReached = result.stepLimitReached,
    steps = result.steps,
    toolResults = result.toolResults,
    usage = result.usage,
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

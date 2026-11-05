-- cc-code/skills/init.lua
-- Skills system for extensible agent capabilities

local json = require("cmn-utils.json")
local text = require("cmn-utils.text")

local skills = {}

-- Registered skills, by name
skills.registry = {}

-- When each skill was registered (a counter), so lists, command lookups and
-- tools follow the load order instead of pairs() order. Weak keys: a skill
-- replaced in the registry is forgotten here too.
local registeredAt = setmetatable({}, { __mode = "k" })
local registrations = 0

-- The file each skill that loadFromDirectory registered came from, so
-- unloadDirectories can tell them from skills a program registered itself
local loadedFrom = setmetatable({}, { __mode = "k" })

-- Base skill class
skills.Skill = {}
skills.Skill.__index = skills.Skill

function skills.Skill:new(opts)
  local self = setmetatable({}, skills.Skill)
  self.name = opts.name or error("Skill requires a name")
  self.description = opts.description or ""
  self.commands = opts.commands or {}  -- Slash commands this skill handles
  self.tools = opts.tools or {}        -- Additional tools this skill provides
  self.onActivate = opts.onActivate    -- Called when skill is activated via command
  self.systemPrompt = opts.systemPrompt -- Added to the system prompt: a string, or function(agent) -> string|nil
  return self
end

-- Register a skill. It replaces a registered skill of the same name, and it
-- comes after every skill registered before it (see getAll).
function skills.register(skill)
  if type(skill) ~= "table" or not skill.name then
    error("Cannot register skill without name")
  end
  registrations = registrations + 1
  registeredAt[skill] = registrations
  skills.registry[skill.name] = skill
  return skill
end

-- Forget every registered skill
function skills.reset()
  for name in pairs(skills.registry) do
    skills.registry[name] = nil
  end
end

-- Forget the skills loadFromDirectory registered (before loading them
-- again, so a skill from an earlier load, such as another project's, does
-- not stay). Skills a program registered itself stay.
function skills.unloadDirectories()
  for name, skill in pairs(skills.registry) do
    if loadedFrom[skill] then
      skills.registry[name] = nil
    end
  end
end

-- Get a skill by name
function skills.get(name)
  return skills.registry[name]
end

-- All registered skills, in the order they were registered. (A skill put
-- into skills.registry directly counts as registered first; ties go by
-- name, so the order never depends on pairs().)
function skills.getAll()
  local list = {}
  for _, skill in pairs(skills.registry) do
    list[#list + 1] = skill
  end
  table.sort(list, function(a, b)
    local orderA, orderB = registeredAt[a] or 0, registeredAt[b] or 0
    if orderA ~= orderB then
      return orderA < orderB
    end
    return tostring(a.name) < tostring(b.name)
  end)
  return list
end

local function claims(skill, command)
  if type(skill.commands) ~= "table" then
    return false
  end
  for _, cmd in ipairs(skill.commands) do
    if cmd == command then
      return true
    end
  end
  return false
end

-- The skill that handles a command: when several claim it, the one
-- registered last (a user or project skill, loaded after the built-ins)
function skills.findByCommand(command)
  local list = skills.getAll()
  for i = #list, 1, -1 do
    if claims(list[i], command) then
      return list[i]
    end
  end
  return nil
end

-- The skill registered last that claims a command, apart from the skill
-- named `except` (nil if there is none)
local function holderOf(command, except)
  local list = skills.getAll()
  for i = #list, 1, -1 do
    if list[i].name ~= except and claims(list[i], command) then
      return list[i]
    end
  end
  return nil
end

-- Names as a set: from a set { [name] = true } or a list of names
local function nameSet(names)
  local set = {}
  if type(names) == "table" then
    for key, value in pairs(names) do
      if type(value) == "string" then
        set[value] = true
      elseif value then
        set[key] = true
      end
    end
  end
  return set
end

-- The skills' tools in registration order, and a message for each tool
-- that is left out: its name is in `reserved` (the built-in tools' names,
-- as a set or a list) or an earlier tool already has it. Two tools with one name would
-- make the model's call ambiguous, and APIs reject duplicate names.
local function collectTools(reserved)
  local builtIn = nameSet(reserved)
  local offered, problems = {}, {}
  local owner = {}  -- tool name -> name of the skill whose tool has it
  for _, skill in ipairs(skills.getAll()) do
    for _, tool in ipairs(type(skill.tools) == "table" and skill.tools or {}) do
      local fn = type(tool) == "table" and tool["function"]
      local name = type(fn) == "table" and fn.name
      if type(name) == "string" then
        local usedBy
        if builtIn[name] then
          usedBy = "a built-in tool"
        elseif owner[name] == skill.name then
          usedBy = "another tool of this skill"
        elseif owner[name] then
          usedBy = "skill " .. owner[name]
        end
        if usedBy then
          table.insert(problems, "Skill " .. tostring(skill.name) .. ": tool " .. name ..
            " is not offered: the name is already used by " .. usedBy)
        else
          owner[name] = skill.name
          table.insert(offered, tool)
        end
      end
    end
  end
  return offered, problems
end

-- The tools of all skills that can be offered to the model (see collectTools)
function skills.getAllTools(reserved)
  local offered = collectTools(reserved)
  return offered
end

-- Why tools of skills are not offered (see collectTools): a list of
-- messages ready to show
function skills.toolProblems(reserved)
  local _, problems = collectTools(reserved)
  return problems
end

-- An error message without the "file:line: " position error() adds
local function bareError(err)
  return (tostring(err):gsub("^[^:]*:%d+: ", ""))
end

-- What is wrong with a tool's parameters, or nil. They are sent with every
-- request, so a value that is not a JSON schema object would make every
-- request fail. (An empty `properties` is fine: it is left out when sent.)
local function checkParameters(params)
  if params == nil then
    return nil
  end
  if type(params) ~= "table" then
    return "parameters must be a table such as { type = \"object\", properties = { ... } }"
  end
  local ok, encoded = pcall(json.encode, params)
  if not ok then
    return "parameters can't be sent as JSON (" .. bareError(encoded) .. ")"
  end
  if next(params) ~= nil and encoded:sub(1, 1) ~= "{" then
    return "parameters must be a schema such as { type = \"object\", properties = { ... } }, not a list"
  end
  local props = params.properties
  if props ~= nil then
    if type(props) ~= "table" then
      return "parameters.properties must be a table such as { count = { type = \"number\" } }"
    end
    if next(props) ~= nil and json.encode(props):sub(1, 1) ~= "{" then
      return "parameters.properties must map names to schemas, such as { count = { type = \"number\" } }, not be a list"
    end
  end
  return nil
end

-- What is wrong with a skill's tools value, or nil
local function checkTools(tools)
  if tools == nil then
    return nil
  end
  if type(tools) ~= "table" then
    return "tools must be a list of ai.tool({ ... }) tables"
  end
  -- One tool not wrapped in a list has no list entries, so the skill
  -- would load with no tools and no message
  if tools["function"] ~= nil or tools.type ~= nil then
    return "tools must be a list, also for one tool: write tools = { ai.tool({ ... }) }"
  end
  local listed = 0
  for _ in ipairs(tools) do
    listed = listed + 1
  end
  local count = 0
  for _ in pairs(tools) do
    count = count + 1
  end
  if count ~= listed then
    return "tools must be a list without gaps or names: write tools = { ai.tool({ ... }), ai.tool({ ... }) }"
  end
  for i, tool in ipairs(tools) do
    local fn = type(tool) == "table" and tool["function"]
    if type(fn) ~= "table" or type(fn.name) ~= "string" or type(fn.execute) ~= "function" then
      return "tool " .. i .. " is not an ai.tool({ name, description, parameters, execute }) table"
    end
    local label = "tool " .. i .. " (" .. fn.name .. ")"
    -- Providers send only tools of type "function": any other tool would
    -- never reach the model
    if tool.type ~= "function" then
      return label .. " needs type = \"function\": make it with ai.tool({ ... })"
    end
    -- What OpenAI accepts as a name; others fail the whole request
    if not fn.name:match("^[%w_%-]+$") or text.byteLen(fn.name) > 64 then
      return label .. ": the name must be 1-64 letters, digits, _ or -"
    end
    if fn.description ~= nil and type(fn.description) ~= "string" then
      return label .. ": description must be a string"
    end
    local problem = checkParameters(fn.parameters)
    if problem then
      return label .. ": " .. problem
    end
  end
  return nil
end

-- What is wrong with a value a skill file returned, or nil if it is a
-- usable skill. A tool that is not an ai.tool() table would otherwise
-- crash cc-code when the next request is built.
local function checkSkill(skill)
  if type(skill) ~= "table" or type(skill.name) ~= "string" or skill.name == "" then
    return "the file did not return a skill (return skills.create({ name = ..., ... }))"
  end
  if skill.commands ~= nil and type(skill.commands) ~= "table" then
    return "commands must be a list of strings such as \"/mine\""
  end
  for _, command in ipairs(skill.commands or {}) do
    if type(command) ~= "string" or command:sub(1, 1) ~= "/" then
      return "commands must be strings that start with \"/\""
    end
  end
  if skill.onActivate ~= nil and type(skill.onActivate) ~= "function" then
    return "onActivate must be a function"
  end
  local promptType = type(skill.systemPrompt)
  if skill.systemPrompt ~= nil and promptType ~= "string" and promptType ~= "function" then
    return "systemPrompt must be a string, or a function(agent) that returns one"
  end
  return checkTools(skill.tools)
end

-- "<path>: <problem>". loadfile and error messages often start with the
-- path already ("/dir/x.lua:3: ..."), which Lua shortens to "...<end of
-- the path>" when it is long: such a message gets the full path, once.
-- (CC paths can't contain ":".)
local function withPath(path, problem)
  local head, rest = problem:match("^([^:]*):(.*)$")
  if head then
    local tail = head:sub(1, 3) == "..." and head:sub(4)
    if head == path or "/" .. head == path
      or (tail and tail ~= "" and path:sub(-text.byteLen(tail)) == tail) then
      return path .. ":" .. rest
    end
  end
  return path .. ": " .. problem
end

local function takeoverText(skill, path, command, holder)
  return "Skill " .. skill.name .. " (" .. path .. ") takes " .. command ..
    " over from skill " .. tostring(holder.name)
end

-- Load the skills in a directory (every .lua file except init.lua), in
-- file name order. Returns messages ready to show: "Skill not loaded:
-- <path>: <problem>" for files that did not load, and a note for each
-- command a new skill takes over from a registered skill with another
-- name. With opts.takeovers (a list), takeovers are added to that list
-- instead, for takeoverMessages once every directory has loaded (a later
-- skill can replace the taker, or take the command again).
-- (unloadDirectories removes the skills loaded this way.)
function skills.loadFromDirectory(dir, opts)
  local takeovers = type(opts) == "table" and type(opts.takeovers) == "table" and opts.takeovers or nil
  local messages = {}
  if not fs.exists(dir) or not fs.isDir(dir) then
    return messages
  end
  local files = fs.list(dir)
  table.sort(files)
  for _, file in ipairs(files) do
    local path = "/" .. fs.combine(dir, file)
    if file:match("%.lua$") and file ~= "init.lua" and not fs.isDir(path) then
      -- Load with this module's environment: CraftOS's dofile uses _G,
      -- which has no `require` (it is per-program)
      local fn, loadErr = loadfile(path, "t", _ENV)
      local problem
      if not fn then
        problem = tostring(loadErr)
      else
        local ok, skill = pcall(fn)
        if not ok then
          if skill == "Terminated" then error(skill, 0) end
          problem = tostring(skill)
        else
          problem = checkSkill(skill)
          if not problem then
            -- Commands another skill (not one this replaces) had until now
            local seen = {}
            for _, command in ipairs(skill.commands or {}) do
              local holder = not seen[command] and holderOf(command, skill.name)
              seen[command] = true
              if holder and takeovers then
                table.insert(takeovers, { skill = skill, path = path, command = command })
              elseif holder then
                table.insert(messages, takeoverText(skill, path, command, holder))
              end
            end
            skills.register(skill)
            loadedFrom[skill] = path
          end
        end
      end
      if problem then
        table.insert(messages, "Skill not loaded: " .. withPath(path, problem))
      end
    end
  end
  return messages
end

-- Messages for the takeovers loadFromDirectory added to opts.takeovers
-- that hold now: the taker still gets the command, and another skill
-- claims it too. Commands in `reserved` (the built-in commands, as a set
-- or a list) are left out: no skill gets them (see commandProblems).
function skills.takeoverMessages(takeovers, reserved)
  local builtIn = nameSet(reserved)
  local messages = {}
  for _, t in ipairs(type(takeovers) == "table" and takeovers or {}) do
    local holder = holderOf(t.command, t.skill.name)
    if holder and not builtIn[t.command] and rawequal(skills.findByCommand(t.command), t.skill) then
      table.insert(messages, takeoverText(t.skill, t.path, t.command, holder))
    end
  end
  return messages
end

-- A message for each skill command in `reserved` (the built-in commands,
-- as a set or a list): those are handled before any skill is asked
function skills.commandProblems(reserved)
  local builtIn = nameSet(reserved)
  local problems = {}
  for _, skill in ipairs(skills.getAll()) do
    local seen = {}
    for _, command in ipairs(type(skill.commands) == "table" and skill.commands or {}) do
      if builtIn[command] and not seen[command] then
        seen[command] = true
        local path = loadedFrom[skill]
        table.insert(problems, "Skill " .. tostring(skill.name) .. (path and (" (" .. path .. ")") or "") ..
          ": " .. command .. " is a built-in command, so the skill never gets it")
      end
    end
  end
  return problems
end

-- Create a new skill (helper function)
function skills.create(opts)
  return skills.Skill:new(opts)
end

return skills

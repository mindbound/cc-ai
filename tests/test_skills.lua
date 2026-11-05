-- tests/test_skills.lua
-- The skills loader as agent.init uses it: command takeovers reported once
-- every folder has loaded, and skill commands that are built-in commands.
-- (tests/test_install.lua has the loader's other tests.)

return function(T)
  -- Each test loads its own copy of the module, so the agent's registry is
  -- not touched
  local function freshSkills()
    return assert(loadfile(T.root .. "/lib/cc-code/skills/init.lua", "t", _ENV))()
  end

  -- A skill file: name and commands (a Lua list literal)
  local function skillFile(path, name, commands)
    T.writeFile(path, table.concat({
      "local skills = require('cc-code.skills')",
      "return skills.create({ name = '" .. name .. "', commands = " .. commands .. ",",
      "  onActivate = function() return nil, '" .. name .. "' end })",
    }, "\n"))
  end

  -- Load the folders as agent.init does; the messages, one per line
  local function loadAll(skills, dirs, reserved)
    local takeovers, messages = {}, {}
    for _, dir in ipairs(dirs) do
      for _, message in ipairs(skills.loadFromDirectory(dir, { takeovers = takeovers })) do
        messages[#messages + 1] = message
      end
    end
    for _, message in ipairs(skills.takeoverMessages(takeovers, reserved)) do
      messages[#messages + 1] = message
    end
    return table.concat(messages, "\n")
  end

  local builtIn, user, project

  local function folders()
    T.resetTmp()
    builtIn, user, project = T.tmp .. "/builtin", T.tmp .. "/user", T.tmp .. "/project"
    skillFile(builtIn .. "/model.lua", "model", "{ '/model' }")
  end

  T.test("skills: a takeover undone by a later skill of the same name is not reported", function()
    folders()
    skillFile(user .. "/zzz.lua", "zzz", "{ '/model' }")
    skillFile(project .. "/zzz.lua", "zzz", "{ '/zzz' }")
    local skills = freshSkills()
    T.eq(loadAll(skills, { builtIn, user, project }), "")
    T.eq(skills.findByCommand("/model").name, "model")
    -- Without opts.takeovers, the message comes as the folder loads
    skills = freshSkills()
    skills.loadFromDirectory(builtIn)
    T.eq(table.concat(skills.loadFromDirectory(user), "\n"),
      "Skill zzz (" .. user .. "/zzz.lua) takes /model over from skill model")
  end)

  T.test("skills: only the takeover that holds at the end is reported", function()
    folders()
    skillFile(user .. "/aaa.lua", "aaa", "{ '/model' }")
    skillFile(user .. "/zzz.lua", "zzz", "{ '/model', '/model' }")
    local skills = freshSkills()
    T.eq(loadAll(skills, { builtIn, user }), "Skill zzz (" .. user .. "/zzz.lua) takes /model over from skill aaa")
    -- The project's zzz replaces the user's and claims /model too: it takes
    -- the command over from aaa (the skill it replaces doesn't count)
    skillFile(project .. "/zzz.lua", "zzz", "{ '/zzz', '/model' }")
    skills = freshSkills()
    T.eq(loadAll(skills, { builtIn, user, project }),
      "Skill zzz (" .. project .. "/zzz.lua) takes /model over from skill aaa")
    T.eq(skills.findByCommand("/model"), skills.get("zzz"))
  end)

  T.test("skills: a takeover from a skill that no longer claims the command is not reported", function()
    folders()
    skillFile(user .. "/aaa.lua", "aaa", "{ '/model' }")
    -- Replaces the built-in model skill, without /model
    skillFile(project .. "/model.lua", "model", "{ '/models' }")
    local skills = freshSkills()
    T.eq(loadAll(skills, { builtIn, user, project }), "")
    T.eq(skills.findByCommand("/model").name, "aaa")
  end)

  T.test("skills: skill commands that are built-in commands are reported", function()
    T.resetTmp()
    local dir = T.tmp .. "/user"
    skillFile(dir .. "/mytools.lua", "mytools", "{ '/tools', '/mine', '/tools', '/clear' }")
    skillFile(dir .. "/other.lua", "other", "{ '/tools' }")
    local skills = freshSkills()
    skills.register(skills.create({ name = "own", commands = { "/exit" } }))
    local reserved = { "/clear", "/exit", "/quit", "/tools" }
    -- No skill gets /tools, so none takes it over from another
    T.eq(loadAll(skills, { dir }, reserved), "")
    local function problem(name, path, command)
      return "Skill " .. name .. (path and (" (" .. path .. ")") or "") .. ": " .. command ..
        " is a built-in command, so the skill never gets it"
    end
    T.eq(table.concat(skills.commandProblems(reserved), "\n"), table.concat({
      problem("own", nil, "/exit"),
      problem("mytools", dir .. "/mytools.lua", "/tools"),
      problem("mytools", dir .. "/mytools.lua", "/clear"),
      problem("other", dir .. "/other.lua", "/tools"),
    }, "\n"))
    -- A set of names works too
    T.eq(#skills.commandProblems({ ["/tools"] = true }), 2)
    T.eq(#skills.commandProblems(), 0)
  end)
end

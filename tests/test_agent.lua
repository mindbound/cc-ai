-- tests/test_agent.lua
-- cc-code agent: skills, commands, shell bypass and a full tool-using turn

return function(T)
  local agent = require("cc-code.agent")
  local skills = require("cc-code.skills")
  local occode = require("cc-code")
  local mock = T.http

  settings.set("AI_GATEWAY_API_KEY", "gw-test")

  local function chat(content, toolCalls)
    return { choices = { { message = { role = "assistant", content = content, tool_calls = toolCalls }, finish_reason = toolCalls and "tool_calls" or "stop" } } }
  end

  agent.init({ model = "anthropic/claude-sonnet-4" })

  T.test("built-in skills are loaded from lib/cc-code/skills", function()
    T.ok(skills.get("help"), "help skill")
    T.ok(skills.get("model"), "model skill")
    T.ok(skills.get("turtle"), "turtle skill")
    T.eq(skills.findByCommand("/turtle").name, "turtle")
  end)

  T.test("/help is answered locally", function()
    local r = agent.process("/help")
    T.eq(r.type, "direct")
    T.contains(r.text, "cc-code - AI Coding Agent for ComputerCraft")
  end)

  T.test("/model switches between gateway and direct providers", function()
    local r = agent.process("/model google gemini-2.5-flash")
    T.contains(r.text, "Switched to google")
    T.eq(agent.config.model.provider, "google")
    r = agent.process("/model openai/gpt-4o-mini")
    T.eq(agent.config.model, "openai/gpt-4o-mini")
    r = agent.process("/model")
    T.contains(r.text, "Current model: openai/gpt-4o-mini")
  end)

  T.test("/model custom uses the AI_CUSTOM_BASE_URL endpoint", function()
    settings.unset("AI_CUSTOM_BASE_URL")
    local r = agent.process("/model custom deepseek/deepseek-v4.1-flash:thinking")
    T.contains(r.text, "Switched to custom provider")
    T.eq(agent.config.model.provider, "custom")
    T.eq(agent.config.model.modelId, "deepseek/deepseek-v4.1-flash:thinking")
    r = agent.process("hello")
    T.eq(r.type, "error")
    T.contains(r.text, "set AI_CUSTOM_BASE_URL <url>")
    T.contains(r.text, "custom:deepseek/deepseek-v4.1-flash:thinking")
    r = agent.process("/model")
    T.contains(r.text, "endpoint: not set")
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    r = agent.process("/model")
    T.contains(r.text, "endpoint: https://nano-gpt.com/api/v1")
    mock.reset()
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "custom ok" }, finish_reason = "stop" } } } }, true) })
    r = agent.process("hello")
    T.eq(r.text, "custom ok")
    T.eq(mock.last().json.stream, true, "custom provider streams")
    T.eq(mock.last().url, "https://nano-gpt.com/api/v1/chat/completions")
    settings.unset("AI_CUSTOM_BASE_URL")
    agent.process("/model anthropic/claude-sonnet-4")
    agent.clearHistory()
  end)

  -- The system prompt and the last message of the latest request
  local function lastRequest()
    local msgs = mock.last().json.messages
    return msgs[1].content, msgs[#msgs].content
  end

  T.test("/turtle adds the quick reference to the system prompt until /clear", function()
    agent.process("/clear")
    local r = agent.process("/turtle")
    T.eq(r.type, "direct")
    T.contains(r.text, "quick reference is now in the context")
    T.contains(agent.process("/turtle").text, "already in the context")
    mock.reset()
    mock.push({ body = chat("ok") })
    agent.process("how do I refuel?")
    local system, last = lastRequest()
    T.contains(system, "turtle.getFuelLevel")
    T.ok(not system:find("# Turtle API", 1, true), "not the full docs")
    T.eq(last, "how do I refuel?")
    -- /turtle <question> sends the question as typed
    mock.push({ body = chat("ok") })
    agent.process("/turtle dig a tunnel")
    system, last = lastRequest()
    T.eq(last, "dig a tunnel")
    T.contains(system, "turtle.getFuelLevel")
    agent.process("/clear")
    mock.push({ body = chat("ok") })
    agent.process("hello")
    T.ok(not lastRequest():find("turtle.getFuelLevel", 1, true), "/clear removes it")
  end)

  T.test("/turtle full puts docs/turtle.md into the system prompt", function()
    agent.process("/clear")
    local r = agent.process("/turtle full")
    T.contains(r.text, "full turtle API reference is now in the context")
    -- A later /turtle keeps the full docs
    T.contains(agent.process("/turtle").text, "full turtle API reference is already")
    mock.reset()
    mock.push({ body = chat("ok") })
    agent.process("/turtle full how do I refuel")
    local system, last = lastRequest()
    T.contains(system, "# Turtle API")
    T.eq(last, "how do I refuel")
    agent.process("/clear")
  end)

  T.test("unknown commands are not sent to the model", function()
    mock.reset()
    agent.clearHistory()
    local r = agent.process("/hepl")
    T.eq(r.type, "error")
    T.eq(r.text, "Unknown command /hepl - did you mean /help? Type /help for the list.")
    T.contains(agent.process("/mod").text, "did you mean /model?")
    r = agent.process("/")
    T.eq(r.type, "error")
    T.eq(r.text, "Unknown command /. Type /help for the list.")
    T.eq(agent.process("/ hello").type, "error", "a / with a space is no request")
    r = agent.process("/xyzzy")
    T.eq(r.text, "Unknown command /xyzzy. Type /help for the list.")
    -- What a word starts comes first (all of it, up to 3), never the /? alias
    T.eq(agent.process("/h").text, "Unknown command /h - did you mean /help? Type /help for the list.")
    T.eq(agent.process("/t").text,
      "Unknown command /t - did you mean /tools or /turtle? Type /help for the list.")
    -- A CraftOS program: run it with !, not a near command such as /?
    T.eq(agent.process("/ls").text,
      "Unknown command /ls. To run the ls program, type !ls. Type /help for the list.")
    -- A mistyped command is caught in longer input too
    r = agent.process("/modle openai/gpt-4o")
    T.eq(r.type, "error")
    T.contains(r.text, "did you mean /model?")
    T.eq(agent.process("/turtel full how do I dig").type, "error")
    T.eq(#mock.requests, 0)
    T.eq(#agent.getHistory(), 0)
    -- A request that starts with a word no command is like goes to the
    -- model (a program that does not exist yet, say)
    mock.push({ body = chat("Writing it.") })
    r = agent.process("/newprog should do X")
    T.eq(r.type, "response")
    local msgs = mock.last().json.messages
    T.eq(msgs[#msgs].content, "/newprog should do X")
    mock.push({ body = chat("ok") })
    T.eq(agent.process("/xyzzy now").type, "response")
    -- A path is a question, not a command
    mock.push({ body = chat("It is the read-only system folder.") })
    r = agent.process("/rom what is this")
    T.eq(r.type, "response")
    mock.push({ body = chat("ok") })
    r = agent.process("/rom/programs/edit.lua crashes")
    T.eq(r.type, "response")
    agent.clearHistory()
  end)

  T.test("/tools sets how tool calls are shown and saves it", function()
    settings.unset("cc-code.tools")
    T.eq(agent.toolDisplay(), "short")
    T.contains(agent.process("/tools").text, "Tool calls are shown: short")
    local r = agent.process("/tools FULL")
    T.eq(r.type, "command")
    T.eq(r.command, "tools")
    T.eq(r.mode, "full")
    T.eq(settings.get("cc-code.tools"), "full")
    T.eq(agent.toolDisplay(), "full")
    T.eq(agent.process("/tools loud").type, "error")
    settings.unset("cc-code.tools")
  end)

  T.test("a bare /tools reports the mode the UI uses, also after the setting changed", function()
    -- The UI loop applied full; then `!set cc-code.tools off`
    agent.state.toolDisplay = "full"
    settings.set("cc-code.tools", "off")
    T.contains(agent.process("/tools").text, "Tool calls are shown: full\n")
    -- Without a UI, the setting
    agent.init({ model = "anthropic/claude-sonnet-4" })
    T.eq(agent.state.toolDisplay, nil, "init forgets the last UI's mode")
    T.contains(agent.process("/tools").text, "Tool calls are shown: off\n")
    settings.unset("cc-code.tools")
  end)

  T.test("!command runs in the shell and returns its output", function()
    local r = agent.process("!id")
    T.eq(r.type, "direct")
    T.contains(r.text, "computer")
  end)

  T.test("/clear and /exit are commands", function()
    T.eq(agent.process("/clear").command, "clear")
    T.eq(agent.process("/exit").command, "exit")
  end)

  T.test("missing API key returns setup instructions", function()
    settings.unset("AI_GATEWAY_API_KEY")
    local r = agent.process("hello")
    T.eq(r.type, "error")
    T.contains(r.text, "set AI_GATEWAY_API_KEY <key>")
    T.eq(#agent.getHistory(), 0)
    settings.set("AI_GATEWAY_API_KEY", "gw-test")
  end)

  T.test("a full turn: model lists a directory via a tool, then answers", function()
    mock.reset()
    agent.clearHistory()
    T.resetTmp()
    T.writeFile(T.tmp .. "/one.lua", "x")
    mock.push({ body = chat(nil, { { id = "c1", type = "function", ["function"] = { name = "list_directory", arguments = "{\"path\":\"" .. T.tmp .. "\"}" } } }) })
    mock.push({ body = chat("There is one file: one.lua") })
    local calls, results = {}, {}
    local r = agent.process("what files are here? caf\233", {
      onToolCall = function(name, args) table.insert(calls, name .. ":" .. args.path) end,
      onToolResult = function(name, res) table.insert(results, res) end,
    })
    T.eq(r.type, "response")
    T.eq(r.text, "There is one file: one.lua")
    T.eq(calls[1], "list_directory:" .. T.tmp)
    T.eq(results[1].entries[1].name, "one.lua")
    -- History keeps the tool exchange: user, assistant tool call, tool result, answer
    local history = agent.getHistory()
    T.eq(#history, 4)
    T.eq(history[1].content, "what files are here? caf\195\169", "user input converted to UTF-8")
    T.eq(history[3].role, "tool")
    T.eq(history[4].content, "There is one file: one.lua")
    local sys = mock.requests[1].json.messages[1].content
    T.contains(sys, "ComputerCraft: Tweaked")
    T.contains(sys, "Current directory: /")
    T.eq(#mock.requests[1].json.tools, 7)
    T.eq(mock.requests[1].timeout, 0, "interactive turns have no idle timeout")
  end)

  T.test("tool results are sent as UTF-8 even for CC charset files", function()
    mock.reset()
    agent.clearHistory()
    T.writeFile(T.tmp .. "/latin.txt", "caf\233")
    mock.push({ body = chat(nil, { { id = "r1", type = "function", ["function"] = { name = "read_file", arguments = "{\"path\":\"" .. T.tmp .. "/latin.txt\"}" } } }) })
    mock.push({ body = chat("ok") })
    agent.process("read it")
    local body = mock.requests[2].body
    T.ok(utf8.len(body), "request body is valid UTF-8")
    T.contains(body, "caf\195\169")
  end)

  T.test("API failures roll back the turn and report the error", function()
    mock.reset()
    agent.clearHistory()
    mock.push({ code = 429, body = { error = { message = "Rate limited" } } })
    local r = agent.process("hi")
    T.eq(r.type, "error")
    T.contains(r.text, "Rate limited")
    T.eq(#agent.getHistory(), 0)
  end)

  local function listCall(id)
    return { { id = id, type = "function", ["function"] = { name = "list_directory", arguments = "{\"path\":\"/\"}" } } }
  end

  T.test("an error after a completed tool step keeps that step", function()
    mock.reset()
    agent.clearHistory()
    mock.push({ body = chat("Looking.", listCall("k1")) })
    mock.push({ code = 502, reason = "Bad Gateway", body = { error = { message = "Upstream down" } } })
    local r = agent.process("list it")
    T.eq(r.type, "error")
    T.contains(r.text, "Upstream down")
    T.contains(r.text, "completed tool step was kept")
    T.eq(r.keptSteps, 1)
    local history = agent.getHistory()
    T.eq(#history, 4, "user, tool call, tool result, note")
    T.eq(history[3].role, "tool")
    T.eq(history[4].role, "assistant")
    T.contains(history[4].content, "stopped with an error")
    -- The next request carries the kept steps
    mock.push({ body = chat("Continuing.") })
    agent.process("continue")
    T.eq(#mock.last().json.messages, 6, "system, the 4 kept messages, the new prompt")
  end)

  T.test("Ctrl+T while waiting for the model keeps finished steps", function()
    mock.reset()
    agent.clearHistory()
    mock.push({ body = chat(nil, listCall("k2")) })
    mock.push({ hold = true, body = chat("too late") })
    local r = agent.process("list it", {
      onStepStart = function(step) if step == 2 then os.queueEvent("terminate") end end,
    })
    T.eq(r.type, "error")
    T.eq(r.error, "cancelled")
    T.contains(r.text, "Request cancelled (Ctrl+T).")
    local history = agent.getHistory()
    T.eq(#history, 4)
    T.contains(history[4].content, "cancelled this turn")
    -- Nothing done yet: the turn is rolled back entirely, as before
    agent.clearHistory()
    mock.push({ hold = true, body = chat("too late") })
    os.queueEvent("terminate")
    r = agent.process("hi")
    T.eq(r.error, "cancelled")
    T.eq(#agent.getHistory(), 0)
  end)

  T.test("Ctrl+T in the shell tool keeps its output as UTF-8 and skips the rest", function()
    mock.reset()
    agent.clearHistory()
    local tools = require("cc-code.tools")
    local shellFn = tools.shell["function"]
    local orig = shellFn.execute
    shellFn.execute = function()
      error({ terminated = true, result = { command = "x", output = "caf\233 out" } }, 0)
    end
    local calls = {
      { id = "c1", type = "function", ["function"] = { name = "shell", arguments = "{\"command\":\"x\"}" } },
      { id = "c2", type = "function", ["function"] = { name = "list_directory", arguments = "{\"path\":\"/\"}" } },
    }
    mock.push({ body = chat("Running.", calls) })
    local shown = {}
    local ok, r = pcall(agent.process, "run it", {
      onToolResult = function(name, res, args) shown[#shown + 1] = { name = name, res = res, args = args } end,
    })
    shellFn.execute = orig
    T.ok(ok, "process raised: " .. tostring(r))
    -- The UI ends the stopped call's line, with the output so far
    T.eq(#shown, 1, "only the stopped call ran")
    T.eq(shown[1].res.cancelled, true)
    T.eq(shown[1].args.command, "x")
    T.eq(require("cc-code.toolview").line("shell", shown[1].args, shown[1].res),
      "$ x - stopped (Ctrl+T): caf\195\169 out")
    T.eq(r.error, "cancelled")
    T.eq(r.keptSteps, 0, "the stopped step is not counted as completed")
    T.eq(r.keptStoppedStep, true)
    T.contains(r.text, "stopped step was kept")
    local history = agent.getHistory()
    local roles = {}
    for i, m in ipairs(history) do roles[i] = m.role end
    T.eq(table.concat(roles, ","), "user,assistant,tool,tool,assistant")
    T.contains(history[3].content, "caf\195\169")
    T.contains(history[3].content, "Stopped by the user")
    T.contains(history[4].content, "Skipped")
    T.contains(history[5].content, "during the last tool step")
    T.ok(not history[5].content:find("were completed", 1, true), "no completed steps claimed")
    mock.push({ body = chat("ok") })
    agent.process("continue")
    local ids = {}
    for _, m in ipairs(mock.last().json.messages) do
      if m.tool_call_id then ids[m.tool_call_id] = true end
    end
    T.ok(ids.c1 and ids.c2, "every tool call has a result")
    T.ok(utf8.len(mock.last().body), "the next request is valid UTF-8")
  end)

  T.test("Google histories: kept steps and notes stay valid contents", function()
    settings.set("GOOGLE_GENERATIVE_AI_API_KEY", "g-test")
    agent.init({ model = "google:gemini-2.5-flash" })
    local function reply(parts)
      return { candidates = { { content = { role = "model", parts = parts }, finishReason = "STOP" } } }
    end
    local call = { functionCall = { name = "list_directory", args = { path = "/" } } }
    local function contentRoles()
      local roles = {}
      for _, c in ipairs(mock.last().json.contents) do
        T.ok(type(c.parts) == "table" and #c.parts > 0 and next(c.parts[1]) ~= nil, "every turn has a non-empty part")
        table.insert(roles, c.role)
      end
      return table.concat(roles, ",")
    end
    -- An error after a completed step
    mock.reset()
    agent.clearHistory()
    mock.push({ body = reply({ { text = "Looking." }, call }) })
    mock.push({ code = 500, reason = "Internal Server Error", body = { error = { message = "Backend error" } } })
    local r = agent.process("list it")
    T.eq(r.keptSteps, 1)
    T.contains(r.text, "completed tool step was kept")
    mock.push({ body = reply({ { text = "Continuing." } }) })
    agent.process("continue")
    T.eq(contentRoles(), "user,model,user,model,user")
    -- The step limit
    mock.reset()
    agent.clearHistory()
    agent.config.maxSteps = 1
    mock.push({ body = reply({ { text = "Step one." }, call }) })
    r = agent.process("work")
    T.eq(r.stepLimitReached, true)
    mock.push({ body = reply({ { text = "ok" } }) })
    agent.process("continue")
    T.eq(contentRoles(), "user,model,user,model,user")
    settings.unset("GOOGLE_GENERATIVE_AI_API_KEY")
    agent.init({ model = "anthropic/claude-sonnet-4" })
  end)

  T.test("a turn that stops at the step limit says so, without duplicates", function()
    mock.reset()
    agent.clearHistory()
    settings.set("cc-code.max_steps", 2)
    agent.init({ model = "anthropic/claude-sonnet-4" })
    T.eq(agent.config.maxSteps, 2)
    mock.push({ body = chat("Step one.", listCall("s1")) })
    mock.push({ body = chat("Step two.", listCall("s2")) })
    local r = agent.process("work")
    T.eq(r.type, "response")
    T.eq(r.stepLimitReached, true)
    T.contains(r.notice, "Stopped after 2 tool steps")
    local history = agent.getHistory()
    T.eq(#history, 6, "user, 2 x (call, result), note")
    T.contains(history[6].content, "Stopped after 2 tool steps")
    local copies = 0
    for _, msg in ipairs(history) do
      copies = copies + select(2, tostring(msg.content):gsub("Step two", ""))
    end
    T.eq(copies, 1, "the last step's text is stored once")
    settings.unset("cc-code.max_steps")
    agent.init({ model = "anthropic/claude-sonnet-4" })
    T.eq(agent.config.maxSteps, 25, "default step limit")
  end)

  T.test("cut-off and empty replies are reported and never stored empty", function()
    mock.reset()
    agent.clearHistory()
    mock.push({ body = { choices = { { message = { role = "assistant", content = "The answer is" }, finish_reason = "length" } } } })
    local r = agent.process("q1")
    T.eq(r.text, "The answer is")
    T.contains(r.notice, "cut off")
    T.contains(agent.getHistory()[2].content, "[cut off at the output token limit]")
    mock.push({ body = chat("") })
    r = agent.process("q2")
    T.contains(r.notice, "empty reply")
    T.eq(agent.getHistory()[4].content, "[empty reply]")
  end)

  T.test("output token cap: none for the custom provider unless set", function()
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    mock.reset()
    agent.clearHistory()
    agent.init({ model = "custom:my/model" })
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "a" }, finish_reason = "stop" } } } }, true) })
    agent.process("x")
    T.eq(mock.last().json.max_tokens, nil, "custom: no cap")
    settings.set("cc-code.max_output_tokens", 16000)
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "b" }, finish_reason = "stop" } } } }, true) })
    agent.process("y")
    T.eq(mock.last().json.max_tokens, 16000, "the setting applies")
    settings.unset("cc-code.max_output_tokens")
    agent.init({ model = "anthropic/claude-sonnet-4" })
    mock.push({ body = chat("c") })
    agent.process("z")
    T.eq(mock.last().json.max_tokens, 4096, "gateway default")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("the model is saved by /model and used at startup", function()
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    settings.unset("cc-code.model")
    local saves = T.saves
    local r = agent.process("/model custom deepseek/deepseek-v4.1-flash:thinking")
    T.contains(r.text, "saved")
    T.eq(settings.get("cc-code.model"), "custom:deepseek/deepseek-v4.1-flash:thinking")
    T.eq(T.saves, saves + 1, "settings saved")
    agent.init()
    T.eq(agent.config.model.provider, "custom")
    T.eq(agent.config.model.modelId, "deepseek/deepseek-v4.1-flash:thinking")
    -- A model given at startup (cc-code -m) wins over the saved one
    agent.init({ model = "groq:llama-3.3-70b-versatile" })
    T.eq(agent.config.model.provider, "groq")
    -- The one-word form and the provider-only form
    r = agent.process("/model custom:other/model")
    T.eq(agent.config.model.modelId, "other/model")
    r = agent.process("/model custom")
    T.contains(r.text, "Usage: /model custom <model>")
    T.contains(r.text, "Saved model: other/model")
    -- Gateway prefixes as -m accepts them
    agent.process("/model vercel:openai/gpt-4o")
    T.eq(agent.config.model, "openai/gpt-4o")
    agent.process("/model GATEWAY:openai/gpt-4o-mini")
    T.eq(agent.config.model, "openai/gpt-4o-mini")
    T.eq(settings.get("cc-code.model"), "openai/gpt-4o-mini")
    -- A saved setting that is not a model falls back, with a warning
    settings.set("cc-code.model", "custom")
    agent.init()
    T.eq(agent.config.model, "anthropic/claude-sonnet-4")
    T.contains(agent.state.modelWarning, "'custom' is not a model")
    T.eq(agent.resolveModel("custom:"), nil)
    settings.unset("cc-code.model")
    settings.unset("AI_CUSTOM_BASE_URL")
    agent.init({ model = "anthropic/claude-sonnet-4" })
  end)

  T.test("occode.exec runs a one-shot prompt", function()
    mock.reset()
    mock.push({ body = chat("done") })
    local textOut = occode.exec("say done")
    T.eq(textOut, "done")
  end)

  T.test("UI selection follows the terminal", function()
    T.eq(occode.needsMonochrome(), not term.isColour())
    T.ok(occode.hasTuiSupport())
    T.eq(occode.getUI(true), require("cc-code.terminal"))
  end)

  T.test("skills load from the user and project folders; errors are reported", function()
    T.resetTmp()
    local userDir = T.tmp .. "/user-skills"
    local project = T.tmp .. "/proj"
    T.writeFile(userDir .. "/greet.lua", table.concat({
      "local skills = require('cc-code.skills')",
      "return skills.create({ name = 'greet', commands = { '/greet' },",
      "  onActivate = function(agent, args) return nil, 'Hello, ' .. args end })",
    }, "\n"))
    T.writeFile(userDir .. "/syntax.lua", "return {")
    T.writeFile(userDir .. "/crash.lua", "error('skill bug')")
    T.writeFile(userDir .. "/notskill.lua", "return 42")
    T.writeFile(userDir .. "/badtool.lua", "return { name = 'badtool', tools = { { name = 'x' } } }")
    T.writeFile(project .. "/.cc-code/skills/boom.lua", table.concat({
      "local skills = require('cc-code.skills')",
      "return skills.create({ name = 'boom', commands = { '/boom' },",
      "  onActivate = function() error('it broke') end })",
    }, "\n"))
    local savedDir, savedUser = shell.dir(), agent.USER_SKILLS_DIR
    agent.USER_SKILLS_DIR = userDir
    shell.setDir(project)
    local ok, err = pcall(function()
      agent.init({ model = "anthropic/claude-sonnet-4" })
      T.eq(agent.process("/greet you").text, "Hello, you")
      T.ok(skills.get("help"), "built-in skills still load")
      local problems = table.concat(agent.state.skillErrors, "\n")
      T.eq(#agent.state.skillErrors, 4, problems)
      T.contains(problems, "syntax.lua")
      T.contains(problems, "crash.lua")
      T.contains(problems, "skill bug")
      T.contains(problems, "notskill.lua: the file did not return a skill")
      T.contains(problems, "badtool.lua: tool 1 is not an ai.tool")
      T.eq(skills.get("badtool"), nil, "a skill with a broken tool is not registered")
      -- A skill that fails when used ends the command, not cc-code
      local r = agent.process("/boom")
      T.eq(r.type, "error")
      T.contains(r.text, "The boom skill failed")
      T.contains(r.text, "it broke")
    end)
    shell.setDir(savedDir)
    agent.USER_SKILLS_DIR = savedUser
    skills.registry.greet, skills.registry.boom = nil, nil
    agent.init({ model = "anthropic/claude-sonnet-4" })
    if not ok then error(err, 0) end
  end)

  T.test("a new init drops the last project's skills, not those a program registered", function()
    T.resetTmp()
    local first, second = T.tmp .. "/first", T.tmp .. "/second"
    local function projectSkill(dir, name)
      T.writeFile(dir .. "/.cc-code/skills/" .. name .. ".lua", table.concat({
        "local skills = require('cc-code.skills')",
        "return skills.create({ name = '" .. name .. "', commands = { '/farm' },",
        "  onActivate = function() return nil, '" .. name .. "' end })",
      }, "\n"))
    end
    projectSkill(first, "farmone")
    projectSkill(second, "farmtwo")
    -- An embedding program registers its own skill before cc-code starts
    skills.register(skills.create({
      name = "embedded",
      commands = { "/embedded" },
      onActivate = function() return nil, "from the program" end,
    }))
    local savedDir = shell.dir()
    local ok, err = pcall(function()
      shell.setDir(first)
      agent.init({ model = "anthropic/claude-sonnet-4" })
      T.eq(agent.process("/farm").text, "farmone")
      T.eq(#agent.state.skillErrors, 0, table.concat(agent.state.skillErrors, "\n"))
      shell.setDir(second)
      agent.init({ model = "anthropic/claude-sonnet-4" })
      T.eq(skills.get("farmone"), nil, "the first project's skill is gone")
      T.eq(agent.process("/farm").text, "farmtwo")
      T.eq(#agent.state.skillErrors, 0, "no takeover from a skill that is gone: " ..
        table.concat(agent.state.skillErrors, "\n"))
      T.eq(agent.process("/embedded").text, "from the program", "a program's skill stays")
      T.ok(skills.get("help"), "built-in skills load again")
    end)
    shell.setDir(savedDir)
    skills.registry.embedded = nil
    agent.init({ model = "anthropic/claude-sonnet-4" })
    if not ok then error(err, 0) end
  end)

  T.test("startup reports the takeovers that hold, and skill commands that are built-in", function()
    T.resetTmp()
    local userDir, project = T.tmp .. "/user-skills", T.tmp .. "/proj"
    local function skillFile(path, name, commands)
      T.writeFile(path, table.concat({
        "local skills = require('cc-code.skills')",
        "return skills.create({ name = '" .. name .. "', commands = " .. commands .. ",",
        "  onActivate = function() return nil, 'from " .. name .. "' end })",
      }, "\n"))
    end
    -- The user's zzz takes /model; the project's zzz replaces it, without /model
    skillFile(userDir .. "/zzz.lua", "zzz", "{ '/model' }")
    skillFile(project .. "/.cc-code/skills/zzz.lua", "zzz", "{ '/zzz' }")
    skillFile(userDir .. "/myhelp.lua", "myhelp", "{ '/help' }")
    skillFile(userDir .. "/mytools.lua", "mytools", "{ '/tools', '/clear', '/mine' }")
    local savedDir, savedUser = shell.dir(), agent.USER_SKILLS_DIR
    agent.USER_SKILLS_DIR = userDir
    shell.setDir(project)
    local ok, err = pcall(function()
      agent.init({ model = "anthropic/claude-sonnet-4" })
      T.eq(table.concat(agent.state.skillErrors, "\n"), table.concat({
        "Skill myhelp (" .. userDir .. "/myhelp.lua) takes /help over from skill help",
        "Skill mytools (" .. userDir .. "/mytools.lua): /tools is a built-in command, so the skill never gets it",
        "Skill mytools (" .. userDir .. "/mytools.lua): /clear is a built-in command, so the skill never gets it",
      }, "\n"))
      T.contains(agent.process("/model").text, "Current model")
      T.eq(agent.process("/zzz").text, "from zzz")
      T.eq(agent.process("/help").text, "from myhelp")
      T.eq(agent.process("/mine").text, "from mytools")
      T.contains(agent.process("/tools").text, "Tool calls are shown")
    end)
    shell.setDir(savedDir)
    agent.USER_SKILLS_DIR = savedUser
    agent.init({ model = "anthropic/claude-sonnet-4" })
    if not ok then error(err, 0) end
  end)

  T.test("Ctrl+T in a slow skill command cancels it, not cc-code", function()
    skills.register(skills.create({
      name = "slowcmd",
      commands = { "/slowcmd" },
      onActivate = function() os.pullEvent("cc-ai-test-never") end,
    }))
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      os.queueEvent("terminate")
      local r = agent.process("/slowcmd now")
      T.eq(r.type, "error")
      T.eq(r.error, "cancelled")
      T.eq(r.text, "Cancelled (Ctrl+T).")
      T.eq(#agent.getHistory(), 0, "nothing in the history")
      T.eq(#mock.requests, 0, "nothing sent")
    end)
    skills.registry.slowcmd = nil
    if not ok then error(err, 0) end
  end)

  T.test("secret setting values are blanked out of tool results and the prompt", function()
    local secret = "sk-test-0123456789abcdef"
    settings.set("AI_CUSTOM_API_KEY", secret)
    settings.set("door.password", "hunter2hunter2")
    T.resetTmp()
    -- A file with the key, also split over two lines as a wrapped print
    T.writeFile(T.tmp .. "/leak.txt", "key=" .. secret .. "\npass: hunter2hunter2\nsk-test-0123\n456789abcdef\n")
    T.writeFile(T.tmp .. "/.cc-code.md", "Use the key " .. secret .. " for tests.")
    local savedDir = shell.dir()
    shell.setDir(T.tmp)
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, { { id = "s1", type = "function", ["function"] = { name = "read_file", arguments = "{\"path\":\"leak.txt\"}" } } }) })
      mock.push({ body = chat("done") })
      local shown
      agent.process("show me", { onToolResult = function(_, result) shown = result end })
      local body = mock.requests[2].body
      T.ok(not body:find(secret, 1, true), "the key is not sent")
      T.ok(not body:find("hunter2hunter2", 1, true), "passwords are secrets too")
      T.ok(not body:find("sk-test-0123\\n456789abcdef", 1, true), "a split key is not sent")
      T.contains(body, "key=<redacted>")
      T.ok(not mock.requests[1].body:find(secret, 1, true), "not in the system prompt either")
      T.ok(not shown.content:find(secret, 1, true), "the UI gets the blanked result")
      -- Short values are left alone (they could be anywhere)
      T.eq(agent.redact("gw-test", agent.secretValues()), "gw-test")
    end)
    shell.setDir(savedDir)
    settings.unset("door.password")
    settings.unset("AI_CUSTOM_API_KEY")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("the system prompt is valid UTF-8 and fits the screen and the mod", function()
    T.vanillaOnly()
    T.resetTmp()
    local savedDir = shell.dir()
    shell.setDir(T.tmp)
    local function systemPrompt()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat("ok") })
      agent.process("hi")
      return mock.last().body, mock.last().json.messages[1].content
    end
    local ok, err = pcall(function()
      -- .cc-code.md wins over CLAUDE.md; a CC charset byte; a cut inside an em dash
      T.writeFile(T.tmp .. "/CLAUDE.md", "host-side docs")
      T.writeFile(T.tmp .. "/.cc-code.md", "caf\233 " .. string.rep("a", 3993) .. "\226\128\148 tail")
      local body, system = systemPrompt()
      T.ok(utf8.len(body), "request body is valid UTF-8")
      T.contains(system, "caf\195\169 aaa")
      T.contains(system, "[truncated]")
      T.ok(not system:find("host-side docs", 1, true), ".cc-code.md wins")
      T.ok(not system:find("\226\128\148", 1, true), "the cut character is left out whole")
      T.ok(not system:find("\226\128\n", 1, true), "no part of it either")
      -- CLAUDE.md is the fallback, capped harder
      fs.delete(T.tmp .. "/.cc-code.md")
      T.writeFile(T.tmp .. "/CLAUDE.md", string.rep("b", 2100))
      body, system = systemPrompt()
      T.contains(system, "Project Instructions (CLAUDE.md)")
      T.contains(system, string.rep("b", 2000) .. "\n[truncated]")
      -- What <redacted> means, and what the shell tool can't do
      T.contains(system, "<redacted> in a tool result stands for a secret value (an API key or a password)")
      T.contains(system, "Never write it into a file")
      T.contains(system, "Never put it into a shell command either: for example, `set name <redacted>` " ..
        "would store the marker in place of the secret")
      T.contains(system, "A program gets no input from you")
      T.contains(system, "waits until the timeout, so give it a short one")
      T.contains(system, "It shows this computer's own terminal only: what a program draws on monitors " ..
        "(or on term.native()) is not captured")
      -- Answer length follows the screen size (in windows of each size:
      -- the real screen can be any size, in-game)
      local small = window.create(term.current(), 1, 1, 51, 19, false)
      local before = term.redirect(small)
      local okSmall, smallSystem = pcall(function() return select(2, systemPrompt()) end)
      term.redirect(before)
      if not okSmall then error(smallSystem, 0) end
      T.contains(smallSystem, "The screen is small")
      local win = window.create(term.current(), 1, 1, 100, 50, false)
      local old = term.redirect(win)
      local okBig, bigSystem = pcall(function() return select(2, systemPrompt()) end)
      term.redirect(old)
      if not okBig then error(bigSystem, 0) end
      T.contains(bigSystem, "The screen is large")
      T.contains(bigSystem, "100x50")
      -- Text rules: CC charset without the mod, UTF-8 rules with it
      T.contains(system, "ASCII and Latin-1")
      T.withUnicodeMod(function()
        local _, modSystem = systemPrompt()
        T.contains(modSystem, "Unicode Support")
        T.contains(modSystem, 'select(2, s:find("$"))')
      end)
    end)
    shell.setDir(savedDir)
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  -- Secrets end to end ------------------------------------------------------

  local json = require("cmn-utils.json")
  local ai = require("ai")
  local byteLen = require("cmn-utils.text").byteLen

  -- A made-up key: prefix, then letters and digits up to len bytes
  local function fakeKey(prefix, len, seed)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local out, x = { prefix }, seed
    for _ = 1, len - byteLen(prefix) do
      x = (x * 16807) % 2147483647
      local k = x % 62 + 1
      out[#out + 1] = chars:sub(k, k)
    end
    return table.concat(out)
  end

  -- Fails when any 12 bytes in a row of the key are in str
  local function noPartOf(str, key, what)
    for i = 1, byteLen(key) - 11 do
      local part = key:sub(i, i + 11)
      T.ok(not str:find(part, 1, true), what .. ": key bytes " .. i .. "-" .. (i + 11) .. " were sent")
    end
  end

  local function toolCall(id, name, args)
    return { { id = id, type = "function", ["function"] = { name = name, arguments = json.encode(args) } } }
  end

  -- The tool result the second request sends back, decoded
  local function sentToolResult()
    for _, m in ipairs(mock.requests[2].json.messages) do
      if m.role == "tool" then
        return json.decode(m.content)
      end
    end
  end

  T.test("secrets: a long key wrapped on a 51-column screen (shell screen=true) is not sent", function()
    local key = fakeKey("sk-proj-", 164, 11)
    settings.set("OPENAI_API_KEY", key)
    T.resetTmp()
    T.writeFile(T.tmp .. "/showkey.lua", 'print("key: " .. settings.get("OPENAI_API_KEY"))\nprint("done")\n')
    local win = window.create(term.current(), 1, 1, 51, 19, false)
    local old = term.redirect(win)
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, toolCall("k1", "shell", { command = T.tmp .. "/showkey.lua", screen = true })) })
      mock.push({ body = chat("ok") })
      local shown
      agent.process("show the key", { onToolResult = function(_, res) shown = res end })
      T.eq(shown.screen.size, "51x19")
      local _, rows = shown.screen.text:gsub("\n", "")
      T.ok(rows >= 4, "the key took several rows: " .. shown.screen.text)
      noPartOf(mock.requests[2].body, key, "request")
      noPartOf(shown.screen.text, key, "UI")
      T.contains(sentToolResult().screen.text, "<redacted>")
      T.contains(sentToolResult().screen.text, "done")
    end)
    term.redirect(old)
    settings.unset("OPENAI_API_KEY")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("secrets: escaped and numeric values in the set listing are not sent", function()
    local password = 'Tr0ub4"dor\\&3x9'
    settings.set("vault.password", password)
    settings.set("door.secret", 12345678)
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, toolCall("v1", "shell", { command = "set" })) })
      mock.push({ body = chat("ok") })
      agent.process("list the settings")
      local output = sentToolResult().output
      T.contains(output, '"vault.password" is "<redacted>"')
      T.contains(output, '"door.secret" is <redacted>')
      T.ok(not output:find("Tr0ub4", 1, true), "the password is not sent")
      T.ok(not output:find("12345678", 1, true), "the number is not sent")
      T.ok(not mock.requests[2].body:find("Tr0ub4", 1, true), "nowhere in the request")
    end)
    settings.unset("vault.password")
    settings.unset("door.secret")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("secrets: cc-code's own prompt text is never blanked; the project's text is", function()
    T.resetTmp()
    local savedDir = shell.dir()
    -- (also the directory the next prompt names, not only the shell's)
    agent.setWorkingDirectory(T.tmp)
    local function systemPrompt()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat("ok") })
      agent.process("hi")
      return mock.last().json.messages[1].content
    end
    local ok, err = pcall(function()
      local before = systemPrompt()
      -- An ordinary word as a password (8 bytes: long enough to be one)
      settings.set("door.password", "redstone")
      local after = systemPrompt()
      T.eq(after, before, "the same prompt")
      T.contains(after, "redstone controllers")
      -- What comes from the computer is blanked
      T.writeFile(T.tmp .. "/.cc-code.md", "The door opens with redstone.")
      local withFile = systemPrompt()
      T.contains(withFile, "The door opens with <redacted>.")
      T.contains(withFile, "`redstone`", "the list of CC globals")
      -- A key across the cut of .cc-code.md leaves no start of it behind
      local key = fakeKey("Zq9", 108, 5)
      settings.set("AI_CUSTOM_API_KEY", key)
      T.writeFile(T.tmp .. "/.cc-code.md", string.rep("x", 3995) .. key .. " more text")
      local cut = systemPrompt()
      T.contains(cut, "[truncated]")
      T.ok(not cut:find("Zq9", 1, true), "no start of the key")
      T.contains(cut, string.rep("x", 3995) .. "<reda")
    end)
    agent.setWorkingDirectory("/" .. savedDir)
    settings.unset("door.password")
    settings.unset("AI_CUSTOM_API_KEY")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("secrets: a UTF-8 secret written in the CC charset is blanked from the prompt", function()
    T.resetTmp()
    local savedDir = shell.dir()
    agent.setWorkingDirectory(T.tmp)
    local function systemPrompt()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat("ok") })
      agent.process("hi")
      return mock.last().json.messages[1].content, mock.last().body
    end
    local ok, err = pcall(function()
      -- "passwort99" with a-umlaut: UTF-8 in the setting, Latin-1 in the files
      settings.set("door.password", "p\195\164sswort99")
      T.writeFile(T.tmp .. "/.cc-code.md", "The door opens with p\228sswort99.")
      agent.config.systemPrompt = "Never say p\228sswort99."
      local system, body = systemPrompt()
      T.contains(system, "The door opens with <redacted>.")
      T.contains(system, "Never say <redacted>.")
      T.ok(not body:find("sswort99", 1, true), "the password is not sent")
      -- CLAUDE.md too
      fs.delete(T.tmp .. "/.cc-code.md")
      T.writeFile(T.tmp .. "/CLAUDE.md", "Password: p\228sswort99")
      system = systemPrompt()
      T.contains(system, "Password: <redacted>")
      -- The cap counts the UTF-8 bytes sent (the converted text is longer)
      -- and still cuts between characters
      T.writeFile(T.tmp .. "/CLAUDE.md", "x" .. string.rep("\233", 1500))
      system = systemPrompt()
      T.ok(utf8.len(system), "valid UTF-8")
      T.contains(system, "\nx" .. string.rep("\195\169", 999) .. "\n[truncated]")
    end)
    agent.config.systemPrompt = nil
    agent.setWorkingDirectory("/" .. savedDir)
    settings.unset("door.password")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("a failed shell program's line shows its error, not the shell's source rows", function()
    T.resetTmp()
    local bad, syn = T.tmp .. "/bad.lua", T.tmp .. "/syn.lua"
    T.writeFile(bad, 'print("starting")\nlocal x = nil\nx()\n')
    T.writeFile(syn, 'print("a"\nlocal = 3\n')
    local view = require("cc-code.toolview")
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, { toolCall("f1", "shell", { command = bad })[1],
        toolCall("f2", "shell", { command = syn })[1] }) })
      mock.push({ body = chat("ok") })
      local lines = {}
      agent.process("run both", { onToolResult = function(name, res, args)
        local text, failed = view.line(name, args, res)
        lines[#lines + 1] = { text = text, failed = failed, output = res.output }
      end })
      T.eq(#lines, 2)
      -- The shell prints source rows after the error ("\149Line 3", ...),
      -- which are "?" once the output is UTF-8
      T.contains(lines[1].output, "\n?Line 3")
      T.eq(lines[1].text, "$ " .. bad .. " - failed: " .. bad .. ":3: attempt to call local 'x' (a nil value)")
      T.eq(lines[1].failed, true)
      T.eq(lines[2].text, "$ " .. syn .. " - failed: Unexpected local. Are you missing a closing bracket?")
      T.eq(lines[2].failed, true)
    end)
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("a tool that raises: its error is the result, blanked, UTF-8 and shown", function()
    local key = fakeKey("sk-ant-api03-", 108, 7)
    settings.set("AI_CUSTOM_API_KEY", key)
    skills.register(skills.create({
      name = "raiser",
      tools = {
        ai.tool({
          name = "fetch_data",
          description = "Fetch data",
          parameters = { type = "object", properties = { q = { type = "string" } } },
          execute = function()
            error("request failed: https://api.example.com/v1?key=" .. key .. " caf\233", 0)
          end,
        }),
        ai.tool({
          name = "stop_me",
          description = "Gets stopped",
          execute = function() error("Terminated", 0) end,
        }),
      },
    }))
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, toolCall("e1", "fetch_data", { q = "x" })) })
      mock.push({ body = chat("It failed.") })
      local shown = {}
      local r = agent.process("fetch it", {
        onToolResult = function(name, res, args) shown[#shown + 1] = { name = name, res = res, args = args } end,
      })
      T.eq(r.type, "response")
      T.eq(r.text, "It failed.")
      -- The UI hears about the failed call (its line is completed)
      T.eq(#shown, 1)
      T.eq(shown[1].name, "fetch_data")
      T.eq(shown[1].args.q, "x")
      T.eq(shown[1].res.error, "request failed: https://api.example.com/v1?key=<redacted> caf\195\169")
      local view = require("cc-code.toolview")
      T.eq(select(2, view.line("fetch_data", shown[1].args, shown[1].res)), true, "shown as failed")
      -- The model gets the same { error = ... }, blanked and as UTF-8
      local body = mock.requests[2].body
      T.ok(utf8.len(body), "the request is valid UTF-8")
      noPartOf(body, key, "request")
      T.eq(sentToolResult().error, shown[1].res.error)
      -- The next request carries that history, still valid
      mock.push({ body = chat("ok") })
      agent.process("and now?")
      T.ok(utf8.len(mock.last().body), "the next request is valid UTF-8")
      noPartOf(mock.last().body, key, "next request")

      -- A tool stopped with Ctrl+T without a partial result: the UI line
      -- ends as stopped, and the turn is cancelled
      mock.reset()
      agent.clearHistory()
      shown = {}
      mock.push({ body = chat(nil, toolCall("e2", "stop_me", {})) })
      r = agent.process("stop", {
        onToolResult = function(name, res, args) shown[#shown + 1] = { name = name, res = res, args = args } end,
      })
      T.eq(r.error, "cancelled")
      T.eq(#shown, 1)
      T.eq(shown[1].res.cancelled, true)
      T.eq(view.line("stop_me", shown[1].args, shown[1].res), "stop_me - stopped (Ctrl+T)")
    end)
    skills.registry.raiser = nil
    settings.unset("AI_CUSTOM_API_KEY")
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("a skill tool's result JSON can't hold is sent as an error; keys are converted and blanked", function()
    settings.set("door.password", "hunter2hunter2")
    local returns
    skills.register(skills.create({
      name = "chest",
      tools = {
        ai.tool({ name = "chest_list", description = "List the chest", execute = function() return returns end }),
        ai.tool({
          name = "chest_stop",
          description = "Gets stopped",
          execute = function() error({ terminated = true, result = { "slot 1", "slot 2" } }, 0) end,
        }),
        ai.tool({
          name = "chest_loop",
          description = "Gets stopped with a partial result that refers to itself",
          execute = function()
            local partial = { done = 1 }
            partial.self = partial
            error({ terminated = true, result = partial }, 0)
          end,
        }),
      },
    }))
    local view = require("cc-code.toolview")
    local ok, err = pcall(function()
      -- A turn in which chest_list returns value: its UI line, whether that
      -- shows a failure, and the result the model got
      local function turn(value)
        returns = value
        mock.reset()
        agent.clearHistory()
        mock.push({ body = chat(nil, toolCall("j1", "chest_list", {})) })
        mock.push({ body = chat("done") })
        local line, failed
        local r = agent.process("list the chest", { onToolResult = function(name, res, args)
          line, failed = view.line(name, args, res)
        end })
        T.eq(r.type, "response", "the turn completes: " .. tostring(r.text))
        T.ok(utf8.len(mock.requests[2].body), "the request is valid UTF-8")
        T.ok(not mock.requests[2].body:find("hunter2hunter2", 1, true), "the password is not sent")
        -- The next request carries the history, still valid
        mock.push({ body = chat("ok") })
        T.eq(agent.process("and now?").type, "response")
        T.ok(utf8.len(mock.last().body), "the next request is valid UTF-8")
        return line, failed, sentToolResult()
      end

      -- A list with gaps (the slots inventory.list() returns), and NaN
      local msg = "The tool's result can't be sent as JSON (invalid table: sparse array): " ..
        "return a table with string keys, or a list without gaps"
      local line, failed, sent = turn({ [1] = { name = "minecraft:coal", count = 3 }, [5] = { name = "minecraft:dirt", count = 64 } })
      T.eq(sent.error, msg)
      T.eq(line, "chest_list - error: " .. msg)
      T.eq(failed, true)
      line, failed, sent = turn({ ratio = 0 / 0 })
      T.contains(sent.error, "The tool's result can't be sent as JSON (unexpected number value")
      T.eq(failed, true)
      -- A key in the CC charset is sent as UTF-8; a secret as a key is blanked
      line, failed, sent = turn({ ["B\251che de ch\234ne"] = 12, hunter2hunter2 = "door" })
      T.eq(failed, false)
      T.eq(sent["B\195\187che de ch\195\170ne"], 12)
      T.eq(sent["<redacted>"], "door")
      T.ok(not line:find("hunter2hunter2", 1, true), "not in the UI either: " .. line)
      -- A table that refers to itself (checked before it is converted,
      -- which would never end)
      local loop = { name = "coal" }
      loop.self = loop
      line, failed, sent = turn(loop)
      T.contains(sent.error, "circular reference")
      T.eq(failed, true)

      -- Ctrl+T with a partial result: it goes to the model with a cancel
      -- mark, which a list can't hold
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, toolCall("j2", "chest_stop", {})) })
      local shown
      local r = agent.process("stop it", { onToolResult = function(_, res) shown = res end })
      T.eq(r.error, "cancelled")
      T.eq(shown.cancelled, true)
      T.eq(shown.error, "The tool's result can't be sent as JSON (invalid table: mixed or invalid key types): " ..
        "return a table with string keys, or a list without gaps")
      T.eq(agent.getHistory()[3].role, "tool")
      T.contains(agent.getHistory()[3].content, "can't be sent as JSON")
      mock.push({ body = chat("ok") })
      T.eq(agent.process("continue").type, "response")
      -- ... also when the partial refers to itself: still a cancel
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat(nil, toolCall("j3", "chest_loop", {})) })
      r = agent.process("stop it", { onToolResult = function(_, res) shown = res end })
      T.eq(r.error, "cancelled")
      T.contains(shown.error, "circular reference")

      -- Google encodes the results when it builds the next request: the
      -- bad one must not get into the history
      settings.set("GOOGLE_GENERATIVE_AI_API_KEY", "g-test")
      agent.init({ model = "google:gemini-2.5-flash" })
      local function reply(parts)
        return { candidates = { { content = { role = "model", parts = parts }, finishReason = "STOP" } } }
      end
      returns = { [1] = "coal", [5] = "dirt" }
      mock.reset()
      agent.clearHistory()
      mock.push({ body = reply({ { functionCall = { name = "chest_list", args = { slot = 1 } } } }) })
      mock.push({ body = reply({ { text = "done" } }) })
      r = agent.process("list the chest")
      T.eq(r.type, "response", "the turn completes: " .. tostring(r.text))
      local response
      for _, content in ipairs(mock.requests[2].json.contents) do
        for _, part in ipairs(content.parts) do
          response = part.functionResponse and part.functionResponse.response or response
        end
      end
      T.eq(response.error, msg)
      mock.push({ body = reply({ { text = "ok" } }) })
      T.eq(agent.process("and now?").type, "response", "later requests still work")
      T.eq(#mock.requests, 3)
    end)
    skills.registry.chest = nil
    settings.unset("door.password")
    settings.unset("GOOGLE_GENERATIVE_AI_API_KEY")
    agent.init({ model = "anthropic/claude-sonnet-4" })
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("a skill's failing systemPrompt: left out, one warning; Ctrl+T in it cancels", function()
    agent.init({ model = "anthropic/claude-sonnet-4" })
    -- Works on a turtle only (turtle is nil on a computer)
    skills.register(skills.create({
      name = "fuelinfo",
      systemPrompt = function() return "Fuel: " .. turtle.getFuelLevel() end,
    }))
    local ok, err = pcall(function()
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat("ok") })
      local r = agent.process("hi")
      T.eq(r.type, "response")
      T.eq(#r.warnings, 1)
      T.contains(r.warnings[1], "The fuelinfo skill's systemPrompt failed, so its instructions are left out")
      T.contains(r.warnings[1], "turtle")
      T.ok(not lastRequest():find("Fuel:", 1, true))
      mock.push({ body = chat("ok") })
      r = agent.process("again")
      T.eq(r.type, "response")
      T.eq(r.warnings, nil, "once per skill and session")
      -- Warnings come with any kind of result
      table.insert(agent.state.warnings, "something to say")
      r = agent.process("/help")
      T.eq(r.type, "direct")
      T.eq(r.warnings[1], "something to say")
      T.eq(agent.process("/help").warnings, nil, "handed over once")
      skills.registry.fuelinfo = nil

      -- Ctrl+T while a systemPrompt function waits: nothing is sent
      skills.register(skills.create({
        name = "slowprompt",
        systemPrompt = function() os.pullEvent("cc-ai-test-never") end,
      }))
      mock.reset()
      agent.clearHistory()
      os.queueEvent("terminate")
      r = agent.process("hi")
      T.eq(r.type, "error")
      T.eq(r.error, "cancelled")
      T.eq(#mock.requests, 0, "no request")
      T.eq(#agent.getHistory(), 0, "the prompt is not kept")
    end)
    skills.registry.fuelinfo, skills.registry.slowprompt = nil, nil
    agent.init({ model = "anthropic/claude-sonnet-4" })
    if not ok then error(err, 0) end
  end)

  T.test("a skill tool named like a built-in tool is reported and not sent", function()
    skills.register(skills.create({
      name = "dupe",
      tools = { ai.tool({ name = "shell", description = "Another shell", execute = function() return {} end }) },
    }))
    local ok, err = pcall(function()
      agent.init({ model = "anthropic/claude-sonnet-4" })
      local problems = table.concat(agent.state.skillErrors, "\n")
      T.contains(problems, "Skill dupe: tool shell is not offered")
      mock.reset()
      agent.clearHistory()
      mock.push({ body = chat("ok") })
      agent.process("hi")
      local shells = 0
      for _, tool in ipairs(mock.last().json.tools) do
        if tool["function"].name == "shell" then
          shells = shells + 1
          T.ok(tool["function"].description ~= "Another shell", "the built-in one is sent")
        end
      end
      T.eq(shells, 1)
    end)
    skills.registry.dupe = nil
    agent.init({ model = "anthropic/claude-sonnet-4" })
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)

  T.test("a stream that stops early is reported and marked in the history", function()
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    local ok, err = pcall(function()
      agent.init({ model = "custom:my/model" })
      mock.reset()
      agent.clearHistory()
      -- No finish_reason and no [DONE]: the server stopped sending
      mock.push({ body = mock.sse({ { choices = { { delta = { content = "Half an ans" } } } } }, false) })
      local r = agent.process("q")
      T.eq(r.type, "response")
      T.eq(r.text, "Half an ans")
      T.eq(r.finishReason, "incomplete")
      T.eq(r.notice, "The reply ended early: the server stopped sending before the end.")
      local history = agent.getHistory()
      T.eq(#history, 2)
      T.eq(history[2].content, "Half an ans\n[the reply ended early]")
    end)
    settings.unset("AI_CUSTOM_BASE_URL")
    agent.init({ model = "anthropic/claude-sonnet-4" })
    agent.clearHistory()
    if not ok then error(err, 0) end
  end)
end

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

  T.test("/turtle on a computer builds a prompt with the quick reference", function()
    local skill = skills.get("turtle")
    local prompt = skill.onActivate(agent, "dig a tunnel")
    T.contains(prompt, "turtle.getFuelLevel")
    T.contains(prompt, "My question: dig a tunnel")
    local _, direct = skill.onActivate(agent, "")
    T.contains(direct, "Quick reference loaded")
  end)

  T.test("/turtle full loads docs/turtle.md", function()
    local prompt = skills.get("turtle").onActivate(agent, "full how do I refuel")
    T.contains(prompt, "# Turtle API")
    T.contains(prompt, "My question: how do I refuel")
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
    local ok, r = pcall(agent.process, "run it")
    shellFn.execute = orig
    T.ok(ok, "process raised: " .. tostring(r))
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
end

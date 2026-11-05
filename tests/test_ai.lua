-- tests/test_ai.lua
-- ai.generateText / streamText / generateObject against a fake HTTP API

return function(T)
  local ai = require("ai")
  local json = require("cmn-utils.json")
  local google = require("ai.google")
  local openai = require("ai.openai")
  local mock = T.http

  local function chat(content, extra)
    local msg = { role = "assistant", content = content }
    if extra then for k, v in pairs(extra) do msg[k] = v end end
    return {
      choices = { { message = msg, finish_reason = extra and extra.tool_calls and "tool_calls" or "stop" } },
      usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 },
    }
  end

  local weather = ai.tool({
    name = "get_weather",
    description = "Get the weather",
    parameters = { type = "object", properties = { location = { type = "string" } }, required = { "location" } },
    execute = function(args) return { location = args.location, temperature = 21 } end,
  })

  settings.set("AI_GATEWAY_API_KEY", "gw-test")
  settings.set("GOOGLE_GENERATIVE_AI_API_KEY", "g-test")
  settings.set("OPENAI_API_KEY", "o-test")

  T.test("gateway generateText sends an OpenAI-style request with the settings key", function()
    mock.reset()
    mock.push({ body = chat("Hello there") })
    local r = ai.generateText({ model = "google/gemini-2.5-flash", prompt = "Hi", system = "Be nice", maxOutputTokens = 50, temperature = 0.5 })
    T.eq(r.text, "Hello there")
    T.eq(r.finishReason, "stop")
    T.eq(r.usage.totalTokens, 15)
    local req = mock.last()
    T.eq(req.url, "https://ai-gateway.vercel.sh/v1/chat/completions")
    T.eq(req.headers.Authorization, "Bearer gw-test")
    T.eq(req.json.model, "google/gemini-2.5-flash")
    T.eq(req.json.messages[1].role, "system")
    T.eq(req.json.messages[2].content, "Hi")
    T.eq(req.json.max_tokens, 50)
    T.eq(req.timeout, 60, "default timeout is CC: Tweaked's maximum")
    T.eq(req.binary, true, "binary mode: replies exactly as sent")
  end)

  T.test("timeouts: per-call option, setting, and clamping to 0-60", function()
    mock.reset()
    mock.push({ body = chat("a") })
    ai.generateText({ model = "a/b", prompt = "x", timeout = 0 })
    T.eq(mock.last().timeout, 0)
    settings.set("ai.http_timeout", 500)
    mock.push({ body = chat("b") })
    ai.generateText({ model = "a/b", prompt = "x" })
    T.eq(mock.last().timeout, 60)
    settings.set("ai.http_timeout", "15")
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "c" } } } } }, true) })
    ai.streamText({ model = "a/b", prompt = "x" })
    T.eq(mock.last().timeout, 15)
    settings.unset("ai.http_timeout")
  end)

  T.test("Ctrl+T inside a tool cancels the whole call", function()
    mock.reset()
    local stopper = ai.tool({ name = "stop", parameters = { type = "object", properties = {} },
      execute = function() error("Terminated", 0) end })
    local failing = ai.tool({ name = "fail", parameters = { type = "object", properties = {} },
      execute = function() error("disk full", 0) end })
    mock.push({ body = chat(nil, { tool_calls = { { id = "s", type = "function", ["function"] = { name = "stop", arguments = "{}" } } } }) })
    T.raises(function() ai.generateText({ model = "a/b", prompt = "x", tools = { stopper }, maxSteps = 3 }) end, "Terminated")
    T.eq(#mock.requests, 1, "no second request after Ctrl+T")
    mock.reset()
    mock.push({ body = chat(nil, { tool_calls = { { id = "f", type = "function", ["function"] = { name = "fail", arguments = "{}" } } } }) })
    mock.push({ body = chat("recovered") })
    local r = ai.generateText({ model = "a/b", prompt = "x", tools = { failing }, maxSteps = 3 })
    T.eq(r.toolResults[1].result.error, "disk full", "other tool errors go back to the model")
  end)

  T.test("tool calls run in a loop until the model answers", function()
    mock.reset()
    mock.push({ body = chat(nil, { tool_calls = { { id = "c1", type = "function", ["function"] = { name = "get_weather", arguments = "{\"location\":\"Paris\"}" } } } }) })
    mock.push({ body = chat("It is 21 degrees in Paris") })
    local r = ai.generateText({ model = "openai/gpt-4o-mini", prompt = "Weather?", tools = { weather }, maxSteps = 3 })
    T.eq(r.text, "It is 21 degrees in Paris")
    T.eq(#r.toolResults, 1)
    T.eq(r.toolResults[1].result.temperature, 21)
    local msgs = mock.last().json.messages
    T.eq(msgs[#msgs].role, "tool")
    T.eq(msgs[#msgs].tool_call_id, "c1")
    T.contains(msgs[#msgs].content, "Paris")
    T.eq(mock.requests[1].json.tools[1]["function"].name, "get_weather")
  end)

  T.test("API error bodies become readable errors", function()
    mock.reset()
    mock.push({ code = 401, reason = "Unauthorized", body = { error = { message = "Invalid API key" } } })
    T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "Invalid API key")
    mock.push({ code = 500, reason = "Internal Server Error", body = "oops" })
    T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "HTTP 500")
    mock.push({ fail = "Timed out" })
    T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "Timed out")
  end)

  T.test("missing API key gives the set command", function()
    mock.reset()
    settings.unset("OPENAI_API_KEY")
    T.raises(function() ai.generateText({ model = openai("gpt-4o"), prompt = "x" }) end, "set OPENAI_API_KEY")
    settings.set("OPENAI_API_KEY", "o-test")
  end)

  T.test("streamText parses OpenAI SSE text and tool-call deltas", function()
    mock.reset()
    mock.push({ body = mock.sse({
      { choices = { { delta = { tool_calls = { { index = 0, id = "t1", ["function"] = { name = "get_", arguments = "{\"loc" } } } } } } },
      { choices = { { delta = { tool_calls = { { index = 0, ["function"] = { name = "weather", arguments = "ation\":\"Oslo\"}" } } } }, finish_reason = "tool_calls" } } },
    }, true) })
    mock.push({ body = mock.sse({
      { choices = { { delta = { content = "Cold " } } } },
      { choices = { { delta = { content = "in Oslo" }, finish_reason = "stop" } } },
    }, true) })
    local chunks, finished = {}, nil
    local r = ai.streamText({
      model = openai("gpt-4o-mini"), prompt = "Weather?", tools = { weather }, maxSteps = 3,
      onChunk = function(c) if c.type == "text" then table.insert(chunks, c.text) end end,
      onFinish = function(res) finished = res end,
    })
    T.eq(table.concat(chunks), "Cold in Oslo")
    T.eq(r.text, "Cold in Oslo")
    T.eq(r.toolResults[1].args.location, "Oslo")
    T.eq(finished.finishReason, "stop")
    T.eq(mock.requests[1].json.stream, true)
    T.eq(mock.requests[1].url, "https://api.openai.com/v1/chat/completions")
  end)

  T.test("Google provider: generateText with a function call round trip", function()
    mock.reset()
    mock.push({ body = { candidates = { { content = { role = "model", parts = { { functionCall = { name = "get_weather", args = { location = "Rome" } } } } }, finishReason = "STOP" } } } })
    mock.push({ body = { candidates = { { content = { role = "model", parts = { { text = "Sunny in Rome" } } }, finishReason = "STOP" } }, usageMetadata = { promptTokenCount = 3, candidatesTokenCount = 4, totalTokenCount = 7 } } })
    local r = ai.generateText({ model = google("gemini-2.5-flash"), prompt = "Weather?", system = "sys", tools = { weather }, maxSteps = 3 })
    T.eq(r.text, "Sunny in Rome")
    T.eq(r.finishReason, "stop")
    local req = mock.last()
    T.eq(req.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
    T.eq(req.headers["x-goog-api-key"], "g-test")
    T.eq(req.json.systemInstruction.parts[1].text, "sys")
    local last = req.json.contents[#req.json.contents]
    T.eq(last.parts[1].functionResponse.name, "get_weather")
    T.eq(last.parts[1].functionResponse.response.location, "Rome")
  end)

  T.test("Google provider: streamText over SSE", function()
    mock.reset()
    mock.push({ body = mock.sse({
      { candidates = { { content = { parts = { { text = "Once " } } } } } },
      { candidates = { { content = { parts = { { text = "upon a time" } } }, finishReason = "MAX_TOKENS" } } },
    }) })
    local chunks = {}
    local r = ai.streamText({ model = google("gemini-2.5-flash"), prompt = "Story", onChunk = function(c) table.insert(chunks, c.text) end })
    T.eq(table.concat(chunks), "Once upon a time")
    T.eq(r.finishReason, "length")
    T.contains(mock.last().url, ":streamGenerateContent?alt=sse")
  end)

  T.test("streaming HTTP errors raise with the API message", function()
    mock.reset()
    mock.push({ code = 400, body = { error = { message = "Bad model" } } })
    T.raises(function() ai.streamText({ model = google("nope"), prompt = "x" }) end, "Bad model")
  end)

  T.test("custom provider: endpoint and key from settings, URL normalised", function()
    local custom = require("ai.custom")
    mock.reset()
    settings.unset("AI_CUSTOM_BASE_URL")
    settings.unset("AI_CUSTOM_API_KEY")
    T.raises(function() ai.generateText({ model = custom("m"), prompt = "x" }) end, "set AI_CUSTOM_BASE_URL")
    -- Documented-style URL with /chat/completions already on it
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1/chat/completions")
    settings.set("AI_CUSTOM_API_KEY", "c-test")
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "hi from custom" }, finish_reason = "stop" } } } }, true) })
    local r = ai.generateText({ model = custom("deepseek/deepseek-v4.1-flash:thinking"), prompt = "x" })
    T.eq(r.text, "hi from custom")
    T.eq(mock.last().url, "https://nano-gpt.com/api/v1/chat/completions")
    T.eq(mock.last().headers.Authorization, "Bearer c-test")
    T.eq(mock.last().json.model, "deepseek/deepseek-v4.1-flash:thinking")
    -- Plain base URL with a trailing slash, no key (local server)
    settings.set("AI_CUSTOM_BASE_URL", "http://localhost:1234/v1/")
    settings.unset("AI_CUSTOM_API_KEY")
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "local" } } } } }, true) })
    r = ai.streamText({ model = custom("qwen"), prompt = "x" })
    T.eq(r.text, "local")
    T.eq(mock.last().url, "http://localhost:1234/v1/chat/completions")
    T.eq(mock.last().headers.Authorization, nil, "no Authorization header without a key")
    -- Options override settings; stream = false uses plain replies
    mock.push({ body = chat("opt") })
    ai.generateText({ model = custom.createCustom({ baseURL = "https://x.example/v1", apiKey = "k", stream = false })("m"), prompt = "x" })
    T.eq(mock.last().url, "https://x.example/v1/chat/completions")
    T.eq(mock.last().headers.Authorization, "Bearer k")
    T.eq(mock.last().json.stream, nil)
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("custom provider: generateText goes through streamed replies", function()
    local custom = require("ai.custom")
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    mock.reset()
    -- Two tool calls whose deltas arrive out of index order, then usage in
    -- a final chunk with no choices, and a last line without a newline
    mock.push({ body = mock.sse({
      { choices = { { delta = { tool_calls = { { index = 1, id = "b", ["function"] = { name = "get_weather", arguments = "{\"location\":\"Oslo\"}" } } } } } } },
      { choices = { { delta = { tool_calls = { { index = 0, id = "a", ["function"] = { name = "get_weather", arguments = "{\"location\":\"Rome\"}" } } } }, finish_reason = "tool_calls" } } },
    }, false) })
    mock.push({ body = mock.sse({
      { choices = { { delta = { content = "Rome 21, " } } } },
      { choices = { { delta = { content = "Oslo 21 \226\128\148 both mild" }, finish_reason = "stop" } } },
      { choices = {}, usage = { prompt_tokens = 30, completion_tokens = 8, total_tokens = 38 } },
    }, false):gsub("\r\n\r\n$", "") })
    local r = ai.generateText({ model = custom("deepseek/deepseek-v4.1-flash:thinking"), prompt = "Weather?", tools = { weather }, maxSteps = 3 })
    T.eq(r.text, "Rome 21, Oslo 21 \226\128\148 both mild")
    T.eq(r.finishReason, "stop")
    T.eq(r.usage.totalTokens, 38, "usage from the final chunk")
    T.eq(mock.requests[1].json.stream, true)
    T.eq(mock.requests[1].json.stream_options.include_usage, true, "usage requested")
    T.eq(r.toolResults[1].args.location, "Rome", "tool calls in index order")
    T.eq(r.toolResults[2].args.location, "Oslo")
    local msgs = mock.requests[2].json.messages
    T.eq(msgs[#msgs - 1].tool_call_id, "a")
    T.eq(msgs[#msgs].tool_call_id, "b")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("an error event inside a stream is raised", function()
    mock.reset()
    mock.push({ body = mock.sse({
      { choices = { { delta = { content = "partial" } } } },
      { error = { message = "Upstream provider overloaded" } },
    }, false) })
    T.raises(function() ai.streamText({ model = "a/b", prompt = "x" }) end, "Upstream provider overloaded")
  end)

  T.test("a reply that was cut short gives a short, clear error", function()
    mock.reset()
    local full = json.encode(chat("The answer \226\128\148 forty-two"))
    mock.push({ body = full:sub(1, #full - 4) })
    local err = T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "may have been cut short")
    T.contains(err, (#full - 4) .. " bytes")
    T.ok(#err < 220, "error is short (" .. #err .. " chars)")
  end)

  T.test("generateObject parses JSON output", function()
    mock.reset()
    mock.push({ body = chat("{\"name\":\"Steve\",\"age\":30}") })
    local r = ai.generateObject({ model = "openai/gpt-4o-mini", prompt = "Person", schema = { type = "object", properties = { name = { type = "string" } } } })
    T.eq(r.object.name, "Steve")
    T.contains(mock.last().json.messages[1].content, "Output JSON only")
  end)

  T.test("requests are tagged so each reply matches its own request", function()
    mock.reset()
    mock.push({ body = chat("one") })
    mock.push({ body = chat("two") })
    ai.generateText({ model = "a/b", prompt = "x" })
    ai.generateText({ model = "a/b", prompt = "y" })
    local first, second = mock.requests[1], mock.requests[2]
    T.eq(first.url, "https://ai-gateway.vercel.sh/v1/chat/completions")
    T.eq(first.method, "POST")
    T.ok(first.rawUrl:find("#cc%-ai%-%x+%-%d+$"), "fragment tag: " .. first.rawUrl)
    T.ok(first.rawUrl ~= second.rawUrl, "a new tag per request")
  end)

  T.test("each program's copy of the SDK tags its requests differently", function()
    -- Every program (each cc-code run, each multishell tab) loads its own copy
    local function loadUtils()
      return assert(loadfile(T.root .. "/lib/ai/utils/init.lua", "t", _ENV))()
    end
    local a, b = loadUtils(), loadUtils()
    mock.reset()
    -- A's request is cancelled; B then sends its first request
    mock.push({ hold = true, body = "late reply for A" })
    os.queueEvent("terminate")
    T.raises(function() a.httpPost("https://x.test/v1/chat", {}, "{}") end, "Terminated")
    local tagA = mock.requests[1].rawUrl
    mock.push({ hold = true, body = "B's reply" })
    parallel.waitForAny(function()
      b.httpPost("https://x.test/v1/chat", {}, "{}")
    end, function() end)
    local tagB = mock.requests[2].rawUrl
    T.ok(tagA ~= tagB, "B's tag differs from A's: " .. tagA .. " / " .. tagB)
    -- B's reply arrives while A's prompt loop runs: A must not close it
    local bReply = mock.release(2)
    local ev, url, handle = os.pullEvent("http_success")
    T.eq(url, tagB)
    T.eq(a.discardStale(ev, url, handle), false, "A leaves B's reply alone")
    T.eq(bReply.closed, nil)
    -- A's own late reply is recognised and closed
    local aReply = mock.release(1)
    ev, url, handle = os.pullEvent("http_success")
    T.eq(a.discardStale(ev, url, handle), true)
    T.eq(aReply.closed, true)
  end)

  T.test("a wait hook that yields fails instead of hanging", function()
    mock.reset()
    mock.push({ hold = true, body = chat("never seen") })
    T.raises(function()
      ai.generateText({ model = "a/b", prompt = "x", onWait = function() sleep(0.1) end })
    end, "yielded")
  end)

  T.test("a late reply to a cancelled request is not taken as the next answer", function()
    mock.reset()
    -- Request 1 is slow; Ctrl+T cancels it while it waits
    mock.push({ hold = true, body = chat("STALE answer to the first question") })
    os.queueEvent("terminate")
    T.raises(function() ai.generateText({ model = "a/b", prompt = "first" }) end, "Terminated")
    -- Its reply arrives just as the second question is sent
    local stale = mock.release()
    mock.push({ body = chat("fresh answer") })
    local r = ai.generateText({ model = "a/b", prompt = "second" })
    T.eq(r.text, "fresh answer")
    T.eq(stale.closed, true, "the stale reply was closed unread")
  end)

  T.test("onWait ticks and onEvent sees other events while waiting", function()
    mock.reset()
    mock.push({ hold = true, body = chat("done") })
    os.queueEvent("mouse_scroll", -1, 5, 5)
    local waits, events = {}, {}
    local r = ai.generateText({
      model = "a/b", prompt = "x",
      onWait = function(seconds)
        table.insert(waits, seconds)
        if #waits == 2 then mock.release() end
      end,
      onEvent = function(event, p1) table.insert(events, event .. ":" .. tostring(p1)) end,
    })
    T.eq(r.text, "done")
    T.eq(#waits, 2)
    T.ok(waits[1] >= 0.4 and waits[2] > waits[1], "elapsed seconds grow: " .. waits[1] .. ", " .. waits[2])
    T.eq(events[1], "mouse_scroll:-1")
  end)

  T.test("tool arguments that are not valid JSON don't run the tool", function()
    mock.reset()
    local ran = 0
    local writer = ai.tool({ name = "write_file", parameters = { type = "object", properties = {} },
      execute = function() ran = ran + 1 return { ok = true } end })
    local noArgs = ai.tool({ name = "list", parameters = { type = "object", properties = {} },
      execute = function(args) return { gotTable = type(args) == "table" } end })
    local cut = { choices = { { message = { role = "assistant", content = "", tool_calls = {
      { id = "w", type = "function", ["function"] = { name = "write_file", arguments = "{\"path\":\"/a.lua\",\"content\":\"print(" } },
      { id = "l", type = "function", ["function"] = { name = "list", arguments = "" } },
    } }, finish_reason = "length" } } }
    mock.push({ body = cut })
    mock.push({ body = chat("ok") })
    local r = ai.generateText({ model = "a/b", prompt = "x", tools = { writer, noArgs }, maxSteps = 3 })
    T.eq(ran, 0, "write_file did not run")
    T.contains(r.toolResults[1].result.error, "not valid JSON")
    T.contains(r.toolResults[1].result.error, "output token limit")
    T.eq(r.toolResults[2].result.gotTable, true, "blank arguments mean no arguments")
    local msgs = mock.requests[2].json.messages
    T.eq(msgs[2].tool_calls[1]["function"].arguments, "{}", "broken JSON is not sent back")
  end)

  T.test("the step limit is reported", function()
    mock.reset()
    local call = { tool_calls = { { id = "c", type = "function", ["function"] = { name = "get_weather", arguments = "{\"location\":\"Oslo\"}" } } } }
    mock.push({ body = chat("Checking.", call) })
    mock.push({ body = chat("Checking again.", call) })
    local starts = {}
    local r = ai.generateText({ model = "a/b", prompt = "x", tools = { weather }, maxSteps = 2,
      onStepStart = function(step, maxSteps) table.insert(starts, step .. "/" .. maxSteps) end })
    T.eq(r.stepLimitReached, true)
    T.eq(r.steps, 2)
    T.eq(#mock.requests, 2)
    T.eq(table.concat(starts, ","), "1/2,2/2")
    mock.reset()
    mock.push({ body = chat("Sunny") })
    r = ai.generateText({ model = "a/b", prompt = "x", tools = { weather }, maxSteps = 2 })
    T.eq(r.stepLimitReached, false)
    T.eq(r.steps, 1)
  end)

  T.test("Ctrl+T in a tool keeps finished results and skips the rest", function()
    mock.reset()
    local ran = {}
    local function named(name, fn)
      return ai.tool({ name = name, parameters = { type = "object", properties = {} }, execute = fn })
    end
    local tools = {
      named("first", function() table.insert(ran, "first") return { done = true } end),
      named("second", function()
        table.insert(ran, "second")
        error({ terminated = true, result = { output = "partial output" } }, 0)
      end),
      named("third", function() table.insert(ran, "third") return {} end),
    }
    local calls = {}
    for i, name in ipairs({ "first", "second", "third" }) do
      calls[i] = { id = "c" .. i, type = "function", ["function"] = { name = name, arguments = "{}" } }
    end
    -- The skipped call's arguments were cut off: they must not be kept
    calls[3]["function"].arguments = "{\"path\":\"/x.lua\",\"content\":\"print("
    mock.push({ body = chat(nil, { tool_calls = calls }) })
    local messages = { { role = "user", content = "go" } }
    local finished, cancelledFlag = 0, nil
    T.raises(function()
      ai.generateText({ model = "a/b", messages = messages, tools = tools, maxSteps = 3,
        onStepFinish = function(info) finished = finished + 1 cancelledFlag = info.cancelled end })
    end, "Terminated")
    T.eq(table.concat(ran, ","), "first,second", "the third tool did not run")
    T.eq(finished, 1, "the step finished with every result in the messages")
    T.eq(cancelledFlag, true, "onStepFinish says the step was cancelled")
    T.eq(messages[2].tool_calls[3]["function"].arguments, "{}", "broken arguments of a skipped call")
    T.eq(#messages, 5, "user, assistant, three tool results")
    T.contains(messages[3].content, "\"done\":true")
    T.contains(messages[4].content, "partial output")
    T.contains(messages[4].content, "Stopped by the user")
    T.contains(messages[5].content, "Skipped")
  end)

  T.test("resolveModel reads provider:model specs", function()
    settings.set("AI_CUSTOM_BASE_URL", "https://nano-gpt.com/api/v1")
    local m = ai.resolveModel("custom:deepseek/deepseek-v4.1-flash:thinking")
    T.eq(m.provider, "custom")
    T.eq(m.modelId, "deepseek/deepseek-v4.1-flash:thinking", "only the first colon splits")
    T.eq(ai.modelSpec(m), "custom:deepseek/deepseek-v4.1-flash:thinking")
    T.eq(ai.resolveModel("Google:gemini-2.5-flash").provider, "google")
    T.eq(ai.resolveModel("openai/gpt-4o"), "openai/gpt-4o", "gateway strings stay strings")
    T.eq(ai.resolveModel("gateway:openai/gpt-4o"), "openai/gpt-4o")
    T.eq(ai.resolveModel("anthropic/claude:thinking"), "anthropic/claude:thinking")
    T.eq(ai.modelSpec("openai/gpt-4o"), "openai/gpt-4o")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)
end

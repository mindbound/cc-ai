-- tests/test_ai.lua
-- ai.generateText / streamText / generateObject against a fake HTTP API

return function(T)
  local ai = require("ai")
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

  T.test("generateObject parses JSON output", function()
    mock.reset()
    mock.push({ body = chat("{\"name\":\"Steve\",\"age\":30}") })
    local r = ai.generateObject({ model = "openai/gpt-4o-mini", prompt = "Person", schema = { type = "object", properties = { name = { type = "string" } } } })
    T.eq(r.object.name, "Steve")
    T.contains(mock.last().json.messages[1].content, "Output JSON only")
  end)
end

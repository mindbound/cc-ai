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

  T.test("custom provider: replies that are not an event stream", function()
    local custom = require("ai.custom")
    settings.set("AI_CUSTOM_BASE_URL", "https://example.test/v1")
    local model = custom("m")
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    -- A server that ignores stream=true and answers with plain JSON
    mock.reset()
    mock.push({ body = chat("plain answer") })
    local r = generate()
    T.eq(r.text, "plain answer")
    T.eq(r.finishReason, "stop")
    -- An error object sent with HTTP 200
    mock.push({ body = { error = { message = "Model not found: m" } } })
    T.raises(generate, "Model not found: m")
    -- An HTML page (a wrong base URL)
    mock.push({ body = "<!DOCTYPE html>\n<html><head><title>Welcome</title></head>\n<body>Hi</body></html>" })
    local err = T.raises(generate, "Expected an event stream from example.test")
    T.contains(err, "<!DOCTYPE html> <html>")
    -- Nothing at all
    mock.push({ body = "" })
    T.raises(generate, "was empty")
    -- "data:" without the space is still an event stream
    mock.push({ body = "data:" .. json.encode({ choices = { { delta = { content = "no space" }, finish_reason = "stop" } } }) .. "\n\ndata:[DONE]\n\n" })
    r = generate()
    T.eq(r.text, "no space")
    -- A stream that stops without [DONE] or a finish reason ended early
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "Partial ans" } } } } }, false) })
    r = generate()
    T.eq(r.text, "Partial ans")
    T.eq(r.finishReason, "incomplete")
    -- [DONE] alone (no finish reason) is a proper end
    mock.push({ body = mock.sse({ { choices = { { delta = { content = "Whole" } } } } }, true) })
    r = generate()
    T.eq(r.finishReason, nil)
    -- A chunk object without "data:" framing is no event stream either
    -- (and is not mistaken for a whole completion)
    mock.push({ body = { object = "chat.completion.chunk", choices = { { delta = { content = "x" }, finish_reason = "stop" } } } })
    err = T.raises(generate, "Expected an event stream from example.test")
    T.contains(err, "chat.completion.chunk")
    T.ok(not err:find("%.lua:%d"), "no Lua error position: " .. err)
    mock.push({ body = { choices = { 1 } } })
    err = T.raises(generate, "Expected an event stream from example.test")
    T.ok(not err:find("%.lua:%d"), "no Lua error position: " .. err)
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  -- One SSE event per JSON-able value
  local function event(e)
    return "data: " .. json.encode(e) .. "\n\n"
  end
  local function textChunk(content, finish)
    return { choices = { { delta = { content = content }, finish_reason = finish } } }
  end

  local function customModel()
    settings.set("AI_CUSTOM_BASE_URL", "https://example.test/v1")
    return require("ai.custom")("m")
  end

  T.test("SSE comment, event, id and retry lines before the data", function()
    local model = customModel()
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    mock.reset()
    -- OpenRouter's processing comments (CRLF line ends)
    mock.push({ body = ": OPENROUTER PROCESSING\r\n\r\n: OPENROUTER PROCESSING\r\n\r\n" ..
      mock.sse({ textChunk("Hello "), textChunk("world", "stop") }, true) })
    local r = generate()
    T.eq(r.text, "Hello world", "the first data chunk after the comments is kept")
    T.eq(r.finishReason, "stop")
    -- Field lines before each data line
    mock.push({ body = "retry: 3000\nevent: message\nid: 1\n" .. event(textChunk("Hi ")) ..
      "event: message\nid: 2\n" .. event(textChunk("there", "stop")) .. "id: 3\ndata: [DONE]\n\n" })
    r = generate()
    T.eq(r.text, "Hi there")
    T.eq(r.finishReason, "stop")
    -- Data payloads that are not objects (numbers, booleans, strings) are skipped
    mock.push({ body = "data: 1\n\ndata:true\n\ndata: \"ping\"\n\n" ..
      mock.sse({ textChunk("ok", "stop") }, true) })
    r = generate()
    T.eq(r.text, "ok")
    T.eq(r.finishReason, "stop")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("a stream of keep-alive messages only is not taken for a wrong base URL", function()
    local model = customModel()
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    local expected = "The server closed the stream before sending any data " ..
      "(only keep-alive messages arrived from example.test)."
    mock.reset()
    mock.push({ body = (": keep-alive\n\n"):rep(5) })
    local err = T.raises(generate)
    T.eq(err, expected)
    mock.push({ body = (": OPENROUTER PROCESSING\r\n\r\n"):rep(3) })
    T.eq(T.raises(generate), expected, "CRLF line ends")
    mock.push({ body = "event: ping\nid: 7\nretry: 500\n\n" })
    T.eq(T.raises(generate), expected, "field lines without data")
    -- streamText through another OpenAI-compatible provider
    mock.push({ body = ": keep-alive\n\n" })
    err = T.raises(function() ai.streamText({ model = openai("gpt-4o"), prompt = "x" }) end)
    T.contains(err, "closed the stream before sending any data")
    T.ok(not err:find("base URL", 1, true), "no base URL hint: " .. err)
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("comment-like lines among other lines: the other lines are read as the reply", function()
    local model = customModel()
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    mock.reset()
    -- An HTML page (wrong base URL) with a CSS line at column 0
    mock.push({ body = "<!DOCTYPE html>\n<html><head><style>\n:root { --bg: #fff; }\nbody { margin: 0 }\n" ..
      "</style></head>\n<body>Welcome</body></html>" })
    local err = T.raises(generate, "Expected an event stream from example.test (is the base URL right?)")
    T.contains(err, "<!DOCTYPE html> <html><head><style> body { margin: 0 }")
    -- A plain JSON error after a keep-alive
    mock.push({ body = ": keep-alive\n\n{\"error\":{\"message\":\"plain after comment\"}}" })
    T.eq(T.raises(generate), "plain after comment")
    -- A whole completion after a keep-alive
    mock.push({ body = ": keep-alive\n\n" .. json.encode(chat("whole answer")) })
    T.eq(generate().text, "whole answer")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("message content given as a list of parts gives the text of its text parts", function()
    local utils = require("ai.utils")
    -- Mistral's reasoning models: thinking, then text
    local parts = {
      { type = "thinking", thinking = { { type = "text", text = "2 + 2 is 4" } } },
      { type = "text", text = "The answer " },
      { type = "text", text = "is 4." },
    }
    mock.reset()
    -- A plain reply, with a tool call: the history gets the text as a string
    mock.push({ body = chat(parts, { tool_calls = { { id = "c1", type = "function",
      ["function"] = { name = "get_weather", arguments = "{\"location\":\"Oslo\"}" } } } }) })
    mock.push({ body = chat(parts) })
    local r = ai.generateText({ model = "a/b", prompt = "2+2?", tools = { weather }, maxSteps = 2 })
    T.eq(r.text, "The answer is 4.")
    T.eq(mock.requests[2].json.messages[2].content, "The answer is 4.")
    -- A server that ignores stream=true (custom provider)
    local model = customModel()
    mock.push({ body = chat(parts) })
    r = ai.generateText({ model = model, prompt = "2+2?" })
    T.eq(r.text, "The answer is 4.")
    -- A stream whose deltas hold lists of parts
    mock.push({ body = mock.sse({
      { choices = { { delta = { content = { parts[1] } } } } },
      { choices = { { delta = { content = { parts[2] } } } } },
      { choices = { { delta = { content = { parts[3] } }, finish_reason = "stop" } } },
    }, true) })
    local chunks = {}
    r = ai.streamText({ model = model, prompt = "2+2?",
      onChunk = function(c) table.insert(chunks, c.text) end })
    T.eq(r.text, "The answer is 4.")
    T.eq(table.concat(chunks, "|"), "The answer |is 4.", "no chunk for the thinking part")
    settings.unset("AI_CUSTOM_BASE_URL")
    -- Google reads a list given as a message's content the same way
    mock.push({ body = { candidates = { { content = { role = "model", parts = { { text = "Hi" } } }, finishReason = "STOP" } } } })
    ai.generateText({ model = google("gemini-2.5-flash"), messages = { { role = "user",
      content = { { type = "text", text = "Hello" }, { type = "image_url", image_url = { url = "x" } } } } } })
    T.eq(mock.last().json.contents[1].parts[1].text, "Hello")
    T.eq(utils.contentText(nil), "")
    T.eq(utils.contentText(5), "")
    T.eq(utils.contentText({ "x", { text = "no type" } }), "")
  end)

  T.test("errors sent as an SSE error: line or an error event are raised", function()
    local model = customModel()
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    local errorLine = "error: {\"code\":500,\"message\":\"context size exceeded\"}\n\n"
    mock.reset()
    -- llama.cpp's error line after some data
    mock.push({ body = event(textChunk("Partial")) .. errorLine })
    T.eq(T.raises(generate), "context size exceeded")
    -- ... and alone, before any data
    mock.push({ body = errorLine })
    T.eq(T.raises(generate), "context size exceeded", "not the wrong-base-URL message")
    mock.push({ body = "error: {\"error\":{\"message\":\"Nested message\"}}\n\n" })
    T.eq(T.raises(generate), "Nested message")
    mock.push({ body = "error: model failed to load\n" })
    T.eq(T.raises(generate), "model failed to load", "plain text")
    -- "event: error" whose data has no "error" key, after data and alone
    mock.push({ body = event(textChunk("Hi")) ..
      "event: error\ndata: {\"message\":\"Rate limit reached\",\"code\":429}\n\n" })
    T.eq(T.raises(generate), "Rate limit reached")
    mock.push({ body = "event: error\ndata: {\"message\":\"Queue full\"}\n\n" })
    T.eq(T.raises(generate), "Queue full")
    mock.push({ body = "event: error\ndata: upstream timeout\n\n" })
    T.eq(T.raises(generate), "upstream timeout")
    -- An event name holds only until the blank line that ends its event
    mock.push({ body = "event: error\n\n" .. mock.sse({ textChunk("fine", "stop") }, true) })
    local r = generate()
    T.eq(r.text, "fine")
    -- streamText raises them too
    mock.push({ body = event(textChunk("Partial")) .. errorLine })
    T.raises(function() ai.streamText({ model = openai("gpt-4o"), prompt = "x" }) end, "context size exceeded")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("an empty finish_reason does not end the stream", function()
    local model = customModel()
    local function generate()
      return ai.generateText({ model = model, prompt = "x" })
    end
    mock.reset()
    -- A server that sends "finish_reason": "" in every chunk, cut off
    mock.push({ body = mock.sse({ textChunk("Hel", ""), textChunk("lo", "") }, false) })
    local r = generate()
    T.eq(r.text, "Hello")
    T.eq(r.finishReason, "incomplete")
    -- ... and the same server's complete reply
    mock.push({ body = mock.sse({ textChunk("Hel", ""), textChunk("lo", "stop") }, false) })
    r = generate()
    T.eq(r.finishReason, "stop")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("a tool call cut off by a stream that ended early does not run", function()
    local model = customModel()
    local ran = {}
    local list = ai.tool({ name = "list", description = "List",
      parameters = { type = "object", properties = { path = { type = "string" } } },
      execute = function(args)
        table.insert(ran, "list:" .. tostring(args.path))
        return { files = { "a" } }
      end })
    local function call(index, id, name, arguments)
      return { choices = { { delta = { tool_calls = { { index = index, id = id,
        ["function"] = { name = name, arguments = arguments } } } } } } }
    end
    local cutMessage = "The reply ended early (the server stopped sending), so this call " ..
      "was cut off and did not run; send it again."
    mock.reset()
    -- Cut right after the call's name: no finish reason, no [DONE]
    mock.push({ body = event({ choices = { { delta = { content = "Let me list /rom." } } } }) ..
      event(call(0, "c1", "list", "")) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    local r = ai.generateText({ model = model, prompt = "x", tools = { list }, maxSteps = 3 })
    T.eq(#ran, 0, "the cut-off call did not run with no arguments")
    T.eq(r.toolResults[1].result.error, cutMessage)
    T.eq(r.text, "Done.")
    local msgs = mock.requests[2].json.messages
    T.eq(msgs[2].tool_calls[1]["function"].arguments, "{}", "blank arguments are not sent back")
    T.contains(msgs[3].content, "cut off")
    -- Earlier calls of the step run; the last one was cut in its arguments
    mock.reset()
    mock.push({ body = event(call(0, "c1", "list", "")) .. event(call(1, "c2", "list", "{\"pa")) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    ran = {}
    r = ai.generateText({ model = model, prompt = "x", tools = { list }, maxSteps = 3 })
    T.eq(table.concat(ran, ","), "list:nil", "the complete first call ran")
    T.eq(r.toolResults[2].result.error, cutMessage)
    -- A broken call before the last one says that the reply ended early
    mock.reset()
    mock.push({ body = event(call(0, "c1", "list", "{\"pa")) .. event(call(1, "c2", "list", "{\"path\":\"/\"}")) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    ran = {}
    r = ai.generateText({ model = model, prompt = "x", tools = { list }, maxSteps = 3 })
    T.contains(r.toolResults[1].result.error, "not valid JSON")
    T.contains(r.toolResults[1].result.error, "The reply ended early")
    T.eq(table.concat(ran, ","), "list:/", "the last call is complete JSON and runs")
    -- A stream that ended properly: blank arguments still mean no arguments
    mock.reset()
    mock.push({ body = event(call(0, "c1", "list", "")) ..
      event({ choices = { { delta = {}, finish_reason = "tool_calls" } } }) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    ran = {}
    ai.generateText({ model = model, prompt = "x", tools = { list }, maxSteps = 3 })
    T.eq(table.concat(ran, ","), "list:nil")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  -- A "list" tool that records each call's path in ran
  local function listTool(ran)
    return ai.tool({ name = "list", description = "List",
      parameters = { type = "object", properties = { path = { type = "string" } } },
      execute = function(args)
        table.insert(ran, "list:" .. tostring(args.path))
        return { files = { "a" } }
      end })
  end
  local function callChunk(index, id, name, arguments, finish)
    return { choices = { { delta = { tool_calls = { { index = index, id = id,
      ["function"] = { name = name, arguments = arguments } } } }, finish_reason = finish } } }
  end
  local function toolCall(id, arguments)
    return { id = id, type = "function", ["function"] = { name = "list", arguments = arguments } }
  end

  T.test("the last tool call of a reply cut at the output token limit does not run", function()
    local model = customModel()
    local limitMessage = "The reply hit the output token limit, so this call was cut off and " ..
      "did not run; send it again in smaller parts (write large files in several " ..
      "smaller write_file/edit_file calls)."
    local ran = {}
    mock.reset()
    -- Streamed: cut right after the call's name
    mock.push({ body = mock.sse({ callChunk(0, "c1", "list", ""),
      { choices = { { delta = {}, finish_reason = "length" } } } }, true) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    local r = ai.generateText({ model = model, prompt = "x", tools = { listTool(ran) }, maxSteps = 3 })
    T.eq(#ran, 0, "the cut-off call did not run with no arguments")
    T.eq(r.toolResults[1].result.error, limitMessage)
    T.eq(mock.requests[2].json.messages[2].tool_calls[1]["function"].arguments, "{}")
    settings.unset("AI_CUSTOM_BASE_URL")
    -- A plain reply: an earlier blank call runs; the last one, cut in its
    -- arguments, gets the same message
    ran = {}
    mock.reset()
    mock.push({ body = { choices = { { message = { role = "assistant", content = "",
      tool_calls = { toolCall("a", ""), toolCall("b", "{\"path\":\"/ro") } }, finish_reason = "length" } } } })
    mock.push({ body = chat("Done.") })
    r = ai.generateText({ model = "a/b", prompt = "x", tools = { listTool(ran) }, maxSteps = 3 })
    T.eq(table.concat(ran, ","), "list:nil", "the earlier blank call ran")
    T.eq(r.toolResults[2].result.error, limitMessage)
    T.eq(mock.requests[2].json.messages[2].tool_calls[2]["function"].arguments, "{}")
  end)

  T.test("tool call arguments go back in the history as a JSON object", function()
    local model = customModel()
    local ran = {}
    mock.reset()
    -- Streamed arguments sent decoded: an empty table (which arrives as
    -- [] here, as rxi json writes it) and an object
    mock.push({ body = mock.sse({ callChunk(0, "c1", "list", {}),
      callChunk(1, "c2", "list", { path = "/rom" }, "tool_calls") }, true) })
    mock.push({ body = mock.sse({ textChunk("Done.", "stop") }, true) })
    ai.generateText({ model = model, prompt = "x", tools = { listTool(ran) }, maxSteps = 3 })
    T.eq(table.concat(ran, ","), "list:nil,list:/rom")
    local sent = mock.requests[2].json.messages[2].tool_calls
    T.eq(sent[1]["function"].arguments, "{}", "not []")
    T.eq(sent[2]["function"].arguments, "{\"path\":\"/rom\"}")
    -- ... also in the stream's own result
    mock.push({ body = mock.sse({ callChunk(0, "c1", "list", {}, "tool_calls") }, true) })
    T.eq(model.doStream({ prompt = "x" }).toolCalls[1]["function"].arguments, "{}")
    settings.unset("AI_CUSTOM_BASE_URL")
    -- A plain reply: JSON lists mean no arguments, and decoded arguments
    -- are encoded
    ran = {}
    mock.reset()
    mock.push({ body = chat(nil, { tool_calls = { toolCall("a", "[]"), toolCall("b", "[\"/rom\"]"),
      toolCall("c", {}), toolCall("d", { path = "/" }), toolCall("e", "5"), toolCall("f", "[null,\"/rom\"]") } }) })
    mock.push({ body = chat("Done.") })
    local r = ai.generateText({ model = "a/b", prompt = "x", tools = { listTool(ran) }, maxSteps = 3 })
    T.eq(table.concat(ran, ","), "list:nil,list:nil,list:nil,list:/,list:nil,list:nil")
    T.eq(r.toolResults[2].args[1], nil, "a list is not passed on")
    sent = mock.requests[2].json.messages[2].tool_calls
    local texts = {}
    for i, call in ipairs(sent) do
      texts[i] = call["function"].arguments
    end
    T.eq(table.concat(texts, " "), "{} {} {} {\"path\":\"/\"} {} {}", "a list starting with null is a list too")
    -- Streamed arguments sent decoded as a list with a hole: rxi json can't
    -- write that back, so they count as no arguments (no crash)
    settings.set("AI_CUSTOM_BASE_URL", "https://example.test/v1")
    mock.reset()
    mock.push({ body = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"h1","function":' ..
      '{"name":"list","arguments":[null,"x"]}}]},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n' })
    T.eq(customModel().doStream({ prompt = "x" }).toolCalls[1]["function"].arguments, "{}")
    settings.unset("AI_CUSTOM_BASE_URL")
  end)

  T.test("tools without arguments are sent without a parameters schema", function()
    local function run() return { fuel = 5 } end
    local tools = {
      weather,
      ai.tool({ name = "fuel_level", description = "Fuel", parameters = { type = "object", properties = {} }, execute = run }),
      ai.tool({ name = "ping", execute = run }),
      ai.tool({ name = "noop", parameters = {}, execute = run }),
      ai.tool({ name = "free", parameters = { type = "object" }, execute = run }),
    }
    -- Every OpenAI-compatible provider builds its tools in openai-compat
    settings.set("GROQ_API_KEY", "q-test")
    local models = { "a/b", openai("gpt-4o"), require("ai.groq")("llama"), customModel() }
    for _, model in ipairs(models) do
      mock.reset()
      mock.push({ body = chat("ok") })
      ai.generateText({ model = model, prompt = "x", tools = tools })
      local req = mock.last()
      local label = ai.modelSpec(model)
      local sent = req.json.tools
      T.eq(#sent, 5, label)
      T.eq(sent[1]["function"].parameters.properties.location.type, "string", label .. ": a normal tool keeps its schema")
      T.eq(sent[2]["function"].name, "fuel_level", label)
      T.eq(sent[2]["function"].parameters, nil, label .. ": empty properties")
      T.eq(sent[3]["function"].parameters, nil, label .. ": no parameters")
      T.eq(sent[4]["function"].parameters, nil, label .. ": empty parameters")
      T.eq(sent[5]["function"].parameters.type, "object", label .. ": an object schema without properties is kept")
      T.ok(not req.body:find("\"properties\":[]", 1, true), label .. ": " .. req.body)
      T.ok(not req.body:find("\"parameters\":[]", 1, true), label .. ": " .. req.body)
    end
    settings.unset("GROQ_API_KEY")
    settings.unset("AI_CUSTOM_BASE_URL")
    -- Google: Gemini also rejects an object schema without properties.
    -- The no-argument call comes back with "args": {}, which must not go
    -- back as [], and a tool result must be an object.
    mock.reset()
    mock.push({ body = "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[" ..
      "{\"functionCall\":{\"name\":\"fuel_level\",\"args\":{}}}," ..
      "{\"functionCall\":{\"name\":\"noop\",\"args\":{}}}]},\"finishReason\":\"STOP\"}]}" })
    mock.push({ body = { candidates = { { content = { role = "model", parts = { { text = "5 fuel" } } }, finishReason = "STOP" } } } })
    local emptyResult = ai.tool({ name = "noop", parameters = {}, execute = function() return {} end })
    local gtools = { tools[1], tools[2], tools[3], emptyResult, tools[5] }
    local r = ai.generateText({ model = google("gemini-2.5-flash"), prompt = "Fuel?", tools = gtools, maxSteps = 2 })
    T.eq(r.text, "5 fuel")
    T.eq(r.toolResults[1].result.fuel, 5, "the no-argument tool ran")
    local decls = mock.requests[1].json.tools[1].functionDeclarations
    T.eq(decls[1].parameters.properties.location.type, "string")
    T.eq(decls[2].parameters, nil)
    T.eq(decls[3].parameters, nil)
    T.eq(decls[4].parameters, nil)
    T.eq(decls[5].parameters, nil, "no properties")
    local body = mock.requests[2].body
    T.ok(not body:find("\"args\":[]", 1, true), "empty args are dropped: " .. body)
    T.contains(body, "\"response\":{\"result\":[]}", "an empty result is wrapped in an object")
    T.contains(body, "\"response\":{\"fuel\":5}")
  end)

  T.test("empty properties of nested object parameters are left out", function()
    local utils = require("ai.utils")
    local params = { type = "object", required = { "name" }, properties = {
      name = { type = "string" },
      opts = { type = "object", properties = {} },
      list = { type = "array", items = { type = "object",
        properties = { deep = { type = "object", properties = {} } } } },
    } }
    local tool = ai.tool({ name = "nested", parameters = params, execute = function() return {} end })
    mock.reset()
    mock.push({ body = chat("ok") })
    ai.generateText({ model = "a/b", prompt = "x", tools = { tool } })
    local req = mock.last()
    T.ok(not req.body:find("\"properties\":[]", 1, true), req.body)
    local sent = req.json.tools[1]["function"].parameters
    T.eq(sent.required[1], "name")
    T.eq(sent.properties.name.type, "string")
    T.eq(sent.properties.opts.type, "object")
    T.eq(sent.properties.opts.properties, nil)
    T.eq(sent.properties.list.items.properties.deep.type, "object")
    T.eq(sent.properties.list.items.properties.deep.properties, nil)
    T.eq(type(params.properties.opts.properties), "table", "the tool's own schema is unchanged")
    T.eq(type(params.properties.list.items.properties.deep.properties), "table")
    mock.push({ body = { candidates = { { content = { role = "model", parts = { { text = "ok" } } }, finishReason = "STOP" } } } })
    ai.generateText({ model = google("gemini-2.5-flash"), prompt = "x", tools = { tool } })
    T.ok(not mock.last().body:find("\"properties\":[]", 1, true), "Google: " .. mock.last().body)
    -- Also under anyOf/oneOf/allOf, additionalProperties and tuple items
    local wide = utils.toolParameters({ type = "object", properties = {
      pick = { anyOf = { { type = "object", properties = {} }, { type = "string" } } },
      map = { type = "object", additionalProperties = { type = "object", properties = {} } },
      pair = { type = "array", items = { { type = "object", properties = {} }, { type = "number" } } },
    } })
    T.eq(wide.properties.pick.anyOf[1].properties, nil)
    T.eq(wide.properties.pick.anyOf[2].type, "string")
    T.eq(wide.properties.map.additionalProperties.properties, nil)
    T.eq(wide.properties.pair.items[1].properties, nil)
    T.eq(wide.properties.pair.items[2].type, "number")
    T.ok(not json.encode(wide):find("[]", 1, true), json.encode(wide))
    -- A schema that refers to itself does not loop forever
    local loop = { type = "object", properties = { name = { type = "string" } } }
    loop.properties.child = loop
    T.eq(utils.toolParameters(loop).properties.child, loop)
  end)

  T.test("plain replies with unexpected shapes give clear errors", function()
    mock.reset()
    mock.push({ body = { error = "Model overloaded" } })
    T.eq(T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end), "Model overloaded")
    mock.push({ body = { choices = { { finish_reason = "stop" } } } })
    local err = T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "has no message")
    T.ok(not err:find("%.lua:%d"), "no Lua error position: " .. err)
    mock.push({ body = { choices = {} } })
    err = T.raises(function() ai.generateText({ model = "a/b", prompt = "x" }) end, "No choices")
    T.ok(not err:find("%.lua:%d"), "no Lua error position: " .. err)
    -- Google's stream skips data that is not an object
    mock.push({ body = "data: 1\n\n" .. mock.sse({ { candidates = { { content = { parts = { { text = "Hi" } } }, finishReason = "STOP" } } } }) })
    local r = ai.streamText({ model = google("gemini-2.5-flash"), prompt = "x" })
    T.eq(r.text, "Hi")
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
    T.contains(r.toolResults[2].result.error, "output token limit, so this call was cut off and did not run",
      "the last call, blank, was cut at the limit")
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

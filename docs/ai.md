# ai - Core SDK

AI SDK for ComputerCraft: Tweaked Lua - generate text, stream responses, use tools, and get structured output.

Inspired by the [Vercel AI SDK](https://sdk.vercel.ai/).

## Using the library

CraftOS gives each program its own `require`, so add the cc-ai libraries to `package.path` at the top of your program:

```lua
package.path = "/cc-ai/lib/?.lua;/cc-ai/lib/?/init.lua;" .. package.path
local ai = require("ai")
```

API keys are read from the settings API. Set them in the shell with `set <NAME> <key>`, or in code with `settings.set(name, key)`.

## Providers

### Vercel AI Gateway (default)

Use `provider/model` string format. Requires the `AI_GATEWAY_API_KEY` setting.

```lua
local ai = require("ai")

ai.generateText({
  model = "openai/gpt-4o-mini",
  prompt = "Hello",
})
```

### Google Generative AI

Direct access to Google's API. Requires the `GOOGLE_GENERATIVE_AI_API_KEY` setting.

```lua
local ai = require("ai")
local google = require("ai.google")

ai.generateText({
  model = google("gemini-2.5-flash"),
  prompt = "Hello",
})
```

### OpenAI

Direct access to OpenAI's API. Requires the `OPENAI_API_KEY` setting.

```lua
local ai = require("ai")
local openai = require("ai.openai")

ai.generateText({
  model = openai("gpt-4o-mini"),
  prompt = "Hello",
})
```

### Custom (OpenAI-compatible)

Any endpoint that implements `/chat/completions`: NanoGPT, OpenRouter, LM Studio, llama.cpp, Ollama and so on. Set the endpoint and, if it needs one, the key:

```
set AI_CUSTOM_BASE_URL https://nano-gpt.com/api/v1
set AI_CUSTOM_API_KEY <key>
```

The base URL may also be given with `/chat/completions` on the end, as some providers document it.

The custom provider requests streamed replies even for `generateText`. Data then keeps arriving while a slow (thinking) model works, so the 60-second idle timeout isn't hit. Pass `stream = false` to `createCustom` to turn this off for a server that doesn't support streaming.

```lua
local ai = require("ai")
local custom = require("ai.custom")

ai.generateText({
  model = custom("deepseek/deepseek-v4.1-flash:thinking"),
  prompt = "Hello",
})

-- Or configure it in code, e.g. for a second endpoint
local local_llm = custom.createCustom({ baseURL = "http://localhost:1234/v1" })
ai.generateText({ model = local_llm("qwen2.5-coder"), prompt = "Hello" })
```

In-game, CC: Tweaked blocks requests to private addresses (localhost, LAN) by default. To use a server on your own network, allow it in the `http` rules of `computercraft-server.toml`.

## API

### generateText

Generate text from a prompt or messages.

```lua
local result = ai.generateText({
  model = "google/gemini-2.5-flash",
  prompt = "Write a recipe (50 words)",           -- or use messages = {...}
  system = "You are a chef.",         -- optional system prompt
  maxOutputTokens = 100,              -- optional
  temperature = 0.7,                  -- optional
  timeout = 60,                       -- optional: HTTP idle timeout in seconds, 0-60, 0 = none
})

print(result.text)
print(result.finishReason)  -- "stop", "length", "tool_calls", etc.
```

### streamText

Receive the response as text chunks through `onChunk`. CC: Tweaked downloads the whole HTTP response before a program can read it, so all the chunks arrive together when the response completes.

```lua
ai.streamText({
  model = "openai/gpt-4o-mini",
  prompt = "Tell me a story",
  onChunk = function(chunk)
    if chunk.type == "text" then
      io.write(chunk.text)
    end
  end,
  onFinish = function(result)
    print("\nDone: " .. result.finishReason)
  end,
})
```

### generateObject

Generate structured JSON output.

```lua
local result = ai.generateObject({
  model = "openai/gpt-4o-mini",
  schema = {
    type = "object",
    properties = {
      name = { type = "string" },
      age = { type = "number" },
    },
  },
  prompt = "Generate a random person.",
})

print(result.object.name)
print(result.object.age)
```

### Tool Calling

Define tools that the model can call.

```lua
local weatherTool = ai.tool({
  name = "get_weather",
  description = "Get the weather in a location",
  parameters = {
    type = "object",
    properties = {
      location = { type = "string" },
    },
    required = { "location" },
  },
  execute = function(args)
    return { temperature = 72, condition = "sunny" }
  end,
})

local result = ai.generateText({
  model = "openai/gpt-4o-mini",
  prompt = "What's the weather in Paris?",
  tools = { weatherTool },
  maxSteps = 3,  -- allow multi-step tool calling
})
```

Each step is one model request; the tools a reply asks for run before the next one. When the loop stops at `maxSteps` with tool results the model has not seen yet, `result.stepLimitReached` is `true`. `result.steps` counts the requests.

If a tool call's arguments are not valid JSON (usually a reply cut off at the output token limit, `finishReason == "length"`), the tool does not run. The model gets an error result saying so instead. Blank arguments count as no arguments (`{}`).

A tool can raise `"Terminated"` (or `{ terminated = true, result = {...} }`, with a partial result) to cancel the call, as Ctrl+T does. The finished tool results of that step and an error for each remaining call are still added to `messages`, so the history stays valid, and then `generateText` raises `"Terminated"`.

### Waiting and step hooks

Requests are asynchronous, and the SDK waits for the reply in its own event loop. These optional hooks let a program stay live meanwhile (they work with `generateText` and `streamText`):

```lua
ai.generateText({
  model = "openai/gpt-4o-mini",
  prompt = "...",
  onStepStart = function(step, maxSteps) end,  -- before each model request
  onWait = function(seconds) end,              -- about twice a second while waiting
  onEvent = function(event, ...) end,          -- other events that arrive meanwhile
  onStepFinish = function(info) end,           -- after each step (info.step, .text,
                                               -- .toolCalls, .finishReason, .usage)
})
```

`onWait` and `onEvent` must not yield: no `sleep`, `os.pullEvent`, `read`, `rednet.receive`, `http.get` or turtle moves. A nested event pull could take the reply's own event, so a hook that yields raises an error instead. `onStepStart` and `onStepFinish` run outside the wait and may yield. `onStepFinish`'s `info.cancelled` is `true` when Ctrl+T stopped one of that step's tools.

Ctrl+T while waiting raises `"Terminated"`, as a blocking `http.post` does. Each request is sent with a `#cc-ai-<session>-<n>` fragment on its URL, unique to the request and to the program that sent it. The server never sees the fragment, but CC: Tweaked reports the URL with the reply. That way, a late reply to a cancelled request is recognised and closed, and a reply meant for another program (another multishell tab, for example) is left alone. A program with its own event loop can close such replies too: call `require("ai.utils").discardStale(event, ...)` with each event it pulls.

### Model specs

`ai.resolveModel(spec)` turns a string into a model: `"custom:deepseek/deepseek-v4.1-flash:thinking"`, `"google:gemini-2.5-flash"`, `"openai:gpt-4o"` or `"groq:..."` give direct provider models. `"gateway:openai/gpt-4o"` or plain `"openai/gpt-4o"` is a gateway model. Only the first `:` after a known provider name splits, because model ids contain `:` themselves. `ai.modelSpec(model)` gives the string back.

## Examples

Run examples from the CraftOS shell:

```
/cc-ai/examples/generateText
/cc-ai/examples/streamText
/cc-ai/examples/toolCalling
/cc-ai/examples/generateObject
/cc-ai/examples/runAll
```

## Settings

- `AI_GATEWAY_API_KEY` - For Vercel AI Gateway (string models)
- `GOOGLE_GENERATIVE_AI_API_KEY` - For Google provider
- `OPENAI_API_KEY` - For OpenAI provider
- `GROQ_API_KEY` - For Groq provider
- `AI_CUSTOM_BASE_URL` - Endpoint for the custom provider (OpenAI-compatible)
- `AI_CUSTOM_API_KEY` - Key for the custom provider (optional)
- `ai.http_timeout` - HTTP idle timeout in seconds, 0-60 (default 60, 0 = none)

The timeout counts seconds without any data from the server, and CC: Tweaked rejects values above 60. A non-streaming reply sends nothing until it is complete, so very long answers can hit it: pass `timeout = 0`, or use `streamText`, which keeps data flowing.

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
- `ai.http_timeout` - HTTP idle timeout in seconds, 0-60 (default 60, 0 = none)

The timeout counts seconds without any data from the server, and CC: Tweaked rejects values above 60. A non-streaming reply sends nothing until it is complete, so very long answers can hit it: pass `timeout = 0`, or use `streamText`, which keeps data flowing.

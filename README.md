# cc-ai

AI toolkit for ComputerCraft: Tweaked - build AI-powered automation in Minecraft.

A port of [oc-ai](https://github.com/DonChong2000/oc-ai) (OpenComputers) to CC: Tweaked.

## Libraries

| Library | Description |
|---------|-------------|
| [ai](docs/ai.md) | Vercel-like Core SDK for text generation, streaming, tool calling, and structured output |
| [cc-code](docs/cc-code.md) | Interactive AI coding agent with file editing, shell access, and TUI |

## Quick Start: cc-code

cc-code is an AI coding assistant that runs directly on a ComputerCraft computer, turtle or pocket computer. It can read, write, and edit files, run shell commands, and help you with coding tasks.

Demos of the original OpenComputers version:

https://github.com/user-attachments/assets/0be2e758-d880-4c70-a6ad-9ee5ac05c513

https://github.com/user-attachments/assets/9fba50a6-4b82-4a2d-be5b-0e4da60d9c71

YouTube: https://youtu.be/u-gIQOXLimQ

---
### Installation

```
wget run https://raw.githubusercontent.com/DonChong2000/cc-ai/main/install.lua
```

This installs everything into `/cc-ai` and adds `/startup/cc-ai.lua`, which puts `cc-code` on the shell path.

### Setup

API keys are stored with CraftOS's `set` program (saved in `/.settings`, so they survive reboots). The Vercel AI Gateway key works with the default model:

```
set AI_GATEWAY_API_KEY <your-key>
```

You can also use a provider directly. For example, you can get a free key from [Google AI Studio](https://aistudio.google.com/api-keys):

```
set GOOGLE_GENERATIVE_AI_API_KEY <your-key>
```

Then, inside cc-code, run `/model google gemini-flash-latest`.

### Run

```
cc-code
```

### Features

- **Interactive TUI** - Color-coded interface with scrolling and command autocomplete
- **Fits any screen** - Computers, turtles (39x13), pocket computers (26x20) and monitors
- **Greyscale mode** - Used automatically on non-advanced computers
- **Multi-provider support** - Anthropic, OpenAI, Google, Groq (direct or via gateway)
- **Built-in tools** - read_file, write_file, edit_file, list_directory, glob, grep, shell
- **Skills system** - Extensible command handlers, including turtle programming help

### Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model` | View or switch AI model |
| `/turtle` | Ask a turtle programming question with API context |
| `/clear` | Clear conversation history |
| `/exit` | Exit cc-code (or hold Ctrl+T at the prompt) |
| `!<cmd>` | Execute shell command directly |

## Quick Start: AI SDK

The AI SDK provides programmatic access to AI models for your own scripts. CraftOS gives each program its own `require`, so first add the cc-ai libraries to `package.path`:

```lua
package.path = "/cc-ai/lib/?.lua;/cc-ai/lib/?/init.lua;" .. package.path
```

### Basic Usage

```lua
local ai = require("ai")
local google = require("ai.google")

local result = ai.generateText({
  model = google("gemini-2.5-flash"),
  prompt = "Hello, world!",
})

print(result.text)
```

### Tool Calling

```lua
local weatherTool = ai.tool({
  name = "get_weather",
  description = "Get current weather",
  parameters = {
    type = "object",
    properties = {
      location = { type = "string" },
    },
    required = { "location" },
  },
  execute = function(args)
    return { temp = 72, condition = "sunny" }
  end,
})

local result = ai.generateText({
  model = google("gemini-2.5-flash"),
  prompt = "What's the weather in Tokyo?",
  tools = { weatherTool },
  maxSteps = 3,
})
```

### Structured Output

```lua
local result = ai.generateObject({
  model = google("gemini-2.5-flash"),
  schema = {
    type = "object",
    properties = {
      name = { type = "string" },
      age = { type = "number" },
    },
  },
  prompt = "Generate a random person.",
})

print(result.object.name, result.object.age)
```

## Installation

### Installer (Recommended)

```
wget run https://raw.githubusercontent.com/DonChong2000/cc-ai/main/install.lua
```

Run it again to update. To install from a fork, a branch or another directory, use `install [owner/repo] [branch] [directory]`.

### Manual

Copy `lib/`, `bin/` and `docs/` to `/cc-ai/` on the computer (for example by dragging them onto the Minecraft window, or with a disk drive). Then add `/cc-ai/bin` to the shell path in a startup file:

```lua
shell.setPath(shell.path() .. ":/cc-ai/bin")
```

## API Keys

| Setting | Provider | Required For |
|---------|----------|--------------|
| `AI_GATEWAY_API_KEY` | Vercel Gateway | `"provider/model"` string format |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google | `google("model")` or `/model google <model>` |
| `OPENAI_API_KEY` | OpenAI | `openai("model")` or `/model openai <model>` |
| `GROQ_API_KEY` | Groq | `groq("model")` or `/model groq <model>` |

Set them with `set <NAME> <key>`. `set ai.http_timeout <seconds>` changes the HTTP timeout (default 120).

## Requirements

- Any ComputerCraft: Tweaked computer, turtle or pocket computer. An advanced one gives you the full-colour TUI
- The HTTP API enabled in the server config (on by default)
- An API key for your chosen provider

## Differences from the OpenComputers version

- **No live streaming.** CC: Tweaked downloads the whole HTTP response before a program can read it. `streamText` still works, but its chunks arrive all at once when the response completes.
- **API keys are settings, not environment variables.** Use `set NAME value` instead of `set NAME=value`. The values persist across reboots.
- **Turtles instead of robots.** The `/robot` skill is now `/turtle`, with a turtle API reference (`docs/turtle.md`) and turtle-specific guidance such as fuel.
- **Ctrl+T instead of Ctrl+C.** Holding Ctrl+T cancels a running request. At an empty prompt it exits cc-code.

## Development

The offline test suite uses a fake HTTP API, so it needs no keys or network. Run it in the [CraftOS-PC](https://www.craftos-pc.cc/) emulator from Windows:

```
.\tests\run.ps1
```

You can also run it in-game with `/cc-ai/tests/run`.

## License

MIT

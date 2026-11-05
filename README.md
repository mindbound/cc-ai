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
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```

This installs cc-code and the AI SDK into `/cc-ai` and adds `/startup/cc-ai.lua`, which puts `cc-code` on the shell path. The tests and examples are left out to save disk space: add `--full` to install them (see Installation below).

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
- **Multi-provider support** - Anthropic, OpenAI, Google, Groq (direct or via gateway), or any OpenAI-compatible endpoint
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
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```

Update later with `/cc-ai/install` (the installer installs itself), or by running the `wget` command again. To install from a fork, a branch or another directory, use `install [--full | --minimal] [owner/repo] [branch] [directory]`.

There are two install sets:

- **Minimal** (the default): `lib/`, `bin/`, `docs/` and the installer, about 350 KB. This is all cc-code and the AI SDK need.
- **Full**: also `tests/` and `examples/`, about 610 KB. The in-game test run (`/cc-ai/tests/run`, `/cc-ai/tests/http-check`) needs it.

Choose with `--full` or `--minimal` anywhere in the arguments, for example `/cc-ai/install --full` or `wget run <url> --full`. The installer records the choice in `/cc-ai/.version`, and an update without an option keeps it. An update to a minimal install deletes `tests/` and `examples/`.

Why minimal is the default: an update downloads the new files next to the old install and replaces it only when every file has arrived, so it needs room for both. A computer's disk holds 1 MB by default (`computer_space_limit` in the server config), which is not enough for two full installs. Before it downloads, the installer checks the free space. If the new files don't fit, it stops, says how many KB it needs and how many are free, and changes nothing: free some space, or use a minimal install. An update from a full to a minimal install deletes `tests/` and `examples/` first, so the download can use their space.

The installer looks up the branch's current commit and downloads every file from that commit, so an update right after a push can't mix old and new files (raw.githubusercontent.com caches branch URLs for about 5 minutes). It writes the commit to `/cc-ai/.version`, and cc-code shows it at startup, for example `Welcome to cc-code v0.2.0 (f3e7a15)`. GitHub's file listing can itself be up to a minute old, so a push may take that long to show up.

Put your own cc-code skills in `/.cc-code/skills/`: updates replace everything in `/cc-ai/lib`. If you put files into `/cc-ai/lib/cc-code/skills/` anyway, the installer keeps them, says so, and renames a file whose name cc-ai starts to use itself (for example to `tools.lua.user`, which does not load).

**Updating an older install (once):** if `/cc-ai/.version` does not exist, `/cc-ai/install` is an older installer. It deletes everything in `/cc-ai/lib`, your skills there too, and within about 5 minutes of a push it can mix old and new files. So:

1. Move your own skills from `/cc-ai/lib/cc-code/skills/` to `/.cc-code/skills/`, for example `mv /cc-ai/lib/cc-code/skills/fuel.lua /.cc-code/skills/fuel.lua`.
2. Wait until the last push is at least 5 minutes old. Then update with the `wget run` command above. It runs the new installer, which makes a minimal install (add `--full` for the tests and examples). Running `/cc-ai/install` twice also works, but the first run, by the older installer, downloads everything (about 610 KB) next to the old install, which may not fit on a 1 MB disk. The second run, by the new installer, makes the install minimal, because the older installer recorded no choice.

### Manual

Copy `lib/`, `bin/` and `docs/` to `/cc-ai/` on the computer (for example by dragging them onto the Minecraft window, or with a disk drive). Then add `/cc-ai/bin` to the shell path in a startup file:

```lua
shell.setPath(shell.path() .. ":/cc-ai/bin")
```

If you used the installer before, delete `/cc-ai/.version` (`rm /cc-ai/.version`). Otherwise cc-code still shows the commit the installer put there, not the version you copied.

## API Keys

| Setting | Provider | Required For |
|---------|----------|--------------|
| `AI_GATEWAY_API_KEY` | Vercel Gateway | `"provider/model"` string format |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google | `google("model")` or `/model google <model>` |
| `OPENAI_API_KEY` | OpenAI | `openai("model")` or `/model openai <model>` |
| `GROQ_API_KEY` | Groq | `groq("model")` or `/model groq <model>` |
| `AI_CUSTOM_BASE_URL` | Custom (OpenAI-compatible) | `custom("model")` or `/model custom <model>`, e.g. `https://nano-gpt.com/api/v1` |
| `AI_CUSTOM_API_KEY` | Custom (OpenAI-compatible) | Optional: keyless local servers work without it |

Set them with `set <NAME> <key>`.

HTTP requests made with the SDK fail if the server sends nothing for 60 seconds, the longest timeout CC: Tweaked allows. Change it with `set ai.http_timeout <0-60>` (`0` = no timeout), or per call with the `timeout` option. cc-code itself uses no timeout, because long answers can take more than a minute; hold Ctrl+T to cancel.

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

You can also run it in-game with `/cc-ai/tests/run`. The tests are only in a full install: run `/cc-ai/install --full` first.

`tests/live.ps1 -Provider <gateway|google|openai|groq|custom> -Model <model>` runs live checks against a real API (text, streaming, tools, structured output and a full agent task). Keys are read from the emulator data directory's settings, which you set yourself in the emulator: see the top of `tests/live.ps1`.

`/cc-ai/tests/http-check [model]` checks in-game whether the custom endpoint's replies arrive complete, with and without streaming. It also needs a full install.

## License

MIT

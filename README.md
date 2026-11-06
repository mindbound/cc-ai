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

### Trying the Basalt UI

cc-code's interface is being rebuilt on [Basalt](https://github.com/mindbound/Basalt2) (a fork of Pyroxenium's Basalt 2.5) as a trial. The hand-written TUI stays the default. To try the new UI once:

```
cc-code --basalt
```

To use it every time, run `set cc-code.ui basalt`. Then `cc-code --tui` starts the TUI for one run, and `set cc-code.ui tui` goes back to the TUI. In the Basalt UI you can type your next prompt while the model works. Enter queues it, and cc-code sends it when the turn ends, also when the turn ended with an error. If you stop the turn with Ctrl+T, nothing more is sent, and the oldest queued prompt goes back into the input line if the line is empty. A queued `/exit` ends the session when its turn comes: the prompts queued before it are still sent, and the prompts queued after it are not.

The installer does not install Basalt, and a minimal install (the default) does not contain the Basalt UI's own code either. The first time the Basalt UI starts, cc-code downloads what is missing: Basalt (`vendor/basalt.lua`, 143 KB, with Basalt's MIT notice) into `/cc-ai/vendor/`, and the Basalt UI's code (`app.lua`, `ui.lua` and `log.lua`, about 58 KB) into `/cc-ai/lib/cc-code/basalt/`. It downloads them from the cc-ai commit named in `/cc-ai/.version`, so they match the installed cc-code (if the installer could not look up the commit, from the head of its branch, which may be newer). After that, cc-code uses the downloaded files and does not download them again. An update deletes the Basalt UI's code with the rest of `/cc-ai/lib`, and the next start of the Basalt UI downloads it from the new commit. Updates leave `/cc-ai/vendor` in place, unless the new files would not fit on the disk with it: then the update deletes it and says so, and the Basalt UI downloads it again the next time it starts. If an update needs a different Basalt build, the next start of the Basalt UI downloads it again. If a download fails (the HTTP API is disabled, the network fails, or the disk is too full), Basalt does not load, or the Basalt UI fails to start, cc-code shows the reason and starts the TUI. To remove Basalt, delete `/cc-ai/vendor`.

The Basalt UI needs the same screen size as the TUI (at least 20x8). `cc-code -t` still starts the line-based terminal mode. [docs/cc-code.md](docs/cc-code.md#basalt-ui-trial) describes how the Basalt UI differs from the TUI.

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

- **Minimal** (the default): `lib/`, `bin/`, `docs/` and the installer, about 380 KB. It leaves out the code of the Basalt UI (a trial, see above). This is all cc-code and the AI SDK need.
- **Full**: also `tests/`, `examples/` and the Basalt UI's code, about 815 KB. The in-game test run (`/cc-ai/tests/run`, `/cc-ai/tests/http-check`) needs it.

Neither set contains `vendor/`, the library of the Basalt UI. The first time you use the Basalt UI, cc-code downloads it (143 KB in `/cc-ai/vendor`), and in a minimal install also the Basalt UI's code (about 58 KB in `/cc-ai/lib/cc-code/basalt`). An update deletes that code with `/cc-ai/lib`, and deletes `/cc-ai/vendor` only when it needs the room. The Basalt UI then downloads them again.

Choose with `--full` or `--minimal` anywhere in the arguments, for example `/cc-ai/install --full` or `wget run <url> --full`. The installer records the choice in `/cc-ai/.version`, and an update without an option keeps it. An update to a minimal install deletes `tests/` and `examples/`.

Why minimal is the default: an update downloads the new files next to the old install and replaces it only when every file has arrived, so it needs room for both. A computer's disk holds 1 MB by default (`computer_space_limit` in the server config), which is not enough for two full installs. An update of a minimal install needs about 760 KB for the old and the new files together, which leaves about 240 KB of the default disk for your own files (about 200 KB less while the Basalt UI's downloads are there). Before it downloads, the installer checks the free space. An update from a full to a minimal install deletes `tests/` and `examples/` first, so the download can use their space. If the new files fit only without the Basalt UI's download, the installer also deletes `/cc-ai/vendor` first and prints `Deleted /cc-ai/vendor/basalt.lua to make room; the Basalt UI downloads it again.` (On the default 1 MB disk, a minimal install with the Basalt UI's downloads and the new files of its update together take nearly all of it.) If the new files don't fit even then, the installer stops, says how many KB it needs and how many are free, and changes nothing: free some space, or use a minimal install.

The installer looks up the branch's current commit and downloads every file from that commit, so an update right after a push can't mix old and new files (raw.githubusercontent.com caches branch URLs for about 5 minutes). It writes the commit to `/cc-ai/.version`, and cc-code shows it at startup, for example `Welcome to cc-code v0.2.0 (f3e7a15)`. GitHub's file listing can itself be up to a minute old, so a push may take that long to show up.

Put your own cc-code skills in `/.cc-code/skills/`: updates replace everything in `/cc-ai/lib`. If you put files into `/cc-ai/lib/cc-code/skills/` anyway, the installer keeps them, says so, and renames a file whose name cc-ai starts to use itself (for example to `tools.lua.user`, which does not load).

**Updating an older install (once):** if `/cc-ai/.version` does not exist, `/cc-ai/install` is an older installer. It deletes everything in `/cc-ai/lib`, your skills there too, and within about 5 minutes of a push it can mix old and new files. So:

1. Move your own skills from `/cc-ai/lib/cc-code/skills/` to `/.cc-code/skills/`, for example `mv /cc-ai/lib/cc-code/skills/fuel.lua /.cc-code/skills/fuel.lua`.
2. Wait until the last push is at least 5 minutes old. Then update with the `wget run` command above. It runs the new installer, which makes a minimal install (add `--full` for the tests and examples). Running `/cc-ai/install` twice also works, but the first run, by the older installer, downloads everything (about 815 KB) next to the old install, which may not fit on a 1 MB disk. The second run, by the new installer, makes the install minimal, because the older installer recorded no choice.

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

You can also run it in-game with `/cc-ai/tests/run`. The tests are only in a full install: run `/cc-ai/install --full` first. The Basalt UI's tests that need `vendor/basalt.lua` are reported as skipped until cc-code has downloaded it: run `cc-code --basalt` once.

`vendor/basalt.lua` is a bundle of the Basalt fork with only the elements the Basalt UI uses. CLAUDE.md says how to rebuild it. After a rebuild, set `COMMIT`, `ELEMENTS` and `MODULES` in `lib/cc-code/basalt/load.lua` to the `-- Commit:`, `-- Elements:` and `-- Modules:` lines of the new bundle's header. cc-code accepts a bundle only when all three match, so a rebuild of the same commit with other elements is downloaded again. The tests check that the constants match the bundle.

`tests/live.ps1 -Provider <gateway|google|openai|groq|custom> -Model <model>` runs live checks against a real API (text, streaming, tools, structured output and a full agent task). Keys are read from the emulator data directory's settings, which you set yourself in the emulator: see the top of `tests/live.ps1`.

`/cc-ai/tests/http-check [model]` checks in-game whether the custom endpoint's replies arrive complete, with and without streaming. It also needs a full install.

## License

MIT

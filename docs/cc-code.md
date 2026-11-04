# cc-code v0.2.0

Interactive AI coding agent for ComputerCraft: Tweaked.

## Installation

```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/main/install.lua
```

## Usage

### Command Line

```
cc-code [options]
  -m, --model <model>   Set AI model (default: anthropic/claude-sonnet-4)
  -t, --terminal        Force terminal mode (line-based, no TUI)
  -c, --monochrome      Use monochrome colors (automatic on non-advanced computers)
  -h, --help            Show help
```

### Programmatic

```lua
package.path = "/cc-ai/lib/?.lua;/cc-ai/lib/?/init.lua;" .. package.path
local occode = require("cc-code")

-- Interactive mode
occode.run()

-- One-shot execution
local response = occode.exec("List the files in /")
print(response)

-- Chat mode
local text = occode.chat("What is 2+2?")
print(text)
```

## Commands

| Command | Description |
|---------|-------------|
| `/help`, `/?` | Show available commands |
| `/model` | View current model |
| `/model <provider/model>` | Switch to gateway model |
| `/model google <model>` | Use Google directly |
| `/model openai <model>` | Use OpenAI directly |
| `/model groq <model>` | Use Groq directly |
| `/model custom <model>` | Use the OpenAI-compatible endpoint in `AI_CUSTOM_BASE_URL` |
| `/turtle <prompt>` | Ask a turtle programming question with the quick API reference |
| `/turtle full <prompt>` | Same, with the full API reference (`docs/turtle.md`) |
| `/clear` | Clear conversation history |
| `/exit`, `/quit` | Exit cc-code |
| `!<command>` | Execute shell command directly |

Holding Ctrl+T cancels a request that is in progress. At an empty prompt, it exits cc-code.

## Tools

The agent has access to these tools:

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents with line numbers |
| `write_file` | Create or overwrite a file |
| `edit_file` | Replace exact string in file |
| `list_directory` | List files and directories |
| `glob` | Find files by pattern (e.g., `*.lua`, `**/*.lua`) |
| `grep` | Search file contents (Lua patterns or literal text) |
| `shell` | Run a CraftOS shell command and capture its output |

When `glob` or `grep` scan from the root directory, they skip `/rom`.

### How shell output is captured

CraftOS has no output redirection, so `shell` and `!<command>` run the command with the terminal redirected to an invisible recording terminal, and return what it printed. While the command runs, it can't be seen. A program that waits for keyboard input blocks cc-code until it exits, so hold Ctrl+T to stop it. `cd` persists, as it would at the shell prompt.

## Display Modes

### TUI Mode (Default)

Works on every computer, turtle, pocket computer and monitor. Features:
- Color-coded output (user, assistant, tools, errors), using the original theme colours on advanced computers
- Greyscale scheme on non-advanced computers
- Header bar with hints
- Status bar showing current operation
- Scrolling with PageUp/PageDown, Ctrl+Up/Down and the mouse wheel
- Command autocomplete popup (Tab)
- Command history (Up/Down)

### Terminal Mode

Forced with `-t`, and used automatically on screens too small for the TUI. Features:
- Simple line-by-line output
- CraftOS's own line editor, with history and Tab completion of commands

## Configuration

### API keys

API keys are stored as settings with the `set` program. They're saved in `/.settings`, so they persist across reboots.

| Setting | Description |
|----------|-------------|
| `AI_GATEWAY_API_KEY` | For gateway models (`provider/model` format) |
| `GOOGLE_GENERATIVE_AI_API_KEY` | For Google direct (`/model google <model>`) |
| `OPENAI_API_KEY` | For OpenAI direct (`/model openai <model>`) |
| `GROQ_API_KEY` | For Groq direct (`/model groq <model>`) |
| `AI_CUSTOM_BASE_URL` | Endpoint for `/model custom <model>`, e.g. `https://nano-gpt.com/api/v1` |
| `AI_CUSTOM_API_KEY` | Key for the custom endpoint (optional) |
| `ai.http_timeout` | HTTP idle timeout for SDK scripts, 0-60 (default 60). cc-code itself uses none |

### Project instructions (.cc-code.md / CLAUDE.md)

cc-code adds project-specific instructions from the current directory to the system prompt. It prefers `.cc-code.md`, which is written for the in-game agent and can be up to 4000 chars. If that file is absent, it falls back to `CLAUDE.md`, up to 2000 chars. Long files are truncated with a `[truncated]` marker.

### Skills

Skills are extensible command handlers. Built-in skills:
- `help` - `/help` command
- `model` - `/model` command
- `turtle` - `/turtle` command. On a turtle it also adds turtle guidance (fuel, dead reckoning, safe movement) to every request

Custom skills can be placed in:
- `/cc-ai/lib/cc-code/skills/` - System-wide (next to the built-in ones)
- `.cc-code/skills/` - Project-local (relative to the current directory)

A skill file returns `require("cc-code.skills").create({ name = ..., commands = { "/x" }, onActivate = function(agent, args) ... end })`.

## Available Models

### Gateway (via Vercel AI Gateway)

```
anthropic/claude-sonnet-4
anthropic/claude-opus-4
openai/gpt-4o
openai/gpt-4o-mini
google/gemini-2.5-flash
google/gemini-2.5-pro
```

### Direct Providers

Google:
```
/model google gemini-flash-latest
/model google gemini-2.5-flash
/model google gemini-2.5-pro
```

OpenAI:
```
/model openai gpt-4o
/model openai gpt-4o-mini
/model openai gpt-5-mini
```

Groq:
```
/model groq llama-3.3-70b-versatile
/model groq openai/gpt-oss-120b
```

Custom endpoint (after `set AI_CUSTOM_BASE_URL https://nano-gpt.com/api/v1`):
```
/model custom deepseek/deepseek-v4.1-flash:thinking
```

## API Reference

### occode.run(config)

Run interactive session.

```lua
occode.run({
  model = "openai/gpt-4o",
  forceTerminal = false,
})
```

### occode.exec(prompt, config)

Execute a one-shot prompt with tool access.

```lua
local response = occode.exec("Create a hello.lua file", {
  maxSteps = 5,
})
```

### occode.chat(prompt, config)

Send a single message and get a response.

```lua
local text, result = occode.chat("Explain this code", {
  model = "google/gemini-2.5-flash",
})
```

## Examples

### Interactive Session

```
> Create a simple calculator function

>> write_file
   {"path":"calculator.lua","content":"..."}
<< {"success":true,"bytesWritten":245}

Created calculator.lua with add, subtract, multiply, and divide functions.

> Add a power function to it

>> read_file
   {"path":"calculator.lua"}
<< {"content":"..."}

>> edit_file
   {"path":"calculator.lua","old_string":"return calc","new_string":"function calc.power(a, b)\n  return a ^ b\nend\n\nreturn calc"}
<< {"success":true}

Added the power function to calculator.lua.
```

### Shell Commands

```
> !ls
cc-ai     rom       startup
calculator.lua

> !id
This is computer #0
```

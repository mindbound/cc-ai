# cc-code v0.2.0

Interactive AI coding agent for ComputerCraft: Tweaked.

## Installation

```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```

## Usage

### Command Line

```
cc-code [options]
  -m, --model <model>   AI model for this run: <provider>:<model> (google,
                        openai, groq, custom) or a gateway model such as
                        openai/gpt-4o. Default: the model /model saved
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
| `/model <provider>` | Show how to pick a model for a provider, and its saved model |
| `/model google <model>` | Use Google directly |
| `/model openai <model>` | Use OpenAI directly |
| `/model groq <model>` | Use Groq directly |
| `/model custom <model>` | Use the OpenAI-compatible endpoint in `AI_CUSTOM_BASE_URL` (also `/model custom:<model>`) |
| `/turtle <prompt>` | Ask a turtle programming question with the quick API reference |
| `/turtle full <prompt>` | Same, with the full API reference (`docs/turtle.md`) |
| `/clear` | Clear conversation history |
| `/exit`, `/quit` | Exit cc-code |
| `!<command>` | Execute shell command directly |

`/model` saves the model it switches to in the `cc-code.model` setting, so the next start uses it. `cc-code -m <model>` overrides it for one run.

While the model works, the status bar shows how long it has been thinking and the tool step, for example `Thinking 1:12 - step 2/25 - Ctrl+T cancels`. You can scroll back meanwhile; new output then leaves your view where it is (Ctrl+End jumps to the bottom).

Holding Ctrl+T cancels a request that is in progress. Tool steps that already finished stay in the conversation (their file changes are on disk anyway), so you can say "continue". At an empty prompt, Ctrl+T exits cc-code.

A turn ends early, with a note, when:
- it reaches the step limit (`cc-code.max_steps`, default 25 model requests per prompt): type `continue` to go on;
- the reply is cut off at the output token limit;
- the model sends an empty reply.

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

CraftOS has no output redirection, so `shell` and `!<command>` run the command with the terminal redirected to an invisible recording terminal, and return what it printed. While the command runs, it can't be seen. `cd` persists, as it would at the shell prompt.

For the `shell` tool:
- The recording terminal is 160 columns wide, so long lines aren't wrapped.
- The model gets the start (1000 bytes) and the end (3000 bytes) of long output, because errors and summaries are printed last.
- A program still running after its `timeout` (20 seconds by default, at most 300; the model can set it per call) is stopped, as Ctrl+T would stop it, and the output so far is returned. That is normal for programs that loop forever, such as monitor dashboards or farm controllers. A program that has not ended 10 seconds after the stop (it ignores terminate, or its cleanup takes too long) is abandoned: it never runs again. If it had set `os.pullEvent = os.pullEventRaw`, as terminate-proof programs do, that is put back.
- On advanced computers the model is told to leave long-running programs running with `bg <program>`, which opens them in their own multishell tab.

Holding Ctrl+T while a command runs stops it: the program gets the terminate and can clean up. A second Ctrl+T abandons a program that is still running. During the `shell` tool, Ctrl+T also ends the turn, but the output so far is still reported to the model.

An abandoned program never pops the shell's record of the running program, so for the rest of that shell's session `shell.getRunningProgram()` and the multishell tab title may name the wrong program. Nothing else is affected.

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

### cc-code settings

| Setting | Description |
|----------|-------------|
| `cc-code.model` | Model used at startup, e.g. `custom:deepseek/deepseek-v4.1-flash:thinking` or `openai/gpt-4o` (gateway). `/model` sets it |
| `cc-code.max_steps` | Most model requests (tool steps) per prompt (default 25) |
| `cc-code.max_output_tokens` | Output token cap per reply. Default: none for the custom provider (thinking models count their reasoning against it), 4096 for the others |

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

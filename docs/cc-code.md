# cc-code v0.2.0

Interactive AI coding agent for ComputerCraft: Tweaked.

## Installation

```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```

This makes a minimal install (`lib/`, `bin/`, `docs/`; about 350 KB), so that an update, which downloads the new files next to the old ones, fits on the default 1 MB computer disk. Add `--full` for the tests and examples too. The README has the details.

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
| `/turtle [prompt]` | Add the turtle API quick reference to the conversation, then ask the prompt if one is given |
| `/turtle full [prompt]` | Same, with the full API reference (`docs/turtle.md`) |
| `/tools short\|full\|off` | How tool calls are shown: one line each (default), the arguments and result as JSON, or not at all. Saved in `cc-code.tools`. `/tools` alone shows the mode in use (a setting changed with `!set` applies from the next start) |
| `/clear` | Clear conversation history (and the `/turtle` reference) |
| `/exit`, `/quit` | Exit cc-code |
| `!<command>` | Execute shell command directly |

`/model` saves the model it switches to in the `cc-code.model` setting, so the next start uses it. `cc-code -m <model>` overrides it for one run.

`/turtle` puts the reference into the system prompt for the rest of the conversation, instead of into one message: later questions see it too, and `/clear` removes it.

An unknown command is not sent to the model as a question: a single word such as `/hepl`, or `/` alone, gives an error with the closest commands (`did you mean /help?`). For a CraftOS program it says how to run it (`/ls`: type `!ls`). Longer input goes to the model unless its first word starts a command or is at most two letters away from one, so `/farm should harvest wheat` and `/startup is broken` are questions, while `/modle openai/gpt-4o` is caught as a typo.

Tool calls show as one line each, completed when the result comes in:

```
* read startup.lua - 42 lines
* edit startup.lua - 1 replacement
! $ startup - failed: startup.lua:12: attempt to call nil
```

A failed call starts with `!` and is shown in the error colour; a call stopped with Ctrl+T ends with `stopped (Ctrl+T)`, and a tool that returns nothing with `done`. On a narrow screen the call is shortened first, so the start of the outcome stays visible. With `/tools full` each call shows its arguments and result as JSON instead.

While the model works, the status bar shows how long it has been thinking and the tool step, for example `Thinking 1:12 - step 2/25 - Ctrl+T cancels`. You can scroll back meanwhile; new output then leaves your view where it is (Ctrl+End jumps to the bottom).

Holding Ctrl+T cancels a request that is in progress. Tool steps that already finished stay in the conversation (their file changes are on disk anyway), so you can say "continue". At an empty prompt, Ctrl+T exits cc-code.

A turn ends early, with a note, when:
- it reaches the step limit (`cc-code.max_steps`, default 25 model requests per prompt): type `continue` to go on;
- the reply is cut off at the output token limit;
- the server ends the reply early (the event stream stops without its end marker);
- the model sends an empty reply.

A custom endpoint that answers with something other than an event stream gives an error instead of an empty reply: plain JSON is still read (some servers ignore `stream`), an error object raises its message, and anything else (often an HTML page from a wrong `AI_CUSTOM_BASE_URL`) is reported with its first bytes. Errors sent inside a stream (an `error:` line or an error event) are shown with their message, and a stream that the server closes after only keep-alive messages says so.

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

Globs (the `glob` tool and grep's `glob` option) know `*` (within a folder), `**` (any depth), `?` (one character), `{a,b}` alternatives, and a leading `./` or `/` (the search folder) or trailing `/` (everything under a folder). grep's `glob` matches paths when it contains a `/` (`lib/**/*.lua`) and file names at any depth when not (`*.lua`); when a non-empty glob matched no file at all, grep says so, so an empty result is not mistaken for "not found".

`edit_file` matches against the text as `read_file` shows it, with every line ending as a plain newline. So it works on files with Windows (CRLF) or mixed line endings, and text that appears twice there is reported as found twice. The new text gets the line ending of the text it replaces (or the file's most common one). `write_file` and `edit_file` check the free disk space first: CC: Tweaked empties a file when it is opened for writing, so a write that did not fit would otherwise leave it empty. A read-only file is reported as read-only.

### Secrets

The values of settings whose names end in `KEY` or contain `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` (8 characters or longer, numbers included) are replaced with `<redacted>` in tool results and error messages, so the model doesn't see your API keys even if it runs `set` or reads `/.settings`. They are found whole, in the escaped forms `set`, `/.settings` and JSON write them, split over lines by wrapping, and as a long enough start or end cut off at a line edge. Shell output is blanked before it is shortened. In the system prompt, only what comes from your files is checked (file names, project instructions, the custom prompt and skill prompts); cc-code's own text never is.

The model is told what `<redacted>` means and not to write it anywhere. `write_file` and `edit_file` refuse to write it into a file (unless the file already contains that text), and the `shell` tool refuses a command that contains it (so `set door.password <redacted>` can't store the marker in place of the password). Commands you type with `!` are not checked.

Limits: what you type yourself is sent as typed. A password that is an ordinary word (such as `redstone`) is blanked wherever that word appears in tool results, so code like `redstone.setOutput` reaches the model as `<redacted>.setOutput`: don't use plain words as passwords. For a value that a program clips at the edge of the screen, the part that shows is blanked only when the value is at least 16 characters long and at least 12 of them show; a shorter clipped value can leak in part.

### How shell output is captured

CraftOS has no output redirection, so `shell` and `!<command>` run the command with the terminal redirected to an invisible recording terminal, and return what it printed. While the command runs, it can't be seen. `cd` persists, as it would at the shell prompt.

For the `shell` tool:
- The recording terminal is 160 columns wide, so long lines aren't wrapped.
- The model gets the start (1000 bytes) and the end (3000 bytes) of long output, because errors and summaries are printed last.
- A program still running after its `timeout` (20 seconds by default, at most 300; the model can set it per call) is stopped, as Ctrl+T would stop it, and the output so far is returned. That is normal for programs that loop forever, such as monitor dashboards or farm controllers. Programs that wait for a key or typed text (menus, games, `read()`, "Press any key" paging) never get any input: the model can't type, and keys and clicks you make meanwhile are not passed on. (Input events a program queues for itself with `os.queueEvent`, the usual way to test a menu without a person, do reach it.) So they also run until the timeout. When the program was waiting for a key, a character, a mouse event or `read()` at that moment, the result says it was waiting for input; a menu that reads every event itself (`os.pullEvent()` with no filter, or a key wait inside `parallel`) is reported like a program that loops forever. A program that has not ended 10 seconds after the stop (it ignores terminate, or its cleanup takes too long) is abandoned: it never runs again. If it had set `os.pullEvent = os.pullEventRaw`, as terminate-proof programs do, that is put back.
- On advanced computers the model is told to leave long-running programs running with `bg <program>`, which opens them in their own multishell tab.
- With `screen: true`, the program runs on an invisible terminal the size of the real screen, and the model gets the final screen instead of the printed output: its text, plus the background and text colours as `term.blit` rows when they are not the defaults, and the palette slots the program changed (as `#rrggbb`). The screen is taken when the program ends, or just before the timeout stops it (so a dashboard that clears the screen on exit is still seen). The model is told to use it for full-screen programs: dashboards, games, plots and menus. On vanilla CC the text shows what the cells show (a UTF-8 character the program printed appears as the two Latin-1 characters CC draws for it). Only the computer's own terminal is captured, not monitors or `term.native()`, and a blank screen says so.

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
| `cc-code.tools` | How tool calls are shown: `short` (default), `full` or `off`. `/tools` sets it |

### System prompt

The system prompt describes the computer: its type, screen size and colours, the current directory and its files. It also adapts to two things:
- **Screen size.** On screens of at least 80x30 (computers can be made bigger in the server's CC: Tweaked config) answers may run to about 20 lines; on smaller ones they stay short.
- **The "CC: Tweaked Unicode Support" mod.** With the mod, the model learns that UTF-8 displays and that `#` and `string.len` count characters while `string.sub`/`find`/`byte` use byte positions. Without it, the model is told the screen shows only ASCII and Latin-1, and to write Latin-1 characters in Lua strings as escapes such as `"\176"`.

The prompt is sent as valid UTF-8 even when file names or project instructions contain CC charset bytes.

### Project instructions (.cc-code.md / CLAUDE.md)

cc-code adds project-specific instructions from the current directory to the system prompt. It prefers `.cc-code.md`, which is written for the in-game agent and can be up to 4000 bytes. If that file is absent, it falls back to `CLAUDE.md`, up to 2000 bytes. Long files are truncated with a `[truncated]` marker (never inside a character).

### Skills

Skills are extensible command handlers. Built-in skills:
- `help` - `/help` command
- `model` - `/model` command
- `turtle` - `/turtle` command. On a turtle it also adds turtle guidance (fuel, dead reckoning, safe movement) to every request

Your own skills go in:
- `/.cc-code/skills/` - for every directory. Updates never touch this folder
- `.cc-code/skills/` - for one project (relative to the current directory)

Skills load in this order: built-in, then `/.cc-code/skills`, then the project's `.cc-code/skills`, and within a folder by file name. A later skill with the same name replaces an earlier one. When skills with different names claim the same command, the one loaded last gets it, and startup says so (`Skill X (<path>) takes /cmd over from skill Y`).

Don't put skills into `/cc-ai/lib/cc-code/skills/`: updates replace `/cc-ai/lib`. The installer records what it put there (in `/cc-ai/.version`) and keeps anything else it finds, saying so; a kept file whose name cc-ai now uses is renamed to `<name>.user`, which does not load. Move such files to `/.cc-code/skills`.

**Updating from a version before this one:** the installer you run (`/cc-ai/install`) is still the old one, which deletes everything in `/cc-ai/lib`. If `/cc-ai/.version` does not exist, first move your skills from `/cc-ai/lib/cc-code/skills` to `/.cc-code/skills`, then update with the `wget run` command at least 5 minutes after the last push. (Running `/cc-ai/install` twice also works, but its first run, by the older installer, downloads everything next to the old install, which may not fit on a 1 MB disk.)

Startup lists every skill problem: a skill that failed to load (a syntax error, an error while it runs, a file that returns something else, or a tool list that would break requests) as `Skill not loaded: <file>: <problem>`, a skill tool that is not offered because its name is already taken, and a skill command that is a built-in command (`/clear`, `/exit`, `/quit`, `/tools`), which a skill can never take over. A skill whose command fails reports the error, and Ctrl+T cancels a slow one; cc-code keeps running. A skill whose `systemPrompt` function fails is left out of the prompt, with one warning after the reply.

#### Writing a skill

A skill file returns a skill made with `skills.create`:

```lua
-- /.cc-code/skills/fuel.lua
local skills = require("cc-code.skills")
local ai = require("ai")

return skills.create({
  name = "fuel",
  description = "Fuel level and refuelling",
  commands = { "/fuel" },

  -- /fuel [question]. Return a prompt to send to the model, or
  -- nil plus text to show without asking the model.
  onActivate = function(agent, args)
    if args == "" then
      return nil, "Fuel: " .. tostring(turtle and turtle.getFuelLevel() or "not a turtle")
    end
    return "About fuel: " .. args
  end,

  -- Extra tools for the model (made with ai.tool)
  tools = {
    ai.tool({
      name = "fuel_level",
      description = "The turtle's fuel level",
      parameters = { type = "object", properties = {} },
      execute = function()
        return { fuel = turtle and turtle.getFuelLevel() or "not a turtle" }
      end,
    }),
  },

  -- Added to the system prompt: a string, or a function(agent) that
  -- returns one (or nil), called for every request
  systemPrompt = "Refuel with coal from slot 16 when the fuel is below 100.",
})
```

A tool's result must be something JSON can hold: a table with string keys, or a list without gaps, made of strings, numbers, booleans and such tables (no NaN, functions or peripherals). `inventory.list()` as it is has gaps between slots, so turn it into a list first. Otherwise the model gets an error saying so, and the call is shown as failed. Keys are converted to UTF-8 and secret values blanked like the values.

Rules for `tools`: it is a list, also for one tool (`tools = { ai.tool({ ... }) }`); a tool name is 1 to 64 letters, digits, `_` or `-`; `parameters`, if given, is a JSON schema table, and a tool without arguments may leave it out (an empty `properties` is fine too); a tool whose name a built-in tool or an earlier skill's tool already has is not offered.

Skills are loaded when cc-code starts, so restart it after changing one.

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
* write calculator.lua - 245 bytes
Created calculator.lua with add, subtract, multiply, and divide functions.

> Add a power function to it
* read calculator.lua - 14 lines
* edit calculator.lua - 1 replacement
Added the power function to calculator.lua.
```

With `/tools full`, each call shows its arguments and result as JSON instead.

### Shell Commands

```
> !ls
cc-ai     rom       startup
calculator.lua

> !id
This is computer #0
```

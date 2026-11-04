# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment

This is a ComputerCraft: Tweaked (CC:T) Lua library for Minecraft 1.21.1, not a typical software project. Code runs inside CraftOS on the Cobalt VM (Lua 5.2 with a few 5.3 stdlib additions such as `utf8`). CC APIs are globals (`fs`, `term`, `http`, `settings`, `shell`, `turtle`, ...), not `require`d modules. It's a port of the OpenComputers project oc-ai; the first commit in git history is the untouched OC version.

## Installation

In-game:
```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```
`install.lua` lists the repo through the GitHub trees API, downloads `lib/ bin/ docs/ examples/ tests/` into `/cc-ai`, and writes `/startup/cc-ai.lua`, which adds `/cc-ai/bin` to the shell path. The repo layout is the installed layout.

## Running Code

From the CraftOS shell, run programs by path. There's no `lua <file>`:
```
cc-code
/cc-ai/examples/generateText
```

Each CraftOS program gets its own `require`, which resolves relative paths against the program's own directory. Entry points therefore prepend the lib dir to `package.path`, for example `"../lib/?.lua;../lib/?/init.lua;"` in `bin/` and `examples/`, or an absolute `/cc-ai/lib/...` path in user programs. Modules loaded by `require` share the program's environment, so they see `shell` and any overridden globals. `dofile` runs in `_G`, which has no `require`, so use `loadfile(path, "t", _ENV)` instead.

API keys are settings, not env vars: `set GOOGLE_GENERATIVE_AI_API_KEY <key>`. Read them through `ai.utils.getEnv(name)`.

## Testing

Offline suite with a fake `http` (no keys or network needed), run in the CraftOS-PC emulator:
```
.\tests\run.ps1                 # all suites
.\tests\run.ps1 -Suite test_ai  # one suite
```
The runner mounts the repo read-only at `/cc-ai` in a headless emulator, runs `tests/run.lua`, and prints the results file. Headless stdout is a garbled screen dump, so tests write results to a file. Suites are `tests/test_*.lua`, each a `function(T)` using `T.test/T.eq/T.contains/T.raises` and `T.http` (mock: `push` responses for POST, `routes` for GET). In-game: `/cc-ai/tests/run [suite]`.

Live checks against a real API: `.\tests\live.ps1 -Provider custom -Model <model>` (`tests/live.lua`). They use the emulator data dir `C:\cc-ai-live`, where the user sets keys themselves. Never read or print its `.settings` file.

## Architecture

**lib/ai/init.lua** - Main AI SDK: `ai.generateText()`, `ai.streamText()`, `ai.generateObject()`, `ai.tool()`
- Vercel AI Gateway (string models) and direct providers (model objects)
- Tool calling with automatic execution loop (`maxSteps`)
- Structured output via `ai.Output.object()`

**lib/ai/utils/init.lua** - `httpPost`, `httpPostStream` (line iterator over the buffered body: CC:T has no live HTTP streaming), `parseSSELine`, `getEnv` (settings), `defineSetting`. Non-2xx responses raise with the API's error message.

**lib/ai/google.lua**, **openai.lua**, **groq.lua**, **vercel.lua**, **custom.lua** - providers. All but Google are built on **openai-compat.lua**. `custom` reads its endpoint from the `AI_CUSTOM_BASE_URL` setting at request time, and its key (`AI_CUSTOM_API_KEY`) is optional. It sends `generateText` through streamed replies (`streamResponses`): NanoGPT's non-streamed replies were cut short in-game when they contained non-ASCII text (a character-count `Content-Length`; CraftOS-PC gets chunked replies and can't reproduce it). `tests/http-check.lua` checks this in-game.

**lib/cmn-utils/** - `json` (rxi/json.lua), `glob`, `grep`, `path` (resolve against `shell.dir()`, yield helper), `text` (UTF-8 to CC charset for display, `fromCC` for user input going to APIs).

**lib/cc-code/** - the agent:
- `agent.lua` - system prompt, slash commands, `!cmd`, tool-call loop with history
- `tools.lua` - read_file, write_file, edit_file, list_directory, glob, grep, shell
- `capture.lua` - runs shell commands under `term.redirect` to a recording terminal, because CraftOS has no `>` redirection
- `tui.lua` - full-screen UI (window-buffered, palette remapped to the theme). `terminal.lua` - line mode using `read()`
- `skills/` - help, model, turtle. Loaded by `skills.loadFromDirectory` from the module's own directory

**bin/cc-code.lua** - entry program (option parsing). **install.lua** - installer.

## Code Style

- 2-space indentation
- Double quotes for strings
- Local variables and functions (avoid globals)
- Modules return tables of public functions
- Use `type()` checks for public API arguments
- Wrap JSON decode with `pcall`
- Use `error("message")` for failures (`error(msg, 0)` for user-facing messages without a position)

## Constraints

- Lua 5.2 (Cobalt): no `//`, no bitwise operators (use `bit32`), no `string.pack`. `goto` and `utf8` work
- Programs must yield at least every ~7s ("Too long without yielding"). Long scans call `cmn-utils.path.maybeYield()`
- Compare key events against `keys.*` names only: MC 1.21 uses GLFW key codes, while CraftOS-PC uses LWJGL2 codes
- Terminal is one byte per glyph (ISO-8859-1 plus CC drawing chars), not UTF-8. Pass displayed model text through `cmn-utils.text.toCC`
- Screens are small: 51x19 computer, 39x13 turtle, 26x20 pocket
- Read and write files in binary mode (`"rb"` / `"wb"`) to keep bytes intact

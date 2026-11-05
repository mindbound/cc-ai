# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment

This is a ComputerCraft: Tweaked (CC:T) Lua library for Minecraft 1.21.1, not a typical software project. Code runs inside CraftOS on the Cobalt VM (Lua 5.2 with a few 5.3 stdlib additions such as `utf8`). CC APIs are globals (`fs`, `term`, `http`, `settings`, `shell`, `turtle`, ...), not `require`d modules. It's a port of the OpenComputers project oc-ai; the first commit in git history is the untouched OC version.

## Installation

In-game:
```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```
`install.lua` resolves the branch to a commit, lists that commit through the GitHub trees API, and downloads `lib/ bin/ docs/` (plus `examples/ tests/` with `--full`; the choice is remembered in `/cc-ai/.version`) into a staging folder, after checking the free space (CC:T charges max(size, 500) per file and 500 per directory; the default disk is 1 MB). It then swaps the staging folder in and writes `/startup/cc-ai.lua`, which adds `/cc-ai/bin` to the shell path. The repo layout is the installed layout.

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
The runner mounts the repo read-only at `/cc-ai` in a headless emulator, runs `tests/run.lua`, and prints the results file. Headless stdout is a garbled screen dump, so tests write results to a file. Suites are `tests/test_*.lua`, each a `function(T)` using `T.test/T.eq/T.contains/T.raises` and `T.http` (mock: `push` responses for POST, `routes` for GET). In-game (needs a full install, `/cc-ai/install --full`): `/cc-ai/tests/run [suite]`. With the Unicode mod installed, tests of vanilla behaviour call `T.vanillaOnly()` and are reported as skipped. CraftOS-PC has functions CC:T lacks (`collectgarbage`) and does not enforce the disk limit: guard such calls and don't rely on the emulator for disk space.

Live checks against a real API: `.\tests\live.ps1 -Provider custom -Model <model>` (`tests/live.lua`). They use the emulator data dir `C:\cc-ai-live`, where the user sets keys themselves. Never read or print its `.settings` file.

## Architecture

**lib/ai/init.lua** - Main AI SDK: `ai.generateText()`, `ai.streamText()`, `ai.generateObject()`, `ai.tool()`
- Vercel AI Gateway (string models) and direct providers (model objects)
- Tool calling with automatic execution loop (`maxSteps`)
- Structured output via `ai.Output.object()`

**lib/ai/utils/init.lua** - `httpPost`, `httpPostStream` (line iterator over the buffered body: CC:T has no live HTTP streaming), `parseSSELine` (also returns the raw data text), `errorMessage` (the message of an API error payload), `toolParameters` (a tool's schema as sent: left out for tools without arguments, because rxi json encodes `{}` as `[]`), `getEnv` (settings), `defineSetting`. Non-2xx responses raise with the API's error message. A streamed reply that is not an event stream is read as plain JSON or raises; one that stops without `[DONE]` or a finish reason gets finishReason `"incomplete"`.

**lib/ai/google.lua**, **openai.lua**, **groq.lua**, **vercel.lua**, **custom.lua** - providers. All but Google are built on **openai-compat.lua**. `custom` reads its endpoint from the `AI_CUSTOM_BASE_URL` setting at request time, and its key (`AI_CUSTOM_API_KEY`) is optional. It sends `generateText` through streamed replies (`streamResponses`), so slow thinking models don't hit the idle timeout.

All HTTP requests use `binary = true`, so replies arrive exactly as sent (the unicode mod below re-encodes text-mode reads). `tests/http-check.lua` checks in-game that replies with non-ASCII text decode.

**lib/cmn-utils/** - `json` (rxi/json.lua), `glob`, `grep`, `path` (resolve against `shell.dir()`, yield helper), `text` (UTF-8 to CC charset for display, `fromCC` for user input going to APIs).

**lib/cc-code/** - the agent:
- `agent.lua` - system prompt, slash commands, `!cmd`, tool-call loop with history, secret redaction of tool results
- `tools.lua` - read_file, write_file, edit_file, list_directory, glob, grep, shell
- `capture.lua` - runs shell commands under `term.redirect` to a recording terminal, because CraftOS has no `>` redirection (or, for `shell` with `screen: true`, to an invisible screen-sized window whose final screen is returned). For the shell tool (`opts.noInput`) the user's keyboard and mouse events are not passed to the hidden program; events the program queues itself are
- `toolview.lua` - one-line tool call summaries for both UIs
- `secrets.lua` - values of secret settings (`*KEY`, `*TOKEN*`, ...) and their removal from tool results, errors and the file-derived parts of the system prompt
- `tui.lua` - full-screen UI (window-buffered, palette remapped to the theme). `terminal.lua` - line mode using `read()`
- `skills/` - help, model, turtle. `agent.init` calls `skills.unloadDirectories()`, then `skills.loadFromDirectory` for these, the user's `/.cc-code/skills` and the project's `.cc-code/skills`; it returns complete messages ready to print (load errors; command takeovers, or with `{ takeovers = list }` records that `skills.takeoverMessages` turns into messages once all folders are loaded). The skill loaded last gets a command. `skills.getAllTools(reserved)` / `toolProblems(reserved)` take the built-in tool names, `commandProblems(reserved)` the built-in commands

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
- Never use `#` or `string.len` on strings for byte work. The "CC: Tweaked Unicode Support" mod (installed in the user's game) makes them count UTF-8 characters, while `string.sub/byte/find` stay byte-based. Use `cmn-utils.text.byteLen` (it uses `string.find`; don't use `rawlen` either, because CraftOS-PC's returns 0 for strings made by `sub` or `..`)
- Display text goes through `text.forDisplay`, and is measured and clipped with `text.width` / `text.sub` (screen cells). Vanilla CC draws one byte per cell (ISO-8859-1 plus CC drawing chars), so `forDisplay` converts UTF-8 there. With the mod, the terminal draws UTF-8 (one cell per character) and `forDisplay` keeps it. Tests can simulate the mod with `T.withUnicodeMod`; real behaviour can only be checked in-game
- Screens are small by default: 51x19 computer, 39x13 turtle, 26x20 pocket. Computer sizes are configurable (the user's server uses 100x50)
- Read and write files in binary mode (`"rb"` / `"wb"`) to keep bytes intact

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment

This is a ComputerCraft: Tweaked (CC:T) Lua library for Minecraft 1.21.1, not a typical software project. Code runs inside CraftOS on the Cobalt VM (Lua 5.2 with a few 5.3 stdlib additions such as `utf8`). CC APIs are globals (`fs`, `term`, `http`, `settings`, `shell`, `turtle`, ...), not `require`d modules. It's a port of the OpenComputers project oc-ai; the first commit in git history is the untouched OC version.

## Installation

In-game:
```
wget run https://raw.githubusercontent.com/mindbound/cc-ai/master/install.lua
```
`install.lua` resolves the branch to a commit, lists that commit through the GitHub trees API, and downloads `lib/ bin/ docs/` (plus `examples/ tests/` with `--full`; the choice is remembered in `/cc-ai/.version`) into a staging folder, after checking the free space (CC:T charges max(size, 500) per file and 500 per directory; the default disk is 1 MB). It then swaps the staging folder in and writes `/startup/cc-ai.lua`, which adds the install's `bin` to the shell path. The repo layout is the installed layout. The minimal set also leaves out single files: the Basalt UI's code, `lib/cc-code/basalt/app.lua`, `ui.lua` and `log.lua` (`FULL_ONLY_FILES` in `install.lua`, the same list as `UI_FILES` in `load.lua`; selected by path, and left out of the space check too). `load.lua` stays in, and cc-code downloads the three on first use (see below); an update deletes them with `lib/`, so the next run downloads them from the new commit. `vendor/` is not in the installer's managed list: it is not installed (cc-code downloads `vendor/basalt.lua` itself, see below), and an update deletes it only when the new files would not fit otherwise. It counts as a last resort, after the entries a minimal update drops; the installer then prints one line and the Basalt UI downloads the file again. (A minimal install is about 380 KB, so a minimal update with the Basalt UI's downloads present, the 143 KB bundle and its 58 KB of code, needs nearly all of the default 1 MB disk: the installer may delete vendor/ then.)

An install is a folder with `.version` or, from an older installer or a copy by hand, `bin/cc-code.lua` (`isInstall`). The install folder is chosen in this order:

1. The folder given: `--dir <folder>` or the third positional argument, resolved with `shell.resolve`. A drive's own folder such as `/hdd` becomes `/hdd/cc-ai`. The installer stops before any request for `/`, `..`, read-only folders, a drive name (`hdd%d*`, `disk%d*`) where no drive is mounted, and a folder with `lib`/`bin`/`docs`/`examples`/`tests` that is not an install (`checkFolder`).
2. The folder of the running installer, when it is an install's own (`debug.getinfo` source `@/<dir>/install.lua`; `OWN`). So `/hdd/cc-ai/install` updates `/hdd/cc-ai`.
3. The first install of these: where the startup file's install is now (`IN_USE`), `/cc-ai`, `cc-ai` on each hard drive. `IN_USE` is found by `findInstall` from the startup file's `local dir = "..."` and its `local within, onDrive = ...` line; for an older startup file, `local binDir = ".../bin"` and `placeOf`. If the startup file's install is on a drive that is not mounted (`driveMissing`) and the search finds it on no other drive, the installer stops before any request rather than make a second install.
4. A new install is placed after the file listing: `cc-ai` on the hard drive with the most free space that fits `needed`, if its `cc-ai` folder does not exist yet. Otherwise it goes to `/cc-ai`.

Hard drives are the CC-Harddisks mod's: peripheral type `hard_drive`, whose `getFixedMountPath()` gives `hdd`, `hdd2`, ...; the installer never chooses a cartridge (`getMountPath()`, `/disk`) itself.

The startup file names the folder. If `<dir>/bin/cc-code.lua` is missing at boot (after an `mv` to another drive, or when `/hdd` and `/hdd2` swapped), the startup file looks for the same place within a drive. It looks under each hard drive (`hdd*`), then each other drive except `rom`, then each folder on the computer's own drive. The computer's own root comes first when the install was on it, else last. While nothing is mounted under the named folder's drive name, it looks on drives only, not on the computer's own drive (the drive may be mounted under another name: `hdd2` is `hdd` when the other hard drive is gone). When it finds nothing, it keeps the named folder. `findInstall` mirrors the startup file's search: the named folder counts by `isInstall`, a searched place only by `bin/cc-code.lua`, as in the startup file. Keep the two in step (test_install checks that the installer updates the folder the startup file put on the path).

When the startup file named or found another install, the installer takes that install's `bin` off the session's path. If that install still exists, it says it is no longer used here, and lists the user's files in its skills folder.

On the computer's own disk, the installer names a hard drive with room when an update does not fit, or when the free space left is less than the next update needs (`moveCommands`). In the not-enough-space error, the installer in the install folder may be older than the running one, or missing (a copy by hand). So unless it is the running one (`OWN`), the command is `wget run <url> [repo branch] --dir <target>`, which also keeps this run's `--full` or `--minimal`. A cached older installer stops at the unknown `--dir` and changes nothing. The docs tell users to move an install the same way: `mv`, then the `wget run` command with `--dir`.

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
The runner mounts the repo read-only at `/cc-ai` in a headless emulator, runs `tests/run.lua`, and prints the results file. Headless stdout is a garbled screen dump, so tests write results to a file. Suites are `tests/test_*.lua`, each a `function(T)` using `T.test/T.eq/T.contains/T.raises` and `T.http` (mock: `push` responses for POST, `routes` for GET). `test_install` runs the installer with a stand-in `peripheral` that reports no hard drives, a startup file under `T.tmp` (`sandboxed`) and a shell path of its own (`sandboxPath`). Its tests of where the installer installs use `fakeComputer`: a computer inside `T.tmp` with its own `/cc-ai`, `/startup`, drives (free space counted as CC:T counts it), current folder and shell path. These tests never touch the real install, startup file or shell path, also in-game. In-game (needs a full install, `/cc-ai/install --full`): `/cc-ai/tests/run [suite]`. With the Unicode mod installed, tests of vanilla behaviour call `T.vanillaOnly()` and are reported as skipped. The repo's `vendor/basalt.lua` is at `/cc-ai/vendor/basalt.lua` in the emulator, so the Basalt loader finds it without a download. `test_basalt_load` tests downloads in a temp install root under `T.tmp`, serving a small stand-in bundle with the expected header lines and stand-in UI files through `mock.routes` (a second copy of the real 143 KB file would not fit next to a full install on a 1 MB disk). Tests that need the real bundle call `T.needsBasalt()` first: in-game it is missing until the Basalt UI has downloaded it, or left from an older version, and the test is then reported as skipped. In the repository (no `.version` at the root), `test_basalt_load`'s check of `COMMIT`, `ELEMENTS` and `MODULES` against the bundle fails on a mismatch instead of skipping. CraftOS-PC has functions CC:T lacks (`collectgarbage`) and does not enforce the disk limit: guard such calls and don't rely on the emulator for disk space.

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
- `init.lua` - `occode.run` picks the UI: the Basalt UI when `config.basalt` (`--basalt`) or the `cc-code.ui` setting asks for it (and `config.basalt ~= false`, which `--tui` sets), the screen is at least 20x8 and the bundle loads (otherwise one line says why, also shown with the TUI's welcome lines, and the TUI runs). When `app.run` raises before its session started (a counter that `startSession` increments when it returns did not change, e.g. a bundle without an element `ui.init` needs), the same line and the TUI follow; a later error, or "Terminated", is raised. Else `tui.lua`, or `terminal.lua` when forced or on smaller screens. The session pieces every UI uses are exported: `occode.startSession(ui, config)`, `turnCallbacks(ui)`, `showResult(ui, result)`, `endSession(ui)`. The TUI and terminal UIs run them in `runLoop` (with `ui.readInput`)
- `tui.lua` - full-screen UI (window-buffered, palette remapped to the theme). `terminal.lua` - line mode using `read()`
- `basalt/` - the Basalt UI (a trial, opt-in). `load.lua` finds `<install root>/vendor/basalt.lua` (root from its own path, or `load({ root = ... })`) and accepts it only when its header's `-- Commit:`, `-- Elements:` and `-- Modules:` lines equal `COMMIT`, `ELEMENTS` and `MODULES` (`fileMatches`). Otherwise it downloads it, together with whichever of the Basalt UI's own files (`UI_FILES`: app.lua, ui.lua, log.lua, which a minimal install leaves out) are missing under `<install root>/lib/cc-code/basalt/`, from raw.githubusercontent.com at the repo and commit (else branch) in `.version`. All files are downloaded and checked first (the bundle's header; the UI files must compile), then the free space is checked for all of them, each is written to a temp file, and the temp files are moved into place only when all are written: a failure writes none of them (and removes folders it made) and returns nil and a reason, so cc-code runs the TUI. It then loads the bundle with the program's environment and returns the Basalt API with reactive strings off, or nil and a short reason. `app.lua` - `app.run(config, basalt)`: cc-code's own event loop ("pump") feeds events to `basalt.update`, runs each turn (`agent.process`) in a coroutine resumed with filters as `parallel` does, routes Ctrl+T by phase (Basalt never sees terminate), queues prompts typed during a turn, and on a UI error finishes a suspended turn with "terminate" before `basalt.cleanup()`. While a turn runs it wraps `os.queueEvent` and counts the input events code queues (a program testing its own `read()`); when they come back they go to the turn only, never to the input line (capture.run's own wrapper nests on top during the shell tool; a mouse event may come back one row higher under multishell's tab bar). The counts are kept in sets: a set is closed each time the turn yields after queueing input events, and when the turn ends. A `cc_code_queued_mark` event is queued behind the closed set; when it comes back, the counts left (events CC:T dropped at its 256-event limit) are dropped, or after a 2-second timer if the marker was lost too. A queued prompt whose turn ends at once starts the next one without waiting for another event. `app.pump` is the running pump while a session runs (nil otherwise; tests look at it). `ui.lua` (`cc-code.basalt.ui`) - the UI object with tui.lua's contract (requirable without Basalt; `registerCompletion` works before init; `handleEvent` does nothing and there is no `readInput`), plus functions for app.lua: `setBasalt`, `inputEvent(ev)` (returns handled and the sent line), `wheel`, `checkSize`, `setQueued`, `setInput`, `clearInput`, `inputText`, `setProgramMode`, the scroll functions, and `inspect` (for tests). ui.lua registers the theme colours in a fixed order, dark ones first, and the popup's highlight is the status colour, so the yellow and gray palette slots that multishell's tab bar uses keep light colours. `log.lua` - the conversation log drawn on a Canvas: tui.lua's wrapping by cells and tool-row cutting rules, the scroll offset (kept when scrolled back), re-wrapping on resize, and the hold-back of an incomplete UTF-8 sequence in `streamText`
- `skills/` - help, model, turtle. `agent.init` calls `skills.unloadDirectories()`, then `skills.loadFromDirectory` for these, the user's `/.cc-code/skills` and the project's `.cc-code/skills`; it returns complete messages ready to print (load errors; command takeovers, or with `{ takeovers = list }` records that `skills.takeoverMessages` turns into messages once all folders are loaded). The skill loaded last gets a command. `skills.getAllTools(reserved)` / `toolProblems(reserved)` take the built-in tool names, `commandProblems(reserved)` the built-in commands

**bin/cc-code.lua** - entry program (option parsing: `-t`, `-b/--basalt` and `--tui` choose the UI, the last one counts). **install.lua** - installer.

**vendor/basalt.lua** - a trimmed, readable single-file bundle of the user's Basalt fork (mindbound/Basalt2) with Frame, Canvas, Label, Input and List (+Collection), no modules, and the MIT header. Only the Basalt UI uses it, and cc-code downloads it on first use, so the bundle must be committed together with the matching `COMMIT`, `ELEMENTS` and `MODULES` in `lib/cc-code/basalt/load.lua`. To rebuild it, use a full (not shallow) clone of the fork with a clean working tree, at the commit you want, and run this from the fork's root: `lua tools/bundle-host.lua <cc-ai>/vendor/basalt.lua --elements Frame,Canvas,Label,Input,List --modules none`. The header's `-- Commit:` line names the last fork commit that changed `src`, `LICENSE` or `tools/bundle.lua`. A build from a working tree with uncommitted changes adds "(with uncommitted changes)" to that line, and cc-code rejects such a build. Then copy the header's `-- Commit:`, `-- Elements:` and `-- Modules:` values into `COMMIT`, `ELEMENTS` and `MODULES` in `load.lua`: a rebuild with other `--elements` or `--modules` keeps the commit, and only the other two lines tell an installed bundle of the old build from the new one. `test_basalt_load` fails until they match. Set reactive strings off (`basalt.setReactiveStrings(false)`, which `load` does): otherwise Basalt runs `{...}` in strings given to element properties as Lua, and model output contains such text.

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

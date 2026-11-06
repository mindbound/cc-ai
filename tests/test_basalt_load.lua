-- tests/test_basalt_load.lua
-- The Basalt UI's loader (cc-code.basalt.load: the bundle, and the UI's
-- files a minimal install leaves out) against the fake HTTP API, how
-- occode.run picks the UI, and the session pieces both UIs share. The
-- download tests serve a small stand-in bundle and stand-in UI files; the
-- few tests that need the real vendor/basalt.lua (not in an install until
-- the Basalt UI has downloaded it) call T.needsBasalt.

return function(T)
  local loader = require("cc-code.basalt.load")
  local occode = require("cc-code")
  local agent = require("cc-code.agent")
  local capture = require("cc-code.capture")
  local mock = T.http

  local COMMIT = "0123456789abcdef0123456789abcdef01234567"

  local function byteLen(s)
    return select(2, s:find("$"))
  end

  -- What the download tests serve: a small stand-in for vendor/basalt.lua
  -- with the header of the expected build, so they don't write a second
  -- copy of the real bundle (143 KB) to a 1 MB in-game disk. The padding
  -- makes it bigger than CC: Tweaked's 500-byte minimum per file, so the
  -- disk-space checks count its real size.
  local BUNDLE = table.concat({
    "-- Basalt (a stand-in for the tests)",
    "-- Commit: " .. loader.COMMIT,
    "-- Elements: " .. loader.ELEMENTS,
    "-- Modules: " .. loader.MODULES,
    "-- " .. string.rep("padding ", 200),
    "return {",
    "  update = function() end,",
    "  cleanup = function() end,",
    "  setReactiveStrings = function(on) end,",
    "}",
    "",
  }, "\n")

  -- The stand-in with another fork commit in its header
  local function bundleFor(commit)
    return (BUNDLE:gsub("\n%-%- Commit: %x+", "\n-- Commit: " .. commit, 1))
  end

  -- The stand-in with another "-- <name>:" header line (nil: without it)
  local function bundleWith(name, value)
    local line = value and ("\n-- " .. name .. ": " .. value) or ""
    return (BUNDLE:gsub("\n%-%- " .. name .. ": [^\n]*", line, 1))
  end

  -- Stand-ins for the Basalt UI's files (Lua, bigger than 500 bytes)
  local UI = {}
  for _, rel in ipairs(loader.UI_FILES) do
    UI[rel] = "-- " .. rel .. " (a stand-in for the tests)\n-- " .. string.rep("padding ", 80) .. "\nreturn {}\n"
  end

  -- A Basalt API for the tests of occode.run's choice, which don't need
  -- the real bundle
  local fakeLoader = {
    load = function()
      return { update = function() end, cleanup = function() end, setReactiveStrings = function() end }
    end,
  }

  -- Where a file of the repository is downloaded from (default: the bundle)
  local function rawUrl(repo, ref, rel)
    return "https://raw.githubusercontent.com/" .. repo .. "/" .. ref .. "/" .. (rel or loader.PATH)
  end

  -- Serve the bundle (default: the stand-in) and the UI's files at repo@ref
  local function serve(repo, ref, bundle)
    mock.routes[rawUrl(repo, ref)] = bundle or BUNDLE
    for _, rel in ipairs(loader.UI_FILES) do
      mock.routes[rawUrl(repo, ref, rel)] = UI[rel]
    end
  end

  -- A fresh install root under T.tmp, with a .version when info is given.
  -- It has the Basalt UI's files (stand-ins), as a full install does; a
  -- minimal one has only the loader in their folder.
  local function newRoot(info, minimal)
    T.resetTmp()
    local root = T.tmp .. "/inst"
    fs.makeDir(root)
    if info then
      T.writeFile(root .. "/.version", textutils.serialize(info))
    end
    T.writeFile(root .. "/lib/cc-code/basalt/load.lua", "-- the loader")
    if not minimal then
      for _, rel in ipairs(loader.UI_FILES) do
        T.writeFile(root .. "/" .. rel, UI[rel])
      end
    end
    return root
  end

  -- Nothing of the Basalt UI was written to a minimal root: no bundle, no
  -- UI file, no temporary file, no vendor/ folder
  local function nothingWritten(root)
    T.ok(not fs.exists(root .. "/vendor"), "no vendor/")
    for _, rel in ipairs(loader.UI_FILES) do
      T.ok(not fs.exists(root .. "/" .. rel), rel .. " not written")
      T.ok(not fs.exists(root .. "/" .. rel .. ".download"), rel .. ": no temporary file")
    end
  end

  local function downloads()
    local list = {}
    for _, req in ipairs(mock.requests) do
      if req.method == "GET" then list[#list + 1] = req end
    end
    return list
  end

  -- Run fn with t[key] replaced, putting it back even if fn fails
  local function withReplaced(t, key, value, fn)
    local saved = t[key]
    t[key] = value
    local ok, err = pcall(fn)
    t[key] = saved
    if not ok then error(err, 0) end
  end

  T.test("the expected build is the repository's bundle", function()
    local path = T.root .. "/vendor/basalt.lua"
    -- In an install (it has a .version), vendor/ is downloaded on its own:
    -- missing, or left from an older version until the Basalt UI runs. In
    -- the repository, a mismatch is a mistake.
    if fs.exists(T.root .. "/.version") then
      T.needsBasalt()
    end
    T.ok(fs.exists(path), "vendor/basalt.lua is missing: commit it together with the constants in load.lua")
    local handle = fs.open(path, "rb")
    local head = handle.read(2048)
    handle.close()
    local commit = head:match("\n%-%- Commit: (%x+)\r?\n")
    T.eq(commit, loader.COMMIT, "update COMMIT in lib/cc-code/basalt/load.lua after rebuilding the bundle")
    T.eq(byteLen(commit), 40, "a full commit hash")
    T.eq(head:match("\n%-%- Elements: ([^\r\n]*)\r?\n"), loader.ELEMENTS,
      "update ELEMENTS in lib/cc-code/basalt/load.lua after rebuilding the bundle")
    T.eq(head:match("\n%-%- Modules: ([^\r\n]*)\r?\n"), loader.MODULES,
      "update MODULES in lib/cc-code/basalt/load.lua after rebuilding the bundle")
    T.eq(loader.fileCommit(path), loader.COMMIT)
    T.ok(loader.fileMatches(path), "accepted as it is")
    -- The UI's files are downloaded from the repository too
    for _, rel in ipairs(loader.UI_FILES) do
      T.ok(fs.exists(T.root .. "/" .. rel), rel .. " is in the repository")
    end
  end)

  T.test("a bundle in place is loaded without a request", function()
    T.needsBasalt()
    mock.reset()
    -- (the repository mounted at /cc-ai is the install root found from
    -- the module's own path)
    local basalt, err = loader.load()
    T.ok(basalt, "loaded: " .. tostring(err))
    T.eq(#mock.requests, 0, "no request")
    T.eq(type(basalt.update), "function")
    T.eq(type(basalt.createFrame), "function")
    T.eq(type(basalt.suspendPalette), "function")
    T.eq(basalt.getReactiveStrings(), false, "reactive strings are off")
    -- Each load gives a fresh instance
    T.ok(loader.load() ~= basalt, "a new instance")
  end)

  T.test("a missing bundle is downloaded from the installed commit", function()
    local root = newRoot({ repo = "me/repo", branch = "dev", commit = COMMIT })
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = BUNDLE
    local lines = {}
    local basalt, err = loader.load({ root = root, status = function(line) lines[#lines + 1] = line end })
    T.ok(basalt, "loaded: " .. tostring(err))
    T.eq(type(basalt.update), "function")
    local gets = downloads()
    T.eq(#gets, 1, "one download")
    T.eq(gets[1].url, rawUrl("me/repo", COMMIT))
    T.eq(gets[1].binary, true, "binary")
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), BUNDLE, "saved as downloaded")
    T.ok(not fs.exists(root .. "/vendor/basalt.lua.download"), "no temporary file left")
    T.eq(#lines, 1, "one status line")
    T.contains(lines[1], "Downloading")
    T.contains(lines[1], "me/repo@0123456")
    -- Found in place the next time
    mock.reset()
    T.ok(loader.load({ root = root }))
    T.eq(#mock.requests, 0, "no request the second time")
  end)

  T.test("without a commit in .version the branch is used, without .version cc-ai's master", function()
    local root = newRoot({ repo = "me/repo", branch = "dev" })
    mock.reset()
    T.eq(loader.load({ root = root }), nil)
    T.eq(downloads()[1].url, rawUrl("me/repo", "dev"))

    root = newRoot()
    mock.reset()
    T.eq(loader.load({ root = root }), nil)
    T.eq(downloads()[1].url, rawUrl("mindbound/cc-ai", "master"))

    root = newRoot()
    T.writeFile(root .. "/.version", "{ broken")
    mock.reset()
    T.eq(loader.load({ root = root }), nil)
    T.eq(downloads()[1].url, rawUrl("mindbound/cc-ai", "master"), "unreadable .version")
  end)

  T.test("a bundle built from another commit is downloaded again", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    T.writeFile(root .. "/vendor/basalt.lua", bundleFor(string.rep("1", 40)))
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = BUNDLE
    local basalt, err = loader.load({ root = root })
    T.ok(basalt, "loaded: " .. tostring(err))
    T.eq(#downloads(), 1)
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), BUNDLE, "replaced")
    T.ok(not fs.exists(root .. "/vendor/basalt.lua.download"), "no temporary file left")
  end)

  T.test("a bundle of the same commit with other elements or modules is downloaded again", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    local path = root .. "/vendor/basalt.lua"
    local others = {
      bundleWith("Elements", "Button, Canvas, Collection, Frame, Input, Label, List"),
      bundleWith("Elements", nil),
      bundleWith("Modules", "benchmark"),
      bundleWith("Modules", nil),
    }
    for i, other in ipairs(others) do
      T.writeFile(path, other)
      T.eq(loader.fileCommit(path), loader.COMMIT, "the same commit (" .. i .. ")")
      T.ok(not loader.fileMatches(path), "another build (" .. i .. ")")
      mock.reset()
      mock.routes[rawUrl("me/repo", COMMIT)] = BUNDLE
      local basalt, err = loader.load({ root = root })
      T.ok(basalt, "loaded: " .. tostring(err))
      T.eq(#downloads(), 1, "downloaded (" .. i .. ")")
      T.eq(T.readFile(path), BUNDLE, "replaced (" .. i .. ")")
      T.ok(loader.fileMatches(path))
    end
  end)

  T.test("a minimal install's missing Basalt UI files are downloaded with the bundle", function()
    local root = newRoot({ repo = "me/repo", branch = "dev", commit = COMMIT }, true)
    mock.reset()
    serve("me/repo", COMMIT)
    local lines = {}
    local basalt, err = loader.load({ root = root, status = function(line) lines[#lines + 1] = line end })
    T.ok(basalt, "loaded: " .. tostring(err))
    local gets = downloads()
    T.eq(#gets, 4, "the bundle and the three UI files")
    T.eq(gets[1].url, rawUrl("me/repo", COMMIT))
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), BUNDLE)
    for i, rel in ipairs(loader.UI_FILES) do
      T.eq(gets[i + 1].url, rawUrl("me/repo", COMMIT, rel), "from the installed commit")
      T.eq(gets[i + 1].binary, true, "binary")
      T.eq(T.readFile(root .. "/" .. rel), UI[rel], rel .. " saved as downloaded")
      T.ok(not fs.exists(root .. "/" .. rel .. ".download"), "no temporary file left")
    end
    T.eq(#lines, 1, "one status line")
    T.contains(lines[1], "basalt.lua, app.lua, ui.lua, log.lua")
    T.contains(lines[1], "me/repo@0123456")

    -- Found in place the next time
    mock.reset()
    T.ok(loader.load({ root = root }))
    T.eq(#mock.requests, 0, "no request the second time")

    -- Only what is missing is downloaded
    fs.delete(root .. "/lib/cc-code/basalt/ui.lua")
    mock.reset()
    serve("me/repo", COMMIT)
    T.ok(loader.load({ root = root }))
    gets = downloads()
    T.eq(#gets, 1, "one file")
    T.eq(gets[1].url, rawUrl("me/repo", COMMIT, "lib/cc-code/basalt/ui.lua"))
    T.eq(T.readFile(root .. "/lib/cc-code/basalt/ui.lua"), UI["lib/cc-code/basalt/ui.lua"])

    -- A bundle of another build with the UI's files in place: the bundle only
    T.writeFile(root .. "/vendor/basalt.lua", bundleFor(string.rep("5", 40)))
    mock.reset()
    serve("me/repo", COMMIT)
    T.ok(loader.load({ root = root }))
    T.eq(#downloads(), 1)
    T.eq(downloads()[1].url, rawUrl("me/repo", COMMIT))
  end)

  T.test("a Basalt UI file that can't be had writes none of the files", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT }, true)
    local log, ui = "lib/cc-code/basalt/log.lua", "lib/cc-code/basalt/ui.lua"

    -- Not found
    mock.reset()
    serve("me/repo", COMMIT)
    mock.routes[rawUrl("me/repo", COMMIT, log)] = nil
    local basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "download of " .. log .. " from me/repo@0123456 failed: 404 Not Found")
    nothingWritten(root)

    -- Not Lua (an error page), or empty
    mock.reset()
    serve("me/repo", COMMIT)
    mock.routes[rawUrl("me/repo", COMMIT, ui)] = "<html>rate limited</html>"
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "the downloaded " .. ui .. " is not Lua")
    nothingWritten(root)
    mock.reset()
    serve("me/repo", COMMIT)
    mock.routes[rawUrl("me/repo", COMMIT, ui)] = "\n"
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "the downloaded " .. ui .. " is empty")
    nothingWritten(root)

    -- A bundle of another build
    mock.reset()
    serve("me/repo", COMMIT, bundleFor(string.rep("6", 40)))
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "6666666")
    nothingWritten(root)

    -- A failure while saving the last file: the files written before it
    -- under temporary names are removed, and the folder made for them
    mock.reset()
    serve("me/repo", COMMIT)
    local realOpen = fs.open
    withReplaced(fs, "open", function(path, mode)
      if type(path) == "string" and path:find("log%.lua%.download$") then
        return nil, "Out of space"
      end
      return realOpen(path, mode)
    end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.eq(basalt, nil)
    T.eq(err, "could not save " .. log .. ": Out of space")
    nothingWritten(root)
    T.ok(fs.exists(root .. "/lib/cc-code/basalt/load.lua"), "the loader's folder is kept")

    -- After all that, a good download works
    mock.reset()
    serve("me/repo", COMMIT)
    basalt, err = loader.load({ root = root })
    T.ok(basalt, "loaded: " .. tostring(err))
  end)

  T.test("the disk space check counts the bundle and the UI's files together", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT }, true)
    -- Each file as CC: Tweaked charges it, and the new vendor/ folder
    local needed = byteLen(BUNDLE) + 500
    for _, rel in ipairs(loader.UI_FILES) do
      needed = needed + math.max(byteLen(UI[rel]), 500)
    end
    local basalt, err
    mock.reset()
    serve("me/repo", COMMIT)
    withReplaced(fs, "getFreeSpace", function() return needed - 1 end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.eq(basalt, nil)
    T.contains(err, "not enough disk space")
    T.contains(err, "needs " .. needed)
    nothingWritten(root)
    withReplaced(fs, "getFreeSpace", function() return needed end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.ok(basalt, "fits exactly: " .. tostring(err))
    for _, rel in ipairs(loader.UI_FILES) do
      T.eq(T.readFile(root .. "/" .. rel), UI[rel])
    end
  end)

  T.test("a failed download gives a reason and writes nothing", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    mock.reset()
    local basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "404 Not Found")
    T.contains(err, "me/repo@0123456")
    T.ok(not fs.exists(root .. "/vendor"), "nothing written")
  end)

  T.test("a download of another commit is refused and replaces nothing", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    local old = bundleFor(string.rep("2", 40))
    T.writeFile(root .. "/vendor/basalt.lua", old)
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = bundleFor(string.rep("3", 40))
    local basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "3333333")
    T.contains(err, loader.COMMIT:sub(1, 7))
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "the old file is kept")
    T.ok(not fs.exists(root .. "/vendor/basalt.lua.download"), "no temporary file")

    -- A build with uncommitted changes names no commit of its own
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = bundleFor(loader.COMMIT .. " (with uncommitted changes)")
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "(no commit)")
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "kept")

    -- Not a bundle at all (an error page)
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = "<html>rate limited</html>"
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "(no commit)")
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "still kept")

    -- The right commit, but other elements or modules
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = bundleWith("Elements", "Canvas, Frame")
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "has the elements Canvas, Frame, not " .. loader.ELEMENTS)
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "kept (elements)")
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = bundleWith("Modules", nil)
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "has the modules (none named), not " .. loader.MODULES)
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "kept (modules)")
    T.ok(not fs.exists(root .. "/vendor/basalt.lua.download"), "no temporary file")
  end)

  T.test("without the disk space nothing is written", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = BUNDLE
    local size = byteLen(BUNDLE)
    local basalt, err
    -- The file and its new folder (500)
    withReplaced(fs, "getFreeSpace", function() return size + 499 end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.eq(basalt, nil)
    T.contains(err, "not enough disk space")
    T.contains(err, "needs " .. (size + 500))
    T.ok(not fs.exists(root .. "/vendor"), "nothing written")
    withReplaced(fs, "getFreeSpace", function() return size + 500 end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.ok(basalt, "fits exactly: " .. tostring(err))

    -- A bundle of another commit can't be used: its space counts as free
    local old = bundleFor(string.rep("4", 40)):sub(1, 600)
    T.writeFile(root .. "/vendor/basalt.lua", old)
    withReplaced(fs, "getFreeSpace", function() return size - 601 end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.eq(basalt, nil)
    T.contains(err, "not enough disk space")
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), old, "the old file is kept")
    withReplaced(fs, "getFreeSpace", function() return size - 600 end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.ok(basalt, "fits in place of the old file: " .. tostring(err))
    T.eq(T.readFile(root .. "/vendor/basalt.lua"), BUNDLE)

    -- Unknown free space: no check
    fs.delete(root .. "/vendor")
    withReplaced(fs, "getFreeSpace", function() return "unlimited" end, function()
      basalt, err = loader.load({ root = root })
    end)
    T.ok(basalt, "unlimited: " .. tostring(err))
  end)

  T.test("without the HTTP API, or on a read-only disk, there is no download", function()
    local root = newRoot({ repo = "me/repo", commit = COMMIT })
    mock.reset()
    mock.routes[rawUrl("me/repo", COMMIT)] = BUNDLE
    local basalt, err
    -- (false, not nil: the program's environment would fall back to _G's
    -- real http)
    withReplaced(_ENV, "http", false, function()
      basalt, err = loader.load({ root = root })
    end)
    T.eq(basalt, nil)
    T.contains(err, "HTTP API is disabled")
    T.eq(#mock.requests, 0)
    T.ok(not fs.exists(root .. "/vendor"), "nothing written")

    mock.reset()
    basalt, err = loader.load({ root = "/rom" })
    T.eq(basalt, nil)
    T.contains(err, "read-only")
    T.eq(#mock.requests, 0, "no request")
  end)

  T.test("a bundle that fails to load gives the error", function()
    mock.reset()
    local root = newRoot()
    local header = "-- Basalt\n-- Commit: " .. loader.COMMIT .. "\n-- Elements: " .. loader.ELEMENTS ..
      "\n-- Modules: " .. loader.MODULES .. "\n"
    T.writeFile(root .. "/vendor/basalt.lua", header .. "return (")
    local basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "could not load vendor/basalt.lua")
    T.writeFile(root .. "/vendor/basalt.lua", header .. "error(\"boom\", 0)")
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "boom")
    T.writeFile(root .. "/vendor/basalt.lua", header .. "return { update = 1 }")
    basalt, err = loader.load({ root = root })
    T.eq(basalt, nil)
    T.contains(err, "not the Basalt build")
    T.eq(#mock.requests, 0, "no download for a bundle of the right build")
    T.raises(function() loader.load("x") end, "opts must be a table")
  end)

  -- occode.run's choice of UI ---------------------------------------------

  settings.set("AI_GATEWAY_API_KEY", "gw-test")

  -- A UI that records what it is asked to do; readInput gives the queued
  -- inputs, then nil (Ctrl+T at an empty prompt)
  local function fakeUI(inputs)
    local ui = {
      calls = {}, running = true, inputs = inputs or {},
      colors = { assistant = colours.cyan, dim = colours.grey, error = colours.red, foreground = colours.white },
    }
    local function record(name)
      return function(...)
        ui.calls[#ui.calls + 1] = { name, ... }
      end
    end
    ui.init = record("init")
    ui.print = record("print")
    ui.printRole = record("printRole")
    ui.setStatus = record("setStatus")
    ui.printToolCall = record("printToolCall")
    ui.printToolResult = record("printToolResult")
    ui.clear = record("clear")
    ui.setToolDisplay = record("setToolDisplay")
    ui.addCommand = record("addCommand")
    ui.suspendTheme = record("suspendTheme")
    ui.resumeTheme = record("resumeTheme")
    function ui.readInput()
      return table.remove(ui.inputs, 1)
    end
    function ui.stop() ui.running = false ui.calls[#ui.calls + 1] = { "stop" } end
    function ui.isRunning() return ui.running end
    function ui.cleanup() ui.calls[#ui.calls + 1] = { "cleanup" } end
    -- The printed texts
    function ui.printed()
      local list = {}
      for _, call in ipairs(ui.calls) do
        if call[1] == "print" then list[#list + 1] = call[2] end
      end
      return list
    end
    return ui
  end

  -- Run occode.run(config) on a w x h recording terminal with the fake UI
  -- as the TUI and a recording stub as the Basalt UI's app. Returns what
  -- happened: { app = {config, basalt} or nil, ui, gotUI, forced, text,
  -- result, err }. stubs: inputs (for the fake UI), load (the loader
  -- module), app (the app module), noApp (none: require looks for it,
  -- package.preload first), window (a hidden window instead of the
  -- recording terminal; text is then ""), expectError (return the error
  -- occode.run raised as err).
  local function runWith(w, h, config, stubs)
    stubs = stubs or {}
    agent.config.model = "anthropic/claude-sonnet-4"
    local happened = { ui = fakeUI(stubs.inputs) }
    local savedGetUI = occode.getUI
    local savedApp = package.loaded["cc-code.basalt.app"]
    local savedLoad = package.loaded["cc-code.basalt.load"]
    occode.getUI = function(forceTerminal)
      happened.gotUI = true
      happened.forced = forceTerminal
      return happened.ui
    end
    if stubs.noApp then
      package.loaded["cc-code.basalt.app"] = nil
    else
      package.loaded["cc-code.basalt.app"] = stubs.app or {
        run = function(cfg, basalt)
          happened.app = { config = cfg, basalt = basalt }
          return "app result"
        end,
      }
    end
    if stubs.load then
      package.loaded["cc-code.basalt.load"] = stubs.load
    end
    local rec = stubs.window and window.create(term.current(), 1, 1, w, h, false) or capture.createTerminal(w, h)
    local old = term.redirect(rec)
    local ok, err = pcall(function()
      happened.result = occode.run(config)
    end)
    term.redirect(old)
    occode.getUI = savedGetUI
    package.loaded["cc-code.basalt.app"] = savedApp
    package.loaded["cc-code.basalt.load"] = savedLoad
    happened.text = rec.getText and rec.getText() or ""
    if not ok then
      if not stubs.expectError then error(err, 0) end
      happened.err = err
    elseif stubs.expectError then
      error("occode.run should have raised an error", 0)
    end
    return happened
  end

  -- The note's place in the fake TUI's session: after the welcome line
  -- and before the blank line that ends the welcome lines
  local function noteShown(ui, note)
    local printed = ui.printed()
    for i, text in ipairs(printed) do
      if text == note then
        T.ok(i > 1 and printed[1]:find("Welcome", 1, true), "after the welcome line")
        T.eq(printed[i + 1], "", "before the blank line")
        return
      end
    end
    error("not shown in the session: " .. note, 2)
  end

  T.test("--basalt runs the Basalt UI with the loaded bundle", function()
    T.needsBasalt()
    mock.reset()
    local config = { basalt = true }
    local happened = runWith(51, 19, config)
    T.ok(happened.app, "the Basalt UI ran")
    T.eq(happened.app.config, config)
    T.eq(type(happened.app.basalt), "table")
    T.eq(type(happened.app.basalt.update), "function")
    T.eq(happened.result, "app result")
    T.eq(happened.forced, nil, "no other UI")
    T.eq(#mock.requests, 0, "the bundle in place (no download)")
  end)

  T.test("the cc-code.ui setting picks the UI; --tui and --terminal override it", function()
    mock.reset()
    local stubs = { load = fakeLoader }
    local ok, err = pcall(function()
      settings.set("cc-code.ui", "basalt")
      T.ok(runWith(51, 19, {}, stubs).app, "setting basalt")
      settings.set("cc-code.ui", " Basalt ")
      T.ok(runWith(51, 19, {}, stubs).app, "case and spaces")
      settings.set("cc-code.ui", "basalt")
      local happened = runWith(51, 19, { basalt = false }, stubs)
      T.eq(happened.app, nil, "--tui")
      T.eq(happened.forced, nil)
      happened = runWith(51, 19, { forceTerminal = true }, stubs)
      T.eq(happened.app, nil, "--terminal")
      T.eq(happened.forced, true)
      settings.set("cc-code.ui", "tui")
      T.eq(runWith(51, 19, {}, stubs).app, nil, "setting tui")
      settings.unset("cc-code.ui")
      happened = runWith(51, 19, {}, stubs)
      T.eq(happened.app, nil, "unset")
      T.ok(happened.text:find("Goodbye!", 1, true), "the TUI session ended")
    end)
    settings.unset("cc-code.ui")
    if not ok then error(err, 0) end
  end)

  T.test("the Basalt UI needs a screen of at least 20x8, like the TUI", function()
    local stubs = { load = fakeLoader }
    T.eq(runWith(19, 19, { basalt = true }, stubs).app, nil, "19 wide")
    T.eq(runWith(51, 7, { basalt = true }, stubs).app, nil, "7 high")
    T.ok(runWith(20, 8, { basalt = true }, stubs).app, "20x8")
  end)

  T.test("when the Basalt UI can't load, one line says why and the TUI runs", function()
    local happened = runWith(200, 20, { basalt = true }, {
      load = { load = function() return nil, "download failed: 404 Not Found" end },
    })
    T.eq(happened.app, nil)
    T.eq(happened.forced, nil, "the TUI")
    local note = "Basalt UI not available (download failed: 404 Not Found); using the standard UI."
    T.contains(happened.text, note, "printed before the TUI starts")
    -- Also with the TUI's welcome lines (it clears the screen), once
    local printed = happened.ui.printed()
    local found
    for i, text in ipairs(printed) do
      if text == note then
        found = i
        for _, call in ipairs(happened.ui.calls) do
          if call[1] == "print" and call[2] == note then T.eq(call[3], colours.red, "error colour") end
        end
      end
    end
    T.ok(found, "shown in the session")
    T.ok(found > 1 and printed[1]:find("Welcome", 1, true), "after the welcome line")
    T.eq(printed[found + 1], "", "before the blank line")
    local nextRun = runWith(200, 20, {})
    for _, text in ipairs(nextRun.ui.printed()) do
      T.ok(text ~= note, "not shown again")
    end
  end)

  T.test("an app module that fails to load falls back to the TUI with its first line", function()
    package.preload["cc-code.basalt.app"] = function() error("broken app\nsecond line", 0) end
    local ok, err = pcall(function()
      local happened = runWith(200, 20, { basalt = true }, { noApp = true, load = fakeLoader })
      T.eq(happened.app, nil)
      T.eq(happened.forced, nil, "the TUI")
      T.contains(happened.text, "Basalt UI not available (broken app); using the standard UI.")
    end)
    package.preload["cc-code.basalt.app"] = nil
    if not ok then error(err, 0) end
  end)

  T.test("a Basalt UI that fails before its session starts falls back to the TUI", function()
    local happened = runWith(200, 20, { basalt = true }, {
      load = fakeLoader,
      app = { run = function() error("attempt to call method 'addCanvas' (a nil value)\nsecond line", 0) end },
    })
    T.ok(happened.gotUI, "the TUI ran")
    T.eq(happened.forced, nil, "the TUI")
    local note = "Basalt UI not available (attempt to call method 'addCanvas' (a nil value)); using the standard UI."
    T.contains(happened.text, note, "printed before the TUI starts")
    noteShown(happened.ui, note)

    -- A failure once the session has started is raised, and no other UI runs
    happened = runWith(200, 20, { basalt = true }, {
      load = fakeLoader,
      expectError = true,
      app = {
        run = function(cfg)
          occode.startSession(fakeUI(), cfg)
          capture.hooks = nil
          error("broke in the session", 0)
        end,
      },
    })
    T.eq(happened.err, "broke in the session")
    T.ok(not happened.gotUI, "no TUI")
    T.ok(not happened.text:find("not available", 1, true), "no note")

    -- Ctrl+T is never a reason to fall back
    happened = runWith(200, 20, { basalt = true }, {
      load = fakeLoader,
      expectError = true,
      app = { run = function() error("Terminated", 0) end },
    })
    T.eq(happened.err, "Terminated")
    T.ok(not happened.gotUI, "no TUI after Ctrl+T")

    -- An app module without run
    happened = runWith(200, 20, { basalt = true }, { load = fakeLoader, app = {} })
    T.ok(happened.gotUI)
    T.contains(happened.text, "Basalt UI not available (cc-code.basalt.app is not the Basalt UI's app module)")
  end)

  T.test("the real Basalt UI falls back when it can't start; a later failure is raised", function()
    T.needsBasalt()
    mock.reset()
    local app = require("cc-code.basalt.app")
    -- The repository's bundle, changed by change
    local function loadWith(change)
      return {
        load = function()
          local basalt = assert(loader.load())
          change(basalt)
          return basalt
        end,
      }
    end

    -- A build the UI can't be built with: ui.init fails
    local happened = runWith(51, 19, { basalt = true }, {
      app = app, window = true,
      load = loadWith(function(basalt)
        basalt.getMainFrame = function() error("this build has no Frame", 0) end
      end),
    })
    T.ok(happened.gotUI, "the TUI ran")
    noteShown(happened.ui, "Basalt UI not available (this build has no Frame); using the standard UI.")
    T.eq(app.pump, nil, "the Basalt session ended")

    -- The session started (its welcome lines were printed), then the
    -- first drawing failed
    happened = runWith(51, 19, { basalt = true }, {
      app = app, window = true, expectError = true,
      load = loadWith(function(basalt)
        basalt.update = function() error("drawing failed", 0) end
      end),
    })
    T.eq(happened.err, "drawing failed")
    T.ok(not happened.gotUI, "no TUI")
    T.eq(app.pump, nil, "the Basalt session ended")
    T.eq(capture.hooks, nil, "hooks removed")
  end)

  T.test("Ctrl+T while Basalt downloads ends cc-code", function()
    T.raises(function()
      runWith(51, 19, { basalt = true }, { load = { load = function() error("Terminated", 0) end } })
    end, "Terminated")
    -- Other errors from the loader fall back
    local happened = runWith(200, 20, { basalt = true }, { load = { load = function() error("oops", 0) end } })
    T.eq(happened.app, nil)
    T.contains(happened.text, "Basalt UI not available (oops)")
  end)

  T.test("cc-code's options: --basalt, --tui and --terminal (the last one counts)", function()
    local configs = {}
    local savedRun, savedPath = occode.run, package.path
    occode.run = function(config) configs[#configs + 1] = config end
    local rec = capture.createTerminal(80, 60)
    local old = term.redirect(rec)
    local ok, err = pcall(function()
      local bin = assert(loadfile(T.root .. "/bin/cc-code.lua", "t", _ENV))
      bin("--basalt")
      bin("-b")
      bin("--tui")
      bin("-t")
      bin("--basalt", "--tui")
      bin("--tui", "-b", "-c")
      bin("-t", "--basalt")
      bin()
      bin("--help")
    end)
    term.redirect(old)
    occode.run, package.path = savedRun, savedPath
    if not ok then error(err, 0) end
    T.eq(#configs, 8, "--help does not run cc-code")
    T.eq(configs[1].basalt, true)
    T.eq(configs[2].basalt, true)
    T.eq(configs[3].basalt, false)
    T.eq(configs[4].forceTerminal, true)
    T.eq(configs[4].basalt, nil)
    T.eq(configs[5].basalt, false)
    T.eq(configs[6].basalt, true)
    T.eq(configs[6].monochrome, true)
    T.eq(configs[7].basalt, true)
    T.eq(configs[7].forceTerminal, nil)
    T.eq(configs[8].basalt, nil, "no option: the setting decides")
    local help = rec.getText()
    T.contains(help, "-b, --basalt")
    T.contains(help, "--tui")
    T.contains(help, "cc-code.ui")
    -- The startup file's completion offers them too
    T.contains(T.readFile(T.root .. "/install.lua"), "\"--terminal\", \"--basalt\", \"--tui\"")
  end)

  -- The pieces of the session both UIs use -------------------------------

  T.test("startSession, showResult and endSession", function()
    agent.config.model = "anthropic/claude-sonnet-4"
    local ui = fakeUI()
    local rec = capture.createTerminal(80, 20)
    local old = term.redirect(rec)
    local ok, err = pcall(function()
      occode.startSession(ui, {})
      T.eq(ui.calls[1][1], "init", "the UI is initialised first")
      T.eq(capture.hooks.before, ui.suspendTheme, "palette hooks")
      T.eq(capture.hooks.after, ui.resumeTheme)
      local names = {}
      for _, call in ipairs(ui.calls) do names[call[1]] = (names[call[1]] or 0) + 1 end
      T.eq(names.setToolDisplay, 1, "the tool display")
      T.ok((names.addCommand or 0) >= 3, "skill commands")
      T.contains(ui.printed()[1], "Welcome to cc-code")
      T.eq(ui.printed()[#ui.printed()], "", "a blank line last")

      ui.calls = {}
      occode.showResult(ui, { type = "response", text = "Hi", notice = "step limit", warnings = { "w1" } })
      T.eq(ui.calls[1][1], "printRole")
      T.eq(ui.calls[1][2], "assistant")
      T.eq(ui.calls[1][3], "Hi")
      T.eq(ui.calls[2][2], "(step limit)")
      T.eq(ui.calls[2][3], colours.grey)
      T.eq(ui.calls[3][2], "w1")
      T.eq(ui.calls[3][3], colours.red)
      T.eq(ui.calls[4][2], "")
      T.eq(#ui.calls, 4)

      ui.calls = {}
      occode.showResult(ui, { type = "response", text = "  " })
      T.eq(#ui.calls, 1, "a blank reply is not shown")

      ui.calls = {}
      occode.showResult(ui, { type = "error", text = "bad" })
      T.eq(ui.calls[1][1], "printRole")
      T.eq(ui.calls[1][2], "error")

      ui.calls = {}
      occode.showResult(ui, { type = "direct", text = "help text" })
      T.eq(ui.calls[1][2], "help text")
      T.eq(ui.calls[1][3], colours.white)

      ui.calls = {}
      occode.showResult(ui, { type = "command", command = "clear" })
      T.eq(ui.calls[1][1], "clear")
      T.eq(ui.calls[2][2], "Conversation cleared.")

      ui.calls = {}
      occode.showResult(ui, { type = "command", command = "tools", mode = "full" })
      T.eq(ui.calls[1][1], "setToolDisplay")
      T.eq(ui.calls[1][2], "full")
      T.eq(agent.state.toolDisplay, "full")
      T.contains(ui.calls[2][2], "full")

      T.ok(ui.isRunning())
      occode.showResult(ui, { type = "command", command = "exit" })
      T.ok(not ui.isRunning(), "/exit stops the UI")

      ui.calls = {}
      occode.endSession(ui)
      T.eq(capture.hooks, nil, "hooks removed")
      T.eq(ui.calls[1][1], "cleanup")
    end)
    capture.hooks = nil
    term.redirect(old)
    if not ok then error(err, 0) end
    T.contains(rec.getText(), "Goodbye!")
  end)

  T.test("turnCallbacks show the wait, the step and the tool calls", function()
    local ui = fakeUI()
    local events = {}
    ui.handleEvent = function(...) events[#events + 1] = { ... } end
    local cb = occode.turnCallbacks(ui)
    cb.onStepStart(1, 1)
    T.eq(ui.calls[1][2][1], "Thinking 0:00")
    T.eq(ui.calls[1][2][2], "Ctrl+T cancels")
    cb.onStepStart(2, 5)
    cb.onWait(61.8)
    local parts = ui.calls[#ui.calls][2]
    T.eq(parts[1], "Thinking 1:02")
    T.eq(parts[2], "step 2/5")
    cb.onEvent("mouse_scroll", 1, 2, 3)
    T.eq(events[1][1], "mouse_scroll")
    T.eq(events[1][4], 3)
    ui.calls = {}
    cb.onToolCall("grep", { pattern = "x" })
    T.eq(ui.calls[1][1], "setStatus")
    T.eq(ui.calls[1][2], "Running grep...")
    T.eq(ui.calls[2][1], "printToolCall")
    cb.onToolResult("grep", { ok = true }, { pattern = "x" })
    T.eq(ui.calls[3][1], "printToolResult")
    T.eq(ui.calls[3][2], "grep")
    -- handleEvent is optional
    ui.handleEvent = nil
    occode.turnCallbacks(ui).onEvent("char", "a")
  end)
end

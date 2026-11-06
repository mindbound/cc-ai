-- tests/test_install.lua
-- install.lua against a fake GitHub

return function(T)
  local mock = T.http
  local root = T.root
  local STARTUP = "/startup/cc-ai.lua"

  -- A trees API listing: { path, type[, size] } entries
  local function treeJson(paths)
    local entries = {}
    for _, p in ipairs(paths) do
      local size = p[3] and (",\"size\":" .. p[3]) or ""
      table.insert(entries, ("{\"path\":%q,\"type\":%q%s}"):format(p[1], p[2], size))
    end
    return "{\"sha\":\"x\",\"tree\":[" .. table.concat(entries, ",") .. "]}"
  end

  -- Routes for a repository snapshot. With a commit, the branch resolves
  -- to it and the files exist only under the commit (as when the branch
  -- URLs on raw.githubusercontent.com still serve a cached older version).
  -- Each file's listed size is its length; noSize lists files without one.
  local function setRoutes(files, commit, noSize)
    mock.reset()
    local ref = commit or "dev"
    local paths = { { "lib", "tree" }, { "README.md", "blob" }, { ".gitattributes", "blob" } }
    for path, body in pairs(files) do
      local size = not (noSize and noSize[path]) and select(2, body:find("$")) or nil
      table.insert(paths, { path, "blob", size })
      mock.routes["https://raw.githubusercontent.com/me/repo/" .. ref .. "/" .. path] = body
    end
    mock.routes["https://raw.githubusercontent.com/me/repo/" .. ref .. "/README.md"] = "readme"
    mock.routes["https://api.github.com/repos/me/repo/git/trees/" .. ref .. "?recursive=1"] = treeJson(paths)
    if commit then
      mock.routes["https://api.github.com/repos/me/repo/commits/dev"] = commit .. "\n"
    end
  end

  local COMMIT = "0123456789abcdef0123456789abcdef01234567"

  -- Run the installer in this environment so it sees the fake http
  local function runInstaller(...)
    local fn = assert(loadfile(root .. "/install.lua", "t", _ENV))
    fn(...)
  end

  -- Install me/repo (dev) into dir, with an option (--full or --minimal)
  local function install(dir, option)
    if option then
      runInstaller(option, "me/repo", "dev", dir)
    else
      runInstaller("me/repo", "dev", dir)
    end
  end

  -- Run the installer with the terminal redirected to a recording one.
  -- Returns what it printed; raises what it raised.
  local capture = require("cc-code.capture")
  local function installPrinting(dir, option)
    local rec = capture.createTerminal(200, 100)
    local old = term.redirect(rec)
    local ok, err = pcall(install, dir, option)
    term.redirect(old)
    if not ok then error(err, 0) end
    return rec.getText()
  end

  local function readVersion(dir)
    return textutils.unserialize(T.readFile(dir .. "/.version") or "")
  end

  -- Run fn with t[key] replaced by value
  local function withReplaced(t, key, value, fn)
    local saved = t[key]
    t[key] = value
    local ok, err = pcall(fn)
    t[key] = saved
    if not ok then error(err, 0) end
  end

  local savedStartup = T.readFile(STARTUP)
  local savedPath = shell.path()
  local dir = T.tmp .. "/inst"

  T.test("installer downloads the managed directories and adds a startup file", function()
    T.resetTmp()
    setRoutes({
      ["lib/ai/init.lua"] = "return {}",
      ["bin/cc-code.lua"] = "print('hi')",
      ["docs/turtle.md"] = "# Turtle API",
      ["tests/run.lua"] = "-- tests",
      ["install.lua"] = "-- installer",
    })
    install(dir)
    T.eq(T.readFile(dir .. "/install.lua"), "-- installer", "installer installs itself for updates")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return {}")
    T.eq(T.readFile(dir .. "/bin/cc-code.lua"), "print('hi')")
    T.eq(T.readFile(dir .. "/docs/turtle.md"), "# Turtle API")
    T.ok(not fs.exists(dir .. "/README.md"), "README is not installed")
    for _, req in ipairs(mock.requests) do
      if req.url:find("raw.githubusercontent", 1, true) then
        T.eq(req.binary, true, "raw files are fetched in binary mode")
      end
    end
    local startup = T.readFile(STARTUP)
    T.contains(startup, "local binDir = \"" .. dir .. "/bin\"")
    T.contains(":" .. shell.path() .. ":", ":" .. dir .. "/bin:")
  end)

  T.test("reinstalling replaces old files and doesn't duplicate the path", function()
    T.writeFile(dir .. "/lib/stale.lua", "old")
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 2 }" })
    install(dir)
    T.ok(not fs.exists(dir .. "/lib/stale.lua"), "stale file removed")
    T.ok(not fs.exists(dir .. "/bin"), "directories missing upstream are removed")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 2 }")
    local _, count = (":" .. shell.path() .. ":"):gsub(":" .. dir:gsub("%-", "%%-") .. "/bin:", "")
    T.eq(count, 1)
  end)

  T.test("a failed download leaves the previous install in place", function()
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 3 }", ["lib/ai/missing.lua"] = "x" })
    mock.routes["https://raw.githubusercontent.com/me/repo/dev/lib/ai/missing.lua"] = nil
    T.raises(function() install(dir) end, "Download failed")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 2 }")
    T.ok(not fs.exists(dir .. ".download"), "staging directory cleaned up")
  end)

  T.test("installer downloads every file from the branch's current commit", function()
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 4 }", ["install.lua"] = "-- installer" }, COMMIT)
    install(dir)
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 4 }")
    local commitRequest
    for _, req in ipairs(mock.requests) do
      if req.url:find("/commits/dev", 1, true) then
        commitRequest = req
      end
      if req.url:find("raw.githubusercontent", 1, true) then
        T.contains(req.url, "/me/repo/" .. COMMIT .. "/", "raw files by commit")
      end
    end
    T.ok(commitRequest, "the branch is resolved to a commit")
    T.eq(commitRequest.headers and commitRequest.headers.Accept, "application/vnd.github.sha")
    local info = textutils.unserialize(T.readFile(dir .. "/.version"))
    T.eq(info.commit, COMMIT)
    T.eq(info.repo, "me/repo")
    T.eq(info.branch, "dev")
  end)

  T.test("without the commit, the install goes by branch name", function()
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 5 }" })
    local out = installPrinting(dir)
    T.contains(out, "Could not look up the commit of dev (Not Found); downloading by branch name.")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 5 }")
    local info = readVersion(dir)
    T.eq(info.commit, nil)
  end)

  T.test("Ctrl+T during the commit lookup cancels the install", function()
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 6 }" }, COMMIT)
    local realGet = http.get
    local err = T.raises(function()
      withReplaced(http, "get", function(url, ...)
        if type(url) == "string" and url:find("/commits/", 1, true) then
          error("Terminated", 0)  -- what os.pullEvent raises
        end
        return realGet(url, ...)
      end, function() install(dir) end)
    end)
    T.eq(err, "Terminated")
    T.eq(#mock.requests, 0, "nothing else was requested")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 5 }", "previous install untouched")
  end)

  T.test("files the user put into the skills folder survive an update from an older installer", function()
    -- An older installer recorded no skills list: every file the new
    -- commit does not have is the user's
    setRoutes({ ["lib/cc-code/skills/help.lua"] = "-- new help", ["lib/ai/init.lua"] = "return {}" }, COMMIT)
    T.writeFile(dir .. "/lib/cc-code/skills/mine.lua", "-- my skill")
    T.writeFile(dir .. "/lib/cc-code/skills/help.lua", "-- old help")
    T.writeFile(dir .. "/.version", textutils.serialize({ repo = "me/repo", branch = "dev", commit = COMMIT }))
    local out = installPrinting(dir)
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/mine.lua"), "-- my skill", "user skill kept")
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/help.lua"), "-- new help", "repository skill updated")
    T.ok(not fs.exists(dir .. "/lib/cc-code/skills/help.lua.user"), "the old help.lua was cc-ai's")
    T.contains(out, "Kept your files in " .. dir .. "/lib/cc-code/skills: mine.lua\n")
    T.contains(out, "Move them to /.cc-code/skills, which updates never touch.")
    local info = readVersion(dir)
    T.eq(table.concat(info.skills, ","), "help.lua", "what the installer put into the skills folder")
  end)

  T.test("a skill cc-ai removed or renamed does not stay", function()
    T.resetTmp()
    setRoutes({ ["lib/cc-code/skills/help.lua"] = "-- help", ["lib/cc-code/skills/oldskill.lua"] = "-- old",
      ["lib/cc-code/skills/init.lua"] = "-- loader" }, COMMIT)
    install(dir)
    T.eq(table.concat(readVersion(dir).skills, ","), "help.lua,init.lua,oldskill.lua")
    setRoutes({ ["lib/cc-code/skills/help.lua"] = "-- help 2", ["lib/cc-code/skills/newskill.lua"] = "-- new",
      ["lib/cc-code/skills/init.lua"] = "-- loader" }, COMMIT)
    local out = installPrinting(dir)
    T.ok(not fs.exists(dir .. "/lib/cc-code/skills/oldskill.lua"), "removed upstream, so removed here")
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/newskill.lua"), "-- new")
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/help.lua"), "-- help 2")
    T.ok(not out:find("Kept your files", 1, true), "nothing reported as the user's")
    T.eq(table.concat(readVersion(dir).skills, ","), "help.lua,init.lua,newskill.lua")
  end)

  T.test("your files and folders in the skills folder are kept; a name cc-ai takes is renamed", function()
    local skillsDir = dir .. "/lib/cc-code/skills"
    T.writeFile(skillsDir .. "/mine.lua", "-- my skill")
    T.writeFile(skillsDir .. "/mylib/util.lua", "-- my util")
    T.writeFile(skillsDir .. "/tools.lua", "-- my tools")
    local files = { ["lib/cc-code/skills/help.lua"] = "-- help 3", ["lib/cc-code/skills/newskill.lua"] = "-- new",
      ["lib/cc-code/skills/tools.lua"] = "-- cc-ai tools" }
    setRoutes(files, COMMIT)
    local out = installPrinting(dir)
    T.eq(T.readFile(skillsDir .. "/mine.lua"), "-- my skill")
    T.eq(T.readFile(skillsDir .. "/mylib/util.lua"), "-- my util", "folder kept")
    T.eq(T.readFile(skillsDir .. "/tools.lua"), "-- cc-ai tools", "cc-ai's new file installed")
    T.eq(T.readFile(skillsDir .. "/tools.lua.user"), "-- my tools", "the user's file kept, renamed")
    T.contains(out, "Kept your files in " .. skillsDir .. ": mine.lua, mylib, tools.lua.user\n")
    T.contains(out, "cc-ai now has its own tools.lua, so yours is kept as tools.lua.user (it does not load as a skill).")
    T.contains(out, "Move them to /.cc-code/skills")
    T.eq(table.concat(readVersion(dir).skills, ","), "help.lua,newskill.lua,tools.lua", "only cc-ai's files")

    -- The next update keeps them as they are
    setRoutes(files, COMMIT)
    out = installPrinting(dir)
    T.eq(T.readFile(skillsDir .. "/tools.lua.user"), "-- my tools")
    T.ok(not fs.exists(skillsDir .. "/tools.lua.user2"), "not renamed again")
    T.eq(T.readFile(skillsDir .. "/mine.lua"), "-- my skill")
    T.contains(out, "Kept your files in " .. skillsDir .. ": mine.lua, mylib, tools.lua.user\n")
    T.ok(not out:find("cc-ai now has", 1, true), "no rename this time")

    -- A user file that takes a renamed file's name gets another one
    T.writeFile(skillsDir .. "/newskill.lua", "-- my newskill")
    T.writeFile(dir .. "/.version", textutils.serialize({ skills = { "help.lua", "tools.lua" } }))
    T.writeFile(skillsDir .. "/newskill.lua.user", "-- older copy")
    setRoutes(files, COMMIT)
    installPrinting(dir)
    T.eq(T.readFile(skillsDir .. "/newskill.lua.user"), "-- older copy")
    T.eq(T.readFile(skillsDir .. "/newskill.lua.user2"), "-- my newskill")
    T.eq(T.readFile(skillsDir .. "/newskill.lua"), "-- new")
  end)

  T.test("a failure while keeping your files leaves the previous install in place", function()
    local skillsDir = dir .. "/lib/cc-code/skills"
    setRoutes({ ["lib/cc-code/skills/help.lua"] = "-- help 4" }, COMMIT)
    local err = T.raises(function()
      withReplaced(fs, "copy", function() error("Out of space", 0) end, function() install(dir) end)
    end)
    T.eq(err, "Could not keep your files in " .. skillsDir .. ": Out of space")
    T.ok(not fs.exists(dir .. ".download"), "staging directory cleaned up")
    T.eq(T.readFile(skillsDir .. "/help.lua"), "-- help 3", "previous install untouched")
    T.eq(T.readFile(skillsDir .. "/mine.lua"), "-- my skill")
  end)

  -- The raw file downloads requested since the last setRoutes
  local function rawDownloads()
    local urls = {}
    for _, req in ipairs(mock.requests) do
      if req.url:find("raw.githubusercontent", 1, true) then
        table.insert(urls, req.url)
      end
    end
    return urls
  end

  local setFiles = {
    ["lib/ai/init.lua"] = "return {}",
    ["tests/run.lua"] = "-- tests",
    ["examples/hello.lua"] = "-- example",
    ["install.lua"] = "-- installer",
  }

  T.test("a minimal install is the default; --full adds tests and examples and is remembered", function()
    T.resetTmp()
    setRoutes(setFiles, COMMIT)
    local out = installPrinting(dir)
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return {}")
    T.ok(not fs.exists(dir .. "/tests"), "no tests/")
    T.ok(not fs.exists(dir .. "/examples"), "no examples/")
    T.eq(#rawDownloads(), 2, table.concat(rawDownloads(), ", "))
    T.eq(readVersion(dir).full, false)
    T.contains(out, "Installing cc-ai (minimal) from me/repo (dev) to " .. dir .. "\n")
    -- (with the repository, branch and directory: they are not the defaults)
    local where = " me/repo dev " .. dir
    T.contains(out, "Installed 2 files (minimal) from commit 0123456. Update later with: " .. dir .. "/install" .. where .. "\n")
    T.contains(out, "To install them: " .. dir .. "/install --full" .. where .. "\n")

    setRoutes(setFiles, COMMIT)
    out = installPrinting(dir, "--full")
    T.eq(T.readFile(dir .. "/tests/run.lua"), "-- tests")
    T.eq(T.readFile(dir .. "/examples/hello.lua"), "-- example")
    T.eq(readVersion(dir).full, true)
    T.contains(out, "Installed 4 files (full) from commit 0123456.")
    T.ok(not out:find("--full", 1, true), "no hint after a full install")

    -- An update without an option stays full
    setRoutes({ ["lib/ai/init.lua"] = "return {}", ["tests/run.lua"] = "-- tests 2" }, COMMIT)
    install(dir)
    T.eq(T.readFile(dir .. "/tests/run.lua"), "-- tests 2")
    T.ok(not fs.exists(dir .. "/examples"), "examples/ removed upstream, so removed here")
    T.eq(readVersion(dir).full, true)
  end)

  T.test("--minimal deletes tests and examples before the download and is remembered", function()
    setRoutes(setFiles, COMMIT)
    install(dir, "--full")
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 2 }", ["tests/run.lua"] = "-- tests" }, COMMIT)
    local during
    local realGet = http.get
    withReplaced(http, "get", function(url, ...)
      if not during and type(url) == "string" and url:find("raw.githubusercontent", 1, true) then
        during = {
          tests = fs.exists(dir .. "/tests"),
          examples = fs.exists(dir .. "/examples"),
          lib = T.readFile(dir .. "/lib/ai/init.lua"),
        }
      end
      return realGet(url, ...)
    end, function() install(dir, "--minimal") end)
    T.eq(during.tests, false, "tests/ deleted before the download")
    T.eq(during.examples, false, "examples/ deleted before the download")
    T.eq(during.lib, "return {}", "lib/ stays usable during the download")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 2 }")
    T.ok(not fs.exists(dir .. "/tests"))
    T.eq(readVersion(dir).full, false)

    -- The next update stays minimal
    setRoutes(setFiles, COMMIT)
    install(dir)
    T.ok(not fs.exists(dir .. "/tests"), "still minimal")
    T.eq(#rawDownloads(), 2)

    -- A failed download after the deletion leaves cc-code in place
    setRoutes(setFiles, COMMIT)
    install(dir, "--full")
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 3 }", ["lib/ai/missing.lua"] = "x" }, COMMIT)
    mock.routes["https://raw.githubusercontent.com/me/repo/" .. COMMIT .. "/lib/ai/missing.lua"] = nil
    T.raises(function() install(dir, "--minimal") end, "Download failed")
    T.ok(not fs.exists(dir .. "/tests"), "tests/ already deleted")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return {}", "previous lib/ in place")
    T.ok(not fs.exists(dir .. ".download"), "staging directory cleaned up")
  end)

  T.test("the options can stand anywhere among the other arguments", function()
    T.resetTmp()
    setRoutes(setFiles, COMMIT)
    runInstaller("me/repo", "--full", "dev", dir)
    T.eq(T.readFile(dir .. "/tests/run.lua"), "-- tests")
    T.eq(readVersion(dir).repo, "me/repo")
    T.eq(readVersion(dir).branch, "dev")
    setRoutes(setFiles, COMMIT)
    runInstaller("me/repo", "dev", dir, "--minimal")
    T.ok(not fs.exists(dir .. "/tests"), "minimal")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return {}")
    setRoutes(setFiles, COMMIT)
    T.raises(function() runInstaller("--fulll", "me/repo", "dev", dir) end,
      "Unknown option --fulll (use --full or --minimal)")
    T.eq(#mock.requests, 0, "nothing requested")
  end)

  T.test("the installer stops before downloading when the files won't fit", function()
    T.resetTmp()
    -- Charged as CC: Tweaked counts: files 1200 + 500 (7 bytes) + 500 (no
    -- size listed), directories lib, lib/ai, lib/ai/utils, bin and the
    -- staging directory 5 x 500: 4700 bytes
    local files = {
      ["lib/ai/init.lua"] = string.rep("x", 1200),
      ["lib/ai/utils/init.lua"] = "-- utils",
      ["bin/cc-code.lua"] = "print()",
      ["tests/run.lua"] = string.rep("t", 2000),
    }
    local noSize = { ["lib/ai/utils/init.lua"] = true }
    local asked
    local function withFree(free, fn)
      withReplaced(fs, "getFreeSpace", function(path)
        asked = path
        return free
      end, fn)
    end

    setRoutes(files, COMMIT, noSize)
    local err = T.raises(function() withFree(4699, function() install(dir) end) end)
    T.eq(err, "Not enough disk space: the minimal install needs 5 KB, but only 4 KB are free." ..
      " Free some space and run the installer again. Nothing was changed.")
    T.eq(asked, fs.getDir(dir), "the free space where the install and the staging directory go")
    T.eq(#rawDownloads(), 0, "nothing downloaded")
    T.ok(not fs.exists(dir), "nothing installed")
    T.ok(not fs.exists(dir .. ".download"), "no staging directory")

    setRoutes(files, COMMIT, noSize)
    withFree(4700, function() install(dir) end)
    T.eq(T.readFile(dir .. "/bin/cc-code.lua"), "print()", "it fits exactly")

    -- Full: also tests/ and the file in it, 2500 bytes more. The previous
    -- install stays as it was.
    setRoutes(files, COMMIT, noSize)
    err = T.raises(function() withFree(7199, function() install(dir, "--full") end) end)
    T.eq(err, "Not enough disk space: the full install needs 8 KB, but only 7 KB are free." ..
      " Free some space, or leave out the tests and examples: run the installer with --minimal." ..
      " Nothing was changed.")
    T.eq(#rawDownloads(), 0, "nothing downloaded")
    T.eq(T.readFile(dir .. "/bin/cc-code.lua"), "print()", "previous install in place")
    T.eq(readVersion(dir).full, false, "still recorded as minimal")
    setRoutes(files, COMMIT, noSize)
    withFree(7200, function() install(dir, "--full") end)
    T.eq(T.readFile(dir .. "/tests/run.lua"), string.rep("t", 2000))

    -- Back to minimal: the tests/ it deletes first (2500 bytes) count as free
    setRoutes(files, COMMIT, noSize)
    T.raises(function() withFree(2199, function() install(dir, "--minimal") end) end, "Not enough disk space")
    T.eq(T.readFile(dir .. "/tests/run.lua"), string.rep("t", 2000), "tests/ kept when stopping")
    setRoutes(files, COMMIT, noSize)
    withFree(2200, function() install(dir, "--minimal") end)
    T.ok(not fs.exists(dir .. "/tests"), "minimal now")
  end)

  T.test("the space check counts the user's files the update keeps", function()
    T.resetTmp()
    -- staging 500 + lib 500 + lib/ai 500 + the file 1200 = 2700
    local files = { ["lib/ai/init.lua"] = string.rep("x", 1200) }
    setRoutes(files, COMMIT)
    install(dir)
    -- Kept: the file (600), plus the folders lib/cc-code and
    -- lib/cc-code/skills the new install doesn't have (2 x 500): 4300
    T.writeFile(dir .. "/lib/cc-code/skills/mine.lua", string.rep("m", 600))
    local function withFree(free, fn)
      withReplaced(fs, "getFreeSpace", function() return free end, fn)
    end
    setRoutes(files, COMMIT)
    T.raises(function() withFree(4299, function() install(dir) end) end, "Not enough disk space")
    T.eq(#rawDownloads(), 0, "nothing downloaded")
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/mine.lua"), string.rep("m", 600), "nothing changed")
    setRoutes(files, COMMIT)
    withFree(4300, function() install(dir) end)
    T.eq(T.readFile(dir .. "/lib/cc-code/skills/mine.lua"), string.rep("m", 600), "kept")
  end)

  T.test("the Basalt UI's download is deleted only when the update needs its room", function()
    T.resetTmp()
    -- staging 500 + lib 500 + lib/ai 500 + the file 5000 = 6500
    local files = { ["lib/ai/init.lua"] = string.rep("x", 5000) }
    setRoutes(files, COMMIT)
    install(dir)
    -- vendor/ (500) and the bundle (1200): 1700
    local bundle = dir .. "/vendor/basalt.lua"
    T.writeFile(bundle, string.rep("b", 1200))
    local function withFree(free, fn)
      withReplaced(fs, "getFreeSpace", function() return free end, fn)
    end
    local message = "Deleted " .. bundle .. " to make room; the Basalt UI downloads it again."

    -- Fits without deleting it
    setRoutes(files, COMMIT)
    local out
    withFree(6500, function() out = installPrinting(dir) end)
    T.eq(T.readFile(bundle), string.rep("b", 1200), "kept")
    T.ok(not out:find("Deleted", 1, true), out)

    -- Doesn't fit even without it: the usual error, nothing deleted
    setRoutes(files, COMMIT)
    local err = T.raises(function() withFree(4799, function() installPrinting(dir) end) end)
    T.eq(err, "Not enough disk space: the minimal install needs 7 KB, but only 4 KB are free." ..
      " Free some space and run the installer again. Nothing was changed.")
    T.eq(#rawDownloads(), 0, "nothing downloaded")
    T.eq(T.readFile(bundle), string.rep("b", 1200), "nothing deleted")

    -- Fits only without it: deleted before the download, with a line
    setRoutes(files, COMMIT)
    local during
    local realGet = http.get
    withReplaced(http, "get", function(url, ...)
      if during == nil and type(url) == "string" and url:find("raw.githubusercontent", 1, true) then
        during = fs.exists(dir .. "/vendor")
      end
      return realGet(url, ...)
    end, function()
      withFree(4800, function() out = installPrinting(dir) end)
    end)
    T.eq(during, false, "vendor/ deleted before the download")
    T.contains(out, message .. "\n")
    T.ok(not fs.exists(dir .. "/vendor"), "vendor/ deleted")
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), string.rep("x", 5000), "installed")

    -- The entries a minimal update drops count first: vendor/ stays when
    -- they make room. (tests/: the folder 500 and the file 1500: 2000)
    local full = { ["lib/ai/init.lua"] = string.rep("x", 5000), ["tests/run.lua"] = string.rep("t", 1500) }
    setRoutes(full, COMMIT)
    install(dir, "--full")
    T.writeFile(bundle, string.rep("b", 1200))
    setRoutes(full, COMMIT)
    withFree(4500, function() out = installPrinting(dir, "--minimal") end)
    T.ok(not fs.exists(dir .. "/tests"), "minimal now")
    T.eq(T.readFile(bundle), string.rep("b", 1200), "kept: the dropped tests/ made room")
    T.ok(not out:find("Deleted", 1, true), out)
    -- ... and it goes when they are not enough
    setRoutes(full, COMMIT)
    install(dir, "--full")
    setRoutes(full, COMMIT)
    withFree(4499, function() out = installPrinting(dir, "--minimal") end)
    T.contains(out, message .. "\n")
    T.ok(not fs.exists(dir .. "/vendor"), "deleted after counting tests/")
  end)

  -- The Basalt UI's files a minimal install leaves out (cc-code downloads
  -- them when the Basalt UI is used; the loader has the list)
  local UI_FILES = require("cc-code.basalt.load").UI_FILES

  T.test("a minimal install leaves out the Basalt UI's code; a full install has it", function()
    T.resetTmp()
    local files = {
      ["lib/ai/init.lua"] = "return {}",
      ["lib/cc-code/basalt/load.lua"] = "-- loader",
      ["lib/cc-code/basalt/app.lua.orig"] = "-- not listed",
    }
    for _, rel in ipairs(UI_FILES) do
      files[rel] = "-- " .. rel
    end
    local function requested(rel)
      for _, url in ipairs(rawDownloads()) do
        if url:sub(-(select(2, rel:find("$")) + 1)) == "/" .. rel then return true end
      end
      return false
    end

    setRoutes(files, COMMIT)
    local out = installPrinting(dir)
    T.eq(T.readFile(dir .. "/lib/cc-code/basalt/load.lua"), "-- loader", "the loader is installed")
    T.eq(T.readFile(dir .. "/lib/cc-code/basalt/app.lua.orig"), "-- not listed", "by path, not by prefix")
    for _, rel in ipairs(UI_FILES) do
      T.ok(not fs.exists(dir .. "/" .. rel), rel .. " left out")
      T.ok(not requested(rel), rel .. " not downloaded")
    end
    T.contains(out, "Installed 3 files (minimal)")

    setRoutes(files, COMMIT)
    out = installPrinting(dir, "--full")
    for _, rel in ipairs(UI_FILES) do
      T.eq(T.readFile(dir .. "/" .. rel), "-- " .. rel, rel .. " in a full install")
    end
    T.contains(out, "Installed 6 files (full)")

    -- An update to a minimal install deletes them with lib/, also the ones
    -- the Basalt UI downloaded (it downloads them again, from the new commit)
    setRoutes(files, COMMIT)
    install(dir, "--minimal")
    for _, rel in ipairs(UI_FILES) do
      T.ok(not fs.exists(dir .. "/" .. rel), rel .. " deleted")
    end
    T.writeFile(dir .. "/lib/cc-code/basalt/ui.lua", "-- downloaded by cc-code")
    setRoutes(files, COMMIT)
    install(dir)
    T.ok(not fs.exists(dir .. "/lib/cc-code/basalt/ui.lua"), "a downloaded one is deleted too")
    T.eq(T.readFile(dir .. "/lib/cc-code/basalt/load.lua"), "-- loader")
  end)

  T.test("the space check counts the Basalt UI's code only in a full install", function()
    T.resetTmp()
    -- Minimal: staging, lib, lib/cc-code and lib/cc-code/basalt 4 x 500,
    -- and load.lua 1000: 3000. Full: also the UI's files, 2000 + 3000 +
    -- 500 (300 bytes): 8500.
    local files = {
      ["lib/cc-code/basalt/load.lua"] = string.rep("l", 1000),
      ["lib/cc-code/basalt/app.lua"] = string.rep("a", 2000),
      ["lib/cc-code/basalt/ui.lua"] = string.rep("u", 3000),
      ["lib/cc-code/basalt/log.lua"] = string.rep("g", 300),
    }
    local function withFree(free, fn)
      withReplaced(fs, "getFreeSpace", function() return free end, fn)
    end
    setRoutes(files, COMMIT)
    local err = T.raises(function() withFree(2999, function() install(dir) end) end)
    T.eq(err, "Not enough disk space: the minimal install needs 3 KB, but only 2 KB are free." ..
      " Free some space and run the installer again. Nothing was changed.")
    setRoutes(files, COMMIT)
    withFree(3000, function() install(dir) end)
    T.ok(fs.exists(dir .. "/lib/cc-code/basalt/load.lua"), "it fits exactly")

    setRoutes(files, COMMIT)
    err = T.raises(function() withFree(8499, function() install(dir, "--full") end) end)
    T.contains(err, "the full install needs 9 KB, but only 8 KB are free.")
    setRoutes(files, COMMIT)
    withFree(8500, function() install(dir, "--full") end)
    T.eq(T.readFile(dir .. "/lib/cc-code/basalt/log.lua"), string.rep("g", 300), "it fits exactly")
  end)

  T.test("the space check is skipped when the free space is unknown", function()
    setRoutes(setFiles, COMMIT)
    withReplaced(fs, "getFreeSpace", function() return "unlimited" end, function() install(dir) end)
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return {}")
    setRoutes({ ["lib/ai/init.lua"] = "return { v = 2 }" }, COMMIT)
    withReplaced(fs, "getFreeSpace", function() error("no such mount") end, function() install(dir) end)
    T.eq(T.readFile(dir .. "/lib/ai/init.lua"), "return { v = 2 }")
  end)

  T.test("cc-code's welcome line shows the installed commit", function()
    T.resetTmp()
    -- The real init.lua, installed: it finds .version from its own path
    setRoutes({ ["lib/cc-code/init.lua"] = T.readFile(root .. "/lib/cc-code/init.lua") }, COMMIT)
    install(dir)
    local occode = assert(loadfile(dir .. "/lib/cc-code/init.lua", "t", _ENV))()
    local plain = "v" .. occode.version
    T.eq(occode.versionText(), plain .. " (0123456)")
    T.eq(occode.installInfo().repo, "me/repo")
    local function versionWith(content)
      T.writeFile(dir .. "/.version", content)
      return occode.versionText()
    end
    T.eq(versionWith(textutils.serialize({ repo = "me/repo", branch = "dev" })), plain, "no commit")
    T.eq(versionWith(textutils.serialize({ commit = "f3e7a15-dirty" })), plain, "not a commit")
    T.eq(versionWith(textutils.serialize({ commit = 123 })), plain, "not a string")
    T.eq(versionWith("{ commit = "), plain, "garbage")
    T.eq(occode.installInfo(), nil)
    T.eq(versionWith(textutils.serialize({ commit = "ABCDEF0123" })), plain .. " (ABCDEF0)")
    fs.delete(dir .. "/.version")
    T.eq(occode.versionText(), plain, "no .version (a manual install)")
  end)

  T.test("installer fails clearly when the repository can't be listed", function()
    mock.reset()
    T.raises(function() install(dir) end, "Download failed")
  end)

  -- Restore the real startup file and shell path
  if savedStartup then
    T.writeFile(STARTUP, savedStartup)
  elseif fs.exists(STARTUP) then
    fs.delete(STARTUP)
  end
  shell.setPath(savedPath)

  -- The skills loader (lib/cc-code/skills). Each test loads its own copy
  -- of the module, so the agent's registry is not touched.
  local function freshSkills()
    return assert(loadfile(root .. "/lib/cc-code/skills/init.lua", "t", _ENV))()
  end

  -- A skill file: name, commands (a Lua list literal) and extra fields
  local function skillFile(path, name, commands, extra)
    T.writeFile(path, table.concat({
      "local skills = require('cc-code.skills')",
      "local ai = require('ai')",
      "return skills.create({ name = '" .. name .. "', commands = " .. (commands or "{}") .. ",",
      "  onActivate = function() return nil, '" .. name .. "' end,",
      extra or "",
      "})",
    }, "\n"))
  end

  local function toolLine(name, more)
    return "ai.tool({ name = '" .. name .. "', execute = function() return {} end" .. (more or "") .. " })"
  end

  local function names(list)
    local out = {}
    for _, item in ipairs(list) do
      local fn = item["function"]
      table.insert(out, fn and fn.name or item.name)
    end
    return table.concat(out, ",")
  end

  T.test("skills: the skill loaded last gets a command, and the takeover is reported", function()
    T.resetTmp()
    local builtIn, user, project = T.tmp .. "/builtin", T.tmp .. "/user", T.tmp .. "/project"
    skillFile(builtIn .. "/model.lua", "model", "{ '/model' }")
    skillFile(builtIn .. "/help.lua", "help", "{ '/help', '/?' }")
    skillFile(user .. "/zzz.lua", "zzz", "{ '/model', '/model' }")
    skillFile(user .. "/aaa.lua", "aaa", "{ '/model' }")
    skillFile(project .. "/model.lua", "model", "{ '/model', '/models' }")
    local skills = freshSkills()
    T.eq(#skills.loadFromDirectory(builtIn), 0)
    T.eq(skills.findByCommand("/model").name, "model")
    local messages = skills.loadFromDirectory(user)
    T.eq(table.concat(messages, "\n"), table.concat({
      "Skill aaa (" .. user .. "/aaa.lua) takes /model over from skill model",
      "Skill zzz (" .. user .. "/zzz.lua) takes /model over from skill aaa",
    }, "\n"))
    T.eq(skills.findByCommand("/model").name, "zzz")
    T.eq(names(skills.getAll()), "help,model,aaa,zzz", "registration order")
    -- A skill of the same name replaces the old one, and takes over from zzz
    messages = skills.loadFromDirectory(project)
    T.eq(table.concat(messages, "\n"), "Skill model (" .. project .. "/model.lua) takes /model over from skill zzz")
    T.eq(skills.findByCommand("/model").name, "model")
    T.eq(skills.findByCommand("/models").name, "model")
    T.eq(skills.findByCommand("/?").name, "help")
    T.eq(skills.findByCommand("/nope"), nil)
    T.eq(names(skills.getAll()), "help,aaa,zzz,model")
    skills.reset()
    T.eq(#skills.getAll(), 0)
  end)

  T.test("skills: unloadDirectories keeps the skills a program registered", function()
    T.resetTmp()
    skillFile(T.tmp .. "/project/farm.lua", "farm", "{ '/farm' }")
    local skills = freshSkills()
    skills.register(skills.create({ name = "own", commands = { "/own" } }))
    skills.loadFromDirectory(T.tmp .. "/project")
    T.eq(names(skills.getAll()), "own,farm")
    skills.unloadDirectories()
    T.eq(names(skills.getAll()), "own")
    T.eq(skills.findByCommand("/farm"), nil)
  end)

  T.test("skills: the winner of a command doesn't depend on the skill names", function()
    T.resetTmp()
    skillFile(T.tmp .. "/builtin/model.lua", "model", "{ '/model' }")
    for i = 1, 40 do
      local name = (i % 2 == 0 and "a" or "z") .. i
      fs.delete(T.tmp .. "/user")
      skillFile(T.tmp .. "/user/" .. name .. ".lua", name, "{ '/model' }")
      local skills = freshSkills()
      skills.loadFromDirectory(T.tmp .. "/builtin")
      skills.loadFromDirectory(T.tmp .. "/user")
      T.eq(skills.findByCommand("/model").name, name)
    end
  end)

  T.test("skills: problems are reported as complete messages", function()
    T.resetTmp()
    local d = T.tmp .. "/bad"
    T.writeFile(d .. "/syntax.lua", "return {")
    T.writeFile(d .. "/crash.lua", "error('skill bug', 0)")
    T.writeFile(d .. "/crash2.lua", "\nerror('skill bug')")
    T.writeFile(d .. "/notskill.lua", "return 42")
    local skills = freshSkills()
    local messages = skills.loadFromDirectory(d)
    T.eq(#messages, 4, table.concat(messages, "\n"))
    T.eq(messages[1], "Skill not loaded: " .. d .. "/crash.lua: skill bug")
    -- Messages that start with the path (which Lua may shorten to
    -- "...<end>") show it once, in full
    T.eq(messages[2], "Skill not loaded: " .. d .. "/crash2.lua:2: skill bug")
    T.eq(messages[3], "Skill not loaded: " .. d .. "/notskill.lua: the file did not return a skill" ..
      " (return skills.create({ name = ..., ... }))")
    T.eq(messages[4]:find("Skill not loaded: " .. d .. "/syntax.lua:1: ", 1, true), 1, messages[4])
  end)

  T.test("skills: tool lists that would give no tools or broken requests are rejected", function()
    T.resetTmp()
    local d = T.tmp .. "/tools"
    local cases = {
      { "unwrapped", "tools = " .. toolLine("t1"),
        "tools must be a list, also for one tool: write tools = { ai.tool({ ... }) }" },
      { "gap", "tools = { [1] = " .. toolLine("t1") .. ", [3] = " .. toolLine("t2") .. " }",
        "tools must be a list without gaps or names" },
      { "handbuilt", "tools = { { ['function'] = { name = 'hb', execute = function() end } } }",
        "tool 1 (hb) needs type = \"function\": make it with ai.tool({ ... })" },
      { "notool", "tools = { { name = 'x' } }",
        "tool 1 is not an ai.tool({ name, description, parameters, execute }) table" },
      { "badname", "tools = { " .. toolLine("my tool") .. " }",
        "tool 1 (my tool): the name must be 1-64 letters, digits, _ or -" },
      { "paramstring", "tools = { " .. toolLine("p1", ", parameters = 'none'") .. " }",
        "tool 1 (p1): parameters must be a table" },
      { "paramlist", "tools = { " .. toolLine("p2", ", parameters = { 'a', 'b' }") .. " }",
        "tool 1 (p2): parameters must be a schema such as" },
      { "proplist", "tools = { " .. toolLine("p3", ", parameters = { type = 'object', properties = { 'a' } }") .. " }",
        "tool 1 (p3): parameters.properties must map names to schemas" },
      { "propstring", "tools = { " .. toolLine("p4", ", parameters = { type = 'object', properties = 'a' }") .. " }",
        "tool 1 (p4): parameters.properties must be a table" },
      { "paramfn", "tools = { " .. toolLine("p5", ", parameters = { type = 'object', default = print }") .. " }",
        "tool 1 (p5): parameters can't be sent as JSON (unexpected type 'function')" },
      { "descfn", "tools = { " .. toolLine("p6", ", description = print") .. " }",
        "tool 1 (p6): description must be a string" },
    }
    for _, case in ipairs(cases) do
      skillFile(d .. "/" .. case[1] .. ".lua", case[1], nil, case[2])
    end
    -- Fine: no parameters, an empty schema, empty properties, a full schema
    skillFile(d .. "/good.lua", "good", nil, "tools = { " .. table.concat({
      toolLine("g1"),
      toolLine("g2", ", parameters = {}"),
      toolLine("g3", ", parameters = { type = 'object', properties = {} }"),
      toolLine("g4", ", description = 'x', parameters = { type = 'object', properties = { n = { type = 'number' } }, required = { 'n' } }"),
    }, ", ") .. " }")
    local skills = freshSkills()
    local messages = table.concat(skills.loadFromDirectory(d), "\n")
    for _, case in ipairs(cases) do
      T.contains(messages, "Skill not loaded: " .. d .. "/" .. case[1] .. ".lua: " .. case[3])
      T.eq(skills.get(case[1]), nil, case[1] .. " is not registered")
    end
    T.ok(not messages:find("good.lua", 1, true), messages)
    T.eq(names(skills.getAllTools()), "g1,g2,g3,g4")
  end)

  T.test("skills: tools whose name is taken are left out and reported", function()
    T.resetTmp()
    local d = T.tmp .. "/dup"
    skillFile(d .. "/a.lua", "a", nil,
      "tools = { " .. toolLine("read_file") .. ", " .. toolLine("shared") .. ", " .. toolLine("shared") .. " }")
    skillFile(d .. "/b.lua", "b", nil, "tools = { " .. toolLine("shared") .. ", " .. toolLine("b_only") .. " }")
    local skills = freshSkills()
    T.eq(#skills.loadFromDirectory(d), 0)
    local reserved = { read_file = true, shell = true }
    T.eq(names(skills.getAllTools(reserved)), "shared,b_only")
    T.eq(table.concat(skills.toolProblems(reserved), "\n"), table.concat({
      "Skill a: tool read_file is not offered: the name is already used by a built-in tool",
      "Skill a: tool shared is not offered: the name is already used by another tool of this skill",
      "Skill b: tool shared is not offered: the name is already used by skill a",
    }, "\n"))
    -- A list of names works too
    T.eq(names(skills.getAllTools({ "read_file", "shell" })), "shared,b_only")
    T.eq(#skills.toolProblems({ "read_file", "shell" }), 3)
    -- Without reserved names, only duplicates are left out
    T.eq(names(skills.getAllTools()), "read_file,shared,b_only")
    T.eq(skills.getAllTools(reserved)[1], skills.get("a").tools[2], "the first skill's tool is offered")
  end)

  T.test("the installer and the Basalt loader list the same UI files", function()
    -- install.lua runs on its own (wget), so it can't require load.lua:
    -- the two lists must be kept equal by hand, and every Basalt UI module
    -- but the loader must be in them
    local loader = require("cc-code.basalt.load")
    local source = T.readFile(T.root .. "/install.lua")
    local block = source:match("local FULL_ONLY_FILES = (%b{})")
    T.ok(block, "FULL_ONLY_FILES found in install.lua")
    local fromInstaller = {}
    for path in block:gmatch('%["([^"]+)"%]%s*=%s*true') do
      fromInstaller[#fromInstaller + 1] = path
    end
    table.sort(fromInstaller)
    local fromLoader = {}
    for i, path in ipairs(loader.UI_FILES) do
      fromLoader[i] = path
    end
    table.sort(fromLoader)
    T.eq(table.concat(fromInstaller, ","), table.concat(fromLoader, ","))
    local listed = {}
    for _, path in ipairs(fromLoader) do
      listed[path] = true
    end
    for _, name in ipairs(fs.list(T.root .. "/lib/cc-code/basalt")) do
      local path = "lib/cc-code/basalt/" .. name
      if name ~= "load.lua" then
        T.ok(listed[path], path .. " is in UI_FILES and FULL_ONLY_FILES")
      end
    end
  end)
end

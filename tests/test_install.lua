-- tests/test_install.lua
-- install.lua against a fake GitHub

return function(T)
  local mock = T.http
  local root = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
  local STARTUP = "/startup/cc-ai.lua"

  local function treeJson(paths)
    local entries = {}
    for _, p in ipairs(paths) do
      table.insert(entries, ("{\"path\":%q,\"type\":%q}"):format(p[1], p[2]))
    end
    return "{\"sha\":\"x\",\"tree\":[" .. table.concat(entries, ",") .. "]}"
  end

  local function setRoutes(files)
    mock.reset()
    local paths = { { "lib", "tree" }, { "README.md", "blob" }, { ".gitattributes", "blob" } }
    for path, body in pairs(files) do
      table.insert(paths, { path, "blob" })
      mock.routes["https://raw.githubusercontent.com/me/repo/dev/" .. path] = body
    end
    mock.routes["https://raw.githubusercontent.com/me/repo/dev/README.md"] = "readme"
    mock.routes["https://api.github.com/repos/me/repo/git/trees/dev?recursive=1"] = treeJson(paths)
  end

  -- Run the installer in this environment so it sees the fake http
  local function install(dir)
    local fn = assert(loadfile(root .. "/install.lua", "t", _ENV))
    fn("me/repo", "dev", dir)
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
    })
    install(dir)
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
end

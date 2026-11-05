-- tests/test_files.lua
-- text conversion, glob, grep and the file tools

return function(T)
  local text = require("cmn-utils.text")
  local glob = require("cmn-utils.glob")
  local grep = require("cmn-utils.grep")
  local cmnPath = require("cmn-utils.path")
  local tools = require("cc-code.tools")

  local function run(tool, args)
    return tools[tool]["function"].execute(args)
  end

  T.test("text.toCC maps UTF-8 punctuation to ASCII and Latin-1 to CC bytes", function()
    T.eq(text.toCC("plain"), "plain")
    T.eq(text.toCC("caf\195\169"), "caf\233")                   -- e-acute
    T.eq(text.toCC("a \226\128\148 b"), "a - b")                -- em dash
    T.eq(text.toCC("\226\128\156hi\226\128\157"), "\"hi\"")     -- curly quotes
    T.eq(text.toCC("ok \226\156\133"), "ok [v]")                -- check emoji
    T.eq(text.toCC("\240\159\152\128!"), "?!")                  -- unmapped emoji
    T.eq(text.toCC("a\tb\r\n"), "a  b\n")
    T.eq(text.toCC("bad \233 byte"), "bad \233 byte")           -- invalid UTF-8 kept
  end)

  T.test("text.byteLen counts bytes (with or without a unicode mod)", function()
    T.eq(text.byteLen(""), 0)
    T.eq(text.byteLen("abc"), 3)
    T.eq(text.byteLen("\226\128\148"), 3, "em dash")
    T.eq(text.byteLen("caf\195\169 \226\128\148 17 \194\176C"), 16)
    T.eq(text.byteLen("a\0b"), 3, "embedded zero")
    T.eq(text.byteLen(("x"):rep(5):sub(2) .. "yz"), 6, "derived strings (CraftOS-PC's rawlen says 0)")
  end)

  T.test("text.fromCC converts CC Latin-1 bytes to UTF-8", function()
    T.eq(text.fromCC("plain"), "plain")
    T.eq(text.fromCC("caf\233"), "caf\195\169")
    T.eq(text.fromCC("caf\195\169"), "caf\195\169")             -- already UTF-8
    T.eq(text.fromCC("box\140"), "box?")                        -- drawing char
    -- Unicode-mod input mixes both: é as one byte, an em dash as UTF-8
    T.eq(text.fromCC("caf\233\226\128\148ok"), "caf\195\169\226\128\148ok")
    T.eq(text.fromCC("a\tb\r"), "a\tb\r")
  end)

  T.test("text width/sub count cells; forDisplay depends on the unicode mod", function()
    T.vanillaOnly()
    local s = "caf\233 \226\128\148 ok"                          -- é as Latin-1, em dash as UTF-8
    -- Vanilla: one byte per cell
    T.eq(text.unicodeTerminal(), false)
    T.eq(text.width(s), 11)
    T.eq(text.sub(s, 5, 7), " \226\128")
    T.eq(text.forDisplay("a \226\128\148 b\t!\r"), "a - b  !")
    -- With the mod: one cell per character, UTF-8 is kept for display
    T.withUnicodeMod(function()
      T.eq(text.unicodeTerminal(), true)
      T.eq(text.width(s), 9)
      T.eq(text.sub(s, 5, 7), " \226\128\148 ")
      T.eq(text.sub(s, -2), "ok")
      T.eq(text.byteLen(s), 11, "byteLen is still bytes")
      T.eq(text.forDisplay("a \226\128\148 b\t!\r"), "a \226\128\148 b  !")
    end)
    T.eq(text.unicodeTerminal(), false, "simulation removed")
  end)

  T.test("json decodes UTF-8 text regardless of string length semantics", function()
    local json = require("cmn-utils.json")
    local doc = "{\"t\":\"caf\195\169 \226\128\148 17 \194\176C\",\"n\":null}"
    local v = json.decode(doc)
    T.eq(v.t, "caf\195\169 \226\128\148 17 \194\176C")
    T.eq(v.n, nil)
  end)

  T.resetTmp()
  local root = T.tmp
  T.writeFile(root .. "/startup.lua", "print('hi')\n")
  T.writeFile(root .. "/notes.txt", "Hello World\nsecond line\nhello again\n")
  T.writeFile(root .. "/lib/a.lua", "local x = 1 -- 100%\nreturn x\n")
  T.writeFile(root .. "/lib/sub/b.lua", "return 'b'\n")

  T.test("path.resolve handles absolute, relative and empty paths", function()
    T.eq(cmnPath.resolve("/a/b/../c"), "/a/c")
    T.eq(cmnPath.resolve(root .. "/lib"), root .. "/lib")
    T.eq(cmnPath.resolve(""), cmnPath.cwd())
  end)

  T.test("glob finds files, with **/ matching zero or more directories", function()
    local r = glob.find("*.lua", root)
    T.eq(table.concat(r.matches, ","), "startup.lua")
    r = glob.find("**/*.lua", root)
    T.eq(table.concat(r.matches, ","), "lib/a.lua,lib/sub/b.lua,startup.lua")
    r = glob.find("lib/**/*.lua", root)
    T.eq(table.concat(r.matches, ","), "lib/a.lua,lib/sub/b.lua")
    r = glob.find("lib/*.lua", root)
    T.eq(table.concat(r.matches, ","), "lib/a.lua")
  end)

  T.test("glob from the root skips /rom", function()
    local r = glob.find("**/motd.lua", "/")
    for _, m in ipairs(r.matches) do
      T.ok(m:sub(1, 4) ~= "rom/", "found " .. m)
    end
  end)

  T.test("grep searches with patterns, literals, globs and limits", function()
    local r = grep.search("[Hh]ello", { path = root })
    T.eq(#r.results, 2)
    T.eq(r.results[1].file, "notes.txt")
    T.eq(r.results[2].line, 3)
    r = grep.search("100%", { path = root, literal = true })
    T.eq(#r.results, 1)
    T.eq(r.results[1].file, "lib/a.lua")
    r = grep.search("return", { path = root, glob = "*.lua" })
    T.eq(#r.results, 2)
    r = grep.search("l", { path = root, maxResults = 2 })
    T.eq(#r.results, 2)
    T.eq(r.truncated, true)
    r = grep.search("(", { path = root })
    T.contains(r.error, "Invalid Lua pattern")
    -- Malformed only once a line reaches it: still a clean error
    r = grep.search("Hello[", { path = root })
    T.contains(r.error, "Invalid Lua pattern")
    T.contains(r.error, "missing ']'")
    r = grep.searchFile("line", root .. "/notes.txt")
    T.eq(#r, 1)
  end)

  T.test("grep's glob matches paths when it has a /, file names when not", function()
    local function files(r)
      local out = {}
      for _, m in ipairs(r.results) do out[#out + 1] = m.file end
      return table.concat(out, ",")
    end
    T.eq(files(grep.search("return", { path = root, glob = "**/*.lua" })), "lib/a.lua,lib/sub/b.lua")
    T.eq(files(grep.search("return", { path = root, glob = "lib/sub/*.lua" })), "lib/sub/b.lua")
    T.eq(files(grep.search("return", { path = root, glob = "lib/*.lua" })), "lib/a.lua")
    T.eq(files(grep.search("return", { path = root, glob = "b.lua" })), "lib/sub/b.lua", "name at any depth")
    T.eq(files(grep.search("return", { path = root .. "/lib/sub/b.lua", glob = "*.lua" })), "b.lua", "single file")
    T.eq(#grep.search("return", { path = root, glob = "*.txt" }).results, 0)
  end)

  T.test("globs take ./ and / prefixes, a trailing /, ? and {a,b}", function()
    local function found(pattern)
      return table.concat(glob.find(pattern, root).matches, ",")
    end
    T.eq(found("./lib/*.lua"), "lib/a.lua")
    T.eq(found("/lib/*.lua"), "lib/a.lua")
    T.eq(found("./*.lua"), "startup.lua")
    T.eq(found("lib/"), "lib/a.lua,lib/sub/b.lua", "a folder: everything under it")
    T.eq(found("*.{lua,txt}"), "notes.txt,startup.lua")
    T.eq(found("{lib,lib/sub}/*.lua"), "lib/a.lua,lib/sub/b.lua")
    T.eq(found("**/{a,b}.{lua,txt}"), "lib/a.lua,lib/sub/b.lua", "several groups")
    T.eq(found("?tartup.lua"), "startup.lua")
    T.eq(found("lib/?.lua"), "lib/a.lua")
    T.eq(found("lib?a.lua"), "", "? does not match /")
    T.eq(found("{lib}/a.lua"), "", "braces without a comma are plain text")
    T.contains(glob.find(nil, root).error, "pattern")
    -- The same globs filter grep
    local function files(r)
      local out = {}
      for _, m in ipairs(r.results) do out[#out + 1] = m.file end
      return table.concat(out, ",")
    end
    T.eq(files(grep.search("[Hh]ello", { path = root, glob = "*.{txt,md}" })), "notes.txt,notes.txt")
    T.eq(files(grep.search("return", { path = root, glob = "./lib/*.lua" })), "lib/a.lua")
    T.eq(files(grep.search("return", { path = root, glob = "lib/" })), "lib/a.lua,lib/sub/b.lua")
    T.eq(files(grep.search("return", { path = root, glob = "{lib/sub/*.lua,*.txt}" })), "lib/sub/b.lua")
    -- A path glob names files under a directory: searching one file ignores it
    local r = grep.search("return", { path = root .. "/lib/a.lua", glob = "lib/*.lua" })
    T.eq(files(r), "a.lua")
    T.eq(r.note, nil)
    -- A glob that matches no file at all says so; one that matched files doesn't
    r = grep.search("return", { path = root, glob = "*.{xyz,abc}" })
    T.eq(#r.results, 0)
    T.contains(r.note, "No file matched the glob")
    T.eq(grep.search("zzz", { path = root, glob = "*.lua" }).note, nil)
    T.contains(grep.search("return", { path = root, glob = 5 }).error, "glob must be a string")
  end)

  T.test("read_file returns numbered lines with offset and limit", function()
    local r = run("read_file", { path = root .. "/notes.txt" })
    T.eq(r.content, "   1\tHello World\n   2\tsecond line\n   3\thello again")
    T.eq(r.totalLines, 3)
    T.writeFile(root .. "/noeol.txt", "a\nb")
    r = run("read_file", { path = root .. "/noeol.txt" })
    T.eq(r.content, "   1\ta\n   2\tb")
    T.eq(r.totalLines, 2)
    fs.delete(root .. "/noeol.txt")
    r = run("read_file", { path = root .. "/notes.txt", offset = 2, limit = 1 })
    T.eq(r.content, "   2\tsecond line")
    r = run("read_file", { path = root .. "/missing" })
    T.contains(r.error, "File not found")
    r = run("read_file", { path = root .. "/lib" })
    T.contains(r.error, "directory")
  end)

  T.test("write_file creates parent directories", function()
    local r = run("write_file", { path = root .. "/new/dir/x.lua", content = "caf\195\169" })
    T.eq(r.success, true)
    T.eq(T.readFile(root .. "/new/dir/x.lua"), "caf\195\169")
    r = run("write_file", { path = "/rom/x.lua", content = "x" })
    T.contains(r.error, "read-only")
    r = run("write_file", { path = root .. "/n.txt", content = 42 })
    T.contains(r.error, "must be a string")
    T.ok(not fs.exists(root .. "/n.txt"))
  end)

  T.test("edit_file on a read-only file says so (not that the disk is full)", function()
    -- A read-only disk reports 0 bytes free, so a growing edit used to be
    -- refused for lack of space
    local romFile = "/rom/programs/fun/hello.lua"
    local content = T.readFile(romFile)
    T.ok(content, romFile .. " exists")
    local r = run("edit_file", { path = romFile, old_string = content:sub(1, 5), new_string = string.rep("x", 900) })
    T.eq(r.error, "Path is read-only: " .. romFile)
    T.eq(T.readFile(romFile), content)
  end)

  T.test("write_file and edit_file refuse the secret marker unless the file has it", function()
    local dir = root .. "/s"
    local path = dir .. "/startup.lua"
    local original = "settings.set(\"MY_API_KEY\", \"sk-abc123def456ghi\")\nprint(\"hi\")\n"
    T.writeFile(path, original)
    -- What read_file showed the model: the key as <redacted>
    local r = run("edit_file", { path = path, old_string = "settings.set(\"MY_API_KEY\", \"<redacted>\")",
      new_string = "settings.set(\"MY_API_KEY\", \"x\")" })
    T.contains(r.error, "old_string contains <redacted>")
    T.contains(r.error, "secret value")
    r = run("edit_file", { path = path, old_string = "print(\"hi\")", new_string = "print(\"<redacted>\")" })
    T.contains(r.error, "new_string contains <redacted>")
    r = run("write_file", { path = path, content = "settings.set(\"MY_API_KEY\", \"<redacted>\")\nprint(\"hello\")\n" })
    T.contains(r.error, "content contains <redacted>")
    T.contains(r.error, "edit_file")
    T.eq(T.readFile(path), original, "the key is kept")
    r = run("write_file", { path = dir .. "/new.lua", content = "local key = \"<redacted>\"\n" })
    T.contains(r.error, "<redacted>")
    T.ok(not fs.exists(dir .. "/new.lua"))
    -- The text around the secret can still be changed
    r = run("edit_file", { path = path, old_string = "print(\"hi\")", new_string = "print(\"hello\")" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "settings.set(\"MY_API_KEY\", \"sk-abc123def456ghi\")\nprint(\"hello\")\n")
    -- A file that really has the marker text (as cc-code's own source does)
    local own = dir .. "/own.lua"
    T.writeFile(own, "local MARK = \"<redacted>\"\n")
    r = run("edit_file", { path = own, old_string = "\"<redacted>\"\n", new_string = "\"<redacted>\" -- shown\n" })
    T.eq(r.replacements, 1)
    r = run("write_file", { path = own, content = "local MARK = \"<redacted>\"\nreturn MARK\n" })
    T.eq(r.success, true)
    fs.delete(dir)
  end)

  T.test("edit_file replaces unique strings and handles % literally", function()
    T.writeFile(root .. "/e.lua", "a = 1\nb = 1\nc = 2\n")
    local r = run("edit_file", { path = root .. "/e.lua", old_string = "= 1", new_string = "= 3" })
    T.contains(r.error, "2 times")
    r = run("edit_file", { path = root .. "/e.lua", old_string = "c = 2", new_string = "c = 50%" })
    T.eq(r.replacements, 1)
    r = run("edit_file", { path = root .. "/e.lua", old_string = "= 1", new_string = "= %1", replace_all = true })
    T.eq(r.replacements, 2)
    T.eq(T.readFile(root .. "/e.lua"), "a = %1\nb = %1\nc = 50%\n")
    r = run("edit_file", { path = root .. "/e.lua", old_string = "zzz", new_string = "y" })
    T.contains(r.error, "not found")
    r = run("edit_file", { path = root .. "/e.lua", old_string = "", new_string = "y", replace_all = true })
    T.contains(r.error, "must not be empty")
    T.writeFile(root .. "/o.txt", "aaa")
    r = run("edit_file", { path = root .. "/o.txt", old_string = "aa", new_string = "b" })
    T.eq(r.replacements, 1, "overlapping matches count once")
    T.eq(T.readFile(root .. "/o.txt"), "ba")
    fs.delete(root .. "/o.txt")
  end)

  T.test("edit_file matches CRLF files with plain newlines and keeps CRLF", function()
    local path = root .. "/w/crlf.lua"
    T.writeFile(path, "local a = 1\r\nlocal b = 2\r\nprint(a + b)\r\n")
    -- read_file shows the file with \n line endings
    T.eq(run("read_file", { path = path }).content, "   1\tlocal a = 1\n   2\tlocal b = 2\n   3\tprint(a + b)")
    local r = run("edit_file", { path = path, old_string = "local b = 2\nprint(a + b)\n",
      new_string = "local b = 3\nlocal c = 4\nprint(a + b + c)\n" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "local a = 1\r\nlocal b = 3\r\nlocal c = 4\r\nprint(a + b + c)\r\n")
    -- A one-line match still gets CRLF in the lines it adds
    r = run("edit_file", { path = path, old_string = "local a = 1", new_string = "local a = 1\nlocal z = 0" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "local a = 1\r\nlocal z = 0\r\nlocal b = 3\r\nlocal c = 4\r\nprint(a + b + c)\r\n")
    -- Mixed line endings: each line matches with its own ending
    T.writeFile(path, "x = 1\ny = 2\r\nz = 3\r\n")
    r = run("edit_file", { path = path, old_string = "y = 2\nz = 3", new_string = "y = 5\nz = 6" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "x = 1\ny = 5\r\nz = 6\r\n")
    r = run("edit_file", { path = path, old_string = "x = 1\ny = 5", new_string = "x = 0\ny = 5" })
    T.eq(r.replacements, 1, "plain newlines still match as written")
    T.eq(T.readFile(path), "x = 0\ny = 5\r\nz = 6\r\n")
    fs.delete(root .. "/w")
  end)

  T.test("edit_file in mixed line endings matches the text read_file shows", function()
    local path = root .. "/w/mixed.lua"
    -- A span across an LF line and CRLF lines
    T.writeFile(path, "a = 1\nb = 2\r\nc = 3\r\n")
    local r = run("edit_file", { path = path, old_string = "a = 1\nb = 2\nc = 3", new_string = "a = 0\nb = 0\nc = 0" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "a = 0\r\nb = 0\r\nc = 0\r\n", "the replaced text had CRLF, so the new text gets it")
    -- read_file shows "x\ny" twice here, once with each ending
    T.writeFile(path, "x\ny\r\nz\r\nx\r\ny\r\n")
    r = run("edit_file", { path = path, old_string = "x\ny", new_string = "X\nY" })
    T.contains(r.error, "found 2 times")
    T.eq(T.readFile(path), "x\ny\r\nz\r\nx\r\ny\r\n")
    -- replace_all: each match keeps its own line ending
    r = run("edit_file", { path = path, old_string = "x\ny", new_string = "X\nY", replace_all = true })
    T.eq(r.replacements, 2)
    T.eq(T.readFile(path), "X\nY\r\nz\r\nX\r\nY\r\n")
    -- A match without a newline: the lines it adds get the file's most common ending
    T.writeFile(path, "a\r\nb\r\nc\nd\r\n")
    r = run("edit_file", { path = path, old_string = "b", new_string = "b1\nb2" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "a\r\nb1\r\nb2\r\nc\nd\r\n")
    T.writeFile(path, "a\nb\nc\r\nd\n")
    r = run("edit_file", { path = path, old_string = "b", new_string = "b1\nb2" })
    T.eq(T.readFile(path), "a\nb1\nb2\nc\r\nd\n")
    -- A match that starts and ends at CRLF newlines takes their CRs along
    T.writeFile(path, "p\r\nq\nr\r\n")
    r = run("edit_file", { path = path, old_string = "\nq\n", new_string = "\n" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "p\r\nr\r\n")
    -- CRLF in old_string matches too (it is read as "\n")
    r = run("edit_file", { path = path, old_string = "p\r\nr", new_string = "p\nq\nr" })
    T.eq(r.replacements, 1)
    T.eq(T.readFile(path), "p\r\nq\r\nr\r\n")
    fs.delete(root .. "/w")
  end)

  T.test("a full disk never empties the file being written", function()
    local path = root .. "/w/keep.lua"
    T.writeFile(path, "original")
    local realFree = fs.getFreeSpace
    local ok, err = pcall(function()
      fs.getFreeSpace = function() return 100 end
      -- 1000 bytes in place of a file charged the 500-byte minimum: 500 more
      local r = run("write_file", { path = path, content = string.rep("x", 1000) })
      T.contains(r.error, "not enough disk space")
      T.contains(r.error, "500 more bytes, 100 are free")
      T.eq(T.readFile(path), "original")
      r = run("edit_file", { path = path, old_string = "original", new_string = string.rep("y", 900) })
      T.contains(r.error, "not enough disk space")
      T.eq(T.readFile(path), "original")
      -- Growing within the minimum file size costs nothing
      r = run("edit_file", { path = path, old_string = "original", new_string = "changed it" })
      T.eq(r.replacements, 1)
      T.eq(T.readFile(path), "changed it")
      -- A disk with no limit reports "unlimited"
      fs.getFreeSpace = function() return "unlimited" end
      r = run("write_file", { path = path, content = string.rep("z", 2000) })
      T.eq(r.success, true)
    end)
    fs.getFreeSpace = realFree
    fs.delete(root .. "/w")
    if not ok then error(err, 0) end
  end)

  T.test("tool summaries: one line per call", function()
    local view = require("cc-code.toolview")
    local function line(name, args, result)
      return (view.line(name, args, result))
    end
    T.eq(line("read_file", { path = "a.lua" }, { totalLines = 120 }), "read a.lua - 120 lines")
    T.eq(line("read_file", { path = "a.lua", offset = 10 }, { totalLines = 1 }), "read a.lua from line 10 - 1 line")
    T.eq(line("write_file", { path = "b.lua", content = "x" }, { bytesWritten = 1200 }), "write b.lua - 1.2 KB")
    T.eq(line("write_file", { path = "b.lua" }, { bytesWritten = 12 }), "write b.lua - 12 bytes")
    T.eq(line("edit_file", { path = "c.lua" }, { replacements = 2 }), "edit c.lua - 2 replacements")
    T.eq(line("list_directory", {}, { entries = { {}, {} } }), "list . - 2 entries")
    T.eq(line("glob", { pattern = "**/*.lua" }, { matches = { "a" } }), "glob **/*.lua - 1 file")
    T.eq(line("grep", { pattern = "TODO", path = "lib", glob = "*.lua" }, { results = {}, truncated = false }),
      "grep \"TODO\" in lib (*.lua) - 0 matches")
    T.eq(line("shell", { command = "mine 3" }, { success = true, output = "Mining\nDone: 12 blocks\n\n" }),
      "$ mine 3 - ok: Done: 12 blocks")
    T.eq(line("shell", { command = "x" }, { success = true, output = "(no output)" }), "$ x - ok")
    T.eq(line("shell", { command = "demo", screen = true }, { timedOut = true, screen = { size = "100x50" } }),
      "$ demo (screen) - stopped at the timeout, screen 100x50")
    local text, failed = view.line("shell", { command = "bad" }, { success = false, output = "bad.lua:3: oops" })
    T.eq(text, "$ bad - failed: bad.lua:3: oops")
    T.eq(failed, true)
    -- A failed or stopped command shows why, not the source rows the shell
    -- prints after an error ("\149" bullets and "\131" underlines are "?"
    -- in UTF-8; U+2022 is a bullet too). tests/test_agent runs real ones.
    local bullet = "\226\128\162"
    T.eq(line("shell", { command = "bad" }, { success = false,
      output = "starting\n/bad.lua:3: attempt to call nil\n  no file 'x'\n?Line 3\n?x()\n?" }),
      "$ bad - failed: /bad.lua:3: attempt to call nil")
    T.eq(line("shell", { command = "syn" }, { success = false,
      output = "Unexpected end of file.\n\n" .. bullet .. "Line 2\n" .. bullet .. "  ??\n" .. bullet .. "Block here." }),
      "$ syn - failed: Unexpected end of file.")
    T.eq(line("shell", { command = "loop" }, { cancelled = true, output = "tick 2\nTerminated\n?Line 1\n?" }),
      "$ loop - stopped (Ctrl+T): Terminated")
    T.eq(line("shell", { command = "q" }, { success = true, output = "a.lua:1: note\n? done" }), "$ q - ok: ? done",
      "a command that worked shows its last line")
    -- The reason is the group right above the context rows: a tip after
    -- them is not it, and without context rows an earlier line that looks
    -- like an error (a caught one the program printed) is not either
    T.eq(line("shell", { command = "syn" }, { success = false,
      output = "Unexpected = in expression.\n\n\149Line 2\n\149  x = = 1\n\131\nTip: Wrap the preceding expression in [ and ]." }),
      "$ syn - failed: Unexpected = in expression.")
    T.eq(line("shell", { command = "retry" }, { success = false, output = "/x.lua:1: caught\nretrying\ngiving up" }),
      "$ retry - failed: giving up")
    T.eq(line("shell", { command = "log" }, { success = false,
      output = "12:05: harvested\n/farm.lua:9: out of seeds\n?Line 9\n?" }),
      "$ log - failed: /farm.lua:9: out of seeds")
    text, failed = view.line("edit_file", { path = "c.lua" }, { error = "String not found in file" })
    T.eq(text, "edit c.lua - error: String not found in file")
    T.eq(failed, true)
    -- Newlines never break the line; unknown (skill) tools show JSON
    T.eq(view.call("shell", { command = "a\nb" }), "$ a b")
    T.eq(line("my_tool", { n = 1 }, nil), "my_tool {\"n\":1} - done", "a tool that returns nothing")
    T.eq(line("my_tool", { n = 1 }, { ok = true }), "my_tool {\"n\":1} - {\"ok\":true}")
    T.eq(line("my_tool", {}, "done"), "my_tool - done")
  end)

  T.test("list_directory lists directories first with sizes", function()
    local r = run("list_directory", { path = root })
    T.eq(r.entries[1].type, "directory")
    local names = {}
    for _, e in ipairs(r.entries) do names[#names + 1] = e.name end
    T.eq(table.concat(names, ","), "lib,new,e.lua,notes.txt,startup.lua")
    T.eq(r.entries[5].size, 12)
  end)
end

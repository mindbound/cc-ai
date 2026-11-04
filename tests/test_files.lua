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

  T.test("list_directory lists directories first with sizes", function()
    local r = run("list_directory", { path = root })
    T.eq(r.entries[1].type, "directory")
    local names = {}
    for _, e in ipairs(r.entries) do names[#names + 1] = e.name end
    T.eq(table.concat(names, ","), "lib,new,e.lua,notes.txt,startup.lua")
    T.eq(r.entries[5].size, 12)
  end)
end

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

  T.test("text.fromCC converts CC Latin-1 bytes to UTF-8", function()
    T.eq(text.fromCC("plain"), "plain")
    T.eq(text.fromCC("caf\233"), "caf\195\169")
    T.eq(text.fromCC("caf\195\169"), "caf\195\169")             -- already UTF-8
    T.eq(text.fromCC("box\140"), "box?")                        -- drawing char
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
    r = grep.searchFile("line", root .. "/notes.txt")
    T.eq(#r, 1)
  end)

  T.test("read_file returns numbered lines with offset and limit", function()
    local r = run("read_file", { path = root .. "/notes.txt" })
    T.contains(r.content, "   1\tHello World")
    T.eq(r.totalLines, 4)
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

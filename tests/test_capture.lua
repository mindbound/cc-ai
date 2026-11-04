-- tests/test_capture.lua
-- Shell command output capture and the shell tool

return function(T)
  local capture = require("cc-code.capture")
  local tools = require("cc-code.tools")

  local root = T.tmp .. "/cap"
  fs.makeDir(root)
  T.writeFile(root .. "/hello.lua", "print('Hello from ' .. (...))\nprint('line 2')\n")
  T.writeFile(root .. "/many.lua", "for i = 1, 1200 do print('row ' .. i) end\n")
  T.writeFile(root .. "/boom.lua", "print('before')\nerror('kaboom')\n")
  T.writeFile(root .. "/colour.lua", "term.setTextColour(colours.red)\nwrite('red ')\nterm.setTextColour(colours.white)\nprint('white')\nterm.setPaletteColour(colours.red, 0x000000)\n")
  T.writeFile(root .. "/clear.lua", "print('one')\nterm.clear()\nterm.setCursorPos(1, 1)\nprint('two')\n")
  fs.makeDir(root .. "/subdir")

  T.test("capture.run returns a program's printed output and arguments", function()
    local ok, out = capture.run(root .. "/hello.lua world")
    T.eq(ok, true)
    T.eq(out, "Hello from world\nline 2")
  end)

  T.test("capture.run keeps output longer than the virtual screen", function()
    local ok, out = capture.run(root .. "/many.lua")
    T.eq(ok, true)
    local count = select(2, out:gsub("\n", "\n")) + 1
    T.eq(count, 1200)
    T.contains(out, "row 1\nrow 2\n")
    T.contains(out, "row 1200")
  end)

  T.test("capture.run reports program errors as failure with the message", function()
    local ok, out = capture.run(root .. "/boom.lua")
    T.eq(ok, false)
    T.contains(out, "before")
    T.contains(out, "kaboom")
  end)

  T.test("capture.run reports unknown programs", function()
    local ok, out = capture.run("no-such-program-xyz")
    T.eq(ok, false)
    T.contains(out, "No such program")
  end)

  T.test("capture.run ignores colours and palette changes", function()
    local before = { term.getPaletteColour(colours.red) }
    local ok, out = capture.run(root .. "/colour.lua")
    T.eq(ok, true)
    T.eq(out, "red white")
    local after = { term.getPaletteColour(colours.red) }
    T.eq(after[1], before[1])
  end)

  T.test("capture.run keeps output from before term.clear()", function()
    local ok, out = capture.run(root .. "/clear.lua")
    T.eq(out, "one\ntwo")
  end)

  T.test("capture.run lists directories with ls", function()
    local ok, out = capture.run("ls " .. root)
    T.eq(ok, true)
    T.contains(out, "subdir")
    T.contains(out, "hello.lua")
  end)

  T.test("capture.run with workdir runs there and restores the directory", function()
    local before = shell.dir()
    local ok, out = capture.run("hello.lua there", root)
    T.eq(ok, true)
    T.contains(out, "Hello from there")
    T.eq(shell.dir(), before)
  end)

  T.test("cd through capture.run persists like typing it", function()
    local before = shell.dir()
    capture.run("cd " .. root)
    T.eq("/" .. shell.dir(), root)
    shell.setDir(before)
  end)

  T.test("capture.run reports Ctrl+T, and the shell tool turns it into a cancel", function()
    T.writeFile(root .. "/wait.lua", "print('waiting')\nos.pullEvent('never_happens')\n")
    os.queueEvent("terminate")
    local ok, out, terminated = capture.run(root .. "/wait.lua")
    T.eq(ok, false)
    T.eq(terminated, true)
    T.contains(out, "waiting")
    os.queueEvent("terminate")
    T.raises(function() tools.shell["function"].execute({ command = root .. "/wait.lua" }) end, "Terminated")
    local _, _, again = capture.run(root .. "/hello.lua x")
    T.eq(again, false, "no stale terminate flag")
  end)

  T.test("shell tool wraps capture and truncates long output", function()
    local r = tools.shell["function"].execute({ command = root .. "/many.lua" })
    T.eq(r.success, true)
    T.eq(r.truncated, true)
    T.eq(#r.output, 4000)
    r = tools.shell["function"].execute({ command = "hello.lua x", workdir = root })
    T.contains(r.output, "Hello from x")
  end)
end

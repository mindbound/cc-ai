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
    -- The cancel carries the output so far, which is still reported
    local ok2, err = pcall(tools.shell["function"].execute, { command = root .. "/wait.lua" })
    T.eq(ok2, false)
    T.eq(type(err), "table")
    T.eq(err.terminated, true)
    T.contains(err.result.output, "waiting")
    local _, _, again = capture.run(root .. "/hello.lua x")
    T.eq(again, false, "no stale terminate flag")
  end)

  T.test("shell tool keeps the start and the end of long output", function()
    local r = tools.shell["function"].execute({ command = root .. "/many.lua" })
    T.eq(r.success, true)
    T.eq(r.truncated, true)
    T.contains(r.output, "row 1\nrow 2\n")
    T.contains(r.output, "\nrow 1200")
    T.contains(r.output, "lines (")
    T.ok(#r.output < 4200, "about 4000 bytes kept, got " .. #r.output)
    r = tools.shell["function"].execute({ command = "hello.lua x", workdir = root })
    T.contains(r.output, "Hello from x")
    T.eq(r.truncated, nil)
  end)

  T.test("very long output keeps its first and last lines in bounded memory", function()
    T.writeFile(root .. "/huge.lua", "for i = 1, 5000 do print('n ' .. i) end\nerror('the end')\n")
    local ok, out = capture.run(root .. "/huge.lua")
    T.eq(ok, false)
    T.contains(out, "n 1\nn 2\n")
    T.contains(out, "lines left out")
    T.contains(out, "n 5000")
    T.contains(out, "the end")
  end)

  T.test("shell tool records on a wide terminal", function()
    T.writeFile(root .. "/wide.lua", "print(string.rep('1234567890', 15))\n")
    local r = tools.shell["function"].execute({ command = root .. "/wide.lua" })
    T.eq(r.output, string.rep("1234567890", 15), "150 columns on one line")
    local _, out = capture.run(root .. "/wide.lua")
    T.ok(out:find("\n"), "! commands still wrap at the screen width (at least 80)")
  end)

  T.test("shell tool stops a program that runs past its timeout", function()
    T.writeFile(root .. "/forever.lua", "while true do print('tick') sleep(0.2) end\n")
    local started = os.epoch("utc")
    local r = tools.shell["function"].execute({ command = root .. "/forever.lua", timeout = 1 })
    local took = os.epoch("utc") - started
    T.eq(r.timedOut, true)
    T.contains(r.output, "tick")
    T.contains(r.note, "stopped")
    T.ok(took < 2500, "stopped promptly, took " .. took .. " ms")
    -- The shell is usable again afterwards
    local ok, out = capture.run(root .. "/hello.lua again")
    T.eq(ok, true)
    T.eq(out, "Hello from again\nline 2")
  end)

  -- A shorter grace period keeps these tests quick
  local function withGrace(seconds, fn)
    local saved = capture.STOP_GRACE
    capture.STOP_GRACE = seconds
    local ok, err = pcall(fn)
    capture.STOP_GRACE = saved
    if not ok then error(err, 0) end
  end

  T.test("a program that ignores the stop is abandoned after a grace period", function()
    T.writeFile(root .. "/stubborn.lua", "print('stubborn')\nwhile true do os.pullEventRaw() end\n")
    withGrace(1, function()
      local r = tools.shell["function"].execute({ command = root .. "/stubborn.lua", timeout = 1 })
      T.eq(r.timedOut, true)
      T.contains(r.output, "stubborn")
      T.contains(r.note, "abandoned")
    end)
  end)

  T.test("os.pullEvent is put back after abandoning a terminate-proof program", function()
    local savedPull = os.pullEvent
    T.writeFile(root .. "/lock.lua", "os.pullEvent = os.pullEventRaw\nprint('locked')\nwhile true do os.pullEvent() end\n")
    local ok, err = pcall(withGrace, 1, function()
      local r = tools.shell["function"].execute({ command = root .. "/lock.lua", timeout = 1 })
      T.contains(r.note, "abandoned")
      T.contains(r.note, "put back")
      T.ok(os.pullEvent ~= os.pullEventRaw, "os.pullEvent restored")
      -- A normal program still stops at its timeout, without being abandoned
      r = tools.shell["function"].execute({ command = root .. "/forever.lua", timeout = 1 })
      T.eq(r.timedOut, true)
      T.ok(not r.note:find("abandoned", 1, true), r.note)
    end)
    os.pullEvent = savedPull
    if not ok then error(err, 0) end
  end)

  T.test("Ctrl+T lets a program finish its cleanup; a second Ctrl+T abandons it", function()
    T.writeFile(root .. "/tidy.lua", "pcall(function() while true do sleep(0.1) end end)\n" ..
      "print('cleaning up')\nsleep(1.5)\nprint('saved')\n")
    withGrace(1, function()
      os.queueEvent("terminate")
      local _, out, terminated, info = capture.run(root .. "/tidy.lua")
      T.eq(terminated, true)
      T.eq(info.abandoned, false, "a cleanup longer than the grace period still finishes")
      T.contains(out, "saved")
      -- A second Ctrl+T during the cleanup gives up on it
      T.writeFile(root .. "/slowtidy.lua", "pcall(function() while true do sleep(0.1) end end)\n" ..
        "print('cleaning up')\nsleep(30)\nprint('saved')\n")
      os.queueEvent("terminate")
      local started = os.epoch("utc")
      parallel.waitForAll(function()
        _, out, terminated, info = capture.run(root .. "/slowtidy.lua")
      end, function()
        -- pullEventRaw: this coroutine also sees the terminate events
        local id = os.startTimer(0.5)
        repeat
          local _, t = os.pullEventRaw("timer")
        until t == id
        os.queueEvent("terminate")
      end)
      T.eq(info.abandoned, true)
      T.contains(out, "cleaning up")
      T.ok(os.epoch("utc") - started < 3000, "abandoned at the second Ctrl+T")
    end)
  end)

  T.test("Ctrl+T then the timeout: no stray timer reaches the program", function()
    T.writeFile(root .. "/logger.lua", "local log = fs.open('" .. root .. "/events.txt', 'w')\n" ..
      "while true do local e = os.pullEventRaw() log.writeLine(e) log.flush() end\n")
    withGrace(1, function()
      os.queueEvent("terminate")
      local started = os.epoch("utc")
      local ok, err = pcall(tools.shell["function"].execute, { command = root .. "/logger.lua", timeout = 1 })
      local took = os.epoch("utc") - started
      -- The user's Ctrl+T makes the tool raise a cancel with the result
      T.eq(ok, false)
      local r = err.result
      T.eq(r.timedOut, true)
      T.contains(r.note, "abandoned")
      T.ok(took < 2700, "took " .. took .. " ms")
    end)
    sleep(1.2)
    local log = T.readFile(root .. "/events.txt") or ""
    T.ok(not log:find("timer", 1, true), "events seen: " .. log:gsub("\n", ","))
  end)

  T.test("the shell tool's note counts lines the recorder already dropped", function()
    local r = tools.shell["function"].execute({ command = root .. "/huge.lua" })
    local omitted = tonumber(r.output:match("%[%.%.%. (%d+) lines %("))
    T.ok(omitted, "note present")
    local before = tonumber(r.output:match("n (%d+)\n%[%.%.%. %d+ lines %("))
    local after = tonumber(r.output:match("bytes%) left out %.%.%.%]\nn (%d+)"))
    T.ok(before and after, "lines around the note")
    T.eq(omitted, after - before - 1, "the note's count matches the gap")
  end)

  T.test("a program's own timers and events still reach it", function()
    T.writeFile(root .. "/timers.lua", "local id = os.startTimer(0.1)\nlocal _, got = os.pullEvent('timer')\n" ..
      "print(got == id and 'own timer' or 'wrong timer')\nos.queueEvent('custom_evt', 42)\n" ..
      "local _, v = os.pullEvent('custom_evt')\nprint('custom ' .. v)\n")
    local r = tools.shell["function"].execute({ command = root .. "/timers.lua", timeout = 5 })
    T.eq(r.success, true)
    T.eq(r.output, "own timer\ncustom 42")
  end)
end

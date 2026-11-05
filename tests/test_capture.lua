-- tests/test_capture.lua
-- Shell command output capture and the shell tool

return function(T)
  local capture = require("cc-code.capture")
  local tools = require("cc-code.tools")
  local byteLen = require("cmn-utils.text").byteLen

  -- Run fn with the terminal redirected to an invisible w x h window (the
  -- screen=true terminal is the current one's size)
  local function onWindow(w, h, fn)
    local win = window.create(term.current(), 1, 1, w, h, false)
    local old = term.redirect(win)
    local ok, err = pcall(fn, win)
    term.redirect(old)
    if not ok then error(err, 0) end
    return win
  end

  -- Run fn with these settings set; they are unset afterwards
  local function withSettings(values, fn)
    for name, value in pairs(values) do
      settings.set(name, value)
    end
    local ok, err = pcall(fn)
    for name in pairs(values) do
      settings.unset(name)
    end
    if not ok then error(err, 0) end
  end

  -- Fails when any n-byte piece of secret is in str
  local function noPieces(str, secret, n)
    for i = 1, byteLen(secret) - n + 1 do
      local piece = secret:sub(i, i + n - 1)
      T.ok(not str:find(piece, 1, true), "a piece of the secret (" .. piece .. ") in: " .. str)
    end
  end

  local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

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
    T.contains(r.note, "loop forever")
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
    -- (the log is closed after each event: the abandoned program must not
    -- keep the file open, or the test files can't be deleted on Windows)
    T.writeFile(root .. "/logger.lua", "while true do local e = os.pullEventRaw()\n" ..
      "local log = fs.open('" .. root .. "/events.txt', 'a') log.writeLine(e) log.close() end\n")
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

  T.test("screen=true returns the final screen with its colours", function()
    T.writeFile(root .. "/draw.lua", table.concat({
      "term.setBackgroundColour(colours.black)",
      "term.clear()",
      "for i = 1, 30 do print('scrolled ' .. i) end",
      "term.clear()",
      "term.setCursorPos(3, 2)",
      "term.setTextColour(colours.yellow)",
      "term.write('Title')",
      "term.setCursorPos(1, 4)",
      "term.blit('ab  ', '0e00', 'fbbf')",
      "term.setPaletteColour(colours.blue, 0x000000)",
      "term.setCursorPos(1, 6)",
    }, "\n") .. "\n")
    -- The terminal the program sees is the current one's size
    local win = window.create(term.current(), 1, 1, 30, 12, false)
    local blueBefore = { win.getPaletteColour(colours.blue) }
    local old = term.redirect(win)
    local ok, r = pcall(tools.shell["function"].execute, { command = root .. "/draw.lua", screen = true })
    term.redirect(old)
    if not ok then error(r, 0) end
    T.eq(r.success, true)
    T.eq(r.output, nil)
    T.eq(r.screen.size, "30x12")
    T.eq(r.screen.text, "\n  Title\n\nab")
    T.eq(r.screen.background, "\n\n\nfbb")
    T.eq(r.screen.textColour, "\n  44444\n\n0e")
    T.contains(r.screen.colours, "4 yellow")
    -- The program set blue to black: the palette says so
    T.eq(r.screen.palette.b, "#000000")
    T.contains(r.screen.colours, "palette")
    -- The real screen was not drawn on, nor its palette changed
    T.eq((win.getLine(2):gsub(" +$", "")), "")
    T.eq(select(3, win.getPaletteColour(colours.blue)), blueBefore[3])
  end)

  T.test("screen=true: plain text has no colour rows; a stopped program's screen is kept", function()
    T.writeFile(root .. "/plain.lua", "print('just text')\n")
    local r = tools.shell["function"].execute({ command = root .. "/plain.lua", screen = true })
    T.eq(r.screen.text, "just text")
    T.eq(r.screen.background, nil)
    T.eq(r.screen.textColour, nil)
    T.eq(r.screen.colours, nil)
    -- A dashboard that clears the screen when it is stopped
    T.writeFile(root .. "/dash.lua", table.concat({
      "term.clear() term.setCursorPos(1, 1) print('Power: 42 RF')",
      "local ok = pcall(function() while true do os.sleep(0.2) end end)",
      "term.clear() term.setCursorPos(1, 1) print('bye')",
    }, "\n") .. "\n")
    r = tools.shell["function"].execute({ command = root .. "/dash.lua", screen = true, timeout = 1 })
    T.eq(r.timedOut, true)
    T.eq(r.screen.text, "Power: 42 RF")
    T.contains(r.note, "from just before the stop")
    -- A program that fails shows its error on the screen
    r = tools.shell["function"].execute({ command = root .. "/boom.lua", screen = true })
    T.eq(r.success, false)
    T.contains(r.screen.text, "kaboom")
  end)

  T.test("screen=true under the unicode mod: colours follow cells, not bytes", function()
    -- The mod's window keeps the text's bytes but one colour per cell
    local modWindow = {
      getSize = function() return 4, 1 end,
      getLine = function() return "a\195\169 b", "0400", "ffff" end,
    }
    T.withUnicodeMod(function()
      local shot = capture.snapshot(modWindow)
      T.eq(shot.text, "a\195\169 b")
      T.eq(shot.textColour, "04 0")
      T.eq(shot.background, nil)
    end)
  end)

  T.test("screen=true on vanilla CC: the text shows what the cells show", function()
    T.vanillaOnly()
    -- Vanilla CC draws each byte of a UTF-8 "°" in its own cell: "Â°"
    local vanillaWindow = {
      getSize = function() return 9, 1 end,
      getLine = function() return "T: 21\194\176C!", "eeeeeeeee", "fffffffff" end,
    }
    local shot = capture.snapshot(vanillaWindow)
    T.eq(shot.text, "T: 21\195\130\194\176C!")
    T.eq(shot.textColour, "ee eeeeee", "one colour per character of the text")
    -- Drawing characters (128-159) have no UTF-8 form
    T.eq(capture.cellText("box\140 caf\233"), "box? caf\195\169")
    -- The same through the shell tool
    T.writeFile(root .. "/degree.lua", "term.setTextColour(colours.red)\nterm.write('T: 21\\194\\176C!')\n")
    local r = tools.shell["function"].execute({ command = root .. "/degree.lua", screen = true })
    T.eq(r.screen.text, "T: 21\195\130\194\176C!")
    T.eq(r.screen.textColour, "ee eeeeee")
  end)

  T.test("screen=true on vanilla CC: a secret with UTF-8 in it is blanked as the cells show it", function()
    T.vanillaOnly()
    T.ok(not require("cmn-utils.text").unicodeTerminal(), "runs on vanilla CC")
    -- Each byte of the "é" has its own cell, so the screen text has the
    -- value in capture.cellText's form, which is not the value as set
    local value = "utf8-caf\195\169-secret-value-abc"
    T.writeFile(root .. "/showutf8.lua", "print(settings.get('ZZ_C_PASSWORD'))\n")
    local r
    withSettings({ ZZ_C_PASSWORD = value }, function()
      r = tools.shell["function"].execute({ command = root .. "/showutf8.lua", screen = true })
    end)
    noPieces(r.screen.text, capture.cellText(value), 12)
    noPieces(r.screen.text, value, 12)
    T.eq(r.screen.text, "<redacted>")
  end)

  T.test("screen=true: an empty screen says what is not captured; a drawing is not empty", function()
    T.writeFile(root .. "/nothing.lua", "local x = 1\n")
    local r = tools.shell["function"].execute({ command = root .. "/nothing.lua", screen = true })
    T.eq(r.screen.text, "(the screen is empty; output to monitors or term.native() is not captured)")
    -- A paintutils plot has no text, only background colours
    T.writeFile(root .. "/plot.lua", table.concat({
      "term.setBackgroundColour(colours.black) term.clear()",
      "paintutils.drawLine(2, 2, 20, 2, colours.red)",
      "paintutils.drawFilledBox(2, 4, 10, 6, colours.green)",
      "term.setBackgroundColour(colours.black) term.setCursorPos(1, 8)",
    }, "\n") .. "\n")
    onWindow(30, 10, function()
      r = tools.shell["function"].execute({ command = root .. "/plot.lua", screen = true })
    end)
    T.eq(r.screen.text, "(no text on the screen; the background rows show what is drawn)")
    T.eq(r.screen.background, "\nf" .. string.rep("e", 19) .. "\n\n" ..
      string.rep("f" .. string.rep("d", 9), 3, "\n"))
    T.eq(r.screen.textColour, nil)
    -- Without its colours (too big) the screen isn't called empty either
    local saved = capture.MAX_COLOUR_CELLS
    capture.MAX_COLOUR_CELLS = 0
    local ok, err = pcall(onWindow, 30, 10, function()
      r = tools.shell["function"].execute({ command = root .. "/plot.lua", screen = true })
    end)
    capture.MAX_COLOUR_CELLS = saved
    if not ok then error(err, 0) end
    T.eq(r.screen.text, "(no text on the screen)")
    T.eq(r.screen.background, nil)
    T.contains(r.screen.note, "too big")
  end)

  T.test("screen=true reports the program's palette changes, not the UI theme's", function()
    -- A parent with remapped colours, as the TUI's theme has
    T.writeFile(root .. "/redtext.lua", "term.setTextColour(colours.red)\nprint('red text')\n")
    local r
    onWindow(30, 12, function(win)
      win.setPaletteColour(colours.red, 0x123456)
      win.setPaletteColour(colours.black, 0x202020)
      r = tools.shell["function"].execute({ command = root .. "/redtext.lua", screen = true })
    end)
    T.eq(r.screen.palette, nil)
    T.eq(r.screen.textColour, "eee eeee")
    -- A program that remaps a colour: that slot is listed
    T.writeFile(root .. "/remap.lua", "term.setPaletteColour(colours.blue, 0xFF0000)\n" ..
      "term.setBackgroundColour(colours.blue)\nterm.clear()\n")
    onWindow(10, 3, function()
      r = tools.shell["function"].execute({ command = root .. "/remap.lua", screen = true })
    end)
    local slots = {}
    for slot, colour in pairs(r.screen.palette) do
      slots[#slots + 1] = slot .. "=" .. colour
    end
    T.eq(table.concat(slots, ","), "b=#ff0000")
    T.eq(r.screen.background, "bbbbbbbbbb\nbbbbbbbbbb\nbbbbbbbbbb")
    T.contains(r.screen.colours, "palette")
  end)

  T.test("a program waiting for input is reported as such at the timeout", function()
    T.writeFile(root .. "/menu.lua", "print('1) Start')\nprint('2) Quit')\nlocal _, key = os.pullEvent('key')\n")
    local r = tools.shell["function"].execute({ command = root .. "/menu.lua", timeout = 1 })
    T.eq(r.timedOut, true)
    T.contains(r.output, "1) Start\n2) Quit")
    T.contains(r.note, "waiting for input")
    T.ok(not r.note:find("loop forever", 1, true), r.note)
    -- read() waits for any event, with the cursor blinking
    T.writeFile(root .. "/ask.lua", "write('Name: ')\nlocal name = read()\nprint('Hi ' .. name)\n")
    local _, out, _, info = capture.run(root .. "/ask.lua", nil, { timeout = 1 })
    T.eq(info.timedOut, true)
    T.eq(info.waitingForInput, true)
    T.contains(out, "Name:")
    -- A loop that sleeps is not waiting for input
    _, _, _, info = capture.run(root .. "/forever.lua", nil, { timeout = 1 })
    T.eq(info.waitingForInput, false)
    -- A paged listing stops at "Press any key" on the real screen size;
    -- the screen shows that prompt
    T.writeFile(root .. "/paged.lua", "local t = {}\nfor i = 1, 40 do t[i] = 'item ' .. i end\n" ..
      "textutils.pagedPrint(table.concat(t, '\\n'))\n")
    onWindow(30, 12, function()
      r = tools.shell["function"].execute({ command = root .. "/paged.lua", screen = true, timeout = 1 })
    end)
    T.eq(r.timedOut, true)
    T.contains(r.note, "waiting for input")
    T.contains(r.note, "The screen shows what it was waiting on.")
    T.contains(r.screen.text, "Press any key to continue")
  end)

  T.test("the shell tool keeps keys and clicks from the hidden program; ! commands get them", function()
    -- A hotkey menu: a key the user presses during the run (here queued)
    -- must not choose for them
    T.writeFile(root .. "/hotkeys.lua", "print('d) delete  s) start')\n" ..
      "local _, c = os.pullEvent('char')\nprint('chose ' .. c)\n")
    os.queueEvent("char", "s")
    local r = tools.shell["function"].execute({ command = root .. "/hotkeys.lua", timeout = 1 })
    T.eq(r.timedOut, true)
    T.ok(not r.output:find("chose", 1, true), r.output)
    T.contains(r.note, "waiting for input")
    T.contains(r.note, "not passed on")
    -- A program that feeds itself input (the way to test a menu or read()
    -- without a person) still gets it; a key from outside is still dropped
    T.writeFile(root .. "/selftest.lua", "os.queueEvent('char', 'q')\n" ..
      "local _, c = os.pullEvent('char')\nprint('got ' .. c)\n")
    local realQueue = os.queueEvent
    os.queueEvent("char", "x")
    r = tools.shell["function"].execute({ command = root .. "/selftest.lua", timeout = 5 })
    T.eq(r.success, true)
    T.eq(r.output, "got q")
    T.eq(os.queueEvent, realQueue, "os.queueEvent is put back")
    -- A program waiting for another mouse event is waiting for input too
    T.writeFile(root .. "/scroll.lua", "os.pullEvent('mouse_scroll')\n")
    os.queueEvent("mouse_scroll", 1, 5, 5)
    r = tools.shell["function"].execute({ command = root .. "/scroll.lua", timeout = 1 })
    T.eq(r.timedOut, true)
    T.contains(r.note, "waiting for input")
    -- Every keyboard and mouse event is dropped; other events still arrive
    T.writeFile(root .. "/events.lua", "while true do\n  local e = os.pullEventRaw()\n" ..
      "  if e == 'zz_done' then break end\n  print('got ' .. e)\nend\n")
    local input = { "key", "key_up", "char", "paste", "mouse_click", "mouse_up", "mouse_drag", "mouse_scroll" }
    local function queueAll()
      for _, name in ipairs(input) do
        os.queueEvent(name, 1, 1, 1)
      end
      os.queueEvent("zz_custom")
      os.queueEvent("zz_done")
    end
    queueAll()
    r = tools.shell["function"].execute({ command = root .. "/events.lua", timeout = 5 })
    T.eq(r.success, true)
    T.eq(r.output, "got zz_custom")
    -- capture.run without noInput (as for !cmd) passes them on
    queueAll()
    local ok, out = capture.run(root .. "/events.lua", nil, { timeout = 5 })
    T.eq(ok, true)
    for _, name in ipairs(input) do
      T.contains(out, "got " .. name .. "\n")
    end
    T.contains(out, "got zz_custom")
    os.queueEvent("char", "s")
    ok, out = capture.run(root .. "/hotkeys.lua", nil, { timeout = 5 })
    T.eq(out, "d) delete  s) start\nchose s")
  end)

  T.test("the shell tool refuses a command with the secret marker; ! commands are not checked", function()
    -- What `set door.password` showed the model; written back, the marker
    -- would replace the password
    local password = "Tr0ub4dor&3xyz"
    local r
    withSettings({ ZZ_DOOR_PASSWORD = password }, function()
      r = tools.shell["function"].execute({ command = "set ZZ_DOOR_PASSWORD" })
      T.contains(r.output, "<redacted>")
      T.ok(not r.output:find(password, 1, true), r.output)
      r = tools.shell["function"].execute({ command = "set ZZ_DOOR_PASSWORD <redacted>" })
      T.eq(settings.get("ZZ_DOOR_PASSWORD"), password, "the password is kept")
    end)
    T.eq(r.success, nil)
    T.contains(r.error, "command contains <redacted>")
    T.contains(r.error, "secret value")
    T.contains(r.error, "ask the user")
    -- capture.run, which runs commands typed with !, runs it as typed
    local ok, out = capture.run(root .. "/hello.lua <redacted>")
    T.eq(ok, true)
    T.contains(out, "Hello from <redacted>")
  end)

  T.test("screen=true: a secret wrapped over several rows is blanked, and the rows kept", function()
    -- 110 bytes: on 30 columns, after "key: " it takes 4 rows (25, 30, 30, 25)
    local key = "sk-test-" .. (ALPHABET .. ALPHABET):sub(1, 102)
    -- Wraps at a space: the row keeps "battery" and the trailing space is trimmed
    local pass = "correct horse battery staple"
    T.writeFile(root .. "/showkey.lua", "print('key: ' .. settings.get('ZZ_TEST_API_KEY'))\n" ..
      "print('pass: ' .. settings.get('ZZ_TEST_PASSWORD'))\nprint('end')\n")
    local r, raw, redacted
    withSettings({ ZZ_TEST_API_KEY = key, ZZ_TEST_PASSWORD = pass }, function()
      onWindow(30, 12, function()
        r = tools.shell["function"].execute({ command = root .. "/showkey.lua", screen = true })
        -- The agent's own check of every tool result does the same
        local secrets = require("cc-code.secrets")
        _, raw = capture.run(root .. "/showkey.lua", nil, { screen = true })
        redacted = secrets.redact(raw, secrets.values())
      end)
    end)
    T.eq(select(2, raw:gsub("\n", "")), 6, "the screen shows 7 rows")
    T.contains(raw, "battery\nstaple", "the passphrase wrapped at its space")
    for _, text in ipairs({ r.screen.text, redacted }) do
      noPieces(text, key, 12)
      for _, word in ipairs({ "correct", "horse", "battery", "staple" }) do
        T.ok(not text:find(word, 1, true), "\"" .. word .. "\" in: " .. text)
      end
      -- Still 7 rows: the key's 4, the passphrase's 2 and "end"
      T.eq(text, "key: <redacted>\n\n\n\npass: <redacted>\n\nend")
    end
  end)

  T.test("the shell tool blanks secrets before it shortens long output", function()
    -- 200 bytes (longer than the 160-column row, so it wraps mid-word):
    -- the row before the head cut ends with only its first 8 bytes, too
    -- short to be recognised once the rest is cut away
    local key = "sk-cut-" .. ALPHABET:rep(4):sub(1, 193)
    T.writeFile(root .. "/cutkey.lua", table.concat({
      "for i = 1, 8 do print(string.rep('a', 99)) end",
      "print(string.rep('b', 151) .. ' ' .. settings.get('ZZ_TEST_API_KEY'))",
      "for i = 1, 60 do print(string.rep('c', 79)) end",
    }, "\n") .. "\n")
    local r
    withSettings({ ZZ_TEST_API_KEY = key }, function()
      r = tools.shell["function"].execute({ command = root .. "/cutkey.lua" })
    end)
    T.eq(r.truncated, true)
    T.contains(r.output, string.rep("b", 151) .. " <redacted>")
    noPieces(r.output, key, 8)
  end)
end

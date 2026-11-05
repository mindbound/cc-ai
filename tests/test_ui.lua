-- tests/test_ui.lua
-- End-to-end: the real cc-code loop in an off-screen window, driven by
-- queued key events, answering from the fake HTTP API

return function(T)
  local occode = require("cc-code")
  local agent = require("cc-code.agent")
  local capture = require("cc-code.capture")
  local mock = T.http

  settings.set("AI_GATEWAY_API_KEY", "gw-test")

  local function chat(content, toolCalls)
    return { choices = { { message = { role = "assistant", content = content, tool_calls = toolCalls }, finish_reason = toolCalls and "tool_calls" or "stop" } } }
  end

  -- Wait one tick. Uses pullEventRaw because parallel hands every queued
  -- event (including the "terminate" we send) to this coroutine too.
  local function tick()
    local id = os.startTimer(0)
    repeat
      local _, timer = os.pullEventRaw("timer")
    until timer == id
  end

  local function snapshotPalette(win)
    local p = {}
    for i = 0, 15 do
      p[i] = { win.getPaletteColour(2 ^ i) }
    end
    return p
  end

  -- cc-code's cleanup must put every palette slot back as it was
  local function expectPalette(win, before)
    local after = snapshotPalette(win)
    for i = 0, 15 do
      for k = 1, 3 do
        T.eq(after[i][k], before[i][k], "palette slot " .. i)
      end
    end
  end

  -- Ctrl+T at the prompt: CC:T sends a key event for T before the
  -- terminate (cc-code ignores a terminate without one right after a reply)
  local CTRL_T = { "ctrl-t" }

  -- Steps: a string is typed, "enter"/"tab"/... are keys, CTRL_T is Ctrl+T,
  -- a table is queued as an event, a function is called with the window
  -- (for assertions)
  local function runUI(w, h, config, steps)
    -- A model saved by an earlier /model test would replace the default
    settings.unset("cc-code.model")
    local win = window.create(term.current(), 1, 1, w, h, false)
    -- A custom palette, which cc-code must restore on exit
    win.setPaletteColour(colours.black, 0x123456)
    local paletteBefore = snapshotPalette(win)
    local old = term.redirect(win)
    local ok, err = true, nil
    local stepErr
    local finished = false
    parallel.waitForAny(function()
      ok, err = pcall(occode.run, config)
      finished = true
    end, function()
      tick()
      for _, step in ipairs(steps) do
        if step == CTRL_T then
          os.queueEvent("key", keys.leftCtrl, false)
          os.queueEvent("key", keys.t, false)
          os.queueEvent("terminate")
        elseif type(step) == "string" and keys[step] then
          os.queueEvent("key", keys[step], false)
        elseif type(step) == "string" then
          for c in step:gmatch(".") do
            os.queueEvent("char", c)
          end
        elseif type(step) == "table" then
          os.queueEvent(table.unpack(step))
        else
          local sOk, e = pcall(step, win)
          if not sOk then
            stepErr = e
            return
          end
        end
        tick()
      end
      -- Give the UI a moment to exit on its own
      for _ = 1, 20 do
        if finished then return end
        tick()
      end
    end)
    term.redirect(old)
    if stepErr then error(stepErr, 0) end
    T.ok(ok, "cc-code crashed: " .. tostring(err))
    T.ok(finished, "cc-code did not exit")
    return win, paletteBefore
  end

  local function screen(win)
    local _, h = win.getSize()
    local lines = {}
    for y = 1, h do
      lines[y] = (win.getLine(y)):gsub("%s+$", "")
    end
    return table.concat(lines, "\n")
  end

  local function expectScreen(sub)
    return function(win)
      T.contains(screen(win), sub, "screen")
    end
  end

  -- cc-code must still be running (it prints "Goodbye!" on exit)
  local function expectRunning(win)
    T.ok(not screen(win):find("Goodbye!", 1, true), "cc-code exited:\n" .. screen(win))
  end

  local function inputLine(win)
    local _, h = win.getSize()
    return (win.getLine(h)):gsub("%s+$", "")
  end

  local function count(str, sub)
    local n, pos = 0, 1
    while true do
      local s, e = str:find(sub, pos, true)
      if not s then return n end
      n = n + 1
      pos = e + 1
    end
  end

  local defaultModel = "anthropic/claude-sonnet-4"

  T.test("TUI: chat turn with a tool call, UTF-8 reply, then /exit", function()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat(nil, { { id = "c1", type = "function", ["function"] = { name = "list_directory", arguments = "{\"path\":\"/rom\"}" } } }) })
    mock.push({ body = chat("Found caf\195\169 \226\128\148 done") })
    local win, paletteBefore = runUI(51, 19, {}, {
      expectScreen("cc-code"),
      "hello", "enter",
      expectScreen("> hello"),
      expectScreen(">> list_directory"),
      expectScreen("Found caf\233 - done"),
      "/exit", "enter",
    })
    T.contains(screen(win), "Goodbye!")
    expectPalette(win, paletteBefore)
    T.eq(#mock.requests, 2)
    T.eq(capture.hooks, nil, "capture hooks cleared on exit")
  end)

  T.test("TUI: the status shows the wait, and scrolling works while waiting", function()
    mock.reset()
    mock.push({ hold = true, body = chat("Finally done") })
    runUI(51, 19, {}, {
      "/help", "enter",
      "slow question", "enter",
      expectScreen("Thinking 0:00 - step 1/25 - Ctrl+T cancels"),
      function() sleep(1.6) end,
      expectScreen("Thinking 0:01"),
      "pageUp",
      expectScreen("up]"),
      function(win)
        T.ok(not screen(win):find("> slow question", 1, true), "scrolled back over the question")
        mock.release()
      end,
      function() sleep(0.2) end,
      expectScreen("Ready"),
      { "key", keys.leftCtrl, false }, "end",
      expectScreen("Finally done"),
      "/exit", "enter",
    })
  end)

  T.test("TUI: /help is shown, history recalls the previous input", function()
    mock.reset()
    runUI(51, 19, {}, {
      "/help", "enter",
      expectScreen("API keys: exit, then run"), -- end of the help text
      "up",
      function(win)
        T.contains(inputLine(win), "/help", "input line after Up")
      end,
      "enter",
      "/exit", "enter",
    })
  end)

  T.test("TUI: '/he' + Enter completes to /help, a second Enter sends it", function()
    mock.reset()
    runUI(51, 19, {}, {
      "/he", "enter",
      function(win)
        T.eq(inputLine(win), " > /help", "input after first Enter")
        expectRunning(win)
      end,
      "enter",
      expectScreen("API keys: exit, then run"),
      "/exit", "enter",
    })
  end)

  T.test("TUI: /model <provider> <model> is sent as typed", function()
    mock.reset()
    agent.config.model = defaultModel
    runUI(51, 19, {}, {
      "/model openai gpt-4o", "enter",
      function()
        local m = agent.config.model
        T.eq(type(m), "table", "direct provider model")
        T.eq(m.provider, "openai")
        T.eq(m.modelId, "gpt-4o")
      end,
      -- Not in the completion list, only a prefix of entries in it
      "/model openai gpt-5", "enter",
      function()
        T.eq(agent.config.model.modelId, "gpt-5")
      end,
      -- Space never picks from the popup
      "/model google gemini-flash-latest", "enter",
      function()
        T.eq(agent.config.model.provider, "google")
        T.eq(agent.config.model.modelId, "gemini-flash-latest")
      end,
      "/exit", "enter",
    })
    agent.config.model = defaultModel
  end)

  T.test("TUI: Tab takes the highlighted entry, Down/Enter pick another", function()
    mock.reset()
    agent.config.model = defaultModel
    runUI(51, 19, {}, {
      "/model anth", "tab",
      function(win)
        T.eq(inputLine(win), " > /model anthropic/claude-sonnet-4", "first Tab")
        T.contains(screen(win), "Enter: pick", "popup hint after Tab")
      end,
      "down", "enter",
      function(win)
        T.eq(inputLine(win), " > /model anthropic/claude-opus-4", "Enter picks the highlight")
      end,
      "enter",
      function()
        T.eq(agent.config.model, "anthropic/claude-opus-4")
      end,
      -- First entry for "/model " is a direct provider, not a gateway model
      "/model ", "tab",
      function(win)
        T.eq(inputLine(win), " > /model google", "first /model completion")
      end,
      { "terminate" }, -- clears the input
      "/exit", "enter",
    })
    agent.config.model = defaultModel
  end)

  T.test("TUI: history Up passes over a slash command entry", function()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("first reply") })
    runUI(51, 19, {}, {
      "hello", "enter",
      expectScreen("first reply"),
      "/help", "enter",
      expectScreen("API keys: exit, then run"),
      "up",
      function(win) T.eq(inputLine(win), " > /help") end,
      "up",
      function(win) T.eq(inputLine(win), " > hello", "older prompt reached") end,
      "down",
      function(win) T.eq(inputLine(win), " > /help") end,
      { "terminate" },
      CTRL_T,
    })
  end)

  T.test("TUI: Ctrl+T at an empty prompt exits", function()
    mock.reset()
    runUI(51, 19, {}, { CTRL_T })
  end)

  T.test("TUI: a Ctrl+T left over from a reply does not exit", function()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("the reply") })
    runUI(51, 19, {}, {
      "hi", "enter",
      expectScreen("the reply"),
      { "terminate" }, -- no T key event: the user was cancelling the request
      expectRunning,
      expectScreen("the reply"),
      CTRL_T,
    })
  end)

  T.test("TUI: fits a turtle and a pocket computer screen", function()
    for _, size in ipairs({ { 39, 13 }, { 26, 20 } }) do
      mock.reset()
      mock.push({ body = chat("A reply long enough that it has to wrap over several lines on a small screen.") })
      runUI(size[1], size[2], {}, {
        "/m", "tab",
        function(win) T.contains(screen(win), "/model", "popup at " .. size[1] .. "x" .. size[2]) end,
        { "terminate" }, -- clears the input
        "hi", "enter",
        expectScreen("wrap"),
        CTRL_T,
      })
    end
  end)

  T.test("TUI: monochrome mode leaves the palette alone", function()
    mock.reset()
    runUI(51, 19, { monochrome = true }, {
      function(w)
        T.eq(w.getPaletteColour(colours.black), 0x12 / 255, "custom palette kept while running")
      end,
      CTRL_T,
    })
  end)

  T.test("TUI: shell commands run with the normal palette", function()
    mock.reset()
    local dir = T.tmp .. "/ui"
    fs.makeDir(dir)
    local probe = dir .. "/palprobe.lua"
    local out = dir .. "/palette.txt"
    if fs.exists(out) then fs.delete(out) end
    -- A program (e.g. one opening a multishell tab) sees the palette of the
    -- terminal cc-code runs on
    T.writeFile(probe, "local r = term.getPaletteColour(colours.black)\n" ..
      "local h = fs.open(" .. string.format("%q", out) .. ", 'w')\n" ..
      "h.write(string.format('%.6f', r))\nh.close()\nprint('probed')\n")
    runUI(51, 19, {}, {
      function(w)
        T.eq(w.getPaletteColour(colours.black), 0x1a / 255, "theme loaded")
      end,
      "!" .. probe, "enter",
      expectScreen("probed"),
      function(w)
        T.eq(w.getPaletteColour(colours.black), 0x1a / 255, "theme back after the command")
      end,
      "/exit", "enter",
    })
    T.eq(tonumber(T.readFile(out)), tonumber(string.format("%.6f", 0x12 / 255)), "palette during the command")
    T.eq(capture.hooks, nil, "capture hooks cleared on exit")
  end)

  T.test("terminal mode: chat turn and /exit", function()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("Terminal reply") })
    local win = runUI(51, 19, { forceTerminal = true }, {
      "hello", "enter",
      expectScreen("Terminal reply"),
      function(w)
        T.eq(count(screen(w), "> hello"), 1, "input shown once")
      end,
      "/exit", "enter",
    })
    T.contains(screen(win), "Goodbye!")
  end)

  T.test("terminal mode: /model completion", function()
    mock.reset()
    agent.config.model = defaultModel
    runUI(51, 19, { forceTerminal = true }, {
      "/model openai g", "tab", "enter",
      function(w)
        T.eq(agent.config.model.provider, "openai")
        T.eq(agent.config.model.modelId, "gpt-5.2")
        T.eq(count(screen(w), "/model openai gpt-5.2"), 1, "input shown once")
      end,
      "/model OpenAI gpt-4", "tab", "enter",
      function()
        T.eq(agent.config.model.modelId, "gpt-4o", "case-insensitive completion")
      end,
      "/mo", "tab", "enter",
      expectScreen("llama-3.3-70b-versatile"), -- end of the /model listing
      "/exit", "enter",
    })
    agent.config.model = defaultModel
  end)

  T.test("terminal mode: Ctrl+T clears typed text, quits at an empty prompt", function()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("the reply") })
    local win = runUI(51, 19, { forceTerminal = true }, {
      "abc", CTRL_T,
      expectRunning,
      "up", CTRL_T, -- recalled from history: the line is not known to be empty
      expectRunning,
      "hi", "enter",
      expectScreen("the reply"),
      { "terminate" }, -- left over from cancelling the request
      expectRunning,
      CTRL_T,
    })
    T.contains(screen(win), "Goodbye!")
  end)

  -- "CC: Tweaked Unicode Support" mod ---------------------------------------
  -- T.withUnicodeMod installs the mod's `unicode` table. The emulator's
  -- window still counts bytes, so the TUI draws into a fake window that
  -- stores one cell per character (by the mod's rules) and records writes
  -- that run past the right edge.

  local tui = require("cc-code.tui")
  local terminal = require("cc-code.terminal")
  local DASH = "\226\128\148" -- em dash, 3 bytes, 1 cell under the mod
  local EACUTE = "\195\169"   -- é in UTF-8, 2 bytes, 1 cell

  local function cellWindow(w, h)
    local t = { overflow = 0 }
    local rows, cx, cy, blink = {}, 1, 1, false
    local function blank()
      rows = {}
      for y = 1, h do
        rows[y] = {}
        for x = 1, w do rows[y][x] = " " end
      end
    end
    blank()
    function t.write(s)
      local n = unicode.len(s)
      for k = 1, n do
        local x = cx + k - 1
        if x < 1 or x > w then
          t.overflow = t.overflow + 1
        elseif cy >= 1 and cy <= h then
          rows[cy][x] = unicode.sub(s, k, k)
        end
      end
      cx = cx + n
    end
    function t.clear() blank() end
    function t.setCursorPos(x, y) cx, cy = x, y end
    function t.getCursorPos() return cx, cy end
    function t.setCursorBlink(b) blink = b end
    function t.getCursorBlink() return blink end
    function t.setVisible() end
    function t.setTextColour() end
    function t.setBackgroundColour() end
    function t.setPaletteColour() end
    function t.reposition(_, _, nw, nh)
      w, h = nw or w, nh or h
      blank()
    end
    -- Cells of row y, and the row as text without trailing spaces
    function t.cells(y) return rows[y] end
    function t.text(y) return (table.concat(rows[y]):gsub("%s+$", "")) end
    -- Content columns 2..w-1 of rows a..b joined (for text split by wrapping)
    function t.joined(a, b)
      local out = {}
      for y = a, b do
        local row = {}
        for x = 2, w - 1 do row[#row + 1] = rows[y][x] end
        out[#out + 1] = (table.concat(row):gsub("%s+$", ""))
      end
      return table.concat(out)
    end
    return t
  end

  -- Start the TUI on a w x h cell window; returns it and a cleanup function
  local function cellTUI(w, h)
    local parentWin = window.create(term.current(), 1, 1, w, h, false)
    local old = term.redirect(parentWin)
    local realWindow = window
    local cw = cellWindow(w, h)
    window = { create = function() return cw end }
    local ok, err = pcall(tui.init, {})
    window = realWindow
    if not ok then
      term.redirect(old)
      error(err, 0)
    end
    return cw, function()
      tui.cleanup()
      term.redirect(old)
    end
  end

  -- Run tui.readInput while feeding steps (as in runUI)
  local function driveRead(steps)
    local result, err, done
    parallel.waitForAny(function()
      local ok, r = pcall(tui.readInput)
      if ok then result = r else err = r end
      done = true
    end, function()
      tick()
      for _, step in ipairs(steps) do
        if done then break end
        if type(step) == "string" and keys[step] then
          os.queueEvent("key", keys[step], false)
        elseif type(step) == "string" then
          for c in step:gmatch(".") do os.queueEvent("char", c) end
        elseif type(step) == "table" then
          os.queueEvent(table.unpack(step))
        else
          step()
        end
        tick()
      end
      for _ = 1, 5 do
        if done then return end
        tick()
      end
    end)
    if err then error(err, 0) end
    T.ok(done, "readInput did not return")
    return result
  end

  -- Is every cell one complete character (no stray UTF-8 bytes)?
  local function wholeCells(cw, a, b, allowed)
    for y = a, b do
      for _, cell in ipairs(cw.cells(y)) do
        if not allowed[cell] then return false, "row " .. y .. ": " .. string.format("%q", cell) end
      end
    end
    return true
  end

  T.test("unicode mod: messages are wrapped by cell width", function()
    T.withUnicodeMod(function()
      local cw, done = cellTUI(30, 12)
      local ok, err = pcall(function()
        tui.print("na\195\175ve " .. DASH .. " caf" .. EACUTE)
        local row = cw.cells(2)
        T.eq(row[2], "n")
        T.eq(row[4], "\195\175", "i-diaeresis in one cell")
        T.eq(row[8], DASH, "em dash in one cell")
        T.eq(row[13], EACUTE, "e-acute in one cell")
        T.eq(row[14], " ", "nothing after the 12 characters")

        -- 10 words of 3 cells (6 bytes) each: 7 fit in the 28 content cells
        local word = DASH .. EACUTE .. "x"
        tui.print(string.rep(word .. " ", 10))
        T.eq(cw.text(3), " " .. string.rep(word, 7, " "), "first wrapped row")
        T.eq(cw.text(4), " " .. string.rep(word, 3, " "), "second wrapped row")

        -- A long word is split by cells, never inside a character
        tui.print(string.rep(DASH, 40))
        T.eq(cw.text(5), " " .. string.rep(DASH, 28))
        T.eq(cw.text(6), " " .. string.rep(DASH, 12))
        T.eq(cw.overflow, 0, "cells written past the right edge")
      end)
      done()
      if not ok then error(err, 0) end
    end)
  end)

  T.test("unicode mod: input is edited by cells", function()
    T.withUnicodeMod(function()
      local cw, done = cellTUI(30, 12)
      local ok, err = pcall(function()
        local seen = {}
        local res = driveRead({
          { "char", DASH }, { "char", "x" }, "left",
          function() seen.afterLeft = { cw.getCursorPos() } end,
          "backspace",
          function()
            seen.afterBackspace = { cw.getCursorPos() }
            seen.line = cw.text(12)
          end,
          -- Latin-1 arrives as one byte, other characters as UTF-8
          { "char", "\233" }, "end", { "char", DASH },
          function() seen.cursor = { cw.getCursorPos() } end,
          "enter",
        })
        T.eq(seen.afterLeft[1], 5, "cursor after Left (cell 1)")
        T.eq(seen.afterBackspace[1], 4, "cursor after Backspace (cell 0)")
        T.eq(seen.line, " > x", "Backspace removed the whole em dash")
        T.eq(seen.cursor[1], 7, "cursor after 3 characters")
        T.eq(res, "\233x" .. DASH)

        -- Ctrl+Left/Right word jumps and Delete
        res = driveRead({
          { "char", DASH }, { "char", DASH }, { "char", " " }, { "char", EACUTE }, { "char", "y" },
          "leftCtrl", "left", { "key_up", keys.leftCtrl },
          function() seen.word = { cw.getCursorPos() } end,
          "delete", "enter",
        })
        T.eq(seen.word[1], 4 + 3, "Ctrl+Left to the start of the word")
        T.eq(res, DASH .. DASH .. " y")

        -- A long line scrolls sideways inside the screen
        res = driveRead({
          function()
            for _ = 1, 40 do os.queueEvent("char", DASH) end
          end,
          function()
            seen.long = { cw.getCursorPos() }
            seen.longLine = cw.text(12)
          end,
          "enter",
        })
        T.eq(res, string.rep(DASH, 40))
        T.ok(seen.long[1] <= 29, "cursor inside the screen: " .. seen.long[1])
        T.eq(cw.overflow, 0, "cells written past the right edge")
        T.ok(wholeCells(cw, 12, 12, { [" "] = true, [">"] = true, [DASH] = true }))
      end)
      done()
      if not ok then error(err, 0) end
    end)
  end)

  T.test("unicode mod: tool previews are cut by cells", function()
    T.withUnicodeMod(function()
      local cw, done = cellTUI(51, 19)
      local ok, err = pcall(function()
        tui.printToolResult("read_file", string.rep(DASH, 300))
        -- "<< " + 197 dashes + "..." = 203 cells: rows 2-6 of 49 cells
        T.eq(cw.joined(2, 6), "<< " .. string.rep(DASH, 197) .. "...")
        T.ok(wholeCells(cw, 2, 6, { [" "] = true, ["<"] = true, ["."] = true, [DASH] = true }))

        tui.clear()
        tui.printToolCall("write_file", { text = string.rep(EACUTE, 150) })
        -- '{"text":"' is 9 cells, so 88 characters fit in the 97 before "..."
        -- "   " + 100 cells = 103: rows 3-5
        T.eq(cw.joined(3, 5), '   {"text":"' .. string.rep(EACUTE, 88) .. "...")
        T.eq(cw.overflow, 0)
      end)
      done()
      if not ok then error(err, 0) end
    end)

    -- Terminal mode cuts the same way (100 cells for results)
    T.withUnicodeMod(function()
      local rec = capture.createTerminal(400, 20)
      local old = term.redirect(rec)
      local ok, err = pcall(terminal.printToolResult, "x", string.rep(DASH, 150))
      term.redirect(old)
      if not ok then error(err, 0) end
      T.eq(rec.getText(), "<< " .. string.rep(DASH, 97) .. "...")
    end)
  end)

  T.test("unicode mod: UTF-8 is drawn as is, converted without the mod", function()
    local sample = "caf" .. EACUTE .. " " .. DASH .. " ok"
    T.withUnicodeMod(function()
      local cw, done = cellTUI(30, 12)
      local ok, err = pcall(function()
        tui.print(sample)
        T.eq(cw.text(2), " " .. sample)
        -- Streamed text: a sequence split across chunks is held back
        tui.streamText("na\195")
        tui.streamText("\175ve")
        tui.endStream()
        T.eq(cw.text(3), " na\195\175ve")
        tui.setStatus("Running " .. DASH)
        T.eq(cw.text(11), " Running " .. DASH)
      end)
      done()
      if not ok then error(err, 0) end

      local rec = capture.createTerminal(80, 20)
      local old = term.redirect(rec)
      ok, err = pcall(terminal.print, sample)
      term.redirect(old)
      if not ok then error(err, 0) end
      T.eq(rec.getText(), sample)
    end)

    -- Vanilla: converted to the CC charset
    local win = window.create(term.current(), 1, 1, 30, 12, false)
    local old = term.redirect(win)
    local ok, err = pcall(function()
      tui.init({})
      tui.print(sample)
      T.eq((win.getLine(2)):gsub("%s+$", ""), " caf\233 - ok")
      tui.cleanup()
    end)
    term.redirect(old)
    if not ok then error(err, 0) end

    local rec = capture.createTerminal(80, 20)
    old = term.redirect(rec)
    ok, err = pcall(terminal.print, sample)
    term.redirect(old)
    if not ok then error(err, 0) end
    T.eq(rec.getText(), "caf\233 - ok")
  end)
end

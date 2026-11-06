-- tests/test_basaltui.lua
-- The Basalt UI (cc-code --basalt, a trial): end to end through occode.run
-- with config.basalt = true in an off-screen window, driven by queued
-- events and answered by the fake HTTP API; and focused tests of its log
-- and tool lines. The bundle comes from the repository (/cc-ai/vendor).

return function(T)
  local occode = require("cc-code")
  local agent = require("cc-code.agent")
  local capture = require("cc-code.capture")
  local loader = require("cc-code.basalt.load")
  local app = require("cc-code.basalt.app")
  local bui = require("cc-code.basalt.ui")
  local Log = require("cc-code.basalt.log")
  local mock = T.http

  settings.set("AI_GATEWAY_API_KEY", "gw-test")
  local defaultModel = "anthropic/claude-sonnet-4"

  local DASH = "\226\128\148" -- em dash, 3 bytes, 1 cell under the mod
  local EACUTE = "\195\169"   -- e-acute in UTF-8, 2 bytes, 1 cell

  -- The events of the user: queued with os.queueEvent as it is before a
  -- session. (While a turn runs, the Basalt UI wraps os.queueEvent, and
  -- input events queued through the wrapper go to the turn only, as keys
  -- a program queues for itself.)
  local userEvent = os.queueEvent

  -- Call first in every test that loads the real bundle (vendor/basalt.lua)
  local function needsBasalt()
    if T.needsBasalt then T.needsBasalt() end
  end

  local function chat(content, toolCalls)
    return { choices = { { message = { role = "assistant", content = content, tool_calls = toolCalls }, finish_reason = toolCalls and "tool_calls" or "stop" } } }
  end

  local function toolCall(id, name, args)
    return { { id = id, type = "function", ["function"] = { name = name, arguments = textutils.serializeJSON(args) } } }
  end

  local function tick()
    local id = os.startTimer(0)
    repeat
      local _, timer = os.pullEventRaw("timer")
    until timer == id
  end

  local function snapshotPalette(t)
    local p = {}
    for i = 0, 15 do
      p[i] = { t.getPaletteColour(2 ^ i) }
    end
    return p
  end

  local function samePalette(a, b)
    for i = 0, 15 do
      for k = 1, 3 do
        if math.abs(a[i][k] - b[i][k]) > 0.002 then return false, i end
      end
    end
    return true
  end

  local function expectPalette(t, before, msg)
    local same, slot = samePalette(snapshotPalette(t), before)
    T.ok(same, (msg or "palette") .. ": slot " .. tostring(slot) .. " differs")
  end

  -- Is rgb (0xRRGGBB) in one of the palette slots?
  local function paletteHas(t, rgb)
    local r, g, b = math.floor(rgb / 65536) / 255, math.floor(rgb / 256) % 256 / 255, (rgb % 256) / 255
    for i = 0, 15 do
      local pr, pg, pb = t.getPaletteColour(2 ^ i)
      if math.abs(pr - r) + math.abs(pg - g) + math.abs(pb - b) < 0.01 then return true end
    end
    return false
  end

  local CTRL_T = { "ctrl-t" }

  -- The palette of the terminal of the running runUI before cc-code started
  local runPalette

  -- Run cc-code (Basalt UI unless config says otherwise) on a w x h
  -- off-screen window (or opts.term), feeding steps as test_ui's runUI
  -- does: strings are typed, key names pressed, CTRL_T is Ctrl+T, tables
  -- are queued events, functions are called with the terminal. With
  -- opts.expectError, returns the error cc-code raised.
  local function runUI(w, h, config, steps, opts)
    opts = opts or {}
    settings.unset("cc-code.model")
    config = config or {}
    if config.basalt == nil then config.basalt = true end
    local win = opts.term or window.create(term.current(), 1, 1, w, h, false)
    -- A custom palette, which cc-code must restore on exit
    win.setPaletteColour(colours.black, 0x123456)
    local paletteBefore = snapshotPalette(win)
    runPalette = paletteBefore
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
        if finished then break end
        if step == CTRL_T then
          userEvent("key", keys.leftCtrl, false)
          userEvent("key", keys.t, false)
          userEvent("terminate")
          userEvent("key_up", keys.t)
          userEvent("key_up", keys.leftCtrl)
        elseif type(step) == "string" and keys[step] then
          userEvent("key", keys[step], false)
        elseif type(step) == "string" then
          for c in step:gmatch(".") do
            userEvent("char", c)
          end
        elseif type(step) == "table" then
          userEvent(table.unpack(step))
        else
          local sOk, e = pcall(step, win)
          if not sOk then
            stepErr = e
            return
          end
        end
        tick()
      end
      for _ = 1, 20 do
        if finished then return end
        tick()
      end
    end)
    local current = term.current()
    term.redirect(old)
    if stepErr then error(stepErr, 0) end
    T.ok(finished, "cc-code did not exit")
    T.eq(current, win, "the terminal cc-code ran on is current again")
    if opts.expectError then
      T.ok(not ok, "cc-code should have raised an error")
      return win, paletteBefore, err
    end
    T.ok(ok, "cc-code crashed: " .. tostring(err))
    return win, paletteBefore
  end

  local function screen(t)
    local _, h = t.getSize()
    local lines = {}
    for y = 1, h do
      lines[y] = (t.getLine(y)):gsub("%s+$", "")
    end
    return table.concat(lines, "\n")
  end

  local function row(t, y)
    return ((t.getLine(y)):gsub("%s+$", ""))
  end

  local function expectScreen(sub)
    return function(t)
      T.contains(screen(t), sub, "screen")
    end
  end

  -- Wait (up to 3 seconds) until the screen shows sub. (A zero timer can
  -- fire at once in the emulator, so this counts time, not ticks.)
  local function waitScreen(sub)
    return function(t)
      local deadline = os.epoch("utc") + 3000
      repeat
        if screen(t):find(sub, 1, true) then return end
        tick()
      until os.epoch("utc") > deadline
      T.contains(screen(t), sub, "screen")
    end
  end

  local function expectRunning(t)
    T.ok(not screen(t):find("Goodbye!", 1, true), "cc-code exited:\n" .. screen(t))
  end

  -- The Basalt UI (not the TUI it falls back to) is running
  local function expectBasalt()
    T.ok(app.pump ~= nil, "the Basalt UI is running")
  end

  local function inputLine(t)
    local _, h = t.getSize()
    return row(t, h)
  end

  -- Width of a screen row in cells
  local cells = require("cmn-utils.text").width

  local function count(str, sub)
    local n, pos = 0, 1
    while true do
      local s, e = str:find(sub, pos, true)
      if not s then return n end
      n = n + 1
      pos = e + 1
    end
  end

  -- All rows of the conversation, also those scrolled off the screen
  local function logText()
    local out = {}
    for i, r in ipairs(bui.inspect().log.rows) do
      out[i] = r.text or ""
    end
    return table.concat(out, "\n")
  end

  -- The prompts shown in the conversation ("> ..." rows), joined by "|"
  local function shownPrompts()
    local out = {}
    for _, r in ipairs(bui.inspect().log.rows) do
      if (r.text or ""):sub(1, 2) == "> " then out[#out + 1] = r.text end
    end
    return table.concat(out, "|")
  end

  -- The text of the last user message the model was sent
  local function lastPrompt(req)
    local messages = req and req.json and req.json.messages or {}
    for i = #messages, 1, -1 do
      if messages[i].role == "user" then return messages[i].content end
    end
  end

  T.test("Basalt UI: chat turn with a tool call, then the reply and /exit", function()
    needsBasalt()
    T.vanillaOnly()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat(nil, toolCall("c1", "list_directory", { path = "/rom" })) })
    mock.push({ body = chat("Found caf" .. EACUTE .. " " .. DASH .. " done") })
    local win, paletteBefore = runUI(51, 19, {}, {
      expectBasalt,
      expectScreen("cc-code"),
      expectScreen("/help | PgUp/PgDn to scroll | /exit"),
      expectScreen("Welcome to cc-code"),
      function(t) T.eq(inputLine(t), " >", "empty input line") end,
      "hello", "enter",
      expectScreen("> hello"),
      waitScreen("* list /rom - "),
      waitScreen("Found caf\233 - done"),
      function(t)
        -- One row per call, completed in place
        T.eq(count(screen(t), "list /rom"), 1, "the call's row")
        T.contains(screen(t), "Ready")
      end,
      "/exit", "enter",
    })
    T.contains(screen(win), "Goodbye!")
    T.eq(row(win, 1), "Goodbye!", "the goodbye is on a clean screen")
    expectPalette(win, paletteBefore, "palette after exit")
    T.eq(#mock.requests, 2)
    T.eq(capture.hooks, nil, "capture hooks cleared on exit")
    T.eq(app.pump, nil, "the session ended")
  end)

  T.test("Basalt UI: the status shows the wait; scrolling works while waiting", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("Finally done") })
    runUI(51, 19, {}, {
      "/help", "enter",
      waitScreen(".cc-code/skills (this directory)"),
      "slow question", "enter",
      waitScreen("Thinking 0:00 - step 1/25 - Ctrl+T cancels"),
      function() sleep(1.6) end,
      expectScreen("Thinking 0:01"),
      "pageUp",
      -- (the long "[Scroll: 5 lines up]" would crowd the status)
      expectScreen("[5 up]"),
      function(t)
        T.ok(not screen(t):find("> slow question", 1, true), "scrolled back over the question")
      end,
      { "mouse_scroll", -1, 10, 10 },
      expectScreen("[8 up]"),
      { "mouse_scroll", 1, 10, 10 },
      expectScreen("[5 up]"),
      function() mock.release() end,
      waitScreen("Ready"),
      function(t)
        -- The view stayed where it was while the reply came in
        T.ok(not screen(t):find("Finally done", 1, true), "the reply is below the view")
      end,
      { "key", keys.leftCtrl, false }, "end", { "key_up", keys.leftCtrl },
      expectScreen("Finally done"),
      function(t) T.ok(not screen(t):find("up]", 1, true), "back at the bottom") end,
      "/exit", "enter",
    })
  end)

  T.test("Basalt UI: a prompt typed during a turn is queued and sent after it", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("reply one") })
    mock.push({ body = chat("reply two") })
    runUI(51, 19, {}, {
      "first", "enter",
      waitScreen("Thinking"),
      "sec",
      function(t) T.eq(inputLine(t), " > sec", "typed during the turn") end,
      "ond", "enter",
      function(t)
        T.eq(inputLine(t), " >", "the input is free again")
        T.contains(screen(t), "[1 queued]", "status")
        T.eq(#mock.requests, 1, "not sent yet")
      end,
      function() mock.release() end,
      waitScreen("reply two"),
      function(t)
        local s = screen(t)
        T.ok(s:find("reply one", 1, true) < s:find("> second", 1, true), "sent after the first reply")
        T.ok(not s:find("queued]", 1, true), "nothing queued any more")
        T.eq(#mock.requests, 2)
        T.eq(lastPrompt(mock.requests[2]), "second")
      end,
      "up",
      function(t) T.eq(inputLine(t), " > second", "the queued prompt is in the history") end,
      { "terminate" },
      CTRL_T,
    })
  end)

  T.test("Basalt UI: after a queued prompt that ends at once, the next starts without another event", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("reply one") })
    mock.push({ body = chat("reply two") })
    local realProcess = agent.process
    local starts = {}
    agent.process = function(line, ...)
      starts[#starts + 1] = { line = line, at = os.epoch("utc") }
      return realProcess(line, ...)
    end
    local ok, err = pcall(runUI, 51, 19, {}, {
      "first", "enter",
      waitScreen("Thinking"),
      "/help", "enter",
      "q2", "enter",
      expectScreen("[2 queued]"),
      function(t)
        mock.release()
        -- Nothing else happens for a while (runUI's steps wait on timers,
        -- which the pump sees too): the turns' own events must be enough
        local id = os.startTimer(1.5)
        repeat
          local _, timer = os.pullEventRaw("timer")
        until timer == id
        local s = screen(t)
        T.contains(s, "reply two", "the second queued prompt ran")
        T.ok(not s:find("queued]", 1, true), "nothing queued any more")
        local all = logText()
        local one, help, q2 = all:find("reply one", 1, true), all:find(".cc-code/skills (this directory)", 1, true), all:find("> q2", 1, true)
        T.ok(one and help and q2 and one < help and help < q2, "first, /help, q2 in order:\n" .. all)
      end,
      "/exit", "enter",
    })
    agent.process = realProcess
    if not ok then error(err, 0) end
    T.eq(#starts, 4, "first, /help, q2, /exit")
    T.eq(starts[2].line, "/help")
    T.eq(starts[3].line, "q2")
    T.ok(starts[3].at - starts[2].at < 700, "q2 started " .. (starts[3].at - starts[2].at) .. " ms after /help")
    T.eq(#mock.requests, 2)
    T.eq(lastPrompt(mock.requests[2]), "q2")
  end)

  T.test("Basalt UI: Ctrl+T while a queued prompt waits keeps it unsent", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("too late") })
    runUI(51, 19, {}, {
      "first", "enter",
      waitScreen("Thinking"),
      "later", "enter",
      expectScreen("[1 queued]"),
      CTRL_T,
      waitScreen("Request cancelled (Ctrl+T)."),
      expectScreen("(The queued prompt was not sent.)"),
      function(t)
        T.eq(inputLine(t), " > later", "back in the input line")
        T.eq(#mock.requests, 1, "nothing else was sent")
        expectRunning(t)
      end,
      { "terminate" }, -- clears the line
      function(t) T.eq(inputLine(t), " >") end,
      CTRL_T,
    })
  end)

  T.test("Basalt UI: Ctrl+T cancels a waiting turn, then exits at an empty prompt", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("too late") })
    local late
    local win = runUI(51, 19, {}, {
      "hi", "enter",
      waitScreen("Thinking"),
      CTRL_T,
      waitScreen("Error: Request cancelled (Ctrl+T)."),
      expectRunning,
      function() late = mock.release() end,
      function()
        T.ok(late.closed, "the late reply was closed unread")
      end,
      expectRunning,
      expectScreen("Ready"),
      CTRL_T,
    })
    T.contains(screen(win), "Goodbye!")
  end)

  T.test("Basalt UI: a Ctrl+T left over from a reply does not exit", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("the reply") })
    mock.push({ hold = true, body = chat("first of two") })
    mock.push({ body = chat("second of two") })
    runUI(51, 19, {}, {
      "hi", "enter",
      waitScreen("the reply"),
      { "terminate" }, -- no T key: the user was cancelling the request
      expectRunning,
      expectScreen("the reply"),
      -- The same for a queued prompt that just started
      "uno", "enter",
      waitScreen("Thinking"),
      "dos", "enter",
      function()
        mock.release()
        userEvent("terminate")
      end,
      waitScreen("second of two"),
      function(t) T.ok(not screen(t):find("cancelled", 1, true), "the queued turn ran") end,
      CTRL_T,
    })
  end)

  T.test("Basalt UI: Tab takes the highlighted entry, Down/Enter pick another", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    runUI(51, 19, {}, {
      "/he",
      expectScreen("Commands:"),
      expectScreen("Tab: complete"),
      "enter",
      function(t)
        T.eq(inputLine(t), " > /help", "'/he' + Enter completes")
        T.ok(not screen(t):find("Commands:", 1, true), "popup closed")
      end,
      { "terminate" },
      "/model anth", "tab",
      function(t)
        T.eq(inputLine(t), " > /model anthropic/claude-sonnet-4", "first Tab")
        T.contains(screen(t), "Models:")
        T.contains(screen(t), "Enter: pick", "popup hint after Tab")
      end,
      "down", "enter",
      function(t)
        T.eq(inputLine(t), " > /model anthropic/claude-opus-4", "Enter picks the highlight")
      end,
      "enter",
      function()
        T.eq(agent.config.model, "anthropic/claude-opus-4")
      end,
      "/model ", "tab",
      function(t)
        T.eq(inputLine(t), " > /model google", "first /model completion")
      end,
      { "terminate" }, -- clears the input
      function(t)
        T.eq(inputLine(t), " >")
        T.ok(not screen(t):find("Models:", 1, true), "popup closed")
      end,
      -- Typed in full, sent as typed
      "/model openai gpt-5", "enter",
      function()
        T.eq(agent.config.model.provider, "openai")
        T.eq(agent.config.model.modelId, "gpt-5")
      end,
      "/exit", "enter",
    })
    agent.config.model = defaultModel
  end)

  T.test("Basalt UI: clicks keep the keys on the input line; a popup row can be clicked", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    runUI(51, 19, {}, {
      "ab",
      -- On the log, the header, the status bar
      { "mouse_click", 1, 10, 5 }, { "mouse_up", 1, 10, 5 },
      { "mouse_click", 1, 3, 1 }, { "mouse_up", 1, 3, 1 },
      { "mouse_click", 1, 3, 18 }, { "mouse_up", 1, 3, 18 },
      "cd",
      function(t) T.eq(inputLine(t), " > abcd", "typing went on after the clicks") end,
      { "terminate" },
      -- "/m": one entry, on row 15 (header 14, footer 16)
      "/m",
      expectScreen("Commands:"),
      { "mouse_click", 1, 5, 15 }, { "mouse_up", 1, 5, 15 },
      function(t)
        T.eq(inputLine(t), " > /model", "the clicked entry was taken")
        T.ok(not screen(t):find("Commands:", 1, true), "popup closed")
      end,
      { "char", "x" },
      function(t) T.eq(inputLine(t), " > /model x", "still typing into the input") end,
      { "terminate" },
      CTRL_T,
    })
  end)

  T.test("Basalt UI: history Up/Down, and Ctrl+Left/Right on the line", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("first reply") })
    runUI(51, 19, {}, {
      "hello", "enter",
      waitScreen("first reply"),
      "/help", "enter",
      waitScreen(".cc-code/skills (this directory)"),
      "draft",
      "up",
      function(t) T.eq(inputLine(t), " > /help") end,
      "up",
      function(t) T.eq(inputLine(t), " > hello", "older prompt reached") end,
      "down",
      function(t) T.eq(inputLine(t), " > /help") end,
      "down",
      function(t) T.eq(inputLine(t), " > draft", "the typed line is back") end,
      { "terminate" },
      "one two three",
      { "key", keys.leftCtrl, false }, "left", "left", { "key_up", keys.leftCtrl },
      "X",
      function(t) T.eq(inputLine(t), " > one Xtwo three", "Ctrl+Left twice") end,
      { "key", keys.leftCtrl, false }, "right", { "key_up", keys.leftCtrl },
      "Y",
      function(t) T.eq(inputLine(t), " > one Xtwo Ythree", "Ctrl+Right") end,
      "home", "Z", "end", "!",
      function(t) T.eq(inputLine(t), " > Zone Xtwo Ythree!", "Home and End") end,
      { "paste", "multi\nline" },
      function(t) T.eq(inputLine(t), " > Zone Xtwo Ythree!multi line", "a paste is one line") end,
      { "terminate" },
      CTRL_T,
    })
  end)

  T.test("Basalt UI: a resize during a turn wraps again and drops status parts", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ hold = true, body = chat("A reply long enough that it has to wrap over several lines on a small screen.") })
    runUI(51, 19, {}, {
      "slow", "enter",
      waitScreen("Thinking 0:00 - step 1/25 - Ctrl+T cancels"),
      function(t)
        t.reposition(1, 1, 39, 13)
        os.queueEvent("term_resize")
      end,
      waitScreen("/help | PgUp/PgDn | /exit"),
      function(t)
        T.ok(not screen(t):find("Ctrl+T cancels", 1, true), "status part dropped:\n" .. screen(t))
        T.contains(screen(t), "Thinking 0:00 - step 1/25")
        T.contains(screen(t), "Welcome to cc-code")
        mock.release()
      end,
      waitScreen("wrap over several lines on a small"),
      function(t)
        local _, h = t.getSize()
        T.eq(h, 13)
        for y = 1, 13 do
          T.ok(cells(row(t, y)) <= 39, "row " .. y .. " fits")
        end
        T.contains(screen(t), "Ready")
      end,
      CTRL_T,
    })
  end)

  T.test("Basalt UI: a ! command gets the keys", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    local dir = T.tmp .. "/bui"
    fs.makeDir(dir)
    local prog = dir .. "/ask.lua"
    T.writeFile(prog, "local s = read()\nprint('got[' .. s .. ']')\n")
    runUI(51, 19, {}, {
      "!" .. prog, "enter",
      expectScreen("> !" .. prog),
      { "char", "x" }, "enter",
      waitScreen("got[x]"),
      function(t)
        T.eq(inputLine(t), " >", "the input line got none of the keys")
        T.eq(#mock.requests, 0, "nothing was sent to the model")
      end,
      "after",
      function(t) T.eq(inputLine(t), " > after", "the input line has the keys again") end,
      { "terminate" },
      "/exit", "enter",
    })
  end)

  T.test("Basalt UI: keys and clicks a program queues go to the program, not the input line", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    local dir = T.tmp .. "/bui"
    fs.makeDir(dir)
    -- Tests its own read() as a program does without a person, then leaves
    -- more keys and a wheel turn behind when it ends
    local selftest = dir .. "/selftest.lua"
    T.writeFile(selftest, "os.queueEvent('char', 'r') os.queueEvent('char', 'm') os.queueEvent('key', keys.enter, false)\n" ..
      "local s = read()\nprint('read[' .. s .. ']')\n" ..
      "os.queueEvent('char', 'z') os.queueEvent('key', keys.enter, false) os.queueEvent('mouse_scroll', -1, 5, 5)\n")
    -- A ! command that ends without waiting: its keys come back after the turn
    local leave = dir .. "/leave.lua"
    T.writeFile(leave, "os.queueEvent('char', 'q') os.queueEvent('key', keys.enter, false)\nprint('left keys')\n")
    mock.push({ hold = true, body = chat(nil, toolCall("s1", "shell", { command = selftest })) })
    mock.push({ body = chat("tested the prompt") })
    local queueEvent = os.queueEvent
    runUI(51, 19, {}, {
      -- (enough rows to scroll)
      "/help", "enter",
      waitScreen(".cc-code/skills (this directory)"),
      "test my program", "enter",
      waitScreen("Thinking"),
      "ab",
      function(t) T.eq(inputLine(t), " > ab", "typed ahead") end,
      function() mock.release() end,
      waitScreen("tested the prompt"),
      function() sleep(0.3) end,
      function(t)
        local s = screen(t)
        T.contains(mock.requests[2].body, "read[rm]", "the program read its own keys")
        T.eq(inputLine(t), " > ab", "the input line has the user's keys only")
        T.ok(not s:find("queued]", 1, true), "nothing was queued:\n" .. s)
        T.ok(not s:find("up]", 1, true), "the program's wheel turn did not scroll:\n" .. s)
        T.eq(shownPrompts(), "> /help|> test my program", "the program's keys were not sent")
        T.eq(#mock.requests, 2, "requests sent to the model")
        T.eq(os.queueEvent, queueEvent, "os.queueEvent is put back when the turn ends")
      end,
      { "terminate" },
      "!" .. leave, "enter",
      waitScreen("left keys"),
      function() sleep(0.3) end,
      function(t)
        T.eq(inputLine(t), " >", "the input line got none of the program's keys")
        T.eq(shownPrompts(), "> /help|> test my program|> !" .. leave, "the program's keys were not sent")
        T.eq(#mock.requests, 2, "nothing more was sent to the model")
        T.eq(os.queueEvent, queueEvent, "os.queueEvent is put back")
        T.eq(#app.pump.sets, 0, "every queued event came back")
      end,
      -- The user's own keys still work, also the same ones
      { "char", "q" }, { "char", "r" },
      function(t) T.eq(inputLine(t), " > qr") end,
      { "terminate" },
      "/exit", "enter",
    })
    T.eq(os.queueEvent, queueEvent, "os.queueEvent after the session")
  end)

  T.test("Basalt UI: shell commands run with the terminal's palette; keys go to the input meanwhile", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    local dir = T.tmp .. "/bui"
    fs.makeDir(dir)
    local probe = dir .. "/palprobe.lua"
    local out = dir .. "/palette.txt"
    if fs.exists(out) then fs.delete(out) end
    -- Every slot as the program sees it, then a pause (for typing)
    T.writeFile(probe, "local h = fs.open(" .. string.format("%q", out) .. ", 'w')\n" ..
      "for i = 0, 15 do local r, g, b = term.getPaletteColour(2 ^ i)\n" ..
      "h.write(string.format('%.4f %.4f %.4f\\n', r, g, b)) end\nh.close()\n" ..
      "sleep(tonumber(... or 0) or 0)\nprint('probed')\n")
    local function readProbe()
      local p, i = {}, 0
      for line in (T.readFile(out) or ""):gmatch("[^\n]+") do
        local r, g, b = line:match("(%S+) (%S+) (%S+)")
        p[i] = { tonumber(r), tonumber(g), tonumber(b) }
        i = i + 1
      end
      return p
    end
    mock.push({ body = chat(nil, toolCall("s1", "shell", { command = probe .. " 0.6" })) })
    mock.push({ body = chat("Probed it") })
    local win, paletteBefore = runUI(51, 19, {}, {
      function(t)
        T.ok(paletteHas(t, 0x1a1a2e), "theme loaded")
      end,
      "!" .. probe, "enter",
      waitScreen("probed"),
      function(t)
        T.ok(paletteHas(t, 0x1a1a2e), "theme back after the command")
        T.ok(samePalette(readProbe(), runPalette), "the command saw the terminal's palette")
        fs.delete(out)
      end,
      -- The shell tool: the keys typed while it runs reach the input line
      "probe it", "enter",
      waitScreen("Running shell"),
      "next",
      waitScreen("Probed it"),
      function(t)
        T.ok(samePalette(readProbe(), runPalette), "the shell tool saw the terminal's palette")
        T.eq(inputLine(t), " > next", "typed while the tool ran")
        T.ok(paletteHas(t, 0x1a1a2e), "theme back after the tool")
      end,
      { "terminate" },
      "/exit", "enter",
    })
    expectPalette(win, paletteBefore, "palette after exit")
    T.eq(capture.hooks, nil, "capture hooks cleared on exit")
  end)

  T.test("Basalt UI: monochrome leaves the palette alone", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("plain") })
    local win, paletteBefore = runUI(51, 19, { monochrome = true }, {
      expectBasalt,
      "hi", "enter",
      waitScreen("plain"),
      function(t)
        expectPalette(t, runPalette, "palette while running")
        -- Plain colours: the reply in white, the status bar grey
        local _, h = t.getSize()
        for y = 1, h do
          local text, fg = t.getLine(y)
          if text:find("plain", 1, true) then
            T.eq(fg:sub(2, 2), colours.toBlit(colours.white), "reply colour")
          end
        end
        local _, _, bg = t.getLine(h - 1)
        T.eq(bg:sub(1, 1), colours.toBlit(colours.grey), "status bar")
      end,
      CTRL_T,
    })
    expectPalette(win, paletteBefore, "palette after exit")
  end)

  -- Relative luminance (WCAG) of a palette slot of t
  local function luminance(t, colour)
    local function linear(c)
      return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    local r, g, b = t.getPaletteColour(colour)
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  end

  T.test("Basalt UI: the theme leaves multishell's tab bar readable", function()
    needsBasalt()
    -- multishell draws the current tab's title in the yellow slot on the
    -- black one, and the other tabs in black on the gray one, from the
    -- focused tab's palette. Basalt gives the theme's colours the lowest
    -- free slots, in the order ui.init registers them: whatever that
    -- order puts in yellow and gray on the first frame stays there.
    local LIGHT, DARK = 0.18, 0.05
    local function check(t, where)
      local yellow, black = luminance(t, colours.yellow), luminance(t, colours.black)
      T.ok(yellow > LIGHT, where .. ": the yellow slot is light (" .. yellow .. ")")
      T.ok(black < DARK, where .. ": the black slot is dark (" .. black .. ")")
      local gray = { t.getPaletteColour(colours.grey) }
      local own = runPalette[7]
      local kept = math.abs(gray[1] - own[1]) + math.abs(gray[2] - own[2]) + math.abs(gray[3] - own[3]) < 0.01
      T.ok(kept or luminance(t, colours.grey) > LIGHT,
        where .. ": the gray slot is the terminal's or light (" .. luminance(t, colours.grey) .. ")")
      T.ok(paletteHas(t, 0x1a1a2e) and paletteHas(t, 0x282c34), where .. ": the theme is loaded")
      -- Every role is drawn in a theme colour
      local paint = bui.inspect().paint
      for role, colour in pairs(bui.colors) do
        T.ok(paint[colour] ~= nil, where .. ": role " .. role .. " has a theme colour")
      end
    end
    local cases = {
      { name = "welcome screen", config = {}, last = "Use !<command>" },
      -- A startup problem adds a line in the error colour
      { name = "welcome screen with an error line", config = { model = "nomodel" }, last = "cc-code.model:",
        rgb = 0xe06c75 },
    }
    for _, case in ipairs(cases) do
      mock.reset()
      agent.config.model = defaultModel
      runUI(51, 19, case.config, {
        expectBasalt,
        waitScreen(case.last),
        function(t)
          if case.rgb then
            T.ok(paletteHas(t, case.rgb), case.name .. ": the error line is on screen")
          end
          check(t, case.name)
        end,
        CTRL_T,
      })
    end
    -- Later colours: a reply, then the command popup with its selected row
    -- (no dark colour may first show after the first frame)
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat("A reply") })
    runUI(51, 19, {}, {
      expectBasalt,
      waitScreen("Use !<command>"),
      "hi", "enter",
      waitScreen("A reply"),
      "/", "tab",
      waitScreen("/model"),
      function(t) check(t, "after a reply and the popup") end,
      { "terminate" },
      CTRL_T,
    })
  end)

  T.test("Basalt UI: fits a turtle and a pocket computer screen", function()
    needsBasalt()
    for _, size in ipairs({ { 39, 13 }, { 26, 20 } }) do
      mock.reset()
      agent.config.model = defaultModel
      mock.push({ body = chat("A reply long enough that it has to wrap over several lines on a small screen.") })
      local where = size[1] .. "x" .. size[2]
      runUI(size[1], size[2], {}, {
        expectBasalt,
        "/m", "tab",
        function(t) T.contains(screen(t), "/model", "popup at " .. where) end,
        { "terminate" },
        "hi", "enter",
        waitScreen("wrap"),
        function(t)
          for y = 1, size[2] do
            T.ok(cells(row(t, y)) <= size[1], "row " .. y .. " fits at " .. where)
          end
          T.contains(screen(t), size[1] == 26 and "/help | /exit" or "/help | PgUp/PgDn | /exit", "header at " .. where)
        end,
        CTRL_T,
      })
    end
  end)

  T.test("Basalt UI: braces from the model and the user are shown as written", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    mock.push({ body = chat('Use {self:destroy()} or {"a":1}') })
    mock.push({ body = chat(nil, toolCall("b1", "list_directory", { path = "/{y}" })) })
    mock.push({ body = chat("{done}") })
    runUI(51, 19, {}, {
      "{x}", "enter",
      waitScreen('Use {self:destroy()} or {"a":1}'),
      expectScreen("> {x}"),
      "up",
      function(t) T.eq(inputLine(t), " > {x}", "recalled as typed") end,
      { "terminate" },
      "again", "enter",
      waitScreen("{done}"),
      expectScreen("list /{y} - error"),
      "/exit", "enter",
    })
  end)

  -- A terminal that keeps one cell per character by the (simulated) mod's
  -- rules, for the Unicode tests: the emulator's window counts bytes
  local function cellTerm(w, h)
    local t = { overflow = 0 }
    local text, fgs, bgs = {}, {}, {}
    local cx, cy, blink = 1, 1, false
    local tc, bc = "0", "f"
    local pal = {}
    for i = 0, 15 do pal[i] = { term.nativePaletteColour(2 ^ i) } end
    local function blankRow(y)
      text[y], fgs[y], bgs[y] = {}, {}, {}
      for x = 1, w do text[y][x], fgs[y][x], bgs[y][x] = " ", tc, bc end
    end
    local function blank()
      for y = 1, h do blankRow(y) end
    end
    blank()
    local function slot(c)
      for i = 0, 15 do
        if 2 ^ i == c then return i end
      end
      error("bad colour " .. tostring(c), 3)
    end
    local function put(s, f, b)
      local n = unicode.len(s)
      for k = 1, n do
        local x = cx + k - 1
        if x < 1 or x > w then
          t.overflow = t.overflow + 1
        elseif cy >= 1 and cy <= h then
          text[cy][x] = unicode.sub(s, k, k)
          fgs[cy][x] = f and f:sub(k, k) or tc
          bgs[cy][x] = b and b:sub(k, k) or bc
        end
      end
      cx = cx + n
    end
    function t.write(s) put(tostring(s)) end
    function t.blit(s, f, b)
      local n = unicode.len(s)
      if select(2, f:find("$")) ~= n or select(2, b:find("$")) ~= n then
        error("blit: arguments must be the same length (" .. n .. " cells)", 2)
      end
      put(s, f, b)
    end
    function t.clear() blank() end
    function t.clearLine() blankRow(cy) end
    function t.getCursorPos() return cx, cy end
    function t.setCursorPos(x, y) cx, cy = math.floor(x), math.floor(y) end
    function t.setCursorBlink(on) blink = on end
    function t.getCursorBlink() return blink end
    function t.getSize() return w, h end
    function t.isColour() return true end
    t.isColor = t.isColour
    function t.setTextColour(c) tc = ("0123456789abcdef"):sub(slot(c) + 1, slot(c) + 1) end
    t.setTextColor = t.setTextColour
    function t.getTextColour() return 2 ^ tonumber(tc, 16) end
    t.getTextColor = t.getTextColour
    function t.setBackgroundColour(c) bc = ("0123456789abcdef"):sub(slot(c) + 1, slot(c) + 1) end
    t.setBackgroundColor = t.setBackgroundColour
    function t.getBackgroundColour() return 2 ^ tonumber(bc, 16) end
    t.getBackgroundColor = t.getBackgroundColour
    function t.setPaletteColour(c, r, g, b)
      if g == nil then
        r, g, b = math.floor(r / 65536) / 255, math.floor(r / 256) % 256 / 255, (r % 256) / 255
      end
      pal[slot(c)] = { r, g, b }
    end
    t.setPaletteColor = t.setPaletteColour
    function t.getPaletteColour(c) local p = pal[slot(c)] return p[1], p[2], p[3] end
    t.getPaletteColor = t.getPaletteColour
    function t.scroll(n)
      for _ = 1, n do
        for y = 1, h - 1 do text[y], fgs[y], bgs[y] = text[y + 1], fgs[y + 1], bgs[y + 1] end
        blankRow(h)
      end
    end
    function t.getLine(y)
      return table.concat(text[y]), table.concat(fgs[y]), table.concat(bgs[y])
    end
    function t.cells(y) return text[y] end
    function t.reposition(_, _, nw, nh)
      w, h = nw or w, nh or h
      blank()
    end
    return t
  end

  T.test("Basalt UI with the unicode mod: UTF-8 is drawn and typed by cells", function()
    needsBasalt()
    T.withUnicodeMod(function()
      mock.reset()
      agent.config.model = defaultModel
      mock.push({ body = chat("na\195\175ve caf" .. EACUTE .. " " .. DASH .. " done\n" .. string.rep(DASH, 60)) })
      local cw = cellTerm(51, 19)
      runUI(51, 19, {}, {
        expectBasalt,
        { "char", "\233" }, { "char", "x" }, { "char", DASH },
        function(t) T.eq(inputLine(t), " > " .. EACUTE .. "x" .. DASH, "typed: Latin-1 becomes UTF-8") end,
        "left", "backspace",
        function(t) T.eq(inputLine(t), " > " .. EACUTE .. DASH, "Backspace removed one cell") end,
        { "char", "x" }, "enter",
        waitScreen("na\195\175ve caf" .. EACUTE .. " " .. DASH),
        function(t)
          T.contains(screen(t), "> " .. EACUTE .. "x" .. DASH, "the prompt shown")
          T.eq(lastPrompt(mock.requests[1]), EACUTE .. "x" .. DASH, "sent as UTF-8")
          -- The long run of dashes wraps at 49 cells, whole characters only
          local found
          for y = 1, 19 do
            local cells = t.cells(y)
            if cells[2] == DASH and cells[50] == DASH then found = true end
            for x = 1, 51 do
              local cell = cells[x]
              T.ok(cell == " " or unicode.len(cell) == 1, "one character per cell at " .. x .. "," .. y)
            end
          end
          T.ok(found, "a full row of dashes:\n" .. screen(t))
          T.eq(t.overflow, 0, "cells written past the right edge")
        end,
        CTRL_T,
      }, { term = cw })
      T.contains(screen(cw), "Goodbye!")
    end)
  end)

  T.test("Basalt UI: a failure during a shell command gives the terminal back", function()
    needsBasalt()
    mock.reset()
    agent.config.model = defaultModel
    local dir = T.tmp .. "/bui"
    fs.makeDir(dir)
    local prog = dir .. "/slow.lua"
    T.writeFile(prog, "for i = 1, 30 do sleep(0.1) end\nprint('slow done')\n")
    mock.push({ body = chat(nil, toolCall("w1", "shell", { command = prog, timeout = 20 })) })
    mock.push({ body = chat("unreachable") })
    local realWheel = bui.wheel
    local queueEvent = os.queueEvent
    -- capture.run must end (and undo its redirect and wrapper) by itself
    local realRun = capture.run
    local captured
    capture.run = function(...)
      -- The turn's wrapper, which capture's own goes on top of
      local before = os.queueEvent
      local r = table.pack(realRun(...))
      captured = { terminated = r[3], info = r[4], current = term.current(), queueEvent = os.queueEvent, before = before }
      return table.unpack(r, 1, r.n)
    end
    local win, paletteBefore, err
    local ok, e = pcall(function()
      win, paletteBefore, err = runUI(51, 19, {}, {
        "run it", "enter",
        waitScreen("Running shell"),
        function()
          T.ok(os.queueEvent ~= queueEvent, "capture wrapped os.queueEvent")
          bui.wheel = function() error("wheel broke", 0) end
        end,
        { "mouse_scroll", -1, 5, 5 },
      }, { expectError = true })
    end)
    bui.wheel = realWheel
    capture.run = realRun
    if not ok then error(e, 0) end
    T.eq(err, "wheel broke")
    T.ok(captured, "the shell command's capture.run returned")
    T.ok(captured.terminated, "the program was stopped")
    T.eq(captured.current, win, "capture put the terminal back itself")
    T.ok(captured.before ~= queueEvent, "the turn wrapped os.queueEvent before capture did")
    T.eq(captured.queueEvent, captured.before, "capture put the turn's os.queueEvent back itself")
    T.eq(os.queueEvent, queueEvent, "os.queueEvent restored")
    T.eq(capture.hooks, nil, "capture hooks cleared")
    T.eq(app.pump, nil, "the session ended")
    expectPalette(win, paletteBefore, "palette after the failure")
    T.ok(not screen(win):find("cc-code", 1, true), "the screen was cleared:\n" .. screen(win))
  end)

  -- Focused tests: the UI on a plain window (vanilla: one byte per cell)

  local function plainUI(w, h, config, fn)
    local win = window.create(term.current(), 1, 1, w, h, false)
    local old = term.redirect(win)
    local basalt, why = loader.load({ root = T.root })
    T.ok(basalt, "the bundle loads: " .. tostring(why))
    local ok, err = pcall(function()
      bui.setBasalt(basalt)
      bui.init(config or {})
      bui.setToolDisplay("short")
      local function draw()
        basalt.update()
      end
      fn(win, function(y)
        draw()
        return ((win.getLine(y)):gsub("%s+$", ""))
      end, basalt)
    end)
    pcall(bui.cleanup)
    term.redirect(old)
    if not ok then error(err, 0) end
  end

  T.test("Basalt UI: short tool lines, one row each, completed in place", function()
    needsBasalt()
    plainUI(40, 12, {}, function(_, rowOf)
      bui.printToolCall("read_file", { path = "startup.lua" })
      T.eq(rowOf(2), " * read startup.lua")
      bui.printToolResult("read_file", { totalLines = 12 })
      T.eq(rowOf(2), " * read startup.lua - 12 lines", "same row")
      T.eq(rowOf(3), "")
      bui.printToolCall("shell", { command = "mine 3" })
      bui.printToolResult("shell", { success = false, output = "mine.lua:7: attempt to call nil, a very long message" })
      T.eq(rowOf(3), " ! $ mine 3 - failed: mine.lua:7: at...")
      bui.printToolCall("glob", { pattern = "*.lua" })
      bui.print("note")
      bui.printToolResult("glob", { matches = { "a.lua" } })
      T.eq(rowOf(4), " * glob *.lua")
      T.eq(rowOf(5), " note")
      T.eq(rowOf(6), " * glob *.lua - 1 file")
      bui.printToolCall("my_tool", { n = 1 })
      bui.printToolResult("my_tool", nil)
      T.eq(rowOf(7), " * my_tool {\"n\":1} - done")
      bui.printToolCall("shell", { command = "farm" })
      bui.printToolResult("shell", { cancelled = true, output = "row 4 done" })
      T.eq(rowOf(8), " * $ farm - stopped (Ctrl+T): row 4 ...", "cut to the 38 cells")
      bui.clear()
      bui.setToolDisplay("off")
      bui.printToolCall("read_file", { path = "x" })
      bui.printToolResult("read_file", { totalLines = 1 })
      T.eq(rowOf(2), "")
      bui.setToolDisplay("full")
      bui.printToolCall("write_file", { path = "a" })
      bui.printToolResult("write_file", { bytes = 3 })
      T.eq(rowOf(2), " >> write_file")
      T.eq(rowOf(3), "    {\"path\":\"a\"}")
      T.eq(rowOf(4), " << {\"bytes\":3}")
    end)
  end)

  T.test("Basalt UI: narrow tool lines keep the outcome; a resize cuts again", function()
    needsBasalt()
    local function calls()
      bui.printToolCall("edit_file", { path = "startup.lua" })
      bui.printToolResult("edit_file", { error = "String not found in file" })
      bui.printToolCall("shell", { command = "programs/quarry 3 3" })
      bui.printToolResult("shell", { success = false, output = "quarry.lua:12: attempt to call nil" })
      bui.printToolCall("read_file", { path = "programs/quarry.lua" })
      bui.printToolResult("read_file", { totalLines = 120 })
    end
    plainUI(26, 12, { monochrome = true }, function(_, rowOf)
      calls()
      T.eq(rowOf(2), " ! edit ... - error: S...")
      T.eq(rowOf(3), " ! $ pro... - failed: ...")
      T.eq(rowOf(4), " * read pr... - 120 lines")
    end)
    plainUI(39, 12, { monochrome = true }, function(win, rowOf, basalt)
      calls()
      T.eq(rowOf(2), " ! edit startup.lua - error: String...")
      T.eq(rowOf(3), " ! $ programs/qu... - failed: quarr...")
      T.eq(rowOf(4), " * read programs/quarry... - 120 lines")
      local _, fg = win.getLine(2)
      T.eq(fg:sub(2, 2), colours.toBlit(colours.white), "error drawn white")
      _, fg = win.getLine(4)
      T.eq(fg:sub(2, 2), colours.toBlit(colours.lightGrey), "dim drawn light grey")
      win.reposition(1, 1, 26, 12)
      bui.checkSize()
      basalt.update("term_resize")
      T.eq(rowOf(2), " ! edit ... - error: S...")
      T.eq(rowOf(4), " * read pr... - 120 lines")
      win.reposition(1, 1, 39, 12)
      bui.checkSize()
      basalt.update("term_resize")
      T.eq(rowOf(2), " ! edit startup.lua - error: String...")
    end)
  end)

  T.test("Basalt UI: print colours, the theme's RGB and the status parts", function()
    needsBasalt()
    plainUI(51, 12, {}, function(win, rowOf)
      bui.printRole("error", "boom")
      T.eq(rowOf(2), " Error: boom")
      T.ok(paletteHas(win, 0xe06c75), "the error colour is the theme's")
      local _, fg = win.getLine(2)
      local _, _, bg = win.getLine(1)
      T.ok(fg:sub(2, 2) ~= bg:sub(1, 1), "text and header in different slots")
      bui.print("odd colour", 12345)
      T.eq(rowOf(3), " odd colour", "an invalid colour is the foreground")
      for i = 1, 10 do bui.print("line " .. i) end
      bui.setStatus({ "Thinking 0:03", "step 2/25", "Ctrl+T cancels" })
      T.eq(rowOf(11), " Thinking 0:03 - step 2/25 - Ctrl+T cancels")
      bui.setQueued(2)
      -- The status gives way to the queue
      T.eq(rowOf(11), " Thinking 0:03 - step 2/25" .. string.rep(" ", 13) .. "[2 queued]")
      bui.scrollUp(1)
      T.eq(rowOf(11), " Thinking 0:03 - step 2/25      [2 queued] [1 up]", "the scroll position shortened")
      bui.scrollDown(1)
      -- Ctrl+Up/Down scroll a row, Ctrl+Home/End to the top and bottom
      local function key(code) return bui.inputEvent({ "key", code, false, n = 3 }) end
      key(keys.leftCtrl)
      T.eq(key(keys.up), true, "Ctrl+Up handled")
      T.contains(rowOf(11), "[1 up]")
      key(keys.home)
      T.contains(rowOf(11), "[3 up]", "Ctrl+Home: 12 rows, 9 on screen")
      T.eq(rowOf(2), " Error: boom")
      key(keys.down)
      T.contains(rowOf(11), "[2 up]")
      key(keys["end"])
      T.ok(not rowOf(11):find("up]", 1, true), "Ctrl+End: at the bottom")
      bui.inputEvent({ "key_up", keys.leftCtrl, n = 2 })
      T.eq(key(keys.up), true, "Up without Ctrl: history")
      T.ok(not rowOf(11):find("up]", 1, true), "no scrolling")
      bui.setInput("")
      bui.setStatus("Ready")
      T.eq(rowOf(11), " Ready" .. string.rep(" ", 33) .. "[2 queued]")
      bui.setQueued(0)
      T.eq(rowOf(11), " Ready")
      -- Streamed text: a sequence split across chunks is held back (and
      -- shown as forDisplay shows it: the CC charset without the mod)
      bui.streamText("na\195")
      bui.streamText("\175ve")
      bui.endStream()
      T.eq(rowOf(10), " " .. require("cmn-utils.text").forDisplay("na\195\175ve"))
      T.ok(paletteHas(win, 0x282c34), "the status bar colour is the theme's")
      T.ok(paletteHas(win, 0x1a1a2e), "the background colour is the theme's")
    end)
  end)

  T.test("Basalt pump: code-queued mouse events under a tab bar, and a lost marker", function()
    -- (no bundle needed: only the pump's bookkeeping)
    local app = require("cc-code.basalt.app")
    local pump = app.newPump({}, {}, {})
    local realQueue = os.queueEvent
    local queued = {}
    local set
    local ok, err = pcall(function()
      os.queueEvent = function(...) queued[#queued + 1] = table.pack(...) end
      pump:watchQueue()
      os.queueEvent("mouse_scroll", 1, 5, 7)
      os.queueEvent("char", "q")
      pump:unwatchQueue()
      set = pump.sets[1]
      T.ok(set and set.timer, "a fallback timer for the marker")
      T.eq(queued[#queued][1], "cc_code_queued_mark")
      -- Multishell's tab bar gives the focused tab y - 1: still the program's
      T.eq(pump:queuedByCode(table.pack("mouse_scroll", 1, 5, 6)), true)
      T.eq(pump:queuedByCode(table.pack("mouse_scroll", 1, 5, 6)), false, "counted off once")
      T.eq(pump:queuedByCode(table.pack("char", "q")), true)
      -- The marker was lost (a full event queue): its timer drops the set
      pump:watchQueue()
      os.queueEvent("char", "z")
      pump:unwatchQueue()
      T.eq(#pump.sets, 2)
      local newest = pump.sets[2]
      pump:handle(table.pack("timer", newest.timer))
      T.eq(#pump.sets, 0, "the newest set and every older one are dropped")
      T.eq(pump:queuedByCode(table.pack("char", "z")), false, "the user's z goes to the input line")
    end)
    os.queueEvent = realQueue
    if set and set.timer then os.cancelTimer(set.timer) end
    for _, s in ipairs(pump.sets) do
      if s.timer then os.cancelTimer(s.timer) end
    end
    if not ok then error(err, 0) end
  end)

  T.test("Basalt pump: a dropped input event is forgotten at the next marker, during the turn", function()
    -- (no bundle needed: the pump with a stand-in UI and Basalt)
    local app = require("cc-code.basalt.app")
    local typed = {}
    local fakeUI = {
      inputEvent = function(ev)
        typed[#typed + 1] = ev[1] .. ":" .. tostring(ev[2])
        return true
      end,
      isRunning = function() return true end,
      setStatus = function() end, setQueued = function() end, setProgramMode = function() end,
    }
    local pump = app.newPump(fakeUI, { update = function() end }, {})
    local realQueue = os.queueEvent
    -- The computer's event queue. CC: Tweaked drops events when it holds
    -- 256: here ('char', 'x') is lost, and everything while full is set
    local queued, full = {}, false
    local function fakeQueue(name, ...)
      if full or (name == "char" and (...) == "x") then return end
      queued[#queued + 1] = table.pack(name, ...)
    end
    -- The pump's loop: every queued event, first in, first out
    local function deliver()
      while #queued > 0 do
        pump:handle(table.remove(queued, 1))
      end
    end
    local function newTurn(fn)
      local turn = { started = os.epoch("utc"), co = coroutine.create(fn) }
      pump.turn = turn
      pump:watchQueue()
      pump:resume(turn, nil)
      return turn
    end
    local function typedHas(entry)
      for _, e in ipairs(typed) do
        if e == entry then return true end
      end
      return false
    end
    local got = {}
    local ok, err = pcall(function()
      os.queueEvent = fakeQueue
      local wrapper
      local turn = newTurn(function()
        wrapper = os.queueEvent
        -- A program typing into its own read(): x never arrives
        os.queueEvent("char", "a")
        os.queueEvent("char", "x")
        got[#got + 1] = select(2, coroutine.yield("char"))
        os.queueEvent("char", "b")
        got[#got + 1] = select(2, coroutine.yield("key"))
        -- The queue is full: these and the marker are lost
        full = true
        os.queueEvent("char", "y")
        os.queueEvent("char", "y")
        local _, key = coroutine.yield("key")
        got[#got + 1] = key
      end)
      T.eq(#pump.sets, 2, "the yield closed the set and opened one")
      T.eq(pump.sets[1].open, false)
      T.ok(pump.sets[1].timer ~= nil, "a fallback timer for its marker")
      T.eq(queued[#queued][1], "cc_code_queued_mark", "the marker goes behind the queued events")
      T.eq(os.queueEvent, wrapper, "the same wrapper counts on (capture.run keeps a copy)")
      deliver()
      T.eq(got[1], "a", "the program read its own key")
      T.eq(pump.turn, turn, "the turn still runs")
      T.ok(not typedHas("char:b"), "b was counted in the new set: not the user's")
      T.eq(#pump.sets, 1, "both markers came back: only the open set is left")
      -- The user types x while the turn still runs: it is not swallowed
      pump:handle(table.pack("char", "x"))
      T.ok(typedHas("char:x"), "the user's x reached the input line")
      -- The turn gets a key and fills the queue: the marker is lost
      pump:handle(table.pack("key", keys.a, false))
      T.eq(got[2], keys.a)
      full = false
      local lost = pump.sets[1]
      T.ok(lost and not lost.open and lost.timer, "a closed set waits for its lost marker")
      pump:handle(table.pack("char", "y"))
      T.ok(not typedHas("char:y"), "until then, a y is taken for the program's (one of two)")
      -- The fallback timer gives up on the set
      pump:handle(table.pack("timer", lost.timer))
      pump:handle(table.pack("char", "y"))
      T.ok(typedHas("char:y"), "after the timer, the user's y reaches the input line")
      pump:handle(table.pack("key", keys.enter, false))
      T.eq(got[3], keys.enter)
      T.eq(pump.turn, nil, "the turn ended")
      T.eq(os.queueEvent, fakeQueue, "os.queueEvent is put back")
      T.eq(#pump.sets, 0, "an empty set goes when the turn ends")

      -- A turn that leaves keys behind, then one that queues none: the
      -- first one's set still waits for its marker
      newTurn(function() os.queueEvent("char", "q") end)
      newTurn(function() end)
      T.eq(#pump.sets, 1, "the first turn's set is kept")
      deliver()
      T.ok(not typedHas("char:q"), "the first turn's q did not reach the input line")
      T.eq(#pump.sets, 0, "its marker came back")
    end)
    os.queueEvent = realQueue
    for _, s in ipairs(pump.sets) do
      if s.timer then os.cancelTimer(s.timer) end
    end
    if not ok then error(err, 0) end
  end)

  T.test("Basalt log: wrapping by cells, as tui.lua wraps", function()
    local log = Log.new(10)
    log:add("one two three four five", 1)
    T.eq(#log.rows, 3)
    T.eq(log.rows[1].text, "one two")
    T.eq(log.rows[2].text, "three four")
    T.eq(log.rows[3].text, "five")
    log:add("  indented line here", 1)
    T.eq(log.rows[4].text, "  indented", "the first row keeps its indentation")
    T.eq(log.rows[5].text, "line here")
    log:add("a\n\nb", 1)
    T.eq(log.rows[6].text, "a")
    T.eq(log.rows[7].text, "", "empty lines are kept")
    T.eq(log.rows[8].text, "b")
    log:add("x " .. string.rep("y", 25), 1)
    T.eq(log.rows[9].text, "x yyyyyyyy", "a long word starts on the current row")
    T.eq(log.rows[10].text, "yyyyyyyyyy")
    T.eq(log.rows[11].text, "yyyyyyy")
    -- Scrolled back, new rows keep the view; at the bottom it follows
    log:scroll(3, 4)
    T.eq(log.offset, 3)
    log:add("more", 1)
    T.eq(log.offset, 4)
    local first, last = log:window(4)
    T.eq(last - first + 1, 4)
    T.eq(last, #log.rows - 4)
    log:rewrap(20)
    T.eq(log.rows[1].text, "one two three four")
    log:clamp(4)
    T.ok(log.offset <= #log.rows - 4)
    T.withUnicodeMod(function()
      local l = Log.new(5)
      l:add(string.rep(DASH, 12), 1)
      T.eq(l.rows[1].text, string.rep(DASH, 5), "split by cells")
      T.eq(l.rows[3].text, string.rep(DASH, 2))
      -- A sequence split across chunks is held back
      local function keep(s) return s end
      l:stream("na\195", 2, keep)
      l:stream("\175ve", 2, keep)
      l:endStream(keep)
      T.eq(l.rows[#l.rows].text, "na\195\175ve")
    end)
  end)

  T.test("Basalt UI: completions are registered before Basalt is loaded", function()
    needsBasalt()
    -- skills/model.lua registers /model with this module when skills load
    agent.init({ model = defaultModel })
    local seen
    bui.registerCompletion("/probe", function(args)
      seen = args
      return { { cmd = "/probe one", desc = "One" } }
    end, "Probes")
    plainUI(51, 19, {}, function(win, rowOf)
      bui.setInput("/PROBE x")
      bui.inputEvent({ "key", keys.tab, false, n = 3 })
      T.eq(seen, "x")
      T.eq(rowOf(19), " > /probe one", "Tab took the entry")
      T.contains(rowOf(14), "Probes:")
    end)
  end)
end

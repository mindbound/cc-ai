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
end

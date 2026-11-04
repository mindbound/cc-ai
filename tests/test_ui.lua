-- tests/test_ui.lua
-- End-to-end: the real cc-code loop in an off-screen window, driven by
-- queued key events, answering from the fake HTTP API

return function(T)
  local occode = require("cc-code")
  local agent = require("cc-code.agent")
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

  -- Steps: a string is typed, "enter"/"tab"/... are keys, a table is queued
  -- as an event, a function is called with the window (for assertions)
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
        if type(step) == "string" and keys[step] then
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

  T.test("TUI: chat turn with a tool call, UTF-8 reply, then /exit", function()
    mock.reset()
    agent.config.model = "anthropic/claude-sonnet-4"
    mock.push({ body = chat(nil, { { id = "c1", type = "function", ["function"] = { name = "list_directory", arguments = "{\"path\":\"/rom\"}" } } }) })
    mock.push({ body = chat("Found caf\195\169 \226\128\148 done") })
    local win, paletteBefore = runUI(51, 19, {}, {
      expectScreen("cc-code"),
      "hello", "enter",
      expectScreen("> hello"),
      expectScreen(">> list_directory"),
      expectScreen("Found caf\233 - done"),
      "/exit", "enter", "enter",
    })
    T.contains(screen(win), "Goodbye!")
    expectPalette(win, paletteBefore)
    T.eq(#mock.requests, 2)
  end)

  T.test("TUI: /help is shown, history recalls the previous input", function()
    mock.reset()
    runUI(51, 19, {}, {
      "/help", "enter", "enter",
      expectScreen("API keys: exit, then run"), -- end of the help text
      "up",
      function(win)
        local _, h = win.getSize()
        T.contains(win.getLine(h), "/help", "input line after Up")
      end,
      "enter",
      "/exit", "enter", "enter",
    })
  end)

  T.test("TUI: Ctrl+T at an empty prompt exits", function()
    mock.reset()
    runUI(51, 19, {}, { { "terminate" } })
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
        { "terminate" },
      })
    end
  end)

  T.test("TUI: monochrome mode leaves the palette alone", function()
    mock.reset()
    runUI(51, 19, { monochrome = true }, {
      function(w)
        T.eq(w.getPaletteColour(colours.black), 0x12 / 255, "custom palette kept while running")
      end,
      { "terminate" },
    })
  end)

  T.test("terminal mode: chat turn and /exit", function()
    mock.reset()
    mock.push({ body = chat("Terminal reply") })
    local win = runUI(51, 19, { forceTerminal = true }, {
      "hello", "enter",
      expectScreen("Terminal reply"),
      "/exit", "enter",
    })
    T.contains(screen(win), "Goodbye!")
  end)
end

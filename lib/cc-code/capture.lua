-- cc-code/capture.lua
-- Run a CraftOS shell command and capture what it prints.
-- CraftOS has no output redirection (no "> file"), so the command runs with
-- the terminal redirected to a virtual terminal that records every write.

local capture = {}

-- Byte length: positions in the recorded lines are bytes, also under mods
-- that make # count UTF-8 characters
local byteLen = require("cmn-utils.text").byteLen

-- Optional { before = fn, after = fn }, called around every command
capture.hooks = nil

-- Virtual terminal height. Large so programs that page their output
-- (textutils.pagedPrint, used by ls/help) never stop to wait for a key.
local VIRTUAL_HEIGHT = 999

-- Lines that scrolled off the top are kept from the start and from the end
-- of the output; the middle of a very long output is dropped (and counted)
local KEEP_HEAD_LINES = 200
local KEEP_TAIL_LINES = 1000

-- Seconds a program gets to end after its timeout asked it to stop (enough
-- for cleanup such as saving state or a turtle making a few moves)
capture.STOP_GRACE = 10

-- Create a recording terminal object implementing the term redirect API
function capture.createTerminal(width, height, parent)
  parent = parent or term.current()
  -- Screen rows: row y is rows[top + y]. Scrolling moves top instead of
  -- copying every row.
  local rows = {}
  local top = 0
  -- Rows that left the screen: the first ones, then a ring of the latest
  local head = {}
  local ring, ringNext, ringCount = {}, 1, 0
  local scrolledTotal = 0
  local droppedBytes = 0
  local cursorX, cursorY = 1, 1
  local textColour, backgroundColour = colours.white, colours.black
  local cursorBlink = false

  local t = {}

  local function keepScrolled(line)
    scrolledTotal = scrolledTotal + 1
    if #head < KEEP_HEAD_LINES then
      head[#head + 1] = line
      return
    end
    local old = ring[ringNext]
    if old then
      droppedBytes = droppedBytes + byteLen(old) + 1
    end
    ring[ringNext] = line
    ringNext = ringNext % KEEP_TAIL_LINES + 1
    if ringCount < KEEP_TAIL_LINES then
      ringCount = ringCount + 1
    end
  end

  local function put(str)
    str = tostring(str)
    local x = cursorX
    cursorX = cursorX + byteLen(str)
    if cursorY < 1 or cursorY > height then return end
    -- Clip to the visible columns, like a real terminal
    if x < 1 then
      str = str:sub(2 - x)
      x = 1
    end
    if x > width then return end
    str = str:sub(1, width - x + 1)
    local line = rows[top + cursorY] or ""
    local lineLen = byteLen(line)
    if lineLen < x - 1 then
      line = line .. string.rep(" ", x - 1 - lineLen)
    end
    rows[top + cursorY] = line:sub(1, x - 1) .. str .. line:sub(x + byteLen(str))
  end

  function t.write(str) put(str) end
  function t.blit(str, _fg, _bg) put(str) end

  function t.clear()
    -- Keep what was on screen: the caller wants the whole output history
    for y = 1, height do
      local line = rows[top + y]
      if line then
        keepScrolled(line)
        rows[top + y] = nil
      end
    end
  end

  function t.clearLine()
    rows[top + cursorY] = nil
  end

  function t.scroll(n)
    n = math.floor(n)
    if n > 0 then
      for y = 1, math.min(n, height) do
        keepScrolled(rows[top + y] or "")
        rows[top + y] = nil
      end
      for y = height + 1, n do
        keepScrolled("")
      end
      -- Rows that scroll past the bottom of the old screen start empty
      top = top + n
    elseif n < 0 then
      -- Rare (scrolling down): move the rows one by one, bottom first
      local m = -n
      for y = height, 1, -1 do
        local from = y - m
        rows[top + y] = from >= 1 and rows[top + from] or nil
      end
    end
  end

  function t.getCursorPos() return cursorX, cursorY end
  function t.setCursorPos(x, y)
    cursorX, cursorY = math.floor(x), math.floor(y)
  end
  function t.getCursorBlink() return cursorBlink end
  function t.setCursorBlink(blink) cursorBlink = blink end
  function t.getSize() return width, height end
  function t.isColour() return parent.isColour() end
  t.isColor = t.isColour

  function t.setTextColour(c) textColour = c end
  t.setTextColor = t.setTextColour
  function t.getTextColour() return textColour end
  t.getTextColor = t.getTextColour
  function t.setBackgroundColour(c) backgroundColour = c end
  t.setBackgroundColor = t.setBackgroundColour
  function t.getBackgroundColour() return backgroundColour end
  t.getBackgroundColor = t.getBackgroundColour

  -- Palette calls are ignored so programs can't recolour the real screen
  function t.setPaletteColour() end
  t.setPaletteColor = t.setPaletteColour
  function t.getPaletteColour(c) return parent.getPaletteColour(c) end
  t.getPaletteColor = t.getPaletteColour

  -- Lines (and their bytes, newlines included) dropped from the middle of a
  -- very long output; getText marks the place with "[... N lines left out ...]"
  function t.getDropped()
    return scrolledTotal - #head - ringCount, droppedBytes
  end

  -- Everything written so far, as text (trailing spaces/blank lines trimmed)
  function t.getText()
    local out = {}
    for _, line in ipairs(head) do
      out[#out + 1] = line
    end
    local dropped = scrolledTotal - #head - ringCount
    if dropped > 0 then
      out[#out + 1] = "[... " .. dropped .. " lines left out ...]"
    end
    local oldest = ringCount < KEEP_TAIL_LINES and 1 or ringNext
    for i = 0, ringCount - 1 do
      out[#out + 1] = ring[(oldest - 1 + i) % KEEP_TAIL_LINES + 1]
    end
    local lastRow = 0
    for index in pairs(rows) do
      local y = index - top
      if y > lastRow and y <= height then lastRow = y end
    end
    for y = 1, lastRow do
      out[#out + 1] = rows[top + y] or ""
    end
    for i = 1, #out do
      out[i] = out[i]:gsub("%s+$", "")
    end
    while #out > 0 and out[#out] == "" do
      table.remove(out)
    end
    while #out > 0 and out[1] == "" do
      table.remove(out, 1)
    end
    return table.concat(out, "\n")
  end

  return t
end

-- Run a shell command. Returns success (boolean), its captured output,
-- whether the user pressed Ctrl+T while it ran (the shell catches the
-- "Terminated" error inside the program, so it is detected separately), and
-- a table { timedOut, abandoned, pullEventRestored, droppedLines,
-- droppedBytes }.
-- The command runs in the current shell, so `cd` persists, like typing it.
-- opts (optional):
--   width    columns of the recording terminal (default: screen, at least 80)
--   timeout  seconds; a program still running then is sent a terminate, and
--            abandoned if it has not ended capture.STOP_GRACE seconds later
-- Ctrl+T is passed to the program, which then usually ends (after any
-- cleanup it does). A second Ctrl+T, or one during the grace period after a
-- timeout, abandons a program that is still running. An abandoned program
-- is never resumed again; the shell's record of the running program can't
-- be undone from outside, so shell.getRunningProgram() keeps naming it.
function capture.run(command, workdir, opts)
  opts = opts or {}
  if not shell then
    return false, "The shell API is not available", false, {}
  end

  local oldDir
  if workdir then
    if not fs.isDir(workdir) then
      return false, "Working directory not found: " .. workdir, false, {}
    end
    oldDir = shell.dir()
    shell.setDir(fs.combine(workdir, ""))
  end

  local parent = term.current()
  local width = opts.width or math.max((parent.getSize()), 80)
  local recorder = capture.createTerminal(width, VIRTUAL_HEIGHT, parent)

  -- Optional UI hooks around the command (the TUI puts the normal palette
  -- back, so a multishell tab the command opens doesn't copy the theme)
  local hooks = capture.hooks
  if hooks and hooks.before then
    pcall(hooks.before)
  end

  -- Shared state an abandoned program can leave changed: put back after it
  -- (programs that ignore Ctrl+T usually set os.pullEvent = os.pullEventRaw,
  -- which affects every program on the computer)
  local savedPullEvent = os.pullEvent
  local tab = multishell and multishell.getCurrent and multishell.getCurrent()
  local savedTitle = tab and multishell.getTitle and multishell.getTitle(tab)

  local previous = term.redirect(recorder)
  local ok, result
  local terminated, timedOut, abandoned = false, false, false
  local stopRequested = false

  -- The program runs in its own coroutine, resumed here like parallel does.
  -- A stop is delivered to it directly: a queued "terminate" would go to the
  -- focused multishell tab, which may be another program.
  local co = coroutine.create(function()
    ok, result = pcall(shell.run, command)
  end)
  local filter
  local function resume(...)
    local resumed, value = coroutine.resume(co, ...)
    if resumed then
      filter = value
    else
      ok, result = false, value
    end
  end

  local timer = opts.timeout and os.startTimer(opts.timeout)
  local graceTimer
  local loopOk, loopErr = pcall(function()
    resume()
    while coroutine.status(co) ~= "dead" do
      local event = table.pack(os.pullEventRaw())
      local name = event[1]
      if name == "timer" and timer and event[2] == timer then
        timer = nil
        timedOut = true
        stopRequested = true
        resume("terminate")
        if coroutine.status(co) ~= "dead" and not graceTimer then
          graceTimer = os.startTimer(capture.STOP_GRACE)
        end
      elseif name == "timer" and graceTimer and event[2] == graceTimer then
        -- Still running: it ignores terminate, or its cleanup takes too long
        abandoned = true
        break
      elseif name == "terminate" and stopRequested then
        -- Ctrl+T again after a stop request: give up on the program now
        terminated = true
        abandoned = true
        break
      else
        if name == "terminate" then
          terminated = true
          stopRequested = true
        end
        if filter == nil or filter == name or name == "terminate" then
          resume(table.unpack(event, 1, event.n))
        end
      end
    end
  end)
  if timer then os.cancelTimer(timer) end
  if graceTimer then os.cancelTimer(graceTimer) end
  term.redirect(previous)

  local pullEventRestored = false
  if abandoned and os.pullEvent ~= savedPullEvent then
    os.pullEvent = savedPullEvent
    pullEventRestored = true
  end
  if savedTitle and multishell.setTitle then
    pcall(multishell.setTitle, tab, savedTitle)
  end

  -- The program ran in pcall, so this runs even when the command errored
  if hooks and hooks.after then
    pcall(hooks.after)
  end

  if oldDir then
    shell.setDir(oldDir)
  end

  if not loopOk then
    error(loopErr, 0)
  end

  local droppedLines, droppedBytes = recorder.getDropped()
  local info = {
    timedOut = timedOut,
    abandoned = abandoned,
    pullEventRestored = pullEventRestored,
    droppedLines = droppedLines,
    droppedBytes = droppedBytes,
  }
  local output = recorder.getText()
  if ok == false then
    -- shell.run itself failed
    output = output .. (output ~= "" and "\n" or "") .. tostring(result)
    return false, output, terminated, info
  end
  return result == true, output, terminated, info
end

return capture

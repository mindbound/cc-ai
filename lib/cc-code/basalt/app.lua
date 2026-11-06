-- cc-code/basalt/app.lua
-- The Basalt UI's session and event loop (a trial; see cc-code.basalt.ui).
--
-- cc-code keeps its own event loop (the "pump") and feeds events to Basalt
-- with basalt.update; Basalt never runs its own loop. Each prompt's turn
-- (agent.process, then occode.showResult) runs in a coroutine that the
-- pump resumes the way the parallel API does: with every event its filter
-- accepts, and always with "terminate". So the SDK's wait for the model,
-- the shell tool's capture loop and grep's yields all get their events,
-- while the UI keeps drawing, scrolling and resizing.
--
-- Routing:
--   terminate   during a turn: to the turn only (it cancels the model wait,
--               or stops the running program; a second one abandons it).
--               At the prompt: clears the input line, or exits when it is
--               empty, except a Ctrl+T left over from cancelling a turn
--               (no T key since the prompt came back, within a second), as
--               tui.lua does. Basalt never sees it.
--   keyboard    during a `!command`: to the turn only (the user's own
--               program reads them). Otherwise to the turn (the model wait
--               and the shell tool drop them) and to the UI: the user can
--               type the next prompt while the model works, and Enter
--               queues it until the turn ends. A turn stopped with Ctrl+T
--               sends nothing more: the oldest queued prompt goes back to
--               the input line. (The leftover rule above also covers the
--               first second of a queued prompt's turn.)
--   the rest    to the turn, then to Basalt (mouse, resizes, timers).
--
-- Only the user's keys and clicks reach the UI. While a turn runs,
-- os.queueEvent is wrapped to count the input events code queues (a
-- program the shell tool or a `!command` runs, testing its own read() or
-- menu, and anything else): when such an event comes back it goes to the
-- turn only, also after the turn ended. (capture.run's own wrapper goes on
-- top of this one during the shell tool and puts it back.) The counts are
-- kept in sets: each time the turn yields after queueing input events,
-- their set is closed and a marker event queued behind them, and a new set
-- counts from then on. When the marker comes back, so has everything the
-- set counted, and what is still counted was dropped (CC: Tweaked keeps
-- at most 256 queued events), so the set goes: a dropped event never
-- swallows the user's matching key for longer than that.
--
-- If anything fails while a turn is suspended (for example inside a shell
-- command, with the terminal redirected to capture's recorder), the turn
-- is resumed with "terminate" until it ends, which puts the terminal and
-- os.queueEvent back; then the screen is cleaned up and the error raised.

local aiUtils = require("ai.utils")
local agent = require("cc-code.agent")
local capture = require("cc-code.capture")

local app = {}

-- Keyboard events
local KEYS = { key = true, key_up = true, char = true, paste = true }

-- Events the user makes with the keyboard and mouse (as capture.lua)
local INPUT_EVENTS = {
  key = true, key_up = true, char = true, paste = true,
  mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}

-- Queued when a set of counted input events is closed (the turn yielded or
-- ended): when it comes back, so have all of them (the event queue is
-- first in, first out)
local MARK_EVENT = "cc_code_queued_mark"
local markCount = 0

-- CC: Tweaked keeps at most 256 queued events and drops the rest, so the
-- marker can be lost after a program queued that many: the set is also
-- dropped this many seconds after it was closed, when the queue has long
-- drained. (The timer's event is queued when it fires, behind everything
-- the set counted.)
local MARK_FALLBACK = 2

-- A Ctrl+T this soon after the prompt came back (or after a queued prompt
-- started), with no T key event since, is left over from cancelling the
-- turn before
local LEFTOVER_MS = 1000

-- How often a failed session's turn is resumed with "terminate" (the shell
-- tool needs two: stop, then abandon; a model request one)
local ABANDON_TRIES = 10

local function now()
  return os.epoch("utc")
end

-- An event by name and arguments (as capture.lua's eventKey)
local function eventKey(...)
  local parts = table.pack(...)
  for i = 1, parts.n do
    parts[i] = tostring(parts[i])
  end
  return table.concat(parts, "\0", 1, parts.n)
end

local Pump = {}
Pump.__index = Pump

-- A pump for ui (cc-code.basalt.ui) drawing with basalt; occode is the
-- cc-code module (turnCallbacks, showResult)
function app.newPump(ui, basalt, occode)
  return setmetatable({
    ui = ui, basalt = basalt, occode = occode,
    turn = nil,        -- the running turn: { co, filter, bang, started, auto, terminated }
    queue = {},        -- prompts typed during a turn, oldest first
    pending = nil,     -- the prompt that starts after the current event
    pendingAuto = false,
    promptSince = now(),
    sawT = false,      -- a T key event since the prompt (or queued turn) started
    recovering = false,
    watch = nil,       -- the running turn's os.queueEvent wrapper: { set (the open one), real, wrapper }
    sets = {},         -- input events code queued and not yet back, oldest first (the open set last)
  }, Pump)
end

-- A new set that counts input events, added to the sets
function Pump:openSet()
  markCount = markCount + 1
  local set = { id = now() .. "-" .. markCount, counts = {}, open = true }
  self.sets[#self.sets + 1] = set
  return set
end

-- While a turn runs: count the input events code queues (by name and
-- arguments), so that they go to the turn only when they come back. The
-- wrapper counts into the open set of the moment (watch.set).
function Pump:watchQueue()
  local real = os.queueEvent
  local watch = { real = real, set = self:openSet() }
  function watch.wrapper(name, ...)
    local set = watch.set
    if set.open and INPUT_EVENTS[name] then
      local key = eventKey(name, ...)
      set.counts[key] = (set.counts[key] or 0) + 1
    end
    return real(name, ...)
  end
  self.watch = watch
  os.queueEvent = watch.wrapper
end

-- Drop a set, and every older one: the queue is first in, first out, so
-- what they counted has come back too (or was dropped). Their fallback
-- timers are cancelled.
function Pump:dropSet(id)
  for i, set in ipairs(self.sets) do
    if set.id == id then
      for _ = 1, i do
        local old = table.remove(self.sets, 1)
        if old.timer then os.cancelTimer(old.timer) end
      end
      return
    end
  end
end

-- Close the watch's open set: a marker goes behind what it counted, with
-- the fallback timer. A set that counted nothing (or got it all back) is
-- removed alone: older sets still wait for their markers.
function Pump:closeSet(watch)
  local set = watch.set
  set.open = false
  if next(set.counts) then
    watch.real(MARK_EVENT, set.id)
    set.timer = os.startTimer(MARK_FALLBACK)
    return
  end
  for i = #self.sets, 1, -1 do
    if self.sets[i] == set then
      table.remove(self.sets, i)
      break
    end
  end
end

-- The turn yielded: if it queued input events since the set was opened,
-- close that set and count on in a new one (the same wrapper, so
-- capture.run's saved copy keeps counting)
function Pump:rotateSet()
  local watch = self.watch
  if watch and next(watch.set.counts) then
    self:closeSet(watch)
    watch.set = self:openSet()
  end
end

-- The set whose fallback timer this is, if any
function Pump:setOfTimer(timerId)
  for _, set in ipairs(self.sets) do
    if set.timer == timerId then
      return set
    end
  end
  return nil
end

-- The turn ended: put os.queueEvent back (unless something replaced it
-- since; the wrapper then only passes events on). The events it counted
-- that are still on the way keep going to nobody but a turn.
function Pump:unwatchQueue()
  local watch = self.watch
  if not watch then return end
  self.watch = nil
  if os.queueEvent == watch.wrapper then
    os.queueEvent = watch.real
  end
  self:closeSet(watch)
end

-- Count off one event from the sets; true if one had it
function Pump:countOff(key)
  for _, set in ipairs(self.sets) do
    local n = set.counts[key]
    if n then
      set.counts[key] = n > 1 and n - 1 or nil
      return true
    end
  end
  return false
end

-- Did code queue this input event (packed) during a turn? It is counted off.
-- A mouse event comes back one row higher when multishell shows its tab
-- bar (it gives the focused tab y - 1), so that form counts too.
function Pump:queuedByCode(ev)
  if #self.sets == 0 then return false end
  if self:countOff(eventKey(table.unpack(ev, 1, ev.n))) then
    return true
  end
  local name, a, x, y = ev[1], ev[2], ev[3], ev[4]
  if name:find("^mouse_") and type(y) == "number" then
    return self:countOff(eventKey(name, a, x, y + 1))
  end
  return false
end

-- A line was sent: start it after the current event, or queue it while a
-- turn runs
function Pump:submit(line)
  if line == "" then return end
  if self.turn or self.pending then
    self.queue[#self.queue + 1] = line
    self.ui.setQueued(#self.queue)
  else
    self.pending, self.pendingAuto = line, false
  end
end

-- Resume the turn with ev (nil: start it). An error in the turn is raised.
function Pump:resume(turn, ev)
  local ok, res
  if ev then
    ok, res = coroutine.resume(turn.co, table.unpack(ev, 1, ev.n))
  else
    ok, res = coroutine.resume(turn.co)
  end
  if not ok then
    self.turn = nil
    error(res, 0)
  end
  turn.filter = res
  if coroutine.status(turn.co) == "dead" then
    self:endTurn(turn)
  else
    self:rotateSet()
  end
end

function Pump:startTurn(line, auto)
  local ui, occode = self.ui, self.occode
  ui.printRole("user", line)
  ui.setStatus("Thinking...")
  local turn = {
    bang = line:sub(1, 1) == "!",
    started = now(),
    auto = auto,
  }
  turn.co = coroutine.create(function()
    local result = agent.process(line, occode.turnCallbacks(ui))
    if not self.recovering then
      occode.showResult(ui, result)
    end
  end)
  self.turn = turn
  self.sawT = false
  if turn.bang then
    -- The user's own program gets the keys
    ui.setProgramMode(true)
  end
  self:watchQueue()
  self:resume(turn, nil)
end

function Pump:endTurn(turn)
  local ui = self.ui
  if self.turn == turn then
    self.turn = nil
  end
  self:unwatchQueue()
  if turn.bang then
    ui.setProgramMode(false)
  end
  self.promptSince, self.sawT = now(), false
  if not ui.isRunning() then
    -- /exit: what was typed ahead is not sent
    self.queue = {}
    ui.setQueued(0)
    return
  end
  ui.setStatus("Ready")
  if #self.queue == 0 then return end
  if turn.terminated then
    -- The user stopped the turn with Ctrl+T: nothing more is sent. The
    -- oldest queued prompt goes back to the input line (when it is empty)
    -- to be sent or changed; all of them are in the input history.
    local first, count = self.queue[1], #self.queue
    self.queue = {}
    ui.setQueued(0)
    if ui.inputText() == "" then
      ui.setInput(first)
    end
    ui.print(count == 1 and "(The queued prompt was not sent.)"
      or ("(" .. count .. " queued prompts were not sent.)"), ui.colors and ui.colors.dim)
    return
  end
  self.pending, self.pendingAuto = table.remove(self.queue, 1), true
  ui.setQueued(#self.queue)
end

-- Ctrl+T at the prompt
function Pump:promptTerminate()
  local ui = self.ui
  if ui.clearInput() then
    return
  end
  if self.sawT or now() - self.promptSince >= LEFTOVER_MS then
    ui.stop()
  end
  -- Otherwise it is left over from cancelling the last turn: ignored
end

-- Route one event (packed)
function Pump:handle(ev)
  local name = ev[1]
  local ui, turn = self.ui, self.turn

  if (name == "http_success" or name == "http_failure")
    and aiUtils.discardStale(table.unpack(ev, 1, ev.n)) then
    -- A late reply to a request cancelled with Ctrl+T: closed unread
    return
  end

  if name == MARK_EVENT then
    -- The input events a finished turn queued have all come back
    self:dropSet(ev[2])
    return
  end
  if name == "timer" then
    local set = self:setOfTimer(ev[2])
    if set then
      -- The marker was lost (a full event queue): give up on the set
      self:dropSet(set.id)
      return
    end
  end

  if INPUT_EVENTS[name] and self:queuedByCode(ev) then
    -- Not from the user: for the turn only (a program reading its own
    -- queued keys), never the input line or a click
    if turn and (turn.filter == nil or turn.filter == name) then
      self:resume(turn, ev)
    end
    return
  end

  if name == "terminate" then
    if turn then
      if turn.auto and not self.sawT and now() - turn.started < LEFTOVER_MS then
        -- Left over from cancelling the turn before this queued one
        return
      end
      turn.terminated = true
      self:resume(turn, ev)
    else
      self:promptTerminate()
    end
    return
  end

  if name == "key" and ev[2] == keys.t then
    self.sawT = true
  end

  if turn and (turn.filter == nil or turn.filter == name) then
    self:resume(turn, ev)
  end
  if KEYS[name] and turn and turn.bang then
    -- Keys belong to the user's program
    return
  end

  if KEYS[name] then
    local handled, line = ui.inputEvent(ev)
    if line then
      self:submit(line)
    end
    if handled then return end
  elseif name == "mouse_scroll" then
    if ui.wheel(ev[2], ev[3], ev[4]) then return end
  elseif name == "term_resize" or name == "monitor_resize" then
    ui.checkSize()
  end
  self.basalt.update(table.unpack(ev, 1, ev.n))
end

-- The loop: until the UI stops (Ctrl+T at an empty prompt, /exit) and no
-- turn runs
function Pump:run()
  local ui, basalt = self.ui, self.basalt
  self.promptSince = now()
  basalt.update()
  while true do
    -- A prompt starts here, after the event that sent it was handled (so
    -- its turn never sees that Enter). A turn that ends without waiting
    -- (/help, a quick !ls) starts the next queued prompt at once.
    while self.pending and not self.turn do
      local line, auto = self.pending, self.pendingAuto
      self.pending, self.pendingAuto = nil, false
      self:startTurn(line, auto)
      basalt.update()
    end
    if not self.turn and not self.pending and not ui.isRunning() then
      break
    end
    local ev = table.pack(os.pullEventRaw())
    self:handle(ev)
    -- Draw what changed (nothing happens when nothing did)
    basalt.update()
  end
end

-- After a failure: resume a suspended turn with "terminate" until it ends.
-- capture.run then undoes its term.redirect and os.queueEvent wrapper.
function Pump:abandonTurn()
  local turn = self.turn
  self.recovering = true
  self.turn = nil
  self.pending = nil
  self.queue = {}
  if turn then
    for _ = 1, ABANDON_TRIES do
      if coroutine.status(turn.co) ~= "suspended" then break end
      coroutine.resume(turn.co, "terminate")
    end
  end
  -- (after capture.run put its own wrapper back)
  self:unwatchQueue()
end

-- Run a cc-code session in the Basalt UI. basalt: the Basalt API
-- (cc-code.basalt.load). Errors are raised after the screen was given
-- back.
function app.run(config, basalt)
  if type(basalt) ~= "table" or type(basalt.update) ~= "function" then
    error("cc-code.basalt.app.run: basalt must be the Basalt API", 2)
  end
  local occode = require("cc-code")
  local ui = require("cc-code.basalt.ui")
  local screen = term.current()
  local queueEvent, pullEvent = os.queueEvent, os.pullEvent

  basalt.setReactiveStrings(false)
  ui.setBasalt(basalt)
  local pump = app.newPump(ui, basalt, occode)
  -- The running session's pump (nil when none runs; tests look at it)
  app.pump = pump

  local ok, err = pcall(function()
    occode.startSession(ui, config or {})
    pump:run()
  end)
  if not ok then
    pcall(pump.abandonTurn, pump)
    capture.hooks = nil
    -- Whatever a turn cut short left changed
    if term.current() ~= screen then term.redirect(screen) end
    os.queueEvent, os.pullEvent = queueEvent, pullEvent
    pcall(ui.cleanup)
    app.pump = nil
    -- Errors from Basalt's scheduled tasks are tables
    error(type(err) == "table" and tostring(err) or err, 0)
  end
  -- (no turn runs here: its end already put os.queueEvent back)
  pump:unwatchQueue()
  app.pump = nil
  occode.endSession(ui)
end

return app

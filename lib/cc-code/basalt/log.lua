-- cc-code/basalt/log.lua
-- The chat log of the Basalt UI: messages wrapped once into display rows
-- (by screen cells, as tui.lua wraps them), and the scroll position. It
-- knows nothing about Basalt: the UI draws the rows that are on screen.
--
-- Messages are already prepared for display (cmn-utils.text forDisplay).
-- Colours are kept as given (CC colour constants); the UI maps them to
-- what it draws. Measuring and clipping is in cells (text.width/text.sub),
-- never with #.

local cctext = require("cmn-utils.text")

local width, csub = cctext.width, cctext.sub

-- Is s wider than n cells? (Cheap on vanilla: no full-length scan)
local function longerThan(s, n)
  return csub(s, n + 1, n + 1) ~= ""
end

-- Cut s to cols cells, ending in "..." when cut
local function cutTo(s, cols)
  if longerThan(s, cols) then
    return csub(s, 1, math.max(cols - 3, 1)) .. "..."
  end
  return s
end

-- A tool line that is too long keeps this many cells of its outcome
-- (" - " not counted) before its call is cut; the call keeps
-- TOOL_CALL_MIN cells at least (the same rules as tui.lua)
local TOOL_OUTCOME_MIN = 16
local TOOL_CALL_MIN = 8

-- A tool message as one row of cols cells: "* call - outcome" ("!" for a
-- failed call). The call is cut first, so the start of the outcome stays
-- visible; then the end of the whole row.
local function toolLineText(msg, cols)
  local head = msg.mark .. " "
  local call = msg.call
  if not msg.outcome then
    return cutTo(head .. call, cols)
  end
  local tail = " - " .. msg.outcome
  local avail = cols - width(head)
  local callWidth, tailWidth = width(call), width(tail)
  if callWidth + tailWidth > avail then
    local room = math.max(TOOL_CALL_MIN, avail - math.min(tailWidth, 3 + TOOL_OUTCOME_MIN))
    if callWidth > room then
      call = cutTo(call, room)
    end
  end
  return cutTo(head .. call .. tail, cols)
end

-- Wrap one line (no newlines) to cols cells, appending rows to out
local function wrapLine(line, cols, color, out)
  while longerThan(line, cols) do
    -- Break after the last word that fits; keep leading indentation. A
    -- space byte never occurs inside a UTF-8 sequence, so the byte
    -- position found in the cell-cut head is a safe place to cut.
    local cut = csub(line, 1, cols + 1):match("^.*%S() ")
    -- A following word too long for any line gets split anyway, so start
    -- it on this line instead of leaving most of the line empty
    if cut then
      local nextWord = line:match("^ +(%S+)", cut)
      if nextWord and longerThan(nextWord, cols) then
        cut = nil
      end
    end
    if cut then
      out[#out + 1] = { text = line:sub(1, cut - 1), color = color }
      line = line:sub(cut):gsub("^ +", "")
    else
      -- No space to break at: split the word by cells
      out[#out + 1] = { text = csub(line, 1, cols), color = color }
      line = csub(line, cols + 1)
    end
  end
  if line ~= "" then
    out[#out + 1] = { text = line, color = color }
  end
end

local Log = {}
Log.__index = Log

-- A new, empty log for rows of cols cells
function Log.new(cols)
  return setmetatable({
    cols = math.max(1, cols or 1),
    messages = {}, -- { text, color } or tool messages { tool, mark, call, outcome, color }
    rows = {},     -- wrapped display rows { text, color }
    offset = 0,    -- rows scrolled up from the bottom (0: following new rows)
  }, Log)
end

-- Append msg's rows; returns how many
function Log:wrap(msg)
  local rows = self.rows
  if msg.tool then
    rows[#rows + 1] = { text = toolLineText(msg, self.cols), color = msg.color }
    return 1
  end
  local lines = {}
  local str, start = msg.text, 1
  while true do
    local nl = str:find("\n", start, true)
    local before = #lines
    wrapLine(str:sub(start, nl and (nl - 1) or -1), self.cols, msg.color, lines)
    if #lines == before then
      lines[#lines + 1] = { text = "", color = msg.color }
    end
    if not nl then break end
    start = nl + 1
  end
  for i = 1, #lines do
    rows[#rows + 1] = lines[i]
  end
  return #lines
end

-- Drop the last n rows
function Log:dropRows(n)
  local rows = self.rows
  for _ = 1, n do
    rows[#rows] = nil
  end
end

-- New rows keep the view where it is: at the bottom it follows them;
-- scrolled back, the same rows stay on screen
function Log:keepView(added)
  if self.offset > 0 then
    self.offset = math.max(0, self.offset + added)
  end
end

-- Add a message (tool: { mark, call, outcome } for a one-row tool line).
-- Returns the message; its rows are counted in msg.lines.
function Log:add(text, color, tool)
  local msg = { text = text, color = color }
  if tool then
    msg.tool, msg.mark, msg.call, msg.outcome = true, tool.mark, tool.call, tool.outcome
  end
  self.messages[#self.messages + 1] = msg
  msg.lines = self:wrap(msg)
  self:keepView(msg.lines)
  return msg
end

-- Is msg the newest message?
function Log:isLast(msg)
  return self.messages[#self.messages] == msg
end

-- Wrap the newest message again after its text changed
function Log:rewrapLast()
  local msg = self.messages[#self.messages]
  local before = msg.lines
  self:dropRows(before)
  msg.lines = self:wrap(msg)
  self:keepView(msg.lines - before)
end

-- Finish the newest message, a tool line whose result came in. Returns
-- false when msg is no longer the newest message.
function Log:completeTool(msg, mark, outcome, color)
  if not self:isLast(msg) then
    return false
  end
  msg.mark, msg.outcome = mark, outcome
  msg.color = color or msg.color
  self:rewrapLast()
  return true
end

-- Wrap everything again for rows of cols cells (after a resize)
function Log:rewrap(cols)
  cols = math.max(1, cols)
  if cols == self.cols then return end
  self.cols = cols
  self.rows = {}
  for _, msg in ipairs(self.messages) do
    msg.lines = self:wrap(msg)
  end
end

-- Streamed text (UTF-8 chunks) appended to the newest message, or to a
-- new one; forDisplay prepares the text. An incomplete UTF-8 sequence at
-- the end of a chunk is held back until the next chunk.
function Log:stream(chunk, color, forDisplay)
  local msg = self.messages[#self.messages]
  if not (msg and msg.streaming) then
    msg = self:add("", color)
    msg.streaming = true
    msg.pending = ""
  end
  local raw = msg.pending .. chunk
  local tail = ""
  local rawLen = cctext.byteLen(raw)
  local i = rawLen
  while i > 0 and i > rawLen - 3 do
    local b = raw:byte(i)
    if b < 0x80 or b >= 0xC0 then
      local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
      if need > rawLen - i + 1 then
        tail = raw:sub(i)
        raw = raw:sub(1, i - 1)
      end
      break
    end
    i = i - 1
  end
  msg.pending = tail
  msg.text = msg.text .. forDisplay(raw)
  self:rewrapLast()
end

-- End streaming: the held-back bytes are shown as they are
function Log:endStream(forDisplay)
  local msg = self.messages[#self.messages]
  if msg and msg.streaming then
    msg.streaming = false
    if msg.pending ~= "" then
      msg.text = msg.text .. forDisplay(msg.pending)
      msg.pending = ""
      self:rewrapLast()
    end
  end
end

-- Empty the log
function Log:clear()
  self.messages = {}
  self.rows = {}
  self.offset = 0
end

-- How far the log can scroll up with this many rows on screen
function Log:maxOffset(viewRows)
  return math.max(0, #self.rows - viewRows)
end

-- Scroll up (n > 0) or down (n < 0) by n rows
function Log:scroll(n, viewRows)
  self.offset = math.max(0, math.min(self:maxOffset(viewRows), self.offset + n))
end

-- Keep the offset possible after the view got smaller or rows went away
function Log:clamp(viewRows)
  self.offset = math.min(self.offset, self:maxOffset(viewRows))
end

-- The rows to show with viewRows rows on screen: first and last index.
-- Short logs sit at the top, as in tui.lua.
function Log:window(viewRows)
  local first = math.max(1, #self.rows - viewRows + 1 - self.offset)
  local last = math.min(#self.rows, first + viewRows - 1)
  return first, last
end

return Log

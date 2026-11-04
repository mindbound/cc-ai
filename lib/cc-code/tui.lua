-- cc-code/tui.lua
-- Text User Interface for cc-code (ComputerCraft: Tweaked)
--
-- Draws into a window on the current terminal. Text is handled as CC charset
-- (one byte per glyph); everything coming from the model is converted from
-- UTF-8 once, when it is added to the content history.

local json = require("cmn-utils.json")
local cctext = require("cmn-utils.text")

-- The CC colour API ("tui.colors" below is the table of UI roles)
local ccColors = colors

local tui = {}

-- Colour scheme: UI role -> CC palette slot
local colorScheme = {
  background = ccColors.black,
  foreground = ccColors.white,
  prompt = ccColors.purple,
  user = ccColors.lime,
  assistant = ccColors.lightBlue,
  tool = ccColors.yellow,
  toolName = ccColors.magenta,
  error = ccColors.red,
  success = ccColors.lime,
  dim = ccColors.gray,
  border = ccColors.lightGray,
  highlight = ccColors.cyan,
  status = ccColors.brown,
}

-- Original theme RGB, loaded into the palette slots above on colour terminals
local themeRGB = {
  background = 0x1a1a2e,
  foreground = 0xeaeaea,
  prompt = 0x7b68ee,
  user = 0x98c379,
  assistant = 0x61afef,
  tool = 0xe5c07b,
  toolName = 0xc678dd,
  error = 0xe06c75,
  success = 0x98c379,
  dim = 0x5c6370,
  border = 0x3e4451,
  highlight = 0x2c323c,
  status = 0x282c34,
}

-- Monochrome scheme (basic computers: only white, lightGray, gray, black)
local monoScheme = {
  background = ccColors.black,
  foreground = ccColors.white,
  prompt = ccColors.white,
  user = ccColors.white,
  assistant = ccColors.white,
  tool = ccColors.white,
  toolName = ccColors.white,
  error = ccColors.white,
  success = ccColors.white,
  dim = ccColors.lightGray,
  border = ccColors.lightGray,
  highlight = ccColors.black,
  status = ccColors.gray,
}

-- Public role table (values are CC colour constants)
tui.colors = {}
for role, color in pairs(colorScheme) do
  tui.colors[role] = color
end

-- Valid CC colour values, used to sanitise colours passed to print()
local validColors = {}
for i = 0, 15 do
  validColors[2 ^ i] = true
end

-- State
local state = {
  width = 51,
  height = 19,
  scrollOffset = 0,
  messages = {},  -- logical messages { text, color } (CC charset)
  history = {},   -- wrapped display lines { text, color }
  inputBuffer = "",
  inputCursor = 0,
  cursorX = 4,
  reading = false,
  running = true,
  status = "Ready",
  showTools = true,
  -- Command popup state
  showCommandPopup = false,
  commandPopupIndex = 1,
  filteredCommands = {},
  completionType = nil,  -- nil for commands, else the handler's label
  popupNavigated = false,  -- Tab/Up/Down used on the popup since the last edit
  -- Command history state
  commandHistory = {},
  historyIndex = 0,  -- 0 = not browsing, 1+ = position from end
  savedInput = "",   -- saves current input when browsing history
  -- Held Ctrl keys (CC has no keyboard.isControlDown)
  ctrlHeld = {},
}

-- Terminal we draw on, the window we draw into, and whether we changed the
-- parent's palette
local parent, win
local paletteChanged = false

-- Available commands
local availableCommands = {
  { cmd = "/help", desc = "Show help and commands" },
  { cmd = "/?", desc = "Show help (alias)" },
  { cmd = "/model", desc = "View/switch AI model" },
  { cmd = "/turtle", desc = "Ask with turtle API context" },
  { cmd = "/clear", desc = "Clear conversation" },
  { cmd = "/exit", desc = "Exit cc-code" },
  { cmd = "/quit", desc = "Exit (alias)" },
}

-- Registered completion handlers: { prefix = { handler = fn, label = "Models" } }
local completionHandlers = {}

-- Header hints, longest first; the first one that fits beside the title is used
local headerHints = {
  "/help | PgUp/PgDn to scroll | /exit",
  "/help | PgUp/PgDn | /exit",
  "/help | /exit",
  "/help",
}

-- Popup footer hints, longest first. Escape never reaches a CC:T computer
-- (Minecraft closes the GUI), so the popup is passive: it only takes over
-- Enter/Up/Down after Tab has been used on it.
local popupHints = {
  "Tab: complete",
  "Tab",
}
local popupNavHints = {
  "Up/Down: choose  Enter: pick",
  "Enter: pick",
  "Enter",
}

---------------------------------------------------------------------------
-- Low-level drawing (all writes are clipped to the screen)
---------------------------------------------------------------------------

local function isCtrlDown()
  return next(state.ctrlHeld) ~= nil
end

-- Fill part of a row with spaces in a background colour
local function fill(x, y, w, bg)
  if y < 1 or y > state.height then return end
  if x < 1 then
    w = w + x - 1
    x = 1
  end
  if x + w - 1 > state.width then
    w = state.width - x + 1
  end
  if w <= 0 then return end
  win.setBackgroundColour(bg)
  win.setCursorPos(x, y)
  win.write(string.rep(" ", w))
end

-- Write text at x,y, clipped to column maxX (default: screen width)
local function put(x, y, s, fg, bg, maxX)
  if y < 1 or y > state.height or s == "" then return end
  maxX = math.min(maxX or state.width, state.width)
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  local avail = maxX - x + 1
  if avail <= 0 then return end
  if #s > avail then
    s = s:sub(1, avail)
  end
  win.setTextColour(fg)
  win.setBackgroundColour(bg)
  win.setCursorPos(x, y)
  win.write(s)
end

-- Put the blinking cursor on the input line while reading, hide it otherwise
local function placeCursor()
  if state.reading then
    win.setTextColour(tui.colors.foreground)
    win.setBackgroundColour(tui.colors.background)
    win.setCursorPos(math.max(1, math.min(state.cursorX, state.width)), state.height)
    win.setCursorBlink(true)
  else
    win.setCursorBlink(false)
  end
end

-- Palette slot -> { r, g, b } the parent had before the theme was loaded
local savedPalette = {}

-- Restore the palette slots the theme changed (on the parent terminal) to
-- what they were before init, so a user's custom palette survives
local function restorePalette()
  if not paletteChanged then return end
  local target = parent or term.current()
  for slot, rgb in pairs(savedPalette) do
    target.setPaletteColour(slot, rgb[1], rgb[2], rgb[3])
  end
  savedPalette = {}
  paletteChanged = false
end

-- Batch drawing: the window is hidden while drawing and shown (redrawn in
-- one go) at the end, so the screen does not flicker
local drawDepth = 0

local function draw(fn, ...)
  if not win then return end
  if drawDepth == 0 then
    win.setVisible(false)
  end
  drawDepth = drawDepth + 1
  local ok, err = pcall(fn, ...)
  drawDepth = drawDepth - 1
  if drawDepth == 0 and win then
    placeCursor()
    win.setVisible(true)
  end
  if not ok then
    error(err, 0)
  end
end

-- Truncate s to max bytes, marking the cut with ".."
local function truncate(s, max)
  if max <= 0 then return "" end
  if #s <= max then return s end
  if max <= 2 then return s:sub(1, max) end
  return s:sub(1, max - 2) .. ".."
end

---------------------------------------------------------------------------
-- Text wrapping and content history
---------------------------------------------------------------------------

-- Content area bounds (header at line 1, content from line 2, status at
-- height-1, input at height)
local function getContentBounds()
  return 2, 2, math.max(1, state.width - 2), math.max(0, state.height - 3)
end

-- Wrap one line (no newlines) to width, appending lines to out
local function wrapLine(line, width, color, out)
  while #line > width do
    -- Break after the last word that fits; keep leading indentation
    local cut = line:sub(1, width + 1):match("^.*%S() ")
    -- A following word too long for any line gets split anyway, so start
    -- it on this line instead of leaving most of the line empty
    if cut then
      local nextWord = line:match("^ +(%S+)", cut)
      if nextWord and #nextWord > width then
        cut = nil
      end
    end
    if cut then
      out[#out + 1] = { text = line:sub(1, cut - 1), color = color }
      line = line:sub(cut):gsub("^ +", "")
    else
      -- No space to break at: break the long word
      out[#out + 1] = { text = line:sub(1, width), color = color }
      line = line:sub(width + 1)
    end
  end
  if line ~= "" then
    out[#out + 1] = { text = line, color = color }
  end
end

-- Wrap a message into display lines; returns the number of lines added
local function wrapMessage(msg, width)
  local lines = {}
  local str = msg.text
  local start = 1
  while true do
    local nl = str:find("\n", start, true)
    local line = str:sub(start, nl and (nl - 1) or -1)
    local before = #lines
    wrapLine(line, width, msg.color, lines)
    if #lines == before then
      lines[#lines + 1] = { text = "", color = msg.color }
    end
    if not nl then break end
    start = nl + 1
  end
  for i = 1, #lines do
    state.history[#state.history + 1] = lines[i]
  end
  return #lines
end

-- Add an already-converted (CC charset) message to the history
local function addMessage(str, color)
  if not validColors[color] then
    color = tui.colors.foreground
  end
  local msg = { text = str, color = color }
  state.messages[#state.messages + 1] = msg
  local _, _, w = getContentBounds()
  msg.lines = wrapMessage(msg, w)
  return msg
end

-- Rebuild the wrapped history (after the width changed)
local function rewrapHistory()
  local _, _, w = getContentBounds()
  state.history = {}
  for _, msg in ipairs(state.messages) do
    msg.lines = wrapMessage(msg, w)
  end
end

-- Convert a value to a display string (CC charset)
local function toDisplay(value)
  if type(value) ~= "string" then
    local ok, encoded = pcall(json.encode, value)
    value = ok and encoded or tostring(value)
  end
  return cctext.toCC(value)
end

---------------------------------------------------------------------------
-- Command popup
---------------------------------------------------------------------------

-- Register a completion handler for a command prefix
-- handler(args) should return { {cmd, desc}, ... }
function tui.registerCompletion(prefix, handler, label)
  completionHandlers[prefix:lower()] = { handler = handler, label = label }
end

-- Filter commands based on input
local function filterCommands(input)
  if not input or input == "" then
    return {}, nil
  end

  -- Only show popup if input starts with /
  if input:sub(1, 1) ~= "/" then
    return {}, nil
  end

  -- Check registered completion handlers
  for prefix, reg in pairs(completionHandlers) do
    local pattern = "^" .. prefix:gsub("([^%w])", "%%%1") .. "%s+(.*)$"
    local args = input:lower():match(pattern)
    if args then
      local results = reg.handler(args)
      return results or {}, reg.label
    end
  end

  -- Standard command completion
  local filtered = {}
  local searchTerm = input:lower()
  for _, cmd in ipairs(availableCommands) do
    if cmd.cmd:lower():find(searchTerm, 1, true) == 1 then
      table.insert(filtered, cmd)
    end
  end

  return filtered, nil
end

-- Popup geometry, or nil when it does not fit on the screen
local function popupLayout()
  local count = #state.filteredCommands
  -- Rows between the header (1) and the status bar (height-1), keeping the
  -- original one-row gap above the status bar; 2 rows go to header/footer
  local maxItems = math.min(count, 8, state.height - 6)
  -- Use wider popup for custom completions (they tend to have longer names)
  local fullWidth = state.completionType and 50 or 35
  local popupWidth = math.min(fullWidth, state.width - 2)
  if maxItems < 1 or popupWidth < 6 then
    return nil
  end
  local popupX = 2
  local popupY = state.height - 2 - (maxItems + 2)
  return maxItems, popupWidth, popupX, popupY, popupWidth < fullWidth
end

-- Is the popup showing and actually drawn (it does not fit on tiny screens)?
local function popupVisible()
  return state.showCommandPopup and #state.filteredCommands > 0 and popupLayout() ~= nil
end

-- Text shown in the popup's command column
local function popupCmdText(cmd)
  local displayCmd = cctext.toCC(tostring(cmd.cmd or ""))
  if state.completionType then
    -- Strip the command prefix (e.g., "/model " from "/model google")
    displayCmd = displayCmd:match("^/%S+%s+(.+)$") or displayCmd
  end
  return displayCmd
end

-- Draw command popup above status bar
local function drawCommandPopup()
  if not state.showCommandPopup or #state.filteredCommands == 0 then
    return
  end
  local maxItems, popupWidth, popupX, popupY, narrow = popupLayout()
  if not maxItems then return end

  local c = tui.colors
  local right = popupX + popupWidth - 1
  local count = #state.filteredCommands

  -- Scroll the list so the selected item stays visible
  local first = 1
  if state.commandPopupIndex > maxItems then
    first = state.commandPopupIndex - maxItems + 1
  end

  -- Top border with context-aware header
  fill(popupX, popupY, popupWidth, c.status)
  local headerText = state.completionType and (state.completionType .. ":") or "Commands:"
  put(popupX, popupY, headerText, c.foreground, c.status, right)
  if count > maxItems then
    local pos = state.commandPopupIndex .. "/" .. count
    local px = right - #pos
    if px > popupX + #headerText then
      put(px, popupY, pos, c.dim, c.status, right)
    end
  end

  -- Use wider command column for custom completions
  local maxCmdLen = state.completionType and 28 or 12
  local maxDescLen = popupWidth - maxCmdLen - 4
  if narrow then
    -- The screen is narrower than the popup's full width: size the columns
    -- to the items so as little as possible is cut off
    local longestCmd, longestDesc = 0, 0
    for _, cmd in ipairs(state.filteredCommands) do
      longestCmd = math.max(longestCmd, #popupCmdText(cmd))
      longestDesc = math.max(longestDesc, #tostring(cmd.desc or ""))
    end
    local cmdNeed = math.min(maxCmdLen, longestCmd)
    if popupWidth - 4 - cmdNeed >= longestDesc then
      maxCmdLen = math.min(maxCmdLen, popupWidth - 4 - longestDesc)
    else
      maxCmdLen = cmdNeed
    end
    maxDescLen = popupWidth - maxCmdLen - 4
    if maxDescLen < 4 then
      -- Very narrow: split the space between command and description
      maxCmdLen = math.max(1, math.floor((popupWidth - 4) * 0.6))
      maxDescLen = popupWidth - maxCmdLen - 4
    end
  end

  -- Draw commands
  for i = 1, maxItems do
    local idx = first + i - 1
    local cmd = state.filteredCommands[idx]
    local y = popupY + i
    local bg, fg
    if idx == state.commandPopupIndex then
      bg, fg = c.highlight, c.assistant
    else
      bg, fg = c.status, c.foreground
    end
    fill(popupX, y, popupWidth, bg)

    if cmd then
      -- For custom completions, show just the argument part
      local displayCmd = popupCmdText(cmd)
      local descText = cctext.toCC(tostring(cmd.desc or ""))

      put(popupX + 1, y, truncate(displayCmd, maxCmdLen), fg, bg, right)
      if maxDescLen > 0 then
        put(popupX + maxCmdLen + 2, y, truncate(descText, maxDescLen), c.dim, bg, right)
      end
    end
  end

  -- Bottom border with hint
  local hintY = popupY + maxItems + 1
  fill(popupX, hintY, popupWidth, c.status)
  for _, hint in ipairs(state.popupNavigated and popupNavHints or popupHints) do
    if #hint <= popupWidth - 1 then
      put(popupX + 1, hintY, hint, c.dim, c.status, right)
      break
    end
  end
end

---------------------------------------------------------------------------
-- Screen parts (internal, unbatched)
---------------------------------------------------------------------------

local function drawHeaderBar()
  local c = tui.colors
  fill(1, 1, state.width, c.status)
  local title = "cc-code"
  put(2, 1, title, c.assistant, c.status)
  for _, hint in ipairs(headerHints) do
    local hx = state.width - #hint - 1
    if hx >= 2 + #title + 1 then
      put(hx, 1, hint, c.dim, c.status)
      break
    end
  end
end

local function drawStatusBar()
  local y = state.height - 1  -- Status bar is just above input
  if y < 2 then return end
  local c = tui.colors
  fill(1, y, state.width, c.status)
  put(2, y, state.status, c.dim, c.status)

  -- Show scroll indicator
  if state.scrollOffset > 0 then
    local scrollText = string.format("[Scroll: %d lines up]", state.scrollOffset)
    if state.width - #scrollText - 1 < 2 + #state.status + 1 then
      scrollText = string.format("[%d up]", state.scrollOffset)
    end
    put(math.max(1, state.width - #scrollText - 1), y, scrollText, c.tool, c.status)
  end
end

local function drawContentArea()
  local x, y, w, h = getContentBounds()
  local bg = tui.colors.background
  for row = y, y + h - 1 do
    fill(1, row, state.width, bg)
  end

  local startIdx = math.max(1, #state.history - h + 1 - state.scrollOffset)
  local endIdx = math.min(#state.history, startIdx + h - 1)

  local row = y
  for i = startIdx, endIdx do
    local entry = state.history[i]
    put(x, row, entry.text, entry.color or tui.colors.foreground, bg, x + w - 1)
    row = row + 1
  end

  drawCommandPopup()
end

local function drawInputLine()
  local y = state.height
  local c = tui.colors
  fill(1, y, state.width, c.background)
  put(2, y, "> ", c.prompt, c.background)

  local inputStart = 4
  local maxWidth = math.max(1, state.width - inputStart - 1)
  local displayText = state.inputBuffer
  local visibleCursorPos = state.inputCursor

  if #displayText > maxWidth then
    -- Keep some context to the right of the cursor (10 columns on wide
    -- screens, less on narrow ones)
    local margin = math.max(1, math.min(10, math.floor(maxWidth / 4)))
    local start = math.max(1, state.inputCursor - maxWidth + margin)
    displayText = state.inputBuffer:sub(start, start + maxWidth - 1)
    visibleCursorPos = state.inputCursor - (start - 1)
  end

  put(inputStart, y, displayText, c.foreground, c.background, inputStart + maxWidth - 1)
  state.cursorX = inputStart + visibleCursorPos
end

local function drawAll()
  win.setBackgroundColour(tui.colors.background)
  win.clear()
  drawHeaderBar()
  drawContentArea()
  drawStatusBar()
  drawInputLine()
end

-- Re-read the terminal size; resize the window and redraw if it changed
local function checkSize(force)
  if not win then return end
  local w, h = parent.getSize()
  if not force and w == state.width and h == state.height then
    return
  end
  local widthChanged = w ~= state.width
  state.width, state.height = w, h
  win.reposition(1, 1, w, h)
  if widthChanged then
    rewrapHistory()
  end
  local _, _, _, ch = getContentBounds()
  state.scrollOffset = math.min(state.scrollOffset, math.max(0, #state.history - ch))
  draw(drawAll)
end

---------------------------------------------------------------------------
-- Public drawing API
---------------------------------------------------------------------------

-- Initialize TUI
function tui.init(config)
  config = config or {}

  -- Undo a previous init that was not cleaned up
  restorePalette()

  parent = term.current()
  local mono = config.monochrome or not parent.isColour()

  -- Apply the colour scheme (in place, so references to tui.colors stay valid)
  for role, color in pairs(mono and monoScheme or colorScheme) do
    tui.colors[role] = color
  end

  state.width, state.height = parent.getSize()
  win = window.create(parent, 1, 1, state.width, state.height, true)

  -- Load the original theme into the palette (colour terminals only)
  if not mono then
    savedPalette = {}
    for role, rgb in pairs(themeRGB) do
      local slot = colorScheme[role]
      if not savedPalette[slot] then
        savedPalette[slot] = { parent.getPaletteColour(slot) }
      end
      win.setPaletteColour(slot, rgb)
    end
    paletteChanged = true
  end

  state.running = true
  state.scrollOffset = 0
  state.messages = {}
  state.history = {}
  state.inputBuffer = ""
  state.inputCursor = 0
  state.reading = false
  state.status = "Ready"
  state.showCommandPopup = false
  state.filteredCommands = {}
  state.commandPopupIndex = 1
  state.completionType = nil
  -- Preserve command history across init, but reset browsing state
  state.historyIndex = 0
  state.savedInput = ""
  drawDepth = 0
  draw(drawAll)
end

-- Draw header bar
function tui.drawHeader()
  draw(drawHeaderBar)
end

-- Draw status bar (above input line)
function tui.drawStatus()
  draw(drawStatusBar)
end

-- Set status message
function tui.setStatus(msg)
  state.status = cctext.toCC(tostring(msg or "Ready"))
  tui.drawStatus()
end

-- Clear content area
function tui.clearContent()
  draw(function()
    local _, y, _, h = getContentBounds()
    for row = y, y + h - 1 do
      fill(1, row, state.width, tui.colors.background)
    end
  end)
end

-- Redraw content area with history
function tui.redrawContent()
  draw(function()
    drawContentArea()
    drawStatusBar()
  end)
end

-- Draw input line (at the very bottom)
function tui.drawInput()
  draw(drawInputLine)
end

-- Print message to content area
function tui.print(msg, color)
  addMessage(cctext.toCC(tostring(msg)), color or tui.colors.foreground)
  -- Auto-scroll to bottom when new content is added
  state.scrollOffset = 0
  tui.redrawContent()
end

-- Print with role prefix
function tui.printRole(role, msg)
  local color, prefix
  if role == "user" then
    color = tui.colors.user
    prefix = "> "
  elseif role == "assistant" then
    color = tui.colors.assistant
    prefix = ""
  elseif role == "tool" then
    color = tui.colors.tool
    prefix = "  "
  elseif role == "error" then
    color = tui.colors.error
    prefix = "Error: "
  else
    color = tui.colors.foreground
    prefix = ""
  end

  tui.print(prefix .. tostring(msg), color)
end

-- Print tool call
function tui.printToolCall(name, args)
  if not state.showTools then return end
  tui.print(">> " .. tostring(name), tui.colors.toolName)
  if args then
    local argsStr = toDisplay(args)
    if #argsStr > 100 then
      argsStr = argsStr:sub(1, 97) .. "..."
    end
    addMessage("   " .. argsStr, tui.colors.dim)
    tui.redrawContent()
  end
end

-- Print tool result
function tui.printToolResult(name, result)
  if not state.showTools then return end
  local resultStr = toDisplay(result)
  if #resultStr > 200 then
    resultStr = resultStr:sub(1, 197) .. "..."
  end
  addMessage("<< " .. resultStr, tui.colors.dim)
  state.scrollOffset = 0
  tui.redrawContent()
end

-- Scroll functions
function tui.scrollUp(lines)
  lines = lines or 1
  local _, _, _, h = getContentBounds()
  local maxScroll = math.max(0, #state.history - h)
  state.scrollOffset = math.min(maxScroll, state.scrollOffset + lines)
  tui.redrawContent()
end

function tui.scrollDown(lines)
  lines = lines or 1
  state.scrollOffset = math.max(0, state.scrollOffset - lines)
  tui.redrawContent()
end

function tui.scrollToBottom()
  state.scrollOffset = 0
  tui.redrawContent()
end

function tui.scrollToTop()
  local _, _, _, h = getContentBounds()
  state.scrollOffset = math.max(0, #state.history - h)
  tui.redrawContent()
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

-- Close the popup without redrawing
local function clearPopupState()
  state.showCommandPopup = false
  state.filteredCommands = {}
  state.commandPopupIndex = 1
  state.completionType = nil
  state.popupNavigated = false
end

-- Do two completion lists hold the same commands?
local function sameCommands(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].cmd ~= b[i].cmd then return false end
  end
  return true
end

-- Update command popup state
local function updateCommandPopup()
  local previous = state.filteredCommands
  state.filteredCommands, state.completionType = filterCommands(state.inputBuffer)
  state.showCommandPopup = #state.filteredCommands > 0
  if sameCommands(previous, state.filteredCommands) then
    state.commandPopupIndex = math.min(state.commandPopupIndex, math.max(1, #state.filteredCommands))
  else
    -- A different list: highlight its first entry
    state.commandPopupIndex = 1
  end
end

-- The input was edited: refilter, and the popup is passive again
local function inputEdited()
  state.popupNavigated = false
  updateCommandPopup()
end

-- Hide command popup
local function hideCommandPopup()
  clearPopupState()
  tui.redrawContent()
end

-- Select command from popup
local function selectCommand()
  if state.showCommandPopup and state.filteredCommands[state.commandPopupIndex] then
    local cmd = state.filteredCommands[state.commandPopupIndex].cmd
    state.inputBuffer = cmd .. " "
    state.inputCursor = #state.inputBuffer
    hideCommandPopup()
    return true
  end
  return false
end

-- Insert text at the cursor
local function insertText(str)
  state.inputBuffer = state.inputBuffer:sub(1, state.inputCursor) ..
                      str ..
                      state.inputBuffer:sub(state.inputCursor + 1)
  state.inputCursor = state.inputCursor + #str
  inputEdited()
end

-- Show a command history entry (or the saved input for index 0)
local function showHistoryEntry()
  if state.historyIndex == 0 then
    state.inputBuffer = state.savedInput
  else
    state.inputBuffer = state.commandHistory[#state.commandHistory - state.historyIndex + 1]
  end
  state.inputCursor = #state.inputBuffer
  -- A recalled line is sent as it is: keep the popup closed (so Up/Down keep
  -- browsing history) until the next edit or Tab. readInput's loop redraws
  -- the content area under the old popup.
  clearPopupState()
end

-- Move the popup selection by delta (wrapping) and show it in the input
local function cyclePopup(delta, updateInput)
  local count = #state.filteredCommands
  state.commandPopupIndex = state.commandPopupIndex + delta
  if state.commandPopupIndex > count then
    state.commandPopupIndex = 1
  elseif state.commandPopupIndex < 1 then
    state.commandPopupIndex = count
  end
  if updateInput then
    local cmd = state.filteredCommands[state.commandPopupIndex]
    if cmd then
      state.inputBuffer = cmd.cmd
      state.inputCursor = #state.inputBuffer
    end
  end
  state.popupNavigated = true
end

-- Handle a "key" event; returns the submitted input when Enter submits
local function handleKey(code)
  local buf = state.inputBuffer

  if code == keys.enter or code == keys.numPadEnter then
    local only = state.filteredCommands[1]
    if popupVisible() and state.popupNavigated then
      -- The user picked an entry with Tab/Up/Down: take it
      selectCommand()
    elseif state.showCommandPopup and state.completionType == nil and
           #state.filteredCommands == 1 and #buf < #only.cmd then
      -- An unfinished command with one match ("/he"): complete it
      state.commandPopupIndex = 1
      selectCommand()
    else
      -- Submit the input exactly as typed; add to command history if
      -- different from last entry
      if buf ~= "" and state.commandHistory[#state.commandHistory] ~= buf then
        table.insert(state.commandHistory, buf)
      end
      return buf
    end

  elseif code == keys.tab then
    if not (state.showCommandPopup and #state.filteredCommands > 0) then
      updateCommandPopup()
    end
    if state.showCommandPopup and #state.filteredCommands > 0 then
      -- First Tab takes the highlighted entry; later Tabs cycle
      local cur = state.filteredCommands[state.commandPopupIndex]
      if cur and state.inputBuffer ~= cur.cmd then
        state.inputBuffer = cur.cmd
        state.inputCursor = #state.inputBuffer
        state.popupNavigated = true
      else
        cyclePopup(1, true)
      end
    end

  elseif code == keys.backspace then
    if state.inputCursor > 0 then
      state.inputBuffer = buf:sub(1, state.inputCursor - 1) .. buf:sub(state.inputCursor + 1)
      state.inputCursor = state.inputCursor - 1
      inputEdited()
    end

  elseif code == keys.delete then
    if state.inputCursor < #buf then
      state.inputBuffer = buf:sub(1, state.inputCursor) .. buf:sub(state.inputCursor + 2)
      inputEdited()
    end

  elseif code == keys.left then
    if isCtrlDown() then
      -- Move to previous word boundary
      local pos = state.inputCursor
      while pos > 0 and buf:sub(pos, pos):match("%s") do
        pos = pos - 1
      end
      while pos > 0 and not buf:sub(pos, pos):match("%s") do
        pos = pos - 1
      end
      state.inputCursor = pos
    else
      state.inputCursor = math.max(0, state.inputCursor - 1)
    end

  elseif code == keys.right then
    if isCtrlDown() then
      -- Move to next word boundary
      local len = #buf
      local pos = state.inputCursor
      while pos < len and not buf:sub(pos + 1, pos + 1):match("%s") do
        pos = pos + 1
      end
      while pos < len and buf:sub(pos + 1, pos + 1):match("%s") do
        pos = pos + 1
      end
      state.inputCursor = pos
    else
      state.inputCursor = math.min(#buf, state.inputCursor + 1)
    end

  elseif code == keys.up then
    if popupVisible() and state.popupNavigated then
      cyclePopup(-1, false)
    elseif isCtrlDown() then
      tui.scrollUp(1)
    elseif #state.commandHistory > 0 then
      -- Navigate command history (older)
      if state.historyIndex == 0 then
        state.savedInput = buf
      end
      if state.historyIndex < #state.commandHistory then
        state.historyIndex = state.historyIndex + 1
        showHistoryEntry()
      end
    end

  elseif code == keys.down then
    if popupVisible() and state.popupNavigated then
      cyclePopup(1, false)
    elseif isCtrlDown() then
      tui.scrollDown(1)
    elseif state.historyIndex > 0 then
      -- Navigate command history (newer)
      state.historyIndex = state.historyIndex - 1
      showHistoryEntry()
    end

  elseif code == keys.home then
    if isCtrlDown() then
      tui.scrollToTop()
    else
      state.inputCursor = 0
    end

  elseif code == keys["end"] then
    if isCtrlDown() then
      tui.scrollToBottom()
    else
      state.inputCursor = #buf
    end

  elseif code == keys.pageUp then
    tui.scrollUp(5)

  elseif code == keys.pageDown then
    tui.scrollDown(5)
  end

  return nil
end

-- Reset the input line state
local function resetInput()
  state.inputBuffer = ""
  state.inputCursor = 0
  state.historyIndex = 0
  state.savedInput = ""
end

-- Leave readInput: hide popup, clear the input line, hide the cursor
local function finishInput()
  resetInput()
  state.reading = false
  clearPopupState()
  draw(function()
    drawContentArea()
    drawStatusBar()
    drawInputLine()
  end)
end

-- Read user input. Returns the submitted line, or nil when the user asked to
-- quit (Ctrl+T on an empty line).
function tui.readInput()
  if not win then
    error("tui.init() must be called before tui.readInput()", 2)
  end
  resetInput()
  clearPopupState()
  state.ctrlHeld = {}
  state.reading = true

  -- A Ctrl+T held to cancel a request can land here if the reply came first.
  -- A fresh Ctrl+T sends a key event for T before the terminate, so quit
  -- only after one, or once the prompt has been up for a second.
  local startedAt = os.epoch("utc")
  local sawT = false

  -- The terminal may have been resized while we were not reading events
  checkSize()
  draw(function()
    drawContentArea()
    drawStatusBar()
    drawInputLine()
  end)

  while true do
    local ev, p1 = os.pullEventRaw()
    local hadPopup = state.showCommandPopup
    local changed = false

    if ev == "terminate" then
      if state.inputBuffer ~= "" then
        -- Ctrl+T with text: clear the line and keep reading
        resetInput()
        clearPopupState()
        changed = true
      elseif sawT or os.epoch("utc") - startedAt >= 1000 then
        finishInput()
        return nil
      end
      -- Otherwise it is left over from cancelling the last request: ignore it

    elseif ev == "char" then
      insertText(p1)
      changed = true

    elseif ev == "key" then
      if p1 == keys.t then
        sawT = true
      end
      if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
        state.ctrlHeld[p1] = true
      else
        local submitted = handleKey(p1)
        if submitted then
          finishInput()
          return submitted
        end
        changed = true
      end

    elseif ev == "key_up" then
      if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
        state.ctrlHeld[p1] = nil
      end

    elseif ev == "paste" then
      local pasted = tostring(p1 or ""):gsub("\r?\n", " ")
      if pasted ~= "" then
        insertText(pasted)
        changed = true
      end

    elseif ev == "mouse_scroll" then
      -- Mouse wheel: -1 = up (back in history), 1 = down
      if p1 == -1 then
        tui.scrollUp(3)
      elseif p1 == 1 then
        tui.scrollDown(3)
      end

    elseif ev == "term_resize" or ev == "monitor_resize" then
      checkSize()
    end

    if changed then
      draw(function()
        -- Redraw the content under the popup when it was or is visible, so a
        -- shrinking or closing popup leaves nothing behind
        if hadPopup or state.showCommandPopup then
          drawContentArea()
        end
        drawInputLine()
      end)
    end
  end
end

-- Show streaming text (chunks of UTF-8, appended to the last message)
function tui.streamText(chunk)
  chunk = tostring(chunk)
  local msg = state.messages[#state.messages]
  if not (msg and msg.streaming) then
    msg = addMessage("", tui.colors.assistant)
    msg.streaming = true
    msg.pending = ""
  end
  -- Hold back an incomplete UTF-8 sequence at the end of the chunk
  local raw = msg.pending .. chunk
  local tail = ""
  local i = #raw
  while i > 0 and i > #raw - 3 do
    local b = raw:byte(i)
    if b < 0x80 or b >= 0xC0 then
      local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
      if need > #raw - i + 1 then
        tail = raw:sub(i)
        raw = raw:sub(1, i - 1)
      end
      break
    end
    i = i - 1
  end
  msg.pending = tail
  msg.text = msg.text .. cctext.toCC(raw)

  -- Re-wrap this message
  for _ = 1, msg.lines do
    state.history[#state.history] = nil
  end
  local _, _, w = getContentBounds()
  msg.lines = wrapMessage(msg, w)

  -- Auto-scroll to bottom during streaming
  state.scrollOffset = 0
  tui.redrawContent()
end

-- End streaming (mark as complete)
function tui.endStream()
  local msg = state.messages[#state.messages]
  if msg and msg.streaming then
    msg.streaming = false
    if msg.pending ~= "" then
      msg.text = msg.text .. cctext.toCC(msg.pending)
      msg.pending = ""
      for _ = 1, msg.lines do
        state.history[#state.history] = nil
      end
      local _, _, w = getContentBounds()
      msg.lines = wrapMessage(msg, w)
      tui.redrawContent()
    end
  end
end

-- Clear conversation
function tui.clear()
  state.messages = {}
  state.history = {}
  state.scrollOffset = 0
  tui.clearContent()
end

-- Put the parent's own palette back for a while, e.g. while a shell command
-- runs that may open a multishell tab (a new tab copies the palette it sees)
function tui.suspendTheme()
  if not paletteChanged or not parent then return end
  for slot, rgb in pairs(savedPalette) do
    parent.setPaletteColour(slot, rgb[1], rgb[2], rgb[3])
  end
end

-- Load the theme again after suspendTheme (showing the window pushes its
-- palette to the parent)
function tui.resumeTheme()
  if not paletteChanged then return end
  draw(function() end)
end

-- Cleanup on exit: restore the palette and leave a clean white-on-black screen
function tui.cleanup()
  state.reading = false
  local target = parent or term.current()
  if win then
    win.setCursorBlink(false)
    win.setVisible(false)
  end
  restorePalette()
  target.setCursorBlink(false)
  target.setBackgroundColour(ccColors.black)
  target.setTextColour(ccColors.white)
  target.clear()
  target.setCursorPos(1, 1)
  win = nil
  drawDepth = 0
end

-- Check if running
function tui.isRunning()
  return state.running
end

-- Stop running
function tui.stop()
  state.running = false
end

return tui

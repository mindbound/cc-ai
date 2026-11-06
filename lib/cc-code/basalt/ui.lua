-- cc-code/basalt/ui.lua
-- The Basalt UI for cc-code (a trial: `cc-code --basalt`, or the setting
-- cc-code.ui = "basalt"). It offers the calls cc-code.tui offers (print,
-- printRole, printToolCall/printToolResult, setStatus, clear, the theme
-- hooks, ...), drawn with Basalt elements, but it does not read input
-- itself: cc-code.basalt.app runs the event loop, hands every event to
-- Basalt with basalt.update, and asks this module what keys do
-- (ui.inputEvent).
--
-- Layout (as tui.lua): header on row 1, the log on rows 2..h-2 (text in
-- columns 2..w-1), the status bar on row h-1, the input line on row h, and
-- the command popup above the status bar. The log is a Canvas that draws
-- the wrapped rows on screen (cc-code.basalt.log); the input line is a
-- Basalt Input; the popup is a List with a Canvas for its header and
-- footer rows.
--
-- This module can be required without Basalt (skills register completions
-- before the UI starts): app.lua passes Basalt in with ui.setBasalt before
-- ui.init. Text from the model and the user is only ever drawn by the
-- Canvas callbacks, put in the Input's text (a raw string) or in List
-- items (shown as written); Basalt's reactive strings are off as well.
-- Text is measured and cut in cells (cmn-utils.text width/sub), never #.

local json = require("cmn-utils.json")
local cctext = require("cmn-utils.text")
local toolview = require("cc-code.toolview")
local Log = require("cc-code.basalt.log")

local width, csub = cctext.width, cctext.sub

-- Is s wider than n cells?
local function longerThan(s, n)
  return csub(s, n + 1, n + 1) ~= ""
end

-- The CC colour API ("ui.colors" below is the table of UI roles)
local ccColors = colors

local ui = {}

-- Colour roles -> CC colour constants (the same slots as tui.lua). These
-- are the values ui.colors holds and print() takes; on colour screens they
-- are drawn in the theme's RGB colours (basalt.rgb), on basic computers as
-- the plain colours of monoScheme.
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

-- The theme's RGB per role (tui.lua's themeRGB)
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
  -- The popup's selected row: the status color (tui.lua uses the nearly
  -- identical 0x2c323c), so basalt.rgb gives the same color and no dark
  -- color first shows after the first frame (see themeOrder)
  highlight = 0x282c34,
  status = 0x282c34,
}

-- The order the theme's colours are registered in (basalt.rgb). Basalt
-- gives each colour on screen the lowest free palette slot, in this order
-- (white, orange, magenta, lightBlue, yellow, ...; black is not reached),
-- and keeps it there while it stays on screen. multishell draws the
-- current tab's title in the yellow slot (4) on black, and the other tabs
-- in black on the gray slot (7), from the focused tab's palette. So the
-- dark roles go first: the first frame shows at most three of them
-- (background, status, dim), which take slots 0 to 2, and the yellow and
-- gray slots get a light colour (foreground on the welcome screen) or keep
-- their own. A colour that first shows later takes the lowest slot free
-- then, so no dark colour may first show later: the popup's highlight is
-- the status colour (the same palette entry). A fixed list:
-- pairs() would leave the slots to the VM's iteration order (on CC:
-- Tweaked it put the background in yellow).
local themeOrder = {
  -- dark
  "background", "status", "highlight", "border", "dim",
  -- light
  "assistant", "foreground", "prompt", "error", "user", "success", "tool", "toolName",
}

-- Basic computers: only white, lightGray, gray and black
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

-- Public role table (CC colour constants), filled in place by init
ui.colors = {}
for role, color in pairs(colorScheme) do
  ui.colors[role] = color
end

-- Valid CC colour values, for colours passed to print()
local validColors = {}
for i = 0, 15 do
  validColors[2 ^ i] = true
end

-- Built-in commands for the popup (as tui.lua); skills add theirs
local availableCommands = {
  { cmd = "/help", desc = "Show help and commands" },
  { cmd = "/?", desc = "Show help (alias)" },
  { cmd = "/model", desc = "View/switch AI model" },
  { cmd = "/turtle", desc = "Add the turtle API reference" },
  { cmd = "/tools", desc = "Tool lines: short|full|off" },
  { cmd = "/clear", desc = "Clear conversation" },
  { cmd = "/exit", desc = "Exit cc-code" },
  { cmd = "/quit", desc = "Exit (alias)" },
}

-- Registered completion handlers: { prefix = { handler = fn, label = "Models" } }
local completionHandlers = {}

-- Header hints, longest first; the first that fits beside the title
local headerHints = {
  "/help | PgUp/PgDn to scroll | /exit",
  "/help | PgUp/PgDn | /exit",
  "/help | /exit",
  "/help",
}

-- Popup footer hints, longest first. The popup is passive until Tab.
local popupHints = { "Tab: complete", "Tab" }
local popupNavHints = { "Up/Down: choose  Enter: pick", "Enter: pick", "Enter" }

local state = {
  running = true,
  status = "Ready",
  statusParts = nil,
  toolDisplay = "short",  -- /tools: "short", "full" or "off"
  pendingTool = nil,      -- the short tool line waiting for its result
  queued = 0,             -- prompts typed ahead, sent when the turn ends
  -- Command popup
  showPopup = false,
  popupIndex = 1,
  filtered = {},
  completionType = nil,   -- nil for commands, else the handler's label
  popupNavigated = false, -- Tab/Up/Down used on the popup since the last edit
  -- Input history (kept across init calls)
  history = {},
  historyIndex = 0,       -- 0 = not browsing, 1+ = position from the end
  savedInput = "",
  -- Held Ctrl keys
  ctrlHeld = {},
}

local log = Log.new(49)

-- Basalt, the terminal it draws on, its size, the elements, and what each
-- role colour is drawn as (theme RGB handles on colour screens)
local basalt, parent
local W, H = 51, 19
local frame, header, logView, statusView, inputBar, input, popupBox, popupList
local paint = {}
local mono = false

local function P(color)
  return paint[color] or color
end

-- Something changed: the next basalt.update draws the tree again
local function changed()
  if frame then frame:markRenderDirty() end
end

-- Rows of the log on screen
local function viewRows()
  return math.max(0, H - 3)
end

local function isCtrlDown()
  return next(state.ctrlHeld) ~= nil
end

-- Truncate s to max cells, marking the cut with ".."
local function truncate(s, max)
  if max <= 0 then return "" end
  if not longerThan(s, max) then return s end
  if max <= 2 then return csub(s, 1, max) end
  return csub(s, 1, max - 2) .. ".."
end

-- s cut or padded with spaces to n cells
local function padTo(s, n)
  s = truncate(s, n)
  return s .. string.rep(" ", n - width(s))
end

-- A value as display text (JSON for tables)
local function toDisplay(value)
  if type(value) ~= "string" then
    local ok, encoded = pcall(json.encode, value)
    value = ok and encoded or tostring(value)
  end
  return cctext.forDisplay(value)
end

---------------------------------------------------------------------------
-- Command popup
---------------------------------------------------------------------------

-- Register a completion handler for a command prefix (works before init):
-- handler(args) returns { { cmd = "/model google", desc = "..." }, ... }
function ui.registerCompletion(prefix, handler, label)
  completionHandlers[prefix:lower()] = { handler = handler, label = label }
end

-- The popup entries for the input line, and the completion label (nil for
-- the command list)
local function filterCommands(text)
  if not text or text == "" or text:sub(1, 1) ~= "/" then
    return {}, nil
  end
  local lower = text:lower()
  for prefix, reg in pairs(completionHandlers) do
    local pattern = "^" .. prefix:gsub("([^%w])", "%%%1") .. "%s+(.*)$"
    local args = lower:match(pattern)
    if args then
      -- A failing handler shows no entries (it must not end cc-code)
      local ok, results = pcall(reg.handler, args)
      return (ok and type(results) == "table") and results or {}, reg.label
    end
  end
  local filtered = {}
  for _, cmd in ipairs(availableCommands) do
    if cmd.cmd:lower():find(lower, 1, true) == 1 then
      filtered[#filtered + 1] = cmd
    end
  end
  return filtered, nil
end

-- Popup geometry, or nil when it does not fit
local function popupLayout()
  local maxItems = math.min(#state.filtered, 8, H - 6)
  local fullWidth = state.completionType and 50 or 35
  local popupWidth = math.min(fullWidth, W - 2)
  if maxItems < 1 or popupWidth < 6 then
    return nil
  end
  return maxItems, popupWidth, 2, H - 2 - (maxItems + 2), popupWidth < fullWidth
end

local function popupVisible()
  return state.showPopup and #state.filtered > 0 and popupLayout() ~= nil
end

-- Text of an entry's command column
local function popupCmdText(cmd)
  local shown = cctext.forDisplay(tostring(cmd.cmd or ""))
  if state.completionType then
    -- Without the command ("/model google" -> "google")
    shown = shown:match("^/%S+%s+(.+)$") or shown
  end
  return shown
end

-- Widths of the command and description columns (as tui.lua)
local function popupColumns(popupWidth, narrow)
  local cmdLen = state.completionType and 28 or 12
  local descLen = popupWidth - cmdLen - 4
  if narrow then
    local longestCmd, longestDesc = 0, 0
    for _, cmd in ipairs(state.filtered) do
      longestCmd = math.max(longestCmd, width(popupCmdText(cmd)))
      longestDesc = math.max(longestDesc, width(cctext.forDisplay(tostring(cmd.desc or ""))))
    end
    local cmdNeed = math.min(cmdLen, longestCmd)
    if popupWidth - 4 - cmdNeed >= longestDesc then
      cmdLen = math.min(cmdLen, popupWidth - 4 - longestDesc)
    else
      cmdLen = cmdNeed
    end
    descLen = popupWidth - cmdLen - 4
    if descLen < 4 then
      cmdLen = math.max(1, math.floor((popupWidth - 4) * 0.6))
      descLen = popupWidth - cmdLen - 4
    end
  end
  return cmdLen, descLen
end

-- Show the popup state in the popup elements
local function refreshPopup()
  if not popupList then return end
  local maxItems, popupWidth, popupX, popupY, narrow = popupLayout()
  local show = state.showPopup and #state.filtered > 0 and maxItems ~= nil
  popupBox.visible = show
  popupList.visible = show
  if not show then return end
  popupBox:setBounds(popupX, popupY, popupWidth, maxItems + 2)
  popupList:setBounds(popupX, popupY + 1, popupWidth, maxItems)
  local cmdLen, descLen = popupColumns(popupWidth, narrow)
  local items = {}
  for i, cmd in ipairs(state.filtered) do
    local row = " " .. padTo(popupCmdText(cmd), cmdLen)
    if descLen > 0 then
      row = row .. " " .. truncate(cctext.forDisplay(tostring(cmd.desc or "")), descLen)
    end
    items[i] = { text = row }
  end
  popupList.items = items
  popupList:selectItem(state.popupIndex, false)
  -- The highlight stays on the last row when the list scrolls (tui.lua)
  popupList:setOffset(math.max(0, state.popupIndex - maxItems))
  changed()
end

-- Close the popup (state only)
local function clearPopupState()
  state.showPopup = false
  state.filtered = {}
  state.popupIndex = 1
  state.completionType = nil
  state.popupNavigated = false
end

local function sameCommands(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].cmd ~= b[i].cmd then return false end
  end
  return true
end

-- Refilter for the current input
local function updateCommandPopup()
  local previous = state.filtered
  state.filtered, state.completionType = filterCommands(input and input.text or "")
  state.showPopup = #state.filtered > 0
  if sameCommands(previous, state.filtered) then
    state.popupIndex = math.min(state.popupIndex, math.max(1, #state.filtered))
  else
    state.popupIndex = 1
  end
end

-- The input was edited: refilter; the popup is passive again
local function inputEdited()
  state.popupNavigated = false
  updateCommandPopup()
  refreshPopup()
end

-- Put text in the input line with the cursor at its end
local function setInputText(text)
  input.text = text
  input:setCursorPos(math.huge)
  changed()
end

-- Take the highlighted entry (with a trailing space) and close the popup
local function selectCommand()
  local entry = state.showPopup and state.filtered[state.popupIndex]
  if not entry then return false end
  setInputText(entry.cmd .. " ")
  clearPopupState()
  refreshPopup()
  return true
end

-- Move the highlight by delta (wrapping); optionally show it in the input
local function cyclePopup(delta, updateInput)
  local count = #state.filtered
  state.popupIndex = state.popupIndex + delta
  if state.popupIndex > count then
    state.popupIndex = 1
  elseif state.popupIndex < 1 then
    state.popupIndex = count
  end
  if updateInput then
    local cmd = state.filtered[state.popupIndex]
    if cmd then setInputText(cmd.cmd) end
  end
  state.popupNavigated = true
end

---------------------------------------------------------------------------
-- Drawing (Canvas callbacks; they run inside basalt.update)
---------------------------------------------------------------------------

local function drawHeader(self, buf)
  local c = ui.colors
  local title = "cc-code"
  buf:blit(2, 1, title, P(c.assistant), P(c.status))
  for _, hint in ipairs(headerHints) do
    local hx = self.width - width(hint) - 1
    if hx >= 2 + width(title) + 1 then
      buf:blit(hx, 1, hint, P(c.dim), P(c.status))
      break
    end
  end
end

-- The status in at most maxWidth cells: parts are dropped from the end
-- until it fits (the first part always stays)
local function statusText(maxWidth)
  local parts = state.statusParts
  if not parts then
    return truncate(state.status, maxWidth)
  end
  for n = #parts, 2, -1 do
    local candidate = table.concat(parts, " - ", 1, n)
    if not longerThan(candidate, maxWidth) then
      return candidate
    end
  end
  return truncate(parts[1] or "", maxWidth)
end

-- The right side of the status bar in w cells: prompts typed ahead, and
-- the scroll position (shortened, as in tui.lua, when it would crowd the
-- status; the status gives way to the queue instead)
local function indicatorText(w)
  local queued = state.queued > 0 and ("[" .. state.queued .. " queued]") or nil
  local scroll
  if log.offset > 0 then
    scroll = string.format("[Scroll: %d lines up]", log.offset)
    local used = width(scroll) + (queued and (width(queued) + 1) or 0)
    if w - used - 1 < 2 + width(statusText(w)) + 1 then
      scroll = string.format("[%d up]", log.offset)
    end
  end
  if queued and scroll then
    return queued .. " " .. scroll
  end
  return queued or scroll
end

local function drawStatus(self, buf)
  local c = ui.colors
  local w = self.width
  local right = indicatorText(w)
  local room = w - 2 - (right and (width(right) + 2) or 0)
  local text = statusText(math.max(1, room))
  if text ~= "" then
    buf:blit(2, 1, text, P(c.dim), P(c.status))
  end
  if right then
    buf:blit(math.max(1, w - width(right) - 1), 1, right, P(c.tool), P(c.status))
  end
end

-- The log draws whole rows (margin, text, padding to the right edge), so
-- it needs no background fill: one write per row on screen. A row keeps
-- its padded text for the width it was last drawn at.
local blankRow = { width = 0, text = "" }

local function drawLog(self, buf)
  local rows = log.rows
  local w, h = self.width, self.height
  local first, last = log:window(h)
  local fg, bg = P(ui.colors.foreground), P(ui.colors.background)
  if blankRow.width ~= w then
    blankRow.width, blankRow.text = w, string.rep(" ", w)
  end
  local y = 1
  for i = first, last do
    local row = rows[i]
    if row.padWidth ~= w then
      row.padWidth = w
      row.padded = " " .. row.text .. string.rep(" ", math.max(0, w - 1 - width(row.text)))
    end
    buf:blit(1, y, row.padded, P(row.color), bg)
    y = y + 1
  end
  for rest = y, h do
    buf:blit(1, rest, blankRow.text, fg, bg)
  end
end

local function drawInputBar(_, buf)
  local c = ui.colors
  buf:blit(2, 1, ">", P(c.prompt), P(c.background))
end

local function drawPopupBox(self, buf)
  local c = ui.colors
  local w, h = self.width, self.height
  local headerText = state.completionType and (state.completionType .. ":") or "Commands:"
  buf:blit(1, 1, truncate(headerText, w), P(c.foreground), P(c.status))
  local count = #state.filtered
  if count > h - 2 then
    local pos = state.popupIndex .. "/" .. count
    local px = w - width(pos)
    if px > 1 + width(headerText) then
      buf:blit(px, 1, pos, P(c.dim), P(c.status))
    end
  end
  for _, hint in ipairs(state.popupNavigated and popupNavHints or popupHints) do
    if width(hint) <= w - 1 then
      buf:blit(2, h, hint, P(c.dim), P(c.status))
      break
    end
  end
end

-- Place the elements for the current size
local function relayout()
  local w, h = W, H
  header:setBounds(1, 1, w, 1)
  logView:setBounds(1, 2, w, viewRows())
  statusView:setBounds(1, math.max(1, h - 1), w, 1)
  inputBar:setBounds(1, h, w, 1)
  -- The text area of tui.lua's input line: columns 4..w-2
  input:setBounds(4, h, math.max(1, w - 5), 1)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- The Basalt API to draw with (app.lua passes it in before init)
function ui.setBasalt(api)
  basalt = api
end

-- A popup row clicked: take it, as Enter after Tab does
local function onPopupSelect(_, index)
  if type(index) == "number" and state.filtered[index] then
    state.popupIndex = index
    selectCommand()
  end
end

-- Build the UI on the current terminal
function ui.init(config)
  config = config or {}
  if not basalt then
    error("cc-code.basalt.ui: ui.setBasalt(basalt) must be called before ui.init()", 2)
  end
  parent = term.current()
  mono = config.monochrome or not parent.isColour()
  for role, color in pairs(mono and monoScheme or colorScheme) do
    ui.colors[role] = color
  end
  paint = {}
  if not mono then
    for _, role in ipairs(themeOrder) do
      paint[colorScheme[role]] = basalt.rgb(themeRGB[role])
    end
  end
  -- "{...}" in element properties stays text; cells as cc-code measures them
  basalt.setReactiveStrings(false)
  basalt.text.setUtf8(cctext.unicodeTerminal())

  W, H = parent.getSize()
  local c = ui.colors

  frame = basalt.getMainFrame()
  -- (a main frame left by an earlier run on this Basalt draws here again)
  frame:setTerm(parent)
  frame:setFocused(nil)
  local old = {}
  for i, child in ipairs(frame:getChildren()) do old[i] = child end
  for _, child in ipairs(old) do frame:removeChild(child) end
  -- Clicks never take the keyboard focus from the input line
  frame.focusOnClick = false
  -- The elements cover the whole screen: no fill under them (it would
  -- cost a full-screen write on every frame)
  frame.background = false
  frame.foreground = P(c.foreground)

  local function canvas(draw, bg)
    return frame:addCanvas({ draw = draw, background = bg and P(bg) or false, foreground = P(c.foreground),
      focusOnClick = false })
  end
  header = canvas(drawHeader, c.status)
  logView = canvas(drawLog, nil)
  statusView = canvas(drawStatus, c.status)
  inputBar = canvas(drawInputBar, c.background)
  input = frame:addInput({
    background = P(c.background), foreground = P(c.foreground),
    placeholderColor = P(c.dim), focusOnClick = false, z = 1,
  })
  input:on("change", inputEdited)
  popupBox = canvas(drawPopupBox, c.status)
  popupBox.z = 50
  popupBox.visible = false
  popupList = frame:addList({
    background = P(c.status), foreground = P(c.foreground),
    selectionBackground = P(c.highlight), selectionForeground = P(c.assistant),
    scrollbar = "hidden", focusOnClick = false, z = 51, visible = false,
  })
  popupList:on("select", onPopupSelect)
  relayout()
  input:focus()

  state.running = true
  state.status = "Ready"
  state.statusParts = nil
  state.pendingTool = nil
  state.queued = 0
  state.ctrlHeld = {}
  state.historyIndex = 0
  state.savedInput = ""
  clearPopupState()
  log = Log.new(W - 2)
  changed()
end

---------------------------------------------------------------------------
-- Status, printing, tool lines
---------------------------------------------------------------------------

-- Status: a string, or a list of parts dropped from the end to fit.
-- (Called from inside the SDK's wait hooks: it only changes state.)
function ui.setStatus(msg)
  if type(msg) == "table" then
    local parts = {}
    for i, part in ipairs(msg) do
      parts[i] = cctext.forDisplay(tostring(part))
    end
    state.statusParts = parts
    state.status = parts[1] or ""
  else
    state.statusParts = nil
    state.status = cctext.forDisplay(tostring(msg or "Ready"))
  end
  changed()
end

-- Add a prepared message to the log
local function addMessage(text, color, tool)
  if not validColors[color] then
    color = ui.colors.foreground
  end
  local msg = log:add(text, color, tool)
  changed()
  return msg
end

function ui.print(msg, color)
  addMessage(cctext.forDisplay(tostring(msg)), color or ui.colors.foreground)
end

function ui.printRole(role, msg)
  local c = ui.colors
  local color, prefix
  if role == "user" then
    color, prefix = c.user, "> "
  elseif role == "assistant" then
    color, prefix = c.assistant, ""
  elseif role == "tool" then
    color, prefix = c.tool, "  "
  elseif role == "error" then
    color, prefix = c.error, "Error: "
  else
    color, prefix = c.foreground, ""
  end
  if role == "user" then
    -- The user just sent this: show it and what follows
    log.offset = 0
  end
  ui.print(prefix .. tostring(msg), color)
end

-- "short" (one line per call, completed in place), "full" or "off"
function ui.setToolDisplay(mode)
  if mode == "short" or mode == "full" or mode == "off" then
    state.toolDisplay = mode
  end
end

function ui.printToolCall(name, args)
  state.pendingTool = nil
  if state.toolDisplay == "off" then return end
  if state.toolDisplay == "short" then
    local call = cctext.forDisplay(toolview.call(name, args))
    local msg = addMessage("", ui.colors.toolName, { mark = toolview.mark(false), call = call })
    state.pendingTool = { msg = msg, name = name, args = args }
    return
  end
  ui.print(">> " .. tostring(name), ui.colors.toolName)
  if args then
    local argsStr = toDisplay(args)
    if longerThan(argsStr, 100) then
      argsStr = csub(argsStr, 1, 97) .. "..."
    end
    addMessage("   " .. argsStr, ui.colors.dim)
  end
end

function ui.printToolResult(name, result, args)
  local pending = state.pendingTool
  state.pendingTool = nil
  if state.toolDisplay == "off" then return end
  if state.toolDisplay == "short" then
    if pending and pending.name == name then
      args = args or pending.args
    else
      pending = nil
    end
    local outcome, failed = toolview.result(name, result, args)
    outcome = cctext.forDisplay(outcome)
    local mark = toolview.mark(failed)
    local color = failed and ui.colors.error or ui.colors.dim
    if not (pending and log:completeTool(pending.msg, mark, outcome, color)) then
      local call = cctext.forDisplay(toolview.call(name, args))
      addMessage("", color, { mark = mark, call = call, outcome = outcome })
    end
    changed()
    return
  end
  local resultStr = toDisplay(result)
  if longerThan(resultStr, 200) then
    resultStr = csub(resultStr, 1, 197) .. "..."
  end
  addMessage("<< " .. resultStr, ui.colors.dim)
end

-- Offer a command (from a skill) in the popup
function ui.addCommand(cmd, desc)
  for _, entry in ipairs(availableCommands) do
    if entry.cmd == cmd then return end
  end
  table.insert(availableCommands, { cmd = cmd, desc = desc or "" })
end

-- Streamed text (UTF-8 chunks) appended to the newest message
function ui.streamText(chunk)
  log:stream(tostring(chunk), ui.colors.assistant, cctext.forDisplay)
  changed()
end

function ui.endStream()
  log:endStream(cctext.forDisplay)
  changed()
end

function ui.clear()
  log:clear()
  state.pendingTool = nil
  changed()
end

---------------------------------------------------------------------------
-- Scrolling
---------------------------------------------------------------------------

function ui.scrollUp(n)
  log:scroll(n or 1, viewRows())
  changed()
end

function ui.scrollDown(n)
  log:scroll(-(n or 1), viewRows())
  changed()
end

function ui.scrollToTop()
  log.offset = log:maxOffset(viewRows())
  changed()
end

function ui.scrollToBottom()
  log.offset = 0
  changed()
end

-- The mouse wheel (dir -1 up, 1 down) at x, y: scrolls the log by 3,
-- except over the popup, whose List scrolls itself. Returns true when
-- handled here.
function ui.wheel(dir, x, y)
  if popupList and popupList.visible and type(x) == "number" and type(y) == "number"
    and popupList:contains(x, y) then
    return false
  end
  if dir == -1 then
    ui.scrollUp(3)
  elseif dir == 1 then
    ui.scrollDown(3)
  end
  return true
end

-- Events the SDK's wait passes on (turnCallbacks.onEvent): nothing to do,
-- the app's event loop already gave them to the UI
function ui.handleEvent()
end

-- Re-read the terminal size: place the elements again, and wrap the log
-- again when the width changed
function ui.checkSize()
  if not parent or not frame then return end
  local w, h = parent.getSize()
  if w == W and h == H then return end
  W, H = w, h
  log:rewrap(W - 2)
  log:clamp(viewRows())
  relayout()
  refreshPopup()
  changed()
end

---------------------------------------------------------------------------
-- Input (app.lua gives keyboard events here first)
---------------------------------------------------------------------------

local function resetInput()
  if input then
    input.text = ""
    input:setCursorPos(1)
  end
  state.historyIndex = 0
  state.savedInput = ""
end

-- Show a history entry (or the saved line for index 0). A recalled line
-- is sent as it is: the popup stays closed until the next edit or Tab.
local function showHistoryEntry()
  if state.historyIndex == 0 then
    setInputText(state.savedInput)
  else
    setInputText(state.history[#state.history - state.historyIndex + 1])
  end
  clearPopupState()
  refreshPopup()
end

-- Word jumps (Ctrl+Left/Right) over cells, as tui.lua
local function wordLeft(text, pos)
  while pos > 0 and csub(text, pos, pos):match("%s") do pos = pos - 1 end
  while pos > 0 and not csub(text, pos, pos):match("%s") do pos = pos - 1 end
  return pos
end

local function wordRight(text, pos)
  local len = width(text)
  while pos < len and not csub(text, pos + 1, pos + 1):match("%s") do pos = pos + 1 end
  while pos < len and csub(text, pos + 1, pos + 1):match("%s") do pos = pos + 1 end
  return pos
end

-- A "key" event. Returns false to give it to the Input (editing keys),
-- true when handled here, plus the line when Enter sends one.
local function handleKey(code)
  local text = input.text

  if code == keys.enter or code == keys.numPadEnter then
    local only = state.filtered[1]
    if popupVisible() and state.popupNavigated then
      -- An entry picked with Tab/Up/Down
      selectCommand()
    elseif state.showPopup and state.completionType == nil and
           #state.filtered == 1 and width(text) < width(only.cmd) then
      -- An unfinished command with one match ("/he"): complete it
      state.popupIndex = 1
      selectCommand()
    else
      -- Send the line exactly as typed
      if text ~= "" and state.history[#state.history] ~= text then
        table.insert(state.history, text)
      end
      resetInput()
      clearPopupState()
      refreshPopup()
      changed()
      return true, text
    end
    return true

  elseif code == keys.tab then
    if not (state.showPopup and #state.filtered > 0) then
      updateCommandPopup()
    end
    if state.showPopup and #state.filtered > 0 then
      -- The first Tab takes the highlighted entry; later Tabs cycle
      local cur = state.filtered[state.popupIndex]
      if cur and text ~= cur.cmd then
        setInputText(cur.cmd)
        state.popupNavigated = true
      else
        cyclePopup(1, true)
      end
    end
    refreshPopup()
    return true

  elseif code == keys.left or code == keys.right then
    if not isCtrlDown() then return false end
    local pos = input:getCursorPos() - 1
    pos = code == keys.left and wordLeft(text, pos) or wordRight(text, pos)
    input:setCursorPos(pos + 1)
    return true

  elseif code == keys.up then
    if popupVisible() and state.popupNavigated then
      cyclePopup(-1, false)
      refreshPopup()
    elseif isCtrlDown() then
      ui.scrollUp(1)
    elseif #state.history > 0 then
      if state.historyIndex == 0 then
        state.savedInput = text
      end
      if state.historyIndex < #state.history then
        state.historyIndex = state.historyIndex + 1
        showHistoryEntry()
      end
    end
    return true

  elseif code == keys.down then
    if popupVisible() and state.popupNavigated then
      cyclePopup(1, false)
      refreshPopup()
    elseif isCtrlDown() then
      ui.scrollDown(1)
    elseif state.historyIndex > 0 then
      state.historyIndex = state.historyIndex - 1
      showHistoryEntry()
    end
    return true

  elseif code == keys.home or code == keys["end"] then
    if not isCtrlDown() then return false end
    if code == keys.home then ui.scrollToTop() else ui.scrollToBottom() end
    return true

  elseif code == keys.pageUp then
    ui.scrollUp(5)
    return true

  elseif code == keys.pageDown then
    ui.scrollDown(5)
    return true
  end

  return false
end

-- A keyboard event (key, key_up, char, paste; ev is the packed event)
-- before Basalt sees it. Returns false to give it to Basalt (whose Input
-- edits the line), true when handled here, plus the line when Enter sent
-- one. A paste is made one line.
function ui.inputEvent(ev)
  if not input then return false end
  local name, p1 = ev[1], ev[2]
  if name == "key" then
    if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
      state.ctrlHeld[p1] = true
      return false
    end
    return handleKey(p1)
  elseif name == "key_up" then
    if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
      state.ctrlHeld[p1] = nil
    end
    return false
  elseif name == "paste" then
    local pasted = tostring(p1 or ""):gsub("\r?\n", " ")
    if pasted == "" then return true end
    ev[2] = pasted
  end
  return false
end

-- The input line as typed
function ui.inputText()
  return input and input.text or ""
end

-- Put a line in the input (empty: cleared, with the popup)
function ui.setInput(text)
  if not input then return end
  resetInput()
  if text ~= "" then setInputText(text) end
  clearPopupState()
  refreshPopup()
  changed()
end

-- Ctrl+T at the prompt: clear the line. Returns false when it was empty.
function ui.clearInput()
  if not input or input.text == "" then return false end
  ui.setInput("")
  return true
end

-- Prompts typed ahead (shown in the status bar)
function ui.setQueued(n)
  state.queued = n or 0
  changed()
end

-- While a `!` command runs, keys go to the program: the input line shows
-- no cursor. The held-Ctrl state starts over afterwards (key_up events
-- went to the program).
function ui.setProgramMode(on)
  if not input then return end
  if on then
    frame:setFocused(nil)
  else
    state.ctrlHeld = {}
    input:focus()
  end
  changed()
end

---------------------------------------------------------------------------
-- Theme and lifecycle
---------------------------------------------------------------------------

-- The terminal's own palette while a shell command runs (a multishell tab
-- copies the palette it sees); the UI keeps drawing in the nearest plain
-- colours meanwhile
function ui.suspendTheme()
  if basalt and frame and not mono then
    basalt.suspendPalette()
  end
end

-- The theme again; everything is drawn again (a program may have written
-- to the real screen)
function ui.resumeTheme()
  if not (basalt and frame) then return end
  if mono then
    basalt.repaint()
  else
    basalt.resumePalette()
  end
end

-- Give the screen back: palette restored, terminal cleared
function ui.cleanup()
  if basalt then
    basalt.cleanup()
  end
  state.ctrlHeld = {}
end

function ui.isRunning()
  return state.running
end

function ui.stop()
  state.running = false
end

-- For tests: the log rows, the popup state and the Basalt elements
function ui.inspect()
  return {
    log = log, state = state, frame = frame, input = input,
    popupList = popupList, popupBox = popupBox, size = { W, H }, mono = mono,
    paint = paint,
  }
end

return ui

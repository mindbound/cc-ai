-- cc-code/capture.lua
-- Run a CraftOS shell command and capture what it prints.
-- CraftOS has no output redirection (no "> file"), so the command runs with
-- the terminal redirected to a virtual terminal that records every write.

local capture = {}

-- Virtual terminal height. Large so programs that page their output
-- (textutils.pagedPrint, used by ls/help) never stop to wait for a key.
local VIRTUAL_HEIGHT = 999

-- Create a recording terminal object implementing the term redirect API
function capture.createTerminal(width, height, parent)
  parent = parent or term.current()
  local lines = {}     -- [y] = text currently on that row
  local scrolled = {}  -- rows that scrolled off the top, in order
  local cursorX, cursorY = 1, 1
  local textColour, backgroundColour = colours.white, colours.black
  local cursorBlink = false

  local t = {}

  local function put(str)
    str = tostring(str)
    local x = cursorX
    cursorX = cursorX + #str
    if cursorY < 1 or cursorY > height then return end
    -- Clip to the visible columns, like a real terminal
    if x < 1 then
      str = str:sub(2 - x)
      x = 1
    end
    if x > width then return end
    str = str:sub(1, width - x + 1)
    local line = lines[cursorY] or ""
    if #line < x - 1 then
      line = line .. string.rep(" ", x - 1 - #line)
    end
    lines[cursorY] = line:sub(1, x - 1) .. str .. line:sub(x + #str)
  end

  function t.write(str) put(str) end
  function t.blit(str, _fg, _bg) put(str) end

  function t.clear()
    -- Keep what was on screen: the caller wants the whole output history
    for y = 1, height do
      if lines[y] then
        table.insert(scrolled, lines[y])
      end
    end
    lines = {}
  end

  function t.clearLine()
    lines[cursorY] = nil
  end

  function t.scroll(n)
    n = math.floor(n)
    if n > 0 then
      for y = 1, n do
        table.insert(scrolled, lines[y] or "")
      end
      local newLines = {}
      for y = n + 1, height do
        newLines[y - n] = lines[y]
      end
      lines = newLines
    elseif n < 0 then
      local newLines = {}
      for y = 1, height + n do
        newLines[y - n] = lines[y]
      end
      lines = newLines
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

  -- Everything written so far, as text (trailing spaces/blank lines trimmed)
  function t.getText()
    local out = {}
    for _, line in ipairs(scrolled) do
      table.insert(out, line)
    end
    local lastRow = 0
    for y in pairs(lines) do
      if y > lastRow then lastRow = y end
    end
    for y = 1, lastRow do
      table.insert(out, lines[y] or "")
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

-- Run a shell command, returning success (boolean) and its captured output.
-- The command runs in the current shell, so `cd` persists, like typing it.
function capture.run(command, workdir)
  if not shell then
    return false, "The shell API is not available"
  end

  local oldDir
  if workdir then
    if not fs.isDir(workdir) then
      return false, "Working directory not found: " .. workdir
    end
    oldDir = shell.dir()
    shell.setDir(fs.combine(workdir, ""))
  end

  local parent = term.current()
  local width = math.max(parent.getSize(), 80)
  local recorder = capture.createTerminal(width, VIRTUAL_HEIGHT, parent)

  local previous = term.redirect(recorder)
  local ok, result = pcall(shell.run, command)
  term.redirect(previous)

  if oldDir then
    shell.setDir(oldDir)
  end

  local output = recorder.getText()
  if not ok then
    -- shell.run itself failed (e.g. "Terminated" raised outside the program)
    output = output .. (output ~= "" and "\n" or "") .. tostring(result)
    return false, output
  end
  return result == true, output
end

return capture

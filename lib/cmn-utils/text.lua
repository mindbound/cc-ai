-- cmn-utils/text.lua
-- Text handling for the CC terminal:
--   byteLen          byte length that stays right when a mod changes #
--   width, sub       screen width and cell-indexed substrings
--   forDisplay       model output (UTF-8) -> what the terminal can show
--   toCC, fromCC     UTF-8 <-> the vanilla CC charset
--
-- Vanilla CC: Tweaked draws one byte per cell: ASCII, CC drawing
-- characters at 128-159 and ISO-8859-1 at 160-255. UTF-8 is converted to
-- that charset for display.
--
-- The "CC: Tweaked Unicode Support" mod makes the terminal draw UTF-8 (one
-- cell per character, lone bytes 160-255 still as Latin-1) and adds a
-- global `unicode` table (len, sub, ...). It also makes # and string.len
-- count UTF-8 characters, while string.sub/byte/find stay byte-based, so
-- byte work must use byteLen, and display work width/sub.

local text = {}

-- Byte length. string.find still works on bytes under the unicode mod.
-- (rawlen would be O(1) and is unchanged by the mod, but the CraftOS-PC
-- emulator's rawlen returns 0 for strings made by sub or "..".)
local function rawlen(s)
  local _, last = s:find("$")
  return last
end

-- The mod's helpers when installed. Looked up on every call: it's cheap,
-- and it lets tests simulate the mod with a fake `unicode` table.
local function unicodeLib()
  local u = unicode
  if type(u) == "table" and type(u.len) == "function" and type(u.sub) == "function" then
    return u
  end
  return nil
end

-- True when the terminal draws UTF-8 (the unicode mod is installed)
function text.unicodeTerminal()
  return unicodeLib() ~= nil
end

-- Length in bytes, for byte positions (string.sub, byte, find)
function text.byteLen(s)
  return rawlen(s)
end

-- Width on screen in cells
function text.width(s)
  local u = unicodeLib()
  if u then
    return u.len(s)
  end
  return rawlen(s)
end

-- Substring by cells (same arguments as string.sub)
function text.sub(s, i, j)
  local u = unicodeLib()
  if u then
    return u.sub(s, i, j)
  end
  return string.sub(s, i, j)
end

-- Decode one UTF-8 sequence at byte i (same rules as the unicode mod and
-- Lua 5.3: no overlong forms, surrogates or values above U+10FFFF).
-- Returns codepoint and byte length, or nil if the bytes there are not a
-- complete, well-formed sequence.
local function decodeAt(str, i, n)
  local b = str:byte(i)
  local len, cp
  if b >= 0xC2 and b <= 0xDF then
    len, cp = 2, b - 0xC0
  elseif b >= 0xE0 and b <= 0xEF then
    len, cp = 3, b - 0xE0
  elseif b >= 0xF0 and b <= 0xF4 then
    len, cp = 4, b - 0xF0
  else
    return nil
  end
  if i + len - 1 > n then return nil end
  local second = str:byte(i + 1)
  if (b == 0xE0 and second < 0xA0) or (b == 0xED and second > 0x9F)
    or (b == 0xF0 and second < 0x90) or (b == 0xF4 and second > 0x8F) then
    return nil
  end
  for j = i + 1, i + len - 1 do
    local c = str:byte(j)
    if c < 0x80 or c > 0xBF then return nil end
    cp = cp * 64 + (c - 0x80)
  end
  return cp, len
end

-- Characters outside ISO-8859-1 that models commonly emit, mapped to ASCII
local replacements = {
  [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-",
  [0x2014] = "-", [0x2015] = "-", [0x2212] = "-",
  [0x2018] = "'", [0x2019] = "'", [0x201A] = ",", [0x201B] = "'",
  [0x201C] = "\"", [0x201D] = "\"", [0x201E] = "\"", [0x201F] = "\"",
  [0x2032] = "'", [0x2033] = "\"",
  [0x2026] = "...", [0x2022] = "*", [0x2023] = ">", [0x2043] = "-",
  [0x25CF] = "*", [0x25CB] = "o", [0x25A0] = "#", [0x25A1] = "[]",
  [0x2190] = "<-", [0x2192] = "->", [0x2191] = "^", [0x2193] = "v",
  [0x2194] = "<->", [0x21D2] = "=>", [0x21D0] = "<=",
  [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "!=", [0x2248] = "~=",
  [0x2713] = "v", [0x2714] = "v", [0x2705] = "[v]",
  [0x2717] = "x", [0x2718] = "x", [0x274C] = "[x]",
  [0x26A0] = "!", [0x2139] = "i",
  [0x00A0] = " ", [0x2002] = " ", [0x2003] = " ", [0x2009] = " ",
  [0x200A] = " ", [0x202F] = " ", [0x2007] = " ", [0x2008] = " ",
  [0x200B] = "", [0x200C] = "", [0x200D] = "", [0x2060] = "", [0xFEFF] = "",
  [0xFE0F] = "",
}

local function mapCodepoint(cp)
  local rep = replacements[cp]
  if rep then return rep end
  if cp >= 0xA1 and cp <= 0xFF then
    return string.char(cp) -- CC renders ISO-8859-1 here
  end
  if cp >= 0x2500 and cp <= 0x257F then
    -- Box drawing: keep the general shape readable
    if cp == 0x2500 or cp == 0x2501 or cp == 0x2550 then return "-" end
    if cp == 0x2502 or cp == 0x2503 or cp == 0x2551 then return "|" end
    return "+"
  end
  return "?"
end

-- Walk a string: ASCII runs are copied in one piece, every other position
-- is handed to onByte(i, n, out), which appends to out and returns the
-- number of bytes it consumed
local function walk(str, onByte)
  local out = {}
  local i, n = 1, rawlen(str)
  while i <= n do
    local nextHigh = str:find("[\128-\255\t\r]", i)
    if not nextHigh then
      out[#out + 1] = str:sub(i)
      break
    end
    if nextHigh > i then
      out[#out + 1] = str:sub(i, nextHigh - 1)
    end
    i = nextHigh + onByte(nextHigh, n, out)
  end
  return table.concat(out)
end

-- Convert UTF-8 text to the vanilla CC charset. Bytes that are not part of
-- a valid UTF-8 sequence are kept as-is (they are most likely already CC
-- charset). Tabs become two spaces, CR is dropped.
function text.toCC(str)
  str = tostring(str)
  if not str:find("[\128-\255\t\r]") then
    return str
  end
  return walk(str, function(i, n, out)
    local b = str:byte(i)
    if b == 9 then
      out[#out + 1] = "  "
      return 1
    elseif b == 13 then
      return 1
    end
    local cp, len = decodeAt(str, i, n)
    if cp then
      out[#out + 1] = mapCodepoint(cp)
      return len
    end
    out[#out + 1] = string.char(b)
    return 1
  end)
end

-- Prepare model output (UTF-8) for the terminal: kept as UTF-8 when the
-- terminal can draw it (unicode mod), converted to the CC charset otherwise
function text.forDisplay(str)
  str = tostring(str)
  if text.unicodeTerminal() then
    return (str:gsub("\t", "  "):gsub("\r", ""))
  end
  return text.toCC(str)
end

-- Convert text from the computer (typed, pasted, files, program output) to
-- UTF-8 so it can be sent in JSON. Valid UTF-8 sequences are kept; other
-- bytes are CC charset: 160-255 are ISO-8859-1, 128-159 (CC drawing
-- characters) have no equivalent and become "?". With the unicode mod,
-- typed text mixes both (é arrives as one byte, an em dash as UTF-8).
function text.fromCC(str)
  str = tostring(str)
  if not str:find("[\128-\255]") then
    return str
  end
  return walk(str, function(i, n, out)
    local b = str:byte(i)
    if b < 0x80 then
      out[#out + 1] = string.char(b) -- tab or CR: keep
      return 1
    end
    local cp, len = decodeAt(str, i, n)
    if cp then
      out[#out + 1] = str:sub(i, i + len - 1)
      return len
    end
    if b >= 0xA0 then
      -- ISO-8859-1 codepoint -> 2-byte UTF-8
      out[#out + 1] = string.char(0xC0 + math.floor(b / 64), 0x80 + (b % 64))
    else
      out[#out + 1] = "?"
    end
    return 1
  end)
end

return text

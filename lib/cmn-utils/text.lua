-- cmn-utils/text.lua
-- Conversion between UTF-8 (what AI APIs send and expect) and the
-- ComputerCraft terminal charset (one byte per glyph: ASCII, CC drawing
-- characters at 128-159, ISO-8859-1 at 160-255).

local text = {}

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

-- Convert UTF-8 text to something the CC terminal can display.
-- Bytes that are not part of a valid UTF-8 sequence are kept as-is (they are
-- most likely already CC charset). Tabs become two spaces, CR is dropped.
function text.toCC(str)
  str = tostring(str)
  if not str:find("[\128-\255\t\r]") then
    return str
  end
  local out = {}
  local i, n = 1, #str
  while i <= n do
    local b = str:byte(i)
    if b < 0x80 then
      if b == 9 then
        out[#out + 1] = "  "
      elseif b ~= 13 then
        out[#out + 1] = string.char(b)
      end
      i = i + 1
    else
      local len, cp = 0, nil
      if b >= 0xC2 and b <= 0xDF then
        len, cp = 2, b - 0xC0
      elseif b >= 0xE0 and b <= 0xEF then
        len, cp = 3, b - 0xE0
      elseif b >= 0xF0 and b <= 0xF4 then
        len, cp = 4, b - 0xF0
      end
      local valid = len > 0 and i + len - 1 <= n
      if valid then
        for j = i + 1, i + len - 1 do
          local c = str:byte(j)
          if c < 0x80 or c > 0xBF then
            valid = false
            break
          end
          cp = cp * 64 + (c - 0x80)
        end
      end
      if valid then
        out[#out + 1] = mapCodepoint(cp)
        i = i + len
      else
        out[#out + 1] = string.char(b)
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

-- Convert CC charset text (typed or pasted on the computer) to UTF-8 so it
-- can be sent in JSON. Valid UTF-8 input is returned unchanged.
function text.fromCC(str)
  str = tostring(str)
  if not str:find("[\128-\255]") then
    return str
  end
  if utf8 and utf8.len and utf8.len(str) then
    return str -- already valid UTF-8
  end
  return (str:gsub("[\128-\255]", function(c)
    local b = c:byte()
    if b >= 0xA0 then
      -- ISO-8859-1 codepoint -> 2-byte UTF-8
      return string.char(0xC0 + math.floor(b / 64), 0x80 + (b % 64))
    end
    return "?" -- CC drawing characters have no UTF-8 equivalent
  end))
end

return text

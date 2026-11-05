-- cc-code/secrets.lua
-- Secret setting values (API keys, tokens, passwords) and their removal
-- from text the model is sent. A tool result could otherwise carry them:
-- the `set` program lists every setting with its value, read_file can open
-- /.settings, and programs print what they like.
--
-- A value is found whole, split over lines (printed output wraps at the
-- edge of the screen, which can also turn a space into a line break), in
-- the escaped forms `set`, /.settings and JSON write, and as a long enough
-- start at the end of a line or end at the start of one (a value clipped
-- at the edge of the screen, or cut where long output was shortened).

local text = require("cmn-utils.text")
local json = require("cmn-utils.json")

local byteLen = text.byteLen

local secrets = {}

-- What a secret is replaced with
secrets.REDACTED = "<redacted>"

-- Setting names (upper-cased) that hold secrets
secrets.NAME_PATTERNS = { "KEY$", "TOKEN", "SECRET", "PASSWORD", "PASSWD" }

-- Shorter values are too likely to occur in ordinary text
secrets.MIN_BYTES = 8

-- A part of a value cut at a line edge is blanked when it is at least this
-- long (and the value at least MIN_PART + 4 bytes)
local MIN_PART = 12

-- Is this the name of a setting that holds a secret?
function secrets.isSecretName(name)
  local upper = tostring(name):upper()
  for _, pattern in ipairs(secrets.NAME_PATTERNS) do
    if upper:find(pattern) then
      return true
    end
  end
  return false
end

-- The secret values to blank out, in every form they are written in,
-- longest first (so a value that contains another is blanked whole)
function secrets.values()
  local list, seen = {}, {}
  local function add(value)
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      list[#list + 1] = value
    end
  end
  local names = settings and settings.getNames and settings.getNames() or {}
  for _, name in ipairs(names) do
    if secrets.isSecretName(name) then
      local value = settings.get(name)
      -- `set name 12345678` stores a number
      if type(value) == "number" then
        value = tostring(value)
      end
      if type(value) == "string" and byteLen(value) >= secrets.MIN_BYTES then
        add(value)
        -- Tool results are converted to UTF-8 before they are checked
        add(text.fromCC(value))
        -- As `set` and /.settings write it (textutils.serialize: %q) ...
        local quoted = ("%q"):format(value):sub(2, -2):gsub("\\\n", "\\n")
        add(quoted)
        add(text.fromCC(quoted))
        -- ... and as JSON writes it
        local ok, encoded = pcall(json.encode, value)
        if ok and type(encoded) == "string" then
          add(encoded:sub(2, -2))
        end
      end
    end
  end
  table.sort(list, function(a, b) return byteLen(a) > byteLen(b) end)
  return list
end

-- Replace every occurrence of needle in str (plain text, no patterns)
local function replacePlain(str, needle, replacement)
  local start = str:find(needle, 1, true)
  if not start then
    return str
  end
  local out, pos, len = {}, 1, byteLen(needle)
  while start do
    out[#out + 1] = str:sub(pos, start - 1)
    out[#out + 1] = replacement
    pos = start + len
    start = str:find(needle, pos, true)
  end
  out[#out + 1] = str:sub(pos)
  return table.concat(out)
end

-- A Lua pattern for the value with line breaks allowed between any two
-- bytes, and a line break in place of a space (wrapping drops the space
-- at the end of a row)
local function wrappedPattern(secret)
  local parts = {}
  for i = 1, byteLen(secret) do
    local c = secret:sub(i, i)
    if c == " " then
      parts[#parts + 1] = "[ \n]"
    elseif c:find("^%w$") then
      parts[#parts + 1] = c
    else
      parts[#parts + 1] = "%" .. c
    end
  end
  return table.concat(parts, "\n?")
end

-- Blank a long enough start of the value at the end of a line, and a long
-- enough end of it at the start of a line
local function blankEdgeParts(str, secret)
  local len = byteLen(secret)
  if len < MIN_PART + 4 then
    return str
  end
  -- Ranges to blank, as { from, to } byte positions, in order
  local ranges = {}

  -- A start of the value that runs to the end of a line
  local head = secret:sub(1, MIN_PART)
  local pos = 1
  while true do
    local s = str:find(head, pos, true)
    if not s then break end
    local k = MIN_PART
    while k < len and str:byte(s + k) == secret:byte(k + 1) do
      k = k + 1
    end
    local after = str:byte(s + k)
    if k < len and (after == nil or after == 10) then
      ranges[#ranges + 1] = { s, s + k - 1 }
    end
    pos = s + 1
  end

  -- An end of the value that starts a line
  local tail = secret:sub(-MIN_PART)
  pos = 1
  while true do
    local s = str:find(tail, pos, true)
    if not s then break end
    local e = s + MIN_PART - 1
    local k = MIN_PART
    while k < len and s - (k - MIN_PART) - 1 >= 1
      and str:byte(s - (k - MIN_PART) - 1) == secret:byte(len - k) do
      k = k + 1
    end
    local from = e - k + 1
    local before = from > 1 and str:byte(from - 1) or nil
    if k < len and (before == nil or before == 10) then
      ranges[#ranges + 1] = { from, e }
    end
    pos = s + 1
  end

  if #ranges == 0 then
    return str
  end
  table.sort(ranges, function(a, b) return a[1] < b[1] end)
  local out, last = {}, 1
  for _, r in ipairs(ranges) do
    if r[1] >= last then
      out[#out + 1] = str:sub(last, r[1] - 1)
      out[#out + 1] = secrets.REDACTED
      last = r[2] + 1
    end
  end
  out[#out + 1] = str:sub(last)
  return table.concat(out)
end

-- Blank out secrets in a string (list: from secrets.values). Line breaks
-- inside a blanked value are kept after the marker, so rows stay rows.
function secrets.redact(str, list)
  if type(str) ~= "string" then
    return str
  end
  for _, secret in ipairs(list) do
    str = replacePlain(str, secret, secrets.REDACTED)
    -- (a pattern can't hold a NUL byte; such a value is only found whole)
    if str:find("\n", 1, true) and not secret:find("\0", 1, true) then
      str = str:gsub(wrappedPattern(secret), function(match)
        local _, breaks = match:gsub("\n", "")
        return secrets.REDACTED .. string.rep("\n", breaks)
      end)
    end
    str = blankEdgeParts(str, secret)
  end
  return str
end

-- Blank out secrets in every string of a value, table keys too (a copy is
-- returned)
function secrets.redactDeep(value, list)
  if #list == 0 then
    return value
  end
  if type(value) == "string" then
    return secrets.redact(value, list)
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[secrets.redact(k, list)] = secrets.redactDeep(v, list)
    end
    return out
  end
  return value
end

return secrets

-- tests/harness.lua
-- Tiny test framework plus a fake `http` API for offline tests

local json = require("cmn-utils.json")

local T = { passed = 0, failed = 0, failures = {}, log = {} }

function T.print(msg)
  table.insert(T.log, msg)
end

function T.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
    T.print("  ok   " .. name)
  else
    T.failed = T.failed + 1
    table.insert(T.failures, name .. ": " .. tostring(err))
    T.print("  FAIL " .. name .. ": " .. tostring(err))
  end
end

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" then return json.encode(v) end
  return tostring(v)
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function T.ok(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
end

function T.contains(str, sub, msg)
  if type(str) ~= "string" or not str:find(sub, 1, true) then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(str) .. " to contain " .. show(sub), 2)
  end
end

function T.raises(fn, sub)
  local ok, err = pcall(fn)
  if ok then error("expected an error", 2) end
  if sub then T.contains(tostring(err), sub, "error message") end
  return err
end

-- Fake HTTP --------------------------------------------------------------

local mock = { queue = {}, requests = {} }
T.http = mock

local function makeHandle(code, body)
  local pos = 1
  local h = {}
  function h.getResponseCode() return code end
  function h.readAll()
    local rest = body:sub(pos)
    pos = #body + 1
    return rest
  end
  function h.readLine(withTrailing)
    if pos > #body then return nil end
    local nl = body:find("\n", pos, true)
    local line
    if nl then
      line = withTrailing and body:sub(pos, nl) or body:sub(pos, nl - 1)
      pos = nl + 1
    else
      line = body:sub(pos)
      pos = #body + 1
    end
    return line
  end
  function h.close() end
  return h
end

-- Queue a response: { code = 200, body = "..." } or { fail = "Timed out" }.
-- A table body is JSON-encoded.
function mock.push(resp)
  if type(resp.body) == "table" then
    resp.body = json.encode(resp.body)
  end
  table.insert(mock.queue, resp)
end

function mock.reset()
  mock.queue = {}
  mock.requests = {}
  mock.routes = {}
end

-- The last request, with its JSON body decoded
function mock.last()
  return mock.requests[#mock.requests]
end

function mock.post(req, body, headers)
  if type(req) ~= "table" then
    req = { url = req, body = body, headers = headers }
  end
  -- Real CC: Tweaked raises for timeouts outside 0-60 seconds
  if req.timeout ~= nil and (type(req.timeout) ~= "number" or req.timeout < 0 or req.timeout > 60) then
    error("timeout out of range (" .. tostring(req.timeout) .. ")", 2)
  end
  local decoded
  pcall(function() decoded = json.decode(req.body) end)
  table.insert(mock.requests, { url = req.url, headers = req.headers, body = req.body, json = decoded, timeout = req.timeout, binary = req.binary })
  local resp = table.remove(mock.queue, 1)
  if not resp then
    error("mock http: unexpected request to " .. tostring(req.url))
  end
  if resp.fail then
    return nil, resp.fail
  end
  local handle = makeHandle(resp.code or 200, resp.body or "")
  if (resp.code or 200) >= 400 then
    return nil, resp.reason or "HTTP error", handle
  end
  return handle
end

-- http.get: answered from mock.routes[url] (a string body), else 404
mock.routes = {}
function mock.get(req, headers, binary)
  local url = type(req) == "table" and req.url or req
  table.insert(mock.requests, { url = url, method = "GET", binary = binary })
  local body = mock.routes[url]
  if body == nil then
    return nil, "Not Found", makeHandle(404, "")
  end
  return makeHandle(200, body)
end

-- Build an SSE body from a list of JSON-able events
function mock.sse(events, done)
  local lines = {}
  for _, e in ipairs(events) do
    table.insert(lines, "data: " .. json.encode(e) .. "\r\n\r\n")
  end
  if done then
    table.insert(lines, "data: [DONE]\r\n\r\n")
  end
  return table.concat(lines)
end

-- Simulated "CC: Tweaked Unicode Support" mod ---------------------------------
-- The mod adds a global `unicode` table whose len/sub count characters: a
-- well-formed UTF-8 sequence is one character, any other byte is one
-- character on its own. (It also changes # in the Lua VM, which can't be
-- simulated here; cc-ai code must not use # on strings for byte work.)

local function seqLen(s, i, n)
  local b = s:byte(i)
  local len
  if b >= 0xC2 and b <= 0xDF then len = 2
  elseif b >= 0xE0 and b <= 0xEF then len = 3
  elseif b >= 0xF0 and b <= 0xF4 then len = 4
  else return 1 end
  if i + len - 1 > n then return 1 end
  local second = s:byte(i + 1)
  if (b == 0xE0 and second < 0xA0) or (b == 0xED and second > 0x9F)
    or (b == 0xF0 and second < 0x90) or (b == 0xF4 and second > 0x8F) then
    return 1
  end
  for j = i + 1, i + len - 1 do
    local c = s:byte(j)
    if c < 0x80 or c > 0xBF then return 1 end
  end
  return len
end

-- Byte offsets where each character starts
local function charStarts(s)
  local starts, i, n = {}, 1, select(2, s:find("$"))
  while i <= n do
    starts[#starts + 1] = i
    i = i + seqLen(s, i, n)
  end
  return starts, n
end

local fakeUnicode = {
  len = function(s)
    return #(charStarts(s))
  end,
  sub = function(s, i, j)
    local starts, n = charStarts(s)
    local count = #starts
    i = i or 1
    j = j or -1
    if i < 0 then i = math.max(count + i + 1, 1) elseif i == 0 then i = 1 end
    if j < 0 then j = count + j + 1 elseif j > count then j = count end
    if i > j then return "" end
    local last = (starts[j + 1] or (n + 1)) - 1
    return s:sub(starts[i], last)
  end,
}

-- Run fn with the simulated mod installed (a global `unicode` table)
function T.withUnicodeMod(fn)
  unicode = fakeUnicode
  local ok, err = pcall(fn)
  unicode = nil
  if not ok then error(err, 0) end
end

-- Filesystem scratch area --------------------------------------------------

T.tmp = "/cc-ai-test-tmp"

function T.resetTmp()
  if fs.exists(T.tmp) then fs.delete(T.tmp) end
  fs.makeDir(T.tmp)
end

function T.writeFile(path, content)
  local h = fs.open(path, "wb")
  h.write(content)
  h.close()
end

function T.readFile(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local c = h.readAll()
  h.close()
  return c
end

return T

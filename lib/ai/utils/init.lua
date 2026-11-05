local utils = {}

-- HTTP idle timeout in seconds: the request fails if the server sends
-- nothing for this long. CC: Tweaked accepts 0-60 (and raises an error for
-- anything else); 0 means no timeout. Override per call with opts.timeout
-- or globally with: set ai.http_timeout <seconds>
local DEFAULT_TIMEOUT = 60
local MAX_TIMEOUT = 60

local function clampTimeout(value)
  value = tonumber(value)
  if not value then return nil end
  return math.max(0, math.min(MAX_TIMEOUT, value))
end

local function getTimeout(override)
  local value = clampTimeout(override)
  if value then return value end
  value = clampTimeout(settings and settings.get("ai.http_timeout"))
  if value then return value end
  return DEFAULT_TIMEOUT
end

-- Read a configuration value (API keys etc.).
-- CC: Tweaked has no environment variables, so values live in the settings
-- API (persisted in /.settings): set GOOGLE_GENERATIVE_AI_API_KEY <key>
function utils.getEnv(name)
  if settings then
    local value = settings.get(name)
    if value ~= nil and value ~= "" then
      return tostring(value)
    end
  end
  if os.getenv then
    local value = os.getenv(name)
    if value ~= nil and value ~= "" then
      return value
    end
  end
  return nil
end

-- Register a setting so the `set` program can show its description
function utils.defineSetting(name, description)
  if settings and settings.define then
    pcall(settings.define, name, { description = description, type = "string" })
  end
end

-- How often (seconds) a waiting request calls its onWait hook
local WAIT_TICK = 0.5

-- Requests are sent with a unique "#cc-ai-<session>-<n>" fragment. The
-- fragment is not sent to the server, but CC: Tweaked's http_success /
-- http_failure events carry the URL exactly as given, so a reply can be
-- matched to its own request even when several go to the same endpoint.
-- Every program loads its own copy of this module (each cc-code run, each
-- multishell tab), so the session part keeps their tags apart too.
-- (%.0f: the epoch in ms is too big for %d/%x in some Lua 5.2 builds)
local session = ("%.0f%07d"):format(os.epoch("utc"), math.random(0, 9999999))
local requestCount = 0

-- Tagged URLs of requests that were given up on (Ctrl+T or an error while
-- waiting). Their replies may still arrive later and are closed unread.
local abandoned = {}

local function hostOf(url)
  return url:match("^%w+://([^/]+)") or url
end

-- Close a reply that belongs to a request this program abandoned. Returns
-- true when the event was such a reply. (Replies to other programs'
-- requests are left alone.) Event loops that may see these replies call it
-- with every event they pull (cc-code's prompt does).
function utils.discardStale(event, url, handle, errHandle)
  if (event == "http_success" or event == "http_failure") and abandoned[url] then
    abandoned[url] = nil
    local h = event == "http_success" and handle or errHandle
    if type(h) == "table" and type(h.close) == "function" then
      pcall(h.close)
    end
    return true
  end
  return false
end

-- POST and return the response handle plus the status code.
-- Non-2xx responses still return their handle (the body usually holds the
-- API's JSON error); only transport failures raise.
--
-- The request is asynchronous (http.request) and this function runs its
-- own event loop until the reply arrives, so the caller can see the wait:
--   hooks.onWait(seconds)    called every WAIT_TICK seconds while waiting
--   hooks.onEvent(event, ...) called with every event that is not part of
--                             the request (keys, scrolling, resizes, ...)
-- The hooks must not yield (no sleep, os.pullEvent, read, rednet.receive,
-- http.get, turtle moves, ...): a nested event pull could take the reply's
-- event. A hook that yields raises an error instead.
-- Ctrl+T raises "Terminated", like a blocking http.post.
local function post(url, headers, body, timeout, hooks)
  if not http then
    error("HTTP API is disabled. Enable http in the ComputerCraft config.", 0)
  end
  hooks = hooks or {}

  requestCount = requestCount + 1
  local tagged = url
  if not url:find("#", 1, true) then
    tagged = url .. "#cc-ai-" .. session .. "-" .. requestCount
  end

  local request = {
    url = tagged,
    method = "POST",
    body = body,
    headers = headers,
    timeout = getTimeout(timeout),
    -- Binary mode: the reply exactly as sent. (With the "CC: Tweaked
    -- Unicode Support" mod, text-mode reads re-encode bytes that aren't
    -- valid UTF-8.)
    binary = true,
  }
  local ok, err = http.request(request)
  if not ok and tagged ~= url then
    -- The tag was refused: send it untagged (then a late reply to a
    -- cancelled request can't be told apart from this one)
    tagged = url
    request.url = url
    ok, err = http.request(request)
  end
  if not ok then
    error("HTTP request to " .. hostOf(url) .. " failed: " .. tostring(err), 0)
  end

  local started = os.epoch("utc")
  local timer = hooks.onWait and os.startTimer(WAIT_TICK)

  -- Give up on the request: its reply will be closed when it arrives
  local function abandon(reason)
    abandoned[tagged] = true
    if timer then os.cancelTimer(timer) end
    error(reason, 0)
  end

  -- Call a hook; an error in it abandons the request. It runs as a
  -- coroutine so that a hook that yields is caught (see above).
  local function call(fn, ...)
    local co = coroutine.create(fn)
    local hookOk, hookErr = coroutine.resume(co, ...)
    if not hookOk then
      abandon(hookErr)
    elseif coroutine.status(co) ~= "dead" then
      abandon("ai: an onWait/onEvent hook yielded (it must not sleep or pull events)")
    end
  end

  while true do
    local event, p1, p2, p3 = os.pullEventRaw()
    if (event == "http_success" or event == "http_failure") and p1 == tagged then
      if timer then os.cancelTimer(timer) end
      if event == "http_success" then
        return p2, p2.getResponseCode()
      end
      if type(p3) == "table" then
        return p3, p3.getResponseCode(), p2
      end
      error("HTTP request to " .. hostOf(url) .. " failed: " .. tostring(p2), 0)
    elseif event == "terminate" then
      abandon("Terminated")
    elseif utils.discardStale(event, p1, p2, p3) then
      -- A late reply to an earlier, abandoned request
    elseif event == "timer" and p1 == timer then
      timer = os.startTimer(WAIT_TICK)
      call(hooks.onWait, (os.epoch("utc") - started) / 1000)
    elseif hooks.onEvent then
      call(hooks.onEvent, event, p1, p2, p3)
    end
  end
end

-- Turn an error response body into a readable message
local function describeError(code, reason, bodyText)
  local json = require("cmn-utils.json")
  local ok, data = pcall(json.decode, bodyText or "")
  if ok and type(data) == "table" and data.error then
    local e = data.error
    if type(e) == "table" then
      return e.message or json.encode(e)
    end
    return tostring(e)
  end
  local msg = "HTTP " .. tostring(code) .. " " .. tostring(reason or "")
  if bodyText and bodyText ~= "" then
    msg = msg .. ": " .. bodyText:sub(1, 300)
  end
  return msg
end

-- Wait hooks from a generateText/streamText options table (see post())
function utils.waitHooks(opts)
  if type(opts) ~= "table" then return nil end
  return { onWait = opts.onWait, onEvent = opts.onEvent }
end

-- POST and return the full response body as a string
-- timeout: optional idle timeout in seconds (0 = none), see DEFAULT_TIMEOUT
-- hooks: optional { onWait, onEvent }, see post()
function utils.httpPost(url, headers, body, timeout, hooks)
  local handle, code, reason = post(url, headers, body, timeout, hooks)
  local text = handle.readAll() or ""
  handle.close()
  if code >= 400 then
    error(describeError(code, reason, text), 0)
  end
  return text
end

-- POST and return an iterator over the response body, one line at a time
-- (each line keeps its trailing "\n").
-- Note: CC: Tweaked downloads the whole response before the reply event
-- arrives, so chunks are delivered all at once when the response completes.
function utils.httpPostStream(url, headers, body, timeout, hooks)
  local handle, code, reason = post(url, headers, body, timeout, hooks)
  if code >= 400 then
    local text = handle.readAll() or ""
    handle.close()
    error(describeError(code, reason, text), 0)
  end
  return function()
    if not handle then return nil end
    local line = handle.readLine(true)
    if line == nil then
      handle.close()
      handle = nil
    end
    return line
  end
end

-- Decode a JSON response body. On failure, raise a short error (the whole
-- body would flood the screen) that says how big it was and how it ends:
-- a reply cut short is the usual cause.
function utils.decodeJSON(text)
  local json = require("cmn-utils.json")
  local ok, data = pcall(json.decode, text)
  if ok then
    return data
  end
  local tail = text:sub(-60):gsub("%s+", " ")
  error(("Could not parse the API response (%d bytes; it may have been cut short). It ends with: %s")
    :format(select(2, text:find("$")), tail), 0)
end

function utils.parseSSELine(line)
  line = line:gsub("\r$", "")
  if line:sub(1, 6) == "data: " then
    local data = line:sub(7)
    if data == "[DONE]" then
      return "done", nil
    end
    local json = require("cmn-utils.json")
    local ok, parsed = pcall(json.decode, data)
    if ok then
      return "data", parsed
    end
  end
  return nil, nil
end

return utils

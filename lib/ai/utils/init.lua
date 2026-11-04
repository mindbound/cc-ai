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

-- POST and return the response handle plus the status code.
-- Non-2xx responses still return their handle (the body usually holds the
-- API's JSON error); only transport failures raise.
local function post(url, headers, body, timeout)
  if not http then
    error("HTTP API is disabled. Enable http in the ComputerCraft config.", 0)
  end
  local response, err, errResponse = http.post({
    url = url,
    body = body,
    headers = headers,
    timeout = getTimeout(timeout),
  })
  if response then
    return response, response.getResponseCode()
  end
  if errResponse then
    return errResponse, errResponse.getResponseCode(), err
  end
  local host = url:match("^%w+://([^/]+)") or url
  error("HTTP request to " .. host .. " failed: " .. tostring(err), 0)
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

-- POST and return the full response body as a string
-- timeout: optional idle timeout in seconds (0 = none), see DEFAULT_TIMEOUT
function utils.httpPost(url, headers, body, timeout)
  local handle, code, reason = post(url, headers, body, timeout)
  local text = handle.readAll() or ""
  handle.close()
  if code >= 400 then
    error(describeError(code, reason, text), 0)
  end
  return text
end

-- POST and return an iterator over the response body, one line at a time
-- (each line keeps its trailing "\n").
-- Note: CC: Tweaked downloads the whole response before http.post returns,
-- so chunks are delivered all at once when the response completes.
function utils.httpPostStream(url, headers, body, timeout)
  local handle, code, reason = post(url, headers, body, timeout)
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
    :format(#text, tail), 0)
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

local json = require("cmn-utils.json")
local utils = require("ai.utils")

local function isGpt5Model(modelId)
  return modelId and modelId:match("^gpt%-5") ~= nil
end

local function buildMessages(opts)
  local messages = {}
  if opts.system then
    table.insert(messages, { role = "system", content = opts.system })
  end
  if opts.messages then
    for _, msg in ipairs(opts.messages) do
      table.insert(messages, msg)
    end
  elseif opts.prompt then
    table.insert(messages, { role = "user", content = opts.prompt })
  end
  return messages
end

-- Whether a decoded reply (or stream event) is an error object
local function hasError(data)
  if type(data) ~= "table" then return false end
  local e = data.error
  return e ~= nil and e ~= false and e ~= ""
end

-- A tool without arguments (no parameters, or no properties) is sent
-- without "parameters": see utils.toolParameters
local function buildTools(tools)
  if not tools then return nil end
  local result = {}
  for _, tool in ipairs(tools) do
    if type(tool) == "table" and tool.type == "function" and type(tool["function"]) == "table" then
      local fn = tool["function"]
      table.insert(result, {
        type = "function",
        ["function"] = {
          name = fn.name,
          description = fn.description,
          parameters = utils.toolParameters(fn.parameters),
        },
      })
    end
  end
  return #result > 0 and result or nil
end

local function parseResponse(response)
  local choice = type(response) == "table" and type(response.choices) == "table" and response.choices[1]
  if type(choice) ~= "table" then
    error("No choices in the reply.", 0)
  end

  local message = choice.message
  if type(message) ~= "table" then
    error("The reply's first choice has no message.", 0)
  end
  local usage = {}
  if type(response.usage) == "table" then
    usage.inputTokens = response.usage.prompt_tokens
    usage.outputTokens = response.usage.completion_tokens
    usage.totalTokens = response.usage.total_tokens
  end

  return {
    text = utils.contentText(message.content),
    finishReason = choice.finish_reason,
    toolCalls = message.tool_calls,
    usage = usage,
    rawMessage = message,
  }
end

-- Full chat completions URL. The base URL may be given with or without a
-- trailing slash or "/chat/completions" (as some providers document it).
local function chatURL(config)
  local base = config.getBaseURL()
  if type(base) ~= "string" or base == "" then
    error(config.baseURLError or "No base URL configured for this provider.", 0)
  end
  base = base:gsub("/+$", "")
  base = base:gsub("/chat/completions$", "")
  return base .. "/chat/completions"
end

local function checkApiKey(config)
  if config.apiKeyOptional then return end
  local apiKey = config.getApiKey()
  if not apiKey or apiKey == "" then
    error("API key is required. " .. config.apiKeyError, 0)
  end
end

local function createLanguageModel(modelId, config)
  local model = {
    modelId = modelId,
    provider = config.provider,
  }

  function model.doGenerate(opts)
    -- Optionally go through the streaming endpoint: data keeps arriving
    -- while the model works, so a slow (thinking) model doesn't hit the
    -- HTTP idle timeout. CC: Tweaked buffers the stream, so the result is
    -- the same as a plain request.
    if config.streamResponses then
      local parsed = model.doStream(opts, nil, true)
      return parsed, { streamed = true, model = modelId }
    end

    checkApiKey(config)

    local url = chatURL(config)
    local headers = config.getHeaders()
    local messages = buildMessages(opts)

    local requestBody = {
      model = modelId,
      messages = messages,
    }

    if opts.maxOutputTokens then
      if isGpt5Model(modelId) then
        requestBody.max_completion_tokens = opts.maxOutputTokens
      else
        requestBody.max_tokens = opts.maxOutputTokens
      end
    end
    -- GPT-5 (reasoning model) doesn't support temperature/topP
    if not isGpt5Model(modelId) then
      if opts.temperature then
        requestBody.temperature = opts.temperature
      end
      if opts.topP then
        requestBody.top_p = opts.topP
      end
    end
    if opts.tools then
      requestBody.tools = buildTools(opts.tools)
    end
    if opts.toolChoice then
      requestBody.tool_choice = opts.toolChoice
    end

    local bodyJson = json.encode(requestBody)
    local responseText = utils.httpPost(url, headers, bodyJson, opts.timeout, utils.waitHooks(opts))
    local responseData = utils.decodeJSON(responseText)

    if hasError(responseData) then
      error(utils.errorMessage(responseData, responseText), 0)
    end

    return parseResponse(responseData), responseData
  end

  function model.formatToolResult(toolCall, result)
    local resultStr = type(result) == "string" and result or json.encode(result)
    local msg = {
      role = "tool",
      tool_call_id = toolCall.id,
      content = resultStr,
    }
    if isGpt5Model(modelId) then
      msg.type = "function_tool_output"
      msg.name = toolCall["function"].name
    end
    return msg
  end

  function model.addAssistantMessage(messages, parsed)
    table.insert(messages, {
      role = "assistant",
      content = parsed.text,
      tool_calls = parsed.toolCalls,
    })
  end

  function model.addToolResults(messages, toolResults)
    for _, result in ipairs(toolResults) do
      table.insert(messages, result)
    end
  end

  -- includeUsage: ask for token usage in the stream (OpenAI's stream_options),
  -- used when generateText goes through a stream and should report usage
  function model.doStream(opts, onChunk, includeUsage)
    checkApiKey(config)

    local url = chatURL(config)
    local headers = config.getHeaders()
    local messages = buildMessages(opts)

    local requestBody = {
      model = modelId,
      messages = messages,
      stream = true,
    }
    if includeUsage then
      requestBody.stream_options = { include_usage = true }
    end

    if opts.maxOutputTokens then
      if isGpt5Model(modelId) then
        requestBody.max_completion_tokens = opts.maxOutputTokens
      else
        requestBody.max_tokens = opts.maxOutputTokens
      end
    end
    -- GPT-5 (reasoning model) doesn't support temperature/topP
    if not isGpt5Model(modelId) then
      if opts.temperature then
        requestBody.temperature = opts.temperature
      end
      if opts.topP then
        requestBody.top_p = opts.topP
      end
    end
    if opts.tools then
      requestBody.tools = buildTools(opts.tools)
    end
    if opts.toolChoice then
      requestBody.tool_choice = opts.toolChoice
    end

    local bodyJson = json.encode(requestBody)
    local request = utils.httpPostStream(url, headers, bodyJson, opts.timeout, utils.waitHooks(opts))

    local fullText = ""
    local finishReason = nil
    local toolCalls = {}
    local usage = {}
    local buffer = ""
    -- Whether the reply is an event stream at all, and whether it ended
    -- properly ([DONE] or a finish reason). Lines before the first "data:"
    -- are kept: a server that ignores stream=true sends plain JSON, and a
    -- wrong base URL often gives an HTML page. Comment and field lines
    -- (":", "event:", "id:", "retry:") show that it is an event stream
    -- even when no data follows (keep-alives while a request is queued).
    local sawData, sawEnd, sawSSE = false, false, false
    local otherLines = {}
    -- The current event's name from an "event:" line (until a blank line)
    local eventName

    local function handleLine(line)
      line = line:gsub("\r$", "")
      if line == "" then
        eventName = nil
        return
      end
      -- An error sent as a line of its own ("error: {...}", as llama.cpp's
      -- server did), before or after the data
      local errorText = line:match("^error:%s?(.*)$")
      if errorText then
        local ok, decoded = pcall(json.decode, errorText)
        error(utils.errorMessage(ok and decoded or nil, errorText), 0)
      end
      if line:find("^:") or line:find("^id:") or line:find("^retry:") then
        sawSSE = true
        return
      end
      local name = line:match("^event:%s?(.-)%s*$")
      if name then
        sawSSE = true
        eventName = name
        return
      end
      if not sawData then
        if line:find("^data:") then
          sawData = true
          otherLines = nil
        else
          otherLines[#otherLines + 1] = line
          return
        end
      end
      local eventType, data, payload = utils.parseSSELine(line)
      if eventType == "done" then
        sawEnd = true
        return
      end
      -- "event: error": the data is the error, with or without an "error" key
      if eventName == "error" and payload then
        error(utils.errorMessage(data, payload), 0)
      end
      if eventType ~= "data" or type(data) ~= "table" then
        return
      end
      if hasError(data) then
        error(utils.errorMessage(data, payload), 0)
      end
      if type(data.usage) == "table" then
        usage.inputTokens = data.usage.prompt_tokens
        usage.outputTokens = data.usage.completion_tokens
        usage.totalTokens = data.usage.total_tokens
      end
      local choice = type(data.choices) == "table" and data.choices[1]
      if type(choice) ~= "table" then
        return
      end
      local delta = type(choice.delta) == "table" and choice.delta or {}
      local text = utils.contentText(delta.content)
      if text ~= "" then
        fullText = fullText .. text
        if onChunk then
          onChunk({ type = "text", text = text })
        end
      end
      if type(delta.tool_calls) == "table" then
        for _, tc in ipairs(delta.tool_calls) do
          if type(tc) == "table" then
            local idx = (tonumber(tc.index) or 0) + 1
            if not toolCalls[idx] then
              toolCalls[idx] = {
                type = "function",
                ["function"] = { name = "", arguments = "" },
              }
            end
            local call = toolCalls[idx]
            if type(tc.id) == "string" and tc.id ~= "" then call.id = tc.id end
            local fn = tc["function"]
            if type(fn) == "table" then
              if type(fn.name) == "string" then
                call["function"].name = call["function"].name .. fn.name
              end
              local args = fn.arguments
              if type(args) == "table" then
                -- Some servers send the arguments decoded. rxi json
                -- would write empty arguments as [], which is no object.
                -- (A table rxi can't encode, such as a list with holes,
                -- counts as no arguments.)
                local ok, text = pcall(json.encode, args)
                args = (ok and next(args) ~= nil) and text or "{}"
              end
              if type(args) == "string" then
                call["function"].arguments = call["function"].arguments .. args
              end
            end
          end
        end
      end
      -- Only a real reason ends the reply: some servers send "" (or null)
      -- in every chunk until the last
      if type(choice.finish_reason) == "string" and choice.finish_reason ~= "" then
        finishReason = choice.finish_reason
        sawEnd = true
      end
    end

    for chunk in request do
      buffer = buffer .. chunk
      while true do
        local lineEnd = buffer:find("\n")
        if not lineEnd then break end
        local line = buffer:sub(1, lineEnd - 1)
        buffer = buffer:sub(lineEnd + 1)
        handleLine(line)
      end
    end
    -- A final line without a trailing newline
    handleLine(buffer)

    if not sawData then
      local host = utils.hostOf(url)
      local body = table.concat(otherLines, "\n")
      if sawSSE and not body:find("%S") then
        -- An event stream that the server closed before any data, e.g.
        -- after only keep-alives while the request waited in a queue. Not
        -- a wrong base URL.
        error("The server closed the stream before sending any data " ..
          "(only keep-alive messages arrived from " .. host .. ").", 0)
      end
      -- Not an event stream: the other lines are read as a whole (comment
      -- and field lines are left out of them, so an error object after a
      -- keep-alive is still read, and an HTML page with a CSS line such as
      -- ":root {" still gets the base URL hint). Plain JSON: a whole
      -- completion (the server ignored stream=true) or an error; anything
      -- else is reported with its first bytes rather than taken as an
      -- empty answer.
      local start = body:sub(1, 300):gsub("%s+", " "):gsub("^ ", "")
      local ok, data = pcall(json.decode, body)
      if ok and type(data) == "table" then
        if hasError(data) then
          error(utils.errorMessage(data, body), 0)
        end
        local choice = type(data.choices) == "table" and data.choices[1]
        if type(choice) == "table" and type(choice.message) == "table" then
          local parsed = parseResponse(data)
          if onChunk and parsed.text ~= "" then
            onChunk({ type = "text", text = parsed.text })
          end
          return parsed
        end
      end
      if start == "" then
        error("The reply from " .. host .. " was empty (expected an event stream).", 0)
      end
      error("Expected an event stream from " .. host ..
        " (is the base URL right?). The reply starts with: " .. start:sub(1, 120), 0)
    end
    if not sawEnd then
      -- The stream stopped without [DONE] or a finish reason: the server
      -- ended it early (some document this for errors mid-stream)
      finishReason = "incomplete"
    end

    -- Tool calls in index order (deltas are keyed by index)
    local indexes = {}
    for idx in pairs(toolCalls) do
      indexes[#indexes + 1] = idx
    end
    table.sort(indexes)
    local toolCallsList = {}
    for _, idx in ipairs(indexes) do
      table.insert(toolCallsList, toolCalls[idx])
    end

    return {
      text = fullText,
      finishReason = finishReason,
      toolCalls = #toolCallsList > 0 and toolCallsList or nil,
      usage = usage,
    }
  end

  return model
end

-- defaults: baseURL, name, envVar (API key setting), apiKeyError, and
-- optionally baseURLEnvVar (setting read at request time when no baseURL
-- option is given), baseURLError, apiKeyOptional (keyless local servers),
-- streamResponses (generateText uses streamed replies; options.stream
-- overrides it per provider instance)
local function createProvider(defaults)
  utils.defineSetting(defaults.envVar, "API key for the " .. defaults.name .. " provider (cc-ai)")
  if defaults.baseURLEnvVar then
    utils.defineSetting(defaults.baseURLEnvVar, "Base URL for the " .. defaults.name .. " provider (cc-ai)")
  end
  return function(options)
    options = options or {}
    local providerName = options.name or defaults.name

    local function getBaseURL()
      return options.baseURL
        or (defaults.baseURLEnvVar and utils.getEnv(defaults.baseURLEnvVar))
        or defaults.baseURL
    end

    local function getApiKey()
      return options.apiKey or utils.getEnv(defaults.envVar)
    end

    local function getHeaders()
      local headers = {
        ["Content-Type"] = "application/json",
      }
      local apiKey = getApiKey()
      if apiKey and apiKey ~= "" then
        headers["Authorization"] = "Bearer " .. apiKey
      elseif not defaults.apiKeyOptional then
        headers["Authorization"] = "Bearer "
      end
      if options.headers then
        for k, v in pairs(options.headers) do
          headers[k] = v
        end
      end
      return headers
    end

    local config = {
      provider = providerName,
      getBaseURL = getBaseURL,
      getHeaders = getHeaders,
      getApiKey = getApiKey,
      apiKeyError = defaults.apiKeyError,
      apiKeyOptional = defaults.apiKeyOptional,
      baseURLError = defaults.baseURLError,
      -- generateText through the streaming endpoint (see doGenerate)
      streamResponses = options.stream == nil and defaults.streamResponses or options.stream,
    }

    local function createModel(modelId)
      return createLanguageModel(modelId, config)
    end

    local provider = setmetatable({
      languageModel = createModel,
      chat = createModel,
    }, {
      __call = function(_, modelId)
        return createModel(modelId)
      end,
    })

    return provider
  end
end

return {
  createProvider = createProvider,
  createLanguageModel = createLanguageModel,
  buildMessages = buildMessages,
  buildTools = buildTools,
  parseResponse = parseResponse,
}

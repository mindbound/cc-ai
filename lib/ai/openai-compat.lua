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

local function buildTools(tools)
  if not tools then return nil end
  local result = {}
  for _, tool in ipairs(tools) do
    if tool.type == "function" then
      table.insert(result, {
        type = "function",
        ["function"] = {
          name = tool["function"].name,
          description = tool["function"].description,
          parameters = tool["function"].parameters,
        },
      })
    end
  end
  return #result > 0 and result or nil
end

local function parseResponse(response)
  local choice = response.choices and response.choices[1]
  if not choice then
    error("No choices in response")
  end

  local message = choice.message
  local usage = {}
  if response.usage then
    usage.inputTokens = response.usage.prompt_tokens
    usage.outputTokens = response.usage.completion_tokens
    usage.totalTokens = response.usage.total_tokens
  end

  return {
    text = message.content or "",
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

    if responseData.error then
      error(responseData.error.message or json.encode(responseData.error), 0)
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

    local function handleLine(line)
      if line == "" then return end
      local eventType, data = utils.parseSSELine(line)
      if eventType == "data" and data then
        if data.error then
          local e = data.error
          error(type(e) == "table" and (e.message or json.encode(e)) or tostring(e), 0)
        end
        if type(data.usage) == "table" then
          usage.inputTokens = data.usage.prompt_tokens
          usage.outputTokens = data.usage.completion_tokens
          usage.totalTokens = data.usage.total_tokens
        end
        local choice = data.choices and data.choices[1]
        if choice then
          local delta = choice.delta
          if delta and delta.content then
            fullText = fullText .. delta.content
            if onChunk then
              onChunk({ type = "text", text = delta.content })
            end
          end
          if delta and delta.tool_calls then
            for _, tc in ipairs(delta.tool_calls) do
              local idx = (tc.index or 0) + 1
              if not toolCalls[idx] then
                toolCalls[idx] = {
                  id = tc.id,
                  type = "function",
                  ["function"] = { name = "", arguments = "" },
                }
              end
              if tc.id then toolCalls[idx].id = tc.id end
              if tc["function"] then
                if tc["function"].name then
                  toolCalls[idx]["function"].name = toolCalls[idx]["function"].name .. tc["function"].name
                end
                if tc["function"].arguments then
                  toolCalls[idx]["function"].arguments = toolCalls[idx]["function"].arguments .. tc["function"].arguments
                end
              end
            end
          end
          if choice.finish_reason then
            finishReason = choice.finish_reason
          end
        end
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

    -- Tool calls in index order (deltas are keyed by index)
    local maxIndex = 0
    for idx in pairs(toolCalls) do
      if idx > maxIndex then maxIndex = idx end
    end
    local toolCallsList = {}
    for idx = 1, maxIndex do
      if toolCalls[idx] then
        table.insert(toolCallsList, toolCalls[idx])
      end
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

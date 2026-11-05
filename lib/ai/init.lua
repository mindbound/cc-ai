local json = require("cmn-utils.json")
local vercel = require("ai.vercel")

local ai = {}

-- Output specification helpers
ai.Output = {
  object = function(opts)
    return {
      type = "object",
      schema = opts.schema,
    }
  end,
}

-- Tool helper for cleaner tool definitions
function ai.tool(opts)
  if type(opts) ~= "table" then
    error("tool requires a table argument")
  end
  if not opts.name then
    error("tool requires a name")
  end
  return {
    type = "function",
    ["function"] = {
      name = opts.name,
      description = opts.description,
      parameters = opts.parameters,
      execute = opts.execute,
    },
  }
end

local function findTool(tools, name)
  if not tools then return nil end
  for _, tool in ipairs(tools) do
    if tool.type == "function" and tool["function"].name == name then
      return tool
    end
  end
  return nil
end

-- Providers that a "provider:model" string can name. Anything else is a
-- Vercel AI Gateway model ("creator/model").
local DIRECT_PROVIDERS = { "google", "openai", "groq", "custom" }

-- Turn a model spec into what generateText takes:
--   "custom:deepseek/deepseek-v4.1-flash:thinking" -> custom provider model
--   "gateway:openai/gpt-4o" or "openai/gpt-4o"     -> gateway model string
-- Only the first ":" splits, and only after a known provider name, because
-- model ids contain ":" themselves. Model objects are returned unchanged.
function ai.resolveModel(spec)
  if type(spec) ~= "string" then
    return spec
  end
  local prefix, id = spec:match("^([%w_%-]+):(.+)$")
  if prefix then
    prefix = prefix:lower()
    if prefix == "gateway" or prefix == "vercel" then
      return id
    end
    for _, name in ipairs(DIRECT_PROVIDERS) do
      if prefix == name then
        return require("ai." .. name)(id)
      end
    end
  end
  return spec
end

-- The spec string for a model (the inverse of resolveModel)
function ai.modelSpec(model)
  if type(model) == "table" and model.provider and model.modelId then
    return tostring(model.provider) .. ":" .. tostring(model.modelId)
  end
  return tostring(model)
end

-- Raised by a tool when the user pressed Ctrl+T while it ran. The plain
-- string "Terminated" works too; a table can carry a partial result that is
-- still reported to the model, e.g. { terminated = true, result = {...} }.
local function isCancel(err)
  return err == "Terminated" or (type(err) == "table" and err.terminated == true)
end

-- Run a tool. Returns its result, or nil plus the cancel value when the user
-- cancelled it with Ctrl+T.
local function executeTool(tool, args)
  local fn = tool["function"]
  if fn and fn.execute then
    local ok, result = pcall(fn.execute, args)
    if ok then
      return result
    elseif isCancel(result) then
      return nil, result
    else
      return { error = tostring(result) }
    end
  end
  return { error = "No execute function" }
end

-- Decode a tool call's arguments (a JSON string, or a table from a server
-- that sends them decoded). Missing or blank arguments, and JSON that is
-- not an object (a list, a number, ...), mean "no arguments" ({}); returns
-- nil when they are not valid JSON (usually a reply cut off at the output
-- token limit). The second value is the arguments as they go back in the
-- history: a JSON object text, as strict servers reject anything else
-- ("{}" for none, or for broken ones: rxi json would write {} as []).
local function decodeArguments(raw)
  local args = raw
  if type(raw) == "string" and raw:find("%S") then
    local ok
    ok, args = pcall(json.decode, raw)
    if not ok then
      return nil, "{}"
    end
  end
  -- A decoded JSON object has only string keys, a list only number keys
  -- (also a list that starts with null, which has no [1])
  if type(args) ~= "table" or type(next(args)) == "number" then
    return {}, "{}"
  end
  if next(args) == nil then
    return args, "{}"
  end
  if type(raw) == "string" then
    return args, raw
  end
  local ok, text = pcall(json.encode, args)
  return args, ok and text or "{}"
end

-- The result of the last tool call of a reply that was cut off (see
-- runToolCalls), by finish reason
local CUT_OFF = {
  incomplete = "The reply ended early (the server stopped sending), so this call " ..
    "was cut off and did not run; send it again.",
  length = "The reply hit the output token limit, so this call was cut off and " ..
    "did not run; send it again in smaller parts (write large files in several " ..
    "smaller write_file/edit_file calls).",
}

-- Run one step's tool calls and add their results to messages. Returns the
-- cancel value when the user pressed Ctrl+T in a tool: the remaining calls
-- are skipped, and every call still gets a result, so the messages stay
-- valid for the next request.
-- When the reply was cut off (finishReason "incomplete": the stream
-- stopped without [DONE] or a finish reason; or "length": the output token
-- limit), its last call may be cut off too: with blank or broken arguments
-- it does not run. (Earlier calls were complete before the next one
-- started.)
local function runToolCalls(model, tools, messages, parsed, allToolResults)
  local parts = {}
  local cancel
  local incomplete = parsed.finishReason == "incomplete"
  local cutMessage = CUT_OFF[parsed.finishReason]
  local count = #parsed.toolCalls
  for i, toolCall in ipairs(parsed.toolCalls) do
    local fn = toolCall["function"] or {}
    local name = fn.name
    local blank = fn.arguments == nil or (type(fn.arguments) == "string" and not fn.arguments:find("%S"))
    local args, sendBack = decodeArguments(fn.arguments)
    local cutOff = cutMessage and i == count and (blank or not args)
    -- Don't send broken, blank or non-object arguments back with later
    -- requests (strict servers reject the whole history), also when the
    -- call is skipped
    fn.arguments = sendBack
    local result

    if cancel then
      result = { error = "Skipped: the user cancelled the turn (Ctrl+T)." }
    elseif cutOff then
      result = { error = cutMessage }
    elseif not args then
      local msg = "The arguments were not valid JSON, so the tool did not run."
      if parsed.finishReason == "length" then
        msg = msg .. " The reply hit the output token limit: write large files " ..
          "in several smaller write_file/edit_file calls."
      elseif incomplete then
        msg = msg .. " The reply ended early (the server stopped sending); send the call again."
      end
      result = { error = msg }
    else
      local tool = findTool(tools, name)
      if tool then
        local value, cancelled = executeTool(tool, args)
        if cancelled then
          cancel = cancelled
          local partial = type(cancelled) == "table" and cancelled.result
          if type(partial) == "table" then
            result = partial
            result.cancelled = "Stopped by the user (Ctrl+T)."
          else
            result = { error = "Cancelled by the user (Ctrl+T)." }
          end
        else
          result = value
        end
      else
        result = { error = "Unknown tool: " .. tostring(name) }
      end
    end

    table.insert(allToolResults, {
      toolCallId = toolCall.id,
      toolName = name,
      args = args or {},
      result = result,
    })
    table.insert(parts, model.formatToolResult(toolCall, result))
  end
  model.addToolResults(messages, parts)
  return cancel
end

-- The step loop shared by generateText and streamText. call(currentOpts)
-- makes one model request and returns the parsed reply (and the raw one).
-- Hooks in opts:
--   onStepStart(step, maxSteps)   before each model request
--   onStepFinish(info)            after each step, once its tool results are
--                                 in the messages (info: step, text,
--                                 toolCalls, finishReason, usage, and
--                                 cancelled = true when Ctrl+T stopped one
--                                 of its tools)
--   onWait, onEvent               while waiting for a reply (see ai.utils;
--                                 they must not yield)
local function runSteps(model, opts, call)
  local maxSteps = opts.maxSteps or 1
  local allToolResults = {}
  local totalUsage = { inputTokens = 0, outputTokens = 0, totalTokens = 0 }
  local text, finishReason, rawResponse
  local steps, stepLimitReached = 0, false

  -- Copy opts for mutation during tool loop
  local currentOpts = {}
  for k, v in pairs(opts) do
    currentOpts[k] = v
  end

  -- Handle structured output
  local outputSpec = opts.output
  if outputSpec and outputSpec.type == "object" then
    local schemaJson = json.encode(outputSpec.schema)
    local systemPrompt = "Output JSON only. No extra text. No code blocks. Schema:\n" .. schemaJson
    if currentOpts.system then
      currentOpts.system = currentOpts.system .. "\n\n" .. systemPrompt
    else
      currentOpts.system = systemPrompt
    end
  end

  for step = 1, maxSteps do
    if opts.onStepStart then
      opts.onStepStart(step, maxSteps)
    end

    local parsed
    parsed, rawResponse = call(currentOpts)
    steps = step

    text = parsed.text
    finishReason = parsed.finishReason
    local usage = parsed.usage or {}
    totalUsage.inputTokens = totalUsage.inputTokens + (usage.inputTokens or 0)
    totalUsage.outputTokens = totalUsage.outputTokens + (usage.outputTokens or 0)
    totalUsage.totalTokens = totalUsage.totalTokens + (usage.totalTokens or 0)

    local hasTools = parsed.toolCalls and #parsed.toolCalls > 0
    local cancel
    if hasTools then
      -- Build messages for next iteration
      currentOpts.messages = currentOpts.messages or {}
      if currentOpts.prompt then
        table.insert(currentOpts.messages, { role = "user", content = currentOpts.prompt })
        currentOpts.prompt = nil
      end

      model.addAssistantMessage(currentOpts.messages, parsed)
      cancel = runToolCalls(model, opts.tools, currentOpts.messages, parsed, allToolResults)
    end

    if opts.onStepFinish then
      opts.onStepFinish({
        step = step,
        text = parsed.text,
        toolCalls = parsed.toolCalls,
        finishReason = parsed.finishReason,
        usage = usage,
        cancelled = cancel ~= nil,
      })
    end

    if cancel then
      error("Terminated", 0)
    end
    if not hasTools then
      break
    end
    if step == maxSteps then
      -- Stopped with tool results the model has not seen yet
      stepLimitReached = true
      break
    end
  end

  -- Parse structured output
  local output = nil
  if outputSpec and outputSpec.type == "object" and text then
    local ok, parsed = pcall(json.decode, text)
    if ok then
      output = parsed
    end
  end

  return {
    text = text,
    output = output,
    finishReason = finishReason,
    usage = totalUsage,
    toolResults = allToolResults,
    response = rawResponse,
    steps = steps,
    stepLimitReached = stepLimitReached,
  }
end

function ai.generateText(opts)
  if type(opts) ~= "table" then
    error("generateText requires a table argument")
  end
  if not opts.model then
    error("model is required")
  end
  if not opts.prompt and not opts.messages then
    error("prompt or messages is required")
  end

  -- Get or create model
  local model
  if type(opts.model) == "table" and opts.model.doGenerate then
    model = opts.model
  else
    model = vercel(opts.model)
  end

  return runSteps(model, opts, function(currentOpts)
    return model.doGenerate(currentOpts)
  end)
end

function ai.streamText(opts)
  if type(opts) ~= "table" then
    error("streamText requires a table argument")
  end
  if not opts.model then
    error("model is required")
  end
  if not opts.prompt and not opts.messages then
    error("prompt or messages is required")
  end

  -- Get or create model
  local model
  if type(opts.model) == "table" and opts.model.doStream then
    model = opts.model
  elseif type(opts.model) == "table" and opts.model.doGenerate then
    error("This model does not support streaming")
  else
    model = vercel(opts.model)
  end

  local onChunk = opts.onChunk
  local result = runSteps(model, opts, function(currentOpts)
    return model.doStream(currentOpts, onChunk)
  end)

  if opts.onFinish then
    opts.onFinish({
      text = result.text,
      finishReason = result.finishReason,
      toolResults = result.toolResults,
      steps = result.steps,
      stepLimitReached = result.stepLimitReached,
    })
  end

  return {
    text = result.text,
    finishReason = result.finishReason,
    toolResults = result.toolResults,
    usage = result.usage,
    steps = result.steps,
    stepLimitReached = result.stepLimitReached,
  }
end

function ai.generateObject(opts)
  if type(opts) ~= "table" then
    error("generateObject requires a table argument")
  end
  if not opts.model then
    error("model is required")
  end
  if not opts.schema then
    error("schema is required")
  end
  if not opts.prompt and not opts.messages then
    error("prompt or messages is required")
  end

  local result = ai.generateText({
    model = opts.model,
    prompt = opts.prompt,
    messages = opts.messages,
    system = opts.system,
    maxOutputTokens = opts.maxOutputTokens,
    temperature = opts.temperature,
    topP = opts.topP,
    timeout = opts.timeout,
    output = ai.Output.object({ schema = opts.schema }),
  })

  if not result.output then
    error("Failed to parse structured output")
  end

  return {
    object = result.output,
    finishReason = result.finishReason,
    usage = result.usage,
    response = result.response,
  }
end

return ai

-- Custom OpenAI-compatible provider: any endpoint that implements
-- /chat/completions (NanoGPT, OpenRouter, LM Studio, llama.cpp, Ollama, ...).
-- Configure it with settings:
--   set AI_CUSTOM_BASE_URL https://nano-gpt.com/api/v1
--   set AI_CUSTOM_API_KEY <key>          (optional for keyless local servers)
-- or in code: require("ai.custom").createCustom({ baseURL = ..., apiKey = ... })
local compat = require("ai.openai-compat")

local createCustom = compat.createProvider({
  name = "custom",
  envVar = "AI_CUSTOM_API_KEY",
  baseURLEnvVar = "AI_CUSTOM_BASE_URL",
  apiKeyOptional = true,
  -- generateText uses streamed replies: data keeps arriving while a slow
  -- (thinking) model works, so the 60s idle timeout isn't hit. Disable with
  -- createCustom({ stream = false }) for servers without streaming.
  streamResponses = true,
  apiKeyError = "Run: set AI_CUSTOM_API_KEY <key>, or pass apiKey to createCustom().",
  baseURLError = "No endpoint configured. Run: set AI_CUSTOM_BASE_URL <url> " ..
    "(e.g. https://host/v1), or pass baseURL to createCustom().",
})

local custom = setmetatable({
  createCustom = createCustom,
}, {
  __call = function(_, modelId)
    return createCustom()(modelId)
  end,
  __index = createCustom(),
})

return custom

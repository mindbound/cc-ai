local compat = require("ai.openai-compat")

local createGroq = compat.createProvider({
  baseURL = "https://api.groq.com/openai/v1",
  name = "groq",
  envVar = "GROQ_API_KEY",
  apiKeyError = "Run: set GROQ_API_KEY <key>, or pass apiKey to createGroq().",
})

local groq = setmetatable({
  createGroq = createGroq,
}, {
  __call = function(_, modelId)
    return createGroq()(modelId)
  end,
  __index = createGroq(),
})

return groq

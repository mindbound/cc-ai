-- Make the cc-ai libraries in ../../lib requireable
package.path = "../../lib/?.lua;../../lib/?/init.lua;" .. package.path

local ai = require("ai")
local groq = require("ai.groq")

local result = ai.generateText({
  model = groq("llama-3.3-70b-versatile"),
  prompt = "Why is the sky blue?",
  maxOutputTokens = 100,
})

print(result.text)

-- Make the cc-ai libraries in ../lib requireable
package.path = "../lib/?.lua;../lib/?/init.lua;" .. package.path

local ai = require("ai")

local result = ai.generateText({
  model = "google/gemini-2.5-flash-lite",
  prompt = "Why is the sky blue? (50 words)",
  maxOutputTokens = 100,
})

print(result.text)

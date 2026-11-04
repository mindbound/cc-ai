-- Make the cc-ai libraries in ../../lib requireable
package.path = "../../lib/?.lua;../../lib/?/init.lua;" .. package.path

local ai = require("ai")
local google = require("ai.google")

local result = ai.generateText({
  model = google("gemini-2.5-flash"),
  prompt = "Why is the sky blue?",
  maxOutputTokens = 1000,
})

print(result.text)

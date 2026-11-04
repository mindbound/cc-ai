-- Make the cc-ai libraries in ../../lib requireable
package.path = "../../lib/?.lua;../../lib/?/init.lua;" .. package.path

-- examples/cc-code/basic.lua
-- Basic example of using cc-code programmatically

local occode = require("cc-code")

-- One-shot mode: ask a single question
print("Asking cc-code to list files...")
local response = occode.exec("List the files in the current directory")
print("Response:", response)

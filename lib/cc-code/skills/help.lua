-- cc-code/skills/help.lua
-- Help skill - shows available commands and usage

local skills = require("cc-code.skills")

return skills.create({
  name = "help",
  description = "Show help and available commands",
  commands = { "/help", "/?" },

  onActivate = function(agent, args)
    local currentModel = agent.config.model
    local modelStr = type(currentModel) == "string" and currentModel or
      (currentModel.provider .. ":" .. currentModel.modelId)

    local lines = {
      "cc-code - AI Coding Agent for ComputerCraft",
      "",
      "Current model: " .. modelStr,
      "",
      "Commands:",
      "  /help, /?       - Show this help message",
      "  /model          - View/switch AI model or provider",
      "    /model                    - List available models",
      "    /model <provider/model>   - Use gateway model",
      "    /model google <model>     - Use Google directly",
      "    /model openai <model>     - Use OpenAI directly",
      "    /model groq <model>       - Use Groq directly",
      "    /model custom <model>     - Use AI_CUSTOM_BASE_URL",
      "  /turtle <prompt> - Ask turtle programming question with context",
      "    /turtle write a mining script    - Quick reference",
      "    /turtle full <prompt>            - Use full API docs",
      "  /clear          - Clear conversation history",
      "  /exit, /quit    - Exit cc-code",
      "",
      "Shell Commands:",
      "  !<command>      - Execute shell command directly",
      "    Examples:",
      "      !ls         - List files in current directory",
      "      !cd disk    - Change directory",
      "      !id         - Show computer ID and label",
      "",
      "Tools:",
      "  read_file, write_file, edit_file, list_directory,",
      "  glob, grep, shell",
      "",
      "Tips:",
      "  - Type naturally to ask for help with code",
      "  - Use PageUp/PageDown or the mouse wheel to scroll",
      "  - Hold Ctrl+T to cancel a request, or to exit at the prompt",
      "  - API keys: exit, then run: set <KEY_NAME> <key>",
    }
    -- Return nil to prevent sending to AI, handle directly
    return nil, table.concat(lines, "\n")
  end,
})

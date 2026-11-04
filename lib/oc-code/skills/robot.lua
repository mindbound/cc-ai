-- oc-code/skills/robot.lua
-- Robot skill - loads Robot API context for AI assistance

local skills = require("oc-code.skills")
local fs = require("filesystem")
local shell = require("shell")
local component = require("component")

-- Path to robot API documentation (relative to working directory)
local ROBOT_DOCS_PATH = "/home/oc-ai/docs/robot.md"

-- Quick reference for common robot operations
local function getQuickReference()
  return [[OpenComputers Robot API Quick Reference:

Movement:
  robot.forward/back/up/down() -> boolean, string
  robot.turnLeft/turnRight/turnAround()

Inventory:
  robot.select([slot]) -> number
  robot.count([slot]) -> number
  robot.space([slot]) -> number
  robot.transferTo(slot, [count]) -> boolean

World Interaction:
  robot.detect/detectUp/detectDown() -> boolean, string
  robot.compare/compareUp/compareDown() -> boolean
  robot.swing/swingUp/swingDown([side, sneaky]) -> boolean, string
  robot.use/useUp/useDown([side, sneaky, duration]) -> boolean, string
  robot.place/placeUp/placeDown([side, sneaky]) -> boolean, string

Items:
  robot.drop/dropUp/dropDown([count]) -> boolean
  robot.suck/suckUp/suckDown([count]) -> boolean

Tools:
  robot.durability() -> number, number, number or nil, string

Fluids (if tank upgrades installed):
  robot.tankCount() -> number
  robot.selectTank(tank)
  robot.tankLevel([tank]) -> number
  robot.drain/drainUp/drainDown([count]) -> boolean
  robot.fill/fillUp/fillDown([count]) -> boolean
]]
end

return skills.create({
  name = "robot",
  description = "Load Robot API documentation as context",
  commands = { "/robot" },

  onActivate = function(agent, args)
    -- Parse arguments to determine if "full" is specified and extract user prompt
    local loadFull = false
    local userPrompt = args or ""

    if args and args:match("^%s*full%s+") then
      -- "/robot full <prompt>"
      loadFull = true
      userPrompt = args:match("^%s*full%s+(.+)") or ""
    elseif args and args:match("^%s*full%s*$") then
      -- Just "/robot full" with no prompt
      loadFull = true
      userPrompt = ""
    end

    -- On robots the systemPrompt below already carries the context every turn;
    -- injecting it again into message history would duplicate it permanently.
    if not loadFull and component.isAvailable("robot") then
      if userPrompt ~= "" then
        return userPrompt
      end
      return nil, "Robot context is already active on this robot.\n" ..
                  "Ask robot questions directly, or use /robot full to load the complete API docs."
    end

    -- Build context (quick reference or full docs)
    local context
    if loadFull then
      -- Try to load full documentation
      if not fs.exists(ROBOT_DOCS_PATH) then
        context = getQuickReference()
      else
        local handle = io.open(ROBOT_DOCS_PATH, "r")
        if handle then
          context = handle:read("*a")
          handle:close()
        else
          context = getQuickReference()
        end
      end
    else
      -- Load quick reference (non-robot machine writing robot code)
      context = getQuickReference()
    end

    -- If user provided a prompt, combine context with their question
    if userPrompt ~= "" then
      return "I need help with OpenComputers robot programming.\n\n" ..
             context .. "\n\n" ..
             "My question: " .. userPrompt
    else
      -- No prompt provided, just show the context
      return nil, "Robot API context loaded. You can now ask robot programming questions.\n\n" ..
                  (loadFull and "Full documentation loaded." or "Quick reference loaded.") ..
                  "\n\nExample: /robot write a script to mine a 3x3 area"
    end
  end,

  -- Only inject robot context when this machine actually is a robot
  systemPrompt = component.isAvailable("robot") and [[
## Robot Programming
This machine is an OpenComputers robot: `local robot = require("robot")`. How robots interact with the world:

Position and orientation:
- There are NO coordinates. All movement is relative to current facing. Track position yourself: keep x, z, heading variables and update them on every SUCCESSFUL move/turn (dead reckoning).
- turnLeft/turnRight rotate 90 degrees; forward/back/up/down move exactly one block.

Movement can fail:
- Moves return true, or nil plus a reason (block, entity, "impossible move"). Always check the return value. On failure: retry after os.sleep(0.5), swing() to clear the obstacle, or abort with error(). Never update tracked position on a failed move, or the whole plan desyncs.
- Flight limit: at most 8 blocks above solid ground without a hover upgrade; "impossible move" often means this or an unloaded chunk.

Placing blocks:
- The robot occupies its own block and CANNOT place where it stands. To build a flat path or floor: fly one block above the target row and placeDown() after each move.
- place/placeDown/placeUp only work if the target position touches an existing solid block (no placing in mid-air without an Angel upgrade).
- Blocks come from the currently selected slot: robot.select(slot) first, check robot.count(), and switch to the next stocked slot when a stack runs out. Check place return values too.

Mining and tools: swing/swingUp/swingDown left-click with the equipped tool (tool durability runs out); use() right-clicks.

Writing build scripts (shapes, patterns, fractals):
1. Compute the full move/turn/place sequence first (e.g. L-system rules for a Hilbert curve), THEN execute it.
2. Execute through a small safeMove/safePlace wrapper that checks returns, retries, and updates tracked position.
3. Report progress with print() so the user can watch, and stop with a clear error() message on unrecoverable failure.

Full API reference: /robot full, or read_file /home/oc-ai/docs/robot.md.

]] .. getQuickReference() or nil,
})

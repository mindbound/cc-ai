-- cc-code/skills/turtle.lua
-- Turtle skill - loads Turtle API context for AI assistance

local skills = require("cc-code.skills")

-- Full turtle API reference, shipped with cc-ai at docs/turtle.md.
-- Found relative to this file: <root>/lib/cc-code/skills/turtle.lua
local function getDocsPath()
  local source = debug.getinfo(1, "S").source or ""
  local root = source:match("^@(.*)/lib/cc%-code/skills/turtle%.lua$")
  if root then
    return root .. "/docs/turtle.md"
  end
  return "/cc-ai/docs/turtle.md"
end

local TURTLE_DOCS_PATH = getDocsPath()

-- Quick reference for common turtle operations
local function getQuickReference()
  return [=[ComputerCraft Turtle API Quick Reference (global `turtle`, no require):

Movement (each block moved costs 1 fuel):
  turtle.forward/back/up/down() -> boolean, string|nil
  turtle.turnLeft/turnRight() -> boolean, string|nil

Fuel:
  turtle.getFuelLevel() -> number | "unlimited"
  turtle.getFuelLimit() -> number | "unlimited"
  turtle.refuel([count]) -> boolean, string|nil  (burns items in the selected slot; count 0 = just test)

Inventory (16 slots):
  turtle.select(slot) -> true
  turtle.getSelectedSlot() -> number
  turtle.getItemCount([slot]) -> number
  turtle.getItemSpace([slot]) -> number
  turtle.getItemDetail([slot [, detailed]]) -> { name, count, ... } | nil
  turtle.transferTo(slot [, count]) -> boolean
  turtle.compareTo(slot) -> boolean

World Interaction:
  turtle.detect/detectUp/detectDown() -> boolean
  turtle.inspect/inspectUp/inspectDown() -> boolean, { name, state, tags } | string
  turtle.compare/compareUp/compareDown() -> boolean
  turtle.dig/digUp/digDown([side]) -> boolean, string|nil  (needs a pickaxe/tool)
  turtle.attack/attackUp/attackDown([side]) -> boolean, string|nil
  turtle.place/placeUp/placeDown([text]) -> boolean, string|nil

Items:
  turtle.drop/dropUp/dropDown([count]) -> boolean, string|nil
  turtle.suck/suckUp/suckDown([count]) -> boolean, string|nil

Upgrades:
  turtle.equipLeft/equipRight() -> boolean, string|nil  (swap selected slot with that side)
  turtle.craft([limit]) -> boolean, string|nil  (needs a crafting table upgrade)
]=]
end

return skills.create({
  name = "turtle",
  description = "Load Turtle API documentation as context",
  commands = { "/turtle" },

  onActivate = function(agent, args)
    -- Parse arguments to determine if "full" is specified and extract user prompt
    local loadFull = false
    local userPrompt = args or ""

    if args and args:match("^%s*full%s+") then
      -- "/turtle full <prompt>"
      loadFull = true
      userPrompt = args:match("^%s*full%s+(.+)") or ""
    elseif args and args:match("^%s*full%s*$") then
      -- Just "/turtle full" with no prompt
      loadFull = true
      userPrompt = ""
    end

    -- On turtles the systemPrompt below already carries the context every turn;
    -- injecting it again into message history would duplicate it permanently.
    if not loadFull and turtle then
      if userPrompt ~= "" then
        return userPrompt
      end
      return nil, "Turtle context is already active on this turtle.\n" ..
                  "Ask turtle questions directly, or use /turtle full to load the complete API docs."
    end

    -- Build context (quick reference or full docs)
    local context
    if loadFull then
      -- Try to load full documentation
      local handle = fs.exists(TURTLE_DOCS_PATH) and fs.open(TURTLE_DOCS_PATH, "r")
      if handle then
        context = handle.readAll()
        handle.close()
      else
        context = getQuickReference()
      end
    else
      -- Load quick reference (non-turtle machine writing turtle code)
      context = getQuickReference()
    end

    -- If user provided a prompt, combine context with their question
    if userPrompt ~= "" then
      return "I need help with ComputerCraft turtle programming.\n\n" ..
             context .. "\n\n" ..
             "My question: " .. userPrompt
    else
      -- No prompt provided, just show the context
      return nil, "Turtle API context loaded. You can now ask turtle programming questions.\n\n" ..
                  (loadFull and "Full documentation loaded." or "Quick reference loaded.") ..
                  "\n\nExample: /turtle write a script to mine a 3x3 tunnel"
    end
  end,

  -- Only inject turtle context when this machine actually is a turtle
  systemPrompt = turtle and [[
## Turtle Programming
This machine is a ComputerCraft turtle: the `turtle` API is a global (no require). How turtles interact with the world:

Position and orientation:
- Turtles don't know their coordinates or facing. Track position yourself: keep x, y, z, heading variables and update them on every SUCCESSFUL move/turn (dead reckoning). gps.locate() only works if GPS host computers are set up nearby.
- turnLeft/turnRight rotate 90 degrees; forward/back/up/down move exactly one block.

Fuel:
- Every block moved costs 1 fuel (turning is free). Check turtle.getFuelLevel() before long jobs ("unlimited" means fuel is disabled); refuel with turtle.select(slot) + turtle.refuel(). Running out of fuel makes every move fail with "Out of fuel".

Movement can fail:
- Moves return true, or false plus a reason ("Movement obstructed", "Out of fuel", ...). Always check the return value. On failure: retry after os.sleep(0.5), dig() to clear a block, attack() for a mob, or abort with error(). Never update tracked position on a failed move, or the whole plan desyncs.
- Turtles can fly: there is no height limit above ground and no gravity, but falling blocks (sand, gravel) may refill a dug space, so re-check after dig().

Placing blocks:
- place/placeUp/placeDown put the selected slot's block in front/above/below. The turtle occupies its own block and can't place where it stands. To build a floor: move one block above the target row and placeDown() after each move.
- Blocks come from the currently selected slot: turtle.select(slot) first, check turtle.getItemCount(), and switch to the next stocked slot when a stack runs out (turtle.getItemDetail(slot).name tells you what is there). Check place return values too.

Mining and tools: dig/digUp/digDown need a pickaxe or other tool upgrade equipped (mining turtle); attack() hits entities. inspect() returns the block's name, e.g. "minecraft:stone".

Writing build scripts (shapes, patterns, fractals):
1. Compute the full move/turn/place sequence first (e.g. L-system rules for a Hilbert curve), THEN execute it.
2. Execute through a small safeMove/safePlace wrapper that checks returns, retries, and updates tracked position.
3. Check fuel up front, report progress with print() so the user can watch, and stop with a clear error() message on unrecoverable failure.

Full API reference: /turtle full, or read_file ]] .. TURTLE_DOCS_PATH .. [[.

]] .. getQuickReference() or nil,
})

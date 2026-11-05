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

-- Read the full reference (nil if it is missing)
local function readDocs()
  local handle = fs.exists(TURTLE_DOCS_PATH) and fs.open(TURTLE_DOCS_PATH, "rb")
  if not handle then
    return nil
  end
  local docs = handle.readAll()
  handle.close()
  return docs
end

-- How turtles work, for the system prompt on a turtle
local TURTLE_GUIDE = [[
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
]]

return skills.create({
  name = "turtle",
  description = "Add the turtle API reference to the conversation",
  commands = { "/turtle" },

  -- /turtle [question]       the quick reference
  -- /turtle full [question]  the full reference (docs/turtle.md)
  -- The reference goes into the system prompt for the rest of the
  -- conversation (/clear removes it); a question is then sent as typed.
  onActivate = function(agent, args)
    args = args or ""
    local loadFull = false
    local userPrompt = args:match("^%s*(.-)%s*$")
    local rest = userPrompt:match("^full%s+(.+)$")
    if rest then
      loadFull, userPrompt = true, rest
    elseif userPrompt == "full" then
      loadFull, userPrompt = true, ""
    end

    local context = agent.state.context
    local before = context.turtle
    if loadFull then
      context.turtle = "full"
    elseif before ~= "full" and not turtle then
      -- On a turtle the quick reference is always in the system prompt
      context.turtle = "quick"
    end

    if userPrompt ~= "" then
      return userPrompt
    end
    if context.turtle == before or (not loadFull and turtle) then
      return nil, (context.turtle == "full" and "The full turtle API reference"
        or "The turtle API quick reference") .. " is already in the context.\n" ..
        (context.turtle ~= "full" and "Use /turtle full for the complete docs; " or "") ..
        "ask turtle questions directly."
    end
    local what = context.turtle == "full"
      and (readDocs() and "The full turtle API reference" or "The turtle API quick reference (docs/turtle.md is missing)")
      or "The turtle API quick reference"
    return nil, what .. " is now in the context for this conversation (/clear removes it).\n" ..
      "Example: write a script to mine a 3x3 tunnel"
  end,

  -- On a turtle: how turtles work and the quick reference, always. After
  -- /turtle: the quick reference, or after /turtle full: the full docs.
  systemPrompt = function(agent)
    local mode = agent and agent.state and agent.state.context and agent.state.context.turtle
    local parts = {}
    if turtle then
      parts[#parts + 1] = TURTLE_GUIDE
    end
    local docs = mode == "full" and readDocs()
    if docs then
      parts[#parts + 1] = "Full turtle API reference (" .. TURTLE_DOCS_PATH .. "):\n" .. docs
    elseif turtle or mode then
      parts[#parts + 1] = getQuickReference()
    end
    if #parts == 0 then
      return nil
    end
    return table.concat(parts, "\n")
  end,
})

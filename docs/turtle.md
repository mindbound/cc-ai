# Turtle API

Reference for programming ComputerCraft: Tweaked turtles, loaded by `/turtle full` in cc-code. The `turtle` API is a global on turtles (no `require`). It does not exist on computers or pocket computers, so check `if not turtle then error("Run this on a turtle") end`.

Every turtle function yields (it waits for the next game tick), so turtle loops never hit "Too long without yielding". Most actions return `true` on success, or `false` plus a reason string on failure. Always check the result.

## Movement

| Function | Returns | Notes |
|---|---|---|
| `turtle.forward()` | `boolean, string?` | Move one block forward |
| `turtle.back()` | `boolean, string?` | Move one block back (doesn't turn) |
| `turtle.up()` | `boolean, string?` | Move one block up |
| `turtle.down()` | `boolean, string?` | Move one block down |
| `turtle.turnLeft()` | `boolean, string?` | Rotate 90 degrees counter-clockwise |
| `turtle.turnRight()` | `boolean, string?` | Rotate 90 degrees clockwise |

- Moving costs 1 fuel per block. Turning is free.
- Common failure reasons: `"Movement obstructed"` (block or entity in the way), `"Out of fuel"`, `"Too high to move"` / `"Too low to move"` (world height limits).
- There's no gravity or flight limit: turtles can hover anywhere.
- Turtles don't know where they are. Track position and heading yourself, and update them only after a successful move or turn. `gps.locate(timeout)` returns `x, y, z` when GPS host computers have been set up and the turtle has a wireless modem.

## Fuel

| Function | Returns | Notes |
|---|---|---|
| `turtle.getFuelLevel()` | `number` or `"unlimited"` | `"unlimited"` when fuel is disabled in the server config |
| `turtle.getFuelLimit()` | `number` or `"unlimited"` | 20000 for normal turtles, 100000 for advanced |
| `turtle.refuel([count])` | `boolean, string?` | Burn items from the selected slot. `refuel(0)` only tests whether the item is fuel |

Coal and charcoal give 80 fuel each, and a lava bucket gives 1000. Check the fuel level before a long job, so the turtle doesn't strand itself halfway.

## Inventory

A turtle has 16 slots, numbered 1-16 (row by row, starting top-left).

| Function | Returns | Notes |
|---|---|---|
| `turtle.select(slot)` | `true` | Select the active slot (used by place, drop, refuel, ...) |
| `turtle.getSelectedSlot()` | `number` | |
| `turtle.getItemCount([slot])` | `number` | Defaults to the selected slot |
| `turtle.getItemSpace([slot])` | `number` | How many more items fit |
| `turtle.getItemDetail([slot [, detailed]])` | `table` or `nil` | `{ name = "minecraft:cobblestone", count = 12 }`. `detailed = true` adds more fields (displayName, tags, ...) |
| `turtle.transferTo(slot [, count])` | `boolean` | Move items from the selected slot into `slot` |
| `turtle.compareTo(slot)` | `boolean` | Whether the selected slot holds the same item as `slot` |

When a stack runs out, scan slots 1-16 for more of the same item, using `getItemDetail(slot).name`.

## Interacting with blocks

Each action has a front, `Up` and `Down` variant: for example `dig`, `digUp` and `digDown`.

| Function | Returns | Notes |
|---|---|---|
| `turtle.detect()` | `boolean` | Is there a solid block in front |
| `turtle.inspect()` | `boolean, table or string` | `true, { name = "minecraft:stone", state = {...}, tags = {...} }`, or `false, "No block to inspect"` |
| `turtle.compare()` | `boolean` | Is the block in front the same as the selected slot's item |
| `turtle.dig([side])` | `boolean, string?` | Break the block in front (needs a pickaxe, axe, shovel or hoe upgrade). `side` picks `"left"` or `"right"` tool |
| `turtle.place([text])` | `boolean, string?` | Place the selected slot's block or item in front. `text` is written on signs |
| `turtle.attack([side])` | `boolean, string?` | Attack the entity in front (needs a sword or other tool) |
| `turtle.drop([count])` | `boolean, string?` | Drop items from the selected slot, into an inventory (a chest) if there is one in front |
| `turtle.suck([count])` | `boolean, string?` | Pick up items from the ground or from an inventory in front |

- A turtle can't place a block in its own space. To build a floor, move one block above the target row and use `placeDown()` after each move.
- Falling blocks such as sand and gravel can refill a hole after `dig()`. Loop `while turtle.detect() do turtle.dig() end` before moving into it.
- Broken blocks go into the turtle's inventory. When the inventory is full they drop on the ground.

## Upgrades

| Function | Returns | Notes |
|---|---|---|
| `turtle.equipLeft()` / `turtle.equipRight()` | `boolean, string?` | Swap the selected slot's item with the upgrade on that side (pickaxe, crafting table, modem, ...) |
| `turtle.craft([limit])` | `boolean, string?` | Craft using the inventory as the grid: the recipe goes in the top-left 3x3 slots (1-3, 5-7, 9-11) and every other slot must be empty. Needs a crafting table upgrade |

Peripherals attached as upgrades (a wireless modem, for example) are used through the `peripheral` API, the same as on computers.

## Example: safe movement with dead reckoning

```lua
local pos = { x = 0, y = 0, z = 0, dir = 0 } -- dir: 0=+z, 1=+x, 2=-z, 3=-x
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }

local function needFuel(n)
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" and level < n then
    error("Need " .. n .. " fuel, have " .. level)
  end
end

local function forward()
  for attempt = 1, 10 do
    if turtle.forward() then
      pos.x = pos.x + DX[pos.dir]
      pos.z = pos.z + DZ[pos.dir]
      return
    end
    if turtle.detect() then
      turtle.dig()
    else
      turtle.attack()
    end
    os.sleep(0.5)
  end
  error("Stuck at " .. pos.x .. "," .. pos.y .. "," .. pos.z)
end

local function turnRight()
  turtle.turnRight()
  pos.dir = (pos.dir + 1) % 4
end

needFuel(20)
for i = 1, 10 do forward() end
turnRight()
print("Now at x=" .. pos.x .. " z=" .. pos.z)
```

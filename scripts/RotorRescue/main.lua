-- Rotor Rescue for ETHOS. ETHOS runs this file at startup to list the game under System.
-- The game itself is in game.lua: it is loaded when the game is opened and dropped when it
-- is closed, so the System tile holds almost no Lua memory while the game is not running.
local ROOT = "SCRIPTS:/RotorRescue/"
local env = { perf = false } -- kept between openings; also tells the game the memory at opening
local game

local function luaFree()
    local usage = system.getMemoryUsage and system.getMemoryUsage()
    return type(usage) == "table" and usage.luaRamAvailable or nil
end

-- title = false hides the ETHOS title bar: the game gets the whole screen and paints faster.
local tool = { name = "Rotor Rescue", title = false }

function tool.create()
    collectgarbage("collect")
    env.heapBefore, env.freeBefore = collectgarbage("count"), luaFree()
    game = game or assert(loadfile(ROOT .. "game.lua"))()
    return game.create(env)
end

function tool.wakeup(g)
    if game then game.wakeup(g) end
end

function tool.paint(g)
    if game then game.paint(g) end
end

function tool.event(g, category, value, x, y)
    if game then return game.event(g, category, value, x, y) end
end

function tool.close()
    game = nil
    collectgarbage("collect")
end

local function init()
    tool.icon = lcd.loadMask(ROOT .. "icon.png", false)
    system.registerSystemTool(tool)
end

return { init = init }

-- Rotor Rescue: a two-axis, fixed-pitch RC helicopter game for ETHOS.
-- main.lua loads this file when the game is opened and drops it when it closes.
local VERSION = "0.7.1"
local ROOT = "SCRIPTS:/RotorRescue/"
local STEP, FRAME, GRAVITY = 1 / 60, 1 / 30, 9.81
-- HUD text refreshes at most this often; a full repaint at least this often while anything moves.
local HUD_PERIOD, FULL_PERIOD = 0.15, 2
local BOARD_TIME, DELIVERY, SCORE_LIMIT = 1.6, 300, 5
local SCORE_FILES = { ROOT .. "scores-a.dat", ROOT .. "scores-b.dat" }
local WIDTH, CEILING, SKID = 76, 30, 0.92
local LIFT_RATIO, MAX_SINK, MAX_SLIDE, MAX_TILT = 1.92, 2.4, 2, 0.24
local PADS = {
    { x = 8, y = 2.8, half = 4.2, name = "BASE" },
    { x = 24, y = 8, half = 3.6, name = "1 / RIDGE", points = 100 },
    { x = 49, y = 14, half = 2.8, name = "2 / LOOKOUT", points = 200 },
    { x = 65, y = 5, half = 2.3, name = "3 / CAMP", points = 300 },
}
local PALETTE = {
    night = { 13, 23, 40 }, sky = { 23, 45, 65 }, haze = { 38, 67, 86 },
    rock = { 24, 52, 60 }, earth = { 21, 38, 45 }, line = { 76, 102, 117 },
    white = { 235, 244, 250 }, dim = { 166, 190, 207 }, red = { 255, 120, 108 },
    amber = { 255, 198, 83 }, green = { 103, 229, 177 }, glass = { 84, 170, 205 },
}

-- Engine sound (tools/make_sounds.py): a seamless loop per rotor speed band, a pitch
-- glide between neighbouring bands, and spool-up / spool-down clips. Each clip is queued
-- just before the previous one ends, so ETHOS plays them back to back.
local SOUND = ROOT .. "sounds/"
local BANDS, LOOP_LENGTH, GLIDE_LENGTH, START_LENGTH, STOP_LENGTH = 10, 0.6, 0.2, 0.4, 0.6
local AUDIO_LEAD, AUDIO_FLOOR, AUDIO_HYSTERESIS = 0.120, 0.16, 0.02
local LOOPS, UPS, DOWNS = {}, {}, {}
for band = 1, BANDS do
    LOOPS[band] = SOUND .. "loop" .. band .. ".wav"
    if band < BANDS then
        UPS[band] = SOUND .. "up" .. band .. ".wav"     -- band -> band + 1
        DOWNS[band] = SOUND .. "down" .. band .. ".wav" -- band + 1 -> band
    end
end
local START_FILE, STOP_FILE = SOUND .. "start.wav", SOUND .. "stop.wav"

local abs, min, max, sin, cos, floor = math.abs, math.min, math.max, math.sin, math.cos, math.floor

local function clamp(v, low, high)
    return max(low, min(high, v))
end

local function missionScore(centis, retries)
    return 600 + DELIVERY + max(0, 600 - floor(centis / 25) - retries * 150)
end

local function better(a, b)
    if a.points ~= b.points then return a.points > b.points end
    if a.centis ~= b.centis then return a.centis < b.centis end
    return a.retries < b.retries
end

local function readScores(path)
    local file = io.open(path, "r")
    if not file then return end
    local data = io.read(file, 512)
    io.close(file)
    if type(data) ~= "string" or #data >= 512 then return end
    local revision, rows, ending = data:match("^RR1 (%d+)\n(.*)END (%d+)\n$")
    if not revision or revision ~= ending or #revision > 9 then return end
    local scores = {}
    for row in rows:gmatch("([^\n]*)\n") do
        local points, centis, retries = row:match("^(%d+) (%d+) (%d+)$")
        if not points or #scores >= SCORE_LIMIT or #centis > 9 or #retries > 6 then return end
        local entry = { points = tonumber(points), centis = tonumber(centis), retries = tonumber(retries) }
        if entry.points ~= missionScore(entry.centis, entry.retries) then return end
        scores[#scores + 1] = entry
    end
    if rows:sub(-1) ~= "\n" then return end
    table.sort(scores, better)
    return scores, tonumber(revision)
end

local function loadScores(g)
    g.scores, g.scoreRevision, g.scoreSlot = {}, 0, 2
    for slot, path in ipairs(SCORE_FILES) do
        local scores, revision = readScores(path)
        if revision and revision > g.scoreRevision then
            g.scores, g.scoreRevision, g.scoreSlot = scores, revision, slot
        end
    end
end

local function recordScore(g, centis)
    local entry = { points = g.score, centis = centis, retries = g.retries }
    local scores = g.scores
    if #scores == SCORE_LIMIT and not better(entry, scores[SCORE_LIMIT]) then return end
    scores[#scores + 1] = entry
    table.sort(scores, better)
    scores[SCORE_LIMIT + 1] = nil
    -- Alternate snapshots so an incomplete write cannot destroy the last valid list.
    local revision, slot = g.scoreRevision + 1, 3 - g.scoreSlot
    local lines = { "RR1 " .. revision }
    for _, score in ipairs(scores) do
        lines[#lines + 1] = string.format("%d %d %d", score.points, score.centis, score.retries)
    end
    lines[#lines + 1] = "END " .. revision .. "\n"
    local file = io.open(SCORE_FILES[slot], "w")
    if file then
        io.write(file, table.concat(lines, "\n"))
        io.close(file)
        local _, saved = readScores(SCORE_FILES[slot])
        if saved == revision then
            g.scoreRevision, g.scoreSlot, g.saveFailed = revision, slot, false
            return
        end
    end
    g.saveFailed = true
end

local function buzz(ms)
    -- Haptic feedback where the radio has a vibration motor; strength follows System settings.
    if system.playHaptic then pcall(system.playHaptic, ms) end
end

local function sticks()
    return system.getSource({ category = CATEGORY_ANALOG, member = ANALOG_STICK_THROTTLE }),
        system.getSource({ category = CATEGORY_ANALOG, member = ANALOG_STICK_AILERON })
end

local function readAxis(source)
    local value = source and source:value()
    if type(value) == "number" and value == value and abs(value) <= 2048 then
        return clamp(value / 1024, -1, 1)
    end
end

local function reset(g, checkpoint)
    if checkpoint then
        g.retries = g.retries + 1
    else
        g.score, g.target, g.time, g.retries, g.started = 0, 2, 0, 0, false
        g.checkpoint, g.cargo = 1, 0
    end
    local pad = PADS[g.checkpoint]
    g.x, g.y, g.vx, g.vy = pad.x, pad.y, 0, 0
    g.tilt, g.rpm, g.rotor, g.support = 0, 0, 0, pad
    g.mode, g.reason, g.crashTitle, g.accum = "ready", nil, nil, 0
    g.last = os.clock()
    g.nextFrame = g.last
    g.feedback, g.feedbackUntil = nil, 0
    g.boarding, g.spotted, g.showScores = nil, nil, false
    g.facing = g.target == 1 and -1 or 1
    g.action, g.guideInk, g.targetHeight, g.guideKey = nil, nil, nil, nil
    g.full, g.nextHud = true, 0
end

local function create(env)
    env = env or {}
    local throttle, cyclic = sticks()
    local version = system.getVersion and system.getVersion()
    local board = type(version) == "table" and version.board
    local buildLabel = type(board) == "string" and board ~= "" and (board .. "  /  " .. VERSION) or VERSION
    local g = { throttle = throttle, cyclic = cyclic, nextLookup = 0, power = 1, stick = 0, mute = false,
        buildLabel = buildLabel, hud = {}, nextFull = 0, paints = 0, paintTime = 0, perfPaints = 0,
        perfTime = 0, perfNext = 0, fps = 0, paintMs = 0, env = env, perf = env.perf or false }
    loadScores(g)
    reset(g)
    return g
end

local function crash(g, reason, title)
    g.mode, g.reason, g.crashTitle = "crashed", reason, title or "HARD LANDING"
    g.vx, g.vy = 0, 0
    buzz(250)
end

local function touchdown(g, pad)
    if g.vy < -MAX_SINK then
        crash(g, string.format("Descent %.1f m/s. Limit %.1f m/s.", -g.vy, MAX_SINK))
    elseif abs(g.vx) > MAX_SLIDE then
        crash(g, string.format("Side speed %.1f m/s. Limit %.1f m/s.", abs(g.vx), MAX_SLIDE))
    elseif abs(g.tilt) > MAX_TILT then
        crash(g, string.format("Tilt %.0f deg. Limit %.0f deg.", math.deg(abs(g.tilt)), math.deg(MAX_TILT)))
    else
        g.support, g.vx, g.vy, g.tilt = pad, 0, 0, 0
        if pad == PADS[g.target] then
            if g.target == 1 then
                local centis = floor(g.time * 100 + 0.5)
                g.score, g.mode = missionScore(centis, g.retries), "won"
                recordScore(g, centis)
                buzz(150)
            else
                g.boarding, g.spotted = 0, true
            end
        end
    end
end

local GROUND = { y = 0 }
local function advance(g, dt)
    local power = g.mode == "flight" and g.power or 0
    -- Rotor speed lags the command. Lift scales with speed squared and tilts with the airframe.
    local demand = math.sqrt(power)
    g.rpm = g.rpm + (demand - g.rpm) * dt / 0.39
    if g.rpm < 0.003 then g.rpm = 0 end
    g.rotor = (g.rotor + g.rpm * dt * 42) % (2 * math.pi)
    if g.mode ~= "flight" then return end
    if g.started then g.time = g.time + dt end

    local lift = GRAVITY * LIFT_RATIO * g.rpm * g.rpm
    if g.support then
        if lift <= GRAVITY * 1.02 then
            if g.boarding then
                g.boarding = g.boarding + dt
                if g.boarding >= BOARD_TIME then
                    local points = g.support.points
                    g.score, g.cargo, g.checkpoint = g.score + points, g.cargo + 2, g.target
                    g.target = g.target < #PADS and g.target + 1 or 1
                    g.boarding, g.spotted = nil, nil
                    g.feedback, g.feedbackUntil = "+" .. points .. "  /  2 ON BOARD", g.time + 2.5
                    buzz(60)
                end
            end
            return
        end
        g.boarding = nil
        g.support = nil
        g.started = true
    end
    local stick = g.stick
    local command = abs(stick) < 0.045 and 0 or stick * (0.64 + 0.36 * abs(stick))
    g.tilt = g.tilt + (command * 0.57 - g.tilt) * dt / 0.22
    local clearance = g.y
    for index = 1, #PADS do
        local pad = PADS[index]
        if abs(g.x - pad.x) <= pad.half and g.y >= pad.y then
            clearance = min(clearance, g.y - pad.y)
        end
    end
    lift = lift * (1 + 0.035 * max(0, 1 - clearance / 1.1))
    g.vx = g.vx + (lift * sin(g.tilt) - 0.24 * g.vx - 0.055 * g.vx * abs(g.vx)) * dt
    g.vy = g.vy + (lift * cos(g.tilt) - GRAVITY - 0.17 * g.vy - 0.046 * g.vy * abs(g.vy)) * dt
    if abs(g.vx) > 0.8 then g.facing = g.vx < 0 and -1 or 1 end

    local oldX, oldY = g.x, g.y
    g.x, g.y = g.x + g.vx * dt, g.y + g.vy * dt
    if g.x < 2 or g.x > WIDTH - 2 then
        g.x = clamp(g.x, 2, WIDTH - 2)
        crash(g, "Outside the flight area", "OUT OF BOUNDS")
        return
    end
    if g.y > CEILING then g.y, g.vy = CEILING, min(0, g.vy) end
    for index = 1, #PADS do
        local pad = PADS[index]
        if oldY >= pad.y and g.y <= pad.y and g.vy < 0 then
            -- Test skid position at the deck crossing instead of at the end of the step.
            local contact = (oldY - pad.y) / (oldY - g.y)
            local x = oldX + (g.x - oldX) * contact
            local offset = abs(x - pad.x)
            if offset <= pad.half + SKID then
                g.x, g.y = x, pad.y
                if offset <= pad.half - SKID then touchdown(g, pad)
                else crash(g, "Skid caught the pad edge", "PLATFORM STRIKE") end
                return
            end
        end
        local reachesDeck = g.y < pad.y and g.y + 1.75 > pad.y - 0.35
        if reachesDeck and abs(g.x - pad.x) < pad.half + 1.15 then
            crash(g, "Hit the platform", "PLATFORM STRIKE")
            return
        end
    end
    if g.y <= 0 then
        g.y = 0
        touchdown(g, GROUND)
    end
end

local function engineBand(g, current)
    local load = (clamp(g.rpm * 0.78 + g.power * 0.22, 0, 1) - 0.12) / 0.88
    if current and load >= (current - 1) / BANDS - AUDIO_HYSTERESIS and load <= current / BANDS + AUDIO_HYSTERESIS then
        return current
    end
    return clamp(floor(load * BANDS) + 1, 1, BANDS)
end

local function audio(g, now)
    local soundEnd = g.soundEnd or 0
    if g.mute or now < soundEnd - AUDIO_LEAD then return end
    -- The band the queued audio ends in; after silence the engine starts from the spool-up clip.
    local band = now <= soundEnd and g.soundBand or nil
    local file, length
    if g.rpm < AUDIO_FLOOR then
        if not band then return end
        -- Wind down one band at a time, then fade out.
        if band > 1 then file, length, band = DOWNS[band - 1], GLIDE_LENGTH, band - 1
        else file, length, band = STOP_FILE, STOP_LENGTH, nil end
    elseif not band then
        file, length, band = START_FILE, START_LENGTH, 1
    else
        local want = engineBand(g, band)
        if want > band then file, length, band = UPS[band], GLIDE_LENGTH, band + 1
        elseif want < band then file, length, band = DOWNS[band - 1], GLIDE_LENGTH, band - 1
        else file, length = LOOPS[band], LOOP_LENGTH end
    end
    -- Queue just before the current clip ends. Rebase after silence instead of catching up.
    g.soundEnd = max(now, soundEnd) + length
    g.soundBand = band
    system.playFile(file)
end

local function updateFlight(g, now)
    g.accum = g.accum + clamp(now - g.last, 0, 0.10)
    g.last = now
    if g.accum < STEP then return end

    if (not g.throttle or not g.cyclic) and now >= g.nextLookup then
        g.throttle, g.cyclic = sticks()
        g.nextLookup = now + 1
    end
    local collective, cyclic = readAxis(g.throttle), readAxis(g.cyclic)
    g.hasInput = collective ~= nil and cyclic ~= nil
    g.power, g.stick = collective and (1 + collective) / 2 or 0, cyclic or 0
    if g.mode == "ready" and g.hasInput and g.power <= 0.07 then g.mode = "flight" end
    if g.mode == "flight" and not g.hasInput then crash(g, "Stick input lost", "FLIGHT INTERRUPTED") end
    while g.accum >= STEP do
        advance(g, STEP)
        g.accum = g.accum - STEP
    end
end

------------------------------------------------------------------------------------------
-- Screen layout, computed once per window size. Without the ETHOS title bar the tool gets
-- the whole 800 x 480 screen; the scenery stretches to the height it is given.

local HILLS = { -- x1, x2, x3 as fractions of the width, rise in px at the reference height, ink
    0, 0.16, 0.34, 144, "haze", 0.17, 0.41, 0.72, 175, "haze",
    0.45, 0.68, 0.93, 135, "haze", 0.65, 0.91, 1, 155, "haze",
    0, 0.10, 0.40, 62, "rock", 0.20, 0.37, 0.65, 83, "rock",
    0.51, 0.72, 0.90, 90, "rock", 0.74, 0.93, 1, 78, "rock",
}
local HEADER, FOOTER, SKY_REFERENCE = 47, 59, 303
local EXIT_W = 46

local function layout(g)
    local w, h = lcd.getWindowSize()
    local lay = g.lay
    if lay and lay.w == w and lay.h == h then return lay end
    local floorY = h - FOOTER
    local vs = (floorY - HEADER) / SKY_REFERENCE
    lay = { w = w, h = h, floorY = floorY, sx = w / WIDTH, sy = (floorY - 78) / CEILING,
        scale = min(w / 800, h / 415), hazeY = floorY - floor(104 * vs + 0.5),
        moonX = floor(w * 0.81), moonY = floor(HEADER + 36 * vs + 0.5), hills = {}, pads = {} }
    lay.heliR = floor(36 * lay.scale + 0.5) + 2
    for i = 1, #HILLS, 5 do
        local x1, x2, x3 = floor(w * HILLS[i]), floor(w * HILLS[i + 1]), floor(w * HILLS[i + 2])
        local top = floorY - floor(HILLS[i + 3] * vs + 0.5)
        local hill = lay.hills
        hill[#hill + 1], hill[#hill + 2], hill[#hill + 3], hill[#hill + 4] = x1, x2, x3, top
        hill[#hill + 1] = HILLS[i + 4]
    end
    for index, pad in ipairs(PADS) do
        local x, y, span = pad.x * lay.sx, floorY - pad.y * lay.sy, pad.half * lay.sx
        local reach = max(span + 26 * lay.scale, 70)
        -- Everything drawn for a pad: deck, braces, label, guide marks and passengers.
        lay.pads[index] = { x = x, y = y, span = span, braceY = min(y + (index == 1 and 9 or 22), floorY),
            labelY = y + (index == 1 and 11 or 24), x0 = x - reach, x1 = x + reach,
            y0 = y - 24 * max(1, lay.scale), y1 = y + (index == 1 and 11 or 24) + 20 }
    end
    -- The Ready / crash / Mission Complete panel covers Lookout fully, whatever the height.
    lay.panelY = floor(h * 0.30)
    lay.panelH = max(148, floor(lay.pads[3].labelY + 22 - lay.panelY))
    lay.panelTop = lay.panelY + floor((lay.panelH - 148) / 2)
    g.lay, g.full = lay, true
    return lay
end

------------------------------------------------------------------------------------------
-- Frame preparation (wakeup): decide what changed and invalidate only that rectangle.
-- A plain lcd.invalidate() makes ETHOS clear the window first; a rectangle does not.

local MODE_KEY = { ready = 1, flight = 2, crashed = 3, won = 4 }
local INK_KEY = { red = 1, amber = 2, green = 3 }

local function approach(g, target)
    local height = g.y - target.y
    local toPad = target.x - g.x
    local offset = abs(toPad)
    local closing = toPad * g.vx > 0 and abs(g.vx) or 0
    local lookAhead = clamp(5 + closing * 1.5, 5, 12)
    if offset > target.half + lookAhead or height > 6 then return nil, "amber", height end
    if height < 0 then
        if offset < target.half + 1.15 then return "CLEAR PAD SIDE", "red", height end
        return "CLIMB", "red", height
    end
    if g.vy < -MAX_SINK then return "REDUCE SINK", "red", height end
    if abs(g.vx) > MAX_SLIDE then return "SLOW SIDEWAYS", "amber", height end
    if offset > target.half - SKID then return "CENTER OVER PAD", "amber", height end
    if abs(g.tilt) > MAX_TILT then return "LEVEL SKIDS", "amber", height end
    if g.vy > 0.35 then return "SETTLE DOWN", "amber", height end
    return "ALIGNED", "green", height
end

local function scoresAvailable(g)
    return not g.started or g.mode == "won" or g.mode == "crashed"
end

local function dirty(g, x0, y0, x1, y1)
    if g.dirty then
        g.dx0, g.dy0, g.dx1, g.dy1 = min(g.dx0, x0), min(g.dy0, y0), max(g.dx1, x1), max(g.dy1, y1)
    else
        g.dirty, g.dx0, g.dy0, g.dx1, g.dy1 = true, x0, y0, x1, y1
    end
end

local function changed(hud, field, value)
    if hud[field] == value then return false end
    hud[field] = value
    return true
end

-- Snapshot every HUD string; report which bar changed.
local function buildHud(g, lay)
    local hud, h = g.hud, lay.h
    local top, bottom = false, false
    local passengers = g.mode == "won" and "DELIVERED" or "ON BOARD"
    if hud.scoreValue ~= g.score or hud.cargoValue ~= g.cargo or hud.passengers ~= passengers then
        hud.scoreValue, hud.cargoValue, hud.passengers = g.score, g.cargo, passengers
        top = changed(hud, "score", string.format("%03d PTS  /  %d %s", g.score, g.cargo, passengers)) or top
    end
    local run = g.retries == 0 and "CLEAN RUN" or string.format("RETRIES %d", g.retries)
    if g.mode == "crashed" then
        run = g.retries == 0 and "RUN INTERRUPTED" or string.format("INTERRUPTED / RETRIES %d", g.retries)
    end
    local second = floor(g.time)
    if hud.second ~= second or hud.run ~= run then
        hud.second, hud.run = second, run
        top = changed(hud, "clock", string.format("%d:%02d   /   %s", floor(second / 60), second % 60, run)) or top
    end
    local percent = floor(g.power * 100 + 0.5)
    if hud.percent ~= percent then
        hud.percent = percent
        top = changed(hud, "power", string.format("%02d%% PWR / 52%% HOVER", percent)) or top
    end
    top = changed(hud, "powerW", max(1, floor(130 * g.power + 0.5))) or top
    top = changed(hud, "title", g.perf and g.perfSpeed or "ROTOR RESCUE") or top
    top = changed(hud, "build", g.perf and g.perfMemory or g.buildLabel) or top

    local target = g.mode ~= "won" and PADS[g.target] or nil
    local objective = not target and "ALL SIX SAFE AT BASE"
        or (g.target == 1 and "RETURN TO BASE" or ("RESCUE  " .. target.name))
    bottom = changed(hud, "objective", objective)
    local center, centerInk, centerY, board = nil, nil, h - 46, nil
    local hint = "Throttle lifts / aileron tilts. Start at about 60% power."
    if not g.support then
        hint = string.format("SIDE %+0.1f   VERTICAL %+0.1f m/s", g.vx, g.vy)
        local height = g.targetHeight
        if g.target == 1 and g.x > PADS[3].x + PADS[3].half and g.y < PADS[3].y + 2.2 then
            center, centerInk = "CLIMB OVER LOOKOUT", "amber"
        elseif height then
            local text = string.format("%.1f m %s TARGET", abs(height), height < 0 and "BELOW" or "ABOVE")
            center, centerInk = g.action or text, g.guideInk
            if g.action then hint = text .. "   /   " .. hint end
        end
        if g.spotted then hint = hint .. "   /   PASSENGERS WAITING" end
    elseif g.mode == "won" then
        hint = "Rescue route complete. Tap Fly Again for a new run."
    elseif g.boarding then
        center, centerInk, centerY = string.format("BOARDING  %.1f s", max(0, BOARD_TIME - g.boarding)), "amber", h - 51
        board = max(1, floor(104 * g.boarding / BOARD_TIME + 0.5))
        hint = "Hold on the pad until both passengers are aboard."
    elseif g.feedback and g.time < g.feedbackUntil then
        center, centerInk = g.feedback, "green"
        hint = g.target == 1 and "Climb over Lookout, then fly left to Base." or "Raise throttle to lift off for the next pad."
    end
    bottom = changed(hud, "center", center or false) or bottom
    bottom = changed(hud, "centerInk", centerInk or false) or bottom
    bottom = changed(hud, "centerY", centerY) or bottom
    bottom = changed(hud, "board", board or false) or bottom
    bottom = changed(hud, "hint", hint) or bottom
    bottom = changed(hud, "sound", g.mute and "SOUND OFF" or "SOUND ON") or bottom
    bottom = changed(hud, "scores", scoresAvailable(g)) or bottom
    return top, bottom
end

local function prepareFrame(g, now)
    local lay = layout(g)
    local key = MODE_KEY[g.mode] + g.target * 8 + g.checkpoint * 64 + (g.spotted and 512 or 0)
        + (g.hasInput and 1024 or 0) + (g.showScores and 2048 or 0)
    if key ~= g.frameKey then g.frameKey, g.full = key, true end

    -- Landing guidance at the target pad.
    local target = g.mode ~= "won" and PADS[g.target] or nil
    local action, ink, height
    if target and g.mode == "flight" and not g.support then action, ink, height = approach(g, target) end
    g.action, g.targetHeight = action, height
    local guide = height and INK_KEY[ink] * 4 + (action == "CLIMB" and (g.x < target.x and 1 or 2) or 0) or 0
    if guide ~= g.guideKey then
        g.guideKey, g.guideInk = guide, ink
        local zone = lay.pads[g.target]
        dirty(g, zone.x0, zone.y0, zone.x1, zone.y1)
    end
    if g.spotted and target and g.target > 1 then
        local zone = lay.pads[g.target]
        dirty(g, zone.x0, zone.y0, zone.x1, zone.y1)
    end

    -- Helicopter, drawn where it is now: the time not yet stepped is carried forward.
    local ahead = g.mode == "flight" and not g.support and g.accum or 0
    local hx = (g.x + g.vx * ahead) * lay.sx
    local hy = lay.floorY - (g.y + g.vy * ahead) * lay.sy - 7 * lay.scale
    local span = 12 + 13 * abs(cos(g.rotor))
    if hx ~= g.hx or hy ~= g.hy or g.tilt ~= g.heliTilt or span ~= g.heliSpan or g.facing ~= g.heliFacing then
        local r = lay.heliR
        if g.hx then dirty(g, g.hx - r, g.hy - r, g.hx + r, g.hy + r) end
        g.hx, g.hy, g.heliTilt, g.heliSpan, g.heliFacing = hx, hy, g.tilt, span, g.facing
        dirty(g, hx - r, hy - r, hx + r, hy + r)
    end

    if g.full or now >= g.nextHud then
        g.nextHud = now + HUD_PERIOD
        local top, bottom = buildHud(g, lay)
        if top then dirty(g, 0, 0, lay.w, HEADER) end
        if bottom then dirty(g, 0, lay.floorY, lay.w, lay.h) end
    end

    if g.dirty and now >= g.nextFull then g.full = true end
    if g.full then
        g.full, g.dirty, g.pending, g.pendingFull = false, false, true, true
        g.nextFull = now + FULL_PERIOD
        lcd.invalidate(0, 0, lay.w, lay.h)
    elseif g.dirty then
        g.dirty = false
        local x0, y0 = max(0, floor(g.dx0) - 2), max(0, floor(g.dy0) - 2)
        local x1, y1 = min(lay.w, floor(g.dx1) + 3), min(lay.h, floor(g.dy1) + 3)
        if x1 <= x0 or y1 <= y0 then return end
        -- Rectangles waiting for the same paint are merged.
        if g.pending then
            x0, y0, x1, y1 = min(x0, g.px0), min(y0, g.py0), max(x1, g.px1), max(y1, g.py1)
        end
        g.pending, g.px0, g.py0, g.px1, g.py1 = true, x0, y0, x1, y1
        lcd.invalidate(x0, y0, x1 - x0, y1 - y0)
    end
end

local function wakeup(g)
    local now = os.clock()
    if now >= g.perfNext then
        -- Performance readout, once a second: paints per second, mean paint time, and the Lua
        -- memory left now and when the game was opened (from main.lua).
        local span, paints = now - (g.perfAt or now), g.paints - g.perfPaints
        g.fps = span > 0 and floor(paints / span + 0.5) or 0
        g.paintMs = paints > 0 and (g.paintTime - g.perfTime) * 1000 / paints or 0
        g.perfPaints, g.perfTime, g.perfAt, g.perfNext = g.paints, g.paintTime, now, now + 1
        if g.perf then
            local env = g.env
            local usage = system.getMemoryUsage and system.getMemoryUsage()
            local free = type(usage) == "table" and usage.luaRamAvailable
            g.perfSpeed = string.format("%d FPS  /  PAINT %.1f MS", g.fps, g.paintMs)
            if free and env.freeBefore then
                g.perfMemory = string.format("FREE %d KB  /  AT OPEN %d KB", free // 1024, env.freeBefore // 1024)
            else
                g.perfMemory = string.format("LUA %d KB  /  AT OPEN %d KB", floor(collectgarbage("count")),
                    floor(env.heapBefore or 0))
            end
        end
    end
    if g.showScores then
        g.last = now
        if g.full then prepareFrame(g, now) end
        return
    end

    updateFlight(g, now)
    audio(g, now)
    if system.resetBacklightTimeout and now >= (g.nextBacklight or 0) then
        system.resetBacklightTimeout()
        g.nextBacklight = now + 1
    end

    if now < g.nextFrame then return end
    -- Keep the frame phase through small delays and skip frames after a stall.
    g.nextFrame = max(g.nextFrame + FRAME, now + FRAME / 2)
    prepareFrame(g, now)
end

------------------------------------------------------------------------------------------
-- Painting. Each element is skipped when it lies outside the rectangle being repainted.

local paintColor, paintFont
local cx0, cy0, cx1, cy1 = 0, 0, 0, 0

local function visible(x0, y0, x1, y1)
    return x1 >= cx0 and x0 <= cx1 and y1 >= cy0 and y0 <= cy1
end

local function color(key)
    if key ~= paintColor then
        lcd.color(PALETTE[key])
        paintColor = key
    end
end

local function label(x, y, value, font, ink, flags)
    color(ink)
    if font ~= paintFont then
        lcd.font(font)
        paintFont = font
    end
    lcd.drawText(floor(x + 0.5), floor(y + 0.5), value, flags or 0)
end

local function box(x, y, w, h, ink)
    color(ink)
    lcd.drawFilledRectangle(floor(x + 0.5), floor(y + 0.5), floor(w + 0.5), floor(h + 0.5))
end

local function line(x, y, x2, y2, ink)
    color(ink)
    lcd.drawLine(floor(x + 0.5), floor(y + 0.5), floor(x2 + 0.5), floor(y2 + 0.5))
end

local function paintScenery(lay)
    local w, h, floorY = lay.w, lay.h, lay.floorY
    box(0, 0, w, h, "sky")
    if visible(0, lay.hazeY, w, floorY) then box(0, lay.hazeY, w, floorY - lay.hazeY, "haze") end
    if visible(lay.moonX - 22, lay.moonY - 22, lay.moonX + 22, lay.moonY + 22) then
        color("haze")
        lcd.drawFilledCircle(lay.moonX, lay.moonY, 22)
    end
    local hills = lay.hills
    for i = 1, #hills, 5 do
        local x1, x2, x3, top = hills[i], hills[i + 1], hills[i + 2], hills[i + 3]
        if visible(x1, top, x3, floorY) then
            color(hills[i + 4])
            lcd.drawFilledTriangle(x1, floorY, x2, top, x3, floorY)
        end
    end
    if visible(0, floorY, w, h) then
        box(0, floorY, w, h - floorY, "earth")
        line(0, floorY, w - 1, floorY, "line")
    end
end

-- The helicopter in sprite units (x forward, y down), rotated by the tilt when drawn.
local HELI_BACK = { -- x1, y1, x2, y2: tail boom, then fin and tail rotor
    -17, -2, -31, -9, -17, -3, -30, -10, -30, -15, -30, -5, -33, -10, -27, -10 }
local HELI_BACK_INK = { "amber", "amber", "white", "white" }
local HELI_BODY = { -- filled triangles: fuselage, then the canopy
    -19.5, -3, -15.5, -8.5, 7.5, -8.5, -19.5, -3, 7.5, -8.5, 11.5, -3,
    -19.5, -3, 11.5, -3, 8.3, 1.5, -19.5, -3, 8.3, 1.5, -16.3, 1.5,
    0.5, -7.5, 7.5, -7.5, 9.5, -5, 0.5, -7.5, 9.5, -5, 6.5, -1.5,
    0.5, -7.5, 6.5, -1.5, 0.5, -1.5 }
local HELI_FRONT = { -- mast, skid struts and skid; the main rotor is added when drawn
    -3, -8, -3, -15, -10, 1, -12, 7, 3, 1, 5, 7, -16, 7, 10, 7 }

local function paintHeli(g, lay)
    local x, y, r = g.hx, g.hy, lay.heliR
    if not x or not visible(x - r, y - r, x + r, y + r) then return end
    local scale, facing = lay.scale, g.heliFacing
    local c, s = cos(g.heliTilt) * scale, sin(g.heliTilt) * scale
    local fc, fs = c * facing, s * facing
    local drawLine = lcd.drawLine
    for i = 1, #HELI_BACK, 4 do
        local ax, ay, bx, by = HELI_BACK[i], HELI_BACK[i + 1], HELI_BACK[i + 2], HELI_BACK[i + 3]
        color(HELI_BACK_INK[(i + 3) // 4])
        drawLine(floor(x + ax * fc - ay * s + 0.5), floor(y + ax * fs + ay * c + 0.5),
            floor(x + bx * fc - by * s + 0.5), floor(y + bx * fs + by * c + 0.5))
    end
    local drawTriangle = lcd.drawFilledTriangle
    for i = 1, #HELI_BODY, 6 do
        color(i < 25 and "amber" or "glass")
        local ax, ay, bx, by, qx, qy = HELI_BODY[i], HELI_BODY[i + 1], HELI_BODY[i + 2], HELI_BODY[i + 3],
            HELI_BODY[i + 4], HELI_BODY[i + 5]
        drawTriangle(floor(x + ax * fc - ay * s + 0.5), floor(y + ax * fs + ay * c + 0.5),
            floor(x + bx * fc - by * s + 0.5), floor(y + bx * fs + by * c + 0.5),
            floor(x + qx * fc - qy * s + 0.5), floor(y + qx * fs + qy * c + 0.5))
    end
    color("white")
    for i = 1, #HELI_FRONT, 4 do
        local ax, ay, bx, by = HELI_FRONT[i], HELI_FRONT[i + 1], HELI_FRONT[i + 2], HELI_FRONT[i + 3]
        drawLine(floor(x + ax * fc - ay * s + 0.5), floor(y + ax * fs + ay * c + 0.5),
            floor(x + bx * fc - by * s + 0.5), floor(y + bx * fs + by * c + 0.5))
    end
    local span = g.heliSpan
    local ax, bx = -3 - span, span - 3
    drawLine(floor(x + ax * fc + 15 * s + 0.5), floor(y + ax * fs - 15 * c + 0.5),
        floor(x + bx * fc + 15 * s + 0.5), floor(y + bx * fs - 15 * c + 0.5))
end

local function paintPeople(g, pad, sx, y, scale)
    local progress = g.boarding and min(1, g.boarding / BOARD_TIME) or 0
    for side = -1, 1, 2 do
        local ledge = (pad.x + side * pad.half) * sx + side * 14 * scale
        local step = max(0, (progress - 0.18) / 0.82)
        local door = g.x * sx + side * 7 * scale
        local x = ledge + (door - ledge) * step
        local feet = y + (6 - 9 * step) * scale
        local walk = step > 0 and sin(progress * 34) * 2 or 0
        local arm = step == 0 and sin(g.time * 9 + side) * 3 or walk
        box(ledge - 7 * scale, y + 6 * scale, 14 * scale, 2, "line")
        color("white")
        lcd.drawFilledCircle(floor(x + 0.5), floor(feet - 14 * scale + 0.5), max(1, floor(2.5 * scale)))
        line(x, feet - 11 * scale, x, feet - 5 * scale, "amber")
        line(x, feet - 10 * scale, x + side * 5 * scale, feet + (arm - 12) * scale, "white")
        line(x, feet - 10 * scale, x - side * 4 * scale, feet - 7 * scale, "white")
        line(x, feet - 5 * scale, x - (2 + walk) * scale, feet, "dim")
        line(x, feet - 5 * scale, x + (2 + walk) * scale, feet, "dim")
    end
end

local function paintPads(g, lay)
    local target = g.mode ~= "won" and PADS[g.target] or nil
    for index = 1, #PADS do
        local pad, p = PADS[index], lay.pads[index]
        if visible(p.x0, p.y0, p.x1, p.y1) then
            local x, y, span = p.x, p.y, p.span
            local ink = pad == target and "amber" or (index <= g.checkpoint and "green" or "dim")
            line(x - span * 0.82, y + 4, x - span * 0.49, p.braceY, "line")
            line(x + span * 0.82, y + 4, x + span * 0.49, p.braceY, "line")
            line(x - span * 0.49, p.braceY, x + span * 0.49, p.braceY, "line")
            box(x - span, y, span * 2, 4, ink)
            box(x - span, y - 4, 3, 5, ink)
            box(x + span - 3, y - 4, 3, 5, ink)
            label(x, p.labelY, pad.name, FONT_XS, ink, CENTERED)
            if pad == target and index > 1 and g.spotted then paintPeople(g, pad, lay.sx, y, lay.scale) end
            if pad == target and g.targetHeight then
                local guideInk = g.guideInk
                local inner = (pad.half - SKID) * lay.sx
                local guideY = y - 20
                line(x - inner, y - 4, x - inner, guideY, guideInk)
                line(x + inner, y - 4, x + inner, guideY, guideInk)
                line(x - inner, guideY, x - inner + 5, guideY, guideInk)
                line(x + inner - 5, guideY, x + inner, guideY, guideInk)
                line(x - span - 12, y, x - span - 4, y, guideInk)
                line(x + span + 4, y, x + span + 12, y, guideInk)
                if g.action == "CLIMB" then
                    local arrow = x + (g.guideKey % 4 == 1 and -1 or 1) * (span + 17)
                    line(arrow, y + 3, arrow, y - 14, "red")
                    line(arrow - 5, y - 9, arrow, y - 14, "red")
                    line(arrow, y - 14, arrow + 5, y - 9, "red")
                end
            end
        end
    end
end

local function paintHud(g, lay)
    local hud, w, h = g.hud, lay.w, lay.h
    if visible(0, 0, w, HEADER) then
        box(0, 0, w, HEADER, "night")
        -- Exit button: the title bar and its back arrow are hidden in full screen.
        box(8, 7, EXIT_W - 14, 33, "rock")
        line(29, 15, 20, 23, "white")
        line(20, 23, 29, 31, "white")
        line(30, 15, 21, 23, "white")
        line(21, 23, 30, 31, "white")
        if g.perf then
            label(EXIT_W + 7, 8, hud.title, FONT_XS, "green")
        else
            label(EXIT_W + 6, 6, hud.title, FONT_STD, "white")
        end
        label(EXIT_W + 7, 28, hud.build, FONT_XS, g.perf and "green" or "dim")
        label(w * 0.5, 5, hud.score, FONT_STD, "amber", CENTERED)
        label(w / 2, 29, hud.clock, FONT_XS, "dim", CENTERED)
        local powerX = w - 145
        box(powerX, 29, 130, 4, "line")
        box(powerX, 29, hud.powerW, 4, "green")
        box(powerX + 130 / LIFT_RATIO, 26, 2, 10, "amber")
        label(w - 15, 7, hud.power, FONT_XS, "white", RIGHT)
    end
    if visible(0, lay.floorY, w, h) then
        label(15, h - 44, hud.objective, FONT_S, "white")
        if hud.center then label(w / 2, hud.centerY, hud.center, FONT_S, hud.centerInk, CENTERED) end
        if hud.board then
            box(w / 2 - 52, h - 27, 104, 4, "line")
            box(w / 2 - 52, h - 27, hud.board, 4, "green")
        end
        label(15, h - 22, hud.hint, FONT_XS, "dim")
        label(w - 15, h - 35, hud.sound, FONT_S, "dim", RIGHT)
        if hud.scores then label(w - 149, h - 35, "TOP SCORES", FONT_S, "amber", RIGHT) end
    end
end

local function paintScores(g, w, h)
    local y = h * 0.19
    box(w * 0.20, y, w * 0.60, 245, "night")
    label(w / 2, y + 12, "LOCAL TOP 5", FONT_L, "amber", CENTERED)
    label(w * 0.31, y + 46, "POINTS", FONT_XS, "dim")
    label(w * 0.53, y + 46, "FLIGHT TIME", FONT_XS, "dim", CENTERED)
    label(w * 0.69, y + 46, "RETRIES", FONT_XS, "dim", CENTERED)
    if #g.scores == 0 then
        label(w / 2, y + 101, "Bring all six passengers back to Base.", FONT_S, "white", CENTERED)
    end
    for rank, entry in ipairs(g.scores) do
        local rowY = y + 49 + 24 * rank
        local ink = rank == 1 and "amber" or "white"
        label(w * 0.31, rowY, string.format("%d.  %d", rank, entry.points), FONT_S, ink)
        label(w * 0.53, rowY, string.format("%d:%05.2f", floor(entry.centis / 6000), entry.centis % 6000 / 100), FONT_S, ink, CENTERED)
        label(w * 0.69, rowY, tostring(entry.retries), FONT_S, ink, CENTERED)
    end
    if g.saveFailed then label(w / 2, y + 190, "Score storage unavailable", FONT_XS, "red", CENTERED) end
    box(w * 0.40, y + 207, w * 0.20, 28, "amber")
    label(w / 2, y + 212, "CLOSE", FONT_S, "night", CENTERED)
end

local function paintPanel(g, lay)
    local w, y = lay.w, lay.panelTop
    if not visible(w * 0.17, lay.panelY, w * 0.83, lay.panelY + lay.panelH) then return end
    box(w * 0.17, lay.panelY, w * 0.66, lay.panelH, "night")
    local readyTitle = g.checkpoint > 1 and "READY AT CHECKPOINT" or "READY ON THE BASE"
    local title = g.mode == "ready" and readyTitle or (g.mode == "won" and "MISSION COMPLETE" or g.crashTitle)
    label(w / 2, y + 14, title, FONT_L, g.mode == "crashed" and "red" or "amber", CENTERED)
    local hint = g.hasInput and "Lower throttle to arm. Aileron tilts the rotor." or "Waiting for throttle and aileron inputs"
    if g.mode == "crashed" then hint = g.reason
    elseif g.mode == "won" then hint = string.format("6 delivered  /  %d points  /  %.1fs", g.score, g.time) end
    label(w / 2, y + 63, hint, FONT_S, "white", CENTERED)
    if g.mode == "crashed" then
        box(w * 0.25, y + 94, w * 0.24, 36, "amber")
        label(w * 0.37, y + 103, g.checkpoint > 1 and "RETRY CHECKPOINT" or "RETRY FROM BASE", FONT_S, "night", CENTERED)
        box(w * 0.51, y + 94, w * 0.24, 36, "rock")
        label(w * 0.63, y + 103, "NEW RUN", FONT_S, "white", CENTERED)
    elseif g.mode == "won" then
        box(w * 0.37, y + 94, w * 0.26, 36, "amber")
        label(w / 2, y + 103, "FLY AGAIN", FONT_S, "night", CENTERED)
    end
end

local function paint(g)
    local started = g.perf and os.clock()
    paintColor, paintFont = nil, nil
    local lay = layout(g)
    local w, h = lay.w, lay.h
    -- Repaint only the rectangle wakeup invalidated. A paint ETHOS asks for by itself, or a
    -- new window size, draws everything.
    local partial = g.pending and not g.pendingFull and not g.full
    if partial then
        cx0, cy0, cx1, cy1 = g.px0, g.py0, g.px1, g.py1
        lcd.setClipping(cx0, cy0, cx1 - cx0, cy1 - cy0)
    else
        cx0, cy0, cx1, cy1 = 0, 0, w, h
    end
    g.pending, g.pendingFull = false, false
    if not g.hud.clock then buildHud(g, lay) end

    paintScenery(lay)
    paintPads(g, lay)
    paintHeli(g, lay)
    paintHud(g, lay)
    if g.showScores then
        paintScores(g, w, h)
    elseif g.mode ~= "flight" then
        paintPanel(g, lay)
    end

    if partial then lcd.setClipping(0, 0, w, h) end
    g.paints = g.paints + 1
    if started then g.paintTime = g.paintTime + os.clock() - started end
end

local function event(g, category, value, x, y)
    local finished = g.mode == "won" or g.mode == "crashed"
    local enter = (category == EVT_KEY and KEY_ENTER_BREAK ~= nil and value == KEY_ENTER_BREAK)
        or (EVT_VIRTUAL ~= nil and category == EVT_VIRTUAL and EVT_VIRTUAL_ENTER ~= nil and value == EVT_VIRTUAL_ENTER)
    if enter and g.showScores then
        g.showScores, g.full = false, true
        return true
    end
    if enter and finished then
        reset(g, g.mode == "crashed")
        return true
    end
    if category == EVT_TOUCH and value == TOUCH_END and x and y then
        local w, h = lcd.getWindowSize()
        if y < HEADER and x < EXIT_W then
            system.exit()
            return true
        end
        if y < HEADER and x < EXIT_W + 200 then
            -- Tap the title to show frames per second, paint time and Lua memory.
            g.perf, g.full, g.perfNext = not g.perf, true, 0
            g.env.perf = g.perf
            return true
        end
        if g.showScores then
            local buttonY = h * 0.19 + 207
            if x >= w * 0.40 and x <= w * 0.60 and y >= buttonY and y <= buttonY + 28 then
                g.showScores, g.full = false, true
            end
            return true
        end
        if scoresAvailable(g) and y >= h - 48 and x >= w - 253 and x < w - 142 then
            if not g.started and g.mode == "flight" then g.mode = "ready" end
            g.showScores, g.full = true, true
            return true
        end
        local panelTop = layout(g).panelTop
        if finished and y >= panelTop + 94 and y <= panelTop + 130 then
            local retry = g.mode == "crashed" and x >= w * 0.25 and x <= w * 0.49
            local restart = (g.mode == "crashed" and x >= w * 0.51 and x <= w * 0.75)
                or (g.mode == "won" and x >= w * 0.37 and x <= w * 0.63)
            if retry or restart then
                reset(g, retry)
                return true
            end
        end
        if y >= h - 48 and x >= w - 142 then
            g.mute, g.full = not g.mute, true
            return true
        end
    end
end

for key, rgb in pairs(PALETTE) do PALETTE[key] = lcd.RGB(rgb[1], rgb[2], rgb[3]) end

return { create = create, wakeup = wakeup, paint = paint, event = event }

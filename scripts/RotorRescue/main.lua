-- Rotor Rescue: a two-axis, fixed-pitch RC helicopter game for ETHOS.
local VERSION = "0.6.4"
local ROOT = "SCRIPTS:/RotorRescue/"
local STEP, FRAME, GRAVITY = 1 / 60, 1 / 30, 9.81
local AUDIO_LENGTH, AUDIO_LEAD, AUDIO_SHIFT = 0.750, 0.120, 0.200
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
local SOUNDS = { "rotor1.wav", "rotor2.wav", "rotor3.wav", "rotor4.wav", "rotor5.wav" }
local PALETTE = {
    night = { 13, 23, 40 }, sky = { 23, 45, 65 }, haze = { 38, 67, 86 },
    rock = { 24, 52, 60 }, earth = { 21, 38, 45 }, line = { 76, 102, 117 },
    white = { 235, 244, 250 }, dim = { 166, 190, 207 }, red = { 255, 120, 108 },
    amber = { 255, 198, 83 }, green = { 103, 229, 177 }, glass = { 84, 170, 205 },
}

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
end

local function create()
    local throttle, cyclic = sticks()
    local version = system.getVersion and system.getVersion()
    local board = type(version) == "table" and version.board
    local buildLabel = type(board) == "string" and board ~= "" and (board .. "  /  " .. VERSION) or VERSION
    local g = { throttle = throttle, cyclic = cyclic, nextLookup = 0, power = 1, stick = 0, mute = false,
        buildLabel = buildLabel }
    loadScores(g)
    reset(g)
    return g
end

local function crash(g, reason, title)
    g.mode, g.reason, g.crashTitle = "crashed", reason, title or "HARD LANDING"
    g.vx, g.vy = 0, 0
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
    for _, pad in ipairs(PADS) do
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
    for _, pad in ipairs(PADS) do
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

local function audio(g, now)
    if g.mute or g.rpm < 0.16 or now < (g.soundEnd or 0) - AUDIO_LEAD then return end
    local load = clamp(g.rpm * 0.78 + g.power * 0.22, 0, 1)
    local band = clamp(floor(load * 5) + 1, 1, 5)
    local previous = g.soundEnd and now <= g.soundEnd and g.soundBand
    if previous and load >= (previous - 1) / 5 - 0.025 and load <= previous / 5 + 0.025 then
        band = previous
    end
    local file, length = SOUNDS[band], AUDIO_LENGTH
    if previous and previous ~= band then
        file, length = string.format("shift%d%d.wav", previous, band), AUDIO_SHIFT
    end
    -- Queue just before the current clip ends. Rebase after silence instead of catching up.
    g.soundEnd = max(now, g.soundEnd or now) + length
    g.soundBand = band
    system.playFile(ROOT .. file)
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

local function wakeup(g)
    local now = os.clock()
    if g.showScores then g.last = now; return end

    updateFlight(g, now)
    audio(g, now)
    if system.resetBacklightTimeout and now >= (g.nextBacklight or 0) then
        system.resetBacklightTimeout()
        g.nextBacklight = now + 1
    end

    if now < g.nextFrame then return end
    -- Keep the frame phase through small delays and skip frames after a stall.
    g.nextFrame = max(g.nextFrame + FRAME, now + FRAME / 2)
    local displayedPower = floor(g.power * 100 + 0.5)
    local feedbackVisible = g.time < g.feedbackUntil
    local clockSecond = floor(g.time)
    local activeFrame = g.rpm > 0.015 or (g.mode == "flight" and (not g.support or g.boarding))
    if activeFrame or displayedPower ~= g.displayedPower or g.mode ~= g.displayedMode
        or g.hasInput ~= g.displayedInput or feedbackVisible ~= g.displayedFeedback
        or clockSecond ~= g.displayedSecond or g.cargo ~= g.displayedCargo then
        g.displayedPower, g.displayedMode = displayedPower, g.mode
        g.displayedInput, g.displayedFeedback = g.hasInput, feedbackVisible
        g.displayedSecond, g.displayedCargo = clockSecond, g.cargo
        lcd.invalidate()
    end
end

local paintColor
local function color(key)
    if key ~= paintColor then
        lcd.color(PALETTE[key])
        paintColor = key
    end
end

local function label(x, y, value, font, ink, flags)
    color(ink)
    lcd.font(font)
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

local function hill(w, y, x1, x2, x3, rise, ink)
    color(ink)
    lcd.drawFilledTriangle(floor(w * x1), y, floor(w * x2), y - rise, floor(w * x3), y)
end

local function paintScenery(w, h, floorY)
    box(0, 0, w, h, "sky")
    box(0, floorY - 104, w, 104, "haze")
    color("haze")
    lcd.drawFilledCircle(floor(w * 0.81), 83, 22)
    hill(w, floorY, 0, 0.16, 0.34, 144, "haze")
    hill(w, floorY, 0.17, 0.41, 0.72, 175, "haze")
    hill(w, floorY, 0.45, 0.68, 0.93, 135, "haze")
    hill(w, floorY, 0.65, 0.91, 1, 155, "haze")
    hill(w, floorY, 0, 0.10, 0.40, 62, "rock")
    hill(w, floorY, 0.20, 0.37, 0.65, 83, "rock")
    hill(w, floorY, 0.51, 0.72, 0.90, 90, "rock")
    hill(w, floorY, 0.74, 0.93, 1, 78, "rock")
    box(0, floorY, w, h - floorY, "earth")
    line(0, floorY, w - 1, floorY, "line")
end

local function paintHeli(g, x, y, scale)
    local c, s = cos(g.tilt), sin(g.tilt)
    local function segment(ax, ay, bx, by, ink)
        ax, bx = ax * g.facing, bx * g.facing
        line(x + scale * (ax * c - ay * s), y + scale * (ax * s + ay * c),
            x + scale * (bx * c - by * s), y + scale * (bx * s + by * c), ink)
    end
    segment(-17, -2, -31, -9, "amber")
    segment(-17, -3, -30, -10, "amber")
    segment(-30, -15, -30, -5, "white")
    segment(-33, -10, -27, -10, "white")
    for row = -8, 1 do
        local inset = abs(row + 3) * 0.8
        segment(-19 + inset, row, 11 - inset, row, "amber")
    end
    for row = -7, -2 do segment(1, row, 9 - abs(row + 5), row, "glass") end
    segment(-3, -8, -3, -15, "white")
    local span = 12 + 13 * abs(cos(g.rotor))
    segment(-3 - span, -15, span - 3, -15, "white")
    segment(-10, 1, -12, 7, "white")
    segment(3, 1, 5, 7, "white")
    segment(-16, 7, 10, 7, "white")
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

local function scoresAvailable(g)
    return not g.started or g.mode == "won" or g.mode == "crashed"
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

local function paint(g)
    paintColor = nil
    local w, h = lcd.getWindowSize()
    local floorY = h - 59
    local sx, sy = w / WIDTH, (floorY - 78) / CEILING
    local scale = min(w / 800, h / 415)
    paintScenery(w, h, floorY)
    local target = g.mode ~= "won" and PADS[g.target] or nil
    local action, guideInk, targetHeight
    if target and g.mode == "flight" and not g.support then action, guideInk, targetHeight = approach(g, target) end
    for index, pad in ipairs(PADS) do
        local x, y, span = pad.x * sx, floorY - pad.y * sy, pad.half * sx
        local ink = pad == target and "amber" or (index <= g.checkpoint and "green" or "dim")
        local braceY = min(y + (index == 1 and 9 or 22), floorY)
        line(x - span * 0.82, y + 4, x - span * 0.49, braceY, "line")
        line(x + span * 0.82, y + 4, x + span * 0.49, braceY, "line")
        line(x - span * 0.49, braceY, x + span * 0.49, braceY, "line")
        box(x - span, y, span * 2, 4, ink)
        box(x - span, y - 4, 3, 5, ink)
        box(x + span - 3, y - 4, 3, 5, ink)
        label(x, y + (index == 1 and 11 or 24), pad.name, FONT_XS, ink, CENTERED)
        if pad == target and index > 1 and g.spotted then paintPeople(g, pad, sx, y, scale) end
        if pad == target and targetHeight then
            local inner = (pad.half - SKID) * sx
            local guideY = y - 20
            line(x - inner, y - 4, x - inner, guideY, guideInk)
            line(x + inner, y - 4, x + inner, guideY, guideInk)
            line(x - inner, guideY, x - inner + 5, guideY, guideInk)
            line(x + inner - 5, guideY, x + inner, guideY, guideInk)
            line(x - span - 12, y, x - span - 4, y, guideInk)
            line(x + span + 4, y, x + span + 12, y, guideInk)
            if action == "CLIMB" then
                local arrow = x + (g.x < pad.x and -1 or 1) * (span + 17)
                line(arrow, y + 3, arrow, y - 14, "red")
                line(arrow - 5, y - 9, arrow, y - 14, "red")
                line(arrow, y - 14, arrow + 5, y - 9, "red")
            end
        end
    end
    paintHeli(g, g.x * sx, floorY - g.y * sy - 7 * scale, scale)

    box(0, 0, w, 47, "night")
    label(15, 6, "ROTOR RESCUE", FONT_STD, "white")
    label(16, 28, g.buildLabel, FONT_XS, "dim")
    local passengers = g.mode == "won" and "DELIVERED" or "ON BOARD"
    label(w * 0.5, 5, string.format("%03d PTS  /  %d %s", g.score, g.cargo, passengers), FONT_STD, "amber", CENTERED)
    local run = g.retries == 0 and "CLEAN RUN" or string.format("RETRIES %d", g.retries)
    if g.mode == "crashed" then
        run = g.retries == 0 and "RUN INTERRUPTED" or string.format("INTERRUPTED / RETRIES %d", g.retries)
    end
    label(w / 2, 29, string.format("%d:%02d   /   %s", floor(g.time / 60), floor(g.time) % 60, run), FONT_XS, "dim", CENTERED)
    local powerX = w - 145
    box(powerX, 29, 130, 4, "line")
    box(powerX, 29, max(1, 130 * g.power), 4, "green")
    box(powerX + 130 / LIFT_RATIO, 26, 2, 10, "amber")
    label(w - 15, 7, string.format("%02d%% PWR / 52%% HOVER", floor(g.power * 100 + 0.5)), FONT_XS, "white", RIGHT)
    local objective = g.target == 1 and "RETURN TO BASE" or ("RESCUE  " .. PADS[g.target].name)
    label(15, h - 44, target and objective or "ALL SIX SAFE AT BASE", FONT_S, "white")
    local hint = "Throttle lifts / aileron tilts. Start at about 60% power."
    if not g.support then
        hint = string.format("SIDE %+0.1f   VERTICAL %+0.1f m/s", g.vx, g.vy)
        if g.target == 1 and g.x > PADS[3].x + PADS[3].half and g.y < PADS[3].y + 2.2 then
            label(w / 2, h - 46, "CLIMB OVER LOOKOUT", FONT_S, "amber", CENTERED)
        elseif targetHeight then
            local height = string.format("%.1f m %s TARGET", abs(targetHeight), targetHeight < 0 and "BELOW" or "ABOVE")
            label(w / 2, h - 46, action or height, FONT_S, guideInk, CENTERED)
            if action then hint = height .. "   /   " .. hint end
        end
        if g.spotted then hint = hint .. "   /   PASSENGERS WAITING" end
    elseif g.mode == "won" then
        hint = "Rescue route complete. Tap Fly Again for a new run."
    elseif g.boarding then
        label(w / 2, h - 51, string.format("BOARDING  %.1f s", max(0, BOARD_TIME - g.boarding)), FONT_S, "amber", CENTERED)
        box(w / 2 - 52, h - 27, 104, 4, "line")
        box(w / 2 - 52, h - 27, max(1, 104 * g.boarding / BOARD_TIME), 4, "green")
        hint = "Hold on the pad until both passengers are aboard."
    elseif g.feedback and g.time < g.feedbackUntil then
        label(w / 2, h - 46, g.feedback, FONT_S, "green", CENTERED)
        hint = g.target == 1 and "Climb over Lookout, then fly left to Base." or "Raise throttle to lift off for the next pad."
    end
    label(15, h - 22, hint, FONT_XS, "dim")
    label(w - 15, h - 35, g.mute and "SOUND OFF" or "SOUND ON", FONT_S, "dim", RIGHT)
    if scoresAvailable(g) then label(w - 149, h - 35, "TOP SCORES", FONT_S, "amber", RIGHT) end

    if g.showScores then
        paintScores(g, w, h)
        return
    end

    if g.mode ~= "flight" then
        local y = h * 0.30
        box(w * 0.17, y, w * 0.66, 148, "night")
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
end

local function event(g, category, value, x, y)
    local finished = g.mode == "won" or g.mode == "crashed"
    local enter = (category == EVT_KEY and KEY_ENTER_BREAK ~= nil and value == KEY_ENTER_BREAK)
        or (EVT_VIRTUAL ~= nil and category == EVT_VIRTUAL and EVT_VIRTUAL_ENTER ~= nil and value == EVT_VIRTUAL_ENTER)
    if enter and g.showScores then
        g.showScores = false
        lcd.invalidate()
        return true
    end
    if enter and finished then
        reset(g, g.mode == "crashed")
        lcd.invalidate()
        return true
    end
    if category == EVT_TOUCH and value == TOUCH_END and x and y then
        local w, h = lcd.getWindowSize()
        if g.showScores then
            local buttonY = h * 0.19 + 207
            if x >= w * 0.40 and x <= w * 0.60 and y >= buttonY and y <= buttonY + 28 then
                g.showScores = false
                lcd.invalidate()
            end
            return true
        end
        if scoresAvailable(g) and y >= h - 48 and x >= w - 253 and x < w - 142 then
            if not g.started and g.mode == "flight" then g.mode = "ready" end
            g.showScores = true
            lcd.invalidate()
            return true
        end
        if finished and y >= h * 0.30 + 94 and y <= h * 0.30 + 130 then
            local retry = g.mode == "crashed" and x >= w * 0.25 and x <= w * 0.49
            local restart = (g.mode == "crashed" and x >= w * 0.51 and x <= w * 0.75)
                or (g.mode == "won" and x >= w * 0.37 and x <= w * 0.63)
            if retry or restart then
                reset(g, retry)
                lcd.invalidate()
                return true
            end
        end
        if y >= h - 48 and x >= w - 142 then
            g.mute = not g.mute
            lcd.invalidate()
            return true
        end
    end
end

local function init()
    for key, rgb in pairs(PALETTE) do PALETTE[key] = lcd.RGB(rgb[1], rgb[2], rgb[3]) end
    local icon = lcd.loadMask(ROOT .. "icon.png", false)
    system.registerSystemTool({ name = "Rotor Rescue", icon = icon, create = create,
        wakeup = wakeup, paint = paint, event = event })
end

return { init = init }

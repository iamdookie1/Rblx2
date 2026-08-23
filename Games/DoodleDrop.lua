--// Doodle Drop -------------------------------------------------------------------
-- You draw a track on a flat plane and a marble is dropped down it. The whole
-- game is one optimisation problem, and unusually the game hands you everything
-- needed to solve it.
--
-- ReplicatedStorage.MarbleGame ships its own deterministic 2D physics engine as
-- a plain ModuleScript. MarbleSim.run(segs, {startX, startY}, goalBox, opts)
-- returns
--
--   { outcome = "goal" | ..., reached = bool, time = n, ticks = n,
--     path = {{t, x, y}, ...}, maxSpeed = n, final = {x, y} }
--
-- at a fixed dt of 1/360 with gravity 206 - no Roblox physics involved, no
-- randomness, same answer every call. That means a track can be scored without
-- drawing it, without dropping a marble and without the server ever hearing
-- about it, which is the whole basis of the search below: generate a shape,
-- score it, keep what is quicker, repeat a few thousand times a minute.
--
-- The pipeline the game itself uses, and the one used here so the answer is
-- valid rather than merely fast:
--
--   strokes            array of arrays of Vector3 in the z = 0 plane
--   TrackPrep.cleanStrokes(strokes, Config.maxPoints, planeZ, noDrawSpec)
--   TrackPrep.simSegs(cleaned, level)   -> {{x1,y1,x2,y2}, ...}
--   MarbleSim.run(segs, start, goalBox, opts)
--
-- Levels come from MarbleGame.Levels: start, goalBox, barriers and noDraw zones
-- per level, all client readable. Barriers are fed to the sim through simSegs
-- exactly as the drawn track is, so the search plans around them for free.
--
-- One thing worth knowing and deliberately not built on: the run result travels
-- to the server as ClientResult:FireServer(reached, ticks, outcome, diag) - the
-- client states its own time. Nothing here touches that. A solved track is one
-- that genuinely runs that fast in the game's own engine, which is both the
-- interesting problem and the only version that survives the server checking
-- the strokes it was sent.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace


local function resolveEvent(modern, legacy)
    local ok, ev = pcall(function() return RunService[modern] end)
    if ok and ev then return ev end
    return RunService[legacy]
end
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local Unloading = false
local function track(c) Connections[#Connections + 1] = c return c end

--// Game modules ------------------------------------------------------------------
local Game = {}
do
    local root = ReplicatedStorage:FindFirstChild("MarbleGame")
    local function grab(name)
        if not root then return nil end
        local child = root:FindFirstChild(name)
        if not child then return nil end
        local ok, mod = pcall(require, child)
        return ok and mod or nil
    end
    Game.Config = grab("Config")
    Game.Levels = grab("Levels")
    Game.Sim = grab("MarbleSim")
    Game.Prep = grab("TrackPrep")
    Game.Remotes = root and root:FindFirstChild("Remotes") or nil
end

local READY = Game.Config ~= nil and Game.Levels ~= nil and Game.Sim ~= nil and Game.Prep ~= nil

--// Config ------------------------------------------------------------------------
local Config = {
    LevelId = 1,
    AutoLevel = true,

    Points = 7,
    Sigma = 6,
    Budget = 6,          -- ms of simulation per frame
    Anneal = 0.93,

    ShowPath = true,
    ShowTrack = true,
    TrackColor = Color3.fromRGB(120, 220, 130),
    PathColor = Color3.fromRGB(120, 200, 255),
}

local Stats = {
    Status = READY and "idle" or "MarbleGame modules not found",
    Level = "-",
    Sims = 0,
    Rate = 0,
    Best = "none",
    BestTicks = math.huge,
    Reached = false,
    Attempts = 0,
    Stage = "-",
}

--// Level model -------------------------------------------------------------------
local function getLevel(id)
    if not READY then return nil end
    local list = Game.Levels.list
    if not list then return nil end
    return list[math.clamp(id, 1, #list)]
end

-- The sim wants a flat option table. Barriers reach it through simSegs rather
-- than through here, which is why the search plans around them without ever
-- being told they exist.
local function simOptions(level)
    local tuning = level.tuning
    return {
        hazards = level.hazards,
        flippers = level.flippers,
        accelerators = level.accelerators,
        rings = level.rings,
        bounds = Game.Config.drawBounds,
        gravity = tuning and tuning.gravity or nil,
        restitution = tuning and tuning.restitution or nil,
        friction = tuning and tuning.friction or nil,
        maxTime = Game.Config.failTimeout,
    }
end

local function noDrawSpec(level)
    return {
        x = level.start.X,
        y = level.start.Y,
        r = Game.Config.noDrawRadius,
        zone = level.noDraw,
    }
end

--// Candidate tracks --------------------------------------------------------------
-- A candidate is a column of heights. The x positions are fixed, spread from
-- just clear of the drop to the middle of the goal box, and only the y values
-- are searched - which turns a free-form drawing into a handful of numbers and
-- is what makes a few thousand attempts a minute possible at all.
local function xColumn(level, n)
    local startX = level.start.X
    local goalBox = level.goalBox
    local goalX = (goalBox.minX + goalBox.maxX) * 0.5
    local bounds = Game.Config.drawBounds

    -- The first control point clears the no-draw circle around the drop, or the
    -- whole track is rejected before it is ever simulated.
    local clearance = Game.Config.noDrawRadius + Game.Config.marble.radius + 0.6
    local dir = goalX >= startX and 1 or -1
    local firstX = startX + dir * clearance

    local xs = {}
    for i = 1, n do
        local a = (i - 1) / (n - 1)
        xs[i] = math.clamp(firstX + (goalX - firstX) * a, bounds.minX, bounds.maxX)
    end
    return xs
end

local function clampY(y)
    local bounds = Game.Config.drawBounds
    return math.clamp(y, bounds.minY, bounds.maxY)
end

local function buildStrokes(xs, ys)
    local z = (Game.Config and Game.Config.planeZ) or 0
    local points = {}
    for i = 1, #xs do
        points[i] = Vector3.new(xs[i], ys[i], z)
    end
    return { points }
end

--// Scoring -----------------------------------------------------------------------
-- Lower is better. A track that arrives is scored on the game's own tick count;
-- one that does not is scored on how close it got, offset far enough that no
-- failure can ever beat an arrival.
local FAIL_BASE = 1e9

local function score(level, xs, ys)
    local strokes = buildStrokes(xs, ys)
    local spec = noDrawSpec(level)
    -- Third argument is planeZ, not a flag. Handing it a boolean makes the
    -- Vector3 constructor inside throw, every candidate scores as a failure and
    -- the search runs forever finding nothing.
    local planeZ = Game.Config.planeZ or 0
    local ok, cleaned = pcall(Game.Prep.cleanStrokes, strokes, Game.Config.maxPoints, planeZ, spec)
    if not ok or not cleaned then return FAIL_BASE * 10, nil end

    local violated = false
    pcall(function()
        violated = Game.Prep.noDrawViolation(cleaned, spec) and true or false
    end)
    if violated then return FAIL_BASE * 10, nil end

    local segsOk, segs = pcall(Game.Prep.simSegs, cleaned, level)
    if not segsOk or not segs or #segs == 0 then return FAIL_BASE * 10, nil end

    local runOk, result = pcall(
        Game.Sim.run, segs, { level.start.X, level.start.Y }, level.goalBox, simOptions(level)
    )
    Stats.Sims = Stats.Sims + 1
    if not runOk or type(result) ~= "table" then return FAIL_BASE * 10, nil end

    if result.reached then
        return result.ticks or math.floor((result.time or 0) * 10000), result
    end

    local goalBox = level.goalBox
    local gx = (goalBox.minX + goalBox.maxX) * 0.5
    local gy = (goalBox.minY + goalBox.maxY) * 0.5
    local final = result.final or { level.start.X, level.start.Y }
    local dx, dy = final[1] - gx, final[2] - gy
    return FAIL_BASE + math.sqrt(dx * dx + dy * dy) * 1000, result
end

--// Seeds -------------------------------------------------------------------------
-- Sensible starting shapes rather than pure noise. A steep drop that flattens
-- late is the fast answer to most of these - height first buys speed, and the
-- flat run spends it - so the search is handed that idea instead of having to
-- rediscover it from a straight line every restart.
local function seedShapes(level, xs)
    local n = #xs
    local y0 = level.start.Y - 2
    local goalBox = level.goalBox
    local y1 = (goalBox.minY + goalBox.maxY) * 0.5

    local shapes = {}

    local straight = {}
    for i = 1, n do
        straight[i] = clampY(y0 + (y1 - y0) * ((i - 1) / (n - 1)))
    end
    shapes[#shapes + 1] = straight

    -- Drop hard, then run flat.
    local steep = {}
    for i = 1, n do
        local a = (i - 1) / (n - 1)
        steep[i] = clampY(y0 + (y1 - y0) * (a ^ 0.45))
    end
    shapes[#shapes + 1] = steep

    -- Ease out gently, for levels where speed into the box overshoots it.
    local shallow = {}
    for i = 1, n do
        local a = (i - 1) / (n - 1)
        shallow[i] = clampY(y0 + (y1 - y0) * (a ^ 2.0))
    end
    shapes[#shapes + 1] = shallow

    -- A dip below the goal line and back up, which beats everything on levels
    -- where a barrier sits across the direct route.
    local dip = {}
    for i = 1, n do
        local a = (i - 1) / (n - 1)
        dip[i] = clampY(y0 + (y1 - y0) * a - math.sin(a * math.pi) * 8)
    end
    shapes[#shapes + 1] = dip

    return shapes
end

--// Search ------------------------------------------------------------------------
-- A restarted hill climb. Each pass perturbs every height by a shrinking
-- gaussian and keeps the result only if it is quicker, so it walks downhill
-- from wherever the seed put it; when the step size collapses the run is spent
-- and the next seed starts fresh somewhere else. Restarts are what stop a level
-- with a barrier in the way from settling into the best of the wrong shapes.
local Search = {
    running = false,
    level = nil,
    xs = nil,
    seeds = nil,
    seedIndex = 0,
    current = nil,
    currentScore = math.huge,
    sigma = 0,
    best = nil,
    bestScore = math.huge,
    bestResult = nil,
    sinceImprove = 0,
}

local function resetSearch(level)
    Search.level = level
    Search.xs = xColumn(level, math.floor(Config.Points))
    Search.seeds = seedShapes(level, Search.xs)
    Search.seedIndex = 0
    Search.current = nil
    Search.currentScore = math.huge
    Search.best = nil
    Search.bestScore = math.huge
    Search.bestResult = nil
    Search.sinceImprove = 0
    Stats.Sims = 0
    Stats.Attempts = 0
    Stats.Best = "none"
    Stats.BestTicks = math.huge
    Stats.Reached = false
end

local function copyList(list)
    local out = table.create(#list)
    for i = 1, #list do out[i] = list[i] end
    return out
end

local function beginSeed()
    Search.seedIndex = Search.seedIndex + 1
    local seeds = Search.seeds
    local seed
    if Search.seedIndex <= #seeds then
        seed = copyList(seeds[Search.seedIndex])
        Stats.Stage = ("seed %d of %d"):format(Search.seedIndex, #seeds)
    else
        -- Out of shapes, so restart from the best found so far with a wide
        -- kick. Random noise from scratch almost never clears a barrier.
        local base = Search.best or seeds[1]
        seed = copyList(base)
        for i = 1, #seed do
            seed[i] = clampY(seed[i] + (math.random() - 0.5) * Config.Sigma * 3)
        end
        Stats.Stage = ("restart %d"):format(Search.seedIndex - #seeds)
    end
    Search.current = seed
    Search.currentScore = math.huge
    Search.sigma = Config.Sigma
    Search.sinceImprove = 0
end

local function step()
    if not Search.current then
        beginSeed()
    end

    local xs, level = Search.xs, Search.level

    if Search.currentScore == math.huge then
        local s, result = score(level, xs, Search.current)
        Search.currentScore = s
        Stats.Attempts = Stats.Attempts + 1
        if s < Search.bestScore then
            Search.bestScore = s
            Search.best = copyList(Search.current)
            Search.bestResult = result
        end
        return
    end

    local trial = copyList(Search.current)
    for i = 1, #trial do
        trial[i] = clampY(trial[i] + (math.random() - 0.5) * 2 * Search.sigma)
    end

    local s, result = score(level, xs, trial)
    Stats.Attempts = Stats.Attempts + 1

    if s < Search.currentScore then
        Search.current = trial
        Search.currentScore = s
        Search.sinceImprove = 0
        if s < Search.bestScore then
            Search.bestScore = s
            Search.best = copyList(trial)
            Search.bestResult = result
            Stats.Reached = s < FAIL_BASE
            Stats.BestTicks = s < FAIL_BASE and s or math.huge
            Stats.Best = s < FAIL_BASE and ("%.4fs"):format(s / 10000) or "no route yet"
        end
    else
        Search.sinceImprove = Search.sinceImprove + 1
        Search.sigma = Search.sigma * Config.Anneal
        -- Spent: the steps are too small to find anything and nothing has moved
        -- in a while. Take the next seed rather than grinding.
        if Search.sigma < 0.05 or Search.sinceImprove > 60 then
            Search.current = nil
        end
    end
end

local simsThisSecond, secondMark = 0, os.clock()

track(PostSimulation:Connect(function()
    if Unloading or not Search.running or not READY then return end
    local budget = Config.Budget / 1000
    local started = os.clock()
    local before = Stats.Sims
    while os.clock() - started < budget do
        step()
        if not Search.running then break end
    end
    simsThisSecond = simsThisSecond + (Stats.Sims - before)
    if os.clock() - secondMark >= 1 then
        Stats.Rate = simsThisSecond / (os.clock() - secondMark)
        simsThisSecond, secondMark = 0, os.clock()
    end
    Stats.Status = ("searching - %s"):format(Stats.Stage)
end))

--// Drawing ----------------------------------------------------------------------
local folder
local function visualFolder()
    if folder and folder.Parent then return folder end
    folder = Instance.new("Folder")
    folder.Name = "DD_Solver"
    folder.Parent = Workspace
    return folder
end

local function clearVisual()
    if folder then
        pcall(function() folder:ClearAllChildren() end)
    end
end

local function drawLine(a, b, colour, thickness)
    local diff = b - a
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Material = Enum.Material.Neon
    part.Color = colour
    part.Size = Vector3.new(thickness, thickness, math.max(diff.Magnitude, 0.05))
    part.CFrame = CFrame.lookAt(a + diff * 0.5, b)
    part.Parent = visualFolder()
end

local function drawBest()
    clearVisual()
    if not Search.best or not Search.xs then return end
    local xs, ys = Search.xs, Search.best

    if Config.ShowTrack then
        for i = 2, #xs do
            drawLine(
                Vector3.new(xs[i - 1], ys[i - 1], 0),
                Vector3.new(xs[i], ys[i], 0),
                Config.TrackColor, 0.5
            )
        end
    end

    -- The trajectory the sim actually produced, which is the useful half: it
    -- shows where the marble leaves the track and whether it lands in the box
    -- or merely near it.
    if Config.ShowPath and Search.bestResult and Search.bestResult.path then
        local path = Search.bestResult.path
        for i = 2, #path do
            local a, b = path[i - 1], path[i]
            drawLine(
                Vector3.new(a[2], a[3], 0),
                Vector3.new(b[2], b[3], 0),
                Config.PathColor, 0.25
            )
        end
    end
end

--// Playing it ------------------------------------------------------------------
-- The strokes go to the server the same way the game's own drop does. Nothing
-- here reports a time: the run is played out and scored by whatever the game
-- normally scores it with, which is the point - a track this fast is fast
-- because the physics say so, not because we said so.
local function playBest(mode)
    if not Search.best or not Search.xs then return false, "nothing solved yet" end
    local remotes = Game.Remotes
    local drop = remotes and remotes:FindFirstChild("DropMarble")
    if not drop then return false, "DropMarble remote missing" end

    local strokes = buildStrokes(Search.xs, Search.best)
    local ok, err = pcall(function()
        drop:FireServer(mode or "fast", strokes, os.clock(), Config.LevelId)
    end)
    return ok, ok and "sent" or tostring(err)
end

--// Level tracking ---------------------------------------------------------------
if READY and Game.Remotes then
    local setLevel = Game.Remotes:FindFirstChild("SetLevel")
    if setLevel then
        track(setLevel.OnClientEvent:Connect(function(payload)
            if Unloading or not Config.AutoLevel then return end
            local id
            if type(payload) == "number" then
                id = payload
            elseif type(payload) == "table" then
                id = payload.levelId or payload.level or payload.id
            end
            if type(id) == "number" and id ~= Config.LevelId then
                Config.LevelId = id
                local level = getLevel(id)
                if level then
                    Stats.Level = ("%d - %s"):format(id, tostring(level.name))
                    if Search.running then
                        resetSearch(level)
                    end
                end
            end
        end))
    end
end

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui/main/Lib2.lua"))()

local Window = Centrl:Window({
    Title = "doodle drop",
    SubTitle = "path solver",
    Folder = "Hub",
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(120, 220, 130),
})

local SolveTab = Window:Tab({ Title = "solve", Icon = "route" })

local RunSection = SolveTab:Section({ Title = "search", Side = "left" })

RunSection:Toggle({
    Title = "search for a path",
    Flag = "dd_search",
    Default = false,
    Callback = function(state)
        if not READY then
            Stats.Status = "MarbleGame modules not found"
            return
        end
        Search.running = state
        if state then
            local level = getLevel(Config.LevelId)
            if level then
                Stats.Level = ("%d - %s"):format(Config.LevelId, tostring(level.name))
                resetSearch(level)
            else
                Search.running = false
                Stats.Status = "no such level"
            end
        else
            Stats.Status = "stopped"
        end
    end,
})

RunSection:Slider({
    Title = "level",
    Flag = "dd_level",
    Min = 1, Max = 12, Increment = 1, Default = 1,
    Callback = function(value)
        Config.LevelId = value
        local level = getLevel(value)
        if level then
            Stats.Level = ("%d - %s"):format(value, tostring(level.name))
            if Search.running then resetSearch(level) end
        end
    end,
})

RunSection:Toggle({
    Title = "follow the level i'm on",
    Flag = "dd_autolevel",
    Default = true,
    Callback = function(state) Config.AutoLevel = state end,
})

RunSection:Button({
    Title = "draw the best path",
    Callback = function() drawBest() end,
})

RunSection:Button({
    Title = "play it",
    Callback = function()
        local ok, message = playBest("fast")
        Centrl:Notify({
            Title = "doodle drop",
            Content = message,
            Type = ok and "success" or "warning",
            Duration = 5,
        })
    end,
})

RunSection:Button({
    Title = "clear drawing",
    Callback = function() clearVisual() end,
})

local TuneSection = SolveTab:Section({ Title = "search shape", Side = "right" })

TuneSection:Slider({
    Title = "control points",
    Flag = "dd_points",
    Min = 3, Max = 20, Increment = 1, Default = 7,
    Callback = function(value)
        Config.Points = value
        local level = getLevel(Config.LevelId)
        if level and Search.running then resetSearch(level) end
    end,
})

TuneSection:Slider({
    Title = "starting step size",
    Flag = "dd_sigma",
    Min = 0.5, Max = 20, Increment = 0.5, Default = 6,
    Suffix = " studs",
    Callback = function(value) Config.Sigma = value end,
})

TuneSection:Slider({
    Title = "simulation per frame",
    Flag = "dd_budget",
    Min = 1, Max = 12, Increment = 0.5, Default = 6,
    Suffix = "ms",
    Callback = function(value) Config.Budget = value end,
})

TuneSection:Paragraph({
    Title = "what is actually being searched",
    Text = "A candidate track is a row of control points at fixed x positions, evenly spread from just clear of the drop to the middle of the goal box, and only their heights are searched. That turns a free-form drawing into a handful of numbers, which is the difference between a few attempts a second and a few thousand a minute.\n\nMore control points can express a cleverer shape but make the search space larger, so they take longer to pay off. Seven is a good default; raise it for levels where the direct route is blocked and a genuinely odd shape is needed.",
})

TuneSection:Paragraph({
    Title = "why it restarts",
    Text = "Each pass nudges every height by a shrinking random amount and keeps the change only if the marble arrives quicker, walking downhill from wherever it started. When the steps get too small to find anything the run is spent, and the next seed starts somewhere else entirely - a straight ramp, a steep drop that flattens late, a gentle curve, a dip below the goal line and back up.\n\nThat last one exists because a level with a barrier across the direct route has a best answer that no amount of nudging a straight line will ever reach. Restarts are what stop it settling for the best of the wrong shape.",
})

TuneSection:Paragraph({
    Title = "the simulation is the game's own",
    Text = "MarbleSim ships in ReplicatedStorage as a plain module: a fixed 1/360 step, gravity 206, no Roblox physics and no randomness, so the same track scores the same every time. A candidate is cleaned through the game's own TrackPrep - the same clamping, smoothing, spacing and no-draw checks a hand-drawn path gets - before it is scored, so a track that wins here is a track that is legal and genuinely that quick rather than one that only looks good on paper.\n\nLevel barriers are handed to the simulation the same way the drawn track is, which is why the search plans around them without being told they are there.",
})

local StatusSection = SolveTab:Section({ Title = "status", Side = "left" })

local statusLabel = StatusSection:Label({ Title = "status: --" })
local levelLabel = StatusSection:Label({ Title = "level: --" })
local bestLabel = StatusSection:Label({ Title = "best: --" })
local simLabel = StatusSection:Label({ Title = "sims: 0" })
local stageLabel = StatusSection:Label({ Title = "stage: --" })

StatusSection:Paragraph({
    Title = "the time is reported by the client",
    Text = "Worth saying because it explains what this deliberately is not. A finished run reaches the server as ClientResult with the tick count the client worked out, so a fabricated record is one line away and nothing here goes near it.\n\nThe strokes are sent too, though, so a claimed time that the track cannot produce is a claim the server can check. Solving the track properly is the version that holds up either way, and it is the more interesting problem.",
})

local VisualSection = SolveTab:Section({ Title = "drawing", Side = "right" })

VisualSection:Toggle({
    Title = "show the track",
    Flag = "dd_show_track",
    Default = true,
    Callback = function(state) Config.ShowTrack = state drawBest() end,
})

VisualSection:Toggle({
    Title = "show the marble's route",
    Flag = "dd_show_path",
    Default = true,
    Callback = function(state) Config.ShowPath = state drawBest() end,
})

VisualSection:Colorpicker({
    Title = "track colour",
    Flag = "dd_track_colour",
    Default = Color3.fromRGB(120, 220, 130),
    Callback = function(value) Config.TrackColor = value drawBest() end,
})

VisualSection:Colorpicker({
    Title = "route colour",
    Flag = "dd_path_colour",
    Default = Color3.fromRGB(120, 200, 255),
    Callback = function(value) Config.PathColor = value drawBest() end,
})

VisualSection:Button({
    Title = "unload",
    Callback = function()
        Unloading = true
        Search.running = false
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        clearVisual()
        if folder then pcall(function() folder:Destroy() end) end
        Centrl:Unload()
    end,
})

Window:Load()

--// Status pump ------------------------------------------------------------------
task.spawn(function()
    local lastDraw = 0
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            statusLabel:Set("status: " .. Stats.Status)
            levelLabel:Set("level: " .. Stats.Level)
            bestLabel:Set(("best: %s%s"):format(Stats.Best, Stats.Reached and "" or "  (not arriving yet)"))
            simLabel:Set(("sims: %d   %.0f/s   tried %d"):format(Stats.Sims, Stats.Rate, Stats.Attempts))
            stageLabel:Set("stage: " .. Stats.Stage)
        end)
        -- Redrawn on a timer rather than on every improvement: early on the best
        -- changes several times a second and rebuilding the parts that often
        -- costs more than the search itself.
        if Search.running and os.clock() - lastDraw > 1.5 then
            lastDraw = os.clock()
            pcall(drawBest)
        end
    end
end)

Centrl:Notify({
    Title = "doodle drop",
    Content = READY and "Loaded. RightShift toggles the menu."
        or "Loaded, but ReplicatedStorage.MarbleGame was not found.",
    Type = READY and "success" or "warning",
    Duration = 6,
})

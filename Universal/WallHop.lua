--// Wall Hop -------------------------------------------------------------------------
-- A wall hop and ladder flick helper for any game. It runs on its own, outside
-- the hub:
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Universal/WallHop.lua'))()
--
-- A wall hop only works where two parts meet: blocks stacked with no gap, or the
-- top edge of a wall. When your legs are level with that seam and you turn about
-- 45 degrees and straight back, a corner of your character swings into the wall.
-- The humanoid's ground check then starts inside the upper part, finds the top of
-- the lower one and counts you as landed, so a held jump goes off again. A ladder
-- flick is the same trick on a ladder's rungs, and a truss flick the same at the
-- top of a truss with a part over it.
--
-- The turn, three ways:
--   Silent  turns your character. Unseen, it only lasts while physics runs and
--           is undone before the frame is drawn; with visible rotation on it
--           turns where everyone can see it, at the rotation speed.
--   Camera  turns the camera and back the way a player flicks, instantly or at
--           the rotation speed. Your character only follows in shift lock or
--           first person.
--   Keys    presses , and . (Roblox's 45 degree camera keys) the way the public
--           wall hop macro does.
--
-- Wall hops can be timed two ways:
--   On jump press  flicks the moment you press jump in the air next to a wall.
--   At seam        flicks by itself when a seam reaches the set height on your
--                  legs while you push toward the wall. Hold jump to hop.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__WallHopStop) == "function" then pcall(Genv.__WallHopStop) end

local Settings = {
    Enabled = false,
    Method = "Silent",            -- Silent / Camera / Keys
    When = "On jump press",       -- On jump press / At seam
    Direction = "Away from wall", -- Away from wall / Left / Right / Alternate
    Angle = 45,                   -- degrees
    SeamHeight = 30,              -- At seam: how far up your legs the seam is when it flicks, in %

    -- rotation
    Visible = false,              -- turn where it can be seen, at Speed, instead of in one go
    Speed = 720,                  -- degrees per second
    SyncMobile = false,           -- use how fast you really turn your camera instead of Speed
    RandomSpeed = false,
    SpeedRandom = 180,            -- degrees per second either side of the speed
    TurnBackVisible = true,       -- with visible rotation, turn back at the same speed

    -- hold
    HoldBy = "Frames",            -- Frames / Milliseconds / Until it lands
    HoldFrames = 2,
    HoldMs = 50,
    RandomHold = false,
    HoldRandom = 20,              -- ms either side

    -- legit
    Reaction = 0,                 -- ms before the turn starts
    ReactionRandom = 0,           -- ms either side
    AngleRandom = 0,              -- degrees either side
    Miss = 0,                     -- % of flicks left out on purpose
    MinGap = 0,                   -- ms between hops at the least
    MaxHops = 0,                  -- hops in a row before it waits for the floor, 0 = no limit
    OnlySeams = false,            -- On jump press waits for a seam rather than flicking at once
    NeedHeldJump = false,         -- leave the jump to you instead of keeping your press
}

local Ladder = {
    Enabled = false,
    When = "On jump press",       -- On jump press / Auto climb / Truss top
    Method = "Silent",
    Direction = "Alternate",      -- Left / Right / Alternate
    Angle = 45,
    Interval = 250,               -- Auto climb: ms between flicks
}

local WALL_GAP = 1          -- studs between you and a wall for it to count
local WALL_NORMAL_Y = 0.35  -- a face tilted more than this is a floor or a slope, not a wall
local SCAN_STEP = 0.2       -- seam scan spacing before a find is refined
local SCAN_BELOW = 0.5      -- the scan starts this far under your feet
local SCAN_ABOVE = 0.3      -- and ends this far over your hips
local COOLDOWN = 0.05       -- seconds between flicks
local SAME_SEAM = 0.35      -- At seam: a seam this close to the last one is that one again
local SAME_SEAM_TIME = 0.6
local PRESS_GAP = 0.12      -- JumpRequest repeats while jump is held; a gap this long is a new press
local PRESS_WINDOW = 0.1    -- a press still counts this long after it, if the wall shows up late
local SEAM_WAIT = 0.35      -- only flick at seams: how long a press waits for one
local MAX_HOLD = 0.5        -- hold until it lands gives up after this
local FLICK_TIMEOUT = 6     -- a flick that has not finished by now is ended
local TOP_STILL = 0.15      -- truss top: still on it for this long means the top
local MOBILE_DEFAULT = 540  -- degrees per second until your own turning has been measured

local RENDER_NAME = "WallHopCamera"

local function resolveEvent(modern, legacy)
    local ok, event = pcall(function() return RunService[modern] end)
    if ok and event then return event end
    return RunService[legacy]
end

local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local notify = function() end
local Window

--// Character ----------------------------------------------------------------------
local function character()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = hum and (hum.RootPart or char:FindFirstChild("HumanoidRootPart"))
    if not root or hum.Health <= 0 then return nil end
    return char, hum, root
end

local AIRBORNE = {
    [Enum.HumanoidStateType.Freefall] = true,
    [Enum.HumanoidStateType.Jumping] = true,
}

local LANDING = {
    [Enum.HumanoidStateType.Landed] = true,
    [Enum.HumanoidStateType.Running] = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Jumping] = true,
}

local CLIMBING = Enum.HumanoidStateType.Climbing

-- R6 legs are 2 studs; R15 sizes them with HipHeight.
local function legLength(hum)
    if hum.RigType == Enum.HumanoidRigType.R6 then return 2 end
    return hum.HipHeight
end

local function feetY(hum, root)
    return root.Position.Y - root.Size.Y / 2 - legLength(hum)
end

--// Geometry -----------------------------------------------------------------------
local function flat(v)
    local f = Vector3.new(v.X, 0, v.Z)
    if f.Magnitude < 1e-3 then return nil end
    return f.Unit
end

-- The same turn as CFrame.Angles(0, yaw, 0): a positive yaw turns left.
local function rotateY(v, yaw)
    local c, s = math.cos(yaw), math.sin(yaw)
    return Vector3.new(v.X * c + v.Z * s, v.Y, v.Z * c - v.X * s)
end

-- How far your footprint reaches from its centre along `dir`, after turning by `yaw`.
local function reach(root, dir, yaw)
    local right, look = root.CFrame.RightVector, root.CFrame.LookVector
    if yaw and yaw ~= 0 then
        right, look = rotateY(right, yaw), rotateY(look, yaw)
    end
    return root.Size.X / 2 * math.abs(right:Dot(dir)) + root.Size.Z / 2 * math.abs(look:Dot(dir))
end

local Params = RaycastParams.new()
Params.FilterType = Enum.RaycastFilterType.Exclude
Params.IgnoreWater = true
pcall(function() Params.RespectCanCollide = true end)

local filterAt = -math.huge

-- Characters (yours and everyone else's) and anything on the camera are never walls.
local function refreshFilter()
    if os.clock() - filterAt < 0.5 then return end
    filterAt = os.clock()
    local list = {}
    if Workspace.CurrentCamera then list[#list + 1] = Workspace.CurrentCamera end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then list[#list + 1] = player.Character end
    end
    Params.FilterDescendantsInstances = list
end

local AROUND = { 0, math.pi / 4, -math.pi / 4, math.pi / 2, -math.pi / 2, math.pi * 3 / 4, -math.pi * 3 / 4, math.pi }

-- The closest wall next to your legs, looking all the way round you.
local function findWall(hum, root)
    local look = flat(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
    local feet, leg = feetY(hum, root), legLength(hum)
    local heights = { feet + 0.15, feet + leg * 0.6 }
    local best
    for _, yaw in ipairs(AROUND) do
        local dir = rotateY(look, yaw)
        local edge = reach(root, dir)
        for _, y in ipairs(heights) do
            local origin = Vector3.new(root.Position.X, y, root.Position.Z)
            local hit = Workspace:Raycast(origin, dir * (edge + WALL_GAP), Params)
            local normal = hit and math.abs(hit.Normal.Y) < WALL_NORMAL_Y and flat(hit.Normal)
            if normal then
                local gap = (hit.Position - origin).Magnitude - edge
                if not best or gap < best.gap then
                    best = { gap = gap, into = -normal, depth = (hit.Position - origin):Dot(-normal) }
                end
            end
        end
    end
    return best
end

-- Heights on that wall where a part stops: the top of a part with another part,
-- or nothing, right above it. Scans from `low` to `high` and refines each find.
local function findSeams(root, wall, low, high)
    local length = wall.depth + 1
    local x, z = root.Position.X, root.Position.Z
    local function probe(y)
        local hit = Workspace:Raycast(Vector3.new(x, y, z), wall.into * length, Params)
        if hit and math.abs(hit.Normal.Y) < WALL_NORMAL_Y then return hit.Instance end
        return nil
    end
    local seams = {}
    local y, below = low, probe(low)
    while y < high do
        local nextY = math.min(y + SCAN_STEP, high)
        local above = probe(nextY)
        if below and above ~= below then
            local lo, hi = y, nextY
            for _ = 1, 4 do
                local mid = (lo + hi) / 2
                if probe(mid) == below then lo = mid else hi = mid end
            end
            seams[#seams + 1] = (lo + hi) / 2
        end
        y, below = nextY, above
    end
    return seams
end

--// How fast you turn your own camera -------------------------------------------------
-- Every quick turn of the camera that this script did not make is one sample:
-- the fastest it went during that turn. Sync with mobile rotation speed uses
-- the middle of the last dozen, so the flick turns as fast as your own swipes.
-- A jump in a single frame is a cut (a respawn, a teleport, the camera snapping
-- back), not a swipe, so a turn has to last two frames to count.
local Turn = { peaks = {}, peak = 0, frames = 0, yaw = nil }

function Turn.measure(dt, ours)
    local camera = Workspace.CurrentCamera
    if not camera or dt <= 0 then return end
    local look = camera.CFrame.LookVector
    local yaw = math.atan2(-look.X, -look.Z)
    if ours then
        Turn.peak, Turn.frames = 0, 0
    elseif Turn.yaw then
        local d = (yaw - Turn.yaw + math.pi) % (2 * math.pi) - math.pi
        local rate = math.deg(math.abs(d)) / dt
        if rate > 90 then
            Turn.peak = math.max(Turn.peak, rate)
            Turn.frames = Turn.frames + 1
        else
            if Turn.frames >= 2 then
                table.insert(Turn.peaks, Turn.peak)
                if #Turn.peaks > 12 then table.remove(Turn.peaks, 1) end
            end
            Turn.peak, Turn.frames = 0, 0
        end
    end
    Turn.yaw = yaw
end

function Turn.speed()
    if #Turn.peaks == 0 then return MOBILE_DEFAULT end
    local sorted = {}
    for i, v in ipairs(Turn.peaks) do sorted[i] = v end
    table.sort(sorted)
    return sorted[math.floor((#sorted + 1) / 2)]
end

--// Flick ----------------------------------------------------------------------------
-- A flick goes wait (the reaction delay), out (turning to the angle), hold
-- (staying there), back (turning home), then ends. Its offset is how far it is
-- turned right now; applied is how much of that is on the character or camera.
local Flick = {
    active = false,
    method = nil,
    source = nil,          -- wall / ladder
    phase = nil,
    sign = 1,              -- +1 turns left, -1 turns right
    turn = 0,              -- radians, signed
    offset = 0,
    applied = 0,
    visible = false,
    speed = math.huge,     -- radians per second
    backSpeed = math.huge,
    startAt = 0,
    outAt = 0,
    holdStart = 0,
    holdCount = 0,
    holdFrames = 1,
    holdTime = 0,
    keysOut = false,
    saved = nil,           -- unseen Silent: your rotation before this physics step's turn
    autoRotate = nil,
    hum = nil,
    root = nil,
    latch = false,         -- keep the jump press that started it
    hopped = false,
    startedAt = -math.huge,
    endedAt = -math.huge,
    lastSeam = nil,
    lastSeamAt = -math.huge,
    alternate = 1,
    ladderAlternate = 1,
    pressAt = -math.huge,
    ladderPressAt = -math.huge,
    lastLadderAt = -math.huge,
    lastRequest = -math.huge,
    stillSince = nil,
    groundSince = nil,
    chain = 0,             -- hops since you were last on the floor
    flicks = 0,
    hops = 0,
    skipped = 0,
    lastSpeed = nil,       -- degrees per second, for the status line
    wall = nil,
    seam = nil,
    seenAt = -math.huge,
}

local function spread(amount)
    if not amount or amount <= 0 then return 0 end
    return (math.random() * 2 - 1) * amount
end

local function tapKey(key)
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

-- , turns the camera left and . turns it right
local function flickKey(sign)
    return sign > 0 and Enum.KeyCode.Comma or Enum.KeyCode.Period
end

local function turnCamera(yaw)
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local pivot = camera.Focus.Position
    camera.CFrame = CFrame.new(pivot) * CFrame.Angles(0, yaw, 0) * CFrame.new(-pivot) * camera.CFrame
end

local function rotateRoot(root, yaw)
    local cf = root.CFrame
    root.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, yaw, 0) * (cf - cf.Position)
end

local function nextAlternate()
    Flick.alternate = -Flick.alternate
    return Flick.alternate
end

local function wallSign(root, wall)
    local direction = Settings.Direction
    if direction == "Left" then return 1 end
    if direction == "Right" then return -1 end
    if direction == "Alternate" then return nextAlternate() end
    -- Away from wall: the side that swings a corner deeper into the wall, which
    -- is turning away from it whenever you roughly face it. Head on, either
    -- side works.
    local turn = math.rad(Settings.Angle)
    local left, right = reach(root, wall.into, turn), reach(root, wall.into, -turn)
    if math.abs(left - right) < 0.02 then return nextAlternate() end
    return left > right and 1 or -1
end

local function ladderSign()
    if Ladder.Direction == "Left" then return 1 end
    if Ladder.Direction == "Right" then return -1 end
    Flick.ladderAlternate = -Flick.ladderAlternate
    return Flick.ladderAlternate
end

-- degrees per second for the next flick: your own turning or the slider, give
-- or take the randomizer
local function flickSpeed()
    local base = Settings.SyncMobile and Turn.speed() or Settings.Speed
    if Settings.RandomSpeed then base = base + spread(Settings.SpeedRandom) end
    return math.max(base, 30)
end

local function finishFlick()
    if not Flick.active then return end
    local hum, root = Flick.hum, Flick.root
    if Flick.method == "Silent" then
        if root and root.Parent then
            if Flick.saved then
                root.CFrame = CFrame.new(root.Position) * Flick.saved
            elseif Flick.applied ~= 0 then
                rotateRoot(root, -Flick.applied)
            end
        end
        if Flick.autoRotate ~= nil and hum then hum.AutoRotate = Flick.autoRotate end
    elseif Flick.method == "Camera" then
        if Flick.applied ~= 0 then turnCamera(-Flick.applied) end
    elseif Flick.method == "Keys" then
        if Flick.keysOut then tapKey(flickKey(-Flick.sign)) end
    end
    Flick.saved = nil
    Flick.autoRotate = nil
    Flick.keysOut = false
    Flick.offset, Flick.applied = 0, 0
    Flick.active = false
    Flick.endedAt = os.clock()
end

local function startFlick(hum, root, sign, angle, method, latch, source)
    local now = os.clock()
    if method == "Keys" and not VirtualInputManager then return end
    -- now and then a flick is left out on purpose
    if Settings.Miss > 0 and math.random() * 100 < Settings.Miss then
        Flick.skipped = Flick.skipped + 1
        Flick.endedAt = now
        return
    end

    Flick.active = true
    Flick.method = method
    Flick.source = source
    Flick.sign = sign
    Flick.turn = math.rad(math.max(1, angle + spread(Settings.AngleRandom))) * sign
    Flick.visible = Settings.Visible and method ~= "Keys"
    local speed = flickSpeed()
    Flick.lastSpeed = Flick.visible and speed or nil
    Flick.speed = Flick.visible and math.rad(speed) or math.huge
    Flick.backSpeed = (Flick.visible and Settings.TurnBackVisible) and Flick.speed or math.huge
    Flick.startAt = now + math.max(0, (Settings.Reaction + spread(Settings.ReactionRandom)) / 1000)
    Flick.phase = "wait"
    Flick.offset, Flick.applied = 0, 0

    local jitter = Settings.RandomHold and spread(Settings.HoldRandom) or 0
    Flick.holdFrames = math.max(1, math.floor(Settings.HoldFrames + jitter / (1000 / 60) + 0.5))
    Flick.holdTime = math.max(0, (Settings.HoldMs + jitter) / 1000)

    Flick.hum, Flick.root = hum, root
    Flick.latch = latch and not Settings.NeedHeldJump
    Flick.hopped = false
    Flick.saved = nil
    Flick.autoRotate = nil
    Flick.keysOut = false
    Flick.startedAt = now
    Flick.flicks = Flick.flicks + 1
end

-- keep the jump press that started it, from the moment the turn is really on
-- you: a jump that went off before the turn (off a ladder, say) would be wasted
local function latchJump(hum)
    if not (Flick.active and Flick.latch) then return end
    local turned = (Flick.method == "Silent" and Flick.offset ~= 0)
        or (Flick.method == "Camera" and Flick.applied ~= 0)
        or (Flick.method == "Keys" and Flick.keysOut and os.clock() > Flick.outAt)
    if turned then hum.Jump = true end
end

local function beginBack()
    Flick.phase = "back"
    if Flick.method == "Keys" then
        if Flick.keysOut then tapKey(flickKey(-Flick.sign)) end
        Flick.keysOut = false
        Flick.offset = 0
    end
end

local function approach(value, goal, step)
    if step == math.huge then return goal end
    if value < goal then return math.min(goal, value + step) end
    return math.max(goal, value - step)
end

-- one step of the flick: through the phases, and how far it is turned now
local function advance(dt, now)
    if Flick.phase == "wait" then
        if now < Flick.startAt then return end
        Flick.phase = "out"
        Flick.outAt = now
        if Flick.method == "Keys" then
            tapKey(flickKey(Flick.sign))
            Flick.keysOut = true
            Flick.offset = Flick.turn
        end
    end

    if Flick.phase == "out" then
        Flick.offset = approach(Flick.offset, Flick.turn, Flick.speed * dt)
        if Flick.offset == Flick.turn then
            Flick.phase = "hold"
            Flick.holdStart, Flick.holdCount = now, 0
        elseif Flick.hopped then
            beginBack()
        end
        return
    end

    if Flick.phase == "hold" then
        Flick.holdCount = Flick.holdCount + 1
        local done
        if Settings.HoldBy == "Milliseconds" then
            done = now - Flick.holdStart >= Flick.holdTime
        elseif Settings.HoldBy == "Until it lands" then
            done = Flick.hopped or now - Flick.holdStart >= MAX_HOLD
        else
            -- frames, cut short once it has done its job
            done = Flick.holdCount >= Flick.holdFrames or Flick.hopped
        end
        if not done then return end
        beginBack()
    end

    if Flick.phase == "back" then
        Flick.offset = approach(Flick.offset, 0, Flick.backSpeed * dt)
        if Flick.offset == 0 then finishFlick() end
    end
end

-- Silent and Keys, before each physics step. Unseen Silent turns you for the
-- step and is undone after it; seen, the turn stays on you between frames.
local function silentStep(dt, now)
    advance(dt, now)
    if not Flick.active or Flick.method ~= "Silent" then return end
    local hum, root = Flick.hum, Flick.root
    if not root or not root.Parent then return finishFlick() end
    if Flick.offset ~= 0 and Flick.autoRotate == nil then
        -- the humanoid would otherwise turn you straight back
        Flick.autoRotate = hum.AutoRotate
        hum.AutoRotate = false
    end
    if Flick.visible then
        local delta = Flick.offset - Flick.applied
        if delta ~= 0 then
            rotateRoot(root, delta)
            Flick.applied = Flick.offset
        end
    elseif Flick.offset ~= 0 then
        local cf = root.CFrame
        Flick.saved = cf - cf.Position
        root.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, Flick.offset, 0) * Flick.saved
    end
end

-- unseen Silent, after the step: turn back before anything is drawn, and keep
-- wherever physics moved you
local function silentRestore()
    local root = Flick.root
    if Flick.saved and root and root.Parent then
        root.CFrame = CFrame.new(root.Position) * Flick.saved
        local spin = root.AssemblyAngularVelocity
        root.AssemblyAngularVelocity = Vector3.new(0, spin.Y, 0)
    end
    Flick.saved = nil
end

-- Camera, each frame right after the camera updates. The character turns to
-- the camera in the physics step that follows.
local function cameraStep(dt, now)
    advance(dt, now)
    if not Flick.active then return end
    local delta = Flick.offset - Flick.applied
    if delta ~= 0 then
        turnCamera(delta)
        Flick.applied = Flick.offset
    end
end

-- whether another flick may start now: the gap since the last one, and how
-- many hops in a row there have been since the floor
local function ready(now)
    if now - Flick.endedAt < math.max(COOLDOWN, Settings.MinGap / 1000) then return false end
    if Settings.MaxHops > 0 and Flick.chain >= Settings.MaxHops then return false end
    return true
end

-- ladder flick: on a ladder or truss, while the humanoid is climbing
local function ladderStep(dt, hum, root, now)
    local vy = root.AssemblyLinearVelocity.Y
    if math.abs(vy) < 1 then
        Flick.stillSince = Flick.stillSince or now
    else
        Flick.stillSince = nil
    end
    if not ready(now) then return end

    local pressed = now - Flick.ladderPressAt <= PRESS_WINDOW
    local go
    if Ladder.When == "Auto climb" then
        local climbing = hum.MoveDirection.Magnitude > 0.1 or vy > 1
        go = climbing and now - Flick.lastLadderAt >= Ladder.Interval / 1000
    elseif Ladder.When == "Truss top" then
        -- the top is where climbing stops taking you up
        go = pressed and Flick.stillSince ~= nil and now - Flick.stillSince >= TOP_STILL
    else
        go = pressed
    end
    if not go then return end

    Flick.ladderPressAt = -math.huge
    Flick.lastLadderAt = now
    startFlick(hum, root, ladderSign(), Ladder.Angle, Ladder.Method, true, "ladder")
    if Flick.active and Flick.method ~= "Camera" then silentStep(dt, now) end
    latchJump(hum)
end

local function step(dt)
    local _, hum, root = character()
    local now = os.clock()

    if Flick.active then
        local off = (Flick.source == "wall" and not Settings.Enabled) or (Flick.source == "ladder" and not Ladder.Enabled)
        if not hum or hum ~= Flick.hum or off or now - Flick.startedAt > FLICK_TIMEOUT then
            finishFlick()
            return
        end
        if Flick.method ~= "Camera" then silentStep(dt, now) end
        latchJump(hum)
        return
    end
    if not hum then return end

    -- a moment on the floor starts the count of hops in a row over
    local state = hum:GetState()
    if AIRBORNE[state] or state == CLIMBING then
        Flick.groundSince = nil
    else
        Flick.groundSince = Flick.groundSince or now
        if now - Flick.groundSince > 0.2 then Flick.chain = 0 end
    end

    if state == CLIMBING then
        if Ladder.Enabled then ladderStep(dt, hum, root, now) end
        return
    end
    Flick.stillSince = nil

    if not Settings.Enabled then return end
    if not AIRBORNE[state] then
        Flick.pressAt = -math.huge
        return
    end

    refreshFilter()
    local wall = findWall(hum, root)
    if not wall then return end

    local leg, feet = legLength(hum), feetY(hum, root)
    local vy = root.AssemblyLinearVelocity.Y
    -- Camera and Keys turn you a frame later than Silent does, and the
    -- reaction delay later still
    local lead = (Settings.Method == "Silent" and 0 or dt) + math.max(0, Settings.Reaction) / 1000
    local target = feet + vy * lead + leg * Settings.SeamHeight / 100
    local nearest
    for _, seam in ipairs(findSeams(root, wall, feet - SCAN_BELOW, feet + leg + SCAN_ABOVE)) do
        if not nearest or math.abs(seam - target) < math.abs(nearest - target) then nearest = seam end
    end
    Flick.wall, Flick.seam, Flick.seenAt = wall.gap, nearest and nearest - feet, now

    if not ready(now) then return end

    local tolerance = math.max(0.1, math.abs(vy) * dt / 2 + 0.05)
    local atSeam = nearest ~= nil and math.abs(nearest - target) <= tolerance
    local latch
    if Settings.When == "On jump press" then
        local window = Settings.OnlySeams and SEAM_WAIT or PRESS_WINDOW
        if now - Flick.pressAt > window then return end
        -- only flick at seams: the press waits for one to come into reach
        if Settings.OnlySeams and not atSeam then return end
        Flick.pressAt = -math.huge
        latch = true
    else
        local move = flat(hum.MoveDirection)
        if not move or move:Dot(wall.into) < 0.3 then return end
        if not atSeam then return end
        if Flick.lastSeam and math.abs(nearest - Flick.lastSeam) < SAME_SEAM and now - Flick.lastSeamAt < SAME_SEAM_TIME then return end
        Flick.lastSeam, Flick.lastSeamAt = nearest, now
        latch = false
    end

    startFlick(hum, root, wallSign(root, wall), Settings.Angle, Settings.Method, latch, "wall")
    if Flick.active and Flick.method ~= "Camera" then silentStep(dt, now) end
    -- a quick tap may already be let go of by the time the turn lands you
    latchJump(hum)
end

--// Wiring ---------------------------------------------------------------------------
local stopped = false
local warned = false

local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not warned then
        warned = true
        warn("[WallHop] " .. tostring(err))
    end
end

local function watchHumanoid(hum)
    track(hum.StateChanged:Connect(function(old, new)
        if Flick.hopped or not (AIRBORNE[old] or old == CLIMBING) or not LANDING[new] then return end
        if Flick.active or os.clock() - Flick.endedAt < 0.05 then
            Flick.hopped = true
            Flick.hops = Flick.hops + 1
            Flick.chain = Flick.chain + 1
        end
    end))
end

local function onCharacter(char)
    finishFlick()
    filterAt = -math.huge
    Flick.chain = 0
    local hum = char:WaitForChild("Humanoid", 10)
    if hum and not stopped then watchHumanoid(hum) end
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    task.spawn(onCharacter, char)
end))
if LocalPlayer.Character then task.spawn(onCharacter, LocalPlayer.Character) end

track(UserInputService.JumpRequest:Connect(function()
    local now = os.clock()
    local fresh = now - Flick.lastRequest > PRESS_GAP
    Flick.lastRequest = now
    if not fresh then return end
    local _, hum = character()
    if not hum then return end
    local state = hum:GetState()
    if state == CLIMBING then
        if Ladder.Enabled then Flick.ladderPressAt = now end
    elseif Settings.Enabled and Settings.When == "On jump press" and AIRBORNE[state] then
        -- a press on the ground is just a jump
        Flick.pressAt = now
    end
end))

track(PreSimulation:Connect(function(a, b)
    -- PreSimulation passes the step; the legacy Stepped passes (time, step)
    local dt = type(b) == "number" and b or a
    if type(dt) ~= "number" or dt <= 0 then dt = 1 / 60 end
    guarded(step, dt)
end))

track(PostSimulation:Connect(function()
    if Flick.active and Flick.method == "Silent" and not Flick.visible and Flick.saved then
        guarded(silentRestore)
        -- landed already: done, unless you asked for a set time
        if Flick.hopped and Settings.HoldBy ~= "Milliseconds" then finishFlick() end
    end
end))

pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
    dt = type(dt) == "number" and dt > 0 and dt or 1 / 60
    -- a Camera or Keys flick turns the camera itself, and its turn back can land
    -- a frame after it ends
    local ours = Flick.method ~= "Silent" and (Flick.active or os.clock() - Flick.endedAt < 0.1)
    guarded(Turn.measure, dt, ours)
    if Flick.active and Flick.method == "Camera" then guarded(cameraStep, dt, os.clock()) end
end)

local function shutdown()
    if stopped then return end
    stopped = true
    Settings.Enabled = false
    Ladder.Enabled = false
    finishFlick()
    for i = #Connections, 1, -1 do
        pcall(function() Connections[i]:Disconnect() end)
        Connections[i] = nil
    end
    pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
    if Window then pcall(function() Window:Destroy() end) end
    if Genv.__WallHopStop == shutdown then Genv.__WallHopStop = nil end
end
Genv.__WallHopStop = shutdown
Genv.WallHop = { Settings = Settings, Ladder = Ladder, Flick = Flick, Turn = Turn, Unload = shutdown }

--// UI -------------------------------------------------------------------------------
-- Onyx, loaded straight from the library repo. Resolving the latest commit
-- first means a fresh copy every load instead of the up-to-5-minute raw cache;
-- if the API call is blocked it falls back to the main branch.
local Onyx
do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Onyx] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/Ui.lua'):format(ref)
    Onyx = loadstring(game:HttpGet(url))()
end

Window = Onyx:CreateWindow({
    Title = 'wall hop',
    SubTitle = 'helper',
    Folder = 'WallHop',
    -- not RightShift, so it does not open and close with the hub
    Keybind = Enum.KeyCode.RightControl,
    Accent = Color3.fromRGB(90, 170, 255),
})

notify = function(content, kind)
    Onyx:Notify({ Title = 'wall hop', Content = content, Type = kind or 'info', Duration = 5 })
end

local function toggle(section, title, description, flag, owner, key, changed)
    section:Toggle({
        Title = title,
        Description = description,
        Default = owner[key],
        Flag = flag,
        Callback = function(v)
            v = v == true
            if owner[key] == v then return end
            owner[key] = v
            if changed then changed(v) end
        end,
    })
end

local function slider(section, title, description, flag, owner, key, low, high, increment, suffix)
    section:Slider({
        Title = title,
        Description = description,
        Min = low,
        Max = high,
        Increment = increment,
        Default = owner[key],
        Suffix = suffix,
        Flag = flag,
        Callback = function(v)
            if type(v) == "number" then owner[key] = v end
        end,
    })
end

local function pick(section, title, description, flag, owner, key, values, changed)
    section:Dropdown({
        Title = title,
        Description = description,
        Values = values,
        Default = owner[key],
        Flag = flag,
        Callback = function(v)
            if type(v) ~= "string" or owner[key] == v then return end
            finishFlick()
            owner[key] = v
            if changed then changed(v) end
        end,
    })
end

local function keysCheck(v)
    if v == 'Keys' and not VirtualInputManager then
        notify('Your executor has no VirtualInputManager, so Keys cannot press anything. Use Silent or Camera.', 'warning')
    end
end

--// wall hop tab
local WallTab = Window:CreateTab({ Title = 'wall hop' })

local FlickSection = WallTab:CreateSection('auto flick')
toggle(FlickSection, 'auto flick', 'turns you into the wall and back for you, so a held jump goes off again', 'wh_enabled', Settings, 'Enabled',
    function(v) if not v then finishFlick() end end)
pick(FlickSection, 'method', 'silent turns your character, camera turns the camera (shift lock or first person), keys presses , and .', 'wh_method', Settings, 'Method', { 'Silent', 'Camera', 'Keys' }, keysCheck)
pick(FlickSection, 'when', 'on jump press flicks as you press jump by a wall; at seam flicks by itself while you push into the wall', 'wh_when', Settings, 'When', { 'On jump press', 'At seam' })
pick(FlickSection, 'direction', nil, 'wh_direction', Settings, 'Direction', { 'Away from wall', 'Left', 'Right', 'Alternate' })
slider(FlickSection, 'angle', nil, 'wh_angle', Settings, 'Angle', 15, 90, 5, ' deg')
slider(FlickSection, 'seam height (at seam)', 'how far up your legs the seam is when it flicks', 'wh_seam_height', Settings, 'SeamHeight', 0, 100, 5, '%')

local RotationSection = WallTab:CreateSection('rotation')
toggle(RotationSection, 'visible rotation', 'turns where it can be seen, at the speed below, instead of in a single step (silent and camera)', 'wh_visible', Settings, 'Visible')
slider(RotationSection, 'rotation speed', nil, 'wh_speed', Settings, 'Speed', 60, 3000, 10, ' deg/s')
toggle(RotationSection, 'sync with mobile rotation speed', 'turns as fast as you really turn your own camera, measured from your swipes, instead of the slider above. the randomizer still applies', 'wh_sync_mobile', Settings, 'SyncMobile')
toggle(RotationSection, 'randomize speed', nil, 'wh_random_speed', Settings, 'RandomSpeed')
slider(RotationSection, 'speed randomness', 'how far either side of the speed each flick may land', 'wh_speed_random', Settings, 'SpeedRandom', 0, 1500, 10, ' deg/s')
toggle(RotationSection, 'turn back visibly', 'with visible rotation, turns back at the same speed instead of snapping back', 'wh_turn_back', Settings, 'TurnBackVisible')

local HoldSection = WallTab:CreateSection('hold')
pick(HoldSection, 'hold by', 'how long it stays turned before turning back', 'wh_hold_by', Settings, 'HoldBy', { 'Frames', 'Milliseconds', 'Until it lands' })
slider(HoldSection, 'hold frames', nil, 'wh_hold_frames', Settings, 'HoldFrames', 1, 12, 1, ' frames')
slider(HoldSection, 'hold time', nil, 'wh_hold_ms', Settings, 'HoldMs', 10, 500, 5, ' ms')
toggle(HoldSection, 'randomize hold', nil, 'wh_random_hold', Settings, 'RandomHold')
slider(HoldSection, 'hold randomness', 'how far either side of the hold each flick may land', 'wh_hold_random', Settings, 'HoldRandom', 0, 200, 5, ' ms')

local LegitSection = WallTab:CreateSection('legit')
slider(LegitSection, 'reaction delay', 'waits this long before turning, like a person would', 'wh_reaction', Settings, 'Reaction', 0, 400, 5, ' ms')
slider(LegitSection, 'reaction randomness', nil, 'wh_reaction_random', Settings, 'ReactionRandom', 0, 200, 5, ' ms')
slider(LegitSection, 'angle randomness', nil, 'wh_angle_random', Settings, 'AngleRandom', 0, 30, 1, ' deg')
slider(LegitSection, 'miss chance', 'leaves this share of flicks out on purpose', 'wh_miss', Settings, 'Miss', 0, 50, 1, '%')
slider(LegitSection, 'min time between hops', nil, 'wh_min_gap', Settings, 'MinGap', 0, 1500, 10, ' ms')
slider(LegitSection, 'max hops in a row', 'then it waits for you to touch the floor. 0 = no limit', 'wh_max_hops', Settings, 'MaxHops', 0, 30, 1, '')
toggle(LegitSection, 'only flick at seams', 'on jump press waits up to a third of a second for a seam instead of flicking a plain wall', 'wh_only_seams', Settings, 'OnlySeams')
toggle(LegitSection, 'need a held jump', 'does not keep your jump press for you: you have to be holding jump when the turn lands', 'wh_held_jump', Settings, 'NeedHeldJump')

local StatusSection = WallTab:CreateSection('status')
local StatusLabel = StatusSection:Label('wall -  |  seam -  |  flicks 0  |  hops 0')
local TurnLabel = StatusSection:Label('turn speed -')
StatusSection:Button({ Title = 'unload', Callback = shutdown })

--// ladder flick tab
local LadderTab = Window:CreateTab({ Title = 'ladder flick' })

local LadderSection = LadderTab:CreateSection('ladder flick')
toggle(LadderSection, 'ladder flick', 'flicks while you climb a ladder or truss so the jump goes off a rung', 'lf_enabled', Ladder, 'Enabled',
    function(v) if not v then finishFlick() end end)
pick(LadderSection, 'when', 'on jump press flicks as you press jump while climbing; auto climb keeps flicking up it while you climb; truss top flicks your jump at the top of a truss', 'lf_when', Ladder, 'When', { 'On jump press', 'Auto climb', 'Truss top' })
pick(LadderSection, 'method', nil, 'lf_method', Ladder, 'Method', { 'Silent', 'Camera', 'Keys' }, keysCheck)
pick(LadderSection, 'direction', nil, 'lf_direction', Ladder, 'Direction', { 'Alternate', 'Left', 'Right' })
slider(LadderSection, 'angle', nil, 'lf_angle', Ladder, 'Angle', 15, 90, 5, ' deg')
slider(LadderSection, 'auto climb interval', 'time between flicks while auto climbing', 'lf_interval', Ladder, 'Interval', 100, 1000, 10, ' ms')
LadderSection:Label('Uses the rotation, hold and legit settings from the wall hop tab. Works best on R6 and on ladders built from separate rungs; for a truss flick, climb to the top of a truss with a part over it.')
local LadderLabel = LadderSection:Label('not climbing')

task.spawn(function()
    while not stopped do
        local fresh = os.clock() - Flick.seenAt < 1
        local wall = fresh and Flick.wall and ('%.1f'):format(math.max(0, Flick.wall)) or '-'
        local seam = fresh and Flick.seam and ((Flick.seam >= 0 and '+' or '') .. ('%.1f'):format(Flick.seam)) or '-'
        pcall(function()
            StatusLabel:SetText(('wall %s  |  seam %s  |  flicks %d  |  hops %d  |  left out %d'):format(
                wall, seam, Flick.flicks, Flick.hops, Flick.skipped))
            local mobile = ('%d deg/s%s'):format(math.floor(Turn.speed() + 0.5), #Turn.peaks == 0 and ' (default)' or '')
            TurnLabel:SetText(('turn speed %s  |  your swipes %s'):format(
                Flick.lastSpeed and ('%d deg/s'):format(math.floor(Flick.lastSpeed + 0.5)) or '-', mobile))
            local _, hum = character()
            local climbing = hum and hum:GetState() == CLIMBING
            LadderLabel:SetText(climbing and (Ladder.Enabled and 'climbing, ready' or 'climbing, ladder flick is off') or 'not climbing')
        end)
        task.wait(0.25)
    end
end)

notify('Loaded. Turn on auto flick or ladder flick to start.', 'success')

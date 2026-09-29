--// Wall Hop -------------------------------------------------------------------------
-- A wall hop helper for any game. It runs on its own, outside the hub:
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Universal/WallHop.lua'))()
--
-- A wall hop only works where two parts meet: blocks stacked with no gap, or the
-- top edge of a wall. When your legs are level with that seam and you turn about
-- 45 degrees and straight back, a corner of your character swings into the wall.
-- The humanoid's ground check then starts inside the upper part, finds the top of
-- the lower one and counts you as landed, so a held jump goes off again.
--
-- Auto flick does that turn for you, three ways:
--   Silent  turns your character only while physics runs and turns it back
--           before the frame is drawn, so your camera never moves.
--   Camera  turns the camera and back the way a player flicks. Your character
--           only follows it in shift lock or first person.
--   Keys    presses , and . (Roblox's 45 degree camera keys) the way the public
--           wall hop macro does.
--
-- And two ways to time it:
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
    Method = "Silent",           -- Silent / Camera / Keys
    When = "On jump press",      -- On jump press / At seam
    Direction = "Away from wall", -- Away from wall / Left / Right / Alternate
    Angle = 45,                  -- degrees
    Hold = 2,                    -- frames the turn is held
    SeamHeight = 30,             -- At seam: how far up your legs the seam is when it flicks, in %
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
local FLICK_TIMEOUT = 0.5   -- a flick that has not finished by now is ended

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

--// Flick ----------------------------------------------------------------------------
local Flick = {
    active = false,
    method = nil,
    sign = 1,              -- +1 turns left, -1 turns right
    turn = 0,              -- radians, signed
    frames = 0,            -- frames of the turn still to run
    turned = false,        -- Camera/Keys: the camera is turned right now
    saved = nil,           -- Silent: your rotation before this physics step's turn
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
    pressAt = -math.huge,
    lastRequest = -math.huge,
    flicks = 0,
    hops = 0,
    wall = nil,            -- for the status line
    seam = nil,
    seenAt = -math.huge,
}

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

local function nextAlternate()
    Flick.alternate = -Flick.alternate
    return Flick.alternate
end

local function chooseSign(root, wall)
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

local function finishFlick()
    if not Flick.active then return end
    local hum, root = Flick.hum, Flick.root
    if Flick.method == "Silent" then
        if Flick.saved and root and root.Parent then
            root.CFrame = CFrame.new(root.Position) * Flick.saved
        end
        if Flick.autoRotate ~= nil and hum then hum.AutoRotate = Flick.autoRotate end
    elseif Flick.method == "Camera" then
        if Flick.turned then turnCamera(-Flick.turn) end
    elseif Flick.method == "Keys" then
        if Flick.turned then tapKey(flickKey(-Flick.sign)) end
    end
    Flick.saved = nil
    Flick.autoRotate = nil
    Flick.turned = false
    Flick.active = false
    Flick.endedAt = os.clock()
end

local function startFlick(hum, root, wall, latch)
    if Settings.Method == "Keys" and not VirtualInputManager then return end
    Flick.active = true
    Flick.method = Settings.Method
    Flick.sign = chooseSign(root, wall)
    Flick.turn = math.rad(Settings.Angle) * Flick.sign
    Flick.frames = math.max(1, math.floor(Settings.Hold + 0.5))
    Flick.turned = false
    Flick.saved = nil
    Flick.autoRotate = nil
    Flick.hum, Flick.root = hum, root
    Flick.latch = latch
    Flick.hopped = false
    Flick.startedAt = os.clock()
    Flick.flicks = Flick.flicks + 1
    -- a quick tap may already be let go of by the time the turn lands you
    if latch then hum.Jump = true end
    if Flick.method == "Keys" then
        tapKey(flickKey(Flick.sign))
        Flick.turned = true
    end
end

-- Silent, before each physics step of the flick: turn. Physics runs the ground
-- check with you turned.
local function silentTurn()
    local hum, root = Flick.hum, Flick.root
    if not root or not root.Parent then return finishFlick() end
    if Flick.autoRotate == nil then
        -- the humanoid would otherwise turn you straight back mid-step
        Flick.autoRotate = hum.AutoRotate
        hum.AutoRotate = false
    end
    local cf = root.CFrame
    Flick.saved = cf - cf.Position
    root.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, Flick.turn, 0) * Flick.saved
end

-- Silent, after the step: turn back before anything is drawn, and keep wherever
-- physics moved you.
local function silentRestore()
    local root = Flick.root
    if Flick.saved and root and root.Parent then
        root.CFrame = CFrame.new(root.Position) * Flick.saved
        local spin = root.AssemblyAngularVelocity
        root.AssemblyAngularVelocity = Vector3.new(0, spin.Y, 0)
    end
    Flick.saved = nil
    Flick.frames = Flick.frames - 1
    if Flick.frames <= 0 or Flick.hopped then finishFlick() end
end

-- Camera and Keys, each frame right after the camera updates. The character
-- turns to the camera in the physics step that follows.
local function cameraStep()
    if Flick.method == "Camera" and not Flick.turned then
        turnCamera(Flick.turn)
        Flick.turned = true
        return
    end
    Flick.frames = Flick.frames - 1
    if Flick.frames <= 0 or Flick.hopped then finishFlick() end
end

local function step(dt)
    local _, hum, root = character()
    local now = os.clock()

    if Flick.active then
        if not hum or hum ~= Flick.hum or not Settings.Enabled or now - Flick.startedAt > FLICK_TIMEOUT then
            finishFlick()
            return
        end
        if Flick.latch then hum.Jump = true end
        if Flick.method == "Silent" then silentTurn() end
        return
    end

    if not Settings.Enabled or not hum then return end
    if not AIRBORNE[hum:GetState()] then
        Flick.pressAt = -math.huge
        return
    end

    refreshFilter()
    local wall = findWall(hum, root)
    if not wall then return end

    local leg, feet = legLength(hum), feetY(hum, root)
    local vy = root.AssemblyLinearVelocity.Y
    -- Camera and Keys turn you a frame later than Silent does
    local lead = Settings.Method == "Silent" and 0 or 1
    local target = feet + vy * dt * lead + leg * Settings.SeamHeight / 100
    local nearest
    for _, seam in ipairs(findSeams(root, wall, feet - SCAN_BELOW, feet + leg + SCAN_ABOVE)) do
        if not nearest or math.abs(seam - target) < math.abs(nearest - target) then nearest = seam end
    end
    Flick.wall, Flick.seam, Flick.seenAt = wall.gap, nearest and nearest - feet, now

    if now - Flick.endedAt < COOLDOWN then return end

    if Settings.When == "On jump press" then
        if now - Flick.pressAt > PRESS_WINDOW then return end
        Flick.pressAt = -math.huge
        startFlick(hum, root, wall, true)
    else
        local move = flat(hum.MoveDirection)
        if not move or move:Dot(wall.into) < 0.3 then return end
        local tolerance = math.max(0.1, math.abs(vy) * dt / 2 + 0.05)
        if not nearest or math.abs(nearest - target) > tolerance then return end
        if Flick.lastSeam and math.abs(nearest - Flick.lastSeam) < SAME_SEAM and now - Flick.lastSeamAt < SAME_SEAM_TIME then return end
        Flick.lastSeam, Flick.lastSeamAt = nearest, now
        startFlick(hum, root, wall, false)
    end

    if Flick.active and Flick.method == "Silent" then silentTurn() end
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
        if Flick.hopped or not AIRBORNE[old] or not LANDING[new] then return end
        if Flick.active or os.clock() - Flick.endedAt < 0.05 then
            Flick.hopped = true
            Flick.hops = Flick.hops + 1
        end
    end))
end

local function onCharacter(char)
    finishFlick()
    filterAt = -math.huge
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
    if not fresh or not Settings.Enabled or Settings.When ~= "On jump press" then return end
    local _, hum = character()
    -- a press on the ground is just a jump
    if hum and AIRBORNE[hum:GetState()] then Flick.pressAt = now end
end))

track(PreSimulation:Connect(function(a, b)
    -- PreSimulation passes the step; the legacy Stepped passes (time, step)
    local dt = type(b) == "number" and b or a
    if type(dt) ~= "number" or dt <= 0 then dt = 1 / 60 end
    guarded(step, dt)
end))

track(PostSimulation:Connect(function()
    if Flick.active and Flick.method == "Silent" and Flick.saved then guarded(silentRestore) end
end))

pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function()
    if Flick.active and Flick.method ~= "Silent" then guarded(cameraStep) end
end)

local function shutdown()
    if stopped then return end
    stopped = true
    Settings.Enabled = false
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

--// UI -------------------------------------------------------------------------------
-- Void (VoidUI), loaded straight from the library repo. Resolving the latest
-- commit first means a fresh copy every load instead of the up-to-5-minute raw
-- cache; if the API call is blocked it falls back to the main branch.
local Void
do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Void] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/VoidUI.lua'):format(ref)
    Void = loadstring(game:HttpGet(url))()
end

Window = Void:CreateWindow({
    Title = 'Wall Hop',
    SubTitle = 'helper',
    -- not RightShift, so it does not open and close with the hub
    Keybind = Enum.KeyCode.RightControl,
    Scope = 'universal',
    Status = 'off',
    StartOpen = true,
    Opener = 'Topbar',
})

notify = function(content, warnColour)
    Void:Notify({ Title = 'Wall Hop', Content = content, Duration = 5, Warn = warnColour == true })
end

-- Callbacks act only on a real change, so a call the UI may make at load with
-- the default does nothing.
local function pick(section, title, flag, setting, values, half, changed)
    section:Dropdown({
        Title = title,
        Values = values,
        Default = Settings[setting],
        Flag = flag,
        Half = half,
        Callback = function(v)
            if type(v) ~= "string" or Settings[setting] == v then return end
            finishFlick()
            Settings[setting] = v
            if changed then changed(v) end
        end,
    })
end

local function slider(section, title, flag, setting, low, high, increment, suffix)
    section:Slider({
        Title = title,
        Flag = flag,
        Min = low,
        Max = high,
        Increment = increment,
        Rounding = 0,
        Default = Settings[setting],
        Suffix = suffix,
        Callback = function(v)
            if type(v) == "number" then Settings[setting] = v end
        end,
    })
end

local Tab = Window:CreateTab('wall hop')

local FlickSection = Tab:CreateSection('auto flick')
FlickSection:Toggle({
    Title = 'auto flick',
    Flag = 'wh_enabled',
    Default = Settings.Enabled,
    Callback = function(v)
        if Settings.Enabled == v then return end
        Settings.Enabled = v
        if not v then finishFlick() end
        pcall(function() Window:SetStatus(v and 'on' or 'off') end)
    end,
})
pick(FlickSection, 'method', 'wh_method', 'Method', { 'Silent', 'Camera', 'Keys' }, true, function(v)
    if v == 'Keys' and not VirtualInputManager then
        notify('Your executor has no VirtualInputManager, so Keys cannot press anything. Use Silent or Camera.', true)
    end
end)
pick(FlickSection, 'when', 'wh_when', 'When', { 'On jump press', 'At seam' }, true)
pick(FlickSection, 'direction', 'wh_direction', 'Direction', { 'Away from wall', 'Left', 'Right', 'Alternate' }, false)
slider(FlickSection, 'angle', 'wh_angle', 'Angle', 15, 90, 5, ' deg')
slider(FlickSection, 'hold', 'wh_hold', 'Hold', 1, 4, 1, ' frames')
slider(FlickSection, 'seam height (at seam)', 'wh_seam_height', 'SeamHeight', 0, 100, 5, '%')

local InfoSection = Tab:CreateSection('how to use')
InfoSection:Paragraph({
    Title = 'wall hops',
    Content = 'They only work where two parts meet, like stacked blocks or the top of a wall. Face the wall and jump. On jump press: press jump again as your legs reach a seam. At seam: push toward the wall and hold jump. Silent works with any camera, Camera needs shift lock or first person, Keys needs the default Roblox camera.',
})
local StatusLabel = InfoSection:Label('wall -  |  seam -  |  flicks 0  |  hops 0')
InfoSection:Button({
    Title = 'unload',
    Callback = shutdown,
})

task.spawn(function()
    while not stopped do
        local fresh = os.clock() - Flick.seenAt < 1
        local wall = fresh and Flick.wall and ('%.1f'):format(math.max(0, Flick.wall)) or '-'
        local seam = fresh and Flick.seam and ((Flick.seam >= 0 and '+' or '') .. ('%.1f'):format(Flick.seam)) or '-'
        pcall(function()
            StatusLabel:SetText(('wall %s  |  seam %s  |  flicks %d  |  hops %d'):format(wall, seam, Flick.flicks, Flick.hops))
        end)
        task.wait(0.25)
    end
end)

notify('Loaded. Turn on auto flick, then face a wall made of stacked parts.')

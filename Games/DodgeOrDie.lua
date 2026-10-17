--// Dodge or Die -- auto dodge (presimulated), ball ESP, godmode, rewards,
--// anti-AFK.
--
-- Built against a script dump of the live game (place 131794278839305, game
-- 9845585365, version 5299). What the game's own client scripts show:
--  * Balls are parts in Workspace.Balls. Each homes onto its target with an
--    AlignPosition whose Attachment1 is the target's RootAttachment, and gets
--    a short "miss boost" push along its velocity once it has flown past.
--  * Hits are detected on the client: PlayerScripts.GamePlay's two
--    HitDetectionLocalScripts check every frame for a ball touching your
--    limbs and send ClientBallHit:FireServer(ball).
--  * A dash is DashHandler's doDash(Left / Right / Forward): it sends
--    MovementGrace:FireServer("Dash" .. dir) and sets the root's horizontal
--    velocity to (Upgrades.Dashes effective + 120) on the ground, + 50 in the
--    air, along -Right / Right / Look. Cooldowns are 0.75s left and right, 2s
--    forward (less with the Dash Accelerator tool). On mobile the game's own
--    Left / Right / Forward buttons call that same function.
--  * Remotes are all renamed to their class name; safe-net.get(name) finds
--    them by an encrypted name table. The folder of balls is renamed to
--    "Lobby" after 10 seconds, and every ball to "Part".
--  * Anti cheat: CLIENT_ANTI kicks ("VIM") the moment VirtualInputManager or
--    VirtualUser exists as a service, so nothing here ever touches either.
--    DetectionScript reports known hub GUIs by name, so this one's menu uses
--    its own names only.
--
--  * The hit check (HitDetectionLocalScript) is GetPartBoundsInRadius at the
--    ball's centre, radius half its size less 0.15, against every part of
--    your character. Any ball counts, not only the one after you.
--  * The ball is pulled by its AlignPosition, held up by its VectorForce, and
--    pushed on by MissBoostForce once it flies past.
--
-- Auto dodge: every frame the balls that can reach you are played forward with
-- the limits read off their own AlignPosition (and what is left measured from
-- how they move) against your body as the game measures it. It tries a side
-- dash at 24 angles, turning you first since the game dashes along your
-- facing, never the slow forward roll, checking walls and edges, and dashes at
-- the last safe moment with a buffer for frame drops. With both dashes
-- recharging it walks or jumps you clear. It times your own dashes to keep its
-- model of them right. All work per frame is bounded, nothing yields in the
-- frame loop and a ball sitting on you costs nothing extra.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__DodgeOrDieStop) == "function" then pcall(Genv.__DodgeOrDieStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end


--// settings ----------------------------------------------------------------

local Dodge = {
    Enabled = false,
    Method = "Auto",          -- Auto / Game buttons / Script dash
    Mode = "Last moment",     -- Last moment / Early
    SafetyBuffer = 0.08,      -- s: dashes this much before the last possible moment
    EarlyWindow = 0.3,        -- s before impact, in early mode
    Margin = 1.0,             -- studs of room a dodge should leave
    Horizon = 1.0,            -- s of ball flight played forward
    Directions = 24,          -- angles tried around you
    KeepHeading = 0.6,        -- how much it prefers dodging the way you were going
    WallCheck = true,         -- don't dash into walls
    VoidCheck = true,         -- don't dash off the edge
    WatchMovement = true,     -- play your own path forward along where you are steering
    OtherBalls = true,        -- also dodge balls after someone else that pass through you
    Steer = true,             -- walk / jump clear while both dashes recharge
    SteerWindow = 0.6,        -- s before impact it may take over your movement
    Jump = true,              -- jumping is one of the ways out it may use
    Practice = true,          -- also dodge practice-area balls
}

local Esp = {
    Enabled = false,
    Target = true, Distance = true, Speed = true,
    Warning = true,           -- big warning when a ball is after you
}

local God = { Enabled = false }

local Misc = { AutoDaily = false, AutoQuests = false, AntiAfk = true }

local Stats = { Dodges = 0, Status = "idle", Threat = nil, Method = "-" }

--// helpers -----------------------------------------------------------------

local Library -- Ui3, loaded last
local Log
local PendingLog = {}
local LOG_COLORS = {
    Info = Color3.fromRGB(150, 200, 255),
    Success = Color3.fromRGB(126, 217, 87),
    Warn = Color3.fromRGB(255, 200, 90),
    Error = Color3.fromRGB(255, 96, 106),
}

local function log(kind, ...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    local text = table.concat(parts, " ", 1, parts.n)
    if not Log then
        PendingLog[#PendingLog + 1] = { text, LOG_COLORS[kind] }
        return
    end
    pcall(function() Log:Log(text, LOG_COLORS[kind]) end)
end

local function myCharacter()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function safeRequire(...)
    local node = ReplicatedStorage
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
    end
    if not node or not node:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, node)
    return ok and result or nil
end

local Upgrades = safeRequire("Modules", "UpgradesSharedModule")
local ToolsShared = safeRequire("Modules", "ToolsSharedModule")

--// remotes -----------------------------------------------------------------
-- safe-net.get refuses callers whose function environments carry metatables
-- (an executor's do), so it is called from a fresh coroutine running a
-- function with a plain environment table: the only frames it can see are
-- its own and that one.

local SafeNet = safeRequire("Packages", "safe-net")
local RemoteCache = {}

local function remote(name)
    if RemoteCache[name] ~= nil then return RemoteCache[name] or nil end
    if type(SafeNet) ~= "table" or type(SafeNet.get) ~= "function" then return nil end
    local get = SafeNet.get
    local function fetch() return get(name) end
    if typeof(setfenv) == "function" then pcall(setfenv, fetch, {}) end
    local co = coroutine.create(fetch)
    local ok, result = coroutine.resume(co)
    if not (ok and typeof(result) == "Instance") then
        ok, result = pcall(get, name)
    end
    local found = ok and typeof(result) == "Instance" and result or nil
    RemoteCache[name] = found or false
    return found
end

--// balls -------------------------------------------------------------------

-- The folder of balls, found by what it holds: it gets renamed to "Lobby",
-- the same name as the lobby map, a few seconds into the game.
local BallFolder = Workspace:FindFirstChild("Balls")
local NextFolderScan = 0

local function isMapLobby(folder)
    return folder:FindFirstChild("PracticeArea") ~= nil or folder:FindFirstChild("ToolCratesArea") ~= nil
end

local function ballFolder()
    if BallFolder and BallFolder.Parent == Workspace then return BallFolder end
    if os.clock() < NextFolderScan then return nil end
    NextFolderScan = os.clock() + 2
    for _, child in ipairs(Workspace:GetChildren()) do
        if (child.Name == "Balls" or child.Name == "Lobby") and child:IsA("Folder") and not isMapLobby(child) then
            BallFolder = child
            return child
        end
    end
    return nil
end

local PracticeBalls = nil
local function practiceFolder()
    if PracticeBalls and PracticeBalls.Parent then return PracticeBalls end
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == "Lobby" and isMapLobby(child) then
            local area = child:FindFirstChild("PracticeArea")
            PracticeBalls = area and area:FindFirstChild("PracticeBalls")
            return PracticeBalls
        end
    end
    return nil
end

local function ballTarget(ball)
    local align = ball:FindFirstChild("AlignPosition")
    local attachment = align and align.Attachment1
    return attachment and attachment.Parent and attachment.Parent.Parent or nil, align
end

local function targetsMe(ball, root)
    local align = ball:FindFirstChild("AlignPosition")
    return align ~= nil and align.Attachment1 ~= nil and align.Attachment1.Parent == root
end

--// ball model ----------------------------------------------------------------
-- Each ball is pulled at its target's RootAttachment by an AlignPosition. The
-- limits set on that constraint (top speed, force, responsiveness) are read
-- straight off it, and what it leaves open is measured from the ball's own
-- motion, so the simulation moves the ball the way it really moves.

local SIM_STEP = 1 / 120
local MAX_STEPS = 160

local BallInfo = setmetatable({}, { __mode = "k" })

local function finite(x, cap)
    return type(x) == "number" and x > 0 and x < cap
end

local function readProp(obj, prop)
    local ok, value = pcall(function() return obj[prop] end)
    if ok then return value end
    return nil
end

local function ballInfo(ball, now)
    local info = BallInfo[ball]
    local vel = ball.AssemblyLinearVelocity
    if not info then
        info = { Vel = vel, At = now, Top = math.max(vel.Magnitude, 25), SeenAccel = 0, Grav = 0 }
        BallInfo[ball] = info
    end
    if not info.Read or now - info.Read > 0.5 then
        info.Read = now
        local mass = ball.AssemblyMass
        if not (mass and mass > 0) then mass = 1 end
        local align = ball:FindFirstChild("AlignPosition")
        if align then
            local maxVel = readProp(align, "MaxVelocity")
            local maxForce = readProp(align, "MaxForce")
            local resp = readProp(align, "Responsiveness")
            info.MaxVel = finite(maxVel, 1e5) and maxVel or nil
            info.ForceAccel = finite(maxForce, 1e8) and maxForce / mass or nil
            info.Resp = finite(resp, 1e4) and resp or nil
            info.Rigid = readProp(align, "RigidityEnabled") == true
        end
        -- the ball's own VectorForce holds it up against gravity
        local lift = 0
        for _, child in ipairs(ball:GetChildren()) do
            if child:IsA("VectorForce") and child.Name ~= "MissBoostForce" and child.Enabled then
                local force = readProp(child, "Force")
                if typeof(force) == "Vector3" then lift += force.Y end
            end
        end
        info.Grav = math.max(Workspace.Gravity - lift / mass, 0)
        local size = ball.Size
        -- the game's own hit check: a sphere this big against your parts' bounds
        info.Radius = math.max(math.max(size.X, size.Y, size.Z) * 0.5 - 0.15, 0.3)
    end
    local dt = now - info.At
    if dt >= 1 / 240 then
        local accel = (vel - info.Vel).Magnitude / dt
        info.Top = math.max(info.Top * 0.998, vel.Magnitude)
        if accel < 4000 then info.SeenAccel = math.max(info.SeenAccel * 0.995, accel) end
        info.Vel, info.At = vel, now
    end
    return info
end

-- what the simulation uses for a ball
local function ballParams(info)
    local vmax = info.MaxVel or info.Top
    local amax
    if info.Rigid then
        amax = 5000
    elseif info.ForceAccel then
        amax = info.ForceAccel
    else
        amax = math.max(info.SeenAccel, 40)
    end
    return { VMax = math.max(vmax, 10), AMax = amax, Resp = info.Resp, Grav = info.Grav, Radius = info.Radius or 1 }
end

local function stepBall(pos, vel, goal, p, dt)
    local to = goal - pos
    local dist = to.Magnitude
    if dist > 1e-3 then
        local want = p.VMax
        if p.Resp then want = math.min(want, dist * p.Resp) end
        local dv = to * (want / dist) - vel
        local cap = p.AMax * dt
        local m = dv.Magnitude
        if m > cap then dv *= cap / m end
        vel += dv
    end
    if p.Grav > 0 then vel -= Vector3.new(0, p.Grav * dt, 0) end
    return pos + vel * dt, vel
end

--// your body ------------------------------------------------------------------
-- The game counts a hit when the ball's sphere touches the bounds of any part
-- of your character, accessories included. Those bounds, measured around your
-- root as a cylinder, are what the simulation checks against.

local Body = { R = 1.6, Low = -3, High = 2.5, At = 0 }

local function measureBody(char, root)
    if os.clock() - Body.At < 0.5 then return end
    Body.At = os.clock()
    local r, low, high = 1, -2.5, 2
    local rootPos = root.Position
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "VFXPart" then
            local offset = part.Position - rootPos
            local half = part.Size * 0.5
            local flatReach = Vector3.new(offset.X, 0, offset.Z).Magnitude + math.max(half.X, half.Z)
            if flatReach < 4 then r = math.max(r, flatReach) end
            local reachY = math.max(half.X, half.Y, half.Z)
            if math.abs(offset.Y) < 6 then
                low = math.min(low, offset.Y - reachY)
                high = math.max(high, offset.Y + reachY)
            end
        end
    end
    Body.R, Body.Low, Body.High = math.min(r, 2.6), low, high
end

-- how far the ball's surface is from your body with your root at p; 0 or less
-- is a hit
local function bodyGap(ballPos, p, radius)
    local dy = ballPos.Y - p.Y
    local vertical = 0
    if dy < Body.Low then
        vertical = Body.Low - dy
    elseif dy > Body.High then
        vertical = dy - Body.High
    end
    local horizontal = math.max(Vector3.new(ballPos.X - p.X, 0, ballPos.Z - p.Z).Magnitude - Body.R, 0)
    return math.sqrt(horizontal * horizontal + vertical * vertical) - radius
end

--// dash physics ------------------------------------------------------------------

-- After a dash the game sets your horizontal velocity once and your humanoid
-- walks it back toward your walking pace, close to an exponential settle. Its
-- rate is measured off your own dashes as you make them.
local DashTau = 0.14
local AIR_TAU = 0.3
local WALK_TAU = 0.08

local AIR_STATES = {
    [Enum.HumanoidStateType.Jumping] = true,
    [Enum.HumanoidStateType.Freefall] = true,
    [Enum.HumanoidStateType.FallingDown] = true,
}

-- the game's own airborne test for dashes (DashHandler)
local function isAirborne(hum)
    return hum.FloorMaterial == Enum.Material.Air or AIR_STATES[hum:GetState()] == true
end

local function dashAmount()
    local upgrades = LocalPlayer:FindFirstChild("Upgrades")
    local dashes = upgrades and upgrades:FindFirstChild("Dashes")
    if not (dashes and type(dashes.Value) == "number") then return 0 end
    if Upgrades and type(Upgrades.GetEffectiveAmount) == "function" then
        local ok, effective = pcall(Upgrades.GetEffectiveAmount, dashes.Value)
        if ok and type(effective) == "number" then return effective end
    end
    return dashes.Value
end

-- a side dash's speed, the way DashHandler works it out
local function dashSpeed(hum)
    local amount = dashAmount()
    local char = LocalPlayer.Character
    local speed
    if isAirborne(hum) then
        speed = amount + 50
    else
        speed = amount + 120
        if char and CollectionService:HasTag(char, "Shrunk") then speed *= 0.6 end
    end
    if char and CollectionService:HasTag(char, "Glitch") then speed *= 1.5 end
    return speed
end

local function settle(tau, t)
    return tau * (1 - math.exp(-t / tau))
end

local WallParams = RaycastParams.new()
WallParams.FilterType = Enum.RaycastFilterType.Exclude

local function wallIgnore()
    local ignore = { LocalPlayer.Character }
    local folder = ballFolder()
    if folder then ignore[#ignore + 1] = folder end
    local practice = practiceFolder()
    if practice then ignore[#ignore + 1] = practice end
    WallParams.FilterDescendantsInstances = ignore
end

-- How much of a dash's travel is really open: walls stop it, and with the void
-- check a dash that would leave the floor counts as no room at all.
local function roomFor(root, hum, dir, want)
    local room = want
    if Dodge.WallCheck then
        local hit = Workspace:Raycast(root.Position, dir * want, WallParams)
        if hit then room = math.max((hit.Position - root.Position).Magnitude - 1.5, 0) end
    end
    if Dodge.VoidCheck and room > 4 then
        local land = root.Position + dir * room
        local depth = hum.HipHeight + root.Size.Y / 2 + 12
        if not Workspace:Raycast(land, Vector3.new(0, -depth, 0), WallParams) then
            -- try halfway, else there is no safe room this way
            local half = root.Position + dir * room * 0.5
            if Workspace:Raycast(half, Vector3.new(0, -depth, 0), WallParams) then
                room *= 0.5
            else
                return 0, true
            end
        end
    end
    return room, false
end

--// where you are going ---------------------------------------------------------
-- What you are steering toward (Humanoid.MoveDirection, which follows your
-- keys, stick and camera) and how steadily it is turning, so your own path is
-- played forward along where you are really heading.

local Motion = { Intent = Vector3.zero, Turn = 0, Last = nil }

local function rotateY(v, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return Vector3.new(v.X * c + v.Z * s, 0, -v.X * s + v.Z * c)
end

local function watchMotion(hum, dt)
    local md = flat(hum.MoveDirection)
    if md.Magnitude < 0.05 then
        Motion.Intent, Motion.Last = Vector3.zero, nil
        Motion.Turn *= 0.8
        return
    end
    md = md.Unit
    local last = Motion.Last
    if last and dt > 0 then
        local angle = math.atan2(last.Z * md.X - last.X * md.Z, last:Dot(md))
        if math.abs(angle) > math.rad(40) then
            Motion.Turn = 0
        else
            Motion.Turn += (math.clamp(angle / dt, -8, 8) - Motion.Turn) * 0.25
        end
    end
    Motion.Last, Motion.Intent = md, md
end

-- Your path for the coming steps, shared by every option this frame:
-- Walk[i] is where your walking puts you at step i (curving with your turn,
-- falling with gravity onto the floor below), Settle[i] how much of a velocity
-- change (a dash) has carried you by then.
local Walk, Fall, Settle = {}, {}, {}
local Path = { Tau = DashTau, WalkVel = Vector3.zero, Excess = Vector3.zero, Steps = 0, Here = Vector3.zero }

local function planPath(root, hum, steps)
    local here = root.Position
    local velocity = root.AssemblyLinearVelocity
    local airborne = isAirborne(hum)
    Path.Tau = airborne and AIR_TAU or DashTau
    Path.Here, Path.Steps = here, steps

    local heading, speed, turn
    if Dodge.WatchMovement then
        heading, speed, turn = Motion.Intent, hum.WalkSpeed, Motion.Turn
    else
        local moving = flat(velocity)
        heading = moving.Magnitude > 0.1 and moving.Unit or Vector3.zero
        speed, turn = math.min(moving.Magnitude, hum.WalkSpeed), 0
    end
    Path.WalkVel = heading * speed
    Path.Excess = flat(velocity) - Path.WalkVel

    local floorY = -math.huge
    if airborne then
        local down = Workspace:Raycast(here, Vector3.new(0, -80, 0), WallParams)
        floorY = down and (here.Y - down.Distance + hum.HipHeight + root.Size.Y / 2) or (here.Y - 80)
    end
    local gravity = Workspace.Gravity
    local x, z = 0, 0
    for i = 1, steps do
        local t = i * SIM_STEP
        local dir = heading
        if turn ~= 0 then dir = rotateY(heading, math.clamp(turn * t, -math.pi / 2, math.pi / 2)) end
        x += dir.X * speed * SIM_STEP
        z += dir.Z * speed * SIM_STEP
        local y = 0
        if airborne then y = math.max(floorY - here.Y, velocity.Y * t - 0.5 * gravity * t * t) end
        Walk[i] = Vector3.new(x, 0, z)
        Fall[i] = y
        Settle[i] = settle(Path.Tau, t)
    end
end

--// threats ---------------------------------------------------------------------------

local Threats = {}

-- where a ball's target will be: you along a candidate path, anyone else along
-- their current motion
local function otherGoal(threat, t)
    return threat.GoalPos + threat.GoalVel * t
end

-- Plays every threat forward against a path. Returns the smallest room any
-- ball leaves you (negative: it hits) and the first time one comes within pad.
local function clearance(path, steps, pad)
    pad = pad or 0
    local worst, firstHit = math.huge, nil
    for _, threat in ipairs(Threats) do
        local p = threat.Params
        local pos, vel = threat.Pos, threat.Vel
        for i = 1, steps do
            local t = i * SIM_STEP
            local me = path(i, t)
            local goal = threat.Mine and me or otherGoal(threat, t)
            pos, vel = stepBall(pos, vel, goal, p, SIM_STEP)
            local gap = bodyGap(pos, me, p.Radius)
            if gap < worst then worst = gap end
            if gap <= pad then
                if not firstHit or t < firstHit then firstHit = t end
                if gap <= 0 then break end
            end
        end
    end
    return worst, firstHit
end

local function stayPath(i)
    return Path.Here + Walk[i] + Path.Excess * Settle[i] + Vector3.new(0, Fall[i], 0)
end

-- a dash along dir at speed v0, now
local function dashPath(v0)
    local excess = v0 - Path.WalkVel
    return function(i)
        return Path.Here + Walk[i] + excess * Settle[i] + Vector3.new(0, Fall[i], 0)
    end
end

-- the same dash, made after waiting `wait` seconds on your current path
local function laterDashPath(v0, wait)
    local excess = v0 - Path.WalkVel
    local carried = Path.Excess * settle(Path.Tau, wait)
    return function(i, t)
        if t <= wait then return stayPath(i) end
        return Path.Here + Walk[i] + carried + excess * settle(Path.Tau, t - wait) + Vector3.new(0, Fall[i], 0)
    end
end

-- walking a way instead of where you are going (dashes recharging)
local function walkPath(dir, speed, jumpVel)
    local excess = flat(Path.Excess + Path.WalkVel) - dir * speed
    local gravity = Workspace.Gravity
    return function(i, t)
        local y = Fall[i]
        if jumpVel then y = math.max(y, jumpVel * t - 0.5 * gravity * t * t) end
        return Path.Here + dir * speed * t + excess * settle(WALK_TAU, t) + Vector3.new(0, y, 0)
    end
end

--// dashing -----------------------------------------------------------------
-- Only the side dashes: the forward roll is slow to come back and not worth it.

local SIDES = { "Left", "Right" }
local BASE_COOLDOWN = { Left = 0.75, Right = 0.75 }
local LastDash = { Left = -math.huge, Right = -math.huge }

local function cooldown(dir)
    local base = BASE_COOLDOWN[dir]
    if ToolsShared and type(ToolsShared.GetDashCooldown) == "function" then
        local ok, value = pcall(ToolsShared.GetDashCooldown, LocalPlayer, base)
        if ok and type(value) == "number" then return value end
    end
    return base
end

local function ready(dir, now)
    local char = LocalPlayer.Character
    if char and CollectionService:HasTag(char, "Glitch") then return true end
    return now - LastDash[dir] >= cooldown(dir) + 0.03
end

local function sideVector(root, dir)
    local right = flat(root.CFrame.RightVector)
    if right.Magnitude < 1e-3 then right = Vector3.new(1, 0, 0) end
    right = right.Unit
    return dir == "Left" and -right or right
end

-- the way to face so that a side dash sends you along dir
local function facingFor(button, dir)
    if button == "Right" then return Vector3.new(dir.Z, 0, -dir.X) end
    return Vector3.new(-dir.Z, 0, dir.X)
end

-- the game's own dash buttons (mobile controls), pressed through their
-- connections so its own code runs: cooldowns, grace, animation and sound
local function buttonFor(dir)
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("MobileControlsUI")
    local buttons = ui and ui:FindFirstChild("MobileButtons")
    return buttons and buttons:FindFirstChild(dir .. "Button")
end

local ButtonsWork = nil -- learnt: nil unknown, false they did nothing

local function pressButton(dir)
    if typeof(getconnections) ~= "function" or ButtonsWork == false then return false end
    local button = buttonFor(dir)
    if not button then return false end
    local ok, list = pcall(getconnections, button.Activated)
    if not ok or type(list) ~= "table" or #list == 0 then return false end
    local fired = false
    for _, connection in ipairs(list) do
        local done = pcall(function() connection:Fire() end)
        if not done and type(connection.Function) == "function" then
            done = pcall(connection.Function)
        end
        fired = fired or done
    end
    return fired
end

-- the same dash, done here: the grace notice first, then the push
local function scriptDash(button, dir, root, hum)
    local grace = remote("MovementGrace")
    if grace then pcall(function() grace:FireServer("Dash" .. button) end) end
    local v = dir * dashSpeed(hum)
    local current = root.AssemblyLinearVelocity
    root.AssemblyLinearVelocity = Vector3.new(v.X, current.Y, v.Z)
    return true
end

-- watched after each dash: did it happen, and how fast it settled
local DashWatch = nil

local function doDash(plan, root, hum)
    local method = Dodge.Method
    local done, how = false, nil
    local look = facingFor(plan.Button, plan.Dir)
    local before = root.CFrame
    -- the game dashes along your facing, so face the way that sends the
    -- button's dash along the planned direction first
    root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
    if method ~= "Script dash" then
        done = pressButton(plan.Button)
        if done then how = "game buttons" end
    end
    if not done and method ~= "Game buttons" then
        done = scriptDash(plan.Button, plan.Dir, root, hum)
        if done then how = "script dash" end
    end
    if not done then
        root.CFrame = CFrame.new(root.Position) * before.Rotation
        return false
    end
    Stats.Method = how
    LastDash[plan.Button] = os.clock()
    Stats.Dodges += 1
    DashWatch = {
        At = os.clock(), Dir = plan.Dir, Speed = plan.Speed, How = how, Button = plan.Button,
        Ground = not isAirborne(hum), Checked = false,
    }
    return true
end

-- the frame after a dash: if the game's buttons did nothing, say so and fall
-- back to the script dash from then on; after that, time how fast the dash
-- settled to keep the path model honest
local function watchDash(root, hum)
    local w = DashWatch
    if not w then return end
    local age = os.clock() - w.At
    local along = flat(root.AssemblyLinearVelocity):Dot(w.Dir)
    if not w.Checked and age > 0.02 then
        w.Checked = true
        if along < w.Speed * 0.35 then
            if w.How == "game buttons" then
                ButtonsWork = false
                log("Warn", "the game's dash buttons did nothing, using the script dash from now on")
                if Dodge.Method ~= "Game buttons" then scriptDash(w.Button, w.Dir, root, hum) end
            end
            DashWatch = nil
            return
        end
        if w.How == "game buttons" then ButtonsWork = true end
        w.Start = along
    end
    if w.Checked and w.Start and w.Ground then
        local walk = hum.WalkSpeed
        local excess0 = w.Start - walk
        if excess0 > 10 and along - walk <= excess0 * 0.3679 then
            DashTau = math.clamp(DashTau + (age - DashTau) * 0.5, 0.05, 0.5)
            DashWatch = nil
            return
        end
    end
    if age > 0.8 then DashWatch = nil end
end

--// steering -----------------------------------------------------------------------
-- With both dashes recharging, it can still walk you out of the way: for this
-- frame only, the humanoid is moved the safest way instead of where your keys
-- say, and it can jump.

local SteerDir = nil
local SteerJump = false
local STEER_NAME = "DDSteer" .. tostring(math.random(1000, 9999))

pcall(function()
    RunService:BindToRenderStep(STEER_NAME, Enum.RenderPriority.Character.Value + 1, function()
        if Unloaded then return end
        local dir = SteerDir
        local jump = SteerJump
        SteerDir, SteerJump = nil, false
        if not dir and not jump then return end
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        if dir then pcall(function() hum:Move(dir, false) end) end
        if jump then hum.Jump = true end
    end)
end)

--// auto dodge ----------------------------------------------------------------

local function canDodge(char)
    if not CollectionService:HasTag(char, "Playing") and not CollectionService:HasTag(char, "Lobby") then
        return false
    end
    for _, tag in ipairs({ "Downed", "FreezeTagFrozen", "HumanShield" }) do
        if CollectionService:HasTag(char, tag) then return false end
    end
    return true
end

local MAX_THREATS = 4

local function gatherThreats(root, now)
    table.clear(Threats)
    local list = {}
    local function scan(folder)
        if not folder then return end
        for _, ball in ipairs(folder:GetChildren()) do
            if ball:IsA("BasePart") then
                local offset = ball.Position - root.Position
                local distance = offset.Magnitude
                if distance < 220 then
                    local mine = targetsMe(ball, root)
                    local vel = ball.AssemblyLinearVelocity
                    -- someone else's ball only matters when it could reach you soon
                    local reach = vel.Magnitude * Dodge.Horizon + 15
                    if mine or (Dodge.OtherBalls and distance < reach) then
                        list[#list + 1] = { Ball = ball, Distance = distance, Mine = mine }
                    end
                end
            end
        end
    end
    scan(ballFolder())
    if Dodge.Practice then scan(practiceFolder()) end
    if #list == 0 then return end
    -- soonest first, by distance over closing speed
    for _, entry in ipairs(list) do
        local vel = entry.Ball.AssemblyLinearVelocity
        local toMe = root.Position - entry.Ball.Position
        local closing = toMe.Magnitude > 0 and vel:Dot(toMe.Unit) or 0
        entry.Soon = entry.Distance / math.max(closing, 5)
    end
    table.sort(list, function(a, b) return a.Soon < b.Soon end)
    for i = 1, math.min(#list, MAX_THREATS) do
        local entry = list[i]
        local ball = entry.Ball
        local info = ballInfo(ball, now)
        local threat = {
            Ball = ball, Mine = entry.Mine, Distance = entry.Distance,
            Pos = ball.Position, Vel = ball.AssemblyLinearVelocity, Params = ballParams(info),
        }
        if not entry.Mine then
            local target = ballTarget(ball)
            local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
            if targetRoot then
                threat.GoalPos, threat.GoalVel = targetRoot.Position, targetRoot.AssemblyLinearVelocity
            else
                -- no target: it carries on along its velocity
                threat.GoalPos, threat.GoalVel = ball.Position + ball.AssemblyLinearVelocity * 10, ball.AssemblyLinearVelocity
            end
        end
        Threats[#Threats + 1] = threat
    end
end

-- model check: how far a 0.25s prediction of the nearest ball misses by
local Check = nil
local function checkModel(now)
    if Check and now >= Check.Due then
        if Check.Ball.Parent then
            local miss = (Check.Ball.Position - Check.Pos).Magnitude
            Stats.ModelError = (Stats.ModelError or miss) * 0.8 + miss * 0.2
        end
        Check = nil
    end
    local threat = Threats[1]
    if Check or not threat or not threat.Mine then return end
    local pos, vel = threat.Pos, threat.Vel
    local steps = math.floor(0.25 / SIM_STEP)
    if steps > Path.Steps then return end
    for i = 1, steps do
        pos, vel = stepBall(pos, vel, stayPath(i), threat.Params, SIM_STEP)
    end
    Check = { Ball = threat.Ball, Pos = pos, Due = now + steps * SIM_STEP }
end

local function dodgeStep(dt)
    local char, root, hum = myCharacter()
    Stats.Threat = nil
    if not char then
        Stats.Status = "no character"
        return
    end
    watchMotion(hum, dt)
    watchDash(root, hum)
    measureBody(char, root)

    local now = os.clock()
    gatherThreats(root, now)
    if #Threats == 0 then
        Stats.Status = "nothing after you"
        return
    end

    local nearest = Threats[1]
    local toMe = root.Position - nearest.Pos
    local closing = toMe.Magnitude > 0 and nearest.Vel:Dot(toMe.Unit) or 0
    Stats.Threat = {
        Distance = nearest.Distance, Speed = nearest.Vel.Magnitude,
        Eta = closing > 1 and nearest.Distance / closing or nil,
    }

    -- a ball already touching you: nothing to do this frame, and no work spent
    for _, threat in ipairs(Threats) do
        if bodyGap(threat.Pos, root.Position, threat.Params.Radius) <= 0 then
            Stats.Status = "ball on you"
            return
        end
    end

    if not Dodge.Enabled or not canDodge(char) then
        Stats.Status = Dodge.Enabled and "can't dash right now" or "watching"
        return
    end

    wallIgnore()
    local steps = math.clamp(math.ceil(Dodge.Horizon / SIM_STEP), 1, MAX_STEPS)
    planPath(root, hum, steps)
    checkModel(now)

    -- staying on your path: a pass closer than half the safety room counts
    -- as a hit, since the model is never perfect
    local stayRoom, hitAt = clearance(stayPath, steps, Dodge.Margin * 0.5)
    Stats.Threat.Eta = hitAt or Stats.Threat.Eta
    if not hitAt then
        Stats.Status = ("ball after you, misses by %.1f studs"):format(stayRoom)
        return
    end
    -- only as far ahead as matters: a little past the hit, to see it come back
    local planSteps = steps
    if hitAt then planSteps = math.clamp(math.ceil((hitAt + 0.45) / SIM_STEP), 1, steps) end

    local frame = math.max(dt, 1 / 240)
    local buffer = math.max(Dodge.SafetyBuffer, frame * 2)

    -- every way around you, by whichever side dash is ready
    local readyButtons = {}
    for _, button in ipairs(SIDES) do
        if ready(button, now) then readyButtons[#readyButtons + 1] = button end
    end

    if #readyButtons > 0 then
        local speed = dashSpeed(hum)
        local full = speed * Path.Tau
        local intent = Motion.Intent
        local plans = {}
        for k = 0, Dodge.Directions - 1 do
            local dir = rotateY(Vector3.new(0, 0, -1), k * (2 * math.pi / Dodge.Directions))
            local room, void = roomFor(root, hum, dir, full)
            if not void then
                local button, bestDot = readyButtons[1], -math.huge
                for _, b in ipairs(readyButtons) do
                    local d = sideVector(root, b):Dot(dir)
                    if d > bestDot then button, bestDot = b, d end
                end
                local v0 = dir * speed * (full > 0 and math.clamp(room / full, 0, 1) or 0)
                local gap = clearance(dashPath(v0), planSteps)
                local score = math.min(gap, 10)
                    + (intent.Magnitude > 0 and intent:Dot(dir) * Dodge.KeepHeading or 0)
                    + (room / math.max(full, 1)) * 0.5
                plans[#plans + 1] = { Dir = dir, Button = button, Speed = speed, V0 = v0, Gap = gap, Score = score }
            end
        end
        table.sort(plans, function(a, b) return a.Score > b.Score end)
        local best = plans[1]

        if best then
            -- the room it has to leave: the safety room if any dash manages
            -- that, else just not touching
            local need = best.Gap > Dodge.Margin and Dodge.Margin or 0
            if best.Gap > need then
                local go
                if Dodge.Mode == "Early" then
                    go = not hitAt or hitAt <= Dodge.EarlyWindow
                else
                    -- the last safe moment: dash now unless one of the best
                    -- few would still clear it after waiting the buffer
                    local canWait = false
                    if hitAt and hitAt > buffer then
                        for i = 1, math.min(#plans, 4) do
                            local plan = plans[i]
                            if plan.Gap <= need then break end
                            if clearance(laterDashPath(plan.V0, buffer), planSteps) > need then
                                canWait = true
                                break
                            end
                        end
                    end
                    go = not canWait
                end
                if go then
                    if doDash(best, root, hum) then
                        Stats.Status = ("dodged, %d° %s, %.1f studs clear"):format(
                            math.floor(math.deg(math.atan2(-best.Dir.X, -best.Dir.Z)) % 360), best.Button:lower(), best.Gap)
                    else
                        Stats.Status = "dash failed"
                    end
                else
                    Stats.Status = ("ball in %.2fs, waiting for the last safe moment"):format(hitAt or 0)
                end
                return
            end
            -- nothing clears it: the dash that gets furthest, at the very end
            if hitAt and hitAt <= buffer then
                doDash(best, root, hum)
                Stats.Status = "dodged (closest call)"
                return
            end
        end
    end

    -- dashes recharging or no dash helps: walk (and jump) the safest way
    if Dodge.Steer and hitAt and hitAt <= Dodge.SteerWindow then
        local speed = hum.WalkSpeed
        local jumpVel = nil
        if Dodge.Jump and not isAirborne(hum) then
            jumpVel = hum.UseJumpPower and hum.JumpPower or math.sqrt(2 * Workspace.Gravity * math.max(hum.JumpHeight, 0))
        end
        local bestDir, bestJump, bestGap = nil, false, stayRoom
        for k = 0, 15 do
            local dir = rotateY(Vector3.new(0, 0, -1), k * (math.pi / 8))
            local room = roomFor(root, hum, dir, 6)
            if room >= 3 then
                local gap = clearance(walkPath(dir, speed, nil), planSteps)
                if gap > bestGap + 0.2 then bestDir, bestJump, bestGap = dir, false, gap end
            end
        end
        if jumpVel and jumpVel > 0 then
            local dir = bestDir or (Path.WalkVel.Magnitude > 0.1 and Path.WalkVel.Unit) or Vector3.zero
            local gap = clearance(walkPath(dir, dir.Magnitude > 0 and speed or 0, jumpVel), planSteps)
            if gap > bestGap + 0.2 then bestJump, bestGap = true, gap end
        end
        if bestDir or bestJump then
            SteerDir, SteerJump = bestDir, bestJump
            Stats.Status = ("dashes recharging, %s%s (%.1f studs)"):format(
                bestDir and "steering clear" or "", bestJump and (bestDir and " + jump" or "jumping") or "", bestGap)
            return
        end
    end
    Stats.Status = #readyButtons == 0 and ("ball in %.2fs, both dashes recharging"):format(hitAt or 0)
        or ("ball in %.2fs, no clean dodge yet"):format(hitAt or 0)
end

track(RunService.Heartbeat:Connect(function(dt)
    if Unloaded then return end
    local ok, err = pcall(dodgeStep, dt)
    if not ok then
        Stats.Status = "error"
        -- logged at most once a second so a broken frame can't flood the log
        if not Stats.LastError or os.clock() - Stats.LastError > 1 then
            Stats.LastError = os.clock()
            log("Error", "auto dodge: " .. tostring(err))
        end
    end
end))

--// godmode -------------------------------------------------------------------
-- The game only learns you were hit from your own hit detection scripts.
-- Turning them off means no hit is ever reported. Whether the server checks
-- hits on its own as well isn't in the dump, so this can get you flagged.

local GodScripts = {}

local function hitScripts()
    local list = {}
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
    if not scripts then return list end
    for _, inst in ipairs(scripts:GetDescendants()) do
        if inst:IsA("LocalScript") and inst.Name:find("HitDetection") then list[#list + 1] = inst end
    end
    return list
end

local function setGod(state)
    God.Enabled = state
    if state then
        for _, script in ipairs(hitScripts()) do
            if not GodScripts[script] then GodScripts[script] = script.Disabled end
            pcall(function() script.Disabled = true end)
        end
        local count = 0
        for _ in pairs(GodScripts) do count += 1 end
        log(count > 0 and "Warn" or "Error", count > 0
            and ("godmode on: %d hit detection script(s) off"):format(count)
            or "godmode: hit detection scripts not found")
    else
        for script, was in pairs(GodScripts) do
            pcall(function() script.Disabled = was end)
        end
        table.clear(GodScripts)
        log("Info", "godmode off")
    end
end

--// esp -----------------------------------------------------------------------

local EspFolder = Instance.new("Folder")
EspFolder.Name = "DDEsp" .. tostring(math.random(1000, 9999))
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    EspFolder.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end

local EspObjects = setmetatable({}, { __mode = "k" })

local function espFor(ball)
    local obj = EspObjects[ball]
    if obj and obj.Gui.Parent then return obj end
    local gui = Instance.new("BillboardGui")
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(180, 44)
    gui.StudsOffset = Vector3.new(0, 3, 0)
    gui.Adornee = ball
    gui.Parent = EspFolder
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextStrokeTransparency = 0.4
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Parent = gui
    obj = { Gui = gui, Label = label }
    EspObjects[ball] = obj
    return obj
end

local Warning
do
    local gui = Instance.new("ScreenGui")
    gui.Name = "DDWarn"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = EspFolder
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 0, 90)
    label.Size = UDim2.fromOffset(420, 40)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBlack
    label.TextScaled = true
    label.TextColor3 = Color3.fromRGB(255, 80, 80)
    label.TextStrokeTransparency = 0.3
    label.Visible = false
    label.Parent = gui
    Warning = label
end

task.spawn(function()
    while not Unloaded do
        task.wait(0.1)
        pcall(function()
            local _, root = myCharacter()
            local seen = {}
            if Esp.Enabled then
                for _, folder in ipairs({ ballFolder(), Dodge.Practice and practiceFolder() or nil }) do
                    for _, ball in ipairs(folder and folder:GetChildren() or {}) do
                        if ball:IsA("BasePart") then
                            seen[ball] = true
                            local obj = espFor(ball)
                            local target = ballTarget(ball)
                            local mine = root and targetsMe(ball, root)
                            local parts = {}
                            if Esp.Target then
                                parts[#parts + 1] = mine and "YOU" or (target and target.Name or "no target")
                            end
                            if Esp.Distance and root then
                                parts[#parts + 1] = ("%dm"):format(math.floor((ball.Position - root.Position).Magnitude))
                            end
                            if Esp.Speed then
                                parts[#parts + 1] = ("%d/s"):format(math.floor(ball.AssemblyLinearVelocity.Magnitude))
                            end
                            obj.Label.Text = table.concat(parts, "  ")
                            obj.Label.TextColor3 = mine and Color3.fromRGB(255, 80, 80) or Color3.new(1, 1, 1)
                        end
                    end
                end
            end
            for ball, obj in pairs(EspObjects) do
                if not seen[ball] then
                    pcall(function() obj.Gui:Destroy() end)
                    EspObjects[ball] = nil
                end
            end
            local threat = Stats.Threat
            Warning.Visible = Esp.Warning and threat ~= nil
            if threat then
                Warning.Text = threat.Eta and ("BALL ON YOU  %.2fs"):format(threat.Eta)
                    or ("BALL ON YOU  %dm"):format(math.floor(threat.Distance))
            end
        end)
    end
end)

--// rewards and afk -----------------------------------------------------------

local function invoke(name, ...)
    local r = remote(name)
    if not r then return false, "remote not found" end
    local args = table.pack(...)
    return pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end)
end

local function claimDaily()
    local ok, result = invoke("ClaimDailyReward")
    if ok and result then log("Success", "daily reward claimed") end
    return ok
end

local function claimQuests()
    local claimed = 0
    for i = 1, 7 do
        local ok, result = invoke("QuestClaimEvent", i)
        if ok and result then claimed += 1 end
    end
    if claimed > 0 then log("Success", ("claimed %d quest(s)"):format(claimed)) end
end

task.spawn(function()
    local nextDaily, nextQuests = 0, 0
    while not Unloaded do
        task.wait(5)
        if Misc.AutoDaily and os.clock() >= nextDaily then
            nextDaily = os.clock() + 300
            pcall(claimDaily)
        end
        if Misc.AutoQuests and os.clock() >= nextQuests then
            nextQuests = os.clock() + 60
            pcall(claimQuests)
        end
    end
end)

-- Anti-AFK without VirtualUser (its mere existence gets you kicked here):
-- the idle kick hangs off Players.LocalPlayer.Idled, so its connections are
-- switched off instead.
local AfkConnections = {}
local function setAntiAfk(state)
    Misc.AntiAfk = state
    if typeof(getconnections) ~= "function" then
        if state then log("Warn", "anti-AFK needs getconnections, which your executor doesn't have") end
        return
    end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return end
    for _, connection in ipairs(list) do
        if state then
            if pcall(function() connection:Disable() end) then AfkConnections[connection] = true end
        elseif AfkConnections[connection] then
            pcall(function() connection:Enable() end)
            AfkConnections[connection] = nil
        end
    end
end

--// teardown ------------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Dodge.Enabled = false
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    if God.Enabled then setGod(false) end
    if Misc.AntiAfk then pcall(setAntiAfk, false) end
    pcall(function() RunService:UnbindFromRenderStep(STEER_NAME) end)
    pcall(function() EspFolder:Destroy() end)
end

Genv.__DodgeOrDieStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ------------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Dodge or Die',
    Footer = 'assist',
    Icon = 'shield',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'DodgeOrDie',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

do
    local Tab = Window:AddTab('Dodge', 'shield', 'Auto dodge')

    local overview = Tab:AddBigGroupbox('Status', 'gauge')
    local status = overview:AddLabel('-', true)
    every(0.1, function()
        local threat = Stats.Threat
        local threatText = threat and ("%dm, %d/s%s"):format(math.floor(threat.Distance), math.floor(threat.Speed),
            threat.Eta and (", %.2fs"):format(threat.Eta) or "") or "none"
        status:SetText(("%s\nball after you: %s\ndodges: %d   dash by: %s\nball model off by %s   dash settle %.2fs"):format(
            Stats.Status, threatText, Stats.Dodges, Stats.Method,
            Stats.ModelError and ("%.1f studs"):format(Stats.ModelError) or "-", DashTau))
    end)

    local dodge = Tab:AddLeftGroupbox('Auto dodge', 'wind')

    dodge:AddToggle('dd_dodge', {
        Text = 'Auto dodge',
        Tooltip = 'plays every ball that can reach you forward and side-dashes out of its path at the best angle, at the last safe moment',
        Default = false,
        Callback = function(v) Dodge.Enabled = v end,
    }):AddKeyPicker('dd_dodge_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Auto dodge',
    })

    dodge:AddDropdown('dd_method', {
        Text = 'Dash with',
        Tooltip = 'game buttons: presses the game\'s own dash buttons, so its own code does the dash (needs getconnections). script dash: does the same dash itself, notice to the server included. auto: buttons when they work, else the script dash',
        Values = { 'Auto', 'Game buttons', 'Script dash' },
        Default = Dodge.Method,
        Callback = function(v) Dodge.Method = v or "Auto" end,
    })

    dodge:AddDropdown('dd_mode', {
        Text = 'When to dash',
        Tooltip = 'last moment: as late as still safe, so the ball can\'t turn after you. early: once a hit is due within the early window',
        Values = { 'Last moment', 'Early' },
        Default = Dodge.Mode,
        Callback = function(v) Dodge.Mode = v or "Last moment" end,
    })

    dodge:AddSlider('dd_buffer', {
        Text = 'Safety buffer',
        Tooltip = 'how much before the very last moment it dashes, room for frame drops and lag. raise it if you get clipped',
        Min = 0.02, Max = 0.3, Default = Dodge.SafetyBuffer, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.SafetyBuffer = v end,
    })

    dodge:AddSlider('dd_early', {
        Text = 'Early window',
        Min = 0.05, Max = 0.8, Default = Dodge.EarlyWindow, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.EarlyWindow = v end,
    })

    dodge:AddToggle('dd_others', {
        Text = 'Dodge other people\'s balls too',
        Tooltip = 'any ball touching you counts as a hit, not only the one after you',
        Default = Dodge.OtherBalls,
        Callback = function(v) Dodge.OtherBalls = v end,
    })

    dodge:AddToggle('dd_steer', {
        Text = 'Walk clear while dashes recharge',
        Tooltip = 'with both dashes on cooldown, takes over your movement for a moment to walk out of the ball\'s way',
        Default = Dodge.Steer,
        Callback = function(v) Dodge.Steer = v end,
    })

    dodge:AddToggle('dd_jump', {
        Text = 'Jump when it helps',
        Default = Dodge.Jump,
        Callback = function(v) Dodge.Jump = v end,
    })

    dodge:AddToggle('dd_practice', {
        Text = 'Practice area too',
        Default = Dodge.Practice,
        Callback = function(v) Dodge.Practice = v end,
    })

    local tune = Tab:AddRightGroupbox('Tuning', 'sliders-horizontal')

    tune:AddSlider('dd_margin', {
        Text = 'Safety room',
        Tooltip = 'studs a dodge should leave between you and the ball',
        Min = 0, Max = 5, Default = Dodge.Margin, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Dodge.Margin = v end,
    })

    tune:AddSlider('dd_horizon', {
        Text = 'Look ahead',
        Tooltip = 'how far ahead balls are played forward',
        Min = 0.4, Max = 1.3, Default = Dodge.Horizon, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.Horizon = v end,
    })

    tune:AddSlider('dd_dirs', {
        Text = 'Angles tried',
        Tooltip = 'how many directions around you each dodge picks from',
        Min = 8, Max = 36, Default = Dodge.Directions, Rounding = 0,
        Callback = function(v) Dodge.Directions = math.floor(v) end,
    })

    tune:AddSlider('dd_heading', {
        Text = 'Keep my heading',
        Tooltip = 'how much it prefers dodging the way you were already going, when several ways are safe',
        Min = 0, Max = 3, Default = Dodge.KeepHeading, Rounding = 1,
        Callback = function(v) Dodge.KeepHeading = v end,
    })

    tune:AddSlider('dd_steerwin', {
        Text = 'Take over movement within',
        Min = 0.2, Max = 1.2, Default = Dodge.SteerWindow, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.SteerWindow = v end,
    })

    tune:AddToggle('dd_watch', {
        Text = 'Follow where you\'re going',
        Tooltip = 'plays your own path forward along where you are steering, curves and falling included',
        Default = Dodge.WatchMovement,
        Callback = function(v) Dodge.WatchMovement = v end,
    })

    tune:AddToggle('dd_wall', {
        Text = 'Avoid walls',
        Tooltip = 'a dash into a wall goes nowhere, so only the room really there counts',
        Default = Dodge.WallCheck,
        Callback = function(v) Dodge.WallCheck = v end,
    })

    tune:AddToggle('dd_void', {
        Text = 'Avoid edges',
        Tooltip = 'never dashes somewhere with no floor under it',
        Default = Dodge.VoidCheck,
        Callback = function(v) Dodge.VoidCheck = v end,
    })

    local god = Tab:AddRightGroupbox('Godmode (risky)', 'skull')
    god:AddLabel('Turns off your own hit detection, so no hit is reported. The server may also check hits itself, which could get you flagged or banned.', true)
    god:AddToggle('dd_god', {
        Text = 'Godmode',
        Risky = true,
        Default = false,
        Callback = function(v) setGod(v) end,
    })
    Library:SetIgnoreIndexes({ 'dd_god' })

    local logBox = Tab:AddBigGroupbox('Log', 'scroll-text')
    Log = logBox:AddLog('dd_log', { Height = 120, MaxLines = 120, Timestamps = true })
    Log:Log('loaded. turn on auto dodge, then join a round.')
    for _, line in ipairs(PendingLog) do
        pcall(function() Log:Log(line[1], line[2]) end)
    end
    table.clear(PendingLog)
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'Ball ESP')
    local esp = Tab:AddLeftGroupbox('Ball ESP', 'scan-eye')
    esp:AddToggle('dd_esp', { Text = 'Ball ESP', Default = false, Callback = function(v) Esp.Enabled = v end })
    esp:AddToggle('dd_esp_target', { Text = 'Who it is after', Default = Esp.Target, Callback = function(v) Esp.Target = v end })
    esp:AddToggle('dd_esp_distance', { Text = 'Distance', Default = Esp.Distance, Callback = function(v) Esp.Distance = v end })
    esp:AddToggle('dd_esp_speed', { Text = 'Speed', Default = Esp.Speed, Callback = function(v) Esp.Speed = v end })
    esp:AddToggle('dd_esp_warning', {
        Text = 'Warning when it\'s after you',
        Default = Esp.Warning,
        Callback = function(v) Esp.Warning = v end,
    })
end

do
    local Tab = Window:AddTab('Misc', 'gift', 'Rewards and AFK')
    local rewards = Tab:AddLeftGroupbox('Rewards', 'gift')

    rewards:AddToggle('dd_daily', { Text = 'Auto daily reward', Default = false, Callback = function(v) Misc.AutoDaily = v end })
    rewards:AddToggle('dd_quests', { Text = 'Auto claim quests', Default = false, Callback = function(v) Misc.AutoQuests = v end })
    rewards:AddButton({
        Text = 'Claim now',
        Func = function()
            task.spawn(function()
                if not claimDaily() then log("Warn", "rewards: couldn't reach the game's remotes") end
                claimQuests()
            end)
        end,
    })

    local code = ''
    rewards:AddInput('dd_code', {
        Text = 'Code',
        Placeholder = 'type a code',
        Default = '',
        Callback = function(v) code = v end,
    })
    Library:SetIgnoreIndexes({ 'dd_code' })
    rewards:AddButton({
        Text = 'Redeem',
        Func = function()
            task.spawn(function()
                local text = code:gsub("^%s+", ""):gsub("%s+$", "")
                if text == "" then return end
                local ok, result = invoke("RedeemCode", text)
                if ok then
                    log(result and "Success" or "Warn", ("code %s: %s"):format(text, result and "redeemed" or "not accepted"))
                else
                    log("Error", "code: " .. tostring(result))
                end
            end)
        end,
    })

    local afk = Tab:AddRightGroupbox('AFK', 'moon')
    afk:AddToggle('dd_antiafk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the idle kick without VirtualUser, which this game kicks for',
        Default = Misc.AntiAfk,
        Callback = function(v) setAntiAfk(v) end,
    })
    afk:AddButton({
        Text = 'Toggle the game\'s AFK farm',
        Func = function()
            local r = remote("AFKToggle")
            if r then
                pcall(function() r:FireServer() end)
                log("Info", "AFK farm toggled")
            else
                log("Warn", "AFK toggle remote not found")
            end
        end,
    })
end

task.defer(function()
    local found = remote("MovementGrace") ~= nil
    log(found and "Info" or "Warn", found and "game remotes reachable"
        or "couldn't reach the game's remotes: script dash goes without its grace notice, and rewards won't work")
    if typeof(getconnections) ~= "function" then
        log("Warn", "no getconnections: auto dodge uses script dash only")
    end
end)

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
-- Auto dodge presimulates: every frame, for each ball after you, it plays the
-- ball forward (homing on you at the speed and turn rate it has actually been
-- seen to have) against the path you are on and against each dash you have
-- ready, and dashes at the last frame a dash still clears it. Your path follows
-- where you are steering (MoveDirection and how it is turning, gravity when in
-- the air). With better directions on it weighs every way around you and turns
-- you to face so a ready dash goes that way, as the game dashes along facing. All work per
-- frame is bounded, nothing yields in the frame loop and a ball sitting on you
-- costs nothing extra, so a stuck ball can't lag or loop it.

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
    UseForward = true,        -- the forward roll, on its longer cooldown
    Margin = 1.5,             -- studs of extra room a dodge must leave
    Horizon = 0.7,            -- seconds of ball flight played forward
    LastMoment = true,        -- dash at the last frame it still works (false: as soon as a hit is coming)
    EarlyWindow = 0.35,       -- seconds before impact when not waiting for the last moment
    WallCheck = true,         -- don't dash into walls
    WatchMovement = true,     -- play your own path forward along where you are steering, curves included
    BetterDirections = false, -- try every way around you, turning before the dash, not just left / right / forward
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

-- What each ball has been seen to do: speed, how hard it can turn, and its
-- velocity smoothed over the last few frames.
local Seen = setmetatable({}, { __mode = "k" })

local function observe(ball, now)
    local entry = Seen[ball]
    local velocity = ball.AssemblyLinearVelocity
    if not entry then
        entry = { Velocity = velocity, At = now, TopSpeed = velocity.Magnitude, Accel = 60 }
        Seen[ball] = entry
        return entry
    end
    local dt = now - entry.At
    if dt > 1 / 240 then
        local accel = (velocity - entry.Velocity).Magnitude / dt
        -- the turn rate it has shown, held with a slow decay so one spike
        -- doesn't stick but real turning is remembered
        if accel < 2000 then entry.Accel = math.max(entry.Accel * 0.995, accel) end
        entry.Velocity, entry.At = velocity, now
        entry.TopSpeed = math.max(entry.TopSpeed * 0.999, velocity.Magnitude)
    end
    return entry
end

--// presimulation -----------------------------------------------------------

local SIM_STEP = 1 / 90
local MAX_STEPS = 140 -- 1.5s of look-ahead at most

-- After a dash the game sets your horizontal velocity once and your humanoid
-- walks it back toward your walking pace, which is close to an exponential
-- settle. Air control is weaker, so it settles slower in the air.
local DASH_TAU = 0.14
local AIR_TAU = 0.3

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

-- the Shark Fin tool makes the forward roll longer, the way DashHandler's
-- sharkdash works it out
local function sharkMultiplier(amount)
    local equipped = LocalPlayer:FindFirstChild("EquippedTool")
    if not equipped then return 1 end
    for _, v in ipairs(equipped:GetChildren()) do
        if v.Name == "SharkFin" and v.Value == true then
            local tools = LocalPlayer:FindFirstChild("Tools")
            local fin = tools and tools:FindFirstChild("SharkFin")
            local level = fin and type(fin.Value) == "number" and fin.Value or 0
            return math.clamp(1.75 + level * 0.1, 1, math.max(1, 245 / (120 + amount)))
        end
    end
    return 1
end

local function dashSpeed(hum, dir)
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
    if dir == "Forward" then speed *= sharkMultiplier(amount) end
    return speed
end

-- how far a velocity excess carries you t seconds on, as it settles away
local function settle(tau, t)
    return tau * (1 - math.exp(-t / tau))
end

local WallParams = RaycastParams.new()
WallParams.FilterType = Enum.RaycastFilterType.Exclude

local function wallIgnore()
    local ignore = { LocalPlayer.Character }
    local folder = ballFolder()
    if folder then ignore[#ignore + 1] = folder end
    WallParams.FilterDescendantsInstances = ignore
end

-- How far you can actually dash in a direction before a wall stops you.
local function freeDistance(root, dir, want)
    if not Dodge.WallCheck then return want end
    local hit = Workspace:Raycast(root.Position, dir * want, WallParams)
    return hit and math.max((hit.Position - root.Position).Magnitude - 1.5, 0) or want
end

--// where you are going ---------------------------------------------------------
-- Watches what you are steering toward (Humanoid.MoveDirection, which follows
-- your keys, stick and camera) and how steadily it is turning, so your own
-- path is played forward along the way you are actually heading, curves
-- included, instead of as a straight line along your current velocity.

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
            -- a snap to a new key, not a steady turn
            Motion.Turn = 0
        else
            Motion.Turn += (math.clamp(angle / dt, -8, 8) - Motion.Turn) * 0.25
        end
    end
    Motion.Last, Motion.Intent = md, md
end

-- Your own path for the next steps if you don't dash: Walk[i] is where your
-- walking puts you at step i, Decay[i] how much of a velocity excess (a dash
-- in progress, or you not yet up to pace) has carried you by then.
local Walk, Decay = {}, {}
local PathTau = DASH_TAU
local WalkVelocity = Vector3.zero

local function planPath(root, hum, steps)
    local here = root.Position
    local velocity = root.AssemblyLinearVelocity
    local airborne = isAirborne(hum)
    PathTau = airborne and AIR_TAU or DASH_TAU

    local heading, speed, turn
    if Dodge.WatchMovement then
        heading, speed, turn = Motion.Intent, hum.WalkSpeed, Motion.Turn
    else
        local moving = flat(velocity)
        local capped = math.min(moving.Magnitude, hum.WalkSpeed)
        heading = moving.Magnitude > 0.1 and moving.Unit or Vector3.zero
        speed, turn = capped, 0
    end
    WalkVelocity = heading * speed

    -- falling: the path follows gravity down to the floor below you
    local floorY = -math.huge
    if airborne then
        local down = Workspace:Raycast(here, Vector3.new(0, -60, 0), WallParams)
        floorY = down and (here.Y - down.Distance + hum.HipHeight + root.Size.Y / 2) or (here.Y - 60)
    end
    local gravity = Workspace.Gravity
    local x, z = here.X, here.Z
    for i = 1, steps do
        local t = i * SIM_STEP
        local dir = heading
        if turn ~= 0 then dir = rotateY(heading, math.clamp(turn * t, -math.pi / 2, math.pi / 2)) end
        x += dir.X * speed * SIM_STEP
        z += dir.Z * speed * SIM_STEP
        local y = here.Y
        if airborne then y = math.max(floorY, here.Y + velocity.Y * t - 0.5 * gravity * t * t) end
        Walk[i] = Vector3.new(x, y, z)
        Decay[i] = settle(PathTau, t)
    end
    return flat(velocity) - WalkVelocity
end

-- Closest a ball gets to a path over the steps, and the first time it gets
-- within reach. path(i, t) is your position at step i.
local function simulate(ballPos, ballVel, info, path, reach, steps)
    local pos, vel = ballPos, ballVel
    local topSpeed = math.max(info.TopSpeed, vel.Magnitude, 20)
    local accel = math.max(info.Accel, 30)
    local closest, hitAt = math.huge, nil
    for i = 1, steps do
        local t = i * SIM_STEP
        local target = path(i, t)
        local to = target - pos
        if to.Magnitude > 0 then
            local change = to.Unit * topSpeed - vel
            local maxChange = accel * SIM_STEP
            if change.Magnitude > maxChange then change = change.Unit * maxChange end
            vel += change
        end
        pos += vel * SIM_STEP
        local gap = (target - pos).Magnitude
        if gap < closest then closest = gap end
        if not hitAt and gap <= reach then hitAt = t end
    end
    return closest, hitAt
end

--// dashing -----------------------------------------------------------------

local DIRS = { "Left", "Right", "Forward" }
local BASE_COOLDOWN = { Left = 0.75, Right = 0.75, Forward = 2 }
local LastDash = { Left = -math.huge, Right = -math.huge, Forward = -math.huge }

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

local function dashVector(root, dir)
    if dir == "Left" then return -flat(root.CFrame.RightVector).Unit end
    if dir == "Right" then return flat(root.CFrame.RightVector).Unit end
    return flat(root.CFrame.LookVector).Unit
end

-- the way to face so that a dash button sends you along dir
local function facingFor(button, dir)
    if button == "Right" then return Vector3.new(dir.Z, 0, -dir.X) end
    if button == "Left" then return Vector3.new(-dir.Z, 0, dir.X) end
    return dir
end

-- the game's own dash buttons (mobile controls), pressed through their
-- connections so its own code runs: cooldowns, grace, animation and sound
local function buttonFor(dir)
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = gui and gui:FindFirstChild("MobileControlsUI")
    local buttons = ui and ui.Enabled and ui:FindFirstChild("MobileButtons")
    return buttons and buttons:FindFirstChild(dir .. "Button")
end

local function pressButton(dir)
    if typeof(getconnections) ~= "function" then return false end
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
local function scriptDash(plan, root)
    local grace = remote("MovementGrace")
    if grace then pcall(function() grace:FireServer("Dash" .. plan.Button) end) end
    local v = plan.Dir * plan.Speed
    local current = root.AssemblyLinearVelocity
    root.AssemblyLinearVelocity = Vector3.new(v.X, current.Y, v.Z)
    return true
end

local function doDash(plan, root)
    local method = Dodge.Method
    local done = false
    if method ~= "Script dash" then
        local before = root.CFrame
        if not plan.Natural then
            -- the game dashes along your facing, so face the way that sends
            -- this button's dash along the planned direction first
            local look = facingFor(plan.Button, plan.Dir)
            root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
        end
        done = pressButton(plan.Button)
        if done then
            Stats.Method = "game buttons"
        elseif not plan.Natural then
            root.CFrame = CFrame.new(root.Position) * before.Rotation
        end
    end
    if not done and method ~= "Game buttons" then
        done = scriptDash(plan, root)
        if done then Stats.Method = "script dash" end
    end
    if done then
        LastDash[plan.Button] = os.clock()
        Stats.Dodges += 1
    end
    return done
end

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

local MAX_THREATS = 3     -- balls played forward each frame, nearest first
local DIRECTIONS = 16     -- directions tried with better directions on

local Threats = {}

-- the dashes to weigh this frame: your three as they are, plus with better
-- directions every way around you, each done by whichever ready button needs
-- the least turning to send you there
local function candidates(root, hum, now)
    local list = {}
    local readyList = {}
    for _, button in ipairs(DIRS) do
        if (button ~= "Forward" or Dodge.UseForward) and ready(button, now) then
            readyList[#readyList + 1] = button
            list[#list + 1] = {
                Button = button, Dir = dashVector(root, button),
                Speed = dashSpeed(hum, button), Natural = true,
            }
        end
    end
    if not Dodge.BetterDirections or #readyList == 0 then return list end

    local sides = {}
    for _, button in ipairs(readyList) do
        if button ~= "Forward" then sides[#sides + 1] = button end
    end
    local pool = #sides > 0 and sides or readyList -- the forward roll only when no side dash is ready
    for k = 0, DIRECTIONS - 1 do
        local dir = rotateY(Vector3.new(0, 0, -1), k * (2 * math.pi / DIRECTIONS))
        local best, bestDot = nil, -math.huge
        for _, button in ipairs(pool) do
            local d = dashVector(root, button):Dot(dir)
            if d > bestDot then best, bestDot = button, d end
        end
        list[#list + 1] = { Button = best, Dir = dir, Speed = dashSpeed(hum, best), Natural = false }
    end
    return list
end

local function dodgeStep(dt)
    local char, root, hum = myCharacter()
    Stats.Threat = nil
    if not char then
        Stats.Status = "no character"
        return
    end
    watchMotion(hum, dt)

    local now = os.clock()
    table.clear(Threats)
    local function gather(folder)
        if not folder then return end
        for _, ball in ipairs(folder:GetChildren()) do
            if ball:IsA("BasePart") and targetsMe(ball, root) then
                local distance = (ball.Position - root.Position).Magnitude
                if distance < 250 then Threats[#Threats + 1] = { Ball = ball, Distance = distance } end
            end
        end
    end
    gather(ballFolder())
    if Dodge.Practice then gather(practiceFolder()) end
    if #Threats == 0 then
        Stats.Status = "nothing after you"
        return
    end
    table.sort(Threats, function(a, b) return a.Distance < b.Distance end)
    -- only the nearest few are worked on, so a crowd of balls can't make a
    -- frame expensive
    for i = #Threats, MAX_THREATS + 1, -1 do Threats[i] = nil end
    for _, threat in ipairs(Threats) do
        local ball = threat.Ball
        threat.Info = observe(ball, now)
        threat.Pos, threat.Vel = ball.Position, ball.AssemblyLinearVelocity
        local size = ball.Size
        threat.Radius = math.max(size.X, size.Y, size.Z) / 2
        threat.Reach = threat.Radius + 2.2 + Dodge.Margin
    end

    local nearest = Threats[1]
    local ballVel = nearest.Vel
    local closing = ballVel.Magnitude > 1 and nearest.Distance > 0
        and ballVel:Dot((root.Position - nearest.Pos).Unit) or 0
    Stats.Threat = {
        Distance = nearest.Distance, Speed = ballVel.Magnitude,
        Eta = closing > 1 and nearest.Distance / closing or nil,
    }

    if not Dodge.Enabled or not canDodge(char) then
        Stats.Status = Dodge.Enabled and "can't dash right now" or "watching"
        return
    end

    -- a ball already inside you: nothing a dash can do this frame, and no
    -- work is spent on it
    if nearest.Distance <= nearest.Radius + 1 then
        Stats.Status = "ball on you"
        return
    end
    -- far and not closing, or still far out: skip the simulation entirely
    if Stats.Threat.Eta == nil and nearest.Distance > 40 then
        Stats.Status = "ball after you, not closing"
        return
    end
    if Stats.Threat.Eta and Stats.Threat.Eta > Dodge.Horizon + 0.3 then
        Stats.Status = ("ball after you, %.2fs out"):format(Stats.Threat.Eta)
        return
    end

    local steps = math.clamp(math.ceil(Dodge.Horizon / SIM_STEP), 1, MAX_STEPS)
    wallIgnore()
    local stayExcess = planPath(root, hum, steps)
    local function stay(i) return Walk[i] + stayExcess * Decay[i] end

    -- the room a path leaves from every ball (negative: one gets you), and
    -- the first time one would
    local function clearance(path)
        local worst, firstHit = math.huge, nil
        for _, threat in ipairs(Threats) do
            local closest, hitAt = simulate(threat.Pos, threat.Vel, threat.Info, path, threat.Reach, steps)
            worst = math.min(worst, closest - threat.Reach)
            if hitAt and (not firstHit or hitAt < firstHit) then firstHit = hitAt end
        end
        return worst, firstHit
    end

    local _, hitAt = clearance(stay)
    if not hitAt then
        Stats.Status = "ball after you, it misses"
        return
    end

    local list = candidates(root, hum, now)
    if #list == 0 then
        Stats.Status = "ball coming, every dash on cooldown"
        return
    end

    local frame = math.max(dt, 1 / 120)
    local intent = Motion.Intent
    for _, plan in ipairs(list) do
        local full = plan.Speed * PathTau
        local room = freeDistance(root, plan.Dir, full)
        local scale = full > 0 and math.clamp(room / full, 0, 1) or 0
        plan.Excess = plan.Dir * plan.Speed * scale - WalkVelocity
        local excess = plan.Excess
        plan.Clear = clearance(function(i) return Walk[i] + excess * Decay[i] end)
        if plan.Clear > 0 then
            -- clears it: more room is better up to a point, then keep going
            -- the way you were heading, and spare the long forward cooldown
            plan.Score = 1000 + math.min(plan.Clear, 8) * 4
                + (intent.Magnitude > 0 and intent:Dot(plan.Dir) * 3 or 0)
                + (plan.Natural and 1.5 or 0)
                - (plan.Button == "Forward" and 2 or 0)
        else
            plan.Score = plan.Clear
        end
    end
    table.sort(list, function(a, b) return a.Score > b.Score end)
    local best = list[1]

    if best.Clear <= 0 then
        -- nothing clears it: take the dash that gets furthest, at the last
        -- moment, which is the best a person could do too
        if hitAt <= frame * 2 then
            doDash(best, root)
            Stats.Status = "dodged (closest call)"
        else
            Stats.Status = "ball coming, no clean dodge yet"
        end
        return
    end

    local go
    if Dodge.LastMoment then
        -- the last frame a dash still clears it: dash now unless one of the
        -- best few would still clear it a frame from now
        local stayAtFrame = stayExcess * settle(PathTau, frame)
        local nextOk = false
        for k = 1, math.min(#list, 3) do
            local plan = list[k]
            if plan.Clear <= 0 then break end
            local excess = plan.Excess
            local later = clearance(function(i, t)
                if t <= frame then return stay(i) end
                return Walk[i] + stayAtFrame + excess * settle(PathTau, t - frame)
            end)
            if later > 0 then
                nextOk = true
                break
            end
        end
        go = not nextOk or hitAt <= frame * 2
    else
        go = hitAt <= Dodge.EarlyWindow
    end
    if go then
        doDash(best, root)
        Stats.Status = best.Natural and ("dodged " .. best.Button:lower())
            or ("dodged, %s dash turned to the best way out"):format(best.Button:lower())
    else
        Stats.Status = ("ball coming in %.2fs, waiting for the last moment"):format(hitAt)
    end
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
        status:SetText(("%s\nball after you: %s\ndodges: %d   dash by: %s"):format(
            Stats.Status, threatText, Stats.Dodges, Stats.Method))
    end)

    local dodge = Tab:AddLeftGroupbox('Auto dodge', 'wind')

    dodge:AddToggle('dd_dodge', {
        Text = 'Auto dodge',
        Tooltip = 'plays every ball after you forward and dashes out of its path at the last moment a dash still clears it',
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
        Tooltip = 'game buttons: presses the game\'s own mobile dash buttons, so its own code does the dash (needs mobile controls and getconnections). script dash: does the same dash itself, notice to the server included. auto: buttons when it can',
        Values = { 'Auto', 'Game buttons', 'Script dash' },
        Default = Dodge.Method,
        Callback = function(v) Dodge.Method = v or "Auto" end,
    })

    dodge:AddToggle('dd_forward', {
        Text = 'Use the forward roll',
        Tooltip = 'the forward dash has a 2s cooldown, left and right 0.75s',
        Default = Dodge.UseForward,
        Callback = function(v) Dodge.UseForward = v end,
    })

    dodge:AddToggle('dd_lastmoment', {
        Text = 'Wait for the last moment',
        Tooltip = 'on: dashes at the last frame a dash still clears the ball, so it can\'t turn and catch you. off: dashes once a hit is due within the window below',
        Default = Dodge.LastMoment,
        Callback = function(v) Dodge.LastMoment = v end,
    })

    dodge:AddSlider('dd_early', {
        Text = 'Early window',
        Min = 0.05, Max = 0.8, Default = Dodge.EarlyWindow, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.EarlyWindow = v end,
    })

    dodge:AddToggle('dd_practice', {
        Text = 'Practice area too',
        Default = Dodge.Practice,
        Callback = function(v) Dodge.Practice = v end,
    })

    local tune = Tab:AddRightGroupbox('Tuning', 'sliders-horizontal')

    tune:AddSlider('dd_margin', {
        Text = 'Safety room',
        Tooltip = 'studs a dodge has to keep between you and the ball',
        Min = 0, Max = 6, Default = Dodge.Margin, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Dodge.Margin = v end,
    })

    tune:AddSlider('dd_horizon', {
        Text = 'Look ahead',
        Tooltip = 'how far ahead each ball is played forward',
        Min = 0.3, Max = 1.5, Default = Dodge.Horizon, Rounding = 2, Suffix = 's',
        Callback = function(v) Dodge.Horizon = v end,
    })

    tune:AddToggle('dd_watch', {
        Text = 'Follow where you\'re going',
        Tooltip = 'plays your own path forward along where you are steering (keys, stick and camera), curves and falling included, instead of a straight line along your current speed. dodges come out more accurate while you move',
        Default = Dodge.WatchMovement,
        Callback = function(v) Dodge.WatchMovement = v end,
    })

    tune:AddToggle('dd_better', {
        Text = 'Better directions',
        Tooltip = 'tries 16 directions all around you, not only left, right and forward, and picks the one that clears every ball by the most while keeping you heading your way. you turn to face it for a moment, since the game dashes along your facing',
        Default = Dodge.BetterDirections,
        Callback = function(v) Dodge.BetterDirections = v end,
    })

    tune:AddToggle('dd_wall', {
        Text = 'Avoid walls',
        Tooltip = 'a dash into a wall goes nowhere, so the planner counts only the room that is really there',
        Default = Dodge.WallCheck,
        Callback = function(v) Dodge.WallCheck = v end,
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

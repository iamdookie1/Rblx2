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
-- seen to have) against you standing still and against each dash you have
-- ready, and dashes at the last frame a dash still clears it. All work per
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

-- How far a dash in a direction carries you over time: the game sets the
-- horizontal velocity once and your humanoid walks it back down, which is
-- close to an exponential settle back to walking pace.
local DASH_TAU = 0.14

local function dashSpeed(hum)
    local amount = 0
    local upgrades = LocalPlayer:FindFirstChild("Upgrades")
    local dashes = upgrades and upgrades:FindFirstChild("Dashes")
    if dashes and type(dashes.Value) == "number" then
        amount = dashes.Value
        if Upgrades and type(Upgrades.GetEffectiveAmount) == "function" then
            local ok, effective = pcall(Upgrades.GetEffectiveAmount, dashes.Value)
            if ok and type(effective) == "number" then amount = effective end
        end
    end
    local airborne = hum.FloorMaterial == Enum.Material.Air
    local speed = airborne and (amount + 50) or (amount + 120)
    local char = LocalPlayer.Character
    if char and CollectionService:HasTag(char, "Shrunk") and not airborne then speed *= 0.6 end
    if char and CollectionService:HasTag(char, "Glitch") then speed *= 1.5 end
    return speed
end

-- Where you would be t seconds after starting a dash of velocity v0, walking
-- at walk afterwards along your current motion.
local function dashOffset(v0, t)
    return v0 * DASH_TAU * (1 - math.exp(-t / DASH_TAU))
end

local WallParams = RaycastParams.new()
WallParams.FilterType = Enum.RaycastFilterType.Exclude

-- How far you can actually dash in a direction before a wall stops you.
local function freeDistance(root, dir, want)
    if not Dodge.WallCheck then return want end
    local char = LocalPlayer.Character
    local ignore = { char }
    local folder = ballFolder()
    if folder then ignore[#ignore + 1] = folder end
    WallParams.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(root.Position, dir * want, WallParams)
    return hit and math.max((hit.Position - root.Position).Magnitude - 1.5, 0) or want
end

-- Closest the ball gets to you over the horizon, and when it first gets
-- within reach. me(t) gives your position t seconds from now.
local function simulate(ballPos, ballVel, info, me, reach, horizon)
    local pos, vel = ballPos, ballVel
    local topSpeed = math.max(info.TopSpeed, vel.Magnitude, 20)
    local accel = math.max(info.Accel, 30)
    local closest, hitAt = math.huge, nil
    local t = 0
    local steps = math.ceil(horizon / SIM_STEP)
    for _ = 1, steps do
        t += SIM_STEP
        local target = me(t)
        local to = target - pos
        local dist = to.Magnitude
        if dist > 0 then
            local desired = to.Unit * topSpeed
            local change = desired - vel
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
local function scriptDash(dir, root, hum)
    local grace = remote("MovementGrace")
    if grace then pcall(function() grace:FireServer("Dash" .. dir) end) end
    local v = dashVector(root, dir) * dashSpeed(hum)
    local current = root.AssemblyLinearVelocity
    root.AssemblyLinearVelocity = Vector3.new(v.X, current.Y, v.Z)
    return true
end

local function doDash(dir, root, hum)
    local method = Dodge.Method
    local done = false
    if method ~= "Script dash" then
        done = pressButton(dir)
        if done then Stats.Method = "game buttons" end
    end
    if not done and method ~= "Game buttons" then
        done = scriptDash(dir, root, hum)
        if done then Stats.Method = "script dash" end
    end
    if done then
        LastDash[dir] = os.clock()
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

local Threats = {}

local function dodgeStep(dt)
    local char, root, hum = myCharacter()
    Stats.Threat = nil
    if not char then
        Stats.Status = "no character"
        return
    end

    local now = os.clock()
    table.clear(Threats)
    local function gather(folder)
        if not folder then return end
        for _, ball in ipairs(folder:GetChildren()) do
            if ball:IsA("BasePart") and targetsMe(ball, root) then
                local distance = (ball.Position - root.Position).Magnitude
                -- at most a handful, nearest first, so a crowd of balls can't
                -- make a frame expensive
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

    local nearest = Threats[1]
    local info = observe(nearest.Ball, now)
    for i = 2, math.min(#Threats, 3) do observe(Threats[i].Ball, now) end

    local ballPos, ballVel = nearest.Ball.Position, nearest.Ball.AssemblyLinearVelocity
    local closing = ballVel.Magnitude > 1 and ballVel:Dot((root.Position - ballPos).Unit) or 0
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
    local radius = math.max(nearest.Ball.Size.X, nearest.Ball.Size.Y, nearest.Ball.Size.Z) / 2
    local reach = radius + 2.2 + Dodge.Margin
    if nearest.Distance <= radius + 1 then
        Stats.Status = "ball on you"
        return
    end
    -- far and slow: skip the simulation entirely
    if Stats.Threat.Eta == nil and nearest.Distance > 40 then
        Stats.Status = "ball after you, not closing"
        return
    end
    if Stats.Threat.Eta and Stats.Threat.Eta > Dodge.Horizon + 0.3 then
        Stats.Status = ("ball after you, %.2fs out"):format(Stats.Threat.Eta)
        return
    end

    local here = root.Position
    -- your motion split into walking and whatever a dash already in progress
    -- is still adding, which settles away like any dash does. So a dash that
    -- already clears the ball isn't followed by a wasted second one.
    local moving = flat(root.AssemblyLinearVelocity)
    local walk, extra = moving, Vector3.zero
    if moving.Magnitude > hum.WalkSpeed * 1.2 then
        walk = moving.Unit * hum.WalkSpeed
        extra = moving - walk
    end
    local function stay(t) return here + walk * t + dashOffset(extra, t) end
    local _, hitAt = simulate(ballPos, ballVel, info, stay, reach, Dodge.Horizon)
    if not hitAt then
        Stats.Status = "ball after you, it misses"
        return
    end

    -- each dash you have ready, now and one frame from now
    local frame = math.max(dt, 1 / 120)
    local speed = dashSpeed(hum)
    local best, bestGap, nextOk = nil, -math.huge, false
    for _, dir in ipairs(DIRS) do
        if (dir ~= "Forward" or Dodge.UseForward) and ready(dir, now) then
            local vec = dashVector(root, dir)
            local reachable = freeDistance(root, vec, speed * DASH_TAU)
            local scale = (speed * DASH_TAU) > 0 and math.clamp(reachable / (speed * DASH_TAU), 0, 1) or 0
            local v0 = vec * speed * scale
            local function dashNow(t) return here + dashOffset(v0, t) end
            local gap = simulate(ballPos, ballVel, info, dashNow, reach, Dodge.Horizon)
            if gap > bestGap then best, bestGap = dir, gap end
            if gap > reach then
                local function dashLater(t)
                    if t <= frame then return stay(t) end
                    return stay(frame) + dashOffset(v0, t - frame)
                end
                local later = simulate(ballPos, ballVel, info, dashLater, reach, Dodge.Horizon)
                if later > reach then nextOk = true end
            end
        end
    end

    if not best then
        Stats.Status = "ball coming, every dash on cooldown"
        return
    end
    if bestGap <= reach then
        -- nothing clears it: take the dash that gets furthest, at the last
        -- moment, which is the best a person could do too
        if hitAt <= frame * 2 then
            doDash(best, root, hum)
            Stats.Status = "dodged (closest call)"
        else
            Stats.Status = "ball coming, no clean dodge yet"
        end
        return
    end

    local go
    if Dodge.LastMoment then
        -- the last frame a dash still clears it
        go = not nextOk or hitAt <= frame * 2
    else
        go = hitAt <= Dodge.EarlyWindow
    end
    if go then
        doDash(best, root, hum)
        Stats.Status = "dodged " .. best:lower()
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

--// Blade Ball Aim Trainer -- auto parry, ball control and a better ball.
--
-- Built against a script dump of the live game (place 15172193554, game
-- 5229983206, version 970). What the game's own client scripts show:
--  * The whole round is local. PlayerScripts.BallMove clones its Ball child
--    into Workspace and moves it with an AlignPosition between two bots
--    (Workspace.Query.p1 / p2) and you (an Attachment it adds to your root).
--    It turns red while it is coming for you. When it reaches you with your
--    "Deflecting" value at 0, it waits ReplicatedStorage.Mode seconds for a
--    parry and then sets your health to 0.
--  * Parrying is ReplicatedStorage.Events.Deflect, a BindableEvent; the game's
--    own Parry button fires it too. A parry keeps "Deflecting" up for 0.7s and
--    "Debounce" up for 1.9s, and a successful one clears both.
--  * Every parry adds 1 to ReplicatedStorage.Speed, which is added onto the
--    ball's MaxVelocity each time it changes target. Bot (1 or 2 bots), Mode
--    (seconds to parry once it reaches you), Freeze (how far bots wander, a
--    string) and Auto (1 restarts the round on respawn) are plain values too.
--  * Your streak is reported when you die (Died / Death remotes).
--  * The game runs Adonis's client anti cheat, which kicks for hooked
--    metamethods and anti-kick tricks. Nothing here hooks anything: parries go
--    through the game's own Deflect event, the same one its button fires.
--
-- The better ball turns BallMove off (it is a LocalScript in your
-- PlayerScripts, so it can be) and runs a ball of its own: it curves onto its
-- target like the real game, speeds up per parry, and plays to the same
-- values, events, effects and streak as the game's ball.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__BladeTrainerStop) == "function" then pcall(Genv.__BladeTrainerStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// game references ---------------------------------------------------------

local Events = ReplicatedStorage:WaitForChild("Events", 15)
local ServerEvents = ReplicatedStorage:FindFirstChild("ServerEvents")

local function event(name) return Events and Events:FindFirstChild(name) or nil end
local function value(name) return ReplicatedStorage:FindFirstChild(name) end

local function readNumber(name, default)
    local v = value(name)
    return v and tonumber(v.Value) or default
end

local function writeValue(name, new)
    local v = value(name)
    if not v then return end
    pcall(function()
        if v:IsA("StringValue") then v.Value = tostring(new) else v.Value = new end
    end)
end

local Query = Workspace:WaitForChild("Query", 15)
local Bot1 = Query and Query:FindFirstChild("p1")
local Bot2 = Query and Query:FindFirstChild("p2")
local Indicator1 = Workspace:FindFirstChild("Indicator")
local Indicator2 = Workspace:FindFirstChild("Indicator2")
-- where the bots stand before they wander, read before anything moves them
local Home1 = Indicator1 and Indicator1.Position or (Bot1 and Bot1.Position)
local Home2 = Indicator2 and Indicator2.Position or (Bot2 and Bot2.Position)

local function ballMoveScript()
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
    return scripts and scripts:FindFirstChild("BallMove")
end

-- BallMove's own children (ball, clash effects, sounds) are kept here once
-- seen, so the better ball still has them after BallMove is turned off.
local Assets = {}
local function grabAssets()
    local script = ballMoveScript()
    if not script then return end
    for _, name in ipairs({ "Ball", "Clash", "Parry", "Other", "Shield" }) do
        local child = script:FindFirstChild(name)
        if child and not Assets[name] then Assets[name] = child end
    end
end
grabAssets()

--// settings ----------------------------------------------------------------

local Parry = {
    Enabled = false,
    Lead = 0.12,          -- seconds before the ball arrives to parry
    Jitter = 0,           -- ms of random extra delay
    MinDistance = 0,      -- studs; also parry once the ball is this close
}

local Control = {
    LockSpeed = false, Speed = 2,       -- hold ReplicatedStorage.Speed at a value
    StartSpeed = 2,                      -- Speed at the start of a round
    MaxVelocity = 0,                     -- cap on the ball's MaxVelocity, 0 = off
    Responsiveness = 0,                  -- AlignPosition.Responsiveness, 0 = game's
    Rigid = false,
    FreezeBall = false,
    BallSize = 0,                        -- studs, 0 = game's
    Trail = true,
    Color = nil,
}

local Better = {
    Enabled = false,
    BaseSpeed = 40,       -- studs/s at streak 0
    Gain = 3,             -- studs/s per parry
    MaxSpeed = 400,
    Curve = 6,            -- how hard it turns onto its target; higher = straighter
    YouChance = 50,       -- % a bot sends it at you when there are two bots
    HitRadius = 3.5,      -- studs from your root that counts as reaching you
    ParryWindow = 0.7,    -- seconds a parry protects you
    Cooldown = 1.9,       -- seconds before you can parry again after a miss
}

local Stats = { Parries = 0, Speed = 0, Distance = 0, Status = "idle" }

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

local function leaderstat(name)
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    local v = stats and stats:FindFirstChild(name)
    return v and v.Value or 0
end

local function canParry()
    local char = LocalPlayer.Character
    local debounce = char and char:FindFirstChild("Debounce")
    return debounce ~= nil and debounce.Value == 0
end

--// the game's ball ---------------------------------------------------------

local function gameBall()
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == "Ball" and child:IsA("BasePart") then
            local attachment = child:FindFirstChild("Attachment")
            local align = attachment and attachment:FindFirstChildOfClass("AlignPosition")
            if align then return child, align end
        end
    end
    return nil
end

local Original = setmetatable({}, { __mode = "k" }) -- ball -> its first size, color, responsiveness

local function applyControl(ball, align)
    local saved = Original[ball]
    if not saved then
        saved = { Size = ball.Size, Responsiveness = align.Responsiveness, Rigid = align.RigidityEnabled }
        Original[ball] = saved
    end
    if Control.MaxVelocity > 0 and align.MaxVelocity > Control.MaxVelocity then
        align.MaxVelocity = Control.MaxVelocity
    end
    align.Responsiveness = Control.Responsiveness > 0 and Control.Responsiveness or saved.Responsiveness
    align.RigidityEnabled = Control.Rigid or saved.Rigid
    align.Enabled = not Control.FreezeBall
    if Control.FreezeBall then ball.AssemblyLinearVelocity = Vector3.zero end
    local size = Control.BallSize > 0 and Vector3.new(Control.BallSize, Control.BallSize, Control.BallSize) or saved.Size
    if ball.Size ~= size then ball.Size = size end
    local trail = ball:FindFirstChildOfClass("Trail")
    if trail then trail.Enabled = Control.Trail end
end

local function gameBallTargetsMe(align)
    local target = align.Attachment1
    local char = LocalPlayer.Character
    return target ~= nil and char ~= nil and target:IsDescendantOf(char)
end

--// better ball -------------------------------------------------------------

local Engine = {
    Running = false,
    Ball = nil,
    Target = nil,       -- "p1" / "p2" / "you"
    Velocity = Vector3.zero,
    Speed = 0,
    GraceUntil = nil,
    Attachment = nil,
    Highlight = nil,
    BallHighlight = nil,
    Deflecting = nil,
    Debounce = nil,
}

local function botPart(name)
    if name == "p1" then return Bot1 end
    if name == "p2" then return Bot2 end
    return nil
end

local function oneBot()
    return readNumber("Bot", 1) == 1
end

local function wander(bot, home, indicator)
    if not bot or not home then return end
    local spread = math.floor(readNumber("Freeze", 0))
    local offset = Vector3.new(
        spread > 0 and math.random(-spread, spread) or 0,
        math.random() * 0.5 + 0.5,
        spread > 0 and math.random(-spread, spread) or 0)
    local nextPos = home + offset
    pcall(function()
        TweenService:Create(bot, TweenInfo.new(10), { Position = indicator and indicator.Position or nextPos }):Play()
        if indicator then indicator.Position = nextPos end
    end)
end

local function setTarget(name)
    Engine.Target = name
    local ball = Engine.Ball
    if not ball then return end
    local danger = name == "you"
    pcall(function()
        ball.Material = Enum.Material.Neon
        ball.Color = danger and Color3.fromRGB(255, 0, 0) or (Control.Color or Color3.fromRGB(163, 162, 165))
        if Engine.Highlight then Engine.Highlight.Enabled = danger end
        if Engine.BallHighlight then
            Engine.BallHighlight.Enabled = true
            Engine.BallHighlight.FillTransparency = danger and 0 or 1
        end
    end)
end

local function engineSpeed()
    return math.min(Better.BaseSpeed + Better.Gain * leaderstat("Streak"), Better.MaxSpeed)
end

local function stopEngineRound()
    Engine.Running = false
    Engine.GraceUntil = nil
    for _, key in ipairs({ "Ball", "Attachment", "Highlight", "Deflecting", "Debounce" }) do
        local inst = Engine[key]
        if inst then pcall(function() inst:Destroy() end) end
        Engine[key] = nil
    end
    Engine.BallHighlight = nil
end

local function playClash(at)
    pcall(function()
        local clash = Assets.Clash
        local clasher = value("Clasher")
        local fx = clash and clasher and clash:FindFirstChild(clasher.Value)
        if fx then
            local clone = fx:Clone()
            clone.Parent = at
            for _, emitter in ipairs(clone:GetChildren()) do
                if emitter:IsA("ParticleEmitter") then emitter:Emit(readNumber("Device", 0) == 0 and 3 or 1) end
            end
            Debris:AddItem(clone, 1)
        end
        if Assets.Parry then
            local sound = Assets.Parry:Clone()
            sound.Parent = at
            sound:Play()
            Debris:AddItem(sound, 1)
        end
    end)
end

local function engineDeflected()
    local _, root = myCharacter()
    if root then playClash(root) end
    Engine.Deflecting.Value = 0
    Engine.Debounce.Value = 0
    Engine.GraceUntil = nil
    Stats.Parries += 1
    pcall(function()
        local streak = LocalPlayer.leaderstats.Streak
        streak.Value += 1
    end)
    writeValue("Speed", readNumber("Speed", 2) + 1)
    pcall(function() event("Count"):Fire(readNumber("Speed", 2)) end)
    local next = (oneBot() or math.random() < 0.5) and "p1" or "p2"
    setTarget(next)
    -- bounce back off you, then curve onto the bot
    if root and Engine.Ball then
        local away = (Engine.Ball.Position - root.Position)
        if away.Magnitude > 0 then Engine.Velocity = away.Unit * Engine.Speed end
    end
end

local function engineStart()
    local char, root, hum = myCharacter()
    if not char or not Query then return end
    stopEngineRound()
    grabAssets()
    pcall(function() ServerEvents.Start:FireServer() end)
    pcall(function()
        Bot1.gui.ParticleEmitter.Visible = true
        Bot2.gui.ParticleEmitter.Visible = not oneBot()
    end)
    root.CFrame = CFrame.new(Workspace.TeleportPart.Position + Vector3.new(0, 5, 0))
    pcall(function() char.Hello.Enabled = true end)

    Engine.Attachment = Instance.new("Attachment")
    Engine.Attachment.Name = "BetterBallTarget"
    Engine.Attachment.Parent = root
    char.Parent = Query
    if Bot1 and Home1 then Bot1.Position = Home1 end
    if Bot2 and Home2 then Bot2.Position = Home2 end
    pcall(function()
        Indicator1.Transparency = 0
        Indicator2.Transparency = 0
    end)
    wander(Bot1, Home1, Indicator1)
    wander(Bot2, Home2, Indicator2)
    pcall(function() event("Count"):Fire(-1) end)

    Engine.Highlight = Instance.new("Highlight")
    Engine.Highlight.Enabled = false
    Engine.Highlight.Parent = char
    Engine.Deflecting = Instance.new("NumberValue")
    Engine.Deflecting.Name = "Deflecting"
    Engine.Deflecting.Parent = char
    Engine.Debounce = Instance.new("NumberValue")
    Engine.Debounce.Name = "Debounce"
    Engine.Debounce.Parent = char

    local ball
    if Assets.Ball then
        ball = Assets.Ball:Clone()
        for _, inst in ipairs(ball:GetDescendants()) do
            if inst:IsA("AlignPosition") or inst:IsA("AlignOrientation") then inst:Destroy() end
        end
    else
        ball = Instance.new("Part")
        ball.Shape = Enum.PartType.Ball
        ball.Size = Vector3.new(2, 2, 2)
    end
    ball.Name = "BetterBall"
    ball.Anchored = true
    ball.CanCollide = false
    ball.CanQuery = false
    ball.CanTouch = false
    if Bot1 then ball.Position = Bot1.Position + Vector3.new(0, 4, 0) end
    ball.Parent = Workspace
    Engine.Ball = ball
    Engine.BallHighlight = Instance.new("Highlight")
    Engine.BallHighlight.FillTransparency = 1
    Engine.BallHighlight.Parent = ball

    writeValue("Speed", Control.StartSpeed)
    Engine.Speed = engineSpeed()
    Engine.Velocity = Vector3.zero
    setTarget("p1")
    Engine.Running = true
    Stats.Status = "better ball"

    hum.Died:Once(function()
        stopEngineRound()
        writeValue("Speed", 2)
        pcall(function() LocalPlayer.Character.Hello.Enabled = false end)
        pcall(function()
            local stats = LocalPlayer.leaderstats
            if stats.Streak.Value > stats.Best.Value then
                ReplicatedStorage.Died:FireServer(stats.Streak.Value)
                task.wait(0.01)
            end
            stats.Streak.Value = 0
        end)
    end)
end

local function engineArrive()
    local name = Engine.Target
    if name == "you" then
        if Engine.Deflecting and Engine.Deflecting.Value ~= 0 then
            engineDeflected()
        elseif not Engine.GraceUntil then
            Engine.GraceUntil = os.clock() + readNumber("Mode", 0.09)
        end
        return
    end
    local bot = botPart(name)
    pcall(function() bot.Ding:Play() end)
    if name == "p1" then wander(Bot1, Home1, Indicator1) else wander(Bot2, Home2, Indicator2) end
    -- one bot always sends it at you; with two, the other bot is a maybe
    if name == "p2" or oneBot() or math.random(100) <= Better.YouChance then
        setTarget("you")
    else
        setTarget("p2")
    end
    Engine.Speed = engineSpeed()
end

local function engineStep(dt)
    local ball = Engine.Ball
    local _, root, hum = myCharacter()
    if not ball or not ball.Parent or not root then return end

    if Engine.GraceUntil then
        -- sitting on you, waiting out the parry window the game gives
        ball.Position = root.Position
        if Engine.Deflecting and Engine.Deflecting.Value ~= 0 then
            engineDeflected()
        elseif os.clock() >= Engine.GraceUntil then
            Engine.GraceUntil = nil
            hum.Health = 0
        end
        return
    end

    if Control.FreezeBall then return end
    local target = Engine.Target == "you" and root or botPart(Engine.Target)
    if not target then return end
    local goal = target.Position
    local toGoal = goal - ball.Position
    local distance = toGoal.Magnitude
    local radius = Engine.Target == "you" and Better.HitRadius or 2.5
    local step = Engine.Speed * dt
    if distance <= radius or distance <= step then
        ball.Position = goal
        engineArrive()
        return
    end
    -- curves onto the target: turn the heading toward it at Curve per second,
    -- harder the closer it gets, so it never orbits
    local desired = toGoal.Unit * Engine.Speed
    local current = Engine.Velocity.Magnitude > 0 and Engine.Velocity or desired
    local turn = math.clamp(Better.Curve * dt * (1 + 20 / math.max(distance, 1)), 0, 1)
    local heading = current:Lerp(desired, turn)
    if heading.Magnitude < 1e-3 then heading = desired end
    Engine.Velocity = heading.Unit * Engine.Speed
    ball.Position += Engine.Velocity * dt
end

-- The game's deflect, for the better ball: BallMove's own copy is off with it.
local DeflectToken = 0
local function engineDeflect()
    if not Engine.Running or not Engine.Debounce or not Engine.Deflecting then return end
    if Engine.Debounce.Value > 0 then return end
    local char, root, hum = myCharacter()
    if not char then return end
    DeflectToken += 1
    local token = DeflectToken
    local stamp = os.clock()
    Engine.Debounce.Value = stamp
    Engine.Deflecting.Value = stamp
    pcall(function() event("Cooldown"):Fire() end)
    pcall(function()
        local animation = Instance.new("Animation")
        animation.AnimationId = "rbxassetid://15173331151"
        hum:LoadAnimation(animation):Play()
    end)
    pcall(function()
        if Assets.Other then
            local sound = Assets.Other:Clone()
            sound.Volume = 0.2
            sound.Parent = root
            sound:Play()
            Debris:AddItem(sound, 0.5)
        end
        local shield = Assets.Shield and Assets.Shield:FindFirstChild("Attachment")
        if shield then
            local clone = shield:Clone()
            clone.Parent = root
            for _, emitter in ipairs(clone:GetChildren()) do
                if emitter:IsA("ParticleEmitter") then emitter:Emit(emitter:GetAttribute("EmitCount") or 5) end
            end
            Debris:AddItem(clone, 0.45)
        end
    end)
    task.delay(Better.ParryWindow, function()
        if token == DeflectToken and Engine.Deflecting and Engine.Deflecting.Value == stamp then
            Engine.Deflecting.Value = 0
        end
    end)
    task.delay(Better.Cooldown, function()
        if Engine.Debounce and Engine.Debounce.Value == stamp then Engine.Debounce.Value = 0 end
    end)
end

local function setBetter(state)
    Better.Enabled = state
    local script = ballMoveScript()
    grabAssets()
    if state then
        if script then pcall(function() script.Disabled = true end) end
        -- clear what the game's ball left behind
        local ball = gameBall()
        if ball then ball:Destroy() end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            for _, child in ipairs(root:GetChildren()) do
                if child:IsA("Attachment") and child.Name == "Attachment" then child:Destroy() end
            end
        end
        if char then
            for _, name in ipairs({ "Deflecting", "Debounce" }) do
                local v = char:FindFirstChild(name)
                if v then v:Destroy() end
            end
            for _, h in ipairs(char:GetChildren()) do
                if h:IsA("Highlight") then h:Destroy() end
            end
        end
        if char and Query and char.Parent == Query then engineStart() end
        log("Success", "better ball on" .. (script and "" or " (BallMove not found, the game's ball may still run)"))
    else
        stopEngineRound()
        if script then pcall(function() script.Disabled = false end) end
        pcall(function() event("Count"):Fire(-1) end)
        log("Info", "better ball off, the game's ball is back. press start for a new round")
    end
end

local function onEvent(name, fn)
    local e = event(name)
    if e then track(e.Event:Connect(fn)) else log("Warn", "Events." .. name .. " not found") end
end

onEvent("Start", function()
    if Better.Enabled then task.defer(engineStart) end
end)

onEvent("Deflect", function()
    if Better.Enabled then task.spawn(engineDeflect) end
end)

do
    -- BallMove's own keys and taps, for while it is off
    local touchStart
    track(UserInputService.InputBegan:Connect(function(input, processed)
        if not Better.Enabled or processed then return end
        if input.KeyCode == Enum.KeyCode.F or input.UserInputType == Enum.UserInputType.MouseButton1 then
            task.spawn(engineDeflect)
        elseif input.UserInputType == Enum.UserInputType.Touch then
            touchStart = input.Position
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input, processed)
        if processed or input.UserInputType ~= Enum.UserInputType.Touch or not touchStart then return end
        if (input.Position - touchStart).Magnitude > 10 then touchStart = nil end
    end))
    track(UserInputService.InputEnded:Connect(function(input, processed)
        if not Better.Enabled or processed or input.UserInputType ~= Enum.UserInputType.Touch then return end
        if touchStart then task.spawn(engineDeflect) end
        touchStart = nil
    end))
end

--// main loop ---------------------------------------------------------------

local Tracked = { Ball = nil, Distance = nil, Clock = nil, Closing = 0 }
local ParryPlannedAt = nil

local function fireParry()
    local deflect = event("Deflect")
    if deflect then pcall(function() deflect:Fire() end) end
end

track(RunService.Heartbeat:Connect(function(dt)
    if Unloaded then return end

    if Control.LockSpeed then writeValue("Speed", Control.Speed) end

    if Better.Enabled and Engine.Running then
        local ok, err = pcall(engineStep, dt)
        if not ok then log("Error", "better ball: " .. tostring(err)) end
    end

    -- the ball in play and whether it is after you
    local ball, targetsMe, closing
    local _, root = myCharacter()
    if Better.Enabled then
        ball = Engine.Running and Engine.Ball or nil
        targetsMe = ball ~= nil and Engine.Target == "you" and not Engine.GraceUntil
        closing = Engine.Speed
    else
        local align
        ball, align = gameBall()
        if ball and align then
            applyControl(ball, align)
            targetsMe = gameBallTargetsMe(align)
        end
    end

    if not ball or not root then
        Tracked.Ball = nil
        Stats.Status = Better.Enabled and "better ball, waiting for start" or "waiting for a round"
        Stats.Distance = 0
        return
    end

    local distance = (ball.Position - root.Position).Magnitude
    local clock = os.clock()
    if not Better.Enabled then
        -- closing speed from how fast the gap shrinks, smoothed
        if Tracked.Ball == ball and Tracked.Distance and clock > Tracked.Clock then
            local rate = (Tracked.Distance - distance) / (clock - Tracked.Clock)
            Tracked.Closing = Tracked.Closing * 0.5 + rate * 0.5
        else
            Tracked.Closing = 0
        end
        Tracked.Ball, Tracked.Distance, Tracked.Clock = ball, distance, clock
        closing = math.max(Tracked.Closing, ball.AssemblyLinearVelocity.Magnitude * 0.5)
    end
    Stats.Distance = distance
    Stats.Speed = closing or 0
    Stats.Status = targetsMe and "coming for you" or "with a bot"

    if not Parry.Enabled or not targetsMe then
        ParryPlannedAt = nil
        return
    end
    if not canParry() then return end
    local arrival = (closing and closing > 0.5) and distance / closing or math.huge
    if arrival <= Parry.Lead + dt or distance <= Parry.MinDistance then
        if Parry.Jitter > 0 then
            ParryPlannedAt = ParryPlannedAt or (clock + math.random() * Parry.Jitter / 1000)
            if clock < ParryPlannedAt then return end
        end
        ParryPlannedAt = nil
        fireParry()
    end
end))

-- start speed for the game's own rounds
onEvent("Count", function(speed)
    if speed == -1 and not Better.Enabled and Control.StartSpeed ~= 2 then
        writeValue("Speed", Control.StartSpeed)
    end
end)

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Parry.Enabled = false
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    if Better.Enabled then
        stopEngineRound()
        local script = ballMoveScript()
        if script then pcall(function() script.Disabled = false end) end
    end
    local ball, align = gameBall()
    if ball and align and Original[ball] then
        pcall(function()
            align.Enabled = true
            align.Responsiveness = Original[ball].Responsiveness
            align.RigidityEnabled = Original[ball].Rigid
            ball.Size = Original[ball].Size
        end)
    end
end

Genv.__BladeTrainerStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Blade Ball Trainer',
    Footer = 'auto parry',
    Icon = 'swords',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'BladeBallTrainer',
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
    local Tab = Window:AddTab('Auto parry', 'shield', 'Parries for you')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('bbt_stats', {
        Cards = {
            { Title = 'Streak', Value = '0', Icon = 'flame' },
            { Title = 'Best', Value = '0', Icon = 'trophy' },
            { Title = 'Ball speed', Value = '0', Icon = 'gauge' },
            { Title = 'Distance', Value = '0', Icon = 'ruler' },
        },
    })
    local status = overview:AddLabel('ball: -')
    every(0.15, function()
        cards:SetValue('Streak', tostring(leaderstat("Streak")))
        cards:SetValue('Best', tostring(leaderstat("Best")))
        cards:SetValue('Ball speed', tostring(math.floor(Stats.Speed)))
        cards:SetValue('Distance', tostring(math.floor(Stats.Distance)))
        status:SetText('ball: ' .. Stats.Status)
    end)

    local parry = Tab:AddLeftGroupbox('Auto parry', 'shield')

    parry:AddToggle('bbt_parry', {
        Text = 'Auto parry',
        Tooltip = 'parries through the game\'s own deflect when the ball is about to reach you',
        Default = false,
        Callback = function(state) Parry.Enabled = state end,
    }):AddKeyPicker('bbt_parry_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Auto parry',
    })

    parry:AddSlider('bbt_lead', {
        Text = 'Parry before arrival',
        Tooltip = 'how long before the ball reaches you to parry. a parry lasts 0.7s, so anything under that holds',
        Min = 0.02, Max = 0.6, Default = Parry.Lead, Rounding = 2, Suffix = 's',
        Callback = function(v) Parry.Lead = v end,
    })

    parry:AddSlider('bbt_jitter', {
        Text = 'Random delay',
        Tooltip = 'up to this much extra delay per parry, to look human. keep it under the lead or it gets late',
        Min = 0, Max = 300, Default = Parry.Jitter, Rounding = 0, Suffix = 'ms',
        Callback = function(v) Parry.Jitter = v end,
    })

    parry:AddSlider('bbt_mindist', {
        Text = 'Also parry within',
        Tooltip = 'parries as soon as the ball is this close, whatever its speed. 0 = off',
        Min = 0, Max = 30, Default = Parry.MinDistance, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Parry.MinDistance = v end,
    })

    local manual = Tab:AddRightGroupbox('Round', 'play')
    manual:AddButton({
        Text = 'Start round',
        Func = function() pcall(function() event("Start"):Fire() end) end,
    }):AddButton({
        Text = 'Parry now',
        Func = fireParry,
    })

    local logBox = Tab:AddBigGroupbox('Log', 'scroll-text')
    Log = logBox:AddLog('bbt_log', { Height = 120, MaxLines = 120, Timestamps = true })
    Log:Log('loaded. turn on auto parry and start a round.')
    for _, line in ipairs(PendingLog) do
        pcall(function() Log:Log(line[1], line[2]) end)
    end
    table.clear(PendingLog)
end

do
    local Tab = Window:AddTab('Ball control', 'circle-dot', 'Tune the ball and the round')

    local normal = Tab:AddLeftGroupbox('Normal', 'sliders-horizontal')

    normal:AddDropdown('bbt_bots', {
        Text = 'Bots',
        Values = { '1', '2' },
        Default = tostring(readNumber("Bot", 1) == 1 and 1 or 2),
        Callback = function(v) writeValue("Bot", tonumber(v) or 1) end,
    })

    normal:AddSlider('bbt_mode', {
        Text = 'Parry grace',
        Tooltip = 'how long the ball waits on you for a parry before you die (the game\'s Mode value)',
        Min = 0, Max = 1, Default = readNumber("Mode", 0.09), Rounding = 2, Suffix = 's',
        Callback = function(v) writeValue("Mode", v) end,
    })

    normal:AddSlider('bbt_freeze', {
        Text = 'Bot wander',
        Tooltip = 'how far the bots move around between hits (the game\'s Freeze value)',
        Min = 0, Max = 150, Default = readNumber("Freeze", 75), Rounding = 0, Suffix = ' studs',
        Callback = function(v) writeValue("Freeze", v) end,
    })

    normal:AddSlider('bbt_startspeed', {
        Text = 'Start speed',
        Tooltip = 'the speed value a new round starts on. the game adds it to the ball\'s top speed every time it changes target',
        Min = 1, Max = 50, Default = Control.StartSpeed, Rounding = 0,
        Callback = function(v) Control.StartSpeed = v end,
    })

    normal:AddToggle('bbt_lockspeed', {
        Text = 'Lock speed',
        Tooltip = 'stops the speed value from going up each parry',
        Default = false,
        Callback = function(state) Control.LockSpeed = state end,
    })

    normal:AddSlider('bbt_speed', {
        Text = 'Locked speed',
        Min = 1, Max = 50, Default = Control.Speed, Rounding = 0,
        Callback = function(v) Control.Speed = v end,
    })

    normal:AddToggle('bbt_auto', {
        Text = 'Auto restart',
        Tooltip = 'starts a new round as soon as you respawn (the game\'s Auto value)',
        Default = readNumber("Auto", 2) == 1,
        Callback = function(state) writeValue("Auto", state and 1 or 2) end,
    })

    local advanced = Tab:AddRightGroupbox('Advanced', 'settings-2')

    advanced:AddSlider('bbt_maxvel', {
        Text = 'Top speed cap',
        Tooltip = 'caps the game ball\'s MaxVelocity. 0 = no cap',
        Min = 0, Max = 1000, Default = Control.MaxVelocity, Rounding = 0, Suffix = ' studs/s',
        Callback = function(v) Control.MaxVelocity = v end,
    })

    advanced:AddSlider('bbt_resp', {
        Text = 'Responsiveness',
        Tooltip = 'how hard the game ball pulls toward its target. 0 = the game\'s own',
        Min = 0, Max = 200, Default = 0, Rounding = 0,
        Callback = function(v) Control.Responsiveness = v end,
    })

    advanced:AddToggle('bbt_rigid', {
        Text = 'Rigid',
        Tooltip = 'the game ball goes straight to its target as fast as it can',
        Default = false,
        Callback = function(state) Control.Rigid = state end,
    })

    advanced:AddToggle('bbt_freezeball', {
        Text = 'Freeze ball',
        Default = false,
        Callback = function(state) Control.FreezeBall = state end,
    })

    advanced:AddSlider('bbt_size', {
        Text = 'Ball size',
        Tooltip = '0 = the game\'s own',
        Min = 0, Max = 10, Default = 0, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Control.BallSize = v end,
    })

    advanced:AddToggle('bbt_trail', {
        Text = 'Trail',
        Default = true,
        Callback = function(state) Control.Trail = state end,
    })

    local better = Tab:AddLeftGroupbox('Better ball', 'sparkles')

    better:AddToggle('bbt_better', {
        Text = 'Better ball',
        Tooltip = 'turns off the trainer\'s ball script and runs a ball that curves onto its target and speeds up per parry like the real game. bots, grace and wander above still apply',
        Default = false,
        Callback = function(state) setBetter(state) end,
    })

    better:AddSlider('bbt_base', {
        Text = 'Start speed',
        Min = 10, Max = 200, Default = Better.BaseSpeed, Rounding = 0, Suffix = ' studs/s',
        Callback = function(v) Better.BaseSpeed = v end,
    })

    better:AddSlider('bbt_gain', {
        Text = 'Speed per parry',
        Min = 0, Max = 30, Default = Better.Gain, Rounding = 1, Suffix = ' studs/s',
        Callback = function(v) Better.Gain = v end,
    })

    better:AddSlider('bbt_max', {
        Text = 'Top speed',
        Min = 50, Max = 1500, Default = Better.MaxSpeed, Rounding = 0, Suffix = ' studs/s',
        Callback = function(v) Better.MaxSpeed = v end,
    })

    better:AddSlider('bbt_curve', {
        Text = 'Curve',
        Tooltip = 'how hard the ball turns onto its target. low = wide curves, high = almost straight',
        Min = 1, Max = 30, Default = Better.Curve, Rounding = 1,
        Callback = function(v) Better.Curve = v end,
    })

    better:AddSlider('bbt_youchance', {
        Text = 'Comes at you',
        Tooltip = 'with two bots, the chance the first bot sends it to you instead of the other bot',
        Min = 0, Max = 100, Default = Better.YouChance, Rounding = 0, Suffix = '%',
        Callback = function(v) Better.YouChance = v end,
    })

    better:AddSlider('bbt_radius', {
        Text = 'Hit radius',
        Min = 1, Max = 10, Default = Better.HitRadius, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Better.HitRadius = v end,
    })

    better:AddSlider('bbt_window', {
        Text = 'Parry lasts',
        Min = 0.1, Max = 1.5, Default = Better.ParryWindow, Rounding = 2, Suffix = 's',
        Callback = function(v) Better.ParryWindow = v end,
    })

    better:AddSlider('bbt_cooldown', {
        Text = 'Missed parry cooldown',
        Min = 0, Max = 3, Default = Better.Cooldown, Rounding = 2, Suffix = 's',
        Callback = function(v) Better.Cooldown = v end,
    })
end

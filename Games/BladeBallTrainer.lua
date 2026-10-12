--// Blade Ball Aim Trainer -- auto parry, ball control, a better ball and
--// better visuals.
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
-- PlayerScripts, so it can be) and runs a ball of its own: it flies straight
-- at its target, re-aimed every frame so it follows you, and moves by time
-- rather than by frame, so at any speed it lands every hit it should, several
-- in one frame if it is that fast. It plays to the same values, events,
-- effects and streak as the game's ball.

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
    Mode = "Smart",       -- Smart: one well timed parry / Spam: every frame inside the window
    Lead = 0.12,          -- Smart: seconds before the ball arrives to parry
    SpamWindow = 0.3,     -- Spam: seconds before arrival the spam starts
    SpamPerFrame = 1,     -- Spam: parries fired each frame
    Jitter = 0,           -- ms of random extra delay
    MinDistance = 0,      -- studs; also parry once the ball is this close
    Sync = true,          -- better ball: parry on the exact frame it reaches you, at any speed
}

local Control = {
    LockSpeed = false, Speed = 2,       -- hold ReplicatedStorage.Speed at a value
    StartSpeed = 2,                      -- Speed at the start of a round
    MaxVelocity = 0,                     -- cap on the ball's MaxVelocity, 0 = off
    Responsiveness = 0,                  -- AlignPosition.Responsiveness, 0 = game's
    Rigid = false,
    FreezeBall = false,
    BallSize = 0,                        -- studs, 0 = game's
}

local Better = {
    Enabled = false,
    Pace = "Speed",       -- Speed: studs/s from the streak / Travel time: each trip takes a set time
    BaseSpeed = 80,       -- studs/s at streak 0
    GainMode = "Add",     -- Add: + Gain per parry / Multiply: x Multiplier per parry
    Gain = 3,
    Multiplier = 1.05,
    MaxSpeed = 400,       -- any number, 1e9 and inf included
    TravelTime = 0.35,    -- seconds per trip, Travel time pace
    InstantBots = false,  -- bots send it back the moment it is sent to them
    HitsPerFrame = 1,     -- most parries one frame may hold, at speeds that cover several trips a frame
    YouChance = 50,       -- % a bot sends it at you when there are two bots
    HitRadius = 5,        -- studs from your root that counts as reaching you
    ParryWindow = 0.7,    -- seconds a parry protects you
    Cooldown = 1.9,       -- seconds before you can parry again after a miss
    BallSize = 2,
}

local Visual = {
    BetterTrail = false, TrailLife = 0.35, TrailWidth = 1, TrailColor = Color3.fromRGB(255, 255, 255),
    Rainbow = false, RainbowBall = false, RainbowSpeed = 0.5,
    BallColor = nil,                     -- nil = the game's
    DangerColor = Color3.fromRGB(255, 0, 0),
    Glow = false, GlowRange = 12,
    BetterFx = false, FxSize = 12, FxSparks = 30, FxFlash = true, FxShake = false, FxShakePower = 0.6,
    FxGap = 0.05,                        -- seconds between effects, so fast streaks don't flood
    FxColor = Color3.fromRGB(255, 255, 255),
    HideGameFx = false,
    HitVolume = 0.5,
}

local Stats = { Parries = 0, Speed = 0, Distance = 0, Status = "idle", PerSecond = 0 }

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

-- Numbers typed by hand: 1e9, 2.5e3, inf / infinity / huge all work.
local function parseNumber(text, default)
    if type(text) == "number" then return text end
    local cleaned = tostring(text or ""):lower():gsub("[%s,_]", "")
    if cleaned == "inf" or cleaned == "infinity" or cleaned == "huge" or cleaned == "math.huge" then
        return math.huge
    end
    local number = tonumber(cleaned)
    if number and number == number then return number end
    return default
end

local function showNumber(n)
    if n == math.huge then return "inf" end
    if math.abs(n) >= 1e6 then return string.format("%.3g", n) end
    return tostring(math.floor(n + 0.5))
end

local function rainbow(offset)
    return Color3.fromHSV(((os.clock() * Visual.RainbowSpeed) + (offset or 0)) % 1, 0.85, 1)
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

local Original = setmetatable({}, { __mode = "k" }) -- ball -> what it started with

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
end

local function gameBallTargetsMe(align)
    local target = align.Attachment1
    local char = LocalPlayer.Character
    return target ~= nil and char ~= nil and target:IsDescendantOf(char)
end

--// visuals -----------------------------------------------------------------

local FxFolder = Instance.new("Folder")
FxFolder.Name = "TrainerFx"
FxFolder.Parent = Workspace

local Shake = { Until = 0, Power = 0 }
local LastFx = 0

-- A parry burst: an expanding glow sphere, a flat shock ring, sparks and a
-- flash of light, all in one colour, gone in half a second.
local function parryEffect(position, color)
    local now = os.clock()
    if now - LastFx < Visual.FxGap then return end
    LastFx = now
    color = color or (Visual.Rainbow and rainbow() or Visual.FxColor)
    local size = Visual.FxSize

    local anchor = Instance.new("Part")
    anchor.Name = "ParryFx"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.2, 0.2, 0.2)
    anchor.Position = position
    anchor.Parent = FxFolder
    Debris:AddItem(anchor, 1)

    local sphere = Instance.new("Part")
    sphere.Shape = Enum.PartType.Ball
    sphere.Material = Enum.Material.Neon
    sphere.Color = color
    sphere.Anchored = true
    sphere.CanCollide = false
    sphere.CanQuery = false
    sphere.CanTouch = false
    sphere.CastShadow = false
    sphere.Size = Vector3.new(1, 1, 1)
    sphere.Transparency = 0.1
    sphere.Position = position
    sphere.Parent = FxFolder
    Debris:AddItem(sphere, 0.6)
    TweenService:Create(sphere, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Size = Vector3.new(size, size, size), Transparency = 1,
    }):Play()

    local ring = Instance.new("Part")
    ring.Shape = Enum.PartType.Cylinder
    ring.Material = Enum.Material.Neon
    ring.Color = color
    ring.Anchored = true
    ring.CanCollide = false
    ring.CanQuery = false
    ring.CanTouch = false
    ring.CastShadow = false
    ring.Size = Vector3.new(0.15, 1, 1)
    ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
    ring.Transparency = 0
    ring.Parent = FxFolder
    Debris:AddItem(ring, 0.6)
    TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Size = Vector3.new(0.05, size * 1.6, size * 1.6), Transparency = 1,
    }):Play()

    if Visual.FxSparks > 0 then
        local attachment = Instance.new("Attachment")
        attachment.Parent = anchor
        local sparks = Instance.new("ParticleEmitter")
        sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        sparks.Color = ColorSequence.new(color)
        sparks.LightEmission = 1
        sparks.LightInfluence = 0
        sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
        sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
        sparks.Lifetime = NumberRange.new(0.25, 0.5)
        sparks.Speed = NumberRange.new(size * 2, size * 4)
        sparks.SpreadAngle = Vector2.new(180, 180)
        sparks.Drag = 6
        sparks.Enabled = false
        sparks.Parent = attachment
        sparks:Emit(Visual.FxSparks)
    end

    if Visual.FxFlash then
        local light = Instance.new("PointLight")
        light.Color = color
        light.Range = size * 2
        light.Brightness = 6
        light.Parent = anchor
        TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 0 }):Play()
    end

    if Visual.FxShake then
        Shake.Until = now + 0.15
        Shake.Power = Visual.FxShakePower
    end

    if Assets.Parry and Visual.HitVolume > 0 then
        pcall(function()
            local sound = Assets.Parry:Clone()
            sound.Volume = Visual.HitVolume
            sound.PlaybackSpeed = 0.95 + math.random() * 0.15
            sound.Parent = anchor
            sound:Play()
        end)
    end
end

pcall(function()
    RunService:BindToRenderStep("TrainerShake", Enum.RenderPriority.Camera.Value + 1, function()
        local now = os.clock()
        if now >= Shake.Until then return end
        local camera = Workspace.CurrentCamera
        if not camera then return end
        local power = Shake.Power * ((Shake.Until - now) / 0.15)
        camera.CFrame *= CFrame.Angles(
            math.rad((math.random() - 0.5) * power),
            math.rad((math.random() - 0.5) * power), 0)
    end)
end)

-- the better trail, kept per ball
local Trails = setmetatable({}, { __mode = "k" })

local function updateBallLook(ball, danger)
    if not ball or not ball.Parent then return end
    local radius = math.max(ball.Size.X, 0.5) / 2

    -- trail
    local mine = Trails[ball]
    for _, trail in ipairs(ball:GetChildren()) do
        if trail:IsA("Trail") and (not mine or trail ~= mine.Trail) then
            trail.Enabled = not Visual.BetterTrail
        end
    end
    if Visual.BetterTrail then
        if not mine or not mine.Trail.Parent then
            local top = Instance.new("Attachment")
            top.Name = "TrainerTrailTop"
            top.Parent = ball
            local bottom = Instance.new("Attachment")
            bottom.Name = "TrainerTrailBottom"
            bottom.Parent = ball
            local trail = Instance.new("Trail")
            trail.Name = "TrainerTrail"
            trail.Attachment0 = top
            trail.Attachment1 = bottom
            trail.FaceCamera = true
            trail.LightEmission = 1
            trail.LightInfluence = 0
            trail.MinLength = 0
            trail.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(0.6, 0.4),
                NumberSequenceKeypoint.new(1, 1),
            })
            trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
            trail.Parent = ball
            mine = { Trail = trail, Top = top, Bottom = bottom }
            Trails[ball] = mine
        end
        local half = radius * Visual.TrailWidth
        mine.Top.Position = Vector3.new(0, half, 0)
        mine.Bottom.Position = Vector3.new(0, -half, 0)
        mine.Trail.Lifetime = Visual.TrailLife
        mine.Trail.Enabled = true
        if Visual.Rainbow then
            local keys = {}
            for i = 0, 4 do
                keys[#keys + 1] = ColorSequenceKeypoint.new(i / 4, rainbow(i * 0.12))
            end
            mine.Trail.Color = ColorSequence.new(keys)
        else
            mine.Trail.Color = ColorSequence.new(danger and Visual.DangerColor or Visual.TrailColor)
        end
    elseif mine then
        mine.Trail:Destroy()
        mine.Top:Destroy()
        mine.Bottom:Destroy()
        Trails[ball] = nil
    end

    -- colour
    if Visual.Rainbow and Visual.RainbowBall then
        ball.Color = rainbow()
        ball.Material = Enum.Material.Neon
    elseif danger and Better.Enabled then
        ball.Color = Visual.DangerColor
    elseif Visual.BallColor and not danger then
        ball.Color = Visual.BallColor
        ball.Material = Enum.Material.Neon
    end

    -- glow
    local light = ball:FindFirstChild("TrainerGlow")
    if Visual.Glow then
        if not light then
            light = Instance.new("PointLight")
            light.Name = "TrainerGlow"
            light.Brightness = 3
            light.Parent = ball
        end
        light.Range = Visual.GlowRange
        light.Color = ball.Color
    elseif light then
        light:Destroy()
    end
end

-- The game's own parry effects, hidden when asked: the clash and shield
-- particles it parents to your root, and its parry sound.
local function watchGameFx(char)
    local root = char and char:WaitForChild("HumanoidRootPart", 10)
    if not root then return end
    track(root.ChildAdded:Connect(function(child)
        if not Visual.HideGameFx then return end
        task.defer(function()
            if not child.Parent then return end
            if child:IsA("Attachment") and child:FindFirstChildWhichIsA("ParticleEmitter") then
                child:Destroy()
            elseif child:IsA("Sound") and (child.Name == "Parry" or child.Name == "Other") then
                child:Destroy()
            end
        end)
    end))
end
if LocalPlayer.Character then task.spawn(watchGameFx, LocalPlayer.Character) end
track(LocalPlayer.CharacterAdded:Connect(function(char) task.spawn(watchGameFx, char) end))

--// better ball -------------------------------------------------------------

local Engine = {
    Running = false,
    Ball = nil,
    Target = nil,       -- "p1" / "p2" / "you"
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

local function streakSpeed()
    local streak = leaderstat("Streak")
    local speed
    if Better.GainMode == "Multiply" then
        speed = Better.BaseSpeed * (Better.Multiplier ^ streak)
    else
        speed = Better.BaseSpeed + Better.Gain * streak
    end
    if speed ~= speed then speed = Better.MaxSpeed end
    return math.max(math.min(speed, Better.MaxSpeed), 1)
end

-- Speed for the trip about to start: from the streak, or whatever gets it
-- there in the set travel time.
local function engineSpeed(distance)
    if Better.Pace == "Travel time" and distance then
        return math.max(distance / math.max(Better.TravelTime, 0.001), 1)
    end
    return streakSpeed()
end

local function setTarget(name)
    Engine.Target = name
    local ball = Engine.Ball
    if not ball then return end
    local _, root = myCharacter()
    local goal = name == "you" and root or botPart(name)
    Engine.Speed = engineSpeed(goal and (goal.Position - ball.Position).Magnitude)
    local danger = name == "you"
    pcall(function()
        ball.Material = Enum.Material.Neon
        ball.Color = danger and Visual.DangerColor or (Visual.BallColor or Color3.fromRGB(163, 162, 165))
        if Engine.Highlight then Engine.Highlight.Enabled = danger end
        if Engine.BallHighlight then
            Engine.BallHighlight.Enabled = true
            Engine.BallHighlight.FillTransparency = danger and 0 or 1
        end
    end)
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

local LastGameFx = 0
local function playClash(at)
    -- the game's own clash, unless better effects replace it
    if Visual.BetterFx or Visual.HideGameFx then return end
    local now = os.clock()
    if now - LastGameFx < Visual.FxGap then return end
    LastGameFx = now
    pcall(function()
        local clash = Assets.Clash
        local clasher = value("Clasher")
        local fx = clash and clasher and clash:FindFirstChild(clasher.Value)
        if fx then
            local clone = fx:Clone()
            clone.Parent = at
            for _, emitter in ipairs(clone:GetChildren()) do
                if emitter:IsA("ParticleEmitter") then emitter:Emit(3) end
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
end

-- The game's deflect, for the better ball: BallMove's own copy is off with it.
-- instant: a parry landing this very frame (sync), so no timers are needed;
-- its animation and sound are thinned out at extreme rates.
local DeflectToken = 0
local LastDeflectFx = 0
local function engineDeflect(instant)
    if not Engine.Running or not Engine.Debounce or not Engine.Deflecting then return end
    if Engine.Debounce.Value > 0 and not instant then return end
    local char, root, hum = myCharacter()
    if not char then return end
    DeflectToken += 1
    local token = DeflectToken
    local stamp = os.clock()
    Engine.Debounce.Value = stamp
    Engine.Deflecting.Value = stamp
    pcall(function() event("Cooldown"):Fire() end)
    if stamp - LastDeflectFx >= math.max(Visual.FxGap, 0.1) then
        LastDeflectFx = stamp
        pcall(function()
            local animation = Instance.new("Animation")
            animation.AnimationId = "rbxassetid://15173331151"
            hum:LoadAnimation(animation):Play()
        end)
        if not Visual.HideGameFx and not Visual.BetterFx then
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
        end
    end
    if instant then return end
    task.delay(Better.ParryWindow, function()
        if token == DeflectToken and Engine.Deflecting and Engine.Deflecting.Value == stamp then
            Engine.Deflecting.Value = 0
        end
    end)
    task.delay(Better.Cooldown, function()
        if Engine.Debounce and Engine.Debounce.Value == stamp then Engine.Debounce.Value = 0 end
    end)
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
    end
    ball.Name = "BetterBall"
    ball.Size = Vector3.new(Better.BallSize, Better.BallSize, Better.BallSize)
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
        elseif Parry.Enabled and Parry.Sync and Engine.Debounce and Engine.Debounce.Value == 0 then
            -- sync: the parry lands on the exact frame of contact
            engineDeflect(true)
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
end

-- Moves the ball by this frame's time, not by one step: a trip that takes
-- less than a frame lands and the next trip starts with the time left, up to
-- HitsPerFrame parries a frame.
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
    local timeLeft = dt
    local hits = 0
    for _ = 1, 400 do
        if not Engine.Running or Engine.GraceUntil then return end
        local target = Engine.Target == "you" and root or botPart(Engine.Target)
        if not target then return end
        local goal = target.Position
        local toGoal = goal - ball.Position
        local distance = toGoal.Magnitude
        local radius = Engine.Target == "you" and Better.HitRadius or 2.5
        local travel = math.max(distance - radius, 0)
        local needed = (Engine.Target ~= "you" and Better.InstantBots) and 0
            or (Engine.Speed == math.huge and 0 or travel / Engine.Speed)
        if needed > timeLeft then
            ball.Position += toGoal.Unit * (Engine.Speed * timeLeft)
            return
        end
        timeLeft -= needed
        ball.Position = goal
        local wasYou = Engine.Target == "you"
        engineArrive()
        if wasYou then
            hits += 1
            if hits >= Better.HitsPerFrame then return end
        end
    end
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
    if Better.Enabled then engineDeflect(false) end
end)

do
    -- BallMove's own keys and taps, for while it is off
    local touchStart
    track(UserInputService.InputBegan:Connect(function(input, processed)
        if not Better.Enabled or processed then return end
        if input.KeyCode == Enum.KeyCode.F or input.UserInputType == Enum.UserInputType.MouseButton1 then
            engineDeflect(false)
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
        if touchStart then engineDeflect(false) end
        touchStart = nil
    end))
end

-- better effects on every parry, game ball or better ball
do
    local lastStreak = leaderstat("Streak")
    local recent = {}
    local function hook(stats)
        local streak = stats:WaitForChild("Streak", 10)
        if not streak then return end
        lastStreak = streak.Value
        track(streak.Changed:Connect(function(new)
            if new > lastStreak then
                local now = os.clock()
                recent[#recent + 1] = now
                if Visual.BetterFx then
                    local ball = Better.Enabled and Engine.Ball or gameBall()
                    local _, root = myCharacter()
                    local at = (root and root.Position) or (ball and ball.Position)
                    if at then parryEffect(at) end
                end
            end
            lastStreak = new
        end))
    end
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    if stats then task.spawn(hook, stats) end
    track(LocalPlayer.ChildAdded:Connect(function(child)
        if child.Name == "leaderstats" then task.spawn(hook, child) end
    end))
    -- parries over the last second
    task.spawn(function()
        while not Unloaded do
            task.wait(0.25)
            local cutoff = os.clock() - 1
            local kept = {}
            for _, t in ipairs(recent) do if t >= cutoff then kept[#kept + 1] = t end end
            recent = kept
            Stats.PerSecond = #recent
        end
    end)
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
        -- still "after you" while it sits on you in the grace window, so a parry
        -- that was a frame late still lands
        targetsMe = ball ~= nil and Engine.Target == "you"
        closing = Engine.Speed
    else
        local align
        ball, align = gameBall()
        if ball and align then
            applyControl(ball, align)
            targetsMe = gameBallTargetsMe(align)
        end
    end

    if ball then pcall(updateBallLook, ball, targetsMe) end

    if not ball or not root then
        Tracked.Ball = nil
        Stats.Status = Better.Enabled and "better ball, waiting for start" or "waiting for a round"
        Stats.Distance = 0
        return
    end

    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    local clock = os.clock()
    if not Better.Enabled then
        -- how fast it closes in: the larger of the gap shrinking (smoothed)
        -- and its velocity straight at you, so a sudden turn is caught early
        local rate = 0
        if Tracked.Ball == ball and Tracked.Distance and clock > Tracked.Clock then
            rate = (Tracked.Distance - distance) / (clock - Tracked.Clock)
        end
        Tracked.Closing = Tracked.Ball == ball and (Tracked.Closing * 0.4 + rate * 0.6) or rate
        Tracked.Ball, Tracked.Distance, Tracked.Clock = ball, distance, clock
        local radial = distance > 0 and ball.AssemblyLinearVelocity:Dot(offset.Unit) or 0
        closing = math.max(Tracked.Closing, radial)
    end
    Stats.Distance = distance
    Stats.Speed = closing or 0
    Stats.Status = targetsMe and "coming for you" or "with a bot"

    if not Parry.Enabled or not targetsMe then
        ParryPlannedAt = nil
        return
    end
    -- the better ball parries itself on contact when synced
    if Better.Enabled and Parry.Sync then return end

    -- the game counts a hit when the ball's edge reaches your body, not your
    -- centre, so time it to that
    local edge = math.max(distance - ball.Size.X / 2 - 2, 0)
    local arrival = (closing and closing > 0.5) and edge / closing or math.huge
    -- a parry decided now only goes out next frame at the earliest
    local frame = math.max(dt, 1 / 240)

    if Parry.Mode == "Spam" then
        if arrival <= Parry.SpamWindow + frame or distance <= Parry.MinDistance then
            for _ = 1, Parry.SpamPerFrame do fireParry() end
        end
        return
    end

    if not canParry() then return end
    local lead = math.min(Parry.Lead, Better.ParryWindow - 0.05)
    if arrival <= lead + frame or distance <= Parry.MinDistance then
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
    pcall(function() RunService:UnbindFromRenderStep("TrainerShake") end)
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
    if ball then
        pcall(function()
            for _, child in ipairs(ball:GetChildren()) do
                if child.Name:match("^Trainer") then child:Destroy() end
                if child:IsA("Trail") then child.Enabled = true end
            end
        end)
    end
    pcall(function() FxFolder:Destroy() end)
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

-- a text box for a number that takes 1e9, inf and the like
local function numberBox(box, index, cfg)
    return box:AddInput(index, {
        Text = cfg.Text,
        Tooltip = cfg.Tooltip,
        Default = tostring(cfg.Default),
        Placeholder = cfg.Placeholder or tostring(cfg.Default),
        Callback = function(text)
            local number = parseNumber(text, nil)
            if number == nil then return end
            if cfg.Min and number < cfg.Min then number = cfg.Min end
            cfg.Callback(number)
        end,
    })
end

do
    local Tab = Window:AddTab('Auto parry', 'shield', 'Parries for you')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('bbt_stats', {
        Cards = {
            { Title = 'Streak', Value = '0', Icon = 'flame' },
            { Title = 'Best', Value = '0', Icon = 'trophy' },
            { Title = 'Parries / s', Value = '0', Icon = 'zap' },
            { Title = 'Ball speed', Value = '0', Icon = 'gauge' },
            { Title = 'Distance', Value = '0', Icon = 'ruler' },
        },
    })
    local status = overview:AddLabel('ball: -')
    every(0.15, function()
        cards:SetValue('Streak', tostring(leaderstat("Streak")))
        cards:SetValue('Best', tostring(leaderstat("Best")))
        cards:SetValue('Parries / s', tostring(Stats.PerSecond))
        cards:SetValue('Ball speed', showNumber(Stats.Speed))
        cards:SetValue('Distance', showNumber(Stats.Distance))
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

    parry:AddDropdown('bbt_parry_mode', {
        Text = 'Mode',
        Tooltip = 'smart: one parry timed from the ball\'s distance and closing speed. spam: parries every frame once the ball is inside the spam window, for when it is too fast to time',
        Values = { 'Smart', 'Spam' },
        Default = Parry.Mode,
        Callback = function(v) Parry.Mode = v or "Smart" end,
    })

    parry:AddToggle('bbt_parry_sync', {
        Text = 'Sync with better ball',
        Tooltip = 'with the better ball on, the parry lands on the exact frame the ball reaches you, so it keeps up at any speed, 1e9 and inf included',
        Default = Parry.Sync,
        Callback = function(state) Parry.Sync = state end,
    })

    parry:AddSlider('bbt_lead', {
        Text = 'Smart: parry before arrival',
        Tooltip = 'how long before the ball reaches you to parry. a parry lasts 0.7s, so anything under that holds',
        Min = 0.01, Max = 0.6, Default = Parry.Lead, Rounding = 2, Suffix = 's',
        Callback = function(v) Parry.Lead = v end,
    })

    parry:AddSlider('bbt_spamwindow', {
        Text = 'Spam: window',
        Tooltip = 'how long before arrival the spam starts',
        Min = 0.02, Max = 0.6, Default = Parry.SpamWindow, Rounding = 2, Suffix = 's',
        Callback = function(v) Parry.SpamWindow = v end,
    })

    parry:AddSlider('bbt_spamrate', {
        Text = 'Spam: parries per frame',
        Min = 1, Max = 10, Default = Parry.SpamPerFrame, Rounding = 0,
        Callback = function(v) Parry.SpamPerFrame = v end,
    })

    parry:AddSlider('bbt_jitter', {
        Text = 'Random delay',
        Tooltip = 'smart mode: up to this much extra delay per parry, to look human. keep it under the lead or it gets late',
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
        Text = 'Start speed value',
        Tooltip = 'the game\'s speed value a new round starts on. the game adds it to the ball\'s top speed every time it changes target',
        Min = 1, Max = 50, Default = Control.StartSpeed, Rounding = 0,
        Callback = function(v) Control.StartSpeed = v end,
    })

    normal:AddToggle('bbt_lockspeed', {
        Text = 'Lock speed value',
        Tooltip = 'stops the speed value from going up each parry',
        Default = false,
        Callback = function(state) Control.LockSpeed = state end,
    })

    normal:AddSlider('bbt_speed', {
        Text = 'Locked speed value',
        Min = 1, Max = 50, Default = Control.Speed, Rounding = 0,
        Callback = function(v) Control.Speed = v end,
    })

    normal:AddToggle('bbt_auto', {
        Text = 'Auto restart',
        Tooltip = 'starts a new round as soon as you respawn (the game\'s Auto value)',
        Default = readNumber("Auto", 2) == 1,
        Callback = function(state) writeValue("Auto", state and 1 or 2) end,
    })

    local advanced = Tab:AddRightGroupbox('Advanced (game ball)', 'settings-2')

    numberBox(advanced, 'bbt_maxvel', {
        Text = 'Top speed cap',
        Tooltip = 'caps the game ball\'s top speed. 0 = no cap. takes 1e3 style numbers',
        Default = Control.MaxVelocity, Min = 0,
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

    local better = Tab:AddLeftGroupbox('Better ball', 'sparkles')

    better:AddToggle('bbt_better', {
        Text = 'Better ball',
        Tooltip = 'turns off the trainer\'s ball script and runs one that flies straight at its target, follows you, and never skips a hit at any speed. bots, grace and wander above still apply',
        Default = false,
        Callback = function(state) setBetter(state) end,
    })

    better:AddDropdown('bbt_pace', {
        Text = 'Pace',
        Tooltip = 'speed: studs per second from your streak. travel time: every trip takes the same time however far it is',
        Values = { 'Speed', 'Travel time' },
        Default = Better.Pace,
        Callback = function(v) Better.Pace = v or "Speed" end,
    })

    numberBox(better, 'bbt_travel', {
        Text = 'Travel time (s)',
        Tooltip = 'travel time pace: seconds for each trip. 0.001 and up',
        Default = Better.TravelTime, Min = 0.001,
        Callback = function(v) Better.TravelTime = v end,
    })

    better:AddToggle('bbt_instantbots', {
        Text = 'Instant bot hits',
        Tooltip = 'the ball skips the trip to the bots and comes straight back at you, so only your trips take time',
        Default = Better.InstantBots,
        Callback = function(state) Better.InstantBots = state end,
    })

    numberBox(better, 'bbt_base', {
        Text = 'Start speed (studs/s)',
        Tooltip = 'speed pace: how fast it starts',
        Default = Better.BaseSpeed, Min = 1,
        Callback = function(v) Better.BaseSpeed = v end,
    })

    better:AddDropdown('bbt_gainmode', {
        Text = 'Speed up by',
        Tooltip = 'add: plus the amount below each parry. multiply: times the multiplier each parry, which climbs fast',
        Values = { 'Add', 'Multiply' },
        Default = Better.GainMode,
        Callback = function(v) Better.GainMode = v or "Add" end,
    })

    numberBox(better, 'bbt_gain', {
        Text = 'Add per parry (studs/s)',
        Default = Better.Gain, Min = 0,
        Callback = function(v) Better.Gain = v end,
    })

    numberBox(better, 'bbt_mult', {
        Text = 'Multiply per parry',
        Tooltip = 'e.g. 1.05 is 5% faster every parry',
        Default = Better.Multiplier, Min = 1,
        Callback = function(v) Better.Multiplier = v end,
    })

    numberBox(better, 'bbt_max', {
        Text = 'Top speed (studs/s)',
        Tooltip = 'any number: 5000, 1e6, 1e9, inf',
        Default = Better.MaxSpeed, Min = 1,
        Callback = function(v) Better.MaxSpeed = v end,
    })

    better:AddSlider('bbt_hitsframe', {
        Text = 'Most parries per frame',
        Tooltip = 'at speeds where the ball would cover several trips in one frame, how many of them a frame may hold',
        Min = 1, Max = 100, Default = Better.HitsPerFrame, Rounding = 0,
        Callback = function(v) Better.HitsPerFrame = v end,
    })

    better:AddSlider('bbt_youchance', {
        Text = 'Comes at you',
        Tooltip = 'with two bots, the chance the first bot sends it to you instead of the other bot',
        Min = 0, Max = 100, Default = Better.YouChance, Rounding = 0, Suffix = '%',
        Callback = function(v) Better.YouChance = v end,
    })

    better:AddSlider('bbt_radius', {
        Text = 'Hit radius',
        Min = 1, Max = 15, Default = Better.HitRadius, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Better.HitRadius = v end,
    })

    better:AddSlider('bbt_bsize', {
        Text = 'Ball size',
        Min = 0.5, Max = 10, Default = Better.BallSize, Rounding = 1, Suffix = ' studs',
        Callback = function(v)
            Better.BallSize = v
            if Engine.Ball then Engine.Ball.Size = Vector3.new(v, v, v) end
        end,
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

do
    local Tab = Window:AddTab('Visuals', 'palette', 'Trail, effects and the ball\'s look')

    local trail = Tab:AddLeftGroupbox('Trail', 'wind')

    trail:AddToggle('bbt_trail', {
        Text = 'Better trail',
        Tooltip = 'a glowing trail that tapers off, in place of the game\'s',
        Default = false,
        Callback = function(state) Visual.BetterTrail = state end,
    }):AddColorPicker('bbt_trail_color', {
        Default = Visual.TrailColor,
        Title = 'Trail colour',
        Callback = function(color) Visual.TrailColor = color end,
    })

    trail:AddSlider('bbt_trail_life', {
        Text = 'Trail length',
        Min = 0.05, Max = 2, Default = Visual.TrailLife, Rounding = 2, Suffix = 's',
        Callback = function(v) Visual.TrailLife = v end,
    })

    trail:AddSlider('bbt_trail_width', {
        Text = 'Trail width',
        Min = 0.2, Max = 4, Default = Visual.TrailWidth, Rounding = 1, Suffix = 'x',
        Callback = function(v) Visual.TrailWidth = v end,
    })

    trail:AddToggle('bbt_rainbow', {
        Text = 'Rainbow',
        Tooltip = 'cycles the trail and the effects through every colour',
        Default = false,
        Callback = function(state) Visual.Rainbow = state end,
    })

    trail:AddToggle('bbt_rainbow_ball', {
        Text = 'Rainbow ball too',
        Default = false,
        Callback = function(state) Visual.RainbowBall = state end,
    })

    trail:AddSlider('bbt_rainbow_speed', {
        Text = 'Rainbow speed',
        Min = 0.05, Max = 3, Default = Visual.RainbowSpeed, Rounding = 2,
        Callback = function(v) Visual.RainbowSpeed = v end,
    })

    local fx = Tab:AddRightGroupbox('Parry effects', 'sparkle')

    fx:AddToggle('bbt_fx', {
        Text = 'Better effects',
        Tooltip = 'a shock sphere, ring, sparks and a light flash on every parry, in place of the game\'s clash',
        Default = false,
        Callback = function(state) Visual.BetterFx = state end,
    }):AddColorPicker('bbt_fx_color', {
        Default = Visual.FxColor,
        Title = 'Effect colour',
        Callback = function(color) Visual.FxColor = color end,
    })

    fx:AddToggle('bbt_hidegame', {
        Text = 'Hide the game\'s effects',
        Tooltip = 'removes the game\'s own clash and shield particles and parry sounds',
        Default = false,
        Callback = function(state) Visual.HideGameFx = state end,
    })

    fx:AddSlider('bbt_fx_size', {
        Text = 'Effect size',
        Min = 2, Max = 40, Default = Visual.FxSize, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Visual.FxSize = v end,
    })

    fx:AddSlider('bbt_fx_sparks', {
        Text = 'Sparks',
        Min = 0, Max = 120, Default = Visual.FxSparks, Rounding = 0,
        Callback = function(v) Visual.FxSparks = v end,
    })

    fx:AddToggle('bbt_fx_flash', {
        Text = 'Light flash',
        Default = Visual.FxFlash,
        Callback = function(state) Visual.FxFlash = state end,
    })

    fx:AddToggle('bbt_fx_shake', {
        Text = 'Camera shake',
        Default = Visual.FxShake,
        Callback = function(state) Visual.FxShake = state end,
    })

    fx:AddSlider('bbt_fx_shakepower', {
        Text = 'Shake strength',
        Min = 0.1, Max = 3, Default = Visual.FxShakePower, Rounding = 1,
        Callback = function(v) Visual.FxShakePower = v end,
    })

    fx:AddSlider('bbt_fx_gap', {
        Text = 'Time between effects',
        Tooltip = 'at very fast streaks only one effect plays per this much time, so the screen stays readable',
        Min = 0, Max = 0.5, Default = Visual.FxGap, Rounding = 2, Suffix = 's',
        Callback = function(v) Visual.FxGap = v end,
    })

    fx:AddSlider('bbt_fx_volume', {
        Text = 'Hit sound',
        Min = 0, Max = 2, Default = Visual.HitVolume, Rounding = 1,
        Callback = function(v) Visual.HitVolume = v end,
    })

    local look = Tab:AddLeftGroupbox('Ball look', 'circle')

    look:AddToggle('bbt_ballcolor_on', {
        Text = 'Custom ball colour',
        Default = false,
        Callback = function(state)
            Visual.BallColor = state and (Library.Options.bbt_ballcolor and Library.Options.bbt_ballcolor.Value) or nil
        end,
    }):AddColorPicker('bbt_ballcolor', {
        Default = Color3.fromRGB(163, 162, 165),
        Title = 'Ball colour',
        Callback = function(color)
            local toggle = Library.Toggles.bbt_ballcolor_on
            if toggle and toggle.Value then Visual.BallColor = color end
        end,
    })

    look:AddLabel('Coming for you'):AddColorPicker('bbt_dangercolor', {
        Default = Visual.DangerColor,
        Title = 'Colour when it targets you',
        Callback = function(color) Visual.DangerColor = color end,
    })

    look:AddToggle('bbt_glow', {
        Text = 'Glow',
        Default = false,
        Callback = function(state) Visual.Glow = state end,
    })

    look:AddSlider('bbt_glowrange', {
        Text = 'Glow range',
        Min = 2, Max = 40, Default = Visual.GlowRange, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Visual.GlowRange = v end,
    })
end

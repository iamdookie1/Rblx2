--// Blade Ball ------------------------------------------------------------------------
-- Written from how the game is laid out (names below), not from a dump of this exact
-- version, so a renamed folder or attribute after an update is the first thing to check.
--
--  * Balls live in Workspace.Balls (Workspace.TrainingBalls in training). The live ball
--    has the realBall attribute, `target` is the name of the player it's flying at, and
--    its motion is the "zoomies" LinearVelocity (VectorVelocity).
--  * Players still in the round are in Workspace.Alive. Effects (Tornado...) spawn in
--    Workspace.Runtime.
--  * Remotes: ParrySuccess / ParrySuccessAll fire on a good parry, DeathBall and
--    InfinityBall flag those abilities, and the sleitnick net package carries the
--    Time Hole and Slashes of Fury events. AbilityButtonPress (and ParryButtonPress
--    when it exists) are the game's own client-side buttons: firing them is the same
--    as pressing the button on screen.
--  * The game signs every parry it sends. This script never builds or sends a parry
--    packet itself: it presses the game's own parry input (the parry button event, or
--    the F key / a click), and the game's code sends the real, signed parry and plays
--    its own animation.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__BladeBallUnload then
    pcall(Genv.__BladeBallUnload)
end
Genv.__BladeBallRun = (Genv.__BladeBallRun or 0) + 1
local RUN = Genv.__BladeBallRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__BladeBallRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local ref = "main"
local resolved, shaOrError = pcall(function()
    local commit = HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main"))
    return commit.sha
end)
if resolved and shaOrError then
    ref = shaOrError
else
    warn("[Ui3] could not resolve the latest commit, falling back to main: " .. tostring(shaOrError))
end
local Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()

local S = {
    -- auto parry
    AutoParry = false, Training = true, Input = "Auto", Accuracy = 50, PingComp = 100, ReactionMs = 0,
    CurveCheck = true, RetryAfter = 450, MinRange = 10,
    DetectInfinity = true, DetectDeathSlash = true, DetectTimeHole = true, DetectFury = true, DetectTornado = true,
    -- ability
    AutoAbility = false, AbilityMode = "Instead of a parry",
    -- spam
    SpamKey = false, SpamRate = 18, AutoSpam = false, ClashRange = 18, ClashBallRange = 22, ClashWindow = 600,
    SpamAnimation = false,
    -- visuals
    BallEsp = true, BallInfo = true, ParryRing = false, Trajectory = false, TargetEsp = false,
    -- misc
    AntiAfk = true,
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

local function getHui()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    return (ok and hui) or CoreGui
end

local VisualGui = Instance.new("ScreenGui")
VisualGui.Name = "BladeBallVisuals"
VisualGui.IgnoreGuiInset = true
VisualGui.ResetOnSpawn = false
pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(VisualGui)
    end
end)
if not pcall(function()
    VisualGui.Parent = getHui()
end) then
    VisualGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function rootPart()
    local c = LocalPlayer.Character
    return c and (c.PrimaryPart or c:FindFirstChild("HumanoidRootPart"))
end
local function ping()
    local ok, ms = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    return (ok and ms or 80) / 1000
end

local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 10)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end
local function netEvent(name)
    local ok, ev = pcall(function()
        local index = ReplicatedStorage.Packages._Index
        for _, pkg in index:GetChildren() do
            if pkg.Name:find("sleitnick_net", 1, true) then
                return pkg.net:FindFirstChild("RE/" .. name)
            end
        end
        return nil
    end)
    return ok and ev or nil
end

--// Balls \\--
local function realBalls(folderName)
    local out = {}
    local folder = Workspace:FindFirstChild(folderName)
    if folder then
        for _, ball in folder:GetChildren() do
            if ball:IsA("BasePart") and ball:GetAttribute("realBall") then
                out[#out + 1] = ball
            end
        end
    end
    return out
end
local function ballVelocity(ball)
    local z = ball:FindFirstChild("zoomies")
    if z and z:IsA("LinearVelocity") then
        return z.VectorVelocity
    end
    return ball.AssemblyLinearVelocity
end
local function isAlive()
    local folder = Workspace:FindFirstChild("Alive")
    local c = LocalPlayer.Character
    return c and folder and c.Parent == folder
end
local function closestEnemy()
    local hrp = rootPart()
    local folder = Workspace:FindFirstChild("Alive")
    if not hrp or not folder then
        return nil, math.huge
    end
    local best, bestD
    for _, model in folder:GetChildren() do
        if model ~= LocalPlayer.Character and model.PrimaryPart then
            local d = (model.PrimaryPart.Position - hrp.Position).Magnitude
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best, bestD or math.huge
end

--// State from the game's own events \\--
local Game = {
    infinity = false, deathSlash = false, timeHole = false, fury = false, furyCount = 0,
    tornadoAt = 0, parries = 0, successes = 0, lastParry = 0, lastSuccess = 0,
}
local BallState = {} -- [ball] = { target, parriedAt, targetChangedAt, changes = {times} }

local Log -- set once the UI exists
local function logEvent(text, color)
    if Log then
        pcall(Log.Log, Log, text, color)
    end
end

local function isMe(who)
    return who == LocalPlayer or who == LocalPlayer.Name or (typeof(who) == "Instance" and who.Name == LocalPlayer.Name)
end

task.spawn(function()
    local r = remote("InfinityBall")
    if r then
        bind(r.OnClientEvent, function(_, active)
            Game.infinity = active == true
        end)
    end
    r = remote("DeathBall")
    if r then
        bind(r.OnClientEvent, function(_, active)
            Game.deathSlash = active == true
        end)
    end
    r = remote("ParrySuccess")
    if r then
        bind(r.OnClientEvent, function()
            Game.successes += 1
            Game.lastSuccess = os.clock()
        end)
    end
    local ev = netEvent("TimeHoleActivate")
    if ev then
        bind(ev.OnClientEvent, function(who)
            if isMe(who) then
                Game.timeHole = true
            end
        end)
    end
    ev = netEvent("TimeHoleDeactivate")
    if ev then
        bind(ev.OnClientEvent, function()
            Game.timeHole = false
        end)
    end
    ev = netEvent("SlashesOfFuryActivate")
    if ev then
        bind(ev.OnClientEvent, function(who)
            if isMe(who) then
                Game.fury, Game.furyCount = true, 0
            end
        end)
    end
    ev = netEvent("SlashesOfFuryEnd")
    if ev then
        bind(ev.OnClientEvent, function()
            Game.fury, Game.furyCount = false, 0
        end)
    end
    ev = netEvent("SlashesOfFuryParry")
    if ev then
        bind(ev.OnClientEvent, function()
            Game.furyCount += 1
        end)
    end
end)

--// Parrying: the game's own input \\--
local ParryButton = nil
task.spawn(function()
    local b = remote("ParryButtonPress")
    if b and b:IsA("BindableEvent") then
        ParryButton = b
    end
end)

local function pressKey(code)
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, code, false, game)
        VirtualInputManager:SendKeyEvent(false, code, false, game)
    end)
end
local function click()
    pcall(function()
        local pos = UserInputService:GetMouseLocation()
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
end

-- The parry animation for your sword, for spam presses the game doesn't animate.
local AnimCache = {}
local function parryAnimation()
    local c = LocalPlayer.Character
    local sword = c and c:GetAttribute("CurrentlyEquippedSword")
    local key = sword or "Default"
    if AnimCache[key] ~= nil then
        return AnimCache[key]
    end
    local anim = false
    pcall(function()
        local api = ReplicatedStorage.Shared.SwordAPI.Collection
        local kind
        if sword then
            local data = ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(sword)
            kind = type(data) == "table" and data.AnimationType
        end
        local folder = kind and api:FindFirstChild(kind) or api:FindFirstChild("Default")
        anim = folder and (folder:FindFirstChild("GrabParry") or folder:FindFirstChild("Grab")) or false
    end)
    AnimCache[key] = anim
    return anim
end
local LastAnim = 0
local function playParryAnimation()
    if os.clock() - LastAnim < 0.2 then
        return
    end
    LastAnim = os.clock()
    local c = LocalPlayer.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    local anim = parryAnimation()
    if animator and anim then
        pcall(function()
            for _, t in animator:GetPlayingAnimationTracks() do
                if t.Name == "GrabParry" or t.Name == "Grab" then
                    t:Stop(0)
                end
            end
            animator:LoadAnimation(anim):Play(0, 1, 1)
        end)
    end
end

local function parry(fromSpam)
    local method = S.Input
    if method == "Auto" then
        method = ParryButton and "Parry button" or "F key"
    end
    if method == "Parry button" and ParryButton then
        pcall(ParryButton.Fire, ParryButton)
    elseif method == "Click" then
        click()
    else
        pressKey(Enum.KeyCode.F)
    end
    Game.parries += 1
    Game.lastParry = os.clock()
    if fromSpam and S.SpamAnimation then
        playParryAnimation()
    end
end

--// Ability \\--
local DEFLECT_ABILITIES = { "Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash" }
local function abilityReady()
    local ok, ready = pcall(function()
        return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5
    end)
    return ok and ready
end
local function deflectAbility()
    local c = LocalPlayer.Character
    local abilities = c and c:FindFirstChild("Abilities")
    if not abilities then
        return nil
    end
    for _, name in DEFLECT_ABILITIES do
        local a = abilities:FindFirstChild(name)
        if a and a.Enabled then
            return name
        end
    end
    return nil
end
local function useAbility()
    local b = remote("AbilityButtonPress")
    if b and b:IsA("BindableEvent") then
        pcall(b.Fire, b)
        return true
    end
    return false
end

--// Auto parry logic \\--
-- How far out to parry: what the ball covers in your ping plus a window that shrinks
-- as the ball gets faster (fast balls need less lead, they'd overshoot otherwise).
local function parryDistance(speed)
    local p = ping() * (S.PingComp / 100)
    local accuracy = 0.7 + (S.Accuracy - 1) * (0.9 / 99)
    local divisor = (2.4 + math.clamp(speed - 9.5, 0, 650) * 0.002) * accuracy
    return speed * p + math.max(speed / divisor, S.MinRange)
end

local function stateOf(ball)
    local st = BallState[ball]
    if not st then
        st = { target = nil, parriedAt = 0, changes = {}, lastDot = 1, warpAt = 0 }
        BallState[ball] = st
    end
    local target = ball:GetAttribute("target")
    if target ~= st.target then
        st.target = target
        st.parriedAt = 0
        table.insert(st.changes, os.clock())
        if #st.changes > 8 then
            table.remove(st.changes, 1)
        end
    end
    return st
end

-- A curving ball isn't flying at you yet; parrying it early wastes the parry.
local function curving(ball, st, toMe, speed, dist)
    if not S.CurveCheck or dist < 25 then
        return false
    end
    local v = ballVelocity(ball)
    local dot = v.Unit:Dot(toMe.Unit)
    -- A sudden swing in direction is the start of a curve.
    if math.abs(dot - st.lastDot) > 0.35 then
        st.warpAt = os.clock()
    end
    st.lastDot = dot
    local reach = dist / math.max(speed, 1)
    if os.clock() - st.warpAt < reach / 1.4 then
        return true
    end
    return dot < math.clamp(0.55 - ping() * 0.75, -1, 0.45)
end

local function blockedByAbility(ball)
    if S.DetectInfinity and Game.infinity then
        return true
    end
    if S.DetectDeathSlash and Game.deathSlash then
        return true
    end
    if S.DetectTimeHole and Game.timeHole then
        return true
    end
    if S.DetectFury and Game.fury then
        return true
    end
    if S.DetectTornado then
        local runtime = Workspace:FindFirstChild("Runtime")
        if ball:FindFirstChild("AeroDynamicSlashVFX") then
            Game.tornadoAt = os.clock()
        end
        local tornado = runtime and runtime:FindFirstChild("Tornado")
        if tornado and os.clock() - Game.tornadoAt < (tornado:GetAttribute("TornadoTime") or 1) + 0.35 then
            return true
        end
    end
    local hrp = rootPart()
    if hrp and hrp:FindFirstChild("SingularityCape") then
        return true
    end
    return ball:FindFirstChild("ComboCounter") ~= nil
end

local Live = { ball = nil, speed = 0, dist = 0, tti = 0, range = 0, target = "-", curving = false }

local function considerBall(ball)
    local hrp = rootPart()
    if not hrp then
        return
    end
    local st = stateOf(ball)
    local toMe = hrp.Position - ball.Position
    local dist = toMe.Magnitude
    local v = ballVelocity(ball)
    local speed = v.Magnitude
    local range = parryDistance(speed)
    local curve = st.target == LocalPlayer.Name and speed >= 1 and curving(ball, st, toMe, speed, dist) or false

    if Live.ball == nil or st.target == LocalPlayer.Name then
        Live.ball, Live.speed, Live.dist, Live.range, Live.curving = ball, speed, dist, range, curve
        Live.target = tostring(st.target or "-")
        Live.tti = speed > 1 and dist / speed or math.huge
    end

    if st.target ~= LocalPlayer.Name or speed < 1 then
        return
    end
    -- Already parried this throw: wait for it to change hands, or retry if it didn't take.
    if st.parriedAt > 0 and os.clock() - st.parriedAt < S.RetryAfter / 1000 then
        return
    end
    if curve or blockedByAbility(ball) then
        return
    end
    if dist > range then
        return
    end

    -- Use the ability instead, when it's one that deflects and it's ready.
    if S.AutoAbility and S.AbilityMode == "Instead of a parry" and abilityReady() and deflectAbility() then
        if useAbility() then
            st.parriedAt = os.clock()
            logEvent("Used " .. deflectAbility() .. " instead of a parry")
            return
        end
    end

    st.parriedAt = os.clock()
    if S.ReactionMs > 0 then
        task.delay(S.ReactionMs / 1000, function()
            if alive() and ball.Parent and ball:GetAttribute("target") == LocalPlayer.Name then
                parry(false)
            end
        end)
    else
        parry(false)
    end
end

local function autoParryStep()
    Live.ball = nil
    if not S.AutoParry then
        return
    end
    for _, ball in realBalls("Balls") do
        considerBall(ball)
    end
    if S.Training then
        for _, ball in realBalls("TrainingBalls") do
            considerBall(ball)
        end
    end
    for ball in BallState do
        if not ball.Parent then
            BallState[ball] = nil
        end
    end
end

--// Spam \\--
local Spam = { held = false, acc = 0, auto = false }

-- A clash: you and the closest player trading the ball fast and close.
local function clashing()
    local hrp = rootPart()
    if not hrp then
        return false
    end
    local enemy, enemyDist = closestEnemy()
    if not enemy or enemyDist > S.ClashRange then
        return false
    end
    for _, ball in realBalls("Balls") do
        local st = BallState[ball]
        local dist = (ball.Position - hrp.Position).Magnitude
        if st and dist <= S.ClashBallRange and (st.target == LocalPlayer.Name or st.target == enemy.Name) then
            local n = #st.changes
            if n >= 2 and os.clock() - st.changes[n - 1] <= S.ClashWindow / 1000 then
                return true
            end
        end
    end
    return false
end

local function spamStep(dt)
    local furySpam = S.DetectFury and Game.fury and Game.furyCount < 36
    Spam.auto = S.AutoSpam and clashing()
    if not (Spam.held or Spam.auto or furySpam) then
        Spam.acc = 0
        return
    end
    Spam.acc += dt
    local every = 1 / math.max(S.SpamRate, 1)
    local fired = 0
    while Spam.acc >= every and fired < 4 do
        Spam.acc -= every
        fired += 1
        parry(true)
    end
    if Spam.acc > every * 4 then
        Spam.acc = 0
    end
end

--// Visuals \\--
local Vis = {}
local function ensureVisuals()
    if Vis.highlight then
        return
    end
    local hl = Instance.new("Highlight")
    hl.FillTransparency = 0.55
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = VisualGui
    Vis.highlight = hl

    local bb = Instance.new("BillboardGui")
    bb.Size = UDim2.fromOffset(220, 40)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    bb.Parent = VisualGui
    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.fromScale(1, 1)
    text.Font = Enum.Font.GothamBold
    text.TextSize = 13
    text.TextStrokeTransparency = 0.3
    text.TextColor3 = Color3.new(1, 1, 1)
    text.Parent = bb
    Vis.info, Vis.infoText = bb, text

    local ring = Instance.new("CylinderHandleAdornment")
    ring.Height = 0.15
    ring.Transparency = 0.6
    ring.AlwaysOnTop = false
    ring.Visible = false
    ring.Parent = VisualGui
    Vis.ring = ring

    local holder = Instance.new("Part")
    holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch = true, false, false, false
    holder.Transparency = 1
    holder.Size = Vector3.new(0.2, 0.2, 0.2)
    holder.Parent = Camera
    local a0 = Instance.new("Attachment", holder)
    local a1 = Instance.new("Attachment", holder)
    local beam = Instance.new("Beam")
    beam.Attachment0, beam.Attachment1 = a0, a1
    beam.Width0, beam.Width1 = 0.25, 0.05
    beam.FaceCamera = true
    beam.LightEmission = 1
    beam.Parent = holder
    Vis.beamHolder, Vis.a0, Vis.a1, Vis.beam = holder, a0, a1, beam

    local thl = Instance.new("Highlight")
    thl.FillTransparency = 0.75
    thl.OutlineTransparency = 0
    thl.OutlineColor = Color3.fromRGB(255, 200, 80)
    thl.FillColor = Color3.fromRGB(255, 200, 80)
    thl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    thl.Parent = VisualGui
    Vis.targetHl = thl
end

local function updateVisuals()
    ensureVisuals()
    local ball = Live.ball
    local mine = ball and ball:GetAttribute("target") == LocalPlayer.Name
    local color = mine and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(120, 200, 255)

    Vis.highlight.Adornee = S.BallEsp and ball or nil
    Vis.highlight.FillColor, Vis.highlight.OutlineColor = color, color

    Vis.info.Adornee = S.BallInfo and ball or nil
    if ball and S.BallInfo then
        Vis.infoText.Text = string.format("%s · %d sp · %dm%s", Live.target, math.floor(Live.speed), math.floor(Live.dist),
            Live.curving and " · curving" or "")
        Vis.infoText.TextColor3 = color
    end

    local hrp = rootPart()
    if S.ParryRing and hrp and ball then
        local r = math.clamp(Live.range, 1, 400)
        Vis.ring.Adornee = Workspace.Terrain
        Vis.ring.Radius = r
        Vis.ring.InnerRadius = math.max(0, r - 0.6)
        Vis.ring.Color3 = color
        Vis.ring.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 2.8, 0)) * CFrame.Angles(math.rad(90), 0, 0)
        Vis.ring.Visible = true
    else
        Vis.ring.Visible = false
    end

    if S.Trajectory and ball then
        local v = ballVelocity(ball)
        Vis.a0.WorldPosition = ball.Position
        Vis.a1.WorldPosition = ball.Position + v * 0.4
        Vis.beam.Color = ColorSequence.new(color)
        Vis.beam.Enabled = true
    else
        Vis.beam.Enabled = false
    end

    local targetModel
    if S.TargetEsp and ball and not mine then
        local folder = Workspace:FindFirstChild("Alive")
        targetModel = folder and folder:FindFirstChild(tostring(ball:GetAttribute("target")))
    end
    Vis.targetHl.Adornee = targetModel
end

local function clearVisuals()
    for _, k in { "highlight", "info", "ring", "beamHolder", "targetHl" } do
        if Vis[k] then
            pcall(Vis[k].Destroy, Vis[k])
        end
    end
    table.clear(Vis)
end

bind(LocalPlayer.Idled, function()
    if not alive() or not S.AntiAfk then
        return
    end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "dookie hub · Ui3",
    Icon = "swords",
    Size = UDim2.fromOffset(760, 580),
    ConfigFolder = "Ui3/BladeBall",
})

local UI = {}

do -- Dashboard
    local Tab = Window:AddTab("Dashboard", "layout-dashboard", "The ball at a glance")
    local BallBox = Tab:AddBigGroupbox("Ball", "circle-dot")
    UI.BallCards = BallBox:AddStatCards("BallCards", {
        Cards = {
            { Title = "Target", Value = "-", Icon = "crosshair" },
            { Title = "Speed", Value = "-", Icon = "gauge" },
            { Title = "Distance", Value = "-", Icon = "ruler" },
            { Title = "Hits you in", Value = "-", Icon = "timer" },
        },
    })
    UI.RangeBar = BallBox:AddProgressBar("RangeBar", { Text = "Distance vs parry range", Default = 0, Max = 1, Percent = true })
    local YouBox = Tab:AddBigGroupbox("You", "user")
    UI.YouCards = YouBox:AddStatCards("YouCards", {
        Cards = {
            { Title = "Parries", Value = "0", Icon = "shield" },
            { Title = "Successful", Value = "0", Icon = "check" },
            { Title = "Ping", Value = "-", Icon = "wifi" },
            { Title = "Status", Value = "-", Icon = "activity" },
        },
    })
    local LogBox = Tab:AddBigGroupbox("Log", "scroll-text")
    Log = LogBox:AddLog("EventLog", { Height = 140, MaxLines = 150, Timestamps = true })
end

do -- Auto parry
    local Tab = Window:AddTab("Auto Parry", "shield", "Timing, input and ability checks")
    local Main = Tab:AddLeftGroupbox("Auto parry", "shield")
    Main:AddToggle("AutoParry", {
        Text = "Auto parry",
        Default = false,
        Callback = function(v)
            S.AutoParry = v
        end,
    }):AddKeyPicker("AutoParryKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry" })
    Main:AddToggle("Training", {
        Text = "Training balls too",
        Default = S.Training,
        Tooltip = "Also parries the balls in training mode",
        Callback = function(v)
            S.Training = v
        end,
    })
    Main:AddDropdown("Input", {
        Text = "Parry with",
        Values = { "Auto", "Parry button", "F key", "Click" },
        Default = S.Input,
        Tooltip = "All of these go through the game's own parry, so it sends a real parry and plays your animation. Auto uses the parry button when the game has one, else F",
        Callback = function(v)
            S.Input = v or "Auto"
        end,
    })
    Main:AddSlider("Accuracy", {
        Text = "Timing",
        Default = S.Accuracy,
        Min = 1,
        Max = 100,
        Tooltip = "Lower parries earlier, higher parries later. 50 is a good start; raise it if you parry too early",
        Callback = function(v)
            S.Accuracy = v
        end,
    })
    Main:AddSlider("PingComp", {
        Text = "Ping compensation",
        Default = S.PingComp,
        Min = 0,
        Max = 200,
        Suffix = "%",
        Tooltip = "How much of your ping to parry early by",
        Callback = function(v)
            S.PingComp = v
        end,
    })
    Main:AddSlider("MinRange", {
        Text = "Always parry within",
        Default = S.MinRange,
        Min = 5,
        Max = 30,
        Suffix = " studs",
        Callback = function(v)
            S.MinRange = v
        end,
    })
    Main:AddSlider("ReactionMs", {
        Text = "Reaction delay",
        Default = S.ReactionMs,
        Min = 0,
        Max = 200,
        Suffix = " ms",
        Tooltip = "Waits this long before pressing, to look human. Keep it low on fast balls",
        Callback = function(v)
            S.ReactionMs = v
        end,
    })
    Main:AddSlider("RetryAfter", {
        Text = "Retry if it didn't take",
        Default = S.RetryAfter,
        Min = 150,
        Max = 1500,
        Suffix = " ms",
        Callback = function(v)
            S.RetryAfter = v
        end,
    })
    Main:AddToggle("CurveCheck", {
        Text = "Wait out curves",
        Default = S.CurveCheck,
        Tooltip = "Doesn't parry a ball that's curving around you until it actually heads your way",
        Callback = function(v)
            S.CurveCheck = v
        end,
    })

    local Det = Tab:AddRightGroupbox("Ability checks", "scan-eye")
    Det:AddToggle("DetectInfinity", { Text = "Infinity", Default = S.DetectInfinity, Callback = function(v)
        S.DetectInfinity = v
    end })
    Det:AddToggle("DetectDeathSlash", { Text = "Death Slash", Default = S.DetectDeathSlash, Callback = function(v)
        S.DetectDeathSlash = v
    end })
    Det:AddToggle("DetectTimeHole", { Text = "Time Hole", Default = S.DetectTimeHole, Callback = function(v)
        S.DetectTimeHole = v
    end })
    Det:AddToggle("DetectFury", {
        Text = "Slashes of Fury",
        Default = S.DetectFury,
        Tooltip = "Holds normal parries during it and spams the catches instead",
        Callback = function(v)
            S.DetectFury = v
        end,
    })
    Det:AddToggle("DetectTornado", { Text = "Tornado (Aerodynamic Slash)", Default = S.DetectTornado, Callback = function(v)
        S.DetectTornado = v
    end })
    Det:AddLabel("While one of these is up, auto parry holds off instead of wasting the parry.", true)

    local Ab = Tab:AddRightGroupbox("Ability", "zap")
    Ab:AddToggle("AutoAbility", {
        Text = "Auto ability",
        Default = false,
        Tooltip = "Presses the game's ability button for deflecting abilities (Raging/Calming Deflection, Rapture, Aerodynamic Slash, Fracture, Death Slash)",
        Callback = function(v)
            S.AutoAbility = v
        end,
    })
    Ab:AddDropdown("AbilityMode", {
        Text = "Use it",
        Values = { "Instead of a parry", "Whenever ready" },
        Default = S.AbilityMode,
        Callback = function(v)
            S.AbilityMode = v or "Instead of a parry"
        end,
    })
end

do -- Spam
    local Tab = Window:AddTab("Spam", "zap", "Manual and auto spam")
    local Man = Tab:AddLeftGroupbox("Manual spam", "keyboard")
    Man:AddLabel("Hold spam"):AddKeyPicker("SpamKey", {
        Default = "E",
        Mode = "Hold",
        Text = "Spam parry",
        Callback = function(state)
            Spam.held = state == true
        end,
    })
    Man:AddSlider("SpamRate", {
        Text = "Spam speed",
        Default = S.SpamRate,
        Min = 5,
        Max = 60,
        Suffix = " /s",
        Tooltip = "Presses per second. Very high rates look inhuman",
        Callback = function(v)
            S.SpamRate = v
        end,
    })
    Man:AddToggle("SpamAnimation", {
        Text = "Animate every press",
        Default = S.SpamAnimation,
        Tooltip = "Plays your sword's parry animation on spam presses the game doesn't animate",
        Callback = function(v)
            S.SpamAnimation = v
        end,
    })

    local Auto = Tab:AddRightGroupbox("Auto spam (clashes)", "swords")
    Auto:AddToggle("AutoSpam", {
        Text = "Auto spam in clashes",
        Default = false,
        Tooltip = "Spams when you and the closest player are trading the ball fast and close",
        Callback = function(v)
            S.AutoSpam = v
        end,
    })
    Auto:AddSlider("ClashRange", { Text = "Player within", Default = S.ClashRange, Min = 5, Max = 40, Suffix = " studs", Callback = function(v)
        S.ClashRange = v
    end })
    Auto:AddSlider("ClashBallRange", { Text = "Ball within", Default = S.ClashBallRange, Min = 5, Max = 50, Suffix = " studs", Callback = function(v)
        S.ClashBallRange = v
    end })
    Auto:AddSlider("ClashWindow", {
        Text = "Ball changing hands within",
        Default = S.ClashWindow,
        Min = 150,
        Max = 1500,
        Suffix = " ms",
        Callback = function(v)
            S.ClashWindow = v
        end,
    })
end

do -- Visuals
    local Tab = Window:AddTab("Visuals", "eye", "Ball ESP and ranges")
    local Box = Tab:AddLeftGroupbox("Ball", "circle-dot")
    Box:AddToggle("BallEsp", { Text = "Ball highlight", Default = S.BallEsp, Tooltip = "Red when it's coming for you", Callback = function(v)
        S.BallEsp = v
    end })
    Box:AddToggle("BallInfo", { Text = "Target, speed and distance", Default = S.BallInfo, Callback = function(v)
        S.BallInfo = v
    end })
    Box:AddToggle("Trajectory", { Text = "Where it's heading", Default = S.Trajectory, Callback = function(v)
        S.Trajectory = v
    end })
    Box:AddToggle("ParryRing", { Text = "Parry range ring", Default = S.ParryRing, Callback = function(v)
        S.ParryRing = v
    end })
    Box:AddToggle("TargetEsp", { Text = "Highlight who it's going for", Default = S.TargetEsp, Callback = function(v)
        S.TargetEsp = v
    end })

    local Misc = Tab:AddRightGroupbox("Misc", "settings")
    Misc:AddToggle("AntiAfk", { Text = "Anti AFK", Default = S.AntiAfk, Callback = function(v)
        S.AntiAfk = v
    end })
    Misc:AddButton({
        Text = "Unload",
        DoubleClick = true,
        Func = function()
            if Genv.__BladeBallUnload then
                Genv.__BladeBallUnload()
            end
        end,
    })
end

--// Loops \\--
bind(RunService.PreSimulation, function(dt)
    if not alive() then
        return
    end
    pcall(autoParryStep)
    pcall(spamStep, dt)
end)

bind(RunService.RenderStepped, function()
    if alive() then
        pcall(updateVisuals)
    end
end)

-- Ability "whenever ready", and the dashboard.
task.spawn(function()
    local lastTarget
    while alive() do
        pcall(function()
            if S.AutoAbility and S.AbilityMode == "Whenever ready" and isAlive() and abilityReady() and deflectAbility() then
                useAbility()
            end

            local target = Live.ball and Live.target or "-"
            if target ~= lastTarget and target == LocalPlayer.Name then
                logEvent(string.format("Ball on you · %d speed", math.floor(Live.speed)), Color3.fromRGB(255, 120, 90))
            end
            lastTarget = target

            UI.BallCards:SetValue("Target", target == LocalPlayer.Name and "You" or target)
            UI.BallCards:SetValue("Speed", Live.ball and tostring(math.floor(Live.speed)) or "-")
            UI.BallCards:SetValue("Distance", Live.ball and (math.floor(Live.dist) .. "m") or "-")
            UI.BallCards:SetValue("Hits you in", (Live.ball and target == LocalPlayer.Name and Live.tti < 60)
                and string.format("%.2fs", Live.tti) or "-")
            UI.RangeBar:SetText(Live.curving and "Curving, holding the parry" or "Distance vs parry range")
            UI.RangeBar:SetValue(Live.ball and math.clamp(Live.range / math.max(Live.dist, 0.1), 0, 1) or 0)

            local status = not isAlive() and "Spectating"
                or (Spam.held or Spam.auto) and "Spamming"
                or (Game.infinity and "Infinity up") or (Game.deathSlash and "Death Slash up")
                or (Game.timeHole and "Time Hole") or (Game.fury and "Slashes of Fury")
                or (S.AutoParry and "Auto parry on" or "Idle")
            UI.YouCards:SetValue("Parries", tostring(Game.parries))
            UI.YouCards:SetValue("Successful", tostring(Game.successes))
            UI.YouCards:SetValue("Ping", math.floor(ping() * 1000) .. " ms")
            UI.YouCards:SetValue("Status", status)
        end)
        task.wait(0.15)
    end
end)

task.delay(2, function()
    if not alive() then
        return
    end
    logEvent(ParryButton and "Parry button found: auto input uses it" or "No parry button event: auto input uses the F key")
    if not Workspace:FindFirstChild("Balls") then
        logEvent("No Workspace.Balls yet (in the lobby?)")
    end
end)

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    table.clear(Connections)
    Spam.held = false
    clearVisuals()
    pcall(function()
        VisualGui:Destroy()
    end)
end

Library:OnUnload(cleanup)
Genv.__BladeBallUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

--// Blade Ball ---------------------------------------------------------------------
-- Built against a decompile of the live client plus a logged round of real play.
--
-- What the recon settled, and why the auto parry is shaped the way it is:
--
--   * The ball is a real Part in workspace.Balls: Shape Ball, Size 3, and
--     Transparency 1. What you actually SEE is a second, anchored clone the
--     client makes and tags realBall = false. Read the wrong one and you get a
--     ball that never moves - so every lookup below filters on that attribute.
--
--   * The ball publishes who it is flying at as a plain string attribute:
--         ball:GetAttribute("target") == LocalPlayer.Name
--     No prediction needed to know it is yours. It also carries "from" (who hit
--     it last), "minHeight" and "IsInTimeHoleAOE".
--
--   * AssemblyLinearVelocity is real and clean. Differentiating position instead
--     looks noisy only because position snapshots arrive at about 20Hz over an
--     UnreliableRemoteEvent while we sample at 60 - smoothed over 7 frames the
--     two agree to ~5%. Reported velocity never went stale in 842 samples.
--
--   * Every successful parry in the logged round was pressed between 0.217s and
--     0.514s before impact, at distances from 13 to 88 studs. Time is the
--     invariant, distance is not: at 216 studs/s, 50 studs is 0.23s. A
--     distance-triggered auto parry works early in a round and dies late.
--
--   * The parry cooldown is broadcast to you: VisualCD fires with the duration
--     in seconds. It grew 0.195 -> 0.26 -> 0.325 over one round as the ball sped
--     up, so it is read live rather than hardcoded.
--
-- What is NOT settled: which call actually presses parry. SwordsController.PRY
-- turned out to be Luraph-obfuscated anti-cheat, not parry logic, so the trigger
-- is unresolved. Rather than guess, all three candidates ship here as a
-- selectable method and the script scores them against real ParrySuccess events.
-- Run one round on Auto and it will tell you which one works.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle -------------------------------------------------------------------
local Connections = {}
local Unloading = false
local notify

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Config ----------------------------------------------------------------------
local Config = {
    Enabled = false,

    -- Seconds before impact to press. Every logged success sat between 0.217
    -- and 0.514; the middle of that is the safe default.
    Lead = 0.35,
    -- Half the round trip has to happen before the server sees the press, so
    -- the lead grows with your ping. 1.0 = compensate fully.
    PingFactor = 1.0,
    -- Refuse to fire when the ball is further out than this even if the maths
    -- says otherwise, so a slow ball on a long map does not trigger a press it
    -- will waste the cooldown on.
    MaxDistance = 140,

    Method = "Auto",
    HoldTicks = 1,

    -- Curve and fakeouts mean the ball is not always closing on you in a
    -- straight line. Projecting velocity onto the line to you is the honest
    -- number; raw speed overestimates and fires early.
    UseClosingSpeed = true,

    Logging = false,
}

local Stats = {
    Presses = 0,
    Successes = 0,
    LastEta = 0,
    LastDistance = 0,
    LastSpeed = 0,
    LastTarget = "-",
    Cooldown = 0.195,
    CooldownUntil = 0,
    LastPressAt = 0,
    LastPressMethod = "-",
    Ping = 0,
}

-- Scored per method so "Auto" can settle the open question by experiment
-- instead of me picking one and hoping.
local MethodScores = {
    Remote = { presses = 0, successes = 0 },
    Bindable = { presses = 0, successes = 0 },
    Input = { presses = 0, successes = 0 },
}
local MethodOrder = { "Remote", "Bindable", "Input" }

--// Paths -----------------------------------------------------------------------
local BallsFolder = Workspace:WaitForChild("Balls", 20)
local AliveFolder = Workspace:WaitForChild("Alive", 20)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)

local ParryAttempt = Remotes and Remotes:FindFirstChild("ParryAttempt")
local ParryButtonPress = Remotes and Remotes:FindFirstChild("ParryButtonPress")
local ParrySuccess = Remotes and Remotes:FindFirstChild("ParrySuccess")
local VisualCD = Remotes and Remotes:FindFirstChild("VisualCD")
local KeybindM2 = Remotes and Remotes:FindFirstChild("KeybindM2")

local PingModule = ReplicatedStorage:FindFirstChild("Shared")
PingModule = PingModule and PingModule:FindFirstChild("Ping")

--// Logging ---------------------------------------------------------------------
local LOG_PATH = "BladeBallParry.txt"
local canWrite = typeof(writefile) == "function"
local canAppend = typeof(appendfile) == "function"
local logBuffer = {}

local function appendToFile(text)
    if not canWrite then return end
    if canAppend then
        if pcall(appendfile, LOG_PATH, text) then return end
    end
    local existing = ""
    if typeof(readfile) == "function" and typeof(isfile) == "function" then
        local ok, contents = pcall(function()
            if isfile(LOG_PATH) then return readfile(LOG_PATH) end
            return ""
        end)
        if ok and typeof(contents) == "string" then existing = contents end
    end
    pcall(writefile, LOG_PATH, existing .. text)
end

local function log(text)
    if not Config.Logging then return end
    logBuffer[#logBuffer + 1] = ("[%8.3f] %s"):format(os.clock(), text)
end

task.spawn(function()
    while not Unloading do
        task.wait(0.2)
        if #logBuffer > 0 then
            local chunk = table.concat(logBuffer, "\n") .. "\n"
            table.clear(logBuffer)
            appendToFile(chunk)
        end
    end
end)

--// Character helpers ------------------------------------------------------------
local function getCharacter() return LocalPlayer.Character end

local function getRoot()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- Alive and Dead are separate Workspace folders in this game, so being in the
-- round is a parent check rather than a health check.
local function isPlaying()
    local char = getCharacter()
    if not char then return false end
    if AliveFolder and char.Parent ~= AliveFolder then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

--// Ball ------------------------------------------------------------------------
-- The visible ball is a decoy: the client clones every ball, anchors the clone
-- and tags it realBall = false, leaving the original at Transparency 1. Reading
-- the clone gives a permanently stationary ball, which is the single most
-- common way an auto parry in this game silently does nothing.
local function realBall()
    if not BallsFolder then return nil end
    for _, part in ipairs(BallsFolder:GetChildren()) do
        if part:IsA("BasePart") and part:GetAttribute("realBall") ~= false then
            return part
        end
    end
    return nil
end

local function ballTargetsMe(ball)
    return ball:GetAttribute("target") == LocalPlayer.Name
end

-- Raw speed answers "how fast is it moving", which is not the question. The
-- question is "how fast is the gap closing", and during a curve or a fakeout
-- those differ enough to fire early and waste the cooldown.
local function closingSpeed(ball, root)
    local velocity = ball.AssemblyLinearVelocity
    if not Config.UseClosingSpeed then return velocity.Magnitude end

    local toMe = root.Position - ball.Position
    if toMe.Magnitude < 0.01 then return velocity.Magnitude end
    local closing = velocity:Dot(toMe.Unit)
    if closing <= 0 then return 0 end
    return closing
end

--// Cooldown --------------------------------------------------------------------
-- The server tells us the cooldown every time we press: VisualCD fires with
-- (true, true, duration). It grew from 0.195 to 0.325 across one round as the
-- ball sped up, so it is tracked live rather than assumed.
if VisualCD then
    track(VisualCD.OnClientEvent:Connect(function(a, b, duration)
        if Unloading then return end
        if typeof(duration) == "number" and duration > 0 then
            Stats.Cooldown = duration
            Stats.CooldownUntil = os.clock() + duration
            log(("cooldown %.3fs"):format(duration))
        elseif a == false then
            Stats.CooldownUntil = 0
        end
    end))
end

if ParrySuccess then
    track(ParrySuccess.OnClientEvent:Connect(function()
        if Unloading then return end
        Stats.Successes = Stats.Successes + 1
        local method = Stats.LastPressMethod
        local score = MethodScores[method]
        -- Only credit the method that actually pressed, and only if it pressed
        -- recently enough to plausibly be the cause.
        if score and (os.clock() - Stats.LastPressAt) < 0.75 then
            score.successes = score.successes + 1
        end
        log(("SUCCESS via %s, %.0fms after press"):format(
            tostring(method), (os.clock() - Stats.LastPressAt) * 1000))
    end))
end

--// Pressing --------------------------------------------------------------------
-- Which of these is the real trigger is the one thing the decompile could not
-- answer, because the module that owns it turned out to be obfuscated
-- anti-cheat. So all three ship, and Auto rotates through them and keeps score
-- against real ParrySuccess events until one proves itself.
local parryInputType = Enum.UserInputType.MouseButton1

if KeybindM2 then
    track(KeybindM2.OnClientEvent:Connect(function(useM2)
        parryInputType = useM2 and Enum.UserInputType.MouseButton2
            or Enum.UserInputType.MouseButton1
    end))
end

local function pressRemote()
    if not ParryAttempt then return false end
    return pcall(function() ParryAttempt:FireServer() end)
end

local function pressBindable()
    if not ParryButtonPress then return false end
    return pcall(function() ParryButtonPress:Fire() end)
end

-- Aimed at the centre of the screen rather than at the ball: the handler reads
-- the input type, not where it landed, and clicking wherever the ball happens
-- to be on screen can hit the Roblox menu button on mobile.
local function pressInput()
    if typeof(VirtualInputManager) ~= "Instance" then return false end
    local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local x, y = viewport.X * 0.5, viewport.Y * 0.5
    local button = parryInputType == Enum.UserInputType.MouseButton2 and 1 or 0
    return pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, button, true, game, 1)
        VirtualInputManager:SendMouseButtonEvent(x, y, button, false, game, 1)
    end)
end

local Pressers = {
    Remote = pressRemote,
    Bindable = pressBindable,
    Input = pressInput,
}

local autoIndex = 1

local function chooseMethod()
    if Config.Method ~= "Auto" then return Config.Method end

    -- Stop experimenting once something has actually landed twice. Counting
    -- successes rather than a hit rate matters: a working trigger still misses
    -- when the timing is off, but a trigger that does nothing scores zero
    -- forever, so any confirmed hits at all separate the two.
    local best, bestSuccesses = nil, 0
    for _, name in ipairs(MethodOrder) do
        local score = MethodScores[name]
        if score.successes > bestSuccesses then
            best, bestSuccesses = name, score.successes
        end
    end
    if best and bestSuccesses >= 2 then return best end

    autoIndex = autoIndex % #MethodOrder + 1
    return MethodOrder[autoIndex]
end

local function press()
    local method = chooseMethod()
    local presser = Pressers[method]
    if not presser then return end

    local ok = presser()
    Stats.Presses = Stats.Presses + 1
    Stats.LastPressAt = os.clock()
    Stats.LastPressMethod = method

    local score = MethodScores[method]
    if score then score.presses = score.presses + 1 end

    -- Assume the cooldown even if the server never confirms, so a method that
    -- does nothing at all cannot turn into a press every frame.
    if Stats.CooldownUntil < os.clock() then
        Stats.CooldownUntil = os.clock() + Stats.Cooldown
    end

    log(("press via %s ok=%s eta=%.3f dist=%.1f speed=%.1f"):format(
        method, tostring(ok), Stats.LastEta, Stats.LastDistance, Stats.LastSpeed))
end

--// The loop --------------------------------------------------------------------
track(PostSimulation:Connect(function()
    if Unloading then return end

    if PingModule then
        Stats.Ping = PingModule:GetAttribute("LocalPlayerPing") or 0
    end

    local ball = realBall()
    local root = getRoot()

    if not ball or not root then
        Stats.LastTarget = "-"
        Stats.LastEta = 0
        Stats.LastDistance = 0
        Stats.LastSpeed = 0
        return
    end

    Stats.LastTarget = tostring(ball:GetAttribute("target"))

    local distance = (ball.Position - root.Position).Magnitude
    local speed = closingSpeed(ball, root)
    Stats.LastDistance = distance
    Stats.LastSpeed = speed

    local eta = math.huge
    if speed > 1 then eta = distance / speed end
    Stats.LastEta = eta

    if not Config.Enabled then return end
    if not isPlaying() then return end
    if not ballTargetsMe(ball) then return end
    if os.clock() < Stats.CooldownUntil then return end
    if distance > Config.MaxDistance then return end

    -- Half the round trip has to elapse before the server sees this, so a laggy
    -- connection needs to press proportionally earlier.
    local lead = Config.Lead + (Stats.Ping * 0.5 * Config.PingFactor)
    if eta <= lead then
        press()
    end
end))

--// UI --------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet(
    'https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'blade ball',
    SubTitle = 'auto parry',
    Folder = 'BladeBall',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(120, 90, 255),
})

function notify(content, kind, duration)
    Centrl:Notify({
        Title = 'blade ball',
        Content = content,
        Type = kind or 'success',
        Duration = duration or 5,
    })
end

if not BallsFolder then
    notify('workspace.Balls not found - the game may have changed.', 'error', 8)
end

local MainTab = Window:Tab({ Title = 'parry', Icon = 'crosshair' })
local ParrySection = MainTab:Section({ Title = 'auto parry', Side = 'left' })

ParrySection:Toggle({
    Title = 'auto parry',
    Flag = 'bb_enabled',
    Default = false,
    Callback = function(v) Config.Enabled = v end,
})

ParrySection:Slider({
    Title = 'press this far ahead',
    Flag = 'bb_lead',
    Min = 0.1,
    Max = 0.8,
    Increment = 0.01,
    Default = 0.35,
    Suffix = 's',
    Callback = function(v) Config.Lead = v end,
})

ParrySection:Slider({
    Title = 'ping compensation',
    Flag = 'bb_ping_factor',
    Min = 0,
    Max = 2,
    Increment = 0.1,
    Default = 1,
    Suffix = 'x',
    Callback = function(v) Config.PingFactor = v end,
})

ParrySection:Slider({
    Title = 'ignore beyond',
    Flag = 'bb_max_distance',
    Min = 40,
    Max = 400,
    Increment = 10,
    Default = 140,
    Suffix = ' studs',
    Callback = function(v) Config.MaxDistance = v end,
})

ParrySection:Toggle({
    Title = 'use closing speed',
    Flag = 'bb_closing',
    Default = true,
    Callback = function(v) Config.UseClosingSpeed = v end,
})

ParrySection:Paragraph({
    Title = 'why time and not distance',
    Text = 'Every successful parry in the logged round was pressed between 0.217 and 0.514 seconds before impact, at distances anywhere from 13 to 88 studs. Time to impact is the thing that stays constant; distance is not. At 216 studs a second - which the ball reached inside 90 seconds - fifty studs is only 0.23s away, so a distance-triggered parry that feels right early in a round fires far too late by the end of one.',
})

local MethodSection = MainTab:Section({ Title = 'trigger method', Side = 'right' })

MethodSection:Dropdown({
    Title = 'method',
    Flag = 'bb_method',
    Options = { 'Auto', 'Remote', 'Bindable', 'Input' },
    Default = 'Auto',
    Callback = function(v) Config.Method = v end,
})

local remoteStat = MethodSection:Stat({
    Title = 'ParryAttempt',
    Value = ParryAttempt and 'found' or 'missing',
})
local bindableStat = MethodSection:Stat({
    Title = 'ParryButtonPress',
    Value = ParryButtonPress and 'found' or 'missing',
})
local scoreRemote = MethodSection:Stat({ Title = 'Remote', Value = '0/0' })
local scoreBindable = MethodSection:Stat({ Title = 'Bindable', Value = '0/0' })
local scoreInput = MethodSection:Stat({ Title = 'Input', Value = '0/0' })

MethodSection:Paragraph({
    Title = 'why there is a choice at all',
    Text = 'The module that owns the parry, SwordsController.PRY, turned out to be Luraph-obfuscated anti-cheat rather than parry logic - it sets BAC_HASH and two decoy globals and checks whether debug.info has been hooked. So the exact call has not been read. Auto rotates through the three candidates and keeps score against real ParrySuccess events; after three presses each it locks onto whichever is actually landing. The scores above are hits over attempts.',
})

local BallSection = MainTab:Section({ Title = 'ball', Side = 'left' })

local targetStat = BallSection:Stat({ Title = 'target', Value = '-' })
local distStat = BallSection:Stat({ Title = 'distance', Value = '-' })
local speedStat = BallSection:Stat({ Title = 'closing speed', Value = '-' })
local etaStat = BallSection:Stat({ Title = 'time to impact', Value = '-' })
local cdStat = BallSection:Stat({ Title = 'cooldown', Value = '-' })
local pingStat = BallSection:Stat({ Title = 'ping', Value = '-' })
local hitStat = BallSection:Stat({ Title = 'parried', Value = '0 / 0' })

task.spawn(function()
    while not Unloading do
        task.wait(0.1)

        local mine = Stats.LastTarget == LocalPlayer.Name
        pcall(function()
            targetStat:Set(Stats.LastTarget .. (mine and '  (YOU)' or ''),
                mine and Color3.fromRGB(255, 90, 90) or nil)
        end)
        pcall(function() distStat:Set(('%.1f studs'):format(Stats.LastDistance)) end)
        pcall(function() speedStat:Set(('%.1f studs/s'):format(Stats.LastSpeed)) end)
        pcall(function()
            if Stats.LastEta == math.huge then
                etaStat:Set('-')
            else
                etaStat:Set(('%.3fs'):format(Stats.LastEta))
            end
        end)

        local remaining = Stats.CooldownUntil - os.clock()
        pcall(function()
            if remaining > 0 then
                cdStat:Set(('%.2fs left (%.3fs)'):format(remaining, Stats.Cooldown))
            else
                cdStat:Set(('ready (%.3fs)'):format(Stats.Cooldown))
            end
        end)

        pcall(function() pingStat:Set(('%.0f ms'):format(Stats.Ping * 1000)) end)
        pcall(function()
            hitStat:Set(('%d / %d'):format(Stats.Successes, Stats.Presses))
        end)

        pcall(function()
            scoreRemote:Set(('%d / %d'):format(
                MethodScores.Remote.successes, MethodScores.Remote.presses))
        end)
        pcall(function()
            scoreBindable:Set(('%d / %d'):format(
                MethodScores.Bindable.successes, MethodScores.Bindable.presses))
        end)
        pcall(function()
            scoreInput:Set(('%d / %d'):format(
                MethodScores.Input.successes, MethodScores.Input.presses))
        end)
    end
end)

--// Settings ---------------------------------------------------------------------
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'left' })

DiagSection:Toggle({
    Title = 'log every press to file',
    Flag = 'bb_logging',
    Default = false,
    Callback = function(v)
        Config.Logging = v
        if v and not canWrite then
            notify('This executor has no writefile - nothing will be logged.', 'error', 7)
        elseif v then
            notify('Logging to ' .. LOG_PATH, 'success')
        end
    end,
})

DiagSection:Button({
    Title = 'reset method scores',
    Callback = function()
        for _, name in ipairs(MethodOrder) do
            MethodScores[name].presses = 0
            MethodScores[name].successes = 0
        end
        Stats.Presses = 0
        Stats.Successes = 0
        notify('Scores cleared.')
    end,
})

DiagSection:Paragraph({
    Title = 'the decoy ball',
    Text = 'workspace.Balls holds two parts. The real one is Transparency 1 with the physics on it; the client clones it, anchors the clone and tags it realBall = false, and that clone is the one you can see. Everything here filters on that attribute, because reading the clone gives a ball that never moves and an auto parry that silently never fires.',
})

DiagSection:Paragraph({
    Title = 'anti-cheat',
    Text = 'This game ships an obfuscated client-side anti-cheat that checks whether debug.info has been hooked. Nothing here hooks a metamethod or touches its decoy globals - the ball is read through ordinary attributes and properties. The Input trigger method synthesises a real click, which is the least distinguishable of the three; Remote fires the same RemoteEvent the game does. Neither is a guarantee of anything.',
})

local ControlSection = SettingsTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        Config.Enabled = false
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        Centrl:Unload()
    end,
})

Window:Load()

notify('Loaded. RightShift toggles the menu.', 'success', 5)

--// Blade Ball ---------------------------------------------------------------------
-- Built from a decompile of the live client plus a logged round of real play.
--
-- READ THIS FIRST. An earlier build of this script got its author kicked:
--     BAC | Kicked for exploiting! [BAC 45X24fgg88]
-- That build had an "Auto" mode which rotated through three different ways of
-- triggering a parry to find out which one worked. Rotating meant it fired all
-- three within a few seconds, so it hit every detection this game has at once
-- and there was no way to tell which one answered. Auto is gone. Nothing here
-- fires anything unless you pick that method by name.
--
-- The default mode now writes NOTHING. It reads the ball and shows you when to
-- press. That is not a compromise for its own sake - reading attributes and
-- positions is genuinely invisible, and every part of this script that got
-- somebody kicked was on the writing side.
--
-- What the recon settled, and why the timing is shaped the way it is:
--
--   * The ball is a real Part in workspace.Balls: Shape Ball, Size 3, and
--     Transparency 1. What you SEE is a second, anchored clone the client makes
--     and tags realBall = false. Read the wrong one and you get a ball that
--     never moves, so every lookup here filters on that attribute.
--
--   * The ball says who it is flying at:  ball:GetAttribute("target")
--     No prediction needed. It also carries "from", "minHeight",
--     "IsInTimeHoleAOE" and "lastUpdateRecieveTick".
--
--   * AssemblyLinearVelocity is clean and never went stale across 842 logged
--     samples. Differentiating position looks noisy only because snapshots
--     arrive at ~20Hz over an UnreliableRemoteEvent while sampling runs at 60;
--     smoothed over 7 frames the two agree to about 5%.
--
--   * Every successful parry in the logged round was pressed between 0.217s and
--     0.514s before impact, at distances from 13 to 88 studs. Time is the
--     invariant, distance is not: at the 216 studs/s the ball reached inside 90
--     seconds, fifty studs is 0.23s away.
--
--   * The parry cooldown is broadcast to you on VisualCD, and it grew from
--     0.195 to 0.325 across one round, so it is read live.
--
-- What is still unknown is the exact call the game makes to parry. The module
-- that owns it, SwordsController.PRY, is Luraph-obfuscated anti-cheat rather
-- than parry logic - it sets BAC_HASH plus two decoy globals and checks whether
-- debug.info has been hooked. The three candidates are still here, one at a
-- time, capped, and logged, so a test costs one kick and names its cause.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

    -- Indicator writes nothing at all. The other three each fire one specific
    -- thing and are chosen by name - there is no mode that tries several.
    Mode = "Indicator",

    -- Seconds before impact. Every logged success sat between 0.217 and 0.514.
    Lead = 0.35,
    PingFactor = 1.0,
    MaxDistance = 140,
    UseClosingSpeed = true,

    -- A press mode disables itself after this many presses. If a method is
    -- detected, that costs one kick rather than a session of them, and the log
    -- says which method was live when it happened.
    PressBudget = 5,

    Sound = true,
    Logging = true,
}

local Stats = {
    Presses = 0,
    Successes = 0,
    Budget = 0,
    LastEta = 0,
    LastDistance = 0,
    LastSpeed = 0,
    LastTarget = "-",
    Cooldown = 0.195,
    CooldownUntil = 0,
    LastPressAt = 0,
    Ping = 0,
    Cues = 0,
}

local MethodScores = {
    Remote = { presses = 0, successes = 0 },
    Bindable = { presses = 0, successes = 0 },
    Input = { presses = 0, successes = 0 },
}

--// Paths -----------------------------------------------------------------------
local BallsFolder = Workspace:WaitForChild("Balls", 20)
local AliveFolder = Workspace:WaitForChild("Alive", 20)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)

local ParryAttempt = Remotes and Remotes:FindFirstChild("ParryAttempt")
local ParryButtonPress = Remotes and Remotes:FindFirstChild("ParryButtonPress")
local ParrySuccessRemote = Remotes and Remotes:FindFirstChild("ParrySuccess")
local VisualCD = Remotes and Remotes:FindFirstChild("VisualCD")
local KeybindM2 = Remotes and Remotes:FindFirstChild("KeybindM2")

local PingModule = ReplicatedStorage:FindFirstChild("Shared")
PingModule = PingModule and PingModule:FindFirstChild("Ping")

--// Logging ---------------------------------------------------------------------
-- Presses are flushed the instant they happen rather than batched, because the
-- whole point of the log is to survive a kick and name what was live.
local LOG_PATH = "BladeBallParry.txt"
local canWrite = typeof(writefile) == "function"
local canAppend = typeof(appendfile) == "function"

local function appendToFile(text)
    if not canWrite then return end
    if canAppend and pcall(appendfile, LOG_PATH, text) then return end
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
    appendToFile(("[%s] %s\n"):format(os.date("%H:%M:%S"), text))
end

--// Character helpers ------------------------------------------------------------
local function getRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- Alive and Dead are separate Workspace folders here, so being in the round is
-- a parent check rather than a health check.
local function isPlaying()
    local char = LocalPlayer.Character
    if not char then return false end
    if AliveFolder and char.Parent ~= AliveFolder then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

--// Ball ------------------------------------------------------------------------
local function realBall()
    if not BallsFolder then return nil end
    for _, part in ipairs(BallsFolder:GetChildren()) do
        if part:IsA("BasePart") and part:GetAttribute("realBall") ~= false then
            return part
        end
    end
    return nil
end

-- Raw speed answers "how fast is it moving", which is not the question. The
-- question is how fast the gap is closing, and on a curve or a fakeout those
-- differ enough to fire early.
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
if VisualCD then
    track(VisualCD.OnClientEvent:Connect(function(a, _, duration)
        if Unloading then return end
        if typeof(duration) == "number" and duration > 0 then
            Stats.Cooldown = duration
            Stats.CooldownUntil = os.clock() + duration
        elseif a == false then
            Stats.CooldownUntil = 0
        end
    end))
end

if ParrySuccessRemote then
    track(ParrySuccessRemote.OnClientEvent:Connect(function()
        if Unloading then return end
        Stats.Successes = Stats.Successes + 1
        local score = MethodScores[Config.Mode]
        if score and (os.clock() - Stats.LastPressAt) < 0.75 then
            score.successes = score.successes + 1
            log(("SUCCESS via %s, %.0fms after press")
                :format(Config.Mode, (os.clock() - Stats.LastPressAt) * 1000))
        end
    end))
end

--// Indicator -------------------------------------------------------------------
-- The safe mode. It reads the same numbers the press modes use and paints them,
-- and that is all it does - no remote, no bindable, no synthesised input.
local IndicatorGui = Instance.new("ScreenGui")
IndicatorGui.Name = "BBParryCue"
IndicatorGui.ResetOnSpawn = false
IndicatorGui.IgnoreGuiInset = true
IndicatorGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
IndicatorGui.DisplayOrder = 9

local cueRing = Instance.new("Frame")
cueRing.Name = "ring"
cueRing.AnchorPoint = Vector2.new(0.5, 0.5)
cueRing.Position = UDim2.fromScale(0.5, 0.5)
cueRing.Size = UDim2.fromOffset(120, 120)
cueRing.BackgroundTransparency = 1
cueRing.Visible = false
cueRing.Parent = IndicatorGui

local ringCorner = Instance.new("UICorner")
ringCorner.CornerRadius = UDim.new(1, 0)
ringCorner.Parent = cueRing

local ringStroke = Instance.new("UIStroke")
ringStroke.Thickness = 4
ringStroke.Color = Color3.fromRGB(255, 210, 80)
ringStroke.Parent = cueRing

local cueLabel = Instance.new("TextLabel")
cueLabel.Name = "label"
cueLabel.AnchorPoint = Vector2.new(0.5, 0)
cueLabel.Position = UDim2.new(0.5, 0, 0.5, 74)
cueLabel.Size = UDim2.fromOffset(300, 26)
cueLabel.BackgroundTransparency = 1
cueLabel.Font = Enum.Font.GothamBold
cueLabel.TextSize = 20
cueLabel.TextStrokeTransparency = 0.3
cueLabel.TextColor3 = Color3.fromRGB(255, 210, 80)
cueLabel.Text = ""
cueLabel.Visible = false
cueLabel.Parent = IndicatorGui

local function parentGui()
    local ok = pcall(function()
        if typeof(gethui) == "function" then
            IndicatorGui.Parent = gethui()
        else
            IndicatorGui.Parent = LocalPlayer:WaitForChild("PlayerGui", 10)
        end
    end)
    if not ok then
        pcall(function() IndicatorGui.Parent = game:GetService("CoreGui") end)
    end
end
parentGui()

local cueSound = Instance.new("Sound")
cueSound.Name = "BBParryCue"
cueSound.SoundId = "rbxassetid://12221967"
cueSound.Volume = 0.5
cueSound.Parent = IndicatorGui

local cueUntil = 0

local function fireCue()
    Stats.Cues = Stats.Cues + 1
    cueUntil = os.clock() + 0.25
    if Config.Sound then
        pcall(function() cueSound:Play() end)
    end
end

--// Pressing --------------------------------------------------------------------
-- One method, chosen by name, never rotated. Each one fires exactly one thing.
local parryInputType = Enum.UserInputType.MouseButton1

if KeybindM2 then
    track(KeybindM2.OnClientEvent:Connect(function(useM2)
        parryInputType = useM2 and Enum.UserInputType.MouseButton2
            or Enum.UserInputType.MouseButton1
    end))
end

-- A phone reports TouchEnabled true and MouseEnabled false. Sending a mouse
-- click on one is the single most obvious thing this script was doing wrong.
local function isTouchDevice()
    local ok, touch = pcall(function()
        return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
    end)
    return ok and touch == true
end

local Pressers = {
    -- Fires the same RemoteEvent the game fires. The arguments the real client
    -- sends were never read, because the module that sends them is obfuscated,
    -- so this sends none - which is exactly the kind of thing a server can spot.
    -- Treat it as the most likely of the three to be the one that answered.
    Remote = function()
        if not ParryAttempt then return false, "ParryAttempt missing" end
        return pcall(function() ParryAttempt:FireServer() end)
    end,

    -- A client-internal BindableEvent. Firing it should run the game's own parry
    -- path, cooldown and all, but anything listening can tell it came from
    -- nowhere.
    Bindable = function()
        if not ParryButtonPress then return false, "ParryButtonPress missing" end
        return pcall(function() ParryButtonPress:Fire() end)
    end,

    -- Synthesised input at the centre of the screen, not at the ball: the
    -- handler reads the input type, not where it landed, and tapping wherever
    -- the ball happens to be can hit the Roblox menu button on a phone.
    --
    -- The DEVICE decides which kind of input. The build that got somebody
    -- kicked always sent a mouse click, and it was sent from a phone. A
    -- MouseButton1 event on a device with no mouse is not a subtle tell -
    -- UserInputService reports TouchEnabled true and MouseEnabled false, and
    -- anything watching can read those two properties as easily as we can. On
    -- touch this now sends a touch, which is the input the game expects there.
    --
    -- That removes an obvious tell. It does not make VirtualInputManager itself
    -- invisible: it is a known exploit tool and a client-side anti-cheat can
    -- look for it directly.
    Input = function()
        local vim = game:GetService("VirtualInputManager")
        if typeof(vim) ~= "Instance" then return false, "no VirtualInputManager" end

        local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
        local x, y = viewport.X * 0.5, viewport.Y * 0.5

        if isTouchDevice() then
            -- SendTouchEvent(touchId, state, x, y). State 0 begins the touch,
            -- 2 ends it, which is a tap.
            return pcall(function()
                vim:SendTouchEvent(1, 0, x, y)
                vim:SendTouchEvent(1, 2, x, y)
            end)
        end

        local button = parryInputType == Enum.UserInputType.MouseButton2 and 1 or 0
        return pcall(function()
            vim:SendMouseButtonEvent(x, y, button, true, game, 1)
            vim:SendMouseButtonEvent(x, y, button, false, game, 1)
        end)
    end,
}

local budgetLabel

local function press()
    local presser = Pressers[Config.Mode]
    if not presser then return end

    if Stats.Budget <= 0 then
        Config.Enabled = false
        log(("BUDGET SPENT on %s - auto parry disabled"):format(Config.Mode))
        notify('Press budget spent. Auto parry turned itself off.', 'warning', 8)
        return
    end

    Stats.Budget = Stats.Budget - 1
    Stats.Presses = Stats.Presses + 1
    Stats.LastPressAt = os.clock()

    local score = MethodScores[Config.Mode]
    if score then score.presses = score.presses + 1 end

    -- Logged and flushed BEFORE the call, so if this is the one that gets you
    -- kicked the file already names it.
    log(("press %d/%d via %s | eta=%.3f dist=%.1f speed=%.1f ping=%.0fms")
        :format(Stats.Presses, Config.PressBudget, Config.Mode,
            Stats.LastEta, Stats.LastDistance, Stats.LastSpeed, Stats.Ping * 1000))

    local ok, err = presser()
    if not ok then
        log(("  press failed: %s"):format(tostring(err)))
    end

    if Stats.CooldownUntil < os.clock() then
        Stats.CooldownUntil = os.clock() + Stats.Cooldown
    end
end

--// The loop --------------------------------------------------------------------
track(PostSimulation:Connect(function()
    if Unloading then return end

    if PingModule then
        Stats.Ping = PingModule:GetAttribute("LocalPlayerPing") or 0
    end

    local showCue = os.clock() < cueUntil
    cueRing.Visible = showCue
    cueLabel.Visible = showCue

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
    if ball:GetAttribute("target") ~= LocalPlayer.Name then return end
    if os.clock() < Stats.CooldownUntil then return end
    if distance > Config.MaxDistance then return end

    -- Half the round trip has to elapse before the server sees a press, so a
    -- laggy connection needs to act proportionally earlier. The cue leads by the
    -- same amount, because a human also has to react.
    local lead = Config.Lead + (Stats.Ping * 0.5 * Config.PingFactor)
    if eta > lead then return end

    if Config.Mode == "Indicator" then
        fireCue()
        cueLabel.Text = ("PARRY   %.2fs"):format(eta)
        Stats.CooldownUntil = os.clock() + Stats.Cooldown
    else
        press()
    end
end))

--// UI --------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet(
    'https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'blade ball',
    SubTitle = 'parry',
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
local ModeSection = MainTab:Section({ Title = 'mode', Side = 'left' })

ModeSection:Dropdown({
    Title = 'mode',
    Flag = 'bb_mode',
    Options = { 'Indicator', 'Remote', 'Bindable', 'Input' },
    Default = 'Indicator',
    Callback = function(value)
        Config.Mode = value
        Stats.Budget = Config.PressBudget
        if value == 'Indicator' then
            notify('Indicator only. Nothing is sent to the server.', 'success', 5)
        else
            notify(('%s mode: %d presses then it turns itself off. This is the part that gets people kicked.')
                :format(value, Config.PressBudget), 'warning', 10)
        end
        log(("mode set to %s"):format(value))
    end,
})

ModeSection:Toggle({
    Title = 'enabled',
    Flag = 'bb_enabled',
    Default = false,
    Callback = function(value)
        Config.Enabled = value
        if value then Stats.Budget = Config.PressBudget end
        log(value and ("ENABLED in %s mode"):format(Config.Mode) or "disabled")
    end,
})

ModeSection:Slider({
    Title = 'press budget',
    Flag = 'bb_budget',
    Min = 1,
    Max = 50,
    Increment = 1,
    Default = 5,
    Callback = function(value)
        Config.PressBudget = value
        Stats.Budget = value
    end,
})

ModeSection:Toggle({
    Title = 'cue sound',
    Flag = 'bb_sound',
    Default = true,
    Callback = function(value) Config.Sound = value end,
})

ModeSection:Paragraph({
    Title = 'what got somebody kicked',
    Text = 'BAC | Kicked for exploiting! [BAC 45X24fgg88], the moment auto parry was switched on. The build that did it had an Auto mode that rotated through all three trigger methods to find out which one worked, so it fired every one of them within seconds - it hit whatever detection this game has and left no way to tell which. Auto is gone. A mode fires one specific thing, only when you name it, and stops after its budget.',
})

local TimingSection = MainTab:Section({ Title = 'timing', Side = 'right' })

TimingSection:Slider({
    Title = 'lead',
    Flag = 'bb_lead',
    Min = 0.1,
    Max = 0.8,
    Increment = 0.01,
    Default = 0.35,
    Suffix = 's',
    Callback = function(value) Config.Lead = value end,
})

TimingSection:Slider({
    Title = 'ping compensation',
    Flag = 'bb_ping_factor',
    Min = 0,
    Max = 2,
    Increment = 0.1,
    Default = 1,
    Suffix = 'x',
    Callback = function(value) Config.PingFactor = value end,
})

TimingSection:Slider({
    Title = 'ignore beyond',
    Flag = 'bb_max_distance',
    Min = 40,
    Max = 400,
    Increment = 10,
    Default = 140,
    Suffix = ' studs',
    Callback = function(value) Config.MaxDistance = value end,
})

TimingSection:Toggle({
    Title = 'use closing speed',
    Flag = 'bb_closing',
    Default = true,
    Callback = function(value) Config.UseClosingSpeed = value end,
})

TimingSection:Paragraph({
    Title = 'why time and not distance',
    Text = 'Every successful parry in the logged round was pressed between 0.217 and 0.514 seconds before impact, at distances anywhere from 13 to 88 studs. Time to impact stays constant, distance does not. At the 216 studs a second the ball reached inside 90 seconds, fifty studs is only 0.23s away - so a distance trigger that feels right early in a round fires far too late by the end of one.',
})

local BallSection = MainTab:Section({ Title = 'ball', Side = 'left' })

local targetStat = BallSection:Stat({ Title = 'target', Value = '-' })
local distStat = BallSection:Stat({ Title = 'distance', Value = '-' })
local speedStat = BallSection:Stat({ Title = 'closing speed', Value = '-' })
local etaStat = BallSection:Stat({ Title = 'time to impact', Value = '-' })
local cdStat = BallSection:Stat({ Title = 'cooldown', Value = '-' })
local pingStat = BallSection:Stat({ Title = 'ping', Value = '-' })
local cueStat = BallSection:Stat({ Title = 'cues shown', Value = '0' })
budgetLabel = BallSection:Stat({ Title = 'presses left', Value = '-' })
local hitStat = BallSection:Stat({ Title = 'parried', Value = '0 / 0' })
local verdictStat = BallSection:Stat({ Title = 'verdict', Value = '-' })

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
        pcall(function() cueStat:Set(tostring(Stats.Cues)) end)
        pcall(function()
            if Config.Mode == 'Indicator' then
                budgetLabel:Set('n/a - nothing is sent')
            else
                budgetLabel:Set(('%d of %d'):format(Stats.Budget, Config.PressBudget))
            end
        end)
        pcall(function()
            hitStat:Set(('%d / %d'):format(Stats.Successes, Stats.Presses))
        end)

        -- "It did not get me kicked" and "it did not do anything" look the
        -- same from the outside. ParrySuccess is the only thing that tells
        -- them apart, so it gets said out loud rather than left to inference.
        pcall(function()
            local score = MethodScores[Config.Mode]
            if Config.Mode == 'Indicator' then
                verdictStat:Set('reading only', Color3.fromRGB(126, 217, 87))
            elseif not score or score.presses == 0 then
                verdictStat:Set('untested')
            elseif score.successes > 0 then
                verdictStat:Set(('WORKS - %d confirmed'):format(score.successes),
                    Color3.fromRGB(126, 217, 87))
            else
                verdictStat:Set(('no effect in %d presses'):format(score.presses),
                    Color3.fromRGB(255, 180, 70))
            end
        end)
    end
end)

--// Settings ---------------------------------------------------------------------
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local RiskSection = SettingsTab:Section({ Title = 'what is safe and what is not', Side = 'left' })

RiskSection:Paragraph({
    Title = 'Indicator',
    Text = 'Reads ball attributes and positions and paints a ring on your screen. No remote, no bindable, no synthesised input, no metamethod hooks, and it never touches the anti-cheat decoy globals. There is nothing here for a server to see - it is the same information the game already sends you, drawn differently.',
})

RiskSection:Paragraph({
    Title = 'Remote - most likely to be the one that answered',
    Text = 'Fires ReplicatedStorage.Remotes.ParryAttempt. The arguments the real client sends were never read, because SwordsController.PRY is obfuscated, so this sends none at all. A server receiving that remote with no arguments, from a client whose parry did not come from input, is about as clear a signature as exploiting produces. If you only test one thing, do not make it this one.',
})

RiskSection:Paragraph({
    Title = 'Bindable',
    Text = 'Fires the ParryButtonPress BindableEvent, which should run the game\'s own parry path including its cooldown. That is the appeal. The risk is that BAC runs on this client too and can compare a parry against whether any real input happened.',
})

RiskSection:Paragraph({
    Title = 'Input - this is the one that got somebody kicked',
    Text = 'It sent a MouseButton1 click, from a phone. UserInputService on that device reports TouchEnabled true and MouseEnabled false, so a mouse click there is a tell anything can read in two lines. It now sends a touch on touch devices and a click on desktop. That removes an obvious mistake rather than making the method safe: VirtualInputManager is a known exploit tool in its own right and a client-side anti-cheat can look for it directly. It is still the method whose parry looks most genuine, because the game\'s own code runs end to end.',
})

RiskSection:Paragraph({
    Title = 'why nothing here can make a call look legitimate',
    Text = 'Firing ParryAttempt with the right arguments would need the arguments, and the only code that knows them is SwordsController.PRY, which is a Luraph VM. Reading them off the wire while you parry by hand means hooking a metamethod - and that module already checks whether debug.info has been hooked, so the capture is more detectable than the thing it is trying to make safe. If your executor has a built-in remote spy, that runs below the game and is the one route that does not put a hook in this script.',
})

RiskSection:Paragraph({
    Title = 'can the anti-cheat just be turned off',
    Text = 'It runs on your client, so in principle yes. In practice it is a Luraph VM that is already required and running before this script loads, and it sets BAC_HASH plus two decoy globals specifically so tampering shows. The bigger problem is that this game routes 1232 of its remotes through hashed names - the anti-cheat almost certainly reports over one of them and cannot be picked out by name. Silencing a client that the server expects to hear from usually ends the same way as being caught by it, except the kick becomes something that does not expire.',
})

local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'right' })

DiagSection:Toggle({
    Title = 'log to file',
    Flag = 'bb_logging',
    Default = true,
    Callback = function(value)
        Config.Logging = value
        if value and not canWrite then
            notify('This executor has no writefile - nothing will be logged.', 'error', 7)
        end
    end,
})

DiagSection:Paragraph({
    Title = 'how to find the culprit',
    Text = 'Presses are written to BladeBallParry.txt and flushed before the call goes out, so the file survives a kick and the last line names the mode that was live. Test one mode at a time with a small budget. A mode that gets you kicked will have exactly one press logged after the last mode change; a mode that works will start logging SUCCESS lines instead.',
})

DiagSection:Button({
    Title = 'reset counters',
    Callback = function()
        for _, score in pairs(MethodScores) do
            score.presses = 0
            score.successes = 0
        end
        Stats.Presses = 0
        Stats.Successes = 0
        Stats.Cues = 0
        Stats.Budget = Config.PressBudget
        notify('Counters cleared.')
    end,
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
        pcall(function() IndicatorGui:Destroy() end)
        Centrl:Unload()
    end,
})

Window:Load()

Stats.Budget = Config.PressBudget
log("loaded")
notify('Loaded in Indicator mode - it only shows you when to press.', 'success', 7)

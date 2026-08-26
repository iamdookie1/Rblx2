local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreSimulation = resolveEvent("PreSimulation", "Stepped")

local Connections = {}
local Unloading = false

local notify
local statusStat
local lockedStat
local EnabledToggle

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local Config = {
    Enabled = false,
    Lead = 0.38,
    SpeedLead = 0.12,
    PingFactor = 1.0,
    MaxDistance = 160,
    Cooldown = 0.2,
}

local Fires = 0
local CooldownUntil = 0

local LockedRemote = nil
local LockedClass = nil
local LockedFullName = nil

local learning = false
local lastPressAt = 0
local learnQueue = {}
local LEARN_QUEUE_LIMIT = 200

local hookInstalled = false
local originalNamecall = nil

local function findChildCI(parent, name)
    if not parent then return nil end
    local lowered = name:lower()
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name:lower() == lowered then
            return child
        end
    end
    return nil
end

local BallsFolder = Workspace:WaitForChild("Balls", 6)
local TrainingBallsFolder = findChildCI(Workspace, "TrainingBalls")
local AliveFolder = Workspace:WaitForChild("Alive", 20)

local PingModule = ReplicatedStorage:FindFirstChild("Shared")
PingModule = PingModule and PingModule:FindFirstChild("Ping")

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
    appendToFile(("[%s] %s\n"):format(os.date("%H:%M:%S"), text))
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isAlive()
    local char = LocalPlayer.Character
    if not char then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

local function isPlaying()
    local char = LocalPlayer.Character
    if not char then return false end
    if AliveFolder and char.Parent ~= AliveFolder then return false end
    return isAlive()
end

local function realBall()
    if BallsFolder then
        for _, part in ipairs(BallsFolder:GetChildren()) do
            if part:IsA("BasePart") and part:GetAttribute("realBall") ~= false then
                return part, false
            end
        end
    end
    if TrainingBallsFolder then
        for _, part in ipairs(TrainingBallsFolder:GetChildren()) do
            if part:IsA("BasePart") then
                return part, true
            end
        end
    end
    return nil, false
end

local HAS_NAMECALL = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

local IGNORE_NAMES = {
    SetPointer = true,
    SetLook = true,
    Ping = true,
    Fps = true,
    MenuState = true,
    OnDeath = true,
}

local IGNORE_TAGS = {
    Activity = true,
    Snapshot = true,
    UIInteraction = true,
    AFKStart = true,
    AFKEnd = true,
    FirstMove = true,
    ["5455ef47-de02-4074-808c-8d82c2cd12ec"] = true,
}

local function installHook()
    if hookInstalled or not HAS_NAMECALL then return hookInstalled end

    local ok = pcall(function()
        local hook = function(self, ...)
            if learning and not Unloading and #learnQueue < LEARN_QUEUE_LIMIT and typeof(self) == "Instance" then
                local okMethod, method = pcall(getnamecallmethod)
                if okMethod and (method == "FireServer" or method == "InvokeServer") then
                    local okName, name = pcall(function() return self.Name end)
                    local firstArg = select(1, ...)
                    if not ((okName and IGNORE_NAMES[name]) or IGNORE_TAGS[firstArg]) then
                        learnQueue[#learnQueue + 1] = { instance = self, at = os.clock() }
                    end
                end
            end
            return originalNamecall(self, ...)
        end

        if typeof(newcclosure) == "function" then
            local wrapped = newcclosure(hook)
            originalNamecall = hookmetamethod(game, "__namecall", wrapped)
        else
            originalNamecall = hookmetamethod(game, "__namecall", hook)
        end
    end)

    if not ok or not originalNamecall then
        originalNamecall = nil
        return false
    end

    hookInstalled = true
    log("namecall hook installed (permanent, gated)")
    return true
end

local function stopLearning()
    learning = false
    table.clear(learnQueue)
end

local function lockRemote(instance)
    local okClass, className = pcall(function() return instance.ClassName end)
    if not okClass then return false end

    local okFullName, fullName = pcall(function() return instance:GetFullName() end)
    if not okFullName then return false end

    LockedRemote = instance
    LockedClass = className
    LockedFullName = fullName
    CooldownUntil = os.clock() + 2

    stopLearning()

    log("locked remote: " .. fullName .. " (" .. className .. ")")
    notify('Learned: ' .. fullName, 'success', 10)
    return true
end

local function startLearning()
    if learning or LockedRemote then return end

    if not HAS_NAMECALL then
        notify('This executor has no hookmetamethod/getnamecallmethod.', 'error', 8)
        Config.Enabled = false
        if EnabledToggle then EnabledToggle:Set(false, true) end
        return
    end

    if not installHook() then
        notify('Failed to install the hook.', 'error', 7)
        Config.Enabled = false
        if EnabledToggle then EnabledToggle:Set(false, true) end
        return
    end

    table.clear(learnQueue)
    lastPressAt = 0
    learning = true

    task.spawn(function()
        while learning and not Unloading do
            if #learnQueue > 0 then
                local item = table.remove(learnQueue, 1)
                local delta = item.at - lastPressAt
                if lastPressAt > 0 and delta >= 0 and delta <= 0.4 then
                    if lockRemote(item.instance) then
                        break
                    end
                end
            else
                task.wait(0.05)
            end
        end
    end)
end

local function isPressLikeInput(inputType)
    return inputType == Enum.UserInputType.MouseButton1
        or inputType == Enum.UserInputType.MouseButton2
        or inputType == Enum.UserInputType.Touch
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloading or not learning then return end
    if processed then return end
    if not isPressLikeInput(input.UserInputType) then return end
    lastPressAt = os.clock()
end))

local function fireLocked()
    local remote = LockedRemote
    local className = LockedClass
    if not remote then return end

    CooldownUntil = os.clock() + Config.Cooldown

    task.spawn(function()
        local ok = pcall(function()
            if className == "RemoteFunction" then
                remote:InvokeServer()
            else
                remote:FireServer()
            end
        end)

        if ok then
            Fires = Fires + 1
        else
            log("fire failed")
        end
    end)
end

track(PreSimulation:Connect(function()
    if Unloading or not Config.Enabled or not LockedRemote then return end
    if os.clock() < CooldownUntil then return end

    local ball, isTraining = realBall()
    if not ball then return end

    local root = getRoot()
    if not root then return end

    if isTraining then
        if not isAlive() then return end
    else
        if not isPlaying() then return end
        if ball:GetAttribute("target") ~= LocalPlayer.Name then return end
    end

    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    if distance > Config.MaxDistance then return end

    local velocity = ball.AssemblyLinearVelocity
    if distance < 0.01 then return end

    local closing = velocity:Dot(offset.Unit)
    if closing <= 1 then return end

    local eta = distance / closing

    local ping = 0
    if PingModule then
        ping = PingModule:GetAttribute("LocalPlayerPing") or 0
    end

    local lead = Config.Lead
        + (ping * 0.5 * Config.PingFactor)
        + math.clamp(closing / 1000, 0, 1) * Config.SpeedLead

    if eta > lead then return end

    fireLocked()
end))

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

local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })
local MainSection = MainTab:Section({ Title = 'auto parry', Side = 'left' })

statusStat = MainSection:Stat({ Title = 'status', Value = 'off' })
lockedStat = MainSection:Stat({ Title = 'learned remote', Value = 'none yet' })

EnabledToggle = MainSection:Toggle({
    Title = 'auto parry',
    Flag = 'bb_auto_parry',
    Default = false,
    Callback = function(value)
        Config.Enabled = value
        if value then
            if not LockedRemote then
                startLearning()
                notify('Parry once yourself - it will learn from that press.', 'warning', 9)
            end
        else
            stopLearning()
        end
    end,
})

local TuningSection = MainTab:Section({ Title = 'timing', Side = 'left' })

TuningSection:Slider({
    Title = 'lead',
    Flag = 'bb_lead',
    Min = 0.1,
    Max = 0.8,
    Increment = 0.01,
    Default = 0.38,
    Suffix = 's',
    Callback = function(value) Config.Lead = value end,
})

TuningSection:Slider({
    Title = 'speed lead',
    Flag = 'bb_speed_lead',
    Min = 0,
    Max = 0.4,
    Increment = 0.01,
    Default = 0.12,
    Suffix = 's',
    Callback = function(value) Config.SpeedLead = value end,
})

TuningSection:Slider({
    Title = 'ping compensation',
    Flag = 'bb_ping',
    Min = 0,
    Max = 2,
    Increment = 0.1,
    Default = 1,
    Suffix = 'x',
    Callback = function(value) Config.PingFactor = value end,
})

local ControlSection = MainTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'forget learned remote',
    Callback = function()
        LockedRemote = nil
        LockedClass = nil
        LockedFullName = nil
        stopLearning()
        log("forgot learned remote")
        notify('Forgotten. Turn auto parry off and on to learn again.', 'warning', 7)
    end,
})

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        Config.Enabled = false
        stopLearning()
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        Centrl:Unload()
    end,
})

ControlSection:Paragraph({
    Title = 'how it learns',
    Text = 'Turn auto parry on, then parry once yourself the normal way. Whatever remote your own press fires within 0.4s gets locked in and reused for every parry after that. The hook is installed once and stays installed as a plain passthrough - it is never uninstalled, because hookmetamethod does not restore, it replaces, and re-installing what it returned makes it call itself until the client dies.',
})

task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            if not Config.Enabled then
                statusStat:Set('off')
            elseif LockedRemote then
                statusStat:Set(('armed - %d fired'):format(Fires), Color3.fromRGB(126, 217, 87))
            elseif learning then
                statusStat:Set('parry once yourself...', Color3.fromRGB(255, 180, 70))
            else
                statusStat:Set('idle')
            end
            lockedStat:Set(LockedFullName or 'none yet')
        end)
    end
end)

Window:Load()
log("loaded")

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

local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local Unloading = false
local notify

local EnabledToggle
local statusStat

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local Config = {
    Enabled = false,
    Lead = 0.40,
    PingFactor = 1.0,
    MaxDistance = 140,
    UseClosingSpeed = true,
    Cooldown = 0.195,
}

local Fires = 0
local CooldownUntil = 0

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

local function isPlaying()
    local char = LocalPlayer.Character
    if not char then return false end
    if AliveFolder and char.Parent ~= AliveFolder then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

local function isAlive()
    local char = LocalPlayer.Character
    if not char then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
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

local function closingSpeed(ball, root)
    local velocity = ball.AssemblyLinearVelocity
    if not Config.UseClosingSpeed then return velocity.Magnitude end
    local toMe = root.Position - ball.Position
    if toMe.Magnitude < 0.01 then return velocity.Magnitude end
    local closing = velocity:Dot(toMe.Unit)
    if closing <= 0 then return 0 end
    return closing
end

local HAS_NAMECALL = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"
local CAPTURE_IGNORE = { SetPointer = true, SetLook = true, Ping = true, Fps = true, MenuState = true, OnDeath = true }
local CAPTURE_IGNORE_TAGS = {
    Activity = true,
    Snapshot = true,
    UIInteraction = true,
    AFKStart = true,
    AFKEnd = true,
    FirstMove = true,
    ["5455ef47-de02-4074-808c-8d82c2cd12ec"] = true,
}

local function isPressLikeInput(inputType)
    return inputType == Enum.UserInputType.MouseButton1
        or inputType == Enum.UserInputType.MouseButton2
        or inputType == Enum.UserInputType.Touch
end

local LockedRemote = nil
local LockedClass = nil
local learning = false
local recentlyPressed = false
local learnOriginalNamecall = nil
local learnInputConnection = nil
local learnQueue = {}
local LEARN_QUEUE_LIMIT = 20

local function stopLearning()
    learning = false
    table.clear(learnQueue)
    if learnOriginalNamecall then
        pcall(function() hookmetamethod(game, "__namecall", learnOriginalNamecall) end)
        learnOriginalNamecall = nil
    end
    if learnInputConnection then
        learnInputConnection:Disconnect()
        learnInputConnection = nil
    end
end

local function lockRemote(instance)
    local okClass, className = pcall(function() return instance.ClassName end)
    if not okClass then return end

    LockedRemote = instance
    LockedClass = className
    stopLearning()

    local okFullName, fullName = pcall(function() return instance:GetFullName() end)
    log("locked remote: " .. (okFullName and fullName or "?"))
    notify('Learned the real parry remote from your press - auto parry is armed.', 'success', 8)
end

local function startLearning()
    if learning or LockedRemote then return end
    if not HAS_NAMECALL then
        notify('This executor has no hookmetamethod/getnamecallmethod - cannot learn the remote.', 'error', 8)
        if EnabledToggle then EnabledToggle:Set(false, true) end
        Config.Enabled = false
        return
    end

    learning = true
    table.clear(learnQueue)

    learnInputConnection = track(UserInputService.InputBegan:Connect(function(input, processed)
        if not isPressLikeInput(input.UserInputType) then return end
        recentlyPressed = true
        task.delay(0.5, function() recentlyPressed = false end)
    end))

    local hookOk = pcall(function()
        learnOriginalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if learning and recentlyPressed and typeof(self) == "Instance" and #learnQueue < LEARN_QUEUE_LIMIT then
                local okMethod, method = pcall(getnamecallmethod)
                if okMethod and (method == "FireServer" or method == "Fire" or method == "InvokeServer") then
                    local okName, name = pcall(function() return self.Name end)
                    local firstArg = select(1, ...)
                    local ignored = (okName and CAPTURE_IGNORE[name] == true) or CAPTURE_IGNORE_TAGS[firstArg] == true

                    if not ignored then
                        learnQueue[#learnQueue + 1] = self
                    end
                end
            end
            return learnOriginalNamecall(self, ...)
        end)
    end)

    if not hookOk or not learnOriginalNamecall then
        learning = false
        if learnInputConnection then
            learnInputConnection:Disconnect()
            learnInputConnection = nil
        end
        notify('Failed to install the learning hook.', 'error', 6)
        return
    end

    task.spawn(function()
        while learning do
            if #learnQueue > 0 then
                local candidate = table.remove(learnQueue, 1)
                lockRemote(candidate)
                break
            end
            task.wait(0.05)
        end
    end)
end

local function fireLocked()
    if not LockedRemote then return end
    CooldownUntil = os.clock() + Config.Cooldown

    task.spawn(function()
        local okClass, className = pcall(function() return LockedRemote.ClassName end)
        if not okClass then return end

        local ok = pcall(function()
            if className == "RemoteFunction" then
                LockedRemote:InvokeServer()
            elseif className == "BindableEvent" then
                LockedRemote:Fire()
            else
                LockedRemote:FireServer()
            end
        end)

        if ok then
            Fires = Fires + 1
            log(("fired locked remote (#%d)"):format(Fires))
        else
            log("fired locked remote FAILED")
        end
    end)
end

track(PostSimulation:Connect(function()
    if Unloading or not Config.Enabled or not LockedRemote then return end

    local ball, isTraining = realBall()
    local root = getRoot()
    if not ball or not root then return end

    if isTraining then
        if not isAlive() then return end
    else
        if not isPlaying() then return end
        if ball:GetAttribute("target") ~= LocalPlayer.Name then return end
    end

    if os.clock() < CooldownUntil then return end

    local distance = (ball.Position - root.Position).Magnitude
    if distance > Config.MaxDistance then return end

    local speed = closingSpeed(ball, root)
    if speed <= 1 then return end

    local eta = distance / speed
    local ping = PingModule and (PingModule:GetAttribute("LocalPlayerPing") or 0) or 0
    local lead = Config.Lead + (ping * 0.5 * Config.PingFactor)
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

EnabledToggle = MainSection:Toggle({
    Title = 'auto parry',
    Flag = 'bb_auto_parry',
    Default = false,
    Callback = function(value)
        Config.Enabled = value
        if value then
            if not LockedRemote then
                startLearning()
                notify('Waiting for your next real parry press to learn the remote...', 'warning', 8)
            end
        else
            stopLearning()
        end
        log(value and "auto parry ON" or "auto parry OFF")
    end,
})

local ControlSection = MainTab:Section({ Title = 'control', Side = 'right' })

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

task.spawn(function()
    while not Unloading do
        task.wait(0.2)
        pcall(function()
            if not Config.Enabled then
                statusStat:Set('off')
            elseif LockedRemote then
                statusStat:Set(('armed - %d fired'):format(Fires), Color3.fromRGB(126, 217, 87))
            elseif learning then
                statusStat:Set('waiting for your real parry...', Color3.fromRGB(255, 180, 70))
            else
                statusStat:Set('starting...')
            end
        end)
    end
end)

Window:Load()
log("loaded")

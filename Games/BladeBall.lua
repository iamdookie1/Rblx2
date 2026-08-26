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

local Connections = {}
local Unloading = false
local notify
local remoteConsole

local EnabledToggle

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

local Config = {
    Enabled = false,

    Mode = "Indicator",

    Lead = 0.40,
    PingFactor = 1.0,
    MaxDistance = 140,
    UseClosingSpeed = true,

    PressBudget = 2,
    CaptureWindow = 2.0,
    ObserveWindow = 10,

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
    UIBlock = { presses = 0, successes = 0 },
    UIButton = { presses = 0, successes = 0 },
    ReplayInput = { presses = 0, successes = 0 },
    FireCaptured = { presses = 0, successes = 0 },
    Animation = { presses = 0, successes = 0 },
    Bindable = { presses = 0, successes = 0 },
    Input = { presses = 0, successes = 0 },
    Capture = { presses = 0, successes = 0 },
    Observe = { presses = 0, successes = 0 },
}

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
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)

local ParryAttempt = Remotes and Remotes:FindFirstChild("ParryAttempt")
local ParryButtonPress = Remotes and Remotes:FindFirstChild("ParryButtonPress")
local ParrySuccessRemote = Remotes and Remotes:FindFirstChild("ParrySuccess")
local VisualCD = Remotes and Remotes:FindFirstChild("VisualCD")
local KeybindM2 = Remotes and Remotes:FindFirstChild("KeybindM2")

local PackagesFolder = ReplicatedStorage:WaitForChild("Packages", 10)
local NetModule = PackagesFolder and PackagesFolder:FindFirstChild("_Index")
NetModule = NetModule and NetModule:FindFirstChild("sleitnick_net@0.1.0")
NetModule = NetModule and NetModule:FindFirstChild("net")

local UIBlockRemote = NetModule and NetModule:FindFirstChild(
    "RE/39401853105429a6fe7a64f68bfa545f05c15db6dfca91b9c9f53836a9ada3ff")

local PlayerGuiFolder = LocalPlayer:WaitForChild("PlayerGui", 10)
local HotbarFrame = PlayerGuiFolder and PlayerGuiFolder:FindFirstChild("Hotbar")
local BlockButton = HotbarFrame and HotbarFrame:FindFirstChild("Block")

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
    if not Config.Logging then return end
    appendToFile(("[%s] %s\n"):format(os.date("%H:%M:%S"), text))
end

local SNAP_PATH_1 = "RemotesSnap.txt"
local SNAP_PATH_2 = "RemotesSnap2.txt"
local canRead = typeof(readfile) == "function"
local canCheckFile = typeof(isfile) == "function"
local canDelete = typeof(delfile) == "function"

local function dumpNetLines()
    local lines = {}
    if NetModule then
        for _, child in ipairs(NetModule:GetChildren()) do
            lines[#lines + 1] = child.ClassName .. " | " .. child.Name
        end
    end
    table.sort(lines)
    return lines
end

local function snapshotRemotes()
    if not NetModule then return false, "net module missing" end
    if not canWrite or not canCheckFile then return false, "executor has no writefile/isfile" end

    local dump = table.concat(dumpNetLines(), "\n")
    local target
    if not isfile(SNAP_PATH_1) then
        target = SNAP_PATH_1
    elseif not isfile(SNAP_PATH_2) then
        target = SNAP_PATH_2
    else
        return false, "both snapshots already exist - reset first"
    end

    local ok = pcall(writefile, target, dump)
    if not ok then return false, "writefile failed for " .. target end
    return true, target
end

local function resetSnapshots()
    if canDelete then
        pcall(delfile, SNAP_PATH_1)
        pcall(delfile, SNAP_PATH_2)
    elseif canWrite then
        pcall(writefile, SNAP_PATH_1, "")
        pcall(writefile, SNAP_PATH_2, "")
    end
end

local function compareSnapshots()
    if not canRead or not canCheckFile then return nil, "executor has no readfile/isfile" end
    if not isfile(SNAP_PATH_1) or not isfile(SNAP_PATH_2) then
        return nil, "need both " .. SNAP_PATH_1 .. " and " .. SNAP_PATH_2
    end

    local okA, contentsA = pcall(readfile, SNAP_PATH_1)
    local okB, contentsB = pcall(readfile, SNAP_PATH_2)
    if not okA or not okB then return nil, "readfile failed" end

    local setA, setB = {}, {}
    for line in contentsA:gmatch("[^\n]+") do setA[line] = true end
    for line in contentsB:gmatch("[^\n]+") do setB[line] = true end

    local onlyA, onlyB = {}, {}
    for line in pairs(setA) do
        if not setB[line] then onlyA[#onlyA + 1] = line end
    end
    for line in pairs(setB) do
        if not setA[line] then onlyB[#onlyB + 1] = line end
    end
    table.sort(onlyA)
    table.sort(onlyB)

    return { onlyA = onlyA, onlyB = onlyB }
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

local parryInputType = Enum.UserInputType.MouseButton1

if KeybindM2 then
    track(KeybindM2.OnClientEvent:Connect(function(useM2)
        parryInputType = useM2 and Enum.UserInputType.MouseButton2
            or Enum.UserInputType.MouseButton1
    end))
end

local function isTouchDevice()
    local ok, touch = pcall(function()
        return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
    end)
    return ok and touch == true
end

local netWatching = false

local function startNetWatch(duration)
    if not NetModule then return false, "net module missing" end
    if netWatching then return false, "already watching" end
    netWatching = true

    local known = {}
    for _, child in ipairs(NetModule:GetChildren()) do
        known[child] = true
    end

    task.spawn(function()
        local deadline = os.clock() + duration
        local found = {}
        while os.clock() < deadline and netWatching do
            for _, child in ipairs(NetModule:GetChildren()) do
                if not known[child] then
                    known[child] = true
                    local line = child.ClassName .. " | " .. child.Name
                    found[#found + 1] = line
                    log("watch: new remote appeared -> " .. line)
                end
            end
            task.wait(0.05)
        end
        netWatching = false

        if #found == 0 then
            notify('No new remotes appeared under net during the window. No hook was used either way - this was pure GetChildren polling.', 'warning', 8)
        else
            local text = table.concat(found, "\n")
            local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
            notify(copied
                and ('%d new remote(s) appeared - copied to clipboard.'):format(#found)
                or ('%d new remote(s) appeared - see %s'):format(#found, LOG_PATH),
                'success', 8)
        end
    end)

    return true
end

local HAS_NAMECALL = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"
local capturing = false

local CAPTURE_LIMIT = 60
local CAPTURE_IGNORE = { SetPointer = true, SetLook = true, Ping = true, Fps = true, MenuState = true, OnDeath = true }
local CAPTURE_IGNORE_TAGS = { Activity = true, Snapshot = true, ["5455ef47-de02-4074-808c-8d82c2cd12ec"] = true }

local LastCaptured = {}
local CapturedTargetIndex = nil

local function recordCaptured(instance, fullName)
    local hash = fullName:match("/(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)$")
    LastCaptured[#LastCaptured + 1] = { instance = instance, hash = hash, fullName = fullName }
    if #LastCaptured > 20 then
        table.remove(LastCaptured, 1)
        if CapturedTargetIndex then
            CapturedTargetIndex = math.max(1, CapturedTargetIndex - 1)
        end
    end
end

local function currentCapturedEntry()
    if #LastCaptured == 0 then return nil, 0 end
    local index = CapturedTargetIndex or #LastCaptured
    index = math.max(1, math.min(index, #LastCaptured))
    return LastCaptured[index], index
end

local function searchGameForValue(target)
    local matches = {}
    local scanned = 0
    local descendants = game:GetDescendants()

    for _, instance in ipairs(descendants) do
        scanned = scanned + 1
        if scanned % 500 == 0 then task.wait() end

        local okAttrs, attrs = pcall(function() return instance:GetAttributes() end)
        if okAttrs and attrs then
            for key, value in pairs(attrs) do
                if tostring(value) == target then
                    matches[#matches + 1] = instance:GetFullName() .. " [" .. key .. "=" .. tostring(value) .. "]"
                end
            end
        end
    end

    return matches, scanned
end

local function findPlacement(self)
    local okParent, parent = pcall(function() return self.Parent end)
    if not okParent or not parent then return nil end
    local okChildren, children = pcall(function() return parent:GetChildren() end)
    if not okChildren then return nil end
    for index, child in ipairs(children) do
        if child == self then
            return index, #children
        end
    end
    return nil
end

local function describeCall(self, method, args)
    local fullName = "?"
    pcall(function() fullName = self:GetFullName() end)

    local placementText = ""
    local index, total = findPlacement(self)
    if index then
        placementText = ("[placement %d/%d] "):format(index, total)
    end

    local parts = {}
    for index, value in ipairs(args) do
        local ok, text = pcall(function()
            if typeof(value) == "Instance" then
                return "Instance(" .. value:GetFullName() .. ")"
            end
            if typeof(value) == "table" then

                local pairsText = {}
                for key, inner in pairs(value) do
                    pairsText[#pairsText + 1] = tostring(key) .. "=" .. tostring(inner)
                end
                return "{" .. table.concat(pairsText, ", ") .. "}"
            end
            return tostring(value)
        end)
        parts[index] = ok and text or "<unreadable>"
    end

    local tag = fullName:find("sleitnick_net", 1, true) and "[NET] " or ""
    return ("%s%s%s : %s(%s)"):format(tag, placementText, fullName, method, table.concat(parts, ", "))
end

local function pressInput()
    local vim = game:GetService("VirtualInputManager")
    if typeof(vim) ~= "Instance" then return false, "no VirtualInputManager" end

    local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local x, y = viewport.X * 0.5, viewport.Y * 0.5

    if isTouchDevice() then

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
end

local BUTTON_SIGNAL_NAMES = { "Activated", "MouseButton1Click", "MouseButton1Down" }

local function fireButtonSignal(guiButton)
    if typeof(firesignal) ~= "function" then return false, "no firesignal on this executor" end

    for _, signalName in ipairs(BUTTON_SIGNAL_NAMES) do
        local okSignal, signal = pcall(function() return guiButton[signalName] end)
        if okSignal and signal then
            if pcall(firesignal, signal) then return true end
        end
    end

    return false, "firesignal failed on every signal tried"
end

local function fireButtonConnections(guiButton)
    if typeof(getconnections) ~= "function" then return false, "no getconnections on this executor" end

    for _, signalName in ipairs(BUTTON_SIGNAL_NAMES) do
        local okSignal, signal = pcall(function() return guiButton[signalName] end)
        if okSignal and signal then
            local okConn, connections = pcall(getconnections, signal)
            if okConn and typeof(connections) == "table" and #connections > 0 then
                local fired = false
                for _, connection in ipairs(connections) do
                    if pcall(function() connection:Fire() end) then fired = true end
                end
                if fired then return true end
            end
        end
    end

    return false, "no working connections found"
end

local function describeSignalConnections(signal, label)
    local lines = {}
    if typeof(getconnections) ~= "function" then return lines end

    local okConn, connections = pcall(getconnections, signal)
    if okConn and typeof(connections) == "table" then
        for index, connection in ipairs(connections) do
            local line = ("%s #%d: "):format(label, index)
            local okFn, fn = pcall(function() return connection.Function end)
            if okFn and typeof(fn) == "function" then
                local results = { pcall(debug.info, fn, "slna") }
                if results[1] then
                    local source, currentLine, name, numParams, isVararg = results[2], results[3], results[4], results[5], results[6]
                    line = line .. ("source=%s line=%s name=%s params=%s vararg=%s"):format(
                        tostring(source), tostring(currentLine), tostring(name), tostring(numParams), tostring(isVararg))
                else
                    line = line .. "<no debug.info>"
                end
            else
                line = line .. "<no Function field / locked>"
            end
            lines[#lines + 1] = line
        end
    end

    return lines
end

local function describeButtonConnections(guiButton)
    local lines = {}

    for _, signalName in ipairs(BUTTON_SIGNAL_NAMES) do
        local okSignal, signal = pcall(function() return guiButton[signalName] end)
        if okSignal and signal then
            for _, line in ipairs(describeSignalConnections(signal, signalName)) do
                lines[#lines + 1] = line
            end
        end
    end

    return lines
end

local function clickButtonDirectly(guiButton)
    local vim = game:GetService("VirtualInputManager")
    if typeof(vim) ~= "Instance" then return false, "no VirtualInputManager" end

    local okPos, center = pcall(function()
        return guiButton.AbsolutePosition + guiButton.AbsoluteSize * 0.5
    end)
    if not okPos then return false, "could not read button position" end

    local x, y = center.X, center.Y

    if isTouchDevice() then
        return pcall(function()
            vim:SendTouchEvent(1, 0, x, y)
            vim:SendTouchEvent(1, 2, x, y)
        end)
    end

    return pcall(function()
        vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
        vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
end

local GrabParryAnim = Instance.new("Animation")
GrabParryAnim.AnimationId = "rbxassetid://13772445960"

local grabParryTracks = setmetatable({}, { __mode = "k" })

local function getGrabParryTrack()
    local char = LocalPlayer.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return nil end

    local existing = grabParryTracks[animator]
    if existing then return existing end

    local ok, animTrack = pcall(function() return animator:LoadAnimation(GrabParryAnim) end)
    if not ok then return nil end

    grabParryTracks[animator] = animTrack
    return animTrack
end

local animWatching = false

local function watchAnimations(duration)
    if animWatching then return false, "already watching" end
    local char = LocalPlayer.Character
    if not char then return false, "no character" end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return false, "no Animator found on current character" end

    animWatching = true
    local found = {}
    local connection
    connection = track(animator.AnimationPlayed:Connect(function(animTrack)
        local id = "?"
        pcall(function() id = animTrack.Animation.AnimationId end)
        local line = ("%s | %s | weight=%.2f"):format(id, animTrack.Name, animTrack.WeightTarget)
        found[#found + 1] = line
        log("animation played -> " .. line)
    end))

    task.spawn(function()
        task.wait(duration)
        if connection then connection:Disconnect() end
        animWatching = false

        if #found == 0 then
            notify('No animations observed during the window.', 'warning', 7)
            return
        end

        local text = table.concat(found, "\n")
        local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
        notify(copied
            and ('%d animation(s) captured - copied to clipboard.'):format(#found)
            or ('%d animation(s) captured - see %s'):format(#found, LOG_PATH),
            'success', 8)
    end)

    return true
end

local CapturedInput = nil
local capturingInput = false

local function isPressLikeInput(inputType)
    return inputType == Enum.UserInputType.MouseButton1
        or inputType == Enum.UserInputType.MouseButton2
        or inputType == Enum.UserInputType.Touch
end

local function armInputCapture()
    if capturingInput then return false, "already capturing" end
    capturingInput = true

    local connection
    connection = track(UserInputService.InputBegan:Connect(function(input, processed)
        if not isPressLikeInput(input.UserInputType) then return end
        CapturedInput = input
        capturingInput = false
        if connection then connection:Disconnect() end
        notify('Captured a real input - ReplayInput mode is ready.', 'success', 6)
        log("captured real InputObject: " .. tostring(input.UserInputType))
    end))

    return true
end

local function replayCapturedInput()
    if not CapturedInput then return false, "no captured input yet - use the capture button first" end
    if typeof(getconnections) ~= "function" then return false, "no getconnections on this executor" end

    local okConn, connections = pcall(getconnections, UserInputService.InputBegan)
    if not okConn or typeof(connections) ~= "table" then return false, "getconnections failed" end

    local fired = false
    for _, connection in ipairs(connections) do
        local okFn, fn = pcall(function() return connection.Function end)
        if okFn and typeof(fn) == "function" then
            if pcall(function() connection:Fire(CapturedInput, false) end) then fired = true end
        end
    end

    if fired then return true end
    return false, "no non-locked connections to fire"
end

local liveLogging = false
local liveOriginalNamecall = nil

local function setLiveRemoteLogging(enabled)
    if enabled == liveLogging then return end

    if not enabled then
        if liveOriginalNamecall then
            pcall(function() hookmetamethod(game, "__namecall", liveOriginalNamecall) end)
            liveOriginalNamecall = nil
        end
        liveLogging = false
        log("live remote logging: off")
        return
    end

    if not HAS_NAMECALL then
        notify('This executor has no hookmetamethod/getnamecallmethod - cannot log remotes live.', 'error', 7)
        return
    end

    local hookOk = pcall(function()
        liveOriginalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if typeof(self) == "Instance" then
                local okMethod, method = pcall(getnamecallmethod)
                if okMethod and (method == "FireServer" or method == "Fire" or method == "InvokeServer") then
                    local okName, name = pcall(function() return self.Name end)
                    local firstArg = select(1, ...)
                    local ignored = (okName and CAPTURE_IGNORE[name] == true) or CAPTURE_IGNORE_TAGS[firstArg] == true

                    if not ignored then
                        local args = { ... }
                        task.spawn(function()
                            local summary = describeCall(self, method, args)
                            log("live -> " .. summary)
                            if remoteConsole then remoteConsole:Add(summary) end

                            local okFullName, fullName = pcall(function() return self:GetFullName() end)
                            if okFullName then recordCaptured(self, fullName) end
                        end)
                    end
                end
            end
            return liveOriginalNamecall(self, ...)
        end)
    end)

    if not hookOk or not liveOriginalNamecall then
        notify('Failed to install live hook.', 'error', 6)
        return
    end

    liveLogging = true
    log("live remote logging: on")
end

local function runCaptureWindow(duration, pressFirst)
    if not HAS_NAMECALL then return false, "no hookmetamethod on this executor" end
    if capturing then return false, "already capturing" end
    capturing = true

    local count = 0
    local ignoredCount = 0
    local summaries = {}
    local originalNamecall
    local hookOk = pcall(function()
        originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if count < CAPTURE_LIMIT and typeof(self) == "Instance" then
                local okMethod, method = pcall(getnamecallmethod)
                if okMethod and (method == "FireServer" or method == "Fire" or method == "InvokeServer") then
                    local okName, name = pcall(function() return self.Name end)
                    local firstArg = select(1, ...)
                    local ignored = (okName and CAPTURE_IGNORE[name] == true) or CAPTURE_IGNORE_TAGS[firstArg] == true

                    if ignored then
                        ignoredCount = ignoredCount + 1
                    else
                        count = count + 1
                        local args = { ... }

                        task.spawn(function()
                            local summary = describeCall(self, method, args)
                            summaries[#summaries + 1] = summary
                            log("capture #" .. count .. " -> " .. summary)
                            if remoteConsole then remoteConsole:Add(summary) end

                            local okFullName, fullName = pcall(function() return self:GetFullName() end)
                            if okFullName then recordCaptured(self, fullName) end
                        end)
                    end
                end
            end
            return originalNamecall(self, ...)
        end)
    end)

    if not hookOk or not originalNamecall then
        capturing = false
        return false, "hook install failed"
    end

    local pressOk = true
    if pressFirst then
        pressOk = pressInput()
    end

    task.spawn(function()

        local deadline = os.clock() + duration
        while os.clock() < deadline do
            task.wait()
        end
        pcall(function() hookmetamethod(game, "__namecall", originalNamecall) end)
        capturing = false

        if count == 0 then
            log(("capture: nothing new within %.1fs (%d filtered)"):format(duration, ignoredCount))
            if ignoredCount > 0 then
                notify(('Hook saw %d already-known call(s) (Ping, MenuState, etc) but nothing new.'):format(ignoredCount), 'warning', 8)
            else
                notify('Hook saw zero remote calls of any kind during the window.', 'warning', 7)
            end
            return
        end

        log(("capture: %d call(s) observed (%d filtered), see the lines above"):format(count, ignoredCount))
        if typeof(setclipboard) == "function" then
            local copied = pcall(setclipboard, table.concat(summaries, "\n"))
            notify(copied
                and ('Captured %d call(s). All copied to your clipboard.'):format(count)
                or ('Captured %d call(s), but copying failed - see %s'):format(count, LOG_PATH),
                copied and 'success' or 'warning', 8)
        else
            notify(('Captured %d call(s), but this executor has no setclipboard - see %s'):format(count, LOG_PATH), 'warning', 8)
        end
    end)

    return (not pressFirst) or pressOk, "armed"
end

local Pressers = {

    Remote = function()
        if not ParryAttempt then return false, "ParryAttempt missing" end
        return pcall(function() ParryAttempt:FireServer() end)
    end,

    UIBlock = function()
        if not UIBlockRemote then return false, "UIInteraction remote missing" end
        return pcall(function()
            UIBlockRemote:FireServer("UIInteraction", { ui = "Hotbar", inMatch = true, control = "Block" })
        end)
    end,

    UIButton = function()
        if not BlockButton then return false, "PlayerGui.Hotbar.Block missing" end
        if fireButtonSignal(BlockButton) then return true, "fired via firesignal" end
        if fireButtonConnections(BlockButton) then return true, "fired via connection" end
        return clickButtonDirectly(BlockButton)
    end,

    ReplayInput = replayCapturedInput,

    FireCaptured = function()
        local entry = currentCapturedEntry()
        if not entry then return false, "nothing captured yet" end

        local okClass, className = pcall(function() return entry.instance.ClassName end)
        if not okClass then return false, "captured instance is gone" end

        return pcall(function()
            if className == "RemoteFunction" then
                entry.instance:InvokeServer()
            else
                entry.instance:FireServer()
            end
        end)
    end,

    Animation = function()
        local animTrack = getGrabParryTrack()
        if not animTrack then return false, "could not load GrabParry animation track" end
        return pcall(function() animTrack:Play(0) end)
    end,

    Bindable = function()
        if not ParryButtonPress then return false, "ParryButtonPress missing" end
        return pcall(function() ParryButtonPress:Fire() end)
    end,

    Input = pressInput,

    Capture = function()
        return runCaptureWindow(Config.CaptureWindow, true)
    end,

    Observe = function()
        return runCaptureWindow(Config.ObserveWindow, false)
    end,
}

local budgetLabel

local function press()
    local presser = Pressers[Config.Mode]
    if not presser then return end

    if Stats.Budget <= 0 then
        Config.Enabled = false

        if EnabledToggle then EnabledToggle:Set(false, true) end
        log(("BUDGET SPENT on %s - auto parry disabled"):format(Config.Mode))
        notify('Press budget spent. Auto parry turned itself off.', 'warning', 8)
        return
    end

    Stats.Budget = Stats.Budget - 1
    Stats.Presses = Stats.Presses + 1
    Stats.LastPressAt = os.clock()

    local score = MethodScores[Config.Mode]
    if score then score.presses = score.presses + 1 end

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

track(PostSimulation:Connect(function()
    if Unloading then return end

    if PingModule then
        Stats.Ping = PingModule:GetAttribute("LocalPlayerPing") or 0
    end

    local showCue = os.clock() < cueUntil
    cueRing.Visible = showCue
    cueLabel.Visible = showCue

    local ball, isTraining = realBall()
    local root = getRoot()

    if not ball or not root then
        Stats.LastTarget = "-"
        Stats.LastEta = 0
        Stats.LastDistance = 0
        Stats.LastSpeed = 0
        return
    end

    Stats.LastTarget = isTraining and "(training)" or tostring(ball:GetAttribute("target"))

    local distance = (ball.Position - root.Position).Magnitude
    local speed = closingSpeed(ball, root)
    Stats.LastDistance = distance
    Stats.LastSpeed = speed

    local eta = math.huge
    if speed > 1 then eta = distance / speed end
    Stats.LastEta = eta

    if not Config.Enabled then return end
    if isTraining then
        if not isAlive() then return end
    else
        if not isPlaying() then return end
    end
    if not isTraining and ball:GetAttribute("target") ~= LocalPlayer.Name then return end
    if os.clock() < Stats.CooldownUntil then return end
    if distance > Config.MaxDistance then return end

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

if not BallsFolder and not TrainingBallsFolder then
    notify('workspace.Balls not found - the game may have changed.', 'error', 8)
elseif not BallsFolder then
    notify(('Using workspace.%s - workspace.Balls not found.'):format(TrainingBallsFolder.Name), 'warning', 6)
end

local MainTab = Window:Tab({ Title = 'parry', Icon = 'crosshair' })
local ModeSection = MainTab:Section({ Title = 'mode', Side = 'left' })

ModeSection:Dropdown({
    Title = 'mode',
    Flag = 'bb_mode',
    Options = { 'Indicator', 'Remote', 'UIBlock', 'UIButton', 'ReplayInput', 'FireCaptured', 'Animation', 'Bindable', 'Input', 'Capture', 'Observe' },
    Default = 'Indicator',
    Callback = function(value)
        Config.Mode = value
        Stats.Budget = Config.PressBudget
        if value == 'Indicator' then
            notify('Indicator only. Nothing is sent to the server.', 'success', 5)
        elseif value == 'Capture' then
            if not HAS_NAMECALL then
                notify('This executor has no hookmetamethod/getnamecallmethod - Capture cannot run here.', 'error', 8)
            else
                notify('Capture fires a real touch and records EVERY remote call seen for 0.5s, not just parry-shaped ones - written to file as each is seen. One attempt is enough - lower the press budget below.', 'warning', 10)
            end
        elseif value == 'Observe' then
            if not HAS_NAMECALL then
                notify('This executor has no hookmetamethod/getnamecallmethod - Observe cannot run here.', 'error', 8)
            else
                notify('Observe hooks the same as Capture but presses nothing itself - use it while another script (or your own real presses) does the real work, and it records every remote call seen during the window.', 'warning', 10)
            end
        else
            notify(('%s mode: %d presses then it turns itself off. This is the part that gets people kicked.')
                :format(value, Config.PressBudget), 'warning', 10)
        end
        log(("mode set to %s"):format(value))
    end,
})

EnabledToggle = ModeSection:Toggle({
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
    Default = 2,
    Callback = function(value)
        Config.PressBudget = value
        Stats.Budget = value
    end,
})

ModeSection:Slider({
    Title = 'capture window',
    Flag = 'bb_capture_window',
    Min = 0.3,
    Max = 4,
    Increment = 0.1,
    Default = 2.0,
    Suffix = 's',
    Callback = function(value) Config.CaptureWindow = value end,
})

ModeSection:Slider({
    Title = 'observe window',
    Flag = 'bb_observe_window',
    Min = 3,
    Max = 30,
    Increment = 1,
    Default = 10,
    Suffix = 's',
    Callback = function(value) Config.ObserveWindow = value end,
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
    Default = 0.40,
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
    Title = 'UIBlock - probably telemetry, not the real action',
    Text = 'Replicates the exact UIInteraction call captured alongside a real parry - same shape as the UIInteraction/JumpButton call seen earlier, which is a UI click log, not what makes the character jump. This is very likely the same: a report that the Hotbar Block button was clicked, not the thing that actually resolves a hit. The real decision most likely still goes through the separate hashed RemoteFunction seen firing in the same window, which cannot be hardcoded because its name is salted fresh per lobby. Cheap to test, low expectation it does anything.',
})

RiskSection:Paragraph({
    Title = 'Animation - plays GrabParry directly, no remote at all',
    Text = 'Loads and plays rbxassetid://13772445960 (GrabParry) on the current Animator - the exact animation confirmed to play on every real block press. Animation state replicates to the server automatically the same way a real press would, with no remote call from this script at all - the lowest-footprint method tried yet if the theory holds that blocking is resolved from replicated pose rather than an explicit attempt message. Unconfirmed: whether the server can tell a programmatically-played animation apart from one driven by real input.',
})

RiskSection:Paragraph({
    Title = 'FireCaptured - calls the exact instance last targeted',
    Text = 'Uses the literal Instance reference from the most recent Capture/Observe hit, not its name - so it works even though names rotate, as long as you are still in the lobby that instance came from. Strongest candidate yet if that last capture came from watching a script confirmed to actually work: calling the same real remote it used, timed against a real ball the same way every other mode is. Only as good as whatever was last captured - re-run Capture or Observe first if you switch targets.',
})

RiskSection:Paragraph({
    Title = 'ReplayInput - fires the suspected real VM handler with real captured input',
    Text = 'Requires capturing a real InputObject from your own keypress first (settings -> diagnostics -> capture next real press). Then fires every non-locked InputBegan connection with that real object - identified by elimination: 53 of 55 connections were locked C closures, 2 were real Luau functions with a scrambled Luraph-style source name, matching SwordsController.PRY. No synthetic click, no metamethod hook, no guessed remote name - but also the least proven, since firing a connection this way has never been tested against this specific VM before.',
})

RiskSection:Paragraph({
    Title = 'UIButton - runs the real handler instead of guessing a remote',
    Text = 'Targets PlayerGui.Hotbar.Block directly. First tries getconnections on its Activated/MouseButton1Click signal and fires the bound function itself - if the executor supports that, this runs the exact same code a real click runs, whatever remote it calls and whatever the current lobby\'s hash happens to be, without this script ever needing to know either. No hook, no guessed name. Falls back to a synthetic click aimed at the button\'s actual screen position (not screen centre like Input mode) only if getconnections is unavailable. If the connection route works, this is the closest thing here to a real press - and also the least tested.',
})

RiskSection:Paragraph({
    Title = 'Bindable',
    Text = 'Fires the ParryButtonPress BindableEvent, which should run the game\'s own parry path including its cooldown. That is the appeal. The risk is that BAC runs on this client too and can compare a parry against whether any real input happened.',
})

RiskSection:Paragraph({
    Title = 'Input - kicked twice now, for two different reasons',
    Text = 'First on a phone sending a MouseButton1 click while UserInputService reported TouchEnabled true, MouseEnabled false - a tell anything can read in two lines. Fixed: it now sends a touch on touch devices and a click on desktop. Tested again after the fix - the touch itself landed a real parry and was kicked anyway, fast. One success then an immediate kick is not what a slow statistical check looks like; it reads as a direct, synchronous signature check, most likely on VirtualInputManager use itself rather than anything about the click. There is no known way to make this method safe from inside this script.',
})

RiskSection:Paragraph({
    Title = 'Capture - grabs the real arguments instead of guessing them',
    Text = 'Fires the same real touch or click Input does, with a __namecall hook armed for the 0.5s around it. It no longer filters by name - a real test filtered for "parry" in the remote name, found nothing, and still got kicked, faster than previous kicks though not instantly. Most likely the real call has a different name entirely, so now every FireServer, Fire and InvokeServer seen in that window gets written to BladeBallParry.txt the instant it happens, not batched at the end. If the kick lands mid-window, whatever was already seen is already on disk.',
})

RiskSection:Paragraph({
    Title = 'Observe - same hook, but presses nothing itself',
    Text = 'For watching a known-working script instead of guessing blindly: run it alongside this one, arm Observe right before it would act, and everything it fires through FireServer/Fire/InvokeServer gets caught by the same hook Capture uses - just without this script adding its own synthetic press into the mix. Same __namecall exposure as Capture, held open longer (default 10s instead of 2s) since there is no single press to time it around.',
})

RiskSection:Paragraph({
    Title = 'this is a wider hook than it used to be',
    Text = 'Watching everything instead of one name means the hook can no longer stop the moment it sees a match - there might be more after it - so the full 0.5s is paid every time now, not just on a miss. That is more of the game\'s own traffic passing through code this script wrote, for longer, on every attempt. It is not a smaller risk than before; treat one capture as the whole budget for this mode.',
})

RiskSection:Paragraph({
    Title = 'the actual parry remote renames itself every call',
    Text = 'Two real-match captures around the same Block control produced two different hashed RemoteFunction names, both invoked with zero arguments. A stable hash from sleitnick_net would repeat every time for the same name - it did not, which means the name is being regenerated per call on purpose. There is nothing to hardcode here; any saved hash is already wrong by the next press. Capture is the only mode that can ever reach this one, because it reads whatever the game itself just called instead of guessing a name in advance.',
})

RiskSection:Paragraph({
    Title = 'why nothing here can make a call look legitimate on its own',
    Text = 'Firing ParryAttempt with the right arguments needs the arguments, and the only code that ever knew them was SwordsController.PRY, a Luraph VM. Capture is the compromise: instead of reading the VM, it reads what the VM itself sends over the wire when a real touch triggers it - but getting there means hooking a metamethod, and that module already checks whether debug.info has been hooked, which is exactly the technique used to detect a hook like this one. If your executor has a built-in remote spy, that runs below the game and is the one route that puts no hook in this script at all - prefer it over Capture if you have it.',
})

RiskSection:Paragraph({
    Title = 'there is no window to beat the kick in',
    Text = 'The server decides before the client ever sees anything - by the time a kick message renders, the check that produced it already ran and already finished. There is no intermediate signal to react to, because for one to exist, detection and enforcement would have to be two separate steps with something crossing back to the client in between. What actually happened - one parry, then an immediate kick - looks like a single synchronous check with no such gap. And even where anti-cheats do delay enforcement, the delay is often deliberately randomised so it cannot be timed against. Racing this is not a code problem with a code answer.',
})

RiskSection:Paragraph({
    Title = 'there is no window to beat the kick in',
    Text = 'The server decides before the client ever sees anything - by the time a kick message renders, the check that produced it already ran and already finished. There is no intermediate signal to react to, because for one to exist, detection and enforcement would have to be two separate steps with something crossing back to the client in between. What actually happened - one parry, then an immediate kick - looks like a single synchronous check with no such gap. And even where anti-cheats do delay enforcement, the delay is often deliberately randomised so it cannot be timed against. Racing this is not a code problem with a code answer.',
})

RiskSection:Paragraph({
    Title = 'can the anti-cheat just be turned off',
    Text = 'It runs on your client, so in principle yes. In practice it is a Luraph VM that is already required and running before this script loads, and it sets BAC_HASH plus two decoy globals specifically so tampering shows. The bigger problem is that this game routes 1232 of its remotes through hashed names - the anti-cheat almost certainly reports over one of them and cannot be picked out by name. Silencing a client that the server expects to hear from usually ends the same way as being caught by it, except the kick becomes something that does not expire.',
})

local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'right' })

DiagSection:Stat({
    Title = 'Capture support',
    Value = HAS_NAMECALL and 'hookmetamethod found' or 'not available on this executor',
})

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
    Title = 'watch for new remotes (10s, no hook)',
    Callback = function()
        if not NetModule then
            notify('sleitnick_net module not found.', 'error', 6)
            return
        end
        local ok, err = startNetWatch(10)
        if ok then
            notify('Watching net for 10s. Press the real parry key yourself right now - no synthetic input, no hook, just reading GetChildren.', 'warning', 8)
        else
            notify(tostring(err), 'error', 6)
        end
    end,
})

DiagSection:Button({
    Title = 'copy Block button connections',
    Callback = function()
        if not BlockButton then
            notify('PlayerGui.Hotbar.Block missing.', 'error', 6)
            return
        end
        local lines = describeButtonConnections(BlockButton)
        if #lines == 0 then
            notify('No connections found (or no getconnections on this executor).', 'warning', 7)
            return
        end
        local text = table.concat(lines, "\n")
        log("connections -> " .. text)
        local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
        notify(copied
            and ('%d connection(s) copied to clipboard.'):format(#lines)
            or ('%d connection(s) - see %s'):format(#lines, LOG_PATH),
            'success', 7)
    end,
})

DiagSection:Paragraph({
    Title = 'why InputBegan is next',
    Text = 'Both connections found on Hotbar.Block (ClickSFX, AnalyticsController) are generic UI components attached to every button in the game, not this one specifically. If that is everything on this instance, the real block detection is not wired to this button at all - it is more likely watching raw input directly, which is also the only way KeybindM2 (letting you rebind M1/M2) would make sense in the first place.',
})

DiagSection:Button({
    Title = 'copy InputBegan connections',
    Callback = function()
        local lines = describeSignalConnections(UserInputService.InputBegan, "InputBegan")
        if #lines == 0 then
            notify('No connections found (or no getconnections on this executor).', 'warning', 7)
            return
        end
        local text = table.concat(lines, "\n")
        log("InputBegan connections -> " .. text)
        local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
        notify(copied
            and ('%d connection(s) copied to clipboard.'):format(#lines)
            or ('%d connection(s) - see %s'):format(#lines, LOG_PATH),
            'success', 7)
    end,
})

DiagSection:Paragraph({
    Title = 'ReplayInput - capture a real press, then replay it',
    Text = '53 of 55 InputBegan connections were locked C closures - normal engine plumbing. 2 came back as real Luau functions with a scrambled, unreadable source name, exactly what a Luraph chunk looks like through debug.info. That matches SwordsController.PRY. Capture below saves the very next real InputObject from your actual keypress, then ReplayInput mode fires every non-locked InputBegan connection with that real captured object - the VM runs its own real code on real input data, no synthetic click, no guessed remote name.',
})

DiagSection:Button({
    Title = 'capture next real press (for ReplayInput)',
    Callback = function()
        local ok, err = armInputCapture()
        if ok then
            notify('Armed. Press your real parry key/button right now.', 'warning', 7)
        else
            notify(tostring(err), 'error', 6)
        end
    end,
})

DiagSection:Paragraph({
    Title = 'maybe there is no remote - animation watch',
    Text = 'Every remote-based method tried so far (Remote, UIBlock, UIButton, ReplayInput) produced no effect, including ReplayInput firing the suspected real VM handler with a genuinely captured InputObject - and training confirmed it resolves hits for real (getting hit ejects you), so that is not explained away by a fake test environment. Blade-dodging games commonly resolve blocks by animation instead of by remote: press block plays a local animation, which replicates automatically with no remote call needed, and the server checks your replicated pose against its own ball tracking. Watch below for 10s and do one real manual block press - whatever animation ID plays is the next thing worth targeting instead of another remote guess.',
})

DiagSection:Button({
    Title = 'watch animations (10s, real press)',
    Callback = function()
        local ok, err = watchAnimations(10)
        if ok then
            notify('Watching for 10s. Do one real manual block press right now.', 'warning', 7)
        else
            notify(tostring(err), 'error', 6)
        end
    end,
})

DiagSection:Paragraph({
    Title = 'compare across lobbies',
    Text = 'Snapshot saves every remote name under net to RemotesSnap.txt. Do it once this lobby, rejoin or queue into a new match, then snapshot again - it writes to RemotesSnap2.txt automatically since the first file already exists. Compare then reads both and reports exactly which names differ between the two lobbies. Reset clears both files to start over.',
})

DiagSection:Button({
    Title = 'snapshot remotes (for lobby compare)',
    Callback = function()
        local ok, result = snapshotRemotes()
        if ok then
            notify(('Saved %s (%d remotes).'):format(result, #dumpNetLines()), 'success', 6)
        else
            notify(tostring(result), 'error', 6)
        end
    end,
})

DiagSection:Button({
    Title = 'compare snapshots',
    Callback = function()
        local result, err = compareSnapshots()
        if not result then
            notify(tostring(err), 'error', 6)
            return
        end

        local totalDiff = #result.onlyA + #result.onlyB
        log(("compare: %d only in snap1, %d only in snap2"):format(#result.onlyA, #result.onlyB))

        local lines = {}
        table.insert(lines, ("-- only in %s (%d) --"):format(SNAP_PATH_1, #result.onlyA))
        for _, line in ipairs(result.onlyA) do table.insert(lines, line) end
        table.insert(lines, ("-- only in %s (%d) --"):format(SNAP_PATH_2, #result.onlyB))
        for _, line in ipairs(result.onlyB) do table.insert(lines, line) end
        local text = table.concat(lines, "\n")

        if canWrite then pcall(writefile, "RemotesSnapDiff.txt", text) end
        local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)

        if totalDiff == 0 then
            notify('No differences - every remote name matched across both lobbies.', 'success', 8)
        else
            notify(('%d remote(s) differ between lobbies.%s'):format(
                totalDiff, copied and ' Copied to clipboard.' or ' See RemotesSnapDiff.txt'), 'warning', 8)
        end
    end,
})

DiagSection:Button({
    Title = 'reset snapshots',
    Callback = function()
        resetSnapshots()
        notify('Both snapshot files cleared.')
    end,
})

DiagSection:Paragraph({
    Title = 'picking which capture FireCaptured targets',
    Text = 'A single Capture/Observe window can catch more than one call - FireCaptured only ever used the very last one, with no way to check whether that was actually the right one. List shows every recent capture with its index; the target buttons move which one FireCaptured will call, defaulting to the newest.',
})

DiagSection:Button({
    Title = 'list recent captures',
    Callback = function()
        if #LastCaptured == 0 then
            notify('Nothing captured yet.', 'warning', 6)
            return
        end

        local lines = {}
        for index, entry in ipairs(LastCaptured) do
            local marker = (index == select(2, currentCapturedEntry())) and " <- target" or ""
            lines[#lines + 1] = ("#%d: %s%s"):format(index, entry.fullName, marker)
        end

        local text = table.concat(lines, "\n")
        log("recent captures ->\n" .. text)
        local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
        notify(copied
            and ('%d capture(s) copied to clipboard.'):format(#LastCaptured)
            or ('%d capture(s) - see %s'):format(#LastCaptured, LOG_PATH),
            'success', 7)
    end,
})

DiagSection:Button({
    Title = 'target previous capture',
    Callback = function()
        if #LastCaptured == 0 then
            notify('Nothing captured yet.', 'warning', 6)
            return
        end
        local _, index = currentCapturedEntry()
        CapturedTargetIndex = math.max(1, index - 1)
        local entry = LastCaptured[CapturedTargetIndex]
        notify(('Targeting #%d: %s'):format(CapturedTargetIndex, entry.fullName), 'success', 6)
    end,
})

DiagSection:Button({
    Title = 'target latest capture',
    Callback = function()
        CapturedTargetIndex = nil
        local entry, index = currentCapturedEntry()
        if entry then
            notify(('Targeting #%d (latest): %s'):format(index, entry.fullName), 'success', 6)
        else
            notify('Nothing captured yet.', 'warning', 6)
        end
    end,
})

DiagSection:Paragraph({
    Title = 'where does the hash come from',
    Text = 'The hash is not necessarily pure noise - it could be derived from something else in the game (a JobId, a GUID stored as an attribute, anything). Searches every attribute on every instance in the game for an exact match to the most recently captured hash, plus a direct check against game.JobId. A match would reveal where the value actually comes from instead of treating it as unrecoverable.',
})

DiagSection:Button({
    Title = 'search game for targeted capture hash',
    Callback = function()
        local entry = currentCapturedEntry()
        if not entry then
            notify('Nothing captured yet - run Capture or Observe first.', 'warning', 6)
            return
        end
        if not entry.hash then
            notify('Last captured call had no hash-shaped name to search for.', 'warning', 6)
            return
        end

        notify(('Searching the game for "%s"... this can take a moment.'):format(entry.hash), 'warning', 6)

        task.spawn(function()
            local jobIdMatch = game.JobId == entry.hash
            local matches, scanned = searchGameForValue(entry.hash)

            log(("search: scanned %d instances for %s, %d attribute match(es), JobId match=%s")
                :format(scanned, entry.hash, #matches, tostring(jobIdMatch)))

            if jobIdMatch then
                notify('Matched game.JobId exactly - the hash is (or is derived from) the server JobId.', 'success', 10)
                return
            end

            if #matches == 0 then
                notify(('No attribute anywhere in the game matched - scanned %d instances.'):format(scanned), 'warning', 8)
                return
            end

            local text = table.concat(matches, "\n")
            local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
            notify(copied
                and ('%d match(es) found - copied to clipboard.'):format(#matches)
                or ('%d match(es) found - see %s'):format(#matches, LOG_PATH),
                'success', 9)
        end)
    end,
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
        setLiveRemoteLogging(false)
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        pcall(function() IndicatorGui:Destroy() end)
        Centrl:Unload()
    end,
})

local RemoteTab = Window:Tab({ Title = 'remotes', Icon = 'radio' })
local LiveSection = RemoteTab:Section({ Title = 'live capture', Side = 'left' })

local function randomFlag(prefix)
    local ok, guid = pcall(function()
        return game:GetService("HttpService"):GenerateGUID(false)
    end)
    return prefix .. "_" .. (ok and guid or tostring(math.random(1, 2 ^ 31)))
end

LiveSection:Toggle({
    Title = 'log remotes live',
    Flag = randomFlag('bb_live_remote'),
    Default = false,
    Callback = function(value)
        setLiveRemoteLogging(value)
    end,
})

LiveSection:Paragraph({
    Title = 'always on, never remembered',
    Text = 'Hooks __namecall for as long as this stays on, logging every FireServer/Fire/InvokeServer call seen to file and into the same capture list FireCaptured reads from - no fixed window, so it can be left running while your paid script (or your own real presses) does the real work. Its Flag is a fresh random UUID every time this loads, so this toggle never restores a saved state across reloads - if leaving it on ever caused a kick, it will not silently turn itself back on next time.',
})

local ConsoleSection = RemoteTab:Section({ Title = 'log', Side = 'right' })

remoteConsole = ConsoleSection:Console({
    Title = 'captured calls',
    Height = 260,
    MaxLines = 200,
    Timestamps = true,
})

ConsoleSection:Button({
    Title = 'clear log',
    Callback = function()
        if remoteConsole then remoteConsole:Clear() end
    end,
})

Window:Load()

Stats.Budget = Config.PressBudget
log("loaded")
notify('Loaded in Indicator mode - it only shows you when to press.', 'success', 7)

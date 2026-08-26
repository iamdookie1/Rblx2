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
local methodStat
local blockStat
local targetStat
local distStat
local etaStat
local logConsole
local EnabledToggle

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local Config = {
    Enabled = false,
    Method = "Auto",
    Lead = 0.38,
    SpeedLead = 0.12,
    PingFactor = 1.0,
    MaxDistance = 160,
    Cooldown = 0.2,
}

local Fires = 0
local CooldownUntil = 0
local FireMethod = "none"

local Blocked = "off"
local LiveTarget = "-"
local LiveDistance = 0
local LiveClosing = 0
local LiveEta = 0
local LiveLead = 0

local CapturedInput = nil
local ParryButton = nil

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

local GameUIS = nil
pcall(function()
    local module = ReplicatedStorage:FindFirstChild("UserInputService")
    if module and module:IsA("ModuleScript") then
        GameUIS = require(module)
    end
end)

local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
local ParryButtonPress = RemotesFolder and RemotesFolder:FindFirstChild("ParryButtonPress")

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

local function say(text, color)
    log(text)
    if logConsole then logConsole:Add(text, color) end
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

local function isPressLikeInput(inputType)
    return inputType == Enum.UserInputType.MouseButton1
        or inputType == Enum.UserInputType.MouseButton2
        or inputType == Enum.UserInputType.Touch
end

track(UserInputService.InputBegan:Connect(function(input)
    if isPressLikeInput(input.UserInputType) or input.KeyCode == Enum.KeyCode.F then
        if not CapturedInput then
            say("captured a real input to replay: " .. tostring(input.UserInputType),
                Color3.fromRGB(126, 217, 87))
        end
        CapturedInput = input
    end
end))

local PARRY_BUTTON_NAMES = { block = true, parry = true }
local boundButtons = setmetatable({}, { __mode = "k" })

local function noteParryButton(instance)
    if boundButtons[instance] then return end
    if not instance:IsA("GuiButton") then return end
    if not PARRY_BUTTON_NAMES[instance.Name:lower()] then return end
    boundButtons[instance] = true
    if not ParryButton or instance.Name:lower() == "block" then
        ParryButton = instance
        say("found parry button: " .. instance:GetFullName())
    end
end

task.spawn(function()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 20)
    if not playerGui then return end
    for _, descendant in ipairs(playerGui:GetDescendants()) do
        pcall(noteParryButton, descendant)
    end
    track(playerGui.DescendantAdded:Connect(function(descendant)
        pcall(noteParryButton, descendant)
    end))
end)

local function fireGameUIS()
    if not GameUIS then return false, "no game UIS module" end
    if not CapturedInput then return false, "press parry once first" end

    local okSignal, signal = pcall(function() return GameUIS.InputBegan end)
    if not okSignal or not signal then return false, "module has no InputBegan" end

    if pcall(function() signal:Fire(CapturedInput, false) end) then
        return true, "gameUIS:Fire"
    end

    if typeof(firesignal) == "function" and pcall(firesignal, signal, CapturedInput, false) then
        return true, "gameUIS:firesignal"
    end

    if typeof(getconnections) == "function" then
        local okConn, connections = pcall(getconnections, signal)
        if okConn and typeof(connections) == "table" and #connections > 0 then
            local any = false
            for _, connection in ipairs(connections) do
                if pcall(function() connection:Fire(CapturedInput, false) end) then any = true end
            end
            if any then return true, "gameUIS:connections" end
        end
    end

    return false, "gameUIS had no usable signal"
end

local function fireRealUIS()
    if not CapturedInput then return false, "press parry once first" end
    if typeof(getconnections) ~= "function" then return false, "no getconnections" end

    local okConn, connections = pcall(getconnections, UserInputService.InputBegan)
    if not okConn or typeof(connections) ~= "table" then return false, "getconnections failed" end

    local any = 0
    for _, connection in ipairs(connections) do
        local okFn, fn = pcall(function() return connection.Function end)
        if okFn and typeof(fn) == "function" then
            if pcall(function() connection:Fire(CapturedInput, false) end) then
                any = any + 1
            end
        end
    end

    if any > 0 then return true, ("realUIS:%d handlers"):format(any) end
    return false, "no unlocked handlers on real UIS"
end

local BUTTON_SIGNALS = { "Activated", "MouseButton1Click", "MouseButton1Down" }

local function fireButton()
    local button = ParryButton
    if not button or not button.Parent then return false, "no parry button found" end

    if typeof(firesignal) == "function" then
        for _, signalName in ipairs(BUTTON_SIGNALS) do
            local okSignal, signal = pcall(function() return button[signalName] end)
            if okSignal and signal and pcall(firesignal, signal) then
                return true, "button:firesignal:" .. signalName
            end
        end
    end

    if typeof(getconnections) == "function" then
        for _, signalName in ipairs(BUTTON_SIGNALS) do
            local okSignal, signal = pcall(function() return button[signalName] end)
            if okSignal and signal then
                local okConn, connections = pcall(getconnections, signal)
                if okConn and typeof(connections) == "table" and #connections > 0 then
                    local any = false
                    for _, connection in ipairs(connections) do
                        if pcall(function() connection:Fire() end) then any = true end
                    end
                    if any then return true, "button:connections:" .. signalName end
                end
            end
        end
    end

    return false, "button had no usable signal"
end

local function pickFunction(globalName, debugName)
    local fn = nil
    pcall(function()
        local candidate = rawget(getfenv(0), globalName)
        if typeof(candidate) == "function" then fn = candidate end
    end)
    if fn then return fn end
    pcall(function()
        local candidate = debug and debug[debugName]
        if typeof(candidate) == "function" then fn = candidate end
    end)
    return fn
end

local getUpvalues = pickFunction("getupvalues", "getupvalues")
local getConstants = pickFunction("getconstants", "getconstants")
local getProtos = pickFunction("getprotos", "getprotos")
local getGc = pickFunction("getgc", "getgc")

local INSPECT_PATH = "BladeBallInspect.txt"
local PARRY_WORDS = { "parry", "block", "deflect", "swing", "slash" }

local function shortValue(value)
    local kind = typeof(value)
    if kind == "Instance" then
        local ok, full = pcall(function() return value:GetFullName() end)
        return "Instance(" .. (ok and full or value.ClassName) .. ")"
    end
    if kind == "string" then
        if #value > 120 then return ('string("%s...")'):format(value:sub(1, 120)) end
        return ('string("%s")'):format(value)
    end
    if kind == "table" then
        local count = 0
        pcall(function() for _ in pairs(value) do count = count + 1 end end)
        return ("table(%d keys)"):format(count)
    end
    if kind == "function" then
        local ok, source = pcall(debug.info, value, "s")
        return "function(" .. (ok and tostring(source) or "?") .. ")"
    end
    return kind .. "(" .. tostring(value) .. ")"
end

local function looksInteresting(text)
    local lowered = text:lower()
    for _, word in ipairs(PARRY_WORDS) do
        if lowered:find(word, 1, true) then return true end
    end
    return false
end

local function deliverDump(lines, label)
    local text = table.concat(lines, "\n")
    if canWrite then pcall(writefile, INSPECT_PATH, text) end
    local copied = typeof(setclipboard) == "function" and pcall(setclipboard, text)
    say(("%s: %d lines%s"):format(label, #lines,
        copied and " - copied to clipboard" or (" - see " .. INSPECT_PATH)),
        Color3.fromRGB(126, 217, 87))
end

local function inspectFunction(fn, lines, label)
    lines[#lines + 1] = "== " .. label .. " =="

    local okInfo, source, line, name = pcall(debug.info, fn, "sln")
    if okInfo then
        lines[#lines + 1] = ("  source=%s line=%s name=%s")
            :format(tostring(source), tostring(line), tostring(name))
    end

    if getUpvalues then
        local ok, ups = pcall(getUpvalues, fn)
        if ok and typeof(ups) == "table" then
            lines[#lines + 1] = "  -- upvalues --"
            for index, value in pairs(ups) do
                lines[#lines + 1] = ("    [%s] %s"):format(tostring(index), shortValue(value))
            end
        end
    else
        lines[#lines + 1] = "  (no getupvalues on this executor)"
    end

    if getConstants then
        local ok, consts = pcall(getConstants, fn)
        if ok and typeof(consts) == "table" then
            lines[#lines + 1] = "  -- constants --"
            for index, value in pairs(consts) do
                lines[#lines + 1] = ("    [%s] %s"):format(tostring(index), shortValue(value))
            end
        end
    else
        lines[#lines + 1] = "  (no getconstants on this executor)"
    end

    if getProtos then
        local ok, protos = pcall(getProtos, fn)
        if ok and typeof(protos) == "table" then
            lines[#lines + 1] = ("  -- %d nested function(s) --"):format(#protos)
        end
    end
end

local function inspectInputHandlers()
    local lines = {}
    lines[#lines + 1] = "InputBegan handler inspection"

    if typeof(getconnections) ~= "function" then
        say("no getconnections on this executor", Color3.fromRGB(255, 120, 120))
        return
    end

    local okConn, connections = pcall(getconnections, UserInputService.InputBegan)
    if not okConn or typeof(connections) ~= "table" then
        say("getconnections failed", Color3.fromRGB(255, 120, 120))
        return
    end

    lines[#lines + 1] = ("%d connection(s) total"):format(#connections)

    local inspected = 0
    for index, connection in ipairs(connections) do
        local okFn, fn = pcall(function() return connection.Function end)
        if okFn and typeof(fn) == "function" then
            inspected = inspected + 1
            inspectFunction(fn, lines, ("connection #%d"):format(index))
        end
    end

    lines[#lines + 1] = ("%d were readable Luau closures"):format(inspected)
    deliverDump(lines, "input handlers")
end

local function dumpTable(value, lines, prefix, depth, seen)
    if depth > 2 then return end
    seen = seen or {}
    if seen[value] then
        lines[#lines + 1] = prefix .. "(already shown)"
        return
    end
    seen[value] = true

    local keys = {}
    pcall(function()
        for key in pairs(value) do keys[#keys + 1] = key end
    end)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    for _, key in ipairs(keys) do
        local ok, entry = pcall(function() return value[key] end)
        if ok then
            lines[#lines + 1] = ("%s%s = %s"):format(prefix, tostring(key), shortValue(entry))
            if typeof(entry) == "table" and depth < 2 then
                dumpTable(entry, lines, prefix .. "  ", depth + 1, seen)
            end
        end
    end

    local okMeta, meta = pcall(getmetatable, value)
    if okMeta and typeof(meta) == "table" and depth < 2 then
        lines[#lines + 1] = prefix .. "-- metatable --"
        dumpTable(meta, lines, prefix .. "  ", depth + 1, seen)
    end
end

local function findControllerModule(namePart)
    local controllers = ReplicatedStorage:FindFirstChild("Controllers")
    if not controllers then return nil end
    for _, child in ipairs(controllers:GetChildren()) do
        if child:IsA("ModuleScript") and child.Name:lower():find(namePart, 1, true) then
            return child
        end
    end
    return nil
end

local function dumpModule(module, label)
    if not module then
        say(label .. ": not found", Color3.fromRGB(255, 120, 120))
        return
    end

    local ok, result = pcall(require, module)
    if not ok then
        say(label .. ": require failed - " .. tostring(result), Color3.fromRGB(255, 120, 120))
        return
    end

    local lines = {}
    lines[#lines + 1] = label .. " -> " .. module:GetFullName()
    lines[#lines + 1] = "returned " .. typeof(result)

    if typeof(result) == "table" then
        dumpTable(result, lines, "  ", 0, nil)
    else
        lines[#lines + 1] = "  " .. shortValue(result)
    end

    deliverDump(lines, label)
end

local function scanGarbageCollector()
    if not getGc then
        say("no getgc on this executor", Color3.fromRGB(255, 120, 120))
        return
    end

    say("scanning memory, this takes a moment...", Color3.fromRGB(255, 180, 70))

    task.spawn(function()
        local lines = {}
        lines[#lines + 1] = "garbage collector scan"

        local ok, objects = pcall(getGc, true)
        if not ok or typeof(objects) ~= "table" then
            say("getgc failed", Color3.fromRGB(255, 120, 120))
            return
        end

        local scanned = 0
        local hits = 0

        for _, object in pairs(objects) do
            scanned = scanned + 1
            if scanned % 2000 == 0 then task.wait() end
            if hits >= 60 then break end

            local kind = typeof(object)

            if kind == "table" then
                pcall(function()
                    for key, value in pairs(object) do
                        if typeof(key) == "string" and looksInteresting(key) then
                            hits = hits + 1
                            lines[#lines + 1] = ("table key %s = %s"):format(key, shortValue(value))
                            break
                        end
                    end
                end)
            elseif kind == "function" and getConstants then
                pcall(function()
                    local okConst, consts = pcall(getConstants, object)
                    if okConst and typeof(consts) == "table" then
                        for _, value in pairs(consts) do
                            if typeof(value) == "string" and looksInteresting(value) then
                                hits = hits + 1
                                local okSrc, source = pcall(debug.info, object, "s")
                                lines[#lines + 1] = ("function const %q in %s")
                                    :format(value:sub(1, 80), okSrc and tostring(source) or "?")
                                break
                            end
                        end
                    end
                end)
            end
        end

        lines[#lines + 1] = ("scanned %d objects, %d hit(s)"):format(scanned, hits)
        deliverDump(lines, "gc scan")
    end)
end

local GuiService = game:GetService("GuiService")
local TOUCH_ID = 87

local function buttonScreenPoint(button)
    local okPos, centre = pcall(function()
        return button.AbsolutePosition + button.AbsoluteSize * 0.5
    end)
    if not okPos then return nil end

    local ignoresInset = false
    pcall(function()
        local ancestor = button
        while ancestor do
            if ancestor:IsA("ScreenGui") then
                ignoresInset = ancestor.IgnoreGuiInset
                break
            end
            ancestor = ancestor.Parent
        end
    end)

    if ignoresInset then
        return centre.X, centre.Y
    end

    local okInset, inset = pcall(function() return GuiService:GetGuiInset() end)
    if okInset and inset then
        return centre.X + inset.X, centre.Y + inset.Y
    end
    return centre.X, centre.Y
end

local function fireTouch()
    local button = ParryButton
    if not button or not button.Parent then return false, "no parry button found" end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if typeof(vim) ~= "Instance" then return false, "no VirtualInputManager" end

    local x, y = buttonScreenPoint(button)
    if not x then return false, "could not read button position" end

    local ok = pcall(function()
        vim:SendTouchEvent(TOUCH_ID, 0, x, y)
    end)
    if not ok then return false, "SendTouchEvent begin failed" end

    task.delay(0.05, function()
        pcall(function() vim:SendTouchEvent(TOUCH_ID, 2, x, y) end)
    end)

    return true, ("touch:%d,%d"):format(math.floor(x), math.floor(y))
end

local function fireBindable()
    if not ParryButtonPress then return false, "ParryButtonPress not found" end
    local ok = pcall(function() ParryButtonPress:Fire() end)
    if ok then return true, "bindable:ParryButtonPress" end
    return false, "ParryButtonPress:Fire failed"
end

local Methods = {
    Bindable = fireBindable,
    GameUIS = fireGameUIS,
    RealUIS = fireRealUIS,
    Button = fireButton,
    Touch = fireTouch,
}

local AUTO_ORDER = { "Bindable", "GameUIS", "RealUIS", "Button" }

local function doFire()
    if Config.Method ~= "Auto" then
        local fn = Methods[Config.Method]
        if not fn then return false, "unknown method" end
        return fn()
    end

    local lastWhy = "nothing available"
    for _, name in ipairs(AUTO_ORDER) do
        local ok, why = Methods[name]()
        if ok then return true, why end
        lastWhy = why
    end
    return false, lastWhy
end

local function fireParry()
    CooldownUntil = os.clock() + Config.Cooldown

    task.spawn(function()
        local ok, why = doFire()
        if ok then
            Fires = Fires + 1
            if FireMethod ~= why then
                say("firing via " .. why, Color3.fromRGB(126, 217, 87))
            end
            FireMethod = why
        else
            if FireMethod ~= why then
                say("could not fire: " .. tostring(why), Color3.fromRGB(255, 120, 120))
            end
            FireMethod = why
        end
    end)
end

track(PreSimulation:Connect(function()
    if Unloading then return end
    if not Config.Enabled then Blocked = "off" return end

    local ball, isTraining = realBall()
    if not ball then
        Blocked = BallsFolder and "no ball in folder" or "no Balls folder"
        LiveTarget, LiveDistance, LiveEta = "-", 0, 0
        return
    end

    local root = getRoot()
    if not root then Blocked = "no character" return end

    local targetAttr = ball:GetAttribute("target")
    LiveTarget = isTraining and "(training)" or tostring(targetAttr)

    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    LiveDistance = distance

    local closing = 0
    if distance >= 0.01 then
        closing = ball.AssemblyLinearVelocity:Dot(offset.Unit)
    end
    LiveClosing = closing

    local eta = (closing > 1) and (distance / closing) or math.huge
    LiveEta = eta

    local ping = 0
    if PingModule then
        ping = PingModule:GetAttribute("LocalPlayerPing") or 0
    end

    local lead = Config.Lead
        + (ping * 0.5 * Config.PingFactor)
        + math.clamp(closing / 1000, 0, 1) * Config.SpeedLead
    LiveLead = lead

    if isTraining then
        if not isAlive() then Blocked = "dead" return end
    else
        if not isPlaying() then Blocked = "not in Alive folder" return end
        if targetAttr ~= LocalPlayer.Name then Blocked = "not my ball" return end
    end

    if os.clock() < CooldownUntil then Blocked = "cooldown" return end
    if distance > Config.MaxDistance then Blocked = "too far" return end
    if closing <= 1 then Blocked = "not closing" return end
    if eta > lead then Blocked = "waiting for lead" return end

    Blocked = "FIRING"
    fireParry()
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
methodStat = MainSection:Stat({ Title = 'firing via', Value = 'nothing yet' })

EnabledToggle = MainSection:Toggle({
    Title = 'auto parry',
    Flag = 'bb_auto_parry',
    Default = false,
    Callback = function(value)
        Config.Enabled = value
        log(value and "auto parry ON" or "auto parry OFF")
        if value and not ParryButtonPress and not CapturedInput then
            notify('Press parry once yourself so it has a real input to replay.', 'warning', 9)
        end
    end,
})

MainSection:Dropdown({
    Title = 'method',
    Flag = 'bb_method',
    Options = { 'Auto', 'Bindable', 'GameUIS', 'RealUIS', 'Button', 'Touch' },
    Default = 'Auto',
    Callback = function(value)
        Config.Method = value
        FireMethod = "none"
        log("method set to " .. value)
    end,
})

MainSection:Paragraph({
    Title = 'the methods',
    Text = 'Bindable fires ReplicatedStorage.Remotes.ParryButtonPress, a BindableEvent - the game\'s own internal "the parry button was pressed" signal, sitting among others like M1Stop and ResetFOV that its scripts Fire on themselves. Nothing leaves the client and there is no server call at all, so it is the closest thing to the game telling itself you pressed parry. GameUIS pushes your captured input through ReplicatedStorage.UserInputService, a custom module the game uses instead of the real service. RealUIS fires the unlocked handlers on the real UserInputService.InputBegan. Button presses the Hotbar Block ImageButton. Auto tries them in that order.',
})

MainSection:Paragraph({
    Title = 'Touch - a real tap, aimed properly',
    Text = 'Not in Auto, pick it deliberately. It sends a genuine touch at the Block button\'s own screen position, worked out from AbsolutePosition plus half its size and corrected for the GUI inset, so it lands on the button rather than wherever the screen centre happens to be. It uses touch id 87 rather than 1, so it cannot collide with the fingers you are actually using - the old version reused the same id as your real touches, which is what made it fight your input. Begin and end are sent 0.05s apart so it reads as a tap. This is the only method here that goes through VirtualInputManager, so it is also the one an anti-cheat is most likely to notice.',
})

local LiveSection = MainTab:Section({ Title = 'live', Side = 'left' })
blockStat = LiveSection:Stat({ Title = 'why not firing', Value = 'off' })
targetStat = LiveSection:Stat({ Title = 'ball target', Value = '-' })
distStat = LiveSection:Stat({ Title = 'distance', Value = '-' })
etaStat = LiveSection:Stat({ Title = 'eta / lead', Value = '-' })

local TuningSection = MainTab:Section({ Title = 'timing', Side = 'right' })

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

TuningSection:Slider({
    Title = 'cooldown',
    Flag = 'bb_cooldown',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = 0.2,
    Suffix = 's',
    Callback = function(value) Config.Cooldown = value end,
})

local LogSection = MainTab:Section({ Title = 'log', Side = 'right' })

logConsole = LogSection:Console({
    Title = 'what it is doing',
    Height = 200,
    MaxLines = 100,
    Timestamps = true,
})

LogSection:Button({
    Title = 'test fire now',
    Callback = function()
        local ok, why = doFire()
        say(ok and ("test fire ok: " .. why) or ("test fire failed: " .. tostring(why)),
            ok and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 120, 120))
    end,
})

LogSection:Button({
    Title = 'clear log',
    Callback = function()
        if logConsole then logConsole:Clear() end
    end,
})

local InspectTab = Window:Tab({ Title = 'inspect', Icon = 'search' })
local InspectSection = InspectTab:Section({ Title = 'read the VM', Side = 'left' })

InspectSection:Paragraph({
    Title = 'why this instead of another method',
    Text = 'Every firing method reports success and nothing happens, so the parry is not reachable from any entrance we can find. This stops trying to send it and reads what the VM already holds instead. Inspect handlers dumps the upvalues, constants and nested functions of every readable Luau closure on UserInputService.InputBegan - two of those had scrambled Luraph source names, which is where the sword controller appeared to sit, and their upvalues are its live state. Scan memory walks every table and function alive and reports anything whose keys or string constants mention parry, block, deflect, swing or slash. Both are read only: nothing is fired, nothing is sent.',
})

InspectSection:Button({
    Title = 'inspect InputBegan handlers',
    Callback = function()
        task.spawn(inspectInputHandlers)
    end,
})

InspectSection:Button({
    Title = 'dump custom UserInputService',
    Callback = function()
        task.spawn(function()
            dumpModule(ReplicatedStorage:FindFirstChild("UserInputService"), "custom UIS")
        end)
    end,
})

InspectSection:Button({
    Title = 'dump SwordsController',
    Callback = function()
        task.spawn(function()
            dumpModule(findControllerModule("swordscontroller"), "SwordsController")
        end)
    end,
})

InspectSection:Button({
    Title = 'list Controllers',
    Callback = function()
        local controllers = ReplicatedStorage:FindFirstChild("Controllers")
        if not controllers then
            say("no Controllers folder", Color3.fromRGB(255, 120, 120))
            return
        end
        local lines = { "Controllers children" }
        for _, child in ipairs(controllers:GetChildren()) do
            local raw = child.Name
            local cleaned = raw:gsub("%c", function(c)
                return ("\\%d"):format(c:byte())
            end)
            lines[#lines + 1] = ("%s | %q"):format(child.ClassName, cleaned)
        end
        deliverDump(lines, "controllers")
    end,
})

InspectSection:Button({
    Title = 'scan memory for parry',
    Callback = scanGarbageCollector,
})

InspectSection:Button({
    Title = 'what this executor supports',
    Callback = function()
        local parts = {
            "getconnections=" .. tostring(typeof(getconnections) == "function"),
            "getupvalues=" .. tostring(getUpvalues ~= nil),
            "getconstants=" .. tostring(getConstants ~= nil),
            "getprotos=" .. tostring(getProtos ~= nil),
            "getgc=" .. tostring(getGc ~= nil),
            "firesignal=" .. tostring(typeof(firesignal) == "function"),
        }
        say(table.concat(parts, "  "), Color3.fromRGB(126, 217, 87))
    end,
})

local InspectLogSection = InspectTab:Section({ Title = 'notes', Side = 'right' })

InspectLogSection:Paragraph({
    Title = 'what to look for',
    Text = 'In the handler dump, an upvalue printed as Instance(...) pointing at something under Packages._Index.sleitnick_net is the remote the controller captured for itself - that is the one worth firing. A constant that reads as a plain string naming a remote is just as good. In the gc scan, a table key like Parry or Block whose value is a function is a callable entry point. Paste whatever comes out and it can be turned into a real method.',
})

local ControlSection = MainTab:Section({ Title = 'control', Side = 'right' })

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

task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            if not Config.Enabled then
                statusStat:Set('off')
            elseif ParryButtonPress or CapturedInput then
                statusStat:Set(('armed - %d fired'):format(Fires), Color3.fromRGB(126, 217, 87))
            else
                statusStat:Set('press parry once to arm', Color3.fromRGB(255, 180, 70))
            end

            methodStat:Set(FireMethod)
            blockStat:Set(Blocked, Blocked == "FIRING" and Color3.fromRGB(126, 217, 87) or nil)
            targetStat:Set(LiveTarget == LocalPlayer.Name and (LiveTarget .. '  (YOU)') or LiveTarget,
                LiveTarget == LocalPlayer.Name and Color3.fromRGB(255, 90, 90) or nil)
            distStat:Set(('%.1f studs @ %.0f/s'):format(LiveDistance, LiveClosing))
            etaStat:Set(LiveEta == math.huge
                and ('- / %.2fs'):format(LiveLead)
                or ('%.3fs / %.2fs'):format(LiveEta, LiveLead))
        end)
    end
end)

Window:Load()
log("loaded")
say(GameUIS and "found the game's custom UserInputService module"
    or "no custom UserInputService module found")

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

local function pickFunction(...)
    local names = { ... }

    for _, name in ipairs(names) do
        local fn = nil

        pcall(function()
            if typeof(getgenv) == "function" then
                local candidate = getgenv()[name]
                if typeof(candidate) == "function" then fn = candidate end
            end
        end)
        if fn then return fn end

        pcall(function()
            local candidate = getfenv(0)[name]
            if typeof(candidate) == "function" then fn = candidate end
        end)
        if fn then return fn end

        pcall(function()
            local candidate = debug and debug[name]
            if typeof(candidate) == "function" then fn = candidate end
        end)
        if fn then return fn end
    end

    return nil
end

local getUpvalues = pickFunction("getupvalues", "debug_getupvalues")
local getConstants = pickFunction("getconstants", "debug_getconstants")
local getProtos = pickFunction("getprotos", "debug_getprotos")
local getGc = pickFunction("getgc", "get_gc_objects", "getgarbagecollector")

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
    local wanted = namePart:lower():gsub("%s+", "")
    for _, descendant in ipairs(controllers:GetDescendants()) do
        if descendant:IsA("ModuleScript") then
            local cleaned = descendant.Name:lower():gsub("%c", ""):gsub("%s+", "")
            if cleaned:find(wanted, 1, true) then
                return descendant
            end
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

local function scanBySource(sourceQuery)
    if not getGc then
        say("no getgc on this executor", Color3.fromRGB(255, 120, 120))
        return
    end

    local wanted = sourceQuery:lower():gsub("%s+", "")
    say("looking for functions from " .. sourceQuery .. "...", Color3.fromRGB(255, 180, 70))

    task.spawn(function()
        local lines = {}
        lines[#lines + 1] = "functions whose chunk matches " .. sourceQuery

        local ok, objects = pcall(getGc, true)
        if not ok or typeof(objects) ~= "table" then
            say("getgc failed", Color3.fromRGB(255, 120, 120))
            return
        end

        local scanned, found = 0, 0
        local seenUpvalues = {}

        for _, object in pairs(objects) do
            scanned = scanned + 1
            if scanned % 2000 == 0 then task.wait() end
            if found >= 25 then break end

            if typeof(object) == "function" then
                local okSrc, source = pcall(debug.info, object, "s")
                if okSrc and typeof(source) == "string" then
                    local cleaned = source:lower():gsub("%c", ""):gsub("%s+", "")
                    if cleaned:find(wanted, 1, true) then
                        found = found + 1
                        local okLine, line = pcall(debug.info, object, "l")
                        lines[#lines + 1] = ("== %s line %s =="):format(source, okLine and tostring(line) or "?")

                        if getUpvalues then
                            local okUp, ups = pcall(getUpvalues, object)
                            if okUp and typeof(ups) == "table" then
                                for index, value in pairs(ups) do
                                    local rendered = shortValue(value)
                                    local key = tostring(index) .. rendered
                                    if not seenUpvalues[key] then
                                        seenUpvalues[key] = true
                                        lines[#lines + 1] = ("    up[%s] %s"):format(tostring(index), rendered)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        lines[#lines + 1] = ("scanned %d objects, %d matching function(s)"):format(scanned, found)
        deliverDump(lines, "source scan")
    end)
end

local FoundRemotes = {}

local function isRemoteInstance(value)
    if typeof(value) ~= "Instance" then return false end
    local ok, result = pcall(function()
        return value:IsA("RemoteEvent") or value:IsA("RemoteFunction")
            or value:IsA("UnreliableRemoteEvent") or value:IsA("BindableEvent")
    end)
    return ok and result
end

local function noteFoundRemote(instance, where, lines, seen)
    if seen[instance] then return end
    seen[instance] = true

    local okName, fullName = pcall(function() return instance:GetFullName() end)
    if not okName then return end

    FoundRemotes[#FoundRemotes + 1] = {
        instance = instance,
        className = instance.ClassName,
        fullName = fullName,
    }
    lines[#lines + 1] = ("[%d] %s %s"):format(#FoundRemotes, instance.ClassName, fullName)
    lines[#lines + 1] = ("      held by %s"):format(where)
end

local captureHookInstalled = false
local captureOriginal = nil
local capturing = false
local watching = false
local captureQueue = {}
local CAPTURE_QUEUE_LIMIT = 400

local WATCH_METHODS = {
    FireServer = true,
    InvokeServer = true,
    Fire = true,
    Invoke = true,
    SendTouchEvent = true,
    SendMouseButtonEvent = true,
    SendKeyEvent = true,
    SendMouseMoveEvent = true,
    Play = true,
    Stop = true,
    AdjustSpeed = true,
    LoadAnimation = true,
    BindAction = true,
    BindActionAtPriority = true,
    CallFunction = true,
}

local function installCaptureHook()
    if captureHookInstalled then return true end

    local hookMeta = pickFunction("hookmetamethod")
    local getNamecall = pickFunction("getnamecallmethod")
    if not hookMeta or not getNamecall then return false end

    local ok = pcall(function()
        local body = function(self, ...)
            if (capturing or watching) and typeof(self) == "Instance"
                and #captureQueue < CAPTURE_QUEUE_LIMIT then

                local okMethod, method = pcall(getNamecall)
                if okMethod then
                    local wanted = watching
                        and WATCH_METHODS[method]
                        or (method == "FireServer" or method == "InvokeServer")

                    if wanted then
                        local caller = "?"
                        if watching then
                            pcall(function() caller = tostring(debug.info(2, "s")) end)
                        end

                        captureQueue[#captureQueue + 1] = {
                            instance = self,
                            method = method,
                            at = os.clock(),
                            caller = caller,
                        }
                    end
                end
            end
            return captureOriginal(self, ...)
        end

        local newC = pickFunction("newcclosure")
        captureOriginal = hookMeta(game, "__namecall", newC and newC(body) or body)
    end)

    if not ok or not captureOriginal then
        captureOriginal = nil
        return false
    end

    captureHookInstalled = true
    return true
end

local function watchEverything(duration)
    if watching or capturing then
        say("already running", Color3.fromRGB(255, 180, 70))
        return
    end

    if not installCaptureHook() then
        say("could not install hook", Color3.fromRGB(255, 120, 120))
        return
    end

    table.clear(captureQueue)
    table.clear(FoundRemotes)
    watching = true

    say(("watching everything for %ds - let the paid script parry NOW"):format(duration),
        Color3.fromRGB(255, 210, 80))

    task.spawn(function()
        local started = os.clock()
        local lines = { "everything called during the window" }
        local records = {}

        while os.clock() - started < duration do
            while #captureQueue > 0 do
                local item = table.remove(captureQueue, 1)
                local okName, fullName = pcall(function() return item.instance:GetFullName() end)
                records[#records + 1] = {
                    method = item.method,
                    fullName = okName and fullName or "?",
                    className = item.instance.ClassName,
                    caller = item.caller,
                    offset = item.at - started,
                    instance = item.instance,
                }
            end
            task.wait(0.03)
        end

        watching = false

        local byCaller = {}
        for _, record in ipairs(records) do
            byCaller[record.caller] = (byCaller[record.caller] or 0) + 1
        end

        lines[#lines + 1] = "-- callers seen --"
        for caller, count in pairs(byCaller) do
            lines[#lines + 1] = ("  %d call(s) from %s"):format(count, caller)
        end

        lines[#lines + 1] = "-- calls in order --"
        local seen = {}
        for _, record in ipairs(records) do
            lines[#lines + 1] = ("+%.3fs %s %s %s")
                :format(record.offset, record.method, record.className, record.fullName)
            lines[#lines + 1] = ("        from %s"):format(record.caller)

            if isRemoteInstance(record.instance) and not seen[record.instance] then
                seen[record.instance] = true
                FoundRemotes[#FoundRemotes + 1] = {
                    instance = record.instance,
                    className = record.className,
                    fullName = record.fullName,
                    method = record.method,
                }
            end
        end

        lines[#lines + 1] = ("%d call(s) total, %d distinct remote(s) kept")
            :format(#records, #FoundRemotes)
        deliverDump(lines, "watch")
        say(("watched %d call(s), kept %d remote(s)"):format(#records, #FoundRemotes),
            Color3.fromRGB(255, 210, 80))
    end)
end

local function captureDuringParry(duration)
    if capturing then
        say("already capturing", Color3.fromRGB(255, 180, 70))
        return
    end

    if not installCaptureHook() then
        say("could not install capture hook", Color3.fromRGB(255, 120, 120))
        return
    end

    table.clear(captureQueue)
    table.clear(FoundRemotes)
    capturing = true

    say(("capturing for %ds - PARRY NOW"):format(duration), Color3.fromRGB(255, 210, 80))

    task.spawn(function()
        local started = os.clock()
        local seen = {}
        local lines = { "captured during a real parry" }

        while os.clock() - started < duration do
            while #captureQueue > 0 do
                local item = table.remove(captureQueue, 1)
                local before = #FoundRemotes
                noteFoundRemote(item.instance, ("%s at +%.2fs"):format(item.method, item.at - started),
                    lines, seen)
                if #FoundRemotes > before then
                    local entry = FoundRemotes[#FoundRemotes]
                    entry.method = item.method
                    say(("[%d] %s %s (+%.2fs)"):format(#FoundRemotes, item.method,
                        entry.fullName:match("[^%.]+$") or entry.fullName, item.at - started),
                        Color3.fromRGB(126, 217, 87))
                end
            end
            task.wait(0.05)
        end

        capturing = false
        lines[#lines + 1] = ("%d distinct remote(s) captured"):format(#FoundRemotes)
        deliverDump(lines, "parry capture")
        say(("done - %d captured. Pick a number and fire it at a real ball."):format(#FoundRemotes),
            Color3.fromRGB(255, 210, 80))
    end)
end

local function huntRemotesInMemory()
    if not getGc then
        say("no getgc on this executor", Color3.fromRGB(255, 120, 120))
        return
    end

    say("hunting for remotes held in memory...", Color3.fromRGB(255, 180, 70))

    task.spawn(function()
        table.clear(FoundRemotes)

        local lines = { "remotes found held by live code" }
        local seen = {}

        local ok, objects = pcall(getGc, true)
        if not ok or typeof(objects) ~= "table" then
            say("getgc failed", Color3.fromRGB(255, 120, 120))
            return
        end

        local scanned = 0

        for _, object in pairs(objects) do
            scanned = scanned + 1
            if scanned % 1500 == 0 then task.wait() end
            if #FoundRemotes >= 80 then break end

            local kind = typeof(object)

            if kind == "function" and getUpvalues then
                pcall(function()
                    local okUp, ups = pcall(getUpvalues, object)
                    if okUp and typeof(ups) == "table" then
                        for _, value in pairs(ups) do
                            if isRemoteInstance(value) then
                                local okSrc, source = pcall(debug.info, object, "s")
                                noteFoundRemote(value,
                                    "upvalue of function in " .. (okSrc and tostring(source) or "?"),
                                    lines, seen)
                            end
                        end
                    end
                end)
            elseif kind == "table" then
                pcall(function()
                    for key, value in pairs(object) do
                        if isRemoteInstance(value) then
                            noteFoundRemote(value, "table field " .. tostring(key), lines, seen)
                        end
                    end
                end)
            end
        end

        lines[#lines + 1] = ("scanned %d objects, found %d remote(s)"):format(scanned, #FoundRemotes)
        deliverDump(lines, "remote hunt")
    end)
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

local moduleQuery = "InputController"

InspectSection:Textbox({
    Title = 'controller name',
    Flag = 'bb_module_query',
    Default = 'InputController',
    Placeholder = 'InputController',
    Callback = function(value)
        moduleQuery = value
    end,
})

InspectSection:Button({
    Title = 'dump that controller',
    Callback = function()
        task.spawn(function()
            local query = (moduleQuery or ""):lower():gsub("%s+", "")
            if query == "" then
                say("type a controller name first", Color3.fromRGB(255, 120, 120))
                return
            end
            dumpModule(findControllerModule(query), moduleQuery)
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
    Title = 'find functions from that script',
    Callback = function()
        local query = moduleQuery or ""
        if query:gsub("%s+", "") == "" then
            say("type a script name first", Color3.fromRGB(255, 120, 120))
            return
        end
        scanBySource(query)
    end,
})

InspectSection:Button({
    Title = 'watch paid script (6s)',
    Callback = function()
        watchEverything(6)
    end,
})

InspectSection:Paragraph({
    Title = 'copying what the paid script does',
    Text = 'Run the paid script with its auto parry on, press this, and let it parry. It records every remote fire, bindable fire, synthetic input, animation play and action bind seen in the window, and tags each one with the chunk that called it - so its calls are separated from the game\'s own. Whatever it does that a manual parry does not is the mechanism. Any remotes seen are kept in the numbered list so they can be fired straight afterwards.',
})

InspectSection:Button({
    Title = 'capture during real parry (4s)',
    Callback = function()
        captureDuringParry(4)
    end,
})

InspectSection:Paragraph({
    Title = 'the one test that never got a clean run',
    Text = 'Press capture, then parry for real within four seconds. Every FireServer and InvokeServer seen in that window is numbered, so the block call is in there even if the success report is too. Then stay in the same lobby, pick a number and fire it while a ball is coming at you. Names re-salt per lobby, so a captured remote is only valid until you leave. Nothing auto-selects and nothing fires on its own - the earlier attempts at this were ruined by a crash from restoring the hook, by auto-picking the success report, and by our own UI clicks counting as parries, all of which are gone.',
})

InspectSection:Button({
    Title = 'hunt remotes in memory',
    Callback = huntRemotesInMemory,
})

local remoteIndex = 1

InspectSection:Textbox({
    Title = 'found remote number',
    Flag = 'bb_remote_index',
    Default = '1',
    Placeholder = '1',
    Callback = function(value)
        remoteIndex = tonumber(value) or 1
    end,
})

InspectSection:Button({
    Title = 'fire that found remote',
    Callback = function()
        local entry = FoundRemotes[remoteIndex]
        if not entry then
            say(("no remote #%d - run the hunt first"):format(remoteIndex), Color3.fromRGB(255, 120, 120))
            return
        end

        task.spawn(function()
            local ok = pcall(function()
                if entry.method == "InvokeServer" or entry.className == "RemoteFunction" then
                    entry.instance:InvokeServer()
                elseif entry.className == "BindableEvent" then
                    entry.instance:Fire()
                else
                    entry.instance:FireServer()
                end
            end)
            say(("[%d] %s -> %s"):format(remoteIndex, entry.fullName, ok and "fired" or "failed"),
                ok and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 120, 120))
        end)
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
            "getconnections=" .. tostring(pickFunction("getconnections") ~= nil),
            "getupvalues=" .. tostring(getUpvalues ~= nil),
            "getconstants=" .. tostring(getConstants ~= nil),
            "getprotos=" .. tostring(getProtos ~= nil),
            "getgc=" .. tostring(getGc ~= nil),
            "firesignal=" .. tostring(pickFunction("firesignal") ~= nil),
            "getgenv=" .. tostring(typeof(getgenv) == "function"),
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

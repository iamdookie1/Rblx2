--// Dumper -----------------------------------------------------------------------
--
-- loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Tools/Dumper.lua'))()
--
-- Every option in the menu can also be set before loading, and AutoStart/NoUI
-- run it headless:
--
-- getgenv().DumperConfig = { Tree = false, Spy = true, SpySeconds = 30, AutoStart = true, NoUI = true }
--
-- Output lands in Dumper/<PlaceId>/ in the executor's workspace folder.

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local env = (typeof(getgenv) == "function" and getgenv()) or _G

local Has = {
    writefile = typeof(writefile) == "function",
    appendfile = typeof(appendfile) == "function",
    readfile = typeof(readfile) == "function",
    makefolder = typeof(makefolder) == "function",
    isfolder = typeof(isfolder) == "function",
    isfile = typeof(isfile) == "function",
    delfile = typeof(delfile) == "function",
    decompile = typeof(decompile) == "function",
    scripthash = typeof(getscripthash) == "function",
    nilinstances = typeof(getnilinstances) == "function",
    loadedmodules = typeof(getloadedmodules) == "function",
    runningscripts = typeof(getrunningscripts) == "function",
    hook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function",
    checkcaller = typeof(checkcaller) == "function",
}

local VERSION = "Dumper v5"
local SEP = string.rep("=", 80)

local ROOT_ORDER = {
    "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer",
    "StarterPack", "Players", "Lighting", "SoundService", "Teams", "Chat",
}

local Config = {
    Output = "Single file",
    Info = true,
    Scripts = true,
    Tree = true,
    Remotes = true,
    Values = true,
    Interactables = true,
    Hidden = true,
    Spy = false,
    SpySeconds = 20,
    Attributes = true,
    SkipDefaults = true,
    DedupeScripts = true,
    OnlyMyCharacter = true,
    OnlyMyPlayer = false,
    CollapseRepeats = true,
    SkipGuiValues = true,
    MaxDepth = 16,
    MaxScriptChars = 150000,
    DecompileTimeout = 10,
    Roots = { "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer",
        "StarterPack", "Players", "Lighting", "SoundService", "Teams" },
    AutoStart = false,
    NoUI = false,
}

if typeof(env.DumperConfig) == "table" then
    for key, value in pairs(env.DumperConfig) do
        if Config[key] ~= nil then Config[key] = value end
    end
end

-- Roblox's own player/chat scripts: identical in every game, and on the last
-- dump they were thousands of lines of the tree before anything game-specific.
local DEFAULT_SCRIPTS = {
    PlayerModule = true, PlayerScriptsLoader = true, RbxCharacterSounds = true,
    ChatScript = true, BubbleChat = true, ChatMain = true,
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
    BindableEvent = true, BindableFunction = true,
}

--// Serialising values --------------------------------------------------------------
local function fmt(n)
    if n == math.floor(n) and math.abs(n) < 1e15 then return tostring(n) end
    local text = ("%.3f"):format(n):gsub("0+$", ""):gsub("%.$", "")
    return text
end

local function serialize(value, depth)
    depth = depth or 0
    local kind = typeof(value)
    if kind == "string" then
        if #value > 200 then value = value:sub(1, 200) .. "..." end
        return ("%q"):format(value)
    elseif kind == "number" then
        return fmt(value)
    elseif kind == "boolean" or kind == "nil" then
        return tostring(value)
    elseif kind == "Instance" then
        local ok, name = pcall(function() return value:GetFullName() end)
        return "<" .. (ok and name or "?") .. ">"
    elseif kind == "Vector3" then
        return ("Vector3(%s, %s, %s)"):format(fmt(value.X), fmt(value.Y), fmt(value.Z))
    elseif kind == "Vector2" then
        return ("Vector2(%s, %s)"):format(fmt(value.X), fmt(value.Y))
    elseif kind == "CFrame" then
        local p = value.Position
        return ("CFrame(%s, %s, %s)"):format(fmt(p.X), fmt(p.Y), fmt(p.Z))
    elseif kind == "Color3" then
        return ("Color3(%d, %d, %d)"):format(
            math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5))
    elseif kind == "EnumItem" then
        return tostring(value)
    elseif kind == "table" then
        if depth >= 3 then return "{...}" end
        local parts, count = {}, 0
        for k, v in pairs(value) do
            count = count + 1
            if count > 12 then
                parts[#parts + 1] = "..."
                break
            end
            local key = typeof(k) == "string" and k or ("[" .. serialize(k, depth + 1) .. "]")
            parts[#parts + 1] = key .. " = " .. serialize(v, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    local ok, text = pcall(tostring, value)
    return kind .. "(" .. (ok and text or "?") .. ")"
end

local function attributesOf(inst)
    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if not ok or typeof(attrs) ~= "table" or next(attrs) == nil then return nil end
    local keys = {}
    for key in pairs(attrs) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. "=" .. serialize(attrs[key], 1)
    end
    local text = table.concat(parts, ", ")
    if #text > 300 then text = text:sub(1, 300) .. "..." end
    return text
end

--// Paths ----------------------------------------------------------------------------
-- The last game named every one of its 90 remotes plain "RemoteEvent", so a
-- full name alone pointed at nothing. Siblings that share a name get their
-- position appended - RemoteEvent[3] - which stays stable for the life of the
-- server and is what the spy log uses too, so the two can be matched up.
local siblingIndex = setmetatable({}, { __mode = "k" })

local function indexSiblings(parent, children)
    local counts, seen, map = {}, {}, {}
    for _, child in ipairs(children) do
        local ok, name = pcall(function() return child.Name end)
        if ok then counts[name] = (counts[name] or 0) + 1 end
    end
    for _, child in ipairs(children) do
        local ok, name = pcall(function() return child.Name end)
        if ok and counts[name] > 1 then
            seen[name] = (seen[name] or 0) + 1
            map[child] = seen[name]
        end
    end
    siblingIndex[parent] = map
    return map
end

local function segment(inst, map)
    local name = inst.Name
    local index = map and map[inst]
    return index and (name .. "[" .. index .. "]") or name
end

local function pathOf(inst)
    local parts = {}
    local current = inst
    while current and current ~= game do
        local parent = current.Parent
        if not parent then
            table.insert(parts, 1, current.Name)
            table.insert(parts, 1, "nil")
            break
        end
        local map = siblingIndex[parent]
        if not map then
            local ok, children = pcall(function() return parent:GetChildren() end)
            map = ok and indexSiblings(parent, children) or {}
        end
        table.insert(parts, 1, segment(current, map))
        current = parent
    end
    return table.concat(parts, ".")
end

--// Streaming file writer --------------------------------------------------------------
-- Buffers small chunks and flushes them as it goes, so a dump of a huge game
-- never sits in memory as one giant string.
local FileWriter = {}
FileWriter.__index = FileWriter

function FileWriter.new(path)
    local self = setmetatable({ path = path, buffer = {}, chars = 0 }, FileWriter)
    pcall(writefile, path, "")
    return self
end

function FileWriter:write(text)
    self.buffer[#self.buffer + 1] = text
    self.chars = self.chars + #text
    if self.chars >= 32768 then self:flush() end
end

function FileWriter:flush()
    if #self.buffer == 0 then return end
    local chunk = table.concat(self.buffer)
    self.buffer, self.chars = {}, 0
    if Has.appendfile then
        pcall(appendfile, self.path, chunk)
    elseif Has.readfile then
        local existing = ""
        pcall(function() existing = readfile(self.path) or "" end)
        pcall(writefile, self.path, existing .. chunk)
    else
        self.whole = (self.whole or "") .. chunk
        pcall(writefile, self.path, self.whole)
    end
end

--// Output layout ----------------------------------------------------------------------
local function folder()
    return ("Dumper/%d"):format(game.PlaceId)
end

local function ensureFolder()
    if not Has.makefolder then return end
    for _, path in ipairs({ "Dumper", folder() }) do
        if not (Has.isfolder and isfolder(path)) then pcall(makefolder, path) end
    end
end

local function filePath(name)
    if Has.makefolder then return folder() .. "/" .. name end
    return ("Dumper_%d_%s"):format(game.PlaceId, name)
end

-- written smallest and most useful first, so the top of a single-file dump
-- is the part worth reading before scrolling into the tree
local SECTIONS = {
    { key = "Info", file = "Info.txt", title = "GAME INFO" },
    { key = "Spy", file = "Spy.txt", title = "REMOTE SPY (live calls while dumping)" },
    { key = "Remotes", file = "Remotes.txt", title = "REMOTE CATALOGUE" },
    { key = "Interactables", file = "Interactables.txt", title = "INTERACTABLES (prompts, click and touch parts)" },
    { key = "Values", file = "Values.txt", title = "VALUE + ATTRIBUTE SNAPSHOT" },
    { key = "Hidden", file = "Hidden.txt", title = "HIDDEN (nil parented, loaded or running but not in the tree)" },
    { key = "Tree", file = "Tree.txt", title = "INSTANCE TREE" },
    { key = "Scripts", file = "Scripts.txt", title = "SCRIPTS" },
}

--// Crash memory -------------------------------------------------------------------
-- A decompile that takes the client down never gets to say so. Each script is
-- marked ATTEMPT before decompiling and DONE after; an ATTEMPT without a DONE
-- on the next run is the script that crashed it, and it gets skipped.
local function loadSuspects(path)
    local suspects = {}
    if not Has.readfile or (Has.isfile and not isfile(path)) then return suspects end
    local ok, content = pcall(readfile, path)
    if not ok or typeof(content) ~= "string" then return suspects end
    local attempted, done = {}, {}
    for line in content:gmatch("[^\r\n]+") do
        local tag, name = line:match("^(%a+)\t(.+)$")
        if tag == "ATTEMPT" then attempted[name] = true elseif tag == "DONE" then done[name] = true end
    end
    for name in pairs(attempted) do
        if not done[name] then suspects[name] = true end
    end
    return suspects
end

--// Remote spy ---------------------------------------------------------------------
-- Records every remote the game's own scripts fire (and every event the
-- server sends back) while the dump runs, with the real arguments. On a game
-- whose remotes all share one name, this is the only way to tell which one
-- is the dodge and which is the purchase.
local Spy = env.__DumperSpy
if typeof(Spy) ~= "table" then
    Spy = { active = false }
    env.__DumperSpy = Spy
end

local SPY_SAMPLES = 5
local SPY_CLASSES = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }

function Spy.reset()
    Spy.entries, Spy.order, Spy.started, Spy.connections = {}, {}, os.clock(), {}
end

function Spy.record(direction, remote, ...)
    local key = direction .. "\0" .. tostring(remote)
    local entry = Spy.entries[key]
    if not entry then
        entry = { direction = direction, remote = remote, count = 0, samples = {} }
        Spy.entries[key] = entry
        Spy.order[#Spy.order + 1] = entry
    end
    entry.count = entry.count + 1
    if #entry.samples < SPY_SAMPLES then
        local n = select("#", ...)
        local args = { ... }
        local parts = {}
        for i = 1, n do parts[i] = serialize(args[i]) end
        entry.samples[#entry.samples + 1] = ("@%.2fs  (%s)"):format(os.clock() - Spy.started, table.concat(parts, ", "))
    end
end

-- installed once per session and gated on Spy.active, since a namecall hook
-- cannot be taken back out again
local function installSpyHook()
    if not Has.hook or env.__DumperSpyHooked then return Has.hook end
    env.__DumperSpyHooked = true
    local original
    local function onNamecall(self, ...)
        local spy = env.__DumperSpy
        if spy and spy.active and typeof(self) == "Instance" then
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and SPY_CLASSES[self.ClassName]
                and not (Has.checkcaller and checkcaller())
            then
                pcall(spy.record, method == "FireServer" and "OUT FireServer" or "OUT InvokeServer", self, ...)
            end
        end
        return original(self, ...)
    end
    if typeof(newcclosure) == "function" then onNamecall = newcclosure(onNamecall) end
    original = hookmetamethod(game, "__namecall", onNamecall)
    return true
end

function Spy.start()
    Spy.reset()
    Spy.hooked = installSpyHook()
    for _, root in ipairs({ game:GetService("ReplicatedStorage"), workspace, LocalPlayer }) do
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        for _, inst in ipairs(ok and descendants or {}) do
            local okClass, className = pcall(function() return inst.ClassName end)
            if okClass and (className == "RemoteEvent" or className == "UnreliableRemoteEvent") then
                local okConn, connection = pcall(function()
                    return inst.OnClientEvent:Connect(function(...)
                        if Spy.active then pcall(Spy.record, "IN  OnClientEvent", inst, ...) end
                    end)
                end)
                if okConn then Spy.connections[#Spy.connections + 1] = connection end
            end
        end
    end
    Spy.active = true
end

function Spy.stop()
    Spy.active = false
    for _, connection in ipairs(Spy.connections or {}) do pcall(function() connection:Disconnect() end) end
    Spy.connections = {}
end

function Spy.write(writer)
    if not Spy.hooked then
        writer:write("-- outgoing calls need hookmetamethod, which this executor does not have; incoming only\n\n")
    end
    if #Spy.order == 0 then
        writer:write("-- nothing fired while recording. play the game (use tools, buy things, move) during the spy window\n")
        return
    end
    table.sort(Spy.order, function(a, b) return a.count > b.count end)
    for _, entry in ipairs(Spy.order) do
        local okPath, path = pcall(pathOf, entry.remote)
        writer:write(("[%s] %s   x%d\n"):format(entry.direction, okPath and path or "?", entry.count))
        for i, sample in ipairs(entry.samples) do
            writer:write(("    #%d %s\n"):format(i, sample))
        end
    end
end

--// Traversal helpers ------------------------------------------------------------
local function isDefaultScript(inst)
    local current = inst
    while current and current ~= game do
        if DEFAULT_SCRIPTS[current.Name] and SCRIPT_CLASSES[current.ClassName] then return true end
        current = current.Parent
    end
    return false
end

-- only client code ships to the client: a plain server Script's bytecode never
-- replicates, so there is nothing to decompile and trying just wastes time
local function isClientReadable(inst, className)
    if className ~= "Script" then return true end
    local ok, context = pcall(function() return inst.RunContext end)
    return ok and context == Enum.RunContext.Client
end

local function decompileWithTimeout(inst)
    local done, ok, result = false, false, nil
    task.spawn(function()
        ok, result = pcall(decompile, inst)
        done = true
    end)
    local started = os.clock()
    while not done do
        if os.clock() - started > Config.DecompileTimeout then
            return false, ("timed out after %ds"):format(Config.DecompileTimeout)
        end
        task.wait()
    end
    return ok, result
end

local function characterOwner(inst)
    local ok, player = pcall(function() return Players:GetPlayerFromCharacter(inst) end)
    return ok and player or nil
end

--// The dump -----------------------------------------------------------------------
local Dump = { running = false, cancel = false }

local function newStats()
    return {
        instances = 0, scripts = 0, duplicates = 0, defaults = 0, serverScripts = 0,
        failures = 0, suspects = 0, remotes = 0, values = 0, interactables = 0,
        collapsed = 0, hidden = 0,
    }
end

local function writeScript(ctx, inst, className, path)
    local stats = ctx.stats
    if Config.SkipDefaults and isDefaultScript(inst) then
        stats.defaults = stats.defaults + 1
        return
    end

    local w = ctx.writers.Scripts
    local header = ("%s\n%s | Type: %s | Method: decompile\nLocation: %s\n%s\n\n"):format(SEP, inst.Name, className, path, SEP)

    if not isClientReadable(inst, className) then
        stats.serverScripts = stats.serverScripts + 1
        return
    end

    if not Has.decompile then
        w:write(header .. "-- [decompile unavailable on this executor]\n\n")
        return
    end

    if ctx.suspects[path] then
        w:write(header .. "-- [skipped: a previous dump crashed while decompiling this one. forget crash skips to retry it]\n\n")
        stats.suspects = stats.suspects + 1
        return
    end

    -- the same Animate/Sprint script lives in every character and the same
    -- template in every clone - one copy is plenty
    local hash
    if Config.DedupeScripts and Has.scripthash then
        local ok, value = pcall(getscripthash, inst)
        if ok and value then hash = value end
    end
    if hash and ctx.seenScripts[hash] then
        w:write(header .. "-- [identical to " .. ctx.seenScripts[hash] .. "]\n\n")
        stats.duplicates = stats.duplicates + 1
        return
    end

    ctx.writers.State:write("ATTEMPT\t" .. path .. "\n")
    ctx.writers.State:flush()
    local ok, source = decompileWithTimeout(inst)
    ctx.writers.State:write("DONE\t" .. path .. "\n")

    if not ok or typeof(source) ~= "string" then
        w:write(header .. "-- [decompile failed: " .. tostring(source) .. "]\n\n")
        stats.failures = stats.failures + 1
        return
    end

    if Config.DedupeScripts and not hash then
        if ctx.seenScripts[source] then
            w:write(header .. "-- [identical to " .. ctx.seenScripts[source] .. "]\n\n")
            stats.duplicates = stats.duplicates + 1
            return
        end
        ctx.seenScripts[source] = path
    elseif hash then
        ctx.seenScripts[hash] = path
    end

    if #source > Config.MaxScriptChars then
        source = source:sub(1, Config.MaxScriptChars) .. ("\n-- [...truncated, %d chars total]"):format(#source)
    end
    w:write(header .. source .. "\n\n")
    stats.scripts = stats.scripts + 1
end

local function writeInteractable(ctx, inst, className, path)
    local w = ctx.writers.Interactables
    if className == "ProximityPrompt" then
        local ok, text = pcall(function()
            return ("action=%q object=%q hold=%ss range=%s enabled=%s"):format(
                inst.ActionText, inst.ObjectText, fmt(inst.HoldDuration), fmt(inst.MaxActivationDistance), tostring(inst.Enabled))
        end)
        w:write(("[Prompt] %s  %s\n"):format(path, ok and text or ""))
    elseif className == "ClickDetector" then
        local ok, range = pcall(function() return inst.MaxActivationDistance end)
        w:write(("[Click] %s  range=%s\n"):format(path, ok and fmt(range) or "?"))
    else
        local part = path:gsub("%.TouchInterest$", "")
        w:write(("[Touch] %s\n"):format(part))
    end
    ctx.stats.interactables = ctx.stats.interactables + 1
end

local function treeNote(inst, className)
    if REMOTE_CLASSES[className] then return "  <- remote" end
    if className == "Script" then
        local ok, context = pcall(function() return inst.RunContext end)
        return (ok and context == Enum.RunContext.Client) and "  [client]" or "  [server, unreadable]"
    end
    local ok, isValue = pcall(function() return inst:IsA("ValueBase") end)
    if ok and isValue then
        local okVal, value = pcall(function() return inst.Value end)
        return okVal and ("  = " .. serialize(value)) or ""
    end
    return ""
end

-- the children worth walking into, with repeats and other players' copies of
-- the same character folded down to a single line each
local function childrenOf(ctx, inst, depth, prefix, parentPath)
    if depth >= Config.MaxDepth then return {} end
    local ok, children = pcall(function() return inst:GetChildren() end)
    if not ok then return {} end
    local map = indexSiblings(inst, children)

    local groups, kept = {}, {}
    for _, child in ipairs(children) do
        local okName, name = pcall(function() return child.Name end)
        local okClass, className = pcall(function() return child.ClassName end)
        if okName and okClass and className ~= "Terrain" then
            local path = parentPath .. "." .. segment(child, map)
            local owner = className == "Model" and Config.OnlyMyCharacter and characterOwner(child)
            local otherPlayer = className == "Player" and Config.OnlyMyPlayer and child ~= LocalPlayer

            if owner and owner ~= LocalPlayer then
                kept[#kept + 1] = { note = name .. " (Model)  -- character of " .. owner.Name .. ", same as yours, skipped" }
            elseif otherPlayer then
                kept[#kept + 1] = { note = name .. " (Player)  -- skipped, only your own player is dumped" }
            elseif Config.SkipDefaults and DEFAULT_SCRIPTS[name] and SCRIPT_CLASSES[className] then
                kept[#kept + 1] = { note = name .. " (" .. className .. ")  -- roblox default, skipped" }
                ctx.stats.defaults = ctx.stats.defaults + 1
            else
                -- remotes and scripts are never folded: twenty identical
                -- "RemoteEvent"s are twenty different remotes
                local groupKey = name .. "\0" .. className
                local group = groups[groupKey]
                if not group then
                    group = { count = 0 }
                    groups[groupKey] = group
                end
                group.count = group.count + 1
                local foldable = Config.CollapseRepeats and not REMOTE_CLASSES[className] and not SCRIPT_CLASSES[className]
                if not foldable or group.count <= 3 then
                    kept[#kept + 1] = { inst = child, path = path, label = segment(child, map) }
                    group.last = #kept
                    group.name, group.className = name, className
                end
            end
        end
    end

    for _, group in pairs(groups) do
        local hidden = group.count - 3
        if Config.CollapseRepeats and hidden > 0 and group.last
            and not REMOTE_CLASSES[group.className] and not SCRIPT_CLASSES[group.className]
        then
            kept[group.last].fold = ("... +%d more %s (%s), same shape as the ones above, not walked")
                :format(hidden, group.name, group.className)
            ctx.stats.collapsed = ctx.stats.collapsed + hidden
        end
    end

    local frames = {}
    for _, item in ipairs(kept) do
        frames[#frames + 1] = item
        if item.fold then frames[#frames + 1] = { note = item.fold } end
    end
    for i, frame in ipairs(frames) do
        frame.depth, frame.prefix, frame.isLast = depth, prefix, i == #frames
    end
    return frames
end

local function visit(ctx, frame)
    local w, stats = ctx.writers, ctx.stats
    local branch = frame.depth == 0 and "" or (frame.isLast and "`-- " or "|-- ")

    if frame.note then
        if Config.Tree then w.Tree:write(frame.prefix .. branch .. frame.note .. "\n") end
        return
    end

    local inst, path = frame.inst, frame.path
    local okClass, className = pcall(function() return inst.ClassName end)
    if not okClass then return end
    ctx.visited[inst] = true
    stats.instances = stats.instances + 1

    local attrs = Config.Attributes and attributesOf(inst)
    if Config.Tree then
        w.Tree:write(frame.prefix .. branch .. (frame.label or inst.Name) .. " (" .. className .. ")" .. treeNote(inst, className)
            .. (attrs and ("  {" .. attrs .. "}") or "") .. "\n")
    end

    if Config.Scripts and SCRIPT_CLASSES[className] then
        writeScript(ctx, inst, className, path)
    elseif Config.Remotes and REMOTE_CLASSES[className] then
        w.Remotes:write(("[%s] %s\n"):format(className, path))
        stats.remotes = stats.remotes + 1
    elseif Config.Interactables and (className == "ProximityPrompt" or className == "ClickDetector" or className == "TouchTransmitter") then
        writeInteractable(ctx, inst, className, path)
    end

    local inGui = path:find("PlayerGui", 1, true) or path:find("StarterGui", 1, true)
    if Config.Values and not (Config.SkipGuiValues and inGui) then
        local okValue, isValue = pcall(function() return inst:IsA("ValueBase") end)
        if okValue and isValue then
            local okVal, value = pcall(function() return inst.Value end)
            w.Values:write(("%-16s %s = %s\n"):format(className, path, okVal and serialize(value) or "<unreadable>"))
            stats.values = stats.values + 1
        end
        if attrs then
            w.Values:write(("%-16s %s {%s}\n"):format("Attributes", path, attrs))
        end
    end

    local childPrefix = frame.prefix
    if frame.depth > 0 then childPrefix = childPrefix .. (frame.isLast and "    " or "|   ") end
    local children = childrenOf(ctx, inst, frame.depth + 1, childPrefix, path)
    for i = #children, 1, -1 do
        ctx.stack[#ctx.stack + 1] = children[i]
    end
end

local function dumpHidden(ctx)
    local w = ctx.writers.Hidden
    local sources = {
        { "nil parented", Has.nilinstances and getnilinstances },
        { "loaded module", Has.loadedmodules and getloadedmodules },
        { "running script", Has.runningscripts and getrunningscripts },
    }
    for _, source in ipairs(sources) do
        local label, getter = source[1], source[2]
        if getter then
            local ok, list = pcall(getter)
            for _, inst in ipairs(ok and typeof(list) == "table" and list or {}) do
                if Dump.cancel then return end
                local okClass, className = pcall(function() return inst.ClassName end)
                if okClass and not ctx.visited[inst] and (SCRIPT_CLASSES[className] or REMOTE_CLASSES[className]) then
                    ctx.visited[inst] = true
                    local okPath, path = pcall(pathOf, inst)
                    path = okPath and path or ("nil." .. tostring(inst))
                    w:write(("[%s] %s  (%s)\n"):format(className, path, label))
                    ctx.stats.hidden = ctx.stats.hidden + 1
                    if Config.Scripts and SCRIPT_CLASSES[className] then
                        writeScript(ctx, inst, className, path)
                    end
                    task.wait()
                end
            end
        else
            w:write(("-- %s: not supported on this executor\n"):format(label))
        end
    end
end

local function writeInfo(w)
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    local identify = typeof(identifyexecutor) == "function" and identifyexecutor
        or typeof(getexecutorname) == "function" and getexecutorname
    local okExec, executor = pcall(function() return identify and identify() end)

    w:write(("%s\n"):format(VERSION))
    w:write(("Game: %s\n"):format(ok and info and info.Name or "?"))
    w:write(("PlaceId: %d   GameId: %d   PlaceVersion: %d\n"):format(game.PlaceId, game.GameId, game.PlaceVersion))
    w:write(("JobId: %s\n"):format(game.JobId))
    w:write(("Creator: %s %s\n"):format(tostring(game.CreatorType), tostring(game.CreatorId)))
    w:write(("Players: %d / %d\n"):format(#Players:GetPlayers(), Players.MaxPlayers))
    w:write(("Executor: %s\n"):format(okExec and tostring(executor or "?") or "?"))
    w:write(("Generated: %s\n\n"):format(os.date("%Y-%m-%d %H:%M:%S")))

    local keys = {}
    for key in pairs(Config) do keys[#keys + 1] = key end
    table.sort(keys)
    w:write("Settings:\n")
    for _, key in ipairs(keys) do
        local value = Config[key]
        w:write(("  %-16s %s\n"):format(key, typeof(value) == "table" and table.concat(value, ", ") or tostring(value)))
    end
end

function Dump.run(report)
    if Dump.running then return end
    if not Has.writefile then
        report("writefile is not available on this executor", true)
        return
    end
    Dump.running, Dump.cancel = true, false
    ensureFolder()

    local statePath = filePath("State.txt")
    local ctx = {
        stats = newStats(),
        suspects = loadSuspects(statePath),
        seenScripts = {},
        visited = setmetatable({}, { __mode = "k" }),
        stack = {},
        writers = { State = FileWriter.new(statePath) },
    }
    -- the state file starts over, so anything already known to crash is
    -- written straight back in or it would be forgotten if this run dies too
    for path in pairs(ctx.suspects) do
        ctx.writers.State:write("ATTEMPT\t" .. path .. "\n")
    end
    ctx.writers.State:flush()

    for _, section in ipairs(SECTIONS) do
        local writer = FileWriter.new(filePath(section.file))
        writer:write(("%s\n%s\n%s\n\n"):format(SEP, section.title, SEP))
        ctx.writers[section.key] = writer
    end

    local started = os.clock()
    if Config.Spy then Spy.start() end
    if Config.Info then writeInfo(ctx.writers.Info) end

    local ok, err = pcall(function()
        local wanted = {}
        for _, name in ipairs(Config.Roots) do wanted[name] = true end
        local roots = {}
        for _, name in ipairs(ROOT_ORDER) do
            if wanted[name] then
                local okService, service = pcall(function() return game:GetService(name) end)
                if okService and service then roots[#roots + 1] = service end
            end
        end
        for i = #roots, 1, -1 do
            ctx.stack[#ctx.stack + 1] = { inst = roots[i], path = roots[i].Name, depth = 0, prefix = "", isLast = i == #roots }
        end

        local processed = 0
        while #ctx.stack > 0 and not Dump.cancel do
            local frame = ctx.stack[#ctx.stack]
            ctx.stack[#ctx.stack] = nil
            visit(ctx, frame)
            processed = processed + 1
            if processed % 25 == 0 then
                report(("walking - %d instances, %d scripts, %d queued"):format(ctx.stats.instances, ctx.stats.scripts, #ctx.stack))
                task.wait()
            end
        end

        if Config.Hidden and not Dump.cancel then
            report("checking nil / loaded / running scripts")
            dumpHidden(ctx)
        end

        if Config.Spy then
            local remaining = Config.SpySeconds - (os.clock() - started)
            while remaining > 0 and not Dump.cancel do
                report(("recording remotes - %ds left, keep playing"):format(math.ceil(remaining)))
                task.wait(0.5)
                remaining = Config.SpySeconds - (os.clock() - started)
            end
            Spy.stop()
            Spy.write(ctx.writers.Spy)
        end
    end)
    if Config.Spy then Spy.stop() end

    local stats = ctx.stats
    local summary = ("instances %d | scripts %d (+%d duplicate, %d default skipped, %d server-only, %d failed, %d crash-skipped) | remotes %d | values %d | interactables %d | hidden %d | folded repeats %d | %.1fs")
        :format(stats.instances, stats.scripts, stats.duplicates, stats.defaults, stats.serverScripts, stats.failures,
            stats.suspects, stats.remotes, stats.values, stats.interactables, stats.hidden, stats.collapsed, os.clock() - started)
    if Config.Info then
        ctx.writers.Info:write("\nResult: " .. (ok and summary or ("errored - " .. tostring(err))) .. (Dump.cancel and " (stopped early)" or "") .. "\n")
    end

    for _, writer in pairs(ctx.writers) do writer:flush() end
    -- a dump that finished only needs to remember the scripts known to crash
    -- the client, so they stay skipped until "forget crash skips" is pressed;
    -- one that stopped or errored keeps its whole trail so the next run also
    -- skips whatever was mid-decompile when it died
    if ok and not Dump.cancel then
        local lines = {}
        for path in pairs(ctx.suspects) do lines[#lines + 1] = "ATTEMPT\t" .. path .. "\n" end
        pcall(writefile, statePath, table.concat(lines))
    end

    local output = folder()
    if Config.Output == "Single file" and Has.readfile then
        local combined = FileWriter.new(filePath("Dump.txt"))
        for _, section in ipairs(SECTIONS) do
            if Config[section.key] then
                local path = filePath(section.file)
                local okRead, content = pcall(readfile, path)
                if okRead and content then combined:write(content .. "\n") end
            end
        end
        combined:flush()
        for _, section in ipairs(SECTIONS) do
            local path = filePath(section.file)
            if Has.delfile then pcall(delfile, path) else pcall(writefile, path, "") end
        end
        output = filePath("Dump.txt")
    else
        for _, section in ipairs(SECTIONS) do
            if not Config[section.key] then
                local path = filePath(section.file)
                if Has.delfile then pcall(delfile, path) else pcall(writefile, path, "") end
            end
        end
    end

    Dump.running = false
    report(ok and ("done - saved to " .. output) or ("errored - " .. tostring(err)), not ok, summary)
end

--// Headless ------------------------------------------------------------------------
if Config.NoUI then
    if Config.AutoStart then
        task.spawn(Dump.run, function(text, isError, summary)
            if isError then warn("[Dumper] " .. text) end
            if summary then print("[Dumper] " .. text .. "\n[Dumper] " .. summary) end
        end)
    end
    env.Dumper = {
        Config = Config, Run = Dump.run,
        Stop = function() Dump.cancel = true end,
        ForgetCrashes = function() pcall(writefile, filePath("State.txt"), "") end,
    }
    return
end

--// UI ----------------------------------------------------------------------------
local Onyx
do
    local ref = "main"
    local resolved, sha = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui2/commits/main"))
        return commit.sha
    end)
    if resolved and sha then ref = sha end
    Onyx = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui2/%s/Ui.lua"):format(ref)))()
end

local Window = Onyx:CreateWindow({
    Title = "dumper",
    SubTitle = VERSION,
    Folder = "Dumper",
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 170, 60),
})

local StatusLabel, SummaryLabel

do
    local Tab = Window:CreateTab({ Title = "dump" })
    local section = Tab:CreateSection("sections")

    local function toggle(title, key, description)
        section:Toggle({
            Title = title,
            Description = description,
            Flag = "dumper_" .. key,
            Default = Config[key],
            Callback = function(state) Config[key] = state end,
        })
    end

    toggle("game info", "Info", "place, game id, creator, executor and the settings this dump used")
    toggle("scripts", "Scripts", "decompiles every client-readable script")
    toggle("workspace tree", "Tree", "every instance, with values, attributes and remotes marked inline")
    toggle("remotes", "Remotes", "every remote and bindable, numbered when siblings share a name")
    toggle("values + attributes", "Values", "the live value of every ValueBase and every attribute")
    toggle("interactables", "Interactables", "proximity prompts, click detectors and touch parts - what auto farms hook into")
    toggle("hidden scripts", "Hidden", "scripts and remotes parented to nil, or loaded/running without being in the tree")

    section = Tab:CreateSection("remote spy")
    toggle("record remotes", "Spy", "logs every remote the game fires and receives while the dump runs, with real arguments. play normally during it")
    section:Slider({
        Title = "record for",
        Description = "the dump waits for this long before finishing so there is time to use things",
        Min = 5, Max = 180, Increment = 5, Suffix = "s",
        Default = Config.SpySeconds,
        Flag = "dumper_spy_seconds",
        Callback = function(value) Config.SpySeconds = tonumber(value) or Config.SpySeconds end,
    })

    section = Tab:CreateSection("filters")
    toggle("skip roblox defaults", "SkipDefaults", "PlayerModule, chat and character sound scripts - the same in every game")
    toggle("dedupe scripts", "DedupeScripts", "one copy of a script that exists in every character or clone")
    toggle("only my character", "OnlyMyCharacter", "other players' characters are copies of yours")
    toggle("only my player", "OnlyMyPlayer", "skip other players' data folders (keeps yours)")
    toggle("fold repeats", "CollapseRepeats", "more than 3 identical siblings become one line. never folds remotes or scripts")
    toggle("skip gui values", "SkipGuiValues", "values inside PlayerGui/StarterGui are nearly always animation state")
    toggle("attributes", "Attributes", "show attributes in the tree and snapshot")

    section = Tab:CreateSection("where to look")
    section:Dropdown({
        Title = "roots",
        Description = "which services get walked",
        Values = ROOT_ORDER,
        Default = Config.Roots,
        Multi = true,
        Flag = "dumper_roots",
        Callback = function(value)
            if typeof(value) == "table" then Config.Roots = value end
        end,
    })

    section = Tab:CreateSection("limits")
    section:Dropdown({
        Title = "output",
        Description = "one file to upload, or one file per section",
        Values = { "Single file", "Split files" },
        Default = Config.Output,
        Flag = "dumper_output",
        Callback = function(value) Config.Output = value end,
    })
    section:Slider({
        Title = "max tree depth", Min = 4, Max = 40, Increment = 1,
        Default = Config.MaxDepth, Flag = "dumper_depth",
        Callback = function(value) Config.MaxDepth = tonumber(value) or Config.MaxDepth end,
    })
    section:Slider({
        Title = "max chars per script", Min = 10000, Max = 500000, Increment = 10000,
        Default = Config.MaxScriptChars, Flag = "dumper_chars",
        Callback = function(value) Config.MaxScriptChars = tonumber(value) or Config.MaxScriptChars end,
    })
    section:Slider({
        Title = "decompile timeout", Min = 2, Max = 60, Increment = 1, Suffix = "s",
        Default = Config.DecompileTimeout, Flag = "dumper_timeout",
        Callback = function(value) Config.DecompileTimeout = tonumber(value) or Config.DecompileTimeout end,
    })

    section = Tab:CreateSection("run")
    StatusLabel = section:Label({ Title = "status: idle" })
    SummaryLabel = section:Label({ Title = "-" })

    section:Button({
        Title = "start dump",
        Callback = function()
            if Dump.running then return end
            task.spawn(Dump.run, function(text, isError, summary)
                StatusLabel:SetText("status: " .. text)
                if summary then
                    SummaryLabel:SetText(summary)
                    Onyx:Notify({ Title = "dumper", Content = text, Type = isError and "error" or "success", Duration = 8 })
                elseif isError then
                    Onyx:Notify({ Title = "dumper", Content = text, Type = "error", Duration = 6 })
                end
            end)
        end,
    })
    section:Button({
        Title = "stop",
        Callback = function()
            if Dump.running then
                Dump.cancel = true
                StatusLabel:SetText("status: stopping...")
            end
        end,
    })

    section:Button({
        Title = "forget crash skips",
        Callback = function()
            if Dump.running then return end
            pcall(writefile, filePath("State.txt"), "")
            StatusLabel:SetText("status: crash skips cleared, every script gets retried")
        end,
    })

    section:Paragraph({
        Title = "what to send back",
        Content = "single file mode writes Dumper/<place id>/Dump.txt - that one file is everything. turn on record remotes and actually play during the window (use tools, buy, open menus) - it is what makes a game whose remotes all share one name readable",
    })
end

env.Dumper = {
    Config = Config, Run = Dump.run,
    Stop = function() Dump.cancel = true end,
    ForgetCrashes = function() pcall(writefile, filePath("State.txt"), "") end,
}

if Config.AutoStart then
    task.spawn(Dump.run, function(text, _, summary)
        StatusLabel:SetText("status: " .. text)
        if summary then SummaryLabel:SetText(summary) end
    end)
end

Onyx:Notify({ Title = "dumper", Content = "loaded - RightShift toggles the menu", Type = "success", Duration = 5 })

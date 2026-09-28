--// Dumper -------------------------------------------------------------------------
--
-- loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Tools/Dumper.lua'))()
--
-- Every option in the menu can also be set before loading; AutoStart + NoUI
-- run it headless:
--
-- getgenv().DumperConfig = { Spy = true, SpySeconds = 30, Speed = "Max", AutoStart = true, NoUI = true }
--
-- Output lands in Dumper/<PlaceId>/ in the executor's workspace folder.
--
-- Why it is fast now:
--   * it works to a time budget per frame instead of pausing every 25
--     instances, which alone was ~17s of waiting on a 25k instance game
--   * the walk only queues scripts; they are decompiled afterwards in one
--     sorted pass, duplicates are caught by hash before decompiling
--   * the output is built in memory and written in a handful of calls instead
--     of thousands of appends, then stitched with a contents page

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
    bytecode = typeof(getscriptbytecode) == "function",
    nilinstances = typeof(getnilinstances) == "function",
    loadedmodules = typeof(getloadedmodules) == "function",
    runningscripts = typeof(getrunningscripts) == "function",
    hook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function",
    checkcaller = typeof(checkcaller) == "function",
}

local VERSION = "Dumper v6"
local WIDTH = 80
local RULE = string.rep("=", WIDTH)
local THIN = string.rep("-", WIDTH)

local ROOT_ORDER = {
    "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer",
    "StarterPack", "Players", "Lighting", "SoundService", "Teams", "Chat",
}
-- scripts are written grouped by where they live, shared code first
local SCRIPT_ROOT_RANK = {
    ReplicatedFirst = 1, ReplicatedStorage = 2, StarterPlayer = 3, StarterGui = 4,
    StarterPack = 5, Players = 6, Workspace = 7, Lighting = 8, SoundService = 9,
    Teams = 10, Chat = 11,
}

-- seconds of work per frame before handing the frame back to the game
local SPEEDS = { Smooth = 0.006, Fast = 0.016, Max = 0.05 }

local Config = {
    Output = "Single file",
    Speed = "Fast",
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
    MaxDepth = 40,
    MaxScriptChars = 500000,
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

-- Roblox's own player/chat scripts: identical in every game
local DEFAULT_SCRIPTS = {
    PlayerModule = true, PlayerScriptsLoader = true, RbxCharacterSounds = true,
    ChatScript = true, BubbleChat = true, ChatMain = true,
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
    BindableEvent = true, BindableFunction = true,
}
local VALUE_CLASSES = {
    StringValue = true, IntValue = true, NumberValue = true, BoolValue = true,
    ObjectValue = true, Vector3Value = true, CFrameValue = true, Color3Value = true,
    BrickColorValue = true, RayValue = true,
}
local INTERACT_CLASSES = { ProximityPrompt = true, ClickDetector = true, TouchTransmitter = true }

-- plain functions for pcall, so a guarded read allocates no closure
local function readValue(inst) return inst.Value end
local function readRunContext(inst) return inst.RunContext end

--// Serialising values ----------------------------------------------------------------
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
        local ok, name = pcall(value.GetFullName, value)
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

-- sorted { key, text } pairs, or nil when there are none
local function readAttributes(inst)
    local ok, attrs = pcall(inst.GetAttributes, inst)
    if not ok or typeof(attrs) ~= "table" or next(attrs) == nil then return nil end
    local list = {}
    for key, value in pairs(attrs) do
        list[#list + 1] = { key = key, text = serialize(value, 1) }
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

local function inlineAttributes(list)
    local parts = {}
    for i, attr in ipairs(list) do parts[i] = attr.key .. "=" .. attr.text end
    local text = table.concat(parts, ", ")
    if #text > 300 then text = text:sub(1, 300) .. "..." end
    return text
end

local function pad(text, width)
    if #text >= width then return text end
    return text .. string.rep(" ", width - #text)
end

local function padLeft(text, width)
    if #text >= width then return text end
    return string.rep(" ", width - #text) .. text
end

--// Paths ------------------------------------------------------------------------------
-- Siblings that share a name get their position appended - RemoteEvent[3] -
-- which stays stable for the life of the server and is what the spy uses too.
local siblingIndex = setmetatable({}, { __mode = "k" })

local function indexSiblings(parent, children)
    local counts, seen, map = {}, {}, {}
    for _, child in ipairs(children) do
        local name = child.Name
        counts[name] = (counts[name] or 0) + 1
    end
    for _, child in ipairs(children) do
        local name = child.Name
        if counts[name] > 1 then
            seen[name] = (seen[name] or 0) + 1
            map[child] = seen[name]
        end
    end
    siblingIndex[parent] = map
    return map
end

local function segment(inst, map)
    local index = map and map[inst]
    return index and (inst.Name .. "[" .. index .. "]") or inst.Name
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
            local ok, children = pcall(parent.GetChildren, parent)
            map = ok and indexSiblings(parent, children) or {}
        end
        table.insert(parts, 1, segment(current, map))
        current = parent
    end
    return table.concat(parts, ".")
end

local function parentPathOf(path)
    return path:match("^(.*)%.[^%.]+$") or path
end

--// Output buffers -------------------------------------------------------------------
-- Everything is built in memory and counted in lines as it goes, which is what
-- lets the contents page and the script index point at exact line numbers.
local Buffer = {}
Buffer.__index = Buffer

function Buffer.new()
    return setmetatable({ parts = {}, n = 0, lines = 0 }, Buffer)
end

function Buffer:line(text)
    local n = self.n
    self.parts[n + 1] = text
    self.parts[n + 2] = "\n"
    self.n = n + 2
    self.lines = self.lines + 1
end

-- multi-line text, and how many lines it is if the caller already knows
function Buffer:block(text, count)
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    if not count then
        local _, newlines = text:gsub("\n", "")
        count = newlines
    end
    self.n = self.n + 1
    self.parts[self.n] = text
    self.lines = self.lines + count
    return count
end

function Buffer:text()
    return table.concat(self.parts, "", 1, self.n)
end

--// Files ------------------------------------------------------------------------------
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

-- a few big writes rather than thousands of small ones
local function writeChunks(path, chunks)
    if Has.appendfile then
        pcall(writefile, path, chunks[1] or "")
        for i = 2, #chunks do pcall(appendfile, path, chunks[i]) end
    else
        pcall(writefile, path, table.concat(chunks))
    end
end

--// Crash memory ---------------------------------------------------------------------
-- A decompile that takes the client down never gets to say so. Each script is
-- written down as an ATTEMPT just before it is decompiled - one append, nothing
-- after - and a finished dump rewrites the file with only the known SUSPECTs.
-- So a file still holding attempts means the last run died, and since scripts
-- are decompiled one at a time, the last attempt is the one that killed it.
-- (Files from the old dumper paired ATTEMPT with DONE; those still read.)
local function loadSuspects(path)
    local suspects = {}
    if not Has.readfile or (Has.isfile and not isfile(path)) then return suspects end
    local ok, content = pcall(readfile, path)
    if not ok or typeof(content) ~= "string" then return suspects end
    local attempted, done, lastAttempt, oldFormat = {}, {}, nil, false
    for line in content:gmatch("[^\r\n]+") do
        local tag, name = line:match("^(%a+)\t(.+)$")
        if tag == "SUSPECT" then
            suspects[name] = true
        elseif tag == "ATTEMPT" then
            attempted[name] = true
            lastAttempt = name
        elseif tag == "DONE" then
            done[name] = true
            oldFormat = true
        end
    end
    if oldFormat then
        for name in pairs(attempted) do
            if not done[name] then suspects[name] = true end
        end
    elseif lastAttempt then
        suspects[lastAttempt] = true
    end
    return suspects
end

local State = {}

function State.open(path, suspects)
    State.path, State.text = path, {}
    for name in pairs(suspects) do State.text[#State.text + 1] = "SUSPECT\t" .. name .. "\n" end
    pcall(writefile, path, table.concat(State.text))
end

function State.add(line)
    State.text[#State.text + 1] = line
    if Has.appendfile then
        pcall(appendfile, State.path, line)
    else
        pcall(writefile, State.path, table.concat(State.text))
    end
end

--// Remote spy -----------------------------------------------------------------------
-- Records every remote the game's own scripts fire (and every event the server
-- sends back) while the dump runs, with the real arguments.
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
        entry.samples[#entry.samples + 1] = ("@%6.2fs  (%s)"):format(os.clock() - Spy.started, table.concat(parts, ", "))
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
        local ok, descendants = pcall(root.GetDescendants, root)
        for _, inst in ipairs(ok and descendants or {}) do
            local className = inst.ClassName
            if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
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

function Spy.write(out)
    if not Spy.hooked then
        out:line("outgoing calls need hookmetamethod, which this executor does not have - incoming only")
        out:line("")
    end
    if not Spy.order or #Spy.order == 0 then
        out:line("nothing fired while recording - play the game (use tools, buy, move) during the spy window")
        return
    end
    table.sort(Spy.order, function(a, b)
        if a.direction ~= b.direction then return a.direction > b.direction end
        return a.count > b.count
    end)
    local lastSide
    for _, entry in ipairs(Spy.order) do
        local side = entry.direction:match("^%a+")
        if side ~= lastSide then
            if lastSide then out:line("") end
            out:line(side == "OUT" and "sent by the game (client -> server)" or "received (server -> client)")
            out:line(THIN)
            lastSide = side
        end
        local okPath, path = pcall(pathOf, entry.remote)
        out:line(("%-18s %s   x%d"):format(entry.direction:gsub("^%a+%s+", ""), okPath and path or "?", entry.count))
        for _, sample in ipairs(entry.samples) do
            out:line("      " .. sample)
        end
    end
end

--// Walking the game -------------------------------------------------------------------
local Dump = { running = false, cancel = false }

local function isDefaultScript(inst)
    local current = inst
    while current and current ~= game do
        if DEFAULT_SCRIPTS[current.Name] and SCRIPT_CLASSES[current.ClassName] then return true end
        current = current.Parent
    end
    return false
end

-- only client code ships to the client: a plain server Script's bytecode never
-- replicates, so there is nothing to decompile
local function isClientReadable(inst, className)
    if className ~= "Script" then return true end
    local ok, context = pcall(readRunContext, inst)
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

local function newContext()
    local characters = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then characters[player.Character] = player end
    end
    return {
        stats = {
            instances = 0, scripts = 0, duplicates = 0, defaults = 0, serverScripts = 0,
            failures = 0, suspects = 0, remotes = 0, values = 0, interactables = 0,
            collapsed = 0, hidden = 0,
        },
        timings = {},
        characters = characters,
        classCount = {},
        visited = setmetatable({}, { __mode = "k" }),
        stack = {},
        queue = {},        -- scripts found by the walk, decompiled afterwards
        remotes = {},      -- { parent, name, className }
        interactables = {},
        hidden = {},
        index = {},        -- the script index rows
        seenScripts = {},
        out = {
            Tree = Buffer.new(),
            Values = Buffer.new(),
            Scripts = Buffer.new(),
        },
    }
end

-- hands the frame back once this frame's share of work is spent
local Budget = { last = 0 }

function Budget.start() Budget.last = os.clock() end

function Budget.check(onYield)
    if os.clock() - Budget.last >= (SPEEDS[Config.Speed] or SPEEDS.Fast) then
        if onYield then onYield() end
        task.wait()
        Budget.last = os.clock()
    end
end

local function treeNote(className, value, hasValue)
    if REMOTE_CLASSES[className] then return "  <- remote" end
    if className == "Script" then return nil end
    if hasValue then return "  = " .. value end
    return ""
end

-- the children worth walking into, with repeats and other players' copies of
-- the same character folded down to a single line each
local function childFrames(ctx, inst, depth, prefix, parentPath, inGui)
    if depth >= Config.MaxDepth then return nil end
    local ok, children = pcall(inst.GetChildren, inst)
    if not ok or #children == 0 then return nil end
    local map = indexSiblings(inst, children)

    local groups, kept = {}, {}
    for _, child in ipairs(children) do
        local name, className = child.Name, child.ClassName
        if className ~= "Terrain" then
            local owner = className == "Model" and Config.OnlyMyCharacter and ctx.characters[child]
            if owner and owner ~= LocalPlayer then
                kept[#kept + 1] = { note = name .. " (Model)  -- " .. owner.Name .. "'s character, same as yours, skipped" }
            elseif className == "Player" and Config.OnlyMyPlayer and child ~= LocalPlayer then
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
                    group = { count = 0, name = name, className = className }
                    groups[groupKey] = group
                end
                group.count = group.count + 1
                local foldable = Config.CollapseRepeats and not REMOTE_CLASSES[className] and not SCRIPT_CLASSES[className]
                if not foldable or group.count <= 3 then
                    local label = segment(child, map)
                    kept[#kept + 1] = {
                        inst = child, className = className, label = label,
                        path = parentPath .. "." .. label,
                        inGui = inGui or name == "PlayerGui" or name == "StarterGui",
                    }
                    group.last = #kept
                end
            end
        end
    end

    for _, group in pairs(groups) do
        local extra = group.count - 3
        if extra > 0 and group.last and Config.CollapseRepeats
            and not REMOTE_CLASSES[group.className] and not SCRIPT_CLASSES[group.className]
        then
            kept[group.last].fold = ("... +%d more %s (%s), same shape as the ones above, not walked")
                :format(extra, group.name, group.className)
            ctx.stats.collapsed = ctx.stats.collapsed + extra
        end
    end

    local frames = {}
    for _, item in ipairs(kept) do
        frames[#frames + 1] = item
        if item.fold then frames[#frames + 1] = { note = item.fold } end
    end
    local count = #frames
    for i, frame in ipairs(frames) do
        frame.depth, frame.prefix, frame.isLast = depth, prefix, i == count
    end
    return frames
end

local function visit(ctx, frame)
    local out, stats = ctx.out, ctx.stats
    local branch = frame.depth == 0 and "" or (frame.isLast and "`-- " or "|-- ")

    if frame.note then
        if Config.Tree then out.Tree:line(frame.prefix .. branch .. frame.note) end
        return
    end

    local inst, path = frame.inst, frame.path
    local className = frame.className or inst.ClassName
    ctx.visited[inst] = true
    stats.instances = stats.instances + 1
    ctx.classCount[className] = (ctx.classCount[className] or 0) + 1

    local attrs = Config.Attributes and readAttributes(inst) or nil
    local hasValue, valueText = false, nil
    if VALUE_CLASSES[className] then
        local ok, value = pcall(readValue, inst)
        hasValue, valueText = true, ok and serialize(value) or "<unreadable>"
    end

    if Config.Tree then
        local note
        if className == "Script" then
            local ok, context = pcall(readRunContext, inst)
            note = (ok and context == Enum.RunContext.Client) and "  [client]" or "  [server, unreadable]"
        else
            note = treeNote(className, valueText, hasValue)
        end
        out.Tree:line(frame.prefix .. branch .. (frame.label or inst.Name) .. " (" .. className .. ")" .. note
            .. (attrs and ("  {" .. inlineAttributes(attrs) .. "}") or ""))
    end

    if SCRIPT_CLASSES[className] then
        if Config.Scripts then
            ctx.queue[#ctx.queue + 1] = { inst = inst, className = className, path = path }
        end
    elseif REMOTE_CLASSES[className] then
        if Config.Remotes then
            ctx.remotes[#ctx.remotes + 1] = { parent = parentPathOf(path), name = frame.label or inst.Name, className = className }
            stats.remotes = stats.remotes + 1
        end
    elseif INTERACT_CLASSES[className] and Config.Interactables then
        ctx.interactables[#ctx.interactables + 1] = { inst = inst, className = className, path = path }
        stats.interactables = stats.interactables + 1
    end

    -- values hang off their parent, attributes off the instance itself; the
    -- walk visits an instance right before its children, so both land under
    -- one heading
    if Config.Values and not (Config.SkipGuiValues and frame.inGui) then
        local values = out.Values
        if attrs then
            if values.group ~= path then
                values.group = path
                values:line("")
                values:line(path)
            end
            for _, attr in ipairs(attrs) do
                values:line("    @" .. pad(attr.key, 26) .. " = " .. attr.text)
            end
        end
        if hasValue then
            local parent = parentPathOf(path)
            if values.group ~= parent then
                values.group = parent
                values:line("")
                values:line(parent)
            end
            values:line("    " .. pad(frame.label or inst.Name, 27) .. " = " .. pad(valueText, 30) .. "  " .. className)
            stats.values = stats.values + 1
        end
    end

    local childPrefix = frame.prefix
    if frame.depth > 0 then childPrefix = childPrefix .. (frame.isLast and "    " or "|   ") end
    local children = childFrames(ctx, inst, frame.depth + 1, childPrefix, path, frame.inGui)
    if children then
        local stack = ctx.stack
        for i = #children, 1, -1 do stack[#stack + 1] = children[i] end
    end
end

local function collectHidden(ctx)
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
                    ctx.hidden[#ctx.hidden + 1] = { className = className, path = path, label = label }
                    ctx.stats.hidden = ctx.stats.hidden + 1
                    if Config.Scripts and SCRIPT_CLASSES[className]
                        and not (Config.SkipDefaults and isDefaultScript(inst))
                    then
                        ctx.queue[#ctx.queue + 1] = { inst = inst, className = className, path = path, hidden = true }
                    end
                end
                Budget.check()
            end
        else
            ctx.hidden[#ctx.hidden + 1] = { note = label .. ": not supported on this executor" }
        end
    end
end

-- One script: skipped, matched to one already written, or decompiled and
-- written under a header that is itself a Lua comment, so a script copied out
-- of the dump still runs.
local function decompileOne(ctx, item)
    local stats, out = ctx.stats, ctx.out.Scripts
    local row = { path = item.path, className = item.className }
    ctx.index[#ctx.index + 1] = row

    if not isClientReadable(item.inst, item.className) then
        stats.serverScripts = stats.serverScripts + 1
        row.status = "server"
        return
    end
    if not Has.decompile then
        row.status = "no decompiler"
        return
    end
    if ctx.suspects[item.path] then
        stats.suspects = stats.suspects + 1
        row.status = "crash-skipped"
        return
    end

    -- the same Animate/Sprint script lives in every character and the same
    -- template in every clone - one copy is plenty, and a hash says so
    -- without decompiling it again
    local key
    if Config.DedupeScripts then
        if Has.scripthash then
            local ok, hash = pcall(getscripthash, item.inst)
            if ok and hash then key = hash end
        end
        if not key and Has.bytecode then
            local ok, bytecode = pcall(getscriptbytecode, item.inst)
            if ok and typeof(bytecode) == "string" then
                if bytecode == "" then
                    row.status = "empty"
                    return
                end
                key = bytecode
            end
        end
        if key and ctx.seenScripts[key] then
            stats.duplicates = stats.duplicates + 1
            row.status, row.sameAs = "same", ctx.seenScripts[key]
            return
        end
    end

    State.add("ATTEMPT\t" .. item.path .. "\n")
    local started = os.clock()
    local ok, source = decompileWithTimeout(item.inst)
    local took = os.clock() - started

    if not ok or typeof(source) ~= "string" then
        stats.failures = stats.failures + 1
        row.status, row.note = "failed", tostring(source)
        return
    end

    if Config.DedupeScripts then
        -- no hash on this executor: the source itself is the key
        key = key or source
        if ctx.seenScripts[key] then
            stats.duplicates = stats.duplicates + 1
            row.status, row.sameAs = "same", ctx.seenScripts[key]
            return
        end
        ctx.seenScripts[key] = item.path
    end

    local chars = #source
    if chars > Config.MaxScriptChars then
        source = source:sub(1, Config.MaxScriptChars) .. ("\n-- [...truncated, %d chars total]"):format(chars)
    end
    if source:sub(-1) ~= "\n" then source = source .. "\n" end
    local _, lines = source:gsub("\n", "")

    out:line("")
    out:line(THIN)
    row.line = out.lines + 1   -- this header's line, counted within the section
    out:line(("-- [%s] %s%s"):format(item.className, item.inst.Name, item.hidden and "  (hidden)" or ""))
    out:line("-- " .. item.path)
    out:line(("-- %d lines, %.1f KB, decompiled in %.2fs"):format(lines, chars / 1024, took))
    out:line(THIN)
    out:block(source, lines)
    row.lines, row.kb = lines, chars / 1024
    stats.scripts = stats.scripts + 1
    row.status = "ok"
end

--// The report -------------------------------------------------------------------------
local function sectionHeader(out, number, title)
    out:line("")
    out:line(RULE)
    out:line((" %d. %s"):format(number, title))
    out:line(RULE)
    out:line("")
end
local SECTION_HEADER_LINES = 5

local function writeInfo(ctx, out)
    local identify = typeof(identifyexecutor) == "function" and identifyexecutor
        or typeof(getexecutorname) == "function" and getexecutorname
    local okExec, executor = pcall(function() return identify and identify() end)
    local s, t = ctx.stats, ctx.timings

    out:line(pad("game", 12) .. (ctx.gameName or "?"))
    out:line(pad("place", 12) .. ("%d   (game %d, version %d)"):format(game.PlaceId, game.GameId, game.PlaceVersion))
    out:line(pad("server", 12) .. ("%s   players %d/%d"):format(game.JobId, #Players:GetPlayers(), Players.MaxPlayers))
    out:line(pad("executor", 12) .. (okExec and tostring(executor or "?") or "?"))
    out:line(pad("generated", 12) .. os.date("%Y-%m-%d %H:%M:%S"))
    out:line(pad("took", 12) .. ("%.1fs   walk %.1fs, hidden %.1fs, decompile %.1fs, spy %.1fs"):format(
        t.total or 0, t.walk or 0, t.hidden or 0, t.decompile or 0, t.spy or 0))
    out:line("")
    out:line(pad("instances", 12) .. ("%d walked, %d repeats folded"):format(s.instances, s.collapsed))
    out:line(pad("scripts", 12) .. ("%d decompiled, %d same as another, %d roblox default, %d server-only, %d failed, %d crash-skipped")
        :format(s.scripts, s.duplicates, s.defaults, s.serverScripts, s.failures, s.suspects))
    out:line(pad("found", 12) .. ("%d remotes, %d values, %d interactables, %d hidden"):format(
        s.remotes, s.values, s.interactables, s.hidden))
    out:line("")
    local keys = {}
    for key in pairs(Config) do keys[#keys + 1] = key end
    table.sort(keys)
    out:line("settings")
    for _, key in ipairs(keys) do
        local value = Config[key]
        out:line("  " .. pad(key, 18) .. (typeof(value) == "table" and table.concat(value, ", ") or tostring(value)))
    end
end

local function writeRemotes(ctx, out)
    table.sort(ctx.remotes, function(a, b)
        if a.parent ~= b.parent then return a.parent < b.parent end
        return a.name < b.name
    end)
    local last
    for _, remote in ipairs(ctx.remotes) do
        if remote.parent ~= last then
            if last then out:line("") end
            out:line(remote.parent)
            last = remote.parent
        end
        out:line("    " .. pad(remote.className, 22) .. remote.name)
    end
    if #ctx.remotes == 0 then out:line("none found") end
end

local function writeInteractables(ctx, out)
    local groups = {
        { "ProximityPrompt", "proximity prompts" },
        { "ClickDetector", "click detectors" },
        { "TouchTransmitter", "touch parts" },
    }
    local any = false
    for _, group in ipairs(groups) do
        local first = true
        for _, item in ipairs(ctx.interactables) do
            if item.className == group[1] then
                if first then
                    if any then out:line("") end
                    out:line(group[2])
                    first, any = false, true
                end
                if item.className == "ProximityPrompt" then
                    local ok, text = pcall(function()
                        return ("action=%q object=%q hold=%ss range=%s enabled=%s"):format(
                            item.inst.ActionText, item.inst.ObjectText, fmt(item.inst.HoldDuration),
                            fmt(item.inst.MaxActivationDistance), tostring(item.inst.Enabled))
                    end)
                    out:line("    " .. item.path .. "   " .. (ok and text or ""))
                elseif item.className == "ClickDetector" then
                    local ok, range = pcall(function() return item.inst.MaxActivationDistance end)
                    out:line("    " .. item.path .. "   range=" .. (ok and fmt(range) or "?"))
                else
                    out:line("    " .. item.path:gsub("%.TouchInterest$", ""))
                end
            end
        end
    end
    if not any then out:line("none found") end
end

local function writeHidden(ctx, out)
    for _, item in ipairs(ctx.hidden) do
        if item.note then
            out:line(item.note)
        else
            out:line(pad("[" .. item.className .. "]", 18) .. pad(item.label, 16) .. item.path)
        end
    end
    if #ctx.hidden == 0 then out:line("none found") end
end

local function writeTreeSummary(ctx, out)
    local list = {}
    for className, count in pairs(ctx.classCount) do list[#list + 1] = { className, count } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(12, #list) do parts[i] = ("%s %d"):format(list[i][1], list[i][2]) end
    out:line("most common: " .. table.concat(parts, ", "))
    out:line("")
end

-- The index rows. `bodyAt` is the line the Scripts section's first body line
-- lands on in whichever file it ends up in, so every row points at the exact
-- line of that script's header.
local function writeIndex(ctx, out, bodyAt, scriptsFile)
    local rows = ctx.index
    local written, other = {}, {}
    for _, row in ipairs(rows) do
        if row.status == "ok" then written[#written + 1] = row else other[#other + 1] = row end
    end
    out:line(("%d written below%s, %d not written"):format(#written,
        scriptsFile and (" in " .. scriptsFile) or "", #other))
    out:line("")
    out:line(padLeft("line", 7) .. padLeft("lines", 7) .. padLeft("KB", 7) .. "   " .. pad("type", 14) .. "path")
    for _, row in ipairs(written) do
        out:line(padLeft(tostring(bodyAt + row.line - 1), 7) .. padLeft(tostring(row.lines), 7)
            .. padLeft(("%.1f"):format(row.kb), 7) .. "   " .. pad(row.className, 14) .. row.path)
    end
    if #other > 0 then
        out:line("")
        out:line("not written")
        for _, row in ipairs(other) do
            local why = row.status == "same" and ("same as " .. row.sameAs)
                or row.status == "failed" and ("decompile failed: " .. (row.note or "?"))
                or row.status == "server" and "server script, never sent to the client"
                or row.status == "crash-skipped" and "crashed a previous dump - forget crash skips to retry"
                or row.status
            out:line("    " .. pad(row.className, 14) .. row.path)
            out:line("    " .. string.rep(" ", 14) .. "-> " .. why)
        end
    end
end

-- Stitches every section together behind a banner and a contents page that
-- gives each section's line, and writes it out.
local function writeOutputs(ctx)
    local sections = {}
    local function add(key, title, build, count)
        if key and not Config[key] then return end
        local out = Buffer.new()
        build(out)
        sections[#sections + 1] = { key = key or title, title = title, out = out, count = count }
        return sections[#sections]
    end

    add("Info", "GAME INFO", function(out) writeInfo(ctx, out) end)
    add("Spy", "REMOTE SPY", function(out) Spy.write(out) end)
    add("Remotes", "REMOTES", function(out) writeRemotes(ctx, out) end, #ctx.remotes)
    add("Interactables", "INTERACTABLES", function(out) writeInteractables(ctx, out) end, #ctx.interactables)
    local values = ctx.out.Values
    if Config.Values then
        if values.lines == 0 then values:line("none found") end
        sections[#sections + 1] = { key = "Values", title = "VALUES + ATTRIBUTES", out = values, count = ctx.stats.values }
    end
    add("Hidden", "HIDDEN (nil parented, loaded or running, not in the tree)", function(out) writeHidden(ctx, out) end, #ctx.hidden)
    -- the index is sized now and filled once the scripts' final line is known
    local index
    if Config.Scripts then
        index = { key = "Index", title = "SCRIPT INDEX", out = nil, count = ctx.stats.scripts }
        sections[#sections + 1] = index
    end
    if Config.Tree then
        local tree = Buffer.new()
        writeTreeSummary(ctx, tree)
        tree:block(ctx.out.Tree:text())
        sections[#sections + 1] = { key = "Tree", title = "INSTANCE TREE", out = tree, count = ctx.stats.instances }
    end
    local scripts
    if Config.Scripts then
        scripts = { key = "Scripts", title = "SCRIPTS", out = ctx.out.Scripts, count = ctx.stats.scripts }
        if scripts.out.lines == 0 then scripts.out:line("none written") end
        sections[#sections + 1] = scripts
    end

    -- a dry run of the index tells how many lines it takes, which is all the
    -- contents page needs before the real numbers exist
    if index then
        local probe = Buffer.new()
        writeIndex(ctx, probe, 1)
        index.lines = probe.lines
    end

    local function titled(section)
        return section.count and ("%s  (%d)"):format(section.title, section.count) or section.title
    end
    local gameName = ctx.gameName or "?"

    if Config.Output == "Split files" then
        local contents = Buffer.new()
        contents:line(RULE)
        contents:line(("  %s  -  %s  (place %d)"):format(VERSION, gameName, game.PlaceId))
        contents:line(RULE)
        contents:line("")
        for _, section in ipairs(sections) do
            section.file = section.key .. ".txt"
            contents:line("  " .. pad(titled(section), 60) .. section.file)
        end
        if index then
            contents:line("")
            contents:line(RULE)
            contents:line(" SCRIPT INDEX  (line numbers are in Scripts.txt)")
            contents:line(RULE)
            contents:line("")
            -- a split file has no section header, so its body starts on line 1
            writeIndex(ctx, contents, 1, "Scripts.txt")
        end
        writeChunks(filePath("Index.txt"), { contents:text() })
        for _, section in ipairs(sections) do
            if section ~= index then
                writeChunks(filePath(section.file), { section.out:text() })
            end
        end
        return folder() .. "/  (start with Index.txt)"
    end

    -- Banner + contents first. Its size is fixed by the number of sections, so
    -- every section's position is known before anything is written:
    -- a section's header takes SECTION_HEADER_LINES, its title is the third of
    -- them, and its body starts right after.
    local headLines = 5 + 4 + #sections
    local line = headLines + 1
    for number, section in ipairs(sections) do
        section.number = number
        section.titleAt = line + 2
        section.bodyAt = line + SECTION_HEADER_LINES
        local bodyLines = section == index and index.lines or section.out.lines
        line = line + SECTION_HEADER_LINES + bodyLines
    end

    local head = Buffer.new()
    head:line(RULE)
    head:line(("  %s  -  %s"):format(VERSION, gameName))
    head:line(("  place %d  -  game %d  -  version %d  -  %s"):format(game.PlaceId, game.GameId, game.PlaceVersion,
        os.date("%Y-%m-%d %H:%M")))
    head:line(RULE)
    head:line("")
    head:line("CONTENTS" .. string.rep(" ", WIDTH - 8 - 4) .. "line")
    head:line("")
    for _, section in ipairs(sections) do
        local label = ("  %d. %s "):format(section.number, titled(section))
        local at = " " .. tostring(section.titleAt)
        head:line(label .. string.rep(".", math.max(2, WIDTH - #label - #at)) .. at)
    end
    head:line("")
    head:line("")

    local chunks = { head:text() }
    for _, section in ipairs(sections) do
        local header = Buffer.new()
        sectionHeader(header, section.number, titled(section))
        if section == index then
            local body = Buffer.new()
            writeIndex(ctx, body, scripts.bodyAt)
            chunks[#chunks + 1] = header:text() .. body:text()
        else
            chunks[#chunks + 1] = header:text() .. section.out:text()
        end
    end
    local path = filePath("Dump.txt")
    writeChunks(path, chunks)
    return path
end

--// Running ----------------------------------------------------------------------------
-- `ui` receives phase(name, fraction, detail), log(text, kind) and
-- done(ok, output, summary); every field is optional.
function Dump.run(ui)
    ui = ui or {}
    local function phase(name, fraction, detail)
        if ui.phase then pcall(ui.phase, name, fraction, detail) end
    end
    local function log(text, kind)
        if ui.log then pcall(ui.log, text, kind) end
    end

    if Dump.running then return end
    if not Has.writefile then
        log("writefile is not available on this executor", "bad")
        if ui.done then pcall(ui.done, false, nil, "writefile is not available on this executor") end
        return
    end
    Dump.running, Dump.cancel = true, false
    ensureFolder()

    local ctx = newContext()
    -- a web request, so it runs alongside the walk instead of in front of it
    task.spawn(function()
        local okInfo, info = pcall(function()
            return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
        end)
        ctx.gameName = okInfo and info and info.Name or nil
    end)
    local statePath = filePath("State.txt")
    ctx.suspects = loadSuspects(statePath)
    State.open(statePath, ctx.suspects)

    local started = os.clock()
    local stats = ctx.stats
    if Config.Spy then
        Spy.start()
        log(Spy.hooked and "remote spy recording, in and out" or "remote spy recording, incoming only")
    end

    local ok, err = pcall(function()
        -- 1. walk
        Budget.start()
        local wanted = {}
        for _, name in ipairs(Config.Roots) do wanted[name] = true end
        local roots = {}
        for _, name in ipairs(ROOT_ORDER) do
            if wanted[name] then
                local okService, service = pcall(game.GetService, game, name)
                if okService and service then roots[#roots + 1] = service end
            end
        end
        for i = #roots, 1, -1 do
            ctx.stack[#ctx.stack + 1] = {
                inst = roots[i], path = roots[i].Name, depth = 0, prefix = "", isLast = i == #roots,
            }
        end
        log(("walking %d services"):format(#roots))
        local walkStart = os.clock()
        local function walkProgress()
            local done = stats.instances
            phase("walking", done / math.max(1, done + #ctx.stack),
                ("%d instances, %d scripts found"):format(done, #ctx.queue))
        end
        local stack = ctx.stack
        while #stack > 0 and not Dump.cancel do
            local frame = stack[#stack]
            stack[#stack] = nil
            visit(ctx, frame)
            Budget.check(walkProgress)
        end
        ctx.timings.walk = os.clock() - walkStart
        log(("walked %d instances in %.1fs"):format(stats.instances, ctx.timings.walk))

        -- 2. hidden scripts and remotes
        if Config.Hidden and not Dump.cancel then
            phase("hidden", 0, "nil parented, loaded and running scripts")
            local hiddenStart = os.clock()
            collectHidden(ctx)
            ctx.timings.hidden = os.clock() - hiddenStart
            log(("found %d hidden"):format(stats.hidden))
        end

        -- 3. decompile, grouped by where each script lives
        if Config.Scripts and not Dump.cancel then
            local queue = ctx.queue
            for _, item in ipairs(queue) do
                item.rank = item.hidden and 99 or (SCRIPT_ROOT_RANK[item.path:match("^[^%.]+")] or 50)
            end
            table.sort(queue, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.path < b.path
            end)
            local decompileStart = os.clock()
            log(("decompiling %d scripts"):format(#queue))
            for i, item in ipairs(queue) do
                if Dump.cancel then break end
                decompileOne(ctx, item)
                Budget.check(function()
                    phase("decompiling", i / #queue, ("%d / %d  -  %s"):format(i, #queue, item.inst.Name))
                end)
            end
            ctx.timings.decompile = os.clock() - decompileStart
            log(("decompiled %d (%d same as another, %d failed) in %.1fs"):format(
                stats.scripts, stats.duplicates, stats.failures, ctx.timings.decompile))
            if stats.failures > 0 then log(("%d scripts failed to decompile - see the index"):format(stats.failures), "bad") end
        end

        -- 4. whatever is left of the spy window
        if Config.Spy then
            local spyStart = os.clock()
            local remaining = Config.SpySeconds - (os.clock() - started)
            while remaining > 0 and not Dump.cancel do
                phase("recording remotes", 1 - remaining / math.max(1, Config.SpySeconds),
                    ("%ds left - keep playing"):format(math.ceil(remaining)))
                task.wait(0.25)
                remaining = Config.SpySeconds - (os.clock() - started)
            end
            Spy.stop()
            ctx.timings.spy = os.clock() - spyStart
        end
    end)
    if Config.Spy then Spy.stop() end

    phase("writing", 1, "")
    ctx.timings.total = os.clock() - started
    local okWrite, output = pcall(writeOutputs, ctx)

    -- Getting here at all means nothing crashed the client - even a stopped or
    -- errored run - so the attempt trail is dropped and only the scripts known
    -- to crash it stay remembered, skipped until "forget crash skips".
    do
        local lines = {}
        for path in pairs(ctx.suspects) do lines[#lines + 1] = "SUSPECT\t" .. path .. "\n" end
        pcall(writefile, statePath, table.concat(lines))
    end

    local summary = ("%d instances - %d scripts (+%d same) - %d remotes - %d values - %.1fs"):format(
        stats.instances, stats.scripts, stats.duplicates, stats.remotes, stats.values, os.clock() - started)
    Dump.running = false

    local success = ok and okWrite
    local message = not ok and ("errored: " .. tostring(err))
        or not okWrite and ("writing failed: " .. tostring(output))
        or (Dump.cancel and "stopped early, saved what it had" or "done")
    log(message, success and "good" or "bad")
    if ui.done then pcall(ui.done, success, okWrite and output or nil, summary, message) end
end

local function forgetCrashes()
    pcall(writefile, filePath("State.txt"), "")
end

env.Dumper = {
    Config = Config,
    Run = Dump.run,
    Stop = function() Dump.cancel = true end,
    ForgetCrashes = forgetCrashes,
}

--// Headless ---------------------------------------------------------------------------
if Config.NoUI then
    if Config.AutoStart then
        task.spawn(Dump.run, {
            log = function(text, kind)
                if kind == "bad" then warn("[Dumper] " .. text) else print("[Dumper] " .. text) end
            end,
            done = function(_, output, summary)
                print("[Dumper] " .. summary .. (output and ("\n[Dumper] saved to " .. output) or ""))
            end,
        })
    end
    return
end

--// UI ---------------------------------------------------------------------------------
local Void
do
    local ref = "main"
    local resolved, sha = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui2/commits/main"))
        return commit.sha
    end)
    if resolved and sha then ref = sha end
    Void = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui2/%s/VoidUI.lua"):format(ref)))()
end

local Window = Void:CreateWindow({
    Title = "dumper",
    SubTitle = VERSION,
    Keybind = Enum.KeyCode.RightShift,
    Scope = "universal",
    Status = "idle",
    StartOpen = true,
    Opener = "Topbar",
})
pcall(function() Void:SetAccent(Color3.fromRGB(255, 170, 60)) end)

local Run = {}

do
    local Tab = Window:CreateTab("dump")

    local section = Tab:CreateSection("run")
    section:Button({
        Title = "start dump",
        Half = true,
        Callback = function()
            if Dump.running then return end
            Run.start()
        end,
    })
    section:Button({
        Title = "stop",
        Half = true,
        Callback = function()
            if Dump.running then
                Dump.cancel = true
                Run.log:Append("stopping...")
            end
        end,
    })
    Run.progress = section:Progress({ Title = "progress", Default = 0 })
    Run.phase = section:Stat({ Title = "phase", Value = "idle" })
    Run.detail = section:Stat({ Title = "now", Value = "-" })
    Run.time = section:Stat({ Title = "elapsed", Value = "-" })
    Run.saved = section:Stat({ Title = "saved to", Value = "-" })
    Run.log = section:Console({ Title = "log", Height = 120, MaxLines = 60 })

    section = Tab:CreateSection("what goes in")
    local function toggle(group, title, key)
        group:Toggle({
            Title = title,
            Flag = "dumper_" .. key,
            Default = Config[key],
            Half = true,
            Callback = function(state) Config[key] = state end,
        })
    end
    toggle(section, "game info", "Info")
    toggle(section, "scripts", "Scripts")
    toggle(section, "instance tree", "Tree")
    toggle(section, "remotes", "Remotes")
    toggle(section, "values", "Values")
    toggle(section, "interactables", "Interactables")
    toggle(section, "hidden scripts", "Hidden")
    toggle(section, "attributes", "Attributes")

    section = Tab:CreateSection("remote spy")
    section:Toggle({
        Title = "record remotes while dumping",
        Flag = "dumper_Spy",
        Default = Config.Spy,
        Callback = function(state) Config.Spy = state end,
    })
    section:Slider({
        Title = "record for",
        Min = 5, Max = 180, Increment = 5, Suffix = "s",
        Default = Config.SpySeconds,
        Flag = "dumper_spy_seconds",
        Callback = function(value) Config.SpySeconds = tonumber(value) or Config.SpySeconds end,
    })
    section:Paragraph({
        Title = "how to use it",
        Content = "logs every remote the game fires and receives, with the real arguments. the dump waits out this window at the end, so play normally while it runs - use tools, attack, buy, open menus",
    })

    Tab = Window:CreateTab("options")

    section = Tab:CreateSection("speed")
    section:Segmented({
        Title = "speed",
        Values = { "Smooth", "Fast", "Max" },
        Default = Config.Speed,
        Flag = "dumper_Speed",
        Callback = function(value) if SPEEDS[value] then Config.Speed = value end end,
    })
    section:Paragraph({
        Title = "what it changes",
        Content = "how much of each frame the dump gets. smooth keeps the game playable, fast is the default, max takes most of the frame - the game stutters while it runs but it finishes soonest",
    })

    section = Tab:CreateSection("output")
    section:Segmented({
        Title = "file",
        Values = { "Single file", "Split files" },
        Default = Config.Output,
        Flag = "dumper_Output",
        Callback = function(value) Config.Output = value end,
    })
    section:Paragraph({
        Title = "what you get",
        Content = "single file writes Dumper/<place id>/Dump.txt with a contents page and a script index that give the line each part starts on. split files writes one file per section plus Index.txt",
    })

    section = Tab:CreateSection("filters")
    local function filter(title, key)
        section:Toggle({
            Title = title,
            Flag = "dumper_" .. key,
            Default = Config[key],
            Callback = function(state) Config[key] = state end,
        })
    end
    filter("skip roblox default scripts", "SkipDefaults")
    filter("one copy of identical scripts", "DedupeScripts")
    filter("only my character", "OnlyMyCharacter")
    filter("only my player", "OnlyMyPlayer")
    filter("fold 4+ identical siblings", "CollapseRepeats")
    filter("skip values inside guis", "SkipGuiValues")

    section = Tab:CreateSection("where to look")
    local roots = section:Dropdown({
        Title = "services",
        Values = ROOT_ORDER,
        Multi = true,
        Flag = "dumper_roots",
        Callback = function(list)
            if typeof(list) == "table" then Config.Roots = list end
        end,
    })
    pcall(function() roots:Set(Config.Roots) end)

    section = Tab:CreateSection("limits")
    section:Slider({
        Title = "max tree depth", Min = 4, Max = 60, Increment = 1,
        Default = Config.MaxDepth, Flag = "dumper_depth",
        Callback = function(value) Config.MaxDepth = tonumber(value) or Config.MaxDepth end,
    })
    section:Slider({
        Title = "max chars per script", Min = 10000, Max = 1000000, Increment = 10000,
        Default = Config.MaxScriptChars, Flag = "dumper_chars",
        Callback = function(value) Config.MaxScriptChars = tonumber(value) or Config.MaxScriptChars end,
    })
    section:Slider({
        Title = "decompile timeout", Min = 2, Max = 60, Increment = 1, Suffix = "s",
        Default = Config.DecompileTimeout, Flag = "dumper_timeout",
        Callback = function(value) Config.DecompileTimeout = tonumber(value) or Config.DecompileTimeout end,
    })

    section = Tab:CreateSection("crash guard")
    section:Button({
        Title = "forget crash skips",
        Confirm = true,
        ConfirmText = "Scripts that crashed a previous dump get decompiled again next run.",
        Callback = function()
            if Dump.running then return end
            forgetCrashes()
            Run.log:Append("crash skips cleared - every script gets retried")
        end,
    })
    section:Paragraph({
        Title = "what it is",
        Content = "a decompile that crashes the game is remembered, and that script is skipped on the next run so the dump can finish. this clears the list",
    })
end

function Run.start()
    local started = os.clock()
    Run.progress:Set(0)
    Run.saved:Set("-")
    Run.log:Clear()
    Window:SetStatus("dumping")
    task.spawn(Dump.run, {
        phase = function(name, fraction, detail)
            Run.phase:Set(name)
            Run.detail:Set(detail ~= "" and detail or "-")
            Run.progress:Set(math.clamp(fraction or 0, 0, 1))
            Run.time:Set(("%.1fs"):format(os.clock() - started))
            Window:SetStatus(name)
        end,
        log = function(text, kind)
            if kind == "good" then
                Run.log:Good(text)
            elseif kind == "bad" then
                Run.log:Bad(text)
            else
                Run.log:Append(text)
            end
        end,
        done = function(success, output, summary, message)
            Run.progress:Set(success and 1 or 0)
            Run.phase:Set(message or (success and "done" or "failed"))
            Run.detail:Set(summary)
            Run.time:Set(("%.1fs"):format(os.clock() - started))
            if output then Run.saved:Set(output) end
            Window:SetStatus(success and "done" or "failed")
            Void:Notify({
                Title = "dumper",
                Content = success and ("saved - " .. summary) or (message or "failed"),
                Duration = 8,
                Warn = not success,
            })
        end,
    })
end

if Config.AutoStart then Run.start() end

Void:Notify({ Title = "dumper", Content = "loaded - RightShift or the top bar button opens it", Duration = 5 })

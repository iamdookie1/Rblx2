local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

--// Executor feature detection -------------------------------------------------
local HAS_WRITEFILE = typeof(writefile) == "function"
local HAS_APPENDFILE = typeof(appendfile) == "function"
local HAS_READFILE = typeof(readfile) == "function"
local HAS_MAKEFOLDER = typeof(makefolder) == "function"
local HAS_ISFOLDER = typeof(isfolder) == "function"
local HAS_DECOMPILE = typeof(decompile) == "function"

local Config = {
    DumpScripts = true,
    DumpTree = true,
    DumpRemotes = true,
    DumpValues = true,
    MaxDepth = 14,
    MaxScriptChars = 150000,
    YieldEvery = 20,
}

-- Terrain/Camera/etc. can carry enormous or pointless child counts on big
-- games (Terrain especially - it isn't even really a container the same way,
-- but shows up in GetChildren of Workspace) - skip walking into them at all
-- rather than let them blow up the tree/instance count.
local SkipClasses = {
    Terrain = true,
}

local SEP = string.rep("=", 80)

--// Streaming file writer -------------------------------------------------------
-- The actual crash risk in a naive dumper isn't the traversal, it's holding
-- the entire multi-megabyte dump as one growing Lua string (repeated ".."
-- concatenation is O(n^2), and a big game's dump easily runs into the tens
-- of MB) and only writing it out once at the end. This buffers small chunks
-- and flushes them to disk well before that ever becomes a problem, so
-- memory use stays flat regardless of how big the game is. appendfile (true
-- incremental append) is used when available; without it, falls back to
-- read-modify-write, and only as a last resort (neither API present) does
-- it keep accumulating in memory for one final write.
local FileWriter = {}
FileWriter.__index = FileWriter

function FileWriter.new(path)
    local self = setmetatable({}, FileWriter)
    self.path = path
    self.buffer = {}
    self.bufferChars = 0
    pcall(writefile, path, "")
    return self
end

function FileWriter:write(text)
    self.buffer[#self.buffer + 1] = text
    self.bufferChars = self.bufferChars + #text
    if self.bufferChars >= 32768 then
        self:flush()
    end
end

function FileWriter:flush()
    if #self.buffer == 0 then return end
    local chunk = table.concat(self.buffer)
    self.buffer = {}
    self.bufferChars = 0

    if HAS_APPENDFILE then
        pcall(appendfile, self.path, chunk)
    elseif HAS_READFILE then
        local existing = ""
        pcall(function() existing = readfile(self.path) or "" end)
        pcall(writefile, self.path, existing .. chunk)
    else
        -- No append, no read: nothing to do but hold it and hope for the
        -- best on the final flush - this path only triggers on executors
        -- missing both APIs, which is rare.
        self._fallback = (self._fallback or "") .. chunk
        pcall(writefile, self.path, self._fallback)
    end
end

function FileWriter:close()
    self:flush()
end

--// Decompile / value helpers ---------------------------------------------------
local function tryGetFullName(inst)
    local ok, name = pcall(function() return inst:GetFullName() end)
    return ok and name or "?"
end

local function writeScriptEntry(inst, className, writer, stats)
    local fullName = tryGetFullName(inst)
    writer:write(("%s\n%s | Type: %s | Method: decompile\nLocation: %s\n%s\n\n"):format(
        SEP, inst.Name, className, fullName, SEP))

    if not HAS_DECOMPILE then
        writer:write("-- [decompile unavailable on this executor]\n\n")
        return
    end

    -- pcall only catches the decompiler erroring, not it hanging - a
    -- pathological script that makes the decompiler itself loop forever
    -- isn't something callers can preempt from Lua. Genuinely rare in
    -- practice; everything else here is what actually causes crashes.
    local ok, source = pcall(decompile, inst)
    if not ok or typeof(source) ~= "string" then
        writer:write("-- [decompile failed: " .. tostring(source) .. "]\n\n")
        stats.decompileFailures = stats.decompileFailures + 1
        return
    end

    if #source > Config.MaxScriptChars then
        source = source:sub(1, Config.MaxScriptChars)
            .. ("\n-- [...truncated, %d chars total]"):format(#source)
        stats.truncated = stats.truncated + 1
    end

    writer:write(source .. "\n\n")
    stats.scripts = stats.scripts + 1
end

local function writeRemoteEntry(inst, className, writer, stats)
    writer:write(("[%s] %s\n"):format(className, tryGetFullName(inst)))
    stats.remotes = stats.remotes + 1
end

local function writeValueEntry(inst, className, writer, stats)
    local okVal, value = pcall(function() return inst.Value end)
    if not okVal then return end
    local okStr, str = pcall(tostring, value)
    writer:write(("%-16s %-70s = %s\n"):format(className, tryGetFullName(inst), okStr and str or "<unreadable>"))
    stats.values = stats.values + 1
end

--// Roots ------------------------------------------------------------------------
local ROOT_SERVICE_NAMES = {
    "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage",
    "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "Chat",
}

local function getRoots()
    local roots = {}
    for _, name in ipairs(ROOT_SERVICE_NAMES) do
        local ok, service = pcall(function() return game:GetService(name) end)
        if ok and service then
            roots[#roots + 1] = service
        end
    end
    for _, childName in ipairs({ "Backpack", "PlayerGui", "PlayerScripts" }) do
        local ok, child = pcall(function() return LocalPlayer:FindFirstChild(childName) end)
        if ok and child then
            roots[#roots + 1] = child
        end
    end
    return roots
end

--// Traversal ---------------------------------------------------------------------
-- One iterative, explicit-stack pass over the whole tree (not a recursive
-- function - a big game's hierarchy can run deep enough to blow the Lua call
-- stack) that classifies and writes each instance to the right file as it's
-- visited, instead of collecting everything into tables first and writing at
-- the end. GetChildren() is also only ever called once per instance, instead
-- of separate tree/script/remote/value passes each re-walking the same tree.
local function pushChildren(stack, inst, depth, prefix)
    if depth >= Config.MaxDepth then return end
    local ok, children = pcall(function() return inst:GetChildren() end)
    if not ok then return end

    local filtered = {}
    for _, child in ipairs(children) do
        local okClass, className = pcall(function() return child.ClassName end)
        if okClass and not SkipClasses[className] then
            filtered[#filtered + 1] = child
        end
    end

    for i = #filtered, 1, -1 do
        stack[#stack + 1] = {
            inst = filtered[i],
            depth = depth,
            prefix = prefix,
            isLast = (i == #filtered),
        }
    end
end

local function runDump(writers, progress, isCancelled)
    local stats = { instances = 0, scripts = 0, remotes = 0, values = 0, decompileFailures = 0, truncated = 0 }

    local stack = {}
    local roots = getRoots()
    for i = #roots, 1, -1 do
        stack[#stack + 1] = { inst = roots[i], depth = 0, prefix = "", isLast = (i == 1) }
    end

    local processed = 0
    while #stack > 0 do
        if isCancelled() then break end

        local frame = stack[#stack]
        stack[#stack] = nil

        local inst = frame.inst
        local okName, name = pcall(function() return inst.Name end)
        local okClass, className = pcall(function() return inst.ClassName end)

        if okName and okClass then
            stats.instances = stats.instances + 1
            processed = processed + 1

            if Config.DumpTree then
                local branch = frame.depth == 0 and "" or (frame.isLast and "`-- " or "|-- ")
                writers.tree:write(frame.prefix .. branch .. name .. " (" .. className .. ")\n")
            end

            if Config.DumpScripts and (className == "Script" or className == "LocalScript" or className == "ModuleScript") then
                writeScriptEntry(inst, className, writers.scripts, stats)
            elseif Config.DumpRemotes and (className == "RemoteEvent" or className == "RemoteFunction"
                or className == "BindableEvent" or className == "BindableFunction") then
                writeRemoteEntry(inst, className, writers.remotes, stats)
            elseif Config.DumpValues and className:match("Value$") then
                writeValueEntry(inst, className, writers.values, stats)
            end

            local childPrefix = frame.prefix
            if frame.depth > 0 then
                childPrefix = childPrefix .. (frame.isLast and "    " or "|   ")
            end
            pushChildren(stack, inst, frame.depth + 1, childPrefix)

            if processed % Config.YieldEvery == 0 then
                task.wait()
                progress(stats, #stack)
            end
        end
    end

    progress(stats, #stack)
    return stats
end

--// UI -----------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'game dumper',
    SubTitle = 'scripts / tree / remotes / values',
    Folder = 'GameDumper',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 170, 60),
})

local Tab = Window:Tab({ Title = 'dumper', Icon = 'download' })
local Options = Tab:Section({ Title = 'what to dump', Side = 'left' })

Options:Toggle({
    Title = 'scripts',
    Flag = 'gd_scripts',
    Default = true,
    Callback = function(v) Config.DumpScripts = v end,
})

Options:Toggle({
    Title = 'workspace tree',
    Flag = 'gd_tree',
    Default = true,
    Callback = function(v) Config.DumpTree = v end,
})

Options:Toggle({
    Title = 'remotes',
    Flag = 'gd_remotes',
    Default = true,
    Callback = function(v) Config.DumpRemotes = v end,
})

Options:Toggle({
    Title = 'value snapshot',
    Flag = 'gd_values',
    Default = true,
    Callback = function(v) Config.DumpValues = v end,
})

local Limits = Tab:Section({ Title = 'limits', Side = 'right' })

Limits:Slider({
    Title = 'max tree depth',
    Flag = 'gd_max_depth',
    Min = 4,
    Max = 30,
    Increment = 1,
    Default = 14,
    Callback = function(v) Config.MaxDepth = v end,
})

Limits:Slider({
    Title = 'max chars per script',
    Flag = 'gd_max_script_chars',
    Min = 10000,
    Max = 500000,
    Increment = 10000,
    Default = 150000,
    Callback = function(v) Config.MaxScriptChars = v end,
})

Limits:Paragraph({
    Title = 'why this exists',
    Text = 'Streams output to disk in small chunks instead of building one giant string in memory, yields every few instances instead of running one unbroken loop, and walks the tree iteratively instead of recursively - the actual reasons a dumper crashes on big games.',
})

local Run = Tab:Section({ Title = 'run', Side = 'left' })
local StatusLabel = Run:Label({ Title = 'status: idle' })
local CountLabel = Run:Label({ Title = 'instances: 0  scripts: 0  remotes: 0  values: 0' })

local dumping = false
local cancelRequested = false

local StartButton, StopButton

local function setRunning(state)
    dumping = state
    cancelRequested = false
end

StartButton = Run:Button({
    Title = 'start dump',
    Callback = function()
        if dumping then return end
        if not HAS_WRITEFILE then
            Centrl:Notify({ Title = 'game dumper', Content = 'writefile is not available on this executor.', Type = 'error', Duration = 5 })
            return
        end

        setRunning(true)
        StatusLabel:Set('status: running')

        task.spawn(function()
            local folder = ('GameDump_%d_%s'):format(game.PlaceId, os.date('%Y%m%d_%H%M%S'))
            if HAS_MAKEFOLDER and not (HAS_ISFOLDER and isfolder(folder)) then
                pcall(makefolder, folder)
            end

            -- Without makefolder, a path like "<folder>/Scripts.txt" points
            -- at a directory that was never created and writefile would
            -- just fail into it silently - flatten to "<folder>_Scripts.txt"
            -- instead so output still lands somewhere real.
            local function filePath(name)
                if HAS_MAKEFOLDER then
                    return folder .. '/' .. name
                end
                return folder .. '_' .. name
            end

            local writers = {
                scripts = FileWriter.new(filePath('Scripts.txt')),
                tree = FileWriter.new(filePath('Tree.txt')),
                remotes = FileWriter.new(filePath('Remotes.txt')),
                values = FileWriter.new(filePath('Values.txt')),
            }

            local startTime = os.clock()
            local ok, stats = pcall(runDump, writers, function(s, queued)
                CountLabel:Set(('instances: %d  scripts: %d  remotes: %d  values: %d  (queued: %d)')
                    :format(s.instances, s.scripts, s.remotes, s.values, queued))
            end, function() return cancelRequested end)

            for _, writer in pairs(writers) do
                writer:close()
            end

            local duration = os.clock() - startTime
            local summary = FileWriter.new(filePath('Summary.txt'))
            if ok then
                summary:write(("Place: %d\nGenerated: %s\nDuration: %.1fs\nCancelled: %s\n\n"):format(
                    game.PlaceId, os.date('%Y-%m-%d %H:%M:%S'), duration, tostring(cancelRequested)))
                summary:write(("Instances: %d\nScripts decompiled: %d\nDecompile failures: %d\nTruncated scripts: %d\nRemotes: %d\nValues: %d\n"):format(
                    stats.instances, stats.scripts, stats.decompileFailures, stats.truncated, stats.remotes, stats.values))
                summary:close()

                StatusLabel:Set(cancelRequested and 'status: cancelled' or 'status: done')
                Centrl:Notify({
                    Title = 'game dumper',
                    Content = ('Saved to %s (%d instances, %.1fs)'):format(folder, stats.instances, duration),
                    Type = 'success',
                    Duration = 6,
                })
            else
                summary:write('Dump errored: ' .. tostring(stats) .. '\n')
                summary:close()
                StatusLabel:Set('status: error')
                Centrl:Notify({ Title = 'game dumper', Content = 'Dump failed: ' .. tostring(stats), Type = 'error', Duration = 8 })
            end

            setRunning(false)
        end)
    end,
})

StopButton = Run:Button({
    Title = 'stop',
    Callback = function()
        if not dumping then return end
        cancelRequested = true
        StatusLabel:Set('status: stopping...')
    end,
})

Window:Load()

Centrl:Notify({
    Title = 'game dumper',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

--// Executor feature detection -------------------------------------------------
local HAS_WRITEFILE = typeof(writefile) == "function"
local HAS_APPENDFILE = typeof(appendfile) == "function"
local HAS_READFILE = typeof(readfile) == "function"
local HAS_MAKEFOLDER = typeof(makefolder) == "function"
local HAS_ISFOLDER = typeof(isfolder) == "function"
local HAS_ISFILE = typeof(isfile) == "function"
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

function FileWriter.new(path, opts)
    opts = opts or {}
    local self = setmetatable({}, FileWriter)
    self.path = path
    self.buffer = {}
    self.bufferChars = 0
    self.flushThreshold = opts.flushThreshold or 32768
    -- truncate defaults to true (fresh file); pass truncate = false to keep
    -- whatever's already on disk, which is what resuming a crashed dump
    -- needs - the new run's writes should land after the old ones, not wipe
    -- them.
    if opts.truncate ~= false then
        pcall(writefile, path, "")
    end
    return self
end

function FileWriter:write(text)
    self.buffer[#self.buffer + 1] = text
    self.bufferChars = self.bufferChars + #text
    if self.bufferChars >= self.flushThreshold then
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

-- Crash-survivable progress: DONE/ATTEMPT lines keyed by an instance's
-- FullName (the only identity that survives a client restart - object
-- references don't). An ATTEMPT with no matching DONE means a previous run
-- started decompiling that instance and never got the chance to record
-- success, which is the strongest signal available for "this is probably
-- what took the client down" - so it gets treated as a crash suspect and
-- skipped instead of retried. Fully finished instances (DONE) are skipped
-- too, so a resumed run doesn't redo work or risk hitting the same crash a
-- second time before it even gets back to where it died.
local function loadState(path)
    local doneSet, attempted, doneCount = {}, {}, 0
    local canRead = HAS_READFILE and (not HAS_ISFILE or isfile(path))
    if canRead then
        local ok, content = pcall(readfile, path)
        if ok and typeof(content) == "string" then
            for line in content:gmatch("[^\r\n]+") do
                local tag, name = line:match("^(%a+)\t(.+)$")
                if tag == "DONE" and not doneSet[name] then
                    doneSet[name] = true
                    doneCount = doneCount + 1
                elseif tag == "ATTEMPT" then
                    attempted[name] = true
                end
            end
        end
    end

    local crashSuspects = {}
    for name in pairs(attempted) do
        if not doneSet[name] then
            crashSuspects[name] = true
        end
    end

    return doneSet, crashSuspects, doneCount
end

local function writeScriptEntry(inst, className, writer, stats, fullName, stateWriter, isSuspect)
    writer:write(("%s\n%s | Type: %s | Method: decompile\nLocation: %s\n%s\n\n"):format(
        SEP, inst.Name, className, fullName, SEP))

    if not HAS_DECOMPILE then
        writer:write("-- [decompile unavailable on this executor]\n\n")
        return
    end

    if isSuspect then
        writer:write("-- [skipped: this instance was mid-decompile when a previous dump attempt crashed, so it's assumed to be the cause and left un-decompiled]\n\n")
        stats.suspectsSkipped = stats.suspectsSkipped + 1
        return
    end

    -- Flushed to disk immediately, before decompile runs - if decompiling
    -- this specific instance is what takes the whole client down, this line
    -- is what lets the next run recognize it and skip it instead of dying
    -- in the same place again.
    if stateWriter then
        stateWriter:write("ATTEMPT\t" .. fullName .. "\n")
        stateWriter:flush()
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

local function writeRemoteEntry(inst, className, writer, stats, fullName)
    writer:write(("[%s] %s\n"):format(className, fullName))
    stats.remotes = stats.remotes + 1
end

local function writeValueEntry(inst, className, writer, stats, fullName)
    local okVal, value = pcall(function() return inst.Value end)
    if not okVal then return end
    local okStr, str = pcall(tostring, value)
    writer:write(("%-16s %-70s = %s\n"):format(className, fullName, okStr and str or "<unreadable>"))
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

local function runDump(writers, progress, isCancelled, doneSet, crashSuspects)
    local stats = {
        instances = 0, scripts = 0, remotes = 0, values = 0,
        decompileFailures = 0, truncated = 0, skippedDuplicates = 0,
        resumedSkipped = 0, suspectsSkipped = 0,
    }

    -- Roots overlap on purpose (Players contains LocalPlayer, which already
    -- has Backpack/PlayerGui/PlayerScripts as real children before we also
    -- list them as their own roots for convenience) and a big, active game
    -- can reparent things mid-scan, so the same instance can genuinely turn
    -- up twice. Weak-keyed so an entry stops pinning memory the moment the
    -- instance itself is actually gone (destroyed and unreferenced
    -- elsewhere) instead of holding every instance we've ever seen alive
    -- in our own table for the rest of a long run - remembers just long
    -- enough to dedupe, forgets as soon as that's no longer needed.
    local visited = setmetatable({}, { __mode = "k" })

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

        if okName and okClass and visited[inst] then
            stats.skippedDuplicates = stats.skippedDuplicates + 1
        elseif okName and okClass then
            visited[inst] = true
            stats.instances = stats.instances + 1
            processed = processed + 1

            local fullName = tryGetFullName(inst)
            local alreadyDone = doneSet and doneSet[fullName]

            if alreadyDone then
                stats.resumedSkipped = stats.resumedSkipped + 1
            else
                if Config.DumpTree then
                    local branch = frame.depth == 0 and "" or (frame.isLast and "`-- " or "|-- ")
                    writers.tree:write(frame.prefix .. branch .. name .. " (" .. className .. ")\n")
                end

                if Config.DumpScripts and (className == "Script" or className == "LocalScript" or className == "ModuleScript") then
                    local isSuspect = crashSuspects and crashSuspects[fullName]
                    writeScriptEntry(inst, className, writers.scripts, stats, fullName, writers.state, isSuspect)
                elseif Config.DumpRemotes and (className == "RemoteEvent" or className == "RemoteFunction"
                    or className == "BindableEvent" or className == "BindableFunction") then
                    writeRemoteEntry(inst, className, writers.remotes, stats, fullName)
                elseif Config.DumpValues and className:match("Value$") then
                    writeValueEntry(inst, className, writers.values, stats, fullName)
                end

                -- Marks the instance fully handled regardless of type - not
                -- just scripts - so a resumed run can skip straight past
                -- everything already written on the tree/remote/value side
                -- too, not only the decompile-risk path.
                if writers.state then
                    writers.state:write("DONE\t" .. fullName .. "\n")
                end
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
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib3.lua'))()

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

local function dumpFolder()
    -- Stable per-place name (no timestamp) is what makes resuming possible -
    -- a crashed run and the retry that resumes it need to land in the same
    -- folder and see the same State.txt.
    return ('GameDump_%d'):format(game.PlaceId)
end

local function dumpFilePath(name)
    local folder = dumpFolder()
    if HAS_MAKEFOLDER then
        return folder .. '/' .. name
    end
    return folder .. '_' .. name
end

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
            local folder = dumpFolder()
            if HAS_MAKEFOLDER and not (HAS_ISFOLDER and isfolder(folder)) then
                pcall(makefolder, folder)
            end

            local statePath = dumpFilePath('State.txt')
            local doneSet, crashSuspects, doneCount = loadState(statePath)
            local resuming = doneCount > 0

            if resuming then
                StatusLabel:Set('status: resuming previous dump')
                Centrl:Notify({
                    Title = 'game dumper',
                    Content = ('Resuming previous dump - %d instance(s) already done will be skipped.'):format(doneCount),
                    Type = 'info',
                    Duration = 6,
                })
            end

            -- Resuming means appending past what's already on disk, not
            -- wiping it - only a fresh (non-resumed) run truncates.
            local writers = {
                scripts = FileWriter.new(dumpFilePath('Scripts.txt'), { truncate = not resuming }),
                tree = FileWriter.new(dumpFilePath('Tree.txt'), { truncate = not resuming }),
                remotes = FileWriter.new(dumpFilePath('Remotes.txt'), { truncate = not resuming }),
                values = FileWriter.new(dumpFilePath('Values.txt'), { truncate = not resuming }),
                state = FileWriter.new(statePath, { truncate = not resuming, flushThreshold = 512 }),
            }

            local startTime = os.clock()
            local ok, stats = pcall(runDump, writers, function(s, queued)
                CountLabel:Set(('instances: %d  scripts: %d  remotes: %d  values: %d  dupes: %d  resumed: %d  suspects: %d  (queued: %d)')
                    :format(s.instances, s.scripts, s.remotes, s.values, s.skippedDuplicates, s.resumedSkipped, s.suspectsSkipped, queued))
            end, function() return cancelRequested end, doneSet, crashSuspects)

            for _, writer in pairs(writers) do
                writer:close()
            end

            local duration = os.clock() - startTime
            local summary = FileWriter.new(dumpFilePath('Summary.txt'))
            if ok then
                summary:write(("Place: %d\nGenerated: %s\nDuration: %.1fs\nCancelled: %s\nResumed: %s\n\n"):format(
                    game.PlaceId, os.date('%Y-%m-%d %H:%M:%S'), duration, tostring(cancelRequested), tostring(resuming)))
                summary:write(("Instances: %d\nDuplicate visits skipped: %d\nAlready-done (resumed) skipped: %d\nCrash-suspect scripts skipped: %d\nScripts decompiled: %d\nDecompile failures: %d\nTruncated scripts: %d\nRemotes: %d\nValues: %d\n"):format(
                    stats.instances, stats.skippedDuplicates, stats.resumedSkipped, stats.suspectsSkipped,
                    stats.scripts, stats.decompileFailures, stats.truncated, stats.remotes, stats.values))
                summary:close()

                local finishedClean = not cancelRequested
                if finishedClean then
                    -- The "forget" half: a dump that actually finished
                    -- doesn't need its crash-resume trail anymore, so clear
                    -- it - otherwise a later, genuinely fresh dump would
                    -- silently skip everything as "already done".
                    pcall(writefile, statePath, "")
                end

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

Run:Button({
    Title = 'reset progress',
    Callback = function()
        if dumping then return end
        if not HAS_WRITEFILE then return end

        for _, name in ipairs({ 'State.txt', 'Scripts.txt', 'Tree.txt', 'Remotes.txt', 'Values.txt', 'Summary.txt' }) do
            pcall(writefile, dumpFilePath(name), "")
        end

        StatusLabel:Set('status: idle')
        CountLabel:Set('instances: 0  scripts: 0  remotes: 0  values: 0')
        Centrl:Notify({
            Title = 'game dumper',
            Content = 'Progress cleared - next dump starts fresh.',
            Type = 'success',
            Duration = 4,
        })
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

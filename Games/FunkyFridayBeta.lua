--// [MADNESS] Funky Friday -- beta autoplayer (WindUI).
--
-- Auto play, with how often each judgement comes out (Sick / Good / Ok / Bad /
-- Miss chances, or perfect 0.00ms hits) and how long a key stays down after a
-- hit. It runs on its own, separate from the full script (Games/FunkyFriday.lua):
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Games/FunkyFridayBeta.lua'))()
--
-- How it plays (the full script's game mode): hits are judged on the client.
-- Lane:Hit(isKeyDown, timestamp) turns the os.clock() of a press into a song
-- time with the playback sample and the HitboxOffset setting, and anything
-- within 50ms of the note is a Sick, 100ms a Good, 150ms an Ok, and anything
-- inside its 200ms window a Bad. The worker reads the real notes (time,
-- length, type) out of the game and calls Field:HitLane with the timestamp
-- each note is due, moved by the judgement rolled for it, worked out ahead of
-- the frame so frame rate doesn't matter. A rolled Miss leaves the note alone. Hold notes are held their full length; Death, Poison and
-- Mechanic notes are left alone. The game's modules live in
-- PlayerScripts.ClientActor, so the worker runs there through run_on_actor, or
-- here when getgc can see them.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__FunkyFridayBetaStop) == "function" then pcall(Genv.__FunkyFridayBetaStop) end

-- Settings go to the worker (in whichever VM it runs) as attributes on a
-- folder both VMs can see.
local Bridge = Instance.new("Folder")
Bridge.Name = "FFB_" .. HttpService:GenerateGUID(false):sub(1, 8)
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    Bridge.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end
Bridge:SetAttribute("Enabled", false)

local Auto = {
    Enabled = false,
    -- how often each judgement comes out, as weights (they don't need to add
    -- up to 100). all Sick by default.
    Chance = { Sick = 100, Good = 0, Ok = 0, Bad = 0, Miss = 0 },
    Perfect = false,       -- every hit dead on the note: 0.00ms
    -- how long a key stays down after hitting a normal note (hold notes are
    -- always held for their full length)
    PressHold = true,      -- off lets go straight away
    PressHoldMs = 60,
    PressRandom = false,   -- vary it per note
    PressRandomRange = 30, -- % either side of PressHoldMs
}
local GRADE_ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }

local function pushSettings()
    Bridge:SetAttribute("Enabled", Auto.Enabled)
    Bridge:SetAttribute("Perfect", Auto.Perfect)
    Bridge:SetAttribute("PressHold", Auto.PressHold)
    Bridge:SetAttribute("PressHoldMs", Auto.PressHoldMs)
    Bridge:SetAttribute("PressRandom", Auto.PressRandom)
    Bridge:SetAttribute("PressRandomRange", Auto.PressRandomRange)
    for _, name in ipairs(GRADE_ORDER) do
        Bridge:SetAttribute("Chance" .. name, Auto.Chance[name] or 0)
    end
end
pushSettings()

local WORKER = [==[
local BRIDGE_NAME = "__BRIDGE__"
local WORKER_ID = "__WORKER__"
local RunService = game:GetService("RunService")

local bridge
for _, getRoot in ipairs({
    function() return gethui and gethui() end,
    function() return game:GetService("CoreGui") end,
    function() return game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui") end,
}) do
    local ok, root = pcall(getRoot)
    if ok and root then
        bridge = root:FindFirstChild(BRIDGE_NAME)
        if bridge then break end
    end
end
if not bridge then return end

local function attr(name, default)
    local value = bridge:GetAttribute(name)
    if value == nil then return default end
    return value
end

-- the game's framework table: VSRG (with the InputHandler that knows your
-- field) and the SettingsHandler
local function findFramework()
    if typeof(getgc) ~= "function" then return nil end
    local ok, objects = pcall(getgc, true)
    if not ok then return nil end
    for _, value in ipairs(objects) do
        if type(value) == "table" then
            local vsrg = rawget(value, "VSRG")
            if type(vsrg) == "table" and type(rawget(value, "SettingsHandler")) == "table"
                and type(rawget(vsrg, "InputHandler")) == "table" then
                return value
            end
        end
    end
    return nil
end

local Framework
local nextSearch = 0
local Lanes = {}   -- lane -> { Down, Hold, ReleaseAt (song time), LastPress }
local Planned = setmetatable({}, { __mode = "k" }) -- note -> true pressed / false left alone
local Offsets = setmetatable({}, { __mode = "k" }) -- note -> timing error, rolled once
local lastField
local rng = Random.new()

-- timing error for each judgement, in ms either side of the note, kept clear
-- of the game's 50 / 100 / 150 / 200ms edges
local GRADES = {
    Sick = { 0, 30 }, Good = { 60, 90 }, Ok = { 110, 140 }, Bad = { 160, 190 },
}
local ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }

local function chance(name)
    return math.max(tonumber(attr("Chance" .. name, name == "Sick" and 100 or 0)) or 0, 0)
end

-- rolls a judgement by the chances: the timing error in seconds, or nil for
-- a miss (the note is left alone)
local function rollOffset()
    -- perfect: the press is stamped to the note's own time, which Lane:Hit
    -- turns back into exactly that song time, so the game judges it 0.00ms
    if attr("Perfect", false) then return 0 end
    local total = 0
    for _, name in ipairs(ORDER) do total += chance(name) end
    if total <= 0 then return 0 end
    local roll = rng:NextNumber(0, total)
    local pick = "Sick"
    for _, name in ipairs(ORDER) do
        roll -= chance(name)
        if roll <= 0 then
            pick = name
            break
        end
    end
    if pick == "Miss" then return nil end
    local band = GRADES[pick]
    local ms = rng:NextNumber(band[1], band[2])
    if rng:NextNumber() < 0.5 then ms = -ms end
    return ms / 1000
end

-- seconds a key stays down after a normal note, cut short when the next note
-- in the lane comes sooner
local function tapLength()
    if not attr("PressHold", true) then return 0.001 end
    local ms = tonumber(attr("PressHoldMs", 60)) or 60
    local range = attr("PressRandom", false) and (tonumber(attr("PressRandomRange", 0)) or 0) or 0
    if range > 0 then
        local spread = ms * range / 100
        ms = rng:NextNumber(math.max(ms - spread, 1), ms + spread)
    end
    return math.max(ms, 1) / 1000
end

local function ignored(note)
    local kind = type(note.NoteData) == "table" and note.NoteData.Type
    if not kind then return false end
    local configs = Framework.Configs
    local list = configs and configs.VSRG and configs.VSRG.IgnoredNoteTypes or { "Death", "Poison", "Mechanic" }
    return table.find(list, kind) ~= nil
end

local function releaseAll(field)
    for lane, state in pairs(Lanes) do
        if state.Down then pcall(field.HitLane, field, lane, false, os.clock()) end
    end
    table.clear(Lanes)
end

local function hitboxOffset()
    local ok, value = pcall(function() return Framework.SettingsHandler:Get("HitboxOffset") end)
    return ok and tonumber(value) or 0
end

local candidates = {}
local function byTime(a, b) return a.Time < b.Time end

local connection
connection = RunService.Heartbeat:Connect(function(dt)
    if not bridge.Parent or attr("Stop", false) then
        if lastField then pcall(releaseAll, lastField) end
        connection:Disconnect()
        return
    end
    local owner = bridge:GetAttribute("Owner")
    if owner and owner ~= WORKER_ID then
        connection:Disconnect()
        return
    end
    local playing = attr("Enabled", false)
    if not playing then
        if lastField then
            pcall(releaseAll, lastField)
            lastField = nil
        end
        return
    end

    if not Framework then
        if os.clock() < nextSearch then return end
        nextSearch = os.clock() + 3
        Framework = findFramework()
        if not Framework then return end
        if bridge:GetAttribute("Owner") then
            connection:Disconnect()
            return
        end
        bridge:SetAttribute("Owner", WORKER_ID)
        bridge:SetAttribute("Where", WORKER_ID)
    end

    local handler = Framework.VSRG and Framework.VSRG.InputHandler
    local field = handler and handler.Field
    if field ~= lastField then
        if lastField then pcall(releaseAll, lastField) end
        lastField = field
        Planned = setmetatable({}, { __mode = "k" })
        Offsets = setmetatable({}, { __mode = "k" })
    end
    local song = field and field.Game
    if not song or song.Ending or type(field.Lanes) ~= "table" then
        if bridge:GetAttribute("Status") ~= "waiting for a song" then bridge:SetAttribute("Status", "waiting for a song") end
        return
    end
    if bridge:GetAttribute("Status") ~= "playing" then bridge:SetAttribute("Status", "playing") end

    local sample = song.TimePositionSample
    local samplePos = sample and sample.Position or song.TimePosition
    if type(samplePos) ~= "number" then return end
    local sampleClock = sample and sample.Clock or os.clock()
    local playback = song.AdjustedPlayback or 1
    local now = samplePos + (os.clock() - sampleClock) * playback
    local hitbox = hitboxOffset() / 1000
    -- everything due before the next frame goes out now, each press stamped
    -- with its own moment, so the game judges it as if it came exactly then
    local horizon = now + math.max(dt, 1 / 240) * 1.5 * playback

    local function stamp(songTime)
        return sampleClock + (songTime - samplePos - hitbox) / playback
    end

    for lane, laneObject in pairs(field.Lanes) do
        local state = Lanes[lane]
        if not state then
            state = { Down = false, Hold = false, ReleaseAt = 0, LastPress = -math.huge }
            Lanes[lane] = state
        end

        table.clear(candidates)
        if type(laneObject) == "table" and type(laneObject.Notes) == "table" then
            for _, note in pairs(laneObject.Notes) do
                if type(note) == "table" and not note.Hit and not note.Cleaned and type(note.Time) == "number"
                    and Planned[note] == nil and note.Time > now - 0.18 then
                    candidates[#candidates + 1] = note
                end
            end
        end
        table.sort(candidates, byTime)

        local index = 1
        for _ = 1, 256 do
            local note = candidates[index]
            local pressAt
            if note then
                local offset = Offsets[note]
                if offset == nil then
                    if ignored(note) then
                        Planned[note] = false
                        index += 1
                        continue
                    end
                    offset = rollOffset()
                    if not offset then
                        Planned[note] = false
                        index += 1
                        continue
                    end
                    Offsets[note] = offset
                end
                -- presses in a lane never go back in time on tightly packed notes
                pressAt = math.max(note.Time + offset, state.LastPress + 0.001)
            end

            if state.Down then
                local releaseAt = state.ReleaseAt
                if not state.Hold and pressAt and pressAt <= horizon then
                    -- the next note comes before this tap would let go
                    releaseAt = math.min(releaseAt, (state.LastPress + pressAt) / 2)
                end
                if releaseAt <= horizon then
                    pcall(field.HitLane, field, lane, false, stamp(math.max(releaseAt, state.LastPress)))
                    state.Down = false
                else
                    break
                end
            end

            if not note or pressAt > horizon then break end
            pcall(field.HitLane, field, lane, true, stamp(pressAt))
            Planned[note] = true
            state.Down = true
            state.LastPress = pressAt
            local length = tonumber(note.Length) or 0
            state.Hold = length > 0
            state.ReleaseAt = state.Hold and (note.Time + length) or (pressAt + tapLength())
            index += 1
        end
    end
end)
]==]

local Workers = { Here = false, Actor = false }

local function findActor()
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
    local actor = scripts and scripts:FindFirstChild("ClientActor")
    if not actor and typeof(getactors) == "function" then
        local ok, list = pcall(getactors)
        if ok and type(list) == "table" then
            for _, candidate in ipairs(list) do
                if candidate.Name == "ClientActor" then return candidate end
            end
        end
    end
    return actor
end

-- One worker here, one in the actor when the executor can; whichever finds
-- the game first plays and the other stops. They start when auto play is
-- first turned on, and the actor one is tried again until it's in: run too
-- early (in the loading screen) ClientActor isn't there yet, and the worker
-- here can't see the game's modules on its own, so auto play never started.
local function startWorkers()
    if not Workers.Here and typeof(getgc) == "function" then
        local fn = loadstring(WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "ThisVM"))
        if fn then
            task.spawn(fn)
            Workers.Here = true
        end
    end

    local run = (typeof(run_on_actor) == "function" and run_on_actor)
        or (type(syn) == "table" and typeof(syn.run_on_actor) == "function" and syn.run_on_actor)
    if not Workers.Actor and run then
        local actor = findActor()
        if actor and pcall(run, actor, (WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "Actor"))) then
            Workers.Actor = true
        end
    end
    return Workers.Here or Workers.Actor
end

local canPlay = typeof(getgc) == "function" or typeof(run_on_actor) == "function"
    or (type(syn) == "table" and typeof(syn.run_on_actor) == "function")

local Unloaded = false
local Window -- the menu, made below

local function shutdown()
    if Unloaded then return end
    Unloaded = true
    Auto.Enabled = false
    pcall(function() Bridge:SetAttribute("Enabled", false) end)
    pcall(function() Bridge:SetAttribute("Stop", true) end)
    -- the workers see Stop on their next frame, let go of any held lane, and quit
    task.delay(0.5, function() pcall(function() Bridge:Destroy() end) end)
    -- the old menu goes too: a second load used to leave it up, and its auto
    -- play toggle then pointed at a bridge that was gone, so it did nothing
    if Window then pcall(function() Window:Destroy() end) end
    if Genv.__FunkyFridayBetaStop == shutdown then Genv.__FunkyFridayBetaStop = nil end
end
Genv.__FunkyFridayBetaStop = shutdown

-- the actor may turn up after the script ran, so keep trying it
task.spawn(function()
    while not Unloaded do
        if Auto.Enabled and not Bridge:GetAttribute("Owner") then startWorkers() end
        task.wait(1)
    end
end)

--// ui ------------------------------------------------------------------------

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
if Unloaded then return end -- loaded again while this one was still fetching the menu

Window = WindUI:CreateWindow({
    Title = "Funky Friday",
    Author = "beta",
    Icon = "music",
    Folder = "FunkyFridayBeta",
    Size = UDim2.fromOffset(480, 300),
})

local Tab = Window:Tab({ Title = "Main", Icon = "music" })

Tab:Toggle({
    Title = "Auto play",
    Desc = "Hits the notes by the chances below",
    Value = false,
    Callback = function(state)
        if Unloaded then return end
        Auto.Enabled = state == true
        if Auto.Enabled then startWorkers() end
        pushSettings()
        if state and not canPlay then
            WindUI:Notify({
                Title = "Funky Friday",
                Content = "Your executor needs getgc or run_on_actor for auto play.",
                Duration = 6,
            })
        end
    end,
})

local statusText = Tab:Paragraph({ Title = "Status", Desc = "off" })
task.spawn(function()
    local last
    while not Unloaded do
        local text
        if not Auto.Enabled then
            text = "off"
        elseif not Bridge:GetAttribute("Where") then
            text = (Workers.Here or Workers.Actor) and "looking for the game..." or "waiting for the game's actor..."
        else
            text = tostring(Bridge:GetAttribute("Status") or "waiting for a song")
        end
        if text ~= last then
            last = text
            pcall(function() statusText:SetDesc(text) end)
        end
        task.wait(0.5)
    end
end)

local Judge = Window:Tab({ Title = "Judgements", Icon = "dices" })

local share = Judge:Paragraph({
    Title = "How often each judgement comes out",
    Desc = "",
})

-- the chances work as weights, so this shows what they come to
local function showShare()
    local total = 0
    for _, name in ipairs(GRADE_ORDER) do total += math.max(Auto.Chance[name] or 0, 0) end
    local parts = {}
    for _, name in ipairs(GRADE_ORDER) do
        local pct = total > 0 and (math.max(Auto.Chance[name] or 0, 0) / total * 100) or (name == "Sick" and 100 or 0)
        if pct > 0 then parts[#parts + 1] = ("%s %.0f%%"):format(name, pct) end
    end
    local text = Auto.Perfect and "Perfect: every hit 0.00ms" or ("Weights, they don't have to add up to 100. Now: " .. table.concat(parts, ", "))
    pcall(function() share:SetDesc(text) end)
end

Judge:Toggle({
    Title = "Perfect hits (0.00ms)",
    Desc = "Every note dead on its time, over the chances below",
    Value = Auto.Perfect,
    Callback = function(state)
        Auto.Perfect = state == true
        pushSettings()
        showShare()
    end,
})

for _, name in ipairs(GRADE_ORDER) do
    Judge:Slider({
        Title = name .. " %",
        Step = 1,
        Value = { Min = 0, Max = 100, Default = Auto.Chance[name] },
        Callback = function(value)
            Auto.Chance[name] = tonumber(value) or 0
            pushSettings()
            showShare()
        end,
    })
end
showShare()

local Hold = Window:Tab({ Title = "Key hold", Icon = "hand" })

Hold:Paragraph({
    Title = "Key hold after a hit",
    Desc = "How long the key stays down after hitting a normal note. It always lets go before the next note in the same lane, so fast streams still work. Hold notes are always held for their full length.",
})

Hold:Toggle({
    Title = "Hold the key",
    Desc = "Off lets go straight away",
    Value = Auto.PressHold,
    Callback = function(state)
        Auto.PressHold = state == true
        pushSettings()
    end,
})

Hold:Slider({
    Title = "Hold for (ms)",
    Step = 1,
    Value = { Min = 1, Max = 300, Default = Auto.PressHoldMs },
    Callback = function(value)
        Auto.PressHoldMs = tonumber(value) or Auto.PressHoldMs
        pushSettings()
    end,
})

Hold:Toggle({
    Title = "Randomize",
    Desc = "Each hit holds a different length, within the range below",
    Value = Auto.PressRandom,
    Callback = function(state)
        Auto.PressRandom = state == true
        pushSettings()
    end,
})

Hold:Slider({
    Title = "Random range (%)",
    Desc = "60ms with a 50% range holds each hit between 30ms and 90ms",
    Step = 1,
    Value = { Min = 0, Max = 100, Default = Auto.PressRandomRange },
    Callback = function(value)
        Auto.PressRandomRange = tonumber(value) or Auto.PressRandomRange
        pushSettings()
    end,
})

pcall(function() Window:OnDestroy(shutdown) end)

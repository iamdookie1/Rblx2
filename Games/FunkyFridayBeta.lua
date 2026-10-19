--// [MADNESS] Funky Friday -- beta autoplayer (WindUI).
--
-- One toggle: auto play, every note a Sick. It runs on its own, separate from
-- the full script (Games/FunkyFriday.lua):
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Games/FunkyFridayBeta.lua'))()
--
-- How it plays (the full script's game mode): hits are judged on the client.
-- Lane:Hit(isKeyDown, timestamp) turns the os.clock() of a press into a song
-- time with the playback sample and the HitboxOffset setting, and anything
-- within 50ms of the note is a Sick. The worker reads the real notes (time,
-- length, type) out of the game and calls Field:HitLane with the timestamp
-- each note is due, plus a few milliseconds either way so it isn't robotic
-- (always well inside the Sick window), worked out ahead of the frame so frame
-- rate doesn't matter. Hold notes are held their full length; Death, Poison and
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
local Offsets = setmetatable({}, { __mode = "k" }) -- note -> timing error, picked once
local lastField
local rng = Random.new()

-- a Sick: up to 30ms either side of the note, well inside the game's 50ms
local function sickOffset()
    local ms = rng:NextNumber(0, 30)
    if rng:NextNumber() < 0.5 then ms = -ms end
    return ms / 1000
end

-- a tap stays down about 60ms, cut short when the next note in the lane is sooner
local function tapLength()
    return rng:NextNumber(0.045, 0.075)
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
    if not song or song.Ending or type(field.Lanes) ~= "table" then return end

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
                    offset = sickOffset()
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

-- One worker here, one in the actor when the executor can; whichever finds
-- the game first plays and the other stops.
local function startWorkers()
    local started = false
    local here = WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "ThisVM")
    local actorCode = WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "Actor")

    if typeof(getgc) == "function" then
        local fn = loadstring(here)
        if fn then
            task.spawn(fn)
            started = true
        end
    end

    local run = (typeof(run_on_actor) == "function" and run_on_actor)
        or (type(syn) == "table" and typeof(syn.run_on_actor) == "function" and syn.run_on_actor)
    if run then
        local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        local actor = scripts and scripts:FindFirstChild("ClientActor")
        if not actor and typeof(getactors) == "function" then
            local ok, list = pcall(getactors)
            if ok and type(list) == "table" then
                for _, candidate in ipairs(list) do
                    if candidate.Name == "ClientActor" then
                        actor = candidate
                        break
                    end
                end
            end
        end
        if actor and pcall(run, actor, actorCode) then started = true end
    end
    return started
end

local canPlay = startWorkers()

local function shutdown()
    pcall(function() Bridge:SetAttribute("Enabled", false) end)
    pcall(function() Bridge:SetAttribute("Stop", true) end)
    -- the workers see Stop on their next frame, let go of any held lane, and quit
    task.delay(0.5, function() pcall(function() Bridge:Destroy() end) end)
    if Genv.__FunkyFridayBetaStop == shutdown then Genv.__FunkyFridayBetaStop = nil end
end
Genv.__FunkyFridayBetaStop = shutdown

--// ui ------------------------------------------------------------------------

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
    Title = "Funky Friday",
    Author = "beta",
    Icon = "music",
    Folder = "FunkyFridayBeta",
    Size = UDim2.fromOffset(480, 300),
})

local Tab = Window:Tab({ Title = "Main", Icon = "music" })

Tab:Toggle({
    Title = "Auto play",
    Desc = "Hits every note as a Sick",
    Value = false,
    Callback = function(state)
        Bridge:SetAttribute("Enabled", state == true)
        if state and not canPlay then
            WindUI:Notify({
                Title = "Funky Friday",
                Content = "Your executor needs getgc or run_on_actor for auto play.",
                Duration = 6,
            })
        end
    end,
})

pcall(function() Window:OnDestroy(shutdown) end)

--// [MADNESS] Funky Friday -- autoplayer.
--
-- Built against a script dump of the live game (place 6447798030, game
-- 2404080894, version 532). What the game's own client scripts show:
--  * Hits are judged on the client. Lane:Hit(isKeyDown, timestamp) takes the
--    os.clock() of the press, turns it into a song time with the playback
--    sample (TimePositionSample.Position / .Clock, AdjustedPlayback, clamped
--    to 0.25s either side) plus the HitboxOffset setting, and scores the
--    closest unhit note inside a 200ms window. Within 50ms is a Sick.
--  * Holds score 75% on the press and 25% on how long you hold, full marks
--    from 80% of the length on.
--  * Death and Poison notes cost health when hit, and "Mechanic" notes count
--    as a miss when hit (Configs.VSRG.IgnoredNoteTypes). Leaving any of them
--    alone costs nothing.
--  * Input comes from Roblox's input action system: PlayerGui.VSRGContext
--    holds an InputAction per lane ("Lane1".."LaneN") with InputBindings for
--    your keys, and its Pressed / Released call Field:HitLane(lane, down,
--    os.clock()).
--  * Every game module runs inside PlayerScripts.ClientActor, its own Lua VM.
--
-- Three ways to play, picked in the menu:
--  Game          reads the real notes (time, length, type) out of the game and
--                calls Field:HitLane with the exact timestamp each note is due,
--                worked out ahead of the frame, so timing does not depend on
--                frame rate at all. Needs getgc, and either the game in the
--                same VM as this script or run_on_actor to get into the actor.
--  Input action  fires the lane's InputAction, the same path a key takes.
--  Keypress      presses your lane keys with VirtualInputManager.
-- The last two read the notes off the screen and predict when each one lands
-- on its receptor from how fast it is moving, so they press within a frame.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__FunkyFridayStop) == "function" then pcall(Genv.__FunkyFridayStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// settings ----------------------------------------------------------------

local MODES = { "Game", "Input action", "Keypress" }

local Auto = {
    Enabled = false,
    Mode = "Game",
    -- how often each judgement comes out, as weights (they don't need to add
    -- up to 100). all Sick by default.
    Chance = { Sick = 100, Good = 0, Ok = 0, Bad = 0, Miss = 0 },
    SkipSpecial = true,  -- screen modes: leave death / poison notes alone
    -- hold notes
    Holds = true,        -- hold them down; off plays every hold as a tap
    HoldPercent = 100,   -- how much of each hold to keep down (80% and up already scores full)
    HoldRandom = false,  -- vary it per hold
    HoldRandomRange = 20,-- holds pick between HoldPercent - this and HoldPercent
    Side = "Auto",       -- screen modes: which field is yours
}

local Stats = { Status = "off", Special = 0, Sick = 0, Good = 0, Ok = 0, Bad = 0, Miss = 0 }

local Library -- the Ui3 menu, loaded last
local Log
local PendingLog = {}

local LOG_COLORS = {
    Info = Color3.fromRGB(150, 200, 255),
    Success = Color3.fromRGB(126, 217, 87),
    Warn = Color3.fromRGB(255, 200, 90),
    Error = Color3.fromRGB(255, 96, 106),
}

local function log(kind, ...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    local text = table.concat(parts, " ", 1, parts.n)
    if not Log then
        PendingLog[#PendingLog + 1] = { text, LOG_COLORS[kind] }
        return
    end
    pcall(function() Log:Log(text, LOG_COLORS[kind]) end)
end

local Rng = Random.new()

-- The game judges a hit by how far off it is: under 50ms is Sick, under
-- 100ms Good, under 150ms Ok, and anything inside its 200ms window Bad. Each
-- judgement plays from the middle of its band, so frame-to-frame jitter in the
-- screen modes can't push it into the next one.
local GRADES = {
    { Name = "Sick", Min = 0, Max = 30 },
    { Name = "Good", Min = 60, Max = 90 },
    { Name = "Ok", Min = 110, Max = 140 },
    { Name = "Bad", Min = 160, Max = 190 },
}
local GRADE_ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }

-- Picks a judgement by the chances. Returns its name and the timing error in
-- seconds (nil for a miss: the note is left alone).
local function plan()
    local total = 0
    for _, name in ipairs(GRADE_ORDER) do total += math.max(Auto.Chance[name] or 0, 0) end
    local pick = "Sick"
    if total > 0 then
        local roll = Rng:NextNumber(0, total)
        for _, name in ipairs(GRADE_ORDER) do
            roll -= math.max(Auto.Chance[name] or 0, 0)
            if roll <= 0 then
                pick = name
                break
            end
        end
    end
    if pick == "Miss" then return pick, nil end
    for _, grade in ipairs(GRADES) do
        if grade.Name == pick then
            local ms = Rng:NextNumber(grade.Min, grade.Max)
            if Rng:NextNumber() < 0.5 then ms = -ms end
            return pick, ms / 1000
        end
    end
    return "Sick", 0
end

--// game mode ---------------------------------------------------------------
-- The worker runs wherever the game's modules are: in this VM if getgc can see
-- them, otherwise inside ClientActor through run_on_actor. Settings go to it
-- (and its status comes back) as attributes on a bridge folder, the one thing
-- both VMs can see.

local Bridge = Instance.new("Folder")
Bridge.Name = "FF_" .. HttpService:GenerateGUID(false):sub(1, 8)
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    Bridge.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end

-- How much of a hold this one keeps, 0..1.
local function holdFraction(rng)
    local top = math.clamp(Auto.HoldPercent, 0, 100)
    if Auto.HoldRandom and Auto.HoldRandomRange > 0 then
        local low = math.max(top - Auto.HoldRandomRange, 0)
        return (rng or Rng):NextNumber(low, top) / 100
    end
    return top / 100
end

local function pushSettings()
    Bridge:SetAttribute("Enabled", Auto.Enabled and Auto.Mode == "Game")
    Bridge:SetAttribute("Holds", Auto.Holds)
    Bridge:SetAttribute("HoldPercent", Auto.HoldPercent)
    Bridge:SetAttribute("HoldRandom", Auto.HoldRandom)
    Bridge:SetAttribute("HoldRandomRange", Auto.HoldRandomRange)
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

-- The game's framework table: it holds VSRG (with the InputHandler that knows
-- your field) and the SettingsHandler.
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
local searches = 0
local Lanes = {}     -- lane -> { Down, Hold, ReleaseAt (song time), LastPress }
local Planned = setmetatable({}, { __mode = "k" }) -- note -> true pressed / false left alone
local Plans = setmetatable({}, { __mode = "k" })   -- note -> { Grade, Offset }, decided the first time it is seen
local lastField
local rng = Random.new()

local GRADES = {
    Sick = { 0, 30 }, Good = { 60, 90 }, Ok = { 110, 140 }, Bad = { 160, 190 },
}
local ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }
local TAP = 0.03 -- seconds a tap stays down, cut short when the next note in the lane comes sooner

local function pickGrade()
    local total = 0
    for _, name in ipairs(ORDER) do total += math.max(attr("Chance" .. name, name == "Sick" and 100 or 0), 0) end
    if total <= 0 then return "Sick", 0 end
    local roll = rng:NextNumber(0, total)
    local pick = "Sick"
    for _, name in ipairs(ORDER) do
        roll -= math.max(attr("Chance" .. name, name == "Sick" and 100 or 0), 0)
        if roll <= 0 then
            pick = name
            break
        end
    end
    if pick == "Miss" then return pick, nil end
    local band = GRADES[pick]
    local ms = rng:NextNumber(band[1], band[2])
    if rng:NextNumber() < 0.5 then ms = -ms end
    return pick, ms / 1000
end

local function bump(name)
    bridge:SetAttribute(name, attr(name, 0) + 1)
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
    if not attr("Enabled", false) then
        if lastField then pcall(releaseAll, lastField) end
        return
    end

    if not Framework then
        if os.clock() < nextSearch then return end
        nextSearch = os.clock() + 3
        searches += 1
        Framework = findFramework()
        if not Framework then
            if not owner then bridge:SetAttribute("Status" .. WORKER_ID, "game not found (try " .. searches .. ")") end
            return
        end
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
        Plans = setmetatable({}, { __mode = "k" })
    end
    local song = field and field.Game
    if not song or song.Ending or type(field.Lanes) ~= "table" then
        bridge:SetAttribute("Status", "waiting for a song")
        return
    end

    local sample = song.TimePositionSample
    local samplePos = sample and sample.Position or song.TimePosition
    if type(samplePos) ~= "number" then return end
    local sampleClock = sample and sample.Clock or os.clock()
    local playback = song.AdjustedPlayback or 1
    local clock = os.clock()
    local now = samplePos + (clock - sampleClock) * playback
    local hitbox = hitboxOffset() / 1000
    -- everything due before the next frame goes out now, each press stamped
    -- with its own moment, so the game judges it as if it came exactly then.
    -- a lane can take any number of presses and releases in one frame, which
    -- is what keeps up with jacks and streams faster than the frame rate
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
            -- settle the note's judgement the first time it is looked at
            local pressAt
            if note then
                local plan = Plans[note]
                if not plan then
                    if ignored(note) then
                        Planned[note] = false
                        bump("Special")
                        index += 1
                        continue
                    end
                    local grade, offset = pickGrade()
                    if not offset then
                        Planned[note] = false
                        bump("GradeMiss")
                        index += 1
                        continue
                    end
                    plan = { Grade = grade, Offset = offset }
                    Plans[note] = plan
                end
                -- presses in a lane never go back in time, however the
                -- judgement offsets fall on tightly packed notes
                pressAt = math.max(note.Time + plan.Offset, state.LastPress + 0.001)
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
            bump("Grade" .. Plans[note].Grade)
            state.Down = true
            state.LastPress = pressAt
            local length = tonumber(note.Length) or 0
            local keep = 0
            if length > 0 and attr("Holds", true) then
                local top = math.clamp(attr("HoldPercent", 100), 0, 100)
                local range = attr("HoldRandom", false) and math.max(attr("HoldRandomRange", 0), 0) or 0
                keep = (range > 0 and rng:NextNumber(math.max(top - range, 0), top) or top) / 100
            end
            state.Hold = keep > 0
            state.ReleaseAt = state.Hold and (note.Time + length * keep) or (pressAt + TAP)
            index += 1
        end
    end
    bridge:SetAttribute("Status", "playing")
end)
]==]

local Workers = {}

-- Starts game-mode workers: one here, one in the actor when the executor can.
-- Whichever finds the game first plays; the other stops.
local function startWorkers()
    if Workers.Started then return end
    Workers.Started = true
    -- worker ids end up in attribute names, so letters only
    local here = WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "ThisVM")
    local actorCode = WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "Actor")

    if typeof(getgc) == "function" then
        local fn = loadstring(here)
        if fn then
            task.spawn(fn)
            Workers.Here = true
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
        if actor then
            local ok, err = pcall(run, actor, actorCode)
            Workers.Actor = ok
            if not ok then log("Warn", "run_on_actor failed: " .. tostring(err)) end
        end
    end

    if not Workers.Here and not Workers.Actor then
        log("Warn", "game mode can't run here: no getgc and no run_on_actor. use input action or keypress")
        Stats.Status = "game mode unavailable"
    end
end

--// screen modes ------------------------------------------------------------

local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local function playerGui()
    return LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local function context()
    local gui = playerGui()
    return gui and gui:FindFirstChild("VSRGContext")
end

local function laneAction(index)
    local ctx = context()
    return ctx and ctx:FindFirstChild("Lane" .. index)
end

local GAMEPAD = {
    [Enum.KeyCode.ButtonL2] = true, [Enum.KeyCode.ButtonR2] = true,
    [Enum.KeyCode.ButtonL1] = true, [Enum.KeyCode.ButtonR1] = true,
    [Enum.KeyCode.DPadLeft] = true, [Enum.KeyCode.DPadRight] = true,
    [Enum.KeyCode.DPadUp] = true, [Enum.KeyCode.DPadDown] = true,
    [Enum.KeyCode.ButtonA] = true, [Enum.KeyCode.ButtonB] = true,
    [Enum.KeyCode.ButtonX] = true, [Enum.KeyCode.ButtonY] = true,
}

local function laneKey(index)
    local action = laneAction(index)
    if not action then return nil end
    for _, binding in ipairs(action:GetChildren()) do
        if binding:IsA("InputBinding") then
            local key = binding.KeyCode
            if key and key ~= Enum.KeyCode.Unknown and not GAMEPAD[key] then return key end
        end
    end
    return nil
end

local Down = {} -- lane index -> true while this script holds it

local function press(index, down)
    if Auto.Mode == "Input action" then
        local action = laneAction(index)
        if not action then return false end
        local ok = pcall(function() action:Fire(down) end)
        if ok then Down[index] = down or nil end
        return ok
    end
    local key = laneKey(index)
    if not key or not VirtualInputManager then return false end
    local ok = pcall(function() VirtualInputManager:SendKeyEvent(down, key, false, game) end)
    if ok then Down[index] = down or nil end
    return ok
end

local function releaseScreen()
    for index in pairs(Down) do pcall(press, index, false) end
    table.clear(Down)
end

-- Finds the note fields on screen: every lane is a frame named by its index
-- holding a Receptor frame and a Notes folder.
local Fields = { List = {}, At = 0 }

local function scanFields()
    local gui = playerGui()
    local groups = {}
    for _, inst in ipairs(gui and gui:GetDescendants() or {}) do
        if inst.Name == "Receptor" and inst:IsA("Frame") then
            local lane = inst.Parent
            local index = lane and tonumber(lane.Name)
            local notes = lane and lane:FindFirstChild("Notes")
            if index and notes and lane.Parent then
                local group = groups[lane.Parent]
                if not group then
                    group = { Container = lane.Parent, Lanes = {} }
                    groups[lane.Parent] = group
                end
                group.Lanes[index] = { Frame = lane, Receptor = inst, Notes = notes }
            end
        end
    end
    local list = {}
    for _, group in pairs(groups) do list[#list + 1] = group end
    Fields.List = list
    Fields.At = os.clock()
end

local function center(gui)
    return gui.AbsolutePosition + gui.AbsoluteSize / 2
end

local function laneCount(group)
    local count = 0
    for _ in pairs(group.Lanes) do count += 1 end
    return count
end

local function myField()
    if os.clock() - Fields.At > 1 then scanFields() end
    local ctx = context()
    local wanted = 0
    for _, child in ipairs(ctx and ctx:GetChildren() or {}) do
        if child:IsA("InputAction") then wanted += 1 end
    end
    local candidates = {}
    for _, group in ipairs(Fields.List) do
        if group.Container.Parent and group.Container.AbsoluteSize.X > 0 and (wanted == 0 or laneCount(group) == wanted) then
            candidates[#candidates + 1] = group
        end
    end
    if #candidates <= 1 then return candidates[1] end
    local camera = workspace.CurrentCamera
    local middle = camera and camera.ViewportSize.X / 2 or 0
    table.sort(candidates, function(a, b) return center(a.Container).X < center(b.Container).X end)
    if Auto.Side == "Left" then return candidates[1] end
    if Auto.Side == "Right" then return candidates[#candidates] end
    -- your field is the one in the middle with middle scroll, and the bigger one
    local best, bestScore
    for _, group in ipairs(candidates) do
        local score = math.abs(center(group.Container).X - middle) - group.Container.AbsoluteSize.X * 0.5
        if not bestScore or score < bestScore then best, bestScore = group, score end
    end
    return best
end

-- Death and poison notes are drawn with the game's hazard skins (arrow skins
-- of type "DeathPoison"; the type picks the skin when the note is set up).
-- The game's own Arrows settings page builds a preview of every hazard skin
-- under ...Notes.Options.Bottom.Skin.Content, so the images used there are
-- exactly the images a hazard note can carry. Read once they exist; until
-- then the lane-majority guess below stands in.
local Hazard = { Images = nil, NextScan = 0 }

local function scanHazardSkins()
    if Hazard.Images or os.clock() < Hazard.NextScan then return end
    Hazard.NextScan = os.clock() + 3
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return end
    local found, normal = {}, {}
    local count = 0
    for _, inst in ipairs(gui:GetDescendants()) do
        local parent = inst.Parent
        if inst.Name == "Content" and parent and parent.Name == "Skin"
            and parent.Parent and parent.Parent.Name == "Bottom" then
            for _, image in ipairs(inst:GetDescendants()) do
                if image:IsA("ImageLabel") and image.Image ~= "" then found[image.Image] = true end
            end
        elseif inst.Name == "Arrows" and parent and parent.Name == "Inner"
            and parent.Parent and parent.Parent.Name == "Arrows" then
            -- the normal arrow preview on the same page: anything in it is not a hazard
            for _, image in ipairs(inst:GetDescendants()) do
                if image:IsA("ImageLabel") and image.Image ~= "" then normal[image.Image] = true end
            end
        end
    end
    for image in pairs(normal) do found[image] = nil end
    for _ in pairs(found) do count += 1 end
    if count > 0 then
        Hazard.Images = found
        log("Success", ("found the game's death / poison skins (%d images), special notes are read exactly now"):format(count))
    end
end

Hazard.Seen, Hazard.Flagged = 0, 0

local function isHazard(frame)
    if not Hazard.Images then return nil end
    local hit = false
    for _, inst in ipairs(frame:GetDescendants()) do
        if inst:IsA("ImageLabel") and Hazard.Images[inst.Image] then
            hit = true
            break
        end
    end
    Hazard.Seen += 1
    if hit then Hazard.Flagged += 1 end
    -- hazards are a handful of notes in a song. if most notes match, the skins
    -- share images with your arrows, so fall back to guessing from looks
    if Hazard.Seen >= 12 and Hazard.Flagged / Hazard.Seen > 0.5 then
        Hazard.Images = nil
        Hazard.NextScan = math.huge
        log("Warn", "your arrow skin shares images with the death / poison skins, guessing from looks instead")
        return nil
    end
    return hit
end

-- The image a note is drawn with, to tell normal notes from death / poison
-- ones, which come in their own skin.
local function noteLook(frame)
    for _, inst in ipairs(frame:GetDescendants()) do
        if inst:IsA("ImageLabel") and inst.Visible and inst.Image ~= "" then
            return inst.Image .. "|" .. inst.ImageRectOffset.X .. "," .. inst.ImageRectOffset.Y
        end
    end
    return "?"
end

-- the longest piece of a note along the lane: its hold tail when it has one
local function tailLength(frame, axis)
    local longest = 0
    for _, inst in ipairs(frame:GetDescendants()) do
        if inst:IsA("GuiObject") and inst.Visible then
            local size = inst.AbsoluteSize
            local along = math.abs(size.X * axis.X) + math.abs(size.Y * axis.Y)
            if along > longest then longest = along end
        end
    end
    return longest
end

local Tracked = setmetatable({}, { __mode = "k" }) -- note frame -> motion state
local Looks = {}                                   -- lane index -> { [look] = count }
local Holding = {}                                 -- lane index -> { Frame, Axis, ReleaseAt }
local TapRelease = {}                              -- lane index -> os.clock() to let go

local function majorityLook(index)
    local counts = Looks[index]
    local best, bestCount = nil, 0
    for look, count in pairs(counts or {}) do
        if count > bestCount then best, bestCount = look, count end
    end
    return best, bestCount
end

local lastField

local function screenStep(dt)
    local field = myField()
    if field ~= lastField then
        releaseScreen()
        table.clear(Holding)
        table.clear(TapRelease)
        table.clear(Looks)
        lastField = field
    end
    local ctx = context()
    if not field or not ctx then
        Stats.Status = "waiting for a song"
        return
    end
    Stats.Status = "playing"
    if Auto.SkipSpecial then scanHazardSkins() end
    local clock = os.clock()

    for index, lane in pairs(field.Lanes) do
        local receptor = center(lane.Receptor)
        local size = lane.Receptor.AbsoluteSize.Magnitude

        local holding = Holding[index]
        if holding then
            local frame = holding.Frame
            local gone = not frame.Parent or not frame.Visible or frame.Name ~= holding.Name
            local tail = (not gone) and tailLength(frame, holding.Axis) or 0
            if gone or tail <= holding.NoteSize * 1.15 or clock >= holding.ReleaseAt then
                press(index, false)
                Holding[index] = nil
            end
        elseif TapRelease[index] then
            if clock >= TapRelease[index] then
                press(index, false)
                TapRelease[index] = nil
            end
        end

        local best, bestTime
        for _, frame in ipairs(lane.Notes:GetChildren()) do
            if frame:IsA("GuiObject") and frame.Visible then
                local state = Tracked[frame]
                if not state or state.Name ~= frame.Name then
                    local look = noteLook(frame)
                    Looks[index] = Looks[index] or {}
                    Looks[index][look] = (Looks[index][look] or 0) + 1
                    state = { Name = frame.Name, Look = look }
                    Tracked[frame] = state
                end
                local pos = center(frame)
                local toReceptor = receptor - pos
                if not state.Axis and toReceptor.Magnitude > size * 0.75 then
                    state.Axis = toReceptor.Unit
                end
                if state.Axis and not state.Done then
                    local distance = toReceptor:Dot(state.Axis)
                    if state.Distance and state.Clock and clock > state.Clock then
                        local speed = (state.Distance - distance) / (clock - state.Clock)
                        if speed > 0 then
                            state.Speed = state.Speed and (state.Speed * 0.6 + speed * 0.4) or speed
                        end
                    end
                    state.Distance, state.Clock = distance, clock
                    if state.Speed and state.Speed > 1 then
                        local due = distance / state.Speed -- seconds until it sits on the receptor
                        if due > -0.12 and (not bestTime or due < bestTime) then
                            best, bestTime = frame, due
                        end
                    end
                end
            end
        end

        if best and not Holding[index] then
            local state = Tracked[best]
            if state.Plan == nil then
                local special = false
                if Auto.SkipSpecial then
                    local exact = isHazard(best)
                    if exact ~= nil then
                        special = exact
                    else
                        local normal, count = majorityLook(index)
                        special = count >= 3 and state.Look ~= normal
                    end
                end
                if special then
                    state.Plan = false
                    Stats.Special += 1
                else
                    local grade, offset = plan()
                    state.Grade = grade
                    state.Plan = offset or false
                    if not offset then Stats.Miss += 1 end
                end
            end
            if state.Plan == false then
                state.Done = true
            elseif bestTime + state.Plan <= dt * 0.5 then
                -- lands within half a frame from now: press on this one
                state.Done = true
                if TapRelease[index] then
                    press(index, false)
                    TapRelease[index] = nil
                end
                if press(index, true) then
                    Stats[state.Grade] = (Stats[state.Grade] or 0) + 1
                    local tail = tailLength(best, state.Axis)
                    local noteSize = math.min(best.AbsoluteSize.X, best.AbsoluteSize.Y)
                    local keep = (tail > noteSize * 1.6 and Auto.Holds) and holdFraction() or 0
                    if keep > 0 then
                        Holding[index] = {
                            Frame = best, Name = best.Name, Axis = state.Axis, NoteSize = noteSize,
                            -- a full hold also lets go when the tail runs out
                            ReleaseAt = clock + (tail / state.Speed) * keep + (keep >= 1 and 0.1 or 0),
                        }
                    else
                        TapRelease[index] = clock + 0.03
                    end
                end
            end
        end
    end
end

track(RunService.RenderStepped:Connect(function(dt)
    if Unloaded then return end
    if not Auto.Enabled or Auto.Mode == "Game" then
        if next(Down) then releaseScreen() end
        if not Auto.Enabled then Stats.Status = "off" end
        return
    end
    local ok, err = pcall(screenStep, dt)
    if not ok then
        Stats.Status = "error"
        log("Error", "autoplayer: " .. tostring(err))
        task.wait(1)
    end
end))

-- game mode status comes back over the bridge
track(Bridge.AttributeChanged:Connect(function(name)
    local grade = name:match("^Grade(%a+)$")
    if grade then Stats[grade] = Bridge:GetAttribute(name) or Stats[grade] end
    if name == "Special" then Stats.Special = Bridge:GetAttribute("Special") or Stats.Special end
    if name == "Where" then
        local where = Bridge:GetAttribute("Where") == "Actor" and "the game's actor" or "this script's vm"
        log("Success", "game mode found the game, running in " .. where)
    end
    if Auto.Mode == "Game" and Auto.Enabled and (name == "Status" or name:match("^Status")) then
        Stats.Status = Bridge:GetAttribute("Status")
            or Bridge:GetAttribute("StatusActor")
            or Bridge:GetAttribute("StatusThisVM")
            or Stats.Status
    end
end))

--// mode check --------------------------------------------------------------

local function checkModes()
    local lines = {}
    local game_ = {}
    if typeof(getgc) == "function" then game_[#game_ + 1] = "getgc" end
    if typeof(run_on_actor) == "function" or (type(syn) == "table" and syn.run_on_actor) then game_[#game_ + 1] = "run_on_actor" end
    if Bridge:GetAttribute("Where") then
        lines[#lines + 1] = "game: working (" .. tostring(Bridge:GetAttribute("Where")) .. ")"
    elseif #game_ > 0 then
        lines[#lines + 1] = "game: has " .. table.concat(game_, " + ") .. ", turn it on in a song to see if it finds the game"
    else
        lines[#lines + 1] = "game: no (needs getgc or run_on_actor)"
    end

    local action = laneAction(1)
    if action then
        local ok = pcall(function() return action.Fire end)
        lines[#lines + 1] = "input action: " .. (ok and "yes" or "no")
    else
        lines[#lines + 1] = "input action: start a song to check"
    end

    lines[#lines + 1] = "keypress: " .. (VirtualInputManager and "yes" or "no (no VirtualInputManager)")
    local identify = "unknown"
    if typeof(identifyexecutor) == "function" then
        local ok, name = pcall(identifyexecutor)
        if ok and name then identify = tostring(name) end
    end
    lines[#lines + 1] = "executor: " .. identify
    for _, line in ipairs(lines) do log("Info", line) end
    return lines
end

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Auto.Enabled = false
    pcall(releaseScreen)
    Bridge:SetAttribute("Stop", true)
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    task.delay(0.5, function() pcall(function() Bridge:Destroy() end) end)
end

Genv.__FunkyFridayStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Funky Friday',
    Footer = 'autoplayer',
    Icon = 'music',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Violet',
    ConfigFolder = 'FunkyFriday',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

do
    local Tab = Window:AddTab('Autoplayer', 'music', 'Plays your side of the song')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('ff_stats', {
        Cards = {
            { Title = 'Sick', Value = '0', Icon = 'sparkles' },
            { Title = 'Good', Value = '0', Icon = 'thumbs-up' },
            { Title = 'Ok', Value = '0', Icon = 'circle' },
            { Title = 'Bad', Value = '0', Icon = 'thumbs-down' },
            { Title = 'Miss', Value = '0', Icon = 'x' },
        },
    })
    local statusLabel = overview:AddLabel('status: off')
    every(0.2, function()
        for _, name in ipairs(GRADE_ORDER) do cards:SetValue(name, tostring(Stats[name] or 0)) end
        statusLabel:SetText(("status: %s   mode: %s   special notes left alone: %d"):format(
            tostring(Stats.Status), Auto.Mode, Stats.Special or 0))
    end)

    local play = Tab:AddLeftGroupbox('Autoplayer', 'play')

    play:AddToggle('ff_enabled', {
        Text = 'Autoplayer',
        Default = false,
        Callback = function(state)
            Auto.Enabled = state
            if state and Auto.Mode == "Game" then startWorkers() end
            pushSettings()
        end,
    }):AddKeyPicker('ff_enabled_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Autoplayer',
    })

    play:AddDropdown('ff_mode', {
        Text = 'Input',
        Tooltip = 'game: reads the real notes and hits them through the game itself, timed exactly (needs getgc / run_on_actor). input action: fires the lane\'s input like a key would. keypress: presses your keys. use "check modes" to see what your executor can do',
        Values = MODES,
        Default = Auto.Mode,
        Callback = function(value)
            Auto.Mode = value or "Game"
            releaseScreen()
            if Auto.Enabled and Auto.Mode == "Game" then startWorkers() end
            pushSettings()
        end,
    })

    play:AddButton({ Text = 'Check modes', Func = checkModes })

    play:AddButton({
        Text = 'Reset counts',
        Func = function()
            for _, name in ipairs(GRADE_ORDER) do
                Stats[name] = 0
                Bridge:SetAttribute("Grade" .. name, 0)
            end
            Stats.Special = 0
            Bridge:SetAttribute("Special", 0)
        end,
    })

    local chances = Tab:AddRightGroupbox('Judgement chances', 'dices')

    chances:AddLabel('How often each judgement comes out. They work as weights, so they don\'t have to add up to 100: 90 Sick and 10 Good is one Good in ten. All Sick by default.', true)

    local share = chances:AddLabel('', true)
    local function showShare()
        local total = 0
        for _, name in ipairs(GRADE_ORDER) do total += math.max(Auto.Chance[name] or 0, 0) end
        local parts = {}
        for _, name in ipairs(GRADE_ORDER) do
            local pct = total > 0 and (math.max(Auto.Chance[name] or 0, 0) / total * 100) or (name == "Sick" and 100 or 0)
            if pct > 0 then parts[#parts + 1] = ("%s %.0f%%"):format(name, pct) end
        end
        share:SetText("so: " .. table.concat(parts, ", "))
    end

    for _, name in ipairs(GRADE_ORDER) do
        chances:AddSlider('ff_chance_' .. name:lower(), {
            Text = name,
            Min = 0, Max = 100, Default = Auto.Chance[name], Rounding = 0, Suffix = '%',
            Callback = function(value)
                Auto.Chance[name] = value
                pushSettings()
                showShare()
            end,
        })
    end
    showShare()

    local screen = Tab:AddLeftGroupbox('Input action / keypress', 'monitor')

    screen:AddDropdown('ff_side', {
        Text = 'Your field',
        Tooltip = 'auto picks the centred / bigger field. set it if the autoplayer plays the wrong side',
        Values = { 'Auto', 'Left', 'Right' },
        Default = Auto.Side,
        Callback = function(value) Auto.Side = value or "Auto" end,
    })

    screen:AddToggle('ff_skipspecial', {
        Text = 'Leave death / poison notes',
        Tooltip = 'matches notes against the game\'s own death and poison skins once its Arrows settings page has built them (open settings > Arrows > Notes once if it says it hasn\'t). until then a note drawn differently from the rest of its lane is left alone. game mode always knows the real type',
        Default = Auto.SkipSpecial,
        Callback = function(state) Auto.SkipSpecial = state end,
    })

    local hazardLabel = screen:AddLabel('death / poison: -', true)
    every(1, function()
        hazardLabel:SetText(Hazard.Images and "death / poison: read from the game's skins"
            or "death / poison: guessing from looks (open settings > Arrows > Notes once)")
    end)

    screen:AddLabel('Or turn off Note Mechanics in the game\'s song options: the game then never spawns death or poison notes at all.', true)

    local holds = Tab:AddRightGroupbox('Hold notes', 'hand')

    holds:AddToggle('ff_holds', {
        Text = 'Hold them',
        Tooltip = 'off plays every hold like a tap, which loses the hold part of its score',
        Default = Auto.Holds,
        Callback = function(state)
            Auto.Holds = state
            pushSettings()
        end,
    })

    holds:AddSlider('ff_holdpercent', {
        Text = 'Hold for',
        Tooltip = 'how much of each hold to keep down. the game gives full marks from 80% on',
        Min = 0, Max = 100, Default = Auto.HoldPercent, Rounding = 0, Suffix = '%',
        Callback = function(value)
            Auto.HoldPercent = value
            pushSettings()
        end,
    })

    holds:AddToggle('ff_holdrandom', {
        Text = 'Randomize',
        Tooltip = 'each hold picks its own length, up to the range below shorter than "hold for"',
        Default = Auto.HoldRandom,
        Callback = function(state)
            Auto.HoldRandom = state
            pushSettings()
        end,
    })

    holds:AddSlider('ff_holdrange', {
        Text = 'Random range',
        Tooltip = 'e.g. hold for 100% with a 30% range holds each one somewhere between 70% and 100%',
        Min = 0, Max = 100, Default = Auto.HoldRandomRange, Rounding = 0, Suffix = '%',
        Callback = function(value)
            Auto.HoldRandomRange = value
            pushSettings()
        end,
    })

    local logBox = Tab:AddBigGroupbox('Log', 'scroll-text')
    Log = logBox:AddLog('ff_log', { Height = 150, MaxLines = 150, Timestamps = true })
    Log:Log('loaded. pick an input and turn the autoplayer on, then start a song.')
    for _, line in ipairs(PendingLog) do
        pcall(function() Log:Log(line[1], line[2]) end)
    end
    table.clear(PendingLog)
end

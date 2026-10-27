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
--
-- This is the dev version of the beta script (Games/FunkyFridayBeta.lua). The
-- two link up across clients through a web relay: the Dev tab lists who in the
-- lobby is on beta, and the Cmds tab sends them commands (see "link" below).

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
    -- how long a key stays down after hitting a normal note (hold notes are
    -- always held for their full length)
    PressHold = true,    -- off lets go straight away
    PressHoldMs = 60,
    PressRandom = false, -- vary it per note
    PressRandomRange = 30, -- % either side of PressHoldMs
    Side = "Auto",       -- screen modes: which field is yours
    Perfect = false,     -- every hit dead on the note: 0.00ms (exact in game mode)
    SemiLegit = false,   -- game mode: press through the game's touch tiles, so they light up like a finger
    SemiTiles = true,    -- semi legit: show the touch tiles on PC too
}

-- client side note themes, one per lane direction, after the website's space
-- themes (black hole left out)
local THEME_NAMES = {
    "Default", "Violet Nebula", "Deep Ocean", "Magenta Cloud", "Emerald Drift",
    "Ember Storm", "Aurora", "Crimson Void", "Ice Comet", "Supernova",
}
local DIRECTIONS = { "Left", "Down", "Up", "Right" }
local Theme = {
    Left = "Default", Down = "Default", Up = "Default", Right = "Default",
    Animate = true,
    Speed = 1,
    Stars = true,
    Glow = true,
    Tails = true,
    Receptors = false,
}

local Stats = { Status = "off", Special = 0, Sick = 0, Good = 0, Ok = 0, Bad = 0, Miss = 0 }

-- commands sent to "Me" from the Cmds tab: chances swapped out, or auto play
-- held off, until a moment passes
local Prank = { Chance = nil, ChanceUntil = 0, FrozenUntil = 0 }

local function chancesNow()
    if Prank.Chance and os.clock() < Prank.ChanceUntil then return Prank.Chance, true end
    return Auto.Chance, false
end

local function frozen()
    return os.clock() < Prank.FrozenUntil
end

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
    local chance, pranked = chancesNow()
    if Auto.Perfect and not pranked then return "Sick", 0 end
    local total = 0
    for _, name in ipairs(GRADE_ORDER) do total += math.max(chance[name] or 0, 0) end
    local pick = "Sick"
    if total > 0 then
        local roll = Rng:NextNumber(0, total)
        for _, name in ipairs(GRADE_ORDER) do
            roll -= math.max(chance[name] or 0, 0)
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

-- Seconds a key stays down after a normal note. It is always let go before
-- the next note in the same lane, however long this is.
local function pressLength()
    if not Auto.PressHold then return 0.001 end
    local ms = Auto.PressHoldMs
    if Auto.PressRandom and Auto.PressRandomRange > 0 then
        local spread = ms * Auto.PressRandomRange / 100
        ms = Rng:NextNumber(math.max(ms - spread, 1), ms + spread)
    end
    return math.max(ms, 1) / 1000
end

local function pushSettings()
    local chance, pranked = chancesNow()
    Bridge:SetAttribute("Enabled", Auto.Enabled and Auto.Mode == "Game" and not frozen())
    Bridge:SetAttribute("PressHold", Auto.PressHold)
    Bridge:SetAttribute("PressHoldMs", Auto.PressHoldMs)
    Bridge:SetAttribute("PressRandom", Auto.PressRandom)
    Bridge:SetAttribute("PressRandomRange", Auto.PressRandomRange)
    for _, name in ipairs(GRADE_ORDER) do
        Bridge:SetAttribute("Chance" .. name, chance[name] or 0)
    end
    Bridge:SetAttribute("Perfect", Auto.Perfect and not pranked)
    Bridge:SetAttribute("SemiLegit", Auto.SemiLegit)
    Bridge:SetAttribute("SemiTiles", Auto.SemiTiles)
end

local function themesOn()
    for _, dir in ipairs(DIRECTIONS) do
        if Theme[dir] ~= "Default" then return true end
    end
    return false
end

local function pushTheme()
    for _, dir in ipairs(DIRECTIONS) do Bridge:SetAttribute("Theme" .. dir, Theme[dir]) end
    Bridge:SetAttribute("ThemeAnimate", Theme.Animate)
    Bridge:SetAttribute("ThemeSpeed", Theme.Speed)
    Bridge:SetAttribute("ThemeStars", Theme.Stars)
    Bridge:SetAttribute("ThemeGlow", Theme.Glow)
    Bridge:SetAttribute("ThemeTails", Theme.Tails)
    Bridge:SetAttribute("ThemeReceptors", Theme.Receptors)
    Bridge:SetAttribute("ThemesOn", themesOn())
    Bridge:SetAttribute("ThemeVersion", (Bridge:GetAttribute("ThemeVersion") or 0) + 1)
end
pushTheme()
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
-- seconds a key stays down after a normal note, cut short when the next note
-- in the lane comes sooner
local function tapLength()
    if not attr("PressHold", true) then return 0.001 end
    local ms = attr("PressHoldMs", 60)
    local range = attr("PressRandom", false) and attr("PressRandomRange", 0) or 0
    if range > 0 then
        local spread = ms * range / 100
        ms = rng:NextNumber(math.max(ms - spread, 1), ms + spread)
    end
    return math.max(ms, 1) / 1000
end

local function pickGrade()
    -- perfect: pressed exactly on the note. the press is stamped to the note's
    -- own time, which Lane:Hit turns back into exactly that song time, so the
    -- game judges it 0.00ms
    if attr("Perfect", false) then return "Sick", 0 end
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

-- Semi legit: presses go through the game's own touch tiles,
-- VSRG.HUD.TouchInputs:ToggleKey(lane, down, timestamp), the same path a
-- finger on a lane's tile takes. The tile lights up and the game calls
-- HitLane itself, with the timestamp given, so timing is the same.
local ForcedTiles = nil

local function touchInputs(field)
    local hud = Framework and Framework.VSRG and Framework.VSRG.HUD
    local touch = hud and hud.TouchInputs
    if type(touch) == "table" and touch.Field == field and type(touch.ToggleKey) == "function"
        and type(touch.Active) == "table" then
        return touch
    end
    return nil
end

local function press(field, lane, down, at)
    if attr("SemiLegit", false) then
        local touch = touchInputs(field)
        if touch then
            local held = touch.Active[lane]
            -- ToggleKey skips HitLane for a tile already down (a press) or
            -- already let go (a release); those go straight to HitLane
            if (down and not held) or (not down and held) then
                if pcall(touch.ToggleKey, touch, lane, down, at) then return end
            end
        end
    end
    pcall(field.HitLane, field, lane, down, at)
end

-- the tiles only show for touch input; with "show on PC" they show anyway,
-- and go back to the game's own choice when it's turned off
local function restoreTiles()
    if ForcedTiles then
        pcall(ForcedTiles.UpdateVisibility, ForcedTiles)
        ForcedTiles = nil
    end
end

local function showTiles(field)
    local want = attr("SemiLegit", false) and attr("SemiTiles", true)
    if not want then
        restoreTiles()
        return
    end
    local touch = touchInputs(field)
    local frame = touch and touch.TouchInputsFrame
    if typeof(frame) == "Instance" and not frame.Visible then
        frame.Visible = true
        ForcedTiles = touch
    end
end

local function releaseAll(field)
    for lane, state in pairs(Lanes) do
        if state.Down then press(field, lane, false, os.clock()) end
    end
    table.clear(Lanes)
end

local function hitboxOffset()
    local ok, value = pcall(function() return Framework.SettingsHandler:Get("HitboxOffset") end)
    return ok and tonumber(value) or 0
end

--// note themes ------------------------------------------------------------
-- Only your own field (VSRG.InputHandler.Field) is themed, lane by lane: every
-- frame its notes, hold tails and (if wanted) receptors are checked and given
-- their lane's theme. Each is a LayeredSprite: one ImageLabel per layer, the
-- colourable ones flagged Colorized. A theme sits on those layers: a UIGradient
-- that drifts and turns like the website's gas clouds (a gradient on an image
-- only colours the image's own pixels, so it keeps the arrow's shape), a
-- twinkling star shimmer on top and a soft glow behind.

local function hex(h) return Color3.fromHex(h) end
local function themeDef(c1, c2, c3, c4, glow, glowAlpha)
    c1, c2, c3, c4 = hex(c1), hex(c2), hex(c3), hex(c4)
    return {
        Gas = ColorSequence.new({
            ColorSequenceKeypoint.new(0, c1),
            ColorSequenceKeypoint.new(0.2, c2),
            ColorSequenceKeypoint.new(0.38, c3),
            ColorSequenceKeypoint.new(0.52, c2),
            ColorSequenceKeypoint.new(0.68, c1:Lerp(c4, 0.45)),
            ColorSequenceKeypoint.new(0.84, c2),
            ColorSequenceKeypoint.new(1, c1),
        }),
        Glow = glow,
        GlowAlpha = glowAlpha,
    }
end
local THEMES = {
    ["Violet Nebula"] = themeDef("3b0f8f", "7a3cff", "e0a8ff", "12052e", Color3.fromRGB(150, 90, 255), 0.5),
    ["Deep Ocean"] = themeDef("0a2a8f", "1f7bff", "8fe3ff", "030b26", Color3.fromRGB(60, 150, 255), 0.5),
    ["Magenta Cloud"] = themeDef("7a0a5c", "ff2fa8", "ffb3e1", "22041a", Color3.fromRGB(255, 60, 170), 0.5),
    ["Emerald Drift"] = themeDef("04594a", "12d18e", "b4ffd9", "021a14", Color3.fromRGB(30, 220, 150), 0.45),
    ["Ember Storm"] = themeDef("8a1c05", "ff5a1f", "ffd08a", "240702", Color3.fromRGB(255, 110, 40), 0.5),
    ["Aurora"] = themeDef("0b4f6c", "f2b632", "6ff7ff", "04121c", Color3.fromRGB(120, 220, 230), 0.45),
    ["Crimson Void"] = themeDef("5c0010", "d4143a", "ff8fa3", "160005", Color3.fromRGB(230, 30, 70), 0.5),
    ["Ice Comet"] = themeDef("1b3a5c", "7fc4ff", "f2fbff", "050d18", Color3.fromRGB(180, 225, 255), 0.45),
    ["Supernova"] = themeDef("6b2bd9", "ffb52e", "fff6dd", "120a20", Color3.fromRGB(255, 200, 90), 0.5),
}

-- narrow bright flecks on an otherwise clear gradient: the stars
local STARS = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1),
    NumberSequenceKeypoint.new(0.10, 1), NumberSequenceKeypoint.new(0.12, 0.1), NumberSequenceKeypoint.new(0.14, 1),
    NumberSequenceKeypoint.new(0.31, 1), NumberSequenceKeypoint.new(0.33, 0.25), NumberSequenceKeypoint.new(0.35, 1),
    NumberSequenceKeypoint.new(0.56, 1), NumberSequenceKeypoint.new(0.58, 0), NumberSequenceKeypoint.new(0.60, 1),
    NumberSequenceKeypoint.new(0.74, 1), NumberSequenceKeypoint.new(0.76, 0.3), NumberSequenceKeypoint.new(0.78, 1),
    NumberSequenceKeypoint.new(0.87, 1), NumberSequenceKeypoint.new(0.89, 0.15), NumberSequenceKeypoint.new(0.91, 1),
    NumberSequenceKeypoint.new(1, 1),
})

local DIRS = { "Left", "Down", "Up", "Right" }
local Themed = setmetatable({}, { __mode = "k" }) -- sprite -> { Name, Version, Key, Decor, Layers }
local Live = setmetatable({}, { __mode = "k" })   -- label -> animation state
local ThemeHook = nil
local ThemeVersion = 0

local function dirName(d)
    d = tonumber(d) or 1
    return DIRS[((math.floor(d) - 1) % 4) + 1]
end

local function copyImage(from, to)
    to.Image = from.Image
    to.ImageRectOffset = from.ImageRectOffset
    to.ImageRectSize = from.ImageRectSize
    to.ScaleType = from.ScaleType
    to.SliceCenter = from.SliceCenter
    to.SliceScale = from.SliceScale
    to.ResampleMode = from.ResampleMode
end

local function undecorate(sprite)
    local entry = type(sprite) == "table" and Themed[sprite]
    if not entry then return end
    Themed[sprite] = nil
    for _, obj in ipairs(entry.Decor) do pcall(function() obj:Destroy() end) end
    for _, layer in ipairs(entry.Layers) do
        if rawget(layer, "SetColor") then rawset(layer, "SetColor", nil) end
        local label = layer.Frame
        if typeof(label) == "Instance" then
            Live[label] = nil
            pcall(function() label.ImageColor3 = layer.ImageColor3 end)
        end
    end
end

-- the first layer object, to notice when the game rebuilt the sprite's layers
local function firstLayer(sprite)
    local sprites = type(sprite) == "table" and sprite.Sprites
    if type(sprites) ~= "table" then return nil end
    local _, layer = next(sprites)
    return layer
end

local function decorate(sprite, name, kind)
    local theme = THEMES[name]
    if not theme or type(sprite.Sprites) ~= "table" then return end
    local entry = { Name = name, Version = ThemeVersion, Key = firstLayer(sprite), Decor = {}, Layers = {} }
    Themed[sprite] = entry
    local anyColorized = false
    for _, layer in pairs(sprite.Sprites) do
        if type(layer) == "table" and layer.Colorized then anyColorized = true end
    end
    local phase = rng:NextNumber(0, 20)
    local stars = attr("ThemeStars", true) and kind ~= "Tail"
    local glowOn = attr("ThemeGlow", true) and kind ~= "Tail"
    for _, layer in pairs(sprite.Sprites) do
        local label = type(layer) == "table" and layer.Frame
        if typeof(label) == "Instance" and label:IsA("ImageLabel") and (layer.Colorized or not anyColorized) then
            entry.Layers[#entry.Layers + 1] = layer
            -- the game recolours through SetColor; while themed the label
            -- stays white and the gradient does the colour
            rawset(layer, "SetColor", function(self, color) self.ImageColor3 = color or self.ImageColor3 end)
            label.ImageColor3 = Color3.new(1, 1, 1)

            local gas = Instance.new("UIGradient")
            gas.Name = "FFT_Gas"
            gas.Color = theme.Gas
            gas.Rotation = 35
            gas.Parent = label
            entry.Decor[#entry.Decor + 1] = gas
            local state = { Gas = gas, Phase = phase, Theme = theme, Label = label }

            if stars then
                local overlay = Instance.new("ImageLabel")
                overlay.Name = "FFT_Stars"
                overlay.BackgroundTransparency = 1
                overlay.Size = UDim2.fromScale(1, 1)
                overlay.ImageColor3 = Color3.new(1, 1, 1)
                overlay.ZIndex = label.ZIndex
                copyImage(label, overlay)
                local sparkle = Instance.new("UIGradient")
                sparkle.Transparency = STARS
                sparkle.Rotation = rng:NextNumber(20, 160)
                sparkle.Parent = overlay
                overlay.Parent = label
                entry.Decor[#entry.Decor + 1] = overlay
                state.Stars, state.Sparkle = overlay, sparkle
            end

            if glowOn and label.Parent then
                local glow = Instance.new("ImageLabel")
                glow.Name = "FFT_Glow"
                glow.BackgroundTransparency = 1
                glow.AnchorPoint = label.AnchorPoint
                glow.Position = label.Position
                glow.Size = label.Size
                glow.ImageColor3 = theme.Glow
                glow.ZIndex = 0
                copyImage(label, glow)
                local scale = Instance.new("UIScale")
                scale.Scale = 1.22
                scale.Parent = glow
                glow.Parent = label.Parent
                entry.Decor[#entry.Decor + 1] = glow
                state.Glow = glow
            end

            Live[label] = state
        end
    end
end

-- makes a sprite wear the wanted theme (nil: none), redoing it when the
-- settings changed or the game rebuilt its layers
local function ensure(sprite, name, kind)
    if type(sprite) ~= "table" then return end
    local entry = Themed[sprite]
    if entry then
        if entry.Name == name and entry.Version == ThemeVersion and entry.Key == firstLayer(sprite) then return end
        undecorate(sprite)
    end
    if name and name ~= "Default" then decorate(sprite, name, kind) end
end

local function isSpecial(note)
    local kind = type(note.NoteData) == "table" and note.NoteData.Type
    if not kind then return false end
    local configs = Framework.Configs and Framework.Configs.VSRG
    local list = configs and configs.IgnoredNoteTypes or { "Death", "Poison", "Mechanic" }
    return table.find(list, kind) ~= nil or (configs and configs.DeathNoteTypes and table.find(configs.DeathNoteTypes, kind) ~= nil)
end

-- your own field only, lane by lane: lanes 1-4 of a 4 key chart are left,
-- down, up and right; other key counts go by each lane's arrow direction
local function scanThemes()
    local handler = Framework.VSRG and Framework.VSRG.InputHandler
    local field = handler and handler.Field
    if not field or type(field.Lanes) ~= "table" then return end
    local fourKey = #field.Lanes == 4
    local tails = attr("ThemeTails", true)
    local receptors = attr("ThemeReceptors", false)
    for index, lane in pairs(field.Lanes) do
        if type(lane) == "table" then
            local dir = fourKey and DIRS[index] or dirName(lane.Direction)
            local name = attr("Theme" .. dir, "Default")
            if name == "Default" then name = nil end
            if type(lane.Notes) == "table" then
                for _, note in pairs(lane.Notes) do
                    if type(note) == "table" and not note.Cleaned and note.Sprite then
                        local wanted = name
                        if wanted and isSpecial(note) then wanted = nil end
                        ensure(note.Sprite, wanted, "Note")
                        if note.Streak then ensure(note.Streak, tails and wanted or nil, "Tail") end
                    end
                end
            end
            local receptorTheme = receptors and name or nil
            ensure(lane.ReceptorSprite, receptorTheme, "Base")
            ensure(lane.PressedSprite, receptorTheme, "Base")
            ensure(lane.ReleasedSprite, receptorTheme, "Base")
        end
    end
end

-- the game hands note visuals back to a shared pool when a note is done; the
-- theme comes off there, so a pooled note never turns up themed on the other
-- side
local function installThemes(handler)
    if ThemeHook or type(handler) ~= "table" or type(handler.ReleaseNoteVisual) ~= "function" then return end
    local original = handler.ReleaseNoteVisual
    ThemeHook = { Handler = handler, Original = original }
    handler.ReleaseNoteVisual = function(self, bundle, ...)
        if type(bundle) == "table" then
            pcall(undecorate, bundle.Sprite)
            pcall(undecorate, bundle.Streak)
        end
        return original(self, bundle, ...)
    end
    bridge:SetAttribute("ThemeStatus", "on")
end

local function removeThemes()
    if not ThemeHook then return end
    pcall(function() ThemeHook.Handler.ReleaseNoteVisual = ThemeHook.Original end)
    for sprite in pairs(Themed) do pcall(undecorate, sprite) end
    ThemeHook = nil
end

bridge.AttributeChanged:Connect(function(name)
    if name:sub(1, 5) == "Theme" and name ~= "ThemeStatus" then ThemeVersion += 1 end
end)

-- the drift, the twinkle and the glow, every frame, for what is on screen
local TAU = math.pi * 2
local animator = RunService.RenderStepped:Connect(function()
    if not ThemeHook then return end
    pcall(scanThemes)
    local animate = attr("ThemeAnimate", true)
    local t = os.clock() * attr("ThemeSpeed", 1)
    for label, state in pairs(Live) do
        if not label.Parent then
            -- the game rebuilt or dropped this layer: its glow goes with it
            if state.Glow then pcall(function() state.Glow:Destroy() end) end
            Live[label] = nil
        elseif label.Visible and label.AbsoluteSize.X > 0 then
            local p = t + state.Phase
            if animate then
                state.Gas.Rotation = 35 + 30 * math.sin(p * TAU / 14)
                state.Gas.Offset = Vector2.new(0.3 * math.sin(p * TAU / 11), 0.25 * math.cos(p * TAU / 17))
            end
            local base = label.ImageTransparency
            if state.Stars then
                local twinkle = animate and (0.35 + 0.65 * (0.5 + 0.5 * math.sin(p * TAU / 6))) or 0.7
                state.Stars.ImageTransparency = 1 - (1 - base) * twinkle * 0.9
                state.Stars.ImageRectOffset = label.ImageRectOffset
                if animate then state.Sparkle.Offset = Vector2.new(((p * 0.08) % 2) - 1, 0) end
            end
            if state.Glow then
                local pulse = animate and (0.85 + 0.15 * math.sin(p * TAU / 8)) or 1
                state.Glow.ImageTransparency = 1 - (1 - base) * state.Theme.GlowAlpha * pulse
                state.Glow.ImageRectOffset = label.ImageRectOffset
                state.Glow.Position, state.Glow.Size = label.Position, label.Size
                state.Glow.Visible = true
            end
        elseif state.Glow then
            state.Glow.Visible = false
        end
    end
end)

local candidates = {}
local function byTime(a, b) return a.Time < b.Time end

local connection
connection = RunService.Heartbeat:Connect(function(dt)
    if not bridge.Parent or attr("Stop", false) then
        if lastField then pcall(releaseAll, lastField) end
        pcall(restoreTiles)
        pcall(removeThemes)
        animator:Disconnect()
        connection:Disconnect()
        return
    end
    local owner = bridge:GetAttribute("Owner")
    if owner and owner ~= WORKER_ID then
        animator:Disconnect()
        connection:Disconnect()
        return
    end
    local playing = attr("Enabled", false)
    if not playing and lastField then
        pcall(releaseAll, lastField)
        lastField = nil
    end
    if not playing then pcall(restoreTiles) end
    if not playing and not attr("ThemesOn", false) and not Framework then return end

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
            animator:Disconnect()
            connection:Disconnect()
            return
        end
        bridge:SetAttribute("Owner", WORKER_ID)
        bridge:SetAttribute("Where", WORKER_ID)
    end

    if attr("ThemesOn", false) and not ThemeHook then pcall(installThemes, Framework.SpriteHandler) end
    if not playing then return end

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
    pcall(showTiles, field)

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
                    press(field, lane, false, stamp(math.max(releaseAt, state.LastPress)))
                    state.Down = false
                else
                    break
                end
            end

            if not note or pressAt > horizon then break end
            press(field, lane, true, stamp(pressAt))
            Planned[note] = true
            bump("Grade" .. Plans[note].Grade)
            state.Down = true
            state.LastPress = pressAt
            local length = tonumber(note.Length) or 0
            state.Hold = length > 0
            state.ReleaseAt = state.Hold and (note.Time + length) or (pressAt + tapLength())
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
                    if tail > noteSize * 1.6 then
                        Holding[index] = {
                            Frame = best, Name = best.Name, Axis = state.Axis, NoteSize = noteSize,
                            ReleaseAt = clock + tail / state.Speed + 0.1,
                        }
                    else
                        TapRelease[index] = clock + pressLength()
                    end
                end
            end
        end
    end
end

track(RunService.RenderStepped:Connect(function(dt)
    if Unloaded then return end
    if not Auto.Enabled or Auto.Mode == "Game" or frozen() then
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

--// link ----------------------------------------------------------------------
-- Funky Friday (the dev script, Games/FunkyFriday.lua) and Funky Friday beta
-- (Games/FunkyFridayBeta.lua) find each other through a relay on the web, not
-- through the game. Every copy in a server joins the same ntfy topic (named
-- from the server's JobId), listens to it over a WebSocket, and posts small
-- JSON messages to it with the executor's request function. Nothing is played
-- on your character, so it works without one, commands land in a fraction of
-- a second, a command reaches exactly the UserId it is for, and messages can
-- carry real values (any duration, your own text).
--  hi    who you are: role and flags. q = true asks everyone to answer with theirs
--  cmd   a command for one beta user (t = their UserId) or all of them (t = 0)
--  ack   a beta copy ran command s
--  bye   the script was closed
-- Every copy says hi with q when it starts, so the ones already here answer.
-- Each copy has its own id (i) and only skips its own messages, so the dev and
-- beta scripts running on the same client find each other through the relay
-- too, which is how you test it alone: you show up on your own beta list.
-- A peer only counts while that player is in this server, commands are only
-- taken from a dev copy in this server, and the dev copy asks again every two
-- minutes to drop anyone whose script died without a bye. Without a WebSocket
-- it polls the topic every few seconds instead. To use your own ntfy server,
-- set getgenv().FunkyFridayRelay = "https://your.server" before loading.
-- Keep this block the same in both files.

local LINK_RELAY = "https://ntfy.sh"
local LINK_BETA, LINK_DEV = 1, 2
local LINK_FLAG_AUTO, LINK_FLAG_PLAYING = 1, 2
local LINK_POLL_EVERY = 6   -- seconds, when there's no WebSocket
local LINK_ASK_EVERY = 120  -- seconds, the dev copy's roll call
local LINK_TEXT_MAX = 120

-- index -> seconds, for the duration picker
local LINK_DURATIONS = { [0] = 1, 2, 3, 5, 8, 10, 15, 20, 30, 60 }
local LINK_MESSAGES = {
    [0] = "👀", "skill issue", "the dev is watching you", "you're not him", "nice miss lol",
    "bro is NOT locked in", "turn around", "L + ratio", "do better", "gg ez",
}
local LINK_COMMANDS = {
    AutoOff = 1, AutoOn = 2, Freeze = 3,
    MissStorm = 4, AllBad = 5, Shaky = 6,
    Shake = 7, Blur = 8, Rainbow = 9, FakeKick = 10,
    Jump = 11, Sit = 12, Message = 13,
    Unload = 14, Kick = 15,
    Bless = 16, CoinFlip = 17, OkOnly = 18,
    UpsideDown = 19, SpinCam = 20, Wobble = 21, Zoom = 22,
    BlackWhite = 23, DeepFry = 24, LightsOut = 25, Flash = 26,
    PopupSpam = 27, Confetti = 28,
    Mute = 29, Chipmunk = 30, DeepVoice = 31,
    Dance = 32,
}

local function linkRequestFunction()
    if typeof(request) == "function" then return request end
    if typeof(http_request) == "function" then return http_request end
    if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
    if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
    if typeof(fluxus) == "table" and typeof(fluxus.request) == "function" then return fluxus.request end
    return nil
end

local function linkSocketFunction()
    if typeof(WebSocket) == "table" then
        local connect = WebSocket.connect or WebSocket.Connect
        if typeof(connect) == "function" then return connect end
    end
    if typeof(syn) == "table" and typeof(syn.websocket) == "table" and typeof(syn.websocket.connect) == "function" then
        return syn.websocket.connect
    end
    return nil
end

-- role: LINK_BETA or LINK_DEV. onCommand(cmd, seconds, text, fromPlayer) runs
-- on beta copies for every command aimed at them.
local function makeLink(role, onCommand)
    local link = { Role = role, Flags = 0, Seq = 0, Peers = {}, Stopped = false, Mode = "starting" }
    local httpRequest = linkRequestFunction()
    local socketConnect = linkSocketFunction()
    local relay = (tostring(Genv.FunkyFridayRelay or LINK_RELAY):gsub("/+$", ""))
    local jobId = (tostring(game.JobId):gsub("[^%w]", ""):lower())
    local topic = "madness-ff-" .. (jobId ~= "" and jobId or ("solo" .. LocalPlayer.UserId))
    local me = LocalPlayer.UserId
    local instance = HttpService:GenerateGUID(false)
    -- where to pick up from: the last message we saw, or the relay's last few
    -- seconds (by its own clock) for the first look
    local lastId = nil
    local seen = {}
    local outbox = {}
    local lastHi = 0

    local function post(message)
        message.v, message.f, message.i = 1, me, instance
        outbox[#outbox + 1] = HttpService:JSONEncode(message)
    end

    local function hello(ask)
        lastHi = os.clock()
        post({ k = "hi", r = role, fl = link.Flags, q = ask or nil })
    end

    local function handle(event)
        if type(event) ~= "table" or event.event ~= "message" or type(event.message) ~= "string" then return end
        if event.id then
            if seen[event.id] then return end
            seen[event.id] = true
            lastId = event.id
        end
        local ok, data = pcall(HttpService.JSONDecode, HttpService, event.message)
        if not ok or type(data) ~= "table" or data.v ~= 1 then return end
        local from = tonumber(data.f)
        if not from or data.i == instance then return end
        local player = Players:GetPlayerByUserId(from)
        if not player then return end

        local peer = link.Peers[player]
        if data.k == "hi" then
            if not peer then
                peer = { Player = player, Ack = 0 }
                link.Peers[player] = peer
            end
            peer.Role = tonumber(data.r)
            peer.Flags = tonumber(data.fl) or 0
            peer.Seen = os.clock()
            if data.q then hello(false) end
        elseif data.k == "bye" then
            link.Peers[player] = nil
        elseif data.k == "ack" then
            if peer then peer.Ack = tonumber(data.s) or peer.Ack end
        elseif data.k == "cmd" and role == LINK_BETA and onCommand then
            if not peer or peer.Role ~= LINK_DEV then return end
            local target = tonumber(data.t) or 0
            if target ~= 0 and target ~= me then return end
            post({ k = "ack", s = tonumber(data.s) or 0 })
            local text = type(data.x) == "string" and data.x:sub(1, LINK_TEXT_MAX) or ""
            task.spawn(pcall, onCommand, tonumber(data.c), tonumber(data.d), text, player)
        end
    end

    local function handleText(text)
        local ok, event = pcall(HttpService.JSONDecode, HttpService, text)
        if ok then handle(event) end
    end

    -- posts go out one at a time, in order. a busy relay (429) gets them again
    task.spawn(function()
        while httpRequest do
            if #outbox == 0 then
                if link.Stopped then break end
                task.wait(0.05)
            else
                local ok, response = pcall(httpRequest, {
                    Url = relay .. "/" .. topic,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "text/plain" },
                    Body = outbox[1],
                })
                if ok and type(response) == "table" and response.StatusCode == 429 and not link.Stopped then
                    task.wait(5)
                else
                    table.remove(outbox, 1)
                end
            end
        end
    end)

    local function since()
        return lastId or "10s"
    end

    local function poll()
        local ok, response = pcall(httpRequest, {
            Url = ("%s/%s/json?poll=1&since=%s"):format(relay, topic, since()),
            Method = "GET",
        })
        if not ok or type(response) ~= "table" or type(response.Body) ~= "string" then return false end
        for line in response.Body:gmatch("[^\n]+") do handleText(line) end
        return (response.StatusCode or 200) < 400
    end

    -- a WebSocket while one stays up, polling otherwise
    task.spawn(function()
        if not httpRequest then
            link.Mode = "off"
            return
        end
        hello(true)
        local socketWorks, hadSocket = socketConnect ~= nil, false
        while not link.Stopped do
            local socket
            if socketWorks then
                local url = ("%s/%s/ws?since=%s"):format(relay:gsub("^http", "ws"), topic, since())
                local ok, result = pcall(socketConnect, url)
                if ok and result then
                    socket, hadSocket = result, true
                elseif not hadSocket then
                    socketWorks = false -- never got one up, so don't keep trying
                end
            end
            if socket then
                link.Mode = "live"
                local closed = false
                local onMessage = socket.OnMessage:Connect(handleText)
                local onClose = socket.OnClose:Connect(function() closed = true end)
                while not closed and not link.Stopped do task.wait(0.25) end
                pcall(function() onMessage:Disconnect() end)
                pcall(function() onClose:Disconnect() end)
                pcall(function() socket:Close() end)
                if not link.Stopped then
                    link.Mode = "reconnecting"
                    task.wait(2)
                end
            else
                link.Mode = poll() and "polling" or "relay unreachable"
                task.wait(LINK_POLL_EVERY)
            end
        end
    end)

    -- flag changes, the dev copy's roll call, and players who left
    task.spawn(function()
        local sentFlags = link.Flags
        local nextAsk = os.clock() + LINK_ASK_EVERY
        local askedAt = nil
        while not link.Stopped do
            local now = os.clock()
            if link.Flags ~= sentFlags and now - lastHi >= 3 then
                sentFlags = link.Flags
                hello(false)
            end
            if role == LINK_DEV and now >= nextAsk then
                nextAsk = now + LINK_ASK_EVERY
                askedAt = now
                hello(true)
            end
            for player, peer in pairs(link.Peers) do
                local silent = askedAt and now - askedAt > 10 and peer.Seen < askedAt
                if not player.Parent or silent then link.Peers[player] = nil end
            end
            if askedAt and now - askedAt > 10 then askedAt = nil end
            task.wait(0.5)
        end
    end)

    -- sends a command to one beta player, or to every one with no target.
    -- returns its sequence number, which the target acks once it has run it
    function link.Send(cmd, seconds, text, target)
        link.Seq = link.Seq % 9999 + 1
        post({
            k = "cmd", c = cmd, d = seconds, s = link.Seq,
            x = text and tostring(text):sub(1, LINK_TEXT_MAX) or nil,
            t = target and target.UserId or 0,
        })
        return link.Seq
    end

    -- peers of a role, sorted by name
    function link.List(wanted)
        local list = {}
        for _, peer in pairs(link.Peers) do
            if not wanted or peer.Role == wanted then list[#list + 1] = peer end
        end
        table.sort(list, function(a, b) return a.Player.Name:lower() < b.Player.Name:lower() end)
        return list
    end

    function link.Status()
        if link.Mode == "off" then return "off: this executor has no request function" end
        if link.Mode == "live" then return "live over a WebSocket" end
        if link.Mode == "polling" then return ("on, checking every %ds (no WebSocket)"):format(LINK_POLL_EVERY) end
        return link.Mode .. "..."
    end

    -- says bye so the others drop us straight away, then stops
    function link.Stop()
        if link.Stopped then return end
        post({ k = "bye" })
        link.Stopped = true
    end

    return link
end

local Link = makeLink(LINK_DEV)

--// pranks --------------------------------------------------------------------
-- What a command does when it lands: on beta copies when the dev script sends
-- it, or on the dev copy itself when it targets "Me", to see it first. All of
-- it is on this client only, and all of it wears off. Keep this block the same
-- in Games/FunkyFriday.lua and Games/FunkyFridayBeta.lua.
--
-- hooks: SetAuto(state), Freeze(seconds), Chances(map, seconds), Unload()

local function makePranks(hooks)
    local RunService = game:GetService("RunService")
    local Lighting = game:GetService("Lighting")
    local pranks = { Stopped = false }
    local junk = {} -- guis, effects, connections and render binds, cleaned up on Stop
    local rng = Random.new()

    local function keep(thing)
        junk[#junk + 1] = thing
        return thing
    end

    -- for a while, then back
    local function lasting(seconds, onEnd)
        task.delay(seconds, function()
            if not pranks.Stopped then pcall(onEnd) end
        end)
    end

    local function screen()
        local gui = Instance.new("ScreenGui")
        gui.Name = "FFP_" .. HttpService:GenerateGUID(false):sub(1, 6)
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 1000
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
        gui.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
        return keep(gui)
    end

    local function bigText(parent, text, position, size)
        local label = Instance.new("TextLabel")
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = position or UDim2.fromScale(0.5, 0.3)
        label.Size = size or UDim2.fromScale(0.8, 0.12)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBlack
        label.TextScaled = true
        label.TextColor3 = Color3.new(1, 1, 1)
        label.TextStrokeTransparency = 0
        label.Text = text
        label.Parent = parent
        return label
    end

    local function popup(text, seconds)
        local gui = screen()
        bigText(gui, text)
        lasting(seconds, function() gui:Destroy() end)
    end

    -- a full screen colour over everything
    local function cover(color, transparency)
        local gui = screen()
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = color
        frame.BackgroundTransparency = transparency
        frame.BorderSizePixel = 0
        frame.Parent = gui
        return gui, frame
    end

    -- runs after the game's camera every frame, for a while
    local function cameraEffect(seconds, step)
        local name = "FFP_Cam_" .. HttpService:GenerateGUID(false):sub(1, 6)
        local started = os.clock()
        RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, function()
            local camera = workspace.CurrentCamera
            if camera then pcall(step, camera, os.clock() - started) end
        end)
        keep(name)
        lasting(seconds, function() RunService:UnbindFromRenderStep(name) end)
    end

    local function colorEffect(seconds, props, step)
        local color = Instance.new("ColorCorrectionEffect")
        for key, value in pairs(props) do color[key] = value end
        color.Parent = Lighting
        keep(color)
        local connection = step and keep(RunService.RenderStepped:Connect(function() step(color) end))
        lasting(seconds, function()
            if connection then connection:Disconnect() end
            color:Destroy()
        end)
    end

    local function playingSounds()
        local list = {}
        for _, root in ipairs({ workspace, game:GetService("SoundService"), LocalPlayer:FindFirstChildOfClass("PlayerGui") }) do
            for _, sound in ipairs(root and root:GetDescendants() or {}) do
                if sound:IsA("Sound") and sound.Playing then list[#list + 1] = sound end
            end
        end
        return list
    end

    local function pitch(seconds, octave)
        for _, sound in ipairs(playingSounds()) do
            local shift = Instance.new("PitchShiftSoundEffect")
            shift.Octave = octave
            shift.Parent = sound
            keep(shift)
            lasting(seconds, function() shift:Destroy() end)
        end
    end

    local function humanoid()
        local character = LocalPlayer.Character
        return character and character:FindFirstChildOfClass("Humanoid")
    end

    local function fakeKick(seconds)
        local gui, dim = cover(Color3.new(0, 0, 0), 0.35)
        dim.Active = true
        local box = Instance.new("Frame")
        box.AnchorPoint = Vector2.new(0.5, 0.5)
        box.Position = UDim2.fromScale(0.5, 0.5)
        box.Size = UDim2.fromOffset(400, 200)
        box.BackgroundColor3 = Color3.fromRGB(57, 59, 61)
        box.BorderSizePixel = 0
        box.Parent = dim
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
        local function text(content, y, height, size, bold)
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Position = UDim2.new(0, 20, 0, y)
            label.Size = UDim2.new(1, -40, 0, height)
            label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
            label.TextSize = size
            label.TextWrapped = true
            label.TextColor3 = Color3.new(1, 1, 1)
            label.Text = content
            label.Parent = box
            return label
        end
        text("Disconnected", 14, 30, 20, true)
        local body = text("You were kicked from this experience: skill issue\n(Error Code: 267)", 56, 80, 16, false)
        local button = Instance.new("TextLabel")
        button.AnchorPoint = Vector2.new(0.5, 1)
        button.Position = UDim2.new(0.5, 0, 1, -16)
        button.Size = UDim2.fromOffset(180, 36)
        button.BackgroundColor3 = Color3.new(1, 1, 1)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 16
        button.TextColor3 = Color3.fromRGB(57, 59, 61)
        button.Text = "Leave"
        button.Parent = box
        Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
        lasting(seconds, function()
            body.Text = "jk 😭"
            lasting(1.5, function() gui:Destroy() end)
        end)
    end

    local C = LINK_COMMANDS
    local RUN = {
        [C.AutoOff] = function() hooks.SetAuto(false) end,
        [C.AutoOn] = function() hooks.SetAuto(true) end,
        [C.Freeze] = function(seconds) hooks.Freeze(seconds) end,
        [C.MissStorm] = function(seconds) hooks.Chances({ Miss = 100 }, seconds) end,
        [C.AllBad] = function(seconds) hooks.Chances({ Bad = 100 }, seconds) end,
        [C.Shaky] = function(seconds) hooks.Chances({ Good = 30, Ok = 35, Bad = 25, Miss = 10 }, seconds) end,
        [C.Bless] = function(seconds) hooks.Chances({ Sick = 100 }, seconds) end,
        [C.CoinFlip] = function(seconds) hooks.Chances({ Sick = 50, Miss = 50 }, seconds) end,
        [C.OkOnly] = function(seconds) hooks.Chances({ Ok = 100 }, seconds) end,

        [C.Shake] = function(seconds)
            cameraEffect(seconds, function(camera)
                camera.CFrame *= CFrame.new(rng:NextNumber(-0.6, 0.6), rng:NextNumber(-0.6, 0.6), 0)
                    * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-3, 3)))
            end)
        end,
        [C.UpsideDown] = function(seconds)
            cameraEffect(seconds, function(camera) camera.CFrame *= CFrame.Angles(0, 0, math.pi) end)
        end,
        [C.SpinCam] = function(seconds)
            cameraEffect(seconds, function(camera, t) camera.CFrame *= CFrame.Angles(0, 0, t * math.pi) end)
        end,
        [C.Wobble] = function(seconds)
            cameraEffect(seconds, function(camera, t)
                camera.CFrame *= CFrame.new(math.sin(t * 1.7) * 0.8, math.sin(t * 2.3) * 0.4, 0)
                    * CFrame.Angles(0, 0, math.rad(math.sin(t * 1.3) * 12))
            end)
        end,
        [C.Zoom] = function(seconds)
            local camera = workspace.CurrentCamera
            local before = camera and camera.FieldOfView or 70
            cameraEffect(seconds, function(cam) cam.FieldOfView = 120 end)
            lasting(seconds + 0.05, function()
                if workspace.CurrentCamera then workspace.CurrentCamera.FieldOfView = before end
            end)
        end,

        [C.Blur] = function(seconds)
            local blur = Instance.new("BlurEffect")
            blur.Size = 24
            blur.Parent = Lighting
            keep(blur)
            lasting(seconds, function() blur:Destroy() end)
        end,
        [C.Rainbow] = function(seconds)
            colorEffect(seconds, { Saturation = 1 }, function(color)
                color.TintColor = Color3.fromHSV((os.clock() * 0.6) % 1, 0.6, 1)
            end)
        end,
        [C.BlackWhite] = function(seconds) colorEffect(seconds, { Saturation = -1 }) end,
        [C.DeepFry] = function(seconds)
            colorEffect(seconds, { Saturation = 2, Contrast = 1, TintColor = Color3.fromRGB(255, 190, 120) })
        end,
        [C.LightsOut] = function(seconds)
            local gui = cover(Color3.new(0, 0, 0), 0.08)
            lasting(seconds, function() gui:Destroy() end)
        end,
        [C.Flash] = function()
            local gui, frame = cover(Color3.new(1, 1, 1), 0)
            local started = os.clock()
            local connection
            connection = keep(RunService.RenderStepped:Connect(function()
                local t = os.clock() - started
                frame.BackgroundTransparency = math.clamp((t - 0.4) / 1.6, 0, 1)
                if t > 2 then
                    connection:Disconnect()
                    gui:Destroy()
                end
            end))
        end,

        [C.FakeKick] = fakeKick,
        [C.Message] = function(_, text) popup(text ~= "" and text or "👀", 3) end,
        [C.PopupSpam] = function(seconds)
            local gui = screen()
            local ends = os.clock() + seconds
            task.spawn(function()
                while os.clock() < ends and not pranks.Stopped and gui.Parent do
                    local label = bigText(gui, LINK_MESSAGES[rng:NextInteger(0, 9)],
                        UDim2.fromScale(rng:NextNumber(0.15, 0.85), rng:NextNumber(0.15, 0.85)),
                        UDim2.fromScale(0.35, 0.07))
                    label.Rotation = rng:NextNumber(-20, 20)
                    label.TextColor3 = Color3.fromHSV(rng:NextNumber(), 0.7, 1)
                    task.delay(1.2, function() label:Destroy() end)
                    task.wait(0.25)
                end
                gui:Destroy()
            end)
        end,
        [C.Confetti] = function(seconds)
            local gui = screen()
            local pieces = { "🎉", "✨", "🎵", "⭐", "💜", "🎶" }
            local falling = {}
            local ends = os.clock() + seconds
            local nextDrop = 0
            local connection
            connection = keep(RunService.RenderStepped:Connect(function(dt)
                local now = os.clock()
                if now < ends and now >= nextDrop then
                    nextDrop = now + 0.05
                    local label = bigText(gui, pieces[rng:NextInteger(1, #pieces)],
                        UDim2.fromScale(rng:NextNumber(0, 1), -0.05), UDim2.fromOffset(36, 36))
                    falling[label] = rng:NextNumber(0.25, 0.5)
                end
                for label, speed in pairs(falling) do
                    label.Position += UDim2.fromScale(0, speed * dt)
                    label.Rotation += 90 * dt
                    if label.Position.Y.Scale > 1.1 then
                        falling[label] = nil
                        label:Destroy()
                    end
                end
                if now >= ends and next(falling) == nil then
                    connection:Disconnect()
                    gui:Destroy()
                end
            end))
        end,

        [C.Mute] = function(seconds)
            local muted = {}
            for _, sound in ipairs(playingSounds()) do
                muted[sound] = sound.Volume
                sound.Volume = 0
            end
            lasting(seconds, function()
                for sound, volume in pairs(muted) do pcall(function() sound.Volume = volume end) end
            end)
        end,
        [C.Chipmunk] = function(seconds) pitch(seconds, 1.6) end,
        [C.DeepVoice] = function(seconds) pitch(seconds, 0.6) end,

        [C.Jump] = function()
            local h = humanoid()
            if h then
                h.Jump = true
                pcall(h.ChangeState, h, Enum.HumanoidStateType.Jumping)
            end
        end,
        [C.Sit] = function()
            local h = humanoid()
            if h then h.Sit = true end
        end,
        [C.Dance] = function(seconds)
            local h = humanoid()
            local animator = h and h:FindFirstChildOfClass("Animator")
            if not animator then return end
            local animation = Instance.new("Animation")
            animation.AnimationId = "rbxassetid://507771019" -- Roblox's own dance emote
            local track = animator:LoadAnimation(animation)
            track.Priority = Enum.AnimationPriority.Action
            track.Looped = true
            track:Play()
            keep(track)
            lasting(seconds, function() track:Stop() end)
        end,

        [C.Unload] = function() hooks.Unload() end,
        [C.Kick] = function() LocalPlayer:Kick("the dev kicked you lol") end,
    }

    -- seconds for the commands that last a while, text for Message
    function pranks.Run(cmd, seconds, text)
        if pranks.Stopped then return end
        local fn = RUN[cmd]
        if fn then task.spawn(pcall, fn, math.clamp(tonumber(seconds) or 5, 0.5, 120), tostring(text or "")) end
    end

    function pranks.Stop()
        pranks.Stopped = true
        for _, thing in ipairs(junk) do
            pcall(function()
                if type(thing) == "string" then
                    RunService:UnbindFromRenderStep(thing)
                elseif typeof(thing) == "RBXScriptConnection" then
                    thing:Disconnect()
                elseif typeof(thing) == "Instance" and thing:IsA("AnimationTrack") then
                    thing:Stop()
                else
                    thing:Destroy()
                end
            end)
        end
        table.clear(junk)
    end

    return pranks
end

local Pranks = makePranks({
    SetAuto = function(state)
        if Library and Library.Toggles and Library.Toggles.ff_enabled then
            pcall(function() Library.Toggles.ff_enabled:SetValue(state) end)
        end
        if Auto.Enabled ~= state then
            Auto.Enabled = state
            if state and Auto.Mode == "Game" then startWorkers() end
            pushSettings()
        end
    end,
    Freeze = function(seconds)
        Prank.FrozenUntil = os.clock() + seconds
        pushSettings()
        task.delay(seconds + 0.05, pushSettings)
    end,
    Chances = function(map, seconds)
        Prank.Chance = map
        Prank.ChanceUntil = os.clock() + seconds
        pushSettings()
        task.delay(seconds + 0.05, pushSettings)
    end,
    Unload = function()
        if Genv.__FunkyFridayStop then Genv.__FunkyFridayStop() end
    end,
})

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Auto.Enabled = false
    pcall(releaseScreen)
    Link.Stop()
    Pranks.Stop()
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

--// chat commands -------------------------------------------------------------
-- "/e hide" hides the menu's mobile open button and "/e show" brings it back.
-- The button is Ui3's "Toggle" TextButton in its ScreenGui (made on mobile
-- only). Commands are caught from every chat path: Player.Chatted, the new
-- chat's SendingMessage, and its /e emote command, which takes /e messages
-- before they are sent.

local ButtonHidden = false

local function ui3Button()
    local gui = Library and Library.ScreenGui
    if typeof(gui) ~= "Instance" then return nil end
    for _, child in ipairs(gui:GetChildren()) do
        if child:IsA("TextButton") and child.Text == "Toggle" then return child end
    end
    return nil
end

local function setButtonHidden(hidden)
    ButtonHidden = hidden
    local button = ui3Button()
    if button then button.Visible = not hidden end
    log("Info", hidden and "menu button hidden (/e show brings it back)" or "menu button shown")
end

local LastCommand = { Text = nil, At = 0 }
local function chatCommand(text)
    if Unloaded or type(text) ~= "string" then return end
    local cmd = string.lower(text)
    cmd = cmd:gsub("%s+", " ")
    cmd = cmd:match("^%s*(.-)%s*$")
    if cmd ~= "/e hide" and cmd ~= "/e show" then return end
    -- the same message can come in through more than one path
    if LastCommand.Text == cmd and os.clock() - LastCommand.At < 0.5 then return end
    LastCommand.Text, LastCommand.At = cmd, os.clock()
    setButtonHidden(cmd == "/e hide")
end

track(LocalPlayer.Chatted:Connect(chatCommand))
task.spawn(function()
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        track(TextChatService.SendingMessage:Connect(function(message) chatCommand(message.Text) end))
        local commands = TextChatService:WaitForChild("TextChatCommands", 10)
        local emote = commands and commands:WaitForChild("RBXEmoteCommand", 10)
        if emote then track(emote.Triggered:Connect(function(_, text) chatCommand(text) end)) end
    end)
end)

-- keep it hidden if anything shows it again
task.spawn(function()
    while not Unloaded and not Library.Unloaded do
        if ButtonHidden then
            local button = ui3Button()
            if button and button.Visible then button.Visible = false end
        end
        task.wait(0.5)
    end
end)

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

    play:AddToggle('ff_semilegit', {
        Text = 'Semi legit',
        Tooltip = 'game mode: every press goes through the game\'s own mobile lane tiles, the way a finger does, so the tiles light up on each note and a recording looks like real pressing. timing stays exact',
        Default = Auto.SemiLegit,
        Callback = function(state)
            Auto.SemiLegit = state
            pushSettings()
        end,
    })

    play:AddToggle('ff_semitiles', {
        Text = 'Show the tiles on PC too',
        Tooltip = 'semi legit: the game only shows its touch tiles for touch input. this shows them on PC as well, so the presses can be seen',
        Default = Auto.SemiTiles,
        Callback = function(state)
            Auto.SemiTiles = state
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

    chances:AddToggle('ff_perfect', {
        Text = 'Perfect hits (0.00ms)',
        Tooltip = 'every note hit dead on its time, over the chances below. exact in game mode, where each press is stamped to the note\'s own time; the screen modes get within a frame',
        Default = Auto.Perfect,
        Callback = function(state)
            Auto.Perfect = state
            pushSettings()
        end,
    })

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

    local pressBox = Tab:AddRightGroupbox('Key hold after a hit', 'hand')

    pressBox:AddLabel('How long the key stays down after hitting a normal note. It always lets go before the next note in the same lane, so fast streams still work. Hold notes are always held for their full length.', true)

    pressBox:AddToggle('ff_presshold', {
        Text = 'Hold the key',
        Tooltip = 'off lets go straight away',
        Default = Auto.PressHold,
        Callback = function(state)
            Auto.PressHold = state
            pushSettings()
        end,
    })

    pressBox:AddSlider('ff_pressms', {
        Text = 'Hold for',
        Min = 1, Max = 300, Default = Auto.PressHoldMs, Rounding = 0, Suffix = 'ms',
        Callback = function(value)
            Auto.PressHoldMs = value
            pushSettings()
        end,
    })

    pressBox:AddToggle('ff_pressrandom', {
        Text = 'Randomize',
        Tooltip = 'each hit holds a different length, within the range below',
        Default = Auto.PressRandom,
        Callback = function(state)
            Auto.PressRandom = state
            pushSettings()
        end,
    })

    pressBox:AddSlider('ff_pressrange', {
        Text = 'Random range',
        Tooltip = 'e.g. 60ms with a 50% range holds each hit somewhere between 30ms and 90ms',
        Min = 0, Max = 100, Default = Auto.PressRandomRange, Rounding = 0, Suffix = '%',
        Callback = function(value)
            Auto.PressRandomRange = value
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

do
    local Tab = Window:AddTab('Theme', 'palette', 'Client side note themes')

    local lanes = Tab:AddLeftGroupbox('Note themes', 'palette')
    lanes:AddLabel('Only you see these, and only on your own side: the opponent\'s notes keep their skin. Each lane can have its own theme, or stay on your normal skin. Death and poison notes are never themed, so you can still tell them apart.', true)

    local function changed()
        pushTheme()
        if themesOn() then startWorkers() end
    end

    local dropdowns = {}
    for _, dir in ipairs(DIRECTIONS) do
        dropdowns[dir] = lanes:AddDropdown('ff_theme_' .. dir:lower(), {
            Text = dir,
            Values = THEME_NAMES,
            Default = Theme[dir],
            Callback = function(value)
                Theme[dir] = value or "Default"
                changed()
            end,
        })
    end

    local allChoice = "Violet Nebula"
    lanes:AddDropdown('ff_theme_all', {
        Text = 'Set every lane to',
        Values = THEME_NAMES,
        Default = allChoice,
        Callback = function(value) allChoice = value or "Default" end,
    })
    lanes:AddButton({
        Text = 'Apply to all lanes',
        Func = function()
            for _, dir in ipairs(DIRECTIONS) do
                Theme[dir] = allChoice
                pcall(function() dropdowns[dir]:SetValue(allChoice) end)
            end
            changed()
        end,
    })

    local look = Tab:AddRightGroupbox('Look', 'sparkles')
    look:AddToggle('ff_theme_animate', {
        Text = 'Animated',
        Tooltip = 'the colours drift and turn like the website\'s gas clouds, the stars twinkle and the glow breathes',
        Default = Theme.Animate,
        Callback = function(v) Theme.Animate = v; changed() end,
    })
    look:AddSlider('ff_theme_speed', {
        Text = 'Animation speed',
        Min = 0.1, Max = 4, Default = Theme.Speed, Rounding = 1, Suffix = 'x',
        Callback = function(v) Theme.Speed = v; changed() end,
    })
    look:AddToggle('ff_theme_stars', { Text = 'Twinkling stars', Default = Theme.Stars, Callback = function(v) Theme.Stars = v; changed() end })
    look:AddToggle('ff_theme_glow', { Text = 'Glow', Default = Theme.Glow, Callback = function(v) Theme.Glow = v; changed() end })
    look:AddToggle('ff_theme_tails', { Text = 'Hold tails too', Default = Theme.Tails, Callback = function(v) Theme.Tails = v; changed() end })
    look:AddToggle('ff_theme_receptors', {
        Text = 'Receptors too',
        Tooltip = 'the arrows notes land on, and the skin previews in menus',
        Default = Theme.Receptors,
        Callback = function(v) Theme.Receptors = v; changed() end,
    })

    local status = look:AddLabel('themes: off', true)
    every(0.5, function()
        local hooked = Bridge:GetAttribute("ThemeStatus")
        status:SetText(themesOn() and ("themes: " .. (hooked or "looking for the game...")) or "themes: off")
    end)
    look:AddLabel('Changes show straight away, on notes already on screen too. Needs getgc or run_on_actor, like game mode.', true)
end

--// dev ---------------------------------------------------------------------
-- Everyone in the lobby running the beta script (Games/FunkyFridayBeta.lua),
-- found through the link above, and commands to mess with them. They only
-- ever touch the beta player's own client, and they all wear off.

local function peerName(player)
    if player.DisplayName ~= player.Name then return player.DisplayName .. " (@" .. player.Name .. ")" end
    return "@" .. player.Name
end

do
    local Tab = Window:AddTab('Dev', 'shield', 'Who is on beta in this lobby')

    local betaBox = Tab:AddBigGroupbox('Beta users in this lobby', 'users')
    local betaLabel = betaBox:AddLabel('looking...', true)
    every(0.5, function()
        local lines = {}
        for _, peer in ipairs(Link.List(LINK_BETA)) do
            local auto = bit32.band(peer.Flags or 0, LINK_FLAG_AUTO) ~= 0
            local playing = bit32.band(peer.Flags or 0, LINK_FLAG_PLAYING) ~= 0
            local you = peer.Player == LocalPlayer and " (you, found through the relay)" or ""
            lines[#lines + 1] = ("• %s%s   auto: %s%s"):format(peerName(peer.Player), you, auto and "on" or "off", playing and ", in a song" or "")
        end
        betaLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "nobody on beta in this lobby right now")
    end)

    local devBox = Tab:AddLeftGroupbox('Other dev users', 'shield')
    local devLabel = devBox:AddLabel('-', true)
    every(1, function()
        local names = {}
        for _, peer in ipairs(Link.List(LINK_DEV)) do names[#names + 1] = peerName(peer.Player) end
        devLabel:SetText(#names > 0 and table.concat(names, "\n") or "just you")
    end)

    local linkBox = Tab:AddRightGroupbox('Link', 'radio')
    local linkLabel = linkBox:AddLabel('-', true)
    every(1, function()
        linkLabel:SetText("link: " .. Link.Status())
    end)
    linkBox:AddLabel('The scripts find each other through a relay on the web (an ntfy topic for this server), not through the game, so nothing shows on your character and it works without one. A beta user shows up here about a second after they load it.', true)
end

do
    local Tab = Window:AddTab('Cmds', 'terminal', 'Mess with whoever is on beta')

    -- "Me (no relay)" runs the command on this client straight away, to see what
    -- it does. to test the relay itself, run the beta script on this client too
    -- and pick your own name: that goes out to the relay and back
    local ME = "Me (no relay)"
    local targetName = "Everyone"
    local durationArg = 4 -- 8s
    local messageArg = 1
    local customMessage = ""
    local Sent = nil -- { Seq, Target, Name, At, Self }

    local function targetPlayer()
        if targetName == "Everyone" or targetName == ME then return nil end
        return Players:FindFirstChild(targetName)
    end

    local function send(name, cmd, seconds, text)
        if targetName == ME then
            Pranks.Run(cmd, seconds, text)
            Sent = { Name = name, At = os.clock(), Self = true }
            return
        end
        if #Link.List(LINK_BETA) == 0 then
            Library:Notify({ Title = 'Nobody on beta here', Description = 'There\'s no one running the beta script in this lobby. Pick "Me (no relay)" to try it on yourself, or run the beta script here too to test the relay.', Time = 3 })
            return
        end
        local target = targetPlayer()
        if targetName ~= "Everyone" and (not target or not Link.Peers[target]) then
            Library:Notify({ Title = 'Not here', Description = targetName .. ' isn\'t on beta in this lobby anymore.', Time = 3 })
            return
        end
        local seq = Link.Send(cmd, seconds, text, target)
        Sent = { Seq = seq, Target = target, Name = name, At = os.clock() }
        log("Info", ("sent %s to %s"):format(name, target and peerName(target) or "every beta user"))
    end

    local targetBox = Tab:AddLeftGroupbox('Target', 'crosshair')
    local targetDropdown = targetBox:AddDropdown('ff_cmd_target', {
        Text = 'Send to',
        Tooltip = 'Everyone on beta, one of them (your own name if you run beta here too), or Me (no relay) to try it locally',
        Values = { 'Everyone', ME },
        Default = 'Everyone',
        Callback = function(value) targetName = value or "Everyone" end,
    })
    local durationValues = {}
    for arg = 0, 9 do durationValues[#durationValues + 1] = LINK_DURATIONS[arg] .. 's' end
    targetBox:AddDropdown('ff_cmd_duration', {
        Text = 'How long',
        Tooltip = 'for the commands that last a while: freeze, miss storm, shake, blur...',
        Values = durationValues,
        Default = durationValues[durationArg + 1],
        Callback = function(value)
            local index = table.find(durationValues, value)
            if index then durationArg = index - 1 end
        end,
    })
    local sentLabel = targetBox:AddLabel('last: -', true)

    local lastList = ""
    every(1, function()
        local names = { 'Everyone', ME }
        for _, peer in ipairs(Link.List(LINK_BETA)) do names[#names + 1] = peer.Player.Name end
        local key = table.concat(names, ",")
        if key ~= lastList then
            lastList = key
            targetDropdown:SetValues(names)
        end
        if not table.find(names, targetName) then
            targetName = "Everyone"
            targetDropdown:SetValue("Everyone")
        end
    end)

    every(0.25, function()
        if not Sent then return end
        if Sent.Self then
            sentLabel:SetText(("last: %s -> you: done"):format(Sent.Name))
            return
        end
        local done, total = 0, 0
        for _, peer in ipairs(Link.List(LINK_BETA)) do
            if not Sent.Target or peer.Player == Sent.Target then
                total += 1
                if peer.Ack == Sent.Seq then done += 1 end
            end
        end
        local state
        if total > 0 and done == total then
            state = "done"
        elseif os.clock() - Sent.At > 10 then
            state = done > 0 and ("reached %d of %d"):format(done, total) or "didn't go through"
        else
            state = "sending..."
        end
        sentLabel:SetText(("last: %s -> %s: %s"):format(Sent.Name,
            Sent.Target and Sent.Target.Name or "everyone", state))
    end)

    local function button(box, text, cmd, timed, tooltip)
        box:AddButton({
            Text = text,
            Tooltip = tooltip,
            Func = function() send(text, cmd, timed and LINK_DURATIONS[durationArg] or 0) end,
        })
    end

    local autoBox = Tab:AddLeftGroupbox('Their auto play', 'music')
    button(autoBox, 'Turn auto off', LINK_COMMANDS.AutoOff, false, 'flips their auto play toggle off')
    button(autoBox, 'Turn auto on', LINK_COMMANDS.AutoOn, false, 'flips their auto play toggle on')
    button(autoBox, 'Freeze auto', LINK_COMMANDS.Freeze, true, 'auto play stops hitting for a while, then carries on. their toggle stays on')

    local judgeBox = Tab:AddRightGroupbox('Their judgements', 'dices')
    button(judgeBox, 'Miss storm', LINK_COMMANDS.MissStorm, true, 'every note gets missed for a while')
    button(judgeBox, 'All Bads', LINK_COMMANDS.AllBad, true, 'every hit is a Bad for a while')
    button(judgeBox, 'All Oks', LINK_COMMANDS.OkOnly, true, 'every hit is an Ok for a while')
    button(judgeBox, 'Shaky hands', LINK_COMMANDS.Shaky, true, 'a mess of Goods, Oks, Bads and some misses for a while')
    button(judgeBox, 'Coin flip', LINK_COMMANDS.CoinFlip, true, 'every note is a 50/50 between a Sick and a miss')
    button(judgeBox, 'Bless them', LINK_COMMANDS.Bless, true, 'all Sicks for a while, to be nice')

    local cameraBox = Tab:AddLeftGroupbox('Their camera', 'camera')
    button(cameraBox, 'Camera shake', LINK_COMMANDS.Shake, true)
    button(cameraBox, 'Upside down', LINK_COMMANDS.UpsideDown, true)
    button(cameraBox, 'Spin', LINK_COMMANDS.SpinCam, true, 'the camera rolls round and round')
    button(cameraBox, 'Seasick', LINK_COMMANDS.Wobble, true, 'the camera sways side to side')
    button(cameraBox, 'Fish eye', LINK_COMMANDS.Zoom, true, 'a very wide field of view')

    local screenBox = Tab:AddRightGroupbox('Their screen', 'monitor')
    button(screenBox, 'Blur', LINK_COMMANDS.Blur, true)
    button(screenBox, 'Rainbow', LINK_COMMANDS.Rainbow, true)
    button(screenBox, 'Black and white', LINK_COMMANDS.BlackWhite, true)
    button(screenBox, 'Deep fry', LINK_COMMANDS.DeepFry, true, 'cranked colours and contrast')
    button(screenBox, 'Lights out', LINK_COMMANDS.LightsOut, true, 'the screen goes almost black')
    button(screenBox, 'Flashbang', LINK_COMMANDS.Flash, false, 'a white flash that fades out')
    button(screenBox, 'Confetti', LINK_COMMANDS.Confetti, true)
    button(screenBox, 'Fake kick', LINK_COMMANDS.FakeKick, true, 'a fake "Disconnected" box over their screen, then "jk"')

    local messageBox = Tab:AddLeftGroupbox('Messages', 'message-circle')
    local messageValues = {}
    for arg = 0, 9 do messageValues[#messageValues + 1] = LINK_MESSAGES[arg] end
    messageBox:AddDropdown('ff_cmd_message', {
        Text = 'Message',
        Values = messageValues,
        Default = messageValues[messageArg + 1],
        Callback = function(value)
            local index = table.find(messageValues, value)
            if index then messageArg = index - 1 end
        end,
    })
    messageBox:AddButton({
        Text = 'Pop it on their screen',
        Func = function() send('Message', LINK_COMMANDS.Message, 0, LINK_MESSAGES[messageArg]) end,
    })
    messageBox:AddInput('ff_cmd_custom_message', {
        Text = 'Your own message',
        Placeholder = 'type anything, up to ' .. LINK_TEXT_MAX .. ' characters',
        Default = '',
        Finished = false,
        Callback = function(value) customMessage = tostring(value or '') end,
    })
    messageBox:AddButton({
        Text = 'Pop your own message',
        Func = function()
            if customMessage:match('^%s*$') then
                Library:Notify({ Title = 'Nothing to send', Description = 'Type a message first.', Time = 3 })
                return
            end
            send('Message', LINK_COMMANDS.Message, 0, customMessage:sub(1, LINK_TEXT_MAX))
        end,
    })
    button(messageBox, 'Popup spam', LINK_COMMANDS.PopupSpam, true, 'all the messages, all over their screen')

    local soundBox = Tab:AddRightGroupbox('Their sound', 'volume-2')
    button(soundBox, 'Mute the game', LINK_COMMANDS.Mute, true, 'everything playing goes silent on their side, the song keeps going')
    button(soundBox, 'Chipmunk song', LINK_COMMANDS.Chipmunk, true, 'everything playing goes up in pitch, same speed')
    button(soundBox, 'Deep voice song', LINK_COMMANDS.DeepVoice, true, 'everything playing goes down in pitch, same speed')

    local charBox = Tab:AddLeftGroupbox('Their character', 'person-standing')
    button(charBox, 'Make them jump', LINK_COMMANDS.Jump, false)
    button(charBox, 'Make them sit', LINK_COMMANDS.Sit, false)
    button(charBox, 'Make them dance', LINK_COMMANDS.Dance, true, 'plays Roblox\'s dance emote on them for a while')

    local otherBox = Tab:AddRightGroupbox('Other', 'skull')
    button(otherBox, 'Unload their beta', LINK_COMMANDS.Unload, false, 'closes their beta script (on Me (no relay): closes this one)')
    otherBox:AddButton({
        Text = 'Kick them (for real)',
        Tooltip = 'actually kicks them from the server, double click. they can just rejoin',
        Risky = true,
        DoubleClick = true,
        Func = function() send('Kick', LINK_COMMANDS.Kick, 0) end,
    })
end

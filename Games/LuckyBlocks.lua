--// Lucky Blocks ------------------------------------------------------------------
-- Bases are workspace.Spawn1 .. Spawn8, plus workspace.CenterBlocks for the
-- contested ones in the middle. Each holds a Givers model of BlockGiverLucky1,
-- BlockGiverSuper1, BlockGiverDiamond1, BlockGiverRainbow1, BlockGiverGalaxy1,
-- BlockGiverVoid1 (and a 2 of each), plus LimitedTimeGiver.
--
-- A giver is collected by touching ColoredParts.TouchMe, which carries a
-- TouchInterest - so firetouchinterest collects it from anywhere on the map
-- without the character moving at all. Its Settings folder holds WeaponName,
-- RegenTime, StartColor and RegenColor: the pad wears StartColor while a block
-- is waiting and RegenColor while it is on cooldown, which is how readiness is
-- read here rather than by guessing at timers.
--
-- Base ownership is base.Owner, a StringValue holding a username, and each
-- player carries lucky_tag / super_tag / diamond_tag / rainbow_tag / galaxy_tag
-- NumberValues counting what they are holding. Both replicate to everyone.
--
-- Two remote paths worth knowing about:
--
--   ReplicatedStorage.Spawn{Lucky,Super,Diamond,Rainbow,Galaxy}Block
--     RemoteEvents the server listens on that *no client script in the game
--     ever fires*. Nothing in the dumped client touches them, so whatever
--     guard they carry is server side and untested from here.
--
--   ReplicatedStorage.UpdateCameraAngle
--     Named for a camera, used for nothing of the sort: ReplicatedFirst's
--     afk_connection fires it with your Minutes total when you come back from
--     an AFK server, to restore the count. The client is trusted to say what
--     that number is.
--
-- The AFK teleport itself is worth defusing: afk_connection watches
-- UserInputService and, after 1140 seconds without input, teleports you to
-- place 15626342566. Also note every base's Walls.SpawnWalls parts run a lava
-- script, so walking a route through someone's base kills you - which is most
-- of why collection here is done by touch rather than by driving the character.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local function resolveEvent(modern, legacy)
    local ok, ev = pcall(function() return RunService[modern] end)
    if ok and ev then return ev end
    return RunService[legacy]
end
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local Unloading = false
local function track(c) Connections[#Connections + 1] = c return c end

local BLOCK_TYPES = { "Lucky", "Super", "Diamond", "Rainbow", "Galaxy", "Void", "LimitedTime" }

local BLOCK_COLORS = {
    Lucky = Color3.fromRGB(255, 225, 60),
    Super = Color3.fromRGB(255, 130, 40),
    Diamond = Color3.fromRGB(120, 235, 255),
    Rainbow = Color3.fromRGB(255, 90, 200),
    Galaxy = Color3.fromRGB(150, 100, 255),
    Void = Color3.fromRGB(180, 180, 180),
    LimitedTime = Color3.fromRGB(90, 255, 140),
}

--// Config ------------------------------------------------------------------------
local Config = {
    AutoCollect = false,
    Want = { Lucky = true, Super = true, Diamond = true, Rainbow = true, Galaxy = true, Void = true, LimitedTime = true },
    OwnBase = true,
    CenterBlocks = true,
    OtherBases = false,
    TouchGap = { Min = 0.10, Max = 0.25 },
    SweepDelay = 1,
    ReadyCheck = true,
    SpawnLoop = false,
    SpawnRate = 50,
    SpawnKinds = { Lucky = true, Super = true, Diamond = true, Rainbow = true, Galaxy = true },
    Minutes = 1000,
    TpBase = "Spawn1",

    Wanted = "",
    AutoEquip = true,

    AntiAfk = true,
    BlockAfkTeleport = true,

    BlockEsp = false,
    EspReadyOnly = false,
    PlayerEsp = false,

    WalkSpeed = 16,
    JumpPower = 50,
    InfiniteJump = false,
    Noclip = false,
}

local Stats = {
    Bases = 0,
    Givers = 0,
    Ready = 0,
    Collected = 0,
    LastCollected = "-",
    Status = "idle",
    Touch = "checking",
    MyBase = "-",
    Held = "-",
    Fired = 0,
    Tools = 0,
    LastTool = "-",
    Watch = "-",
}

-- Drawn fresh for every pad rather than once when the slider moves, which is
-- what the old code did - it picked a single number on release and then used
-- that same gap forever, turning a range into a constant.
local function touchGap()
    local lo = math.min(Config.TouchGap.Min, Config.TouchGap.Max)
    local hi = math.max(Config.TouchGap.Min, Config.TouchGap.Max)
    if hi <= lo then return lo end
    return lo + math.random() * (hi - lo)
end

--// Executor capability -----------------------------------------------------------
-- firetouchinterest is what makes collection possible without moving. Without
-- it the only honest fallback is to put the character on the pad for a moment,
-- which is slower, visible, and walks you past the lava walls.
local fireTouch
do
    -- Executors disagree about where they put it: some as a plain global, some
    -- only inside getgenv(). Both are read through pcall because touching an
    -- absent getgenv is an error rather than a nil.
    local ok, found = pcall(function()
        if typeof(firetouchinterest) == "function" then return firetouchinterest end
        if typeof(getgenv) == "function" then
            local env = getgenv()
            if env and typeof(env.firetouchinterest) == "function" then
                return env.firetouchinterest
            end
        end
        return nil
    end)
    fireTouch = ok and found or nil
end
Stats.Touch = typeof(fireTouch) == "function" and "firetouchinterest" or "teleport fallback"

--// Base and giver discovery ------------------------------------------------------
local function isBase(model)
    return model:IsA("Model") and model:FindFirstChild("Givers") ~= nil
end

local function myBaseName()
    local value = LocalPlayer:FindFirstChild("Spawn")
    return value and value.Value or nil
end

local function collectBases()
    local out = {}
    local mine = myBaseName()
    for _, model in ipairs(Workspace:GetChildren()) do
        if isBase(model) then
            local isMine = (mine ~= nil and model.Name == mine)
            local isCenter = model.Name == "CenterBlocks"
            local wanted
            if isCenter then
                wanted = Config.CenterBlocks
            elseif isMine then
                wanted = Config.OwnBase
            else
                wanted = Config.OtherBases
            end
            if wanted then
                out[#out + 1] = { model = model, mine = isMine, center = isCenter }
            end
        end
    end
    -- CenterBlocks is a Folder rather than a Model, so the loop above misses it.
    local center = Workspace:FindFirstChild("CenterBlocks")
    if center and Config.CenterBlocks and center:FindFirstChild("Givers") then
        local already = false
        for _, entry in ipairs(out) do
            if entry.model == center then already = true end
        end
        if not already then
            out[#out + 1] = { model = center, mine = false, center = true }
        end
    end
    return out
end

local function giverType(giver)
    local settings = giver:FindFirstChild("Settings")
    local named = settings and settings:FindFirstChild("WeaponName")
    if named and named.Value ~= "" then
        return named.Value
    end
    -- LimitedTimeGiver carries no WeaponName, and a giver mid-regen can be
    -- missing its Settings folder entirely, so the name is the backstop.
    for _, kind in ipairs(BLOCK_TYPES) do
        if string.find(giver.Name, kind, 1, true) then return kind end
    end
    return "Unknown"
end

local function touchPart(giver)
    local coloured = giver:FindFirstChild("ColoredParts")
    if not coloured then return nil end
    return coloured:FindFirstChild("TouchMe")
end

-- The pad wears Settings.StartColor while a block is waiting on it and
-- RegenColor while it is cooling down. That is the game's own signal, so it
-- beats timing the regen ourselves and never drifts.
local function isReady(giver)
    if not Config.ReadyCheck then return true end
    local settings = giver:FindFirstChild("Settings")
    local start = settings and settings:FindFirstChild("StartColor")
    local regen = settings and settings:FindFirstChild("RegenColor")
    local coloured = giver:FindFirstChild("ColoredParts")
    local pad = coloured and (coloured:FindFirstChild("Center") or coloured:FindFirstChild("TouchMe"))
    if not (start and regen and pad) then
        -- Nothing to read: fall back to whether the block model is sitting there.
        return giver:FindFirstChild("LuckyBlock") ~= nil
    end
    if pad.BrickColor == regen.Value then return false end
    if pad.BrickColor == start.Value then return true end
    return giver:FindFirstChild("LuckyBlock") ~= nil
end

local function eachGiver(fn)
    local bases = collectBases()
    Stats.Bases = #bases
    local total, ready = 0, 0
    for _, entry in ipairs(bases) do
        local givers = entry.model:FindFirstChild("Givers")
        if givers then
            for _, giver in ipairs(givers:GetChildren()) do
                if giver:IsA("Model") and (string.sub(giver.Name, 1, 10) == "BlockGiver" or giver.Name == "LimitedTimeGiver") then
                    total = total + 1
                    local kind = giverType(giver)
                    local live = isReady(giver)
                    if live then ready = ready + 1 end
                    fn(giver, kind, live, entry)
                end
            end
        end
    end
    Stats.Givers = total
    Stats.Ready = ready
end

--// Collecting --------------------------------------------------------------------
local LastPad = { kind = nil, at = 0 }

local function rootPart()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function collect(giver, kind)
    local part = touchPart(giver)
    local root = rootPart()
    if not part or not root then return false end

    if typeof(fireTouch) == "function" then
        -- 0 then 1 is the begin/end pair the engine would deliver itself. The
        -- end matters: leaving it hanging keeps the server thinking we are
        -- still standing on the pad and it will not fire again.
        local ok = pcall(fireTouch, part, root, 0)
        if ok then pcall(fireTouch, part, root, 1) end
        if not ok then return false end
    else
        local back = root.CFrame
        root.CFrame = part.CFrame + Vector3.new(0, 3, 0)
        task.wait(0.12)
        if rootPart() == root then
            root.CFrame = back
        end
    end

    Stats.Collected = Stats.Collected + 1
    Stats.LastCollected = kind
    -- Remembered so a tool arriving in the next moment can be attributed to the
    -- pad that produced it. It is the only way to learn which tier an item
    -- comes from, since the roll itself is server side and silent.
    LastPad.kind = kind
    LastPad.at = os.clock()
    return true
end

task.spawn(function()
    while not Unloading do
        task.wait(Config.SweepDelay)
        if Config.AutoCollect and rootPart() then
            local queue = {}
            eachGiver(function(giver, kind, live)
                if live and Config.Want[kind] then
                    queue[#queue +1] = { giver = giver, kind = kind }
                end
            end)
            Stats.Status = ("%d ready of %d"):format(#queue, Stats.Givers)
            for _, entry in ipairs(queue) do
                if Unloading or not Config.AutoCollect then break end
                collect(entry.giver, entry.kind)
                task.wait(touchGap())
            end
        elseif not Config.AutoCollect then
            Stats.Status = "idle"
        end
    end
end)

--// Spawn remotes -----------------------------------------------------------------
-- Server-listened RemoteEvents with no caller anywhere in the game's own
-- client, which is exactly the shape of something never meant to be reachable.
-- Whatever check they carry lives on the server, so this is a try-it, not a
-- guarantee - which is why nothing here loops on them by default.
local SPAWN_REMOTES = {
    Lucky = "SpawnLuckyBlock",
    Super = "SpawnSuperBlock",
    Diamond = "SpawnDiamondBlock",
    Rainbow = "SpawnRainbowBlock",
    Galaxy = "SpawnGalaxyBlock",
}

local SPAWN_ORDER = { "Lucky", "Super", "Diamond", "Rainbow", "Galaxy" }

-- Looked up once and kept. At fifty calls a second a FindFirstChild per fire is
-- fifty pointless tree walks a second, and the remotes never move.
local spawnRemoteCache = {}

local function spawnRemote(kind)
    local cached = spawnRemoteCache[kind]
    if cached and cached.Parent then return cached end
    local name = SPAWN_REMOTES[kind]
    if not name then return nil end
    local remote = ReplicatedStorage:FindFirstChild(name)
    spawnRemoteCache[kind] = remote
    return remote
end

local function fireSpawn(kind)
    local name = SPAWN_REMOTES[kind]
    if not name then return false, "no remote for " .. tostring(kind) end
    local remote = spawnRemote(kind)
    if not remote then return false, name .. " missing" end
    local ok, err = pcall(function()
        remote:FireServer()
    end)
    if ok then Stats.Fired = Stats.Fired + 1 end
    return ok, ok and "fired" or tostring(err)
end

-- Rate driven off the frame delta rather than a task.wait per call, because
-- task.wait cannot go below a frame: a wait of 0.02 still costs a whole one, so
-- the old loop's ceiling was the refresh rate no matter what number went in.
-- Carrying the fractional remainder between frames keeps the rate honest at any
-- framerate, and firing several in one frame is what gets past sixty a second.
--
-- The per-frame cap is the important half. After a hitch the accumulator is
-- holding a second's worth of calls, and dumping four hundred remotes into one
-- frame is how a client freezes itself or trips a rate limit.
local SPAWN_BURST_CAP = 25
local spawnCarry, spawnCursor = 0, 0

track(PostSimulation:Connect(function(delta)
    if Unloading or not Config.SpawnLoop then
        spawnCarry = 0
        return
    end

    local kinds = {}
    for _, kind in ipairs(SPAWN_ORDER) do
        if Config.SpawnKinds[kind] then kinds[#kinds + 1] = kind end
    end
    if #kinds == 0 then
        spawnCarry = 0
        return
    end

    spawnCarry = spawnCarry + (delta or 0) * Config.SpawnRate
    local count = math.floor(spawnCarry)
    if count <= 0 then return end
    spawnCarry = spawnCarry - count
    if count > SPAWN_BURST_CAP then
        count = SPAWN_BURST_CAP
        spawnCarry = 0
    end

    -- Round robin rather than a block of one kind then a block of the next, so
    -- every selected type gets an even share of the rate even at low counts.
    for _ = 1, count do
        spawnCursor = spawnCursor % #kinds + 1
        fireSpawn(kinds[spawnCursor])
    end
end))

--// AFK --------------------------------------------------------------------------
-- Two layers, because the timer lives in a ReplicatedFirst upvalue we would
-- rather not go rummaging for. VirtualUser feeds the UserInputService events
-- afk_connection is listening to, which resets its clock the same way a real
-- click does; blocking the Teleport call is the backstop for when it does not.
local afkStart = os.clock()

task.spawn(function()
    local ok, virtual = pcall(function()
        return game:GetService("VirtualUser")
    end)
    while not Unloading do
        task.wait(60)
        if Config.AntiAfk and ok and virtual then
            pcall(function()
                virtual:CaptureController()
                virtual:ClickButton2(Vector2.new(0, 0))
            end)
            afkStart = os.clock()
        end
    end
end)

do
    local ok = pcall(function()
        local teleport = game:GetService("TeleportService")
        if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then
            error("no namecall hook on this executor")
        end
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if not Unloading and Config.BlockAfkTeleport and self == teleport then
                local method = getnamecallmethod()
                if method == "Teleport" or method == "TeleportToPlaceInstance" then
                    local placeId = (...)
                    -- Only the AFK place. A teleport the player asked for still
                    -- has to work.
                    if placeId == 15626342566 then
                        Stats.Status = "blocked an afk teleport"
                        return nil
                    end
                end
            end
            return oldNamecall(self, ...)
        end)
    end)
    if not ok then
        Stats.Touch = Stats.Touch .. " (no namecall hook)"
    end
end

--// Minutes ----------------------------------------------------------------------
local function sendMinutes(amount)
    local remote = ReplicatedStorage:FindFirstChild("UpdateCameraAngle")
    if not remote then return false, "UpdateCameraAngle missing" end
    local ok, err = pcall(function()
        remote:FireServer(amount)
    end)
    return ok, ok and ("sent " .. tostring(amount)) or tostring(err)
end

--// Visuals ----------------------------------------------------------------------
local blockHighlights = {}
local playerHighlights = {}

local function clearStore(store)
    for key, inst in pairs(store) do
        pcall(function() inst:Destroy() end)
        store[key] = nil
    end
end

local function refreshBlockEsp()
    if not Config.BlockEsp then
        clearStore(blockHighlights)
        return
    end
    local seen = {}
    eachGiver(function(giver, kind, live)
        local show = Config.Want[kind] and (live or not Config.EspReadyOnly)
        if not show then return end
        seen[giver] = true
        local highlight = blockHighlights[giver]
        if not highlight or not highlight.Parent then
            highlight = Instance.new("Highlight")
            highlight.FillTransparency = 0.65
            highlight.OutlineTransparency = 0
            highlight.Adornee = giver
            highlight.Parent = giver
            blockHighlights[giver] = highlight
        end
        local colour = BLOCK_COLORS[kind] or Color3.fromRGB(255, 255, 255)
        if not live then
            -- Dimmed rather than hidden, so a pad on cooldown still reads as a
            -- pad rather than vanishing off the map.
            colour = colour:Lerp(Color3.fromRGB(40, 40, 40), 0.65)
        end
        highlight.FillColor = colour
        highlight.OutlineColor = colour
    end)
    for giver, highlight in pairs(blockHighlights) do
        if not seen[giver] then
            pcall(function() highlight:Destroy() end)
            blockHighlights[giver] = nil
        end
    end
end

local function heldCounts(player)
    local parts = {}
    for _, kind in ipairs({ "lucky", "super", "diamond", "rainbow", "galaxy" }) do
        local value = player:FindFirstChild(kind .. "_tag")
        if value and value.Value and value.Value > 0 then
            parts[#parts + 1] = ("%s %d"):format(string.sub(kind, 1, 1):upper(), value.Value)
        end
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, " ")
end

local function refreshPlayerEsp()
    if not Config.PlayerEsp then
        clearStore(playerHighlights)
        for _, player in ipairs(Players:GetPlayers()) do
            local head = player.Character and player.Character:FindFirstChild("Head")
            local tag = head and head:FindFirstChild("LB_Tag")
            if tag then pcall(function() tag:Destroy() end) end
        end
        return
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local character = player.Character
            local highlight = playerHighlights[player]
            if not highlight or not highlight.Parent then
                highlight = Instance.new("Highlight")
                highlight.FillTransparency = 0.75
                highlight.FillColor = Color3.fromRGB(255, 90, 90)
                highlight.OutlineColor = Color3.fromRGB(255, 160, 160)
                highlight.Parent = character
                playerHighlights[player] = highlight
            end
            highlight.Adornee = character

            local head = character:FindFirstChild("Head")
            if head then
                local gui = head:FindFirstChild("LB_Tag")
                if not gui then
                    gui = Instance.new("BillboardGui")
                    gui.Name = "LB_Tag"
                    gui.Adornee = head
                    gui.Size = UDim2.fromOffset(220, 32)
                    gui.StudsOffset = Vector3.new(0, 2.6, 0)
                    gui.AlwaysOnTop = true
                    local text = Instance.new("TextLabel")
                    text.Name = "T"
                    text.BackgroundTransparency = 1
                    text.Size = UDim2.fromScale(1, 1)
                    text.Font = Enum.Font.GothamBold
                    text.TextSize = 13
                    text.TextStrokeTransparency = 0.4
                    text.TextColor3 = Color3.fromRGB(255, 255, 255)
                    text.Parent = gui
                    gui.Parent = head
                end
                local label = gui:FindFirstChild("T")
                if label then
                    local spawnValue = player:FindFirstChild("Spawn")
                    label.Text = ("%s  [%s]  %s"):format(
                        player.Name,
                        spawnValue and spawnValue.Value or "?",
                        heldCounts(player)
                    )
                end
            end
        end
    end
end

task.spawn(function()
    while not Unloading do
        task.wait(0.6)
        pcall(refreshBlockEsp)
        pcall(refreshPlayerEsp)
        Stats.MyBase = myBaseName() or "-"
        Stats.Held = heldCounts(LocalPlayer)
    end
end)

--// Movement ---------------------------------------------------------------------
local function humanoid()
    local character = LocalPlayer.Character
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

track(PostSimulation:Connect(function()
    if Unloading then return end
    local human = humanoid()
    if human then
        if Config.WalkSpeed ~= 16 and human.WalkSpeed ~= Config.WalkSpeed then
            human.WalkSpeed = Config.WalkSpeed
        end
        if Config.JumpPower ~= 50 then
            human.UseJumpPower = true
            if human.JumpPower ~= Config.JumpPower then
                human.JumpPower = Config.JumpPower
            end
        end
    end
end))

-- Every base's SpawnWalls run a lava script, so clipping through them is less a
-- movement toy than the only safe way across someone else's base.
--
-- Only the parts that were actually colliding get switched, and they are
-- remembered so turning it off puts back exactly those and nothing else. The
-- naive version - forcing CanCollide true on everything when off - switches on
-- accessory handles and hat meshes that were never meant to collide, and the
-- character starts snagging on scenery.
local noclipped = setmetatable({}, { __mode = "k" })

track(PostSimulation:Connect(function()
    if Unloading then return end
    local character = LocalPlayer.Character
    if not character then return end
    if Config.Noclip then
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                noclipped[part] = true
                part.CanCollide = false
            end
        end
    elseif next(noclipped) ~= nil then
        for part in pairs(noclipped) do
            if part.Parent then
                part.CanCollide = true
            end
            noclipped[part] = nil
        end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloading or not Config.InfiniteJump then return end
    local human = humanoid()
    if human then
        human:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end))

local function teleportTo(cframe)
    local root = rootPart()
    if root and cframe then
        root.CFrame = cframe
    end
end

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib3.lua'))()

local Window = Centrl:Window({
    Title = "lucky blocks",
    SubTitle = "block farm",
    Folder = "Hub",
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 200, 60),
})

--// Farm tab ---------------------------------------------------------------------
local FarmTab = Window:Tab({ Title = "farm", Icon = "package" })

local CollectSection = FarmTab:Section({ Title = "auto collect", Side = "left" })

CollectSection:Toggle({
    Title = "auto collect",
    Flag = "lb_auto",
    Default = false,
    Callback = function(state) Config.AutoCollect = state end,
})

-- Handles kept so narrowing the farm can move the switches as well as the
-- config, rather than leaving the panel claiming something that is no longer
-- true.
local wantToggles = {}
for _, kind in ipairs(BLOCK_TYPES) do
    wantToggles[kind] = CollectSection:Toggle({
        Title = string.lower(kind) .. " blocks",
        Flag = "lb_want_" .. string.lower(kind),
        Default = true,
        Callback = function(state) Config.Want[kind] = state end,
    })
end

local SourceSection = FarmTab:Section({ Title = "where from", Side = "right" })

SourceSection:Toggle({
    Title = "my base",
    Flag = "lb_own",
    Default = true,
    Callback = function(state) Config.OwnBase = state end,
})

SourceSection:Toggle({
    Title = "center blocks",
    Flag = "lb_center",
    Default = true,
    Callback = function(state) Config.CenterBlocks = state end,
})

SourceSection:Toggle({
    Title = "other people's bases",
    Flag = "lb_others",
    Default = false,
    Callback = function(state) Config.OtherBases = state end,
})

SourceSection:Toggle({
    Title = "only touch ready pads",
    Flag = "lb_ready",
    Default = true,
    Callback = function(state) Config.ReadyCheck = state end,
})

SourceSection:RangeSlider({
    Title = "gap between touches",
    Flag = "lb_touch_gap",
    Min = 0, Max = 1, Increment = 0.01,
    Default = { 0.1, 0.25 },
    Suffix = "s",
    Callback = function(low, high)
        Config.TouchGap = { Min = low, Max = high }
    end,
})

SourceSection:Slider({
    Title = "sweep every",
    Flag = "lb_sweep",
    Min = 0.25, Max = 10, Increment = 0.25, Default = 1,
    Suffix = "s",
    Callback = function(value) Config.SweepDelay = value end,
})

CollectSection:Button({
    Title = "collect everything once",
    Callback = function()
        task.spawn(function()
            local taken = 0
            local queue = {}
            eachGiver(function(giver, kind, live)
                if live and Config.Want[kind] then
                    queue[#queue + 1] = { giver = giver, kind = kind }
                end
            end)
            for _, entry in ipairs(queue) do
                if collect(entry.giver, entry.kind) then taken = taken + 1 end
                task.wait(touchGap())
            end
            Centrl:Notify({
                Title = "lucky blocks",
                Content = ("Touched %d of %d ready pads."):format(taken, #queue),
                Type = taken > 0 and "success" or "warning",
                Duration = 5,
            })
        end)
    end,
})

CollectSection:Paragraph({
    Title = "collected without moving",
    Text = "Every pad is a part with a TouchInterest on it, so firetouchinterest delivers the same begin-and-end pair the engine would and the server collects the block with the character standing exactly where it was. The end half matters as much as the begin: leave it hanging and the server keeps thinking you are still stood on the pad, and it will not fire again.\n\nOn an executor without firetouchinterest this falls back to putting the character on the pad for a tenth of a second and returning it - slower, visible to everyone, and it walks you past the lava walls, so it is a fallback and not a plan.",
})

CollectSection:Paragraph({
    Title = "how readiness is known",
    Text = "Each giver's Settings folder names a StartColor and a RegenColor, and the pad wears one or the other. Reading the colour is the game telling you directly whether a block is sitting there, which never drifts the way counting down RegenTime ourselves would - and RegenTime varies by block anyway, 60 seconds on Galaxy against 300 on Rainbow. Turning the check off touches every pad on every sweep, which collects nothing extra and makes a great deal more noise.",
})

local StatusSection = FarmTab:Section({ Title = "status", Side = "left" })

local baseLabel = StatusSection:Label({ Title = "base: --" })
local giverLabel = StatusSection:Label({ Title = "givers: --" })
local heldLabel = StatusSection:Label({ Title = "holding: --" })
local tagLabel = StatusSection:Label({ Title = "blocks out: --" })
local collectLabel = StatusSection:Label({ Title = "collected 0" })
local touchLabel = StatusSection:Label({ Title = "method: --" })
local firedLabel = StatusSection:Label({ Title = "spawn fired: 0" })
local statusLabel = StatusSection:Label({ Title = "status: --" })

--// Remotes tab ------------------------------------------------------------------
local RemoteTab = Window:Tab({ Title = "remotes", Icon = "radio" })

local SpawnSection = RemoteTab:Section({ Title = "spawn blocks", Side = "left" })

for _, kind in ipairs({ "Lucky", "Super", "Diamond", "Rainbow", "Galaxy" }) do
    SpawnSection:Button({
        Title = "fire spawn " .. string.lower(kind),
        Callback = function()
            local ok, message = fireSpawn(kind)
            Centrl:Notify({
                Title = "lucky blocks",
                Content = kind .. ": " .. message,
                Type = ok and "success" or "warning",
                Duration = 5,
            })
        end,
    })
end

SpawnSection:Paragraph({
    Title = "nothing in the game fires these",
    Text = "ReplicatedStorage holds SpawnLuckyBlock, SpawnSuperBlock, SpawnDiamondBlock, SpawnRainbowBlock and SpawnGalaxyBlock, and not one client script in the whole game touches any of them - the blocks you get normally come from walking onto a pad. A remote the server listens on that its own client never calls is either dead code or a developer path, and either way whatever guards it is server side and cannot be read from here.\n\nSo these are buttons rather than a loop. Press one and watch: if a block appears, it works and the toggle below is worth having on. If nothing happens, it is guarded and no amount of repeating will change that.",
})

SpawnSection:Toggle({
    Title = "keep firing them",
    Flag = "lb_spawn_loop",
    Default = false,
    Callback = function(state) Config.SpawnLoop = state end,
})

SpawnSection:Slider({
    Title = "fire rate",
    Flag = "lb_spawn_rate",
    Min = 1, Max = 200, Increment = 1, Default = 50,
    Suffix = "/s",
    Callback = function(value) Config.SpawnRate = value end,
})

SpawnSection:Dropdown({
    Title = "which to fire",
    Flag = "lb_spawn_kinds",
    Options = { "Lucky", "Super", "Diamond", "Rainbow", "Galaxy" },
    Multi = true,
    Default = { "Lucky", "Super", "Diamond", "Rainbow", "Galaxy" },
    Callback = function(value)
        local picked = {}
        for _, kind in ipairs(typeof(value) == "table" and value or { value }) do
            picked[kind] = true
        end
        Config.SpawnKinds = picked
    end,
})

SpawnSection:Paragraph({
    Title = "the rate is a real rate",
    Text = "Fifty a second means fifty, not fifty attempts. Driving this off task.wait cannot get there - a wait of 0.02 still costs a whole frame, so the old loop was capped at the refresh rate however small the number went. This one takes the frame delta, works out how many calls that slice of a second is owed and fires them all, carrying the fraction over so the rate holds at any framerate.\n\nA cap of twenty-five per frame sits on top. After a hitch the accumulator is holding a second's worth of calls, and dumping several hundred remotes into one frame is how a client freezes itself.\n\nPick only the block you actually want. Firing all five splits the rate five ways, so fifty a second across the lot is ten a second of the one that matters.",
})

local MinuteSection = RemoteTab:Section({ Title = "minutes", Side = "right" })

MinuteSection:Slider({
    Title = "minutes to claim",
    Flag = "lb_minutes",
    Min = 1, Max = 100000, Increment = 1, Default = 1000,
    Callback = function(value) Config.Minutes = value end,
})

MinuteSection:Button({
    Title = "send minutes",
    Callback = function()
        local ok, message = sendMinutes(Config.Minutes or 1000)
        Centrl:Notify({
            Title = "lucky blocks",
            Content = message,
            Type = ok and "success" or "warning",
            Duration = 5,
        })
    end,
})

MinuteSection:Paragraph({
    Title = "the remote is misnamed",
    Text = "UpdateCameraAngle has nothing to do with a camera. ReplicatedFirst's afk_connection fires it with your Minutes total the moment you arrive back from an AFK server, so the count carries over - the client is simply trusted to state what that number was.\n\nThat is the only place the game ever sends it, so calling it directly is an untested path with a plausible reason to work. Start with a small number and check the leaderboard before reaching for the top of the slider: if it adds rather than sets, a huge value is not something you can take back.",
})

--// Items ------------------------------------------------------------------------
-- You cannot pick what a block gives. The roll happens on the server against a
-- table the client never sees, and the gear lands straight in the Backpack -
-- there is not one Tool loose in the whole workspace, so there is no dropped
-- item on the floor to walk past and leave behind either. Nothing about which
-- item arrives is decided anywhere this script can reach.
--
-- What is decidable is which pad you pull from. Every tool is stamped with the
-- tier of the pad touched immediately before it appeared, which over a few
-- hundred pulls says plainly which tier your item actually comes from - and
-- that turns "I want this item" into "stop spending pulls on the four tiers
-- that have never once produced it", which is a real saving even though it is
-- not a guarantee.
--
-- The drop feature that used to live here is gone. Reparenting a tool from the
-- client is how Roblox's own Backspace drop works, but this game does not
-- honour it, so it half-worked at best.

-- A tool that lands more than this long after a pad was touched cannot be
-- credited to it. Generous, because the server takes its time.
local ATTRIBUTION_WINDOW = 3

local seenTools = {}      -- [name] = { total = n, tiers = { [tier] = n } }
local toolLog = {}        -- most recent arrivals, newest first
local wantedHits = 0

local function backpack()
    return LocalPlayer:FindFirstChildOfClass("Backpack")
end

local function heldTools()
    local out = {}
    local bag = backpack()
    if bag then
        for _, item in ipairs(bag:GetChildren()) do
            if item:IsA("Tool") then out[#out + 1] = item end
        end
    end
    local character = LocalPlayer.Character
    if character then
        for _, item in ipairs(character:GetChildren()) do
            if item:IsA("Tool") then out[#out + 1] = item end
        end
    end
    return out
end

-- Comma separated, because wanting one specific item is rarer than wanting any
-- of a handful.
local function wantedList()
    local out = {}
    for word in string.gmatch(string.lower(Config.Wanted or ""), "[^,]+") do
        word = string.gsub(word, "^%s+", "")
        word = string.gsub(word, "%s+$", "")
        if word ~= "" then out[#out + 1] = word end
    end
    return out
end

local function isWanted(name)
    local lowered = string.lower(name)
    for _, word in ipairs(wantedList()) do
        if string.find(lowered, word, 1, true) then return true end
    end
    return false
end

local function noteArrival(tool)
    local name = tool.Name
    local tier = "unknown"
    if LastPad.kind and os.clock() - LastPad.at <= ATTRIBUTION_WINDOW then
        tier = LastPad.kind
    end

    local entry = seenTools[name]
    if not entry then
        entry = { total = 0, tiers = {} }
        seenTools[name] = entry
    end
    entry.total = entry.total + 1
    entry.tiers[tier] = (entry.tiers[tier] or 0) + 1

    table.insert(toolLog, 1, ("%s  <- %s"):format(name, tier))
    for index = #toolLog, 41, -1 do
        toolLog[index] = nil
    end
    Stats.LastTool = ("%s (%s)"):format(name, tier)

    if isWanted(name) then
        wantedHits = wantedHits + 1
        Stats.Watch = ("%s x%d"):format(name, wantedHits)
        Centrl:Notify({
            Title = "lucky blocks",
            Content = ("Got %s from a %s block."):format(name, tier),
            Type = "success",
            Duration = 6,
        })
        if Config.AutoEquip then
            local character = LocalPlayer.Character
            local human = character and character:FindFirstChildOfClass("Humanoid")
            if human then pcall(function() human:EquipTool(tool) end) end
        end
    end
end

task.spawn(function()
    -- Rebound on every respawn, because the Backpack instance is replaced.
    local hooked = nil
    while not Unloading do
        local bag = backpack()
        if bag and bag ~= hooked then
            hooked = bag
            track(bag.ChildAdded:Connect(function(child)
                if Unloading then return end
                if child:IsA("Tool") then
                    task.defer(noteArrival, child)
                end
            end))
        end
        Stats.Tools = #heldTools()
        task.wait(1)
    end
end)

-- Which tiers have ever produced something on the wanted list, and how often.
local function tiersForWanted()
    local counts, total = {}, 0
    for name, entry in pairs(seenTools) do
        if isWanted(name) then
            for tier, n in pairs(entry.tiers) do
                if tier ~= "unknown" then
                    counts[tier] = (counts[tier] or 0) + n
                    total = total + n
                end
            end
        end
    end
    return counts, total
end

--// Items tab -------------------------------------------------------------------
local BagTab = Window:Tab({ Title = "items", Icon = "backpack" })

local WantSection = BagTab:Section({ Title = "items you want", Side = "left" })

WantSection:Textbox({
    Title = "wanted",
    Flag = "lb_wanted",
    Placeholder = "comma separated, e.g. periastron, falcon",
    ClearOnFocus = false,
    Callback = function(text) Config.Wanted = tostring(text or "") end,
})

WantSection:Toggle({
    Title = "equip it the moment it lands",
    Flag = "lb_autoequip",
    Default = true,
    Callback = function(state) Config.AutoEquip = state end,
})

WantSection:Paragraph({
    Title = "the roll cannot be picked",
    Text = "Which item a block gives is decided on the server against a table the client never sees, and the gear appears straight in your Backpack. There is not one Tool loose anywhere in the workspace either, so there is no item lying on the floor to walk past and leave behind. Nothing about which item arrives is decided anywhere this script can reach.\n\nWhat is decidable is which pad you pull from, and that is what the rest of this tab is for.",
})

WantSection:Paragraph({
    Title = "so narrow the pulls instead",
    Text = "Every tool that arrives is stamped with the tier of the pad touched just before it. Over a few hundred pulls that says plainly which tier your item actually comes from - and if four of the six tiers have never once produced it, switching them off means every pull afterwards is spent somewhere it can happen.\n\nThat is not a guarantee of the item. It is the difference between rolling the right table and rolling five wrong ones alongside it, which is the whole of what can honestly be done here.",
})

local NarrowSection = BagTab:Section({ Title = "narrow the farm", Side = "right" })

local narrowLabel = NarrowSection:Label({ Title = "no data yet" })

NarrowSection:Button({
    Title = "where do my items come from",
    Callback = function()
        local counts, total = tiersForWanted()
        if total == 0 then
            narrowLabel:Set("nothing on the wanted list has dropped yet")
            Centrl:Notify({
                Title = "lucky blocks",
                Content = "No wanted item has dropped yet - keep farming and try again.",
                Type = "warning",
                Duration = 5,
            })
            return
        end
        local rows = {}
        for tier, n in pairs(counts) do
            rows[#rows + 1] = { tier = tier, n = n }
        end
        table.sort(rows, function(a, b) return a.n > b.n end)
        local parts = {}
        for _, row in ipairs(rows) do
            parts[#parts + 1] = ("%s %d (%.0f%%)"):format(row.tier, row.n, row.n / total * 100)
        end
        narrowLabel:Set(table.concat(parts, "   "))
    end,
})

NarrowSection:Button({
    Title = "farm only those tiers",
    Callback = function()
        local counts, total = tiersForWanted()
        if total == 0 then
            Centrl:Notify({
                Title = "lucky blocks",
                Content = "Nothing to narrow to yet - no wanted item has dropped.",
                Type = "warning",
                Duration = 5,
            })
            return
        end
        local kept = {}
        for _, kind in ipairs(BLOCK_TYPES) do
            local on = (counts[kind] or 0) > 0
            Config.Want[kind] = on
            if wantToggles[kind] then pcall(function() wantToggles[kind]:Set(on) end) end
            if on then kept[#kept + 1] = kind end
        end
        Centrl:Notify({
            Title = "lucky blocks",
            Content = "Now farming only: " .. table.concat(kept, ", "),
            Type = "success",
            Duration = 6,
        })
    end,
})

NarrowSection:Button({
    Title = "turn every tier back on",
    Callback = function()
        for _, kind in ipairs(BLOCK_TYPES) do
            Config.Want[kind] = true
            if wantToggles[kind] then pcall(function() wantToggles[kind]:Set(true) end) end
        end
    end,
})

NarrowSection:Paragraph({
    Title = "give it a sample first",
    Text = "One drop is not evidence. Leave the farm running until the wanted item has landed a good few times before narrowing, or you will switch off a tier that simply had not come up yet. The percentages beside each tier are there so you can see how much you are actually going on.",
})

local LogSection = BagTab:Section({ Title = "what has dropped", Side = "left" })

local toolsLabel = LogSection:Label({ Title = "tools: 0" })
local lastToolLabel = LogSection:Label({ Title = "last: --" })
local watchLabel = LogSection:Label({ Title = "wanted: --" })
local logLabel = LogSection:Paragraph({ Title = "by item", Text = "nothing yet" })

LogSection:Button({
    Title = "count what you have seen",
    Callback = function()
        local rows = {}
        for name, entry in pairs(seenTools) do
            rows[#rows + 1] = { name = name, entry = entry }
        end
        table.sort(rows, function(a, b) return a.entry.total > b.entry.total end)
        local lines = {}
        for index = 1, math.min(#rows, 20) do
            local row = rows[index]
            local tiers = {}
            for tier, n in pairs(row.entry.tiers) do
                tiers[#tiers + 1] = ("%s %d"):format(tier, n)
            end
            table.sort(tiers)
            lines[#lines + 1] = ("%s  x%d   [%s]"):format(row.name, row.entry.total, table.concat(tiers, ", "))
        end
        -- Paragraph:Set takes a table, not a string. Handed a string it finds
        -- no Title and no Text on it and quietly does nothing at all.
        logLabel:Set({ Text = #lines > 0 and table.concat(lines, "\n") or "nothing yet" })
    end,
})

LogSection:Button({
    Title = "recent arrivals",
    Callback = function()
        local lines = {}
        for index = 1, math.min(#toolLog, 20) do
            lines[#lines + 1] = toolLog[index]
        end
        logLabel:Set({ Text = #lines > 0 and table.concat(lines, "\n") or "nothing yet" })
    end,
})

--// Player tab -------------------------------------------------------------------
local PlayerTab = Window:Tab({ Title = "player", Icon = "user" })

local MoveSection = PlayerTab:Section({ Title = "movement", Side = "left" })

MoveSection:Slider({
    Title = "walk speed",
    Flag = "lb_walkspeed",
    Min = 16, Max = 250, Increment = 1, Default = 16,
    Callback = function(value) Config.WalkSpeed = value end,
})

MoveSection:Slider({
    Title = "jump power",
    Flag = "lb_jump",
    Min = 50, Max = 350, Increment = 1, Default = 50,
    Callback = function(value) Config.JumpPower = value end,
})

MoveSection:Toggle({
    Title = "infinite jump",
    Flag = "lb_infjump",
    Default = false,
    Callback = function(state) Config.InfiniteJump = state end,
})

MoveSection:Toggle({
    Title = "noclip",
    Flag = "lb_noclip",
    Default = false,
    Callback = function(state) Config.Noclip = state end,
})

MoveSection:Paragraph({
    Title = "the walls are lava",
    Text = "Every base wraps itself in Walls.SpawnWalls parts running a lava script, and the map centre is fenced the same way. Noclip is here because crossing someone else's base on foot is a death rather than a trip - and it is also why collection is done by touch instead of by walking the character around a route.",
})

local TeleSection = PlayerTab:Section({ Title = "teleport", Side = "right" })

TeleSection:Button({
    Title = "to my base",
    Callback = function()
        local value = LocalPlayer:FindFirstChild("SpawnCFrame")
        if value then
            teleportTo(value.Value + Vector3.new(0, 4, 0))
        end
    end,
})

TeleSection:Button({
    Title = "to center blocks",
    Callback = function()
        local center = Workspace:FindFirstChild("CenterBlocks")
        local givers = center and center:FindFirstChild("Givers")
        local first = givers and givers:FindFirstChildWhichIsA("Model")
        local part = first and touchPart(first)
        if part then
            teleportTo(part.CFrame + Vector3.new(0, 6, 0))
        end
    end,
})

TeleSection:Dropdown({
    Title = "to a base",
    Flag = "lb_tp_base",
    Options = { "Spawn1", "Spawn2", "Spawn3", "Spawn4", "Spawn5", "Spawn6", "Spawn7", "Spawn8" },
    Default = "Spawn1",
    Callback = function(value) Config.TpBase = value end,
})

TeleSection:Button({
    Title = "go",
    Callback = function()
        local base = Workspace:FindFirstChild(Config.TpBase or "Spawn1")
        local spot = base and base:FindFirstChild("SpawnLocation")
        if spot then
            teleportTo(spot.CFrame + Vector3.new(0, 5, 0))
        end
    end,
})

--// Visual tab -------------------------------------------------------------------
local VisualTab = Window:Tab({ Title = "visual", Icon = "eye" })

local EspSection = VisualTab:Section({ Title = "esp", Side = "left" })

EspSection:Toggle({
    Title = "block esp",
    Flag = "lb_block_esp",
    Default = false,
    Callback = function(state)
        Config.BlockEsp = state
        if not state then clearStore(blockHighlights) end
    end,
})

EspSection:Toggle({
    Title = "hide pads on cooldown",
    Flag = "lb_esp_ready",
    Default = false,
    Callback = function(state) Config.EspReadyOnly = state end,
})

EspSection:Toggle({
    Title = "player esp",
    Flag = "lb_player_esp",
    Default = false,
    Callback = function(state)
        Config.PlayerEsp = state
        if not state then clearStore(playerHighlights) end
    end,
})

EspSection:Paragraph({
    Title = "what the colours mean",
    Text = "Each pad is tinted by its block type and dimmed while it is regenerating, so a glance across the map says both what is out there and what is worth walking to. Player tags carry the base they own and the blocks they are currently holding - lucky_tag through galaxy_tag are plain NumberValues on every player and replicate to everyone, so that reading is the real one rather than a guess from what they have equipped.",
})

local AfkSection = VisualTab:Section({ Title = "afk", Side = "right" })

AfkSection:Toggle({
    Title = "anti afk",
    Flag = "lb_antiafk",
    Default = true,
    Callback = function(state) Config.AntiAfk = state end,
})

AfkSection:Toggle({
    Title = "block the afk teleport",
    Flag = "lb_block_tp",
    Default = true,
    Callback = function(state) Config.BlockAfkTeleport = state end,
})

AfkSection:Paragraph({
    Title = "nineteen minutes",
    Text = "afk_connection watches UserInputService and, once 1140 seconds pass without a single input, teleports you to place 15626342566 whether you were farming or not. Anti afk feeds VirtualUser input into the same events it is listening to, which resets its clock exactly as a real click would.\n\nBlocking the teleport is the backstop for when that is not enough, and it is deliberately narrow: only a Teleport aimed at that one place id is dropped, so anything you ask for yourself still goes through.",
})

AfkSection:Button({
    Title = "unload",
    Callback = function()
        Unloading = true
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        clearStore(blockHighlights)
        clearStore(playerHighlights)
        for _, player in ipairs(Players:GetPlayers()) do
            local head = player.Character and player.Character:FindFirstChild("Head")
            local tag = head and head:FindFirstChild("LB_Tag")
            if tag then pcall(function() tag:Destroy() end) end
        end
        Centrl:Unload()
    end,
})

Window:Load()

--// Status pump ------------------------------------------------------------------
task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            baseLabel:Set(("base: %s   (%d bases in range)"):format(Stats.MyBase, Stats.Bases))
            giverLabel:Set(("givers: %d   ready %d"):format(Stats.Givers, Stats.Ready))
            heldLabel:Set("holding: " .. tostring(Stats.Held))
            -- Every type spelled out rather than only the non-zero ones, so a
            -- counter sitting at its cap is visible instead of inferred.
            local tags = {}
            for _, kind in ipairs({ "lucky", "super", "diamond", "rainbow", "galaxy" }) do
                local value = LocalPlayer:FindFirstChild(kind .. "_tag")
                tags[#tags + 1] = ("%s %s"):format(
                    string.sub(kind, 1, 3), value and tostring(math.floor(value.Value)) or "?")
            end
            tagLabel:Set("blocks out: " .. table.concat(tags, "  "))
            toolsLabel:Set(("tools: %d"):format(Stats.Tools))
            lastToolLabel:Set("last: " .. tostring(Stats.LastTool))
            watchLabel:Set("wanted: " .. (Config.Wanted ~= "" and (Config.Wanted .. "  -> " .. Stats.Watch) or "nothing set"))
            collectLabel:Set(("collected %d   last: %s"):format(Stats.Collected, tostring(Stats.LastCollected)))
            touchLabel:Set("method: " .. Stats.Touch)
            firedLabel:Set(("spawn fired: %d%s"):format(
                Stats.Fired, Config.SpawnLoop and ("  (" .. math.floor(Config.SpawnRate) .. "/s)") or ""))
            statusLabel:Set("status: " .. Stats.Status)
        end)
    end
end)

Centrl:Notify({
    Title = "lucky blocks",
    Content = "Loaded (" .. Stats.Touch .. "). RightShift toggles the menu.",
    Type = "success",
    Duration = 6,
})

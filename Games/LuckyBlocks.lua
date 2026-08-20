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
    Minutes = 1000,
    TpBase = "Spawn1",

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

local function fireSpawn(kind)
    local name = SPAWN_REMOTES[kind]
    if not name then return false, "no remote for " .. tostring(kind) end
    local remote = ReplicatedStorage:FindFirstChild(name)
    if not remote then return false, name .. " missing" end
    local ok, err = pcall(function()
        remote:FireServer()
    end)
    return ok, ok and "fired" or tostring(err)
end

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
local Centrl = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui/main/Lib2.lua"))()

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

for _, kind in ipairs(BLOCK_TYPES) do
    CollectSection:Toggle({
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
local collectLabel = StatusSection:Label({ Title = "collected 0" })
local touchLabel = StatusSection:Label({ Title = "method: --" })
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
    Callback = function(state)
        Config.SpawnLoop = state
        if not state then return end
        task.spawn(function()
            while Config.SpawnLoop and not Unloading do
                for _, kind in ipairs({ "Lucky", "Super", "Diamond", "Rainbow", "Galaxy" }) do
                    if not Config.SpawnLoop or Unloading then break end
                    fireSpawn(kind)
                    task.wait(0.2)
                end
                task.wait(1)
            end
        end)
    end,
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
            collectLabel:Set(("collected %d   last: %s"):format(Stats.Collected, tostring(Stats.LastCollected)))
            touchLabel:Set("method: " .. Stats.Touch)
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

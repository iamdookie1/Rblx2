--// Wall Hop for Brainrots! -- auto grab, auto place / sell, cash collect,
--// auto upgrades and rebirth, movement, item esp, spawn alerts and free rewards.
--
-- Built against a script dump of the live game (place 138154148141431, game
-- 10004134791, version 585). What the game's own client scripts show:
--  * Brainrots spawn as models under Workspace.ItemSpawners.<Rarity> (one part
--    per rarity, Common through Mythical) carrying IsSpawnedItem, OriginalName,
--    Rarity, Mutation (Normal / Golden / Diamond / Lava / Galaxy), Level and
--    ExpiresAt (server time). Each has a "Pick Up" ProximityPrompt on its
--    PrimaryPart with no hold and an 8 stud range. Dropped ones sit in
--    Workspace.DroppedItems the same way. Divine and Insane spawns are announced
--    through Events.DivineSpawned / Events.InsaneSpawned.
--  * Picked up brainrots are tools in your backpack with the same attributes.
--    Your base is Workspace.Plot_<name>: Floor1-3, each with Slots.Slot1-10.
--    A slot's Spawn part has a prompt reading "Place Item" when empty and
--    "Pick Up / Swap" when full, and its CollectTouch part pays out on touch.
--  * Events.TeleportToBase:FireServer() sends you home (the game only shows the
--    button inside the CollectionZone). Events.RequestSell:FireServer("Inventory"
--    or "Equipped") sells at the SellNPC.
--  * Upgrades are argument-free remotes: PurchaseSpeed(1 | 5 | 10) buys Jump
--    Power at 1.25^(JP-1)*50 each, PurchaseCarry(), RequestBaseUpgrade() (price
--    on Plot.BaseUpgrade.GUIPart), RequestSlotUpgrade(floorName, slotName) and
--    RequestRebirth() once Jump Power reaches 2^rebirths*40.
--  * Jump power is applied by the client itself (CustomSpeedController sets
--    Humanoid.JumpPower from the Jump Power stat, and forces 50 inside the
--    "no janp" part). AntiFlingController caps your speed off walls at 55 on
--    every frame. The VIP door only stops colliding on the client.
--  * Free rewards: Events.ClaimDailyReward (when RequestDailyRewardData says
--    CanClaim), GiftPlaytimeFolder.ClaimGift:InvokeServer(n) for the nine
--    playtime gifts, Events.SpinRequest with AdData.AdSpinTickets, and the
--    group reward stand's prompt.
--
-- The map streams, so spawners and your base are only on the client while
-- you are near them. Their positions are saved as soon as they are seen (the
-- spawners to a file, per place) and the farm travels to them to load them in.
--
-- The server scripts were not in the dump, so which remotes it checks for
-- distance is not known: the farm walks (or teleports) to the prompt, base and
-- sell NPC the way a player would rather than relying on it not checking.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local REPO_RAW_BASE = 'https://raw.githubusercontent.com/iamdookie1/Rblx2/main/'

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__WallHopBrainrotsStop) == "function" then pcall(Genv.__WallHopBrainrotsStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

--// game references ---------------------------------------------------------

local Events = ReplicatedStorage:WaitForChild("Events", 15)
local GiftFolder = ReplicatedStorage:FindFirstChild("GiftPlaytimeFolder")

local function remote(name)
    return Events and Events:FindFirstChild(name) or nil
end

local function safeRequire(...)
    local node = ReplicatedStorage
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
    end
    if not node or not node:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, node)
    return ok and result or nil
end

local ItemConfig = safeRequire("Modules", "ItemConfigurations")
local RarityConfig = safeRequire("Modules", "RarityConfigurations") or {}
local GiftData = GiftFolder and (function()
    local module = GiftFolder:FindFirstChild("SharedGiftData")
    if not module then return nil end
    local ok, result = pcall(require, module)
    return ok and result or nil
end)() or {}

local RARITIES = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical",
    "Secret", "Celestial", "Divine", "Insane", "InsaneInsane", "Exclusive",
}
local RarityRank = {}
for index, name in ipairs(RARITIES) do RarityRank[name] = index end

-- The game gives mutations no ranking of its own on the client, so this order
-- (rarest looking last) is only the tiebreak between two otherwise equal items.
local MUTATIONS = { "Normal", "Golden", "Diamond", "Lava", "Galaxy" }
local MutationRank = {}
for index, name in ipairs(MUTATIONS) do MutationRank[name] = index end

local FALLBACK_COLORS = {
    Common = Color3.fromRGB(200, 200, 200),
    Uncommon = Color3.fromRGB(85, 255, 142),
    Rare = Color3.fromRGB(0, 200, 255),
    Epic = Color3.fromRGB(255, 85, 255),
    Legendary = Color3.fromRGB(255, 200, 0),
    Mythical = Color3.fromRGB(255, 60, 60),
}

local function rarityColor(rarity)
    local info = RarityConfig[rarity]
    local gradient = info and info.GradientColor
    if typeof(gradient) == "ColorSequence" then
        local points = gradient.Keypoints
        return points[#points].Value
    end
    return FALLBACK_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
end

local function baseIncome(name)
    local items = ItemConfig and ItemConfig.Items
    local entry = items and items[name]
    return entry and tonumber(entry.Income) or 0
end

local function toSet(list)
    local set = {}
    for _, value in ipairs(list or {}) do set[value] = true end
    return set
end

--// settings ----------------------------------------------------------------
-- Every value here is driven by a flagged element in the menu below, so all of
-- it is saved and loaded with the menu's configs.

local Farm = {
    Enabled = false,
    Rarities = toSet({ "Legendary", "Mythical", "Secret", "Celestial", "Divine", "Insane", "InsaneInsane", "Exclusive" }),
    Mutations = toSet(MUTATIONS),
    Priority = "Rarity",       -- Rarity / Income / Nearest
    RushSpecials = true,       -- Divine and above jump the queue whatever the filters say
    PerTrip = 1,               -- items to carry before heading home
    MinTimeLeft = 3,           -- seconds; skip items about to despawn
    Ignore = {},               -- lowercased names never grabbed
    Only = {},                 -- lowercased names; when not empty, nothing else is grabbed
    Deposit = "Place",         -- Place / Sell / Place then sell
    Swap = false,              -- swap a worse placed item out when the base is full
    StopWhenFull = true,       -- turn the farm off when nothing more can be placed
    CollectOnReturn = true,
    ActionDelay = 0.15,
    IdleAtBase = true,         -- wait at the base when there is nothing to grab
    Scout = true,              -- visit saved spawners when nothing wanted is loaded in
    ScoutWait = 1,             -- seconds to let a spawner's brainrots load in
    PickupWait = 3,            -- seconds a pickup gets to show up in your backpack
}

local Travel = {
    Mode = "Teleport",         -- Teleport / Tween
    Speed = 250,               -- studs per second when tweening
    Return = "Teleport",       -- Teleport / Remote
    Height = 3,                -- studs above a target to arrive at
}

local Cash = {
    Enabled = false,
    Interval = 5,
    WalkFallback = true,       -- step on each pad when the executor has no firetouchinterest
}

local Up = {
    Jump = false, JumpAmount = 1,
    Carry = false,
    Base = false,
    Slots = false,
    Rebirth = false,
    Reserve = 0,               -- money never spent by the auto buyers
    Interval = 1,
}

local Move = {
    JumpOn = false, Jump = 150, IgnoreNoJump = true,
    SpeedOn = false, Speed = 32,
    InfiniteJump = false,
    Uncap = false,
    Noclip = false,
    Fly = false, FlySpeed = 80,
    Vip = false,
}

local Esp = {
    Enabled = false,
    Rarities = toSet(RARITIES),
    Name = true, Rarity = true, Mutation = true, Timer = true, Distance = true, Income = false,
    Highlight = false,
    TextSize = 14,
    MaxDistance = 5000,
}

local Alerts = {
    Specials = true,
    Rarities = toSet({ "Mythical", "Secret", "Celestial", "Divine", "Insane", "InsaneInsane", "Exclusive" }),
    Sound = true,
}

local Misc = {
    Daily = false,
    Playtime = false,
    Spin = false,
    AntiAfk = true,
}

local Stats = { Grabbed = 0, Placed = 0, Sold = 0, Trips = 0, State = "idle" }

--// helpers -----------------------------------------------------------------

local Library -- the Ui3 menu library, loaded last

local NOTIFY_ICONS = { info = "bell", success = "check", warning = "triangle-alert", error = "circle-x" }

local function notify(title, content, kind)
    if not Library then return end
    pcall(function()
        Library:Notify({ Title = title, Description = content, Time = 6, Icon = NOTIFY_ICONS[kind or "info"] })
    end)
end

local function myCharacter()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function leaderstat(name)
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    local value = stats and stats:FindFirstChild(name)
    return value and tonumber(value.Value) or 0
end

local function serverNow()
    local ok, now = pcall(function() return Workspace:GetServerTimeNow() end)
    return ok and now or os.time()
end

local function formatNumber(n)
    n = math.floor(tonumber(n) or 0)
    if n < 1000 then return tostring(n) end
    local suffixes = { "k", "M", "B", "T", "qd", "Qn", "sx", "Sp", "O", "N", "de" }
    local tier = math.floor(math.log(n, 1000))
    local text = string.format("%.1f", n / 1000 ^ tier):gsub("%.0$", "")
    return text .. (suffixes[tier] or "??")
end

-- Presses a prompt: the executor's fireproximityprompt, or failing that the
-- prompt's own input with the hold and line of sight taken out.
local function firePrompt(prompt)
    if not prompt or not prompt.Parent then return false end
    if typeof(fireproximityprompt) == "function" and pcall(fireproximityprompt, prompt, 1, true) then
        return true
    end
    return (pcall(function()
        local duration, sight = prompt.HoldDuration, prompt.RequiresLineOfSight
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt:InputHoldBegin()
        prompt:InputHoldEnd()
        prompt.HoldDuration = duration
        prompt.RequiresLineOfSight = sight
    end))
end

local function touch(root, part)
    if typeof(firetouchinterest) ~= "function" then return false end
    pcall(firetouchinterest, root, part, 0)
    pcall(firetouchinterest, root, part, 1)
    return true
end

local function promptPosition(prompt)
    local parent = prompt and prompt.Parent
    if not parent then return nil end
    if parent:IsA("Attachment") then return parent.WorldPosition end
    if parent:IsA("BasePart") then return parent.Position end
    if parent:IsA("Model") then return parent:GetPivot().Position end
    return nil
end

--// items -------------------------------------------------------------------

local function itemPrompt(model)
    local primary = model:FindFirstChild("PrimaryPart")
    local prompt = primary and primary:FindFirstChildOfClass("ProximityPrompt")
    return prompt or model:FindFirstChildWhichIsA("ProximityPrompt", true)
end

local function readItem(model)
    if not model:IsA("Model") or model:GetAttribute("IsSpawnedItem") ~= true then return nil end
    local prompt = itemPrompt(model)
    local pos = promptPosition(prompt) or model:GetPivot().Position
    local name = model:GetAttribute("OriginalName") or model.Name
    return {
        Model = model,
        Prompt = prompt,
        Position = pos,
        Name = name,
        Rarity = model:GetAttribute("Rarity") or "?",
        Mutation = model:GetAttribute("Mutation") or "Normal",
        Level = model:GetAttribute("Level") or 1,
        ExpiresAt = model:GetAttribute("ExpiresAt"),
        Income = baseIncome(name),
    }
end

-- Everything spawned right now: the rarity spawners, dropped items, and
-- anything marked IsSpawnedItem straight under Workspace (special spawns do
-- not get a spawner part of their own in the dump, so this covers wherever the
-- server chooses to put them).
local function allItems()
    local list = {}
    local spawners = Workspace:FindFirstChild("ItemSpawners")
    if spawners then
        for _, spawner in ipairs(spawners:GetChildren()) do
            for _, child in ipairs(spawner:GetChildren()) do
                local item = readItem(child)
                if item then list[#list + 1] = item end
            end
        end
    end
    local dropped = Workspace:FindFirstChild("DroppedItems")
    if dropped then
        for _, child in ipairs(dropped:GetChildren()) do
            local item = readItem(child)
            if item then list[#list + 1] = item end
        end
    end
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") and child:GetAttribute("IsSpawnedItem") == true then
            local item = readItem(child)
            if item then list[#list + 1] = item end
        end
    end
    return list
end

local function isSpecial(rarity)
    return (RarityRank[rarity] or 0) >= RarityRank.Divine
end

local function itemBetter(a, b, origin)
    if Farm.Priority == "Nearest" and origin then
        return (a.Position - origin).Magnitude < (b.Position - origin).Magnitude
    end
    local ra, rb = RarityRank[a.Rarity] or 0, RarityRank[b.Rarity] or 0
    local ma, mb = MutationRank[a.Mutation] or 0, MutationRank[b.Mutation] or 0
    if Farm.Priority == "Income" then
        if a.Income ~= b.Income then return a.Income > b.Income end
        if ra ~= rb then return ra > rb end
        return ma > mb
    end
    if ra ~= rb then return ra > rb end
    if ma ~= mb then return ma > mb end
    return a.Income > b.Income
end

local FailedAt = setmetatable({}, { __mode = "k" })

local function wanted(item, now)
    if not item.Prompt or not item.Prompt.Enabled then return false end
    local failed = FailedAt[item.Model]
    if failed and os.clock() - failed.At < 20 and failed.Count >= 3 then return false end
    if item.ExpiresAt and item.ExpiresAt - now < Farm.MinTimeLeft then return false end
    local lname = tostring(item.Name):lower()
    if Farm.Ignore[lname] then return false end
    if Farm.RushSpecials and isSpecial(item.Rarity) then return true end
    if next(Farm.Only) and not Farm.Only[lname] then return false end
    return Farm.Rarities[item.Rarity] == true and Farm.Mutations[item.Mutation] == true
end

local function pickTarget(origin)
    local now = serverNow()
    local best, bestSpecial
    for _, item in ipairs(allItems()) do
        if wanted(item, now) then
            if Farm.RushSpecials and isSpecial(item.Rarity) then
                if not bestSpecial or itemBetter(item, bestSpecial, origin) then bestSpecial = item end
            elseif not best or itemBetter(item, best, origin) then
                best = item
            end
        end
    end
    return bestSpecial or best
end

local function carried()
    local list = {}
    for _, container in ipairs({ LocalPlayer:FindFirstChildOfClass("Backpack"), LocalPlayer.Character }) do
        for _, child in ipairs(container and container:GetChildren() or {}) do
            if child:IsA("Tool") and child:GetAttribute("OriginalName") then list[#list + 1] = child end
        end
    end
    return list
end

local function toolInfo(tool)
    local name = tool:GetAttribute("OriginalName") or tool.Name
    return {
        Name = name,
        Rarity = tool:GetAttribute("Rarity") or "?",
        Mutation = tool:GetAttribute("Mutation") or "Normal",
        Income = baseIncome(name),
        Position = Vector3.zero,
    }
end

--// base --------------------------------------------------------------------

local function myPlot()
    return Workspace:FindFirstChild("Plot_" .. LocalPlayer.Name)
end

local function slots()
    local list = {}
    local plot = myPlot()
    if not plot then return list end
    for _, floor in ipairs(plot:GetChildren()) do
        local folder = floor:IsA("Model") and floor:FindFirstChild("Slots")
        if folder then
            for _, slot in ipairs(folder:GetChildren()) do
                local spawn = slot:FindFirstChild("Spawn")
                local prompt = spawn and spawn:FindFirstChildOfClass("ProximityPrompt")
                if prompt then
                    local visual = spawn:FindFirstChild("VisualItem")
                    list[#list + 1] = {
                        Floor = floor.Name,
                        Name = slot.Name,
                        Spawn = spawn,
                        Prompt = prompt,
                        Collect = slot:FindFirstChild("CollectTouch"),
                        Item = visual and {
                            Name = visual:GetAttribute("OriginalName") or visual.Name,
                            Rarity = visual:GetAttribute("Rarity") or "?",
                            Mutation = visual:GetAttribute("Mutation") or "Normal",
                            Income = baseIncome(visual:GetAttribute("OriginalName") or visual.Name),
                            Position = Vector3.zero,
                        } or nil,
                        Empty = prompt.ActionText == "Place Item" or visual == nil,
                    }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.Floor ~= b.Floor then return a.Floor < b.Floor end
        return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
    end)
    return list
end

--// saved positions -------------------------------------------------------
-- The map streams: a few hundred studs away the spawners, their brainrots and
-- even your own base are not on the client at all, so they can't be found by
-- looking. Every spot the farm needs is written down the moment it is seen.
-- Spawners and the fixed spots (sell npc, shops) never move, so they are also
-- saved to a file and known on the next join before they ever load in. Your
-- plot changes from server to server, so it is only kept for this session.

local HttpService = game:GetService("HttpService")
local SAVE_FOLDER = "WallHopBrainrots"
local SAVE_FILE = SAVE_FOLDER .. "/positions_" .. tostring(game.PlaceId) .. ".json"

local Saved = { Spawners = {}, Points = {} } -- name -> Vector3, written to SAVE_FILE
local Session = { Home = nil, Slots = {} }   -- this server only
local SaveDirty = false

local POINTS = {
    -- point name, model under Workspace, child holding the position
    { "sell npc", "SellNPC", "ProxPart" },
    { "carry shop", "Carry", "Touch" },
    { "jump power shop", "JumpPower", "Touch" },
    { "collection zone", "CollectionZone" },
}

local function canFile()
    return typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
end

local function encodePositions(map)
    local out = {}
    for key, pos in pairs(map) do out[key] = { pos.X, pos.Y, pos.Z } end
    return out
end

local function decodePositions(map)
    local out = {}
    for key, value in pairs(type(map) == "table" and map or {}) do
        if type(value) == "table" and #value == 3 then out[key] = Vector3.new(value[1], value[2], value[3]) end
    end
    return out
end

local function loadSaved()
    if not canFile() then return end
    local ok, data = pcall(function()
        if not isfile(SAVE_FILE) then return nil end
        return HttpService:JSONDecode(readfile(SAVE_FILE))
    end)
    if ok and type(data) == "table" then
        Saved.Spawners = decodePositions(data.Spawners)
        Saved.Points = decodePositions(data.Points)
    end
end

local function writeSaved()
    if not canFile() then return end
    pcall(function()
        if typeof(isfolder) == "function" and typeof(makefolder) == "function" and not isfolder(SAVE_FOLDER) then
            makefolder(SAVE_FOLDER)
        end
        writefile(SAVE_FILE, HttpService:JSONEncode({
            Spawners = encodePositions(Saved.Spawners),
            Points = encodePositions(Saved.Points),
        }))
    end)
end

local function remember(map, key, pos, persist)
    local old = map[key]
    if old and (old - pos).Magnitude < 1 then return end
    map[key] = pos
    if persist then SaveDirty = true end
end

local function positionOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Model") then
        local ok, pivot = pcall(function() return inst:GetPivot() end)
        if ok and inst:FindFirstChildWhichIsA("BasePart", true) then return pivot.Position end
    end
    return nil
end

local function liveHome()
    local plot = myPlot()
    return plot and positionOf(plot:FindFirstChild("Spawn")) or nil
end

-- Writes down everything currently loaded in.
local function recordPositions()
    local spawners = Workspace:FindFirstChild("ItemSpawners")
    for _, part in ipairs(spawners and spawners:GetChildren() or {}) do
        local pos = RarityRank[part.Name] and positionOf(part)
        if pos then remember(Saved.Spawners, part.Name, pos, true) end
    end
    for _, point in ipairs(POINTS) do
        local inst = Workspace:FindFirstChild(point[2])
        if inst and point[3] then inst = inst:FindFirstChild(point[3]) or inst end
        local pos = positionOf(inst)
        if pos then remember(Saved.Points, point[1], pos, true) end
    end
    local home = liveHome()
    if home then Session.Home = home end
    for _, slot in ipairs(slots()) do
        Session.Slots[slot.Floor .. "/" .. slot.Name] = slot.Spawn.Position
    end
end

local function homePosition()
    return liveHome() or Session.Home
end

local function sellPosition()
    local npc = Workspace:FindFirstChild("SellNPC")
    return positionOf(npc and npc:FindFirstChild("ProxPart")) or Saved.Points["sell npc"]
end

loadSaved()
pcall(recordPositions)

task.spawn(function()
    local nextWrite = 0
    while not Unloaded do
        task.wait(1)
        pcall(recordPositions)
        if SaveDirty and os.clock() >= nextWrite then
            SaveDirty = false
            nextWrite = os.clock() + 5
            writeSaved()
        end
    end
end)

-- Asks the server to load the map around a point before you get there, when
-- the game streams. It waits at most a couple of seconds.
local function streamAround(pos)
    if not pos then return end
    pcall(function()
        if Workspace.StreamingEnabled then LocalPlayer:RequestStreamAroundAsync(pos, 2) end
    end)
end

local function waitFor(check, timeout)
    local start = os.clock()
    while os.clock() - start < timeout and not Unloaded do
        local ok, done = pcall(check)
        if ok and done then return true end
        task.wait(0.1)
    end
    return false
end

--// movement ----------------------------------------------------------------

local Travelling = false

-- Moves you to a point, instantly or at Travel.Speed. keepGoing is checked
-- every frame of a tween so a farm turned off mid-flight stops where it is.
local function travelTo(pos, keepGoing)
    local _, root = myCharacter()
    if not root or not pos then return false end
    local goal = pos + Vector3.new(0, Travel.Height, 0)
    if (goal - root.Position).Magnitude > 150 then streamAround(goal) end
    _, root = myCharacter()
    if not root then return false end
    if Travel.Mode == "Teleport" then
        root.CFrame = CFrame.new(goal) * (root.CFrame - root.CFrame.Position)
        root.AssemblyLinearVelocity = Vector3.zero
        return true
    end
    Travelling = true
    local reached = false
    while not Unloaded do
        local dt = RunService.Heartbeat:Wait()
        local _, r = myCharacter()
        if not r or (keepGoing and not keepGoing()) then break end
        local delta = goal - r.Position
        local distance = delta.Magnitude
        if distance < 1.5 then
            reached = true
            break
        end
        local step = math.min(distance, Travel.Speed * dt)
        r.CFrame = CFrame.new(r.Position + delta.Unit * step) * (r.CFrame - r.CFrame.Position)
        r.AssemblyLinearVelocity = Vector3.zero
    end
    Travelling = false
    return reached
end

--// farm --------------------------------------------------------------------

local Log -- the menu's log, set once the menu exists
local LOG_COLORS = {
    Info = Color3.fromRGB(150, 200, 255),
    Success = Color3.fromRGB(126, 217, 87),
    Warn = Color3.fromRGB(255, 200, 90),
    Error = Color3.fromRGB(255, 96, 106),
}
local PendingLog = {}
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

local Busy = false -- a farm step or a manual action is moving the character

local function farmOn() return Farm.Enabled and not Unloaded end

-- Pickups made on this trip. The tool can take a while to reach your
-- backpack, so a brainrot counts as soon as it leaves the ground; going by the
-- backpack alone let the farm pick up more than the trip allows.
local Trip = { Count = 0 }

local function onGround(item)
    local model, prompt = item.Model, item.Prompt
    return model.Parent ~= nil and model:GetAttribute("IsSpawnedItem") == true
        and prompt ~= nil and prompt.Parent ~= nil and prompt.Enabled
end

local function grab(item)
    local before = #carried()
    Stats.State = "grabbing " .. item.Name
    if not travelTo(item.Position, farmOn) then return false end
    task.wait(Farm.ActionDelay)
    firePrompt(item.Prompt)
    local start = os.clock()
    while os.clock() - start < Farm.PickupWait do
        local arrived = #carried() > before
        if arrived or not onGround(item) then
            if not arrived then
                -- gone from the ground: give the tool a moment to arrive
                waitFor(function() return #carried() > before end, 1)
            end
            Trip.Count += 1
            Stats.Grabbed += 1
            log("Success", ("grabbed %s (%s %s)"):format(item.Name, item.Mutation, item.Rarity))
            return true
        end
        task.wait(0.05)
    end
    local failed = FailedAt[item.Model] or { Count = 0, At = 0 }
    failed.Count += 1
    failed.At = os.clock()
    FailedAt[item.Model] = failed
    return false
end

local function goHome()
    Stats.State = "going home"
    local home = homePosition()
    local back = remote("TeleportToBase")
    -- with the base never seen this server there is no point to go to, so the
    -- game's own teleport home is the only way there
    if back and (Travel.Return == "Remote" or not home) then
        pcall(function() back:FireServer() end)
        task.wait(0.6)
        local _, root = myCharacter()
        home = homePosition()
        if root and home and (root.Position - home).Magnitude < 60 then
            waitFor(function() return #slots() > 0 end, 3)
            return true
        end
    end
    if not home then
        log("Warn", "base position not known yet, walk to your base once")
        return false
    end
    local ok = travelTo(home, farmOn)
    -- your slots stream in after you arrive
    waitFor(function() return #slots() > 0 end, 3)
    return ok
end

local function collectCash()
    local _, root = myCharacter()
    if not root then return end
    local pads = {}
    for _, slot in ipairs(slots()) do
        if slot.Collect and not slot.Empty then pads[#pads + 1] = slot.Collect end
    end
    if typeof(firetouchinterest) == "function" then
        for _, pad in ipairs(pads) do touch(root, pad) end
        return
    end
    if not Cash.WalkFallback then return end
    for _, pad in ipairs(pads) do
        travelTo(pad.Position, function() return not Unloaded end)
        task.wait(0.1)
    end
end

local function worstSlotBelow(info)
    local worst
    for _, slot in ipairs(slots()) do
        if not slot.Empty and slot.Item and itemBetter(info, slot.Item) then
            if not worst or itemBetter(worst.Item, slot.Item) then worst = slot end
        end
    end
    return worst
end

-- Places what you carry, best first. Returns how many could not be placed,
-- and whether your slots were loaded in at all (a base that hasn't streamed in
-- is not a full one).
local function placeCarried()
    local _, _, hum = myCharacter()
    if not hum then return #carried(), false end
    if #slots() == 0 then return #carried(), false end
    local tools = carried()
    table.sort(tools, function(a, b) return itemBetter(toolInfo(a), toolInfo(b)) end)
    local left = 0
    for _, tool in ipairs(tools) do
        if not farmOn() then break end
        local target
        for _, slot in ipairs(slots()) do
            if slot.Empty then
                target = slot
                break
            end
        end
        if not target and Farm.Swap then target = worstSlotBelow(toolInfo(tool)) end
        if not target then
            left += 1
        else
            Stats.State = "placing " .. tostring(tool:GetAttribute("OriginalName"))
            travelTo(target.Spawn.Position, farmOn)
            pcall(function() hum:EquipTool(tool) end)
            task.wait(Farm.ActionDelay + 0.1)
            firePrompt(target.Prompt)
            local start = os.clock()
            while os.clock() - start < 1.5 and tool.Parent == LocalPlayer.Character do task.wait(0.05) end
            if tool.Parent ~= LocalPlayer.Character and tool.Parent ~= LocalPlayer:FindFirstChildOfClass("Backpack") then
                Stats.Placed += 1
                log("Log", ("placed %s in %s %s"):format(tostring(tool:GetAttribute("OriginalName")), target.Floor, target.Name))
            else
                left += 1
            end
        end
    end
    pcall(function() hum:UnequipTools() end)
    return left, true
end

local function sellCarried()
    local sell = remote("RequestSell")
    if not sell or #carried() == 0 then return end
    Stats.State = "selling"
    local count = #carried()
    travelTo(sellPosition(), farmOn)
    task.wait(Farm.ActionDelay)
    pcall(function() sell:FireServer("Inventory") end)
    task.wait(0.4)
    local sold = count - #carried()
    if sold > 0 then
        Stats.Sold += sold
        log("Log", ("sold %d item(s)"):format(sold))
    end
end

local FarmToggle -- the menu toggle, so a full base can switch it off

local function deposit()
    Stats.Trips += 1
    Trip.Count = 0
    if Farm.Deposit == "Sell" then
        sellCarried()
    else
        goHome()
        local left, loaded = placeCarried()
        if Farm.CollectOnReturn then collectCash() end
        if left > 0 and not loaded then
            log("Warn", "your base did not load in, trying again next trip")
            task.wait(1)
        elseif left > 0 then
            if Farm.Deposit == "Place then sell" then
                sellCarried()
            elseif Farm.StopWhenFull and #carried() >= Farm.PerTrip then
                log("Warn", "base is full, auto grab stopped")
                notify("auto grab stopped", "every slot is taken. turn on swap or the sell deposit to keep going.", "warning")
                if FarmToggle then FarmToggle:SetValue(false) else Farm.Enabled = false end
            end
        end
    end
end

-- Spawners the farm can visit when nothing it wants is loaded in: the saved
-- ones for the rarities you picked, best first (or nearest first). A full
-- round that finds nothing waits a few seconds before going round again.
local Scout = { Index = 0, Misses = 0, PauseUntil = 0 }

local function scoutList(origin)
    local list = {}
    for index = #RARITIES, 1, -1 do
        local rarity = RARITIES[index]
        if Saved.Spawners[rarity] and Farm.Rarities[rarity] then list[#list + 1] = rarity end
    end
    if Farm.Priority == "Nearest" and origin then
        table.sort(list, function(a, b)
            return (Saved.Spawners[a] - origin).Magnitude < (Saved.Spawners[b] - origin).Magnitude
        end)
    end
    return list
end

local function nextScout(origin)
    if not Farm.Scout or os.clock() < Scout.PauseUntil then return nil end
    local list = scoutList(origin)
    if #list == 0 then return nil end
    if Scout.Misses >= #list then
        Scout.Misses = 0
        Scout.PauseUntil = os.clock() + 4
        return nil
    end
    Scout.Index = Scout.Index % #list + 1
    Scout.Misses += 1
    return list[Scout.Index]
end

local function farmStep()
    local _, root = myCharacter()
    if not root then
        Stats.State = "waiting for character"
        task.wait(0.5)
        return
    end
    local holding = math.max(#carried(), Trip.Count)
    if holding >= Farm.PerTrip then
        deposit()
        return
    end
    local target = pickTarget(root.Position)
    if target then
        Scout.Misses = 0
    else
        -- look round the other spawners before heading home half full
        local rarity = nextScout(root.Position)
        if rarity then
            Stats.State = "checking the " .. rarity .. " spawner"
            travelTo(Saved.Spawners[rarity], farmOn)
            task.wait(Farm.ScoutWait)
            return
        end
        if holding > 0 then
            deposit()
            return
        end
        Stats.State = "nothing to grab"
        if Farm.IdleAtBase then
            local home = homePosition()
            if home and (root.Position - home).Magnitude > 40 then goHome() end
        end
        task.wait(0.5)
        return
    end
    if not grab(target) and holding > 0 then
        -- a pickup that does nothing while you already hold something is
        -- usually the carry limit
        local failed = FailedAt[target.Model]
        if failed and failed.Count >= 2 then deposit() end
    end
    task.wait(Farm.ActionDelay)
end

task.spawn(function()
    while not Unloaded do
        if Farm.Enabled and not Busy then
            Busy = true
            local ok, err = pcall(farmStep)
            Busy = false
            if not ok then
                log("Error", "farm: " .. tostring(err))
                task.wait(1)
            end
        else
            if not Farm.Enabled then Stats.State = "idle" end
            task.wait(0.2)
        end
    end
end)

task.spawn(function()
    while not Unloaded do
        task.wait(Cash.Interval)
        if Cash.Enabled and (typeof(firetouchinterest) == "function" or not Busy) then
            local wasBusy = Busy
            if not wasBusy then Busy = true end
            pcall(collectCash)
            if not wasBusy then Busy = false end
        end
    end
end)

--// upgrades ----------------------------------------------------------------

local CarryInfo = {} -- last Events.UpdateCarryPrices payload: Current, NextPrice, IsMax

do
    local event = remote("UpdateCarryPrices")
    if event then
        track(event.OnClientEvent:Connect(function(info)
            if type(info) == "table" then CarryInfo = info end
        end))
    end
end

local function jumpPrice(jp, amount)
    local total = 0
    for _ = 1, amount do
        total += 1.25 ^ math.max(0, jp - 1) * 50
        jp += 1
    end
    return math.floor(total)
end

local function canSpend(price)
    return leaderstat("Money") - (price or 0) >= Up.Reserve
end

local function fire(name, ...)
    local event = remote(name)
    if not event then return false end
    local args = table.pack(...)
    return (pcall(function() event:FireServer(table.unpack(args, 1, args.n)) end))
end

task.spawn(function()
    local nextSlotRound = 0
    while not Unloaded do
        task.wait(Up.Interval)
        pcall(function()
            local jp = leaderstat("Jump Power")
            local rebirths = leaderstat("Rebirths")

            if Up.Rebirth and jp >= 2 ^ rebirths * 40 then
                if fire("RequestRebirth") then
                    log("Success", ("rebirth %d"):format(rebirths + 1))
                    task.wait(2)
                    return
                end
            end

            if Up.Jump and canSpend(jumpPrice(jp, Up.JumpAmount)) then
                fire("PurchaseSpeed", Up.JumpAmount)
            end

            if Up.Carry and not CarryInfo.IsMax and canSpend(CarryInfo.NextPrice) then
                fire("PurchaseCarry")
            end

            if Up.Base then
                local plot = myPlot()
                local gui = plot and plot:FindFirstChild("BaseUpgrade") and plot.BaseUpgrade:FindFirstChild("GUIPart")
                if gui then
                    local level = gui:GetAttribute("CurrentLevel") or 0
                    local max = gui:GetAttribute("MaxLevel") or 2
                    if level < max and canSpend(gui:GetAttribute("Price")) then fire("RequestBaseUpgrade") end
                end
            end

            -- slot prices are only shown as formatted text, so these go out on
            -- their own slower round and the server turns down what you can't afford
            if Up.Slots and os.clock() >= nextSlotRound and canSpend(0) then
                nextSlotRound = os.clock() + math.max(3, Up.Interval * 5)
                for _, slot in ipairs(slots()) do
                    if not slot.Empty then fire("RequestSlotUpgrade", slot.Floor, slot.Name) end
                end
            end
        end)
    end
end)

--// player ------------------------------------------------------------------

local NoJumpPart = Workspace:FindFirstChild("no janp")
local DefaultWalkSpeed = 16
local VipParts = {}

local function inNoJumpZone(char)
    if not NoJumpPart then return false end
    local ok, parts = pcall(function() return Workspace:GetPartsInPart(NoJumpPart) end)
    if not ok then return false end
    for _, part in ipairs(parts) do
        if part:IsDescendantOf(char) then return true end
    end
    return false
end

local noJumpCheckAt, noJumpInside = 0, false

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    local char, root, hum = myCharacter()
    if not char then return end

    if Move.JumpOn then
        local now = os.clock()
        if not Move.IgnoreNoJump and now - noJumpCheckAt > 0.2 then
            noJumpCheckAt = now
            noJumpInside = inNoJumpZone(char)
        end
        if Move.IgnoreNoJump or not noJumpInside then
            hum.UseJumpPower = true
            if hum.JumpPower ~= Move.Jump then hum.JumpPower = Move.Jump end
        end
    end

    if Move.SpeedOn and hum.WalkSpeed ~= Move.Speed then hum.WalkSpeed = Move.Speed end

    if Move.Fly then
        local direction = hum.MoveDirection * Move.FlySpeed
        local vertical = 0
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then vertical += Move.FlySpeed end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
            vertical -= Move.FlySpeed
        end
        -- on touch there are no keys: pitch the camera up or down to climb
        if vertical == 0 and Camera and hum.MoveDirection.Magnitude > 0 then
            local look = Camera.CFrame.LookVector
            local flat = Vector3.new(look.X, 0, look.Z)
            if flat.Magnitude > 0 and hum.MoveDirection:Dot(flat.Unit) > 0.3 then
                vertical = look.Y * Move.FlySpeed
            end
        end
        root.AssemblyLinearVelocity = Vector3.new(direction.X, vertical, direction.Z)
    end
end))

track(RunService.Stepped:Connect(function()
    if Unloaded or not (Move.Noclip or Travelling) then return end
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloaded or not Move.InfiniteJump then return end
    local _, _, hum = myCharacter()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

-- The game's AntiFlingController lives in the character, so it comes back on
-- every respawn; disabling the script stops its Heartbeat clamp outright.
local function applyUncap()
    local char = LocalPlayer.Character
    if not char then return end
    for _, inst in ipairs(char:GetDescendants()) do
        if inst:IsA("LocalScript") and inst.Name == "AntiFlingController" then
            pcall(function() inst.Disabled = Move.Uncap end)
        end
    end
end

local function applyVip()
    for _, part in ipairs(CollectionService:GetTagged("V.I.P")) do
        if part:IsA("BasePart") then
            if Move.Vip then
                if VipParts[part] == nil then VipParts[part] = { part.CanCollide, part.Transparency } end
                part.CanCollide = false
                part.Transparency = math.max(part.Transparency, 0.5)
            elseif VipParts[part] then
                part.CanCollide = VipParts[part][1]
                part.Transparency = VipParts[part][2]
                VipParts[part] = nil
            end
        end
    end
end

track(CollectionService:GetInstanceAddedSignal("V.I.P"):Connect(function()
    if Move.Vip then applyVip() end
end))

track(LocalPlayer.CharacterAdded:Connect(function(char)
    char:WaitForChild("Humanoid", 10)
    task.wait(0.6)
    if Unloaded then return end
    if Move.Uncap then applyUncap() end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and not Move.SpeedOn then DefaultWalkSpeed = hum.WalkSpeed end
end))

do
    local _, _, hum = myCharacter()
    if hum then DefaultWalkSpeed = hum.WalkSpeed end
end

--// esp ---------------------------------------------------------------------

local EspFolder = Instance.new("Folder")
EspFolder.Name = "BrainrotEsp"
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    EspFolder.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end

local EspObjects = {}

local function espDrop(model)
    local obj = EspObjects[model]
    if not obj then return end
    pcall(function() obj.Gui:Destroy() end)
    if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
    EspObjects[model] = nil
end

local function espMake(item)
    local adornee = item.Prompt and item.Prompt.Parent
    if not adornee or not adornee:IsA("BasePart") then adornee = item.Model.PrimaryPart or item.Model:FindFirstChildWhichIsA("BasePart") end
    if not adornee then return nil end
    local gui = Instance.new("BillboardGui")
    gui.Name = "Esp"
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(220, 70)
    gui.StudsOffset = Vector3.new(0, 3, 0)
    gui.LightInfluence = 0
    gui.Adornee = adornee
    gui.Parent = EspFolder
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.RichText = true
    label.TextStrokeTransparency = 0.4
    label.TextYAlignment = Enum.TextYAlignment.Bottom
    label.Parent = gui
    local obj = { Gui = gui, Label = label }
    EspObjects[item.Model] = obj
    return obj
end

local function espText(item, distance)
    local lines = {}
    if Esp.Name then lines[#lines + 1] = item.Name end
    local tags = {}
    if Esp.Mutation and item.Mutation ~= "Normal" then tags[#tags + 1] = item.Mutation end
    if Esp.Rarity then tags[#tags + 1] = item.Rarity end
    if #tags > 0 then lines[#lines + 1] = table.concat(tags, " ") end
    local extra = {}
    if Esp.Income and item.Income > 0 then extra[#extra + 1] = "$" .. formatNumber(item.Income) .. "/s" end
    if Esp.Timer and item.ExpiresAt then
        local left = math.max(0, item.ExpiresAt - serverNow())
        extra[#extra + 1] = string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))
    end
    if Esp.Distance and distance then extra[#extra + 1] = math.floor(distance) .. "m" end
    if #extra > 0 then lines[#lines + 1] = table.concat(extra, "  ") end
    return table.concat(lines, "\n")
end

task.spawn(function()
    while not Unloaded do
        task.wait(0.2)
        pcall(function()
            if not Esp.Enabled then
                for model in pairs(EspObjects) do espDrop(model) end
                return
            end
            local _, root = myCharacter()
            local origin = root and root.Position or (Camera and Camera.CFrame.Position) or Vector3.zero
            local seen = {}
            for _, item in ipairs(allItems()) do
                local distance = (item.Position - origin).Magnitude
                if Esp.Rarities[item.Rarity] and distance <= Esp.MaxDistance then
                    seen[item.Model] = true
                    local obj = EspObjects[item.Model] or espMake(item)
                    if obj then
                        local color = rarityColor(item.Rarity)
                        obj.Label.TextColor3 = color
                        obj.Label.TextSize = Esp.TextSize
                        obj.Label.Text = espText(item, distance)
                        if Esp.Highlight and not obj.Highlight then
                            local highlight = Instance.new("Highlight")
                            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                            highlight.FillTransparency = 0.7
                            highlight.Adornee = item.Model
                            highlight.Parent = EspFolder
                            obj.Highlight = highlight
                        elseif not Esp.Highlight and obj.Highlight then
                            obj.Highlight:Destroy()
                            obj.Highlight = nil
                        end
                        if obj.Highlight then
                            obj.Highlight.FillColor = color
                            obj.Highlight.OutlineColor = color
                        end
                    end
                end
            end
            for model in pairs(EspObjects) do
                if not seen[model] then espDrop(model) end
            end
        end)
    end
end)

--// alerts ------------------------------------------------------------------

local function playAlertSound()
    if not Alerts.Sound then return end
    local sounds = Workspace:FindFirstChild("Sounds")
    local sound = sounds and (sounds:FindFirstChild("Win") or sounds:FindFirstChild("Success"))
    if sound and sound:IsA("Sound") then pcall(function() sound:Play() end) end
end

for name, label in pairs({ DivineSpawned = "Divine", InsaneSpawned = "Insane" }) do
    local event = remote(name)
    if event then
        track(event.OnClientEvent:Connect(function()
            if not Alerts.Specials then return end
            log("Success", label .. " spawned")
            notify(label .. " spawned", Farm.Enabled and Farm.RushSpecials and "auto grab is heading for it" or "", "success")
            playAlertSound()
        end))
    end
end

do
    local announced = setmetatable({}, { __mode = "k" })
    -- Everything already on the map when the script starts counts as seen, so
    -- only new spawns are announced.
    for _, item in ipairs(allItems()) do announced[item.Model] = true end
    task.spawn(function()
        while not Unloaded do
            task.wait(0.5)
            pcall(function()
                for _, item in ipairs(allItems()) do
                    if not announced[item.Model] then
                        announced[item.Model] = true
                        if Alerts.Rarities[item.Rarity] then
                            local text = ("%s%s (%s)"):format(item.Mutation ~= "Normal" and (item.Mutation .. " ") or "", item.Name, item.Rarity)
                            log("Info", "spawned: " .. text)
                            notify("new " .. item.Rarity, text, "info")
                            playAlertSound()
                        end
                    end
                end
            end)
        end
    end)
end

--// rewards -----------------------------------------------------------------

local ClaimedGifts = {}

task.spawn(function()
    local nextDaily = 0
    while not Unloaded do
        task.wait(3)
        pcall(function()
            if Misc.Daily and os.clock() >= nextDaily then
                nextDaily = os.clock() + 60
                local data = remote("RequestDailyRewardData")
                local ok, info = pcall(function() return data and data:InvokeServer() end)
                if ok and type(info) == "table" and info.CanClaim then
                    if fire("ClaimDailyReward") then log("Success", "daily reward claimed") end
                end
            end

            if Misc.Playtime and GiftFolder and GiftFolder:FindFirstChild("ClaimGift") then
                local session = LocalPlayer:FindFirstChild("CurrentSession")
                local played = session and tonumber(session.Value) or 0
                for _, gift in ipairs(GiftData) do
                    local number = gift.GiftNumber
                    if number and not ClaimedGifts[number] and played >= (gift.Time or math.huge) then
                        local ok, result = pcall(function() return GiftFolder.ClaimGift:InvokeServer(number) end)
                        if ok then
                            -- true is a claim; anything else is already claimed or
                            -- refused, so it is not asked again this session
                            ClaimedGifts[number] = true
                            if result == true then log("Success", ("playtime gift %d claimed"):format(number)) end
                        end
                    end
                end
            end

            if Misc.Spin then
                local ad = LocalPlayer:FindFirstChild("AdData")
                local tickets = ad and ad:FindFirstChild("AdSpinTickets")
                local spin = remote("SpinRequest")
                if tickets and tickets.Value > 0 and spin then
                    local ok, result = pcall(function() return spin:InvokeServer() end)
                    if ok then log("Success", "spun the wheel: " .. tostring(type(result) == "table" and (result.Name or result.Reward) or result)) end
                    task.wait(4)
                end
            end
        end)
    end
end)

local function groupRewardPrompt()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("ProximityPrompt") and inst.ObjectText == "Group Reward" then return inst end
    end
    return nil
end

-- Runs a one-off trip somewhere and back, holding the farm while it does.
local function errand(fn)
    task.spawn(function()
        while Busy and not Unloaded do task.wait(0.05) end
        Busy = true
        local _, root = myCharacter()
        local back = root and root.Position
        local ok, err = pcall(fn)
        if not ok then log("Error", tostring(err)) end
        task.wait(0.2)
        if back then travelTo(back - Vector3.new(0, Travel.Height, 0)) end
        Busy = false
    end)
end

--// anti afk ----------------------------------------------------------------

do
    local ok, VirtualUser = pcall(function() return game:GetService("VirtualUser") end)
    if ok and VirtualUser then
        track(LocalPlayer.Idled:Connect(function()
            if not Misc.AntiAfk or Unloaded then return end
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end))
    end
end

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Farm.Enabled = false
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    local _, root, hum = myCharacter()
    if hum and Move.SpeedOn then hum.WalkSpeed = DefaultWalkSpeed end
    if root and Move.Fly then root.AssemblyLinearVelocity = Vector3.zero end
    if Move.Uncap then
        Move.Uncap = false
        applyUncap()
    end
    if Move.Vip then
        Move.Vip = false
        applyVip()
    end
    for model in pairs(EspObjects) do espDrop(model) end
    pcall(function() EspFolder:Destroy() end)
    if Genv.__WallHopBrainrotsStop == unload then Genv.__WallHopBrainrotsStop = nil end
end

Genv.__WallHopBrainrotsStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Wall Hop for Brainrots',
    Footer = 'assist',
    Icon = 'mountain',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Magenta',
    ConfigFolder = 'WallHopBrainrots',
})

-- unloading from the menu's own settings tears the script down too
Library:OnUnload(unload)

-- Ui3 hands a multi dropdown's value over as { [value] = true }; a default
-- (or anything else) may still be a plain array, so both are accepted.
local function asSet(value)
    local set = {}
    if type(value) ~= "table" then return set end
    for key, flag in pairs(value) do
        if type(key) == "number" then
            set[flag] = true
        elseif flag then
            set[key] = true
        end
    end
    return set
end

local function setToList(set, order)
    local list = {}
    for _, name in ipairs(order) do
        if set[name] then list[#list + 1] = name end
    end
    return list
end

-- names typed as a comma separated list, matched without case
local function nameSet(text)
    local set = {}
    for name in tostring(text or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then set[name:lower()] = true end
    end
    return set
end

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

do
    local FarmTab = Window:AddTab('Farm', 'tractor', 'Auto grab, deposits and cash')

    local overview = FarmTab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('whb_stats', {
        Cards = {
            { Title = 'Money', Value = '$0', Icon = 'dollar-sign' },
            { Title = 'Jump Power', Value = '0', Icon = 'arrow-up' },
            { Title = 'Rebirths', Value = '0', Icon = 'refresh-cw' },
            { Title = 'Carrying', Value = '0', Icon = 'package' },
            { Title = 'Grabbed', Value = '0', Icon = 'hand' },
            { Title = 'Placed / Sold', Value = '0 / 0', Icon = 'warehouse' },
        },
    })
    local stateLabel = overview:AddLabel('doing: idle')
    every(0.5, function()
        cards:SetValue('Money', '$' .. formatNumber(leaderstat("Money")))
        cards:SetValue('Jump Power', formatNumber(leaderstat("Jump Power")))
        cards:SetValue('Rebirths', tostring(leaderstat("Rebirths")))
        cards:SetValue('Carrying', tostring(#carried()))
        cards:SetValue('Grabbed', tostring(Stats.Grabbed))
        cards:SetValue('Placed / Sold', Stats.Placed .. ' / ' .. Stats.Sold)
        stateLabel:SetText('doing: ' .. Stats.State)
    end)

    local grabBox = FarmTab:AddLeftGroupbox('Auto grab', 'hand')

    FarmToggle = grabBox:AddToggle('whb_farm', {
        Text = 'Auto grab',
        Tooltip = 'goes to the best brainrot that passes the filters below, picks it up, and brings it home once you carry the amount set under trips',
        Default = false,
        Callback = function(state) Farm.Enabled = state end,
    })
    FarmToggle:AddKeyPicker('whb_farm_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Auto grab',
    })

    grabBox:AddDropdown('whb_farm_rarities', {
        Text = 'Rarities',
        Values = RARITIES,
        Multi = true,
        Default = setToList(Farm.Rarities, RARITIES),
        Callback = function(value) Farm.Rarities = asSet(value) end,
    })

    grabBox:AddDropdown('whb_farm_mutations', {
        Text = 'Mutations',
        Values = MUTATIONS,
        Multi = true,
        Default = table.clone(MUTATIONS),
        Callback = function(value) Farm.Mutations = asSet(value) end,
    })

    grabBox:AddDropdown('whb_farm_priority', {
        Text = 'Go for',
        Values = { 'Rarity', 'Income', 'Nearest' },
        Default = Farm.Priority,
        Callback = function(value) Farm.Priority = value or 'Rarity' end,
    })

    grabBox:AddToggle('whb_farm_specials', {
        Text = 'Rush Divine and up',
        Tooltip = 'Divine, Insane and Exclusive spawns are grabbed first, even if the rarity, mutation or name filters would skip them',
        Default = Farm.RushSpecials,
        Callback = function(state) Farm.RushSpecials = state end,
    })

    grabBox:AddInput('whb_farm_only', {
        Text = 'Only these names',
        Placeholder = 'comma separated, empty = any',
        Default = '',
        Callback = function(text) Farm.Only = nameSet(text) end,
    })

    grabBox:AddInput('whb_farm_ignore', {
        Text = 'Never grab',
        Placeholder = 'comma separated',
        Default = '',
        Callback = function(text) Farm.Ignore = nameSet(text) end,
    })

    grabBox:AddSlider('whb_farm_timeleft', {
        Text = 'Skip if despawning within',
        Min = 0, Max = 30, Default = Farm.MinTimeLeft, Rounding = 0, Suffix = 's',
        Callback = function(value) Farm.MinTimeLeft = value end,
    })

    local trips = FarmTab:AddRightGroupbox('Trips', 'route')

    trips:AddSlider('whb_farm_pertrip', {
        Text = 'Items per trip',
        Tooltip = 'how many to pick up before heading home. the game has its own carry limit (buy more at the carry shop); a pickup that fails because of it sends you home early',
        Min = 1, Max = 20, Default = Farm.PerTrip, Rounding = 0,
        Callback = function(value) Farm.PerTrip = value end,
    })

    trips:AddDropdown('whb_farm_deposit', {
        Text = 'When home',
        Values = { 'Place', 'Sell', 'Place then sell' },
        Default = Farm.Deposit,
        Callback = function(value) Farm.Deposit = value or 'Place' end,
    })

    trips:AddToggle('whb_farm_swap', {
        Text = 'Swap worse items',
        Tooltip = 'with every slot taken, swaps what you carry for the worst placed brainrot it beats (same ranking as "go for")',
        Default = Farm.Swap,
        Callback = function(state) Farm.Swap = state end,
    })

    trips:AddToggle('whb_farm_stopfull', {
        Text = 'Stop when base is full',
        Default = Farm.StopWhenFull,
        Callback = function(state) Farm.StopWhenFull = state end,
    })

    trips:AddToggle('whb_farm_collect', {
        Text = 'Collect cash on return',
        Default = Farm.CollectOnReturn,
        Callback = function(state) Farm.CollectOnReturn = state end,
    })

    trips:AddToggle('whb_farm_idle', {
        Text = 'Wait at base when idle',
        Default = Farm.IdleAtBase,
        Callback = function(state) Farm.IdleAtBase = state end,
    })

    local travel = FarmTab:AddLeftGroupbox('Travel', 'navigation')

    travel:AddDropdown('whb_travel_mode', {
        Text = 'Move by',
        Values = { 'Teleport', 'Tween' },
        Default = Travel.Mode,
        Callback = function(value) Travel.Mode = value or 'Teleport' end,
    })

    travel:AddSlider('whb_travel_speed', {
        Text = 'Tween speed',
        Min = 30, Max = 1500, Default = Travel.Speed, Rounding = 0, Suffix = ' studs/s',
        Callback = function(value) Travel.Speed = value end,
    })

    travel:AddDropdown('whb_travel_return', {
        Text = 'Go home by',
        Tooltip = 'remote asks the server to send you home with the game\'s own teleport-to-base; it falls back to moving there yourself if it does not take',
        Values = { 'Teleport', 'Remote' },
        Default = Travel.Return,
        Callback = function(value) Travel.Return = value or 'Teleport' end,
    })

    travel:AddSlider('whb_travel_height', {
        Text = 'Arrive above target',
        Min = 0, Max = 8, Default = Travel.Height, Rounding = 1, Suffix = ' studs',
        Callback = function(value) Travel.Height = value end,
    })

    travel:AddSlider('whb_farm_delay', {
        Text = 'Action delay',
        Min = 0, Max = 1, Default = Farm.ActionDelay, Rounding = 2, Suffix = 's',
        Callback = function(value) Farm.ActionDelay = value end,
    })

    local spots = FarmTab:AddLeftGroupbox('Saved positions', 'map-pinned')

    spots:AddToggle('whb_farm_scout', {
        Text = 'Visit saved spawners',
        Tooltip = 'brainrots far away are not loaded in, so with nothing wanted in view the farm goes round the saved spawners of the rarities you picked to load them',
        Default = Farm.Scout,
        Callback = function(state) Farm.Scout = state end,
    })

    spots:AddSlider('whb_farm_scoutwait', {
        Text = 'Wait at a spawner',
        Min = 0.2, Max = 5, Default = Farm.ScoutWait, Rounding = 1, Suffix = 's',
        Callback = function(value) Farm.ScoutWait = value end,
    })

    spots:AddSlider('whb_farm_pickupwait', {
        Text = 'Pickup wait',
        Tooltip = 'how long a pickup gets before it counts as failed',
        Min = 0.5, Max = 6, Default = Farm.PickupWait, Rounding = 1, Suffix = 's',
        Callback = function(value) Farm.PickupWait = value end,
    })

    local spotsLabel = spots:AddLabel('saved: -', true)
    every(1, function()
        local found = {}
        for _, rarity in ipairs(RARITIES) do
            if Saved.Spawners[rarity] then found[#found + 1] = rarity end
        end
        local missing = {}
        for _, rarity in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical" }) do
            if not Saved.Spawners[rarity] then missing[#missing + 1] = rarity end
        end
        spotsLabel:SetText(("spawners: %s\nnot seen yet: %s\nbase: %s%s"):format(
            #found > 0 and table.concat(found, ", ") or "none",
            #missing > 0 and table.concat(missing, ", ") or "none",
            homePosition() and "saved" or "not seen this server",
            canFile() and "" or "\n(no writefile, positions last until you leave)"))
    end)

    local saveAs = "Mythical"
    local saveValues = { "my base" }
    for _, rarity in ipairs(RARITIES) do saveValues[#saveValues + 1] = rarity end
    spots:AddDropdown('whb_spot_kind', {
        Text = 'Save where I stand as',
        Tooltip = 'for a spawner that never loaded in while the script ran (or the rarer ones that have no spawner part)',
        Values = saveValues,
        Default = saveAs,
        Callback = function(value) saveAs = value or "Mythical" end,
    })
    Library:SetIgnoreIndexes({ 'whb_spot_kind' })

    spots:AddButton({
        Text = 'Save here',
        Func = function()
            local _, root = myCharacter()
            if not root then return end
            local pos = root.Position - Vector3.new(0, 3, 0)
            if saveAs == "my base" then
                Session.Home = pos
            else
                remember(Saved.Spawners, saveAs, pos, true)
            end
            log("Success", "saved " .. saveAs)
        end,
    }):AddButton({
        Text = 'Forget all',
        DoubleClick = true,
        Func = function()
            table.clear(Saved.Spawners)
            table.clear(Saved.Points)
            Session.Home = nil
            table.clear(Session.Slots)
            writeSaved()
            log("Warn", "saved positions cleared")
        end,
    })

    local cash = FarmTab:AddRightGroupbox('Cash', 'banknote')

    cash:AddToggle('whb_cash', {
        Text = 'Auto collect cash',
        Tooltip = 'touches the collect pad of every filled slot on your base',
        Default = false,
        Callback = function(state) Cash.Enabled = state end,
    })

    cash:AddSlider('whb_cash_interval', {
        Text = 'Collect every',
        Min = 1, Max = 60, Default = Cash.Interval, Rounding = 0, Suffix = 's',
        Callback = function(value) Cash.Interval = value end,
    })

    cash:AddToggle('whb_cash_walk', {
        Text = 'Walk pads if needed',
        Tooltip = typeof(firetouchinterest) == "function"
            and 'your executor has firetouchinterest, so pads are touched from anywhere and this is not used'
            or 'your executor has no firetouchinterest, so collecting moves you over each pad',
        Default = Cash.WalkFallback,
        Callback = function(state) Cash.WalkFallback = state end,
    })

    cash:AddButton({ Text = 'Collect now', Func = function() errand(collectCash) end }):AddButton({
        Text = 'Sell inventory',
        Func = function()
            errand(function()
                travelTo(sellPosition())
                task.wait(0.15)
                fire("RequestSell", "Inventory")
                task.wait(0.3)
            end)
        end,
    })
end

do
    local UpTab = Window:AddTab('Upgrades', 'trending-up', 'Auto buy and rebirth')
    local buy = UpTab:AddLeftGroupbox('Auto buy', 'shopping-cart')

    buy:AddToggle('whb_up_jump', {
        Text = 'Jump power',
        Default = false,
        Callback = function(state) Up.Jump = state end,
    })

    buy:AddDropdown('whb_up_jump_amount', {
        Text = 'Jump power per buy',
        Values = { '1', '5', '10' },
        Default = '1',
        Callback = function(value) Up.JumpAmount = tonumber(value) or 1 end,
    })

    buy:AddToggle('whb_up_carry', {
        Text = 'Carry',
        Default = false,
        Callback = function(state) Up.Carry = state end,
    })

    buy:AddToggle('whb_up_base', {
        Text = 'Base floors',
        Default = false,
        Callback = function(state) Up.Base = state end,
    })

    buy:AddToggle('whb_up_slots', {
        Text = 'Slot levels',
        Tooltip = 'upgrades every filled slot on your base',
        Default = false,
        Callback = function(state) Up.Slots = state end,
    })

    buy:AddToggle('whb_up_rebirth', {
        Text = 'Auto rebirth',
        Tooltip = 'rebirths as soon as your jump power reaches the cost, 2^rebirths x 40. each rebirth adds x0.5 to your money multiplier',
        Default = false,
        Callback = function(state) Up.Rebirth = state end,
    })

    local limits = UpTab:AddRightGroupbox('Limits', 'wallet')

    limits:AddInput('whb_up_reserve', {
        Text = 'Keep at least ($)',
        Tooltip = 'the auto buyers never spend below this',
        Numeric = true,
        Default = tostring(Up.Reserve),
        Placeholder = '0',
        Callback = function(value) Up.Reserve = math.max(0, tonumber(value) or 0) end,
    })

    limits:AddSlider('whb_up_interval', {
        Text = 'Buy every',
        Min = 0.2, Max = 10, Default = Up.Interval, Rounding = 1, Suffix = 's',
        Callback = function(value) Up.Interval = value end,
    })

    local prices = limits:AddLabel('next jump power: -', true)
    local rebirthCost = limits:AddLabel('next rebirth: -', true)
    every(0.5, function()
        local jp = leaderstat("Jump Power")
        local rebirths = leaderstat("Rebirths")
        local carry = CarryInfo.Current and (CarryInfo.IsMax and "max" or ("$" .. formatNumber(CarryInfo.NextPrice or 0))) or "open the carry shop once"
        prices:SetText(("next jump power: $%s\nnext carry: %s"):format(formatNumber(jumpPrice(jp, Up.JumpAmount)), carry))
        rebirthCost:SetText(("next rebirth: %s jump power (x%.1f money)"):format(formatNumber(2 ^ rebirths * 40), 1 + (rebirths + 1) * 0.5))
    end)
end

do
    local PlayerTab = Window:AddTab('Player', 'user', 'Movement and teleports')

    local jump = PlayerTab:AddLeftGroupbox('Jump', 'arrow-up')

    jump:AddToggle('whb_move_jump', {
        Text = 'Jump power override',
        Tooltip = 'the game sets your jump power on the client from your stat, so any value works here',
        Default = false,
        Callback = function(state)
            Move.JumpOn = state
            if not state then
                -- hands jump power back to the game's own script on its next update
                local _, _, hum = myCharacter()
                if hum then hum.JumpPower = (leaderstat("Jump Power") - 1) * 2 + 50 end
            end
        end,
    })

    jump:AddSlider('whb_move_jump_value', {
        Text = 'Jump power',
        Min = 50, Max = 3000, Default = Move.Jump, Rounding = 0,
        Callback = function(value) Move.Jump = value end,
    })

    jump:AddToggle('whb_move_nojump', {
        Text = 'Ignore no-jump zone',
        Default = Move.IgnoreNoJump,
        Callback = function(state) Move.IgnoreNoJump = state end,
    })

    jump:AddToggle('whb_move_infjump', {
        Text = 'Infinite jump',
        Default = false,
        Callback = function(state) Move.InfiniteJump = state end,
    })

    jump:AddToggle('whb_move_uncap', {
        Text = 'Remove wall speed cap',
        Tooltip = 'turns off the game\'s anti fling script, which caps your speed off walls at 55 every frame, so wall hops keep all their momentum',
        Default = false,
        Callback = function(state)
            Move.Uncap = state
            applyUncap()
        end,
    })

    jump:AddButton({
        Text = 'Open wall hop helper',
        Tooltip = 'loads the hub\'s universal wall hop script in its own window',
        Func = function()
            local ok, err = pcall(function()
                loadstring(game:HttpGet(REPO_RAW_BASE .. 'Universal/WallHop.lua'))()
            end)
            if not ok then log("Error", "wall hop: " .. tostring(err)) end
        end,
    })

    local movement = PlayerTab:AddRightGroupbox('Movement', 'footprints')

    movement:AddToggle('whb_move_speed', {
        Text = 'Walk speed',
        Default = false,
        Callback = function(state)
            Move.SpeedOn = state
            local _, _, hum = myCharacter()
            if hum and not state then hum.WalkSpeed = DefaultWalkSpeed end
        end,
    })

    movement:AddSlider('whb_move_speed_value', {
        Text = 'Speed',
        Min = 16, Max = 300, Default = Move.Speed, Rounding = 0,
        Callback = function(value) Move.Speed = value end,
    })

    movement:AddToggle('whb_move_fly', {
        Text = 'Fly',
        Tooltip = 'space to rise, ctrl or shift to sink. on touch, look up or down while moving forward',
        Default = false,
        Callback = function(state)
            Move.Fly = state
            local _, root = myCharacter()
            if root and not state then root.AssemblyLinearVelocity = Vector3.zero end
        end,
    }):AddKeyPicker('whb_move_fly_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Fly',
    })

    movement:AddSlider('whb_move_fly_speed', {
        Text = 'Fly speed',
        Min = 10, Max = 500, Default = Move.FlySpeed, Rounding = 0,
        Callback = function(value) Move.FlySpeed = value end,
    })

    movement:AddToggle('whb_move_noclip', {
        Text = 'Noclip',
        Default = false,
        Callback = function(state) Move.Noclip = state end,
    })

    movement:AddToggle('whb_move_vip', {
        Text = 'Open VIP door',
        Tooltip = 'the vip door only stops colliding on the owner\'s client; this does the same on yours',
        Default = false,
        Callback = function(state)
            Move.Vip = state
            applyVip()
        end,
    })

    local tp = PlayerTab:AddLeftGroupbox('Teleport', 'map-pin')

    -- everything here goes by the saved positions, so a spot that has
    -- streamed out can still be reached
    local function destinations()
        local list = { "my base" }
        for _, point in ipairs(POINTS) do list[#list + 1] = point[1] end
        for _, rarity in ipairs(RARITIES) do
            if Saved.Spawners[rarity] then list[#list + 1] = rarity .. " spawner" end
        end
        return list
    end

    local function destination(name)
        if name == "my base" then return homePosition() end
        if name == "sell npc" then return sellPosition() end
        local rarity = name:match("^(%S+) spawner$")
        if rarity then return Saved.Spawners[rarity] end
        return Saved.Points[name]
    end

    local chosen = "my base"
    local dropdown = tp:AddDropdown('whb_tp_place', {
        Text = 'Place',
        Values = destinations(),
        Default = chosen,
        Callback = function(value) chosen = value or "my base" end,
    })
    -- where to go is picked fresh each time, so it is not saved in configs
    Library:SetIgnoreIndexes({ 'whb_tp_place' })

    tp:AddButton({
        Text = 'Go',
        Func = function()
            local pos = destination(chosen)
            if pos then
                task.spawn(travelTo, pos)
            else
                log("Warn", "could not find " .. tostring(chosen))
            end
        end,
    }):AddButton({ Text = 'Refresh list', Func = function() dropdown:SetValues(destinations()) end })
end

do
    local VisualTab = Window:AddTab('Visuals', 'eye', 'Item esp and spawn alerts')
    local esp = VisualTab:AddLeftGroupbox('Brainrot esp', 'scan-eye')

    esp:AddToggle('whb_esp', {
        Text = 'Esp',
        Default = false,
        Callback = function(state) Esp.Enabled = state end,
    })

    esp:AddDropdown('whb_esp_rarities', {
        Text = 'Show rarities',
        Values = RARITIES,
        Multi = true,
        Default = table.clone(RARITIES),
        Callback = function(value) Esp.Rarities = asSet(value) end,
    })

    for _, entry in ipairs({
        { 'whb_esp_name', 'Name', 'Name' },
        { 'whb_esp_rarity', 'Rarity', 'Rarity' },
        { 'whb_esp_mutation', 'Mutation', 'Mutation' },
        { 'whb_esp_timer', 'Despawn timer', 'Timer' },
        { 'whb_esp_distance', 'Distance', 'Distance' },
        { 'whb_esp_income', 'Base income', 'Income' },
        { 'whb_esp_highlight', 'Highlight', 'Highlight' },
    }) do
        local key = entry[3]
        esp:AddCheckbox(entry[1], {
            Text = entry[2],
            Default = Esp[key],
            Callback = function(state) Esp[key] = state end,
        })
    end

    esp:AddSlider('whb_esp_textsize', {
        Text = 'Text size',
        Min = 8, Max = 28, Default = Esp.TextSize, Rounding = 0,
        Callback = function(value) Esp.TextSize = value end,
    })

    esp:AddSlider('whb_esp_distance_max', {
        Text = 'Max distance',
        Min = 50, Max = 20000, Default = Esp.MaxDistance, Rounding = 0, Suffix = ' studs',
        Callback = function(value) Esp.MaxDistance = value end,
    })

    local alerts = VisualTab:AddRightGroupbox('Spawn alerts', 'bell-ring')

    alerts:AddToggle('whb_alert_specials', {
        Text = 'Divine / Insane announcements',
        Default = Alerts.Specials,
        Callback = function(state) Alerts.Specials = state end,
    })

    alerts:AddDropdown('whb_alert_rarities', {
        Text = 'Notify on new',
        Values = RARITIES,
        Multi = true,
        Default = setToList(Alerts.Rarities, RARITIES),
        Callback = function(value) Alerts.Rarities = asSet(value) end,
    })

    alerts:AddToggle('whb_alert_sound', {
        Text = 'Alert sound',
        Default = Alerts.Sound,
        Callback = function(state) Alerts.Sound = state end,
    })
end

do
    local MiscTab = Window:AddTab('Misc', 'gift', 'Free rewards and session')
    local rewards = MiscTab:AddLeftGroupbox('Free rewards', 'gift')

    rewards:AddToggle('whb_misc_daily', {
        Text = 'Auto daily reward',
        Default = false,
        Callback = function(state) Misc.Daily = state end,
    })

    rewards:AddToggle('whb_misc_playtime', {
        Text = 'Auto playtime gifts',
        Tooltip = 'claims each of the nine playtime gifts the moment your session time reaches it (5 minutes up to 100)',
        Default = false,
        Callback = function(state) Misc.Playtime = state end,
    })

    rewards:AddToggle('whb_misc_spin', {
        Text = 'Auto spin',
        Tooltip = 'spins the wheel whenever you have a spin ticket',
        Default = false,
        Callback = function(state) Misc.Spin = state end,
    })

    rewards:AddButton({
        Text = 'Claim group reward',
        Tooltip = 'goes to the group reward stand, presses it, and comes back. it only pays out if you are in the group',
        Func = function()
            errand(function()
                local prompt = groupRewardPrompt()
                if not prompt then
                    log("Warn", "group reward stand not found")
                    return
                end
                travelTo(promptPosition(prompt))
                task.wait(0.2)
                firePrompt(prompt)
                task.wait(0.4)
            end)
        end,
    })

    local session = MiscTab:AddRightGroupbox('Session', 'power')

    session:AddToggle('whb_misc_afk', {
        Text = 'Anti afk',
        Default = Misc.AntiAfk,
        Callback = function(state) Misc.AntiAfk = state end,
    })

    session:AddButton({
        Text = 'Unload',
        Risky = true,
        DoubleClick = true,
        Func = function() Library:Unload() end,
    })

    local logBox = MiscTab:AddBigGroupbox('Log', 'scroll-text')
    Log = logBox:AddLog('whb_log', { Height = 170, MaxLines = 150, Timestamps = true })
    Log:Log('loaded. configs, themes and the menu key live under settings (gear icon, top right).')
    if not ItemConfig then log("Warn", 'could not read ItemConfigurations, income sorting falls back to rarity') end
    if typeof(fireproximityprompt) ~= "function" then log("Warn", 'no fireproximityprompt, prompts are pressed through their own input') end
    for _, line in ipairs(PendingLog) do
        pcall(function() Log:Log(line[1], line[2]) end)
    end
    table.clear(PendingLog)
end

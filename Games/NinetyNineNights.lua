--// Survive 99 Nights ------------------------------------------------------------------
-- Built against a script dump of the live game (place 126509999114328, version 712).
--
-- What the game's own client scripts show:
--  * Every swing of an axe, sword or chainsaw ends in
--    RemoteEvents.ToolDamageObject:InvokeServer(target, tool, hitId, rootCFrame, killing)
--    where `tool` is the item model in Players.<you>.Inventory, `hitId` is
--    "<counter>_<abs UserId>" (EnemyHandler.GetHitRegId) and `killing` is true
--    when a resource's Health minus the hits already sent reaches 0. One swing
--    hits everything inside a small box in front of you, on the tool's
--    ToolCooldown (0.5 s on the Good Axe).
--  * Trees and other choppable things are models with a Resource attribute
--    ("Tree", "IceBlock", "MeteorNode", ...), a Health attribute and a
--    HitRegisters folder. AllowTool_<ToolName> says which tools can hit it and
--    ToolTier is the tier the tool needs.
--  * Mobs live in Workspace.Characters with a Humanoid named "NPC". The game's
--    own "can this be hit" check (Flashlight) is: has NPC, no NotAttackable, no
--    NotDamageable, not Tamed. Lost kids carry KidId / NPCType "Lost Child" and
--    NotAttackable. A mob after you has State "Chase" and ChasingPlayer = your
--    UserId, and attacks with its AttackRange / AttackCooldown attributes.
--  * Equipping is EquipItemHandle:FireServer("FireAllClients", item) and your
--    character's Equipped attribute holds the held item's name.
--  * Workspace.Map.MissingKids keeps a Vector3 attribute per kid still missing
--    (DinoKid, KoalaKid, KrakenKid, SquidKid), so a kid can be found without its
--    model being streamed in.
--  * Workspace attributes carry the clock: State (Day / Night), SecondsLeft,
--    StoryDayCounter, Weather, Biome, CultistAttackDay, plus the cave teleport
--    points (CaveTeleport_Exit1..5, CaveTeleport_Entrance1).
--  * Your stats are attributes on your Player: Hunger (max 200), Temperature,
--    Warmth, Armour, Class, ClassLevel, Diamonds, Candy.
--  * Moving loose items (Workspace.Items) is the game's drag:
--    RequestStartDraggingItem:FireServer(item) hands you the item, the client
--    moves it, StopDraggingItem:FireServer(item) gives it back. The camp fire
--    burns with RequestBurnItem:FireServer(MainFire, item) (fuel = BurnFuel,
--    not Wet), the crafting bench scraps with
--    RequestScrapItem:InvokeServer(CraftingBench, item).
--  * Eating and healing: RequestConsumeItem:InvokeServer(item). Coins (tag
--    Coins): RequestCollectCoints:InvokeServer(item). Diamonds:
--    RequestTakeDiamonds:FireServer(item). Chests: their prompt, or
--    RequestOpenItemChest:FireServer(chest). Lost kids go in the sack with
--    RequestBagStoreItem:InvokeServer(sack, kid) and come out with
--    RequestBagDropItem:FireServer(sack, kid, isLast); sack contents live in
--    Players.<you>.ItemBag.
--  * The only client anti cheat is AntiFlingClient: a root moving faster than
--    300 studs/s is slowed to 100. Fly and tween teleports stay under that.
--
-- Mobs are sorted by what they do, not by name, so new mobs from updates are
-- picked up without changes here:
--   Hostile    chasing someone, or has AttackDamage / AggroRange
--   Can attack has AttackRange and AttackCooldown (can fight back)
--   Passive    neither
--   Kids, pets, the dead and anything marked NotAttackable are never hit.
--
-- The automations (tree farm, kid rescue, chest run, night safety) only chain
-- the calls above: move, then do what you'd do standing there. One runs at a
-- time; starting one stops the other.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__NinetyNineUnload then
    pcall(Genv.__NinetyNineUnload)
end
Genv.__NinetyNineRun = (Genv.__NinetyNineRun or 0) + 1
local RUN = Genv.__NinetyNineRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__NinetyNineRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local Library
do
local ref = "main"
local resolved, shaOrError = pcall(function()
    local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main"))
    return commit.sha
end)
if resolved and shaOrError then
    ref = shaOrError
else
    warn("[Ui3] could not resolve the latest commit, falling back to main: " .. tostring(shaOrError))
end
Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
local Options = Library.Options
if not alive() then
    return
end

local Settings = {
    -- combat
    AutoChop = false, ChopRange = 40, ShowChopRange = false, ChopColor = Color3.fromRGB(120, 220, 120),
    ChopTypes = { Tree = true }, ChopPerSwing = 3,
    KillAura = false, AuraRange = 30, ShowAuraRange = false, AuraColor = Color3.fromRGB(255, 90, 90),
    AuraKinds = { Hostile = true, ["Can attack"] = true }, AuraPerSwing = 3, AuraPriority = "Chasing me first",
    AutoEquip = true, HitFrom = "Your position", ExtraDelay = 0, OneTool = true,
    -- tree farm
    FarmTrees = false, FarmRadius = 250, FarmAround = "Camp fire", FarmNight = "Wait at camp",
    -- movement
    Speed = false, SpeedValue = 32, SpeedMethod = "WalkSpeed",
    Jump = false, JumpValue = 75, InfJump = false,
    Fly = false, FlySpeed = 60, Noclip = false, AntiAfk = true,
    TpMethod = "Tween", TpSpeed = 150, TpGround = true,
    -- visuals
    KidDots = false, KidLabels = true, KidColor = Color3.fromRGB(255, 220, 80),
    EspMobs = false, EspKids = false, EspPlayers = false, EspChests = false, EspItems = false,
    EspItemKinds = { Fuel = true, Food = true, Heals = true, Scrap = true, Gems = true, Ammo = true, Gear = true, Seeds = true, Currency = true },
    EspHighlight = true, EspDistance = 400, EspShowHealth = true,
    PlayerColor = Color3.fromRGB(120, 180, 255), ChestColor = Color3.fromRGB(255, 200, 90),
    ItemColor = Color3.fromRGB(200, 200, 200),
    Fullbright = false, NoFog = false, AlwaysDay = false, FovOn = false, Fov = 80,
    -- bring
    BringKinds = { Fuel = true }, BringNames = {}, BringByName = false, BringExclude = {},
    BringDest = "You", BringMode = "Fast", BringPerFrame = 10, BringHold = 100,
    BringMax = 100, BringRange = 2000, BringSkipNear = true, SavedSpot = nil,
    AutoBring = false, AutoBringEvery = 10,
    -- survival
    AutoEat = false, EatBelow = 120, EatBring = true,
    AutoHeal = false, HealBelow = 50, HealBring = true, ConsumeRange = 15,
    KeepFireFed = false, FireBelow = 40, KeepScrapping = false,
    NightCamp = false, Escape = false, EscapeBelow = 25,
    -- explore
    AutoChests = false, AutoBagKids = false, AutoDropKids = false,
    AutoCoins = false, CoinRange = 20, InstantPrompts = false,
    ReturnAfterRun = true,
}

local MobColors = {
    Hostile = Color3.fromRGB(255, 70, 70),
    ["Can attack"] = Color3.fromRGB(255, 160, 60),
    Passive = Color3.fromRGB(110, 220, 110),
    Pet = Color3.fromRGB(110, 170, 255),
    Kid = Color3.fromRGB(255, 220, 80),
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

local function getHui()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    return (ok and hui) or game:GetService("CoreGui")
end

local VisualGui = Instance.new("ScreenGui")
VisualGui.Name = "NinetyNineVisuals"
VisualGui.IgnoreGuiInset = true
VisualGui.ResetOnSpawn = false
VisualGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(VisualGui)
    end
end)
if not pcall(function()
    VisualGui.Parent = getHui()
end) then
    VisualGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function character()
    return LocalPlayer.Character
end
local function rootPart()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function healthPercent()
    local hum = humanoid()
    if not hum then
        return 100
    end
    return hum.Health / math.max(hum.MaxHealth, 1) * 100
end
local function pivotPos(model)
    if not model or not model.Parent then
        return nil
    end
    if model:IsA("BasePart") then
        return model.Position
    end
    local ok, cf = pcall(model.GetPivot, model)
    return ok and cf.Position or nil
end
local function distanceTo(pos)
    local hrp = rootPart()
    if not hrp or not pos then
        return math.huge
    end
    return (hrp.Position - pos).Magnitude
end
local function anyPart(model)
    if model:IsA("BasePart") then
        return model
    end
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Main")
        or model:FindFirstChildWhichIsA("BasePart", true)
end
local function spaced(text)
    return (tostring(text):gsub("(%l)(%u)", "%1 %2"))
end
local function cleanName(name)
    return (tostring(name):gsub("%[%d+%]$", ""):gsub("%d+$", ""))
end
local function clock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end
local function byDistance(a, b)
    return a.d < b.d
end
local function notify(title, text, time)
    pcall(Library.Notify, Library, { Title = title, Description = text, Time = time or 3 })
end

local Remotes = ReplicatedStorage:WaitForChild("RemoteEvents", 15)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end

local function mapFolder(name)
    local map = Workspace:FindFirstChild("Map")
    return map and map:FindFirstChild(name)
end
local function charactersFolder()
    return Workspace:FindFirstChild("Characters")
end
local function itemsFolder()
    return Workspace:FindFirstChild("Items")
end
local function campPart(name)
    local camp = mapFolder("Campground")
    return camp and camp:FindFirstChild(name)
end
local function campPos()
    return pivotPos(campPart("MainFire"))
end
local function isNight()
    return Workspace:GetAttribute("State") == "Night"
end

-- Things that shouldn't wait on each other run on their own thread, guarded so
-- one error never kills the loop.
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[99 Nights] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end

--// Tools \\--
local function inventory()
    return LocalPlayer:FindFirstChild("Inventory")
end

local function inventoryItems()
    local inv = inventory()
    return inv and inv:GetChildren() or {}
end

local function equippedName()
    local c = character()
    return c and c:GetAttribute("Equipped")
end

local function canChopWith(tool, target)
    local toolName = tool:GetAttribute("ToolName")
    if not toolName or not tool:GetAttribute("WeaponResourceDamage") then
        return false
    end
    if target:GetAttribute("AllowTool_" .. toolName) ~= true then
        return false
    end
    local need = target:GetAttribute("ToolTier")
    return not need or (tool:GetAttribute("ToolTier") or 1) >= need
end

local function canChopAtAll(target)
    for _, item in inventoryItems() do
        if canChopWith(item, target) then
            return true
        end
    end
    return false
end

local RANGED = { Firearm = true, ThrownWeapon = true }
local function isMelee(tool)
    return tool:GetAttribute("WeaponDamage") ~= nil and not RANGED[tool:GetAttribute("ToolName") or ""]
end

-- Best melee weapon in the inventory by WeaponDamage. Ties go to the one in hand.
local function bestWeapon()
    local held = equippedName()
    local best, bestDamage
    for _, item in inventoryItems() do
        if isMelee(item) then
            local damage = item:GetAttribute("WeaponDamage") or 0
            if not bestDamage or damage > bestDamage or (damage == bestDamage and item.Name == held) then
                best, bestDamage = item, damage
            end
        end
    end
    return best
end

-- The axe that can break the most of `trees`, then the one that hits them hardest.
-- Returns the axe and the trees it can break.
local function bestAxe(trees)
    local held = equippedName()
    local best, bestList, bestCount, bestDamage
    for _, item in inventoryItems() do
        if item:GetAttribute("WeaponResourceDamage") and item:GetAttribute("ToolName") then
            local list = {}
            for _, entry in trees do
                if canChopWith(item, entry.model) then
                    table.insert(list, entry)
                end
            end
            local damage = item:GetAttribute("WeaponResourceDamage") or 0
            local better = not bestCount
                or #list > bestCount
                or (#list == bestCount and damage > bestDamage)
                or (#list == bestCount and damage == bestDamage and item.Name == held)
            if better then
                best, bestList, bestCount, bestDamage = item, list, #list, damage
            end
        end
    end
    return best, bestList or {}
end

local lastEquip = 0
-- True when `tool` is already in hand. Otherwise asks the server to equip it
-- (when auto equip is on) and the swing waits for the next tick.
local function readyTool(tool)
    if equippedName() == tool.Name then
        return true
    end
    if not Settings.AutoEquip then
        return true
    end
    if os.clock() - lastEquip > 0.75 then
        lastEquip = os.clock()
        local r = remote("EquipItemHandle")
        if r then
            r:FireServer("FireAllClients", tool)
        end
    end
    return false
end

local hitCounter = 0
local function nextHitId()
    hitCounter += 1
    return (500000 + hitCounter) .. "_" .. math.abs(LocalPlayer.UserId)
end

local function sendHit(target, tool, killing)
    local r = remote("ToolDamageObject")
    local hrp = rootPart()
    if not r or not hrp then
        return
    end
    local origin = hrp.CFrame
    if Settings.HitFrom == "Near target" then
        local pos = pivotPos(target)
        if pos then
            local away = hrp.Position - pos
            away = Vector3.new(away.X, 0, away.Z)
            away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
            local from = pos + away * 4 + Vector3.new(0, 2, 0)
            origin = CFrame.lookAt(from, Vector3.new(pos.X, from.Y, pos.Z))
        end
    end
    task.spawn(function()
        pcall(r.InvokeServer, r, target, tool, nextHitId(), origin, killing)
    end)
end

--// Resources (anything choppable) \\--
-- Trees don't move, so each one's position is read once and filed in a grid of
-- 64-stud cells. A range lookup then only looks at the cells it overlaps
-- instead of every tree on the map.
local CELL = 64
local Resources = {} -- model -> position
local ResourceGrid = {} -- cell key -> { [model] = true }
local ResourceTypes = {}
local pendingTypes = false

local function cellKey(cx, cz)
    return cx * 100003 + cz
end

local function fileResource(model, pos)
    Resources[model] = pos
    local key = cellKey(pos.X // CELL, pos.Z // CELL)
    local cell = ResourceGrid[key]
    if not cell then
        cell = {}
        ResourceGrid[key] = cell
    end
    cell[model] = true
end

local function dropResource(model)
    local pos = Resources[model]
    if pos then
        Resources[model] = nil
        local cell = ResourceGrid[cellKey(pos.X // CELL, pos.Z // CELL)]
        if cell then
            cell[model] = nil
        end
    end
end

local function considerResource(inst)
    if not inst:IsA("Model") then
        return
    end
    local kind = inst:GetAttribute("Resource")
    if kind == nil or inst:GetAttribute("Health") == nil then
        return
    end
    local pos = pivotPos(inst)
    if not pos then
        return
    end
    fileResource(inst, pos)
    if not ResourceTypes[kind] then
        ResourceTypes[kind] = true
        pendingTypes = true
    end
end

task.spawn(function()
    local map = Workspace:WaitForChild("Map", 30)
    if not map or not alive() then
        return
    end
    bind(map.DescendantAdded, function(inst)
        -- Attributes can land a frame after the model.
        task.defer(considerResource, inst)
    end)
    bind(map.DescendantRemoving, dropResource)
    for i, inst in map:GetDescendants() do
        considerResource(inst)
        if i % 4000 == 0 then
            task.wait()
        end
    end
end)

-- Choppable things of the chosen types within `radius` of `center`, nearest first.
local function resourcesNear(center, radius)
    local list = {}
    local r2 = radius * radius
    for cx = (center.X - radius) // CELL, (center.X + radius) // CELL do
        for cz = (center.Z - radius) // CELL, (center.Z + radius) // CELL do
            local cell = ResourceGrid[cellKey(cx, cz)]
            if cell then
                for model in cell do
                    local pos = Resources[model]
                    if model.Parent == nil then
                        dropResource(model)
                    elseif Settings.ChopTypes[model:GetAttribute("Resource")] and (model:GetAttribute("Health") or 0) > 0 then
                        local delta = pos - center
                        local d2 = delta.X * delta.X + delta.Z * delta.Z
                        if d2 <= r2 then
                            table.insert(list, { model = model, d = math.sqrt(d2 + delta.Y * delta.Y) })
                        end
                    end
                end
            end
        end
    end
    table.sort(list, byDistance)
    return list
end

--// Mobs \\--
-- What a mob is, from what it does (see the header).
local function mobKind(model)
    local npc = model:FindFirstChild("NPC")
    if not npc then
        return nil
    end
    if model:GetAttribute("KidId") or model:GetAttribute("NPCType") == "Lost Child" then
        return "Kid"
    end
    if model:GetAttribute("Dead") or (npc:IsA("Humanoid") and npc.Health <= 0) then
        return "Dead"
    end
    if model:GetAttribute("Tamed") or model:GetAttribute("CurrentTamingState") == "Tamed" or model:GetAttribute("State") == "FollowOwner" then
        return "Pet"
    end
    if model:GetAttribute("NotAttackable") or model:GetAttribute("NotDamageable") then
        return "Immune"
    end
    local chasing = model:GetAttribute("ChasingPlayer")
    local state = model:GetAttribute("State")
    if (chasing and chasing ~= 0) or state == "Chase" or state == "Attack"
        or model:GetAttribute("AttackDamage") or model:GetAttribute("AggroRange") then
        return "Hostile"
    end
    local target = model:FindFirstChild("NPCTarget")
    if target and target:IsA("ObjectValue") and target.Value and Players:GetPlayerFromCharacter(target.Value) then
        return "Hostile"
    end
    if model:GetAttribute("AttackRange") and model:GetAttribute("AttackCooldown") then
        return "Can attack"
    end
    return "Passive"
end

local function mobPos(model)
    local hrp = model:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or pivotPos(model)
end

local function mobHealth(model)
    local npc = model:FindFirstChild("NPC")
    return npc and npc:IsA("Humanoid") and npc.Health or math.huge
end

local function chasingMe(model)
    return model:GetAttribute("ChasingPlayer") == LocalPlayer.UserId
end

--// Auto chop + kill aura, side by side \\--
-- Both share one swing clock (the server sees one tool swing at a time). Each
-- swing hits mobs and trees together when one tool can do both; otherwise the
-- two jobs take turns.
local SwingInfo = { axe = "-", weapon = "-", blocked = 0, blockedTier = nil }
local FarmTarget = nil -- the tree the farm walked to; chopped even past the chop distance
local swingTick
do
local nextSwing = 0
local nextJob = "aura"

local function chopCandidates()
    local hrp = rootPart()
    if not hrp then
        return {}
    end
    local list = resourcesNear(hrp.Position, Settings.ChopRange)
    if FarmTarget and FarmTarget.Parent and Resources[FarmTarget] then
        local seen = false
        for _, entry in list do
            if entry.model == FarmTarget then
                seen = true
                break
            end
        end
        if not seen then
            table.insert(list, 1, { model = FarmTarget, d = (Resources[FarmTarget] - hrp.Position).Magnitude })
        end
    end
    return list
end

local AURA_SORTS = {
    Nearest = function(a, b)
        return a.d < b.d
    end,
    ["Chasing me first"] = function(a, b)
        if a.mine ~= b.mine then
            return a.mine
        end
        return a.d < b.d
    end,
    ["Lowest health"] = function(a, b)
        if a.hp ~= b.hp then
            return a.hp < b.hp
        end
        return a.d < b.d
    end,
}

local function auraTargets()
    local hrp = rootPart()
    local folder = charactersFolder()
    if not hrp or not folder then
        return {}
    end
    local list = {}
    for _, model in folder:GetChildren() do
        if model:IsA("Model") then
            local kind = mobKind(model)
            if kind and Settings.AuraKinds[kind] then
                local pos = mobPos(model)
                local d = pos and (pos - hrp.Position).Magnitude
                if d and d <= Settings.AuraRange then
                    table.insert(list, { model = model, d = d, mine = chasingMe(model), hp = mobHealth(model) })
                end
            end
        end
    end
    table.sort(list, AURA_SORTS[Settings.AuraPriority] or AURA_SORTS.Nearest)
    return list
end

local function hitMobs(list, tool)
    for i = 1, math.min(Settings.AuraPerSwing, #list) do
        sendHit(list[i].model, tool, false)
    end
end

local function hitTrees(list, tool)
    local damage = tool:GetAttribute("WeaponResourceDamage") or 10
    for i = 1, math.min(Settings.ChopPerSwing, #list) do
        local model = list[i].model
        sendHit(model, tool, (model:GetAttribute("Health") or 0) - damage <= 0)
    end
end

function swingTick()
    local chopping = Settings.AutoChop or FarmTarget ~= nil
    if not (chopping or Settings.KillAura) then
        return
    end
    local now = os.clock()
    if now < nextSwing then
        return
    end
    -- Nothing to hit or no tool yet: look again shortly rather than every frame.
    nextSwing = now + 0.15
    local hum = humanoid()
    if not hum or hum.Health <= 0 then
        return
    end

    local mobs = Settings.KillAura and auraTargets() or {}
    local weapon = #mobs > 0 and bestWeapon() or nil
    SwingInfo.weapon = weapon and string.format("%s (%d dmg)", weapon.Name, weapon:GetAttribute("WeaponDamage") or 0)
        or (Settings.KillAura and (#mobs > 0 and "no melee weapon" or "nothing in range") or "-")

    local trees, axe, breakable = {}, nil, {}
    if chopping then
        trees = chopCandidates()
        if #trees > 0 then
            axe, breakable = bestAxe(trees)
        end
        -- Trees in range that no axe you own can break, and the tier they need.
        SwingInfo.blocked = #trees - #breakable
        SwingInfo.blockedTier = nil
        if SwingInfo.blocked > 0 then
            for _, entry in trees do
                local need = entry.model:GetAttribute("ToolTier")
                if need and (not axe or not canChopWith(axe, entry.model)) then
                    SwingInfo.blockedTier = math.max(SwingInfo.blockedTier or 0, need)
                end
            end
        end
        SwingInfo.axe = axe and string.format("%s (tier %d, %d wood dmg)", axe.Name, axe:GetAttribute("ToolTier") or 1, axe:GetAttribute("WeaponResourceDamage") or 0)
            or (#trees > 0 and "no axe in inventory" or "nothing in range")
    end

    local wantAura = weapon ~= nil
    local wantChop = axe ~= nil and #breakable > 0
    if not wantAura and not wantChop then
        return
    end

    local auraTool, chopTool = weapon, axe
    if wantAura and wantChop and auraTool ~= chopTool then
        -- One tool for both when it can: the weapon chops these trees, or the axe
        -- can fight. Saves an equip swap every swing.
        local weaponChops = {}
        for _, entry in breakable do
            if canChopWith(weapon, entry.model) then
                table.insert(weaponChops, entry)
            end
        end
        if #weaponChops > 0 then
            chopTool, breakable = weapon, weaponChops
        elseif Settings.OneTool and isMelee(axe) then
            auraTool = axe
        end
    end

    local function finish(tool)
        nextSwing = now + (tool:GetAttribute("ToolCooldown") or 0.5) + Settings.ExtraDelay / 1000
    end

    if wantAura and wantChop and auraTool == chopTool then
        if readyTool(auraTool) then
            hitMobs(mobs, auraTool)
            hitTrees(breakable, auraTool)
            finish(auraTool)
        end
        return
    end

    -- Different tools: take turns, so neither job starves. A mob chasing you
    -- always gets the swing first.
    local job
    if wantAura and wantChop then
        job = mobs[1].mine and "aura" or nextJob
    else
        job = wantAura and "aura" or "chop"
    end
    local tool = job == "aura" and auraTool or chopTool
    if readyTool(tool) then
        if job == "aura" then
            hitMobs(mobs, tool)
        else
            hitTrees(breakable, tool)
        end
        finish(tool)
        nextJob = job == "aura" and "chop" or "aura"
    end
end
end

--// Range rings \\--
local ChopRing, AuraRing
do
local function makeRing()
    local ring = Instance.new("CylinderHandleAdornment")
    ring.Adornee = Workspace.Terrain
    ring.Height = 0.12
    ring.Transparency = 0.35
    ring.AlwaysOnTop = false
    ring.ZIndex = 1
    ring.Visible = false
    ring.Parent = VisualGui
    return ring
end
ChopRing, AuraRing = makeRing(), makeRing()
end

local function placeRing(ring, show, radius, color, lift)
    local hrp = rootPart()
    local hum = humanoid()
    if not show or radius <= 0 or not hrp then
        ring.Visible = false
        return
    end
    local feet = hrp.Position - Vector3.new(0, (hum and hum.HipHeight or 2) + hrp.Size.Y / 2 - lift, 0)
    ring.Radius = radius
    ring.InnerRadius = math.max(0, radius - 0.45)
    ring.Color3 = color
    ring.CFrame = CFrame.new(feet) * CFrame.Angles(math.rad(90), 0, 0)
    ring.Visible = true
end

--// Movement \\--
local Controls
task.spawn(function()
    pcall(function()
        local module = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
        Controls = require(module):GetControls()
    end)
end)

-- Camera-relative move input from keyboard or the mobile thumbstick.
local function moveInput()
    if Controls then
        local ok, v = pcall(Controls.GetMoveVector, Controls)
        if ok and v then
            return v
        end
    end
    local hum = humanoid()
    if hum and hum.MoveDirection.Magnitude > 0 then
        local cf = Camera.CFrame
        local md = hum.MoveDirection
        local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
        flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, -1)
        return Vector3.new(md:Dot(cf.RightVector), 0, -md:Dot(flat))
    end
    return Vector3.zero
end

local FlyUpHeld, FlyDownHeld = false, false
local FlyObjects = {}

local function stopFly()
    for _, obj in FlyObjects do
        pcall(obj.Destroy, obj)
    end
    table.clear(FlyObjects)
    local hum = humanoid()
    if hum then
        pcall(hum.ChangeState, hum, Enum.HumanoidStateType.Freefall)
    end
end

local function flyStep()
    local hrp = rootPart()
    if not hrp then
        return
    end
    local lv = FlyObjects.Velocity
    if not lv or lv.Parent == nil or FlyObjects.Attachment.Parent ~= hrp then
        stopFly()
        local att = Instance.new("Attachment")
        att.Name = "NNFlyAttachment"
        att.Parent = hrp
        lv = Instance.new("LinearVelocity")
        lv.Name = "NNFly"
        lv.Attachment0 = att
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        lv.MaxForce = math.huge
        lv.Parent = hrp
        local align = Instance.new("AlignOrientation")
        align.Name = "NNFlyAlign"
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        align.Attachment0 = att
        align.RigidityEnabled = true
        align.Parent = hrp
        FlyObjects.Attachment, FlyObjects.Velocity, FlyObjects.Align = att, lv, align
    end

    local cf = Camera.CFrame
    local input = moveInput()
    local dir = cf.RightVector * input.X + cf.LookVector * -input.Z
    local hum = humanoid()
    local up = FlyUpHeld or UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E)
    local down = FlyDownHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q)
    if up then
        dir += Vector3.new(0, 1, 0)
    end
    if down then
        dir -= Vector3.new(0, 1, 0)
    end
    if dir.Magnitude > 1 then
        dir = dir.Unit
    end
    -- Stays under the game's 300 studs/s anti-fling cap.
    lv.VectorVelocity = dir * math.min(Settings.FlySpeed, 280)
    local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    if flat.Magnitude > 0.01 then
        FlyObjects.Align.CFrame = CFrame.lookAt(Vector3.zero, flat)
    end
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Physics)
    end
end

-- On-screen up/down buttons for flying on a phone.
local FlyButtons = Instance.new("Frame")
do
FlyButtons.Name = "FlyButtons"
FlyButtons.BackgroundTransparency = 1
FlyButtons.AnchorPoint = Vector2.new(1, 1)
FlyButtons.Position = UDim2.new(1, -24, 1, -170)
FlyButtons.Size = UDim2.fromOffset(64, 136)
FlyButtons.Visible = false
FlyButtons.Parent = VisualGui

local function flyButton(text, y, onHold)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(64, 64)
    b.Position = UDim2.fromOffset(0, y)
    b.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
    b.BackgroundTransparency = 0.2
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 22
    b.Text = text
    b.AutoButtonColor = true
    b.Parent = FlyButtons
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", b)
    stroke.Color = Color3.fromRGB(255, 151, 227)
    stroke.Transparency = 0.3
    b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            onHold(true)
        end
    end)
    b.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            onHold(false)
        end
    end)
end
flyButton("▲", 0, function(v)
    FlyUpHeld = v
end)
flyButton("▼", 72, function(v)
    FlyDownHeld = v
end)
end

local Saved = {}
local NoclipParts = {}
local Travelling = false -- a tween is moving you; it passes through walls on the way

local function movementStep(dt)
    local hum = humanoid()
    local hrp = rootPart()
    if not hum or not hrp then
        return
    end

    if Settings.Speed then
        if Settings.SpeedMethod == "WalkSpeed" then
            hum.WalkSpeed = Settings.SpeedValue
        elseif not Settings.Fly and hum.MoveDirection.Magnitude > 0 then
            -- CFrame: the game keeps its own walk speed, the rest is added on top.
            local extra = math.max(0, Settings.SpeedValue - hum.WalkSpeed)
            hrp.CFrame += hum.MoveDirection * extra * dt
        end
    end

    if Settings.Jump then
        if Saved.UseJumpPower == nil then
            Saved.UseJumpPower, Saved.JumpPower, Saved.JumpHeight = hum.UseJumpPower, hum.JumpPower, hum.JumpHeight
        end
        hum.UseJumpPower = true
        hum.JumpPower = Settings.JumpValue
    end

    if Settings.Fly then
        flyStep()
    end
    FlyButtons.Visible = Settings.Fly and UserInputService.TouchEnabled
end

local function restoreJump()
    local hum = humanoid()
    if hum and Saved.UseJumpPower ~= nil then
        hum.UseJumpPower = Saved.UseJumpPower
        hum.JumpPower = Saved.JumpPower
        hum.JumpHeight = Saved.JumpHeight
    end
    Saved.UseJumpPower = nil
end

local function restoreNoclip()
    for part in NoclipParts do
        if part.Parent then
            part.CanCollide = true
        end
    end
    table.clear(NoclipParts)
end

bind(RunService.Stepped, function()
    if not alive() or not (Settings.Noclip or Travelling) then
        return
    end
    local c = character()
    if not c then
        return
    end
    for _, part in c:GetDescendants() do
        if part:IsA("BasePart") and part.CanCollide then
            NoclipParts[part] = true
            part.CanCollide = false
        end
    end
end)

bind(UserInputService.JumpRequest, function()
    if not alive() or not Settings.InfJump or Settings.Fly then
        return
    end
    local hum = humanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

bind(LocalPlayer.Idled, function()
    if not alive() or not Settings.AntiAfk then
        return
    end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

--// Travel \\--
-- Far places may not be streamed in yet, so the area is asked for first, then
-- the landing spot is found by casting down onto the ground (through tree tops,
-- mobs and loose items) so you never land in a canopy or under the map.
local tpToken = 0
local TravelOwner = nil
local moveTo
do
local GroundParams = RaycastParams.new()
GroundParams.FilterType = Enum.RaycastFilterType.Exclude

local function streamAround(pos)
    pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, pos, 2)
end

local function groundAt(pos, fromHeight)
    local skip = { character(), charactersFolder(), itemsFolder(), VisualGui }
    local list = {}
    for _, inst in skip do
        if inst then
            table.insert(list, inst)
        end
    end
    local origin = Vector3.new(pos.X, (fromHeight or pos.Y) + 8, pos.Z)
    for _ = 1, 10 do
        GroundParams.FilterDescendantsInstances = list
        local hit = Workspace:Raycast(origin, Vector3.new(0, -600, 0), GroundParams)
        if not hit then
            return nil
        end
        local inst = hit.Instance
        local model = inst:FindFirstAncestorWhichIsA("Model")
        -- Tree tops, leaves and anything you can walk through aren't ground.
        if (model and model:GetAttribute("Resource")) or not inst.CanCollide or inst.Transparency >= 1 then
            table.insert(list, inst)
            origin = hit.Position
        else
            return hit.Position
        end
    end
    return nil
end

-- Where to stand for `pos`: on the ground under it when it can be found.
local function landingSpot(pos, unknownHeight)
    if not Settings.TpGround and not unknownHeight then
        return pos + Vector3.new(0, 4, 0)
    end
    local ground = groundAt(pos, unknownHeight and 400 or nil)
    if ground then
        return ground + Vector3.new(0, 3.5, 0)
    end
    return unknownHeight and Vector3.new(pos.X, 80, pos.Z) or pos + Vector3.new(0, 4, 0)
end

-- Moves you to `pos` and returns once you're there (true) or the move was
-- replaced, cancelled or timed out (false). `opts.unknownHeight`: the point is a
-- map marker with no real height.
function moveTo(pos, opts)
    opts = opts or {}
    local hrp = rootPart()
    if not hrp or not pos then
        return false
    end
    tpToken += 1
    local token = tpToken
    local far = (pos - hrp.Position).Magnitude > 200 or opts.unknownHeight
    if far then
        streamAround(pos)
    end
    local target = landingSpot(pos, opts.unknownHeight)
    local look = hrp.CFrame.Rotation

    if Settings.TpMethod == "Instant" then
        hrp.CFrame = CFrame.new(target) * look
        hrp.AssemblyLinearVelocity = Vector3.zero
        if Travelling then
            Travelling, TravelOwner = false, nil
            if not Settings.Noclip then
                restoreNoclip()
            end
        end
    else
        -- Tween: moved by CFrame with no velocity, so the anti-fling never sees it.
        Travelling, TravelOwner = true, token
        local t0 = os.clock()
        local limit = (target - hrp.Position).Magnitude / math.max(Settings.TpSpeed, 1) + 10
        local arrived = false
        while alive() and token == tpToken and os.clock() - t0 < limit do
            local dt = RunService.Heartbeat:Wait()
            local r = rootPart()
            if not r then
                break
            end
            local delta = target - r.Position
            local d = delta.Magnitude
            if d < 2 then
                r.CFrame = CFrame.new(target) * look
                r.AssemblyLinearVelocity = Vector3.zero
                arrived = true
                break
            end
            local step = math.min(d, Settings.TpSpeed * dt)
            r.CFrame = CFrame.new(r.Position + delta.Unit * step) * look
            r.AssemblyLinearVelocity = Vector3.zero
        end
        if TravelOwner == token then
            Travelling, TravelOwner = false, nil
            if not Settings.Noclip then
                restoreNoclip()
            end
        end
        if not arrived then
            return false
        end
    end

    -- A map marker's real ground streams in after you get there: settle onto it.
    if opts.unknownHeight then
        task.wait(0.5)
        local r = rootPart()
        local ground = r and groundAt(r.Position, 400)
        if r and ground and token == tpToken then
            r.CFrame = CFrame.new(ground + Vector3.new(0, 3.5, 0)) * look
            r.AssemblyLinearVelocity = Vector3.zero
        end
    end
    return token == tpToken
end
end

local function teleportTo(pos, opts)
    if not rootPart() or not pos then
        notify("Teleport", "Nowhere to go (not loaded?)")
        return
    end
    task.spawn(moveTo, pos, opts)
end

-- A spot `gap` studs from `pos`, on your side of it.
local function besideOf(pos, gap)
    local hrp = rootPart()
    local away = hrp and (hrp.Position - pos) or Vector3.new(0, 0, 1)
    away = Vector3.new(away.X, 0, away.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    return pos + away * gap
end

--// Jobs \\--
-- One automation at a time (tree farm, kid rescue, chest run, going to camp).
-- Starting one stops the one before; each checks `still()` between steps.
local Job = { name = nil, token = 0, status = "Idle" }

local function setStatus(text)
    Job.status = text
end

local function stopJob(reason)
    Job.token += 1
    tpToken += 1
    Job.name = nil
    FarmTarget = nil
    setStatus(reason or "Idle")
end

local function startJob(name, fn)
    stopJob()
    local token = Job.token
    Job.name = name
    local function still()
        return alive() and Job.token == token
    end
    task.spawn(function()
        local ok, err = pcall(fn, still)
        if not ok then
            warn("[99 Nights] " .. name .. ": " .. tostring(err))
        end
        if Job.token == token then
            Job.name = nil
            FarmTarget = nil
            if not ok then
                setStatus(name .. " stopped: " .. tostring(err))
            end
        end
    end)
end

-- Waits up to `seconds`, returning early (true) once `done()` holds.
local function waitFor(seconds, done, still)
    local t0 = os.clock()
    while os.clock() - t0 < seconds do
        if still and not still() then
            return false
        end
        if done() then
            return true
        end
        task.wait(0.15)
    end
    return done()
end

--// Places \\--
-- Fixed places: camp pieces and every cave point the server publishes.
local function placeTargets()
    local list, order = {}, {}
    local function add(label, getPos)
        if not list[label] then
            list[label] = getPos
            table.insert(order, label)
        end
    end
    local camp = mapFolder("Campground")
    if camp then
        for _, entry in {
            { "Camp fire", "MainFire" },
            { "Crafting bench", "CraftingBench" },
            { "Scrapper", "Scrapper" },
            { "Notice board", "NoticeBoard" },
        } do
            local model = camp:FindFirstChild(entry[2])
            if model then
                add(entry[1], function()
                    local pos = pivotPos(model)
                    return pos and besideOf(pos, 8)
                end)
            end
        end
    end
    local caves = {}
    for name, value in Workspace:GetAttributes() do
        local kind, n = name:match("^CaveTeleport_(%a+)(%d+)$")
        if kind and typeof(value) == "CFrame" then
            table.insert(caves, { kind = kind, n = tonumber(n), cf = value })
        end
    end
    table.sort(caves, function(a, b)
        if a.n == b.n then
            return a.kind > b.kind
        end
        return a.n < b.n
    end)
    for _, cave in caves do
        local label = cave.kind == "Exit" and ("Cave " .. cave.n .. " (outside)") or ("Cave " .. cave.n .. " (inside)")
        add(label, function()
            return cave.cf.Position
        end)
    end
    return list, order
end

local function isChest(model)
    return model:GetAttribute("Interaction") == "ItemChest"
end

local function chestOpened(chest)
    return chest:GetAttribute("LocalOpened") or chest:GetAttribute(math.abs(LocalPlayer.UserId) .. "Opened")
end

-- Every chest, numbered once so a label keeps pointing at the same chest.
local ChestIds, nextChestId = setmetatable({}, { __mode = "k" }), 0
local function chestTargets()
    local items = itemsFolder()
    local list, order = {}, {}
    if not items then
        return list, order
    end
    local found = {}
    for _, model in items:GetChildren() do
        if isChest(model) then
            if not ChestIds[model] then
                nextChestId += 1
                ChestIds[model] = nextChestId
            end
            local label = (model:GetAttribute("ChestName") or cleanName(model.Name)) .. " #" .. ChestIds[model]
            if model:GetAttribute("Locked") then
                label ..= " (locked)"
            elseif chestOpened(model) then
                label ..= " (opened)"
            end
            table.insert(found, { label = label, model = model, d = distanceTo(pivotPos(model)) })
        end
    end
    table.sort(found, byDistance)
    for _, entry in found do
        list[entry.label] = entry.model
        table.insert(order, entry.label)
    end
    return list, order
end

local INTERESTING_LANDMARK = { Landmark = true, Trap = true }
local function landmarkTargets(everything)
    local folder = mapFolder("Landmarks")
    local list, order, counts = {}, {}, {}
    if not folder then
        return list, order
    end
    local found = {}
    for _, model in folder:GetChildren() do
        local full = model:GetAttribute("FullLandmarkName")
        if everything or full or INTERESTING_LANDMARK[model:GetAttribute("PingId") or ""] then
            local base = full or cleanName(model.Name)
            if model:GetAttribute("KidId") then
                base ..= " (" .. spaced(model:GetAttribute("KidId")) .. ")"
            end
            counts[base] = (counts[base] or 0) + 1
            table.insert(found, { base = base, model = model, d = distanceTo(pivotPos(model)) })
        end
    end
    table.sort(found, function(a, b)
        if a.base == b.base then
            return a.d < b.d
        end
        return a.base < b.base
    end)
    local seen = {}
    for _, entry in found do
        local label = entry.base
        if counts[entry.base] > 1 then
            seen[entry.base] = (seen[entry.base] or 0) + 1
            label ..= " " .. seen[entry.base]
        end
        list[label] = entry.model
        table.insert(order, label)
    end
    return list, order
end

--// Kids \\--
local function liveKid(kidId)
    local folder = charactersFolder()
    if not folder then
        return nil
    end
    for _, model in folder:GetChildren() do
        if model:GetAttribute("KidId") == kidId and model:GetAttribute("Lost") ~= false then
            return model
        end
    end
    return nil
end

-- Kids: the live model when it's streamed in, the server's map point otherwise.
local function kidPositions()
    local kids = {}
    local missing = mapFolder("MissingKids")
    if missing then
        for kidId, value in missing:GetAttributes() do
            if typeof(value) == "Vector3" then
                kids[kidId] = { pos = value, live = false }
            end
        end
    end
    local folder = charactersFolder()
    if folder then
        for _, model in folder:GetChildren() do
            local kidId = model:GetAttribute("KidId")
            if kidId and model:GetAttribute("Lost") ~= false and (kids[kidId] or not missing) then
                local pos = mobPos(model)
                if pos then
                    kids[kidId] = { pos = pos, live = true, name = model:GetAttribute("PingName"), model = model }
                end
            end
        end
    end
    return kids
end

local function missingCount()
    local n = 0
    local folder = mapFolder("MissingKids")
    if folder then
        for _, value in folder:GetAttributes() do
            if typeof(value) == "Vector3" then
                n += 1
            end
        end
    end
    return n
end

--// Kid dots (screen markers, work on anything the camera can project) \\--
local updateKidDots
do
local KidMarkers = {}
local function kidMarker(kidId)
    local m = KidMarkers[kidId]
    if m then
        return m
    end
    local dot = Instance.new("Frame")
    dot.Name = "Kid_" .. kidId
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.Size = UDim2.fromOffset(12, 12)
    dot.BorderSizePixel = 0
    dot.Parent = VisualGui
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", dot)
    stroke.Color = Color3.new(0, 0, 0)
    stroke.Thickness = 1.5
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 1, 3)
    label.Size = UDim2.fromOffset(160, 16)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 12
    label.TextStrokeTransparency = 0.4
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Parent = dot
    m = { dot = dot, label = label }
    KidMarkers[kidId] = m
    return m
end

function updateKidDots()
    local hrp = rootPart()
    local kids = (Settings.KidDots and hrp) and kidPositions() or {}
    for kidId, m in KidMarkers do
        if not kids[kidId] then
            m.dot.Visible = false
        end
    end
    if not Settings.KidDots or not hrp then
        return
    end
    local view = Camera.ViewportSize
    for kidId, info in kids do
        local m = kidMarker(kidId)
        local pos = info.pos
        if not info.live and pos.Y == 0 then
            pos = Vector3.new(pos.X, hrp.Position.Y, pos.Z)
        end
        local screen, onScreen = Camera:WorldToViewportPoint(pos)
        local x, y = screen.X, screen.Y
        if not onScreen then
            -- Off screen or behind: pin to the edge in the kid's direction.
            local rel = Camera.CFrame:PointToObjectSpace(pos)
            local dir = Vector2.new(rel.X, -rel.Y)
            if dir.Magnitude < 1e-3 then
                dir = Vector2.new(0, 1)
            end
            dir = dir.Unit
            local half = view / 2 - Vector2.new(40, 40)
            local scale = math.min(half.X / math.max(math.abs(dir.X), 1e-3), half.Y / math.max(math.abs(dir.Y), 1e-3))
            local p = view / 2 + dir * scale
            x, y = p.X, p.Y
        end
        m.dot.Position = UDim2.fromOffset(x, y)
        m.dot.BackgroundColor3 = Settings.KidColor
        m.dot.BackgroundTransparency = info.live and 0 or 0.15
        m.label.Visible = Settings.KidLabels
        m.label.Text = string.format("%s · %dm%s", info.name or spaced(kidId), math.floor((pos - hrp.Position).Magnitude), info.live and "" or " (map)")
        m.dot.Visible = true
    end
end
end

--// Items: types by what they do, so new items sort themselves \\--
local ITEM_KINDS = { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Other" }
local HEAL_NAMES = { Bandage = true, MedKit = true }

local function mineOrFree(model)
    local owner = model:GetAttribute("Owner")
    return owner == nil or owner == LocalPlayer.UserId
end

-- nil for things that aren't loose items (chests, coins, diamonds).
local function itemKind(model)
    local interaction = model:GetAttribute("Interaction")
    if interaction == nil or interaction == "ItemChest" then
        return nil
    end
    if interaction == "Currency" then
        return "Currency"
    end
    if model:GetAttribute("RestoreHealth") or HEAL_NAMES[cleanName(model.Name)] then
        return "Heals"
    elseif model:HasTag("Gem") or model:HasTag("GreenGem") then
        return "Gems"
    elseif model:GetAttribute("AmmoType") or model:GetAttribute("RifleAmmo") or model:GetAttribute("RevolverAmmo")
        or model:GetAttribute("ShotgunAmmo") then
        return "Ammo"
    elseif model:GetAttribute("RestoreHunger") then
        return "Food"
    elseif interaction == "Tool" or interaction == "Armour" then
        return "Gear"
    elseif model:HasTag("Plantable") or model:HasTag("SeedBox") or model:HasTag("Acorn") then
        return "Seeds"
    elseif model:GetAttribute("BurnFuel") then
        return "Fuel"
    elseif model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded") then
        return "Scrap"
    end
    return "Other"
end

local function isFood(model)
    local bunny = LocalPlayer:GetAttribute("Class") == "Bunny"
    return model:GetAttribute("RestoreHunger") ~= nil and not (bunny and model:GetAttribute("HasMeat"))
end

local function isHeal(model)
    return model:GetAttribute("RestoreHealth") ~= nil or HEAL_NAMES[cleanName(model.Name)] == true
end

-- Names of the loose items on the map, for the pickers.
local function itemNames()
    local items = itemsFolder()
    local seen, order = {}, {}
    if not items then
        return order
    end
    for _, model in items:GetChildren() do
        local kind = itemKind(model)
        if kind and kind ~= "Currency" then
            local name = cleanName(model.Name)
            if not seen[name] then
                seen[name] = true
                table.insert(order, name)
            end
        end
    end
    table.sort(order)
    return order
end

local function nearestItemNamed(name)
    local items = itemsFolder()
    local best, bestD
    if not items then
        return nil
    end
    for _, model in items:GetChildren() do
        if cleanName(model.Name) == name and not isChest(model) then
            local d = distanceTo(pivotPos(model))
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best
end

--// Bring \\--
-- The game's own drag: RequestStartDraggingItem hands you the item, you move
-- it, StopDraggingItem gives it back. Fast mode starts, moves and releases
-- many items per frame and moves each again right before release, so it lands
-- even when the hand-over is a frame late. Safe mode does one at a time and
-- waits for the hand-over.
local BRING_DESTS = { "You", "Camp fire", "Crafting bench", "Saved spot" }
local Bring = { token = 0, done = 0, total = 0, running = false }

local function bringTarget(dest)
    local hrp = rootPart()
    if dest == "Camp fire" then
        local fire = campPart("MainFire")
        local center = fire and (fire:FindFirstChild("Center") or fire:FindFirstChild("InnerTouchZone"))
        local pos = center and (center:IsA("BasePart") and center.Position or pivotPos(center)) or pivotPos(fire)
        return pos and CFrame.new(pos + Vector3.new(0, 4, 0))
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local zone = bench and bench:FindFirstChild("TouchZone")
        local pos = zone and zone.Position or pivotPos(bench)
        return pos and CFrame.new(pos + Vector3.new(0, 3, 0))
    elseif dest == "Saved spot" then
        return Settings.SavedSpot
    end
    return hrp and (hrp.CFrame * CFrame.new(0, 1, -7))
end

-- Spread items in a grid so a big pile doesn't explode. The fire and bench
-- want them close together so they land in the touch zone.
local function slotOffset(i, dest)
    local spacing = (dest == "Camp fire" or dest == "Crafting bench") and 0.8 or 1.8
    local r = (i - 1) % 36
    local layer = (i - 1) // 36
    return Vector3.new((r % 6 - 2.5) * spacing, layer * spacing, (r // 6 - 2.5) * spacing)
end

-- What to bring: { kinds = {}, names = {}, byName = bool, filter = fn, exclude = {} }
local function bringList(what, dest, limit)
    local items = itemsFolder()
    local hrp = rootPart()
    local target = bringTarget(dest)
    if not items or not hrp or not target then
        return {}
    end
    local exclude = what.exclude or {}
    local list = {}
    for _, model in items:GetChildren() do
        local kind = itemKind(model)
        local name = cleanName(model.Name)
        local wanted
        if what.filter then
            wanted = kind ~= nil and what.filter(model)
        elseif what.byName then
            wanted = what.names[name] == true
        else
            wanted = kind ~= nil and kind ~= "Currency" and what.kinds[kind] == true and not exclude[name]
        end
        if wanted and mineOrFree(model) and anyPart(model) then
            local pos = pivotPos(model)
            local d = pos and (pos - hrp.Position).Magnitude
            local atTarget = pos and (pos - target.Position).Magnitude < 12
            if d and d <= Settings.BringRange and not (Settings.BringSkipNear and atTarget) then
                table.insert(list, { model = model, d = d })
            end
        end
    end
    table.sort(list, byDistance)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i].model
    end
    return out
end

local function placeItem(model, cf)
    pcall(function()
        model:PivotTo(cf)
        local part = model.PrimaryPart or anyPart(model)
        if part then
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end)
end

-- What the fire and the bench do with an item that arrives, through the same
-- remotes their touch zones use.
local function arrive(model, dest)
    if dest == "Camp fire" then
        local fire = campPart("MainFire")
        local r = remote("RequestBurnItem")
        if fire and r and model:GetAttribute("BurnFuel") and (model:GetAttribute("Wet") or 0) < 1 then
            r:FireServer(fire, model)
        end
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local r = remote("RequestScrapItem")
        if bench and r and (model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded")) then
            task.spawn(pcall, r.InvokeServer, r, bench, model)
        end
    end
end

local function isOwner(part)
    if typeof(isnetworkowner) ~= "function" or not part then
        return nil
    end
    local ok, result = pcall(isnetworkowner, part)
    return ok and result or false
end

local function currentBringWhat()
    return {
        kinds = Settings.BringKinds,
        names = Settings.BringNames,
        byName = Settings.BringByName,
        exclude = Settings.BringExclude,
    }
end

-- Starts a bring and returns how many items it's moving.
local function runBring(what, dest, limit)
    Bring.token += 1
    local token = Bring.token
    local list = bringList(what, dest, limit or Settings.BringMax)
    local start, stop = remote("RequestStartDraggingItem"), remote("StopDraggingItem")
    Bring.total, Bring.done = #list, 0
    if #list == 0 or not start or not stop then
        Bring.running = false
        return 0
    end
    Bring.running = true
    task.spawn(function()
        local base = bringTarget(dest)
        if not base then
            Bring.running = false
            return
        end
        if Settings.BringMode == "Fast" then
            local i = 0
            while i < #list and alive() and token == Bring.token do
                for _ = 1, Settings.BringPerFrame do
                    i += 1
                    local model = list[i]
                    if not model then
                        break
                    end
                    if model.Parent then
                        local cf = CFrame.new(base.Position + slotOffset(i, dest))
                        start:FireServer(model)
                        placeItem(model, cf)
                        task.delay(Settings.BringHold / 1000, function()
                            if model.Parent then
                                placeItem(model, cf)
                                stop:FireServer(model)
                                arrive(model, dest)
                            end
                            Bring.done += 1
                        end)
                    else
                        Bring.done += 1
                    end
                end
                RunService.Heartbeat:Wait()
            end
        else
            for i, model in list do
                if token ~= Bring.token or not alive() then
                    break
                end
                if model.Parent then
                    local cf = CFrame.new(base.Position + slotOffset(i, dest))
                    local part = model.PrimaryPart or anyPart(model)
                    start:FireServer(model)
                    local t0 = os.clock()
                    if isOwner(part) ~= nil then
                        repeat
                            RunService.Heartbeat:Wait()
                        until isOwner(part) or os.clock() - t0 > 0.35
                    else
                        task.wait(Settings.BringHold / 1000)
                    end
                    placeItem(model, cf)
                    RunService.Heartbeat:Wait()
                    placeItem(model, cf)
                    stop:FireServer(model)
                    arrive(model, dest)
                end
                Bring.done = i
            end
        end
        task.wait(Settings.BringHold / 1000 + 0.1)
        if token == Bring.token then
            Bring.running = false
        end
    end)
    return #list
end

--// Loot, kids, coins, eating, healing \\--
local Tried = setmetatable({}, { __mode = "k" })
local function tryOnce(model, every)
    local last = Tried[model]
    if last and os.clock() - last < (every or 4) then
        return false
    end
    Tried[model] = os.clock()
    return true
end

local function chestPrompt(chest)
    for _, inst in chest:GetDescendants() do
        if inst:IsA("ProximityPrompt") then
            return inst
        end
    end
    return nil
end

local function openChest(chest)
    local prompt = chestPrompt(chest)
    if prompt and prompt.Enabled and typeof(fireproximityprompt) == "function" then
        -- Some executors honour the hold time, so drop it for the call.
        local hold = prompt.HoldDuration
        prompt.HoldDuration = 0
        pcall(fireproximityprompt, prompt)
        task.delay(0.25, function()
            if prompt.Parent and not Settings.InstantPrompts then
                prompt.HoldDuration = hold
            end
        end)
        return true
    end
    local r = remote("RequestOpenItemChest")
    if r then
        r:FireServer(chest)
        chest:SetAttribute("LocalOpened", true)
        return true
    end
    return false
end

local function openableChest(chest)
    return isChest(chest) and chest.Parent ~= nil and not chest:GetAttribute("Locked") and not chestOpened(chest)
end

local function openChestsInRange()
    local items = itemsFolder()
    local hrp = rootPart()
    if not items or not hrp then
        return
    end
    for _, chest in items:GetChildren() do
        if openableChest(chest) then
            local prompt = chestPrompt(chest)
            local pos = pivotPos(chest)
            -- Opens exactly where the chest's own prompt would let you.
            local range = prompt and prompt.MaxActivationDistance or 10
            if pos and (pos - hrp.Position).Magnitude <= range and tryOnce(chest, 5) then
                openChest(chest)
            end
        end
    end
end

local function itemBag()
    for _, item in inventoryItems() do
        if item:HasTag("ItemBag") then
            return item
        end
    end
    return nil
end

local function kidsInBag()
    local bagFolder = LocalPlayer:FindFirstChild("ItemBag")
    local n = 0
    if bagFolder then
        for _, item in bagFolder:GetChildren() do
            if item:GetAttribute("KidId") then
                n += 1
            end
        end
    end
    return n
end

local function canBag(model)
    return model:GetAttribute("CanBeBagged") and model:GetAttribute("Interaction") == "CanBeBagged"
end

local function bagKid(model)
    local bag, r = itemBag(), remote("RequestBagStoreItem")
    if bag and r then
        task.spawn(pcall, r.InvokeServer, r, bag, model)
        return true
    end
    return false
end

-- Kids go in the sack from the game's interaction range (15 studs).
local function bagKidsInRange()
    local folder = charactersFolder()
    local hrp = rootPart()
    if not folder or not hrp or not itemBag() then
        return
    end
    for _, model in folder:GetChildren() do
        if canBag(model) then
            local pos = mobPos(model)
            if pos and (pos - hrp.Position).Magnitude <= 15 and tryOnce(model, 3) then
                bagKid(model)
            end
        end
    end
end

-- Kids in the sack come out at camp.
local function dropKidsAtCamp(force)
    local bagFolder = LocalPlayer:FindFirstChild("ItemBag")
    local bag = itemBag()
    local r = remote("RequestBagDropItem")
    if not bagFolder or not bag or not r or distanceTo(campPos()) > 30 then
        return
    end
    for _, item in bagFolder:GetChildren() do
        if item:GetAttribute("KidId") and (force or tryOnce(item, 3)) then
            r:FireServer(bag, item, #bagFolder:GetChildren() <= 1)
        end
    end
end

local function collectCurrency()
    local items = itemsFolder()
    local hrp = rootPart()
    if not items or not hrp then
        return
    end
    local coins, diamonds = remote("RequestCollectCoints"), remote("RequestTakeDiamonds")
    for _, model in items:GetChildren() do
        if model:GetAttribute("Interaction") == "Currency" and not model:GetAttribute("Destroyed") then
            local pos = pivotPos(model)
            if pos and (pos - hrp.Position).Magnitude <= Settings.CoinRange and tryOnce(model, 3) then
                if model:GetAttribute("Diamonds") and diamonds then
                    diamonds:FireServer(model)
                elseif model:HasTag("Coins") and coins then
                    task.spawn(pcall, coins.InvokeServer, coins, model)
                end
            end
        end
    end
end

-- Eats or heals with the nearest matching item in reach.
local function consumeNearest(filter)
    local items = itemsFolder()
    local hrp = rootPart()
    local r = remote("RequestConsumeItem")
    if not items or not hrp or not r then
        return false
    end
    local best, bestD
    for _, model in items:GetChildren() do
        if filter(model) and mineOrFree(model) then
            local pos = pivotPos(model)
            local d = pos and (pos - hrp.Position).Magnitude
            if d and d <= Settings.ConsumeRange and (not bestD or d < bestD) then
                best, bestD = model, d
            end
        end
    end
    if best and tryOnce(best, 3) then
        task.spawn(pcall, r.InvokeServer, r, best)
        return true
    end
    return false
end

-- Nothing in reach: pull the nearest one over and use it on the next pass.
local lastFetch = 0
local function consumeOrFetch(filter, fetch)
    if consumeNearest(filter) then
        return true
    end
    if fetch and not Bring.running and os.clock() - lastFetch > 3 then
        lastFetch = os.clock()
        runBring({ filter = filter }, "You", 1)
    end
    return false
end

local lastEat, lastHeal, lastFeed, lastScrap = 0, 0, 0, 0
local function survivalTick()
    if Settings.AutoChests then
        openChestsInRange()
    end
    if Settings.AutoBagKids then
        bagKidsInRange()
    end
    if Settings.AutoDropKids then
        dropKidsAtCamp(false)
    end
    if Settings.AutoCoins then
        collectCurrency()
    end
    local now = os.clock()
    if Settings.AutoEat and now - lastEat > 1.5 and (LocalPlayer:GetAttribute("Hunger") or 200) < Settings.EatBelow then
        if consumeOrFetch(isFood, Settings.EatBring) then
            lastEat = now
        end
    end
    local hum = humanoid()
    if Settings.AutoHeal and hum and hum.Health > 0 and now - lastHeal > 1.5 and healthPercent() < Settings.HealBelow then
        if consumeOrFetch(isHeal, Settings.HealBring) then
            lastHeal = now
        end
    end
    if Settings.KeepFireFed and now - lastFeed > 8 and not Bring.running then
        local fire = campPart("MainFire")
        local fuel = fire and fire:GetAttribute("FuelRemaining")
        if fuel and fuel < Settings.FireBelow then
            lastFeed = now
            runBring({ kinds = { Fuel = true }, exclude = Settings.BringExclude }, "Camp fire", 6)
        end
    end
    if Settings.KeepScrapping and now - lastScrap > 20 and not Bring.running then
        lastScrap = now
        runBring({ kinds = { Scrap = true }, exclude = Settings.BringExclude }, "Crafting bench", 20)
    end
end

-- Instant prompts: every hold-to-interact prompt fires on press.
local setInstantPrompts
do
local PromptHolds = setmetatable({}, { __mode = "k" })
local function instantPrompt(prompt)
    if prompt:IsA("ProximityPrompt") and prompt.HoldDuration > 0 then
        if PromptHolds[prompt] == nil then
            PromptHolds[prompt] = prompt.HoldDuration
        end
        prompt.HoldDuration = 0
    end
end
function setInstantPrompts(on)
    if on then
        for _, inst in Workspace:GetDescendants() do
            instantPrompt(inst)
        end
    else
        for prompt, hold in PromptHolds do
            if prompt.Parent then
                prompt.HoldDuration = hold
            end
        end
        table.clear(PromptHolds)
    end
end
bind(Workspace.DescendantAdded, function(inst)
    if Settings.InstantPrompts and inst:IsA("ProximityPrompt") then
        task.defer(instantPrompt, inst)
    end
end)
end

--// Automations \\--
local logEvent -- set once the dashboard exists

local function goToCamp(still)
    local pos = campPos()
    if not pos then
        setStatus("No camp fire found")
        return false
    end
    setStatus("Going to camp")
    return moveTo(besideOf(pos, 10)) and (not still or still())
end

-- Tree farm: walk to the nearest tree an axe you own can break, stay until
-- it falls (the swing loop chops it), then the next one.
local function farmCenter(origin)
    if Settings.FarmAround == "Camp fire" then
        return campPos() or origin
    end
    return origin
end

-- A tree that took no damage last time is skipped for a while.
local FarmSkip = setmetatable({}, { __mode = "k" })

-- The tree nearest to you among those within the farm radius of `center`.
local function nextFarmTree(center)
    local hrp = rootPart()
    local best, bestD
    for _, entry in resourcesNear(center, Settings.FarmRadius) do
        local model = entry.model
        local skipUntil = FarmSkip[model]
        if not (skipUntil and os.clock() < skipUntil) and canChopAtAll(model) then
            local d = hrp and (Resources[model] - hrp.Position).Magnitude or entry.d
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best
end

local function treeFarm(still)
    local hrp = rootPart()
    local origin = hrp and hrp.Position
    if not origin then
        return
    end
    while still() and Settings.FarmTrees do
        if isNight() and Settings.FarmNight ~= "Keep farming" then
            FarmTarget = nil
            if Settings.FarmNight == "Wait at camp" and distanceTo(campPos()) > 40 then
                goToCamp(still)
            end
            setStatus("Night: waiting for morning")
            waitFor(600, function()
                return not isNight() or not Settings.FarmTrees
            end, still)
        else
            local tree = nextFarmTree(farmCenter(origin))
            if not tree then
                FarmTarget = nil
                setStatus("No trees left within " .. Settings.FarmRadius .. " studs")
                task.wait(3)
            else
                FarmTarget = tree
                local name = cleanName(tree.Name)
                setStatus("Walking to " .. name)
                local pos = Resources[tree] or pivotPos(tree)
                if pos and moveTo(besideOf(pos, 4)) and still() then
                    local startHealth = tree:GetAttribute("Health") or 0
                    setStatus("Chopping " .. name)
                    local fell = waitFor(25, function()
                        return not tree.Parent or (tree:GetAttribute("Health") or 0) <= 0 or not Settings.FarmTrees
                            or (isNight() and Settings.FarmNight ~= "Keep farming")
                    end, still)
                    if not fell and (tree:GetAttribute("Health") or 0) >= startHealth then
                        -- No damage at all in 25 s: something blocks it, try others first.
                        FarmSkip[tree] = os.clock() + 120
                    end
                else
                    FarmSkip[tree] = os.clock() + 30
                end
                FarmTarget = nil
            end
        end
    end
    setStatus("Tree farm off")
end

-- Kid rescue: go to each missing kid, bag it, bring it back to camp.
local function rescueKids(still)
    local start = rootPart() and rootPart().Position
    local rescued, failed = 0, {}
    while still() do
        if not itemBag() then
            setStatus("You need a sack in your inventory to carry kids")
            return
        end
        local hrp = rootPart()
        local kids = kidPositions()
        local pick, pickD
        for kidId, info in kids do
            if not failed[kidId] then
                local d = hrp and (info.pos - hrp.Position).Magnitude or 0
                if not pickD or d < pickD then
                    pick, pickD = kidId, d
                end
            end
        end
        if not pick then
            break
        end
        local info = kids[pick]
        local name = info.name or spaced(pick)
        setStatus("Going to " .. name)
        local unknown = not info.live and info.pos.Y == 0
        if not moveTo(info.pos, { unknownHeight = unknown }) or not still() then
            return
        end
        -- Wait for the kid to stream in, then step right next to it.
        setStatus("Looking for " .. name)
        local model
        waitFor(5, function()
            model = liveKid(pick)
            return model ~= nil
        end, still)
        if not model then
            failed[pick] = "not found at its map point"
        elseif not canBag(model) then
            failed[pick] = "can't be picked up yet"
        else
            local before = kidsInBag()
            moveTo(besideOf(mobPos(model), 3))
            setStatus("Picking up " .. name)
            local got = waitFor(6, function()
                if tryOnce(model, 1.5) then
                    bagKid(model)
                end
                return kidsInBag() > before or model.Parent == nil
            end, still)
            if not got then
                failed[pick] = "the sack wouldn't take it (full?)"
            else
                if not goToCamp(still) then
                    return
                end
                setStatus("Dropping " .. name .. " at camp")
                waitFor(6, function()
                    dropKidsAtCamp(true)
                    return kidsInBag() == 0
                end, still)
                rescued += 1
                if logEvent then
                    logEvent("Rescued " .. name, Color3.fromRGB(255, 220, 80))
                end
            end
        end
    end
    local text = string.format("Kid rescue done: %d rescued", rescued)
    local skipped = {}
    for kidId, why in failed do
        table.insert(skipped, spaced(kidId) .. " (" .. why .. ")")
    end
    if #skipped > 0 then
        text ..= " · skipped " .. table.concat(skipped, ", ")
    end
    -- Kids that couldn't be picked up can leave you out in the woods: end at
    -- camp when anyone was rescued, otherwise back where you started.
    if still() then
        if rescued > 0 then
            goToCamp(still)
        elseif start then
            moveTo(start)
        end
    end
    setStatus(text)
    notify("Kid rescue", text, 6)
end

-- Chest run: visit every chest that can still be opened, nearest first.
local function chestRun(still)
    local start = rootPart() and rootPart().Position
    local opened, skipped = 0, setmetatable({}, { __mode = "k" })
    while still() do
        local items = itemsFolder()
        local best, bestD
        for _, chest in items and items:GetChildren() or {} do
            if openableChest(chest) and not skipped[chest] then
                local d = distanceTo(pivotPos(chest))
                if not bestD or d < bestD then
                    best, bestD = chest, d
                end
            end
        end
        if not best then
            break
        end
        local name = best:GetAttribute("ChestName") or cleanName(best.Name)
        setStatus(string.format("Chest run: %s (%d opened)", name, opened))
        local pos = pivotPos(best)
        if pos and moveTo(besideOf(pos, 4)) and still() then
            local done = waitFor(3, function()
                if tryOnce(best, 1) then
                    openChest(best)
                end
                return not openableChest(best)
            end, still)
            if done then
                opened += 1
            end
        end
        skipped[best] = true
    end
    setStatus(string.format("Chest run done: %d opened", opened))
    notify("Chest run", string.format("%d chest%s opened", opened, opened == 1 and "" or "s"))
    if Settings.ReturnAfterRun and start and still() then
        moveTo(start)
    end
end

-- Night safety and low health escape, checked from the survival loop.
local lastEscape = 0
local wasNight = nil
local function safetyTick()
    local night = isNight()
    if Settings.NightCamp and night and wasNight == false and Job.name ~= "Tree farm" then
        startJob("Night safety", function(still)
            goToCamp(still)
            setStatus("Night: at camp")
        end)
    end
    wasNight = night
    if Settings.Escape and humanoid() and humanoid().Health > 0 and healthPercent() < Settings.EscapeBelow
        and os.clock() - lastEscape > 10 and distanceTo(campPos()) > 40 then
        lastEscape = os.clock()
        local wasFarming = Job.name == "Tree farm"
        startJob("Escape", function(still)
            goToCamp(still)
            if wasFarming then
                -- The farm stays off until you turn it back on.
                Settings.FarmTrees = false
                if Options.FarmTrees then
                    Options.FarmTrees:SetValue(false)
                end
            end
            setStatus(string.format("Escaped to camp at %d%% health", math.floor(healthPercent())))
            if logEvent then
                logEvent("Low health: escaped to camp", Color3.fromRGB(255, 120, 90))
            end
        end)
    end
end

--// ESP \\--
-- Roblox draws at most 31 highlights at once, so they go to the nearest 30
-- things; names show on everything in range.
local MAX_HIGHLIGHTS = 30
local Esp = {}
local function espEntry(model)
    local e = Esp[model]
    if e then
        return e
    end
    local part = anyPart(model)
    if not part then
        return nil
    end
    local bb = Instance.new("BillboardGui")
    bb.Name = "NNEsp"
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(220, 34)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
    bb.LightInfluence = 0
    bb.MaxDistance = math.huge
    bb.Adornee = part
    bb.Parent = VisualGui
    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.fromScale(1, 1)
    text.Font = Enum.Font.GothamMedium
    text.TextSize = 12
    text.TextStrokeTransparency = 0.35
    text.Parent = bb
    e = { bb = bb, text = text }
    Esp[model] = e
    return e
end

local function dropHighlight(e)
    if e.hl then
        e.hl:Destroy()
        e.hl = nil
    end
end

local function dropEsp(model)
    local e = Esp[model]
    if e then
        e.bb:Destroy()
        dropHighlight(e)
        Esp[model] = nil
    end
end

local function updateEsp()
    local hrp = rootPart()
    local want, order = {}, {}
    local function consider(model, color, text)
        local pos = pivotPos(model)
        local d = hrp and pos and (pos - hrp.Position).Magnitude
        if d and d <= Settings.EspDistance then
            local entry = { model = model, d = d, color = color, text = text .. string.format(" · %dm", math.floor(d)) }
            want[model] = entry
            table.insert(order, entry)
        end
    end

    if hrp then
        local folder = charactersFolder()
        if folder and (Settings.EspMobs or Settings.EspKids) then
            for _, model in folder:GetChildren() do
                local kind = mobKind(model)
                if kind == "Kid" then
                    if Settings.EspKids then
                        consider(model, Settings.KidColor, model:GetAttribute("PingName") or spaced(model:GetAttribute("KidId") or "Kid"))
                    end
                elseif kind and kind ~= "Dead" and kind ~= "Immune" and Settings.EspMobs then
                    local label = (model:GetAttribute("Name") or cleanName(model.Name)) .. " [" .. kind .. "]"
                    local npc = model:FindFirstChild("NPC")
                    if Settings.EspShowHealth and npc and npc:IsA("Humanoid") then
                        label ..= string.format(" %d/%d", math.floor(npc.Health), math.floor(npc.MaxHealth))
                    end
                    if chasingMe(model) then
                        label ..= " ⚠"
                    end
                    consider(model, MobColors[kind] or Color3.new(1, 1, 1), label)
                end
            end
        end
        if Settings.EspPlayers then
            for _, player in Players:GetPlayers() do
                if player ~= LocalPlayer and player.Character then
                    consider(player.Character, Settings.PlayerColor, player.DisplayName)
                end
            end
        end
        local items = itemsFolder()
        if items and (Settings.EspChests or Settings.EspItems) then
            for _, model in items:GetChildren() do
                if isChest(model) then
                    if Settings.EspChests and not chestOpened(model) then
                        local name = model:GetAttribute("ChestName") or cleanName(model.Name)
                        consider(model, Settings.ChestColor, model:GetAttribute("Locked") and (name .. " (locked)") or name)
                    end
                elseif Settings.EspItems and model:GetAttribute("Interaction") and Settings.EspItemKinds[itemKind(model)] then
                    consider(model, Settings.ItemColor, cleanName(model.Name))
                end
            end
        end
    end

    for model in Esp do
        if not want[model] or not model.Parent then
            dropEsp(model)
        end
    end
    table.sort(order, byDistance)
    for i, info in order do
        local e = espEntry(info.model)
        if e then
            e.text.Text = info.text
            e.text.TextColor3 = info.color
            if Settings.EspHighlight and i <= MAX_HIGHLIGHTS then
                if not e.hl then
                    e.hl = Instance.new("Highlight")
                    e.hl.FillTransparency = 0.75
                    e.hl.OutlineTransparency = 0.1
                    e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    e.hl.Adornee = info.model
                    e.hl.Parent = VisualGui
                end
                e.hl.FillColor = info.color
                e.hl.OutlineColor = info.color
            else
                dropHighlight(e)
            end
        end
    end
end

--// Lighting \\--
local restoreLighting, lightingStep
do
local LightingSaved = nil
local EffectsSaved = {}
local function saveLighting()
    if LightingSaved then
        return
    end
    LightingSaved = {
        Brightness = Lighting.Brightness,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        GlobalShadows = Lighting.GlobalShadows,
        FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart,
        ClockTime = Lighting.ClockTime,
        ExposureCompensation = Lighting.ExposureCompensation,
    }
end
function restoreLighting()
    if Settings.Fullbright or Settings.NoFog or Settings.AlwaysDay then
        return
    end
    if LightingSaved then
        for k, v in LightingSaved do
            pcall(function()
                Lighting[k] = v
            end)
        end
        LightingSaved = nil
    end
    for effect, props in EffectsSaved do
        if effect.Parent then
            for k, v in props do
                pcall(function()
                    effect[k] = v
                end)
            end
        end
    end
    table.clear(EffectsSaved)
end
local function saveEffect(effect, prop)
    EffectsSaved[effect] = EffectsSaved[effect] or {}
    if EffectsSaved[effect][prop] == nil then
        EffectsSaved[effect][prop] = effect[prop]
    end
end

-- The game rewrites lighting every frame for day/night, so this runs every frame too.
function lightingStep()
    if not (Settings.Fullbright or Settings.NoFog or Settings.AlwaysDay) then
        return
    end
    saveLighting()
    if Settings.Fullbright then
        Lighting.Brightness = 2
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.GlobalShadows = false
        Lighting.ExposureCompensation = 0
    end
    if Settings.AlwaysDay then
        Lighting.ClockTime = 14
    end
    if Settings.NoFog then
        Lighting.FogStart = 0
        Lighting.FogEnd = 1e6
    end
    for _, effect in Lighting:GetChildren() do
        if Settings.NoFog and effect:IsA("Atmosphere") then
            saveEffect(effect, "Density")
            saveEffect(effect, "Haze")
            effect.Density = 0
            effect.Haze = 0
        elseif Settings.Fullbright and effect:IsA("ColorCorrectionEffect") then
            saveEffect(effect, "Enabled")
            effect.Enabled = false
        end
    end
end
end

local UI = {}
--// UI \\--
UI.Window = Library:CreateWindow({
    Title = "Survive 99 Nights",
    Footer = "dookie hub · Ui3",
    Icon = "trees",
    Size = UDim2.fromOffset(760, 580),
    ConfigFolder = "Ui3/Survive99Nights",
})

local function toggle(box, idx, text, key, tooltip, after)
    return box:AddToggle(idx, {
        Text = text,
        Default = Settings[key],
        Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
end

local function slider(box, idx, text, key, min, max, suffix, tooltip)
    return box:AddSlider(idx, {
        Text = text,
        Default = Settings[key],
        Min = min,
        Max = max,
        Suffix = suffix,
        Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end

local function choice(box, idx, text, key, values, tooltip)
    return box:AddDropdown(idx, {
        Text = text,
        Values = values,
        Default = Settings[key],
        Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v or values[1]
        end,
    })
end

local function multi(box, idx, text, key, values, defaults, tooltip)
    return box:AddDropdown(idx, {
        Text = text,
        Values = values,
        Default = defaults,
        Multi = true,
        Searchable = #values > 8,
        Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end

-- Dashboard ---------------------------------------------------------------------
UI.DashTab = UI.Window:AddTab("Dashboard", "layout-dashboard", "Night and game info")

UI.NightBox = UI.DashTab:AddBigGroupbox("Night", "moon")
UI.NightCards = UI.NightBox:AddStatCards("NightCards", {
    Cards = {
        { Title = "Day", Value = "-", Icon = "calendar" },
        { Title = "Phase", Value = "-", Icon = "sun-moon" },
        { Title = "Time left", Value = "-", Icon = "clock" },
        { Title = "Weather", Value = "-", Icon = "cloud" },
    },
})
UI.PhaseBar = UI.NightBox:AddProgressBar("PhaseBar", { Text = "Until night", Default = 0, Max = 1, Percent = true })
UI.NightCards2 = UI.NightBox:AddStatCards("NightCards2", {
    Cards = {
        { Title = "Cultist attack", Value = "-", Icon = "skull" },
        { Title = "Biome", Value = "-", Icon = "map" },
        { Title = "Kids missing", Value = "-", Icon = "search" },
        { Title = "Hostiles near", Value = "-", Icon = "swords" },
    },
})

UI.YouBox = UI.DashTab:AddBigGroupbox("You", "user")
UI.YouCards = UI.YouBox:AddStatCards("YouCards", {
    Cards = {
        { Title = "Health", Value = "-", Icon = "heart" },
        { Title = "Hunger", Value = "-", Icon = "drumstick" },
        { Title = "Temperature", Value = "-", Icon = "thermometer" },
        { Title = "Class", Value = "-", Icon = "shield" },
    },
})
UI.HungerBar = UI.YouBox:AddProgressBar("HungerBar", { Text = "Hunger", Default = 0, Max = 200, Percent = false })
UI.HealthBar = UI.YouBox:AddProgressBar("HealthBar", { Text = "Health", Default = 0, Max = 100, Percent = false })

UI.GameBox = UI.DashTab:AddBigGroupbox("Game", "gamepad-2")
UI.GameCards = UI.GameBox:AddStatCards("GameCards", {
    Cards = {
        { Title = "Camp fire fuel", Value = "-", Icon = "flame" },
        { Title = "Diamonds", Value = "-", Icon = "gem" },
        { Title = "Players", Value = "-", Icon = "users" },
        { Title = "Automation", Value = "-", Icon = "bot" },
    },
})
UI.FireBar = UI.GameBox:AddProgressBar("FireBar", { Text = "Camp fire fuel", Default = 0, Max = 100, Percent = false })
UI.EventLog = UI.GameBox:AddLog("EventLog", { Text = "Events", Height = 140, MaxLines = 150 })

logEvent = function(text, color)
    pcall(UI.EventLog.Log, UI.EventLog, text, color)
end

-- Combat --------------------------------------------------------------------------
UI.CombatTab = UI.Window:AddTab("Combat", "axe", "Auto chop, kill aura and tree farm")

UI.ChopBox = UI.CombatTab:AddLeftGroupbox("Auto chop", "trees")
toggle(UI.ChopBox, "AutoChop", "Auto chop", "AutoChop", "Hits the nearest trees in range with your best axe, on the axe's own cooldown")
    :AddKeyPicker("AutoChopKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto chop" })
slider(UI.ChopBox, "ChopRange", "Chop distance", "ChopRange", 0, 200, " studs")
toggle(UI.ChopBox, "ShowChopRange", "Show chop range", "ShowChopRange"):AddColorPicker("ChopColor", {
    Default = Settings.ChopColor,
    Title = "Chop range color",
    Callback = function(c)
        Settings.ChopColor = c
    end,
})
slider(UI.ChopBox, "ChopPerSwing", "Trees per swing", "ChopPerSwing", 1, 10)
multi(UI.ChopBox, "ChopTypes", "What to chop", "ChopTypes", { "Tree" }, { "Tree" },
    "Filled from what the map holds, so new resource types show up here on their own")

UI.AuraBox = UI.CombatTab:AddRightGroupbox("Kill aura", "swords")
toggle(UI.AuraBox, "KillAura", "Kill aura", "KillAura", "Hits mobs in range with your best melee weapon. Kids and pets are never hit")
    :AddKeyPicker("KillAuraKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Kill aura" })
slider(UI.AuraBox, "AuraRange", "Aura distance", "AuraRange", 0, 200, " studs")
toggle(UI.AuraBox, "ShowAuraRange", "Show aura range", "ShowAuraRange"):AddColorPicker("AuraColor", {
    Default = Settings.AuraColor,
    Title = "Aura range color",
    Callback = function(c)
        Settings.AuraColor = c
    end,
})
slider(UI.AuraBox, "AuraPerSwing", "Mobs per swing", "AuraPerSwing", 1, 10)
multi(UI.AuraBox, "AuraKinds", "Targets", "AuraKinds", { "Hostile", "Can attack", "Passive" }, { "Hostile", "Can attack" },
    "Hostile: chasing or aggressive. Can attack: fights back. Passive: neither")
choice(UI.AuraBox, "AuraPriority", "Hit first", "AuraPriority", { "Chasing me first", "Nearest", "Lowest health" },
    "Which mobs get the swing when more are in range than mobs per swing")
UI.AuraNearLabel = UI.AuraBox:AddLabel("Nearby: -", true)

UI.SwingBox = UI.CombatTab:AddLeftGroupbox("Swing settings", "settings-2")
toggle(UI.SwingBox, "AutoEquip", "Auto equip the right tool", "AutoEquip")
choice(UI.SwingBox, "HitFrom", "Send hits from", "HitFrom", { "Your position", "Near target" },
    "Near target reports the swing next to what you hit. Try it if far hits don't land")
slider(UI.SwingBox, "ExtraDelay", "Extra delay per swing", "ExtraDelay", 0, 1000, " ms")
toggle(UI.SwingBox, "OneTool", "One tool for chop and aura", "OneTool",
    "With both on, swing your axe at mobs too instead of swapping to a weapon every other swing")
UI.AxeLabel = UI.SwingBox:AddLabel("Axe: -", true)
UI.WeaponLabel = UI.SwingBox:AddLabel("Weapon: -", true)
UI.BlockedLabel = UI.SwingBox:AddLabel("", true)

UI.FarmBox = UI.CombatTab:AddRightGroupbox("Tree farm", "tree-pine")
toggle(UI.FarmBox, "FarmTrees", "Tree farm", "FarmTrees",
    "Goes from tree to tree and chops each one down. Only picks trees an axe you own can break",
    function(v)
        if v then
            startJob("Tree farm", treeFarm)
        elseif Job.name == "Tree farm" then
            stopJob("Tree farm off")
        end
    end)
slider(UI.FarmBox, "FarmRadius", "Farm radius", "FarmRadius", 50, 2000, " studs")
choice(UI.FarmBox, "FarmAround", "Around", "FarmAround", { "Camp fire", "Where I started" },
    "Camp fire keeps the logs close for bringing to the fire")
choice(UI.FarmBox, "FarmNight", "At night", "FarmNight", { "Wait at camp", "Wait where I am", "Keep farming" })
UI.FarmBox:AddLabel("Pair it with Bring → Auto bring (Fuel to Camp fire) to keep the fire burning", true)

-- Bring ---------------------------------------------------------------------------
do
    local BringTab = UI.Window:AddTab("Bring", "magnet", "Pull items to you, the fire or the bench")

    local WhatBox = BringTab:AddLeftGroupbox("What", "package-search")
    multi(WhatBox, "BringKinds", "Item types", "BringKinds", ITEM_KINDS, { "Fuel" },
        "Sorted by what an item does (burns, feeds, heals, scraps...), so new items fall in on their own")
    UI.BringExclude = WhatBox:AddDropdown("BringExclude", {
        Text = "Never bring",
        Values = {},
        Multi = true,
        Searchable = true,
        Tooltip = "Items to leave where they are, even when their type is picked",
        Callback = function(v)
            Settings.BringExclude = v
        end,
    })
    WhatBox:AddDivider()
    toggle(WhatBox, "BringByName", "Pick by name instead", "BringByName")
    UI.BringNames = WhatBox:AddDropdown("BringNames", {
        Text = "Item names",
        Values = {},
        Multi = true,
        Searchable = true,
        Callback = function(v)
            Settings.BringNames = v
        end,
    })
    WhatBox:AddButton("Refresh names", function()
        local names = itemNames()
        UI.BringNames:SetValues(names)
        UI.BringExclude:SetValues(names)
    end)

    local WhereBox = BringTab:AddRightGroupbox("Where", "map-pin")
    choice(WhereBox, "BringDest", "Bring to", "BringDest", BRING_DESTS,
        "Camp fire burns fuel as it lands. Crafting bench scraps scrap as it lands")
    local SpotLabel = WhereBox:AddLabel("Saved spot: none", true)
    WhereBox:AddButton("Save current spot", function()
        local hrp = rootPart()
        if hrp then
            Settings.SavedSpot = CFrame.new(hrp.Position + hrp.CFrame.LookVector * 6)
            local p = Settings.SavedSpot.Position
            SpotLabel:SetText(string.format("Saved spot: %d, %d, %d", p.X, p.Y, p.Z))
        end
    end)

    local HowBox = BringTab:AddLeftGroupbox("How", "gauge")
    choice(HowBox, "BringMode", "Method", "BringMode", { "Fast", "Safe" },
        "Fast moves many items per frame (100+ a second). Safe moves one at a time and waits until the server hands it over")
    slider(HowBox, "BringPerFrame", "Items per frame (fast)", "BringPerFrame", 1, 50)
    slider(HowBox, "BringHold", "Hold before letting go", "BringHold", 0, 500, " ms", "Raise this if items snap back to where they were")
    slider(HowBox, "BringMax", "Max items per bring", "BringMax", 1, 500)
    slider(HowBox, "BringRange", "Search distance", "BringRange", 25, 5000, " studs")
    toggle(HowBox, "BringSkipNear", "Skip items already there", "BringSkipNear")

    local GoBox = BringTab:AddRightGroupbox("Bring", "send")
    UI.BringStatus = GoBox:AddLabel("Idle", true)
    GoBox:AddButton({
        Text = "Bring now",
        Func = function()
            if runBring(currentBringWhat(), Settings.BringDest) == 0 then
                UI.BringStatus:SetText("Nothing to bring")
            end
        end,
    }):AddButton({
        Text = "Stop",
        Func = function()
            Bring.token += 1
            Bring.running = false
        end,
    })
    toggle(GoBox, "AutoBring", "Auto bring", "AutoBring")
    slider(GoBox, "AutoBringEvery", "Every", "AutoBringEvery", 2, 60, " s")

    local QuickBox = BringTab:AddRightGroupbox("Quick", "zap")
    for _, quick in {
        { "Fuel to camp fire", { Fuel = true }, "Camp fire" },
        { "Scrap to crafting bench", { Scrap = true }, "Crafting bench" },
        { "Food to me", { Food = true }, "You" },
        { "Heals to me", { Heals = true }, "You" },
        { "Gear and ammo to me", { Gear = true, Ammo = true }, "You" },
        { "Gems to me", { Gems = true }, "You" },
    } do
        QuickBox:AddButton(quick[1], function()
            if runBring({ kinds = quick[2], exclude = Settings.BringExclude }, quick[3]) == 0 then
                UI.BringStatus:SetText("Nothing to bring")
            end
        end)
    end
end

-- Survival ------------------------------------------------------------------------
do
    local SurvivalTab = UI.Window:AddTab("Survival", "heart-pulse", "Eating, healing, the fire and staying alive")

    local EatBox = SurvivalTab:AddLeftGroupbox("Eat and heal", "drumstick")
    toggle(EatBox, "AutoEat", "Auto eat", "AutoEat", "Eats the nearest food in reach when hunger drops below the line")
    slider(EatBox, "EatBelow", "Eat below hunger", "EatBelow", 10, 200)
    toggle(EatBox, "EatBring", "Bring food over if none is in reach", "EatBring")
    EatBox:AddDivider()
    toggle(EatBox, "AutoHeal", "Auto heal", "AutoHeal", "Uses the nearest bandage or medkit in reach when health drops below the line")
    slider(EatBox, "HealBelow", "Heal below health", "HealBelow", 5, 95, "%")
    toggle(EatBox, "HealBring", "Bring a heal over if none is in reach", "HealBring")
    EatBox:AddDivider()
    slider(EatBox, "ConsumeRange", "Eat / heal reach", "ConsumeRange", 5, 80, " studs",
        "The game lets you use things within 15 studs; more may or may not be accepted")

    local CampBox = SurvivalTab:AddRightGroupbox("Camp", "flame")
    toggle(CampBox, "KeepFireFed", "Keep the fire fed", "KeepFireFed",
        "Brings fuel to the camp fire (and burns it) whenever its fuel drops below the line")
    slider(CampBox, "FireBelow", "Feed below fuel", "FireBelow", 1, 500)
    toggle(CampBox, "KeepScrapping", "Keep scrapping", "KeepScrapping",
        "Every 20 s, brings scrap to the crafting bench and scraps it")

    local SafeBox = SurvivalTab:AddRightGroupbox("Safety", "shield")
    toggle(SafeBox, "NightCamp", "Go to camp when night falls", "NightCamp",
        "Stops whatever automation is running (except the tree farm, which has its own night setting)")
    toggle(SafeBox, "Escape", "Escape to camp on low health", "Escape",
        "Drops what you're doing and goes to the camp fire. Turns the tree farm off")
    slider(SafeBox, "EscapeBelow", "Escape below health", "EscapeBelow", 5, 80, "%")
end

-- Explore -------------------------------------------------------------------------
do
    local ExploreTab = UI.Window:AddTab("Explore", "compass", "Kids, chests and loot")

    local RunBox = ExploreTab:AddLeftGroupbox("Automation", "bot")
    UI.JobLabel = RunBox:AddLabel("Idle", true)
    RunBox:AddButton({
        Text = "Rescue all kids",
        Func = function()
            startJob("Kid rescue", rescueKids)
        end,
    }):AddButton({
        Text = "Chest run",
        Func = function()
            startJob("Chest run", chestRun)
        end,
    })
    RunBox:AddButton("Stop", function()
        if Job.name == "Tree farm" and Options.FarmTrees then
            Options.FarmTrees:SetValue(false)
        end
        stopJob("Stopped")
    end)
    toggle(RunBox, "ReturnAfterRun", "Go back to where I was after a chest run", "ReturnAfterRun")
    RunBox:AddLabel("Kid rescue needs a sack. It goes to each kid, picks it up and brings it to the camp fire. Turn on kill aura first", true)

    local KidsBox = ExploreTab:AddRightGroupbox("Lost kids", "baby")
    toggle(KidsBox, "AutoBagKids", "Auto pick up kids", "AutoBagKids",
        "Puts a lost kid in your sack as soon as you're within 15 studs (the game's reach). Needs room in the sack")
    toggle(KidsBox, "AutoDropKids", "Auto drop kids at camp", "AutoDropKids",
        "Takes kids out of your sack when you're within 30 studs of the camp fire")

    local LootBox = ExploreTab:AddRightGroupbox("Loot", "package-open")
    toggle(LootBox, "AutoChests", "Auto open chests in range", "AutoChests",
        "Opens a chest once you're inside its own prompt range, without the hold. Skips locked and opened ones")
    toggle(LootBox, "AutoCoins", "Auto collect coins and diamonds", "AutoCoins")
    slider(LootBox, "CoinRange", "Collect range", "CoinRange", 5, 80, " studs")
    toggle(LootBox, "InstantPrompts", "Instant interact (no hold)", "InstantPrompts", nil, setInstantPrompts)
end

-- Movement ------------------------------------------------------------------------
local refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems
do
    local MoveTab = UI.Window:AddTab("Movement", "footprints", "Speed, jump, fly and teleports")

    local MoveBox = MoveTab:AddLeftGroupbox("Movement", "move")
    toggle(MoveBox, "Speed", "Speed", "Speed", nil, function(v)
        local hum = humanoid()
        if not v and hum and Settings.SpeedMethod == "WalkSpeed" then
            hum.WalkSpeed = 16
        end
    end)
    slider(MoveBox, "SpeedValue", "Walk speed", "SpeedValue", 16, 150)
    choice(MoveBox, "SpeedMethod", "Speed method", "SpeedMethod", { "WalkSpeed", "CFrame" },
        "CFrame leaves the game's walk speed alone and pushes you along on top of it")
    MoveBox:AddDivider()
    toggle(MoveBox, "Jump", "Jump power", "Jump", nil, function(v)
        if not v then
            restoreJump()
        end
    end)
    slider(MoveBox, "JumpValue", "Jump power", "JumpValue", 50, 250)
    toggle(MoveBox, "InfJump", "Infinite jump", "InfJump")
    MoveBox:AddDivider()
    toggle(MoveBox, "Fly", "Fly", "Fly",
        "Thumbstick or WASD to move where the camera looks. Space/E up, Ctrl/Q down, or the ▲▼ buttons on mobile",
        function(v)
            if not v then
                stopFly()
                FlyUpHeld, FlyDownHeld = false, false
            end
        end):AddKeyPicker("FlyKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
    slider(MoveBox, "FlySpeed", "Fly speed", "FlySpeed", 16, 280)
    toggle(MoveBox, "Noclip", "Noclip", "Noclip", nil, function(v)
        if not v and not Travelling then
            restoreNoclip()
        end
    end)
    toggle(MoveBox, "AntiAfk", "Anti AFK", "AntiAfk")

    local TpSetBox = MoveTab:AddLeftGroupbox("Teleport settings", "settings")
    choice(TpSetBox, "TpMethod", "Teleport method", "TpMethod", { "Tween", "Instant" },
        "Tween glides there through walls at the speed below. Instant jumps straight there")
    slider(TpSetBox, "TpSpeed", "Tween speed", "TpSpeed", 30, 280)
    toggle(TpSetBox, "TpGround", "Land on the ground", "TpGround", "Finds the ground under where you're going, so you never land in a tree top")
    TpSetBox:AddButton("Stop moving", function()
        tpToken += 1
    end)

    -- Each teleport dropdown keeps a label -> target map that refreshes rebuild.
    local function teleportPicker(box, idx, text, build, resolve)
        local map = {}
        local dropdown = box:AddDropdown(idx, { Text = text, Values = {}, Searchable = true, AllowNull = true })
        local function refresh()
            local list, order = build()
            map = list
            dropdown:SetValues(order)
        end
        box:AddButton({
            Text = "Teleport",
            Func = function()
                local label = dropdown.Value
                if not label or map[label] == nil then
                    notify("Teleport", "Pick something first", 2)
                    return
                end
                local pos, opts = resolve(map[label])
                teleportTo(pos, opts)
            end,
        }):AddButton({ Text = "Refresh", Func = refresh })
        return refresh
    end

    local PlaceBox = MoveTab:AddRightGroupbox("Places", "map-pin")
    refreshPlaces = teleportPicker(PlaceBox, "TpPlace", "Camp and caves", placeTargets, function(getPos)
        return getPos()
    end)

    local LandBox = MoveTab:AddRightGroupbox("Landmarks", "landmark")
    local landmarkEverything = false
    refreshLandmarks = teleportPicker(LandBox, "TpLandmark", "Landmark", function()
        return landmarkTargets(landmarkEverything)
    end, pivotPos)
    LandBox:AddToggle("LandmarkAll", {
        Text = "List every landmark",
        Default = false,
        Tooltip = "Off lists the named ones (caves, ponds, traps, the mother tree...). On adds spawns, huts, graves and the rest",
        Callback = function(v)
            landmarkEverything = v
            refreshLandmarks()
        end,
    })

    local ChestBox = MoveTab:AddRightGroupbox("Chests", "package")
    refreshChests = teleportPicker(ChestBox, "TpChest", "Chest (nearest first)", chestTargets, function(chest)
        local pos = pivotPos(chest)
        return pos and besideOf(pos, 4)
    end)
    ChestBox:AddButton("Nearest unopened chest", function()
        local items = itemsFolder()
        local best, bestD
        for _, chest in items and items:GetChildren() or {} do
            if openableChest(chest) then
                local d = distanceTo(pivotPos(chest))
                if not bestD or d < bestD then
                    best, bestD = chest, d
                end
            end
        end
        if best then
            teleportTo(besideOf(pivotPos(best), 4))
        else
            notify("Teleport", "No unopened chest loaded", 2)
        end
    end)

    local KidBox = MoveTab:AddLeftGroupbox("Lost kids", "baby")
    refreshKids = teleportPicker(KidBox, "TpKid", "Kid", function()
        local list, order = {}, {}
        for kidId, info in kidPositions() do
            local label = info.name or spaced(kidId)
            list[label] = kidId
            table.insert(order, label)
        end
        table.sort(order)
        return list, order
    end, function(kidId)
        local info = kidPositions()[kidId]
        if not info then
            return nil
        end
        -- A map point has no height; the landing finds the ground once it loads.
        return info.pos, { unknownHeight = not info.live and info.pos.Y == 0 }
    end)

    local ItemBox = MoveTab:AddLeftGroupbox("Items", "box")
    refreshItems = teleportPicker(ItemBox, "TpItem", "Nearest item of type", function()
        local list = {}
        local order = itemNames()
        for _, name in order do
            list[name] = name
        end
        return list, order
    end, function(name)
        return pivotPos(nearestItemNamed(name))
    end)

    local PlayerBox = MoveTab:AddRightGroupbox("Players", "users")
    PlayerBox:AddDropdown("TpPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
    PlayerBox:AddButton("Teleport", function()
        local name = Options.TpPlayer and Options.TpPlayer.Value
        local player = name and Players:FindFirstChild(name)
        local hrp = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        teleportTo(hrp and hrp.Position)
    end)
end

-- Visuals -------------------------------------------------------------------------
do
    local VisTab = UI.Window:AddTab("Visuals", "eye", "ESP, kid dots and lighting")

    local KidEspBox = VisTab:AddLeftGroupbox("Kid dots", "baby")
    toggle(KidEspBox, "KidDots", "Kid dots", "KidDots",
        "A dot on each missing kid, from the server's map points, so they show even when not loaded. Off screen dots stick to the edge")
        :AddColorPicker("KidColor", {
            Default = Settings.KidColor,
            Title = "Kid color",
            Callback = function(c)
                Settings.KidColor = c
                MobColors.Kid = c
            end,
        })
    toggle(KidEspBox, "KidLabels", "Show name and distance", "KidLabels")

    local EspBox = VisTab:AddLeftGroupbox("ESP", "scan-eye")
    toggle(EspBox, "EspMobs", "Mobs", "EspMobs", "Red hostile, orange can attack, green passive, blue pets. ⚠ = chasing you")
    toggle(EspBox, "EspKids", "Kids (loaded)", "EspKids")
    toggle(EspBox, "EspPlayers", "Players", "EspPlayers"):AddColorPicker("PlayerColor", {
        Default = Settings.PlayerColor,
        Title = "Player color",
        Callback = function(c)
            Settings.PlayerColor = c
        end,
    })
    toggle(EspBox, "EspChests", "Chests (unopened)", "EspChests"):AddColorPicker("ChestColor", {
        Default = Settings.ChestColor,
        Title = "Chest color",
        Callback = function(c)
            Settings.ChestColor = c
        end,
    })
    toggle(EspBox, "EspItems", "Items", "EspItems"):AddColorPicker("ItemColor", {
        Default = Settings.ItemColor,
        Title = "Item color",
        Callback = function(c)
            Settings.ItemColor = c
        end,
    })
    multi(EspBox, "EspItemKinds", "Item types", "EspItemKinds",
        { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency", "Other" },
        { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency" },
        "Sorted by what the item does (burns, feeds, scraps...), so new items fall in on their own")

    local EspSetBox = VisTab:AddRightGroupbox("ESP settings", "sliders-horizontal")
    toggle(EspSetBox, "EspHighlight", "Highlights", "EspHighlight", "On the nearest 30 (Roblox's limit); names show on everything")
    toggle(EspSetBox, "EspShowHealth", "Mob health", "EspShowHealth")
    slider(EspSetBox, "EspDistance", "Max distance", "EspDistance", 50, 2000, " studs")

    local WorldBox = VisTab:AddRightGroupbox("World", "sun")
    toggle(WorldBox, "Fullbright", "Fullbright", "Fullbright", nil, restoreLighting)
    toggle(WorldBox, "NoFog", "No fog", "NoFog", nil, restoreLighting)
    toggle(WorldBox, "AlwaysDay", "Always day (only on your screen)", "AlwaysDay", nil, restoreLighting)
    toggle(WorldBox, "FovOn", "Field of view", "FovOn", nil, function(v)
        if not v then
            Camera.FieldOfView = 70
        end
    end)
    slider(WorldBox, "Fov", "FOV", "Fov", 50, 120)
end

--// Loops \\--
bind(RunService.Heartbeat, function(dt)
    if not alive() then
        return
    end
    swingTick()
    movementStep(dt)
end)

bind(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    Camera = Workspace.CurrentCamera
    placeRing(ChopRing, Settings.ShowChopRange, Settings.ChopRange, Settings.ChopColor, 0.05)
    placeRing(AuraRing, Settings.ShowAuraRange, Settings.AuraRange, Settings.AuraColor, 0.15)
    updateKidDots()
    lightingStep()
    if Settings.FovOn then
        Camera.FieldOfView = Settings.Fov
    end
end)

loop(0.25, updateEsp)

-- Teleport lists fill themselves once things load, and new resource types and
-- item names reach their pickers.
local lastLists = 0
loop(1, function()
    if os.clock() - lastLists > 15 then
        lastLists = os.clock()
        for _, refresh in { refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems } do
            pcall(refresh)
        end
    end
    if #UI.BringNames.Values == 0 then
        local names = itemNames()
        UI.BringNames:SetValues(names)
        UI.BringExclude:SetValues(names)
    end
    if pendingTypes and Options.ChopTypes then
        pendingTypes = false
        local types = {}
        for kind in ResourceTypes do
            table.insert(types, kind)
        end
        table.sort(types)
        Options.ChopTypes:SetValues(types)
    end
end)

-- Survival helpers, safety and auto bring.
local lastAutoBring = 0
loop(0.3, function()
    survivalTick()
    safetyTick()
    if Settings.AutoBring and not Bring.running and os.clock() - lastAutoBring >= Settings.AutoBringEvery then
        lastAutoBring = os.clock()
        runBring(currentBringWhat(), Settings.BringDest)
    end
    if Bring.running then
        UI.BringStatus:SetText(string.format("Bringing %d / %d", math.min(Bring.done, Bring.total), Bring.total))
    elseif Bring.total > 0 then
        UI.BringStatus:SetText(string.format("Done: %d item%s", Bring.total, Bring.total == 1 and "" or "s"))
    end
    UI.JobLabel:SetText(Job.name and (Job.name .. ": " .. Job.status) or Job.status)
end)

-- Dashboard.
do
local Phase = { state = nil, max = 1, day = nil, weather = nil, cultist = nil, missing = nil }
local ChasedBy = {}
local startTime = os.clock()

loop(0.25, function()
    local state = Workspace:GetAttribute("State") or "-"
    local left = Workspace:GetAttribute("SecondsLeft") or 0
    local day = Workspace:GetAttribute("StoryDayCounter") or Workspace:GetAttribute("RealDayCounter")
    local weather = Workspace:GetAttribute("Weather") or "-"
    local cultist = Workspace:GetAttribute("CultistAttackDay") == true
    local missing = missingCount()

    if state ~= Phase.state then
        if Phase.state ~= nil then
            logEvent((state == "Night" and "Night" or "Day") .. " started (day " .. tostring(day) .. ")",
                state == "Night" and Color3.fromRGB(150, 140, 255) or Color3.fromRGB(255, 220, 120))
        end
        Phase.state = state
        Phase.max = math.max(left, 1)
    end
    Phase.max = math.max(Phase.max, left)
    if day ~= Phase.day then
        if Phase.day ~= nil then
            logEvent("Day " .. tostring(day))
        end
        Phase.day = day
    end
    if weather ~= Phase.weather then
        if Phase.weather ~= nil then
            logEvent("Weather: " .. tostring(weather))
        end
        Phase.weather = weather
    end
    if cultist ~= Phase.cultist then
        if cultist then
            logEvent("Cultist attack tonight", Color3.fromRGB(255, 90, 90))
        end
        Phase.cultist = cultist
    end
    if Phase.missing and missing < Phase.missing then
        logEvent(string.format("A kid is back at camp (%d still missing)", missing), Color3.fromRGB(255, 220, 80))
    end
    Phase.missing = missing

    UI.NightCards:SetValue("Day", tostring(day or "-"))
    UI.NightCards:SetValue("Phase", state)
    UI.NightCards:SetValue("Time left", clock(left))
    UI.NightCards:SetValue("Weather", tostring(weather))
    UI.PhaseBar:SetText(state == "Night" and "Until morning" or "Until night")
    UI.PhaseBar:SetMax(Phase.max)
    UI.PhaseBar:SetValue(Phase.max - left)

    local counts = { Hostile = 0, ["Can attack"] = 0, Passive = 0 }
    local folder = charactersFolder()
    local hrp = rootPart()
    if folder then
        for _, model in folder:GetChildren() do
            local kind = mobKind(model)
            if counts[kind] and hrp then
                local pos = mobPos(model)
                if pos and (pos - hrp.Position).Magnitude <= math.max(Settings.AuraRange, 60) then
                    counts[kind] += 1
                end
            end
            if kind == "Hostile" and chasingMe(model) and model:GetAttribute("State") == "Chase" then
                if not ChasedBy[model] then
                    ChasedBy[model] = true
                    local name = model:GetAttribute("Name") or cleanName(model.Name)
                    logEvent(name .. " is chasing you", Color3.fromRGB(255, 120, 90))
                end
            elseif ChasedBy[model] then
                ChasedBy[model] = nil
            end
        end
    end
    for model in ChasedBy do
        if not model.Parent then
            ChasedBy[model] = nil
        end
    end

    UI.NightCards2:SetValue("Cultist attack", cultist and "Tonight" or "No")
    UI.NightCards2:SetValue("Biome", tostring(Workspace:GetAttribute("Biome") or "-"))
    UI.NightCards2:SetValue("Kids missing", tostring(missing))
    UI.NightCards2:SetValue("Hostiles near", tostring(counts.Hostile))
    UI.AuraNearLabel:SetText(string.format("Nearby: %d hostile · %d can attack · %d passive", counts.Hostile, counts["Can attack"], counts.Passive))
    UI.AxeLabel:SetText("Axe: " .. SwingInfo.axe)
    UI.WeaponLabel:SetText("Weapon: " .. SwingInfo.weapon)
    if (Settings.AutoChop or FarmTarget) and SwingInfo.blocked > 0 then
        UI.BlockedLabel:SetText(string.format("%d tree%s in range need%s a tier %s axe",
            SwingInfo.blocked, SwingInfo.blocked == 1 and "" or "s", SwingInfo.blocked == 1 and "s" or "",
            tostring(SwingInfo.blockedTier or "?")))
    else
        UI.BlockedLabel:SetText("")
    end

    local hum = humanoid()
    local hunger = LocalPlayer:GetAttribute("Hunger") or 0
    local temp = LocalPlayer:GetAttribute("Temperature")
    local class = LocalPlayer:GetAttribute("Class")
    UI.YouCards:SetValue("Health", hum and string.format("%d / %d", math.floor(hum.Health), math.floor(hum.MaxHealth)) or "-")
    UI.YouCards:SetValue("Hunger", string.format("%d / 200", math.floor(hunger)))
    UI.YouCards:SetValue("Temperature", temp and tostring(math.floor(temp)) or "-")
    UI.YouCards:SetValue("Class", class and (class .. " " .. tostring(LocalPlayer:GetAttribute("ClassLevel") or "")) or "-")
    UI.HungerBar:SetMax(math.max(200, hunger))
    UI.HungerBar:SetValue(hunger)
    if hum then
        UI.HealthBar:SetMax(math.max(hum.MaxHealth, 1))
        UI.HealthBar:SetValue(hum.Health)
    end

    local fire = campPart("MainFire")
    local fuel = fire and fire:GetAttribute("FuelRemaining") or 0
    UI.GameCards:SetValue("Camp fire fuel", fire and tostring(math.floor(fuel)) or "-")
    UI.GameCards:SetValue("Diamonds", tostring(LocalPlayer:GetAttribute("Diamonds") or "-"))
    UI.GameCards:SetValue("Players", #Players:GetPlayers() .. " / " .. Players.MaxPlayers)
    UI.GameCards:SetValue("Automation", Job.name or "Idle")
    UI.FireBar:SetMax(math.max(UI.FireBar.Max, fuel, 1))
    UI.FireBar:SetValue(fuel)
end)

logEvent("Loaded in " .. string.format("%.1fs", os.clock() - startTime) .. " · place " .. game.PlaceId)
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    table.clear(Connections)
    stopJob()
    Bring.token += 1
    if Settings.InstantPrompts then
        Settings.InstantPrompts = false
        setInstantPrompts(false)
    end
    stopFly()
    restoreNoclip()
    restoreJump()
    Settings.Fullbright, Settings.NoFog, Settings.AlwaysDay = false, false, false
    restoreLighting()
    if Settings.FovOn then
        Camera.FieldOfView = 70
    end
    local hum = humanoid()
    if hum and Settings.Speed and Settings.SpeedMethod == "WalkSpeed" then
        hum.WalkSpeed = 16
    end
    for model in Esp do
        dropEsp(model)
    end
    pcall(function()
        VisualGui:Destroy()
    end)
end

Library:OnUnload(cleanup)
Genv.__NinetyNineUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

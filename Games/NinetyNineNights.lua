--// Survive 99 Nights ------------------------------------------------------------------
-- Built against script dumps of the live game (place 126509999114328, versions
-- 712 and 720).
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
--  * Version 720 adds (all from the game's own client modules):
--    cooking: RequestCookItem:FireServer(fire, item) for a Cookable item while
--      the fire has fuel; crockpots (tag Crockpot, < 3 Ingredients) take
--      RequestCrockpotItem:InvokeServer(pot, item).
--    fishing: the rod object (ReplicatedStorage.Tools["Fishing Rod"]) runs the
--      catch bar on the client; :Pull() while the bar overlaps the green zone
--      scores, and the rod itself reports the catch.
--    taming: the flute object runs its mini game on the client and fires
--      RequestTame_Hungry when its TamingTime fills; then the animal (tag
--      CanFeed_<UserId>) wants Food<n>Type and takes
--      RequestTame_Feed:InvokeServer(animal, food, n). Your pets carry
--      TamedAnimal_<UserId>; RequestFeedHealPet:FireServer(pet, food) heals,
--      CommandPet:FireServer(pet, "Sit" / "FollowOwner"), RequestSummonAllPets.
--    Halloween: candy is spawned on the client in Workspace.Halloween.Candy and
--      claimed one at a time with RequestCollectCandy:FireServer(1, source)
--      (floating candy: RequestCollectFloatingCandy(spawnId, index)). Houses
--      (tag HalloweenHouse) light with a Halloween Candle through
--      RequestActivateHalloweenHouse(candle, house) and are knocked through the
--      game's TrickOrTreatClient.KnockOnDoor(door). Carving tables (tag
--      PumpkinCarvingTable): RequestPlaceCarvingPumpkin(pumpkin, table),
--      RequestCarvePumpkin(table, option), RequestCollectCarvedPumpkin(table).
--      The Hollow: GetHollowEntrancePosition, GetHollowUpgradeOffer /
--      ChooseHollowUpgrade(id) while HollowUpgradesReady > 0; its trees live in
--      Workspace.HollowMap.
--    jungle: Crystal Skull Keys (tag JungleKey) go on temple podiums with
--      RequestAddJungleTempleGem(key, podium); keys (tag KeyModel) open the
--      lock whose LockNumber matches UnlocksDoor with KeyUsed(key, lock).
--    gems: gem rain and diamond tree diamonds are client models (AdminDiamond)
--      claimed with ClaimGemRainGem / ClaimDiamondTreeGem(tag); green gem pieces
--      merge with RequestMergeGems(a, b).
--    planting: RequestPlantItem(item, groundPos) 40+ studs from the fire,
--      RequestPlantSeeds(seedBox). Crafting: CraftItem(name). Base Defender:
--      RequestUpgradeDefense(structure). Revive: RequestRevivePlayer(body)
--      with a bandage or medkit, RequestSelfRevive. Machines (gems):
--      RequestClearWeather(Weather Machine),
--      RequestActivateNightSkipMachine(Temporal Accelerometer). Wood Rain
--      Storage dries with RequestRainStorageDry(item, storage). Caves:
--      CaveInstanceClient.TeleportTo(point). Shops: RequestPurchaseTool(name),
--      RequestPurchaseExtra(name), RequestBuyFromBeekeeper(slot).
--    The game's client hub (require(PlayerScripts.Client)) loads any of its
--    modules by name, so the game's own functions are used where they exist.
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
    AutoEquip = true, HitFrom = "Your position", ExtraDelay = 0, OneTool = true, SwingMode = "Fast",
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
    EspItemKinds = { Fuel = true, Food = true, Heals = true, Scrap = true, Gems = true, Ammo = true, Gear = true, Seeds = true, Keys = true, Currency = true },
    EspHighlight = true, EspDistance = 400, EspShowHealth = true, EspMax = 120,
    PlayerColor = Color3.fromRGB(120, 180, 255), ChestColor = Color3.fromRGB(255, 200, 90),
    ItemColor = Color3.fromRGB(200, 200, 200),
    Fullbright = false, NoFog = false, AlwaysDay = false, FovOn = false, Fov = 80,
    -- bring
    BringCategory = "Fuel", BringPicks = {}, BringExclude = {}, BringOrder = "Nearest first",
    BringDest = "You", BringMode = "Fast", BringPerFrame = 10, BringHold = 100,
    BringMax = 100, BringRange = 2000, BringSkipNear = true, SavedSpot = nil,
    AutoBring = false, AutoBringEvery = 10,
    ChestLoot = false, ChestLootDest = "You",
    ChestLootKinds = { Fuel = true, Food = true, Heals = true, Scrap = true, Gems = true, Ammo = true, Gear = true, Seeds = true, Keys = true, Other = true },
    -- survival
    AutoEat = false, EatBelow = 120, EatBring = true,
    AutoHeal = false, HealBelow = 50, HealBring = true, ConsumeRange = 15,
    KeepFireFed = false, FireBelow = 40, FuelOrder = "Strongest first", KeepScrapping = false,
    NightCamp = false, Escape = false, EscapeBelow = 25,
    AutoReviveOthers = false, AutoSelfRevive = false,
    AutoClearWeather = false, AutoNightSkip = false, AutoDryWood = false,
    -- farm
    AutoCook = false, AutoCrockpot = false,
    PerfectFishing = false, InstantCatch = false, InstantCatchDelay = 0.4, AutoRecast = false,
    PerfectFlute = false, InstaTame = false, AutoStartTaming = false, AutoFeedTaming = false, AutoHealPets = false,
    AutoUpgradeTools = false, AutoArmour = false, EspFishSpots = false,
    AutoPlant = false, PlantRadius = 60, AutoBenchUpgrade = false, CraftPick = nil,
    AutoUpgradeDefense = false,
    -- events
    AutoCandy = false, AutoTrickOrTreat = false, AutoLightHouses = true, AutoPumpkins = false,
    AutoHollowUpgrade = false, HollowUpgradePick = "First offer",
    AutoTempleKeys = false, AutoKeys = false, AutoGemClaim = false, AutoMergeGems = false,
    BeekeeperMax = 100,
    -- explore
    AutoChests = false, AutoBagKids = false, AutoDropKids = false,
    AutoCoins = false, CoinRange = 20, InstantPrompts = false,
    ReturnAfterRun = true, RunSpeed = 300, RunHigh = 35, SkipGuarded = true, GuardRadius = 14,
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
local function notify(title, text, seconds)
    pcall(Library.Notify, Library, { Title = title, Description = text, Time = seconds or 3 })
end

local UID = LocalPlayer.UserId

-- The game's client hub: indexing it loads any of its modules by name
-- (TrickOrTreatClient, CaveInstanceClient, ...), the same table its own
-- scripts use.
local GameClient
local function gameClient()
    if GameClient == nil then
        local ok, hub = pcall(function()
            return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client", 5))
        end)
        GameClient = (ok and type(hub) == "table") and hub or false
    end
    return GameClient or nil
end
local function gameModule(name)
    local hub = gameClient()
    if not hub then
        return nil
    end
    local ok, mod = pcall(function()
        return hub[name]
    end)
    return ok and mod or nil
end

-- Live sets of what's on the map, kept up to date by ChildAdded/ChildRemoved
-- instead of re-reading whole folders every tick (filled in further down).
local Index = {
    items = {}, -- model -> { kind, name }
    byKind = {}, -- kind -> { [model] = true }
    byName = {}, -- name -> { [model] = true }
    chests = {}, -- chest -> true
    mobs = {}, -- Workspace.Characters model -> true
    kids = {}, -- lost kid model -> true
    namesVersion = 0, -- bumps whenever an item name appears or disappears
}

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
-- Cached for a moment: the swing loop asks every tick and the inventory
-- rarely changes.
local weaponCache, weaponCacheAt = nil, -1
local function bestWeaponNow()
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
local function bestWeapon()
    if os.clock() - weaponCacheAt > 1 or (weaponCache and weaponCache.Parent == nil) then
        weaponCache, weaponCacheAt = bestWeaponNow(), os.clock()
    end
    return weaponCache
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

local lastEquip, lastEquipped = 0, nil
-- True when the swing can go ahead with `tool`. Not in hand: asks the server
-- to equip it (when auto equip is on). Fast swings straight away, since the
-- server handles the equip before the hits sent after it; Normal waits a
-- tick for the game to show the tool in hand.
local function readyTool(tool)
    if equippedName() == tool.Name or not Settings.AutoEquip then
        return true
    end
    local fast = Settings.SwingMode == "Fast"
    if lastEquipped ~= tool or os.clock() - lastEquip > (fast and 0.3 or 0.75) then
        lastEquip, lastEquipped = os.clock(), tool
        local r = remote("EquipItemHandle")
        if r then
            r:FireServer("FireAllClients", tool)
        end
        return fast
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

-- The main map and the Halloween Hollow (Workspace.HollowMap) both hold trees.
local ScannedMaps = {}
local function scanMap(map)
    if ScannedMaps[map] then
        return
    end
    ScannedMaps[map] = true
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
end
local RESOURCE_ROOTS = { Map = true, HollowMap = true }
task.spawn(function()
    local map = Workspace:WaitForChild("Map", 30)
    if not alive() then
        return
    end
    bind(Workspace.ChildAdded, function(child)
        if RESOURCE_ROOTS[child.Name] then
            task.defer(scanMap, child)
        end
    end)
    if map then
        scanMap(map)
    end
    local hollow = Workspace:FindFirstChild("HollowMap")
    if hollow then
        scanMap(hollow)
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
    if model:GetAttribute("Tamed") or model:GetAttribute("CurrentTamingState") == "Tamed" or model:GetAttribute("State") == "FollowOwner"
        or model:HasTag("TamedAnimal_" .. UID) then
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
    if not hrp then
        return {}
    end
    local list = {}
    for model in Index.mobs do
        if model.Parent then
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
-- opts: unknownHeight (a map marker with no real height), exact (go to `pos`
-- itself instead of the ground under it), speed (studs/s, overrides the tween
-- speed), high (studs: rise this far above the route, cross, then drop, so
-- mobs on the ground can't reach you on the way).
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
    local target = opts.exact and pos or landingSpot(pos, opts.unknownHeight)
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
        local points = { target }
        local high = opts.high and opts.high > 0 and (target - hrp.Position).Magnitude > 30
        if high then
            local top = math.max(hrp.Position.Y, target.Y) + opts.high
            points = {
                Vector3.new(hrp.Position.X, top, hrp.Position.Z),
                Vector3.new(target.X, top, target.Z),
                target,
            }
        end
        local speed = opts.speed or Settings.TpSpeed
        Travelling, TravelOwner = true, token
        local arrived = true
        for _, point in points do
            local r0 = rootPart()
            local t0 = os.clock()
            local limit = r0 and (point - r0.Position).Magnitude / math.max(speed, 1) + 10 or 0
            local reached = false
            while alive() and token == tpToken and os.clock() - t0 < limit do
                local dt = RunService.Heartbeat:Wait()
                local r = rootPart()
                if not r then
                    break
                end
                local delta = point - r.Position
                local d = delta.Magnitude
                if d < 2 then
                    r.CFrame = CFrame.new(point) * look
                    r.AssemblyLinearVelocity = Vector3.zero
                    reached = true
                    break
                end
                local step = math.min(d, speed * dt)
                r.CFrame = CFrame.new(r.Position + delta.Unit * step) * look
                r.AssemblyLinearVelocity = Vector3.zero
            end
            if not reached then
                arrived = false
                break
            end
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

-- Keeps you at `cf` for `seconds` (hovering, no falling), or until `done()`.
local function holdAt(cf, seconds, done)
    local t0 = os.clock()
    while alive() and os.clock() - t0 < seconds do
        local r = rootPart()
        if not r then
            return false
        end
        r.CFrame = cf
        r.AssemblyLinearVelocity = Vector3.zero
        if done and done() then
            return true
        end
        RunService.Heartbeat:Wait()
    end
    return done == nil or done()
end

-- A spot `gap` studs from `pos`, on your side of it.
local function besideOf(pos, gap)
    local hrp = rootPart()
    local away = hrp and (hrp.Position - pos) or Vector3.new(0, 0, 1)
    away = Vector3.new(away.X, 0, away.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    return pos + away * gap
end

-- Mobs that can hurt you within `radius` of `pos`.
local function foesNear(pos, radius)
    local list = {}
    for model in Index.mobs do
        if model.Parent then
            local kind = mobKind(model)
            if kind == "Hostile" or kind == "Can attack" then
                local p = mobPos(model)
                if p and (p - pos).Magnitude <= radius then
                    table.insert(list, p)
                end
            end
        end
    end
    return list
end

-- A spot `gap` studs from `pos` on the side furthest from any mob nearby.
local function safeSpotNear(pos, gap)
    local foes = foesNear(pos, 40)
    if #foes == 0 then
        return besideOf(pos, gap)
    end
    local best, bestScore
    for i = 0, 7 do
        local angle = i * math.pi / 4
        local spot = pos + Vector3.new(math.cos(angle) * gap, 0, math.sin(angle) * gap)
        local score = math.huge
        for _, foe in foes do
            score = math.min(score, (foe - spot).Magnitude)
        end
        if not bestScore or score > bestScore then
            best, bestScore = spot, score
        end
    end
    return best
end

-- How the runs (chest run, kid rescue) travel: faster than a plain teleport
-- tween, over the top of mobs.
local function runOpts(extra)
    local opts = { speed = Settings.RunSpeed, high = Settings.RunHigh }
    for k, v in extra or {} do
        opts[k] = v
    end
    return opts
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
    return chest:GetAttribute("LocalOpened") or chest:GetAttribute(math.abs(UID) .. "Opened")
end

local function openableChest(chest)
    return chest.Parent ~= nil and isChest(chest) and not chest:GetAttribute("Locked") and not chestOpened(chest)
end

-- Every chest, numbered once so a label keeps pointing at the same chest.
local ChestIds, nextChestId = setmetatable({}, { __mode = "k" }), 0
local function chestTargets()
    local list, order, found = {}, {}, {}
    for model in Index.chests do
        if model.Parent then
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

local function nearestOpenableChest(skip)
    local best, bestD
    for chest in Index.chests do
        if openableChest(chest) and not (skip and skip[chest]) then
            local d = distanceTo(pivotPos(chest))
            if not bestD or d < bestD then
                best, bestD = chest, d
            end
        end
    end
    return best
end

--// Kids \\--
local function isKid(model)
    return model:GetAttribute("KidId") ~= nil or model:GetAttribute("NPCType") == "Lost Child"
end

local function liveKid(kidId)
    for model in Index.kids do
        if model.Parent and model:GetAttribute("KidId") == kidId and model:GetAttribute("Lost") ~= false then
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
    for model in Index.kids do
        local kidId = model:GetAttribute("KidId")
        if kidId and model.Parent and model:GetAttribute("Lost") ~= false and (kids[kidId] or not missing) then
            local pos = mobPos(model)
            if pos then
                kids[kidId] = { pos = pos, live = true, name = model:GetAttribute("PingName"), model = model }
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

--// Items: types by what they do, so new items sort themselves \\--
local ITEM_KINDS = { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Keys", "Other" }
local HEAL_NAMES = { Bandage = true, MedKit = true }

local function mineOrFree(model)
    local owner = model:GetAttribute("Owner")
    return owner == nil or owner == UID
end

-- nil for things that aren't loose items (chests, unknown models).
local function itemKind(model)
    local interaction = model:GetAttribute("Interaction")
    if interaction == nil or interaction == "ItemChest" then
        return nil
    end
    if interaction == "Currency" then
        return "Currency"
    end
    if model:GetAttribute("RestoreHealth") and not model:GetAttribute("RestoreHunger") or HEAL_NAMES[cleanName(model.Name)] then
        return "Heals"
    elseif model:HasTag("Gem") or model:HasTag("GreenGem") or model:HasTag("GreenGemPiece") then
        return "Gems"
    elseif model:GetAttribute("AmmoType") or model:GetAttribute("RifleAmmo") or model:GetAttribute("RevolverAmmo")
        or model:GetAttribute("ShotgunAmmo") then
        return "Ammo"
    elseif model:GetAttribute("RestoreHunger") or model:GetAttribute("Cookable") then
        return "Food"
    elseif interaction == "Tool" or interaction == "Armour" then
        return "Gear"
    elseif model:HasTag("Plantable") or model:HasTag("SeedBox") or model:HasTag("Acorn") then
        return "Seeds"
    elseif model:HasTag("JungleKey") or model:HasTag("KeyModel") then
        return "Keys"
    elseif model:GetAttribute("BurnFuel") then
        return "Fuel"
    elseif model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded") then
        return "Scrap"
    end
    return "Other"
end

local function isFood(model)
    local bunny = LocalPlayer:GetAttribute("Class") == "Bunny"
    return model:GetAttribute("RestoreHunger") ~= nil and not model:GetAttribute("FoodRot")
        and not (bunny and model:GetAttribute("HasMeat"))
end

local function isHeal(model)
    return model:GetAttribute("RestoreHealth") ~= nil or HEAL_NAMES[cleanName(model.Name)] == true
end

-- Index upkeep ---------------------------------------------------------------------
-- kindNames[kind][name] = how many of that item lie on the map, so the bring
-- pickers can list a category's items without walking the whole folder.
local kindNames = {}
local onItemAdded -- chest loot watcher, set further down
local watchChest -- set further down
do

local function setAdd(map, key, model)
    local set = map[key]
    if not set then
        set = {}
        map[key] = set
    end
    set[model] = true
end

local function countName(kind, name, delta)
    local names = kindNames[kind]
    if not names then
        names = {}
        kindNames[kind] = names
    end
    local n = (names[name] or 0) + delta
    if n <= 0 then
        names[name] = nil
        Index.namesVersion += 1
    else
        if not names[name] then
            Index.namesVersion += 1
        end
        names[name] = n
    end
end

local function indexItem(model)
    if Index.items[model] or Index.chests[model] or model.Parent ~= itemsFolder() then
        return
    end
    if isChest(model) then
        Index.chests[model] = true
        if watchChest then
            watchChest(model)
        end
        return
    end
    local kind = itemKind(model)
    if not kind then
        return
    end
    local name = cleanName(model.Name)
    Index.items[model] = { kind = kind, name = name }
    setAdd(Index.byKind, kind, model)
    setAdd(Index.byName, name, model)
    countName(kind, name, 1)
    if onItemAdded then
        onItemAdded(model, kind)
    end
end

local function unindexItem(model)
    Index.chests[model] = nil
    local entry = Index.items[model]
    if not entry then
        return
    end
    Index.items[model] = nil
    local set = Index.byKind[entry.kind]
    if set then
        set[model] = nil
    end
    set = Index.byName[entry.name]
    if set then
        set[model] = nil
        if next(set) == nil then
            Index.byName[entry.name] = nil
        end
    end
    countName(entry.kind, entry.name, -1)
end

local function indexMob(model)
    if not model:IsA("Model") then
        return
    end
    Index.mobs[model] = true
    if isKid(model) then
        Index.kids[model] = true
    end
end

local function unindexMob(model)
    Index.mobs[model] = nil
    Index.kids[model] = nil
end

task.spawn(function()
    local items = Workspace:WaitForChild("Items", 30)
    if items and alive() then
        bind(items.ChildAdded, function(model)
            -- Attributes replicate with the model, but a defer keeps any that
            -- the game sets in the same frame.
            task.defer(indexItem, model)
        end)
        bind(items.ChildRemoved, unindexItem)
        for i, model in items:GetChildren() do
            indexItem(model)
            if i % 2000 == 0 then
                task.wait()
            end
        end
    end
end)

task.spawn(function()
    local folder = Workspace:WaitForChild("Characters", 30)
    if folder and alive() then
        bind(folder.ChildAdded, function(model)
            task.defer(indexMob, model)
        end)
        bind(folder.ChildRemoved, unindexMob)
        for _, model in folder:GetChildren() do
            indexMob(model)
        end
    end
end)
end

-- Items of `kind` ("All" or nil for every kind), with how many of each lie around.
local function namesIn(kind)
    local out, counts = {}, {}
    for k, names in kindNames do
        if (kind == nil or kind == "All" or k == kind) and k ~= "Currency" then
            for name, n in names do
                if not counts[name] then
                    table.insert(out, name)
                end
                counts[name] = (counts[name] or 0) + n
            end
        end
    end
    table.sort(out)
    return out, counts
end

local function itemNames()
    return (namesIn(nil))
end

local function nearestItemNamed(name)
    local best, bestD
    for model in Index.byName[name] or {} do
        if model.Parent then
            local d = distanceTo(pivotPos(model))
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best
end

--// Structures \\--
local function structuresFolder()
    return Workspace:FindFirstChild("Structures")
end

local function nearestStructure(test)
    local folder = structuresFolder()
    local best, bestD
    for _, model in folder and folder:GetChildren() or {} do
        if test(model) then
            local d = distanceTo(pivotPos(model))
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best
end

local function rainStorage()
    return nearestStructure(function(model)
        return model.Name == "Wood Rain Storage"
    end)
end

local function tagged(tag)
    local ok, list = pcall(function()
        return game:GetService("CollectionService"):GetTagged(tag)
    end)
    return ok and list or {}
end

--// Bring \\--
-- The game's own drag: RequestStartDraggingItem hands you the item, you move
-- it, StopDraggingItem gives it back. Fast mode starts, moves and releases
-- many items per frame and moves each again right before release, so it lands
-- even when the hand-over is a frame late. Safe mode does one at a time and
-- waits for the hand-over.
local BRING_DESTS = { "You", "Camp fire", "Cook at fire", "Crafting bench", "Rain storage", "Saved spot" }
local Bring = { token = 0, done = 0, total = 0, running = false }

local function bringTarget(dest)
    local hrp = rootPart()
    if dest == "Camp fire" or dest == "Cook at fire" then
        local fire = campPart("MainFire")
        local center = fire and (fire:FindFirstChild("Center") or fire:FindFirstChild("InnerTouchZone"))
        local pos = center and (center:IsA("BasePart") and center.Position or pivotPos(center)) or pivotPos(fire)
        return pos and CFrame.new(pos + Vector3.new(0, 4, 0))
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local zone = bench and bench:FindFirstChild("TouchZone")
        local pos = zone and zone.Position or pivotPos(bench)
        return pos and CFrame.new(pos + Vector3.new(0, 3, 0))
    elseif dest == "Rain storage" then
        local storage = rainStorage()
        local zone = storage and storage:FindFirstChild("TouchZone", true)
        local pos = zone and zone.Position or pivotPos(storage)
        return pos and CFrame.new(pos + Vector3.new(0, 3, 0))
    elseif dest == "Saved spot" then
        return Settings.SavedSpot
    end
    return hrp and (hrp.CFrame * CFrame.new(0, 1, -7))
end

-- Spread items in a grid so a big pile doesn't explode. The fire, bench and
-- storage want them close together so they land in the touch zone.
local function slotOffset(i, dest)
    local spacing = dest == "You" and 1.8 or dest == "Saved spot" and 1.8 or 0.8
    local r = (i - 1) % 36
    local layer = (i - 1) // 36
    return Vector3.new((r % 6 - 2.5) * spacing, layer * spacing, (r // 6 - 2.5) * spacing)
end

local BRING_SORTS = {
    ["Nearest first"] = function(a, b)
        return a.d < b.d
    end,
    ["Farthest first"] = function(a, b)
        return a.d > b.d
    end,
    -- Fuel: the most burn time per trip first (oil barrel, canister, coal, logs).
    ["Strongest first"] = function(a, b)
        if a.fuel ~= b.fuel then
            return a.fuel > b.fuel
        end
        return a.d < b.d
    end,
    ["Weakest first"] = function(a, b)
        if a.fuel ~= b.fuel then
            return a.fuel < b.fuel
        end
        return a.d < b.d
    end,
}

-- What to bring:
--   kinds   { [kind] = true } or nil for every kind
--   names   { [name] = true }; when it has entries only those names come
--   exclude { [name] = true }
--   filter  fn(model) -> bool
--   list    exact models (chest loot)
--   order   a BRING_SORTS key
--   at      a CFrame to bring to instead of the destination's own spot
local function bringList(what, dest, limit)
    local hrp = rootPart()
    local target = what.at or bringTarget(dest)
    if not hrp or not target then
        return {}
    end
    local exclude = what.exclude or {}
    local names = what.names and next(what.names) and what.names or nil
    local sources = {}
    if what.list then
        local set = {}
        for _, model in what.list do
            set[model] = true
        end
        sources = { set }
    elseif names then
        for name in names do
            table.insert(sources, Index.byName[name] or {})
        end
    elseif what.kinds then
        for kind in what.kinds do
            table.insert(sources, Index.byKind[kind] or {})
        end
    else
        sources = { Index.items }
    end

    local list, seen = {}, {}
    for _, set in sources do
        for model in set do
            local entry = Index.items[model]
            if entry and not seen[model] and model.Parent and model:GetAttribute("Interaction") ~= nil then
                seen[model] = true
                local wanted = entry.kind ~= "Currency" and not exclude[entry.name]
                if wanted and names and what.kinds and not what.kinds[entry.kind] then
                    wanted = false
                end
                if wanted and what.filter then
                    wanted = what.filter(model)
                end
                if wanted and mineOrFree(model) then
                    local pos = pivotPos(model)
                    local d = pos and (pos - hrp.Position).Magnitude
                    local atTarget = pos and (pos - target.Position).Magnitude < 12
                    if d and (what.list or d <= Settings.BringRange) and not (Settings.BringSkipNear and atTarget) then
                        table.insert(list, { model = model, d = d, fuel = model:GetAttribute("BurnFuel") or 0 })
                    end
                end
            end
        end
    end
    table.sort(list, BRING_SORTS[what.order or Settings.BringOrder] or BRING_SORTS["Nearest first"])
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

local function fireHasFuel(fire)
    return (fire:GetAttribute("FuelRemaining") or 0) > 0
end

-- What the fire, bench and storage do with an item that arrives, through the
-- same remotes their touch zones use.
local function arrive(model, dest)
    if dest == "Camp fire" or dest == "Cook at fire" then
        local fire = campPart("MainFire")
        if not fire then
            return
        end
        if model:GetAttribute("Cookable") and fireHasFuel(fire) then
            local r = remote("RequestCookItem")
            if r then
                r:FireServer(fire, model)
            end
        elseif dest == "Camp fire" and model:GetAttribute("BurnFuel") and (model:GetAttribute("Wet") or 0) < 1 then
            local r = remote("RequestBurnItem")
            if r then
                r:FireServer(fire, model)
            end
        end
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local r = remote("RequestScrapItem")
        if bench and r and (model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded")) then
            task.spawn(pcall, r.InvokeServer, r, bench, model)
        end
    elseif dest == "Rain storage" then
        local storage = rainStorage()
        local r = remote("RequestRainStorageDry")
        if storage and r then
            r:FireServer(model, storage)
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

-- The pickers on the Bring tab: one category, and the items in it (none
-- picked = the whole category).
local ALL_ITEMS = "★ All of them"
local function currentBringWhat()
    local category = Settings.BringCategory or "All"
    local picks = Settings.BringPicks[category]
    if picks and picks[ALL_ITEMS] then
        picks = nil
    end
    return {
        kinds = category ~= "All" and { [category] = true } or nil,
        names = picks,
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
        local base = what.at or bringTarget(dest)
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

-- Moves one item next to `pos` with the drag and waits for the hand-over, for
-- the helpers that need an item somewhere before calling a remote on it.
local function carryTo(model, pos)
    local start, stop = remote("RequestStartDraggingItem"), remote("StopDraggingItem")
    if not start or not stop or not model.Parent then
        return false
    end
    local cf = CFrame.new(pos)
    start:FireServer(model)
    placeItem(model, cf)
    task.wait(math.max(Settings.BringHold, 80) / 1000)
    placeItem(model, cf)
    stop:FireServer(model)
    return true
end

--// Chest loot \\--
-- A chest's loot lands in Workspace.Items right next to it within a few
-- seconds of opening. Items that appear like that are queued and brought to
-- the chosen place.
local RecentChests = setmetatable({}, { __mode = "k" })
local LootQueue = {}
-- During a chest run, loot sent to "You" goes to where the run started, not
-- to wherever the run has flown to by then.
local LootAnchor = { cf = nil, untilT = 0 }

local function noteChestOpened(chest)
    local pos = pivotPos(chest)
    if pos then
        RecentChests[chest] = { pos = pos, t = os.clock() }
    end
end

watchChest = function(chest)
    local was = chestOpened(chest)
    local function check()
        local now = chestOpened(chest)
        if now and not was then
            noteChestOpened(chest)
        end
        was = now
    end
    bind(chest:GetAttributeChangedSignal(math.abs(UID) .. "Opened"), check)
    bind(chest:GetAttributeChangedSignal("LocalOpened"), check)
    bind(chest.AncestryChanged, function()
        -- Some chests (costume boxes) are removed as they open.
        if not chest.Parent and not was then
            noteChestOpened(chest)
        end
    end)
end

onItemAdded = function(model, kind)
    if not Settings.ChestLoot or not Settings.ChestLootKinds[kind] then
        return
    end
    local pos = pivotPos(model)
    if not pos then
        return
    end
    local now = os.clock()
    for chest, info in RecentChests do
        if now - info.t < 8 and (pos - info.pos).Magnitude < 16 then
            LootQueue[model] = now
            return
        end
    end
end

local function pumpLoot()
    if not Settings.ChestLoot or Bring.running or next(LootQueue) == nil then
        return
    end
    local list, now = {}, os.clock()
    for model, t in LootQueue do
        -- A short wait lets the loot finish spilling out of the chest.
        if now - t > 0.6 then
            LootQueue[model] = nil
            if model.Parent then
                table.insert(list, model)
            end
        end
    end
    if #list > 0 then
        local at = Settings.ChestLootDest == "You" and LootAnchor.cf and os.clock() < LootAnchor.untilT and LootAnchor.cf or nil
        runBring({ list = list, at = at }, Settings.ChestLootDest, #list)
    end
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

-- The game opens every chest with this remote once its prompt finishes,
-- including the ones marked NotClickable (stone and jungle chests).
local function openChest(chest)
    local r = remote("RequestOpenItemChest")
    if r then
        r:FireServer(chest)
        chest:SetAttribute("LocalOpened", true)
        noteChestOpened(chest)
        return true
    end
    local prompt = chestPrompt(chest)
    if prompt and typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        noteChestOpened(chest)
        return true
    end
    return false
end

local function openChestsInRange()
    local hrp = rootPart()
    if not hrp then
        return
    end
    for chest in Index.chests do
        if openableChest(chest) then
            local pos = pivotPos(chest)
            if pos and (pos - hrp.Position).Magnitude <= 12 and tryOnce(chest, 5) then
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

local function bagContents()
    local folder = LocalPlayer:FindFirstChild("ItemBag")
    return folder and folder:GetChildren() or {}
end

local function kidsInBag()
    local n = 0
    for _, item in bagContents() do
        if item:GetAttribute("KidId") then
            n += 1
        end
    end
    return n
end

-- Free sack slots, from the game's own count when it can be read.
local function sackSpace()
    local bag = itemBag()
    if not bag then
        return 0
    end
    local util = gameModule("Utility")
    local ok, total = pcall(function()
        return util.GetItemBagSpace(bag, LocalPlayer)
    end)
    total = ok and tonumber(total) or bag:GetAttribute("Capacity") or 5
    local okUsed, used = pcall(function()
        return util.GetItemBagUsedSpace(bagContents(), LocalPlayer)
    end)
    used = okUsed and tonumber(used) or #bagContents()
    return math.max(0, total - used)
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
    local hrp = rootPart()
    if not hrp or not itemBag() then
        return
    end
    for model in Index.kids do
        if model.Parent and canBag(model) then
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

local survivalTick
do
local function collectCurrency()
    local hrp = rootPart()
    if not hrp then
        return
    end
    local coins, diamonds = remote("RequestCollectCoints"), remote("RequestTakeDiamonds")
    for model in Index.byKind.Currency or {} do
        if model.Parent and not model:GetAttribute("Destroyed") then
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

-- Eats or heals with the nearest matching item of `kind` in reach.
local function consumeNearest(filter, kinds)
    local hrp = rootPart()
    local r = remote("RequestConsumeItem")
    if not hrp or not r then
        return false
    end
    local best, bestD
    for _, kind in kinds do
        for model in Index.byKind[kind] or {} do
            if model.Parent and filter(model) and mineOrFree(model) then
                local pos = pivotPos(model)
                local d = pos and (pos - hrp.Position).Magnitude
                if d and d <= Settings.ConsumeRange and (not bestD or d < bestD) then
                    best, bestD = model, d
                end
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
local function consumeOrFetch(filter, kinds, fetch)
    if consumeNearest(filter, kinds) then
        return true
    end
    if fetch and not Bring.running and os.clock() - lastFetch > 3 then
        lastFetch = os.clock()
        local set = {}
        for _, kind in kinds do
            set[kind] = true
        end
        runBring({ kinds = set, filter = filter }, "You", 1)
    end
    return false
end

local FOOD_KINDS, HEAL_KINDS = { "Food" }, { "Heals", "Food" }

local lastEat, lastHeal, lastFeed, lastScrap = 0, 0, 0, 0
function survivalTick()
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
    pumpLoot()
    local now = os.clock()
    if Settings.AutoEat and now - lastEat > 1.5 and (LocalPlayer:GetAttribute("Hunger") or 200) < Settings.EatBelow then
        if consumeOrFetch(isFood, FOOD_KINDS, Settings.EatBring) then
            lastEat = now
        end
    end
    local hum = humanoid()
    if Settings.AutoHeal and hum and hum.Health > 0 and now - lastHeal > 1.5 and healthPercent() < Settings.HealBelow then
        if consumeOrFetch(isHeal, HEAL_KINDS, Settings.HealBring) then
            lastHeal = now
        end
    end
    if Settings.KeepFireFed and now - lastFeed > 8 and not Bring.running then
        local fire = campPart("MainFire")
        local fuel = fire and fire:GetAttribute("FuelRemaining")
        if fuel and fuel < Settings.FireBelow then
            lastFeed = now
            runBring({
                kinds = { Fuel = true },
                exclude = Settings.BringExclude,
                order = Settings.FuelOrder,
                filter = function(model)
                    return (model:GetAttribute("Wet") or 0) < 1
                end,
            }, "Camp fire", 6)
        end
    end
    if Settings.KeepScrapping and now - lastScrap > 20 and not Bring.running then
        lastScrap = now
        runBring({ kinds = { Scrap = true }, exclude = Settings.BringExclude }, "Crafting bench", 20)
    end
end
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
local goToCamp, treeFarm, rescueKids, chestRun, safetyTick
-- In their own function, like the feature module, so their helpers don't
-- crowd the main chunk's 200 locals.
;(function()

function goToCamp(still)
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

function treeFarm(still)
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

-- Kid rescue: fill the sack with as many kids as it holds (nearest next each
-- time), then one trip to camp drops them all. Dropping doesn't wait for the
-- server to mark them rescued; those kids are just never visited again.
function rescueKids(still)
    local start = rootPart() and rootPart().Position
    local rescued, failed, done = 0, {}, {}
    local function inBag()
        local ids = {}
        for _, item in bagContents() do
            local id = item:GetAttribute("KidId")
            if id then
                ids[id] = true
            end
        end
        return ids
    end
    local function dropAll()
        if not goToCamp(still) then
            return false
        end
        local carried = inBag()
        setStatus("Dropping kids at camp")
        dropKidsAtCamp(true)
        waitFor(1.5, function()
            return kidsInBag() == 0
        end, still)
        for id in carried do
            done[id] = true
            rescued += 1
            if logEvent then
                logEvent("Rescued " .. spaced(id), Color3.fromRGB(255, 220, 80))
            end
        end
        return true
    end
    while still() do
        if not itemBag() then
            setStatus("You need a sack in your inventory to carry kids")
            notify("Kid rescue", "You need a sack in your inventory", 4)
            return
        end
        local carrying = inBag()
        local hrp = rootPart()
        local pick, pickD, pickInfo
        for kidId, info in kidPositions() do
            if not failed[kidId] and not done[kidId] and not carrying[kidId] then
                local d = hrp and (info.pos - hrp.Position).Magnitude or 0
                if not pickD or d < pickD then
                    pick, pickD, pickInfo = kidId, d, info
                end
            end
        end
        local full = sackSpace() <= 0
        if (not pick or full) and next(carrying) then
            if not dropAll() then
                return
            end
        elseif not pick then
            break
        elseif full then
            setStatus("Your sack is full: empty it first")
            notify("Kid rescue", "Your sack is full: empty it first", 5)
            return
        else
            local name = pickInfo.name or spaced(pick)
            setStatus("Going to " .. name)
            local unknown = not pickInfo.live and pickInfo.pos.Y == 0
            if not moveTo(pickInfo.pos, runOpts({ unknownHeight = unknown })) or not still() then
                return
            end
            setStatus("Looking for " .. name)
            local model
            waitFor(3, function()
                model = liveKid(pick)
                return model ~= nil
            end, still)
            if not model then
                failed[pick] = "not found at its map point"
            elseif not canBag(model) then
                failed[pick] = "can't be picked up yet"
            else
                local before = kidsInBag()
                moveTo(safeSpotNear(mobPos(model), 3), runOpts())
                setStatus("Picking up " .. name)
                local got = waitFor(4, function()
                    if tryOnce(model, 0.75) then
                        bagKid(model)
                    end
                    return kidsInBag() > before or model.Parent == nil
                end, still)
                if not got then
                    failed[pick] = "the sack wouldn't take it"
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
    if still() and rescued == 0 and start then
        moveTo(start, runOpts())
    end
    setStatus(text)
    notify("Kid rescue", text, 6)
end

-- Chest run: hover just above each chest that can still be opened (nearest
-- next), open it and move straight on: the loot is brought separately (see
-- Chest loot), so nothing waits for it. Travel goes over the top of mobs and
-- chests with mobs right next to them can be skipped.
function chestRun(still)
    local hrp = rootPart()
    local start = hrp and hrp.CFrame
    if start then
        LootAnchor.cf = start * CFrame.new(0, 1, -7)
        LootAnchor.untilT = os.clock() + 900
    end
    local opened, skipped, guarded = 0, setmetatable({}, { __mode = "k" }), 0
    while still() do
        local best = nearestOpenableChest(skipped)
        if not best then
            break
        end
        skipped[best] = true
        local pos = pivotPos(best)
        local name = best:GetAttribute("ChestName") or cleanName(best.Name)
        if pos and Settings.SkipGuarded and #foesNear(pos, Settings.GuardRadius) > 0 and not Settings.KillAura then
            guarded += 1
        elseif pos then
            setStatus(string.format("Chest run: %s (%d opened)", name, opened))
            local spot = safeSpotNear(pos, 2.5) + Vector3.new(0, 5, 0)
            if moveTo(spot, runOpts({ exact = true })) and still() then
                local here = CFrame.new(spot)
                -- Every chest in reach, not just the one we came for.
                for chest in Index.chests do
                    local p = openableChest(chest) and pivotPos(chest)
                    if p and (p - spot).Magnitude <= 12 then
                        openChest(chest)
                        skipped[chest] = true
                        opened += 1
                    end
                end
                holdAt(here, 0.15)
            end
        end
    end
    local text = string.format("Chest run done: %d opened", opened)
    if guarded > 0 then
        text ..= string.format(" · %d skipped (mobs next to them)", guarded)
    end
    setStatus(text)
    notify("Chest run", text)
    if Settings.ReturnAfterRun and start and still() then
        moveTo(start.Position, runOpts())
    end
    -- Loot from the last chests is still landing: keep sending it to the start.
    LootAnchor.untilT = os.clock() + 10
end

-- Night safety and low health escape, checked from the survival loop.
local lastEscape = 0
local wasNight = nil
function safetyTick()
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
end)()

--// Farm, events and helpers from version 720 \\--
-- Each helper is one small tick, run from a shared loop below, and every one
-- goes through the same calls the game's own client makes (see the header).
-- Runs in its own function so its many locals don't crowd the main chunk
-- (Luau allows 200 locals per function).
local Feat, fire = (function()
local Feat = {}
local fire

-- Finds one of the game's live tool objects (fishing rod, taming flute) in
-- memory. getgc is slow, so callers cache the result and only look again
-- every few seconds while the tool is in use.
local function findGameObject(test)
    if typeof(getgc) ~= "function" then
        return nil
    end
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then
        return nil
    end
    for _, v in list do
        if type(v) == "table" then
            local good, hit = pcall(test, v)
            if good and hit then
                return v
            end
        end
    end
    return nil
end

local function interface(name)
    local ui = gameModule("Interface")
    local ok, frame = pcall(function()
        return ui[name]
    end)
    if ok and frame then
        return frame
    end
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    return gui and gui:FindFirstChild(name, true)
end

-- The two bars of a timing mini game: the moving bar and the green zone.
local function barOverlap(frame)
    local zone = frame.TimingBar.SuccessArea
    local bar = frame.TimingBar.Bar
    local z0, z1 = zone.AbsolutePosition.Y, zone.AbsolutePosition.Y + zone.AbsoluteSize.Y
    local b0, b1 = bar.AbsolutePosition.Y, bar.AbsolutePosition.Y + bar.AbsoluteSize.Y
    return (z0 < b1 and b0 < z0) or (b0 < z1 and z1 < b1) or (z0 < b0 and b1 < z1)
end

local function nearestNamed(names, near)
    local best, bestD
    for name in names do
        for model in Index.byName[name] or {} do
            if model.Parent and mineOrFree(model) and not model:GetAttribute("FoodRot") then
                local pos = pivotPos(model)
                local d = pos and (pos - near).Magnitude
                if d and (not bestD or d < bestD) then
                    best, bestD = model, d
                end
            end
        end
    end
    return best
end

local function invoke(name, ...)
    local r = remote(name)
    if not r then
        return nil
    end
    local ok, result = pcall(r.InvokeServer, r, ...)
    return ok and result or nil
end

function fire(name, ...)
    local r = remote(name)
    if r then
        r:FireServer(...)
        return true
    end
    return false
end

local function campGems()
    local camp = mapFolder("Campground")
    return camp and camp:GetAttribute("TotalGems") or 0
end

-- Cooking --------------------------------------------------------------------------
local lastCook = 0
function Feat.cookTick()
    if not Settings.AutoCook or Bring.running or os.clock() - lastCook < 3 then
        return
    end
    local fire = campPart("MainFire")
    if not fire or not fireHasFuel(fire) then
        return
    end
    lastCook = os.clock()
    runBring({
        filter = function(model)
            return model:GetAttribute("Cookable") ~= nil
        end,
    }, "Cook at fire", 10)
end

-- Everything the game's crockpot refuses (finished meals and a few raw items).
local CROCKPOT_BANNED = {}
for _, name in {
    "Stew", "Berry", "Chilli", "Hearty Stew", "Shark", "Seafood Chowder", "Steak Dinner", "Pumpkin Soup", "BBQ Ribs",
    "Carrot Cake", "Jar o' Jelly", "Candy Apple", "Cotton Candy", "Pumpkin Pie", "Candy Corn", "Turkey Legs", "Casserole",
    "Berry Juice", "Roast Turkey", "Corn on the Cob", "Stuffed Peppers", "Stuffing Bowl", "Sweet Potato Pie",
    "Spicy Swordfish", "Hearty Thanksgiving Meal", "Strawberry", "Candied Meat", "Meat? Sandwich", "Giant Lollypop", "Rock Cake",
} do
    CROCKPOT_BANNED[name] = true
end

local function crockpotIngredient(model)
    local name = cleanName(model.Name)
    return (model:GetAttribute("RestoreHunger") or model:GetAttribute("CrockpotIngredient"))
        and not CROCKPOT_BANNED[name] and not name:find("Shark")
        and not model:GetAttribute("CrockPotBanned") and not model:GetAttribute("PreparedMeal")
        and model:GetAttribute("ToolName") ~= "Consumable" and not model:GetAttribute("FoodRot")
end

local busyPot = setmetatable({}, { __mode = "k" })
function Feat.crockpotTick()
    if not Settings.AutoCrockpot then
        return
    end
    local chef = LocalPlayer:GetAttribute("Class") == "Chef"
    for _, pot in tagged("Crockpot") do
        local zone = pot:FindFirstChild("TouchZone")
        if zone and pot:IsDescendantOf(Workspace) and not busyPot[pot]
            and (pot.Name ~= "Chefs Station" or chef)
            and (pot:GetAttribute("Ingredients") or 0) < 3 and not pot:GetAttribute("Cooking") and not pot:GetAttribute("CanTake") then
            local best, bestD
            for model in Index.byKind.Food or {} do
                if model.Parent and mineOrFree(model) and crockpotIngredient(model) then
                    local d = (pivotPos(model) - zone.Position).Magnitude
                    if d <= Settings.BringRange and (not bestD or d < bestD) then
                        best, bestD = model, d
                    end
                end
            end
            if best then
                busyPot[pot] = true
                task.spawn(function()
                    if carryTo(best, zone.Position + Vector3.new(0, 1, 0)) then
                        invoke("RequestCrockpotItem", pot, best)
                    end
                    task.wait(0.5)
                    busyPot[pot] = nil
                end)
            end
        end
    end
end

-- Fishing --------------------------------------------------------------------------
-- The rod object is ReplicatedStorage.Tools["Fishing Rod"] made with .new: it
-- has Model, RealModel, State, CatchCount and the Pull/Cast/Reel methods. The
-- game makes a fresh one every time the rod is equipped (OnEquip sets its
-- Equipped field), so the one in hand is the one with Equipped == true.
local heldCache, heldAt = nil, -1
local function heldToolNow()
    local handler = gameModule("InventoryHandler")
    local ok, tool = pcall(function()
        return handler.GetCurrentlyEquipped()
    end)
    if ok and typeof(tool) == "Instance" then
        return tool
    end
    local name = equippedName()
    local inv = inventory()
    return name and inv and inv:FindFirstChild(name) or nil
end
-- Asked every frame by the fishing and flute helpers, so read a few times a second.
local function heldTool()
    if os.clock() - heldAt > 0.2 then
        heldCache, heldAt = heldToolNow(), os.clock()
    end
    return heldCache
end
Feat.heldTool = heldTool

local function holding(toolName)
    local tool = heldTool()
    return tool ~= nil and (tool:GetAttribute("ToolName") == toolName or tostring(tool.Name):find(toolName == "Fishing Rod" and "Rod" or "Flute") ~= nil)
end

local Rod, lastRodScan = nil, 0
local function isRod(t)
    if rawget(t, "CatchCount") == nil or rawget(t, "RealModel") == nil then
        return false
    end
    local mt = getmetatable(t)
    return type(mt) == "table" and type(rawget(mt, "Pull")) == "function"
end

-- The rod object for the tool in hand (when the hand can be read).
local function liveRod()
    local held = heldTool()
    local function good(t)
        return isRod(t) and rawget(t, "Equipped") == true and (held == nil or t.RealModel == held)
    end
    if Rod and good(Rod) and Rod.RealModel.Parent then
        return Rod
    end
    if os.clock() - lastRodScan < 1.5 then
        return nil
    end
    lastRodScan = os.clock()
    Rod = findGameObject(good)
    return Rod
end

local hookedRod, hookedItem, hookedAt = nil, nil, 0
function Feat.fishingStep()
    if not (Settings.PerfectFishing or Settings.InstantCatch or Settings.AutoRecast) then
        return
    end
    local frame = interface("FishingCatchFrame")
    local catching = frame and frame.Visible
    -- Only look for the rod while it matters: a fish on the line, or a rod in hand to recast.
    if not catching and not (Settings.AutoRecast and holding("Fishing Rod")) then
        return
    end
    local rod = liveRod()
    if not rod then
        return
    end
    if rod ~= hookedRod or rod.HookedItem ~= hookedItem then
        hookedRod, hookedItem, hookedAt = rod, rod.HookedItem, os.clock()
    end
    if rod.State == "Fishing" and rod.HookedItem and not rod.ItemCaught then
        if Settings.InstantCatch and os.clock() - hookedAt >= Settings.InstantCatchDelay then
            -- What a full catch bar does: mark it caught, tell the server, reel in.
            rod.ItemCaught = true
            fire("ConfirmCatchItem")
            pcall(rod.Reel, rod)
        elseif Settings.PerfectFishing and catching and not rod.AlreadyClickedThisPass and barOverlap(frame) then
            pcall(rod.Pull, rod)
        end
    end
    if Settings.AutoRecast and rod.State == "Idle" and time() >= (rod.LastCast or 0) + (rod.Cooldown or 0.5) + 1.2 then
        pcall(rod.Activate, rod)
    end
end

-- Fish hotspots (tag FishHotspot) are the bubbling patches; Active ones bite.
function Feat.fishingSpots()
    local list, order = {}, {}
    local found = {}
    for _, spot in tagged("FishHotspot") do
        if spot:IsA("BasePart") and spot:IsDescendantOf(Workspace) then
            local owner = spot:FindFirstAncestorWhichIsA("Model")
            local base = owner and (owner:GetAttribute("FullLandmarkName") or cleanName(owner.Name)) or "Fishing spot"
            table.insert(found, { spot = spot, base = base, active = spot:GetAttribute("Active") == true, d = distanceTo(spot.Position) })
        end
    end
    table.sort(found, function(a, b)
        if a.active ~= b.active then
            return a.active
        end
        return a.d < b.d
    end)
    local counts = {}
    for _, entry in found do
        counts[entry.base] = (counts[entry.base] or 0) + 1
        local label = string.format("%s %d%s · %dm", entry.base, counts[entry.base], entry.active and " (active)" or "", math.floor(entry.d))
        list[label] = entry.spot
        table.insert(order, label)
    end
    return list, order
end

-- Somewhere dry to stand next to the water at `pos`.
local ShoreParams = RaycastParams.new()
ShoreParams.FilterType = Enum.RaycastFilterType.Exclude
function Feat.shoreNear(pos)
    ShoreParams.FilterDescendantsInstances = { character(), charactersFolder(), itemsFolder() }
    for _, gap in { 10, 16, 22, 30, 40 } do
        for i = 0, 7 do
            local angle = i * math.pi / 4
            local probe = pos + Vector3.new(math.cos(angle) * gap, 60, math.sin(angle) * gap)
            local hit = Workspace:Raycast(probe, Vector3.new(0, -140, 0), ShoreParams)
            if hit and hit.Material ~= Enum.Material.Water and not hit.Instance:HasTag("Water") and hit.Instance.Name ~= "Water" then
                return hit.Position + Vector3.new(0, 3.5, 0)
            end
        end
    end
    return pos + Vector3.new(0, 6, 0)
end

-- Taming ---------------------------------------------------------------------------
local Flute, lastFluteScan = nil, 0
local function isFlute(t)
    return rawget(t, "RealModel") ~= nil and rawget(t, "TamingMinigameActive") ~= nil
end

local function liveFlute(activeOnly)
    local held = heldTool()
    local function good(t)
        return isFlute(t) and rawget(t, "Equipped") ~= false and (held == nil or t.RealModel == held)
            and (not activeOnly or t.TamingMinigameActive == true)
    end
    if Flute and good(Flute) and Flute.RealModel.Parent then
        return Flute
    end
    if os.clock() - lastFluteScan < 1 then
        return nil
    end
    lastFluteScan = os.clock()
    Flute = findGameObject(good)
    return Flute
end

function Feat.fluteStep()
    if not (Settings.PerfectFlute or Settings.InstaTame or Settings.AutoStartTaming) then
        return
    end
    local frame = interface("TamingFluteFrame")
    local playing = frame and frame.Visible
    if not playing and not (Settings.AutoStartTaming and holding("Taming Flute")) then
        return
    end
    local flute = liveFlute(playing)
    if not flute then
        return
    end
    if playing and flute.TamingMinigameActive then
        if Settings.InstaTame then
            -- The game's own test shortcut: a full bar finishes the song.
            flute.TamingTime = 1000
            return
        end
        if Settings.PerfectFlute then
            -- Keep the note on the middle of the green zone. Bar height on
            -- screen is (1 - NotePosition) of the track, so a pixel gap maps
            -- straight back.
            local track = frame.TimingBar
            local zone, bar = track.SuccessArea, track.Bar
            local height = track.AbsoluteSize.Y
            if height > 0 then
                local zoneMid = zone.AbsolutePosition.Y + zone.AbsoluteSize.Y / 2
                local barMid = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y / 2
                flute.NotePosition = math.clamp((flute.NotePosition or 0) + (barMid - zoneMid) / height, 0, 1)
                flute.NoteVelocity = 0
            end
        end
    elseif Settings.AutoStartTaming and not flute.TamingMinigameActive then
        -- Start the song on the nearest animal the flute can reach, unless it
        -- already wants food from you.
        local animal = flute.ClosestAnimal
        if animal and animal.Parent and animal:GetAttribute("PlayerFeeding") ~= UID
            and time() - (flute.LastTaming or 0) > 1.5 and time() >= (flute.LastSwing or 0) + (flute.Cooldown or 0.5) then
            pcall(flute.Activate, flute)
        end
    end
end

local function foodNamesFor(animal)
    local names = {}
    for n = 1, 3 do
        local food = animal:GetAttribute("Food" .. n .. "Type")
        if food then
            names[food] = n
            names["Cooked " .. food] = n
        end
    end
    return names
end

local feedBusy = setmetatable({}, { __mode = "k" })
function Feat.tamingTick()
    if Settings.AutoFeedTaming then
        for _, animal in tagged("CanFeed_" .. UID) do
            if animal.Parent and animal:GetAttribute("PlayerFeeding") == UID and not feedBusy[animal] then
                -- The first food slot that's still open, and something on the map that fills it.
                local slot, want = nil, {}
                for n = 1, 3 do
                    local food = animal:GetAttribute("Food" .. n .. "Type")
                    if food and animal:GetAttribute("Food" .. n .. "Done") == nil and animal:GetAttribute("Food" .. n .. "DoneLocal") == nil then
                        slot = n
                        want = { [food] = true, ["Cooked " .. food] = true }
                        break
                    end
                end
                local pos = pivotPos(animal)
                local food = slot and pos and nearestNamed(want, pos)
                if food then
                    feedBusy[animal] = true
                    task.spawn(function()
                        if carryTo(food, (pivotPos(animal) or pos) + Vector3.new(0, 2, 0)) then
                            invoke("RequestTame_Feed", animal, food, slot)
                        end
                        task.wait(1.5)
                        feedBusy[animal] = nil
                    end)
                end
            end
        end
    end
    if Settings.AutoHealPets then
        for _, pet in tagged("TamedAnimal_" .. UID) do
            local hum = pet:FindFirstChildOfClass("Humanoid")
            local pos = pivotPos(pet)
            if hum and pos and hum.Health > 0 and hum.Health < hum.MaxHealth and not feedBusy[pet] then
                local options = {}
                for name in foodNamesFor(pet) do
                    options[name] = true
                end
                local food = nearestNamed(options, pos)
                if food then
                    feedBusy[pet] = true
                    task.spawn(function()
                        if carryTo(food, (pivotPos(pet) or pos) + Vector3.new(0, 2, 0)) then
                            fire("RequestFeedHealPet", pet, food)
                        end
                        task.wait(2)
                        feedBusy[pet] = nil
                    end)
                end
            end
        end
    end
end

function Feat.commandPets(command)
    local n = 0
    for _, pet in tagged("TamedAnimal_" .. UID) do
        if pet.Parent and fire("CommandPet", pet, command) then
            n += 1
        end
    end
    return n
end

-- Planting -------------------------------------------------------------------------
-- Saplings must go 40+ studs from the fire (52 for a Giant Sapling), on the
-- map's ground. Spots are taken around the camp in a ring.
local PlantParams = RaycastParams.new()
PlantParams.FilterType = Enum.RaycastFilterType.Include
PlantParams.IgnoreWater = true
local plantAngle = 0

local function plantSpot(radius)
    local center = campPos()
    local map = Workspace:FindFirstChild("Map")
    local ground = map and map:FindFirstChild("Ground")
    if not center or not ground then
        return nil
    end
    PlantParams.FilterDescendantsInstances = { ground, map:FindFirstChild("Snow") }
    for _ = 1, 24 do
        plantAngle += 0.6
        local probe = center + Vector3.new(math.cos(plantAngle) * radius, 40, math.sin(plantAngle) * radius)
        local hit = Workspace:Raycast(probe, Vector3.new(0, -120, 0), PlantParams)
        if hit then
            return hit.Position
        end
    end
    return nil
end

local plantBusy = false
local lastPlant = 0
function Feat.plantTick()
    if not Settings.AutoPlant or plantBusy or os.clock() - lastPlant < 2 then
        return
    end
    lastPlant = os.clock()
    local hrp = rootPart()
    if not hrp then
        return
    end
    for model in Index.byKind.Seeds or {} do
        if model.Parent and mineOrFree(model) and tryOnce(model, 6) then
            if model:HasTag("SeedBox") and model:GetAttribute("SeedType") then
                task.spawn(invoke, "RequestPlantSeeds", model)
                return
            elseif model:HasTag("Acorn") then
                local roots = gameModule("TreeRootClient")
                if roots and roots.PlantAcorn then
                    task.spawn(pcall, roots.PlantAcorn, model)
                    return
                end
            elseif model:HasTag("Plantable") then
                local radius = math.max(Settings.PlantRadius, cleanName(model.Name) == "Giant Sapling" and 55 or 44)
                local spot = plantSpot(radius)
                if spot then
                    plantBusy = true
                    task.spawn(function()
                        if carryTo(model, spot + Vector3.new(0, 3, 0)) then
                            invoke("RequestPlantItem", model, spot)
                        end
                        plantBusy = false
                    end)
                    return
                end
            end
        end
    end
end

-- Crafting -------------------------------------------------------------------------
function Feat.blueprints()
    local list, seen = {}, {}
    local ok, db = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Databases", 5):WaitForChild("CraftingDatabase", 5))
    end)
    if not ok or type(db) ~= "table" or type(db.PossibleBlueprints) ~= "table" then
        return list
    end
    for _, tier in db.PossibleBlueprints do
        for _, bp in type(tier) == "table" and tier or {} do
            if type(bp) == "table" and bp.Name and not seen[bp.Name] then
                seen[bp.Name] = true
                table.insert(list, bp)
            end
        end
    end
    return list
end

function Feat.craft(name)
    return invoke("CraftItem", name)
end

local lastBench = 0
function Feat.benchTick()
    if not Settings.AutoBenchUpgrade or os.clock() - lastBench < 10 then
        return
    end
    lastBench = os.clock()
    local tierFolder = ReplicatedStorage:FindFirstChild("Crafting Table")
    local tier = tierFolder and tierFolder:GetAttribute("CraftingTableTier") or 1
    local nextName = "Crafting Bench " .. (tier + 1)
    for _, bp in Feat.blueprints() do
        if bp.Name == nextName then
            local camp = mapFolder("Campground")
            local wood = camp and camp:GetAttribute("TotalWood") or 0
            local scrap = camp and camp:GetAttribute("TotalScrap") or 0
            if wood >= (bp.WoodPrice or 0) and scrap >= (bp.ScrapPrice or 0) then
                task.spawn(Feat.craft, nextName)
            end
            return
        end
    end
end

-- Base Defender: upgrade the camp's defence structures.
function Feat.defenseTick()
    if not Settings.AutoUpgradeDefense or LocalPlayer:GetAttribute("Class") ~= "Base Defender" then
        return
    end
    for _, structure in tagged("DefenceStructure") do
        if structure.Parent == structuresFolder() and not structure:GetAttribute("Upgraded") and tryOnce(structure, 6) then
            fire("RequestUpgradeDefense", structure)
        end
    end
end

-- Halloween ------------------------------------------------------------------------
-- Candy is spawned on your client and claimed one piece at a time, exactly
-- like the game's own pickup does when it reaches you.
function Feat.candyTick()
    if not Settings.AutoCandy then
        return
    end
    local folder = Workspace:FindFirstChild("Halloween")
    folder = folder and folder:FindFirstChild("Candy")
    for _, candy in folder and folder:GetChildren() or {} do
        if candy:IsA("Model") and not candy:GetAttribute("Animating") and not candy:GetAttribute("Taken") then
            candy:SetAttribute("Animating", true)
            candy:SetAttribute("Taken", true)
            local source = candy:GetAttribute("CandySource")
            if source == "FloatingCandy" then
                fire("RequestCollectFloatingCandy", candy:GetAttribute("FloatingSpawnId"), candy:GetAttribute("FloatingIndex"))
            else
                fire("RequestCollectCandy", 1, source or "TrickOrTreating")
            end
            candy:Destroy()
        end
    end
end

local function houseDoor(house)
    local functional = house:FindFirstChild("Functional")
    return functional and functional:FindFirstChild("Door"), functional
end

local function candles()
    local list = {}
    for model in Index.byName["Halloween Candle"] or {} do
        if model.Parent and mineOrFree(model) and not model:GetAttribute("BeingUsed") then
            table.insert(list, model)
        end
    end
    return list
end

-- Trick or treat: light houses that are dark (with a Halloween Candle), then
-- knock on every lit house you haven't visited. Lit houses only answer at
-- night unless they're always open.
function Feat.trickOrTreat(still)
    local visited = 0
    while still() and Settings.AutoTrickOrTreat do
        local did = false
        for _, house in tagged("HalloweenHouse") do
            if not still() then
                return
            end
            local door, functional = houseDoor(house)
            if door and house:IsDescendantOf(Workspace) then
                local open = house:GetAttribute("AlwaysActivated") or (house:GetAttribute("Activated") and isNight())
                if not house:GetAttribute("Activated") and not house:GetAttribute("AlwaysActivated") and Settings.AutoLightHouses then
                    local candle = candles()[1]
                    local zone = functional:FindFirstChild("TouchZone")
                    if candle and zone then
                        setStatus("Lighting " .. cleanName(house.Name))
                        if moveTo(besideOf(zone.Position, 6)) and still() and carryTo(candle, zone.Position) then
                            invoke("RequestActivateHalloweenHouse", candle, house)
                            did = true
                        end
                    end
                elseif open and not house:GetAttribute("Visited_" .. UID) then
                    local stand = functional:FindFirstChild("PlayerPart")
                    setStatus("Trick or treat at " .. cleanName(house.Name))
                    if stand and moveTo(stand.Position) and still() then
                        local module = gameModule("TrickOrTreatClient")
                        if module and module.KnockOnDoor then
                            task.spawn(pcall, module.KnockOnDoor, door)
                        else
                            task.spawn(invoke, "RequestKnockOnDoor", door)
                        end
                        -- The knock plays a cutscene; the candy comes after it.
                        waitFor(20, function()
                            return house:GetAttribute("Visited_" .. UID) ~= nil
                        end, still)
                        task.wait(4)
                        visited += 1
                        did = true
                    end
                end
            end
        end
        if not did then
            setStatus(string.format("Trick or treat: %d visited, waiting for %s", visited, isNight() and "a house to reset" or "night"))
            waitFor(10, function()
                return not Settings.AutoTrickOrTreat
            end, still)
        end
    end
end

-- Pumpkin carving tables: place a pumpkin, carve it, collect it.
local pumpkinBusy = setmetatable({}, { __mode = "k" })
function Feat.pumpkinTick()
    if not Settings.AutoPumpkins then
        return
    end
    for _, carving in tagged("PumpkinCarvingTable") do
        local functional = carving:FindFirstChild("Functional")
        local zone = functional and functional:FindFirstChild("TouchZone")
        if zone and carving:IsDescendantOf(Workspace) and not pumpkinBusy[carving] and tryOnce(carving, 3) then
            if carving:GetAttribute("PumpkinCarved" .. UID) then
                fire("RequestCollectCarvedPumpkin", carving)
            elseif (carving:GetAttribute("PumpkinsPlaced" .. UID) or 0) >= 1 then
                local shop = ReplicatedStorage:FindFirstChild("Shops")
                local options = shop and shop:FindFirstChild("PumpkinCarving")
                options = options and options:FindFirstChild(tostring(UID))
                local first = options and options:GetChildren()[1]
                if first then
                    fire("RequestCarvePumpkin", carving, first.Name)
                end
            else
                local pumpkin = nearestNamed({ Pumpkin = true }, zone.Position)
                if pumpkin then
                    pumpkinBusy[carving] = true
                    task.spawn(function()
                        if carryTo(pumpkin, zone.Position + Vector3.new(0, 1, 0)) then
                            invoke("RequestPlaceCarvingPumpkin", pumpkin, carving)
                        end
                        task.wait(1)
                        pumpkinBusy[carving] = nil
                    end)
                end
            end
        end
    end
end

-- The Hollow: pick an upgrade as soon as one is ready.
local lastHollow = 0
function Feat.hollowTick()
    if not Settings.AutoHollowUpgrade or os.clock() - lastHollow < 2 then
        return
    end
    if (LocalPlayer:GetAttribute("HollowUpgradesReady") or 0) <= 0 then
        return
    end
    lastHollow = os.clock()
    task.spawn(function()
        local offer = invoke("GetHollowUpgradeOffer")
        if type(offer) == "table" then
            local pick = Settings.HollowUpgradePick == "Second offer" and offer[2] or offer[1]
            pick = pick or offer[1]
            if pick and pick.Id ~= nil then
                task.wait(0.5)
                invoke("ChooseHollowUpgrade", pick.Id)
                if logEvent then
                    logEvent("Hollow upgrade: " .. tostring(pick.Text or pick.Id), Color3.fromRGB(190, 120, 255))
                end
            end
        end
    end)
end

function Feat.hollowEntrance()
    return invoke("GetHollowEntrancePosition")
end

-- Hollow plants: walk to each and use its prompt. The game hands these out
-- through the plant's own prompt, so this needs an executor with
-- fireproximityprompt.
function Feat.hollowPlants(still)
    local picked = 0
    for _, plant in tagged("HollowPlant") do
        if not still() then
            return
        end
        local pos = pivotPos(plant)
        if pos and plant:IsDescendantOf(Workspace) then
            setStatus("Hollow plant " .. (picked + 1))
            if moveTo(besideOf(pos, 4)) and still() then
                for _, prompt in plant:GetDescendants() do
                    if prompt:IsA("ProximityPrompt") and typeof(fireproximityprompt) == "function" then
                        pcall(fireproximityprompt, prompt, 0)
                    end
                end
                task.wait(1)
                picked += 1
            end
        end
    end
    setStatus(string.format("Hollow plants: visited %d", picked))
end

-- Jungle ---------------------------------------------------------------------------
local function templePodiums()
    local list = {}
    for _, temple in tagged("JungleTemplePodium") do
        local functional = temple:FindFirstChild("Functional")
        local podiums = functional and functional:FindFirstChild("Podiums")
        for _, podium in podiums and podiums:GetChildren() or {} do
            if not podium:GetAttribute("GemAdded") and podium:FindFirstChild("TouchZone") then
                table.insert(list, podium)
            end
        end
    end
    return list
end

local keyBusy = false
function Feat.templeTick()
    if not Settings.AutoTempleKeys or keyBusy then
        return
    end
    local podium = templePodiums()[1]
    if not podium then
        return
    end
    for model in Index.byKind.Keys or {} do
        if model.Parent and model:HasTag("JungleKey") and mineOrFree(model) and not model:GetAttribute("BeingUsed") and tryOnce(model, 5) then
            keyBusy = true
            task.spawn(function()
                if carryTo(model, podium.TouchZone.Position + Vector3.new(0, 1, 0)) then
                    invoke("RequestAddJungleTempleGem", model, podium)
                end
                keyBusy = false
            end)
            return
        end
    end
end

-- Locks: parts named KeyInteraction whose parent carries LockNumber.
local Locks, lastLockScan = {}, 0
local function locks()
    if os.clock() - lastLockScan > 30 then
        lastLockScan = os.clock()
        table.clear(Locks)
        local map = Workspace:FindFirstChild("Map")
        for _, inst in map and map:GetDescendants() or {} do
            if inst.Name == "KeyInteraction" and inst:IsA("BasePart") and inst.Parent and inst.Parent:GetAttribute("LockNumber") ~= nil then
                table.insert(Locks, inst)
            end
        end
    end
    return Locks
end

function Feat.keysTick()
    if not Settings.AutoKeys or keyBusy then
        return
    end
    for model in Index.byKind.Keys or {} do
        local door = model:GetAttribute("UnlocksDoor")
        if door ~= nil and model.Parent and model:HasTag("KeyModel") and tryOnce(model, 6) then
            for _, part in locks() do
                if part.Parent and part.Parent:GetAttribute("LockNumber") == door then
                    keyBusy = true
                    task.spawn(function()
                        if carryTo(model, part.Position) then
                            invoke("KeyUsed", model, part.Parent)
                        end
                        keyBusy = false
                    end)
                    return
                end
            end
        end
    end
end

-- Gems -----------------------------------------------------------------------------
-- Gem rain and diamond tree drops are client models named AdminDiamond with a
-- GemRain... / DiamondTree... tag; touching one claims it with that tag.
local function claimDiamond(model)
    if not Settings.AutoGemClaim or not model:IsA("Model") or model.Name ~= "AdminDiamond" or model:GetAttribute("NNClaimed") then
        return
    end
    for _, tag in model:GetTags() do
        local remoteName = tag:sub(1, 7) == "GemRain" and "ClaimGemRainGem" or tag:sub(1, 11) == "DiamondTree" and "ClaimDiamondTreeGem"
        if remoteName then
            model:SetAttribute("NNClaimed", true)
            fire(remoteName, tag)
            model:Destroy()
            return
        end
    end
end
bind(Workspace.DescendantAdded, function(inst)
    if Settings.AutoGemClaim and inst.Name == "AdminDiamond" then
        task.defer(claimDiamond, inst)
    end
end)
function Feat.claimAllDiamonds()
    for _, inst in Workspace:GetDescendants() do
        if inst.Name == "AdminDiamond" then
            claimDiamond(inst)
        end
    end
end

-- Green gem pieces: merge two at a time, yours first, until each has four.
local mergeBusy = false
function Feat.mergeTick()
    if not Settings.AutoMergeGems or mergeBusy then
        return
    end
    local pieces = {}
    for model in Index.byKind.Gems or {} do
        local n = model:GetAttribute("NumberPieces")
        if model.Parent and model:HasTag("GreenGemPiece") and n and n < 4 and mineOrFree(model) and not model:GetAttribute("Destroyed") then
            table.insert(pieces, model)
        end
    end
    if #pieces < 2 then
        return
    end
    table.sort(pieces, function(a, b)
        return (a:GetAttribute("NumberPieces") or 0) > (b:GetAttribute("NumberPieces") or 0)
    end)
    local a, b = pieces[1], pieces[#pieces]
    if not tryOnce(b, 3) then
        return
    end
    mergeBusy = true
    task.spawn(function()
        local pos = pivotPos(a)
        if pos and carryTo(b, pos + Vector3.new(0, 1.5, 0)) then
            invoke("RequestMergeGems", a, b)
        end
        mergeBusy = false
    end)
end

-- Revive, machines, rain storage ------------------------------------------------
local function hasReviveKit()
    local inv = inventory()
    return inv and (inv:FindFirstChild("Bandage") or inv:FindFirstChild("MedKit")) ~= nil
end

function Feat.reviveTick()
    if Settings.AutoReviveOthers and hasReviveKit() then
        local hrp = rootPart()
        for _, player in Players:GetPlayers() do
            local body = player ~= LocalPlayer and player.Character
            if body and body:GetAttribute("Interaction") == "Revive" and hrp then
                local pos = pivotPos(body)
                if pos and (pos - hrp.Position).Magnitude < 20 and tryOnce(body, 4) then
                    fire("RequestRevivePlayer", body)
                end
            end
        end
        -- Bodies left in the item folder sort as "Other".
        for model in Index.byKind.Other or {} do
            if model:GetAttribute("Interaction") == "Revive" and hrp then
                local pos = pivotPos(model)
                if pos and (pos - hrp.Position).Magnitude < 20 and tryOnce(model, 4) then
                    fire("RequestRevivePlayer", model)
                end
            end
        end
    end
    if Settings.AutoSelfRevive and LocalPlayer:GetAttribute("DeathTime") then
        -- Only while the game itself offers the self-revive button.
        local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local button = gui and gui:FindFirstChild("PurchaseRespawnButton", true)
        if button and button.Visible and tryOnce(LocalPlayer, 5) then
            fire("RequestSelfRevive")
        end
    end
end

local lastWeather, nightSkipped = 0, nil
function Feat.machineTick()
    if Settings.AutoClearWeather and os.clock() - lastWeather > 30 then
        local weather = Workspace:GetAttribute("Weather")
        if weather and weather ~= "Clear" then
            local machine = nearestStructure(function(model)
                return model.Name == "Weather Machine"
            end)
            if machine and campGems() >= (machine:GetAttribute("GemPrice") or machine:GetAttribute("UseCost") or 1) then
                lastWeather = os.clock()
                task.spawn(invoke, "RequestClearWeather", machine)
            end
        end
    end
    if Settings.AutoNightSkip and isNight() then
        local night = Workspace:GetAttribute("StoryDayCounter")
        if nightSkipped ~= night then
            local machine = nearestStructure(function(model)
                return model.Name == "Temporal Accelerometer"
            end)
            if machine and campGems() >= (machine:GetAttribute("GemPrice") or machine:GetAttribute("UseCost") or 1) then
                nightSkipped = night
                fire("RequestActivateNightSkipMachine", machine)
            end
        end
    end
end

local lastDry = 0
function Feat.dryTick()
    if not Settings.AutoDryWood or Bring.running or os.clock() - lastDry < 15 or not rainStorage() then
        return
    end
    lastDry = os.clock()
    runBring({
        kinds = { Fuel = true },
        filter = function(model)
            return (model:GetAttribute("Wet") or 0) >= 1
        end,
    }, "Rain storage", 8)
end

-- Caves ----------------------------------------------------------------------------
function Feat.cavePoints()
    local points = {}
    for name, value in Workspace:GetAttributes() do
        local point = name:match("^CaveTeleport_(.+)$")
        if point and typeof(value) == "CFrame" then
            table.insert(points, point)
        end
    end
    table.sort(points)
    return points
end

function Feat.caveTravel(point)
    local caves = gameModule("CaveInstanceClient")
    if caves and caves.TeleportTo then
        local ok = pcall(caves.TeleportTo, point)
        if ok then
            return true
        end
    end
    local cf = Workspace:GetAttribute("CaveTeleport_" .. point)
    if typeof(cf) == "CFrame" then
        teleportTo(cf.Position)
        return true
    end
    return false
end

-- Shops, traders and benches ------------------------------------------------------
-- The map is built fresh each game, so these are looked up by what they do
-- (their Interaction) and by landmark name rather than fixed spots.
local PLACE_WORDS = { "trader", "smith", "shop", "workshop", "upgrade", "beekeeper", "merchant", "anvil" }
local function placeLabel(name)
    local lower = string.lower(name)
    for _, word in PLACE_WORDS do
        if lower:find(word, 1, true) then
            return true
        end
    end
    return false
end

function Feat.places()
    local list, order, seen = {}, {}, {}
    local function add(label, model)
        local pos = pivotPos(model)
        if pos and not seen[model] then
            seen[model] = true
            local text = string.format("%s · %dm", spaced(label), math.floor(distanceTo(pos)))
            list[text] = model
            table.insert(order, text)
        end
    end
    for _, root in { Workspace:FindFirstChild("Map"), structuresFolder(), charactersFolder() } do
        for _, inst in root and root:GetDescendants() or {} do
            if inst:IsA("Model") then
                local interaction = inst:GetAttribute("Interaction")
                if interaction and placeLabel(interaction) then
                    add(interaction == "OpenToolTrader" and "Tool Smith" or interaction, inst)
                elseif placeLabel(inst.Name) and (inst.Parent and inst.Parent.Name == "Landmarks" or inst.Parent == structuresFolder()) then
                    add(inst:GetAttribute("FullLandmarkName") or cleanName(inst.Name), inst)
                end
            end
        end
    end
    table.sort(order, function(a, b)
        return (pivotPos(list[a]) and distanceTo(pivotPos(list[a])) or 0) < (pivotPos(list[b]) and distanceTo(pivotPos(list[b])) or 0)
    end)
    return list, order
end

function Feat.findToolSmith()
    local list, order = Feat.places()
    for _, label in order do
        local lower = label:lower()
        if lower:find("tool smith") or lower:find("toolsmith") or lower:find("tool trader") then
            return list[label]
        end
    end
    return nil
end

-- Rod and flute upgrades: hold the tool at an upgrade bench once it has its
-- XP. Rods go Old -> Good -> Strong; flutes likewise.
local UPGRADES = {
    { tool = "Fishing Rod", benches = { ToolUpgradeBench = true, FishingRodUpgrade = true }, module = "FishingUpgradeClient",
        call = "RequestUpgradeRod", remote = "RequestUpgradeRod", maxed = function(item)
            return item.Name ~= "Old Rod" and item.Name ~= "Good Rod"
        end },
    { tool = "Taming Flute", benches = { ToolUpgradeBench = true, TamingFluteUpgrade = true }, module = "FluteUpgradeClient",
        call = "RequestUpgradeFlute", remote = "RequestUpgradeFlute", maxed = function(item)
            return (item:GetAttribute("ToolTier") or 1) >= 3
        end },
}

local function readyToUpgrade(item, kind)
    return item:GetAttribute("ToolName") == kind.tool and not kind.maxed(item)
        and (item:GetAttribute("XP") or 0) >= (item:GetAttribute("LevelUpXP") or math.huge)
end

local function upgradeBench(kind)
    local best, bestD
    for _, root in { structuresFolder(), Workspace:FindFirstChild("Map") } do
        for _, inst in root and root:GetDescendants() or {} do
            if inst:IsA("Model") and kind.benches[inst:GetAttribute("Interaction") or ""] then
                local d = distanceTo(pivotPos(inst))
                if not bestD or d < bestD then
                    best, bestD = inst, d
                end
            end
        end
    end
    return best
end

function Feat.upgradesReady()
    local ready = {}
    for _, item in inventoryItems() do
        for _, kind in UPGRADES do
            if readyToUpgrade(item, kind) then
                table.insert(ready, { item = item, kind = kind })
            end
        end
    end
    return ready
end

function Feat.upgradeTools(still)
    local start = rootPart() and rootPart().Position
    local done = 0
    for _, entry in Feat.upgradesReady() do
        if not still() then
            return
        end
        local bench = upgradeBench(entry.kind)
        if not bench then
            setStatus("No upgrade bench for your " .. entry.kind.tool:lower() .. " on this map")
        else
            setStatus("Upgrading " .. entry.item.Name)
            if moveTo(safeSpotNear(pivotPos(bench), 5), runOpts()) and still() then
                fire("EquipItemHandle", "FireAllClients", entry.item)
                waitFor(2, function()
                    local held = heldToolNow()
                    return held == entry.item
                end, still)
                local module = gameModule(entry.kind.module)
                local fn = module and module[entry.kind.call]
                if not (fn and pcall(fn, bench)) then
                    invoke(entry.kind.remote, entry.item, bench)
                end
                task.wait(2)
                done += 1
            end
        end
    end
    setStatus(done > 0 and string.format("Upgraded %d tool%s", done, done == 1 and "" or "s") or "Nothing ready to upgrade")
    if start and still() then
        moveTo(start, runOpts())
    end
end

local lastUpgradeCheck = 0
function Feat.upgradeTick()
    if not Settings.AutoUpgradeTools or Job.name or os.clock() - lastUpgradeCheck < 15 then
        return
    end
    lastUpgradeCheck = os.clock()
    if #Feat.upgradesReady() > 0 then
        startJob("Upgrade tools", Feat.upgradeTools)
    end
end

-- Armour: wear the best piece lying around for each slot.
local armourBusy = false
function Feat.armourTick()
    if not Settings.AutoArmour or armourBusy then
        return
    end
    local worn = {}
    local folder = LocalPlayer:FindFirstChild("Armour")
    for _, piece in folder and folder:GetChildren() or {} do
        local slot = piece:GetAttribute("ArmourSlot") or "?"
        worn[slot] = math.max(worn[slot] or 0, piece:GetAttribute("Armour") or 0)
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    local best, bestGain
    for model in Index.byKind.Gear or {} do
        if model.Parent and model:GetAttribute("Interaction") == "Armour" and mineOrFree(model) then
            local gain = (model:GetAttribute("Armour") or 0) - (worn[model:GetAttribute("ArmourSlot") or "?"] or 0)
            if gain > 0 and (not bestGain or gain > bestGain) and tryOnce(model, 10) then
                best, bestGain = model, gain
            end
        end
    end
    if best then
        armourBusy = true
        task.spawn(function()
            if carryTo(best, hrp.Position + hrp.CFrame.LookVector * 3) then
                invoke("RequestEquipArmour", best)
            end
            armourBusy = false
        end)
    end
end

-- Shops ----------------------------------------------------------------------------
function Feat.beekeeperSlots()
    local shops = ReplicatedStorage:FindFirstChild("Shops")
    local keeper = shops and shops:FindFirstChild("Beekeeper")
    local list, order = {}, {}
    for _, slot in keeper and keeper:GetChildren() or {} do
        local label = string.format("%s · %d honey · %d left", tostring(slot:GetAttribute("Name") or slot.Name),
            slot:GetAttribute("Price") or 0, slot:GetAttribute("Stock") or 0)
        list[label] = slot
        table.insert(order, label)
    end
    table.sort(order)
    return list, order
end

function Feat.buyBeekeeper(slot)
    if not slot or (slot:GetAttribute("Stock") or 0) <= 0 then
        return false, "out of stock"
    end
    if (slot:GetAttribute("Price") or 0) > (Workspace:GetAttribute("TotalHoney") or 0) then
        return false, "not enough honey"
    end
    fire("RequestBuyFromBeekeeper", slot)
    return true
end

-- Badges -------------------------------------------------------------------------
-- The dump holds no badge list (it's in the game's website data), so the list
-- comes from Roblox's public badge API for this game, and which ones you own
-- from the same API (or BadgeService when the web call is blocked).
local function httpGet(url)
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(body) == "string" and #body > 0 then
        return body
    end
    local req = (typeof(syn) == "table" and syn.request) or (typeof(http_request) == "function" and http_request)
        or (typeof(request) == "function" and request)
    if req then
        local good, res = pcall(req, { Url = url, Method = "GET" })
        if good and type(res) == "table" and type(res.Body) == "string" then
            return res.Body
        end
    end
    return nil
end

local function decode(body)
    local ok, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(body)
    end)
    return ok and type(data) == "table" and data or nil
end

-- Returns the badges you don't have ({ name, description }) and how many the game has.
function Feat.missingBadges()
    local all, cursor = {}, nil
    repeat
        local url = ("https://badges.roblox.com/v1/universes/%d/badges?limit=100&sortOrder=Asc"):format(game.GameId)
        if cursor then
            url ..= "&cursor=" .. cursor
        end
        local data = decode(httpGet(url) or "")
        if not data then
            return nil, "couldn't load the game's badge list (your executor may block web requests)"
        end
        for _, badge in data.data or {} do
            table.insert(all, badge)
        end
        cursor = data.nextPageCursor
    until not cursor or cursor == "" or #all >= 1000
    local owned = {}
    for i = 1, #all, 50 do
        local ids = {}
        for j = i, math.min(i + 49, #all) do
            table.insert(ids, tostring(all[j].id))
        end
        local data = decode(httpGet(("https://badges.roblox.com/v1/users/%d/badges/awarded-dates?badgeIds=%s"):format(UID, table.concat(ids, ","))) or "")
        if data and data.data then
            for _, row in data.data do
                owned[row.badgeId] = true
            end
        else
            local service = game:GetService("BadgeService")
            for j = i, math.min(i + 49, #all) do
                local ok, has = pcall(service.UserHasBadgeAsync, service, UID, all[j].id)
                if ok and has then
                    owned[all[j].id] = true
                end
            end
        end
    end
    local missing = {}
    for _, badge in all do
        if badge.enabled ~= false and not owned[badge.id] then
            table.insert(missing, { name = tostring(badge.displayName or badge.name or badge.id),
                description = tostring(badge.displayDescription or badge.description or "") })
        end
    end
    return missing, #all
end

-- Daily quests, for the dashboard.
function Feat.dailyQuests()
    local folder = LocalPlayer:FindFirstChild("DailyQuests")
    local lines = {}
    for _, quest in folder and folder:GetChildren() or {} do
        table.insert(lines, { n = quest:GetAttribute("QuestNumber") or 0,
            text = (quest:GetAttribute("Completed") and "✓ " or "• ") .. tostring(quest:GetAttribute("Description") or quest.Name) })
    end
    table.sort(lines, function(a, b)
        return a.n < b.n
    end)
    local out = {}
    for _, line in lines do
        table.insert(out, line.text)
    end
    return #out > 0 and table.concat(out, "\n") or "No daily quests"
end

-- Every tick above shares one loop, so none of them costs its own thread;
-- each runs guarded, so one failing never stops the others.
local TICKS = {
    "cookTick", "crockpotTick", "tamingTick", "plantTick", "benchTick", "defenseTick", "candyTick", "pumpkinTick",
    "hollowTick", "templeTick", "keysTick", "mergeTick", "reviveTick", "machineTick", "dryTick", "upgradeTick", "armourTick",
}
local tickErrors = {}
loop(0.5, function()
    for _, name in TICKS do
        local ok, err = pcall(Feat[name])
        if not ok and not tickErrors[name] then
            tickErrors[name] = true
            warn("[99 Nights] " .. name .. ": " .. tostring(err))
        end
    end
end)
bind(RunService.RenderStepped, function()
    if alive() then
        for _, name in { "fishingStep", "fluteStep" } do
            local ok, err = pcall(Feat[name])
            if not ok and not tickErrors[name] then
                tickErrors[name] = true
                warn("[99 Nights] " .. name .. ": " .. tostring(err))
            end
        end
    end
end)
return Feat, fire
end)()

-- The UI and the loops run in their own function for the same reason.
;(function()

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
        if Settings.EspMobs or Settings.EspKids then
            for model in Index.mobs do
                local kind = model.Parent and mobKind(model)
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
        if Settings.EspFishSpots then
            for _, spot in tagged("FishHotspot") do
                if spot:IsA("BasePart") and spot:GetAttribute("Active") then
                    consider(spot, Color3.fromRGB(90, 200, 255), "Fishing spot")
                end
            end
        end
        if Settings.EspChests then
            for model in Index.chests do
                if model.Parent and not chestOpened(model) then
                    local name = model:GetAttribute("ChestName") or cleanName(model.Name)
                    consider(model, Settings.ChestColor, model:GetAttribute("Locked") and (name .. " (locked)") or name)
                end
            end
        end
        if Settings.EspItems then
            for kind in Settings.EspItemKinds do
                for model in Index.byKind[kind] or {} do
                    if model.Parent then
                        consider(model, Settings.ItemColor, Index.items[model] and Index.items[model].name or cleanName(model.Name))
                    end
                end
            end
        end
    end

    -- Only the nearest few get a label; thousands of billboards are what made
    -- item ESP lag.
    table.sort(order, byDistance)
    for i = Settings.EspMax + 1, #order do
        want[order[i].model] = nil
        order[i] = nil
    end
    for model in Esp do
        if not want[model] or not model.Parent then
            dropEsp(model)
        end
    end
    for i, info in order do
        local e = espEntry(info.model)
        if e then
            if e.lastText ~= info.text then
                e.lastText = info.text
                e.text.Text = info.text
            end
            if e.lastColor ~= info.color then
                e.lastColor = info.color
                e.text.TextColor3 = info.color
            end
            if Settings.EspHighlight and i <= MAX_HIGHLIGHTS then
                if not e.hl then
                    e.hl = Instance.new("Highlight")
                    e.hl.FillTransparency = 0.75
                    e.hl.OutlineTransparency = 0.1
                    e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    e.hl.Adornee = info.model
                    e.hl.Parent = VisualGui
                end
                if e.hlColor ~= info.color then
                    e.hlColor = info.color
                    e.hl.FillColor = info.color
                    e.hl.OutlineColor = info.color
                end
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

-- Labels are only rewritten when their text changes.
local function setText(label, text)
    if label and label.__nnText ~= text then
        label.__nnText = text
        label:SetText(text)
    end
end

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
UI.QuestLabel = UI.GameBox:AddLabel("Daily quests: -", true)

UI.BadgeBox = UI.DashTab:AddBigGroupbox("Badges you don't have", "award")
UI.BadgeLabel = UI.BadgeBox:AddLabel("Press Check to look them up", true)
UI.BadgeLog = UI.BadgeBox:AddLog("BadgeLog", { Text = "Missing badges", Height = 160, MaxLines = 300 })
local function checkBadges()
    setText(UI.BadgeLabel, "Looking up this game's badges...")
    task.spawn(function()
        local missing, total = Feat.missingBadges()
        pcall(UI.BadgeLog.Clear, UI.BadgeLog)
        if not missing then
            setText(UI.BadgeLabel, "Couldn't check: " .. tostring(total))
            return
        end
        setText(UI.BadgeLabel, string.format("You have %d of %d badges · %d missing", total - #missing, total, #missing))
        for _, badge in missing do
            pcall(UI.BadgeLog.Log, UI.BadgeLog, badge.name .. (badge.description ~= "" and (" — " .. badge.description) or ""))
        end
    end)
end
UI.BadgeBox:AddButton("Check badges", checkBadges)
task.delay(6, function()
    if alive() then
        checkBadges()
    end
end)
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
slider(UI.ChopBox, "ChopPerSwing", "Trees per swing", "ChopPerSwing", 1, 25)
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
slider(UI.AuraBox, "AuraPerSwing", "Mobs per swing", "AuraPerSwing", 1, 25)
multi(UI.AuraBox, "AuraKinds", "Targets", "AuraKinds", { "Hostile", "Can attack", "Passive" }, { "Hostile", "Can attack" },
    "Hostile: chasing or aggressive. Can attack: fights back. Passive: neither")
choice(UI.AuraBox, "AuraPriority", "Hit first", "AuraPriority", { "Chasing me first", "Nearest", "Lowest health" },
    "Which mobs get the swing when more are in range than mobs per swing")
UI.AuraNearLabel = UI.AuraBox:AddLabel("Nearby: -", true)

UI.SwingBox = UI.CombatTab:AddLeftGroupbox("Swing settings", "settings-2")
toggle(UI.SwingBox, "AutoEquip", "Auto equip the right tool", "AutoEquip")
choice(UI.SwingBox, "SwingMode", "Swing mode", "SwingMode", { "Fast", "Normal" },
    "Fast equips and hits in the same moment, on the tool's own cooldown. Normal waits a beat for the tool to show in hand")
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
local refreshBringItems
do
    local BringTab = UI.Window:AddTab("Bring", "magnet", "Pull items to you, the fire, the bench or the rain storage")

    local PickBox = BringTab:AddLeftGroupbox("Pick items", "package-search")
    local countLabel
    -- The item list follows the category: picking a category fills the
    -- second list with what of that kind lies on the map right now.
    local lastVersion, lastCategory = -1, nil
    refreshBringItems = function(force)
        if not UI.BringItems then
            return
        end
        local category = Settings.BringCategory or "All"
        if not force and lastVersion == Index.namesVersion and lastCategory == category then
            return
        end
        lastVersion, lastCategory = Index.namesVersion, category
        local names, counts = namesIn(category)
        local values = { ALL_ITEMS }
        for _, name in names do
            table.insert(values, name)
        end
        UI.BringItems:SetValues(values)
        local picks = Settings.BringPicks[category] or {}
        UI.BringItems:SetValue(picks)
        if UI.BringExclude then
            UI.BringExclude:SetValues(itemNames())
        end
        local parts = {}
        local sorted = table.clone(names)
        table.sort(sorted, function(a, b)
            return (counts[a] or 0) > (counts[b] or 0)
        end)
        for i = 1, math.min(6, #sorted) do
            table.insert(parts, string.format("%d %s", counts[sorted[i]], sorted[i]))
        end
        if countLabel then
            countLabel:SetText(#names == 0 and "Nothing of this kind on the map" or ("On the map: " .. table.concat(parts, " · ")
                .. (#sorted > 6 and string.format(" +%d more", #sorted - 6) or "")))
        end
    end
    local categories = { "All" }
    for _, kind in ITEM_KINDS do
        table.insert(categories, kind)
    end
    PickBox:AddDropdown("BringCategory", {
        Text = "Category",
        Values = categories,
        Default = Settings.BringCategory,
        Tooltip = "Sorted by what an item does (burns, feeds, heals, scraps...), so new items fall in on their own",
        Callback = function(v)
            Settings.BringCategory = v or "All"
            refreshBringItems(true)
        end,
    })
    UI.BringItems = PickBox:AddDropdown("BringItems", {
        Text = "Items in it",
        Values = {},
        Multi = true,
        Searchable = true,
        Tooltip = "Changes with the category. ★ All of them (or nothing picked) brings the whole category",
        Callback = function(v)
            local picks = {}
            for name, on in v or {} do
                if on then
                    picks[name] = true
                end
            end
            -- "All of them" wins over single picks.
            if picks[ALL_ITEMS] then
                picks = { [ALL_ITEMS] = true }
            end
            Settings.BringPicks[Settings.BringCategory or "All"] = picks
        end,
    })
    countLabel = PickBox:AddLabel("", true)
    UI.BringExclude = PickBox:AddDropdown("BringExclude", {
        Text = "Never bring",
        Values = {},
        Multi = true,
        Searchable = true,
        Tooltip = "Items to leave where they are, whatever is picked above",
        Callback = function(v)
            Settings.BringExclude = v
        end,
    })
    refreshBringItems(true)

    local WhereBox = BringTab:AddRightGroupbox("Where", "map-pin")
    choice(WhereBox, "BringDest", "Bring to", "BringDest", BRING_DESTS,
        "Camp fire burns fuel and cooks raw food as it lands. Cook at fire only cooks. Crafting bench scraps. Rain storage dries wet wood")
    choice(WhereBox, "BringOrder", "Order", "BringOrder", { "Nearest first", "Farthest first", "Strongest first", "Weakest first" },
        "Strongest first takes the items that burn longest first (oil barrel, canister, coal, logs)")
    local SpotLabel = WhereBox:AddLabel("Saved spot: none", true)
    WhereBox:AddButton("Save current spot", function()
        local hrp = rootPart()
        if hrp then
            Settings.SavedSpot = CFrame.new(hrp.Position + hrp.CFrame.LookVector * 6)
            local p = Settings.SavedSpot.Position
            SpotLabel:SetText(string.format("Saved spot: %d, %d, %d", p.X, p.Y, p.Z))
        end
    end)

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

    local HowBox = BringTab:AddLeftGroupbox("How", "gauge")
    choice(HowBox, "BringMode", "Method", "BringMode", { "Fast", "Safe" },
        "Fast moves many items per frame (100+ a second). Safe moves one at a time and waits until the server hands it over")
    slider(HowBox, "BringPerFrame", "Items per frame (fast)", "BringPerFrame", 1, 50)
    slider(HowBox, "BringHold", "Hold before letting go", "BringHold", 0, 500, " ms", "Raise this if items snap back to where they were")
    slider(HowBox, "BringMax", "Max items per bring", "BringMax", 1, 500)
    slider(HowBox, "BringRange", "Only items within", "BringRange", 25, 5000, " studs",
        "Bring only takes items your game has loaded (the map around you, plus anything the game keeps loaded everywhere); this caps how far from you they can be")
    toggle(HowBox, "BringSkipNear", "Skip items already there", "BringSkipNear")

    local LootBox = BringTab:AddRightGroupbox("Chest loot", "package-open")
    toggle(LootBox, "ChestLoot", "Bring what chests drop", "ChestLoot",
        "When a chest opens (by you, a chest run or auto open), what falls out of it is brought to the place below")
    choice(LootBox, "ChestLootDest", "Bring loot to", "ChestLootDest", BRING_DESTS)
    multi(LootBox, "ChestLootKinds", "Loot types", "ChestLootKinds", ITEM_KINDS, ITEM_KINDS)

    local QuickBox = BringTab:AddRightGroupbox("Quick", "zap")
    for _, quick in {
        { "Fuel to camp fire", { kinds = { Fuel = true }, order = "Strongest first" }, "Camp fire" },
        { "Cook raw food", { filter = function(m)
            return m:GetAttribute("Cookable") ~= nil
        end }, "Cook at fire" },
        { "Scrap to crafting bench", { kinds = { Scrap = true } }, "Crafting bench" },
        { "Wet wood to rain storage", { kinds = { Fuel = true }, filter = function(m)
            return (m:GetAttribute("Wet") or 0) >= 1
        end }, "Rain storage" },
        { "Food to me", { kinds = { Food = true } }, "You" },
        { "Heals to me", { kinds = { Heals = true } }, "You" },
        { "Gear and ammo to me", { kinds = { Gear = true, Ammo = true } }, "You" },
        { "Gems and keys to me", { kinds = { Gems = true, Keys = true } }, "You" },
    } do
        QuickBox:AddButton(quick[1], function()
            local what = table.clone(quick[2])
            what.exclude = Settings.BringExclude
            if runBring(what, quick[3]) == 0 then
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
    toggle(EatBox, "AutoHeal", "Auto heal", "AutoHeal", "Uses the nearest bandage, medkit or healing food in reach when health drops below the line")
    slider(EatBox, "HealBelow", "Heal below health", "HealBelow", 5, 95, "%")
    toggle(EatBox, "HealBring", "Bring a heal over if none is in reach", "HealBring")
    EatBox:AddDivider()
    slider(EatBox, "ConsumeRange", "Eat / heal reach", "ConsumeRange", 5, 80, " studs",
        "The game lets you use things within 15 studs; more may or may not be accepted")

    local CampBox = SurvivalTab:AddRightGroupbox("Camp", "flame")
    toggle(CampBox, "KeepFireFed", "Keep the fire fed", "KeepFireFed",
        "Brings dry fuel to the camp fire (and burns it) whenever its fuel drops below the line")
    slider(CampBox, "FireBelow", "Feed below fuel", "FireBelow", 1, 500)
    choice(CampBox, "FuelOrder", "Fuel first", "FuelOrder", { "Strongest first", "Weakest first", "Nearest first" },
        "Strongest first burns oil barrels and canisters before logs")
    toggle(CampBox, "KeepScrapping", "Keep scrapping", "KeepScrapping",
        "Every 20 s, brings scrap to the crafting bench and scraps it")
    toggle(CampBox, "AutoDryWood", "Dry wet wood", "AutoDryWood",
        "Every 15 s, brings wet fuel to your Wood Rain Storage, which dries it")

    local SafeBox = SurvivalTab:AddRightGroupbox("Safety", "shield")
    toggle(SafeBox, "NightCamp", "Go to camp when night falls", "NightCamp",
        "Stops whatever automation is running (except the tree farm, which has its own night setting)")
    toggle(SafeBox, "Escape", "Escape to camp on low health", "Escape",
        "Drops what you're doing and goes to the camp fire. Turns the tree farm off")
    slider(SafeBox, "EscapeBelow", "Escape below health", "EscapeBelow", 5, 80, "%")

    local ReviveBox = SurvivalTab:AddLeftGroupbox("Revive", "cross")
    toggle(EatBox, "AutoArmour", "Wear better armour", "AutoArmour",
        "Brings over and puts on any armour on the map that beats what you wear in that slot")
    toggle(ReviveBox, "AutoReviveOthers", "Revive teammates near me", "AutoReviveOthers",
        "Revives downed players within 20 studs. Needs a bandage or medkit in your inventory, like reviving by hand")
    toggle(ReviveBox, "AutoSelfRevive", "Self revive when offered", "AutoSelfRevive",
        "Presses the game's own self-revive button when it shows. If the game asks for a purchase you still have to confirm it")

    local MachineBox = SurvivalTab:AddLeftGroupbox("Machines (cost gems)", "cog")
    toggle(MachineBox, "AutoClearWeather", "Clear bad weather", "AutoClearWeather",
        "Uses your Weather Machine whenever the weather isn't clear. Each use costs camp gems")
    toggle(MachineBox, "AutoNightSkip", "Skip the night", "AutoNightSkip",
        "Uses your Temporal Accelerometer once each night. Each use costs camp gems")
end

-- Farm ----------------------------------------------------------------------------
do
    local FarmTab = UI.Window:AddTab("Farm", "wheat", "Cooking, fishing, taming, planting and crafting")

    local CookBox = FarmTab:AddLeftGroupbox("Cooking", "chef-hat")
    toggle(CookBox, "AutoCook", "Auto cook raw food", "AutoCook",
        "Every 3 s, brings raw food to the camp fire and cooks it (the fire needs fuel)")
    toggle(CookBox, "AutoCrockpot", "Fill crockpots", "AutoCrockpot",
        "Brings ingredients to any crockpot with room and adds them. Collect the meal yourself")

    local FishBox = FarmTab:AddRightGroupbox("Fishing", "fish")
    toggle(FishBox, "PerfectFishing", "Perfect catch", "PerfectFishing",
        "While a fish is hooked, reels exactly when the bar is in the green zone")
    toggle(FishBox, "InstantCatch", "Instant catch", "InstantCatch",
        "Lands a fish as soon as it bites, the way a full catch bar does")
    slider(FishBox, "InstantCatchDelay", "Wait after the bite", "InstantCatchDelay", 0, 3, " s",
        "A short wait looks like a real catch. Raise it if catches get refused")
    toggle(FishBox, "AutoRecast", "Recast after each catch", "AutoRecast",
        "Casts again where you're aiming. Keep the camera on the water")
    local spots = {}
    local spotPicker = FishBox:AddDropdown("FishSpot", { Text = "Fishing spot", Values = {}, AllowNull = true, Searchable = true,
        Tooltip = "Bubbling hotspots, active ones first. You land on the shore next to it" })
    local function refreshSpots()
        local list, order = Feat.fishingSpots()
        spots = list
        spotPicker:SetValues(order)
    end
    FishBox:AddButton({
        Text = "Teleport",
        Func = function()
            local spot = spots[spotPicker.Value]
            if not spot or not spot.Parent then
                notify("Fishing", "Pick a spot first (or refresh)", 2)
                return
            end
            teleportTo(Feat.shoreNear(spot.Position), { exact = true })
        end,
    }):AddButton({ Text = "Refresh", Func = refreshSpots })
    task.defer(refreshSpots)

    local TameBox = FarmTab:AddLeftGroupbox("Taming and pets", "paw-print")
    toggle(TameBox, "PerfectFlute", "Perfect flute", "PerfectFlute",
        "Keeps the note in the green zone while you play the taming flute")
    toggle(TameBox, "InstaTame", "Instant flute", "InstaTame",
        "Finishes the flute song the moment it starts (the game's own test shortcut). Pair with Feed the animal")
    toggle(TameBox, "AutoStartTaming", "Start taming the nearest animal", "AutoStartTaming",
        "While you hold the flute, plays it at the nearest tameable animal in reach")
    toggle(TameBox, "AutoFeedTaming", "Feed the animal I'm taming", "AutoFeedTaming",
        "Brings the food the animal asks for (raw or cooked) and feeds it")
    toggle(TameBox, "AutoHealPets", "Heal hurt pets", "AutoHealPets", "Feeds a hurt pet one of its favourite foods")
    TameBox:AddButton({
        Text = "Summon all pets",
        Func = function()
            fire("RequestSummonAllPets")
        end,
    })
    TameBox:AddButton({
        Text = "Pets: sit",
        Func = function()
            notify("Pets", Feat.commandPets("Sit") .. " told to sit", 2)
        end,
    }):AddButton({
        Text = "Pets: follow",
        Func = function()
            notify("Pets", Feat.commandPets("FollowOwner") .. " told to follow", 2)
        end,
    })

    local PlantBox = FarmTab:AddRightGroupbox("Planting", "sprout")
    toggle(PlantBox, "AutoPlant", "Auto plant", "AutoPlant",
        "Plants saplings in a ring around camp, opens seed boxes and plants acorns")
    slider(PlantBox, "PlantRadius", "Ring distance from the fire", "PlantRadius", 44, 200, " studs",
        "The game needs 40+ studs from the fire (52+ for a Giant Sapling)")

    local CraftBox = FarmTab:AddLeftGroupbox("Crafting", "hammer")
    local blueprints = {}
    for _, bp in Feat.blueprints() do
        table.insert(blueprints, bp.Name)
    end
    choice(CraftBox, "CraftPick", "Blueprint", "CraftPick", blueprints)
    CraftBox:AddButton("Craft", function()
        if Settings.CraftPick then
            task.spawn(function()
                local ok = Feat.craft(Settings.CraftPick)
                notify("Crafting", ok and ("Crafted " .. Settings.CraftPick) or "The bench said no (materials or tier?)", 3)
            end)
        end
    end)
    toggle(CraftBox, "AutoBenchUpgrade", "Upgrade the crafting bench", "AutoBenchUpgrade",
        "Crafts the next Crafting Bench tier as soon as the camp has the wood and scrap")
    toggle(CraftBox, "AutoUpgradeDefense", "Upgrade defences (Base Defender)", "AutoUpgradeDefense",
        "Base Defender class only: upgrades every defence structure that isn't upgraded yet")

    local UpBox = FarmTab:AddRightGroupbox("Tool upgrades", "arrow-big-up")
    toggle(UpBox, "AutoUpgradeTools", "Auto upgrade rod and flute", "AutoUpgradeTools",
        "When your rod or flute has the XP for its next level, goes to an upgrade bench, upgrades it and comes back")
    UpBox:AddButton("Upgrade now", function()
        startJob("Upgrade tools", Feat.upgradeTools)
    end)
    local upLabel = UpBox:AddLabel("", true)
    loop(3, function()
        local parts = {}
        for _, item in inventoryItems() do
            local need = item:GetAttribute("LevelUpXP")
            if need and (item:GetAttribute("ToolName") == "Fishing Rod" or item:GetAttribute("ToolName") == "Taming Flute") then
                table.insert(parts, string.format("%s %d/%d XP", item.Name, item:GetAttribute("XP") or 0, need))
            end
        end
        setText(upLabel, #parts > 0 and table.concat(parts, " · ") or "No rod or flute in your inventory")
    end)
end

-- Events --------------------------------------------------------------------------
do
    local EventTab = UI.Window:AddTab("Events", "ghost", "Halloween, the Hollow, the jungle and gems")

    local HalloweenBox = EventTab:AddLeftGroupbox("Halloween", "candy")
    toggle(HalloweenBox, "AutoCandy", "Collect candy", "AutoCandy", "Claims each piece of candy that drops, the way the pickup does")
    toggle(HalloweenBox, "AutoTrickOrTreat", "Trick or treat", "AutoTrickOrTreat",
        "Goes to every lit house you haven't visited and knocks (houses answer at night). Pair it with Collect candy",
        function(v)
            if v then
                startJob("Trick or treat", Feat.trickOrTreat)
            elseif Job.name == "Trick or treat" then
                stopJob("Trick or treat off")
            end
        end)
    toggle(HalloweenBox, "AutoLightHouses", "Light dark houses with candles", "AutoLightHouses",
        "While trick or treating, uses a Halloween Candle from the map on houses that aren't lit")
    toggle(HalloweenBox, "AutoPumpkins", "Carve pumpkins", "AutoPumpkins",
        "Places a pumpkin on each carving table, carves it and collects it")

    local HollowBox = EventTab:AddRightGroupbox("The Hollow", "moon-star")
    toggle(HollowBox, "AutoHollowUpgrade", "Pick upgrades", "AutoHollowUpgrade", "Chooses an upgrade as soon as one is ready")
    choice(HollowBox, "HollowUpgradePick", "Which", "HollowUpgradePick", { "First offer", "Second offer" })
    HollowBox:AddButton({
        Text = "Go to the entrance",
        Func = function()
            task.spawn(function()
                local pos = Feat.hollowEntrance()
                if typeof(pos) == "Vector3" then
                    teleportTo(pos)
                elseif typeof(pos) == "CFrame" then
                    teleportTo(pos.Position)
                else
                    notify("The Hollow", "The server didn't give an entrance yet", 3)
                end
            end)
        end,
    }):AddButton({
        Text = "Visit plants",
        Func = function()
            startJob("Hollow plants", Feat.hollowPlants)
        end,
    })
    HollowBox:AddLabel("Hollow trees count for auto chop and the tree farm", true)

    local JungleBox = EventTab:AddLeftGroupbox("Jungle", "key-round")
    toggle(JungleBox, "AutoTempleKeys", "Crystal skulls to the temple", "AutoTempleKeys",
        "Puts each Crystal Skull Key on an empty jungle temple podium")
    toggle(JungleBox, "AutoKeys", "Use keys on their locks", "AutoKeys", "Takes each key to the lock it opens")

    local GemBox = EventTab:AddRightGroupbox("Gems", "gem")
    toggle(GemBox, "AutoGemClaim", "Claim gem rain and diamond tree gems", "AutoGemClaim", nil, function(v)
        if v then
            Feat.claimAllDiamonds()
        end
    end)
    toggle(GemBox, "AutoMergeGems", "Merge green gem pieces", "AutoMergeGems")
end

-- Explore -------------------------------------------------------------------------
do
    local ExploreTab = UI.Window:AddTab("Explore", "compass", "Kids, chests, loot and shops")

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
        for _, idx in { "FarmTrees", "AutoTrickOrTreat" } do
            if Options[idx] and Options[idx].Value then
                Options[idx]:SetValue(false)
            end
        end
        stopJob("Stopped")
    end)
    toggle(RunBox, "ReturnAfterRun", "Go back to where I was after a chest run", "ReturnAfterRun")
    slider(RunBox, "RunSpeed", "Run speed", "RunSpeed", 100, 600, " studs/s",
        "How fast chest runs and kid rescue travel. Moves by position, so the game's speed check doesn't see it")
    slider(RunBox, "RunHigh", "Fly over mobs by", "RunHigh", 0, 80, " studs",
        "Runs rise this high before crossing the map and drop at the end, out of reach of mobs on the ground. 0 = straight line")
    toggle(RunBox, "SkipGuarded", "Skip chests with mobs next to them", "SkipGuarded",
        "Chest run leaves a chest alone when a hostile mob is this close to it, unless kill aura is on")
    slider(RunBox, "GuardRadius", "Mob distance", "GuardRadius", 5, 40, " studs")
    RunBox:AddLabel("Kid rescue needs a sack. It goes to each kid, picks it up and brings it to the camp fire. Turn on kill aura first", true)

    local KidsBox = ExploreTab:AddRightGroupbox("Lost kids", "baby")
    toggle(KidsBox, "AutoBagKids", "Auto pick up kids", "AutoBagKids",
        "Puts a lost kid in your sack as soon as you're within 15 studs (the game's reach). Needs room in the sack")
    toggle(KidsBox, "AutoDropKids", "Auto drop kids at camp", "AutoDropKids",
        "Takes kids out of your sack when you're within 30 studs of the camp fire")

    local LootBox = ExploreTab:AddRightGroupbox("Loot", "package-open")
    toggle(LootBox, "AutoChests", "Auto open chests in range", "AutoChests",
        "Opens a chest within 12 studs, stone and jungle chests too. Skips locked and opened ones")
    toggle(LootBox, "AutoCoins", "Auto collect coins and diamonds", "AutoCoins")
    slider(LootBox, "CoinRange", "Collect range", "CoinRange", 5, 80, " studs")
    toggle(LootBox, "InstantPrompts", "Instant interact (no hold)", "InstantPrompts", nil, setInstantPrompts)

    local ShopBox = ExploreTab:AddLeftGroupbox("Shops", "store")
    ShopBox:AddLabel("Tool trader (20 coins each, extras as priced)", true)
    for _, row in { { "Old Rod", "Old Taming Flute" }, { "Hammer", "Bandage" } } do
        local function buy(name)
            return function()
                if name == "Hammer" or name == "Bandage" then
                    fire("RequestPurchaseExtra", name)
                else
                    fire("RequestPurchaseTool", name)
                end
                notify("Tool trader", "Asked to buy " .. name, 2)
            end
        end
        ShopBox:AddButton({ Text = row[1], Func = buy(row[1]) }):AddButton({ Text = row[2], Func = buy(row[2]) })
    end
    ShopBox:AddDivider("Beekeeper (honey)")
    local slots = {}
    local slotPicker = ShopBox:AddDropdown("BeekeeperSlot", { Text = "Item", Values = {}, AllowNull = true })
    local function refreshSlots()
        local list, order = Feat.beekeeperSlots()
        slots = list
        slotPicker:SetValues(order)
    end
    ShopBox:AddButton({
        Text = "Buy",
        Func = function()
            local ok, why = Feat.buyBeekeeper(slots[slotPicker.Value])
            notify("Beekeeper", ok and "Bought" or ("Can't buy: " .. tostring(why or "pick an item")), 2)
            task.delay(1, refreshSlots)
        end,
    }):AddButton({ Text = "Refresh", Func = refreshSlots })
    task.defer(refreshSlots)
end

-- Movement ------------------------------------------------------------------------
local refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems, refreshShops
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

    local ShopTpBox = MoveTab:AddRightGroupbox("Shops and benches", "store")
    refreshShops = teleportPicker(ShopTpBox, "TpShop", "Trader, smith or bench", Feat.places, function(model)
        local pos = pivotPos(model)
        return pos and safeSpotNear(pos, 6)
    end)
    ShopTpBox:AddButton("Tool Smith", function()
        local smith = Feat.findToolSmith()
        if smith then
            teleportTo(safeSpotNear(pivotPos(smith), 6))
        else
            notify("Tool Smith", "No Tool Smith on this map yet (the map changes every game, and far parts may not be loaded)", 4)
        end
    end)

    local CaveBox = MoveTab:AddRightGroupbox("Cave travel", "mountain")
    local cavePicker = CaveBox:AddDropdown("CavePoint", { Text = "Cave point", Values = Feat.cavePoints(), AllowNull = true,
        Tooltip = "Uses the game's own cave teleport, with its loading screen and cave lighting" })
    CaveBox:AddButton({
        Text = "Travel",
        Func = function()
            if not cavePicker.Value then
                notify("Caves", "Pick a cave point first", 2)
            elseif not Feat.caveTravel(cavePicker.Value) then
                notify("Caves", "That cave point isn't open", 2)
            end
        end,
    }):AddButton({
        Text = "Refresh",
        Func = function()
            cavePicker:SetValues(Feat.cavePoints())
        end,
    })

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
        local best = nearestOpenableChest()
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
    toggle(EspBox, "EspFishSpots", "Active fishing spots", "EspFishSpots")
    multi(EspBox, "EspItemKinds", "Item types", "EspItemKinds",
        { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency", "Other" },
        { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency" },
        "Sorted by what the item does (burns, feeds, scraps...), so new items fall in on their own")

    local EspSetBox = VisTab:AddRightGroupbox("ESP settings", "sliders-horizontal")
    toggle(EspSetBox, "EspHighlight", "Highlights", "EspHighlight", "On the nearest 30 (Roblox's limit); names show on everything")
    toggle(EspSetBox, "EspShowHealth", "Mob health", "EspShowHealth")
    slider(EspSetBox, "EspDistance", "Max distance", "EspDistance", 50, 2000, " studs")
    slider(EspSetBox, "EspMax", "Max labels", "EspMax", 10, 400, nil, "Only the nearest this many get a label. Fewer = less lag")

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

loop(0.3, updateEsp)

-- Teleport lists fill themselves once things load, and new resource types and
-- item names reach their pickers.
local lastLists = 0
loop(1, function()
    if os.clock() - lastLists > 15 then
        lastLists = os.clock()
        for _, refresh in { refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems, refreshShops } do
            pcall(refresh)
        end
    end
    -- The item picker only rebuilds when an item name came or went.
    refreshBringItems(false)
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
        setText(UI.BringStatus, string.format("Bringing %d / %d", math.min(Bring.done, Bring.total), Bring.total))
    elseif Bring.total > 0 then
        setText(UI.BringStatus, string.format("Done: %d item%s", Bring.total, Bring.total == 1 and "" or "s"))
    end
    setText(UI.JobLabel, Job.name and (Job.name .. ": " .. Job.status) or Job.status)
end)

-- Dashboard.
do
local Phase = { state = nil, max = 1, day = nil, weather = nil, cultist = nil, missing = nil }
local ChasedBy = {}
local startTime = os.clock()

loop(0.5, function()
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
    local hrp = rootPart()
    do
        for model in Index.mobs do
            local kind = model.Parent and mobKind(model)
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
    setText(UI.AuraNearLabel, string.format("Nearby: %d hostile · %d can attack · %d passive", counts.Hostile, counts["Can attack"], counts.Passive))
    setText(UI.AxeLabel, "Axe: " .. SwingInfo.axe)
    setText(UI.WeaponLabel, "Weapon: " .. SwingInfo.weapon)
    if (Settings.AutoChop or FarmTarget) and SwingInfo.blocked > 0 then
        setText(UI.BlockedLabel, string.format("%d tree%s in range need%s a tier %s axe",
            SwingInfo.blocked, SwingInfo.blocked == 1 and "" or "s", SwingInfo.blocked == 1 and "s" or "",
            tostring(SwingInfo.blockedTier or "?")))
    else
        setText(UI.BlockedLabel, "")
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
    setText(UI.QuestLabel, "Daily quests\n" .. Feat.dailyQuests() .. string.format("\nCandy %d · Honey %d · Coins %d",
        LocalPlayer:GetAttribute("Candy") or 0, Workspace:GetAttribute("TotalHoney") or 0, LocalPlayer:GetAttribute("Coins") or 0))
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
end)()

--// Last Stop -------------------------------------------------------------------------
-- Built against a script dump of the live game (place 122776220269735, version 62).
--
-- What the game's own client scripts show:
--  * Everything runs on Knit (ReplicatedStorage.ClientSource.Mutual.Packages.Knit) and
--    ReplicaService. Every item, mob, the bus and you have a replica, kept in
--    Shared.ReplicaInstance.ReplicaInstances[id], where id is the instance's Name (a
--    UUID; the bus is "Bus"). Item features talk to the server with
--    replica:FireServer(<feature>, <action>, ...).
--  * Grabbing: replica:FireServer("Grab", "RequestStartGrab") makes you the item's
--    Data.CurrentHolder and your client carries it; ("Grab", "ForceStopGrab") lets go.
--    The client only lets you grab within 10 studs.
--  * The bus furnace burns whatever fuel you're holding: bus replica
--    FireServer("Furnace", "RequestBurn"). Fuel items carry a Feature_Fuel attribute
--    (dead mobs too). Bus Data: Fuel, MaxFuel, Speed, AttachedWheels.
--  * Driving is your character's move input (the game sets the controls' moveVector
--    while you sit in the driver seat).
--  * Guns: Firearm asks AimAssist.Adjust(origin, direction, range, config) for the
--    aim direction, then FireServer("Firearm", "Fire", direction, pellets, hits).
--    Replacing Adjust is silent aim through the game's own code. Melee:
--    FireServer("Melee", "Attack", look, order) then ("Melee", "Hit", part, pos,
--    normal, material) per target the client found.
--  * Mobs live in Workspace.ENTITY_CONTAINER, tagged "Entity", with replica Data.Health.
--    Items live in Workspace.ITEM_CONTAINER; the item's real name is its replica's
--    Tags.Name, and the game files every item under Assets.Mutual.Item.Category.<group>.
--  * GameReplica Data: Cycle, IsDay, NextCycle, GameMode, StartPosition, EndPosition.
--    Your player replica Data: Hunger, MaxHunger, CharacterState. Your wallet is
--    PlayerProfile Data.Wallet.
--  * Sprinting has no stamina; it's only blocked while you're hungry.
--  * No client anti cheat. Admins are listed in Config.Places (UserIds) and rank 31+ in
--    group 1040745973.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local FOLDER = "LastStop"
local STAFF_IDS = { [1214392104] = true, [94853864] = true, [106377417] = true, [5013420553] = true,
    [437492645] = true, [10378964019] = true }
local STAFF_GROUP = 1040745973

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__LastStopUnload then
    pcall(Genv.__LastStopUnload)
end
Genv.__LastStopRun = (Genv.__LastStopRun or 0) + 1
local RUN = Genv.__LastStopRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__LastStopRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    else
        warn("[Ui3] could not resolve the latest commit, falling back to main: " .. tostring(sha))
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
local Options = Library.Options

local S = {
    -- combat
    SilentAim = false, AimPart = "Head", AimMode = "Crosshair", AimFov = 25, AimRange = 300, AimWallCheck = true,
    ShowFov = false, FovColor = Color3.fromRGB(255, 151, 227), IgnoreTypes = "Dog",
    MeleeAura = false, MeleeRange = 12, MeleeTargets = 3, MeleeDelay = 450,
    GunAura = false, GunRange = 150, GunRate = 4, AutoReload = true,
    -- bus
    AutoFuel = false, FuelBelow = 60, FuelGroup = "Fuel", AutoDrive = false, ClearRoad = false, ClearRange = 40,
    -- bring
    BringGroup = "Fuel", BringDest = "Me", BringMethod = "Auto", BringMax = 25, BringRange = 400,
    BringSkipNear = true, BringDelay = 60, GrabTimeout = 600, SavedSpot = nil, AutoBring = false, AutoBringEvery = 15,
    -- loot
    AutoChests = false, ChestRange = 0, AutoSell = false, SellGroup = "Valuables",
    -- survival
    AutoEat = false, EatBelow = 40, EatRange = 60, AlwaysSprint = false, InstantPrompts = false,
    -- movement
    Speed = false, SpeedValue = 30, SpeedMethod = "CFrame", Fly = false, FlySpeed = 60, Noclip = false, InfJump = false,
    TpMethod = "Instant",
    -- visuals
    EspMobs = false, EspItems = false, EspItemGroups = { Fuel = true, Valuables = true, Chests = true },
    EspPlayers = false, EspDistance = 500, EspHighlight = true, Fullbright = false, NoFog = false,
    -- staff / lobby
    StaffDetect = true, StaffGroupRank = 31, StaffActions = { Notify = true, ["Pause auto features"] = true },
    AutoPlayAgain = false, AntiAfk = true,
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local ok, c = pcall(signal.Connect, signal, fn)
    if ok and c then
        table.insert(Connections, c)
    end
    return c
end

local function getHui()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    return (ok and hui) or CoreGui
end

local VisualGui = Instance.new("ScreenGui")
VisualGui.Name = "LastStopVisuals"
VisualGui.IgnoreGuiInset = true
VisualGui.ResetOnSpawn = false
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
local function pivotPos(inst)
    if not inst or not inst.Parent then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.Position
    end
    local ok, cf = pcall(inst.GetPivot, inst)
    return ok and cf.Position or nil
end
local function distanceTo(pos)
    local hrp = rootPart()
    return (hrp and pos) and (hrp.Position - pos).Magnitude or math.huge
end
local function anyPart(model)
    if model:IsA("BasePart") then
        return model
    end
    return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Main", true)
        or model:FindFirstChildWhichIsA("BasePart", true)
end
local function notify(title, text, time)
    pcall(function()
        Library:Notify({ Title = title, Description = text, Time = time or 4 })
    end)
end
local function fileOk()
    return typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
end

--// The game's own tables \\--
local G = { knit = nil, replicas = nil, aim = nil, aimOriginal = nil, sprint = nil }
do
    local function try(f)
        local ok, r = pcall(f)
        return ok and r or nil
    end
    local knit = try(function()
        return require(ReplicatedStorage.ClientSource.Mutual.Packages.Knit)
    end)
    if knit and not try(function()
        return knit.GetController("ItemController")
    end) then
        knit = nil
    end
    local replicas = try(function()
        return require(ReplicatedStorage.ClientSource.Mutual.Shared.ReplicaInstance).ReplicaInstances
    end)
    if replicas and next(replicas) == nil then
        replicas = nil
    end
    local aim = try(function()
        return require(ReplicatedStorage.ClientSource.Game.Packages.Modules.Item.Types.Weapon.Firearm.Handlers.AimAssist)
    end)
    -- A require that ran the module fresh gives empty copies; the game's own are in the gc.
    if (not knit or not replicas) and typeof(getgc) == "function" then
        pcall(function()
            for _, v in getgc(true) do
                if type(v) == "table" then
                    if not knit and rawget(v, "GetController") and rawget(v, "CreateController") and rawget(v, "Player") then
                        knit = v
                    elseif not replicas and type(rawget(v, "ReplicaInstances")) == "table" and next(rawget(v, "ReplicaInstances")) then
                        replicas = rawget(v, "ReplicaInstances")
                    end
                    if knit and replicas then
                        break
                    end
                end
            end
        end)
    end
    G.knit, G.replicas, G.aim = knit, replicas, aim
    if knit then
        G.sprint = try(function()
            return knit.GetController("SprintController")
        end)
        G.replicaController = try(function()
            return knit.GetController("ReplicaController")
        end)
    end
end

local function replicaOf(inst)
    if not inst then
        return nil
    end
    local id = typeof(inst) == "string" and inst or inst.Name
    local r = G.replicas and G.replicas[id]
    if r then
        return r
    end
    local controller = G.replicaController
    if controller and controller.TryGetReplicaInstance then
        local ok, rep = pcall(controller.TryGetReplicaInstance, controller, id)
        if ok then
            return rep
        end
    end
    return nil
end

local function fireReplica(rep, ...)
    if not rep then
        return false
    end
    return (pcall(rep.FireServer, rep, ...))
end

local function classReplica(class)
    local controller = G.replicaController
    return controller and controller.Replicas and controller.Replicas[class]
end

local function knitRemote(service, kind, name)
    local ok, r = pcall(function()
        return ReplicatedStorage.ClientSource.Mutual.Packages.Knit.Services[service][kind][name]
    end)
    return ok and r or nil
end

local function containers()
    return Workspace:FindFirstChild("ITEM_CONTAINER"), Workspace:FindFirstChild("ENTITY_CONTAINER")
end

--// Items: names and groups \\--
local ItemInfo = {} -- name -> { category = "Food", sub = "Melee" }
local ItemNames = {}
do
    local root = ReplicatedStorage:FindFirstChild("Assets")
    root = root and root:FindFirstChild("Mutual")
    root = root and root:FindFirstChild("Item")
    root = root and root:FindFirstChild("Category")
    local skip = { src = true, Model = true, VFX = true, SFX = true, Animation = true, Interface = true, Update = true }
    local function walk(folder, category, sub)
        for _, child in folder:GetChildren() do
            if child:IsA("Folder") and not skip[child.Name] then
                local src = child:FindFirstChild("src")
                local isItem = child:FindFirstChild("Model") ~= nil or (src ~= nil and src:FindFirstChild("Config") ~= nil)
                if isItem and category then
                    if not ItemInfo[child.Name] then
                        ItemInfo[child.Name] = { category = category, sub = sub }
                        table.insert(ItemNames, child.Name)
                    end
                else
                    walk(child, category or child.Name, category and child.Name or nil)
                end
            end
        end
    end
    if root then
        walk(root, nil, nil)
    end
    table.sort(ItemNames)
end

local function itemName(inst)
    local rep = replicaOf(inst)
    local name = rep and rep.Tags and rep.Tags.Name
    if not name and inst:GetAttribute("Class") == "Entity" then
        name = "Corpse: " .. tostring(inst:GetAttribute("Type") or "?")
    end
    return name or inst:GetAttribute("Class") or inst.Name
end

-- Default groups, by what the game files items under (and what they do).
local DEFAULT_GROUPS = {
    Fuel = function(name, inst)
        local info = ItemInfo[name]
        return (info and info.category == "Fuel") or (inst and inst:GetAttribute("Feature_Fuel") ~= nil and inst:GetAttribute("Class") ~= "Entity")
    end,
    Corpses = function(name)
        return string.sub(name, 1, 8) == "Corpse: "
    end,
    Valuables = function(name)
        local info = ItemInfo[name]
        return info and (info.category == "Valuable" or name == "CashBag")
    end,
    Food = function(name)
        local info = ItemInfo[name]
        return info and info.category == "Food"
    end,
    Medical = function(name)
        local info = ItemInfo[name]
        return info and (info.category == "Medic" or info.category == "Potion")
    end,
    Weapons = function(name)
        local info = ItemInfo[name]
        return info and (info.category == "Weapon" or info.category == "Ammo" or info.category == "Attachment" or info.category == "Explosive")
    end,
    Junk = function(name, inst)
        local info = ItemInfo[name]
        return (info and info.category == "Junk") or (inst and inst:GetAttribute("Feature_Type") == "Junk")
    end,
    Materials = function(name, inst)
        local info = ItemInfo[name]
        return (info and info.category == "Resources") or (inst and inst:GetAttribute("Feature_Type") == "Wood")
    end,
    Wheels = function(name, inst)
        local info = ItemInfo[name]
        return (info and info.category == "Wheel") or (inst and inst:GetAttribute("Feature_Type") == "Wheel")
    end,
    Gear = function(name)
        local info = ItemInfo[name]
        return info and (info.category == "Armor" or info.category == "Backpack" or info.category == "Misc" or info.category == "Radio")
    end,
    Chests = function(name, inst)
        local info = ItemInfo[name]
        return (info and info.category == "Chest") or (inst and inst:GetAttribute("Feature_Chest") == true)
    end,
}
local GROUP_NAMES = { "Fuel", "Corpses", "Valuables", "Food", "Medical", "Weapons", "Junk", "Materials", "Wheels", "Gear", "Chests", "Custom 1", "Custom 2" }

-- Groups are sets of names you can edit: { [group] = { [name] = true } }. Names
-- seen in the world get added to the default groups they fit.
local Groups = {}
local Edited = {} -- groups you changed by hand keep exactly your picks
local function defaultMember(group, name, inst)
    local rule = DEFAULT_GROUPS[group]
    return rule ~= nil and rule(name, inst) == true
end
local function resetGroup(group)
    Groups[group] = {}
    Edited[group] = nil
    for _, name in ItemNames do
        if defaultMember(group, name, nil) then
            Groups[group][name] = true
        end
    end
end
for _, group in GROUP_NAMES do
    resetGroup(group)
end

local SeenNames = {}
local function noteName(name, inst)
    if SeenNames[name] then
        return
    end
    SeenNames[name] = true
    if not ItemInfo[name] then
        table.insert(ItemNames, name)
        table.sort(ItemNames)
    end
    for _, group in GROUP_NAMES do
        if not Edited[group] and defaultMember(group, name, inst) then
            Groups[group][name] = true
        end
    end
end

local function inGroup(group, inst)
    local name = itemName(inst)
    noteName(name, inst)
    local set = Groups[group]
    return set ~= nil and set[name] == true, name
end

local function saveGroups()
    if not fileOk() then
        return
    end
    pcall(function()
        if typeof(isfolder) == "function" and not isfolder(FOLDER) then
            makefolder(FOLDER)
        end
        local out = {}
        for group in Edited do
            local list = {}
            for name in Groups[group] do
                table.insert(list, name)
            end
            out[group] = list
        end
        writefile(FOLDER .. "/groups.json", HttpService:JSONEncode(out))
    end)
end
local function loadGroups()
    if not fileOk() or not isfile(FOLDER .. "/groups.json") then
        return
    end
    pcall(function()
        local data = HttpService:JSONDecode(readfile(FOLDER .. "/groups.json"))
        for group, list in data do
            if Groups[group] then
                Groups[group] = {}
                Edited[group] = true
                for _, name in list do
                    Groups[group][name] = true
                end
            end
        end
    end)
end
loadGroups()

local function worldItems()
    local items = {}
    local itemFolder = containers()
    if itemFolder then
        for _, inst in itemFolder:GetChildren() do
            if inst:GetAttribute("Feature_Grab") and not inst:GetAttribute("Feature_Bus") then
                items[#items + 1] = inst
            end
        end
    end
    -- Dead mobs lie in the workspace root with Class = "Entity".
    for _, inst in Workspace:GetChildren() do
        if inst:IsA("Model") and inst:GetAttribute("Class") == "Entity" and inst:GetAttribute("Feature_Grab") then
            items[#items + 1] = inst
        end
    end
    return items
end

--// Bus \\--
local function busModel()
    local itemFolder = containers()
    if not itemFolder then
        return nil
    end
    local bus = itemFolder:FindFirstChild("Bus")
    if bus and bus:GetAttribute("Feature_Bus") then
        return bus
    end
    for _, inst in itemFolder:GetChildren() do
        if inst:GetAttribute("Feature_Bus") then
            return inst
        end
    end
    return nil
end
local function busReplica()
    return replicaOf(busModel())
end
local function busFuel()
    local rep = busReplica()
    local data = rep and rep.Data
    return data and data.Fuel, data and data.MaxFuel, data
end
local function burnPart()
    local bus = busModel()
    return bus and (bus:FindFirstChild("BurnPart", true) or bus:FindFirstChild("FurnaceBurn", true))
end

--// Teleport \\--
local function teleport(cf)
    local hrp = rootPart()
    if not hrp or not cf then
        return false
    end
    if typeof(cf) == "Vector3" then
        cf = CFrame.new(cf)
    end
    hrp.CFrame = cf
    hrp.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- Every ProximityPrompt in the workspace, kept up to date (scanning 50k parts each tick is slow).
local Prompts = {}
for _, inst in Workspace:GetDescendants() do
    if inst:IsA("ProximityPrompt") then
        Prompts[inst] = true
    end
end
bind(Workspace.DescendantAdded, function(inst)
    if inst:IsA("ProximityPrompt") then
        Prompts[inst] = true
    end
end)
bind(Workspace.DescendantRemoving, function(inst)
    Prompts[inst] = nil
end)

--// Bring: fetch with the game's own grab \\--
local Bring = { token = 0, running = false, done = 0, total = 0, status = "Idle" }
local BRING_DESTS = { "Me", "Bus", "Furnace (burn)", "Sell conveyor", "Saved spot" }

local function holder(rep)
    local data = rep and rep.Data
    return data and data.CurrentHolder
end

local function sellZone()
    local best, bestD
    for prompt in Prompts do
        if prompt.Name == "SellOnConveyorPrompt" and prompt.Parent then
            local pos = pivotPos(prompt.Parent)
            local d = distanceTo(pos)
            if pos and (not bestD or d < bestD) then
                best, bestD = prompt, d
            end
        end
    end
    return best
end

local function destinationFrame(dest, home)
    if dest == "Bus" then
        local bus = busModel()
        local pos = pivotPos(bus)
        return pos and CFrame.new(pos + Vector3.new(0, 6, 0))
    elseif dest == "Furnace (burn)" then
        local part = burnPart()
        return part and (part.CFrame * CFrame.new(0, 0, -4))
    elseif dest == "Sell conveyor" then
        local prompt = sellZone()
        local pos = prompt and pivotPos(prompt.Parent)
        return pos and CFrame.new(pos + Vector3.new(0, 3, 4), pos)
    elseif dest == "Saved spot" then
        return S.SavedSpot
    end
    return home
end

local function grab(rep)
    fireReplica(rep, "Grab", "RequestStartGrab")
    local t0 = os.clock()
    while os.clock() - t0 < S.GrabTimeout / 1000 do
        if holder(rep) == LocalPlayer then
            return true
        end
        RunService.Heartbeat:Wait()
    end
    return holder(rep) == LocalPlayer
end

local function release(rep)
    if holder(rep) == LocalPlayer then
        fireReplica(rep, "Grab", "ForceStopGrab")
    end
end

-- Fetches one item: walk up to it (teleport), grab it, carry it to the spot, let go.
local function bringOne(inst, dest, stand)
    local rep = replicaOf(inst)
    local hrp = rootPart()
    if not rep or not hrp or not inst.Parent then
        return false
    end
    local current = holder(rep)
    if current and current ~= LocalPlayer then
        return false
    end
    local lock = rep.Data and rep.Data.OwnerLock
    if lock and lock ~= LocalPlayer.UserId then
        return false
    end
    local pos = pivotPos(inst)
    if not pos then
        return false
    end
    local near = (pos - hrp.Position).Magnitude <= 8
    local got = false
    if near or S.BringMethod == "Pull" then
        got = grab(rep)
    end
    if not got and S.BringMethod ~= "Pull" then
        -- The game only grabs from about 10 studs: step up to it first.
        teleport(CFrame.new(pos + Vector3.new(0, 3, 0)))
        task.wait()
        got = grab(rep)
    end
    if not got then
        return false
    end
    -- Carry: you stand at the drop spot and the game's grab keeps the item in front of you.
    teleport(stand)
    task.wait(0.12)
    if dest == "Furnace (burn)" then
        fireReplica(busReplica(), "Furnace", "RequestBurn")
        task.wait(0.15)
    end
    release(rep)
    return true
end

local function bringList(group, dest, limit)
    local hrp = rootPart()
    if not hrp then
        return {}
    end
    local target = destinationFrame(dest, hrp.CFrame)
    local list = {}
    for _, inst in worldItems() do
        local member = inGroup(group, inst)
        if member then
            local pos = pivotPos(inst)
            local d = pos and (pos - hrp.Position).Magnitude
            local there = target and pos and (pos - target.Position).Magnitude < 10
            if d and d <= S.BringRange and not (S.BringSkipNear and there) then
                local rep = replicaOf(inst)
                local busy = rep and holder(rep) and holder(rep) ~= LocalPlayer
                if not busy then
                    list[#list + 1] = { inst = inst, d = d }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        return a.d < b.d
    end)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i].inst
    end
    return out
end

local function runBring(group, dest, limit, onDone)
    if Bring.running then
        return 0
    end
    local list = bringList(group, dest, limit or S.BringMax)
    Bring.total, Bring.done = #list, 0
    if #list == 0 then
        Bring.status = "Nothing in " .. group .. " to bring"
        return 0
    end
    Bring.token += 1
    local token = Bring.token
    Bring.running = true
    Bring.status = "Bringing " .. group
    task.spawn(function()
        local hrp = rootPart()
        local home = hrp and hrp.CFrame
        local stand = destinationFrame(dest, home) or home
        local moved = 0
        for _, inst in list do
            if token ~= Bring.token or not alive() then
                break
            end
            if dest == "Furnace (burn)" then
                local fuel, maxFuel = busFuel()
                if fuel and maxFuel and fuel >= maxFuel then
                    Bring.status = "Bus is full"
                    break
                end
            end
            if pcall(bringOne, inst, dest, stand) then
                moved += 1
            end
            Bring.done += 1
            task.wait(S.BringDelay / 1000)
        end
        if dest == "Sell conveyor" then
            local prompt = sellZone()
            if prompt and typeof(fireproximityprompt) == "function" then
                task.wait(0.3)
                prompt.HoldDuration = 0
                pcall(fireproximityprompt, prompt)
            end
        end
        if dest ~= "Me" and home and token == Bring.token then
            teleport(home)
        end
        Bring.status = string.format("Brought %d / %d", moved, #list)
        Bring.running = false
        if onDone then
            pcall(onDone, moved)
        end
    end)
    return #list
end

--// Mobs \\--
local IgnoreTypes = {}
local function refreshIgnore()
    IgnoreTypes = {}
    for word in string.gmatch(string.lower(S.IgnoreTypes or ""), "[%w_]+") do
        IgnoreTypes[word] = true
    end
end
refreshIgnore()

local function mobHealth(model)
    local rep = replicaOf(model)
    local data = rep and rep.Data
    if data and data.Health then
        return data.Health, data.MaxHealth or data.Health
    end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        return hum.Health, hum.MaxHealth
    end
    return 1, 1
end

local function mobAlive(model)
    if not model.Parent then
        return false
    end
    local kind = model:GetAttribute("Type")
    if kind and IgnoreTypes[string.lower(tostring(kind))] then
        return false
    end
    local hp = mobHealth(model)
    return hp > 0
end

local function mobs()
    local list = {}
    local _, entityFolder = containers()
    local seen = {}
    if entityFolder then
        for _, model in entityFolder:GetChildren() do
            if model:IsA("Model") and model:GetAttribute("Type") then
                seen[model] = true
                list[#list + 1] = model
            end
        end
    end
    for _, model in CollectionService:GetTagged("Entity") do
        if not seen[model] and model:IsA("Model") and model:IsDescendantOf(Workspace) and model:GetAttribute("Class") ~= "Entity" then
            list[#list + 1] = model
        end
    end
    return list
end

local function aimPoint(model)
    local part = (S.AimPart == "Head" and model:FindFirstChild("Head"))
        or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("UpperTorso") or anyPart(model)
    return part and part.Position, part
end

local function visible(origin, pos, model)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { Camera, character() }
    local hit = Workspace:Raycast(origin, pos - origin, params)
    return not hit or hit.Instance:IsDescendantOf(model)
end

-- Best target for a shot from `origin` looking along `dir`.
local function pickTarget(origin, dir, range)
    local best, bestScore
    local fov = math.rad(S.AimFov)
    for _, model in mobs() do
        if mobAlive(model) then
            local pos = aimPoint(model)
            if pos then
                local offset = pos - origin
                local dist = offset.Magnitude
                if dist > 0 and dist <= range then
                    local angle = dir:Angle(offset.Unit)
                    if angle <= fov and (not S.AimWallCheck or visible(origin, pos, model)) then
                        local score = S.AimMode == "Closest" and dist or angle
                        if not bestScore or score < bestScore then
                            best, bestScore = model, score
                        end
                    end
                end
            end
        end
    end
    return best
end

-- Silent aim: the game asks AimAssist.Adjust for every shot's direction. The table
-- the game holds is patched (found through getgc when require gave a fresh copy).
local AimPatches = {}
local function patchAim(tbl)
    if type(tbl) ~= "table" or AimPatches[tbl] or type(rawget(tbl, "Adjust")) ~= "function" then
        return
    end
    local original = rawget(tbl, "Adjust")
    AimPatches[tbl] = original
    tbl.Adjust = function(origin, dir, range, config, ...)
        if alive() and S.SilentAim then
            local ok, target = pcall(pickTarget, origin, dir, math.min(range or S.AimRange, S.AimRange))
            if ok and target then
                local pos = aimPoint(target)
                if pos and (pos - origin).Magnitude > 0 then
                    return (pos - origin).Unit
                end
            end
        end
        return original(origin, dir, range, config, ...)
    end
end
patchAim(G.aim)
if typeof(getgc) == "function" then
    pcall(function()
        for _, v in getgc(true) do
            if type(v) == "table" and type(rawget(v, "Adjust")) == "function" then
                local keys = 0
                for _ in v do
                    keys += 1
                end
                if keys == 1 then
                    patchAim(v)
                end
            end
        end
    end)
end
G.aimOriginal = next(AimPatches) ~= nil

-- Held weapon: the Tool in your character, named by its item id.
local function heldWeapon()
    local c = character()
    local tool = c and c:FindFirstChildOfClass("Tool")
    if not tool then
        return nil
    end
    local rep = replicaOf(tool)
    local name = rep and rep.Tags and rep.Tags.Name or tool.Name
    local info = ItemInfo[name]
    local kind = info and info.category == "Weapon" and info.sub or nil
    return rep, kind, name
end

local nextMelee, meleeOrder, nextGun = 0, 1, 0
local function auraTick()
    if not (S.MeleeAura or S.GunAura) then
        return
    end
    local now = os.clock()
    local hrp = rootPart()
    if not hrp then
        return
    end
    local rep, kind = heldWeapon()
    if not rep then
        return
    end
    if kind == "Melee" and S.MeleeAura and now >= nextMelee then
        local targets = {}
        for _, model in mobs() do
            if mobAlive(model) then
                local pos, part = aimPoint(model)
                local d = pos and (pos - hrp.Position).Magnitude
                if d and d <= S.MeleeRange and part then
                    targets[#targets + 1] = { part = part, d = d }
                end
            end
        end
        if #targets > 0 then
            table.sort(targets, function(a, b)
                return a.d < b.d
            end)
            nextMelee = now + S.MeleeDelay / 1000
            local look = (targets[1].part.Position - hrp.Position).Unit
            fireReplica(rep, "Melee", "Attack", look, meleeOrder)
            meleeOrder = meleeOrder % 3 + 1
            task.delay(0.12, function()
                for i = 1, math.min(S.MeleeTargets, #targets) do
                    local part = targets[i].part
                    if part.Parent then
                        fireReplica(rep, "Melee", "Hit", part, part.Position, -look, part.Material)
                    end
                end
            end)
        end
    elseif kind == "Firearm" and S.GunAura and now >= nextGun then
        local origin = Camera.CFrame.Position
        local target = pickTarget(origin, Camera.CFrame.LookVector, S.GunRange)
        if not target then
            -- Any direction: the closest mob in range you can see.
            local best, bestD
            for _, model in mobs() do
                if mobAlive(model) then
                    local pos = aimPoint(model)
                    local d = pos and (pos - origin).Magnitude
                    if d and d <= S.GunRange and (not bestD or d < bestD) and visible(origin, pos, model) then
                        best, bestD = model, d
                    end
                end
            end
            target = best
        end
        if target then
            local pos = aimPoint(target)
            local dir = (pos - origin).Unit
            nextGun = now + 1 / math.max(S.GunRate, 0.5)
            local magazine = rep.Data and (rep.Data.Ammo or rep.Data.Magazine)
            if S.AutoReload and type(magazine) == "number" and magazine <= 0 then
                fireReplica(rep, "Firearm", "Reload")
                nextGun = now + 1.5
            else
                fireReplica(rep, "Firearm", "Fire", dir, { dir }, nil)
            end
        end
    end
end

--// Prompts: chests, road blocks, instant hold \\--
local ROAD_PROMPTS = { RemoveTreePrompt = true, RaiseBarrierPrompt = true, RemoveTrap = true }
local Fired = setmetatable({}, { __mode = "k" })
local function firePrompt(prompt)
    if typeof(fireproximityprompt) ~= "function" then
        return false
    end
    local last = Fired[prompt]
    if last and os.clock() - last < 2 then
        return false
    end
    Fired[prompt] = os.clock()
    local hold = prompt.HoldDuration
    prompt.HoldDuration = 0
    pcall(fireproximityprompt, prompt)
    task.delay(0.3, function()
        if prompt.Parent and not S.InstantPrompts then
            prompt.HoldDuration = hold
        end
    end)
    return true
end

local function promptTick()
    local hrp = rootPart()
    if not hrp or not (S.AutoChests or S.ClearRoad) then
        return
    end
    for prompt in Prompts do
        if prompt.Parent and prompt.Enabled then
            local isChest = prompt.Name == "OpenChestPrompt"
            local isRoad = ROAD_PROMPTS[prompt.Name]
                or (prompt.ActionText == "Remove" and prompt.ObjectText == "Barricade")
            if (isChest and S.AutoChests) or (isRoad and S.ClearRoad) then
                local pos = pivotPos(prompt.Parent)
                local reach = isChest and (S.ChestRange > 0 and S.ChestRange or prompt.MaxActivationDistance)
                    or S.ClearRange
                if pos and (pos - hrp.Position).Magnitude <= reach then
                    if (pos - hrp.Position).Magnitude > prompt.MaxActivationDistance then
                        local home = hrp.CFrame
                        teleport(CFrame.new(pos + Vector3.new(0, 3, 0)))
                        task.wait(0.1)
                        firePrompt(prompt)
                        task.wait(0.1)
                        teleport(home)
                    else
                        firePrompt(prompt)
                    end
                end
            end
        end
    end
end

local PromptHolds = setmetatable({}, { __mode = "k" })
local function setInstantPrompts(on)
    for prompt in Prompts do
        if prompt.Parent then
            if on and prompt.HoldDuration > 0 then
                PromptHolds[prompt] = PromptHolds[prompt] or prompt.HoldDuration
                prompt.HoldDuration = 0
            elseif not on and PromptHolds[prompt] then
                prompt.HoldDuration = PromptHolds[prompt]
            end
        end
    end
    if not on then
        table.clear(PromptHolds)
    end
end
bind(Workspace.DescendantAdded, function(inst)
    if S.InstantPrompts and inst:IsA("ProximityPrompt") then
        task.defer(function()
            PromptHolds[inst] = inst.HoldDuration
            inst.HoldDuration = 0
        end)
    end
end)

--// You \\--
local function playerReplica()
    local knit = G.knit
    local ok, comp = pcall(function()
        return knit.Components.Player:FromInstance(LocalPlayer)
    end)
    return ok and comp and comp.Replica or nil
end

local lastEat = 0
local function eatTick()
    if not S.AutoEat or os.clock() - lastEat < 3 then
        return
    end
    local rep = playerReplica()
    local data = rep and rep.Data
    if not data or not data.Hunger then
        return
    end
    local maxHunger = data.MaxHunger or 100
    if data.Hunger / maxHunger * 100 >= S.EatBelow then
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    local best, bestD
    for _, inst in worldItems() do
        if inGroup("Food", inst) then
            local d = distanceTo(pivotPos(inst))
            if d <= S.EatRange and (not bestD or d < bestD) then
                best, bestD = inst, d
            end
        end
    end
    if not best then
        return
    end
    lastEat = os.clock()
    local eat = knitRemote("ItemService", "RF", "Eat")
    local home = hrp.CFrame
    if bestD > 8 then
        teleport(CFrame.new(pivotPos(best) + Vector3.new(0, 3, 0)))
        task.wait(0.1)
    end
    if eat then
        pcall(eat.InvokeServer, eat, best)
    end
    if bestD > 8 then
        task.wait(0.1)
        teleport(home)
    end
end

--// Movement \\--
local Controls
task.spawn(function()
    pcall(function()
        Controls = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)):GetControls()
    end)
end)

local function moveInput()
    if Controls then
        local ok, v = pcall(Controls.GetMoveVector, Controls)
        if ok and v then
            return v
        end
    end
    return Vector3.zero
end

local Fly = { objects = {}, up = false, down = false }
local function stopFly()
    for _, obj in Fly.objects do
        pcall(obj.Destroy, obj)
    end
    table.clear(Fly.objects)
end
local function flyStep()
    local hrp = rootPart()
    if not hrp then
        return
    end
    local lv = Fly.objects.velocity
    if not lv or lv.Parent ~= hrp then
        stopFly()
        local att = Instance.new("Attachment")
        att.Parent = hrp
        lv = Instance.new("LinearVelocity")
        lv.Attachment0 = att
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        lv.MaxForce = math.huge
        lv.Parent = hrp
        local align = Instance.new("AlignOrientation")
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        align.Attachment0 = att
        align.RigidityEnabled = true
        align.Parent = hrp
        Fly.objects.attachment, Fly.objects.velocity, Fly.objects.align = att, lv, align
    end
    local cf = Camera.CFrame
    local input = moveInput()
    local dir = cf.RightVector * input.X + cf.LookVector * -input.Z
    if Fly.up or UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
        dir += Vector3.new(0, 1, 0)
    end
    if Fly.down or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
        dir -= Vector3.new(0, 1, 0)
    end
    if dir.Magnitude > 1 then
        dir = dir.Unit
    end
    lv.VectorVelocity = dir * S.FlySpeed
    local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    if flat.Magnitude > 0.01 then
        Fly.objects.align.CFrame = CFrame.lookAt(Vector3.zero, flat)
    end
end

local FlyButtons = Instance.new("Frame")
FlyButtons.BackgroundTransparency = 1
FlyButtons.AnchorPoint = Vector2.new(1, 1)
FlyButtons.Position = UDim2.new(1, -24, 1, -170)
FlyButtons.Size = UDim2.fromOffset(64, 136)
FlyButtons.Visible = false
FlyButtons.Parent = VisualGui
for i, spec in { { "▲", "up" }, { "▼", "down" } } do
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(64, 64)
    b.Position = UDim2.fromOffset(0, (i - 1) * 72)
    b.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
    b.BackgroundTransparency = 0.2
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 22
    b.Text = spec[1]
    b.Parent = FlyButtons
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
    b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            Fly[spec[2]] = true
        end
    end)
    b.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            Fly[spec[2]] = false
        end
    end)
end

local NoclipParts = {}
local function restoreNoclip()
    for part in NoclipParts do
        if part.Parent then
            part.CanCollide = true
        end
    end
    table.clear(NoclipParts)
end

-- Seated in the bus's driver seat.
local function driving()
    local hum = humanoid()
    local seat = hum and hum.SeatPart
    local bus = busModel()
    return seat ~= nil and bus ~= nil and seat:IsDescendantOf(bus)
end

local function movementStep(dt)
    local hum = humanoid()
    local hrp = rootPart()
    if not hum or not hrp then
        return
    end
    if S.Speed and not driving() then
        if S.SpeedMethod == "WalkSpeed" then
            hum.WalkSpeed = S.SpeedValue
        elseif not S.Fly and hum.MoveDirection.Magnitude > 0 then
            local extra = math.max(0, S.SpeedValue - hum.WalkSpeed)
            hrp.CFrame += hum.MoveDirection * extra * dt
        end
    end
    if S.Fly then
        flyStep()
    end
    FlyButtons.Visible = S.Fly and UserInputService.TouchEnabled
    if S.AlwaysSprint and G.sprint then
        pcall(function()
            if G.sprint.BlockReasons and G.sprint.BlockReasons.Hunger then
                G.sprint.BlockReasons.Hunger = nil
            end
        end)
    end
end

--// Visuals \\--
local Esp = {}
local function dropEsp(inst)
    local e = Esp[inst]
    if e then
        e.bb:Destroy()
        if e.hl then
            e.hl:Destroy()
        end
        Esp[inst] = nil
    end
end
local GROUP_COLORS = {
    Fuel = Color3.fromRGB(255, 170, 60), Corpses = Color3.fromRGB(150, 110, 90), Valuables = Color3.fromRGB(255, 220, 80),
    Food = Color3.fromRGB(120, 220, 120), Medical = Color3.fromRGB(255, 120, 150), Weapons = Color3.fromRGB(255, 90, 90),
    Junk = Color3.fromRGB(170, 170, 170), Materials = Color3.fromRGB(180, 140, 90), Wheels = Color3.fromRGB(120, 160, 255),
    Gear = Color3.fromRGB(180, 120, 255), Chests = Color3.fromRGB(255, 200, 120),
}
local function updateEsp()
    local hrp = rootPart()
    local want = {}
    local function consider(inst, color, text)
        local d = distanceTo(pivotPos(inst))
        if d <= S.EspDistance then
            want[inst] = { color = color, text = text .. string.format(" · %dm", math.floor(d)) }
        end
    end
    if hrp then
        if S.EspMobs then
            for _, model in mobs() do
                if mobAlive(model) then
                    local hp, maxHp = mobHealth(model)
                    consider(model, Color3.fromRGB(255, 80, 80), string.format("%s %d/%d", tostring(model:GetAttribute("Type") or "Mob"), math.floor(hp), math.floor(maxHp)))
                end
            end
        end
        if S.EspItems then
            for _, inst in worldItems() do
                local name = itemName(inst)
                noteName(name, inst)
                for group in S.EspItemGroups do
                    if Groups[group] and Groups[group][name] then
                        consider(inst, GROUP_COLORS[group] or Color3.new(1, 1, 1), name)
                        break
                    end
                end
            end
        end
        if S.EspPlayers then
            for _, p in Players:GetPlayers() do
                if p ~= LocalPlayer and p.Character then
                    consider(p.Character, Color3.fromRGB(120, 180, 255), p.DisplayName)
                end
            end
        end
    end
    for inst in Esp do
        if not want[inst] or not inst.Parent then
            dropEsp(inst)
        end
    end
    for inst, info in want do
        local e = Esp[inst]
        if not e then
            local part = anyPart(inst)
            if part then
                local bb = Instance.new("BillboardGui")
                bb.AlwaysOnTop = true
                bb.Size = UDim2.fromOffset(220, 30)
                bb.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
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
                Esp[inst] = e
            end
        end
        if e then
            e.text.Text = info.text
            e.text.TextColor3 = info.color
            if S.EspHighlight then
                if not e.hl then
                    e.hl = Instance.new("Highlight")
                    e.hl.FillTransparency = 0.8
                    e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    e.hl.Adornee = inst
                    e.hl.Parent = VisualGui
                end
                e.hl.FillColor, e.hl.OutlineColor = info.color, info.color
            elseif e.hl then
                e.hl:Destroy()
                e.hl = nil
            end
        end
    end
end

local FovCircle = Instance.new("Frame")
FovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
FovCircle.BackgroundTransparency = 1
FovCircle.Visible = false
FovCircle.Parent = VisualGui
Instance.new("UICorner", FovCircle).CornerRadius = UDim.new(1, 0)
local FovStroke = Instance.new("UIStroke", FovCircle)
FovStroke.Thickness = 1.5

local LightingSaved
local function lightingStep()
    if not (S.Fullbright or S.NoFog) then
        if LightingSaved then
            for k, v in LightingSaved do
                pcall(function()
                    Lighting[k] = v
                end)
            end
            LightingSaved = nil
        end
        return
    end
    LightingSaved = LightingSaved or {
        Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
        GlobalShadows = Lighting.GlobalShadows, FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart,
    }
    if S.Fullbright then
        Lighting.Brightness = 2
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.GlobalShadows = false
    end
    if S.NoFog then
        Lighting.FogStart, Lighting.FogEnd = 0, 1e6
        for _, effect in Lighting:GetChildren() do
            if effect:IsA("Atmosphere") then
                effect.Density = 0
            end
        end
    end
end

--// Staff \\--
local Staff = { present = false, list = {}, ranks = {} }
local function staffReason(p)
    if STAFF_IDS[p.UserId] then
        return "Admin"
    end
    local rank = Staff.ranks[p.UserId]
    if rank and rank >= S.StaffGroupRank then
        return "group rank " .. rank
    end
    return nil
end
local function paused()
    return S.StaffDetect and Staff.present and S.StaffActions["Pause auto features"] == true
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Last Stop",
    Footer = "dookie hub · Ui3",
    Icon = "bus",
    Size = UDim2.fromOffset(780, 600),
    ConfigFolder = "Ui3/LastStop",
})
local UI = {}
local Log

do -- Dashboard
    local Tab = Window:AddTab("Dashboard", "layout-dashboard", "The trip at a glance")
    local Trip = Tab:AddBigGroupbox("Trip", "route")
    UI.TripCards = Trip:AddStatCards("TripCards", {
        Cards = {
            { Title = "Day", Value = "-", Icon = "calendar" },
            { Title = "Time", Value = "-", Icon = "sun-moon" },
            { Title = "To the last stop", Value = "-", Icon = "flag" },
            { Title = "Mode", Value = "-", Icon = "gamepad-2" },
        },
    })
    UI.TripBar = Trip:AddProgressBar("TripBar", { Text = "Trip", Default = 0, Max = 100, Percent = true })
    local Bus = Tab:AddBigGroupbox("Bus", "bus")
    UI.BusCards = Bus:AddStatCards("BusCards", {
        Cards = {
            { Title = "Fuel", Value = "-", Icon = "fuel" },
            { Title = "Speed", Value = "-", Icon = "gauge" },
            { Title = "Wheels", Value = "-", Icon = "circle-dot" },
            { Title = "Distance to bus", Value = "-", Icon = "map-pin" },
        },
    })
    UI.FuelBar = Bus:AddProgressBar("FuelBar", { Text = "Bus fuel", Default = 0, Max = 100, Percent = false })
    local You = Tab:AddBigGroupbox("You", "user")
    UI.YouCards = You:AddStatCards("YouCards", {
        Cards = {
            { Title = "Health", Value = "-", Icon = "heart" },
            { Title = "Hunger", Value = "-", Icon = "drumstick" },
            { Title = "Wallet", Value = "-", Icon = "wallet" },
            { Title = "Mobs near", Value = "-", Icon = "skull" },
        },
    })
    UI.HungerBar = You:AddProgressBar("HungerBar", { Text = "Hunger", Default = 0, Max = 100, Percent = true })
    UI.Log = You:AddLog("EventLog", { Text = "Events", Height = 130, MaxLines = 150 })
    Log = UI.Log
    UI.HookLabel = You:AddLabel("", true)
end

local function logLine(text, color)
    if Log then
        pcall(Log.Log, Log, text, color)
    end
end

do -- Combat
    local Tab = Window:AddTab("Combat", "crosshair", "Silent aim and auras")
    local Aim = Tab:AddLeftGroupbox("Silent aim", "crosshair")
    Aim:AddToggle("SilentAim", {
        Text = "Silent aim",
        Default = false,
        Tooltip = "Your shots go where the game's own aim assist sends them, pointed at the mob you pick",
        Callback = function(v)
            S.SilentAim = v
        end,
    }):AddKeyPicker("SilentAimKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Silent aim" })
    Aim:AddDropdown("AimPart", { Text = "Aim at", Values = { "Head", "Body" }, Default = S.AimPart, Callback = function(v)
        S.AimPart = v or "Head"
    end })
    Aim:AddDropdown("AimMode", {
        Text = "Pick",
        Values = { "Crosshair", "Closest" },
        Default = S.AimMode,
        Tooltip = "Crosshair: the mob nearest your aim. Closest: the nearest mob inside the FOV",
        Callback = function(v)
            S.AimMode = v or "Crosshair"
        end,
    })
    Aim:AddSlider("AimFov", { Text = "FOV", Default = S.AimFov, Min = 1, Max = 180, Suffix = "°", Callback = function(v)
        S.AimFov = v
    end })
    Aim:AddSlider("AimRange", { Text = "Range", Default = S.AimRange, Min = 20, Max = 1000, Suffix = " studs", Callback = function(v)
        S.AimRange = v
    end })
    Aim:AddToggle("AimWallCheck", { Text = "Only through clear lines", Default = S.AimWallCheck, Callback = function(v)
        S.AimWallCheck = v
    end })
    Aim:AddToggle("ShowFov", { Text = "Show FOV circle", Default = false, Callback = function(v)
        S.ShowFov = v
    end }):AddColorPicker("FovColor", { Default = S.FovColor, Title = "FOV color", Callback = function(c)
        S.FovColor = c
    end })
    Aim:AddInput("IgnoreTypes", {
        Text = "Never target",
        Default = S.IgnoreTypes,
        Placeholder = "mob types, e.g. Dog",
        Finished = true,
        Callback = function(v)
            S.IgnoreTypes = v or ""
            refreshIgnore()
        end,
    })

    local Aura = Tab:AddRightGroupbox("Auras", "swords")
    Aura:AddToggle("MeleeAura", {
        Text = "Melee aura",
        Default = false,
        Tooltip = "With a melee weapon in hand, swings at mobs in range",
        Callback = function(v)
            S.MeleeAura = v
        end,
    })
    Aura:AddSlider("MeleeRange", { Text = "Melee range", Default = S.MeleeRange, Min = 3, Max = 40, Suffix = " studs", Callback = function(v)
        S.MeleeRange = v
    end })
    Aura:AddSlider("MeleeTargets", { Text = "Mobs per swing", Default = S.MeleeTargets, Min = 1, Max = 4, Callback = function(v)
        S.MeleeTargets = v
    end })
    Aura:AddSlider("MeleeDelay", { Text = "Time between swings", Default = S.MeleeDelay, Min = 150, Max = 2000, Suffix = " ms", Callback = function(v)
        S.MeleeDelay = v
    end })
    Aura:AddDivider()
    Aura:AddToggle("GunAura", {
        Text = "Gun aura",
        Default = false,
        Tooltip = "With a gun in hand, shoots mobs in range on its own",
        Callback = function(v)
            S.GunAura = v
        end,
    })
    Aura:AddSlider("GunRange", { Text = "Gun range", Default = S.GunRange, Min = 20, Max = 600, Suffix = " studs", Callback = function(v)
        S.GunRange = v
    end })
    Aura:AddSlider("GunRate", { Text = "Shots per second", Default = S.GunRate, Min = 1, Max = 15, Callback = function(v)
        S.GunRate = v
    end })
    Aura:AddToggle("AutoReload", { Text = "Reload when empty", Default = S.AutoReload, Callback = function(v)
        S.AutoReload = v
    end })
end

do -- Bus
    local Tab = Window:AddTab("Bus", "bus", "Fuel, driving and the road")
    local Fuel = Tab:AddLeftGroupbox("Fuel", "fuel")
    Fuel:AddToggle("AutoFuel", {
        Text = "Auto fuel",
        Default = false,
        Tooltip = "When the bus runs low, fetches items from the fuel group and burns them in the furnace",
        Callback = function(v)
            S.AutoFuel = v
        end,
    })
    Fuel:AddSlider("FuelBelow", { Text = "Refuel below", Default = S.FuelBelow, Min = 5, Max = 100, Suffix = "%", Callback = function(v)
        S.FuelBelow = v
    end })
    Fuel:AddDropdown("FuelGroup", {
        Text = "Burn items from",
        Values = GROUP_NAMES,
        Default = S.FuelGroup,
        Tooltip = "Edit the group on the Bring tab to leave things out",
        Callback = function(v)
            S.FuelGroup = v or "Fuel"
        end,
    })
    Fuel:AddButton("Refuel now", function()
        runBring(S.FuelGroup, "Furnace (burn)", S.BringMax)
    end)

    local Drive = Tab:AddRightGroupbox("Driving", "steering-wheel")
    Drive:AddToggle("AutoDrive", {
        Text = "Auto drive",
        Default = false,
        Tooltip = "Holds forward for you while you sit in the driver's seat",
        Callback = function(v)
            S.AutoDrive = v
        end,
    })
    Drive:AddButton("Take the wheel", function()
        local bus = busModel()
        local prompt = bus and bus:FindFirstChild("DriveBusPrompt", true)
        if prompt then
            teleport(CFrame.new(pivotPos(prompt.Parent) + Vector3.new(0, 3, 0)))
            task.wait(0.15)
            firePrompt(prompt)
        else
            notify("Bus", "No driver seat found", 3)
        end
    end)
    Drive:AddButton("Teleport to bus", function()
        local pos = pivotPos(busModel())
        if pos then
            teleport(CFrame.new(pos + Vector3.new(0, 6, 0)))
        end
    end)

    local Road = Tab:AddLeftGroupbox("Road", "construction")
    Road:AddToggle("ClearRoad", {
        Text = "Clear the road",
        Default = false,
        Tooltip = "Removes fallen trees, traps and barriers (and barricades) near you through their own prompts",
        Callback = function(v)
            S.ClearRoad = v
        end,
    })
    Road:AddSlider("ClearRange", { Text = "Clear within", Default = S.ClearRange, Min = 10, Max = 150, Suffix = " studs", Callback = function(v)
        S.ClearRange = v
    end })
end

do -- Bring
    local Tab = Window:AddTab("Bring", "magnet", "Fetch items with the game's own grab")
    local What = Tab:AddLeftGroupbox("Bring", "package")
    What:AddDropdown("BringGroup", { Text = "Group", Values = GROUP_NAMES, Default = S.BringGroup, Callback = function(v)
        S.BringGroup = v or "Fuel"
    end })
    What:AddDropdown("BringDest", {
        Text = "To",
        Values = BRING_DESTS,
        Default = S.BringDest,
        Tooltip = "Furnace burns each item as it arrives. Sell conveyor drops them on the nearest one and sells",
        Callback = function(v)
            S.BringDest = v or "Me"
        end,
    })
    UI.SpotLabel = What:AddLabel("Saved spot: none", true)
    What:AddButton("Save this spot", function()
        local hrp = rootPart()
        if hrp then
            S.SavedSpot = hrp.CFrame
            UI.SpotLabel:SetText(string.format("Saved spot: %.0f, %.0f, %.0f", hrp.Position.X, hrp.Position.Y, hrp.Position.Z))
        end
    end)
    What:AddButton({
        Text = "Bring",
        Func = function()
            runBring(S.BringGroup, S.BringDest, S.BringMax)
        end,
    }):AddButton({
        Text = "Stop",
        Func = function()
            Bring.token += 1
            Bring.running = false
            Bring.status = "Stopped"
        end,
    })
    UI.BringStatus = What:AddLabel("Idle", true)
    What:AddToggle("AutoBring", { Text = "Auto bring", Default = false, Callback = function(v)
        S.AutoBring = v
    end })
    What:AddSlider("AutoBringEvery", { Text = "Every", Default = S.AutoBringEvery, Min = 3, Max = 120, Suffix = " s", Callback = function(v)
        S.AutoBringEvery = v
    end })

    local How = Tab:AddRightGroupbox("How", "settings-2")
    How:AddDropdown("BringMethod", {
        Text = "Method",
        Values = { "Auto", "Pull" },
        Default = S.BringMethod,
        Tooltip = "Auto steps up to each item first (the game grabs from about 10 studs). Pull tries to grab from where you stand",
        Callback = function(v)
            S.BringMethod = v or "Auto"
        end,
    })
    How:AddSlider("BringMax", { Text = "Max items", Default = S.BringMax, Min = 1, Max = 200, Callback = function(v)
        S.BringMax = v
    end })
    How:AddSlider("BringRange", { Text = "Search distance", Default = S.BringRange, Min = 20, Max = 3000, Suffix = " studs", Callback = function(v)
        S.BringRange = v
    end })
    How:AddSlider("BringDelay", { Text = "Pause between items", Default = S.BringDelay, Min = 0, Max = 1000, Suffix = " ms", Callback = function(v)
        S.BringDelay = v
    end })
    How:AddSlider("GrabTimeout", { Text = "Wait for a grab", Default = S.GrabTimeout, Min = 150, Max = 2000, Suffix = " ms", Callback = function(v)
        S.GrabTimeout = v
    end })
    How:AddToggle("BringSkipNear", { Text = "Skip items already there", Default = S.BringSkipNear, Callback = function(v)
        S.BringSkipNear = v
    end })

    -- Group editor: pick a group, then tick exactly what belongs in it.
    local Edit = Tab:AddBigGroupbox("Edit groups", "list-checks")
    Edit:AddLabel("Pick a group, then untick anything you don't want in it (or tick extras). Changes are saved and used by Bring, Auto fuel, Auto sell, Auto eat and ESP.", true)
    local editing = "Fuel"
    local members
    local applying = false
    local function showGroup()
        applying = true
        members:SetValues(table.clone(ItemNames))
        members:SetValue(Groups[editing] or {})
        applying = false
    end
    Edit:AddDropdown("EditGroup", { Text = "Group", Values = GROUP_NAMES, Default = "Fuel", Callback = function(v)
        editing = v or "Fuel"
        if members then
            showGroup()
        end
    end })
    members = Edit:AddDropdown("GroupMembers", {
        Text = "Items in this group",
        Values = table.clone(ItemNames),
        Multi = true,
        Searchable = true,
        MaxVisibleDropdownItems = 12,
        Callback = function(v)
            if applying or not v then
                return
            end
            Groups[editing] = table.clone(v)
            Edited[editing] = true
            saveGroups()
        end,
    })
    Library:SetIgnoreIndexes({ "GroupMembers", "EditGroup" })
    Edit:AddButton({
        Text = "Reset this group",
        DoubleClick = true,
        Func = function()
            resetGroup(editing)
            for name in SeenNames do
                if defaultMember(editing, name, nil) then
                    Groups[editing][name] = true
                end
            end
            saveGroups()
            showGroup()
        end,
    }):AddButton({
        Text = "Refresh names",
        Func = function()
            for _, inst in worldItems() do
                noteName(itemName(inst), inst)
            end
            showGroup()
        end,
    })
    task.defer(showGroup)
end

do -- Loot & survival
    local Tab = Window:AddTab("Loot", "package-open", "Chests, selling and eating")
    local Loot = Tab:AddLeftGroupbox("Loot", "package-open")
    Loot:AddToggle("AutoChests", {
        Text = "Auto open chests",
        Default = false,
        Tooltip = "Opens chests within the range below (0 = the chest's own prompt range)",
        Callback = function(v)
            S.AutoChests = v
        end,
    })
    Loot:AddSlider("ChestRange", { Text = "Chest range", Default = S.ChestRange, Min = 0, Max = 200, Suffix = " studs", Callback = function(v)
        S.ChestRange = v
    end })
    Loot:AddDivider()
    Loot:AddToggle("AutoSell", {
        Text = "Auto sell at terminals",
        Default = false,
        Tooltip = "Near a sell conveyor, fetches the sell group onto it and sells",
        Callback = function(v)
            S.AutoSell = v
        end,
    })
    Loot:AddDropdown("SellGroup", { Text = "Sell items from", Values = GROUP_NAMES, Default = S.SellGroup, Callback = function(v)
        S.SellGroup = v or "Valuables"
    end })

    local Live = Tab:AddRightGroupbox("Survival", "heart-pulse")
    Live:AddToggle("AutoEat", { Text = "Auto eat", Default = false, Tooltip = "Eats food from the Food group when you get hungry", Callback = function(v)
        S.AutoEat = v
    end })
    Live:AddSlider("EatBelow", { Text = "Eat below hunger", Default = S.EatBelow, Min = 5, Max = 95, Suffix = "%", Callback = function(v)
        S.EatBelow = v
    end })
    Live:AddSlider("EatRange", { Text = "Look for food within", Default = S.EatRange, Min = 5, Max = 300, Suffix = " studs", Callback = function(v)
        S.EatRange = v
    end })
    Live:AddToggle("AlwaysSprint", { Text = "Sprint even when hungry", Default = false, Callback = function(v)
        S.AlwaysSprint = v
    end })
    Live:AddToggle("InstantPrompts", { Text = "Instant interact (no hold)", Default = false, Callback = function(v)
        S.InstantPrompts = v
        setInstantPrompts(v)
    end })
end

do -- Movement
    local Tab = Window:AddTab("Movement", "footprints", "Speed, fly and teleports")
    local Move = Tab:AddLeftGroupbox("Movement", "move")
    Move:AddToggle("Speed", { Text = "Speed", Default = false, Callback = function(v)
        S.Speed = v
    end })
    Move:AddSlider("SpeedValue", { Text = "Walk speed", Default = S.SpeedValue, Min = 16, Max = 120, Callback = function(v)
        S.SpeedValue = v
    end })
    Move:AddDropdown("SpeedMethod", { Text = "Speed method", Values = { "CFrame", "WalkSpeed" }, Default = S.SpeedMethod, Callback = function(v)
        S.SpeedMethod = v or "CFrame"
    end })
    Move:AddToggle("Fly", {
        Text = "Fly",
        Default = false,
        Tooltip = "Thumbstick or WASD where the camera looks; Space/E up, Ctrl/Q down, or the ▲▼ buttons on mobile",
        Callback = function(v)
            S.Fly = v
            if not v then
                stopFly()
            end
        end,
    }):AddKeyPicker("FlyKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
    Move:AddSlider("FlySpeed", { Text = "Fly speed", Default = S.FlySpeed, Min = 16, Max = 250, Callback = function(v)
        S.FlySpeed = v
    end })
    Move:AddToggle("Noclip", { Text = "Noclip", Default = false, Callback = function(v)
        S.Noclip = v
        if not v then
            restoreNoclip()
        end
    end })
    Move:AddToggle("InfJump", { Text = "Infinite jump", Default = false, Callback = function(v)
        S.InfJump = v
    end })

    local Tp = Tab:AddRightGroupbox("Teleports", "map-pin")
    Tp:AddButton("Bus", function()
        local pos = pivotPos(busModel())
        if pos then
            teleport(CFrame.new(pos + Vector3.new(0, 6, 0)))
        end
    end)
    Tp:AddButton("Nearest sell conveyor", function()
        local prompt = sellZone()
        local pos = prompt and pivotPos(prompt.Parent)
        if pos then
            teleport(CFrame.new(pos + Vector3.new(0, 3, 4)))
        else
            notify("Teleport", "No terminal loaded", 3)
        end
    end)
    Tp:AddButton("Nearest chest", function()
        local best, bestD
        for prompt in Prompts do
            if prompt.Parent and prompt.Name == "OpenChestPrompt" and prompt.Enabled then
                local d = distanceTo(pivotPos(prompt.Parent))
                if not bestD or d < bestD then
                    best, bestD = prompt, d
                end
            end
        end
        if best then
            teleport(CFrame.new(pivotPos(best.Parent) + Vector3.new(0, 3, 0)))
        end
    end)
    Tp:AddButton("Saved spot", function()
        teleport(S.SavedSpot)
    end)
    Tp:AddDropdown("TpPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
    Tp:AddButton("Teleport to player", function()
        local name = Options.TpPlayer and Options.TpPlayer.Value
        local p = name and Players:FindFirstChild(name)
        local hrp = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            teleport(hrp.CFrame * CFrame.new(0, 0, 3))
        end
    end)
end

do -- Visuals
    local Tab = Window:AddTab("Visuals", "eye", "ESP and lighting")
    local EspBox = Tab:AddLeftGroupbox("ESP", "scan-eye")
    EspBox:AddToggle("EspMobs", { Text = "Mobs", Default = false, Callback = function(v)
        S.EspMobs = v
    end })
    EspBox:AddToggle("EspItems", { Text = "Items", Default = false, Callback = function(v)
        S.EspItems = v
    end })
    EspBox:AddDropdown("EspItemGroups", {
        Text = "Item groups",
        Values = GROUP_NAMES,
        Default = { "Fuel", "Valuables", "Chests" },
        Multi = true,
        Callback = function(v)
            S.EspItemGroups = v or {}
        end,
    })
    EspBox:AddToggle("EspPlayers", { Text = "Players", Default = false, Callback = function(v)
        S.EspPlayers = v
    end })
    EspBox:AddToggle("EspHighlight", { Text = "Highlights", Default = true, Callback = function(v)
        S.EspHighlight = v
    end })
    EspBox:AddSlider("EspDistance", { Text = "Max distance", Default = S.EspDistance, Min = 50, Max = 3000, Suffix = " studs", Callback = function(v)
        S.EspDistance = v
    end })
    local World = Tab:AddRightGroupbox("World", "sun")
    World:AddToggle("Fullbright", { Text = "Fullbright", Default = false, Callback = function(v)
        S.Fullbright = v
    end })
    World:AddToggle("NoFog", { Text = "No fog", Default = false, Callback = function(v)
        S.NoFog = v
    end })
end

do -- Staff & lobby
    local Tab = Window:AddTab("Staff", "shield-alert", "Admins and the end of a run")
    local Detect = Tab:AddLeftGroupbox("Staff", "scan-eye")
    Detect:AddToggle("StaffDetect", { Text = "Detect admins", Default = S.StaffDetect, Callback = function(v)
        S.StaffDetect = v
    end })
    Detect:AddSlider("StaffGroupRank", {
        Text = "Game group rank at least",
        Default = S.StaffGroupRank,
        Min = 1,
        Max = 255,
        Tooltip = "Rank 31 in the game's group gets admin tools",
        Callback = function(v)
            S.StaffGroupRank = v
        end,
    })
    Detect:AddDropdown("StaffActions", {
        Text = "When one is here",
        Values = { "Notify", "Pause auto features", "Leave server" },
        Default = { "Notify", "Pause auto features" },
        Multi = true,
        Callback = function(v)
            S.StaffActions = v or {}
        end,
    })
    UI.StaffLabel = Detect:AddLabel("No admins in this server", true)
    local Run = Tab:AddRightGroupbox("Run", "rotate-ccw")
    Run:AddToggle("AutoPlayAgain", { Text = "Auto play again", Default = false, Callback = function(v)
        S.AutoPlayAgain = v
    end })
    Run:AddToggle("AntiAfk", { Text = "Anti AFK", Default = S.AntiAfk, Callback = function(v)
        S.AntiAfk = v
    end })
end

--// Events \\--
do
    local ended = knitRemote("GameService", "RE", "GameEnded")
    if ended then
        bind(ended.OnClientEvent, function()
            if not alive() then
                return
            end
            logLine("Run ended", Library.Scheme.AccentColor)
            if S.AutoPlayAgain then
                task.delay(3, function()
                    local playAgain = knitRemote("GameService", "RF", "PlayAgain")
                    if playAgain then
                        pcall(playAgain.InvokeServer, playAgain)
                    end
                end)
            end
        end)
    end
    local randomEvent = knitRemote("RandomEventService", "RE", "RandomEvent")
    if randomEvent then
        bind(randomEvent.OnClientEvent, function(name)
            if alive() then
                logLine("Event: " .. tostring(name), Color3.fromRGB(255, 200, 120))
            end
        end)
    end
    local down = knitRemote("ReviveService", "RE", "PlayerDown")
    if down then
        bind(down.OnClientEvent, function(who)
            if alive() then
                logLine(tostring(typeof(who) == "Instance" and who.Name or who) .. " is down", Color3.fromRGB(255, 120, 120))
            end
        end)
    end
end

bind(UserInputService.JumpRequest, function()
    if alive() and S.InfJump and not S.Fly then
        local hum = humanoid()
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)
bind(LocalPlayer.Idled, function()
    if alive() and S.AntiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)
bind(RunService.Stepped, function()
    if not alive() or not S.Noclip then
        return
    end
    local c = character()
    if c then
        for _, part in c:GetDescendants() do
            if part:IsA("BasePart") and part.CanCollide then
                NoclipParts[part] = true
                part.CanCollide = false
            end
        end
    end
end)

-- Auto drive: the game drives the bus from your controls' move vector.
pcall(function()
    RunService:BindToRenderStep("LastStopAutoDrive", Enum.RenderPriority.Input.Value + 1, function()
        if not alive() or not S.AutoDrive or paused() or not driving() then
            return
        end
        local active = Controls and Controls.activeController
        if active then
            active.moveVector = Vector3.new(0, 0, -1)
        end
    end)
end)

bind(RunService.Heartbeat, function(dt)
    if not alive() then
        return
    end
    pcall(movementStep, dt)
    if not paused() then
        pcall(auraTick)
    end
end)

bind(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    Camera = Workspace.CurrentCamera
    lightingStep()
    if S.ShowFov then
        local radius = math.tan(math.rad(math.min(S.AimFov, 89))) / math.tan(math.rad(Camera.FieldOfView / 2)) * Camera.ViewportSize.Y / 2
        FovCircle.Size = UDim2.fromOffset(radius * 2, radius * 2)
        FovCircle.Position = UDim2.fromOffset(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
        FovStroke.Color = S.FovColor
        FovCircle.Visible = true
    else
        FovCircle.Visible = false
    end
end)

-- Slower jobs: prompts, eating, fuel, selling, auto bring, staff, ESP.
task.spawn(function()
    local lastAutoBring, lastSell = 0, 0
    while alive() do
        if not paused() then
            pcall(promptTick)
            pcall(eatTick)
            if S.AutoFuel and not Bring.running then
                local fuel, maxFuel = busFuel()
                if fuel and maxFuel and maxFuel > 0 and fuel / maxFuel * 100 < S.FuelBelow then
                    local n = runBring(S.FuelGroup, "Furnace (burn)", 8, function(moved)
                        if moved > 0 then
                            logLine("Burned " .. moved .. " for fuel")
                        end
                    end)
                    if n == 0 then
                        Bring.status = "No fuel in range"
                    end
                end
            end
            if S.AutoSell and not Bring.running and os.clock() - lastSell > 20 then
                local prompt = sellZone()
                if prompt and distanceTo(pivotPos(prompt.Parent)) < 120 then
                    lastSell = os.clock()
                    runBring(S.SellGroup, "Sell conveyor", S.BringMax)
                end
            end
            if S.AutoBring and not Bring.running and os.clock() - lastAutoBring >= S.AutoBringEvery then
                lastAutoBring = os.clock()
                runBring(S.BringGroup, S.BringDest, S.BringMax)
            end
        end
        task.wait(0.4)
    end
end)

task.spawn(function()
    while alive() do
        pcall(updateEsp)
        task.wait(0.3)
    end
end)

local function lookUpRank(p)
    if p == LocalPlayer or Staff.ranks[p.UserId] ~= nil then
        return
    end
    task.spawn(function()
        local ok, rank = pcall(p.GetRankInGroup, p, STAFF_GROUP)
        Staff.ranks[p.UserId] = ok and rank or 0
    end)
end
for _, p in Players:GetPlayers() do
    lookUpRank(p)
end
bind(Players.PlayerAdded, lookUpRank)

task.spawn(function()
    while alive() do
        pcall(function()
            local names = {}
            local was = Staff.present
            for _, p in Players:GetPlayers() do
                local reason = p ~= LocalPlayer and staffReason(p)
                if reason then
                    table.insert(names, p.DisplayName .. " (@" .. p.Name .. ") — " .. reason)
                    if not Staff.list[p.UserId] then
                        Staff.list[p.UserId] = true
                        logLine("Admin: " .. p.Name .. " (" .. reason .. ")", Color3.fromRGB(255, 80, 80))
                        if S.StaffDetect and S.StaffActions.Notify then
                            notify("Admin in server", p.DisplayName .. " — " .. reason, 6)
                        end
                    end
                end
            end
            Staff.present = S.StaffDetect and #names > 0
            UI.StaffLabel:SetText(#names > 0 and table.concat(names, "\n") or "No admins in this server")
            if Staff.present and not was and S.StaffActions["Leave server"] then
                pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
            end
        end)
        task.wait(2)
    end
end)

-- Dashboard.
task.spawn(function()
    local tripStart
    while alive() do
        pcall(function()
            local game_ = classReplica("GameReplica")
            local data = game_ and game_.Data or {}
            UI.TripCards:SetValue("Day", tostring(data.Cycle or "-"))
            UI.TripCards:SetValue("Time", data.IsDay == nil and "-" or (data.IsDay and "Day" or "Night"))
            UI.TripCards:SetValue("Mode", tostring(data.GameMode or "-"))

            local bus = busModel()
            local busPos = pivotPos(bus)
            local endPos = data.EndPosition
            endPos = typeof(endPos) == "CFrame" and endPos.Position or endPos
            local startPos = data.StartPosition
            startPos = typeof(startPos) == "CFrame" and startPos.Position or startPos
            if typeof(endPos) == "Vector3" and busPos then
                local left = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(busPos.X, 0, busPos.Z)).Magnitude
                UI.TripCards:SetValue("To the last stop", string.format("%.0f studs", left))
                if typeof(startPos) == "Vector3" then
                    tripStart = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
                end
                if tripStart and tripStart > 0 then
                    UI.TripBar:SetValue(math.clamp((1 - left / tripStart) * 100, 0, 100))
                end
            end

            local fuel, maxFuel, busData = busFuel()
            UI.BusCards:SetValue("Fuel", fuel and string.format("%.0f / %.0f", fuel, maxFuel or 0) or "-")
            UI.BusCards:SetValue("Speed", busData and busData.Speed and string.format("%.0f", busData.Speed) or "-")
            local wheels = busData and busData.AttachedWheels
            local count = 0
            if type(wheels) == "table" then
                for _ in wheels do
                    count += 1
                end
            end
            UI.BusCards:SetValue("Wheels", busData and tostring(count) or "-")
            UI.BusCards:SetValue("Distance to bus", busPos and string.format("%.0f studs", distanceTo(busPos)) or "-")
            if fuel and maxFuel then
                UI.FuelBar:SetMax(math.max(maxFuel, 1))
                UI.FuelBar:SetValue(fuel)
            end

            local hum = humanoid()
            UI.YouCards:SetValue("Health", hum and string.format("%.0f / %.0f", hum.Health, hum.MaxHealth) or "-")
            local me = playerReplica()
            local myData = me and me.Data
            if myData and myData.Hunger then
                local maxHunger = myData.MaxHunger or 100
                UI.YouCards:SetValue("Hunger", string.format("%.0f / %.0f", myData.Hunger, maxHunger))
                UI.HungerBar:SetValue(myData.Hunger / maxHunger * 100)
            end
            local profile = classReplica("PlayerProfile")
            local wallet = profile and profile.Data and profile.Data.Wallet
            if type(wallet) == "table" then
                local parts = {}
                for currency, amount in wallet do
                    table.insert(parts, tostring(currency) .. " " .. tostring(amount))
                end
                UI.YouCards:SetValue("Wallet", #parts > 0 and table.concat(parts, ", ") or "0")
            end
            local near = 0
            for _, model in mobs() do
                if mobAlive(model) and distanceTo(pivotPos(model)) <= 80 then
                    near += 1
                end
            end
            UI.YouCards:SetValue("Mobs near", tostring(near))
            UI.BringStatus:SetText(Bring.running and string.format("%s (%d / %d)", Bring.status, Bring.done, Bring.total) or Bring.status)
            UI.HookLabel:SetText(string.format("Knit %s · replicas %s · silent aim %s%s",
                G.knit and "found" or "missing", G.replicas and "found" or "missing",
                G.aimOriginal and "hooked" or "unavailable", paused() and " · PAUSED: admin in server" or ""))
        end)
        task.wait(0.3)
    end
end)

logLine(string.format("Loaded · %d item names in %d groups", #ItemNames, #GROUP_NAMES))
if not G.replicas then
    notify("Last Stop", "Couldn't reach the game's replicas: bring, fuel and auras won't work", 8)
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    Bring.token += 1
    for tbl, original in AimPatches do
        tbl.Adjust = original
    end
    pcall(RunService.UnbindFromRenderStep, RunService, "LastStopAutoDrive")
    for _, c in Connections do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(Connections)
    stopFly()
    restoreNoclip()
    if S.InstantPrompts then
        S.InstantPrompts = false
        setInstantPrompts(false)
    end
    S.Fullbright, S.NoFog = false, false
    lightingStep()
    for inst in Esp do
        dropEsp(inst)
    end
    pcall(function()
        VisualGui:Destroy()
    end)
end

Library:OnUnload(cleanup)
Genv.__LastStopUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

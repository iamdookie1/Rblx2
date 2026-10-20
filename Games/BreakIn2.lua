--// Break In 2 (Story) -- the story level (place 13864667823, game 4807308814).
--
-- Built against a script dump of the live game (version 1732). What the
-- game's own client scripts show:
--  * Every request is a RemoteEvent in ReplicatedStorage.Events. There is no
--    anti-cheat on the client: no kicks, no speed or teleport checks, no hook
--    or caller checks. Cutscenes freeze you by resetting WalkSpeed to 0
--    whenever it changes; that's the only thing that fights movement.
--  * The client is the judge of most things:
--      - melee: WeaponsModule picks the targets with a hitbox and sends
--        HitBadguy(enemyModel, damage, weaponLevel) after WeaponCheck(level, 1);
--        a target at 5 health or less gets 996 (the finisher);
--      - your own damage: hail, lightning, lava, bombs and boss hits are all
--        Energy:FireServer(-amount, ...) from the client, and the server asks
--        RemoteFunctions.CheckDamage whether its own attacks were in range;
--      - healing: food sends Energy(amount, itemName); charges on the
--        lollipop, bottle, medkit and chips are counted on the client;
--      - the chasing boss decides on the client that it caught you
--        (LarryBossEvents "CaughtPlayer");
--      - Speed and Strength XP live in the StrengthService module and are
--        reported with LevelToServer(level, "Speed" | "Strength").
--    The server scripts aren't in the dump, so whether the server re-checks
--    any of this is unknown. Everything here sends what the game's own code
--    sends, just more often, from further, or with its own numbers.
--  * Health is "Energy", 0-200, pushed by the server with Energy:FireClient.
--  * Pickups, crates, vending, trash cans and Uncle Pete are ClickDetectors
--    the client makes itself; their click handlers run the game's own code.
--
-- Nothing here touches TooFarAway or TestRespawn, two remotes the client
-- never uses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__BreakIn2Stop) == "function" then pcall(Genv.__BreakIn2Stop) end

local LOBBY_PLACE = 13864661000

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function loop(interval, fn)
    task.spawn(function()
        while not Unloaded do
            pcall(fn)
            task.wait(type(interval) == "function" and interval() or interval)
        end
    end)
end

--// remotes -----------------------------------------------------------------

local Events = ReplicatedStorage:WaitForChild("Events", 30)
local RemoteFunctions = ReplicatedStorage:FindFirstChild("RemoteFunctions")
local Bindables = ReplicatedStorage:FindFirstChild("BindableEvents")

local function remote(name)
    return Events and Events:FindFirstChild(name)
end

local function fire(name, ...)
    local r = remote(name)
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
end

--// settings ----------------------------------------------------------------

local S = {
    -- combat
    KillAura = false,
    AuraRange = 18,
    AuraDamage = 40,
    AuraTargets = 3,
    AuraRate = 0.35,
    OneHit = false,
    AutoSwing = false,
    AutoEquipWeapon = false,
    -- protection
    God = false,
    NoCatch = false,
    NoLobby = false,
    -- healing
    AutoEat = false,
    EatBelow = 100,
    KeepCharges = false,
    -- loot
    AutoLoot = false,
    AutoMoney = false,
    LootTeleport = true,
    -- stats
    TrainSpeed = false,
    TrainStrength = false,
    -- movement
    Speed = false,
    SpeedValue = 24,
    Jump = false,
    JumpValue = 60,
    Noclip = false,
    Fly = false,
    FlySpeed = 50,
    InfJump = false,
    -- story
    AutoPete = false,
    FastGenerator = false,
    AutoHittables = false,
    AutoVote = false,
    VoteFor = "Ending1",
    -- esp
    EspEnemies = false,
    EspBosses = false,
    EspItems = false,
    EspMoney = false,
    EspPlayers = false,
    -- misc
    AntiAfk = true,
}

local Library -- the Ui3 menu, loaded last

--// the game's modules ------------------------------------------------------

local Mods = {}

local function mod(name)
    if Mods[name] then return Mods[name] end
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
    local inst = scripts and scripts:FindFirstChild(name)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    if ok and type(result) == "table" then
        Mods[name] = result
        return result
    end
    return nil
end

--// helpers -----------------------------------------------------------------

local function myChar()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function position(obj)
    if typeof(obj) ~= "Instance" then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("PVInstance") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok then return pivot.Position end
    end
    return nil
end

local function path(root, p)
    local node = root
    for part in p:gmatch("[^/]+") do
        node = node and node:FindFirstChild(part)
    end
    return node
end

local function teleport(pos)
    local _, root = myChar()
    if not root or not pos then return false end
    root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    root.AssemblyLinearVelocity = Vector3.zero
    return true
end

local function distance(pos)
    local _, root = myChar()
    if not root or not pos then return math.huge end
    return (root.Position - pos).Magnitude
end

-- a ClickDetector's own click handlers (most here are made by the game's
-- client scripts, so this runs the game's own code), or a real click
local function click(detector)
    if typeof(detector) ~= "Instance" or not detector:IsA("ClickDetector") then return false end
    if typeof(getconnections) == "function" then
        local ok, list = pcall(getconnections, detector.MouseClick)
        if ok and type(list) == "table" and #list > 0 then
            for _, connection in ipairs(list) do
                local fn = connection.Function
                if type(fn) == "function" then
                    task.spawn(pcall, fn, LocalPlayer)
                else
                    pcall(function() connection:Fire(LocalPlayer) end)
                end
            end
            return true
        end
    end
    if typeof(fireclickdetector) == "function" then
        return (pcall(fireclickdetector, detector))
    end
    return false
end

local function clickIn(obj)
    local detector = obj and (obj:FindFirstChildOfClass("ClickDetector") or obj:FindFirstChildWhichIsA("ClickDetector", true))
    return click(detector)
end

-- clicks something within reach, stepping there first when asked and back
-- afterwards
local function reachAndClick(obj, range, stepThere)
    local pos = position(obj)
    if not pos then return false end
    local _, root = myChar()
    if not root then return false end
    local back
    if stepThere and distance(pos) > (range or 20) then
        back = root.CFrame
        teleport(pos)
        task.wait(0.2)
    end
    local ok = clickIn(obj)
    if back then
        task.wait(0.25)
        local _, r = myChar()
        if r then r.CFrame = back end
    end
    return ok
end

local function touch(part)
    local _, root = myChar()
    if not root or typeof(part) ~= "Instance" or not part:IsA("BasePart") then return false end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, part, 0)
        task.wait()
        pcall(firetouchinterest, root, part, 1)
        return true
    end
    local back = root.CFrame
    root.CFrame = part.CFrame
    task.wait(0.15)
    root.CFrame = back
    return true
end

local function tools()
    local list = {}
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local char = LocalPlayer.Character
    for _, holder in ipairs({ backpack, char }) do
        for _, t in ipairs(holder and holder:GetChildren() or {}) do
            if t:IsA("Tool") then list[#list + 1] = t end
        end
    end
    return list
end

local function findTool(name)
    for _, t in ipairs(tools()) do
        if t.Name == name then return t end
    end
    return nil
end

local function countTool(name)
    local n = 0
    for _, t in ipairs(tools()) do
        if t.Name == name then n += 1 end
    end
    return n
end

-- equips through the game's own backpack request (its hotbar is custom)
local function equip(tool)
    if not tool then return false end
    if tool.Parent == LocalPlayer.Character then return true end
    fire("BackpackEvent", "Equip", tool)
    for _ = 1, 10 do
        if tool.Parent == LocalPlayer.Character then return true end
        task.wait(0.05)
    end
    local _, _, hum = myChar()
    if hum and tool.Parent == LocalPlayer:FindFirstChildOfClass("Backpack") then pcall(hum.EquipTool, hum, tool) end
    return tool.Parent == LocalPlayer.Character
end

local function notify(text, seconds)
    if Library then pcall(function() Library:Notify(text, seconds or 4) end) end
end

--// energy (health) ---------------------------------------------------------

local Energy = 200
if remote("Energy") then
    track(remote("Energy").OnClientEvent:Connect(function(value)
        if type(value) == "number" then Energy = value end
    end))
end

--// protection --------------------------------------------------------------
-- God mode drops the game's own reports of damage to you (Energy with a
-- negative amount), and answers the server's range check with "not in range".
-- No catch drops the chasing boss's "caught you". No lobby keeps the death
-- screen's countdown from sending you to the lobby.

local HookInstalled = false

local function installHook()
    if HookInstalled then return true end
    if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then return false end
    local wrap = typeof(newcclosure) == "function" and newcclosure or function(f) return f end
    local isOurs = typeof(checkcaller) == "function" and checkcaller or function() return false end
    local energyRemote = remote("Energy")
    local catchRemote = remote("LarryBossEvents")
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if not Unloaded and not isOurs() then
            local method = getnamecallmethod()
            if method == "FireServer" then
                if S.God and self == energyRemote then
                    local amount = ...
                    if type(amount) == "number" and amount < 0 then return nil end
                elseif S.NoCatch and self == catchRemote then
                    local what = ...
                    if what == "CaughtPlayer" then return nil end
                end
            elseif S.NoLobby and self == TeleportService and (method == "Teleport" or method == "TeleportAsync") then
                local place = ...
                if place == LOBBY_PLACE then return nil end
            end
        end
        return old(self, ...)
    end))
    HookInstalled = true
    return true
end

-- the game's own range check, kept to put back
local function gameCheckDamage(pos)
    local _, root = myChar()
    if not root or typeof(pos) ~= "Vector3" then return false end
    return (pos - root.Position).Magnitude < 15
end

local function setCheckDamage()
    local check = RemoteFunctions and RemoteFunctions:FindFirstChild("CheckDamage")
    if not check then return end
    pcall(function()
        check.OnClientInvoke = S.God and function() return false end or gameCheckDamage
    end)
end

--// enemies -----------------------------------------------------------------

local ENEMY_NAMES = { BadGuy = true, BadGuySmall = true, BadGuyPizza = true, BadGuyBrute = true }
local ENEMY_FOLDERS = { "BadGuys", "BadGuysFront", "BadGuysBoss", "FinalBadGuys" }

-- the same test the game's hit code makes
local function isEnemy(model)
    if typeof(model) ~= "Instance" or not model:IsA("Model") then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if ENEMY_NAMES[model.Name] then
        return not (model.Name == "BadGuyBrute" and model:FindFirstChild("forcefield"))
    end
    return model.Name == " " and not model:FindFirstChild("SuperHeroMask1") and Players:GetPlayerFromCharacter(model) == nil
end

local function enemies()
    local list, seen = {}, {}
    local function add(model)
        if not seen[model] and isEnemy(model) then
            seen[model] = true
            list[#list + 1] = model
        end
    end
    for _, name in ipairs(ENEMY_FOLDERS) do
        local folder = Workspace:FindFirstChild(name)
        for _, child in ipairs(folder and folder:GetChildren() or {}) do add(child) end
    end
    for _, child in ipairs(Workspace:GetChildren()) do
        add(child)
        if child:IsA("Model") and (child.Name == "PizzaBossAlec" or child.Name == "BadGuyBruteLOADPLEASE") then
            for _, sub in ipairs(child:GetChildren()) do add(sub) end
        end
    end
    return list
end

local function weapon()
    for _, t in ipairs(tools()) do
        if t:FindFirstChild("WeaponLevel") then return t end
    end
    return nil
end

local function strengthLevel()
    local ss = mod("StrengthService")
    return ss and tonumber(ss.level2) or 1
end

-- kill aura: the game's hit request, for every enemy in range
loop(function() return S.AuraRate end, function()
    if not S.KillAura then return end
    local _, root = myChar()
    if not root then return end
    local wep = weapon()
    if S.AutoEquipWeapon and wep and wep.Parent ~= LocalPlayer.Character then equip(wep) end
    local targets = {}
    for _, enemy in ipairs(enemies()) do
        local pos = position(enemy.PrimaryPart or enemy:FindFirstChild("HumanoidRootPart") or enemy)
        if pos and (pos - root.Position).Magnitude <= S.AuraRange then
            targets[#targets + 1] = { Model = enemy, Dist = (pos - root.Position).Magnitude }
        end
    end
    if #targets == 0 then return end
    table.sort(targets, function(a, b) return a.Dist < b.Dist end)
    local level = strengthLevel()
    local weaponLevel = wep and wep:FindFirstChild("WeaponLevel") and wep.WeaponLevel.Value or 4
    fire("WeaponCheck", level, 1)
    for i = 1, math.min(#targets, S.AuraTargets) do
        local enemy = targets[i].Model
        local hum = enemy:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            if S.OneHit or hum.Health <= 5 then
                fire("HitBadguy", enemy, 996)
            else
                fire("HitBadguy", enemy, S.AuraDamage, weaponLevel)
            end
        end
    end
end)

-- auto swing: the game's own swing (its mobile hit button), when an enemy is
-- close, facing it
loop(0.2, function()
    if not S.AutoSwing then return end
    local _, root = myChar()
    if not root then return end
    local wep = weapon()
    if not wep then return end
    if wep.Parent ~= LocalPlayer.Character then
        if not S.AutoEquipWeapon then return end
        equip(wep)
    end
    local best, bestDist = nil, 11
    for _, enemy in ipairs(enemies()) do
        local pos = position(enemy.PrimaryPart or enemy:FindFirstChild("HumanoidRootPart") or enemy)
        local d = pos and (pos - root.Position).Magnitude
        if d and d < bestDist then best, bestDist = pos, d end
    end
    if not best then return end
    root.CFrame = CFrame.lookAt(root.Position, Vector3.new(best.X, root.Position.Y, best.Z))
    local hit = Bindables and Bindables:FindFirstChild("MobileHit")
    if hit then pcall(hit.Fire, hit) end
end)

--// healing -----------------------------------------------------------------
-- What each food does when eaten, exactly as the game's HoldingService sends it.

local FOODS = {
    { Name = "GoldPizza", Use = function() fire("CurePlayer", LocalPlayer, LocalPlayer) end },
    { Name = "RainbowPizza", Use = function() fire("RainbowPizza", LocalPlayer) end },
    { Name = "Pizza", Use = function() fire("Energy", 25, "Pizza") end },
    { Name = "GoldenApple", Use = function() fire("HealTheNoobs") end },
    { Name = "BloxyCola", Use = function() fire("Energy", 15, "BloxyCola") end },
    { Name = "Apple", Use = function() fire("Energy", 15, "Apple") end },
    { Name = "Cookie", Use = function() fire("Energy", 15, "Cookie") end },
    { Name = "ExpiredBloxyCola", Use = function() fire("Energy", 15, "ExpiredBloxyCola") end },
    { Name = "Chips", Use = function(tool) fire("Energy", "Chips", nil, tool) end },
    { Name = "Lollipop", Use = function(tool) fire("Energy", "Lollipop", nil, tool) end },
}

local function eatOnce()
    for _, food in ipairs(FOODS) do
        local tool = findTool(food.Name)
        if tool then
            local charges = tool:FindFirstChild("Charges")
            if not charges or charges.Value > 0 then
                equip(tool)
                task.wait(0.15)
                food.Use(tool)
                return food.Name
            end
        end
    end
    return nil
end

loop(1.5, function()
    if not S.AutoEat or Energy >= S.EatBelow then return end
    if not myChar() then return end
    eatOnce()
end)

-- charges are counted on the client; this puts them back where they started
local ChargeMax = setmetatable({}, { __mode = "k" })
loop(0.2, function()
    if not S.KeepCharges then return end
    for _, tool in ipairs(tools()) do
        local charges = tool:FindFirstChild("Charges")
        if charges and charges:IsA("IntValue") then
            ChargeMax[charges] = math.max(ChargeMax[charges] or 0, charges.Value)
            if charges.Value < ChargeMax[charges] then charges.Value = ChargeMax[charges] end
        end
    end
end)

local function healEveryone()
    local kit = findTool("MedKit")
    if kit then equip(kit) end
    for _, player in ipairs(Players:GetPlayers()) do
        fire("HealPlayer", player)
        task.wait(0.1)
    end
end

--// loot --------------------------------------------------------------------

local function lootAll()
    local found = 0
    local hidden = Workspace:FindFirstChild("Hidden")
    for _, item in ipairs(hidden and hidden:GetChildren() or {}) do
        if Unloaded then break end
        local detector = item:FindFirstChildOfClass("ClickDetector")
        local isNote = item.Name:sub(1, 4) == "Note"
        if detector and (not isNote or detector.MaxActivationDistance > 0) then
            if reachAndClick(item, 20, S.LootTeleport) then found += 1 end
            task.wait(0.25)
        end
    end
    local table_ = Workspace:FindFirstChild("TableSetMONEY")
    for _, pile in ipairs(table_ and table_:GetChildren() or {}) do
        if pile.Name:match("^MoneyPile") and pile:FindFirstChildWhichIsA("ClickDetector", true) then
            if reachAndClick(pile, 20, S.LootTeleport) then found += 1 end
            task.wait(0.25)
        end
    end
    local boxes = Workspace:FindFirstChild("Boxes")
    for _, box in ipairs(boxes and boxes:GetChildren() or {}) do
        if box:FindFirstChildOfClass("ClickDetector") then
            if reachAndClick(box, 20, S.LootTeleport) then found += 1 end
            task.wait(0.25)
        end
    end
    for _, name in ipairs({ "RainbowPizzaBox", "GoldenApple" }) do
        local obj = Workspace:FindFirstChild(name)
        if obj and obj:FindFirstChildWhichIsA("ClickDetector", true) then
            if reachAndClick(obj, 10, S.LootTeleport) then found += 1 end
            task.wait(0.25)
        end
    end
    return found
end

local function grabCrowbar()
    local rack = path(Workspace, "TheHouse/Rack")
    if rack then
        if not reachAndClick(rack, 14, true) then fire("GiveCrowbar", rack) end
        return true
    end
    return false
end

-- money dropped by bad guys: the server marks it with BadGuyMoney, and the
-- game's own pickup sends FoundMoney with the part
local PendingMoney = {}
if remote("BadGuyMoney") then
    track(remote("BadGuyMoney").OnClientEvent:Connect(function(live, part)
        if live and typeof(part) == "Instance" then PendingMoney[part] = true end
    end))
end

loop(0.5, function()
    if not S.AutoMoney then return end
    for part in pairs(PendingMoney) do
        PendingMoney[part] = nil
        if part.Parent then
            if S.LootTeleport and distance(part.Position) > 25 then
                local _, root = myChar()
                local back = root and root.CFrame
                teleport(part.Position)
                task.wait(0.15)
                fire("FoundMoney", part)
                task.wait(0.15)
                local _, r = myChar()
                if r and back then r.CFrame = back end
            else
                fire("FoundMoney", part)
            end
        end
    end
    -- loose money lying about
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == "Money3" and child:FindFirstChildWhichIsA("ClickDetector", true) then
            reachAndClick(child, 20, S.LootTeleport)
        end
    end
end)

loop(4, function()
    if S.AutoLoot then lootAll() end
end)

--// item spawner ------------------------------------------------------------
-- Every way the game's own client asks the server for an item, tried with
-- any item name. Which ones the server honours is only known by trying; the
-- result says which way worked.

local ITEMS = {
    "Apple", "Cookie", "Pizza", "GoldPizza", "RainbowPizza", "GoldenApple", "BloxyCola", "ExpiredBloxyCola",
    "Chips", "Lollipop", "Bottle", "MedKit", "Book", "Phone", "Key", "GoldKey", "Battery", "Ladder", "Louise",
    "Bat", "Broom", "Pitchfork", "Hammer", "Wrench", "LinkedSword", "Crowbar1", "Crowbar2", "Crowbar3",
}

local MACHINE_FOR = {
    Apple = "Food", Cookie = "Food", Pizza = "Food", Chips = "Food",
    BloxyCola = "Drinks", ExpiredBloxyCola = "Drinks", Key = "Drinks",
    Crowbar1 = "Weapons", Crowbar2 = "Weapons", Crowbar3 = "Weapons", Bat = "Weapons", Broom = "Weapons",
    Pitchfork = "Weapons", Hammer = "Weapons", Wrench = "Weapons", LinkedSword = "Weapons",
}

local VendingId = 1000

local SPAWN_WAYS = {
    { Name = "GiveTool", Try = function(item) fire("GiveTool", item); fire("GiveTool", item, true) end },
    { Name = "Crate", Try = function(item)
        local hidden = Workspace:FindFirstChild("Hidden")
        local spot = hidden and (hidden:FindFirstChild(item) or hidden:FindFirstChild("RainbowPizza") or hidden:FindFirstChild("Bottle"))
        local boxes = Workspace:FindFirstChild("Boxes")
        spot = spot or (boxes and boxes:GetChildren()[1])
        if spot then fire("BoxEvent", 2, spot, item) end
    end },
    { Name = "Vending", Try = function(item)
        VendingId += 1
        fire("Vending", 3, item, MACHINE_FOR[item] or "Food", LocalPlayer.Name, nil, VendingId)
    end },
    { Name = "Stack", Try = function(item)
        if item == "Pizza" or item == "BloxyCola" then fire("StackItem", item) end
    end },
    { Name = "Special", Try = function(item)
        if item == "MedKit" then fire("AtticMedKit") end
        if item:match("^Crowbar") then grabCrowbar(); fire("FloorCrowbar", 1); fire("FloorCrowbar", 2) end
        if item == "Bottle" then fire("TakingBottle") end
        if item == "Louise" then fire("LouiseGive", 1) end
    end },
}

local function spawnItem(item, way)
    local before = countTool(item)
    for _, w in ipairs(SPAWN_WAYS) do
        if way == "Auto" or way == w.Name then
            pcall(w.Try, item)
            for _ = 1, 15 do
                task.wait(0.1)
                if countTool(item) > before then return true, w.Name end
            end
        end
    end
    return false, nil
end

--// vending -----------------------------------------------------------------

local MACHINES = { "Food", "Drinks", "Weapons", "Armor" }

-- the machine's own buy click (it checks money and stock itself), from anywhere
local function buyFrom(machine)
    local m = path(Workspace, "VendingMachines/" .. machine)
    local price = m and m:FindFirstChild("PricePart")
    if not price then return false end
    return clickIn(price)
end

--// stats -------------------------------------------------------------------

local SPEED_WALK = { 16, 16.5, 17, 18, 20 }

-- the same reports the game makes on each level up, one level at a time
local function maxStat(stat)
    local ss = mod("StrengthService")
    if not ss then return false end
    local bars = mod("LevelBarService")
    local field = stat == "Speed" and "level" or "level2"
    local xpField = stat == "Speed" and "xp" or "xp2"
    local current = tonumber(ss[field]) or 1
    for level = current + 1, 5 do
        ss[field] = level
        ss[xpField] = level >= 5 and 1 or 0
        fire("LevelToServer", level, stat)
        fire("PlayerGainedXp", level, stat, ss[xpField])
        if stat == "Speed" then
            fire("Walkspeeder2", SPEED_WALK[level])
            if level == 3 then
                pcall(function()
                    local env = getfenv(ss.tickXP)
                    if type(env.doLadder) == "function" then env.doLadder() end
                end)
            end
        end
        if bars and type(bars.lvlUp) == "function" then pcall(bars.lvlUp, stat, level) end
        task.wait(0.35)
    end
    return true
end

-- the game's own XP tick, as the gym gives it (its cooldown still applies)
loop(0.4, function()
    local ss = mod("StrengthService")
    if not ss then return end
    if S.TrainSpeed and (ss.level or 1) < 5 and type(ss.tickXP) == "function" then pcall(ss.tickXP, true, true) end
    if S.TrainStrength and (ss.level2 or 1) < 5 and type(ss.tickXP2) == "function" then pcall(ss.tickXP2, 7) end
end)

--// movement ----------------------------------------------------------------

-- cutscene locks reset WalkSpeed to 0 the moment it changes; while speed is
-- on those listeners are switched off, and back on after
local SpeedLocks = {}

local function setSpeedLocks(off)
    local _, _, hum = myChar()
    if off and hum and typeof(getconnections) == "function" then
        for _, signal in ipairs({ hum:GetPropertyChangedSignal("WalkSpeed"), hum:GetPropertyChangedSignal("JumpPower") }) do
            local ok, list = pcall(getconnections, signal)
            for _, connection in ipairs(ok and list or {}) do
                if pcall(function() connection:Disable() end) then SpeedLocks[#SpeedLocks + 1] = connection end
            end
        end
    elseif not off then
        for _, connection in ipairs(SpeedLocks) do pcall(function() connection:Enable() end) end
        table.clear(SpeedLocks)
    end
end

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    pcall(function()
        local _, _, hum = myChar()
        if not hum then return end
        if S.Speed and hum.WalkSpeed ~= S.SpeedValue then hum.WalkSpeed = S.SpeedValue end
        if S.Jump then
            hum.UseJumpPower = true
            if hum.JumpPower ~= S.JumpValue then hum.JumpPower = S.JumpValue end
        end
    end)
end))

track(RunService.Stepped:Connect(function()
    if Unloaded or not S.Noclip then return end
    pcall(function()
        local char = LocalPlayer.Character
        for _, part in ipairs(char and char:GetDescendants() or {}) do
            if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
        end
    end)
end))

track(RunService.RenderStepped:Connect(function(dt)
    if Unloaded or not S.Fly then return end
    pcall(function()
        local _, root, hum = myChar()
        if not root then return end
        local look = Camera.CFrame
        local move = hum.MoveDirection
        local dir = Vector3.zero
        if move.Magnitude > 0 then
            local flatLook = Vector3.new(look.LookVector.X, 0, look.LookVector.Z)
            local forward = flatLook.Magnitude > 0 and flatLook.Unit or Vector3.new(0, 0, -1)
            local along = move:Dot(forward)
            dir = move + Vector3.new(0, look.LookVector.Y * along, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0, 1, 0) end
        root.AssemblyLinearVelocity = Vector3.zero
        if dir.Magnitude > 0 then
            root.CFrame = root.CFrame + dir.Unit * S.FlySpeed * dt
        end
    end)
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloaded or not S.InfJump then return end
    local _, _, hum = myChar()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

--// story -------------------------------------------------------------------

-- Uncle Pete: once his alert shows, his reward click (the game's own)
loop(1, function()
    if not S.AutoPete then return end
    local pete = Workspace:FindFirstChild("UnclePete")
    local alert = pete and path(pete, "Head/Alertbbg/Alert")
    if alert and alert.Visible then
        reachAndClick(pete, 20, true)
        task.wait(2)
    end
end)

-- generator bike: the power tick the game sends while you pedal, faster
loop(0.12, function()
    if not S.FastGenerator then return end
    local generator = Workspace:FindFirstChild("Generator")
    for _, bike in ipairs(generator and generator:GetChildren() or {}) do
        local owner = bike:FindFirstChild("Owner")
        if owner and owner.Value == LocalPlayer.Name then fire("BikeEvent", 3, bike.Name) end
    end
end)

-- doors, the tree, the punchable character and the rest: the game's own
-- "hit" for anything marked hittable within its reach
local Hittables, HittablesAt = {}, -math.huge
loop(0.6, function()
    if not S.AutoHittables then return end
    local hs = mod("HittableService")
    if not hs or type(hs.onHit) ~= "function" then return end
    if os.clock() - HittablesAt > 6 then
        table.clear(Hittables)
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d.Name == "hittable" and d.Parent and d.Parent:IsA("Model") then Hittables[#Hittables + 1] = d.Parent end
        end
        HittablesAt = os.clock()
    end
    for _, model in ipairs(Hittables) do
        if model.Parent and model.PrimaryPart and distance(model.PrimaryPart.Position) < 18 then
            pcall(hs.onHit, model)
        end
    end
end)

-- ending vote: the game's vote request, for the chosen ending, when a vote opens
if remote("ChooseEnding") then
    track(remote("ChooseEnding").OnClientEvent:Connect(function(what)
        if what ~= "StartVote" or not S.AutoVote then return end
        task.delay(1, function() fire("ChooseEnding", S.VoteFor) end)
    end))
end

local function unlockCamera()
    pcall(function()
        Camera.CameraType = Enum.CameraType.Custom
        local _, _, hum = myChar()
        if hum then Camera.CameraSubject = hum end
    end)
    local skip = path(LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer, "Assets/SkipButton")
    if skip and typeof(getconnections) == "function" then
        for _, signal in ipairs({ skip.MouseButton1Down, skip.Activated }) do
            local ok, list = pcall(getconnections, signal)
            for _, connection in ipairs(ok and list or {}) do
                if type(connection.Function) == "function" then task.spawn(pcall, connection.Function) end
            end
        end
    end
end

-- the Scary Larry ending's three items, the way the game collects each
local function larryMask()
    local mask = path(Workspace, "MaskOutside/Part")
    if mask then touch(mask) end
    fire("LarryEndingEvent", "MaskCollected")
end

local function larryTree()
    if strengthLevel() < 3 then maxStat("Strength") end
    fire("LarryEndingEvent", "TreeFelled")
end

local function larryCrowbar()
    local crowbar = Workspace:FindFirstChild("GoldCrowbarClickable")
    if crowbar then
        local part = crowbar:FindFirstChild("Part") or crowbar.PrimaryPart
        if part then touch(part) end
        clickIn(crowbar)
    end
    fire("LarryEndingEvent", "CrowbarCollected")
end

local function larryHat()
    fire("PunchableQuest", "Quest", "Pizza")
    task.wait(0.5)
    fire("PunchableQuest", "Quest", "GoldPizza")
    task.wait(0.5)
    local pickup = Workspace:FindFirstChild("LarryHatPickup")
    if pickup then
        touch(pickup)
        clickIn(pickup)
    end
    fire("LarryEndingEvent", "HatCollected", true)
end

-- the power objective: search the trash cans, pick the batteries up, place them
local function searchTrash()
    local cans = Workspace:FindFirstChild("TrashCans")
    for _, can in ipairs(cans and cans:GetChildren() or {}) do
        local detector = can:FindFirstChild("Model") and can.Model:FindFirstChild("ClickDetector")
        if detector then
            click(detector)
            task.wait(0.6)
        end
    end
end

local function grabBatteries()
    local cans = Workspace:FindFirstChild("TrashCans")
    local got = 0
    for _, can in ipairs(cans and cans:GetChildren() or {}) do
        local battery = can:FindFirstChild("Battery2")
        if battery and clickIn(battery) then got += 1 end
    end
    return got
end

local function placeBatteries()
    for slot = 1, 2 do
        local battery = findTool("Battery")
        if not battery then break end
        equip(battery)
        task.wait(0.2)
        local slotModel = Workspace:FindFirstChild("BatterySlot" .. slot)
        if slotModel then
            local _, root = myChar()
            local back = root and root.CFrame
            teleport(position(slotModel))
            task.wait(0.2)
            fire("BatteryEvent", "UsedBattery", slot)
            task.wait(0.3)
            local _, r = myChar()
            if r and back then r.CFrame = back end
        end
    end
end

--// esp ---------------------------------------------------------------------

local Esp = {} -- target -> { Highlight, Billboard, Label }
local EspFolder = Instance.new("Folder")
EspFolder.Name = "BI2_ESP"
pcall(function() EspFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not EspFolder.Parent then EspFolder.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BOSS_NAMES = { PizzaBossAlec = "Pizza Boss", BadGuyBrute = "Brute", AgentBeans = "Bradley Beans", Villainess = "Scary Mary", ["Scary Larry"] = "Scary Larry", BigBoss = "Big Boss", AgentBoss = "Agent Boss" }

local function bossLives()
    local area = mod("BossAreaServiceClient")
    local final = mod("BossFinalClient")
    return {
        Arena1 = area and area.bossHealth,
        Arena2 = area and area.bossHealth2,
        Arena3 = area and area.bossHealth3,
        Mary = final and final.MaryHealth,
        Bradley = final and final.AgentHealth,
    }
end

local function espFor(target, color, text)
    local entry = Esp[target]
    if not entry then
        local highlight = Instance.new("Highlight")
        highlight.FillTransparency = 0.7
        highlight.OutlineTransparency = 0
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Adornee = target
        highlight.Parent = EspFolder
        local billboard = Instance.new("BillboardGui")
        billboard.Size = UDim2.fromOffset(160, 36)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.AlwaysOnTop = true
        billboard.Adornee = target:IsA("Model") and (target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")) or target
        billboard.Parent = EspFolder
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.TextStrokeTransparency = 0.4
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.Parent = billboard
        entry = { Highlight = highlight, Billboard = billboard, Label = label }
        Esp[target] = entry
    end
    entry.Highlight.FillColor, entry.Highlight.OutlineColor = color, color
    entry.Label.TextColor3 = color
    entry.Label.Text = text
    entry.Seen = true
end

loop(0.4, function()
    for _, entry in pairs(Esp) do entry.Seen = false end
    local _, root = myChar()
    local function dist(obj)
        local pos = position(obj)
        return (pos and root) and ("  %dm"):format(math.floor((pos - root.Position).Magnitude)) or ""
    end
    if S.EspEnemies then
        for _, enemy in ipairs(enemies()) do
            local hum = enemy:FindFirstChildOfClass("Humanoid")
            espFor(enemy, Color3.fromRGB(255, 70, 70), ("%s  %d hp%s"):format(enemy.Name == " " and "Bad Guy" or enemy.Name, hum and math.floor(hum.Health) or 0, dist(enemy)))
        end
    end
    if S.EspBosses then
        local lives = bossLives()
        for name, label in pairs(BOSS_NAMES) do
            local boss = Workspace:FindFirstChild(name)
            if boss and boss:IsA("Model") then
                local extra = (name == "Villainess" and lives.Mary) or (name == "AgentBeans" and lives.Bradley) or nil
                espFor(boss, Color3.fromRGB(190, 90, 255), label .. (extra and ("  " .. tostring(extra) .. " lives") or "") .. dist(boss))
            end
        end
    end
    if S.EspItems then
        local hidden = Workspace:FindFirstChild("Hidden")
        for _, item in ipairs(hidden and hidden:GetChildren() or {}) do
            if item.Name ~= "Money" and (item:IsA("BasePart") or item:IsA("Model")) then
                espFor(item, Color3.fromRGB(90, 230, 120), item.Name .. dist(item))
            end
        end
        for _, name in ipairs({ "RainbowPizzaBox", "GoldenApple", "MaskOutside", "GoldCrowbarClickable", "Punchable Character", "ChopTree" }) do
            local obj = Workspace:FindFirstChild(name)
            if obj then espFor(obj, Color3.fromRGB(90, 230, 120), name .. dist(obj)) end
        end
        local boxes = Workspace:FindFirstChild("Boxes")
        for _, box in ipairs(boxes and boxes:GetChildren() or {}) do
            if box:FindFirstChildOfClass("ClickDetector") then espFor(box, Color3.fromRGB(90, 230, 120), "Crate" .. dist(box)) end
        end
        local cans = Workspace:FindFirstChild("TrashCans")
        for _, can in ipairs(cans and cans:GetChildren() or {}) do
            local battery = can:FindFirstChild("Battery2")
            if battery then espFor(battery, Color3.fromRGB(90, 230, 120), "Battery" .. dist(battery)) end
        end
    end
    if S.EspMoney then
        local hidden = Workspace:FindFirstChild("Hidden")
        for _, item in ipairs(hidden and hidden:GetChildren() or {}) do
            if item.Name == "Money" then espFor(item, Color3.fromRGB(255, 215, 60), "Money" .. dist(item)) end
        end
        for part in pairs(PendingMoney) do
            if part.Parent then espFor(part, Color3.fromRGB(255, 215, 60), "Money" .. dist(part)) end
        end
        for _, child in ipairs(Workspace:GetChildren()) do
            if child.Name == "Money3" then espFor(child, Color3.fromRGB(255, 215, 60), "Money" .. dist(child)) end
        end
        local table_ = Workspace:FindFirstChild("TableSetMONEY")
        for _, pile in ipairs(table_ and table_:GetChildren() or {}) do
            if pile.Name:match("^MoneyPile") then espFor(pile, Color3.fromRGB(255, 215, 60), "Money" .. dist(pile)) end
        end
    end
    if S.EspPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                espFor(player.Character, Color3.fromRGB(80, 170, 255), player.DisplayName .. dist(player.Character))
            end
        end
    end
    for target, entry in pairs(Esp) do
        if not entry.Seen or not target.Parent then
            pcall(function() entry.Highlight:Destroy() end)
            pcall(function() entry.Billboard:Destroy() end)
            Esp[target] = nil
        end
    end
end)

--// teleports ---------------------------------------------------------------

local SPOTS = {
    { "Main room", function() return position(path(Workspace, "Spawns/Main")) end, Vector3.new(-272, 34, -790.8) },
    { "Lab", function() return position(path(Workspace, "Spawns/Lab")) end },
    { "Uncle Pete", function() return position(Workspace:FindFirstChild("UnclePete")) end },
    { "Vending machines", function() return position(Workspace:FindFirstChild("VendingMachines")) end },
    { "Crowbar rack", function() return position(path(Workspace, "TheHouse/Rack")) end },
    { "Gym (treadmills)", function() return position(Workspace:FindFirstChild("Tredmills")) end },
    { "Gym (bench presses)", function() return position(Workspace:FindFirstChild("BenchPresses")) end },
    { "Trash cans", function() return position(Workspace:FindFirstChild("TrashCans")) end },
    { "Battery slot 1", function() return position(Workspace:FindFirstChild("BatterySlot1")) end },
    { "Battery slot 2", function() return position(Workspace:FindFirstChild("BatterySlot2")) end },
    { "Generator", function() return position(Workspace:FindFirstChild("Generator") or Workspace:FindFirstChild("TempGenerator")) end },
    { "Golden apple", function() return position(Workspace:FindFirstChild("GoldenApple")) end, Vector3.new(93.2, 48.3, -789.2) },
    { "Rainbow pizza box", function() return position(Workspace:FindFirstChild("RainbowPizzaBox")) end },
    { "Pizza boss", function() return position(Workspace:FindFirstChild("PizzaBossAlec")) end },
    { "Break room door", nil, Vector3.new(-233.6, 78.9, -715.2) },
    { "Bog", function() return position(Workspace:FindFirstChild("BogArea")) end, Vector3.new(-83, 27, -918) },
    { "Larry mask", function() return position(path(Workspace, "MaskOutside/Part")) end },
    { "Chop tree", function() return position(Workspace:FindFirstChild("ChopTree")) end, Vector3.new(-148.7, 26.3, -937) },
    { "Punchable character", function() return position(Workspace:FindFirstChild("Punchable Character")) end },
    { "Bridge", function() return position(Workspace:FindFirstChild("BridgeRespawn")) end },
    { "Vault", function() return position(Workspace:FindFirstChild("VaultRespawn")) end },
    { "Boss fight", function() return position(Workspace:FindFirstChild("BossFightRespawn")) end, Vector3.new(-1500.4, -321.9, -1060.2) },
    { "Final boss area", nil, Vector3.new(-1597, -372, -1058) },
    { "School", function() return position(Workspace:FindFirstChild("SpawnsSchool")) end, Vector3.new(-603, 240, 881) },
    { "Obby", function() return position(Workspace:FindFirstChild("SpawnsObby")) end },
    { "Spawn", function() return position(Workspace:FindFirstChild("SpawnLocation")) end },
}

local function spotPosition(name)
    for _, spot in ipairs(SPOTS) do
        if spot[1] == name then
            local pos = spot[2] and spot[2]()
            return pos or spot[3]
        end
    end
    return nil
end

--// anti-AFK ----------------------------------------------------------------

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    for _, connection in ipairs(list) do
        pcall(function()
            if on then
                connection:Disable()
                IdleOff[#IdleOff + 1] = connection
            end
        end)
    end
    if not on then
        for _, connection in ipairs(IdleOff) do pcall(function() connection:Enable() end) end
        table.clear(IdleOff)
    end
    return true
end
task.delay(3, function() if S.AntiAfk and not Unloaded then setAntiAfk(true) end end)

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    for key, value in pairs(S) do
        if value == true then S[key] = false end
    end
    pcall(setCheckDamage)
    pcall(setSpeedLocks, false)
    pcall(setAntiAfk, false)
    Unloaded = true
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    pcall(function() EspFolder:Destroy() end)
    pcall(function()
        local _, _, hum = myChar()
        if hum then hum.WalkSpeed = 16 end
    end)
end

Genv.__BreakIn2Stop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

local okLib, lib = pcall(function()
    return loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()
end)
if not okLib or type(lib) ~= "table" then return end
Library = lib

local Window = Library:CreateWindow({
    Title = 'Break In 2',
    Footer = 'story',
    Icon = 'swords',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'BreakIn2',
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

local function toggle(box, id, text, key, tooltip, onChange)
    return box:AddToggle(id, {
        Text = text,
        Tooltip = tooltip,
        Default = S[key],
        Callback = function(v)
            S[key] = v
            if onChange then onChange(v) end
        end,
    })
end

local function needHook(v)
    if v and not installHook() then notify("Your executor has no hookmetamethod, so this can't block anything.", 5) end
end

do
    local Tab = Window:AddTab('Combat', 'swords', 'Fights')

    local aura = Tab:AddLeftGroupbox('Kill aura', 'crosshair')
    toggle(aura, 'bi_aura', 'Kill aura', 'KillAura', 'hits every bad guy in range with the game\'s own hit request, like your swings do')
        :AddKeyPicker('bi_aura_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Kill aura' })
    aura:AddSlider('bi_aura_range', { Text = 'Range', Min = 5, Max = 80, Default = S.AuraRange, Rounding = 0, Suffix = ' studs', Callback = function(v) S.AuraRange = v end })
    aura:AddSlider('bi_aura_dmg', { Text = 'Damage per hit', Tooltip = 'the game\'s own hits do 5 to 79 depending on strength and weapon', Min = 1, Max = 200, Default = S.AuraDamage, Rounding = 0, Callback = function(v) S.AuraDamage = v end })
    aura:AddSlider('bi_aura_targets', { Text = 'Targets per hit', Min = 1, Max = 20, Default = S.AuraTargets, Rounding = 0, Callback = function(v) S.AuraTargets = v end })
    aura:AddSlider('bi_aura_rate', { Text = 'Hit every', Min = 0.1, Max = 2, Default = S.AuraRate, Rounding = 2, Suffix = 's', Callback = function(v) S.AuraRate = v end })
    toggle(aura, 'bi_onehit', 'One hit (finisher)', 'OneHit', 'sends the finisher the game uses on bad guys at 5 health or less, on every hit')

    local swing = Tab:AddRightGroupbox('Swing', 'hand')
    toggle(swing, 'bi_swing', 'Auto swing', 'AutoSwing', 'turns to the nearest bad guy within 11 studs and swings through the game\'s own hit button')
    toggle(swing, 'bi_autoequip', 'Auto equip weapon', 'AutoEquipWeapon', 'holds your weapon while the aura or swing is on')
    local count = swing:AddLabel('-', true)
    every(1, function()
        local list = enemies()
        local wep = weapon()
        count:SetText(("bad guys around: %d\nweapon: %s\nstrength level: %d"):format(#list, wep and (wep.Name .. " (lvl " .. tostring(wep.WeaponLevel.Value) .. ")") or "none", strengthLevel()))
    end)

    local bosses = Tab:AddLeftGroupbox('Bosses', 'skull')
    local lives = bosses:AddLabel('-', true)
    every(1, function()
        local l = bossLives()
        lives:SetText(("boss arena lives: %s / %s / %s\nScary Mary: %s   Bradley: %s"):format(
            tostring(l.Arena1 or "-"), tostring(l.Arena2 or "-"), tostring(l.Arena3 or "-"), tostring(l.Mary or "-"), tostring(l.Bradley or "-")))
    end)
    bosses:AddButton({ Text = 'Hit Scary Mary', Func = function() fire("DamageMary") end })
    bosses:AddButton({ Text = 'Hit Larry', Func = function() fire("DamageLarry") end })
    bosses:AddButton({ Text = 'Hit Bradley', Func = function() fire("DamageBradley") end })
    bosses:AddLabel('These send the hit each boss takes when you land the real move (Mary\'s key, Bradley while dizzy). They only count when the boss can take it.', true)

    local guard = Tab:AddRightGroupbox('Protection', 'shield')
    toggle(guard, 'bi_god', 'God mode', 'God', 'drops the damage reports the game sends for you (hail, lightning, lava, bombs, boss hits) and tells the server its attacks missed you', function(v)
        needHook(v)
        setCheckDamage()
    end)
    toggle(guard, 'bi_nocatch', 'Can\'t be caught', 'NoCatch', 'the chasing boss decides it caught you on your side; this drops that', needHook)
    local energy = guard:AddLabel('-', true)
    every(0.5, function() energy:SetText(("energy: %d / 200"):format(math.floor(Energy))) end)
end

do
    local Tab = Window:AddTab('Items', 'backpack', 'Healing, loot, spawning')

    local heal = Tab:AddLeftGroupbox('Healing', 'heart')
    toggle(heal, 'bi_autoeat', 'Auto eat', 'AutoEat', 'eats the best food you carry when energy drops under the line')
    heal:AddSlider('bi_eatbelow', { Text = 'Eat below', Min = 20, Max = 200, Default = S.EatBelow, Rounding = 0, Callback = function(v) S.EatBelow = v end })
    toggle(heal, 'bi_charges', 'Keep charges', 'KeepCharges', 'lollipop, bottle, medkit and chips count their charges on your side; this keeps them full')
    heal:AddButton({ Text = 'Eat now', Func = function() task.spawn(function() notify(eatOnce() and "ate" or "no food to eat") end) end })
    heal:AddButton({ Text = 'Heal everyone (MedKit)', Func = function() task.spawn(healEveryone) end })
    heal:AddButton({ Text = 'Heal all (Golden Apple)', Func = function() fire("HealTheNoobs") end })
    heal:AddButton({ Text = 'Try a free pizza heal', Func = function() fire("Energy", 25, "Pizza") end })

    local spawn = Tab:AddRightGroupbox('Item spawner', 'sparkles')
    spawn:AddLabel('Asks the server for an item every way the game\'s own client does. Whether it hands it over is the server\'s call: the result says which way worked, if any.', true)
    local chosen, way = ITEMS[1], "Auto"
    spawn:AddDropdown('bi_spawn_item', { Text = 'Item', Values = ITEMS, Default = ITEMS[1], Searchable = true, Callback = function(v) chosen = v or chosen end })
    local ways = { "Auto" }
    for _, w in ipairs(SPAWN_WAYS) do ways[#ways + 1] = w.Name end
    spawn:AddDropdown('bi_spawn_way', { Text = 'Way', Values = ways, Default = "Auto", Callback = function(v) way = v or way end })
    local result = spawn:AddLabel('', true)
    spawn:AddButton({
        Text = 'Spawn',
        Func = function()
            task.spawn(function()
                result:SetText("trying " .. chosen .. "...")
                local ok, how = spawnItem(chosen, way)
                result:SetText(ok and ("got " .. chosen .. " through " .. how) or ("the server didn't give " .. chosen))
            end)
        end,
    })
    spawn:AddButton({
        Text = 'Try every item',
        Func = function()
            task.spawn(function()
                local got = {}
                for _, item in ipairs(ITEMS) do
                    result:SetText("trying " .. item .. "...")
                    local ok, how = spawnItem(item, "Auto")
                    if ok then got[#got + 1] = item .. " (" .. how .. ")" end
                end
                result:SetText(#got > 0 and ("worked: " .. table.concat(got, ", ")) or "the server gave none of them")
            end)
        end,
    })

    local loot = Tab:AddLeftGroupbox('Loot', 'coins')
    toggle(loot, 'bi_autoloot', 'Auto loot', 'AutoLoot', 'picks up the hidden apples, cookies, keys, money, the medkit and opens the crates (crates need strength 2)')
    toggle(loot, 'bi_automoney', 'Auto pick up money', 'AutoMoney', 'collects the money bad guys drop the moment it lands')
    toggle(loot, 'bi_loottp', 'Step to loot', 'LootTeleport', 'steps next to each thing and back, since clicks have a reach')
    local found = loot:AddLabel('', true)
    loot:AddButton({ Text = 'Loot everything now', Func = function() task.spawn(function() found:SetText(("clicked %d things"):format(lootAll())) end) end })
    loot:AddButton({ Text = 'Grab a crowbar (rack)', Func = function() task.spawn(grabCrowbar) end })

    local shop = Tab:AddRightGroupbox('Vending', 'shopping-cart')
    local money = shop:AddLabel('-', true)
    every(1, function()
        local ms = mod("MoneyService")
        money:SetText("money: $" .. tostring(ms and ms.playersMoney or "-"))
    end)
    for _, machine in ipairs(MACHINES) do
        shop:AddButton({ Text = 'Buy from ' .. machine, Func = function() task.spawn(buyFrom, machine) end })
    end
    shop:AddLabel('These press the machine\'s own button from anywhere, so the game still checks your money and its stock. Armor opens once the fight room is cleared.', true)
end

do
    local Tab = Window:AddTab('Player', 'user', 'Stats and movement')

    local stats = Tab:AddLeftGroupbox('Levels', 'trending-up')
    local levels = stats:AddLabel('-', true)
    every(1, function()
        local ss = mod("StrengthService")
        levels:SetText(ss and ("speed level %d (xp %.1f)\nstrength level %d (xp %.1f)"):format(ss.level or 1, ss.xp or 0, ss.level2 or 1, ss.xp2 or 0) or "levels not loaded")
    end)
    stats:AddButton({ Text = 'Max speed level', Func = function() task.spawn(maxStat, "Speed") end })
    stats:AddButton({ Text = 'Max strength level', Func = function() task.spawn(maxStat, "Strength") end })
    toggle(stats, 'bi_trainspeed', 'Auto train speed', 'TrainSpeed', 'the game\'s own XP tick, the way the treadmill gives it')
    toggle(stats, 'bi_trainstrength', 'Auto train strength', 'TrainStrength', 'the game\'s own XP tick, the way the weights give it')

    local move = Tab:AddRightGroupbox('Movement', 'footprints')
    toggle(move, 'bi_speed', 'Walk speed', 'Speed', 'cutscenes reset your speed to 0 when it changes; while this is on that lock is off', function(v) setSpeedLocks(v or S.Jump) end)
    move:AddSlider('bi_speedv', { Text = 'Speed', Min = 16, Max = 120, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'bi_jump', 'Jump power', 'Jump', nil, function(v) setSpeedLocks(v or S.Speed) end)
    move:AddSlider('bi_jumpv', { Text = 'Jump', Min = 30, Max = 200, Default = S.JumpValue, Rounding = 0, Callback = function(v) S.JumpValue = v end })
    toggle(move, 'bi_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'bi_noclip', 'Noclip', 'Noclip')
    toggle(move, 'bi_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('bi_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('bi_flyspeed', { Text = 'Fly speed', Min = 10, Max = 200, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })
end

do
    local Tab = Window:AddTab('Story', 'book-open', 'Objectives and endings')

    local quest = Tab:AddLeftGroupbox('Objectives', 'flag')
    toggle(quest, 'bi_pete', 'Auto claim Uncle Pete', 'AutoPete', 'takes Uncle Pete\'s reward the moment his quest is done')
    toggle(quest, 'bi_gen', 'Fast generator', 'FastGenerator', 'while you sit on a generator bike, sends its power ticks much faster')
    toggle(quest, 'bi_hit', 'Auto break things', 'AutoHittables', 'hits doors, locks, the tree and anything else breakable you walk past (locks need the strength level they show)')
    quest:AddButton({ Text = 'Search trash cans', Func = function() task.spawn(searchTrash) end })
    quest:AddButton({ Text = 'Pick up batteries', Func = function() task.spawn(function() notify(("picked up %d"):format(grabBatteries())) end) end })
    quest:AddButton({ Text = 'Place batteries', Func = function() task.spawn(placeBatteries) end })
    quest:AddButton({ Text = 'Skip intro / free camera', Func = unlockCamera })

    local larry = Tab:AddRightGroupbox('Scary Larry ending', 'ghost')
    larry:AddLabel('The secret ending needs three things before the final fight. These collect each the way the game does.', true)
    larry:AddButton({ Text = 'Mask (bog)', Func = function() task.spawn(larryMask) end })
    larry:AddButton({ Text = 'Fell the tree (strength 3)', Func = function() task.spawn(larryTree) end })
    larry:AddButton({ Text = 'Gold crowbar', Func = function() task.spawn(larryCrowbar) end })
    larry:AddButton({ Text = 'Hat (punchable character)', Func = function() task.spawn(larryHat) end })

    local vote = Tab:AddLeftGroupbox('Ending vote', 'vote')
    toggle(vote, 'bi_vote', 'Auto vote', 'AutoVote', 'votes the moment the ending vote opens')
    vote:AddDropdown('bi_votefor', { Text = 'Vote for', Values = { "Ending1", "Ending2", "Ending3", "Ending4" }, Default = "Ending1", Callback = function(v) S.VoteFor = v or S.VoteFor end })
    vote:AddButton({ Text = 'Vote now', Func = function() fire("ChooseEnding", S.VoteFor) end })

    local death = Tab:AddRightGroupbox('Death', 'heart-crack')
    toggle(death, 'bi_nolobby', 'No forced lobby', 'NoLobby', 'the death screen sends you to the lobby after its countdown; this stops that so you can spectate', needHook)
    death:AddButton({ Text = 'Try free respawn', Func = function() fire("RespawnGui", "Pizza") end })
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'ESP')
    local box = Tab:AddLeftGroupbox('ESP', 'scan-eye')
    toggle(box, 'bi_esp_enemies', 'Bad guys', 'EspEnemies')
    toggle(box, 'bi_esp_bosses', 'Bosses', 'EspBosses')
    toggle(box, 'bi_esp_items', 'Items and crates', 'EspItems')
    toggle(box, 'bi_esp_money', 'Money', 'EspMoney')
    toggle(box, 'bi_esp_players', 'Players', 'EspPlayers')
end

do
    local Tab = Window:AddTab('Teleport', 'map-pin', 'Places')
    local box = Tab:AddLeftGroupbox('Places', 'map')
    local names = {}
    for _, spot in ipairs(SPOTS) do names[#names + 1] = spot[1] end
    local chosen = names[1]
    box:AddDropdown('bi_tp', { Text = 'Place', Values = names, Default = names[1], Searchable = true, Callback = function(v) chosen = v or chosen end })
    box:AddButton({
        Text = 'Teleport',
        Func = function()
            local pos = spotPosition(chosen)
            if pos then teleport(pos) else notify(chosen .. " isn't loaded right now") end
        end,
    })
    local people = Tab:AddRightGroupbox('Players', 'users')
    local target
    people:AddDropdown('bi_tp_player', { SpecialType = "Player", ExcludeLocalPlayer = true, Text = 'Player', Callback = function(v) target = v end })
    people:AddButton({
        Text = 'Teleport to player',
        Func = function()
            local player = typeof(target) == "Instance" and target or Players:FindFirstChild(tostring(target))
            local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if root then teleport(root.Position) end
        end,
    })
end

do
    local Tab = Window:AddTab('Misc', 'settings', 'Other')
    local box = Tab:AddLeftGroupbox('Idle', 'clock')
    box:AddToggle('bi_afk', {
        Text = 'Anti-AFK',
        Default = S.AntiAfk,
        Callback = function(v)
            S.AntiAfk = v
            setAntiAfk(v)
        end,
    })
end

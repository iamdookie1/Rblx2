--// Crunch Leaves -- auto crunch (teleporting), leaf rain, rolls, upgrades,
--// rebirths, selling, every reward, the Tix and gear shops.
--
-- Built against a script dump of the live game (place 98218013791770, game
-- 10764755131, version 1951). What its client code shows:
--  * Plain, readable remotes in ReplicatedStorage.Shared.Packages.TypedRemote,
--    no caller checks, no anti-cheat on the client.
--  * Leaves placed on your floor spawn copies into <plot>.SpawnedLeaves; the
--    game's RangeController picks them up from a box round your feet and calls
--    SpawnedLeavesController.TryCollect(leaf), which sends RequestCollectLeaf
--    with the leaf's spawn id. The server checks you're near the leaf. So the
--    crunch puts you on each leaf and calls that same TryCollect.
--  * Every buy and claim is a request with a key and no amount: BuyUpgrade(key),
--    PerformRebirth(), StartRoll(), BuyLeaf(slot), PlaceBestLeaves(),
--    SellItems({items}), ClaimReward("Daily1".."PlayTime12"),
--    ClaimGroupReward(), CollectOfflineRewards(), ClaimQuestReward(period,
--    task, cycle), BuyQuestReward(key), BuyGear(key, revision),
--    TriggerLeafRain(). The server decides, so asking early or often only
--    costs a refusal.
--  * Your data is a ReplicaService replica (DataAggregation): Cash, Rebirths,
--    UpgradeLevels, Inventory.
--  * The game rejoins you after 19 idle minutes (AntiAFKController on
--    Players.LocalPlayer.Idled); anti-AFK switches that off.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__CrunchLeavesStop) == "function" then pcall(Genv.__CrunchLeavesStop) end

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

--// settings ----------------------------------------------------------------

local S = {
    Crunch = false,
    CrunchDelay = 0.03,     -- seconds on each leaf
    ReturnHome = true,      -- back onto the spawn zone after a pass
    LeafRain = false,
    Roll = false,
    RollEvery = 3,
    BuyRolled = true,
    PlaceBest = true,
    Upgrades = false,
    UpgradeList = { Range = true, SpawnCooldown = true, BaseLevel = true, LeafRain = true, RollSlots = true, LeafLuck = true, OrbSpawnLuck = true },
    Rebirth = false,
    Sell = false,
    SellAt = 110,           -- inventory leaves
    KeepVariants = true,    -- keep anything that isn't a Normal variant
    Claim = false,
    Quests = false,
    TixShop = false,
    TixList = {},
    Gears = false,
    GearList = {},
    Speed = false,
    SpeedValue = 40,
    Noclip = false,
    Fly = false,
    FlySpeed = 60,
    InfJump = false,
    AntiAfk = true,
}

local Stats = { Crunched = 0, Started = os.clock(), CashStart = nil, Status = "off" }
local Library

--// the game's code ---------------------------------------------------------

local Shared = ReplicatedStorage:WaitForChild("Shared", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    return ok and result or nil
end

local SharedUtils = safeRequire(Shared and Shared:FindFirstChild("SharedUtils"))
local Config = safeRequire(Shared and Shared:FindFirstChild("Config"))
local QuestUtils = safeRequire(Shared and Shared:FindFirstChild("Modules") and Shared.Modules:FindFirstChild("QuestUtils"))

local function playerScripts()
    return LocalPlayer:FindFirstChildOfClass("PlayerScripts") or LocalPlayer:WaitForChild("PlayerScripts", 10)
end

local Controllers = {}
local function controller(name)
    if Controllers[name] then return Controllers[name] end
    local ps = playerScripts()
    local folder = ps and ps:FindFirstChild("ClientControllers")
    local result = safeRequire(folder and folder:FindFirstChild(name))
    Controllers[name] = result
    return result
end

local Replica
local function data()
    if not Replica then
        local ps = playerScripts()
        local agg = safeRequire(ps and ps:FindFirstChild("ClientModules") and ps.ClientModules:FindFirstChild("DataAggregation"))
        if agg then
            local ok, r = pcall(agg.GetReplica)
            if ok and r then Replica = r end
        end
    end
    return Replica and Replica.Data or nil
end

local function remote(name)
    if SharedUtils and SharedUtils.GetRemote then
        local ok, r = pcall(SharedUtils.GetRemote, name)
        if ok and r then return r end
    end
    local folder = Shared and Shared:FindFirstChild("Packages") and Shared.Packages:FindFirstChild("TypedRemote")
    return folder and folder:FindFirstChild(name)
end

local function fire(name, ...)
    local r = remote(name)
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
end

local function invoke(name, ...)
    local r = remote(name)
    if not r then return nil end
    local ok, result = pcall(r.InvokeServer, r, ...)
    return ok and result or nil
end

--// helpers -----------------------------------------------------------------

local function myChar()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function plot()
    local container = LocalPlayer:GetAttribute("PlotContainerName")
    local name = LocalPlayer:GetAttribute("PlotModelName")
    local map = Workspace:FindFirstChild("Map")
    local holder = map and container and map:FindFirstChild(container)
    return holder and name and holder:FindFirstChild(name) or nil
end

local function spawnZone()
    local p = plot()
    local floor = p and p:FindFirstChild("Floor1")
    return floor and floor:FindFirstChild("SpawnZone")
end

local function cash()
    local d = data()
    return d and tonumber(d.Cash) or 0
end

local function short(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qa", "Qi" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do
        n /= 1000
        i += 1
    end
    return (i == 1 and tostring(math.floor(n)) or ("%.2f"):format(n)) .. units[i]
end

--// auto crunch -------------------------------------------------------------
-- Each of your spawned leaves: you're put on it (the server checks you're
-- close), and the game's own TryCollect sends the pickup with the leaf's
-- spawn id and handles the server's answer.

local function myLeaves()
    local p = plot()
    local folder = p and p:FindFirstChild("SpawnedLeaves")
    local list = {}
    for _, leaf in ipairs(folder and folder:GetChildren() or {}) do
        if leaf:IsA("Model") and leaf:GetAttribute("SpawnedLeafOwnerUserId") == LocalPlayer.UserId then
            list[#list + 1] = leaf
        end
    end
    return list
end

local function leafPosition(leaf)
    local landing = leaf:GetAttribute("SpawnedLeafLandingPivot")
    if typeof(landing) == "CFrame" then return landing.Position end
    local ok, pivot = pcall(function() return leaf:GetPivot() end)
    return ok and pivot.Position or nil
end

local function crunchPass()
    local leaves = myLeaves()
    if #leaves == 0 then
        Stats.Status = "waiting for leaves to spawn"
        return 0
    end
    local collector = controller("SpawnedLeavesController")
    if not collector or type(collector.TryCollect) ~= "function" then
        Stats.Status = "collector not loaded"
        return 0
    end
    local _, root = myChar()
    if not root then return 0 end
    -- nearest first, walking the pile
    local here = root.Position
    table.sort(leaves, function(a, b)
        local pa, pb = leafPosition(a), leafPosition(b)
        return pa and pb and (pa - here).Magnitude < (pb - here).Magnitude or false
    end)
    local sent = 0
    for _, leaf in ipairs(leaves) do
        if not S.Crunch or Unloaded then break end
        if leaf.Parent then
            local pos = leafPosition(leaf)
            local _, r = myChar()
            if pos and r then
                r.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
                r.AssemblyLinearVelocity = Vector3.zero
                local ok, result = pcall(collector.TryCollect, leaf)
                if ok and result then
                    sent += 1
                    Stats.Crunched += 1
                end
                task.wait(S.CrunchDelay)
            end
        end
    end
    Stats.Status = ("crunched %d this pass"):format(sent)
    if S.ReturnHome then
        local zone = spawnZone()
        local _, r = myChar()
        if zone and r then r.CFrame = CFrame.new(zone.Position + Vector3.new(0, 3, 0)) end
    end
    return sent
end

loop(0.1, function()
    if S.Crunch then crunchPass() end
end)

--// leaf rain ---------------------------------------------------------------

local function leafRainReady()
    local nextRain = LocalPlayer:GetAttribute("nextLeafRain")
    return type(nextRain) == "number" and nextRain - Workspace:GetServerTimeNow() <= 0
end

local function triggerLeafRain()
    fire("TriggerLeafRain")
    local p = plot()
    local trigger = p and p:FindFirstChild("LeafRain") and p.LeafRain:FindFirstChild("Trigger")
    local _, root = myChar()
    if trigger and root and typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, trigger, 0)
        task.wait()
        pcall(firetouchinterest, root, trigger, 1)
    end
end

loop(1, function()
    if S.LeafRain and leafRainReady() then
        triggerLeafRain()
        task.wait(3)
    end
end)

--// rolling and buying ------------------------------------------------------

local function rollSlots()
    local p = plot()
    local list = {}
    for i = 1, 3 do
        local slot = p and p:FindFirstChild("RollSlot" .. i)
        if slot then list[i] = slot end
    end
    return list
end

local function slotPrice(slot)
    for _, child in ipairs(slot:GetDescendants()) do
        if child:GetAttribute("RollSlotItem") == true then return tonumber(child:GetAttribute("Price")) end
    end
    return nil
end

local function buyRolled()
    for i, slot in pairs(rollSlots()) do
        local top = slot:FindFirstChild("Top")
        if slot:GetAttribute("IsUnlocked") and top and top:GetAttribute("HasRolledLeaf") then
            local price = slotPrice(slot)
            if not price or price <= cash() then fire("BuyLeaf", i) end
        end
    end
end

loop(function() return S.RollEvery end, function()
    if not S.Roll then return end
    fire("StartRoll")
    task.wait(math.min(S.RollEvery * 0.8, 2.5))
    if S.BuyRolled then buyRolled() end
    if S.PlaceBest then fire("PlaceBestLeaves") end
end)

--// upgrades and rebirth ----------------------------------------------------

local UPGRADE_ORDER = { "SpawnCooldown", "BaseLevel", "Range", "LeafRain", "RollSlots", "LeafLuck", "OrbSpawnLuck" }

loop(2, function()
    if not S.Upgrades then return end
    for _, name in ipairs(UPGRADE_ORDER) do
        if S.UpgradeList[name] then
            fire("BuyUpgrade", name)
            task.wait(0.15)
        end
    end
end)

local function rebirthCost()
    local d = data()
    local levels = Config and Config.Rebirth and Config.Rebirth.Levels
    local next = levels and levels[((d and tonumber(d.Rebirths)) or 0) + 1]
    return next and tonumber(next.CashRequirement) or nil
end

loop(2, function()
    if not S.Rebirth then return end
    local cost = rebirthCost()
    if cost and cash() >= cost then
        fire("PerformRebirth")
        task.wait(3)
    end
end)

--// selling -----------------------------------------------------------------

local function leafItems()
    local d = data()
    local list = {}
    for _, item in ipairs(d and d.Inventory or {}) do
        if type(item) == "table" and item.ItemType == "Leaf" then list[#list + 1] = item end
    end
    return list
end

local function sellable(item)
    if item.IsFavorite or item.Favorite or item.Favorited then return false end
    if S.KeepVariants and type(item.Variant) == "string" and item.Variant ~= "" and item.Variant ~= "Normal" then return false end
    return true
end

local function sellLeaves()
    local batch = {}
    for _, item in ipairs(leafItems()) do
        if sellable(item) then batch[#batch + 1] = item end
    end
    if #batch > 0 then fire("SellItems", batch) end
    return #batch
end

loop(3, function()
    if S.Sell and #leafItems() >= S.SellAt then sellLeaves() end
end)

--// rewards -----------------------------------------------------------------

local function claimAll()
    for i = 1, 7 do fire("ClaimReward", "Daily" .. i) end
    for i = 1, 12 do fire("ClaimReward", "PlayTime" .. i) end
    fire("ClaimGroupReward")
    fire("CollectOfflineRewards")
end

loop(30, function()
    if S.Claim then claimAll() end
end)

local QUEST_PERIODS = { "Daily", "Weekly" }
local QUEST_TASKS = { "Playtime", "Rolls", "Crunch", "MutationOrbs" }

local function claimQuests()
    local now = Workspace:GetServerTimeNow()
    local periods = (Config and Config.Quests and Config.Quests.PeriodOrder) or QUEST_PERIODS
    local tasks = (Config and Config.Quests and Config.Quests.QuestOrder) or QUEST_TASKS
    for _, period in ipairs(periods) do
        local cycle
        if QuestUtils and QuestUtils.GetCycle then
            local ok, start = pcall(QuestUtils.GetCycle, period, now)
            if ok then cycle = start end
        end
        for _, taskName in ipairs(tasks) do invoke("ClaimQuestReward", period, taskName, cycle) end
    end
end

loop(20, function()
    if S.Quests then claimQuests() end
end)

local TIX_ITEMS = (Config and Config.Quests and Config.Quests.ShopOrder) or { "LuckRoll10", "LuckRoll100", "SpawnPotion4", "x2Cash", "VIP", "MoreLuck" }

loop(10, function()
    if not S.TixShop then return end
    for _, key in ipairs(TIX_ITEMS) do
        if S.TixList[key] then invoke("BuyQuestReward", key) end
    end
end)

--// gear shop ---------------------------------------------------------------

local GEAR_ITEMS = {}
if Config and Config.Gears and Config.Gears.Items then
    for key, def in pairs(Config.Gears.Items) do
        if def.Shop ~= false then GEAR_ITEMS[#GEAR_ITEMS + 1] = key end
    end
    table.sort(GEAR_ITEMS, function(a, b)
        return (Config.Gears.Items[a].Order or 0) < (Config.Gears.Items[b].Order or 0)
    end)
end

local function inStock(state, key)
    local stock = type(state) == "table" and state.Stock
    if type(stock) ~= "table" then return true end
    local entry = stock[key]
    if type(entry) == "number" then return entry > 0 end
    if type(entry) == "table" then return (tonumber(entry.Amount or entry.Stock or entry.Count) or 1) > 0 end
    return entry ~= nil and entry ~= false
end

loop(15, function()
    if not S.Gears then return end
    local state = invoke("GetGearShopState")
    if type(state) ~= "table" then return end
    for _, key in ipairs(GEAR_ITEMS) do
        if S.GearList[key] and inStock(state, key) then
            local def = Config.Gears.Items[key]
            if not def.CashCost or def.CashCost <= cash() then
                fire("BuyGear", key, state.Revision)
                task.wait(0.3)
            end
        end
    end
end)

--// movement ----------------------------------------------------------------

track(RunService.Heartbeat:Connect(function()
    if Unloaded or not S.Speed then return end
    pcall(function()
        local _, _, hum = myChar()
        if hum and hum.WalkSpeed ~= S.SpeedValue then hum.WalkSpeed = S.SpeedValue end
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
            dir = move + Vector3.new(0, look.LookVector.Y * move:Dot(forward), 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0, 1, 0) end
        root.AssemblyLinearVelocity = Vector3.zero
        if dir.Magnitude > 0 then root.CFrame = root.CFrame + dir.Unit * S.FlySpeed * dt end
    end)
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloaded or not S.InfJump then return end
    local _, _, hum = myChar()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

--// teleports ---------------------------------------------------------------

local function teleportTo(cf)
    local char = LocalPlayer.Character
    if char and cf then pcall(function() char:PivotTo(cf + Vector3.new(0, 3, 0)) end) end
end

local SPOTS = {
    Home = function()
        local p = plot()
        local spawn = p and p:FindFirstChild("Spawn")
        return spawn and spawn.CFrame
    end,
    ["Spawn zone"] = function()
        local zone = spawnZone()
        return zone and zone.CFrame
    end,
    Sell = function()
        local part = Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("Shops") and Workspace.Map.Shops:FindFirstChild("SellTeleportPart")
        return part and part.CFrame
    end,
    Plaza = function()
        local part = Workspace:FindFirstChild("SpawnLocation")
        return part and part.CFrame
    end,
}

--// anti-AFK ----------------------------------------------------------------
-- the game's own idle handler rejoins you after 19 minutes; this switches
-- the idle handlers off (Roblox's 20 minute kick hangs off the same signal)

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
    Unloaded = true
    pcall(setAntiAfk, false)
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    pcall(function()
        local _, _, hum = myChar()
        if hum and S.Speed then hum.WalkSpeed = (Config and Config.WalkSpeed) or 21 end
    end)
end

Genv.__CrunchLeavesStop = function()
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
    Title = 'Crunch Leaves',
    Footer = 'auto farm',
    Icon = 'leaf',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'CrunchLeaves',
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

do
    local Tab = Window:AddTab('Farm', 'leaf', 'Crunching and leaf rain')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('cl_cards', {
        Cards = {
            { Title = 'Cash', Value = '-', Icon = 'banknote' },
            { Title = 'Earned', Value = '-', Icon = 'trending-up' },
            { Title = 'Crunched', Value = '0', Icon = 'leaf' },
            { Title = 'Per minute', Value = '-', Icon = 'timer' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(1, function()
        local now = cash()
        Stats.CashStart = Stats.CashStart or now
        local minutes = math.max((os.clock() - Stats.Started) / 60, 1 / 60)
        cards:SetValue('Cash', '$' .. short(now))
        cards:SetValue('Earned', '$' .. short(now - Stats.CashStart))
        cards:SetValue('Crunched', tostring(Stats.Crunched))
        cards:SetValue('Per minute', short(Stats.Crunched / minutes) .. ' leaves')
        local d = data()
        local rain = LocalPlayer:GetAttribute("nextLeafRain")
        local rainIn = type(rain) == "number" and math.max(0, math.floor(rain - Workspace:GetServerTimeNow())) or nil
        local cost = rebirthCost()
        info:SetText(("crunch: %s\nleaves waiting: %d   leaf rain: %s\nrebirths: %s   next rebirth: %s   inventory leaves: %d"):format(
            Stats.Status, #myLeaves(), rainIn and (rainIn == 0 and "ready" or (rainIn .. "s")) or "-",
            tostring(d and d.Rebirths or "-"), cost and ("$" .. short(cost)) or "maxed", #leafItems()))
    end)

    local crunch = Tab:AddLeftGroupbox('Auto crunch', 'zap')
    toggle(crunch, 'cl_crunch', 'Auto crunch (teleport)', 'Crunch', 'puts you on each of your spawned leaves in turn and collects it with the game\'s own pickup')
        :AddKeyPicker('cl_crunch_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto crunch' })
    crunch:AddSlider('cl_crunch_delay', { Text = 'Time on each leaf', Tooltip = 'lower is faster; raise it if leaves get skipped', Min = 0, Max = 0.3, Default = S.CrunchDelay, Rounding = 2, Suffix = 's', Callback = function(v) S.CrunchDelay = v end })
    toggle(crunch, 'cl_home', 'Back to the spawn zone after each pass', 'ReturnHome')
    toggle(crunch, 'cl_rain', 'Auto leaf rain', 'LeafRain', 'starts the free leaf rain every time its timer is ready')
    crunch:AddButton({ Text = 'Leaf rain now', Func = function() task.spawn(triggerLeafRain) end })

    local roll = Tab:AddRightGroupbox('Rolling', 'dices')
    toggle(roll, 'cl_roll', 'Auto roll', 'Roll')
    roll:AddSlider('cl_roll_every', { Text = 'Roll every', Min = 1, Max = 15, Default = S.RollEvery, Rounding = 1, Suffix = 's', Callback = function(v) S.RollEvery = v end })
    toggle(roll, 'cl_buyrolled', 'Buy rolled leaves', 'BuyRolled', 'buys every rolled leaf you can afford')
    toggle(roll, 'cl_placebest', 'Place best leaves', 'PlaceBest', 'fills your floor with your best leaves after buying')
    roll:AddButton({ Text = 'Place best now', Func = function() fire("PlaceBestLeaves") end })
end

do
    local Tab = Window:AddTab('Progress', 'trending-up', 'Upgrades, rebirth, selling')

    local up = Tab:AddLeftGroupbox('Upgrades', 'arrow-up')
    toggle(up, 'cl_upgrades', 'Auto upgrade', 'Upgrades', 'buys each ticked upgrade whenever you can afford it (spawn rate and floor slots first)')
    for _, name in ipairs(UPGRADE_ORDER) do
        up:AddToggle('cl_up_' .. name, {
            Text = name,
            Default = S.UpgradeList[name],
            Callback = function(v) S.UpgradeList[name] = v end,
        })
    end
    local levels = up:AddLabel('-', true)
    every(2, function()
        local d = data()
        local parts = {}
        for _, name in ipairs(UPGRADE_ORDER) do
            parts[#parts + 1] = ("%s %s"):format(name, tostring(d and d.UpgradeLevels and d.UpgradeLevels[name] or 0))
        end
        levels:SetText(table.concat(parts, "\n"))
    end)

    local reb = Tab:AddRightGroupbox('Rebirth', 'refresh-cw')
    toggle(reb, 'cl_rebirth', 'Auto rebirth', 'Rebirth', 'rebirths the moment you have the cash for the next one')
    reb:AddButton({ Text = 'Rebirth now', Func = function() fire("PerformRebirth") end })

    local sell = Tab:AddRightGroupbox('Selling', 'badge-dollar-sign')
    toggle(sell, 'cl_sell', 'Auto sell', 'Sell', 'sells inventory leaves once you have this many (cap is 125). favorites are kept')
    sell:AddSlider('cl_sellat', { Text = 'Sell at', Min = 10, Max = 125, Default = S.SellAt, Rounding = 0, Suffix = ' leaves', Callback = function(v) S.SellAt = v end })
    toggle(sell, 'cl_keepvariants', 'Keep special variants', 'KeepVariants', 'never sells anything that isn\'t a Normal variant (silver, gold and the rest)')
    local sold = sell:AddLabel('', true)
    sell:AddButton({ Text = 'Sell now', Func = function() sold:SetText(("sold %d"):format(sellLeaves())) end })
end

do
    local Tab = Window:AddTab('Rewards', 'gift', 'Claims and shops')

    local claim = Tab:AddLeftGroupbox('Claims', 'gift')
    toggle(claim, 'cl_claim', 'Auto claim rewards', 'Claim', 'daily rewards, all 12 playtime rewards, the group reward and offline earnings, every 30s (the server only gives what\'s ready)', function(v) if v then task.spawn(claimAll) end end)
    claim:AddButton({ Text = 'Claim everything now', Func = function() task.spawn(claimAll) end })
    toggle(claim, 'cl_quests', 'Auto claim quests', 'Quests', 'daily and weekly quest Tix as each finishes', function(v) if v then task.spawn(claimQuests) end end)
    claim:AddButton({ Text = 'Claim quests now', Func = function() task.spawn(claimQuests) end })

    local tix = Tab:AddRightGroupbox('Tix shop', 'ticket')
    toggle(tix, 'cl_tix', 'Auto buy with Tix', 'TixShop', 'buys each ticked item whenever you have the Tix')
    for _, key in ipairs(TIX_ITEMS) do
        tix:AddToggle('cl_tix_' .. key, { Text = key, Default = false, Callback = function(v) S.TixList[key] = v end })
    end

    local gear = Tab:AddLeftGroupbox('Gear shop', 'flask-conical')
    toggle(gear, 'cl_gears', 'Auto buy gear', 'Gears', 'buys each ticked gear when it\'s in stock and you have the cash (the shop restocks every 5 minutes)')
    for _, key in ipairs(GEAR_ITEMS) do
        local def = Config.Gears.Items[key]
        gear:AddToggle('cl_gear_' .. key, {
            Text = ("%s ($%s)"):format(def.DisplayName or key, short(def.CashCost or 0)),
            Default = false,
            Callback = function(v) S.GearList[key] = v end,
        })
    end
end

do
    local Tab = Window:AddTab('Player', 'user', 'Movement and teleports')

    local move = Tab:AddLeftGroupbox('Movement', 'footprints')
    toggle(move, 'cl_speed', 'Walk speed', 'Speed')
    move:AddSlider('cl_speedv', { Text = 'Speed', Min = 16, Max = 150, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'cl_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'cl_noclip', 'Noclip', 'Noclip')
    toggle(move, 'cl_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('cl_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('cl_flyspeed', { Text = 'Fly speed', Min = 10, Max = 250, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })

    local tp = Tab:AddRightGroupbox('Teleport', 'map-pin')
    for _, name in ipairs({ "Home", "Spawn zone", "Sell", "Plaza" }) do
        tp:AddButton({ Text = name, Func = function() teleportTo(SPOTS[name]()) end })
    end
    local target
    tp:AddDropdown('cl_tp_player', { SpecialType = "Player", ExcludeLocalPlayer = true, Text = 'Player', Callback = function(v) target = v end })
    tp:AddButton({
        Text = 'Teleport to player',
        Func = function()
            local player = typeof(target) == "Instance" and target or Players:FindFirstChild(tostring(target))
            local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if root then teleportTo(root.CFrame) end
        end,
    })

    local misc = Tab:AddRightGroupbox('Idle', 'clock')
    misc:AddToggle('cl_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the game rejoining you after 19 idle minutes, and Roblox\'s 20 minute kick',
        Default = S.AntiAfk,
        Callback = function(v)
            S.AntiAfk = v
            setAntiAfk(v)
        end,
    })
end

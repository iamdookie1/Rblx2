--// Outpost Nights ----------------------------------------------------------------------
-- place 134158159495580 (game 8776018564) by A-1 Productions. The dump calls it
-- "Game"; mine Scrap and Crystals, sell them at the Outpost, survive the
-- employees at night.
--
-- How the game works (from its client code):
--   Remotes live in ReplicatedStorage["RemoteService/Remotes"]; the game's
--   RemoteService:Send(name, ...) is a plain FireServer.
--   Tools are folders in <character>.Tools with an Id attribute.
--     EquippedTool(id) equips one (nil unequips).
--     Swingable tools (pickaxes, swords: tag SwingableTool) swing on the
--     server while tool.HoldingDown:FireServer(true) is held.
--     Other tools fire tool.Activate:FireServer(args); rapid guns and
--     throwables send a world position, one-shot guns nothing.
--   Mining: Minable models in Workspace.Visuals (Scrap, Crystal) with
--     health, IsDestroyed and Id attributes. Drops go in the sack with
--     PutItemInSack(item) while a sack is equipped (sack tool attributes
--     current/max). DropItemFromSack() drops the last one; dropped at the
--     Outpost elevator they count as materials, and the lever's "Exchange"
--     prompt turns them into cash. The Deposit part (touch) pays cash into
--     the base upgrade machine.
--   Items: Workspace.Items. Shop items have the BuyableItem tag and a Price
--     attribute: BuyBuyableItem(item). Food is a DroppedItem you eat with
--     ConsumeItem(item). Tools on the floor: PickUpTool(item).
--   Night market: NightMarketState sends { item, price } entries,
--     BuyNightMarketItem(item, "cash") buys one.
--   Chests: tag Chest, OpenChest(chest). Gems: the server sends
--     LocalGem(id, position, amount), collected with LocalGem(id).
--     Experience: Experience(id, position, kind), collected with Experience(id).
--   Mobs: Workspace.Visuals.Mobs (client copies; real spot in the
--     ServerCFrame attribute), attributes Health, IsAggrod, IsDead.
--   Revive a teammate: <their character>.Revive:FireServer() (the game asks
--     for a Reboot Card).
--   World state: Workspace attributes day, isDay, timeRemaining, level,
--     currentCash, requiredCash; Hunger and Cash come by remote.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run retires the first.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__OutpostUnload then
    pcall(Genv.__OutpostUnload)
end
Genv.__OutpostRun = (Genv.__OutpostRun or 0) + 1
local RUN = Genv.__OutpostRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__OutpostRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
local Options = Library.Options
if not alive() then
    return
end

local Settings = {
    -- farm
    AutoMine = false, MineTypes = { Scrap = true, Crystal = true }, MineRange = 2000, AutoSell = true,
    SellWhenFull = true, AutoUpgradeBase = false, KeepCash = 0, CollectDrops = true, MineTimeout = 12,
    CollectExtras = true, AvoidEmployees = false, AvoidRadius = 30,
    -- items
    AutoEat = false, EatBelow = 40, AutoPickUpTools = false, AutoBuy = false, BuyPicks = {}, BuyMaxPrice = 300,
    BuyKeep = 0, BuyPerItem = 1, AutoNightMarket = false, NightPicks = {}, AutoChests = false, AutoGems = true, GemsGoTo = false,
    AutoExperience = true,
    -- combat and safety
    KillAura = false, AuraRange = 40, AuraWeapon = "Best", AuraOnlyAggro = false,
    SilentAim = false, SilentTarget = "Closest to mouse", SilentFov = 150, ShowFov = true, SilentRange = 400,
    SilentOnlyAggro = false, SilentHeight = 1.5,
    FleeAtNight = false, FleeWhenChased = false, FleeBelow = 30, AutoRevive = false,
    -- movement
    MoveMethod = "Teleport", TweenSpeed = 120, Speed = false, SpeedValue = 30, Jump = false, JumpValue = 70,
    Fly = false, FlySpeed = 60, Noclip = false, InfJump = false, AntiAfk = true,
    -- visuals
    EspMobs = false, EspMinables = false, EspChests = false, EspShop = false, EspFood = false, EspPlayers = false,
    EspDistance = 600, Fullbright = false, NoFog = false,
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[Outpost] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end

local function notify(title, text, seconds)
    pcall(Library.Notify, Library, { Title = title, Description = text, Time = seconds or 3 })
end

local Remotes = ReplicatedStorage:WaitForChild("RemoteService/Remotes", 20)
local function send(name, ...)
    local r = Remotes and Remotes:FindFirstChild(name)
    if r then
        r:FireServer(...)
        return true
    end
    return false
end
local function listen(name, fn)
    local r = Remotes and Remotes:WaitForChild(name, 10)
    if r then
        bind(r.OnClientEvent, fn)
    end
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
local function isDead()
    local c = character()
    return c == nil or c:GetAttribute("IsDead") == true
end

local function pivotPos(inst)
    if not inst then
        return nil
    end
    local cf = inst:GetAttribute("ServerCFrame")
    if typeof(cf) == "CFrame" then
        return cf.Position
    end
    if inst:IsA("BasePart") then
        return inst.Position
    end
    local ok, p = pcall(inst.GetPivot, inst)
    return ok and p.Position or nil
end
local function distanceTo(pos)
    local hrp = rootPart()
    return (hrp and pos) and (hrp.Position - pos).Magnitude or math.huge
end
local function tagged(tag)
    local ok, list = pcall(CollectionService.GetTagged, CollectionService, tag)
    return ok and list or {}
end

-- Game state the server sends us.
local State = { cash = 0, pending = 0, hunger = 100, gems = {}, market = {}, lastMarket = nil }
task.spawn(function()
    listen("Cash", function(v)
        State.cash = tonumber(v) or State.cash
    end)
end)
task.spawn(function()
    listen("PendingCash", function(v)
        State.pending += tonumber(v) or 0
    end)
end)
task.spawn(function()
    listen("Hunger", function(v)
        State.hunger = tonumber(v) or State.hunger
    end)
end)
task.spawn(function()
    listen("LocalGem", function(id, pos, amount)
        if pos == nil then
            State.gems[id] = nil
        else
            State.gems[id] = { pos = typeof(pos) == "CFrame" and pos.Position or pos, amount = amount or 1 }
        end
    end)
end)
task.spawn(function()
    listen("NightMarketState", function(state)
        State.lastMarket = state
        local list = {}
        local function walk(t, depth)
            if type(t) ~= "table" or depth > 4 then
                return
            end
            if type(t.item) == "string" then
                table.insert(list, { item = t.item, price = tonumber(t.price) or 0 })
            end
            for _, v in t do
                walk(v, depth + 1)
            end
        end
        walk(state, 0)
        State.market = list
    end)
end)

--// Tools \\--
local SACKS = { Sack = true, Briefcase = true, Backpack = true, DuffelBag = true, DoomsdayKit = true }
local GUN_ORDER = { "RocketLauncher", "Sniper", "LaserRifle", "Shotgun", "PlasmaPistol", "LaserPistol", "Crossbow", "NailGun", "Bow",
    "FreezeRay", "ToyGun" }
local MELEE_ORDER = { "LaserSword", "DiamondSword", "DiamondSpear", "Chainsaw", "GoldSword", "GoldSpear", "IronSword", "IronSpear",
    "SpikedBat", "Crowbar", "SqueakyHammer", "Wrench" }
local PICK_ORDER = { "CelestialPickaxe", "DiamondPickaxe", "GoldPickaxe", "IronPickaxe", "Pickaxe", "ToyPickaxe" }

local function toolsFolder()
    local c = character()
    return c and c:FindFirstChild("Tools")
end
local function tools()
    local f = toolsFolder()
    return f and f:GetChildren() or {}
end
local function toolNamed(name)
    local f = toolsFolder()
    return f and f:FindFirstChild(name)
end
local function firstOf(order)
    for _, name in order do
        local t = toolNamed(name)
        if t then
            return t
        end
    end
    return nil
end
local function pickaxe()
    local t = firstOf(PICK_ORDER)
    if t then
        return t
    end
    for _, tool in tools() do
        if tool.Name:find("Pickaxe") then
            return tool
        end
    end
    return nil
end
local function sack()
    for _, tool in tools() do
        if SACKS[tool.Name] then
            return tool
        end
    end
    return nil
end
local function sackState()
    local s = sack()
    if not s then
        return 0, 0
    end
    return s:GetAttribute("current") or 0, s:GetAttribute("max") or 10
end

-- You can switch tools yourself too, so the same tool is re-sent now and then.
local equippedId, equippedAt = nil, 0
local function equip(tool)
    local id = tool and tool:GetAttribute("Id")
    if id ~= equippedId or os.clock() - equippedAt > 1.5 then
        local changed = id ~= equippedId
        equippedId, equippedAt = id, os.clock()
        send("EquippedTool", id)
        if changed then
            task.wait(0.1)
        end
    end
end
local function hold(tool, on)
    local r = tool and tool:FindFirstChild("HoldingDown")
    if r then
        r:FireServer(on)
    end
end
local function activate(tool, ...)
    local r = tool and tool:FindFirstChild("Activate")
    if r then
        r:FireServer(...)
        return true
    end
    return false
end

--// Movement \\--
local moveToken = 0
local Travelling = false
local function face(pos)
    local hrp = rootPart()
    if hrp and pos then
        local flat = Vector3.new(pos.X, hrp.Position.Y, pos.Z)
        if (flat - hrp.Position).Magnitude > 0.1 then
            hrp.CFrame = CFrame.lookAt(hrp.Position, flat)
        end
    end
end

-- Moves you to `pos` (teleport or tween, per the setting); true once there.
local function moveTo(pos, lookAt)
    local hrp = rootPart()
    if not hrp or not pos then
        return false
    end
    moveToken += 1
    local token = moveToken
    local target = pos + Vector3.new(0, 3, 0)
    if Settings.MoveMethod == "Teleport" then
        hrp.CFrame = lookAt and CFrame.lookAt(target, Vector3.new(lookAt.X, target.Y, lookAt.Z)) or CFrame.new(target) * hrp.CFrame.Rotation
        hrp.AssemblyLinearVelocity = Vector3.zero
        return true
    end
    Travelling = true
    local t0 = os.clock()
    local limit = (target - hrp.Position).Magnitude / math.max(Settings.TweenSpeed, 1) + 8
    while alive() and token == moveToken and os.clock() - t0 < limit do
        local dt = RunService.Heartbeat:Wait()
        local r = rootPart()
        if not r then
            break
        end
        local delta = target - r.Position
        if delta.Magnitude < 2 then
            r.CFrame = lookAt and CFrame.lookAt(target, Vector3.new(lookAt.X, target.Y, lookAt.Z)) or CFrame.new(target) * r.CFrame.Rotation
            r.AssemblyLinearVelocity = Vector3.zero
            Travelling = false
            return token == moveToken
        end
        r.CFrame = CFrame.new(r.Position + delta.Unit * math.min(delta.Magnitude, Settings.TweenSpeed * dt)) * r.CFrame.Rotation
        r.AssemblyLinearVelocity = Vector3.zero
    end
    Travelling = false
    return false
end

-- A spot `gap` studs from `pos`, on your side of it.
local function besideOf(pos, gap)
    local hrp = rootPart()
    local away = hrp and (hrp.Position - pos) or Vector3.new(0, 0, 1)
    away = Vector3.new(away.X, 0, away.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    return pos + away * gap
end

local function firePrompt(prompt)
    if not prompt then
        return false
    end
    -- fireproximityprompt's second argument is how many times to fire in
    -- most executors, so it's called with the prompt alone; the hold is
    -- skipped by zeroing it for the call. Without it, hold the prompt.
    local hold = prompt.HoldDuration
    if typeof(fireproximityprompt) == "function" then
        pcall(function()
            prompt.HoldDuration = 0
        end)
        local ok = pcall(fireproximityprompt, prompt)
        pcall(function()
            prompt.HoldDuration = hold
        end)
        if ok then
            return true
        end
    end
    pcall(function()
        prompt:InputHoldBegin()
        task.wait(hold + 0.1)
        prompt:InputHoldEnd()
    end)
    return true
end

local function touch(part)
    local hrp = rootPart()
    if not hrp or not part then
        return
    end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, hrp, part, 0)
        task.wait(0.05)
        pcall(firetouchinterest, hrp, part, 1)
    else
        moveTo(part.Position)
    end
end

--// Places \\--
local function plotsFolder()
    return Workspace:FindFirstChild("Plots")
end
local function outpost()
    local plots = plotsFolder()
    local op = plots and plots:FindFirstChild("Outpost")
    return op and op:FindFirstChild("1")
end
local function outpostPart(name)
    local op = outpost()
    return op and op:FindFirstChild(name)
end
local function lever()
    return outpostPart("Lever") or tagged("SellLever")[1]
end
local function elevator()
    return outpostPart("Elevator") or tagged("OutpostElevator")[1]
end
local function deposit()
    return outpostPart("Deposit") or tagged("UpgradeMachineCashDeposit")[1]
end
local function itemsFolder()
    return Workspace:FindFirstChild("Items")
end
local function mobs()
    local out = {}
    local visuals = Workspace:FindFirstChild("Visuals")
    for _, folder in { visuals and visuals:FindFirstChild("Mobs"), Workspace:FindFirstChild("Mobs") } do
        for _, m in folder and folder:GetChildren() or {} do
            if m:IsA("Model") and not m:GetAttribute("IsDead") and (m:GetAttribute("Health") or 1) > 0 then
                table.insert(out, m)
            end
        end
    end
    return out
end

--// Jobs: one automation at a time \\--
local Job = { name = nil, token = 0, status = "Idle" }
local function stopJob(reason)
    Job.token += 1
    Job.name = nil
    Job.status = reason or "Idle"
    moveToken += 1
    local p = pickaxe()
    if p then
        hold(p, false)
    end
end
local function startJob(name, fn)
    stopJob()
    Job.name = name
    local token = Job.token
    local function still()
        return alive() and Job.token == token
    end
    task.spawn(function()
        local ok, err = pcall(fn, still, function(text)
            if still() then
                Job.status = text
            end
        end)
        if not ok then
            warn("[Outpost] " .. name .. ": " .. tostring(err))
        end
        if still() then
            Job.name = nil
            Job.status = "Idle"
        end
    end)
end

--// Farming \\--
local Stats = { startCash = nil, rocks = 0, sold = 0, trips = 0 }
local Farm = { sellNow = false }

local function minables()
    local out = {}
    for _, m in tagged("Minable") do
        if m.Parent and not m:GetAttribute("IsDestroyed") and (m:GetAttribute("health") or 1) > 0 then
            local kind = m.Name:match("^(%a+)")
            if Settings.MineTypes[kind] then
                table.insert(out, m)
            end
        end
    end
    return out
end

-- An employee chasing someone near `pos`?
local function guarded(pos)
    if not Settings.AvoidEmployees then
        return false
    end
    for _, m in mobs() do
        local p = pivotPos(m)
        if p and (p - pos).Magnitude < Settings.AvoidRadius then
            return true
        end
    end
    return false
end

local function nearestMinable()
    local best, bestD
    for _, m in minables() do
        local pos = pivotPos(m)
        local d = distanceTo(pos)
        if d <= Settings.MineRange and (not bestD or d < bestD) and not guarded(pos) then
            best, bestD = m, d
        end
    end
    return best
end

-- Every mined material lying around (Scrap, Crystal, and the Wire and
-- Batteries scrap piles sometimes drop), kept up to date as they appear and
-- go, so nothing a rock drops is forgotten: not the ones that didn't fit in
-- the sack before a sell trip, and not the drops of a rock broken by
-- accident next to the one being mined. Ones lying on the elevator are
-- already sold and are left alone.
local MATERIALS = { Scrap = true, Crystal = true }
local EXTRAS = { Wire = true, Battery = true }
local Materials = {}
local function isMaterial(item)
    return (MATERIALS[item.Name] or (Settings.CollectExtras and EXTRAS[item.Name])) and not item:HasTag("BuyableItem")
end
task.spawn(function()
    local folder = Workspace:WaitForChild("Items", 30)
    if not folder or not alive() then
        return
    end
    bind(folder.ChildAdded, function(item)
        task.defer(function()
            if item.Parent == folder and isMaterial(item) then
                Materials[item] = os.clock()
            end
        end)
    end)
    bind(folder.ChildRemoved, function(item)
        Materials[item] = nil
    end)
    for _, item in folder:GetChildren() do
        if isMaterial(item) then
            Materials[item] = os.clock()
        end
    end
end)

local Skip = setmetatable({}, { __mode = "k" })
local function leftovers()
    local el = elevator()
    local out = {}
    for item in Materials do
        local pos = item.Parent and pivotPos(item)
        if pos and not (Skip[item] and os.clock() < Skip[item]) and not (el and (pos - el.Position).Magnitude < 14)
            and distanceTo(pos) <= Settings.MineRange and not guarded(pos) then
            table.insert(out, item)
        end
    end
    return out
end
local function nearestLeftover()
    local best, bestD
    for _, item in leftovers() do
        local d = distanceTo(pivotPos(item))
        if not bestD or d < bestD then
            best, bestD = item, d
        end
    end
    return best
end

-- Puts `item` in the sack; true once the sack's count really went up.
local function storeItem(item)
    local s = sack()
    if not s or not item.Parent then
        return false
    end
    local before = sackState()
    local p = pivotPos(item)
    if p and distanceTo(p) > 6 then
        moveTo(besideOf(p, 2.5), p)
    end
    equip(s)
    for _ = 1, 2 do
        send("PutItemInSack", item)
        local t0 = os.clock()
        repeat
            task.wait(0.05)
        until sackState() > before or not item.Parent or os.clock() - t0 > 0.6
        if sackState() > before or not item.Parent then
            return true
        end
        equip(s)
    end
    -- The game refused it (out of reach, someone else's): leave it a while.
    Skip[item] = os.clock() + 20
    return false
end

-- Standing on top of the elevator, empties the sack onto it; returns how
-- many items left the sack.
local function dropAtElevator(still, status)
    local el, s = elevator(), sack()
    local current = sackState()
    if not el or not s or current == 0 then
        return 0
    end
    status("Dropping " .. current .. " items on the elevator")
    local top = el.Position + Vector3.new(0, (el.Size and el.Size.Y or 2) / 2, 0)
    moveTo(top)
    equip(s)
    local dropped, misses = 0, 0
    while still() and sackState() > 0 and misses < 4 do
        local before = sackState()
        send("DropItemFromSack")
        local t0 = os.clock()
        repeat
            task.wait(0.05)
        until sackState() < before or os.clock() - t0 > 0.6
        if sackState() < before then
            dropped += before - sackState()
            misses = 0
        else
            misses += 1
            equip(s)
            moveTo(top)
        end
    end
    return dropped
end

-- Sells: empties the sack on the elevator, pulls the Exchange lever and
-- (optionally) pays into the base upgrade. Works with an empty sack too
-- (just the lever, for what's already on the elevator).
local function sell(still, status)
    local el, lv = elevator(), lever()
    if not el or not lv then
        status("No Outpost elevator or lever loaded")
        return false
    end
    local back = rootPart() and rootPart().CFrame
    local dropped = dropAtElevator(still, status)
    Stats.sold += dropped
    if not still() then
        return false
    end
    local prompt = lv:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt then
        status("The sell lever has no prompt")
        return false
    end
    status("Pulling the sell lever")
    local cashBefore = State.cash
    moveTo(besideOf(lv.Position, 3), lv.Position)
    task.wait(0.15)
    firePrompt(prompt)
    local t0 = os.clock()
    repeat
        task.wait(0.1)
    until State.cash ~= cashBefore or os.clock() - t0 > 2
    Stats.trips += 1
    local gained = State.cash - cashBefore
    status(gained > 0 and ("Sold for $" .. gained) or "Pulled the lever")
    if Settings.AutoUpgradeBase and State.cash > Settings.KeepCash then
        local dp = deposit()
        if dp then
            status("Paying into the base upgrade")
            touch(dp)
            task.wait(0.3)
        end
    end
    return true, back
end

local function mineRock(still, status, rock, pick)
    local pos = pivotPos(rock)
    status("Mining " .. rock.Name)
    moveTo(besideOf(pos, 3.5), pos)
    equip(pick)
    face(pos)
    hold(pick, true)
    local t0 = os.clock()
    while still() and rock.Parent and not rock:GetAttribute("IsDestroyed") and (rock:GetAttribute("health") or 1) > 0
        and os.clock() - t0 < Settings.MineTimeout do
        face(pos)
        task.wait(0.15)
    end
    hold(pick, false)
    if rock:GetAttribute("IsDestroyed") or not rock.Parent or (rock:GetAttribute("health") or 1) <= 0 then
        Stats.rocks += 1
    end
    task.wait(0.3) -- let the drops land
end

-- The farm, in order of what matters: sell a full sack, pick up anything
-- left lying around (leftovers from the last trip, drops of rocks broken on
-- the side), then mine the next rock; with nothing left, sell what's carried.
local function mineLoop(still, status)
    Stats.startCash = Stats.startCash or State.cash
    while still() do
        if isDead() then
            status("Dead, waiting")
            task.wait(1)
        else
            local current, max = sackState()
            local hasSack = sack() ~= nil
            local leftover = Settings.CollectDrops and hasSack and current < max and nearestLeftover()
            if Farm.sellNow or (Settings.AutoSell and hasSack and current >= max) then
                Farm.sellNow = false
                sell(still, status)
            elseif leftover then
                status(("Picking up %s (%d/%d)"):format(leftover.Name, current, max))
                storeItem(leftover)
            else
                local rock = nearestMinable()
                local pick = pickaxe()
                if not pick then
                    status("No pickaxe in your tools")
                    task.wait(2)
                elseif rock then
                    mineRock(still, status, rock, pick)
                elseif Settings.AutoSell and current > 0 then
                    sell(still, status)
                else
                    status("No rocks to mine, waiting")
                    task.wait(2)
                end
            end
        end
        task.wait(0.05)
    end
    local p = pickaxe()
    if p then
        hold(p, false)
    end
end

--// Items \\--
-- Floor food (item type Craftable, described "Food"): eaten with ConsumeItem.
-- Granola bars and Bloxy Cola are held tools, picked up instead.
local FOOD = { Apple = true, Beans = true, Bread = true, Burger = true, Carrot = true, ChickenLeg = true, ChocolateBar = true,
    FriedEgg = true, Hotdog = true, Pizza = true, Spaghetti = true, Steak = true }
local function isFood(item)
    return FOOD[item.Name] == true and not item:HasTag("BuyableItem")
end
-- Every item the game types as a Tool or Wearable.
local TOOL_ITEMS = {}
for name in ("AdrenalineInjector AllSeeingEye Backpack BasicScanner BatteryPack Beacon Beartrap BloxyCola Boombox Bow Briefcase "
    .. "BugSpray Camera Chainsaw Claymore ClownHorn Compass CraftingTable Crossbow Crowbar DarkEnergyBottle DiamondArmor "
    .. "DiamondPickaxe DiamondSpear DiamondSword Doomsday DuffelBag FireworkLauncher Flamethrower FlashBeacon Flashlight FreezeRay "
    .. "Glider GoldArmor GoldPickaxe GoldSpear GoldSword GranolaBar GrapplingHook GravityGun GunAmmo IronArmor IronPickaxe IronSpear "
    .. "IronSword LaserPistol LaserRifle LaserSword LightningBottle LightningStaff LureGrenade Medkit MetalDetector Molotov Mop "
    .. "Mousetrap MysteryPotion NailGun Pickaxe PlasmaPistol PortableScanner PortalGun RebootCard RiotShield RocketLauncher Sack "
    .. "ScrabbleGoggles ShieldBubble Shotgun Sniper SoulPhone SpawnAFort SpawnAFortress SpikedBat SqueakyHammer StickyBomb "
    .. "SubspaceTripmine SuperScanner Tablet Taser ThunderstormBottle ToxicBottle ToyGun WalkieTalkie Watch Wrench Zipline"):gmatch("%a+") do
    TOOL_ITEMS[name] = true
end
local function looseItems(test)
    local out = {}
    local folder = itemsFolder()
    for _, item in folder and folder:GetChildren() or {} do
        if test(item) then
            table.insert(out, item)
        end
    end
    return out
end
local function nearest(list)
    local best, bestD
    for _, inst in list do
        local d = distanceTo(pivotPos(inst))
        if not bestD or d < bestD then
            best, bestD = inst, d
        end
    end
    return best, bestD
end

local busy = false
local function eatTick()
    if not Settings.AutoEat or busy or Job.name or State.hunger >= Settings.EatBelow then
        return
    end
    local food, d = nearest(looseItems(isFood))
    if not food then
        return
    end
    busy = true
    local back = rootPart() and rootPart().CFrame
    if d > 8 then
        moveTo(besideOf(pivotPos(food), 3), pivotPos(food))
    end
    send("ConsumeItem", food)
    task.wait(0.3)
    if back and d > 8 and rootPart() then
        moveTo(back.Position - Vector3.new(0, 3, 0))
    end
    busy = false
end

local Tried = setmetatable({}, { __mode = "k" })
local function tryOnce(inst, every)
    local last = Tried[inst]
    if last and os.clock() - last < (every or 4) then
        return false
    end
    Tried[inst] = os.clock()
    return true
end

local function pickUpToolsTick()
    if not Settings.AutoPickUpTools then
        return
    end
    for _, item in looseItems(function(i)
        return TOOL_ITEMS[i.Name] and not i:HasTag("BuyableItem")
    end) do
        if distanceTo(pivotPos(item)) < 10 and tryOnce(item, 5) then
            send("PickUpTool", item)
        end
    end
end

-- Shop items by name, cheapest first.
local function shopItems()
    return looseItems(function(i)
        return i:HasTag("BuyableItem") and i:GetAttribute("Price") ~= nil
            and (not i:GetAttribute("ExclusiveToPlayer") or i:GetAttribute("ExclusivePlayerUserId") == LocalPlayer.UserId)
    end)
end
local function shopNames()
    local seen, out = {}, {}
    for _, i in shopItems() do
        if not seen[i.Name] then
            seen[i.Name] = true
            table.insert(out, i.Name)
        end
    end
    table.sort(out)
    return out
end
-- Shop items as "Name  $price", nearest copy per name, for the buy picker.
local function shopChoices()
    local best = {}
    for _, i in shopItems() do
        local d = distanceTo(pivotPos(i))
        if not best[i.Name] or d < best[i.Name].d then
            best[i.Name] = { item = i, d = d }
        end
    end
    local out, byLabel = {}, {}
    for name, e in best do
        local label = ("%s  $%d"):format(name, e.item:GetAttribute("Price") or 0)
        table.insert(out, label)
        byLabel[label] = name
    end
    table.sort(out)
    return out, byLabel
end

-- Buys one `item`: goes there, buys, checks it left the shop, comes back.
local Bought = {} -- name -> how many auto buy got this session
local function buyItem(item)
    local price = item:GetAttribute("Price") or 0
    if State.cash < price then
        notify("Shop", ("%s costs $%d, you have $%d"):format(item.Name, price, State.cash), 3)
        return false
    end
    local p = pivotPos(item)
    local back = rootPart() and rootPart().CFrame
    if p and distanceTo(p) > 7 then
        moveTo(besideOf(p, 3), p)
        task.wait(0.15)
    end
    local cashBefore = State.cash
    send("BuyBuyableItem", item)
    local t0 = os.clock()
    repeat
        task.wait(0.1)
    until not item.Parent or item:GetAttribute("Price") == nil or State.cash < cashBefore or os.clock() - t0 > 2
    local ok = not item.Parent or State.cash < cashBefore or not item:HasTag("BuyableItem")
    if back and rootPart() and p and (back.Position - p).Magnitude > 8 then
        moveTo(back.Position - Vector3.new(0, 3, 0))
    end
    return ok
end
local function buyNamed(name)
    local best, bestD
    for _, i in shopItems() do
        if i.Name == name then
            local d = distanceTo(pivotPos(i))
            if not bestD or d < bestD then
                best, bestD = i, d
            end
        end
    end
    if not best then
        notify("Shop", name .. " isn't in a shop right now", 3)
        return false
    end
    local ok = buyItem(best)
    notify("Shop", ok and ("Bought " .. name) or ("Couldn't buy " .. name), 3)
    return ok
end

-- Auto buy, but careful: each picked item at most `BuyPerItem` times this
-- session, never over the max price, always keeping the cash floor.
local function buyTick()
    if not Settings.AutoBuy or busy or Job.name then
        return
    end
    for _, item in shopItems() do
        local price = item:GetAttribute("Price")
        if Settings.BuyPicks[item.Name] and (Bought[item.Name] or 0) < Settings.BuyPerItem and price <= Settings.BuyMaxPrice
            and State.cash - price >= Settings.BuyKeep and tryOnce(item, 10) then
            busy = true
            if buyItem(item) then
                Bought[item.Name] = (Bought[item.Name] or 0) + 1
            end
            busy = false
            return
        end
    end
end

local MarketBought = {}
local function marketEntry(name)
    for _, e in State.market do
        if e.item == name then
            return e
        end
    end
end
local function buyFromMarket(name)
    local e = marketEntry(name)
    if not e then
        return false, "not in the night market now"
    end
    if State.cash < e.price then
        return false, ("costs $%d, you have $%d"):format(e.price, State.cash)
    end
    send("BuyNightMarketItem", e.item, "cash")
    return true
end
local function nightMarketTick()
    if not Settings.AutoNightMarket then
        return
    end
    for _, e in State.market do
        if Settings.NightPicks[e.item] and (MarketBought[e.item] or 0) < Settings.BuyPerItem
            and State.cash - e.price >= Settings.BuyKeep and tryOnce(e, 15) then
            if buyFromMarket(e.item) then
                MarketBought[e.item] = (MarketBought[e.item] or 0) + 1
            end
            return
        end
    end
end

local function chestTick()
    if not Settings.AutoChests then
        return
    end
    for _, chest in tagged("Chest") do
        if not chest:GetAttribute("IsOpened") and distanceTo(pivotPos(chest)) < 12 and tryOnce(chest, 6) then
            send("OpenChest", chest)
        end
    end
end

local function gemsTick()
    if not Settings.AutoGems then
        return
    end
    for id, gem in State.gems do
        if distanceTo(gem.pos) < 20 then
            send("LocalGem", id)
            State.gems[id] = nil
        elseif Settings.GemsGoTo and not busy and not Job.name and distanceTo(gem.pos) < 400 then
            busy = true
            local back = rootPart() and rootPart().CFrame
            moveTo(gem.pos)
            send("LocalGem", id)
            State.gems[id] = nil
            if back and rootPart() then
                moveTo(back.Position - Vector3.new(0, 3, 0))
            end
            busy = false
            return
        end
    end
end

local function experienceTick()
    if not Settings.AutoExperience then
        return
    end
    for _, orb in tagged("Experience") do
        local id = orb:GetAttribute("Id")
        if id ~= nil and orb.Parent and tryOnce(orb, 3) then
            send("Experience", id)
            pcall(orb.Destroy, orb)
        end
    end
end

--// Combat and safety \\--
local function bestWeapon()
    local melee = firstOf(MELEE_ORDER)
    if not melee then
        for _, tool in tools() do
            if tool:HasTag("SwingableTool") and not tool.Name:find("Pickaxe") then
                melee = tool
                break
            end
        end
    end
    if Settings.AuraWeapon == "Melee" then
        return melee or pickaxe(), "melee"
    end
    local gun = firstOf(GUN_ORDER)
    if gun and gun:GetAttribute("IsOnCooldown") ~= true and gun:GetAttribute("isUsable") ~= false then
        return gun, "gun"
    end
    if melee then
        return melee, "melee"
    end
    return gun, "gun"
end

local auraHolding = nil
local function auraTick()
    if not Settings.KillAura or isDead() or (Job.name and Job.name ~= "Mine") then
        if auraHolding then
            hold(auraHolding, false)
            auraHolding = nil
        end
        return
    end
    local target, td
    for _, m in mobs() do
        if not Settings.AuraOnlyAggro or m:GetAttribute("IsAggrod") then
            local d = distanceTo(pivotPos(m))
            if d <= Settings.AuraRange and (not td or d < td) then
                target, td = m, d
            end
        end
    end
    if not target then
        if auraHolding then
            hold(auraHolding, false)
            auraHolding = nil
        end
        return
    end
    local weapon, kind = bestWeapon()
    if not weapon then
        return
    end
    local pos = pivotPos(target)
    if Job.name == "Mine" then
        -- Mining owns the pickaxe; only guns join in.
        if kind ~= "gun" then
            return
        end
    end
    equip(weapon)
    face(pos)
    if kind == "gun" then
        activate(weapon, pos + Vector3.new(0, 2, 0))
    else
        if td > 6 then
            moveTo(besideOf(pos, 3), pos)
        end
        if auraHolding ~= weapon then
            hold(weapon, true)
            auraHolding = weapon
        end
    end
end

local fleeing = false
local function safetyTick()
    if fleeing or isDead() then
        return
    end
    local hum = humanoid()
    local c = character()
    local hp = c and (c:GetAttribute("Health") or (hum and hum.Health)) or 100
    local maxHp = c and (c:GetAttribute("MaxHealth") or (hum and hum.MaxHealth)) or 100
    local chased = false
    for _, m in mobs() do
        if m:GetAttribute("IsAggrod") and distanceTo(pivotPos(m)) < 60 then
            chased = true
        end
    end
    local why
    if Settings.FleeWhenChased and chased then
        why = "an employee is after you"
    elseif hp / math.max(maxHp, 1) * 100 <= Settings.FleeBelow and (Settings.FleeWhenChased or Settings.FleeAtNight) then
        why = "low health"
    elseif Settings.FleeAtNight and Workspace:GetAttribute("isDay") == false then
        why = "night"
    end
    local el = why and elevator()
    if el and distanceTo(el.Position) > 30 then
        fleeing = true
        stopJob("Went to the Outpost: " .. why)
        moveTo(el.Position + Vector3.new(6, 0, 0))
        notify("Safety", "Back at the Outpost (" .. why .. ")", 3)
        task.wait(2)
        fleeing = false
    end
end

local function reviveTick()
    if not Settings.AutoRevive then
        return
    end
    for _, player in Players:GetPlayers() do
        local c = player ~= LocalPlayer and player.Character
        local r = c and c:FindFirstChild("Revive")
        if r and c:GetAttribute("IsDead") and distanceTo(pivotPos(c)) < 12 and tryOnce(c, 4) then
            local card = toolNamed("RebootCard")
            if card then
                equip(card)
            end
            r:FireServer()
        end
    end
end

--// Silent aim \\--
-- Guns send where they shoot: rapid guns and throwables a world position,
-- position tools a position and normal, one-shot guns nothing (they fire
-- where you face). When one of your guns fires, the position is swapped for
-- the chosen employee's body, and for a gun that sends nothing you're turned
-- to face it for that shot. Only your own tool remotes are touched.
local AIMABLE = {}
for _, n in GUN_ORDER do
    AIMABLE[n] = true
end
for _, n in { "LightningStaff", "FireworkLauncher", "DarkEnergyBottle", "LightningBottle", "Molotov", "ThunderstormBottle",
    "ToxicBottle", "LureGrenade", "StickyBomb", "GrapplingHook", "GravityGun", "PortalGun", "Taser" } do
    AIMABLE[n] = true
end

local function silentTarget()
    local cam = Workspace.CurrentCamera
    local mouse = UserInputService:GetMouseLocation()
    local best, bestScore
    for _, m in mobs() do
        if not Settings.SilentOnlyAggro or m:GetAttribute("IsAggrod") then
            local pos = pivotPos(m)
            local d = distanceTo(pos)
            if pos and d <= Settings.SilentRange then
                local score
                if Settings.SilentTarget == "Closest to mouse" and cam then
                    local v, onScreen = cam:WorldToViewportPoint(pos)
                    local sd = (Vector2.new(v.X, v.Y) - mouse).Magnitude
                    if onScreen and sd <= Settings.SilentFov then
                        score = sd
                    end
                else
                    score = d
                end
                if score and (not bestScore or score < bestScore) then
                    best, bestScore = m, score
                end
            end
        end
    end
    return best and (pivotPos(best) + Vector3.new(0, Settings.SilentHeight, 0)), best
end

-- One hook per session; reruns swap in their own handler through Genv.
Genv.__OutpostSilent = function(self, args)
    if not alive() or not Settings.SilentAim then
        return nil
    end
    local tool = self.Parent
    local folder = toolsFolder()
    if not tool or not folder or tool.Parent ~= folder or not AIMABLE[tool.Name] then
        return nil
    end
    local aim = silentTarget()
    if not aim then
        return nil
    end
    if args.n == 0 then
        face(aim)
        return nil
    end
    local changed = false
    for i = 1, args.n do
        if typeof(args[i]) == "Vector3" and not changed then
            args[i] = aim
            changed = true
        elseif typeof(args[i]) == "CFrame" and not changed then
            args[i] = CFrame.new(aim)
            changed = true
        end
    end
    return changed and args or nil
end
if not Genv.__OutpostSilentHooked and typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    Genv.__OutpostSilentHooked = true
    local wrap = typeof(newcclosure) == "function" and newcclosure or function(f)
        return f
    end
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        local handler = Genv.__OutpostSilent
        if handler and getnamecallmethod() == "FireServer" and typeof(self) == "Instance" and self.Name == "Activate" then
            local ok, args = pcall(handler, self, table.pack(...))
            if ok and args then
                return old(self, table.unpack(args, 1, args.n))
            end
        end
        return old(self, ...)
    end))
end

-- The FOV circle.
local FovCircle
pcall(function()
    FovCircle = Drawing.new("Circle")
    FovCircle.Thickness = 1.5
    FovCircle.NumSides = 48
    FovCircle.Filled = false
    FovCircle.Transparency = 0.8
    FovCircle.Color = Color3.fromRGB(255, 255, 255)
    FovCircle.Visible = false
end)
local function fovStep()
    if not FovCircle then
        return
    end
    local show = Settings.SilentAim and Settings.ShowFov and Settings.SilentTarget == "Closest to mouse"
    FovCircle.Visible = show
    if show then
        FovCircle.Position = UserInputService:GetMouseLocation()
        FovCircle.Radius = Settings.SilentFov
        local _, target = silentTarget()
        FovCircle.Color = target and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(255, 255, 255)
    end
end

--// Movement extras \\--
local savedJump
local function movementStep()
    local hum = humanoid()
    if not hum then
        return
    end
    if Settings.Speed then
        hum.WalkSpeed = Settings.SpeedValue
    end
    if Settings.Jump then
        savedJump = savedJump or { hum.UseJumpPower, hum.JumpPower, hum.JumpHeight }
        hum.UseJumpPower = true
        hum.JumpPower = Settings.JumpValue
    elseif savedJump then
        hum.UseJumpPower, hum.JumpPower, hum.JumpHeight = savedJump[1], savedJump[2], savedJump[3]
        savedJump = nil
    end
end

local noclipParts = {}
local function noclipStep()
    local c = character()
    if not c then
        return
    end
    if Settings.Noclip or Settings.Fly or Travelling then
        for _, p in c:GetDescendants() do
            if p:IsA("BasePart") and p.CanCollide then
                noclipParts[p] = true
                p.CanCollide = false
            end
        end
    elseif next(noclipParts) then
        for p in noclipParts do
            if p.Parent then
                p.CanCollide = true
            end
        end
        table.clear(noclipParts)
    end
end

local function flyStep(dt)
    if not Settings.Fly then
        return
    end
    local hrp = rootPart()
    local cam = Workspace.CurrentCamera
    if not hrp or not cam then
        return
    end
    local dir = Vector3.zero
    local cf = cam.CFrame
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0, 1, 0) end
    local hum = humanoid()
    if hum and hum.MoveDirection.Magnitude > 0 and dir.Magnitude == 0 then
        dir = hum.MoveDirection
    end
    if dir.Magnitude > 0 then
        dir = dir.Unit
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = CFrame.new(hrp.Position + dir * Settings.FlySpeed * dt) * cf.Rotation
end

bind(UserInputService.JumpRequest, function()
    if Settings.InfJump and alive() then
        local hum = humanoid()
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)
bind(LocalPlayer.Idled, function()
    if Settings.AntiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

--// ESP \\--
local EspFolder = Instance.new("Folder")
EspFolder.Name = "OutpostEsp"
pcall(function()
    EspFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not EspFolder.Parent then
    EspFolder.Parent = LocalPlayer:WaitForChild("PlayerGui")
end
local Esp = {}
local function espFor(inst, text, color)
    local e = Esp[inst]
    if not e then
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(200, 34)
        bb.AlwaysOnTop = true
        bb.StudsOffset = Vector3.new(0, 3, 0)
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.4
        label.Parent = bb
        local hl = Instance.new("Highlight")
        hl.FillTransparency = 0.75
        hl.OutlineTransparency = 0.2
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        bb.Parent = EspFolder
        hl.Parent = EspFolder
        e = { bb = bb, label = label, hl = hl }
        Esp[inst] = e
    end
    e.bb.Adornee = inst:IsA("BasePart") and inst or (inst:IsA("Model") and (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true))) or nil
    e.hl.Adornee = inst
    e.label.Text = text
    e.label.TextColor3 = color
    e.hl.FillColor = color
    e.hl.OutlineColor = color
    e.seen = true
end
local function updateEsp()
    for _, e in Esp do
        e.seen = false
    end
    local function add(list, on, label, color)
        if not on then
            return
        end
        for _, inst in list do
            local d = distanceTo(pivotPos(inst))
            if d <= Settings.EspDistance then
                espFor(inst, label(inst, d), type(color) == "function" and color(inst) or color)
            end
        end
    end
    add(mobs(), Settings.EspMobs, function(m, d)
        return ("%s%s  %d hp  %dm"):format(m:GetAttribute("IsAggrod") and "⚠ " or "", m.Name, m:GetAttribute("Health") or 0, d)
    end, function(m)
        return m:GetAttribute("IsAggrod") and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 170, 70)
    end)
    add(minables(), Settings.EspMinables, function(m, d)
        return ("%s  %d%%  %dm"):format(m.Name:match("^%a+"), m:GetAttribute("health") or 0, d)
    end, function(m)
        return m.Name:find("Crystal") and Color3.fromRGB(120, 200, 255) or Color3.fromRGB(190, 190, 190)
    end)
    add(tagged("Chest"), Settings.EspChests, function(c, d)
        return ("Chest  %dm"):format(d)
    end, Color3.fromRGB(255, 205, 90))
    add(tagged("Crate"), Settings.EspChests, function(c, d)
        return ("%s  $%s  %dm"):format(c:GetAttribute("IsGem") and "Gem crate" or "Crate", tostring(c:GetAttribute("Price") or "?"), d)
    end, Color3.fromRGB(255, 160, 220))
    add(shopItems(), Settings.EspShop, function(i, d)
        return ("%s  $%d  %dm"):format(i.Name, i:GetAttribute("Price") or 0, d)
    end, Color3.fromRGB(120, 255, 140))
    add(looseItems(isFood), Settings.EspFood, function(i, d)
        return ("%s  %dm"):format(i.Name, d)
    end, Color3.fromRGB(255, 230, 120))
    local others = {}
    for _, p in Players:GetPlayers() do
        if p ~= LocalPlayer and p.Character then
            table.insert(others, p.Character)
        end
    end
    add(others, Settings.EspPlayers, function(c, d)
        return ("%s%s  %dm"):format(c.Name, c:GetAttribute("IsDead") and " (down)" or "", d)
    end, Color3.fromRGB(120, 180, 255))
    for inst, e in Esp do
        if not e.seen or not inst.Parent then
            e.bb:Destroy()
            e.hl:Destroy()
            Esp[inst] = nil
        end
    end
end

--// Lighting \\--
local savedLighting
local function lightingStep()
    if Settings.Fullbright or Settings.NoFog then
        savedLighting = savedLighting or { Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows, Lighting.Ambient }
        if Settings.Fullbright then
            Lighting.Brightness = 2
            Lighting.ClockTime = 14
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        end
        if Settings.NoFog then
            Lighting.FogEnd = 1e6
            for _, a in Lighting:GetChildren() do
                if a:IsA("Atmosphere") then
                    a.Density = 0
                end
            end
        end
    elseif savedLighting then
        Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows, Lighting.Ambient =
            savedLighting[1], savedLighting[2], savedLighting[3], savedLighting[4], savedLighting[5]
        savedLighting = nil
    end
end

--// Teleport targets \\--
local function placeTargets()
    local out = {}
    local op = outpost()
    if op then
        out["Outpost elevator"] = elevator()
        out["Sell lever"] = lever()
        out["Base upgrade deposit"] = deposit()
    end
    local basement = Workspace:GetAttribute("BasementEntrancePosition")
    if typeof(basement) == "Vector3" then
        out["Basement entrance"] = basement
    end
    local prison = Workspace:GetAttribute("PrisonEntrancePosition")
    if typeof(prison) == "Vector3" then
        out["Prison entrance"] = prison
    end
    for _, plot in plotsFolder() and plotsFolder():GetChildren() or {} do
        local inner = plot:FindFirstChild("1") or plot
        if inner then
            out[plot.Name] = out[plot.Name] or inner
        end
    end
    for _, tag in { "StorageFacilityEntrance", "InfiniteStairwellEntrance", "KeycardSwiper", "Pillar", "PillarActivator" } do
        local inst = tagged(tag)[1]
        if inst then
            out[tag:gsub("(%l)(%u)", "%1 %2")] = inst
        end
    end
    return out
end
local function goTo(target)
    if typeof(target) == "Vector3" then
        return moveTo(target)
    end
    local pos = target and pivotPos(target)
    return pos and moveTo(pos)
end

--// UI \\--
local UI = {}
UI.Window = Library:CreateWindow({
    Title = "Outpost Nights",
    Footer = "dookie hub · Ui3",
    Icon = "pickaxe",
    Size = UDim2.fromOffset(720, 560),
    ConfigFolder = "Ui3/OutpostNights",
})

local function setText(label, text)
    if label and label.__t ~= text then
        label.__t = text
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
        Text = text, Default = Settings[key], Min = min, Max = max, Suffix = suffix, Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function choice(box, idx, text, key, values, tooltip)
    return box:AddDropdown(idx, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v or values[1]
        end,
    })
end
local function multi(box, idx, text, key, values, defaults, tooltip)
    return box:AddDropdown(idx, {
        Text = text, Values = values, Default = defaults, Multi = true, Searchable = #values > 8, Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end

-- Dashboard
do
    local Tab = UI.Window:AddTab("Dashboard", "layout-dashboard", "Day, cash and your sack")
    local DayBox = Tab:AddLeftGroupbox("World", "sun")
    UI.DayLabel = DayBox:AddLabel("...", true)
    local YouBox = Tab:AddRightGroupbox("You", "user")
    UI.YouLabel = YouBox:AddLabel("...", true)
    UI.JobLabel = YouBox:AddLabel("Idle", true)
    UI.StatsLabel = YouBox:AddLabel("", true)
    YouBox:AddButton({ Text = "Stop everything", Func = function()
        stopJob("Stopped")
    end })
end

-- Farm
do
    local Tab = UI.Window:AddTab("Farm", "pickaxe", "Mine, sell and upgrade")
    local MineBox = Tab:AddLeftGroupbox("Auto mine", "pickaxe")
    toggle(MineBox, "AutoMine", "Auto mine", "AutoMine",
        "Goes to the nearest rock, swings your best pickaxe until it breaks, puts the drops in your sack and sells when it's full",
        function(v)
            if v then
                startJob("Mine", mineLoop)
            elseif Job.name == "Mine" then
                stopJob("Mining off")
            end
        end)
    multi(MineBox, "MineTypes", "Rocks", "MineTypes", { "Scrap", "Crystal" }, { "Scrap", "Crystal" })
    slider(MineBox, "MineRange", "Travel up to", "MineRange", 50, 3000, " studs")
    slider(MineBox, "MineTimeout", "Give up on a rock after", "MineTimeout", 4, 40, " s")
    toggle(MineBox, "CollectDrops", "Pick up drops and leftovers", "CollectDrops",
        "Every Scrap and Crystal lying around is remembered: what didn't fit before a sell trip, and drops of rocks broken on the side")
    toggle(MineBox, "CollectExtras", "Also Wire and Batteries", "CollectExtras")
    toggle(MineBox, "AvoidEmployees", "Skip spots near employees", "AvoidEmployees")
    slider(MineBox, "AvoidRadius", "Employee distance", "AvoidRadius", 10, 80, " studs")
    UI.LeftoverLabel = MineBox:AddLabel("Leftovers: 0", true)
    MineBox:AddButton({ Text = "Pick up leftovers now", Func = function()
        if Job.name == "Mine" then
            return
        end
        startJob("Leftovers", function(still, status)
            while still() do
                local c, m = sackState()
                local item = sack() and c < m and nearestLeftover()
                if not item then
                    break
                end
                status(("Picking up %s (%d/%d)"):format(item.Name, c, m))
                storeItem(item)
            end
        end)
    end })

    local SellBox = Tab:AddRightGroupbox("Sell and upgrade", "badge-dollar-sign")
    toggle(SellBox, "AutoSell", "Sell when the sack is full", "AutoSell",
        "Drops everything at the Outpost elevator and pulls the Exchange lever")
    toggle(SellBox, "AutoUpgradeBase", "Pay into the base upgrade after selling", "AutoUpgradeBase")
    slider(SellBox, "KeepCash", "Keep at least", "KeepCash", 0, 2000, " $")
    SellBox:AddButton({ Text = "Sell now", Func = function()
        if Job.name == "Mine" then
            -- The farm sells at its next step and carries on.
            Farm.sellNow = true
            return
        end
        startJob("Sell", function(still, status)
            local ok, back = sell(still, status)
            if ok and back and still() and rootPart() then
                moveTo(back.Position - Vector3.new(0, 3, 0))
            end
        end)
    end }):AddButton({ Text = "Pay into base", Func = function()
        task.spawn(touch, deposit())
    end })
end

-- Items
do
    local Tab = UI.Window:AddTab("Items", "shopping-bag", "Food, shops, chests, gems")
    local EatBox = Tab:AddLeftGroupbox("Eating", "drumstick")
    toggle(EatBox, "AutoEat", "Auto eat", "AutoEat", "Eats the nearest food when your hunger drops below the line")
    slider(EatBox, "EatBelow", "Eat below", "EatBelow", 5, 95, "%")
    toggle(EatBox, "AutoPickUpTools", "Pick up tools you walk past", "AutoPickUpTools")

    local ShopBox = Tab:AddRightGroupbox("Shop", "store")
    local labels, byLabel = shopChoices()
    UI.BuyOne = ShopBox:AddDropdown("BuyOnePick", { Text = "Item", Values = labels, Searchable = true })
    ShopBox:AddButton({ Text = "Buy one", Func = function()
        local label = Options.BuyOnePick and Options.BuyOnePick.Value
        local name = label and (byLabel[label] or label:match("^(.-)  %$"))
        if name then
            task.spawn(buyNamed, name)
        else
            notify("Shop", "Pick an item first", 2)
        end
    end }):AddButton({ Text = "Refresh", Func = function()
        labels, byLabel = shopChoices()
        UI.BuyOne:SetValues(labels)
        UI.ShopPicks:SetValues(shopNames())
    end })
    ShopBox:AddDivider()
    UI.ShopPicks = multi(ShopBox, "BuyPicks", "Auto buy these", "BuyPicks", shopNames(), {})
    toggle(ShopBox, "AutoBuy", "Auto buy", "AutoBuy", "Buys picked items from the shops, at most the count below of each this session")
    slider(ShopBox, "BuyPerItem", "At most of each", "BuyPerItem", 1, 10)
    slider(ShopBox, "BuyMaxPrice", "Max price", "BuyMaxPrice", 5, 2000, " $")
    slider(ShopBox, "BuyKeep", "Keep at least", "BuyKeep", 0, 2000, " $")

    local NightBox = Tab:AddRightGroupbox("Night market", "moon")
    UI.NightLabel = NightBox:AddLabel("Not seen yet", true)
    UI.NightOne = NightBox:AddDropdown("NightOnePick", { Text = "Item", Values = {}, Searchable = true })
    NightBox:AddButton({ Text = "Buy one", Func = function()
        local name = Options.NightOnePick and Options.NightOnePick.Value
        if not name then
            notify("Night market", "Pick an item first", 2)
            return
        end
        local ok, why = buyFromMarket(name)
        notify("Night market", ok and ("Bought " .. name) or (name .. ": " .. tostring(why)), 3)
    end })
    UI.NightPicks = multi(NightBox, "NightPicks", "Auto buy these", "NightPicks", {}, {})
    toggle(NightBox, "AutoNightMarket", "Auto buy (same per-item limit)", "AutoNightMarket")

    local LootBox = Tab:AddLeftGroupbox("Loot", "gem")
    toggle(LootBox, "AutoChests", "Open chests near you", "AutoChests")
    toggle(LootBox, "AutoGems", "Collect gems near you", "AutoGems")
    toggle(LootBox, "GemsGoTo", "Go get gems (within 400 studs)", "GemsGoTo")
    toggle(LootBox, "AutoExperience", "Collect experience orbs", "AutoExperience")
end

-- Combat
do
    local Tab = UI.Window:AddTab("Combat", "swords", "Kill aura, fleeing and reviving")
    local AuraBox = Tab:AddLeftGroupbox("Kill aura", "crosshair")
    toggle(AuraBox, "KillAura", "Kill aura", "KillAura", "Turns to the nearest employee and fires your best gun, or swings your sword")
        :AddKeyPicker("AuraKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Kill aura" })
    choice(AuraBox, "AuraWeapon", "Weapon", "AuraWeapon", { "Best", "Melee" })
    slider(AuraBox, "AuraRange", "Range", "AuraRange", 5, 150, " studs")
    toggle(AuraBox, "AuraOnlyAggro", "Only ones chasing me", "AuraOnlyAggro")

    local AimBox = Tab:AddLeftGroupbox("Silent aim (guns)", "target")
    toggle(AimBox, "SilentAim", "Silent aim", "SilentAim",
        "Your gun shots and throws go to an employee even when you aim elsewhere")
        :AddKeyPicker("SilentKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Silent aim" })
    choice(AimBox, "SilentTarget", "Target", "SilentTarget", { "Closest to mouse", "Closest to me" })
    slider(AimBox, "SilentFov", "FOV radius", "SilentFov", 20, 600, " px")
    toggle(AimBox, "ShowFov", "Show FOV circle", "ShowFov")
    slider(AimBox, "SilentRange", "Max distance", "SilentRange", 20, 1000, " studs")
    toggle(AimBox, "SilentOnlyAggro", "Only ones chasing me", "SilentOnlyAggro")
    if typeof(hookmetamethod) ~= "function" then
        AimBox:AddLabel("Your executor has no hookmetamethod, so silent aim can't work here", true)
    end

    local SafeBox = Tab:AddRightGroupbox("Safety", "shield")
    toggle(SafeBox, "FleeAtNight", "Go to the Outpost at night", "FleeAtNight")
    toggle(SafeBox, "FleeWhenChased", "Go to the Outpost when chased", "FleeWhenChased")
    slider(SafeBox, "FleeBelow", "Or below health", "FleeBelow", 5, 90, "%")
    toggle(SafeBox, "AutoRevive", "Revive downed teammates near me", "AutoRevive", "Uses the game's revive (it wants a Reboot Card)")
end

-- Movement
do
    local Tab = UI.Window:AddTab("Movement", "footprints", "Speed, fly and teleports")
    local MoveBox = Tab:AddLeftGroupbox("Movement", "move")
    choice(MoveBox, "MoveMethod", "Move by", "MoveMethod", { "Teleport", "Tween" }, "How the farm, buying and teleports travel")
    slider(MoveBox, "TweenSpeed", "Tween speed", "TweenSpeed", 30, 300, " studs/s")
    toggle(MoveBox, "Speed", "Walk speed", "Speed")
    slider(MoveBox, "SpeedValue", "Speed", "SpeedValue", 16, 120)
    toggle(MoveBox, "Jump", "Jump power", "Jump")
    slider(MoveBox, "JumpValue", "Jump", "JumpValue", 50, 200)
    toggle(MoveBox, "InfJump", "Infinite jump", "InfJump")
    toggle(MoveBox, "Fly", "Fly", "Fly"):AddKeyPicker("FlyKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
    slider(MoveBox, "FlySpeed", "Fly speed", "FlySpeed", 10, 200)
    toggle(MoveBox, "Noclip", "Noclip", "Noclip")
    toggle(MoveBox, "AntiAfk", "Anti AFK", "AntiAfk")

    local TpBox = Tab:AddRightGroupbox("Teleports", "map-pin")
    local targets = placeTargets()
    local function names()
        local list = {}
        for k in targets do
            table.insert(list, k)
        end
        table.sort(list)
        return list
    end
    UI.TpPick = TpBox:AddDropdown("TpPick", { Text = "Place", Values = names(), Searchable = true })
    TpBox:AddButton({ Text = "Go", Func = function()
        local which = Options.TpPick and Options.TpPick.Value
        task.spawn(goTo, which and targets[which])
    end }):AddButton({ Text = "Refresh", Func = function()
        targets = placeTargets()
        UI.TpPick:SetValues(names())
    end })
    TpBox:AddButton({ Text = "Nearest rock", Func = function()
        local m = nearestMinable()
        if m then
            task.spawn(moveTo, besideOf(pivotPos(m), 3.5), pivotPos(m))
        else
            notify("Teleport", "No rocks loaded", 3)
        end
    end }):AddButton({ Text = "Nearest food", Func = function()
        local f = nearest(looseItems(isFood))
        if f then
            task.spawn(moveTo, besideOf(pivotPos(f), 3), pivotPos(f))
        end
    end })
end

-- Visuals
do
    local Tab = UI.Window:AddTab("Visuals", "eye", "ESP and lighting")
    local EspBox = Tab:AddLeftGroupbox("ESP", "scan-eye")
    toggle(EspBox, "EspMobs", "Employees (⚠ = chasing you)", "EspMobs")
    toggle(EspBox, "EspMinables", "Rocks (Scrap, Crystal)", "EspMinables")
    toggle(EspBox, "EspChests", "Chests and crates", "EspChests")
    toggle(EspBox, "EspShop", "Shop items and prices", "EspShop")
    toggle(EspBox, "EspFood", "Food", "EspFood")
    toggle(EspBox, "EspPlayers", "Players", "EspPlayers")
    slider(EspBox, "EspDistance", "Distance", "EspDistance", 50, 2000, " studs")
    local WorldBox = Tab:AddRightGroupbox("World", "sun")
    toggle(WorldBox, "Fullbright", "Fullbright", "Fullbright")
    toggle(WorldBox, "NoFog", "No fog", "NoFog")
end

--// Loops \\--
bind(RunService.Heartbeat, function(dt)
    if alive() then
        movementStep()
        flyStep(dt)
    end
end)
bind(RunService.RenderStepped, function()
    if alive() then
        fovStep()
    end
end)
bind(RunService.Stepped, function()
    if alive() then
        noclipStep()
    end
end)

loop(0.25, function()
    for _, fn in { eatTick, pickUpToolsTick, buyTick, nightMarketTick, chestTick, gemsTick, experienceTick, auraTick, safetyTick, reviveTick } do
        local ok, err = pcall(fn)
        if not ok then
            warn("[Outpost] " .. tostring(err))
        end
    end
end)
loop(0.4, function()
    updateEsp()
    lightingStep()
end)

-- Dashboard text, night market list.
local lastMarketCount = -1
loop(0.5, function()
    local day = Workspace:GetAttribute("day") or "?"
    local isDay = Workspace:GetAttribute("isDay")
    local left = Workspace:GetAttribute("timeRemaining") or 0
    setText(UI.DayLabel, ("%s %s · %d:%02d left\nBase level %s · upgrade $%s / $%s\nEmployees out: %d"):format(
        isDay and "Day" or "Night", tostring(day), left // 60, left % 60,
        tostring(Workspace:GetAttribute("level") or 0), tostring(Workspace:GetAttribute("currentCash") or 0),
        tostring(Workspace:GetAttribute("requiredCash") or "?"), #mobs()))
    local current, max = sackState()
    setText(UI.YouLabel, ("Cash $%d · hunger %d%%\nSack %d/%d · scrap %s · crystals %s"):format(
        State.cash, State.hunger, current, max, tostring(LocalPlayer:GetAttribute("scrap") or 0), tostring(LocalPlayer:GetAttribute("crystals") or 0)))
    setText(UI.JobLabel, Job.name and (Job.name .. ": " .. Job.status) or Job.status)
    setText(UI.LeftoverLabel, ("Leftovers lying around: %d"):format(#leftovers()))
    setText(UI.StatsLabel, ("This session: %s$%d · %d rocks · %d sold in %d trips"):format(
        (Stats.startCash and State.cash - Stats.startCash >= 0) and "+" or "", Stats.startCash and (State.cash - Stats.startCash) or 0,
        Stats.rocks, Stats.sold, Stats.trips))
    if #State.market ~= lastMarketCount then
        lastMarketCount = #State.market
        local names, lines = {}, {}
        for _, e in State.market do
            table.insert(names, e.item)
            table.insert(lines, ("%s $%d"):format(e.item, e.price))
        end
        UI.NightPicks:SetValues(names)
        UI.NightOne:SetValues(names)
        setText(UI.NightLabel, #lines > 0 and table.concat(lines, "\n") or "Not seen yet")
    end
end)

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    stopJob()
    if auraHolding then
        hold(auraHolding, false)
    end
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    table.clear(Connections)
    Settings.Fullbright, Settings.NoFog = false, false
    lightingStep()
    for p in noclipParts do
        if p.Parent then
            p.CanCollide = true
        end
    end
    local hum = humanoid()
    if hum and Settings.Speed then
        hum.WalkSpeed = 16
    end
    pcall(EspFolder.Destroy, EspFolder)
    if FovCircle then
        pcall(function()
            FovCircle:Remove()
        end)
    end
end
Library:OnUnload(cleanup)
Genv.__OutpostUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

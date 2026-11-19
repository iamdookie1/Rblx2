--// Dont Splash For Eggs ------------------------------------------------------------------------
-- place 87581667376056 (game 10774325480), built against version 729. Built on Ui3.
-- How the game works, from its own client scripts:
--   Eggs     Workspace.Zones.<biome>.Nests: parts named "Egg" (attributes Rarity 1-6,
--            Biome, Species, Size, Kg, Mutation; Taken once someone has it). You pick
--            one up by touching it (player attribute Carrying = its rarity), carry it to
--            your pen (Map.Bases.Base<n> with OwnerId = you; InMyPen when you're in it)
--            and plant it with Remotes.DropEgg. GameConfig.EggValue(biome, rarity, size,
--            mutation, species) is what the pet will earn a second.
--   Splash   The "you splashed" report comes from your own client: the WaterSense
--            LocalScript fires Remotes.WaterSense while you're below a Water part's
--            surface. That's what wakes a biome's guardians (Zones.<biome>.Monster).
--   Fling    A guardian (or a bat) hitting you: Remotes.Fling sends a velocity and your
--            own client ragdolls you (GameClient), Unragdoll gets you up.
--   Combo    Your own client reports each landing after a jump: Combo("land", part)
--            (ComboClient, after 0.24 s in the air). The server keeps the count
--            (ComboCount, ComboEnd 5 s ahead, ComboCash) and answers "land", "bank"
--            (paid out when the timer runs out), "lost" (broken) and "why" (a landing
--            that didn't count, with the reason). Config: MinHop 6 studs between
--            landings, a platform can't count again for PlatformCooldown 10 s.
--   Tricks   Combo("trick", id) in the air (TrickClient), points and flip coins.
--   Steal    Other pens' eggs have a "Steal Egg" prompt: StealHold(egg, "begin"), then
--            after its HoldDuration StealHold(egg, "done").
--   Base     Decks.CollectPad (touch to collect), SquatArea.Mat (stand on it to squat:
--            Training), TreasureChest.OpenAnchor.OpenPrompt, Decks.UpgradeBoard clicks.
--   Remotes  Purchase("barbell", 1), Rebirth("do"), PetAction("equipBest" / "list" /
--            "sellMany", uids), SpinWheel("spin"), FreeGift("claim"), Rewards("daily" /
--            "play", i), Journey("claim"), QuestCall("accept"), ShopAction("claimIndex"),
--            GearShop("buy", id / "use", id); you own what's in the GearOwn attribute.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__EggsUnload then
    pcall(Genv.__EggsUnload)
end
Genv.__EggsRun = (Genv.__EggsRun or 0) + 1
local RUN = Genv.__EggsRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__EggsRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local RARITY_NAMES = { "Common", "Rare", "Hyper Rare", "Legendary", "Eternal", "Transcendent" }
local GEAR_BUY = { "Pebbles", "SplashShield", "GhostCloak", "Incubator5", "Incubator10", "Incubator25", "Incubator50", "GrowthPotion",
    "CashPotion", "SquatPotion", "TokenPotion", "ComboClock", "ComboSaver", "InstantExtract", "SizeModifier" }

local Settings = {
    -- eggs
    EggFarm = false, EggMinRarity = "Common", EggPick = "Best value", EggBiomes = {}, GrabDropped = true, AutoPlant = true,
    MoveMethod = "Teleport", FlySpeed = 160,
    -- steal
    StealAura = false, StealTravel = false, StealMinRarity = "Rare",
    -- safety
    NoSplash = true, WalkOnWater = true, AntiFling = true, RunFromGuardians = false, RunRange = 25,
    AutoCloak = false, AutoPebbles = false,
    -- combo
    InfCombo = false, ComboMethod = "Teleport hop", ComboRate = 3, ComboBankAt = 0, AutoTricks = false,
    -- base
    AutoCollect = false, CollectEvery = 5, AutoTrain = false, AutoBarbell = false, AutoRebirth = false, AutoEquipBest = false,
    AutoSell = false, SellUpTo = "Common", AutoPenUpgrade = false, AutoTreasure = false,
    -- rewards
    AutoSpin = false, AutoGift = false, AutoDaily = false, AutoPlaytime = false, AutoJourney = false, AutoQuests = false, AutoIndex = false,
    AutoBuyGear = false, GearBuyList = {}, AutoPotions = false, AutoIncubators = false,
    -- esp
    EspEggs = false, EspMinRarity = "Common", EspGuardians = false, EspDropped = false, EspSteal = false, EspPlayers = false, EspDistance = 3000,
    -- player
    SpeedOn = false, WalkSpeed = 30, JumpOn = false, JumpPower = 90, InfJump = false, Fly = false, FlyMoveSpeed = 80, Noclip = false,
    AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
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
                warn("[Eggs] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Eggs", Description = text, Time = seconds or 3 })
end
local function comma(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end
local Tried = {}
local function tryOnce(key, every)
    local t = Tried[key]
    if t and os.clock() - t < every then
        return false
    end
    Tried[key] = os.clock()
    return true
end
local function myChar()
    return LocalPlayer.Character
end
local function myRoot()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function myHum()
    local c = myChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function attr(name)
    return LocalPlayer:GetAttribute(name)
end
local function pivotOf(inst)
    if not (inst and inst.Parent) then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.Position
    end
    local ok, cf = pcall(inst.GetPivot, inst)
    return ok and cf.Position or nil
end
local function rarityIndex(name)
    return table.find(RARITY_NAMES, name) or 1
end
local function touch(part)
    local root = myRoot()
    if not (root and part and part.Parent) or typeof(firetouchinterest) ~= "function" then
        return false
    end
    pcall(firetouchinterest, root, part, 0)
    task.defer(pcall, firetouchinterest, root, part, 1)
    return true
end

--// The game \\--
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end
local function fire(name, ...)
    local r = remote(name)
    if r and r:IsA("RemoteEvent") then
        r:FireServer(...)
        return true
    end
    return false
end
local function call(name, ...)
    local r = remote(name)
    if not (r and r:IsA("RemoteFunction")) then
        return nil
    end
    local ok, res = pcall(r.InvokeServer, r, ...)
    return ok and res or nil
end
local Config
do
    local shared = ReplicatedStorage:WaitForChild("Shared", 10)
    local m = shared and shared:FindFirstChild("GameConfig")
    local ok, r = pcall(function()
        return m and require(m)
    end)
    Config = (ok and type(r) == "table") and r or {}
    if type(Config.Rarities) == "table" then
        for i, r2 in Config.Rarities do
            if type(r2) == "table" and r2.Name then
                RARITY_NAMES[i] = r2.Name
            end
        end
    end
end
local function rarityColor(i)
    local r = Config.Rarities and Config.Rarities[i]
    return (r and r.Color) or Color3.fromRGB(240, 240, 240)
end

local Game = {}
function Game.zones()
    local z = Workspace:FindFirstChild("Zones")
    return z and z:GetChildren() or {}
end
function Game.zoneNamed(name)
    local z = Workspace:FindFirstChild("Zones")
    return z and z:FindFirstChild(name)
end
function Game.zoneAt(pos)
    for _, z in Game.zones() do
        local s, e = z:GetAttribute("ZStart"), z:GetAttribute("ZEnd")
        if s and e and pos.Z <= s + 40 and pos.Z >= e then
            return z
        end
    end
    return nil
end
function Game.zoneCenter(z)
    local s, e = z:GetAttribute("ZStart"), z:GetAttribute("ZEnd")
    if s and e then
        return Vector3.new(0, 62, (s + e) / 2)
    end
    return pivotOf(z)
end
function Game.myBase()
    local map = Workspace:FindFirstChild("Map")
    local bases = map and map:FindFirstChild("Bases")
    for _, b in bases and bases:GetChildren() or {} do
        if b:GetAttribute("OwnerId") == LocalPlayer.UserId then
            return b
        end
    end
    local idx = attr("BaseIndex")
    return idx and bases and bases:FindFirstChild("Base" .. idx) or nil
end
function Game.penSpot()
    local base = Game.myBase()
    local floor = base and (base:FindFirstChild("Floor") or base:FindFirstChild("InnerFloor"))
    if floor and floor:IsA("BasePart") then
        return floor.Position + Vector3.new(0, floor.Size.Y / 2 + 3, 0)
    end
    return base and pivotOf(base) or nil
end
function Game.carrying()
    return attr("Carrying") ~= nil
end
function Game.gearOwned()
    local raw = attr("GearOwn")
    local ok, t = pcall(HttpService.JSONDecode, HttpService, raw or "{}")
    local out = {}
    if ok and type(t) == "table" then
        for k, v in t do
            if type(k) == "string" then
                out[k] = tonumber(v) or (v and 1 or 0)
            elseif type(v) == "table" and v.Id then
                out[v.Id] = tonumber(v.Count) or 1
            elseif type(v) == "string" then
                out[v] = (out[v] or 0) + 1
            end
        end
    end
    return out
end
function Game.useGear(id)
    local r = call("GearShop", "use", id)
    return type(r) == "table" and r.ok
end
-- Asks the server to send an area (the map streams).
function Game.stream(pos, timeout)
    pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, pos, timeout or 1)
end

--// Moving \\--
local Move = { busy = false }
do
    -- Teleport, or fly in a straight line at FlySpeed (held every frame, so nothing
    -- trips you on the way). Returns false if `still` stopped it.
    function Move.to(pos, still)
        local root = myRoot()
        if not (root and pos) then
            return false
        end
        if Settings.MoveMethod == "Teleport" then
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.new(pos) * root.CFrame.Rotation
            return true
        end
        local from = root.Position
        local dist = (pos - from).Magnitude
        local t, total = 0, dist / math.max(Settings.FlySpeed, 10)
        while t < total do
            if still and not still() then
                return false
            end
            local r = myRoot()
            if not r then
                return false
            end
            t += RunService.Heartbeat:Wait()
            local p = from:Lerp(pos, math.min(t / total, 1))
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(p) * r.CFrame.Rotation
        end
        return true
    end
    -- Stay at `pos` for `seconds` (or until done()), holding the spot.
    function Move.hold(pos, seconds, done, still)
        local t0 = os.clock()
        while os.clock() - t0 < seconds do
            if still and not still() then
                return false
            end
            if done and done() then
                return true
            end
            local r = myRoot()
            if r then
                r.AssemblyLinearVelocity = Vector3.zero
                r.CFrame = CFrame.new(pos) * r.CFrame.Rotation
            end
            RunService.Heartbeat:Wait()
        end
        return done and done() or false
    end
end

--// Jobs: one thing that moves you at a time \\--
local Job = { name = nil, token = 0, info = "Idle" }
local function stopJob(reason)
    Job.token += 1
    Job.name = nil
    Job.info = reason or "Idle"
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
            warn("[Eggs] " .. name .. ": " .. tostring(err))
            Job.info = name .. " stopped: " .. tostring(err)
        end
        if Job.token == token then
            Job.name = nil
        end
    end)
end

--// Safety: no splash, walk on water, anti-fling \\--
do
    -- No splash: the WaterSense script is the only thing that tells the server you're
    -- in the water. Switched off, the guardians never hear a splash.
    local sense
    local function waterSense()
        if sense and sense.Parent then
            return sense
        end
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        sense = ps and ps:FindFirstChild("WaterSense")
        return sense
    end
    local blocked = false
    local hooked = false
    local function setSense(on)
        local s = waterSense()
        if s then
            pcall(function()
                s.Enabled = on
            end)
            pcall(function()
                s.Disabled = not on
            end)
        end
    end
    -- If the script can't be switched off, its remote is blocked instead.
    local function hookSense()
        if hooked or typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then
            return
        end
        local r = remote("WaterSense")
        if not r then
            return
        end
        hooked = true
        local old
        old = hookmetamethod(game, "__namecall", function(self, ...)
            if self == r and blocked and not Unloaded then
                local m = getnamecallmethod()
                if m == "FireServer" then
                    return nil
                end
            end
            return old(self, ...)
        end)
    end
    local function senseOn(s)
        local ok, on = pcall(function()
            return s.Enabled
        end)
        return ok and on ~= false
    end
    loop(1, function()
        local s = waterSense()
        if Settings.NoSplash then
            blocked = true
            -- (also catches the script loading late or the game turning it back on)
            if s and senseOn(s) then
                setSense(false)
                if senseOn(s) then
                    hookSense()
                end
            elseif not s then
                hookSense()
            end
        elseif blocked then
            blocked = false
            setSense(true)
        end
    end)
    table.insert(Cleanups, function()
        blocked = false
        setSense(true)
    end)

    -- Walk on water: every Water part is solid for you (only on your side), so you
    -- stand on it instead of sinking and slowing down.
    local solid = {}
    local function waterParts()
        local list = {}
        for _, z in Game.zones() do
            local w = z:FindFirstChild("Water")
            for _, p in w and w:GetDescendants() or {} do
                if p:IsA("BasePart") and p.Name == "Water" then
                    table.insert(list, p)
                end
            end
        end
        return list
    end
    loop(1.5, function()
        if Settings.WalkOnWater then
            for _, p in waterParts() do
                if solid[p] == nil then
                    solid[p] = p.CanCollide
                    p.CanCollide = true
                end
            end
        elseif next(solid) then
            for p, was in solid do
                pcall(function()
                    p.CanCollide = was
                end)
            end
            table.clear(solid)
        end
    end)
    table.insert(Cleanups, function()
        for p, was in solid do
            pcall(function()
                p.CanCollide = was
            end)
        end
    end)

    -- Anti-fling: the game's handler that throws and ragdolls you is switched off.
    local flingOff = {}
    loop(1, function()
        local r = remote("Fling")
        if not (r and typeof(getconnections) == "function") then
            return
        end
        if Settings.AntiFling then
            for _, c in getconnections(r.OnClientEvent) do
                if not flingOff[c] then
                    local fn = c.Function
                    local src = fn and type(debug) == "table" and debug.info and select(2, pcall(debug.info, fn, "s"))
                    if tostring(src):find("GameClient", 1, true) and pcall(c.Disable, c) then
                        flingOff[c] = true
                    end
                end
            end
        elseif next(flingOff) then
            for c in flingOff do
                pcall(c.Enable, c)
            end
            table.clear(flingOff)
        end
        -- and if it got you anyway, up you get
        local hum = myHum()
        if Settings.AntiFling and hum and hum.PlatformStand and not attr("Training") then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end)
    table.insert(Cleanups, function()
        for c in flingOff do
            pcall(c.Enable, c)
        end
    end)
end

--// Guardians \\--
local Guard = { nearest = nil, nearestD = nil }
function Guard.list()
    local out = {}
    for _, z in Game.zones() do
        local m = z:FindFirstChild("Monster")
        for _, g in m and m:GetChildren() or {} do
            if g:IsA("Model") then
                table.insert(out, g)
            end
        end
    end
    return out
end
function Guard.chasingMe()
    return attr("ChasedBy") ~= nil or attr("HuntedBy") ~= nil
end
loop(0.25, function()
    local root = myRoot()
    Guard.nearest, Guard.nearestD = nil, nil
    if not root then
        return
    end
    for _, g in Guard.list() do
        local p = pivotOf(g)
        if p then
            local d = (p - root.Position).Magnitude
            if not Guard.nearestD or d < Guard.nearestD then
                Guard.nearest, Guard.nearestD = g, d
            end
        end
    end
    local danger = Guard.chasingMe() or (Guard.nearestD and Guard.nearestD < Settings.RunRange and Guard.nearest:GetAttribute("Chasing"))
    if danger then
        if Settings.AutoCloak and (Game.gearOwned().GhostCloak or 0) > 0 and tryOnce("cloak", 5) then
            Game.useGear("GhostCloak")
        end
        if Settings.AutoPebbles and (Game.gearOwned().Pebbles or 0) > 0 and tryOnce("pebble", 3) then
            Game.useGear("Pebbles")
        end
        if Settings.RunFromGuardians and Job.name ~= "Inf combo" and tryOnce("run", 2) then
            local spot = Game.penSpot()
            if spot then
                Move.to(spot)
            end
        end
    end
end)

--// Eggs \\--
local Eggs = { info = "Off", planted = 0, grabbed = 0, skip = setmetatable({}, { __mode = "k" }) }
function Eggs.value(part, zoneName)
    local r = tonumber(part:GetAttribute("Rarity")) or 1
    if type(Config.EggValue) == "function" then
        local ok, v = pcall(Config.EggValue, part:GetAttribute("Biome") or zoneName, r, part:GetAttribute("Size"),
            part:GetAttribute("Mutation"), part:GetAttribute("Species"))
        if ok and tonumber(v) then
            return tonumber(v)
        end
    end
    return tonumber(part:GetAttribute("Income")) or ((Config.Rarities and Config.Rarities[r] and Config.Rarities[r].Income) or r)
end
-- Every egg nobody has: in the nests, and (optionally) dropped ones.
function Eggs.list(includeDropped)
    local out = {}
    for _, z in Game.zones() do
        local nests = z:FindFirstChild("Nests")
        for _, d in nests and nests:GetDescendants() or {} do
            if d.Name == "Egg" and d:IsA("BasePart") and not d:GetAttribute("Taken") then
                table.insert(out, { part = d, zone = z.Name, dropped = false })
            end
        end
    end
    if includeDropped then
        local dropped = Workspace:FindFirstChild("DroppedEggs")
        for _, d in dropped and dropped:GetDescendants() or {} do
            if d:IsA("BasePart") and (d.Name == "Egg" or d:GetAttribute("Rarity")) and not d:GetAttribute("Taken") then
                local z = Game.zoneAt(d.Position)
                table.insert(out, { part = d, zone = z and z.Name or "Park", dropped = true })
            end
        end
    end
    return out
end
function Eggs.best()
    local root = myRoot()
    if not root then
        return nil
    end
    local min = rarityIndex(Settings.EggMinRarity)
    local anyBiome = next(Settings.EggBiomes) == nil
    local best, bestScore
    for _, e in Eggs.list(Settings.GrabDropped) do
        local r = tonumber(e.part:GetAttribute("Rarity")) or 1
        if not Eggs.skip[e.part] and (r >= min or e.dropped) and (anyBiome or Settings.EggBiomes[e.zone]) then
            local d = (e.part.Position - root.Position).Magnitude
            local v = Eggs.value(e.part, e.zone)
            local score
            if Settings.EggPick == "Nearest" then
                score = -d
            elseif Settings.EggPick == "Rarest" then
                score = r * 1e9 + v - d * 1e-3
            else
                score = v - d * 1e-4
            end
            if e.dropped then
                score += 1e12 -- free, and gone in 15 s
            end
            if not bestScore or score > bestScore then
                best, bestScore = e, score
            end
        end
    end
    return best
end
-- Carry the egg you have to your pen and plant it.
function Eggs.plant(still)
    if not Game.carrying() then
        return true
    end
    local spot = Game.penSpot()
    if not spot then
        Eggs.info = "Couldn't find your pen"
        return false
    end
    Eggs.info = "Taking the egg to your pen"
    if not Move.to(spot, still) then
        return false
    end
    Move.hold(spot, 3, function()
        return attr("InMyPen") == true
    end, still)
    local t0 = os.clock()
    while Game.carrying() and os.clock() - t0 < 4 do
        if still and not still() then
            return false
        end
        if tryOnce("dropEgg", 0.6) then
            fire("DropEgg")
        end
        local r = myRoot()
        if r then
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(spot) * r.CFrame.Rotation
        end
        RunService.Heartbeat:Wait()
    end
    if Game.carrying() then
        Eggs.info = "The pen didn't take it (full?). Make room or hatch some"
        return false
    end
    Eggs.planted += 1
    return true
end
-- Go get one egg.
function Eggs.grab(e, still)
    local part = e.part
    local spot = part.Position + Vector3.new(0, 2.5, 0)
    Eggs.info = ("Going for a %s egg in %s"):format(RARITY_NAMES[tonumber(part:GetAttribute("Rarity")) or 1] or "?", e.zone)
    if not Move.to(spot, still) then
        return false
    end
    local got = Move.hold(spot, 2.5, function()
        if part.Parent and tryOnce("touchEgg", 0.2) then
            touch(part)
        end
        return Game.carrying()
    end, still)
    if got then
        Eggs.grabbed += 1
    else
        Eggs.skip[part] = true
        task.delay(20, function()
            Eggs.skip[part] = nil
        end)
    end
    return got
end
function Eggs.farm(still)
    local lastStream, zoneI = 0, 0
    while still() do
        if Game.carrying() then
            if not Eggs.plant(still) then
                if not still() then
                    return
                end
                task.wait(3)
            end
        else
            local e = Eggs.best()
            if e then
                Eggs.grab(e, still)
            else
                -- nothing loaded: ask the server for the next biome
                local zones = Game.zones()
                if #zones > 0 and os.clock() - lastStream > 0.5 then
                    lastStream = os.clock()
                    zoneI = zoneI % #zones + 1
                    local c = Game.zoneCenter(zones[zoneI])
                    if c then
                        Eggs.info = "Looking for eggs in " .. zones[zoneI].Name
                        Game.stream(c, 1)
                    end
                end
                task.wait(0.3)
            end
        end
        task.wait(0.05)
    end
end
-- Plant on its own whenever you walk into your pen with an egg.
loop(0.5, function()
    if Settings.AutoPlant and Game.carrying() and attr("InMyPen") == true and tryOnce("autoPlant", 1) then
        fire("DropEgg")
    end
end)

--// Steal \\--
local Steal = { prompts = {}, info = "Off", stolen = 0 }
do
    local function track(d)
        if d:IsA("ProximityPrompt") and d.ActionText == "Steal Egg" then
            Steal.prompts[d] = true
        end
    end
    for _, d in Workspace:GetDescendants() do
        track(d)
    end
    bind(Workspace.DescendantAdded, track)
    bind(Workspace.DescendantRemoving, function(d)
        Steal.prompts[d] = nil
    end)
end
function Steal.targets()
    local out = {}
    local min = rarityIndex(Settings.StealMinRarity)
    local mine = Game.myBase()
    for p in Steal.prompts do
        local egg = p.Parent
        if p.Enabled and egg and egg:IsA("BasePart") and egg:IsDescendantOf(Workspace) and not (mine and egg:IsDescendantOf(mine)) then
            local r = tonumber(egg:GetAttribute("Rarity")) or 1
            if r >= min then
                table.insert(out, { prompt = p, egg = egg, r = r })
            end
        end
    end
    table.sort(out, function(a, b)
        return a.r > b.r
    end)
    return out
end
function Steal.take(t, still)
    local egg = t.egg
    local hold = (tonumber(t.prompt.HoldDuration) or 1) + 0.1
    fire("StealHold", egg, "begin")
    local root = myRoot()
    local near = root and (root.Position - egg.Position).Magnitude <= t.prompt.MaxActivationDistance
    local spot = near and root.Position or (egg.Position + Vector3.new(0, 3, 0))
    Move.hold(spot, hold, nil, still)
    if still and not still() then
        fire("StealHold", egg, "cancel")
        return false
    end
    fire("StealHold", egg, "done")
    local got = Move.hold(myRoot() and myRoot().Position or spot, 1.5, Game.carrying, still)
    if got then
        Steal.stolen += 1
    end
    return got
end
loop(0.3, function()
    if not Settings.StealAura or Game.carrying() or Job.name then
        return
    end
    local root = myRoot()
    if not root then
        return
    end
    for _, t in Steal.targets() do
        if (t.egg.Position - root.Position).Magnitude <= t.prompt.MaxActivationDistance then
            Steal.info = "Stealing a " .. (RARITY_NAMES[t.r] or "?") .. " egg"
            Steal.take(t)
            return
        end
    end
end)
function Steal.run(still)
    while still() do
        if Game.carrying() then
            if not Eggs.plant(still) then
                task.wait(3)
            end
        else
            local t = Steal.targets()[1]
            if t then
                Steal.info = ("Going to steal a %s egg"):format(RARITY_NAMES[t.r] or "?")
                if Move.to(t.egg.Position + Vector3.new(0, 3, 0), still) then
                    Steal.take(t, still)
                end
            else
                Steal.info = "No eggs to steal right now"
                task.wait(1)
            end
        end
        task.wait(0.1)
    end
end

--// Inf combo \\--
-- Hops platform to platform: each landing at least 6 studs from the last, no
-- platform again within 10 s, never longer than the 5 s timer between landings,
-- never touching water (no splash keeps the guardians away too). Three ways:
--   Teleport hop:  put you on the next platform and report the landing,
--   Real fall:     drop you onto it from 12 studs up so the game reports it itself,
--   Report only:   report landings without moving you at all (if the server takes it).
-- It watches what the server says back ("why" a landing didn't count) and moves to
-- a slower way by itself when a faster one isn't counted.
local Combo = { info = "Off", why = "-", landed = 0, sent = 0, banked = 0, lastBank = 0, lost = 0, best = 0 }
do
    local r = remote("Combo")
    if r and r:IsA("RemoteEvent") then
        bind(r.OnClientEvent, function(kind, data)
            data = type(data) == "table" and data or {}
            if kind == "land" then
                Combo.landed += 1
                Combo.best = math.max(Combo.best, tonumber(data.Count) or 0)
            elseif kind == "why" then
                Combo.why = tostring(data.Text or "?")
            elseif kind == "bank" then
                Combo.banked += 1
                Combo.lastBank = tonumber(data.Cash) or 0
            elseif kind == "lost" then
                Combo.lost += 1
            end
        end)
    end
end
local function platformsIn(zone)
    local out = {}
    local pf = zone and zone:FindFirstChild("Platforms")
    for _, d in pf and pf:GetDescendants() or {} do
        if d:IsA("Model") and d.Name == "Platform" then
            local part, size = nil, 0
            for _, p in d:GetDescendants() do
                if p:IsA("BasePart") and p.CanCollide and p.Transparency < 1 then
                    local s = p.Size.X * p.Size.Z
                    if s > size then
                        part, size = p, s
                    end
                end
            end
            part = part or d:FindFirstChildWhichIsA("BasePart", true)
            if part and not d:GetAttribute("Vanish") then
                local ok, cf, sz = pcall(d.GetBoundingBox, d)
                local top = ok and (cf.Position + Vector3.new(0, sz.Y / 2, 0)) or (part.Position + Vector3.new(0, part.Size.Y / 2, 0))
                table.insert(out, { model = d, part = part, top = top })
            end
        end
    end
    -- in order along the biome, so each hop is short but more than 6 studs
    table.sort(out, function(a, b)
        return a.top.Z > b.top.Z
    end)
    local spaced, last = {}, nil
    for _, p in out do
        if not last or (p.top - last.top).Magnitude >= 6.5 then
            table.insert(spaced, p)
            last = p
        end
    end
    return spaced
end
function Combo.run(still)
    local root = myRoot()
    if not root then
        return
    end
    -- the biome you're in, else the nearest one with enough platforms
    local zone = Game.zoneAt(root.Position)
    local plats = zone and platformsIn(zone) or {}
    if #plats < 4 then
        local bestZ, bestD
        for _, z in Game.zones() do
            local c = Game.zoneCenter(z)
            if c then
                local d = (c - root.Position).Magnitude
                if (not bestD or d < bestD) and #platformsIn(z) >= 4 then
                    bestZ, bestD = z, d
                end
            end
        end
        zone = bestZ
        plats = zone and platformsIn(zone) or {}
    end
    if #plats < 4 then
        Combo.info = "No biome with platforms loaded near you: walk into one first"
        return
    end
    local methods = { "Report only", "Teleport hop", "Real fall" }
    local mi = table.find(methods, Settings.ComboMethod) or 2
    local i = 0
    local lastLand = 0
    local tries, landedAt = 0, Combo.landed
    local rem = remote("Combo")
    while still() do
        local count = tonumber(attr("ComboCount")) or 0
        -- bank: stop landing until the timer runs out and the combo pays
        if Settings.ComboBankAt > 0 and count >= Settings.ComboBankAt then
            Combo.info = ("Banking x%d..."):format(count)
            local spot = plats[1].top + Vector3.new(0, 3, 0)
            Move.hold(spot, 6.5, function()
                return (tonumber(attr("ComboCount")) or 0) == 0
            end, still)
        else
            -- one platform each step, spaced so none comes back inside 10.5 s
            local gap = math.max(1 / math.max(Settings.ComboRate, 0.5), 10.6 / #plats, 0.33)
            i = i % #plats + 1
            local p = plats[i]
            local method = methods[mi]
            if p.model.Parent and p.part.Parent then
                if method == "Report only" then
                    if rem then
                        rem:FireServer("land", p.part)
                    end
                    Combo.sent += 1
                    lastLand = os.clock()
                    task.wait(gap)
                elseif method == "Teleport hop" then
                    local spot = p.top + Vector3.new(0, 3, 0)
                    Move.hold(spot, 0.12, nil, still)
                    local wait = 0.31 - (os.clock() - lastLand)
                    if wait > 0 then
                        Move.hold(spot, wait, nil, still)
                    end
                    if rem then
                        rem:FireServer("land", p.part)
                    end
                    Combo.sent += 1
                    lastLand = os.clock()
                    Move.hold(spot, math.max(gap - 0.12, 0.02), nil, still)
                else
                    -- dropped from above: the game sees a real landing and reports it
                    local r = myRoot()
                    if r then
                        r.AssemblyLinearVelocity = Vector3.zero
                        r.CFrame = CFrame.new(p.top + Vector3.new(0, 12, 0))
                    end
                    local hum = myHum()
                    local t0 = os.clock()
                    repeat
                        RunService.Heartbeat:Wait()
                    until not still() or (hum and hum.FloorMaterial ~= Enum.Material.Air and os.clock() - t0 > 0.2) or os.clock() - t0 > 1.2
                    Combo.sent += 1
                    lastLand = os.clock()
                    task.wait(math.max(gap - (os.clock() - t0), 0.05))
                end
            end
            -- not being counted? step down to a slower, more real way
            tries += 1
            if tries >= 10 then
                if Combo.landed == landedAt and mi < #methods then
                    mi += 1
                    Combo.why ..= " → trying " .. methods[mi]
                end
                tries, landedAt = 0, Combo.landed
            end
            Combo.info = ("%s · x%d · +$%s waiting · %d counted of %d"):format(methods[mi], count, comma(attr("ComboCash")), Combo.landed, Combo.sent)
        end
    end
end

-- Auto tricks: in the air, chains the best tricks that fit before you land.
do
    local TRICKS = {}
    for _, t in (Config.Tricks and Config.Tricks.List) or {} do
        if type(t) == "table" and t.Id and t.Dur and t.Pts and not tostring(t.Id):find("^Dir") then
            table.insert(TRICKS, t)
        end
    end
    table.sort(TRICKS, function(a, b)
        return a.Pts / a.Dur > b.Pts / b.Dur
    end)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local takeoff, busyUntil, chain = nil, 0, 0
    local function timeToGround(root)
        params.FilterDescendantsInstances = { myChar() }
        local hit = Workspace:Raycast(root.Position, Vector3.new(0, -200, 0), params)
        if not hit then
            return 0
        end
        local hum = myHum()
        local h = root.Position.Y - hit.Position.Y - (hum and hum.HipHeight or 2) - root.Size.Y / 2
        local vy, g = root.AssemblyLinearVelocity.Y, Workspace.Gravity
        if h <= 0 then
            return 0
        end
        return (vy + math.sqrt(math.max(vy * vy + 2 * g * h, 0))) / g
    end
    bind(RunService.Heartbeat, function()
        if not (alive() and Settings.AutoTricks) or Job.name == "Inf combo" then
            takeoff = nil
            return
        end
        local hum, root = myHum(), myRoot()
        if not (hum and root) or attr("Training") or attr("Ragdoll") then
            return
        end
        if hum.FloorMaterial ~= Enum.Material.Air then
            takeoff, chain = nil, 0
            return
        end
        takeoff = takeoff or os.clock()
        local now = os.clock()
        local min = (Config.Tricks and Config.Tricks.MinAir) or 0.07
        if now - takeoff < min + 0.02 or now < busyUntil or chain >= ((Config.Tricks and Config.Tricks.MaxPerJump) or 8) then
            return
        end
        local left = timeToGround(root)
        for _, t in TRICKS do
            if t.Dur + 0.1 <= left then
                fire("Combo", "trick", t.Id)
                chain += 1
                busyUntil = now + t.Dur + ((Config.Tricks and Config.Tricks.Gap) or 0.04) + 0.02
                return
            end
        end
    end)
end

--// Base \\--
local Base = { info = "-", collected = 0 }
loop(function()
    return math.max(Settings.CollectEvery, 1)
end, function()
    if not Settings.AutoCollect then
        return
    end
    local base = Game.myBase()
    local decks = base and base:FindFirstChild("Decks")
    for _, pad in decks and decks:GetChildren() or {} do
        if pad.Name == "CollectPad" and pad:IsA("BasePart") then
            if touch(pad) then
                Base.collected += 1
            end
            task.wait(0.05)
        end
    end
end)
-- Auto train: stands you on your squat mat whenever nothing else needs you.
loop(1, function()
    if not Settings.AutoTrain or Job.name or Game.carrying() or attr("Training") then
        return
    end
    local base = Game.myBase()
    local area = base and base:FindFirstChild("SquatArea")
    local mat = area and area:FindFirstChild("Mat")
    if not (mat and mat:IsA("BasePart")) then
        return
    end
    local root = myRoot()
    if not root then
        return
    end
    if (root.Position - mat.Position).Magnitude > 4 then
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(mat.Position + Vector3.new(0, mat.Size.Y / 2 + 3, 0))
    end
    touch(mat)
end)
loop(3, function()
    local cash = tonumber(attr("Cash")) or 0
    if Settings.AutoBarbell and cash >= (tonumber(attr("NextBarbellCost")) or math.huge) and tryOnce("barbell", 4) then
        call("Purchase", "barbell", 1)
    end
    if Settings.AutoRebirth and tryOnce("rebirth", 15) then
        call("Rebirth", "do")
    end
    if Settings.AutoEquipBest and tryOnce("equipBest", 30) then
        call("PetAction", "equipBest")
    end
    if Settings.AutoSell and tryOnce("sell", 20) then
        local list = call("PetAction", "list")
        local pets = type(list) == "table" and (list.Pets or list.pets or list) or {}
        local max = rarityIndex(Settings.SellUpTo)
        local uids = {}
        for _, p in type(pets) == "table" and pets or {} do
            if type(p) == "table" and p.Uid and not p.Fav and not p.Placed and not p.Equipped and not p.Active
                and (tonumber(p.Rarity) or 99) <= max then
                table.insert(uids, p.Uid)
            end
        end
        if #uids > 0 then
            call("PetAction", "sellMany", uids)
            Base.info = ("Sold %d pets"):format(#uids)
        end
    end
    if Settings.AutoPenUpgrade and typeof(fireclickdetector) == "function" and tryOnce("pen", 6) then
        local base = Game.myBase()
        local decks = base and base:FindFirstChild("Decks")
        for _, b in decks and decks:GetChildren() or {} do
            local cd = b.Name == "UpgradeBoard" and b:FindFirstChildOfClass("ClickDetector")
            if cd then
                pcall(fireclickdetector, cd)
                task.wait(0.1)
            end
        end
    end
    if Settings.AutoTreasure and not Job.name and tryOnce("treasure", 20) then
        local base = Game.myBase()
        local chest = base and base:FindFirstChild("TreasureChest")
        local anchor = chest and chest:FindFirstChild("OpenAnchor")
        local prompt = anchor and anchor:FindFirstChildOfClass("ProximityPrompt")
        if prompt and prompt.Enabled and typeof(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, prompt)
        end
    end
end)

--// Rewards \\--
local Rewards = { info = "-", n = 0 }
loop(5, function()
    if Settings.AutoSpin and (tonumber(attr("SpinFree")) or 0) > 0 and tryOnce("spin", 8) then
        local r = call("SpinWheel", "spin")
        if r then
            Rewards.n += 1
            Rewards.info = "Spun the wheel"
        end
    end
    if Settings.AutoGift and attr("GiftClaimed") ~= true and tryOnce("gift", 30) then
        call("FreeGift", "claim")
    end
    if Settings.AutoDaily and tryOnce("daily", 120) then
        call("Rewards", "daily")
    end
    if Settings.AutoPlaytime and tryOnce("play", 60) then
        for i = 1, 12 do
            call("Rewards", "play", i)
        end
    end
    if Settings.AutoJourney and (tonumber(attr("JourneyHave")) or 0) >= (tonumber(attr("JourneyNeed")) or math.huge) and tryOnce("journey", 5) then
        fire("Journey", "claim")
        Rewards.n += 1
        Rewards.info = "Journey: " .. tostring(attr("JourneyReward") or "claimed")
    end
    if Settings.AutoQuests and tryOnce("quest", 30) then
        call("QuestCall", "accept")
    end
    if Settings.AutoIndex and tryOnce("index", 60) then
        call("ShopAction", "claimIndex")
    end
    if Settings.AutoBuyGear and tryOnce("gearbuy", 30) then
        for id, on in Settings.GearBuyList do
            if on then
                call("GearShop", "buy", id)
                task.wait(0.2)
            end
        end
    end
    local own = (Settings.AutoPotions or Settings.AutoIncubators) and Game.gearOwned() or {}
    if Settings.AutoPotions then
        for _, id in { "CashPotion", "SquatPotion", "GrowthPotion", "TokenPotion" } do
            if (own[id] or 0) > 0 and tryOnce("use" .. id, 60) then
                Game.useGear(id)
            end
        end
    end
    if Settings.AutoIncubators then
        for _, id in { "Incubator50", "Incubator25", "Incubator10", "Incubator5" } do
            if (own[id] or 0) > 0 and tryOnce("use" .. id, 10) then
                Game.useGear(id)
                break
            end
        end
    end
end)

--// Player \\--
do
    local orig = {}
    local flyBody
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        local hum, root = myHum(), myRoot()
        if not (hum and root) then
            return
        end
        if Settings.SpeedOn and not attr("Training") then
            orig.ws = orig.ws or hum.WalkSpeed
            hum.WalkSpeed = Settings.WalkSpeed
        elseif orig.ws then
            hum.WalkSpeed = tonumber(attr("WalkSpeed")) or orig.ws
            orig.ws = nil
        end
        if Settings.JumpOn then
            orig.jp = orig.jp or hum.JumpPower
            hum.UseJumpPower = true
            hum.JumpPower = Settings.JumpPower
        elseif orig.jp then
            hum.JumpPower = tonumber(attr("JumpPower")) or orig.jp
            orig.jp = nil
        end
        if Settings.Fly and not Job.name then
            local cam = Workspace.CurrentCamera
            local dir = hum.MoveDirection
            local up = (UserInputService:IsKeyDown(Enum.KeyCode.Space) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) and 1 or 0)
            local v = dir * Settings.FlyMoveSpeed + Vector3.new(0, up * Settings.FlyMoveSpeed, 0)
            if cam and dir.Magnitude > 0 then
                local look = cam.CFrame.LookVector
                v += Vector3.new(0, look.Y * dir.Magnitude * Settings.FlyMoveSpeed, 0)
            end
            root.AssemblyLinearVelocity = v
            if not flyBody then
                flyBody = true
                hum:ChangeState(Enum.HumanoidStateType.Physics)
            end
        elseif flyBody then
            flyBody = nil
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end)
    bind(RunService.Stepped, function()
        if not (alive() and Settings.Noclip) then
            return
        end
        local c = myChar()
        for _, p in c and c:GetDescendants() or {} do
            if p:IsA("BasePart") and p.CanCollide then
                p.CanCollide = false
            end
        end
    end)
    bind(UserInputService.JumpRequest, function()
        if Settings.InfJump and not attr("Training") then
            local hum = myHum()
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end)
    bind(LocalPlayer.CharacterAdded, function()
        orig = {}
        flyBody = nil
    end)
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, c in getconnections(LocalPlayer.Idled) do
                if not idled[c] and pcall(c.Disable, c) then
                    idled[c] = true
                end
            end
        elseif next(idled) then
            for c in idled do
                pcall(c.Enable, c)
            end
            table.clear(idled)
        end
    end)
    -- the game sends idle players elsewhere after 18 minutes: a tiny input now and then
    loop(60, function()
        if Settings.AntiAfk then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end
    end)
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
        end
        local hum = myHum()
        if hum then
            hum.WalkSpeed = tonumber(attr("WalkSpeed")) or hum.WalkSpeed
            hum.JumpPower = tonumber(attr("JumpPower")) or hum.JumpPower
        end
    end)
end

--// ESP \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "\0"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local marks = {}
    local function mark(key, adornee, color, text, highlight)
        local m = marks[key]
        if m and m.adornee == adornee and adornee.Parent then
            if m.label.Text ~= text then
                m.label.Text = text
            end
            m.label.TextColor3 = color
            if m.hl then
                m.hl.FillColor, m.hl.OutlineColor = color, color
            end
            m.seen = true
            return
        end
        if m then
            m.bb:Destroy()
            if m.hl then
                m.hl:Destroy()
            end
        end
        local part = adornee:IsA("BasePart") and adornee or adornee:FindFirstChildWhichIsA("BasePart", true)
        if not part then
            return
        end
        local bb = Instance.new("BillboardGui")
        bb.AlwaysOnTop = true
        bb.Size = UDim2.fromOffset(220, 30)
        bb.StudsOffset = Vector3.new(0, 3, 0)
        bb.MaxDistance = math.huge
        bb.Adornee = part
        bb.Parent = folder
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.35
        label.TextColor3 = color
        label.Text = text
        label.Parent = bb
        local hl
        if highlight then
            hl = Instance.new("Highlight")
            hl.Adornee = adornee
            hl.FillColor, hl.OutlineColor = color, color
            hl.FillTransparency = 0.6
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = folder
        end
        marks[key] = { bb = bb, hl = hl, label = label, adornee = adornee, seen = true }
    end
    loop(0.3, function()
        for _, m in marks do
            m.seen = false
        end
        local root = myRoot()
        local function d(pos)
            return root and pos and math.floor((pos - root.Position).Magnitude) or 0
        end
        if Settings.EspEggs or Settings.EspDropped then
            local min = rarityIndex(Settings.EspMinRarity)
            for _, e in Eggs.list(Settings.EspDropped) do
                local r = tonumber(e.part:GetAttribute("Rarity")) or 1
                local show = (e.dropped and Settings.EspDropped) or (not e.dropped and Settings.EspEggs and r >= min)
                if show and d(e.part.Position) <= Settings.EspDistance then
                    local v = Eggs.value(e.part, e.zone)
                    mark(e.part, e.part, rarityColor(r), ("%s%s egg · $%s/s · %dm"):format(e.dropped and "DROPPED " or "", RARITY_NAMES[r] or "?",
                        comma(v), d(e.part.Position)), r >= 4 or e.dropped)
                end
            end
        end
        if Settings.EspGuardians then
            for _, g in Guard.list() do
                local p = pivotOf(g)
                if p then
                    local chasing = g:GetAttribute("Chasing")
                    mark(g, g, chasing and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 170, 60),
                        ("%s%s · %dm"):format(g.Name, chasing and " (CHASING)" or "", d(p)), true)
                end
            end
        end
        if Settings.EspSteal then
            for _, t in Steal.targets() do
                mark(t.egg, t.egg, rarityColor(t.r), ("STEAL: %s egg · %dm"):format(RARITY_NAMES[t.r] or "?", d(t.egg.Position)), true)
            end
        end
        if Settings.EspPlayers then
            for _, plr in Players:GetPlayers() do
                local c = plr ~= LocalPlayer and plr.Character
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local carry = plr:GetAttribute("Carrying")
                    mark(plr, c, carry and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(120, 200, 255),
                        ("%s%s · %dm"):format(plr.DisplayName, carry and (" (carrying " .. tostring(carry) .. ")") or "", d(hrp.Position)), false)
                end
            end
        end
        for k, m in marks do
            if not m.seen or not m.adornee.Parent then
                m.bb:Destroy()
                if m.hl then
                    m.hl:Destroy()
                end
                marks[k] = nil
            end
        end
    end)
end

--// Dashboard \\--
local function dashboard()
    local carry = attr("Carrying")
    return table.concat({
        ("Cash $%s · income $%s/s · jump %s"):format(comma(attr("Cash")), tostring(attr("Income") or "?"), comma(attr("Strength"))),
        carry and ("Carrying a %s egg%s"):format(tostring(carry), attr("InMyPen") and " (in your pen)" or "") or "Not carrying an egg",
        ("Job: %s%s"):format(Job.name and (Job.name .. " · ") or "", Job.info),
        ("Eggs: %d grabbed, %d planted · stolen %d"):format(Eggs.grabbed, Eggs.planted, Steal.stolen),
        ("Combo x%s (best x%d) · banked %d times, last $%s"):format(tostring(attr("ComboCount") or 0), Combo.best, Combo.banked, comma(Combo.lastBank)),
        Guard.nearestD and ("Nearest guardian %dm%s"):format(math.floor(Guard.nearestD), Guard.chasingMe() and " · CHASING YOU" or "") or "No guardian near",
    }, "\n")
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Dont Splash For Eggs",
    Footer = "dookie hub · Ui3",
    Icon = "egg",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/DontSplashForEggs",
})
local Options = {}
local function toggle(box, key, text, tip, after)
    Options[key] = box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
    return Options[key]
end
local function slider(box, key, text, min, max, rounding, suffix, tip)
    return box:AddSlider(key, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function multi(box, key, text, values, defaults, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = defaults or {}, Multi = true, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.4)
        end
    end)
end
local function goButton(box, text, fn)
    box:AddButton({ Text = text, Func = function()
        task.spawn(fn)
    end })
end
-- a job toggle: on starts it, off stops it, and it flips back off when the job ends
local runs = {}
local function jobToggle(box, key, name, text, fn, tip)
    toggle(box, key, text, tip, function(v)
        if v then
            runs[key] = (runs[key] or 0) + 1
            local me = runs[key]
            startJob(name, function(still)
                fn(still)
                -- it ended (done, or another job took over): the toggle goes off too
                if runs[key] == me and Settings[key] and Options[key] then
                    task.defer(function()
                        Options[key]:SetValue(false)
                    end)
                end
            end)
        elseif Job.name == name then
            stopJob("Stopped")
        end
    end)
end
local BIOMES = (Config.Combo and Config.Combo.BiomeOrder) or { "Park", "Beach", "Candyland", "Jungle", "FrozenKingdom", "Volcano", "Sakura" }

do
    local Tab = Window:AddTab("Eggs", "egg", "Farm, steal, plant")
    local F = Tab:AddLeftGroupbox("Egg farm", "egg")
    jobToggle(F, "EggFarm", "Egg farm", "Auto egg farm", Eggs.farm,
        "Goes to the best egg, grabs it, takes it to your pen and plants it, over and over. Turn on No splash first")
    dropdown(F, "EggPick", "Pick", { "Best value", "Rarest", "Nearest" }, "Best value: what the pet will earn (the game's own formula)")
    dropdown(F, "EggMinRarity", "At least", RARITY_NAMES)
    multi(F, "EggBiomes", "Only these biomes", BIOMES, {}, "Leave empty for every biome")
    toggle(F, "GrabDropped", "Grab dropped eggs first", "Eggs other players dropped vanish after 15 s")
    toggle(F, "AutoPlant", "Plant in your pen by itself", "Plants the moment you walk into your pen with an egg")
    dropdown(F, "MoveMethod", "Travel", { "Teleport", "Fly" }, "Fly goes in a straight line at the speed below")
    slider(F, "FlySpeed", "Fly speed", 40, 500, 0, " studs/s")
    status(F, function()
        return ("%s\nGrabbed %d · planted %d"):format(Eggs.info, Eggs.grabbed, Eggs.planted)
    end)
    goButton(F, "Plant the egg I have", function()
        startJob("Plant", Eggs.plant)
    end)
    local S = Tab:AddRightGroupbox("Steal", "hand")
    toggle(S, "StealAura", "Steal aura", "Steals any egg in reach of you from other players' pens (rarest first)")
    jobToggle(S, "StealTravel", "Steal run", "Go steal from other pens", Steal.run, "Goes to other pens, steals the best egg and plants it at home")
    dropdown(S, "StealMinRarity", "At least", RARITY_NAMES)
    status(S, function()
        return ("%s\nStolen %d · %d to steal right now"):format(Steal.info, Steal.stolen, #Steal.targets())
    end)
    local D = Tab:AddRightGroupbox("Status", "layout-dashboard")
    status(D, dashboard)
end

do
    local Tab = Window:AddTab("Safety", "shield", "Splash, water, guardians")
    local W = Tab:AddLeftGroupbox("Water", "droplets")
    toggle(W, "NoSplash", "No splash", "Your client is what tells the server you splashed: it's switched off, so the guardians never hear you")
    toggle(W, "WalkOnWater", "Walk on water", "Water is solid for you: no sinking, no slowdown")
    toggle(W, "AntiFling", "Anti-fling", "Guardian and bat hits don't throw or ragdoll you (the throw is done by your own client)")
    local G = Tab:AddRightGroupbox("Guardians", "skull")
    toggle(G, "RunFromGuardians", "Run home when chased", "Back to your pen when a guardian is chasing you")
    slider(G, "RunRange", "Or closer than", 8, 80, 0, " studs")
    toggle(G, "AutoCloak", "Use Ghost Cloak when chased", "Guardians can't catch you for 4 s")
    toggle(G, "AutoPebbles", "Throw Pebbles when chased", "The guardian goes after the pebble instead")
end

do
    local Tab = Window:AddTab("Combo", "zap", "Infinite combo, tricks")
    local C = Tab:AddLeftGroupbox("Inf combo", "infinity")
    jobToggle(C, "InfCombo", "Inf combo", "Inf combo", Combo.run,
        "Keeps your combo going forever: a new platform every hop (6+ studs apart, none again inside 10 s), never in the water")
    dropdown(C, "ComboMethod", "Way", { "Report only", "Teleport hop", "Real fall" },
        "Report only is fastest and doesn't move you; Teleport hop puts you on each platform; Real fall drops you on it. If one isn't counted it moves to the next by itself")
    slider(C, "ComboRate", "Hops a second", 1, 3, 1, "", "Capped so no platform repeats inside its 10 s cooldown")
    slider(C, "ComboBankAt", "Cash out at", 0, 500, 0, "x", "0 = never (combo grows forever). Otherwise it stops at this count and lets the timer pay it out")
    status(C, function()
        return ("%s\nServer says: %s\nBanked %d times · last $%s · broken %d"):format(Combo.info, Combo.why, Combo.banked, comma(Combo.lastBank), Combo.lost)
    end)
    local T = Tab:AddRightGroupbox("Tricks", "sparkles")
    toggle(T, "AutoTricks", "Auto tricks", "In the air, chains the best tricks that fit before you land (points and flip coins)")
end

do
    local Tab = Window:AddTab("Base", "home", "Collect, train, pets")
    local B = Tab:AddLeftGroupbox("Money", "dollar-sign")
    toggle(B, "AutoCollect", "Auto collect", "Touches your collect pads")
    slider(B, "CollectEvery", "Every", 1, 60, 0, " s")
    toggle(B, "AutoPenUpgrade", "Auto upgrade pedestals", "Clicks your pen's upgrade boards (spends cash)")
    toggle(B, "AutoTreasure", "Open your pet treasure")
    local T = Tab:AddLeftGroupbox("Strength", "dumbbell")
    toggle(T, "AutoTrain", "Auto train", "Stands you on your squat mat whenever nothing else needs you")
    toggle(T, "AutoBarbell", "Auto buy barbells", "The next barbell as soon as you have the cash")
    toggle(T, "AutoRebirth", "Auto rebirth")
    local P = Tab:AddRightGroupbox("Pets", "paw-print")
    toggle(P, "AutoEquipBest", "Equip best pets")
    toggle(P, "AutoSell", "Auto sell pets", "Never favourites or pets in your pen")
    dropdown(P, "SellUpTo", "Sell up to", RARITY_NAMES)
    status(P, function()
        return ("%s · collected %d times"):format(Base.info, Base.collected)
    end)
end

do
    local Tab = Window:AddTab("Rewards", "gift", "Claims, gear")
    local R = Tab:AddLeftGroupbox("Claim", "gift")
    toggle(R, "AutoSpin", "Spin the wheel (free spins)")
    toggle(R, "AutoGift", "Free gift")
    toggle(R, "AutoDaily", "Daily reward")
    toggle(R, "AutoPlaytime", "Playtime rewards")
    toggle(R, "AutoJourney", "Journey rewards")
    toggle(R, "AutoQuests", "Accept quests")
    toggle(R, "AutoIndex", "Index rewards")
    status(R, function()
        return ("%s · %d claimed"):format(Rewards.info, Rewards.n)
    end)
    local G = Tab:AddRightGroupbox("Gear", "backpack")
    toggle(G, "AutoBuyGear", "Auto buy gear", "Buys the picked gear whenever the shop has it")
    multi(G, "GearBuyList", "Buy", GEAR_BUY, {})
    toggle(G, "AutoPotions", "Use potions", "Cash, squat, growth and token potions as soon as you have them")
    toggle(G, "AutoIncubators", "Use incubators", "Biggest first, on your slowest egg")
end

do
    local Tab = Window:AddTab("ESP", "eye", "Eggs, guardians, players")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "EspEggs", "Eggs", "Rarity, what the pet will earn and distance")
    dropdown(E, "EspMinRarity", "At least", RARITY_NAMES)
    toggle(E, "EspDropped", "Dropped eggs")
    toggle(E, "EspGuardians", "Guardians", "Red when chasing")
    toggle(E, "EspSteal", "Eggs you can steal")
    toggle(E, "EspPlayers", "Players", "Yellow when carrying an egg")
    slider(E, "EspDistance", "Max distance", 100, 8000, 0, " studs")
    local T = Tab:AddRightGroupbox("Teleport", "map-pin")
    goButton(T, "My pen", function()
        local s = Game.penSpot()
        if s then
            Move.to(s)
        end
    end)
    goButton(T, "Hub", function()
        local map = Workspace:FindFirstChild("Map")
        local hub = map and map:FindFirstChild("Hub")
        local spot = hub and (pivotOf(hub:FindFirstChild("FreeGift")) or pivotOf(hub:FindFirstChild("SpinWheel")))
        if spot then
            Move.to(spot + Vector3.new(6, 5, 0))
        end
    end)
    for _, name in BIOMES do
        goButton(T, name, function()
            local z = Game.zoneNamed(name)
            local s = z and z:GetAttribute("ZStart")
            if s then
                Game.stream(Vector3.new(0, 62, s - 20), 2)
                Move.to(Vector3.new(0, 68, s - 15))
            else
                notify(name .. " isn't loaded or open yet")
            end
        end)
    end
end

do
    local Tab = Window:AddTab("Player", "user", "Movement, AFK")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Speed")
    slider(M, "WalkSpeed", "Speed", 16, 150, 0)
    toggle(M, "JumpOn", "Jump power")
    slider(M, "JumpPower", "Jump power", 50, 300, 0)
    toggle(M, "InfJump", "Infinite jump")
    toggle(M, "Fly", "Fly", "Space up, Left Ctrl down")
    slider(M, "FlyMoveSpeed", "Fly speed", 20, 300, 0)
    toggle(M, "Noclip", "Noclip")
    local O = Tab:AddRightGroupbox("Other", "settings")
    toggle(O, "AntiAfk", "Anti-AFK", "The game moves idle players after 18 minutes")
    goButton(O, "Stop what it's doing", function()
        for _, k in { "EggFarm", "StealTravel", "InfCombo" } do
            if Settings[k] and Options[k] then
                Options[k]:SetValue(false)
            end
        end
        stopJob("Stopped")
    end)
    O:AddButton({ Text = "Unload", Func = function()
        if Genv.__EggsUnload then
            Genv.__EggsUnload()
        end
    end })
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    stopJob()
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__EggsUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded" .. ((next(Config) == nil) and " (game config not found)" or ""), 4)

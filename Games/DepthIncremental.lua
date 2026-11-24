--// DEPTH INCREMENTAL ---------------------------------------------------------------------------
-- place 119101118479978 (game 10769835283), built against version 31. Built on Ui3.
-- What the game's client shows:
--   Config     ReplicatedStorage.PitConfig: Steps / W2Steps (position, price, currency), Rooms,
--              Upgrades, Tree, Specials, Rebirths, Boss, plus Price / StepDiscount /
--              StepBlocked / UpgradeCost / SpecialUnlocked / SpecialOn helpers.
--   Money      player attributes Cash, Bucks, Spores, Essence, Souls, ... (the currency a
--              thing costs is named in its config entry). Steps / W2Steps = steps owned,
--              Up_<name> = upgrade level, Tree_<id> = tree node owned, Room_<id> = room
--              owned, Special_<id> / SpecialOff_<id> = special bought / switched off,
--              Rebirths, <Prefix>Active = a boss fight is running.
--   Remotes    ReplicatedStorage.PitRemotes:
--                BuyStep(n) / BuyW2Step(n)   buy the next step (you stand on it)
--                BuyRoom(id), BuyUpgrade(name, buyMax), BuyTreeNode(id)
--                BuySpecial(id), ToggleSpecial(id), Rebirth()
--                W2Hatch(eggId, count) on W2EggStand models, W2PetEquipBest(), W2PetUnequipAll()
--                WormSpawned(id, pos, golden) -> WormCollected(id) inside the worm radius
--                EssencePick(ids), CoalPickup() / CoalDrop(), Teleport(room), SetPref(name, v)
--                <P>Start() / <P>Hit() / <P>Down() with <P>Event for each boss (P = Beetle,
--                Captain, Eye, King, Kraken, Mantis, Queen, Skull, Warden, Wyrm, W2Baker...;
--                the first two bosses share BossStart(id) / BossHit() / BossGate(id)).
-- The server checks most of these (money, where you stand, timing), so everything is a
-- request the game's own client would send; the risky ones are marked "test" in the menu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__DepthIncUnload then
    pcall(Genv.__DepthIncUnload)
end
Genv.__DepthIncRun = (Genv.__DepthIncRun or 0) + 1
local RUN = Genv.__DepthIncRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__DepthIncRun == RUN
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

local Settings = {
    -- progress
    AutoSteps = false, AutoStepsW2 = false, AutoRooms = false, AutoUpgrades = false, AutoTree = false,
    AutoSpecials = false, AutoToggleSpecials = false, AutoRebirth = false, RebirthLimit = 99,
    -- bosses
    BossHit = false, BossHitDelay = 0.6, BossPick = "Dirt",
    -- pets
    AutoHatch = false, HatchEgg = "", HatchCount = 1, HatchDelay = 3, AutoEquipBest = false,
    -- collecting
    AutoWorms = false, AutoEssence = false, AutoCoalDrop = false, AutoPrompts = false, PromptRange = 14,
    PromptAvoid = true,
    -- esp
    EggEsp = false, WormEsp = false, PromptEsp = false, EspDistance = 400,
    -- misc
    AntiAfk = true, Fullbright = false, TeleportTo = "Hatchery",
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
                warn("[DEPTH INCREMENTAL] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "DEPTH INCREMENTAL", Description = text, Time = seconds or 3 })
end
local function myRoot()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function num(name)
    return tonumber(LocalPlayer:GetAttribute(name)) or 0
end
local function flag(name)
    return LocalPlayer:GetAttribute(name) == true
end
local function comma(n)
    n = tonumber(n) or 0
    if math.abs(n) < 1000 then
        return tostring(math.floor(n * 10 + 0.5) / 10)
    end
    local units = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 0
    while math.abs(n) >= 1000 and i < #units do
        n /= 1000
        i += 1
    end
    return ("%.2f%s"):format(n, units[i])
end

local Remotes = ReplicatedStorage:WaitForChild("PitRemotes", 15)
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
local Cfg
pcall(function()
    Cfg = require(ReplicatedStorage:WaitForChild("PitConfig", 10))
end)
local Pets
pcall(function()
    Pets = require(ReplicatedStorage:WaitForChild("PetConfig", 5))
end)

-- A move-and-come-back helper for things you have to stand next to.
local Busy = { reason = nil }
local function trip(reason, fn, back)
    if Busy.reason then
        return false
    end
    local root = myRoot()
    if not root then
        return false
    end
    Busy.reason = reason
    local home = root.CFrame
    local ok, err = pcall(fn)
    if not ok then
        warn("[DEPTH INCREMENTAL] " .. tostring(err))
    end
    if back ~= false then
        local r = myRoot()
        if r then
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = home
        end
    end
    Busy.reason = nil
    return ok
end
local function moveTo(pos)
    local root = myRoot()
    if root and pos then
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(pos)
        return true
    end
    return false
end

--// Progress \\--
local Progress = { info = "", bought = {} }
do
    local function count(key)
        Progress.bought[key] = (Progress.bought[key] or 0) + 1
    end

    -- Steps: the game only buys the step you are standing on, so you are put on it first.
    local lastStep = { [1] = { 0, 0 }, [2] = { 0, 0 } }
    local function stepTick(world)
        if not Cfg or Busy.reason then
            return
        end
        local steps, attrName, remoteName, price, currency, blocked
        if world == 1 then
            steps, attrName, remoteName = Cfg.Steps, "Steps", "BuyStep"
            price = function(n)
                local p = Cfg.Price(n)
                return p and math.floor(p * Cfg.StepDiscount(LocalPlayer, n)) or nil
            end
            currency = Cfg.StepCurrency
            blocked = Cfg.StepBlocked
        else
            steps, attrName, remoteName = Cfg.W2Steps, "W2Steps", "BuyW2Step"
            price = Cfg.W2Price
            currency = Cfg.W2StepCurrency
            blocked = Cfg.W2StepBlocked
        end
        if not (steps and price and currency) then
            return
        end
        local owned = num(attrName)
        local n = owned + 1
        local step = steps[n]
        if not step then
            Progress.info = ("world %d: no more steps"):format(world)
            return
        end
        local cost = price(n)
        local cur = currency(n) or "Cash"
        if not cost then
            return
        end
        if blocked then
            local why = blocked(LocalPlayer, n)
            if why then
                Progress.info = ("step %d: %s"):format(n, tostring(why))
                return
            end
        end
        if num(cur) < cost then
            Progress.info = ("step %d needs %s %s"):format(n, comma(cost), cur)
            return
        end
        -- one try per second for the same step
        local last = lastStep[world]
        if last[1] == n and os.clock() - last[2] < 1 then
            return
        end
        lastStep[world] = { n, os.clock() }
        moveTo(step.pos + Vector3.new(0, 3, 0))
        task.wait(0.15)
        fire(remoteName, n)
        count("steps")
        Progress.info = ("bought step %d"):format(n)
    end
    loop(0.3, function()
        if Settings.AutoSteps then
            stepTick(1)
        end
        if Settings.AutoStepsW2 then
            stepTick(2)
        end
    end)

    -- Rooms
    loop(1, function()
        if not (Settings.AutoRooms and Cfg and type(Cfg.Rooms) == "table") then
            return
        end
        for _, room in Cfg.Rooms do
            if not flag("Room_" .. room.id) and num("Steps") >= (room.step or 0) and num(room.currency or "Cash") >= (room.price or math.huge) then
                fire("BuyRoom", room.id)
                count("rooms")
                Progress.info = "bought room " .. room.id
                task.wait(0.4)
            end
        end
    end)

    -- Upgrades
    loop(0.5, function()
        if not (Settings.AutoUpgrades and Cfg and Cfg.UpgradeOrder) then
            return
        end
        for _, name in Cfg.UpgradeOrder do
            local up = Cfg.Upgrades[name]
            local level = num("Up_" .. name)
            if up and level < up.max then
                local ok, cost = pcall(Cfg.UpgradeCost, name, level)
                if ok and cost and num(up.currency or "Cash") >= cost then
                    local r = remote("BuyUpgrade")
                    if r then
                        r:FireServer(name, false)
                        count("upgrades")
                        Progress.info = ("%s -> %d"):format(name, level + 1)
                        task.wait(0.15)
                    end
                end
            end
        end
    end)

    -- Upgrade tree
    loop(0.5, function()
        if not (Settings.AutoTree and Cfg and type(Cfg.Tree) == "table") then
            return
        end
        local list = {}
        for _, node in Cfg.Tree do
            if not flag("Tree_" .. node.id) and (not node.parent or flag("Tree_" .. node.parent))
                and num("Rebirths") >= (node.rebirth or 0) and num(node.currency or "Cash") >= (node.cost or math.huge) then
                table.insert(list, node)
            end
        end
        table.sort(list, function(a, b)
            return a.cost < b.cost
        end)
        for i = 1, math.min(#list, 3) do
            fire("BuyTreeNode", list[i].id)
            count("tree")
            Progress.info = "tree node " .. tostring(list[i].id)
            task.wait(0.3)
        end
    end)

    -- Specials (the game's own auto-features): buy them, keep the auto ones switched on.
    loop(1, function()
        if not (Cfg and type(Cfg.Specials) == "table") then
            return
        end
        for _, sp in Cfg.Specials do
            local owned = flag("Special_" .. sp.id)
            if Settings.AutoSpecials and not owned and Cfg.SpecialUnlocked(LocalPlayer, sp)
                and num(sp.currency or "Cash") >= (sp.cost or math.huge) then
                fire("BuySpecial", sp.id)
                count("specials")
                Progress.info = "special " .. tostring(sp.name or sp.id)
                task.wait(0.4)
            elseif Settings.AutoToggleSpecials and owned and sp.wall == "Auto" and not Cfg.SpecialOn(LocalPlayer, sp.id) then
                fire("ToggleSpecial", sp.id)
                task.wait(0.4)
            end
        end
    end)

    -- Rebirth: when the next one is affordable.
    local lastRebirth = 0
    loop(1.5, function()
        if not (Settings.AutoRebirth and Cfg and type(Cfg.Rebirths) == "table") then
            return
        end
        local nextRebirth = num("Rebirths") + 1
        local def = Cfg.Rebirths[nextRebirth]
        if def and nextRebirth <= Settings.RebirthLimit and num(def.currency or "Cash") >= def.cost and os.clock() - lastRebirth > 8 then
            lastRebirth = os.clock()
            fire("Rebirth")
            count("rebirths")
            Progress.info = "rebirth " .. nextRebirth
        end
    end)

    function Progress.status()
        local lines = {
            ("Cash %s · Bucks %s"):format(comma(num("Cash")), comma(num("Bucks"))),
            ("Steps %d · world 2 steps %d · rebirths %d"):format(num("Steps"), num("W2Steps"), num("Rebirths")),
            ("Bought: %d steps, %d rooms, %d upgrades, %d tree, %d specials"):format(Progress.bought.steps or 0, Progress.bought.rooms or 0,
                Progress.bought.upgrades or 0, Progress.bought.tree or 0, Progress.bought.specials or 0),
            Progress.info ~= "" and ("Last: " .. Progress.info) or "-",
        }
        return table.concat(lines, "\n")
    end
end

--// Bosses \\--
local Boss = { hits = 0, info = "" }
do
    -- id -> the remote prefix the game uses for it
    local PREFIX = {
        Spider = "Queen", Kraken = "Kraken", FrostWyrm = "Wyrm", MushroomKing = "King", VoidEye = "Eye",
        SoulWarden = "Warden", TectonicBeetle = "Beetle", GhostCaptain = "Captain", TitanSkull = "Skull",
        Mantis = "Mantis", Ignaroth = "Ignaroth", TitanSkullEcho = "Skull",
    }
    local ORDER = { "Dirt", "Stone", "Spider", "Kraken", "FrostWyrm", "MushroomKing", "VoidEye", "SoulWarden", "TectonicBeetle", "GhostCaptain", "TitanSkull", "Mantis" }
    Boss.list = ORDER
    -- Every boss with Start / Hit / Event remotes.
    local function prefixes()
        local out = {}
        if Remotes then
            for _, r in Remotes:GetChildren() do
                local p = r.Name:match("^(.+)Hit$")
                if p and remote(p .. "Start") and remote(p .. "Event") then
                    table.insert(out, p)
                end
            end
        end
        return out
    end
    -- Auto hit: the swing the game's own client sends while a fight is on.
    loop(0.1, function()
        if not Settings.BossHit then
            return
        end
        local now = os.clock()
        if now - (Boss.last or 0) < Settings.BossHitDelay then
            return
        end
        for _, p in prefixes() do
            if flag(p .. "Active") then
                Boss.last = now
                fire(p .. "Hit")
                Boss.hits += 1
                Boss.info = "hitting " .. p
            end
        end
    end)
    -- Start one on demand: opens the gate, then asks for the fight.
    function Boss.start(id)
        id = id or Settings.BossPick
        if id == "Dirt" or id == "Stone" then
            fire("BossGate", id)
            task.wait(1.2)
            fire("BossStart", id)
            Boss.info = "started " .. id
            return
        end
        local p = PREFIX[id]
        if not p then
            return
        end
        fire("BossGate", id)
        task.wait(1.2)
        fire(p .. "Start")
        Boss.info = "started " .. id
    end
end

--// Pets \\--
local Pet = { hatched = 0, info = "" }
do
    function Pet.eggs()
        local list, seen = {}, {}
        for _, stand in CollectionService:GetTagged("W2EggStand") do
            local id = stand:GetAttribute("EggId")
            if id and not seen[id] then
                seen[id] = true
                table.insert(list, id)
            end
        end
        table.sort(list)
        return list
    end
    local function stand(eggId)
        for _, s in CollectionService:GetTagged("W2EggStand") do
            if s:GetAttribute("EggId") == eggId then
                return s
            end
        end
        return nil
    end
    loop(0.5, function()
        if not Settings.AutoHatch or Settings.HatchEgg == "" or Busy.reason then
            return
        end
        local def = Pets and Pets.EGGS and Pets.EGGS[Settings.HatchEgg]
        if not def then
            return
        end
        local count = Settings.HatchCount
        if Pets.bestCount then
            local ok, best = pcall(Pets.bestCount, LocalPlayer, count)
            if ok and best then
                count = best
            end
        end
        if num(def.currency or "Bucks") < def.price * count then
            Pet.info = "can't afford " .. Settings.HatchEgg
            return
        end
        local s = stand(Settings.HatchEgg)
        local part = s and (s:FindFirstChild("EggAnchor") or s.PrimaryPart or s:FindFirstChildWhichIsA("BasePart", true))
        if part then
            local root = myRoot()
            if root and (root.Position - part.Position).Magnitude > 14 then
                moveTo(part.Position + Vector3.new(0, 4, 8))
                task.wait(0.2)
            end
        end
        fire("W2Hatch", Settings.HatchEgg, count)
        Pet.hatched += count
        Pet.info = ("hatched %d x %s"):format(count, Settings.HatchEgg)
        task.wait(Settings.HatchDelay)
    end)
    loop(15, function()
        if Settings.AutoEquipBest then
            fire("W2PetEquipBest")
        end
    end)
end

--// Collecting \\--
local Collect = { worms = {}, essence = {}, taken = 0, info = "" }
do
    -- Worms: the server tells you where each one is; you have to be inside the worm radius.
    local spawned, collected = remote("WormSpawned"), remote("WormCollected")
    if spawned then
        bind(spawned.OnClientEvent, function(id, pos, golden)
            if typeof(pos) == "Vector3" then
                Collect.worms[id] = { pos = pos, golden = golden == true }
            end
        end)
    end
    if collected then
        bind(collected.OnClientEvent, function(id)
            Collect.worms[id] = nil
        end)
    end
    loop(0.4, function()
        if not Settings.AutoWorms or Busy.reason or not next(Collect.worms) then
            return
        end
        local radius = (Cfg and Cfg.WORM_RADIUS or 4.5) + num("TreeWormRadius") - 1
        local ids = {}
        local first
        for id, w in Collect.worms do
            if not first or w.golden then
                first = w
            end
            table.insert(ids, id)
            if #ids >= 40 then
                break
            end
        end
        if not first then
            return
        end
        trip("worms", function()
            moveTo(first.pos + Vector3.new(0, 3, 0))
            task.wait(0.15)
            for id, w in Collect.worms do
                local root = myRoot()
                if root and ((root.Position - w.pos) * Vector3.new(1, 0, 1)).Magnitude <= radius then
                    collected:FireServer(id)
                    Collect.taken += 1
                end
            end
            task.wait(0.2)
        end, true)
        Collect.info = "worms: " .. Collect.taken
    end)

    -- Essence orbs: the pick request names the orbs close to you.
    local stateEv, spawnEv = remote("EssenceState"), remote("EssenceSpawn")
    local function put(id, data)
        local pos
        if typeof(data) == "Vector3" then
            pos = data
        elseif type(data) == "table" then
            pos = data.pos or data.p or data.position or data[1]
        end
        if typeof(pos) == "Vector3" then
            Collect.essence[id] = pos
        end
    end
    if stateEv then
        bind(stateEv.OnClientEvent, function(list)
            Collect.essence = {}
            if type(list) == "table" then
                for _, row in list do
                    if type(row) == "table" then
                        put(row[1], row[2])
                    end
                end
            end
        end)
    end
    if spawnEv then
        bind(spawnEv.OnClientEvent, function(id, data)
            put(id, data)
        end)
    end
    local pick = remote("EssencePick")
    if pick then
        bind(pick.OnClientEvent, function(list)
            if type(list) == "table" then
                for _, row in list do
                    if type(row) == "table" then
                        Collect.essence[row[1]] = nil
                    end
                end
            end
        end)
    end
    loop(0.5, function()
        if not Settings.AutoEssence or not pick or Busy.reason or not next(Collect.essence) then
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        local ids = {}
        for id, pos in Collect.essence do
            if (pos - root.Position).Magnitude <= 40 then
                table.insert(ids, id)
            end
        end
        if #ids == 0 then
            -- nothing close: go to the nearest one
            local best, bd
            for _, pos in Collect.essence do
                local d = (pos - root.Position).Magnitude
                if not bd or d < bd then
                    best, bd = pos, d
                end
            end
            if best then
                trip("essence", function()
                    moveTo(best + Vector3.new(0, 3, 0))
                    task.wait(0.3)
                    local ids2 = {}
                    for id, pos in Collect.essence do
                        if (pos - best).Magnitude <= 30 then
                            table.insert(ids2, id)
                        end
                    end
                    pick:FireServer(ids2)
                    task.wait(0.3)
                end, true)
            end
        else
            pick:FireServer(ids)
        end
        Collect.info = "essence orbs: " .. tostring(#ids)
    end)

    -- Coal: the crate is picked up with a prompt; this drops it off when you're carrying one.
    loop(1, function()
        if Settings.AutoCoalDrop and flag("Carrying") then
            fire("CoalDrop")
        end
    end)

    -- Any prompt close to you (coal crates, gates, echo crystals, veils...), except purchases.
    local AVOID = { "buy", "purchase", "robux", "r$", "gift", "group" }
    loop(0.4, function()
        if not Settings.AutoPrompts or typeof(fireproximityprompt) ~= "function" then
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        for _, d in Workspace:GetDescendants() do
            if d:IsA("ProximityPrompt") and d.Enabled then
                local parent = d.Parent
                local pos = parent and (parent:IsA("BasePart") and parent.Position or parent:IsA("Attachment") and parent.WorldPosition)
                if pos and (pos - root.Position).Magnitude <= Settings.PromptRange then
                    local text = (d.ActionText .. " " .. d.ObjectText):lower()
                    local skip = false
                    if Settings.PromptAvoid then
                        for _, w in AVOID do
                            if text:find(w, 1, true) then
                                skip = true
                                break
                            end
                        end
                    end
                    if not skip then
                        pcall(fireproximityprompt, d)
                    end
                end
            end
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
    local function mark(key, adornee, color, text)
        local m = marks[key]
        if not m then
            local bb = Instance.new("BillboardGui")
            bb.AlwaysOnTop = true
            bb.Size = UDim2.fromOffset(180, 28)
            bb.StudsOffset = Vector3.new(0, 3, 0)
            bb.MaxDistance = math.huge
            bb.Adornee = adornee
            bb.Parent = folder
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.fromScale(1, 1)
            label.Font = Enum.Font.GothamBold
            label.TextSize = 12
            label.TextStrokeTransparency = 0.35
            label.Parent = bb
            m = { bb = bb, label = label }
            marks[key] = m
        end
        m.seen = true
        m.label.Text = text
        m.label.TextColor3 = color
    end
    local anchors = {} -- worm id -> invisible anchored part
    local function anchor(key, pos)
        local p = anchors[key]
        if not p then
            p = Instance.new("Part")
            p.Anchored = true
            p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
            p.Transparency = 1
            p.Size = Vector3.one
            p.Parent = folder
            anchors[key] = p
        end
        p.Position = pos
        return p
    end
    loop(0.3, function()
        for _, m in marks do
            m.seen = false
        end
        local root = myRoot()
        local function near(pos)
            return root and (pos - root.Position).Magnitude <= Settings.EspDistance
        end
        if Settings.EggEsp then
            for _, s in CollectionService:GetTagged("W2EggStand") do
                local part = s:FindFirstChild("EggAnchor") or s.PrimaryPart or s:FindFirstChildWhichIsA("BasePart", true)
                local def = Pets and Pets.EGGS and Pets.EGGS[s:GetAttribute("EggId")]
                if part and near(part.Position) then
                    local afford = def and num(def.currency or "Bucks") >= def.price
                    mark(s, part, afford and Color3.fromRGB(150, 255, 140) or Color3.fromRGB(255, 140, 130),
                        ("%s%s"):format(tostring(s:GetAttribute("EggId")), def and (" · " .. comma(def.price) .. " " .. (def.currency or "Bucks")) or ""))
                end
            end
        end
        if Settings.WormEsp then
            for id, w in Collect.worms do
                if near(w.pos) then
                    mark("worm" .. tostring(id), anchor("worm" .. tostring(id), w.pos), w.golden and Color3.fromRGB(255, 220, 90) or Color3.fromRGB(255, 170, 200),
                        w.golden and "GOLDEN worm" or "worm")
                end
            end
        end
        if Settings.PromptEsp then
            for _, d in Workspace:GetDescendants() do
                if d:IsA("ProximityPrompt") and d.Enabled and d.Parent and d.Parent:IsA("BasePart") and near(d.Parent.Position) then
                    mark(d, d.Parent, Color3.fromRGB(120, 200, 255), ("%s %s"):format(d.ActionText, d.ObjectText))
                end
            end
        end
        for k, m in marks do
            local gone = not m.seen or (typeof(k) == "Instance" and not k.Parent)
            if gone then
                m.bb:Destroy()
                marks[k] = nil
                if type(k) == "string" and anchors[k] then
                    anchors[k]:Destroy()
                    anchors[k] = nil
                end
            end
        end
    end)
end

--// Misc \\--
do
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
    -- The game rejoins you after about 17 minutes without input; a tiny mouse nudge counts as input.
    loop(45, function()
        if Settings.AntiAfk and typeof(mousemoverel) == "function" then
            pcall(mousemoverel, 1, 0)
            task.wait(0.05)
            pcall(mousemoverel, -1, 0)
        end
    end)
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
        end
    end)

    local saved
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        if Settings.Fullbright then
            if not saved then
                saved = {
                    Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, GlobalShadows = Lighting.GlobalShadows,
                    Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
                }
            end
            Lighting.Brightness = 2
            Lighting.ClockTime = 14
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(180, 180, 180)
            Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
        elseif saved then
            for k, v in saved do
                pcall(function()
                    Lighting[k] = v
                end)
            end
            saved = nil
        end
    end)
    table.insert(Cleanups, function()
        if saved then
            for k, v in saved do
                pcall(function()
                    Lighting[k] = v
                end)
            end
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "DEPTH INCREMENTAL",
    Footer = "dookie hub · Ui3",
    Icon = "gem",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/DepthIncremental",
})
local function toggle(box, key, text, tip, after)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
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
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.5)
        end
    end)
end

do
    local Tab = Window:AddTab("Progress", "map", "Steps, upgrades, rebirth")
    local S = Tab:AddLeftGroupbox("Going down", "footprints")
    toggle(S, "AutoSteps", "Auto buy steps", "Puts you on the next step and buys it when you can pay and the gate is open")
    toggle(S, "AutoStepsW2", "Auto buy steps (world 2)")
    toggle(S, "AutoRooms", "Auto buy rooms", "Upgrades room, fossils, worms, tree...")
    toggle(S, "AutoRebirth", "Auto rebirth", "When the next rebirth is affordable")
    slider(S, "RebirthLimit", "Stop at rebirth", 1, 99, 0, "")
    status(S, Progress.status)
    local U = Tab:AddRightGroupbox("Upgrades", "zap")
    toggle(U, "AutoUpgrades", "Auto buy upgrades", "Every upgrade, one level at a time, whenever it's affordable")
    toggle(U, "AutoTree", "Auto buy upgrade tree", "Cheapest open node first")
    toggle(U, "AutoSpecials", "Auto buy specials", "The game's own auto features")
    toggle(U, "AutoToggleSpecials", "Keep auto specials switched on")
end

do
    local Tab = Window:AddTab("Bosses", "hammer", "Fights")
    local B = Tab:AddLeftGroupbox("Boss fights", "hammer")
    toggle(B, "BossHit", "Auto hit boss", "Sends the boss swing every time below while any fight is running (the server checks you are close)")
    slider(B, "BossHitDelay", "Swing every", 0.2, 2, 2, " s", "The game's own swing is 0.4 to 1 s depending on the boss")
    dropdown(B, "BossPick", "Boss", Boss.list)
    B:AddButton({ Text = "Open gate and start fight", Func = function()
        task.spawn(Boss.start)
    end, Tooltip = "Stand near the arena first; the game asks the server to open the gate then to begin" })
    status(B, function()
        return ("Hits sent: %d\n%s"):format(Boss.hits, Boss.info)
    end)
end

do
    local Tab = Window:AddTab("Pets", "gem", "Eggs and pets")
    local P = Tab:AddLeftGroupbox("Hatching", "gem")
    local eggs = Pet.eggs()
    if Settings.HatchEgg == "" then
        Settings.HatchEgg = eggs[1] or ""
    end
    dropdown(P, "HatchEgg", "Egg", #eggs > 0 and eggs or { "(none loaded)" }, "Eggs on stands in the world 2 area")
    slider(P, "HatchCount", "Eggs at once", 1, 10, 0, "", "Capped to what you've unlocked")
    slider(P, "HatchDelay", "Wait between hatches", 1, 10, 1, " s")
    toggle(P, "AutoHatch", "Auto hatch", "Walks to the stand if you're far and hatches whenever you can pay")
    toggle(P, "AutoEquipBest", "Keep best pets equipped", "Every 15 s")
    P:AddButton({ Text = "Equip best now", Func = function()
        fire("W2PetEquipBest")
    end })
    P:AddButton({ Text = "Unequip all", Func = function()
        fire("W2PetUnequipAll")
    end })
    status(P, function()
        return ("Hatched: %d\n%s"):format(Pet.hatched, Pet.info)
    end)
end

do
    local Tab = Window:AddTab("Collect", "truck", "Worms, essence, coal, prompts")
    local C = Tab:AddLeftGroupbox("Collecting", "truck")
    toggle(C, "AutoWorms", "Auto collect worms", "Hops to each worm and collects it, then comes back")
    toggle(C, "AutoEssence", "Auto collect essence (test)", "Picks the orbs near you, or hops to the nearest")
    toggle(C, "AutoCoalDrop", "Auto drop coal crate", "Drops the crate you're carrying")
    toggle(C, "AutoPrompts", "Auto use nearby prompts", "Coal crates, room gates, echo crystals, veil tiers... anything close to you except purchases")
    slider(C, "PromptRange", "Prompt range", 4, 40, 0, " studs")
    toggle(C, "PromptAvoid", "Skip purchase prompts", "Buy / Robux / gift / group")
    status(C, function()
        return ("Worms seen: %d · collected: %d\n%s"):format((function()
            local n = 0
            for _ in Collect.worms do
                n += 1
            end
            return n
        end)(), Collect.taken, Collect.info)
    end)
    local T = Tab:AddRightGroupbox("Teleport", "map")
    local rooms = { "Hatchery" }
    if Cfg and type(Cfg.Rooms) == "table" then
        for _, r in Cfg.Rooms do
            table.insert(rooms, r.id)
        end
    end
    dropdown(T, "TeleportTo", "Room", rooms)
    T:AddButton({ Text = "Teleport", Func = function()
        fire("Teleport", Settings.TeleportTo)
    end })
end

do
    local Tab = Window:AddTab("ESP", "eye", "Eggs, worms, prompts")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "EggEsp", "Egg stands", "Green when you can afford one")
    toggle(E, "WormEsp", "Worms", "Golden in yellow")
    toggle(E, "PromptEsp", "Interaction prompts")
    slider(E, "EspDistance", "Max distance", 50, 2000, 0, " studs")
end

do
    local Tab = Window:AddTab("Misc", "settings", "Script")
    local M = Tab:AddLeftGroupbox("Misc", "settings")
    toggle(M, "AntiAfk", "Anti-AFK", "Also nudges the mouse so the game's own 17 minute rejoin doesn't trigger")
    toggle(M, "Fullbright", "Fullbright")
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__DepthIncUnload then
            Genv.__DepthIncUnload()
        end
    end })
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
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__DepthIncUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(Cfg and "Loaded" or "Loaded (game config not found: most options won't work)", 4)

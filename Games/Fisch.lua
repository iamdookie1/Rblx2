--// Fisch ---------------------------------------------------------------------------------------
-- place 131716211654599 (game 5750914919). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Remotes  named remotes are children of ReplicatedStorage.packages.Net,
--            called "RE/<name>" (events) and "RF/<name>" (functions). Older
--            ones live in ReplicatedStorage.events.
--   Rod      a rod is a Tool with values.state (RodState: 3 Equipped,
--            4 Casting, 5 Searching, 6 Luring, 7 PreReel, 8 Reeling,
--            9 CatchFinished) and values.casted. rodClient charges a power
--            bar and calls RF/FishingRod/Cast(power 0-100, perfect).
--            RE/FishingRod/Reset puts the rod back.
--   Shake    the server invokes RF/LureShake/Start on you, a "shakeui" goes
--            into PlayerGui, and every click sends RE/LureShake/Shake (the
--            game allows one every 0.25s). RE/LureShake/Stop ends it.
--   Reel     the server invokes RF/Reel/Start; ReelController.StartReel
--            runs the whole minigame on your side (fishPosition, barPosition,
--            barSize, progress) and EndMinigame sends RE/Reel/Finish
--            { e = progress (100 = caught), p = perfect, l = {}, d = ... }.
--            Player attribute MinigameSpeedMulti scales the minigame's time.
--   Selling  merchants are NPC models with NpcType "Merchant"; the dialog's
--            choice calls events.SellAll with { npc = merchant }.
--            events.PreviewSellAll(false) is what your fish are worth, and
--            events.selleverything sells from anywhere (gamepass).
--   Other    RF/Conch/RequestTpSpots (every client asks for it at load),
--            RE/FastTravel/Teleport(key) (Traveler's Whistle), events.runcode
--            (codes), RE/DailyReward/Claim, RE/TotemCrafting/ClaimCraft,
--            events.open_treasure(id) for "ChestClosed" chests, MeteorItem
--            tagged meteor drops with a ProximityPrompt.
--   Careful  zones tagged Anti_Zone_Exploit (The Depths, Mineshaft, ...) are
--            watched by the server; teleporting into a locked one is risky.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__FischUnload then
    pcall(Genv.__FischUnload)
end
Genv.__FischRun = (Genv.__FischRun or 0) + 1
local RUN = Genv.__FischRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__FischRun == RUN
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
    -- fishing
    AutoEquip = true, AutoCast = false, PerfectCast = true, CastPower = 100, CastDelay = 0.6, StuckReset = 45,
    AutoShake = false, ShakeDelay = 0.3,
    AutoReel = false, ReelMode = "Lock bar on fish", InstantDelay = 1.5,
    FastReel = false, ReelSpeed = 1.5,
    -- selling
    AutoSell = false, SellWhen = "Worth over", SellWorth = 10000, SellEvery = 5, SellAnywhere = false, SellReturn = true,
    -- teleports
    TpSpot = nil, FastTravel = nil,
    -- world
    EspPools = false, EspEvents = false, EspChests = false, EspMeteors = false, EspNpcs = false,
    AutoChests = false, AutoMeteors = false,
    -- misc
    AutoDaily = false, AutoTotem = false, AntiAfk = true, Codes = "",
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
                warn("[Fisch] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Fisch", Description = text, Time = seconds or 3 })
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

--// The game \\--
local Packages = ReplicatedStorage:WaitForChild("packages", 10)
local NetFolder = Packages and Packages:WaitForChild("Net", 10)
local Events = ReplicatedStorage:WaitForChild("events", 10)
local function net(name)
    return NetFolder and NetFolder:FindFirstChild(name)
end
local function ev(name)
    return Events and Events:FindFirstChild(name)
end
local RodState = { Equipped = 3, Casting = 4, Searching = 5, Luring = 6, PreReel = 7, Reeling = 8, CatchFinished = 9 }

local Reel
do
    local ok, m = pcall(function()
        return require(ReplicatedStorage:WaitForChild("client", 10).legacyControllers.ReelController)
    end)
    if ok and type(m) == "table" and type(rawget(m, "StartReel")) == "function" then
        Reel = m
    elseif typeof(getgc) == "function" then
        for _, v in getgc(true) do
            if type(v) == "table" and type(rawget(v, "StartReel")) == "function" and type(rawget(v, "EndMinigame")) == "function"
                and rawget(v, "type") == "reel" then
                Reel = v
                break
            end
        end
    end
end
local function activeReel()
    local r = Reel and Reel.ActiveReel
    if type(r) == "table" and not r.mock then
        return r
    end
    return nil
end
local function shakeUi()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local ui = pg and pg:FindFirstChild("shakeui")
    if ui and ui:IsA("ScreenGui") then
        return ui
    end
    return nil
end
local function isRod(t)
    if not (t and t:IsA("Tool")) then
        return false
    end
    local v = t:FindFirstChild("values")
    return v ~= nil and v:FindFirstChild("state") ~= nil
end
local function heldRod()
    local c = myChar()
    if c then
        for _, t in c:GetChildren() do
            if isRod(t) then
                return t
            end
        end
    end
    return nil
end
local function backpackRod()
    local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
    if not bp then
        return nil
    end
    local wanted
    pcall(function()
        local stats = Workspace.PlayerStats[LocalPlayer.Name].T[LocalPlayer.Name].Stats
        wanted = stats.rod.Value
    end)
    local first
    for _, t in bp:GetChildren() do
        if isRod(t) then
            if t.Name == wanted then
                return t
            end
            first = first or t
        end
    end
    return first
end
local Busy = { reason = nil }

--// Fishing: cast, shake, reel \\--
local Fish = { info = "off", casts = 0, shakes = 0, reels = 0, caught = 0, missed = 0 }
do
    local castRemote = net("RF/FishingRod/Cast")
    local resetRemote = net("RE/FishingRod/Reset")
    local shakeRemote = net("RE/LureShake/Shake")
    local castAt, idleSince, lastState = 0, os.clock(), nil

    loop(0.2, function()
        if not Settings.AutoCast then
            Fish.info = "off"
            return
        end
        if Busy.reason then
            Fish.info = "paused (" .. Busy.reason .. ")"
            return
        end
        local hum = myHum()
        if not hum or hum.Health <= 0 then
            Fish.info = "waiting for your character"
            return
        end
        if hum:GetState() == Enum.HumanoidStateType.Swimming then
            Fish.info = "get out of the water to cast"
            return
        end
        local rod = heldRod()
        if not rod then
            if Settings.AutoEquip then
                local t = backpackRod()
                if t then
                    hum:EquipTool(t)
                    Fish.info = "equipping " .. t.Name
                    task.wait(0.6)
                else
                    Fish.info = "no rod in your backpack"
                end
            else
                Fish.info = "hold a rod"
            end
            return
        end
        if activeReel() then
            Fish.info = "reeling"
            castAt = os.clock()
            return
        end
        if shakeUi() then
            Fish.info = "shaking"
            castAt = os.clock()
            return
        end
        local values = rod.values
        local state = values.state.Value
        local casted = values:FindFirstChild("casted") and values.casted.Value
        if state ~= lastState then
            if state <= RodState.Equipped then
                idleSince = os.clock()
            end
            lastState = state
        end
        if state <= RodState.Equipped and not casted then
            if os.clock() - idleSince < Settings.CastDelay then
                Fish.info = "about to cast"
                return
            end
            if not castRemote then
                Fish.info = "cast remote not found"
                return
            end
            local power = Settings.PerfectCast and (math.random(970, 1000) / 10) or Settings.CastPower
            local ok, res = pcall(castRemote.InvokeServer, castRemote, math.clamp(power, 0, 100), Settings.PerfectCast)
            castAt = os.clock()
            idleSince = os.clock()
            if ok and res then
                Fish.casts += 1
                Fish.info = "casted"
            else
                Fish.info = "cast refused, trying again"
            end
        elseif state >= RodState.Casting and state <= RodState.Luring then
            Fish.info = "waiting for a bite"
            if os.clock() - castAt > Settings.StuckReset and resetRemote then
                resetRemote:FireServer()
                castAt = os.clock()
                idleSince = os.clock()
                Fish.info = "no bite for a while, recasting"
            end
        end
    end)

    -- Shake: the game's own remote, at the pace the shake button allows.
    loop(function()
        return math.max(0.05, Settings.ShakeDelay)
    end, function()
        if not (Settings.AutoShake and shakeRemote) then
            return
        end
        local ui = shakeUi()
        if ui and ui.Enabled then
            shakeRemote:FireServer()
            Fish.shakes += 1
        end
    end)

    -- Reel: steer the bar, lock it on the fish, or finish it.
    local held = {}
    local function release(r)
        local rod = r and r.core and r.core.rod
        if rod and held[r] then
            rod.Disabled = false
            held[r] = nil
        end
    end
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        local r = activeReel()
        if not r then
            return
        end
        if not Settings.AutoReel then
            release(r)
            return
        end
        if not (r.active and r.ready) then
            return
        end
        local rod = r.core and r.core.rod
        local mode = Settings.ReelMode
        if mode == "Instant" then
            r.__dkSeen = r.__dkSeen or os.clock()
            if not r.__dkEnded and os.clock() - r.__dkSeen >= Settings.InstantDelay then
                r.__dkEnded = true
                Fish.reels += 1
                task.spawn(function()
                    pcall(r.EndMinigame, r, true)
                end)
            end
            return
        end
        if type(r.fishPosition) ~= "number" or type(r.barPosition) ~= "number" or type(r.barSize) ~= "number" then
            return
        end
        if mode == "Lock bar on fish" then
            if rod and not rod.Disabled then
                rod.Disabled = true
                held[r] = true
            end
            local half = r.barSize / 2
            local lo = (r.minBarPosition or 0) + half
            local hi = (r.maxBarPosition or 1) - half
            if lo > hi then
                lo, hi = (lo + hi) / 2, (lo + hi) / 2
            end
            r.barPosition = math.clamp(r.fishPosition, lo, hi)
        elseif rod then
            release(r)
            local fishV = (r.core.fish and tonumber(r.core.fish.CurrentVelocity)) or 0
            local barV = tonumber(rod.CurrentVelocity) or 0
            local target = r.fishPosition + fishV * 0.12
            local err = target - r.barPosition - barV * 0.18
            if err > 0 then
                if rod.CurrentInputDirection ~= 1 then
                    rod:InputBegan()
                end
            elseif rod.CurrentInputDirection ~= -1 then
                rod:InputEnded()
            end
        end
    end)
    table.insert(Cleanups, function()
        for r in held do
            release(r)
        end
    end)

    local finished = ev("bindable_reel_finished")
    if finished then
        bind(finished.Event, function(ok)
            if ok then
                Fish.caught += 1
            else
                Fish.missed += 1
            end
        end)
    end

    -- Faster minigame: the game's own speed attribute, on your side only.
    local original
    loop(0.4, function()
        if Settings.FastReel then
            if original == nil then
                original = LocalPlayer:GetAttribute("MinigameSpeedMulti") or false
            end
            if LocalPlayer:GetAttribute("MinigameSpeedMulti") ~= Settings.ReelSpeed then
                LocalPlayer:SetAttribute("MinigameSpeedMulti", Settings.ReelSpeed)
            end
        elseif original ~= nil then
            LocalPlayer:SetAttribute("MinigameSpeedMulti", original or nil)
            original = nil
        end
    end)
    table.insert(Cleanups, function()
        if original ~= nil then
            LocalPlayer:SetAttribute("MinigameSpeedMulti", original or nil)
        end
    end)
end

--// Moving around \\--
local Move = {}
do
    function Move.to(pos)
        local root = myRoot()
        if not (root and typeof(pos) == "Vector3") then
            return false
        end
        pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, pos, 5)
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(pos + Vector3.new(0, 3.5, 0)) * root.CFrame.Rotation
        return true
    end
    function Move.near(model, dist)
        local ok, pivot = pcall(model.GetPivot, model)
        if not ok then
            return false
        end
        local root = myRoot()
        if not root then
            return false
        end
        local spot = pivot.Position + pivot.LookVector * (dist or 4)
        pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, spot, 3)
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.lookAt(spot + Vector3.new(0, 1, 0), pivot.Position * Vector3.new(1, 0, 1) + Vector3.new(0, spot.Y + 1, 0))
        return true
    end
    -- Run fn somewhere else and come back afterwards.
    function Move.trip(reason, fn, back)
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
            warn("[Fisch] " .. tostring(err))
        end
        if back ~= false then
            task.wait(0.25)
            local r = myRoot()
            if r then
                r.AssemblyLinearVelocity = Vector3.zero
                r.CFrame = home
            end
        end
        Busy.reason = nil
        return ok
    end
end

--// Selling \\--
local Sell = { info = "off", sold = 0, worth = nil }
do
    local function merchants()
        local out = {}
        local world = Workspace:FindFirstChild("world")
        local npcs = world and world:FindFirstChild("npcs")
        if npcs then
            for _, d in npcs:GetDescendants() do
                if d:IsA("Model") and d:GetAttribute("NpcType") == "Merchant" then
                    table.insert(out, d)
                end
            end
        end
        return out
    end
    local function nearest()
        local root = myRoot()
        if not root then
            return nil
        end
        local best, bestD
        for _, m in merchants() do
            local ok, p = pcall(m.GetPivot, m)
            if ok then
                local d = (p.Position - root.Position).Magnitude
                if not bestD or d < bestD then
                    best, bestD = m, d
                end
            end
        end
        return best, bestD
    end
    function Sell.preview()
        local f = ev("PreviewSellAll")
        if not f then
            return nil
        end
        local ok, v = pcall(f.InvokeServer, f, false)
        return ok and tonumber(v) or nil
    end
    function Sell.now()
        if Settings.SellAnywhere then
            local f = ev("selleverything")
            local ok, res = pcall(function()
                return f and f:InvokeServer()
            end)
            if ok and res then
                Sell.sold += 1
                Sell.info = "sold (anywhere)"
            else
                Sell.info = "couldn't sell anywhere (needs the gamepass, or nothing to sell)"
            end
            return
        end
        local m, d = nearest()
        if not m then
            Sell.info = "no merchant loaded near you (teleport to an island first)"
            return
        end
        local sellAll = ev("SellAll")
        if not sellAll then
            Sell.info = "SellAll not found"
            return
        end
        local done = false
        Move.trip("selling", function()
            if d > 8 then
                Move.near(m, 4)
                task.wait(0.5)
            end
            local ok, res = pcall(sellAll.InvokeServer, sellAll, { npc = m })
            if not (ok and res) then
                ok, res = pcall(sellAll.InvokeServer, sellAll)
            end
            done = ok and res ~= false and res ~= nil
            task.wait(0.3)
        end, Settings.SellReturn)
        if done then
            Sell.sold += 1
            Sell.info = "sold at " .. m.Name
        else
            Sell.info = "the merchant didn't take it (nothing to sell?)"
        end
    end
    local lastSell, lastCheck = os.clock(), 0
    loop(1, function()
        if not Settings.AutoSell then
            Sell.info = "off"
            return
        end
        if Busy.reason or activeReel() or shakeUi() then
            return
        end
        if Settings.SellWhen == "Every few minutes" then
            local left = Settings.SellEvery * 60 - (os.clock() - lastSell)
            if left > 0 then
                Sell.info = ("selling in %ds"):format(math.ceil(left))
                return
            end
        else
            if os.clock() - lastCheck < 10 then
                return
            end
            lastCheck = os.clock()
            local worth = Sell.preview()
            Sell.worth = worth
            if not worth then
                Sell.info = "can't read what your fish are worth"
                return
            end
            if worth < Settings.SellWorth then
                Sell.info = ("fish worth %d / %d C$"):format(worth, Settings.SellWorth)
                return
            end
        end
        lastSell = os.clock()
        Sell.now()
    end)
end

--// Teleports \\--
local Tp = { spots = {}, names = {}, info = "" }
local FAST_TRAVEL = {
    "volcanicvents", "challengersdeep", "abyssalzenith", "calmzone", "veilofforsaken",
    "base", "cryogenic", "frigidcavern", "glacial", "overgrowthcaves", "borealpines",
    "bellona", "apollo", "poseidon", "zeus", "hades", "olympian", "sunkendepths", "etherealabyss",
    "poseidontemple", "zeustrial", "krakenlair",
    "vertigo", "thedepths", "crystalcove", "venue",
    "toxicgrove", "livinggarden", "nectarden",
    "desolatepocket", "brinepool", "luminescentcavern", "crimsoncavern",
    "lairentrance", "hallofwhispers", "passageofoaths", "thesanctum",
    "sunkenreliquary", "coralbastion", "collapsedruins", "crownedruins",
    "treasureisland", "abovetheclouds",
}
do
    local function toPos(v)
        local t = typeof(v)
        if t == "Vector3" then
            return v
        elseif t == "CFrame" then
            return v.Position
        elseif t == "Instance" then
            if v:IsA("BasePart") then
                return v.Position
            elseif v:IsA("Model") then
                local ok, p = pcall(v.GetPivot, v)
                return ok and p.Position or nil
            elseif v:IsA("Attachment") then
                return v.WorldPosition
            end
        elseif t == "table" then
            return toPos(v.CFrame or v.Position or v.cframe or v.position or v[1])
        end
        return nil
    end
    function Tp.load()
        local spots = {}
        local f = net("RF/Conch/RequestTpSpots")
        if f then
            local ok, t = pcall(f.InvokeServer, f)
            if ok and type(t) == "table" then
                for k, v in pairs(t) do
                    local pos = toPos(v)
                    if type(k) == "string" and pos then
                        spots[k] = pos
                    end
                end
            end
        end
        local world = Workspace:FindFirstChild("world")
        local sp = world and world:FindFirstChild("spawns")
        if sp then
            for _, folder in sp:GetChildren() do
                if folder.Name == "TpSpots" then
                    for _, p in folder:GetChildren() do
                        if p:IsA("BasePart") and not spots[p.Name] then
                            spots[p.Name] = p.Position
                        end
                    end
                elseif folder:IsA("Folder") and not spots[folder.Name] then
                    for _, p in folder:GetDescendants() do
                        if p:IsA("BasePart") then
                            spots[folder.Name] = p.Position
                            break
                        end
                    end
                end
            end
        end
        local names = {}
        for k in spots do
            table.insert(names, k)
        end
        table.sort(names, function(a, b)
            return a:lower() < b:lower()
        end)
        Tp.spots, Tp.names = spots, names
        Tp.info = ("%d spots"):format(#names)
        return names
    end
    function Tp.go(name)
        local pos = name and Tp.spots[name]
        if not pos then
            notify("Pick a spot first")
            return
        end
        if Move.to(pos) then
            Tp.info = "went to " .. name
        end
    end
    function Tp.fast(key)
        local r = net("RE/FastTravel/Teleport")
        if not (key and r) then
            notify("Pick a place first")
            return
        end
        r:FireServer(key)
        Tp.info = "fast travel to " .. key .. " (needs the Traveler's Whistle and that place unlocked)"
    end
end

--// World: ESP, chests, meteors \\--
local World = { chests = {}, info = "", opened = 0, meteors = 0 }
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
        if m and m.adornee == adornee and adornee.Parent then
            m.label.Text = text
            m.seen = true
            return
        end
        if m then
            m.bb:Destroy()
            if m.hl then
                m.hl:Destroy()
            end
        end
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
        label.TextSize = 13
        label.TextStrokeTransparency = 0.35
        label.TextColor3 = color
        label.Text = text
        label.Parent = bb
        local hl
        if adornee:IsA("Model") or adornee:IsA("BasePart") then
            hl = Instance.new("Highlight")
            hl.Adornee = adornee
            hl.FillColor, hl.OutlineColor = color, color
            hl.FillTransparency = 0.75
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = folder
        end
        marks[key] = { bb = bb, hl = hl, label = label, adornee = adornee, seen = true }
    end

    local fishingZones = Workspace:FindFirstChild("zones") and Workspace.zones:FindFirstChild("fishing")
    local startZones = {}
    if fishingZones then
        for _, z in fishingZones:GetChildren() do
            startZones[z] = true
        end
    end

    -- Chests: "ChestClosed" models with an id, found once and then as they appear.
    local function noteChest(d)
        if d.Name == "ChestClosed" and d:GetAttribute("id") then
            World.chests[d] = true
        end
    end
    task.spawn(function()
        for _, d in Workspace:GetDescendants() do
            if d.Name == "ChestClosed" then
                noteChest(d)
            end
        end
    end)
    bind(Workspace.DescendantAdded, function(d)
        if d.Name == "ChestClosed" then
            task.defer(noteChest, d)
        end
    end)

    local function pivotOf(inst)
        if inst:IsA("BasePart") then
            return inst.Position
        end
        local ok, p = pcall(inst.GetPivot, inst)
        return ok and p.Position or nil
    end

    loop(1, function()
        for _, m in marks do
            m.seen = false
        end
        local root = myRoot()
        if fishingZones and (Settings.EspPools or Settings.EspEvents) then
            for _, z in fishingZones:GetChildren() do
                if z:IsA("BasePart") then
                    local ab = z:FindFirstChild("Abundance")
                    if Settings.EspPools and ab and ab:IsA("StringValue") and ab.Value ~= "" then
                        mark(z, z, Color3.fromRGB(120, 220, 255), ab.Value .. " pool")
                    elseif Settings.EspEvents and not startZones[z] then
                        mark(z, z, Color3.fromRGB(255, 170, 60), z.Name)
                    end
                end
            end
        end
        if Settings.EspChests then
            for c in World.chests do
                if c.Parent then
                    local p = pivotOf(c)
                    local dist = root and p and math.floor((p - root.Position).Magnitude) or 0
                    mark(c, c, Color3.fromRGB(255, 215, 80), ("Chest [%dm]"):format(dist))
                else
                    World.chests[c] = nil
                end
            end
        end
        if Settings.EspMeteors then
            for _, m in CollectionService:GetTagged("MeteorItem") do
                mark(m, m, Color3.fromRGB(255, 110, 80), "Meteor")
            end
        end
        if Settings.EspNpcs then
            for _, tag in { "NewNpc", "LegacyNpc" } do
                for _, n in CollectionService:GetTagged(tag) do
                    local kind = n:GetAttribute("NpcType")
                    if kind and (kind == "Merchant" or kind == "Appraiser" or kind == "Daily Shopkeeper" or kind == "InnKeeper") then
                        mark(n, n, Color3.fromRGB(150, 255, 150), ("%s (%s)"):format(n.Name, kind))
                    end
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

    -- Open chests and grab meteors, then come back.
    loop(2, function()
        if Busy.reason or activeReel() or shakeUi() then
            return
        end
        if Settings.AutoChests then
            local open = ev("open_treasure")
            for c in World.chests do
                if not Settings.AutoChests or not alive() then
                    break
                end
                local id = c.Parent and c:GetAttribute("id")
                if id and open then
                    Move.trip("opening a chest", function()
                        Move.near(c, 3)
                        task.wait(0.4)
                        local prompt = c:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if prompt and typeof(fireproximityprompt) == "function" then
                            pcall(fireproximityprompt, prompt)
                        else
                            open:FireServer(id)
                        end
                        task.wait(0.6)
                    end)
                    World.opened += 1
                    World.chests[c] = nil
                    task.wait(0.5)
                end
            end
        end
        if Settings.AutoMeteors then
            for _, m in CollectionService:GetTagged("MeteorItem") do
                local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt and typeof(fireproximityprompt) == "function" then
                    Move.trip("grabbing a meteor", function()
                        Move.near(m, 2)
                        task.wait(0.4)
                        pcall(fireproximityprompt, prompt)
                        task.wait(0.6)
                    end)
                    World.meteors += 1
                end
            end
        end
    end)

    function World.events()
        local live = {}
        for k, v in Workspace:GetAttributes() do
            if v == true and (k:match("HuntActive$") or k:match("_IsActive$") or k:match("Active$")) then
                local name = k:gsub("_IsActive$", ""):gsub("HuntActive$", " hunt"):gsub("Active$", "")
                table.insert(live, name)
            end
        end
        table.sort(live)
        return live
    end
end

--// Claims, codes, anti-AFK \\--
local Claims = { info = "", codes = 0 }
do
    loop(300, function()
        if Settings.AutoDaily then
            local r = net("RE/DailyReward/Claim")
            if r then
                r:FireServer()
                Claims.info = "daily reward claimed (if it was ready)"
            end
        end
    end)
    loop(30, function()
        if Settings.AutoTotem then
            local r = net("RE/TotemCrafting/ClaimCraft")
            if r then
                r:FireServer()
            end
        end
    end)
    function Claims.redeem(text)
        local run = ev("runcode")
        if not run then
            notify("Codes remote not found")
            return
        end
        local n = 0
        for code in tostring(text or ""):gmatch("[^%s,;]+") do
            run:FireServer(code)
            n += 1
            task.wait(1)
        end
        Claims.codes += n
        notify(n > 0 and ("Sent %d code%s"):format(n, n == 1 and "" or "s") or "Type a code first")
    end

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
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
        end
    end)
end

--// Stats \\--
local Stats = { start = os.clock(), coins0 = nil }
do
    local function coins()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local v = ls and ls:FindFirstChild("C$")
        if not v and ls then
            for _, c in ls:GetChildren() do
                if c:IsA("ValueBase") and c.Name ~= "Level" and tonumber(c.Value) then
                    v = c
                    break
                end
            end
        end
        return v and tonumber(v.Value) or nil, v and v.Name or "C$"
    end
    Stats.coins = coins
    Stats.coins0 = coins()
    function Stats.text()
        local mins = math.max((os.clock() - Stats.start) / 60, 1 / 60)
        local c, currency = coins()
        Stats.coins0 = Stats.coins0 or c
        local earned = (c and Stats.coins0) and (c - Stats.coins0) or 0
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local lvl = ls and ls:FindFirstChild("Level")
        return ("Session: %dm\nCaught: %d  Missed: %d  (%.1f / min)\n%s: %s  (+%s, %s / hour)\nLevel: %s"):format(
            math.floor(mins), Fish.caught, Fish.missed, Fish.caught / mins,
            currency, c and tostring(c) or "?", tostring(earned), tostring(math.floor(earned / mins * 60)),
            lvl and tostring(lvl.Value) or "?")
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Fisch",
    Footer = "dookie hub · Ui3",
    Icon = "fish",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/Fisch",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
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
local function dropdown(box, key, text, values, tip, searchable)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip, Searchable = searchable,
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

do
    local Tab = Window:AddTab("Fishing", "fish", "Cast, shake, reel")
    local C = Tab:AddLeftGroupbox("Auto cast", "anchor")
    toggle(C, "AutoCast", "Auto cast", "Casts with the game's own cast remote whenever your rod is free")
    toggle(C, "AutoEquip", "Equip your rod", "Pulls your rod out of the backpack if you're not holding it")
    toggle(C, "PerfectCast", "Perfect cast", "Every cast at 97-100% power, counted as perfect")
    slider(C, "CastPower", "Power (not perfect)", 10, 100, 0, "%")
    slider(C, "CastDelay", "Wait before casting", 0, 5, 1, " s")
    slider(C, "StuckReset", "Recast after no bite for", 15, 180, 0, " s")
    status(C, function()
        return ("Now: %s\nCasts: %d"):format(Fish.info, Fish.casts)
    end)

    local S = Tab:AddLeftGroupbox("Auto shake", "hand")
    toggle(S, "AutoShake", "Auto shake", "Sends the shake while the shake button is up")
    slider(S, "ShakeDelay", "Every", 0.1, 1, 2, " s", "The game allows one shake every 0.25s; faster can be thrown away")
    status(S, function()
        return ("Shakes: %d"):format(Fish.shakes)
    end)

    local R = Tab:AddRightGroupbox("Auto reel", "refresh-cw")
    toggle(R, "AutoReel", "Auto reel")
    dropdown(R, "ReelMode", "How", { "Lock bar on fish", "Legit", "Instant" },
        "Lock bar on fish: your bar sits on the fish the whole time (perfect catches). Legit: holds and lets go like a player. Instant: finishes the reel right away (the server may check how long it took)")
    slider(R, "InstantDelay", "Instant: wait first", 0, 10, 1, " s", "How long to wait before finishing. A couple of seconds looks more normal")
    toggle(R, "FastReel", "Faster minigame", "The game's own minigame speed setting, on your side")
    slider(R, "ReelSpeed", "Minigame speed", 1, 5, 1, "x")
    status(R, function()
        return ("Reel: %s\nInstant reels: %d\nCaught: %d  Missed: %d"):format(
            Reel and (activeReel() and "reeling" or "waiting") or "ReelController not found", Fish.reels, Fish.caught, Fish.missed)
    end)
end

do
    local Tab = Window:AddTab("Selling", "dollar-sign", "Auto sell")
    local S = Tab:AddLeftGroupbox("Auto sell", "dollar-sign")
    toggle(S, "AutoSell", "Auto sell", "Goes to the nearest merchant, sells every fish that isn't favourited, and comes back")
    dropdown(S, "SellWhen", "When", { "Worth over", "Every few minutes" })
    slider(S, "SellWorth", "Sell once worth", 500, 500000, 0, " C$")
    slider(S, "SellEvery", "Every", 1, 60, 0, " min")
    toggle(S, "SellAnywhere", "Sell from anywhere", "Uses the game's sell-everything (needs the sell anywhere gamepass)")
    toggle(S, "SellReturn", "Come back after selling")
    S:AddButton({ Text = "Sell now", Func = function()
        task.spawn(Sell.now)
    end })
    status(S, function()
        return ("Now: %s\nSold: %d times\nFish worth: %s C$"):format(Sell.info, Sell.sold, Sell.worth and tostring(Sell.worth) or "?")
    end)
    local St = Tab:AddRightGroupbox("Stats", "bar-chart")
    status(St, Stats.text)
end

do
    local Tab = Window:AddTab("Teleport", "map-pin", "Islands and fast travel")
    local T = Tab:AddLeftGroupbox("Teleport", "map-pin")
    local spots = T:AddDropdown("TpSpot", {
        Text = "Spot", Values = {}, Searchable = true,
        Callback = function(v)
            Settings.TpSpot = v
        end,
    })
    local function refresh()
        local names = Tp.load()
        pcall(function()
            spots:SetValues(names)
        end)
    end
    T:AddButton({ Text = "Go", Func = function()
        Tp.go(Settings.TpSpot)
    end, Tooltip = "Locked zones are watched by the server: going into one you haven't unlocked is risky" })
    T:AddButton({ Text = "Refresh spots", Func = function()
        task.spawn(refresh)
    end })
    task.spawn(refresh)
    local F = Tab:AddRightGroupbox("Fast travel", "wind")
    dropdown(F, "FastTravel", "Place", FAST_TRAVEL, "The game's own fast travel", true)
    F:AddButton({ Text = "Travel", Func = function()
        Tp.fast(Settings.FastTravel)
    end, Tooltip = "Needs the Traveler's Whistle and that place unlocked" })
    status(F, function()
        return Tp.info
    end)
end

do
    local Tab = Window:AddTab("World", "globe", "ESP, chests, meteors")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "EspPools", "Fish pools", "Zones with a boosted fish, and which fish")
    toggle(E, "EspEvents", "Event pools", "Fishing zones that showed up after you joined (events, hunts)")
    toggle(E, "EspChests", "Treasure chests")
    toggle(E, "EspMeteors", "Meteors")
    toggle(E, "EspNpcs", "Merchants and shops")
    local A = Tab:AddRightGroupbox("Collect", "package")
    toggle(A, "AutoChests", "Open treasure chests", "Goes to each loaded chest, opens it, comes back")
    toggle(A, "AutoMeteors", "Grab meteors", "Goes to a landed meteor, picks it up, comes back")
    status(A, function()
        local live = World.events()
        return ("Chests opened: %d\nMeteors: %d\nLive now: %s"):format(World.opened, World.meteors, #live > 0 and table.concat(live, ", ") or "nothing")
    end)
end

do
    local Tab = Window:AddTab("Misc", "settings", "Claims, codes")
    local M = Tab:AddLeftGroupbox("Claims", "gift")
    toggle(M, "AutoDaily", "Claim daily reward")
    toggle(M, "AutoTotem", "Claim crafted totems")
    toggle(M, "AntiAfk", "Anti-AFK")
    status(M, function()
        return Claims.info ~= "" and Claims.info or "Daily reward is tried every 5 minutes"
    end)
    local K = Tab:AddRightGroupbox("Codes", "ticket")
    K:AddInput("Codes", {
        Text = "Codes", Placeholder = "One or more, split by spaces or commas", Default = "", Finished = false,
        Callback = function(t)
            Settings.Codes = t
        end,
    })
    K:AddButton({ Text = "Redeem", Func = function()
        task.spawn(Claims.redeem, Settings.Codes)
    end })
    local U = Tab:AddRightGroupbox("Script", "power")
    U:AddButton({ Text = "Unload", Func = function()
        if Genv.__FischUnload then
            Genv.__FischUnload()
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
Genv.__FischUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

local missing = {}
if not Reel then
    table.insert(missing, "ReelController")
end
if not net("RF/FishingRod/Cast") then
    table.insert(missing, "cast remote")
end
notify("Loaded" .. (#missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or ""), 4)

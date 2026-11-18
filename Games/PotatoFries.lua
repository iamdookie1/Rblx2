--// Potato fries shop (place "Map1") ---------------------------------------------------------
-- place 139542527731344 (game 10767380385), built against version 75. Built on Ui3.
-- A co-op fries shop with a horror night. What the game's client shows:
--   Pile     Workspace.PotatoPile parts; the PileController module (PlayerScripts
--            .Controllers) exports pickNear(center, radius, count, eye, skipColumn)
--            which hands back pile cells { x, y, z, texture }. Hands / buckets take
--            them with RemovePotato(x, y, z, texture, extraCells), vacuums with
--            Vacuum(cells, droppedParts, nozzle). Shared.Stats has carryCapacity,
--            scoop and toolInfo (Vacuums).
--   Carry    player attributes CarryRaw, CarryPeeled, CarryFries, CarryCount.
--   Peel     BeginPeel() -> PeelProgress(0..1) -> FinishPeel(), no sooner than
--            Config.Peel.MinSeconds (2.5 s, 0.5 s with instant peel) after it began.
--   Kitchen  Map.Kitchen.KitchenAppliances: PotatoCrate.BoxPrompt (put / take
--            potatoes), PeelingStation.PeelPrompt, DeepFryer.FryerPrompt (put peeled
--            in, take fries out; FryerReady counts what's done).
--   Sell     DriveThru.Window.WindowPrompt hands fries to the waiting car
--            (DriveThru CarWaiting). Cars are RoutedCar models; a monster car has an
--            Anomaly attribute (a string). ShutterPress() at the ShutterButton
--            toggles the shutter (DriveThru.Shutter ShutterClosed).
--   Night    Shared.DayNight.isNight(clockTime()). Monsters live in
--            Workspace.Anomalies. Power boxes (Workspace.PowerBoxes) break
--            (PowerBroken): FixPowerPrompt claims the box (PowerFixer = you), then
--            PowerCable(box, "Plug", cable) for every cable 1..rows of
--            PowerCables "left/right". Jammed robots take RebootPrompt, a monster at
--            the pile ShooPrompt, a downed player RescuePrompt (held 3 s).
--   Perks    DraftOffer (player attribute, card ids) -> DraftPick(card, DraftId).
--   Shop     Purchase("Upgrade", id) / Purchase("Tool", name); tycoon pads in
--            Workspace.Tycoon.Pads buy what they show when touched.
--   Key      Workspace KeyHolder (user id), KeyPrompt / BasementPrompt at the
--            basement door (Workspace BasementDoor).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__FriesUnload then
    pcall(Genv.__FriesUnload)
end
Genv.__FriesRun = (Genv.__FriesRun or 0) + 1
local RUN = Genv.__FriesRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__FriesRun == RUN
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

local PERKS = {
    { "ExtraLife", "Extra Life" }, { "SharpPeeler", "Instant Peel" }, { "TipJar", "More Cash" }, { "DeepPockets", "Carry More" },
    { "QuickFix", "Fix Power Fast" }, { "ExtraRobot", "+1 Robot" }, { "NightShift", "Night Cash" }, { "Hearty", "More Health" },
    { "QuickFeet", "Walk Faster" }, { "QuickDrop", "Drop Faster" }, { "NightOwl", "Rich at Night" }, { "GoldenGreed", "Golden Vacuum" },
    { "BloodMoney", "Rich but Weak" }, { "Adrenaline", "Fast but Broke" },
}
local UPGRADES = { "BiggerPeel", "PeelAmount", "MoneyMulti", "BucketLevel", "VacuumLevel", "GoldenVacuumLevel", "DiamondVacuumLevel",
    "VipBucketLevel", "CandyBucketLevel" }

local Settings = {
    -- shift
    AutoShift = false, ShiftNight = "Use the crate", AutoPeel = false, PeelTime = 2.7, AutoGrab = false, GrabRange = 9,
    AutoFry = false, AutoServe = false, AutoShutter = false, OpenForCustomers = true, AutoDropped = false,
    -- night
    AutoPower = false, AutoReboot = false, AutoShoo = false, AutoRescue = false, AutoKey = false, JumpInBasement = false,
    MonsterAlert = true, AlertRange = 45, EscapeMonsters = false, EscapeRange = 22,
    -- buying
    AutoPerk = false, AvoidCursed = true, AutoUpgrades = false, UpgradePicks = { BiggerPeel = true, PeelAmount = true, MoneyMulti = true },
    AutoTools = false, AutoPads = false,
    -- esp
    EspMonsters = false, EspCars = false, EspPlayers = false, EspRobots = false, EspPower = false, EspDropped = false, EspDistance = 800,
    -- player
    SpeedOn = false, WalkSpeed = 30, InfJump = false, Fly = false, FlySpeed = 70, Noclip = false, Fullbright = false,
    SkipIntro = false, AntiAfk = true,
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
                warn("[Fries] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Fries", Description = text, Time = seconds or 3 })
end
local function comma(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
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
    return tonumber(LocalPlayer:GetAttribute(name)) or 0
end
local function pivotOf(inst)
    if not (inst and inst.Parent) then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.Position
    end
    if inst:IsA("Attachment") then
        return inst.WorldPosition
    end
    local ok, cf = pcall(inst.GetPivot, inst)
    return ok and cf.Position or nil
end
local function anyPart(inst)
    if inst:IsA("BasePart") then
        return inst
    end
    if inst:IsA("Model") and inst.PrimaryPart then
        return inst.PrimaryPart
    end
    return inst:FindFirstChild("HumanoidRootPart") or inst:FindFirstChild("Head") or inst:FindFirstChildWhichIsA("BasePart", true)
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

--// The game \\--
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
local function remote(name)
    return RemotesFolder and RemotesFolder:FindFirstChild(name)
end
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local function shared(name)
    local m = Shared and Shared:FindFirstChild(name)
    if not m then
        return nil
    end
    local ok, r = pcall(require, m)
    return ok and type(r) == "table" and r or nil
end
local Config = shared("Config")
local Stats = shared("Stats")
local DayNight = shared("DayNight")
local PileLayout = shared("PileLayout")
local function controller(name)
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    local c = ps and ps:FindFirstChild("Controllers")
    local m = c and c:FindFirstChild(name)
    if not m then
        return nil
    end
    local ok, r = pcall(require, m)
    return ok and type(r) == "table" and r or nil
end
local Pile = controller("PileController")

local Game = {}
function Game.kitchen(name)
    local m = Workspace:FindFirstChild("Map")
    local k = m and m:FindFirstChild("Kitchen")
    local a = k and k:FindFirstChild("KitchenAppliances")
    return a and a:FindFirstChild(name)
end
function Game.prompt(container, name)
    local p = container and container:FindFirstChild(name, true)
    return p and p:IsA("ProximityPrompt") and p or nil
end
function Game.driveThru()
    return Workspace:FindFirstChild("DriveThru")
end
function Game.isNight()
    if DayNight and type(DayNight.isNight) == "function" and type(DayNight.clockTime) == "function" then
        local ok, night = pcall(function()
            return DayNight.isNight(DayNight.clockTime())
        end)
        if ok then
            return night == true
        end
    end
    return false
end
function Game.capacity()
    if Stats and type(Stats.carryCapacity) == "function" then
        local ok, n = pcall(Stats.carryCapacity, LocalPlayer)
        if ok and tonumber(n) then
            return n
        end
    end
    return 1
end
function Game.space()
    return math.max(0, Game.capacity() - attr("CarryCount"))
end
function Game.scoop()
    if Stats and type(Stats.scoop) == "function" then
        local ok, n = pcall(Stats.scoop, LocalPlayer)
        if ok and tonumber(n) then
            return math.max(1, n)
        end
    end
    return 1
end
function Game.hasVacuum()
    if Stats and type(Stats.toolInfo) == "function" then
        local ok, info = pcall(Stats.toolInfo, LocalPlayer)
        return ok and type(info) == "table" and info.Vacuums and true or false
    end
    return tostring(LocalPlayer:GetAttribute("Tool") or ""):find("Vacuum") ~= nil
end
function Game.downed(plr)
    return typeof(plr:GetAttribute("DownedUntil")) == "number"
end
function Game.peelMin()
    local p = Config and Config.Peel
    return (type(p) == "table" and tonumber(p.MinSeconds)) or 2.5
end
function Game.fryerReady()
    local f = Game.kitchen("DeepFryer")
    return f and tonumber(f:GetAttribute("FryerReady")) or 0
end
function Game.crateCount()
    local c = Game.kitchen("PotatoCrate")
    return c and tonumber(c:GetAttribute("BoxCount")) or 0
end
function Game.shutterClosed()
    local d = Game.driveThru()
    local s = d and d:FindFirstChild("Shutter")
    return s and s:GetAttribute("ShutterClosed") == true
end

-- Monster cars: a car that ever had an Anomaly attribute stays a monster.
local Cars = { monsters = setmetatable({}, { __mode = "k" }) }
function Cars.kind(car)
    local a = car:GetAttribute("Anomaly")
    if typeof(a) == "string" and a ~= "" then
        Cars.monsters[car] = a
    end
    return Cars.monsters[car]
end
function Cars.atWindow()
    local d = Game.driveThru()
    local window = d and d:FindFirstChild("Window")
    if not window then
        return nil
    end
    local best, bestD
    for _, car in CollectionService:GetTagged("RoutedCar") do
        local pos = pivotOf(car)
        if pos then
            local dist = (pos - window.Position).Magnitude
            if dist <= 30 and (not bestD or dist < bestD) then
                best, bestD = car, dist
            end
        end
    end
    return best
end
loop(0.5, function()
    for _, car in CollectionService:GetTagged("RoutedCar") do
        Cars.kind(car)
    end
end)

-- Monsters: Workspace.Anomalies, except the ones that are vanishing or are a role.
local Monsters = {}
function Monsters.list()
    local out = {}
    local f = Workspace:FindFirstChild("Anomalies")
    if f then
        for _, m in f:GetChildren() do
            if m:IsA("Model") and m:GetAttribute("Role") == nil and m:GetAttribute("State") ~= "Vanish" then
                table.insert(out, m)
            end
        end
    end
    return out
end
function Monsters.nearest(pos)
    local best, bestD
    for _, m in Monsters.list() do
        local p = pivotOf(m)
        if p then
            local d = (p - pos).Magnitude
            if not bestD or d < bestD then
                best, bestD = m, d
            end
        end
    end
    return best, bestD
end

--// Moving and prompts \\--
local Busy = { reason = nil }
-- Jobs that need you somewhere else (a power box, a robot, the key): run now,
-- or right after the current step when the auto shift is going.
local Queue = {}
local function runJob(key, fn)
    if Settings.AutoShift then
        Queue[key] = Queue[key] or fn
    elseif not Busy.reason then
        local ok, err = pcall(fn)
        if not ok then
            warn("[Fries] " .. tostring(err))
        end
    end
end
local Move = {}
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local function floor(pos, ignore)
        local list = { myChar() }
        if ignore then
            table.insert(list, ignore)
        end
        params.FilterDescendantsInstances = list
        local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -25, 0), params)
        return hit and hit.Position or nil
    end
    function Move.to(pos)
        local root = myRoot()
        if not (root and pos) then
            return false
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(pos) * root.CFrame.Rotation
        return true
    end
    -- Stand `gap` studs from something, on the floor, facing it.
    function Move.near(target, gap, ignore)
        local root = myRoot()
        local pos = typeof(target) == "Vector3" and target or pivotOf(target)
        if not (root and pos) then
            return false
        end
        local away = root.Position - pos
        away = Vector3.new(away.X, 0, away.Z)
        away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
        local spot = pos + away * (gap or 3)
        local f = floor(spot, ignore or (typeof(target) == "Instance" and target or nil))
        spot = f and (f + Vector3.new(0, 3, 0)) or spot
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.lookAt(spot, Vector3.new(pos.X, spot.Y, pos.Z))
        return true
    end
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
            warn("[Fries] " .. tostring(err))
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
end

-- A prompt, used like a player does: make sure it shows, hold it, let go.
local shown = setmetatable({}, { __mode = "k" })
do
    local PromptService = game:GetService("ProximityPromptService")
    bind(PromptService.PromptShown, function(p)
        shown[p] = true
    end)
    bind(PromptService.PromptHidden, function(p)
        shown[p] = nil
    end)
end
local function usePrompt(p)
    if not (p and p.Parent) then
        return false
    end
    -- The game switches prompts off on your side (the tutorial shows one at a
    -- time); the server still has them on, so it's switched on for the use.
    local wasOff = not p.Enabled
    if wasOff then
        p.Enabled = true
    end
    local dist, los, excl = p.MaxActivationDistance, p.RequiresLineOfSight, p.Exclusivity
    if p.MaxActivationDistance < 10 then
        p.MaxActivationDistance = 10
    end
    p.RequiresLineOfSight = false
    p.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
    local fired = false
    local conn = p.Triggered:Connect(function()
        fired = true
    end)
    local t0 = os.clock()
    while not shown[p] and os.clock() - t0 < 0.4 and p.Parent do
        RunService.Heartbeat:Wait()
    end
    pcall(p.InputHoldBegin, p)
    local h0 = os.clock()
    while not fired and os.clock() - h0 < p.HoldDuration + 0.1 and p.Parent do
        RunService.Heartbeat:Wait()
    end
    pcall(p.InputHoldEnd, p)
    if not fired and p.Parent and typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, p)
        task.wait(0.1)
    end
    conn:Disconnect()
    if p.Parent then
        if p.MaxActivationDistance == 10 and dist < 10 then
            p.MaxActivationDistance = dist
        end
        p.RequiresLineOfSight, p.Exclusivity = los, excl
        if wasOff then
            p.Enabled = false
        end
    end
    return fired
end

--// Work: grab, peel, fry, serve, shutter \\--
local Work = { info = "", peeled = 0, served = 0, grabbed = 0, shutters = 0 }
do
    local removePotato, vacuum = remote("RemovePotato"), remote("Vacuum")
    local beginPeel, peelProgress, finishPeel = remote("BeginPeel"), remote("PeelProgress"), remote("FinishPeel")
    local shutterPress = remote("ShutterPress")

    function Work.pileNear(pos, radius)
        local f = Workspace:FindFirstChild("PotatoPile")
        if not f then
            return nil
        end
        local best, bestD
        for _, p in f:GetChildren() do
            if p:IsA("BasePart") then
                local d = (p.Position - pos).Magnitude
                if d <= (radius or math.huge) and (not bestD or d < bestD) then
                    best, bestD = p, d
                end
            end
        end
        return best, bestD
    end

    -- Grab potatoes from the pile within reach, as many as the tool scoops.
    function Work.grab()
        if not (Pile and type(Pile.pickNear) == "function") then
            Work.info = "the pile controller isn't loaded"
            return 0
        end
        local root, char = myRoot(), myChar()
        local head = char and char:FindFirstChild("Head")
        if not (root and head) or LocalPlayer:GetAttribute("PotatoBusy") == true then
            return 0
        end
        local space = Game.space()
        if space <= 0 then
            return 0
        end
        local eye = head.Position
        if Game.hasVacuum() then
            if not vacuum then
                return 0
            end
            local list = Pile.pickNear(root.Position, Settings.GrabRange, math.min(space, 12), eye)
            if #list == 0 then
                return 0
            end
            local cells = {}
            for _, e in list do
                table.insert(cells, e.cell)
            end
            vacuum:FireServer(cells, {}, root.Position + root.CFrame.LookVector * 2)
            Work.grabbed += #cells
            return #cells
        end
        if not removePotato then
            return 0
        end
        local first = Pile.pickNear(root.Position, Settings.GrabRange, 1, eye)[1]
        if not first then
            return 0
        end
        local c = first.cell
        local extras = {}
        local more = math.min(Game.scoop(), space) - 1
        if more > 0 and PileLayout and type(PileLayout.packKey) == "function" then
            local radius = (Config and Config.Pile and tonumber(Config.Pile.ScoopRadius)) or 2.5
            for _, e in Pile.pickNear(first.cframe.Position, radius, more, eye, PileLayout.packKey(c[1], c[3])) do
                table.insert(extras, e.cell)
            end
        end
        removePotato:FireServer(c[1], c[2], c[3], c[4], #extras > 0 and extras or nil)
        Work.grabbed += 1 + #extras
        return 1 + #extras
    end

    -- One peel: begin, report progress over the time set, finish.
    function Work.peel()
        if not (beginPeel and peelProgress and finishPeel) then
            return false, "peel remotes not found"
        end
        local ok, started, reason = pcall(beginPeel.InvokeServer, beginPeel)
        if not (ok and started == true) then
            return false, typeof(reason) == "string" and reason or "can't peel"
        end
        local total = math.max(Settings.PeelTime, 0.6)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < total do
            task.wait(0.15)
            peelProgress:FireServer(math.min(0.97, (os.clock() - t0) / total))
        end
        peelProgress:FireServer(1)
        task.wait(0.2)
        finishPeel:FireServer()
        local w0 = os.clock()
        while os.clock() - w0 < 2 and attr("Peeling") > 0 do
            task.wait(0.1)
        end
        Work.peeled += 1
        return true
    end
    function Work.canPeel()
        return attr("CarryRaw") > 0 or (Game.crateCount() > 0 and attr("CarryCount") == 0)
    end

    -- The fryer: a use that changes nothing (full, still cooking) waits a bit.
    local fryerWaitUntil, windowWaitUntil = 0, 0
    function Work.fry()
        local fryer = Game.kitchen("DeepFryer")
        local before = attr("CarryPeeled") * 1000 + attr("CarryFries")
        usePrompt(Game.prompt(fryer, "FryerPrompt"))
        task.wait(0.4)
        local changed = attr("CarryPeeled") * 1000 + attr("CarryFries") ~= before
        if not changed then
            fryerWaitUntil = os.clock() + 3
        end
        return changed
    end
    function Work.wantsFryer()
        if os.clock() < fryerWaitUntil then
            return false
        end
        return attr("CarryPeeled") > 0 or (Game.fryerReady() > 0 and Game.space() > 0)
    end
    function Work.takeFromCrate()
        return usePrompt(Game.prompt(Game.kitchen("PotatoCrate"), "BoxPrompt"))
    end

    -- A normal car is waiting at an open window.
    function Work.customer()
        if os.clock() < windowWaitUntil then
            return nil
        end
        local d = Game.driveThru()
        if not (d and d:GetAttribute("CarWaiting") == true) then
            return nil
        end
        local car = Cars.atWindow()
        if car and Cars.kind(car) then
            return nil
        end
        return car or true
    end
    function Work.serve()
        local d = Game.driveThru()
        local window = d and d:FindFirstChild("Window")
        local before = attr("CarryFries")
        usePrompt(window and window:FindFirstChildOfClass("ProximityPrompt"))
        task.wait(0.4)
        local ok = attr("CarryFries") < before
        if ok then
            Work.served += 1
        else
            windowWaitUntil = os.clock() + 2
        end
        return ok
    end

    -- The shutter: closed for monster cars, open for customers.
    function Work.pressShutter()
        local d = Game.driveThru()
        local button = d and d:FindFirstChild("ShutterButton")
        if not (button and shutterPress) then
            return false
        end
        local root = myRoot()
        local pos = pivotOf(button)
        if not (root and pos) then
            return false
        end
        if (root.Position - pos).Magnitude <= 4 then
            shutterPress:FireServer()
        else
            -- Straight there and back, even in the middle of something else.
            local home = root.CFrame
            Move.near(button, 2.5)
            task.wait(0.15)
            shutterPress:FireServer()
            task.wait(0.2)
            local r = myRoot()
            if r then
                r.AssemblyLinearVelocity = Vector3.zero
                r.CFrame = home
            end
        end
        Work.shutters += 1
        return true
    end
    loop(0.25, function()
        if not Settings.AutoShutter then
            return
        end
        local car = Cars.atWindow()
        local monster = car and Cars.kind(car)
        if monster and not Game.shutterClosed() and tryOnce("shutter", 1.5) then
            Work.info = "monster car (" .. tostring(monster) .. "): closing the shutter"
            Work.pressShutter()
        elseif Settings.OpenForCustomers and Game.shutterClosed() and not monster then
            local d = Game.driveThru()
            if d and d:GetAttribute("CarWaiting") == true and tryOnce("shutter", 2) then
                Work.info = "customer waiting: opening the shutter"
                Work.pressShutter()
            end
        end
    end)

    -- Auras: each one works while you're close enough.
    local function near(inst, range)
        local root, pos = myRoot(), pivotOf(inst)
        return root and pos and (root.Position - pos).Magnitude <= range
    end
    loop(0.2, function()
        if Busy.reason or Settings.AutoShift then
            return
        end
        if Settings.AutoGrab and Game.space() > 0 then
            Work.grab()
        end
    end)
    loop(0.3, function()
        if Busy.reason or Settings.AutoShift then
            return
        end
        if Settings.AutoPeel and Work.canPeel() and near(Game.kitchen("PeelingStation"), 10) then
            Busy.reason = "peeling"
            local ok, done, why = pcall(Work.peel)
            Busy.reason = nil
            if not ok or not done then
                Work.info = "peel: " .. tostring(ok and why or done)
                task.wait(1)
            end
        end
        if Settings.AutoFry and Work.wantsFryer() and near(Game.kitchen("DeepFryer"), 10) and tryOnce("fry", 0.8) then
            Work.fry()
        end
        if Settings.AutoServe and attr("CarryFries") > 0 and Work.customer() then
            local d = Game.driveThru()
            if near(d and d:FindFirstChild("Window"), 10) and tryOnce("serve", 1) then
                Work.serve()
            end
        end
    end)

    -- Dropped potatoes and fries next to you.
    local pickup = remote("PickupDropped")
    loop(0.3, function()
        if not (Settings.AutoDropped and pickup) then
            return
        end
        local root = myRoot()
        local f = Workspace:FindFirstChild("DroppedPotatoes")
        if not (root and f) or Game.space() <= 0 then
            return
        end
        for _, p in f:GetChildren() do
            if p:IsA("BasePart") and (p.Position - root.Position).Magnitude <= 9 and tryOnce(p, 1.5) then
                pickup:FireServer(p)
                break
            end
        end
    end)
end

--// The whole shift \\--
local Shift = { info = "off" }
do
    local function goTo(inst, gap)
        if inst then
            Move.near(inst, gap or 3)
            task.wait(0.2)
        end
    end
    local function pileSpot()
        local station = Game.kitchen("PeelingStation")
        local from = pivotOf(station) or (myRoot() and myRoot().Position)
        return from and Work.pileNear(from)
    end
    function Shift.step()
        local raw, peeled, fries = attr("CarryRaw"), attr("CarryPeeled"), attr("CarryFries")
        local d = Game.driveThru()
        if fries > 0 and Work.customer() then
            Shift.info = "serving a car"
            goTo(d and d:FindFirstChild("Window"), 3)
            Work.serve()
            return
        end
        if Work.wantsFryer() then
            Shift.info = peeled > 0 and "frying" or "taking fries"
            goTo(Game.kitchen("DeepFryer"), 3)
            Work.fry()
            task.wait(0.3)
            return
        end
        if Work.canPeel() and (raw > 0 or fries == 0) then
            Shift.info = "peeling"
            goTo(Game.kitchen("PeelingStation"), 2.5)
            local ok, why = Work.peel()
            if not ok then
                Shift.info = "peel: " .. tostring(why)
                task.wait(0.5)
            end
            return
        end
        if fries > 0 and Game.space() <= 0 then
            Shift.info = "waiting for a car"
            goTo(d and d:FindFirstChild("Window"), 3)
            task.wait(0.5)
            return
        end
        if Game.isNight() and Settings.ShiftNight ~= "Keep going outside" then
            if Game.crateCount() > 0 and attr("CarryCount") == 0 then
                Shift.info = "night: taking potatoes from the crate"
                goTo(Game.kitchen("PotatoCrate"), 3)
                Work.takeFromCrate()
            else
                Shift.info = "night: waiting inside"
                goTo(Game.kitchen("PeelingStation"), 3)
                task.wait(1)
            end
            return
        end
        local spot = pileSpot()
        if not spot then
            Shift.info = "no potatoes left in the pile"
            task.wait(1)
            return
        end
        Shift.info = "grabbing potatoes"
        Move.near(spot, 3.5, Workspace:FindFirstChild("PotatoPile"))
        task.wait(0.25)
        for _ = 1, 6 do
            if Game.space() <= 0 or not Settings.AutoShift then
                break
            end
            if Work.grab() == 0 then
                break
            end
            task.wait(0.25)
        end
    end
    loop(0.15, function()
        if not Settings.AutoShift then
            Shift.info = "off"
            return
        end
        if Busy.reason then
            return
        end
        local hum = myHum()
        if not hum or hum.Health <= 0 or Game.downed(LocalPlayer) then
            Shift.info = "waiting (downed or dead)"
            return
        end
        local key, job = next(Queue)
        if key then
            Queue[key] = nil
            Shift.info = "doing: " .. tostring(key)
            local ok, err = pcall(job)
            if not ok then
                warn("[Fries] " .. tostring(err))
            end
            return
        end
        Busy.reason = "shift"
        local ok, err = pcall(Shift.step)
        Busy.reason = nil
        if not ok then
            Shift.info = "error: " .. tostring(err)
            task.wait(1)
        end
    end)
end

--// Night: power, robots, monsters, rescue, key \\--
local Night = { fixed = 0, reboots = 0, shoos = 0, rescues = 0, info = "" }
do
    local powerCable = remote("PowerCable")
    local function plugged(box)
        local set = {}
        local s = box:GetAttribute("PowerPlugged")
        if typeof(s) == "string" then
            for d in s:gmatch("%d") do
                set[tonumber(d)] = true
            end
        end
        return set
    end
    function Night.fix(box)
        local prompt = Game.prompt(box, "FixPowerPrompt")
        if not (prompt and powerCable) then
            return false
        end
        local done = false
        Move.trip("fixing the power", function()
            Move.near(prompt.Parent, 2.5)
            task.wait(0.2)
            usePrompt(prompt)
            local t0 = os.clock()
            while os.clock() - t0 < 2.5 and box:GetAttribute("PowerFixer") ~= LocalPlayer.UserId do
                task.wait(0.1)
            end
            if box:GetAttribute("PowerFixer") ~= LocalPlayer.UserId then
                Night.info = "someone else is fixing that box"
                return
            end
            local layout = box:GetAttribute("PowerCables")
            local left = typeof(layout) == "string" and layout:match("^(%d+)/%d+$")
            local rows = left and #left or 0
            local have = plugged(box)
            for cable = 1, rows do
                if not have[cable] then
                    powerCable:FireServer(box, "Plug", cable)
                    task.wait(0.25)
                end
            end
            local w0 = os.clock()
            while os.clock() - w0 < 3 and box:GetAttribute("PowerBroken") == true do
                task.wait(0.1)
            end
            done = box:GetAttribute("PowerBroken") ~= true
            if not done then
                powerCable:FireServer(box, "Close")
            end
        end)
        if done then
            Night.fixed += 1
        end
        return done
    end
    loop(1, function()
        if not Settings.AutoPower then
            return
        end
        local f = Workspace:FindFirstChild("PowerBoxes")
        if not f then
            return
        end
        for _, box in f:GetChildren() do
            if box:GetAttribute("PowerBroken") == true and tryOnce(box, 6) then
                runJob("fix power", function()
                    Night.info = "fixing " .. box.Name
                    Night.fix(box)
                end)
            end
        end
    end)

    -- Any prompt with this name somewhere in a folder: go to it and use it.
    local function fireAll(folder, name, key, label)
        if not folder then
            return
        end
        for _, d in folder:GetDescendants() do
            if d.Name == name and d:IsA("ProximityPrompt") and d.Enabled and tryOnce(d, 4) and not Busy.reason then
                local okTrip = Move.trip(label, function()
                    Move.near(d.Parent, 2.5)
                    task.wait(0.2)
                    if usePrompt(d) then
                        Night[key] += 1
                    end
                end)
                if okTrip then
                    return
                end
            end
        end
    end
    loop(1, function()
        if Settings.AutoReboot then
            runJob("reboot a robot", function()
                fireAll(Workspace:FindFirstChild("Robots"), "RebootPrompt", "reboots", "rebooting a robot")
            end)
        end
        if Settings.AutoShoo then
            runJob("scare a monster off", function()
                fireAll(Workspace:FindFirstChild("Anomalies"), "ShooPrompt", "shoos", "scaring a monster off")
                fireAll(Workspace:FindFirstChild("PotatoPile"), "ShooPrompt", "shoos", "scaring a monster off")
            end)
        end
        if Settings.AutoRescue then
            for _, plr in Players:GetPlayers() do
                if plr ~= LocalPlayer and Game.downed(plr) and plr.Character then
                    runJob("help " .. plr.DisplayName, function()
                        fireAll(plr.Character, "RescuePrompt", "rescues", "helping " .. plr.DisplayName .. " up")
                    end)
                end
            end
        end
    end)

    -- Monster warnings and running inside.
    local inside = RaycastParams.new()
    inside.FilterType = Enum.RaycastFilterType.Exclude
    local function outdoors(root)
        inside.FilterDescendantsInstances = { myChar() }
        return Workspace:Raycast(root.Position, Vector3.new(0, 60, 0), inside) == nil
    end
    loop(0.3, function()
        local root = myRoot()
        if not root then
            return
        end
        local m, d = Monsters.nearest(root.Position)
        Night.nearest = m and d
        if not m then
            return
        end
        if Settings.MonsterAlert and d <= Settings.AlertRange and tryOnce("monsteralert", 6) then
            notify(("A monster is %d studs away!"):format(math.floor(d)), 3)
        end
        if Settings.EscapeMonsters and d <= Settings.EscapeRange and outdoors(root) and tryOnce("escape", 1) then
            local station = Game.kitchen("PeelingStation")
            if station then
                Move.near(station, 3)
                notify("Ran inside from a monster", 2)
            end
        end
    end)

    -- The basement key.
    local function useKey()
        local spot = Workspace:GetAttribute("BasementDoor")
        local m = Workspace:FindFirstChild("Map")
        local door = m and m:FindFirstChild("BasementDoor")
        local keyPrompt = Game.prompt(door, "KeyPrompt")
        Move.trip("opening the basement", function()
            if typeof(spot) == "Vector3" then
                Move.near(spot, 3)
            elseif keyPrompt then
                Move.near(keyPrompt.Parent, 3)
            end
            task.wait(0.3)
            if keyPrompt then
                usePrompt(keyPrompt)
            end
            task.wait(0.5)
            if Settings.JumpInBasement then
                usePrompt(Game.prompt(door, "BasementPrompt"))
            end
        end, not Settings.JumpInBasement)
    end
    Night.useKey = useKey
    loop(1, function()
        if Settings.AutoKey and Workspace:GetAttribute("KeyHolder") == LocalPlayer.UserId and tryOnce("key", 8) then
            runJob("use the key", useKey)
        end
    end)
end

--// Buying \\--
local Buy = { info = "" }
do
    local draftPick, purchase, equipTool = remote("DraftPick"), remote("Purchase"), remote("EquipTool")
    local cursed = { NightOwl = true, GoldenGreed = true, BloodMoney = true, Adrenaline = true }
    local function offer()
        local out = {}
        local s = LocalPlayer:GetAttribute("DraftOffer")
        if typeof(s) == "string" then
            for _, id in s:split(",") do
                if id ~= "" then
                    out[id] = true
                end
            end
        end
        return out
    end
    function Buy.pickPerk()
        local cards = offer()
        if not (next(cards) and draftPick) then
            return false
        end
        local choice
        for _, p in PERKS do
            if cards[p[1]] and not (Settings.AvoidCursed and cursed[p[1]]) then
                choice = p
                break
            end
        end
        if not choice then
            for _, p in PERKS do
                if cards[p[1]] then
                    choice = p
                    break
                end
            end
        end
        if not choice then
            return false
        end
        local ok, picked = pcall(draftPick.InvokeServer, draftPick, choice[1], LocalPlayer:GetAttribute("DraftId"))
        if ok and picked == true then
            Buy.info = "picked " .. choice[2]
            notify("Perk: " .. choice[2], 3)
            return true
        end
        return false
    end
    loop(1, function()
        if Settings.AutoPerk and next(offer()) and tryOnce("perk", 2) then
            Buy.pickPerk()
        end
    end)

    loop(4, function()
        if Settings.AutoUpgrades and purchase then
            for _, id in UPGRADES do
                if Settings.UpgradePicks[id] and tryOnce("up" .. id, 8) then
                    local ok, bought = pcall(purchase.InvokeServer, purchase, "Upgrade", id)
                    if ok and bought == true then
                        Buy.info = "bought " .. id
                    end
                end
            end
        end
        if Settings.AutoTools and purchase then
            local money = attr("Money")
            for _, tool in { { "Bucket", 100 }, { "Vacuum", 1000 } } do
                if LocalPlayer:GetAttribute("Owns_" .. tool[1]) ~= true and money >= tool[2] and tryOnce("tool" .. tool[1], 10) then
                    local ok, bought = pcall(purchase.InvokeServer, purchase, "Tool", tool[1])
                    if ok and bought == true then
                        Buy.info = "bought the " .. tool[1]
                        if equipTool then
                            pcall(equipTool.InvokeServer, equipTool, tool[1])
                        end
                    end
                end
            end
        end
        if Settings.AutoPads then
            local t = Workspace:FindFirstChild("Tycoon")
            local pads = t and t:FindFirstChild("Pads")
            local root = myRoot()
            if pads and root and typeof(firetouchinterest) == "function" then
                for _, pad in pads:GetChildren() do
                    local trigger = pad:FindFirstChild("Trigger", true)
                    if trigger and trigger:IsA("BasePart") and t:GetAttribute("Owned_" .. pad.Name) ~= true and tryOnce(pad, 8) then
                        pcall(firetouchinterest, root, trigger, 0)
                        task.wait()
                        pcall(firetouchinterest, root, trigger, 1)
                    end
                end
            end
        end
    end)
end

--// Player: speed, fly, noclip, light, skips \\--
do
    local flyForce
    local function stopFly()
        if flyForce then
            flyForce:Destroy()
            flyForce = nil
        end
    end
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local root, hum = myRoot(), myHum()
        if not (root and hum) then
            stopFly()
            return
        end
        if Settings.SpeedOn and hum.WalkSpeed ~= Settings.WalkSpeed then
            hum.WalkSpeed = Settings.WalkSpeed
        end
        if Settings.Fly and hum.Health > 0 then
            if not (flyForce and flyForce.Parent == root) then
                stopFly()
                flyForce = Instance.new("BodyVelocity")
                flyForce.MaxForce = Vector3.one * 1e9
                flyForce.P = 1e4
                flyForce.Parent = root
            end
            local cam = Workspace.CurrentCamera
            local md = hum.MoveDirection
            local v = Vector3.zero
            if md.Magnitude > 0.05 and cam then
                local look = cam.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                if flat.Magnitude > 1e-3 then
                    flat = flat.Unit
                    local right = flat:Cross(Vector3.yAxis)
                    v = look * md:Dot(flat) + right * md:Dot(right)
                else
                    v = md
                end
            end
            if not UserInputService:GetFocusedTextBox() then
                if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
                    v += Vector3.yAxis
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
                    v -= Vector3.yAxis
                end
            end
            if v.Magnitude > 1 then
                v = v.Unit
            end
            flyForce.Velocity = v * Settings.FlySpeed
        else
            stopFly()
        end
    end)
    table.insert(Cleanups, stopFly)

    local noclipped = {}
    bind(RunService.Stepped, function()
        local c = myChar()
        if Settings.Noclip and c and alive() then
            for _, p in c:GetDescendants() do
                if p:IsA("BasePart") and p.CanCollide then
                    noclipped[p] = true
                    p.CanCollide = false
                end
            end
        elseif next(noclipped) then
            for p in noclipped do
                if p.Parent then
                    p.CanCollide = true
                end
            end
            table.clear(noclipped)
        end
    end)
    bind(UserInputService.JumpRequest, function()
        local hum = myHum()
        if Settings.InfJump and hum and hum.Health > 0 and alive() then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)

    local saved
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        if Settings.Fullbright then
            saved = saved or {
                Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            }
            Lighting.Brightness = 2
            Lighting.ClockTime = 14
            Lighting.FogEnd = 1e6
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(170, 170, 170)
            Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
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

    local introSkip = remote("IntroSkip")
    loop(1, function()
        if Settings.SkipIntro and introSkip and LocalPlayer:GetAttribute("IntroPlaying") == true and tryOnce("intro", 3) then
            introSkip:FireServer()
        end
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
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
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
        local part = anyPart(adornee)
        if not part then
            return
        end
        local bb = Instance.new("BillboardGui")
        bb.AlwaysOnTop = true
        bb.Size = UDim2.fromOffset(200, 30)
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
            hl.FillTransparency = 0.65
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = folder
        end
        marks[key] = { bb = bb, hl = hl, label = label, adornee = adornee, seen = true }
    end
    loop(0.25, function()
        for _, m in marks do
            m.seen = false
        end
        local root = myRoot()
        local function dist(pos)
            return root and pos and math.floor((pos - root.Position).Magnitude) or 0
        end
        local function inRange(pos)
            return dist(pos) <= Settings.EspDistance
        end
        if Settings.EspMonsters then
            for _, m in Monsters.list() do
                local pos = pivotOf(m)
                if inRange(pos) then
                    mark(m, m, Color3.fromRGB(255, 50, 50), ("%s [%dm]"):format(m.Name, dist(pos)), true)
                end
            end
        end
        if Settings.EspCars then
            for _, car in CollectionService:GetTagged("RoutedCar") do
                local monster = Cars.kind(car)
                local pos = pivotOf(car)
                if monster and inRange(pos) then
                    mark(car, car, Color3.fromRGB(255, 120, 40), ("MONSTER CAR (%s) [%dm]"):format(tostring(monster), dist(pos)), true)
                end
            end
        end
        if Settings.EspPlayers then
            for _, plr in Players:GetPlayers() do
                local c = plr ~= LocalPlayer and plr.Character
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local down = Game.downed(plr)
                    mark(plr, c, down and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(120, 200, 255),
                        ("%s%s [%dm]"):format(plr.DisplayName, down and " (DOWNED)" or "", dist(hrp.Position)), false)
                end
            end
        end
        if Settings.EspRobots then
            local f = Workspace:FindFirstChild("Robots")
            for _, r in f and f:GetChildren() or {} do
                if r:GetAttribute("Jammed") == true then
                    mark(r, r, Color3.fromRGB(255, 160, 60), ("Robot jammed [%dm]"):format(dist(pivotOf(r))), true)
                end
            end
        end
        if Settings.EspPower then
            local f = Workspace:FindFirstChild("PowerBoxes")
            for _, b in f and f:GetChildren() or {} do
                if b:GetAttribute("PowerBroken") == true then
                    mark(b, b, Color3.fromRGB(255, 230, 60), ("Power box broken [%dm]"):format(dist(pivotOf(b))), true)
                end
            end
        end
        if Settings.EspDropped then
            for _, name in { "DroppedPotatoes", "DroppedItems" } do
                local f = Workspace:FindFirstChild(name)
                for _, p in f and f:GetChildren() or {} do
                    local pos = pivotOf(p)
                    if inRange(pos) then
                        mark(p, p, Color3.fromRGB(200, 255, 150), ("%s [%dm]"):format(p.Name, dist(pos)), false)
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
end

--// Dashboard \\--
local function dashboard()
    local day = Workspace:GetAttribute("DayNumber") or "?"
    local night = Game.isNight()
    local car = Cars.atWindow()
    local monster = car and Cars.kind(car)
    local d = Game.driveThru()
    local carText = monster and ("MONSTER (" .. tostring(monster) .. ")") or (d and d:GetAttribute("CarWaiting") == true and "customer waiting") or "none"
    local holder = Workspace:GetAttribute("KeyHolder")
    local holderName = "-"
    if typeof(holder) == "number" and holder ~= 0 then
        local p = Players:GetPlayerByUserId(holder)
        holderName = p and p.DisplayName or tostring(holder)
    end
    return table.concat({
        ("Day %s · %s · review %s stars"):format(tostring(day), night and "NIGHT" or "day", tostring(Workspace:GetAttribute("ReviewStars") or "?")),
        ("Money $%s · lives %d · run $%s"):format(comma(attr("Money")), attr("Lives"), comma(attr("Run_Money"))),
        ("Carrying: %d raw, %d peeled, %d fries (%d / %d)"):format(attr("CarryRaw"), attr("CarryPeeled"), attr("CarryFries"), attr("CarryCount"), Game.capacity()),
        ("Fryer ready: %d · crate: %d · pile: %s / %s"):format(Game.fryerReady(), Game.crateCount(), comma(Workspace:GetAttribute("PileLeft")), comma(Workspace:GetAttribute("PileTotal"))),
        ("Window: %s · shutter %s"):format(carText, Game.shutterClosed() and "closed" or "open"),
        ("Power boxes broken: %s · key: %s (%s)"):format(tostring(Workspace:GetAttribute("PowerBoxes") or 0), tostring(Workspace:GetAttribute("KeyState") or "?"), holderName),
        Night.nearest and ("Nearest monster: %d studs"):format(math.floor(Night.nearest)) or "No monsters out",
    }, "\n")
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Fries",
    Footer = "dookie hub · Ui3",
    Icon = "utensils",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/PotatoFries",
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
            task.wait(0.4)
        end
    end)
end
local function goButton(box, text, fn)
    box:AddButton({ Text = text, Func = function()
        task.spawn(fn)
    end })
end

do
    local Tab = Window:AddTab("Shift", "utensils", "Grab, peel, fry, serve")
    local A = Tab:AddLeftGroupbox("Full auto", "play")
    toggle(A, "AutoShift", "Auto shift", "Does the whole job: grabs potatoes, peels them, fries them, takes the fries and hands them to cars")
    dropdown(A, "ShiftNight", "At night", { "Use the crate", "Keep going outside" },
        "Use the crate: stays inside and peels what's in the potato crate. The pile is outdoors")
    status(A, function()
        return ("Now: %s\nPeeled %d · served %d · grabbed %d"):format(Shift.info, Work.peeled, Work.served, Work.grabbed)
    end)
    local W = Tab:AddLeftGroupbox("By hand, but faster", "hand")
    toggle(W, "AutoGrab", "Grab potatoes", "Takes potatoes from the pile in reach, as many as your tool scoops")
    slider(W, "GrabRange", "Grab reach", 3, 12, 0, " studs")
    toggle(W, "AutoPeel", "Auto peel", "Peels every potato you carry (or the crate's) while you're at the peeling station")
    slider(W, "PeelTime", "Peel time", 0.6, 6, 1, " s", "The server wants at least 2.5 s a potato (0.5 s with instant peel)")
    toggle(W, "AutoFry", "Auto fryer", "Puts peeled potatoes in and takes the fries out while you're at the fryer")
    toggle(W, "AutoServe", "Auto serve", "Hands fries to the car at the window (never a monster car)")
    toggle(W, "AutoDropped", "Pick up dropped potatoes and fries")
    local S = Tab:AddRightGroupbox("Drive-thru", "car")
    toggle(S, "AutoShutter", "Shut out monster cars", "Presses the shutter button the moment a monster car is at the window")
    toggle(S, "OpenForCustomers", "Open it again for customers")
    goButton(S, "Press the shutter", Work.pressShutter)
    status(S, function()
        return ("Shutter pressed %d times\n%s"):format(Work.shutters, Work.info ~= "" and Work.info or "-")
    end)
    local D = Tab:AddRightGroupbox("Dashboard", "layout-dashboard")
    status(D, dashboard)
end

do
    local Tab = Window:AddTab("Night", "moon", "Power, robots, monsters, key")
    local N = Tab:AddLeftGroupbox("Fixing", "wrench")
    toggle(N, "AutoPower", "Auto fix power", "Goes to a broken power box, claims it and plugs every cable")
    toggle(N, "AutoReboot", "Reboot jammed robots")
    toggle(N, "AutoShoo", "Scare monsters off the pile")
    toggle(N, "AutoRescue", "Help downed players up")
    status(N, function()
        return ("Power fixed %d · robots %d · scared %d · helped %d%s"):format(Night.fixed, Night.reboots, Night.shoos, Night.rescues,
            Night.info ~= "" and ("\n" .. Night.info) or "")
    end)
    local M = Tab:AddRightGroupbox("Monsters", "skull")
    toggle(M, "MonsterAlert", "Warn me", "A message when a monster gets close")
    slider(M, "AlertRange", "Warn at", 10, 150, 0, " studs")
    toggle(M, "EscapeMonsters", "Run inside", "When a monster is this close and you're outdoors, you go to the kitchen")
    slider(M, "EscapeRange", "Run at", 5, 80, 0, " studs")
    local K = Tab:AddRightGroupbox("Basement key", "key")
    toggle(K, "AutoKey", "Use the key", "When you hold the key, goes to the basement door and uses it")
    toggle(K, "JumpInBasement", "Jump in after", "Also jumps into the basement (that ends the run)")
    goButton(K, "Go to the basement door", function()
        local spot = Workspace:GetAttribute("BasementDoor")
        if typeof(spot) == "Vector3" then
            Move.near(spot, 3)
        end
    end)
    goButton(K, "Use the key now", Night.useKey)
end

do
    local Tab = Window:AddTab("Buy", "shopping-cart", "Perks, upgrades, tools")
    local P = Tab:AddLeftGroupbox("Perks", "sparkles")
    toggle(P, "AutoPerk", "Auto pick perks",
        "Order: Extra Life, Instant Peel, More Cash, Carry More, Fix Power Fast, +1 Robot, Night Cash, More Health, Walk Faster, Drop Faster")
    toggle(P, "AvoidCursed", "Skip cursed perks", "Rich at Night, Golden Vacuum, Rich but Weak, Fast but Broke are only picked if nothing else is offered")
    goButton(P, "Pick one now", Buy.pickPerk)
    local U = Tab:AddRightGroupbox("Upgrades", "trending-up")
    toggle(U, "AutoUpgrades", "Auto buy upgrades", "Buys the picked upgrades whenever you can afford them")
    U:AddDropdown("UpgradePicks", {
        Text = "Upgrades", Values = UPGRADES, Default = { "BiggerPeel", "PeelAmount", "MoneyMulti" }, Multi = true,
        Callback = function(v)
            Settings.UpgradePicks = v
        end,
    })
    toggle(U, "AutoTools", "Buy the bucket and vacuum", "Bucket at $100, vacuum at $1,000")
    toggle(U, "AutoPads", "Buy tycoon pads", "Steps on each available pad (auto fryer, auto peeler, conveyor, robots...) when you can pay")
    status(U, function()
        return Buy.info ~= "" and Buy.info or "-"
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Monsters, cars, players")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "EspMonsters", "Monsters")
    toggle(E, "EspCars", "Monster cars", "Every car that's a monster, with what kind")
    toggle(E, "EspPlayers", "Players", "Yellow when downed")
    toggle(E, "EspRobots", "Jammed robots")
    toggle(E, "EspPower", "Broken power boxes")
    toggle(E, "EspDropped", "Dropped potatoes and items")
    slider(E, "EspDistance", "Max distance", 50, 3000, 0, " studs")
    local T = Tab:AddRightGroupbox("Teleport", "map-pin")
    goButton(T, "Peeling station", function()
        Move.near(Game.kitchen("PeelingStation"), 3)
    end)
    goButton(T, "Fryer", function()
        Move.near(Game.kitchen("DeepFryer"), 3)
    end)
    goButton(T, "Potato crate", function()
        Move.near(Game.kitchen("PotatoCrate"), 3)
    end)
    goButton(T, "Drive-thru window", function()
        local d = Game.driveThru()
        Move.near(d and d:FindFirstChild("Window"), 3)
    end)
    goButton(T, "Potato pile", function()
        local station = Game.kitchen("PeelingStation")
        local spot = Work.pileNear(pivotOf(station) or myRoot().Position)
        if spot then
            Move.near(spot, 3.5, Workspace:FindFirstChild("PotatoPile"))
        end
    end)
    goButton(T, "Shop", function()
        Move.near(Workspace:FindFirstChild("ItemShop"), 4)
    end)
end

do
    local Tab = Window:AddTab("Player", "user", "Movement, light, skips")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Speed")
    slider(M, "WalkSpeed", "Speed", 16, 200, 0, "", "The game's own limit is 200")
    toggle(M, "InfJump", "Infinite jump")
    toggle(M, "Fly", "Fly", "Moves where you look. Space up, Left Ctrl down")
    slider(M, "FlySpeed", "Fly speed", 10, 300, 0)
    toggle(M, "Noclip", "Noclip")
    local O = Tab:AddRightGroupbox("Other", "settings")
    toggle(O, "Fullbright", "Fullbright", "Bright nights")
    toggle(O, "SkipIntro", "Skip the intro")
    goButton(O, "Skip the tutorial", function()
        local r = remote("TutorialDone")
        if r then
            r:FireServer("Skipped")
        end
    end)
    goButton(O, "Back to the lobby", function()
        local r = remote("ReturnToLobby")
        if r then
            r:FireServer()
        end
    end)
    toggle(O, "AntiAfk", "Anti-AFK")
    O:AddButton({ Text = "Unload", Func = function()
        if Genv.__FriesUnload then
            Genv.__FriesUnload()
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
Genv.__FriesUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

local missing = {}
if not Pile then
    table.insert(missing, "pile controller")
end
if not Stats then
    table.insert(missing, "Stats")
end
notify("Loaded" .. (#missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or ""), 4)

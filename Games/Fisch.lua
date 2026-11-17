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
--   Shake    two systems, both a PlayerGui "shakeui". New: the server invokes
--            RF/LureShake/Start, LureShakeController puts a button in
--            safezone and each press sends RE/LureShake/Shake (one per
--            0.25s). Old: the server clones resources.replicated.fishing
--            .shakeui itself (safezone has bobber / char values) and a
--            server Script there counts real clicks on safezone "button"s,
--            so those buttons have to be pressed for real.
--   Reel     the server invokes RF/Reel/Start; ReelController.StartReel
--            runs the whole minigame on your side (fishPosition, barPosition,
--            barSize, progress) and EndMinigame sends RE/Reel/Finish
--            { e = progress (100 = caught), p = perfect, l = {}, d = ... }.
--            Player attribute MinigameSpeedMulti scales the minigame's time.
--   Selling  merchants are NPC models with NpcType "Merchant"; the dialog's
--            choice calls events.SellAll with { npc = merchant }.
--            events.PreviewSellAll(false) is what your fish are worth, and
--            events.selleverything sells from anywhere (gamepass).
--   Places   the map streams in, so far spawn points aren't on your side.
--            PlayerGui.loading's loading/client has a camera CFrame for every
--            Sea 1 area (the loading screen); those are built in here and you
--            land on dry ground near where each one looks.
--   Zones    workspace.zones.fishing holds a part per fishing zone (Abundance
--            StringValue = a boosted fish). library.fish.zones[name].Pool is
--            what can bite there; the server rolls a rarity group first
--            (rarities.ChanceGroups BaseChance + luck * LuckFactor) and then a
--            fish in it by Chance. A fish sells for
--            ceil(weight / (WeightPool[2] / 10) * Price) before mutations.
--   Air      oxygen, pressure, heat, cold are worked out on the server and
--            sent with RE/URE EnvironmentResource/UpdateValue; the client
--            keeps them in EnvironmentResourceController.ResourceData.
--   Boats    your own boat is driven on your side: BoatController.Physics
--            .currentBoatData (MaxSpeed, Accel, TurningSpeed, FlyingBoat, ...)
--            is read every frame, the boat's PlaneConstraint keeps it on the
--            water.
--   Other    events.runcode
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
    AutoShake = false, ShakeDelay = 0.25, ShakeMethod = "Auto",
    AutoReel = false, ReelMode = "Lock bar on fish", InstantDelay = 1.5,
    FastReel = false, ReelSpeed = 1.5,
    -- selling
    AutoSell = false, SellWhen = "Worth over", SellWorth = 10000, SellEvery = 5, SellAnywhere = false, SellReturn = true,
    -- teleports
    TpSpot = nil, SpotName = "",
    -- zones
    ZonePick = nil, ZoneSort = "Best value", EspZones = false,
    -- player
    SpeedOn = false, WalkSpeed = 32, JumpOn = false, JumpPower = 80, InfJump = false,
    Fly = false, FlySpeed = 80, Noclip = false, WaterWalk = false,
    AntiDrown = false, DrownAt = 35, DrownReturn = true,
    -- boat
    BoatSpeedOn = false, BoatSpeed = 2, BoatFly = false, BoatFlySpeed = 60, BoatInfBoost = false,
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
    if not pg then
        return nil
    end
    local found
    for _, g in pg:GetChildren() do
        if g.Name == "shakeui" and g:IsA("ScreenGui") then
            if g.Enabled then
                return g
            end
            found = found or g
        end
    end
    return found
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

    -- Shake. New system: RE/LureShake/Shake is all it takes. Old system: the
    -- server only counts real presses of the safezone "button"s, so those get
    -- pressed with the method you pick:
    --   Tap             a touch with its own finger, so your movement stick
    --                   keeps working on mobile
    --   Select + Enter  selects the button and presses Enter
    --   Mouse click     clicks its middle
    --   VirtualUser     clicks through VirtualUser instead of
    --                   VirtualInputManager
    --   Remote          fires the remotes only (instant, may not count on the
    --                   old system)
    --   Auto            Remote on the new system; Tap on a phone, Select + Enter
    --                   on a computer for the old one
    local GuiService = game:GetService("GuiService")
    local UserInputService = game:GetService("UserInputService")
    local VIM, VU
    do
        local ok, svc = pcall(game.GetService, game, "VirtualInputManager")
        VIM = ok and svc or nil
        local ok2, vu = pcall(game.GetService, game, "VirtualUser")
        VU = ok2 and vu or nil
    end
    local function shakeButton(ui)
        local safe = ui:FindFirstChild("safezone")
        if not safe then
            return nil, false
        end
        local legacy = safe:FindFirstChild("bobber") ~= nil or safe:FindFirstChild("char") ~= nil or ui:FindFirstChild("cancel") ~= nil
        for _, d in safe:GetDescendants() do
            if d:IsA("GuiButton") and d.Visible and d.AbsoluteSize.X > 1 and (d.Name == "button" or not legacy) then
                return d, legacy
            end
        end
        return nil, legacy
    end
    local function screenPoint(btn)
        local gui = btn:FindFirstAncestorWhichIsA("ScreenGui")
        local c = btn.AbsolutePosition + btn.AbsoluteSize / 2
        if not (gui and gui.IgnoreGuiInset) then
            c += GuiService:GetGuiInset()
        end
        return c
    end
    local FINGER = 7351
    local Press = {}
    Press["Tap"] = function(btn)
        if not VIM then
            return false
        end
        local c = screenPoint(btn)
        VIM:SendTouchEvent(FINGER, 0, c.X, c.Y)
        task.wait()
        VIM:SendTouchEvent(FINGER, 2, c.X, c.Y)
        return true
    end
    Press["Select + Enter"] = function(btn)
        if not (VIM and btn.Selectable) then
            return false
        end
        local prev = GuiService.SelectedObject
        pcall(function()
            GuiService.SelectedObject = btn
        end)
        if GuiService.SelectedObject ~= btn then
            return false
        end
        VIM:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait()
        VIM:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
        task.delay(0.05, function()
            if GuiService.SelectedObject == btn or not btn.Parent then
                pcall(function()
                    GuiService.SelectedObject = prev
                end)
            end
        end)
        return true
    end
    Press["Mouse click"] = function(btn)
        if not VIM then
            return false
        end
        local c = screenPoint(btn)
        VIM:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 0)
        task.wait()
        VIM:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 0)
        return true
    end
    Press["VirtualUser click"] = function(btn)
        if not VU then
            return false
        end
        local c = screenPoint(btn)
        local cam = Workspace.CurrentCamera
        local at = cam and cam.CFrame or CFrame.new()
        pcall(VU.CaptureController, VU)
        VU:Button1Down(c, at)
        task.wait()
        VU:Button1Up(c, at)
        return true
    end
    local function remoteShake(btn, legacy)
        if legacy then
            local sent = false
            local r = btn and btn:FindFirstChild("shake")
            if r and r:IsA("RemoteEvent") then
                r:FireServer()
                sent = true
            end
            if btn and typeof(firesignal) == "function" then
                pcall(firesignal, btn.MouseButton1Click)
                pcall(firesignal, btn.Activated)
                sent = true
            end
            return sent
        end
        local r = net("RE/LureShake/Shake")
        if r then
            r:FireServer()
            return true
        end
        return false
    end
    local function methodFor(legacy)
        local m = Settings.ShakeMethod
        if m == "Auto" then
            if not legacy then
                return "Remote"
            end
            if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
                return "Tap"
            end
            return "Select + Enter"
        end
        return m
    end
    Fish.shakeInfo = "off"
    local lastShake = 0
    local pressedAt = setmetatable({}, { __mode = "k" })
    loop(0.03, function()
        if not Settings.AutoShake then
            Fish.shakeInfo = "off"
            return
        end
        local ui = shakeUi()
        if not (ui and ui.Enabled) then
            Fish.shakeInfo = "waiting for a shake"
            return
        end
        local now = os.clock()
        if now - lastShake < math.max(0.03, Settings.ShakeDelay) then
            return
        end
        local btn, legacy = shakeButton(ui)
        local method = methodFor(legacy)
        local kind = legacy and "old shake" or "new shake"
        if method == "Remote" then
            lastShake = now
            if remoteShake(btn, legacy) then
                Fish.shakes += 1
                Fish.shakeInfo = ("shaking (remote, %s)"):format(kind)
            else
                Fish.shakeInfo = "no shake remote found"
            end
            return
        end
        if not btn then
            Fish.shakeInfo = "waiting for the shake button"
            return
        end
        if pressedAt[btn] and now - pressedAt[btn] < 0.5 then
            return
        end
        local press = Press[method]
        local ok, res = false, false
        if press then
            ok, res = pcall(press, btn)
        end
        lastShake = now
        pressedAt[btn] = now
        if ok and res then
            Fish.shakes += 1
            Fish.shakeInfo = ("shaking (%s, %s)"):format(method, kind)
        elseif remoteShake(btn, legacy) then
            Fish.shakes += 1
            Fish.shakeInfo = ("%s isn't available here, used the remote (%s)"):format(method, kind)
        else
            Fish.shakeInfo = method .. " isn't available here"
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

--// Teleports \\--
-- Places don't have to be loaded on your side: the loading screen's camera
-- spots for every Sea 1 area are built in, plus spawn points that are
-- loaded and spots you save yourself.
local Tp = { spots = {}, names = {}, info = "" }
local BUILT_IN = {
	["Starter"] = CFrame.new(317.298, 134.766, 277.479) * CFrame.fromOrientation(0, -0.9948376736367679, 0.22689280275926285),
	["Abyssal Zenith"] = CFrame.new(-13589, -11004, 18) * CFrame.fromOrientation(-0.5235987755982988, 2.199114857512855, -0.22689280275926285),
	["AncientIsle"] = CFrame.new(6076, 206, 256) * CFrame.fromOrientation(-0.22689280275926285, 2.8099800957108707, 0.22689280275926285),
	["Atlantis"] = CFrame.new(-4150, -555, 1747) * CFrame.fromOrientation(-0.24434609527920614, 2.0420352248333655, 0.22689280275926285),
	["Calm Zone"] = CFrame.new(-4293, -11194, 1748) * CFrame.fromOrientation(-0.17453292519943295, -0.13962634015954636, 0.22689280275926285),
	["Castaway Cliffs"] = CFrame.new(673, 159, -1757) * CFrame.fromOrientation(0.4363323129985824, 0.4363323129985824, -0.24434609527920614),
	["Challengers Deep"] = CFrame.new(-738, -3236, -673) * CFrame.fromOrientation(-0.3141592653589793, 1.9722220547535925, -0.22689280275926285),
	["CryogenicCanal"] = CFrame.new(20310, 724, 5657) * CFrame.fromOrientation(0.15707963267948966, 2.199114857512855, -0.22689280275926285),
	["CrystalCove"] = CFrame.new(1382, -615, 2456) * CFrame.fromOrientation(0.06981317007977318, 0.20943951023931956, -0.22689280275926285),
	["DesolateDeep"] = CFrame.new(-1656, -207, -2935) * CFrame.fromOrientation(-0.20943951023931956, -2.6179938779914944, 0.22689280275926285),
	["Forsaken Shores"] = CFrame.new(-2449, 147, 1493) * CFrame.fromOrientation(-0.017453292519943295, 2.129301687433082, 0.22689280275926285),
	["FrigidCavern"] = CFrame.new(19723, 422, 5411) * CFrame.fromOrientation(-0.08726646259971647, -1.2566370614359172, -0.22689280275926285),
	["GlacialGrotto"] = CFrame.new(19997, 1144, 5568) * CFrame.fromOrientation(0.20943951023931956, 0.6806784082777885, 0.22689280275926285),
	["Living Garden"] = CFrame.new(-2493, -300, -3106) * CFrame.fromOrientation(-0.12217304763960307, -2.4958208303518914, 0.22689280275926285),
	["Lost Jungle"] = CFrame.new(-2670, 170, -2080) * CFrame.fromOrientation(-0.2792526803190927, 1.710422666954443, 0.22689280275926285),
	["LuminescentCavern"] = CFrame.new(-1023, -330, -4078) * CFrame.fromOrientation(-0, -0.10471975511965978, 0.22689280275926285),
	["Moosewood"] = CFrame.new(454, 154, 249) * CFrame.fromOrientation(-0.06981317007977318, -1.8500490071139892, -0.22689280275926285),
	["OvergrowthCaves"] = CFrame.new(19541, 176, 5358) * CFrame.fromOrientation(-0.5585053606381855, -0.4014257279586958, 0.2617993877991494),
	["Roslit"] = CFrame.new(-1419, 137, 754) * CFrame.fromOrientation(0.05235987755982989, 0.8726646259971648, -0.22689280275926285),
	["Scoria Reach"] = CFrame.new(-5098, 140, -1461) * CFrame.fromOrientation(0.2792526803190927, 1.5882496193148399, 0.24434609527920614),
	["SharkSanctuary"] = CFrame.new(-4012, -1865, -861) * CFrame.fromOrientation(-0.03490658503988659, 0.20943951023931956, 0.2617993877991494),
	["Snowcap"] = CFrame.new(2669, 155, 2362) * CFrame.fromOrientation(0.08726646259971647, -2.670353755551324, -0.22689280275926285),
	["Sunstone"] = CFrame.new(-904, 141, -1146) * CFrame.fromOrientation(0.2617993877991494, 2.426007660272118, 0.22689280275926285),
	["Terrapin"] = CFrame.new(-124, 161, 1928) * CFrame.fromOrientation(-0.20943951023931956, 1.710422666954443, 0.22689280275926285),
	["The Depths"] = CFrame.new(943, -696, 1173) * CFrame.fromOrientation(0.06981317007977318, 3.1066860685499065, -0.22689280275926285),
	["Tidefall"] = CFrame.new(3091, -1098, 805) * CFrame.fromOrientation(0.15707963267948966, -1.0122909661567112, 0.22689280275926285),
	["Volcanic Vents"] = CFrame.new(-3352, -2242, 3811) * CFrame.fromOrientation(-0.08726646259971647, 2.478367537831948, -0.22689280275926285),
	["FischFright"] = CFrame.new(-14596, 157, -9640) * CFrame.fromOrientation(0.08726646259971647, 1.4835298641951802, 0.2617993877991494),
}
local WATCHED = {
    ["The Depths"] = true, ["Tidefall"] = true, ["CrystalCove"] = true, ["Living Garden"] = true,
    ["Scoria Reach"] = true, ["Toxic Grove"] = true, ["Nectar Den"] = true,
}
local MERCHANT_ISLANDS = { "Moosewood", "Roslit", "Terrapin", "Snowcap", "Sunstone", "Forsaken Shores", "AncientIsle" }
do
    local world = ReplicatedStorage:GetAttribute("CurrentWorld") or "Sea 1"
    local SEA_LEVEL = world == "Sea 2" and 74 or 127
    local FILE = "Ui3/Fisch/spots.json"

    local saved = {}
    local function readSaved()
        if typeof(readfile) ~= "function" or typeof(isfile) ~= "function" then
            return
        end
        local ok, data = pcall(function()
            return isfile(FILE) and HttpService:JSONDecode(readfile(FILE)) or nil
        end)
        if ok and type(data) == "table" and type(data[world]) == "table" then
            for name, v in data[world] do
                if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
                    saved[name] = CFrame.new(v[1], v[2], v[3])
                end
            end
        end
    end
    local function writeSaved()
        if typeof(writefile) ~= "function" then
            return false
        end
        local all = {}
        pcall(function()
            if typeof(isfile) == "function" and isfile(FILE) then
                all = HttpService:JSONDecode(readfile(FILE))
            end
        end)
        if type(all) ~= "table" then
            all = {}
        end
        local mine = {}
        for name, cf in saved do
            local p = cf.Position
            mine[name] = { math.floor(p.X * 10) / 10, math.floor(p.Y * 10) / 10, math.floor(p.Z * 10) / 10 }
        end
        all[world] = mine
        return pcall(function()
            if typeof(makefolder) == "function" then
                pcall(makefolder, "Ui3")
                pcall(makefolder, "Ui3/Fisch")
            end
            writefile(FILE, HttpService:JSONEncode(all))
        end)
    end
    readSaved()

    function Tp.load()
        local spots = {}
        if world == "Sea 1" then
            for name, cf in BUILT_IN do
                spots[name .. (WATCHED[name] and " (watched zone)" or "")] = { cf = cf, kind = "camera" }
            end
        end
        local w = Workspace:FindFirstChild("world")
        local sp = w and w:FindFirstChild("spawns")
        if sp then
            for _, folder in sp:GetChildren() do
                local found = folder:IsA("BasePart") and folder or folder:FindFirstChildWhichIsA("BasePart", true)
                local name = folder.Name
                if found and not (BUILT_IN[name] and world == "Sea 1") and name ~= "loading" then
                    spots[name .. (WATCHED[name] and " (watched zone)" or "")] = { cf = found.CFrame, kind = "spawn" }
                end
            end
        end
        for name, cf in saved do
            spots["* " .. name] = { cf = cf, kind = "saved" }
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

    -- Dry ground near a camera spot: along where it looks for islands, under
    -- it for caves and deep places.
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local function ground(p, depth)
        params.FilterDescendantsInstances = { myChar() }
        local hit = Workspace:Raycast(p + Vector3.new(0, 120, 0), Vector3.new(0, -(depth or 500), 0), params)
        if hit and hit.Material ~= Enum.Material.Water then
            return hit.Position
        end
        return nil
    end
    local function landing(cf)
        local pos = cf.Position
        if pos.Y < SEA_LEVEL - 10 then
            params.FilterDescendantsInstances = { myChar() }
            local hit = Workspace:Raycast(pos, Vector3.new(0, -400, 0), params)
            return hit and hit.Position or nil
        end
        local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
        if look.Magnitude < 0.01 then
            look = Vector3.new(0, 0, -1)
        end
        look = look.Unit
        local here = ground(pos)
        if here and here.Y > SEA_LEVEL + 1 then
            return here
        end
        for t = 15, 900, 15 do
            local g = ground(pos + look * t)
            if g and g.Y > SEA_LEVEL + 1 then
                return g
            end
        end
        return nil
    end
    function Tp.land(cf)
        local root = myRoot()
        if not root then
            return false
        end
        pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, cf.Position, 6)
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(cf.Position) * root.CFrame.Rotation
        local spot
        for _ = 1, 6 do
            task.wait(0.25)
            local r = myRoot()
            if not r then
                return false
            end
            spot = landing(cf)
            if spot then
                break
            end
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(cf.Position) * r.CFrame.Rotation
        end
        local r = myRoot()
        if r and spot then
            r.AssemblyLinearVelocity = Vector3.zero
            r.CFrame = CFrame.new(spot + Vector3.new(0, 3.5, 0)) * r.CFrame.Rotation
        end
        return true
    end
    function Tp.go(name)
        local s = name and Tp.spots[name]
        if not s then
            notify("Pick a spot first")
            return
        end
        Tp.info = "going to " .. name
        if s.kind == "camera" then
            Tp.land(s.cf)
        else
            Move.to(s.cf.Position)
        end
        Tp.info = "went to " .. name
    end
    function Tp.save(name)
        local root = myRoot()
        name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if not root or name == "" then
            notify("Type a name for this spot first")
            return
        end
        saved[name] = root.CFrame
        local ok = writeSaved()
        notify(ok and ("Saved " .. name) or ("Saved " .. name .. " for this session (your executor can't write files)"))
    end
    function Tp.forget(label)
        local name = type(label) == "string" and label:match("^%* (.+)$")
        if not (name and saved[name]) then
            notify("Pick one of your saved spots (they start with *)")
            return
        end
        saved[name] = nil
        writeSaved()
        notify("Removed " .. name)
    end
    function Tp.camera(name)
        return world == "Sea 1" and BUILT_IN[name] or nil
    end
end

--// Player: speed, jump, fly, noclip, water, air \\--
local UserInputService = game:GetService("UserInputService")
local Plat = {}
do
    local function newPart(name)
        local p = Instance.new("Part")
        p.Name = name
        p.Anchored = true
        p.CanCollide = true
        p.CanTouch = false
        p.CastShadow = false
        p.Transparency = 1
        p.Size = Vector3.new(14, 1, 14)
        return p
    end
    Plat.walk = newPart("\0w")
    Plat.spotPart = newPart("\0s")
    Plat.spotAt = nil
    table.insert(Cleanups, function()
        Plat.walk:Destroy()
        Plat.spotPart:Destroy()
    end)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = false
    -- A ray that sees the water surface and skips you, the zone volumes and
    -- these platforms.
    function Plat.ray(from, dir)
        local list = { Plat.walk, Plat.spotPart }
        local c = myChar()
        if c then
            table.insert(list, c)
        end
        local z = Workspace:FindFirstChild("zones")
        if z then
            table.insert(list, z)
        end
        params.FilterDescendantsInstances = list
        return Workspace:Raycast(from, dir, params)
    end
    -- Something to stand on at a water surface; it goes away once you walk off.
    function Plat.spot(surface)
        Plat.spotAt = surface
        Plat.spotPart.CFrame = CFrame.new(surface - Vector3.new(0, 0.35, 0))
        Plat.spotPart.Parent = Workspace
    end
    function Plat.clearSpot()
        Plat.spotAt = nil
        Plat.spotPart.Parent = nil
    end
end

do
    -- Walk speed and jump power: the game sets them from character attributes
    -- whenever something changes, so ours is put back every frame and the
    -- game's own value comes back when you turn it off.
    local cur = { hum = nil }
    local function hold(hum, on, prop, value, key)
        local ours, theirs = key .. "Ours", key .. "Game"
        if on then
            if hum[prop] ~= value then
                if hum[prop] ~= cur[ours] then
                    cur[theirs] = hum[prop]
                end
                hum[prop] = value
                cur[ours] = value
            end
        elseif cur[ours] ~= nil then
            if cur[theirs] and hum[prop] == cur[ours] then
                hum[prop] = cur[theirs]
            end
            cur[ours], cur[theirs] = nil, nil
        end
    end

    local flyForce
    local function stopFly()
        if flyForce then
            flyForce:Destroy()
            flyForce = nil
        end
    end
    local function flyVelocity(hum)
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
        return v * Settings.FlySpeed
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
        if hum ~= cur.hum then
            table.clear(cur)
            cur.hum = hum
        end
        hold(hum, Settings.SpeedOn, "WalkSpeed", Settings.WalkSpeed, "speed")
        hold(hum, Settings.JumpOn, "JumpPower", Settings.JumpPower, "jump")

        if Settings.Fly and hum.Health > 0 and not hum.SeatPart then
            if not (flyForce and flyForce.Parent == root) then
                stopFly()
                flyForce = Instance.new("BodyVelocity")
                flyForce.Name = "\0f"
                flyForce.MaxForce = Vector3.one * 1e9
                flyForce.P = 1e4
                flyForce.Velocity = Vector3.zero
                flyForce.Parent = root
            end
            flyForce.Velocity = flyVelocity(hum)
        else
            stopFly()
        end

        -- Walk on water: a platform right at the surface under you, while
        -- you're at or above it (dive more than a couple of studs to go under).
        if Settings.WaterWalk and hum.Health > 0 and not hum.SeatPart and not Settings.Fly then
            local hit = Plat.ray(root.Position + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0))
            if hit and hit.Material == Enum.Material.Water and root.Position.Y > hit.Position.Y - 2.5 then
                Plat.walk.CFrame = CFrame.new(root.Position.X, hit.Position.Y - 0.35, root.Position.Z)
                Plat.walk.Parent = Workspace
            elseif Plat.walk.Parent then
                Plat.walk.Parent = nil
            end
        elseif Plat.walk.Parent then
            Plat.walk.Parent = nil
        end
        if Plat.spotAt then
            local d = root.Position - Plat.spotAt
            if Vector3.new(d.X, 0, d.Z).Magnitude > 30 or math.abs(d.Y) > 25 then
                Plat.clearSpot()
            end
        end
    end)
    table.insert(Cleanups, function()
        stopFly()
        local hum = cur.hum
        if hum and hum.Parent then
            hold(hum, false, "WalkSpeed", 0, "speed")
            hold(hum, false, "JumpPower", 0, "jump")
        end
    end)

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
    table.insert(Cleanups, function()
        for p in noclipped do
            if p.Parent then
                p.CanCollide = true
            end
        end
    end)

    bind(UserInputService.JumpRequest, function()
        if Settings.InfJump and alive() then
            local hum = myHum()
            if hum and hum.Health > 0 and not hum.SeatPart then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end)
end

-- Anti drown: watch oxygen (and pressure, heat, cold) and when one gets low,
-- go back to the last place where nothing was running out, wait until it's
-- full again, and come back.
local Air = { info = "off", saves = 0 }
do
    local Controller, Config
    pcall(function()
        Controller = require(ReplicatedStorage.client.legacyControllers.EnvironmentResourceController)
    end)
    pcall(function()
        Config = require(ReplicatedStorage.shared.modules.EnvironmentResources).Resources
    end)
    local heard = {}
    local function onValue(name, data)
        if type(name) == "string" and type(data) == "table" then
            local h = heard[name] or {}
            heard[name] = h
            if tonumber(data.Value) then
                h.value = data.Value
            end
        end
    end
    local function onState(name, data)
        if type(name) == "string" and type(data) == "table" then
            local h = heard[name] or {}
            heard[name] = h
            if tonumber(data.Max) then
                h.max = data.Max
            end
            if data.Enabled ~= nil then
                h.enabled = data.Enabled and true or false
            end
        end
    end
    for _, n in { "URE/EnvironmentResource/UpdateValue", "RE/EnvironmentResource/UpdateValue" } do
        local r = net(n)
        if r then
            bind(r.OnClientEvent, onValue)
        end
    end
    local st = net("RE/EnvironmentResource/UpdateState")
    if st then
        bind(st.OnClientEvent, onState)
    end

    local function readAll()
        local out = {}
        local data = type(Controller) == "table" and rawget(Controller, "ResourceData")
        if type(data) == "table" then
            for name, r in data do
                if type(r) == "table" and tonumber(r.Value) and tonumber(r.Max) then
                    out[name] = { value = r.Value, min = tonumber(r.Min) or 0, max = r.Max, inverse = r.InverseDirection, enabled = r.Enabled }
                end
            end
        end
        for name, h in heard do
            if not out[name] and h.value then
                local c = type(Config) == "table" and Config[name] or nil
                out[name] = {
                    value = h.value, min = (c and c.BaseMin) or 0, max = h.max or (c and c.BaseMax) or 100,
                    inverse = c and c.InverseDirection, enabled = h.enabled ~= false,
                }
            end
        end
        return out
    end
    -- 1 = nothing wrong, 0 = taking damage.
    local function left(r)
        local span = r.max - r.min
        if span <= 0 then
            return 1
        end
        local f = (r.value - r.min) / span
        if r.inverse then
            f = 1 - f
        end
        return math.clamp(f, 0, 1)
    end
    function Air.levels()
        local parts = {}
        for name, r in readAll() do
            if r.enabled then
                table.insert(parts, ("%s %d%%"):format(name, math.floor(left(r) * 100)))
            end
        end
        table.sort(parts)
        return #parts > 0 and table.concat(parts, ", ") or "nothing running out"
    end

    local safe
    local function surfaceAbove(pos)
        local hit = Plat.ray(pos + Vector3.new(0, 400, 0), Vector3.new(0, -400, 0))
        if hit and hit.Material == Enum.Material.Water and hit.Position.Y > pos.Y then
            return hit.Position
        end
        return nil
    end
    local function rescue(name)
        local root = myRoot()
        if not root then
            return
        end
        local target, surface = safe, nil
        if not target then
            surface = surfaceAbove(root.Position)
            target = surface and CFrame.new(surface + Vector3.new(0, 3.2, 0))
        end
        if not target then
            Air.info = "low on " .. name .. " and no safe spot known yet"
            return
        end
        Busy.reason = "getting air"
        Air.info = "low on " .. name .. ", going up for air"
        local home = root.CFrame
        if surface then
            Plat.spot(surface)
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = target
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 25 do
            task.wait(0.25)
            local r = readAll()[name]
            if not r or left(r) >= 0.97 then
                break
            end
            if not r.enabled and os.clock() - t0 > 3 then
                break
            end
        end
        Air.saves += 1
        local r2 = myRoot()
        if Settings.DrownReturn and r2 and alive() then
            r2.AssemblyLinearVelocity = Vector3.zero
            r2.CFrame = home
        end
        Busy.reason = nil
    end

    local prev = {}
    loop(0.25, function()
        local root, hum = myRoot(), myHum()
        if not (root and hum and hum.Health > 0) then
            return
        end
        local worst, worstName, dropping = 1, nil, false
        for name, r in readAll() do
            local l = left(r)
            if r.enabled then
                if prev[name] and l < prev[name] - 1e-4 then
                    dropping = true
                end
                if l < worst then
                    worst, worstName = l, name
                end
            end
            prev[name] = l
        end
        local state = hum:GetState()
        local dry = state ~= Enum.HumanoidStateType.Swimming and hum.FloorMaterial ~= Enum.Material.Air
            and hum.FloorMaterial ~= Enum.Material.Water and not hum.SeatPart
        if worst >= 0.97 and not dropping and dry then
            safe = root.CFrame
        end
        if not Settings.AntiDrown then
            Air.info = "off"
            return
        end
        Air.info = worstName and ("%s at %d%%"):format(worstName, math.floor(worst * 100)) or "fine"
        if worstName and worst * 100 <= Settings.DrownAt and dropping and not Busy.reason then
            rescue(worstName)
        end
    end)
end

--// Boat \\--
-- Your boat runs on your side, from BoatController.Physics.currentBoatData:
-- swap in a copy with more speed, or make it a flying boat.
local Boat = { info = "" }
do
    local Phys
    local function phys()
        if Phys == nil then
            local ok, m = pcall(function()
                return require(ReplicatedStorage.client.legacyControllers.BoatController)
            end)
            Phys = (ok and type(m) == "table" and type(m.Physics) == "table") and m.Physics or false
        end
        return Phys or nil
    end
    local base, modded, sig, plane, weSetVertical
    local function restore(p)
        if p and modded and p.currentBoatData == modded then
            p.currentBoatData = base
            if p.controlsEnabled then
                pcall(p.EnableControls, p)
            end
        end
        if plane then
            plane.Enabled = true
            plane = nil
        end
        if p and weSetVertical then
            p.targetVerticalSpeed = 0
        end
        base, modded, sig, weSetVertical = nil, nil, nil, nil
    end
    local function upInput(boat)
        local up = 0
        if not UserInputService:GetFocusedTextBox() then
            if UserInputService:IsKeyDown(Enum.KeyCode.R) then
                up += 1
            end
            if UserInputService:IsKeyDown(Enum.KeyCode.F) then
                up -= 1
            end
        end
        if up == 0 and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
            local seat = boat.VehicleSeat
            local cam = Workspace.CurrentCamera
            if seat and cam and math.abs(seat.ThrottleFloat) > 0.1 then
                local ly = cam.CFrame.LookVector.Y
                if math.abs(ly) > 0.25 then
                    up = math.clamp(ly * 2, -1, 1)
                end
            end
        end
        return up
    end
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local p = phys()
        if not p then
            Boat.info = "boat controller not found"
            return
        end
        local boat, data = p.currentBoat, p.currentBoatData
        if not (boat and data) then
            if modded or plane then
                restore(p)
            end
            Boat.info = "not in your own boat"
            return
        end
        Boat.info = ("%s: %.0f studs/s"):format(tostring(boat.Name or "boat"), tonumber(p.currentTotalSpeed) or 0)
        if not (Settings.BoatSpeedOn or Settings.BoatFly or Settings.BoatInfBoost) then
            if modded or plane then
                restore(p)
            end
            return
        end
        local want = ("%s|%s|%s|%s"):format(tostring(Settings.BoatSpeedOn), tostring(Settings.BoatSpeed), tostring(Settings.BoatFly), tostring(Settings.BoatFlySpeed))
        if data ~= modded or want ~= sig then
            if data ~= modded then
                base = data
            end
            local m = table.clone(base)
            if Settings.BoatSpeedOn then
                local k = Settings.BoatSpeed
                m.MaxSpeed = (tonumber(base.MaxSpeed) or 0) * k
                m.Accel = (tonumber(base.Accel) or 1) * k
                m.TurningSpeed = (tonumber(base.TurningSpeed) or 1) * (1 + (k - 1) * 0.5)
                if tonumber(base.BoostMaxSpeed) then
                    m.BoostMaxSpeed = base.BoostMaxSpeed * k
                end
            end
            if Settings.BoatFly then
                m.FlyingBoat = true
                m.VerticalMaxSpeed = Settings.BoatFlySpeed
            end
            modded, sig = m, want
            p.currentBoatData = m
            if p.controlsEnabled then
                pcall(p.EnableControls, p)
            end
        end
        if Settings.BoatFly then
            local pc = boat.PlaneConstraint
            if pc and pc.Enabled then
                pc.Enabled = false
                plane = pc
            end
            local up = upInput(boat)
            if up ~= 0 then
                p.targetVerticalSpeed = up * Settings.BoatFlySpeed
                weSetVertical = true
            elseif weSetVertical then
                p.targetVerticalSpeed = 0
                weSetVertical = nil
            end
        elseif plane then
            plane.Enabled = true
            plane = nil
        end
        if Settings.BoatInfBoost and p.currentBoatData and p.currentBoatData.BoostEnabled then
            p.pboostCharge = 1
        end
    end)
    table.insert(Cleanups, function()
        restore(phys())
    end)
end

--// Fishing zones: what bites where, and what it's worth \\--
local Zones = { entries = {}, labels = {}, byLabel = {}, info = "not loaded yet", cache = {} }
do
    local Lib = {}
    local function load()
        if Lib.ok then
            return true
        end
        local ok = pcall(function()
            local library = ReplicatedStorage:WaitForChild("shared", 5):WaitForChild("modules", 5):WaitForChild("library", 5)
            Lib.fish = require(library:WaitForChild("fish", 5))
            Lib.zones = require(library.fish:WaitForChild("zones", 5))
            Lib.rarities = require(library:WaitForChild("rarities", 5))
            pcall(function()
                Lib.rods = require(library:WaitForChild("rods", 5))
            end)
        end)
        Lib.ok = ok and type(Lib.fish) == "table" and type(Lib.zones) == "table" and type(Lib.rarities) == "table"
            and type(Lib.rarities.OrderedChanceGroups) == "table"
        return Lib.ok
    end
    local function groupOf(f)
        if f.ChanceGroup then
            return f.ChanceGroup
        end
        local r = Lib.rarities.Rarities and Lib.rarities.Rarities[f.Rarity]
        return r and r.ChanceGroup
    end
    local function rodStats()
        local rod = heldRod()
        local name = rod and rod.Name
        if not name then
            pcall(function()
                name = Workspace.PlayerStats[LocalPlayer.Name].T[LocalPlayer.Name].Stats.rod.Value
            end)
        end
        local r = name and type(Lib.rods) == "table" and Lib.rods[name]
        if type(r) ~= "table" then
            return 0, math.huge, name
        end
        return tonumber(r.Luck) or 0, tonumber(r.Strength) or math.huge, name
    end
    Zones.rod = function()
        local luck, _, name = rodStats()
        return name, luck
    end
    local function worldValue(n)
        local w = ReplicatedStorage:FindFirstChild("world")
        local v = w and w:FindFirstChild(n)
        return v and v.Value
    end
    -- Normal value: no mutation, no shiny/sparkling, at the average weight.
    local function valueOf(f)
        local price = tonumber(f.Price) or 0
        local wp = f.WeightPool
        if type(wp) == "table" and tonumber(wp[1]) and tonumber(wp[2]) and wp[2] > 0 then
            return math.ceil((wp[1] + wp[2]) / 2 / wp[2] * price), price
        end
        return price, price
    end
    Zones.valueOf = valueOf

    -- The server's roll, without bait, enchants, weather and events: a share
    -- for each rarity group (base chance + your rod's luck), split between
    -- the fish in it by their Chance.
    function Zones.odds(zoneName, boosted, boost)
        local zone = Lib.zones[zoneName]
        if type(zone) ~= "table" or type(zone.Pool) ~= "table" then
            return nil
        end
        local pool = table.clone(zone.Pool)
        if boosted and type(Lib.fish[boosted]) == "table" and not zone.IsHunt and not table.find(pool, boosted) then
            table.insert(pool, boosted)
        end
        local luck, strength = rodStats()
        local groups = Lib.rarities.OrderedChanceGroups
        local final, sums, members, carry = {}, {}, {}, 0
        for i = #groups, 1, -1 do
            local g = groups[i]
            local w = (tonumber(g.BaseChance) or 0) * ((zone.RarityBaseChanceBoosts and zone.RarityBaseChanceBoosts[g.Name]) or 1)
                + luck / 100 * (tonumber(g.LuckFactor) or 0) * ((zone.RarityLuckFactorBoosts and zone.RarityLuckFactorBoosts[g.Name]) or 1)
            local sum, m = 0, {}
            for _, name in pool do
                local f = Lib.fish[name]
                if type(f) == "table" and type(f.Chance) == "number" and f.Chance > 0 and groupOf(f) == g.Name
                    and (tonumber(f.BlockPassiveCapture) or 0) <= 5
                    and not (type(f.WeightPool) == "table" and (tonumber(f.WeightPool[1]) or 0) / 10 > strength) then
                    sum += f.Chance
                    m[name] = f.Chance / (tonumber(f.FinalChanceDivisor) or 1)
                end
            end
            members[i] = m
            if sum > 0 then
                final[i] = math.max(w, 0) + carry
                sums[i] = sum
                carry = 0
            else
                carry += w
            end
        end
        if carry > 0 and (final[2] or 0) > 0 then
            final[2] += carry
        end
        local season, cycle = worldValue("season"), worldValue("cycle")
        local rows, total = {}, 0
        for i, m in members do
            if final[i] and sums[i] then
                for name, c in m do
                    local f = Lib.fish[name]
                    if f.StrictZoneChance == nil then
                        local w = math.max(c / sums[i] * final[i], c / 2000)
                        if season and type(f.Seasons) == "table" and #f.Seasons > 0 and f.Seasons[1] ~= "None" then
                            w *= table.find(f.Seasons, season) and 1.2 or 0.9
                        end
                        if cycle and f.FavouriteTime and f.FavouriteTime ~= "None" and f.FavouriteTime ~= cycle then
                            w *= 0.25
                        end
                        if name == boosted then
                            w *= 1 + (tonumber(boost) or 70) / 100
                        end
                        if w > 0 then
                            local avg, top = valueOf(f)
                            total += w
                            table.insert(rows, { name = name, w = w, rarity = tostring(f.Rarity or "?"), value = avg, top = top })
                        end
                    end
                end
            end
        end
        if total <= 0 then
            return nil
        end
        local worth = 0
        for _, r in rows do
            r.chance = r.w / total
            worth += r.chance * r.value
        end
        table.sort(rows, function(a, b)
            return a.w > b.w
        end)
        return rows, worth
    end
    local function oddsCached(zoneName, boosted, boost)
        local key = zoneName .. "|" .. tostring(boosted) .. "|" .. tostring(boost)
        local c = Zones.cache[key]
        if c and os.clock() - c.at < 30 then
            return c.rows, c.worth
        end
        local rows, worth = Zones.odds(zoneName, boosted, boost)
        Zones.cache[key] = { rows = rows, worth = worth, at = os.clock() }
        return rows, worth
    end

    local function boostOf(part)
        local ab = part:FindFirstChild("Abundance")
        if ab and ab:IsA("StringValue") and ab.Value ~= "" and ab.Value ~= "Mutation" and type(Lib.fish[ab.Value]) == "table" then
            local ch = ab:FindFirstChild("Chance")
            return ab.Value, ch and tonumber(ch.Value) or nil
        end
        return nil, nil
    end
    local function displayName(name)
        local z = Lib.zones[name]
        return (type(z) == "table" and z.DisplayName) or name
    end
    local function folder()
        local z = Workspace:FindFirstChild("zones")
        return z and z:FindFirstChild("fishing")
    end

    function Zones.refresh()
        if not load() then
            Zones.info = "couldn't read the game's fish lists"
            return {}
        end
        table.clear(Zones.cache)
        local f = folder()
        if not f then
            Zones.info = "no fishing zones found"
            return {}
        end
        local byName, entries = {}, {}
        for _, part in f:GetChildren() do
            local zone = part:IsA("BasePart") and Lib.zones[part.Name]
            if type(zone) == "table" and type(zone.Pool) == "table" then
                local e = byName[part.Name]
                if not e then
                    e = { zone = part.Name, parts = {} }
                    byName[part.Name] = e
                    table.insert(entries, e)
                end
                table.insert(e.parts, part)
                local fish, boost = boostOf(part)
                if fish then
                    table.insert(entries, { zone = part.Name, parts = { part }, boosted = fish, boost = boost })
                end
            end
        end
        local labels, byLabel = {}, {}
        for _, e in entries do
            e.rows, e.worth = Zones.odds(e.zone, e.boosted, e.boost)
            local name = displayName(e.zone)
            local label
            if e.boosted then
                label = ("%s pool @ %s  ~%s C$"):format(e.boosted, name, comma(e.worth or 0))
            else
                label = ("%s  ~%s C$"):format(name, comma(e.worth or 0))
            end
            while byLabel[label] do
                label ..= " "
            end
            e.label = label
            byLabel[label] = e
        end
        table.sort(entries, function(a, b)
            if Settings.ZoneSort == "Name" then
                return a.label:lower() < b.label:lower()
            end
            return (a.worth or 0) > (b.worth or 0)
        end)
        for _, e in entries do
            table.insert(labels, e.label)
        end
        Zones.entries, Zones.labels, Zones.byLabel = entries, labels, byLabel
        local rod, luck = Zones.rod()
        Zones.info = ("%d zones · odds with %s (luck %s)"):format(#entries, rod or "no rod", tostring(luck or 0))
        return labels
    end

    function Zones.describe(label)
        local e = label and Zones.byLabel[label]
        if not e then
            return Zones.info
        end
        if not e.rows then
            return displayName(e.zone) .. ": nothing can bite here with your rod"
        end
        local lines = {
            ("%s%s\nAverage catch ~%s C$ (no mutation)"):format(displayName(e.zone), e.boosted and (" · " .. e.boosted .. " boosted") or "", comma(e.worth or 0)),
        }
        for i = 1, math.min(10, #e.rows) do
            local r = e.rows[i]
            local pct = r.chance < 0.001 and " <0.1%" or ("%5.1f%%"):format(r.chance * 100)
            table.insert(lines, ("%s  %s (%s)  ~%s C$"):format(pct, r.name, r.rarity, comma(r.value)))
        end
        if #e.rows > 10 then
            table.insert(lines, ("... and %d more"):format(#e.rows - 10))
        end
        return table.concat(lines, "\n")
    end

    -- The ESP text for one zone part.
    function Zones.espText(part)
        if not load() or type(Lib.zones[part.Name]) ~= "table" then
            return nil
        end
        local fish, boost = boostOf(part)
        local rows, worth = oddsCached(part.Name, fish, boost)
        local lines = { displayName(part.Name) .. (fish and (" · " .. fish .. " pool") or "") }
        if rows then
            lines[1] ..= ("  ~%s C$"):format(comma(worth or 0))
            for i = 1, math.min(3, #rows) do
                local c = rows[i].chance
                table.insert(lines, ("%s %s ~%s"):format(c < 0.01 and "<1%" or ("%.0f%%"):format(c * 100), rows[i].name, comma(rows[i].value)))
            end
        end
        return table.concat(lines, "\n")
    end

    -- A water surface inside the zone, near its middle.
    local function surfaceIn(part)
        local cf, size = part.CFrame, part.Size
        local best, bestD
        local sx, sz = math.min(size.X * 0.2, 40), math.min(size.Z * 0.2, 40)
        for ix = -2, 2 do
            for iz = -2, 2 do
                local p = cf:PointToWorldSpace(Vector3.new(ix * sx, size.Y / 2, iz * sz))
                local hit = Plat.ray(p + Vector3.new(0, 30, 0), Vector3.new(0, -(size.Y + 60), 0))
                if hit and hit.Material == Enum.Material.Water then
                    local d = math.abs(ix) + math.abs(iz)
                    if not bestD or d < bestD then
                        best, bestD = hit.Position, d
                    end
                end
            end
        end
        return best
    end
    function Zones.go(label)
        local e = label and Zones.byLabel[label]
        if not e then
            notify("Pick a zone first")
            return
        end
        local part, vol
        for _, p in e.parts do
            if p.Parent then
                local v = p.Size.X * p.Size.Y * p.Size.Z
                if not vol or v > vol then
                    part, vol = p, v
                end
            end
        end
        local root = myRoot()
        if not (part and root) then
            notify("That zone isn't there any more, refresh the list")
            return
        end
        local top = part.CFrame:PointToWorldSpace(Vector3.new(0, part.Size.Y / 2 + 4, 0))
        pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, top, 6)
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.new(top) * root.CFrame.Rotation
        root.Anchored = true
        local spot
        pcall(function()
            for _ = 1, 10 do
                task.wait(0.2)
                spot = surfaceIn(part)
                if spot or not root.Parent then
                    break
                end
            end
        end)
        root.Anchored = false
        local r = myRoot()
        if not r then
            return
        end
        r.AssemblyLinearVelocity = Vector3.zero
        if spot then
            Plat.spot(spot)
            r.CFrame = CFrame.new(spot + Vector3.new(0, 3.2, 0)) * r.CFrame.Rotation
        else
            local hit = Plat.ray(top, Vector3.new(0, -(part.Size.Y + 200), 0))
            if hit then
                r.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3.5, 0)) * r.CFrame.Rotation
            end
        end
        notify("At " .. displayName(e.zone) .. (spot and " (standing on the water, cast away)" or ""))
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
        local sellAll = ev("SellAll")
        if not sellAll then
            Sell.info = "SellAll not found"
            return
        end
        local m, d = nearest()
        local root = myRoot()
        local island
        if not m and root then
            local bestD
            for _, name in MERCHANT_ISLANDS do
                local cf = Tp.camera(name)
                if cf then
                    local dd = (cf.Position - root.Position).Magnitude
                    if not bestD or dd < bestD then
                        island, bestD = name, dd
                    end
                end
            end
            if not island then
                Sell.info = "no merchant loaded near you"
                return
            end
        end
        local done = false
        Move.trip("selling", function()
            if not m then
                Sell.info = "going to " .. island .. " to sell"
                Tp.land(Tp.camera(island))
                task.wait(0.8)
                m, d = nearest()
                if not m then
                    return
                end
            end
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
        elseif not m then
            Sell.info = "couldn't find the merchant at " .. tostring(island)
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
    local function mark(key, adornee, color, text, opts)
        local m = marks[key]
        if m and m.adornee == adornee and adornee.Parent and m.plain == (opts ~= nil) then
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
        bb.Size = opts and opts.size or UDim2.fromOffset(180, 28)
        if opts and opts.offset then
            bb.StudsOffsetWorldSpace = opts.offset
        else
            bb.StudsOffset = Vector3.new(0, 3, 0)
        end
        bb.MaxDistance = opts and opts.range or math.huge
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
        if not opts and (adornee:IsA("Model") or adornee:IsA("BasePart")) then
            hl = Instance.new("Highlight")
            hl.Adornee = adornee
            hl.FillColor, hl.OutlineColor = color, color
            hl.FillTransparency = 0.75
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = folder
        end
        marks[key] = { bb = bb, hl = hl, label = label, adornee = adornee, seen = true, plain = opts ~= nil }
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
        fishingZones = fishingZones and fishingZones.Parent and fishingZones
            or (Workspace:FindFirstChild("zones") and Workspace.zones:FindFirstChild("fishing"))
        if fishingZones and Settings.EspZones then
            for _, z in fishingZones:GetChildren() do
                if z:IsA("BasePart") then
                    local text = Zones.espText(z)
                    if text then
                        local boosted = z:FindFirstChild("Abundance") ~= nil
                        mark(z, z, boosted and Color3.fromRGB(120, 220, 255) or Color3.fromRGB(235, 235, 235), text, {
                            size = UDim2.fromOffset(240, 64),
                            offset = Vector3.new(0, math.min(z.Size.Y / 2, 60) + 2, 0),
                            range = 1500,
                        })
                    end
                end
            end
        elseif fishingZones and (Settings.EspPools or Settings.EspEvents) then
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
    toggle(S, "AutoShake", "Auto shake", "Shakes while the shake button is up")
    dropdown(S, "ShakeMethod", "Method", { "Auto", "Remote", "Tap", "Select + Enter", "Mouse click", "VirtualUser click" },
        "Auto: the remote on the new shake, Tap on a phone / Select + Enter on a computer for the old one. Remote: fastest, no input at all. Tap: its own finger, so your movement stick keeps working. Select + Enter and Mouse click use VirtualInputManager, VirtualUser click doesn't")
    slider(S, "ShakeDelay", "Every", 0.05, 1, 2, " s", "Time between shakes. The new shake takes one every 0.25s; faster can be thrown away")
    status(S, function()
        return ("Now: %s\nShakes: %d"):format(Fish.shakeInfo or "off", Fish.shakes)
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
    local Tab = Window:AddTab("Zones", "compass", "What bites where, and what it's worth")
    local Z = Tab:AddLeftGroupbox("Fishing zones", "compass")
    local pick = Z:AddDropdown("ZonePick", {
        Text = "Zone", Values = {}, Searchable = true,
        Tooltip = "Every fishing zone in this sea with the average value of a catch there (no mutations). Pools are zones with a boosted fish",
        Callback = function(v)
            Settings.ZonePick = v
        end,
    })
    local function refresh()
        local labels = Zones.refresh()
        pcall(function()
            pick:SetValues(labels)
        end)
    end
    Z:AddDropdown("ZoneSort", {
        Text = "Sort by", Values = { "Best value", "Name" }, Default = Settings.ZoneSort,
        Callback = function(v)
            Settings.ZoneSort = v
            task.spawn(refresh)
        end,
    })
    Z:AddButton({ Text = "Teleport to zone", Func = function()
        task.spawn(Zones.go, Settings.ZonePick)
    end, Tooltip = "Puts you on the water in the middle of the zone, with something to stand on so you can cast" })
    Z:AddButton({ Text = "Refresh zones", Func = function()
        task.spawn(refresh)
    end, Tooltip = "Pools and event zones come and go, and the odds change with the rod you hold" })
    task.spawn(refresh)
    local D = Tab:AddRightGroupbox("Most likely catches", "list")
    status(D, function()
        return Zones.describe(Settings.ZonePick)
    end)
    local E = Tab:AddRightGroupbox("Zone ESP", "eye")
    toggle(E, "EspZones", "Show zones", "Name, average catch value and the top 3 fish over every fishing zone")
    E:AddLabel("Odds use your rod's luck and the season and time of day. Bait, enchants, weather and events change them, so treat them as a guide.", true)
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
    local Tab = Window:AddTab("Teleport", "map-pin", "Islands, caves, your own spots")
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
        task.spawn(Tp.go, Settings.TpSpot)
    end, Tooltip = "Works without the place being loaded. Zones marked watched are checked by the server: going into one you haven't unlocked is risky" })
    T:AddButton({ Text = "Refresh spots", Func = function()
        task.spawn(refresh)
    end, Tooltip = "Adds spawn points that have loaded in since" })
    task.spawn(refresh)
    status(T, function()
        return Tp.info
    end)
    local Sv = Tab:AddRightGroupbox("Your spots", "bookmark")
    Sv:AddInput("SpotName", {
        Text = "Name", Placeholder = "e.g. my fishing spot", Default = "", Finished = false,
        Callback = function(t)
            Settings.SpotName = t
        end,
    })
    Sv:AddButton({ Text = "Save where I am", Func = function()
        Tp.save(Settings.SpotName)
        refresh()
    end, Tooltip = "Saved to a file, so it's still there next time" })
    Sv:AddButton({ Text = "Delete picked spot", Func = function()
        Tp.forget(Settings.TpSpot)
        refresh()
    end, Tooltip = "Pick one of your spots (they start with *) in the list first" })
end

do
    local Tab = Window:AddTab("Player", "user", "Movement, water, air, boat")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Walk speed")
    slider(M, "WalkSpeed", "Speed", 16, 150, 0)
    toggle(M, "JumpOn", "Jump power")
    slider(M, "JumpPower", "Power", 50, 300, 0)
    toggle(M, "InfJump", "Infinite jump", "Jump again in the air")
    toggle(M, "Fly", "Fly", "Moves where your camera looks. Space goes up, Left Ctrl goes down; on a phone look up or down while you move")
    slider(M, "FlySpeed", "Fly speed", 10, 300, 0)
    toggle(M, "Noclip", "Noclip", "Walk through walls")
    local W = Tab:AddLeftGroupbox("Water and air", "droplet")
    toggle(W, "WaterWalk", "Walk on water", "Stand and cast on any water. Dive a couple of studs down to go under")
    toggle(W, "AntiDrown", "Anti drown", "When oxygen (or pressure, heat, cold) gets low, goes back to the last spot where nothing was running out, waits until it's full and comes back")
    slider(W, "DrownAt", "Go up at", 10, 80, 0, "%")
    toggle(W, "DrownReturn", "Come back after")
    status(W, function()
        return ("Now: %s\nLevels: %s\nSaved you: %d times"):format(Air.info, Air.levels(), Air.saves)
    end)
    local B = Tab:AddRightGroupbox("Boat", "ship")
    toggle(B, "BoatSpeedOn", "Faster boat", "More top speed, speed-up and turning for your own boat")
    slider(B, "BoatSpeed", "Speed", 1, 10, 1, "x")
    toggle(B, "BoatFly", "Flying boat", "Any boat flies. R goes up, F goes down; on a phone look up or down while you drive")
    slider(B, "BoatFlySpeed", "Up / down speed", 10, 200, 0)
    toggle(B, "BoatInfBoost", "Infinite boost", "Boats with a boost (jetskis) never run out")
    status(B, function()
        return Boat.info
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

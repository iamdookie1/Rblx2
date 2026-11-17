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
--   Shake    a PlayerGui "shakeui". The server invokes RF/LureShake/Start,
--            LureShakeController puts a button in safezone whose Activated
--            runs onShake: RE/LureShake/Shake at most every 0.25 / ShakeScale
--            s, each one taking a seeded random bite out of the shake timer.
--            Calling that connection is a real shake with no input. The old
--            template (resources.replicated.fishing.shakeui, a server Script
--            counting real clicks on safezone "button"s) is still in the
--            game; those buttons get pressed for real.
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
    EventAlert = true, EventAutoGo = false, EventUseBoat = false,
    -- player
    SpeedOn = false, WalkSpeed = 32, JumpOn = false, JumpPower = 80, InfJump = false,
    Fly = false, FlySpeed = 80, Noclip = false, WaterWalk = false,
    AntiDrown = false, DrownAt = 35, DrownReturn = true,
    -- boat
    BoatSpeedOn = false, BoatSpeed = 2, BoatTurnOn = false, BoatTurn = 2, BoatFly = false, BoatFlySpeed = 60,
    BoatInfBoost = false, BoatAnyBoost = false, BoatBoostPower = 0.75, BoatAlwaysBoost = false,
    BoatInstant = false, BoatSteady = false, BoatKeepSpeed = false, BoatNoclip = false, BoatPick = nil,
    -- world
    EspPools = false, EspEvents = false, EspChests = false, EspMeteors = false, EspNpcs = false,
    AutoChests = false, AutoMeteors = false,
    -- items
    JunkMode = "Off", JunkBelow = 50, JunkDelay = 0.5, CatchAlert = true, CatchAlertRarity = "Mythical", CatchAlertValue = 100000,
    AutoMaps = false, AutoFav = false, FavRarity = "Mythical", FavMutated = false, FavValue = 0,
    AutoBait = false, BaitStat = "Luck", AutoCages = false,
    AppraiseFor = "Any mutation", AppraiseTries = 20, AppraiseAnywhere = false,
    TotemPick = nil, TotemAuto = false, TotemWhen = "Night", TotemEvery = 15,
    -- misc
    AutoDaily = false, AutoTotem = false, AutoRodRewards = false, AntiAfk = true, AutoRejoin = false, Codes = "",
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

    -- The new shake (LureShakeController): the server invokes RF/LureShake/Start
    -- with { seed, initialTimer, ShakePower, ShakeScale, ButtonName }. The
    -- button's Activated is connected to the game's onShake, which fires
    -- RE/LureShake/Shake at most once every 0.25 / ShakeScale s and knocks
    -- Random.new(seed):NextNumber(0.5, 1.5) * ShakePower off the timer; the
    -- shake ends when the timer (which also runs down by itself) hits 0.
    --   Game handler  calls that onShake straight from the button's
    --                 connections every frame: no input at all, and as fast
    --                 as the game itself allows
    --   Remote        fires RE/LureShake/Shake on your own timer
    --   Tap / Select + Enter / Mouse click / VirtualUser click
    --                 press the button like a player would
    -- An old shakeui (resources.replicated.fishing.shakeui) is still in the
    -- game; its buttons only count real presses, so on that one the handler
    -- and remote methods fall back to a press.
    local Shake = { data = nil, started = 0, need = nil, sent = 0 }
    Fish.shake = Shake
    local LureShake
    pcall(function()
        LureShake = require(ReplicatedStorage:WaitForChild("client", 5).legacyControllers.LureShakeController)
    end)
    local function shakesNeeded(d)
        local seed, timer, power = tonumber(d.seed), tonumber(d.initialTimer), tonumber(d.ShakePower)
        if not (seed and timer and power and power > 0) then
            return nil
        end
        local rng, n = Random.new(seed), 0
        while timer > 0 and n < 500 do
            timer -= rng:NextNumber(0.5, 1.5) * power
            n += 1
        end
        return n
    end
    if type(LureShake) == "table" and type(rawget(LureShake, "StartMinigame")) == "function" then
        local original = LureShake.StartMinigame
        LureShake.StartMinigame = function(self, data, ...)
            if type(data) == "table" then
                Shake.data, Shake.started, Shake.sent = data, os.clock(), 0
                Shake.need = shakesNeeded(data)
            end
            return original(self, data, ...)
        end
        table.insert(Cleanups, function()
            LureShake.StartMinigame = original
        end)
    end
    local function interval()
        local d = Shake.data
        local scale = d and tonumber(d.ShakeScale) or 1
        return 0.25 / math.max(scale, 0.01)
    end
    Shake.interval = interval
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
    local canHandler = typeof(getconnections) == "function" or typeof(firesignal) == "function"
    local function methodFor(legacy)
        local m = Settings.ShakeMethod
        if legacy and (m == "Game handler" or m == "Remote" or m == "Auto") then
            if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
                return "Tap"
            end
            return "Select + Enter"
        end
        if m == "Auto" then
            return canHandler and "Game handler" or "Remote"
        end
        if m == "Game handler" and not canHandler then
            return "Remote"
        end
        return m
    end
    local function progress(kind)
        local need = Shake.need
        return ("%d%s shakes, %s"):format(Shake.sent, need and (" / ~" .. need) or "", kind)
    end

    -- Game handler: run the button's own Activated connections (the game's
    -- onShake) every frame; it rate-limits itself.
    local handlers = setmetatable({}, { __mode = "k" })
    local function runHandlers(btn)
        local list = handlers[btn]
        if list == nil then
            list = false
            if typeof(getconnections) == "function" then
                local ok, cons = pcall(getconnections, btn.Activated)
                if ok and type(cons) == "table" and #cons > 0 then
                    list = cons
                end
            end
            handlers[btn] = list
        end
        if list then
            for _, c in list do
                local fn = c.Function
                if type(fn) == "function" then
                    pcall(fn)
                elseif c.Fire then
                    pcall(c.Fire, c)
                end
            end
            return true
        end
        if typeof(firesignal) == "function" then
            return (pcall(firesignal, btn.Activated))
        end
        return false
    end
    Fish.shakeInfo = "off"
    local lastShake = 0
    local pressedAt = setmetatable({}, { __mode = "k" })
    local function step(fromFrame)
        if not Settings.AutoShake then
            Fish.shakeInfo = "off"
            return
        end
        local ui = shakeUi()
        if not (ui and ui.Enabled) then
            Fish.shakeInfo = "waiting for a shake"
            if Shake.data and os.clock() - Shake.started > 1 then
                Shake.data, Shake.need = nil, nil
            end
            if not Shake.data then
                Shake.sent = 0
            end
            return
        end
        local btn, legacy = shakeButton(ui)
        local method = methodFor(legacy)
        local kind = legacy and "old shake" or "new shake"
        if method == "Game handler" then
            if not fromFrame then
                return
            end
            if not btn then
                local safe = ui:FindFirstChild("safezone")
                btn = safe and safe:FindFirstChildWhichIsA("GuiButton", true)
            end
            if btn and runHandlers(btn) then
                if Shake.data then
                    local n = math.floor((os.clock() - Shake.started) / interval()) + 1
                    Shake.sent = Shake.need and math.min(n, Shake.need) or n
                end
                Fish.shakeInfo = ("shaking (game handler): %s"):format(progress(kind))
            elseif not btn then
                Fish.shakeInfo = "waiting for the shake button"
            end
            return
        end
        if fromFrame then
            return
        end
        local now = os.clock()
        if method == "Remote" then
            if now - lastShake < math.max(0, Settings.ShakeDelay) then
                return
            end
            lastShake = now
            if remoteShake(btn, legacy) then
                Shake.sent += 1
                Fish.shakeInfo = ("shaking (remote): %s"):format(progress(kind))
            else
                Fish.shakeInfo = "no shake remote found"
            end
            return
        end
        if now - lastShake < math.max(0.03, Settings.ShakeDelay) then
            return
        end
        if not btn then
            Fish.shakeInfo = "waiting for the shake button"
            return
        end
        if pressedAt[btn] and now - pressedAt[btn] < (legacy and 0.5 or interval()) then
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
            Shake.sent += 1
            Fish.shakeInfo = ("shaking (%s): %s"):format(method, progress(kind))
        elseif remoteShake(btn, legacy) then
            Fish.shakeInfo = ("%s isn't available here, used the remote (%s)"):format(method, kind)
        else
            Fish.shakeInfo = method .. " isn't available here"
        end
    end
    bind(RunService.Heartbeat, function()
        if alive() then
            step(true)
        end
    end)
    loop(0.03, function()
        step(false)
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
    Tp.seaLevel = SEA_LEVEL
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
-- swap in a copy with the mods on. Boats are spawned with RF/Boats/Spawn
-- (RE/Boats/Close first if you're docked, like the quick-access menu), you
-- sit with VehicleSeat:Sit, and a boat is moved with PivotTo while you drive
-- it plus its PlanePart (the water plane it's held to) set to the new water
-- height.
local Boat = { info = "", owned = {} }
do
    local Phys, Vessels
    local function phys()
        if Phys == nil then
            local ok, m = pcall(function()
                return require(ReplicatedStorage.client.legacyControllers.BoatController)
            end)
            Phys = (ok and type(m) == "table" and type(m.Physics) == "table") and m.Physics or false
        end
        return Phys or nil
    end
    local function vessels()
        if Vessels == nil then
            local ok, m = pcall(function()
                return require(ReplicatedStorage.shared.modules.vessels)
            end)
            Vessels = (ok and type(m) == "table") and m or false
        end
        return Vessels or nil
    end
    local function num(v, default)
        return tonumber(v) or default
    end
    function Boat.current()
        local p = phys()
        local b = p and p.currentBoat
        if type(b) == "table" and b.Instance and b.Instance.Parent and b.VehicleSeat then
            return b, p
        end
        return nil, p
    end
    function Boat.list()
        local v = vessels()
        local out = {}
        if v and type(v.library) == "table" then
            for name, data in v.library do
                if type(data) == "table" and type(name) == "string" then
                    local ok, has = pcall(v.Has, v, LocalPlayer, name)
                    if ok and has then
                        table.insert(out, name)
                    end
                end
            end
        end
        table.sort(out)
        Boat.owned = out
        return out
    end

    -- Mods
    local base, modded, sig, plane, weSetVertical
    local function anyMod()
        return Settings.BoatSpeedOn or Settings.BoatTurnOn or Settings.BoatFly or Settings.BoatInfBoost or Settings.BoatAlwaysBoost
            or Settings.BoatAnyBoost or Settings.BoatInstant or Settings.BoatSteady or Settings.BoatKeepSpeed
    end
    local function signature()
        return table.concat({
            tostring(Settings.BoatSpeedOn), tostring(Settings.BoatSpeed), tostring(Settings.BoatTurnOn), tostring(Settings.BoatTurn),
            tostring(Settings.BoatFly), tostring(Settings.BoatFlySpeed), tostring(Settings.BoatAnyBoost), tostring(Settings.BoatBoostPower),
            tostring(Settings.BoatInstant), tostring(Settings.BoatSteady), tostring(Settings.BoatKeepSpeed),
        }, "|")
    end
    local function build(b)
        local m = table.clone(b)
        if Settings.BoatSpeedOn then
            local k = Settings.BoatSpeed
            m.MaxSpeed = num(b.MaxSpeed, 0) * k
            m.Accel = num(b.Accel, 1) * k
            if num(b.BoostMaxSpeed) then
                m.BoostMaxSpeed = b.BoostMaxSpeed * k
            end
        end
        if Settings.BoatTurnOn then
            m.TurningSpeed = num(b.TurningSpeed, 1) * Settings.BoatTurn
        end
        if Settings.BoatInstant then
            m.Accel = math.max(num(m.Accel, 1), 1) * 50
            m.StopEfficiency = math.max(num(b.StopEfficiency, 1), 1) * 4
            m.BackwardsEfficiency = math.max(num(b.BackwardsEfficiency, 1), 1)
        end
        if Settings.BoatSteady then
            m.Bobbing, m.SteerTilt, m.ForwardTilt = 0, 0, 0
        end
        if Settings.BoatKeepSpeed then
            m.NoMomentumLossOnImpact = true
        end
        if Settings.BoatAnyBoost then
            m.BoostEnabled = true
            m.BoostMaxSpeed = num(m.MaxSpeed, 50) * Settings.BoatBoostPower
            m.BoostMaxTime = num(b.BoostMaxTime, 3)
            m.BoostChargeTime = num(b.BoostChargeTime, 4)
        end
        if Settings.BoatFly then
            m.FlyingBoat = true
            m.VerticalMaxSpeed = Settings.BoatFlySpeed
        end
        return m
    end
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
    local function upInput(b)
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
            local seat = b.VehicleSeat
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
        local b, p = Boat.current()
        if not p then
            Boat.info = "boat controller not found"
            return
        end
        local data = p.currentBoatData
        if not (b and data) then
            if modded or plane then
                restore(p)
            end
            Boat.info = "no boat of yours out"
            return
        end
        local hum = myHum()
        Boat.info = ("%s: %s studs/s%s"):format(tostring(b.Name or b.Instance.Name), comma(num(p.currentTotalSpeed, 0)),
            (hum and hum.SeatPart == b.VehicleSeat) and "" or " (not in it)")
        if not anyMod() then
            if modded or plane then
                restore(p)
            end
            return
        end
        local want = signature()
        if data ~= modded or want ~= sig then
            if data ~= modded then
                base = data
            end
            modded, sig = build(base), want
            p.currentBoatData = modded
            if p.controlsEnabled then
                pcall(p.EnableControls, p)
            end
        end
        if Settings.BoatFly then
            local pc = b.PlaneConstraint
            if pc and pc.Enabled then
                pc.Enabled = false
                plane = pc
            end
            local up = upInput(b)
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
        local d = p.currentBoatData
        if d and d.BoostEnabled then
            if Settings.BoatInfBoost or Settings.BoatAlwaysBoost then
                p.pboostCharge = 1
            end
            if Settings.BoatAlwaysBoost and p.controlsEnabled and not p.pboostActive then
                p.pboostActive = true
                pcall(function()
                    p.PlayerBoostStarted:Fire(1)
                end)
            end
        end
    end)

    -- Boat noclip: through rocks, docks and islands (it stays on the water).
    local ghosted = {}
    local function unghost()
        for part in ghosted do
            if part.Parent then
                part.CanCollide = true
            end
        end
        table.clear(ghosted)
    end
    loop(0.5, function()
        local b = Boat.current()
        if Settings.BoatNoclip and b then
            for _, part in b.Instance:GetDescendants() do
                if part:IsA("BasePart") and part.CanCollide then
                    ghosted[part] = true
                    part.CanCollide = false
                end
            end
        elseif next(ghosted) then
            unghost()
        end
    end)
    table.insert(Cleanups, function()
        restore(phys())
        unghost()
    end)

    -- Spawning, sitting, moving
    function Boat.spawn(name)
        name = name or Settings.BoatPick
        if not name or name == "" then
            notify("Pick one of your boats first")
            return false
        end
        local spawnFn, close = net("RF/Boats/Spawn"), net("RE/Boats/Close")
        if not spawnFn then
            notify("Boat spawn remote not found")
            return false
        end
        local dock = LocalPlayer:GetAttribute("LastDock")
        if close and type(dock) == "string" and dock ~= "None" then
            close:FireServer()
            local t = os.clock()
            while LocalPlayer:GetAttribute("LastDock") == dock and os.clock() - t < 3 do
                task.wait(0.1)
            end
        end
        local ok, res = pcall(spawnFn.InvokeServer, spawnFn, name)
        if not ok then
            notify("Couldn't spawn " .. name .. ": " .. tostring(res))
            return false
        end
        if type(res) == "string" and res ~= "" then
            notify(name .. ": " .. res)
        end
        local t = os.clock()
        while not Boat.current() and os.clock() - t < 8 do
            task.wait(0.2)
        end
        return Boat.current() ~= nil
    end
    function Boat.sit(b)
        local hum, root = myHum(), myRoot()
        if not (hum and root and b) then
            return false
        end
        local seat = b.VehicleSeat
        if hum.SeatPart == seat then
            return true
        end
        if seat.Occupant then
            return false
        end
        pcall(hum.UnequipTools, hum)
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = seat.CFrame + Vector3.new(0, 3, 0)
        task.wait(0.15)
        pcall(seat.Sit, seat, hum)
        local t = os.clock()
        while hum.SeatPart ~= seat and os.clock() - t < 1.5 do
            task.wait(0.1)
        end
        if hum.SeatPart ~= seat then
            local prompt = seat:FindFirstChild("sitprompt")
            if prompt and typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
                task.wait(0.6)
            end
        end
        return hum.SeatPart == seat
    end
    function Boat.moveTo(surface)
        local b, p = Boat.current()
        if not (b and surface) then
            return false
        end
        local inst = b.Instance
        local pivot = inst:GetPivot()
        local planeY = (b.PlanePart and b.PlanePart.Position.Y) or Tp.seaLevel
        local _, yaw = pivot:ToOrientation()
        pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, surface, 6)
        inst:PivotTo(CFrame.new(surface.X, surface.Y + (pivot.Position.Y - planeY), surface.Z) * CFrame.fromOrientation(0, yaw, 0))
        if b.PlanePart then
            b.PlanePart.CFrame = CFrame.new(0, surface.Y, 0)
        end
        if b.Base then
            b.Base.AssemblyLinearVelocity = Vector3.zero
            b.Base.AssemblyAngularVelocity = Vector3.zero
        end
        if p then
            p.currentSpeed, p._springVelocity = 0, 0
        end
        return true
    end
    -- Open water near a spot (the closest ring of points that hits water).
    function Boat.waterNear(pos, maxR)
        for r = 0, maxR or 700, 35 do
            local n = r == 0 and 1 or math.max(8, math.floor(r / 10))
            for i = 1, n do
                local a = i / n * math.pi * 2
                local x, z = pos.X + math.cos(a) * r, pos.Z + math.sin(a) * r
                local hit = Plat.ray(Vector3.new(x, math.max(pos.Y, Tp.seaLevel) + 150, z), Vector3.new(0, -500, 0))
                if hit and hit.Material == Enum.Material.Water then
                    return hit.Position
                end
            end
        end
        return nil
    end
    -- Get in your boat (spawning the picked one if none is out) and drive it
    -- to a water surface.
    function Boat.go(surface, what)
        if Busy.reason then
            notify("Busy: " .. Busy.reason)
            return false
        end
        if not surface then
            notify("No water found there for the boat")
            return false
        end
        local b = Boat.current()
        if not b then
            notify("Spawning your " .. tostring(Settings.BoatPick or "boat") .. "...")
            if not Boat.spawn() then
                notify("No boat: pick one of yours in the Boat tab (and be somewhere it can spawn)")
                return false
            end
            b = Boat.current()
        end
        Busy.reason = "moving the boat"
        local ok, err = pcall(function()
            if not Boat.sit(b) then
                error("couldn't get in the boat (someone in the seat?)")
            end
            task.wait(0.1)
            Boat.moveTo(surface)
        end)
        Busy.reason = nil
        if not ok then
            notify((tostring(err):gsub("^.-:%d+: ", "")))
            return false
        end
        notify("Boat at " .. (what or "the spot"))
        return true
    end
    function Boat.bring()
        local root = myRoot()
        if not root then
            return
        end
        local water = Boat.waterNear(root.Position, 400)
        if not water then
            notify("No water near you")
            return
        end
        Boat.go(water, "you")
    end
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
    function Zones.lib()
        return load() and Lib or nil
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

    -- Events: hunts and limited pools (Megalodon, sharks, Kraken, orcas,
    -- whales, Scylla, Lovestorm, Golden Tide, ...) show up as new parts in
    -- workspace.zones.fishing, so they're caught the moment they spawn.
    local EVENT_WORDS = {
        "Megalodon", "Shark", "Kraken", "Orca", "Whale", "Leviathan", "Scylla", "Hunt", "Lovestorm", "Golden Tide",
        "Isonade", "Narwhal", "Beluga", "Bloop", "Dragon", "Animal Pool", "Octophant", "Frightful", "Phantasmal",
        "Nessie", "Algae Pool", "Zeus Pool", "Poseidon Pool", "Ashfall", "Cults Curse", "Sharky", "Glitched", "Smurf",
        "Lucky Gold", "Storm", "Blue Moon", "Terrosunder", "Kerauno", "Birthday", "Anniversary", "Shamrock", "Serpent",
        "Frenzy", "Haunt", "Charybdis", "Skolopendra",
    }
    function Zones.isEvent(name)
        if not load() then
            return false
        end
        local z = Lib.zones[name]
        if type(z) == "table" and z.IsHunt then
            return true
        end
        for _, w in EVENT_WORDS do
            if name:find(w, 1, true) then
                return true
            end
        end
        return false
    end
    local function rarityOrder(r)
        local x = Lib.rarities.Rarities and Lib.rarities.Rarities[r]
        return x and tonumber(x.Order) or 0
    end
    -- The catch worth going for: the most valuable fish there.
    local function bestOf(rows)
        local best
        for _, r in rows or {} do
            if not best or r.value > best.value then
                best = r
            end
        end
        return best
    end
    Zones.bestOf = bestOf

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
                    e = { zone = part.Name, parts = {}, event = Zones.isEvent(part.Name) }
                    byName[part.Name] = e
                    table.insert(entries, e)
                end
                table.insert(e.parts, part)
                local fish, boost = boostOf(part)
                if fish then
                    table.insert(entries, { zone = part.Name, parts = { part }, boosted = fish, boost = boost, event = e.event })
                end
            end
        end
        local labels, byLabel = {}, {}
        for _, e in entries do
            e.rows, e.worth = Zones.odds(e.zone, e.boosted, e.boost)
            e.best = bestOf(e.rows)
            local name = displayName(e.zone)
            local label
            if e.boosted then
                label = ("%s pool @ %s  ~%s C$"):format(e.boosted, name, comma(e.worth or 0))
            else
                label = ("%s  ~%s C$"):format(name, comma(e.worth or 0))
            end
            if e.event then
                label = "[EVENT] " .. label
            end
            while byLabel[label] do
                label ..= " "
            end
            e.label = label
            byLabel[label] = e
        end
        table.sort(entries, function(a, b)
            if a.event ~= b.event then
                return a.event == true
            end
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
            ("%s%s%s\nAverage catch ~%s C$ (no mutation)"):format(e.event and "EVENT: " or "", displayName(e.zone),
                e.boosted and (" · " .. e.boosted .. " boosted") or "", comma(e.worth or 0)),
        }
        if e.best then
            table.insert(lines, ("Best: %s (%s) ~%s C$"):format(e.best.name, e.best.rarity, comma(e.best.value)))
        end
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
        local lines = { (Zones.isEvent(part.Name) and "[EVENT] " or "") .. displayName(part.Name) .. (fish and (" · " .. fish .. " pool") or "") }
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
    local function biggest(parts)
        local part, vol
        for _, p in parts do
            if p.Parent then
                local v = p.Size.X * p.Size.Y * p.Size.Z
                if not vol or v > vol then
                    part, vol = p, v
                end
            end
        end
        return part
    end

    -- Go to a zone part: on foot (onto the water, with something to stand
    -- on) or in your boat.
    function Zones.goPart(part, withBoat)
        local root = myRoot()
        if not (part and part.Parent and root) then
            notify("That zone isn't there any more, refresh the list")
            return
        end
        local name = displayName(part.Name)
        local top = part.CFrame:PointToWorldSpace(Vector3.new(0, part.Size.Y / 2 + 4, 0))
        if withBoat then
            pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, top, 6)
            local spot
            for _ = 1, 8 do
                spot = surfaceIn(part)
                if spot then
                    break
                end
                task.wait(0.25)
            end
            if not spot then
                local lo = part.Position.Y - part.Size.Y / 2
                local hi = part.Position.Y + part.Size.Y / 2
                if Tp.seaLevel >= lo - 5 and Tp.seaLevel <= hi + 5 then
                    spot = Vector3.new(part.Position.X, Tp.seaLevel, part.Position.Z)
                end
            end
            Boat.go(spot, name)
            return
        end
        if Busy.reason then
            notify("Busy: " .. Busy.reason)
            return
        end
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
        notify("At " .. name .. (spot and " (standing on the water, cast away)" or ""))
    end
    function Zones.go(label, withBoat)
        local e = label and Zones.byLabel[label]
        if not e then
            notify("Pick a zone first")
            return
        end
        Zones.goPart(biggest(e.parts), withBoat)
    end

    -- What's live right now, best first.
    function Zones.events()
        local out = {}
        for _, e in Zones.entries do
            if e.event and biggest(e.parts) then
                table.insert(out, e)
            end
        end
        table.sort(out, function(a, b)
            return (a.worth or 0) > (b.worth or 0)
        end)
        return out
    end
    function Zones.eventsText()
        local live = Zones.events()
        if #live == 0 then
            return "No events up right now. You get told the moment one spawns."
        end
        local root = myRoot()
        local lines = {}
        for i = 1, math.min(6, #live) do
            local e = live[i]
            local part = biggest(e.parts)
            local dist = root and part and comma((part.Position - root.Position).Magnitude) or "?"
            table.insert(lines, ("%s · ~%s C$%s · %s studs"):format(displayName(e.zone), comma(e.worth or 0),
                e.best and (" · best " .. e.best.name) or "", dist))
        end
        return table.concat(lines, "\n")
    end
    function Zones.goBestEvent(withBoat)
        if #Zones.entries == 0 then
            Zones.refresh()
        end
        local e = Zones.events()[1]
        if not e then
            notify("No events up right now")
            return
        end
        Zones.goPart(biggest(e.parts), withBoat)
    end

    local pending
    local function changed()
        if pending then
            return
        end
        pending = true
        task.delay(0.6, function()
            pending = false
            if not alive() then
                return
            end
            Zones.refresh()
            if Zones.onChange then
                pcall(Zones.onChange, Zones.labels)
            end
        end)
    end
    local alerted = {}
    local function check(part, atStart)
        if not (alive() and part:IsA("BasePart") and part.Parent and load()) then
            return
        end
        local name = part.Name
        local zone = Lib.zones[name]
        if type(zone) ~= "table" or type(zone.Pool) ~= "table" then
            return
        end
        local boosted, boost = boostOf(part)
        local event = Zones.isEvent(name)
        local rarePool = boosted and type(Lib.fish[boosted]) == "table" and rarityOrder(Lib.fish[boosted].Rarity) >= rarityOrder("Mythical")
        if not (event or rarePool) then
            return
        end
        local key = name .. "|" .. tostring(boosted)
        if alerted[key] and os.clock() - alerted[key] < 300 then
            return
        end
        alerted[key] = os.clock()
        local rows, worth = Zones.odds(name, boosted, boost)
        local best = bestOf(rows)
        local root = myRoot()
        local dist = root and comma((part.Position - root.Position).Magnitude) or "?"
        local what = rarePool and (boosted .. " pool at " .. displayName(name)) or displayName(name)
        if Settings.EventAlert then
            notify(("%s %s! Avg ~%s C$%s · %s studs away"):format(what, atStart and "is up" or "just spawned", comma(worth or 0),
                best and (" · best " .. best.name .. " ~" .. comma(best.value) .. " C$") or "", dist), 10)
        end
        if Settings.EventAutoGo and not atStart and not Busy.reason and not activeReel() then
            task.spawn(Zones.goPart, part, Settings.EventUseBoat)
        end
    end
    task.spawn(function()
        local f
        for _ = 1, 60 do
            f = folder()
            if f or not alive() then
                break
            end
            task.wait(1)
        end
        if not (f and alive()) then
            return
        end
        bind(f.ChildAdded, function(part)
            changed()
            task.delay(0.5, check, part, false)
        end)
        bind(f.ChildRemoved, changed)
        task.wait(2)
        for _, part in f:GetChildren() do
            check(part, true)
        end
    end)
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
                        local color = Zones.isEvent(z.Name) and Color3.fromRGB(255, 160, 50)
                            or boosted and Color3.fromRGB(120, 220, 255) or Color3.fromRGB(235, 235, 235)
                        mark(z, z, color, text, {
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

--// Items: catches, junk, favourites, bait, treasure maps, crab cages, appraise, totems \\--
-- Inventory lives in DataController.InventoryReplicator ("Inventory": id ->
-- { name, sub = { Weight, Mutation, Shiny, Sparkling, Favourited, Repaired,
-- x, y, z, ... } }); a Tool's "link" value is its id. RE/Backpack/Favourite
-- (id, on), RE/Bait/Equip(name), CrabCageController:Claim(cage). NPC jobs
-- (Jack Marrow fixing a held treasure map, the appraiser) are RemoteFunctions
-- inside the NPC model, found by name. A fixed map's chest shows up in
-- world.chests and opens with events.open_treasure(id).
local Items = { log = {}, best = nil, line = "nothing on the line", caught = 0, earned = 0, junked = 0, favs = 0, cages = 0,
    mapInfo = "", baitInfo = "", appraiseInfo = "", totemInfo = "" }
do
    local Data, Mutations, BaitLib, Cages
    pcall(function()
        Data = require(ReplicatedStorage.client.legacyControllers.DataController)
    end)
    pcall(function()
        Mutations = require(ReplicatedStorage.shared.modules.fishing.mutations).Mutations
    end)
    pcall(function()
        BaitLib = require(ReplicatedStorage.shared.modules.library.bait)
    end)
    pcall(function()
        Cages = require(ReplicatedStorage.client.legacyControllers.CrabCageController)
    end)
    local Inv = type(Data) == "table" and Data.InventoryReplicator or nil
    local function inventory()
        local ok, t = pcall(function()
            return Inv:TryIndex({ "Inventory" })
        end)
        return (ok and type(t) == "table") and t or {}
    end
    local function itemOf(tool)
        if not (Data and tool) then
            return nil
        end
        local ok, item, id = pcall(Data.getItemFromLink, tool)
        if ok and type(item) == "table" then
            return item, id
        end
        return nil
    end
    local function rarityOrder(r)
        local L = Zones.lib()
        local x = L and L.rarities.Rarities and L.rarities.Rarities[r]
        return x and tonumber(x.Order) or 0
    end
    local function fishData(name)
        local L = Zones.lib()
        local f = L and type(name) == "string" and L.fish[name]
        if type(f) == "table" and not f.NonFish and tonumber(f.Price) then
            return f
        end
        return nil
    end
    -- What the merchant pays for one fish (the game's SellFish).
    function Items.value(name, sub)
        local f = fishData(name)
        if not f then
            return nil
        end
        sub = type(sub) == "table" and sub or {}
        local wp, v = f.WeightPool, f.Price
        if tonumber(sub.Weight) and type(wp) == "table" and tonumber(wp[2]) and wp[2] > 0 then
            v = math.ceil(sub.Weight / (wp[2] / 10) * f.Price)
        end
        if sub.Shiny then
            v *= 1.85
        end
        if sub.Sparkling then
            v *= 1.85
        end
        if sub.Glitched then
            v = 0
        end
        local m = sub.Mutation and type(Mutations) == "table" and Mutations[sub.Mutation]
        if type(m) == "table" and tonumber(m.PriceMultiply) then
            v *= m.PriceMultiply
        end
        return v
    end
    local function describe(name, sub)
        local parts = {}
        if sub.Shiny then
            table.insert(parts, "Shiny")
        end
        if sub.Sparkling then
            table.insert(parts, "Sparkling")
        end
        if sub.Mutation then
            table.insert(parts, tostring(sub.Mutation))
        end
        table.insert(parts, tostring(name))
        return table.concat(parts, " ") .. (tonumber(sub.Weight) and (" %.1fkg"):format(sub.Weight) or "")
    end
    function Items.mutationNames()
        local out = {}
        if type(Mutations) == "table" then
            for name, m in Mutations do
                if type(name) == "string" and type(m) == "table" then
                    table.insert(out, name)
                end
            end
        end
        table.sort(out)
        return out
    end

    -- Catch log: every new fish in your inventory.
    local known, ready = {}, false
    if Inv then
        pcall(function()
            Inv:ObserveKeys({ "Inventory" }, function(id, item)
                if not alive() then
                    return
                end
                if item == nil then
                    known[id] = nil
                    return
                end
                if known[id] then
                    return
                end
                known[id] = true
                if not ready or type(item) ~= "table" then
                    return
                end
                local sub = type(item.sub) == "table" and item.sub or {}
                local v = Items.value(item.name, sub)
                if not v then
                    return
                end
                local f = fishData(item.name)
                local entry = { name = item.name, text = describe(item.name, sub), value = v, rarity = tostring(f.Rarity or "?") }
                table.insert(Items.log, 1, entry)
                if #Items.log > 6 then
                    table.remove(Items.log)
                end
                Items.caught += 1
                Items.earned += v
                if not Items.best or v > Items.best.value then
                    Items.best = entry
                end
                if Settings.CatchAlert and (rarityOrder(entry.rarity) >= rarityOrder(Settings.CatchAlertRarity) or v >= Settings.CatchAlertValue) then
                    notify(("Caught %s (%s) ~%s C$"):format(entry.text, entry.rarity, comma(v)), 6)
                end
            end)
        end)
    end
    task.delay(3, function()
        ready = true
    end)
    function Items.logText()
        local lines = {
            ("On the line: %s"):format(Items.line),
            ("This session: %d fish, ~%s C$%s"):format(Items.caught, comma(Items.earned), Items.junked > 0 and (", %d junk skipped"):format(Items.junked) or ""),
        }
        if Items.best then
            table.insert(lines, ("Best: %s ~%s C$"):format(Items.best.text, comma(Items.best.value)))
        end
        for _, e in Items.log do
            table.insert(lines, ("· %s (%s) ~%s"):format(e.text, e.rarity, comma(e.value)))
        end
        return table.concat(lines, "\n")
    end

    -- What's on the line, and junk: reel it in instantly or let it go.
    local junkAt = setmetatable({}, { __mode = "k" })
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local r = activeReel()
        if not r then
            Items.line = "nothing"
            return
        end
        local fish = r.fish
        local name = (typeof(fish) == "Instance" and fish.Name) or (type(fish) == "table" and (fish.Name or fish.name)) or nil
        if type(name) ~= "string" then
            return
        end
        local L = Zones.lib()
        local raw = L and L.fish[name]
        local f = fishData(name)
        local avg = f and Zones.valueOf(f) or 0
        Items.line = ("%s (%s) ~%s C$"):format(name, type(raw) == "table" and tostring(raw.Rarity) or "?", comma(avg))
        local keep = type(raw) == "table" and raw.NonFish and raw.Rarity ~= "Trash"
        if Settings.JunkMode ~= "Off" and not keep and not junkAt[r] and r.active and r.ready and avg < Settings.JunkBelow then
            junkAt[r] = os.clock()
        end
        local at = junkAt[r]
        if at and not r.__dkEnded and os.clock() - at >= Settings.JunkDelay then
            r.__dkEnded = true
            Items.junked += 1
            local catch = Settings.JunkMode == "Reel instantly"
            task.spawn(function()
                pcall(r.EndMinigame, r, catch)
            end)
        end
    end)

    -- Auto favourite: keeps the good ones out of Sell All.
    local favDone = {}
    loop(3, function()
        if not (Settings.AutoFav and Inv) then
            return
        end
        local r = net("RE/Backpack/Favourite")
        if not r then
            return
        end
        local min = Settings.FavRarity ~= "Off" and rarityOrder(Settings.FavRarity) or math.huge
        local sent = 0
        for id, item in table.clone(inventory()) do
            if not favDone[id] and type(item) == "table" then
                local sub = type(item.sub) == "table" and item.sub or {}
                local f = fishData(item.name)
                if sub.Favourited then
                    favDone[id] = true
                elseif f then
                    local want = rarityOrder(f.Rarity) >= min
                        or (Settings.FavMutated and (sub.Mutation ~= nil or sub.Shiny or sub.Sparkling))
                        or (Settings.FavValue > 0 and (Items.value(item.name, sub) or 0) >= Settings.FavValue)
                    if want then
                        r:FireServer(id, true)
                        favDone[id] = true
                        Items.favs += 1
                        sent += 1
                        if sent >= 10 then
                            break
                        end
                        task.wait(0.15)
                    end
                end
            end
        end
    end)

    -- Bait: equip the best one you have.
    local function statsFolder()
        local ok, s = pcall(function()
            return Workspace.PlayerStats[LocalPlayer.Name].T[LocalPlayer.Name].Stats
        end)
        return ok and s or nil
    end
    function Items.baits()
        local s = statsFolder()
        local b = s and s:FindFirstChild("bait")
        local owned = {}
        if b then
            for _, c in b:GetChildren() do
                local n = c.Name:match("^bait_(.+)$")
                if n and tonumber(c.Value) and c.Value > 0 then
                    owned[n] = c.Value
                end
            end
        end
        return owned, b and b.Value or nil
    end
    loop(4, function()
        if not Settings.AutoBait then
            return
        end
        local owned, equipped = Items.baits()
        local best, bestV
        for name in owned do
            local d = type(BaitLib) == "table" and BaitLib[name]
            local v = type(d) == "table" and tonumber(d[Settings.BaitStat]) or 0
            if not bestV or v > bestV then
                best, bestV = name, v
            end
        end
        if not best then
            Items.baitInfo = "you have no bait"
        elseif best ~= equipped then
            local r = net("RE/Bait/Equip")
            if r then
                r:FireServer(best)
                Items.baitInfo = ("equipped %s (%s %s)"):format(best, Settings.BaitStat, tostring(bestV))
            end
        else
            Items.baitInfo = ("using %s (%d left)"):format(best, owned[best] or 0)
        end
    end)

    -- NPCs
    local function findNpc(name, kind)
        local w = Workspace:FindFirstChild("world")
        local npcs = w and w:FindFirstChild("npcs")
        if not npcs then
            return nil
        end
        for _, d in npcs:GetDescendants() do
            if d:IsA("Model") and ((name and d.Name == name) or (kind and d:GetAttribute("NpcType") == kind)) then
                return d
            end
        end
        return nil
    end
    local function remoteIn(model, pattern)
        for _, d in model:GetDescendants() do
            if (d:IsA("RemoteFunction") or d:IsA("RemoteEvent")) and d.Name:lower():find(pattern, 1, true) then
                return d
            end
        end
        return nil
    end
    local function call(r, ...)
        if r:IsA("RemoteFunction") then
            return pcall(r.InvokeServer, r, ...)
        end
        return pcall(r.FireServer, r, ...)
    end
    -- Walk up to an NPC, going to its island first if it isn't loaded.
    local function reach(name, kind, island)
        local npc = findNpc(name, kind)
        if not npc then
            local cf = Tp.camera(island)
            if cf then
                Tp.land(cf)
                for _ = 1, 12 do
                    task.wait(0.3)
                    npc = findNpc(name, kind)
                    if npc then
                        break
                    end
                end
            end
        end
        if npc then
            Move.near(npc, 4)
            task.wait(0.4)
        end
        return npc
    end
    local function toolById(id)
        for _, holder in { myChar(), LocalPlayer:FindFirstChildOfClass("Backpack") } do
            if holder then
                for _, t in holder:GetChildren() do
                    local link = t:IsA("Tool") and t:FindFirstChild("link")
                    if link and link.Value == id then
                        return t
                    end
                end
            end
        end
        return nil
    end

    -- Treasure maps
    function Items.maps()
        local broken, fixed = {}, {}
        for _, holder in { LocalPlayer:FindFirstChildOfClass("Backpack"), myChar() } do
            if holder then
                for _, t in holder:GetChildren() do
                    if t:IsA("Tool") and t.Name == "Treasure Map" then
                        local item = itemOf(t)
                        local sub = item and type(item.sub) == "table" and item.sub or nil
                        table.insert((sub and sub.Repaired) and fixed or broken, { tool = t, sub = sub })
                    end
                end
            end
        end
        return broken, fixed
    end
    function Items.mapText()
        local broken, fixed = Items.maps()
        local lines = { ("Maps to fix: %d · fixed: %d"):format(#broken, #fixed) }
        for i = 1, math.min(3, #fixed) do
            local s = fixed[i].sub
            local where = "?"
            pcall(function()
                where = require(ReplicatedStorage.shared.utils.FischUtils).GetZoneName(Vector3.new(s.x, s.y, s.z))
            end)
            table.insert(lines, ("· chest at %s"):format(tostring(where)))
        end
        if Items.mapInfo ~= "" then
            table.insert(lines, Items.mapInfo)
        end
        return table.concat(lines, "\n")
    end
    function Items.fixMaps()
        local broken = Items.maps()
        if #broken == 0 then
            Items.mapInfo = "no maps to fix"
            return
        end
        Items.mapInfo = ""
        Move.trip("fixing treasure maps", function()
            local npc = reach("Jack Marrow", nil, "Moosewood")
            if not npc then
                Items.mapInfo = "couldn't find Jack Marrow (Moosewood)"
                return
            end
            local r = remoteIn(npc, "repair")
            if not r then
                Items.mapInfo = "Jack Marrow's repair isn't loaded yet"
                return
            end
            local hum = myHum()
            for _, m in broken do
                if m.tool.Parent and hum then
                    hum:EquipTool(m.tool)
                    task.wait(0.35)
                    call(r)
                    task.wait(0.6)
                end
            end
            if hum then
                pcall(hum.UnequipTools, hum)
            end
        end)
        local left = Items.maps()
        local n = #broken - #left
        if Items.mapInfo == "" or n > 0 then
            Items.mapInfo = ("fixed %d, %d left%s"):format(n, #left, (n == 0 and #left > 0) and " (enough C$?)" or "")
        end
    end
    loop(20, function()
        if Settings.AutoMaps and not Busy.reason and not activeReel() and not shakeUi() then
            local broken = Items.maps()
            if #broken > 0 then
                Items.fixMaps()
            end
        end
    end)

    -- Crab cages: claim the full ones (walking over if the server wants you close).
    local tries = {}
    loop(5, function()
        if not (Settings.AutoCages and type(Cages) == "table" and type(Cages.ActiveCages) == "table") then
            return
        end
        for _, c in Cages.ActiveCages do
            if type(c) == "table" and type(c.data) == "table" and c.data.s == 2 and not c.pending then
                tries[c] = (tries[c] or 0) + 1
                if tries[c] > 1 and c.model and c.model.Parent and not Busy.reason and not activeReel() then
                    Move.trip("claiming a crab cage", function()
                        Move.near(c.model, 3)
                        task.wait(0.4)
                        pcall(Cages.Claim, Cages, c)
                        task.wait(0.4)
                    end)
                else
                    pcall(Cages.Claim, Cages, c)
                end
                Items.cages += 1
                task.wait(0.3)
            end
        end
    end)

    -- Appraise the held fish until it has what you want.
    local function wanted(sub)
        local w = Settings.AppraiseFor
        if w == "Any mutation" then
            return sub.Mutation ~= nil
        elseif w == "Shiny" then
            return sub.Shiny == true
        elseif w == "Sparkling" then
            return sub.Sparkling == true
        end
        return sub.Mutation == w
    end
    function Items.heldFish()
        local c = myChar()
        local t = c and c:FindFirstChildOfClass("Tool")
        local item, id = itemOf(t)
        if item and fishData(item.name) then
            return t, item, id
        end
        return nil
    end
    function Items.stopAppraise()
        Items.appraising = false
    end
    function Items.appraise()
        if Items.appraising then
            return
        end
        local tool, item, id = Items.heldFish()
        if not tool then
            notify("Hold the fish you want appraised")
            return
        end
        if wanted(item.sub or {}) then
            notify("That fish already has it")
            return
        end
        Items.appraising = true
        local function oneTry(r)
            local t = toolById(id) or tool
            local hum = myHum()
            if hum and t.Parent ~= myChar() then
                hum:EquipTool(t)
                task.wait(0.3)
            end
            call(r)
            task.wait(0.8)
            local now = inventory()[id]
            return now and type(now.sub) == "table" and now.sub or {}
        end
        local function run(r)
            for i = 1, Settings.AppraiseTries do
                if not (Items.appraising and alive()) then
                    break
                end
                local sub = oneTry(r)
                Items.appraiseInfo = ("try %d: %s"):format(i, describe(item.name, sub))
                if wanted(sub) then
                    notify("Appraised: " .. describe(item.name, sub), 6)
                    break
                end
            end
        end
        if Settings.AppraiseAnywhere then
            local r = net("RF/AppraiseAnywhere/Fire")
            if r then
                run(r)
            else
                Items.appraiseInfo = "appraise anywhere remote not found"
            end
        else
            Move.trip("appraising", function()
                local npc = reach(nil, "Appraiser", "Moosewood")
                local r = npc and remoteIn(npc, "apprais")
                if not r then
                    Items.appraiseInfo = "couldn't find the appraiser"
                    return
                end
                run(r)
            end)
        end
        Items.appraising = false
    end

    -- Totems
    function Items.totems()
        local seen, out = {}, {}
        for _, holder in { LocalPlayer:FindFirstChildOfClass("Backpack"), myChar() } do
            if holder then
                for _, t in holder:GetChildren() do
                    if t:IsA("Tool") and t.Name:find("Totem", 1, true) and not seen[t.Name] then
                        seen[t.Name] = true
                        table.insert(out, t.Name)
                    end
                end
            end
        end
        table.sort(out)
        return out
    end
    function Items.useTotem(name)
        name = name or Settings.TotemPick
        local hum = myHum()
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        local t = name and ((bp and bp:FindFirstChild(name)) or (myChar() and myChar():FindFirstChild(name)))
        if not (t and hum) then
            Items.totemInfo = "you don't have " .. tostring(name or "that totem")
            return false
        end
        hum:EquipTool(t)
        task.wait(0.4)
        pcall(t.Activate, t)
        task.wait(1.5)
        pcall(hum.UnequipTools, hum)
        Items.totemInfo = "used " .. name
        Items.lastTotem = os.clock()
        return true
    end
    loop(10, function()
        if not Settings.TotemAuto or Busy.reason or activeReel() then
            return
        end
        if Items.lastTotem and os.clock() - Items.lastTotem < Settings.TotemEvery * 60 then
            return
        end
        local w = ReplicatedStorage:FindFirstChild("world")
        local cycle = w and w:FindFirstChild("cycle") and w.cycle.Value
        if Settings.TotemWhen ~= "Any time" and cycle ~= Settings.TotemWhen then
            return
        end
        Items.useTotem()
    end)
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
    loop(120, function()
        if Settings.AutoRodRewards then
            local r = net("RE/RodJournal/ClaimAllRodRewards")
            if r then
                r:FireServer()
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

    -- Servers
    local TeleportService = game:GetService("TeleportService")
    function Claims.hop()
        notify("Finding another server...")
        local r = net("RF/ServerBrowser/TeleportToRandom")
        local ok = r and pcall(r.InvokeServer, r)
        task.wait(8)
        if alive() then
            pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
        end
        return ok
    end
    function Claims.rejoin()
        local ok = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, game.JobId, LocalPlayer)
        if not ok then
            pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
        end
    end
    local GuiService = game:GetService("GuiService")
    bind(GuiService.ErrorMessageChanged, function(msg)
        if Settings.AutoRejoin and alive() and type(msg) == "string" and msg ~= "" then
            task.delay(3, Claims.rejoin)
        end
    end)
    function Claims.fpsBoost()
        local Lighting = game:GetService("Lighting")
        pcall(function()
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 1e6
        end)
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
        local terrain = Workspace:FindFirstChildOfClass("Terrain")
        if terrain then
            pcall(function()
                terrain.WaterWaveSize = 0
                terrain.WaterWaveSpeed = 0
                terrain.WaterReflectance = 0
                terrain.Decoration = false
            end)
        end
        local n = 0
        for _, d in Workspace:GetDescendants() do
            if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles") then
                d.Enabled = false
                n += 1
            elseif d:IsA("BasePart") and d.CastShadow then
                d.CastShadow = false
            end
        end
        for _, e in Lighting:GetChildren() do
            if e:IsA("PostEffect") then
                e.Enabled = false
            end
        end
        notify(("FPS boost on (%d effects off). Rejoin to undo"):format(n))
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
    slider(C, "StuckReset", "Recast after no bite for", 15, 600, 0, " s")
    status(C, function()
        return ("Now: %s\nCasts: %d"):format(Fish.info, Fish.casts)
    end)

    local S = Tab:AddLeftGroupbox("Auto shake", "hand")
    toggle(S, "AutoShake", "Auto shake", "Shakes while the shake button is up")
    dropdown(S, "ShakeMethod", "Method", { "Auto", "Game handler", "Remote", "Tap", "Select + Enter", "Mouse click", "VirtualUser click" },
        "Game handler: runs the shake button's own connection (the game's shake code) every frame, so it shakes as fast as the game allows with no input at all. Remote: fires the shake remote on the timer below. Tap / Select + Enter / Mouse click / VirtualUser click press the button. Auto: Game handler, or a press on the old shake")
    slider(S, "ShakeDelay", "Remote / press gap", 0, 1, 2, " s", "Only for Remote and the press methods. The game itself sends one shake every 0.25s (less with some rods); going faster may be thrown away")
    status(S, function()
        return ("Now: %s\nGame's shake rate: every %.2fs"):format(Fish.shakeInfo or "off", Fish.shake.interval())
    end)

    local R = Tab:AddRightGroupbox("Auto reel", "refresh-cw")
    toggle(R, "AutoReel", "Auto reel")
    dropdown(R, "ReelMode", "How", { "Lock bar on fish", "Legit", "Instant" },
        "Lock bar on fish: your bar sits on the fish the whole time (perfect catches). Legit: holds and lets go like a player. Instant: finishes the reel right away (the server may check how long it took)")
    slider(R, "InstantDelay", "Instant: wait first", 0, 10, 1, " s", "How long to wait before finishing. A couple of seconds looks more normal")
    toggle(R, "FastReel", "Faster minigame", "The game's own minigame speed setting, on your side")
    slider(R, "ReelSpeed", "Minigame speed", 1, 10, 1, "x")
    status(R, function()
        return ("Reel: %s\nInstant reels: %d\nCaught: %d  Missed: %d"):format(
            Reel and (activeReel() and "reeling" or "waiting") or "ReelController not found", Fish.reels, Fish.caught, Fish.missed)
    end)

    local J = Tab:AddRightGroupbox("Junk fish", "trash-2")
    dropdown(J, "JunkMode", "Junk fish", { "Off", "Reel instantly", "Let it go" },
        "A bite worth less than the amount below (trash included) is reeled in at once, or let go so you can cast again")
    slider(J, "JunkBelow", "Junk if worth under", 0, 10000, 0, " C$")
    slider(J, "JunkDelay", "Wait first", 0, 5, 1, " s")
    local K = Tab:AddRightGroupbox("Catches", "list")
    toggle(K, "CatchAlert", "Tell me about big catches")
    dropdown(K, "CatchAlertRarity", "Rarity at least", { "Rare", "Legendary", "Mythical", "Exotic", "Secret" })
    slider(K, "CatchAlertValue", "Or worth at least", 1000, 5000000, 0, " C$")
    status(K, Items.logText)
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
    Z:AddButton({ Text = "Teleport with boat", Func = function()
        task.spawn(Zones.go, Settings.ZonePick, true)
    end, Tooltip = "Gets in your boat (spawns the one picked in the Boat tab if none is out) and moves it, with you, to the zone" })
    Z:AddButton({ Text = "Refresh zones", Func = function()
        task.spawn(refresh)
    end, Tooltip = "The list also updates by itself when zones and pools come and go" })
    Zones.onChange = function(labels)
        pcall(function()
            pick:SetValues(labels)
        end)
    end
    task.spawn(refresh)
    local V = Tab:AddLeftGroupbox("Events", "zap")
    toggle(V, "EventAlert", "Tell me when one spawns", "Megalodon, sharks, Kraken, orcas, whales, Scylla, hunts, Lovestorm, Golden Tide and pools of a mythical or rarer fish, the moment the zone shows up")
    toggle(V, "EventAutoGo", "Go there by itself", "Teleports you to a new event as soon as it spawns (not while you're reeling)")
    toggle(V, "EventUseBoat", "Go by boat", "Auto go takes your boat")
    V:AddButton({ Text = "Go to best event", Func = function()
        task.spawn(Zones.goBestEvent, false)
    end })
    V:AddButton({ Text = "Go to best event by boat", Func = function()
        task.spawn(Zones.goBestEvent, true)
    end })
    status(V, Zones.eventsText)
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
    slider(S, "SellWorth", "Sell once worth", 500, 10000000, 0, " C$")
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
    T:AddButton({ Text = "Go with boat", Func = function()
        task.spawn(function()
            local s = Settings.TpSpot and Tp.spots[Settings.TpSpot]
            if not s then
                notify("Pick a spot first")
                return
            end
            local pos = s.cf.Position
            pcall(LocalPlayer.RequestStreamAroundAsync, LocalPlayer, pos, 6)
            local water
            for _ = 1, 3 do
                water = Boat.waterNear(pos, 700)
                if water then
                    break
                end
                task.wait(0.6)
            end
            Boat.go(water, Settings.TpSpot)
        end)
    end, Tooltip = "Takes your boat to the water nearest the spot (spawns the boat picked in the Boat tab if none is out)" })
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
    local Tab = Window:AddTab("Player", "user", "Movement, water, air")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Walk speed")
    slider(M, "WalkSpeed", "Speed", 16, 500, 0)
    toggle(M, "JumpOn", "Jump power")
    slider(M, "JumpPower", "Power", 50, 1000, 0)
    toggle(M, "InfJump", "Infinite jump", "Jump again in the air")
    toggle(M, "Fly", "Fly", "Moves where your camera looks. Space goes up, Left Ctrl goes down; on a phone look up or down while you move")
    slider(M, "FlySpeed", "Fly speed", 10, 1000, 0)
    toggle(M, "Noclip", "Noclip", "Walk through walls")
    local W = Tab:AddLeftGroupbox("Water and air", "droplet")
    toggle(W, "WaterWalk", "Walk on water", "Stand and cast on any water. Dive a couple of studs down to go under")
    toggle(W, "AntiDrown", "Anti drown", "When oxygen (or pressure, heat, cold) gets low, goes back to the last spot where nothing was running out, waits until it's full and comes back")
    slider(W, "DrownAt", "Go up at", 5, 95, 0, "%")
    toggle(W, "DrownReturn", "Come back after")
    status(W, function()
        return ("Now: %s\nLevels: %s\nSaved you: %d times"):format(Air.info, Air.levels(), Air.saves)
    end)
end

do
    local Tab = Window:AddTab("Boat", "ship", "Boat mods, spawn, bring, teleport")
    local B = Tab:AddLeftGroupbox("Boat mods", "ship")
    toggle(B, "BoatSpeedOn", "Faster boat", "More top speed and speed-up for your own boat")
    slider(B, "BoatSpeed", "Speed", 1, 50, 1, "x")
    toggle(B, "BoatTurnOn", "Faster turning")
    slider(B, "BoatTurn", "Turning", 1, 20, 1, "x")
    toggle(B, "BoatInstant", "Instant speed-up and stop", "No waiting to get up to speed or to stop")
    toggle(B, "BoatSteady", "Steady boat", "No bobbing or tilting")
    toggle(B, "BoatKeepSpeed", "Keep speed on hits", "Bumping into things doesn't stop you")
    toggle(B, "BoatNoclip", "Boat noclip", "Drive through rocks, docks and islands (the boat stays on the water)")
    toggle(B, "BoatFly", "Flying boat", "Any boat flies. R goes up, F goes down; on a phone look up or down while you drive")
    slider(B, "BoatFlySpeed", "Up / down speed", 10, 1000, 0)
    local O = Tab:AddRightGroupbox("Boost", "zap")
    toggle(O, "BoatAnyBoost", "Boost on any boat", "Gives any boat the jetski boost (Q, or the boost button)")
    slider(O, "BoatBoostPower", "Boost adds", 0.25, 10, 2, "x top speed")
    toggle(O, "BoatInfBoost", "Infinite boost", "The boost never runs out")
    toggle(O, "BoatAlwaysBoost", "Always boosting", "Boosting the whole time you drive")
    local Y = Tab:AddRightGroupbox("Your boats", "anchor")
    local pick = Y:AddDropdown("BoatPick", {
        Text = "Boat", Values = {}, Searchable = true,
        Tooltip = "Your boats. Used when a boat has to be spawned",
        Callback = function(v)
            Settings.BoatPick = v
        end,
    })
    local function refresh()
        local list = Boat.list()
        pcall(function()
            pick:SetValues(list)
        end)
        if not Settings.BoatPick and list[1] then
            pcall(function()
                pick:SetValue(list[1])
            end)
            Settings.BoatPick = Settings.BoatPick or list[1]
        end
    end
    Y:AddButton({ Text = "Spawn boat", Func = function()
        task.spawn(function()
            if Boat.spawn() then
                local b = Boat.current()
                if b then
                    Boat.sit(b)
                end
            end
        end)
    end, Tooltip = "Spawns the picked boat (like the quick menu) and gets you in" })
    Y:AddButton({ Text = "Bring my boat", Func = function()
        task.spawn(Boat.bring)
    end, Tooltip = "Gets in your boat and brings it to the water next to you" })
    Y:AddButton({ Text = "Get in my boat", Func = function()
        task.spawn(function()
            local b = Boat.current()
            if not (b and Boat.sit(b)) then
                notify(b and "Couldn't get in (someone in the seat?)" or "No boat of yours out")
            end
        end)
    end })
    Y:AddButton({ Text = "Refresh boats", Func = function()
        task.spawn(refresh)
    end })
    task.spawn(refresh)
    status(Y, function()
        return Boat.info
    end)
end

do
    local Tab = Window:AddTab("Items", "package", "Treasure maps, favourites, bait, crab cages, appraise, totems")
    local T = Tab:AddLeftGroupbox("Treasure maps", "map")
    toggle(T, "AutoMaps", "Fix treasure maps", "Takes your unfixed maps to Jack Marrow (Moosewood), gets each one fixed and comes back")
    toggle(T, "AutoChests", "Open treasure chests", "Goes to each chest from a fixed map, opens it, comes back")
    T:AddButton({ Text = "Fix maps now", Func = function()
        task.spawn(Items.fixMaps)
    end })
    status(T, Items.mapText)
    local F = Tab:AddLeftGroupbox("Favourites", "star")
    toggle(F, "AutoFav", "Auto favourite", "Favourites fish that match below, so Sell All keeps them")
    dropdown(F, "FavRarity", "Rarity at least", { "Off", "Rare", "Legendary", "Mythical", "Exotic", "Secret" })
    toggle(F, "FavMutated", "Any mutation, shiny or sparkling")
    slider(F, "FavValue", "Or worth at least (0 = off)", 0, 1000000, 0, " C$")
    status(F, function()
        return ("Favourited: %d"):format(Items.favs)
    end)
    local C = Tab:AddLeftGroupbox("Crab cages", "box")
    toggle(C, "AutoCages", "Claim full crab cages", "Claims your cages when they're ready (walks over if it has to)")
    status(C, function()
        return ("Claimed: %d"):format(Items.cages)
    end)
    local B = Tab:AddRightGroupbox("Bait", "anchor")
    toggle(B, "AutoBait", "Use your best bait", "Equips the bait you own with the most of the stat below, and switches when it runs out")
    dropdown(B, "BaitStat", "Best by", { "Luck", "PreferredLuck", "Lure", "Resilience", "Control", "ProgressSpeed" },
        "Luck: universal luck. PreferredLuck: extra luck on fish that like it. Lure: faster bites")
    status(B, function()
        local owned, equipped = Items.baits()
        local n = 0
        for _ in owned do
            n += 1
        end
        return ("Now: %s\nEquipped: %s · %d kinds owned"):format(Items.baitInfo ~= "" and Items.baitInfo or "off", tostring(equipped or "none"), n)
    end)
    local A = Tab:AddRightGroupbox("Appraise", "search")
    local wants = { "Any mutation", "Shiny", "Sparkling" }
    for _, m in Items.mutationNames() do
        table.insert(wants, m)
    end
    dropdown(A, "AppraiseFor", "Until it has", wants, "Hold the fish, then start. It goes to the appraiser and keeps appraising until the fish has this", true)
    slider(A, "AppraiseTries", "At most", 1, 200, 0, " tries")
    toggle(A, "AppraiseAnywhere", "Appraise anywhere (gamepass)", "Uses the appraise-anywhere gamepass instead of going to the appraiser")
    A:AddButton({ Text = "Start appraising", Func = function()
        task.spawn(Items.appraise)
    end })
    A:AddButton({ Text = "Stop", Func = Items.stopAppraise })
    status(A, function()
        return (Items.appraising and "Appraising: " or "Last: ") .. (Items.appraiseInfo ~= "" and Items.appraiseInfo or "-")
    end)
    local O = Tab:AddRightGroupbox("Totems", "sun")
    local pick = O:AddDropdown("TotemPick", {
        Text = "Totem", Values = Items.totems(),
        Callback = function(v)
            Settings.TotemPick = v
        end,
    })
    O:AddButton({ Text = "Use totem", Func = function()
        task.spawn(Items.useTotem)
    end })
    O:AddButton({ Text = "Refresh totems", Func = function()
        pcall(function()
            pick:SetValues(Items.totems())
        end)
    end })
    toggle(O, "TotemAuto", "Use it by itself", "Uses the picked totem at the time below, then waits before using another")
    dropdown(O, "TotemWhen", "When", { "Night", "Day", "Any time" })
    slider(O, "TotemEvery", "Wait between", 1, 60, 0, " min")
    status(O, function()
        return Items.totemInfo ~= "" and Items.totemInfo or "-"
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
    toggle(M, "AutoRodRewards", "Claim rod journal rewards")
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
    local Sv = Tab:AddLeftGroupbox("Server", "server")
    Sv:AddButton({ Text = "Server hop", Func = function()
        task.spawn(Claims.hop)
    end, Tooltip = "Joins another server (handy for finding events)" })
    Sv:AddButton({ Text = "Rejoin", Func = function()
        task.spawn(Claims.rejoin)
    end })
    toggle(Sv, "AutoRejoin", "Rejoin if kicked", "Rejoins when you get disconnected or kicked")
    Sv:AddButton({ Text = "FPS boost", Func = function()
        task.spawn(Claims.fpsBoost)
    end, Tooltip = "Turns off shadows, particles, water waves and post effects. Rejoin to undo" })
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

--// Break In 2 (Story) -- the story level (place 13864667823, game 4807308814).
--
-- Built against a script dump of the live game (version 1732). This version
-- does every job the way a player does it, so the server gets exactly what it
-- would from real play. The first version tried shortcuts the server checks
-- and undoes:
--  * levels: the server tracks XP itself; a report it didn't see earned is
--    answered with PlayerGainedXp:FireClient, which drops the stat back to 1.
--    So training runs the real treadmill, bench press and book: the game's
--    own machine click, its own input handler, its own XP ticks.
--  * fighting: damage is worked out by the game's swing (strength, weapon
--    level, combo, targets per swing, its 8.5 x 7.5 x 13 hitbox). So the
--    farm stands you in front of a bad guy and presses the game's own hit
--    button (BindableEvents.MobileHit) with your weapon really equipped.
--  * food heals only while the food is in your hand, so it's equipped and
--    used through the game's own click handler.
--  * pickups, crates, vending, trash cans, bikes and Uncle Pete are clicked
--    from within their reach, through the click handlers the game connected.
-- What the client really decides on its own (blocked by god mode): the damage
-- it reports for you (Energy with a negative amount), the server's "were you
-- in range" question (RemoteFunctions.CheckDamage), the chasing boss's
-- "caught you", the road mission's hit, and the death screen's lobby teleport.
--
-- The server scripts aren't in the dump, so none of this can be checked
-- against them; it follows the client code exactly. Nothing here touches
-- TooFarAway or TestRespawn, two remotes the client never uses.

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

local function waitFor(seconds, check)
    local started = os.clock()
    while os.clock() - started < seconds and not Unloaded do
        if check() then return true end
        task.wait(0.1)
    end
    return check()
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
    Farm = false,         -- go to bad guys and swing
    Swing = false,        -- swing at bad guys that come close
    FarmBosses = true,
    -- protection
    God = false,
    NoCatch = false,
    NoLobby = false,
    -- training
    Treadmill = false,
    Bench = false,
    Read = false,
    -- items
    AutoEat = false,
    EatBelow = 100,
    AutoLoot = false,
    AutoMoney = false,
    OutsideFood = false,
    VendSwap = false,
    VendItem = "Crowbar3",
    PickupSwap = false,
    PickupItem = "Key",
    -- story
    AutoPete = false,
    AutoBike = false,
    AutoBatteries = false,
    AutoMary = false,
    AutoVote = false,
    VoteFor = "Ending1",
    -- movement
    Speed = false,
    SpeedValue = 24,
    Jump = false,
    JumpValue = 60,
    Noclip = false,
    Fly = false,
    FlySpeed = 50,
    InfJump = false,
    -- esp
    EspEnemies = false,
    EspBosses = false,
    EspItems = false,
    EspMoney = false,
    EspPlayers = false,
    -- misc
    AntiAfk = true,
}

local Status = { Farm = "off", Train = "off", Loot = "", Story = "" }
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

local function speedLevel()
    local ss = mod("StrengthService")
    return ss and tonumber(ss.level) or 1
end

local function strengthLevel()
    local ss = mod("StrengthService")
    return ss and tonumber(ss.level2) or 1
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

local function distance(pos)
    local _, root = myChar()
    if not root or not pos then return math.huge end
    return (root.Position - pos).Magnitude
end

local function teleport(pos, lookAt)
    local _, root = myChar()
    if not root or not pos then return false end
    local at = pos + Vector3.new(0, 3, 0)
    root.CFrame = lookAt and CFrame.lookAt(at, Vector3.new(lookAt.X, at.Y, lookAt.Z)) or CFrame.new(at)
    root.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- steps within `range` of a thing (stopping a few studs short so you don't
-- land inside it)
local function goNear(obj, range)
    local pos = position(obj)
    if not pos then return false end
    if distance(pos) <= range then return true end
    local _, root = myChar()
    if not root then return false end
    local away = root.Position - pos
    away = Vector3.new(away.X, 0, away.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
    teleport(pos + away * math.min(range * 0.5, 4), pos)
    task.wait(0.2)
    return distance(pos) <= range + 3
end

-- runs the handlers the game connected to a ClickDetector (for the ones the
-- game's client makes, this is the only way in), and also clicks it for real
-- (for the server's own). Both need you within its reach.
local function click(detector)
    if typeof(detector) ~= "Instance" or not detector:IsA("ClickDetector") then return false end
    local ran = false
    if typeof(getconnections) == "function" then
        local ok, list = pcall(getconnections, detector.MouseClick)
        for _, connection in ipairs(ok and type(list) == "table" and list or {}) do
            local fn = connection.Function
            if type(fn) == "function" then
                task.spawn(pcall, fn, LocalPlayer)
                ran = true
            elseif pcall(function() connection:Fire(LocalPlayer) end) then
                ran = true
            end
        end
    end
    if typeof(fireclickdetector) == "function" then
        if pcall(fireclickdetector, detector) then ran = true end
    end
    return ran
end

local function detectorOf(obj)
    if typeof(obj) ~= "Instance" then return nil end
    if obj:IsA("ClickDetector") then return obj end
    return obj:FindFirstChildOfClass("ClickDetector") or obj:FindFirstChildWhichIsA("ClickDetector", true)
end

-- goes within the detector's reach, clicks, and comes back
local function reachAndClick(obj, stayThere)
    local detector = detectorOf(obj)
    if not detector then return false end
    local range = math.max(math.min(detector.MaxActivationDistance, 20), 6)
    local _, root = myChar()
    if not root then return false end
    local back = root.CFrame
    local target = detector.Parent
    goNear(target, range - 2)
    local ok = click(detector)
    if not stayThere then
        task.wait(0.35)
        local _, r = myChar()
        if r and (r.Position - back.Position).Magnitude > 3 then r.CFrame = back end
    end
    return ok
end

-- fires a part's touch, the way walking into it does
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
    task.wait(0.2)
    root.CFrame = back
    return true
end

-- Calls the game's own input handler for a click (the one in `scriptName`)
-- with a click that wasn't on any GUI. Falls back to a real mouse click.
local VirtualInputManager = nil
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local function fakeClick(state)
    return {
        UserInputType = Enum.UserInputType.MouseButton1,
        UserInputState = state,
        KeyCode = Enum.KeyCode.Unknown,
        Position = Vector3.zero,
        Delta = Vector3.zero,
    }
end

local function gameClick(signal, scriptName, state)
    local ran = false
    if typeof(getconnections) == "function" then
        local ok, list = pcall(getconnections, signal)
        for _, connection in ipairs(ok and type(list) == "table" and list or {}) do
            local fn = connection.Function
            if type(fn) == "function" then
                local okSource, source = pcall(function() return debug.info(fn, "s") end)
                if okSource and type(source) == "string" and source:find(scriptName, 1, true) then
                    task.spawn(pcall, fn, fakeClick(state), false)
                    ran = true
                end
            end
        end
    end
    if not ran and VirtualInputManager then
        local size = Camera.ViewportSize
        local x, y = size.X * 0.5, size.Y * 0.3
        local down = state == Enum.UserInputState.Begin
        ran = pcall(function() VirtualInputManager:SendMouseButtonEvent(x, y, 0, down, game, 0) end)
        if ran and down then
            task.delay(0.03, function() pcall(function() VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0) end) end)
        end
    end
    return ran
end

local function fireGui(button)
    if typeof(button) ~= "Instance" then return false end
    local ran = false
    if typeof(getconnections) == "function" then
        for _, signal in ipairs({ button.MouseButton1Down, button.MouseButton1Click, button.Activated }) do
            local ok, list = pcall(getconnections, signal)
            for _, connection in ipairs(ok and type(list) == "table" and list or {}) do
                if type(connection.Function) == "function" then
                    task.spawn(pcall, connection.Function)
                    ran = true
                end
            end
        end
    end
    if not ran and typeof(firesignal) == "function" then
        ran = pcall(firesignal, button.MouseButton1Down)
    end
    return ran
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

-- equips the way the game's hotbar does: the humanoid picks it up and the
-- server is told. Waits until it's really in your hand.
local function equip(tool)
    if not tool then return false end
    local char, _, hum = myChar()
    if not char then return false end
    if tool.Parent == char then return true end
    pcall(hum.EquipTool, hum, tool)
    fire("BackpackEvent", "Equip", tool)
    return waitFor(1.5, function() return tool.Parent == LocalPlayer.Character end)
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

--// the request filter ------------------------------------------------------
-- One hook on the game's outgoing requests (never ours):
--  * god mode drops its reports of damage to you (Energy with a negative
--    amount) and the road mission's hit (RoadMissionEvent 9);
--  * no catch drops the chasing boss's "caught you";
--  * no lobby drops the death screen's teleport to the lobby;
--  * the item swaps change which item the game claims from a vending machine
--    or a drawer pickup it is really making.

local HookInstalled = false

local function installHook()
    if HookInstalled then return true end
    if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then return false end
    local wrap = typeof(newcclosure) == "function" and newcclosure or function(f) return f end
    local isOurs = typeof(checkcaller) == "function" and checkcaller or function() return false end
    local energy, catch, road = remote("Energy"), remote("LarryBossEvents"), remote("RoadMissionEvent")
    local vending, giveTool = remote("Vending"), remote("GiveTool")
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if not Unloaded and not isOurs() then
            local method = getnamecallmethod()
            if method == "FireServer" then
                local first = ...
                if S.God and self == energy and type(first) == "number" and first < 0 then return nil end
                if S.God and self == road and first == 9 then return nil end
                if S.NoCatch and self == catch and first == "CaughtPlayer" then return nil end
                if S.VendSwap and self == vending and first == 3 then
                    local args = table.pack(...)
                    args[2] = S.VendItem
                    return old(self, table.unpack(args, 1, args.n))
                end
                if S.PickupSwap and self == giveTool and (first == "Apple" or first == "Cookie") then
                    return old(self, S.PickupItem, S.PickupItem == "Key" or nil)
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

-- the game's own answer to CheckDamage, kept to put back
local function gameCheckDamage(pos)
    local _, root = myChar()
    if not root or typeof(pos) ~= "Vector3" then return false end
    return (pos - root.Position).Magnitude < 15
end

local function setCheckDamage()
    local check = RemoteFunctions and RemoteFunctions:FindFirstChild("CheckDamage")
    if not check then return end
    pcall(function()
        check.OnClientInvoke = (S.God and not Unloaded) and function() return false end or gameCheckDamage
    end)
end

--// fighting ----------------------------------------------------------------

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

-- bosses that take a weapon hit only in a window: Bradley (AgentBoss) once
-- he's dizzy (the game gives him a "hittable" tag), the pizza boss while idle
local function bossTargets()
    local list = {}
    local agent = Workspace:FindFirstChild("AgentBoss")
    if agent and agent:FindFirstChild("hittable") and agent.PrimaryPart then list[#list + 1] = agent end
    local pizza = path(Workspace, "PizzaBossAlec/BadGuyPizza")
    local idle = pizza and pizza:FindFirstChild("Idle")
    if pizza and idle and idle.Value == true and pizza.PrimaryPart and pizza:FindFirstChild("hittable") then list[#list + 1] = pizza end
    return list
end

local function weapon()
    local best, bestLevel = nil, -1
    for _, t in ipairs(tools()) do
        local level = t:FindFirstChild("WeaponLevel")
        if level and level.Value > bestLevel then best, bestLevel = t, level.Value end
    end
    return best
end

local function rootOf(model)
    return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

-- the game's own swing: its hit button (the mobile one, also live on PC).
-- The game paces it and works out targets and damage itself.
local function swing()
    local hit = Bindables and Bindables:FindFirstChild("MobileHit")
    if hit then pcall(hit.Fire, hit) end
end

-- the hitbox is 8.5 wide and 13 deep, 1.8 studs in front of you; 3 studs
-- back from the target, facing it, is well inside it
local function standInFront(target)
    local _, root = myChar()
    local part = rootOf(target)
    if not root or not part then return false end
    local tpos = part.Position
    local away = Vector3.new(root.Position.X - tpos.X, 0, root.Position.Z - tpos.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    local stand = Vector3.new(tpos.X, tpos.Y, tpos.Z) + away * 3
    root.CFrame = CFrame.lookAt(stand, Vector3.new(tpos.X, stand.Y, tpos.Z))
    root.AssemblyLinearVelocity = Vector3.zero
    return true
end

local function closest(list)
    local _, root = myChar()
    if not root then return nil end
    local best, bestDist = nil, math.huge
    for _, model in ipairs(list) do
        local part = rootOf(model)
        if part then
            local d = (part.Position - root.Position).Magnitude
            if d < bestDist then best, bestDist = model, d end
        end
    end
    return best, bestDist
end

loop(0.08, function()
    if not S.Farm and not S.Swing then
        Status.Farm = "off"
        return
    end
    if not myChar() then return end
    local wep = weapon()
    if not wep then
        Status.Farm = "no weapon (get a crowbar from the rack)"
        return
    end
    local list = enemies()
    if S.FarmBosses then
        for _, boss in ipairs(bossTargets()) do list[#list + 1] = boss end
    end
    local target, dist = closest(list)
    if not target then
        Status.Farm = "no bad guys right now"
        return
    end
    if not S.Farm and dist > 8 then
        Status.Farm = "waiting for one to come close"
        return
    end
    if wep.Parent ~= LocalPlayer.Character and not equip(wep) then
        Status.Farm = "couldn't equip " .. wep.Name
        return
    end
    if S.Farm then standInFront(target) end
    Status.Farm = "hitting " .. (target.Name == " " and "a bad guy" or target.Name)
    swing()
end)

-- Scary Mary: when she's stunned (stars over her head) the key on her back
-- can be turned: its click, from within its 12 stud reach
loop(0.3, function()
    if not S.AutoMary then return end
    local mary = Workspace:FindFirstChild("Villainess")
    local stars = mary and path(mary, "Head2/Stars")
    if not (stars and stars.Enabled) then return end
    local key = path(mary, "RoboBackKey/Handle/SpinnerClick")
    if not key then return end
    goNear(key, 8)
    touch(key)
    local detector = key:FindFirstChildOfClass("ClickDetector")
    if detector then click(detector) end
    task.wait(1)
end)

--// training ----------------------------------------------------------------
-- Treadmill (Speed): the machine's own start click, then you're kept on the
-- target spot the game lights up (standing on it is the bonus XP), never
-- touching the back of the cage. The game ticks the XP itself every 3s.
-- Bench press (Strength): the machine's own start click, then the game's own
-- click handler, which lifts, and fills the bonus bar when one comes up.
-- Book (both, Nerd role): the game's own reading, with its quiz answered.

local Training = { Machine = nil }

local function myMachine(folderName, machineName)
    local folder = Workspace:FindFirstChild(folderName)
    for _, eq in ipairs(folder and folder:GetChildren() or {}) do
        local owner = eq:FindFirstChild("Owner")
        if eq.Name == machineName and owner and owner.Value == LocalPlayer.Name then return eq end
    end
    return nil
end

local function freeMachine(folderName, machineName)
    local folder = Workspace:FindFirstChild(folderName)
    local best, bestDist = nil, math.huge
    for _, eq in ipairs(folder and folder:GetChildren() or {}) do
        local owner = eq:FindFirstChild("Owner")
        local start = eq:FindFirstChild("StartPart")
        if eq.Name == machineName and owner and owner.Value == "" and start then
            local d = distance(start.Position)
            if d < bestDist then best, bestDist = eq, d end
        end
    end
    return best
end

local function startMachine(eq)
    local start = eq and eq:FindFirstChild("StartPart")
    local detector = start and start:FindFirstChildOfClass("ClickDetector")
    if not detector then return false end
    goNear(start, 8)
    click(detector)
    return waitFor(4, function()
        local owner = eq:FindFirstChild("Owner")
        return owner ~= nil and owner.Value == LocalPlayer.Name
    end)
end

local function leaveMachine()
    local _, _, hum = myChar()
    if hum then hum.Jump = true end
    Training.Machine = nil
end

-- the spot the game lights up on the treadmill, and its touch sensor
local function treadmillTarget(eq)
    local options = eq:FindFirstChild("TredmillOptions")
    for _, spot in ipairs(options and options:GetChildren() or {}) do
        local decal = spot:FindFirstChild("Decal")
        if spot:IsA("BasePart") and decal and math.abs(decal.Transparency - 0.6) < 0.01 then
            local sensor
            for _, child in ipairs(spot:GetChildren()) do
                if child:IsA("BasePart") and not child:FindFirstChild("Decal") then sensor = child end
            end
            return spot, sensor
        end
    end
    return nil
end

local LastSensor = nil

-- keeps you on the lit spot every frame while on the treadmill
track(RunService.Heartbeat:Connect(function()
    if Unloaded or not S.Treadmill or not Training.Machine or Training.Machine.Name ~= "Tredmill" then return end
    pcall(function()
        local eq = Training.Machine
        local _, root = myChar()
        local here = eq:FindFirstChild("WorkoutHere")
        if not root or not here then return end
        local spot, sensor = treadmillTarget(eq)
        local rotation = here.CFrame - here.CFrame.Position
        local target = spot and Vector3.new(spot.Position.X, root.Position.Y, spot.Position.Z) or Vector3.new(here.Position.X, root.Position.Y, here.Position.Z)
        root.CFrame = CFrame.new(target) * rotation
        root.AssemblyLinearVelocity = Vector3.zero
        if sensor and sensor ~= LastSensor then
            LastSensor = sensor
            task.spawn(touch, sensor)
        end
    end)
end))

loop(1, function()
    if not S.Treadmill then return end
    if speedLevel() >= 5 then
        if myMachine("Tredmills", "Tredmill") then leaveMachine() end
        S.Treadmill = false
        Status.Train = "speed is maxed"
        notify("Speed is level 5")
        return
    end
    local eq = myMachine("Tredmills", "Tredmill")
    if eq then
        Training.Machine = eq
        local ss = mod("StrengthService")
        Status.Train = ("treadmill: speed %d, xp %.1f"):format(speedLevel(), ss and ss.xp or 0)
        return
    end
    Training.Machine = nil
    local free = freeMachine("Tredmills", "Tredmill")
    if not free then
        Status.Train = "every treadmill is taken"
        return
    end
    Status.Train = "getting on a treadmill"
    if startMachine(free) then Training.Machine = free end
end)

loop(0.12, function()
    if not S.Bench then return end
    if strengthLevel() >= 5 then
        if myMachine("BenchPresses", "BenchPress") then leaveMachine() end
        S.Bench = false
        Status.Train = "strength is maxed"
        notify("Strength is level 5")
        return
    end
    local eq = myMachine("BenchPresses", "BenchPress")
    if not eq then
        Training.Machine = nil
        local free = freeMachine("BenchPresses", "BenchPress")
        if not free then
            Status.Train = "every bench is taken"
            task.wait(1)
            return
        end
        Status.Train = "getting on a bench"
        if startMachine(free) then
            Training.Machine = free
            -- the server hands over the bar once the bench is yours
            waitFor(8, function() return LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("BarTool") ~= nil end)
        end
        return
    end
    Training.Machine = eq
    if not (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("BarTool")) then
        Status.Train = "waiting for the bar"
        return
    end
    local ss = mod("StrengthService")
    Status.Train = ("bench: strength %d, xp %.1f"):format(strengthLevel(), ss and ss.xp2 or 0)
    -- a lift is a click released in the world
    gameClick(UserInputService.InputEnded, "GymService", Enum.UserInputState.End)
end)

-- the book's quiz: "a + b" / "a - b", the button whose answer matches
local function answerQuiz()
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local book = gui and path(gui, "Book/Book/Book")
    if not book or not book.Visible then return false end
    local question = book:FindFirstChild("Question")
    local a, op, b = tostring(question and question.Text or ""):match("(%d+)%s*([%+%-])%s*(%d+)")
    if not a then return false end
    local answer = op == "+" and (tonumber(a) + tonumber(b)) or (tonumber(a) - tonumber(b))
    for i = 1, 3 do
        local button = book:FindFirstChild("Button" .. i)
        local label = button and button:FindFirstChild("Answer")
        if label and button.Visible and label.Text == tostring(answer) then
            task.wait(0.4 + math.random() * 0.6)
            return fireGui(button)
        end
    end
    return false
end

loop(0.5, function()
    if not S.Read then return end
    if speedLevel() >= 5 and strengthLevel() >= 5 then
        S.Read = false
        Status.Train = "both stats are maxed"
        return
    end
    local gs = mod("GymService")
    local book = findTool("Book")
    if not book then
        Status.Train = "reading needs the Book (Nerd role)"
        return
    end
    if gs and gs.isReading then
        Status.Train = ("reading: speed %d, strength %d"):format(speedLevel(), strengthLevel())
        answerQuiz()
        return
    end
    if not equip(book) then return end
    task.wait(0.3)
    Status.Train = "opening the book"
    if gs and type(gs.startReading) == "function" then
        pcall(gs.startReading)
    else
        gameClick(UserInputService.InputBegan, "BookToolClient", Enum.UserInputState.Begin)
    end
    task.wait(1)
end)

--// food --------------------------------------------------------------------
-- Eating: the food in hand, used through the game's own click handler
-- (HoldingService), exactly like clicking with it. Next to the cat or the
-- punchable character a click feeds them instead, so there the same request
-- the handler would send is sent directly.

local FOODS = {
    { Name = "GoldPizza", Send = function() fire("CurePlayer", LocalPlayer, LocalPlayer) end },
    { Name = "RainbowPizza", Send = function() fire("RainbowPizza", LocalPlayer) end },
    { Name = "Pizza", Send = function() fire("Energy", 25, "Pizza") end },
    { Name = "BloxyCola", Send = function() fire("Energy", 15, "BloxyCola") end },
    { Name = "Apple", Send = function() fire("Energy", 15, "Apple") end },
    { Name = "Cookie", Send = function() fire("Energy", 15, "Cookie") end },
    { Name = "ExpiredBloxyCola", Send = function() fire("Energy", 15, "ExpiredBloxyCola") end },
    { Name = "Chips", Send = function(tool) fire("Energy", "Chips", nil, tool) end },
    { Name = "Lollipop", Handler = "LollipopScript" },
    { Name = "GoldenApple", Send = function() fire("HealTheNoobs") end },
}

local function nearFeedable()
    local cat = path(Workspace, "TheHouse/SmallCat/Torso")
    local punch = path(Workspace, "Punchable Character/HumanoidRootPart")
    return (cat and distance(cat.Position) < 15) or (punch and distance(punch.Position) < 15)
end

local function eatOnce()
    for _, food in ipairs(FOODS) do
        local tool = findTool(food.Name)
        local charges = tool and tool:FindFirstChild("Charges")
        if tool and (not charges or charges.Value > 0) then
            if not equip(tool) then return nil end
            task.wait(0.35)
            if food.Handler then
                gameClick(UserInputService.InputBegan, food.Handler, Enum.UserInputState.Begin)
            elseif nearFeedable() or not gameClick(UserInputService.InputBegan, "HoldingService", Enum.UserInputState.Begin) then
                food.Send(tool)
            end
            return food.Name
        end
    end
    return nil
end

loop(2, function()
    if not S.AutoEat or Energy >= S.EatBelow then return end
    if not myChar() then return end
    -- the bench and reading stop if you take something else in hand
    if (S.Bench or S.Read) and Training.Machine then return end
    eatOnce()
end)

-- MedKit: heals other players (not yourself), through the game's own medkit
-- event, the same thing clicking someone with it does
local function healOthers()
    local kit = findTool("MedKit")
    if not kit then
        notify("You need the MedKit")
        return
    end
    equip(kit)
    task.wait(0.3)
    local medEvent = Bindables and Bindables:FindFirstChild("MedKitEvent")
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
            goNear(player.Character.HumanoidRootPart, 8)
            if medEvent then pcall(medEvent.Fire, medEvent, 1, player) end
            task.wait(1.6)
        end
    end
end

--// loot --------------------------------------------------------------------

local function lootOnce()
    local count = 0
    local function take(obj)
        if Unloaded or not obj or not obj.Parent then return end
        local detector = detectorOf(obj)
        if detector and detector.MaxActivationDistance > 0 then
            if reachAndClick(obj) then count += 1 end
            task.wait(0.3)
        end
    end
    -- drawers: apples, cookies, the key, money, the attic medkit, notes once shown
    local hidden = Workspace:FindFirstChild("Hidden")
    for _, item in ipairs(hidden and hidden:GetChildren() or {}) do
        local needsStrength = item.Name == "Bottle" or item.Name == "RainbowPizza"
        if not needsStrength or strengthLevel() >= 2 then take(item) end
    end
    -- crates (strength 2)
    if strengthLevel() >= 2 then
        local boxes = Workspace:FindFirstChild("Boxes")
        for _, box in ipairs(boxes and boxes:GetChildren() or {}) do take(box) end
    end
    take(Workspace:FindFirstChild("RainbowPizzaBox"))
    -- the golden apple, once the road mission turns it gold
    local apple = Workspace:FindFirstChild("GoldenApple")
    local gold = apple and pcall(function()
        local color = apple.Mesh.VertexColor
        assert(color.X > 0.9 and color.Y > 0.9 and color.Z < 0.1)
    end)
    if gold then take(apple) end
    Status.Loot = ("picked up %d"):format(count)
    return count
end

local function grabCrowbar()
    local rack = path(Workspace, "TheHouse/Rack")
    if not rack then return false end
    return reachAndClick(rack)
end

loop(5, function()
    if S.AutoLoot then lootOnce() end
end)

-- money bad guys drop: the server announces each with BadGuyMoney; the
-- game's pickup is walking into it (or clicking it), so you're put on it
local PendingMoney = {}
if remote("BadGuyMoney") then
    track(remote("BadGuyMoney").OnClientEvent:Connect(function(live, part)
        if live and typeof(part) == "Instance" then PendingMoney[part] = true end
    end))
end

loop(0.4, function()
    if not S.AutoMoney then return end
    for part in pairs(PendingMoney) do
        PendingMoney[part] = nil
        if part.Parent and part:IsA("BasePart") then
            local _, root = myChar()
            if not root then return end
            local back = root.CFrame
            root.CFrame = CFrame.new(part.Position + Vector3.new(0, 2, 0))
            task.wait(0.15)
            touch(part)
            local detector = part:FindFirstChildOfClass("ClickDetector")
            if detector then click(detector) end
            task.wait(0.25)
            local _, r = myChar()
            if r then r.CFrame = back end
        end
    end
end)

-- outside food: walk over the pizzas and cola packs the server scatters
-- outside (that's the pickup), carry them in through the front door (that
-- puts them on the table), then eat from the table
local function outsideFoodOnce()
    local outside = Workspace:FindFirstChild("OutsideParts")
    local _, root = myChar()
    if not outside or not root then return 0 end
    local back = root.CFrame
    local picked = 0
    for _, item in ipairs(outside:GetChildren()) do
        local part = item:IsA("BasePart") and item or item.PrimaryPart
        if part then
            local _, r = myChar()
            if not r then break end
            r.CFrame = CFrame.new(part.Position + Vector3.new(0, 2, 0))
            task.wait(0.2)
            touch(part)
            picked += 1
            task.wait(0.4)
        end
    end
    if picked > 0 then
        local door = path(Workspace, "InsideTouchParts/FrontDoor")
        if door then
            local _, r = myChar()
            if r then r.CFrame = CFrame.new(door.Position) end
            task.wait(0.2)
            touch(door)
            task.wait(1.5)
        end
        local onTable = Workspace:FindFirstChild("OnTable")
        for _, food in ipairs(onTable and onTable:GetDescendants() or {}) do
            if food:IsA("ClickDetector") then
                goNear(food.Parent, 10)
                click(food)
                task.wait(0.4)
            end
        end
    end
    local _, r = myChar()
    if r then r.CFrame = back end
    return picked
end

loop(6, function()
    if S.OutsideFood then outsideFoodOnce() end
end)

--// vending -----------------------------------------------------------------
-- The machine's own buy click from within its reach, once you have the
-- money; the game dispenses (the server marks the machine yours first) and
-- claims the item itself after a few seconds. With the swap on, that claim
-- asks for the item you picked instead of what came out.

local MACHINES = { "Food", "Drinks", "Weapons", "Armor" }
local VEND_ITEMS = { "Apple", "Cookie", "Chips", "BloxyCola", "Key", "Crowbar1", "Crowbar2", "Crowbar3", "Bat", "Broom", "Pitchfork", "Hammer", "Wrench", "LinkedSword", "Pizza", "GoldPizza", "RainbowPizza", "MedKit", "Battery" }

local function buyFrom(machine)
    local m = path(Workspace, "VendingMachines/" .. machine)
    local price = m and m:FindFirstChild("PricePart")
    local detector = price and price:FindFirstChildOfClass("ClickDetector")
    if not detector then return false, "machine not found" end
    local shop, money = mod("ShopServiceClient"), mod("MoneyService")
    local cost = shop and shop.machines and shop.machines[machine] and shop.machines[machine].Price
    if cost and money and (money.playersMoney or 0) < cost then return false, ("needs $%d"):format(cost) end
    goNear(price, 10)
    click(detector)
    -- the server makes it yours, the game dispenses
    local owner = price:FindFirstChild("Owner")
    if owner and not waitFor(10, function() return owner.Value == LocalPlayer.Name end) then return false, "machine didn't open" end
    return true, "bought"
end

--// story -------------------------------------------------------------------

-- Uncle Pete counts your kills only after you've talked to him once, and pays
-- on a click once a quest is done. His click handler, straight.
local function clickPete()
    local pete = Workspace:FindFirstChild("UnclePete")
    local detector = pete and pete:FindFirstChildOfClass("ClickDetector")
    if detector then return click(detector) end
    return false
end

task.delay(4, function()
    if S.AutoPete and not Unloaded then clickPete() end
end)

loop(1.5, function()
    if not S.AutoPete then return end
    local alert = path(Workspace, "UnclePete/Head/Alertbbg/Alert")
    if alert and alert.Visible then
        clickPete()
        Status.Story = "claimed an Uncle Pete reward"
        task.wait(3)
    end
end)

-- the generator bikes: on a free seat through its own click; the game then
-- pedals; sprint (speed level 3) through its own sprint button
local function onBike()
    local generator = Workspace:FindFirstChild("Generator")
    for _, seat in ipairs(generator and generator:GetChildren() or {}) do
        local owner = seat:FindFirstChild("Owner")
        if owner and owner.Value == LocalPlayer.Name then return seat end
    end
    return nil
end

loop(1, function()
    if not S.AutoBike then return end
    local bikes = mod("BikeServiceClient")
    local generator = Workspace:FindFirstChild("Generator")
    if not generator or (bikes and bikes.powerOff == false) then
        Status.Story = "the generator isn't needed right now"
        return
    end
    if onBike() then
        Status.Story = "pedalling"
        local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local sprint = gui and path(gui, "Assets/SprintButton")
        if sprint and sprint.Visible and bikes and not bikes.isSprinting then fireGui(sprint) end
        return
    end
    for _, seat in ipairs(generator:GetChildren()) do
        local owner = seat:FindFirstChild("Owner")
        local part = seat:FindFirstChild("Seat")
        local detector = part and part:FindFirstChildOfClass("ClickDetector")
        if owner and owner.Value == "" and detector then
            goNear(part, 6)
            click(detector)
            touch(part)
            Status.Story = "getting on a bike"
            return
        end
    end
    Status.Story = "every bike is taken"
end)

-- the power objective: the server says which two trash cans hold batteries
-- and how many searches each takes; those cans are searched, the batteries
-- picked up, and put in the two slots
local BatteryInfo = nil
if remote("BatteryEvent") then
    track(remote("BatteryEvent").OnClientEvent:Connect(function(what, a, b, counts)
        if what == "info" then
            BatteryInfo = { a, b, counts }
        elseif what == "createClickDetectors" and S.AutoBatteries then
            task.delay(1, function() if not Unloaded then task.spawn(Genv.__BreakIn2Batteries) end end)
        end
    end))
end

local function runBatteries()
    local cans = Workspace:FindFirstChild("TrashCans")
    if not cans then return "no trash cans here" end
    local _, root = myChar()
    if not root then return "no character" end
    local back = root.CFrame
    local targets = {}
    if BatteryInfo then
        targets = { BatteryInfo[1], BatteryInfo[2] }
    else
        for _, can in ipairs(cans:GetChildren()) do targets[#targets + 1] = tonumber(can.Name:sub(9)) end
    end
    for _, index in ipairs(targets) do
        local can = cans:FindFirstChild("TrashCan" .. tostring(index))
        local detector = can and can:FindFirstChild("Model") and can.Model:FindFirstChildOfClass("ClickDetector")
        if detector then
            goNear(can.Model, 8)
            local times = BatteryInfo and BatteryInfo[3] and tonumber(BatteryInfo[3][index]) or 3
            for _ = 1, math.max(times, 1) do
                if Unloaded or can:FindFirstChild("Battery2") then break end
                click(detector)
                task.wait(0.5)
            end
            local battery = can:FindFirstChild("Battery2")
            if battery then
                local cd = detectorOf(battery)
                if cd then click(cd) end
                waitFor(3, function() return findTool("Battery") ~= nil end)
            end
        end
    end
    for slot = 1, 2 do
        local battery = findTool("Battery")
        local slotModel = Workspace:FindFirstChild("BatterySlot" .. slot)
        local done = slotModel and slotModel:FindFirstChild("Done")
        if battery and slotModel and not (done and done.Value) then
            equip(battery)
            goNear(slotModel, 8)
            task.wait(0.3)
            fire("BatteryEvent", "UsedBattery", slot)
            task.wait(0.6)
        end
    end
    local _, r = myChar()
    if r then r.CFrame = back end
    return "done"
end
Genv.__BreakIn2Batteries = function() Status.Story = "batteries: " .. tostring(runBatteries()) end

-- ending vote: the game's vote request for the chosen ending, when it opens
if remote("ChooseEnding") then
    track(remote("ChooseEnding").OnClientEvent:Connect(function(what)
        if what ~= "StartVote" or not S.AutoVote then return end
        task.delay(1.5, function() fire("ChooseEnding", S.VoteFor) end)
    end))
end

-- the intro camera can be cut short safely: only the camera is local, the
-- story still waits for the server
local function freeCamera()
    pcall(function()
        Camera.CameraType = Enum.CameraType.Custom
        local _, _, hum = myChar()
        if hum then Camera.CameraSubject = hum end
    end)
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local skip = gui and path(gui, "Assets/SkipButton")
    if skip then fireGui(skip) end
end

-- the Scary Larry ending's items, the way each is really collected
local function larryMask()
    local mask = path(Workspace, "MaskOutside/Part")
    if not mask then return "the mask isn't out" end
    goNear(mask, 4)
    touch(mask)
    local detector = detectorOf(Workspace:FindFirstChild("MaskOutside"))
    if detector then click(detector) end
    return "mask"
end

local function larryTree()
    if strengthLevel() < 3 then return "the tree needs strength 3" end
    local tree = Workspace:FindFirstChild("ChopTree")
    if not tree or not tree.PrimaryPart then return "no tree" end
    local wep = weapon()
    if not wep or not equip(wep) then return "needs a weapon" end
    goNear(tree.PrimaryPart, 5)
    for _ = 1, 6 do
        local _, root = myChar()
        if root then root.CFrame = CFrame.lookAt(root.Position, Vector3.new(tree.PrimaryPart.Position.X, root.Position.Y, tree.PrimaryPart.Position.Z)) end
        swing()
        task.wait(0.6)
    end
    return "tree"
end

local function larryCrowbar()
    local crowbar = Workspace:FindFirstChild("GoldCrowbarClickable")
    if not crowbar then return "fell the tree first" end
    local part = crowbar:FindFirstChild("Part") or crowbar.PrimaryPart
    if part then
        goNear(part, 4)
        touch(part)
    end
    local detector = detectorOf(crowbar)
    if detector then click(detector) end
    return "crowbar"
end

local function larryHat()
    local hat = Workspace:FindFirstChild("LarryHatPickup")
    if not hat then return "give the punchable character a pizza, then a gold pizza, first" end
    goNear(hat, 4)
    touch(hat)
    local detector = detectorOf(hat)
    if detector then click(detector) end
    return "hat"
end

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

-- speed is left alone while training: the treadmill sets its own pace and
-- reading stops the moment you move
local function training()
    return Training.Machine ~= nil or (S.Read and mod("GymService") and mod("GymService").isReading)
end

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    pcall(function()
        local _, _, hum = myChar()
        if not hum or training() then return end
        if S.Speed and hum.WalkSpeed ~= S.SpeedValue then hum.WalkSpeed = S.SpeedValue end
        if S.Jump then
            hum.UseJumpPower = true
            if hum.JumpPower ~= S.JumpValue then hum.JumpPower = S.JumpValue end
        end
    end)
end))

track(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    if S.Speed or S.Jump then setSpeedLocks(true) end
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

--// esp ---------------------------------------------------------------------

local Esp = {}
local EspFolder = Instance.new("Folder")
EspFolder.Name = "BI2_ESP"
pcall(function() EspFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not EspFolder.Parent then EspFolder.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BOSS_NAMES = { PizzaBossAlec = "Pizza Boss", BadGuyBrute = "Brute", AgentBoss = "Bradley", AgentBeans = "Bradley Beans", Villainess = "Scary Mary", ["Scary Larry"] = "Scary Larry", BigBoss = "Big Boss" }

local function bossLives()
    local area = mod("BossAreaServiceClient")
    local final = mod("BossFinalClient")
    return {
        Arena1 = area and area.bossHealth, Arena2 = area and area.bossHealth2, Arena3 = area and area.bossHealth3,
        Mary = final and final.MaryHealth, Bradley = final and final.AgentHealth,
    }
end

local function espFor(target, color, text)
    local entry = Esp[target]
    if not entry then
        local highlight = Instance.new("Highlight")
        highlight.FillTransparency = 0.7
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Adornee = target
        highlight.Parent = EspFolder
        local billboard = Instance.new("BillboardGui")
        billboard.Size = UDim2.fromOffset(170, 36)
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
    local function dist(obj)
        local pos = position(obj)
        local d = pos and distance(pos)
        return (d and d < math.huge) and ("  %dm"):format(math.floor(d)) or ""
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
                local extra = (name == "Villainess" and lives.Mary) or ((name == "AgentBoss" or name == "AgentBeans") and lives.Bradley) or nil
                espFor(boss, Color3.fromRGB(190, 90, 255), label .. (extra and ("  " .. tostring(extra) .. " lives") or "") .. dist(boss))
            end
        end
    end
    if S.EspItems then
        local hidden = Workspace:FindFirstChild("Hidden")
        for _, item in ipairs(hidden and hidden:GetChildren() or {}) do
            if item.Name ~= "Money" and (item:IsA("BasePart") or item:IsA("Model")) then espFor(item, Color3.fromRGB(90, 230, 120), item.Name .. dist(item)) end
        end
        for _, name in ipairs({ "RainbowPizzaBox", "GoldenApple", "MaskOutside", "GoldCrowbarClickable", "LarryHatPickup", "Punchable Character", "ChopTree" }) do
            local obj = Workspace:FindFirstChild(name)
            if obj then espFor(obj, Color3.fromRGB(90, 230, 120), name .. dist(obj)) end
        end
        local boxes = Workspace:FindFirstChild("Boxes")
        for _, box in ipairs(boxes and boxes:GetChildren() or {}) do
            if detectorOf(box) then espFor(box, Color3.fromRGB(90, 230, 120), "Crate" .. dist(box)) end
        end
        local outside = Workspace:FindFirstChild("OutsideParts")
        for _, item in ipairs(outside and outside:GetChildren() or {}) do espFor(item, Color3.fromRGB(90, 230, 120), item.Name .. dist(item)) end
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
    end
    if S.EspPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then espFor(player.Character, Color3.fromRGB(80, 170, 255), player.DisplayName .. dist(player.Character)) end
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
    { "Treadmills", function() return position(Workspace:FindFirstChild("Tredmills")) end },
    { "Bench presses", function() return position(Workspace:FindFirstChild("BenchPresses")) end },
    { "Trash cans", function() return position(Workspace:FindFirstChild("TrashCans")) end },
    { "Battery slot 1", function() return position(Workspace:FindFirstChild("BatterySlot1")) end },
    { "Battery slot 2", function() return position(Workspace:FindFirstChild("BatterySlot2")) end },
    { "Generator", function() return position(Workspace:FindFirstChild("Generator") or Workspace:FindFirstChild("TempGenerator")) end },
    { "Golden apple", function() return position(Workspace:FindFirstChild("GoldenApple")) end, Vector3.new(93.2, 48.3, -789.2) },
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
        if spot[1] == name then return (spot[2] and spot[2]()) or spot[3] end
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
    if Training.Machine then pcall(leaveMachine) end
    for key, value in pairs(S) do
        if value == true then S[key] = false end
    end
    Unloaded = true
    pcall(setCheckDamage)
    pcall(setSpeedLocks, false)
    pcall(setAntiAfk, false)
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    pcall(function() EspFolder:Destroy() end)
    Genv.__BreakIn2Batteries = nil
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

    local farm = Tab:AddLeftGroupbox('Fighting', 'crosshair')
    toggle(farm, 'bi_farm', 'Auto farm bad guys', 'Farm', 'goes to the nearest bad guy, stands in front of it and swings with the game\'s own hit button, your weapon in hand. damage is the game\'s own (it grows with strength and weapon)')
        :AddKeyPicker('bi_farm_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto farm' })
    toggle(farm, 'bi_swing', 'Auto swing (stay put)', 'Swing', 'swings whenever a bad guy is within reach, without moving you')
    toggle(farm, 'bi_bosses', 'Include bosses', 'FarmBosses', 'Bradley once he\'s dizzy, the pizza boss to start its fight')
    toggle(farm, 'bi_mary', 'Auto turn Mary\'s key', 'AutoMary', 'when Scary Mary is stunned, turns the key on her back (that\'s what damages her)')
    local farmStatus = farm:AddLabel('-', true)
    every(0.5, function()
        local wep = weapon()
        farmStatus:SetText(("%s\nweapon: %s   strength %d"):format(Status.Farm, wep and (wep.Name .. " lvl " .. tostring(wep.WeaponLevel.Value)) or "none", strengthLevel()))
    end)
    farm:AddButton({ Text = 'Grab a crowbar (rack)', Func = function() task.spawn(grabCrowbar) end })

    local guard = Tab:AddRightGroupbox('Protection', 'shield')
    toggle(guard, 'bi_god', 'God mode', 'God', 'the game reports most of your damage itself (hail, lightning, lava, bombs, boss attacks, the road); this stops those reports, and tells the server its own attacks missed you', function(v)
        needHook(v)
        setCheckDamage()
    end)
    toggle(guard, 'bi_nocatch', 'Can\'t be caught', 'NoCatch', 'the chasing boss decides it caught you on your side; this stops that', needHook)
    toggle(guard, 'bi_nolobby', 'No forced lobby', 'NoLobby', 'stops the death screen sending you to the lobby when its countdown ends', needHook)
    local energy = guard:AddLabel('-', true)
    every(0.5, function()
        local l = bossLives()
        energy:SetText(("energy: %d / 200\nboss lives: %s %s %s   Mary %s   Bradley %s"):format(math.floor(Energy),
            tostring(l.Arena1 or "-"), tostring(l.Arena2 or "-"), tostring(l.Arena3 or "-"), tostring(l.Mary or "-"), tostring(l.Bradley or "-")))
    end)
end

do
    local Tab = Window:AddTab('Training', 'dumbbell', 'Speed and strength')

    local box = Tab:AddLeftGroupbox('Gym', 'dumbbell')
    box:AddLabel('The server keeps your XP, so levels are earned on the real equipment: this does the training for you, at the game\'s own pace (a few minutes per stat).', true)
    toggle(box, 'bi_tread', 'Auto treadmill (speed)', 'Treadmill', 'gets on a free treadmill and keeps you on the lit spot for the bonus XP until speed is 5')
    toggle(box, 'bi_bench', 'Auto bench press (strength)', 'Bench', 'gets on a free bench and lifts with the game\'s own click, filling the bonus bar, until strength is 5')
    toggle(box, 'bi_read', 'Auto read (Book role)', 'Read', 'reads the book and answers its quiz; trains both stats. needs the Book')
    local status = box:AddLabel('-', true)
    every(0.5, function()
        local ss = mod("StrengthService")
        status:SetText(("%s\nspeed %d (xp %.1f)   strength %d (xp %.1f)"):format(Status.Train, speedLevel(), ss and ss.xp or 0, strengthLevel(), ss and ss.xp2 or 0))
    end)
    box:AddButton({ Text = 'Get off the machine', Func = function()
        S.Treadmill, S.Bench = false, false
        leaveMachine()
    end })
end

do
    local Tab = Window:AddTab('Items', 'backpack', 'Food, loot, vending')

    local heal = Tab:AddLeftGroupbox('Food', 'heart')
    toggle(heal, 'bi_autoeat', 'Auto eat', 'AutoEat', 'eats the best food you carry when energy drops under the line, by really using it')
    heal:AddSlider('bi_eatbelow', { Text = 'Eat below', Min = 20, Max = 200, Default = S.EatBelow, Rounding = 0, Callback = function(v) S.EatBelow = v end })
    heal:AddButton({ Text = 'Eat now', Func = function() task.spawn(function() notify(eatOnce() and "eating" or "no food on you") end) end })
    heal:AddButton({ Text = 'Heal the others (MedKit)', Func = function() task.spawn(healOthers) end })
    toggle(heal, 'bi_outside', 'Collect outside food', 'OutsideFood', 'picks up the pizzas and cola packs outside, carries them in to the table and eats from it')

    local loot = Tab:AddRightGroupbox('Loot', 'coins')
    toggle(loot, 'bi_autoloot', 'Auto loot', 'AutoLoot', 'goes to each drawer item (apples, cookies, key, money, notes, the attic medkit), crate and box in reach and clicks it, then comes back. crates and the bottle need strength 2')
    toggle(loot, 'bi_automoney', 'Auto pick up dropped money', 'AutoMoney', 'steps onto the money bad guys drop the moment it lands')
    local lootStatus = loot:AddLabel('', true)
    every(1, function()
        local ms = mod("MoneyService")
        lootStatus:SetText(("money: $%s\n%s"):format(tostring(ms and ms.playersMoney or "-"), Status.Loot))
    end)
    loot:AddButton({ Text = 'Loot everything now', Func = function() task.spawn(lootOnce) end })

    local shop = Tab:AddLeftGroupbox('Vending', 'shopping-cart')
    local result = shop:AddLabel('', true)
    for _, machine in ipairs(MACHINES) do
        shop:AddButton({
            Text = 'Buy from ' .. machine,
            Func = function()
                task.spawn(function()
                    local _, why = buyFrom(machine)
                    result:SetText(machine .. ": " .. tostring(why))
                end)
            end,
        })
    end

    local swap = Tab:AddRightGroupbox('Item swap', 'repeat')
    swap:AddLabel('The game\'s client says which item it takes from a vending machine and from a drawer. These change that to the item you pick, on a real buy or pickup. Whether the server allows a given item is only known by trying.', true)
    toggle(swap, 'bi_vendswap', 'Vending gives', 'VendSwap', nil, needHook)
    swap:AddDropdown('bi_venditem', { Text = 'Item', Values = VEND_ITEMS, Default = S.VendItem, Searchable = true, Callback = function(v) S.VendItem = v or S.VendItem end })
    toggle(swap, 'bi_pickswap', 'Drawer apples / cookies give', 'PickupSwap', nil, needHook)
    swap:AddDropdown('bi_pickitem', { Text = 'Item', Values = { "Key", "Apple", "Cookie" }, Default = S.PickupItem, Callback = function(v) S.PickupItem = v or S.PickupItem end })
end

do
    local Tab = Window:AddTab('Story', 'book-open', 'Objectives and endings')

    local quest = Tab:AddLeftGroupbox('Objectives', 'flag')
    toggle(quest, 'bi_pete', 'Auto Uncle Pete', 'AutoPete', 'talks to him once (his kill count only starts then) and takes each reward as soon as it\'s ready', function(v) if v then task.spawn(clickPete) end end)
    toggle(quest, 'bi_bike', 'Auto generator bike', 'AutoBike', 'when the power is out, gets on a free bike (it pedals itself) and sprints once you have speed 3')
    toggle(quest, 'bi_batteries', 'Auto batteries', 'AutoBatteries', 'when the battery hunt starts, searches the two trash cans that hold them, picks them up and places them')
    quest:AddButton({ Text = 'Do the batteries now', Func = function() task.spawn(Genv.__BreakIn2Batteries) end })
    local storyStatus = quest:AddLabel('', true)
    every(1, function() storyStatus:SetText(Status.Story) end)
    quest:AddButton({ Text = 'Skip intro camera', Func = freeCamera })

    local larry = Tab:AddRightGroupbox('Scary Larry ending', 'ghost')
    larry:AddLabel('The secret ending needs three things before the final fight. Each button gets one the real way.', true)
    local larryStatus = larry:AddLabel('', true)
    local function run(fn) task.spawn(function() larryStatus:SetText(tostring(fn())) end) end
    larry:AddButton({ Text = 'Mask (outside, by the bog)', Func = function() run(larryMask) end })
    larry:AddButton({ Text = 'Chop the tree (strength 3)', Func = function() run(larryTree) end })
    larry:AddButton({ Text = 'Gold crowbar (after the tree)', Func = function() run(larryCrowbar) end })
    larry:AddButton({ Text = 'Hat (after feeding the character)', Func = function() run(larryHat) end })

    local vote = Tab:AddLeftGroupbox('Ending vote', 'vote')
    toggle(vote, 'bi_vote', 'Auto vote', 'AutoVote', 'votes the moment the ending vote opens')
    vote:AddDropdown('bi_votefor', { Text = 'Vote for', Values = { "Ending1", "Ending2", "Ending3", "Ending4" }, Default = "Ending1", Callback = function(v) S.VoteFor = v or S.VoteFor end })
end

do
    local Tab = Window:AddTab('Player', 'user', 'Movement')
    local move = Tab:AddLeftGroupbox('Movement', 'footprints')
    toggle(move, 'bi_speed', 'Walk speed', 'Speed', 'held every frame; cutscene speed locks are switched off while it\'s on. paused while training', function(v) setSpeedLocks(v or S.Jump) end)
    move:AddSlider('bi_speedv', { Text = 'Speed', Min = 16, Max = 120, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'bi_jump', 'Jump power', 'Jump', nil, function(v) setSpeedLocks(v or S.Speed) end)
    move:AddSlider('bi_jumpv', { Text = 'Jump', Min = 30, Max = 200, Default = S.JumpValue, Rounding = 0, Callback = function(v) S.JumpValue = v end })
    toggle(move, 'bi_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'bi_noclip', 'Noclip', 'Noclip')
    toggle(move, 'bi_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('bi_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('bi_flyspeed', { Text = 'Fly speed', Min = 10, Max = 200, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })

    local tp = Tab:AddRightGroupbox('Teleport', 'map-pin')
    local names = {}
    for _, spot in ipairs(SPOTS) do names[#names + 1] = spot[1] end
    local chosen = names[1]
    tp:AddDropdown('bi_tp', { Text = 'Place', Values = names, Default = names[1], Searchable = true, Callback = function(v) chosen = v or chosen end })
    tp:AddButton({
        Text = 'Teleport',
        Func = function()
            local pos = spotPosition(chosen)
            if pos then teleport(pos) else notify(chosen .. " isn't loaded right now") end
        end,
    })
    local target
    tp:AddDropdown('bi_tp_player', { SpecialType = "Player", ExcludeLocalPlayer = true, Text = 'Player', Callback = function(v) target = v end })
    tp:AddButton({
        Text = 'Teleport to player',
        Func = function()
            local player = typeof(target) == "Instance" and target or Players:FindFirstChild(tostring(target))
            local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if root then teleport(root.Position) end
        end,
    })
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'ESP')
    local box = Tab:AddLeftGroupbox('ESP', 'scan-eye')
    toggle(box, 'bi_esp_enemies', 'Bad guys', 'EspEnemies')
    toggle(box, 'bi_esp_bosses', 'Bosses', 'EspBosses')
    toggle(box, 'bi_esp_items', 'Items, crates, batteries', 'EspItems')
    toggle(box, 'bi_esp_money', 'Money', 'EspMoney')
    toggle(box, 'bi_esp_players', 'Players', 'EspPlayers')
    local misc = Tab:AddRightGroupbox('Idle', 'clock')
    misc:AddToggle('bi_afk', {
        Text = 'Anti-AFK',
        Default = S.AntiAfk,
        Callback = function(v)
            S.AntiAfk = v
            setAntiAfk(v)
        end,
    })
end

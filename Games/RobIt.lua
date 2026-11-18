--// ROB IT ----------------------------------------------------------------------------------
-- place 83907398368798 (game 9472441390), built against version 190. Built on Ui3.
-- Every heist (House, Jewelry Store, Mansion, Bank, Yacht, Museum, ...) loads
-- into Workspace.Map with the same folders, so everything here works on all
-- of them. What the game's client shows:
--   Items    Map.StealableItems.<folder>.<item> models, each with a StealPrompt
--            (Worth, Rarity 1-5, Mutation, Diamond on gems). Hold times are
--            client side; StealPromptSight zeroes the reach of items you can't
--            see from your camera or head.
--   Bag      player attributes BagScale (0-10, full at 9.95) and
--            CurrentStolenItems. Touching Map.CollectTruck.TouchPart hands the
--            bag in (RequiredStolen / StolenAmount / TotalMoney on it).
--   Van      Map.Truck (Map.Boat on the yacht) seats; it leaves when the Map's
--            Time attribute hits 0.
--   Guards   Map.NPCS models: DetectRange (forward), DetectSpread (sideways),
--            BackDetection, HeightDetection, IsChasing, Hit, Punched, Blinded.
--            The server decides when you're seen and tells you with
--            Remotes.NPCRemotes.NPCStartedNoticing(npc).
--   Noise    Remotes.AnimationStateChanged:FireServer("Crouching" / "Idle" /
--            "Walking" / "Sprinting") is how the server knows how loud you are
--            (crouching and idle are quiet, sprinting is loud).
--   Games    MinigameEvent "Start" (name, ...) runs a module in
--            MainFrame.Minigames.Minigames; its EndGame(true) sends
--            MinigameEvent("Finished", true). Lockpick: the server fires
--            LockpickMinigame(door), the answer is FireServer(door, ok). The
--            ATM and safe are RemoteFunctions the server invokes on you (true =
--            done). Power box: HackPowerBox(true) -> FireServer(ok).
--   Crowbar  Tools.HitNPC(npc, "Crowbar"), Utilities.BreakDoor(door),
--            BreakWindow(glass), HitCashier(cashier, "Crowbar").
--   Rounds   FinishedStats at the end, PlayAgain("Replay" / "Next").

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__RobItUnload then
    pcall(Genv.__RobItUnload)
end
Genv.__RobItRun = (Genv.__RobItRun or 0) + 1
local RUN = Genv.__RobItRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__RobItRun == RUN
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
    -- steal
    FastSteal = false, StealTimePct = 60, StealAura = false, StealRange = 11, StealMinWorth = 0, StealThroughWalls = false,
    AutoDeliver = false, DeliverAt = 9.9, DeliverReturn = true,
    StealOrder = "Best worth first", SkipGuarded = true, GuardRadius = 18, StealAllReturn = true,
    -- stealth
    Silent = false, SpeedOn = false, WalkSpeed = 22, AntiStun = false, GuardAlert = true,
    CamerasBlind = false, NoNoiseAreas = false,
    -- minigames
    AutoMinigames = false, MinigameDelay = 0.6, InstantLockpick = false, InstantATM = false, InstantSafe = false,
    InstantPowerBox = false, AutoLockpickDoors = false,
    -- doors and crowbar
    AutoOpenDoors = false, DoorRange = 10, CrowbarAura = false, CrowbarRange = 9, CrowbarEquip = false,
    CrowbarGuards = true, CrowbarDoors = true, CrowbarGlass = true, CrowbarCashiers = true,
    -- esp
    ItemEsp = false, ItemMinWorth = 0, GuardEsp = false, GuardCones = true, CameraEsp = false, VanEsp = false,
    PlayerEsp = false, EspDistance = 600,
    -- world
    Fullbright = false, AutoEscape = false, EscapeAt = 20, AutoReplay = false, ReplayMode = "Same map", ReplayDelay = 4,
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
                warn("[ROB IT] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "ROB IT", Description = text, Time = seconds or 3 })
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
local function map()
    return Workspace:FindFirstChild("Map")
end
local function mapChild(name)
    local m = map()
    return m and m:FindFirstChild(name)
end
local function remote(path)
    local node = ReplicatedStorage:FindFirstChild("Remotes")
    for part in path:gmatch("[^%.]+") do
        node = node and node:FindFirstChild(part)
    end
    return node
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
    return inst:FindFirstChild("HumanoidRootPart") or inst:FindFirstChildWhichIsA("BasePart", true)
end
local function promptPos(prompt)
    local p = prompt.Parent
    return p and pivotOf(p)
end
local function bagFill()
    return tonumber(LocalPlayer:GetAttribute("BagScale")) or 0
end
local function busyMinigame()
    return LocalPlayer:GetAttribute("MinigameActive") == true
end
local Tried = setmetatable({}, { __mode = "k" })
local function tryOnce(key, every)
    local t = Tried[key]
    if t and os.clock() - t < every then
        return false
    end
    Tried[key] = os.clock()
    return true
end
-- Fire a prompt the way the game would: the executor's fireproximityprompt,
-- or holding it for its hold time.
local function firePrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then
            return true
        end
    end
    local ok = pcall(function()
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.05)
        prompt:InputHoldEnd()
    end)
    return ok
end
local Busy = { reason = nil }

--// Moving \\--
local Move = {}
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    function Move.ground(pos, ignore)
        local list = { myChar() }
        if ignore then
            table.insert(list, ignore)
        end
        params.FilterDescendantsInstances = list
        local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -30, 0), params)
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
    -- Stand next to something, on the floor, on your side of it.
    function Move.near(inst, gap)
        local root = myRoot()
        local pos = pivotOf(inst)
        if not (root and pos) then
            return false
        end
        local away = root.Position - pos
        away = Vector3.new(away.X, 0, away.Z)
        away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
        local spot = pos + away * (gap or 3)
        local floor = Move.ground(spot, inst)
        spot = floor and (floor + Vector3.new(0, 3, 0)) or (spot + Vector3.new(0, 1, 0))
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = CFrame.lookAt(spot, Vector3.new(pos.X, spot.Y, pos.Z))
        return true
    end
    -- Do something somewhere else, then come back.
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
            warn("[ROB IT] " .. tostring(err))
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

--// Items, guards, cameras \\--
local RARITY = {
    [1] = { "Common", Color3.fromRGB(200, 200, 200) },
    [2] = { "Uncommon", Color3.fromRGB(110, 230, 110) },
    [3] = { "Rare", Color3.fromRGB(90, 160, 255) },
    [4] = { "Legendary", Color3.fromRGB(200, 100, 255) },
    [5] = { "Mythical", Color3.fromRGB(255, 200, 60) },
}
local Mutations
pcall(function()
    Mutations = require(ReplicatedStorage:WaitForChild("MutationCatalog", 5))
end)
local Scan = { items = {}, guards = {}, cameras = {} }
do
    local function itemName(model, prompt)
        local asset = model:GetAttribute("Asset")
        if type(asset) == "string" and asset ~= "" then
            return asset
        end
        local name = (model.Name:gsub("%[%d+%]$", ""))
        if name == "" then
            name = prompt.ActionText
        end
        return name
    end
    -- Everything stealable on the map, re-read twice a second.
    loop(0.5, function()
        local items = {}
        local folder = mapChild("StealableItems")
        if folder then
            for _, d in folder:GetDescendants() do
                if d.Name == "StealPrompt" and d:IsA("ProximityPrompt") and d.Parent then
                    local model = d.Parent
                    local mutation = d:GetAttribute("Mutation") or model:GetAttribute("Mutation")
                    table.insert(items, {
                        prompt = d,
                        model = model,
                        name = itemName(model, d),
                        worth = tonumber(d:GetAttribute("Worth")) or tonumber(model:GetAttribute("Worth")) or 0,
                        rarity = tonumber(d:GetAttribute("Rarity")) or tonumber(model:GetAttribute("Rarity")) or 1,
                        mutation = mutation ~= "Normal" and mutation or nil,
                        diamond = d:GetAttribute("Diamond") ~= nil or model.Name:find("Gem") ~= nil,
                    })
                end
            end
        end
        Scan.items = items
        local guards = {}
        for _, name in { "NPCS", "EliteSnipers" } do
            local f = mapChild(name)
            if f then
                for _, m in f:GetChildren() do
                    if m:IsA("Model") and m:FindFirstChild("HumanoidRootPart") then
                        table.insert(guards, m)
                    end
                end
            end
        end
        Scan.guards = guards
        local cams = {}
        local cf = mapChild("Cameras")
        if cf then
            for _, m in cf:GetDescendants() do
                if m:IsA("Model") and m:GetAttribute("CatagoryName") == "Camera" then
                    table.insert(cams, m)
                end
            end
        end
        Scan.cameras = cams
    end)
    function Scan.knocked(guard)
        local hum = guard:FindFirstChildOfClass("Humanoid")
        return (hum and hum.Health <= 0) or guard:GetAttribute("Hit") == true
    end
    function Scan.guardNear(pos, radius)
        for _, g in Scan.guards do
            local root = g:FindFirstChild("HumanoidRootPart")
            if root and not Scan.knocked(g) and (root.Position - pos).Magnitude <= radius then
                return g
            end
        end
        return nil
    end
    function Scan.mutationColor(name)
        local m = type(Mutations) == "table" and type(Mutations.ByName) == "table" and Mutations.ByName[name]
        return type(m) == "table" and typeof(m.Color) == "Color3" and m.Color or Color3.fromRGB(255, 120, 220)
    end
end

--// Stealing \\--
local Steal = { info = "off", stolen = 0, delivered = 0, runInfo = "" }
do
    -- Steal time: each steal prompt's hold is set to a share of its normal
    -- time. The hold is counted on your side, but the server can check how
    -- long it took, so it's a slider instead of 0.
    local holds = setmetatable({}, { __mode = "k" }) -- prompt -> its normal hold
    local setTo = setmetatable({}, { __mode = "k" }) -- prompt -> what we set it to
    -- Through walls: the game's StealPromptSight zeroes the reach of items
    -- your camera can't see; it's switched off and the reach put back.
    local reach = setmetatable({}, { __mode = "k" })
    local sightScript
    local function sight(enabled)
        sightScript = sightScript or (LocalPlayer:FindFirstChild("PlayerScripts") and LocalPlayer.PlayerScripts:FindFirstChild("StealPromptSight"))
        if sightScript and sightScript:IsA("LocalScript") and sightScript.Disabled == enabled then
            sightScript.Disabled = not enabled
        end
    end
    function Steal.normalHold(p)
        return holds[p] or p.HoldDuration
    end
    local function wantHold(p)
        local normal = Steal.normalHold(p)
        if Settings.FastSteal then
            return math.max(normal * Settings.StealTimePct / 100, 0.05)
        end
        return normal
    end
    loop(0.25, function()
        for _, it in Scan.items do
            local p = it.prompt
            if p.Parent then
                if p.MaxActivationDistance > 0 and not reach[p] then
                    reach[p] = p.MaxActivationDistance
                end
                -- the game changed it (a talent, a tool): that's the new normal
                if not holds[p] or (setTo[p] and math.abs(p.HoldDuration - setTo[p]) > 1e-3) then
                    holds[p] = p.HoldDuration
                end
                local want = wantHold(p)
                if math.abs(p.HoldDuration - want) > 1e-3 then
                    p.HoldDuration = want
                end
                setTo[p] = p.HoldDuration
                if Settings.StealThroughWalls and p.MaxActivationDistance <= 0 then
                    p.MaxActivationDistance = reach[p] or 12
                end
            end
        end
        sight(not Settings.StealThroughWalls)
    end)
    table.insert(Cleanups, function()
        for p, h in holds do
            if p.Parent then
                p.HoldDuration = h
            end
        end
        sight(true)
    end)

    -- Which prompts the game is showing: only shown prompts take a hold, and
    -- by default only one prompt per key is shown at a time.
    local shown = setmetatable({}, { __mode = "k" })
    local PromptService = game:GetService("ProximityPromptService")
    bind(PromptService.PromptShown, function(p)
        shown[p] = true
    end)
    bind(PromptService.PromptHidden, function(p)
        shown[p] = nil
    end)
    local seen = remote("LayedEyesUponItem")

    function Steal.full()
        return bagFill() >= Settings.DeliverAt
    end
    -- One steal, the way a player does it: the game shows the prompt, it's
    -- held for its hold time and let go.
    function Steal.take(it)
        local p = it.prompt
        if not (p.Parent and p.Enabled) then
            return false
        end
        local before = bagFill()
        if seen and p:GetAttribute("LayedEyesUpon") == false then
            pcall(seen.FireServer, seen, p)
        end
        local excl, los = p.Exclusivity, p.RequiresLineOfSight
        p.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
        p.RequiresLineOfSight = false
        if p.MaxActivationDistance <= 0 then
            p.MaxActivationDistance = reach[p] or 12
        end
        local fired = false
        local conn = p.Triggered:Connect(function()
            fired = true
        end)
        local t0 = os.clock()
        while not shown[p] and os.clock() - t0 < 0.5 and p.Parent do
            RunService.Heartbeat:Wait()
        end
        local hold = p.HoldDuration
        pcall(p.InputHoldBegin, p)
        local h0 = os.clock()
        while not fired and os.clock() - h0 < hold + 0.1 and p.Parent do
            RunService.Heartbeat:Wait()
        end
        pcall(p.InputHoldEnd, p)
        if not fired and p.Parent and typeof(fireproximityprompt) == "function" then
            -- The prompt never took the hold (the game didn't show it).
            pcall(fireproximityprompt, p)
        end
        local ok = false
        local w0 = os.clock()
        while alive() and os.clock() - w0 < 1.5 do
            if not p.Parent or not p.Enabled or bagFill() > before then
                ok = true
                break
            end
            task.wait(0.05)
        end
        conn:Disconnect()
        if p.Parent then
            p.Exclusivity, p.RequiresLineOfSight = excl, los
        end
        if ok then
            Steal.stolen += 1
            Steal.last = "took " .. it.name
        elseif fired then
            Steal.last = it.name .. " wasn't given (steal time too short?)"
        else
            Steal.last = "couldn't hold " .. it.name
        end
        return ok
    end

    -- Hand the bag in at the van.
    function Steal.deliver(back)
        local truck = mapChild("CollectTruck")
        local pad = truck and truck:FindFirstChild("TouchPart")
        if not pad then
            Steal.info = "no van on this map"
            return false
        end
        if bagFill() <= 0.05 then
            return true
        end
        local done = false
        Move.trip("handing in the bag", function()
            local root = myRoot()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = pad.CFrame + Vector3.new(0, 2.5, 0)
            local t0 = os.clock()
            while alive() and os.clock() - t0 < 3 do
                if typeof(firetouchinterest) == "function" then
                    pcall(firetouchinterest, root, pad, 0)
                    task.wait()
                    pcall(firetouchinterest, root, pad, 1)
                end
                if bagFill() <= 0.05 then
                    done = true
                    break
                end
                local r = myRoot()
                if r then
                    r.CFrame = pad.CFrame + Vector3.new(0, 2.5, 0)
                end
                task.wait(0.15)
            end
        end, back)
        if done then
            Steal.delivered += 1
        end
        return done
    end

    -- Steal aura: whatever's in reach, best first.
    local working = false
    loop(0.12, function()
        if not Settings.StealAura or working or Busy.reason or busyMinigame() then
            if not Settings.StealAura then
                Steal.info = "off"
            end
            return
        end
        if Steal.full() then
            Steal.info = "bag full"
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        local best, bestWorth
        for _, it in Scan.items do
            local p = it.prompt
            if p.Parent and p.Enabled and it.worth >= Settings.StealMinWorth then
                local pos = promptPos(p)
                local range = math.min(Settings.StealRange, (reach[p] or p.MaxActivationDistance or 12))
                if pos and (pos - root.Position).Magnitude <= range and (not Tried[p] or os.clock() - Tried[p] > 2) then
                    if not bestWorth or it.worth > bestWorth then
                        best, bestWorth = it, it.worth
                    end
                end
            end
        end
        if best then
            working = true
            Tried[best.prompt] = os.clock()
            Steal.info = "taking " .. best.name
            local ok, err = pcall(Steal.take, best)
            working = false
            if not ok then
                warn("[ROB IT] steal: " .. tostring(err))
            end
        else
            Steal.info = "nothing in reach"
        end
    end)

    -- Auto deliver when the bag is full.
    loop(0.5, function()
        if Settings.AutoDeliver and Steal.full() and not Busy.reason and not busyMinigame() then
            Steal.deliver(Settings.DeliverReturn)
        end
    end)

    -- Steal everything: item to item, handing the bag in whenever it fills.
    Steal.token = 0
    function Steal.stop()
        Steal.token += 1
        Steal.runInfo = "stopped"
    end
    function Steal.all()
        Steal.token += 1
        local token = Steal.token
        local function still()
            return alive() and Steal.token == token
        end
        local root = myRoot()
        local start = root and root.CFrame
        local skip = {}
        local taken = 0
        while still() do
            if Steal.full() then
                Steal.runInfo = "bag full: handing it in"
                Steal.deliver(false)
            end
            local r = myRoot()
            if not r then
                break
            end
            local list = {}
            for _, it in Scan.items do
                local p = it.prompt
                if p.Parent and p.Enabled and not skip[p] and it.worth >= Settings.StealMinWorth then
                    local pos = promptPos(p)
                    if pos and not (Settings.SkipGuarded and Scan.guardNear(pos, Settings.GuardRadius)) then
                        it.d = (pos - r.Position).Magnitude
                        table.insert(list, it)
                    end
                end
            end
            if #list == 0 then
                break
            end
            table.sort(list, function(a, b)
                if Settings.StealOrder == "Nearest first" then
                    return a.d < b.d
                end
                return a.worth > b.worth
            end)
            local it = list[1]
            skip[it.prompt] = true
            Steal.runInfo = ("going to %s ($%s)"):format(it.name, comma(it.worth))
            Busy.reason = "stealing"
            Move.near(it.model, 2.5)
            task.wait(0.25)
            Busy.reason = nil
            if not still() then
                break
            end
            if Steal.take(it) then
                taken += 1
            end
        end
        if still() then
            if bagFill() > 0.05 then
                Steal.runInfo = "handing in the last bag"
                Steal.deliver(false)
            end
            if Settings.StealAllReturn and start then
                local r = myRoot()
                if r then
                    r.CFrame = start
                end
            end
            Steal.runInfo = ("done: %d item%s"):format(taken, taken == 1 and "" or "s")
            notify("Steal all done: " .. taken .. " items", 4)
        end
    end
end

--// Stealth \\--
local Stealth = { info = "", noticed = 0 }
do
    -- Silent movement: the server only hears "Crouching" while you move.
    local anim = remote("AnimationStateChanged")
    if anim and typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        local isOurs = typeof(checkcaller) == "function" and checkcaller or function()
            return false
        end
        local wrap = typeof(newcclosure) == "function" and newcclosure or function(f)
            return f
        end
        local old
        old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
            if self == anim and Settings.Silent and not Unloaded and not isOurs() and getnamecallmethod() == "FireServer" then
                local state = ...
                if state == "Sprinting" or state == "Walking" then
                    return old(self, "Crouching")
                end
            end
            return old(self, ...)
        end))
        Stealth.hooked = true
    end
    function Stealth.setSilent(on)
        if on and anim then
            pcall(anim.FireServer, anim, "Crouching")
        end
    end

    -- Speed and anti stun: the game sets WalkSpeed on every state change and
    -- zeroes it while you're tased, cuffed or frozen.
    local function stunned()
        local now = Workspace:GetServerTimeNow()
        return LocalPlayer:GetAttribute("CvRFrozen") == true or (LocalPlayer:GetAttribute("TasedUntil") or 0) > now
            or LocalPlayer:GetAttribute("CvREscortedBy") ~= nil or (LocalPlayer:GetAttribute("CvRCuffedUntil") or 0) > now
    end
    Stealth.stunned = stunned
    local normalJump
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local hum = myHum()
        if not hum then
            return
        end
        local held = stunned()
        if not held and hum.JumpPower > 0 then
            normalJump = hum.JumpPower
        end
        if held and Settings.AntiStun then
            hum.WalkSpeed = Settings.SpeedOn and Settings.WalkSpeed or 14
            if normalJump and hum.JumpPower == 0 then
                hum.JumpPower = normalJump
            end
        elseif Settings.SpeedOn and not held and hum.WalkSpeed ~= Settings.WalkSpeed then
            hum.WalkSpeed = Settings.WalkSpeed
        end
    end)

    -- A guard has started noticing you.
    local noticing = remote("NPCRemotes.NPCStartedNoticing")
    local flash = Instance.new("Highlight")
    flash.FillColor = Color3.fromRGB(255, 40, 40)
    flash.OutlineColor = Color3.fromRGB(255, 255, 255)
    flash.FillTransparency = 0.4
    flash.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    flash.Enabled = false
    flash.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        flash:Destroy()
    end)
    if noticing then
        bind(noticing.OnClientEvent, function(npc)
            Stealth.noticed += 1
            if not Settings.GuardAlert then
                return
            end
            if typeof(npc) == "Instance" then
                flash.Adornee = npc
                flash.Enabled = true
                task.delay(3, function()
                    if flash.Adornee == npc then
                        flash.Enabled = false
                    end
                end)
            end
            if tryOnce("notice", 2) then
                notify("A guard is noticing you!", 2)
            end
        end)
    end

    -- Cameras and noisy floors: touches are worked out on your side, so with
    -- touching off those parts never report you.
    local touchOff = setmetatable({}, { __mode = "k" })
    local function setTouch(part, off)
        if off then
            if part.CanTouch then
                touchOff[part] = true
                part.CanTouch = false
            end
        elseif touchOff[part] then
            part.CanTouch = true
            touchOff[part] = nil
        end
    end
    loop(1.5, function()
        for _, cam in Scan.cameras do
            for _, d in cam:GetDescendants() do
                if d:IsA("BasePart") and d.Name == "TouchPart" then
                    setTouch(d, Settings.CamerasBlind)
                end
            end
        end
        local noise = mapChild("NoiseAreas")
        if noise then
            for _, d in noise:GetDescendants() do
                if d:IsA("BasePart") then
                    setTouch(d, Settings.NoNoiseAreas)
                end
            end
        end
    end)
    table.insert(Cleanups, function()
        for part in touchOff do
            if part.Parent then
                part.CanTouch = true
            end
        end
    end)
end

--// Minigames \\--
local Games = { won = 0, info = "" }
do
    local function playerGui()
        return LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end
    -- Auto win: let the minigame open, then finish it the game's own way.
    local event = remote("MinigameEvent")
    if event then
        bind(event.OnClientEvent, function(kind, name)
            if kind ~= "Start" or not Settings.AutoMinigames then
                return
            end
            task.delay(Settings.MinigameDelay, function()
                if not (alive() and Settings.AutoMinigames) then
                    return
                end
                local pg = playerGui()
                local folder = pg and pg:FindFirstChild("MainFrame") and pg.MainFrame:FindFirstChild("Minigames")
                folder = folder and folder:FindFirstChild("Minigames")
                local module = folder and folder:FindFirstChild(tostring(name))
                local ok, mod = false, nil
                if module then
                    ok, mod = pcall(require, module)
                end
                if ok and type(mod) == "table" and type(mod.EndGame) == "function" then
                    if busyMinigame() then
                        pcall(mod.EndGame, true)
                    end
                else
                    event:FireServer("Finished", true)
                end
                Games.won += 1
                Games.info = "won " .. tostring(name)
            end)
        end)
    end

    -- Answer an event ourselves and keep the game's own handler out of it.
    local function takeOver(signal, settingKey, answer)
        local ours = function(...)
            if Settings[settingKey] and alive() then
                answer(...)
            end
        end
        bind(signal, ours)
        if typeof(getconnections) ~= "function" then
            return
        end
        local paused = {}
        loop(0.5, function()
            for _, c in getconnections(signal) do
                if c.Function ~= ours then
                    if Settings[settingKey] and not paused[c] then
                        if pcall(c.Disable, c) then
                            paused[c] = true
                        end
                    elseif not Settings[settingKey] and paused[c] then
                        pcall(c.Enable, c)
                        paused[c] = nil
                    end
                end
            end
        end)
        table.insert(Cleanups, function()
            for c in paused do
                pcall(c.Enable, c)
            end
        end)
    end
    local lockpick = remote("Utilities.LockpickMinigame")
    if lockpick then
        takeOver(lockpick.OnClientEvent, "InstantLockpick", function(door)
            task.wait(math.min(Settings.MinigameDelay, 0.4))
            lockpick:FireServer(door, true)
            Games.won += 1
            Games.info = "picked a lock"
        end)
    end
    local powerBox = remote("Utilities.HackPowerBox")
    if powerBox then
        takeOver(powerBox.OnClientEvent, "InstantPowerBox", function(start)
            if start then
                task.wait(Settings.MinigameDelay)
                powerBox:FireServer(true)
                Games.won += 1
                Games.info = "hacked a power box"
            end
        end)
    end

    -- ATM and safe: the server asks you to play and waits for true.
    local function takeInvoke(rf, settingKey, label)
        if not rf then
            return
        end
        local original = typeof(getcallbackvalue) == "function" and (select(2, pcall(getcallbackvalue, rf, "OnClientInvoke"))) or nil
        if type(original) ~= "function" then
            original = nil
        end
        local installed = false
        local function install()
            if installed then
                return
            end
            installed = true
            rf.OnClientInvoke = function(...)
                if Settings[settingKey] and alive() then
                    task.wait(Settings.MinigameDelay)
                    Games.won += 1
                    Games.info = label
                    return true
                end
                if original then
                    return original(...)
                end
                return false
            end
        end
        if original then
            install()
            table.insert(Cleanups, function()
                rf.OnClientInvoke = original
            end)
        else
            -- Can't read the game's own answer: only take over once asked to.
            loop(0.5, function()
                if Settings[settingKey] then
                    install()
                end
            end)
        end
    end
    takeInvoke(remote("Utilities.StartATMGame"), "InstantATM", "cracked an ATM")
    takeInvoke(remote("Utilities.StartSaveMinigame"), "InstantSafe", "cracked a safe")
end

--// Doors and crowbar \\--
local Doors = { opened = 0, hits = 0 }
do
    local function doorPrompts()
        local out = {}
        local doors = mapChild("Doors")
        if doors then
            for _, d in doors:GetDescendants() do
                if d:IsA("ProximityPrompt") then
                    table.insert(out, d)
                end
            end
        end
        return out
    end
    local function tool(name)
        local c = myChar()
        local held = c and c:FindFirstChild(name)
        if held and held:IsA("Tool") then
            return held, true
        end
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        local t = bp and bp:FindFirstChild(name)
        return t, false
    end
    loop(0.4, function()
        local root = myRoot()
        if not root or busyMinigame() then
            return
        end
        if Settings.AutoOpenDoors or Settings.AutoLockpickDoors then
            for _, p in doorPrompts() do
                local pos = p.Enabled and promptPos(p)
                if pos and (pos - root.Position).Magnitude <= Settings.DoorRange then
                    if Settings.AutoOpenDoors and p.ActionText == "Open" and tryOnce(p, 3) then
                        firePrompt(p)
                        Doors.opened += 1
                    elseif Settings.AutoLockpickDoors and p.ActionText == "Locked" and tryOnce(p, 5) then
                        local pick, inHand = tool("Lockpick")
                        local hum = myHum()
                        if pick and hum then
                            if not inHand then
                                hum:EquipTool(pick)
                                task.wait(0.2)
                            end
                            firePrompt(p)
                        end
                    end
                end
            end
        end
    end)

    -- Crowbar aura: the hits the crowbar's swing sends, for everything in reach.
    local hitNpc, breakDoor = remote("Tools.HitNPC"), remote("Utilities.BreakDoor")
    local breakWindow, hitCashier = remote("Utilities.BreakWindow"), remote("Utilities.HitCashier")
    loop(0.35, function()
        if not Settings.CrowbarAura then
            return
        end
        local root, hum = myRoot(), myHum()
        if not (root and hum) then
            return
        end
        local bar, inHand = tool("Crowbar")
        if not bar then
            return
        end
        if not inHand then
            if not Settings.CrowbarEquip then
                return
            end
            hum:EquipTool(bar)
            task.wait(0.15)
        end
        local range = Settings.CrowbarRange
        local function close(inst)
            local pos = pivotOf(inst)
            return pos and (pos - root.Position).Magnitude <= range
        end
        if Settings.CrowbarGuards and hitNpc then
            for _, g in Scan.guards do
                if not Scan.knocked(g) and close(g) and tryOnce(g, 1.2) then
                    hitNpc:FireServer(g, "Crowbar")
                    Doors.hits += 1
                end
            end
        end
        if Settings.CrowbarDoors and breakDoor then
            local doors = mapChild("Doors")
            if doors then
                for _, door in doors:GetChildren() do
                    if door:IsA("Model") and close(door) and tryOnce(door, 2) then
                        local locked = false
                        for _, d in door:GetDescendants() do
                            if d:IsA("ProximityPrompt") and d.ActionText == "Locked" then
                                locked = true
                                break
                            end
                        end
                        if locked then
                            breakDoor:FireServer(door)
                            Doors.hits += 1
                        end
                    end
                end
            end
        end
        if Settings.CrowbarGlass and breakWindow then
            for _, glass in CollectionService:GetTagged("BreakableGlass") do
                if glass:IsDescendantOf(Workspace) and close(glass) and tryOnce(glass, 2) then
                    breakWindow:FireServer(glass)
                    Doors.hits += 1
                end
            end
        end
        if Settings.CrowbarCashiers and hitCashier then
            for _, c in CollectionService:GetTagged("Cashiers") do
                if c:IsDescendantOf(Workspace) and close(c) and tryOnce(c, 1.5) then
                    hitCashier:FireServer(c, "Crowbar")
                    Doors.hits += 1
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
        bb.Size = UDim2.fromOffset(200, 34)
        bb.StudsOffset = Vector3.new(0, 2.5, 0)
        bb.MaxDistance = math.huge
        bb.Adornee = part
        bb.Parent = folder
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 12
        label.TextStrokeTransparency = 0.35
        label.TextColor3 = color
        label.Text = text
        label.Parent = bb
        local hl
        if highlight then
            hl = Instance.new("Highlight")
            hl.Adornee = adornee
            hl.FillColor, hl.OutlineColor = color, color
            hl.FillTransparency = 0.7
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
        if Settings.ItemEsp then
            for _, it in Scan.items do
                local pos = promptPos(it.prompt)
                local d = dist(pos)
                if it.prompt.Parent and it.worth >= Settings.ItemMinWorth and d <= Settings.EspDistance then
                    local r = RARITY[it.rarity] or RARITY[1]
                    local color = it.mutation and Scan.mutationColor(it.mutation) or (it.diamond and Color3.fromRGB(80, 255, 255)) or r[2]
                    local text = it.diamond and ("%s [%dm]"):format(it.name, d)
                        or ("%s%s $%s\n%s [%dm]"):format(it.mutation and (it.mutation .. " ") or "", it.name, comma(it.worth), r[1], d)
                    if not it.prompt.Enabled then
                        text ..= " (locked)"
                    end
                    mark(it.prompt, it.model, color, text, false)
                end
            end
        end
        if Settings.GuardEsp then
            for _, g in Scan.guards do
                local pos = pivotOf(g)
                if dist(pos) <= Settings.EspDistance then
                    local chasing = (g:GetAttribute("IsChasing") or "") ~= ""
                    local knocked = Scan.knocked(g)
                    local color = knocked and Color3.fromRGB(150, 150, 150) or chasing and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 170, 60)
                    local state = knocked and "down" or chasing and "CHASING" or "guard"
                    mark(g, g, color, ("%s [%dm]"):format(state, dist(pos)), true)
                end
            end
        end
        if Settings.CameraEsp then
            for _, c in Scan.cameras do
                local pos = pivotOf(c)
                if dist(pos) <= Settings.EspDistance then
                    local on = c:GetAttribute("Enabled") ~= false
                    local alarm = c:GetAttribute("Alarm") == true
                    local color = alarm and Color3.fromRGB(255, 40, 40) or on and Color3.fromRGB(255, 230, 90) or Color3.fromRGB(140, 140, 140)
                    mark(c, c, color, ("Camera%s [%dm]"):format(alarm and " ALARM" or on and "" or " off", dist(pos)), true)
                end
            end
        end
        if Settings.VanEsp then
            local truck = mapChild("CollectTruck")
            local pad = truck and truck:FindFirstChild("TouchPart")
            if pad then
                mark(pad, pad, Color3.fromRGB(90, 255, 120), ("Hand in [%dm]"):format(dist(pad.Position)), false)
            end
            local van = mapChild("Truck") or mapChild("Boat")
            if van then
                mark(van, van, Color3.fromRGB(120, 200, 255), ("Getaway [%dm]"):format(dist(pivotOf(van))), false)
            end
        end
        if Settings.PlayerEsp then
            for _, plr in Players:GetPlayers() do
                local c = plr ~= LocalPlayer and plr.Character
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local team = plr:GetAttribute("CvRTeam")
                    local color = team == "Police" and Color3.fromRGB(80, 140, 255) or Color3.fromRGB(240, 240, 240)
                    mark(plr, c, color, ("%s%s [%dm]"):format(plr.DisplayName, team and (" (" .. team .. ")") or "", dist(hrp.Position)), false)
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

    -- Guard vision cones: DetectRange ahead, DetectSpread to each side, and
    -- the BackDetection ring behind them.
    if typeof(Drawing) == "table" or typeof(Drawing) == "userdata" then
        local pools = {}
        local function lines(key, n)
            local pool = pools[key]
            if not pool then
                pool = {}
                pools[key] = pool
            end
            for i = #pool + 1, n do
                local ok, l = pcall(Drawing.new, "Line")
                if not ok then
                    break
                end
                l.Thickness = 1.5
                l.Visible = false
                pool[i] = l
            end
            return pool
        end
        local function hide(pool)
            for _, l in pool do
                l.Visible = false
            end
        end
        local RING = 10
        bind(RunService.RenderStepped, function()
            local cam = Workspace.CurrentCamera
            local show = alive() and Settings.GuardEsp and Settings.GuardCones and cam
            local live = {}
            if show then
                local root = myRoot()
                for _, g in Scan.guards do
                    local hrp = g:FindFirstChild("HumanoidRootPart")
                    if hrp and not Scan.knocked(g) and (not root or (hrp.Position - root.Position).Magnitude <= Settings.EspDistance) then
                        live[g] = true
                        local pool = lines(g, 3 + RING)
                        local cf = hrp.CFrame
                        local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
                        fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, -1)
                        local right = Vector3.new(-fwd.Z, 0, fwd.X)
                        local range = tonumber(g:GetAttribute("DetectRange")) or 30
                        local spread = tonumber(g:GetAttribute("DetectSpread")) or 12
                        local back = tonumber(g:GetAttribute("BackDetection")) or 10
                        local o = hrp.Position - Vector3.new(0, 2.5, 0)
                        local fl = o + fwd * range - right * spread
                        local fr = o + fwd * range + right * spread
                        local chasing = (g:GetAttribute("IsChasing") or "") ~= ""
                        local color = chasing and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 200, 60)
                        local segs = { { o, fl }, { o, fr }, { fl, fr } }
                        for i = 0, RING - 1 do
                            local a1, a2 = i / RING * math.pi * 2, (i + 1) / RING * math.pi * 2
                            table.insert(segs, {
                                o + Vector3.new(math.cos(a1) * back, 0, math.sin(a1) * back),
                                o + Vector3.new(math.cos(a2) * back, 0, math.sin(a2) * back),
                            })
                        end
                        for i, s in segs do
                            local l = pool[i]
                            if l then
                                local a, va = cam:WorldToViewportPoint(s[1])
                                local b, vb = cam:WorldToViewportPoint(s[2])
                                if a.Z > 0 and b.Z > 0 and (va or vb) then
                                    l.From = Vector2.new(a.X, a.Y)
                                    l.To = Vector2.new(b.X, b.Y)
                                    l.Color = color
                                    l.Visible = true
                                else
                                    l.Visible = false
                                end
                            end
                        end
                    end
                end
            end
            for key, pool in pools do
                if not live[key] then
                    hide(pool)
                    if not (typeof(key) == "Instance" and key.Parent) then
                        for _, l in pool do
                            pcall(l.Remove, l)
                        end
                        pools[key] = nil
                    end
                end
            end
        end)
        table.insert(Cleanups, function()
            for _, pool in pools do
                for _, l in pool do
                    pcall(l.Remove, l)
                end
            end
        end)
    end
end

--// World: light, escape, rounds \\--
local World = { info = "", escaped = false }
do
    local saved, fog
    local function save()
        saved = {
            Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
            GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
        }
        fog = {}
    end
    local function restore()
        for k, v in saved do
            pcall(function()
                Lighting[k] = v
            end)
        end
        for e, d in fog do
            if e.Parent then
                e.Density = d
            end
        end
        saved, fog = nil, nil
    end
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        if Settings.Fullbright then
            if not saved then
                save()
            end
            Lighting.Brightness = 2
            Lighting.ClockTime = 14
            Lighting.FogEnd = 1e6
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(180, 180, 180)
            Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
            for _, e in Lighting:GetChildren() do
                if e:IsA("Atmosphere") and e.Density > 0 then
                    fog[e] = fog[e] or e.Density
                    e.Density = 0
                end
            end
        elseif saved then
            restore()
        end
    end)
    table.insert(Cleanups, function()
        if saved then
            restore()
        end
    end)

    -- Get in the getaway van before it leaves.
    function World.freeSeat()
        local van = mapChild("Truck") or mapChild("Boat")
        if not van then
            return nil
        end
        for _, d in van:GetDescendants() do
            if (d:IsA("Seat") or d:IsA("VehicleSeat")) and not d.Occupant then
                return d
            end
        end
        return nil
    end
    function World.escape()
        local hum, root = myHum(), myRoot()
        if not (hum and root) then
            return false
        end
        if hum.SeatPart then
            return true
        end
        if bagFill() > 0.05 then
            Steal.deliver(false)
        end
        local seat = World.freeSeat()
        if not seat then
            notify("No free seat in the getaway")
            return false
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.CFrame = seat.CFrame + Vector3.new(0, 2.5, 0)
        task.wait(0.15)
        pcall(seat.Sit, seat, hum)
        return true
    end
    loop(1, function()
        local m = map()
        local t = m and tonumber(m:GetAttribute("Time"))
        if not t then
            return
        end
        if t > Settings.EscapeAt + 5 then
            World.escaped = false
        end
        if Settings.AutoEscape and not World.escaped and t <= Settings.EscapeAt and t > 0 and not Busy.reason then
            World.escaped = World.escape()
            if World.escaped then
                notify("In the getaway van", 3)
            end
        end
    end)

    -- Play again at the end of a round.
    local finished, again = remote("FinishedStats"), remote("PlayAgain")
    if finished and again then
        bind(finished.OnClientEvent, function()
            if not Settings.AutoReplay then
                return
            end
            task.delay(Settings.ReplayDelay, function()
                if alive() and Settings.AutoReplay then
                    again:FireServer(Settings.ReplayMode == "Next map" and "Next" or "Replay")
                end
            end)
        end)
    end

    -- Anti-AFK
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

    function World.dashboard()
        local m = map()
        if not m then
            return "No heist loaded"
        end
        local t = math.max(0, math.floor(tonumber(m:GetAttribute("Time")) or 0))
        local truck = mapChild("CollectTruck")
        local pad = truck and truck:FindFirstChild("TouchPart")
        local alert = "calm"
        local chasing = Workspace:FindFirstChild("Chasing")
        if chasing then
            for _, name in { "Police", "Chase", "Investigate" } do
                local v = chasing:FindFirstChild(name)
                if v and tonumber(v.Value) and v.Value > 0 then
                    alert = name == "Investigate" and "investigating" or name == "Chase" and "CHASE" or "POLICE"
                    break
                end
            end
        end
        local sus = m:FindFirstChild("SuspiciousAmount")
        return table.concat({
            ("%s · %s · next %s"):format(tostring(m:GetAttribute("MapName") or "?"), tostring(m:GetAttribute("Difficulty") or "?"),
                tostring(m:GetAttribute("NextMap") or "-")),
            ("Van leaves in %02d:%02d%s"):format(t // 60, t % 60, m:GetAttribute("Blackout") and " · blackout" or ""),
            ("Stolen $%s · in bags $%s · handed in $%s"):format(comma(m:GetAttribute("TotalWorthStolen")),
                comma(m:GetAttribute("TotalWorthInBags")), comma(m:GetAttribute("TotalWorthDelivered"))),
            pad and ("Van: %d / %d items · gems %d / %d"):format(tonumber(pad:GetAttribute("StolenAmount")) or 0,
                tonumber(pad:GetAttribute("RequiredStolen")) or 0, tonumber(pad:GetAttribute("StolenAmountDiamonds")) or 0,
                tonumber(pad:GetAttribute("RequiredStolenDiamonds")) or 0) or "Van: -",
            ("Loot budget $%s · items left %d"):format(comma(m:GetAttribute("LootBudget")), #Scan.items),
            ("Alert: %s · suspicion %s"):format(alert, sus and tostring(math.floor((tonumber(sus.Value) or 0) * 10) / 10) or "-"),
            ("Your bag: %d%% · %d items"):format(math.floor(bagFill() * 10), tonumber(LocalPlayer:GetAttribute("CurrentStolenItems")) or 0),
        }, "\n")
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "ROB IT",
    Footer = "dookie hub · Ui3",
    Icon = "gem",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/RobIt",
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
            task.wait(0.4)
        end
    end)
end

do
    local Tab = Window:AddTab("Steal", "gem", "Stealing and handing in")
    local S = Tab:AddLeftGroupbox("Stealing", "hand")
    toggle(S, "FastSteal", "Faster steal", "Steals take the share of their normal time set below")
    slider(S, "StealTimePct", "Steal time", 5, 100, 0, "% of normal",
        "Lower is faster. If steals stop counting, the server wants more time: raise it")
    toggle(S, "StealAura", "Steal aura", "Takes the best item in reach as you walk around")
    slider(S, "StealRange", "Reach", 4, 12, 0, " studs", "The game's own reach is 12")
    slider(S, "StealMinWorth", "Only items worth at least", 0, 50000, 0, " $")
    toggle(S, "StealThroughWalls", "Steal through walls", "Items stay in reach when a wall is in the way (the game only blocks this on your side)")
    status(S, function()
        return ("Aura: %s\nLast: %s\nStolen: %d"):format(Steal.info, Steal.last or "-", Steal.stolen)
    end)
    local D = Tab:AddRightGroupbox("Hand in", "truck")
    toggle(D, "AutoDeliver", "Auto hand in", "Takes a full bag to the van and comes back")
    slider(D, "DeliverAt", "When the bag is at", 1, 9.9, 1, " / 10")
    toggle(D, "DeliverReturn", "Come back after")
    D:AddButton({ Text = "Hand in now", Func = function()
        task.spawn(Steal.deliver, Settings.DeliverReturn)
    end })
    status(D, function()
        return ("Bag: %d%%\nHanded in: %d times"):format(math.floor(bagFill() * 10), Steal.delivered)
    end)
    local A = Tab:AddRightGroupbox("Steal everything", "zap")
    dropdown(A, "StealOrder", "Order", { "Best worth first", "Nearest first" })
    toggle(A, "SkipGuarded", "Skip items near guards", "Leaves items with an awake guard close by")
    slider(A, "GuardRadius", "Guard distance", 5, 60, 0, " studs")
    toggle(A, "StealAllReturn", "Come back when done")
    A:AddButton({ Text = "Steal everything", Func = function()
        task.spawn(Steal.all)
    end, Tooltip = "Goes item to item, hands the bag in when it fills, and hands in the last one at the end" })
    A:AddButton({ Text = "Stop", Func = Steal.stop })
    status(A, function()
        return Steal.runInfo ~= "" and Steal.runInfo or "-"
    end)
end

do
    local Tab = Window:AddTab("Stealth", "eye-off", "Noise, speed, guards")
    local N = Tab:AddLeftGroupbox("Moving", "footprints")
    toggle(N, "Silent", "Silent movement", "The server is only ever told you're crouching, so sprinting is as quiet as sneaking", Stealth.setSilent)
    toggle(N, "SpeedOn", "Speed")
    slider(N, "WalkSpeed", "Speed", 6, 80, 0, "", "Walk 14, crouch 6, sprint 22")
    toggle(N, "AntiStun", "Anti stun", "Keep moving while tased, cuffed or frozen (Cops vs Robbers)")
    status(N, function()
        return Stealth.hooked and ("Stunned: %s"):format(Stealth.stunned() and "yes" or "no")
            or "Your executor can't hook, so silent movement is off"
    end)
    local G = Tab:AddRightGroupbox("Guards and cameras", "shield")
    toggle(G, "GuardAlert", "Warn me when a guard notices me", "The guard flashes red and you get a message")
    toggle(G, "CamerasBlind", "Cameras don't see me", "Camera trigger zones stop touching you (touches are worked out on your side)")
    toggle(G, "NoNoiseAreas", "No noisy floors", "Noise areas stop touching you")
    status(G, function()
        return ("Guards noticed you %d times"):format(Stealth.noticed)
    end)
end

do
    local Tab = Window:AddTab("Minigames", "puzzle", "Locks, ATMs, safes, power")
    local M = Tab:AddLeftGroupbox("Minigames", "puzzle")
    toggle(M, "AutoMinigames", "Auto win minigames", "Lockpick, circle, hold bar, pincode, power, power cut and swipe card finish as a win")
    slider(M, "MinigameDelay", "Finish after", 0, 3, 1, " s", "A short wait looks more normal")
    toggle(M, "InstantLockpick", "Instant lockpick", "The lockpick tool's minigame is answered as a pick straight away")
    toggle(M, "InstantATM", "Instant ATM")
    toggle(M, "InstantSafe", "Instant safe")
    toggle(M, "InstantPowerBox", "Instant power box")
    status(M, function()
        return ("Won: %d%s"):format(Games.won, Games.info ~= "" and ("\nLast: " .. Games.info) or "")
    end)
    local Dr = Tab:AddRightGroupbox("Doors", "door-open")
    toggle(Dr, "AutoOpenDoors", "Auto open doors", "Opens doors and vents next to you")
    toggle(Dr, "AutoLockpickDoors", "Auto lockpick doors", "Uses your lockpick on locked doors next to you (pair with instant lockpick)")
    slider(Dr, "DoorRange", "Door reach", 4, 10, 0, " studs")
    local C = Tab:AddRightGroupbox("Crowbar", "hammer")
    toggle(C, "CrowbarAura", "Crowbar aura", "While you hold the crowbar, it hits everything picked below in reach")
    toggle(C, "CrowbarEquip", "Take the crowbar out by itself")
    slider(C, "CrowbarRange", "Reach", 4, 15, 0, " studs")
    toggle(C, "CrowbarGuards", "Knock out guards")
    toggle(C, "CrowbarDoors", "Break locked doors")
    toggle(C, "CrowbarGlass", "Break glass")
    toggle(C, "CrowbarCashiers", "Hit cashiers")
    status(C, function()
        return ("Doors opened: %d · crowbar hits: %d"):format(Doors.opened, Doors.hits)
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Items, guards, cameras, van")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "ItemEsp", "Items", "Name, worth, rarity and mutation. Gems in cyan, mutated items in their mutation's color")
    slider(E, "ItemMinWorth", "Items worth at least", 0, 50000, 0, " $")
    toggle(E, "GuardEsp", "Guards", "Orange, red when chasing, grey when knocked out")
    toggle(E, "GuardCones", "Guard vision cones", "What each guard can see: its detect range ahead, spread to the sides and the ring behind it")
    toggle(E, "CameraEsp", "Cameras", "Yellow, red when alarmed, grey when off")
    toggle(E, "VanEsp", "Van and getaway")
    toggle(E, "PlayerEsp", "Players", "Police in blue in Cops vs Robbers")
    slider(E, "EspDistance", "Max distance", 50, 2000, 0, " studs")
end

do
    local Tab = Window:AddTab("Heist", "map", "Dashboard, teleports, rounds")
    local H = Tab:AddLeftGroupbox("Dashboard", "layout-dashboard")
    status(H, World.dashboard)
    local T = Tab:AddRightGroupbox("Teleport", "map-pin")
    T:AddButton({ Text = "Van (hand in spot)", Func = function()
        local truck = mapChild("CollectTruck")
        local pad = truck and truck:FindFirstChild("TouchPart")
        if pad then
            Move.to(pad.Position + Vector3.new(0, 3, 0))
        end
    end })
    T:AddButton({ Text = "Getaway seat", Func = function()
        task.spawn(World.escape)
    end })
    T:AddButton({ Text = "Spawn", Func = function()
        local s = mapChild("SpawnLocation")
        if s then
            Move.to(s.Position + Vector3.new(0, 4, 0))
        end
    end })
    T:AddButton({ Text = "Best item", Func = function()
        local best
        for _, it in Scan.items do
            if it.prompt.Parent and it.prompt.Enabled and (not best or it.worth > best.worth) then
                best = it
            end
        end
        if best then
            Move.near(best.model, 2.5)
        else
            notify("Nothing left to steal")
        end
    end })
    local R = Tab:AddRightGroupbox("Rounds", "refresh-cw")
    toggle(R, "AutoEscape", "Get in the van by itself", "Hands your bag in, then sits in a free getaway seat before the van leaves")
    slider(R, "EscapeAt", "When the van leaves in", 5, 120, 0, " s")
    toggle(R, "AutoReplay", "Play again by itself")
    dropdown(R, "ReplayMode", "Play", { "Same map", "Next map" }, "Next map needs the next map unlocked")
    slider(R, "ReplayDelay", "Wait first", 1, 30, 0, " s")
    toggle(R, "Fullbright", "Fullbright", "Bright everywhere, blackouts too")
end

do
    local Tab = Window:AddTab("Misc", "settings", "Script")
    local M = Tab:AddLeftGroupbox("Misc", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__RobItUnload then
            Genv.__RobItUnload()
        end
    end })
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    Steal.token += 1
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__RobItUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(map() and ("Loaded on " .. tostring(map():GetAttribute("MapName") or "the map")) or "Loaded (no heist yet)", 4)

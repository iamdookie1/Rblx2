--// Needle in a Haystack (Chapter 1: Farmhouse) ----------------------------------------
-- Built against a script dump of the live game (place 108628039999641, version 1274).
--
-- What the game's own client scripts show:
--  * The pile is drawn on the client: Workspace.HaystackClient holds the strands you
--    can see ("HayPiece" parts with HayId and HayMutation attributes). Only the
--    RenderedHay closest to the surface exist at once; new ones appear as hay is dug.
--  * Picking is ReplicatedStorage.NeedleHaystack.PickHay:FireServer(hayId, extraIds),
--    on your HayPickCooldown attribute, with extraIds being the closest strands
--    inside HayGrabRadius (HayGrabCount - 1 of them). Dropped hay is
--    PickDroppedHay:FireServer(part). Everything is within 20 studs (INTERACT_DISTANCE).
--  * Selling is SellHay:FireServer() while near a part tagged "SellPart" (the hole by
--    the cow). Your bag is the HayHeld / HayCapacity attributes, InfiniteBagOwned
--    lifts the cap. Cash is leaderstats.Cash, gems the Gems attribute.
--  * The needle's strand is picked on the server and only sent once
--    NeedleRevealFraction of the hay is gone (75% normal, 67% hard): NeedleTargetChanged
--    (hayId), and GetHayState returns it as needleHayId. NeedleFound(userId, name, _, id)
--    is someone finding it. Nothing on the client knows where it is before that.
--  * Special hay is worked out on the client from the round's MutationSeed attribute
--    (Config.mutationFor(hayId)): Void x20, Rainbow x10, Electric x8, Gold x6, Burnt x4,
--    Glass x3, Muddy x2, Grassy x1.5, Damp x1.25.
--  * Gems: GemSpawned(id, CFrame), CollectGem:FireServer(id), GemCollected(id, userId).
--  * Tools: DeployDrone:FireServer() (DroneOwned, DroneDeployed), PitchforkDig:FireServer(hayId)
--    on PitchforkCooldown, VacuumAction "Start" / "Tick"(aim, nozzle, ids) / "Stop" with
--    VacuumHeat and VacuumState, TntAction "light" then "throw"(cframe, velocity) after
--    "lit", on TntCooldown.
--  * Upgrades: BuyUpgrade:FireServer(track), level in the HayUpgrade<Track> attribute,
--    cost Config.UPGRADE_TRACKS[track].Levels[next].Cost * UpgradeCostMultiplier.
--    Tools: BuyShopItem:FireServer("Pitchfork" | "Tnt" | "Vacuum" | "Drone").
--  * There is no client anti cheat. Only the save-data code kicks.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__NeedleUnload then
    pcall(Genv.__NeedleUnload)
end
Genv.__NeedleRun = (Genv.__NeedleRun or 0) + 1
local RUN = Genv.__NeedleRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__NeedleRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local ref = "main"
local resolved, shaOrError = pcall(function()
    local commit = HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main"))
    return commit.sha
end)
if resolved and shaOrError then
    ref = shaOrError
else
    warn("[Ui3] could not resolve the latest commit, falling back to main: " .. tostring(shaOrError))
end
local Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
local Options = Library.Options

local S = {
    -- farm
    AutoPick = false, PickReach = 16, PickExtraDelay = 0, MoveToHay = true, PickDropped = true,
    SpecialFirst = true, ChaseSpecial = false, ChaseMinMult = 6,
    AutoSell = false, SellAt = 100, SellInfiniteAt = 500, ReturnAfterSell = true,
    -- tools
    AutoDrone = false, AutoPitchfork = false, AutoVacuum = false, VacuumStopAt = 100,
    AutoTnt = false, TntTarget = "Special hay, else thickest", TntRange = 45,
    -- gems
    AutoGems = false, GemTeleport = true, GemReturn = true,
    -- upgrades
    AutoUpgrade = false, UpgradeTracks = {}, UpgradeOnlyOwned = true, KeepCash = 0,
    AutoBuyTools = false, BuyTools = {},
    -- needle
    NeedleAlert = true, NeedleEsp = true, NeedleBeam = true,
    -- visuals
    SpecialEsp = false, SpecialTypes = {}, SpecialLabels = true, SpecialMax = 60,
    GemEsp = false, DroneEsp = false, SellEsp = false, PlayerEsp = false,
    -- movement
    Speed = false, SpeedValue = 32, SpeedMethod = "WalkSpeed",
    Jump = false, JumpValue = 75, InfJump = false,
    Fly = false, FlySpeed = 60, Noclip = false, AntiAfk = true,
    TpMethod = "Instant", TpSpeed = 150,
    -- misc
    SkipCutscenes = false, AutoLobby = false, LobbyDelay = 8,
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

local function getHui()
    local ok, hui = pcall(function()
        return gethui and gethui()
    end)
    return (ok and hui) or CoreGui
end

local VisualGui = Instance.new("ScreenGui")
VisualGui.Name = "NeedleVisuals"
VisualGui.IgnoreGuiInset = true
VisualGui.ResetOnSpawn = false
VisualGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    if syn and syn.protect_gui then
        syn.protect_gui(VisualGui)
    end
end)
if not pcall(function()
    VisualGui.Parent = getHui()
end) then
    VisualGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
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
local function pivotPos(model)
    if not model or not model.Parent then
        return nil
    end
    if model:IsA("BasePart") then
        return model.Position
    end
    local ok, cf = pcall(model.GetPivot, model)
    return ok and cf.Position or nil
end
local function anyPart(model)
    if model:IsA("BasePart") then
        return model
    end
    return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end
local function clock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end
local function money(n)
    n = tonumber(n) or 0
    local whole = math.floor(n)
    local text = tostring(whole):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return "$" .. text .. string.format(".%02d", math.floor((n - whole) * 100 + 0.5) % 100)
end
local function notify(title, text, time)
    pcall(function()
        Library:Notify({ Title = title, Description = text, Time = time or 4 })
    end)
end

--// The game's pieces \\--
local NH = ReplicatedStorage:WaitForChild("NeedleHaystack", 30)
local Config
pcall(function()
    Config = require(NH:WaitForChild("Config", 10))
end)
local C = {
    PICK_COOLDOWN = Config and Config.PICK_COOLDOWN or 0.55,
    INTERACT_DISTANCE = Config and Config.INTERACT_DISTANCE or 20,
    PILE_CENTER = Config and Config.PILE_CENTER or Vector3.new(-199.18, 2.1, 30.24),
    PILE_RADIUS = Config and Config.PILE_RADIUS or 17,
    PILE_HEIGHT = Config and Config.PILE_HEIGHT or 12,
    REVEAL = Config and Config.NEEDLE_REVEAL_FRACTION or 0.75,
    TOTAL_HAY = Config and Config.TOTAL_HAY or 100000,
    VACUUM_TICK = Config and Config.VACUUM_TICK or 0.16,
    VACUUM_RANGE = Config and Config.VACUUM_RANGE or 11,
    VACUUM_REACH = Config and Config.VACUUM_HARVEST_REACH or 2.85,
    TNT_LIGHT_TIME = Config and Config.TNT_LIGHT_TIME or 0.48,
    TNT_COOLDOWN = Config and Config.TNT_COOLDOWN or 20,
    TNT_MAX_SPEED = Config and Config.TNT_MAX_THROW_SPEED or 78,
    PITCHFORK_COOLDOWN = Config and Config.PITCHFORK_COOLDOWN or 0.85,
    SELL_TAG = Config and Config.SELL_PART_NAME or "SellPart",
}

local function remote(name)
    return NH and NH:FindFirstChild(name)
end
local function fire(name, ...)
    local r = remote(name)
    if r then
        local args = table.pack(...)
        pcall(function()
            r:FireServer(table.unpack(args, 1, args.n))
        end)
        return true
    end
    return false
end

-- Special hay, best first. Colors are for the ESP.
local Special = {
    order = { "Void", "Rainbow", "Electric", "Gold", "Acid", "Burnt", "Glass", "Muddy", "Grassy", "Damp" },
    mult = { Void = 20, Rainbow = 10, Electric = 8, Gold = 6, Acid = 5, Burnt = 4, Glass = 3, Muddy = 2, Grassy = 1.5, Damp = 1.25 },
    color = {
        Void = Color3.fromRGB(150, 70, 255), Rainbow = Color3.fromRGB(255, 120, 220), Electric = Color3.fromRGB(80, 220, 255),
        Gold = Color3.fromRGB(255, 205, 60), Acid = Color3.fromRGB(150, 255, 60), Burnt = Color3.fromRGB(200, 90, 40),
        Glass = Color3.fromRGB(190, 235, 255), Muddy = Color3.fromRGB(130, 90, 50), Grassy = Color3.fromRGB(110, 210, 90),
        Damp = Color3.fromRGB(110, 140, 190),
    },
}
if Config and Config.HAY_MUTATIONS then
    for _, m in Config.HAY_MUTATIONS do
        if m.Name and m.ValueMultiplier then
            Special.mult[m.Name] = m.ValueMultiplier
            if not table.find(Special.order, m.Name) then
                table.insert(Special.order, m.Name)
            end
        end
    end
end
for _, name in Special.order do
    S.SpecialTypes[name] = (Special.mult[name] or 1) >= 3
end
local function multOf(name)
    return Special.mult[name] or 1
end

local function hayFolder()
    return Workspace:FindFirstChild("HaystackClient")
end
local function bag()
    local held = tonumber(LocalPlayer:GetAttribute("HayHeld")) or 0
    local cap = tonumber(LocalPlayer:GetAttribute("HayCapacity")) or 25
    local infinite = LocalPlayer:GetAttribute("InfiniteBagOwned") == true
    return held, cap, infinite
end
local function bagFull()
    local held, cap, infinite = bag()
    return not infinite and held >= cap
end
local function cash()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local c = ls and ls:FindFirstChild("Cash")
    return c and c.Value or 0
end
local function inputLocked()
    return LocalPlayer:GetAttribute("NeedleInputLocked") == true or LocalPlayer:GetAttribute("CutsceneActive") == true
        or LocalPlayer:GetAttribute("NeedleRoundComplete") == true
end

-- Strands near a point, from the game's own client folder.
local HayOverlap = OverlapParams.new()
HayOverlap.FilterType = Enum.RaycastFilterType.Include
HayOverlap.MaxParts = 0
local HayOverlapFolder
local function haysNear(pos, radius)
    local f = hayFolder()
    if not f then
        return {}
    end
    if HayOverlapFolder ~= f then
        HayOverlapFolder = f
        HayOverlap.FilterDescendantsInstances = { f }
    end
    local out = {}
    for _, p in Workspace:GetPartBoundsInRadius(pos, radius, HayOverlap) do
        if p.Parent == f and p:GetAttribute("HayId") then
            out[#out + 1] = p
        end
    end
    return out
end

-- Special strands on screen, kept up to date as the pile is drawn.
local SpecialParts = {}
local WatchedFolder
local function noteHay(p)
    if not p:IsA("BasePart") then
        return
    end
    local m = p:GetAttribute("HayMutation")
    if m and m ~= "Normal" and p:GetAttribute("HayId") then
        SpecialParts[p] = m
    end
end
local function watchHayFolder()
    local f = hayFolder()
    if not f or f == WatchedFolder then
        return
    end
    WatchedFolder = f
    table.clear(SpecialParts)
    for _, p in f:GetChildren() do
        noteHay(p)
    end
    bind(f.ChildAdded, function(p)
        task.defer(noteHay, p)
    end)
    bind(f.ChildRemoved, function(p)
        SpecialParts[p] = nil
    end)
end

local function liveSpecial()
    local list = {}
    for p, m in SpecialParts do
        if p.Parent and p:GetAttribute("HayId") then
            list[#list + 1] = { part = p, name = m, mult = multOf(m) }
        else
            SpecialParts[p] = nil
        end
    end
    table.sort(list, function(a, b)
        return a.mult > b.mult
    end)
    return list
end

--// Round state \\--
local Round = {
    needleId = nil, needleClaimedBy = nil, revealedAt = nil, specialCounts = nil, seedScanned = nil,
    sold = 0, picks = 0, gems = 0, startCash = nil, lastHeld = 0,
}

local Log -- set once the UI exists
local function logEvent(text, color)
    if Log then
        pcall(Log.Log, Log, text, color)
    end
end

-- How many of each special strand the whole round has, from the seed.
local function scanSpecial()
    if not Config or not Config.mutationFor or not NH then
        return
    end
    local seed = NH:GetAttribute("MutationSeed")
    if seed == nil or seed == Round.seedScanned then
        return
    end
    Round.seedScanned = seed
    task.spawn(function()
        local counts = {}
        local total = tonumber(NH:GetAttribute("TotalHay")) or C.TOTAL_HAY
        for id = 1, total do
            local ok, m = pcall(Config.mutationFor, id)
            if ok and m and m ~= "Normal" then
                counts[m] = (counts[m] or 0) + 1
            end
            if id % 4000 == 0 then
                task.wait()
                if not alive() or NH:GetAttribute("MutationSeed") ~= seed then
                    return
                end
            end
        end
        Round.specialCounts = counts
        local parts = {}
        for _, name in Special.order do
            if counts[name] and multOf(name) >= 3 then
                table.insert(parts, string.format("%d %s", counts[name], name))
            end
        end
        if #parts > 0 then
            logEvent("This round has " .. table.concat(parts, ", "), Color3.fromRGB(255, 205, 60))
        end
    end)
end

local function needlePart()
    local id = Round.needleId
    local hidden = Workspace:FindFirstChild("HiddenNeedleClient")
    if hidden then
        for _, d in hidden:GetDescendants() do
            if d:IsA("BasePart") then
                return d
            end
        end
    end
    local server = Workspace:FindFirstChild("NeedleObjectiveServer")
    if server then
        for _, d in server:GetDescendants() do
            if d:IsA("BasePart") and (d:GetAttribute("IsNeedleObjective") or d.Transparency < 1) then
                return d
            end
        end
    end
    if id then
        local f = hayFolder()
        if f then
            for _, p in f:GetChildren() do
                if p:GetAttribute("HayId") == id then
                    return p
                end
            end
        end
    end
    return nil
end

local function onNeedleTarget(id)
    if typeof(id) ~= "number" then
        Round.needleId = nil
        return
    end
    local was = Round.needleId
    Round.needleId = id
    if was ~= id then
        Round.revealedAt = os.clock()
        logEvent("Needle revealed", Color3.fromRGB(255, 90, 90))
        if S.NeedleAlert then
            notify("Needle", "The needle is showing! Follow the beam.", 6)
        end
    end
end

task.spawn(function()
    local r = remote("NeedleTargetChanged")
    if r then
        bind(r.OnClientEvent, onNeedleTarget)
    end
    local found = remote("NeedleFound")
    if found then
        bind(found.OnClientEvent, function(userId, name, _, id)
            if id == Round.needleId or id == nil then
                Round.needleId = nil
            end
            Round.needleClaimedBy = userId == LocalPlayer.UserId and "You" or tostring(name or "Someone")
            logEvent(Round.needleClaimedBy .. " found the needle", Color3.fromRGB(255, 205, 60))
        end)
    end
    local getState = remote("GetHayState")
    if getState then
        local ok, state = pcall(getState.InvokeServer, getState)
        if ok and type(state) == "table" and typeof(state.needleHayId) == "number" then
            Round.needleId = state.needleHayId
            Round.revealedAt = os.clock()
        end
    end
end)

--// Gems \\--
local Gems = {} -- [id] = position
local function gemsFolder()
    return Workspace:FindFirstChild("GemsClient")
end
task.spawn(function()
    local folder = gemsFolder()
    if folder then
        for _, m in folder:GetChildren() do
            local id = tonumber(string.match(m.Name, "^Gem_(%d+)$"))
            local pos = pivotPos(m)
            if id and pos then
                Gems[id] = pos
            end
        end
    end
    local spawned = remote("GemSpawned")
    if spawned then
        bind(spawned.OnClientEvent, function(id, where)
            if typeof(id) ~= "number" then
                return
            end
            local pos = typeof(where) == "CFrame" and where.Position or typeof(where) == "Vector3" and where or nil
            if pos then
                if not Gems[id] then
                    logEvent("A gem showed up", Color3.fromRGB(96, 190, 255))
                end
                Gems[id] = pos
            end
        end)
    end
    local collected = remote("GemCollected")
    if collected then
        bind(collected.OnClientEvent, function(id, userId)
            Gems[id] = nil
            if userId == LocalPlayer.UserId then
                Round.gems += 1
            end
        end)
    end
end)

--// Movement \\--
local Controls
task.spawn(function()
    pcall(function()
        local module = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
        Controls = require(module):GetControls()
    end)
end)

-- Camera-relative move input from keyboard or the mobile thumbstick.
local function moveInput()
    if Controls then
        local ok, v = pcall(Controls.GetMoveVector, Controls)
        if ok and v then
            return v
        end
    end
    local hum = humanoid()
    if hum and hum.MoveDirection.Magnitude > 0 then
        local cf = Camera.CFrame
        local md = hum.MoveDirection
        local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
        flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, -1)
        return Vector3.new(md:Dot(cf.RightVector), 0, -md:Dot(flat))
    end
    return Vector3.zero
end

local FlyUpHeld, FlyDownHeld = false, false
local FlyObjects = {}

local function stopFly()
    for _, obj in FlyObjects do
        pcall(obj.Destroy, obj)
    end
    table.clear(FlyObjects)
    local hum = humanoid()
    if hum then
        pcall(hum.ChangeState, hum, Enum.HumanoidStateType.Freefall)
    end
end

local function flyStep()
    local hrp = rootPart()
    if not hrp then
        return
    end
    local lv = FlyObjects.Velocity
    if not lv or lv.Parent == nil or FlyObjects.Attachment.Parent ~= hrp then
        stopFly()
        local att = Instance.new("Attachment")
        att.Name = "NHFlyAttachment"
        att.Parent = hrp
        lv = Instance.new("LinearVelocity")
        lv.Name = "NHFly"
        lv.Attachment0 = att
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        lv.MaxForce = math.huge
        lv.Parent = hrp
        local align = Instance.new("AlignOrientation")
        align.Name = "NHFlyAlign"
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        align.Attachment0 = att
        align.RigidityEnabled = true
        align.Parent = hrp
        FlyObjects.Attachment, FlyObjects.Velocity, FlyObjects.Align = att, lv, align
    end

    local cf = Camera.CFrame
    local input = moveInput()
    local dir = cf.RightVector * input.X + cf.LookVector * -input.Z
    local hum = humanoid()
    local up = FlyUpHeld or UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E)
    local down = FlyDownHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q)
    if up then
        dir += Vector3.new(0, 1, 0)
    end
    if down then
        dir -= Vector3.new(0, 1, 0)
    end
    if dir.Magnitude > 1 then
        dir = dir.Unit
    end
    lv.VectorVelocity = dir * S.FlySpeed
    local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    if flat.Magnitude > 0.01 then
        FlyObjects.Align.CFrame = CFrame.lookAt(Vector3.zero, flat)
    end
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Physics)
    end
end

-- On-screen up/down buttons for flying on a phone.
local FlyButtons = Instance.new("Frame")
FlyButtons.Name = "FlyButtons"
FlyButtons.BackgroundTransparency = 1
FlyButtons.AnchorPoint = Vector2.new(1, 1)
FlyButtons.Position = UDim2.new(1, -24, 1, -170)
FlyButtons.Size = UDim2.fromOffset(64, 136)
FlyButtons.Visible = false
FlyButtons.Parent = VisualGui

local function flyButton(text, y, onHold)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(64, 64)
    b.Position = UDim2.fromOffset(0, y)
    b.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
    b.BackgroundTransparency = 0.2
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 22
    b.Text = text
    b.AutoButtonColor = true
    b.Parent = FlyButtons
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", b)
    stroke.Color = Color3.fromRGB(255, 205, 60)
    stroke.Transparency = 0.3
    b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            onHold(true)
        end
    end)
    b.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            onHold(false)
        end
    end)
end
flyButton("▲", 0, function(v)
    FlyUpHeld = v
end)
flyButton("▼", 72, function(v)
    FlyDownHeld = v
end)

local Saved = {}
local NoclipParts = {}

local function movementStep(dt)
    local hum = humanoid()
    local hrp = rootPart()
    if not hum or not hrp then
        return
    end
    if S.Speed then
        if S.SpeedMethod == "WalkSpeed" then
            hum.WalkSpeed = S.SpeedValue
        elseif not S.Fly and hum.MoveDirection.Magnitude > 0 then
            local extra = math.max(0, S.SpeedValue - hum.WalkSpeed)
            hrp.CFrame += hum.MoveDirection * extra * dt
        end
    end
    if S.Jump then
        if Saved.UseJumpPower == nil then
            Saved.UseJumpPower, Saved.JumpPower, Saved.JumpHeight = hum.UseJumpPower, hum.JumpPower, hum.JumpHeight
        end
        hum.UseJumpPower = true
        hum.JumpPower = S.JumpValue
    end
    if S.Fly then
        flyStep()
    end
    FlyButtons.Visible = S.Fly and UserInputService.TouchEnabled
end

local function restoreJump()
    local hum = humanoid()
    if hum and Saved.UseJumpPower ~= nil then
        hum.UseJumpPower = Saved.UseJumpPower
        hum.JumpPower = Saved.JumpPower
        hum.JumpHeight = Saved.JumpHeight
    end
    Saved.UseJumpPower = nil
end

local function restoreNoclip()
    for part in NoclipParts do
        if part.Parent then
            part.CanCollide = true
        end
    end
    table.clear(NoclipParts)
end

bind(RunService.Stepped, function()
    if not alive() or not S.Noclip then
        return
    end
    local c = character()
    if not c then
        return
    end
    for _, part in c:GetDescendants() do
        if part:IsA("BasePart") and part.CanCollide then
            NoclipParts[part] = true
            part.CanCollide = false
        end
    end
end)

bind(UserInputService.JumpRequest, function()
    if not alive() or not S.InfJump or S.Fly then
        return
    end
    local hum = humanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

bind(LocalPlayer.Idled, function()
    if not alive() or not S.AntiAfk then
        return
    end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

--// Teleports \\--
local tpToken = 0
local function teleportTo(pos, quiet)
    local hrp = rootPart()
    if not hrp or not pos then
        if not quiet then
            notify("Teleport", "Nowhere to go (not loaded?)", 3)
        end
        return
    end
    local target = CFrame.new(pos + Vector3.new(0, 4, 0))
    tpToken += 1
    local token = tpToken
    if S.TpMethod == "Instant" or quiet then
        hrp.CFrame = target
        hrp.AssemblyLinearVelocity = Vector3.zero
        return
    end
    task.spawn(function()
        while alive() and token == tpToken do
            local dt = RunService.Heartbeat:Wait()
            local r = rootPart()
            if not r then
                break
            end
            local delta = target.Position - r.Position
            local d = delta.Magnitude
            if d < 2 then
                r.CFrame = target
                r.AssemblyLinearVelocity = Vector3.zero
                break
            end
            local step = math.min(d, S.TpSpeed * dt)
            r.CFrame = CFrame.new(r.Position + delta.Unit * step) * r.CFrame.Rotation
            r.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end

-- Puts you right above a point, for the farm (always instant).
local function standAt(pos)
    local hrp = rootPart()
    if not hrp or not pos then
        return
    end
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0)) * hrp.CFrame.Rotation
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function nearestSellPart()
    local hrp = rootPart()
    local best, bestD
    for _, p in CollectionService:GetTagged(C.SELL_TAG) do
        if p:IsA("BasePart") and p:IsDescendantOf(Workspace) then
            local d = hrp and (p.Position - hrp.Position).Magnitude or 0
            if not bestD or d < bestD then
                best, bestD = p, d
            end
        end
    end
    return best, bestD
end

-- A spot next to the sell hole, on the pile's side.
local function sellSpot(part)
    local toward = C.PILE_CENTER - part.Position
    toward = Vector3.new(toward.X, 0, toward.Z)
    toward = toward.Magnitude > 0.1 and toward.Unit or Vector3.new(1, 0, 0)
    return part.Position + toward * 6 + Vector3.new(0, 2, 0)
end

local function pileTop()
    local f = hayFolder()
    local best
    if f then
        local center = C.PILE_CENTER
        for _, p in f:GetChildren() do
            if p:IsA("BasePart") and p:GetAttribute("HayId") then
                local flat = Vector3.new(p.Position.X - center.X, 0, p.Position.Z - center.Z).Magnitude
                if flat < 6 and (not best or p.Position.Y > best.Y) then
                    best = p.Position
                end
            end
        end
    end
    return best or (C.PILE_CENTER + Vector3.new(0, C.PILE_HEIGHT, 0))
end

local function farmerPos()
    local npc = Workspace:FindFirstChild("NPC")
    local farmer = npc and npc:FindFirstChild("Farmer_NPC")
    return pivotPos(farmer)
end
local function shopPos()
    local shop = Workspace:FindFirstChild("BarnShop")
    if not shop then
        return nil
    end
    local sum, n = Vector3.zero, 0
    for _, child in shop:GetChildren() do
        local p = pivotPos(child)
        if p then
            sum += p
            n += 1
        end
    end
    return n > 0 and sum / n or nil
end

--// Farm \\--
local Farm = { busy = false, lastPick = 0, recent = {}, lastSell = 0, status = "Idle" }

-- The game's own grab: the strand plus the closest ones inside your grab radius.
local function grabExtras(target)
    local count = tonumber(LocalPlayer:GetAttribute("HayGrabCount")) or 1
    local radius = tonumber(LocalPlayer:GetAttribute("HayGrabRadius")) or 0
    if count <= 1 or radius <= 0 then
        return {}
    end
    local list = {}
    for _, p in haysNear(target.Position, radius) do
        if p ~= target then
            list[#list + 1] = { id = p:GetAttribute("HayId"), d = (p.Position - target.Position).Magnitude }
        end
    end
    table.sort(list, function(a, b)
        if a.d == b.d then
            return a.id < b.id
        end
        return a.d < b.d
    end)
    local ids = {}
    for i = 1, math.min(count - 1, #list) do
        ids[i] = list[i].id
    end
    return ids
end

local function nearestHayAnywhere()
    local hrp = rootPart()
    local f = hayFolder()
    if not hrp or not f then
        return nil
    end
    local best, bestD
    for _, p in f:GetChildren() do
        if p:IsA("BasePart") and p:GetAttribute("HayId") then
            local d = (p.Position - hrp.Position).Magnitude
            if not bestD or d < bestD then
                best, bestD = p, d
            end
        end
    end
    return best
end

local function pickTarget()
    local hrp = rootPart()
    if not hrp then
        return nil
    end
    local now = os.clock()
    local function fresh(p)
        local id = p:GetAttribute("HayId")
        return id and (not Farm.recent[id] or now - Farm.recent[id] > 1.2)
    end
    -- Special strands first: in reach, or worth flying to.
    if S.SpecialFirst or S.ChaseSpecial then
        for _, s in liveSpecial() do
            if fresh(s.part) then
                local d = (s.part.Position - hrp.Position).Magnitude
                local chase = S.ChaseSpecial and s.mult >= S.ChaseMinMult
                if d <= S.PickReach and (S.SpecialFirst or chase) then
                    return s.part
                end
                if chase then
                    standAt(s.part.Position)
                    return s.part, true
                end
            end
        end
    end
    local best, bestD
    for _, p in haysNear(hrp.Position, S.PickReach) do
        if fresh(p) then
            local d = (p.Position - hrp.Position).Magnitude
            if not bestD or d < bestD then
                best, bestD = p, d
            end
        end
    end
    if best then
        return best
    end
    if S.MoveToHay then
        local p = nearestHayAnywhere()
        if p then
            standAt(p.Position)
            return p, true
        end
    end
    return nil
end

local function pickDroppedNear()
    local folder = Workspace:FindFirstChild("DroppedHay")
    local hrp = rootPart()
    if not folder or not hrp then
        return false
    end
    for _, p in folder:GetChildren() do
        if p:IsA("BasePart") and p:GetAttribute("IsDroppedHay") and (p.Position - hrp.Position).Magnitude <= S.PickReach then
            fire("PickDroppedHay", p)
            return true
        end
    end
    return false
end

local function pickTick()
    if not S.AutoPick or Farm.busy or inputLocked() or bagFull() then
        return
    end
    local cooldown = (tonumber(LocalPlayer:GetAttribute("HayPickCooldown")) or C.PICK_COOLDOWN) + S.PickExtraDelay / 1000
    local now = os.clock()
    if now - Farm.lastPick < cooldown then
        return
    end
    if S.PickDropped and pickDroppedNear() then
        Farm.lastPick = now
        return
    end
    local target, moved = pickTarget()
    if not target then
        Farm.status = "No hay in reach"
        return
    end
    if moved then
        -- Picked next tick, once the server has you next to it.
        Farm.status = "Moving to hay"
        return
    end
    local id = target:GetAttribute("HayId")
    Farm.recent[id] = now
    Farm.lastPick = now
    fire("PickHay", id, grabExtras(target))
    Round.picks += 1
    Farm.status = "Picking"
    if SpecialParts[target] and multOf(SpecialParts[target]) >= 3 then
        logEvent("Picked " .. SpecialParts[target] .. " hay (x" .. multOf(SpecialParts[target]) .. ")", Special.color[SpecialParts[target]])
    end
end

local function shouldSell()
    local held, cap, infinite = bag()
    held += tonumber(LocalPlayer:GetAttribute("VacuumLoad")) or 0
    if held <= 0 then
        return false
    end
    if infinite then
        return held >= S.SellInfiniteAt
    end
    return held >= math.max(1, math.ceil(cap * S.SellAt / 100))
end

local function sellNow(manual)
    if Farm.busy then
        return
    end
    local hrp = rootPart()
    local part = nearestSellPart()
    if not hrp or not part then
        if manual then
            notify("Sell", "Couldn't find the sell hole", 3)
        end
        return
    end
    Farm.busy = true
    Farm.status = "Selling"
    local back = hrp.CFrame
    local moved = false
    if (part.Position - hrp.Position).Magnitude > 12 then
        local spot = sellSpot(part)
        hrp.CFrame = CFrame.lookAt(spot, Vector3.new(part.Position.X, spot.Y, part.Position.Z))
        hrp.AssemblyLinearVelocity = Vector3.zero
        moved = true
        task.wait(0.3)
    end
    local before = bag()
    fire("SellHay")
    local t = os.clock()
    while os.clock() - t < 1.5 and alive() do
        if bag() < before then
            break
        end
        task.wait(0.05)
    end
    if bag() < before then
        Round.sold += before - bag()
    end
    Farm.lastSell = os.clock()
    if moved and S.ReturnAfterSell and alive() then
        local r = rootPart()
        if r then
            r.CFrame = back
            r.AssemblyLinearVelocity = Vector3.zero
        end
    end
    Farm.busy = false
end

local function sellTick()
    if not S.AutoSell or Farm.busy or inputLocked() then
        return
    end
    if os.clock() - Farm.lastSell < 1.5 then
        return
    end
    if shouldSell() then
        task.spawn(sellNow, false)
    end
end

--// Gems \\--
local function gemTick()
    if not S.AutoGems or Farm.busy or inputLocked() then
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    for id, pos in Gems do
        local d = (pos - hrp.Position).Magnitude
        if d <= S.PickReach then
            fire("CollectGem", id)
            Gems[id] = nil
            return
        elseif S.GemTeleport then
            Farm.busy = true
            local back = hrp.CFrame
            standAt(pos)
            task.wait(0.25)
            fire("CollectGem", id)
            task.wait(0.25)
            if S.GemReturn and alive() then
                local r = rootPart()
                if r then
                    r.CFrame = back
                end
            end
            Gems[id] = nil
            Farm.busy = false
            return
        end
    end
end

--// Tools \\--
local Tools = { pitchforkAt = 0, vacuumOn = false, vacuumTickAt = 0, tntState = "idle", tntReadyAt = 0, droneAt = 0 }

local function droneTick()
    if not S.AutoDrone or inputLocked() then
        return
    end
    if LocalPlayer:GetAttribute("DroneOwned") ~= true or LocalPlayer:GetAttribute("DroneDeployed") == true then
        return
    end
    if os.clock() - Tools.droneAt < 3 then
        return
    end
    Tools.droneAt = os.clock()
    fire("DeployDrone")
    logEvent("Drone sent out")
end

local function pitchforkTick()
    if not S.AutoPitchfork or Farm.busy or inputLocked() or bagFull() then
        return
    end
    if LocalPlayer:GetAttribute("PitchforkOwned") ~= true then
        return
    end
    local cooldown = tonumber(LocalPlayer:GetAttribute("PitchforkCooldown")) or C.PITCHFORK_COOLDOWN
    if os.clock() - Tools.pitchforkAt < cooldown + 0.05 then
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    local best, bestD
    for _, p in haysNear(hrp.Position, math.min(S.PickReach, 14)) do
        local d = (p.Position - hrp.Position).Magnitude
        if not bestD or d < bestD then
            best, bestD = p, d
        end
    end
    if best then
        Tools.pitchforkAt = os.clock()
        fire("PitchforkDig", best:GetAttribute("HayId"))
    end
end

local function stopVacuum()
    if Tools.vacuumOn then
        Tools.vacuumOn = false
        fire("VacuumAction", "Stop")
    end
end

local function vacuumTick()
    local owned = LocalPlayer:GetAttribute("VacuumOwned") == true
    local heat = tonumber(LocalPlayer:GetAttribute("VacuumHeat")) or 0
    local overheated = LocalPlayer:GetAttribute("VacuumState") == "Overheated"
    if not S.AutoVacuum or not owned or overheated or Farm.busy or inputLocked() or bagFull() or heat * 100 >= S.VacuumStopAt then
        stopVacuum()
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    -- Aim at the closest strand in the vacuum's range.
    local best, bestD
    for _, p in haysNear(hrp.Position, C.VACUUM_RANGE) do
        local d = (p.Position - hrp.Position).Magnitude
        if not bestD or d < bestD then
            best, bestD = p, d
        end
    end
    if not best then
        stopVacuum()
        return
    end
    if not Tools.vacuumOn then
        Tools.vacuumOn = true
        fire("VacuumAction", "Start")
    end
    if os.clock() - Tools.vacuumTickAt < C.VACUUM_TICK then
        return
    end
    Tools.vacuumTickAt = os.clock()
    local nozzle = hrp.Position + hrp.CFrame.LookVector * 1.5 + Vector3.new(0, 1, 0)
    local ids = { best:GetAttribute("HayId") }
    for _, p in haysNear(best.Position, C.VACUUM_REACH) do
        local id = p:GetAttribute("HayId")
        if id ~= ids[1] and #ids < 24 then
            ids[#ids + 1] = id
        end
    end
    fire("VacuumAction", "Tick", best.Position, nozzle, ids)
end

-- Where to throw: the best special strand, or the strand with the most hay around it.
local function tntTarget()
    local hrp = rootPart()
    if not hrp then
        return nil
    end
    if S.TntTarget ~= "Thickest spot" then
        for _, s in liveSpecial() do
            if s.mult >= 3 and (s.part.Position - hrp.Position).Magnitude <= S.TntRange then
                return s.part.Position
            end
        end
        if S.TntTarget == "Special hay only" then
            return nil
        end
    end
    local best, bestN
    local near = haysNear(hrp.Position, S.TntRange)
    -- A sample of strands in range, scored by how much hay sits around each.
    for _ = 1, math.min(#near, 40) do
        local p = near[math.random(1, #near)]
        local n = #haysNear(p.Position, 3)
        if not bestN or n > bestN then
            best, bestN = p.Position, n
        end
    end
    return best
end

-- A throw that lands on `target` from `origin` under the workspace's gravity.
local function throwVelocity(origin, target)
    local g = Workspace.Gravity
    local delta = target - origin
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local t = math.clamp(flat.Magnitude / 40, 0.35, 1.2)
    local v = flat / t + Vector3.new(0, delta.Y / t + 0.5 * g * t, 0)
    if v.Magnitude > C.TNT_MAX_SPEED then
        v = v.Unit * C.TNT_MAX_SPEED
    end
    return v
end

task.spawn(function()
    local r = remote("TntAction")
    if r then
        bind(r.OnClientEvent, function(kind, value)
            if kind == "denied" then
                Tools.tntState = "idle"
                Tools.tntReadyAt = os.clock() + (tonumber(value) or 1)
            elseif kind == "lit" then
                Tools.tntReadyAt = os.clock() + (tonumber(LocalPlayer:GetAttribute("TntCooldown")) or C.TNT_COOLDOWN)
                if Tools.tntState == "lighting" then
                    Tools.tntState = "lit"
                end
            end
        end)
    end
end)

local function tntTick()
    if not S.AutoTnt or Farm.busy or inputLocked() or Tools.tntState ~= "idle" then
        return
    end
    if LocalPlayer:GetAttribute("TntOwned") ~= true or os.clock() < Tools.tntReadyAt then
        return
    end
    local target = tntTarget()
    if not target then
        return
    end
    Tools.tntState = "lighting"
    fire("TntAction", "light")
    task.spawn(function()
        local t = os.clock()
        while alive() and Tools.tntState == "lighting" and os.clock() - t < 2 do
            task.wait(0.05)
        end
        if Tools.tntState ~= "lit" then
            Tools.tntState = "idle"
            return
        end
        task.wait(C.TNT_LIGHT_TIME + 0.1)
        local hrp = rootPart()
        if hrp and alive() then
            local origin = hrp.CFrame * CFrame.new(0.8, 1.2, -1)
            fire("TntAction", "throw", origin, throwVelocity(origin.Position, target))
            logEvent("TNT thrown")
        end
        Tools.tntState = "idle"
    end)
end

--// Upgrades and tools \\--
local TrackTool = {
    TntLuck = "TntOwned", TntCooldown = "TntOwned", TntPower = "TntOwned",
    PitchforkCooldown = "PitchforkOwned", PitchforkHold = "PitchforkOwned", Pitchfork = "PitchforkOwned",
    DroneSpeed = "DroneOwned", DroneGrab = "DroneOwned", DroneCapacity = "DroneOwned",
    VacuumPower = "VacuumOwned", VacuumCooling = "VacuumOwned", VacuumRuntime = "VacuumOwned",
}
local UpgradeTracks = { "Capacity" }
if Config and Config.UPGRADE_ORDER then
    for _, t in Config.UPGRADE_ORDER do
        table.insert(UpgradeTracks, t)
    end
end
local function trackLabel(track)
    local info = Config and Config.UPGRADE_TRACKS and Config.UPGRADE_TRACKS[track]
    local name = info and info.DisplayName or track
    local group = track:match("^(Tnt)") or track:match("^(Pitchfork)") or track:match("^(Drone)") or track:match("^(Vacuum)")
    if group then
        return (group == "Tnt" and "TNT" or group) .. " " .. name
    end
    return name
end
local TrackLabels = {}
for _, t in UpgradeTracks do
    table.insert(TrackLabels, trackLabel(t))
end

local function nextUpgrade(track)
    local info = Config and Config.UPGRADE_TRACKS and Config.UPGRADE_TRACKS[track]
    if not info then
        return nil
    end
    local level = math.clamp(tonumber(LocalPlayer:GetAttribute("HayUpgrade" .. track)) or 1, 1, #info.Levels)
    local nextLevel = info.Levels[level + 1]
    if not nextLevel then
        return nil, level
    end
    local cost = nextLevel.Cost * (tonumber(LocalPlayer:GetAttribute("UpgradeCostMultiplier")) or 1)
    if string.sub(track, 1, 9) == "Pitchfork" then
        cost *= tonumber(LocalPlayer:GetAttribute("PitchforkUpgradeCostMultiplier")) or 1
    end
    return math.round(cost * 100) / 100, level
end

local Shop = { lastBuy = 0 }
local ToolItems = {
    { id = "Pitchfork", owned = "PitchforkOwned", label = "Pitchfork ($8)" },
    { id = "Tnt", owned = "TntOwned", label = "TNT ($25)" },
    { id = "Vacuum", owned = "VacuumOwned", label = "Vacuum ($69.99)" },
    { id = "Drone", owned = "DroneOwned", label = "Drone (40 gems)" },
}

local function upgradeTick()
    if os.clock() - Shop.lastBuy < 1.2 or inputLocked() then
        return
    end
    local spend = cash() - S.KeepCash
    if S.AutoBuyTools then
        for _, item in ToolItems do
            if S.BuyTools[item.label] and LocalPlayer:GetAttribute(item.owned) ~= true then
                Shop.lastBuy = os.clock()
                fire("BuyShopItem", item.id)
                return
            end
        end
    end
    if not S.AutoUpgrade then
        return
    end
    local best, bestCost
    for _, track in UpgradeTracks do
        if S.UpgradeTracks[trackLabel(track)] then
            local need = TrackTool[track]
            if not (S.UpgradeOnlyOwned and need and LocalPlayer:GetAttribute(need) ~= true) then
                local cost = nextUpgrade(track)
                if cost and cost <= spend and (not bestCost or cost < bestCost) then
                    best, bestCost = track, cost
                end
            end
        end
    end
    if best then
        Shop.lastBuy = os.clock()
        fire("BuyUpgrade", best)
        logEvent(string.format("Bought %s (%s)", trackLabel(best), money(bestCost)), Library.Scheme.AccentColor)
    end
end

--// Misc \\--
local Misc = { lobbyAt = nil, skipAt = 0 }

local function fireButton(button)
    if typeof(firesignal) == "function" then
        if pcall(firesignal, button.Activated) then
            return true
        end
        return pcall(firesignal, button.MouseButton1Click)
    end
    if typeof(getconnections) == "function" then
        local fired = false
        for _, signal in { button.Activated, button.MouseButton1Click } do
            for _, c in getconnections(signal) do
                if c.Function then
                    task.spawn(c.Function)
                    fired = true
                end
            end
        end
        return fired
    end
    return false
end

local function miscTick()
    if S.SkipCutscenes and LocalPlayer:GetAttribute("CutsceneActive") == true and os.clock() - Misc.skipAt > 1 then
        Misc.skipAt = os.clock()
        local gui = LocalPlayer:FindFirstChild("PlayerGui")
        local button = gui and gui:FindFirstChild("SkipCutsceneButton", true)
        if button and button:IsA("GuiButton") then
            fireButton(button)
        end
    end
    if S.AutoLobby and LocalPlayer:GetAttribute("NeedleRoundComplete") == true then
        Misc.lobbyAt = Misc.lobbyAt or os.clock() + S.LobbyDelay
        if os.clock() >= Misc.lobbyAt then
            Misc.lobbyAt = os.clock() + 15
            fire("ReturnToLobby")
            logEvent("Going back to the lobby")
        end
    elseif LocalPlayer:GetAttribute("NeedleRoundComplete") ~= true then
        Misc.lobbyAt = nil
    end
end

--// ESP \\--
local Esp = {}
local function espEntry(key, part)
    local e = Esp[key]
    if e then
        if e.bb.Adornee ~= part then
            e.bb.Adornee = part
        end
        return e
    end
    local bb = Instance.new("BillboardGui")
    bb.Name = "NHEsp"
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(200, 36)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 1.5, 0)
    bb.LightInfluence = 0
    bb.MaxDistance = math.huge
    bb.Adornee = part
    bb.Parent = VisualGui
    local dot = Instance.new("Frame")
    dot.AnchorPoint = Vector2.new(0.5, 1)
    dot.Position = UDim2.new(0.5, 0, 1, 0)
    dot.Size = UDim2.fromOffset(10, 10)
    dot.BorderSizePixel = 0
    dot.Parent = bb
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", dot)
    stroke.Color = Color3.new(0, 0, 0)
    stroke.Thickness = 1.5
    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.new(1, 0, 1, -12)
    text.Font = Enum.Font.GothamBold
    text.TextSize = 12
    text.TextStrokeTransparency = 0.35
    text.Parent = bb
    e = { bb = bb, text = text, dot = dot }
    Esp[key] = e
    return e
end
local function dropEsp(key)
    local e = Esp[key]
    if e then
        e.bb:Destroy()
        if e.hl then
            e.hl:Destroy()
        end
        Esp[key] = nil
    end
end

-- A line from you to the needle.
local Beam = { part = nil, beam = nil, a0 = nil, a1 = nil }
local function clearBeam()
    for _, k in { "beam", "a0", "a1", "part" } do
        if Beam[k] then
            pcall(Beam[k].Destroy, Beam[k])
            Beam[k] = nil
        end
    end
end
local function updateBeam(target)
    local hrp = rootPart()
    if not target or not hrp or not S.NeedleBeam then
        clearBeam()
        return
    end
    if not Beam.part then
        local holder = Instance.new("Part")
        holder.Name = "NHBeamHolder"
        holder.Anchored = true
        holder.CanCollide = false
        holder.CanQuery = false
        holder.CanTouch = false
        holder.Transparency = 1
        holder.Size = Vector3.new(0.2, 0.2, 0.2)
        holder.Parent = Workspace.CurrentCamera
        Beam.part = holder
        Beam.a0 = Instance.new("Attachment", holder)
        Beam.a1 = Instance.new("Attachment", holder)
        local beam = Instance.new("Beam")
        beam.Attachment0, beam.Attachment1 = Beam.a0, Beam.a1
        beam.Width0, beam.Width1 = 0.35, 0.35
        beam.FaceCamera = true
        beam.LightEmission = 1
        beam.Color = ColorSequence.new(Color3.fromRGB(255, 80, 80), Color3.fromRGB(255, 220, 90))
        beam.Transparency = NumberSequence.new(0.1)
        beam.Parent = holder
        Beam.beam = beam
    end
    Beam.a0.WorldPosition = hrp.Position - Vector3.new(0, 1.5, 0)
    Beam.a1.WorldPosition = target.Position
end

local function updateEsp()
    local hrp = rootPart()
    local want = {}
    local function consider(key, part, color, text, highlight)
        if not part or not part.Parent then
            return
        end
        local d = hrp and math.floor((part.Position - hrp.Position).Magnitude) or 0
        want[key] = { part = part, color = color, text = text and (text .. " · " .. d .. "m") or nil, highlight = highlight }
    end

    local needle = (S.NeedleEsp or S.NeedleBeam) and Round.needleId and needlePart() or nil
    if needle and S.NeedleEsp then
        consider("needle", needle, Color3.fromRGB(255, 70, 70), "NEEDLE", needle)
    end
    updateBeam(needle)

    if S.SpecialEsp then
        local shown = 0
        for _, s in liveSpecial() do
            if S.SpecialTypes[s.name] then
                shown += 1
                if shown > S.SpecialMax then
                    break
                end
                consider(s.part, s.part, Special.color[s.name] or Color3.new(1, 1, 1),
                    S.SpecialLabels and (s.name .. " x" .. s.mult) or nil)
            end
        end
    end
    if S.GemEsp then
        local folder = gemsFolder()
        if folder then
            for _, m in folder:GetChildren() do
                local p = anyPart(m)
                if p then
                    consider(m, p, Color3.fromRGB(96, 190, 255), "Gem", m)
                end
            end
        end
    end
    if S.DroneEsp then
        local drones = Workspace:FindFirstChild("HayDrones")
        if drones then
            for _, m in drones:GetChildren() do
                local p = anyPart(m)
                if p then
                    local owner = m:GetAttribute("OwnerName") or "Drone"
                    consider(m, p, Color3.fromRGB(200, 200, 200), tostring(owner) .. "'s drone")
                end
            end
        end
    end
    if S.SellEsp then
        local part = nearestSellPart()
        if part then
            consider("sell", part, Color3.fromRGB(120, 230, 120), "Sell hole", part)
        end
    end
    if S.PlayerEsp then
        for _, player in Players:GetPlayers() do
            if player ~= LocalPlayer and player.Character then
                local p = player.Character:FindFirstChild("HumanoidRootPart")
                if p then
                    consider(player, p, Color3.fromRGB(120, 180, 255), player.DisplayName, player.Character)
                end
            end
        end
    end

    for key in Esp do
        if not want[key] then
            dropEsp(key)
        end
    end
    for key, info in want do
        local e = espEntry(key, info.part)
        e.dot.BackgroundColor3 = info.color
        e.text.Text = info.text or ""
        e.text.TextColor3 = info.color
        if info.highlight then
            if not e.hl then
                e.hl = Instance.new("Highlight")
                e.hl.FillTransparency = 0.6
                e.hl.OutlineTransparency = 0
                e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                e.hl.Parent = VisualGui
            end
            if e.hl.Adornee ~= info.highlight then
                e.hl.Adornee = info.highlight
            end
            e.hl.FillColor = info.color
            e.hl.OutlineColor = info.color
        elseif e.hl then
            e.hl:Destroy()
            e.hl = nil
        end
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Needle in a Haystack",
    Footer = "dookie hub · Ui3",
    Icon = "wheat",
    Size = UDim2.fromOffset(760, 580),
    ConfigFolder = "Ui3/NeedleHaystack",
})

local UI = {}

do -- Dashboard
    local Tab = Window:AddTab("Dashboard", "layout-dashboard", "The round at a glance")
    local RoundBox = Tab:AddBigGroupbox("Round", "wheat")
    UI.RoundCards = RoundBox:AddStatCards("RoundCards", {
        Cards = {
            { Title = "Hay left", Value = "-", Icon = "layers" },
            { Title = "Needle", Value = "Hidden", Icon = "search" },
            { Title = "Round time", Value = "-", Icon = "clock" },
            { Title = "Difficulty", Value = "-", Icon = "flame" },
        },
    })
    UI.RevealBar = RoundBox:AddProgressBar("RevealBar", { Text = "Until the needle shows", Default = 0, Max = 1, Percent = true })
    UI.SpecialLabel = RoundBox:AddLabel("Special hay this round: working it out...", true)

    local YouBox = Tab:AddBigGroupbox("You", "user")
    UI.YouCards = YouBox:AddStatCards("YouCards", {
        Cards = {
            { Title = "Bag", Value = "-", Icon = "shopping-bag" },
            { Title = "Cash", Value = "-", Icon = "coins" },
            { Title = "Gems", Value = "-", Icon = "gem" },
            { Title = "Earned here", Value = "-", Icon = "trending-up" },
        },
    })
    UI.BagBar = YouBox:AddProgressBar("BagBar", { Text = "Bag", Default = 0, Max = 25, Percent = false })
    UI.FarmLabel = YouBox:AddLabel("Farm: idle", true)

    local LogBox = Tab:AddBigGroupbox("Log", "scroll-text")
    Log = LogBox:AddLog("EventLog", { Height = 150, MaxLines = 150, Timestamps = true })
end

do -- Farm
    local Tab = Window:AddTab("Farm", "pickaxe", "Auto pick, sell and gems")
    local Pick = Tab:AddLeftGroupbox("Auto pick", "hand")
    Pick:AddToggle("AutoPick", {
        Text = "Auto pick hay",
        Default = false,
        Tooltip = "Picks the closest strands on your own pick cooldown, using your Grasp upgrade like the game does",
        Callback = function(v)
            S.AutoPick = v
        end,
    }):AddKeyPicker("AutoPickKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto pick" })
    Pick:AddSlider("PickReach", {
        Text = "Reach",
        Default = S.PickReach,
        Min = 4,
        Max = 20,
        Suffix = " studs",
        Tooltip = "The game lets you pick up to 20 studs away",
        Callback = function(v)
            S.PickReach = v
        end,
    })
    Pick:AddSlider("PickExtraDelay", {
        Text = "Extra wait between picks",
        Default = S.PickExtraDelay,
        Min = 0,
        Max = 1000,
        Suffix = " ms",
        Callback = function(v)
            S.PickExtraDelay = v
        end,
    })
    Pick:AddToggle("MoveToHay", {
        Text = "Move to hay when none is in reach",
        Default = S.MoveToHay,
        Callback = function(v)
            S.MoveToHay = v
        end,
    })
    Pick:AddToggle("PickDropped", { Text = "Pick up dropped hay", Default = S.PickDropped, Callback = function(v)
        S.PickDropped = v
    end })
    Pick:AddDivider("Special hay")
    Pick:AddToggle("SpecialFirst", {
        Text = "Special hay first",
        Default = S.SpecialFirst,
        Tooltip = "When a special strand is in reach, it's picked before anything else (best multiplier first)",
        Callback = function(v)
            S.SpecialFirst = v
        end,
    })
    Pick:AddToggle("ChaseSpecial", {
        Text = "Go get special hay anywhere",
        Default = S.ChaseSpecial,
        Tooltip = "Teleports to special strands on the pile that are worth at least the multiplier below",
        Callback = function(v)
            S.ChaseSpecial = v
        end,
    })
    Pick:AddSlider("ChaseMinMult", {
        Text = "Worth going for from",
        Default = S.ChaseMinMult,
        Min = 1,
        Max = 20,
        Suffix = "x",
        Callback = function(v)
            S.ChaseMinMult = v
        end,
    })

    local Sell = Tab:AddRightGroupbox("Auto sell", "badge-dollar-sign")
    Sell:AddToggle("AutoSell", {
        Text = "Auto sell",
        Default = false,
        Tooltip = "Goes to the cow's sell hole when your bag is full enough, sells, and comes back",
        Callback = function(v)
            S.AutoSell = v
        end,
    })
    Sell:AddSlider("SellAt", {
        Text = "Sell when the bag is",
        Default = S.SellAt,
        Min = 10,
        Max = 100,
        Suffix = "% full",
        Callback = function(v)
            S.SellAt = v
        end,
    })
    Sell:AddSlider("SellInfiniteAt", {
        Text = "With the infinite bag, sell at",
        Default = S.SellInfiniteAt,
        Min = 25,
        Max = 5000,
        Suffix = " hay",
        Callback = function(v)
            S.SellInfiniteAt = v
        end,
    })
    Sell:AddToggle("ReturnAfterSell", { Text = "Go back after selling", Default = S.ReturnAfterSell, Callback = function(v)
        S.ReturnAfterSell = v
    end })
    Sell:AddButton("Sell now", function()
        task.spawn(sellNow, true)
    end)

    local GemBox = Tab:AddRightGroupbox("Gems", "gem")
    GemBox:AddToggle("AutoGems", {
        Text = "Auto collect gems",
        Default = false,
        Tooltip = "Grabs gems as they pop out of the pile",
        Callback = function(v)
            S.AutoGems = v
        end,
    })
    GemBox:AddToggle("GemTeleport", { Text = "Go to gems out of reach", Default = S.GemTeleport, Callback = function(v)
        S.GemTeleport = v
    end })
    GemBox:AddToggle("GemReturn", { Text = "Go back after a gem", Default = S.GemReturn, Callback = function(v)
        S.GemReturn = v
    end })
    UI.GemLabel = GemBox:AddLabel("Gems out: 0", true)
end

do -- Tools
    local Tab = Window:AddTab("Tools", "wrench", "Drone, pitchfork, vacuum and TNT")
    local Use = Tab:AddLeftGroupbox("Use tools", "hammer")
    Use:AddToggle("AutoDrone", {
        Text = "Auto send the drone",
        Default = false,
        Tooltip = "Sends it back out every time it lands",
        Callback = function(v)
            S.AutoDrone = v
        end,
    })
    Use:AddToggle("AutoPitchfork", {
        Text = "Auto pitchfork",
        Default = false,
        Tooltip = "Digs the closest strand on the pitchfork's cooldown, no Hold upgrade needed",
        Callback = function(v)
            S.AutoPitchfork = v
        end,
    })
    Use:AddToggle("AutoVacuum", {
        Text = "Auto vacuum",
        Default = false,
        Tooltip = "Runs the vacuum on the closest strands and starts it again after it cools down",
        Callback = function(v)
            S.AutoVacuum = v
            if not v then
                stopVacuum()
            end
        end,
    })
    Use:AddSlider("VacuumStopAt", {
        Text = "Stop vacuum at heat",
        Default = S.VacuumStopAt,
        Min = 50,
        Max = 100,
        Suffix = "%",
        Tooltip = "100 runs it until it overheats. Heat doesn't drop while it's off, so stopping early only saves you from the forced cooldown",
        Callback = function(v)
            S.VacuumStopAt = v
        end,
    })
    Use:AddDivider("TNT")
    Use:AddToggle("AutoTnt", {
        Text = "Auto TNT",
        Default = false,
        Tooltip = "Lights and throws TNT whenever its cooldown is ready",
        Callback = function(v)
            S.AutoTnt = v
        end,
    })
    Use:AddDropdown("TntTarget", {
        Text = "Throw at",
        Values = { "Special hay, else thickest", "Special hay only", "Thickest spot" },
        Default = S.TntTarget,
        Callback = function(v)
            S.TntTarget = v or "Special hay, else thickest"
        end,
    })
    Use:AddSlider("TntRange", { Text = "Throw range", Default = S.TntRange, Min = 10, Max = 80, Suffix = " studs", Callback = function(v)
        S.TntRange = v
    end })
    UI.ToolLabel = Use:AddLabel("-", true)

    local Up = Tab:AddRightGroupbox("Upgrades", "arrow-up-circle")
    Up:AddToggle("AutoUpgrade", {
        Text = "Auto buy upgrades",
        Default = false,
        Tooltip = "Buys the cheapest ticked upgrade you can afford, again and again",
        Callback = function(v)
            S.AutoUpgrade = v
        end,
    })
    Up:AddDropdown("UpgradeTracks", {
        Text = "Upgrades to buy",
        Values = TrackLabels,
        Default = {},
        Multi = true,
        Searchable = true,
        Callback = function(v)
            S.UpgradeTracks = v or {}
        end,
    })
    Up:AddToggle("UpgradeOnlyOwned", {
        Text = "Only for tools you own",
        Default = S.UpgradeOnlyOwned,
        Callback = function(v)
            S.UpgradeOnlyOwned = v
        end,
    })
    Up:AddSlider("KeepCash", { Text = "Always keep", Default = S.KeepCash, Min = 0, Max = 100, Prefix = "$", Callback = function(v)
        S.KeepCash = v
    end })
    UI.UpgradeLabel = Up:AddLabel("-", true)

    local Buy = Tab:AddRightGroupbox("Buy tools", "shopping-cart")
    Buy:AddToggle("AutoBuyTools", {
        Text = "Auto buy tools",
        Default = false,
        Tooltip = "Buys the ticked tools with cash (or gems for the drone) as soon as you can",
        Callback = function(v)
            S.AutoBuyTools = v
        end,
    })
    local labels = {}
    for _, item in ToolItems do
        table.insert(labels, item.label)
    end
    Buy:AddDropdown("BuyTools", {
        Text = "Tools",
        Values = labels,
        Default = {},
        Multi = true,
        Callback = function(v)
            S.BuyTools = v or {}
        end,
    })
end

do -- Visuals
    local Tab = Window:AddTab("Visuals", "eye", "Needle, special hay and more")
    local Needle = Tab:AddLeftGroupbox("Needle", "search")
    Needle:AddToggle("NeedleAlert", { Text = "Alert when it shows", Default = S.NeedleAlert, Callback = function(v)
        S.NeedleAlert = v
    end })
    Needle:AddToggle("NeedleEsp", { Text = "Needle ESP", Default = S.NeedleEsp, Callback = function(v)
        S.NeedleEsp = v
    end })
    Needle:AddToggle("NeedleBeam", {
        Text = "Beam to the needle",
        Default = S.NeedleBeam,
        Callback = function(v)
            S.NeedleBeam = v
            if not v then
                clearBeam()
            end
        end,
    })
    Needle:AddLabel("The server only sends where the needle is once enough hay is gone (see the bar on the Dashboard).", true)

    local Spec = Tab:AddRightGroupbox("Special hay", "sparkles")
    Spec:AddToggle("SpecialEsp", {
        Text = "Special hay ESP",
        Default = false,
        Tooltip = "Dots on special strands in the pile, colored by type. Deeper ones show up as the pile is dug",
        Callback = function(v)
            S.SpecialEsp = v
        end,
    })
    local typeLabels = {}
    for _, name in Special.order do
        table.insert(typeLabels, name)
    end
    Spec:AddDropdown("SpecialTypes", {
        Text = "Types",
        Values = typeLabels,
        Default = (function()
            local d = {}
            for name, on in S.SpecialTypes do
                if on then
                    table.insert(d, name)
                end
            end
            return d
        end)(),
        Multi = true,
        Callback = function(v)
            S.SpecialTypes = v or {}
        end,
    })
    Spec:AddToggle("SpecialLabels", { Text = "Show type and multiplier", Default = S.SpecialLabels, Callback = function(v)
        S.SpecialLabels = v
    end })
    Spec:AddSlider("SpecialMax", { Text = "Most shown at once", Default = S.SpecialMax, Min = 5, Max = 200, Callback = function(v)
        S.SpecialMax = v
    end })

    local Other = Tab:AddLeftGroupbox("Other ESP", "scan-eye")
    Other:AddToggle("GemEsp", { Text = "Gems", Default = false, Callback = function(v)
        S.GemEsp = v
    end })
    Other:AddToggle("DroneEsp", { Text = "Drones", Default = false, Callback = function(v)
        S.DroneEsp = v
    end })
    Other:AddToggle("SellEsp", { Text = "Sell hole", Default = false, Callback = function(v)
        S.SellEsp = v
    end })
    Other:AddToggle("PlayerEsp", { Text = "Players", Default = false, Callback = function(v)
        S.PlayerEsp = v
    end })
end

do -- Movement
    local Tab = Window:AddTab("Movement", "footprints", "Speed, jump, fly and teleports")
    local Move = Tab:AddLeftGroupbox("Movement", "move")
    Move:AddToggle("Speed", {
        Text = "Speed",
        Default = false,
        Callback = function(v)
            S.Speed = v
            if not v then
                local hum = humanoid()
                if hum and S.SpeedMethod == "WalkSpeed" then
                    hum.WalkSpeed = 16
                end
            end
        end,
    })
    Move:AddSlider("SpeedValue", { Text = "Walk speed", Default = S.SpeedValue, Min = 16, Max = 150, Callback = function(v)
        S.SpeedValue = v
    end })
    Move:AddDropdown("SpeedMethod", {
        Text = "Speed method",
        Values = { "WalkSpeed", "CFrame" },
        Default = S.SpeedMethod,
        Tooltip = "CFrame leaves the game's walk speed alone and pushes you along on top of it",
        Callback = function(v)
            S.SpeedMethod = v or "WalkSpeed"
        end,
    })
    Move:AddDivider()
    Move:AddToggle("Jump", {
        Text = "Jump power",
        Default = false,
        Callback = function(v)
            S.Jump = v
            if not v then
                restoreJump()
            end
        end,
    })
    Move:AddSlider("JumpValue", { Text = "Jump power", Default = S.JumpValue, Min = 50, Max = 250, Callback = function(v)
        S.JumpValue = v
    end })
    Move:AddToggle("InfJump", { Text = "Infinite jump", Default = false, Callback = function(v)
        S.InfJump = v
    end })
    Move:AddDivider()
    Move:AddToggle("Fly", {
        Text = "Fly",
        Default = false,
        Tooltip = "Thumbstick or WASD to move where the camera looks. Space/E up, Ctrl/Q down, or the ▲▼ buttons on mobile",
        Callback = function(v)
            S.Fly = v
            if not v then
                stopFly()
                FlyUpHeld, FlyDownHeld = false, false
            end
        end,
    }):AddKeyPicker("FlyKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
    Move:AddSlider("FlySpeed", { Text = "Fly speed", Default = S.FlySpeed, Min = 16, Max = 250, Callback = function(v)
        S.FlySpeed = v
    end })
    Move:AddToggle("Noclip", {
        Text = "Noclip",
        Default = false,
        Callback = function(v)
            S.Noclip = v
            if not v then
                restoreNoclip()
            end
        end,
    })

    local Tp = Tab:AddRightGroupbox("Teleports", "map-pin")
    Tp:AddDropdown("TpMethod", { Text = "Teleport method", Values = { "Instant", "Tween" }, Default = S.TpMethod, Callback = function(v)
        S.TpMethod = v or "Instant"
    end })
    Tp:AddSlider("TpSpeed", { Text = "Tween speed", Default = S.TpSpeed, Min = 30, Max = 280, Callback = function(v)
        S.TpSpeed = v
    end })
    Tp:AddButton("Top of the pile", function()
        teleportTo(pileTop())
    end):AddButton({ Text = "Sell hole", Func = function()
        local part = nearestSellPart()
        teleportTo(part and sellSpot(part))
    end })
    Tp:AddButton("Farmer", function()
        teleportTo(farmerPos())
    end):AddButton({ Text = "Shop", Func = function()
        teleportTo(shopPos())
    end })
    Tp:AddButton("Stop tween", function()
        tpToken += 1
    end)

    local Pl = Tab:AddRightGroupbox("Players", "users")
    Pl:AddDropdown("TpPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
    Pl:AddButton("Teleport", function()
        local name = Options.TpPlayer and Options.TpPlayer.Value
        local player = name and Players:FindFirstChild(name)
        local hrp = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        teleportTo(hrp and hrp.Position)
    end)
end

do -- Misc
    local Tab = Window:AddTab("Misc", "settings", "Cutscenes, lobby and the menu")
    local Box = Tab:AddLeftGroupbox("Round", "flag")
    Box:AddToggle("SkipCutscenes", {
        Text = "Skip cutscenes",
        Default = false,
        Tooltip = "Presses the game's own skip button as soon as one starts",
        Callback = function(v)
            S.SkipCutscenes = v
        end,
    })
    Box:AddToggle("AutoLobby", {
        Text = "Back to lobby after the round",
        Default = false,
        Callback = function(v)
            S.AutoLobby = v
        end,
    })
    Box:AddSlider("LobbyDelay", { Text = "Wait before leaving", Default = S.LobbyDelay, Min = 0, Max = 60, Suffix = " s", Callback = function(v)
        S.LobbyDelay = v
    end })
    Box:AddToggle("AntiAfk", { Text = "Anti AFK", Default = S.AntiAfk, Callback = function(v)
        S.AntiAfk = v
    end })

    local Menu = Tab:AddRightGroupbox("Menu", "panel-top")
    Menu:AddButton({
        Text = "Unload",
        DoubleClick = true,
        Func = function()
            if Genv.__NeedleUnload then
                Genv.__NeedleUnload()
            end
        end,
    })
end

--// Loops \\--
bind(RunService.Heartbeat, function(dt)
    if not alive() then
        return
    end
    pcall(movementStep, dt)
end)

-- Farm: fast loop for picking and tools.
task.spawn(function()
    while alive() do
        pcall(watchHayFolder)
        pcall(pickTick)
        pcall(sellTick)
        pcall(pitchforkTick)
        pcall(vacuumTick)
        pcall(tntTick)
        pcall(gemTick)
        task.wait(0.05)
    end
    stopVacuum()
end)

-- Slower loop: drone, shop, misc and ESP.
task.spawn(function()
    while alive() do
        pcall(droneTick)
        pcall(upgradeTick)
        pcall(miscTick)
        pcall(scanSpecial)
        pcall(updateEsp)
        task.wait(0.2)
    end
end)

-- Dashboard.
task.spawn(function()
    while alive() do
        pcall(function()
            local total = tonumber(NH and NH:GetAttribute("TotalHay")) or C.TOTAL_HAY
            local left = tonumber(NH and NH:GetAttribute("RemainingHay")) or total
            local dug = math.max(0, total - left)
            local revealed = NH and NH:GetAttribute("NeedleRevealed") == true or Round.needleId ~= nil
            local claimed = NH and NH:GetAttribute("NeedleClaimed") == true
            local started = tonumber(NH and NH:GetAttribute("RoundStartedAt"))
            local now = Workspace:GetServerTimeNow()

            UI.RoundCards:SetValue("Hay left", string.format("%d / %d", left, total))
            UI.RoundCards:SetValue("Needle", claimed and ("Found" .. (Round.needleClaimedBy and (" by " .. Round.needleClaimedBy) or ""))
                or revealed and "Showing" or "Hidden")
            UI.RoundCards:SetValue("Round time", started and clock(now - started) or "-")
            UI.RoundCards:SetValue("Difficulty", tostring(NH and NH:GetAttribute("Difficulty") or "-"))
            local need = math.max(1, total * C.REVEAL)
            UI.RevealBar:SetText(revealed and "The needle is showing" or string.format("Until the needle shows (%d more hay)", math.max(0, math.ceil(need - dug))))
            UI.RevealBar:SetValue(revealed and 1 or math.clamp(dug / need, 0, 1))

            if Round.specialCounts then
                local parts = {}
                for _, name in Special.order do
                    local n = Round.specialCounts[name]
                    if n then
                        table.insert(parts, string.format("%s x%s: %d", name, tostring(multOf(name)), n))
                    end
                end
                local inPile = 0
                for _ in SpecialParts do
                    inPile += 1
                end
                UI.SpecialLabel:SetText("Special hay this round: " .. (#parts > 0 and table.concat(parts, "  ·  ") or "none")
                    .. string.format("\nOn the surface right now: %d", inPile))
            end

            local held, cap, infinite = bag()
            local c = cash()
            Round.startCash = Round.startCash or c
            UI.YouCards:SetValue("Bag", infinite and (held .. " / ∞") or string.format("%d / %d", held, cap))
            UI.YouCards:SetValue("Cash", money(c))
            UI.YouCards:SetValue("Gems", tostring(LocalPlayer:GetAttribute("Gems") or "-"))
            UI.YouCards:SetValue("Earned here", money(math.max(0, c - Round.startCash)))
            UI.BagBar:SetMax(math.max(infinite and S.SellInfiniteAt or cap, 1))
            UI.BagBar:SetValue(held)

            local farmBits = {}
            if S.AutoPick then
                table.insert(farmBits, Farm.status)
            end
            table.insert(farmBits, string.format("%d picks, %d hay sold, %d gems", Round.picks, Round.sold, Round.gems))
            UI.FarmLabel:SetText("Farm: " .. table.concat(farmBits, "  ·  "))

            local gemCount = 0
            for _ in Gems do
                gemCount += 1
            end
            UI.GemLabel:SetText("Gems out: " .. gemCount)

            local owned = {}
            for _, item in ToolItems do
                if LocalPlayer:GetAttribute(item.owned) == true then
                    table.insert(owned, item.id == "Tnt" and "TNT" or item.id)
                end
            end
            local heat = tonumber(LocalPlayer:GetAttribute("VacuumHeat"))
            UI.ToolLabel:SetText("Owned: " .. (#owned > 0 and table.concat(owned, ", ") or "none")
                .. (heat and string.format("\nVacuum heat: %d%%%s", math.floor(heat * 100),
                    LocalPlayer:GetAttribute("VacuumState") == "Overheated" and " (cooling)" or "") or "")
                .. (Tools.tntReadyAt > os.clock() and string.format("\nTNT ready in %ds", math.ceil(Tools.tntReadyAt - os.clock())) or ""))

            local lines = {}
            for _, track in UpgradeTracks do
                if S.UpgradeTracks[trackLabel(track)] then
                    local cost, level = nextUpgrade(track)
                    table.insert(lines, string.format("%s: lvl %s%s", trackLabel(track), tostring(level or "?"),
                        cost and (" · next " .. money(cost)) or " · max"))
                end
            end
            UI.UpgradeLabel:SetText(#lines > 0 and table.concat(lines, "\n") or "Tick upgrades above to see their next cost")
        end)
        task.wait(0.3)
    end
end)

logEvent("Loaded · " .. tostring(NH and NH:GetAttribute("Map") or "?") .. " · " .. tostring(NH and NH:GetAttribute("Difficulty") or "?"))

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    table.clear(Connections)
    tpToken += 1
    pcall(stopVacuum)
    stopFly()
    restoreNoclip()
    restoreJump()
    local hum = humanoid()
    if hum and S.Speed and S.SpeedMethod == "WalkSpeed" then
        hum.WalkSpeed = 16
    end
    for key in Esp do
        dropEsp(key)
    end
    clearBeam()
    pcall(function()
        VisualGui:Destroy()
    end)
end

Library:OnUnload(cleanup)
Genv.__NeedleUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

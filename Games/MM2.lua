local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function resolveEvent(modern, legacy)
    local ok, event = pcall(function() return RunService[modern] end)
    if ok and event then return event end
    return RunService[legacy]
end

local PreSimulation = resolveEvent("PreSimulation", "Stepped")

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

local function waitForPath(root, path, timeout)
    local current = root
    for _, name in ipairs(path) do
        if not current then return nil end
        local ok, child = pcall(function() return current:WaitForChild(name, timeout or 10) end)
        if not ok then return nil end
        current = child
    end
    return current
end

local RemotesFolder = waitForPath(ReplicatedStorage, { "Remotes" })
local GameplayRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Gameplay")
local InventoryRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Inventory")

local GetCurrentPlayerData = GameplayRemotes and GameplayRemotes:FindFirstChild("GetCurrentPlayerData")
local PlayerDataChangedRemote = GameplayRemotes and GameplayRemotes:FindFirstChild("PlayerDataChanged")

local GetProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("GetProfileData")
local ChangeProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeProfileData")
local ChangeInventoryItem = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeInventoryItem")

local LevelModule = nil
do
    local ModulesFolder = waitForPath(ReplicatedStorage, { "Modules" })
    local mod = ModulesFolder and ModulesFolder:FindFirstChild("LevelModule")
    if mod then
        local ok, result = pcall(require, mod)
        if ok then LevelModule = result end
    end
end

local RoundData = {}

local function refreshRoundData()
    if not GetCurrentPlayerData then return end
    local ok, data = pcall(function() return GetCurrentPlayerData:InvokeServer() end)
    if ok and typeof(data) == "table" then
        RoundData = data
    end
end

task.spawn(refreshRoundData)

if PlayerDataChangedRemote then
    track(PlayerDataChangedRemote.OnClientEvent:Connect(function(data)
        if typeof(data) == "table" then
            RoundData = data
        end
    end))
end

task.spawn(function()
    while not Unloading do
        task.wait(2)
        pcall(refreshRoundData)
    end
end)

local function heldWeapon(char)
    if not char then return nil end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then
            local tagged = false
            pcall(function() tagged = CollectionService:HasTag(item, "Weapon_Gun") end)
            if item.Name == "Gun" or item:FindFirstChild("IsGun") or tagged then
                return "Gun"
            end
            if item.Name == "Knife" or item:FindFirstChild("KnifeClient") or item:FindFirstChild("Stab") then
                return "Knife"
            end
        end
    end
    return nil
end

local function roleOf(plr)
    local entry = RoundData[plr.Name]
    local role = entry and entry.Role or nil
    local dead = entry ~= nil and entry.Dead == true
    local held = heldWeapon(plr.Character)

    if held == "Knife" then
        role = "Murderer"
    elseif held == "Gun" then
        if role == nil then
            role = "Sheriff"
        elseif role ~= "Sheriff" and role ~= "Hero" then
            role = "Hero"
        end
    end

    return role, dead, entry
end

local function isAlivePlr(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local ProfileData = nil

local function fetchProfileData()
    if not GetProfileData then return end
    task.spawn(function()
        local tries = 0
        while not Unloading and tries < 60 do
            local ok, data = pcall(function() return GetProfileData:InvokeServer() end)
            if ok and typeof(data) == "table" then
                ProfileData = data
                return
            end
            tries = tries + 1
            task.wait(0.25)
        end
    end)
end

fetchProfileData()

if ChangeProfileData then
    track(ChangeProfileData.OnClientEvent:Connect(function(key, value)
        if ProfileData then ProfileData[key] = value end
    end))
end

local DICT_INVENTORY_TYPES = { Weapons = true, Pets = true, Materials = true }

if ChangeInventoryItem then
    track(ChangeInventoryItem.OnClientEvent:Connect(function(itemType, id, amount)
        if not ProfileData or not ProfileData[itemType] then return end
        if DICT_INVENTORY_TYPES[itemType] then
            ProfileData[itemType].Owned[id] = amount
        elseif amount ~= nil and amount > 0 then
            table.insert(ProfileData[itemType].Owned, id)
        end
    end))
end

local function countOwned(owned)
    if not owned then return 0 end
    local n = 0
    for _ in pairs(owned) do n = n + 1 end
    return n
end

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'mm2',
    SubTitle = 'assist',
    Folder = 'MM2Assist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(210, 45, 45),
})

local ProfileTab = Window:Tab({ Title = 'profile', Icon = 'user' })

local EconomySection = ProfileTab:Section({ Title = 'economy', Side = 'left' })
local CoinsStat = EconomySection:Stat({ Title = 'coins', Value = '-' })
local GemsStat = EconomySection:Stat({ Title = 'gems', Value = '-' })
local PrestigeStat = EconomySection:Stat({ Title = 'prestige', Value = '-' })
EconomySection:Button({ Title = 'refresh', Callback = fetchProfileData })

local LevelSection = ProfileTab:Section({ Title = 'level', Side = 'right' })
local LevelStat = LevelSection:Stat({ Title = 'level', Value = '-' })
local XPBar = LevelSection:Progress({ Title = 'xp to next level', Percent = true })

local InventorySection = ProfileTab:Section({ Title = 'inventory', Side = 'left' })
local WeaponsStat = InventorySection:Stat({ Title = 'weapons owned', Value = '-' })
local PetsStat = InventorySection:Stat({ Title = 'pets owned', Value = '-' })
local MaterialsStat = InventorySection:Stat({ Title = 'materials owned', Value = '-' })

local function refreshDashboard()
    if not ProfileData then return end

    CoinsStat:Set(tostring(ProfileData.Coins or 0))
    GemsStat:Set(tostring(ProfileData.Gems or 0))
    PrestigeStat:Set(tostring(ProfileData.Prestige or 0))

    local xp = ProfileData.NewXP or 0
    if LevelModule then
        local ok, level = pcall(LevelModule.GetLevel, xp)
        if ok then LevelStat:Set(tostring(level)) end
        local ok2, progress = pcall(LevelModule.GetProgressToNextLevel, xp)
        if ok2 and typeof(progress) == "number" then
            XPBar:Set(math.clamp(progress, 0, 1) * 100)
        end
    else
        LevelStat:Set('n/a')
    end

    WeaponsStat:Set(tostring(countOwned(ProfileData.Weapons and ProfileData.Weapons.Owned)))
    PetsStat:Set(tostring(countOwned(ProfileData.Pets and ProfileData.Pets.Owned)))
    MaterialsStat:Set(tostring(countOwned(ProfileData.Materials and ProfileData.Materials.Owned)))
end

task.spawn(function()
    while not Unloading do
        task.wait(0.5)
        pcall(refreshDashboard)
    end
end)

local Aim = {
    SilentAim = false,
    WallCheck = true,
    AimPart = "Head",
    MaxRange = 300,
    FOVEnabled = false,
    FOVRadius = 200,
    FOVFollowMouse = true,
    OffScreen = false,
    Predict = true,
    UsePing = true,
    AutoPredict = true,
    AutoLevel = 'Normal',
    ManualLeadTimeGun = 0.05,
    ManualLeadTimeKnife = 0.15,
    KnifeSpeed = 96,
    JumpAware = true,
    Method = 'Delay + travel',
    MathMethod = 'Circular',
    BulletSpeed = 400,
}

local AUTO_LEVELS = {
    Lesser   = { rate = 0.10, delayMin = 0, delayMax = 0.8, smooth = 0.35, passes = 1 },
    Normal   = { rate = 0.18, delayMin = 0, delayMax = 1.3, smooth = 0.50, passes = 2 },
    Extra    = { rate = 0.26, delayMin = 0, delayMax = 1.8, smooth = 0.60, passes = 2 },
    Advanced = { rate = 0.34, delayMin = 0, delayMax = 2.2, smooth = 0.70, passes = 3 },
    Best     = { rate = 0.45, delayMin = 0, delayMax = 2.5, smooth = 0.80, passes = 3 },
}

local AIM_METHODS = { 'Delay + travel', 'Delay only', 'Travel only', 'Ping only' }
local MATH_METHODS = {
    'Circular',
    'Circle fit',
    'Orbit',
    'Spiral',
    'Arc jerk',
    'Decay arc',
    'Tight arc',
    'Steady arc',
    'Arc blend',
    'Arc capped',
    'Arc strafe',
    'Reverse arc',
    'Adaptive arc',
    'Curve',
    'Linear',
    'Acceleration',
    'Jerk',
    'Damped',
    'Raw',
    'Average',
    'Median',
    'Displacement',
    'Facing',
    'Strafe',
    'Capped',
    'Blend',
    'Conservative',
    'Aggressive',
    'Adaptive',
}
local GUN_SEED_DELAY = 0.6
local KNIFE_SEED_DELAY = 0.25
local MAX_TRAVEL_TIME = 2.5
local MAX_LEAD_OFFSET = 50
local MAX_VERTICAL_RISE = 2
local MAX_VERTICAL_DROP = 12
local LEARN_MIN_LEAD = 0.75
local MAX_PENDING = 24
local JUMP_SPAM_WINDOW = 3
local JUMP_SPAM_COUNT = 3
local SAMPLE_STALE = 0.5
local HISTORY_LIMIT = 14
local HISTORY_WINDOW = 0.7
local MIN_TURN_RATE = 0.05
local MIN_TURN_RADIUS = 2.5
local MAX_TURN_RADIUS = 400
local TURN_DECAY = 0.45

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.IgnoreWater = true

local function clearPath(origin, target, char)
    if not Aim.WallCheck then return true end
    visionParams.FilterDescendantsInstances = { LocalPlayer.Character, char }
    local direction = target - origin
    local ok, result = pcall(function() return Workspace:Raycast(origin, direction, visionParams) end)
    if not ok then return true end
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

local function screenAnchor()
    if Aim.FOVFollowMouse then
        return UserInputService:GetMouseLocation()
    end
    local viewport = Camera.ViewportSize
    return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

local function getPing()
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and typeof(ping) == "number" and ping > 0 then return ping end
    return 0.08
end

local function gravity()
    local ok, value = pcall(function() return Workspace.Gravity end)
    if ok and typeof(value) == "number" and value > 0 then return value end
    return 196.2
end

local motion = {}

local function flatten(vector)
    local flat = Vector3.new(vector.X, 0, vector.Z)
    if flat.Magnitude < 0.001 then return Vector3.new(0, 0, 1) end
    return flat.Unit
end

local function humanoidState(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil, false end
    local ok, state = pcall(function() return hum:GetState() end)
    local airborne = ok and (state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.FallingDown)
    return hum, airborne and true or false
end

local function jumpLaunchVelocity(hum)
    local ok, useJumpPower = pcall(function() return hum.UseJumpPower end)
    if ok and useJumpPower then
        local ok2, power = pcall(function() return hum.JumpPower end)
        if ok2 and typeof(power) == "number" and power > 0 then return power end
        return nil
    end
    local ok3, height = pcall(function() return hum.JumpHeight end)
    if ok3 and typeof(height) == "number" and height > 0 then
        return math.sqrt(2 * gravity() * height)
    end
    return nil
end

local function feetOffset(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local ok, hip = pcall(function() return hum and hum.HipHeight end)
    if ok and typeof(hip) == "number" and hip > 0 then
        return hip + 0.5
    end
    return 2.5
end

local function sampleMotion(plr, root, now)
    local name = plr.Name
    local entry = motion[name]
    local position = root.Position
    local hum, airborne = humanoidState(plr.Character)

    if not entry then
        entry = {
            position = position,
            time = now,
            horizontal = Vector3.zero,
            vertical = 0,
            raw = Vector3.zero,
            accel = Vector3.zero,
            jerk = Vector3.zero,
            turnRate = 0,
            steady = 1,
            facing = flatten(root.CFrame.LookVector),
            walkSpeed = 16,
            speedCheck = 0,
            history = {},
            groundY = position.Y,
            airborne = airborne,
            jumps = {},
            jumpStart = nil,
            jumpFromY = position.Y,
            jumpLaunchV = nil,
            jumpElapsed = 0,
        }
        motion[name] = entry
        return entry
    end

    local dt = now - entry.time
    if dt > 0 and dt < SAMPLE_STALE then
        local delta = position - entry.position
        local rawHorizontal = Vector3.new(delta.X, 0, delta.Z) / dt
        local rawVertical = delta.Y / dt
        local settings = AUTO_LEVELS[Aim.AutoLevel] or AUTO_LEVELS.Normal
        local previous = entry.horizontal

        entry.raw = rawHorizontal
        entry.horizontal = previous:Lerp(rawHorizontal, settings.smooth)
        entry.vertical = entry.vertical + (rawVertical - entry.vertical) * 0.65

        local previousAccel = entry.accel
        local accel = (entry.horizontal - previous) / dt
        entry.accel = entry.accel:Lerp(accel, 0.4)
        entry.jerk = entry.jerk:Lerp((entry.accel - previousAccel) / dt, 0.25)

        if previous.Magnitude > 1 and entry.horizontal.Magnitude > 1 then
            local a, b = previous.Unit, entry.horizontal.Unit
            local dot = math.clamp(a:Dot(b), -1, 1)
            local cross = a.X * b.Z - a.Z * b.X
            local turn = math.atan2(cross, dot) / dt
            entry.turnRate = entry.turnRate + (turn - entry.turnRate) * 0.35
            entry.steady = entry.steady + (math.max(dot, 0) - entry.steady) * 0.3
        else
            entry.turnRate = entry.turnRate * 0.8
            entry.steady = entry.steady + (1 - entry.steady) * 0.1
        end

        table.insert(entry.history, { v = rawHorizontal, p = position, t = now })
        while #entry.history > HISTORY_LIMIT or (entry.history[1] and now - entry.history[1].t > HISTORY_WINDOW) do
            table.remove(entry.history, 1)
        end
    elseif dt >= SAMPLE_STALE then
        entry.horizontal = Vector3.zero
        entry.raw = Vector3.zero
        entry.accel = Vector3.zero
        entry.jerk = Vector3.zero
        entry.turnRate = 0
        entry.vertical = 0
        entry.steady = 1
        table.clear(entry.history)
    end

    entry.facing = flatten(root.CFrame.LookVector)
    if now - entry.speedCheck > 0.5 then
        entry.speedCheck = now
        local okSpeed, speed = pcall(function() return hum and hum.WalkSpeed end)
        if okSpeed and typeof(speed) == "number" and speed > 0 then
            entry.walkSpeed = speed
        end
    end

    if airborne and not entry.airborne then
        table.insert(entry.jumps, now)
        entry.jumpStart = now
        entry.jumpFromY = entry.position.Y
        entry.jumpLaunchV = hum and jumpLaunchVelocity(hum) or nil
    end
    while entry.jumps[1] and now - entry.jumps[1] > JUMP_SPAM_WINDOW do
        table.remove(entry.jumps, 1)
    end

    if airborne and entry.jumpStart then
        entry.jumpElapsed = now - entry.jumpStart
    end

    if not airborne then
        entry.groundY = position.Y
        entry.jumpStart = nil
        entry.jumpLaunchV = nil
    end

    entry.airborne = airborne
    entry.position = position
    entry.time = now
    return entry
end

local function isSpamJumper(entry)
    return #entry.jumps >= JUMP_SPAM_COUNT
end

local LEAD_MATH = {}

local function historyAt(entry, index)
    return entry.history and entry.history[index] or nil
end

local function medianOf(values)
    table.sort(values)
    local count = #values
    if count == 0 then return 0 end
    if count % 2 == 1 then return values[(count + 1) / 2] end
    return (values[count / 2] + values[count / 2 + 1]) * 0.5
end

local function perpOf(forward)
    return Vector3.new(-forward.Z, 0, forward.X)
end

local function arcDisplacement(forward, speed, omega, t)
    if math.abs(omega) < MIN_TURN_RATE or math.abs(speed) < 0.25 then
        return forward * (speed * t)
    end
    local radius = speed / omega
    local angle = omega * t
    return forward * (radius * math.sin(angle))
        + perpOf(forward) * (radius * (1 - math.cos(angle)))
end

local function rotateAbout(offset, angle)
    local cos, sin = math.cos(angle), math.sin(angle)
    return Vector3.new(
        offset.X * cos - offset.Z * sin,
        0,
        offset.X * sin + offset.Z * cos)
end

local function fitCircle(entry)
    local history = entry.history
    local count = history and #history or 0
    if count < 5 then return nil end

    local first = history[1]
    local middle = history[math.floor((count + 1) / 2)]
    local last = history[count]
    local span = last.t - first.t
    if span < 0.12 then return nil end

    local origin = last.p
    local ax, az = first.p.X - origin.X, first.p.Z - origin.Z
    local bx, bz = middle.p.X - origin.X, middle.p.Z - origin.Z

    local d = 2 * (ax * bz - bx * az)
    if math.abs(d) < 1e-4 then return nil end

    local aSq = ax * ax + az * az
    local bSq = bx * bx + bz * bz
    local cx = (aSq * bz - bSq * az) / d
    local cz = (bSq * ax - aSq * bx) / d

    local radius = math.sqrt(cx * cx + cz * cz)
    if radius < MIN_TURN_RADIUS or radius > MAX_TURN_RADIUS then return nil end

    local center = Vector3.new(origin.X + cx, 0, origin.Z + cz)
    local toStart = Vector3.new(first.p.X - center.X, 0, first.p.Z - center.Z)
    local toEnd = Vector3.new(origin.X - center.X, 0, origin.Z - center.Z)
    if toStart.Magnitude < 0.001 or toEnd.Magnitude < 0.001 then return nil end

    local startUnit, endUnit = toStart.Unit, toEnd.Unit
    local dot = math.clamp(startUnit:Dot(endUnit), -1, 1)
    local cross = startUnit.X * endUnit.Z - startUnit.Z * endUnit.X
    local swept = math.atan2(cross, dot)
    local omega = swept / span
    if math.abs(omega) < MIN_TURN_RATE then return nil end

    return center, radius, omega, toEnd
end

LEAD_MATH.Linear = function(entry, t)
    return entry.horizontal * t
end

LEAD_MATH.Raw = function(entry, t)
    return entry.raw * t
end

LEAD_MATH.Acceleration = function(entry, t)
    return entry.horizontal * t + entry.accel * (0.5 * t * t)
end

LEAD_MATH.Jerk = function(entry, t)
    return entry.horizontal * t
        + entry.accel * (0.5 * t * t)
        + (entry.jerk or Vector3.zero) * (t * t * t / 6)
end

LEAD_MATH.Curve = function(entry, t)
    local omega = entry.turnRate
    if math.abs(omega) < 0.05 then
        return entry.horizontal * t
    end
    local steps = 4
    local step = t / steps
    local displacement = Vector3.zero
    local velocity = entry.horizontal
    for _ = 1, steps do
        displacement = displacement + velocity * step
        local angle = omega * step
        local cos, sin = math.cos(angle), math.sin(angle)
        velocity = Vector3.new(
            velocity.X * cos - velocity.Z * sin,
            0,
            velocity.X * sin + velocity.Z * cos)
    end
    return displacement
end

LEAD_MATH.Circular = function(entry, t)
    local speed = entry.horizontal.Magnitude
    if speed < 0.5 then return entry.horizontal * t end
    return arcDisplacement(entry.horizontal.Unit, speed, entry.turnRate, t)
end

LEAD_MATH.Spiral = function(entry, t)
    local omega = entry.turnRate
    local speed = entry.horizontal.Magnitude
    if math.abs(omega) < MIN_TURN_RATE or speed < 0.5 then
        return LEAD_MATH.Acceleration(entry, t)
    end

    local forward = entry.horizontal.Unit
    local tangential = entry.accel:Dot(forward)
    local angle = omega * t
    local cos, sin = math.cos(angle), math.sin(angle)

    local along = speed * sin / omega
        + tangential * ((cos - 1) / (omega * omega) + t * sin / omega)
    local across = speed * (1 - cos) / omega
        + tangential * (sin / (omega * omega) - t * cos / omega)

    return forward * along + perpOf(forward) * across
end

LEAD_MATH['Circle fit'] = function(entry, t)
    local center, _, omega, spoke = fitCircle(entry)
    if not center then return LEAD_MATH.Circular(entry, t) end
    return rotateAbout(spoke, omega * t) - spoke
end

LEAD_MATH.Orbit = function(entry, t)
    local center, radius, omega, spoke = fitCircle(entry)
    if not center then return LEAD_MATH.Circular(entry, t) end
    local speed = entry.horizontal.Magnitude
    if speed > 0.5 and radius > 0 then
        local paced = speed / radius
        omega = omega >= 0 and paced or -paced
    end
    return rotateAbout(spoke, omega * t) - spoke
end

LEAD_MATH['Decay arc'] = function(entry, t)
    local omega = entry.turnRate
    local speed = entry.horizontal.Magnitude
    if math.abs(omega) < MIN_TURN_RATE or speed < 0.5 then
        return entry.horizontal * t
    end

    local forward = entry.horizontal.Unit
    local side = perpOf(forward)
    local steps = 6
    local step = t / steps
    local displacement = Vector3.zero
    for index = 1, steps do
        local mid = (index - 0.5) * step
        local heading = omega * TURN_DECAY * (1 - math.exp(-mid / TURN_DECAY))
        displacement = displacement
            + (forward * math.cos(heading) + side * math.sin(heading)) * (speed * step)
    end
    return displacement
end

LEAD_MATH['Tight arc'] = function(entry, t)
    local speed = entry.horizontal.Magnitude
    local omega = entry.turnRate
    if speed < 0.5 then return entry.horizontal * t end
    if math.abs(omega) >= MIN_TURN_RATE then
        local radius = speed / omega
        if math.abs(radius) < MIN_TURN_RADIUS then
            omega = radius >= 0 and (speed / MIN_TURN_RADIUS) or -(speed / MIN_TURN_RADIUS)
        end
    end
    return arcDisplacement(entry.horizontal.Unit, speed, omega, t)
end

LEAD_MATH['Steady arc'] = function(entry, t)
    local history = entry.history
    if not history or #history < 3 then return LEAD_MATH.Circular(entry, t) end
    local sum = Vector3.zero
    for _, sample in ipairs(history) do
        sum = sum + sample.v
    end
    local mean = sum / #history
    local speed = mean.Magnitude
    if speed < 0.5 then return entry.horizontal * t end
    return arcDisplacement(mean.Unit, speed, entry.turnRate, t)
end

LEAD_MATH['Arc blend'] = function(entry, t)
    local steady = math.clamp(entry.steady or 1, 0, 1)
    return (entry.horizontal * t):Lerp(LEAD_MATH.Circular(entry, t), steady)
end

LEAD_MATH['Arc capped'] = function(entry, t)
    local speed = entry.horizontal.Magnitude
    if speed < 0.5 then return entry.horizontal * t end
    local ceiling = (entry.walkSpeed or 16) * 1.15
    if speed > ceiling then speed = ceiling end
    return arcDisplacement(entry.horizontal.Unit, speed, entry.turnRate, t)
end

LEAD_MATH['Reverse arc'] = function(entry, t)
    local speed = entry.horizontal.Magnitude
    if speed < 0.5 then return entry.horizontal * t end
    return arcDisplacement(entry.horizontal.Unit, speed, -entry.turnRate, t)
end

LEAD_MATH['Arc strafe'] = function(entry, t)
    local facing = entry.facing
    if not facing then return LEAD_MATH.Circular(entry, t) end
    local speed = entry.horizontal:Dot(facing)
    if math.abs(speed) < 0.5 then return Vector3.zero end
    return arcDisplacement(facing, speed, entry.turnRate, t)
end

LEAD_MATH['Arc jerk'] = function(entry, t)
    local base = LEAD_MATH.Spiral(entry, t)
    local jerk = entry.jerk or Vector3.zero
    return base + jerk * (t * t * t / 6)
end

LEAD_MATH.Damped = function(entry, t)
    local tau = 0.6
    return entry.horizontal * (tau * (1 - math.exp(-t / tau)))
end

LEAD_MATH.Average = function(entry, t)
    local history = entry.history
    if not history or #history == 0 then
        return entry.horizontal * t
    end
    local sum = Vector3.zero
    for _, sample in ipairs(history) do
        sum = sum + sample.v
    end
    return (sum / #history) * t
end

LEAD_MATH.Median = function(entry, t)
    local history = entry.history
    if not history or #history < 3 then
        return entry.horizontal * t
    end
    local xs, zs = {}, {}
    for index, sample in ipairs(history) do
        xs[index] = sample.v.X
        zs[index] = sample.v.Z
    end
    return Vector3.new(medianOf(xs), 0, medianOf(zs)) * t
end

LEAD_MATH.Displacement = function(entry, t)
    local first = historyAt(entry, 1)
    local last = historyAt(entry, entry.history and #entry.history or 0)
    if not first or not last then
        return entry.horizontal * t
    end
    local span = last.t - first.t
    if span < 0.05 then
        return entry.horizontal * t
    end
    local delta = last.p - first.p
    return Vector3.new(delta.X, 0, delta.Z) * (t / span)
end

LEAD_MATH.Facing = function(entry, t)
    local facing = entry.facing
    if not facing then
        return entry.horizontal * t
    end
    local speed = entry.horizontal.Magnitude
    if speed < 0.5 then
        return Vector3.zero
    end
    return facing * (speed * t)
end

LEAD_MATH.Strafe = function(entry, t)
    local facing = entry.facing
    if not facing then
        return entry.horizontal * t
    end
    local along = facing * entry.horizontal:Dot(facing)
    local lateral = entry.horizontal - along
    return (along + lateral * 0.35) * t
end

LEAD_MATH.Capped = function(entry, t)
    local velocity = entry.horizontal
    local speed = velocity.Magnitude
    local ceiling = (entry.walkSpeed or 16) * 1.15
    if speed > ceiling and speed > 0.001 then
        velocity = velocity.Unit * ceiling
    end
    return velocity * t
end

LEAD_MATH.Blend = function(entry, t)
    local steady = math.clamp(entry.steady or 1, 0, 1)
    local linear = entry.horizontal * t
    local curved = entry.horizontal * t + entry.accel * (0.5 * t * t)
    return linear:Lerp(curved, steady)
end

LEAD_MATH.Conservative = function(entry, t)
    return entry.horizontal * (t * 0.6)
end

LEAD_MATH.Aggressive = function(entry, t)
    return entry.horizontal * (t * 1.25) + entry.accel * (0.5 * t * t)
end

LEAD_MATH.Adaptive = function(entry, t)
    if math.abs(entry.turnRate) > 1.2 then
        return LEAD_MATH.Circular(entry, t)
    end
    if entry.accel.Magnitude > 40 then
        return LEAD_MATH.Acceleration(entry, t)
    end
    if (entry.steady or 1) < 0.35 then
        return LEAD_MATH.Damped(entry, t)
    end
    return LEAD_MATH.Linear(entry, t)
end

LEAD_MATH['Adaptive arc'] = function(entry, t)
    local steady = entry.steady or 1
    local speed = entry.horizontal.Magnitude

    if speed < 0.5 then return Vector3.zero end
    if steady < 0.3 then return LEAD_MATH['Arc blend'](entry, t) end

    local center = fitCircle(entry)
    if center and steady > 0.55 then
        return LEAD_MATH.Orbit(entry, t)
    end

    if math.abs(entry.accel:Dot(entry.horizontal.Unit)) > 25 then
        return LEAD_MATH.Spiral(entry, t)
    end
    if t > 0.8 then
        return LEAD_MATH['Decay arc'](entry, t)
    end
    if speed > (entry.walkSpeed or 16) * 1.4 then
        return LEAD_MATH['Arc capped'](entry, t)
    end
    return LEAD_MATH['Tight arc'](entry, t)
end

local function horizontalLead(entry, t)
    local solver = LEAD_MATH[Aim.MathMethod] or LEAD_MATH.Linear
    return solver(entry, t)
end

local function predictRoot(entry, travelTime)
    local base = entry.position
    if not Aim.Predict or travelTime <= 0 then
        return base
    end

    local horizontal = horizontalLead(entry, travelTime)
    if horizontal.Magnitude > MAX_LEAD_OFFSET then
        horizontal = horizontal.Unit * MAX_LEAD_OFFSET
    end

    local y = base.Y
    if Aim.JumpAware then
        if entry.airborne then
            local g = gravity()
            if entry.jumpLaunchV then
                local t = entry.jumpElapsed + travelTime
                y = entry.jumpFromY + entry.jumpLaunchV * t - 0.5 * g * t * t
            else
                y = base.Y + entry.vertical * travelTime - 0.5 * g * travelTime * travelTime
            end
        end
    elseif entry.airborne then
        y = base.Y + entry.vertical * travelTime
    end

    if y > base.Y + MAX_VERTICAL_RISE then
        y = base.Y + MAX_VERTICAL_RISE
    end
    if y < base.Y - MAX_VERTICAL_DROP then
        y = base.Y - MAX_VERTICAL_DROP
    end
    if entry.groundY and base.Y >= entry.groundY and y < entry.groundY then
        y = entry.groundY
    end

    return Vector3.new(base.X + horizontal.X, y, base.Z + horizontal.Z)
end

local function newLeadState(seed)
    return { delay = seed, pending = {}, verified = 0 }
end

local GunLead = newLeadState(GUN_SEED_DELAY)
local KnifeLead = newLeadState(KNIFE_SEED_DELAY)

local function methodUsesDelay()
    return Aim.Method == 'Delay + travel' or Aim.Method == 'Delay only'
end

local function methodUsesTravel()
    return Aim.Method == 'Delay + travel' or Aim.Method == 'Travel only'
end

local function travelTimeFor(state, distance, weaponSpeed, pingComponent)
    local total = pingComponent
    if methodUsesDelay() then
        total = total + state.delay
    end
    if methodUsesTravel() then
        total = total + distance / math.max(weaponSpeed, 1)
    end
    return math.min(total, MAX_TRAVEL_TIME)
end

local function verifyLead(state, settings, now)
    local pending = state.pending
    local index = 1
    while index <= #pending do
        local record = pending[index]
        if now < record.dueAt then
            index = index + 1
        else
            local entry = record.entry
            local lead = record.lead
            local length = lead.Magnitude
            if entry and length >= LEARN_MIN_LEAD and record.learnable and (now - entry.time) < SAMPLE_STALE then
                local actual = Vector3.new(entry.position.X, 0, entry.position.Z)
                local predicted = Vector3.new(record.root.X, 0, record.root.Z)
                local drift = (actual - predicted):Dot(lead.Unit)
                local timeError = drift / math.max(record.speed, 1)
                state.delay = math.clamp(state.delay + timeError * settings.rate, settings.delayMin, settings.delayMax)
                state.verified = state.verified + 1
            end
            table.remove(pending, index)
        end
    end
end

local function logLead(state, entry, predictedRoot, travelTime, now)
    local lead = Vector3.new(predictedRoot.X - entry.position.X, 0, predictedRoot.Z - entry.position.Z)
    if lead.Magnitude < LEARN_MIN_LEAD or #state.pending >= MAX_PENDING then return end
    table.insert(state.pending, {
        dueAt = now + travelTime,
        entry = entry,
        root = predictedRoot,
        lead = lead,
        speed = entry.horizontal.Magnitude,
        learnable = not entry.airborne and not isSpamJumper(entry),
    })
end

local autoSummary = 'idle'

local function aimPartFor(char, entry)
    local preferred = Aim.AimPart
    if Aim.AutoPredict and Aim.JumpAware and preferred == "Head" and entry and isSpamJumper(entry) then
        preferred = "HumanoidRootPart"
    end
    return char:FindFirstChild(preferred) or char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
end

local function candidateScreenDist(part, anchor, origin)
    if (part.Position - origin).Magnitude > Aim.MaxRange then return nil end

    local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
    if not onScreen then
        if not Aim.OffScreen then return nil end
        local look = Camera.CFrame.LookVector
        local toward = part.Position - origin
        if toward.Magnitude < 0.01 then return nil end
        local angle = math.deg(math.acos(math.clamp(look.Unit:Dot(toward.Unit), -1, 1)))
        local viewport = Camera.ViewportSize
        return viewport.Magnitude + angle
    end

    local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - anchor).Magnitude
    if Aim.FOVEnabled and screenDist > Aim.FOVRadius then return nil end
    return screenDist
end

local function isMurderer(plr)
    local role, dead = roleOf(plr)
    return role == "Murderer" and not dead
end

local function scanTarget(filterFn)
    local origin = Camera.CFrame.Position
    local anchor = screenAnchor()

    local candidates = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) and (not filterFn or filterFn(plr)) then
            local char = plr.Character
            local part = char and aimPartFor(char, motion[plr.Name])
            if part then
                local screenDist = candidateScreenDist(part, anchor, origin)
                if screenDist then
                    candidates[#candidates + 1] = { plr = plr, char = char, part = part, screenDist = screenDist }
                end
            end
        end
    end

    if #candidates == 0 then return nil, nil, nil end

    table.sort(candidates, function(a, b) return a.screenDist < b.screenDist end)

    for _, candidate in ipairs(candidates) do
        if clearPath(origin, candidate.part.Position, candidate.char) then
            return candidate.plr, candidate.part, candidate.char
        end
    end

    local nearest = candidates[1]
    return nearest.plr, nearest.part, nearest.char
end

local knifeSpeedSlider = nil

local function onThrowingKnifeAdded(instance)
    local ok, speed = pcall(function() return instance:GetAttribute("ThrowSpeed") end)
    if ok and typeof(speed) == "number" and speed > 1 and speed ~= Aim.KnifeSpeed then
        Aim.KnifeSpeed = speed
        if knifeSpeedSlider then
            pcall(function() knifeSpeedSlider:Set(speed) end)
        end
    end
end

track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(onThrowingKnifeAdded))
for _, instance in ipairs(CollectionService:GetTagged("ThrowingKnife")) do
    task.spawn(onThrowingKnifeAdded, instance)
end

local cachedGunRedirect = nil
local cachedKnifeRedirect = nil
local cachedPing = 0.08

local function findGunOrigin()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local attachment = root and root:FindFirstChild("GunRaycastAttachment")
    return attachment and attachment.WorldPosition
end

local function findKnifeOrigin()
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChild("Knife")
    local handle = tool and tool:FindFirstChild("Handle")
    return handle and handle.Position
end

local function solveAim(entry, part, root, char, origin, isKnife, now, settings)
    local offset = part.Position - root.Position
    if Aim.JumpAware and entry.airborne then
        offset = Vector3.new(offset.X, -feetOffset(char), offset.Z)
    end

    if not Aim.Predict then
        return root.Position + offset
    end

    if not Aim.AutoPredict then
        local travelTime = isKnife and Aim.ManualLeadTimeKnife or Aim.ManualLeadTimeGun
        return predictRoot(entry, travelTime) + offset
    end

    local pingComponent = Aim.UsePing and (cachedPing / 2) or 0
    local state = isKnife and KnifeLead or GunLead
    local weaponSpeed = isKnife and Aim.KnifeSpeed or Aim.BulletSpeed

    local travelTime = travelTimeFor(state, (part.Position - origin).Magnitude, weaponSpeed, pingComponent)
    local predicted = predictRoot(entry, travelTime)
    for _ = 2, settings.passes do
        travelTime = travelTimeFor(state, ((predicted + offset) - origin).Magnitude, weaponSpeed, pingComponent)
        predicted = predictRoot(entry, travelTime)
    end

    if methodUsesDelay() then
        logLead(state, entry, predicted, travelTime, now)
    end
    return predicted + offset
end

track(PreSimulation:Connect(function()
    if Unloading or not Aim.SilentAim then
        cachedGunRedirect, cachedKnifeRedirect = nil, nil
        return
    end

    local ok = pcall(function()
        local now = os.clock()
        cachedPing = getPing()
        local settings = AUTO_LEVELS[Aim.AutoLevel] or AUTO_LEVELS.Normal

        if Aim.AutoPredict then
            verifyLead(GunLead, settings, now)
            verifyLead(KnifeLead, settings, now)
            autoSummary = ('gun %.2fs (%d)  knife %.2fs (%d)')
                :format(GunLead.delay, GunLead.verified, KnifeLead.delay, KnifeLead.verified)
        end

        local gPlr, gPart, gChar = scanTarget(isMurderer)
        local gEntry, gRoot = nil, nil
        if gPlr and gPart and gChar then
            gRoot = gChar:FindFirstChild("HumanoidRootPart")
            if gRoot then gEntry = sampleMotion(gPlr, gRoot, now) end
        end

        local kPlr, kPart, kChar = scanTarget(nil)
        local kEntry, kRoot = nil, nil
        if kPlr and kPart and kChar then
            kRoot = kChar:FindFirstChild("HumanoidRootPart")
            if kRoot then kEntry = sampleMotion(kPlr, kRoot, now) end
        end

        local gunOrigin = findGunOrigin()
        if not gunOrigin or not gEntry then
            cachedGunRedirect = nil
        else
            local aim = solveAim(gEntry, gPart, gRoot, gChar, gunOrigin, false, now, settings)
            cachedGunRedirect = clearPath(gunOrigin, aim, gChar) and CFrame.new(aim) or nil
        end

        local knifeOrigin = findKnifeOrigin()
        if not knifeOrigin or not kEntry then
            cachedKnifeRedirect = nil
        else
            local aim = solveAim(kEntry, kPart, kRoot, kChar, knifeOrigin, true, now, settings)
            cachedKnifeRedirect = clearPath(knifeOrigin, aim, kChar) and CFrame.new(aim) or nil
        end
    end)

    if not ok then
        cachedGunRedirect, cachedKnifeRedirect = nil, nil
    end
end))

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall

    local function onNamecall(self, ...)
        if Unloading or not Aim.SilentAim or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
            return originalNamecall(self, ...)
        end

        if self.Name == "Shoot" and self.ClassName == "RemoteEvent" and cachedGunRedirect then
            local parent = self.Parent
            if parent and parent.ClassName == "Tool" and parent.Name == "Gun" then
                local origin = ...
                if typeof(origin) == "CFrame" then
                    return originalNamecall(self, origin, cachedGunRedirect)
                end
            end
        elseif self.Name == "KnifeThrown" and cachedKnifeRedirect then
            local events = self.Parent
            local tool = events and events.Parent
            if events and events.Name == "Events" and tool and tool.ClassName == "Tool" and tool.Name == "Knife" then
                local handle = ...
                if typeof(handle) == "CFrame" then
                    return originalNamecall(self, handle, cachedKnifeRedirect)
                end
            end
        end

        return originalNamecall(self, ...)
    end

    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end

    originalNamecall = hookmetamethod(game, "__namecall", onNamecall)
end

local SilentAimTab = Window:Tab({ Title = 'silent aim', Icon = 'crosshair' })

local AimSection = SilentAimTab:Section({ Title = 'aim', Side = 'left' })

AimSection:Stat({
    Title = 'hook api',
    Value = hasNamecallHook and 'available' or 'missing',
    Color = hasNamecallHook and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
})

AimSection:Toggle({
    Title = 'silent aim',
    Desc = 'gun redirects only to the murderer, knife to the nearest valid target. your click, animation and the real origin stay as fired',
    Flag = 'mm2_silent_aim',
    Callback = function(state)
        if state and not hasNamecallHook then
            Centrl:Notify({
                Title = 'mm2',
                Content = 'hookmetamethod/getnamecallmethod not available on this executor.',
                Type = 'error',
                Duration = 6,
            })
        end
        Aim.SilentAim = state
    end,
})

AimSection:Dropdown({
    Title = 'aim part',
    Values = { 'Head', 'HumanoidRootPart' },
    Default = 'Head',
    Flag = 'mm2_silent_aim_part',
    Callback = function(value) Aim.AimPart = value end,
})

AimSection:Toggle({
    Title = 'wall check',
    Desc = 'prefers a clear camera sightline when ranking, requires one from the real muzzle before redirecting',
    Flag = 'mm2_silent_aim_wallcheck',
    Default = true,
    Callback = function(state) Aim.WallCheck = state end,
})

AimSection:Slider({
    Title = 'max range',
    Min = 25,
    Max = 300,
    Increment = 5,
    Default = 300,
    Suffix = ' studs',
    Flag = 'mm2_silent_aim_range',
    Callback = function(value) Aim.MaxRange = value end,
})

knifeSpeedSlider = AimSection:Slider({
    Title = 'knife speed',
    Desc = 'starts at the real default and self-corrects the moment any knife is seen flying',
    Min = 40,
    Max = 300,
    Increment = 5,
    Default = Aim.KnifeSpeed,
    Suffix = ' studs/s',
    Flag = 'mm2_silent_aim_knife_speed',
    Callback = function(value) Aim.KnifeSpeed = value end,
})

local FovSection = SilentAimTab:Section({ Title = 'fov', Side = 'right' })

FovSection:Toggle({
    Title = 'fov limit',
    Desc = 'off means the whole screen is fair game - anything visible can be targeted. on restricts it to the radius below',
    Flag = 'mm2_silent_aim_fov',
    Default = false,
    Callback = function(state) Aim.FOVEnabled = state end,
})

FovSection:Slider({
    Title = 'fov radius',
    Desc = 'only used while fov limit is on',
    Min = 20,
    Max = 600,
    Increment = 10,
    Default = 200,
    Flag = 'mm2_silent_aim_fov_radius',
    Callback = function(value) Aim.FOVRadius = value end,
})

FovSection:Toggle({
    Title = 'follow mouse',
    Flag = 'mm2_silent_aim_follow_mouse',
    Default = true,
    Callback = function(state) Aim.FOVFollowMouse = state end,
})

FovSection:Toggle({
    Title = 'off screen targets',
    Desc = 'also allows targets that are off screen entirely, including behind you, ranked by angle from where the camera points. on screen targets always take priority',
    Flag = 'mm2_silent_aim_offscreen',
    Default = false,
    Callback = function(state) Aim.OffScreen = state end,
})

local PredictionSection = SilentAimTab:Section({ Title = 'prediction', Side = 'right' })

PredictionSection:Toggle({
    Title = 'predict movement',
    Desc = 'master switch. off aims exactly where the target is right now',
    Flag = 'mm2_silent_aim_predict',
    Default = true,
    Callback = function(state) Aim.Predict = state end,
})

PredictionSection:Toggle({
    Title = 'jump aware',
    Desc = 'solves a jumping target as a real arc under gravity instead of extrapolating their vertical speed in a straight line, aims at their feet rather than head/torso while airborne so a slightly-off vertical read still lands, and drops head aim to torso against repeat jumpers',
    Flag = 'mm2_silent_aim_jump',
    Default = true,
    Callback = function(state) Aim.JumpAware = state end,
})

PredictionSection:Toggle({
    Title = 'use ping',
    Desc = 'adds the one-way latency estimate to lead time',
    Flag = 'mm2_silent_aim_use_ping',
    Default = true,
    Callback = function(state) Aim.UsePing = state end,
})

PredictionSection:Toggle({
    Title = 'auto prediction',
    Desc = 'travel time is distance / a learned speed, so lead grows with range and stays tight up close. scores its own shots against where the target ended up and corrects that learned speed live',
    Flag = 'mm2_silent_aim_auto_predict',
    Default = true,
    Callback = function(state) Aim.AutoPredict = state end,
})

PredictionSection:Dropdown({
    Title = 'auto prediction amount',
    Desc = 'how hard the feedback loop corrects, how far the learned delay is allowed to move, how heavily velocity is smoothed, and how many passes the travel time solves for',
    Values = { 'Lesser', 'Normal', 'Extra', 'Advanced', 'Best' },
    Default = 'Normal',
    Flag = 'mm2_silent_aim_auto_level',
    Callback = function(value) Aim.AutoLevel = value end,
})

PredictionSection:Dropdown({
    Title = 'method',
    Desc = 'delay + travel: a learned constant delay plus distance/speed flight time, the full model. delay only: constant lead everywhere, ignores distance - use when the delay is what matters and range is not. travel only: distance/speed alone, lead scales with range and goes near zero up close. ping only: raw half-ping, effectively no prediction, for comparison',
    Values = AIM_METHODS,
    Default = 'Delay + travel',
    Flag = 'mm2_silent_aim_method',
    Callback = function(value) Aim.Method = value end,
})

PredictionSection:Dropdown({
    Title = 'math',
    Desc = 'how the future position is worked out from their movement. the arc family is listed first. circular: the exact arc for their measured turn rate, no stepping error. circle fit: fits a real circle through three of their past positions and walks them around it, so the arc comes from where they actually went rather than a smoothed turn number. orbit: same fit but paced by their current speed, for someone holding a lap around you. spiral: an arc whose speed is also changing, for a turn taken while accelerating out of it. arc jerk: spiral plus the third order term. decay arc: the turn fades out across the lead, nobody holds a constant turn for a whole second. tight arc: an arc whose radius cannot go below a real player turning circle, so a noisy turn reading cannot produce a silly tight loop. steady arc: the arc driven by the averaged window instead of the latest sample. arc blend: arc and straight line mixed by how consistent their direction has been. arc capped: the arc with speed held to their walkspeed, kills rubberband spikes. arc strafe: the arc along the way they are facing only. reverse arc: assumes they flip the turn, for jukers. adaptive arc: picks from the arc family per target. curve: the old stepped version of circular. then the straight line family - linear, acceleration, jerk, damped, raw, average, median, displacement, facing, strafe, capped, blend, conservative, aggressive, adaptive',
    Values = MATH_METHODS,
    Default = 'Circular',
    Flag = 'mm2_silent_aim_math',
    Callback = function(value) Aim.MathMethod = value end,
})

PredictionSection:Slider({
    Title = 'bullet speed',
    Desc = 'the travel component for the gun. high means the distance part barely adds anything and the learned delay does the work - a fast shot can still land late',
    Min = 50,
    Max = 1500,
    Increment = 10,
    Default = Aim.BulletSpeed,
    Suffix = ' studs/s',
    Flag = 'mm2_silent_aim_bullet_speed',
    Callback = function(value) Aim.BulletSpeed = value end,
})

local AutoStat = PredictionSection:Stat({ Title = 'learned delay', Value = 'idle' })

PredictionSection:Slider({
    Title = 'manual gun lead time',
    Desc = 'used while auto prediction is off - flat, not distance scaled',
    Min = 0,
    Max = 2.5,
    Increment = 0.05,
    Default = Aim.ManualLeadTimeGun,
    Suffix = 's',
    Flag = 'mm2_silent_aim_manual_gun',
    Callback = function(value) Aim.ManualLeadTimeGun = value end,
})

PredictionSection:Slider({
    Title = 'manual knife lead time',
    Desc = 'used while auto prediction is off - flat, not distance scaled',
    Min = 0,
    Max = 3,
    Increment = 0.05,
    Default = Aim.ManualLeadTimeKnife,
    Suffix = 's',
    Flag = 'mm2_silent_aim_manual_knife',
    Callback = function(value) Aim.ManualLeadTimeKnife = value end,
})

local Visual = {
    Esp = false,
    ColorByRole = false,
    RoleEsp = false,
    ShowPerk = false,
    ShowDistance = false,
}

local ROLE_COLORS = {
    Innocent = Color3.fromRGB(0, 255, 0),
    Sheriff = Color3.fromRGB(0, 0, 255),
    Murderer = Color3.fromRGB(255, 0, 0),
    Hero = Color3.fromRGB(255, 196, 60),
    Zombie = Color3.fromRGB(25, 172, 0),
    Survivor = Color3.fromRGB(43, 154, 238),
    Freezer = Color3.fromRGB(150, 220, 250),
    Runner = Color3.fromRGB(0, 200, 100),
}
local NEUTRAL_COLOR = Color3.fromRGB(255, 255, 255)

local espObjects = {}

local function destroyEsp(plr)
    local obj = espObjects[plr]
    if not obj then return end
    if obj.Highlight then obj.Highlight:Destroy() end
    if obj.Billboard then obj.Billboard:Destroy() end
    espObjects[plr] = nil
end

local function buildEsp(plr, char)
    destroyEsp(plr)

    local highlight = Instance.new("Highlight")
    highlight.FillTransparency = 0.5
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = false
    highlight.Parent = char

    local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "MM2Esp"
    billboard.Adornee = head
    billboard.Size = UDim2.fromOffset(220, 38)
    billboard.StudsOffset = Vector3.new(0, 2.4, 0)
    billboard.AlwaysOnTop = true
    billboard.Enabled = false

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextStrokeTransparency = 0.4
    label.Text = ""
    label.Parent = billboard

    billboard.Parent = char

    espObjects[plr] = {
        Char = char,
        Highlight = highlight,
        Billboard = billboard,
        Label = label,
    }
    return espObjects[plr]
end

local function distanceTo(part)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or not part then return nil end
    return (root.Position - part.Position).Magnitude
end

local function updateEsp()
    if not Visual.Esp and not Visual.RoleEsp then
        for plr in pairs(espObjects) do destroyEsp(plr) end
        return
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local obj = espObjects[plr]

            if not char or not isAlivePlr(plr) then
                if obj then destroyEsp(plr) end
            else
                if not obj or obj.Char ~= char or not obj.Highlight.Parent then
                    obj = buildEsp(plr, char)
                end

                if obj then
                    local role, dead = roleOf(plr)
                    local color = (role and ROLE_COLORS[role]) or NEUTRAL_COLOR
                    local espColor = Visual.ColorByRole and not dead and color or NEUTRAL_COLOR

                    obj.Highlight.Enabled = Visual.Esp
                    obj.Highlight.FillColor = espColor
                    obj.Highlight.OutlineColor = espColor

                    local showRole = Visual.RoleEsp and role ~= nil and not dead
                    obj.Billboard.Enabled = showRole
                    if showRole then
                        local text = role
                        if Visual.ShowPerk and role == "Murderer" then
                            local entry = RoundData[plr.Name]
                            if entry and entry.Perk then
                                text = text .. " (" .. tostring(entry.Perk) .. ")"
                            end
                        end
                        if Visual.ShowDistance then
                            local dist = distanceTo(char:FindFirstChild("HumanoidRootPart"))
                            if dist then
                                text = text .. (" [%d]"):format(math.floor(dist))
                            end
                        end
                        obj.Label.Text = text
                        obj.Label.TextColor3 = color
                    end
                end
            end
        end
    end
end

task.spawn(function()
    while not Unloading do
        task.wait(0.15)
        pcall(updateEsp)
    end
end)

track(Players.PlayerRemoving:Connect(function(plr)
    destroyEsp(plr)
    motion[plr.Name] = nil
end))

local Xray = {
    Enabled = false,
    Transparency = 0.5,
    Range = 100,
}

local xrayObjects = {}

local xrayParams = OverlapParams.new()
xrayParams.FilterType = Enum.RaycastFilterType.Exclude

local function xrayRestoreAll()
    for part, original in pairs(xrayObjects) do
        if part and part.Parent then
            pcall(function() part.Transparency = original end)
        end
    end
    table.clear(xrayObjects)
end

local function xrayFilterList()
    local list = {}
    local char = LocalPlayer.Character
    if char then list[#list + 1] = char end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then list[#list + 1] = plr.Character end
    end
    return list
end

task.spawn(function()
    while not Unloading do
        task.wait(0.5)

        if not Xray.Enabled then
            if next(xrayObjects) then xrayRestoreAll() end
        else
            local ok = pcall(function()
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not root then
                    xrayRestoreAll()
                    return
                end

                xrayParams.FilterDescendantsInstances = xrayFilterList()
                local parts = Workspace:GetPartBoundsInRadius(root.Position, Xray.Range, xrayParams)

                local seen = {}
                for _, part in ipairs(parts) do
                    if part:IsA("BasePart") and part.Parent then
                        seen[part] = true
                        if xrayObjects[part] == nil then
                            if part.Transparency == 0 then
                                xrayObjects[part] = 0
                                part.Transparency = Xray.Transparency
                            end
                        elseif part.Transparency ~= Xray.Transparency then
                            part.Transparency = Xray.Transparency
                        end
                    end
                end

                for part, original in pairs(xrayObjects) do
                    if not seen[part] then
                        if part and part.Parent then
                            pcall(function() part.Transparency = original end)
                        end
                        xrayObjects[part] = nil
                    end
                end
            end)

            if not ok then xrayRestoreAll() end
        end
    end
end)

local TrapEsp = { Enabled = false }
local trapObjects = {}

local function isTrapVisual(inst)
    return typeof(inst) == "Instance" and inst.Name == "TrapVisual" and inst:IsA("BasePart")
end

local function destroyTrapEsp(part)
    local hl = trapObjects[part]
    if hl then hl:Destroy() end
    trapObjects[part] = nil
end

local function buildTrapEsp(part)
    if trapObjects[part] then return end
    local hl = Instance.new("Highlight")
    hl.FillColor = Color3.fromRGB(255, 170, 0)
    hl.OutlineColor = Color3.fromRGB(255, 170, 0)
    hl.FillTransparency = 0.3
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = part
    trapObjects[part] = hl
end

local function trapEspRefreshAll()
    for part in pairs(trapObjects) do destroyTrapEsp(part) end
    if not TrapEsp.Enabled then return end
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if isTrapVisual(inst) then buildTrapEsp(inst) end
    end
end

track(Workspace.DescendantAdded:Connect(function(inst)
    if TrapEsp.Enabled and isTrapVisual(inst) then
        buildTrapEsp(inst)
    end
end))

track(Workspace.DescendantRemoving:Connect(function(inst)
    if trapObjects[inst] then destroyTrapEsp(inst) end
end))

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })

local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Desc = 'highlights every other living player',
    Flag = 'mm2_esp',
    Callback = function(state) Visual.Esp = state end,
})

EspSection:Toggle({
    Title = 'color by role',
    Desc = 'colors the highlight by current role instead of a flat white',
    Flag = 'mm2_esp_role_color',
    Callback = function(state) Visual.ColorByRole = state end,
})

local RoleEspSection = VisualTab:Section({ Title = 'role esp', Side = 'right' })

RoleEspSection:Toggle({
    Title = 'role esp',
    Desc = 'shows role above the head while alive and in the round, never on you. a dropped gun being picked up reads as hero the moment it is equipped',
    Flag = 'mm2_role_esp',
    Callback = function(state) Visual.RoleEsp = state end,
})

RoleEspSection:Toggle({
    Title = "show murderer's perk",
    Flag = 'mm2_role_esp_perk',
    Callback = function(state) Visual.ShowPerk = state end,
})

RoleEspSection:Toggle({
    Title = 'show distance',
    Flag = 'mm2_role_esp_distance',
    Callback = function(state) Visual.ShowDistance = state end,
})

local XraySection = VisualTab:Section({ Title = 'xray', Side = 'left' })

XraySection:Toggle({
    Title = 'xray',
    Desc = 'fades opaque parts in range, leaves anything already see-through alone',
    Flag = 'mm2_xray',
    Callback = function(state)
        Xray.Enabled = state
        if not state then xrayRestoreAll() end
    end,
})

XraySection:Slider({
    Title = 'xray transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = Xray.Transparency,
    Flag = 'mm2_xray_transparency',
    Callback = function(value)
        Xray.Transparency = value
        for part in pairs(xrayObjects) do
            if part and part.Parent then
                pcall(function() part.Transparency = value end)
            end
        end
    end,
})

XraySection:Slider({
    Title = 'xray range',
    Min = 20,
    Max = 300,
    Increment = 10,
    Default = Xray.Range,
    Suffix = ' studs',
    Flag = 'mm2_xray_range',
    Callback = function(value) Xray.Range = value end,
})

local TrapSection = VisualTab:Section({ Title = 'traps', Side = 'right' })

TrapSection:Toggle({
    Title = 'trap esp',
    Desc = 'highlights every placed trap',
    Flag = 'mm2_trap_esp',
    Callback = function(state)
        TrapEsp.Enabled = state
        trapEspRefreshAll()
    end,
})

local SessionSection = VisualTab:Section({ Title = 'session', Side = 'right' })

SessionSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end

        for plr in pairs(espObjects) do destroyEsp(plr) end
        for part in pairs(trapObjects) do destroyTrapEsp(part) end
        xrayRestoreAll()

        Centrl:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every hook and loop, restores every part xray touched, clears all esp, then closes the menu. The Shoot/KnifeThrown namecall hook cannot be reversed without rejoining.',
})

task.spawn(function()
    while not Unloading do
        task.wait(0.4)
        pcall(function()
            AutoStat:Set(Aim.SilentAim and Aim.Predict and Aim.AutoPredict and autoSummary or 'off')
        end)
    end
end)

Window:Load()

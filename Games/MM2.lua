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

local function isGunTool(item)
    if not item:IsA("Tool") then return false end
    local tagged = false
    pcall(function() tagged = CollectionService:HasTag(item, "Weapon_Gun") end)
    return item.Name == "Gun" or item:FindFirstChild("IsGun") ~= nil or tagged
end

local function isKnifeTool(item)
    if not item:IsA("Tool") then return false end
    return item.Name == "Knife" or item:FindFirstChild("KnifeClient") ~= nil or item:FindFirstChild("Stab") ~= nil
end

local function heldWeapon(char)
    if not char then return nil end
    for _, item in ipairs(char:GetChildren()) do
        if isGunTool(item) then return "Gun" end
        if isKnifeTool(item) then return "Knife" end
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
    AimPart = "Body",
    MaxRange = 300,
    FOVEnabled = false,
    FOVRadius = 200,
    FOVFollowMouse = true,
    OffScreen = false,
    Predict = true,
    UsePing = true,
    AutoLevel = 'Normal',
    JumpAware = true,
    RedirectChance = 100,
}

local GunTune = { Extra = 0 }
local KnifeTune = { Extra = 0, Speed = 96 }

local Legit = {
    Enabled = false,
    RedirectChance = 65,
    ReactionTime = 0.22,
    Stickiness = 1.2,
    ErrorDegrees = 0.7,
    DriftShare = 0.6,
    MissChance = 18,
    MissSpread = 3.5,
}

local Debug = {
    Enabled = false,
    Markers = true,
}

local cachedPing = 0.08
local cachedFrame = 1 / 60
local lastTick = 0

local shotStats = { seen = 0, redirected = 0, suppressed = 0, proved = 0, error = 0 }
local shotEvents = {}
local lastSolve = {}

local legitDriftX = 0
local legitDriftY = 0
local legitSeen = {}
local legitLock = {}

local AUTO_LEVELS = {
    Lesser   = { smooth = 0.35, passes = 1 },
    Normal   = { smooth = 0.50, passes = 2 },
    Extra    = { smooth = 0.60, passes = 2 },
    Advanced = { smooth = 0.70, passes = 3 },
    Best     = { smooth = 0.80, passes = 3 },
}

local MAX_TRAVEL_TIME = 5
local MAX_LEAD_OFFSET = 50
local MAX_VERTICAL_RISE = 2
local MAX_VERTICAL_DROP = 12
local MAX_PENDING = 24
local JUMP_SPAM_WINDOW = 3
local JUMP_SPAM_COUNT = 3
local SAMPLE_STALE = 0.5
local HISTORY_LIMIT = 14
local HISTORY_WINDOW = 0.7
local MIN_TURN_RATE = 0.05
local MAX_TURN_RATE = 4
local MIN_TURN_RADIUS = 2.5
local MAX_TURN_RADIUS = 400
local TURN_DECAY = 0.45
local MAX_TANGENTIAL = 120
local SPEED_CEILING = 1.6
local TRUST_FLOOR = 0.7
local ARC_STEPS = 6
local PLAN_STALE = 0.25
local TRANSPARENT_SKIPS = 8
local LEGIT_REACQUIRE = 0.4
local DRIFT_STEP = 0.06
local HIT_WINDOW = 0.35
local MAX_CANDIDATES = 5
local PART_ORDER_HEAD = { "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso" }
local PART_ORDER_BODY = { "HumanoidRootPart", "UpperTorso", "Torso", "LowerTorso", "Head" }

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.IgnoreWater = true

local function weaponCast(origin, direction, ignore)
    local filter = { LocalPlayer.Character }
    if ignore then
        for _, extra in ipairs(ignore) do
            filter[#filter + 1] = extra
        end
    end

    for _ = 1, TRANSPARENT_SKIPS do
        visionParams.FilterDescendantsInstances = filter
        local ok, result = pcall(function() return Workspace:Raycast(origin, direction, visionParams) end)
        if not ok or not result then return nil end

        local instance = result.Instance
        if not instance then return result end

        local transparent = false
        pcall(function() transparent = instance.Transparency == 1 end)
        if not transparent then return result end

        filter[#filter + 1] = instance
    end

    return nil
end

local function clearPath(origin, target, char)
    if not Aim.WallCheck then return true end
    local direction = target - origin
    local result = weaponCast(origin, direction, { char })
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
            accel = Vector3.zero,
            turnRate = 0,
            steady = 1,
            walkSpeed = 16,
            speedCheck = 0,
            repLag = 0,
            lastMove = now,
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

        entry.horizontal = previous:Lerp(rawHorizontal, settings.smooth)
        entry.vertical = entry.vertical + (rawVertical - entry.vertical) * 0.65

        local accel = (entry.horizontal - previous) / dt
        entry.accel = entry.accel:Lerp(accel, 0.4)

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

        table.insert(entry.history, { p = position, t = now })
        while #entry.history > HISTORY_LIMIT or (entry.history[1] and now - entry.history[1].t > HISTORY_WINDOW) do
            table.remove(entry.history, 1)
        end
    elseif dt >= SAMPLE_STALE then
        entry.horizontal = Vector3.zero
        entry.accel = Vector3.zero
        entry.turnRate = 0
        entry.vertical = 0
        entry.steady = 1
        table.clear(entry.history)
    end

    if now - entry.speedCheck > 0.5 then
        entry.speedCheck = now
        local okSpeed, speed = pcall(function() return hum and hum.WalkSpeed end)
        if okSpeed and typeof(speed) == "number" and speed > 0 then
            entry.walkSpeed = speed
        end
    end

    if (position - entry.position).Magnitude > 0.001 then
        local gap = now - (entry.lastMove or now)
        entry.lastMove = now
        if gap > 0 and gap < 0.5 then
            entry.repLag = entry.repLag + (gap - entry.repLag) * 0.2
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

local function perpOf(forward)
    return Vector3.new(-forward.Z, 0, forward.X)
end

local function dotOf(a, b)
    return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

local function fitTurnRate(entry, speed)
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

    local toStart = Vector3.new(first.p.X - origin.X - cx, 0, first.p.Z - origin.Z - cz)
    local toEnd = Vector3.new(-cx, 0, -cz)
    if toStart.Magnitude < 0.001 or toEnd.Magnitude < 0.001 then return nil end

    local startUnit, endUnit = toStart.Unit, toEnd.Unit
    local dot = math.clamp(dotOf(startUnit, endUnit), -1, 1)
    local cross = startUnit.X * endUnit.Z - startUnit.Z * endUnit.X
    local omega = math.atan2(cross, dot) / span
    if math.abs(omega) < MIN_TURN_RATE then return nil end

    local implied = radius * math.abs(omega)
    if implied < speed * 0.5 or implied > speed * 2 then return nil end

    return omega
end

local function predictHorizontal(entry, t)
    if t == 0 then return Vector3.zero end

    local velocity = entry.horizontal
    local speed = velocity.Magnitude
    if speed < 0.5 then return Vector3.zero end

    local ceiling = (entry.walkSpeed or 16) * SPEED_CEILING
    if speed > ceiling then speed = ceiling end

    local forward = velocity.Unit
    local steady = math.clamp(entry.steady or 1, 0, 1)

    local fitted = fitTurnRate(entry, speed)
    local omega = math.clamp(fitted or entry.turnRate, -MAX_TURN_RATE, MAX_TURN_RATE) * steady

    local tangential = math.clamp(dotOf(entry.accel, forward), -MAX_TANGENTIAL, MAX_TANGENTIAL)
    local horizon = t * (TRUST_FLOOR + (1 - TRUST_FLOOR) * steady)

    local side = perpOf(forward)
    local step = horizon / ARC_STEPS
    local displacement = Vector3.zero

    for index = 1, ARC_STEPS do
        local mid = (index - 0.5) * step
        local heading
        if fitted then
            heading = omega * mid
        else
            heading = omega * TURN_DECAY * (1 - math.exp(-mid / TURN_DECAY))
        end
        local moving = math.clamp(speed + tangential * mid, 0, ceiling)
        displacement = displacement
            + (forward * math.cos(heading) + side * math.sin(heading)) * (moving * step)
    end

    return displacement
end

local function predictRoot(entry, base, sinceSample, travelTime)
    if not Aim.Predict or travelTime == 0 then
        return base
    end

    local horizontal = predictHorizontal(entry, travelTime)
    if horizontal.Magnitude > MAX_LEAD_OFFSET then
        horizontal = horizontal.Unit * MAX_LEAD_OFFSET
    end

    local y = base.Y
    if entry.airborne then
        local g = gravity()
        if entry.jumpLaunchV then
            local t = entry.jumpElapsed + sinceSample + travelTime
            y = entry.jumpFromY + entry.jumpLaunchV * t - 0.5 * g * t * t
        else
            y = base.Y + entry.vertical * travelTime - 0.5 * g * travelTime * travelTime
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
    end

    return Vector3.new(base.X + horizontal.X, y, base.Z + horizontal.Z)
end

local function newLeadState(tune)
    return {
        tune = tune,
        pending = {},
        verified = 0,
        hits = 0,
    }
end

local GunLead = newLeadState(GunTune)
local KnifeLead = newLeadState(KnifeTune)

local function travelTimeFor(state, entry, distance)
    local tune = state.tune
    local total = 0

    if Aim.UsePing then
        total = total + cachedPing
    end
    total = total + (entry ~= nil and entry.repLag or 0) * 0.5
    total = total + cachedFrame

    if tune.Speed ~= nil and tune.Speed > 0 then
        total = total + distance / tune.Speed
    end

    total = total + tune.Extra / 1000

    return math.clamp(total, -MAX_TRAVEL_TIME, MAX_TRAVEL_TIME)
end

local function scoreShot(state, hit)
    state.verified = state.verified + 1
    if hit then state.hits = state.hits + 1 end
end

local function verifyLead(state, settings, now)
    local pending = state.pending
    local index = 1
    while index <= #pending do
        local record = pending[index]
        local resolved, hit = false, false

        if record.hum == nil or record.hum.Parent == nil then
            resolved, hit = true, true
        else
            local ok, health = pcall(function() return record.hum.Health end)
            if not ok then
                resolved, hit = true, true
            elseif health <= 0 or health < record.health - 0.01 then
                resolved, hit = true, true
            elseif now >= record.dueAt then
                resolved, hit = true, false
            end
        end

        if resolved then
            scoreShot(state, hit)
            table.remove(pending, index)
        else
            index = index + 1
        end
    end
end

local function logLead(state, char, distance, used, now)
    if #state.pending >= MAX_PENDING then return end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local ok, health = pcall(function() return hum.Health end)
    if not ok or health <= 0 then return end

    table.insert(state.pending, {
        dueAt = now + used + cachedPing + HIT_WINDOW,
        hum = hum,
        health = health,
        distance = distance,
        used = used,
    })
end


local function aimPartsFor(char, entry)
    local order = PART_ORDER_BODY
    if Aim.AimPart == "Head" and not (Aim.JumpAware and entry and isSpamJumper(entry)) then
        order = PART_ORDER_HEAD
    end

    local parts = {}
    for _, name in ipairs(order) do
        local part = char:FindFirstChild(name)
        if part then parts[#parts + 1] = part end
    end
    return parts
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

local function scanTargets(filterFn)
    local origin = Camera.CFrame.Position
    local anchor = screenAnchor()

    local candidates = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) and (not filterFn or filterFn(plr)) then
            local char = plr.Character
            local parts = char and aimPartsFor(char, motion[plr.Name])
            if parts and #parts > 0 then
                local best = nil
                for _, part in ipairs(parts) do
                    local screenDist = candidateScreenDist(part, anchor, origin)
                    if screenDist and (not best or screenDist < best) then
                        best = screenDist
                    end
                end
                if best then
                    candidates[#candidates + 1] = {
                        plr = plr,
                        char = char,
                        parts = parts,
                        screenDist = best,
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.screenDist < b.screenDist end)
    return candidates
end

local knifeSpeedStat = nil

local function onThrowingKnifeAdded(instance)
    local ok, speed = pcall(function() return instance:GetAttribute("ThrowSpeed") end)
    if ok and typeof(speed) == "number" and speed > 1 and speed ~= KnifeTune.Speed then
        KnifeTune.Speed = speed
        if knifeSpeedStat then
            pcall(function() knifeSpeedStat:Set(('%d studs/s'):format(speed)) end)
        end
    end
end

track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(onThrowingKnifeAdded))
for _, instance in ipairs(CollectionService:GetTagged("ThrowingKnife")) do
    task.spawn(onThrowingKnifeAdded, instance)
end

local gunPlan = nil
local knifePlan = nil

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

local function solveAim(plan, origin, now, leadScale)
    leadScale = leadScale or plan.leadScale or 1
    local entry = plan.entry
    local rootPos = plan.root.Position
    local partPos = plan.part.Position
    local sinceSample = now - entry.time
    if sinceSample < 0 then sinceSample = 0 end
    if sinceSample > SAMPLE_STALE then sinceSample = SAMPLE_STALE end

    local offset = partPos - rootPos
    if Aim.JumpAware and entry.airborne then
        offset = Vector3.new(offset.X, -plan.hipOffset, offset.Z)
    end

    if not Aim.Predict then
        return rootPos + offset, rootPos, 0, (partPos - origin).Magnitude, rootPos
    end

    local state = plan.state
    local settings = plan.settings

    local distance = (partPos - origin).Magnitude
    local travelTime = travelTimeFor(state, entry, distance) * leadScale
    local predicted = predictRoot(entry, rootPos, sinceSample, travelTime)
    for _ = 2, settings.passes do
        distance = ((predicted + offset) - origin).Magnitude
        travelTime = travelTimeFor(state, entry, distance) * leadScale
        predicted = predictRoot(entry, rootPos, sinceSample, travelTime)
    end

    return predicted + offset, rootPos, travelTime, distance, predicted
end

local function crossOf(a, b)
    return Vector3.new(
        a.Y * b.Z - a.Z * b.Y,
        a.Z * b.X - a.X * b.Z,
        a.X * b.Y - a.Y * b.X)
end

local function humanise(origin, aim)
    local direction = aim - origin
    local distance = direction.Magnitude
    if distance < 0.1 then return aim end

    local forward = direction.Unit
    local right = crossOf(forward, Vector3.new(0, 1, 0))
    if right.Magnitude < 0.001 then
        right = Vector3.new(1, 0, 0)
    else
        right = right.Unit
    end
    local lift = crossOf(right, forward).Unit

    local share = math.clamp(Legit.DriftShare, 0, 1)
    local ex = legitDriftX * share + (math.random() * 2 - 1) * (1 - share)
    local ey = legitDriftY * share + (math.random() * 2 - 1) * (1 - share)

    local radius = distance * math.tan(math.rad(Legit.ErrorDegrees))
    if math.random() * 100 < Legit.MissChance then
        radius = radius + Legit.MissSpread
    end

    if radius < 0.001 then return aim end

    return aim + (right * ex + lift * ey) * radius
end

local function noteShot(plan, reason, origin, sent, aimed, predictedRoot, travel)
    if not Debug.Enabled or #shotEvents >= 24 then return end
    shotEvents[#shotEvents + 1] = {
        at = os.clock(),
        reason = reason,
        knife = plan ~= nil and plan.isKnife or false,
        target = plan ~= nil and plan.char ~= nil and plan.char.Name or nil,
        char = plan ~= nil and plan.char or nil,
        origin = origin,
        sent = sent,
        aimed = aimed,
        root = plan ~= nil and plan.root ~= nil and plan.root.Position or nil,
        predicted = predictedRoot,
        travel = travel,
        scale = plan ~= nil and plan.leadScale or nil,
        part = plan ~= nil and plan.part ~= nil and plan.part.Name or nil,
    }
end

local function resolveRedirect(plan, originCFrame, sentCFrame)
    shotStats.seen = shotStats.seen + 1

    local origin = originCFrame.Position
    local sent = typeof(sentCFrame) == "CFrame" and sentCFrame.Position or nil

    if not plan then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(nil, "no target", origin, sent, nil, nil, nil)
        return nil
    end

    if os.clock() - plan.stamp > PLAN_STALE then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "plan stale", origin, sent, nil, nil, nil)
        return nil
    end

    local chance = Legit.Enabled and Legit.RedirectChance or Aim.RedirectChance
    if chance < 100 and math.random() * 100 >= chance then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "chance roll", origin, sent, nil, nil, nil)
        return nil
    end

    local aim, predictedRoot, travel
    local ok, solved, _, solvedTravel, _, solvedRoot = pcall(solveAim, plan, origin, os.clock())
    if ok and typeof(solved) == "Vector3" then
        aim, predictedRoot, travel = solved, solvedRoot, solvedTravel
    elseif plan.fallback then
        aim = plan.fallback.Position
    else
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "solve failed", origin, sent, nil, nil, nil)
        return nil
    end

    if Legit.Enabled then
        aim = humanise(origin, aim)
    end

    shotStats.redirected = shotStats.redirected + 1
    noteShot(plan, "redirected", origin, sent, aim, predictedRoot, travel)
    return CFrame.new(aim)
end

local function buildPlan(filter, isKnife, origin, now, settings)
    if not origin then return nil end

    local candidates = scanTargets(filter)
    if #candidates == 0 then return nil end

    local slot = isKnife and "k" or "g"

    if Legit.Enabled then
        local lock = legitLock[slot]
        if lock and now < lock.expires then
            for index, candidate in ipairs(candidates) do
                if candidate.plr == lock.player then
                    table.remove(candidates, index)
                    table.insert(candidates, 1, candidate)
                    break
                end
            end
        end
    end

    for rank, candidate in ipairs(candidates) do
        if rank > MAX_CANDIDATES then break end

        local plr = candidate.plr
        local char = candidate.char
        local root = char:FindFirstChild("HumanoidRootPart")
        local entry = motion[plr.Name]
        local ready = true

        if Legit.Enabled then
            local key = slot .. plr.Name
            local seen = legitSeen[key]
            if not seen or now - seen.last > LEGIT_REACQUIRE then
                legitSeen[key] = { first = now, last = now }
                ready = false
            else
                seen.last = now
                ready = now - seen.first >= Legit.ReactionTime
            end
        end

        if root and entry and ready then
            local plan = {
                entry = entry,
                root = root,
                char = char,
                hipOffset = feetOffset(char),
                state = isKnife and KnifeLead or GunLead,
                settings = settings,
                isKnife = isKnife,
                leadScale = 1,
                stamp = now,
            }

            for _, part in ipairs(candidate.parts) do
                plan.part = part

                if clearPath(origin, part.Position, char) then
                    local aim, _, travelTime, distance = solveAim(plan, origin, now, 1)

                    if clearPath(origin, aim, char) then
                        plan.fallback = CFrame.new(aim)

                        if distance then
                            logLead(plan.state, char, distance, travelTime, now)
                        end

                        if Legit.Enabled then
                            local lock = legitLock[slot]
                            if not lock or lock.player ~= plr or now >= lock.expires then
                                legitLock[slot] = { player = plr, expires = now + Legit.Stickiness }
                            end
                        end

                        return plan
                    end
                end
            end
        end
    end

    return nil
end

local proofQueue = {}
local debugLog
local markerAim, markerReal

local function makeMarker(color)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Locked = true
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(1.4, 1.4, 1.4)
    part.Material = Enum.Material.Neon
    part.Color = color
    part.Transparency = 0.3
    part.Name = "MM2AssistMarker"
    part.Parent = Workspace
    return part
end

local function clearMarkers()
    if markerAim then markerAim:Destroy() markerAim = nil end
    if markerReal then markerReal:Destroy() markerReal = nil end
end

local function showMarker(which, position)
    if not Debug.Markers or not position then return end
    if which == "aim" then
        if not markerAim or not markerAim.Parent then
            markerAim = makeMarker(Color3.fromRGB(255, 70, 70))
        end
        markerAim.Position = position
    else
        if not markerReal or not markerReal.Parent then
            markerReal = makeMarker(Color3.fromRGB(90, 230, 120))
        end
        markerReal.Position = position
    end
end

local function flatDistance(a, b)
    return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function debugTick(now)
    if not Debug.Enabled then
        if #shotEvents > 0 then table.clear(shotEvents) end
        return
    end

    local drained = {}
    for index = 1, #shotEvents do drained[index] = shotEvents[index] end
    table.clear(shotEvents)

    for _, event in ipairs(drained) do
        local tag = event.knife and "knife" or "gun"
        if event.reason ~= "redirected" then
            if debugLog then
                debugLog:Warn(("%s not redirected: %s"):format(tag, event.reason))
            end
        else
            local moved = event.sent and event.aimed and (event.aimed - event.sent).Magnitude or nil
            local lead = event.root and event.predicted and flatDistance(event.predicted, event.root) or nil
            if debugLog then
                debugLog:Add(("%s -> %s %s | moved %s | lead %s | travel %s | lead scale %s"):format(
                    tag,
                    event.target or "?",
                    event.part or "?",
                    moved and ("%.1f studs"):format(moved) or "n/a",
                    lead and ("%.1f studs"):format(lead) or "n/a",
                    event.travel and ("%.3fs"):format(event.travel) or "n/a",
                    event.scale and ("%.2f"):format(event.scale) or "n/a"))
            end
            showMarker("aim", event.aimed)

            if event.char and event.predicted and event.travel and event.travel > 0 then
                proofQueue[#proofQueue + 1] = {
                    dueAt = now + event.travel,
                    char = event.char,
                    predicted = event.predicted,
                    lead = lead,
                    target = event.target,
                }
            end
        end
    end

    local index = 1
    while index <= #proofQueue do
        local proof = proofQueue[index]
        if now < proof.dueAt then
            index = index + 1
        else
            local root = proof.char and proof.char:FindFirstChild("HumanoidRootPart")
            if root then
                local off = flatDistance(proof.predicted, root.Position)
                shotStats.proved = shotStats.proved + 1
                shotStats.error = shotStats.error + off
                showMarker("real", root.Position)
                if debugLog then
                    local verdict = off <= 2 and "HIT band" or (off <= 4 and "close" or "MISS")
                    debugLog:Add(("  %s landed: predicted off by %.1f studs (lead was %s) %s"):format(
                        proof.target or "?",
                        off,
                        proof.lead and ("%.1f"):format(proof.lead) or "?",
                        verdict))
                end
            end
            table.remove(proofQueue, index)
        end
    end
end

track(PreSimulation:Connect(function()
    if Unloading or not Aim.SilentAim then
        gunPlan, knifePlan = nil, nil
        return
    end

    local ok = pcall(function()
        local now = os.clock()
        cachedPing = getPing()
        if lastTick > 0 then
            local dt = now - lastTick
            if dt > 0 and dt < 0.5 then
                cachedFrame = cachedFrame + (dt - cachedFrame) * 0.1
            end
        end
        lastTick = now
        local settings = AUTO_LEVELS[Aim.AutoLevel] or AUTO_LEVELS.Normal

        if Legit.Enabled then
            legitDriftX = math.clamp(legitDriftX + (math.random() * 2 - 1) * DRIFT_STEP, -1, 1)
            legitDriftY = math.clamp(legitDriftY + (math.random() * 2 - 1) * DRIFT_STEP, -1, 1)
        end

        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then sampleMotion(plr, root, now) end
            end
        end

        verifyLead(GunLead, settings, now)
        verifyLead(KnifeLead, settings, now)

        gunPlan = buildPlan(isMurderer, false, findGunOrigin(), now, settings)
        knifePlan = buildPlan(nil, true, findKnifeOrigin(), now, settings)

        debugTick(now)
    end)

    if not ok then
        gunPlan, knifePlan = nil, nil
    end
end))

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall

    local function onNamecall(self, ...)
        if Unloading or not Aim.SilentAim or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
            return originalNamecall(self, ...)
        end

        if self.Name == "Shoot" and self.ClassName == "RemoteEvent" then
            local parent = self.Parent
            if parent and parent.ClassName == "Tool" and parent.Name == "Gun" then
                local origin, sent = ...
                if typeof(origin) == "CFrame" then
                    local redirect = resolveRedirect(gunPlan, origin, sent)
                    if redirect then
                        local fire = self.FireServer
                        if typeof(fire) == "function" then
                            fire(self, origin, redirect)
                            return
                        end
                        return originalNamecall(self, origin, redirect)
                    end
                end
            end
        elseif self.Name == "KnifeThrown" then
            local events = self.Parent
            local tool = events and events.Parent
            if events and events.Name == "Events" and tool and tool.ClassName == "Tool" and tool.Name == "Knife" then
                local handle, sent = ...
                if typeof(handle) == "CFrame" then
                    local redirect = resolveRedirect(knifePlan, handle, sent)
                    if redirect then
                        local fire = self.FireServer
                        if typeof(fire) == "function" then
                            fire(self, handle, redirect)
                            return
                        end
                        return originalNamecall(self, handle, redirect)
                    end
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
    Desc = 'the gun one shots anywhere on the body, so body is not a compromise - it is the same kill with a wider target. the server checks the shot by casting from your gun to the point sent, so how far the prediction can be off before missing is just the width of what you aimed at: about a stud either side of the torso against about half that on the head. head is only worth it if you want the killfeed',
    Values = { 'Body', 'Head' },
    Default = 'Body',
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

AimSection:Slider({
    Title = 'redirect chance',
    Desc = 'percent of shots that get redirected at all. the rest fire exactly where you aimed, untouched. 100 redirects every shot',
    Min = 0,
    Max = 100,
    Increment = 1,
    Default = 100,
    Suffix = '%',
    Flag = 'mm2_silent_aim_redirect_chance',
    Callback = function(value) Aim.RedirectChance = value end,
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
    Desc = 'master switch. off aims exactly where the target is right now. on, the lead is solved on the frame the shot actually fires, from the real muzzle position the game passes in, so nothing is a frame behind. the path is an arc: their turn is measured by fitting a circle through where they actually were, and when that fit holds up it is trusted for the whole lead. when it does not the arc falls back to a smoothed turn that fades out across the lead. speed is held to their walkspeed so a rubberband spike cannot throw the aim, and the whole lead shortens on someone whose direction keeps flipping',
    Flag = 'mm2_silent_aim_predict',
    Default = true,
    Callback = function(state) Aim.Predict = state end,
})

PredictionSection:Toggle({
    Title = 'jump aware',
    Desc = 'the vertical aim point is always solved the same safe way regardless of this toggle - it never overshoots above where they are now by more than a couple studs, and it never undershoots the ground. this only changes where on their body it aims while they are in the air: on, it aims near their feet so a slightly-off vertical read still lands on them, and repeat jumpers get aimed at the torso instead of the head. off, it keeps aiming at the normal point even mid jump',
    Flag = 'mm2_silent_aim_jump',
    Default = true,
    Callback = function(state) Aim.JumpAware = state end,
})

PredictionSection:Toggle({
    Title = 'use ping',
    Desc = 'adds your measured round trip ping to the lead. off, ping contributes nothing at all - the lead is only replication lag, your own frame time, and extra lead per weapon below',
    Flag = 'mm2_silent_aim_use_ping',
    Default = true,
    Callback = function(state) Aim.UsePing = state end,
})

PredictionSection:Dropdown({
    Title = 'smoothing',
    Desc = 'how heavily raw velocity is smoothed and how many times the distance-dependent part of the lead re-solves against where that lead itself would put them. higher settles on a steadier number for someone running a straight line but reacts a little slower to a sudden turn. does not affect the extra lead sliders below, and nothing here is fitted from your shots - it only shapes how the current motion reading is filtered',
    Values = { 'Lesser', 'Normal', 'Extra', 'Advanced', 'Best' },
    Default = 'Normal',
    Flag = 'mm2_silent_aim_auto_level',
    Callback = function(value) Aim.AutoLevel = value end,
})


local Visual = {
    Esp = false,
    ColorByRole = false,
    RoleEsp = false,
    ShowPerk = false,
    ShowDistance = false,
    GunEsp = false,
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
local GUN_ESP_COLOR = Color3.fromRGB(0, 255, 255)

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
    if not Visual.Esp and not Visual.RoleEsp and not Visual.GunEsp then
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
                    local hasGun = heldWeapon(char) == "Gun"
                    local showGun = Visual.GunEsp and hasGun

                    local roleColor = (role and ROLE_COLORS[role]) or NEUTRAL_COLOR
                    local color = Visual.ColorByRole and not dead and roleColor or NEUTRAL_COLOR
                    local espColor = showGun and GUN_ESP_COLOR or color

                    obj.Highlight.Enabled = Visual.Esp or showGun
                    obj.Highlight.FillColor = espColor
                    obj.Highlight.OutlineColor = espColor

                    local showRole = Visual.RoleEsp and role ~= nil and not dead
                    local showLabel = showRole or showGun
                    obj.Billboard.Enabled = showLabel
                    if showLabel then
                        local text = showRole and role or ""
                        if showGun then
                            text = text == "" and "GUN" or (text .. " · GUN")
                        end
                        if showRole and Visual.ShowPerk and role == "Murderer" then
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
                        obj.Label.TextColor3 = showGun and GUN_ESP_COLOR or color
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
    legitSeen["g" .. plr.Name] = nil
    legitSeen["k" .. plr.Name] = nil
    for slot, lock in pairs(legitLock) do
        if lock.player == plr then legitLock[slot] = nil end
    end
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
    return typeof(inst) == "Instance" and inst:IsA("BasePart") and inst.Name == "TrapVisual"
end

local function trapPartFromSignal(inst)
    if typeof(inst) ~= "Instance" then return nil end
    if isTrapVisual(inst) then return inst end

    if inst:IsA("ObjectValue") and inst.Name == "PlacedPlayer" then
        local sibling = inst.Parent and inst.Parent:FindFirstChild("TrapVisual")
        if sibling and isTrapVisual(sibling) then return sibling end
    end

    return nil
end

local function destroyTrapEsp(part)
    local entry = trapObjects[part]
    if not entry then return end
    if entry.highlight then entry.highlight:Destroy() end
    if entry.marker then entry.marker:Destroy() end
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

    local marker = Instance.new("Part")
    marker.Anchored = true
    marker.CanCollide = false
    marker.CanQuery = false
    marker.CanTouch = false
    marker.Locked = true
    marker.Shape = Enum.PartType.Ball
    marker.Size = Vector3.new(2, 2, 2)
    marker.Material = Enum.Material.Neon
    marker.Color = Color3.fromRGB(255, 170, 0)
    marker.Transparency = 0.15
    marker.Name = "MM2AssistTrapMarker"
    marker.Parent = Workspace
    pcall(function() marker.Position = part.Position end)

    trapObjects[part] = { highlight = hl, marker = marker }
end

local function trapEspRefreshAll()
    for part in pairs(trapObjects) do destroyTrapEsp(part) end
    if not TrapEsp.Enabled then return end
    for _, inst in ipairs(Workspace:GetDescendants()) do
        local part = trapPartFromSignal(inst)
        if part then buildTrapEsp(part) end
    end
end

local function updateTrapMarkers()
    for part, entry in pairs(trapObjects) do
        if not part.Parent then
            destroyTrapEsp(part)
        elseif entry.marker then
            pcall(function() entry.marker.Position = part.Position end)
        end
    end
end

task.spawn(function()
    while not Unloading do
        task.wait(0.2)
        if TrapEsp.Enabled then pcall(updateTrapMarkers) end
    end
end)

track(Workspace.DescendantAdded:Connect(function(inst)
    if not TrapEsp.Enabled then return end
    local part = trapPartFromSignal(inst)
    if part then buildTrapEsp(part) end
end))

track(Workspace.DescendantRemoving:Connect(function(inst)
    if trapObjects[inst] then destroyTrapEsp(inst) end
end))

local DroppedGunEsp = { Enabled = false }
local droppedGunObjects = {}

local function isDroppedGun(inst)
    if typeof(inst) ~= "Instance" or not isGunTool(inst) then return false end
    local parent = inst.Parent
    return parent ~= nil and Players:GetPlayerFromCharacter(parent) == nil
end

local function destroyDroppedGunEsp(item)
    local entry = droppedGunObjects[item]
    if not entry then return end
    if entry.highlight then entry.highlight:Destroy() end
    if entry.marker then entry.marker:Destroy() end
    droppedGunObjects[item] = nil
end

local function buildDroppedGunEsp(item)
    if droppedGunObjects[item] then return end

    local hl = Instance.new("Highlight")
    hl.FillColor = GUN_ESP_COLOR
    hl.OutlineColor = GUN_ESP_COLOR
    hl.FillTransparency = 0.3
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = item

    local marker = nil
    local handle = item:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        marker = Instance.new("Part")
        marker.Anchored = true
        marker.CanCollide = false
        marker.CanQuery = false
        marker.CanTouch = false
        marker.Locked = true
        marker.Shape = Enum.PartType.Ball
        marker.Size = Vector3.new(1.6, 1.6, 1.6)
        marker.Material = Enum.Material.Neon
        marker.Color = GUN_ESP_COLOR
        marker.Transparency = 0.15
        marker.Name = "MM2AssistGunMarker"
        marker.Parent = Workspace
        pcall(function() marker.Position = handle.Position end)
    end

    droppedGunObjects[item] = { highlight = hl, marker = marker }
end

local function droppedGunEspRefreshAll()
    for item in pairs(droppedGunObjects) do destroyDroppedGunEsp(item) end
    if not DroppedGunEsp.Enabled then return end
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if isDroppedGun(inst) then buildDroppedGunEsp(inst) end
    end
end

local function updateDroppedGunMarkers()
    for item, entry in pairs(droppedGunObjects) do
        if not item.Parent or not isDroppedGun(item) then
            destroyDroppedGunEsp(item)
        elseif entry.marker then
            local handle = item:FindFirstChild("Handle")
            if handle then
                pcall(function() entry.marker.Position = handle.Position end)
            end
        end
    end
end

task.spawn(function()
    while not Unloading do
        task.wait(0.2)
        if DroppedGunEsp.Enabled then pcall(updateDroppedGunMarkers) end
    end
end)

track(Workspace.DescendantAdded:Connect(function(inst)
    if not DroppedGunEsp.Enabled then return end
    if isDroppedGun(inst) then buildDroppedGunEsp(inst) end
end))

track(Workspace.DescendantRemoving:Connect(function(inst)
    if droppedGunObjects[inst] then destroyDroppedGunEsp(inst) end
end))

local GunLeadSection = SilentAimTab:Section({ Title = 'gun lead', Side = 'left' })

GunLeadSection:Slider({
    Title = 'extra lead',
    Desc = 'a flat amount added to the gun lead, on top of ping, replication lag and your own frame time. positive aims further ahead of the target. negative aims behind them - use it if shots are consistently landing in front, since it walks the point back toward where they already were instead of further into where they are going. the gun is meant to be near instant, so it will rarely need much of this range - it is wide mainly so knife-style flight-time testing does not feel capped',
    Min = -3000,
    Max = 3000,
    Increment = 10,
    Default = 0,
    Suffix = ' ms',
    Flag = 'mm2_gun_lead_extra',
    Callback = function(value) GunTune.Extra = value end,
})

local gunLeadStat = GunLeadSection:Stat({ Title = 'gun hits / shots', Value = '0 / 0' })

local KnifeLeadSection = SilentAimTab:Section({ Title = 'knife lead', Side = 'right' })

KnifeLeadSection:Slider({
    Title = 'extra lead',
    Desc = 'a flat amount added to the knife lead, on top of its real flight time, ping, replication lag and your own frame time. positive aims further ahead of the target. negative aims behind them, for when it is consistently overshooting to one side',
    Min = -3000,
    Max = 3000,
    Increment = 10,
    Default = 0,
    Suffix = ' ms',
    Flag = 'mm2_knife_lead_extra',
    Callback = function(value) KnifeTune.Extra = value end,
})

knifeSpeedStat = KnifeLeadSection:Stat({ Title = 'throw speed (auto)', Value = ('%d studs/s'):format(KnifeTune.Speed) })
local knifeLeadStat = KnifeLeadSection:Stat({ Title = 'knife hits / shots', Value = '0 / 0' })


local LegitTab = Window:Tab({ Title = 'legit', Icon = 'user-check' })

local LegitSection = LegitTab:Section({ Title = 'legit mode', Side = 'left' })

LegitSection:Toggle({
    Title = 'legit mode',
    Desc = 'trades accuracy for looking human. overrides the silent aim redirect chance with its own',
    Flag = 'mm2_legit',
    Default = false,
    Callback = function(state) Legit.Enabled = state end,
})

LegitSection:Slider({
    Title = 'redirect chance',
    Desc = 'percent of shots that get redirected while legit mode is on',
    Min = 0,
    Max = 100,
    Increment = 1,
    Default = 65,
    Suffix = '%',
    Flag = 'mm2_legit_chance',
    Callback = function(value) Legit.RedirectChance = value end,
})

LegitSection:Slider({
    Title = 'reaction time',
    Desc = 'will not redirect onto a target until it has been the candidate this long, so it never tracks someone faster than you could have seen them. resets if they stop being the candidate for 0.4s',
    Min = 0,
    Max = 600,
    Increment = 10,
    Default = 220,
    Suffix = ' ms',
    Flag = 'mm2_legit_reaction',
    Callback = function(value) Legit.ReactionTime = value / 1000 end,
})

LegitSection:Slider({
    Title = 'target stickiness',
    Desc = 'holds the current target this long before it is allowed to switch, so it does not snap between people mid fight',
    Min = 0,
    Max = 5,
    Increment = 0.1,
    Default = 1.2,
    Suffix = 's',
    Flag = 'mm2_legit_sticky',
    Callback = function(value) Legit.Stickiness = value end,
})

local LegitErrorSection = LegitTab:Section({ Title = 'aim error', Side = 'right' })

LegitErrorSection:Slider({
    Title = 'aim error',
    Desc = 'angular error added to the solved point. angular rather than fixed studs, so it opens up with range the way real aim error does',
    Min = 0,
    Max = 5,
    Increment = 0.1,
    Default = 0.7,
    Suffix = ' deg',
    Flag = 'mm2_legit_error',
    Callback = function(value) Legit.ErrorDegrees = value end,
})

LegitErrorSection:Slider({
    Title = 'error drift',
    Desc = 'how much of that error is a slow wander versus fresh randomness each shot. human error is streaky - you are on or off for a few seconds - and pure per shot noise scatters too evenly around dead centre to look real. 0 is all jitter, 100 is all drift',
    Min = 0,
    Max = 100,
    Increment = 5,
    Default = 60,
    Suffix = '%',
    Flag = 'mm2_legit_drift',
    Callback = function(value) Legit.DriftShare = value / 100 end,
})

LegitErrorSection:Slider({
    Title = 'miss chance',
    Desc = 'percent of redirected shots thrown wide on purpose. this is the one that matters most - a hit rate of 100 is what gets you called, not how the shots look',
    Min = 0,
    Max = 100,
    Increment = 1,
    Default = 18,
    Suffix = '%',
    Flag = 'mm2_legit_miss',
    Callback = function(value) Legit.MissChance = value end,
})

LegitErrorSection:Slider({
    Title = 'miss spread',
    Desc = 'how far wide a deliberate miss goes, on top of the normal error',
    Min = 1,
    Max = 12,
    Increment = 0.5,
    Default = 3.5,
    Suffix = ' studs',
    Flag = 'mm2_legit_miss_spread',
    Callback = function(value) Legit.MissSpread = value end,
})

LegitSection:Label({
    Text = 'Silent aim still has to be on. Legit mode only changes how its shots behave - the camera never moves either way.',
})

local DebugTab = Window:Tab({ Title = 'proof', Icon = 'activity' })

local ProofSection = DebugTab:Section({ Title = 'counters', Side = 'left' })

ProofSection:Toggle({
    Title = 'proof mode',
    Desc = 'counts and logs every shot the hook sees. if shots seen stays on zero the hook is not firing at all, if seen climbs while redirected stays on zero it is finding no target, and if redirected climbs it is redirecting - the log then shows by how far',
    Flag = 'mm2_debug',
    Default = false,
    Callback = function(state)
        Debug.Enabled = state
        if not state then clearMarkers() end
    end,
})

ProofSection:Toggle({
    Title = 'world markers',
    Desc = 'red ball where the shot was actually sent, green ball where the target really was when it should have arrived. if the two sit on top of each other the prediction was right. both are set to be ignored by raycasts so they cannot affect your own aim or the hit check',
    Flag = 'mm2_debug_markers',
    Default = true,
    Callback = function(state)
        Debug.Markers = state
        if not state then clearMarkers() end
    end,
})

local SeenStat = ProofSection:Stat({ Title = 'shots seen', Value = '0' })
local RedirectStat = ProofSection:Stat({ Title = 'redirected', Value = '0' })
local SuppressStat = ProofSection:Stat({ Title = 'not redirected', Value = '0' })
local ErrorStat = ProofSection:Stat({ Title = 'avg prediction error', Value = '-' })

ProofSection:Button({
    Title = 'reset counters',
    Callback = function()
        shotStats.seen = 0
        shotStats.redirected = 0
        shotStats.suppressed = 0
        shotStats.proved = 0
        shotStats.error = 0
    end,
})

local LogSection = DebugTab:Section({ Title = 'shot log', Side = 'right' })

debugLog = LogSection:Console({ Title = 'shots', Height = 260, MaxLines = 120, Timestamps = true })
debugLog:Add('turn on proof mode, then shoot')

LogSection:Label({
    Text = 'moved is how far the shot was displaced from where you actually clicked, so any non zero value is the redirect working. lead is how far ahead of the target it aimed. the indented line that follows is measured when the shot should have arrived, comparing where it predicted the target would be against where they actually got to.',
})

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

EspSection:Toggle({
    Title = 'gun esp',
    Desc = 'highlights anyone actually holding a gun right now, in a color of its own that role esp never uses. checked directly off the weapon they are holding rather than guessed from round data, so it still catches a hero even when role detection gets that wrong. works even with esp and role esp both off',
    Flag = 'mm2_esp_gun',
    Callback = function(state) Visual.GunEsp = state end,
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
    Desc = 'a placed trap is invisible until it catches someone, so this looks for it directly instead of waiting for that. matches the part the trap actually uses for its position and the marker object it carries naming who placed it, then puts a highlight and a solid marker ball on it - the marker so it still shows even if the trap part itself has no visible shape of its own',
    Flag = 'mm2_trap_esp',
    Callback = function(state)
        TrapEsp.Enabled = state
        trapEspRefreshAll()
    end,
})

TrapSection:Toggle({
    Title = 'dropped gun esp',
    Desc = 'when a sheriff or hero dies holding the gun, it lands somewhere in the world rather than vanishing. this looks for exactly the same tool the gun is identified by everywhere else in this script - by name, its own marker child, or its tag - lying anywhere that is not inside a character, and puts a highlight and a marker ball on it. stops tracking it the moment someone actually picks it back up',
    Flag = 'mm2_dropped_gun_esp',
    Callback = function(state)
        DroppedGunEsp.Enabled = state
        droppedGunEspRefreshAll()
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
        for item in pairs(droppedGunObjects) do destroyDroppedGunEsp(item) end
        xrayRestoreAll()
        clearMarkers()

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
            SeenStat:Set(tostring(shotStats.seen))
            RedirectStat:Set(tostring(shotStats.redirected),
                shotStats.redirected > 0 and Color3.fromRGB(126, 217, 87) or nil)
            SuppressStat:Set(tostring(shotStats.suppressed))
            ErrorStat:Set(shotStats.proved > 0
                and ('%.1f studs over %d'):format(shotStats.error / shotStats.proved, shotStats.proved)
                or '-')
            gunLeadStat:Set(('%d / %d'):format(GunLead.hits, GunLead.verified))
            knifeLeadStat:Set(('%d / %d'):format(KnifeLead.hits, KnifeLead.verified))
        end)
    end
end)

Window:Load()

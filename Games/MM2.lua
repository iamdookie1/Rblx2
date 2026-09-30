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
local FloatingSpamGui

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

local Onyx
do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Onyx] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/Ui.lua'):format(ref)
    Onyx = loadstring(game:HttpGet(url))()
end

local function addStat(section, cfg)
    local title = cfg.Title
    local label = section:Label({ Title = title .. ': ' .. tostring(cfg.Value), Color = cfg.Color })
    local api = {}
    function api.Set(value, color)
        label:SetText(title .. ': ' .. tostring(value))
        if color then label:SetColor(color) end
    end
    return api
end

local function addProgress(section, cfg)
    local title = cfg.Title
    local label = section:Label({ Title = title .. ': 0%' })
    local api = {}
    function api.Set(percent)
        label:SetText(('%s: %d%%'):format(title, math.floor((tonumber(percent) or 0) + 0.5)))
    end
    return api
end

local Window = Onyx:CreateWindow({
    Title = 'mm2',
    SubTitle = 'assist',
    Folder = 'MM2Assist',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(210, 45, 45),
})

local CoinsStat, GemsStat, PrestigeStat, LevelStat, XPBar, WeaponsStat, PetsStat, MaterialsStat
do
    local ProfileTab = Window:CreateTab({ Title = 'profile' })

    local EconomySection = ProfileTab:CreateSection('economy')
    CoinsStat = addStat(EconomySection, { Title = 'coins', Value = '-' })
    GemsStat = addStat(EconomySection, { Title = 'gems', Value = '-' })
    PrestigeStat = addStat(EconomySection, { Title = 'prestige', Value = '-' })
    EconomySection:Button({ Title = 'refresh', Callback = fetchProfileData })

    local LevelSection = ProfileTab:CreateSection('level')
    LevelStat = addStat(LevelSection, { Title = 'level', Value = '-' })
    XPBar = addProgress(LevelSection, { Title = 'xp to next level' })

    local InventorySection = ProfileTab:CreateSection('inventory')
    WeaponsStat = addStat(InventorySection, { Title = 'weapons owned', Value = '-' })
    PetsStat = addStat(InventorySection, { Title = 'pets owned', Value = '-' })
    MaterialsStat = addStat(InventorySection, { Title = 'materials owned', Value = '-' })
end

local function refreshDashboard()
    if not ProfileData then return end

    CoinsStat.Set(tostring(ProfileData.Coins or 0))
    GemsStat.Set(tostring(ProfileData.Gems or 0))
    PrestigeStat.Set(tostring(ProfileData.Prestige or 0))

    local xp = ProfileData.NewXP or 0
    if LevelModule then
        local ok, level = pcall(LevelModule.GetLevel, xp)
        if ok then LevelStat.Set(tostring(level)) end
        local ok2, progress = pcall(LevelModule.GetProgressToNextLevel, xp)
        if ok2 and typeof(progress) == "number" then
            XPBar.Set(math.clamp(progress, 0, 1) * 100)
        end
    else
        LevelStat.Set('n/a')
    end

    WeaponsStat.Set(tostring(countOwned(ProfileData.Weapons and ProfileData.Weapons.Owned)))
    PetsStat.Set(tostring(countOwned(ProfileData.Pets and ProfileData.Pets.Owned)))
    MaterialsStat.Set(tostring(countOwned(ProfileData.Materials and ProfileData.Materials.Owned)))
end

task.spawn(function()
    while not Unloading do
        task.wait(0.5)
        pcall(refreshDashboard)
    end
end)

-- a config saved by an older build holds a number or a boolean where one of
-- these names now belongs, so anything not on the list falls back to the default
local Choice = {}

function Choice.pick(set, value)
    for _, name in ipairs(set.order) do
        if name == value then return name end
    end
    return set.default
end

function Choice.valueOf(set, value)
    return set.value[Choice.pick(set, value)]
end

-- the one dropdown silent aim v2 has
Choice.Targets = { default = 'Enemies', order = { 'Enemies', 'Anyone' } }

-- fling. a flung player is one whose own client resolved a contact against a
-- part of yours that your client reported moving absurdly fast; every method
-- below is a different way of getting that contact and that report to them
Choice.Fling = {
    -- how a run reaches the person it is aimed at
    Method = {
        default = 'Spin',
        order = { 'Spin', 'Ram', 'Orbit' },
    },

    Power = {
        default = 'Normal',
        order = { 'Gentle', 'Normal', 'Strong', 'Extreme', 'Absurd' },
        -- linear, angular and lift are what a run reports; touch is what the
        -- touch fling multiplies your velocity by, and the lift it adds on top.
        -- lift is what sends people up rather than skidding along the floor
        value = {
            ['Gentle']  = { linear = 1e4, angular = 1e5, lift = 2,  touch = 1e3 },
            ['Normal']  = { linear = 1e6, angular = 1e7, lift = 5,  touch = 1e4 },
            ['Strong']  = { linear = 1e7, angular = 1e8, lift = 8,  touch = 1e5 },
            ['Extreme'] = { linear = 9e7, angular = 9e8, lift = 10, touch = 1e6 },
            ['Absurd']  = { linear = 9e9, angular = 9e9, lift = 10, touch = 1e8 },
        },
    },

    -- how close someone has to be before the touch fling arms. Always runs it
    -- every frame whoever is around, the way the classic scripts do
    Reach = {
        default = 'Close',
        order = { 'Touch', 'Close', 'Medium', 'Wide', 'Always' },
        value = { ['Touch'] = 6, ['Close'] = 10, ['Medium'] = 16, ['Wide'] = 28, ['Always'] = math.huge },
    },

    Targets = {
        default = 'Anyone',
        order = { 'Anyone', 'Murderer only', 'Sheriff only', 'Armed only' },
    },

    -- how wide the circle is when a run orbits someone. kept at or under six
    -- studs so it stays a contact rather than a lunge across the room
    Orbit = {
        default = 'Four',
        order = { 'Two', 'Three', 'Four', 'Five', 'Six' },
        value = { ['Two'] = 2, ['Three'] = 3, ['Four'] = 4, ['Five'] = 5, ['Six'] = 6 },
    },

    -- how long a run keeps at it before giving up and going home, so a target
    -- that simply cannot be flung does not strand you next to them
    Patience = {
        default = 'Normal',
        order = { 'Brief', 'Normal', 'Stubborn' },
        value = { ['Brief'] = 1, ['Normal'] = 2.5, ['Stubborn'] = 5 },
    },

    -- how anti fling keeps you on your feet
    AntiMethod = {
        default = 'Smart',
        order = { 'Smart', 'No collide', 'Guard' },
    },

    -- spin and speed are what marks someone else as flinging; tumble and thrown
    -- are what marks you as being flung. walking is 16, a jump rises at about
    -- 50, and turning only ever spins you about the vertical axis, which the
    -- tumble reading leaves out entirely
    Guard = {
        default = 'Normal',
        order = { 'Relaxed', 'Normal', 'Strict' },
        value = {
            ['Relaxed'] = { spin = 80, speed = 300, tumble = 60, thrown = 250 },
            ['Normal']  = { spin = 40, speed = 180, tumble = 30, thrown = 150 },
            ['Strict']  = { spin = 20, speed = 120, tumble = 18, thrown = 110 },
        },
    },

    Grab = {
        default = 'Fire touch',
        order = { 'Fire touch', 'Teleport' },
    },
}

-- the trigger bot tab. reaction time itself is the one slider in it; the rest
-- follow the same dropdown convention as everywhere else
Choice.Trigger = {
    -- pixels from the mouse a target may be and still count as seen
    Sees = {
        default = 'Visible',
        order = { 'Visible', 'Near crosshair', 'On crosshair' },
        value = { ['Visible'] = math.huge, ['Near crosshair'] = 70, ['On crosshair'] = 0 },
    },

    -- how far either side of the slider each reaction may randomly land
    Jitter = {
        default = 'Human',
        order = { 'Off', 'Small', 'Human', 'Wide' },
        value = { ['Off'] = 0, ['Small'] = 0.1, ['Human'] = 0.25, ['Wide'] = 0.4 },
    },

    -- seconds between shots once one has actually gone out
    Interval = {
        default = 'Normal',
        order = { 'Fast', 'Normal', 'Patient' },
        value = { ['Fast'] = 0.4, ['Normal'] = 0.9, ['Patient'] = 1.6 },
    },

    Method = {
        default = 'Auto',
        order = { 'Auto', 'Activate', 'Remote' },
    },

    -- studs; a throw at someone further than this has time to be walked out of
    ThrowRange = {
        default = 'Medium',
        order = { 'Close', 'Medium', 'Far', 'Any' },
        value = { ['Close'] = 25, ['Medium'] = 50, ['Far'] = 90, ['Any'] = math.huge },
    },
}

-- silent aim v2. Four settings; the rest it works out on its own.
local Aim = {
    Enabled = false,
    Targets = Choice.Targets.default,
    WallCheck = true,
    Fov = 0,        -- degrees either side of where you shot; 0 takes anyone on screen
    Trim = 0,       -- ms added to the lead on top of what it has learned
    Learn = true,   -- learn the real delay from shots that really landed
}

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
Debug = {
    Enabled = false,
    Markers = true,
}

-- global on purpose, like Fling and AutoGun: it is only read a handful of
-- times a frame, where a hash lookup is free
Trigger = {
    Gun = false,
    Throw = false,
    Reaction = 180,
    Jitter = Choice.Trigger.Jitter.default,
    Sees = Choice.Trigger.Sees.default,
    Interval = Choice.Trigger.Interval.default,
    Method = Choice.Trigger.Method.default,
    ThrowRange = Choice.Trigger.ThrowRange.default,

    -- sure shots only: fire only once the predicted chance of the shot
    -- landing is at least this
    Sure = false,
    SureOdds = 0.9,

    -- how long a target may drop out of sight before it counts as lost, and
    -- how long a gun activation has to show up at the hook as a real shot
    Grace = 0.15,
    Confirm = 0.35,
    Retry = 0.25,
    Misfires = 3,

    -- the trigger bot's own plans, and the plan each of its shots was fired
    -- on, which the hook puts that shot on
    plans = {},
    claims = {},

    gun = { held = false, readyAt = 0, target = nil, seenAt = 0, lastSeen = 0, nextAt = 0, shotAt = 0, status = 'off' },
    knife = { held = false, readyAt = 0, target = nil, seenAt = 0, lastSeen = 0, nextAt = 0, shotAt = 0, status = 'off' },

    sawGun = 0,
    sawKnife = 0,
    pendingAt = 0,
    misfires = 0,
    fallback = false,
    hooked = false,
    shots = 0,
    throws = 0,
}

-- the full round trip, not a one way figure: see getPing
local cachedPing = 0.12
local cachedFrame = 1 / 60
local lastTick = 0

local shotStats = { seen = 0, redirected = 0, suppressed = 0, proved = 0, error = 0, hits = 0, resolved = 0 }
local shotEvents = {}

local PLAN_STALE = 0.25
local TRANSPARENT_SKIPS = 8

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

local function gravity()
    local ok, value = pcall(function() return Workspace.Gravity end)
    if ok and typeof(value) == "number" and value > 0 then return value end
    return 196.2
end

local function flatDistance(a, b)
    return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function isMurderer(plr)
    local role, dead = roleOf(plr)
    return role == "Murderer" and not dead
end

--// silent aim v2 --------------------------------------------------------------
--
-- Where to aim, worked out from how each player has really been moving.
--
-- Across the ground: every moment of the last few seconds of someone's own
-- movement whose future is already known says "from a moment like that, over a
-- lead this long, they moved like this". Each of those outcomes is turned into
-- the frame of the way they were heading then and rotated onto the way they
-- head now, and weighted by how recent it is and how alike the moment was: how
-- long since they last changed direction (which separates a runner from someone
-- strafing) and how fast they were turning (which catches circlers). The shot
-- goes wherever the most of those outcomes land inside the body's width across
-- the line of fire, so it bets on what that person actually does rather than on
-- a type of player. A plain straight-line guess rides along as one heavy
-- outcome, so with little seen yet it simply leads them.
--
-- Up and down: jump physics. Mid-air they follow the arc down to the floor that
-- is really under them. Someone who keeps jumping goes straight back up after a
-- frame or two on the floor, measured off them, and the aim height is chosen to
-- sit inside their body whether they jump again or not. Spam jumpers are the
-- easy case for this, not the hard one.
--
-- The lead is your round trip plus the delay the game adds drawing other
-- players, and that delay is learned: after every redirected shot, once it is
-- known whether they really went down, each possible delay is checked against
-- where they actually went, and the ones that agree with what happened gain.
-- Its best guess is kept between sessions.
local SA = {
    WINDOW = 3,             -- seconds of their past used as outcomes
    RECENCY = 1.2,          -- seconds for an outcome's weight to fall to about a third
    PHASE = 0.2,            -- seconds: how alike the time since their last change must be
    PHASE_CAP = 1,          -- past this long without a change, every moment looks alike
    MOVING = 2,             -- studs/s
    TURN = math.cos(math.rad(40)),
    TURN_LOOKBACK = 0.1,
    TURN_SPAN = 0.15,
    TURN_WIDTH = 1,         -- rad/s
    RADIUS = 0.8,           -- studs either side of the line of fire that count as the body
    PRIOR = 3,              -- weight of the straight-line guess
    KEEP = 4,               -- seconds of samples kept per player
    BODY_LOW = -2.9,        -- the body around the root: feet
    BODY_HIGH = 2.1,        -- and the top of the head
    SIGMA_STAY = 0.8,       -- studs of doubt in where someone who stays down will be
    SIGMA_GO = 0.6,         -- and in where someone jumping again will be
    MAX_LEAD = 1.5,

    -- the delay learned on top of the round trip, per weapon
    GRID_LO = -0.05,
    GRID_HI = 0.45,
    GRID_STEP = 0.01,
    PRIOR_DELAY = 0.1,
    PRIOR_WIDTH = 0.1,
    FORGET = 0.97,
    WINDOW_HIT = 0.5,       -- seconds after the lead that a hit still counts

    tracks = {},
    lat = {}, alo = {}, wt = {}, order = {},
    knifeSpeed = 96,
    pending = {},
    cal = {},
    lastPlan = nil,
    floorAt = 0,
    file = 'MM2Assist/silent_aim_v2.json',
}

-- The full round trip in seconds. The shot has to travel up to the server, and
-- the target on screen was already one trip down old when it arrived, so the
-- lead needs both halves. GetNetworkPing only reads about half of what the
-- performance stats call ping, so it is doubled and kept as a floor under the
-- stats' own data ping, which is that round trip including processing at both
-- ends. Reading the half figure as the whole trip was a big part of why the
-- lead used to come up short.
local function getPing()
    local rtt = 0
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and typeof(ping) == "number" and ping > 0 then rtt = ping * 2 end

    local item = SA.pingItem
    if item == nil then
        local found = pcall(function()
            item = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
        end)
        item = found and item or false
        SA.pingItem = item
    end
    if item then
        local okData, ms = pcall(function() return item:GetValue() end)
        if okData and typeof(ms) == "number" and ms / 1000 > rtt then rtt = ms / 1000 end
    end

    if rtt <= 0 then return 0.12 end
    return math.min(rtt, 1)
end

SA.floorParams = RaycastParams.new()
SA.floorParams.FilterType = Enum.RaycastFilterType.Exclude
SA.floorParams.IgnoreWater = true

-- the root's height above the floor when standing: HipHeight on R15, the legs
-- on R6
function SA.standHeight(char, root)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local ok, r15 = pcall(function() return hum and hum.RigType == Enum.HumanoidRigType.R15 end)
    if ok and r15 then
        local okHip, hip = pcall(function() return hum.HipHeight end)
        if okHip and typeof(hip) == "number" and hip > 0 then return hip + root.Size.Y / 2 end
    end
    return 3
end

-- characters are never floors or walls here
function SA.refreshFilter(now)
    if now - SA.floorAt < 1 then return end
    SA.floorAt = now
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then list[#list + 1] = plr.Character end
    end
    SA.floorParams.FilterDescendantsInstances = list
end

-- the root height they would stand at on the floor under (x, y, z), or nil
function SA.floorUnder(x, y, z, stand)
    local ok, hit = pcall(function()
        return Workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -60, 0), SA.floorParams)
    end)
    if ok and hit then return hit.Position.Y + stand end
    return nil
end

function SA.newTrack(char)
    return {
        char = char,
        first = 1, last = 0,
        t = {}, x = {}, y = {}, z = {}, vx = {}, vz = {}, vy = {}, e = {}, w = {},
        changeAt = nil, legMoving = false,
        air = false, groundY = nil, lastLandAt = nil, takeoffAt = nil,
        spam = 0.2, launch = 50, groundTime = 0.03, pendingLand = nil,
        stand = 3, floorY = nil,
    }
end

function SA.forget(plr)
    SA.tracks[plr] = nil
end

-- in the air or not. The state the game shows for other players can trail, so
-- a still vertical speed is only called standing once the floor is right there
function SA.airborne(track, char, root, vy)
    if math.abs(vy) > 3 then return true end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local ok, state = pcall(function() return hum and hum:GetState() end)
    if ok and (state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping) then
        return true
    end
    -- on flat ground the height does not move, so the floor only needs
    -- looking for again when it does
    local y = root.Position.Y
    if not track.air and track.floorY and math.abs(y - track.floorY) < 0.05 then return false end
    local floor = SA.floorUnder(root.Position.X, y, root.Position.Z, track.stand)
    if floor and y - floor < 0.6 then
        track.floorY = y
        return false
    end
    track.floorY = nil
    return true
end

function SA.push(s, t, x, y, z, vx, vy, vz, air)
    local speed = math.sqrt(vx * vx + vz * vz)
    local moving = speed > SA.MOVING

    -- a new leg: they stopped, started, or turned sharply since a moment ago
    if s.changeAt == nil then
        s.changeAt, s.legMoving = t, moving
    else
        local changed = moving ~= s.legMoving
        if not changed and moving then
            local j = s.last
            while j > s.first and t - s.t[j] < SA.TURN_LOOKBACK do j = j - 1 end
            local px, pz = s.vx[j] or 0, s.vz[j] or 0
            local ps = math.sqrt(px * px + pz * pz)
            if ps > SA.MOVING and (vx * px + vz * pz) / (speed * ps) < SA.TURN then changed = true end
        end
        if changed then s.changeAt, s.legMoving = t, moving end
    end

    -- jumps: takeoff, launch speed, landing, and whether a landing is met by
    -- another jump straight away
    if air and not s.air then
        s.takeoffAt = t
        if s.pendingLand then
            local gap = t - s.pendingLand
            s.spam = s.spam + ((gap < 0.15 and 1 or 0) - s.spam) * 0.35
            if gap < 0.15 then s.groundTime = s.groundTime + (gap - s.groundTime) * 0.3 end
            s.pendingLand = nil
        end
    end
    if air and s.takeoffAt and t - s.takeoffAt < 0.07 and vy > 15 then
        local launch = vy + gravity() * (t - s.takeoffAt)
        s.launch = s.launch + (launch - s.launch) * 0.3
    end
    if not air and s.air then
        s.lastLandAt, s.pendingLand = t, t
    end
    if s.pendingLand and not air and t - s.pendingLand >= 0.15 then
        s.spam = s.spam - s.spam * 0.35
        s.pendingLand = nil
    end
    if not air then s.groundY = y end
    s.air = air

    local k = s.last + 1
    s.last = k
    s.t[k], s.x[k], s.y[k], s.z[k] = t, x, y, z
    s.vx[k], s.vz[k], s.vy[k] = vx, vz, vy
    s.e[k] = t - s.changeAt

    -- how fast they are turning: heading now against a moment ago
    local omega = 0
    if moving then
        local j = k - 1
        while j > s.first and t - s.t[j] < SA.TURN_SPAN do j = j - 1 end
        local px, pz = s.vx[j] or 0, s.vz[j] or 0
        local ps = math.sqrt(px * px + pz * pz)
        local span = t - (s.t[j] or t)
        if ps > SA.MOVING and span > 0.02 then
            omega = math.atan2(px * vz - pz * vx, px * vx + pz * vz) / span
        end
    end
    s.w[k] = omega

    while s.first < s.last and t - s.t[s.first] > SA.KEEP do
        local f = s.first
        s.t[f], s.x[f], s.y[f], s.z[f], s.vx[f], s.vz[f], s.vy[f], s.e[f], s.w[f] =
            nil, nil, nil, nil, nil, nil, nil, nil, nil
        s.first = f + 1
    end
end

-- one sample of everyone else, every frame
function SA.sampleAll(now)
    SA.refreshFilter(now)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local track = SA.tracks[plr]
                local p = root.Position
                -- a new body, or a jump across the map, starts the history over
                if not track or track.char ~= char
                    or (track.last >= track.first and (Vector3.new(track.x[track.last], track.y[track.last], track.z[track.last]) - p).Magnitude > 25)
                then
                    track = SA.newTrack(char)
                    SA.tracks[plr] = track
                end
                track.root = root
                track.stand = SA.standHeight(char, root)
                local okV, v = pcall(function() return root.AssemblyLinearVelocity end)
                if not okV or typeof(v) ~= "Vector3" then v = Vector3.zero end
                SA.push(track, now, p.X, p.Y, p.Z, v.X, v.Y, v.Z, SA.airborne(track, char, root, v.Y))
            end
        end
    end
end

function SA.byLat(a, b) return SA.lat[a] < SA.lat[b] end

-- where across (c) and along (q) the line of fire to aim, from where they are
-- now, and the share of their past outcomes that lands inside the body
function SA.horizontal(s, now, L, ax, az)
    local last = s.last
    local vx, vz = s.vx[last], s.vz[last]
    local speed = math.sqrt(vx * vx + vz * vz)
    local moving = speed > SA.MOVING
    local fx, fz = 0, 0
    if moving then fx, fz = vx / speed, vz / speed end
    local ux, uz = -az, ax
    local eNow = math.min(now - (s.changeAt or now), SA.PHASE_CAP)
    local wNow = s.w[last] or 0
    local lat, alo, wt, order = SA.lat, SA.alo, SA.wt, SA.order

    local count = 1
    lat[1] = L * (vx * ux + vz * uz)
    alo[1] = L * (vx * ax + vz * az)
    wt[1] = SA.PRIOR
    local total = SA.PRIOR

    local T, X, Z = s.t, s.x, s.z
    local j = s.first
    for i = s.first, last do
        local ti = T[i]
        local goal = ti + L
        if goal > now then break end
        local age = now - ti
        if age <= SA.WINDOW then
            if j < i then j = i end
            while j < last and T[j + 1] <= goal do j = j + 1 end
            local x2, z2
            if j >= last then
                x2, z2 = X[last], Z[last]
            else
                local a = (goal - T[j]) / (T[j + 1] - T[j])
                x2, z2 = X[j] + (X[j + 1] - X[j]) * a, Z[j] + (Z[j + 1] - Z[j]) * a
            end
            local dx, dz = x2 - X[i], z2 - Z[i]
            local vix, viz = s.vx[i], s.vz[i]
            local vi = math.sqrt(vix * vix + viz * viz)
            if moving == (vi > SA.MOVING) then
                local de = (math.min(s.e[i], SA.PHASE_CAP) - eNow) / SA.PHASE
                local w = math.exp(-age / SA.RECENCY) * (math.exp(-de * de) + 0.02)
                local ex, ez = dx, dz
                if moving then
                    local dw = ((s.w[i] or 0) - wNow) / SA.TURN_WIDTH
                    w = w * math.exp(-dw * dw)
                    local fix, fiz = vix / vi, viz / vi
                    local k = speed / vi
                    local along = (dx * fix + dz * fiz) * k
                    local side = (dz * fix - dx * fiz) * k
                    ex, ez = along * fx - side * fz, along * fz + side * fx
                end
                if w > 1e-4 then
                    count = count + 1
                    lat[count] = ex * ux + ez * uz
                    alo[count] = ex * ax + ez * az
                    wt[count] = w
                    total = total + w
                end
            end
        end
    end

    for i = 1, count do order[i] = i end
    for i = count + 1, #order do order[i] = nil end
    table.sort(order, SA.byLat)

    local bestW, bestL, bestR = -1, 1, 1
    local r, sum = 1, 0
    local width = 2 * SA.RADIUS
    for l = 1, count do
        while r <= count and lat[order[r]] - lat[order[l]] <= width do
            sum = sum + wt[order[r]]
            r = r + 1
        end
        if sum > bestW then bestW, bestL, bestR = sum, l, r - 1 end
        sum = sum - wt[order[l]]
    end

    local c = (lat[order[bestL]] + lat[order[bestR]]) / 2
    local q, qw = 0, 0
    for n = bestL, bestR do
        local i = order[n]
        q, qw = q + alo[i] * wt[i], qw + wt[i]
    end
    return c, qw > 0 and q / qw or 0, bestW / total
end

-- the height to aim at, and how sure of it this is. (x, z) is where across the
-- ground the shot will find them, for the floor under that spot
function SA.vertical(s, now, L, x, z)
    local last = s.last
    local y, vy = s.y[last], s.vy[last]
    local g = gravity()
    local launch = math.max(s.launch, 1)
    local gt = s.groundTime
    local airtime = 2 * launch / g
    local p = s.spam
    local centre = (SA.BODY_LOW + SA.BODY_HIGH) / 2

    local stay, go
    if s.air then
        -- the floor they will come down on, under where they are headed
        local ground = SA.floorUnder(x, y, z, s.stand) or s.groundY or (y - 60)
        local disc = vy * vy + 2 * g * math.max(y - ground, 0)
        local land = (vy + math.sqrt(disc)) / g
        if L <= land then return y + vy * L - 0.5 * g * L * L + centre, 1 end
        stay = ground
        local t = (L - land) - gt
        if t <= 0 then
            go = ground
        else
            t = t % (airtime + gt)
            go = t > airtime and ground or ground + launch * t - 0.5 * g * t * t
        end
    else
        local since = now - (s.lastLandAt or -math.huge)
        stay = y
        if since > gt + 0.08 then
            p = 0
            go = y
        else
            local t = (L + since) - gt
            if t <= 0 then
                go = y
            else
                t = t % (airtime + gt)
                go = t > airtime and y or y + launch * t - 0.5 * g * t * t
            end
        end
    end

    return SA.bestHeight(stay, go, p)
end

-- the share of a body standing at root height y (give or take sigma) that
-- an aim at height a lands inside
function SA.inside(a, y, sigma)
    local lo = (a - SA.BODY_HIGH - y) / sigma
    local hi = (a - SA.BODY_LOW - y) / sigma
    return 1 / (1 + math.exp(-1.702 * hi)) - 1 / (1 + math.exp(-1.702 * lo))
end

-- the aim height most likely to be inside the body, whether they stay down
-- (stay) or go straight back up (go, with odds p), and that likelihood
function SA.bestHeight(stay, go, p)
    if p <= 0 or math.abs(go - stay) < 1e-6 then return stay + (SA.BODY_LOW + SA.BODY_HIGH) / 2, 1 end
    local best, bestScore = stay, -1
    local a, to = math.min(stay, go) - 3, math.max(stay, go) + 3
    while a <= to do
        local score = (1 - p) * SA.inside(a, stay, SA.SIGMA_STAY) + p * SA.inside(a, go, SA.SIGMA_GO)
        if score > bestScore then best, bestScore = a, score end
        a = a + 0.1
    end
    return best, bestScore
end

-- the point to send, and the chance it lands, for a lead of L seconds from origin
function SA.predict(s, now, L, origin)
    local last = s.last
    local px, pz = s.x[last], s.z[last]
    local dx, dz = px - origin.X, pz - origin.Z
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1e-3 then dx, dz, d = 1, 0, 1 end
    local ax, az = dx / d, dz / d
    local c, q, chance = SA.horizontal(s, now, L, ax, az)
    local x, z = px - c * az + q * ax, pz + c * ax + q * az
    local y, sure = SA.vertical(s, now, L, x, z)
    return Vector3.new(x, y, z), chance * sure
end

-- The delay learned on top of the round trip, per weapon: a score for every
-- candidate delay on a grid, from a prior around the usual figure (or the one
-- saved last session) plus, for every resolved shot, how well that candidate
-- explains whether it landed.
function SA.calFor(which)
    local cal = SA.cal[which]
    if cal then return cal end
    cal = { score = {}, n = 0, best = SA.saved and SA.saved[which] or SA.PRIOR_DELAY, shots = 0, used = 0 }
    cal.centre = cal.best
    for b = SA.GRID_LO, SA.GRID_HI + 1e-9, SA.GRID_STEP do
        cal.n = cal.n + 1
        local d = (b - cal.centre) / SA.PRIOR_WIDTH
        cal.score[cal.n] = -0.5 * d * d
    end
    SA.cal[which] = cal
    return cal
end

function SA.delay(which)
    if not Aim.Learn then return SA.PRIOR_DELAY end
    return SA.calFor(which).best
end

function SA.load()
    if typeof(readfile) ~= "function" or typeof(isfile) ~= "function" then return end
    pcall(function()
        if not isfile(SA.file) then return end
        local data = game:GetService("HttpService"):JSONDecode(readfile(SA.file))
        if type(data) == "table" then
            SA.saved = {
                Gun = tonumber(data.Gun) and math.clamp(tonumber(data.Gun), SA.GRID_LO, SA.GRID_HI) or nil,
                Knife = tonumber(data.Knife) and math.clamp(tonumber(data.Knife), SA.GRID_LO, SA.GRID_HI) or nil,
            }
        end
    end)
end

function SA.save()
    if typeof(writefile) ~= "function" then return end
    pcall(function()
        if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder('MM2Assist') then
            makefolder('MM2Assist')
        end
        writefile(SA.file, game:GetService("HttpService"):JSONEncode({
            Gun = SA.cal.Gun and SA.cal.Gun.best or (SA.saved and SA.saved.Gun),
            Knife = SA.cal.Knife and SA.cal.Knife.best or (SA.saved and SA.saved.Knife),
        }))
    end)
end

function SA.forgetLead()
    SA.cal, SA.saved = {}, nil
    if typeof(delfile) == "function" and typeof(isfile) == "function" then
        pcall(function() if isfile(SA.file) then delfile(SA.file) end end)
    end
end

-- where they were drawn at time t, from their history
function SA.positionAt(s, t)
    if s.last < s.first or t < s.t[s.first] or t > s.t[s.last] then return nil end
    local lo, hi = s.first, s.last
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if s.t[mid] <= t then lo = mid else hi = mid end
    end
    local span = s.t[hi] - s.t[lo]
    local a = span > 0 and (t - s.t[lo]) / span or 0
    return Vector3.new(s.x[lo] + (s.x[hi] - s.x[lo]) * a, s.y[lo] + (s.y[hi] - s.y[lo]) * a,
        s.z[lo] + (s.z[hi] - s.z[lo]) * a)
end

-- whether the line from origin through aim passes through a body whose root
-- is at root: the torso and arms a stud either side, the head narrower
function SA.through(origin, aim, root)
    local dx, dy, dz = aim.X - origin.X, aim.Y - origin.Y, aim.Z - origin.Z
    local flat = dx * dx + dz * dz
    if flat < 1e-6 then return false end
    local s = ((root.X - origin.X) * dx + (root.Z - origin.Z) * dz) / flat
    if s < 0 then return false end
    local cx, cz = origin.X + dx * s - root.X, origin.Z + dz * s - root.Z
    local h = origin.Y + dy * s - root.Y
    if h < SA.BODY_LOW or h > SA.BODY_HIGH then return false end
    return math.sqrt(cx * cx + cz * cz) <= (h > 0.9 and 0.6 or 1)
end

-- a redirected shot, kept until it is known whether it landed
function SA.record(which, plan, origin, aim, now)
    if #SA.pending >= 24 then return end
    local hum = plan.char and plan.char:FindFirstChildOfClass("Humanoid")
    local ok, health = pcall(function() return hum.Health end)
    if not ok or type(health) ~= "number" or health <= 0 then return end
    SA.pending[#SA.pending + 1] = {
        which = which, at = now, track = plan.entry, hum = hum, health = health,
        origin = origin, aim = aim, rtt = plan.rtt or cachedPing, flight = plan.flight or 0,
        lead = plan.travel or 0, landed = false,
    }
end

function SA.resolve(now)
    local pending = SA.pending
    local index = 1
    while index <= #pending do
        local shot = pending[index]
        if not shot.landed then
            local ok, health = pcall(function() return shot.hum.Parent and shot.hum.Health end)
            if not ok or not health or health < shot.health - 0.01 then shot.landed = true end
        end
        local due = shot.at + shot.rtt + shot.flight + SA.GRID_HI + SA.WINDOW_HIT
        if now < due then
            index = index + 1
        else
            table.remove(pending, index)
            shotStats.resolved = shotStats.resolved + 1
            if shot.landed then shotStats.hits = shotStats.hits + 1 end
            if Aim.Learn then SA.learn(shot) end
        end
    end
end

-- every candidate delay: would the shot have gone through them, had the delay
-- been that? The ones that agree with what really happened gain. A shot every
-- candidate agrees on (someone standing still) teaches nothing and is skipped.
-- A delay past the end of what was seen of them counts as a miss: a body that
-- is gone had already gone down, so this shot cannot have been what did it
function SA.learn(shot)
    local cal = SA.calFor(shot.which)
    local verdicts, agree, known = {}, 0, 0
    for i = 1, cal.n do
        local b = SA.GRID_LO + (i - 1) * SA.GRID_STEP
        local at = SA.positionAt(shot.track, shot.at + shot.rtt + b + shot.flight)
        if at then
            known = known + 1
            verdicts[i] = SA.through(shot.origin, shot.aim, at)
            if verdicts[i] then agree = agree + 1 end
        end
    end
    cal.shots = cal.shots + 1
    if known < cal.n / 2 or agree == 0 or agree == known then return end
    cal.used = cal.used + 1

    local best, bestScore = cal.best, -math.huge
    for i = 1, cal.n do
        local b = SA.GRID_LO + (i - 1) * SA.GRID_STEP
        local d = (b - cal.centre) / SA.PRIOR_WIDTH
        local prior = -0.5 * d * d
        local verdict = verdicts[i] == true
        local p
        if shot.landed then p = verdict and 0.85 or 0.05 else p = verdict and 0.2 or 0.95 end
        local score = prior + (cal.score[i] - prior) * SA.FORGET + math.log(p)
        cal.score[i] = score
        if score > bestScore then best, bestScore = b, score end
    end
    cal.best = best
    SA.save()
end

-- one team per side: town is the innocents, sheriff and hero; the rest of the
-- roles the game hands out (murderer, zombies and survivors, freezers and
-- runners) are each their own
SA.TEAMS = { Innocent = 'town', Sheriff = 'town', Hero = 'town' }

-- the role the round gave them, which is what sides go by; the weapon in their
-- hands only fills in when the round has not said (a knife is the murderer's)
function SA.teamOf(plr)
    local entry = RoundData[plr.Name]
    if entry and entry.Dead then return nil, true end
    local role = entry and entry.Role
    if role == nil then
        local held = heldWeapon(plr.Character)
        role = held == "Knife" and "Murderer" or held == "Gun" and "Hero" or nil
    end
    return role and (SA.TEAMS[role] or role) or nil, false
end

-- who counts as an enemy right now. anyone on another side than you; everyone
-- when there are no sides (a free for all, or no round); and never someone
-- the game has not told you the role of while you are town, since shooting an
-- innocent as sheriff kills you
function SA.refreshTeams()
    local mine = SA.teamOf(LocalPlayer)
    SA.myTeam = mine
    local sides = false
    if mine then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and isAlivePlr(plr) then
                local theirs = SA.teamOf(plr)
                if theirs and theirs ~= mine then sides = true break end
            end
        end
    end
    SA.sides = sides
end

function SA.isEnemy(plr)
    if not SA.sides then return true end
    local theirs, dead = SA.teamOf(plr)
    if dead then return false end
    if theirs == nil then return SA.myTeam ~= 'town' end
    return theirs ~= SA.myTeam
end

function SA.allowed(plr, anyone)
    if plr == LocalPlayer or not isAlivePlr(plr) then return false end
    if anyone then return true end
    return SA.isEnemy(plr)
end

-- a clear line from the weapon to the point, whatever transparent things are
-- in the way
local function clearPath(origin, target, char)
    local direction = target - origin
    local result = weaponCast(origin, direction, { char })
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

-- the lead for a shot from origin at this target: round trip, the learned
-- delay, your trim and, for the knife, its flight - solved a few times, since
-- the flight depends on where the lead puts them
function SA.solve(track, which, origin, now)
    local base = cachedPing + SA.delay(which) + (tonumber(Aim.Trim) or 0) / 1000
    local root = Vector3.new(track.x[track.last], track.y[track.last], track.z[track.last])
    local flight = 0
    local lead = math.clamp(base, 0, SA.MAX_LEAD)
    local aim, chance = SA.predict(track, now, lead, origin)
    if which == 'Knife' and SA.knifeSpeed > 1 then
        for _ = 1, 3 do
            flight = (aim - origin).Magnitude / SA.knifeSpeed
            lead = math.clamp(base + flight, 0, SA.MAX_LEAD)
            aim, chance = SA.predict(track, now, lead, origin)
        end
    end
    return aim, chance, lead, flight, root
end

-- targets for a shot from origin going along dir, best first: the one nearest
-- that direction, on screen, inside the fov if one is set
function SA.candidates(origin, dir, anyone)
    local list = {}
    local unit = dir.Magnitude > 1e-3 and dir.Unit or Camera.CFrame.LookVector
    local fov = tonumber(Aim.Fov) or 0
    local now = os.clock()
    for _, plr in ipairs(Players:GetPlayers()) do
        local track = SA.tracks[plr]
        -- only someone seen a moment ago, in the body they have now
        if track and track.last >= track.first and now - track.t[track.last] < 0.5
            and track.char == plr.Character and track.root and track.root:IsDescendantOf(Workspace)
            and SA.allowed(plr, anyone)
        then
            local root = track.root
            local toward = root.Position - origin
            if toward.Magnitude > 0.5 then
                local angle = math.deg(math.acos(math.clamp(unit:Dot(toward.Unit), -1, 1)))
                local _, onScreen = Camera:WorldToViewportPoint(root.Position)
                if onScreen and (fov <= 0 or angle <= fov) then
                    list[#list + 1] = { plr = plr, track = track, root = root, angle = angle }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.angle < b.angle end)
    return list
end

-- a plan: who, and the point to send. only would-be targets with a clear line
-- to that point are taken while the wall check is on (the server casts to it)
function SA.plan(which, origin, dir, now, anyone, only)
    if not origin then return nil end
    local list
    if only then
        local track = SA.tracks[only]
        if not track or not track.root or not isAlivePlr(only) then return nil end
        list = { { plr = only, track = track, root = track.root, angle = 0 } }
    else
        list = SA.candidates(origin, dir, anyone)
    end
    for rank, candidate in ipairs(list) do
        if rank > 4 then break end
        local track = candidate.track
        local aim, chance, lead, flight, root = SA.solve(track, which, origin, now)
        local char = track.char
        if not Aim.WallCheck or clearPath(origin, aim, char) then
            return {
                plr = candidate.plr,
                char = char,
                root = candidate.root,
                part = candidate.root,
                entry = track,
                isKnife = which == 'Knife',
                fallback = CFrame.new(aim),
                aim = aim,
                chance = chance,
                travel = lead,
                flight = flight,
                rtt = cachedPing,
                predicted = aim,
                from = root,
                stamp = now,
                ahead = not clearPath(origin, candidate.root.Position, char),
            }
        end
    end
    return nil
end

local knifeSpeedStat = nil

local function onThrowingKnifeAdded(instance)
    local ok, speed = pcall(function() return instance:GetAttribute("ThrowSpeed") end)
    if ok and typeof(speed) == "number" and speed > 1 and speed ~= SA.knifeSpeed then
        SA.knifeSpeed = speed
        if knifeSpeedStat then
            pcall(function() knifeSpeedStat.Set(('%d studs/s'):format(speed)) end)
        end
    end
end

track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(onThrowingKnifeAdded))
for _, instance in ipairs(CollectionService:GetTagged("ThrowingKnife")) do
    task.spawn(onThrowingKnifeAdded, instance)
end

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

local function noteShot(plan, reason, origin, sent, aimed)
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
        root = plan ~= nil and plan.from or nil,
        predicted = plan ~= nil and plan.predicted or nil,
        travel = plan ~= nil and plan.travel or nil,
        chance = plan ~= nil and plan.chance or nil,
        part = 'body',
    }
end

-- the shot leaving now: who it goes to and where. the direction you actually
-- fired in ranks the targets, so this follows your aim on a phone as well as
-- with a mouse. a shot the trigger bot fired stays on the person it fired at
local function resolveRedirect(which, claimed, originCFrame, sentCFrame)
    shotStats.seen = shotStats.seen + 1
    local origin = originCFrame.Position
    local sent = typeof(sentCFrame) == "CFrame" and sentCFrame.Position or nil
    local now = os.clock()

    local dir = sent and (sent - origin) or Camera.CFrame.LookVector
    local plan
    if claimed then
        plan = SA.plan(which, origin, dir, now, false, claimed.plr)
    else
        plan = SA.plan(which, origin, dir, now, Choice.pick(Choice.Targets, Aim.Targets) == 'Anyone')
    end

    if not plan then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(nil, "no target", origin, sent, nil)
        return nil
    end

    SA.lastPlan = plan
    SA.record(which, plan, origin, plan.aim, now)
    shotStats.redirected = shotStats.redirected + 1
    noteShot(plan, "redirected", origin, sent, plan.aim)
    return CFrame.new(plan.aim)
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
                debugLog:Log(("%s -> %s | moved %s | lead %s | travel %s | chance %s"):format(
                    tag,
                    event.target or "?",
                    moved and ("%.1f studs"):format(moved) or "n/a",
                    lead and ("%.1f studs"):format(lead) or "n/a",
                    event.travel and ("%.3fs"):format(event.travel) or "n/a",
                    event.chance and ("%d%%"):format(math.floor(event.chance * 100 + 0.5)) or "n/a"))
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
                    debugLog:Log(("  %s landed: predicted off by %.1f studs (lead was %s) %s"):format(
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

--// trigger bot ---------------------------------------------------------------
--
-- Fires for you once a target has been in view long enough for a person to
-- have reacted to them. The reaction runs twice, in order: once when the
-- weapon comes out, then again from the moment a target is first seen after
-- that - so drawing on someone already standing in front of you takes two
-- reactions, the way it would for anyone. It only ever uses a weapon already
-- in your hands; nothing here equips anything.
--
-- It and silent aim work off one solve. The trigger bot plans with silent aim
-- v2's predictor, only ever at enemies (as sheriff that is the murderer alone,
-- so it cannot get you killed), and every shot it fires carries its target to
-- the hook, which solves that shot again as it leaves and puts it on them -
-- even with silent aim itself switched off.

function Trigger.delay()
    local base = math.max(0, tonumber(Trigger.Reaction) or 0) / 1000
    local spread = Choice.valueOf(Choice.Trigger.Jitter, Trigger.Jitter) or 0
    return math.max(0, base * (1 + spread * (math.random() * 2 - 1)))
end

function Trigger.interval()
    return Choice.valueOf(Choice.Trigger.Interval, Trigger.Interval) or 0.9
end

-- auto starts on the gun's own script, which keeps its cooldown, animation and
-- sound, and moves to the remote for good once a few activations in a row have
-- produced no shot at the hook
function Trigger.gunMethod()
    local method = Choice.pick(Choice.Trigger.Method, Trigger.Method)
    if method == 'Auto' then return Trigger.fallback and 'Remote' or 'Activate' end
    return method
end

-- whether a shot goes where the solve says rather than wherever the mouse
-- happens to be: a throw is always sent at the solved point, and so is any
-- gun shot the hook can put on its plan, or one sent straight by remote
function Trigger.aimed(which)
    if which == 'Knife' then return true end
    return Trigger.hooked or Trigger.gunMethod() == 'Remote'
end

-- a clear line from the weapon whatever the silent aim wall check is set to:
-- this is deciding whether to fire at all, not where
function Trigger.clear(origin, point, char)
    local direction = point - origin
    local result = weaponCast(origin, direction, { char })
    return not result or (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

-- 0 ms is past instant: the trigger bot then fires on the prediction itself,
-- including at someone still stepping out from behind cover
function Trigger.ahead()
    return (tonumber(Trigger.Reaction) or 0) <= 0
end

-- The trigger bot's own plans: enemies only, nearest where the camera looks
function Trigger.buildPlans(now, char)
    local plans = Trigger.plans
    plans.Gun, plans.Knife = nil, nil
    local look = Camera.CFrame.LookVector
    if Trigger.Gun and char and char:FindFirstChild("Gun") then
        plans.Gun = SA.plan('Gun', findGunOrigin(), look, now, false)
    end
    if Trigger.Throw and char and char:FindFirstChild("Knife") then
        plans.Knife = SA.plan('Knife', findKnifeOrigin(), look, now, false)
    end
end

-- a shot the trigger bot is about to fire, and the plan it is for
function Trigger.claim(which, plan, now)
    plan.claimedUntil = now + Trigger.Confirm
    Trigger.claims[which] = plan
end

-- the plan the shot leaving right now was fired on, if the trigger bot fired
-- it; used once, so a shot of your own afterwards goes back to silent aim
function Trigger.claimed(which)
    local plan = Trigger.claims[which]
    if not plan then return nil end
    Trigger.claims[which] = nil
    if os.clock() > (plan.claimedUntil or 0) then return nil end
    return plan
end

function Trigger.sees(which, plan, origin, now)
    if not plan or not plan.part or not plan.fallback or now - plan.stamp > PLAN_STALE then return false end

    if which == 'Knife' then
        local reach = Choice.valueOf(Choice.Trigger.ThrowRange, Trigger.ThrowRange) or math.huge
        if (plan.part.Position - origin).Magnitude > reach then return false end
    end
    -- someone still behind cover is only fired at on the prediction itself, at 0 ms
    if plan.ahead and not Trigger.ahead() then return false end

    -- them, and the point the shot will actually be sent at, both in the
    -- open. a plan made ahead only needs the point: they are still stepping
    -- out, and the shot is for where they will be
    if not plan.ahead and not Trigger.clear(origin, plan.part.Position, plan.char) then return false end
    if not Trigger.clear(origin, plan.fallback.Position, plan.char) then return false end

    -- a gun fired through its own script with nothing to put it on its plan
    -- goes where you point, so then only a target under the mouse counts
    local mode = Choice.pick(Choice.Trigger.Sees, Trigger.Sees)
    if not Trigger.aimed(which) then mode = 'On crosshair' end
    if mode == 'Visible' then return true end
    if plan.ahead then return false end

    local mouse = UserInputService:GetMouseLocation()
    if mode == 'Near crosshair' then
        local screen, onScreen = Camera:WorldToViewportPoint(plan.part.Position)
        return onScreen and (Vector2.new(screen.X, screen.Y) - mouse).Magnitude
            <= Choice.valueOf(Choice.Trigger.Sees, mode)
    end

    local ray = Camera:ViewportPointToRay(mouse.X, mouse.Y)
    local hit = weaponCast(ray.Origin, ray.Direction * 1000, nil)
    return hit ~= nil and hit.Instance ~= nil and hit.Instance:IsDescendantOf(plan.char)
end

-- Sure shots only: whether the shot would land now, and if not, what it is
-- waiting on. The chance is the share of their own past moves the shot would
-- have caught. Returns true, or false and the reason.
function Trigger.sure(plan)
    if plan.ahead then return false, 'waiting to see them for a sure shot' end
    local chance = plan.chance or 0
    if chance < Trigger.SureOdds then
        return false, ('waiting for a sure shot (%d%%)'):format(math.floor(chance * 100 + 0.5))
    end
    return true
end

function Trigger.fireGun(tool, plan, now)
    Trigger.claim('Gun', plan, now)
    if Trigger.gunMethod() == 'Remote' then
        local shoot = tool:FindFirstChild("Shoot")
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local attachment = root and root:FindFirstChild("GunRaycastAttachment")
        if not shoot or not attachment then return false end
        return (pcall(function() shoot:FireServer(attachment.WorldCFrame, plan.fallback) end))
    end
    return (pcall(function() tool:Activate() end))
end

function Trigger.throwKnife(tool, plan, now)
    local events = tool:FindFirstChild("Events")
    local thrown = events and events:FindFirstChild("KnifeThrown")
    local handle = tool:FindFirstChild("Handle")
    if not thrown or not handle then return false end
    Trigger.claim('Knife', plan, now)
    return (pcall(function() thrown:FireServer(handle.CFrame, plan.fallback) end))
end

-- any shot at all, yours or the bot's, restarts the gap before the next one.
-- a gun activation only counts once the hook has actually seen it leave; one
-- that never shows up is retried shortly, and a few of those in a row on auto
-- means the game is not listening for the tool being activated at all
function Trigger.confirm(now)
    local gun, knife = Trigger.gun, Trigger.knife
    if Trigger.sawGun > gun.shotAt then
        gun.shotAt = Trigger.sawGun
        gun.nextAt = math.max(gun.nextAt, Trigger.sawGun + Trigger.interval())
    end
    if Trigger.sawKnife > knife.shotAt then
        knife.shotAt = Trigger.sawKnife
        knife.nextAt = math.max(knife.nextAt, Trigger.sawKnife + Trigger.interval())
    end

    local pending = Trigger.pendingAt
    if pending <= 0 then return end
    if Trigger.sawGun >= pending then
        Trigger.pendingAt = 0
        Trigger.misfires = 0
        Trigger.shots = Trigger.shots + 1
    elseif now - pending > Trigger.Confirm then
        Trigger.pendingAt = 0
        Trigger.misfires = Trigger.misfires + 1
        gun.nextAt = now + Trigger.Retry
        if Trigger.misfires >= Trigger.Misfires and Choice.pick(Choice.Trigger.Method, Trigger.Method) == 'Auto' then
            Trigger.fallback = true
        end
    end
end

function Trigger.run(which, s, now)
    local on = (which == 'Gun' and Trigger.Gun) or (which == 'Knife' and Trigger.Throw)
    local char = LocalPlayer.Character
    local tool = on and char and char:FindFirstChild(which)
    if not tool or not tool:IsA("Tool") then
        s.held, s.target = false, nil
        s.status = on and 'not holding' or 'off'
        return
    end

    -- the first reaction: the weapon has only just come out
    if not s.held then
        s.held = true
        s.readyAt = now + Trigger.delay()
        s.target = nil
    end
    if now < s.readyAt then
        s.status = 'drawing'
        return
    end

    local plan = Trigger.plans[which]
    local origin = which == 'Gun' and findGunOrigin() or findKnifeOrigin()

    if not origin or not Trigger.sees(which, plan, origin, now) then
        -- a split second out of sight is not losing them
        if s.target and now - s.lastSeen > Trigger.Grace then s.target = nil end
        s.status = 'looking'
        return
    end

    -- the second reaction: someone new has just come into view
    s.lastSeen = now
    if s.target ~= plan.char then
        s.target = plan.char
        s.seenAt = now + Trigger.delay()
    end
    if now < s.seenAt then
        s.status = 'reacting to ' .. plan.char.Name
        return
    end

    if now < s.nextAt or (which == 'Gun' and Trigger.pendingAt > 0) then
        s.status = 'waiting to fire again'
        return
    end

    -- the shot waits for the moment it cannot miss
    plan.sure = false
    if Trigger.Sure then
        local ok, reason = Trigger.sure(plan)
        if not ok then
            s.status = reason
            return
        end
        plan.sure = true
    end

    s.status = (plan.ahead and 'firing ahead at ' or plan.sure and 'sure shot at ' or 'firing at ') .. plan.char.Name
    if which == 'Gun' then
        if not Trigger.fireGun(tool, plan, now) then
            s.nextAt = now + Trigger.Retry
        elseif Trigger.hooked then
            Trigger.pendingAt = now
        else
            -- nothing can confirm a shot without the hook, so the attempt is
            -- the best there is
            Trigger.shots = Trigger.shots + 1
            s.nextAt = now + Trigger.interval()
        end
    elseif Trigger.throwKnife(tool, plan, now) then
        Trigger.throws = Trigger.throws + 1
        s.nextAt = now + Trigger.interval()
    else
        s.nextAt = now + Trigger.Retry
    end
end

function Trigger.step(now)
    Trigger.confirm(now)
    Trigger.buildPlans(now, LocalPlayer.Character)
    Trigger.run('Gun', Trigger.gun, now)
    Trigger.run('Knife', Trigger.knife, now)
end

-- every frame: everyone's movement, the sides, the shots waiting to be known
-- as hits or misses, and the trigger bot. silent aim itself solves each shot
-- as it leaves, in the hook below
track(PreSimulation:Connect(function()
    if Unloading or not (Aim.Enabled or Trigger.Gun or Trigger.Throw or #SA.pending > 0) then return end

    pcall(function()
        local now = os.clock()
        cachedPing = cachedPing + (getPing() - cachedPing) * 0.2
        if lastTick > 0 then
            local dt = now - lastTick
            if dt > 0 and dt < 0.5 then
                cachedFrame = cachedFrame + (dt - cachedFrame) * 0.1
            end
        end
        lastTick = now

        SA.sampleAll(now)
        SA.refreshTeams()
        SA.resolve(now)
        Trigger.step(now)
        debugTick(now)
    end)
end))

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall
    local trigger = Trigger

    -- silent aim redirects here, and so does every shot the trigger bot
    -- fires: that one stays on the person it fired at, silent aim on or off.
    -- seeing a shot leave is also what confirms one it asked the gun to fire
    local function onNamecall(self, ...)
        if Unloading or not (Aim.Enabled or trigger.Gun or trigger.Throw)
            or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer"
        then
            return originalNamecall(self, ...)
        end

        if self.Name == "Shoot" and self.ClassName == "RemoteEvent" then
            local parent = self.Parent
            if parent and parent.ClassName == "Tool" and parent.Name == "Gun" then
                trigger.sawGun = os.clock()
                local origin, sent = ...
                local claimed = trigger.claimed('Gun')
                if (Aim.Enabled or claimed) and typeof(origin) == "CFrame" then
                    local redirect = resolveRedirect('Gun', claimed, origin, sent)
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
                trigger.sawKnife = os.clock()
                local handle, sent = ...
                local claimed = trigger.claimed('Knife')
                if (Aim.Enabled or claimed) and typeof(handle) == "CFrame" then
                    local redirect = resolveRedirect('Knife', claimed, handle, sent)
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
    Trigger.hooked = true
end

--// fling --------------------------------------------------------------------
--
-- Every player's client simulates their own character, and takes the velocity
-- reported for everybody else's parts as true. A fling is a contact between
-- them and a part of yours that your client reports moving absurdly fast. What
-- follows are different ways of getting that contact and that report to them:
--
--  * Touch fling (the classic). Right after your physics step - after the frame
--    has been simulated, just before it is sent - your velocity is swapped for
--    an enormous one, and it is put back before the next frame, so your own
--    character never feels it. Anyone who touches you, or you them, gets it.
--  * Spin. A run that sits inside the target, a stud and a half above then
--    below them each frame, spinning and reporting that velocity, until they go.
--  * Ram. Comes at them from alternating sides, the velocity pointed through them.
--  * Orbit. Circles them at arm's length, spinning. The weakest and quietest.
--
-- A run holds you in place with a zero BodyVelocity while it reports, then puts
-- you back where you started.

Fling = {
    Touch = false,       -- the classic touch fling
    TouchSpin = false,   -- report a spin with it as well
    OnTouch = false,     -- run on anyone who touches you
    Tap = false,         -- tap or click a player to run on them
    Loop = false,        -- keep running on targets, nearest first
    Method = Choice.Fling.Method.default,
    Power = Choice.Fling.Power.default,
    Reach = Choice.Fling.Reach.default,
    Targets = Choice.Fling.Targets.default,
    Orbit = Choice.Fling.Orbit.default,
    Patience = Choice.Fling.Patience.default,

    busy = false,        -- a run is going
    target = nil,        -- the player it is on
    cancel = false,
    armed = false,       -- the touch fling found someone in reach this frame
    claimed = false,     -- the touch fling's report is live right now
    saved = nil,
    savedSpin = nil,
    nudge = 0.1,
    runs = 0,
    flung = 0,
    cooldown = {},
    savedHeight = nil,
    tapStart = nil,
}

-- A flung player picks up a speed nothing in normal play produces, or goes up.
Fling.FLUNG_SPEED = 120
Fling.FLUNG_RISE = 12
-- seconds before the same player can be run on again
Fling.RETRY = 3
-- how far ahead of a moving target to sit: what they have covered since the
-- position we see was sent
Fling.LEAD = 0.15
Fling.GUARD_NAME = "MM2FlingGuard"

function Fling.allowed(plr)
    if plr == LocalPlayer or not isAlivePlr(plr) then return false end
    local mode = Fling.Targets
    if mode == 'Murderer only' then return isMurderer(plr) end
    if mode == 'Sheriff only' then
        local role = roleOf(plr)
        return role == 'Sheriff' or role == 'Hero'
    end
    if mode == 'Armed only' then return heldWeapon(plr.Character) ~= nil end
    return true
end

function Fling.myRoot()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum.RootPart, hum
end

-- AssemblyLinearVelocity is the current name; the old one is kept as a fallback
-- so this still works on an older client. A nil argument is left alone.
function Fling.setVelocity(root, linear, angular)
    if linear then
        pcall(function() root.AssemblyLinearVelocity = linear end)
        pcall(function() root.Velocity = linear end)
    end
    if angular then
        pcall(function() root.AssemblyAngularVelocity = angular end)
        pcall(function() root.RotVelocity = angular end)
    end
end

function Fling.rootOf(plr)
    local char = plr and plr.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

-- the nearest player this may go for, skipping anyone run on a moment ago
function Fling.nearest(maxDistance)
    local root = Fling.myRoot()
    if not root then return nil end
    local best, bestDistance
    local now = os.clock()
    for _, plr in ipairs(Players:GetPlayers()) do
        if Fling.allowed(plr) and (Fling.cooldown[plr] or 0) <= now then
            local theirRoot = Fling.rootOf(plr)
            local distance = theirRoot and (theirRoot.Position - root.Position).Magnitude
            if distance and (not maxDistance or distance <= maxDistance) and (not best or distance < bestDistance) then
                best, bestDistance = plr, distance
            end
        end
    end
    return best
end

--// touch fling

function Fling.touchArmed(root)
    local reach = Choice.valueOf(Choice.Fling.Reach, Fling.Reach)
    if reach == math.huge then return true end
    for _, plr in ipairs(Players:GetPlayers()) do
        if Fling.allowed(plr) then
            local theirRoot = Fling.rootOf(plr)
            if theirRoot and (theirRoot.Position - root.Position).Magnitude <= reach then return true end
        end
    end
    return false
end

-- after the physics step: the enormous velocity, which is what gets sent
function Fling.touchClaim()
    Fling.armed = false
    if Unloading or not Fling.Touch or Fling.busy or Fling.claimed then return end
    local root, hum = Fling.myRoot()
    if not root or not hum or hum.Health <= 0 or not Fling.touchArmed(root) then return end
    local power = Choice.valueOf(Choice.Fling.Power, Fling.Power)
    local velocity = root.AssemblyLinearVelocity
    Fling.saved = velocity
    Fling.savedSpin = root.AssemblyAngularVelocity
    Fling.claimed = true
    Fling.armed = true
    Fling.setVelocity(root, velocity * power.touch + Vector3.new(0, power.touch, 0),
        Fling.TouchSpin and Vector3.new(0, power.touch, 0) or nil)
end

-- before the next frame: your own velocity back, so your next step starts from
-- exactly what you were doing and nothing about your character moves
function Fling.touchRestore()
    if not Fling.claimed then return end
    Fling.claimed = false
    local root = Fling.myRoot()
    if root and Fling.saved then
        Fling.setVelocity(root, Fling.saved, Fling.TouchSpin and Fling.savedSpin or nil)
    end
end

-- and just before the step, a tenth of a stud a second up or down, alternating,
-- so a contact never settles into resting
function Fling.touchNudge()
    Fling.touchRestore()
    if not Fling.armed or Fling.busy then return end
    local root = Fling.myRoot()
    if not root then return end
    Fling.nudge = -Fling.nudge
    Fling.setVelocity(root, root.AssemblyLinearVelocity + Vector3.new(0, Fling.nudge, 0), nil)
end

--// runs

-- Reporting a velocity that size would throw you as hard as it throws them. A
-- BodyVelocity pinned at zero with effectively unlimited force cancels your own
-- motion, while the report still goes out - that asymmetry is why they go and
-- you do not. The seated state would zero the report outright, and
-- FallenPartsDestroyHeight goes to NaN, which every comparison fails, so nothing
-- of yours is deleted for being briefly somewhere absurd.
function Fling.protect(root, hum)
    local guard = Instance.new("BodyVelocity")
    guard.Name = Fling.GUARD_NAME
    guard.Velocity = Vector3.zero
    guard.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    guard.Parent = root

    if hum then
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false) end)
    end

    if Fling.savedHeight == nil then Fling.savedHeight = Workspace.FallenPartsDestroyHeight end
    pcall(function() Workspace.FallenPartsDestroyHeight = 0 / 0 end)

    return guard
end

function Fling.unprotect(guard, hum)
    if guard then pcall(function() guard:Destroy() end) end
    if hum then
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end)
    end
    if Fling.savedHeight ~= nil then
        local height = Fling.savedHeight
        Fling.savedHeight = nil
        pcall(function() Workspace.FallenPartsDestroyHeight = height end)
    end
end

-- One CFrame write does not bring you home: the next step can move you again,
-- the other limbs still carry their own velocity, and a tumbled humanoid will
-- not stand up on its own. So this keeps putting you back, every part zeroed,
-- until you are actually there.
function Fling.goHome(home, homeChar)
    if not home or not homeChar then return end

    local deadline = os.clock() + 3
    repeat
        if Unloading or LocalPlayer.Character ~= homeChar then break end

        pcall(function()
            for _, part in ipairs(homeChar:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.AssemblyLinearVelocity = Vector3.zero
                    part.AssemblyAngularVelocity = Vector3.zero
                end
            end

            local root = homeChar:FindFirstChild("HumanoidRootPart")
            if root then root.CFrame = home end

            local hum = homeChar:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.PlatformStand = false
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end)

        task.wait()

        local root = homeChar:FindFirstChild("HumanoidRootPart")
        if not root or (root.Position - home.Position).Magnitude < 6 then break end
    until os.clock() > deadline
end

-- where your root goes this frame, and what it reports
function Fling.place(method, theirRoot, step, power)
    local velocity = theirRoot.AssemblyLinearVelocity
    local lead = Vector3.new(velocity.X, 0, velocity.Z) * Fling.LEAD
    if lead.Magnitude > 6 then lead = lead.Unit * 6 end
    local at = theirRoot.Position + lead
    local spin = Vector3.new(power.angular, power.angular, power.angular)

    if method == 'Orbit' then
        local radius = Choice.valueOf(Choice.Fling.Orbit, Fling.Orbit)
        local angle = step * 0.35
        return CFrame.new(at + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)), nil, spin
    end

    if method == 'Ram' then
        local side = (step % 2 == 0) and 1 or -1
        local from = at + theirRoot.CFrame.RightVector * (2.5 * side)
        local through = (at - from).Unit
        return CFrame.lookAt(from, at),
            through * power.linear + Vector3.new(0, power.linear * power.lift * 0.2, 0), spin
    end

    local up = (step % 2 == 0) and 1.5 or -1.5
    return CFrame.new(at + Vector3.new(0, up, 0)) * CFrame.Angles(math.rad(step * 100), 0, 0),
        Vector3.new(power.linear, power.linear * power.lift, power.linear), spin
end

-- flung means actually going somewhere: up, or fast and away. Someone who is
-- flinging reports a huge speed too, but stays where they are
function Fling.landed(theirRoot, theirHum, start)
    if theirHum and theirHum.Health <= 0 then return true end
    local moved = theirRoot.Position - start
    if moved.Y > Fling.FLUNG_RISE then return true end
    return theirRoot.AssemblyLinearVelocity.Magnitude > Fling.FLUNG_SPEED and moved.Magnitude > 4
end

-- a run on one player, from wherever you are, back to where you started
function Fling.run(plr, why)
    if Fling.busy or Unloading or not plr or plr == LocalPlayer then return false end
    local char = plr.Character
    local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
    local root, hum = Fling.myRoot()
    if not theirRoot or not root or not hum or hum.Health <= 0 then return false end

    Fling.touchRestore()
    Fling.busy = true
    Fling.cancel = false
    Fling.target = plr
    Fling.runs = Fling.runs + 1
    Fling.cooldown[plr] = os.clock() + Fling.RETRY

    task.spawn(function()
        local homeChar = LocalPlayer.Character
        local home = root.CFrame
        local guard

        local ok = pcall(function()
            guard = Fling.protect(root, hum)

            local method = Choice.pick(Choice.Fling.Method, Fling.Method)
            local power = Choice.valueOf(Choice.Fling.Power, Fling.Power)
            local deadline = os.clock() + Choice.valueOf(Choice.Fling.Patience, Fling.Patience)
            local start = theirRoot.Position
            local step = 0

            while os.clock() < deadline and not Fling.cancel and not Unloading do
                if LocalPlayer.Character ~= homeChar or not root.Parent or not theirRoot.Parent then break end
                if Fling.landed(theirRoot, char:FindFirstChildOfClass("Humanoid"), start) then
                    Fling.flung = Fling.flung + 1
                    break
                end

                step = step + 1
                local cf, linear, spin = Fling.place(method, theirRoot, step, power)
                root.CFrame = cf
                Fling.setVelocity(root, linear, spin)
                task.wait()
            end
        end)

        -- teardown runs whatever happened above, a thrown error included, so a
        -- failure part way through can never strand you mid report
        pcall(function()
            local live = homeChar and homeChar:FindFirstChild("HumanoidRootPart")
            if live then Fling.setVelocity(live, Vector3.zero, Vector3.zero) end
            Fling.unprotect(guard, hum)
            Fling.goHome(home, homeChar)
        end)

        Fling.busy = false
        Fling.target = nil
        if not ok then Fling.reset() end
    end)

    return true
end

function Fling.stop()
    Fling.cancel = true
end

-- everything off and put back: for unload, and after an error
function Fling.reset()
    Fling.cancel = true
    Fling.touchRestore()
    Fling.armed = false

    local char = LocalPlayer.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        local stale = root and root:FindFirstChild(Fling.GUARD_NAME)
        if stale then pcall(function() stale:Destroy() end) end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end)
        end
    end

    if Fling.savedHeight ~= nil then
        local height = Fling.savedHeight
        Fling.savedHeight = nil
        pcall(function() Workspace.FallenPartsDestroyHeight = height end)
    end
end

--// ways to start a run

-- Touched fires many times a second against one body, so each player gets one
-- run and then a short cooldown.
function Fling.onTouched(hit)
    if not Fling.OnTouch or Fling.busy or Unloading or typeof(hit) ~= "Instance" then return end
    local char = hit.Parent
    local plr = char and Players:GetPlayerFromCharacter(char)
    if not plr or not Fling.allowed(plr) or (Fling.cooldown[plr] or 0) > os.clock() then return end
    Fling.run(plr, 'touched')
end

function Fling.watchCharacter(char)
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            track(part.Touched:Connect(Fling.onTouched))
        end
    end
    track(char.DescendantAdded:Connect(function(inst)
        if inst:IsA("BasePart") then
            track(inst.Touched:Connect(Fling.onTouched))
        end
    end))
end

-- sheriff also matches hero, since a hero is whoever picked the gun up after
-- the sheriff died and is the same threat
function Fling.byRole(wanted)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) then
            local role = roleOf(plr)
            local match = role == wanted or (wanted == 'Sheriff' and role == 'Hero')
            if match and Fling.run(plr, wanted) then
                return plr.Name
            end
        end
    end
    return nil
end

function Fling.runNearest()
    local plr = Fling.nearest()
    if plr and Fling.run(plr, 'nearest') then return plr.Name end
    return nil
end

-- the player whose body is under a point on the screen; accessories and tools
-- sit a model deeper than the character, so this climbs until it finds one
function Fling.playerAt(screenPos)
    local ray = Camera:ScreenPointToRay(screenPos.X, screenPos.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
    local model = result and result.Instance and result.Instance:FindFirstAncestorOfClass("Model")
    while model do
        local plr = Players:GetPlayerFromCharacter(model)
        if plr then return plr end
        model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
    end
    return nil
end

-- a quick tap or click, not a drag of the camera or a held press
function Fling.isPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or not Fling.Tap or not Fling.isPress(input) then return end
    Fling.tapStart = { at = os.clock(), pos = input.Position }
end))

track(UserInputService.InputEnded:Connect(function(input)
    local start = Fling.tapStart
    if not start or not Fling.Tap or not Fling.isPress(input) then return end
    Fling.tapStart = nil
    if os.clock() - start.at > 0.35 or (input.Position - start.pos).Magnitude > 12 then return end
    local ok, plr = pcall(Fling.playerAt, input.Position)
    if ok and plr and Fling.allowed(plr) then Fling.run(plr, 'tap') end
end))

task.spawn(function()
    if LocalPlayer.Character then Fling.watchCharacter(LocalPlayer.Character) end
end)
track(LocalPlayer.CharacterAdded:Connect(function(char)
    Fling.busy = false
    Fling.target = nil
    Fling.claimed = false
    table.clear(Fling.cooldown)
    task.spawn(Fling.watchCharacter, char)
end))

track(Players.PlayerRemoving:Connect(function(plr)
    Fling.cooldown[plr] = nil
end))

-- keep going through targets, nearest first
task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        if Fling.Loop and not Fling.busy then
            local plr = Fling.nearest()
            if plr then Fling.run(plr, 'loop') end
        end
    end
end)

--// anti fling ---------------------------------------------------------------
--
-- Nobody else can put anything into your character, and nothing they do runs
-- on your client. The one way a fling reaches you is a contact with a part of
-- theirs that is reported moving absurdly fast. So this looks at them, not at
-- you: anyone whose own root reports a spin or a speed that normal play never
-- produces is marked, and for as long as they are, their parts stop colliding
-- with you and their velocity reads zero before each of your steps. Your own
-- motion is only checked as a backstop, and only for what a fling does to a
-- body: tumbling end over end, or being thrown faster than anything can move
-- you. Turning spins you about the vertical axis and is never counted, and the
-- movers the game puts in your character are its own business.

AntiFling = {
    Enabled = false,
    Method = Choice.Fling.AntiMethod.default,
    Guard = Choice.Fling.Guard.default,
    Tell = true,

    saved = 0,       -- times you were caught being thrown and steadied
    caught = 0,      -- flingers spotted
    flagged = {},    -- [player] = marked until
    strikes = {},    -- [player] = frames in a row reading abnormal
    since = {},      -- [player] = { at, pos } when this marking began
    told = {},       -- [player] = when we last said so
    ghosted = {},    -- [part] = its CanCollide before we touched it
    selfStrikes = 0,
    safe = nil,
    safeChar = nil,
    safeAt = 0,
}

function AntiFling.limits() return Choice.valueOf(Choice.Fling.Guard, AntiFling.Guard) end
function AntiFling.method() return Choice.pick(Choice.Fling.AntiMethod, AntiFling.Method) end

function AntiFling.isFlagged(plr, now)
    return (AntiFling.flagged[plr] or 0) > (now or os.clock())
end

-- someone reporting a spin or a speed no normal movement makes. Two frames in a
-- row, or one that is way past it; a mark lasts two seconds past the last one
function AntiFling.scan(limits, now)
    for _, plr in ipairs(Players:GetPlayers()) do
        local root = plr ~= LocalPlayer and Fling.rootOf(plr)
        if root then
            local linear = root.AssemblyLinearVelocity
            local spin = root.AssemblyAngularVelocity.Magnitude
            local speed = Vector3.new(linear.X, 0, linear.Z).Magnitude
            local abnormal = spin > limits.spin or speed > limits.speed or linear.Y > limits.speed
            local extreme = spin > limits.spin * 5 or speed > limits.speed * 5 or linear.Y > limits.speed * 5

            if abnormal then
                AntiFling.strikes[plr] = (AntiFling.strikes[plr] or 0) + 1
                if extreme or AntiFling.strikes[plr] >= 2 then
                    if not AntiFling.isFlagged(plr, now) then
                        AntiFling.since[plr] = { at = now, pos = root.Position, said = false }
                    end
                    AntiFling.flagged[plr] = now + 2
                    AntiFling.tell(plr, root, now)
                end
            else
                AntiFling.strikes[plr] = 0
            end
        end
    end
end

-- a flinger keeps reporting that velocity while going nowhere; someone who was
-- flung reports it too but is actually flying off, so they are left out of this
function AntiFling.tell(plr, root, now)
    local since = AntiFling.since[plr]
    if not since or since.said or now - since.at < 0.5 then return end
    if (root.Position - since.pos).Magnitude > 25 then return end
    since.said = true
    AntiFling.caught = AntiFling.caught + 1
    if AntiFling.Tell and now - (AntiFling.told[plr] or -1e9) > 30 then
        AntiFling.told[plr] = now
        pcall(function()
            Onyx:Notify({ Title = 'anti fling', Content = plr.Name .. ' is flinging - they cannot touch you', Type = 'warning', Duration = 4 })
        end)
    end
end

function AntiFling.flingerNear(root, distance, now)
    for plr in pairs(AntiFling.flagged) do
        if AntiFling.isFlagged(plr, now) then
            local theirRoot = Fling.rootOf(plr)
            if theirRoot and (theirRoot.Position - root.Position).Magnitude <= distance then return true end
        end
    end
    return false
end

function AntiFling.shouldGhost(plr, now)
    -- a run of ours needs the contact
    if plr == Fling.target then return false end
    if AntiFling.isFlagged(plr, now) then return true end
    -- nobody at all, unless something of ours needs people to be touchable
    return AntiFling.method() == 'No collide' and not Fling.Touch and not Fling.OnTouch
end

function AntiFling.restoreAll()
    for part, original in pairs(AntiFling.ghosted) do
        if part.Parent then pcall(function() part.CanCollide = original end) end
        AntiFling.ghosted[part] = nil
    end
end

-- before your physics step: marked players' parts stop colliding, and their
-- reported velocity reads zero for this step
function AntiFling.beforeStep()
    if Unloading or not AntiFling.Enabled then
        if next(AntiFling.ghosted) then AntiFling.restoreAll() end
        return
    end

    local now = os.clock()
    AntiFling.scan(AntiFling.limits(), now)

    local keep = {}
    if AntiFling.method() ~= 'Guard' then
        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr ~= LocalPlayer and plr.Character
            if char and AntiFling.shouldGhost(plr, now) then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if AntiFling.ghosted[part] == nil then AntiFling.ghosted[part] = part.CanCollide end
                        part.CanCollide = false
                        keep[part] = true
                    end
                end
                if AntiFling.isFlagged(plr, now) then
                    local root = char:FindFirstChild("HumanoidRootPart")
                    if root then
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end
                end
            end
        end
    end

    -- hand back whatever no longer needs it
    for part, original in pairs(AntiFling.ghosted) do
        if not keep[part] then
            if part.Parent then pcall(function() part.CanCollide = original end) end
            AntiFling.ghosted[part] = nil
        end
    end
end

-- after your physics step: the backstop. Only tumbling or being thrown counts,
-- two frames in a row (or once, way past it); Smart only steps in when someone
-- flinging is close by or it is way past it
function AntiFling.afterStep()
    if Unloading or not AntiFling.Enabled or Fling.busy or Fling.claimed then return end

    local root, hum = Fling.myRoot()
    local char = LocalPlayer.Character
    if not root or not hum or hum.Health <= 0 then
        AntiFling.safe = nil
        return
    end

    local limits = AntiFling.limits()
    local now = os.clock()
    local linear = root.AssemblyLinearVelocity
    local angular = root.AssemblyAngularVelocity
    local tumble = Vector3.new(angular.X, 0, angular.Z).Magnitude
    local speed = Vector3.new(linear.X, 0, linear.Z).Magnitude
    local thrown = tumble > limits.tumble or speed > limits.thrown or linear.Y > limits.thrown
    local extreme = tumble > limits.tumble * 4 or speed > limits.thrown * 4 or linear.Y > limits.thrown * 4

    if not thrown then
        AntiFling.selfStrikes = 0
        -- somewhere you got to under your own power, to go back to
        if speed < 60 and tumble < 8 and math.abs(linear.Y) < 80 then
            AntiFling.safe, AntiFling.safeChar, AntiFling.safeAt = root.CFrame, char, now
        end
        return
    end

    AntiFling.selfStrikes = AntiFling.selfStrikes + 1
    if not extreme and AntiFling.selfStrikes < 2 then return end
    if AntiFling.method() == 'Smart' and not extreme and not AntiFling.flingerNear(root, 30, now) then return end

    AntiFling.selfStrikes = 0
    AntiFling.saved = AntiFling.saved + 1
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
    if AntiFling.safe and AntiFling.safeChar == char and now - AntiFling.safeAt < 3
        and (root.Position - AntiFling.safe.Position).Magnitude > 4 then
        root.CFrame = AntiFling.safe
    end
    if tumble > limits.tumble then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end
end

track(Players.PlayerRemoving:Connect(function(plr)
    AntiFling.flagged[plr] = nil
    AntiFling.strikes[plr] = nil
    AntiFling.since[plr] = nil
    AntiFling.told[plr] = nil
end))

--// the frame
-- before the physics step: the touch fling's nudge (its report already taken
-- back), and anti fling taking marked players out of your step
track(PreSimulation:Connect(function()
    pcall(Fling.touchNudge)
    pcall(AntiFling.beforeStep)
end))

-- after it: anti fling's backstop looks at what the step did to you, then the
-- touch fling puts its report up to be sent
track(RunService.Heartbeat:Connect(function()
    pcall(AntiFling.afterStep)
    local ok = pcall(Fling.touchClaim)
    if not ok then Fling.reset() end
end))

-- and before the next frame renders, the touch fling's report comes back down
track(resolveEvent("PreRender", "RenderStepped"):Connect(function()
    pcall(Fling.touchRestore)
end))

local SilentAimTab = Window:CreateTab({ Title = 'silent aim v2' })

do
    local MainSection = SilentAimTab:CreateSection('silent aim v2')

    addStat(MainSection, {
        Title = 'hook api',
        Value = hasNamecallHook and 'available' or 'missing',
        Color = hasNamecallHook and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
    })

    MainSection:Toggle({
        Title = 'silent aim',
        Description = 'every gun shot and knife throw goes to the target nearest where you fired, led by how that person really moves',
        Flag = 'mm2_sa2',
        Callback = function(state)
            if state and not hasNamecallHook then
                Onyx:Notify({
                    Title = 'mm2',
                    Content = 'hookmetamethod/getnamecallmethod not available on this executor.',
                    Type = 'error',
                    Duration = 6,
                })
            end
            Aim.Enabled = state
        end,
    })

    MainSection:Dropdown({
        Title = 'targets',
        Description = 'enemies works in every mode: the murderer while you are sheriff or hero, everyone while you are the murderer, the other side in infection or freeze tag, everyone when there are no sides. anyone takes whoever is nearest your shot',
        Values = Choice.Targets.order,
        Default = Choice.Targets.default,
        Flag = 'mm2_sa2_targets',
        Callback = function(value) Aim.Targets = Choice.pick(Choice.Targets, value) end,
    })

    MainSection:Toggle({
        Title = 'wall check',
        Description = 'only redirects when the shot has a clear line to the point it is sent to',
        Flag = 'mm2_sa2_wallcheck',
        Default = true,
        Callback = function(state) Aim.WallCheck = state end,
    })

    MainSection:Slider({
        Title = 'fov',
        Description = 'degrees either side of where you fired that a target may be. 0 takes anyone on screen',
        Min = 0,
        Max = 90,
        Increment = 1,
        Suffix = ' deg',
        Default = 0,
        Flag = 'mm2_sa2_fov',
        Callback = function(value) Aim.Fov = tonumber(value) or 0 end,
    })
end

do
    local LeadSection = SilentAimTab:CreateSection('lead')

    LeadSection:Toggle({
        Title = 'learn the lead',
        Description = 'after every shot it checks whether they really went down, and works out your real delay from it. kept between sessions',
        Flag = 'mm2_sa2_learn',
        Default = true,
        Callback = function(state) Aim.Learn = state end,
    })

    LeadSection:Slider({
        Title = 'lead trim',
        Description = 'added on top of what it learns. raise it if shots land behind people, lower it if they land in front',
        Min = -150,
        Max = 150,
        Increment = 5,
        Suffix = ' ms',
        Default = 0,
        Flag = 'mm2_sa2_trim',
        Callback = function(value) Aim.Trim = tonumber(value) or 0 end,
    })

    LeadSection:Button({
        Title = 'forget the learned lead',
        Callback = function()
            SA.forgetLead()
            Onyx:Notify({ Title = 'mm2', Content = 'learned lead cleared', Type = 'success', Duration = 3 })
        end,
    })

    SA.ui = {
        target = addStat(LeadSection, { Title = 'target', Value = '-' }),
        lead = addStat(LeadSection, { Title = 'lead', Value = '-' }),
        learned = addStat(LeadSection, { Title = 'learned delay', Value = '-' }),
        landed = addStat(LeadSection, { Title = 'shots landed', Value = '0 / 0' }),
    }
    knifeSpeedStat = addStat(LeadSection, { Title = 'knife speed (read from the game)', Value = ('%d studs/s'):format(SA.knifeSpeed) })

    LeadSection:Label({
        Title = 'It aims where each person has really been going: their own last few seconds of movement, matched to what they are doing now, and jump physics for anyone in the air or spamming jump. Chance is how much of that movement the shot would have caught. Lead is your round trip plus the delay it has learned from your own hits and misses.',
    })
end

-- what silent aim would take right now for the weapon in your hands, for the
-- readout: the camera stands in for a shot
function SA.preview()
    local char = LocalPlayer.Character
    if not char then return nil end
    local which = char:FindFirstChild("Gun") and 'Gun' or char:FindFirstChild("Knife") and 'Knife' or nil
    if not which then return nil end
    local origin = which == 'Gun' and findGunOrigin() or findKnifeOrigin()
    return SA.plan(which, origin, Camera.CFrame.LookVector, os.clock(),
        Choice.pick(Choice.Targets, Aim.Targets) == 'Anyone'), which
end

function SA.readout()
    local ui = SA.ui
    if not ui then return end
    local plan, which = nil, nil
    if Aim.Enabled or Trigger.Gun or Trigger.Throw then plan, which = SA.preview() end
    if plan then
        ui.target.Set(('%s, %d%% chance'):format(plan.char.Name, math.floor((plan.chance or 0) * 100 + 0.5)),
            Color3.fromRGB(126, 217, 87))
        local delay = SA.delay(which)
        ui.lead.Set(('%d ms = trip %d + delay %d + trim %d%s'):format(
            math.floor(plan.travel * 1000 + 0.5),
            math.floor(cachedPing * 1000 + 0.5),
            math.floor(delay * 1000 + 0.5),
            math.floor((tonumber(Aim.Trim) or 0) + 0.5),
            (plan.flight or 0) > 0 and (' + flight %d'):format(math.floor(plan.flight * 1000 + 0.5)) or ''))
    else
        ui.target.Set(Aim.Enabled and 'none in reach' or 'off')
        ui.lead.Set(('- (round trip %d ms)'):format(math.floor(cachedPing * 1000 + 0.5)))
    end
    local function learnt(name)
        local cal = SA.cal[name]
        if not Aim.Learn then return 'off' end
        if not cal then
            local saved = SA.saved and SA.saved[name]
            return saved and ('%d ms (saved)'):format(math.floor(saved * 1000 + 0.5)) or 'learning'
        end
        return ('%d ms from %d shots'):format(math.floor(cal.best * 1000 + 0.5), cal.used)
    end
    ui.learned.Set(('gun %s, knife %s'):format(learnt('Gun'), learnt('Knife')))
    ui.landed.Set(('%d / %d'):format(shotStats.hits, shotStats.resolved))
end

SA.load()

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
Visual = {
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
    SA.forget(plr)
end))

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
Xray = {
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

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
TrapEsp = { Enabled = false }
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

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
DroppedGunEsp = { Enabled = false }
local droppedGunObjects = {}

-- The gun on the floor is not always a Tool. In the map it turns up as a
-- GunDrop model sitting under the map folder, which the tool check alone never
-- matched - that is why gun esp was finding nothing once the sheriff died.
local function isDroppedGun(inst)
    if typeof(inst) ~= "Instance" then return false end

    local parent = inst.Parent
    if parent == nil then return false end
    if Players:GetPlayerFromCharacter(parent) ~= nil then return false end

    if isGunTool(inst) then return true end

    if inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder") then
        local name = inst.Name:lower()
        if name:find("gundrop") or name == "droppedgun" then
            -- a GunDrop model holds parts that may also carry the name; only
            -- the outermost one is the drop, so anything nested inside one
            -- already covered is skipped
            local ancestor = parent
            while ancestor and ancestor ~= Workspace do
                local up = ancestor.Name:lower()
                if up:find("gundrop") or up == "droppedgun" then return false end
                ancestor = ancestor.Parent
            end
            return true
        end
    end

    return false
end

-- Highlight needs geometry to adorn. A GunDrop can be a model with no
-- PrimaryPart, or a folder, neither of which shows anything on its own, so
-- this digs out something that will actually render.
local function gunAdornee(item)
    if item:IsA("BasePart") then return item, item end

    if item:IsA("Model") then
        local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart", true)
        if part then return item, part end
        return nil, nil
    end

    local part = item:FindFirstChildWhichIsA("BasePart", true)
    if part then return part, part end
    return nil, nil
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

    local adornee, anchorPart = gunAdornee(item)
    if not adornee then return end

    local hl = Instance.new("Highlight")
    hl.FillColor = GUN_ESP_COLOR
    hl.OutlineColor = GUN_ESP_COLOR
    hl.FillTransparency = 0.3
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    -- adorned explicitly rather than by parenting, so it still shows when the
    -- drop is a folder or a model that cannot be adorned by itself
    hl.Adornee = adornee
    hl.Parent = adornee

    local marker = nil
    local handle = item:FindFirstChild("Handle") or anchorPart
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
            local handle = item:FindFirstChild("Handle") or select(2, gunAdornee(item))
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

--// auto grab gun ------------------------------------------------------------
--
-- The drop is tracked whether or not esp is on, because grabbing needs to know
-- where the gun is regardless of whether you are being shown it.

AutoGun = {
    Enabled = false,
    Method = Choice.Fling.Grab.default,
    Range = 250,
    grabs = 0,
    drops = {},
    lastTry = 0,
}

-- firetouchinterest needs a part the game is actually listening for contact on.
-- A TouchTransmitter is the child Roblox creates when something connects
-- Touched, so a part carrying one is the part the pickup is wired to.
function AutoGun.touchPart(item)
    if item:IsA("BasePart") and item:FindFirstChildOfClass("TouchTransmitter") then
        return item
    end

    for _, inst in ipairs(item:GetDescendants()) do
        if inst:IsA("BasePart") and inst:FindFirstChildOfClass("TouchTransmitter") then
            return inst
        end
    end

    -- nothing is advertising a listener, so fall back to any geometry and let
    -- the touch land where it may
    return select(2, gunAdornee(item))
end

function AutoGun.grab(item)
    if Unloading or not item or not item.Parent then return false end

    local root = Fling.myRoot()
    if not root then return false end

    local part = AutoGun.touchPart(item)
    if not part then return false end

    if (part.Position - root.Position).Magnitude > AutoGun.Range then return false end

    if AutoGun.Method == 'Teleport' then
        local home = root.CFrame
        local homeChar = LocalPlayer.Character
        task.spawn(function()
            pcall(function()
                root.CFrame = CFrame.new(part.Position)
                task.wait(0.2)
                if LocalPlayer.Character == homeChar and root.Parent then
                    root.CFrame = home
                end
            end)
        end)
        AutoGun.grabs = AutoGun.grabs + 1
        return true
    end

    if typeof(firetouchinterest) ~= "function" then return false end

    -- 0 opens the contact and 1 closes it; the pair together is one touch
    local ok = pcall(function()
        firetouchinterest(root, part, 0)
        task.wait()
        firetouchinterest(root, part, 1)
    end)
    if ok then AutoGun.grabs = AutoGun.grabs + 1 end
    return ok
end

task.spawn(function()
    while not Unloading do
        task.wait(0.4)
        if AutoGun.Enabled and heldWeapon(LocalPlayer.Character) ~= "Gun" then
            pcall(function()
                for item in pairs(AutoGun.drops) do
                    if item.Parent and isDroppedGun(item) then
                        if AutoGun.grab(item) then break end
                    else
                        AutoGun.drops[item] = nil
                    end
                end
            end)
        end
    end
end)

local function noteGunDrop(inst)
    if not isDroppedGun(inst) then return end
    AutoGun.drops[inst] = true
    if DroppedGunEsp.Enabled then buildDroppedGunEsp(inst) end
end

task.spawn(function()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if isDroppedGun(inst) then AutoGun.drops[inst] = true end
    end
end)

track(Workspace.DescendantAdded:Connect(noteGunDrop))

track(Workspace.DescendantRemoving:Connect(function(inst)
    AutoGun.drops[inst] = nil
    if droppedGunObjects[inst] then destroyDroppedGunEsp(inst) end
end))


do
    local TriggerTab = Window:CreateTab({ Title = 'trigger bot' })
    local section = TriggerTab:CreateSection('gun')

    section:Toggle({
        Title = 'trigger bot',
        Description = 'shoots once an enemy has been in view for your reaction time. only while the gun is already in your hands, and never at someone on your side',
        Flag = 'mm2_tb_gun',
        Default = false,
        Callback = function(state) Trigger.Gun = state end,
    })

    section:Dropdown({
        Title = 'fire method',
        Description = 'activate clicks through the gun itself, remote sends the shot straight. auto tries activate and switches if it never fires',
        Values = Choice.Trigger.Method.order,
        Default = Choice.Trigger.Method.default,
        Flag = 'mm2_tb_method',
        Callback = function(value)
            -- picking a method again also forgets what auto had worked out
            Trigger.Method = Choice.pick(Choice.Trigger.Method, value)
            Trigger.misfires = 0
            Trigger.fallback = false
        end,
    })

    section = TriggerTab:CreateSection('knife')

    section:Toggle({
        Title = 'throw trigger bot',
        Description = 'throws once a target has been in view for your reaction time. only while the knife is already in your hands',
        Flag = 'mm2_tb_throw',
        Default = false,
        Callback = function(state) Trigger.Throw = state end,
    })

    section:Dropdown({
        Title = 'throw range',
        Description = 'further than this and they have time to walk out of the way',
        Values = Choice.Trigger.ThrowRange.order,
        Default = Choice.Trigger.ThrowRange.default,
        Flag = 'mm2_tb_throw_range',
        Callback = function(value) Trigger.ThrowRange = Choice.pick(Choice.Trigger.ThrowRange, value) end,
    })

    section = TriggerTab:CreateSection('timing')

    section:Slider({
        Title = 'reaction time',
        Description = 'waited once after the weapon comes out, and again once a target is first seen after that. 0 goes past instant: it fires on the prediction itself, the moment the shot would land on them, even as they are still stepping out from behind cover',
        Min = 0,
        Max = 1000,
        Increment = 10,
        Suffix = ' ms',
        Default = Trigger.Reaction,
        Flag = 'mm2_tb_reaction',
        Callback = function(value) Trigger.Reaction = tonumber(value) or Trigger.Reaction end,
    })

    section:Dropdown({
        Title = 'reaction variance',
        Description = 'each reaction lands randomly this far either side of the slider',
        Values = Choice.Trigger.Jitter.order,
        Default = Choice.Trigger.Jitter.default,
        Flag = 'mm2_tb_jitter',
        Callback = function(value) Trigger.Jitter = Choice.pick(Choice.Trigger.Jitter, value) end,
    })

    section:Dropdown({
        Title = 'between shots',
        Description = 'how long after a shot or throw really goes out before the next',
        Values = Choice.Trigger.Interval.order,
        Default = Choice.Trigger.Interval.default,
        Flag = 'mm2_tb_interval',
        Callback = function(value) Trigger.Interval = Choice.pick(Choice.Trigger.Interval, value) end,
    })

    section:Dropdown({
        Title = 'sees a target when',
        Description = 'visible is anyone silent aim would take with a clear line. near and on crosshair also need your mouse on or by them',
        Values = Choice.Trigger.Sees.order,
        Default = Choice.Trigger.Sees.default,
        Flag = 'mm2_tb_sees',
        Callback = function(value) Trigger.Sees = Choice.pick(Choice.Trigger.Sees, value) end,
    })

    section:Toggle({
        Title = 'sure shots only',
        Description = 'holds fire until the predicted chance of the shot landing is 90% or more. the readout shows the chance it is waiting on',
        Flag = 'mm2_tb_sure',
        Default = false,
        Callback = function(state) Trigger.Sure = state end,
    })

    section = TriggerTab:CreateSection('readout')

    Trigger.ui = {
        gun = addStat(section, { Title = 'gun', Value = 'off' }),
        knife = addStat(section, { Title = 'knife', Value = 'off' }),
        method = addStat(section, { Title = 'gun fires by', Value = '-' }),
        fired = addStat(section, { Title = 'shots / throws', Value = '0 / 0' }),
    }

    section:Label({
        Title = 'The trigger bot uses silent aim v2 to aim, but only ever at enemies: as sheriff or hero that is the murderer alone, so it cannot get you killed. Every shot it fires is put on the person it decided to fire at, even with silent aim switched off.',
    })
end


do
    local FlingTab = Window:CreateTab({ Title = 'fling' })

    local function say(title, content, ok)
        Onyx:Notify({ Title = title, Content = content, Type = ok and 'success' or 'warning', Duration = 3 })
    end

    local TouchSection = FlingTab:CreateSection('touch fling')

    TouchSection:Toggle({
        Title = 'touch fling',
        Description = 'anyone you touch, or who touches you, goes flying. your own character never feels it',
        Flag = 'mm2_touch_fling',
        Default = false,
        Callback = function(state)
            Fling.Touch = state
            if not state then Fling.touchRestore() end
        end,
    })

    TouchSection:Dropdown({
        Title = 'arm when',
        Description = 'how close someone has to be before it arms. always runs it every frame, like the classic scripts',
        Values = Choice.Fling.Reach.order,
        Default = Choice.Fling.Reach.default,
        Flag = 'mm2_fling_reach',
        Callback = function(value) Fling.Reach = Choice.pick(Choice.Fling.Reach, value) end,
    })

    TouchSection:Toggle({
        Title = 'add spin',
        Description = 'reports a spin as well, which knocks people sideways as well as up',
        Flag = 'mm2_touch_spin',
        Default = false,
        Callback = function(state) Fling.TouchSpin = state end,
    })

    TouchSection:Dropdown({
        Title = 'power',
        Description = 'for the touch fling and for runs. gentle is a shove, absurd is orbit',
        Values = Choice.Fling.Power.order,
        Default = Choice.Fling.Power.default,
        Flag = 'mm2_fling_power',
        Callback = function(value) Fling.Power = Choice.pick(Choice.Fling.Power, value) end,
    })

    local RunSection = FlingTab:CreateSection('fling someone')

    RunSection:Button({
        Title = 'fling murderer',
        Description = 'goes for whoever is holding the knife right now, then brings you back',
        Callback = function()
            local name = Fling.byRole('Murderer')
            say('fling', name and ('going for ' .. name) or 'no living murderer found', name ~= nil)
        end,
    })

    RunSection:Button({
        Title = 'fling sheriff',
        Description = 'matches the hero too, since a hero is whoever picked the gun up',
        Callback = function()
            local name = Fling.byRole('Sheriff')
            say('fling', name and ('going for ' .. name) or 'no living sheriff or hero found', name ~= nil)
        end,
    })

    RunSection:Button({
        Title = 'fling nearest',
        Description = 'the closest player the target filter allows',
        Callback = function()
            local name = Fling.runNearest()
            say('fling', name and ('going for ' .. name) or 'nobody to go for', name ~= nil)
        end,
    })

    RunSection:Button({
        Title = 'stop',
        Description = 'ends the run in progress and brings you back',
        Callback = function() Fling.stop() end,
    })

    RunSection:Toggle({
        Title = 'tap a player to fling them',
        Description = 'a quick tap or click on someone starts a run on them. dragging the camera does not count',
        Flag = 'mm2_fling_tap',
        Default = false,
        Callback = function(state) Fling.Tap = state end,
    })

    RunSection:Toggle({
        Title = 'fling back whoever touches you',
        Description = 'anyone who brushes against you gets a run, then a few seconds of cooldown',
        Flag = 'mm2_fling_back',
        Default = false,
        Callback = function(state) Fling.OnTouch = state end,
    })

    RunSection:Toggle({
        Title = 'keep flinging targets',
        Description = 'one run after another, nearest first, on whoever the target filter allows',
        Flag = 'mm2_fling_loop',
        Default = false,
        Callback = function(state)
            Fling.Loop = state
            if not state then Fling.stop() end
        end,
    })

    RunSection:Dropdown({
        Title = 'method',
        Description = 'spin sits inside them going above and below; ram comes at them from the sides; orbit circles them and is the weakest',
        Values = Choice.Fling.Method.order,
        Default = Choice.Fling.Method.default,
        Flag = 'mm2_fling_method',
        Callback = function(value) Fling.Method = Choice.pick(Choice.Fling.Method, value) end,
    })

    RunSection:Dropdown({
        Title = 'targets',
        Values = Choice.Fling.Targets.order,
        Default = Choice.Fling.Targets.default,
        Flag = 'mm2_fling_targets',
        Callback = function(value) Fling.Targets = Choice.pick(Choice.Fling.Targets, value) end,
    })

    RunSection:Dropdown({
        Title = 'patience',
        Description = 'how long a run keeps at it before giving up, so an unflingable target does not strand you',
        Values = Choice.Fling.Patience.order,
        Default = Choice.Fling.Patience.default,
        Flag = 'mm2_fling_patience',
        Callback = function(value) Fling.Patience = Choice.pick(Choice.Fling.Patience, value) end,
    })

    RunSection:Dropdown({
        Title = 'orbit radius',
        Description = 'orbit method only',
        Values = Choice.Fling.Orbit.order,
        Default = Choice.Fling.Orbit.default,
        Flag = 'mm2_fling_orbit',
        Callback = function(value) Fling.Orbit = Choice.pick(Choice.Fling.Orbit, value) end,
    })

    Fling.ui = addStat(RunSection, { Title = 'runs', Value = '0' })
    Fling.ui2 = addStat(RunSection, { Title = 'flung', Value = '0' })

    local GuardSection = FlingTab:CreateSection('anti fling')

    GuardSection:Toggle({
        Title = 'anti fling',
        Description = 'anyone flinging stops being able to touch you, and anything that still throws you gets you steadied',
        Flag = 'mm2_antifling',
        Default = false,
        Callback = function(state)
            AntiFling.Enabled = state
            AntiFling.safe = nil
            AntiFling.selfStrikes = 0
            if not state then AntiFling.restoreAll() end
        end,
    })

    GuardSection:Dropdown({
        Title = 'method',
        Description = 'smart only ever acts on someone actually flinging. no collide makes everybody pass through you. guard only watches your own body',
        Values = Choice.Fling.AntiMethod.order,
        Default = Choice.Fling.AntiMethod.default,
        Flag = 'mm2_antifling_method',
        Callback = function(value) AntiFling.Method = Choice.pick(Choice.Fling.AntiMethod, value) end,
    })

    GuardSection:Dropdown({
        Title = 'sensitivity',
        Description = 'what counts as flinging and as being thrown. every level leaves walking, jumping, falling and turning alone',
        Values = Choice.Fling.Guard.order,
        Default = Choice.Fling.Guard.default,
        Flag = 'mm2_antifling_guard',
        Callback = function(value) AntiFling.Guard = Choice.pick(Choice.Fling.Guard, value) end,
    })

    GuardSection:Toggle({
        Title = 'say who is flinging',
        Flag = 'mm2_antifling_tell',
        Default = true,
        Callback = function(state) AntiFling.Tell = state end,
    })

    AntiFling.ui = addStat(GuardSection, { Title = 'steadied you', Value = '0' })
    AntiFling.ui2 = addStat(GuardSection, { Title = 'flingers seen', Value = '0' })

    local NotesSection = FlingTab:CreateSection('notes')

    NotesSection:Paragraph({
        Title = 'how a fling works',
        Content = 'every player\'s client simulates their own character and believes the velocity your client reports for yours. a fling is them touching a part of yours that is reported moving absurdly fast. the touch fling makes that report right after your physics step, when it is sent, and takes it back before your next step, so you never feel it. a run goes to the target and keeps reporting it while a zero BodyVelocity holds you still, then brings you back',
    })

    NotesSection:Paragraph({
        Title = 'why anti fling stopped misfiring',
        Content = 'the old one deleted every mover in your character and treated any spin as an attack. the game puts its own movers in there, and turning spins you about the vertical axis, so it kept firing on nothing. nobody else can put anything in your character, so movers are left alone now; only tumbling end over end or being thrown faster than anything normal counts, and smart only steps in when someone flinging is actually near you',
    })

    NotesSection:Paragraph({
        Title = 'what this cannot do',
        Content = 'if the game puts players in a collision group that stops them touching each other, there is no contact and no power helps. other clients see what you report, so a big touch fling can read as jitter on their end; if you are being noticed, drop the power first',
    })
end


local SeenStat, RedirectStat, SuppressStat, ErrorStat
do

do
    local SpamEquip = {
        Enabled = false,
        ItemName = nil,
        UnequipDelay = 0.1,
        EquipDelay = 0.1,
    }

    local function findSpamEquipTool()
        if not SpamEquip.ItemName then return nil, false end
        local char = LocalPlayer.Character
        if char then
            local tool = char:FindFirstChild(SpamEquip.ItemName)
            if tool and tool:IsA("Tool") then return tool, true end
        end
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        if backpack then
            local tool = backpack:FindFirstChild(SpamEquip.ItemName)
            if tool and tool:IsA("Tool") then return tool, false end
        end
        return nil, false
    end

    local ItemsTab = Window:CreateTab({ Title = 'items' })
    local ItemSection = ItemsTab:CreateSection('spam equip')
    local SavedItemStat = addStat(ItemSection, { Title = 'saved item', Value = 'none' })

    ItemSection:Button({
        Title = 'save current item',
        Callback = function()
            local char = LocalPlayer.Character
            local tool = char and char:FindFirstChildOfClass("Tool")
            if not tool then
                local backpack = LocalPlayer:FindFirstChild("Backpack")
                tool = backpack and backpack:FindFirstChildOfClass("Tool")
            end
            if tool then
                SpamEquip.ItemName = tool.Name
                SavedItemStat.Set(tool.Name)
            else
                SavedItemStat.Set('none equipped')
            end
        end,
    })

    local floatingButton, floatingLabel

    local function refreshFloatingButton()
        if not floatingButton then return end
        if SpamEquip.Enabled then
            floatingButton.BackgroundColor3 = Color3.fromRGB(210, 45, 45)
            floatingLabel.Text = 'ON'
        else
            floatingButton.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
            floatingLabel.Text = 'OFF'
        end
    end

    local spamToggleElement
    spamToggleElement = ItemSection:Toggle({
        Title = 'spam equip/unequip',
        Flag = 'mm2_spam_equip',
        Callback = function(state)
            SpamEquip.Enabled = state
            refreshFloatingButton()
        end,
    })

    local function getFloatingGuiParent()
        local target
        local ok = pcall(function()
            if typeof(gethui) == "function" then target = gethui() end
        end)
        if not ok or not target then
            local ok2 = pcall(function()
                local coreGui = game:GetService("CoreGui")
                local probe = Instance.new("ScreenGui")
                probe.Parent = coreGui
                probe:Destroy()
                target = coreGui
            end)
            if not ok2 then target = nil end
        end
        if not target then
            target = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
        end
        return target
    end

    local function destroyFloatingButton()
        if FloatingSpamGui then
            FloatingSpamGui:Destroy()
            FloatingSpamGui = nil
        end
        floatingButton = nil
        floatingLabel = nil
    end

    local function buildFloatingButton()
        destroyFloatingButton()

        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "MM2SpamToggle"
        screenGui.ResetOnSpawn = false
        screenGui.IgnoreGuiInset = true
        screenGui.DisplayOrder = 9999
        screenGui.Parent = getFloatingGuiParent()
        FloatingSpamGui = screenGui

        local button = Instance.new("TextButton")
        button.Name = "SpamToggle"
        button.AutoButtonColor = false
        button.Text = ""
        button.Size = UDim2.fromOffset(46, 46)
        button.Position = UDim2.fromOffset(16, 160)
        button.ZIndex = 50
        button.Parent = screenGui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = button

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Transparency = 0.7
        stroke.Parent = button

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 12
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        label.Text = 'OFF'
        label.ZIndex = 51
        label.Parent = button

        floatingButton = button
        floatingLabel = label
        refreshFloatingButton()

        local moved = false

        button.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
                and input.UserInputType ~= Enum.UserInputType.Touch then return end
            moved = false
            local startInput = input.Position
            local startPos = button.Position
            local conn
            conn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    conn:Disconnect()
                    return
                end
                local delta = input.Position - startInput
                if math.abs(delta.X) + math.abs(delta.Y) > 8 then moved = true end
                button.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end)
        end)

        button.MouseButton1Click:Connect(function()
            if moved then return end
            spamToggleElement:Set(not SpamEquip.Enabled)
        end)
    end

    ItemSection:Toggle({
        Title = 'floating spam button',
        Flag = 'mm2_spam_floating_button',
        Callback = function(state)
            if state then
                buildFloatingButton()
            else
                destroyFloatingButton()
            end
        end,
    })

    ItemSection:Slider({
        Title = 'delay before equip (after unequip)',
        Min = 0,
        Max = 2,
        Increment = 0.05,
        Default = SpamEquip.UnequipDelay,
        Suffix = ' s',
        Flag = 'mm2_spam_equip_unequip_delay',
        Callback = function(value) SpamEquip.UnequipDelay = value end,
    })

    ItemSection:Slider({
        Title = 'delay before unequip (after equip)',
        Min = 0,
        Max = 2,
        Increment = 0.05,
        Default = SpamEquip.EquipDelay,
        Suffix = ' s',
        Flag = 'mm2_spam_equip_equip_delay',
        Callback = function(value) SpamEquip.EquipDelay = value end,
    })

    task.spawn(function()
        while not Unloading do
            if SpamEquip.Enabled and SpamEquip.ItemName then
                local char = LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                local tool, equipped = findSpamEquipTool()
                if hum and tool then
                    if equipped then
                        hum:UnequipTools()
                        task.wait(SpamEquip.UnequipDelay)
                    else
                        hum:EquipTool(tool)
                        task.wait(SpamEquip.EquipDelay)
                    end
                else
                    task.wait(0.2)
                end
            else
                task.wait(0.2)
            end
        end
    end)
end

local DebugTab = Window:CreateTab({ Title = 'proof' })

local ProofSection = DebugTab:CreateSection('counters')

ProofSection:Toggle({
    Title = 'proof mode',
    Flag = 'mm2_debug',
    Default = false,
    Callback = function(state)
        Debug.Enabled = state
        if not state then clearMarkers() end
    end,
})

ProofSection:Toggle({
    Title = 'world markers',
    Flag = 'mm2_debug_markers',
    Default = true,
    Callback = function(state)
        Debug.Markers = state
        if not state then clearMarkers() end
    end,
})

SeenStat = addStat(ProofSection, { Title = 'shots seen', Value = '0' })
RedirectStat = addStat(ProofSection, { Title = 'redirected', Value = '0' })
SuppressStat = addStat(ProofSection, { Title = 'not redirected', Value = '0' })
ErrorStat = addStat(ProofSection, { Title = 'avg prediction error', Value = '-' })

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

local LogSection = DebugTab:CreateSection('shot log')

debugLog = LogSection:Console({ Title = 'shots', Height = 260, MaxLines = 120, Timestamps = true })
debugLog:Log('turn on proof mode, then shoot')

LogSection:Label({
    Title = 'moved is how far the shot was displaced from where you actually clicked, so any non zero value is the redirect working. lead is how far ahead of the target it aimed. the indented line that follows is measured when the shot should have arrived, comparing where it predicted the target would be against where they actually got to.',
})

local VisualTab = Window:CreateTab({ Title = 'visual' })

local EspSection = VisualTab:CreateSection('esp')

EspSection:Toggle({
    Title = 'esp',
    Flag = 'mm2_esp',
    Callback = function(state) Visual.Esp = state end,
})

EspSection:Toggle({
    Title = 'color by role',
    Flag = 'mm2_esp_role_color',
    Callback = function(state) Visual.ColorByRole = state end,
})

EspSection:Toggle({
    Title = 'gun esp',
    Flag = 'mm2_esp_gun',
    Callback = function(state) Visual.GunEsp = state end,
})

local RoleEspSection = VisualTab:CreateSection('role esp')

RoleEspSection:Toggle({
    Title = 'role esp',
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

local XraySection = VisualTab:CreateSection('xray')

XraySection:Toggle({
    Title = 'xray',
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

local TrapSection = VisualTab:CreateSection('traps')

TrapSection:Toggle({
    Title = 'trap esp',
    Flag = 'mm2_trap_esp',
    Callback = function(state)
        TrapEsp.Enabled = state
        trapEspRefreshAll()
    end,
})

TrapSection:Toggle({
    Title = 'dropped gun esp',
    Description = 'finds the GunDrop in the map, not just a loose Gun tool',
    Flag = 'mm2_dropped_gun_esp',
    Callback = function(state)
        DroppedGunEsp.Enabled = state
        droppedGunEspRefreshAll()
    end,
})

local GunSection = VisualTab:CreateSection('gun pickup')

GunSection:Toggle({
    Title = 'auto grab gun',
    Description = 'picks the dropped gun up on its own, but only while you are not already holding one',
    Flag = 'mm2_auto_gun',
    Callback = function(state) AutoGun.Enabled = state end,
})

GunSection:Dropdown({
    Title = 'method',
    Description = 'fire touch fakes the contact where you stand; teleport goes there and comes straight back',
    Values = Choice.Fling.Grab.order,
    Default = Choice.Fling.Grab.default,
    Flag = 'mm2_auto_gun_method',
    Callback = function(value) AutoGun.Method = Choice.pick(Choice.Fling.Grab, value) end,
})

AutoGun.ui = addStat(GunSection, {
    Title = 'firetouchinterest',
    Value = typeof(firetouchinterest) == "function" and 'available' or 'missing',
    Color = typeof(firetouchinterest) == "function"
        and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
})

AutoGun.ui2 = addStat(GunSection, { Title = 'drops tracked', Value = '0' })

GunSection:Label({
    Title = 'Fire touch looks for the part inside the drop that the game is actually listening for contact on, and fakes a touch against it without moving you. Where the executor has no firetouchinterest, use teleport instead.',
})

local SessionSection = VisualTab:CreateSection('session')

SessionSection:Button({
    Title = 'unload',
    Callback = function()
        -- put the character back before anything is disconnected, so unloading
        -- mid fling cannot leave you holding a claim nothing is going to revert
        Fling.Touch = false
        Fling.OnTouch = false
        Fling.Tap = false
        Fling.Loop = false
        AntiFling.Enabled = false
        AutoGun.Enabled = false
        Trigger.Gun = false
        Trigger.Throw = false
        pcall(Fling.reset)
        pcall(AntiFling.restoreAll)

        Unloading = true

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end

        for plr in pairs(espObjects) do destroyEsp(plr) end
        for part in pairs(trapObjects) do destroyTrapEsp(part) end
        for item in pairs(droppedGunObjects) do destroyDroppedGunEsp(item) end
        xrayRestoreAll()
        clearMarkers()

        if FloatingSpamGui then
            FloatingSpamGui:Destroy()
            FloatingSpamGui = nil
        end

        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every hook and loop, restores every part xray touched, clears all esp, then closes the menu. The Shoot/KnifeThrown namecall hook cannot be reversed without rejoining.',
})

end

task.spawn(function()
    while not Unloading do
        task.wait(0.4)
        pcall(function()
            SeenStat.Set(tostring(shotStats.seen))
            RedirectStat.Set(tostring(shotStats.redirected),
                shotStats.redirected > 0 and Color3.fromRGB(126, 217, 87) or nil)
            SuppressStat.Set(tostring(shotStats.suppressed))
            ErrorStat.Set(shotStats.proved > 0
                and ('%.1f studs over %d'):format(shotStats.error / shotStats.proved, shotStats.proved)
                or '-')

            SA.readout()

            if Trigger.ui then
                local acting = Color3.fromRGB(126, 217, 87)
                local gun, knife = Trigger.gun, Trigger.knife
                Trigger.ui.gun.Set(Trigger.Gun and gun.status or 'off',
                    Trigger.Gun and gun.target ~= nil and acting or nil)
                Trigger.ui.knife.Set(Trigger.Throw and knife.status or 'off',
                    Trigger.Throw and knife.target ~= nil and acting or nil)
                Trigger.ui.method.Set(Trigger.gunMethod()
                    .. (Trigger.fallback and Trigger.Method == 'Auto' and ' (activate never fired, switched)' or ''))
                Trigger.ui.fired.Set(('%d / %d'):format(Trigger.shots, Trigger.throws))
            end

            if Fling.ui then
                Fling.ui.Set(tostring(Fling.runs),
                    (Fling.busy or Fling.armed) and Color3.fromRGB(126, 217, 87) or nil)
            end
            if Fling.ui2 then
                Fling.ui2.Set(tostring(Fling.flung),
                    Fling.flung > 0 and Color3.fromRGB(126, 217, 87) or nil)
            end
            if AntiFling.ui then
                AntiFling.ui.Set(tostring(AntiFling.saved),
                    AntiFling.saved > 0 and Color3.fromRGB(255, 196, 87) or nil)
            end
            if AntiFling.ui2 then
                AntiFling.ui2.Set(tostring(AntiFling.caught),
                    AntiFling.caught > 0 and Color3.fromRGB(255, 196, 87) or nil)
            end
            if AutoGun.ui2 then
                local n = 0
                for _ in pairs(AutoGun.drops) do n = n + 1 end
                AutoGun.ui2.Set(tostring(n), n > 0 and Color3.fromRGB(126, 217, 87) or nil)
            end
        end)
    end
end)


--// external access ----------------------------------------------------------
--
-- One table holding the live config, so anything here can be driven from a
-- console without editing the script. These are the same tables the script
-- reads, not copies, so a write takes effect on the next frame exactly as
-- moving the control would: MM2.Aim.Targets = 'Anyone' is the dropdown.
--
-- Visual, Xray, Debug, TrapEsp, DroppedGunEsp are plain globals as well, since
-- they are read rarely enough that a hash lookup costs nothing.
do
    local env = _G
    local ok, shared = pcall(function() return getgenv() end)
    if ok and type(shared) == "table" then env = shared end

    env.MM2 = {
        Aim = Aim,
        SA = SA,
        Trigger = Trigger,
        Fling = Fling,
        AntiFling = AntiFling,
        Visual = Visual,
        Xray = Xray,
        Debug = Debug,

        Choice = Choice,
        Stats = shotStats,

        -- every dropdown value is validated on the way in, so a typo through
        -- here falls back to that option's default rather than wedging the
        -- script on a name nothing handles
        Pick = Choice.pick,
        ValueOf = Choice.valueOf,
    }
end

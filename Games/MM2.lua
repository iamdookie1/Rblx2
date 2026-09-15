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

do
    local InfoTab = Window:CreateTab({ Title = 'info' })

    local InfoSilentAimSection = InfoTab:CreateSection('silent aim')
    InfoSilentAimSection:Paragraph({
        Title = 'silent aim',
        Content = 'gun redirects to whoever the gun targets dropdown allows, knife to whoever the knife one allows. your click, animation and the real origin stay as fired',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'no sliders',
        Content = 'there is not a single number to dial in here any more. every setting is a dropdown, and each option carries a whole set of tuned values behind it - the filter constants, how many times the lead re-solves, how much of your ping counts, how far the search reaches. picking a name picks all of it at once',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'prediction maths',
        Content = 'which solver works out where they will be. off aims where they are right now. linear walks their current speed forward in a straight line. projected does the same but lets their acceleration change the speed along the way. arc bends the path by a smoothed turn rate that fades out over the lead. circle fits an actual circle through the path they just walked and trusts it for the whole lead. adaptive is the default and picks between the other four per person, per second',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'how adaptive decides',
        Content = 'every target carries a short buffer of their own past motion. about a dozen times a second it takes a snapshot from roughly a fifth of a second ago, replays all four solvers forward from exactly what was known back then, and measures each one against where that person actually got to. the running average of those errors is the score, and the lowest score wins. it is measured against real movement, not guessed, and a challenger only takes over once it is clearly ahead so the pick does not flicker',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'motion filter',
        Content = 'how hard the raw velocity, turn and acceleration readings are filtered before any solver sees them, and how many times the distance dependent part of the lead re-solves against where that lead itself would put them. raw reacts instantly and jitters, locked settles on a very steady number and is slow to notice a sudden turn, balanced sits in the middle. this shapes the reading only - nothing here is fitted from your shots',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'aim part',
        Content = 'the gun one shots anywhere on the body, so body is not a compromise - it is the same kill with a wider target. the server checks the shot by casting from your gun to the point sent, so how far the prediction can be off before missing is just the width of what you aimed at: about a stud either side of the torso against about half that on the head. auto takes the head only when the shot is easy anyway - close, not sprinting, not mid jump - and drops to body the moment any of that stops being true',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'wall check',
        Content = 'strict needs a clear line from the real muzzle to both where they are and the point the lead solved for. loose only asks that they are not behind a wall right now, which redirects more often at the cost of the occasional shot into cover. off never raycasts at all',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'gun targets / knife targets',
        Content = 'who each weapon is allowed to redirect onto. the gun defaults to the murderer alone, the knife to anyone. murderer + armed also lets the gun take a hero or sheriff holding one, and everyone but the murderer keeps the knife off them if you are not the one holding it',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'priority',
        Content = 'how the allowed targets get ranked once more than one qualifies. crosshair takes whoever is nearest to where you are pointing, closest takes whoever is nearest to you in the world, weakest takes the lowest health, armed first puts anyone holding a weapon ahead of everyone else and falls back to the crosshair between them',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'range',
        Content = 'how far the search reaches. no limit turns the cap off entirely and lets anything loaded be a target',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'fov',
        Content = 'off means the whole screen is fair game - anything visible can be targeted. any other option restricts it to that radius in pixels around the anchor below',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'fov anchor',
        Content = 'whether that radius is measured from your mouse or from the middle of the screen',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'search',
        Content = 'anywhere also allows targets that are off screen entirely, including behind you, ranked by angle from where the camera points. on screen targets always take priority either way',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'air handling',
        Content = 'the vertical aim point is always solved the same safe way - it never overshoots above where they are now by more than a couple of studs, and it never undershoots the ground. this only changes where on their body it aims while they are in the air. safe aims near their feet and also drops a head pick to the torso for repeat jumpers, feet does the first without the second, normal keeps aiming at the usual point mid jump, and off stops solving the jump arc at all',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'ping',
        Content = 'how much of your measured round trip counts toward the lead. ignore contributes nothing, so the lead is only replication lag, your own frame time and the lead profile. full + margin overshoots it slightly for a connection that spikes',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'shots redirected',
        Content = 'how many of your shots get redirected at all. the rest fire exactly where you aimed, untouched',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'gun lead / knife lead',
        Content = 'a flat amount added on top of ping, replication lag, frame time and, for the knife, its real flight time. lead options aim further ahead of the target, back options aim behind them - use those if shots keep landing in front, since they walk the point back toward where the target already was',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'auto lead',
        Content = 'the auto option on either lead dropdown tries a slightly shorter or longer lead than usual on a random shot now and then and nudges a multiplier toward whichever length is actually landing more - measured from the target really taking damage, not from any raycast guess. bounded between 0.4x and 4x so a bad run drifts back rather than running away, and it only ever moves after a real block of shots has resolved',
    })

    local InfoProofSection = InfoTab:CreateSection('proof')
    InfoProofSection:Paragraph({
        Title = 'proof mode',
        Content = 'counts and logs every shot the hook sees. if shots seen stays on zero the hook is not firing at all, if seen climbs while redirected stays on zero it is finding no target, and if redirected climbs it is redirecting - the log then shows by how far',
    })
    InfoProofSection:Paragraph({
        Title = 'world markers',
        Content = 'red ball where the shot was actually sent, green ball where the target really was when it should have arrived. if the two sit on top of each other the prediction was right. both are set to be ignored by raycasts so they cannot affect your own aim or the hit check',
    })

    local InfoVisualSection = InfoTab:CreateSection('visual')
    InfoVisualSection:Paragraph({
        Title = 'esp',
        Content = 'highlights every other living player',
    })
    InfoVisualSection:Paragraph({
        Title = 'color by role',
        Content = 'colors the highlight by current role instead of a flat white',
    })
    InfoVisualSection:Paragraph({
        Title = 'gun esp',
        Content = 'highlights anyone actually holding a gun right now, in a color of its own that role esp never uses. checked directly off the weapon they are holding rather than guessed from round data, so it still catches a hero even when role detection gets that wrong. works even with esp and role esp both off',
    })
    InfoVisualSection:Paragraph({
        Title = 'role esp',
        Content = 'shows role above the head while alive and in the round, never on you. a dropped gun being picked up reads as hero the moment it is equipped',
    })
    InfoVisualSection:Paragraph({
        Title = 'xray',
        Content = 'fades opaque parts in range, leaves anything already see-through alone',
    })
    InfoVisualSection:Paragraph({
        Title = 'trap esp',
        Content = 'a placed trap is invisible until it catches someone, so this looks for it directly instead of waiting for that. matches the part the trap actually uses for its position and the marker object it carries naming who placed it, then puts a highlight and a solid marker ball on it - the marker so it still shows even if the trap part itself has no visible shape of its own',
    })
    InfoVisualSection:Paragraph({
        Title = 'dropped gun esp',
        Content = 'when a sheriff or hero dies holding the gun, it lands somewhere in the world rather than vanishing. this looks for exactly the same tool the gun is identified by everywhere else in this script - by name, its own marker child, or its tag - lying anywhere that is not inside a character, and puts a highlight and a marker ball on it. stops tracking it the moment someone actually picks it back up',
    })

    local InfoItemsSection = InfoTab:CreateSection('items')
    InfoItemsSection:Paragraph({
        Title = 'spam equip/unequip',
        Content = 'repeatedly equips then unequips the saved item using the delays below. re-finds the item by name in your character and backpack each cycle, so it keeps working even if the item leaves your inventory and comes back',
    })
    InfoItemsSection:Paragraph({
        Title = 'floating spam button',
        Content = 'a small button on screen, separate from this menu, that starts and stops spam equip - drag it anywhere, click it to toggle. stays in sync with the spam equip/unequip toggle above either way',
    })

end

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

-- there is not a slider left in this tab. every control is a dropdown, and an
-- option is a name standing in for the whole set of numbers behind it, so
-- picking one picks the filtering, the passes, the reach and the lead together
local Choice = {
    Part   = { default = 'Auto',   order = { 'Auto', 'Body', 'Head' } },
    Wall   = { default = 'Strict', order = { 'Strict', 'Loose', 'Off' } },
    Math   = { default = 'Adaptive', order = { 'Adaptive', 'Circle', 'Arc', 'Projected', 'Linear', 'Off' } },
    Air    = { default = 'Safe',   order = { 'Safe', 'Feet', 'Normal', 'Off' } },
    Anchor = { default = 'Mouse',  order = { 'Mouse', 'Screen centre' } },
    Search = { default = 'On screen', order = { 'On screen', 'Anywhere' } },

    Priority     = { default = 'Crosshair',     order = { 'Crosshair', 'Closest', 'Weakest', 'Armed first' } },
    GunTargets   = { default = 'Murderer only', order = { 'Murderer only', 'Murderer + armed', 'Anyone' } },
    KnifeTargets = { default = 'Anyone',        order = { 'Anyone', 'Armed only', 'Everyone but the murderer' } },

    Range = {
        default = 'Long',
        order = { 'Close', 'Medium', 'Long', 'Max', 'No limit' },
        value = {
            ['Close']    = 100,
            ['Medium']   = 175,
            ['Long']     = 250,
            ['Max']      = 300,
            ['No limit'] = math.huge,
        },
    },

    Fov = {
        default = 'Off',
        order = { 'Off', 'Tight', 'Normal', 'Wide', 'Huge' },
        value = {
            ['Off']    = math.huge,
            ['Tight']  = 90,
            ['Normal'] = 200,
            ['Wide']   = 350,
            ['Huge']   = 500,
        },
    },

    Ping = {
        default = 'Full',
        order = { 'Ignore', 'Half', 'Full', 'Full + margin' },
        value = {
            ['Ignore']        = 0,
            ['Half']          = 0.5,
            ['Full']          = 1,
            ['Full + margin'] = 1.25,
        },
    },

    Shots = {
        default = 'Every shot',
        order = { 'Every shot', 'Most (75%)', 'Half', 'Some (25%)' },
        value = {
            ['Every shot'] = 100,
            ['Most (75%)'] = 75,
            ['Half']       = 50,
            ['Some (25%)'] = 25,
        },
    },

    -- smooth is the share of the raw reading folded in on each sample, so a
    -- high number reacts at once and a low one settles slowly. passes is how
    -- many times the distance dependent lead re-solves against its own answer
    Filter = {
        default = 'Balanced',
        order = { 'Raw', 'Light', 'Balanced', 'Heavy', 'Locked' },
        value = {
            ['Raw']      = { smooth = 0.95, vertical = 0.90, turn = 0.60, accel = 0.70, passes = 1, trust = 0.45 },
            ['Light']    = { smooth = 0.70, vertical = 0.80, turn = 0.50, accel = 0.55, passes = 2, trust = 0.55 },
            ['Balanced'] = { smooth = 0.50, vertical = 0.65, turn = 0.35, accel = 0.40, passes = 2, trust = 0.70 },
            ['Heavy']    = { smooth = 0.32, vertical = 0.50, turn = 0.25, accel = 0.30, passes = 3, trust = 0.80 },
            ['Locked']   = { smooth = 0.18, vertical = 0.40, turn = 0.15, accel = 0.20, passes = 3, trust = 0.90 },
        },
    },

    Lead = {
        default = 'Auto',
        order = { 'Auto', 'Pull back', 'Slight back', 'Neutral', 'Slight lead', 'More lead', 'Heavy lead' },
        value = {
            ['Auto']        = { extra = 0,   auto = true  },
            ['Pull back']   = { extra = -60, auto = false },
            ['Slight back'] = { extra = -25, auto = false },
            ['Neutral']     = { extra = 0,   auto = false },
            ['Slight lead'] = { extra = 25,  auto = false },
            ['More lead']   = { extra = 60,  auto = false },
            ['Heavy lead']  = { extra = 120, auto = false },
        },
    },
}

-- a config saved by an older build holds a number or a boolean where one of
-- these names now belongs, so anything not on the list falls back to the default
function Choice.pick(set, value)
    for _, name in ipairs(set.order) do
        if name == value then return name end
    end
    return set.default
end

function Choice.valueOf(set, value)
    return set.value[Choice.pick(set, value)]
end

local Aim = {
    Enabled = false,

    GunTargets = Choice.GunTargets.default,
    KnifeTargets = Choice.KnifeTargets.default,
    Priority = Choice.Priority.default,
    AimPart = Choice.Part.default,

    WallCheck = Choice.Wall.default,
    MaxRange = Choice.valueOf(Choice.Range),
    FOVRadius = Choice.valueOf(Choice.Fov),
    FOVAnchor = Choice.Anchor.default,
    OffScreen = false,

    Math = Choice.Math.default,
    Filter = Choice.Filter.default,
    Air = Choice.Air.default,
    PingScale = Choice.valueOf(Choice.Ping),
    ShotChance = Choice.valueOf(Choice.Shots),
}

local GunTune = { Extra = 0, Auto = Choice.Lead.value[Choice.Lead.default].auto }
local KnifeTune = { Extra = 0, Speed = 96, Auto = Choice.Lead.value[Choice.Lead.default].auto }

local Debug = {
    Enabled = false,
    Markers = true,
}

local Adapt = {
    Models = { 'Circle', 'Arc', 'Projected', 'Linear' },
    MinAge = 0.1,    -- youngest snapshot worth replaying against
    MaxAge = 0.5,    -- older than this and the replay says nothing useful
    Target = 0.2,    -- and the age it aims for, near a real shot's lead
    Rate = 0.08,     -- seconds between scoring rounds
    Blend = 0.25,    -- how fast a round moves a model's running error
    Samples = 6,     -- rounds before the pick is trusted over the default
    Margin = 0.12,   -- share of the held error a challenger must beat it by
    Floor = 0.01,    -- and a studs floor, so near-identical models do not swap
    Fit = 14,        -- newest samples the circle is fitted through
    HeadRange = 60,  -- past this, auto aim part drops the head
    HeadSpeed = 10,  -- and past this speed too
}

local cachedPing = 0.08
local cachedFrame = 1 / 60
local lastTick = 0

local shotStats = { seen = 0, redirected = 0, suppressed = 0, proved = 0, error = 0 }
local shotEvents = {}
local lastModelUsed = '-'

local MAX_TRAVEL_TIME = 5
local MAX_LEAD_OFFSET = 50
local MAX_VERTICAL_RISE = 2
local MAX_VERTICAL_DROP = 12
local MAX_PENDING = 24
local JUMP_SPAM_WINDOW = 3
local JUMP_SPAM_COUNT = 3
local SAMPLE_STALE = 0.5
local HISTORY_LIMIT = 40
local HISTORY_WINDOW = 0.9
local MIN_TURN_RATE = 0.05
local MAX_TURN_RATE = 4
local MIN_TURN_RADIUS = 2.5
local MAX_TURN_RADIUS = 400
local TURN_DECAY = 0.45
local MAX_TANGENTIAL = 120
local SPEED_CEILING = 1.6
local ARC_STEPS = 6
local PLAN_STALE = 0.25
local TRANSPARENT_SKIPS = 8
local HIT_WINDOW = 0.35
local MAX_CANDIDATES = 5
local PART_ORDER_HEAD = { "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso" }
local PART_ORDER_BODY = { "HumanoidRootPart", "UpperTorso", "Torso", "LowerTorso", "Head" }

local function filterSettings()
    return Choice.valueOf(Choice.Filter, Aim.Filter)
end

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
    if Aim.WallCheck == 'Off' then return true end
    local direction = target - origin
    local result = weaponCast(origin, direction, { char })
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

local function screenAnchor()
    if Aim.FOVAnchor == 'Mouse' then
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

local function flatDistance(a, b)
    return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function perpOf(forward)
    return Vector3.new(-forward.Z, 0, forward.X)
end

local function dotOf(a, b)
    return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

-- a circle through three points of the path just walked. when the fit survives
-- every sanity check the turn it implies is real rather than a smoothing
-- artefact. only the newest slice is used, so the longer buffer the backtest
-- needs does not quietly stretch the baseline this is measured over
local function fitTurnRate(history, speed)
    local count = history and #history or 0
    if count < 5 then return nil end

    local from = math.max(1, count - Adapt.Fit + 1)
    local first = history[from]
    local middle = history[from + math.floor((count - from) / 2)]
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

-- the maths dropdown, one function per mode. state is any table carrying the
-- motion fields, so a live target and a stored snapshot of one go through
-- exactly the same solver - which is what makes the replay below honest
local function modelStep(mode, state, t)
    if t <= 0 or mode == 'Off' then return Vector3.zero end

    local velocity = state.horizontal
    if not velocity then return Vector3.zero end

    local speed = velocity.Magnitude
    if speed < 0.5 then return Vector3.zero end

    local ceiling = (state.walkSpeed or 16) * SPEED_CEILING
    if speed > ceiling then speed = ceiling end

    local forward = velocity.Unit

    if mode == 'Linear' then
        return forward * (speed * t)
    end

    local tangential = math.clamp(dotOf(state.accel or Vector3.zero, forward), -MAX_TANGENTIAL, MAX_TANGENTIAL)

    if mode == 'Projected' then
        local travelled = 0
        local straight = t / ARC_STEPS
        for index = 1, ARC_STEPS do
            local mid = (index - 0.5) * straight
            travelled = travelled + math.clamp(speed + tangential * mid, 0, ceiling) * straight
        end
        return forward * travelled
    end

    -- circle rides the fitted turn for the whole lead, arc rides a smoothed
    -- turn that fades out across it. circle with no usable fit is arc
    local fitted = mode == 'Circle' and state.fit or nil
    local steady = math.clamp(state.steady or 1, 0, 1)
    local omega = math.clamp(fitted or state.turnRate or 0, -MAX_TURN_RATE, MAX_TURN_RATE) * steady

    local trust = filterSettings().trust
    local horizon = t * (trust + (1 - trust) * steady)
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

-- what makes adaptive more than a guess: replay every model forward from a
-- snapshot of what was known a fraction of a second ago, and measure each one
-- against where that person actually ended up. lowest running error wins
local function backtest(entry, actual, now)
    if now - entry.backtestAt < Adapt.Rate then return end

    local history = entry.history
    local count = #history
    if count < 5 then return end

    -- the snapshot nearest the age a real shot's lead covers, so the models are
    -- scored over the horizon they will actually be asked to solve. history runs
    -- oldest first, so ages only fall as the index climbs
    local snap, bestGap = nil, math.huge
    for index = 1, count do
        local age = now - history[index].t
        if age < Adapt.MinAge then break end
        if age <= Adapt.MaxAge then
            local gap = math.abs(age - Adapt.Target)
            if gap < bestGap then snap, bestGap = history[index], gap end
        end
    end
    if not snap then return end

    entry.backtestAt = now
    local dt = now - snap.t

    for _, name in ipairs(Adapt.Models) do
        local missed = flatDistance(snap.p + modelStep(name, snap, dt), actual)
        local previous = entry.scores[name]
        entry.scores[name] = previous and (previous + (missed - previous) * Adapt.Blend) or missed
    end

    entry.scored = entry.scored + 1
    if entry.scored < Adapt.Samples then return end

    local best, bestError = nil, math.huge
    for _, name in ipairs(Adapt.Models) do
        local score = entry.scores[name]
        if score and score < bestError then
            best, bestError = name, score
        end
    end

    -- only hand over when the challenger is clearly ahead, so the pick does not
    -- flicker between two models sitting within noise of each other. the margin
    -- is a share of the error being beaten rather than a flat number of studs,
    -- because over a short lead every model is wrong by well under a stud and a
    -- flat margin would swallow the whole spread between them
    if best and best ~= entry.best then
        local held = entry.scores[entry.best]
        if held == nil or bestError + Adapt.Floor < held * (1 - Adapt.Margin) then
            entry.best = best
        end
    end
end

local function chooseModel(entry)
    local mode = Aim.Math
    if mode ~= 'Adaptive' then return mode end
    if not entry or entry.scored < Adapt.Samples then return 'Arc' end
    return entry.best or 'Arc'
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
            fit = nil,
            walkSpeed = 16,
            speedCheck = 0,
            repLag = 0,
            lastMove = now,
            history = {},
            scores = {},
            scored = 0,
            best = 'Arc',
            backtestAt = 0,
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
        local settings = filterSettings()
        local delta = position - entry.position
        local rawHorizontal = Vector3.new(delta.X, 0, delta.Z) / dt
        local rawVertical = delta.Y / dt
        local previous = entry.horizontal

        entry.horizontal = previous:Lerp(rawHorizontal, settings.smooth)
        entry.vertical = entry.vertical + (rawVertical - entry.vertical) * settings.vertical

        local accel = (entry.horizontal - previous) / dt
        entry.accel = entry.accel:Lerp(accel, settings.accel)

        if previous.Magnitude > 1 and entry.horizontal.Magnitude > 1 then
            local a, b = previous.Unit, entry.horizontal.Unit
            local dot = math.clamp(a:Dot(b), -1, 1)
            local cross = a.X * b.Z - a.Z * b.X
            local turn = math.atan2(cross, dot) / dt
            entry.turnRate = entry.turnRate + (turn - entry.turnRate) * settings.turn
            entry.steady = entry.steady + (math.max(dot, 0) - entry.steady) * 0.3
        else
            entry.turnRate = entry.turnRate * 0.8
            entry.steady = entry.steady + (1 - entry.steady) * 0.1
        end

        local snapshot = {
            p = position,
            t = now,
            horizontal = entry.horizontal,
            accel = entry.accel,
            turnRate = entry.turnRate,
            steady = entry.steady,
            walkSpeed = entry.walkSpeed,
        }
        table.insert(entry.history, snapshot)
        while #entry.history > HISTORY_LIMIT or (entry.history[1] and now - entry.history[1].t > HISTORY_WINDOW) do
            table.remove(entry.history, 1)
        end

        -- fitted once per sample rather than once per solve pass, so every lead
        -- pass and every replay of this moment reads the same circle
        entry.fit = fitTurnRate(entry.history, entry.horizontal.Magnitude)
        snapshot.fit = entry.fit

        backtest(entry, position, now)
    elseif dt >= SAMPLE_STALE then
        entry.horizontal = Vector3.zero
        entry.accel = Vector3.zero
        entry.turnRate = 0
        entry.vertical = 0
        entry.steady = 1
        entry.fit = nil
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

local function predictRoot(entry, base, sinceSample, travelTime, mode)
    if mode == 'Off' or travelTime == 0 then
        return base
    end

    local horizontal = modelStep(mode, entry, travelTime)
    if horizontal.Magnitude > MAX_LEAD_OFFSET then
        horizontal = horizontal.Unit * MAX_LEAD_OFFSET
    end

    local y = base.Y
    if entry.airborne and Aim.Air ~= 'Off' then
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

local newLeadState, pickArm, armMultiplier, updateBandit
do
    local DITHER = 0.35
    local MIN_ARM_SAMPLES = 4
    local MULT_MIN = 0.4
    local MULT_MAX = 4
    local ARM_MARGIN = 0.12
    local SWEEP_STEP = 1.5
    local EXPLORE_CHANCE_BASE = 0.2
    local EXPLORE_CHANCE_MIN = 0.06
    local EXPLORE_DECAY = 0.75

    function newLeadState(tune)
        return {
            tune = tune,
            mult = 1,
            exploreChance = EXPLORE_CHANCE_BASE,
            arms = { { hit = 0, shot = 0 }, { hit = 0, shot = 0 }, { hit = 0, shot = 0 } },
            pending = {},
            verified = 0,
            hits = 0,
        }
    end

    function pickArm(state)
        if not state.tune.Auto then return nil end
        if math.random() >= state.exploreChance then return 2 end
        return math.random() < 0.5 and 1 or 3
    end

    function armMultiplier(state, arm)
        if not state.tune.Auto or arm == nil then return 1 end
        if arm == 1 then return state.mult * (1 - DITHER) end
        if arm == 3 then return state.mult * (1 + DITHER) end
        return state.mult
    end

    function updateBandit(state)
        local arms = state.arms
        if arms[1].shot < MIN_ARM_SAMPLES or arms[3].shot < MIN_ARM_SAMPLES then return end

        local landed = arms[1].hit + arms[2].hit + arms[3].hit
        local moved = false

        if landed == 0 then
            state.mult = state.mult * SWEEP_STEP
            if state.mult > MULT_MAX then state.mult = MULT_MIN end
            moved = true
        else
            local centre = arms[2].shot > 0 and (arms[2].hit / arms[2].shot) or -1
            local low = arms[1].hit / arms[1].shot
            local high = arms[3].hit / arms[3].shot

            if low > centre + ARM_MARGIN and low >= high then
                state.mult = state.mult * (1 - DITHER * 0.5)
                moved = true
            elseif high > centre + ARM_MARGIN and high > low then
                state.mult = state.mult * (1 + DITHER * 0.5)
                moved = true
            end
            state.mult = math.clamp(state.mult, MULT_MIN, MULT_MAX)
        end

        state.exploreChance = moved and EXPLORE_CHANCE_BASE
            or math.max(EXPLORE_CHANCE_MIN, state.exploreChance * EXPLORE_DECAY)

        for index = 1, 3 do
            arms[index].hit = 0
            arms[index].shot = 0
        end
    end
end

local GunLead = newLeadState(GunTune)
local KnifeLead = newLeadState(KnifeTune)

local function travelTimeFor(state, entry, distance, arm)
    local tune = state.tune
    local total = cachedPing * Aim.PingScale

    total = total + (entry ~= nil and entry.repLag or 0) * 0.5
    total = total + cachedFrame

    if tune.Speed ~= nil and tune.Speed > 0 then
        total = total + distance / tune.Speed
    end

    total = total + tune.Extra / 1000
    total = total * armMultiplier(state, arm)

    return math.clamp(total, -MAX_TRAVEL_TIME, MAX_TRAVEL_TIME)
end

local function scoreShot(state, hit)
    state.verified = state.verified + 1
    if hit then state.hits = state.hits + 1 end
end

local function verifyLead(state, now)
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
            if state.tune.Auto then
                local arm = state.arms[record.arm or 2]
                arm.shot = arm.shot + 1
                if hit then arm.hit = arm.hit + 1 end
                updateBandit(state)
            end
            table.remove(pending, index)
        else
            index = index + 1
        end
    end
end

local function logLead(state, char, distance, used, arm, now)
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
        arm = arm,
    })
end

-- head is worth its smaller hitbox only when the shot is easy anyway: close,
-- not sprinting, not mid jump. anything else takes the far wider torso
local function autoAimPart(char, entry)
    if Aim.Air ~= 'Off' and entry and (entry.airborne or isSpamJumper(entry)) then return 'Body' end
    if entry and entry.horizontal.Magnitude > Adapt.HeadSpeed then return 'Body' end

    local root = char:FindFirstChild("HumanoidRootPart")
    if root and (root.Position - Camera.CFrame.Position).Magnitude > Adapt.HeadRange then return 'Body' end

    return 'Head'
end

local function aimPartsFor(char, entry)
    local choice = Aim.AimPart
    if choice == 'Auto' then choice = autoAimPart(char, entry) end

    local order = PART_ORDER_BODY
    if choice == 'Head' and not (Aim.Air == 'Safe' and entry and isSpamJumper(entry)) then
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
    if screenDist > Aim.FOVRadius then return nil end
    return screenDist
end

local function isMurderer(plr)
    local role, dead = roleOf(plr)
    return role == "Murderer" and not dead
end

local function allowedTarget(plr, isKnife)
    if isKnife then
        local mode = Aim.KnifeTargets
        if mode == 'Armed only' then return heldWeapon(plr.Character) ~= nil end
        if mode == 'Everyone but the murderer' then return not isMurderer(plr) end
        return true
    end

    local mode = Aim.GunTargets
    if mode == 'Anyone' then return true end
    if mode == 'Murderer + armed' then return isMurderer(plr) or heldWeapon(plr.Character) ~= nil end
    return isMurderer(plr)
end

-- crosshair ranks by pixels from where you point, the rest re-rank the same set
local function priorityScore(candidate, char)
    local mode = Aim.Priority
    if mode == 'Crosshair' then return candidate.screenDist end
    if mode == 'Closest' then return candidate.worldDist end

    if mode == 'Weakest' then
        local hum = char:FindFirstChildOfClass("Humanoid")
        local ok, health = pcall(function() return hum and hum.Health end)
        return (ok and health) or math.huge
    end

    return (heldWeapon(char) ~= nil and 0 or 1e6) + candidate.screenDist
end

local function scanTargets(isKnife)
    local origin = Camera.CFrame.Position
    local anchor = screenAnchor()

    local candidates = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) and allowedTarget(plr, isKnife) then
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
                    local root = char:FindFirstChild("HumanoidRootPart")
                    local candidate = {
                        plr = plr,
                        char = char,
                        parts = parts,
                        screenDist = best,
                        worldDist = root and (root.Position - origin).Magnitude or math.huge,
                    }
                    candidate.score = priorityScore(candidate, char)
                    candidates[#candidates + 1] = candidate
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.score < b.score end)
    return candidates
end

local knifeSpeedStat = nil

local function onThrowingKnifeAdded(instance)
    local ok, speed = pcall(function() return instance:GetAttribute("ThrowSpeed") end)
    if ok and typeof(speed) == "number" and speed > 1 and speed ~= KnifeTune.Speed then
        KnifeTune.Speed = speed
        if knifeSpeedStat then
            pcall(function() knifeSpeedStat.Set(('%d studs/s'):format(speed)) end)
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

local function solveAim(plan, origin, now)
    local entry = plan.entry
    local rootPos = plan.root.Position
    local partPos = plan.part.Position
    local sinceSample = now - entry.time
    if sinceSample < 0 then sinceSample = 0 end
    if sinceSample > SAMPLE_STALE then sinceSample = SAMPLE_STALE end

    local offset = partPos - rootPos
    if entry.airborne and (Aim.Air == 'Feet' or Aim.Air == 'Safe') then
        offset = Vector3.new(offset.X, -plan.hipOffset, offset.Z)
    end

    local mode = chooseModel(entry)
    if mode == 'Off' then
        return rootPos + offset, rootPos, 0, (partPos - origin).Magnitude, rootPos, mode
    end

    local state = plan.state
    local arm = plan.arm
    local passes = filterSettings().passes

    local distance = (partPos - origin).Magnitude
    local travelTime = travelTimeFor(state, entry, distance, arm)
    local predicted = predictRoot(entry, rootPos, sinceSample, travelTime, mode)
    for _ = 2, passes do
        distance = ((predicted + offset) - origin).Magnitude
        travelTime = travelTimeFor(state, entry, distance, arm)
        predicted = predictRoot(entry, rootPos, sinceSample, travelTime, mode)
    end

    return predicted + offset, rootPos, travelTime, distance, predicted, mode
end

local function noteShot(plan, reason, origin, sent, aimed, predictedRoot, travel, model)
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
        model = model,
        part = plan ~= nil and plan.part ~= nil and plan.part.Name or nil,
    }
end

local function resolveRedirect(plan, originCFrame, sentCFrame)
    shotStats.seen = shotStats.seen + 1

    local origin = originCFrame.Position
    local sent = typeof(sentCFrame) == "CFrame" and sentCFrame.Position or nil

    if not plan then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(nil, "no target", origin, sent, nil, nil, nil, nil)
        return nil
    end

    if os.clock() - plan.stamp > PLAN_STALE then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "plan stale", origin, sent, nil, nil, nil, nil)
        return nil
    end

    if Aim.ShotChance < 100 and math.random() * 100 >= Aim.ShotChance then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "chance roll", origin, sent, nil, nil, nil, nil)
        return nil
    end

    local aim, predictedRoot, travel, model
    local ok, solved, _, solvedTravel, _, solvedRoot, solvedModel = pcall(solveAim, plan, origin, os.clock())
    if ok and typeof(solved) == "Vector3" then
        aim, predictedRoot, travel, model = solved, solvedRoot, solvedTravel, solvedModel
    elseif plan.fallback then
        aim, model = plan.fallback.Position, plan.model
    else
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "solve failed", origin, sent, nil, nil, nil, nil)
        return nil
    end

    lastModelUsed = model or '-'
    shotStats.redirected = shotStats.redirected + 1
    noteShot(plan, "redirected", origin, sent, aim, predictedRoot, travel, model)
    return CFrame.new(aim)
end

local function buildPlan(isKnife, origin, now)
    if not origin then return nil end

    local candidates = scanTargets(isKnife)
    if #candidates == 0 then return nil end

    for rank, candidate in ipairs(candidates) do
        if rank > MAX_CANDIDATES then break end

        local plr = candidate.plr
        local char = candidate.char
        local root = char:FindFirstChild("HumanoidRootPart")
        local entry = motion[plr.Name]

        if root and entry then
            local state = isKnife and KnifeLead or GunLead
            local plan = {
                entry = entry,
                root = root,
                char = char,
                hipOffset = feetOffset(char),
                state = state,
                isKnife = isKnife,
                arm = pickArm(state),
                stamp = now,
            }

            for _, part in ipairs(candidate.parts) do
                plan.part = part

                if clearPath(origin, part.Position, char) then
                    local aim, _, travelTime, distance, _, model = solveAim(plan, origin, now)

                    -- strict also demands the solved point be reachable, loose
                    -- only asks that the target is not behind a wall right now
                    if Aim.WallCheck ~= 'Strict' or clearPath(origin, aim, char) then
                        plan.fallback = CFrame.new(aim)
                        plan.model = model

                        if distance then
                            logLead(plan.state, char, distance, travelTime, plan.arm, now)
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
                debugLog:Log(("%s -> %s %s | moved %s | lead %s | travel %s | maths %s"):format(
                    tag,
                    event.target or "?",
                    event.part or "?",
                    moved and ("%.1f studs"):format(moved) or "n/a",
                    lead and ("%.1f studs"):format(lead) or "n/a",
                    event.travel and ("%.3fs"):format(event.travel) or "n/a",
                    event.model or "n/a"))
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

track(PreSimulation:Connect(function()
    if Unloading or not Aim.Enabled then
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

        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then sampleMotion(plr, root, now) end
            end
        end

        verifyLead(GunLead, now)
        verifyLead(KnifeLead, now)

        gunPlan = buildPlan(false, findGunOrigin(), now)
        knifePlan = buildPlan(true, findKnifeOrigin(), now)

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
        if Unloading or not Aim.Enabled or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
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

local SilentAimTab = Window:CreateTab({ Title = 'silent aim' })

local solverStat

do
    local AimSection = SilentAimTab:CreateSection('aim')

    addStat(AimSection, {
        Title = 'hook api',
        Value = hasNamecallHook and 'available' or 'missing',
        Color = hasNamecallHook and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
    })

    AimSection:Toggle({
        Title = 'silent aim',
        Description = 'redirects the shot itself - your click, animation and origin stay as fired',
        Flag = 'mm2_silent_aim',
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

    AimSection:Dropdown({
        Title = 'aim part',
        Description = 'auto takes the head only on a shot that is easy anyway, body the rest of the time',
        Values = Choice.Part.order,
        Default = Choice.Part.default,
        Flag = 'mm2_silent_aim_part',
        Callback = function(value) Aim.AimPart = Choice.pick(Choice.Part, value) end,
    })

    AimSection:Dropdown({
        Title = 'wall check',
        Description = 'strict needs a clear line to the solved point too, loose only to the target',
        Values = Choice.Wall.order,
        Default = Choice.Wall.default,
        Flag = 'mm2_silent_aim_wallcheck',
        Callback = function(value) Aim.WallCheck = Choice.pick(Choice.Wall, value) end,
    })

    AimSection:Dropdown({
        Title = 'range',
        Description = 'how far the search reaches',
        Values = Choice.Range.order,
        Default = Choice.Range.default,
        Flag = 'mm2_silent_aim_range',
        Callback = function(value) Aim.MaxRange = Choice.valueOf(Choice.Range, value) end,
    })

    AimSection:Dropdown({
        Title = 'shots redirected',
        Description = 'the rest fire exactly where you aimed, untouched',
        Values = Choice.Shots.order,
        Default = Choice.Shots.default,
        Flag = 'mm2_silent_aim_shots',
        Callback = function(value) Aim.ShotChance = Choice.valueOf(Choice.Shots, value) end,
    })
end

do
    local MathSection = SilentAimTab:CreateSection('maths')

    MathSection:Dropdown({
        Title = 'prediction maths',
        Description = 'which solver works out where they will be when the shot lands',
        Values = Choice.Math.order,
        Default = Choice.Math.default,
        Flag = 'mm2_silent_aim_math',
        Callback = function(value) Aim.Math = Choice.pick(Choice.Math, value) end,
    })

    MathSection:Dropdown({
        Title = 'motion filter',
        Description = 'how hard the raw motion reading is filtered, and how many lead passes run',
        Values = Choice.Filter.order,
        Default = Choice.Filter.default,
        Flag = 'mm2_silent_aim_filter',
        Callback = function(value) Aim.Filter = Choice.pick(Choice.Filter, value) end,
    })

    MathSection:Dropdown({
        Title = 'air handling',
        Description = 'where on them it aims while they are mid jump',
        Values = Choice.Air.order,
        Default = Choice.Air.default,
        Flag = 'mm2_silent_aim_air',
        Callback = function(value) Aim.Air = Choice.pick(Choice.Air, value) end,
    })

    MathSection:Dropdown({
        Title = 'ping',
        Description = 'how much of your measured round trip counts toward the lead',
        Values = Choice.Ping.order,
        Default = Choice.Ping.default,
        Flag = 'mm2_silent_aim_ping',
        Callback = function(value) Aim.PingScale = Choice.valueOf(Choice.Ping, value) end,
    })

    solverStat = addStat(MathSection, { Title = 'solver in use', Value = '-' })

    MathSection:Label({
        Title = 'Adaptive replays all four solvers against motion that has already happened and keeps whichever one has been right about that person. The readout above is what the last redirected shot actually used.',
    })
end

do
    local TargetSection = SilentAimTab:CreateSection('targets')

    TargetSection:Dropdown({
        Title = 'gun targets',
        Description = 'who the gun is allowed to redirect onto',
        Values = Choice.GunTargets.order,
        Default = Choice.GunTargets.default,
        Flag = 'mm2_silent_aim_gun_targets',
        Callback = function(value) Aim.GunTargets = Choice.pick(Choice.GunTargets, value) end,
    })

    TargetSection:Dropdown({
        Title = 'knife targets',
        Description = 'who the knife is allowed to redirect onto',
        Values = Choice.KnifeTargets.order,
        Default = Choice.KnifeTargets.default,
        Flag = 'mm2_silent_aim_knife_targets',
        Callback = function(value) Aim.KnifeTargets = Choice.pick(Choice.KnifeTargets, value) end,
    })

    TargetSection:Dropdown({
        Title = 'priority',
        Description = 'how the allowed targets get ranked once more than one qualifies',
        Values = Choice.Priority.order,
        Default = Choice.Priority.default,
        Flag = 'mm2_silent_aim_priority',
        Callback = function(value) Aim.Priority = Choice.pick(Choice.Priority, value) end,
    })
end

do
    local FovSection = SilentAimTab:CreateSection('fov')

    FovSection:Dropdown({
        Title = 'fov',
        Description = 'off lets anything on screen be a target',
        Values = Choice.Fov.order,
        Default = Choice.Fov.default,
        Flag = 'mm2_silent_aim_fov',
        Callback = function(value) Aim.FOVRadius = Choice.valueOf(Choice.Fov, value) end,
    })

    FovSection:Dropdown({
        Title = 'fov anchor',
        Description = 'what that radius is measured from',
        Values = Choice.Anchor.order,
        Default = Choice.Anchor.default,
        Flag = 'mm2_silent_aim_anchor',
        Callback = function(value) Aim.FOVAnchor = Choice.pick(Choice.Anchor, value) end,
    })

    FovSection:Dropdown({
        Title = 'search',
        Description = 'anywhere also allows targets off screen, including behind you',
        Values = Choice.Search.order,
        Default = Choice.Search.default,
        Flag = 'mm2_silent_aim_search',
        Callback = function(value) Aim.OffScreen = Choice.pick(Choice.Search, value) == 'Anywhere' end,
    })
end


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


local gunLeadStat, gunMultStat

do
    local GunLeadSection = SilentAimTab:CreateSection('gun lead')

    GunLeadSection:Dropdown({
        Title = 'gun lead',
        Description = 'auto finds the length itself from shots that really landed',
        Values = Choice.Lead.order,
        Default = Choice.Lead.default,
        Flag = 'mm2_gun_lead',
        Callback = function(value)
            local profile = Choice.valueOf(Choice.Lead, value)
            GunTune.Extra = profile.extra
            GunTune.Auto = profile.auto
        end,
    })

    gunLeadStat = addStat(GunLeadSection, { Title = 'gun hits / shots', Value = '0 / 0' })
    gunMultStat = addStat(GunLeadSection, { Title = 'gun auto multiplier', Value = 'off' })
end

local knifeLeadStat, knifeMultStat

do
    local KnifeLeadSection = SilentAimTab:CreateSection('knife lead')

    KnifeLeadSection:Dropdown({
        Title = 'knife lead',
        Description = 'on top of the throw speed below, which is read off the game itself',
        Values = Choice.Lead.order,
        Default = Choice.Lead.default,
        Flag = 'mm2_knife_lead',
        Callback = function(value)
            local profile = Choice.valueOf(Choice.Lead, value)
            KnifeTune.Extra = profile.extra
            KnifeTune.Auto = profile.auto
        end,
    })

    knifeSpeedStat = addStat(KnifeLeadSection, { Title = 'throw speed (auto)', Value = ('%d studs/s'):format(KnifeTune.Speed) })
    knifeLeadStat = addStat(KnifeLeadSection, { Title = 'knife hits / shots', Value = '0 / 0' })
    knifeMultStat = addStat(KnifeLeadSection, { Title = 'knife auto multiplier', Value = 'off' })
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
    Flag = 'mm2_dropped_gun_esp',
    Callback = function(state)
        DroppedGunEsp.Enabled = state
        droppedGunEspRefreshAll()
    end,
})

local SessionSection = VisualTab:CreateSection('session')

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
            gunLeadStat.Set(('%d / %d'):format(GunLead.hits, GunLead.verified))
            knifeLeadStat.Set(('%d / %d'):format(KnifeLead.hits, KnifeLead.verified))
            gunMultStat.Set(GunTune.Auto and ('%.2fx'):format(GunLead.mult) or 'off')
            knifeMultStat.Set(KnifeTune.Auto and ('%.2fx'):format(KnifeLead.mult) or 'off')
            solverStat.Set(Aim.Math == 'Adaptive' and lastModelUsed or Aim.Math)
        end)
    end
end)


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
        Content = 'there is not a single number to dial in on the silent aim side any more. every setting is a dropdown, and each option carries a whole set of tuned values behind it - the filter constants, how many times the lead re-solves, how much of your ping counts, how far the search reaches. picking a name picks all of it at once. the trigger bot reaction time is the one slider, since that one really is just a number',
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
        Content = 'how much of your round trip counts toward the lead. the shot has to reach the server and the target you are looking at was already a trip old when it reached you, so the whole round trip belongs in the lead, not half of it. it is read from the game network stats - the same data ping the performance overlay shows - with the per player ping doubled as a floor, since that one only reads about half the trip. ignore contributes nothing, full + margin overshoots slightly for a connection that spikes',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'replication buffer',
        Content = 'roblox draws every other player a little behind even the newest position it has for them, so their movement looks smooth instead of stepping from packet to packet. that delay is real lead the shot has to cover, but the game does not expose it, so this is a setting rather than a reading. normal is about a tenth of a second, which is typical. if shots still land behind people who are running straight, go up one; if they land in front, go down one. a target whose updates are visibly arriving in steps is measured and covered on top of this automatically',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'shots redirected',
        Content = 'how many of your shots get redirected at all. the rest fire exactly where you aimed, untouched. a shot the trigger bot fires is always redirected',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'gun lead / knife lead',
        Content = 'a flat amount added on top of ping, the replication buffer, frame time and, for the knife, its real flight time. lead options aim further ahead of the target, back options aim behind them - use those if shots keep landing in front, since they walk the point back toward where the target already was',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'auto lead',
        Content = 'the auto option on either lead dropdown tries a slightly shorter or longer lead than usual on a random real shot now and then, and nudges a multiplier toward whichever length is actually landing more - measured from the target really taking damage, not from any raycast guess. only shots that were really fired and redirected count, a run of shots where nothing landed at any length is thrown away rather than read as a direction, and the multiplier stays between 0.6x and 2x. it is a slow fine tune on top of the lead model, not the thing that makes the lead right',
    })
    InfoSilentAimSection:Paragraph({
        Title = 'lead time readout',
        Content = 'the lead line under prediction maths shows exactly what the last solve used - round trip, buffer, frame, flight, the lead profile and the auto multiplier - so if something is off you can see which part',
    })

    local InfoTriggerSection = InfoTab:CreateSection('trigger bot')
    InfoTriggerSection:Paragraph({
        Title = 'trigger bot',
        Content = 'fires for you once a target has been in view for your reaction time. it only ever uses a weapon that is already in your hands - it never equips anything. the gun one fires through the gun itself where it can, so its own cooldown, animation and sound all happen as normal, and silent aim redirects the shot like any other',
    })
    InfoTriggerSection:Paragraph({
        Title = 'reaction time',
        Content = 'runs twice, in order: once from the moment the weapon comes out, and again from the moment a target is first seen after that. so pulling the gun on someone already standing in front of you takes two reactions, like it would for a person. losing sight of someone for a split second does not restart it, losing them properly does. reaction variance spreads each one randomly either side of the slider so no two are identical',
    })
    InfoTriggerSection:Paragraph({
        Title = 'sees a target when',
        Content = 'visible is any target silent aim would take that the weapon has a clear line to. near crosshair also needs them close to your mouse, on crosshair needs your mouse actually over them. with silent aim off, the gun fired through its own script shoots where you point, so the gun trigger bot falls back to on crosshair by itself then - otherwise it would fire at someone it cannot hit',
    })
    InfoTriggerSection:Paragraph({
        Title = 'gun safety',
        Content = 'shooting an innocent as sheriff gets you killed, so the gun trigger bot only fires at the murderer unless you switch it to follow the silent aim gun targets',
    })
    InfoTriggerSection:Paragraph({
        Title = 'fire method',
        Content = 'activate clicks the gun through its own script. remote sends the gun shot straight at the solved point, which works even if the game does not listen for a tool click. auto starts with activate and switches to remote for good if a few attempts in a row never produce a shot at the hook',
    })
    InfoTriggerSection:Paragraph({
        Title = 'throw trigger bot',
        Content = 'same reaction rules for the knife. a throw is always sent at the solved point, so it leads the target by the knife real flight time whether silent aim is on or not. throw range keeps it from throwing at someone far enough away to simply walk out of the way',
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

    -- seconds other players are drawn behind the newest state the client has
    -- for them. the engine interpolates remote characters through a buffer it
    -- never exposes, so this is a setting rather than a reading
    Buffer = {
        default = 'Normal',
        order = { 'None', 'Low', 'Normal', 'High', 'Very high' },
        value = {
            ['None']      = 0,
            ['Low']       = 0.05,
            ['Normal']    = 0.1,
            ['High']      = 0.15,
            ['Very high'] = 0.2,
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

-- walk fling. the teleport and the spin in the usual fling scripts are only the
-- delivery: they exist to reach someone across the map and to keep the solver
-- from settling. walking supplies the contact for free, so all that is left to
-- supply is the momentum - claimed before the physics step and taken back after
Choice.Fling = {
    Power = {
        default = 'Normal',
        order = { 'Gentle', 'Normal', 'Strong', 'Extreme', 'Absurd' },
        -- lift multiplies the vertical component, which is what sends them up
        -- rather than skidding along the floor
        value = {
            ['Gentle']  = { linear = 1e4, angular = 1e5, lift = 2 },
            ['Normal']  = { linear = 1e6, angular = 1e7, lift = 5 },
            ['Strong']  = { linear = 1e7, angular = 1e8, lift = 8 },
            ['Extreme'] = { linear = 9e7, angular = 9e8, lift = 10 },
            ['Absurd']  = { linear = 9e9, angular = 9e9, lift = 10 },
        },
    },

    Reach = {
        default = 'Touch',
        order = { 'Touch', 'Close', 'Medium', 'Wide' },
        value = { ['Touch'] = 6, ['Close'] = 10, ['Medium'] = 16, ['Wide'] = 28 },
    },

    -- Angular is the one that actually transfers. A spin claim puts an enormous
    -- velocity on the *surface* of your assembly, which is what the contact
    -- resolves against; a linear claim mostly just launches you, because your
    -- own centre of mass is what it moves. Angular only is the default for
    -- that reason, and it is also the only mode that leaves you able to walk,
    -- since your walking *is* linear velocity and nothing here touches it.
    Claim = {
        default = 'Angular only',
        order = { 'Angular only', 'Angular + lift', 'Both', 'Linear only' },
        value = {
            ['Angular only']  = { angular = true, linear = false, lift = false },
            ['Angular + lift'] = { angular = true, linear = false, lift = true },
            ['Both']          = { angular = true, linear = true,  lift = true },
            ['Linear only']   = { angular = false, linear = true,  lift = true },
        },
    },

    -- How far your own character is allowed to move in one step before it gets
    -- put back. Walking at 16 studs a second covers about a quarter of a stud
    -- per frame, so anything here is orders of magnitude above normal movement
    -- and only ever catches a claim that threw you.
    Leash = {
        default = 'Normal',
        order = { 'Tight', 'Normal', 'Loose', 'Off' },
        value = { ['Tight'] = 8, ['Normal'] = 20, ['Loose'] = 60, ['Off'] = math.huge },
    },

    Targets = {
        default = 'Anyone',
        order = { 'Anyone', 'Murderer only', 'Armed only' },
    },

    -- Overlap is the one that actually works. It puts your root inside theirs
    -- and alternates above and below them a frame apart, so every frame is a
    -- fresh interpenetration the solver has to resolve, from a direction that
    -- keeps changing. Orbit circles at arm's length instead - quieter to watch
    -- and much weaker, kept only because it does not put you inside anybody.
    Style = {
        default = 'Overlap',
        order = { 'Overlap', 'Orbit' },
    },

    -- how wide the circle is when it orbits someone. kept at or under six
    -- studs so it stays a contact rather than a lunge across the room
    Orbit = {
        default = 'Four',
        order = { 'Two', 'Three', 'Four', 'Five', 'Six' },
        value = { ['Two'] = 2, ['Three'] = 3, ['Four'] = 4, ['Five'] = 5, ['Six'] = 6 },
    },

    -- how long to keep circling before giving up and going home, so a target
    -- that simply cannot be flung does not strand you next to them
    Patience = {
        default = 'Normal',
        order = { 'Brief', 'Normal', 'Stubborn' },
        value = { ['Brief'] = 1, ['Normal'] = 2.5, ['Stubborn'] = 5 },
    },

    -- what counts as abnormal motion on your own character. walking is 16 and
    -- a jump peaks near 50, so even strict leaves ordinary movement alone
    Guard = {
        default = 'Normal',
        order = { 'Strict', 'Normal', 'Loose' },
        value = {
            ['Strict'] = { linear = 120, angular = 25 },
            ['Normal'] = { linear = 250, angular = 60 },
            ['Loose']  = { linear = 600, angular = 150 },
        },
    },

    Grab = {
        default = 'Fire touch',
        order = { 'Fire touch', 'Teleport' },
    },
}

-- the advanced tab's own option sets, kept on Choice so they resolve through
-- the same pick/valueOf guard as everything else
Choice.Adv = {
    Solver = {
        default = 'Ensemble',
        order = { 'Ensemble', 'Best single', 'Top two', 'Fixed circle', 'Fixed arc' },
    },

    -- how an ensemble turns four running error scores into four weights
    -- sharper weightings collapse toward simply picking the winner, which is
    -- what you want when one model is clearly right; the soft ones only pay
    -- off when two models are genuinely within noise of each other
    Weighting = {
        default = 'Inverse square',
        order = { 'Equal', 'Inverse error', 'Softmax', 'Inverse square', 'Inverse fourth' },
    },

    -- how much of the running signed residual gets subtracted back out
    Bias = {
        default = 'Normal',
        order = { 'Off', 'Light', 'Normal', 'Aggressive', 'Full' },
        value = { ['Off'] = 0, ['Light'] = 0.3, ['Normal'] = 0.6, ['Aggressive'] = 0.85, ['Full'] = 1 },
    },

    -- how close two passes must land before the lead solve calls it settled
    Converge = {
        default = 'Tight',
        order = { 'Fixed', 'Loose', 'Tight', 'Exhaustive' },
        value = { ['Fixed'] = nil, ['Loose'] = 0.25, ['Tight'] = 0.05, ['Exhaustive'] = 0.01 },
    },

    -- how many samples of their motion the backtest gets to replay over
    Depth = {
        default = 'Long',
        order = { 'Short', 'Normal', 'Long', 'Maximum' },
        value = {
            ['Short']   = { limit = 16, window = 0.4 },
            ['Normal']  = { limit = 28, window = 0.7 },
            ['Long']    = { limit = 40, window = 0.9 },
            ['Maximum'] = { limit = 64, window = 1.4 },
        },
    },

    -- the lead length the models are scored at. weapon match tracks the real
    -- travel time, so the scoring horizon follows the shot it is scoring for
    Horizon = {
        default = 'Weapon match',
        order = { 'Snap', 'Short', 'Weapon match', 'Long', 'Very long' },
        value = { ['Snap'] = 0.1, ['Short'] = 0.15, ['Weapon match'] = -1, ['Long'] = 0.3, ['Very long'] = 0.45 },
    },

    -- how fast a scoring round moves a model's running error
    Reaction = {
        default = 'Normal',
        order = { 'Instant', 'Fast', 'Normal', 'Slow', 'Glacial' },
        value = { ['Instant'] = 0.8, ['Fast'] = 0.45, ['Normal'] = 0.25, ['Slow'] = 0.12, ['Glacial'] = 0.05 },
    },

    -- a model scoring worse than this multiple of the best is dropped from the
    -- blend entirely rather than dragging the average toward its own answer
    Guard = {
        default = 'Normal',
        order = { 'Off', 'Light', 'Normal', 'Strict' },
        value = { ['Off'] = math.huge, ['Light'] = 6, ['Normal'] = 3, ['Strict'] = 1.8 },
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

    GunTargets = {
        default = 'Murderer only',
        order = { 'Murderer only', 'Silent aim targets' },
    },

    -- studs; a throw at someone further than this has time to be walked out of
    ThrowRange = {
        default = 'Medium',
        order = { 'Close', 'Medium', 'Far', 'Any' },
        value = { ['Close'] = 25, ['Medium'] = 50, ['Far'] = 90, ['Any'] = math.huge },
    },
}

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
    Buffer = Choice.valueOf(Choice.Buffer),
    ShotChance = Choice.valueOf(Choice.Shots),
}

local GunTune = { Extra = 0, Auto = Choice.Lead.value[Choice.Lead.default].auto }
local KnifeTune = { Extra = 0, Speed = 96, Auto = Choice.Lead.value[Choice.Lead.default].auto }

-- global on purpose: cold enough that a hash lookup costs nothing, and
-- reachable from a console without going through the MM2 table below
Debug = {
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

    Epsilon = 0.05,  -- keeps an inverse-error weight finite at zero error
    MaxPasses = 12,  -- ceiling on the converging lead solve
    Temp = 0.25,     -- softmax temperature, as a share of the best error
    MinHeading = 0.5, -- speed below which there is no heading to resolve bias in

    -- what the last lead solve was made of, overwritten in place rather than
    -- rebuilt so the per-frame solve does not allocate. the readout shows it
    lead = { rtt = 0, buffer = 0, frame = 0, flight = 0, extra = 0, mult = 1, total = 0 },
    leadStats = {},

    -- reused by every blend so a solve does not build a fresh table per pass
    scratch = {},
}

-- the advanced tab. when Enabled, these take over from the normal silent aim
-- tab for everything about how the shot is solved. what still comes from that
-- tab is listed in Advanced.Passthrough below - the target side of things,
-- which advanced has no better answer for
local Advanced = {
    Enabled = false,
    Perfection = false,

    Solver = 'Ensemble',
    -- the dropdowns only fire on a change, never at startup, so every field
    -- here has to start on exactly what its dropdown shows
    Weighting = Choice.Adv.Weighting.default,
    Bias = 'Normal',
    Converge = 'Tight',

    Depth = 'Long',
    Horizon = 'Weapon match',
    Reaction = 'Normal',
    Guard = 'Normal',
    Smoothing = 'Balanced',
    Part = 'Auto',
    Air = 'Safe',
    Ping = 'Full',
    Buffer = 'Normal',
    Lead = 'Auto',

    Passthrough = 'range, gun and knife targets, priority, wall check, fov and search',
    ui = {},
}

-- global on purpose, like Fling and AutoGun: this chunk is at its local limit,
-- and it is only read a handful of times a frame, where a hash lookup is free
Trigger = {
    Gun = false,
    Throw = false,
    Reaction = 180,
    Jitter = Choice.Trigger.Jitter.default,
    Sees = Choice.Trigger.Sees.default,
    Interval = Choice.Trigger.Interval.default,
    Method = Choice.Trigger.Method.default,
    GunTargets = Choice.Trigger.GunTargets.default,
    ThrowRange = Choice.Trigger.ThrowRange.default,

    -- how long a target may drop out of sight before it counts as lost, and
    -- how long a gun activation has to show up at the hook as a real shot
    Grace = 0.15,
    Confirm = 0.35,
    Retry = 0.25,
    Misfires = 3,

    gun = { held = false, readyAt = 0, target = nil, seenAt = 0, lastSeen = 0, nextAt = 0, shotAt = 0, status = 'off' },
    knife = { held = false, readyAt = 0, target = nil, seenAt = 0, lastSeen = 0, nextAt = 0, shotAt = 0, status = 'off' },

    sawGun = 0,
    sawKnife = 0,
    pendingAt = 0,
    misfires = 0,
    fallback = false,
    forceUntil = 0,
    hooked = false,
    shots = 0,
    throws = 0,
}

-- the full round trip, not a one way figure: see getPing
local cachedPing = 0.12
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
    if Advanced.Enabled then
        return Choice.valueOf(Choice.Filter, Advanced.Smoothing)
    end
    return Choice.valueOf(Choice.Filter, Aim.Filter)
end

-- the scoring horizon. weapon match follows the travel time the solver last
-- actually produced, so the models are scored over the lead they are being
-- asked to cover rather than a fixed guess at it
function Adapt.horizon()
    if not Advanced.Enabled then return Adapt.Target end
    local want = Choice.valueOf(Choice.Adv.Horizon, Advanced.Horizon) or Adapt.Target
    if want and want > 0 then return want end
    return math.clamp(Adapt.lastTravel or Adapt.Target, Adapt.MinAge, Adapt.MaxAge)
end

function Adapt.depth()
    if not Advanced.Enabled then return HISTORY_LIMIT, HISTORY_WINDOW end
    local set = Choice.valueOf(Choice.Adv.Depth, Advanced.Depth)
    if not set then return HISTORY_LIMIT, HISTORY_WINDOW end
    return set.limit, set.window
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

    local item = Adapt.pingItem
    if item == nil then
        local found = pcall(function()
            item = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
        end)
        item = found and item or false
        Adapt.pingItem = item
    end
    if item then
        local okData, ms = pcall(function() return item:GetValue() end)
        if okData and typeof(ms) == "number" and ms / 1000 > rtt then rtt = ms / 1000 end
    end

    if rtt <= 0 then return 0.12 end
    return math.min(rtt, 1)
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
            local gap = math.abs(age - Adapt.horizon())
            if gap < bestGap then snap, bestGap = history[index], gap end
        end
    end
    if not snap then return end

    entry.backtestAt = now
    local dt = now - snap.t

    local blend = Advanced.Enabled
        and (Choice.valueOf(Choice.Adv.Reaction, Advanced.Reaction) or Adapt.Blend)
        or Adapt.Blend

    for _, name in ipairs(Adapt.Models) do
        local missed = flatDistance(snap.p + modelStep(name, snap, dt), actual)
        local previous = entry.scores[name]
        entry.scores[name] = previous and (previous + (missed - previous) * blend) or missed
    end

    entry.scored = entry.scored + 1

    -- Replay whatever the solver would actually have sent for this snapshot and
    -- keep the signed miss, so the correction is measured against the real
    -- answer rather than against whichever single model happened to win.
    if Advanced.Enabled and Advanced.Bias ~= 'Off' and entry.scored >= Adapt.Samples then
        local heading = snap.horizontal
        if heading and heading.Magnitude >= Adapt.MinHeading then
            local ok, step = pcall(Adapt.step, entry, dt, snap)
            if ok and typeof(step) == "Vector3" then
                local residual = actual - (snap.p + step)

                -- split along and across the heading they had at the time, so
                -- the average survives them turning
                local forward = heading.Unit
                local side = perpOf(forward)
                local along = dotOf(residual, forward)
                local across = dotOf(residual, side)

                entry.biasAlong = entry.biasAlong
                    and entry.biasAlong + (along - entry.biasAlong) * blend or along
                entry.biasAcross = entry.biasAcross
                    and entry.biasAcross + (across - entry.biasAcross) * blend or across
                entry.biasSpan = dt
            end
        end
    end
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
    if Advanced.Enabled then
        local solver = Advanced.Solver
        if solver == 'Fixed circle' then return 'Circle' end
        if solver == 'Fixed arc' then return 'Arc' end
        -- Ensemble / Best single / Top two all resolve per shot inside
        -- Adapt.step; the name returned here is only what gets reported
        if not entry or entry.scored < Adapt.Samples then return 'Arc' end
        return solver == 'Best single' and (entry.best or 'Arc') or solver
    end

    local mode = Aim.Math
    if mode ~= 'Adaptive' then return mode end
    if not entry or entry.scored < Adapt.Samples then return 'Arc' end
    return entry.best or 'Arc'
end

-- The blend's weights, one per model, written into out. The solve and the
-- advanced tab's readout both go through this, so the readout shows exactly
-- the blend the shot used rather than its own copy of the maths drifting from
-- it. Returns the total weight and the single best model.
function Adapt.weights(entry, out)
    local best, bestError = nil, math.huge
    for _, name in ipairs(Adapt.Models) do
        local score = entry.scores[name]
        if score and score < bestError then best, bestError = name, score end
    end

    local solver = Advanced.Solver

    -- Top two keeps the winner and the runner up and drops the rest
    local secondError = math.huge
    if solver == 'Top two' then
        for _, name in ipairs(Adapt.Models) do
            local score = entry.scores[name]
            if score and name ~= best and score < secondError then secondError = score end
        end
    end

    local guard = Choice.valueOf(Choice.Adv.Guard, Advanced.Guard)
    local weighting = Advanced.Weighting
    local cutoff = bestError * guard + Adapt.Epsilon
    local total = 0

    for _, name in ipairs(Adapt.Models) do
        local score = entry.scores[name]
        local weight = 0

        if not best then
            weight = 0
        elseif solver == 'Best single' then
            weight = name == best and 1 or 0
        elseif score and score <= cutoff then
            if solver == 'Top two' and name ~= best and score > secondError then
                weight = 0
            elseif weighting == 'Equal' then
                weight = 1
            elseif weighting == 'Softmax' then
                weight = math.exp(-(score - bestError) / (bestError * Adapt.Temp + Adapt.Epsilon))
            elseif weighting == 'Inverse square' then
                local inv = 1 / (score + Adapt.Epsilon)
                weight = inv * inv
            elseif weighting == 'Inverse fourth' then
                local inv = 1 / (score + Adapt.Epsilon)
                inv = inv * inv
                weight = inv * inv
            else
                weight = 1 / (score + Adapt.Epsilon)
            end
        end

        out[name] = weight
        total = total + weight
    end

    return total, best
end

-- Argmax throws away three quarters of what the backtest learned. This blends
-- every model that is still in contention, weighted by how wrong it has been,
-- so the ones that disagree partly cancel instead of one of them simply losing.
-- entry holds the scores that decide the weights; state is the motion the
-- models are stepped from. They are the same thing for a live shot, but the
-- backtest has to replay from a *snapshot* while still weighting by what the
-- entry has learned, so the two are separate arguments.
function Adapt.step(entry, t, state)
    state = state or entry

    local weights = Adapt.scratch
    local total, best = Adapt.weights(entry, weights)
    if not best then return modelStep('Arc', state, t) end
    if total <= 0 then return modelStep(best, state, t) end

    local blended = Vector3.zero
    for _, name in ipairs(Adapt.Models) do
        local weight = weights[name]
        if weight > 0 then
            blended = blended + modelStep(name, state, t) * weight
        end
    end
    return blended / total
end

-- The models are wrong in a direction, not just by an amount. Tracking the
-- signed residual and subtracting it back out is what corrects a lead that is
-- consistently short or consistently long, which no amount of picking between
-- models will ever fix on its own.
function Adapt.correct(entry, t)
    if not Advanced.Enabled or Advanced.Bias == 'Off' then return Vector3.zero end
    if entry.biasAlong == nil or entry.scored < Adapt.Samples then return Vector3.zero end

    local share = Choice.valueOf(Choice.Adv.Bias, Advanced.Bias) or 0
    if share <= 0 then return Vector3.zero end

    -- the residual was measured over one scoring horizon, so it scales with
    -- however much lead this particular shot is actually asking for
    local measured = entry.biasSpan or Adapt.Target
    if measured <= 0 then return Vector3.zero end

    -- Rebuilt in the heading they have *now*. The bias is stored as along-track
    -- and cross-track, never as a world vector: a lead that is consistently
    -- short is short along their direction of travel whichever way that points,
    -- and averaging that in world space just smears it into nothing on anyone
    -- who is turning.
    local heading = entry.horizontal
    if not heading or heading.Magnitude < Adapt.MinHeading then return Vector3.zero end

    -- A running average of past misses is only worth anything on someone whose
    -- motion is consistent enough for the past to say something about the next
    -- fraction of a second. On a target flipping direction every few frames it
    -- is stale noise, so it fades out with how steady they actually are.
    local forward = heading.Unit
    local side = perpOf(forward)
    local scale = (t / measured) * share * math.clamp(entry.steady or 1, 0, 1)

    local scaled = (forward * entry.biasAlong + side * entry.biasAcross) * scale
    if scaled.Magnitude > MAX_LEAD_OFFSET then
        scaled = scaled.Unit * MAX_LEAD_OFFSET
    end
    return scaled
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
            biasAlong = nil,
            biasAcross = nil,
            biasSpan = nil,
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
        local depthLimit, depthWindow = Adapt.depth()
        while #entry.history > depthLimit or (entry.history[1] and now - entry.history[1].t > depthWindow) do
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

    -- advanced blends the models and then corrects the blend's own running
    -- bias; the normal path is the single picked model, unchanged
    local horizontal
    if Advanced.Enabled and entry.scored >= Adapt.Samples
        and Advanced.Solver ~= 'Fixed circle' and Advanced.Solver ~= 'Fixed arc'
    then
        horizontal = Adapt.step(entry, travelTime) + Adapt.correct(entry, travelTime)
    else
        horizontal = modelStep(mode, entry, travelTime)
    end

    if horizontal.Magnitude > MAX_LEAD_OFFSET then
        horizontal = horizontal.Unit * MAX_LEAD_OFFSET
    end

    local airMode = Advanced.Enabled and Advanced.Air or Aim.Air

    local y = base.Y
    if entry.airborne and airMode ~= 'Off' then
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

-- Auto lead. Every so often a real shot is fired with a slightly shorter or
-- longer lead than the learned centre, and the centre moves toward whichever
-- length is actually landing more. It used to be fed from the per-frame plan
-- rather than from shots, so with a target merely in view it scored thousands
-- of shots nobody fired, all of them "misses", and swept the multiplier up and
-- wrapped it from 4x back to 0.4x every few seconds - the lead was a sawtooth
-- that spent half its time far too short. Now an arm is only ever picked for a
-- shot the hook really redirected, a block with nothing landed is discarded
-- instead of read as a direction, and there is no wrap.
local newLeadState, pickArm, armMultiplier, updateBandit
do
    local DITHER = 0.2
    local MIN_ARM_SAMPLES = 3
    local MULT_MIN = 0.6
    local MULT_MAX = 2
    local ARM_MARGIN = 0.15
    local STEP = 0.1
    local EXPLORE_CHANCE_BASE = 0.3
    local EXPLORE_CHANCE_MIN = 0.1
    local EXPLORE_DECAY = 0.8

    -- auto follows whichever lead dropdown is in charge: advanced's own while
    -- advanced mode is on, otherwise the weapon's one on the silent aim tab
    local function isAuto(state)
        if Advanced.Enabled then
            local profile = Choice.valueOf(Choice.Lead, Advanced.Lead)
            return profile ~= nil and profile.auto
        end
        return state.tune.Auto
    end

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

    -- picked once per real shot. nil while auto is off, which is also how a
    -- resolved shot knows not to feed the bandit
    function pickArm(state)
        if not isAuto(state) then return nil end
        if math.random() >= state.exploreChance then return 2 end
        return math.random() < 0.5 and 1 or 3
    end

    -- nil is the standing per-frame solve: the learned centre, no dither
    function armMultiplier(state, arm)
        if not isAuto(state) then return 1 end
        if arm == 1 then return state.mult * (1 - DITHER) end
        if arm == 3 then return state.mult * (1 + DITHER) end
        return state.mult
    end

    function updateBandit(state)
        local arms = state.arms
        if arms[1].shot < MIN_ARM_SAMPLES or arms[3].shot < MIN_ARM_SAMPLES then return end

        local landed = arms[1].hit + arms[2].hit + arms[3].hit
        local moved = false

        -- nothing landing at any length says nothing about which way the lead
        -- is off - a wall, a dodge and a bad angle miss the same at every
        -- length - so that block is thrown away, not read as a direction
        if landed > 0 then
            local centre = arms[2].shot > 0 and (arms[2].hit / arms[2].shot) or 0
            local low = arms[1].hit / arms[1].shot
            local high = arms[3].hit / arms[3].shot

            -- a tie goes long: a lead that is short is the common failure
            if high > centre + ARM_MARGIN and high >= low then
                state.mult = state.mult * (1 + STEP)
                moved = true
            elseif low > centre + ARM_MARGIN and low > high then
                state.mult = state.mult * (1 - STEP)
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

-- How far ahead of what is on screen the shot has to land, in seconds. The
-- target you see was drawn from a state that is your whole round trip plus the
-- replication buffer old by the time your shot reaches the server, so those
-- are the lead, along with a frame of your own and, for the knife, its real
-- flight time. A target whose updates are visibly arriving in steps is behind
-- by more than the buffer alone, so that measured gap wins when it is larger.
-- The auto multiplier only scales the latency part: flight time is measured
-- off the knife itself and the profile is a trim you picked, neither of which
-- is the uncertain bit.
local function travelTimeFor(state, entry, distance, arm)
    local tune = state.tune
    local lead = Adapt.lead

    local pingScale, buffer
    if Advanced.Enabled then
        pingScale = Choice.valueOf(Choice.Ping, Advanced.Ping) or 1
        buffer = Choice.valueOf(Choice.Buffer, Advanced.Buffer) or 0
    else
        pingScale, buffer = Aim.PingScale, Aim.Buffer
    end

    lead.rtt = cachedPing * pingScale
    lead.buffer = math.max(buffer, entry ~= nil and entry.repLag or 0)
    lead.frame = cachedFrame
    lead.flight = (tune.Speed ~= nil and tune.Speed > 0) and distance / tune.Speed or 0

    -- advanced drives both weapons from its own lead dropdown rather than the
    -- two separate ones on the normal tab
    if Advanced.Enabled then
        local profile = Choice.valueOf(Choice.Lead, Advanced.Lead)
        lead.extra = profile and profile.extra / 1000 or 0
    else
        lead.extra = tune.Extra / 1000
    end
    lead.mult = armMultiplier(state, arm)

    local total = (lead.rtt + lead.buffer + lead.frame) * lead.mult + lead.flight + lead.extra
    total = math.clamp(total, -MAX_TRAVEL_TIME, MAX_TRAVEL_TIME)
    lead.total = total
    return total
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
            -- arm is only set on a shot fired with auto lead on
            if record.arm then
                local arm = state.arms[record.arm]
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
    local airMode = Advanced.Enabled and Advanced.Air or Aim.Air
    if airMode ~= 'Off' and entry and (entry.airborne or isSpamJumper(entry)) then return 'Body' end
    if entry and entry.horizontal.Magnitude > Adapt.HeadSpeed then return 'Body' end

    local root = char:FindFirstChild("HumanoidRootPart")
    if root and (root.Position - Camera.CFrame.Position).Magnitude > Adapt.HeadRange then return 'Body' end

    return 'Head'
end

local function aimPartsFor(char, entry)
    local airMode = Advanced.Enabled and Advanced.Air or Aim.Air
    local choice = Advanced.Enabled and Advanced.Part or Aim.AimPart
    if choice == 'Auto' then choice = autoAimPart(char, entry) end

    local order = PART_ORDER_BODY
    if choice == 'Head' and not (airMode == 'Safe' and entry and isSpamJumper(entry)) then
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

    local airMode = Advanced.Enabled and Advanced.Air or Aim.Air
    local offset = partPos - rootPos
    if entry.airborne and (airMode == 'Feet' or airMode == 'Safe') then
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

    -- A fixed pass count stops wherever it happens to be. Converging runs the
    -- lead against its own answer until the point stops moving, so the distance
    -- the travel time is solved from is the distance the shot actually covers.
    local tolerance = Advanced.Enabled
        and Choice.Adv.Converge.value[Choice.pick(Choice.Adv.Converge, Advanced.Converge)]
        or nil

    if tolerance then
        for _ = 2, Adapt.MaxPasses do
            local previous = predicted
            distance = ((predicted + offset) - origin).Magnitude
            travelTime = travelTimeFor(state, entry, distance, arm)
            predicted = predictRoot(entry, rootPos, sinceSample, travelTime, mode)
            if (predicted - previous).Magnitude <= tolerance then break end
        end
    else
        for _ = 2, passes do
            distance = ((predicted + offset) - origin).Magnitude
            travelTime = travelTimeFor(state, entry, distance, arm)
            predicted = predictRoot(entry, rootPos, sinceSample, travelTime, mode)
        end
    end

    -- what the weapon-match scoring horizon follows
    Adapt.lastTravel = travelTime

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

    -- advanced is going for accuracy, so it redirects every shot regardless of
    -- what the normal tab's shot filter is set to, and a shot the trigger bot
    -- fired was fired to hit, so it is never left to the roll either
    local now = os.clock()
    local chance = (Advanced.Enabled or now < Trigger.forceUntil) and 100 or Aim.ShotChance
    if chance < 100 and math.random() * 100 >= chance then
        shotStats.suppressed = shotStats.suppressed + 1
        noteShot(plan, "chance roll", origin, sent, nil, nil, nil, nil)
        return nil
    end

    -- the auto lead arm is chosen here, per real shot, and only a shot that
    -- actually got solved and sent is logged for it
    plan.arm = pickArm(plan.state)

    local aim, predictedRoot, travel, model
    local ok, solved, _, solvedTravel, solvedDistance, solvedRoot, solvedModel = pcall(solveAim, plan, origin, now)
    if ok and typeof(solved) == "Vector3" then
        aim, predictedRoot, travel, model = solved, solvedRoot, solvedTravel, solvedModel
        logLead(plan.state, plan.char, solvedDistance, solvedTravel, plan.arm, now)
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
            -- no auto lead arm here: this is the standing solve every frame
            -- runs, not a shot, so it takes the learned centre and logs nothing
            local plan = {
                plr = plr,
                entry = entry,
                root = root,
                char = char,
                hipOffset = feetOffset(char),
                state = isKnife and KnifeLead or GunLead,
                isKnife = isKnife,
                arm = nil,
                stamp = now,
            }

            for _, part in ipairs(candidate.parts) do
                plan.part = part

                if clearPath(origin, part.Position, char) then
                    local aim, _, _, _, _, model = solveAim(plan, origin, now)

                    -- strict also demands the solved point be reachable, loose
                    -- only asks that the target is not behind a wall right now
                    if Aim.WallCheck ~= 'Strict' or clearPath(origin, aim, char) then
                        plan.fallback = CFrame.new(aim)
                        plan.model = model
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

--// trigger bot ---------------------------------------------------------------
--
-- Fires for you once a target has been in view long enough for a person to
-- have reacted to them. The reaction runs twice, in order: once when the
-- weapon comes out, then again from the moment a target is first seen after
-- that - so drawing on someone already standing in front of you takes two
-- reactions, the way it would for anyone. It only ever uses a weapon already
-- in your hands; nothing here equips anything. Targets come from the same plan
-- silent aim builds, so it fires at exactly who silent aim would redirect onto.

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
-- happens to be: a throw is always sent at the solved point, and the gun is
-- when silent aim is redirecting it or it goes straight out by remote
function Trigger.aimed(which)
    if which == 'Knife' then return true end
    return (Aim.Enabled and Trigger.hooked) or Trigger.gunMethod() == 'Remote'
end

-- a clear line from the weapon whatever the silent aim wall check is set to:
-- this is deciding whether to fire at all, not where
function Trigger.clear(origin, point, char)
    local direction = point - origin
    local result = weaponCast(origin, direction, { char })
    return not result or (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

function Trigger.sees(which, plan, origin, now)
    if not plan or not plan.part or not plan.fallback or now - plan.stamp > PLAN_STALE then return false end

    if which == 'Gun' then
        -- shooting an innocent as sheriff gets you killed
        if Choice.pick(Choice.Trigger.GunTargets, Trigger.GunTargets) == 'Murderer only'
            and not (plan.plr and isMurderer(plan.plr))
        then
            return false
        end
    else
        local reach = Choice.valueOf(Choice.Trigger.ThrowRange, Trigger.ThrowRange) or math.huge
        if (plan.part.Position - origin).Magnitude > reach then return false end
    end

    -- them, and the point the shot will actually be sent at, both in the open
    if not Trigger.clear(origin, plan.part.Position, plan.char) then return false end
    if not Trigger.clear(origin, plan.fallback.Position, plan.char) then return false end

    -- a gun fired through its own script with nothing redirecting it goes
    -- where you point, so then only a target under the mouse counts
    local mode = Choice.pick(Choice.Trigger.Sees, Trigger.Sees)
    if not Trigger.aimed(which) then mode = 'On crosshair' end
    if mode == 'Visible' then return true end

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

function Trigger.fireGun(tool, plan, now)
    Trigger.forceUntil = now + Trigger.Confirm
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
    Trigger.forceUntil = now + Trigger.Confirm
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

    local plan, origin
    if which == 'Gun' then
        plan, origin = gunPlan, findGunOrigin()
    else
        plan, origin = knifePlan, findKnifeOrigin()
    end

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

    s.status = 'firing at ' .. plan.char.Name
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
    Trigger.run('Gun', Trigger.gun, now)
    Trigger.run('Knife', Trigger.knife, now)
end

track(PreSimulation:Connect(function()
    if Unloading or not (Aim.Enabled or Trigger.Gun or Trigger.Throw) then
        gunPlan, knifePlan = nil, nil
        return
    end

    local ok = pcall(function()
        local now = os.clock()
        cachedPing = cachedPing + (getPing() - cachedPing) * 0.2
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

        -- only the weapon in your hands gets a plan: nothing else can fire, and
        -- the advanced scoring horizon follows whichever plan solved last, so
        -- solving both mixed the gun's lead into the knife's every frame
        local char = LocalPlayer.Character
        gunPlan = char and char:FindFirstChild("Gun") and buildPlan(false, findGunOrigin(), now) or nil
        knifePlan = buildPlan(true, findKnifeOrigin(), now)

        Trigger.step(now)
        debugTick(now)
    end)

    if not ok then
        gunPlan, knifePlan = nil, nil
    end
end))

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall
    local trigger = Trigger

    -- silent aim redirects here; the trigger bot only needs to know a shot
    -- really left, which is what confirms one it asked the gun to fire
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
                if Aim.Enabled and typeof(origin) == "CFrame" then
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
                trigger.sawKnife = os.clock()
                local handle, sent = ...
                if Aim.Enabled and typeof(handle) == "CFrame" then
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
    Trigger.hooked = true
end

--// walk fling ---------------------------------------------------------------
--
-- Your client owns your character's physics, so whatever velocity it reports is
-- taken as true. The claim is made before the physics step, where it takes part
-- in resolving any contact you are already standing in, and taken back after it
-- with your position restored - so the momentum lands on them and nothing about
-- your own character visibly moves. No teleport, because walking into someone
-- already provides the contact a teleport exists to manufacture.

Fling = {
    Enabled = false,
    OnTouch = true,
    Passive = false,
    Power = Choice.Fling.Power.default,
    Reach = Choice.Fling.Reach.default,
    Claim = Choice.Fling.Claim.default,
    Leash = Choice.Fling.Leash.default,
    Targets = Choice.Fling.Targets.default,
    Style = Choice.Fling.Style.default,
    Orbit = Choice.Fling.Orbit.default,
    Patience = Choice.Fling.Patience.default,
    Upright = true,
    savedHeight = nil,

    armed = false,
    busy = false,
    tookLinear = false,
    savedPos = nil,
    hits = 0,
    flung = 0,
    cooldown = {},
}

-- A flung player picks up a velocity nothing in normal play produces, and
-- leaves the spot they were standing in. Either is enough to call it done.
Fling.FLUNG_SPEED = 120
Fling.FLUNG_DISTANCE = 18
Fling.RETOUCH = 1.5
Fling.GUARD_NAME = "MM2FlingGuard"

function Fling.allowed(plr)
    if plr == LocalPlayer or not isAlivePlr(plr) then return false end
    local mode = Fling.Targets
    if mode == 'Murderer only' then return isMurderer(plr) end
    if mode == 'Armed only' then return heldWeapon(plr.Character) ~= nil end
    return true
end

function Fling.inRange(root, reach)
    for _, plr in ipairs(Players:GetPlayers()) do
        if Fling.allowed(plr) then
            local char = plr.Character
            local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
            if theirRoot and (theirRoot.Position - root.Position).Magnitude <= reach then
                return true
            end
        end
    end
    return false
end

function Fling.myRoot()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum.RootPart, hum
end

-- AssemblyLinearVelocity is the current name; the old one is kept as a fallback
-- so this still works on an older client. Either argument may be nil, and a nil
-- one is left strictly alone - that is what lets Angular only leave your own
-- walking velocity untouched instead of stamping over it every frame.
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

-- The leash, which replaces the old hard position pin. That pin restored your
-- CFrame every single frame, which also undid the walking you did during that
-- step - it was an anchor, not a walk fling. This only intervenes when you have
-- moved further in one step than any amount of walking could explain, and it
-- keeps the facing you currently have rather than the one you had a step ago,
-- so ordinary movement passes straight through untouched.
function Fling.leash(root)
    if not Fling.savedPos or Fling.savedChar ~= LocalPlayer.Character then return end

    local limit = Choice.valueOf(Choice.Fling.Leash, Fling.Leash)
    if limit == math.huge then return end

    local drift = (root.Position - Fling.savedPos).Magnitude
    if drift <= limit then return end

    pcall(function()
        root.CFrame = CFrame.new(Fling.savedPos) * (root.CFrame - root.CFrame.Position)
    end)
end

function Fling.reset()
    Fling.armed = false

    -- a guard left behind would pin you at a standstill forever, and a
    -- FallenPartsDestroyHeight left at NaN would stay that way for the session,
    -- so both come off here as well as at the end of a normal run
    local char = LocalPlayer.Character
    if char then
        local stale = char:FindFirstChild("HumanoidRootPart")
        stale = stale and stale:FindFirstChild(Fling.GUARD_NAME)
        if stale then pcall(function() stale:Destroy() end) end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end)
        end
    end

    if Fling.savedHeight then
        pcall(function() Workspace.FallenPartsDestroyHeight = Fling.savedHeight end)
        Fling.savedHeight = nil
    end

    local root = Fling.myRoot()
    if root then
        -- only put linear back if this script was the thing that took it; the
        -- rest of the time that value is your own movement and is not ours
        Fling.setVelocity(root, Fling.tookLinear and Vector3.zero or nil, Vector3.zero)
        Fling.leash(root)
    end

    Fling.tookLinear = false
    Fling.savedPos = nil
    Fling.savedChar = nil
end

--// anti fling ---------------------------------------------------------------
--
-- Every fling, whichever script threw it, has to reach your character through
-- one of two doors: a velocity written straight onto your root, or a mover
-- instance parented into your character to push it. This watches both, and
-- puts you back where you were standing the last time your motion looked
-- ordinary. It stands down while this script is flinging, so the two never
-- fight over the same root part.

AntiFling = {
    Enabled = false,
    Guard = Choice.Fling.Guard.default,
    blocked = 0,
    home = nil,
    homeChar = nil,
}

-- the instance classes a fling can be delivered through
AntiFling.MOVERS = {
    BodyVelocity = true, BodyAngularVelocity = true, BodyForce = true,
    BodyThrust = true, BodyPosition = true, BodyGyro = true,
    LinearVelocity = true, AngularVelocity = true, VectorForce = true,
    AlignPosition = true, AlignOrientation = true, Torque = true,
}

function AntiFling.tick()
    if Unloading or not AntiFling.Enabled then return end
    -- ours is not an attack, so leave it alone
    if Fling.busy or Fling.armed then return end

    local root, hum = Fling.myRoot()
    local char = LocalPlayer.Character
    if not root or not char then return end

    local caught = false

    for _, inst in ipairs(char:GetDescendants()) do
        -- never eat our own self-protection guard, which is the one mover in
        -- here that is holding you still rather than throwing you
        if AntiFling.MOVERS[inst.ClassName] and inst.Name ~= Fling.GUARD_NAME then
            pcall(function() inst:Destroy() end)
            caught = true
        end
    end

    local guard = Choice.valueOf(Choice.Fling.Guard, AntiFling.Guard)
    local linear = root.AssemblyLinearVelocity
    local angular = root.AssemblyAngularVelocity

    if linear.Magnitude > guard.linear or angular.Magnitude > guard.angular then
        caught = true
    end

    if caught then
        Fling.setVelocity(root, Vector3.zero, Vector3.zero)
        if AntiFling.home and AntiFling.homeChar == char then
            pcall(function() root.CFrame = AntiFling.home end)
        end
        if hum then
            pcall(function()
                hum.PlatformStand = false
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)
        end
        AntiFling.blocked = AntiFling.blocked + 1
    else
        -- only remember a position reached under your own power
        AntiFling.home = root.CFrame
        AntiFling.homeChar = char
    end
end

track(RunService.Heartbeat:Connect(AntiFling.tick))

-- Claiming a velocity that enormous would throw you as hard as it throws them.
-- A BodyVelocity pinned at zero with effectively unlimited force cancels your
-- own motion continuously, while the claim still registers for the contact -
-- that asymmetry is the whole reason they go and you do not. The seated state
-- would zero the claim outright, and FallenPartsDestroyHeight is pushed to NaN
-- because every comparison against NaN is false, so nothing of yours gets
-- deleted for being briefly somewhere absurd.
function Fling.protect(root, hum)
    local guard = Instance.new("BodyVelocity")
    guard.Name = Fling.GUARD_NAME
    guard.Velocity = Vector3.zero
    guard.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    guard.Parent = root

    if hum then
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false) end)
    end

    Fling.savedHeight = Workspace.FallenPartsDestroyHeight
    pcall(function() Workspace.FallenPartsDestroyHeight = 0 / 0 end)

    return guard
end

function Fling.unprotect(guard, hum)
    if guard then pcall(function() guard:Destroy() end) end
    if hum then
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end)
    end
    if Fling.savedHeight then
        pcall(function() Workspace.FallenPartsDestroyHeight = Fling.savedHeight end)
        Fling.savedHeight = nil
    end
end

-- One CFrame write does not bring you home. The step right after it can move
-- you again, the other limbs are still carrying their own velocity, and a
-- ragdolled humanoid will not stand up on its own. So this keeps putting you
-- back, zeroing every part rather than only the root, until you are actually
-- there - which is the difference between landing where you started and
-- carrying on into the void.
function Fling.goHome(home, homeChar)
    if not home or not homeChar then return end

    local deadline = os.clock() + 3
    repeat
        if Unloading then break end
        if LocalPlayer.Character ~= homeChar then break end

        pcall(function()
            for _, part in ipairs(homeChar:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Velocity = Vector3.zero
                    part.RotVelocity = Vector3.zero
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
        if not root then break end
        if (root.Position - home.Position).Magnitude < 6 then break end
    until os.clock() > deadline
end

-- Circling someone at close range, spinning, until they go. This is the active
-- half: the passive claim above only fires while you happen to be touching
-- somebody, whereas this holds contact deliberately for as long as it takes.
-- It still never teleports onto them - it orbits at arm's length and puts you
-- back where you started the moment they are gone.
function Fling.orbit(char, why)
    if Fling.busy or Unloading then return false end

    local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not theirRoot then return false end

    local root = Fling.myRoot()
    if not root then return false end

    Fling.busy = true
    Fling.hits = Fling.hits + 1

    task.spawn(function()
        local home = root.CFrame
        local homeChar = LocalPlayer.Character
        local guard, hum

        local ok = pcall(function()
            hum = homeChar and homeChar:FindFirstChildOfClass("Humanoid")
            guard = Fling.protect(root, hum)

            local startPos = theirRoot.Position
            local style = Choice.pick(Choice.Fling.Style, Fling.Style)
            local radius = Choice.valueOf(Choice.Fling.Orbit, Fling.Orbit)
            local patience = Choice.valueOf(Choice.Fling.Patience, Fling.Patience)
            local power = Choice.valueOf(Choice.Fling.Power, Fling.Power)

            local linear = Vector3.new(power.linear, power.linear * power.lift, power.linear)
            local spin = Vector3.new(power.angular, power.angular, power.angular)

            local deadline = os.clock() + patience
            local angle, flip, landed = 0, 1, false

            while os.clock() < deadline do
                if Unloading or not Fling.Enabled then break end
                if LocalPlayer.Character ~= homeChar then break end
                if not theirRoot.Parent or not root.Parent then break end

                local theirHum = char:FindFirstChildOfClass("Humanoid")
                angle = angle + 0.35

                if style == 'Orbit' then
                    root.CFrame = CFrame.new(theirRoot.Position
                        + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
                    Fling.setVelocity(root, nil, spin)
                else
                    -- sit inside them, a stud and a half above then below, and
                    -- drift with wherever they are running so a moving target
                    -- does not simply walk out of the overlap
                    local drift = Vector3.zero
                    if theirHum then
                        drift = theirHum.MoveDirection * math.min(theirHum.WalkSpeed, 24) * 0.08
                    end

                    flip = -flip
                    root.CFrame = CFrame.new(theirRoot.Position + drift + Vector3.new(0, 1.5 * flip, 0))
                        * CFrame.Angles(math.rad(angle * 40), 0, 0)
                    Fling.setVelocity(root, linear, spin)
                end

                if theirRoot.AssemblyLinearVelocity.Magnitude > Fling.FLUNG_SPEED
                    or (theirRoot.Position - startPos).Magnitude > Fling.FLUNG_DISTANCE
                then
                    landed = true
                    break
                end

                task.wait()
            end

            if landed then Fling.flung = Fling.flung + 1 end
        end)

        -- teardown runs whatever happened above, including a thrown error, so
        -- a failure part way through can never strand you mid claim
        pcall(function()
            local live = homeChar and homeChar:FindFirstChild("HumanoidRootPart")
            if live then Fling.setVelocity(live, Vector3.zero, Vector3.zero) end
            Fling.unprotect(guard, hum)
            Fling.goHome(home, homeChar)
        end)

        Fling.busy = false
        if not ok then Fling.reset() end
    end)

    return true
end

-- Anyone whose part brushes one of ours gets orbited, once, then goes on a
-- short cooldown - Touched fires many times a second against a single body and
-- re-entering for every one of them would just restart the routine forever.
function Fling.onTouched(hit)
    if not Fling.Enabled or not Fling.OnTouch or Fling.busy or Unloading then return end
    if typeof(hit) ~= "Instance" then return end

    local char = hit.Parent
    local plr = char and Players:GetPlayerFromCharacter(char)
    if not plr or plr == LocalPlayer or not Fling.allowed(plr) then return end

    local now = os.clock()
    if (Fling.cooldown[plr] or 0) > now then return end
    Fling.cooldown[plr] = now + Fling.RETOUCH

    Fling.orbit(char, 'touched')
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

-- the two buttons. sheriff also matches hero, since a hero is whoever picked
-- the gun up after the sheriff died and is the same threat
function Fling.byRole(wanted)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) then
            local role = roleOf(plr)
            local match = role == wanted or (wanted == 'Sheriff' and role == 'Hero')
            if match and Fling.orbit(plr.Character, wanted) then
                return plr.Name
            end
        end
    end
    return nil
end

task.spawn(function()
    if LocalPlayer.Character then Fling.watchCharacter(LocalPlayer.Character) end
end)
track(LocalPlayer.CharacterAdded:Connect(function(char)
    Fling.busy = false
    table.clear(Fling.cooldown)
    task.spawn(Fling.watchCharacter, char)
end))

track(Players.PlayerRemoving:Connect(function(plr)
    Fling.cooldown[plr] = nil
end))

-- before the step: claim the momentum
track(PreSimulation:Connect(function()
    if Unloading or not Fling.Enabled or not Fling.Passive or Fling.busy then return end

    local ok = pcall(function()
        local root = Fling.myRoot()
        if not root then
            Fling.armed = false
            return
        end

        local reach = Choice.valueOf(Choice.Fling.Reach, Fling.Reach)
        if not Fling.inRange(root, reach) then
            Fling.armed = false
            return
        end

        if not Fling.armed then Fling.hits = Fling.hits + 1 end
        Fling.armed = true
        Fling.savedPos = root.Position
        Fling.savedChar = LocalPlayer.Character

        local power = Choice.valueOf(Choice.Fling.Power, Fling.Power)
        local claim = Choice.valueOf(Choice.Fling.Claim, Fling.Claim)

        local linear = nil
        if claim.linear then
            linear = Vector3.new(power.linear, power.linear * power.lift, power.linear)
        elseif claim.lift then
            -- lift without a full linear claim: keep whatever you are doing
            -- horizontally and only add upward, so you still walk normally
            local current = root.AssemblyLinearVelocity
            linear = Vector3.new(current.X, power.linear * power.lift, current.Z)
        end
        Fling.tookLinear = linear ~= nil

        Fling.setVelocity(root, linear,
            claim.angular and Vector3.new(power.angular, power.angular, power.angular) or nil)
    end)

    if not ok then Fling.reset() end
end))

-- after it: take the claim back. this runs every frame the claim was made,
-- never conditionally - leaving a claim live across frames is what threw you
-- into the void and killed you
track(RunService.Heartbeat:Connect(function()
    if Unloading or not Fling.armed then return end

    if not Fling.Enabled or Fling.busy then
        Fling.reset()
        return
    end

    local ok = pcall(function()
        local root, hum = Fling.myRoot()
        if not root then return end

        -- angular is always ours, so it always goes back to zero. linear is
        -- only ours if we took it, and otherwise it is your own walking
        Fling.setVelocity(root, Fling.tookLinear and Vector3.zero or nil, Vector3.zero)
        Fling.leash(root)

        -- a big angular claim throws the humanoid into a falling state, which is
        -- what renders as the spin; putting it straight back into Running each
        -- frame is what keeps it looking like walking
        if Fling.Upright and hum then
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
        end
    end)

    Fling.tookLinear = false
    if not ok then Fling.reset() end
end))

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

    MathSection:Dropdown({
        Title = 'replication buffer',
        Description = 'how far behind the server other players are drawn. up one if shots land behind runners, down one if in front',
        Values = Choice.Buffer.order,
        Default = Choice.Buffer.default,
        Flag = 'mm2_silent_aim_buffer',
        Callback = function(value) Aim.Buffer = Choice.valueOf(Choice.Buffer, value) end,
    })

    solverStat = addStat(MathSection, { Title = 'solver in use', Value = '-' })
    Adapt.leadStats[#Adapt.leadStats + 1] = addStat(MathSection, { Title = 'lead', Value = '-' })

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
    motion[plr.Name] = nil
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


do
    local AdvancedTab = Window:CreateTab({ Title = 'advanced' })

    local OverrideSection = AdvancedTab:CreateSection('override')

    Advanced.ui.Enabled = OverrideSection:Toggle({
        Title = 'advanced mode',
        Description = 'takes over how the shot is solved and ignores the silent aim tab',
        Flag = 'mm2_adv',
        Default = false,
        Callback = function(state) Advanced.Enabled = state end,
    })

    OverrideSection:Paragraph({
        Title = 'what this ignores',
        Content = 'while advanced mode is on, the silent aim tab stops deciding anything about the solve. aim part, prediction maths, motion filter, air handling, ping, replication buffer, both lead dropdowns and the shot filter all come from this tab instead, and every shot gets redirected regardless of what the shot filter says. what still comes from the silent aim tab is the target side of things, which advanced has no better answer for: ' .. Advanced.Passthrough,
    })

    OverrideSection:Toggle({
        Title = 'perfection',
        Description = 'turns advanced mode on and sets the lead and the solver to their most accurate combination',
        Flag = 'mm2_adv_perfection',
        Default = false,
        Callback = function(state)
            Advanced.Perfection = state
            if not state then return end
            -- drive the dropdowns rather than bypassing them, so the switch is
            -- visible and every part of it stays adjustable afterwards
            for key, value in pairs({
                Enabled = true,
                Solver = 'Ensemble',
                Weighting = 'Inverse fourth',
                Bias = 'Aggressive',
                Converge = 'Exhaustive',
                Horizon = 'Weapon match',
                Ping = 'Full',
                Buffer = 'Normal',
                Lead = 'Auto',
            }) do
                local element = Advanced.ui[key]
                if element then pcall(function() element:Set(value) end) end
            end
        end,
    })

    OverrideSection:Paragraph({
        Title = 'what perfection actually does',
        Content = 'two halves: how far ahead, and where. how far ahead is the lead time, built from what the shot really has to cover - your whole round trip read from the game network stats, the replication buffer other players are drawn behind by, a frame of your own and, for the knife, its measured flight time - with the auto lead only fine tuning that from shots that really landed. the old version counted about half your ping and nothing for the buffer, and its auto multiplier was scoring every frame a target sat on screen as a missed shot and sweeping itself between 0.4x and 4x, so it spent half its time leading far too little. where is the path: all four solvers blended by how wrong each has been, the blend own signed miss subtracted back out, and the lead re-solved until the point stops moving. the lead line in the readout shows every part of the lead the last solve used',
    })

    local SolverSection = AdvancedTab:CreateSection('solver')

    Advanced.ui.Solver = SolverSection:Dropdown({
        Title = 'solver',
        Description = 'ensemble blends every model still in contention; best single is the old argmax',
        Values = Choice.Adv.Solver.order,
        Default = Choice.Adv.Solver.default,
        Flag = 'mm2_adv_solver',
        Callback = function(value) Advanced.Solver = Choice.pick(Choice.Adv.Solver, value) end,
    })

    Advanced.ui.Weighting = SolverSection:Dropdown({
        Title = 'weighting',
        Description = 'how a running error score becomes a share of the blend',
        Values = Choice.Adv.Weighting.order,
        Default = Choice.Adv.Weighting.default,
        Flag = 'mm2_adv_weighting',
        Callback = function(value) Advanced.Weighting = Choice.pick(Choice.Adv.Weighting, value) end,
    })

    Advanced.ui.Bias = SolverSection:Dropdown({
        Title = 'bias correction',
        Description = 'how much of the running signed miss gets subtracted back out',
        Values = Choice.Adv.Bias.order,
        Default = Choice.Adv.Bias.default,
        Flag = 'mm2_adv_bias',
        Callback = function(value) Advanced.Bias = Choice.pick(Choice.Adv.Bias, value) end,
    })

    Advanced.ui.Converge = SolverSection:Dropdown({
        Title = 'convergence',
        Description = 'how close two passes must land before the lead solve calls it settled',
        Values = Choice.Adv.Converge.order,
        Default = Choice.Adv.Converge.default,
        Flag = 'mm2_adv_converge',
        Callback = function(value) Advanced.Converge = Choice.pick(Choice.Adv.Converge, value) end,
    })

    Advanced.ui.Guard = SolverSection:Dropdown({
        Title = 'outlier guard',
        Description = 'a model scoring worse than this multiple of the best is dropped from the blend',
        Values = Choice.Adv.Guard.order,
        Default = Choice.Adv.Guard.default,
        Flag = 'mm2_adv_guard',
        Callback = function(value) Advanced.Guard = Choice.pick(Choice.Adv.Guard, value) end,
    })

    local SamplingSection = AdvancedTab:CreateSection('sampling')

    SamplingSection:Dropdown({
        Title = 'history depth',
        Description = 'how much of their past motion the replay gets to work with',
        Values = Choice.Adv.Depth.order,
        Default = Choice.Adv.Depth.default,
        Flag = 'mm2_adv_depth',
        Callback = function(value) Advanced.Depth = Choice.pick(Choice.Adv.Depth, value) end,
    })

    Advanced.ui.Horizon = SamplingSection:Dropdown({
        Title = 'scoring horizon',
        Description = 'the lead length the models are scored at. weapon match follows the real travel time',
        Values = Choice.Adv.Horizon.order,
        Default = Choice.Adv.Horizon.default,
        Flag = 'mm2_adv_horizon',
        Callback = function(value) Advanced.Horizon = Choice.pick(Choice.Adv.Horizon, value) end,
    })

    SamplingSection:Dropdown({
        Title = 'reaction',
        Description = 'how fast one scoring round moves a model running error',
        Values = Choice.Adv.Reaction.order,
        Default = Choice.Adv.Reaction.default,
        Flag = 'mm2_adv_reaction',
        Callback = function(value) Advanced.Reaction = Choice.pick(Choice.Adv.Reaction, value) end,
    })

    SamplingSection:Dropdown({
        Title = 'motion filter',
        Description = 'replaces the silent aim tab filter while advanced mode is on',
        Values = Choice.Filter.order,
        Default = Choice.Filter.default,
        Flag = 'mm2_adv_filter',
        Callback = function(value) Advanced.Smoothing = Choice.pick(Choice.Filter, value) end,
    })

    local ShotSection = AdvancedTab:CreateSection('shot')

    ShotSection:Dropdown({
        Title = 'aim part',
        Values = Choice.Part.order,
        Default = Choice.Part.default,
        Flag = 'mm2_adv_part',
        Callback = function(value) Advanced.Part = Choice.pick(Choice.Part, value) end,
    })

    ShotSection:Dropdown({
        Title = 'air handling',
        Values = Choice.Air.order,
        Default = Choice.Air.default,
        Flag = 'mm2_adv_air',
        Callback = function(value) Advanced.Air = Choice.pick(Choice.Air, value) end,
    })

    Advanced.ui.Ping = ShotSection:Dropdown({
        Title = 'ping',
        Description = 'how much of your round trip counts toward the lead',
        Values = Choice.Ping.order,
        Default = Choice.Ping.default,
        Flag = 'mm2_adv_ping',
        Callback = function(value) Advanced.Ping = Choice.pick(Choice.Ping, value) end,
    })

    Advanced.ui.Buffer = ShotSection:Dropdown({
        Title = 'replication buffer',
        Description = 'how far behind the server other players are drawn. up one if shots land behind runners, down one if in front',
        Values = Choice.Buffer.order,
        Default = Choice.Buffer.default,
        Flag = 'mm2_adv_buffer',
        Callback = function(value) Advanced.Buffer = Choice.pick(Choice.Buffer, value) end,
    })

    Advanced.ui.Lead = ShotSection:Dropdown({
        Title = 'lead',
        Description = 'drives both weapons from one dropdown instead of the two on the silent aim tab',
        Values = Choice.Lead.order,
        Default = Choice.Lead.default,
        Flag = 'mm2_adv_lead',
        Callback = function(value) Advanced.Lead = Choice.pick(Choice.Lead, value) end,
    })

    local ReadoutSection = AdvancedTab:CreateSection('readout')

    Advanced.ui.state = addStat(ReadoutSection, { Title = 'advanced mode', Value = 'off' })
    Adapt.leadStats[#Adapt.leadStats + 1] = addStat(ReadoutSection, { Title = 'lead', Value = '-' })
    Advanced.ui.weights = addStat(ReadoutSection, { Title = 'model weights', Value = '-' })
    Advanced.ui.biasStat = addStat(ReadoutSection, { Title = 'bias correction', Value = '-' })

    ReadoutSection:Label({
        Title = 'Lead is the last solve broken into its parts: round trip, buffer, frame, flight, the lead profile and the auto multiplier. Weights are the live blend for whoever is currently being solved, best first. Bias correction is how far the blend has been missing by and in which direction, which is the number it is subtracting back out.',
    })
end

do
    local TriggerTab = Window:CreateTab({ Title = 'trigger bot' })
    local section = TriggerTab:CreateSection('gun')

    section:Toggle({
        Title = 'trigger bot',
        Description = 'shoots once a target has been in view for your reaction time. only while the gun is already in your hands',
        Flag = 'mm2_tb_gun',
        Default = false,
        Callback = function(state) Trigger.Gun = state end,
    })

    section:Dropdown({
        Title = 'shoot at',
        Description = 'murderer only never fires at an innocent, which would get you killed as sheriff',
        Values = Choice.Trigger.GunTargets.order,
        Default = Choice.Trigger.GunTargets.default,
        Flag = 'mm2_tb_gun_targets',
        Callback = function(value) Trigger.GunTargets = Choice.pick(Choice.Trigger.GunTargets, value) end,
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
        Description = 'waited once after the weapon comes out, and again once a target is first seen after that',
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

    section = TriggerTab:CreateSection('readout')

    Trigger.ui = {
        gun = addStat(section, { Title = 'gun', Value = 'off' }),
        knife = addStat(section, { Title = 'knife', Value = 'off' }),
        method = addStat(section, { Title = 'gun fires by', Value = '-' }),
        fired = addStat(section, { Title = 'shots / throws', Value = '0 / 0' }),
    }

    section:Label({
        Title = 'Targets come from silent aim: gun and knife targets, priority, range and fov on the silent aim tab all apply here too. With silent aim off, a gun fired through its own script shoots where you point, so it only fires with your mouse on them.',
    })
end


do
    local FlingTab = Window:CreateTab({ Title = 'fling' })

    local FlingSection = FlingTab:CreateSection('walk fling')

    FlingSection:Toggle({
        Title = 'fling if touched',
        Description = 'anyone who touches you gets circled at close range until they go, then you are put back',
        Flag = 'mm2_fling',
        Default = false,
        Callback = function(state)
            Fling.Enabled = state
            if not state then Fling.reset() end
        end,
    })

    FlingSection:Toggle({
        Title = 'on contact',
        Description = 'what triggers it. off leaves the buttons below as the only way to start one',
        Flag = 'mm2_fling_touch',
        Default = true,
        Callback = function(state) Fling.OnTouch = state end,
    })

    FlingSection:Toggle({
        Title = 'passive claim',
        Description = 'the older behaviour - claims momentum every frame anyone is in reach, without circling',
        Flag = 'mm2_fling_passive',
        Default = false,
        Callback = function(state)
            Fling.Passive = state
            if not state then Fling.reset() end
        end,
    })

    FlingSection:Button({
        Title = 'fling murderer',
        Description = 'starts a run on whoever is holding the knife right now',
        Callback = function()
            local name = Fling.byRole('Murderer')
            Onyx:Notify({
                Title = 'fling',
                Content = name and ('going for ' .. name) or 'no living murderer found',
                Type = name and 'success' or 'warning',
                Duration = 3,
            })
        end,
    })

    FlingSection:Button({
        Title = 'fling sheriff',
        Description = 'matches the hero too, since a hero is whoever picked the gun up',
        Callback = function()
            local name = Fling.byRole('Sheriff')
            Onyx:Notify({
                Title = 'fling',
                Content = name and ('going for ' .. name) or 'no living sheriff or hero found',
                Type = name and 'success' or 'warning',
                Duration = 3,
            })
        end,
    })

    FlingSection:Dropdown({
        Title = 'power',
        Description = 'how much momentum gets claimed. gentle is a shove, absurd is orbit',
        Values = Choice.Fling.Power.order,
        Default = Choice.Fling.Power.default,
        Flag = 'mm2_fling_power',
        Callback = function(value) Fling.Power = Choice.pick(Choice.Fling.Power, value) end,
    })

    FlingSection:Dropdown({
        Title = 'reach',
        Description = 'how close they have to be before it arms. touch is the least obvious',
        Values = Choice.Fling.Reach.order,
        Default = Choice.Fling.Reach.default,
        Flag = 'mm2_fling_reach',
        Callback = function(value) Fling.Reach = Choice.pick(Choice.Fling.Reach, value) end,
    })

    FlingSection:Dropdown({
        Title = 'targets',
        Values = Choice.Fling.Targets.order,
        Default = Choice.Fling.Targets.default,
        Flag = 'mm2_fling_targets',
        Callback = function(value) Fling.Targets = Choice.pick(Choice.Fling.Targets, value) end,
    })

    local OrbitSection = FlingTab:CreateSection('orbit')

    OrbitSection:Dropdown({
        Title = 'style',
        Description = 'overlap sits inside them and alternates above and below; orbit circles at arm\'s length and is much weaker',
        Values = Choice.Fling.Style.order,
        Default = Choice.Fling.Style.default,
        Flag = 'mm2_fling_style',
        Callback = function(value) Fling.Style = Choice.pick(Choice.Fling.Style, value) end,
    })

    OrbitSection:Dropdown({
        Title = 'orbit radius',
        Description = 'orbit style only. overlap ignores it and sits inside them instead',
        Values = Choice.Fling.Orbit.order,
        Default = Choice.Fling.Orbit.default,
        Flag = 'mm2_fling_orbit',
        Callback = function(value) Fling.Orbit = Choice.pick(Choice.Fling.Orbit, value) end,
    })

    OrbitSection:Dropdown({
        Title = 'patience',
        Description = 'how long to keep circling before giving up, so an unflingable target does not strand you',
        Values = Choice.Fling.Patience.order,
        Default = Choice.Fling.Patience.default,
        Flag = 'mm2_fling_patience',
        Callback = function(value) Fling.Patience = Choice.pick(Choice.Fling.Patience, value) end,
    })

    Fling.ui2 = addStat(OrbitSection, { Title = 'flung', Value = '0' })

    local GuardSection = FlingTab:CreateSection('anti fling')

    GuardSection:Toggle({
        Title = 'anti fling',
        Description = 'catches anything trying to throw you and puts you back where you were standing',
        Flag = 'mm2_antifling',
        Default = false,
        Callback = function(state)
            AntiFling.Enabled = state
            AntiFling.home = nil
            AntiFling.homeChar = nil
        end,
    })

    GuardSection:Dropdown({
        Title = 'sensitivity',
        Description = 'what counts as abnormal motion. walking is 16 and a jump peaks near 50, so even strict leaves normal movement alone',
        Values = Choice.Fling.Guard.order,
        Default = Choice.Fling.Guard.default,
        Flag = 'mm2_antifling_guard',
        Callback = function(value) AntiFling.Guard = Choice.pick(Choice.Fling.Guard, value) end,
    })

    AntiFling.ui = addStat(GuardSection, { Title = 'blocked', Value = '0' })

    GuardSection:Label({
        Title = 'Watches both doors a fling can come through: a velocity written straight onto your root, and a mover instance parented into your character. It stands down while this script is flinging, so the two never fight over the same part.',
    })

    local TuningSection = FlingTab:CreateSection('tuning')

    TuningSection:Dropdown({
        Title = 'claim',
        Description = 'angular only is the one that transfers, and the only one that leaves you able to walk',
        Values = Choice.Fling.Claim.order,
        Default = Choice.Fling.Claim.default,
        Flag = 'mm2_fling_claim',
        Callback = function(value) Fling.Claim = Choice.pick(Choice.Fling.Claim, value) end,
    })

    TuningSection:Dropdown({
        Title = 'leash',
        Description = 'how far you may move in one step before you are put back. this is what stops you being thrown',
        Values = Choice.Fling.Leash.order,
        Default = Choice.Fling.Leash.default,
        Flag = 'mm2_fling_leash',
        Callback = function(value) Fling.Leash = Choice.pick(Choice.Fling.Leash, value) end,
    })

    TuningSection:Toggle({
        Title = 'stay upright',
        Description = 'puts the humanoid straight back into running each frame, so it reads as walking',
        Flag = 'mm2_fling_upright',
        Default = true,
        Callback = function(state) Fling.Upright = state end,
    })

    Fling.ui = addStat(TuningSection, { Title = 'contacts armed', Value = '0' })

    TuningSection:Button({
        Title = 'reset counter',
        Callback = function() Fling.hits = 0 end,
    })

    local NotesSection = FlingTab:CreateSection('notes')

    NotesSection:Paragraph({
        Title = 'how it works',
        Content = 'your client owns your own character physics, so whatever velocity it reports is taken as true. the claim is made before the physics step, where it takes part in resolving whatever contact you are already standing in, and taken straight back after. a spin claim is what actually transfers: it puts an enormous velocity on the surface of your assembly, which is what the contact resolves against. a linear claim mostly just moves your own centre of mass, which is to say it launches you rather than them',
    })

    NotesSection:Paragraph({
        Title = 'why angular only is the default',
        Content = 'two reasons, and both came out of testing. it is the only claim that reliably transfers, and it is the only one that leaves you able to walk - your walking is linear velocity, so any mode that claims linear is writing over your own movement every frame and pinning you in place. angular never touches linear at all, which is why you keep full control of your character while it runs',
    })

    NotesSection:Paragraph({
        Title = 'the leash',
        Content = 'a spin claim can still throw you, because ground friction turns spin into travel. the leash is the backstop: move further in one step than any amount of walking could explain and you get put back, keeping the direction you are currently facing. walking covers about a quarter of a stud per frame, so normal movement passes through untouched and only a claim that threw you ever gets caught. turn it off and you are relying on nothing going wrong',
    })

    NotesSection:Paragraph({
        Title = 'what this cannot do',
        Content = 'if the game puts players in a collision group that stops them touching each other there is no contact to exploit and no amount of power helps. your own screen stays clean either way, but other clients see the state you replicate, so a large claim can still read as jitter on their end. if you are being noticed, drop the power before anything else',
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
        Fling.Enabled = false
        Fling.OnTouch = false
        Fling.Passive = false
        AntiFling.Enabled = false
        AutoGun.Enabled = false
        Trigger.Gun = false
        Trigger.Throw = false
        pcall(Fling.reset)

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

            -- whichever lead dropdown is in charge decides whether auto is on
            local gunAuto, knifeAuto = GunTune.Auto, KnifeTune.Auto
            if Advanced.Enabled then
                gunAuto = Choice.valueOf(Choice.Lead, Advanced.Lead).auto
                knifeAuto = gunAuto
            end
            gunMultStat.Set(gunAuto and ('%.2fx'):format(GunLead.mult) or 'off')
            knifeMultStat.Set(knifeAuto and ('%.2fx'):format(KnifeLead.mult) or 'off')

            solverStat.Set(Advanced.Enabled and ('advanced: ' .. Advanced.Solver)
                or (Aim.Math == 'Adaptive' and lastModelUsed or Aim.Math))

            local lead = Adapt.lead
            local leadText = lead.total > 0
                and ('%d ms = (trip %d + buffer %d + frame %d) x%.2f + flight %d + trim %d'):format(
                    math.floor(lead.total * 1000 + 0.5),
                    math.floor(lead.rtt * 1000 + 0.5),
                    math.floor(lead.buffer * 1000 + 0.5),
                    math.floor(lead.frame * 1000 + 0.5),
                    lead.mult,
                    math.floor(lead.flight * 1000 + 0.5),
                    math.floor(lead.extra * 1000 + 0.5))
                or ('- (round trip %d ms)'):format(math.floor(cachedPing * 1000 + 0.5))
            for _, stat in ipairs(Adapt.leadStats) do stat.Set(leadText) end

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
                Fling.ui.Set(tostring(Fling.hits),
                    Fling.Enabled and (Fling.armed or Fling.busy)
                        and Color3.fromRGB(126, 217, 87) or nil)
            end
            if Fling.ui2 then
                Fling.ui2.Set(tostring(Fling.flung),
                    Fling.flung > 0 and Color3.fromRGB(126, 217, 87) or nil)
            end
            if AntiFling.ui then
                AntiFling.ui.Set(tostring(AntiFling.blocked),
                    AntiFling.blocked > 0 and Color3.fromRGB(255, 196, 87) or nil)
            end
            if AutoGun.ui2 then
                local n = 0
                for _ in pairs(AutoGun.drops) do n = n + 1 end
                AutoGun.ui2.Set(tostring(n), n > 0 and Color3.fromRGB(126, 217, 87) or nil)
            end

            if not Advanced.Enabled then
                Advanced.ui.state.Set('off')
                Advanced.ui.weights.Set('-')
                Advanced.ui.biasStat.Set('-')
            else
                Advanced.ui.state.Set(Advanced.Perfection and 'perfection' or 'on',
                    Color3.fromRGB(126, 217, 87))

                local entry = gunPlan and gunPlan.entry or knifePlan and knifePlan.entry
                if not entry or entry.scored < Adapt.Samples then
                    Advanced.ui.weights.Set('learning')
                    Advanced.ui.biasStat.Set('learning')
                else
                    -- the exact weights the blend itself uses, as percentages
                    local weights, rows = {}, {}
                    local total = Adapt.weights(entry, weights)
                    for _, name in ipairs(Adapt.Models) do
                        rows[#rows + 1] = { name = name, weight = weights[name] or 0 }
                    end

                    table.sort(rows, function(a, b) return a.weight > b.weight end)

                    local shown = {}
                    for _, row in ipairs(rows) do
                        if row.weight > 0 and total > 0 then
                            shown[#shown + 1] = ('%s %d%%'):format(
                                row.name:sub(1, 4), math.floor(row.weight / total * 100 + 0.5))
                        end
                    end
                    Advanced.ui.weights.Set(#shown > 0 and table.concat(shown, '  ') or '-')

                    if Advanced.Bias == "Off" or entry.biasAlong == nil then
                        Advanced.ui.biasStat.Set('off')
                    else
                        local share = Choice.valueOf(Choice.Adv.Bias, Advanced.Bias) or 0
                        Advanced.ui.biasStat.Set(('%+.2f along %+.2f across at %d%%'):format(
                            entry.biasAlong, entry.biasAcross, math.floor(share * 100 + 0.5)))
                    end
                end
            end
        end)
    end
end)


--// external access ----------------------------------------------------------
--
-- One table holding the live config, so anything here can be driven from a
-- console without editing the script. These are the same tables the script
-- reads, not copies, so a write takes effect on the next frame exactly as
-- moving the dropdown would: MM2.Fling.Power = 'Absurd' is the dropdown.
--
-- Visual, Xray, Debug, TrapEsp, DroppedGunEsp are plain globals as well, since
-- they are read rarely enough that a hash lookup costs nothing. Aim, Advanced,
-- Choice and Adapt stay local and are only reachable through here, because
-- those sit in the per-frame solver - Choice alone is read over a hundred
-- times a frame, and a global is a hash lookup every single time.
do
    local env = _G
    local ok, shared = pcall(function() return getgenv() end)
    if ok and type(shared) == "table" then env = shared end

    env.MM2 = {
        Aim = Aim,
        Advanced = Advanced,
        Trigger = Trigger,
        Fling = Fling,
        Visual = Visual,
        Xray = Xray,
        Debug = Debug,

        Choice = Choice,
        Adapt = Adapt,

        Stats = shotStats,
        GunLead = GunLead,
        KnifeLead = KnifeLead,

        -- every dropdown value is validated on the way in, so a typo through
        -- here falls back to that option's default rather than wedging the
        -- solver on a name nothing handles
        Pick = Choice.pick,
        ValueOf = Choice.valueOf,
    }
end

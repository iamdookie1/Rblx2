--// 100 Days on Chunk! -- auto farm, fast swing, kill aura, survival helpers,
--// loot, anti hit, anti fall, movement, teleports and esp.
--
-- What the game's own client scripts show:
--  * Gathering is GatherHit:FireServer() and a tool swing is MouseClick:FireServer(),
--    both with no arguments at all. The server works out what you hit; the one
--    rule the client knows is GameConfig.GATHER_DISTANCE (12 studs). The game
--    itself fires them on a loop at the tool's cooldown while you hold click,
--    and only while the server has the tool Enabled: the server times swings,
--    so sending more of them than the cooldown allows does nothing.
--  * Every resource is a model tagged GatherResource carrying ResourceType
--    (Tree / Rock, or Cage for the beast's cage), AssetName, Health and
--    Depleted. Most sit under GeneratedChunks.<chunk>.Resources, but snow
--    chunks grow Frozen Cubes (AssetName Freeze) as structures and the pharaoh
--    drops Ancient Tombs, so only the tag finds them all. Axes cut trees,
--    pickaxes break rocks; which rocks a pickaxe is good enough for is the
--    server's secret, so the farm learns it from swings that do nothing.
--  * Enemies (Workspace.Enemies) and animals (Workspace.Animals) keep their
--    health on a Humanoid named Humanoid2, but an enemy is dead as soon as its
--    EnemyActionAnimation says "Dead", whatever that health says, and one with
--    SpawnReady false is still climbing out of the ground.
--  * Enemy swings show up as EnemyActionAnimation "Attack" / "Attack2" (or the
--    EnemyAnimation remote for proxied enemies), and everything thrown or
--    dropped is announced through EnemyPresentation before it lands: where,
--    and at what server time.
--  * Food is the player's Food attribute; eating is Eat:FireServer(foodTool)
--    with a tool that has a Food attribute in your hands. Bandages are tools
--    with a HealAmount that heal while UseItem:FireServer(tool) is held.
--  * Builds sit in Workspace.Builds with a BuildHumanoid, and
--    RepairBuild:InvokeServer(build) mends one while a Repair Hammer is held.
--  * The death screen revives through ClaimFreeRevive: free once, then saved
--    credits with "Saved".
--  * Loot from crates and resources goes straight into your inventory; the
--    items that fly at you are only an effect. Crates are hold prompts marked
--    Crate, often inside barns, towers and wells. Items players drop lie in
--    Workspace.WorldItemDrops.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

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

local function notify(title, content, kind, duration)
    Onyx:Notify({ Title = title, Content = content, Type = kind or 'info', Duration = duration or 4 })
end

local function guiRoot()
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local GuiRoot = guiRoot()

--// game data ---------------------------------------------------------------

local RemoteFolder = ReplicatedStorage:WaitForChild("ChunkGameRemotes", 15)

local function remote(name)
    return RemoteFolder and RemoteFolder:FindFirstChild(name) or nil
end

local Remotes = {
    GatherHit = remote("GatherHit"),
    MouseClick = remote("MouseClick"),
    Eat = remote("Eat"),
    UseItem = remote("UseItem"),
    RepairBuild = remote("RepairBuild"),
    ClaimFreeRevive = remote("ClaimFreeRevive"),
    EnemyPresentation = remote("EnemyPresentation"),
    EnemyAnimation = remote("EnemyAnimation"),
}

-- The numbers the game plays by, read from its own GameConfig. The fallbacks
-- are what it said when this was written.
local Config = {
    GATHER_DISTANCE = 12,
    FOOD_MAX = 100,
    GATHER_TOOL_STATS = {
        ["Wooden Axe"] = { damage = 25, cooldown = 0.5 },
        ["Stone Axe"] = { damage = 35, cooldown = 0.54 },
        ["Iron Axe"] = { damage = 50, cooldown = 0.49 },
        ["Golden Axe"] = { damage = 70, cooldown = 0.44 },
        ["Diamond Axe"] = { damage = 100, cooldown = 0.38 },
        ["Wooden Pickaxe"] = { damage = 25, cooldown = 0.55 },
        ["Stone Pickaxe"] = { damage = 35, cooldown = 0.56 },
        ["Iron Pickaxe"] = { damage = 50, cooldown = 0.51 },
        ["Golden Pickaxe"] = { damage = 70, cooldown = 0.46 },
        ["Diamond Pickaxe"] = { damage = 100, cooldown = 0.4 },
    },
}
do
    local ok, cfg = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("GameConfig", 10))
    end)
    if ok and type(cfg) == "table" then
        Config.GATHER_DISTANCE = tonumber(cfg.GATHER_DISTANCE) or Config.GATHER_DISTANCE
        if type(cfg.GATHER_TOOL_STATS) == "table" then Config.GATHER_TOOL_STATS = cfg.GATHER_TOOL_STATS end
        if type(cfg.FOOD) == "table" then Config.FOOD_MAX = tonumber(cfg.FOOD.max) or Config.FOOD_MAX end
    end
end

-- worth the most first when ores come first
local ORE_VALUE = { DiamondOre = 5, GoldOre = 4, IronOre = 3, DropTomb = 3, CoalOre = 2, Freeze = 2 }

--// state ---------------------------------------------------------------------

local Farm = {
    Enabled = false,
    Kinds = "trees and rocks",
    Move = "teleport",
    Face = "auto",
    Radius = 200,
    OresFirst = true,
    AtNight = false,
    MoveOn = true,

    target = nil,
    skip = {},
    swings = 0,
    progressAt = 0,
    faceLearned = false,
    status = "off",
    broken = 0,
    -- what the server showed about each kind of resource: the strongest tool
    -- that did nothing to it, the weakest that broke it, and misses so far
    cant = {},
    cantTool = {},
    can = {},
    fails = {},
    damaged = setmetatable({}, { __mode = "k" }),
}

local Swing = {
    Fast = false,
    Mode = "tool swap",
    Every = 0.1,
    Manual = true,
    count = 0,
    readyAt = setmetatable({}, { __mode = "k" }),
    firedAt = setmetatable({}, { __mode = "k" }),
    turns = 0,
    damage = {},
}

local Aura = {
    Enabled = false,
    Stick = true,
    Spot = "behind",
    Distance = 3,
    StickRange = 80,
    Range = 12,
    Priority = "nearest",
    Animals = false,
    Face = "auto",
    AutoSword = true,
    Return = true,

    skip = {},
    swings = 0,
    progressAt = 0,
    faceLearned = false,
    status = "off",
    kills = 0,
}

local Food = { Enabled = false, Below = 40, eaten = 0 }
local Heal = { Enabled = false, Below = 50, used = 0 }
local Repair = { Enabled = false, Travel = false, Range = 60, done = 0 }
local Revive = { Enabled = false, UseSaved = true }
local Loot = {
    Crates = false,
    Drops = false,
    Travel = true,
    Range = 120,
    LeaveCrafter = true,
    tries = setmetatable({}, { __mode = "k" }),
    skip = setmetatable({}, { __mode = "k" }),
    visits = setmetatable({}, { __mode = "k" }),
    opened = 0,
    collected = 0,
}
local Night = { Base = false, Warn = true }
local Dodge = { Enabled = false, Melee = true, Ranged = true, threats = {}, seen = setmetatable({}, { __mode = "k" }), dodged = 0 }
local Fall = { Enabled = false, safe = nil, saves = 0 }
local Cages = { Enabled = false, broken = 0 }

local Move = {
    Speed = false,
    SpeedValue = 32,
    Fly = false,
    FlySpeed = 60,
    Noclip = false,
    InfiniteJump = false,
    GlideSpeed = 60,
}

local Esp = {
    Enemies = false,
    Animals = false,
    Ores = false,
    Crates = false,
    Drops = false,
    Hud = true,
}

local Misc = { AntiAfk = true }

local FARM_KINDS = { 'trees and rocks', 'trees', 'rocks', 'ores only' }
local MOVE_MODES = { 'teleport', 'glide', 'walk', "don't move" }
local FACE_MODES = { 'auto', 'always', 'never' }
local SWING_MODES = { 'tool swap', 'on cooldown', 'spam' }
local STICK_SPOTS = { 'behind', 'above', 'circle' }
local PRIORITIES = { 'nearest', 'weakest', 'strongest' }

--// helpers -------------------------------------------------------------------

local function myCharacter()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function pivotOf(inst)
    if inst:IsA("BasePart") then return inst.Position end
    local ok, pivot = pcall(function() return inst:GetPivot().Position end)
    if ok then return pivot end
    return nil
end

-- turns you to face a point without tipping you over
local function face(root, point)
    local pos = root.Position
    local look = flat(point - pos)
    if look.Magnitude < 0.1 then return end
    root.CFrame = CFrame.lookAt(pos, pos + look)
end

-- how high your root part sits above the floor you stand on
local function standHeight(root, hum)
    return (hum.HipHeight > 0 and hum.HipHeight or 2) + root.Size.Y / 2
end

-- One round trip: a teleport has to reach the server before a swing from the
-- new spot can count.
local function roundTrip()
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(ping) == "number" and ping > 0 then return math.min(ping * 2, 0.6) end
    return 0.15
end

-- the server's clock, which the day, the night and every enemy attack run on
local function serverTime()
    local ok, now = pcall(function() return Workspace:GetServerTimeNow() end)
    return ok and now or os.time()
end

--// tools -------------------------------------------------------------------------

local TIERS = { Wooden = 1, Stone = 2, Iron = 3, Golden = 4, Gold = 4, Diamond = 5 }

local function tierOf(tool)
    local first = tool.Name:match("^(%a+)")
    return TIERS[first or ""] or 0
end

local function isPickaxe(tool)
    return tool.Name:find("Pickaxe", 1, true) ~= nil
end

local function isAxe(tool)
    return tool.Name:find("Axe", 1, true) ~= nil and not isPickaxe(tool)
end

-- every tool you carry, in hand or in the backpack
local function allTools()
    local list = {}
    local holders = { LocalPlayer.Character, LocalPlayer:FindFirstChildOfClass("Backpack") }
    for i = 1, 2 do
        local holder = holders[i]
        if holder then
            for _, item in ipairs(holder:GetChildren()) do
                if item:IsA("Tool") then list[#list + 1] = item end
            end
        end
    end
    return list
end

-- gather tools rank by the game's own damage numbers, anything else by the
-- material in its name
local function toolRank(tool)
    local stats = Config.GATHER_TOOL_STATS[tool.Name]
    return (stats and tonumber(stats.damage)) or tierOf(tool)
end

-- every tool that passes test, strongest first
local function toolsWhere(test)
    local list = {}
    for _, tool in ipairs(allTools()) do
        if test(tool) then list[#list + 1] = tool end
    end
    table.sort(list, function(a, b) return toolRank(a) > toolRank(b) end)
    return list
end

local function gatherToolsFor(kind)
    if kind == "Tree" then
        return toolsWhere(function(tool) return tool:GetAttribute("GatherTool") == true and isAxe(tool) end)
    end
    return toolsWhere(function(tool) return tool:GetAttribute("GatherTool") == true and isPickaxe(tool) end)
end

local function swordTools()
    return toolsWhere(function(tool) return tool:GetAttribute("Sword") == true end)
end

local function heldTool(char)
    return char and char:FindFirstChildOfClass("Tool") or nil
end

local function equip(tool, hum)
    if not tool or tool.Parent == LocalPlayer.Character then return tool end
    pcall(function() hum:EquipTool(tool) end)
    return tool
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

--// swinging --------------------------------------------------------------------------

-- a little past the server's cooldown, so a swing that reaches it a touch
-- quicker than the last one is not thrown away
local COOLDOWN_MARGIN = 0.04

-- the server's wait between swings of a tool, as the game's own loops read it
local function toolCooldown(tool, kind)
    if kind == "gather" then
        local stats = Config.GATHER_TOOL_STATS[tool.Name]
        local gap = (stats and tonumber(stats.cooldown)) or tonumber(tool:GetAttribute("SwingCooldown")) or 0.6
        if isAxe(tool) and LocalPlayer:GetAttribute("EquippedClass") == "Lumberjack" then gap = gap * 0.9 end
        return math.max(0.05, gap)
    end
    return math.max(0.05, tonumber(tool:GetAttribute("AttackCooldown")) or 0.5)
end

-- How long after a swing a tool may swing again: the game's own wait
-- normally, just the cooldown with fast swing, the slider in spam mode.
local function gapAfter(tool, kind)
    if not Swing.Fast then return toolCooldown(tool, kind) + 0.08 end
    if Swing.Mode == "spam" then return Swing.Every end
    return toolCooldown(tool, kind) + COOLDOWN_MARGIN
end

local function swapping(candidates)
    return Swing.Fast and Swing.Mode == "tool swap" and #candidates > 1
end

-- The tool to swing right now out of candidates (strongest first), or nil
-- while none is ready. The strongest always swings the moment its cooldown
-- ends. With tool swap the rest take turns in the gaps, one per slot of the
-- strongest one's cooldown, and only in the first half of a slot: a server
-- that times each tool on its own takes every one of those swings, and one
-- that times you as a whole throws them away, as none comes late enough to
-- land in place of the strongest tool's own swing.
local function pickSwing(candidates, kind, now)
    local best = candidates[1]
    if not best then return nil end
    if now >= (Swing.readyAt[best] or 0) then return best end
    local anchor = Swing.firedAt[best]
    if not swapping(candidates) or not anchor then return nil end
    local slot = gapAfter(best, kind) / #candidates
    local turn = math.floor((now - anchor) / slot)
    if turn < 1 or turn >= #candidates or turn <= Swing.turns or now - anchor - turn * slot >= slot / 2 then return nil end
    for i = 2, #candidates do
        local tool = candidates[i]
        if now >= (Swing.readyAt[tool] or 0) then
            Swing.turns = turn
            return tool
        end
    end
    return nil
end

-- exactly what holding click sends: the tool activates, a gather tool sends
-- GatherHit, and any clicking tool sends MouseClick
local function swing(tool, kind)
    pcall(function() tool:Activate() end)
    if kind == "gather" and Remotes.GatherHit then Remotes.GatherHit:FireServer() end
    if Remotes.MouseClick and (kind == "attack" or tool:GetAttribute("ToolClick")) then
        Remotes.MouseClick:FireServer()
    end
    Swing.count = Swing.count + 1
end

local function swingWith(tool, kind, hum, now, candidates)
    equip(tool, hum)
    swing(tool, kind)
    Swing.readyAt[tool] = now + gapAfter(tool, kind)
    if tool == candidates[1] then
        Swing.firedAt[tool] = now
        Swing.turns = 0
    end
end

-- damage you have done in the last ten seconds, for the damage per second readout
local function noteDamage(now, amount)
    local log = Swing.damage
    log[#log + 1] = { at = now, amount = amount }
    while log[1] and now - log[1].at > 10 do table.remove(log, 1) end
end

local function damageRate(now)
    local log = Swing.damage
    while log[1] and now - log[1].at > 10 do table.remove(log, 1) end
    if not log[1] then return 0 end
    local total = 0
    for i = 1, #log do total = total + log[i].amount end
    return total / math.max(now - log[1].at, 2)
end

--// world -------------------------------------------------------------------------------

local Resources = {}
local RaycastIgnore = {}

local function resourceAlive(model)
    return model.Parent ~= nil and model:GetAttribute("Depleted") ~= true
        and (tonumber(model:GetAttribute("Health")) or 1) > 0
end

-- Every resource the game has loaded around you: all it tags GatherResource
-- (Frozen Cubes and tombs live outside the resource folders), plus the
-- resource folders in case a tag is ever missing.
local function scanResources()
    local list, seen, ignore = {}, {}, {}
    local function take(model, folder)
        if seen[model] then return end
        seen[model] = true
        if model:IsA("Model") and model:GetAttribute("ResourceType") ~= nil then
            list[#list + 1] = model
            -- rays and landing spots look straight through resources
            if not folder then ignore[#ignore + 1] = model end
        end
    end
    local function takeFolder(folder)
        if not folder then return end
        ignore[#ignore + 1] = folder
        for _, model in ipairs(folder:GetChildren()) do take(model, folder) end
    end
    local chunks = Workspace:FindFirstChild("GeneratedChunks")
    if chunks then
        for _, chunk in ipairs(chunks:GetChildren()) do takeFolder(chunk:FindFirstChild("Resources")) end
    end
    takeFolder(Workspace:FindFirstChild("Resources"))
    local ok, tagged = pcall(function() return CollectionService:GetTagged("GatherResource") end)
    if ok and type(tagged) == "table" then
        for _, model in ipairs(tagged) do take(model, nil) end
    end
    for _, name in ipairs({ "Enemies", "Animals", "WorldItemDrops", "LocalResourceAnimations", "ClientEnemyPresentation", "ClientEnemyAppearances" }) do
        local folder = Workspace:FindFirstChild(name)
        if folder then ignore[#ignore + 1] = folder end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then ignore[#ignore + 1] = plr.Character end
    end
    Resources = list
    RaycastIgnore = ignore
    local now = os.clock()
    for model, untilTime in pairs(Farm.skip) do
        if untilTime <= now or not model.Parent then Farm.skip[model] = nil end
    end
    for model, untilTime in pairs(Aura.skip) do
        if untilTime <= now or not model.Parent then Aura.skip[model] = nil end
    end
    -- anything you took a chunk out of that is gone now counts as broken
    for model in pairs(Farm.damaged) do
        if not resourceAlive(model) then
            Farm.damaged[model] = nil
            Farm.broken = Farm.broken + 1
        end
    end
end

local function resourcePoint(model)
    local hitbox = model:FindFirstChild("Hitbox", true)
    if hitbox and hitbox:IsA("BasePart") then return hitbox.Position end
    return pivotOf(model)
end

local function assetOf(model)
    return model:GetAttribute("AssetName") or model.Name
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

-- The floor under a point, looked for from a little above it so a roof or a
-- tree top overhead is never mistaken for the ground.
local function floorBelow(point, above, depth, ignore)
    rayParams.FilterDescendantsInstances = ignore or RaycastIgnore
    local hit = Workspace:Raycast(point + Vector3.new(0, above, 0), Vector3.new(0, -(above + depth), 0), rayParams)
    return hit and hit.Position.Y or nil
end

-- A spot gap studs from a point, standing on the ground (trees, balls of
-- leaves and creatures do not count as ground): your side of it first, then
-- the others, so something on the edge of an island never has you standing
-- on thin air. Ground just under the point comes before any further down.
local function spotNear(point, root, hum, gap)
    local away = flat(root.Position - point)
    local start = away.Magnitude > 0.1 and math.atan2(away.Z, away.X) or 0
    local height = standHeight(root, hum) + 0.3
    for _, depth in ipairs({ 20, 60 }) do
        for i = 0, 7 do
            local turn = math.ceil(i / 2) * (i % 2 == 0 and 1 or -1)
            local angle = start + turn * math.pi / 4
            local base = point + Vector3.new(math.cos(angle), 0, math.sin(angle)) * gap
            local floor = floorBelow(base, 8, depth)
            if floor then return Vector3.new(base.X, floor + height, base.Z) end
        end
    end
    local base = point + Vector3.new(math.cos(start), 0, math.sin(start)) * gap
    return Vector3.new(base.X, math.max(root.Position.Y, point.Y), base.Z)
end

-- whether a body standing on the floor at feet fits there with nothing solid
-- in the way
local function bodyFits(feet, ignore)
    overlapParams.FilterDescendantsInstances = ignore
    local ok, parts = pcall(function()
        return Workspace:GetPartBoundsInBox(CFrame.new(feet + Vector3.new(0, 2.7, 0)), Vector3.new(2, 4.6, 2), overlapParams)
    end)
    if not ok or type(parts) ~= "table" then return true end
    for _, part in ipairs(parts) do
        if part.CanCollide then return false end
    end
    return true
end

-- Gets you to a spot the chosen way. Returns true once you are there (a
-- teleport is there at once; glide and walk take a moment).
local function goTo(spot, mode, root, hum, dt, now, state)
    local offset = spot - root.Position
    if offset.Magnitude < 2 then return true end
    if mode == "teleport" then
        root.CFrame = CFrame.new(spot) * (root.CFrame - root.CFrame.Position)
        root.AssemblyLinearVelocity = Vector3.zero
        state.settleUntil = now + roundTrip()
        return true
    elseif mode == "glide" then
        local step = math.min(offset.Magnitude, Move.GlideSpeed * dt)
        root.CFrame = root.CFrame + offset.Unit * step
        root.AssemblyLinearVelocity = Vector3.zero
        return offset.Magnitude - step < 2
    elseif mode == "walk" then
        if now >= (state.nextWalk or 0) then
            state.nextWalk = now + 0.4
            pcall(function() hum:MoveTo(spot) end)
        end
        return flatDistance(spot, root.Position) < 3
    end
    return false
end

local function enemiesFolder() return Workspace:FindFirstChild("Enemies") end
local function animalsFolder() return Workspace:FindFirstChild("Animals") end

-- Alive the way the game itself decides it: health left on Humanoid2 and not
-- playing its death, since a dead enemy can still show health while it falls.
local function creatureAlive(model)
    local hum2 = model:FindFirstChild("Humanoid2")
    if not hum2 or not hum2:IsA("Humanoid") or hum2.Health <= 0 then return false, hum2 end
    return model:GetAttribute("EnemyActionAnimation") ~= "Dead", hum2
end

-- alive and done spawning in, so a hit on it can count
local function creatureReady(model)
    local alive, hum2 = creatureAlive(model)
    return alive and model:GetAttribute("SpawnReady") ~= false, hum2
end

local function creatureRoot(model)
    return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function dayState()
    return ReplicatedStorage:FindFirstChild("DayNightState")
end

local function isNight()
    local state = dayState()
    return state ~= nil and state:GetAttribute("Phase") == "Night"
end

-- your base: the nearest campfire you have built, or else the starter chunk's
-- chunk crafter
local function basePoint(from)
    local best, bestD
    local builds = Workspace:FindFirstChild("Builds")
    if builds then
        for _, build in ipairs(builds:GetChildren()) do
            if build.Name:find("Campfire", 1, true) then
                local point = pivotOf(build)
                if point then
                    local d = from and (point - from).Magnitude or 0
                    if not bestD or d < bestD then best, bestD = point, d end
                end
            end
        end
    end
    if best then return best end
    local chunks = Workspace:FindFirstChild("GeneratedChunks")
    if chunks then
        for _, chunk in ipairs(chunks:GetChildren()) do
            if chunk:GetAttribute("IsStarterChunk") == true then
                local crafter = chunk:FindFirstChild("ChunkCrafting")
                return pivotOf(crafter or chunk)
            end
        end
    end
    return nil
end

-- every chunk crafter in the world
local function chunkCrafters()
    local list = {}
    local chunks = Workspace:FindFirstChild("GeneratedChunks")
    if chunks then
        for _, chunk in ipairs(chunks:GetChildren()) do
            local crafter = chunk:FindFirstChild("ChunkCrafting")
            if crafter then list[#list + 1] = crafter end
        end
    end
    return list
end

--// auto farm ------------------------------------------------------------------------------

-- the game's own names for what it grows, for messages
local DISPLAY_NAMES = {
    Freeze = "Frozen Cube", DropTomb = "Ancient Tomb", DiamondOre = "Diamond Ore", GoldOre = "Gold Ore",
    IronOre = "Iron Ore", CoalOre = "Coal Ore", DesertStone = "Desert Stone",
}

local function displayName(asset)
    return DISPLAY_NAMES[asset] or asset
end

-- trees and rocks the chosen way; cages are left to the cage breaker
local function wantKind(model)
    local kind = model:GetAttribute("ResourceType")
    if kind ~= "Tree" and kind ~= "Rock" then return false end
    if Farm.Kinds == "trees" then return kind == "Tree" end
    if Farm.Kinds == "rocks" then return kind == "Rock" end
    if Farm.Kinds == "ores only" then return kind == "Rock" and ORE_VALUE[assetOf(model)] ~= nil end
    return true
end

-- how close you stand to swing: a little inside the game's gather distance
local function gatherReach()
    return Config.GATHER_DISTANCE - 2.5
end

-- your axes and pickaxes, strongest first, gathered once a frame
local function farmKit()
    return { Tree = gatherToolsFor("Tree"), Rock = gatherToolsFor("Rock"), byAsset = {} }
end

-- The tools that can take a resource on, strongest first, leaving out any
-- that resources of its kind have already shrugged off; nil when none can.
local function farmTools(kit, model)
    local asset = assetOf(model)
    local cached = kit.byAsset[asset]
    if cached ~= nil then return cached or nil end
    local list = kit[model:GetAttribute("ResourceType")] or {}
    local cant = Farm.cant[asset]
    if cant then
        local kept = {}
        for _, tool in ipairs(list) do
            if toolRank(tool) > cant then kept[#kept + 1] = tool end
        end
        list = kept
    end
    kit.byAsset[asset] = list[1] and list or false
    return list[1] and list or nil
end

-- the nearest living resource you have a tool for, ores pulled forward when
-- ores come first
local function farmTarget(root, kit, now)
    local best, bestScore
    for _, model in ipairs(Resources) do
        if resourceAlive(model) and wantKind(model) and not ((Farm.skip[model] or 0) > now) and farmTools(kit, model) then
            local point = resourcePoint(model)
            if point then
                local d = flatDistance(point, root.Position)
                local reach = Farm.Move == "don't move" and gatherReach() or Farm.Radius
                if d <= reach then
                    local score = d
                    if Farm.OresFirst then score = score - (ORE_VALUE[assetOf(model)] or 0) * 60 end
                    if not bestScore or score < bestScore then best, bestScore = model, score end
                end
            end
        end
    end
    return best
end

-- Swings only count once the target's health drops. Auto facing starts off
-- without turning you and switches to facing the first time swings stop
-- landing; a target that still will not take damage is passed over.
local function checkProgress(state, health, now, mode)
    if state.lastHealth and health < state.lastHealth then
        noteDamage(now, state.lastHealth - health)
        state.progressAt = now
        state.misses = 0
        state.landed = (state.landed or 0) + 1
    elseif state.swings >= 3 and now - state.progressAt > 1.5 then
        state.progressAt = now
        state.misses = (state.misses or 0) + 1
        if mode == "auto" and not state.faceLearned then
            state.faceLearned = true
            state.lastHealth = health
            return "face"
        end
        state.lastHealth = health
        return "skip"
    end
    state.lastHealth = health
    return nil
end

-- A resource that took nothing from a tool swung in reach and facing it, and
-- that twice for the same kind of resource: the tool is not good enough for
-- that kind, unless one no stronger has broken one before. The farm then
-- leaves that kind alone until you carry something stronger.
local function learnMiss(model, tool)
    local asset = assetOf(model)
    local rank = toolRank(tool)
    local key = asset .. "|" .. rank
    Farm.fails[key] = (Farm.fails[key] or 0) + 1
    if Farm.fails[key] >= 2 and (Farm.can[asset] or math.huge) > rank and (Farm.cant[asset] or -1) < rank then
        Farm.cant[asset] = rank
        Farm.cantTool[asset] = tool.Name
        notify('farm', ('your %s does nothing to %s, so those are left alone until you carry something stronger'):format(tool.Name, displayName(asset)), 'warning', 6)
    end
end

local function farmStep(now, dt, char, root, hum)
    if not Farm.Enabled then
        Farm.status = "off"
        return false
    end
    -- the swing that breaks the last one is still on its way to the server
    if now < (Farm.moveOnAt or 0) then return true end

    local kit = farmKit()
    if not kit.Tree[1] and not kit.Rock[1] then
        Farm.status = "no axe or pickaxe"
        return false
    end

    -- the current target is kept until it breaks, gets skipped or falls out of
    -- the radius, so a closer tree never pulls you off one half chopped
    local target = Farm.target
    local keep = target and resourceAlive(target) and not ((Farm.skip[target] or 0) > now)
        and farmTools(kit, target) ~= nil and wantKind(target)
    if keep then
        local point = resourcePoint(target)
        keep = point ~= nil and flatDistance(point, root.Position) <= math.max(Farm.Radius, gatherReach())
    end
    if not keep then
        target = farmTarget(root, kit, now)
        Farm.target = target
        Farm.lastHealth = nil
        Farm.swings = 0
        Farm.progressAt = now
        Farm.misses = 0
    end
    if not target then
        Farm.status = "nothing to farm in range"
        return false
    end

    local candidates = farmTools(kit, target)
    local point = resourcePoint(target)
    if not point then return false end

    local name = displayName(assetOf(target))
    if flatDistance(point, root.Position) > gatherReach() then
        if Farm.Move == "don't move" then
            Farm.target = nil
            return false
        end
        Farm.status = ("going to %s"):format(name)
        equip(candidates[1], hum)
        local spot = spotNear(point, root, hum, 4.5)
        if not goTo(spot, Farm.Move, root, hum, dt, now, Farm) then return true end
    end
    if now < (Farm.settleUntil or 0) then return true end

    if Farm.Face == "always" or (Farm.Face == "auto" and Farm.faceLearned) then face(root, point) end

    local health = tonumber(target:GetAttribute("Health")) or 0
    local tool = pickSwing(candidates, "gather", now)
    if tool then
        swingWith(tool, "gather", hum, now, candidates)
        Farm.swings = (Farm.swings or 0) + 1
        -- the strongest tool's swing that breaks it: head for the next one
        -- while it lands, instead of waiting to see it go
        local stats = Config.GATHER_TOOL_STATS[tool.Name]
        local damage = stats and tonumber(stats.damage)
        if Farm.MoveOn and tool == candidates[1] and damage and health <= damage and Farm.Move ~= "don't move" then
            Farm.damaged[target] = true
            Farm.skip[target] = now + 2
            Farm.moveOnAt = now + 0.12
        end
    elseif not contains(candidates, heldTool(char)) then
        equip(candidates[1], hum)
    end

    if Farm.lastHealth and health < Farm.lastHealth then
        Farm.damaged[target] = true
        local asset = assetOf(target)
        Farm.can[asset] = math.min(Farm.can[asset] or math.huge, toolRank(candidates[1]))
    end
    local verdict = checkProgress(Farm, health, now, Farm.Face)
    if verdict == "skip" then
        learnMiss(target, candidates[1])
        Farm.skip[target] = now + 20
        Farm.target = nil
    end
    Farm.status = ("%s %d/%d"):format(name, math.floor(health + 0.5),
        math.floor((tonumber(target:GetAttribute("MaxHealth")) or health) + 0.5))
    return true
end

--// kill aura -------------------------------------------------------------------------------

-- the enemy to fight out of everything within limit, picked the chosen way
local function auraTarget(root, limit, now)
    local best, bestScore
    local function scan(folder)
        for _, model in ipairs(folder:GetChildren()) do
            local ready, hum2 = creatureReady(model)
            local part = ready and creatureRoot(model)
            if part and not ((Aura.skip[model] or 0) > now) then
                local d = (part.Position - root.Position).Magnitude
                if d <= limit then
                    local score = d
                    if Aura.Priority == "weakest" then
                        score = hum2.Health + d * 0.01
                    elseif Aura.Priority == "strongest" then
                        score = -hum2.MaxHealth + d * 0.01
                    end
                    if not bestScore or score < bestScore then best, bestScore = model, score end
                end
            end
        end
    end
    local enemies = enemiesFolder()
    if enemies then scan(enemies) end
    if Aura.Animals then
        local animals = animalsFolder()
        if animals then scan(animals) end
    end
    return best
end

-- Where to stand against a target, redone every frame: behind its back, over
-- its head, or circling it, always facing it and at the height of the floor
-- under that spot rather than its hip height.
local function stickFrame(part, root, hum, now)
    local center = part.Position
    local look = flat(part.CFrame.LookVector)
    look = look.Magnitude > 0.1 and look.Unit or Vector3.new(0, 0, -1)
    if Aura.Spot == "above" then
        local spot = center + Vector3.new(0, Aura.Distance + 2.5, 0)
        return CFrame.lookAt(spot, spot + look)
    end
    local spot
    if Aura.Spot == "circle" then
        local angle = now * 3
        spot = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * Aura.Distance
    else
        spot = center - look * Aura.Distance
    end
    local floor = floorBelow(spot, 4, 12)
    if floor then spot = Vector3.new(spot.X, floor + standHeight(root, hum), spot.Z) end
    return CFrame.lookAt(spot, Vector3.new(center.X, spot.Y, center.Z))
end

local function auraStep(now, dt, char, root, hum)
    if not Aura.Enabled then
        Aura.status = "off"
        Aura.target = nil
        Aura.home = nil
        return false
    end

    local reach = Aura.Stick and math.max(Aura.StickRange, Aura.Range) or Aura.Range
    local target = Aura.target
    if target then
        local alive, hum2 = creatureAlive(target)
        if not alive or not target.Parent then
            -- it died (its health ran out or it is playing its death), or it
            -- vanished after taking damage from you
            local dealt = (hum2 and hum2.Health <= 0) or target:GetAttribute("EnemyActionAnimation") == "Dead"
                or (not target.Parent and Aura.lastHealth and Aura.maxHealth and Aura.lastHealth < Aura.maxHealth)
            if dealt then Aura.kills = Aura.kills + 1 end
            target = nil
        elseif (Aura.skip[target] or 0) > now then
            target = nil
        else
            local part = creatureRoot(target)
            if not part or (part.Position - root.Position).Magnitude > reach + 10 then target = nil end
        end
    end
    if not target then
        target = auraTarget(root, reach, now)
        Aura.target = target
        Aura.lastHealth = nil
        Aura.swings = 0
        Aura.progressAt = now
        Aura.readyAt = now
    end

    if not target then
        Aura.status = "nothing in range"
        if Aura.home then
            -- back to where the fight pulled you from, unless night is taking
            -- you home anyway; always when the fight left you over thin air
            local stranded = not floorBelow(root.Position, 2, 20)
            if (stranded or (Aura.Return and not (Night.Base and isNight()))) and (Aura.home - root.Position).Magnitude > 6 then
                root.CFrame = CFrame.new(Aura.home) * (root.CFrame - root.CFrame.Position)
                root.AssemblyLinearVelocity = Vector3.zero
            end
            Aura.home = nil
        end
        return false
    end

    local candidates = Aura.AutoSword and swordTools() or {}
    if not candidates[1] then
        local held = heldTool(char)
        if held then candidates = { held } end
    end
    if not candidates[1] then
        Aura.status = "no sword"
        return false
    end
    if not contains(candidates, heldTool(char)) then equip(candidates[1], hum) end

    local part = creatureRoot(target)
    local _, hum2 = creatureAlive(target)
    if Aura.Stick then
        if not Aura.home then Aura.home = root.Position end
        -- every frame, so it never gets to turn round and face you
        root.CFrame = stickFrame(part, root, hum, now)
        root.AssemblyLinearVelocity = Vector3.zero
    elseif Aura.Face == "always" or (Aura.Face == "auto" and Aura.faceLearned) then
        face(root, part.Position)
    end

    -- the first swing waits for your new position to reach the server
    if Aura.Stick and now < Aura.readyAt + roundTrip() then
        Aura.status = ("moving onto %s"):format(target.Name)
        return true
    end

    local tool = pickSwing(candidates, "attack", now)
    if tool then
        swingWith(tool, "attack", hum, now, candidates)
        Aura.swings = (Aura.swings or 0) + 1
    end

    local health = hum2 and hum2.Health or 0
    Aura.maxHealth = hum2 and hum2.MaxHealth or nil
    if not creatureAlive(target) then
        Aura.kills = Aura.kills + 1
        Aura.target = nil
    elseif checkProgress(Aura, health, now, Aura.Stick and "always" or Aura.Face) == "skip" then
        -- nothing lands on it; leave it be for a while so the next one gets a turn
        Aura.skip[target] = now + 10
        Aura.target = nil
    end
    local distance = (part.Position - root.Position).Magnitude
    Aura.status = ("%s %d hp · %d st"):format(target.Name, math.floor(health + 0.5), math.floor(distance + 0.5))
    return true
end

--// anti hit --------------------------------------------------------------------------------
-- Enemy swings and everything thrown or dropped at you are announced before
-- they land. Anti hit steps you just clear of them, onto solid ground, and
-- keeps you there until they have landed.

-- how long after an enemy starts a swing its blow can still land
local MELEE_WINDOW = 0.9

local function addThreat(center, radius, landsAt, source)
    Dodge.threats[#Dodge.threats + 1] = { center = center, radius = radius, to = landsAt, source = source }
end

-- a swing reaches as far as the enemy's own attack distance
local function addSwing(model, startedAt)
    local reach = tonumber(model:GetAttribute("AttackDistance")) or 6
    addThreat(nil, reach + 2, startedAt + MELEE_WINDOW, model)
end

if Remotes.EnemyPresentation then
    track(Remotes.EnemyPresentation.OnClientEvent:Connect(function(action, ...)
        if not Dodge.Enabled or not Dodge.Ranged then return end
        local a = table.pack(...)
        local now = serverTime()
        if action == "ThrowProjectile" then
            -- (what, from, where it lands, flight time, thrown at)
            local flight = tonumber(a[4])
            if typeof(a[3]) == "Vector3" and flight then addThreat(a[3], 7, (tonumber(a[5]) or now) + flight + 0.15) end
        elseif action == "CageFall" then
            -- (id, from, where it lands, fall time, dropped at)
            local fall = tonumber(a[4])
            if typeof(a[3]) == "CFrame" and fall then addThreat(a[3].Position, 9, (tonumber(a[5]) or now) + fall + 0.3) end
        elseif action == "TombFall" then
            -- (id, from, where it lands, delay, fall time, dropped at)
            local fall = tonumber(a[5])
            if typeof(a[3]) == "CFrame" and fall then
                addThreat(a[3].Position, 9, (tonumber(a[6]) or now) + (tonumber(a[4]) or 0) + fall + 0.3)
            end
        elseif action == "SpearLaunch" then
            -- (id, from, where it lands, flight time, thrown at)
            local flight = tonumber(a[4])
            if typeof(a[3]) == "Vector3" and flight then addThreat(a[3], 6, (tonumber(a[5]) or now) + flight + 0.15) end
        elseif action == "ThunderStrike" then
            -- (where, delay, how long it lingers)
            local delay = tonumber(a[2])
            if typeof(a[1]) == "Vector3" and delay then addThreat(a[1], 8, now + delay + 0.3) end
        end
    end))
end

if Remotes.EnemyAnimation then
    track(Remotes.EnemyAnimation.OnClientEvent:Connect(function(model, action, startedAt)
        if Dodge.Enabled and Dodge.Melee and (action == "Attack" or action == "Attack2") and typeof(model) == "Instance" then
            addSwing(model, tonumber(startedAt) or serverTime())
        end
    end))
end

-- swings by enemies close by, read off their attributes as they start
local function watchSwings(root, now)
    local enemies = enemiesFolder()
    if not enemies then return end
    for _, model in ipairs(enemies:GetChildren()) do
        local part = creatureRoot(model)
        if part and (part.Position - root.Position).Magnitude < 30 then
            local sequence = model:GetAttribute("EnemyActionSequence")
            if sequence ~= nil and sequence ~= Dodge.seen[model] then
                local first = Dodge.seen[model] == nil
                Dodge.seen[model] = sequence
                local action = model:GetAttribute("EnemyActionAnimation")
                local startedAt = tonumber(model:GetAttribute("EnemyActionStartedAt")) or now
                if (action == "Attack" or action == "Attack2") and (not first or now - startedAt < MELEE_WINDOW) then
                    addSwing(model, startedAt)
                end
            end
        end
    end
end

-- where a threat is right now, or nil when it cannot reach you: a swing
-- only reaches what is in front of the enemy swinging it
local function threatAt(threat, root)
    local model = threat.source
    if not model then return threat.center end
    if not model.Parent or not creatureAlive(model) then return nil end
    local part = creatureRoot(model)
    if not part then return nil end
    local to = flat(root.Position - part.Position)
    local look = flat(part.CFrame.LookVector)
    if to.Magnitude > 0.1 and look.Magnitude > 0.1 and look.Unit:Dot(to.Unit) < -0.3 then return nil end
    return part.Position
end

-- The nearest spot on solid ground clear of every danger, trying straight
-- out from them first.
local function safeSpot(root, hum, dangers)
    local middle, reach = Vector3.zero, 0
    for _, d in ipairs(dangers) do
        middle = middle + d.center
        reach = math.max(reach, d.radius + 2.5)
    end
    middle = middle / #dangers
    local away = flat(root.Position - middle)
    local start = away.Magnitude > 0.1 and math.atan2(away.Z, away.X) or 0
    local height = standHeight(root, hum)
    local best, bestCost
    for i = 0, 11 do
        local turn = math.ceil(i / 2) * (i % 2 == 0 and 1 or -1)
        local angle = start + turn * math.pi / 6
        local spot = middle + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach
        local clear = true
        for _, d in ipairs(dangers) do
            if flatDistance(spot, d.center) < d.radius + 2 then clear = false end
        end
        local floor = clear and floorBelow(Vector3.new(spot.X, root.Position.Y, spot.Z), 6, 14)
        if floor and bodyFits(Vector3.new(spot.X, floor, spot.Z), RaycastIgnore) then
            local stand = Vector3.new(spot.X, floor + height, spot.Z)
            local cost = (stand - root.Position).Magnitude
            if not bestCost or cost < bestCost then best, bestCost = stand, cost end
        end
    end
    return best
end

-- Steps out of whatever is about to land on you. Says "ranged" while it is
-- waiting out something thrown or dropped, when nothing else may move you,
-- and "melee" while it is waiting out a swing, when only the kill aura may
-- (it keeps you behind enemies, out of their swings).
local function dodgeStep(now, char, root, hum)
    if not Dodge.Enabled then
        if Dodge.threats[1] then table.clear(Dodge.threats) end
        return nil
    end
    local t = serverTime()
    if Dodge.Melee then watchSwings(root, t) end
    local dangers
    for i = #Dodge.threats, 1, -1 do
        local threat = Dodge.threats[i]
        if t > threat.to then
            table.remove(Dodge.threats, i)
        else
            local center = threatAt(threat, root)
            if center and flatDistance(center, root.Position) < threat.radius and math.abs(center.Y - root.Position.Y) < threat.radius + 4 then
                dangers = dangers or {}
                dangers[#dangers + 1] = { center = center, radius = threat.radius, to = threat.to, threat = threat }
            end
        end
    end
    if dangers then
        local spot = safeSpot(root, hum, dangers)
        if spot then
            root.CFrame = CFrame.new(spot) * (root.CFrame - root.CFrame.Position)
            root.AssemblyLinearVelocity = Vector3.zero
        end
        for _, d in ipairs(dangers) do
            if not d.threat.dodged then
                d.threat.dodged = true
                Dodge.dodged = Dodge.dodged + 1
            end
            if d.threat.source then
                Dodge.meleeUntil = math.max(Dodge.meleeUntil or 0, d.to)
            else
                Dodge.rangedUntil = math.max(Dodge.rangedUntil or 0, d.to)
            end
        end
    end
    if t < (Dodge.rangedUntil or 0) then return "ranged" end
    if t < (Dodge.meleeUntil or 0) then return "melee" end
    return nil
end

--// anti fall -------------------------------------------------------------------------------

-- Remembers the last ground you stood on, and puts you straight back on it
-- when you drop off an edge with nothing below, or have already fallen far.
local function fallStep(now, char, root, hum)
    if not Fall.Enabled or Move.Fly then return false end
    local velocity = root.AssemblyLinearVelocity
    if hum.FloorMaterial ~= Enum.Material.Air and math.abs(velocity.Y) < 8 then
        Fall.safe = root.Position
        return false
    end
    local safe = Fall.safe
    if not safe or now < (Fall.nextSave or 0) then return false end
    local lost = root.Position.Y < safe.Y - 60
    if not lost and velocity.Y < -30 then lost = floorBelow(root.Position, 0, 250) == nil end
    if not lost then return false end
    root.CFrame = CFrame.new(safe + Vector3.new(0, 0.5, 0)) * (root.CFrame - root.CFrame.Position)
    root.AssemblyLinearVelocity = Vector3.zero
    Fall.saves = Fall.saves + 1
    Fall.nextSave = now + 0.5
    return true
end

--// cages -----------------------------------------------------------------------------------
-- The beast drops a cage on someone: a resource of type Cage that has to be
-- broken to let them out.

local function nearestCage(root, limit)
    local best, bestD
    for _, model in ipairs(Resources) do
        if model:GetAttribute("ResourceType") == "Cage" and resourceAlive(model) then
            local point = resourcePoint(model)
            local d = point and flatDistance(point, root.Position)
            if d and d <= limit and (not bestD or d < bestD) then best, bestD = model, d end
        end
    end
    return best
end

local function cageStep(now, dt, char, root, hum)
    if not Cages.Enabled then return false end
    local cage = nearestCage(root, 80)
    if cage ~= Cages.target then
        if Cages.target and not resourceAlive(Cages.target) then Cages.broken = Cages.broken + 1 end
        Cages.target = cage
        Cages.useless = {}
        Cages.lastHealth = nil
        Cages.swings = 0
        Cages.progressAt = now
    end
    if not cage then return false end
    -- whatever breaks it: gather tools first, then swords, dropping any that do nothing
    local tools = toolsWhere(function(tool)
        return (tool:GetAttribute("GatherTool") == true or tool:GetAttribute("Sword") == true) and not Cages.useless[tool]
    end)
    if not tools[1] then
        Cages.useless = {}
        return false
    end
    local point = resourcePoint(cage)
    if flatDistance(point, root.Position) > gatherReach() then
        goTo(spotNear(point, root, hum, 3), "teleport", root, hum, dt, now, Cages)
    end
    if now < (Cages.settleUntil or 0) then return true end
    local tool = tools[1]
    if now >= (Swing.readyAt[tool] or 0) then
        swingWith(tool, tool:GetAttribute("GatherTool") == true and "gather" or "attack", hum, now, { tool })
        Cages.swings = Cages.swings + 1
    end
    local health = tonumber(cage:GetAttribute("Health")) or 0
    if Cages.lastHealth and health < Cages.lastHealth then
        Cages.progressAt = now
        Cages.swings = 0
    elseif Cages.swings >= 3 and now - Cages.progressAt > 1.5 then
        Cages.useless[tool] = true
        Cages.swings = 0
        Cages.progressAt = now
    end
    Cages.lastHealth = health
    return true
end

--// survival --------------------------------------------------------------------------------

-- the food that best covers what you are missing: the smallest that fills
-- the gap, or failing that the biggest you have
local function pickFood(missing)
    local fits, fitsValue, biggest, biggestValue
    for _, tool in ipairs(allTools()) do
        local value = tonumber(tool:GetAttribute("Food"))
        if value and value > 0 then
            if value >= missing and (not fitsValue or value < fitsValue) then fits, fitsValue = tool, value end
            if not biggestValue or value > biggestValue then biggest, biggestValue = tool, value end
        end
    end
    return fits or biggest
end

local function eatStep(now, char, root, hum)
    if not Food.Enabled then return false end
    if now < (Food.busyUntil or 0) then return true end
    local food = tonumber(LocalPlayer:GetAttribute("Food"))
    if not food or food / Config.FOOD_MAX * 100 >= Food.Below or now < (Food.nextTry or 0) then return false end
    local item = pickFood(Config.FOOD_MAX - food)
    if not item or not Remotes.Eat then
        Food.nextTry = now + 5
        return false
    end
    local previous = heldTool(char)
    equip(item, hum)
    Food.busyUntil = now + 0.5
    Food.nextTry = now + 1.2
    -- the game eats whatever food is in your hands, so the equip has to land first
    task.delay(0.12, function()
        if Unloaded or not item.Parent then return end
        Remotes.Eat:FireServer(item)
        Food.eaten = Food.eaten + 1
    end)
    task.delay(0.45, function()
        if Unloaded then return end
        if previous and previous ~= item and previous.Parent then equip(previous, hum) end
    end)
    return true
end

-- Bandages heal while they are held and used, the way holding click with one
-- does. It stops once you are full, after six seconds, or if you get hit.
local function healStep(now, char, root, hum)
    if not Heal.Enabled or not Remotes.UseItem then return false end
    if Heal.tool then
        local done = hum.Health >= hum.MaxHealth * 0.98 or now >= Heal.stopAt
            or Heal.tool.Parent ~= char or hum.Health < Heal.lowest - 1
        Heal.lowest = math.min(Heal.lowest, hum.Health)
        if not done then return true end
        Remotes.UseItem:FireServer(nil)
        if Heal.previous and Heal.previous ~= Heal.tool and Heal.previous.Parent then equip(Heal.previous, hum) end
        Heal.tool, Heal.previous = nil, nil
        Heal.nextTry = now + 1.5
        return false
    end
    if hum.Health / hum.MaxHealth * 100 >= Heal.Below or now < (Heal.nextTry or 0) then return false end
    local bandage = toolsWhere(function(tool) return tonumber(tool:GetAttribute("HealAmount")) ~= nil end)[1]
    if not bandage then
        Heal.nextTry = now + 5
        return false
    end
    Heal.previous = heldTool(char)
    equip(bandage, hum)
    Heal.tool = bandage
    Heal.stopAt = now + 6
    Heal.lowest = hum.Health
    task.delay(0.12, function()
        if Unloaded or Heal.tool ~= bandage then return end
        Remotes.UseItem:FireServer(bandage)
        Heal.used = Heal.used + 1
    end)
    return true
end

local function hammerFor(totem)
    return toolsWhere(function(tool)
        return tool:GetAttribute("RepairTool") == true and (tool:GetAttribute("TotemRepairTool") == true) == totem
    end)[1]
end

-- the nearest build of yours that is damaged, as the game's own repair hammer
-- sees it
local function damagedBuild(root, range)
    local builds = Workspace:FindFirstChild("Builds")
    if not builds then return nil end
    local best, bestD
    for _, build in ipairs(builds:GetChildren()) do
        if build:IsA("Model") and build:GetAttribute("BuildHealthConfigured") == true then
            local bh = build:FindFirstChild("BuildHumanoid")
            if bh and bh:IsA("Humanoid") and bh.Health > 0 and bh.Health < bh.MaxHealth then
                local point = pivotOf(build)
                local d = point and (point - root.Position).Magnitude
                if d and d <= range and (not bestD or d < bestD) then best, bestD = build, d end
            end
        end
    end
    return best, bestD
end

local function repairStep(now, dt, char, root, hum)
    if not Repair.Enabled or not Remotes.RepairBuild then return false end
    if now < (Repair.busyUntil or 0) then return true end
    if now < (Repair.nextLook or 0) then return false end
    Repair.nextLook = now + 0.5
    local build, distance = damagedBuild(root, Repair.Travel and Repair.Range or 18)
    if not build then return false end
    local hammer = hammerFor(build.Name:find("Totem", 1, true) ~= nil)
    if not hammer then return false end
    if distance > 18 then
        local spot = spotNear(pivotOf(build), root, hum, 8)
        goTo(spot, "teleport", root, hum, dt, now, Repair)
    end
    equip(hammer, hum)
    Repair.busyUntil = now + math.max(0.6, roundTrip() + 0.3)
    task.delay(0.12, function()
        if Unloaded or not build.Parent then return end
        local ok = pcall(function() return Remotes.RepairBuild:InvokeServer(build) end)
        if ok then Repair.done = Repair.done + 1 end
    end)
    return true
end

local function reviveStep(now)
    if not Revive.Enabled or not Remotes.ClaimFreeRevive then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 then
        Revive.deadSince = nil
        return
    end
    Revive.deadSince = Revive.deadSince or now
    -- the same order the death screen's revive button uses
    if now - Revive.deadSince < 2 or now < (Revive.nextTry or 0) then return end
    if LocalPlayer:GetAttribute("ReviveInProgress") then return end
    Revive.nextTry = now + 3
    if LocalPlayer:GetAttribute("FreeReviveUsed") ~= true then
        Remotes.ClaimFreeRevive:FireServer()
        notify('revive', 'used your free revive', 'success', 4)
    elseif Revive.UseSaved and (tonumber(LocalPlayer:GetAttribute("SavedReviveCredits")) or 0) > 0 then
        Remotes.ClaimFreeRevive:FireServer("Saved")
        notify('revive', 'used a saved revive', 'success', 4)
    end
end

local function nightStep(now, dt, char, root, hum)
    if not Night.Base or not isNight() then return false end
    local base = basePoint(root.Position)
    if base and flatDistance(base, root.Position) > 25 and now >= (Night.nextHop or 0) then
        Night.nextHop = now + 3
        goTo(spotNear(base, root, hum, 6), "teleport", root, hum, dt, now, Night)
    end
    -- the kill aura has already had its turn this frame; farming waits
    if Farm.AtNight then return false end
    Farm.status = "waiting out the night at base"
    return true
end

--// loot ------------------------------------------------------------------------------------

-- crates are proximity prompts the game marks with a Crate attribute
local Crates = {}

local function noteCrate(inst)
    if inst:IsA("ProximityPrompt") and inst:GetAttribute("Crate") == true then Crates[inst] = true end
end

for _, inst in ipairs(Workspace:GetDescendants()) do noteCrate(inst) end
track(Workspace.DescendantAdded:Connect(function(inst)
    if inst:IsA("ProximityPrompt") then task.defer(noteCrate, inst) end
end))

local function promptPart(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then parent = parent.Parent end
    if parent and parent:IsA("BasePart") then return parent end
    if parent and parent:IsA("Model") then return parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true) end
    return nil
end

local function promptPoint(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    return parent and pivotOf(parent) or nil
end

-- Presses a prompt: the executor's fireproximityprompt skipping the hold,
-- or failing that the prompt's own input with the hold taken out. With hold
-- it holds for the prompt's full time instead, for a server that times it
-- (that waits, so only from a thread that can).
local function firePrompt(prompt, hold)
    if typeof(fireproximityprompt) == "function" and pcall(fireproximityprompt, prompt, 1, not hold) then
        return true
    end
    return (pcall(function()
        if hold then
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration + 0.05)
            prompt:InputHoldEnd()
            return
        end
        local duration, sight = prompt.HoldDuration, prompt.RequiresLineOfSight
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt:InputHoldBegin()
        prompt:InputHoldEnd()
        prompt.HoldDuration = duration
        prompt.RequiresLineOfSight = sight
    end))
end

-- The crate a prompt opens: the nearest model over the prompt when it is
-- crate sized, otherwise the part the prompt sits on. Gives its middle, its
-- size and the thing itself.
local function crateBox(prompt)
    local node = prompt.Parent
    while node and node ~= Workspace do
        if node:IsA("Model") then
            local ok, cf, size = pcall(function() return node:GetBoundingBox() end)
            if ok and cf and size and size.X <= 16 and size.Y <= 16 and size.Z <= 16 then
                return cf.Position, size, node
            end
            break
        end
        node = node.Parent
    end
    local part = promptPart(prompt)
    if part then return part.Position, part.Size, part end
    local point = promptPoint(prompt)
    if point then return point, Vector3.new(2, 2, 2), nil end
    return nil
end

-- Somewhere to stand right beside a crate, on the same floor it sits on: the
-- side facing you first, then the other sides, then the top of the crate. The
-- floor is looked for from just above the crate's own bottom, so the roof of
-- the barn or tower it is in never counts.
local function crateSpot(prompt, root, hum)
    local center, size, crate = crateBox(prompt)
    if not center then return nil end
    local bottom = center.Y - size.Y / 2
    local height = standHeight(root, hum)
    local ignore = { LocalPlayer.Character }
    if crate then ignore[#ignore + 1] = crate end
    for _, inst in ipairs(RaycastIgnore) do ignore[#ignore + 1] = inst end
    local away = flat(root.Position - center)
    local start = away.Magnitude > 0.1 and math.atan2(away.Z, away.X) or 0
    local gap = math.max(size.X, size.Z) / 2 + 1.8
    for i = 0, 7 do
        local turn = math.ceil(i / 2) * (i % 2 == 0 and 1 or -1)
        local angle = start + turn * math.pi / 4
        local side = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * gap
        local floor = floorBelow(Vector3.new(side.X, bottom, side.Z), 2.5, 3.5, ignore)
        if floor and math.abs(floor - bottom) <= 2 and bodyFits(Vector3.new(side.X, floor, side.Z), ignore) then
            return Vector3.new(side.X, floor + height, side.Z), center
        end
    end
    return Vector3.new(center.X, center.Y + size.Y / 2 + height, center.Z), center
end

local function nearestCrate(root, now, limit)
    local best, bestD
    for prompt in pairs(Crates) do
        if not prompt.Parent or prompt:GetAttribute("Crate") ~= true then
            Crates[prompt] = nil
        elseif prompt.Enabled and not ((Loot.skip[prompt] or 0) > now) then
            local point = promptPoint(prompt)
            local d = point and (point - root.Position).Magnitude
            if d and d <= (limit or Loot.Range) and (not bestD or d < bestD) then best, bestD = prompt, d end
        end
    end
    return best, bestD
end

-- players drop materials by a chunk crafter on purpose to craft a chunk
local function byCrafter(point)
    for _, crafter in ipairs(chunkCrafters()) do
        local at = pivotOf(crafter)
        if at and (at - point).Magnitude <= 16 then return true end
    end
    return false
end

local function nearestDrop(root, limit)
    local folder = Workspace:FindFirstChild("WorldItemDrops")
    if not folder then return nil end
    local best, bestD
    for _, drop in ipairs(folder:GetChildren()) do
        local point = pivotOf(drop)
        local d = point and (point - root.Position).Magnitude
        -- one the game will not hand over after a few visits is left where it is
        if d and d <= limit and (Loot.visits[drop] or 0) < 4 and (not bestD or d < bestD)
            and not (Loot.LeaveCrafter and byCrafter(point)) then
            best, bestD = drop, d
        end
    end
    return best, bestD
end

-- Picks a dropped item up whichever way it wants: its prompt, a click
-- detector, or touching it.
local function collectDrop(drop, root)
    local parts = {}
    if drop:IsA("BasePart") then parts[1] = drop end
    for _, inst in ipairs(drop:GetDescendants()) do
        if inst:IsA("ProximityPrompt") then
            if inst.Enabled then firePrompt(inst) end
        elseif inst:IsA("ClickDetector") then
            if typeof(fireclickdetector) == "function" then pcall(fireclickdetector, inst) end
        elseif inst:IsA("BasePart") then
            parts[#parts + 1] = inst
        end
    end
    if typeof(firetouchinterest) == "function" then
        for i = 1, math.min(#parts, 4) do
            pcall(firetouchinterest, root, parts[i], 0)
            pcall(firetouchinterest, root, parts[i], 1)
        end
    end
end

local function lootStep(now, dt, char, root, hum)
    if now < (Loot.busyUntil or 0) then return true end
    if Loot.Crates then
        local prompt = nearestCrate(root, now, Loot.Travel and Loot.Range or 9)
        if prompt then
            local reach = math.max(math.min(prompt.MaxActivationDistance, 12) - 2, 4)
            local tries = (Loot.tries[prompt] or 0) + 1
            Loot.tries[prompt] = tries
            if tries > 3 then
                -- three goes and it is still shut: something is off with it, come back later
                Loot.tries[prompt] = 0
                Loot.skip[prompt] = now + 30
                return false
            end
            if (promptPoint(prompt) - root.Position).Magnitude > reach then
                local spot, center = crateSpot(prompt, root, hum)
                if not spot then return false end
                root.CFrame = CFrame.lookAt(spot, Vector3.new(center.X, spot.Y, center.Z))
                root.AssemblyLinearVelocity = Vector3.zero
            end
            -- the last go holds for the full time, in case this server times the hold
            local hold = tries == 3
            Loot.busyUntil = now + roundTrip() + 0.35 + (hold and prompt.HoldDuration or 0)
            task.delay(roundTrip(), function()
                if Unloaded or not prompt.Parent or not prompt.Enabled then return end
                firePrompt(prompt, hold)
                task.delay(0.3, function()
                    if not prompt.Parent or not prompt.Enabled then Loot.opened = Loot.opened + 1 end
                end)
            end)
            return true
        end
    end
    if Loot.Drops then
        local drop = nearestDrop(root, Loot.Travel and Loot.Range or 8)
        if drop then
            local point = pivotOf(drop)
            Loot.visits[drop] = (Loot.visits[drop] or 0) + 1
            if (point - root.Position).Magnitude > 3 then
                -- stand right on it so touching it counts too
                root.CFrame = CFrame.new(point + Vector3.new(0, standHeight(root, hum) - 0.5, 0)) * (root.CFrame - root.CFrame.Position)
                root.AssemblyLinearVelocity = Vector3.zero
            end
            Loot.busyUntil = now + roundTrip() + 0.3
            task.delay(roundTrip(), function()
                if Unloaded or not drop.Parent then return end
                local _, liveRoot = myCharacter()
                if liveRoot then collectDrop(drop, liveRoot) end
                task.delay(0.4, function()
                    if not drop.Parent then Loot.collected = Loot.collected + 1 end
                end)
            end)
            return true
        end
    end
    return false
end

--// manual fast swing -----------------------------------------------------------------------

local Holding = {}

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        Holding[input] = true
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    Holding[input] = nil
end))

-- While you hold click with a tool out, fast swing sends the same swing the
-- game does as soon as the server will take it, swapping between every tool
-- of the same kind in tool swap mode.
local function manualStep(now, char, hum)
    if not Swing.Fast or not Swing.Manual or next(Holding) == nil then return end
    local held = heldTool(char)
    if not held then return end
    local kind, candidates
    if held:GetAttribute("GatherTool") == true then
        kind = "gather"
        if Swing.Mode == "tool swap" and (isPickaxe(held) or isAxe(held)) then
            candidates = gatherToolsFor(isPickaxe(held) and "Rock" or "Tree")
        end
    elseif held:GetAttribute("ToolClick") then
        kind = "attack"
        if Swing.Mode == "tool swap" and held:GetAttribute("Sword") == true then candidates = swordTools() end
    else
        return
    end
    if not candidates or not candidates[1] then candidates = { held } end
    local tool = pickSwing(candidates, kind, now)
    if tool then swingWith(tool, kind, hum, now, candidates) end
end

--// driver ----------------------------------------------------------------------------------

-- a new body starts every job afresh, so nothing drags you back to where you died
track(LocalPlayer.CharacterAdded:Connect(function()
    Aura.home, Aura.target, Farm.target = nil, nil, nil
    Heal.tool, Heal.previous = nil, nil
    Fall.safe, Cages.target = nil, nil
end))

-- One job drives your character each frame, in this order: catching a fall,
-- getting out of the way of attacks, healing, eating, breaking cages, the
-- kill aura, repairs, the night, loot, and farming. Each hands over the
-- moment it has nothing to do.
local lastStep = os.clock()
local nextScan = 0
local lastError

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    local now = os.clock()
    local dt = math.min(now - lastStep, 0.1)
    lastStep = now
    local ok, err = pcall(function()
        reviveStep(now)
        local char, root, hum = myCharacter()
        if not char then return end
        if now >= nextScan then
            nextScan = now + 1
            scanResources()
        end
        if fallStep(now, char, root, hum) then return end
        local dodging = dodgeStep(now, char, root, hum)
        if dodging == "ranged" then return end
        if healStep(now, char, root, hum) then return end
        if eatStep(now, char, root, hum) then return end
        if cageStep(now, dt, char, root, hum) then return end
        if auraStep(now, dt, char, root, hum) then return end
        -- out of reach of a swing, nothing but the kill aura moves you back in
        if dodging then return end
        if repairStep(now, dt, char, root, hum) then return end
        if nightStep(now, dt, char, root, hum) then return end
        if lootStep(now, dt, char, root, hum) then return end
        if farmStep(now, dt, char, root, hum) then return end
        manualStep(now, char, hum)
    end)
    if not ok and err ~= lastError then
        lastError = err
        warn('[chunk] ' .. tostring(err))
    end
end))

--// movement --------------------------------------------------------------------------------

local flyVelocity, flyGyro
local Noclipped = {}

local function stopFly()
    if flyVelocity then flyVelocity:Destroy() flyVelocity = nil end
    if flyGyro then flyGyro:Destroy() flyGyro = nil end
end

local function startFly(root)
    stopFly()
    flyVelocity = Instance.new("BodyVelocity")
    flyVelocity.MaxForce = Vector3.new(1, 1, 1) * 9e9
    flyVelocity.Velocity = Vector3.zero
    flyVelocity.Parent = root
    flyGyro = Instance.new("BodyGyro")
    flyGyro.MaxTorque = Vector3.new(1, 1, 1) * 9e9
    flyGyro.P = 9e4
    flyGyro.CFrame = Camera.CFrame
    flyGyro.Parent = root
end

local function restoreCollisions()
    for part in pairs(Noclipped) do
        if part.Parent then part.CanCollide = true end
    end
    table.clear(Noclipped)
end

-- Flying follows the move stick or WASD along where the camera looks, so it
-- works the same on a phone; jump and shift go straight up and down.
track(RunService.Stepped:Connect(function()
    if Unloaded then return end
    local char, root, hum = myCharacter()
    if not char then return end

    if Move.Speed then hum.WalkSpeed = Move.SpeedValue end

    if Move.Noclip then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
                Noclipped[part] = true
            end
        end
    elseif next(Noclipped) then
        restoreCollisions()
    end

    if Move.Fly then
        if not flyVelocity or flyVelocity.Parent ~= root then startFly(root) end
        local cf = Camera.CFrame
        local look, right = cf.LookVector, cf.RightVector
        local moving = hum.MoveDirection
        local forward = moving:Dot(flat(look).Magnitude > 0 and flat(look).Unit or look)
        local sideways = moving:Dot(flat(right).Magnitude > 0 and flat(right).Unit or right)
        local direction = look * forward + right * sideways
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.yAxis end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then direction = direction - Vector3.yAxis end
        flyVelocity.Velocity = (direction.Magnitude > 0.05 and direction.Unit or Vector3.zero) * Move.FlySpeed
        flyGyro.CFrame = cf
    elseif flyVelocity then
        stopFly()
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloaded or not Move.InfiniteJump then return end
    local _, _, hum = myCharacter()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

--// teleports -------------------------------------------------------------------------------

-- point is where the thing is; exact means point is already where you stand
local function teleportTo(point, label, exact)
    local char, root, hum = myCharacter()
    if not char then return end
    if not point then
        notify('teleport', 'could not find ' .. label, 'warning', 3)
        return
    end
    root.CFrame = CFrame.new(exact and point or spotNear(point, root, hum, 4))
    root.AssemblyLinearVelocity = Vector3.zero
end

-- the nearest thing in the world that passes test
local function nearestWhere(folders, test)
    local _, root = myCharacter()
    local best, bestD
    for _, folder in ipairs(folders) do
        if folder then
            for _, inst in ipairs(folder:GetDescendants()) do
                if test(inst) then
                    local point = pivotOf(inst)
                    local d = point and root and (point - root.Position).Magnitude or 0
                    if point and (not bestD or d < bestD) then best, bestD = point, d end
                end
            end
        end
    end
    return best
end

local TeleportPlaces = {
    ['base'] = function()
        local _, root = myCharacter()
        return basePoint(root and root.Position)
    end,
    ['crafting table'] = function()
        return nearestWhere({ Workspace:FindFirstChild("GeneratedChunks"), Workspace:FindFirstChild("Builds") },
            function(inst) return inst:IsA("Model") and inst.Name == "CraftingTable" end)
    end,
    ['chunk crafter'] = function()
        return nearestWhere({ Workspace:FindFirstChild("GeneratedChunks") },
            function(inst) return inst:IsA("Model") and inst.Name == "ChunkCrafting" end)
    end,
    ['chunk forger'] = function()
        return nearestWhere({ Workspace:FindFirstChild("Builds") },
            function(inst) return inst:IsA("Model") and inst.Name == "Chunk Forger" end)
    end,
    ['chest'] = function()
        return nearestWhere({ Workspace:FindFirstChild("Builds") },
            function(inst) return inst:IsA("Model") and inst.Parent and inst.Parent.Name == "Builds" and inst.Name:find("Chest", 1, true) ~= nil end)
    end,
    ['loot crate'] = function()
        local _, root, hum = myCharacter()
        if not root then return nil end
        local prompt = nearestCrate(root, os.clock(), math.huge)
        if not prompt then return nil end
        return (crateSpot(prompt, root, hum)), true
    end,
    ['best ore'] = function()
        local _, root = myCharacter()
        local best, bestScore
        for _, model in ipairs(Resources) do
            local value = ORE_VALUE[model:GetAttribute("AssetName") or model.Name]
            local point = value and resourceAlive(model) and resourcePoint(model)
            if point and root then
                local score = (point - root.Position).Magnitude - value * 200
                if not bestScore or score < bestScore then best, bestScore = point, score end
            end
        end
        return best
    end,
}
local TELEPORT_ORDER = { 'base', 'crafting table', 'chunk crafter', 'chunk forger', 'chest', 'loot crate', 'best ore' }

--// esp ---------------------------------------------------------------------------------------

local EspObjects = {}

local COLORS = {
    enemy = Color3.fromRGB(255, 80, 80),
    hidden = Color3.fromRGB(190, 110, 255),
    animal = Color3.fromRGB(120, 220, 120),
    ore = Color3.fromRGB(90, 200, 255),
    crate = Color3.fromRGB(255, 205, 70),
    drop = Color3.fromRGB(240, 240, 240),
}

local function espMake(inst, adornee, withHighlight)
    local gui = Instance.new("BillboardGui")
    gui.Name = "esp"
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.ResetOnSpawn = false
    gui.Size = UDim2.fromOffset(170, 30)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    gui.Adornee = adornee
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 12
    label.TextStrokeTransparency = 0.35
    label.Text = ""
    label.Parent = gui
    gui.Parent = GuiRoot
    local obj = { gui = gui, label = label }
    if withHighlight then
        local highlight = Instance.new("Highlight")
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillTransparency = 0.75
        highlight.OutlineTransparency = 0.1
        highlight.Adornee = inst
        highlight.Parent = GuiRoot
        obj.highlight = highlight
    end
    EspObjects[inst] = obj
    return obj
end

local function espDrop(inst)
    local obj = EspObjects[inst]
    if not obj then return end
    EspObjects[inst] = nil
    pcall(function() obj.gui:Destroy() end)
    if obj.highlight then pcall(function() obj.highlight:Destroy() end) end
end

local function espShow(inst, adornee, text, color, withHighlight)
    local obj = EspObjects[inst] or espMake(inst, adornee, withHighlight)
    obj.label.Text = text
    obj.label.TextColor3 = color
    if obj.highlight then
        obj.highlight.FillColor = color
        obj.highlight.OutlineColor = color
    end
    obj.seen = true
end

local function espRefresh()
    for _, obj in pairs(EspObjects) do obj.seen = false end
    local _, root = myCharacter()
    local from = root and root.Position or (Camera and Camera.CFrame.Position) or Vector3.zero
    local function distanceText(point) return ("%d st"):format(math.floor((point - from).Magnitude + 0.5)) end

    local function creatures(folder, isAnimal)
        if not folder then return end
        for _, model in ipairs(folder:GetChildren()) do
            local alive, hum2 = creatureAlive(model)
            local part = alive and creatureRoot(model)
            if part then
                local hidden = model:GetAttribute("Hidden") == true
                local color = isAnimal and COLORS.animal or (hidden and COLORS.hidden or COLORS.enemy)
                local text = ("%s%s\n%d/%d · %s"):format(hidden and "hidden " or "", model.Name,
                    math.floor(hum2.Health + 0.5), math.floor(hum2.MaxHealth + 0.5), distanceText(part.Position))
                espShow(model, part, text, color, not isAnimal)
            end
        end
    end
    if Esp.Enemies then creatures(enemiesFolder(), false) end
    if Esp.Animals then creatures(animalsFolder(), true) end

    if Esp.Ores then
        for _, model in ipairs(Resources) do
            local name = model:GetAttribute("AssetName") or model.Name
            if ORE_VALUE[name] and resourceAlive(model) then
                local adornee = model:FindFirstChild("Hitbox", true) or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
                local point = resourcePoint(model)
                if adornee and point then espShow(model, adornee, displayName(name) .. "\n" .. distanceText(point), COLORS.ore, false) end
            end
        end
    end

    if Esp.Crates then
        for prompt in pairs(Crates) do
            local adornee = promptPart(prompt)
            local point = promptPoint(prompt)
            if adornee and point and prompt.Enabled then espShow(prompt, adornee, "crate\n" .. distanceText(point), COLORS.crate, false) end
        end
    end

    if Esp.Drops then
        local folder = Workspace:FindFirstChild("WorldItemDrops")
        if folder then
            for _, drop in ipairs(folder:GetChildren()) do
                local adornee = drop:IsA("BasePart") and drop or drop:FindFirstChildWhichIsA("BasePart", true)
                local point = pivotOf(drop)
                if adornee and point then
                    local name = drop:GetAttribute("ItemId") or drop.Name
                    espShow(drop, adornee, tostring(name) .. "\n" .. distanceText(point), COLORS.drop, false)
                end
            end
        end
    end

    for inst, obj in pairs(EspObjects) do
        if not obj.seen then espDrop(inst) end
    end
end

--// hud ---------------------------------------------------------------------------------------

local HudGui = Instance.new("ScreenGui")
HudGui.Name = "hud"
HudGui.IgnoreGuiInset = true
HudGui.ResetOnSpawn = false
HudGui.DisplayOrder = 40

local HudLabel = Instance.new("TextLabel")
HudLabel.AnchorPoint = Vector2.new(0.5, 0)
HudLabel.Position = UDim2.new(0.5, 0, 0, 44)
HudLabel.Size = UDim2.fromOffset(420, 44)
HudLabel.BackgroundTransparency = 1
HudLabel.Font = Enum.Font.GothamBold
HudLabel.TextSize = 14
HudLabel.TextStrokeTransparency = 0.35
HudLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
HudLabel.Text = ""
HudLabel.Parent = HudGui
HudGui.Parent = GuiRoot

local Watch = { day = nil, phase = nil, warnedDay = nil, bossActive = false }

local function clock(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end


local function hudRefresh()
    local state = dayState()
    local lines = {}
    local head = ""
    if state then
        local day = state:GetAttribute("Day") or 0
        local phase = state:GetAttribute("Phase") or "?"
        local left = (tonumber(state:GetAttribute("PhaseEndsAt")) or 0) - serverTime()
        head = ("Day %s · %s · %s left"):format(tostring(day), tostring(phase):lower(), clock(left))
        if state:GetAttribute("BloodMoon") then head = head .. " · blood moon" end
        if state:GetAttribute("Thunderstorm") then head = head .. " · storm" elseif state:GetAttribute("Rain") then head = head .. " · rain" end

        -- night warnings, once each per day
        if Night.Warn then
            if phase == "Day" and left <= 15 and left > 0 and Watch.warnedDay ~= day then
                Watch.warnedDay = day
                notify('night', 'night falls in 15 seconds', 'warning', 5)
            end
            if phase == "Night" and Watch.phase ~= "Night" and Watch.phase ~= nil then
                notify('night', ('night %s has started'):format(tostring(day)), 'warning', 5)
            end
        end
        Watch.phase = phase
    end
    lines[#lines + 1] = head

    local boss = ReplicatedStorage:FindFirstChild("BossState")
    local bossActive = boss and boss:GetAttribute("Active") == true
    if bossActive then
        lines[#lines + 1] = ("boss %s %d/%d"):format(tostring(boss:GetAttribute("BossName") or ""),
            math.floor((tonumber(boss:GetAttribute("Health")) or 0) + 0.5), math.floor((tonumber(boss:GetAttribute("MaxHealth")) or 0) + 0.5))
        if not Watch.bossActive and Night.Warn then notify('boss', tostring(boss:GetAttribute("BossName") or "a boss") .. ' is here', 'warning', 6) end
    end
    Watch.bossActive = bossActive and true or false

    local raid = ReplicatedStorage:FindFirstChild("HunterRaidState")
    if raid and raid:GetAttribute("Active") == true then
        lines[#lines + 1] = ("hunter raid wave %s/%s · %s left"):format(tostring(raid:GetAttribute("Wave") or 0),
            tostring(raid:GetAttribute("MaxWave") or 0), tostring(raid:GetAttribute("AliveCount") or 0))
    end

    local food = tonumber(LocalPlayer:GetAttribute("Food"))
    if food then lines[#lines + 1] = ("food %d%%"):format(math.floor(food / Config.FOOD_MAX * 100 + 0.5)) end

    HudLabel.Text = table.concat(lines, "\n")
    HudLabel.Visible = Esp.Hud
end

--// readouts ------------------------------------------------------------------------------------

local Readout = {}
local nextVisual = 0

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    local now = os.clock()
    if now < nextVisual then return end
    nextVisual = now + 0.25
    pcall(espRefresh)
    pcall(hudRefresh)
    if Readout.farm then
        Readout.farm.Set(Farm.Enabled and Farm.status or "off")
        Readout.broken.Set(Farm.broken)
        Readout.swings.Set(Swing.count)
        Readout.landed.Set(Farm.landed or 0)
        Readout.dps.Set(("%.1f"):format(damageRate(now)))
        Readout.aura.Set(Aura.Enabled and Aura.status or "off")
        Readout.kills.Set(Aura.kills)
        Readout.loot.Set(("%d crates opened, %d drops picked up"):format(Loot.opened, Loot.collected))
        local facing = "not turning you"
        if Farm.Face == "always" then
            facing = "facing targets"
        elseif Farm.Face == "auto" then
            facing = Farm.faceLearned and "facing targets (swings needed it)" or "not turning you yet"
        end
        Readout.facing.Set(facing)
        local cant = {}
        for asset, toolName in pairs(Farm.cantTool) do
            cant[#cant + 1] = ("%s (%s is not enough)"):format(displayName(asset), toolName)
        end
        table.sort(cant)
        Readout.cant.Set(cant[1] and table.concat(cant, ", ") or "nothing so far")
        Readout.dodged.Set(Dodge.dodged)
        Readout.saves.Set(Fall.saves)
        Readout.cages.Set(Cages.broken)
    end
end))

--// anti afk ------------------------------------------------------------------------------------

track(LocalPlayer.Idled:Connect(function()
    if Unloaded or not Misc.AntiAfk then return end
    pcall(function()
        local virtualUser = game:GetService("VirtualUser")
        virtualUser:CaptureController()
        virtualUser:ClickButton2(Vector2.new())
    end)
end))

--// unload --------------------------------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Farm.Enabled = false
    Aura.Enabled = false
    if Heal.tool and Remotes.UseItem then pcall(function() Remotes.UseItem:FireServer(nil) end) end
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    stopFly()
    restoreCollisions()
    local _, _, hum = myCharacter()
    if hum and Move.Speed then hum.WalkSpeed = 16 end
    for inst in pairs(EspObjects) do espDrop(inst) end
    pcall(function() HudGui:Destroy() end)
end

--// ui -----------------------------------------------------------------------------------------

local Window = Onyx:CreateWindow({
    Title = '100 days on chunk',
    SubTitle = 'assist',
    Folder = 'ChunkAssist',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(110, 200, 90),
})

-- closing the menu from its own settings tears the script down too
Onyx.OnUnload = unload

do
    local FarmTab = Window:CreateTab({ Title = 'farm', Default = true })
    local section = FarmTab:CreateSection('auto farm')

    section:Toggle({
        Title = 'auto farm',
        Description = 'chops trees and breaks rocks for you with your best axe and pickaxe, one after another',
        Flag = 'chunk_farm',
        Default = false,
        Callback = function(state) Farm.Enabled = state end,
    })

    section:Dropdown({
        Title = 'farm',
        Values = FARM_KINDS,
        Default = Farm.Kinds,
        Flag = 'chunk_farm_kinds',
        Callback = function(value) Farm.Kinds = value end,
    })

    section:Dropdown({
        Title = 'get to them by',
        Description = "teleport is instant, glide flies you over at the glide speed, walk walks, don't move only farms what is already in reach",
        Values = MOVE_MODES,
        Default = Farm.Move,
        Flag = 'chunk_farm_move',
        Callback = function(value) Farm.Move = value end,
    })

    section:Dropdown({
        Title = 'face target',
        Description = 'auto starts without turning you and only turns you to face targets if swings stop landing',
        Values = FACE_MODES,
        Default = Farm.Face,
        Flag = 'chunk_farm_face',
        Callback = function(value) Farm.Face = value end,
    })

    section:Toggle({
        Title = 'best ores first',
        Description = 'goes for diamond, gold, iron and coal ahead of closer trees and stone',
        Flag = 'chunk_farm_ores',
        Default = true,
        Callback = function(state) Farm.OresFirst = state end,
    })

    section:Slider({
        Title = 'farm radius',
        Description = 'how far from you it will go for a resource',
        Min = 20, Max = 1000, Increment = 10, Suffix = ' st',
        Default = Farm.Radius,
        Flag = 'chunk_farm_radius',
        Callback = function(value) Farm.Radius = tonumber(value) or Farm.Radius end,
    })

    section:Slider({
        Title = 'glide speed',
        Min = 20, Max = 200, Increment = 5, Suffix = ' st/s',
        Default = Move.GlideSpeed,
        Flag = 'chunk_glide_speed',
        Callback = function(value) Move.GlideSpeed = tonumber(value) or Move.GlideSpeed end,
    })

    section = FarmTab:CreateSection('fast swing')

    section:Toggle({
        Title = 'fast swing',
        Description = 'faster swings for auto farm, kill aura and your own clicks. the server times swings itself, so this works by swinging the moment it allows and by swapping tools',
        Flag = 'chunk_fast_swing2',
        Default = false,
        Callback = function(state) Swing.Fast = state end,
    })

    section:Dropdown({
        Title = 'how',
        Description = 'tool swap rotates every axe, pickaxe or sword you carry so each one swings on its own cooldown. on cooldown swings your best tool the instant its cooldown ends. spam sends at the slider speed',
        Values = SWING_MODES,
        Default = Swing.Mode,
        Flag = 'chunk_swing_mode',
        Callback = function(value) Swing.Mode = value end,
    })

    section:Slider({
        Title = 'spam every',
        Description = 'only used by spam',
        Min = 0.02, Max = 1, Increment = 0.01, Suffix = ' s',
        Default = Swing.Every,
        Flag = 'chunk_swing_every2',
        Callback = function(value) Swing.Every = tonumber(value) or Swing.Every end,
    })

    section:Toggle({
        Title = 'on your own clicks',
        Description = 'fast swing also speeds up swings while you hold click yourself',
        Flag = 'chunk_fast_manual',
        Default = true,
        Callback = function(state) Swing.Manual = state end,
    })

    section:Toggle({
        Title = 'move on during the last hit',
        Description = 'as the swing that breaks a resource goes out, heads for the next one instead of waiting to see it break, so the next swing is ready the moment the cooldown ends',
        Flag = 'chunk_farm_move_on',
        Default = true,
        Callback = function(state) Farm.MoveOn = state end,
    })

    section:Label({
        Title = 'Keep the old axes and pickaxes you replaced: tool swap needs two or more of a kind. Watch damage per second below; if tool swap is no higher than on cooldown, this server times every swing per player and nothing on your side can beat it.',
    })

    section = FarmTab:CreateSection('readout')
    Readout.farm = addStat(section, { Title = 'farming', Value = 'off' })
    Readout.broken = addStat(section, { Title = 'broken', Value = 0 })
    Readout.swings = addStat(section, { Title = 'swings sent', Value = 0 })
    Readout.landed = addStat(section, { Title = 'hits landing', Value = 0 })
    Readout.dps = addStat(section, { Title = 'damage per second', Value = 0 })
    Readout.facing = addStat(section, { Title = 'facing', Value = '-' })
    Readout.cant = addStat(section, { Title = "won't break", Value = 'nothing so far' })

    section:Button({
        Title = "forget what won't break",
        Description = 'lets the farm try everything again, say after the server changed its mind',
        Callback = function()
            table.clear(Farm.cant)
            table.clear(Farm.cantTool)
            table.clear(Farm.fails)
            table.clear(Farm.can)
        end,
    })
end

do
    local CombatTab = Window:CreateTab({ Title = 'combat' })
    local section = CombatTab:CreateSection('kill aura')

    section:Toggle({
        Title = 'kill aura',
        Description = 'fights the nearest enemy with your best sword. it takes over from farming while anything is close',
        Flag = 'chunk_aura',
        Default = false,
        Callback = function(state) Aura.Enabled = state end,
    })

    section:Toggle({
        Title = 'tp behind them',
        Description = 'teleports you behind your target every frame while you fight it, so it never gets to turn round and hit you',
        Flag = 'chunk_aura_stick',
        Default = true,
        Callback = function(state) Aura.Stick = state end,
    })

    section:Dropdown({
        Title = 'stand',
        Description = 'behind its back, hovering over its head, or circling it',
        Values = STICK_SPOTS,
        Default = Aura.Spot,
        Flag = 'chunk_aura_spot',
        Callback = function(value) Aura.Spot = value end,
    })

    section:Slider({
        Title = 'distance',
        Description = 'how far behind it you stand. raise it for big bosses',
        Min = 1, Max = 10, Increment = 0.5, Suffix = ' st',
        Default = Aura.Distance,
        Flag = 'chunk_aura_distance',
        Callback = function(value) Aura.Distance = tonumber(value) or Aura.Distance end,
    })

    section:Slider({
        Title = 'tp range',
        Description = 'how far away an enemy can be for tp behind to go after it',
        Min = 20, Max = 300, Increment = 10, Suffix = ' st',
        Default = Aura.StickRange,
        Flag = 'chunk_aura_stick_range',
        Callback = function(value) Aura.StickRange = tonumber(value) or Aura.StickRange end,
    })

    section:Slider({
        Title = 'swing range',
        Description = 'with tp behind off, only enemies this close get hit and you stay where you are',
        Min = 4, Max = 30, Increment = 1, Suffix = ' st',
        Default = Aura.Range,
        Flag = 'chunk_aura_range',
        Callback = function(value) Aura.Range = tonumber(value) or Aura.Range end,
    })

    section:Dropdown({
        Title = 'target',
        Description = 'nearest first, the weakest first to thin a crowd, or the one with the most health first for bosses',
        Values = PRIORITIES,
        Default = Aura.Priority,
        Flag = 'chunk_aura_priority',
        Callback = function(value) Aura.Priority = value end,
    })

    section:Dropdown({
        Title = 'face target',
        Description = 'with tp behind off: auto only turns you to face enemies if swings stop landing',
        Values = FACE_MODES,
        Default = Aura.Face,
        Flag = 'chunk_aura_face',
        Callback = function(value) Aura.Face = value end,
    })

    section:Toggle({
        Title = 'go back after fights',
        Description = 'puts you back where you were once nothing is left to fight',
        Flag = 'chunk_aura_return',
        Default = true,
        Callback = function(state) Aura.Return = state end,
    })

    section:Toggle({
        Title = 'hit animals too',
        Description = 'cows, chickens, pigs and the rest, for their drops',
        Flag = 'chunk_aura_animals',
        Default = false,
        Callback = function(state) Aura.Animals = state end,
    })

    section:Toggle({
        Title = 'equip sword',
        Description = 'switches to your best sword to fight. off uses whatever you are holding',
        Flag = 'chunk_aura_sword',
        Default = true,
        Callback = function(state) Aura.AutoSword = state end,
    })

    section = CombatTab:CreateSection('readout')
    Readout.aura = addStat(section, { Title = 'fighting', Value = 'off' })
    Readout.kills = addStat(section, { Title = 'kills', Value = 0 })
end

do
    local SurvivalTab = Window:CreateTab({ Title = 'survival' })
    local section = SurvivalTab:CreateSection('food and health')

    section:Toggle({
        Title = 'auto eat',
        Description = 'eats the food that best covers what you are missing when you drop below the line, then puts your tool back',
        Flag = 'chunk_eat',
        Default = false,
        Callback = function(state) Food.Enabled = state end,
    })

    section:Slider({
        Title = 'eat below',
        Min = 10, Max = 95, Increment = 5, Suffix = '%',
        Default = Food.Below,
        Flag = 'chunk_eat_below',
        Callback = function(value) Food.Below = tonumber(value) or Food.Below end,
    })

    section:Toggle({
        Title = 'auto bandage',
        Description = 'heals you with a bandage when your health drops below the line, then puts your tool back',
        Flag = 'chunk_heal',
        Default = false,
        Callback = function(state) Heal.Enabled = state end,
    })

    section:Slider({
        Title = 'bandage below',
        Min = 10, Max = 90, Increment = 5, Suffix = '%',
        Default = Heal.Below,
        Flag = 'chunk_heal_below',
        Callback = function(value) Heal.Below = tonumber(value) or Heal.Below end,
    })

    section = SurvivalTab:CreateSection('base')

    section:Toggle({
        Title = 'auto repair',
        Description = 'mends damaged builds with your repair hammer (the totem hammer for totems)',
        Flag = 'chunk_repair',
        Default = false,
        Callback = function(state) Repair.Enabled = state end,
    })

    section:Toggle({
        Title = 'teleport to repair',
        Description = 'goes to damaged builds up to the repair range instead of only fixing ones within reach',
        Flag = 'chunk_repair_travel',
        Default = false,
        Callback = function(state) Repair.Travel = state end,
    })

    section:Slider({
        Title = 'repair range',
        Min = 20, Max = 300, Increment = 10, Suffix = ' st',
        Default = Repair.Range,
        Flag = 'chunk_repair_range',
        Callback = function(value) Repair.Range = tonumber(value) or Repair.Range end,
    })

    section:Toggle({
        Title = 'go to base at night',
        Description = 'teleports you back to your nearest campfire when night falls, and pauses farming until morning',
        Flag = 'chunk_night_base',
        Default = false,
        Callback = function(state) Night.Base = state end,
    })

    section:Toggle({
        Title = 'keep farming at night',
        Description = 'lets auto farm carry on through the night anyway',
        Flag = 'chunk_farm_night',
        Default = false,
        Callback = function(state) Farm.AtNight = state end,
    })

    section = SurvivalTab:CreateSection('revive')

    section:Toggle({
        Title = 'auto revive',
        Description = 'uses your free revive when you die, then your saved ones. never buys any',
        Flag = 'chunk_revive',
        Default = false,
        Callback = function(state) Revive.Enabled = state end,
    })

    section:Toggle({
        Title = 'use saved revives',
        Flag = 'chunk_revive_saved',
        Default = true,
        Callback = function(state) Revive.UseSaved = state end,
    })

    section = SurvivalTab:CreateSection('alerts')

    section:Toggle({
        Title = 'night and boss alerts',
        Description = 'a heads up 15 seconds before night, when night starts and when a boss shows up',
        Flag = 'chunk_warn',
        Default = true,
        Callback = function(state) Night.Warn = state end,
    })
end

do
    local LootTab = Window:CreateTab({ Title = 'loot' })
    local section = LootTab:CreateSection('loot')

    section:Toggle({
        Title = 'open crates',
        Description = 'lands right beside each crate, on the floor it sits on, and opens it without the hold. what is inside goes straight into your inventory',
        Flag = 'chunk_crates',
        Default = false,
        Callback = function(state) Loot.Crates = state end,
    })

    section:Toggle({
        Title = 'collect drops',
        Description = 'picks up items lying on the ground: stands on each one and uses its prompt or touches it, whichever the game wants',
        Flag = 'chunk_drops',
        Default = false,
        Callback = function(state) Loot.Drops = state end,
    })

    section:Toggle({
        Title = 'teleport to loot',
        Description = 'off only opens and picks up what is already within reach',
        Flag = 'chunk_loot_travel',
        Default = true,
        Callback = function(state) Loot.Travel = state end,
    })

    section:Slider({
        Title = 'loot range',
        Min = 10, Max = 500, Increment = 10, Suffix = ' st',
        Default = Loot.Range,
        Flag = 'chunk_loot_range2',
        Callback = function(value) Loot.Range = tonumber(value) or Loot.Range end,
    })

    section:Toggle({
        Title = 'leave drops at the chunk crafter',
        Description = 'materials dropped by a chunk crafter are there to craft a chunk, so they are left alone',
        Flag = 'chunk_loot_crafter',
        Default = true,
        Callback = function(state) Loot.LeaveCrafter = state end,
    })

    section = LootTab:CreateSection('readout')
    Readout.loot = addStat(section, { Title = 'looted', Value = '-' })
end

do
    local ExtraTab = Window:CreateTab({ Title = 'extra' })
    local section = ExtraTab:CreateSection('anti hit')

    section:Toggle({
        Title = 'anti hit',
        Description = 'steps you out of the way of enemy swings, thrown things, spears, lightning and the cages and tombs bosses drop, onto solid ground, then carries on',
        Flag = 'chunk_dodge',
        Default = false,
        Callback = function(state) Dodge.Enabled = state end,
    })

    section:Toggle({
        Title = 'dodge swings',
        Description = 'only when you are in front of the enemy swinging, so standing behind one with the kill aura keeps you fighting',
        Flag = 'chunk_dodge_melee',
        Default = true,
        Callback = function(state) Dodge.Melee = state end,
    })

    section:Toggle({
        Title = 'dodge thrown and dropped things',
        Description = 'rocks, spears, lightning, the beast cage and the pharaoh tomb, from where and when the game says they land',
        Flag = 'chunk_dodge_ranged',
        Default = true,
        Callback = function(state) Dodge.Ranged = state end,
    })

    Readout.dodged = addStat(section, { Title = 'dodged', Value = 0 })

    section = ExtraTab:CreateSection('anti fall')

    section:Toggle({
        Title = 'anti fall',
        Description = 'if you go off an edge with nothing below, puts you straight back on the last ground you stood on',
        Flag = 'chunk_anti_fall',
        Default = false,
        Callback = function(state) Fall.Enabled = state end,
    })

    Readout.saves = addStat(section, { Title = 'saved', Value = 0 })

    section = ExtraTab:CreateSection('cages')

    section:Toggle({
        Title = 'break cages',
        Description = "breaks the beast's cage when it drops on you or a teammate within 80 studs, with whatever tool it takes",
        Flag = 'chunk_cages',
        Default = false,
        Callback = function(state) Cages.Enabled = state end,
    })

    Readout.cages = addStat(section, { Title = 'cages broken', Value = 0 })
end

do
    local MoveTab = Window:CreateTab({ Title = 'move' })
    local section = MoveTab:CreateSection('movement')

    section:Toggle({
        Title = 'speed',
        Description = 'your walk speed, with no food cost the way sprinting has',
        Flag = 'chunk_speed',
        Default = false,
        Callback = function(state)
            Move.Speed = state
            if not state then
                local _, _, hum = myCharacter()
                if hum then hum.WalkSpeed = 16 end
            end
        end,
    })

    section:Slider({
        Title = 'walk speed',
        Min = 16, Max = 120, Increment = 1,
        Default = Move.SpeedValue,
        Flag = 'chunk_speed_value',
        Callback = function(value) Move.SpeedValue = tonumber(value) or Move.SpeedValue end,
    })

    section:Toggle({
        Title = 'fly',
        Description = 'moves where the camera looks with the move stick or WASD. space and shift go up and down',
        Flag = 'chunk_fly',
        Default = false,
        Callback = function(state) Move.Fly = state end,
    })

    section:Slider({
        Title = 'fly speed',
        Min = 10, Max = 250, Increment = 5,
        Default = Move.FlySpeed,
        Flag = 'chunk_fly_speed',
        Callback = function(value) Move.FlySpeed = tonumber(value) or Move.FlySpeed end,
    })

    section:Toggle({
        Title = 'noclip',
        Flag = 'chunk_noclip',
        Default = false,
        Callback = function(state) Move.Noclip = state end,
    })

    section:Toggle({
        Title = 'infinite jump',
        Flag = 'chunk_inf_jump',
        Default = false,
        Callback = function(state) Move.InfiniteJump = state end,
    })

    section = MoveTab:CreateSection('teleport')
    for _, place in ipairs(TELEPORT_ORDER) do
        section:Button({
            Title = 'teleport to ' .. place,
            Callback = function()
                local point, exact = TeleportPlaces[place]()
                teleportTo(point, place, exact)
            end,
        })
    end
end

do
    local VisualTab = Window:CreateTab({ Title = 'visual' })
    local section = VisualTab:CreateSection('esp')

    section:Toggle({
        Title = 'enemies',
        Description = 'name, health and distance. hidden ones (hunters, mages) show in purple',
        Flag = 'chunk_esp_enemies',
        Default = false,
        Callback = function(state) Esp.Enemies = state end,
    })

    section:Toggle({
        Title = 'animals',
        Flag = 'chunk_esp_animals',
        Default = false,
        Callback = function(state) Esp.Animals = state end,
    })

    section:Toggle({
        Title = 'ores',
        Description = 'coal, iron, gold and diamond in the chunks around you',
        Flag = 'chunk_esp_ores',
        Default = false,
        Callback = function(state) Esp.Ores = state end,
    })

    section:Toggle({
        Title = 'loot crates',
        Flag = 'chunk_esp_crates',
        Default = false,
        Callback = function(state) Esp.Crates = state end,
    })

    section:Toggle({
        Title = 'dropped items',
        Flag = 'chunk_esp_drops',
        Default = false,
        Callback = function(state) Esp.Drops = state end,
    })

    section = VisualTab:CreateSection('hud')

    section:Toggle({
        Title = 'day and night hud',
        Description = 'day, time left until night or morning, weather, the boss and hunter raids, and your food',
        Flag = 'chunk_hud',
        Default = true,
        Callback = function(state) Esp.Hud = state end,
    })
end

do
    local SessionTab = Window:CreateTab({ Title = 'session' })
    local section = SessionTab:CreateSection('session')

    section:Toggle({
        Title = 'anti afk',
        Description = 'stops Roblox kicking you for being idle while things run on their own',
        Flag = 'chunk_anti_afk',
        Default = true,
        Callback = function(state) Misc.AntiAfk = state end,
    })

    section:Button({
        Title = 'unload',
        Callback = function()
            unload()
            Onyx:Unload()
        end,
    })

    section:Paragraph({
        Title = 'unload',
        Text = 'Stops everything, puts your speed and collisions back, clears the esp and the hud, then closes the menu.',
    })
end

scanResources()

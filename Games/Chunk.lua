--// 100 Days on Chunk! -- auto farm, fast swing, kill aura, survival helpers,
--// loot, movement, teleports and esp.
--
-- What the game's own client scripts show:
--  * Gathering is GatherHit:FireServer() and a tool swing is MouseClick:FireServer(),
--    both with no arguments at all. The server works out what you hit; the one
--    rule the client knows is GameConfig.GATHER_DISTANCE (12 studs). The game
--    itself fires them on a loop at the tool's cooldown while you hold click.
--  * Resources are models under GeneratedChunks.<chunk>.Resources carrying
--    ResourceType (Tree / Rock), Health and Depleted. Axes cut trees, pickaxes
--    break rocks.
--  * Enemies (Workspace.Enemies) and animals (Workspace.Animals) keep their
--    health on a Humanoid named Humanoid2.
--  * Food is the player's Food attribute; eating is Eat:FireServer(foodTool)
--    with a tool that has a Food attribute in your hands.
--  * Builds sit in Workspace.Builds with a BuildHumanoid, and
--    RepairBuild:InvokeServer(build) mends one while a Repair Hammer is held.
--  * The death screen revives through ClaimFreeRevive: free once, then saved
--    credits with "Saved".

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
    RepairBuild = remote("RepairBuild"),
    ClaimFreeRevive = remote("ClaimFreeRevive"),
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

    target = nil,
    skip = {},
    swings = 0,
    progressAt = 0,
    faceLearned = false,
    status = "off",
    broken = 0,
}

local Swing = {
    Fast = false,
    Every = 0.15,
    Manual = true,
    count = 0,
}

local Aura = {
    Enabled = false,
    Range = 12,
    Animals = false,
    Face = "auto",
    Hunt = false,
    HuntRange = 60,
    AutoSword = true,

    swings = 0,
    progressAt = 0,
    faceLearned = false,
    status = "off",
    kills = 0,
}

local Food = { Enabled = false, Below = 40, eaten = 0 }
local Repair = { Enabled = false, Travel = false, Range = 60, done = 0 }
local Revive = { Enabled = false, UseSaved = true }
local Loot = { Crates = false, Drops = false, Range = 80, Travel = true, visits = {} }
local Night = { Base = false, Warn = true }

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

-- One round trip: a teleport has to reach the server before a swing from the
-- new spot can count.
local function roundTrip()
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(ping) == "number" and ping > 0 then return math.min(ping * 2, 0.6) end
    return 0.15
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

-- the strongest tool that passes test: gather tools by the game's own damage
-- numbers, anything else by the material in its name
local function bestTool(test)
    local best, bestRank
    for _, tool in ipairs(allTools()) do
        if test(tool) then
            local stats = Config.GATHER_TOOL_STATS[tool.Name]
            local rank = (stats and tonumber(stats.damage)) or tierOf(tool)
            if not bestRank or rank > bestRank then best, bestRank = tool, rank end
        end
    end
    return best
end

local function gatherToolFor(kind)
    if kind == "Tree" then
        return bestTool(function(tool) return tool:GetAttribute("GatherTool") == true and isAxe(tool) end)
    end
    return bestTool(function(tool) return tool:GetAttribute("GatherTool") == true and isPickaxe(tool) end)
end

local function swordTool()
    return bestTool(function(tool) return tool:GetAttribute("Sword") == true end)
end

local function heldTool(char)
    return char and char:FindFirstChildOfClass("Tool") or nil
end

local function equip(tool, hum)
    if not tool or tool.Parent == LocalPlayer.Character then return tool end
    pcall(function() hum:EquipTool(tool) end)
    return tool
end

--// swinging --------------------------------------------------------------------------

-- the gap between swings: the fast swing slider when that is on, otherwise
-- the same wait the game's own loops use
local function swingGap(tool, kind)
    if Swing.Fast then return Swing.Every end
    if kind == "gather" then
        local stats = Config.GATHER_TOOL_STATS[tool.Name]
        local gap = (stats and tonumber(stats.cooldown)) or tonumber(tool:GetAttribute("SwingCooldown")) or 0.6
        if isAxe(tool) and LocalPlayer:GetAttribute("EquippedClass") == "Lumberjack" then gap = gap * 0.9 end
        return math.max(0.05, gap) + 0.08
    end
    return math.max(0.05, tonumber(tool:GetAttribute("AttackCooldown")) or 0.5) + 0.08
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

--// world -------------------------------------------------------------------------------

local Resources = {}
local RaycastIgnore = {}

-- every tree and rock the game has loaded around you
local function scanResources()
    local list = {}
    local ignore = {}
    local function take(folder)
        ignore[#ignore + 1] = folder
        for _, model in ipairs(folder:GetChildren()) do
            local kind = model:GetAttribute("ResourceType")
            if kind == "Tree" or kind == "Rock" then list[#list + 1] = model end
        end
    end
    local chunks = Workspace:FindFirstChild("GeneratedChunks")
    if chunks then
        for _, chunk in ipairs(chunks:GetChildren()) do
            local folder = chunk:FindFirstChild("Resources")
            if folder then take(folder) end
        end
    end
    local loose = Workspace:FindFirstChild("Resources")
    if loose then take(loose) end
    for _, name in ipairs({ "Enemies", "Animals", "WorldItemDrops" }) do
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
end

local function resourcePoint(model)
    local hitbox = model:FindFirstChild("Hitbox")
    if hitbox and hitbox:IsA("BasePart") then return hitbox.Position end
    return pivotOf(model)
end

local function resourceAlive(model)
    return model.Parent ~= nil and model:GetAttribute("Depleted") ~= true
        and (tonumber(model:GetAttribute("Health")) or 1) > 0
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- A spot gap studs short of a point, on your side of it and standing on the
-- ground (trees, balls of leaves and creatures do not count as ground).
local function spotNear(point, root, hum, gap)
    local away = flat(root.Position - point)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
    local base = point + away * gap
    rayParams.FilterDescendantsInstances = RaycastIgnore
    local hit = Workspace:Raycast(Vector3.new(base.X, point.Y + 40, base.Z), Vector3.new(0, -140, 0), rayParams)
    local height = (hum.HipHeight > 0 and hum.HipHeight or 2) + root.Size.Y / 2 + 0.3
    if hit then return Vector3.new(base.X, hit.Position.Y + height, base.Z) end
    return Vector3.new(base.X, math.max(root.Position.Y, point.Y), base.Z)
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

local function creatureAlive(model)
    local hum2 = model:FindFirstChild("Humanoid2")
    return hum2 ~= nil and hum2:IsA("Humanoid") and hum2.Health > 0, hum2
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

--// auto farm ------------------------------------------------------------------------------

local function wantKind(model)
    local kind = model:GetAttribute("ResourceType")
    if Farm.Kinds == "trees" then return kind == "Tree" end
    if Farm.Kinds == "rocks" then return kind == "Rock" end
    if Farm.Kinds == "ores only" then
        return kind == "Rock" and ORE_VALUE[model:GetAttribute("AssetName") or model.Name] ~= nil
    end
    return true
end

-- how close you stand to swing: a little inside the game's gather distance
local function gatherReach()
    return Config.GATHER_DISTANCE - 2.5
end

-- the nearest living resource you have a tool for, ores pulled forward when
-- ores come first
local function farmTarget(root, tools, now)
    local best, bestScore
    for _, model in ipairs(Resources) do
        if resourceAlive(model) and wantKind(model) and tools[model:GetAttribute("ResourceType")]
            and not ((Farm.skip[model] or 0) > now) then
            local point = resourcePoint(model)
            if point then
                local d = flatDistance(point, root.Position)
                local reach = Farm.Move == "don't move" and gatherReach() or Farm.Radius
                if d <= reach then
                    local score = d
                    if Farm.OresFirst then
                        score = score - (ORE_VALUE[model:GetAttribute("AssetName") or model.Name] or 0) * 60
                    end
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
        state.progressAt = now
        state.misses = 0
        state.landed = (state.landed or 0) + 1
    elseif state.swings >= 3 and now - state.progressAt > 1.5 then
        state.progressAt = now
        state.misses = (state.misses or 0) + 1
        if mode == "auto" and not state.faceLearned then
            state.faceLearned = true
            return "face"
        end
        return "skip"
    end
    state.lastHealth = health
    return nil
end

local function farmStep(now, dt, char, root, hum)
    if not Farm.Enabled then
        Farm.status = "off"
        return false
    end

    local tools = { Tree = gatherToolFor("Tree"), Rock = gatherToolFor("Rock") }
    if not tools.Tree and not tools.Rock then
        Farm.status = "no axe or pickaxe"
        return false
    end

    -- the current target is kept until it breaks, gets skipped or falls out of
    -- the radius, so a closer tree never pulls you off one half chopped
    local target = Farm.target
    local keep = target and resourceAlive(target) and not ((Farm.skip[target] or 0) > now)
        and tools[target:GetAttribute("ResourceType")] ~= nil and wantKind(target)
    if keep then
        local point = resourcePoint(target)
        keep = point ~= nil and flatDistance(point, root.Position) <= math.max(Farm.Radius, gatherReach())
    end
    if not keep then
        if target and not resourceAlive(target) then Farm.broken = Farm.broken + 1 end
        target = farmTarget(root, tools, now)
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

    local kind = target:GetAttribute("ResourceType")
    local tool = equip(tools[kind], hum)
    local point = resourcePoint(target)
    if not tool or not point then return false end

    local name = target:GetAttribute("AssetName") or target.Name
    if flatDistance(point, root.Position) > gatherReach() then
        if Farm.Move == "don't move" then
            Farm.target = nil
            return false
        end
        Farm.status = ("going to %s"):format(name)
        local spot = spotNear(point, root, hum, 4.5)
        if not goTo(spot, Farm.Move, root, hum, dt, now, Farm) then return true end
    end
    if now < (Farm.settleUntil or 0) then return true end

    if Farm.Face == "always" or (Farm.Face == "auto" and Farm.faceLearned) then face(root, point) end

    if now >= (Farm.nextSwing or 0) then
        Farm.nextSwing = now + swingGap(tool, "gather")
        swing(tool, "gather")
        Farm.swings = (Farm.swings or 0) + 1
    end

    local health = tonumber(target:GetAttribute("Health")) or 0
    local verdict = checkProgress(Farm, health, now, Farm.Face)
    if verdict == "skip" then
        Farm.skip[target] = now + 20
        Farm.target = nil
    end
    Farm.status = ("%s %d/%d"):format(name, math.floor(health + 0.5),
        math.floor((tonumber(target:GetAttribute("MaxHealth")) or health) + 0.5))
    return true
end

--// kill aura -------------------------------------------------------------------------------

local function auraTarget(root)
    local best, bestD
    local limit = Aura.Hunt and math.max(Aura.HuntRange, Aura.Range) or Aura.Range
    local function scan(folder)
        for _, model in ipairs(folder:GetChildren()) do
            local alive = creatureAlive(model)
            local part = alive and creatureRoot(model)
            if part then
                local d = (part.Position - root.Position).Magnitude
                if d <= limit and (not bestD or d < bestD) then best, bestD = model, d end
            end
        end
    end
    local enemies = enemiesFolder()
    if enemies then scan(enemies) end
    if Aura.Animals then
        local animals = animalsFolder()
        if animals then scan(animals) end
    end
    return best, bestD
end

local function auraStep(now, dt, char, root, hum)
    if not Aura.Enabled then
        Aura.status = "off"
        return false
    end
    local target, distance = auraTarget(root)
    if not target then
        Aura.status = "nothing in range"
        Aura.target = nil
        return false
    end
    local tool = Aura.AutoSword and swordTool() or heldTool(char)
    if not tool then
        Aura.status = "no sword"
        return false
    end
    equip(tool, hum)

    if target ~= Aura.target then
        Aura.target = target
        Aura.lastHealth = nil
        Aura.swings = 0
        Aura.progressAt = now
    end

    local part = creatureRoot(target)
    if distance > Aura.Range then
        local spot = spotNear(part.Position, root, hum, 3)
        if not goTo(spot, "teleport", root, hum, dt, now, Aura) then return true end
    end
    if now < (Aura.settleUntil or 0) then return true end

    if Aura.Face == "always" or (Aura.Face == "auto" and Aura.faceLearned) then face(root, part.Position) end

    if now >= (Aura.nextSwing or 0) then
        Aura.nextSwing = now + swingGap(tool, "attack")
        swing(tool, "attack")
        Aura.swings = (Aura.swings or 0) + 1
    end

    local _, hum2 = creatureAlive(target)
    local health = hum2 and hum2.Health or 0
    if health <= 0 then
        Aura.kills = Aura.kills + 1
        Aura.target = nil
    elseif checkProgress(Aura, health, now, Aura.Face) == "skip" then
        -- nothing lands on it from here; the next one gets a turn
        Aura.target = nil
    end
    Aura.status = ("%s %d hp · %d st"):format(target.Name, math.floor(health + 0.5), math.floor(distance + 0.5))
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

local function hammerFor(totem)
    return bestTool(function(tool)
        return tool:GetAttribute("RepairTool") == true and (tool:GetAttribute("TotemRepairTool") == true) == totem
    end)
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

local function promptPoint(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    return parent and pivotOf(parent) or nil
end

local function nearestCrate(root)
    local best, bestD
    for prompt in pairs(Crates) do
        if not prompt.Parent or prompt:GetAttribute("Crate") ~= true then
            Crates[prompt] = nil
        elseif prompt.Enabled then
            local point = promptPoint(prompt)
            local d = point and (point - root.Position).Magnitude
            if d and d <= Loot.Range and (not bestD or d < bestD) then best, bestD = prompt, d end
        end
    end
    return best, bestD
end

local function nearestDrop(root)
    local folder = Workspace:FindFirstChild("WorldItemDrops")
    if not folder then return nil end
    local best, bestD
    for _, drop in ipairs(folder:GetChildren()) do
        local point = pivotOf(drop)
        local d = point and (point - root.Position).Magnitude
        -- one the game will not hand over after a few visits is left where it is
        if d and d <= Loot.Range and d > 3 and (Loot.visits[drop] or 0) < 4 and (not bestD or d < bestD) then
            best, bestD = drop, d
        end
    end
    return best, bestD
end

local function lootStep(now, dt, char, root, hum)
    if now < (Loot.busyUntil or 0) then return true end
    if Loot.Crates and typeof(fireproximityprompt) == "function" then
        local prompt, distance = nearestCrate(root)
        if prompt then
            local point = promptPoint(prompt)
            local reach = math.max(prompt.MaxActivationDistance - 2, 4)
            if distance > reach then
                if not Loot.Travel then return false end
                goTo(spotNear(point, root, hum, 3), "teleport", root, hum, dt, now, Loot)
            end
            Loot.busyUntil = now + math.max(prompt.HoldDuration, 0) + roundTrip() + 0.2
            task.delay(roundTrip(), function()
                if Unloaded or not prompt.Parent then return end
                pcall(fireproximityprompt, prompt, 1, true)
            end)
            return true
        end
    end
    if Loot.Drops and Loot.Travel then
        local drop = nearestDrop(root)
        if drop then
            Loot.visits[drop] = (Loot.visits[drop] or 0) + 1
            goTo(pivotOf(drop) + Vector3.new(0, 3, 0), "teleport", root, hum, dt, now, Loot)
            Loot.busyUntil = now + 0.25
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

-- while you hold click with a tool out, fast swing sends the same swing the
-- game does, just as often as the slider says
local function manualStep(now, char)
    if not Swing.Fast or not Swing.Manual or next(Holding) == nil then return end
    local tool = heldTool(char)
    if not tool or now < (Swing.nextManual or 0) then return end
    local gather = tool:GetAttribute("GatherTool") == true
    if not gather and not tool:GetAttribute("ToolClick") then return end
    Swing.nextManual = now + Swing.Every
    swing(tool, gather and "gather" or "attack")
end

--// driver ----------------------------------------------------------------------------------

-- One job drives your character each frame, in this order: eating, then the
-- kill aura, repairs, the night, loot, and farming. Each hands over the moment
-- it has nothing to do.
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
        if eatStep(now, char, root, hum) then return end
        if auraStep(now, dt, char, root, hum) then return end
        if repairStep(now, dt, char, root, hum) then return end
        if nightStep(now, dt, char, root, hum) then return end
        if lootStep(now, dt, char, root, hum) then return end
        if farmStep(now, dt, char, root, hum) then return end
        manualStep(now, char)
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

local function teleportTo(point, label)
    local char, root, hum = myCharacter()
    if not char then return end
    if not point then
        notify('teleport', 'could not find ' .. label, 'warning', 3)
        return
    end
    root.CFrame = CFrame.new(spotNear(point, root, hum, 4))
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
        local _, root = myCharacter()
        if not root then return nil end
        local saved = Loot.Range
        Loot.Range = math.huge
        local prompt = nearestCrate(root)
        Loot.Range = saved
        return prompt and promptPoint(prompt)
    end,
}
local TELEPORT_ORDER = { 'base', 'crafting table', 'chunk crafter', 'chunk forger', 'chest', 'loot crate' }

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
                local adornee = model:FindFirstChild("Hitbox") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                local point = resourcePoint(model)
                if adornee and point then espShow(model, adornee, name .. "\n" .. distanceText(point), COLORS.ore, false) end
            end
        end
    end

    if Esp.Crates then
        for prompt in pairs(Crates) do
            local parent = prompt.Parent
            local adornee = parent and (parent:IsA("BasePart") and parent or parent:FindFirstChildWhichIsA("BasePart", true))
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

local function serverNow()
    local ok, now = pcall(function() return Workspace:GetServerTimeNow() end)
    return ok and now or os.time()
end

local function hudRefresh()
    local state = dayState()
    local lines = {}
    local head = ""
    if state then
        local day = state:GetAttribute("Day") or 0
        local phase = state:GetAttribute("Phase") or "?"
        local left = (tonumber(state:GetAttribute("PhaseEndsAt")) or 0) - serverNow()
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
        Readout.aura.Set(Aura.Enabled and Aura.status or "off")
        Readout.kills.Set(Aura.kills)
        local facing = "not turning you"
        if Farm.Face == "always" then
            facing = "facing targets"
        elseif Farm.Face == "auto" then
            facing = Farm.faceLearned and "facing targets (swings needed it)" or "not turning you yet"
        end
        Readout.facing.Set(facing)
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
        Description = 'swings as often as the slider says instead of waiting out the tool cooldown. works for auto farm, kill aura and your own clicks',
        Flag = 'chunk_fast_swing',
        Default = false,
        Callback = function(state) Swing.Fast = state end,
    })

    section:Slider({
        Title = 'swing every',
        Description = 'the game waits about 0.5 to 0.6 s between swings',
        Min = 0.05, Max = 1, Increment = 0.01, Suffix = ' s',
        Default = Swing.Every,
        Flag = 'chunk_swing_every',
        Callback = function(value) Swing.Every = tonumber(value) or Swing.Every end,
    })

    section:Toggle({
        Title = 'on your own clicks',
        Description = 'fast swing also speeds up swings while you hold click yourself',
        Flag = 'chunk_fast_manual',
        Default = true,
        Callback = function(state) Swing.Manual = state end,
    })

    section = FarmTab:CreateSection('readout')
    section:Label({
        Title = 'If hits landing stops keeping up with swings sent once fast swing is on, the server is holding you to its own cooldown and a faster setting will not help.',
    })
    Readout.farm = addStat(section, { Title = 'farming', Value = 'off' })
    Readout.broken = addStat(section, { Title = 'broken', Value = 0 })
    Readout.swings = addStat(section, { Title = 'swings sent', Value = 0 })
    Readout.landed = addStat(section, { Title = 'hits landing', Value = 0 })
    Readout.facing = addStat(section, { Title = 'facing', Value = '-' })
end

do
    local CombatTab = Window:CreateTab({ Title = 'combat' })
    local section = CombatTab:CreateSection('kill aura')

    section:Toggle({
        Title = 'kill aura',
        Description = 'swings your best sword at the nearest enemy in range. it takes over from farming while anything is close',
        Flag = 'chunk_aura',
        Default = false,
        Callback = function(state) Aura.Enabled = state end,
    })

    section:Slider({
        Title = 'range',
        Min = 4, Max = 30, Increment = 1, Suffix = ' st',
        Default = Aura.Range,
        Flag = 'chunk_aura_range',
        Callback = function(value) Aura.Range = tonumber(value) or Aura.Range end,
    })

    section:Dropdown({
        Title = 'face target',
        Description = 'auto only turns you to face enemies if swings stop landing',
        Values = FACE_MODES,
        Default = Aura.Face,
        Flag = 'chunk_aura_face',
        Callback = function(value) Aura.Face = value end,
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

    section:Toggle({
        Title = 'teleport to enemies',
        Description = 'goes after enemies further out than the range, up to the hunt range',
        Flag = 'chunk_aura_hunt',
        Default = false,
        Callback = function(state) Aura.Hunt = state end,
    })

    section:Slider({
        Title = 'hunt range',
        Min = 20, Max = 300, Increment = 10, Suffix = ' st',
        Default = Aura.HuntRange,
        Flag = 'chunk_aura_hunt_range',
        Callback = function(value) Aura.HuntRange = tonumber(value) or Aura.HuntRange end,
    })

    section = CombatTab:CreateSection('readout')
    Readout.aura = addStat(section, { Title = 'fighting', Value = 'off' })
    Readout.kills = addStat(section, { Title = 'kills', Value = 0 })
end

do
    local SurvivalTab = Window:CreateTab({ Title = 'survival' })
    local section = SurvivalTab:CreateSection('food')

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
        Description = typeof(fireproximityprompt) == "function" and 'opens loot crates within the loot range'
            or 'opens loot crates within the loot range (needs fireproximityprompt, which this executor does not have)',
        Flag = 'chunk_crates',
        Default = false,
        Callback = function(state) Loot.Crates = state end,
    })

    section:Toggle({
        Title = 'collect drops',
        Description = 'teleports onto dropped items within the loot range so they get picked up',
        Flag = 'chunk_drops',
        Default = false,
        Callback = function(state) Loot.Drops = state end,
    })

    section:Toggle({
        Title = 'teleport to loot',
        Description = 'off only opens crates already within reach',
        Flag = 'chunk_loot_travel',
        Default = true,
        Callback = function(state) Loot.Travel = state end,
    })

    section:Slider({
        Title = 'loot range',
        Min = 10, Max = 500, Increment = 10, Suffix = ' st',
        Default = Loot.Range,
        Flag = 'chunk_loot_range',
        Callback = function(value) Loot.Range = tonumber(value) or Loot.Range end,
    })
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
            Callback = function() teleportTo(TeleportPlaces[place](), place) end,
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

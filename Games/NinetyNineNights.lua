--// Survive 99 Nights ------------------------------------------------------------------
-- Built against a script dump of the live game (place 126509999114328, version 712).
--
-- What the game's own client scripts show:
--  * Every swing of an axe, sword or chainsaw ends in
--    RemoteEvents.ToolDamageObject:InvokeServer(target, tool, hitId, rootCFrame, killing)
--    where `tool` is the item model in Players.<you>.Inventory, `hitId` is
--    "<counter>_<abs UserId>" (EnemyHandler.GetHitRegId) and `killing` is true
--    when a resource's Health minus the hits already sent reaches 0. One swing
--    hits everything inside a small box in front of you, on the tool's
--    ToolCooldown (0.5 s on the Good Axe).
--  * Trees and other choppable things are models with a Resource attribute
--    ("Tree", "IceBlock", "MeteorNode", ...), a Health attribute and a
--    HitRegisters folder. AllowTool_<ToolName> says which tools can hit it and
--    ToolTier is the tier the tool needs.
--  * Mobs live in Workspace.Characters with a Humanoid named "NPC". The game's
--    own "can this be hit" check (Flashlight) is: has NPC, no NotAttackable, no
--    NotDamageable, not Tamed. Lost kids carry KidId / NPCType "Lost Child" and
--    NotAttackable. A mob after you has State "Chase" and ChasingPlayer = your
--    UserId, and attacks with its AttackRange / AttackCooldown attributes.
--  * Equipping is EquipItemHandle:FireServer("FireAllClients", item) and your
--    character's Equipped attribute holds the held item's name.
--  * Workspace.Map.MissingKids keeps a Vector3 attribute per kid still missing
--    (DinoKid, KoalaKid, KrakenKid, SquidKid), so a kid can be found without its
--    model being streamed in.
--  * Workspace attributes carry the clock: State (Day / Night), SecondsLeft,
--    StoryDayCounter, Weather, Biome, CultistAttackDay, plus the cave teleport
--    points (CaveTeleport_Exit1..5, CaveTeleport_Entrance1).
--  * Your stats are attributes on your Player: Hunger (max 200), Temperature,
--    Warmth, Armour, Class, ClassLevel, Diamonds, Candy.
--  * Moving loose items (Workspace.Items) is the game's drag:
--    RequestStartDraggingItem:FireServer(item) hands you the item, the client
--    moves it, StopDraggingItem:FireServer(item) gives it back. The camp fire
--    burns with RequestBurnItem:FireServer(MainFire, item) (fuel = BurnFuel,
--    not Wet), the crafting bench scraps with
--    RequestScrapItem:InvokeServer(CraftingBench, item).
--  * Eating and healing: RequestConsumeItem:InvokeServer(item). Coins (tag
--    Coins): RequestCollectCoints:InvokeServer(item). Diamonds:
--    RequestTakeDiamonds:FireServer(item). Chests: their prompt, or
--    RequestOpenItemChest:FireServer(chest). Lost kids go in the sack with
--    RequestBagStoreItem:InvokeServer(sack, kid) and come out with
--    RequestBagDropItem:FireServer(sack, kid, isLast); sack contents live in
--    Players.<you>.ItemBag.
--  * The only client anti cheat is AntiFlingClient: a root moving faster than
--    300 studs/s is slowed to 100. Fly and tween teleports stay under that.
--
-- Mobs are sorted by what they do, not by name, so new mobs from updates are
-- picked up without changes here:
--   Hostile    chasing someone, or has AttackDamage / AggroRange
--   Can attack has AttackRange and AttackCooldown (can fight back)
--   Passive    neither
--   Kids, pets, the dead and anything marked NotAttackable are never hit.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__NinetyNineUnload then
    pcall(Genv.__NinetyNineUnload)
end
Genv.__NinetyNineRun = (Genv.__NinetyNineRun or 0) + 1
local RUN = Genv.__NinetyNineRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__NinetyNineRun == RUN
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

local Settings = {
    -- main
    AutoChop = false, ChopRange = 40, ShowChopRange = false, ChopColor = Color3.fromRGB(120, 220, 120),
    ChopTypes = { Tree = true }, ChopPerSwing = 3,
    KillAura = false, AuraRange = 30, ShowAuraRange = false, AuraColor = Color3.fromRGB(255, 90, 90),
    AuraKinds = { Hostile = true, ["Can attack"] = true }, AuraPerSwing = 3,
    AutoEquip = true, HitFrom = "Your position", ExtraDelay = 0,
    -- movement
    Speed = false, SpeedValue = 32, SpeedMethod = "WalkSpeed",
    Jump = false, JumpValue = 75, InfJump = false,
    Fly = false, FlySpeed = 60, Noclip = false, AntiAfk = true,
    TpMethod = "Instant", TpSpeed = 150,
    -- visuals
    KidDots = false, KidLabels = true, KidColor = Color3.fromRGB(255, 220, 80),
    EspMobs = false, EspKids = false, EspPlayers = false, EspChests = false, EspItems = false,
    EspItemKinds = { Fuel = true, Food = true, Heals = true, Scrap = true, Gems = true, Ammo = true, Gear = true, Seeds = true, Currency = true },
    EspHighlight = true, EspDistance = 400, EspShowHealth = true,
    PlayerColor = Color3.fromRGB(120, 180, 255), ChestColor = Color3.fromRGB(255, 200, 90),
    ItemColor = Color3.fromRGB(200, 200, 200),
    Fullbright = false, NoFog = false, AlwaysDay = false, FovOn = false, Fov = 80,
    -- main (both jobs at once)
    OneTool = true,
    -- bring
    BringKinds = { Fuel = true }, BringNames = {}, BringByName = false,
    BringDest = "You", BringMode = "Fast", BringPerFrame = 10, BringHold = 100,
    BringMax = 100, BringRange = 2000, BringSkipNear = true, SavedSpot = nil,
    AutoBring = false, AutoBringEvery = 10,
    -- extra
    AutoChests = false, AutoBagKids = false, AutoDropKids = false,
    AutoCoins = false, CoinRange = 20,
    AutoEat = false, EatBelow = 120, AutoHeal = false, HealBelow = 50, ConsumeRange = 15,
    KeepFireFed = false, FireBelow = 40,
    InstantPrompts = false,
}

local MobColors = {
    Hostile = Color3.fromRGB(255, 70, 70),
    ["Can attack"] = Color3.fromRGB(255, 160, 60),
    Passive = Color3.fromRGB(110, 220, 110),
    Pet = Color3.fromRGB(110, 170, 255),
    Kid = Color3.fromRGB(255, 220, 80),
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
VisualGui.Name = "NinetyNineVisuals"
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
local function distanceTo(pos)
    local hrp = rootPart()
    if not hrp or not pos then
        return math.huge
    end
    return (hrp.Position - pos).Magnitude
end
local function anyPart(model)
    if model:IsA("BasePart") then
        return model
    end
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Main")
        or model:FindFirstChildWhichIsA("BasePart", true)
end
local function spaced(text)
    return (tostring(text):gsub("(%l)(%u)", "%1 %2"))
end
local function cleanName(name)
    return (tostring(name):gsub("%[%d+%]$", ""):gsub("%d+$", ""))
end
local function clock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local Remotes = ReplicatedStorage:WaitForChild("RemoteEvents", 15)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end

local function mapFolder(name)
    local map = Workspace:FindFirstChild("Map")
    return map and map:FindFirstChild(name)
end

--// Tools \\--
local function inventory()
    return LocalPlayer:FindFirstChild("Inventory")
end

local function equippedName()
    local c = character()
    return c and c:GetAttribute("Equipped")
end

local function canChopWith(tool, target)
    local toolName = tool:GetAttribute("ToolName")
    if not toolName or not tool:GetAttribute("WeaponResourceDamage") then
        return false
    end
    if target:GetAttribute("AllowTool_" .. toolName) ~= true then
        return false
    end
    local need = target:GetAttribute("ToolTier")
    return not need or (tool:GetAttribute("ToolTier") or 1) >= need
end

local RANGED = { Firearm = true, ThrownWeapon = true }
local function isMelee(tool)
    return tool:GetAttribute("WeaponDamage") ~= nil and not RANGED[tool:GetAttribute("ToolName") or ""]
end

local function inventoryItems()
    local inv = inventory()
    return inv and inv:GetChildren() or {}
end

-- Best melee weapon in the inventory by WeaponDamage. Ties go to the one in hand.
local function bestWeapon()
    local held = equippedName()
    local best, bestDamage
    for _, item in inventoryItems() do
        if isMelee(item) then
            local damage = item:GetAttribute("WeaponDamage") or 0
            if not bestDamage or damage > bestDamage or (damage == bestDamage and item.Name == held) then
                best, bestDamage = item, damage
            end
        end
    end
    return best
end

-- The axe that can break the most of `trees`, then the one that hits them hardest.
-- Returns the axe and the trees it can break.
local function bestAxe(trees)
    local held = equippedName()
    local best, bestList, bestCount, bestDamage
    for _, item in inventoryItems() do
        if item:GetAttribute("WeaponResourceDamage") and item:GetAttribute("ToolName") then
            local list = {}
            for _, entry in trees do
                if canChopWith(item, entry.model) then
                    table.insert(list, entry)
                end
            end
            local damage = item:GetAttribute("WeaponResourceDamage") or 0
            local better = not bestCount
                or #list > bestCount
                or (#list == bestCount and damage > bestDamage)
                or (#list == bestCount and damage == bestDamage and item.Name == held)
            if better then
                best, bestList, bestCount, bestDamage = item, list, #list, damage
            end
        end
    end
    return best, bestList or {}
end

local lastEquip = 0
-- True when `tool` is already in hand. Otherwise asks the server to equip it
-- (when auto equip is on) and the swing waits for the next tick.
local function readyTool(tool)
    if equippedName() == tool.Name then
        return true
    end
    if not Settings.AutoEquip then
        return true
    end
    if os.clock() - lastEquip > 0.75 then
        lastEquip = os.clock()
        local r = remote("EquipItemHandle")
        if r then
            r:FireServer("FireAllClients", tool)
        end
    end
    return false
end

local hitCounter = 0
local function nextHitId()
    hitCounter += 1
    return (500000 + hitCounter) .. "_" .. math.abs(LocalPlayer.UserId)
end

local function sendHit(target, tool, killing)
    local r = remote("ToolDamageObject")
    local hrp = rootPart()
    if not r or not hrp then
        return
    end
    local origin = hrp.CFrame
    if Settings.HitFrom == "Near target" then
        local pos = pivotPos(target)
        if pos then
            local away = hrp.Position - pos
            away = Vector3.new(away.X, 0, away.Z)
            away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
            local from = pos + away * 4 + Vector3.new(0, 2, 0)
            origin = CFrame.lookAt(from, Vector3.new(pos.X, from.Y, pos.Z))
        end
    end
    task.spawn(function()
        pcall(r.InvokeServer, r, target, tool, nextHitId(), origin, killing)
    end)
end

--// Resources (anything choppable) \\--
local Resources = {}
local ResourceTypes = {}
local pendingTypes = false

local function considerResource(inst)
    if not inst:IsA("Model") then
        return
    end
    local kind = inst:GetAttribute("Resource")
    if kind == nil or inst:GetAttribute("Health") == nil then
        return
    end
    Resources[inst] = true
    if not ResourceTypes[kind] then
        ResourceTypes[kind] = true
        pendingTypes = true
    end
end

task.spawn(function()
    local map = Workspace:WaitForChild("Map", 30)
    if not map or not alive() then
        return
    end
    for i, inst in map:GetDescendants() do
        considerResource(inst)
        if i % 4000 == 0 then
            task.wait()
        end
    end
    bind(map.DescendantAdded, considerResource)
    bind(map.DescendantRemoving, function(inst)
        Resources[inst] = nil
    end)
end)

--// Mobs \\--
local function charactersFolder()
    return Workspace:FindFirstChild("Characters")
end

-- What a mob is, from what it does (see the header).
local function mobKind(model)
    local npc = model:FindFirstChild("NPC")
    if not npc then
        return nil
    end
    if model:GetAttribute("KidId") or model:GetAttribute("NPCType") == "Lost Child" then
        return "Kid"
    end
    if model:GetAttribute("Dead") or (npc:IsA("Humanoid") and npc.Health <= 0) then
        return "Dead"
    end
    if model:GetAttribute("Tamed") or model:GetAttribute("CurrentTamingState") == "Tamed" or model:GetAttribute("State") == "FollowOwner" then
        return "Pet"
    end
    if model:GetAttribute("NotAttackable") or model:GetAttribute("NotDamageable") then
        return "Immune"
    end
    local chasing = model:GetAttribute("ChasingPlayer")
    local state = model:GetAttribute("State")
    if (chasing and chasing ~= 0) or state == "Chase" or state == "Attack"
        or model:GetAttribute("AttackDamage") or model:GetAttribute("AggroRange") then
        return "Hostile"
    end
    local target = model:FindFirstChild("NPCTarget")
    if target and target:IsA("ObjectValue") and target.Value and Players:GetPlayerFromCharacter(target.Value) then
        return "Hostile"
    end
    if model:GetAttribute("AttackRange") and model:GetAttribute("AttackCooldown") then
        return "Can attack"
    end
    return "Passive"
end

local function mobPos(model)
    local hrp = model:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or pivotPos(model)
end

--// Auto chop + kill aura, side by side \\--
-- Both share one swing clock (the server sees one tool swing at a time). Each
-- swing hits mobs and trees together when one tool can do both; otherwise the
-- two jobs take turns.
local nextSwing = 0
local nextJob = "aura"
local SwingInfo = { axe = "-", weapon = "-", blocked = 0, blockedTier = nil }

local function chopCandidates()
    local hrp = rootPart()
    if not hrp then
        return {}
    end
    local list = {}
    for model in Resources do
        if model.Parent == nil then
            Resources[model] = nil
        elseif Settings.ChopTypes[model:GetAttribute("Resource")] and (model:GetAttribute("Health") or 0) > 0 then
            local pos = pivotPos(model)
            local d = pos and (pos - hrp.Position).Magnitude
            if d and d <= Settings.ChopRange then
                table.insert(list, { model = model, d = d })
            end
        end
    end
    table.sort(list, function(a, b)
        return a.d < b.d
    end)
    return list
end

local function auraTargets()
    local hrp = rootPart()
    local folder = charactersFolder()
    if not hrp or not folder then
        return {}
    end
    local list = {}
    for _, model in folder:GetChildren() do
        if model:IsA("Model") then
            local kind = mobKind(model)
            if kind and Settings.AuraKinds[kind] then
                local pos = mobPos(model)
                local d = pos and (pos - hrp.Position).Magnitude
                if d and d <= Settings.AuraRange then
                    table.insert(list, { model = model, d = d })
                end
            end
        end
    end
    table.sort(list, function(a, b)
        return a.d < b.d
    end)
    return list
end

local function hitMobs(list, tool)
    for i = 1, math.min(Settings.AuraPerSwing, #list) do
        sendHit(list[i].model, tool, false)
    end
end

local function hitTrees(list, tool)
    local damage = tool:GetAttribute("WeaponResourceDamage") or 10
    for i = 1, math.min(Settings.ChopPerSwing, #list) do
        local model = list[i].model
        sendHit(model, tool, (model:GetAttribute("Health") or 0) - damage <= 0)
    end
end

local function swingTick()
    if not (Settings.AutoChop or Settings.KillAura) then
        return
    end
    local now = os.clock()
    if now < nextSwing then
        return
    end
    -- Nothing to hit or no tool yet: look again shortly rather than every frame.
    nextSwing = now + 0.15
    local hum = humanoid()
    if not hum or hum.Health <= 0 then
        return
    end

    local mobs = Settings.KillAura and auraTargets() or {}
    local weapon = #mobs > 0 and bestWeapon() or nil
    SwingInfo.weapon = weapon and string.format("%s (%d dmg)", weapon.Name, weapon:GetAttribute("WeaponDamage") or 0)
        or (Settings.KillAura and (#mobs > 0 and "no melee weapon" or "nothing in range") or "-")

    local trees, axe, breakable = {}, nil, {}
    if Settings.AutoChop then
        trees = chopCandidates()
        if #trees > 0 then
            axe, breakable = bestAxe(trees)
        end
        -- Trees in range that no axe you own can break, and the tier they need.
        SwingInfo.blocked = #trees - #breakable
        SwingInfo.blockedTier = nil
        if SwingInfo.blocked > 0 then
            for _, entry in trees do
                local need = entry.model:GetAttribute("ToolTier")
                if need and (not axe or not canChopWith(axe, entry.model)) then
                    SwingInfo.blockedTier = math.max(SwingInfo.blockedTier or 0, need)
                end
            end
        end
        SwingInfo.axe = axe and string.format("%s (tier %d, %d wood dmg)", axe.Name, axe:GetAttribute("ToolTier") or 1, axe:GetAttribute("WeaponResourceDamage") or 0)
            or (#trees > 0 and "no axe in inventory" or "nothing in range")
    end

    local wantAura = weapon ~= nil
    local wantChop = axe ~= nil and #breakable > 0
    if not wantAura and not wantChop then
        return
    end

    local auraTool, chopTool = weapon, axe
    if wantAura and wantChop and auraTool ~= chopTool then
        -- One tool for both when it can: the weapon chops these trees, or the axe
        -- can fight. Saves an equip swap every swing.
        local weaponChops = {}
        for _, entry in breakable do
            if canChopWith(weapon, entry.model) then
                table.insert(weaponChops, entry)
            end
        end
        if #weaponChops > 0 then
            chopTool, breakable = weapon, weaponChops
        elseif Settings.OneTool and isMelee(axe) then
            auraTool = axe
        end
    end

    local function finish(tool)
        nextSwing = now + (tool:GetAttribute("ToolCooldown") or 0.5) + Settings.ExtraDelay / 1000
    end

    if wantAura and wantChop and auraTool == chopTool then
        if readyTool(auraTool) then
            hitMobs(mobs, auraTool)
            hitTrees(breakable, auraTool)
            finish(auraTool)
        end
        return
    end

    -- Different tools: take turns, so neither job starves.
    local job
    if wantAura and wantChop then
        job = nextJob
    else
        job = wantAura and "aura" or "chop"
    end
    local tool = job == "aura" and auraTool or chopTool
    if readyTool(tool) then
        if job == "aura" then
            hitMobs(mobs, tool)
        else
            hitTrees(breakable, tool)
        end
        finish(tool)
        nextJob = job == "aura" and "chop" or "aura"
    end
end

--// Range rings \\--
local function makeRing()
    local ring = Instance.new("CylinderHandleAdornment")
    ring.Adornee = Workspace.Terrain
    ring.Height = 0.12
    ring.Transparency = 0.35
    ring.AlwaysOnTop = false
    ring.ZIndex = 1
    ring.Visible = false
    ring.Parent = VisualGui
    return ring
end
local ChopRing = makeRing()
local AuraRing = makeRing()

local function placeRing(ring, show, radius, color, lift)
    local hrp = rootPart()
    local hum = humanoid()
    if not show or radius <= 0 or not hrp then
        ring.Visible = false
        return
    end
    local feet = hrp.Position - Vector3.new(0, (hum and hum.HipHeight or 2) + hrp.Size.Y / 2 - lift, 0)
    ring.Radius = radius
    ring.InnerRadius = math.max(0, radius - 0.45)
    ring.Color3 = color
    ring.CFrame = CFrame.new(feet) * CFrame.Angles(math.rad(90), 0, 0)
    ring.Visible = true
end

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
        att.Name = "NNFlyAttachment"
        att.Parent = hrp
        lv = Instance.new("LinearVelocity")
        lv.Name = "NNFly"
        lv.Attachment0 = att
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        lv.MaxForce = math.huge
        lv.Parent = hrp
        local align = Instance.new("AlignOrientation")
        align.Name = "NNFlyAlign"
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
    -- Stays under the game's 300 studs/s anti-fling cap.
    lv.VectorVelocity = dir * math.min(Settings.FlySpeed, 280)
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
    stroke.Color = Color3.fromRGB(255, 151, 227)
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

    if Settings.Speed then
        if Settings.SpeedMethod == "WalkSpeed" then
            hum.WalkSpeed = Settings.SpeedValue
        elseif not Settings.Fly and hum.MoveDirection.Magnitude > 0 then
            -- CFrame: the game keeps its own walk speed, the rest is added on top.
            local extra = math.max(0, Settings.SpeedValue - hum.WalkSpeed)
            hrp.CFrame += hum.MoveDirection * extra * dt
        end
    end

    if Settings.Jump then
        if Saved.UseJumpPower == nil then
            Saved.UseJumpPower, Saved.JumpPower, Saved.JumpHeight = hum.UseJumpPower, hum.JumpPower, hum.JumpHeight
        end
        hum.UseJumpPower = true
        hum.JumpPower = Settings.JumpValue
    end

    if Settings.Fly then
        flyStep()
    end
    FlyButtons.Visible = Settings.Fly and UserInputService.TouchEnabled
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
    if not alive() or not Settings.Noclip then
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
    if not alive() or not Settings.InfJump or Settings.Fly then
        return
    end
    local hum = humanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

bind(LocalPlayer.Idled, function()
    if not alive() or not Settings.AntiAfk then
        return
    end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

--// Teleports \\--
local tpToken = 0
local function teleportTo(pos)
    local hrp = rootPart()
    if not hrp or not pos then
        Library:Notify({ Title = "Teleport", Description = "Nowhere to go (not loaded?)", Time = 3 })
        return
    end
    local target = CFrame.new(pos + Vector3.new(0, 4, 0))
    tpToken += 1
    local token = tpToken
    if Settings.TpMethod == "Instant" then
        hrp.CFrame = target
        hrp.AssemblyLinearVelocity = Vector3.zero
        return
    end
    -- Tween: moved by CFrame with no velocity, so the anti-fling never sees it.
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
            local step = math.min(d, Settings.TpSpeed * dt)
            r.CFrame = CFrame.new(r.Position + delta.Unit * step) * r.CFrame.Rotation
            r.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end

-- Fixed places: camp pieces and every cave point the server publishes.
local function placeTargets()
    local list, order = {}, {}
    local function add(label, getPos)
        if not list[label] then
            list[label] = getPos
            table.insert(order, label)
        end
    end
    local camp = mapFolder("Campground")
    if camp then
        for _, entry in {
            { "Camp fire", "MainFire" },
            { "Crafting bench", "CraftingBench" },
            { "Scrapper", "Scrapper" },
            { "Notice board", "NoticeBoard" },
        } do
            local model = camp:FindFirstChild(entry[2])
            if model then
                add(entry[1], function()
                    return pivotPos(model) and pivotPos(model) + Vector3.new(0, 0, 8)
                end)
            end
        end
    end
    local caves = {}
    for name, value in Workspace:GetAttributes() do
        local kind, n = name:match("^CaveTeleport_(%a+)(%d+)$")
        if kind and typeof(value) == "CFrame" then
            table.insert(caves, { kind = kind, n = tonumber(n), cf = value })
        end
    end
    table.sort(caves, function(a, b)
        if a.n == b.n then
            return a.kind > b.kind
        end
        return a.n < b.n
    end)
    for _, cave in caves do
        local label = cave.kind == "Exit" and ("Cave " .. cave.n .. " (outside)") or ("Cave " .. cave.n .. " (inside)")
        add(label, function()
            return cave.cf.Position
        end)
    end
    return list, order
end

-- Every chest, numbered once so a label keeps pointing at the same chest.
local ChestIds, nextChestId = setmetatable({}, { __mode = "k" }), 0
local function chestTargets()
    local items = Workspace:FindFirstChild("Items")
    local list, order = {}, {}
    if not items then
        return list, order
    end
    local found = {}
    for _, model in items:GetChildren() do
        if model:GetAttribute("Interaction") == "ItemChest" then
            if not ChestIds[model] then
                nextChestId += 1
                ChestIds[model] = nextChestId
            end
            local label = (model:GetAttribute("ChestName") or cleanName(model.Name)) .. " #" .. ChestIds[model]
            if model:GetAttribute("Locked") then
                label ..= " (locked)"
            end
            table.insert(found, { label = label, model = model, d = distanceTo(pivotPos(model)) })
        end
    end
    table.sort(found, function(a, b)
        return a.d < b.d
    end)
    for _, entry in found do
        list[entry.label] = entry.model
        table.insert(order, entry.label)
    end
    return list, order
end

local INTERESTING_LANDMARK = { Landmark = true, Trap = true }
local function landmarkTargets(everything)
    local folder = mapFolder("Landmarks")
    local list, order, counts = {}, {}, {}
    if not folder then
        return list, order
    end
    local found = {}
    for _, model in folder:GetChildren() do
        local full = model:GetAttribute("FullLandmarkName")
        if everything or full or INTERESTING_LANDMARK[model:GetAttribute("PingId") or ""] then
            local base = full or cleanName(model.Name)
            if model:GetAttribute("KidId") then
                base ..= " (" .. spaced(model:GetAttribute("KidId")) .. ")"
            end
            counts[base] = (counts[base] or 0) + 1
            table.insert(found, { base = base, model = model, d = distanceTo(pivotPos(model)) })
        end
    end
    table.sort(found, function(a, b)
        if a.base == b.base then
            return a.d < b.d
        end
        return a.base < b.base
    end)
    local seen = {}
    for _, entry in found do
        local label = entry.base
        if counts[entry.base] > 1 then
            seen[entry.base] = (seen[entry.base] or 0) + 1
            label ..= " " .. seen[entry.base]
        end
        list[label] = entry.model
        table.insert(order, label)
    end
    return list, order
end

-- Kids: the live model when it's streamed in, the server's map point otherwise.
local function kidPositions()
    local kids = {}
    local missing = mapFolder("MissingKids")
    if missing then
        for kidId, value in missing:GetAttributes() do
            if typeof(value) == "Vector3" then
                kids[kidId] = { pos = value, live = false }
            end
        end
    end
    local folder = charactersFolder()
    if folder then
        for _, model in folder:GetChildren() do
            local kidId = model:GetAttribute("KidId")
            if kidId and model:GetAttribute("Lost") ~= false and (kids[kidId] or not missing) then
                local pos = mobPos(model)
                if pos then
                    kids[kidId] = { pos = pos, live = true, name = model:GetAttribute("PingName") }
                end
            end
        end
    end
    return kids
end

local function itemNameTargets()
    local items = Workspace:FindFirstChild("Items")
    local names, order = {}, {}
    if not items then
        return order
    end
    for _, model in items:GetChildren() do
        local interaction = model:GetAttribute("Interaction")
        if interaction and interaction ~= "ItemChest" then
            local name = cleanName(model.Name)
            if not names[name] then
                names[name] = true
                table.insert(order, name)
            end
        end
    end
    table.sort(order)
    return order
end

local function nearestItemNamed(name)
    local items = Workspace:FindFirstChild("Items")
    local best, bestD
    if not items then
        return nil
    end
    for _, model in items:GetChildren() do
        if cleanName(model.Name) == name and model:GetAttribute("Interaction") ~= "ItemChest" then
            local d = distanceTo(pivotPos(model))
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    return best
end

--// Kid dots (screen markers, work on anything the camera can project) \\--
local KidMarkers = {}
local function kidMarker(kidId)
    local m = KidMarkers[kidId]
    if m then
        return m
    end
    local dot = Instance.new("Frame")
    dot.Name = "Kid_" .. kidId
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.Size = UDim2.fromOffset(12, 12)
    dot.BorderSizePixel = 0
    dot.Parent = VisualGui
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", dot)
    stroke.Color = Color3.new(0, 0, 0)
    stroke.Thickness = 1.5
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 1, 3)
    label.Size = UDim2.fromOffset(160, 16)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 12
    label.TextStrokeTransparency = 0.4
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Parent = dot
    m = { dot = dot, label = label }
    KidMarkers[kidId] = m
    return m
end

local function updateKidDots()
    local hrp = rootPart()
    local kids = (Settings.KidDots and hrp) and kidPositions() or {}
    for kidId, m in KidMarkers do
        if not kids[kidId] then
            m.dot.Visible = false
        end
    end
    if not Settings.KidDots or not hrp then
        return
    end
    local view = Camera.ViewportSize
    for kidId, info in kids do
        local m = kidMarker(kidId)
        local pos = info.pos
        if not info.live and pos.Y == 0 then
            pos = Vector3.new(pos.X, hrp.Position.Y, pos.Z)
        end
        local screen, onScreen = Camera:WorldToViewportPoint(pos)
        local x, y = screen.X, screen.Y
        if not onScreen then
            -- Off screen or behind: pin to the edge in the kid's direction.
            local rel = Camera.CFrame:PointToObjectSpace(pos)
            local dir = Vector2.new(rel.X, -rel.Y)
            if dir.Magnitude < 1e-3 then
                dir = Vector2.new(0, 1)
            end
            dir = dir.Unit
            local half = view / 2 - Vector2.new(40, 40)
            local scale = math.min(half.X / math.max(math.abs(dir.X), 1e-3), half.Y / math.max(math.abs(dir.Y), 1e-3))
            local p = view / 2 + dir * scale
            x, y = p.X, p.Y
        end
        m.dot.Position = UDim2.fromOffset(x, y)
        m.dot.BackgroundColor3 = Settings.KidColor
        m.dot.BackgroundTransparency = info.live and 0 or 0.15
        m.label.Visible = Settings.KidLabels
        m.label.Text = string.format("%s · %dm%s", info.name or spaced(kidId), math.floor((pos - hrp.Position).Magnitude), info.live and "" or " (map)")
        m.dot.Visible = true
    end
end

--// Items: types by what they do, so new items sort themselves \\--
local ITEM_KINDS = { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Other" }
local HEAL_NAMES = { Bandage = true, MedKit = true }

local function itemsFolder()
    return Workspace:FindFirstChild("Items")
end

local function mineOrFree(model)
    local owner = model:GetAttribute("Owner")
    return owner == nil or owner == LocalPlayer.UserId
end

-- nil for things that aren't loose items (chests, coins, diamonds).
local function itemKind(model)
    local interaction = model:GetAttribute("Interaction")
    if interaction == nil or interaction == "ItemChest" then
        return nil
    end
    if interaction == "Currency" then
        return "Currency"
    end
    if model:GetAttribute("RestoreHealth") or HEAL_NAMES[cleanName(model.Name)] then
        return "Heals"
    elseif model:HasTag("Gem") or model:HasTag("GreenGem") then
        return "Gems"
    elseif model:GetAttribute("AmmoType") or model:GetAttribute("RifleAmmo") or model:GetAttribute("RevolverAmmo")
        or model:GetAttribute("ShotgunAmmo") then
        return "Ammo"
    elseif model:GetAttribute("RestoreHunger") then
        return "Food"
    elseif interaction == "Tool" or interaction == "Armour" then
        return "Gear"
    elseif model:HasTag("Plantable") or model:HasTag("SeedBox") or model:HasTag("Acorn") then
        return "Seeds"
    elseif model:GetAttribute("BurnFuel") then
        return "Fuel"
    elseif model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded") then
        return "Scrap"
    end
    return "Other"
end

local function campPart(name)
    local camp = mapFolder("Campground")
    return camp and camp:FindFirstChild(name)
end

--// Bring \\--
-- The game's own drag: RequestStartDraggingItem hands you the item, you move
-- it, StopDraggingItem gives it back. Fast mode starts, moves and releases
-- many items per frame and moves each again right before release, so it lands
-- even when the hand-over is a frame late. Safe mode does one at a time and
-- waits for the hand-over.
local BRING_DESTS = { "You", "Camp fire", "Crafting bench", "Saved spot" }
local Bring = { token = 0, done = 0, total = 0, running = false }

local function bringTarget(dest)
    local hrp = rootPart()
    if dest == "Camp fire" then
        local fire = campPart("MainFire")
        local center = fire and (fire:FindFirstChild("Center") or fire:FindFirstChild("InnerTouchZone"))
        local pos = center and (center:IsA("BasePart") and center.Position or pivotPos(center)) or pivotPos(fire)
        return pos and CFrame.new(pos + Vector3.new(0, 4, 0))
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local zone = bench and bench:FindFirstChild("TouchZone")
        local pos = zone and zone.Position or pivotPos(bench)
        return pos and CFrame.new(pos + Vector3.new(0, 3, 0))
    elseif dest == "Saved spot" then
        return Settings.SavedSpot
    end
    return hrp and (hrp.CFrame * CFrame.new(0, 1, -7))
end

-- Spread items in a grid so a big pile doesn't explode. The fire and bench
-- want them close together so they land in the touch zone.
local function slotOffset(i, dest)
    local spacing = (dest == "Camp fire" or dest == "Crafting bench") and 0.8 or 1.8
    local r = (i - 1) % 36
    local layer = (i - 1) // 36
    return Vector3.new((r % 6 - 2.5) * spacing, layer * spacing, (r // 6 - 2.5) * spacing)
end

local function bringList(kinds, names, byName, dest, limit)
    local items = itemsFolder()
    local hrp = rootPart()
    local target = bringTarget(dest)
    if not items or not hrp or not target then
        return {}
    end
    local list = {}
    for _, model in items:GetChildren() do
        local kind = itemKind(model)
        local wanted
        if byName then
            wanted = names[cleanName(model.Name)] == true
        else
            wanted = kind ~= nil and kind ~= "Currency" and kinds[kind] == true
        end
        if wanted and mineOrFree(model) and anyPart(model) then
            local pos = pivotPos(model)
            local d = pos and (pos - hrp.Position).Magnitude
            local atTarget = pos and (pos - target.Position).Magnitude < 12
            if d and d <= Settings.BringRange and not (Settings.BringSkipNear and atTarget) then
                table.insert(list, { model = model, d = d })
            end
        end
    end
    table.sort(list, function(a, b)
        return a.d < b.d
    end)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i].model
    end
    return out
end

local function placeItem(model, cf)
    pcall(function()
        model:PivotTo(cf)
        local part = model.PrimaryPart or anyPart(model)
        if part then
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end)
end

-- What the fire and the bench do with an item that arrives, through the same
-- remotes their touch zones use.
local function arrive(model, dest)
    if dest == "Camp fire" then
        local fire = campPart("MainFire")
        local r = remote("RequestBurnItem")
        if fire and r and model:GetAttribute("BurnFuel") and (model:GetAttribute("Wet") or 0) < 1 then
            r:FireServer(fire, model)
        end
    elseif dest == "Crafting bench" then
        local bench = campPart("CraftingBench")
        local r = remote("RequestScrapItem")
        if bench and r and (model:GetAttribute("Scrappable") or model:HasTag("CanBeGrinded")) then
            task.spawn(pcall, r.InvokeServer, r, bench, model)
        end
    end
end

local function isOwner(part)
    if typeof(isnetworkowner) ~= "function" or not part then
        return nil
    end
    local ok, result = pcall(isnetworkowner, part)
    return ok and result or false
end

local function runBring(kinds, names, byName, dest, limit)
    Bring.token += 1
    local token = Bring.token
    local list = bringList(kinds, names, byName, dest, limit or Settings.BringMax)
    local start, stop = remote("RequestStartDraggingItem"), remote("StopDraggingItem")
    Bring.total, Bring.done = #list, 0
    if #list == 0 or not start or not stop then
        return 0
    end
    Bring.running = true
    task.spawn(function()
        local base = bringTarget(dest)
        if not base then
            Bring.running = false
            return
        end
        if Settings.BringMode == "Fast" then
            local i = 0
            while i < #list and alive() and token == Bring.token do
                for _ = 1, Settings.BringPerFrame do
                    i += 1
                    local model = list[i]
                    if not model then
                        break
                    end
                    if model.Parent then
                        local cf = CFrame.new(base.Position + slotOffset(i, dest))
                        start:FireServer(model)
                        placeItem(model, cf)
                        task.delay(Settings.BringHold / 1000, function()
                            if model.Parent then
                                placeItem(model, cf)
                                stop:FireServer(model)
                                arrive(model, dest)
                            end
                            Bring.done += 1
                        end)
                    else
                        Bring.done += 1
                    end
                end
                RunService.Heartbeat:Wait()
            end
        else
            for i, model in list do
                if token ~= Bring.token or not alive() then
                    break
                end
                if model.Parent then
                    local cf = CFrame.new(base.Position + slotOffset(i, dest))
                    local part = model.PrimaryPart or anyPart(model)
                    start:FireServer(model)
                    local t0 = os.clock()
                    if isOwner(part) ~= nil then
                        repeat
                            RunService.Heartbeat:Wait()
                        until isOwner(part) or os.clock() - t0 > 0.35
                    else
                        task.wait(Settings.BringHold / 1000)
                    end
                    placeItem(model, cf)
                    RunService.Heartbeat:Wait()
                    placeItem(model, cf)
                    stop:FireServer(model)
                    arrive(model, dest)
                end
                Bring.done = i
            end
        end
        task.wait(Settings.BringHold / 1000 + 0.1)
        if token == Bring.token then
            Bring.running = false
        end
    end)
    return #list
end

local function itemNames()
    local items = itemsFolder()
    local seen, order = {}, {}
    if not items then
        return order
    end
    for _, model in items:GetChildren() do
        local kind = itemKind(model)
        if kind and kind ~= "Currency" then
            local name = cleanName(model.Name)
            if not seen[name] then
                seen[name] = true
                table.insert(order, name)
            end
        end
    end
    table.sort(order)
    return order
end

--// Extra: chests, kids, coins, eating, healing, fire \\--
local Tried = setmetatable({}, { __mode = "k" })
local function tryOnce(model, every)
    local last = Tried[model]
    if last and os.clock() - last < (every or 4) then
        return false
    end
    Tried[model] = os.clock()
    return true
end

local function chestPrompt(chest)
    for _, inst in chest:GetDescendants() do
        if inst:IsA("ProximityPrompt") then
            return inst
        end
    end
    return nil
end

local function chestOpened(chest)
    return chest:GetAttribute("LocalOpened") or chest:GetAttribute(math.abs(LocalPlayer.UserId) .. "Opened")
end

local function openChestsInRange()
    local items = itemsFolder()
    local hrp = rootPart()
    if not items or not hrp then
        return
    end
    for _, chest in items:GetChildren() do
        if chest:GetAttribute("Interaction") == "ItemChest" and not chest:GetAttribute("Locked") and not chestOpened(chest) then
            local prompt = chestPrompt(chest)
            local pos = pivotPos(chest)
            -- Opens exactly where the chest's own prompt would let you.
            local range = prompt and prompt.MaxActivationDistance or 10
            if prompt and prompt.Enabled and pos and (pos - hrp.Position).Magnitude <= range and tryOnce(chest, 5) then
                if typeof(fireproximityprompt) == "function" then
                    -- Some executors honour the hold time, so drop it for the call.
                    local hold = prompt.HoldDuration
                    prompt.HoldDuration = 0
                    pcall(fireproximityprompt, prompt)
                    task.delay(0.25, function()
                        if prompt.Parent and not Settings.InstantPrompts then
                            prompt.HoldDuration = hold
                        end
                    end)
                else
                    local r = remote("RequestOpenItemChest")
                    if r then
                        r:FireServer(chest)
                        chest:SetAttribute("LocalOpened", true)
                    end
                end
            end
        end
    end
end

local function itemBag()
    for _, item in inventoryItems() do
        if item:HasTag("ItemBag") then
            return item
        end
    end
    return nil
end

-- Kids go in the sack from the game's interaction range (15 studs).
local function bagKidsInRange()
    local folder = charactersFolder()
    local hrp = rootPart()
    local bag = itemBag()
    local r = remote("RequestBagStoreItem")
    if not folder or not hrp or not bag or not r then
        return
    end
    for _, model in folder:GetChildren() do
        if model:GetAttribute("CanBeBagged") and model:GetAttribute("Interaction") == "CanBeBagged" then
            local pos = mobPos(model)
            if pos and (pos - hrp.Position).Magnitude <= 15 and tryOnce(model, 3) then
                task.spawn(pcall, r.InvokeServer, r, bag, model)
            end
        end
    end
end

-- Kids in the sack come out at camp.
local function dropKidsAtCamp()
    local bagFolder = LocalPlayer:FindFirstChild("ItemBag")
    local bag = itemBag()
    local r = remote("RequestBagDropItem")
    local fire = campPart("MainFire")
    if not bagFolder or not bag or not r or not fire or distanceTo(pivotPos(fire)) > 30 then
        return
    end
    local children = bagFolder:GetChildren()
    for _, item in children do
        if item:GetAttribute("KidId") and tryOnce(item, 3) then
            r:FireServer(bag, item, #bagFolder:GetChildren() <= 1)
        end
    end
end

local function collectCurrency()
    local items = itemsFolder()
    local hrp = rootPart()
    if not items or not hrp then
        return
    end
    local coins, diamonds = remote("RequestCollectCoints"), remote("RequestTakeDiamonds")
    for _, model in items:GetChildren() do
        if model:GetAttribute("Interaction") == "Currency" and not model:GetAttribute("Destroyed") then
            local pos = pivotPos(model)
            if pos and (pos - hrp.Position).Magnitude <= Settings.CoinRange and tryOnce(model, 3) then
                if model:GetAttribute("Diamonds") and diamonds then
                    diamonds:FireServer(model)
                elseif model:HasTag("Coins") and coins then
                    task.spawn(pcall, coins.InvokeServer, coins, model)
                end
            end
        end
    end
end

-- Eats or heals with the nearest matching item in reach.
local function consumeNearest(filter)
    local items = itemsFolder()
    local hrp = rootPart()
    local r = remote("RequestConsumeItem")
    if not items or not hrp or not r then
        return false
    end
    local best, bestD
    for _, model in items:GetChildren() do
        if filter(model) and mineOrFree(model) then
            local pos = pivotPos(model)
            local d = pos and (pos - hrp.Position).Magnitude
            if d and d <= Settings.ConsumeRange and (not bestD or d < bestD) then
                best, bestD = model, d
            end
        end
    end
    if best and tryOnce(best, 3) then
        task.spawn(pcall, r.InvokeServer, r, best)
        return true
    end
    return false
end

local lastEat, lastHeal, lastFeed = 0, 0, 0
local function extraTick()
    if Settings.AutoChests then
        openChestsInRange()
    end
    if Settings.AutoBagKids then
        bagKidsInRange()
    end
    if Settings.AutoDropKids then
        dropKidsAtCamp()
    end
    if Settings.AutoCoins then
        collectCurrency()
    end
    local now = os.clock()
    if Settings.AutoEat and now - lastEat > 1.5 and (LocalPlayer:GetAttribute("Hunger") or 200) < Settings.EatBelow then
        local bunny = LocalPlayer:GetAttribute("Class") == "Bunny"
        if consumeNearest(function(m)
            return m:GetAttribute("RestoreHunger") ~= nil and not (bunny and m:GetAttribute("HasMeat"))
        end) then
            lastEat = now
        end
    end
    local hum = humanoid()
    if Settings.AutoHeal and hum and now - lastHeal > 1.5 and hum.Health / math.max(hum.MaxHealth, 1) * 100 < Settings.HealBelow then
        if consumeNearest(function(m)
            return m:GetAttribute("RestoreHealth") ~= nil or HEAL_NAMES[cleanName(m.Name)] == true
        end) then
            lastHeal = now
        end
    end
    if Settings.KeepFireFed and now - lastFeed > 8 and not Bring.running then
        local fire = campPart("MainFire")
        local fuel = fire and fire:GetAttribute("FuelRemaining")
        if fuel and fuel < Settings.FireBelow then
            lastFeed = now
            runBring({ Fuel = true }, {}, false, "Camp fire", 6)
        end
    end
end

-- Instant prompts: every hold-to-interact prompt fires on press.
local PromptHolds = setmetatable({}, { __mode = "k" })
local function instantPrompt(prompt)
    if prompt:IsA("ProximityPrompt") and prompt.HoldDuration > 0 then
        if PromptHolds[prompt] == nil then
            PromptHolds[prompt] = prompt.HoldDuration
        end
        prompt.HoldDuration = 0
    end
end
local function setInstantPrompts(on)
    if on then
        for _, inst in Workspace:GetDescendants() do
            instantPrompt(inst)
        end
    else
        for prompt, hold in PromptHolds do
            if prompt.Parent then
                prompt.HoldDuration = hold
            end
        end
        table.clear(PromptHolds)
    end
end
bind(Workspace.DescendantAdded, function(inst)
    if Settings.InstantPrompts and inst:IsA("ProximityPrompt") then
        task.defer(instantPrompt, inst)
    end
end)

--// ESP \\--
local Esp = {}
local function espEntry(model)
    local e = Esp[model]
    if e then
        return e
    end
    local part = anyPart(model)
    if not part then
        return nil
    end
    local bb = Instance.new("BillboardGui")
    bb.Name = "NNEsp"
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(220, 34)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
    bb.LightInfluence = 0
    bb.MaxDistance = math.huge
    bb.Adornee = part
    bb.Parent = VisualGui
    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Size = UDim2.fromScale(1, 1)
    text.Font = Enum.Font.GothamMedium
    text.TextSize = 12
    text.TextStrokeTransparency = 0.35
    text.Parent = bb
    e = { bb = bb, text = text }
    Esp[model] = e
    return e
end

local function dropEsp(model)
    local e = Esp[model]
    if e then
        e.bb:Destroy()
        if e.hl then
            e.hl:Destroy()
        end
        Esp[model] = nil
    end
end

local function updateEsp()
    local hrp = rootPart()
    local want = {}
    local function consider(model, color, text)
        local pos = pivotPos(model)
        local d = hrp and pos and (pos - hrp.Position).Magnitude
        if d and d <= Settings.EspDistance then
            want[model] = { color = color, text = text .. string.format(" · %dm", math.floor(d)) }
        end
    end

    if hrp then
        local folder = charactersFolder()
        if folder and (Settings.EspMobs or Settings.EspKids) then
            for _, model in folder:GetChildren() do
                local kind = mobKind(model)
                if kind == "Kid" then
                    if Settings.EspKids then
                        consider(model, Settings.KidColor, model:GetAttribute("PingName") or spaced(model:GetAttribute("KidId") or "Kid"))
                    end
                elseif kind and kind ~= "Dead" and kind ~= "Immune" and Settings.EspMobs then
                    local label = (model:GetAttribute("Name") or cleanName(model.Name)) .. " [" .. kind .. "]"
                    local npc = model:FindFirstChild("NPC")
                    if Settings.EspShowHealth and npc and npc:IsA("Humanoid") then
                        label ..= string.format(" %d/%d", math.floor(npc.Health), math.floor(npc.MaxHealth))
                    end
                    consider(model, MobColors[kind] or Color3.new(1, 1, 1), label)
                end
            end
        end
        if Settings.EspPlayers then
            for _, player in Players:GetPlayers() do
                if player ~= LocalPlayer and player.Character then
                    consider(player.Character, Settings.PlayerColor, player.DisplayName)
                end
            end
        end
        local items = Workspace:FindFirstChild("Items")
        if items and (Settings.EspChests or Settings.EspItems) then
            for _, model in items:GetChildren() do
                local interaction = model:GetAttribute("Interaction")
                if interaction == "ItemChest" then
                    if Settings.EspChests then
                        consider(model, Settings.ChestColor, model:GetAttribute("ChestName") or cleanName(model.Name))
                    end
                elseif interaction and Settings.EspItems and Settings.EspItemKinds[itemKind(model)] then
                    consider(model, Settings.ItemColor, cleanName(model.Name))
                end
            end
        end
    end

    for model in Esp do
        if not want[model] or not model.Parent then
            dropEsp(model)
        end
    end
    for model, info in want do
        local e = espEntry(model)
        if e then
            e.text.Text = info.text
            e.text.TextColor3 = info.color
            if Settings.EspHighlight then
                if not e.hl then
                    e.hl = Instance.new("Highlight")
                    e.hl.FillTransparency = 0.75
                    e.hl.OutlineTransparency = 0.1
                    e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    e.hl.Adornee = model
                    e.hl.Parent = VisualGui
                end
                e.hl.FillColor = info.color
                e.hl.OutlineColor = info.color
            elseif e.hl then
                e.hl:Destroy()
                e.hl = nil
            end
        end
    end
end

--// Lighting \\--
local LightingSaved = nil
local EffectsSaved = {}
local function saveLighting()
    if LightingSaved then
        return
    end
    LightingSaved = {
        Brightness = Lighting.Brightness,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        GlobalShadows = Lighting.GlobalShadows,
        FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart,
        ClockTime = Lighting.ClockTime,
        ExposureCompensation = Lighting.ExposureCompensation,
    }
end
local function restoreLighting()
    if Settings.Fullbright or Settings.NoFog or Settings.AlwaysDay then
        return
    end
    if LightingSaved then
        for k, v in LightingSaved do
            pcall(function()
                Lighting[k] = v
            end)
        end
        LightingSaved = nil
    end
    for effect, props in EffectsSaved do
        if effect.Parent then
            for k, v in props do
                pcall(function()
                    effect[k] = v
                end)
            end
        end
    end
    table.clear(EffectsSaved)
end
local function saveEffect(effect, prop)
    EffectsSaved[effect] = EffectsSaved[effect] or {}
    if EffectsSaved[effect][prop] == nil then
        EffectsSaved[effect][prop] = effect[prop]
    end
end

-- The game rewrites lighting every frame for day/night, so this runs every frame too.
local function lightingStep()
    if not (Settings.Fullbright or Settings.NoFog or Settings.AlwaysDay) then
        return
    end
    saveLighting()
    if Settings.Fullbright then
        Lighting.Brightness = 2
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.GlobalShadows = false
        Lighting.ExposureCompensation = 0
    end
    if Settings.AlwaysDay then
        Lighting.ClockTime = 14
    end
    if Settings.NoFog then
        Lighting.FogStart = 0
        Lighting.FogEnd = 1e6
    end
    for _, effect in Lighting:GetChildren() do
        if Settings.NoFog and effect:IsA("Atmosphere") then
            saveEffect(effect, "Density")
            saveEffect(effect, "Haze")
            effect.Density = 0
            effect.Haze = 0
        elseif Settings.Fullbright and effect:IsA("ColorCorrectionEffect") then
            saveEffect(effect, "Enabled")
            effect.Enabled = false
        end
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Survive 99 Nights",
    Footer = "dookie hub · Ui3",
    Icon = "trees",
    Size = UDim2.fromOffset(760, 580),
    ConfigFolder = "Ui3/Survive99Nights",
})

-- Dashboard ---------------------------------------------------------------------
local DashTab = Window:AddTab("Dashboard", "layout-dashboard", "Night and game info")

local NightBox = DashTab:AddBigGroupbox("Night", "moon")
local NightCards = NightBox:AddStatCards("NightCards", {
    Cards = {
        { Title = "Day", Value = "-", Icon = "calendar" },
        { Title = "Phase", Value = "-", Icon = "sun-moon" },
        { Title = "Time left", Value = "-", Icon = "clock" },
        { Title = "Weather", Value = "-", Icon = "cloud" },
    },
})
local PhaseBar = NightBox:AddProgressBar("PhaseBar", { Text = "Until night", Default = 0, Max = 1, Percent = true })
local NightCards2 = NightBox:AddStatCards("NightCards2", {
    Cards = {
        { Title = "Cultist attack", Value = "-", Icon = "skull" },
        { Title = "Biome", Value = "-", Icon = "map" },
        { Title = "Kids missing", Value = "-", Icon = "search" },
        { Title = "Hostiles near", Value = "-", Icon = "swords" },
    },
})

local YouBox = DashTab:AddBigGroupbox("You", "user")
local YouCards = YouBox:AddStatCards("YouCards", {
    Cards = {
        { Title = "Health", Value = "-", Icon = "heart" },
        { Title = "Hunger", Value = "-", Icon = "drumstick" },
        { Title = "Temperature", Value = "-", Icon = "thermometer" },
        { Title = "Class", Value = "-", Icon = "shield" },
    },
})
local HungerBar = YouBox:AddProgressBar("HungerBar", { Text = "Hunger", Default = 0, Max = 200, Percent = false })
local HealthBar = YouBox:AddProgressBar("HealthBar", { Text = "Health", Default = 0, Max = 100, Percent = false })

local GameBox = DashTab:AddBigGroupbox("Game", "gamepad-2")
local GameCards = GameBox:AddStatCards("GameCards", {
    Cards = {
        { Title = "Camp fire fuel", Value = "-", Icon = "flame" },
        { Title = "Diamonds", Value = "-", Icon = "gem" },
        { Title = "Players", Value = "-", Icon = "users" },
        { Title = "Server age", Value = "-", Icon = "timer" },
    },
})
local FireBar = GameBox:AddProgressBar("FireBar", { Text = "Camp fire fuel", Default = 0, Max = 100, Percent = false })
local EventLog = GameBox:AddLog("EventLog", { Text = "Events", Height = 140, MaxLines = 150 })

-- Main ---------------------------------------------------------------------------
local MainTab = Window:AddTab("Main", "axe", "Auto chop and kill aura")

local ChopBox = MainTab:AddLeftGroupbox("Auto chop", "trees")
ChopBox:AddToggle("AutoChop", {
    Text = "Auto chop",
    Default = false,
    Tooltip = "Hits the nearest trees in range with your best axe, on the axe's own cooldown",
    Callback = function(v)
        Settings.AutoChop = v
    end,
})
ChopBox:AddSlider("ChopRange", {
    Text = "Chop distance",
    Default = Settings.ChopRange,
    Min = 0,
    Max = 200,
    Suffix = " studs",
    Callback = function(v)
        Settings.ChopRange = v
    end,
})
ChopBox:AddToggle("ShowChopRange", {
    Text = "Show chop range",
    Default = false,
    Callback = function(v)
        Settings.ShowChopRange = v
    end,
}):AddColorPicker("ChopColor", {
    Default = Settings.ChopColor,
    Title = "Chop range color",
    Callback = function(c)
        Settings.ChopColor = c
    end,
})
ChopBox:AddSlider("ChopPerSwing", {
    Text = "Trees per swing",
    Default = Settings.ChopPerSwing,
    Min = 1,
    Max = 10,
    Callback = function(v)
        Settings.ChopPerSwing = v
    end,
})
ChopBox:AddDropdown("ChopTypes", {
    Text = "What to chop",
    Values = { "Tree" },
    Default = { "Tree" },
    Multi = true,
    Tooltip = "Filled from what the map holds, so new resource types show up here on their own",
    Callback = function(v)
        Settings.ChopTypes = v
    end,
})

local AuraBox = MainTab:AddRightGroupbox("Kill aura", "swords")
AuraBox:AddToggle("KillAura", {
    Text = "Kill aura",
    Default = false,
    Tooltip = "Hits mobs in range with your best melee weapon. Kids and pets are never hit",
    Callback = function(v)
        Settings.KillAura = v
    end,
})
AuraBox:AddSlider("AuraRange", {
    Text = "Aura distance",
    Default = Settings.AuraRange,
    Min = 0,
    Max = 200,
    Suffix = " studs",
    Callback = function(v)
        Settings.AuraRange = v
    end,
})
AuraBox:AddToggle("ShowAuraRange", {
    Text = "Show aura range",
    Default = false,
    Callback = function(v)
        Settings.ShowAuraRange = v
    end,
}):AddColorPicker("AuraColor", {
    Default = Settings.AuraColor,
    Title = "Aura range color",
    Callback = function(c)
        Settings.AuraColor = c
    end,
})
AuraBox:AddSlider("AuraPerSwing", {
    Text = "Mobs per swing",
    Default = Settings.AuraPerSwing,
    Min = 1,
    Max = 10,
    Callback = function(v)
        Settings.AuraPerSwing = v
    end,
})
AuraBox:AddDropdown("AuraKinds", {
    Text = "Targets",
    Values = { "Hostile", "Can attack", "Passive" },
    Default = { "Hostile", "Can attack" },
    Multi = true,
    Tooltip = "Hostile: chasing or aggressive. Can attack: fights back. Passive: neither",
    Callback = function(v)
        Settings.AuraKinds = v
    end,
})
local AuraNearLabel = AuraBox:AddLabel("Nearby: -", true)

local SwingBox = MainTab:AddLeftGroupbox("Swing settings", "settings-2")
SwingBox:AddToggle("AutoEquip", {
    Text = "Auto equip the right tool",
    Default = Settings.AutoEquip,
    Callback = function(v)
        Settings.AutoEquip = v
    end,
})
SwingBox:AddDropdown("HitFrom", {
    Text = "Send hits from",
    Values = { "Your position", "Near target" },
    Default = Settings.HitFrom,
    Tooltip = "Near target reports the swing next to what you hit. Try it if far hits don't land",
    Callback = function(v)
        Settings.HitFrom = v or "Your position"
    end,
})
SwingBox:AddSlider("ExtraDelay", {
    Text = "Extra delay per swing",
    Default = 0,
    Min = 0,
    Max = 1000,
    Suffix = " ms",
    Callback = function(v)
        Settings.ExtraDelay = v
    end,
})
SwingBox:AddToggle("OneTool", {
    Text = "One tool for chop and aura",
    Default = Settings.OneTool,
    Tooltip = "With both on, swing your axe at mobs too instead of swapping to a weapon every other swing",
    Callback = function(v)
        Settings.OneTool = v
    end,
})
local AxeLabel = SwingBox:AddLabel("Axe: -", true)
local WeaponLabel = SwingBox:AddLabel("Weapon: -", true)
local BlockedLabel = SwingBox:AddLabel("", true)

local BringStatus, BringNames
do
-- Bring ---------------------------------------------------------------------------
local BringTab = Window:AddTab("Bring", "magnet", "Pull items to you, the fire or the bench")

local WhatBox = BringTab:AddLeftGroupbox("What", "package-search")
WhatBox:AddDropdown("BringKinds", {
    Text = "Item types",
    Values = ITEM_KINDS,
    Default = { "Fuel" },
    Multi = true,
    Tooltip = "Sorted by what an item does (burns, feeds, heals, scraps...), so new items fall in on their own",
    Callback = function(v)
        Settings.BringKinds = v
    end,
})
WhatBox:AddToggle("BringByName", {
    Text = "Pick by name instead",
    Default = false,
    Callback = function(v)
        Settings.BringByName = v
    end,
})
BringNames = WhatBox:AddDropdown("BringNames", {
    Text = "Item names",
    Values = {},
    Multi = true,
    Searchable = true,
    Callback = function(v)
        Settings.BringNames = v
    end,
})
WhatBox:AddButton("Refresh names", function()
    BringNames:SetValues(itemNames())
end)

local WhereBox = BringTab:AddRightGroupbox("Where", "map-pin")
WhereBox:AddDropdown("BringDest", {
    Text = "Bring to",
    Values = BRING_DESTS,
    Default = Settings.BringDest,
    Tooltip = "Camp fire burns fuel as it lands. Crafting bench scraps scrap as it lands",
    Callback = function(v)
        Settings.BringDest = v or "You"
    end,
})
local SpotLabel = WhereBox:AddLabel("Saved spot: none", true)
WhereBox:AddButton("Save current spot", function()
    local hrp = rootPart()
    if hrp then
        Settings.SavedSpot = CFrame.new(hrp.Position + hrp.CFrame.LookVector * 6)
        local p = Settings.SavedSpot.Position
        SpotLabel:SetText(string.format("Saved spot: %d, %d, %d", p.X, p.Y, p.Z))
    end
end)

local HowBox = BringTab:AddLeftGroupbox("How", "gauge")
HowBox:AddDropdown("BringMode", {
    Text = "Method",
    Values = { "Fast", "Safe" },
    Default = Settings.BringMode,
    Tooltip = "Fast moves many items per frame (100+ a second). Safe moves one at a time and waits until the server hands it over",
    Callback = function(v)
        Settings.BringMode = v or "Fast"
    end,
})
HowBox:AddSlider("BringPerFrame", {
    Text = "Items per frame (fast)",
    Default = Settings.BringPerFrame,
    Min = 1,
    Max = 50,
    Callback = function(v)
        Settings.BringPerFrame = v
    end,
})
HowBox:AddSlider("BringHold", {
    Text = "Hold before letting go",
    Default = Settings.BringHold,
    Min = 0,
    Max = 500,
    Suffix = " ms",
    Tooltip = "Raise this if items snap back to where they were",
    Callback = function(v)
        Settings.BringHold = v
    end,
})
HowBox:AddSlider("BringMax", {
    Text = "Max items per bring",
    Default = Settings.BringMax,
    Min = 1,
    Max = 500,
    Callback = function(v)
        Settings.BringMax = v
    end,
})
HowBox:AddSlider("BringRange", {
    Text = "Search distance",
    Default = Settings.BringRange,
    Min = 25,
    Max = 5000,
    Suffix = " studs",
    Callback = function(v)
        Settings.BringRange = v
    end,
})
HowBox:AddToggle("BringSkipNear", {
    Text = "Skip items already there",
    Default = Settings.BringSkipNear,
    Callback = function(v)
        Settings.BringSkipNear = v
    end,
})

local GoBox = BringTab:AddRightGroupbox("Bring", "send")
BringStatus = GoBox:AddLabel("Idle", true)
GoBox:AddButton({
    Text = "Bring now",
    Func = function()
        local n = runBring(Settings.BringKinds, Settings.BringNames, Settings.BringByName, Settings.BringDest)
        if n == 0 then
            BringStatus:SetText("Nothing to bring")
        end
    end,
}):AddButton({
    Text = "Stop",
    Func = function()
        Bring.token += 1
        Bring.running = false
    end,
})
GoBox:AddToggle("AutoBring", {
    Text = "Auto bring",
    Default = false,
    Callback = function(v)
        Settings.AutoBring = v
    end,
})
GoBox:AddSlider("AutoBringEvery", {
    Text = "Every",
    Default = Settings.AutoBringEvery,
    Min = 2,
    Max = 60,
    Suffix = " s",
    Callback = function(v)
        Settings.AutoBringEvery = v
    end,
})

local QuickBox = BringTab:AddRightGroupbox("Quick", "zap")
for _, quick in {
    { "Fuel to camp fire", { Fuel = true }, "Camp fire" },
    { "Scrap to crafting bench", { Scrap = true }, "Crafting bench" },
    { "Food to me", { Food = true }, "You" },
    { "Heals to me", { Heals = true }, "You" },
    { "Gear and ammo to me", { Gear = true, Ammo = true }, "You" },
    { "Gems to me", { Gems = true }, "You" },
} do
    QuickBox:AddButton(quick[1], function()
        local n = runBring(quick[2], {}, false, quick[3])
        if n == 0 then
            BringStatus:SetText("Nothing to bring")
        end
    end)
end
end

local refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems
do
-- Movement ------------------------------------------------------------------------
local MoveTab = Window:AddTab("Movement", "footprints", "Speed, jump, fly and teleports")

local MoveBox = MoveTab:AddLeftGroupbox("Movement", "move")
MoveBox:AddToggle("Speed", {
    Text = "Speed",
    Default = false,
    Callback = function(v)
        Settings.Speed = v
        if not v then
            local hum = humanoid()
            if hum and Settings.SpeedMethod == "WalkSpeed" then
                hum.WalkSpeed = 16
            end
        end
    end,
})
MoveBox:AddSlider("SpeedValue", {
    Text = "Walk speed",
    Default = Settings.SpeedValue,
    Min = 16,
    Max = 150,
    Callback = function(v)
        Settings.SpeedValue = v
    end,
})
MoveBox:AddDropdown("SpeedMethod", {
    Text = "Speed method",
    Values = { "WalkSpeed", "CFrame" },
    Default = Settings.SpeedMethod,
    Tooltip = "CFrame leaves the game's walk speed alone and pushes you along on top of it",
    Callback = function(v)
        Settings.SpeedMethod = v or "WalkSpeed"
    end,
})
MoveBox:AddDivider()
MoveBox:AddToggle("Jump", {
    Text = "Jump power",
    Default = false,
    Callback = function(v)
        Settings.Jump = v
        if not v then
            restoreJump()
        end
    end,
})
MoveBox:AddSlider("JumpValue", {
    Text = "Jump power",
    Default = Settings.JumpValue,
    Min = 50,
    Max = 250,
    Callback = function(v)
        Settings.JumpValue = v
    end,
})
MoveBox:AddToggle("InfJump", {
    Text = "Infinite jump",
    Default = false,
    Callback = function(v)
        Settings.InfJump = v
    end,
})
MoveBox:AddDivider()
MoveBox:AddToggle("Fly", {
    Text = "Fly",
    Default = false,
    Tooltip = "Thumbstick or WASD to move where the camera looks. Space/E up, Ctrl/Q down, or the ▲▼ buttons on mobile",
    Callback = function(v)
        Settings.Fly = v
        if not v then
            stopFly()
            FlyUpHeld, FlyDownHeld = false, false
        end
    end,
}):AddKeyPicker("FlyKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
MoveBox:AddSlider("FlySpeed", {
    Text = "Fly speed",
    Default = Settings.FlySpeed,
    Min = 16,
    Max = 280,
    Callback = function(v)
        Settings.FlySpeed = v
    end,
})
MoveBox:AddToggle("Noclip", {
    Text = "Noclip",
    Default = false,
    Callback = function(v)
        Settings.Noclip = v
        if not v then
            restoreNoclip()
        end
    end,
})
MoveBox:AddToggle("AntiAfk", {
    Text = "Anti AFK",
    Default = Settings.AntiAfk,
    Callback = function(v)
        Settings.AntiAfk = v
    end,
})

local TpSetBox = MoveTab:AddLeftGroupbox("Teleport settings", "settings")
TpSetBox:AddDropdown("TpMethod", {
    Text = "Teleport method",
    Values = { "Instant", "Tween" },
    Default = Settings.TpMethod,
    Callback = function(v)
        Settings.TpMethod = v or "Instant"
    end,
})
TpSetBox:AddSlider("TpSpeed", {
    Text = "Tween speed",
    Default = Settings.TpSpeed,
    Min = 30,
    Max = 280,
    Callback = function(v)
        Settings.TpSpeed = v
    end,
})
TpSetBox:AddButton("Stop tween", function()
    tpToken += 1
end)

-- Each teleport dropdown keeps a label -> target map that refreshes rebuild.
local function teleportPicker(box, idx, text, build, resolve)
    local map = {}
    local dropdown = box:AddDropdown(idx, { Text = text, Values = {}, Searchable = true, AllowNull = true })
    local function refresh()
        local list, order = build()
        map = list
        dropdown:SetValues(order)
    end
    box:AddButton({
        Text = "Teleport",
        Func = function()
            local label = dropdown.Value
            if not label or map[label] == nil then
                Library:Notify({ Title = "Teleport", Description = "Pick something first", Time = 2 })
                return
            end
            teleportTo(resolve(map[label]))
        end,
    }):AddButton({ Text = "Refresh", Func = refresh })
    return refresh
end

local PlaceBox = MoveTab:AddRightGroupbox("Places", "map-pin")
refreshPlaces = teleportPicker(PlaceBox, "TpPlace", "Camp and caves", placeTargets, function(getPos)
    return getPos()
end)

local LandBox = MoveTab:AddRightGroupbox("Landmarks", "landmark")
local landmarkEverything = false
refreshLandmarks = teleportPicker(LandBox, "TpLandmark", "Landmark", function()
    return landmarkTargets(landmarkEverything)
end, pivotPos)
LandBox:AddToggle("LandmarkAll", {
    Text = "List every landmark",
    Default = false,
    Tooltip = "Off lists the named ones (caves, ponds, traps, the mother tree...). On adds spawns, huts, graves and the rest",
    Callback = function(v)
        landmarkEverything = v
        refreshLandmarks()
    end,
})

local ChestBox = MoveTab:AddRightGroupbox("Chests", "package")
refreshChests = teleportPicker(ChestBox, "TpChest", "Chest (nearest first)", chestTargets, pivotPos)
ChestBox:AddButton("Nearest chest", function()
    local list, order = chestTargets()
    for _, label in order do
        if not label:find("(locked)", 1, true) then
            teleportTo(pivotPos(list[label]))
            return
        end
    end
    Library:Notify({ Title = "Teleport", Description = "No chest loaded", Time = 2 })
end)

local KidBox = MoveTab:AddLeftGroupbox("Lost kids", "baby")
refreshKids = teleportPicker(KidBox, "TpKid", "Kid", function()
    local list, order = {}, {}
    for kidId, info in kidPositions() do
        local label = info.name or spaced(kidId)
        list[label] = kidId
        table.insert(order, label)
    end
    table.sort(order)
    return list, order
end, function(kidId)
    local info = kidPositions()[kidId]
    if not info then
        return nil
    end
    local pos = info.pos
    if not info.live and pos.Y == 0 then
        -- The map point has no height; land well above and let gravity finish.
        pos = Vector3.new(pos.X, 60, pos.Z)
    end
    return pos
end)

local ItemBox = MoveTab:AddLeftGroupbox("Items", "box")
refreshItems = teleportPicker(ItemBox, "TpItem", "Nearest item of type", function()
    local list = {}
    local order = itemNameTargets()
    for _, name in order do
        list[name] = name
    end
    return list, order
end, function(name)
    return pivotPos(nearestItemNamed(name))
end)

local PlayerBox = MoveTab:AddRightGroupbox("Players", "users")
PlayerBox:AddDropdown("TpPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
PlayerBox:AddButton("Teleport", function()
    local name = Options.TpPlayer and Options.TpPlayer.Value
    local player = name and Players:FindFirstChild(name)
    local hrp = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    teleportTo(hrp and hrp.Position)
end)
end

do
-- Visuals -------------------------------------------------------------------------
local VisTab = Window:AddTab("Visuals", "eye", "ESP, kid dots and lighting")

local KidEspBox = VisTab:AddLeftGroupbox("Kid dots", "baby")
KidEspBox:AddToggle("KidDots", {
    Text = "Kid dots",
    Default = false,
    Tooltip = "A dot on each missing kid, from the server's map points, so they show even when not loaded. Off screen dots stick to the edge",
    Callback = function(v)
        Settings.KidDots = v
    end,
}):AddColorPicker("KidColor", {
    Default = Settings.KidColor,
    Title = "Kid color",
    Callback = function(c)
        Settings.KidColor = c
        MobColors.Kid = c
    end,
})
KidEspBox:AddToggle("KidLabels", {
    Text = "Show name and distance",
    Default = true,
    Callback = function(v)
        Settings.KidLabels = v
    end,
})

local EspBox = VisTab:AddLeftGroupbox("ESP", "scan-eye")
EspBox:AddToggle("EspMobs", {
    Text = "Mobs",
    Default = false,
    Tooltip = "Red hostile, orange can attack, green passive, blue pets",
    Callback = function(v)
        Settings.EspMobs = v
    end,
})
EspBox:AddToggle("EspKids", {
    Text = "Kids (loaded)",
    Default = false,
    Callback = function(v)
        Settings.EspKids = v
    end,
})
EspBox:AddToggle("EspPlayers", {
    Text = "Players",
    Default = false,
    Callback = function(v)
        Settings.EspPlayers = v
    end,
}):AddColorPicker("PlayerColor", {
    Default = Settings.PlayerColor,
    Title = "Player color",
    Callback = function(c)
        Settings.PlayerColor = c
    end,
})
EspBox:AddToggle("EspChests", {
    Text = "Chests",
    Default = false,
    Callback = function(v)
        Settings.EspChests = v
    end,
}):AddColorPicker("ChestColor", {
    Default = Settings.ChestColor,
    Title = "Chest color",
    Callback = function(c)
        Settings.ChestColor = c
    end,
})
EspBox:AddToggle("EspItems", {
    Text = "Items",
    Default = false,
    Callback = function(v)
        Settings.EspItems = v
    end,
}):AddColorPicker("ItemColor", {
    Default = Settings.ItemColor,
    Title = "Item color",
    Callback = function(c)
        Settings.ItemColor = c
    end,
})
EspBox:AddDropdown("EspItemKinds", {
    Text = "Item types",
    Values = { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency", "Other" },
    Default = { "Fuel", "Food", "Heals", "Scrap", "Gems", "Ammo", "Gear", "Seeds", "Currency" },
    Multi = true,
    Tooltip = "Sorted by what the item does (burns, feeds, scraps...), so new items fall in on their own",
    Callback = function(v)
        Settings.EspItemKinds = v
    end,
})

local EspSetBox = VisTab:AddRightGroupbox("ESP settings", "sliders-horizontal")
EspSetBox:AddToggle("EspHighlight", {
    Text = "Highlights",
    Default = true,
    Tooltip = "Roblox draws at most 31 highlights at once; names always show",
    Callback = function(v)
        Settings.EspHighlight = v
    end,
})
EspSetBox:AddToggle("EspShowHealth", {
    Text = "Mob health",
    Default = true,
    Callback = function(v)
        Settings.EspShowHealth = v
    end,
})
EspSetBox:AddSlider("EspDistance", {
    Text = "Max distance",
    Default = Settings.EspDistance,
    Min = 50,
    Max = 2000,
    Suffix = " studs",
    Callback = function(v)
        Settings.EspDistance = v
    end,
})

local WorldBox = VisTab:AddRightGroupbox("World", "sun")
WorldBox:AddToggle("Fullbright", {
    Text = "Fullbright",
    Default = false,
    Callback = function(v)
        Settings.Fullbright = v
        restoreLighting()
    end,
})
WorldBox:AddToggle("NoFog", {
    Text = "No fog",
    Default = false,
    Callback = function(v)
        Settings.NoFog = v
        restoreLighting()
    end,
})
WorldBox:AddToggle("AlwaysDay", {
    Text = "Always day (only on your screen)",
    Default = false,
    Callback = function(v)
        Settings.AlwaysDay = v
        restoreLighting()
    end,
})
WorldBox:AddToggle("FovOn", {
    Text = "Field of view",
    Default = false,
    Callback = function(v)
        Settings.FovOn = v
        if not v then
            Camera.FieldOfView = 70
        end
    end,
})
WorldBox:AddSlider("Fov", {
    Text = "FOV",
    Default = Settings.Fov,
    Min = 50,
    Max = 120,
    Callback = function(v)
        Settings.Fov = v
    end,
})
end

do
-- Extra ---------------------------------------------------------------------------
local ExtraTab = Window:AddTab("Extra", "sparkles", "Chests, kids, coins and survival helpers")

local LootBox = ExtraTab:AddLeftGroupbox("Loot", "package-open")
LootBox:AddToggle("AutoChests", {
    Text = "Auto open chests in range",
    Default = false,
    Tooltip = "Opens a chest once you're inside its own prompt range, without the 5.5 s hold. Skips locked and opened ones",
    Callback = function(v)
        Settings.AutoChests = v
    end,
})
LootBox:AddToggle("AutoCoins", {
    Text = "Auto collect coins and diamonds",
    Default = false,
    Callback = function(v)
        Settings.AutoCoins = v
    end,
})
LootBox:AddSlider("CoinRange", {
    Text = "Collect range",
    Default = Settings.CoinRange,
    Min = 5,
    Max = 80,
    Suffix = " studs",
    Callback = function(v)
        Settings.CoinRange = v
    end,
})
LootBox:AddToggle("InstantPrompts", {
    Text = "Instant interact (no hold)",
    Default = false,
    Callback = function(v)
        Settings.InstantPrompts = v
        setInstantPrompts(v)
    end,
})

local KidsBox = ExtraTab:AddRightGroupbox("Lost kids", "baby")
KidsBox:AddToggle("AutoBagKids", {
    Text = "Auto pick up kids",
    Default = false,
    Tooltip = "Puts a lost kid in your sack as soon as you're within 15 studs (the game's reach). Needs room in the sack",
    Callback = function(v)
        Settings.AutoBagKids = v
    end,
})
KidsBox:AddToggle("AutoDropKids", {
    Text = "Auto drop kids at camp",
    Default = false,
    Tooltip = "Takes kids out of your sack when you're within 30 studs of the camp fire",
    Callback = function(v)
        Settings.AutoDropKids = v
    end,
})

local SurviveBox = ExtraTab:AddLeftGroupbox("Survival", "heart-pulse")
SurviveBox:AddToggle("AutoEat", {
    Text = "Auto eat",
    Default = false,
    Tooltip = "Eats the nearest food in reach when hunger drops below the line",
    Callback = function(v)
        Settings.AutoEat = v
    end,
})
SurviveBox:AddSlider("EatBelow", {
    Text = "Eat below hunger",
    Default = Settings.EatBelow,
    Min = 10,
    Max = 200,
    Callback = function(v)
        Settings.EatBelow = v
    end,
})
SurviveBox:AddToggle("AutoHeal", {
    Text = "Auto heal",
    Default = false,
    Tooltip = "Uses the nearest bandage or medkit in reach when health drops below the line",
    Callback = function(v)
        Settings.AutoHeal = v
    end,
})
SurviveBox:AddSlider("HealBelow", {
    Text = "Heal below health",
    Default = Settings.HealBelow,
    Min = 5,
    Max = 95,
    Suffix = "%",
    Callback = function(v)
        Settings.HealBelow = v
    end,
})
SurviveBox:AddSlider("ConsumeRange", {
    Text = "Eat / heal reach",
    Default = Settings.ConsumeRange,
    Min = 5,
    Max = 80,
    Suffix = " studs",
    Tooltip = "The game lets you use things within 15 studs; more may or may not be accepted",
    Callback = function(v)
        Settings.ConsumeRange = v
    end,
})

local FireBox = ExtraTab:AddRightGroupbox("Camp fire", "flame")
FireBox:AddToggle("KeepFireFed", {
    Text = "Keep the fire fed",
    Default = false,
    Tooltip = "Brings fuel to the camp fire (and burns it) whenever its fuel drops below the line",
    Callback = function(v)
        Settings.KeepFireFed = v
    end,
})
FireBox:AddSlider("FireBelow", {
    Text = "Feed below fuel",
    Default = Settings.FireBelow,
    Min = 1,
    Max = 500,
    Callback = function(v)
        Settings.FireBelow = v
    end,
})
end

--// Loops \\--
bind(RunService.Heartbeat, function(dt)
    if not alive() then
        return
    end
    swingTick()
    movementStep(dt)
end)

bind(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    Camera = Workspace.CurrentCamera
    placeRing(ChopRing, Settings.ShowChopRange, Settings.ChopRange, Settings.ChopColor, 0.05)
    placeRing(AuraRing, Settings.ShowAuraRange, Settings.AuraRange, Settings.AuraColor, 0.15)
    updateKidDots()
    lightingStep()
    if Settings.FovOn then
        Camera.FieldOfView = Settings.Fov
    end
end)

task.spawn(function()
    while alive() do
        pcall(updateEsp)
        task.wait(0.25)
    end
end)

-- Teleport lists fill themselves once things load and when chests come or go.
task.spawn(function()
    task.wait(2)
    local lastAuto = 0
    while alive() do
        if os.clock() - lastAuto > 15 then
            lastAuto = os.clock()
            for _, refresh in { refreshPlaces, refreshLandmarks, refreshChests, refreshKids, refreshItems } do
                pcall(refresh)
            end
        end
        if #BringNames.Values == 0 then
            pcall(function()
                BringNames:SetValues(itemNames())
            end)
        end
        if pendingTypes and Options.ChopTypes then
            pendingTypes = false
            local types = {}
            for kind in ResourceTypes do
                table.insert(types, kind)
            end
            table.sort(types)
            Options.ChopTypes:SetValues(types)
        end
        task.wait(1)
    end
end)

-- Extra helpers and auto bring.
task.spawn(function()
    local lastAutoBring = 0
    while alive() do
        pcall(extraTick)
        if Settings.AutoBring and not Bring.running and os.clock() - lastAutoBring >= Settings.AutoBringEvery then
            lastAutoBring = os.clock()
            pcall(runBring, Settings.BringKinds, Settings.BringNames, Settings.BringByName, Settings.BringDest)
        end
        if Bring.running then
            BringStatus:SetText(string.format("Bringing %d / %d", math.min(Bring.done, Bring.total), Bring.total))
        elseif Bring.total > 0 then
            BringStatus:SetText(string.format("Done: %d item%s", Bring.total, Bring.total == 1 and "" or "s"))
        end
        task.wait(0.3)
    end
end)

-- Dashboard.
local Phase = { state = nil, max = 1, day = nil, weather = nil, cultist = nil }
local ChasedBy = {}
local startTime = os.clock()

local function logEvent(text, color)
    pcall(EventLog.Log, EventLog, text, color)
end

task.spawn(function()
    while alive() do
        pcall(function()
            local state = Workspace:GetAttribute("State") or "-"
            local left = Workspace:GetAttribute("SecondsLeft") or 0
            local day = Workspace:GetAttribute("StoryDayCounter") or Workspace:GetAttribute("RealDayCounter")
            local weather = Workspace:GetAttribute("Weather") or "-"
            local cultist = Workspace:GetAttribute("CultistAttackDay") == true

            if state ~= Phase.state then
                if Phase.state ~= nil then
                    logEvent((state == "Night" and "Night" or "Day") .. " started (day " .. tostring(day) .. ")",
                        state == "Night" and Color3.fromRGB(150, 140, 255) or Color3.fromRGB(255, 220, 120))
                end
                Phase.state = state
                Phase.max = math.max(left, 1)
            end
            Phase.max = math.max(Phase.max, left)
            if day ~= Phase.day then
                if Phase.day ~= nil then
                    logEvent("Day " .. tostring(day))
                end
                Phase.day = day
            end
            if weather ~= Phase.weather then
                if Phase.weather ~= nil then
                    logEvent("Weather: " .. tostring(weather))
                end
                Phase.weather = weather
            end
            if cultist ~= Phase.cultist then
                if cultist then
                    logEvent("Cultist attack tonight", Color3.fromRGB(255, 90, 90))
                end
                Phase.cultist = cultist
            end

            NightCards:SetValue("Day", tostring(day or "-"))
            NightCards:SetValue("Phase", state)
            NightCards:SetValue("Time left", clock(left))
            NightCards:SetValue("Weather", tostring(weather))
            PhaseBar:SetText(state == "Night" and "Until morning" or "Until night")
            PhaseBar:SetMax(Phase.max)
            PhaseBar:SetValue(Phase.max - left)

            local missing = 0
            local missingFolder = mapFolder("MissingKids")
            if missingFolder then
                for _, value in missingFolder:GetAttributes() do
                    if typeof(value) == "Vector3" then
                        missing += 1
                    end
                end
            end
            local counts = { Hostile = 0, ["Can attack"] = 0, Passive = 0 }
            local folder = charactersFolder()
            local hrp = rootPart()
            if folder then
                for _, model in folder:GetChildren() do
                    local kind = mobKind(model)
                    if counts[kind] and hrp then
                        local pos = mobPos(model)
                        if pos and (pos - hrp.Position).Magnitude <= math.max(Settings.AuraRange, 60) then
                            counts[kind] += 1
                        end
                    end
                    if kind == "Hostile" and model:GetAttribute("ChasingPlayer") == LocalPlayer.UserId and model:GetAttribute("State") == "Chase" then
                        if not ChasedBy[model] then
                            ChasedBy[model] = true
                            local name = model:GetAttribute("Name") or cleanName(model.Name)
                            logEvent(name .. " is chasing you", Color3.fromRGB(255, 120, 90))
                        end
                    elseif ChasedBy[model] then
                        ChasedBy[model] = nil
                    end
                end
            end
            for model in ChasedBy do
                if not model.Parent then
                    ChasedBy[model] = nil
                end
            end

            NightCards2:SetValue("Cultist attack", cultist and "Tonight" or "No")
            NightCards2:SetValue("Biome", tostring(Workspace:GetAttribute("Biome") or "-"))
            NightCards2:SetValue("Kids missing", tostring(missing))
            NightCards2:SetValue("Hostiles near", tostring(counts.Hostile))
            AuraNearLabel:SetText(string.format("Nearby: %d hostile · %d can attack · %d passive", counts.Hostile, counts["Can attack"], counts.Passive))
            AxeLabel:SetText("Axe: " .. SwingInfo.axe)
            WeaponLabel:SetText("Weapon: " .. SwingInfo.weapon)
            if Settings.AutoChop and SwingInfo.blocked > 0 then
                BlockedLabel:SetText(string.format("%d tree%s in range need%s a tier %s axe",
                    SwingInfo.blocked, SwingInfo.blocked == 1 and "" or "s", SwingInfo.blocked == 1 and "s" or "",
                    tostring(SwingInfo.blockedTier or "?")))
            else
                BlockedLabel:SetText("")
            end

            local hum = humanoid()
            local hunger = LocalPlayer:GetAttribute("Hunger") or 0
            local temp = LocalPlayer:GetAttribute("Temperature")
            local class = LocalPlayer:GetAttribute("Class")
            YouCards:SetValue("Health", hum and string.format("%d / %d", math.floor(hum.Health), math.floor(hum.MaxHealth)) or "-")
            YouCards:SetValue("Hunger", string.format("%d / 200", math.floor(hunger)))
            YouCards:SetValue("Temperature", temp and tostring(math.floor(temp)) or "-")
            YouCards:SetValue("Class", class and (class .. " " .. tostring(LocalPlayer:GetAttribute("ClassLevel") or "")) or "-")
            HungerBar:SetMax(math.max(200, hunger))
            HungerBar:SetValue(hunger)
            if hum then
                HealthBar:SetMax(math.max(hum.MaxHealth, 1))
                HealthBar:SetValue(hum.Health)
            end

            local camp = mapFolder("Campground")
            local fire = camp and camp:FindFirstChild("MainFire")
            local fuel = fire and fire:GetAttribute("FuelRemaining") or 0
            GameCards:SetValue("Camp fire fuel", fire and tostring(math.floor(fuel)) or "-")
            GameCards:SetValue("Diamonds", tostring(LocalPlayer:GetAttribute("Diamonds") or "-"))
            GameCards:SetValue("Players", #Players:GetPlayers() .. " / " .. Players.MaxPlayers)
            GameCards:SetValue("Server age", clock(Workspace.DistributedGameTime))
            FireBar:SetMax(math.max(FireBar.Max, fuel, 1))
            FireBar:SetValue(fuel)
        end)
        task.wait(0.25)
    end
end)

logEvent("Loaded in " .. string.format("%.1fs", os.clock() - startTime) .. " · place " .. game.PlaceId)

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
    Bring.token += 1
    if Settings.InstantPrompts then
        Settings.InstantPrompts = false
        setInstantPrompts(false)
    end
    stopFly()
    restoreNoclip()
    restoreJump()
    Settings.Fullbright, Settings.NoFog, Settings.AlwaysDay = false, false, false
    restoreLighting()
    if Settings.FovOn then
        Camera.FieldOfView = 70
    end
    local hum = humanoid()
    if hum and Settings.Speed and Settings.SpeedMethod == "WalkSpeed" then
        hum.WalkSpeed = 16
    end
    for model in Esp do
        dropEsp(model)
    end
    pcall(function()
        VisualGui:Destroy()
    end)
end

Library:OnUnload(cleanup)
Genv.__NinetyNineUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

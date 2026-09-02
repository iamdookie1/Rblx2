--[[
    Islands (Easy Games) — auto break

    This does not fire CLIENT_BLOCK_HIT_REQUEST itself. It drives the game's own
    AxeTool.startBlockHit loop and lies to it about one thing only: which block
    the mouse is pointing at. Everything downstream of that — the island
    permission check, isBreakable, the 0.3s hit delay and its potion scaling,
    the swing animation, the break particles, and the request payload with the
    signature field the server expects — is the game's code, unmodified.

    That matters because the game rate-limits its own remotes and reports a
    breach to AnalyticsService as Net_Ratelimiter_Fail. Anything that fires the
    break remote on its own schedule walks into that. Borrowing the real loop
    means the request rate is whatever the game would have produced from a
    player holding down the mouse, which is the whole point.

    Grounded in the 20260901 dump:
      ReplicatedStorage.TS.tool.tools.shared.axe-tool  AxeTool, base class for
        every block-breaking tool (ShovelTool sets it as __index)
      AxeTool.getTargettedBlock -> { block, part, pos, norm }, from a mouse ray
      AxeTool.startBlockHit     the swing loop; stops on breakCancelled
      AxeTool.onBlockHit        the island/breakable gate + the remote call
      ToolScript.onClickSetup   runs on every Equipped, for every tool
      ToolUtils.MAX_DISTANCE    24
      BlockUtils.BLOCK_SIZE     3, isIslandBlock, getIslandBlockFromChild
      BlockMeta                 miningExperience -> rock, tree -> tree,
                                cropHarvestConfig -> crop
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace = game:GetService('Workspace')
local CollectionService = game:GetService('CollectionService')
local UserInputService = game:GetService('UserInputService')

local LocalPlayer = Players.LocalPlayer

local Connections = {}
local function track(conn)
    Connections[#Connections + 1] = conn
    return conn
end

local function getChar()
    return LocalPlayer.Character
end
local function getRoot()
    local char = getChar()
    return char and char:FindFirstChild('HumanoidRootPart')
end
local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChildOfClass('Humanoid')
end
local function camPos()
    local cam = Workspace.CurrentCamera
    return cam and cam.CFrame.Position or Vector3.new()
end

--// game modules -------------------------------------------------------------
-- These are all already required by the game by the time this runs, so require
-- returns the cached table — the same one the live tool objects are using.

local Game = {}

local function resolve(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return node
end

local function loadGameModules()
    local TS = ReplicatedStorage:WaitForChild('TS', 20)
    if not TS then return false, 'ReplicatedStorage.TS never appeared' end

    local wanted = {
        { 'AxeTool', { 'tool', 'tools', 'shared', 'axe-tool' }, 'AxeTool' },
        { 'ToolScript', { 'tool', 'tool-script' }, 'ToolScript' },
        { 'ToolMeta', { 'tool', 'tool-meta' }, 'ToolMeta' },
        { 'BlockMeta', { 'block', 'block-meta' }, 'BlockMeta' },
        { 'BlockUtils', { 'util', 'block-utils' }, 'BlockUtils' },
        { 'IslandUtils', { 'util', 'island-utils' }, 'IslandUtils' },
        { 'ToolUtils', { 'util', 'tool-utils' }, 'ToolUtils' },
        { 'CombatUtils', { 'combat', 'combat-utils' }, 'CombatUtils' },
        { 'LivingEntity', { 'combat', 'living-entity' }, 'LivingEntityUtils' },
    }

    for _, entry in ipairs(wanted) do
        local module = resolve(TS, table.unpack(entry[2]))
        if not module then
            return false, 'missing module TS.' .. table.concat(entry[2], '.')
        end
        local ok, result = pcall(require, module)
        if not ok then
            return false, 'require failed on ' .. entry[1] .. ': ' .. tostring(result)
        end
        local value = result and result[entry[3]]
        if not value then
            return false, entry[1] .. ' module did not export ' .. entry[3]
        end
        Game[entry[1]] = value
    end
    return true
end

local ModulesOk, ModuleError = loadGameModules()

--// ui -----------------------------------------------------------------------

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'islands',
    SubTitle = 'auto break',
    Folder = 'Islands',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(120, 210, 120),
})

local function notify(title, content, kind, duration)
    Centrl:Notify({ Title = title, Content = content, Type = kind or 'info', Duration = duration or 5 })
end

if not ModulesOk then
    local FailTab = Window:Tab({ Title = 'error', Icon = 'triangle-alert' })
    local FailSec = FailTab:Section({ Title = 'could not start', Side = 'left' })
    FailSec:Paragraph({
        Title = 'this is not Islands, or the game changed',
        Content = tostring(ModuleError) .. '\n\nEverything here hangs off the game\'s own tool '
            .. 'and block modules. Without them there is nothing to drive, so nothing is hooked '
            .. 'and no remote is touched.',
    })
    Window:Load()
    return
end

--// block classification -----------------------------------------------------
-- Read straight out of BlockMeta rather than a hardcoded name list, so a
-- content update that adds a new rock or tree is picked up for free.

local Classify = {}

function Classify.hasTag(meta, tag)
    local tags = meta.islandCollectionServiceTags
    if type(tags) ~= 'table' then return false end
    for _, entry in ipairs(tags) do
        if entry == tag then return true end
    end
    return false
end

Classify.Order = { 'ores & rocks', 'trees', 'crops', 'flowers', 'everything else' }

Classify.Tests = {
    ['ores & rocks'] = function(meta) return meta.miningExperience ~= nil end,
    ['trees'] = function(meta) return meta.tree ~= nil end,
    ['crops'] = function(meta) return meta.cropHarvestConfig ~= nil end,
    ['flowers'] = function(meta) return Classify.hasTag(meta, 'flower') end,
}

function Classify.categoryOf(meta)
    for _, name in ipairs(Classify.Order) do
        local test = Classify.Tests[name]
        if test and test(meta) then return name end
    end
    return 'everything else'
end

function Classify.labelOf(meta, id)
    local display = meta.displayName
    if type(display) == 'string' and display ~= '' then return display end
    return id
end

--// config -------------------------------------------------------------------

local Config = {
    Enabled = false,

    -- The game's own mouse reach is ToolUtils.MAX_DISTANCE = 24. Going past it
    -- asks the server for something no legitimate client could have produced,
    -- so the slider stops there and the default sits well inside it.
    Radius = 16,

    -- Added on top of the tool's own blockHitDelay, never subtracted from it.
    -- The delay is the rate-limit budget; there is nothing to gain by shaving
    -- it and a Net_Ratelimiter_Fail analytics event to lose.
    ExtraDelay = 0.05,

    -- While the mouse is actually held down the player is mining something on
    -- purpose. Overriding their target then is the bug, not the feature.
    YieldToManualInput = true,
    ManualGrace = 0.4,

    RequireLineOfSight = true,
    FaceTarget = true,
    HighlightTarget = true,
    PreferClosest = true,

    -- Aim somewhere random on the chosen face instead of dead centre every
    -- swing, because a real mouse never lands on the same pixel twice.
    JitterAim = true,

    StopAfter = 0,          -- 0 = no limit

    -- A run of refusals used to switch auto break off, which meant walking back
    -- to the menu to flip it on again. It pauses instead: same back-off, no
    -- babysitting.
    RejectLimit = 3,
    PauseSeconds = 20,

    Categories = { ['ores & rocks'] = true },
    Blocks = {},            -- specific display names; empty means "no extra filter"
    Ignore = {},
}

local State = {
    Tool = nil,
    ToolName = '-',
    Weapon = nil,
    WeaponName = '-',
    Target = nil,
    Hit = nil,
    NextAllowed = 0,
    Swings = 0,
    Broken = 0,
    Rejects = 0,
    Blacklist = {},         -- block -> expiry tick
    Watch = nil,            -- { block, health, since }
    Pending = {},           -- blocks the client removed, awaiting the server's answer
    NextRestart = 0,
    NextPick = 0,
    NextRecapture = 0,
    LastSwingAt = 0,
    PausedUntil = 0,
    Highlight = nil,
    Running = false,
    LastReason = 'idle',
}

--// tool capture -------------------------------------------------------------
-- ToolScript.onClickSetup runs inside the Equipped handler for every tool, and
-- AxeTool inherits it without overriding, so wrapping it hands us the live
-- object for whatever the player just equipped. Tools that were already in hand
-- when this loaded are picked up by the re-equip below.

-- Kept so unload can put the game back exactly as it was found.
local Hooks = {}

Hooks.onClickSetup = Game.ToolScript.onClickSetup
Game.ToolScript.onClickSetup = function(self, ...)
    if type(self) == 'table' and rawget(self, 'instance') then
        if self.startBlockHit then
            State.Tool = self
            State.ToolName = tostring(self.instance and self.instance.Name or '?')
        end
        -- SwordTool is the only class with attemptHit, and every weapon in the
        -- game is one, so this catches swords, hammers and the rest without a
        -- name list to keep up to date.
        if self.attemptHit then
            State.Weapon = self
            State.WeaponName = tostring(self.instance and self.instance.Name or '?')
        end
    end
    return Hooks.onClickSetup(self, ...)
end

local function reEquipHeldTool()
    local char = getChar()
    local humanoid = getHumanoid()
    if not (char and humanoid) then return false end
    local tool = char:FindFirstChildOfClass('Tool')
    if not tool then return false end
    humanoid:UnequipTools()
    task.wait(0.15)
    humanoid:EquipTool(tool)
    return true
end

local function toolIsEquipped()
    local tool = State.Tool
    if not tool then return false end
    local instance = tool.instance
    if not (instance and instance.Parent) then return false end
    return instance.Parent == getChar()
end

--// targeting ----------------------------------------------------------------

local Target = {}

function Target.boxOf(block)
    if block:IsA('BasePart') then
        return block.CFrame, block.Size
    elseif block:IsA('Model') then
        local ok, cf, size = pcall(function()
            return block:GetBoundingBox()
        end)
        if ok and cf then return cf, size end
    end
    return nil, nil
end

-- Models have no Position, so anything that wants a block's location has to go
-- through the bounding box rather than reading .Position off the instance.
function Target.centreOf(block)
    local cf = select(1, Target.boxOf(block))
    return cf and cf.Position or nil
end

-- The face a player would be looking at: the one whose outward normal points
-- most directly at the camera. Returns an axis-aligned unit normal, which is
-- what getBlocksInRangeFromNormalizedFace rounds to anyway.
function Target.nearestFace(block)
    local cf, size = Target.boxOf(block)
    if not cf then return nil, nil end
    local centre = cf.Position
    local half = size * 0.5
    local toCamera = camPos() - centre
    local axes = {
        { Vector3.new(1, 0, 0), math.abs(toCamera.X), toCamera.X >= 0 and 1 or -1, half.X },
        { Vector3.new(0, 1, 0), math.abs(toCamera.Y), toCamera.Y >= 0 and 1 or -1, half.Y },
        { Vector3.new(0, 0, 1), math.abs(toCamera.Z), toCamera.Z >= 0 and 1 or -1, half.Z },
    }
    table.sort(axes, function(a, b) return a[2] > b[2] end)
    local best = axes[1]
    local normal = best[1] * best[3]
    return normal, centre + normal * best[4]
end

function Target.matches(block)
    local meta = Game.BlockMeta[block.Name]
    if not meta then return false end

    local label = Classify.labelOf(meta, block.Name)
    if Config.Ignore[label] then return false end

    local hasBlockFilter = next(Config.Blocks) ~= nil
    if hasBlockFilter and not Config.Blocks[label] then return false end

    local hasCategoryFilter = next(Config.Categories) ~= nil
    if hasCategoryFilter and not Config.Categories[Classify.categoryOf(meta)] then
        return false
    end

    -- With neither filter set nothing would be excluded, which is almost never
    -- what someone wants from a tool with a block picker on it.
    if not hasBlockFilter and not hasCategoryFilter then return false end
    return true
end

function Target.candidates(root)
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getChar() }

    local ok, parts = pcall(function()
        return Workspace:GetPartBoundsInRadius(root.Position, Config.Radius, params)
    end)
    if not ok or type(parts) ~= 'table' then return {} end

    local now = tick()
    local seen, out = {}, {}
    for _, part in ipairs(parts) do
        local block = Game.BlockUtils.getIslandBlockFromChild(part)
        if block and not seen[block] then
            seen[block] = true
            local blocked = State.Blacklist[block]
            if not (blocked and now < blocked) then
                if Target.matches(block) then
                    out[#out + 1] = block
                end
            end
        end
    end
    return out
end

-- Mirrors the game's own mouseRecurseRayAll: cast from the camera, and step
-- past anything that is not an island block instead of treating it as the hit.
function Target.trace(block, aimPos)
    local origin = camPos()
    local ignore = { getChar() }
    for _, smoke in ipairs(CollectionService:GetTagged('void-smoke')) do
        ignore[#ignore + 1] = smoke
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true

    local delta = aimPos - origin
    local length = delta.Magnitude
    -- ToolUtils doubles MAX_DISTANCE for the mouse ray, so 48 is the longest
    -- ray the real client ever casts at a block.
    if length > 48 then return nil end
    local direction = delta.Unit * (length + 0.5)

    for _ = 1, 10 do
        params.FilterDescendantsInstances = ignore
        local result = Workspace:Raycast(origin, direction, params)
        if not result then return nil end
        local hitBlock = Game.BlockUtils.getIslandBlockFromChild(result.Instance)
        if hitBlock == block then return result end
        if hitBlock then return nil end -- a different block is in the way
        ignore[#ignore + 1] = result.Instance
    end
    return nil
end

function Target.aimPoints(block)
    local cf, size = Target.boxOf(block)
    if not cf then return {} end

    -- Three tries, not one per face: a jittered point on the face a player
    -- would be looking at, that face's centre, and the block's own centre.
    -- Anything past that is a block worth skipping rather than hunting for.
    local normal, face = Target.nearestFace(block)
    if not normal then return { cf.Position } end

    local surface = face + normal * 0.05
    local points = {}

    if Config.JitterAim then
        local half = size * 0.5
        local spread = Vector3.new(
            (1 - math.abs(normal.X)) * half.X,
            (1 - math.abs(normal.Y)) * half.Y,
            (1 - math.abs(normal.Z)) * half.Z
        ) * 0.55
        points[#points + 1] = surface + Vector3.new(
            (math.random() * 2 - 1) * spread.X,
            (math.random() * 2 - 1) * spread.Y,
            (math.random() * 2 - 1) * spread.Z
        )
    end

    points[#points + 1] = surface
    points[#points + 1] = cf.Position
    return points
end

-- Builds the { block, part, pos, norm } that getTargettedBlock hands back. The
-- pos and norm come from a real raycast wherever line of sight is required, so
-- they describe a hit the server could reproduce rather than one we computed.
function Target.hitFor(block)
    if not Config.RequireLineOfSight then
        local normal, face = Target.nearestFace(block)
        local part = block:IsA('BasePart') and block
            or block:FindFirstChildWhichIsA('BasePart', true)
        if normal and part then
            return { block = block, part = part, pos = face, norm = normal }
        end
        return nil
    end
    for _, aim in ipairs(Target.aimPoints(block)) do
        local result = Target.trace(block, aim)
        if result then
            return {
                block = block,
                part = result.Instance,
                pos = result.Position,
                norm = result.Normal,
            }
        end
    end
    return nil
end

function Target.pick()
    local root = getRoot()
    local tool = State.Tool
    if not (root and tool) then return nil, 'no tool' end

    local blocks = Target.candidates(root)
    if #blocks == 0 then return nil, 'nothing in range' end

    local origin = root.Position
    table.sort(blocks, function(a, b)
        local pa = Target.centreOf(a) or origin
        local pb = Target.centreOf(b) or origin
        if Config.PreferClosest then
            return (pa - origin).Magnitude < (pb - origin).Magnitude
        end
        return (pa - origin).Magnitude > (pb - origin).Magnitude
    end)

    local rejectedPermission = false
    for index, block in ipairs(blocks) do
        if index > 40 then break end
        local breakable = false
        pcall(function()
            breakable = tool:isBreakable(block) and true or false
        end)
        if breakable then
            -- onBlockHit refuses blocks on islands we cannot modify, and a run
            -- of refused requests is itself a thing worth not generating.
            local allowed = true
            local centre = Target.centreOf(block)
            if centre then
                pcall(function()
                    local island = Game.IslandUtils.getIslandFromPosition(centre)
                    if island then
                        allowed = Game.IslandUtils.canModifyIsland(LocalPlayer, island) and true or false
                    end
                end)
            end
            if not allowed then
                rejectedPermission = true
            else
                local hit = Target.hitFor(block)
                if hit then
                    return block, nil, hit
                end
            end
        end
    end

    if rejectedPermission then
        return nil, 'no permission on this island'
    end
    return nil, 'nothing reachable'
end

--// highlight ----------------------------------------------------------------

local function clearHighlight()
    if State.Highlight then
        State.Highlight:Destroy()
        State.Highlight = nil
    end
end

local function showHighlight(block)
    if not Config.HighlightTarget then
        clearHighlight()
        return
    end
    if not State.Highlight then
        local highlight = Instance.new('Highlight')
        highlight.Name = 'centrl_target'
        highlight.FillColor = Color3.fromRGB(120, 210, 120)
        highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
        highlight.FillTransparency = 0.7
        highlight.OutlineTransparency = 0
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = Workspace
        State.Highlight = highlight
    end
    State.Highlight.Adornee = block
end

--// swing accounting ---------------------------------------------------------

-- How long a block's replicated Health can sit still while we swing at it
-- before we accept the server is refusing rather than lagging.
local REFUSAL_WINDOW = 2.5

-- No swing landing for this long while we hold a target means the game's loop
-- died on us — a manual click that cancelled it, a tool swap, a yield that
-- never came back. Restart it rather than sitting there looking enabled.
local SWING_WATCHDOG = 3
-- The break request is fired inside a deferred closure we cannot hook, but the
-- server's answer is observable: a real hit moves the block's replicated Health
-- value, and a refused one does not. Three swings with no movement means the
-- server is saying no, which is the point at which continuing is the mistake.

local function noteSwing(block)
    State.Swings = State.Swings + 1
    State.LastSwingAt = tick()
    State.NextAllowed = tick() + Config.ExtraDelay

    local health = block:FindFirstChild('Health')
    local value = health and health.Value or nil
    local watch = State.Watch

    if watch and watch.block == block then
        if value ~= nil and watch.health ~= nil and value < watch.health then
            watch.health = value
            watch.since = tick()
            State.Rejects = 0
        elseif tick() - watch.since >= REFUSAL_WINDOW then
            -- Timed rather than counted. The first reading is taken before the
            -- server has answered this swing at all, so counting swings punished
            -- latency; a block whose replicated health has not moved in this
            -- long is one the server is genuinely refusing.
            State.Blacklist[block] = tick() + 30
            State.Rejects = State.Rejects + 1
            State.Watch = nil
            State.LastReason = 'server refused ' .. tostring(block.Name)
        end
    else
        State.Watch = { block = block, health = value, since = tick() }
    end
end

Hooks.onBlockHit = Game.AxeTool.onBlockHit
Game.AxeTool.onBlockHit = function(self, block, ...)
    local result = Hooks.onBlockHit(self, block, ...)
    if Config.Enabled and State.Tool == self and typeof(block) == 'Instance' then
        pcall(noteSwing, block)
    end
    return result
end

--// the lie ------------------------------------------------------------------
-- One function, one behaviour change: while auto break is on and this is the
-- tool we are driving, the mouse "points at" whatever our loop chose. Off, or
-- on any other tool, the original runs and nothing is different.

-- Deciding whether a press is a mining press, the way the game decides it.
--
-- AxeTool.onEquip binds Button1Down straight to startBlockHit on desktop, and
-- on touch it binds a "block-confirm" render step that needs the finger held
-- for 0.3s on a target that has not changed, cancelled the moment the humanoid
-- starts moving. Either way the swing only lands if getTargettedBlock actually
-- returns a block. So a press is a mining press when it is held over a block
-- the real mouse ray reaches — a click on the sky, on the UI, or on a wall is
-- not one, and standing down for it was the thing that made auto break feel
-- like it had stopped working.
local Manual = {
    down = false,
    downAt = 0,
    releasedAt = 0,
    touch = false,
    moveCancelled = false,
    wasMining = false,
    cache = nil,
    cacheAt = 0,
}

local TOUCH_HOLD = 0.3      -- the block-confirm threshold, from AxeTool.onEquip

-- The original, asked at most twenty times a second. It raycasts, and it gets
-- called twice per iteration of the game's own loop as well as from our tick.
local function realTargetBlock()
    local tool = State.Tool
    if not tool then return nil end
    if tick() - Manual.cacheAt < 0.05 then
        return Manual.cache
    end
    local ok, result = pcall(Hooks.getTargettedBlock, tool)
    Manual.cache = (ok and type(result) == 'table') and result.block or nil
    Manual.cacheAt = tick()
    return Manual.cache
end

local function manualActive()
    if not Config.YieldToManualInput then return false end

    if not Manual.down then
        -- Still inside the grace window after a release that was mining.
        return Manual.wasMining == true
            and tick() - Manual.releasedAt < Config.ManualGrace
    end

    if Manual.moveCancelled then return false end
    -- Touch needs the hold, exactly as block-confirm does.
    if Manual.touch and tick() - Manual.downAt < TOUCH_HOLD then return false end

    local mining = realTargetBlock() ~= nil
    Manual.wasMining = mining
    return mining
end

local function isManualInput(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or not isManualInput(input) then return end
    Manual.down = true
    Manual.downAt = tick()
    Manual.touch = input.UserInputType == Enum.UserInputType.Touch
    Manual.moveCancelled = false
    Manual.wasMining = false
end))

-- TouchMoved with the humanoid moving unbinds block-confirm in the game, so a
-- drag is a camera drag, not a mining hold.
track(UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Touch then return end
    if not Manual.down then return end
    local humanoid = getHumanoid()
    if humanoid and humanoid.MoveDirection.Magnitude > 0 then
        Manual.moveCancelled = true
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if not isManualInput(input) then return end
    Manual.down = false
    Manual.releasedAt = tick()
    -- The tool's own Button1Up handler set breakCancelled, which ends the swing
    -- loop a frame later. Clear it once the grace window is up so auto break
    -- picks straight back up instead of sitting out a restart.
    task.delay(Config.ManualGrace + 0.05, function()
        if Config.Enabled and not Manual.down and State.Tool then
            State.Tool.breakCancelled = false
        end
    end)
end))

Hooks.getTargettedBlock = Game.AxeTool.getTargettedBlock
Game.AxeTool.getTargettedBlock = function(self, ...)
    if not (Config.Enabled and State.Tool == self) or manualActive() then
        return Hooks.getTargettedBlock(self, ...)
    end
    local hit = State.Hit
    if hit and hit.block and hit.block.Parent then
        return hit
    end
    return { block = nil }
end

--// driver -------------------------------------------------------------------

local function stopSwinging()
    local tool = State.Tool
    if tool then
        tool.breakCancelled = true
    end
    State.Hit = nil
    State.Target = nil
    clearHighlight()
end

local function startSwinging()
    local tool = State.Tool
    if not tool then return false end
    if tool.isHitting then return true end
    -- Each run of startBlockHit pushes two more mouse connections onto the
    -- tool, and they only come off on unequip. Restarting it on every tick
    -- would grow that list without bound, so restarts are paced.
    if tick() < State.NextRestart then return false end
    State.NextRestart = tick() + 0.75
    task.spawn(function()
        local ok, err = pcall(function()
            tool:startBlockHit()
        end)
        if not ok then
            warn('[islands] startBlockHit: ' .. tostring(err))
        end
    end)
    return true
end

local function faceTowards(position)
    local root = getRoot()
    if not root then return end
    local flat = Vector3.new(position.X, root.Position.Y, position.Z)
    local delta = flat - root.Position
    if delta.Magnitude < 0.5 then return end
    local wanted = delta.Unit
    local facing = root.CFrame.LookVector
    local facingFlat = Vector3.new(facing.X, 0, facing.Z)
    if facingFlat.Magnitude > 0 and facingFlat.Unit:Dot(wanted) > 0.9 then
        return -- already close enough; do not fight the player's own turning
    end
    root.CFrame = CFrame.lookAt(root.Position, flat)
end

-- Re-scanning the island ten times a second to land on the same block again is
-- wasted work, so a target is kept until it stops being a valid one. The aim
-- point is still re-traced each pass, because the camera moves even when the
-- block does not.
local function targetStillGood()
    local block = State.Target
    if not (block and block.Parent) then return false end
    local blocked = State.Blacklist[block]
    if blocked and tick() < blocked then return false end
    if not Target.matches(block) then return false end
    local root = getRoot()
    if not root then return false end
    local centre = Target.centreOf(block)
    if not centre then return false end
    return (centre - root.Position).Magnitude <= Config.Radius + 3
end

local function tick_()
    if not Config.Enabled then return end

    if tick() < State.PausedUntil then
        State.LastReason = ('paused %ds — server was refusing blocks')
            :format(math.ceil(State.PausedUntil - tick()))
        return
    end

    if not toolIsEquipped() then
        State.LastReason = 'no breaking tool equipped'
        State.Hit = nil
        clearHighlight()
        -- The tool object only arrives through an Equipped, so a respawn or a
        -- hotbar swap leaves us with nothing to drive. Re-equip what is in hand
        -- and the capture hook fires again; without this the fix was toggling
        -- the whole thing off and on.
        if tick() >= State.NextRecapture then
            State.NextRecapture = tick() + 3
            task.spawn(function()
                pcall(reEquipHeldTool)
            end)
        end
        return
    end

    if Config.StopAfter > 0 and State.Broken >= Config.StopAfter then
        Config.Enabled = false
        stopSwinging()
        State.LastReason = 'stopped at ' .. tostring(Config.StopAfter) .. ' blocks'
        notify('auto break', State.LastReason, 'info')
        return
    end

    if State.Rejects >= Config.RejectLimit then
        State.Rejects = 0
        State.PausedUntil = tick() + Config.PauseSeconds
        stopSwinging()
        State.LastReason = 'pausing — server refused ' .. tostring(Config.RejectLimit) .. ' blocks in a row'
        notify('auto break', ('backing off for %ds, then carrying on'):format(Config.PauseSeconds),
            'warning', 6)
        return
    end

    -- onBlockHit sets block.Parent = nil the moment the client thinks a swing
    -- was lethal, and puts it back if the server disagrees. So a block that has
    -- just vanished is a question, not an answer: hold it and read the reply.
    local previous = State.Target
    if previous and not previous.Parent then
        if not State.Pending[previous] then
            State.Pending[previous] = { at = tick() }
        end
        if State.Watch and State.Watch.block == previous then
            State.Watch = nil
        end
        State.Target = nil
        State.Hit = nil
    end

    local now = tick()
    for block, entry in pairs(State.Pending) do
        if now - entry.at >= 1.25 then
            State.Pending[block] = nil
            if block.Parent then
                -- Put back, so the server refused the killing blow.
                State.Blacklist[block] = now + 30
                State.Rejects = State.Rejects + 1
                State.LastReason = 'server put ' .. tostring(block.Name) .. ' back'
            else
                State.Broken = State.Broken + 1
                State.Rejects = 0
            end
        end
    end

    if manualActive() then
        State.LastReason = 'standing down — you are mining by hand'
        clearHighlight()
        return
    end

    -- Watchdog. The game's loop exits on breakCancelled, which a real click
    -- sets, and it can also be left holding isHitting after a tool swap. If we
    -- have a target and nothing has landed for a while, break it out of
    -- whatever it is stuck in and let the restart below run.
    if State.Target and State.LastSwingAt > 0
        and tick() - State.LastSwingAt > SWING_WATCHDOG then
        local tool = State.Tool
        if tool then
            tool.breakCancelled = true
            tool.isHitting = false
        end
        State.LastSwingAt = tick()
        State.NextRestart = 0
        State.LastReason = 'swing loop stalled — restarting it'
    end

    if tick() < State.NextAllowed then return end

    if targetStillGood() then
        local refreshed = Target.hitFor(State.Target)
        if refreshed then
            State.Hit = refreshed
            showHighlight(State.Target)
            if Config.FaceTarget then
                pcall(faceTowards, refreshed.pos)
            end
            startSwinging()
            return
        end
    end

    if tick() < State.NextPick then return end
    State.NextPick = tick() + 0.25

    local block, reason, hit = Target.pick()
    if not block then
        State.Hit = nil
        State.Target = nil
        State.LastReason = reason or 'no target'
        clearHighlight()
        return
    end

    State.Target = block
    State.Hit = hit
    State.LastReason = 'breaking ' .. tostring(block.Name)
    showHighlight(block)

    if Config.FaceTarget then
        pcall(faceTowards, hit.pos)
    end

    startSwinging()
end

task.spawn(function()
    while true do
        task.wait(0.1)
        if State.Running then
            local ok, err = pcall(tick_)
            if not ok then
                warn('[islands] tick: ' .. tostring(err))
            end
        end
    end
end)
State.Running = true

--// block picker data --------------------------------------------------------

local Picker = { Labels = {}, Nearby = {} }

function Picker.scan()
    local root = getRoot()
    local found = {}
    if root then
        local params = OverlapParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { getChar() }
        local ok, parts = pcall(function()
            return Workspace:GetPartBoundsInRadius(root.Position, 120, params)
        end)
        if ok and type(parts) == 'table' then
            local seen = {}
            for _, part in ipairs(parts) do
                local block = Game.BlockUtils.getIslandBlockFromChild(part)
                if block and not seen[block] then
                    seen[block] = true
                    local meta = Game.BlockMeta[block.Name]
                    if meta then
                        found[Classify.labelOf(meta, block.Name)] = true
                    end
                end
            end
        end
    end

    local labels = {}
    for label in pairs(found) do
        labels[#labels + 1] = label
    end
    table.sort(labels)
    Picker.Nearby = labels
    return labels
end

function Picker.all()
    if #Picker.Labels > 0 then return Picker.Labels end
    local found = {}
    for id, meta in pairs(Game.BlockMeta) do
        if type(meta) == 'table' and not meta.notBreakable and not meta.liquid then
            found[Classify.labelOf(meta, id)] = true
        end
    end
    local labels = {}
    for label in pairs(found) do
        labels[#labels + 1] = label
    end
    table.sort(labels)
    Picker.Labels = labels
    return labels
end

--// optional client services -------------------------------------------------
-- These live under PlayerScripts rather than ReplicatedStorage, so they load
-- separately and the features that need them switch themselves off when they
-- are missing instead of taking the whole script down with them.

local Services = {}

local function requireExport(module, key)
    if not module then return nil end
    local ok, result = pcall(require, module)
    if not ok then return nil end
    return result and result[key] or nil
end

do
    local scripts = LocalPlayer:FindFirstChild('PlayerScripts')
    local playerTS = scripts and scripts:FindFirstChild('TS')
    if playerTS then
        Services.Crop = requireExport(resolve(playerTS, 'block', 'crop', 'crop-service'), 'CropService')
        Services.Inventory = requireExport(
            resolve(playerTS, 'ui', 'inventory', 'client-inventory-service'), 'ClientInventoryService')
    end
    Services.Remotes = requireExport(resolve(ReplicatedStorage, 'TS', 'remotes', 'remotes'), 'default')
    Services.Requests = requireExport(
        resolve(ReplicatedStorage, 'TS', 'legacy-network', 'legacy-requests'), 'LegacyRequests')
end

-- Several requests carry a fixed field the client always attaches. It is a
-- constant in the client rather than something derived, so a request without it
-- looks nothing like one the game would have sent. Copied byte for byte.
local PLACE_SIGNATURE_KEY = 'uwhiHAMdjExWka'
local PLACE_SIGNATURE = '\7\240\159\164\163\240\159\164\161\7\n\7\n\7\nffEgdldU'
local WORKER_SIGNATURE_KEY = 'gyxibhsvlSg'
local WORKER_SIGNATURE = '\7\240\159\164\163\240\159\164\161\7\n\7\n\7\nzjnceexFHUHoxcyirpdxflnudifxnil'

local function callRequest(name, payload)
    if not (Services.Remotes and Services.Requests) then return nil end
    local id = Services.Requests[name]
    if not id then return nil end
    local ok, result = pcall(function()
        return Services.Remotes.Client:Get(id):CallServer(payload)
    end)
    if not ok then return nil end
    return result
end

--// shared block scanning ----------------------------------------------------

local Scan = {}

-- One helper for every "what is near me" question in the script, so the radius
-- and the character filter are handled the same way everywhere.
-- maxParts matters at the radii the ESP uses: blocks are three studs, so a
-- 300-stud sphere is tens of thousands of parts and an uncapped query there
-- costs more than the highlights it feeds.
function Scan.partsNear(radius, maxParts)
    local root = getRoot()
    if not root then return {} end
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getChar() }
    if maxParts then
        params.MaxParts = maxParts
    end
    local ok, parts = pcall(function()
        return Workspace:GetPartBoundsInRadius(root.Position, radius, params)
    end)
    if not ok or type(parts) ~= 'table' then return {} end
    return parts
end

function Scan.blocksNear(radius, test, maxParts)
    local seen, out = {}, {}
    for _, part in ipairs(Scan.partsNear(radius, maxParts)) do
        local block = Game.BlockUtils.getIslandBlockFromChild(part)
        if block and not seen[block] then
            seen[block] = true
            if not test or test(block) then
                out[#out + 1] = block
            end
        end
    end
    return out
end

-- getBlocksFromLocation is the game's own occupancy check, so this answers
-- "would a place here be rejected" the way the game would answer it.
function Scan.spaceIsFree(position)
    local ok, blocks = pcall(function()
        return Game.BlockUtils.getBlocksFromLocation(position, {}, 1, true)
    end)
    if not ok or type(blocks) ~= 'table' then return false end
    return #blocks == 0
end

--// farm ---------------------------------------------------------------------

local Farm = {
    Harvest = false,
    Plant = false,
    Till = false,
    Radius = 24,
    Interval = 0.4,
    PerPass = 6,
    Harvested = 0,
    Planted = 0,
    Tilled = 0,
    Reason = 'idle',
}

-- CropPrediction.activateStageModel shows the live stage model and reads
-- Harvestable off it, so the same two lookups say whether a crop is ready.
function Farm.cropReady(model)
    local stage = model:FindFirstChild('stage')
    if not stage then return false end
    local staged = model:FindFirstChild('stage-' .. tostring(stage.Value))
    if not staged then return false end
    local flag = staged:FindFirstChild('Harvestable')
    return flag ~= nil and flag.Value == true
end

function Farm.isCrop(block)
    local meta = Game.BlockMeta[block.Name]
    return meta ~= nil and meta.cropHarvestConfig ~= nil
end

function Farm.canTill(block)
    local meta = Game.BlockMeta[block.Name]
    if not (meta and meta.hoeTillsTo) then return false end
    local centre = Target.centreOf(block)
    if not centre then return false end
    return Scan.spaceIsFree(centre + Vector3.new(0, Game.BlockUtils.BLOCK_SIZE, 0))
end

-- The seed in hand decides what gets planted and where it is allowed to go,
-- exactly as SeedTool's placement behaviour does.
function Farm.equippedSeed()
    local char = getChar()
    local tool = char and char:FindFirstChildOfClass('Tool')
    if not tool then return nil end
    local meta = Game.ToolMeta[tool.Name]
    local seed = meta and meta.cropSeed
    if not seed or not seed.cropName then return nil end
    return seed.cropName, seed.placedOnBlocks or { 'soil' }
end

function Farm.plantOn(block, cropName)
    -- The seed spreader tool sends exactly this: the soil block's CFrame lifted
    -- one block, the crop name, and the place signature.
    return callRequest('CLIENT_BLOCK_PLACE_REQUEST', {
        cframe = block.CFrame + Vector3.new(0, Game.BlockUtils.BLOCK_SIZE, 0),
        blockType = cropName,
        [PLACE_SIGNATURE_KEY] = PLACE_SIGNATURE,
    }) ~= nil
end

function Farm.runHarvest()
    if not Services.Crop then
        Farm.Reason = 'crop service missing'
        return
    end
    local ready = Scan.blocksNear(Farm.Radius, function(block)
        return Farm.isCrop(block) and Farm.cropReady(block)
    end)
    if #ready == 0 then return end

    for index, crop in ipairs(ready) do
        if index > Farm.PerPass or not Farm.Harvest then break end
        local ok = pcall(function()
            Services.Crop:harvestCrop(LocalPlayer, crop)
        end)
        if ok then
            Farm.Harvested = Farm.Harvested + 1
            Farm.Reason = 'harvested ' .. tostring(crop.Name)
        end
        task.wait(0.12)
    end
end

function Farm.runPlant()
    local cropName, placedOn = Farm.equippedSeed()
    if not cropName then
        Farm.Reason = 'no seed equipped'
        return
    end

    local allowed = {}
    for _, name in ipairs(placedOn) do
        allowed[name] = true
    end

    local lift = Vector3.new(0, Game.BlockUtils.BLOCK_SIZE, 0)
    local soil = Scan.blocksNear(Farm.Radius, function(block)
        if not allowed[block.Name] then return false end
        local centre = Target.centreOf(block)
        return centre ~= nil and Scan.spaceIsFree(centre + lift)
    end)
    if #soil == 0 then return end

    for index, block in ipairs(soil) do
        if index > Farm.PerPass or not Farm.Plant then break end
        if block:IsA('BasePart') and Farm.plantOn(block, cropName) then
            Farm.Planted = Farm.Planted + 1
            Farm.Reason = 'planted ' .. tostring(cropName)
        end
        task.wait(0.12)
    end
end

function Farm.runTill()
    local plots = Scan.blocksNear(Farm.Radius, Farm.canTill)
    if #plots == 0 then return end
    for index, block in ipairs(plots) do
        if index > Farm.PerPass or not Farm.Till then break end
        if callRequest('CLIENT_PLOW_BLOCK_REQUEST', { block = block }) ~= nil then
            Farm.Tilled = Farm.Tilled + 1
            Farm.Reason = 'tilled ' .. tostring(block.Name)
        end
        task.wait(0.12)
    end
end

task.spawn(function()
    while true do
        task.wait(Farm.Interval)
        if State.Running then
            if Farm.Harvest then pcall(Farm.runHarvest) end
            if Farm.Plant then pcall(Farm.runPlant) end
            if Farm.Till then pcall(Farm.runTill) end
        end
    end
end)

--// collect ------------------------------------------------------------------

local Collect = {
    Drops = false,
    Deposit = false,
    DropRadius = 30,
    ChestRadius = 20,
    Interval = 0.5,
    Items = {},
    KeepHeld = true,
    Picked = 0,
    Deposited = 0,
    Reason = 'idle',
}

-- A dropped item is a Tool whose visible part is called HandleDisabled, which
-- is the part pickupTool tweens toward the player before it asks the server.
function Collect.droppedTools(radius)
    local seen, out = {}, {}
    for _, part in ipairs(Scan.partsNear(radius)) do
        if part.Name == 'HandleDisabled' then
            local tool = part.Parent
            if tool and tool:IsA('Tool') and not seen[tool] then
                seen[tool] = true
                out[#out + 1] = tool
            end
        end
    end
    return out
end

function Collect.runDrops()
    if not Services.Inventory then
        Collect.Reason = 'inventory service missing'
        return
    end
    for _, tool in ipairs(Collect.droppedTools(Collect.DropRadius)) do
        if not Collect.Drops then break end
        if tool.Parent then
            local ok = pcall(function()
                Services.Inventory:pickupTool(tool)
            end)
            if ok then
                Collect.Picked = Collect.Picked + 1
                Collect.Reason = 'picked up ' .. tostring(tool.Name)
            end
            task.wait(0.15)
        end
    end
end

function Collect.nearestChest()
    local root = getRoot()
    if not root then return nil end
    local chests = Scan.blocksNear(Collect.ChestRadius, function(block)
        local ok, isChest = pcall(function()
            return Game.BlockUtils.isChestBlock(block)
        end)
        return ok and isChest and true or false
    end)
    local best, bestDistance = nil, math.huge
    for _, chest in ipairs(chests) do
        local centre = Target.centreOf(chest)
        if centre then
            local distance = (centre - root.Position).Magnitude
            if distance < bestDistance then
                best, bestDistance = chest, distance
            end
        end
    end
    return best
end

function Collect.backpackTools()
    local backpack = LocalPlayer:FindFirstChild('Backpack')
    if not backpack then return {} end
    local out = {}
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA('Tool') and item:FindFirstChild('Amount') then
            out[#out + 1] = item
        end
    end
    return out
end

function Collect.labelOfTool(tool)
    local display = tool:FindFirstChild('DisplayName')
    if display and display.Value ~= '' then return display.Value end
    local meta = Game.ToolMeta[tool.Name]
    if meta and meta.displayName then return meta.displayName end
    return tool.Name
end

-- The same shape ChestInventoryClickHandler sends: the chest block, the tool,
-- and the amount read straight off the tool.
function Collect.deposit(chest, tool)
    local amount = tool:FindFirstChild('Amount')
    local result = callRequest('CLIENT_CHEST_TRANSACTION', {
        player_tracking_category = 'join_from_web',
        chest = chest,
        action = 'deposit',
        tool = tool,
        amount = amount and amount.Value or 1,
    })
    return type(result) == 'table' and result.success == true
end

function Collect.runDeposit()
    if next(Collect.Items) == nil then
        Collect.Reason = 'nothing selected to deposit'
        return
    end
    local chest = Collect.nearestChest()
    if not chest then
        Collect.Reason = 'no chest in range'
        return
    end

    local char = getChar()
    local held = char and char:FindFirstChildOfClass('Tool')
    for _, tool in ipairs(Collect.backpackTools()) do
        if not Collect.Deposit then break end
        if not (Collect.KeepHeld and held and held.Name == tool.Name) then
            if Collect.Items[Collect.labelOfTool(tool)] then
                if Collect.deposit(chest, tool) then
                    Collect.Deposited = Collect.Deposited + 1
                    Collect.Reason = 'deposited ' .. Collect.labelOfTool(tool)
                end
                task.wait(0.15)
            end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(Collect.Interval)
        if State.Running then
            if Collect.Drops then pcall(Collect.runDrops) end
            if Collect.Deposit then pcall(Collect.runDeposit) end
        end
    end
end)

--// block esp ----------------------------------------------------------------

local Esp = {
    Enabled = false,
    Radius = 250,
    MaxBoxes = 250,
    Interval = 0.8,
    Colour = Color3.fromRGB(255, 200, 60),
    Transparency = 0.6,
    Categories = { ['ores & rocks'] = true },
    Blocks = {},
    Live = {},
    Folders = {},
    FoldersAt = 0,
}

function Esp.wants(block)
    local meta = Game.BlockMeta[block.Name]
    if not meta then return false end
    if next(Esp.Blocks) ~= nil then
        return Esp.Blocks[Classify.labelOf(meta, block.Name)] == true
    end
    if next(Esp.Categories) == nil then return false end
    return Esp.Categories[Classify.categoryOf(meta)] == true
end

function Esp.clear()
    for block, adorn in pairs(Esp.Live) do
        adorn:Destroy()
        Esp.Live[block] = nil
    end
end

-- The block folders, not a spatial query. GetPartBoundsInRadius has to be
-- given a MaxParts at ESP range or it walks tens of thousands of parts, and
-- once capped it returns an arbitrary subset — in practice the ground you are
-- standing on, never the vein forty studs out. Walking Blocks directly is both
-- exact and bounded by the number of blocks that actually exist.
function Esp.blockFolders()
    if tick() < Esp.FoldersAt and #Esp.Folders > 0 then
        return Esp.Folders
    end
    local folders = {}
    local islands = Workspace:FindFirstChild('Islands')
    if islands then
        for _, island in ipairs(islands:GetChildren()) do
            local blocks = island:FindFirstChild('Blocks')
            if blocks then
                folders[#folders + 1] = blocks
            end
        end
    end
    local wilderness = Workspace:FindFirstChild('WildernessBlocks')
    if wilderness then
        folders[#folders + 1] = wilderness
    end
    Esp.Folders = folders
    Esp.FoldersAt = tick() + 5
    return folders
end

function Esp.refresh()
    if not Esp.Enabled then
        if next(Esp.Live) ~= nil then Esp.clear() end
        return
    end

    local root = getRoot()
    if not root then return end
    local origin = root.Position
    local limit = Esp.Radius * Esp.Radius

    local found = {}
    for _, folder in ipairs(Esp.blockFolders()) do
        for _, block in ipairs(folder:GetChildren()) do
            local centre = Target.centreOf(block)
            if centre and (centre - origin).Magnitude ^ 2 <= limit and Esp.wants(block) then
                found[#found + 1] = { block = block, distance = (centre - origin).Magnitude }
            end
        end
    end

    table.sort(found, function(a, b) return a.distance < b.distance end)

    local keep = {}
    for index, entry in ipairs(found) do
        if index > Esp.MaxBoxes then break end
        local block = entry.block
        keep[block] = true
        local adorn = Esp.Live[block]
        if not adorn then
            -- BoxHandleAdornment rather than Highlight: Roblox renders only
            -- about thirty Highlights per client at once, so a hundred of them
            -- is ninety that silently draw nothing. Adornments have no such
            -- ceiling, and they take a Model's bounding box just as happily.
            local cf, size = Target.boxOf(block)
            if cf and size then
                adorn = Instance.new('BoxHandleAdornment')
                adorn.Name = 'centrl_block_esp'
                adorn.Adornee = Workspace.Terrain
                adorn.AlwaysOnTop = true
                adorn.ZIndex = 1
                adorn.Size = size + Vector3.new(0.06, 0.06, 0.06)
                adorn.CFrame = cf
                adorn.Parent = Workspace.Terrain
                Esp.Live[block] = adorn
            end
        end
        if adorn then
            adorn.Color3 = Esp.Colour
            adorn.Transparency = Esp.Transparency
        end
    end

    for block, adorn in pairs(Esp.Live) do
        if not keep[block] or not block.Parent then
            adorn:Destroy()
            Esp.Live[block] = nil
        end
    end
end

task.spawn(function()
    while true do
        task.wait(Esp.Interval)
        if State.Running then
            pcall(Esp.refresh)
        end
    end
end)

--// animals ------------------------------------------------------------------
-- Animals sit in Workspace.Islands.<id>-island.Entities as models carrying
-- their own state: LastPet, AnimalProductReady, FoodLevel, Happiness,
-- Favorites.Food. Every gate below is one the client's own interact handlers
-- check before they offer the option, so nothing here asks for something the
-- menu would have refused to show.

local Animals = {
    Pet = false,
    Milk = false,
    Feed = false,
    Honey = false,
    Radius = 60,
    Interval = 1,
    Petted = 0,
    Milked = 0,
    Fed = 0,
    Collected = 0,
    Reason = 'idle',
    Folders = {},
    FoldersAt = 0,
}

local TIME_BETWEEN_PET_SEC = 300    -- AnimalConst.TIME_BETWEEN_PET_SEC
local NECTAR_FOR_HONEY = 250        -- BeehiveInteractHandler's own threshold
local ANIMAL_MAX_FOOD = 1000        -- AnimalConst.ANIMAL_MAX_FOOD

function Animals.entityFolders()
    if tick() < Animals.FoldersAt and #Animals.Folders > 0 then
        return Animals.Folders
    end
    local folders = {}
    local islands = Workspace:FindFirstChild('Islands')
    if islands then
        for _, island in ipairs(islands:GetChildren()) do
            local entities = island:FindFirstChild('Entities')
            if entities then
                folders[#folders + 1] = entities
            end
        end
    end
    Animals.Folders = folders
    Animals.FoldersAt = tick() + 5
    return folders
end

function Animals.near()
    local root = getRoot()
    if not root then return {} end
    local out = {}
    for _, folder in ipairs(Animals.entityFolders()) do
        for _, model in ipairs(folder:GetChildren()) do
            local part = model:FindFirstChild('HumanoidRootPart')
            if part and (part.Position - root.Position).Magnitude <= Animals.Radius then
                out[#out + 1] = model
            end
        end
    end
    return out
end

function Animals.heldToolName()
    local char = getChar()
    local tool = char and char:FindFirstChildOfClass('Tool')
    return tool and tool.Name or nil
end

function Animals.canPet(model)
    local last = model:FindFirstChild('LastPet')
    if not last then return false end
    return os.time() - last.Value >= TIME_BETWEEN_PET_SEC
end

-- CowInteractHandler only offers Milk when an emptyBucket is in hand and the
-- animal has a product waiting, so both are checked here too.
function Animals.canMilk(model)
    local ready = model:FindFirstChild('AnimalProductReady')
    if not (ready and ready.Value > 0) then return false end
    local held = Animals.heldToolName()
    if not held then return false end
    local meta = Game.ToolMeta[held]
    return meta ~= nil and meta.emptyBucket ~= nil
end

-- Feeding, written against AnimalInteractHandler.getInteractOptions rather than
-- guessed at. The first version of this was wrong on every clause: it tested
-- ToolMeta.food, which food tools have and animal feed does not; it never
-- looked at the species' own definite list at all; and it read favourites by
-- child name when getFavoriteFoods reads their Value. Feeding did nothing
-- because the server was being asked for things the menu would never offer.
--
-- The real gate, in order:
--   BlockMeta[animal.Name].animal exists, and the animal is not Sleeping
--   ToolMeta[held].animalFood exists
--   if that food triggers breeding, the animal has to be an adult
--   FoodLevel is under 95% of max, unless the food breeds or is vitamins
--   held name is in animal.foods.definite, or in this animal's Favorites.Food
function Animals.canFeed(model)
    local char = getChar()
    local held = char and char:FindFirstChildOfClass('Tool')
    if not held then return false end

    local animalMeta = Game.BlockMeta[model.Name]
    if not (animalMeta and animalMeta.animal) then return false end

    local toolMeta = Game.ToolMeta[held.Name]
    local animalFood = toolMeta and toolMeta.animalFood
    if not animalFood then return false end

    local sleeping = model:FindFirstChild('Sleeping')
    if sleeping and sleeping.Value then return false end

    local adult = model:FindFirstChild('IsAdult')
    if animalFood.triggerBreed and not (adult and adult.Value) then return false end

    local food = model:FindFirstChild('FoodLevel')
    local hungry = food ~= nil and food.Value <= ANIMAL_MAX_FOOD * 0.95
    if not hungry and not (animalFood.triggerBreed or animalFood.vitamins) then
        return false
    end

    local foods = animalMeta.animal.foods
    if foods and foods.definite and table.find(foods.definite, held.Name) then
        return true
    end

    local favorites = model:FindFirstChild('Favorites')
    favorites = favorites and favorites:FindFirstChild('Food')
    if favorites then
        for _, entry in ipairs(favorites:GetChildren()) do
            if entry:IsA('StringValue') and entry.Value == held.Name then
                return true
            end
        end
    end
    return false
end

function Animals.runPet()
    for _, model in ipairs(Animals.near()) do
        if not Animals.Pet then break end
        if Animals.canPet(model) then
            if callRequest('CLIENT_PET_ANIMAL', { animal = model }) ~= nil then
                Animals.Petted = Animals.Petted + 1
                Animals.Reason = 'petted ' .. tostring(model.Name)
            end
            task.wait(0.2)
        end
    end
end

function Animals.runMilk()
    for _, model in ipairs(Animals.near()) do
        if not Animals.Milk then break end
        if Animals.canMilk(model) then
            if callRequest('CLIENT_MILK_COW', { animal = model }) ~= nil then
                Animals.Milked = Animals.Milked + 1
                Animals.Reason = 'milked ' .. tostring(model.Name)
            end
            task.wait(0.25)
        end
    end
end

function Animals.runFeed()
    for _, model in ipairs(Animals.near()) do
        if not Animals.Feed then break end
        if Animals.canFeed(model) then
            if callRequest('CLIENT_FEED_ANIMAL', { animal = model }) ~= nil then
                Animals.Fed = Animals.Fed + 1
                Animals.Reason = 'fed ' .. tostring(model.Name)
            end
            task.wait(0.25)
        end
    end
end

function Animals.runHoney()
    local hives = Scan.blocksNear(Animals.Radius, function(block)
        local nectar = block:FindFirstChild('Nectar')
        return nectar ~= nil and nectar.Value >= NECTAR_FOR_HONEY
    end)
    for _, hive in ipairs(hives) do
        if not Animals.Honey then break end
        if callRequest('CLIENT_COLLECT_HONEY', { tree = hive }) ~= nil then
            Animals.Collected = Animals.Collected + 1
            Animals.Reason = 'collected honey'
        end
        task.wait(0.25)
    end
end

task.spawn(function()
    while true do
        task.wait(Animals.Interval)
        if State.Running then
            if Animals.Pet then pcall(Animals.runPet) end
            if Animals.Milk then pcall(Animals.runMilk) end
            if Animals.Feed then pcall(Animals.runFeed) end
            if Animals.Honey then pcall(Animals.runHoney) end
        end
    end
end)

--// combat -------------------------------------------------------------------
-- Same shape as auto break, one layer up. SwordTool.onClick finds its victim
-- through CombatUtils.findTarget, which is a mouse ray; patch that one function
-- and the tool's own cooldown, swing index, animation, crit roll and the
-- request with its signature field all run untouched.
--
--   CombatUtils.findTarget(player, range) -> { entity, hitPos, hitPart }
--   LivingEntityUtils.SWORD_HIT_RANGE     15
--   a living entity is a Model carrying LastDamagedTick, CurrentHealth,
--   MaxHealth, IsPlayer and IsDead
--   attemptHit fires namespace fLafXsVXagmlXhlc, remote UlpaomJfNzwc,
--   with { hitUnit = entity, <signature> }

local Combat = {
    Enabled = false,
    Range = 12,
    Targets = 'mobs',       -- mobs | players | both
    IgnoreDead = true,
    FaceTarget = true,
    Esp = false,
    EspRange = 300,
    EspLive = {},
    Target = nil,
    CurrentHit = nil,
    Hits = 0,
    Reason = 'idle',
}

local SWORD_HIT_RANGE = tonumber(Game.LivingEntity.SWORD_HIT_RANGE) or 15

function Combat.isSelf(entity)
    return entity == getChar()
end

function Combat.isDead(entity)
    local dead = entity:FindFirstChild('IsDead')
    if dead and dead.Value then return true end
    local health = entity:FindFirstChild('CurrentHealth')
    return health ~= nil and health.Value <= 0
end

function Combat.wanted(entity)
    if Combat.isSelf(entity) then return false end
    if Combat.IgnoreDead and Combat.isDead(entity) then return false end
    local isPlayer = entity:FindFirstChild('IsPlayer')
    isPlayer = isPlayer ~= nil and isPlayer.Value == true
    if Combat.Targets == 'mobs' then return not isPlayer end
    if Combat.Targets == 'players' then return isPlayer end
    return true
end

-- Walks the Entities folders and the player list rather than a radius query.
-- At ESP range a spatial query returns every block on the island before it
-- returns a single mob, which is the same trap the block ESP fell into.
function Combat.near(range)
    local root = getRoot()
    if not root then return {} end
    local origin = root.Position
    local seen, out = {}, {}

    local function consider(model)
        if not model or seen[model] then return end
        seen[model] = true
        local ok, entity = pcall(Game.LivingEntity.isLivingEntityModel, model)
        if not (ok and entity) then return end
        if (model:GetPivot().Position - origin).Magnitude > range then return end
        if Combat.wanted(model) then
            out[#out + 1] = model
        end
    end

    for _, folder in ipairs(Animals.entityFolders()) do
        for _, model in ipairs(folder:GetChildren()) do
            consider(model)
        end
    end

    local wilderness = Workspace:FindFirstChild('WildernessIsland')
    wilderness = wilderness and wilderness:FindFirstChild('Entities')
    if wilderness then
        for _, model in ipairs(wilderness:GetChildren()) do
            consider(model)
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            consider(player.Character)
        end
    end

    return out
end

-- The same treatment the block targeting gets: a real ray, so the hit part and
-- position handed back describe something the server could reproduce.
function Combat.hitFor(entity)
    local pivot = entity:GetPivot().Position
    local origin = camPos()
    local delta = pivot - origin
    if delta.Magnitude > SWORD_HIT_RANGE * 3 then return nil end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getChar() }
    local result = Workspace:Raycast(origin, delta.Unit * (delta.Magnitude + 1), params)
    if result then
        local ok, hit = pcall(Game.LivingEntity.getLivingEntityFromChildPart, result.Instance)
        if ok and hit == entity then
            return { entity, result.Position, result.Instance }
        end
    end

    -- No clean line: fall back to the entity's own primary part, which is where
    -- the game's ray would have landed on a body shot anyway.
    local part = entity.PrimaryPart or entity:FindFirstChildWhichIsA('BasePart')
    if not part then return nil end
    return { entity, part.Position, part }
end

function Combat.pick()
    local root = getRoot()
    if not root then return nil end
    local best, bestDistance = nil, math.huge
    for _, entity in ipairs(Combat.near(Combat.Range)) do
        local distance = (entity:GetPivot().Position - root.Position).Magnitude
        if distance < bestDistance then
            best, bestDistance = entity, distance
        end
    end
    return best
end

Hooks.findTarget = Game.CombatUtils.findTarget
Game.CombatUtils.findTarget = function(player, range, ...)
    if Combat.Enabled and player == LocalPlayer and not manualActive() then
        local hit = Combat.CurrentHit
        if hit and hit[1] and hit[1].Parent then
            return hit
        end
    end
    return Hooks.findTarget(player, range, ...)
end

function Combat.step()
    local weapon = State.Weapon
    if not weapon then
        Combat.Reason = 'no weapon equipped'
        return
    end
    local instance = weapon.instance
    if not (instance and instance.Parent == getChar()) then
        Combat.Reason = 'weapon not in hand'
        return
    end
    if manualActive() then
        Combat.Reason = 'standing down — you are swinging by hand'
        return
    end

    local entity = Combat.pick()
    if not entity then
        Combat.Target = nil
        Combat.CurrentHit = nil
        Combat.Reason = 'nothing in range'
        return
    end

    local hit = Combat.hitFor(entity)
    if not hit then
        Combat.Reason = 'no line to target'
        return
    end

    Combat.Target = entity
    Combat.CurrentHit = hit
    Combat.Reason = 'hitting ' .. tostring(entity.Name)

    if Combat.FaceTarget then
        pcall(faceTowards, entity:GetPivot().Position)
    end

    -- onClick re-checks toolMeta.combat.cooldown and its own isHitting flag, so
    -- calling it faster than the weapon allows just gets refused rather than
    -- producing a request.
    local mouse = LocalPlayer:GetMouse()
    local ok = pcall(function()
        weapon:onClick(mouse, mouse.Button1Down, nil)
    end)
    if ok then
        Combat.Hits = Combat.Hits + 1
    end
end

function Combat.clearEsp()
    for entity, adorn in pairs(Combat.EspLive) do
        adorn:Destroy()
        Combat.EspLive[entity] = nil
    end
end

function Combat.refreshEsp()
    if not Combat.Esp then
        if next(Combat.EspLive) ~= nil then Combat.clearEsp() end
        return
    end
    local keep = {}
    for _, entity in ipairs(Combat.near(Combat.EspRange)) do
        keep[entity] = true
        local adorn = Combat.EspLive[entity]
        if not adorn then
            adorn = Instance.new('Highlight')
            adorn.Name = 'centrl_entity_esp'
            adorn.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            adorn.FillTransparency = 0.7
            adorn.OutlineTransparency = 0
            adorn.Adornee = entity
            adorn.Parent = Workspace
            Combat.EspLive[entity] = adorn
        end
        local isPlayer = entity:FindFirstChild('IsPlayer')
        local colour = (isPlayer and isPlayer.Value)
            and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(90, 200, 255)
        adorn.FillColor = colour
        adorn.OutlineColor = colour
    end
    for entity, adorn in pairs(Combat.EspLive) do
        if not keep[entity] or not entity.Parent then
            adorn:Destroy()
            Combat.EspLive[entity] = nil
        end
    end
end

task.spawn(function()
    while true do
        task.wait(0.15)
        if State.Running and Combat.Enabled then
            pcall(Combat.step)
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.7)
        if State.Running then
            pcall(Combat.refreshEsp)
        end
    end
end)

--// deposit race -------------------------------------------------------------
-- This is a test, not a feature. Every item remote in this client hands the
-- server an Instance it owns plus an amount it can read off that same Instance,
-- so there is no number to inflate; the only opening left is two requests
-- landing in the same server frame, both reading the state before either
-- writes. Whether the handler yields in the middle is server code, which no
-- client dump contains, so firing it and counting is the only way to know.
--
-- It is also the loudest thing in this script by a distance: N deposits of one
-- stack, N-1 of which the server should refuse.

local Race = {
    Parallel = 3,
    Item = nil,
    Probe = nil,
    Text = '',
    Text2 = '',
    Amount = -1,
    Busy = false,
    Log = nil,
}

-- Whole-inventory diff. Measuring one item by name misses the interesting
-- case, which is a craft that pays back its ingredients; this way whatever
-- moved shows up without knowing the recipe.
function Race.inventory()
    local totals = {}
    for _, tool in ipairs(Collect.backpackTools()) do
        local amount = tool:FindFirstChild('Amount')
        totals[tool.Name] = (totals[tool.Name] or 0) + (amount and amount.Value or 0)
    end
    return totals
end

function Race.report(before, note)
    local after = Race.inventory()
    local changed = false
    for name, amount in pairs(after) do
        local was = before[name] or 0
        if amount ~= was then
            changed = true
            Race.Log:Add(('%s %+d (%d -> %d)'):format(name, amount - was, was, amount))
        end
    end
    for name, was in pairs(before) do
        if after[name] == nil then
            changed = true
            Race.Log:Add(('%s %+d (%d -> 0)'):format(name, -was, was))
        end
    end
    if not changed then
        Race.Log:Add('nothing in the backpack moved')
    end
    if note then Race.Log:Add(note) end
    Race.Busy = false
end

function Race.begin()
    if Race.Busy then return nil end
    Race.Busy = true
    return Race.inventory()
end

function Race.findTool(label)
    for _, tool in ipairs(Collect.backpackTools()) do
        if Collect.labelOfTool(tool) == label then return tool end
    end
    return nil
end

-- Test 1: the deposit race. Already run and answered - the server serialises
-- them - but kept because it is the control the others are read against.
function Race.runRace()
    local label = Race.Item
    if not label then
        Race.Log:Warn('pick an item first')
        return
    end
    local chest = Collect.nearestChest()
    if not chest then
        Race.Log:Warn('stand next to a chest')
        return
    end
    local target = Race.findTool(label)
    if not target then
        Race.Log:Warn('no ' .. label .. ' in the backpack')
        return
    end

    local before = Race.begin()
    if not before then return end
    Race.Log:Add(('race: %d parallel deposits of %s'):format(Race.Parallel, label))

    local successes = 0
    for _ = 1, Race.Parallel do
        task.spawn(function()
            if Collect.deposit(chest, target) then successes = successes + 1 end
        end)
    end

    task.delay(2.5, function()
        Race.report(before, ('%d of %d reported success'):format(successes, Race.Parallel))
    end)
end

function Race.workbench()
    local benches = Scan.blocksNear(24, function(block)
        local ok, isBench = pcall(function()
            return Game.BlockUtils.isWorkbenchBlock(block)
        end)
        return ok and isBench and true or false
    end)
    return benches[1]
end

function Race.worker()
    local workers = Scan.blocksNear(24, function(block)
        local ok, isWorker = pcall(function()
            return Game.BlockUtils.isWorkerBlock(block)
        end)
        return ok and isWorker and true or false
    end)
    return workers[1]
end

--// probes -------------------------------------------------------------------
-- Craft and worker deposit came back clamped, so the sign check exists on the
-- server even though the shared helper has none. These are the remaining
-- remotes that take a number the server cannot re-derive from an Instance it
-- owns. Rather than shipping one at a time and waiting for a merge, each is a
-- row here: pick it, set the number and the string, fire, read the diff.

local Probes = {}

-- The vending machine's customer transaction is the obvious fourth entry and it
-- is deliberately not here: the dump has the remote defined but no call site
-- for it, so its payload shape would be a guess, and a probe built on a guess
-- tells you nothing when it comes back empty.
Probes.Order = {
    'merchant order',
    'trade quantity',
    'claim reward',
    'worker deposit',
    'craft',
}

-- CLIENT_MERCHANT_ORDER_REQUEST is { merchant, offerId, amount }. Worth trying
-- because it is a different handler from crafting and it moves coins as well as
-- items, and the client's own restock maths does stock - amount, which a
-- negative would raise rather than lower.
Probes['merchant order'] = {
    needs = 'string is the offerId; merchant id goes in the second box',
    run = function(amount, text, second)
        return callRequest('CLIENT_MERCHANT_ORDER_REQUEST', {
            merchant = second ~= '' and second or nil,
            offerId = text,
            amount = amount,
        })
    end,
}

-- The trade namespace's setTradeItemQuantity, { toolName, quantity }. Same
-- shape as the two that failed, but a different subsystem, and trade offers are
-- held server-side between two players rather than written straight to an
-- inventory.
Probes['trade quantity'] = {
    needs = 'be in an open trade; string is the internal tool name',
    run = function(amount, text)
        if not Services.Remotes then return nil end
        local ok, result = pcall(function()
            return Services.Remotes.Client
                :GetNamespace('sfsiuWqmBlalIf')
                :Get('gSqxaHqzsgcLolubtmwuuzZoprcsuj')
                :CallServerAsync({ toolName = text, quantity = amount })
                :expect()
        end)
        return ok and result or nil
    end,
}

-- ClaimReward takes a bare reward key string, with HasClaimedReward as its
-- companion. Not a dupe of arbitrary items, but if the claimed flag is written
-- after the grant rather than before, firing the same key twice is free goods.
Probes['claim reward'] = {
    needs = 'string is the reward key; amount is how many times to fire it',
    run = function(amount, text)
        if not Services.Remotes then return nil end
        local fired = math.max(1, math.abs(amount))
        local last = nil
        for _ = 1, fired do
            pcall(function()
                last = Services.Remotes.Client:Get('ClaimReward'):CallServerAsync(text):expect()
            end)
        end
        return last
    end,
}

Probes['worker deposit'] = {
    needs = 'stand at a furnace or forge; string is the internal tool name',
    run = function(amount, text)
        local worker = Race.worker()
        if not worker then return nil end
        return callRequest('CLIENT_BLOCK_WORKER_DEPOSIT_TOOL_REQUEST', {
            block = worker,
            toolName = text,
            amount = amount,
            [WORKER_SIGNATURE_KEY] = WORKER_SIGNATURE,
        })
    end,
}

Probes['craft'] = {
    needs = 'stand at a workbench; string is the internal tool name',
    run = function(amount, text)
        local bench = Race.workbench()
        if not (bench and Services.Remotes) then return nil end
        local ok, result = pcall(function()
            return Services.Remotes.Client:Get('CraftTool'):CallServer({
                workbenchBlock = bench,
                toolName = text,
                amount = amount,
                upgrade = nil,
            })
        end)
        return ok and result or nil
    end,
}

function Race.runProbe()
    local name = Race.Probe
    local probe = name and Probes[name]
    if not probe then
        Race.Log:Warn('pick a probe first')
        return
    end

    local before = Race.begin()
    if not before then return end
    Race.Log:Add(('%s | amount %d | "%s"'):format(name, Race.Amount, tostring(Race.Text)))

    task.spawn(function()
        local result = probe.run(Race.Amount, Race.Text or '', Race.Text2 or '')
        task.wait(1.5)
        local verdict
        if result == nil then
            verdict = 'no reply — the call failed or a precondition was missing (' .. probe.needs .. ')'
        elseif type(result) == 'table' then
            verdict = 'replied success=' .. tostring(result.success)
        else
            verdict = 'replied ' .. tostring(result)
        end
        Race.report(before, verdict)
    end)
end

--// tabs ---------------------------------------------------------------------

local BreakTab = Window:Tab({ Title = 'break', Icon = 'pickaxe' })
local MainSec = BreakTab:Section({ Title = 'auto break', Side = 'left' })
local ReachSec = BreakTab:Section({ Title = 'reach & pacing', Side = 'right' })

local ToolStat = MainSec:Stat({ Title = 'tool', Value = '-' })
local TargetStat = MainSec:Stat({ Title = 'target', Value = '-' })
local BrokenStat = MainSec:Stat({ Title = 'broken', Value = '0' })

MainSec:Toggle({
    Title = 'enabled',
    Desc = 'drives the game\'s own swing loop, never the remote directly',
    Flag = 'ib_enabled',
    Default = false,
    Callback = function(state)
        Config.Enabled = state
        if state then
            State.Broken = 0
            State.Swings = 0
            State.Rejects = 0
            State.PausedUntil = 0
            State.LastSwingAt = tick()
            State.Watch = nil
            table.clear(State.Blacklist)
            table.clear(State.Pending)
            if not toolIsEquipped() then
                if reEquipHeldTool() then
                    notify('auto break', 're-equipped to pick up the held tool', 'info', 4)
                else
                    notify('auto break', 'equip an axe, pickaxe or shovel', 'warning', 6)
                end
            end
        else
            stopSwinging()
        end
    end,
})

MainSec:Button({
    Title = 're-hook equipped tool',
    Desc = 'unequip and re-equip so the tool object is captured',
    Callback = function()
        if reEquipHeldTool() then
            notify('auto break', 'tool re-equipped', 'success', 3)
        else
            notify('auto break', 'nothing in hand', 'warning', 3)
        end
    end,
})

MainSec:Slider({
    Title = 'stop after',
    Desc = '0 leaves it running',
    Flag = 'ib_stopafter',
    Min = 0, Max = 2000, Increment = 10, Default = 0,
    Suffix = ' blocks',
    Callback = function(v) Config.StopAfter = v end,
})

MainSec:Slider({
    Title = 'pause after refusals',
    Desc = 'blocks the server would not let you break, in a row',
    Flag = 'ib_rejectlimit',
    Min = 1, Max = 10, Increment = 1, Default = 3,
    Callback = function(v) Config.RejectLimit = v end,
})

MainSec:Slider({
    Title = 'pause length',
    Desc = 'it backs off and carries on by itself — no re-toggling',
    Flag = 'ib_pause',
    Min = 5, Max = 120, Increment = 5, Default = 20,
    Suffix = 's',
    Callback = function(v) Config.PauseSeconds = v end,
})

ReachSec:Paragraph({
    Title = 'why the reach slider has a ceiling',
    Content = 'It stops at ToolUtils.MAX_DISTANCE, read out of the game — how far its own '
        .. 'mouse ray reaches before it gives up. A break request for a block further away '
        .. 'than that is one no unmodified client could have sent. The default sits below it '
        .. 'so normal movement never pushes a swing out past the real limit.',
})

-- Read off the game rather than typed in, so if a content update moves the
-- client's own reach the cap moves with it.
local MaxReach = tonumber(Game.ToolUtils.MAX_DISTANCE) or 24

ReachSec:Slider({
    Title = 'reach',
    Flag = 'ib_radius',
    Min = 4, Max = MaxReach, Increment = 1,
    Default = math.min(16, MaxReach),
    Suffix = 'st',
    Callback = function(v) Config.Radius = math.min(v, MaxReach) end,
})

ReachSec:Slider({
    Title = 'extra delay',
    Desc = 'added to the tool\'s own hit delay — this never speeds it up',
    Flag = 'ib_extradelay',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.05,
    Suffix = 's',
    Callback = function(v) Config.ExtraDelay = v end,
})

ReachSec:Toggle({
    Title = 'yield to my clicks',
    Desc = 'hold the mouse and you mine what you point at, not what it picked',
    Flag = 'ib_manual',
    Default = true,
    Callback = function(state) Config.YieldToManualInput = state end,
})

ReachSec:Slider({
    Title = 'yield grace',
    Desc = 'how long after letting go before it takes over again',
    Flag = 'ib_manualgrace',
    Min = 0, Max = 3, Increment = 0.1, Default = 0.4,
    Suffix = 's',
    Callback = function(v) Config.ManualGrace = v end,
})

ReachSec:Toggle({
    Title = 'require line of sight',
    Desc = 'only hit blocks a real camera ray can actually reach',
    Flag = 'ib_los',
    Default = true,
    Callback = function(state) Config.RequireLineOfSight = state end,
})

ReachSec:Toggle({
    Title = 'face the block',
    Flag = 'ib_face',
    Default = true,
    Callback = function(state) Config.FaceTarget = state end,
})

ReachSec:Toggle({
    Title = 'jitter the aim point',
    Desc = 'lands somewhere different on the face each swing',
    Flag = 'ib_jitter',
    Default = true,
    Callback = function(state) Config.JitterAim = state end,
})

ReachSec:Toggle({
    Title = 'nearest first',
    Flag = 'ib_closest',
    Default = true,
    Callback = function(state) Config.PreferClosest = state end,
})

ReachSec:Toggle({
    Title = 'highlight the target',
    Flag = 'ib_highlight',
    Default = true,
    Callback = function(state)
        Config.HighlightTarget = state
        if not state then clearHighlight() end
    end,
})

--// filters ------------------------------------------------------------------

local FilterTab = Window:Tab({ Title = 'what to break', Icon = 'filter' })
local CatSec = FilterTab:Section({ Title = 'categories', Side = 'left' })
local BlockSec = FilterTab:Section({ Title = 'specific blocks', Side = 'right' })

CatSec:Paragraph({
    Title = 'how the filters combine',
    Content = 'A block is broken when it passes the category list AND the specific-block '
        .. 'list AND is not on the ignore list. An empty list means that list is not '
        .. 'filtering. With both lists empty nothing is broken, on purpose.',
})

CatSec:Dropdown({
    Title = 'categories',
    Desc = 'read out of BlockMeta, so new content sorts itself',
    Multi = true,
    Values = Classify.Order,
    Default = { 'ores & rocks' },
    Flag = 'ib_categories',
    Callback = function(_, selection)
        Config.Categories = {}
        for name, on in pairs(selection or {}) do
            if on then Config.Categories[name] = true end
        end
    end,
})

CatSec:Paragraph({
    Title = 'what lands where',
    Content = 'ores & rocks — any block with miningExperience (rockIron, rockCoal, '
        .. 'rockDiamond and the rest)\ntrees — any block with a tree entry\n'
        .. 'crops — any block with cropHarvestConfig; breaking these destroys them '
        .. 'rather than harvesting, so leave it off unless you mean it\n'
        .. 'flowers — tagged flower\neverything else — every other breakable block',
})

local BlockDropdown = BlockSec:Dropdown({
    Title = 'blocks',
    Desc = 'leave empty to let the categories decide',
    Multi = true,
    Values = {},
    Flag = 'ib_blocks',
    Callback = function(_, selection)
        Config.Blocks = {}
        for name, on in pairs(selection or {}) do
            if on then Config.Blocks[name] = true end
        end
    end,
})

local IgnoreDropdown = BlockSec:Dropdown({
    Title = 'never break',
    Multi = true,
    Values = {},
    Flag = 'ib_ignore',
    Callback = function(_, selection)
        Config.Ignore = {}
        for name, on in pairs(selection or {}) do
            if on then Config.Ignore[name] = true end
        end
    end,
})

BlockSec:Button({
    Title = 'list blocks around me',
    Desc = 'scans 120 studs and fills both lists with what is actually there',
    Callback = function()
        local labels = Picker.scan()
        BlockDropdown:SetOptions(labels)
        IgnoreDropdown:SetOptions(labels)
        notify('blocks', tostring(#labels) .. ' kinds nearby', 'success', 4)
    end,
})

BlockSec:Button({
    Title = 'list every block in the game',
    Desc = 'the whole of BlockMeta — long, but complete',
    Callback = function()
        local labels = Picker.all()
        BlockDropdown:SetOptions(labels)
        IgnoreDropdown:SetOptions(labels)
        notify('blocks', tostring(#labels) .. ' kinds total', 'success', 4)
    end,
})

--// farm tab -----------------------------------------------------------------

local FarmTab = Window:Tab({ Title = 'farm', Icon = 'sprout' })
local HarvestSec = FarmTab:Section({ Title = 'harvest & plant', Side = 'left' })
local FarmPaceSec = FarmTab:Section({ Title = 'pacing', Side = 'right' })

local FarmStats = {
    harvested = HarvestSec:Stat({ Title = 'harvested', Value = '0' }),
    planted = HarvestSec:Stat({ Title = 'planted', Value = '0' }),
    doing = HarvestSec:Stat({ Title = 'doing', Value = 'idle' }),
}

HarvestSec:Toggle({
    Title = 'auto harvest',
    Desc = 'only crops whose live stage model says Harvestable',
    Flag = 'if_harvest',
    Default = false,
    Callback = function(state)
        Farm.Harvest = state
        if state and not Services.Crop then
            notify('farm', 'crop service not found — harvest will do nothing', 'warning', 6)
        end
    end,
})

HarvestSec:Toggle({
    Title = 'auto plant',
    Desc = 'plants whatever seed you hold, on the blocks that seed allows',
    Flag = 'if_plant',
    Default = false,
    Callback = function(state)
        Farm.Plant = state
        if state and not Farm.equippedSeed() then
            notify('farm', 'hold a seed — that is what decides the crop', 'warning', 6)
        end
    end,
})

HarvestSec:Toggle({
    Title = 'auto till',
    Desc = 'hoes anything with a hoeTillsTo entry and nothing sitting on it',
    Flag = 'if_till',
    Default = false,
    Callback = function(state) Farm.Till = state end,
})

HarvestSec:Button({
    Title = 'reset farm counters',
    Callback = function()
        Farm.Harvested, Farm.Planted, Farm.Tilled = 0, 0, 0
    end,
})

FarmPaceSec:Paragraph({
    Title = 'how planting knows what to plant',
    Content = 'ToolMeta for the seed in your hand carries cropSeed.cropName and '
        .. 'cropSeed.placedOnBlocks. The first is what gets placed, the second is where it '
        .. 'is allowed to go — normally soil. The request is the one the seed spreader tool '
        .. 'sends, lifted one block above the soil, signature field included.',
})

FarmPaceSec:Slider({
    Title = 'radius',
    Flag = 'if_radius',
    Min = 6, Max = 60, Increment = 2, Default = 24,
    Suffix = 'st',
    Callback = function(v) Farm.Radius = v end,
})

FarmPaceSec:Slider({
    Title = 'pass interval',
    Flag = 'if_interval',
    Min = 0.2, Max = 3, Increment = 0.1, Default = 0.4,
    Suffix = 's',
    Callback = function(v) Farm.Interval = v end,
})

FarmPaceSec:Slider({
    Title = 'actions per pass',
    Desc = 'the cap on how many crops one pass will touch',
    Flag = 'if_perpass',
    Min = 1, Max = 20, Increment = 1, Default = 6,
    Callback = function(v) Farm.PerPass = v end,
})

--// collect tab --------------------------------------------------------------

local CollectTab = Window:Tab({ Title = 'collect', Icon = 'package' })
local DropSec = CollectTab:Section({ Title = 'drops', Side = 'left' })
local ChestSec = CollectTab:Section({ Title = 'chest deposit', Side = 'right' })

local CollectStats = {
    picked = DropSec:Stat({ Title = 'picked up', Value = '0' }),
    deposited = DropSec:Stat({ Title = 'deposited', Value = '0' }),
    doing = DropSec:Stat({ Title = 'doing', Value = 'idle' }),
}

DropSec:Toggle({
    Title = 'auto pick up drops',
    Desc = 'goes through the game\'s own pickupTool, permission checks and all',
    Flag = 'ic_drops',
    Default = false,
    Callback = function(state)
        Collect.Drops = state
        if state and not Services.Inventory then
            notify('collect', 'inventory service not found — pickup will do nothing', 'warning', 6)
        end
    end,
})

DropSec:Slider({
    Title = 'drop radius',
    Flag = 'ic_dropradius',
    Min = 8, Max = 80, Increment = 2, Default = 30,
    Suffix = 'st',
    Callback = function(v) Collect.DropRadius = v end,
})

DropSec:Slider({
    Title = 'pass interval',
    Flag = 'ic_interval',
    Min = 0.2, Max = 3, Increment = 0.1, Default = 0.5,
    Suffix = 's',
    Callback = function(v) Collect.Interval = v end,
})

ChestSec:Toggle({
    Title = 'auto deposit',
    Desc = 'into the nearest chest, for the items picked below',
    Flag = 'ic_deposit',
    Default = false,
    Callback = function(state) Collect.Deposit = state end,
})

ChestSec:Toggle({
    Title = 'never deposit what I am holding',
    Flag = 'ic_keepheld',
    Default = true,
    Callback = function(state) Collect.KeepHeld = state end,
})

ChestSec:Slider({
    Title = 'chest radius',
    Flag = 'ic_chestradius',
    Min = 6, Max = 40, Increment = 2, Default = 20,
    Suffix = 'st',
    Callback = function(v) Collect.ChestRadius = v end,
})

local DepositDropdown = ChestSec:Dropdown({
    Title = 'items to deposit',
    Desc = 'nothing selected means nothing gets deposited',
    Multi = true,
    Values = {},
    Flag = 'ic_items',
    Callback = function(_, selection)
        Collect.Items = {}
        for name, on in pairs(selection or {}) do
            if on then Collect.Items[name] = true end
        end
    end,
})

ChestSec:Button({
    Title = 'read my backpack',
    Desc = 'fills the list above with what you are carrying now',
    Callback = function()
        local labels, seen = {}, {}
        for _, tool in ipairs(Collect.backpackTools()) do
            local label = Collect.labelOfTool(tool)
            if not seen[label] then
                seen[label] = true
                labels[#labels + 1] = label
            end
        end
        table.sort(labels)
        DepositDropdown:SetOptions(labels)
        notify('collect', tostring(#labels) .. ' kinds carried', 'success', 4)
    end,
})

--// esp tab ------------------------------------------------------------------

local EspTab = Window:Tab({ Title = 'esp', Icon = 'eye' })
local EspSec = EspTab:Section({ Title = 'block esp', Side = 'left' })
local EspLookSec = EspTab:Section({ Title = 'appearance', Side = 'right' })

EspSec:Toggle({
    Title = 'enabled',
    Flag = 'ie_enabled',
    Default = false,
    Callback = function(state)
        Esp.Enabled = state
        if not state then Esp.clear() end
    end,
})

EspSec:Dropdown({
    Title = 'categories',
    Desc = 'its own filter, so you can light up diamonds while breaking stone',
    Multi = true,
    Values = Classify.Order,
    Default = { 'ores & rocks' },
    Flag = 'ie_categories',
    Callback = function(_, selection)
        Esp.Categories = {}
        for name, on in pairs(selection or {}) do
            if on then Esp.Categories[name] = true end
        end
    end,
})

local EspBlockDropdown = EspSec:Dropdown({
    Title = 'blocks',
    Desc = 'picking any block here overrides the categories',
    Multi = true,
    Values = {},
    Flag = 'ie_blocks',
    Callback = function(_, selection)
        Esp.Blocks = {}
        for name, on in pairs(selection or {}) do
            if on then Esp.Blocks[name] = true end
        end
    end,
})

EspSec:Button({
    Title = 'fill from every block in the game',
    Callback = function()
        local labels = Picker.all()
        EspBlockDropdown:SetOptions(labels)
        notify('esp', tostring(#labels) .. ' kinds listed', 'success', 4)
    end,
})

EspLookSec:Slider({
    Title = 'radius',
    Flag = 'ie_radius',
    Min = 50, Max = 600, Increment = 25, Default = 250,
    Suffix = 'st',
    Callback = function(v) Esp.Radius = v end,
})

EspLookSec:Slider({
    Title = 'max boxes',
    Desc = 'nearest first, so the cap trims the far ones',
    Flag = 'ie_max',
    Min = 25, Max = 800, Increment = 25, Default = 250,
    Callback = function(v) Esp.MaxBoxes = v end,
})

EspLookSec:Slider({
    Title = 'refresh interval',
    Flag = 'ie_interval',
    Min = 0.3, Max = 3, Increment = 0.1, Default = 0.8,
    Suffix = 's',
    Callback = function(v) Esp.Interval = v end,
})

EspLookSec:Paragraph({
    Title = 'why it was drawing nothing',
    Content = 'Two reasons, both fixed. It used Highlight, and Roblox renders only about '
        .. 'thirty of those per client at once, so most were silently blank — these are '
        .. 'BoxHandleAdornments now, which have no ceiling. And it found blocks with a '
        .. 'radius query, which at ESP range has to be capped and then returns an arbitrary '
        .. 'subset — the ground under you, never the vein. It walks the island Blocks '
        .. 'folders directly now.',
})

EspLookSec:Colorpicker({
    Title = 'colour',
    Flag = 'ie_colour',
    Default = Color3.fromRGB(255, 200, 60),
    Callback = function(c) Esp.Colour = c end,
})

EspLookSec:Slider({
    Title = 'fill transparency',
    Flag = 'ie_fill',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.75,
    Callback = function(v) Esp.Transparency = v end,
})

--// pets tab -----------------------------------------------------------------

local PetTab = Window:Tab({ Title = 'pets', Icon = 'heart' })
local PetSec = PetTab:Section({ Title = 'animal care', Side = 'left' })
local PetPaceSec = PetTab:Section({ Title = 'pacing & notes', Side = 'right' })

local PetStats = {
    petted = PetSec:Stat({ Title = 'petted', Value = '0' }),
    milked = PetSec:Stat({ Title = 'milked', Value = '0' }),
    doing = PetSec:Stat({ Title = 'doing', Value = 'idle' }),
}

PetSec:Toggle({
    Title = 'auto pet',
    Desc = 'each animal once its own 5 minute cooldown is up',
    Flag = 'ip_pet',
    Default = false,
    Callback = function(state) Animals.Pet = state end,
})

PetSec:Toggle({
    Title = 'auto milk',
    Desc = 'needs an empty bucket in hand and a product ready',
    Flag = 'ip_milk',
    Default = false,
    Callback = function(state)
        Animals.Milk = state
        if state and not Animals.heldToolName() then
            notify('pets', 'hold an empty bucket', 'warning', 5)
        end
    end,
})

PetSec:Toggle({
    Title = 'auto feed',
    Desc = 'feeds whatever food you are holding to anything still hungry',
    Flag = 'ip_feed',
    Default = false,
    Callback = function(state) Animals.Feed = state end,
})

PetSec:Toggle({
    Title = 'auto collect honey',
    Desc = 'hives at 250 nectar or more, the same bar the menu uses',
    Flag = 'ip_honey',
    Default = false,
    Callback = function(state) Animals.Honey = state end,
})

PetSec:Button({
    Title = 'reset pet counters',
    Callback = function()
        Animals.Petted, Animals.Milked, Animals.Fed, Animals.Collected = 0, 0, 0, 0
    end,
})

PetPaceSec:Paragraph({
    Title = 'every gate here is the game\'s own',
    Content = 'Petting waits out AnimalConst.TIME_BETWEEN_PET_SEC, which is 300, read off '
        .. 'each animal\'s LastPet. Milk needs a tool whose ToolMeta has emptyBucket and an '
        .. 'AnimalProductReady above zero, which is exactly when CowInteractHandler offers '
        .. 'the option. Honey wants Nectar at 250. Asking outside those windows is a refused '
        .. 'request, and refused requests are the thing worth not generating.',
})

PetPaceSec:Slider({
    Title = 'radius',
    Flag = 'ip_radius',
    Min = 15, Max = 150, Increment = 5, Default = 60,
    Suffix = 'st',
    Callback = function(v) Animals.Radius = v end,
})

PetPaceSec:Slider({
    Title = 'pass interval',
    Flag = 'ip_interval',
    Min = 0.5, Max = 5, Increment = 0.5, Default = 1,
    Suffix = 's',
    Callback = function(v) Animals.Interval = v end,
})

--// combat tab ---------------------------------------------------------------

local CombatTab = Window:Tab({ Title = 'combat', Icon = 'swords' })
local CombatSec = CombatTab:Section({ Title = 'auto attack', Side = 'left' })
local CombatNoteSec = CombatTab:Section({ Title = 'targeting & notes', Side = 'right' })

local CombatStats = {
    weapon = CombatSec:Stat({ Title = 'weapon', Value = '-' }),
    target = CombatSec:Stat({ Title = 'target', Value = '-' }),
    doing = CombatSec:Stat({ Title = 'doing', Value = 'idle' }),
}

CombatSec:Toggle({
    Title = 'enabled',
    Desc = 'drives SwordTool.onClick, so the weapon\'s own cooldown still rules',
    Flag = 'iw_enabled',
    Default = false,
    Callback = function(state)
        Combat.Enabled = state
        if not state then
            Combat.Target = nil
            Combat.CurrentHit = nil
        elseif not State.Weapon then
            notify('combat', 'equip a weapon, then re-equip if it does not pick up', 'warning', 6)
        end
    end,
})

CombatSec:Dropdown({
    Title = 'target',
    Values = { 'mobs', 'players', 'both' },
    Default = 'mobs',
    Flag = 'iw_targets',
    Callback = function(value) Combat.Targets = value end,
})

CombatSec:Toggle({
    Title = 'skip the dead',
    Flag = 'iw_ignoredead',
    Default = true,
    Callback = function(state) Combat.IgnoreDead = state end,
})

CombatSec:Toggle({
    Title = 'face the target',
    Flag = 'iw_face',
    Default = true,
    Callback = function(state) Combat.FaceTarget = state end,
})

CombatSec:Toggle({
    Title = 'entity esp',
    Desc = 'blue for mobs, red for players',
    Flag = 'iw_esp',
    Default = false,
    Callback = function(state)
        Combat.Esp = state
        if not state then Combat.clearEsp() end
    end,
})

CombatSec:Button({
    Title = 'reset hit counter',
    Callback = function() Combat.Hits = 0 end,
})

CombatNoteSec:Paragraph({
    Title = 'the range ceiling is the game\'s',
    Content = 'LivingEntityUtils.SWORD_HIT_RANGE is 15, which is how far the weapon\'s own '
        .. 'target ray reaches. The slider stops there for the same reason the mining one '
        .. 'stops at 24: past it you are asking for a hit no unmodified client could have '
        .. 'produced.',
})

CombatNoteSec:Slider({
    Title = 'range',
    Flag = 'iw_range',
    Min = 4, Max = SWORD_HIT_RANGE, Increment = 1,
    Default = math.min(12, SWORD_HIT_RANGE),
    Suffix = 'st',
    Callback = function(v) Combat.Range = math.min(v, SWORD_HIT_RANGE) end,
})

CombatNoteSec:Paragraph({
    Title = 'about hitting players',
    Content = 'CombatUtils.isPvPAllowed only returns true on the PvP island, and past its '
        .. 'divider at that. Off it the server refuses every swing at a player, and a run of '
        .. 'refused combat requests is the same bad pattern as refused break requests — so '
        .. 'mobs is the default, and players is only worth turning on where PvP is live.',
})

CombatNoteSec:Slider({
    Title = 'esp range',
    Desc = 'the esp only, not the attack',
    Flag = 'iw_esprange',
    Min = 50, Max = 800, Increment = 25, Default = 300,
    Suffix = 'st',
    Callback = function(v) Combat.EspRange = v end,
})

CombatNoteSec:Paragraph({
    Title = 'it yields to your clicks too',
    Content = 'The same manual-input check the miner uses. While you are actually swinging '
        .. 'at something, findTarget goes back to reading your mouse.',
})

--// lab tab ------------------------------------------------------------------

local LabTab = Window:Tab({ Title = 'lab', Icon = 'flask-conical' })
local LabSec = LabTab:Section({ Title = 'tests', Side = 'left' })
local LabNoteSec = LabTab:Section({ Title = 'what is being tested', Side = 'right' })

LabNoteSec:Paragraph({
    Title = 'what has been ruled out',
    Content = 'The concurrent deposit race: the server serialises them. Negative amounts '
        .. 'through CraftTool and through the block worker deposit: clamped. So the server '
        .. 'does check the sign, even though the shared helper it calls does not — '
        .. 'decrementToolTypeAmount validates NaN and integrality and nothing else, and '
        .. 'decrementToolAmount would happily write Amount + 5 for a delta of -5. The guard '
        .. 'is somewhere above it, in the handlers those two remotes reach.',
})

LabNoteSec:Paragraph({
    Title = 'what is left, and why these',
    Content = 'Every remaining remote that hands the server a number it cannot re-derive '
        .. 'from an Instance it owns. The merchant order is the best of them: a different '
        .. 'handler from crafting, it moves coins as well as items, and the client\'s own '
        .. 'restock maths does stock minus amount, which a negative raises. Trade quantity '
        .. 'is the same shape in a subsystem that holds offers between two players rather '
        .. 'than writing an inventory. Claim reward is a different shape entirely — a bare '
        .. 'key string with a separate has-claimed check, so if the flag is written after '
        .. 'the grant, firing twice is free goods.',
})

LabNoteSec:Paragraph({
    Title = 'how to sweep',
    Content = 'Pick a probe, set the amount and the string it needs, fire, read the diff. '
        .. 'Every probe reports the whole backpack before and after, so an item going up is '
        .. 'the answer and nothing moving is a clamp. Try -1 first, then -1000: some guards '
        .. 'catch small negatives and overflow on large ones. Then try a huge positive, '
        .. 'which is the other half of an unchecked bound.',
})

LabNoteSec:Paragraph({
    Title = 'this stays the loudest tab',
    Content = 'Every one of these produces requests the server should refuse, which is the '
        .. 'exact pattern the rest of the script is built to avoid. Fire deliberately, read '
        .. 'the answer, stop.',
})

local LabProbeDropdown = LabSec:Dropdown({
    Title = 'probe',
    Values = Probes.Order,
    Default = 'merchant order',
    Flag = 'ir_probe',
    Callback = function(value)
        Race.Probe = value
        local probe = Probes[value]
        if probe then Race.Log:Add('needs: ' .. probe.needs) end
    end,
})

LabSec:Slider({
    Title = 'amount',
    Desc = 'negative first, then very negative, then very large',
    Flag = 'ir_amount',
    Min = -10000, Max = 10000, Increment = 1, Default = -1,
    Callback = function(v) Race.Amount = v end,
})

LabSec:Textbox({
    Title = 'string',
    Desc = 'internal tool name, offer id or reward key, depending on the probe',
    Flag = 'ir_text',
    Default = '',
    Callback = function(text) Race.Text = text end,
})

LabSec:Textbox({
    Title = 'second string',
    Desc = 'only the merchant order uses this — the merchant id',
    Flag = 'ir_text2',
    Default = '',
    Callback = function(text) Race.Text2 = text end,
})

Race.Log = LabSec:Console({ Title = 'result', Height = 150, MaxLines = 60, Timestamps = true })
Race.Log:Add('pick a probe; its preconditions print here')

LabSec:Button({
    Title = 'fire probe',
    Desc = 'one shot; the backpack diff prints above',
    Callback = function() task.spawn(Race.runProbe) end,
})

local LabItemDropdown = LabSec:Dropdown({
    Title = 'item (for the race control)',
    Values = {},
    Flag = 'ir_item',
    Callback = function(value) Race.Item = value end,
})

LabSec:Button({
    Title = 'read my backpack',
    Callback = function()
        local labels, seen = {}, {}
        for _, tool in ipairs(Collect.backpackTools()) do
            local label = Collect.labelOfTool(tool)
            if not seen[label] then
                seen[label] = true
                labels[#labels + 1] = label
            end
        end
        table.sort(labels)
        LabItemDropdown:SetOptions(labels)
    end,
})

LabSec:Slider({
    Title = 'parallel requests',
    Flag = 'ir_parallel',
    Min = 2, Max = 8, Increment = 1, Default = 3,
    Callback = function(v) Race.Parallel = v end,
})

LabSec:Button({
    Title = 'deposit race (the control, already answered)',
    Desc = 'stand at a chest',
    Callback = function() task.spawn(Race.runRace) end,
})

--// status -------------------------------------------------------------------

local StatusTab = Window:Tab({ Title = 'status', Icon = 'activity' })
local LiveSec = StatusTab:Section({ Title = 'live', Side = 'left' })
local NotesSec = StatusTab:Section({ Title = 'notes', Side = 'right' })

local ReasonStat = LiveSec:Stat({ Title = 'doing', Value = 'idle' })
local SwingStat = LiveSec:Stat({ Title = 'swings', Value = '0' })
local RejectStat = LiveSec:Stat({ Title = 'refusals', Value = '0' })

LiveSec:Button({
    Title = 'unload',
    Desc = 'restores the three patched methods and stops everything',
    Callback = function()
        Config.Enabled = false
        State.Running = false
        Farm.Harvest, Farm.Plant, Farm.Till = false, false, false
        Collect.Drops, Collect.Deposit = false, false
        Animals.Pet, Animals.Milk, Animals.Feed, Animals.Honey = false, false, false, false
        Combat.Enabled, Combat.Esp = false, false
        Combat.clearEsp()
        Esp.Enabled = false
        Esp.clear()
        stopSwinging()
        clearHighlight()
        Game.ToolScript.onClickSetup = Hooks.onClickSetup
        Game.AxeTool.onBlockHit = Hooks.onBlockHit
        Game.AxeTool.getTargettedBlock = Hooks.getTargettedBlock
        Game.CombatUtils.findTarget = Hooks.findTarget
        for _, conn in ipairs(Connections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(Connections)
        notify('islands', 'unloaded — the game is back to stock', 'success', 4)
        task.delay(0.5, function()
            pcall(function() Centrl:Destroy() end)
        end)
    end,
})

LiveSec:Button({
    Title = 'reset counters',
    Callback = function()
        State.Broken = 0
        State.Swings = 0
        State.Rejects = 0
        State.Watch = nil
        table.clear(State.Blacklist)
        table.clear(State.Pending)
    end,
})

NotesSec:Paragraph({
    Title = 'what this actually does',
    Content = 'It replaces one method — AxeTool.getTargettedBlock — with one that returns a '
        .. 'block our loop chose instead of the one under the mouse, then starts the game\'s '
        .. 'real startBlockHit loop. The pos and norm handed back come from an actual raycast '
        .. 'from the camera, not from arithmetic, so the hit describes something the server '
        .. 'could reproduce. The request, its timing, and the signature field in its payload '
        .. 'are all the game\'s.',
})

NotesSec:Paragraph({
    Title = 'refusal detection',
    Content = 'A block\'s Health value is replicated from the server. A swing the server '
        .. 'accepted moves it; one it refused does not. Three swings with no movement '
        .. 'benches that block for 30 seconds and counts a refusal, and a run of refusals '
        .. 'switches auto break off — a client that keeps asking for something it has already '
        .. 'been told no about is the loudest thing it can do.',
})

task.spawn(function()
    while true do
        task.wait(0.35)
        pcall(function()
            ToolStat:Set(toolIsEquipped() and State.ToolName or '-')
            TargetStat:Set(State.Target and State.Target.Name or '-')
            BrokenStat:Set(tostring(State.Broken))
            ReasonStat:Set(State.LastReason)
            SwingStat:Set(tostring(State.Swings))
            RejectStat:Set(tostring(State.Rejects))

            FarmStats.harvested:Set(tostring(Farm.Harvested))
            FarmStats.planted:Set(tostring(Farm.Planted))
            FarmStats.doing:Set(Farm.Reason)

            CollectStats.picked:Set(tostring(Collect.Picked))
            CollectStats.deposited:Set(tostring(Collect.Deposited))
            CollectStats.doing:Set(Collect.Reason)

            PetStats.petted:Set(tostring(Animals.Petted))
            PetStats.milked:Set(tostring(Animals.Milked))
            PetStats.doing:Set(Animals.Reason)

            CombatStats.weapon:Set(State.Weapon and State.WeaponName or '-')
            CombatStats.target:Set(Combat.Target and Combat.Target.Name or '-')
            CombatStats.doing:Set(Combat.Reason)
        end)
    end
end)

track(LocalPlayer.CharacterAdded:Connect(function()
    State.Tool = nil
    State.Hit = nil
    State.Target = nil
    State.Watch = nil
    clearHighlight()
end))

Window:Load()
notify('islands', 'equip a pickaxe or axe, pick what to break, then flip it on', 'info', 6)

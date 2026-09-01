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

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib3.lua'))()

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

    RequireLineOfSight = true,
    FaceTarget = true,
    HighlightTarget = true,
    PreferClosest = true,

    -- Aim somewhere random on the chosen face instead of dead centre every
    -- swing, because a real mouse never lands on the same pixel twice.
    JitterAim = true,

    StopAfter = 0,          -- 0 = no limit
    RejectLimit = 3,        -- consecutive blocks the server refused before stopping

    Categories = { ['ores & rocks'] = true },
    Blocks = {},            -- specific display names; empty means "no extra filter"
    Ignore = {},
}

local State = {
    Tool = nil,
    ToolName = '-',
    Target = nil,
    Hit = nil,
    NextAllowed = 0,
    Swings = 0,
    Broken = 0,
    Rejects = 0,
    Blacklist = {},         -- block -> expiry tick
    Watch = nil,            -- { block, health, swings }
    Pending = {},           -- blocks the client removed, awaiting the server's answer
    NextRestart = 0,
    NextPick = 0,
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
    if type(self) == 'table' and rawget(self, 'instance') and self.startBlockHit then
        State.Tool = self
        State.ToolName = tostring(self.instance and self.instance.Name or '?')
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
-- The break request is fired inside a deferred closure we cannot hook, but the
-- server's answer is observable: a real hit moves the block's replicated Health
-- value, and a refused one does not. Three swings with no movement means the
-- server is saying no, which is the point at which continuing is the mistake.

local function noteSwing(block)
    State.Swings = State.Swings + 1
    State.NextAllowed = tick() + Config.ExtraDelay

    local health = block:FindFirstChild('Health')
    local value = health and health.Value or nil
    local watch = State.Watch

    if watch and watch.block == block then
        watch.swings = watch.swings + 1
        if value ~= nil and watch.health ~= nil and value < watch.health then
            watch.health = value
            watch.swings = 0
            State.Rejects = 0
        elseif watch.swings >= 3 then
            State.Blacklist[block] = tick() + 30
            State.Rejects = State.Rejects + 1
            State.Watch = nil
            State.LastReason = 'server refused ' .. tostring(block.Name)
        end
    else
        State.Watch = { block = block, health = value, swings = 1 }
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

Hooks.getTargettedBlock = Game.AxeTool.getTargettedBlock
Game.AxeTool.getTargettedBlock = function(self, ...)
    if not (Config.Enabled and State.Tool == self) then
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

    if not toolIsEquipped() then
        State.LastReason = 'no breaking tool equipped'
        State.Hit = nil
        clearHighlight()
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
        Config.Enabled = false
        stopSwinging()
        State.LastReason = 'stopped — server refused ' .. tostring(State.Rejects) .. ' blocks in a row'
        notify('auto break', State.LastReason, 'warning', 8)
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
    Title = 'stop after refusals',
    Desc = 'blocks the server would not let you break, in a row',
    Flag = 'ib_rejectlimit',
    Min = 1, Max = 10, Increment = 1, Default = 3,
    Callback = function(v) Config.RejectLimit = v end,
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
        stopSwinging()
        clearHighlight()
        Game.ToolScript.onClickSetup = Hooks.onClickSetup
        Game.AxeTool.onBlockHit = Hooks.onBlockHit
        Game.AxeTool.getTargettedBlock = Hooks.getTargettedBlock
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

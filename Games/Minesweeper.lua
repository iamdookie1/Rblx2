--// Minesweeper -------------------------------------------------------------------
-- Mine positions are NOT replicated to the client. The server reveals a tile's
-- contents only after it is touched (MiscEvents.PlayEffect -> EffectScript,
-- which spawns the mine model on reveal). So there is nothing hidden to read.
--
-- Everything below is therefore derived the legitimate way: from the revealed
-- numbers, which the client necessarily has because it draws them. A tile is
-- only ever marked safe or mined when it is *provably* so - never a guess.
--
-- Two solving passes, both exact:
--   1. Single constraint. For a revealed number N with F flagged neighbours and
--      U unknown neighbours: if N-F == 0 every U is safe; if N-F == #U every U
--      is a mine.
--   2. Subset elimination. For constraints A and B where A's unknowns are a
--      subset of B's, the difference B\A must contain exactly (Nb-Fb)-(Na-Fa)
--      mines among #Ub-#Ua tiles. If that is 0 they are all safe; if the counts
--      match they are all mines. This is what cracks the pairs single-constraint
--      logic cannot.
--
-- Nothing probabilistic is shown. If a position genuinely requires a guess,
-- nothing lights up, which is the honest answer.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local Unloading = false

local function track(c) Connections[#Connections + 1] = c return c end
local function spawnLoop(fn) return task.spawn(fn) end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Config ------------------------------------------------------------------------
local Config = {
    ShowSafe = false,
    SafeMethod = "Highlight",
    SafeColor = Color3.fromRGB(80, 230, 120),

    ShowMines = false,
    MineMethod = "Highlight",
    MineColor = Color3.fromRGB(240, 70, 70),

    Transparency = 0.55,
    ScanInterval = 0.35,
}

local Stats = {
    Tiles = 0,
    Revealed = 0,
    Unknown = 0,
    Flagged = 0,
    Safe = 0,
    Mines = 0,
    LastSolve = 0,
    Dirty = 0,
    AvgNeighbours = 0,
    Pitch = 0,
    Status = "no board found",
}

--// Board model -------------------------------------------------------------------
-- tiles[part] = { part, gx, gz, state, number, neighbours }
-- state is "unknown" | "revealed" | "flagged"
local tiles = {}
local grid = {}
local tileList = {}
local dirty = {}
local dirtyCount = 0
local classification = {}   -- [part] = "safe" | "mine"  (what the solver last concluded)
local visuals = {}          -- [part] = { Highlight=, Box=, Outline= }
local tileSize, tileY, gridPitch = nil, nil, nil

local function markDirty(tile)
    if not dirty[tile] then
        dirty[tile] = true
        dirtyCount = dirtyCount + 1
    end
end

--// Reading a tile ------------------------------------------------------------------
-- The dump used to build this was captured in the lobby, so the exact way a
-- revealed number is drawn could not be confirmed. Rather than assume one, every
-- plausible representation is tried in order and the first that yields 0-8 wins.
-- If the board ever reads as all-unknown, this is the function to adjust.
local function readNumber(part)
    local ok, attrs = pcall(function() return part:GetAttributes() end)
    if ok and attrs then
        for _, value in pairs(attrs) do
            if typeof(value) == "number" and value >= 0 and value <= 8 then
                return math.floor(value)
            end
        end
    end

    for _, child in ipairs(part:GetChildren()) do
        if child:IsA("IntValue") or child:IsA("NumberValue") then
            local v = child.Value
            if v >= 0 and v <= 8 then return math.floor(v) end
        elseif child:IsA("StringValue") then
            local n = tonumber(child.Value)
            if n and n >= 0 and n <= 8 then return math.floor(n) end
        elseif child:IsA("SurfaceGui") or child:IsA("BillboardGui") then
            for _, label in ipairs(child:GetDescendants()) do
                if label:IsA("TextLabel") or label:IsA("TextButton") then
                    local n = tonumber((label.Text or ""):match("%d"))
                    if n and n >= 0 and n <= 8 then return n end
                end
            end
        end
    end

    return nil
end

-- Flags are placed as their own objects rather than parented to the tile, so
-- looking only at a tile's children misses them entirely and every flagged
-- square keeps counting as unknown. This maps flag objects onto tiles by
-- position instead, rebuilt each pass since flags come and go constantly.
local flaggedTiles = {}

local function refreshFlags()
    flaggedTiles = {}
    if not gridPitch then return end

    local budget = 4000
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if budget <= 0 then break end
        budget = budget - 1
        if inst:IsA("BasePart") or inst:IsA("Model") then
            if inst.Name:lower():find("flag") and not tiles[inst] then
                local ok, position = pcall(function()
                    if inst:IsA("Model") then return inst:GetPivot().Position end
                    return inst.Position
                end)
                if ok and position then
                    -- Nearest tile beneath the flag, within half a cell.
                    local bestTile, bestGap = nil, gridPitch * 0.75
                    for _, tile in ipairs(tileList) do
                        local tp = tile.part.Position
                        local gap = math.abs(tp.X - position.X) + math.abs(tp.Z - position.Z)
                        if gap < bestGap then
                            bestGap = gap
                            bestTile = tile
                        end
                    end
                    if bestTile then flaggedTiles[bestTile.part] = true end
                end
            end
        end
    end
end

local function isFlagged(part)
    if flaggedTiles[part] then return true end
    for _, child in ipairs(part:GetChildren()) do
        if child.Name:lower():find("flag") then return true end
    end
    local ok, flagged = pcall(function() return part:GetAttribute("Flagged") end)
    if ok and flagged == true then return true end
    return false
end

-- Returns state, number. A tile counts as revealed once a number can be read
-- off it; anything else is still unknown and therefore still solvable-for.
local function readTile(part)
    if isFlagged(part) then return "flagged", nil end
    local number = readNumber(part)
    if number then return "revealed", number end
    return "unknown", nil
end

--// Board discovery ------------------------------------------------------------------
-- The board is found by shape rather than by name: the largest set of
-- identically-sized parts sharing a top surface height is the grid. That
-- survives the tiles being renamed or reparented between rounds.
local function discoverBoard()
    local buckets = {}
    local budget = 12000

    local character = LocalPlayer.Character

    for _, inst in ipairs(Workspace:GetDescendants()) do
        if budget <= 0 then break end
        budget = budget - 1
        -- Guarded rather than `LocalPlayer.Character or Workspace`: with no
        -- character that fallback excludes everything in Workspace and the
        -- scan silently finds nothing.
        local mine = character ~= nil and inst:IsDescendantOf(character)
        if inst:IsA("BasePart") and not mine then
            local size = inst.Size
            -- Tiles are flat and square-ish in plan.
            if math.abs(size.X - size.Z) < 0.05 and size.X >= 1 then
                local key = ("%.2f_%.2f_%.2f"):format(size.X, size.Y, size.Z)
                local bucket = buckets[key]
                if not bucket then
                    bucket = {}
                    buckets[key] = bucket
                end
                bucket[#bucket + 1] = inst
            end
        end
    end

    local best, bestCount = nil, 0
    for _, bucket in pairs(buckets) do
        if #bucket > bestCount then
            best, bestCount = bucket, #bucket
        end
    end

    if not best or bestCount < 9 then
        return false
    end

    -- Keep only the dominant height so a second, unrelated slab of same-sized
    -- parts elsewhere in the map cannot contaminate the grid.
    local heights = {}
    for _, part in ipairs(best) do
        local y = math.floor(part.Position.Y * 10 + 0.5) / 10
        heights[y] = (heights[y] or 0) + 1
    end
    local domY, domCount = nil, 0
    for y, count in pairs(heights) do
        if count > domCount then domY, domCount = y, count end
    end

    tiles, grid, tileList = {}, {}, {}
    tileSize = best[1].Size.X
    tileY = domY

    -- Grid pitch is measured, not assumed to equal tile size. If the board
    -- leaves any gap between tiles then size ~= spacing, and deriving cells
    -- from size alone puts every tile in its own island with no neighbours -
    -- which reads as a perfectly healthy board that can never solve anything.
    local onY = {}
    for _, part in ipairs(best) do
        local y = math.floor(part.Position.Y * 10 + 0.5) / 10
        if y == domY then onY[#onY + 1] = part end
    end

    local function smallestGap(values)
        table.sort(values)
        local gap = nil
        for i = 2, #values do
            local d = values[i] - values[i - 1]
            if d > 0.05 and (not gap or d < gap) then gap = d end
        end
        return gap
    end

    local xsSeen, zsSeen, xs, zs = {}, {}, {}, {}
    local minX, minZ = math.huge, math.huge
    for _, part in ipairs(onY) do
        local x = math.floor(part.Position.X * 100 + 0.5) / 100
        local z = math.floor(part.Position.Z * 100 + 0.5) / 100
        if not xsSeen[x] then xsSeen[x] = true xs[#xs + 1] = x end
        if not zsSeen[z] then zsSeen[z] = true zs[#zs + 1] = z end
        if x < minX then minX = x end
        if z < minZ then minZ = z end
    end

    local pitchX = smallestGap(xs) or tileSize
    local pitchZ = smallestGap(zs) or tileSize
    gridPitch = math.min(pitchX, pitchZ)

    for _, part in ipairs(onY) do
        do
            -- Anchored to the board's own corner rather than world origin, so
            -- a board sitting at arbitrary coordinates still lands on whole
            -- cell indices.
            local gx = math.floor((part.Position.X - minX) / pitchX + 0.5)
            local gz = math.floor((part.Position.Z - minZ) / pitchZ + 0.5)
            local tile = {
                part = part, gx = gx, gz = gz,
                state = "unknown", number = nil, neighbours = nil,
            }
            tiles[part] = tile
            tileList[#tileList + 1] = tile
            grid[gx] = grid[gx] or {}
            grid[gx][gz] = tile
        end
    end

    -- Neighbour links are built once and reused for the life of the board;
    -- recomputing them per solve is pure waste.
    for _, tile in ipairs(tileList) do
        local list = {}
        for dx = -1, 1 do
            for dz = -1, 1 do
                if not (dx == 0 and dz == 0) then
                    local column = grid[tile.gx + dx]
                    local other = column and column[tile.gz + dz]
                    if other then list[#list + 1] = other end
                end
            end
        end
        tile.neighbours = list
    end

    -- A healthy grid averages close to 8 neighbours per tile. Anything near 0
    -- means the cell derivation is wrong, which is invisible from the revealed
    -- count alone - so it gets reported rather than left to be guessed at.
    local totalNeighbours = 0
    for _, tile in ipairs(tileList) do
        totalNeighbours = totalNeighbours + #tile.neighbours
    end
    Stats.AvgNeighbours = #tileList > 0 and (totalNeighbours / #tileList) or 0
    Stats.Pitch = gridPitch or 0

    Stats.Tiles = #tileList
    return #tileList > 0
end

--// Visuals ----------------------------------------------------------------------
local function colorFor(kind)
    return kind == "mine" and Config.MineColor or Config.SafeColor
end

local function methodFor(kind)
    return kind == "mine" and Config.MineMethod or Config.SafeMethod
end

local function clearVisual(part)
    local v = visuals[part]
    if not v then return end
    if v.Highlight then v.Highlight:Destroy() end
    if v.Outline then v.Outline:Destroy() end
    if v.Box then pcall(function() v.Box:Remove() end) end
    visuals[part] = nil
end

local function applyVisual(part, kind)
    local method = methodFor(kind)
    local color = colorFor(kind)
    local existing = visuals[part]

    -- Same kind and same method: only the cheap properties are touched. This is
    -- the path taken when a transparency or colour slider moves, so dragging a
    -- slider never rebuilds a single instance.
    if existing and existing.Kind == kind and existing.Method == method then
        if existing.Highlight then
            existing.Highlight.FillColor = color
            existing.Highlight.OutlineColor = color
            existing.Highlight.FillTransparency = Config.Transparency
        elseif existing.Outline then
            existing.Outline.Color3 = color
            existing.Outline.SurfaceTransparency = Config.Transparency
        elseif existing.Box then
            existing.Box.Color = color
        end
        return
    end

    clearVisual(part)
    local v = { Kind = kind, Method = method }

    if method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = color
        hl.OutlineColor = color
        hl.FillTransparency = Config.Transparency
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = part
        hl.Parent = part
        v.Highlight = hl
    elseif method == "Outline" then
        local box = Instance.new("SelectionBox")
        box.Adornee = part
        box.Color3 = color
        box.LineThickness = 0.03
        box.SurfaceColor3 = color
        box.SurfaceTransparency = Config.Transparency
        box.Parent = part
        v.Outline = box
    elseif method == "Box" and typeof(Drawing) == "table" then
        pcall(function()
            local square = Drawing.new("Square")
            square.Thickness = 1.5
            square.Filled = false
            square.Color = color
            square.Visible = false
            v.Box = square
        end)
    end

    visuals[part] = v
end

-- Only ever called with the tiles whose conclusion actually changed.
local function applyDiff(newClass)
    local safe, mines = 0, 0

    for part, kind in pairs(newClass) do
        if kind == "safe" then safe = safe + 1 else mines = mines + 1 end
        local wanted = (kind == "safe" and Config.ShowSafe) or (kind == "mine" and Config.ShowMines)
        if wanted then
            if classification[part] ~= kind or not visuals[part] then
                applyVisual(part, kind)
            end
        else
            clearVisual(part)
        end
    end

    -- Anything previously marked that no longer is loses its visual, and only
    -- those. Nothing else is touched.
    for part in pairs(classification) do
        if not newClass[part] then
            clearVisual(part)
        end
    end

    classification = newClass
    Stats.Safe = safe
    Stats.Mines = mines
end

-- Re-applies visuals when a toggle/method/colour changes, without re-solving.
local function refreshVisualsOnly()
    for part, kind in pairs(classification) do
        local wanted = (kind == "safe" and Config.ShowSafe) or (kind == "mine" and Config.ShowMines)
        if wanted then
            applyVisual(part, kind)
        else
            clearVisual(part)
        end
    end
end

--// Solver -------------------------------------------------------------------------
-- Builds constraints only around the tiles that changed, then runs exact logic
-- over that local set. A single reveal touches at most a 5x5 neighbourhood, so
-- the work per update is bounded regardless of how large the board is.
local function buildConstraints(scope)
    local constraints = {}
    for _, tile in ipairs(scope) do
        if tile.state == "revealed" and tile.number then
            local unknowns, flagged = {}, 0
            for _, n in ipairs(tile.neighbours) do
                if n.state == "unknown" then
                    unknowns[#unknowns + 1] = n
                elseif n.state == "flagged" then
                    flagged = flagged + 1
                end
            end
            if #unknowns > 0 then
                local remaining = tile.number - flagged
                -- A negative remainder means the flags around this tile are
                -- wrong; trusting it would produce confident nonsense, so the
                -- constraint is dropped instead.
                if remaining >= 0 then
                    constraints[#constraints + 1] = {
                        tile = tile, unknowns = unknowns,
                        count = #unknowns, remaining = remaining,
                    }
                end
            end
        end
    end
    return constraints
end

local function solveScope(scope)
    local constraints = buildConstraints(scope)
    local result = {}

    -- Pass 1: single constraint.
    for _, c in ipairs(constraints) do
        if c.remaining == 0 then
            for _, u in ipairs(c.unknowns) do result[u.part] = "safe" end
        elseif c.remaining == c.count then
            for _, u in ipairs(c.unknowns) do result[u.part] = "mine" end
        end
    end

    -- Pass 2: subset elimination between overlapping constraints.
    for i = 1, #constraints do
        local a = constraints[i]
        local setA = {}
        for _, u in ipairs(a.unknowns) do setA[u] = true end

        for j = 1, #constraints do
            if i ~= j then
                local b = constraints[j]
                if b.count > a.count then
                    local subset = true
                    for _, u in ipairs(a.unknowns) do
                        if not table.find(b.unknowns, u) then
                            subset = false
                            break
                        end
                    end

                    if subset then
                        local extraCount = b.count - a.count
                        local extraMines = b.remaining - a.remaining
                        if extraMines == 0 or extraMines == extraCount then
                            local kind = extraMines == 0 and "safe" or "mine"
                            for _, u in ipairs(b.unknowns) do
                                if not setA[u] then result[u.part] = kind end
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

-- Merges a freshly solved local region into the standing conclusions. Tiles
-- outside the region keep whatever was concluded before, so a small change
-- never discards the rest of the board's solution.
local function solveIncremental()
    if dirtyCount == 0 then return end

    local scope = {}
    local seen = {}
    for tile in pairs(dirty) do
        -- Two rings: the changed tile's neighbours are the constraints that
        -- moved, and their neighbours are the tiles those constraints touch.
        for _, n1 in ipairs(tile.neighbours) do
            if not seen[n1] then seen[n1] = true scope[#scope + 1] = n1 end
            for _, n2 in ipairs(n1.neighbours) do
                if not seen[n2] then seen[n2] = true scope[#scope + 1] = n2 end
            end
        end
        if not seen[tile] then seen[tile] = true scope[#scope + 1] = tile end
    end

    local started = os.clock()
    local localResult = solveScope(scope)

    local merged = {}
    for part, kind in pairs(classification) do
        local tile = tiles[part]
        -- Drop stale conclusions about tiles that have since been revealed or
        -- flagged, and about anything inside the region just recomputed.
        if tile and tile.state == "unknown" and not seen[tile] then
            merged[part] = kind
        end
    end
    for part, kind in pairs(localResult) do
        local tile = tiles[part]
        if tile and tile.state == "unknown" then
            merged[part] = kind
        end
    end

    applyDiff(merged)

    Stats.LastSolve = (os.clock() - started) * 1000
    Stats.Dirty = dirtyCount
    dirty = {}
    dirtyCount = 0
end

--// Change detection ------------------------------------------------------------------
-- Only unknown tiles can change into something interesting, and a revealed tile
-- never goes back. So each pass re-reads just the tiles that are still unknown,
-- which shrinks steadily as the board is cleared.
local function scanForChanges()
    local revealed, unknown, flagged = 0, 0, 0

    refreshFlags()

    for _, tile in ipairs(tileList) do
        -- Revealed tiles never revert, so they are skipped. Unknown and flagged
        -- both still move - a flag can be taken back off - so both are re-read.
        if tile.state ~= "revealed" then
            if tile.part.Parent then
                local state, number = readTile(tile.part)
                if state ~= tile.state or number ~= tile.number then
                    tile.state = state
                    tile.number = number
                    markDirty(tile)
                    -- A flag change alters every constraint touching this tile,
                    -- so its neighbours need re-solving too.
                    for _, n in ipairs(tile.neighbours) do markDirty(n) end
                end
            end
        end
        if tile.state == "revealed" then revealed = revealed + 1
        elseif tile.state == "flagged" then flagged = flagged + 1
        else unknown = unknown + 1 end
    end

    Stats.Revealed = revealed
    Stats.Unknown = unknown
    Stats.Flagged = flagged
end

local boardReady = false

spawnLoop(function()
    while not Unloading do
        if not boardReady then
            local ok = pcall(discoverBoard)
            if ok and #tileList > 0 then
                boardReady = true
                Stats.Status = ("board found: %d tiles"):format(#tileList)
                for _, tile in ipairs(tileList) do markDirty(tile) end
            else
                Stats.Status = "no board found"
                task.wait(1.5)
            end
        else
            -- A board that has vanished (round ended) is rediscovered rather
            -- than left pointing at destroyed parts.
            if #tileList == 0 or not tileList[1].part.Parent then
                boardReady = false
                for part in pairs(visuals) do clearVisual(part) end
                classification = {}
                Stats.Status = "board gone, rescanning"
            else
                pcall(scanForChanges)
                pcall(solveIncremental)
            end
        end
        task.wait(Config.ScanInterval)
    end
end)

--// Box drawing (only when that method is in use) -----------------------------------
track(PreRender:Connect(function()
    if Unloading then return end
    for part, v in pairs(visuals) do
        if v.Box then
            if not part.Parent then
                clearVisual(part)
            else
                local screen, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen then
                    local size = math.max(8, 900 / math.max(screen.Z, 1))
                    v.Box.Visible = true
                    v.Box.Position = Vector2.new(screen.X - size / 2, screen.Y - size / 2)
                    v.Box.Size = Vector2.new(size, size)
                else
                    v.Box.Visible = false
                end
            end
        end
    end
end))

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'minesweeper',
    SubTitle = 'solver',
    Folder = 'MinesweeperSolver',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(90, 220, 140),
})

local MainTab = Window:Tab({ Title = 'main', Icon = 'grid-3x3' })

local SafeSection = MainTab:Section({ Title = 'safe tiles', Side = 'left' })

SafeSection:Toggle({
    Title = 'show safe',
    Flag = 'ms_show_safe',
    Default = false,
    Callback = function(v)
        Config.ShowSafe = v
        refreshVisualsOnly()
    end,
})

SafeSection:Dropdown({
    Title = 'show as',
    Flag = 'ms_safe_method',
    Options = { 'Highlight', 'Outline', 'Box' },
    Default = 'Highlight',
    Callback = function(v)
        Config.SafeMethod = v
        refreshVisualsOnly()
    end,
})

SafeSection:Colorpicker({
    Title = 'safe color',
    Flag = 'ms_safe_color',
    Default = Color3.fromRGB(80, 230, 120),
    Callback = function(v)
        Config.SafeColor = v
        refreshVisualsOnly()
    end,
})

local MineSection = MainTab:Section({ Title = 'mines', Side = 'right' })

MineSection:Toggle({
    Title = 'show mines',
    Flag = 'ms_show_mines',
    Default = false,
    Callback = function(v)
        Config.ShowMines = v
        refreshVisualsOnly()
    end,
})

MineSection:Dropdown({
    Title = 'show as',
    Flag = 'ms_mine_method',
    Options = { 'Highlight', 'Outline', 'Box' },
    Default = 'Highlight',
    Callback = function(v)
        Config.MineMethod = v
        refreshVisualsOnly()
    end,
})

MineSection:Colorpicker({
    Title = 'mine color',
    Flag = 'ms_mine_color',
    Default = Color3.fromRGB(240, 70, 70),
    Callback = function(v)
        Config.MineColor = v
        refreshVisualsOnly()
    end,
})

local SharedSection = MainTab:Section({ Title = 'display', Side = 'left' })

SharedSection:Slider({
    Title = 'transparency',
    Flag = 'ms_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.55,
    Callback = function(v)
        Config.Transparency = v
        refreshVisualsOnly()
    end,
})

SharedSection:Slider({
    Title = 'update interval',
    Flag = 'ms_interval',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = 0.35,
    Suffix = 's',
    Callback = function(v) Config.ScanInterval = v end,
})

SharedSection:Paragraph({
    Title = 'only certainties are shown',
    Text = 'A tile lights up only when the surrounding numbers prove it. Two exact passes run: a number with its mines already flagged makes every remaining neighbour safe, and a number needing exactly as many mines as it has unknowns makes them all mines. Overlapping constraints are then compared against each other, which resolves the pairs the first pass cannot. Positions that genuinely require a guess stay dark rather than showing odds.',
})

local StatusSection = MainTab:Section({ Title = 'status', Side = 'right' })

local boardLabel = StatusSection:Label({ Title = 'board: scanning...' })
local countLabel = StatusSection:Label({ Title = 'revealed 0 / unknown 0 / flagged 0' })
local resultLabel = StatusSection:Label({ Title = 'safe 0 / mines 0' })
local perfLabel = StatusSection:Label({ Title = 'last solve: --' })
local gridLabel = StatusSection:Label({ Title = 'grid: --' })

StatusSection:Button({
    Title = 'rescan board',
    Callback = function()
        boardReady = false
        for part in pairs(visuals) do clearVisual(part) end
        classification = {}
        dirty = {}
        dirtyCount = 0
        Stats.Status = 'rescanning'
    end,
})

StatusSection:Paragraph({
    Title = 'if nothing ever lights up',
    Text = 'Read the grid line. Neighbours average should sit near 8 - if it is near 0 the cells were derived wrongly and no tile can see the numbers around it, which looks identical to a healthy board from the counts alone. If neighbours look right but revealed stays at 0, the numbers are drawn in a form the reader does not know yet.',
})

spawnLoop(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            boardLabel:Set('board: ' .. tostring(Stats.Status))
            countLabel:Set(('revealed %d / unknown %d / flagged %d'):format(
                Stats.Revealed, Stats.Unknown, Stats.Flagged))
            resultLabel:Set(('safe %d / mines %d'):format(Stats.Safe, Stats.Mines))
            if Stats.LastSolve > 0 then
                perfLabel:Set(('last solve: %.2f ms over %d changed'):format(Stats.LastSolve, Stats.Dirty))
            else
                perfLabel:Set('last solve: --')
            end
            gridLabel:Set(('grid: pitch %.2f, %.1f neighbours avg'):format(Stats.Pitch, Stats.AvgNeighbours))
        end)
    end
end)

StatusSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
        for part in pairs(visuals) do clearVisual(part) end
        Centrl:Unload()
    end,
})

Window:Load()

Centrl:Notify({
    Title = 'minesweeper',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

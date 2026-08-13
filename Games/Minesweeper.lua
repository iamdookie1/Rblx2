--// Minesweeper -------------------------------------------------------------------
-- Board:   workspace.Flag.Parts        (one Part per tile)
-- Number:  part.NumberGui.TextLabel.Text
-- Flag:    an object carrying a UserId attribute (names who placed it)
--
-- Mine positions are never replicated - the server reveals a tile only once it
-- is touched - so nothing hidden is being read. Everything below is derived from
-- the revealed numbers, which the client necessarily has because it draws them,
-- and a tile is only marked when it is provably safe or provably mined.
--
-- On placing flags: the game reads a token out of workspace.Salasana at startup
-- and then zeroes, renames and destroys it, so a script injected later cannot
-- read it. Every PlaceFlag:FireServer(part, token, true) needs that value, which
-- is why blindly firing the remote does nothing. Two routes actually work:
-- recover the token from the upvalues of the game's own handler, or fire the
-- ClickDetector the game made and let its handler send the token for us.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modern, legacy)
    local ok, ev = pcall(function() return RunService[modern] end)
    if ok and ev then return ev end
    return RunService[legacy]
end
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local Unloading = false
local function track(c) Connections[#Connections + 1] = c return c end

--// Config ------------------------------------------------------------------------
local Config = {
    ShowSafe = false,
    SafeMethod = "Highlight",
    SafeColor = Color3.fromRGB(70, 170, 255),

    ShowMines = false,
    MineMethod = "Highlight",
    MineColor = Color3.fromRGB(255, 60, 60),

    Transparency = 0.5,
    -- Solving is event driven, so this is only how often the safety sweep runs.
    Backstop = 1,

    AutoFlag = false,
    FlagRange = 16,
    FlagDelay = 0.06,
    FlagMethod = "Auto",
}

local Stats = {
    Tiles = 0, Revealed = 0, Unknown = 0, Flagged = 0,
    Safe = 0, Mines = 0, LastSolve = 0, Changed = 0,
    Neighbours = 0, Token = "not found", Status = "waiting for board",
}

--// Board -------------------------------------------------------------------------
local FlagModel, PartsFolder
local boardPitch = nil
local tiles = {}          -- [part] = tile
local tileList = {}
local dirty, dirtyCount = {}, 0
local classification = {} -- [part] = "safe" | "mine"
local visuals = {}
local flaggedByUs = {}

local function markDirty(tile)
    if tile and not dirty[tile] then
        dirty[tile] = true
        dirtyCount = dirtyCount + 1
    end
end

--// Reading -----------------------------------------------------------------------
local function readNumber(part)
    local gui = part:FindFirstChild("NumberGui")
    if not gui then return nil end
    local label = gui:FindFirstChild("TextLabel") or gui:FindFirstChildWhichIsA("TextLabel", true)
    if not label then return nil end
    local text = label.Text
    if not text or text == "" then
        -- An opened tile with no text is a zero: every neighbour is safe, which
        -- is the single most useful constraint on the board.
        return 0
    end
    return tonumber(text)
end

-- Marker on everything this script parents to a tile, so foreign-child
-- detection below cannot mistake our own highlights for a flag.
local OURS = "MSV_"

-- A flag carries a UserId attribute naming whoever placed it. That is the one
-- unambiguous marker: the name is server-built and varies, and "anything
-- foreign parented to the tile" catches decor that is not a flag at all.
local function carriesUserId(inst)
    local ok, value = pcall(function() return inst:GetAttribute("UserId") end)
    return ok and value ~= nil
end

-- Flags placed away from the tile rather than parented to it, mapped onto the
-- tile beneath them. Rebuilt only when a sweep actually needs it.
local looseFlags = {}

local function hasFlag(part)
    if carriesUserId(part) then return true end
    for _, d in ipairs(part:GetDescendants()) do
        if d.Name:sub(1, #OURS) ~= OURS and carriesUserId(d) then
            return true
        end
    end
    return looseFlags[part] == true
end

-- Sweeps for flag objects that are not inside a tile and pins each to the
-- nearest one. Only worth doing if the per-tile check is coming up empty, so
-- the caller decides when.
local function refreshLooseFlags(tileList, pitch)
    looseFlags = {}
    if not pitch then return end
    local budget = 6000
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if budget <= 0 then break end
        budget = budget - 1
        if (inst:IsA("BasePart") or inst:IsA("Model")) and carriesUserId(inst) then
            local ok, pos = pcall(function()
                if inst:IsA("Model") then return inst:GetPivot().Position end
                return inst.Position
            end)
            if ok and pos then
                local best, bestGap = nil, pitch * 0.75
                for _, tile in ipairs(tileList) do
                    local tp = tile.part.Position
                    local gap = math.abs(tp.X - pos.X) + math.abs(tp.Z - pos.Z)
                    if gap < bestGap then bestGap, best = gap, tile end
                end
                if best then looseFlags[best.part] = true end
            end
        end
    end
end

-- "revealed" once a number can be read, "flagged" if a flag sits on it, else
-- still unknown and therefore still worth solving for.
local function readTile(part)
    if hasFlag(part) then return "flagged", nil end
    local n = readNumber(part)
    if n then return "revealed", n end
    return "unknown", nil
end

--// Discovery ---------------------------------------------------------------------
-- Neighbours are matched by distance rather than by dividing position by tile
-- size: the board leaves a gap between tiles, so size-based cell maths puts
-- every tile on its own index with no neighbours at all - which looks identical
-- to a healthy board from the counts and can never solve anything.
local function buildBoard()
    FlagModel = Workspace:FindFirstChild("Flag")
    PartsFolder = FlagModel and FlagModel:FindFirstChild("Parts")
    if not PartsFolder then return false end

    tiles, tileList = {}, {}
    local parts = {}
    for _, part in ipairs(PartsFolder:GetChildren()) do
        if part:IsA("BasePart") then parts[#parts + 1] = part end
    end
    if #parts == 0 then return false end

    -- Spacing measured off the board itself, then used as the bucket size for a
    -- spatial hash so neighbour matching stays linear instead of comparing every
    -- tile against every other one.
    local pitch = math.huge
    local sample = math.min(#parts, 200)
    for i = 1, sample do
        for j = i + 1, sample do
            local d = (parts[i].Position - parts[j].Position).Magnitude
            if d > 0.05 and d < pitch then pitch = d end
        end
    end
    if pitch == math.huge then pitch = parts[1].Size.X end
    boardPitch = pitch

    local buckets = {}
    local function keyOf(pos)
        return ("%d_%d"):format(math.floor(pos.X / pitch + 0.5), math.floor(pos.Z / pitch + 0.5))
    end

    for _, part in ipairs(parts) do
        local tile = { part = part, state = "unknown", number = nil, neighbours = {} }
        tiles[part] = tile
        tileList[#tileList + 1] = tile
        local k = keyOf(part.Position)
        buckets[k] = buckets[k] or {}
        table.insert(buckets[k], tile)
    end

    local reach = pitch * 1.6
    for _, tile in ipairs(tileList) do
        local pos = tile.part.Position
        local bx = math.floor(pos.X / pitch + 0.5)
        local bz = math.floor(pos.Z / pitch + 0.5)
        local list = {}
        for dx = -1, 1 do
            for dz = -1, 1 do
                local bucket = buckets[("%d_%d"):format(bx + dx, bz + dz)]
                if bucket then
                    for _, other in ipairs(bucket) do
                        if other ~= tile then
                            local d = (other.part.Position - pos).Magnitude
                            if d <= reach then list[#list + 1] = other end
                        end
                    end
                end
            end
        end
        tile.neighbours = list
    end

    local total = 0
    for _, t in ipairs(tileList) do total = total + #t.neighbours end
    Stats.Neighbours = #tileList > 0 and total / #tileList or 0
    Stats.Tiles = #tileList
    return true
end

--// Flag token --------------------------------------------------------------------
-- workspace.Salasana is destroyed by the game before an injected script can read
-- it, so the value is recovered from where it still lives: captured as an upvalue
-- inside the handler the game connected. A closure that holds the PlaceFlag
-- remote is the one we want, and its numeric upvalue is the token.
local PlaceFlagRemote
local flagToken = nil

local function findPlaceFlagRemote()
    local events = ReplicatedStorage:FindFirstChild("Events")
    local folder = events and events:FindFirstChild("FlagEvents")
    return folder and folder:FindFirstChild("PlaceFlag")
end

local function recoverToken()
    PlaceFlagRemote = PlaceFlagRemote or findPlaceFlagRemote()

    -- Free if we got in early enough: the value is still sitting there.
    local salasana = Workspace:FindFirstChild("Salasana")
    if salasana and salasana:IsA("ValueBase") then
        local ok, v = pcall(function() return salasana.Value end)
        if ok and typeof(v) == "number" and v ~= 0 then
            flagToken = v
            Stats.Token = "read from Salasana"
            return true
        end
    end

    if not PlaceFlagRemote then return false end
    if typeof(getgc) ~= "function" or typeof(debug) ~= "table" or typeof(debug.getupvalues) ~= "function" then
        Stats.Token = "no getgc on this executor"
        return false
    end

    local found = nil
    pcall(function()
        for _, fn in ipairs(getgc()) do
            if type(fn) == "function" then
                local ok, ups = pcall(debug.getupvalues, fn)
                if ok and type(ups) == "table" then
                    local holdsRemote, candidate = false, nil
                    for _, up in pairs(ups) do
                        if up == PlaceFlagRemote then
                            holdsRemote = true
                        elseif typeof(up) == "number" and up ~= 0 then
                            candidate = up
                        end
                    end
                    -- Some closures capture ReplicatedStorage rather than the
                    -- remote itself, so a nearby numeric upvalue alone is not
                    -- enough; the remote has to be in the same closure.
                    if holdsRemote and candidate then
                        found = candidate
                        break
                    end
                end
            end
        end
    end)

    if found then
        flagToken = found
        Stats.Token = "recovered from handler"
        return true
    end

    Stats.Token = "not found"
    return false
end

local function placeFlag(part)
    local method = Config.FlagMethod

    if method == "Auto" or method == "Token" then
        if not flagToken then recoverToken() end
        if flagToken and PlaceFlagRemote then
            local ok = pcall(function()
                PlaceFlagRemote:FireServer(part, flagToken, true)
            end)
            if ok then return true end
        end
        if method == "Token" then return false end
    end

    -- The game only creates ClickDetectors on touch devices, but where one
    -- exists its handler already holds the token, so firing it is the most
    -- faithful route available.
    local detector = part:FindFirstChildOfClass("ClickDetector")
    if detector and typeof(fireclickdetector) == "function" then
        local ok = pcall(fireclickdetector, detector)
        if ok then return true end
    end

    return false
end

--// Visuals ----------------------------------------------------------------------
local function clearVisual(part)
    local v = visuals[part]
    if not v then return end
    for _, inst in ipairs(v.Objects) do
        pcall(function() inst:Destroy() end)
    end
    visuals[part] = nil
end

local function buildVisual(part, method, color)
    local made = {}

    local function add(inst)
        -- Tagged so flag detection can tell our own markers apart from a real
        -- flag the game placed.
        inst.Name = OURS .. inst.ClassName
        made[#made + 1] = inst
        return inst
    end

    if method == "Highlight" then
        local h = add(Instance.new("Highlight"))
        h.FillColor, h.OutlineColor = color, color
        h.FillTransparency = Config.Transparency
        h.OutlineTransparency = 0
        h.Adornee = part
        h.Parent = part
    elseif method == "SelectionBox" then
        local b = add(Instance.new("SelectionBox"))
        b.Color3, b.SurfaceColor3 = color, color
        b.LineThickness = 0.05
        b.SurfaceTransparency = Config.Transparency
        b.Adornee = part
        b.Parent = part
    elseif method == "BoxAdornment" then
        local b = add(Instance.new("BoxHandleAdornment"))
        b.Size = part.Size * 1.02
        b.Color3 = color
        b.Transparency = Config.Transparency
        b.AlwaysOnTop = true
        b.ZIndex = 1
        b.Adornee = part
        b.Parent = part
    elseif method == "SphereAdornment" then
        local s = add(Instance.new("SphereHandleAdornment"))
        s.Radius = math.max(part.Size.X, part.Size.Z) / 2
        s.Color3 = color
        s.Transparency = Config.Transparency
        s.AlwaysOnTop = true
        s.Adornee = part
        s.Parent = part
    elseif method == "SurfaceGui" then
        local g = add(Instance.new("SurfaceGui"))
        g.Face = Enum.NormalId.Top
        g.AlwaysOnTop = true
        g.Adornee = part
        g.Parent = part
        local f = Instance.new("Frame")
        f.Size = UDim2.fromScale(1, 1)
        f.BackgroundColor3 = color
        f.BackgroundTransparency = Config.Transparency
        f.BorderSizePixel = 0
        f.Parent = g
    elseif method == "Billboard" then
        local b = add(Instance.new("BillboardGui"))
        b.Size = UDim2.fromOffset(28, 28)
        b.AlwaysOnTop = true
        b.Adornee = part
        b.Parent = part
        local f = Instance.new("Frame")
        f.Size = UDim2.fromScale(1, 1)
        f.BackgroundColor3 = color
        f.BackgroundTransparency = Config.Transparency
        f.BorderSizePixel = 0
        f.Parent = b
    elseif method == "PointLight" then
        local l = add(Instance.new("PointLight"))
        l.Color = color
        l.Brightness = 3
        l.Range = 8
        l.Parent = part
    elseif method == "Neon Overlay" then
        local p = add(Instance.new("Part"))
        p.Size = part.Size * 1.02
        p.CFrame = part.CFrame
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.Material = Enum.Material.Neon
        p.Color = color
        p.Transparency = Config.Transparency
        p.Parent = part
    end

    return made
end

local function applyVisual(part, kind)
    local method = kind == "mine" and Config.MineMethod or Config.SafeMethod
    local color = kind == "mine" and Config.MineColor or Config.SafeColor
    local existing = visuals[part]

    -- Same kind and method: only cheap properties are touched, so dragging the
    -- transparency slider never rebuilds a single instance.
    if existing and existing.Kind == kind and existing.Method == method then
        for _, inst in ipairs(existing.Objects) do
            pcall(function()
                if inst:IsA("Highlight") then
                    inst.FillColor, inst.OutlineColor = color, color
                    inst.FillTransparency = Config.Transparency
                elseif inst:IsA("SelectionBox") then
                    inst.Color3, inst.SurfaceColor3 = color, color
                    inst.SurfaceTransparency = Config.Transparency
                elseif inst:IsA("HandleAdornment") then
                    inst.Color3 = color
                    inst.Transparency = Config.Transparency
                elseif inst:IsA("BasePart") then
                    inst.Color = color
                    inst.Transparency = Config.Transparency
                elseif inst:IsA("PointLight") then
                    inst.Color = color
                elseif inst:IsA("SurfaceGui") or inst:IsA("BillboardGui") then
                    local f = inst:FindFirstChildWhichIsA("Frame")
                    if f then
                        f.BackgroundColor3 = color
                        f.BackgroundTransparency = Config.Transparency
                    end
                end
            end)
        end
        return
    end

    clearVisual(part)
    visuals[part] = { Kind = kind, Method = method, Objects = buildVisual(part, method, color) }
end

-- The game runs a detector once a second that counts tiles whose Color is
-- exactly Color3.new(0,1,0) or Color3.new(1,0,0) and reports the number to the
-- server over ReplicatedStorage.Message with the tag "Color". It is aimed
-- squarely at solver scripts that paint tiles pure green and pure red.
--
-- Nothing here writes a tile's own Color, so the detector has nothing to see -
-- but a colour picked at exactly those two values would still be an odd thing
-- to be wearing, so both are nudged off the exact match.
local function safeColor(color)
    local r = math.floor(color.R * 255 + 0.5)
    local g = math.floor(color.G * 255 + 0.5)
    local b = math.floor(color.B * 255 + 0.5)
    if (r == 0 and g == 255 and b == 0) or (r == 255 and g == 0 and b == 0) then
        return Color3.fromRGB(math.min(r + 8, 255), math.min(g, 247) + 8, b + 8)
    end
    return color
end

local function wanted(kind)
    return (kind == "safe" and Config.ShowSafe) or (kind == "mine" and Config.ShowMines)
end

local function applyDiff(newClass)
    local safe, mines = 0, 0
    for part, kind in pairs(newClass) do
        if kind == "safe" then safe = safe + 1 else mines = mines + 1 end
        if wanted(kind) then
            if classification[part] ~= kind or not visuals[part] then
                applyVisual(part, kind)
            end
        else
            clearVisual(part)
        end
    end
    -- Only tiles that stopped being classified lose their visual. Nothing else
    -- is touched.
    for part in pairs(classification) do
        if not newClass[part] then clearVisual(part) end
    end
    classification = newClass
    Stats.Safe, Stats.Mines = safe, mines
end

local function refreshVisualsOnly()
    for part, kind in pairs(classification) do
        if wanted(kind) then applyVisual(part, kind) else clearVisual(part) end
    end
end

--// Solver -------------------------------------------------------------------------
local function buildConstraints(scope)
    local out = {}
    for _, tile in ipairs(scope) do
        if tile.state == "revealed" and tile.number then
            local unknowns, flags = {}, 0
            for _, n in ipairs(tile.neighbours) do
                if n.state == "unknown" then unknowns[#unknowns + 1] = n
                elseif n.state == "flagged" then flags = flags + 1 end
            end
            if #unknowns > 0 then
                local remaining = tile.number - flags
                -- A negative remainder means the flags nearby are wrong; acting
                -- on it would produce confident nonsense, so it is dropped.
                if remaining >= 0 then
                    out[#out + 1] = { unknowns = unknowns, count = #unknowns, remaining = remaining }
                end
            end
        end
    end
    return out
end

local function solveScope(scope)
    local cs = buildConstraints(scope)
    local result = {}

    -- Pass 1: a number with its mines already flagged frees the rest; a number
    -- needing as many mines as it has unknowns mines them all.
    for _, c in ipairs(cs) do
        if c.remaining == 0 then
            for _, u in ipairs(c.unknowns) do result[u.part] = "safe" end
        elseif c.remaining == c.count then
            for _, u in ipairs(c.unknowns) do result[u.part] = "mine" end
        end
    end

    -- Pass 2: subset elimination. Where A's unknowns sit inside B's, the
    -- difference holds exactly (Rb - Ra) mines across (Cb - Ca) tiles. This is
    -- what resolves the pairs pass 1 cannot.
    local limit = math.min(#cs, 300)
    for i = 1, limit do
        local a = cs[i]
        local inA = {}
        for _, u in ipairs(a.unknowns) do inA[u] = true end
        for j = 1, limit do
            local b = cs[j]
            if i ~= j and b.count > a.count then
                local subset = true
                for _, u in ipairs(a.unknowns) do
                    if not table.find(b.unknowns, u) then subset = false break end
                end
                if subset then
                    local extra = b.count - a.count
                    local mines = b.remaining - a.remaining
                    if mines == 0 or mines == extra then
                        local kind = mines == 0 and "safe" or "mine"
                        for _, u in ipairs(b.unknowns) do
                            if not inA[u] then result[u.part] = kind end
                        end
                    end
                end
            end
        end
    end

    return result
end

local function solveIncremental()
    if dirtyCount == 0 then return end

    -- Two rings: the changed tile's neighbours are the constraints that moved,
    -- and their neighbours are the tiles those constraints reach.
    local scope, seen = {}, {}
    local function push(t)
        if not seen[t] then seen[t] = true scope[#scope + 1] = t end
    end
    for tile in pairs(dirty) do
        push(tile)
        for _, n1 in ipairs(tile.neighbours) do
            push(n1)
            for _, n2 in ipairs(n1.neighbours) do push(n2) end
        end
    end

    local started = os.clock()
    local localResult = solveScope(scope)

    -- Conclusions outside the recomputed region are carried forward, so one
    -- reveal never discards the rest of the board's solution.
    local merged = {}
    for part, kind in pairs(classification) do
        local tile = tiles[part]
        if tile and tile.state == "unknown" and not seen[tile] then
            merged[part] = kind
        end
    end
    for part, kind in pairs(localResult) do
        local tile = tiles[part]
        if tile and tile.state == "unknown" then merged[part] = kind end
    end

    applyDiff(merged)
    Stats.LastSolve = (os.clock() - started) * 1000
    Stats.Changed = dirtyCount
    dirty, dirtyCount = {}, 0
end

--// Change tracking -----------------------------------------------------------------
-- Set by anything that changes the board; the frame loop below picks it up on
-- the very next step. Coalescing through a flag means a burst of twenty reveals
-- costs one solve rather than twenty.
local solveQueued = false
local function requestSolve() solveQueued = true end

local function refreshTile(tile)
    if not tile.part.Parent then return end
    local state, number = readTile(tile.part)
    if state ~= tile.state or number ~= tile.number then
        tile.state, tile.number = state, number

        -- A tile that just got flagged or revealed is no longer something to
        -- point at, so its marker goes immediately rather than surviving until
        -- the next solve. This is the flag-a-bomb-and-it-vanishes case.
        if state ~= "unknown" and classification[tile.part] then
            clearVisual(tile.part)
            classification[tile.part] = nil
        end

        markDirty(tile)
        -- A reveal or a flag changes every constraint touching this tile.
        for _, n in ipairs(tile.neighbours) do markDirty(n) end
        requestSolve()
    end
end

local function fullRescanCounts()
    local r, u, f = 0, 0, 0
    for _, t in ipairs(tileList) do
        if t.state == "revealed" then r = r + 1
        elseif t.state == "flagged" then f = f + 1
        else u = u + 1 end
    end
    Stats.Revealed, Stats.Unknown, Stats.Flagged = r, u, f
end

--// Auto flag ------------------------------------------------------------------------
local flagBusy = false

local function autoFlagPass()
    if flagBusy or not Config.AutoFlag then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    flagBusy = true

    local queue = {}
    for part, kind in pairs(classification) do
        if kind == "mine" and part.Parent and not flaggedByUs[part] then
            local tile = tiles[part]
            if tile and tile.state == "unknown" then
                local d = (part.Position - root.Position).Magnitude
                if d <= Config.FlagRange then
                    queue[#queue + 1] = { part = part, d = d }
                end
            end
        end
    end
    table.sort(queue, function(a, b) return a.d < b.d end)

    for _, entry in ipairs(queue) do
        if Unloading or not Config.AutoFlag then break end
        if entry.part.Parent and not hasFlag(entry.part) then
            flaggedByUs[entry.part] = true
            placeFlag(entry.part)
            task.wait(Config.FlagDelay)
        end
    end

    flagBusy = false
end

--// Main loop -------------------------------------------------------------------------
local boardReady = false

task.spawn(function()
    while not Unloading do
        if not boardReady then
            local ok = pcall(buildBoard)
            if ok and #tileList > 0 then
                boardReady = true
                Stats.Status = ("board found: %d tiles"):format(#tileList)
                for _, t in ipairs(tileList) do refreshTile(t) markDirty(t) end
                recoverToken()

                -- Event driven from here: a tile only changes when something is
                -- added to it, so polling every tile every frame is wasted work.
                track(PartsFolder.DescendantAdded:Connect(function(d)
                    local part = d:FindFirstAncestorWhichIsA("BasePart")
                    if part and tiles[part] then
                        refreshTile(tiles[part])
                    end
                end))
                track(PartsFolder.DescendantRemoving:Connect(function(d)
                    local part = d:FindFirstAncestorWhichIsA("BasePart")
                    if part and tiles[part] then
                        task.defer(function()
                            if tiles[part] then refreshTile(tiles[part]) end
                        end)
                    end
                end))
                track(PartsFolder.ChildRemoved:Connect(function()
                    boardReady = false
                end))
            else
                Stats.Status = "waiting for board"
                task.wait(1)
            end
        else
            if not PartsFolder or not PartsFolder.Parent or #tileList == 0 then
                boardReady = false
                for part in pairs(visuals) do clearVisual(part) end
                classification, flaggedByUs = {}, {}
                Stats.Status = "board gone, rescanning"
            else
                -- Backstop only. The events above drive everything in real
                -- time; this exists purely to catch a change that somehow did
                -- not raise one, so it runs rarely instead of every tick.
                -- If no flag has been spotted on any tile but flags clearly
                -- exist elsewhere, they are parented somewhere other than the
                -- tile, so pin them by position. Only runs while the cheap
                -- per-tile check is finding nothing.
                if Stats.Flagged == 0 then
                    pcall(refreshLooseFlags, tileList, boardPitch)
                end
                for _, t in ipairs(tileList) do
                    if t.state ~= "revealed" then refreshTile(t) end
                end
                fullRescanCounts()
                if Config.AutoFlag then task.spawn(autoFlagPass) end
            end
        end
        task.wait(Config.Backstop)
    end
end)

-- Solving runs on the frame after a change lands, not on a timer. Nothing
-- happens on frames where the board did not move, so this costs nothing while
-- idle and updates immediately when it matters.
track(PostSimulation:Connect(function()
    if Unloading or not boardReady or not solveQueued then return end
    solveQueued = false
    pcall(solveIncremental)
    fullRescanCounts()
end))

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'minesweeper',
    SubTitle = 'solver',
    Folder = 'MinesweeperSolver',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(90, 200, 255),
})

local METHODS = {
    'Highlight', 'SelectionBox', 'BoxAdornment', 'SphereAdornment',
    'SurfaceGui', 'Billboard', 'PointLight', 'Neon Overlay',
}

local MainTab = Window:Tab({ Title = 'main', Icon = 'grid-3x3' })

local SafeSection = MainTab:Section({ Title = 'safe tiles', Side = 'left' })

SafeSection:Toggle({
    Title = 'show safe',
    Flag = 'ms_safe',
    Default = false,
    Callback = function(v) Config.ShowSafe = v refreshVisualsOnly() end,
})

SafeSection:Dropdown({
    Title = 'show as',
    Flag = 'ms_safe_method',
    Options = METHODS,
    Default = 'Highlight',
    Callback = function(v) Config.SafeMethod = v refreshVisualsOnly() end,
})

SafeSection:Colorpicker({
    Title = 'safe color',
    Flag = 'ms_safe_color',
    Default = Color3.fromRGB(70, 170, 255),
    Callback = function(v) Config.SafeColor = safeColor(v) refreshVisualsOnly() end,
})

local MineSection = MainTab:Section({ Title = 'mines', Side = 'right' })

MineSection:Toggle({
    Title = 'show mines',
    Flag = 'ms_mines',
    Default = false,
    Callback = function(v) Config.ShowMines = v refreshVisualsOnly() end,
})

MineSection:Dropdown({
    Title = 'show as',
    Flag = 'ms_mine_method',
    Options = METHODS,
    Default = 'Highlight',
    Callback = function(v) Config.MineMethod = v refreshVisualsOnly() end,
})

MineSection:Colorpicker({
    Title = 'mine color',
    Flag = 'ms_mine_color',
    Default = Color3.fromRGB(255, 60, 60),
    Callback = function(v) Config.MineColor = safeColor(v) refreshVisualsOnly() end,
})

local DisplaySection = MainTab:Section({ Title = 'display', Side = 'left' })

DisplaySection:Slider({
    Title = 'transparency',
    Flag = 'ms_transparency',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.5,
    Callback = function(v) Config.Transparency = v refreshVisualsOnly() end,
})

DisplaySection:Slider({
    Title = 'backstop sweep',
    Flag = 'ms_backstop',
    Min = 0.25, Max = 5, Increment = 0.25, Default = 1,
    Suffix = 's',
    Callback = function(v) Config.Backstop = v end,
})

DisplaySection:Paragraph({
    Title = 'updates are instant',
    Text = 'Solving is driven by the board changing, not by a timer: a reveal or a flag re-solves on the very next frame, and frames where nothing moved cost nothing at all. A tile also loses its marker the moment it stops being unknown, so flagging a bomb clears it immediately rather than on the next pass. The sweep above is only a safety net for a change that somehow raised no event, which is why it can sit at a second or more.',
})

DisplaySection:Paragraph({
    Title = 'the game watches for this',
    Text = 'It counts tiles coloured exactly pure green or pure red once a second and reports the total to the server as a "Color" message - a detector aimed at solver scripts that repaint tiles. Nothing here writes a tile\'s own colour, so it sees nothing, and the pickers refuse those two exact values anyway. Worth knowing before switching to any method that tints the tile itself.',
})

DisplaySection:Paragraph({
    Title = 'only certainties',
    Text = 'A tile lights up only when the surrounding numbers prove it. Two exact passes run: single constraints first, then subset elimination between overlapping ones, which resolves the pairs simple logic cannot. Positions that genuinely need a guess stay dark rather than showing odds.',
})

local FlagSection = MainTab:Section({ Title = 'auto flag', Side = 'right' })

FlagSection:Toggle({
    Title = 'auto flag mines',
    Flag = 'ms_autoflag',
    Default = false,
    Callback = function(v)
        Config.AutoFlag = v
        if v then
            flaggedByUs = {}
            recoverToken()
        end
    end,
})

FlagSection:Dropdown({
    Title = 'method',
    Flag = 'ms_flag_method',
    Options = { 'Auto', 'Token', 'ClickDetector' },
    Default = 'Auto',
    Callback = function(v) Config.FlagMethod = v end,
})

FlagSection:Slider({
    Title = 'flag range',
    Flag = 'ms_flag_range',
    Min = 4, Max = 200, Increment = 2, Default = 16,
    Suffix = ' studs',
    Callback = function(v) Config.FlagRange = v end,
})

FlagSection:Slider({
    Title = 'delay between flags',
    Flag = 'ms_flag_delay',
    Min = 0.02, Max = 0.5, Increment = 0.02, Default = 0.06,
    Suffix = 's',
    Callback = function(v) Config.FlagDelay = v end,
})

FlagSection:Button({
    Title = 'find flag token',
    Callback = function()
        recoverToken()
        Centrl:Notify({
            Title = 'minesweeper',
            Content = 'Token: ' .. Stats.Token,
            Type = flagToken and 'success' or 'warning',
            Duration = 5,
        })
    end,
})

FlagSection:Paragraph({
    Title = 'why flags need a token',
    Text = 'The game reads a value out of workspace.Salasana at startup and then destroys it, and every PlaceFlag call has to include it - which is why firing the remote blind does nothing. If the script loads before that happens the value is read directly; otherwise it is recovered from the upvalues of the handler the game connected. ClickDetector mode instead fires the game\'s own detector and lets its handler supply the token, which only exists on touch devices.',
})

local StatusSection = MainTab:Section({ Title = 'status', Side = 'left' })

local boardLabel = StatusSection:Label({ Title = 'board: --' })
local countLabel = StatusSection:Label({ Title = 'revealed 0 / unknown 0 / flagged 0' })
local resultLabel = StatusSection:Label({ Title = 'safe 0 / mines 0' })
local perfLabel = StatusSection:Label({ Title = 'solve: --' })
local tokenLabel = StatusSection:Label({ Title = 'token: --' })

StatusSection:Button({
    Title = 'rescan board',
    Callback = function()
        boardReady = false
        for part in pairs(visuals) do clearVisual(part) end
        classification, flaggedByUs = {}, {}
        dirty, dirtyCount = {}, 0
    end,
})

StatusSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
        for part in pairs(visuals) do clearVisual(part) end
        Centrl:Unload()
    end,
})

task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            boardLabel:Set(('board: %s (%.1f neighbours avg)'):format(Stats.Status, Stats.Neighbours))
            countLabel:Set(('revealed %d / unknown %d / flagged %d'):format(Stats.Revealed, Stats.Unknown, Stats.Flagged))
            resultLabel:Set(('safe %d / mines %d'):format(Stats.Safe, Stats.Mines))
            if Stats.LastSolve > 0 then
                perfLabel:Set(('solve: %.2f ms over %d changed'):format(Stats.LastSolve, Stats.Changed))
            else
                perfLabel:Set('solve: --')
            end
            tokenLabel:Set('token: ' .. tostring(Stats.Token))
        end)
    end
end)

Window:Load()

Centrl:Notify({
    Title = 'minesweeper',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

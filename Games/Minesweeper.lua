--// Minesweeper -------------------------------------------------------------------------
-- place 7871169780. Rewritten on Ui3.
--
-- How the game works (as the client sees it):
--   Board   workspace.Flag.Parts, one Part per tile, laid out on a grid with gaps.
--   Number  a revealed tile has part.NumberGui.TextLabel; empty text means 0.
--   Flag    an object carrying a UserId attribute (who placed it): the tile
--           itself, a child, a grandchild, or a model lying on the tile.
--   Mines   never replicated: the server reveals a tile when it's touched.
--           Everything here comes from the numbers the client already draws.
--   Flags   PlaceFlag:FireServer(part, token, true) in
--           ReplicatedStorage.Events.FlagEvents. The token is read from
--           workspace.Salasana at startup and then destroyed, so it's taken
--           from there if still present, else from the upvalues of the game's
--           own handler; touch devices also get a ClickDetector whose handler
--           sends the token itself.
--   Watch   the game counts tiles coloured exactly pure green or pure red and
--           reports it; nothing here recolours a tile, and the colour pickers
--           never hand out those two exact colours.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

-- A second run retires the first.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__MinesweeperUnload then
    pcall(Genv.__MinesweeperUnload)
end
Genv.__MinesweeperRun = (Genv.__MinesweeperRun or 0) + 1
local RUN = Genv.__MinesweeperRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__MinesweeperRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
local Options = Library.Options
if not alive() then
    return
end

local Settings = {
    -- markers
    ShowSafe = true, SafeMethod = "Highlight", SafeColor = Color3.fromRGB(70, 170, 255),
    ShowMines = true, MineMethod = "Highlight", MineColor = Color3.fromRGB(255, 70, 70),
    ShowWrongFlags = true, WrongFlagColor = Color3.fromRGB(255, 150, 0),
    ShowChances = false, ShowBestGuess = false, GuessColor = Color3.fromRGB(255, 225, 90),
    Transparency = 0.5,
    -- solver
    DeepThink = true, DeepLimit = 18, DeepCap = 30000, Backstop = 1,
    -- auto
    AutoFlag = false, FlagMethod = "Auto", FlagRange = 30, FlagDelay = 0.05,
    StepSafe = false, StepMethod = "Teleport", StepRange = 60, StepDelay = 0.15,
}

local Stats = {
    Tiles = 0, Revealed = 0, Unknown = 0, Flagged = 0, Safe = 0, Mines = 0, WrongFlags = 0,
    SolveMs = 0, Status = "waiting for the board", Token = "not looked for yet", Neighbours = 0,
}

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[Minesweeper] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Minesweeper", Description = text, Time = seconds or 3 })
end
local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- The game reports tiles painted exactly pure green or pure red; no colour
-- handed out here is ever exactly one of those.
local function guardColor(c)
    local r, g, b = math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)
    if (r == 0 and g == 255 and b == 0) or (r == 255 and g == 0 and b == 0) then
        return Color3.fromRGB(math.max(r - 6, 0) + (r == 0 and 6 or 0), math.max(g - 6, 0) + (g == 0 and 6 or 0), b + 6)
    end
    return c
end

--// Board \\--
-- Tiles are matched to neighbours by distance on a spatial hash sized to the
-- board's own pitch (the gap between tiles makes size-based indexing put
-- every tile in its own cell).
local Board = { tiles = {}, list = {}, pitch = nil, folder = nil, ready = false }
local OURS = "MSW_" -- prefix on everything this script parents to a tile

local function boardFolder()
    local model = Workspace:FindFirstChild("Flag")
    return model and model:FindFirstChild("Parts")
end

local function carriesUserId(inst)
    return inst:GetAttribute("UserId") ~= nil
end

-- Flags lying on a tile rather than parented to it, found once per board.
local Loose = {}
local function findLooseFlags()
    table.clear(Loose)
    local pitch = Board.pitch
    if not pitch or #Board.list == 0 then
        return
    end
    local byCell = {}
    for _, t in Board.list do
        byCell[t.key] = t
    end
    local budget = 8000
    for _, inst in Workspace:GetDescendants() do
        budget -= 1
        if budget <= 0 then
            break
        end
        if (inst:IsA("BasePart") or inst:IsA("Model")) and not Board.tiles[inst] and carriesUserId(inst) then
            local ok, pos = pcall(function()
                return inst:IsA("Model") and inst:GetPivot().Position or inst.Position
            end)
            if ok and pos then
                local t = byCell[("%d_%d"):format(math.floor(pos.X / pitch + 0.5), math.floor(pos.Z / pitch + 0.5))]
                if t then
                    Loose[t.part] = true
                end
            end
        end
    end
end

local function readFlag(part)
    if carriesUserId(part) or Loose[part] then
        return true
    end
    for _, child in part:GetChildren() do
        if child.Name:sub(1, #OURS) ~= OURS then
            if carriesUserId(child) then
                return true
            end
            for _, sub in child:GetChildren() do
                if carriesUserId(sub) then
                    return true
                end
            end
        end
    end
    return false
end

local function readNumber(part)
    local gui = part:FindFirstChild("NumberGui")
    if not gui then
        return nil
    end
    local label = gui:FindFirstChild("TextLabel") or gui:FindFirstChildWhichIsA("TextLabel", true)
    if not label then
        return nil
    end
    local text = label.Text
    if text == nil or text == "" then
        return 0
    end
    return tonumber(text)
end

local function readTile(t)
    if readFlag(t.part) then
        return "flagged", nil
    end
    local n = readNumber(t.part)
    if n then
        return "revealed", n
    end
    return "unknown", nil
end

local function buildBoard()
    local folder = boardFolder()
    if not folder then
        return false
    end
    local parts = {}
    for _, p in folder:GetChildren() do
        if p:IsA("BasePart") then
            table.insert(parts, p)
        end
    end
    if #parts == 0 then
        return false
    end
    -- Pitch: the smallest gap between tile centres, from a sample.
    local pitch = math.huge
    local sample = math.min(#parts, 200)
    for i = 1, sample do
        for j = i + 1, sample do
            local d = (parts[i].Position - parts[j].Position).Magnitude
            if d > 0.05 and d < pitch then
                pitch = d
            end
        end
    end
    if pitch == math.huge then
        pitch = math.max(parts[1].Size.X, 1)
    end
    local tiles, list, buckets = {}, {}, {}
    for _, part in parts do
        local gx = math.floor(part.Position.X / pitch + 0.5)
        local gz = math.floor(part.Position.Z / pitch + 0.5)
        local t = { part = part, gx = gx, gz = gz, key = ("%d_%d"):format(gx, gz), state = "unknown", number = nil, near = {} }
        tiles[part] = t
        table.insert(list, t)
        buckets[t.key] = buckets[t.key] or {}
        table.insert(buckets[t.key], t)
    end
    local reach, links = pitch * 1.6, 0
    for _, t in list do
        for dx = -1, 1 do
            for dz = -1, 1 do
                for _, o in buckets[("%d_%d"):format(t.gx + dx, t.gz + dz)] or {} do
                    if o ~= t and (o.part.Position - t.part.Position).Magnitude <= reach then
                        table.insert(t.near, o)
                        links += 1
                    end
                end
            end
        end
    end
    Board.tiles, Board.list, Board.pitch, Board.folder = tiles, list, pitch, folder
    Stats.Tiles = #list
    Stats.Neighbours = #list > 0 and links / #list or 0
    findLooseFlags()
    for _, t in list do
        t.state, t.number = readTile(t)
    end
    return true
end

--// Solver \\--
-- Constraints: each revealed number with unknown neighbours says "exactly
-- `need` mines among these". Three exact passes, repeated until nothing new
-- turns up:
--   1. a number already satisfied frees the rest; one needing every unknown
--      mines them all;
--   2. subset elimination between overlapping numbers;
--   3. (better thinking) every mine arrangement of each connected clump of
--      unknowns: a mine in all of them is a mine, safe in all of them is
--      safe, and the share of arrangements with a mine is a real chance.
-- A wrong flag shows up when the same solve, with flags opened back up,
-- proves a flagged tile safe.
local Result = { class = {}, chance = {}, wrong = {}, guess = nil }

local function constraints(treatFlagsOpen, known)
    local out = {}
    for _, t in Board.list do
        if t.state == "revealed" and t.number then
            local unknowns, mines = {}, 0
            for _, n in t.near do
                local kind = known[n]
                if kind == "mine" then
                    mines += 1
                elseif kind == "safe" then
                    -- settled, not part of the constraint
                elseif n.state == "unknown" or (treatFlagsOpen and n.state == "flagged") then
                    table.insert(unknowns, n)
                elseif n.state == "flagged" then
                    mines += 1
                end
            end
            local need = t.number - mines
            if #unknowns > 0 and need >= 0 and need <= #unknowns then
                table.insert(out, { cells = unknowns, need = need })
            end
        end
    end
    return out
end

local function solve(treatFlagsOpen)
    local known = {} -- tile -> "safe" | "mine"
    local chance = {}
    local function set(t, kind)
        if known[t] == nil then
            known[t] = kind
            return true
        end
        return false
    end
    for _ = 1, 12 do
        local changed = false
        local cs = constraints(treatFlagsOpen, known)
        -- Pass 1.
        for _, c in cs do
            if c.need == 0 then
                for _, u in c.cells do
                    changed = set(u, "safe") or changed
                end
            elseif c.need == #c.cells then
                for _, u in c.cells do
                    changed = set(u, "mine") or changed
                end
            end
        end
        -- Pass 2: only between constraints that share a tile.
        local byTile = {}
        for _, c in cs do
            for _, u in c.cells do
                byTile[u] = byTile[u] or {}
                table.insert(byTile[u], c)
            end
        end
        for _, a in cs do
            local inA = {}
            for _, u in a.cells do
                inA[u] = true
            end
            local seen = {}
            for _, u in a.cells do
                for _, b in byTile[u] do
                    if b ~= a and not seen[b] and #b.cells > #a.cells then
                        seen[b] = true
                        local shared = 0
                        for _, v in b.cells do
                            if inA[v] then
                                shared += 1
                            end
                        end
                        if shared == #a.cells then
                            local extra, mines = #b.cells - #a.cells, b.need - a.need
                            if mines == 0 or mines == extra then
                                for _, v in b.cells do
                                    if not inA[v] then
                                        changed = set(v, mines == 0 and "safe" or "mine") or changed
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        -- Pass 3 (and chances): clumps of linked unknowns, every arrangement.
        if (Settings.DeepThink or Settings.ShowChances or Settings.ShowBestGuess) and not changed then
            cs = constraints(treatFlagsOpen, known)
            local parent = {}
            local function find(x)
                while parent[x] ~= x do
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                end
                return x
            end
            for _, c in cs do
                for _, u in c.cells do
                    parent[u] = parent[u] or u
                end
                for i = 2, #c.cells do
                    local a, b = find(c.cells[1]), find(c.cells[i])
                    if a ~= b then
                        parent[a] = b
                    end
                end
            end
            local clumps = {}
            for u in parent do
                local r = find(u)
                clumps[r] = clumps[r] or {}
                table.insert(clumps[r], u)
            end
            for _, clump in clumps do
                if #clump <= Settings.DeepLimit then
                    local index = {}
                    for i, u in clump do
                        index[u] = i
                    end
                    local local_cs = {}
                    for _, c in cs do
                        if index[c.cells[1]] then
                            local idx = {}
                            for _, u in c.cells do
                                table.insert(idx, index[u])
                            end
                            table.insert(local_cs, { idx = idx, need = c.need })
                        end
                    end
                    -- Which constraints each cell is in, so a check only looks at those.
                    local of = {}
                    for ci, c in local_cs do
                        for _, i in c.idx do
                            of[i] = of[i] or {}
                            table.insert(of[i], ci)
                        end
                    end
                    local n, assign, mineIn, total = #clump, {}, table.create(#clump, 0), 0
                    local function ok(pos)
                        for _, ci in of[pos] or {} do
                            local c = local_cs[ci]
                            local mines, open = 0, 0
                            for _, i in c.idx do
                                if i <= pos then
                                    if assign[i] then
                                        mines += 1
                                    end
                                else
                                    open += 1
                                end
                            end
                            if mines > c.need or mines + open < c.need then
                                return false
                            end
                        end
                        return true
                    end
                    local function walk(pos)
                        if total > Settings.DeepCap then
                            return
                        end
                        if pos > n then
                            total += 1
                            for i = 1, n do
                                if assign[i] then
                                    mineIn[i] += 1
                                end
                            end
                            return
                        end
                        assign[pos] = false
                        if ok(pos) then
                            walk(pos + 1)
                        end
                        assign[pos] = true
                        if ok(pos) then
                            walk(pos + 1)
                        end
                        assign[pos] = nil
                    end
                    walk(1)
                    if total > 0 and total <= Settings.DeepCap then
                        for i, u in clump do
                            if mineIn[i] == total then
                                if Settings.DeepThink then
                                    changed = set(u, "mine") or changed
                                end
                            elseif mineIn[i] == 0 then
                                if Settings.DeepThink then
                                    changed = set(u, "safe") or changed
                                end
                            else
                                chance[u] = mineIn[i] / total
                            end
                        end
                    end
                end
            end
        end
        if not changed then
            break
        end
    end
    return known, chance
end

local Solve = { queued = true, lastCost = 0, lastAt = 0 }
local function requestSolve()
    Solve.queued = true
end

local function runSolve()
    local t0 = os.clock()
    local known, chance = solve(false)
    local class = {}
    local safe, mines = 0, 0
    for t, kind in known do
        if t.state == "unknown" then
            class[t.part] = kind
            if kind == "safe" then
                safe += 1
            else
                mines += 1
            end
        end
    end
    local wrong = {}
    if Settings.ShowWrongFlags then
        local reopened = solve(true)
        for t, kind in reopened do
            if t.state == "flagged" and kind == "safe" then
                wrong[t.part] = true
            end
        end
    end
    local chances, guess, best = {}, nil, nil
    for t, p in chance do
        if t.state == "unknown" and not class[t.part] then
            chances[t.part] = p
            if not best or p < best then
                guess, best = t.part, p
            end
        end
    end
    -- A guess is only worth showing when there's nothing proven to open.
    if safe > 0 then
        guess = nil
    end
    Result.class, Result.chance, Result.wrong, Result.guess = class, chances, wrong, guess
    Stats.Safe, Stats.Mines = safe, mines
    local n = 0
    for _ in wrong do
        n += 1
    end
    Stats.WrongFlags = n
    local cost = os.clock() - t0
    Stats.SolveMs = cost * 1000
    -- A heavy solve waits about its own length before the next one.
    Solve.lastCost = math.clamp(cost - 0.004, 0, 0.15)
    Solve.lastAt = os.clock()
end

--// Markers \\--
local METHODS = { "Highlight", "SelectionBox", "BoxAdornment", "SphereAdornment", "SurfaceGui", "Billboard", "PointLight", "Neon Overlay" }
local Marks = {} -- part -> { kind, method, objects }
local ChanceTags = {} -- part -> BillboardGui

local function makeMarker(part, method, color)
    local made = {}
    local function add(inst)
        inst.Name = OURS .. inst.ClassName
        table.insert(made, inst)
        return inst
    end
    local tr = Settings.Transparency
    if method == "Highlight" then
        local h = add(Instance.new("Highlight"))
        h.FillColor, h.OutlineColor, h.FillTransparency, h.OutlineTransparency = color, color, tr, 0
        h.Adornee = part
        h.Parent = part
    elseif method == "SelectionBox" then
        local b = add(Instance.new("SelectionBox"))
        b.Color3, b.SurfaceColor3, b.LineThickness, b.SurfaceTransparency = color, color, 0.05, tr
        b.Adornee = part
        b.Parent = part
    elseif method == "BoxAdornment" then
        local b = add(Instance.new("BoxHandleAdornment"))
        b.Size, b.Color3, b.Transparency, b.AlwaysOnTop, b.ZIndex = part.Size * 1.02, color, tr, true, 1
        b.Adornee = part
        b.Parent = part
    elseif method == "SphereAdornment" then
        local s = add(Instance.new("SphereHandleAdornment"))
        s.Radius, s.Color3, s.Transparency, s.AlwaysOnTop = math.max(part.Size.X, part.Size.Z) / 2, color, tr, true
        s.Adornee = part
        s.Parent = part
    elseif method == "SurfaceGui" or method == "Billboard" then
        local g
        if method == "SurfaceGui" then
            g = add(Instance.new("SurfaceGui"))
            g.Face = Enum.NormalId.Top
        else
            g = add(Instance.new("BillboardGui"))
            g.Size = UDim2.fromOffset(28, 28)
        end
        g.AlwaysOnTop = true
        g.Adornee = part
        g.Parent = part
        local f = Instance.new("Frame")
        f.Size, f.BackgroundColor3, f.BackgroundTransparency, f.BorderSizePixel = UDim2.fromScale(1, 1), color, tr, 0
        f.Parent = g
    elseif method == "PointLight" then
        local l = add(Instance.new("PointLight"))
        l.Color, l.Brightness, l.Range = color, 3, 8
        l.Parent = part
    elseif method == "Neon Overlay" then
        local p = add(Instance.new("Part"))
        p.Size, p.CFrame, p.Anchored = part.Size * 1.02, part.CFrame, true
        p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
        p.Material, p.Color, p.Transparency = Enum.Material.Neon, color, tr
        p.Parent = part
    end
    return made
end

local function recolor(objects, color)
    local tr = Settings.Transparency
    for _, inst in objects do
        pcall(function()
            if inst:IsA("Highlight") then
                inst.FillColor, inst.OutlineColor, inst.FillTransparency = color, color, tr
            elseif inst:IsA("SelectionBox") then
                inst.Color3, inst.SurfaceColor3, inst.SurfaceTransparency = color, color, tr
            elseif inst:IsA("HandleAdornment") then
                inst.Color3, inst.Transparency = color, tr
            elseif inst:IsA("BasePart") then
                inst.Color, inst.Transparency = color, tr
            elseif inst:IsA("PointLight") then
                inst.Color = color
            elseif inst:IsA("LayerCollector") then
                local f = inst:FindFirstChildWhichIsA("Frame")
                if f then
                    f.BackgroundColor3, f.BackgroundTransparency = color, tr
                end
            end
        end)
    end
end

local function unmark(part)
    local m = Marks[part]
    if m then
        for _, inst in m.objects do
            pcall(inst.Destroy, inst)
        end
        Marks[part] = nil
    end
end

local function styleOf(kind)
    if kind == "safe" then
        return Settings.ShowSafe, Settings.SafeMethod, Settings.SafeColor
    elseif kind == "mine" then
        return Settings.ShowMines, Settings.MineMethod, Settings.MineColor
    elseif kind == "wrong" then
        return Settings.ShowWrongFlags, "Highlight", Settings.WrongFlagColor
    elseif kind == "guess" then
        return Settings.ShowBestGuess, "Highlight", Settings.GuessColor
    end
end

local function mark(part, kind)
    local show, method, color = styleOf(kind)
    if not show then
        unmark(part)
        return
    end
    local m = Marks[part]
    if m and m.kind == kind and m.method == method then
        recolor(m.objects, color)
        return
    end
    unmark(part)
    Marks[part] = { kind = kind, method = method, objects = makeMarker(part, method, color) }
end

local function drawChances()
    local seen = {}
    if Settings.ShowChances then
        for part, p in Result.chance do
            seen[part] = true
            local gui = ChanceTags[part]
            if not gui then
                gui = Instance.new("BillboardGui")
                gui.Name = OURS .. "Chance"
                gui.Adornee, gui.Size, gui.AlwaysOnTop = part, UDim2.fromOffset(46, 20), true
                local text = Instance.new("TextLabel")
                text.Name = "T"
                text.BackgroundTransparency, text.Size = 1, UDim2.fromScale(1, 1)
                text.Font, text.TextSize, text.TextStrokeTransparency = Enum.Font.GothamBold, 13, 0.4
                text.Parent = gui
                gui.Parent = part
                ChanceTags[part] = gui
            end
            local label = gui:FindFirstChild("T")
            if label then
                label.Text = math.floor(p * 100 + 0.5) .. "%"
                label.TextColor3 = Color3.fromRGB(math.floor(60 + 195 * p), math.floor(220 - 160 * p), 80)
            end
        end
    end
    for part, gui in ChanceTags do
        if not seen[part] then
            pcall(gui.Destroy, gui)
            ChanceTags[part] = nil
        end
    end
end

-- Draws the current result: only what changed is touched.
local function draw()
    local want = {}
    for part, kind in Result.class do
        want[part] = kind
    end
    for part in Result.wrong do
        want[part] = "wrong"
    end
    if Result.guess and not want[Result.guess] then
        want[Result.guess] = "guess"
    end
    for part, kind in want do
        mark(part, kind)
    end
    for part in Marks do
        if not want[part] then
            unmark(part)
        end
    end
    drawChances()
end

local function clearAll()
    for part in Marks do
        unmark(part)
    end
    for part, gui in ChanceTags do
        pcall(gui.Destroy, gui)
        ChanceTags[part] = nil
    end
end

--// Flags \\--
local Flagging = { remote = nil, token = nil, ours = {} }

local function placeFlagRemote()
    local events = ReplicatedStorage:FindFirstChild("Events")
    local folder = events and events:FindFirstChild("FlagEvents")
    return folder and folder:FindFirstChild("PlaceFlag")
end

local function findToken()
    Flagging.remote = Flagging.remote or placeFlagRemote()
    local salasana = Workspace:FindFirstChild("Salasana")
    if salasana and salasana:IsA("ValueBase") then
        local ok, v = pcall(function()
            return salasana.Value
        end)
        if ok and typeof(v) == "number" and v ~= 0 then
            Flagging.token = v
            Stats.Token = "read from Salasana"
            return true
        end
    end
    if not Flagging.remote then
        Stats.Token = "no PlaceFlag remote"
        return false
    end
    if typeof(getgc) ~= "function" or typeof(debug) ~= "table" or typeof(debug.getupvalues) ~= "function" then
        Stats.Token = "this executor has no getgc"
        return false
    end
    -- The handler that holds the PlaceFlag remote also holds the token.
    local found
    pcall(function()
        for _, fn in getgc() do
            if type(fn) == "function" then
                local ok, ups = pcall(debug.getupvalues, fn)
                if ok and type(ups) == "table" then
                    local hasRemote, number = false, nil
                    for _, up in ups do
                        if up == Flagging.remote then
                            hasRemote = true
                        elseif typeof(up) == "number" and up ~= 0 then
                            number = up
                        end
                    end
                    if hasRemote and number then
                        found = number
                        break
                    end
                end
            end
        end
    end)
    if found then
        Flagging.token = found
        Stats.Token = "taken from the game's handler"
        return true
    end
    Stats.Token = "not found"
    return false
end

local function placeFlag(part)
    local method = Settings.FlagMethod
    if method ~= "ClickDetector" then
        if not Flagging.token then
            findToken()
        end
        if Flagging.token and Flagging.remote then
            if pcall(Flagging.remote.FireServer, Flagging.remote, part, Flagging.token, true) then
                return true
            end
        end
        if method == "Token" then
            return false
        end
    end
    local detector = part:FindFirstChildOfClass("ClickDetector")
    if detector and typeof(fireclickdetector) == "function" then
        return pcall(fireclickdetector, detector)
    end
    return false
end

local function flagPass()
    if not Settings.AutoFlag then
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    local queue = {}
    for part, kind in Result.class do
        local t = Board.tiles[part]
        if kind == "mine" and t and t.state == "unknown" and not Flagging.ours[part] then
            local d = (part.Position - hrp.Position).Magnitude
            if d <= Settings.FlagRange then
                table.insert(queue, { part = part, d = d })
            end
        end
    end
    table.sort(queue, function(a, b)
        return a.d < b.d
    end)
    for _, q in queue do
        if not alive() or not Settings.AutoFlag then
            break
        end
        if q.part.Parent and not readFlag(q.part) then
            Flagging.ours[q.part] = true
            placeFlag(q.part)
            task.wait(Settings.FlagDelay)
        end
    end
end

--// Stepping on safe tiles \\--
-- A tile opens when you touch it; proven safe ones are stepped on, nearest
-- first, by teleport or by walking.
local Stepping = { tried = {} }
local function stepPass()
    if not Settings.StepSafe then
        return
    end
    local hrp = rootPart()
    local hum = hrp and hrp.Parent:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then
        return
    end
    local best, bestD
    for part, kind in Result.class do
        local t = Board.tiles[part]
        if kind == "safe" and t and t.state == "unknown" and (Stepping.tried[part] or 0) < os.clock() then
            local d = (part.Position - hrp.Position).Magnitude
            if d <= Settings.StepRange and (not bestD or d < bestD) then
                best, bestD = part, d
            end
        end
    end
    if not best then
        return
    end
    Stepping.tried[best] = os.clock() + 3
    local top = best.Position + Vector3.new(0, best.Size.Y / 2 + 3, 0)
    if Settings.StepMethod == "Teleport" then
        hrp.CFrame = CFrame.new(top) * hrp.CFrame.Rotation
        hrp.AssemblyLinearVelocity = Vector3.zero
        task.wait(Settings.StepDelay)
    else
        hum:MoveTo(best.Position)
        local t0 = os.clock()
        repeat
            task.wait(0.05)
        until not alive() or (Board.tiles[best] and Board.tiles[best].state ~= "unknown") or os.clock() - t0 > 3
    end
end

--// Watching the board \\--
local function refresh(t)
    if not t.part.Parent then
        return
    end
    local state, number = readTile(t)
    if state ~= t.state or number ~= t.number then
        t.state, t.number = state, number
        if state ~= "unknown" then
            unmark(t.part)
            Result.class[t.part] = nil
        end
        requestSolve()
    end
end

local function counts()
    local r, u, f = 0, 0, 0
    for _, t in Board.list do
        if t.state == "revealed" then
            r += 1
        elseif t.state == "flagged" then
            f += 1
        else
            u += 1
        end
    end
    Stats.Revealed, Stats.Unknown, Stats.Flagged = r, u, f
end

local BoardConns = {}
local function dropBoard(why)
    for _, c in BoardConns do
        pcall(c.Disconnect, c)
    end
    table.clear(BoardConns)
    clearAll()
    Result.class, Result.chance, Result.wrong, Result.guess = {}, {}, {}, nil
    table.clear(Flagging.ours)
    table.clear(Stepping.tried)
    Board.ready = false
    Stats.Status = why
end

local function watchBoard()
    local folder = Board.folder
    local function tileOf(inst)
        local part = inst:FindFirstAncestorWhichIsA("BasePart")
        return part and Board.tiles[part]
    end
    table.insert(BoardConns, folder.DescendantAdded:Connect(function(d)
        local t = tileOf(d)
        if t then
            refresh(t)
        end
    end))
    table.insert(BoardConns, folder.DescendantRemoving:Connect(function(d)
        local t = tileOf(d)
        if t then
            task.defer(refresh, t)
        end
    end))
    table.insert(BoardConns, folder.ChildRemoved:Connect(function()
        dropBoard("the board changed, reading it again")
    end))
    table.insert(BoardConns, folder.ChildAdded:Connect(function()
        dropBoard("the board changed, reading it again")
    end))
end

-- Finds the board, then keeps a slow safety sweep going (events drive the rest).
loop(function()
    return Settings.Backstop
end, function()
    if not Board.ready then
        if buildBoard() then
            Board.ready = true
            Stats.Status = ("%d tiles"):format(#Board.list)
            watchBoard()
            findToken()
            requestSolve()
        else
            Stats.Status = "waiting for the board"
        end
        return
    end
    if not Board.folder or not Board.folder.Parent then
        dropBoard("board gone, looking again")
        return
    end
    for _, t in Board.list do
        if t.state ~= "revealed" then
            refresh(t)
        end
    end
    counts()
end)

-- Solves on the frame after the board moves.
bind(RunService.Heartbeat, function()
    if not alive() or not Board.ready or not Solve.queued then
        return
    end
    if os.clock() - Solve.lastAt < Solve.lastCost then
        return
    end
    Solve.queued = false
    local ok, err = pcall(runSolve)
    if not ok then
        warn("[Minesweeper] solve: " .. tostring(err))
    end
    pcall(draw)
    counts()
end)

loop(0.1, function()
    if Board.ready then
        flagPass()
    end
end)
loop(0.05, function()
    if Board.ready then
        stepPass()
    end
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Minesweeper",
    Footer = "dookie hub · Ui3",
    Icon = "grid-3x3",
    Size = UDim2.fromOffset(660, 520),
    ConfigFolder = "Ui3/Minesweeper",
})

local function redraw()
    pcall(draw)
end
local function resolve()
    requestSolve()
end
local function toggle(box, idx, text, key, tooltip, after)
    return box:AddToggle(idx, {
        Text = text, Default = Settings[key], Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
end
local function slider(box, idx, text, key, min, max, rounding, suffix, tooltip, after)
    return box:AddSlider(idx, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
end
local function choice(box, idx, text, key, values, tooltip, after)
    return box:AddDropdown(idx, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tooltip,
        Callback = function(v)
            Settings[key] = v or values[1]
            if after then
                after(v)
            end
        end,
    })
end
local function color(toggleObj, idx, title, key)
    toggleObj:AddColorPicker(idx, {
        Default = Settings[key], Title = title,
        Callback = function(c)
            Settings[key] = guardColor(c)
            redraw()
        end,
    })
end

-- Solver tab
do
    local Tab = Window:AddTab("Solver", "brain", "What the board proves")
    local StatusBox = Tab:AddLeftGroupbox("Board", "grid-3x3")
    local BoardLabel = StatusBox:AddLabel("...", true)
    local CountLabel = StatusBox:AddLabel("...", true)
    local ResultLabel = StatusBox:AddLabel("...", true)
    StatusBox:AddButton({
        Text = "Read the board again",
        Func = function()
            dropBoard("reading the board again")
        end,
    })

    local ThinkBox = Tab:AddRightGroupbox("Thinking", "cpu")
    toggle(ThinkBox, "DeepThink", "Better thinking", "DeepThink",
        "Works through every mine arrangement of each clump of unknown tiles: a mine in all of them is a mine, safe in all of them is safe. Finds everything the board proves", resolve)
    slider(ThinkBox, "DeepLimit", "Biggest clump", "DeepLimit", 8, 26, 0, " tiles",
        "Arrangements grow fast with clump size; bigger clumps are left to the simpler passes", resolve)
    slider(ThinkBox, "Backstop", "Safety sweep every", "Backstop", 0.25, 5, 2, " s",
        "Changes are picked up the moment they happen; this sweep only catches one that raised no event")
    ThinkBox:AddLabel("Only proven tiles get coloured. Chances and the best guess are a separate, honest statement: the share of valid arrangements with a mine there", true)
    local PerfLabel = ThinkBox:AddLabel("...", true)

    loop(0.25, function()
        BoardLabel:SetText(("Board: %s · %.1f neighbours each"):format(Stats.Status, Stats.Neighbours))
        CountLabel:SetText(("Revealed %d · unknown %d · flagged %d"):format(Stats.Revealed, Stats.Unknown, Stats.Flagged))
        ResultLabel:SetText(("Safe %d · mines %d%s"):format(Stats.Safe, Stats.Mines,
            Settings.ShowWrongFlags and (" · wrong flags %d"):format(Stats.WrongFlags) or ""))
        PerfLabel:SetText(("Last solve %.2f ms"):format(Stats.SolveMs))
    end)
end

-- Markers tab
do
    local Tab = Window:AddTab("Markers", "eye", "How proven tiles look")
    local SafeBox = Tab:AddLeftGroupbox("Safe tiles", "shield-check")
    color(toggle(SafeBox, "ShowSafe", "Show safe tiles", "ShowSafe", nil, redraw), "SafeColor", "Safe colour", "SafeColor")
    choice(SafeBox, "SafeMethod", "Look", "SafeMethod", METHODS, nil, redraw)

    local MineBox = Tab:AddRightGroupbox("Mines", "bomb")
    color(toggle(MineBox, "ShowMines", "Show mines", "ShowMines", nil, redraw), "MineColor", "Mine colour", "MineColor")
    choice(MineBox, "MineMethod", "Look", "MineMethod", METHODS, nil, redraw)

    local ExtraBox = Tab:AddLeftGroupbox("More", "sparkles")
    color(toggle(ExtraBox, "ShowWrongFlags", "Wrong flags", "ShowWrongFlags",
        "A flag on a tile the numbers prove safe. Every number around it counts it as a mine, so the area solves wrong until it comes off",
        resolve), "WrongFlagColor", "Wrong flag colour", "WrongFlagColor")
    toggle(ExtraBox, "ShowChances", "Chance on undecided tiles", "ShowChances",
        "The share of valid mine arrangements that put a mine on each tile nothing proves", resolve)
    color(toggle(ExtraBox, "ShowBestGuess", "Mark the best guess", "ShowBestGuess",
        "When nothing is proven, the undecided tile with the lowest chance of a mine", resolve), "GuessColor", "Guess colour", "GuessColor")

    local LookBox = Tab:AddRightGroupbox("Look", "palette")
    slider(LookBox, "Transparency", "Transparency", "Transparency", 0, 1, 2, nil, nil, redraw)
    LookBox:AddLabel("The game reports tiles painted exactly pure green or red. Nothing here paints a tile, and the colour pickers never give those two exact colours", true)
end

-- Auto tab
do
    local Tab = Window:AddTab("Auto", "zap", "Flagging and stepping")
    local FlagBox = Tab:AddLeftGroupbox("Auto flag", "flag")
    toggle(FlagBox, "AutoFlag", "Flag proven mines", "AutoFlag", "Flags every proven mine within range, nearest first", function(v)
        if v then
            table.clear(Flagging.ours)
            findToken()
        end
    end)
    choice(FlagBox, "FlagMethod", "Method", "FlagMethod", { "Auto", "Token", "ClickDetector" },
        "Token: the game's own flag request with the recovered token. ClickDetector: the game's detector (touch devices). Auto: token, else detector")
    slider(FlagBox, "FlagRange", "Range", "FlagRange", 4, 300, 0, " studs")
    slider(FlagBox, "FlagDelay", "Between flags", "FlagDelay", 0, 0.5, 2, " s")
    local TokenLabel = FlagBox:AddLabel("Token: ...", true)
    FlagBox:AddButton({
        Text = "Look for the token again",
        Func = function()
            Flagging.token = nil
            findToken()
            notify("Token: " .. Stats.Token, 4)
        end,
    })

    local StepBox = Tab:AddRightGroupbox("Step on safe tiles", "footprints")
    toggle(StepBox, "StepSafe", "Step on proven safe tiles", "StepSafe",
        "Opens proven safe tiles by stepping on them, nearest first. With auto flag this plays the board out as far as it can be proven")
    choice(StepBox, "StepMethod", "Move by", "StepMethod", { "Teleport", "Walk" })
    slider(StepBox, "StepRange", "Range", "StepRange", 8, 400, 0, " studs")
    slider(StepBox, "StepDelay", "Wait on each tile", "StepDelay", 0.05, 1, 2, " s")

    loop(0.5, function()
        TokenLabel:SetText("Token: " .. tostring(Stats.Token))
    end)
end

-- Unload
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for _, c in BoardConns do
        pcall(c.Disconnect, c)
    end
    clearAll()
end
Library:OnUnload(cleanup)
Genv.__MinesweeperUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded", 3)

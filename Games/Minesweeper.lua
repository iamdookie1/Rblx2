--// Minesweeper -------------------------------------------------------------------------
-- place 7871169780 (bLockerman's Minesweeper). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Board   workspace.Flag.Parts, one Part per tile on a grid with gaps. Infinite
--           boards keep adding and removing tiles, so the board here is kept up
--           tile by tile instead of being read again on every change.
--   Number  a revealed tile has part.NumberGui.TextLabel; empty text means 0.
--           "X" is a tile the game still lets you flag (not revealed).
--   Rules   ReplicatedStorage.Info.Settings: Mode picks which tiles a number
--           counts (Default, Cross, Wrap, Large, Deceiving, Cornerless, Corners,
--           Calculative, Knight); GridSize and MinePercent give the mine count,
--           which is also Info.Mines (an infinite board has Info.Mines.Tiles).
--   Flags   PlaceFlag:FireServer(part, token, true) in
--           ReplicatedStorage.Events.FlagEvents. The token is read from
--           workspace.Salasana by ReplicatedFirst.MouseControl, which then
--           destroys it; the game's click handlers keep it as an upvalue next to
--           ReplicatedStorage and the Parts folder (PC) or the tile (touch). The
--           game only flags within 32 studs, on the Playing team, and never in
--           a Flagless round.
--   Watch   the game counts tiles coloured exactly pure green or pure red and
--           reports it; nothing here recolours a tile and the colour pickers
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
    ShowSafe = true, SafeMethod = "BoxAdornment", SafeColor = Color3.fromRGB(70, 170, 255),
    ShowMines = true, MineMethod = "BoxAdornment", MineColor = Color3.fromRGB(255, 70, 70),
    ShowWrongFlags = true, WrongFlagColor = Color3.fromRGB(255, 150, 0),
    ShowChances = false, ShowBestGuess = false, GuessColor = Color3.fromRGB(255, 225, 90),
    Transparency = 0.5,
    -- overlay
    ShowOwners = false, NumberOverlay = "Challenges only", ShowFire = true,
    -- solver
    DeepThink = true, DeepLimit = 34, DeepCap = 150000, UseMineCount = true, Neighbours = "Auto",
    Backstop = 1, SliceMs = 4,
    -- auto
    AutoFlag = false, FlagMethod = "Auto", FlagRange = 30, FlagDelay = 0.05, FlagChase = false,
    StepSafe = false, StepMethod = "Teleport", StepRange = 60, StepDelay = 0.15,
    -- challenges
    NoBullets = false, StopConveyors = false, SolidTiles = false, SteadyBoard = false,
    AvoidDanger = true, LeaveDanger = false,
    -- game
    AntiAfk = false, VoteAlert = true, AutoVoteNo = false,
}

local Stats = {
    Tiles = 0, Revealed = 0, Unknown = 0, Flagged = 0, Safe = 0, Mines = 0, WrongFlags = 0,
    SolveMs = 0, Status = "waiting for the board", Token = "not looked for yet", Neighbours = 0,
    FlagNote = "", Rules = "Default", Global = "", Guess = nil, Interior = nil,
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

-- Presses one of the game's own buttons, so its own script keeps its state.
local function fireButton(button)
    if not button then
        return false
    end
    if typeof(getconnections) == "function" then
        local ok, conns = pcall(getconnections, button.Activated)
        if ok and type(conns) == "table" and #conns > 0 then
            for _, c in conns do
                if not pcall(function()
                    c:Fire()
                end) then
                    pcall(function()
                        c.Function()
                    end)
                end
            end
            return true
        end
    end
    if typeof(firesignal) == "function" then
        return (pcall(firesignal, button.Activated))
    end
    return false
end

--// The game's state \\--
local MODES = { "Default", "Cross", "Wrap", "Large", "Deceiving", "Cornerless", "Corners", "Calculative", "Knight" }
local CHALLENGES = { "Disappearance", "Confusion", "Conveyors", "Scorching", "Vigilant", "Phasing", "Malfunction", "Bullets", "Amoeba" }
local Game = {}
do
    function Game.info()
        return ReplicatedStorage:FindFirstChild("Info")
    end
    function Game.value(name)
        local info = Game.info()
        local v = info and info:FindFirstChild(name)
        if v and v:IsA("ValueBase") then
            local ok, x = pcall(function()
                return v.Value
            end)
            if ok then
                return x
            end
        end
        return nil
    end
    function Game.setting(name)
        local info = Game.info()
        local s = info and info:FindFirstChild("Settings")
        return s and s:GetAttribute(name)
    end
    function Game.challenge(name)
        if name == "Bullets" and Game.value("Bullets") == true then
            return true
        end
        local info = Game.info()
        local c = info and info:FindFirstChild("ChallengeSettings")
        return c ~= nil and c:GetAttribute(name) == true
    end
    function Game.activeChallenges()
        local out = {}
        for _, name in CHALLENGES do
            if Game.challenge(name) then
                table.insert(out, name)
            end
        end
        return out
    end
    function Game.mode()
        local m = tonumber(Game.setting("Mode"))
        return (m and MODES[m]) or "Default"
    end
    function Game.infinite()
        local info = Game.info()
        local mines = info and info:FindFirstChild("Mines")
        return mines ~= nil and mines:FindFirstChild("Tiles") ~= nil
    end
    -- The whole board's mine count, when it means one.
    function Game.totalMines()
        if Game.infinite() then
            return nil, "infinite board"
        end
        if tonumber(Game.setting("Generation")) == 2 then
            return nil, "progressive mines"
        end
        local v = Game.value("Mines")
        if typeof(v) ~= "number" then
            return nil, "no mine count"
        end
        return v
    end
    function Game.playing()
        local team = LocalPlayer.Team
        return team ~= nil and team.Name == "Playing"
    end
    function Game.flagless()
        return Game.value("Flagless") == true
    end
    function Game.event(folder, name)
        local events = ReplicatedStorage:FindFirstChild("Events")
        local f = events and events:FindFirstChild(folder)
        return f and f:FindFirstChild(name)
    end
    function Game.timer()
        local info = Game.info()
        local t = info and info:FindFirstChild("Timer")
        if not t then
            return nil
        end
        local start = t:GetAttribute("StartTime")
        if start then
            return Workspace:GetServerTimeNow() - start
        end
        return t.Value
    end
end

--// Neighbour shapes \\--
local Shapes = {}
do
    local function box(r, keep)
        local out = {}
        for dx = -r, r do
            for dz = -r, r do
                if (dx ~= 0 or dz ~= 0) and keep(dx, dz) then
                    table.insert(out, { dx, dz })
                end
            end
        end
        return out
    end
    Shapes.Default = box(1, function()
        return true
    end)
    Shapes.Cornerless = box(1, function(dx, dz)
        return dx == 0 or dz == 0
    end)
    Shapes.Corners = box(1, function(dx, dz)
        return dx ~= 0 and dz ~= 0
    end)
    Shapes.Cross = box(2, function(dx, dz)
        return dx == 0 or dz == 0
    end)
    Shapes.Large = box(2, function()
        return true
    end)
    Shapes.Knight = box(2, function(dx, dz)
        return math.abs(dx * dz) == 2
    end)
end
local SHAPE_OF_MODE = {
    Default = "Default", Cross = "Cross", Wrap = "Default", Large = "Large", Deceiving = "Default",
    Cornerless = "Cornerless", Corners = "Corners", Calculative = "Default", Knight = "Knight",
}
local NEIGHBOUR_CHOICES = { "Auto", "Default", "Default + wrap", "Cornerless", "Corners", "Cross", "Large", "Knight" }

--// Number text \\--
-- Plain digits, or (Calculative) a small sum like "2+1" or "(9-3)/2".
local Parse = {}
function Parse.number(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(text)
    if n then
        return n
    end
    text = text:gsub("×", "*"):gsub("÷", "/"):gsub("x", "*")
    if text == "" or not text:match("^[%d%s%+%-%*/%^%(%)%.]+$") then
        return nil
    end
    local pos = 1
    local function skip()
        while text:sub(pos, pos) == " " do
            pos += 1
        end
    end
    local expr
    local function atom()
        skip()
        local c = text:sub(pos, pos)
        if c == "(" then
            pos += 1
            local v = expr()
            skip()
            if text:sub(pos, pos) ~= ")" then
                error("bracket")
            end
            pos += 1
            return v
        elseif c == "-" then
            pos += 1
            return -atom()
        end
        local s, e = text:find("^%d*%.?%d+", pos)
        if not s then
            error("number")
        end
        pos = e + 1
        return tonumber(text:sub(s, e))
    end
    local function power()
        local v = atom()
        skip()
        if text:sub(pos, pos) == "^" then
            pos += 1
            return v ^ power()
        end
        return v
    end
    local function term()
        local v = power()
        while true do
            skip()
            local c = text:sub(pos, pos)
            if c == "*" then
                pos += 1
                v *= power()
            elseif c == "/" then
                pos += 1
                v /= power()
            else
                return v
            end
        end
    end
    function expr()
        local v = term()
        while true do
            skip()
            local c = text:sub(pos, pos)
            if c == "+" then
                pos += 1
                v += term()
            elseif c == "-" then
                pos += 1
                v -= term()
            else
                return v
            end
        end
    end
    local ok, v = pcall(expr)
    skip()
    if not ok or pos <= #text or type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then
        return nil
    end
    local r = math.floor(v + 0.5)
    if math.abs(v - r) > 1e-9 then
        return nil
    end
    return r
end

--#solver
--// Solver \\--
-- Works only from the numbers: flags are never trusted (anyone can place a
-- wrong one), so a flagged tile is just another hidden tile and a flag the
-- numbers prove safe is a wrong flag.
--   1. a number already met frees its other tiles; one needing every hidden
--      tile mines them all;
--   2. subset elimination between overlapping numbers;
--   3. every mine arrangement of each connected clump of hidden tiles, counted
--      by how many mines it uses: a tile mined in all of them is a mine, in
--      none is safe;
--   4. with the board's mine count, the clumps and the tiles no number touches
--      are weighed together (arrangements x ways to place the leftover mines on
--      the untouched tiles), which gives the real chance on every tile and
--      proves whatever the count alone settles.
local Solver = {}
do
    local logFact = { [0] = 0 }
    local function lf(n)
        for i = #logFact + 1, n do
            logFact[i] = logFact[i - 1] + math.log(i)
        end
        return logFact[n]
    end
    local function logC(n, r)
        if r < 0 or r > n then
            return -math.huge
        end
        return lf(n) - lf(r) - lf(n - r)
    end
    Solver.logC = logC

    local function conv(a, b)
        local w, r = {}, {}
        for i = 1, #a.w + #b.w - 1 do
            w[i], r[i] = 0, false
        end
        for i, x in a.w do
            local ri = a.r[i]
            for j, y in b.w do
                local k = i + j - 1
                w[k] += x * y
                if ri and b.r[j] then
                    r[k] = true
                end
            end
        end
        local top = 0
        for _, x in w do
            if x > top then
                top = x
            end
        end
        if top > 0 then
            for i, x in w do
                w[i] = x / top
            end
        end
        return { w = w, r = r }
    end

    -- list: tiles; S[t]: "unknown"/"flagged"/"revealed"; N[t]: number or nil;
    -- near[t]: neighbour tiles. opt: deep, limit, cap, nodeCap, total, yield.
    function Solver.run(list, S, N, near, opt)
        local yield = opt.yield or function() end
        local known, chance = {}, {}
        local out = { known = known, chance = chance, contradiction = false, global = false, unresolved = 0 }
        local function hidden(t)
            local s = S[t]
            return s == "unknown" or s == "flagged"
        end
        local function set(t, kind)
            local k = known[t]
            if k == nil then
                known[t] = kind
                return true
            end
            if k ~= kind then
                out.contradiction = true
            end
            return false
        end
        local function constraints()
            local cs = {}
            for _, t in list do
                local n = N[t]
                if n and S[t] == "revealed" then
                    local cells, mines = {}, 0
                    for _, o in near[t] or {} do
                        if hidden(o) then
                            local k = known[o]
                            if k == "mine" then
                                mines += 1
                            elseif k == nil then
                                table.insert(cells, o)
                            end
                        end
                    end
                    local need = n - mines
                    if need < 0 or need > #cells then
                        out.contradiction, out.bad = true, t
                        return cs
                    end
                    if #cells > 0 then
                        table.insert(cs, { cells = cells, need = need })
                    end
                end
            end
            return cs
        end

        -- Every arrangement of each clump, by mine count.
        local function enumerate(cs)
            local parent = {}
            local function find(x)
                while parent[x] ~= x do
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                end
                return x
            end
            local consOf = {}
            for _, c in cs do
                for _, u in c.cells do
                    if parent[u] == nil then
                        parent[u] = u
                    end
                    consOf[u] = consOf[u] or {}
                    table.insert(consOf[u], c)
                end
                for i = 2, #c.cells do
                    local a, b = find(c.cells[1]), find(c.cells[i])
                    if a ~= b then
                        parent[a] = b
                    end
                end
            end
            local groups, order = {}, {}
            for _, c in cs do
                for _, u in c.cells do
                    local r = find(u)
                    if not groups[r] then
                        groups[r] = {}
                        table.insert(order, r)
                    end
                end
            end
            -- Cells in breadth-first order along shared numbers, so each number
            -- closes as early as possible and dead ends are cut early.
            local seenCell = {}
            for _, r in order do
                local g = groups[r]
                local queue, head = { r }, 1
                seenCell[r] = true
                while head <= #queue do
                    local u = queue[head]
                    head += 1
                    table.insert(g, u)
                    for _, c in consOf[u] do
                        for _, v in c.cells do
                            if not seenCell[v] then
                                seenCell[v] = true
                                table.insert(queue, v)
                            end
                        end
                    end
                end
            end
            local results, changed, ok = {}, false, true
            for _, r in order do
                local clump = groups[r]
                local n = #clump
                if n > opt.limit then
                    ok = false
                    out.unresolved += n
                    continue
                end
                local index = {}
                for i, u in clump do
                    index[u] = i
                end
                local needs, mineCt, openCt, of = {}, {}, {}, {}
                local seenC = {}
                for _, u in clump do
                    for _, c in consOf[u] do
                        if not seenC[c] then
                            seenC[c] = true
                            table.insert(needs, c.need)
                            local ci = #needs
                            mineCt[ci], openCt[ci] = 0, #c.cells
                            for _, v in c.cells do
                                local i = index[v]
                                of[i] = of[i] or {}
                                table.insert(of[i], ci)
                            end
                        end
                    end
                end
                local W = table.create(n + 1, 0)
                local M = {}
                for i = 1, n do
                    M[i] = table.create(n + 1, 0)
                end
                local assign, cur, nodes, sols, aborted = {}, 0, 0, 0, false
                local cap, nodeCap = opt.cap, opt.nodeCap or opt.cap * 25
                local function place(pos, mine)
                    local good = true
                    for _, ci in of[pos] do
                        openCt[ci] -= 1
                        if mine then
                            mineCt[ci] += 1
                        end
                        local need, m = needs[ci], mineCt[ci]
                        if m > need or m + openCt[ci] < need then
                            good = false
                        end
                    end
                    return good
                end
                local function unplace(pos, mine)
                    for _, ci in of[pos] do
                        openCt[ci] += 1
                        if mine then
                            mineCt[ci] -= 1
                        end
                    end
                end
                local function walk(pos)
                    nodes += 1
                    if nodes % 2048 == 0 then
                        if nodes > nodeCap then
                            aborted = true
                        end
                        yield()
                    end
                    if aborted then
                        return
                    end
                    if pos > n then
                        sols += 1
                        if sols > cap then
                            aborted = true
                            return
                        end
                        W[cur + 1] += 1
                        for i = 1, n do
                            if assign[i] then
                                M[i][cur + 1] += 1
                            end
                        end
                        return
                    end
                    assign[pos] = false
                    if place(pos, false) then
                        walk(pos + 1)
                    end
                    unplace(pos, false)
                    assign[pos] = true
                    cur += 1
                    if place(pos, true) then
                        walk(pos + 1)
                    end
                    unplace(pos, true)
                    cur -= 1
                    assign[pos] = nil
                end
                walk(1)
                if aborted then
                    ok = false
                    out.unresolved += n
                elseif sols == 0 then
                    out.contradiction = true
                    return results, false, false
                else
                    for i, u in clump do
                        local s = 0
                        for _, x in M[i] do
                            s += x
                        end
                        if s == sols then
                            if opt.deep then
                                changed = set(u, "mine") or changed
                            end
                        elseif s == 0 then
                            if opt.deep then
                                changed = set(u, "safe") or changed
                            end
                        else
                            chance[u] = s / sols
                        end
                    end
                    table.insert(results, { cells = clump, W = W, M = M, n = n })
                end
            end
            return results, changed, ok
        end

        -- The mine count ties everything together.
        local function weigh(results)
            local R, U, interior, inClump = opt.total, 0, {}, {}
            for _, res in results do
                for _, u in res.cells do
                    inClump[u] = true
                end
            end
            for _, t in list do
                if hidden(t) then
                    local k = known[t]
                    if k == "mine" then
                        R -= 1
                    elseif k == nil and not inClump[t] then
                        U += 1
                        table.insert(interior, t)
                    end
                end
            end
            out.interiorCells, out.remaining = interior, R
            if R < 0 then
                out.countBad = true
                return false
            end
            local m = #results
            local dists = {}
            for j, res in results do
                local top = 0
                for _, x in res.W do
                    if x > top then
                        top = x
                    end
                end
                res.top = top
                local w, r = {}, {}
                for k, x in res.W do
                    w[k], r[k] = x / top, x > 0
                end
                dists[j] = { w = w, r = r }
            end
            local unit = { w = { 1 }, r = { true } }
            local prefix, suffix = { [0] = unit }, { [m + 1] = unit }
            for j = 1, m do
                prefix[j] = conv(prefix[j - 1], dists[j])
                yield()
            end
            for j = m, 1, -1 do
                suffix[j] = conv(dists[j], suffix[j + 1])
                yield()
            end
            local full = prefix[m]
            -- Feasible frontier totals, and what they leave for the untouched tiles.
            local feasible, Lref = {}, -math.huge
            for F = 0, #full.w - 1 do
                local left = R - F
                if full.r[F + 1] and left >= 0 and left <= U then
                    table.insert(feasible, F)
                    local l = logC(U, left)
                    if l > Lref then
                        Lref = l
                    end
                end
            end
            if #feasible == 0 then
                out.countBad = true
                return false
            end
            local changed = false
            -- Untouched tiles.
            if U > 0 then
                local allNone, allFull = true, true
                local num, den = 0, 0
                for _, F in feasible do
                    local left = R - F
                    if left ~= 0 then
                        allNone = false
                    end
                    if left ~= U then
                        allFull = false
                    end
                    local w = full.w[F + 1] * math.exp(logC(U, left) - Lref)
                    den += w
                    num += w * left / U
                end
                if opt.deep and allNone then
                    for _, t in interior do
                        changed = set(t, "safe") or changed
                    end
                elseif opt.deep and allFull then
                    for _, t in interior do
                        changed = set(t, "mine") or changed
                    end
                elseif den > 0 then
                    out.interior = num / den
                end
            end
            -- Each clump against everything else.
            for j, res in results do
                local ex = conv(prefix[j - 1], suffix[j + 1])
                local n = res.n
                local L = -math.huge
                for k = 0, n do
                    if res.W[k + 1] > 0 then
                        for F = 0, #ex.w - 1 do
                            local left = R - k - F
                            if ex.r[F + 1] and left >= 0 and left <= U then
                                local l = logC(U, left)
                                if l > L then
                                    L = l
                                end
                            end
                        end
                    end
                end
                local g, can = {}, {}
                for k = 0, n do
                    local s, any = 0, false
                    if res.W[k + 1] > 0 then
                        for F = 0, #ex.w - 1 do
                            local left = R - k - F
                            if ex.r[F + 1] and left >= 0 and left <= U then
                                any = true
                                s += ex.w[F + 1] * math.exp(logC(U, left) - L)
                            end
                        end
                    end
                    g[k + 1], can[k + 1] = s, any
                end
                local den = 0
                for k = 0, n do
                    den += (res.W[k + 1] / res.top) * g[k + 1]
                end
                for i, u in res.cells do
                    local mineAll, safeAll, anyK, num = true, true, false, 0
                    for k = 0, n do
                        if can[k + 1] then
                            anyK = true
                            local mk = res.M[i][k + 1]
                            if mk > 0 then
                                safeAll = false
                            end
                            if mk < res.W[k + 1] then
                                mineAll = false
                            end
                            num += (mk / res.top) * g[k + 1]
                        end
                    end
                    if anyK and opt.deep and safeAll then
                        changed = set(u, "safe") or changed
                    elseif anyK and opt.deep and mineAll then
                        changed = set(u, "mine") or changed
                    elseif den > 0 and known[u] == nil then
                        chance[u] = num / den
                    end
                end
                yield()
            end
            out.global = true
            return changed
        end

        for _ = 1, 30 do
            local changed = false
            local cs = constraints()
            if out.contradiction then
                return out
            end
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
            if not changed then
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
            end
            if not changed then
                cs = constraints()
                if out.contradiction then
                    return out
                end
                table.clear(chance)
                out.unresolved = 0
                local results, found, whole = enumerate(cs)
                if out.contradiction then
                    return out
                end
                changed = found
                out.global = false
                out.interior = nil
                if not changed and whole and opt.total then
                    changed = weigh(results)
                end
            end
            if out.contradiction then
                return out
            end
            if not changed then
                break
            end
        end
        return out
    end
end
--#/solver

--// Board \\--
local Board = {
    tiles = {}, byKey = {}, list = {}, pitch = nil, ox = 0, oz = 0, folder = nil, ready = false, gen = 0,
    shape = "Default", wrap = false, trusted = true, bounds = nil, mineValue = nil, mineCountBad = false,
    churn = 0, churnAt = 0, waiting = {},
}
local Memo = {} -- grid key -> last number read there (numbers can fade or be pulled)
local Loose = {} -- part -> owner of a flag lying on it rather than parented to it
local OURS = "MSW_" -- prefix on everything this script makes

-- Markers live in their own folder so the tiles' own children stay the game's.
local Container = Instance.new("Folder")
Container.Name = OURS .. "Markers"
Container.Parent = Workspace.CurrentCamera or Workspace

do
    function Board.folderNow()
        local model = Workspace:FindFirstChild("Flag")
        return model and model:FindFirstChild("Parts")
    end
    function Board.key(gx, gz)
        return (gx + 50000) * 100000 + (gz + 50000)
    end
    function Board.grid(pos)
        return math.floor((pos.X - Board.ox) / Board.pitch + 0.5), math.floor((pos.Z - Board.oz) / Board.pitch + 0.5)
    end
    function Board.at(gx, gz)
        return Board.byKey[Board.key(gx, gz)]
    end
    function Board.rules()
        local pick = Settings.Neighbours
        if pick == "Auto" then
            local mode = Game.mode()
            return SHAPE_OF_MODE[mode] or "Default", mode == "Wrap", mode ~= "Deceiving", mode
        elseif pick == "Default + wrap" then
            return "Default", true, true, pick
        end
        return pick, false, true, pick
    end
    function Board.updateBounds()
        local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
        for _, t in Board.list do
            x0, x1 = math.min(x0, t.gx), math.max(x1, t.gx)
            z0, z1 = math.min(z0, t.gz), math.max(z1, t.gz)
        end
        if x0 == math.huge then
            Board.bounds = nil
        else
            Board.bounds = { x0 = x0, z0 = z0, w = x1 - x0 + 1, h = z1 - z0 + 1 }
        end
    end
    function Board.around(t, offs, wrap)
        local out, seen, b = {}, {}, Board.bounds
        for _, o in offs do
            local gx, gz = t.gx + o[1], t.gz + o[2]
            if wrap and b then
                gx = b.x0 + (gx - b.x0) % b.w
                gz = b.z0 + (gz - b.z0) % b.h
            end
            local n = Board.byKey[Board.key(gx, gz)]
            if n and n ~= t and not seen[n] then
                seen[n] = true
                table.insert(out, n)
            end
        end
        return out
    end
    function Board.linkAll()
        local offs = Shapes[Board.shape] or Shapes.Default
        local links = 0
        for _, t in Board.list do
            t.near = Board.around(t, offs, Board.wrap)
            links += #t.near
        end
        Stats.Neighbours = #Board.list > 0 and links / #Board.list or 0
    end
    -- One new tile on a board that doesn't wrap: link it both ways.
    function Board.linkOne(t)
        t.near = Board.around(t, Shapes[Board.shape] or Shapes.Default, false)
        for _, n in t.near do
            if not table.find(n.near, t) then
                table.insert(n.near, t)
            end
        end
    end

    local function ownerOf(inst)
        return inst:GetAttribute("UserId")
    end
    function Board.owner(part)
        local v = ownerOf(part) or Loose[part]
        if v ~= nil then
            return v
        end
        for _, child in part:GetChildren() do
            if child.Name:sub(1, #OURS) ~= OURS then
                v = ownerOf(child)
                if v ~= nil then
                    return v
                end
                for _, sub in child:GetChildren() do
                    v = ownerOf(sub)
                    if v ~= nil then
                        return v
                    end
                end
            end
        end
        return nil
    end
    function Board.placeLoose(inst)
        if not Board.pitch or Board.tiles[inst] then
            return
        end
        if not (inst:IsA("BasePart") or inst:IsA("Model")) then
            return
        end
        local id = ownerOf(inst)
        if id == nil then
            return
        end
        local ok, pos = pcall(function()
            return inst:IsA("Model") and inst:GetPivot().Position or inst.Position
        end)
        if ok and pos then
            local t = Board.at(Board.grid(pos))
            if t then
                Loose[t.part] = id
                inst.Destroying:Once(function()
                    if Loose[t.part] == id then
                        Loose[t.part] = nil
                    end
                end)
            end
        end
    end
    function Board.findLoose()
        table.clear(Loose)
        local budget = 8000
        for _, inst in Workspace:GetDescendants() do
            budget -= 1
            if budget <= 0 then
                break
            end
            if inst:GetAttribute("UserId") ~= nil then
                Board.placeLoose(inst)
            end
        end
    end

    function Board.burning(part)
        if part:GetAttribute("Burning") or part:GetAttribute("OnFire") then
            return true
        end
        return part:FindFirstChildWhichIsA("Fire", true) ~= nil
    end

    function Board.read(t)
        local part = t.part
        local owner = Board.owner(part)
        if owner ~= nil then
            return "flagged", nil, owner
        end
        local gui = part:FindFirstChild("NumberGui")
        if not gui then
            local m = Memo[t.key]
            if m ~= nil then
                return "revealed", m
            end
            return "unknown"
        end
        local label = gui:FindFirstChild("TextLabel") or gui:FindFirstChildWhichIsA("TextLabel", true)
        if not label then
            return "revealed", Memo[t.key]
        end
        local text = label.Text
        if text == "X" then
            return "unknown"
        end
        if text == nil or text:match("^%s*$") then
            local m = Memo[t.key]
            if m ~= nil then
                return "revealed", m
            end
            -- With Disappearance a blank may be a number that faded before it was seen.
            if Game.challenge("Disappearance") then
                return "revealed", nil
            end
            Memo[t.key] = 0
            return "revealed", 0
        end
        local n = Parse.number(text)
        if n and n >= 0 and n <= 24 then
            Memo[t.key] = n
            return "revealed", n
        end
        return "revealed", Memo[t.key]
    end

    function Board.add(part)
        if Board.tiles[part] or not part:IsA("BasePart") then
            return nil
        end
        local gx, gz = Board.grid(part.Position)
        local key = Board.key(gx, gz)
        if Board.byKey[key] then
            -- An old tile still there (a round changing over): taken once it goes.
            Board.waiting[key] = part
            return nil
        end
        local t = { part = part, gx = gx, gz = gz, key = key, state = "unknown", near = {}, home = part.CFrame }
        Board.tiles[part], Board.byKey[key] = t, t
        table.insert(Board.list, t)
        t.idx = #Board.list
        return t
    end
    function Board.remove(part)
        local t = Board.tiles[part]
        if not t then
            return nil
        end
        Board.tiles[part], Board.byKey[t.key], Memo[t.key], Loose[part] = nil, nil, nil, nil
        local last = table.remove(Board.list)
        if last ~= t then
            Board.list[t.idx] = last
            last.idx = t.idx
        end
        for _, n in t.near do
            local i = table.find(n.near, t)
            if i then
                table.remove(n.near, i)
            end
        end
        local next_ = Board.waiting[t.key]
        Board.waiting[t.key] = nil
        if next_ and next_ ~= part and Board.folder and next_.Parent == Board.folder then
            local nt = Board.add(next_)
            if nt then
                if Board.wrap then
                    Board.updateBounds()
                    Board.linkAll()
                else
                    Board.linkOne(nt)
                end
                nt.state, nt.number, nt.owner = Board.read(nt)
            end
        end
        return t
    end

    -- How many tiles disagree with a neighbour shape: a 0 with a hidden
    -- neighbour, or a number bigger than its neighbour count.
    function Board.misfits(shape, wrap)
        local offs, bad = Shapes[shape] or Shapes.Default, 0
        for _, t in Board.list do
            if t.state == "revealed" and t.number then
                local around = Board.around(t, offs, wrap)
                if t.number > #around then
                    bad += 1
                elseif t.number == 0 then
                    for _, n in around do
                        if n.state ~= "revealed" then
                            bad += 1
                            break
                        end
                    end
                end
            end
        end
        return bad
    end
    -- On Auto, a shape that fits the revealed numbers wins over one that doesn't.
    function Board.checkShape()
        if Settings.Neighbours ~= "Auto" or #Board.list == 0 then
            Board.misfit = Board.misfits(Board.shape, Board.wrap)
            return false
        end
        local shape, wrap, trusted, label = Board.rules()
        Board.trusted = trusted
        local bad = Board.misfits(shape, wrap)
        local bestS, bestW, bestBad, bestLabel = shape, wrap, bad, label
        if bad > 0 then
            for _, alt in { "Default", "Cornerless", "Corners", "Cross", "Large", "Knight" } do
                for _, w in { false, true } do
                    local b = Board.misfits(alt, w)
                    if b < bestBad then
                        bestS, bestW, bestBad, bestLabel = alt, w, b, alt .. (w and " + wrap" or "") .. " (fits better than " .. label .. ")"
                    end
                end
            end
        end
        Board.misfit = bestBad
        if bestS ~= Board.shape or bestW ~= Board.wrap then
            Board.shape, Board.wrap, Stats.Rules = bestS, bestW, bestLabel
            Board.linkAll()
            return true
        end
        Stats.Rules = bestLabel
        return false
    end
end

--// Result of the last solve \\--
local Result = { class = {}, chance = {}, wrong = {}, guess = nil, mines = {} }

--// Markers \\--
local METHODS = { "BoxAdornment", "Highlight", "SelectionBox", "SphereAdornment", "SurfaceGui", "Billboard", "PointLight", "Neon Overlay" }
local Marks = {} -- part -> { kind, method, objects }
local ChanceTags = {} -- part -> BillboardGui
local Draw = {}
do
    function Draw.make(part, method, color)
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
            h.Parent = Container
        elseif method == "SelectionBox" then
            local b = add(Instance.new("SelectionBox"))
            b.Color3, b.SurfaceColor3, b.LineThickness, b.SurfaceTransparency = color, color, 0.05, tr
            b.Adornee = part
            b.Parent = Container
        elseif method == "BoxAdornment" then
            local b = add(Instance.new("BoxHandleAdornment"))
            b.Size, b.Color3, b.Transparency, b.AlwaysOnTop, b.ZIndex = part.Size * 1.02, color, tr, true, 1
            b.Adornee = part
            b.Parent = Container
        elseif method == "SphereAdornment" then
            local s = add(Instance.new("SphereHandleAdornment"))
            s.Radius, s.Color3, s.Transparency, s.AlwaysOnTop = math.max(part.Size.X, part.Size.Z) / 2, color, tr, true
            s.Adornee = part
            s.Parent = Container
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
            g.Parent = Container
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
            p.Parent = Container
        end
        return made
    end

    function Draw.recolor(objects, color)
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

    function Draw.unmark(part)
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
        elseif kind == "fire" then
            return Settings.ShowFire, "BoxAdornment", Color3.fromRGB(255, 120, 30)
        end
    end

    function Draw.mark(part, kind)
        local show, method, color = styleOf(kind)
        if not show then
            Draw.unmark(part)
            return
        end
        local m = Marks[part]
        if m and m.kind == kind and m.method == method then
            Draw.recolor(m.objects, color)
            return
        end
        Draw.unmark(part)
        Marks[part] = { kind = kind, method = method, objects = Draw.make(part, method, color) }
    end

    local function tag(store, part, name, size)
        local gui = store[part]
        if not gui or not gui.Parent then
            gui = Instance.new("BillboardGui")
            gui.Name = OURS .. name
            gui.Adornee, gui.Size, gui.AlwaysOnTop = part, size, true
            gui.StudsOffset = Vector3.new(0, part.Size.Y / 2 + 0.6, 0)
            local text = Instance.new("TextLabel")
            text.Name = "T"
            text.BackgroundTransparency, text.Size = 1, UDim2.fromScale(1, 1)
            text.Font, text.TextScaled, text.TextStrokeTransparency = Enum.Font.GothamBold, true, 0.4
            text.Parent = gui
            gui.Parent = Container
            store[part] = gui
        end
        return gui.T
    end
    Draw.tag = tag

    function Draw.chances()
        local seen = {}
        if Settings.ShowChances then
            for part, p in Result.chance do
                seen[part] = true
                local label = tag(ChanceTags, part, "Chance", UDim2.fromOffset(46, 20))
                label.Text = math.floor(p * 100 + 0.5) .. "%"
                label.TextColor3 = Color3.fromRGB(math.floor(60 + 195 * p), math.floor(220 - 160 * p), 80)
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
    function Draw.all()
        local want = {}
        if Settings.ShowFire then
            for _, t in Board.list do
                if t.burning then
                    want[t.part] = "fire"
                end
            end
        end
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
            Draw.mark(part, kind)
        end
        for part in Marks do
            if not want[part] then
                Draw.unmark(part)
            end
        end
        Draw.chances()
    end

    function Draw.clear()
        for part in Marks do
            Draw.unmark(part)
        end
        for part, gui in ChanceTags do
            pcall(gui.Destroy, gui)
            ChanceTags[part] = nil
        end
    end
end

--// Solving, off the frame \\--
-- The solve runs in its own thread and pauses whenever it has used its slice
-- of a frame, so a big board never stalls the game. Proofs from an older
-- snapshot stay true (more information never undoes a proof), so a solve that
-- was overtaken is still shown and the next one follows right after.
local Solve = { queued = true, running = false, slice = 0, lastEnd = 0 }
local function requestSolve()
    Solve.queued = true
end
do
    function Solve.yield()
        if not alive() then
            error("unloaded", 0)
        end
        if os.clock() - Solve.slice > Settings.SliceMs / 1000 then
            task.wait()
            Solve.slice = os.clock()
        end
    end

    function Solve.run()
        local t0 = os.clock()
        local gen = Board.gen
        local list = table.clone(Board.list)
        local S, N, near = {}, {}, {}
        for _, t in list do
            S[t], N[t], near[t] = t.state, t.number, table.clone(t.near)
        end
        if not Board.trusted then
            Result.class, Result.chance, Result.wrong, Result.guess, Result.mines = {}, {}, {}, nil, {}
            Stats.Safe, Stats.Mines, Stats.WrongFlags = 0, 0, 0
            Stats.Status = "Deceiving mode: the numbers can lie, so nothing is marked"
            return
        end
        local total, why = nil, "mine count off"
        if Settings.UseMineCount then
            total, why = Game.totalMines()
            if total then
                if Board.mineValue == nil then
                    Board.mineValue = total
                elseif Board.mineValue ~= total then
                    Board.mineCountBad = true
                end
                if Board.mineCountBad then
                    total, why = nil, "mine count changes during the round"
                end
            end
        end
        local out = Solver.run(list, S, N, near, {
            deep = Settings.DeepThink, limit = Settings.DeepLimit, cap = Settings.DeepCap,
            total = total, yield = Solve.yield,
        })
        if gen ~= Board.gen or not alive() then
            return
        end
        if out.countBad and total then
            Board.mineCountBad = true
        end
        if out.contradiction then
            Result.class, Result.chance, Result.wrong, Result.guess, Result.mines = {}, {}, {}, nil, {}
            Stats.Safe, Stats.Mines, Stats.WrongFlags = 0, 0, 0
            Stats.Status = ("the numbers don't fit %s neighbours, so nothing is marked (try another shape on the Solver tab)"):format(Stats.Rules)
            Board.recheck = true
            return
        end
        local class, chances, wrong, mines = {}, {}, {}, {}
        local safe, mined, wrongN = 0, 0, 0
        for t, kind in out.known do
            local s = S[t]
            if s == "unknown" and t.state == "unknown" then
                class[t.part] = kind
                if kind == "safe" then
                    safe += 1
                else
                    mined += 1
                    table.insert(mines, t.part)
                end
            elseif s == "flagged" and kind == "safe" then
                wrong[t.part] = true
                wrongN += 1
            end
        end
        local guess, best = nil, nil
        for t, p in out.chance do
            if S[t] == "unknown" and t.state == "unknown" and not out.known[t] then
                chances[t.part] = p
                if not best or p < best then
                    guess, best = t.part, p
                end
            end
        end
        -- A tile no number touches can be the better guess; the nearest one is picked.
        if out.interior and (not best or out.interior < best - 1e-9) then
            local hrp = rootPart()
            local pick, pd
            for _, t in out.interiorCells or {} do
                if S[t] == "unknown" and t.state == "unknown" then
                    local d = hrp and (t.part.Position - hrp.Position).Magnitude or 0
                    if not pd or d < pd then
                        pick, pd = t.part, d
                    end
                end
            end
            if pick then
                guess, best = pick, out.interior
            end
        end
        Stats.Guess = best
        Stats.Interior = out.interior
        if safe > 0 then
            guess = nil
        end
        Result.class, Result.chance, Result.wrong, Result.guess, Result.mines = class, chances, wrong, guess, mines
        Stats.Safe, Stats.Mines, Stats.WrongFlags = safe, mined, wrongN
        if out.global then
            Stats.Global = ("mine count used: %d left among hidden tiles"):format(out.remaining or 0)
        elseif out.unresolved > 0 then
            Stats.Global = ("%d tiles in clumps too big to work through (raise Biggest clump)"):format(out.unresolved)
        else
            Stats.Global = "mine count not used (" .. tostring(why or "off") .. ")"
        end
        Stats.Status = ("%d tiles"):format(#Board.list)
        Stats.SolveMs = (os.clock() - t0) * 1000
    end
end

--// Flags \\--
local Flagging = { remote = nil, token = nil, ours = {}, lastScan = -math.huge }
do
    function Flagging.remoteNow()
        return Game.event("FlagEvents", "PlaceFlag")
    end

    -- Takes the token from the game's own click handlers. It runs at most
    -- once every 15 seconds: walking the whole garbage collector is the slow
    -- part, and running it on every flag was what made auto flag stutter.
    function Flagging.findToken(force)
        Flagging.remote = Flagging.remoteNow() or Flagging.remote
        Genv.__MSWRemote = Flagging.remote
        if Flagging.token then
            return true
        end
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
        if not force and os.clock() - Flagging.lastScan < 15 then
            return false
        end
        Flagging.lastScan = os.clock()
        if typeof(getgc) ~= "function" or typeof(debug) ~= "table" or typeof(debug.getupvalues) ~= "function" then
            Stats.Token = "this executor has no getgc; flag one tile yourself and it's picked up"
            return false
        end
        local parts = Board.folderNow()
        local isOurs = (typeof(isexecutorclosure) == "function" and isexecutorclosure)
            or (typeof(checkclosure) == "function" and checkclosure) or nil
        local info = typeof(debug.info) == "function" and debug.info or nil
        local found, bestScore = nil, 0
        pcall(function()
            for _, fn in getgc() do
                if type(fn) == "function" and not (isOurs and isOurs(fn)) then
                    local ok, ups = pcall(debug.getupvalues, fn)
                    if ok and type(ups) == "table" then
                        local num, hasParts, hasRS, hasTile = nil, false, false, false
                        for _, up in ups do
                            local ty = typeof(up)
                            if ty == "number" then
                                if up ~= 0 and up == up and math.abs(up) ~= math.huge then
                                    num = up
                                end
                            elseif ty == "Instance" then
                                if up == parts then
                                    hasParts = true
                                elseif up == ReplicatedStorage then
                                    hasRS = true
                                elseif parts and up.Parent == parts then
                                    hasTile = true
                                end
                            end
                        end
                        -- PC handler: ReplicatedStorage + Parts + token.
                        -- Touch handler: ReplicatedStorage + its tile + token.
                        if num and hasRS and (hasParts or hasTile) then
                            local score = 2 + (hasParts and 1 or 0)
                            if info then
                                local okS, src = pcall(info, fn, "s")
                                if okS and type(src) == "string" and src:find("MouseControl", 1, true) then
                                    score += 10
                                end
                            end
                            if score > bestScore then
                                found, bestScore = num, score
                            end
                        end
                    end
                end
            end
        end)
        if found then
            Flagging.token = found
            Stats.Token = "taken from the game's click handler"
            return true
        end
        Stats.Token = "not found yet; flag one tile yourself and it's picked up"
        return false
    end

    -- The game's own flag request carries the token, so the first flag you
    -- place by hand hands it over. Installed once per session.
    Genv.__MSWTokenSink = function(token)
        if alive() and not Flagging.token then
            Flagging.token = token
            Stats.Token = "picked up from your own flag"
        end
    end
    if not Genv.__MSWHooked and typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        Genv.__MSWHooked = true
        local old
        local function handler(self, ...)
            if self == Genv.__MSWRemote and getnamecallmethod() == "FireServer" then
                local sink = Genv.__MSWTokenSink
                local _, token = ...
                if sink and typeof(token) == "number" and token ~= 0 then
                    pcall(sink, token)
                end
            end
            return old(self, ...)
        end
        local wrap = typeof(newcclosure) == "function" and newcclosure or function(f)
            return f
        end
        pcall(function()
            old = hookmetamethod(game, "__namecall", wrap(handler))
        end)
    end

    function Flagging.place(part)
        local method = Settings.FlagMethod
        if method ~= "ClickDetector" then
            if not Flagging.token then
                Flagging.findToken(false)
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
            return (pcall(fireclickdetector, detector))
        end
        return false
    end
end

--// Moving \\--
local Moves = { tried = {}, lastChase = 0, lastLeave = 0 }
local Challenges = { fatal = nil, bulletScript = nil, conveyors = {}, solid = {} }
do
    function Moves.safeStand(t)
        if not t or t.state ~= "revealed" or not t.part.Parent then
            return false
        end
        if Settings.AvoidDanger then
            if t.burning or (Challenges.fatal and t.number == Challenges.fatal) then
                return false
            end
        end
        return true
    end
    function Moves.tp(part)
        local hrp = rootPart()
        if not hrp then
            return
        end
        hrp.CFrame = CFrame.new(part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)) * hrp.CFrame.Rotation
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
    function Moves.under()
        local hrp = rootPart()
        if not hrp or not Board.pitch then
            return nil
        end
        return Board.at(Board.grid(hrp.Position))
    end
    -- Stand on a revealed tile in reach of the nearest proven mine.
    function Moves.chase()
        if os.clock() - Moves.lastChase < 0.4 then
            return
        end
        local hrp = rootPart()
        if not hrp then
            return
        end
        local target, td
        for _, part in Result.mines do
            local t = Board.tiles[part]
            if t and t.state == "unknown" and not Flagging.ours[part] then
                local d = (part.Position - hrp.Position).Magnitude
                if not td or d < td then
                    target, td = part, d
                end
            end
        end
        if not target then
            return
        end
        local stand, sd
        for _, t in Board.list do
            if Moves.safeStand(t) and (t.part.Position - target.Position).Magnitude <= 26 then
                local d = (t.part.Position - hrp.Position).Magnitude
                if not sd or d < sd then
                    stand, sd = t.part, d
                end
            end
        end
        if stand then
            Moves.lastChase = os.clock()
            Moves.tp(stand)
        end
    end
    -- Off a burning tile or the fatal number.
    function Moves.leaveDanger()
        if not Settings.LeaveDanger or os.clock() - Moves.lastLeave < 0.3 then
            return
        end
        local here = Moves.under()
        if not here or here.state ~= "revealed" then
            return
        end
        if not (here.burning or (Challenges.fatal and here.number == Challenges.fatal)) then
            return
        end
        local hrp = rootPart()
        local best, bd
        for _, t in Board.list do
            if t ~= here and Moves.safeStand(t) and not (t.burning or (Challenges.fatal and t.number == Challenges.fatal)) then
                local d = (t.part.Position - hrp.Position).Magnitude
                if d <= 60 and (not bd or d < bd) then
                    best, bd = t.part, d
                end
            end
        end
        if best then
            Moves.lastLeave = os.clock()
            Moves.tp(best)
        end
    end

    -- A tile opens when you touch it; proven safe ones are stepped on,
    -- nearest first, by teleport or by walking.
    function Moves.stepPass()
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
            if kind == "safe" and t and t.state == "unknown" and (Moves.tried[part] or 0) < os.clock() then
                local d = (part.Position - hrp.Position).Magnitude
                if d <= Settings.StepRange and (not bestD or d < bestD) then
                    best, bestD = part, d
                end
            end
        end
        if not best then
            return
        end
        Moves.tried[best] = os.clock() + 3
        if Settings.StepMethod == "Teleport" then
            Moves.tp(best)
            task.wait(Settings.StepDelay)
        else
            hum:MoveTo(best.Position)
            local t0 = os.clock()
            repeat
                task.wait(0.05)
            until not alive() or (Board.tiles[best] and Board.tiles[best].state ~= "unknown") or os.clock() - t0 > 3
        end
    end
end

function Flagging.pass()
    if not Settings.AutoFlag then
        Stats.FlagNote = ""
        return
    end
    if not Game.playing() then
        Stats.FlagNote = "waiting: you're not on the Playing team"
        return
    end
    if Game.flagless() then
        Stats.FlagNote = "waiting: this round is flagless"
        return
    end
    local hrp = rootPart()
    if not hrp then
        return
    end
    -- The game only takes a flag from under 32 studs away.
    local range = math.min(Settings.FlagRange, 31.5)
    local queue = {}
    for _, part in Result.mines do
        local t = Board.tiles[part]
        if t and t.state == "unknown" and not Flagging.ours[part] then
            local d = (part.Position - hrp.Position).Magnitude
            if d <= range then
                table.insert(queue, { part = part, d = d })
            end
        end
    end
    if #queue == 0 then
        Stats.FlagNote = #Result.mines > 0 and "proven mines are out of reach" or ""
        if Settings.FlagChase and #Result.mines > 0 then
            Moves.chase()
        end
        return
    end
    Stats.FlagNote = ("flagging %d"):format(#queue)
    table.sort(queue, function(a, b)
        return a.d < b.d
    end)
    for _, q in queue do
        if not alive() or not Settings.AutoFlag then
            break
        end
        local t = Board.tiles[q.part]
        local now = rootPart()
        -- Stepping can move you while this runs, so the reach is checked again.
        if t and t.state == "unknown" and q.part.Parent and now and (q.part.Position - now.Position).Magnitude <= range then
            Flagging.ours[q.part] = true
            Flagging.place(q.part)
            if Settings.FlagDelay > 0 then
                task.wait(Settings.FlagDelay)
            end
        end
    end
end

--// Watching the board \\--
local BoardConns = {}
local Watch = {}
do
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
        Stats.Tiles, Stats.Revealed, Stats.Unknown, Stats.Flagged = #Board.list, r, u, f
    end
    Watch.counts = counts

    function Watch.refresh(t)
        if not t.part.Parent then
            return
        end
        local state, number, owner = Board.read(t)
        if state ~= t.state or number ~= t.number or owner ~= t.owner then
            t.state, t.number, t.owner = state, number, owner
            if state ~= "unknown" then
                Result.class[t.part] = nil
            end
            requestSolve()
        end
        local burning = Board.burning(t.part)
        if burning ~= t.burning then
            t.burning = burning
            requestSolve()
        end
    end

    local function ours(inst)
        local p = inst
        for _ = 1, 3 do
            if not p then
                return false
            end
            if p.Name:sub(1, #OURS) == OURS then
                return true
            end
            p = p.Parent
        end
        return false
    end

    local function watchLabel(t, label)
        if label:IsA("TextLabel") then
            table.insert(BoardConns, label:GetPropertyChangedSignal("Text"):Connect(function()
                Watch.refresh(t)
            end))
        end
    end

    function Watch.drop(why)
        for _, c in BoardConns do
            pcall(c.Disconnect, c)
        end
        table.clear(BoardConns)
        Draw.clear()
        Result.class, Result.chance, Result.wrong, Result.guess, Result.mines = {}, {}, {}, nil, {}
        table.clear(Flagging.ours)
        table.clear(Moves.tried)
        Board.ready = false
        Board.gen += 1
        Stats.Status = why
    end

    function Watch.build()
        local folder = Board.folderNow()
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
        Board.tiles, Board.byKey, Board.list, Board.waiting = {}, {}, {}, {}
        Board.pitch, Board.ox, Board.oz, Board.folder = pitch, parts[1].Position.X, parts[1].Position.Z, folder
        Board.gen += 1
        Board.mineValue, Board.mineCountBad = nil, false
        table.clear(Memo)
        for _, p in parts do
            Board.add(p)
        end
        Board.updateBounds()
        local label
        Board.shape, Board.wrap, Board.trusted, label = Board.rules()
        Stats.Rules = label
        Board.linkAll()
        Board.findLoose()
        for _, t in Board.list do
            t.state, t.number, t.owner = Board.read(t)
            t.burning = Board.burning(t.part)
        end
        Board.checkShape()
        counts()

        table.insert(BoardConns, folder.ChildAdded:Connect(function(p)
            local t = Board.add(p)
            if not t then
                return
            end
            if Board.wrap then
                Board.updateBounds()
                Board.linkAll()
            else
                Board.linkOne(t)
            end
            t.state, t.number, t.owner = Board.read(t)
            requestSolve()
        end))
        table.insert(BoardConns, folder.ChildRemoved:Connect(function(p)
            if not Board.tiles[p] then
                return
            end
            -- Most of the board going at once is a new round.
            local now = os.clock()
            if now - Board.churnAt > 1 then
                Board.churn = 0
            end
            Board.churn += 1
            Board.churnAt = now
            if Board.churn > math.max(25, #Board.list * 0.4) then
                Watch.drop("new round, reading the board")
                return
            end
            Board.remove(p)
            Draw.unmark(p)
            Result.class[p], Result.chance[p], Result.wrong[p] = nil, nil, nil
            requestSolve()
        end))
        table.insert(BoardConns, folder.DescendantAdded:Connect(function(d)
            if ours(d) then
                return
            end
            local part = d:FindFirstAncestorWhichIsA("BasePart")
            local t = part and Board.tiles[part]
            if t then
                watchLabel(t, d)
                Watch.refresh(t)
            end
        end))
        table.insert(BoardConns, folder.DescendantRemoving:Connect(function(d)
            if ours(d) then
                return
            end
            local part = d:FindFirstAncestorWhichIsA("BasePart")
            local t = part and Board.tiles[part]
            if t then
                task.defer(Watch.refresh, t)
            end
        end))
        for _, t in Board.list do
            local gui = t.part:FindFirstChild("NumberGui")
            if gui then
                for _, d in gui:GetDescendants() do
                    watchLabel(t, d)
                end
            end
        end
        return true
    end
end

-- Loose flags dropped into the world after the board was read.
bind(Workspace.DescendantAdded, function(inst)
    if Board.ready and (inst:IsA("Model") or inst:IsA("BasePart")) then
        task.defer(function()
            if inst.Parent and inst:GetAttribute("UserId") ~= nil then
                Board.placeLoose(inst)
                local t = Board.at(Board.grid(inst:IsA("Model") and inst:GetPivot().Position or inst.Position))
                if t then
                    Watch.refresh(t)
                end
            end
        end)
    end
end)

-- Finds the board, then keeps a slow safety sweep going (events drive the rest).
loop(function()
    return Settings.Backstop
end, function()
    if not Board.ready then
        if Watch.build() then
            Board.ready = true
            Stats.Status = ("%d tiles"):format(#Board.list)
            Flagging.findToken(true)
            requestSolve()
        else
            Stats.Status = "waiting for the board"
        end
        return
    end
    if not Board.folder or not Board.folder.Parent then
        Watch.drop("board gone, looking again")
        return
    end
    for _, t in Board.list do
        Watch.refresh(t)
    end
    if Board.recheck or (os.clock() % 4 < Settings.Backstop) then
        Board.recheck = false
        if Board.checkShape() then
            requestSolve()
        end
    end
    -- Rules changed between rounds (an admin can change the mode).
    local shape, wrap, trusted = Board.rules()
    if Settings.Neighbours ~= "Auto" and (shape ~= Board.shape or wrap ~= Board.wrap) then
        Board.shape, Board.wrap = shape, wrap
        Board.updateBounds()
        Board.linkAll()
        requestSolve()
    end
    if trusted ~= Board.trusted then
        Board.trusted = trusted
        requestSolve()
    end
    Watch.counts()
end)

-- Starts a solve on the frame after the board moves.
bind(RunService.Heartbeat, function()
    if not alive() or not Board.ready or not Solve.queued or Solve.running then
        return
    end
    if os.clock() - Solve.lastEnd < 0.05 then
        return
    end
    Solve.queued, Solve.running = false, true
    Solve.slice = os.clock()
    task.spawn(function()
        local ok, err = pcall(Solve.run)
        if not ok and tostring(err) ~= "unloaded" then
            warn("[Minesweeper] solve: " .. tostring(err))
        end
        Solve.running = false
        Solve.lastEnd = os.clock()
        if alive() then
            pcall(Draw.all)
            Watch.counts()
        end
    end)
end)

loop(0.1, function()
    if Board.ready then
        Flagging.pass()
    end
end)
loop(0.05, function()
    if Board.ready then
        Moves.stepPass()
        Moves.leaveDanger()
    end
end)

--// Overlay: flag owners and numbers \\--
local Overlay = { owners = {}, numbers = {}, names = {} }
do
    local COLORS = {
        [1] = Color3.fromRGB(40, 120, 230), [2] = Color3.fromRGB(40, 160, 70), [3] = Color3.fromRGB(225, 60, 60),
        [4] = Color3.fromRGB(130, 50, 190), [5] = Color3.fromRGB(200, 110, 20), [6] = Color3.fromRGB(20, 160, 170),
        [7] = Color3.fromRGB(60, 60, 60), [8] = Color3.fromRGB(150, 150, 150),
    }
    function Overlay.name(id)
        local n = Overlay.names[id]
        if n then
            return n
        end
        local p = Players:GetPlayerByUserId(tonumber(id) or 0)
        n = p and p.DisplayName or ("#" .. tostring(id))
        if p then
            Overlay.names[id] = n
        end
        return n
    end
    function Overlay.wantNumbers()
        local mode = Settings.NumberOverlay
        if mode == "Always" then
            return true
        elseif mode == "Challenges only" then
            return Game.challenge("Disappearance") or Game.challenge("Confusion") or Game.challenge("Vigilant")
        end
        return false
    end
    local function sweep(store, keep)
        for part, gui in store do
            if not keep[part] then
                pcall(gui.Destroy, gui)
                store[part] = nil
            end
        end
    end
    function Overlay.update()
        local keepO, keepN = {}, {}
        local numbers = Overlay.wantNumbers()
        for _, t in Board.list do
            local part = t.part
            if Settings.ShowOwners and t.state == "flagged" and t.owner ~= nil then
                keepO[part] = true
                local label = Draw.tag(Overlay.owners, part, "Owner", UDim2.fromOffset(120, 20))
                local wrong = Result.wrong[part]
                local text = (wrong and "wrong · " or "") .. Overlay.name(t.owner)
                if label.Text ~= text then
                    label.Text = text
                end
                label.TextColor3 = wrong and Settings.WrongFlagColor or Color3.fromRGB(235, 235, 235)
            end
            if numbers and t.state == "revealed" and t.number and t.number > 0 then
                keepN[part] = true
                local label = Draw.tag(Overlay.numbers, part, "Number", UDim2.fromOffset(26, 26))
                local text = tostring(t.number)
                if label.Text ~= text then
                    label.Text = text
                end
                local fatal = Challenges.fatal and t.number == Challenges.fatal
                label.TextColor3 = fatal and Color3.fromRGB(255, 40, 120) or COLORS[t.number] or Color3.fromRGB(240, 240, 240)
            end
        end
        sweep(Overlay.owners, keepO)
        sweep(Overlay.numbers, keepN)
    end
    function Overlay.clear()
        sweep(Overlay.owners, {})
        sweep(Overlay.numbers, {})
    end
end
loop(0.3, function()
    if Board.ready then
        Overlay.update()
    end
end)

--// Challenge helpers \\--
do
    -- Vigilant: the fatal number, from Info.NumberTimer.
    function Challenges.readFatal()
        if not Game.challenge("Vigilant") then
            Challenges.fatal = nil
            return
        end
        local v = Game.value("NumberTimer")
        local n = typeof(v) == "Vector3" and math.floor(v.X + 0.5) or nil
        Challenges.fatal = (n and n >= 1 and n <= 24) and n or nil
    end

    -- Bullets: the bullets are a LocalScript's own parts, so with it switched
    -- off none are made and none can touch you.
    function Challenges.bullets()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local gui = pg and pg:FindFirstChild("BulletScriptGui")
        local script = gui and gui:FindFirstChild("BulletScript")
        if Settings.NoBullets then
            if script and Challenges.bulletScript ~= script then
                pcall(function()
                    script.Enabled = false
                end)
                pcall(function()
                    script.Disabled = true
                end)
                Challenges.bulletScript = script
            end
            for _, c in Workspace:GetChildren() do
                if c.Name == "Bullet-Part" then
                    pcall(c.Destroy, c)
                end
            end
        elseif Challenges.bulletScript then
            local s = Challenges.bulletScript
            Challenges.bulletScript = nil
            if s.Parent then
                pcall(function()
                    s.Disabled = false
                end)
                pcall(function()
                    s.Enabled = true
                end)
            end
        end
    end

    -- Conveyors: a tile pushes you through its own velocity; zeroed here.
    function Challenges.conveyorPass()
        if Settings.StopConveyors then
            for _, t in Board.list do
                local p = t.part
                local v = p.AssemblyLinearVelocity
                if v.Magnitude > 0.05 then
                    Challenges.conveyors[p] = Challenges.conveyors[p] or v
                    p.AssemblyLinearVelocity = Vector3.zero
                end
            end
        elseif next(Challenges.conveyors) then
            for p, v in Challenges.conveyors do
                if p.Parent then
                    pcall(function()
                        p.AssemblyLinearVelocity = v
                    end)
                end
            end
            table.clear(Challenges.conveyors)
        end
    end

    -- Phasing: tiles near you stay solid for your own character.
    function Challenges.solidPass()
        if Settings.SolidTiles then
            local here = rootPart()
            if not here or not Board.pitch then
                return
            end
            local gx, gz = Board.grid(here.Position)
            for dx = -3, 3 do
                for dz = -3, 3 do
                    local t = Board.at(gx + dx, gz + dz)
                    if t and not t.part.CanCollide then
                        Challenges.solid[t.part] = true
                        t.part.CanCollide = true
                    end
                end
            end
        elseif next(Challenges.solid) then
            table.clear(Challenges.solid)
        end
    end

    -- Malfunction: tiles put back where they were first seen.
    function Challenges.steadyPass()
        if not Settings.SteadyBoard then
            return
        end
        for _, t in Board.list do
            local p = t.part
            if p.Parent and (p.Position - t.home.Position).Magnitude > 0.05 then
                p.CFrame = t.home
            end
        end
    end
end
bind(Workspace.ChildAdded, function(c)
    if Settings.NoBullets and c.Name == "Bullet-Part" then
        task.defer(function()
            pcall(c.Destroy, c)
        end)
    end
end)
bind(RunService.Heartbeat, function()
    if Board.ready then
        Challenges.solidPass()
    end
end)
loop(0.15, function()
    Challenges.readFatal()
    if Board.ready then
        Challenges.conveyorPass()
        Challenges.steadyPass()
    end
end)
loop(0.5, Challenges.bullets)

--// Votekick and AFK \\--
local Kick = { caller = nil, target = nil, at = 0 }
do
    local function who(p)
        if typeof(p) ~= "Instance" then
            return "someone"
        end
        return p.DisplayName == p.Name and ("@" .. p.Name) or ("%s (@%s)"):format(p.DisplayName, p.Name)
    end
    Kick.who = who
    function Kick.vote(yes)
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local gui = pg and pg:FindFirstChild("VotekickGui")
        local frame = gui and gui:FindFirstChild("KickFrame")
        local button = frame and frame:FindFirstChild(yes and "Yes" or "No")
        -- Through the game's own button so its 15 second fallback doesn't vote again.
        if not (button and frame.Visible and fireButton(button)) then
            local remote = Game.event("VotekickEvents", "VoteOnVotekick")
            if remote then
                pcall(remote.FireServer, remote, yes)
            end
        end
        Kick.caller = nil
    end
    local call = Game.event("VotekickEvents", "CallVotekick")
    if call then
        bind(call.OnClientEvent, function(caller, target)
            if target == LocalPlayer then
                notify(("%s started a votekick on you"):format(who(caller)), 12)
                return
            end
            if caller == LocalPlayer then
                return
            end
            Kick.caller, Kick.target, Kick.at = caller, target, os.clock()
            if Settings.VoteAlert then
                notify(("%s wants to kick %s (Game tab to vote)"):format(who(caller), who(target)), 8)
            end
            if Settings.AutoVoteNo then
                task.delay(0.5, function()
                    if alive() and Kick.caller == caller then
                        Kick.vote(false)
                    end
                end)
            end
        end)
    end
    bind(LocalPlayer.Idled, function()
        if Settings.AntiAfk then
            pcall(function()
                local vu = game:GetService("VirtualUser")
                vu:CaptureController()
                vu:ClickButton2(Vector2.new())
            end)
        end
    end)
end

--// The game's own settings, stats and servers \\--
local GameSet = { syncing = false }
local BOOL_SETTINGS = {
    { "CameraLock", "Camera lock" }, { "ClicksIgnoreFlags", "Clicks ignore flags" },
    { "CursorSelectionBox", "Cursor selection box" }, { "RotateNumbers", "Rotate numbers" },
    { "HideGhosts", "Hide ghosts" }, { "DisableExplosions", "No explosions" },
    { "DisableShadows", "No shadows" }, { "DisableClouds", "No clouds" }, { "HotbarMenu", "Hotbar menu" },
}
local NUM_SETTINGS = {
    { "FieldOfView", "Field of view", 20, 120 }, { "ClockTime", "Clock time", 0, 1 },
    { "PlayerTransparency", "Player transparency", 0, 1 }, { "CursorSelectionColor", "Cursor colour", 0, 1 },
}
do
    local function menu()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        return pg and pg:FindFirstChild("MenuGui")
    end
    local function general()
        local m = menu()
        local f = m and m:FindFirstChild("MainFrame")
        f = f and f:FindFirstChild("Frame")
        f = f and f:FindFirstChild("Settings")
        return f and f:FindFirstChild("General")
    end
    local function module(name)
        local m = menu()
        local ls = m and m:FindFirstChild("LocalScript")
        local s = ls and ls:FindFirstChild("Settings")
        local g = s and s:FindFirstChild("GeneralSettings")
        local mod = g and g:FindFirstChild(name)
        if mod then
            local ok, res = pcall(require, mod)
            if ok and type(res) == "table" then
                return res
            end
        end
        return nil
    end
    local function send(name, value)
        local remote = Game.event("SettingEvents", "SetSettings")
        if remote then
            pcall(remote.FireServer, remote, name, value)
        end
    end
    -- Current values, read off the game's own settings page.
    function GameSet.readBool(name)
        local g = general()
        local row = g and g:FindFirstChild(name)
        local b = row and row:FindFirstChild("Button")
        if b and b:IsA("GuiButton") then
            return b.Text == "On"
        end
        return nil
    end
    function GameSet.readNumber(name)
        local g = general()
        local row = g and g:FindFirstChild(name)
        local v = row and row:FindFirstChildOfClass("NumberValue")
        return v and v.Value or nil
    end
    function GameSet.setBool(name, v)
        local g = general()
        local row = g and g:FindFirstChild(name)
        local b = row and row:FindFirstChild("Button")
        if b and b:IsA("GuiButton") then
            if (b.Text == "On") == v then
                return
            end
            if fireButton(b) then
                return
            end
        end
        local m = module(name)
        if m then
            pcall(v and m.On or m.Off, m)
        end
        send(name, v)
    end
    -- value is the game's own 0..1
    function GameSet.setNumber(name, v)
        local m = module(name)
        if m then
            m.Number = v
            pcall(m.Update, m)
        end
        local g = general()
        local row = g and g:FindFirstChild(name)
        local nv = row and row:FindFirstChildOfClass("NumberValue")
        if nv then
            nv.Value = v -- the game's own Changed handler saves it
            local bar = row:FindFirstChild("Bar")
            local drag = bar and bar:FindFirstChild("Drag")
            if drag then
                pcall(function()
                    drag.Position = UDim2.new(v, 0, drag.Position.Y.Scale, drag.Position.Y.Offset)
                end)
            end
        else
            send(name, v)
        end
    end

    function GameSet.stats()
        local rf = Game.event("SettingEvents", "GetStats")
        if not rf then
            return "no stats remote"
        end
        local ok, d = pcall(rf.InvokeServer, rf)
        if not ok or type(d) ~= "table" then
            return "couldn't fetch stats"
        end
        local wins = "?"
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local w = ls and ls:FindFirstChild("Wins")
        if w then
            wins = tostring(w.Value)
        end
        local dupes = type(d.Dupes) == "table" and d.Dupes or {}
        return ("Wins %s · rounds %s · MVP %s\nTime played %s min (%s h)\nTiles revealed %s\nDuplicates %s / %s / %s (common / rare / legendary)%s"):format(
            wins, tostring(d.Games or "?"), tostring(d.MVPs or "?"),
            tostring(d.Time or "?"), tostring(type(d.Time) == "number" and d.Time // 60 or "?"),
            tostring(d.Tiles or "?"), tostring(dupes.Common or 0), tostring(dupes.Rare or 0), tostring(dupes.Legendary or 0),
            Workspace:FindFirstChild("Vip") and "\n(VIP server: these don't update here)" or "")
    end
end

local Servers = { list = {}, labels = {} }
do
    local function push(label, join)
        table.insert(Servers.labels, label)
        Servers.list[label] = join
    end
    function Servers.reset()
        table.clear(Servers.labels)
        table.clear(Servers.list)
    end
    local infinites, pros = {}, {}
    function Servers.rebuild()
        Servers.reset()
        for _, s in infinites do
            local id = s.PrivateServerId
            push(("Infinite · %s · %d/5 · %s wins"):format(tostring(s.Region), type(s.Players) == "table" and #s.Players or 0, tostring(s.Wins)), function()
                local r = Game.event("GlobalEvents", "JoinInfinite")
                if r then
                    r:FireServer(id)
                end
            end)
        end
        for tier, group in pros do
            if type(group) == "table" then
                for i, s in group do
                    push(("%s #%s · %s · %d/5 · needs %s wins"):format(tostring(tier), tostring(i), tostring(s.Region),
                        type(s.Players) == "table" and #s.Players or 0, tostring(s.Requirement)), function()
                        local r = Game.event("GlobalEvents", "JoinPro")
                        if r then
                            r:FireServer(tier, i)
                        end
                    end)
                end
            end
        end
        if Servers.onChange then
            Servers.onChange()
        end
    end
    local gi, gp = Game.event("GlobalEvents", "GetInfinites"), Game.event("GlobalEvents", "GetPros")
    if gi then
        bind(gi.OnClientEvent, function(list)
            infinites = type(list) == "table" and list or {}
            Servers.rebuild()
        end)
    end
    if gp then
        bind(gp.OnClientEvent, function(list)
            pros = type(list) == "table" and list or {}
            Servers.rebuild()
        end)
    end
    function Servers.refresh()
        if gi then
            pcall(gi.FireServer, gi)
        end
        if gp then
            pcall(gp.FireServer, gp)
        end
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Minesweeper",
    Footer = "dookie hub · Ui3",
    Icon = "grid-3x3",
    Size = UDim2.fromOffset(680, 540),
    ConfigFolder = "Ui3/Minesweeper",
})

local UI = {}
do
    function UI.redraw()
        pcall(Draw.all)
    end
    function UI.resolve()
        requestSolve()
    end
    function UI.toggle(box, idx, text, key, tooltip, after)
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
    function UI.slider(box, idx, text, key, min, max, rounding, suffix, tooltip, after)
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
    function UI.choice(box, idx, text, key, values, tooltip, after)
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
    function UI.color(toggleObj, idx, title, key)
        toggleObj:AddColorPicker(idx, {
            Default = Settings[key], Title = title,
            Callback = function(c)
                Settings[key] = guardColor(c)
                UI.redraw()
            end,
        })
    end
    function UI.pct(p)
        return p and (math.floor(p * 1000 + 0.5) / 10 .. "%") or "-"
    end
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
            Watch.drop("reading the board again")
        end,
    })

    local RoundBox = Tab:AddLeftGroupbox("Round", "info")
    local RoundLabel = RoundBox:AddLabel("...", true)
    local GuessLabel = RoundBox:AddLabel("...", true)

    local ThinkBox = Tab:AddRightGroupbox("Thinking", "cpu")
    UI.toggle(ThinkBox, "DeepThink", "Better thinking", "DeepThink",
        "Works through every mine arrangement of each clump of hidden tiles: a mine in all of them is a mine, safe in all of them is safe", UI.resolve)
    UI.toggle(ThinkBox, "UseMineCount", "Use the mine count", "UseMineCount",
        "Weighs every clump and every untouched tile against the board's mine count. Gives the real chance on every tile and proves what the count alone settles. Off on infinite boards and progressive mines", UI.resolve)
    UI.choice(ThinkBox, "Neighbours", "Neighbour shape", "Neighbours", NEIGHBOUR_CHOICES,
        "Which tiles a number counts. Auto follows the game mode and switches to a shape that fits better if the revealed numbers disagree with it", function()
            if Board.ready then
                Board.shape, Board.wrap, Board.trusted, Stats.Rules = Board.rules()
                Board.updateBounds()
                Board.linkAll()
                Board.checkShape()
                requestSolve()
            end
        end)
    UI.slider(ThinkBox, "DeepLimit", "Biggest clump", "DeepLimit", 8, 48, 0, " tiles",
        "Clumps up to this size are worked through exactly. Bigger ones are left to the simpler passes and the mine count can't be used that solve", UI.resolve)
    UI.slider(ThinkBox, "SliceMs", "Work per frame", "SliceMs", 1, 12, 0, " ms",
        "How long a solve may run in one frame before it pauses. Lower is smoother, higher finishes sooner")
    UI.slider(ThinkBox, "Backstop", "Safety sweep every", "Backstop", 0.25, 5, 2, " s",
        "Changes are picked up the moment they happen; this sweep only catches one that raised no event")
    ThinkBox:AddLabel("Flags are never trusted: proofs come only from the numbers, so a wrong flag can't lead the solver astray. Only proven tiles get coloured", true)
    local PerfLabel = ThinkBox:AddLabel("...", true)

    loop(0.25, function()
        BoardLabel:SetText(("Board: %s\nRules: %s · %.1f neighbours each%s"):format(Stats.Status, tostring(Stats.Rules), Stats.Neighbours,
            (Board.misfit and Board.misfit > 0) and (" · %d tiles disagree"):format(Board.misfit) or ""))
        CountLabel:SetText(("Revealed %d · hidden %d · flagged %d"):format(Stats.Revealed, Stats.Unknown, Stats.Flagged))
        ResultLabel:SetText(("Proven safe %d · proven mines %d · wrong flags %d"):format(Stats.Safe, Stats.Mines, Stats.WrongFlags))
        local total = Game.value("Mines")
        local flags = Game.value("Flags")
        local timer = Game.timer()
        local progress = Game.value("Progress")
        local challenges = Game.activeChallenges()
        local infinite = Game.infinite()
        local size = Game.setting("GridSize")
        RoundLabel:SetText(("Mode %s%s · %s\n%s · flags %s%s\nTimer %s · progress %s\nChallenges: %s"):format(
            Game.mode(),
            typeof(size) == "Vector2" and (" %dx%d"):format(size.X, size.Y) or "",
            Game.value("GameRunning") and "running" or "between rounds",
            infinite and ("Tiles %s"):format(tostring(total)) or ("Mines %s, about %s left"):format(tostring(total),
                (typeof(total) == "number" and typeof(flags) == "number") and tostring(total - flags) or "?"),
            tostring(flags), Game.flagless() and " · flagless" or "",
            timer and ("%.1fs"):format(timer) or "-",
            typeof(progress) == "number" and UI.pct(progress) or "-",
            #challenges > 0 and table.concat(challenges, ", ") or "none"))
        GuessLabel:SetText(Stats.Safe > 0 and ("%d proven safe tiles to open"):format(Stats.Safe)
            or ("Nothing proven. Best guess %s mine chance%s"):format(UI.pct(Stats.Guess),
                Stats.Interior and (" · tiles no number touches " .. UI.pct(Stats.Interior)) or ""))
        PerfLabel:SetText(("Last solve %.1f ms\n%s"):format(Stats.SolveMs, Stats.Global))
    end)
end

-- Markers tab
do
    local Tab = Window:AddTab("Markers", "eye", "How proven tiles look")
    local SafeBox = Tab:AddLeftGroupbox("Safe tiles", "shield-check")
    UI.color(UI.toggle(SafeBox, "ShowSafe", "Show safe tiles", "ShowSafe", nil, UI.redraw), "SafeColor", "Safe colour", "SafeColor")
    UI.choice(SafeBox, "SafeMethod", "Look", "SafeMethod", METHODS, "Highlight only draws about 30 at once (an engine limit); the others have no limit", UI.redraw)

    local MineBox = Tab:AddRightGroupbox("Mines", "bomb")
    UI.color(UI.toggle(MineBox, "ShowMines", "Show mines", "ShowMines", nil, UI.redraw), "MineColor", "Mine colour", "MineColor")
    UI.choice(MineBox, "MineMethod", "Look", "MineMethod", METHODS, "Highlight only draws about 30 at once (an engine limit); the others have no limit", UI.redraw)

    local ExtraBox = Tab:AddLeftGroupbox("More", "sparkles")
    UI.color(UI.toggle(ExtraBox, "ShowWrongFlags", "Wrong flags", "ShowWrongFlags",
        "A flag on a tile the numbers prove safe", UI.redraw), "WrongFlagColor", "Wrong flag colour", "WrongFlagColor")
    UI.toggle(ExtraBox, "ShowChances", "Chance on undecided tiles", "ShowChances",
        "The real chance of a mine on each tile next to a number, counting the board's mines when it can", UI.redraw)
    UI.color(UI.toggle(ExtraBox, "ShowBestGuess", "Mark the best guess", "ShowBestGuess",
        "When nothing is proven, the tile with the lowest chance of a mine, including tiles no number touches", UI.redraw), "GuessColor", "Guess colour", "GuessColor")

    local OverlayBox = Tab:AddRightGroupbox("Board overlay", "layers")
    UI.toggle(OverlayBox, "ShowOwners", "Who placed each flag", "ShowOwners",
        "A name over every flag. Wrong flags say so")
    UI.choice(OverlayBox, "NumberOverlay", "Numbers", "NumberOverlay", { "Off", "Challenges only", "Always" },
        "Draws every revealed number in clear colours from what was read, so numbers that fade (Disappearance) or are recoloured (Confusion) stay readable. The fatal number (Vigilant) is pink")
    UI.toggle(OverlayBox, "ShowFire", "Burning tiles", "ShowFire", "Scorching: tiles on fire get an orange box", UI.redraw)

    local LookBox = Tab:AddLeftGroupbox("Look", "palette")
    UI.slider(LookBox, "Transparency", "Transparency", "Transparency", 0, 1, 2, nil, nil, UI.redraw)
    LookBox:AddLabel("The game reports tiles painted exactly pure green or red. Nothing here paints a tile, and the colour pickers never give those two exact colours", true)
end

-- Auto tab
do
    local Tab = Window:AddTab("Auto", "zap", "Flagging and stepping")
    local FlagBox = Tab:AddLeftGroupbox("Auto flag", "flag")
    UI.toggle(FlagBox, "AutoFlag", "Flag proven mines", "AutoFlag", "Flags every proven mine within range, nearest first", function(v)
        if v then
            table.clear(Flagging.ours)
            Flagging.findToken(true)
        end
    end)
    UI.toggle(FlagBox, "FlagChase", "Go to far mines", "FlagChase",
        "When every proven mine is out of reach, teleports onto a revealed tile next to the nearest one. Never onto a hidden tile")
    UI.choice(FlagBox, "FlagMethod", "Method", "FlagMethod", { "Auto", "Token", "ClickDetector" },
        "Token: the game's own flag request with its token. ClickDetector: the game's detector (touch devices). Auto: token, else detector")
    UI.slider(FlagBox, "FlagRange", "Range", "FlagRange", 4, 32, 0, " studs", "The game only accepts flags from under 32 studs away")
    UI.slider(FlagBox, "FlagDelay", "Between flags", "FlagDelay", 0, 0.5, 2, " s")
    local TokenLabel = FlagBox:AddLabel("Token: ...", true)
    local NoteLabel = FlagBox:AddLabel("", true)
    FlagBox:AddButton({
        Text = "Look for the token again",
        Func = function()
            Flagging.token = nil
            Flagging.findToken(true)
            notify("Token: " .. Stats.Token, 4)
        end,
    })

    local StepBox = Tab:AddRightGroupbox("Step on safe tiles", "footprints")
    UI.toggle(StepBox, "StepSafe", "Step on proven safe tiles", "StepSafe",
        "Opens proven safe tiles by stepping on them, nearest first. With auto flag this plays the board out as far as it can be proven")
    UI.choice(StepBox, "StepMethod", "Move by", "StepMethod", { "Teleport", "Walk" })
    UI.slider(StepBox, "StepRange", "Range", "StepRange", 8, 400, 0, " studs")
    UI.slider(StepBox, "StepDelay", "Wait on each tile", "StepDelay", 0.05, 1, 2, " s")

    loop(0.5, function()
        TokenLabel:SetText("Token: " .. tostring(Stats.Token))
        NoteLabel:SetText(Stats.FlagNote ~= "" and ("Auto flag: " .. Stats.FlagNote) or "")
    end)
end

-- Challenges tab
do
    local Tab = Window:AddTab("Challenges", "trophy", "Helpers for each challenge")
    local NowBox = Tab:AddLeftGroupbox("This round", "info")
    local NowLabel = NowBox:AddLabel("...", true)

    local HelpBox = Tab:AddRightGroupbox("Helpers", "wrench")
    UI.toggle(HelpBox, "NoBullets", "No bullets (Bullets)", "NoBullets",
        "Bullets are made and moved by a LocalScript of yours; it's switched off so none appear or hit you")
    UI.toggle(HelpBox, "StopConveyors", "Stop conveyors (Conveyors)", "StopConveyors",
        "Zeroes each tile's push for your character")
    UI.toggle(HelpBox, "SolidTiles", "Solid tiles (Phasing)", "SolidTiles",
        "Tiles around you stay solid for you while the wave passes")
    UI.toggle(HelpBox, "SteadyBoard", "Steady board (Malfunction)", "SteadyBoard",
        "Puts glitching tiles back where they were first seen, for you")
    UI.toggle(HelpBox, "AvoidDanger", "Avoid danger tiles", "AvoidDanger",
        "Go to far mines and Leave danger tiles never pick a burning tile (Scorching) or one showing the fatal number (Vigilant)")
    UI.toggle(HelpBox, "LeaveDanger", "Leave danger tiles", "LeaveDanger",
        "Moves you off a burning tile or the fatal number onto the nearest tile that's neither")
    HelpBox:AddLabel("Disappearance and Confusion: every number read is remembered and drawn clearly with the Numbers overlay (Markers tab, on for these by default). Amoeba is all server side; the solver works as normal", true)

    loop(0.5, function()
        local lines = {}
        for _, name in CHALLENGES do
            local on = Game.challenge(name)
            local extra = ""
            if name == "Vigilant" and on then
                extra = Challenges.fatal and (" · fatal number " .. Challenges.fatal) or " · fatal number not shown yet"
            elseif name == "Scorching" and on then
                local n = 0
                for _, t in Board.list do
                    if t.burning then
                        n += 1
                    end
                end
                extra = (" · %d burning"):format(n)
            end
            table.insert(lines, (on and "● " or "○ ") .. name .. extra)
        end
        NowLabel:SetText(table.concat(lines, "\n"))
    end)
end

-- Game tab
do
    local Tab = Window:AddTab("Game", "settings", "The game's own settings, stats and servers")
    local SetBox = Tab:AddLeftGroupbox("Game settings", "sliders-horizontal")
    for _, s in BOOL_SETTINGS do
        local name = s[1]
        SetBox:AddToggle("GS_" .. name, {
            Text = s[2], Default = false,
            Callback = function(v)
                if not GameSet.syncing then
                    GameSet.setBool(name, v)
                end
            end,
        })
    end
    for _, s in NUM_SETTINGS do
        local name, min, max = s[1], s[3], s[4]
        SetBox:AddSlider("GS_" .. name, {
            Text = s[2], Default = min, Min = min, Max = max, Rounding = max > 1 and 0 or 2,
            Callback = function(v)
                if not GameSet.syncing then
                    GameSet.setNumber(name, (v - min) / (max - min))
                end
            end,
        })
    end
    SetBox:AddLabel("Saved to your account the same way the game's own menu saves them", true)
    -- Pull the current values off the game's own settings page.
    local function sync()
        GameSet.syncing = true
        for _, s in BOOL_SETTINGS do
            local v = GameSet.readBool(s[1])
            local o = Options["GS_" .. s[1]]
            if v ~= nil and o and o.Value ~= v then
                pcall(o.SetValue, o, v)
            end
        end
        for _, s in NUM_SETTINGS do
            local v = GameSet.readNumber(s[1])
            local o = Options["GS_" .. s[1]]
            if v and o then
                local shown = s[3] + v * (s[4] - s[3])
                if math.abs((o.Value or 0) - shown) > 0.011 then
                    pcall(o.SetValue, o, shown)
                end
            end
        end
        GameSet.syncing = false
    end
    task.delay(2, function()
        if alive() then
            pcall(sync)
        end
    end)

    local StatBox = Tab:AddRightGroupbox("Your stats", "bar-chart-3")
    local StatLabel = StatBox:AddLabel("Press refresh", true)
    local function refreshStats()
        StatLabel:SetText("Loading...")
        task.spawn(function()
            local text = GameSet.stats()
            if alive() then
                StatLabel:SetText(text)
            end
        end)
    end
    StatBox:AddButton({ Text = "Refresh stats", Func = refreshStats })
    task.delay(3, function()
        if alive() then
            refreshStats()
        end
    end)

    local ServerBox = Tab:AddRightGroupbox("Servers", "server")
    local ServerDrop = ServerBox:AddDropdown("ServerPick", {
        Text = "Server", Values = {}, Searchable = true,
        Tooltip = "Public infinite servers and pro servers, as the game lists them",
    })
    Servers.onChange = function()
        pcall(ServerDrop.SetValues, ServerDrop, table.clone(Servers.labels))
    end
    ServerBox:AddButton({
        Text = "Refresh servers",
        Func = Servers.refresh,
    })
    ServerBox:AddButton({
        Text = "Join selected",
        Func = function()
            local pick = ServerDrop.Value
            local join = pick and Servers.list[pick]
            if join then
                notify("Joining " .. pick, 4)
                pcall(join)
            else
                notify("Pick a server first", 3)
            end
        end,
    })

    local SafetyBox = Tab:AddLeftGroupbox("Votekick and AFK", "shield")
    UI.toggle(SafetyBox, "VoteAlert", "Votekick alerts", "VoteAlert",
        "A notice for every votekick. One aimed at you is always shown, since the game hides those from you")
    UI.toggle(SafetyBox, "AutoVoteNo", "Vote no on votekicks", "AutoVoteNo")
    local KickLabel = SafetyBox:AddLabel("No votekick running", true)
    SafetyBox:AddButton({
        Text = "Vote yes",
        Func = function()
            if Kick.caller then
                Kick.vote(true)
            end
        end,
    }):AddButton({
        Text = "Vote no",
        Func = function()
            if Kick.caller then
                Kick.vote(false)
            end
        end,
    })
    UI.toggle(SafetyBox, "AntiAfk", "Anti AFK", "AntiAfk", "Stops Roblox kicking you for being idle")

    loop(0.5, function()
        if Kick.caller and os.clock() - Kick.at > 16 then
            Kick.caller = nil
        end
        KickLabel:SetText(Kick.caller and ("%s wants to kick %s (%ds left)"):format(Kick.who(Kick.caller), Kick.who(Kick.target),
            math.max(0, 15 - math.floor(os.clock() - Kick.at))) or "No votekick running")
    end)
end

-- Unload
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    Genv.__MSWTokenSink = nil
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for _, c in BoardConns do
        pcall(c.Disconnect, c)
    end
    Draw.clear()
    Overlay.clear()
    Settings.NoBullets, Settings.StopConveyors, Settings.SolidTiles = false, false, false
    pcall(Challenges.bullets)
    pcall(Challenges.conveyorPass)
    pcall(Container.Destroy, Container)
end
Library:OnUnload(cleanup)
Genv.__MinesweeperUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded", 3)

--// Math Wars -- path preview and path creator.
--
-- Built against a script dump of the live game (place 107994348663960, game
-- 10769958564, version 257). How the game turns an equation into a shot, and
-- why the tools here work the way they do:
--
--  * The board is the ground seen from above. MathRoyale.World maps it:
--    math x = world X, math y = -world Z. Shots and the game's own preview
--    are drawn Config.TRACER_H studs above the floor.
--  * MathRoyale.Trajectory.fromExpression(text, x0, y0, facing, maxU) is the
--    game's own tracer. It evaluates f at the offset from you, so the shot is
--    y = y0 + f(x - x0) - f(0), heading the way you face (+1 right, -1 left).
--    Constants in f don't matter, only its shape. Your origin is your
--    HumanoidRootPart (World.toMath) plus Config.MUZZLE_Y_OFFSET, and the
--    range is cut at the shrinking edge, Remotes.State "DomainHalf".
--  * The preview traces whatever is in the equation box with that same
--    tracer, all the way to where it stops, and draws it on the board.
--  * The path creator records one drag on the board (screen point -> ray ->
--    the board plane), keeps it moving one way in x (a shot can't go back),
--    and writes the line you drew as a*x + sum c*abs(x - k), which follows a
--    drawn line exactly. Simplify drops the least important corners and rounds
--    harder. Every equation is checked with the game's own compiler and traced
--    with its tracer, so the error it shows is the real one.
--  * The camera only pans on presses the game hasn't handled, so while you
--    draw a full-screen layer takes the press, and the camera is held still
--    on top of that so the drawing lines up with the board.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__MathWarsStop) == "function" then pcall(Genv.__MathWarsStop) end

local Unloaded = false
local Connections = {}
local function track(c) Connections[#Connections + 1] = c return c end

--// the game's modules -------------------------------------------------------

local MR = ReplicatedStorage:WaitForChild("MathRoyale", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, r = pcall(require, inst)
    return ok and r or nil
end

local Config = safeRequire(MR and MR:FindFirstChild("Config")) or {}
local World = safeRequire(MR and MR:FindFirstChild("World"))
local Trajectory = safeRequire(MR and MR:FindFirstChild("Trajectory"))
local MathExpression = safeRequire(MR and MR:FindFirstChild("MathExpression"))

local ARENA = Config.ARENA or { XMIN = -150, XMAX = 150, YMIN = -100, YMAX = 100 }
local TRACER_H = Config.TRACER_H or 2.5
local MUZZLE = Config.MUZZLE_Y_OFFSET or 0
local FLOOR_Y = (World and World.FLOOR_Y) or 0
local PLANE_Y = FLOOR_Y + TRACER_H

local function toWorld(x, y, h)
    if World and World.toWorld then return World.toWorld(x, y, h) end
    return Vector3.new(x, FLOOR_Y + (h or 0), -y)
end

local function toMath(pos)
    if World and World.toMath then return World.toMath(pos) end
    return pos.X, -pos.Z
end

-- the equation box's own module, found in memory so it's never run twice
local GraphInput
local function graphInput()
    if GraphInput then return GraphInput end
    if typeof(getgc) == "function" then
        local ok, list = pcall(getgc, true)
        if ok and type(list) == "table" then
            for _, v in ipairs(list) do
                if type(v) == "table" and type(rawget(v, "getFacing")) == "function" and type(rawget(v, "getText")) == "function" then
                    GraphInput = v
                    return v
                end
            end
        end
    end
    return nil
end

local CachedBox
local function equationBox()
    if CachedBox and CachedBox.Parent then return CachedBox end
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d:IsA("TextBox") and tostring(d.PlaceholderText):find("Enter expression", 1, true) then
            CachedBox = d
            return d
        end
    end
    return nil
end

local function typedText()
    local gi = graphInput()
    if gi then
        local ok, t = pcall(gi.getText)
        if ok and type(t) == "string" then return t end
    end
    local box = equationBox()
    return box and box.Text or ""
end

local function facing()
    local gi = graphInput()
    if gi then
        local ok, f = pcall(gi.getFacing)
        if ok and (f == 1 or f == -1) then return f end
    end
    return 1
end

-- trials draw the board shifted by the trial's own offset
local function boardOffset()
    if LocalPlayer:GetAttribute("InTrial") ~= nil then
        return LocalPlayer:GetAttribute("TrialOX") or 0, LocalPlayer:GetAttribute("TrialOY") or 0
    end
    return 0, 0
end

local function origin()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local x, y = toMath(root.Position)
    local ox, oy = boardOffset()
    return x - ox, y + MUZZLE - oy
end

local function maxRange(x0, f)
    local state = MR and MR:FindFirstChild("Remotes") and MR.Remotes:FindFirstChild("State")
    local half = state and state:GetAttribute("DomainHalf")
    if type(half) ~= "number" then return nil end
    return math.max(0, f > 0 and (half - x0) or (x0 + half))
end

local function trace(text, x0, y0, f)
    if not Trajectory or type(text) ~= "string" or text:match("^%s*$") then return nil, "nothing typed" end
    local ok, path, info = pcall(Trajectory.fromExpression, text, x0, y0, f, maxRange(x0, f))
    if not ok then return nil, tostring(path) end
    if not path then return nil, type(info) == "table" and tostring(info.err or "doesn't compile") or "doesn't compile" end
    return path
end

local function compiles(text)
    if not MathExpression or not MathExpression.compile then return true end
    local ok, r = pcall(MathExpression.compile, text, true)
    return ok and type(r) == "table" and r.ok == true, ok and type(r) == "table" and r.err or nil
end

--// drawing on the board ---------------------------------------------------------

local Folder = Instance.new("Folder")
Folder.Name = "PathToolsPreview"
Folder.Parent = Workspace

local function newPool(color, width, lift)
    return { Parts = {}, Used = 0, Color = color, Width = width, Lift = lift }
end

local Pools = {
    Typed = newPool(Color3.fromRGB(255, 214, 64), 0.55, 0.06),
    Made = newPool(Color3.fromRGB(64, 220, 255), 0.7, 0.1),
    Drag = newPool(Color3.fromRGB(255, 255, 255), 0.45, 0.14),
}

local function poolPart(pool, i)
    local p = pool.Parts[i]
    if not p then
        p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.CastShadow = false
        p.Material = Enum.Material.Neon
        p.Name = "PathLine"
        p.Parent = Folder
        pool.Parts[i] = p
    end
    return p
end

-- points: list of {x, y} on the board (trial offset added here)
local function drawPoints(pool, points)
    local ox, oy = boardOffset()
    local used = 0
    local last
    for _, pt in ipairs(points) do
        local w = toWorld(pt[1] + ox, pt[2] + oy, TRACER_H + pool.Lift)
        if not last or pt.Break then
            last = w
        elseif (w - last).Magnitude >= 0.35 and used < 700 then
            used += 1
            local p = poolPart(pool, used)
            p.Color = pool.Color
            p.Size = Vector3.new(pool.Width, 0.12, (w - last).Magnitude + 0.05)
            p.CFrame = CFrame.lookAt((last + w) / 2, w)
            p.Transparency = 0.15
            last = w
        end
    end
    for i = used + 1, pool.Used do
        local p = pool.Parts[i]
        if p then p.Transparency = 1 end
    end
    pool.Used = used
end

local function clearPool(pool) drawPoints(pool, {}) end

local function pathPoints(path)
    local pts = {}
    for i = 1, path.n do
        local pt = { path.xs[i], path.ys[i] }
        if i > 1 and path.branches and path.branches[i] ~= path.branches[i - 1] then pt.Break = true end
        pts[#pts + 1] = pt
    end
    return pts
end

--// path creator: drag -> polyline -> equation ------------------------------------

local Made = {
    Raw = nil,        -- relative polyline {{u, v}, ...} starting at {0, 0}
    Facing = 1,
    Level = 0,        -- how far Simplify has gone
    Text = nil,
    Snap = true,      -- aim at the player your drag ends on
    Mode = "follow",  -- "aim" when there's a target, else follow the drawing
    Aim = nil :: any,         -- aim options for the target (aimOptions)
    Route = nil :: any,       -- the route on show
    NoAimFor = nil :: any,    -- the player no short shot reached
    FollowCache = nil :: any, -- tracer-checked picks per Simplify level
    LockAim = true,   -- pin the launch angle and the end point
    Candidates = nil, -- fitted options for this drag
    Angle0 = 0,       -- the drawn launch angle, degrees
}

-- Ramer-Douglas-Peucker on a polyline, tolerance in board units
local function simplifyLine(pts, tol)
    if #pts <= 2 then return pts end
    local keep = { [1] = true, [#pts] = true }
    local stack = { { 1, #pts } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local a, b = seg[1], seg[2]
        local ax, ay, bx, by = pts[a][1], pts[a][2], pts[b][1], pts[b][2]
        local dx, dy = bx - ax, by - ay
        local len = math.sqrt(dx * dx + dy * dy)
        local worst, at = 0, nil
        for i = a + 1, b - 1 do
            local px, py = pts[i][1], pts[i][2]
            local d
            if len < 1e-9 then
                d = math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
            else
                d = math.abs(dy * px - dx * py + bx * ay - by * ax) / len
            end
            if d > worst then worst, at = d, i end
        end
        if at and worst > tol then
            keep[at] = true
            stack[#stack + 1] = { a, at }
            stack[#stack + 1] = { at, b }
        end
    end
    local out = {}
    for i = 1, #pts do if keep[i] then out[#out + 1] = pts[i] end end
    return out
end

local function fmt(n, dec)
    local m = 10 ^ dec
    local r = math.floor(math.abs(n) * m + 0.5) / m
    local s = ("%." .. dec .. "f"):format(r)
    if dec > 0 then s = s:gsub("0+$", ""):gsub("%.$", "") end
    return s, r
end

-- a polyline (u ascending in the facing direction, starting at 0,0) as
-- a*x + sum c*abs(x - k): the slope on each piece is what you drew
local function polylineToText(poly, dec)
    local n = #poly
    local slopes = {}
    for i = 1, n - 1 do
        local du = poly[i + 1][1] - poly[i][1]
        slopes[i] = (poly[i + 1][2] - poly[i][2]) / du
    end
    local m = #slopes
    if m == 0 then return "0" end
    local terms = {}
    local function add(coef, body)
        local s, r = fmt(coef, dec)
        if r == 0 then return end
        local sign = coef < 0 and "-" or "+"
        if s == "1" then s = "" end
        terms[#terms + 1] = { sign, s .. body }
    end
    add((slopes[1] + slopes[m]) / 2, "x")
    for i = 2, m do
        local k = poly[i][1]
        local ks, kr = fmt(k, dec)
        local inner
        if kr == 0 then inner = "x" else inner = "x" .. (k < 0 and "+" or "-") .. ks end
        add((slopes[i] - slopes[i - 1]) / 2, "abs(" .. inner .. ")")
    end
    if #terms == 0 then return "0" end
    local out = {}
    for i, t in ipairs(terms) do
        if i == 1 then out[1] = (t[1] == "-" and "-" or "") .. t[2] else out[#out + 1] = t[1] .. t[2] end
    end
    return table.concat(out)
end

local function lineYAt(poly, u)
    for i = 1, #poly - 1 do
        local a, b = poly[i], poly[i + 1]
        if u >= a[1] - 1e-9 and u <= b[1] + 1e-9 then
            local t = (b[1] - a[1]) ~= 0 and (u - a[1]) / (b[1] - a[1]) or 0
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return nil
end

-- the real error: trace the equation and compare it to what was drawn
local function measure(text, rawLine, x0, y0, f)
    local path, err = trace(text, x0, y0, f)
    if not path then return nil, err end
    local worst, last = 0, 0
    for i = 1, path.n do
        local u = (path.xs[i] - x0) * f
        local want = lineYAt(rawLine, u)
        if want then
            worst = math.max(worst, math.abs((path.ys[i] - y0) - want))
            last = math.max(last, u)
        end
    end
    return path, nil, worst, last
end

--// fitting ---------------------------------------------------------------------------
-- Simplify used to just drop drawn points and join the rest, so it followed
-- every wobble of your finger and lost the launch angle. Now each option is
-- fitted: bent lines get their corners placed by least squares, smooth drags
-- also get short polynomial forms, and with "Lock aim" the launch angle (taken
-- from the first stretch of the drag) and the end point are pinned exactly.
-- Every option is scored with the game's own compiled function, and each
-- Simplify picks the shortest one inside the next error budget.

-- least squares: the c minimising |rows * c - rhs|^2
local function solveLS(rows, rhs, n)
    if n == 0 then return {} end
    local M, v = {}, {}
    for i = 1, n do M[i] = table.create(n, 0) v[i] = 0 end
    for r, row in ipairs(rows) do
        local b = rhs[r]
        for i = 1, n do
            local ri = row[i]
            if ri ~= 0 then
                v[i] += ri * b
                local Mi = M[i]
                for j = 1, n do Mi[j] += ri * row[j] end
            end
        end
    end
    for i = 1, n do M[i][i] += 1e-9 end
    for col = 1, n do
        local piv, best = col, math.abs(M[col][col])
        for r = col + 1, n do
            if math.abs(M[r][col]) > best then piv, best = r, math.abs(M[r][col]) end
        end
        if best < 1e-14 then return nil end
        M[col], M[piv] = M[piv], M[col]
        v[col], v[piv] = v[piv], v[col]
        for r = col + 1, n do
            local k = M[r][col] / M[col][col]
            if k ~= 0 then
                for c = col, n do M[r][c] -= k * M[col][c] end
                v[r] -= k * v[col]
            end
        end
    end
    local x = table.create(n, 0)
    for i = n, 1, -1 do
        local sum = v[i]
        for j = i + 1, n do sum -= M[i][j] * x[j] end
        x[i] = sum / M[i][i]
    end
    return x
end

-- the launch slope (rise per unit forward) over the first stretch of the
-- drag, up to the first corner you drew if that comes sooner
local function launchSlope(raw)
    local total = raw[#raw][1]
    local reach = math.max(2, math.min(12, total * 0.12))
    local fine = simplifyLine(raw, 0.3)
    if #fine > 2 and fine[2][1] <= reach + 1 then reach = math.max(1, fine[2][1]) end
    local suv, suu = 0, 0
    for _, p in ipairs(raw) do
        if p[1] > 0 and p[1] <= reach then
            suv += p[1] * p[2]
            suu += p[1] * p[1]
        end
    end
    if suu == 0 then
        local p = raw[2]
        return p[2] / p[1], math.min(reach, p[1])
    end
    return suv / suu, reach
end

-- heights at fixed corner positions (u) that fit the drag best; fixed[j]
-- pins a corner's height
local function fitBroken(raw, knots, fixed)
    local m = #knots
    local index, n = {}, 0
    for j = 1, m do
        if fixed[j] == nil then n += 1 index[j] = n end
    end
    local rows, rhs = {}, {}
    local seg = 1
    for _, p in ipairs(raw) do
        local u = p[1]
        while seg < m - 1 and u > knots[seg + 1] do seg += 1 end
        local a, b = knots[seg], knots[seg + 1]
        local w = b > a and math.clamp((u - a) / (b - a), 0, 1) or 0
        local row = table.create(n, 0)
        local target = p[2]
        if index[seg] then row[index[seg]] += 1 - w else target -= (1 - w) * fixed[seg] end
        if index[seg + 1] then row[index[seg + 1]] += w else target -= w * fixed[seg + 1] end
        rows[#rows + 1], rhs[#rhs + 1] = row, target
    end
    local sol = solveLS(rows, rhs, n)
    if not sol then return nil end
    local ys = {}
    for j = 1, m do ys[j] = fixed[j] or sol[index[j]] end
    return ys
end

-- f(x) = sum c_k (x/S)^k, k = 1..deg. Locked: c_1 is the launch slope and
-- the end point gets a heavy row so the curve lands where the drag ended.
local function fitPoly(rawSigned, deg, S, slopeX, lock, endX, endY)
    local free = {}
    for k = (lock and 2 or 1), deg do free[#free + 1] = k end
    local n = #free
    local c1 = lock and slopeX * S or nil
    local rows, rhs = {}, {}
    local function addRow(x, y, weight)
        local t = x / S
        local row = table.create(n, 0)
        for i, k in ipairs(free) do row[i] = weight * t ^ k end
        local target = y
        if c1 then target -= c1 * t end
        rows[#rows + 1], rhs[#rhs + 1] = row, weight * target
    end
    for _, p in ipairs(rawSigned) do addRow(p[1], p[2], 1) end
    if lock then addRow(endX, endY, 40) end
    local sol = solveLS(rows, rhs, n)
    if not sol then return nil end
    local c = {}
    if c1 then c[1] = c1 end
    for i, k in ipairs(free) do c[k] = sol[i] end
    for k = 1, deg do c[k] = c[k] or 0 end
    return c
end

local function joinTerms(terms)
    if #terms == 0 then return "0" end
    local out = {}
    for i, t in ipairs(terms) do
        if i == 1 then out[1] = (t[1] == "-" and "-" or "") .. t[2] else out[#out + 1] = t[1] .. t[2] end
    end
    return table.concat(out)
end

local function polyToText(c, S, dec)
    local terms = {}
    for k = 1, #c do
        local coef, body = c[k], nil
        if k == 1 then coef, body = coef / S, "x" else body = "(x/" .. S .. ")^" .. k end
        local str, r = fmt(coef, dec)
        if r ~= 0 then
            if str == "1" then str = "" end
            terms[#terms + 1] = { coef < 0 and "-" or "+", str .. body }
        end
    end
    return joinTerms(terms)
end

-- how far an equation is from the drag (the game's own compiled function,
-- shifted the way the tracer shifts it), and its launch angle
local function score(text, sample, F, endX, endY)
    if not MathExpression or not MathExpression.compile then return nil end
    pcall(function() if MathExpression.beginTrace then MathExpression.beginTrace() end end)
    local okc, c = pcall(MathExpression.compile, text, true)
    if not okc or type(c) ~= "table" or not c.ok or type(c.fn) ~= "function" then return nil end
    local f0 = tonumber(c.f0) or 0
    local worst = 0
    for _, p in ipairs(sample) do
        local ok, y = pcall(c.fn, p[1])
        if not ok or type(y) ~= "number" or y ~= y or math.abs(y) == math.huge then return nil end
        worst = math.max(worst, math.abs((y - f0) - p[2]))
    end
    local probe = 0.25
    local ok1, y1 = pcall(c.fn, F * probe)
    local angle = (ok1 and type(y1) == "number") and math.deg(math.atan((y1 - f0) / probe)) or nil
    local okE, yE = pcall(c.fn, endX)
    local endErr = (okE and type(yE) == "number") and math.abs((yE - f0) - endY) or math.huge
    return worst, angle, endErr
end

local function buildCandidates()
    local raw, F, lock = Made.Raw, Made.Facing, Made.LockAim
    local total = raw[#raw][1]
    local endV = raw[#raw][2]
    local s0, reach = launchSlope(raw)

    local sample = {}
    local step = math.max(1, math.floor(#raw / 300))
    for i = 1, #raw, step do sample[#sample + 1] = { raw[i][1] * F, raw[i][2] } end
    sample[#sample + 1] = { total * F, endV }

    local list, seen = {}, {}
    local function consider(text, kind, pieces)
        if seen[text] or #text > 1000 then return end
        seen[text] = true
        local worst, angle, endErr = score(text, sample, F, total * F, endV)
        if worst then list[#list + 1] = { Text = text, Err = worst, Angle = angle, EndErr = endErr, Kind = kind, Pieces = pieces } end
    end

    -- bent lines: corners from the drawing, heights fitted
    local lastKey
    for _, tol in ipairs({ 0.15, 0.3, 0.6, 1.2, 2.5, 5, 10, 20, 40, 1e9 }) do
        local knots = {}
        for _, p in ipairs(simplifyLine(raw, tol)) do knots[#knots + 1] = p[1] end
        local fixed = { [1] = 0 }
        if lock then
            -- a straight launch piece at the drawn angle, no corner inside it
            local k2 = { 0 }
            if reach < total - 0.5 then k2[2] = reach end
            for _, u in ipairs(knots) do
                -- a corner right at the launch piece's end is that end
                if u > k2[#k2] + 0.5 and u < total - 1e-6 then k2[#k2 + 1] = u end
            end
            k2[#k2 + 1] = total
            knots = k2
            if #knots > 2 then fixed[2] = s0 * knots[2] end
            fixed[#knots] = endV
        end
        local key = table.concat(knots, ",")
        if key ~= lastKey then
            lastKey = key
            local ys = fitBroken(raw, knots, fixed)
            if ys then
                local poly = {}
                for j, u in ipairs(knots) do poly[j] = { u * F, ys[j] } end
                if F < 0 then
                    local rev = {}
                    for i = #poly, 1, -1 do rev[#rev + 1] = poly[i] end
                    poly = rev
                end
                for dec = 0, 3 do consider(polylineToText(poly, dec), "line", #knots - 1) end
            end
        end
    end

    -- smooth curves
    local S = 10 * math.max(1, math.floor(total / 10 + 0.5))
    local rawSigned = {}
    for i = 1, #raw, step do rawSigned[#rawSigned + 1] = { raw[i][1] * F, raw[i][2] } end
    for deg = 1, 6 do
        local c = fitPoly(rawSigned, deg, S, s0 * F, lock, total * F, endV)
        if c then
            for dec = 0, 3 do consider(polyToText(c, S, dec), "curve", deg) end
        end
    end

    Made.Candidates = list
    Made.Angle0 = math.deg(math.atan(s0))
    return list
end

local BUDGETS = { 0.5, 1, 2, 4, 8, 16, 32, 64 }

-- every option in the order Simplify takes them at this level: inside the
-- budget shortest first (aim kept when locked), then the rest, closest first
local function rankedCandidates(level)
    local list = Made.Candidates or buildCandidates()
    local budget = BUDGETS[math.clamp(level + 1, 1, #BUDGETS)]
    local function aimOk(c)
        return not Made.LockAim or (c.Angle and math.abs(c.Angle - Made.Angle0) <= 0.75 and c.EndErr <= 1.5)
    end
    local inside, rest = {}, {}
    for _, c in ipairs(list) do
        if aimOk(c) and c.Err <= budget then inside[#inside + 1] = c else rest[#rest + 1] = c end
    end
    table.sort(inside, function(a, b)
        if #a.Text ~= #b.Text then return #a.Text < #b.Text end
        return a.Err < b.Err
    end)
    table.sort(rest, function(a, b)
        local aa, ba = aimOk(a), aimOk(b)
        if aa ~= ba then return aa end
        return a.Err < b.Err
    end)
    for _, c in ipairs(rest) do inside[#inside + 1] = c end
    return inside
end

--// the board: blocks and players ----------------------------------------------------
-- Blocks are parts under workspace.Arena with a "Cell" or "ObstacleId"
-- attribute (what the game's own teleport check looks for); a shot stops at
-- the first one. Players are workspace models with a "CombatantId" and HP
-- left, hit within Config.HITBOX_RADIUS of their PrimaryPart, and a shot can
-- go through several of them.

local HITBOX = Config.HITBOX_RADIUS or 2.8
local HASH = 4

local function buildBlocks()
    local grid = {}
    local arena = Workspace:FindFirstChild("Arena")
    if not arena then return grid end
    local ox, oy = boardOffset()
    for _, d in ipairs(arena:GetDescendants()) do
        if d:IsA("BasePart") and (d:GetAttribute("Cell") ~= nil or d:GetAttribute("ObstacleId") ~= nil) then
            local cf, size = d.CFrame, d.Size
            local function half(axis)
                return (math.abs(cf.RightVector[axis]) * size.X + math.abs(cf.UpVector[axis]) * size.Y
                    + math.abs(cf.LookVector[axis]) * size.Z) / 2
            end
            local hx, hy, hz = half("X"), half("Y"), half("Z")
            local pos = cf.Position
            if pos.Y - hy <= PLANE_Y and pos.Y + hy >= PLANE_Y then
                local rect = { pos.X - hx - ox, pos.X + hx - ox, -(pos.Z + hz) - oy, -(pos.Z - hz) - oy }
                for gx = math.floor((rect[1] - 0.5) / HASH), math.floor((rect[2] + 0.5) / HASH) do
                    for gy = math.floor((rect[3] - 0.5) / HASH), math.floor((rect[4] + 0.5) / HASH) do
                        local key = gx * 1000 + gy
                        local cell = grid[key]
                        if not cell then cell = {} grid[key] = cell end
                        cell[#cell + 1] = rect
                    end
                end
            end
        end
    end
    return grid
end

local function blockAt(grid, x, y, margin)
    local cell = grid[math.floor(x / HASH) * 1000 + math.floor(y / HASH)]
    if not cell then return false end
    for _, r in ipairs(cell) do
        if x >= r[1] - margin and x <= r[2] + margin and y >= r[3] - margin and y <= r[4] + margin then return true end
    end
    return false
end

local function combatants()
    local mine = LocalPlayer:GetAttribute("CombatantId")
    local ox, oy = boardOffset()
    local out = {}
    for _, m in ipairs(Workspace:GetChildren()) do
        local id = m:GetAttribute("CombatantId")
        if id ~= nil and id ~= mine and m:IsA("Model") and (m:GetAttribute("HP") or 1) > 0 and m.PrimaryPart then
            local x, y = toMath(m.PrimaryPart.Position)
            out[#out + 1] = { Model = m, Name = m.Name, X = x - ox, Y = y - oy + (Config.HITBOX_Y_OFFSET or 0) }
        end
    end
    return out
end

-- the player your drag ends on, or failing that the first one it runs through
local function targetOfDrag(raw, F)
    local x0, y0 = origin()
    if not x0 then return nil end
    local people = combatants()
    local ex, ey = x0 + raw[#raw][1] * F, y0 + raw[#raw][2]
    local best, bestD
    for _, c in ipairs(people) do
        local d = math.sqrt((c.X - ex) ^ 2 + (c.Y - ey) ^ 2)
        if d <= HITBOX + 8 and (not bestD or d < bestD) then best, bestD = c, d end
    end
    if best then return best end
    for _, q in ipairs(raw) do
        local px, py = x0 + q[1] * F, y0 + q[2]
        for _, c in ipairs(people) do
            if (px - c.X) ^ 2 + (py - c.Y) ^ 2 <= (HITBOX + 1) ^ 2 then return c end
        end
    end
    return nil
end

-- fly a traced path: who it goes through, and the first block that stops it
local function walkPath(path, grid, people)
    local hits = {}
    for i = 2, path.n do
        local ax, ay, bx, by = path.xs[i - 1], path.ys[i - 1], path.xs[i], path.ys[i]
        local steps = math.max(1, math.ceil(math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / 0.4))
        for st = 1, steps do
            local t = st / steps
            local px, py = ax + (bx - ax) * t, ay + (by - ay) * t
            for _, c in ipairs(people) do
                if not hits[c] and (px - c.X) ^ 2 + (py - c.Y) ^ 2 <= HITBOX ^ 2 then hits[c] = i end
            end
            if blockAt(grid, px, py, 0.2) then return hits, i, px, py end
        end
    end
    return hits
end

-- the game's tracer on an equation, cut where it would hit a block
local function flight(text, x0, y0, F, grid, people)
    local path, err = trace(text, x0, y0, F)
    if not path or path.n < 2 then return nil, err or "no path" end
    local hits, stopAt, sx, sy = walkPath(path, grid, people)
    return { Path = path, Hits = hits, StopAt = stopAt, StopX = sx, StopY = sy }
end

local function flightPoints(f)
    local pts = pathPoints(f.Path)
    if f.StopAt then
        for i = #pts, f.StopAt, -1 do pts[i] = nil end
        pts[#pts + 1] = { f.StopX, f.StopY }
    end
    return pts
end

--// short equations that hit a target ----------------------------------------------

-- a bent line in signed x as text, plus a function made from the very same
-- rounded numbers (so a check on it is a check on what you'll type)
local function brokenForm(poly, dec)
    local m = #poly - 1
    local slopes = {}
    for i = 1, m do slopes[i] = (poly[i + 1][2] - poly[i][2]) / (poly[i + 1][1] - poly[i][1]) end
    local terms, A, parts = {}, 0, {}
    local function value(n)
        local str, r = fmt(n, dec)
        return str, (n < 0 and -r or r)
    end
    local function add(coef, body, knot)
        local str, v = value(coef)
        if v == 0 then return end
        terms[#terms + 1] = { coef < 0 and "-" or "+", (str == "1" and "" or str) .. body }
        if knot then parts[#parts + 1] = { v, knot } else A = v end
    end
    if m >= 1 then add((slopes[1] + slopes[m]) / 2, "x") end
    for i = 2, m do
        local k = poly[i][1]
        local ks, kv = value(k)
        local inner = kv == 0 and "x" or ("x" .. (k < 0 and "+" or "-") .. ks)
        add((slopes[i] - slopes[i - 1]) / 2, "abs(" .. inner .. ")", kv)
    end
    local text = joinTerms(terms)
    return text, function(x)
        local y = A * x
        for _, t in ipairs(parts) do y += t[1] * math.abs(x - t[2]) end
        return y
    end
end

-- f(x) = a x + B (x/10)^2
local function arcForm(a, b, dec)
    local B = b * 100
    local as, av = fmt(a, dec)
    local bs, bv = fmt(B, dec)
    av = a < 0 and -av or av
    bv = B < 0 and -bv or bv
    local terms = {}
    if av ~= 0 then terms[#terms + 1] = { a < 0 and "-" or "+", (as == "1" and "" or as) .. "x" } end
    if bv ~= 0 then terms[#terms + 1] = { B < 0 and "-" or "+", (bs == "1" and "" or bs) .. "(x/10)^2" } end
    return joinTerms(terms), function(x) return av * x + bv * (x / 10) ^ 2 end
end

-- a quick flight of fn from you: does it reach the target before a block or
-- the edge of the board? (steep stretches are stepped through finely)
local function quickShot(fn, F, x0, y0, grid, target, maxU)
    local f0 = fn(0)
    local reach = (HITBOX - 0.6) ^ 2
    local px, py, u = x0, y0, 0
    while u < maxU do
        u = math.min(maxU, u + 0.5)
        local y = y0 + fn(F * u) - f0
        if y ~= y or y < ARENA.YMIN or y > ARENA.YMAX then return false end
        local x = x0 + F * u
        local steps = math.max(1, math.ceil(math.abs(y - py) / 0.5))
        for st = 1, steps do
            local t = st / steps
            local sx, sy = px + (x - px) * t, py + (y - py) * t
            if (sx - target.X) ^ 2 + (sy - target.Y) ^ 2 <= reach then return true end
            if blockAt(grid, sx, sy, 0.35) then return false end
        end
        px, py = x, y
    end
    return false
end

local function signedPoly(uPts, F)
    local poly = {}
    for i, q in ipairs(uPts) do poly[i] = { q[1] * F, q[2] } end
    if F < 0 then
        local rev = {}
        for i = #poly, 1, -1 do rev[#rev + 1] = poly[i] end
        poly = rev
    end
    return poly
end

-- every short shape that gets to the target, shortest first
local function aimOptions(target)
    local x0, y0 = origin()
    if not x0 then return nil, "no character" end
    local dx, dy = target.X - x0, target.Y - y0
    local F = dx >= 0 and 1 or -1
    if math.abs(dx) < 0.5 then F = Made.Facing end
    local du = math.max(0.5, math.abs(dx))
    local grid = buildBlocks()
    local edge = F > 0 and (ARENA.XMAX - x0) or (x0 - ARENA.XMIN)
    local maxU = math.min(du + HITBOX + 3, maxRange(x0, F) or math.huge, edge)
    local ylo, yhi = ARENA.YMIN - y0 + 2, ARENA.YMAX - y0 - 2
    local raw = Made.Raw

    local shapes = {}
    local function bent(uPts, label) shapes[#shapes + 1] = { Poly = signedPoly(uPts, F), Label = label } end
    bent({ { 0, 0 }, { du, dy } }, "straight")
    for _, fk in ipairs({ 0.15, 0.3, 0.45, 0.6, 0.75, 0.9 }) do
        for h = ylo, yhi, 4 do bent({ { 0, 0 }, { du * fk, h }, { du, dy } }, "one bend") end
    end
    -- arcs through you and the target, leaving at every angle
    local tx = F * du
    for deg = -80, 80, 4 do
        local a = F * math.tan(math.rad(deg))
        shapes[#shapes + 1] = { Arc = { a, (dy - a * tx) / (tx * tx) }, Label = "arc" }
    end
    -- routes with your drawing's bends, ending on the target
    if raw then
        local corners = {}
        for _, q in ipairs(simplifyLine(raw, 4)) do
            if q[1] > 1 and q[1] < du - 1 then corners[#corners + 1] = q end
        end
        while #corners > 2 do table.remove(corners, #corners) end
        if #corners > 0 then
            for _, shift in ipairs({ 0, 6, -6, 12, -12 }) do
                local pts = { { 0, 0 } }
                for _, q in ipairs(corners) do pts[#pts + 1] = { q[1], q[2] + shift } end
                pts[#pts + 1] = { du, dy }
                bent(pts, #corners == 1 and "one bend" or "two bends")
            end
        end
    end

    local function drawnGap(fn)
        if not raw then return 0 end
        local f0, sum, n = fn(0), 0, 0
        for _, q in ipairs(raw) do
            if q[1] <= du then
                sum += math.abs((fn(F * q[1]) - f0) - q[2])
                n += 1
            end
        end
        return n > 0 and sum / n or 0
    end

    local found = {}
    for i, sh in ipairs(shapes) do
        if i % 40 == 0 then task.wait() end
        local makeForm
        if sh.Poly then
            makeForm = function(dec) return brokenForm(sh.Poly, dec) end
        else
            makeForm = function(dec) return arcForm(sh.Arc[1], sh.Arc[2], dec) end
        end
        local _, exact = makeForm(6)
        if quickShot(exact, F, x0, y0, grid, target, maxU) then
            for dec = 0, 3 do
                local text, fn = makeForm(dec)
                if quickShot(fn, F, x0, y0, grid, target, maxU) then
                    found[#found + 1] = { Text = text, Label = sh.Label, Gap = drawnGap(fn) }
                    break
                end
            end
        end
    end
    -- shortest first; between ones about as short, the one nearer your drawing
    local function rank(c) return #c.Text + math.min(c.Gap, 40) * 0.08 end
    table.sort(found, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.Gap < b.Gap
    end)
    return { List = found, F = F, X0 = x0, Y0 = y0, Grid = grid, Target = target, Next = 1 }
end

-- the next option the game's own tracer agrees hits the target
local function nextAimRoute(aim)
    local seen = aim.Seen or {}
    aim.Seen = seen
    while aim.Next <= #aim.List do
        local c = aim.List[aim.Next]
        aim.Next += 1
        if not seen[c.Text] then
            seen[c.Text] = true
            if compiles(c.Text) then
                local f = flight(c.Text, aim.X0, aim.Y0, aim.F, aim.Grid, { aim.Target })
                if f and f.Hits[aim.Target] then
                    c.Flight = f
                    return c
                end
            end
        end
        if aim.Next % 6 == 0 then task.wait() end
    end
    return nil
end

--// following the drawing -------------------------------------------------------------

-- the first option at this Simplify level that the game's tracer flies all
-- the way (no early stop), and that misses every block your drawing missed
local function followPick(level)
    Made.FollowCache = Made.FollowCache or {}
    if Made.FollowCache[level] then return Made.FollowCache[level] end
    local raw, F = Made.Raw, Made.Facing
    local total = raw[#raw][1]
    local x0, y0 = origin()
    local grid = x0 and buildBlocks() or {}
    local drawnClear = true
    if x0 then
        for i = 2, #raw do
            if blockAt(grid, x0 + raw[i][1] * F, y0 + raw[i][2], 0.2) then drawnClear = false break end
        end
    end
    local first
    for i, c in ipairs(rankedCandidates(level)) do
        if i > 25 then break end
        first = first or c
        if not x0 then Made.FollowCache[level] = { C = c } return Made.FollowCache[level] end
        local f = flight(c.Text, x0, y0, F, grid, {})
        if f then
            local far = math.abs(f.Path.xs[f.Path.n] - x0)
            local diesEarly = f.Path.termination == "undefined" and far < total - 1
            local blocked = drawnClear and f.StopAt and math.abs(f.StopX - x0) < total - 1
            if not diesEarly and not blocked then
                Made.FollowCache[level] = { C = c, Flight = f }
                return Made.FollowCache[level]
            end
        end
        if i % 5 == 0 then task.wait() end
    end
    Made.FollowCache[level] = first and { C = first } or nil
    return Made.FollowCache[level]
end

local function buildEquation()
    local raw = Made.Raw
    if not raw or #raw < 2 then return nil, "draw a longer path" end
    if Made.Mode == "aim" and Made.Aim then
        local route = Made.Route or nextAimRoute(Made.Aim)
        Made.Route = route
        if route then
            return {
                Mode = "aim", Text = route.Text, Label = route.Label, Path = route.Flight.Path,
                Points = flightPoints(route.Flight), Target = Made.Aim.Target, Facing = Made.Aim.F,
            }
        end
        Made.Mode = "follow"
        Made.NoAimFor = Made.Aim.Target.Name
    end
    local pick = followPick(Made.Level)
    if not pick then return nil, "couldn't fit an equation the game accepts" end
    local c = pick.C
    local result = {
        Mode = "follow", Text = c.Text, Kind = c.Kind, Pieces = c.Pieces, Worst = c.Err,
        Angle = c.Angle, Angle0 = Made.Angle0, Facing = Made.Facing,
    }
    local x0, y0 = origin()
    if pick.Flight then
        result.Path = pick.Flight.Path
        result.Points = flightPoints(pick.Flight)
        result.Blocked = pick.Flight.StopAt ~= nil
        local _, _, worst = measure(c.Text, raw, x0, y0, Made.Facing)
        if worst then result.Worst = worst end
    end
    return result
end

--// mini ui --------------------------------------------------------------------

local Gui = Instance.new("ScreenGui")
Gui.Name = "PathTools"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = true
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.DisplayOrder = 50
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    Gui.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end

local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local THEME = {
    Bg = Color3.fromRGB(22, 24, 32), Bar = Color3.fromRGB(32, 36, 48), Btn = Color3.fromRGB(44, 50, 66),
    On = Color3.fromRGB(46, 140, 220), Text = Color3.fromRGB(235, 238, 245), Dim = Color3.fromRGB(150, 158, 175),
}

-- the layer that takes the drag while armed (under the mini ui)
local Capture = make("TextButton", {
    Name = "Capture", Text = "", AutoButtonColor = false, Active = true, Modal = false,
    BackgroundColor3 = Color3.fromRGB(64, 220, 255), BackgroundTransparency = 0.94,
    Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 1, BorderSizePixel = 0,
}, Gui)
make("TextLabel", {
    Text = "Drag your path on the board", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = THEME.Text,
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0, 60), ZIndex = 2,
    TextStrokeTransparency = 0.5,
}, Capture)

local Panel = make("Frame", {
    Name = "Panel", BackgroundColor3 = THEME.Bg, BorderSizePixel = 0,
    Size = UDim2.fromOffset(276, 316), Position = UDim2.fromOffset(24, 120), ZIndex = 10, Active = true,
}, Gui)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, Panel)
make("UIStroke", { Color = Color3.fromRGB(70, 80, 105), Thickness = 1 }, Panel)

local Bar = make("Frame", {
    BackgroundColor3 = THEME.Bar, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 30), ZIndex = 11, Active = true,
}, Panel)
make("UICorner", { CornerRadius = UDim.new(0, 10) }, Bar)
make("TextLabel", {
    Text = "Path tools", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.Text, BackgroundTransparency = 1,
    Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(12, 0), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 12,
}, Bar)
local Collapse = make("TextButton", {
    Text = "–", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = THEME.Text, BackgroundTransparency = 1,
    Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -30, 0, 0), ZIndex = 12,
}, Bar)

local Body = make("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, -16, 1, -38), Position = UDim2.fromOffset(8, 34), ZIndex = 10,
}, Panel)

local function button(text, x, y, w)
    local b = make("TextButton", {
        Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = THEME.Text, AutoButtonColor = true,
        BackgroundColor3 = THEME.Btn, BorderSizePixel = 0, Size = UDim2.fromOffset(w or 126, 28), Position = UDim2.fromOffset(x, y), ZIndex = 11,
    }, Body)
    make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    return b
end

local CreateBtn = button("Create path", 0, 0)
local SimplifyBtn = button("Simplify", 134, 0)
local CopyBtn = button("Copy", 0, 34)
local ClearBtn = button("Clear", 134, 34)
local PreviewBtn = button("Preview typed: on", 0, 68)
local SnapBtn = button("Snap to enemy: on", 134, 68)
local LockBtn = button("Lock aim: on", 0, 102)
local GuideBtn = button("Key guide: off", 134, 102)
local GuideInfo = make("TextLabel", {
    Text = "key guide: yellow = tap now, purple = tap after", Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = THEME.Dim,
    BackgroundTransparency = 1, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 134), ZIndex = 11,
}, Body)

local Status = make("TextLabel", {
    Text = "Press Create path, then drag on the board.", Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = THEME.Dim,
    BackgroundTransparency = 1, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    Size = UDim2.new(1, 0, 0, 42), Position = UDim2.fromOffset(0, 156), ZIndex = 11,
}, Body)

local Output = make("TextBox", {
    Text = "", PlaceholderText = "your equation shows up here", Font = Enum.Font.Code, TextSize = 13, TextColor3 = THEME.Text,
    PlaceholderColor3 = THEME.Dim, BackgroundColor3 = Color3.fromRGB(14, 16, 22), BorderSizePixel = 0, TextWrapped = true,
    ClearTextOnFocus = false, TextEditable = false, MultiLine = true, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 70), Position = UDim2.fromOffset(0, 202), ZIndex = 11,
}, Body)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, Output)
make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }, Output)

-- keep the panel fully on screen, whatever it's dragged to or the screen does
local function clampPanel()
    local view = Gui.AbsoluteSize
    local size = Panel.AbsoluteSize
    local pos = Panel.AbsolutePosition
    local x = math.clamp(pos.X, 0, math.max(0, view.X - size.X))
    local y = math.clamp(pos.Y, 0, math.max(0, view.Y - size.Y))
    Panel.Position = UDim2.fromOffset(x, y)
end
track(Gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(clampPanel))
track(Panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(clampPanel))
task.defer(clampPanel)

do
    local dragging, startInput, startPos, startPanel
    track(Bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, startInput = true, input
            startPos = Vector2.new(input.Position.X, input.Position.Y)
            startPanel = Panel.AbsolutePosition
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input == startInput or input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = Vector2.new(input.Position.X, input.Position.Y) - startPos
            local view, size = Gui.AbsoluteSize, Panel.AbsoluteSize
            local x = math.clamp(startPanel.X + delta.X, 0, math.max(0, view.X - size.X))
            local y = math.clamp(startPanel.Y + delta.Y, 0, math.max(0, view.Y - size.Y))
            Panel.Position = UDim2.fromOffset(x, y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if dragging and (input == startInput or input.UserInputType == Enum.UserInputType.MouseButton1) then dragging = false end
    end))
end

local collapsed = false
track(Collapse.Activated:Connect(function()
    collapsed = not collapsed
    Body.Visible = not collapsed
    Collapse.Text = collapsed and "+" or "–"
    Panel.Size = collapsed and UDim2.fromOffset(276, 30) or UDim2.fromOffset(276, 316)
    clampPanel()
end))

local function setStatus(text, color)
    Status.Text = text
    Status.TextColor3 = color or THEME.Dim
end

local function faceName(f) return f > 0 and "right" or "left" end

local solveDrag

local function showResult()
    local r, err = buildEquation()
    if not r then
        Made.Text = nil
        Output.Text = ""
        setStatus(err, Color3.fromRGB(255, 110, 110))
        clearPool(Pools.Made)
        return
    end
    Made.Text = r.Text
    Output.Text = r.Text
    if r.Points then
        drawPoints(Pools.Made, r.Points)
    elseif r.Path then
        drawPoints(Pools.Made, pathPoints(r.Path))
    else
        clearPool(Pools.Made)
    end
    SimplifyBtn.Text = r.Mode == "aim" and "Other route" or "Simplify"
    local face = ("face %s%s"):format(faceName(r.Facing), facing() ~= r.Facing and " (flip your facing!)" or "")
    if r.Mode == "aim" then
        setStatus(("hits %s · %s · %d chars · %s"):format(r.Target.Name, r.Label, #r.Text, face), Color3.fromRGB(120, 230, 140))
        return
    end
    local shape
    if r.Kind == "curve" then
        shape = r.Pieces == 1 and "straight line" or ("smooth curve (power %d)"):format(r.Pieces)
    else
        shape = ("%d-piece line"):format(r.Pieces or 1)
    end
    local parts = { face, ("%s, %d chars"):format(shape, #r.Text) }
    if Made.NoAimFor then table.insert(parts, 1, "no clear short shot at " .. Made.NoAimFor .. ", following your drawing") end
    if r.Angle then
        parts[#parts + 1] = ("launch %+.1f° (drew %+.1f°)%s"):format(r.Angle, r.Angle0 or 0, Made.LockAim and " locked" or "")
    end
    if r.Worst then parts[#parts + 1] = ("off by at most %.2f"):format(r.Worst) end
    if r.Blocked then parts[#parts + 1] = "hits a block on the way" end
    if r.TraceError then parts[#parts + 1] = "trace: " .. tostring(r.TraceError) end
    setStatus(table.concat(parts, " · "), THEME.Text)
end

-- work the last drag out again: aim at the player it ends on if there is
-- one (and snapping is on), else follow the drawing
solveDrag = function()
    if not Made.Raw then return end
    Made.Level, Made.Candidates, Made.FollowCache = 0, nil, nil
    Made.Aim, Made.Route, Made.NoAimFor, Made.Mode = nil, nil, nil, "follow"
    setStatus("Working it out...", THEME.Dim)
    task.spawn(function()
        local target = Made.Snap and targetOfDrag(Made.Raw, Made.Facing)
        if target then
            setStatus("Aiming at " .. target.Name .. "...", THEME.Dim)
            local aim = aimOptions(target)
            if aim then Made.Aim, Made.Mode = aim, "aim" end
        end
        showResult()
    end)
end

--// capturing the drag ------------------------------------------------------------

local Armed, Dragging = false, false
local DragInput
local DragPoints = {}    -- board points of the drag
local PinnedCFrame

local function screenToBoard(pos)
    local ray = Workspace.CurrentCamera:ScreenPointToRay(pos.X, pos.Y)
    if math.abs(ray.Direction.Y) < 1e-6 then return nil end
    local t = (PLANE_Y - ray.Origin.Y) / ray.Direction.Y
    if t <= 0 then return nil end
    local hit = ray.Origin + ray.Direction * t
    local x, y = toMath(hit)
    local ox, oy = boardOffset()
    return x - ox, y - oy
end

local function setArmed(on)
    Armed = on
    Capture.Visible = on
    CreateBtn.Text = on and "Cancel" or "Create path"
    CreateBtn.BackgroundColor3 = on and THEME.On or THEME.Btn
    if on then setStatus("Drag your path now. It starts when you press and ends when you let go.", THEME.Text) end
end

local function pinCamera(on)
    if on then
        PinnedCFrame = Workspace.CurrentCamera.CFrame
        pcall(function()
            RunService:BindToRenderStep("PathToolsHoldCamera", Enum.RenderPriority.Camera.Value + 50, function()
                if PinnedCFrame then Workspace.CurrentCamera.CFrame = PinnedCFrame end
            end)
        end)
    else
        PinnedCFrame = nil
        pcall(function() RunService:UnbindFromRenderStep("PathToolsHoldCamera") end)
    end
end

-- turn the drag into a polyline that only moves forward, starting at you
local function dragToRaw()
    local x0, y0 = origin()
    if not x0 or #DragPoints < 2 then return nil end
    local first, last = DragPoints[1], DragPoints[#DragPoints]
    local f = (last[1] - first[1]) >= 0 and 1 or -1
    -- if you started on your character, the direction you moved away wins
    if math.abs(last[1] - x0) > math.abs(last[1] - first[1]) then f = (last[1] - x0) >= 0 and 1 or -1 end
    local raw = { { 0, 0 } }
    local reach = 0
    local minStep = 0.5
    for _, p in ipairs(DragPoints) do
        local u = (p[1] - x0) * f
        if u > reach + minStep then
            raw[#raw + 1] = { u, p[2] - y0 }
            reach = u
        end
    end
    if #raw < 2 then return nil end
    -- keep it inside the board
    for _, p in ipairs(raw) do p[2] = math.clamp(p[2], ARENA.YMIN - y0, ARENA.YMAX - y0) end
    return raw, f
end

local function finishDrag()
    if not Dragging then return end
    Dragging = false
    DragInput = nil
    pinCamera(false)
    setArmed(false)
    clearPool(Pools.Drag)
    local raw, f = dragToRaw()
    if not raw then
        setStatus("That drag was too short (or went backwards). Press Create path and try again.", Color3.fromRGB(255, 170, 90))
        return
    end
    Made.Raw, Made.Facing = raw, f
    solveDrag()
end

track(Capture.InputBegan:Connect(function(input)
    if not Armed or Dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    Dragging = true
    DragInput = input
    table.clear(DragPoints)
    pinCamera(true)
    local x, y = screenToBoard(input.Position)
    if x then DragPoints[1] = { x, y } end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if not Dragging then return end
    local same = input == DragInput
        or (DragInput and DragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
    if not same then return end
    local x, y = screenToBoard(input.Position)
    if not x then return end
    local last = DragPoints[#DragPoints]
    if last and (math.abs(last[1] - x) + math.abs(last[2] - y)) < 0.25 then return end
    if #DragPoints < 3000 then DragPoints[#DragPoints + 1] = { x, y } end
    drawPoints(Pools.Drag, DragPoints)
end))

track(UserInputService.InputEnded:Connect(function(input)
    if not Dragging then return end
    if input == DragInput or (DragInput and DragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1) then
        finishDrag()
    end
end))

--// buttons ---------------------------------------------------------------------

track(CreateBtn.Activated:Connect(function()
    if Dragging then return end
    setArmed(not Armed)
    if not Armed then setStatus("Cancelled.", THEME.Dim) end
end))

track(SimplifyBtn.Activated:Connect(function()
    if not Made.Raw then setStatus("Make a path first.", THEME.Dim) return end
    task.spawn(function()
        -- aiming: the next route the game's tracer agrees hits (round again
        -- from the shortest once they run out)
        if Made.Mode == "aim" and Made.Aim then
            local route = nextAimRoute(Made.Aim)
            if not route then
                Made.Aim.Next, Made.Aim.Seen = 1, nil
                route = nextAimRoute(Made.Aim)
            end
            if route then
                Made.Route = route
                showResult()
            else
                setStatus("No other route hits " .. Made.Aim.Target.Name .. ".", Color3.fromRGB(255, 170, 90))
            end
            return
        end
        -- following: step up until the pick actually gets shorter
        local current = followPick(Made.Level)
        local level = Made.Level
        while level < #BUDGETS - 1 do
            level += 1
            local nextPick = followPick(level)
            if nextPick and current and #nextPick.C.Text < #current.C.Text then
                Made.Level = level
                showResult()
                return
            end
        end
        setStatus("That's as simple as it gets for this drag.", Color3.fromRGB(255, 170, 90))
    end)
end))

track(CopyBtn.Activated:Connect(function()
    if not Made.Text then setStatus("Nothing to copy yet.", THEME.Dim) return end
    local copy = (typeof(setclipboard) == "function" and setclipboard) or (typeof(toclipboard) == "function" and toclipboard)
    if copy then
        pcall(copy, Made.Text)
        setStatus("Copied. Paste or type it into the equation box.", THEME.Text)
    else
        setStatus("No clipboard in this executor; type it from the box below.", Color3.fromRGB(255, 170, 90))
    end
end))

track(ClearBtn.Activated:Connect(function()
    Made.Raw, Made.Text, Made.Level, Made.Candidates, Made.FollowCache = nil, nil, 0, nil, nil
    Made.Aim, Made.Route, Made.NoAimFor, Made.Mode = nil, nil, nil, "follow"
    SimplifyBtn.Text = "Simplify"
    Output.Text = ""
    clearPool(Pools.Made)
    clearPool(Pools.Drag)
    setStatus("Cleared.", THEME.Dim)
end))

local PreviewOn = true
track(PreviewBtn.Activated:Connect(function()
    PreviewOn = not PreviewOn
    PreviewBtn.Text = "Preview typed: " .. (PreviewOn and "on" or "off")
    PreviewBtn.BackgroundColor3 = PreviewOn and THEME.Btn or Color3.fromRGB(60, 40, 44)
    if not PreviewOn then clearPool(Pools.Typed) end
end))

track(LockBtn.Activated:Connect(function()
    Made.LockAim = not Made.LockAim
    LockBtn.Text = "Lock aim: " .. (Made.LockAim and "on" or "off")
    LockBtn.BackgroundColor3 = Made.LockAim and THEME.Btn or Color3.fromRGB(60, 40, 44)
    if Made.Raw then solveDrag() end
end))

track(SnapBtn.Activated:Connect(function()
    Made.Snap = not Made.Snap
    SnapBtn.Text = "Snap to enemy: " .. (Made.Snap and "on" or "off")
    SnapBtn.BackgroundColor3 = Made.Snap and THEME.Btn or Color3.fromRGB(60, 40, 44)
    if Made.Raw then solveDrag() end
end))

--// live preview of what's typed ------------------------------------------------------

task.spawn(function()
    local lastKey
    while not Unloaded do
        if PreviewOn then
            local text = typedText()
            local x0, y0 = origin()
            local f = facing()
            if x0 then
                local key = ("%s|%.2f|%.2f|%d|%s"):format(text, x0, y0, f, tostring(maxRange(x0, f)))
                if key ~= lastKey then
                    lastKey = key
                    local path = trace(text, x0, y0, f)
                    if path then drawPoints(Pools.Typed, pathPoints(path)) else clearPool(Pools.Typed) end
                end
            end
        else
            lastKey = nil
        end
        task.wait(0.15)
    end
end)

--// key guide -------------------------------------------------------------------------
-- The game's touch keypad (MathKeypad) is a Numbers pad that's always up
-- (digits, x, ., UNDO, left, right) and a Functions pad with three pages
-- (TRIG, POWERS, SYMBOLS) that its SwitchPage button steps through. Every key
-- is a button with a "Key" attribute, the display keeps the caret in its
-- "Cursor" attribute, and function keys type "name()" with the caret inside.
-- On a phone the keypad only shows once the equation is opened (OpenEquation).
-- The guide works out every press that types the equation, using the
-- keypad's own edit rules, then reads what's in the box and where the caret
-- is to know how far along you are, and outlines the next thing to tap: the
-- open button, the page switch, or the key.

local PAGES = { "TRIG", "POWERS", "SYMBOLS" }
local KEY_FUNCS = {
    sin = true, cos = true, tan = true, arcsin = true, arccos = true, arctan = true,
    tanh = true, abs = true, sqrt = true, log = true, ln = true, exp = true,
}
local KEY_NAMES = {
    left = "←", right = "→", undo = "UNDO", clear = "CLR", sqrt = "√", ["-"] = "−", ["*"] = "×", ["/"] = "÷",
}

-- the keypad's own edit(text, cursor, key), found in memory
local KeypadEdit
local function findKeypadEdit()
    if KeypadEdit or typeof(getgc) ~= "function" then return KeypadEdit end
    local ok, list = pcall(getgc, true)
    if ok and type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "table" and type(rawget(v, "edit")) == "function" and type(rawget(v, "mount")) == "function" then
                KeypadEdit = v.edit
                break
            end
        end
    end
    return KeypadEdit
end

-- the same rules, for the keys the guide uses, if it can't be found
local function copyEdit(text, cursor, key)
    local len = utf8.len(text) or #text
    cursor = math.clamp(cursor, 0, len)
    if key == "left" then return text, math.max(0, cursor - 1) end
    if key == "right" then return text, math.min(len, cursor + 1) end
    if key == "clear" then return "", 0 end
    local split = utf8.offset(text, cursor + 1) or #text + 1
    local before, after = text:sub(1, split - 1), text:sub(split)
    if key == ")" and after:sub(1, 1) == ")" then return text, cursor + 1 end
    if key == "x" and before:sub(-1) == "x" and after:sub(1, 1) == ")" then
        before, after, cursor = before .. ")", after:sub(2), cursor + 1
    end
    local insert, step = key, #key
    if key == "(" then
        insert, step = "()", 1
    elseif key:match("^[a-z]+$") and key ~= "x" and key ~= "pi" and key ~= "e" then
        insert, step = key .. "()", #key + 1
    end
    return before .. insert .. after, cursor + step
end

local function keypadEdit(text, cursor, key)
    local e = findKeypadEdit()
    if e then
        local ok, t, c = pcall(e, text, cursor, key)
        if ok and type(t) == "string" and type(c) == "number" then return t, c end
    end
    return copyEdit(text, cursor, key)
end

-- every press that types target from an empty box, and the box after each
local function planFor(target)
    local keys, states = {}, { { "", 0 } }
    local text, cursor = "", 0
    for _ = 1, 4000 do
        if cursor >= #target and text == target then break end
        local rest = target:sub(cursor + 1)
        local name = rest:match("^(%a+)%(")
        local key
        if name and KEY_FUNCS[name] then
            key = name
        elseif rest:sub(1, 1) == ")" then
            key = "right" -- the bracket's already there, step past it
        else
            local ch = rest:sub(1, 1)
            if not ch:match("[%d%.x%+%-%*/%^%(]") then return nil, "the keypad can't type '" .. ch .. "'" end
            key = ch
        end
        text, cursor = keypadEdit(text, cursor, key)
        keys[#keys + 1] = key
        states[#states + 1] = { text, cursor }
        if text:sub(1, cursor) ~= target:sub(1, cursor) then return nil, "couldn't plan the presses" end
    end
    if text ~= target then return nil, "couldn't plan the presses" end
    return { Keys = keys, States = states, Target = target }
end

local Guide = { On = false, Plan = nil, StuckText = nil, StuckSince = 0 }

local Mark = make("Frame", {
    Name = "GuideMark", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 60, Active = false,
}, nil)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, Mark)
local MarkStroke = make("UIStroke", {
    Color = Color3.fromRGB(255, 226, 70), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, Mark)
local MarkFill = make("Frame", {
    BackgroundColor3 = Color3.fromRGB(255, 226, 70), BackgroundTransparency = 0.7, Size = UDim2.fromScale(1, 1),
    ZIndex = 59, Active = false, BorderSizePixel = 0,
}, Mark)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, MarkFill)

-- the tap after that: a purple ring just outside the button, so it still
-- shows when it's the same button as the yellow one (a key twice in a row,
-- or the page switch twice)
local MarkNext = make("Frame", {
    Name = "GuideMarkNext", BackgroundTransparency = 1, Size = UDim2.new(1, 10, 1, 10),
    Position = UDim2.fromOffset(-5, -5), ZIndex = 61, Active = false,
}, nil)
make("UICorner", { CornerRadius = UDim.new(0, 11) }, MarkNext)
local MarkNextStroke = make("UIStroke", {
    Color = Color3.fromRGB(176, 92, 255), Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, MarkNext)

local function markOn(btn)
    if Mark.Parent ~= btn then Mark.Parent = btn end
end
local function markNextOn(btn)
    if MarkNext.Parent ~= btn then MarkNext.Parent = btn end
end
local function markNextOff() MarkNext.Parent = nil end
local function markOff()
    Mark.Parent = nil
    markNextOff()
end

track(RunService.RenderStepped:Connect(function()
    if not Mark.Parent then return end
    local pulse = (math.sin(os.clock() * 7) + 1) / 2
    MarkStroke.Transparency = 0.1 + pulse * 0.35
    MarkFill.BackgroundTransparency = 0.55 + pulse * 0.35
    MarkNextStroke.Transparency = 0.15 + (1 - pulse) * 0.3
end))

local Keypad
local function keypadFrame()
    if Keypad and Keypad.Parent then return Keypad end
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d.Name == "MathKeypad" and d:IsA("Frame") and d:FindFirstChild("Numbers") and d:FindFirstChild("Functions") then
            Keypad = d
            return d
        end
    end
    return nil
end

local function findNamed(name, class)
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, d in ipairs(gui and gui:GetDescendants() or {}) do
        if d.Name == name and d:IsA(class) then return d end
    end
    return nil
end

local function shown(gui)
    while gui and gui:IsA("GuiObject") do
        if not gui.Visible then return false end
        gui = gui.Parent
    end
    return true
end

-- the button to tap for a key: the key if it's up, else the page switch
-- (toward whichever page has it in the fewest taps)
local function buttonFor(kp, key)
    local functions = kp:FindFirstChild("Functions")
    local current = table.find(PAGES, functions and functions:GetAttribute("Page") or "") or 3
    local bestPage, bestTaps
    for _, b in ipairs(kp:GetDescendants()) do
        if b:IsA("GuiButton") and b:GetAttribute("Key") == key then
            if shown(b) then return b, nil, 0 end
            local index = tonumber(b.Name:match("^Key(%d+)$"))
            if index and index > 15 then
                local page = (index - 16) // 12 + 1
                local taps = (page - current) % #PAGES
                if not bestTaps or taps < bestTaps then bestPage, bestTaps = page, taps end
            end
        end
    end
    if bestPage then
        local switch = functions and functions:FindFirstChild("SwitchPage")
        return switch, PAGES[bestPage], bestTaps
    end
    return nil, nil, 0
end

local function commonPrefix(a, b)
    local n = 0
    while n < #a and n < #b and a:sub(n + 1, n + 1) == b:sub(n + 1, n + 1) do n += 1 end
    return n
end

-- what to press next, as a key value (or "done"), plus why
local function nextKey(text, cursor)
    local plan = Guide.Plan
    local keys, states = plan.Keys, plan.States
    for k = #states, 1, -1 do
        local st = states[k]
        if st[1] == text and (cursor == nil or st[2] == cursor) then
            if k - 1 >= #keys then return "done" end
            return keys[k], nil, k - 1
        end
    end
    -- right text, caret somewhere else: walk it back into place
    for k = #states, 1, -1 do
        local st = states[k]
        if st[1] == text and cursor ~= nil then
            return cursor < st[2] and "right" or "left", "move the caret back"
        end
    end
    -- something else is in the box. UNDO walks back to where it went wrong;
    -- if it's nothing like the equation, or UNDO has run out, clear it.
    if Guide.StuckText ~= text then Guide.StuckText, Guide.StuckSince = text, os.clock() end
    if #text > 0 and (commonPrefix(text, plan.Target) == 0 or os.clock() - Guide.StuckSince > 4) then
        return "clear", "the box has something else in it"
    end
    return "undo", "that isn't what the equation needs"
end

local function setInfo(text, color)
    GuideInfo.Text = text
    GuideInfo.TextColor3 = color or THEME.Dim
end

local function guideStep()
    local target = Made.Text
    if not target then markOff() setInfo("make a path first") return end
    if not Guide.Plan or Guide.Plan.Target ~= target then
        local plan, err = planFor(target)
        if not plan then markOff() setInfo(err, Color3.fromRGB(255, 110, 110)) return end
        Guide.Plan = plan
    end

    local box = equationBox()
    local text = box and box.Text or typedText()
    local kp = keypadFrame()

    -- no keypad on screen: on a phone the equation has to be opened first;
    -- on a keyboard there's nothing to tap, so say what to type
    if not kp or not shown(kp) then
        if UserInputService.TouchEnabled then
            local open = findNamed("OpenEquation", "GuiButton")
            if open and shown(open) then
                markOn(open)
                setInfo("tap to open the equation", THEME.Text)
                return
            end
            markOff()
            setInfo("the keypad shows up on your turn")
            return
        end
        markOff()
        local done = commonPrefix(text, target)
        if text == target then setInfo("all typed, fire!", Color3.fromRGB(120, 230, 140)) return end
        setInfo(done == #text and ("type: " .. target:sub(done + 1)) or "box doesn't match, fix it", THEME.Text)
        return
    end
    if LocalPlayer:GetAttribute("AdvancedMode") == true then
        markOff()
        setInfo("turn advanced mode off to use the guide", Color3.fromRGB(255, 170, 90))
        return
    end

    local display = findNamed("MathDisplay", "GuiButton")
    local cursor = display and display:GetAttribute("Cursor")
    local key, why, doneCount = nextKey(text, type(cursor) == "number" and cursor or nil)
    if key == "done" then
        markOff()
        setInfo("all typed, fire!", Color3.fromRGB(120, 230, 140))
        return
    end
    local btn, page, taps = buttonFor(kp, key)
    if not btn then markOff() setInfo("can't find the " .. (KEY_NAMES[key] or key) .. " key") return end
    markOn(btn)
    local label = KEY_NAMES[key] or key
    if page then
        -- still on the wrong page: purple says tap the switch again, if it
        -- takes more than one
        if taps >= 2 then markNextOn(btn) else markNextOff() end
        setInfo(("switch page to %s (for %s)%s"):format(page, label, taps >= 2 and ", twice" or ""), THEME.Text)
    elseif why then
        markNextOff()
        setInfo(("%s: tap %s"):format(why, label), Color3.fromRGB(255, 170, 90))
    else
        local plan = Guide.Plan
        -- the key after this one (or the page switch it'll need)
        local after = doneCount and plan.Keys[doneCount + 2]
        local afterBtn = after and buttonFor(kp, after)
        if afterBtn then markNextOn(afterBtn) else markNextOff() end
        local afterLabel = after and (KEY_NAMES[after] or after)
        setInfo(("tap %s%s  (%d/%d)"):format(label, afterLabel and (", then " .. afterLabel) or "", (doneCount or 0) + 1, #plan.Keys), THEME.Text)
    end
end

track(GuideBtn.Activated:Connect(function()
    Guide.On = not Guide.On
    GuideBtn.Text = "Key guide: " .. (Guide.On and "on" or "off")
    GuideBtn.BackgroundColor3 = Guide.On and THEME.On or THEME.Btn
    if not Guide.On then
        markOff()
        setInfo("highlights the next key")
    end
end))

task.spawn(function()
    while not Unloaded do
        if Guide.On then pcall(guideStep) end
        task.wait(0.1)
    end
end)

--// teardown -------------------------------------------------------------------------

Genv.__MathWarsStop = function()
    if Unloaded then return end
    Unloaded = true
    pinCamera(false)
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)
    pcall(function() Gui:Destroy() end)
    pcall(function() Folder:Destroy() end)
    pcall(function() Mark:Destroy() end)
    pcall(function() MarkNext:Destroy() end)
end

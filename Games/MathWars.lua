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
    EndCut = true,
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

-- extra bits that make the shot stop where the drag ended: f is undefined
-- past the end, and the tracer stops at "undefined". Constants don't move the
-- shot, so the +1 these add changes nothing else.
local function endCuts(e, f, dec)
    local es = fmt(e, dec)
    local inside = f > 0 and (es .. "-x") or ("x+" .. es)
    if f > 0 and e < 0 then inside = "-" .. es .. "-x" end
    if f < 0 and e > 0 then inside = "x-" .. es end
    return {
        "+0sqrt(" .. inside .. ")",
        "+sqrt(" .. inside .. ")^0",
        "+sqrt(" .. inside .. ")/sqrt(" .. inside .. ")",
    }
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
local function measure(text, polyAbs, x0, y0, f)
    local path, err = trace(text, x0, y0, f)
    if not path then return nil, err end
    local worst, last = 0, 0
    for i = 1, path.n do
        local u = (path.xs[i] - x0) * f
        local want = lineYAt(polyAbs, u)
        if want then
            worst = math.max(worst, math.abs((path.ys[i] - y0) - want))
            last = math.max(last, u)
        end
    end
    return path, nil, worst, last
end

local function buildEquation()
    local raw = Made.Raw
    if not raw or #raw < 2 then return nil, "draw a longer path" end
    -- each Simplify doubles how far a corner can be from the line before
    -- it's dropped
    local tol = 0.35 * 2 ^ Made.Level
    local poly = simplifyLine(raw, tol)
    -- relative u is distance in the facing direction; the equation's x is
    -- the signed offset, so flip back for a left-facing shot
    local signed = {}
    for i, p in ipairs(poly) do signed[i] = { p[1] * Made.Facing, p[2] } end
    if Made.Facing < 0 then
        -- abs terms need knots in x order; a left shot's x runs negative
        local rev = {}
        for i = #signed, 1, -1 do rev[#rev + 1] = signed[i] end
        signed = rev
    end

    -- round as hard as the shot allows: the fewest decimals whose traced
    -- error stays within this level's tolerance (rounding every coefficient
    -- adds up over many corners, so it's measured, not guessed)
    local x0, y0 = origin()
    local allowed = math.max(0.75, tol * 1.5)
    local base, dec
    for tryDec = 0, 3 do
        local text = polylineToText(signed, tryDec)
        if compiles(text) then
            base, dec = text, tryDec
            if not x0 then break end
            local _, _, worst = measure(text, poly, x0, y0, Made.Facing)
            if worst and worst <= allowed then break end
        end
    end
    if not base then
        local _, err = compiles(polylineToText(signed, 3))
        return nil, "the game rejected it: " .. tostring(err)
    end

    if not x0 then return { Text = base, Segments = #poly - 1 } end
    local text = base
    local endsAtDrag = false
    if Made.EndCut then
        local e = poly[#poly][1] * Made.Facing
        for _, cut in ipairs(endCuts(e, Made.Facing, dec)) do
            local candidate = base .. cut
            if compiles(candidate) then
                local path = trace(candidate, x0, y0, Made.Facing)
                if path and path.termination == "undefined" then
                    local reach = math.abs(path.xs[path.n] - x0)
                    if math.abs(reach - poly[#poly][1]) <= 1.5 then
                        text, endsAtDrag = candidate, true
                        break
                    end
                end
            end
        end
    end
    local path, terr, worst, covered = measure(text, poly, x0, y0, Made.Facing)
    return {
        Text = text,
        Path = path,
        TraceError = terr,
        Worst = worst,
        Covered = covered,
        Length = poly[#poly][1],
        Segments = #poly - 1,
        EndsAtDrag = endsAtDrag,
        Decimals = dec,
    }
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
    Size = UDim2.fromOffset(276, 296), Position = UDim2.fromOffset(24, 120), ZIndex = 10, Active = true,
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
local EndBtn = button("Stop at drag end: on", 134, 68)
local GuideBtn = button("Key guide: off", 0, 102)
local GuideInfo = make("TextLabel", {
    Text = "highlights the next key", Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = THEME.Dim,
    BackgroundTransparency = 1, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.fromOffset(126, 28), Position = UDim2.fromOffset(134, 102), ZIndex = 11,
}, Body)

local Status = make("TextLabel", {
    Text = "Press Create path, then drag on the board.", Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = THEME.Dim,
    BackgroundTransparency = 1, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 136), ZIndex = 11,
}, Body)

local Output = make("TextBox", {
    Text = "", PlaceholderText = "your equation shows up here", Font = Enum.Font.Code, TextSize = 13, TextColor3 = THEME.Text,
    PlaceholderColor3 = THEME.Dim, BackgroundColor3 = Color3.fromRGB(14, 16, 22), BorderSizePixel = 0, TextWrapped = true,
    ClearTextOnFocus = false, TextEditable = false, MultiLine = true, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 70), Position = UDim2.fromOffset(0, 184), ZIndex = 11,
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
    Panel.Size = collapsed and UDim2.fromOffset(276, 30) or UDim2.fromOffset(276, 296)
    clampPanel()
end))

local function setStatus(text, color)
    Status.Text = text
    Status.TextColor3 = color or THEME.Dim
end

local function faceName(f) return f > 0 and "right" or "left" end

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
    if r.Path then drawPoints(Pools.Made, pathPoints(r.Path)) end
    local parts = {
        ("face %s%s"):format(faceName(Made.Facing), facing() ~= Made.Facing and " (flip your facing!)" or ""),
        ("%d piece%s, %d chars"):format(r.Segments, r.Segments == 1 and "" or "s", #r.Text),
    }
    if r.Worst then parts[#parts + 1] = ("off by at most %.2f"):format(r.Worst) end
    if r.EndsAtDrag then parts[#parts + 1] = "stops at your drag's end" elseif Made.EndCut then parts[#parts + 1] = "keeps going past the end" end
    if r.TraceError then parts[#parts + 1] = "trace: " .. tostring(r.TraceError) end
    setStatus(table.concat(parts, " · "), THEME.Text)
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
    Made.Raw, Made.Facing, Made.Level = raw, f, 0
    setStatus("Working it out...", THEME.Dim)
    task.spawn(showResult)
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
    Made.Level += 1
    task.spawn(showResult)
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
    Made.Raw, Made.Text, Made.Level = nil, nil, 0
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

track(EndBtn.Activated:Connect(function()
    Made.EndCut = not Made.EndCut
    EndBtn.Text = "Stop at drag end: " .. (Made.EndCut and "on" or "off")
    if Made.Raw then task.spawn(showResult) end
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

local function markOn(btn)
    if Mark.Parent ~= btn then Mark.Parent = btn end
end
local function markOff() Mark.Parent = nil end

track(RunService.RenderStepped:Connect(function()
    if not Mark.Parent then return end
    local pulse = (math.sin(os.clock() * 7) + 1) / 2
    MarkStroke.Transparency = 0.1 + pulse * 0.35
    MarkFill.BackgroundTransparency = 0.55 + pulse * 0.35
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
            if shown(b) then return b, nil end
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
        return switch, PAGES[bestPage]
    end
    return nil, nil
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
            return keys[k]
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
    local key, why = nextKey(text, type(cursor) == "number" and cursor or nil)
    if key == "done" then
        markOff()
        setInfo("all typed, fire!", Color3.fromRGB(120, 230, 140))
        return
    end
    local btn, page = buttonFor(kp, key)
    if not btn then markOff() setInfo("can't find the " .. (KEY_NAMES[key] or key) .. " key") return end
    markOn(btn)
    local label = KEY_NAMES[key] or key
    if page then
        setInfo(("switch page to %s (for %s)"):format(page, label), THEME.Text)
    elseif why then
        setInfo(("%s: tap %s"):format(why, label), Color3.fromRGB(255, 170, 90))
    else
        local plan = Guide.Plan
        local doneCount = 0
        for k = #plan.States, 1, -1 do
            if plan.States[k][1] == text then doneCount = k - 1 break end
        end
        setInfo(("tap %s  (%d/%d)"):format(label, doneCount + 1, #plan.Keys), THEME.Text)
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
end

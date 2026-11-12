--// Blast Soccer ---------------------------------------------------------------------
-- place 137470666387963. Built on Ui3.
--
-- How the game works (as the client sees it):
--   Shot    Remotes.Soundwave:FireServer(origin, aimLook, serverTime, castId,
--           ballCenter) (and the same on SoundwaveU, sent twice for safety).
--           It connects when the ball is inside a cone (Config.Soundwave:
--           Range 22, HalfAngleDegrees 55, Cooldown 0.7).
--   Launch  Shared.BallMath.boopVelocity: the ball leaves at
--             aimLook * LaunchSpeed * falloff(distance)
--             + yourVelocity * InheritCasterVelocity (0.5)
--             + ballVelocity * KeepBallVelocity (0.15)
--           so it flies along your aim, not along the line through it.
--   Flight  Client.BallView: exponential air drag (Config.Ball.AirDrag 0.08)
--           with workspace gravity, sphere-cast bounces against the arena's
--           Geometry, Goals, Walls and Barriers that keep 82% of a hard hit
--           and slide on a soft one, speed capped at Config.Ball.MaxSpeed.
--   Goals   Arena.Goals.<Team>Goal, attribute Team, with a Trigger box.
--   Checks  Config.Validation: the server checks where a shot comes from,
--           its timing and the cooldown, not its aim.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__BlastSoccerUnload then
    pcall(Genv.__BlastSoccerUnload)
end
Genv.__BlastSoccerRun = (Genv.__BlastSoccerRun or 0) + 1
local RUN = Genv.__BlastSoccerRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__BlastSoccerRun == RUN
end

--// Ui3 \\--
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
if not alive() then
    return
end

local Settings = {
    -- prediction
    ShowPath = true, PathSeconds = 3, ShowShot = true, ShowLanding = true, ShowGoal = true,
    PathColor = Color3.fromRGB(240, 240, 255), ShotColor = Color3.fromRGB(255, 200, 60),
    -- speed helper
    SpeedHelp = false, MaxNudge = 12, MinGain = 1,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
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
                warn("[BlastSoccer] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Blast Soccer", Description = text, Time = seconds or 3 })
end
local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

--// The game's numbers \\--
local Config = {}
do
    local ok, c = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
    if ok and type(c) == "table" then
        Config = c
    end
end
local WAVE = Config.Soundwave or {}
local BALL = Config.Ball or {}
local function wave(key, default)
    local v = WAVE[key]
    return type(v) == "number" and v or default
end
local DRAG = type(BALL.AirDrag) == "number" and BALL.AirDrag or 0.08
local MAX_SPEED = type(BALL.MaxSpeed) == "number" and BALL.MaxSpeed or 180

-- The game's smoothed ball (BallView), else the ball part itself.
local BallView
pcall(function()
    local client = LocalPlayer:WaitForChild("PlayerScripts", 5):WaitForChild("Client", 5)
    local mod = client and client:FindFirstChild("BallView")
    if mod then
        local ok, t = pcall(require, mod)
        if ok and type(t) == "table" and t.getPosition then
            BallView = t
        end
    end
end)
local Ball = {}
function Ball.part()
    local b = Workspace:FindFirstChild("Ball")
    return (b and b:IsA("BasePart")) and b or nil
end
function Ball.state()
    if BallView then
        local ok, p, v, r = pcall(function()
            return BallView.getPosition(), BallView.getVelocity(), BallView.getRadius()
        end)
        if ok and typeof(p) == "Vector3" then
            return p, typeof(v) == "Vector3" and v or Vector3.zero, type(r) == "number" and r or 3.5
        end
    end
    local b = Ball.part()
    if b then
        return b.Position, b.AssemblyLinearVelocity, b.Size.X / 2
    end
    return nil
end

--// Physics, the way BallView does it \\--
local Sim = {}
do
    local SOLIDS = { "Geometry", "Goals", "Walls", "Barriers" }
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    local paramsAt = -1
    function Sim.params()
        if os.clock() - paramsAt > 3 then
            paramsAt = os.clock()
            local list = {}
            for _, root in { "Arena", "Practice" } do
                local folder = Workspace:FindFirstChild(root)
                for _, name in SOLIDS do
                    local f = folder and folder:FindFirstChild(name)
                    if f then
                        table.insert(list, f)
                    end
                end
            end
            params.FilterDescendantsInstances = list
        end
        return params
    end
    -- One drag-and-gravity step (the closed form BallView uses).
    function Sim.fly(p, v, dt)
        local k = DRAG
        local gTerm = Vector3.new(0, -Workspace.Gravity / k, 0)
        local e = math.exp(-k * dt)
        local np = p + gTerm * dt + (v - gTerm) * ((1 - e) / k)
        local nv = (v - gTerm) * e + gTerm
        return np, nv
    end
    -- BallView's sweep: a sphere cast along the step; a hard hit (into the
    -- surface faster than 8) bounces keeping 82%, a soft one slides.
    function Sim.sweep(p0, p1, v0, v1, radius)
        local move = p1 - p0
        local dist = move.Magnitude
        if dist < 0.001 then
            return p1, v1, nil
        end
        local hit = Workspace:Spherecast(p0, radius * 0.98, move, Sim.params())
        if not hit then
            return p1, v1, nil
        end
        local n = hit.Normal
        local dir = move / dist
        local rest = dir * (dist - hit.Distance)
        local into = v1:Dot(n)
        local f = v0:Lerp(v1, hit.Distance / dist):Dot(n) < -8 and 1.82 or 1
        local restInto = rest:Dot(n)
        if restInto < 0 then
            rest -= n * (f * restInto)
        end
        if into < 0 then
            v1 -= n * (f * into)
        end
        return p0 + dir * hit.Distance + n * (radius * 0.02) + rest, v1, hit
    end
    -- The path from here: points, the first ground contact, and a goal if
    -- the ball ends up in one.
    function Sim.path(p, v, radius, seconds, dt)
        dt = dt or 1 / 30
        local pts = { p }
        local landing, goal
        for _ = 1, math.floor(seconds / dt) do
            local np, nv = Sim.fly(p, v, dt)
            if nv.Magnitude > MAX_SPEED then
                nv = nv.Unit * MAX_SPEED
            end
            local hit
            np, nv, hit = Sim.sweep(p, np, v, nv, radius)
            if hit and not landing and hit.Normal.Y > 0.6 then
                landing = hit.Position
            end
            p, v = np, nv
            table.insert(pts, p)
            goal = goal or Sim.inGoal(p)
            if goal or v.Magnitude < 1.5 then
                break
            end
        end
        return pts, landing, goal
    end
    function Sim.inGoal(p)
        local arena = Workspace:FindFirstChild("Arena")
        local goals = arena and arena:FindFirstChild("Goals")
        for _, g in goals and goals:GetChildren() or {} do
            local trig = g:FindFirstChild("Trigger")
            if trig and trig:IsA("BasePart") then
                local rel = trig.CFrame:PointToObjectSpace(p)
                local half = trig.Size / 2
                if math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z then
                    return g:GetAttribute("Team") or g.Name
                end
            end
        end
        return nil
    end
end

--// Shots \\--
local Shot = { last = "no shots yet", cache = {} }
do
    local function inCone(origin, look, center, radius)
        local to = center - origin
        local d = to.Magnitude
        if wave("Range", 22) < d - radius then
            return false
        end
        if d <= radius + 0.5 then
            return true
        end
        local angle = math.acos(math.clamp(to.Unit:Dot(look), -1, 1))
        return angle <= math.rad(wave("HalfAngleDegrees", 55)) + math.asin(math.clamp(radius / d, 0, 1))
    end
    Shot.inCone = inCone
    function Shot.myVelocity()
        local r = rootPart()
        return r and r.AssemblyLinearVelocity or Vector3.zero
    end
    -- The ball's velocity right after a hit with this aim (BallMath.boopVelocity).
    function Shot.launch(origin, look, center, radius, ballVel, myVel)
        local d = math.max(0, (center - origin).Magnitude - radius)
        local t = math.clamp(d / wave("Range", 22), 0, 1)
        local speed = wave("LaunchSpeed", 125) * (1 - (1 - wave("FarLaunchFraction", 0.6)) * t)
        return look * speed + myVel * wave("InheritCasterVelocity", 0.5) + ballVel * wave("KeepBallVelocity", 0.15)
    end
    -- The speed helper: turns your aim a little (never more than MaxNudge
    -- degrees) toward the way you and the ball are already moving, which is
    -- where the inherited speed adds the most. Where the shot goes barely
    -- changes; it just comes off faster. If the ball would leave the cone,
    -- the turn is made smaller.
    function Shot.nudge(origin, look, center, radius, ballVel, myVel)
        local carry = myVel * wave("InheritCasterVelocity", 0.5) + ballVel * wave("KeepBallVelocity", 0.15)
        if carry.Magnitude < 1 or look.Magnitude < 0.5 then
            return look, 0, 0
        end
        look = look.Unit
        local want = carry.Unit
        local between = math.acos(math.clamp(look:Dot(want), -1, 1))
        if between < 1e-3 then
            return look, 0, 0
        end
        local base = Shot.launch(origin, look, center, radius, ballVel, myVel).Magnitude
        local axis = look:Cross(want)
        if axis.Magnitude < 1e-6 then
            return look, 0, 0
        end
        axis = axis.Unit
        local maxTurn = math.min(between, math.rad(Settings.MaxNudge))
        for _, frac in { 1, 0.75, 0.5, 0.25 } do
            local turn = maxTurn * frac
            local newLook = (CFrame.fromAxisAngle(axis, turn) * look).Unit
            if inCone(origin, newLook, center, radius) then
                local gain = Shot.launch(origin, newLook, center, radius, ballVel, myVel).Magnitude - base
                if gain >= Settings.MinGain then
                    return newLook, gain, math.deg(turn)
                end
                return look, 0, 0
            end
        end
        return look, 0, 0
    end

    -- Every shot passes through here on its way to the server. The redundant
    -- copies of the same shot (same time stamp) get the same aim.
    function Shot.adjust(origin, look, stamp)
        if not (Settings.SpeedHelp and typeof(origin) == "Vector3" and typeof(look) == "Vector3") then
            return look
        end
        local key = type(stamp) == "number" and stamp or nil
        if key and Shot.cache[key] then
            return Shot.cache[key]
        end
        local center, ballVel, radius = Ball.state()
        local out = look
        if center and inCone(origin, look, center, radius) then
            local newLook, gain, deg = Shot.nudge(origin, look, center, radius, ballVel, Shot.myVelocity())
            if gain > 0 then
                out = newLook
                Shot.last = ("+%d speed, turned %.1f°"):format(math.floor(gain + 0.5), deg)
            else
                Shot.last = "already at its best"
            end
        end
        if key then
            Shot.cache[key] = out
            task.delay(2, function()
                Shot.cache[key] = nil
            end)
        end
        return out
    end
end

-- Hook the two shot remotes. Installed once per session.
local Hook = { status = "not hooked" }
do
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
    local sw = remotes and remotes:FindFirstChild("Soundwave")
    local swu = remotes and remotes:FindFirstChild("SoundwaveU")
    Genv.__BlastSoccerRemotes = { sw, swu }
    Genv.__BlastSoccerAdjust = function(origin, look, stamp)
        if alive() then
            return Shot.adjust(origin, look, stamp)
        end
        return look
    end
    if Genv.__BlastSoccerHooked then
        Hook.status = "hooked"
    elseif typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        local old
        local function handler(self, ...)
            local list = Genv.__BlastSoccerRemotes
            if list and (self == list[1] or self == list[2]) and getnamecallmethod() == "FireServer" then
                local adjust = Genv.__BlastSoccerAdjust
                if adjust then
                    local args = table.pack(...)
                    local ok, newLook = pcall(adjust, args[1], args[2], args[3])
                    if ok and typeof(newLook) == "Vector3" then
                        args[2] = newLook
                    end
                    return old(self, table.unpack(args, 1, args.n))
                end
            end
            return old(self, ...)
        end
        local wrap = typeof(newcclosure) == "function" and newcclosure or function(f)
            return f
        end
        local ok = pcall(function()
            old = hookmetamethod(game, "__namecall", wrap(handler))
        end)
        if ok and old then
            Genv.__BlastSoccerHooked = true
            Hook.status = "hooked"
        else
            Hook.status = "this executor can't hook remotes"
        end
    else
        Hook.status = "this executor can't hook remotes"
    end
    table.insert(Cleanups, function()
        Genv.__BlastSoccerAdjust = nil
    end)
end

--// Drawing the paths \\--
local Draw = { folder = Instance.new("Folder"), pools = {} }
Draw.folder.Name = "BlastSoccerPrediction"
Draw.folder.Parent = Workspace.CurrentCamera or Workspace
table.insert(Cleanups, function()
    Draw.folder:Destroy()
end)
do
    local function part(color, size)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.Material = Enum.Material.Neon
        p.Color = color
        p.Size = size
        p.Parent = Draw.folder
        return p
    end
    -- A line made of thin segments, reused between frames.
    function Draw.line(name, pts, color, width)
        local pool = Draw.pools[name] or {}
        Draw.pools[name] = pool
        local used = 0
        for i = 1, #pts - 1, 2 do
            local a, b = pts[i], pts[math.min(i + 2, #pts)]
            local len = (b - a).Magnitude
            if len > 0.05 then
                used += 1
                local seg = pool[used]
                if not seg then
                    seg = part(color, Vector3.new(width, width, 1))
                    pool[used] = seg
                end
                seg.Color = color
                seg.Size = Vector3.new(width, width, len)
                seg.CFrame = CFrame.lookAt((a + b) / 2, b)
                seg.Transparency = 0.25
            end
        end
        for i = used + 1, #pool do
            pool[i].Transparency = 1
        end
    end
    function Draw.hide(name)
        for _, seg in Draw.pools[name] or {} do
            seg.Transparency = 1
        end
    end
    -- A flat ring where the ball first comes down.
    local ring
    function Draw.landing(pos, color)
        if not ring then
            ring = part(color, Vector3.new(0.2, 7, 7))
            ring.Shape = Enum.PartType.Cylinder
        end
        if pos then
            ring.Color = color
            ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
            ring.Transparency = 0.35
        else
            ring.Transparency = 1
        end
    end
end

local Predict = { goal = nil, shotGoal = nil }
do
    local camera = Workspace.CurrentCamera
    function Predict.step()
        local center, vel, radius = Ball.state()
        if not center then
            Draw.hide("path")
            Draw.hide("shot")
            Draw.landing(nil)
            Predict.goal, Predict.shotGoal = nil, nil
            return
        end
        -- where the ball is going now
        if Settings.ShowPath then
            local pts, landing, goal = Sim.path(center, vel, radius, Settings.PathSeconds)
            Draw.line("path", pts, Settings.PathColor, 0.35)
            Draw.landing(Settings.ShowLanding and landing or nil, Settings.PathColor)
            Predict.goal = goal
        else
            Draw.hide("path")
            Draw.landing(nil)
            Predict.goal = nil
        end
        -- where it would go if you shot right now
        local root = rootPart()
        camera = Workspace.CurrentCamera
        if Settings.ShowShot and root and camera then
            local origin = root.Position + Vector3.new(0, 1.5, 0)
            local look = camera.CFrame.LookVector
            if Shot.inCone(origin, look, center, radius) then
                local myVel = Shot.myVelocity()
                if Settings.SpeedHelp then
                    look = Shot.nudge(origin, look, center, radius, vel, myVel)
                end
                local launch = Shot.launch(origin, look, center, radius, vel, myVel)
                local pts, _, goal = Sim.path(center, launch, radius, Settings.PathSeconds)
                Draw.line("shot", pts, Settings.ShotColor, 0.3)
                Predict.shotGoal = goal
                Predict.shotSpeed = launch.Magnitude
                return
            end
        end
        Draw.hide("shot")
        Predict.shotGoal, Predict.shotSpeed = nil, nil
    end
end
loop(1 / 20, Predict.step)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Blast Soccer",
    Footer = "dookie hub · Ui3",
    Icon = "circle-dot",
    Size = UDim2.fromOffset(620, 480),
    ConfigFolder = "Ui3/BlastSoccer",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function slider(box, key, text, min, max, rounding, suffix, tip)
    return box:AddSlider(key, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function color(t, key, title)
    t:AddColorPicker(key .. "Pick", {
        Default = Settings[key], Title = title,
        Callback = function(c)
            Settings[key] = c
        end,
    })
end

do
    local Tab = Window:AddTab("Prediction", "spline", "Where the ball is going")
    local PathBox = Tab:AddLeftGroupbox("Ball path", "spline")
    color(toggle(PathBox, "ShowPath", "Ball path", "Where the ball is going, with the game's own drag, gravity and bounces"), "PathColor", "Path colour")
    toggle(PathBox, "ShowLanding", "Landing ring", "Where it first comes down")
    color(toggle(PathBox, "ShowShot", "Your shot", "When the ball is in your cone: where it would go if you shot now"), "ShotColor", "Shot colour")
    slider(PathBox, "PathSeconds", "Look ahead", 0.5, 6, 1, " s")
    local InfoBox = Tab:AddRightGroupbox("Now", "info")
    local InfoLabel = InfoBox:AddLabel("...", true)
    loop(0.2, function()
        local center, vel = Ball.state()
        InfoLabel:SetText(center and ("Ball speed %d%s%s"):format(math.floor(vel.Magnitude),
            Predict.goal and ("\nHeading into the %s goal"):format(Predict.goal) or "",
            Predict.shotSpeed and ("\nYour shot now: %d speed%s"):format(math.floor(Predict.shotSpeed),
                Predict.shotGoal and (", into the %s goal"):format(Predict.shotGoal) or "") or "")
            or "No ball in play")
    end)
end

do
    local Tab = Window:AddTab("Shooting", "zap", "Shot helpers")
    local HelpBox = Tab:AddLeftGroupbox("Speed helper", "gauge")
    toggle(HelpBox, "SpeedHelp", "Speed helper",
        "Turns your aim a little toward the way you and the ball are already moving, so the shot comes off faster. It never turns more than the slider, and never so far the ball leaves your cone")
    slider(HelpBox, "MaxNudge", "Most it turns", 1, 30, 0, "°", "Small is subtle, large is faster")
    slider(HelpBox, "MinGain", "Only if it adds at least", 0, 10, 0, " speed")
    HelpBox:AddLabel("How it works: a shot's speed is your aim x 125, plus half your own speed and 15% of the ball's, so lining your aim up with where you're running adds the most", true)
    local StatusLabel = HelpBox:AddLabel("...", true)
    loop(0.3, function()
        StatusLabel:SetText(("Last shot: %s\nRemotes: %s"):format(Shot.last, Hook.status))
    end)
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__BlastSoccerUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded" .. (Hook.status == "hooked" and "" or (" (speed helper off: " .. Hook.status .. ")")), 4)

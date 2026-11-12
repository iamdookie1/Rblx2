--// Blast Soccer ---------------------------------------------------------------------
-- place 137470666387963. Built on Ui3.
--
-- How the game works (as the client sees it):
--   Shot    Client.WeaponController.soundwave() takes the aim from
--           Client.CameraController.getAimLook(origin) and sends
--           Remotes.Soundwave:FireServer(origin, aim, serverTime, castId,
--           ballCenter). It connects when the ball is inside a cone
--           (Config.Soundwave: Range 22, HalfAngleDegrees 55, Cooldown 0.7).
--   Launch  Shared.BallMath.boopVelocity: the ball leaves at
--             aim * LaunchSpeed * (1 - 0.4 * gap / Range)
--             + yourVelocity * InheritCasterVelocity (0.5)
--             + ballVelocity * KeepBallVelocity (0.15)
--           where gap is the distance from you to the ball's surface. A hit
--           from right next to the ball is 125, one from the edge of range 75.
--   Flight  Client.BallView: exponential air drag (Config.Ball.AirDrag 0.08)
--           with workspace gravity, sphere-cast bounces against the arena's
--           Geometry, Goals, Walls and Barriers that keep 82% of a hard hit
--           and slide on a soft one, speed capped at Config.Ball.MaxSpeed.
--   Goals   Arena.Goals.<Team>Goal, attribute Team, with a Trigger box.
--
-- The helpers wrap the game's own getAimLook and soundwave functions, so the
-- game's own hit prediction, effects and remote all see the same shot. Nothing
-- hooks the remotes.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
    ShowPath = true, PathSeconds = 3, ShowShot = true, ShowLanding = true, ThroughWalls = true, ShotLabel = true,
    PathColor = Color3.fromRGB(240, 240, 255), ShotColor = Color3.fromRGB(255, 190, 40),
    GoalColor = Color3.fromRGB(70, 255, 120),
    -- aim helper
    SpeedHelp = false, MaxNudge = 12, MinGain = 1,
    -- timing helper
    Timing = false, SweetGap = 2, MaxHold = 0.35,
    -- lunge on shoot
    Lunge = false, LungeSpeed = 60, LungeTime = 0.15,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
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

--// The game's modules and numbers \\--
local Config = {}
do
    local ok, c = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
    if ok and type(c) == "table" then
        Config = c
    end
end
local BALL = Config.Ball or {}
local DRAG = type(BALL.AirDrag) == "number" and BALL.AirDrag or 0.08
local MAX_SPEED = type(BALL.MaxSpeed) == "number" and BALL.MaxSpeed or 180

local Mods = {}
do
    local client
    pcall(function()
        client = LocalPlayer:WaitForChild("PlayerScripts", 5):WaitForChild("Client", 5)
    end)
    for key, name in { BallView = "BallView", Camera = "CameraController", Weapon = "WeaponController",
        Abilities = "AbilityController", Movement = "MovementController" } do
        local mod = client and client:FindFirstChild(name)
        if mod then
            local ok, t = pcall(require, mod)
            if ok and type(t) == "table" then
                Mods[key] = t
            end
        end
    end
end

-- The current wave numbers: the ability controller's (which knows about Amp
-- and the like), else the config's.
local function waveParams()
    local a = Mods.Abilities
    if a and type(a.waveParams) == "function" then
        local ok, p = pcall(a.waveParams)
        if ok and type(p) == "table" and type(p.LaunchSpeed) == "number" then
            return p
        end
    end
    return Config.Soundwave or {}
end
local function num(p, key, default)
    local v = p[key]
    return type(v) == "number" and v or default
end

-- The game's smoothed ball (BallView), else the ball part itself.
local Ball = {}
function Ball.part()
    local b = Workspace:FindFirstChild("Ball")
    return (b and b:IsA("BasePart")) and b or nil
end
function Ball.state()
    local view = Mods.BallView
    if view and view.getPosition then
        local ok, p, v, r = pcall(function()
            return view.getPosition(), view.getVelocity(), view.getRadius()
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
local Shot = { last = "no shots yet", timing = "no shots yet" }
do
    local function inCone(origin, look, center, radius, p)
        p = p or waveParams()
        local to = center - origin
        local d = to.Magnitude
        if num(p, "Range", 22) < d - radius then
            return false
        end
        if d <= radius + 0.5 then
            return true
        end
        local angle = math.acos(math.clamp(to.Unit:Dot(look), -1, 1))
        return angle <= math.rad(num(p, "HalfAngleDegrees", 55)) + math.asin(math.clamp(radius / d, 0, 1))
    end
    Shot.inCone = inCone
    function Shot.myVelocity()
        local m = Mods.Movement
        if m and type(m.getVelocity) == "function" then
            local ok, v = pcall(m.getVelocity)
            if ok and typeof(v) == "Vector3" then
                return v
            end
        end
        local r = rootPart()
        return r and r.AssemblyLinearVelocity or Vector3.zero
    end
    function Shot.gap(origin, center, radius)
        return math.max(0, (center - origin).Magnitude - radius)
    end
    -- The ball's velocity right after a hit with this aim (BallMath.boopVelocity).
    function Shot.launch(origin, look, center, radius, ballVel, myVel, p)
        p = p or waveParams()
        local t = math.clamp(Shot.gap(origin, center, radius) / num(p, "Range", 22), 0, 1)
        local speed = num(p, "LaunchSpeed", 125) * (1 - (1 - num(p, "FarLaunchFraction", 0.6)) * t)
        return look * speed + myVel * num(p, "InheritCasterVelocity", 0.5) + ballVel * num(p, "KeepBallVelocity", 0.15)
    end
    -- The aim helper: turns your aim a little (never more than MaxNudge
    -- degrees) toward the way you and the ball are already moving, where the
    -- inherited speed adds the most. If the ball would leave the cone, the
    -- turn is made smaller.
    function Shot.nudge(origin, look, center, radius, ballVel, myVel)
        local p = waveParams()
        local carry = myVel * num(p, "InheritCasterVelocity", 0.5) + ballVel * num(p, "KeepBallVelocity", 0.15)
        if carry.Magnitude < 1 or look.Magnitude < 0.5 then
            return look, 0, 0
        end
        look = look.Unit
        local want = carry.Unit
        local between = math.acos(math.clamp(look:Dot(want), -1, 1))
        local axis = look:Cross(want)
        if between < 1e-3 or axis.Magnitude < 1e-6 then
            return look, 0, 0
        end
        axis = axis.Unit
        local base = Shot.launch(origin, look, center, radius, ballVel, myVel, p).Magnitude
        local maxTurn = math.min(between, math.rad(Settings.MaxNudge))
        for _, frac in { 1, 0.75, 0.5, 0.25 } do
            local turn = maxTurn * frac
            local newLook = (CFrame.fromAxisAngle(axis, turn) * look).Unit
            if inCone(origin, newLook, center, radius, p) then
                local gain = Shot.launch(origin, newLook, center, radius, ballVel, myVel, p).Magnitude - base
                if gain >= Settings.MinGain then
                    return newLook, gain, math.deg(turn)
                end
                return look, 0, 0
            end
        end
        return look, 0, 0
    end
end

--// Wrapping the game's shot \\--
-- getAimLook is only changed while the game is inside soundwave(), so the
-- aim line and anything else that asks for the aim stay as they are.
local Hook = { status = "game modules not found", shooting = false }
do
    local Camera, Weapon = Mods.Camera, Mods.Weapon
    -- A rerun first puts back what the last run replaced.
    local saved = Genv.__BlastSoccerOriginals
    if saved then
        if Camera and saved.aim then
            Camera.getAimLook = saved.aim
        end
        if Weapon and saved.wave then
            Weapon.soundwave = saved.wave
        end
    end
    if Camera and Weapon and type(Camera.getAimLook) == "function" and type(Weapon.soundwave) == "function" then
        local origAim, origWave = Camera.getAimLook, Weapon.soundwave
        Genv.__BlastSoccerOriginals = { aim = origAim, wave = origWave }
        Hook.aim = origAim

        Camera.getAimLook = function(origin, ...)
            local look = origAim(origin, ...)
            if Hook.shooting and alive() and Settings.SpeedHelp and typeof(origin) == "Vector3" and typeof(look) == "Vector3" then
                local ok, newLook = pcall(function()
                    local center, ballVel, radius = Ball.state()
                    if not (center and Shot.inCone(origin, look, center, radius)) then
                        return nil
                    end
                    local out, gain, deg = Shot.nudge(origin, look, center, radius, ballVel, Shot.myVelocity())
                    if gain > 0 then
                        Shot.last = ("+%d speed, turned %.1f°"):format(math.floor(gain + 0.5), deg)
                        return out
                    end
                    Shot.last = "already at its best"
                    return nil
                end)
                if ok and newLook then
                    return newLook
                end
            end
            return look
        end

        -- The real shot, with the aim helper switched on around it.
        function Hook.fire(...)
            if Settings.Lunge and Hook.lunge then
                pcall(Hook.lunge)
            end
            Hook.shooting = true
            local res = table.pack(pcall(origWave, ...))
            Hook.shooting = false
            if not res[1] then
                error(res[2], 0)
            end
            return table.unpack(res, 2, res.n)
        end

        Weapon.soundwave = function(...)
            if not alive() then
                return origWave(...)
            end
            if Settings.Timing then
                return Hook.timed(...)
            end
            return Hook.fire(...)
        end
        Hook.status = "ready"
        table.insert(Cleanups, function()
            Camera.getAimLook, Weapon.soundwave = origAim, origWave
            Genv.__BlastSoccerOriginals = nil
        end)
    end
end

-- The aim the game would use right now (with the aim helper, if on).
local function currentAim(origin)
    local look
    if Hook.aim then
        local ok, l = pcall(Hook.aim, origin)
        look = ok and typeof(l) == "Vector3" and l or nil
    end
    local cam = Workspace.CurrentCamera
    look = look or (cam and cam.CFrame.LookVector)
    if not look then
        return nil
    end
    if Settings.SpeedHelp then
        local center, ballVel, radius = Ball.state()
        if center and Shot.inCone(origin, look, center, radius) then
            look = Shot.nudge(origin, look, center, radius, ballVel, Shot.myVelocity())
        end
    end
    return look
end

--// Timing helper \\--
-- A hit from right next to the ball is far faster than one from range
-- (125 against 75). When you shoot while the ball is still coming toward
-- you, this holds the shot for a moment (never longer than MaxHold) and
-- fires it the instant the ball is as close as it is going to get, or right
-- before it would slip out of your cone.
local Timing = { holding = false }
do
    local LOOK_AHEAD = 1 / 20
    -- "fire" now, or "wait" for a closer hit. Also the speed a hit now gives.
    function Timing.verdict()
        local root = rootPart()
        local center, ballVel, radius = Ball.state()
        if not (root and center) then
            return "fire"
        end
        local origin = root.Position + Vector3.new(0, 1.5, 0)
        local look = currentAim(origin)
        if not look then
            return "fire"
        end
        local myVel = Shot.myVelocity()
        local gap = Shot.gap(origin, center, radius)
        local o2, c2 = origin + myVel * LOOK_AHEAD, center + ballVel * LOOK_AHEAD
        local gap2 = Shot.gap(o2, c2, radius)
        local closing = gap2 < gap - 0.05
        local speed = Shot.launch(origin, look, center, radius, ballVel, myVel).Magnitude
        if Shot.inCone(origin, look, center, radius) then
            if gap <= Settings.SweetGap or not closing or not Shot.inCone(o2, look, c2, radius) then
                return "fire", speed, true
            end
            return "wait", speed, true
        end
        -- Not in reach yet: wait only if it's on its way in.
        if closing and gap < num(waveParams(), "Range", 22) + 25 then
            return "wait", nil, false
        end
        return "fire", nil, false
    end

    function Hook.timed(...)
        if Timing.holding then
            return false
        end
        local verdict, speedNow = Timing.verdict()
        if verdict == "fire" then
            Shot.timing = "fired right away"
            return Hook.fire(...)
        end
        Timing.holding = true
        local args = table.pack(...)
        local started = os.clock()
        local conn
        conn = RunService.Heartbeat:Connect(function()
            local v, speed, inReach = Timing.verdict()
            local waited = os.clock() - started
            if v == "fire" or waited >= Settings.MaxHold or not alive() then
                conn:Disconnect()
                Timing.conn = nil
                Timing.holding = false
                if speedNow and speed then
                    Shot.timing = ("held %.2fs: %d -> %d speed"):format(waited, math.floor(speedNow), math.floor(speed))
                elseif inReach then
                    Shot.timing = ("held %.2fs, hit at %d speed"):format(waited, math.floor(speed or 0))
                else
                    Shot.timing = ("held %.2fs, ball never came in reach"):format(waited)
                end
                local ok, err = pcall(Hook.fire, table.unpack(args, 1, args.n))
                if not ok then
                    warn("[BlastSoccer] " .. tostring(err))
                end
            end
        end)
        Timing.conn = conn
        return true
    end
    table.insert(Cleanups, function()
        if Timing.conn then
            Timing.conn:Disconnect()
        end
    end)
end

--// Lunge on shoot \\--
-- Half your speed carries into the shot, so a short push toward where you're
-- shooting makes it faster. The push goes through the game's own
-- Movement.applyImpulse (what its dash uses), which also caps it at the
-- game's horizontal speed limit. It is topped up for LungeTime seconds so the
-- server sees it when it handles the shot. Only when the ball is in reach.
local Lunge = { info = "no shots yet" }
do
    local MAX = 150
    function Hook.lunge()
        local move = Mods.Movement
        if not (move and type(move.applyImpulse) == "function") then
            Lunge.info = "movement controller not found"
            return
        end
        local root = rootPart()
        local center, ballVel, radius = Ball.state()
        if not (root and center) then
            return
        end
        local origin = root.Position + Vector3.new(0, 1.5, 0)
        local look = currentAim(origin)
        if not (look and Shot.inCone(origin, look, center, radius)) then
            Lunge.info = "ball not in reach, no lunge"
            return
        end
        local flat = Vector3.new(look.X, 0, look.Z)
        if flat.Magnitude < 0.2 then
            Lunge.info = "aiming too steeply, no lunge"
            return
        end
        flat = flat.Unit
        local target = math.min(Settings.LungeSpeed, MAX)
        local before = Shot.myVelocity()
        local function topUp()
            local along = Shot.myVelocity():Dot(flat)
            if along < target - 0.5 then
                move.applyImpulse(flat * (target - along))
            end
        end
        topUp()
        local p = waveParams()
        local beforeShot = Shot.launch(origin, look, center, radius, ballVel, before, p).Magnitude
        local afterShot = Shot.launch(origin, look, center, radius, ballVel, Shot.myVelocity(), p).Magnitude
        Lunge.info = ("you %d -> %d, shot %d -> %d"):format(math.floor(before:Dot(flat)), math.floor(target),
            math.floor(math.min(beforeShot, MAX_SPEED)), math.floor(math.min(afterShot, MAX_SPEED)))
        if Lunge.conn then
            Lunge.conn:Disconnect()
        end
        local started = os.clock()
        Lunge.conn = RunService.Heartbeat:Connect(function()
            if os.clock() - started >= Settings.LungeTime or not alive() then
                Lunge.conn:Disconnect()
                Lunge.conn = nil
                return
            end
            pcall(topUp)
        end)
    end
    table.insert(Cleanups, function()
        if Lunge.conn then
            Lunge.conn:Disconnect()
        end
    end)
end

--// Drawing \\--
-- Thin boxes drawn on top of everything (handle adornments), so the lines
-- show through walls, players and the ball.
local Draw = { folder = Instance.new("Folder"), pools = {} }
Draw.folder.Name = "BlastSoccerPrediction"
Draw.folder.Parent = Workspace.CurrentCamera or Workspace
table.insert(Cleanups, function()
    Draw.folder:Destroy()
end)
do
    local function adornee()
        return Workspace:FindFirstChildOfClass("Terrain") or Workspace.Terrain
    end
    local function make(class, color)
        local a = Instance.new(class)
        a.Adornee = adornee()
        a.Color3 = color
        a.ZIndex = 5
        a.Parent = Draw.folder
        return a
    end
    -- A line made of boxes, reused between frames.
    function Draw.line(name, pts, color, width, transparency)
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
                    seg = make("BoxHandleAdornment", color)
                    pool[used] = seg
                end
                seg.AlwaysOnTop = Settings.ThroughWalls
                seg.Color3 = color
                seg.Size = Vector3.new(width, width, len + width * 0.5)
                seg.CFrame = CFrame.lookAt((a + b) / 2, b)
                seg.Transparency = transparency
                seg.Visible = true
            end
        end
        for i = used + 1, #pool do
            pool[i].Visible = false
        end
    end
    function Draw.hide(name)
        for _, seg in Draw.pools[name] or {} do
            seg.Visible = false
        end
    end
    -- A ball marker at a point (landing spot, end of the shot).
    local dots = {}
    function Draw.dot(name, pos, color, radius)
        local d = dots[name]
        if not d then
            d = make("SphereHandleAdornment", color)
            dots[name] = d
        end
        if pos then
            d.AlwaysOnTop = Settings.ThroughWalls
            d.Color3 = color
            d.Radius = radius
            d.CFrame = CFrame.new(pos)
            d.Transparency = 0.2
            d.Visible = true
        else
            d.Visible = false
        end
    end
    -- A big label over the ball: what your shot would do right now.
    local gui, text
    function Draw.label(part, line, color)
        if not gui then
            gui = Instance.new("BillboardGui")
            gui.Name = "BlastSoccerShot"
            gui.AlwaysOnTop = true
            gui.Size = UDim2.fromOffset(220, 54)
            gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
            gui.LightInfluence = 0
            text = Instance.new("TextLabel")
            text.BackgroundTransparency = 1
            text.Size = UDim2.fromScale(1, 1)
            text.Font = Enum.Font.GothamBlack
            text.TextScaled = true
            text.TextStrokeTransparency = 0.2
            text.Parent = gui
            gui.Parent = Draw.folder
        end
        if part and line then
            gui.Adornee = part
            text.Text = line
            text.TextColor3 = color
            gui.Enabled = true
        else
            gui.Enabled = false
        end
    end
end

local Predict = {}
do
    function Predict.step()
        local center, vel, radius = Ball.state()
        if not center then
            Draw.hide("path")
            Draw.hide("shot")
            Draw.dot("landing", nil)
            Draw.dot("shotEnd", nil)
            Draw.label(nil)
            Predict.goal, Predict.shotGoal, Predict.shotSpeed = nil, nil, nil
            return
        end
        -- where the ball is going now
        if Settings.ShowPath then
            local pts, landing, goal = Sim.path(center, vel, radius, Settings.PathSeconds)
            Draw.line("path", pts, goal and Settings.GoalColor or Settings.PathColor, 0.3, 0.45)
            Draw.dot("landing", Settings.ShowLanding and landing or nil, Settings.PathColor, 1.6)
            Predict.goal = goal
        else
            Draw.hide("path")
            Draw.dot("landing", nil)
            Predict.goal = nil
        end
        -- where it would go if you shot right now
        local root = rootPart()
        if Settings.ShowShot and root then
            local origin = root.Position + Vector3.new(0, 1.5, 0)
            local look = currentAim(origin)
            if look and Shot.inCone(origin, look, center, radius) then
                local launch = Shot.launch(origin, look, center, radius, vel, Shot.myVelocity())
                local pts, _, goal = Sim.path(center, launch, radius, Settings.PathSeconds)
                local color = goal and Settings.GoalColor or Settings.ShotColor
                Draw.line("shot", pts, color, 0.9, 0)
                Draw.dot("shotEnd", pts[#pts], color, 2.4)
                local speed = math.min(launch.Magnitude, MAX_SPEED)
                Predict.shotGoal, Predict.shotSpeed = goal, speed
                Draw.label(Settings.ShotLabel and Ball.part() or nil,
                    ("%d%s"):format(math.floor(speed), goal and "  GOAL" or ""), color)
                return
            end
        end
        Draw.hide("shot")
        Draw.dot("shotEnd", nil)
        Draw.label(nil)
        Predict.shotGoal, Predict.shotSpeed = nil, nil
    end
end
loop(1 / 30, Predict.step)

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
    toggle(PathBox, "ShowLanding", "Landing marker", "Where it first comes down")
    color(toggle(PathBox, "ShowShot", "Your shot", "When the ball is in reach: a thick line of where it would go if you shot now"), "ShotColor", "Shot colour")
    toggle(PathBox, "ShotLabel", "Shot speed over the ball", "Big number over the ball: your shot's speed, and GOAL if it would go in")
    color(toggle(PathBox, "ThroughWalls", "Show through walls"), "GoalColor", "Colour when it goes in")
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
    local TimeBox = Tab:AddLeftGroupbox("Timing helper (big)", "timer")
    toggle(TimeBox, "Timing", "Timing helper",
        "When you shoot while the ball is still coming at you, it waits a moment and fires as the ball gets closest. Close hits are much faster (125 point blank against 75 at the edge of range)")
    slider(TimeBox, "SweetGap", "Fire once the ball is within", 0, 10, 1, " studs")
    slider(TimeBox, "MaxHold", "Longest it waits", 0.05, 0.8, 2, " s")
    local TimingLabel = TimeBox:AddLabel("...", true)

    local LungeBox = Tab:AddLeftGroupbox("Lunge on shoot", "move-right")
    toggle(LungeBox, "Lunge", "Lunge on shoot",
        "When you shoot with the ball in reach, a short push toward where you're shooting. Half your speed goes into the shot. Uses the game's own dash push")
    slider(LungeBox, "LungeSpeed", "Lunge speed", 35, 150, 0, "", "60 is a quick step (about +15 shot speed), 110 is an obvious lunge (near the ball's 180 cap)")
    slider(LungeBox, "LungeTime", "Lunge length", 0.05, 0.4, 2, " s", "Long enough for the server to see it; 0.15-0.25 is about right")
    local LungeLabel = LungeBox:AddLabel("...", true)

    local AimBox = Tab:AddRightGroupbox("Aim helper (small)", "gauge")
    toggle(AimBox, "SpeedHelp", "Aim helper",
        "Turns your aim a little toward the way you and the ball are already moving, so the shot comes off a bit faster. Never more than the slider, and never so far the ball leaves your cone")
    slider(AimBox, "MaxNudge", "Most it turns", 1, 30, 0, "°", "Small is subtle, large is faster")
    slider(AimBox, "MinGain", "Only if it adds at least", 0, 10, 0, " speed")
    local AimLabel = AimBox:AddLabel("...", true)
    loop(0.3, function()
        TimingLabel:SetText(("Last shot: %s"):format(Shot.timing))
        LungeLabel:SetText(("Last shot: %s"):format(Lunge.info))
        AimLabel:SetText(("Last shot: %s\nHook: %s"):format(Shot.last, Hook.status))
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

notify("Loaded" .. (Hook.status == "ready" and "" or (" (shot helpers off: " .. Hook.status .. ")")), 4)

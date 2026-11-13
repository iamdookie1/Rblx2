--// Volleyball Legends -----------------------------------------------------------------
-- place 74691681039273 (game 6931042565). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Hits    Every move (Bump, Set, Spike, JumpSet, Block, Dive) makes a hitbox
--           part in front of you (GameController.Actions.Move.DoMove.ClientHitbox)
--           and checks it against the ball each frame ON YOUR SIDE. On contact
--           it calls BallService:Interact { Move, BallId, LookVector,
--           MoveDirection, TiltDirection, Charge, ... }. The server then runs
--           Common.Physics.canInteract: the ball has to be within 20 studs of
--           you (30 for a dive), on your side, and not just touched by your
--           team. Bump, Set, Dive and Block also get a server hitbox
--           (Configuration.Game.Ball.<Move>.CreateServerHitbox); Spike, JumpSet
--           and Toss don't.
--   Ball    BallController.ActiveBalls[serverId] = { Ball = model, Velocity }.
--           Common.Physics.calculateBallPhysics(dt, velocity, position, ball)
--           steps it: gravity 17 (Modifier BallGravity), sphere-cast bounces.
--   Serve   GameService:Serve(TossDirection, charge). TossDirection is local
--           (x = left/right), charge comes from your charge bar.
--   Moving  Style multipliers are Player attributes read through
--           Common.State.get(player, "Multiplier", "Speed" | "JumpPower" |
--           "DiveSpeed"); jumps launch at Jump.Physics.LaunchSpeed (30) * JumpPower.
--
-- Moves and jumps are started through the game's own input handlers
-- (Binding.Registry.DoMove.onMoveRequest / Registry.Jump.onJumpRequest), the
-- functions your buttons call. Nothing simulates a mouse or a touch.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__VblUnload then
    pcall(Genv.__VblUnload)
end
Genv.__VblRun = (Genv.__VblRun or 0) + 1
local RUN = Genv.__VblRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__VblRun == RUN
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
    -- hitbox
    Hitbox = false, SpikeScale = 1.6, ReceiveScale = 1.3, BlockScale = 1.4, ShowHitboxes = false,
    -- auto
    AutoReceive = false, ReceiveMove = "Bump", ReceiveHeight = 9,
    AutoSpike = false, JumpForSpike = false,
    AutoBlock = false, JumpForBlock = false, AutoDive = false,
    -- aim
    SpikeAim = "Off", NoOvershoot = true, ControlDistance = true, ServePower = false, ServeCharge = 1, ServeAim = false,
    -- visual helper
    Helper = true, ShowPath = true, ShowLanding = true, ShowSpikeSpot = true, ShowAimSpot = true, ShowForecast = true, HelperLabels = true,
    -- movement
    SpeedOn = false, SpeedMult = 1.2, JumpOn = false, JumpMult = 1.15, DiveOn = false, DiveMult = 1.3,
    -- esp / misc
    EspPlayers = false, AntiAfk = true, AutoLevelRewards = false,
    -- rewards
    InstaRoll = false, DupeMode = "Level: race the next reward", DupeBurst = 4, DupeIndex = 1,
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
                warn("[Volleyball] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Volleyball Legends", Description = text, Time = seconds or 3 })
end
local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

--// The game's modules \\--
local function req(inst)
    if not inst then
        return nil
    end
    local ok, m = pcall(require, inst)
    return ok and m or nil
end
local function path(root, str)
    local inst = root
    for name in str:gmatch("[^%.]+") do
        inst = inst and inst:WaitForChild(name, 5)
    end
    return inst
end
local Knit = req(path(ReplicatedStorage, "Packages.Knit"))
pcall(function()
    Knit.OnStart():await()
end)
local GameConfig = req(path(ReplicatedStorage, "Configuration.Game")) or {}
local Physics = req(path(ReplicatedStorage, "Common.Physics"))
local State = req(path(ReplicatedStorage, "Common.State"))
local HitboxTool = req(path(ReplicatedStorage, "Tools.Hitbox"))
local GC = path(ReplicatedFirst, "Controllers.GameController")
local Handlers = req(GC and path(GC, "Handlers"))
local ClientHitbox = req(GC and path(GC, "Actions.Move.DoMove.ClientHitbox"))
local RegDoMove = req(GC and path(GC, "Actions.Binding.Registry.DoMove"))
local RegJump = req(GC and path(GC, "Actions.Binding.Registry.Jump"))
local JumpPhysics = req(GC and path(GC, "Actions.Move.Jump.Physics"))
local function controller(name)
    local ok, c = pcall(function()
        return Knit.GetController(name)
    end)
    return ok and c or nil
end
local function service(name)
    local ok, s = pcall(function()
        return Knit.GetService(name)
    end)
    return ok and s or nil
end
local BallController = controller("BallController")
local SpecialController = controller("SpecialController")
local BallService = service("BallService")
local GameService = service("GameService")
local QuestService = service("QuestService")
local SeasonService = service("SeasonService")
local ChallengeService = service("ChallengeService")
local GameControllerK = controller("GameController")
local LevelService = service("LevelService")
local DataService = service("DataService")
local LevelContent = req(ReplicatedStorage:FindFirstChild("Content") and ReplicatedStorage.Content:FindFirstChild("Level"))

local AERIAL = { Spike = true, JumpSet = true, Block = true, Bump = false, Set = false, Dive = false }

--// Court \\--
local Court = {}
do
    function Court.net()
        local net = CollectionService:GetTagged("Net")[1]
        if net and net:IsA("BasePart") then
            return net
        end
        local map = Workspace:FindFirstChild("Map")
        local only = map and map:FindFirstChild("BallCollideOnly")
        local n = only and only:FindFirstChild("Net")
        return n and n:IsA("BasePart") and n or nil
    end
    -- Team Index 1 plays on the low-Z side of the net, Index 2 on the high side
    -- (Physics.isPointOnTeamSide).
    function Court.mySign()
        local team = LocalPlayer.Team
        local idx = team and team:GetAttribute("Index")
        if idx == 1 then
            return -1
        elseif idx == 2 then
            return 1
        end
        return nil
    end
    function Court.onMySide(pos)
        local net, sign = Court.net(), Court.mySign()
        if not (net and sign) then
            return true
        end
        return (pos.Z - net.Position.Z) * sign > 0
    end
    function Court.lines()
        if Physics and Physics._getCourtlines then
            local ok, part = pcall(Physics._getCourtlines)
            if ok and typeof(part) == "Instance" and part:IsA("BasePart") then
                return part
            end
        end
        for _, p in CollectionService:GetTagged("Courtlines") do
            if p:IsA("BasePart") and p:IsDescendantOf(Workspace) then
                return p
            end
        end
        return nil
    end
    function Court.floorY(pos)
        if Physics and Physics.calculateFloorHeight then
            local ok, y = pcall(Physics.calculateFloorHeight, pos, true)
            if ok and type(y) == "number" then
                return y
            end
        end
        local net = Court.net()
        return net and (net.Position.Y - net.Size.Y / 2) or 0
    end
    function Court.opponents()
        local out = {}
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and p.Team and p.Team ~= LocalPlayer.Team and p.Character then
                local r = p.Character:FindFirstChild("HumanoidRootPart")
                if r then
                    table.insert(out, r.Position)
                end
            end
        end
        return out
    end
end

--// Ball \\--
local Ball = {}
do
    local lastPos, lastAt, guessVel
    function Ball.get()
        if BallController and type(BallController.ActiveBalls) == "table" then
            for id, obj in BallController.ActiveBalls do
                local model = type(obj) == "table" and obj.Ball
                if model and model.Parent and model.PrimaryPart then
                    local vel = typeof(obj.Velocity) == "Vector3" and obj.Velocity or Vector3.zero
                    return model.PrimaryPart.Position, vel, obj, id
                end
            end
        end
        -- Fallback: the tagged ball model, velocity from its movement.
        local model = CollectionService:GetTagged("Ball")[1]
        local part = model and (model:IsA("Model") and model.PrimaryPart or (model:IsA("BasePart") and model))
        if not part then
            return nil
        end
        local now = os.clock()
        if lastPos and now - lastAt > 0 then
            guessVel = (part.Position - lastPos) / (now - lastAt)
        end
        lastPos, lastAt = part.Position, now
        return part.Position, guessVel or Vector3.zero, nil, nil
    end
    function Ball.gravity()
        local g = (GameConfig.Physics and GameConfig.Physics.Gravity) or 17
        if State then
            local ok, v = pcall(State.get, ReplicatedStorage, "Modifier", "BallGravity", g)
            if ok and type(v) == "number" then
                return v
            end
        end
        return g
    end
    function Ball.radius()
        return (GameConfig.Physics and GameConfig.Physics.Radius) or 1.3
    end
end

--// Ball tracker: real gravity, hits and who made them \\--
-- The server only streams position and velocity. Fast spikes come from a
-- higher gravity on the server (SpikeGravityMultiplier), which the client's
-- own ball never learns about. So the gravity is measured here from the
-- change in vertical speed between stream packets, and a jump in horizontal
-- speed (or an upward kick) is taken as a new hit.
local Track = { gm = nil, hitAt = -math.huge, hitPos = nil, hitter = nil, hitVel = nil }
do
    local last
    local function onPacket(pkt)
        if not (alive() and type(pkt) == "table" and typeof(pkt.velocity) == "Vector3" and typeof(pkt.cframe) == "CFrame") then
            return
        end
        local now = os.clock()
        local vel, pos = pkt.velocity, pkt.cframe.Position
        local scale = ReplicatedStorage:GetAttribute("GlobalTimeScale") or 1
        if last and last.id == pkt.ID then
            local dt = (now - last.t) * scale
            local dv = vel - last.vel
            if dt > 0.015 and dt < 0.6 then
                if flat(dv).Magnitude > 4 or dv.Y > 3 then
                    -- A hit, or a bounce: a bounce near the floor isn't a hit.
                    Track.gm = nil
                    if pos.Y - Court.floorY(pos) < 3.5 then
                        last = { t = now, vel = vel, pos = pos, id = pkt.ID }
                        return
                    end
                    Track.hitAt, Track.hitPos, Track.hitVel = now, pos, vel
                    Track.hitter = nil
                    task.delay(0.12, function()
                        Track.hitter = ReplicatedStorage:GetAttribute("LastHitter")
                    end)
                    if Track.onHit then
                        task.spawn(Track.onHit, pos, vel, now)
                    end
                elseif dv.Y < 0 then
                    local g = -dv.Y / dt / ((GameConfig.Physics and GameConfig.Physics.Gravity) or 17)
                    if g > 0.2 and g < 12 then
                        Track.gm = Track.gm and (Track.gm * 0.6 + g * 0.4) or g
                    end
                end
            end
        end
        last = { t = now, vel = vel, pos = pos, id = pkt.ID }
    end
    if BallController and BallController.Streamed and BallController.Streamed.Connect then
        local ok, conn = pcall(function()
            return BallController.Streamed:Connect(onPacket)
        end)
        if ok and conn then
            table.insert(Cleanups, function()
                pcall(function()
                    conn:Disconnect()
                end)
            end)
            Track.status = "ready"
        end
    end
end

--// Prediction: the game's own ball physics, run ahead \\--
-- Returns samples { p, v, t } up to the first floor hit, plus that landing.
local Predict = { samples = {}, landing = nil, landT = nil }
do
    local DT = 1 / 30
    function Predict.run(pos, vel, obj, maxT)
        local samples = { { p = pos, v = vel, t = 0 } }
        local proxy = {
            ID = obj and obj.ID, Target = obj and obj.Target,
            GravityMultiplier = Track.gm or (obj and obj.GravityMultiplier),
            Acceleration = obj and obj.Acceleration, Jerk = obj and obj.Jerk,
        }
        function proxy.SetTarget(self, t)
            self.Target = t
        end
        local g, floor = Ball.gravity(), Court.floorY(pos)
        local useGame = Physics and Physics.calculateBallPhysics
        local t = 0
        for _ = 1, math.floor((maxT or 4) / DT) do
            local r
            if useGame then
                local ok, res = pcall(Physics.calculateBallPhysics, DT, vel, pos, proxy)
                if ok and type(res) == "table" and typeof(res.Position) == "Vector3" then
                    r = res
                else
                    useGame = false
                end
            end
            if not r then
                local nv = vel - Vector3.new(0, g * (proxy.GravityMultiplier or 1) * DT, 0)
                local np = pos + nv * DT
                r = { Position = np, Velocity = nv }
                if np.Y <= floor + Ball.radius() then
                    r.Hit, r.Normal = true, Vector3.yAxis
                end
            end
            t += DT
            pos, vel = r.Position, typeof(r.Velocity) == "Vector3" and r.Velocity or vel
            table.insert(samples, { p = pos, v = vel, t = t })
            if r.Hit and typeof(r.Normal) == "Vector3" and r.Normal.Y > 0.6 then
                return samples, pos, t
            end
        end
        return samples, nil, nil
    end

    -- How high you reach on a spike, and how long a jump takes to get there.
    function Predict.jump()
        local jp = 1
        if State then
            local ok, v = pcall(State.get, LocalPlayer, "Multiplier", "JumpPower", 1)
            jp = ok and type(v) == "number" and v or 1
        end
        local launch = ((JumpPhysics and JumpPhysics.LaunchSpeed) or 30) * jp
        local g = Workspace.Gravity > 0 and Workspace.Gravity or 196.2
        return launch * launch / (2 * g), launch / g
    end

    -- Where to jump from to spike it: the first point on your side where the
    -- ball comes down through your spike height.
    function Predict.spikeSpot(samples)
        local root = rootPart()
        if not (root and samples) then
            return nil
        end
        local floor = Court.floorY(root.Position)
        local apex, tApex = Predict.jump()
        local contact = (root.Position.Y - floor) + apex + 2.5
        for _, s in samples do
            local h = s.p.Y - floor
            if s.t > 0.05 and s.v.Y < 0 and math.abs(h - contact) <= 1.6 and Court.onMySide(s.p) then
                return s, s.t - tApex
            end
        end
        return nil
    end

    loop(1 / 15, function()
        local pos, vel, obj = Ball.get()
        if not pos then
            Predict.samples, Predict.landing, Predict.landT, Predict.spike = {}, nil, nil, nil
            return
        end
        Predict.pos, Predict.vel = pos, vel
        Predict.samples, Predict.landing, Predict.landT = Predict.run(pos, vel, obj, 4)
        Predict.spike, Predict.spikeIn = Predict.spikeSpot(Predict.samples)
        local myTeam = LocalPlayer.Team and LocalPlayer.Team.Name
        local lastTeam = ReplicatedStorage:GetAttribute("LastHitTeam")
        Predict.incoming = lastTeam ~= nil and lastTeam ~= myTeam
    end)
end

--// Learning: how far each player's spikes and serves go \\--
-- The server owns the spike and serve formulas (they're not in the client), so
-- distances are learned from real hits: once a hit's path is known, its
-- landing distance and its angle from the hitter's facing are kept per player.
-- Your own spikes also keep the tilt you sent, to learn how tilt changes
-- your spike's length.
local Learn = { players = {}, mine = {}, lastSpike = nil }
do
    local function record(name, kind)
        local r = Learn.players[name]
        if not r then
            r = {}
            Learn.players[name] = r
        end
        r[kind] = r[kind] or { n = 0, dist = 0, angle = 0 }
        return r[kind]
    end
    function Learn.get(name, kind)
        local r = Learn.players[name]
        return r and r[kind]
    end
    local function lookOf(name)
        local p = name and Players:FindFirstChild(name)
        local r = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        return r and flat(r.CFrame.LookVector).Unit, r and r.Position
    end
    Track.onHit = function(pos, vel, at)
        task.wait(0.35)
        if not alive() or Track.hitAt ~= at then
            return
        end
        local name = Track.hitter or ReplicatedStorage:GetAttribute("LastHitter")
        if not name then
            return
        end
        local p, v, obj = Ball.get()
        if not p then
            return
        end
        local _, landing = Predict.run(p, v, obj, 5)
        if not landing then
            return
        end
        local dist = (flat(landing) - flat(pos)).Magnitude
        local served = ReplicatedStorage:GetAttribute("ServedByPlayer") == name
        local kind = (served and "serve") or ((flat(vel).Magnitude > 30 or vel.Y < -5) and "spike") or "other"
        local look = lookOf(name)
        local angle = 0
        if look and flat(vel).Magnitude > 1 then
            local d = flat(vel).Unit
            angle = math.atan2(look:Cross(d).Y, look:Dot(d))
        end
        local r = record(name, kind)
        r.n += 1
        local w = 1 / math.min(r.n, 6)
        r.dist = r.dist + (dist - r.dist) * w
        r.angle = r.angle + (angle - r.angle) * w
        -- Your own spike: keep the tilt that was sent with it.
        local ls = Learn.lastSpike
        if name == LocalPlayer.Name and kind == "spike" and ls and at - ls.at < 0.8 then
            table.insert(Learn.mine, { dot = ls.dot, dist = dist })
            if #Learn.mine > 25 then
                table.remove(Learn.mine, 1)
            end
        end
    end
    -- Your spike's length for a given tilt (dot of tilt with facing, -1..1):
    -- a straight line through your past spikes, or their average.
    function Learn.myModel()
        local n = #Learn.mine
        if n == 0 then
            return nil
        end
        local sx, sy, sxx, sxy = 0, 0, 0, 0
        for _, m in Learn.mine do
            sx += m.dot
            sy += m.dist
            sxx += m.dot * m.dot
            sxy += m.dot * m.dist
        end
        local mean = sy / n
        local var = sxx / n - (sx / n) ^ 2
        if n >= 3 and var > 0.05 then
            local b = (sxy / n - (sx / n) * mean) / var
            local a = mean - b * (sx / n)
            return { a = a, b = b, n = n, mean = mean }
        end
        return { a = mean, b = 0, n = n, mean = mean }
    end
end

--// Forecast: where a spike or spike serve will go, before it's hit \\--
-- When an opponent is in the air near the ball (or serving), their spike is
-- forecast along where they're facing, turned by their usual angle and as far
-- as their past spikes went (a default until there are some). The exact path
-- replaces it the moment the ball is hit.
local Forecast = { spot = nil, who = nil }
do
    local DEFAULT = { spike = 38, serve = 52 }
    loop(1 / 15, function()
        Forecast.spot, Forecast.who = nil, nil
        local pos = Predict.pos
        if not pos or os.clock() - Track.hitAt < 0.5 then
            return
        end
        local servedBy = ReplicatedStorage:GetAttribute("ServedByPlayer")
        local best, bestD
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and p.Team and p.Team ~= LocalPlayer.Team and p.Character then
                local r = p.Character:FindFirstChild("HumanoidRootPart")
                if r then
                    local d = (r.Position - pos).Magnitude
                    local airborne = p.Character:GetAttribute("Jumping") == true
                    local serving = servedBy == p.Name and pos.Y > r.Position.Y
                    if d < 14 and (airborne or serving) and not Court.onMySide(r.Position) and (not bestD or d < bestD) then
                        best, bestD = { player = p, root = r, kind = (serving and not airborne) and "serve" or "spike" }, d
                    end
                end
            end
        end
        if not best then
            return
        end
        local stats = Learn.get(best.player.Name, best.kind) or (best.kind == "serve" and Learn.get(best.player.Name, "spike"))
        local dist = stats and stats.dist or DEFAULT[best.kind]
        local angle = stats and stats.angle or 0
        local look = flat(best.root.CFrame.LookVector)
        if look.Magnitude < 0.1 then
            return
        end
        local dir = (CFrame.Angles(0, -angle, 0) * look.Unit)
        local spot = flat(best.root.Position) + dir * dist
        Forecast.spot = Vector3.new(spot.X, Court.floorY(best.root.Position), spot.Z)
        Forecast.who = best.player.DisplayName
        Forecast.kind = best.kind
        Forecast.learned = stats and stats.n or 0
    end)
end

--// Spike aim: where on their court, and how to land it there \\--
local AIM_MODES = { "Off", "Open spot", "Gap between players", "At a player", "Deep corner (cross)", "Deep corner (line)",
    "Short corner", "Deep middle", "Just over the net" }
local Aim = {}
do
    -- Their half of the court: x from cx-hx to cx+hx, z from the net to zFar.
    function Aim.court()
        local lines, net, sign = Court.lines(), Court.net(), Court.mySign()
        if not (lines and net and sign) then
            return nil
        end
        local cf, size = lines.CFrame, lines.Size
        return {
            cx = cf.Position.X, hx = size.X / 2 - 2.5, zNet = net.Position.Z,
            zFar = cf.Position.Z - sign * (size.Z / 2 - 2.5), floor = Court.floorY(cf.Position), sign = sign,
        }
    end
    function Aim.inside(c, p, margin)
        margin = margin or 0
        local lo, hi = math.min(c.zNet, c.zFar), math.max(c.zNet, c.zFar)
        return math.abs(p.X - c.cx) <= c.hx - margin and p.Z >= lo + margin and p.Z <= hi - margin
    end
    function Aim.target()
        local mode = Settings.SpikeAim
        if mode == "Off" then
            return nil
        end
        local c = Aim.court()
        local root = rootPart()
        if not (c and root) then
            return nil
        end
        local function at(fx, fz) -- fx -1..1 across, fz 0 (net) .. 1 (back line)
            return Vector3.new(c.cx + c.hx * fx, c.floor, c.zNet + (c.zFar - c.zNet) * fz)
        end
        local mySideX = (root.Position.X >= c.cx) and 1 or -1
        local opp = Court.opponents()
        if mode == "Deep corner (cross)" then
            return at(-mySideX, 0.95)
        elseif mode == "Deep corner (line)" then
            return at(mySideX, 0.95)
        elseif mode == "Short corner" then
            return at(-mySideX, 0.2)
        elseif mode == "Deep middle" then
            return at(0, 0.92)
        elseif mode == "Just over the net" then
            local fx = math.clamp((root.Position.X - c.cx) / math.max(c.hx, 1), -0.8, 0.8)
            return at(fx, 0.12)
        elseif mode == "At a player" then
            local best, bestD
            for _, o in opp do
                local d = (flat(o) - flat(root.Position)).Magnitude
                if Aim.inside(c, o, 0) and (not bestD or d < bestD) then
                    best, bestD = o, d
                end
            end
            return best and Vector3.new(best.X, c.floor, best.Z) or at(0, 0.6)
        elseif mode == "Gap between players" and #opp >= 2 then
            local best, bestGap
            for i = 1, #opp do
                for j = i + 1, #opp do
                    local gap = (flat(opp[i]) - flat(opp[j])).Magnitude
                    if not bestGap or gap > bestGap then
                        best, bestGap = (opp[i] + opp[j]) / 2, gap
                    end
                end
            end
            return Vector3.new(best.X, c.floor, best.Z)
        end
        -- Open spot (and Gap with fewer than two players): farthest from everyone.
        local best, bestScore
        for i = 0, 6 do
            for j = 1, 6 do
                local p = at(-1 + 2 * i / 6, j / 6)
                local score = math.huge
                for _, o in opp do
                    score = math.min(score, (flat(o) - flat(p)).Magnitude)
                end
                if #opp == 0 then
                    score = (p - Vector3.new(c.cx, c.floor, c.zNet)).Magnitude
                end
                if not bestScore or score > bestScore then
                    best, bestScore = p, score
                end
            end
        end
        return best
    end

    -- How to send it: direction, tilt (if your spike length is learned) and
    -- where it should then land. With "no overshoot" the direction is turned
    -- until that landing stays inside their court.
    function Aim.solve(origin, sentDot)
        local target = Aim.spot
        local c = Aim.court()
        if not (target and c) then
            return nil
        end
        local want = flat(target - origin)
        if want.Magnitude < 1 then
            return nil
        end
        local dir, dot = want.Unit, sentDot
        local model = Learn.myModel()
        local length
        if model then
            if Settings.ControlDistance and math.abs(model.b) > 1 then
                dot = math.clamp((want.Magnitude - model.a) / model.b, -1, 1)
            end
            length = model.a + model.b * (dot or 0)
        end
        local landing = length and (flat(origin) + dir * length) or flat(target)
        if Settings.NoOvershoot and length and not Aim.inside(c, landing, 1) then
            for step = 1, 12 do
                local found
                for _, sgn in { 1, -1 } do
                    local d2 = CFrame.Angles(0, math.rad(5 * step) * sgn, 0) * dir
                    local l2 = flat(origin) + d2 * length
                    if Aim.inside(c, l2, 1) then
                        found = { d2, l2 }
                        break
                    end
                end
                if found then
                    dir, landing = found[1], found[2]
                    break
                end
            end
        end
        return { dir = dir, dot = dot, landing = Vector3.new(landing.X, c.floor, landing.Z), length = length }
    end
    loop(0.2, function()
        Aim.spot = Aim.target()
        local root = rootPart()
        Aim.plan = root and Aim.spot and Aim.solve(root.Position, nil) or nil
    end)
end

--// Hitbox expander: the game's own client hitbox, made bigger \\--
local Hit = { status = "client hitbox not found" }
do
    local GROUPS = { Spike = "SpikeScale", JumpSet = "SpikeScale", Bump = "ReceiveScale", Set = "ReceiveScale",
        Dive = "ReceiveScale", Block = "BlockScale" }
    local saved = Genv.__VblHitboxOriginal
    if ClientHitbox and saved then
        ClientHitbox.new = saved
    end
    if ClientHitbox and type(ClientHitbox.new) == "function" then
        local orig = ClientHitbox.new
        Genv.__VblHitboxOriginal = orig
        ClientHitbox.new = function(p, ...)
            if alive() and Settings.Hitbox and type(p) == "table" then
                local key = GROUPS[p.MovementName]
                local s = key and Settings[key] or 1
                local base = p.HitboxSize or (type(p.Hitbox) == "table" and p.Hitbox.Size)
                if s > 1 and typeof(base) == "Vector3" then
                    -- The server still wants the ball within 20 studs of you.
                    p.HitboxSize = Vector3.new(math.min(base.X * s, 34), math.min(base.Y * s, 34), math.min(base.Z * s, 34))
                end
            end
            return orig(p, ...)
        end
        table.insert(Cleanups, function()
            ClientHitbox.new = orig
            Genv.__VblHitboxOriginal = nil
        end)
        Hit.status = "ready"
    end
    -- The game's own debug switch shows hitboxes (read when each is made).
    loop(0.3, function()
        GameConfig._DebugHitboxes = Settings.ShowHitboxes or nil
    end)
    table.insert(Cleanups, function()
        GameConfig._DebugHitboxes = nil
    end)

    -- Roughly how far a move reaches from your root, for the auto moves.
    function Hit.reach(move)
        local size, offset = Vector3.new(6, 6, 6), Vector3.zero
        if HitboxTool then
            local ok, hb = pcall(HitboxTool.get, {
                Special = SpecialController and SpecialController.Special and SpecialController.Special:get() or nil,
                MoveId = move,
            })
            if ok and type(hb) == "table" and typeof(hb.Size) == "Vector3" then
                size = hb.Size
                offset = typeof(hb.Offset) == "CFrame" and hb.Offset.Position or Vector3.zero
            end
        end
        local key = GROUPS[move]
        local s = (Settings.Hitbox and key and Settings[key]) or 1
        return offset.Magnitude + (size * s).Magnitude / 2
    end
end

--// Auto moves, through the game's own input handlers \\--
local Auto = { info = "off" }
do
    local lastMove, lastJump = {}, -math.huge
    local function states()
        return Handlers and Handlers.States
    end
    local function get(v)
        if type(v) == "table" and v.get then
            local ok, r = pcall(v.get, v)
            return ok and r
        end
        return nil
    end
    function Auto.free()
        local st = states()
        if not st then
            return false
        end
        return get(st.IsPlaying) and not get(st.IsBusy) and not get(st.IsServing) and not get(st.IsStunned)
    end
    function Auto.jumping()
        local st = states()
        return st and get(st.IsJumping) or false
    end
    function Auto.move(name)
        if not (RegDoMove and RegDoMove.onMoveRequest) or os.clock() - (lastMove[name] or 0) < 0.35 then
            return false
        end
        lastMove[name] = os.clock()
        local function send(stateEnum)
            pcall(RegDoMove.onMoveRequest, { ActionName = name, IsAerial = AERIAL[name], InputState = stateEnum, Metadata = {} })
        end
        task.spawn(send, Enum.UserInputState.Begin)
        task.delay(0.06, send, Enum.UserInputState.End)
        Auto.info = name .. " at " .. os.date("%X")
        return true
    end
    function Auto.jump()
        if not (RegJump and RegJump.onJumpRequest) or os.clock() - lastJump < 0.8 then
            return false
        end
        lastJump = os.clock()
        task.spawn(pcall, RegJump.onJumpRequest, Enum.UserInputState.Begin)
        task.delay(0.12, function()
            pcall(RegJump.onJumpRequest, Enum.UserInputState.End)
        end)
        return true
    end

    -- A dive pushes at 36 * DiveSpeed, easing to nothing over Dive.Duration * 0.9.
    local lastDive = -math.huge
    function Auto.diveDistance(t)
        local mult = 1
        if State then
            local ok, v = pcall(State.get, LocalPlayer, "Multiplier", "DiveSpeed", 1)
            mult = ok and type(v) == "number" and v or 1
        end
        local T = ((GameConfig.Ball and GameConfig.Ball.Dive and GameConfig.Ball.Dive.Duration) or 1.2) * 0.9
        t = math.clamp(t, 0, T)
        return 36 * mult * (t - 0.99 * t * t / (2 * T)), mult
    end
    function Auto.dive(root, floor)
        if os.clock() - lastDive < 1.5 or not (GameControllerK and GameControllerK.Dive) then
            return false
        end
        local samples = Predict.samples or {}
        local contact
        for _, sm in samples do
            if sm.t > 0 and sm.v.Y < 0 and sm.p.Y - floor <= 4 and Court.onMySide(sm.p) then
                contact = sm
                break
            end
        end
        if not contact then
            return false
        end
        local reach = Hit.reach("Dive") * 0.7
        local gap = (flat(contact.p) - flat(root.Position)).Magnitude
        if gap <= Hit.reach(Settings.ReceiveMove) then
            Auto.info = "in reach, no dive needed"
            return false
        end
        local need = gap - reach
        local can, mult = Auto.diveDistance(contact.t)
        if can < need then
            Auto.info = ("can't reach it (%.0f of %.0f studs)"):format(can, need)
            return false
        end
        -- Go at the last good moment: a dive started now only just gets there.
        if can > need * 1.25 and contact.t > 0.25 then
            Auto.info = ("diving in %.1fs"):format(contact.t)
            return false
        end
        lastDive = os.clock()
        local dir = flat(contact.p - root.Position).Unit
        task.spawn(pcall, GameControllerK.Dive, GameControllerK, { Target = dir * 7 * mult })
        Auto.info = ("dived %.0f studs"):format(need)
        return true
    end

    loop(1 / 30, function()
        if not (Settings.AutoReceive or Settings.AutoSpike or Settings.AutoBlock or Settings.AutoDive) then
            Auto.info = "off"
            return
        end
        local root = rootPart()
        local pos, vel = Predict.pos, Predict.vel
        if not (root and pos and Auto.free()) then
            return
        end
        local ahead = pos + vel * 0.08
        local dist = (ahead - root.Position).Magnitude
        local mine = Court.onMySide(ahead)
        local air = Auto.jumping()
        local floor = Court.floorY(root.Position)

        if air then
            if Settings.AutoSpike and mine and dist <= Hit.reach("Spike") then
                Auto.move("Spike")
                return
            end
            if Settings.AutoBlock and not mine and dist <= Hit.reach("Block") then
                Auto.move("Block")
                return
            end
            return
        end

        -- On the ground.
        if Settings.AutoReceive and mine and vel.Y < 0 and ahead.Y - floor <= Settings.ReceiveHeight
            and dist <= Hit.reach(Settings.ReceiveMove) then
            Auto.move(Settings.ReceiveMove)
            return
        end
        -- Dive to where their spike comes down, only if a dive gets there in time.
        if Settings.AutoDive and Predict.incoming and Auto.dive then
            if Auto.dive(root, floor) then
                return
            end
        end
        -- Jump so the spike meets the ball at the top of the jump.
        if Settings.AutoSpike and Settings.JumpForSpike and Predict.spike and Predict.spikeIn then
            local h = (flat(Predict.spike.p) - flat(root.Position)).Magnitude
            if h <= 7 and Predict.spikeIn <= 0.05 and Predict.spikeIn >= -0.15 then
                Auto.jump()
                return
            end
        end
        -- Jump to block when they hit near the net.
        if Settings.AutoBlock and Settings.JumpForBlock and Predict.incoming then
            local net = Court.net()
            if net and math.abs(root.Position.Z - net.Position.Z) < 9 and not mine
                and (flat(pos) - flat(root.Position)).Magnitude < 14 and pos.Y - floor > 7 then
                Auto.jump()
            end
        end
    end)
end

--// Spike aim and serve, by editing what the game sends \\--
local Shots = { status = "ball service not found", last = "none yet" }
do
    local saved = Genv.__VblShotOriginals or {}
    if BallService and saved.interact then
        BallService.Interact = saved.interact
    end
    if GameService and saved.serve then
        GameService.Serve = saved.serve
    end
    local originals = {}
    if BallService and type(BallService.Interact) == "function" then
        local orig = BallService.Interact
        originals.interact = orig
        BallService.Interact = function(self, data, ...)
            if alive() and type(data) == "table" and data.Move == "Spike" then
                -- The tilt you're holding, as a dot with where you face (-1 back .. 1 forward).
                local look = typeof(data.LookVector) == "Vector3" and flat(data.LookVector) or Vector3.zero
                local tilt = typeof(data.TiltDirection) == "Vector3" and data.TiltDirection or Vector3.new(0, 1, 0)
                local sentDot = (look.Magnitude > 0.1 and flat(tilt).Magnitude > 0.01) and flat(tilt):Dot(look.Unit) or 0
                local root = rootPart()
                if Settings.SpikeAim ~= "Off" and root then
                    local plan = Aim.solve(root.Position, sentDot)
                    if plan then
                        data.LookVector = plan.dir
                        sentDot = plan.dot or sentDot
                        -- Same tilt strength along the new direction (keeps forward/back).
                        data.TiltDirection = plan.dir * sentDot + Vector3.new(0, tilt.Y, 0)
                        Shots.last = plan.length and ("aimed %s, ~%d studs"):format(Settings.SpikeAim:lower(), math.floor(plan.length))
                            or ("aimed %s (learning your spike length)"):format(Settings.SpikeAim:lower())
                    end
                end
                Learn.lastSpike = { at = os.clock(), dot = sentDot }
            end
            return orig(self, data, ...)
        end
        Shots.status = "ready"
    end
    if GameService and type(GameService.Serve) == "function" then
        local orig = GameService.Serve
        originals.serve = orig
        GameService.Serve = function(self, dir, charge, ...)
            if alive() then
                if Settings.ServePower and (type(charge) == "number" or charge == nil) then
                    charge = Settings.ServeCharge
                end
                local root, target = rootPart(), Aim.spot
                if Settings.ServeAim and root and target and typeof(dir) == "Vector3" then
                    local localDir = root.CFrame:VectorToObjectSpace(flat(target - root.Position))
                    if localDir.Magnitude > 1 then
                        local x = math.clamp(localDir.Unit.X * 1.5, -1, 1)
                        dir = Vector3.new(x, dir.Y, dir.Z)
                    end
                end
                Shots.last = ("served at %d%% charge"):format(math.floor((tonumber(charge) or 0) * 100))
            end
            return orig(self, dir, charge, ...)
        end
    end
    Genv.__VblShotOriginals = originals
    table.insert(Cleanups, function()
        if BallService and originals.interact then
            BallService.Interact = originals.interact
        end
        if GameService and originals.serve then
            GameService.Serve = originals.serve
        end
        Genv.__VblShotOriginals = nil
    end)
end

--// Movement: the style multipliers your client reads \\--
local Moves = { status = "state module not found", factor = 1 }
do
    local saved = Genv.__VblStateGetOriginal
    if State and saved then
        State.get = saved
    end
    if State and type(State.get) == "function" then
        local orig = State.get
        Genv.__VblStateGetOriginal = orig
        Moves.orig = orig
        State.get = function(owner, id, key, default, ...)
            local v = orig(owner, id, key, default, ...)
            -- Insta roll: no rarity cutscene after a roll (the game's own setting).
            if owner == LocalPlayer and id == "Settings" and key == "RarityCutscene" and Settings.InstaRoll and alive() then
                return false
            end
            if owner == LocalPlayer and id == "Multiplier" and type(v) == "number" and alive() then
                if key == "Speed" and Settings.SpeedOn then
                    return v * Settings.SpeedMult
                elseif key == "JumpPower" and Settings.JumpOn then
                    return v * Settings.JumpMult
                elseif key == "DiveSpeed" and Settings.DiveOn then
                    return v * Settings.DiveMult
                end
            end
            return v
        end
        table.insert(Cleanups, function()
            State.get = orig
            Genv.__VblStateGetOriginal = nil
        end)
        Moves.status = "ready"
    end
    -- The game sets WalkSpeed at set moments, so a change is applied right away too.
    loop(0.3, function()
        local want = Settings.SpeedOn and Settings.SpeedMult or 1
        local hum = humanoid()
        if hum and want ~= Moves.factor and hum.WalkSpeed > 2 then
            hum.WalkSpeed = hum.WalkSpeed / Moves.factor * want
            Moves.factor = want
        end
    end)
    table.insert(Cleanups, function()
        local hum = humanoid()
        if hum and Moves.factor ~= 1 and hum.WalkSpeed > 2 then
            hum.WalkSpeed = hum.WalkSpeed / Moves.factor
        end
    end)
end

--// Visual helper \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "VblHelper"
    folder.Parent = Workspace
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local function newPart(shape)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.Material = Enum.Material.Neon
        p.Shape = shape or Enum.PartType.Block
        p.Transparency = 1
        p.Parent = folder
        return p
    end
    local segs = {}
    local function seg(i, a, b, color)
        local p = segs[i]
        if not p then
            p = newPart()
            segs[i] = p
        end
        local len = (b - a).Magnitude
        if len < 0.01 then
            p.Transparency = 1
            return
        end
        p.Size = Vector3.new(0.18, 0.18, len)
        p.CFrame = CFrame.lookAt((a + b) / 2, b)
        p.Color = color
        p.Transparency = 0.25
    end
    local function marker(color, text)
        local p = newPart(Enum.PartType.Cylinder)
        p.Size = Vector3.new(0.15, 5, 5)
        p.Color = color
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(180, 40)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop = true
        bb.Adornee = p
        bb.Parent = p
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBlack
        label.TextSize = 15
        label.TextColor3 = color
        label.TextStrokeTransparency = 0.2
        label.Text = text or ""
        label.Parent = bb
        return { part = p, bb = bb, label = label }
    end
    local function place(m, pos, text, show)
        if not (show and pos) then
            m.part.Transparency = 1
            m.bb.Enabled = false
            return
        end
        m.part.CFrame = CFrame.new(pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
        m.part.Transparency = 0.35
        m.bb.Enabled = Settings.HelperLabels and text ~= nil
        m.label.Text = text or ""
    end
    local Land = marker(Color3.fromRGB(255, 220, 60))
    local Spike = marker(Color3.fromRGB(80, 255, 140))
    local Target = marker(Color3.fromRGB(255, 70, 70))
    local MyLand = marker(Color3.fromRGB(255, 140, 220))
    local Fore = marker(Color3.fromRGB(255, 150, 40))
    local foreSegs = {}

    local RED, GREEN, WHITE = Color3.fromRGB(255, 80, 80), Color3.fromRGB(90, 255, 150), Color3.fromRGB(235, 235, 255)
    bind(RunService.RenderStepped, function()
        local on = alive() and Settings.Helper
        local samples = Predict.samples or {}
        local n = 0
        if on and Settings.ShowPath and #samples > 1 then
            local color = Predict.incoming and RED or (Court.onMySide(samples[#samples].p) and GREEN or WHITE)
            local step = math.max(1, math.floor(#samples / 45))
            local prev = samples[1].p
            for i = 1 + step, #samples, step do
                n += 1
                seg(n, prev, samples[i].p, color)
                prev = samples[i].p
            end
        end
        for i = n + 1, #segs do
            segs[i].Transparency = 1
        end

        -- Where it lands, and what that means for you.
        local land = Predict.landing
        local landText
        if land then
            local floor = Court.floorY(land)
            land = Vector3.new(land.X, floor, land.Z)
            local mine = Court.onMySide(land)
            if Predict.incoming and mine then
                landText = ("INCOMING  %.1fs\nget here"):format(Predict.landT or 0)
            elseif mine then
                landText = ("RECEIVE  %.1fs"):format(Predict.landT or 0)
            else
                landText = ("lands their side  %.1fs"):format(Predict.landT or 0)
            end
        end
        place(Land, land, landText, on and Settings.ShowLanding)

        -- Where to jump from to spike it.
        local spot, spotText = Predict.spike and Predict.spike.p, nil
        if spot then
            local floor = Court.floorY(spot)
            spot = Vector3.new(spot.X, floor, spot.Z)
            local wait = Predict.spikeIn or 0
            spotText = wait > 0.05 and ("SPIKE: jump in %.1fs"):format(wait) or "SPIKE: JUMP NOW"
        end
        place(Spike, spot, spotText, on and Settings.ShowSpikeSpot and not Predict.incoming)

        -- Where your spike is aimed, and where it should land with your spike's length.
        local aimOn = on and Settings.ShowAimSpot and Settings.SpikeAim ~= "Off"
        place(Target, Aim.spot, "aim", aimOn)
        local plan = Aim.plan
        place(MyLand, plan and plan.length and plan.landing, plan and plan.length and ("your spike lands ~here (%d studs)"):format(math.floor(plan.length)), aimOn)

        -- Their spike or serve, forecast before they hit it.
        local fs = Forecast.spot
        local showFore = on and Settings.ShowForecast and fs ~= nil and Predict.pos ~= nil
        place(Fore, fs, fs and ("%s's %s ~here%s"):format(Forecast.who or "?", Forecast.kind or "spike",
            (Forecast.learned or 0) > 0 and "" or " (guess)"), showFore)
        local nf = 0
        if showFore then
            local a = Predict.pos
            for i = 1, 8 do
                local b = a:Lerp(fs, i / 8)
                nf += 1
                local part = foreSegs[nf]
                if not part then
                    part = newPart()
                    foreSegs[nf] = part
                end
                if i % 2 == 1 then
                    local prev = Predict.pos:Lerp(fs, (i - 1) / 8)
                    part.Size = Vector3.new(0.14, 0.14, (b - prev).Magnitude)
                    part.CFrame = CFrame.lookAt((prev + b) / 2, b)
                    part.Color = Color3.fromRGB(255, 150, 40)
                    part.Transparency = 0.3
                else
                    part.Transparency = 1
                end
            end
        end
        for i = nf + 1, #foreSegs do
            foreSegs[i].Transparency = 1
        end
    end)
end

--// Player ESP \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "VblEsp"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local items = {}
    local function drop(p)
        local e = items[p]
        if e then
            e.hl:Destroy()
            e.bb:Destroy()
            items[p] = nil
        end
    end
    loop(0.3, function()
        for p in items do
            if not (Settings.EspPlayers and p.Parent and p.Character) then
                drop(p)
            end
        end
        if not Settings.EspPlayers then
            return
        end
        local lastHitter = ReplicatedStorage:GetAttribute("LastHitter")
        for _, p in Players:GetPlayers() do
            local c = p.Character
            local head = c and c:FindFirstChild("Head")
            if p ~= LocalPlayer and head then
                local e = items[p]
                if not e or e.hl.Adornee ~= c then
                    drop(p)
                    local hl = Instance.new("Highlight")
                    hl.FillTransparency = 0.8
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.Adornee = c
                    hl.Parent = folder
                    local bb = Instance.new("BillboardGui")
                    bb.Size = UDim2.fromOffset(200, 36)
                    bb.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
                    bb.AlwaysOnTop = true
                    bb.Adornee = head
                    bb.Parent = folder
                    local t = Instance.new("TextLabel")
                    t.BackgroundTransparency = 1
                    t.Size = UDim2.fromScale(1, 1)
                    t.Font = Enum.Font.GothamBold
                    t.TextSize = 13
                    t.TextStrokeTransparency = 0.3
                    t.Parent = bb
                    e = { hl = hl, bb = bb, text = t }
                    items[p] = e
                end
                local mate = p.Team ~= nil and p.Team == LocalPlayer.Team
                local color = mate and Color3.fromRGB(90, 170, 255) or Color3.fromRGB(255, 80, 80)
                e.hl.FillColor, e.hl.OutlineColor, e.text.TextColor3 = color, color, color
                local style = "?"
                if Moves.orig then
                    local ok, s = pcall(Moves.orig, p, "Game", "Style", "?")
                    style = ok and tostring(s) or "?"
                end
                e.text.Text = ("%s  [%s]%s"):format(p.DisplayName, style, lastHitter == p.Name and "  LAST HIT" or "")
            end
        end
    end)
end

--// Insta roll \\--
-- StyleController:Spin / AbilityController:Spin call StyleService:Roll(lucky)
-- and the server picks the result right then. Afterwards the client waits for
-- the reel (WaitUntilSpinFinishedAync) and plays a cutscene. Insta roll keeps
-- the game's own Spin (so a normal spin is normal and a lucky one is lucky)
-- and only drops the wait; the cutscene goes through the RarityCutscene
-- setting (see State.get above). Ultra rolls still play theirs.
local Rolls = { status = "roll controllers not found", count = 0 }
do
    local patched = {}
    for _, name in { "StyleController", "AbilityController" } do
        local ctrl = controller(name)
        if ctrl and type(ctrl.WaitUntilSpinFinishedAync) == "function" then
            local saved = Genv["__VblWait_" .. name]
            if saved then
                ctrl.WaitUntilSpinFinishedAync = saved
            end
            local orig = ctrl.WaitUntilSpinFinishedAync
            Genv["__VblWait_" .. name] = orig
            ctrl.WaitUntilSpinFinishedAync = function(self, ...)
                if alive() and Settings.InstaRoll then
                    Rolls.count += 1
                    local ok = pcall(function()
                        local n = #self.SpinArray:get()
                        self.SpinIndexIntValue.Value = n
                        self.SpinIndex:set(n)
                    end)
                    if ok then
                        return
                    end
                end
                return orig(self, ...)
            end
            table.insert(patched, { ctrl = ctrl, orig = orig, name = name })
        end
    end
    if #patched > 0 then
        Rolls.status = ("ready (%d rollers)"):format(#patched)
    end
    table.insert(Cleanups, function()
        for _, p in patched do
            p.ctrl.WaitUntilSpinFinishedAync = p.orig
            Genv["__VblWait_" .. p.name] = nil
        end
    end)
end

--// Level reward dupe test \\--
-- Level rewards are one server counter, Statistics.LevelRewardsClaimed. The
-- Claim button sends LevelService:ClaimLevelRewards(level); the client guards
-- in front of it (a 1 second debounce and a LevelClaimed attribute that makes
-- the row look claimed until you rejoin) are client only. The test skips those
-- guards and sends the claim a few times at once, then compares your profile
-- to see whether the reward paid out once or more. Server code isn't in the
-- dump, so only this can tell whether the old dupe still works.
local Dupe = { info = "not run yet", running = false }
do
    local function flatten(t, prefix, out, depth)
        out = out or {}
        if depth > 3 or type(t) ~= "table" then
            return out
        end
        for k, v in t do
            local key = prefix .. tostring(k)
            if type(v) == "number" then
                out[key] = v
            elseif type(v) == "table" then
                flatten(v, key .. ".", out, depth + 1)
            end
        end
        return out
    end
    local function snapshot()
        local out = {}
        if not DataService then
            return out
        end
        for _, section in { "Statistics", "Spins", "Seasonal", "Inventory", "Rewards" } do
            local ok, data = pcall(function()
                return DataService:Get(section):expect()
            end)
            if ok and type(data) == "table" then
                flatten(data, section .. ".", out, 0)
            end
        end
        return out
    end
    -- Statistics, kept up to date the way the game's own menus do it.
    local stats = {}
    if DataService then
        task.spawn(function()
            pcall(function()
                stats = DataService:Get("Statistics"):expect() or stats
            end)
        end)
        pcall(function()
            table.insert(Connections, DataService.ProfileUpdated:Connect(function(section, data)
                if section == "Statistics" and type(data) == "table" then
                    stats = data
                end
            end))
        end)
    end
    function Dupe.levels()
        local level = LocalPlayer:GetAttribute("User_Level") or 0
        local claimed = type(stats.LevelRewardsClaimed) == "number" and stats.LevelRewardsClaimed or 0
        local cap = LevelContent and LevelContent.Amount or 300
        return math.min(level, cap), claimed
    end
    local function rewardText(n)
        if not (LevelContent and LevelContent.getReward) then
            return "?", nil
        end
        local ok, r = pcall(LevelContent.getReward, n)
        if ok and type(r) == "table" then
            return ("%s %s"):format(tostring(r.Value), tostring(r.Type)), r
        end
        return "?", nil
    end

    -- The first finished, unclaimed quest in your profile: { index, seasonal }.
    local function findQuest()
        local ok, data = pcall(function()
            return DataService:Get("Quests"):expect()
        end)
        if not (ok and type(data) == "table") then
            return nil
        end
        local found
        local function scan(t, seasonal, depth)
            if found or depth > 3 or type(t) ~= "table" then
                return
            end
            for k, q in t do
                if type(q) == "table" and type(q.Progress) == "number" and q.Claimed ~= true then
                    local need = q.Requirement or q.Goal or q.Target
                    if type(need) == "number" and q.Progress >= need and type(k) == "number" then
                        found = { index = k, seasonal = seasonal }
                        return
                    end
                elseif type(q) == "table" then
                    scan(q, seasonal or tostring(k):lower():find("season") ~= nil, depth + 1)
                end
            end
        end
        scan(data, false, 0)
        return found
    end
    local function call(svc, method, ...)
        local args = table.pack(...)
        return function()
            pcall(function()
                local res = svc[method](svc, table.unpack(args, 1, args.n))
                if type(res) == "table" and res.await then
                    res:await()
                end
            end)
        end
    end

    -- Each test returns the calls to fire together, a label, and for level
    -- rewards the reward one claim should pay.
    local TESTS = {}
    TESTS["Level: race the next reward"] = function()
        local level, claimed = Dupe.levels()
        if level <= claimed then
            return nil, ("No unclaimed level reward (level %d, claimed %d)"):format(level, claimed)
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(LevelService, "ClaimLevelRewards", claimed + 1))
        end
        return c, ("level %d"):format(claimed + 1), claimed + 1
    end
    TESTS["Level: re-claim a claimed reward"] = function()
        local _, claimed = Dupe.levels()
        if claimed < 1 then
            return nil, "Nothing claimed yet"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(LevelService, "ClaimLevelRewards", claimed))
        end
        return c, ("level %d again"):format(claimed), claimed
    end
    TESTS["Level: Claim All + Claim together"] = function()
        local level, claimed = Dupe.levels()
        if level <= claimed then
            return nil, ("No unclaimed level reward (level %d, claimed %d)"):format(level, claimed)
        end
        local c = {}
        for i = 1, Settings.DupeBurst do
            table.insert(c, i % 2 == 1 and call(LevelService, "ClaimLevelRewards") or call(LevelService, "ClaimLevelRewards", claimed + 1))
        end
        return c, ("level %d, Claim All and Claim mixed"):format(claimed + 1), claimed + 1
    end
    TESTS["Quest: race a finished quest"] = function()
        local q = QuestService and findQuest()
        if not q then
            return nil, "No finished, unclaimed quest found"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(QuestService, "Claim", q.index, q.seasonal))
        end
        return c, ("quest #%d%s"):format(q.index, q.seasonal and " (seasonal)" or "")
    end
    TESTS["Quest: Claim All + Claim together"] = function()
        local q = QuestService and findQuest()
        if not q then
            return nil, "No finished, unclaimed quest found"
        end
        local c = {}
        for i = 1, Settings.DupeBurst do
            table.insert(c, i % 2 == 1 and call(QuestService, "ClaimAll", q.seasonal) or call(QuestService, "Claim", q.index, q.seasonal))
        end
        return c, ("quest #%d, Claim All and Claim mixed"):format(q.index)
    end
    TESTS["Daily present: race (free)"] = function()
        if not SeasonService then
            return nil, "SeasonService not found"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(SeasonService, "ClaimDailyPresent", Settings.DupeIndex, true))
        end
        return c, ("daily present %d (free)"):format(Settings.DupeIndex)
    end
    TESTS["Daily present: race (quest)"] = function()
        if not SeasonService then
            return nil, "SeasonService not found"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(SeasonService, "ClaimDailyPresent", Settings.DupeIndex, false))
        end
        return c, ("daily present %d (quest)"):format(Settings.DupeIndex)
    end
    TESTS["Challenge reward: race"] = function()
        if not ChallengeService then
            return nil, "ChallengeService not found"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(ChallengeService, "ClaimReward", Settings.DupeIndex))
        end
        return c, ("challenge reward %d"):format(Settings.DupeIndex)
    end
    TESTS["Season end reward: race"] = function()
        if not SeasonService then
            return nil, "SeasonService not found"
        end
        local c = {}
        for _ = 1, Settings.DupeBurst do
            table.insert(c, call(SeasonService, "RequestRebirthReward"))
        end
        return c, "season end reward"
    end
    Dupe.MODES = { "Level: race the next reward", "Level: re-claim a claimed reward", "Level: Claim All + Claim together",
        "Quest: race a finished quest", "Quest: Claim All + Claim together", "Daily present: race (free)",
        "Daily present: race (quest)", "Challenge reward: race", "Season end reward: race" }

    function Dupe.run()
        if Dupe.running then
            return
        end
        local test = TESTS[Settings.DupeMode]
        if not test then
            Dupe.info = "Pick a test"
            return
        end
        if Settings.DupeMode:sub(1, 5) == "Level" and not (LevelService and LevelService.ClaimLevelRewards) then
            Dupe.info = "LevelService not found"
            return
        end
        local calls, label, level = test()
        if not calls then
            Dupe.info = label
            return
        end
        Dupe.running = true
        local _, claimed = Dupe.levels()
        local expected, reward = "?", nil
        if level then
            expected, reward = rewardText(level)
        end
        Dupe.info = ("Testing %s x%d..."):format(label, #calls)
        task.spawn(function()
            local before = snapshot()
            -- All in the same frame, so they reach the server together.
            local done = 0
            for _, fn in calls do
                task.spawn(function()
                    fn()
                    done += 1
                end)
            end
            local t0 = os.clock()
            while done < #calls and os.clock() - t0 < 8 do
                task.wait(0.1)
            end
            task.wait(2)
            local after = snapshot()
            pcall(function()
                stats = DataService:Get("Statistics"):expect() or stats
            end)
            local _, claimedNow = Dupe.levels()
            local changes = {}
            for k, v in after do
                local d = v - (before[k] or 0)
                if d ~= 0 and not k:find("Timestamp") and not k:find("Time$") then
                    table.insert(changes, ("%s %+g"):format(k, d))
                end
            end
            table.sort(changes)
            local verdict = #changes > 0 and "check what changed: anything more than one reward's worth is a dupe" or "nothing changed: refused"
            local value = reward and type(reward.Value) == "number" and reward.Value or nil
            if value then
                local best = 0
                for k, v in after do
                    local d = v - (before[k] or 0)
                    if d > 0 and d % value == 0 and (k:lower():find(tostring(reward.Type):lower(), 1, true)
                        or (reward.Type == "Currency" and (k:find("Yen") or k:find("Currency")))) then
                        best = math.max(best, d / value)
                    end
                end
                local reclaim = Settings.DupeMode:find("re%-claim") ~= nil
                if best >= 2 then
                    verdict = ("DUPED: paid %dx. Rejoin and check it stayed"):format(best)
                elseif best == 1 then
                    verdict = reclaim and "Paid again on a claimed level: DUPE" or "Paid once: no dupe"
                else
                    verdict = reclaim and "Refused: no dupe" or "Nothing paid out (claim refused?)"
                end
            end
            Dupe.info = ("%s%s\nLevel claimed counter %d -> %d\n%s\n%s"):format(label, level and (", " .. expected .. " each") or "",
                claimed, claimedNow, verdict, #changes > 0 and table.concat(changes, "\n", 1, math.min(#changes, 8)) or "no profile numbers changed")
            Dupe.running = false
        end)
    end
end

--// Anti-AFK and level rewards \\--
do
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, conn in getconnections(LocalPlayer.Idled) do
                if not idled[conn] and pcall(conn.Disable, conn) then
                    idled[conn] = true
                end
            end
        elseif next(idled) then
            for conn in idled do
                pcall(conn.Enable, conn)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for conn in idled do
            pcall(conn.Enable, conn)
        end
    end)
    loop(60, function()
        if Settings.AutoLevelRewards and LevelService and LevelService.ClaimLevelRewards then
            pcall(LevelService.ClaimLevelRewards, LevelService)
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Volleyball Legends",
    Footer = "dookie hub · Ui3",
    Icon = "volleyball",
    Size = UDim2.fromOffset(640, 500),
    ConfigFolder = "Ui3/VolleyballLegends",
})
local function toggle(box, key, text, tip, after)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
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
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end

do
    local Tab = Window:AddTab("Hitting", "hand", "Hitbox and auto moves")
    local Box = Tab:AddLeftGroupbox("Hitbox expander", "expand")
    toggle(Box, "Hitbox", "Hitbox expander", "Makes the game's own hit area bigger. The server still wants the ball within 20 studs (30 on a dive)")
    slider(Box, "SpikeScale", "Spike / jump set", 1, 3, 1, "x", "No server hitbox for these, so they're the safest to grow")
    slider(Box, "ReceiveScale", "Bump / set / dive", 1, 2.5, 1, "x", "These also have a server hitbox. Past about 1.5x some hits can get refused")
    slider(Box, "BlockScale", "Block", 1, 2.5, 1, "x", "Also has a server hitbox")
    toggle(Box, "ShowHitboxes", "Show hitboxes", "The game's own debug view of each hitbox as you swing")
    local HitLabel = Box:AddLabel("...", true)

    local AutoBox = Tab:AddRightGroupbox("Auto moves", "zap")
    toggle(AutoBox, "AutoReceive", "Auto receive", "Bumps (or sets) when the ball drops into your reach on your side")
    dropdown(AutoBox, "ReceiveMove", "Receive with", { "Bump", "Set" })
    slider(AutoBox, "ReceiveHeight", "Only below", 3, 20, 0, " studs", "How high above the floor the ball can be")
    toggle(AutoBox, "AutoSpike", "Auto spike", "Spikes the moment the ball is in reach while you're in the air")
    toggle(AutoBox, "JumpForSpike", "Jump for me", "Also jumps at the right time so you meet the ball at the top. Stand on the green SPIKE marker")
    toggle(AutoBox, "AutoBlock", "Auto block", "Blocks when the ball comes over the net while you're in the air")
    toggle(AutoBox, "JumpForBlock", "Jump to block", "Jumps when they hit near the net and you're at the net")
    toggle(AutoBox, "AutoDive", "Auto dive to their spike",
        "When they spike it at your side out of your reach, dives to where it comes down. Only if a dive gets there in time (your style's dive speed), and only at the last good moment. Works with fast spikes")
    local AutoLabel = AutoBox:AddLabel("...", true)
    loop(0.3, function()
        HitLabel:SetText(("Hitbox: %s\nSpike reach about %d studs"):format(Hit.status, math.floor(Hit.reach("Spike"))))
        AutoLabel:SetText(("Last: %s"):format(Auto.info))
    end)
end

do
    local Tab = Window:AddTab("Aim", "crosshair", "Spike and serve aim")
    local Box = Tab:AddLeftGroupbox("Spike aim", "crosshair")
    dropdown(Box, "SpikeAim", "Aim spikes at", AIM_MODES,
        "Open spot: farthest from everyone. Gap: between the two players farthest apart. At a player: at the nearest one's feet. Cross / line corners are the back corners across from you and on your side")
    toggle(Box, "NoOvershoot", "Don't overshoot",
        "Uses how far your spikes really go (learned from your last spikes) and turns the aim until it lands inside their court")
    toggle(Box, "ControlDistance", "Control length with tilt",
        "Once it has learned how your tilt changes your spike length, it sets the tilt so the spike lands at the aim spot")
    local AimLabel = Box:AddLabel("...", true)
    local Serve = Tab:AddRightGroupbox("Serve", "send")
    toggle(Serve, "ServePower", "Set serve charge", "Your serve uses this charge instead of the bar")
    slider(Serve, "ServeCharge", "Charge", 0.3, 1, 2, "", "1 is a full bar. Full can fly out on strong styles")
    toggle(Serve, "ServeAim", "Steer serve to the aim spot", "Turns the toss left or right toward the spike aim spot. Needs spike aim on")
    loop(0.3, function()
        local m = Learn.myModel()
        local model = m and ((math.abs(m.b) > 1) and ("%d studs + %d per tilt (%d spikes)"):format(math.floor(m.a), math.floor(m.b), m.n)
            or ("about %d studs (%d spikes)"):format(math.floor(m.mean), m.n)) or "not learned yet: spike a few times"
        AimLabel:SetText(("Status: %s\nLast: %s\nYour spike length: %s"):format(Shots.status, Shots.last, model))
    end)
end

do
    local Tab = Window:AddTab("Helper", "eye", "See where the ball goes")
    local Box = Tab:AddLeftGroupbox("Visual helper", "eye")
    toggle(Box, "Helper", "Visual helper", "Draws the ball's path and where to go, with the game's own ball physics")
    toggle(Box, "ShowPath", "Ball path", "Red when the other team hit it, green when it ends on your side")
    toggle(Box, "ShowLanding", "Landing spot", "Yellow ring where it comes down: INCOMING when they spiked it at you, RECEIVE on your side")
    toggle(Box, "ShowSpikeSpot", "Spike spot", "Green ring where to jump from to spike it, and when to jump")
    toggle(Box, "ShowAimSpot", "Spike target", "Red ring where you're aiming, pink ring where your spike should land with its real length")
    toggle(Box, "ShowForecast", "Their spike / serve forecast",
        "Orange ring and line: where an opponent's spike or spike serve will go, from where they're facing and how far their spikes went before. Shown before they hit it")
    toggle(Box, "HelperLabels", "Labels")
    local Info = Tab:AddRightGroupbox("Now", "info")
    local InfoLabel = Info:AddLabel("...", true)
    loop(0.2, function()
        local vel = Predict.vel
        InfoLabel:SetText(vel and ("Ball speed %d, gravity x%.1f%s\n%s\nLands in %s"):format(math.floor(vel.Magnitude),
            Track.gm or 1, (Track.gm or 1) > 1.6 and " (fast spike)" or "",
            Predict.incoming and "They hit it last" or "Your team hit it last",
            Predict.landT and ("%.1fs"):format(Predict.landT) or "-") or "No ball in play")
    end)
end

do
    local Tab = Window:AddTab("Player", "user", "Movement, ESP and more")
    local Move = Tab:AddLeftGroupbox("Movement", "move")
    toggle(Move, "SpeedOn", "Speed boost", "Multiplies your style's speed")
    slider(Move, "SpeedMult", "Speed", 1, 2, 2, "x")
    toggle(Move, "JumpOn", "Jump boost", "Multiplies your style's jump power")
    slider(Move, "JumpMult", "Jump", 1, 1.6, 2, "x")
    toggle(Move, "DiveOn", "Dive boost", "Multiplies your style's dive speed")
    slider(Move, "DiveMult", "Dive", 1, 2, 2, "x")
    local MoveLabel = Move:AddLabel("...", true)
    local Misc = Tab:AddRightGroupbox("Other", "settings")
    toggle(Misc, "EspPlayers", "Player ESP", "Teammates blue, opponents red, with their style and who hit last")
    toggle(Misc, "AntiAfk", "Anti-AFK")
    toggle(Misc, "AutoLevelRewards", "Auto claim level rewards", "Claims level rewards every minute through the game's own claim")
    loop(0.5, function()
        MoveLabel:SetText(("Movement: %s"):format(Moves.status))
    end)
end

do
    local Tab = Window:AddTab("Rewards", "gift", "Rolls and level rewards")
    local RollBox = Tab:AddLeftGroupbox("Rolls", "dice-5")
    toggle(RollBox, "InstaRoll", "Insta roll",
        "Your Spin buttons work as normal (normal spin = normal, lucky = lucky) but skip the reel and the rarity cutscene. The server picks the style the moment you press, so nothing about the odds changes")
    local RollLabel = RollBox:AddLabel("...", true)

    local DupeBox = Tab:AddRightGroupbox("Level reward dupe test", "copy")
    dropdown(DupeBox, "DupeMode", "Test", Dupe.MODES,
        "Race: the same claim several times at once. Claim All + Claim: two different server handlers for the same reward at once. Daily present and challenge use the index below")
    slider(DupeBox, "DupeBurst", "Claims at once", 2, 8, 0, "")
    slider(DupeBox, "DupeIndex", "Index (daily present / challenge)", 1, 30, 0, "", "Which present or challenge level to claim: count from the first one in that menu")
    DupeBox:AddButton({ Text = "Run test", Func = Dupe.run,
        Tooltip = "Fires once per press. The game has its own ban system and this is what it would look for: use an alt" })
    DupeBox:AddButton({ Text = "Rejoin", Func = function()
        pcall(function()
            game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
        end)
    end, Tooltip = "Rejoin to see whether a duped reward stayed after saving" })
    local LevelLabel = DupeBox:AddLabel("...", true)
    local DupeLabel = DupeBox:AddLabel("...", true)
    loop(0.5, function()
        RollLabel:SetText(("Insta roll: %s\nRolls sped up: %d"):format(Rolls.status, Rolls.count))
        local level, claimed = Dupe.levels()
        LevelLabel:SetText(("Level %d, rewards claimed up to %d (%d unclaimed)"):format(level, claimed, math.max(0, level - claimed)))
        DupeLabel:SetText(Dupe.info)
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
Genv.__VblUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

local missing = {}
for name, m in { Knit = Knit, Physics = Physics, State = State, Hitbox = ClientHitbox, Moves = RegDoMove, Ball = BallController } do
    if not m then
        table.insert(missing, name)
    end
end
notify("Loaded" .. (#missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or ""), 4)

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
    AutoBlock = false, JumpForBlock = false,
    -- aim
    SpikeAim = "Off", ServePower = false, ServeCharge = 1, ServeAim = false,
    -- visual helper
    Helper = true, ShowPath = true, ShowLanding = true, ShowSpikeSpot = true, ShowAimSpot = true, HelperLabels = true,
    -- movement
    SpeedOn = false, SpeedMult = 1.2, JumpOn = false, JumpMult = 1.15, DiveOn = false, DiveMult = 1.3,
    -- esp / misc
    EspPlayers = false, AntiAfk = true, AutoLevelRewards = false,
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
local LevelService = service("LevelService")

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

--// Prediction: the game's own ball physics, run ahead \\--
-- Returns samples { p, v, t } up to the first floor hit, plus that landing.
local Predict = { samples = {}, landing = nil, landT = nil }
do
    local DT = 1 / 30
    function Predict.run(pos, vel, obj, maxT)
        local samples = { { p = pos, v = vel, t = 0 } }
        local proxy = {
            ID = obj and obj.ID, Target = obj and obj.Target, GravityMultiplier = obj and obj.GravityMultiplier,
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
                local nv = vel - Vector3.new(0, g * DT, 0)
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

--// Spike aim target: the open spot or the far corner of their court \\--
local Aim = {}
do
    function Aim.target()
        local mode = Settings.SpikeAim
        if mode == "Off" then
            return nil
        end
        local lines, net, sign = Court.lines(), Court.net(), Court.mySign()
        if not (lines and net and sign) then
            return nil
        end
        local cf, size = lines.CFrame, lines.Size
        local cx, cz = cf.Position.X, cf.Position.Z
        local hx, hz = size.X / 2 - 3, size.Z / 2 - 3
        local floor = Court.floorY(cf.Position)
        local root = rootPart()
        -- Their half runs from the net to the far line, on the other side from you.
        local zNet = net.Position.Z
        local zFar = cz - sign * hz
        if mode == "Far corner" then
            local x = root and ((root.Position.X > cx) and (cx - hx) or (cx + hx)) or (cx + hx)
            return Vector3.new(x, floor, zFar)
        end
        local opp = Court.opponents()
        local best, bestScore
        for i = 0, 6 do
            for j = 1, 6 do
                local x = cx - hx + (2 * hx) * i / 6
                local z = zNet + (zFar - zNet) * (j / 6)
                local p = Vector3.new(x, floor, z)
                local score = math.huge
                for _, o in opp do
                    score = math.min(score, (flat(o) - flat(p)).Magnitude)
                end
                if #opp == 0 then
                    score = (p - net.Position).Magnitude
                end
                if not bestScore or score > bestScore then
                    best, bestScore = p, score
                end
            end
        end
        return best
    end
    loop(0.2, function()
        Aim.spot = Aim.target()
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

    loop(1 / 30, function()
        if not (Settings.AutoReceive or Settings.AutoSpike or Settings.AutoBlock) then
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
            if alive() and type(data) == "table" and data.Move == "Spike" and Settings.SpikeAim ~= "Off" then
                local root, target = rootPart(), Aim.spot
                if root and target then
                    local dir = flat(target - root.Position)
                    if dir.Magnitude > 1 then
                        dir = dir.Unit
                        data.LookVector = dir
                        local tilt = data.TiltDirection
                        if typeof(tilt) == "Vector3" then
                            data.TiltDirection = dir * flat(tilt).Magnitude + Vector3.new(0, tilt.Y, 0)
                        end
                        Shots.last = ("spike aimed %s"):format(Settings.SpikeAim:lower())
                    end
                end
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

        -- Where your spike will be aimed.
        place(Target, Aim.spot, "your spike goes here", on and Settings.ShowAimSpot and Settings.SpikeAim ~= "Off")
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
    local AutoLabel = AutoBox:AddLabel("...", true)
    loop(0.3, function()
        HitLabel:SetText(("Hitbox: %s\nSpike reach about %d studs"):format(Hit.status, math.floor(Hit.reach("Spike"))))
        AutoLabel:SetText(("Last: %s"):format(Auto.info))
    end)
end

do
    local Tab = Window:AddTab("Aim", "crosshair", "Spike and serve aim")
    local Box = Tab:AddLeftGroupbox("Spike aim", "crosshair")
    dropdown(Box, "SpikeAim", "Aim spikes at", { "Off", "Open spot", "Far corner" },
        "Open spot: the place on their court farthest from every player. Far corner: the back corner away from you")
    local AimLabel = Box:AddLabel("...", true)
    local Serve = Tab:AddRightGroupbox("Serve", "send")
    toggle(Serve, "ServePower", "Set serve charge", "Your serve uses this charge instead of the bar")
    slider(Serve, "ServeCharge", "Charge", 0.3, 1, 2, "", "1 is a full bar. Full can fly out on strong styles")
    toggle(Serve, "ServeAim", "Steer serve to the aim spot", "Turns the toss left or right toward the spike aim spot. Needs spike aim on")
    loop(0.3, function()
        AimLabel:SetText(("Status: %s\nLast: %s"):format(Shots.status, Shots.last))
    end)
end

do
    local Tab = Window:AddTab("Helper", "eye", "See where the ball goes")
    local Box = Tab:AddLeftGroupbox("Visual helper", "eye")
    toggle(Box, "Helper", "Visual helper", "Draws the ball's path and where to go, with the game's own ball physics")
    toggle(Box, "ShowPath", "Ball path", "Red when the other team hit it, green when it ends on your side")
    toggle(Box, "ShowLanding", "Landing spot", "Yellow ring where it comes down: INCOMING when they spiked it at you, RECEIVE on your side")
    toggle(Box, "ShowSpikeSpot", "Spike spot", "Green ring where to jump from to spike it, and when to jump")
    toggle(Box, "ShowAimSpot", "Spike target", "Red ring where your aimed spike goes")
    toggle(Box, "HelperLabels", "Labels")
    local Info = Tab:AddRightGroupbox("Now", "info")
    local InfoLabel = Info:AddLabel("...", true)
    loop(0.2, function()
        local vel = Predict.vel
        InfoLabel:SetText(vel and ("Ball speed %d\n%s\nLands in %s"):format(math.floor(vel.Magnitude),
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

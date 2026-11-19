--// Volley Bomb ----------------------------------------------------------------------------------
-- game 10774204862 (New Players place 125848858933944, built against version 29; the Pro
-- place 97790681249268 only swaps the ball's escalation table). Built on Ui3.
-- How the game works, from its own client code:
--   Field    Each player stands in a square zone. BallController._balls[arena].Zones holds
--            the zone parts (attribute Occupied when someone is in it). A ball that lands
--            in an empty zone bounces on to the nearest occupied one; one that lands in an
--            occupied zone blasts (Ball.BlastRadius, 15 studs).
--   Ball     ReplicatedStorage.Shared.Modules.Ball. A state { Origin, Velocity, Gravity,
--            Time, EndTime, Reflect, Server, HitZone, HitBy, HitAt, Hits, Dead, Magnet,
--            Frozen, Tornado... }; Ball.At(state, t) is where it is at server time t, and
--            the client follows Reflect / BounceTarget itself, so the whole flight can be
--            worked out ahead of time with the game's own functions.
--   Hits     BallController:Hit(kind, posOverride, extra) checks everything the game
--            checks (cooldowns, reach Ball.Ranges + Radius, same zone as the ball, touches
--            Hits < MaxHits per zone, the team cooldown) and sends
--            HitBall(kind, flatLookDirection, pos, serverTime, extra). The server works the
--            new flight out from that look direction, so facing a spot before the hit is
--            aiming. A Spike turns into a Bump unless you're near the top of your jump
--            (Ball.Jump >= 0.8) with the ball no lower than 0.5 below your head; it's
--            Perfect (quality >= 0.9) with the ball at most 3.5 above your head.
--   Serve    state.Server == you: Hit("Toss") throws it up, then you hit it like any ball.
--   Abilities AbilityController:ActivateEquipped() / :Activate("Dive"); the equipped one is
--            PlayerData EquippedAbility, owned ones OwnedAbilities.<name>. The Dive sets
--            the ball for you if it passes through the box in front of you.
--   Rewards  PlayerData (replion): ClaimedDailyRewards + FirstJoinTime -> ClaimDayReward(day),
--            DailyQuests / ClaimedQuests -> ClaimQuest(id), ClaimedAchievements + stats ->
--            ClaimAchievement(id), Spins / LuckySpins -> RequestSpin then RequestRewardFromSpin,
--            Money -> BuyAbility(name) / EquipAbility(name). Remotes live in Packages.Net as
--            "RE/<name>" and "RF/<name>".

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__VolleyUnload then
    pcall(Genv.__VolleyUnload)
end
Genv.__VolleyRun = (Genv.__VolleyRun or 0) + 1
local RUN = Genv.__VolleyRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__VolleyRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
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
    -- play
    AutoHit = false, AutoServe = false, ServeDelay = 0.5, AutoMove = false, AutoSpike = false, WaitPerfect = true,
    AutoDive = false, BlastDodge = false, BackToMiddle = false, LeaveToTeammate = false,
    -- aim
    AimMode = "Hardest to save", AimFocus = "Anyone", ReachExtra = 0,
    -- abilities
    AutoAbility = false, AutoBuy = false, BuyList = {}, EquipNewest = false,
    -- esp
    EspLanding = false, EspPath = false, EspBlast = false, EspZones = false, EspPlayers = false, Hud = false,
    -- rewards and rounds
    AutoDaily = false, AutoQuests = false, AutoAchievements = false, AutoLike = false, AutoSpin = false,
    VoteMode = "Off", AutoTeamUp = false, StayActive = false,
    -- player
    SpeedOn = false, WalkSpeed = 22, JumpOn = false, JumpPower = 58, AntiAfk = true,
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
                warn("[Volley] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Volley Bomb", Description = text, Time = seconds or 3 })
end
local function comma(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end
local Tried = {}
local function tryOnce(key, every)
    local t = Tried[key]
    if t and os.clock() - t < every then
        return false
    end
    Tried[key] = os.clock()
    return true
end
local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end
local function flatDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function flatUnit(v)
    local f = Vector3.new(v.X, 0, v.Z)
    return f.Magnitude > 1e-4 and f.Unit or Vector3.new(0, 0, -1)
end
local function pivotOf(inst)
    if not (inst and inst.Parent) then
        return nil
    end
    if inst:IsA("BasePart") then
        return inst.Position
    end
    local hrp = inst:FindFirstChild("HumanoidRootPart")
    if hrp then
        return hrp.Position
    end
    local ok, cf = pcall(inst.GetPivot, inst)
    return ok and cf.Position or nil
end
local function uiParent()
    return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
end
local function nameOf(x)
    if x == LocalPlayer then
        return "you"
    end
    if typeof(x) == "Instance" then
        return x:IsA("Player") and x.DisplayName or x.Name
    end
    if type(x) == "table" then
        return tostring(x.name or x.Name or "a bot")
    end
    return tostring(x)
end

--// The game \\--
local function find(root, names, timeout)
    local cur = root
    for _, n in names do
        if not cur then
            return nil
        end
        cur = timeout and cur:WaitForChild(n, timeout) or cur:FindFirstChild(n)
    end
    return cur
end
local function req(inst)
    if not inst then
        return nil
    end
    local ok, r = pcall(require, inst)
    return ok and type(r) == "table" and r or nil
end
local RS = ReplicatedStorage
local Ball = req(find(RS, { "Shared", "Modules", "Ball" }, 20))
local BC = req(find(RS, { "Shared", "Controllers", "BallController" }, 20))
local AC = req(find(RS, { "Shared", "Controllers", "AbilityController" }, 10))
local Replion = req(find(RS, { "Packages", "replion" }, 10))
local AbilityInfo = req(find(RS, { "Data", "Info", "Abilities" }, 5)) or {}
local QuestInfo = req(find(RS, { "Data", "Info", "Quests" }, 5)) or {}
local AchievementInfo = req(find(RS, { "Data", "Info", "AchievementConfig" }, 5)) or {}
local Teammodes = req(find(RS, { "Data", "Info", "Teammodes" }, 5)) or {}
local DailyInfo = req(find(RS, { "Data", "DailyRewards" }, 5)) or {}
local SpinnerInfo = req(find(RS, { "Data", "Info", "Spinner" }, 5)) or {}
local AbilityMods = {}
do
    local folder = find(RS, { "Shared", "Modules", "Abilities" }, 5)
    for _, m in folder and folder:GetChildren() or {} do
        AbilityMods[m.Name] = req(m)
    end
end
local NetFolder = find(RS, { "Packages", "Net" }, 10)
local function re(name)
    return NetFolder and NetFolder:FindFirstChild("RE/" .. name)
end
local function rf(name)
    return NetFolder and NetFolder:FindFirstChild("RF/" .. name)
end
local function fire(name, ...)
    local r = re(name)
    if r then
        r:FireServer(...)
        return true
    end
    return false
end
local function invoke(name, ...)
    local r = rf(name)
    if not r then
        return nil
    end
    local ok, res = pcall(r.InvokeServer, r, ...)
    return ok and res or nil
end

-- Some executors hand back a fresh copy of a module the game already required. The
-- game's own ball controller is the one with balls in it, so look for that one.
local function gcFind(test)
    if typeof(getgc) ~= "function" then
        return nil
    end
    local ok, list = pcall(getgc, true)
    if not ok then
        return nil
    end
    for _, v in list do
        if type(v) == "table" then
            local ok2, hit = pcall(test, v)
            if ok2 and hit then
                return v
            end
        end
    end
    return nil
end
if BC then
    local t0 = os.clock()
    while alive() and next(BC._balls or {}) == nil and os.clock() - t0 < 6 do
        task.wait(0.25)
    end
    if next(BC._balls or {}) == nil then
        local real = gcFind(function(t)
            local balls = rawget(t, "_balls")
            return type(balls) == "table" and next(balls) ~= nil and type(rawget(t, "Hit")) == "function"
        end)
        if real then
            BC = real
            AC = gcFind(function(t)
                return type(rawget(t, "_lastUsed")) == "table" and type(rawget(t, "ActivateEquipped")) == "function"
                    and type(rawget(t, "_tracks")) == "table" and next(rawget(t, "_tracks")) ~= nil
            end) or AC
            Replion = gcFind(function(t)
                return type(rawget(t, "GetReplion")) == "function" and t:GetReplion("PlayerData") ~= nil
            end) or Replion
        end
    end
end
if not alive() then
    return
end

local function pdata()
    if not Replion then
        return nil
    end
    local ok, r = pcall(Replion.GetReplion, Replion, "PlayerData")
    return ok and r or nil
end
local function pget(key)
    local r = pdata()
    if not r then
        return nil
    end
    local ok, v = pcall(r.Get, r, key)
    if ok then
        return v
    end
    return nil
end

local BLAST = (Ball and Ball.BlastRadius) or 15
local ABILITIES = {}
for name, info in AbilityInfo do
    table.insert(ABILITIES, { name = name, price = tonumber(info.Price) or 0, display = info.DisplayName or name })
end
table.sort(ABILITIES, function(a, b)
    return a.price < b.price
end)
local ABILITY_NAMES = {}
for _, a in ABILITIES do
    table.insert(ABILITY_NAMES, a.name)
    Settings.BuyList[a.name] = true
end
local function owned(name)
    return pget({ "OwnedAbilities", name }) == true
end

--// Who's where \\--
local function sideOf(who)
    if who == LocalPlayer then
        return "me"
    end
    local myRole = LocalPlayer:GetAttribute("Role")
    if myRole ~= nil then
        return who:GetAttribute("Role") == myRole and "ally" or "enemy"
    end
    local myTeam = LocalPlayer:GetAttribute("Team")
    if myTeam ~= nil and who:GetAttribute("Team") == myTeam then
        return "ally"
    end
    return "enemy"
end
local function peopleIn(arena)
    local list = {}
    for _, plr in Players:GetPlayers() do
        if plr:GetAttribute("InRound") == arena then
            local c = plr.Character
            local r = c and c:FindFirstChild("HumanoidRootPart")
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if r and (not h or h.Health > 0) then
                table.insert(list, { who = plr, name = plr.DisplayName, pos = r.Position, side = sideOf(plr), char = c })
            end
        end
    end
    for _, bot in CollectionService:GetTagged("Bot") do
        if bot:GetAttribute("Arena") == arena and bot:IsDescendantOf(Workspace) then
            local pos = pivotOf(bot)
            if pos then
                table.insert(list, { who = bot, name = bot.Name, pos = pos, side = sideOf(bot), char = bot, bot = true })
            end
        end
    end
    return list
end
local function zoneIndex(zones, zone)
    return zones and zone and table.find(zones, zone) or nil
end
local function clampToZone(z, pos, inset)
    local lp = z.CFrame:PointToObjectSpace(pos)
    local hx, hz = math.max(z.Size.X / 2 - inset, 0), math.max(z.Size.Z / 2 - inset, 0)
    return z.CFrame:PointToWorldSpace(Vector3.new(math.clamp(lp.X, -hx, hx), lp.Y, math.clamp(lp.Z, -hz, hz)))
end

--// Where the ball goes \\--
-- The whole flight from the current state on: wall bounces (Reflect) and the bounce
-- from an empty zone to the nearest occupied one, exactly as the client plays them.
local function buildPath(st, zones)
    local list = { st }
    local cur = st
    for _ = 1, 5 do
        if cur.Magnet or cur.Dead or cur.EndTime == math.huge or cur.EndTime <= cur.Time then
            break
        end
        local nextState
        if cur.Reflect then
            local ok, b = pcall(Ball.Bounce, cur)
            nextState = ok and b or nil
        elseif zones then
            local landing = Ball.At(cur, cur.EndTime)
            local target = Ball.BounceTarget(zones, landing)
            if target then
                local ok, b = pcall(Ball.BounceTo, cur, target.Position)
                nextState = ok and b or nil
            end
        end
        if not nextState then
            break
        end
        table.insert(list, nextState)
        cur = nextState
    end
    return list
end
local Pred = {}
local function predict(st, zones)
    if Pred.st == st and Pred.zones == zones and os.clock() - Pred.at < 0.5 then
        return Pred
    end
    local p = { st = st, zones = zones, at = os.clock() }
    if not (st.Magnet or st.Dead) and st.EndTime ~= math.huge and st.EndTime > st.Time then
        local ok, path = pcall(buildPath, st, zones)
        if ok then
            p.path = path
            local last = path[#path]
            p.landTime = last.EndTime
            p.landing = Ball.At(last, last.EndTime)
            p.landZone = zones and Ball.ZoneAt(zones, p.landing)
            p.bounces = #path - 1
        end
    end
    Pred = p
    return p
end
-- Never asks a Magnet state about the future (Ball.At moves a magnet ball along).
local function posAt(p, t)
    local path = p.path
    if not path then
        return Ball.At(p.st, math.min(t, Workspace:GetServerTimeNow()))
    end
    for i = #path, 1, -1 do
        if t >= path[i].Time or i == 1 then
            return Ball.At(path[i], t)
        end
    end
    return Ball.At(path[1], t)
end

local function jumpInfo(hum)
    local g = Workspace.Gravity
    local v0 = hum.UseJumpPower and hum.JumpPower or math.sqrt(2 * g * hum.JumpHeight)
    return { v0 = v0, apex = v0 / g, height = v0 * v0 / (2 * g), g = g }
end

-- How far a dive has carried you after tau seconds (Dive: 120 -> 30 studs/s over 0.5 s, quad out).
local DiveDist = {}
do
    local d, dt = 0, 0.002
    local nextMark = 0
    for i = 0, 250 do
        local tau = i * dt
        if tau >= nextMark - 1e-9 then
            DiveDist[math.floor(nextMark * 100 + 0.5)] = d
            nextMark += 0.01
        end
        local x = math.min(tau / 0.5, 1)
        local e = 1 - (1 - x) * (1 - x)
        d += (120 + (30 - 120) * e) * dt
    end
end
local function diveDist(tau)
    return DiveDist[math.clamp(math.floor(tau * 100 + 0.5), 0, 50)] or 30
end

--// Context: one look at the game each frame \\--
local function context()
    if not (Ball and BC) then
        return nil
    end
    local st = BC._state
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local head = char and char:FindFirstChild("Head")
    if not (st and root and hum and head and hum.Health > 0) then
        return nil
    end
    local arena = LocalPlayer:GetAttribute("InRound")
    local name = arena or "Main"
    local rec = BC._balls and BC._balls[name]
    local zones = rec and rec.Zones
    local now = Workspace:GetServerTimeNow()
    local c = { st = st, char = char, root = root, hum = hum, head = head, arena = name, playing = arena ~= nil, zones = zones, now = now }
    c.myZone = zones and Ball.ZoneAt(zones, root.Position) or nil
    c.ballPos = Ball.Contain(Ball.At(st, now))
    c.ballZone = zones and Ball.ZoneAt(zones, c.ballPos) or nil
    c.ballDist = (c.ballPos - root.Position).Magnitude
    c.people = peopleIn(name)
    c.occ = {}
    if zones then
        for _, o in c.people do
            local z = Ball.ZoneAt(zones, o.pos)
            o.zone = z
            if z then
                c.occ[z] = c.occ[z] or {}
                table.insert(c.occ[z], o)
            end
        end
    end
    c.pred = predict(st, zones)
    c.incoming = c.myZone ~= nil and not st.Dead and st.Server == nil and c.pred.landZone == c.myZone
    c.eta = c.pred.landTime and (c.pred.landTime - now) or nil
    c.grounded = hum.FloorMaterial ~= Enum.Material.Air
    return c
end

--// Aim \\--
-- Tries a ring of directions with the game's own hit and flight functions and picks
-- the one that's hardest to save: lands in an enemy's zone, inside the blast, and
-- farther from them than they can cover before it comes down.
local Aim = { dir = nil, info = "-", key = nil, at = 0, job = nil }
local DIRS = {}
for i = 0, 23 do
    local a = i / 24 * math.pi * 2
    table.insert(DIRS, Vector3.new(math.cos(a), 0, math.sin(a)))
end
local function predictMods(kind)
    local m = { Boost = 1 }
    local active = AC and AC._active or {}
    if kind == "Spike" then
        local adr = AbilityMods.Adrenaline
        if active.Adrenaline and adr then
            m.Boost *= adr.SpikeBoost or 1
            m.MinSpeed = adr.MinSpikeSpeed
        end
        local sup = AbilityMods.Superspike
        if active.Superspike and sup and sup.Apply then
            pcall(sup.Apply, sup, m)
        end
    end
    return m
end
local function scoreLanding(c, L, flight, bounces)
    local z = Ball.ZoneAt(c.zones, L)
    if not z then
        return -300, nil
    end
    if z == c.myZone then
        return -1000, nil
    end
    local nearest, who, enemiesIn, alliesNear, meNear = math.huge, nil, 0, 0, false
    local focused = false
    for _, o in c.people do
        local d = flatDist(o.pos, L)
        if o.side == "me" then
            meNear = meNear or d <= BLAST
        elseif o.side == "ally" then
            if d <= BLAST then
                alliesNear += 1
            end
        elseif o.zone == z then
            if d < nearest then
                nearest, who = d, o
            end
            if d <= BLAST then
                enemiesIn += 1
            end
            if Settings.AimFocus ~= "Anyone" and o.name == Settings.AimFocus then
                focused = true
            end
        end
    end
    if meNear then
        return -900, nil
    end
    if not who then
        return -500, nil
    end
    local need = math.max(nearest - 7, 0) / 16
    local s = 100 + (need - flight) * 60 + math.min(enemiesIn, 3) * 25 - alliesNear * 150 - bounces * 20
    if nearest <= BLAST then
        s += 40
    end
    if focused then
        s += 250
    end
    return s, who.name
end
local function simLanding(c, st, kind, q, ballPos, dir, t, mods)
    local origin, d = Ball.Inside(c.zones, ballPos, dir)
    local ok, s = pcall(Ball.Hits[kind], st.Multipliers, origin, d, t, q, table.clone(mods))
    if not ok or type(s) ~= "table" then
        return nil
    end
    local okPath, path = pcall(buildPath, s, c.zones)
    if not okPath then
        return nil
    end
    local last = path[#path]
    if last.Magnet or last.EndTime == math.huge then
        return nil
    end
    return Ball.At(last, last.EndTime), last.EndTime, #path - 1
end
local function aimKey(st, kind)
    return tostring(st) .. "|" .. kind
end
-- Start working the aim out ahead of the hit (a few directions a frame).
function Aim.prepare(c, kind, q, pos, t)
    if Settings.AimMode == "Off" or not c.zones then
        return
    end
    local key = aimKey(c.st, kind)
    if Aim.key == key or (Aim.job and Aim.job.key == key) then
        return
    end
    local cands = table.clone(DIRS)
    table.insert(cands, flatUnit(c.root.CFrame.LookVector))
    Aim.job = { key = key, kind = kind, q = q, pos = pos, t = t, st = c.st, cands = cands, i = 1, mods = predictMods(kind) }
end
function Aim.step(c, budget)
    local job = Aim.job
    if not job then
        return
    end
    if job.st ~= c.st then
        Aim.job = nil
        return
    end
    for _ = 1, budget do
        local d = job.cands[job.i]
        if not d then
            Aim.key, Aim.dir, Aim.score, Aim.at = job.key, job.best, job.bestScore, os.clock()
            Aim.info = job.best and (job.bestWho and ("at " .. job.bestWho) or "open spot") or "no good spot"
            Aim.job = nil
            return
        end
        job.i += 1
        local L, landT, bounces = simLanding(c, job.st, job.kind, job.q, job.pos, d, job.t, job.mods)
        if L then
            local s, who = scoreLanding(c, L, landT - job.t, bounces)
            if not job.bestScore or s > job.bestScore then
                job.best, job.bestScore, job.bestWho = d, s, who
            end
        end
    end
end
-- The direction for a hit happening now.
function Aim.forHit(c, kind, q)
    if Settings.AimMode == "Off" or not c.zones or kind == "Toss" then
        return nil
    end
    local key = aimKey(c.st, kind)
    if Aim.key == key and Aim.dir then
        return Aim.dir
    end
    Aim.job = nil
    Aim.prepare(c, kind, q, c.ballPos, c.now)
    Aim.step(c, 64)
    return Aim.key == key and Aim.dir or nil
end

--// Auto play \\--
local Play = {
    info = "Off", plan = nil, hits = 0, perfects = 0, spikes = 0, bumps = 0, dives = 0, serves = 0, abilities = 0,
    groundY = nil, headOff = nil, lastAction = "-", pendingDive = nil, err = nil,
}
local Walk = { target = nil, at = 0, moving = false }
local function walkTo(c, pos)
    local target = Vector3.new(pos.X, c.root.Position.Y, pos.Z)
    if c.myZone then
        target = clampToZone(c.myZone, target, 1.2)
        target = Vector3.new(target.X, c.root.Position.Y, target.Z)
    end
    if flatDist(target, c.root.Position) < 0.7 then
        if Walk.moving then
            c.hum:MoveTo(c.root.Position)
            Walk.moving, Walk.target = false, nil
        end
        return
    end
    if not Walk.target or flatDist(Walk.target, target) > 0.5 or os.clock() - Walk.at > 0.4 then
        c.hum:MoveTo(target)
        Walk.target, Walk.at, Walk.moving = target, os.clock(), true
    end
end
local function stopWalk(c)
    if Walk.moving and c then
        c.hum:MoveTo(c.root.Position)
    end
    Walk.moving, Walk.target = false, nil
end

local function canTouchNow(c)
    local st, z = c.st, c.myZone
    if st.Dead or st.Server ~= nil then
        return false
    end
    if not Ball.CanTouch(st, z) then
        return false
    end
    if st.HitZone and st.HitZone == z and st.HitBy ~= LocalPlayer and c.now - (st.HitAt or 0) < Ball.TeamCooldown then
        return false
    end
    return true
end
local function reachOf(c, kind)
    local point = Ball.Reach(kind, c.root.Position, c.char)
    local d = (point - c.ballPos).Magnitude
    local limit = (Ball.Ranges[kind] or 7) + Ball.Radius
    return d, limit, point
end
-- Would this kind still be hittable on the next frame?
local function nextFrameOk(c, kind)
    local dt = 0.05
    local p2 = c.ballPos
    if c.pred.path then
        p2 = Ball.Contain(posAt(c.pred, c.now + dt))
        if c.pred.landTime and c.pred.landTime - c.now < dt + 0.03 then
            return false
        end
    end
    if Ball.ZoneAt(c.zones, p2) ~= c.myZone then
        return false
    end
    local g = Workspace.Gravity
    local vel = c.root.AssemblyLinearVelocity
    local root2 = c.root.Position + vel * dt - Vector3.new(0, g * dt * dt / 2, 0)
    local point2 = Ball.Reach(kind, root2, c.char)
    if (point2 - p2).Magnitude > (Ball.Ranges[kind] or 7) + Ball.Radius - 0.2 then
        return false
    end
    local dy2 = p2.Y - (c.head.Position.Y + (root2.Y - c.root.Position.Y))
    if kind == "Spike" then
        if Ball.Jump(c.char, root2) < (Ball.SpikeMinJump or 0.8) then
            return false
        end
        if dy2 < (Ball.SpikeFloor or -0.5) then
            return false
        end
    end
    return true, dy2
end

local function playTrack(kind)
    local tracks = BC._tracks
    local tr = tracks and tracks[kind]
    if tr then
        pcall(tr.Play, tr)
    end
    if kind == "Spike" and tracks and tracks.Jump then
        pcall(tracks.Jump.Stop, tracks.Jump)
    end
end
local function doHit(c, kind, resolved, q)
    local d, limit, point = reachOf(c, resolved)
    local override
    if d > limit - 0.05 then
        local extra = Settings.ReachExtra
        if d > limit + extra then
            return false
        end
        if extra > 0 then
            override = c.root.Position + (c.ballPos - point).Unit * (d - limit + 0.4)
        end
    end
    local dir = Aim.forHit(c, resolved, q)
    if dir then
        c.root.CFrame = CFrame.lookAt(c.root.Position, c.root.Position + dir)
    end
    local ok, res = pcall(BC.Hit, BC, kind, override)
    if not (ok and res) then
        return false
    end
    Play.hits += 1
    if resolved == "Spike" then
        Play.spikes += 1
        BC._spiked = true
        if q >= 0.9 then
            Play.perfects += 1
        end
        playTrack("Spike")
        Play.lastAction = q >= 0.9 and "Perfect spike" or ("Spike (" .. math.floor(q * 100) .. "%)")
    elseif resolved == "Bump" then
        Play.bumps += 1
        BC._lastBump = c.now
        playTrack("Bump")
        Play.lastAction = "Bump"
    end
    if dir and Aim.info then
        Play.lastAction ..= " " .. Aim.info
    end
    return true
end

-- Where and how to meet the ball: a perfect spike at the top of a jump if you can get
-- under it in time, else a bump.
local function makePlan(c)
    local st, now = c.st, c.now
    local J = jumpInfo(c.hum)
    local allowSpike = Settings.AutoSpike and not (AC and AC._active and AC._active.Moonball)
    if st.Magnet == LocalPlayer then
        return { kind = allowSpike and "Spike" or "Bump", t = now + J.apex, p = c.ballPos, tj = now, magnet = true }
    end
    local pred = c.pred
    local tEnd = pred.landTime
    local frozen = st.Frozen or (st.EndTime <= st.Time)
    if frozen then
        tEnd = st.Time + ((AbilityMods.Frozen and AbilityMods.Frozen.FreezeTime) or 3)
    end
    if not tEnd or tEnd <= now then
        return nil
    end
    local speed = math.max(c.hum.WalkSpeed, 1)
    local groundY = Play.groundY or c.root.Position.Y
    local headY0 = groundY + (Play.headOff or 1.5)
    local spike, bump
    local t = now + 0.04
    local last = math.min(tEnd, now + 4)
    while t <= last do
        local p = frozen and c.ballPos or Ball.Contain(posAt(pred, t))
        if Ball.ZoneAt(c.zones, p) == c.myZone then
            local D = flatDist(p, c.root.Position)
            local avail = t - now
            if allowSpike and not spike and t - J.apex >= now - 0.01 then
                local dy = p.Y - (headY0 + J.height)
                if dy >= -0.3 and dy <= 2.8 and math.max(D - 2.5, 0) <= speed * avail * 0.9 then
                    spike = { kind = "Spike", t = t, p = p, tj = t - J.apex }
                end
            end
            if not bump then
                local dyR = p.Y - groundY
                if dyR >= -2.5 and dyR <= 7.6 then
                    local tol = math.sqrt(math.max(7.8 * 7.8 - dyR * dyR, 0)) - 1
                    if math.max(D - tol, 0) <= speed * avail * 0.9 then
                        bump = { kind = "Bump", t = t, p = p }
                    end
                end
            end
            if spike and bump then
                break
            end
        end
        t += 0.03
    end
    return spike or bump
end

local function tryHit(c, plan)
    if c.ballZone ~= c.myZone or not canTouchNow(c) then
        return false
    end
    if c.now - (BC._lastHit or 0) < (Ball.HitCooldown or 0.35) then
        return false
    end
    if c.grounded then
        local d, limit = reachOf(c, "Bump")
        if d > limit + math.max(Settings.ReachExtra, 0) then
            return false
        end
        if plan and plan.kind == "Spike" and plan.t - c.now > 0.08 and nextFrameOk(c, "Bump") then
            return false
        end
        if c.now - (BC._lastBump or 0) < (Ball.BumpCooldown or 0.5) then
            return false
        end
        return doHit(c, "Bump", "Bump", 1)
    end
    local kind = BC._spiked and "Bump" or "Spike"
    local resolved, q = Ball.Resolve(kind, c.head.Position, c.ballPos, Ball.Jump(c.char, c.root.Position))
    local d, limit = reachOf(c, resolved)
    if d > limit + math.max(Settings.ReachExtra, 0) then
        return false
    end
    if resolved == "Spike" then
        -- Perfect now, good enough (if you don't wait for perfect), or the last frame a
        -- spike is still possible. Right at the edge of the window (just under your head,
        -- or just over the perfect height) it waits a frame if the ball is getting better,
        -- so a little lag on the server's side can't turn it into a bump.
        local okNext, dy2 = nextFrameOk(c, "Spike")
        if not okNext then
            return doHit(c, kind, resolved, q)
        end
        local dy = c.ballPos.Y - c.head.Position.Y
        local floor = Ball.SpikeFloor or -0.5
        local top = (Ball.SpikeSweetSpot or 3) + 0.1 * (Ball.SpikeFalloff or 5) * 0.7
        local rising = c.root.AssemblyLinearVelocity.Y > 0
        local frac = Ball.Jump(c.char, c.root.Position)
        local improving = (dy < floor + 0.35 and dy2 > dy) or (dy > top and dy2 < dy) or (rising and frac < 0.9)
        if not improving and (q >= 0.9 or (q >= 0.5 and not Settings.WaitPerfect)) then
            return doHit(c, kind, resolved, q)
        end
        return false
    end
    -- Too early in the jump (or the ball's below your head): wait while a spike can still
    -- happen, and bump only if the ball is about to get away.
    if kind == "Spike" and nextFrameOk(c, "Spike") then
        return false
    end
    if not nextFrameOk(c, "Bump") then
        if c.now - (BC._lastBump or 0) < (Ball.BumpCooldown or 0.5) then
            return false
        end
        return doHit(c, kind, resolved, q)
    end
    return false
end

local function serveStep(c)
    if not Settings.AutoServe then
        Play.info = "Your serve"
        return
    end
    if Play.serveFor ~= c.st then
        Play.serveFor = c.st
        Play.serveTime = os.clock() + Settings.ServeDelay + math.random() * 0.3
    end
    local d, limit = reachOf(c, "Toss")
    if d > limit - 0.3 then
        Play.info = "Walking to the ball to serve"
        if Settings.AutoMove then
            walkTo(c, c.ballPos)
        end
        return
    end
    if os.clock() < Play.serveTime then
        Play.info = "Serving..."
        return
    end
    if tryOnce("toss", 0.3) then
        local ok, res = pcall(BC.Hit, BC, "Toss")
        if ok and res then
            Play.serves += 1
            Play.lastAction = "Served"
        end
    end
end

local function tryDive(c)
    if not (Settings.AutoDive and AC and c.pred.path and c.grounded) then
        return false
    end
    if BC:Busy() or AC:Remaining("Dive") > 0 or not canTouchNow(c) then
        return false
    end
    local boost = (AbilityMods.Dive and AbilityMods.Dive.Boost) or 1
    local rp = c.root.Position
    local vOff = 2.5 - c.root.Size.Y / 2 - c.hum.HipHeight
    for tau = 0.06, 0.5, 0.02 do
        local b = Ball.Contain(posAt(c.pred, c.now + tau))
        if Ball.ZoneAt(c.zones, b) == c.myZone then
            local off = flat(b - rp)
            local dist = off.Magnitude
            local along = diveDist(tau) * boost + 2
            local landsIn = dist > 0.5 and Ball.ZoneAt(c.zones, rp + off.Unit * diveDist(tau) * boost) == c.myZone
            if landsIn and math.abs(dist - along) <= 2.8 and math.abs(b.Y - (rp.Y + vOff)) <= 5.2 then
                -- The dive goes the way you're moving (or facing, standing still): turn and
                -- start walking that way, then dive once the walk direction has caught up.
                local dir = off.Unit
                c.root.CFrame = CFrame.lookAt(rp, rp + dir)
                c.hum:MoveTo(rp + dir * 25)
                Walk.target, Walk.at, Walk.moving = rp + dir * 25, os.clock(), true
                Play.pendingDive = { dir = dir, at = os.clock() }
                return true
            end
        end
    end
    return false
end
local function finishDive(c)
    local pd = Play.pendingDive
    if not pd then
        return false
    end
    if os.clock() - pd.at > 0.12 or not c.grounded then
        Play.pendingDive = nil
        return false
    end
    local md = c.hum.MoveDirection
    if md.Magnitude < 0.1 or md.Unit:Dot(pd.dir) > 0.85 then
        Play.pendingDive = nil
        c.root.CFrame = CFrame.lookAt(c.root.Position, c.root.Position + pd.dir)
        pcall(AC.Activate, AC, "Dive")
        Play.dives += 1
        Play.lastAction = "Dive"
    end
    return true
end

local function dodge(c)
    local L = c.pred.landing
    local z = c.myZone
    if not (L and z) then
        return false
    end
    local best, bestD
    for _, sx in { -1, 1 } do
        for _, sz in { -1, 1 } do
            local corner = z.CFrame:PointToWorldSpace(Vector3.new(sx * (z.Size.X / 2 - 2.5), 0, sz * (z.Size.Z / 2 - 2.5)))
            local d = flatDist(corner, L)
            if not bestD or d > bestD then
                best, bestD = corner, d
            end
        end
    end
    if best then
        walkTo(c, best)
        Play.info = ("Can't save it: getting away from the blast (%d studs)"):format(math.floor(bestD))
        return true
    end
    return false
end

local OFFENSE = { Superspike = true, Curveball = true, Moonball = true, Portal = true, TornadoBall = true }
local function abilityStep(c)
    if not (Settings.AutoAbility and AC and c.playing) then
        return
    end
    local name = pget("EquippedAbility")
    local mod = name and AbilityMods[name]
    if not mod or mod.Type == "Passive" or not owned(name) then
        return
    end
    local okLeft, left = pcall(AC.Remaining, AC, name)
    if (AC._active and AC._active[name]) or not okLeft or (tonumber(left) or 1) > 0 then
        return
    end
    local st = c.st
    if st.Dead or (st.Server ~= nil and st.Server ~= LocalPlayer) then
        return
    end
    local mine = c.incoming or st.Magnet == LocalPlayer
    local eta = c.eta or math.huge
    local want = false
    if OFFENSE[name] then
        want = (mine and eta < 2.5) or st.Server == LocalPlayer
    elseif name == "Magnet" then
        want = mine and st.Server == nil and not st.Magnet and (not st.Serve or st.Hitter == LocalPlayer)
    elseif name == "Frozen" then
        want = c.incoming and not st.Frozen and Play.plan == nil and c.ballDist <= 22
    elseif name == "Forcefield" then
        want = c.incoming and c.ballZone ~= c.myZone and eta < 1.3 and c.zones and #c.zones ~= 2
    elseif name == "Adrenaline" then
        want = mine and Play.plan ~= nil and flatDist(Play.plan.p, c.root.Position) > 10
    end
    if want and tryOnce("ability", 0.6) then
        if pcall(AC.ActivateEquipped, AC) then
            Play.abilities += 1
            Play.lastAction = "Used " .. name
        end
    end
end

local function anyAuto()
    return Settings.AutoHit or Settings.AutoMove or Settings.AutoSpike or Settings.AutoServe or Settings.AutoDive
        or Settings.BlastDodge or Settings.AutoAbility
end
function Play.step()
    local c = context()
    Play.ctx = c
    if not c then
        Play.info = "Waiting for the ball and your character"
        return
    end
    if c.grounded then
        Play.groundY = c.root.Position.Y
        Play.headOff = c.head.Position.Y - c.root.Position.Y
    end
    if not anyAuto() then
        Play.info = "Off"
        Play.plan = nil
        return
    end
    if not c.playing then
        Play.info = "Not in a round"
        Play.plan = nil
        return
    end
    if not c.myZone then
        Play.info = "You're not in a zone"
        Play.plan = nil
        return
    end
    local st = c.st
    abilityStep(c)
    if st.Dead then
        Play.info = "Point over"
        Play.plan = nil
        return
    end
    if st.Server == LocalPlayer then
        Play.plan = nil
        serveStep(c)
        return
    end
    if st.Server ~= nil then
        Play.info = "Waiting for the serve"
        Play.plan = nil
        if Settings.BackToMiddle and Settings.AutoMove then
            walkTo(c, c.myZone.Position)
        end
        return
    end
    if st.Magnet and st.Magnet ~= LocalPlayer then
        Play.info = "Someone's magnet has the ball"
        Play.plan = nil
        return
    end
    if finishDive(c) then
        return
    end
    -- Only a ball that ends up in your zone is yours to play. One that's just passing over
    -- (or your own hit on its way out) is left alone, so no touches get wasted on it.
    local wanted = c.incoming or st.Magnet == LocalPlayer or (c.ballZone == c.myZone and (st.Frozen or not c.pred.path))
    local plan = wanted and Ball.CanTouch(st, c.myZone) and makePlan(c) or nil
    Play.plan = plan
    if plan then
        if plan.kind == "Spike" then
            Aim.prepare(c, "Spike", 1, plan.p, plan.t)
        else
            Aim.prepare(c, "Bump", 1, plan.p, plan.t)
        end
    end
    Aim.step(c, 4)
    if Settings.AutoHit and wanted and tryHit(c, plan) then
        return
    end
    if plan then
        local D = flatDist(plan.p, c.root.Position)
        local closerAlly = false
        if Settings.LeaveToTeammate then
            for _, o in c.occ[c.myZone] or {} do
                if o.side == "ally" and flatDist(o.pos, plan.p) + 3 < D then
                    closerAlly = true
                end
            end
        end
        if Settings.AutoMove and not closerAlly then
            walkTo(c, plan.p)
        end
        if plan.kind == "Spike" and Settings.AutoSpike and c.grounded and c.now >= plan.tj - 0.015 and D <= 5 then
            c.hum:ChangeState(Enum.HumanoidStateType.Jumping)
            BC._spiked = false
        end
        Play.info = closerAlly and "A teammate is closer" or ("%s in %.2fs (%d studs away)"):format(plan.kind == "Spike" and "Spike" or "Bump",
            math.max(plan.t - c.now, 0), math.floor(D))
        return
    end
    if c.incoming then
        if tryDive(c) then
            Play.info = "Diving for it"
            return
        end
        if Settings.BlastDodge and c.eta and c.eta < 1.6 and dodge(c) then
            return
        end
        Play.info = Ball.CanTouch(st, c.myZone) and ("Coming to you in %.1fs, can't reach it"):format(c.eta or 0)
            or "Your zone is out of touches"
        return
    end
    if Settings.BackToMiddle and Settings.AutoMove then
        walkTo(c, c.myZone.Position)
    elseif Walk.moving then
        stopWalk(c)
    end
    if c.pred.landZone then
        local who = c.occ[c.pred.landZone]
        Play.info = ("Ball going to %s"):format(who and who[1] and who[1].name or ("zone " .. tostring(zoneIndex(c.zones, c.pred.landZone))))
    else
        Play.info = "Watching the ball"
    end
end
bind(RunService.Heartbeat, function()
    if not alive() then
        return
    end
    local ok, err = pcall(Play.step)
    if not ok then
        Play.err = tostring(err)
        if tryOnce("playErr", 10) then
            warn("[Volley] " .. Play.err)
        end
    end
end)

--// ESP \\--
local Esp = {}
do
    local folder = Instance.new("Folder")
    folder.Name = "VolleyEsp"
    folder.Parent = Workspace
    local gui = Instance.new("Folder")
    gui.Name = "\0"
    gui.Parent = uiParent()
    table.insert(Cleanups, function()
        folder:Destroy()
        gui:Destroy()
    end)
    local function part(shape, color, transp)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.Material = Enum.Material.Neon
        p.Shape = shape
        p.Color = color
        p.Transparency = transp
        p.Size = Vector3.new(0.2, 4, 4)
        p.Parent = nil
        return p
    end
    local disc = part(Enum.PartType.Cylinder, Color3.fromRGB(255, 80, 80), 0.35)
    local ring = part(Enum.PartType.Cylinder, Color3.fromRGB(255, 80, 80), 0.85)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(200, 34)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
    bb.Adornee = disc
    bb.Parent = gui
    local bbText = Instance.new("TextLabel")
    bbText.BackgroundTransparency = 1
    bbText.Size = UDim2.fromScale(1, 1)
    bbText.Font = Enum.Font.GothamBold
    bbText.TextSize = 14
    bbText.TextStrokeTransparency = 0.3
    bbText.TextColor3 = Color3.new(1, 1, 1)
    bbText.Parent = bb
    local dots = {}
    for i = 1, 28 do
        local d = part(Enum.PartType.Ball, Color3.fromRGB(255, 255, 255), 0.25)
        d.Size = Vector3.new(0.45, 0.45, 0.45)
        dots[i] = d
    end
    local function hideFlight()
        disc.Parent, ring.Parent = nil, nil
        bb.Enabled = false
        for _, d in dots do
            d.Parent = nil
        end
    end

    -- HUD line at the top of the screen
    local hudGui = Instance.new("ScreenGui")
    hudGui.Name = "\0"
    hudGui.ResetOnSpawn = false
    hudGui.IgnoreGuiInset = true
    hudGui.Parent = uiParent()
    local hud = Instance.new("TextLabel")
    hud.AnchorPoint = Vector2.new(0.5, 0)
    hud.Position = UDim2.new(0.5, 0, 0, 64)
    hud.Size = UDim2.fromOffset(460, 26)
    hud.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    hud.BackgroundTransparency = 0.35
    hud.Font = Enum.Font.GothamBold
    hud.TextSize = 15
    hud.TextColor3 = Color3.new(1, 1, 1)
    hud.Visible = false
    hud.Parent = hudGui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = hud
    table.insert(Cleanups, function()
        hudGui:Destroy()
    end)

    local RED, GREEN, YELLOW, BLUE, GRAY = Color3.fromRGB(255, 70, 70), Color3.fromRGB(80, 230, 110), Color3.fromRGB(255, 210, 60),
        Color3.fromRGB(80, 160, 255), Color3.fromRGB(170, 170, 170)
    local function landingText(c)
        local z = c.pred.landZone
        if not z then
            return "out", YELLOW
        end
        if z == c.myZone then
            return "YOU", RED
        end
        local occ = c.occ[z]
        if occ and occ[1] then
            local names = {}
            local ally = false
            for _, o in occ do
                table.insert(names, o.name)
                ally = ally or o.side == "ally"
            end
            return table.concat(names, ", "), ally and BLUE or GREEN
        end
        return "zone " .. tostring(zoneIndex(c.zones, z)), GRAY
    end
    Esp.landingText = landingText

    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        local c = Play.ctx
        local st = c and c.st
        local pred = c and c.pred
        local flying = st and pred and pred.path and pred.landing and not st.Dead and st.Server == nil
        -- landing spot + blast
        if flying and (Settings.EspLanding or Settings.EspBlast) then
            local who, color = landingText(c)
            local L = pred.landing
            local cf = CFrame.new(L + Vector3.new(0, 0.08 - Ball.Radius + 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
            if Settings.EspLanding then
                disc.Size = Vector3.new(0.15, 5, 5)
                disc.CFrame = cf
                disc.Color = color
                disc.Parent = folder
                bb.Enabled = true
                bbText.TextColor3 = color
                bbText.Text = ("%s · %.1fs"):format(who, math.max((pred.landTime or 0) - Workspace:GetServerTimeNow(), 0))
            else
                disc.Parent = nil
                bb.Enabled = false
            end
            if Settings.EspBlast then
                ring.Size = Vector3.new(0.1, BLAST * 2, BLAST * 2)
                ring.CFrame = cf
                ring.Color = color
                ring.Parent = folder
            else
                ring.Parent = nil
            end
        else
            disc.Parent, ring.Parent = nil, nil
            bb.Enabled = false
        end
        -- flight path
        if flying and Settings.EspPath then
            local now = Workspace:GetServerTimeNow()
            local t1 = pred.landTime
            local span = math.max(t1 - now, 0)
            for i, d in dots do
                if span <= 0.02 then
                    d.Parent = nil
                else
                    d.Position = posAt(pred, now + span * (i / #dots))
                    d.Parent = folder
                end
            end
        else
            for _, d in dots do
                d.Parent = nil
            end
        end
        -- HUD
        if Settings.Hud and c and st then
            local parts = {}
            if st.Dead then
                table.insert(parts, "Point over")
            elseif st.Server then
                table.insert(parts, st.Server == LocalPlayer and "Your serve" or ("Serve: " .. nameOf(st.Server)))
            elseif flying then
                local who = landingText(c)
                table.insert(parts, ("→ %s in %.1fs"):format(who, math.max(c.eta or 0, 0)))
            elseif st.Magnet then
                table.insert(parts, "Magnet")
            elseif st.Frozen then
                table.insert(parts, "Frozen")
            end
            if c.myZone then
                local used = (st.HitZone == c.myZone) and (st.Hits or 0) or 0
                table.insert(parts, ("your touches %d/%d"):format(used, Ball.GetMaxHits()))
            end
            hud.Text = table.concat(parts, "  ·  ")
            hud.TextColor3 = c.incoming and RED or Color3.new(1, 1, 1)
            hud.Visible = true
        else
            hud.Visible = false
        end
        if not c then
            hideFlight()
        end
    end)

    -- zones and players
    local zoneMarks, playerMarks = {}, {}
    local function zoneMark(z)
        local m = zoneMarks[z]
        if m then
            return m
        end
        local box = Instance.new("SelectionBox")
        box.Adornee = z
        box.LineThickness = 0.12
        box.SurfaceTransparency = 1
        box.Parent = gui
        local b = Instance.new("BillboardGui")
        b.AlwaysOnTop = true
        b.Size = UDim2.fromOffset(220, 30)
        b.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
        b.Adornee = z
        b.Parent = gui
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1
        l.Size = UDim2.fromScale(1, 1)
        l.Font = Enum.Font.GothamBold
        l.TextSize = 13
        l.TextStrokeTransparency = 0.35
        l.Parent = b
        m = { box = box, bb = b, label = l }
        zoneMarks[z] = m
        return m
    end
    local function playerMark(key, char)
        local m = playerMarks[key]
        if m and m.char == char and char.Parent then
            return m
        end
        if m then
            m.hl:Destroy()
            m.bb:Destroy()
        end
        local hl = Instance.new("Highlight")
        hl.Adornee = char
        hl.FillTransparency = 0.75
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = gui
        local b = Instance.new("BillboardGui")
        b.AlwaysOnTop = true
        b.Size = UDim2.fromOffset(200, 26)
        b.StudsOffset = Vector3.new(0, 3.2, 0)
        b.Adornee = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
        b.Parent = gui
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1
        l.Size = UDim2.fromScale(1, 1)
        l.Font = Enum.Font.GothamBold
        l.TextSize = 13
        l.TextStrokeTransparency = 0.35
        l.Parent = b
        m = { hl = hl, bb = b, label = l, char = char }
        playerMarks[key] = m
        return m
    end
    loop(0.2, function()
        local c = Play.ctx
        local seenZ, seenP = {}, {}
        if c and c.zones and Settings.EspZones then
            for i, z in c.zones do
                local m = zoneMark(z)
                seenZ[z] = true
                local occ = c.occ[z]
                local color, text = GRAY, ("zone %d · empty"):format(i)
                if z == c.myZone then
                    color, text = BLUE, ("zone %d · YOU"):format(i)
                elseif occ and occ[1] then
                    local names, ally = {}, false
                    for _, o in occ do
                        table.insert(names, o.name)
                        ally = ally or o.side == "ally"
                    end
                    color, text = ally and BLUE or RED, ("zone %d · %s"):format(i, table.concat(names, ", "))
                end
                if c.st.HitZone == z and (c.st.Hits or 0) > 0 then
                    text ..= (" · %d/%d touches"):format(c.st.Hits, Ball.GetMaxHits())
                end
                m.box.Color3 = color
                m.label.TextColor3 = color
                m.label.Text = text
            end
        end
        for z, m in zoneMarks do
            if not seenZ[z] then
                m.box:Destroy()
                m.bb:Destroy()
                zoneMarks[z] = nil
            end
        end
        if c and Settings.EspPlayers then
            local lastHitter = c.st.HitBy or c.st.Hitter
            for _, o in c.people do
                if o.side ~= "me" and o.char then
                    local m = playerMark(o.who, o.char)
                    seenP[o.who] = true
                    local color = o.side == "ally" and GREEN or RED
                    m.hl.FillColor, m.hl.OutlineColor = color, color
                    m.label.TextColor3 = color
                    local text = o.name
                    if lastHitter == o.who then
                        text ..= " (hit last)"
                    end
                    if o.bot then
                        text ..= " [bot]"
                    end
                    m.label.Text = text
                end
            end
        end
        for k, m in playerMarks do
            if not seenP[k] or not m.char.Parent then
                m.hl:Destroy()
                m.bb:Destroy()
                playerMarks[k] = nil
            end
        end
    end)
end

--// Rewards \\--
local Rewards = { claimed = 0, spins = 0, info = "-" }
local function rewardLog(text)
    Rewards.claimed += 1
    Rewards.info = text
end
local Spin = { busy = false }
local function spinOnce()
    if Spin.busy then
        return
    end
    local n = (tonumber(pget("Spins")) or 0) + (tonumber(pget("LuckySpins")) or 0)
    if n <= 0 then
        return
    end
    Spin.busy = true
    task.spawn(function()
        local idx = invoke("RequestSpin")
        if type(idx) == "number" then
            -- the wheel spins for 6 s before the game asks for the prize
            task.wait(6.5)
            invoke("RequestRewardFromSpin")
            Rewards.spins += 1
            local prize = SpinnerInfo.Rewards and SpinnerInfo.Rewards[idx]
            rewardLog("Spin: " .. tostring(prize and prize.Description or ("prize " .. idx)))
        end
        task.wait(1.5)
        Spin.busy = false
    end)
end
loop(4, function()
    if not pdata() then
        return
    end
    local now = Workspace:GetServerTimeNow()
    if Settings.AutoDaily then
        local first = tonumber(pget("FirstJoinTime"))
        local claimed = pget("ClaimedDailyRewards") or {}
        if first then
            for day = 1, #DailyInfo do
                if not table.find(claimed, day) and first + (day - 1) * 86400 <= now and tryOnce("day" .. day, 30) then
                    fire("ClaimDayReward", day)
                    rewardLog("Daily reward, day " .. day)
                end
            end
        end
    end
    if Settings.AutoQuests then
        local quests = pget("DailyQuests") or {}
        local done = pget("ClaimedQuests") or {}
        for id, progress in quests do
            local info = QuestInfo[id]
            if info and not done[id] and (tonumber(progress) or 0) >= (info.Goal or math.huge) and tryOnce("quest" .. tostring(id), 20) then
                fire("ClaimQuest", id)
                rewardLog("Quest: " .. tostring(info.Description or id))
            end
        end
    end
    if Settings.AutoAchievements then
        local done = pget("ClaimedAchievements") or {}
        for _, cat in AchievementInfo do
            for _, a in (type(cat) == "table" and cat.Achievements) or {} do
                if a.Id and not done[a.Id] and (tonumber(pget(a.Stat)) or 0) >= (a.Goal or math.huge) and tryOnce("ach" .. a.Id, 30) then
                    fire("ClaimAchievement", a.Id)
                    rewardLog("Achievement: " .. tostring(a.DisplayName or a.Id))
                end
            end
        end
    end
    if Settings.AutoLike and not pget("ClaimedLikeReward") and tryOnce("like", 120) then
        fire("ClaimLikeReward")
    end
    if Settings.AutoSpin then
        spinOnce()
    end
end)

--// Shop \\--
local Shop = { info = "-" }
loop(2, function()
    if not pdata() then
        return
    end
    if Settings.AutoBuy then
        local money = tonumber(pget("Money")) or 0
        for _, a in ABILITIES do
            if Settings.BuyList[a.name] and a.price > 0 and not owned(a.name) and money >= a.price and tryOnce("buy" .. a.name, 8) then
                fire("BuyAbility", a.name)
                Shop.info = ("Bought %s for %s"):format(a.display, comma(a.price))
                break
            end
        end
    end
    if Settings.EquipNewest then
        local best
        for _, a in ABILITIES do
            if owned(a.name) then
                best = a
            end
        end
        if best and pget("EquippedAbility") ~= best.name and tryOnce("equipBest", 5) then
            fire("EquipAbility", best.name)
            Shop.info = "Equipped " .. best.display
        end
    end
end)
local function equip(name)
    if not name or name == "" then
        return
    end
    if not owned(name) then
        notify("You don't own " .. name .. " yet")
        return
    end
    fire("EquipAbility", name)
    notify("Equipped " .. name)
end

--// Rounds \\--
local asked = {}
loop(0.5, function()
    local voting = Workspace:GetAttribute("Voting")
    if Settings.VoteMode ~= "Off" and voting and tryOnce("vote" .. tostring(voting) .. Settings.VoteMode, 1e9) then
        fire("VoteTeammode", Settings.VoteMode)
    end
    if Settings.StayActive and LocalPlayer:GetAttribute("AFK") and tryOnce("afk", 5) then
        fire("ToggleAFK")
    end
    local starting = Workspace:GetAttribute("GameStarting")
    local mode = Teammodes[Workspace:GetAttribute("Teammode") or ""]
    if Settings.AutoTeamUp and starting and mode and (mode.TeamSize or 1) > 1 and not LocalPlayer:GetAttribute("InRound") then
        local c = LocalPlayer.Character
        local me = c and c:FindFirstChild("HumanoidRootPart")
        local myTeam = LocalPlayer:GetAttribute("Team")
        for _, plr in Players:GetPlayers() do
            local pc = plr ~= LocalPlayer and plr.Character
            local r = pc and pc:FindFirstChild("HumanoidRootPart")
            local key = tostring(starting) .. plr.UserId
            if me and r and not plr:GetAttribute("InRound") and (not myTeam or plr:GetAttribute("Team") ~= myTeam)
                and (r.Position - me.Position).Magnitude < 14 and not asked[key] then
                asked[key] = true
                fire("TeamUp", plr)
            end
        end
    end
end)
local function goPractice()
    local c = LocalPlayer.Character
    local root = c and c:FindFirstChild("HumanoidRootPart")
    local pad = find(Workspace, { "GameObjects", "EnterPractice" })
    if not (root and pad) then
        notify("Couldn't find the practice pad")
        return
    end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, pad, 0)
        task.wait(0.1)
        pcall(firetouchinterest, root, pad, 1)
    end
    task.wait(0.4)
    if LocalPlayer:GetAttribute("InRound") ~= "Practice" then
        root.CFrame = pad.CFrame + Vector3.new(0, 3, 0)
    end
end

--// Player \\--
do
    local orig = {}
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local c = LocalPlayer.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum then
            return
        end
        if Settings.SpeedOn then
            orig.ws = orig.ws or hum.WalkSpeed
            local adrenaline = AC and AC._active and AC._active.Adrenaline
            local want = Settings.WalkSpeed * (adrenaline and ((AbilityMods.Adrenaline and AbilityMods.Adrenaline.WalkBoost) or 1) or 1)
            if math.abs(hum.WalkSpeed - want) > 0.05 then
                hum.WalkSpeed = want
            end
        elseif orig.ws then
            hum.WalkSpeed = orig.ws
            orig.ws = nil
        end
        if Settings.JumpOn then
            if hum.UseJumpPower then
                orig.jp = orig.jp or hum.JumpPower
                hum.JumpPower = Settings.JumpPower
            else
                orig.jh = orig.jh or hum.JumpHeight
                hum.JumpHeight = Settings.JumpPower * Settings.JumpPower / (2 * Workspace.Gravity)
            end
        else
            if orig.jp then
                hum.JumpPower = orig.jp
                orig.jp = nil
            end
            if orig.jh then
                hum.JumpHeight = orig.jh
                orig.jh = nil
            end
        end
    end)
    bind(LocalPlayer.CharacterAdded, function()
        orig = {}
    end)
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, c in getconnections(LocalPlayer.Idled) do
                if not idled[c] and pcall(c.Disable, c) then
                    idled[c] = true
                end
            end
        elseif next(idled) then
            for c in idled do
                pcall(c.Enable, c)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
        end
        local ch = LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then
            if orig.ws then
                hum.WalkSpeed = orig.ws
            end
            if orig.jp then
                hum.JumpPower = orig.jp
            end
            if orig.jh then
                hum.JumpHeight = orig.jh
            end
        end
    end)
end

--// Dashboard \\--
local function dashboard()
    local c = Play.ctx
    local lines = {}
    table.insert(lines, ("Mode: %s · %s · %s touches"):format(tostring(Workspace:GetAttribute("Gamemode") or "?"),
        tostring(Workspace:GetAttribute("Teammode") or "?"), tostring(Ball and Ball.GetMaxHits() or "?")))
    local arena = LocalPlayer:GetAttribute("InRound")
    if c then
        local zi = zoneIndex(c.zones, c.myZone)
        table.insert(lines, arena and ("In round (%s)%s"):format(tostring(arena), zi and (" · zone " .. zi) or " · no zone")
            or "In the lobby")
        local st = c.st
        if st.Dead then
            table.insert(lines, "Ball: point over")
        elseif st.Server then
            table.insert(lines, "Ball: serve by " .. nameOf(st.Server))
        elseif c.pred.landing then
            table.insert(lines, ("Ball: going to %s in %.1fs"):format((Esp.landingText and Esp.landingText(c)) or "?", math.max(c.eta or 0, 0)))
        end
    else
        table.insert(lines, arena and ("In round (%s)"):format(tostring(arena)) or "In the lobby")
    end
    table.insert(lines, "Now: " .. Play.info)
    table.insert(lines, ("Hits %d · perfect %d · bumps %d · dives %d · serves %d · abilities %d"):format(Play.hits, Play.perfects, Play.bumps,
        Play.dives, Play.serves, Play.abilities))
    table.insert(lines, "Last: " .. Play.lastAction)
    local ab = pget("EquippedAbility")
    local abText = "none"
    if ab then
        local left = AC and AC.Remaining and select(2, pcall(AC.Remaining, AC, ab))
        abText = ab .. ((type(left) == "number" and left > 0) and (" (%.1fs)"):format(left) or " (ready)")
    end
    table.insert(lines, ("Money %s · ability %s"):format(comma(pget("Money")), abText))
    if Play.err then
        table.insert(lines, "Error: " .. Play.err)
    end
    return table.concat(lines, "\n")
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Volley Bomb",
    Footer = "dookie hub · Ui3",
    Icon = "volleyball",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/VolleyBomb",
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
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.4)
        end
    end)
end
local function goButton(box, text, fn)
    box:AddButton({ Text = text, Func = function()
        task.spawn(fn)
    end })
end

do
    local Tab = Window:AddTab("Play", "volleyball", "Auto hit, spikes, serves")
    local A = Tab:AddLeftGroupbox("Auto play", "play")
    toggle(A, "AutoHit", "Auto hit", "Hits the ball the moment it's in reach in your zone, with the game's own hit")
    toggle(A, "AutoMove", "Move to the ball", "Walks you to where you can hit the ball when it's coming to your zone")
    toggle(A, "AutoSpike", "Perfect spikes", "Jumps at the right time so the ball is at the top of your jump: a Perfect spike")
    toggle(A, "WaitPerfect", "Wait for perfect", "In the air, only spikes once it's Perfect (unless it's the last chance)")
    toggle(A, "AutoServe", "Auto serve")
    slider(A, "ServeDelay", "Serve delay", 0, 3, 1, " s")
    toggle(A, "AutoDive", "Auto dive", "Dives when the ball is too far to walk to in time")
    toggle(A, "BlastDodge", "Blast dodge", "When the ball can't be saved, runs to the corner of your zone farthest from it")
    toggle(A, "BackToMiddle", "Wait in the middle", "Goes back to the middle of your zone between balls")
    toggle(A, "LeaveToTeammate", "Let a closer teammate take it")
    local S = Tab:AddRightGroupbox("Status", "activity")
    status(S, dashboard)
    local M = Tab:AddRightGroupbox("Aim", "crosshair")
    dropdown(M, "AimMode", "Aim", { "Hardest to save", "Off" },
        "Hardest to save: turns you right before the hit so the ball lands where the enemy can't get to it in time")
    local focus = M:AddDropdown("AimFocus", {
        Text = "Go after", Values = { "Anyone" }, Default = "Anyone", Searchable = true,
        Callback = function(v)
            Settings.AimFocus = v or "Anyone"
        end,
    })
    loop(3, function()
        local names = { "Anyone" }
        for _, plr in Players:GetPlayers() do
            if plr ~= LocalPlayer then
                table.insert(names, plr.DisplayName)
            end
        end
        local key = table.concat(names, "|")
        if key ~= Settings.__focusKey then
            Settings.__focusKey = key
            pcall(focus.SetValues, focus, names)
        end
    end)
    local R = Tab:AddRightGroupbox("Reach (risky)", "alert-triangle")
    slider(R, "ReachExtra", "Extra reach", 0, 12, 1, " studs",
        "Sends your hit from a bit closer to the ball. The server allows some lag, but too much can get flagged")
end

do
    local Tab = Window:AddTab("Abilities", "zap", "Auto use, buy, equip")
    local U = Tab:AddLeftGroupbox("Use", "zap")
    toggle(U, "AutoAbility", "Auto use ability",
        "Frozen / Magnet when the ball comes to you, Forcefield against a ball coming in, Superspike, Curveball, Moonball, Portal and Tornado Ball right before your hit, Adrenaline for long runs")
    status(U, function()
        local ab = pget("EquippedAbility")
        if not ab then
            return "No ability equipped"
        end
        local mod = AbilityMods[ab]
        if mod and mod.Type == "Passive" then
            return ab .. " is passive: it works by itself"
        end
        local ok, left = pcall(AC.Remaining, AC, ab)
        return ("%s · %s"):format(ab, (ok and left and left > 0) and ("%.1fs"):format(left) or "ready")
    end)
    local B = Tab:AddRightGroupbox("Shop", "shopping-cart")
    toggle(B, "AutoBuy", "Auto buy abilities", "Cheapest first, whenever you have the coins")
    local defaults = {}
    for _, n in ABILITY_NAMES do
        table.insert(defaults, n)
    end
    B:AddDropdown("BuyList", {
        Text = "Buy these", Values = ABILITY_NAMES, Default = defaults, Multi = true,
        Callback = function(v)
            Settings.BuyList = v
        end,
    })
    toggle(B, "EquipNewest", "Equip the best one you own", "The most expensive ability you own")
    local pick = ABILITY_NAMES[1]
    B:AddDropdown("EquipPick", {
        Text = "Ability", Values = ABILITY_NAMES, Default = pick,
        Callback = function(v)
            pick = v
        end,
    })
    goButton(B, "Equip it", function()
        equip(pick)
    end)
    status(B, function()
        local have = {}
        for _, a in ABILITIES do
            if owned(a.name) then
                table.insert(have, a.display)
            end
        end
        local nextOne
        for _, a in ABILITIES do
            if not owned(a.name) then
                nextOne = a
                break
            end
        end
        return ("Coins %s\nOwned: %s\nNext: %s\n%s"):format(comma(pget("Money")), #have > 0 and table.concat(have, ", ") or "none",
            nextOne and (nextOne.display .. " (" .. comma(nextOne.price) .. ")") or "all owned", Shop.info)
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Landing spot, zones, players")
    local E = Tab:AddLeftGroupbox("Ball", "circle")
    toggle(E, "EspLanding", "Landing spot", "Where the ball comes down, whose zone and how long until then")
    toggle(E, "EspBlast", "Blast radius", "The 15 stud blast around the landing spot")
    toggle(E, "EspPath", "Flight path", "Wall bounces and bounces off empty zones included")
    toggle(E, "Hud", "Ball info on screen", "Where it's going and how many touches your zone has used")
    local P = Tab:AddRightGroupbox("Field", "grid")
    toggle(P, "EspZones", "Zones", "Blue is you or your team, red an enemy, gray empty")
    toggle(P, "EspPlayers", "Players", "Red enemies, green teammates, and who hit it last")
end

do
    local Tab = Window:AddTab("Rewards", "gift", "Daily, quests, spins, rounds")
    local R = Tab:AddLeftGroupbox("Claim", "gift")
    toggle(R, "AutoDaily", "Daily rewards")
    toggle(R, "AutoQuests", "Quests")
    toggle(R, "AutoAchievements", "Achievements")
    toggle(R, "AutoSpin", "Spin the wheel", "Uses every free spin you have")
    toggle(R, "AutoLike", "Like reward", "Only pays out if you're in the game's group")
    status(R, function()
        return ("Claimed %d · spins %d\n%s"):format(Rewards.claimed, Rewards.spins, Rewards.info)
    end)
    local G = Tab:AddRightGroupbox("Rounds", "users")
    dropdown(G, "VoteMode", "Vote team mode", { "Off", "Solo", "Duos", "Trios" })
    toggle(G, "AutoTeamUp", "Team up with people near you", "In Duos and Trios, asks whoever stands next to you before the round")
    toggle(G, "StayActive", "Stay out of AFK", "Turns the game's AFK mode off so you keep getting put in rounds")
    goButton(G, "Go to practice", goPractice)
    goButton(G, "Leave practice", function()
        fire("ExitPractice")
    end)
    if game.PlaceId == 125848858933944 then
        goButton(G, "Leave the new players server", function()
            fire("LeaveNoobServer")
        end)
    end
end

do
    local Tab = Window:AddTab("Player", "user", "Movement, AFK")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Speed", "Adrenaline still adds its boost on top")
    slider(M, "WalkSpeed", "Speed", 16, 40, 0, "", "Higher is easier to spot")
    toggle(M, "JumpOn", "Jump power", "A higher jump reaches higher balls. Perfect spikes work it out from your real jump")
    slider(M, "JumpPower", "Jump power", 50, 80, 0)
    local O = Tab:AddRightGroupbox("Other", "settings")
    toggle(O, "AntiAfk", "Anti-AFK")
    O:AddButton({ Text = "Unload", Func = function()
        if Genv.__VolleyUnload then
            Genv.__VolleyUnload()
        end
    end })
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
Genv.__VolleyUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

local missing = {}
if not Ball then
    table.insert(missing, "ball module")
end
if not BC then
    table.insert(missing, "ball controller")
end
if not AC then
    table.insert(missing, "ability controller")
end
if not Replion then
    table.insert(missing, "player data")
end
notify("Loaded" .. (#missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or ""), 4)

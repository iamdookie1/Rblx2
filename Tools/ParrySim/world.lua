-- Simulated Blade Ball server + network + client around the real script core.
local M = require("mock")
local v3 = M.v3
local World = {}
World.__index = World

local SERVER_DT = 1 / 60
local BASE_SERVER_TIME = 1794007603

---------------------------------------------------------------- rng
local function mkrng(seed)
    local s = (seed * 2654435761) % 4294967296
    if s == 0 then s = 1 end
    return function()
        s = (1103515245 * s + 12345) % 2147483648
        return s / 2147483648
    end
end
World.mkrng = mkrng

function World:rand(a, b) return a + (b - a) * self.rng() end
function World:pick(list) return list[math.floor(self.rng() * #list) + 1] end
function World:gauss()
    local u1, u2 = math.max(self.rng(), 1e-9), self.rng()
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

---------------------------------------------------------------- setup
function World.new(cfg)
    local self = setmetatable({}, World)
    self.cfg = cfg
    self.rng = mkrng(cfg.seed or 1)
    self.script_rng = mkrng((cfg.seed or 1) * 7 + 3)
    self.inbox = {}
    self.reliable_last = 0
    self.out = {}
    self.sv_req = {}
    self.events = {}
    self.result = nil
    self.stats = { requests = 0, taken = 0, ignored = 0, passes = 0, success = 0, deaths = 0, uses = {}, reasons = {},
        my_hits = 0, bot_kills = 0, wasted = 0, flights = {} }
    M.reset_scheduler()
    M.now = 0
    return self
end

function World:lat(dir)
    local c = self.cfg
    local base = c.rtt * 0.5
    local j = math.abs(self:gauss()) * (c.jitter or 0)
    local sp = 0
    for _, s in ipairs(self.spikes or {}) do
        if M.now >= s.t0 and M.now <= s.t1 then sp = sp + s.add end
    end
    return base + j + sp
end

function World:send_down(fn, reliable)
    local t = M.now + self:lat("down")
    if reliable then
        t = math.max(t, self.reliable_last)
        self.reliable_last = t
    end
    self.inbox[#self.inbox + 1] = { t = t, fn = fn, s = #self.inbox }
end

function World:deliver()
    local due, keep = {}, {}
    for _, m in ipairs(self.inbox) do
        if m.t <= M.now then due[#due + 1] = m else keep[#keep + 1] = m end
    end
    self.inbox = keep
    table.sort(due, function(a, b) if a.t == b.t then return a.s < b.s end; return a.t < b.t end)
    if self.cfg.deferred then
        M.defer_signals = true
        for _, m in ipairs(due) do m.fn() end
        M.defer_signals = false
        M.run_deferred()
    else
        for _, m in ipairs(due) do m.fn(); M.run_deferred() end
    end
end

---------------------------------------------------------------- server model
function World:sv_player(name) return self.sv.players[name] end

function World:me_pos(t)
    local mv = self.cfg.move
    local p = self.me_base
    if not mv then return p end
    local seg = math.floor(t / mv.period)
    local phase = t - seg * mv.period
    local dirs = self.move_dirs
    local off = v3(0, 0, 0)
    for i = 0, seg - 1 do off = off + dirs[(i % #dirs) + 1] * (mv.speed * mv.period) end
    off = off + dirs[(seg % #dirs) + 1] * (mv.speed * phase)
    return p + off
end
function World:me_vel(t)
    local mv = self.cfg.move
    if not mv then return v3(0, 0, 0) end
    local seg = math.floor(t / mv.period)
    return self.move_dirs[(seg % #self.move_dirs) + 1] * mv.speed
end

function World:server_pos(P, t)
    if P.is_me then return self:me_pos(t - self.cfg.rtt * 0.5) end
    return P.pos
end

function World:steer(B, dir, want, dt, t)
    local law = B.law
    if law == "turn" then
        local ang = math.acos(math.max(-1, math.min(1, dir:Dot(want))))
        if ang < 1e-6 then return want end
        local w = B.w
        if B.sscale then w = w * math.max(B.speed / 150, 0.5) ^ B.sscale end
        local step = math.min(w * dt / ang, 1)
        local m = dir + (want - dir) * step
        if m.Magnitude < 1e-6 then m = dir:Cross(M.Vector3.yAxis) + want * 0.01 end
        return m.Unit
    end
    local k = B.k
    if law == "ramp" then k = B.k0 + B.k1 * (t - B.pass_t0) end
    if B.sscale then k = k * math.max(B.speed / 150, 0.5) ^ B.sscale end
    local a = math.min(k * dt, 1)
    local m = dir + (want - dir) * a
    if m.Magnitude < 1e-6 then m = dir:Cross(M.Vector3.yAxis) + want * 0.01 end
    return m.Unit
end

function World:deflect_range(speed)
    local c = self.cfg
    local extra = c.deflect_extra or 0
    if c.deflect_speed then extra = extra + math.min(speed * c.deflect_speed, 20) end
    return c.kill_dist + extra
end

local function seg_entry(p0, p1, q, r)
    local d = p1 - p0
    local f = p0 - q
    local a = d:Dot(d)
    local b = 2 * f:Dot(d)
    local cc = f:Dot(f) - r * r
    if cc <= 0 then return 0 end
    if a < 1e-12 then return nil end
    local disc = b * b - 4 * a * cc
    if disc < 0 then return nil end
    local s = (-b - math.sqrt(disc)) / (2 * a)
    if s >= 0 and s <= 1 then return s end
    return nil
end

function World:new_pass(B, from, target, aim, speed, t)
    B.target = target
    B.dir = aim
    B.speed = speed
    B.pass_t0 = t
    B.from = from
    local h = self.cfg.homing
    B.law = h.law
    B.k = self:rand(h.k[1], h.k[2])
    if h.law == "turn" then B.w = self:rand(h.w[1], h.w[2]) end
    if h.law == "ramp" then B.k0 = self:rand(h.k0[1], h.k0[2]); B.k1 = self:rand(h.k1[1], h.k1[2]) end
    B.sscale = h.speed_scale
    B.bot_req = nil
    B.pass_id = (B.pass_id or 0) + 1
    self:wlog("pass %d -> %s speed %.0f curve %s", B.pass_id, target, speed, tostring(B.curve))
    if target == self.me_name then
        self.stats.passes = self.stats.passes + 1
        self.pass = { t0 = t, from = from, speed = speed, reqs = {}, curve = B.curve, id = B.pass_id }
    end
    local inst = self.ball_inst
    self:send_down(function() inst:SetAttribute("target", target) end, true)
end

function World:aim_dir(from_pos, to_pos, curve)
    local to = to_pos - from_pos
    local m = to.Magnitude
    local toT = m > 1e-6 and to / m or v3(1, 0, 0)
    local up = M.Vector3.yAxis
    local right = toT:Cross(up)
    right = right.Magnitude > 1e-6 and right.Unit or v3(1, 0, 0)
    local side = self.rng() < 0.5 and -1 or 1
    local d
    if curve == "straight" then d = toT
    elseif curve == "high" then d = toT + up * 3
    elseif curve == "backwards" then d = -toT + up * 0.1
    elseif curve == "side" then d = toT * 0.2 + right * side
    elseif curve == "diagonal" then d = toT + right * side + up
    elseif curve == "sky" then d = up + toT * 0.05
    elseif curve == "random" then d = v3(self:rand(-1, 1), self:rand(-0.5, 1), self:rand(-1, 1))
    elseif curve == "flick" then d = toT + right * 2 * side
    elseif curve == "slight" then d = toT + right * 0.35 * side + up * 0.2
    else d = toT end
    if d.Magnitude < 1e-6 then d = toT end
    return d.Unit
end

function World:server_deflect(P, B, t)
    local stats = self.stats
    local tp = self:server_pos(P, t)
    self:wlog("deflect by %s at %.3f dist %.1f speed %.0f", P.name, t, (B.pos - tp).Magnitude, B.speed)
    P.win_until, P.cool_until = -1, -1
    if P.is_me then
        stats.success = stats.success + 1
        stats.my_hits = stats.my_hits + 1
        if self.pass then
            stats.uses[#stats.uses + 1] = t - (P.win_start or t)
            self.pass.result = "success"
            stats.flights[#stats.flights + 1] = t - self.pass.t0
        end
        self.pass = nil
        local remotes = self.remotes
        self:send_down(function() self.cl.win_until, self.cl.cool_until = -1, -1; remotes.ParrySuccess.OnClientEvent:Fire() end, true)
        if self.on_my_success then self:on_my_success(t) end
    end
    local pl = self.player_inst[P.name]
    local remotes = self.remotes
    self:send_down(function() remotes.ParrySuccessAll.OnClientEvent:Fire("Base Sword", nil, nil, pl) end, true)
    if self.done then return end
    local target = self.scenario.choose_target(self, P)
    if not target then return end
    local T = self.sv.players[target]
    local curve = self.scenario.choose_curve(self, P)
    B.curve = curve
    local aim = self:aim_dir(B.pos, self:server_pos(T, t), curve)
    local speed = self.scenario.next_speed(self, B.speed, P)
    self:new_pass(B, P.name, target, aim, speed, t)
end

function World:server_kill(P, B, t)
    local stats = self.stats
    self:wlog("KILL %s at %.3f speed %.0f (win %.3f-%.3f)", P.name, t, B.speed, P.win_start or -1, P.win_until)
    if P.is_me then
        stats.deaths = stats.deaths + 1
        local pass = self.pass
        local reason = "nofire"
        if pass then
            local last
            for _, r in ipairs(pass.reqs) do last = r end
            if last then
                if not last.taken then reason = "ignored"
                elseif last.arrive > t then reason = "late"
                elseif last.win_until < t then reason = "early"
                else reason = "window_but_dead" end
            end
            for _, r in ipairs(self.sv_req) do if r.P == P and r.arrive > t and r.arrive < t + 1 then reason = "late" end end
            pass.result = "dead"
            pass.reason = reason
            stats.flights[#stats.flights + 1] = t - pass.t0
        end
        stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
        self.last_death = { t = t, reason = reason, speed = B.speed, curve = B.curve }
        self.pass = nil
        if self.on_my_death then self:on_my_death(t, reason) end
    else
        stats.bot_kills = stats.bot_kills + 1
        if self.on_bot_death then self:on_bot_death(P, t) end
    end
end

function World:bot_plan(P, B, t)
    if B.bot_req and B.bot_req.pass == B.pass_id then return end
    local pos, dir, speed = B.pos, B.dir, B.speed
    local tp = P.pos
    local tt = 0
    local R = self:deflect_range(speed)
    local tc
    local tmp = { law = B.law, k = B.k, w = B.w, k0 = B.k0, k1 = B.k1, pass_t0 = B.pass_t0, sscale = B.sscale, speed = B.speed }
    while tt < 4 do
        local want = (tp - pos)
        local dist = want.Magnitude
        if dist <= R then tc = tt; break end
        dir = self:steer(tmp, dir, want / dist, SERVER_DT, t + tt)
        pos = pos + dir * speed * SERVER_DT
        tt = tt + SERVER_DT
    end
    if not tc then return end
    local lead = P.lead or self:rand(0.08, 0.3)
    local up = P.up or 0.04
    local send_at = math.max(t, t + tc - lead - up)
    B.bot_req = { pass = B.pass_id, at = send_at }
    self.sv_req[#self.sv_req + 1] = { P = P, arrive = send_at + up, bot = true }
end

function World:wlog(fmt, ...)
    if self.cfg.wlog then
        self.log = self.log or {}
        self.log[#self.log + 1] = ("t=%.3f SV " .. fmt .. "\n"):format(M.now, ...)
    end
end
function World:server_request(P, t)
    local stats = self.stats
    if P.is_me then stats.requests = stats.requests + 1 end
    local taken = not (t < P.cool_until or t < P.win_until)
    local rec
    if P.is_me and self.pass then
        rec = { arrive = t, taken = taken }
        self.pass.reqs[#self.pass.reqs + 1] = rec
    end
    if P.is_me then self:wlog("request from me %s (win_until %.3f cool_until %.3f)", taken and "TAKEN" or "IGNORED", P.win_until, P.cool_until) end
    if not taken then
        if P.is_me then stats.ignored = stats.ignored + 1 end
        return
    end
    P.win_start, P.win_until, P.cool_until = t, t + self.cfg.W, t + self.cfg.cooldown
    if rec then rec.win_until = P.win_until end
    if P.is_me then
        stats.taken = stats.taken + 1
        if not self.pass then stats.wasted = stats.wasted + 1 end
        local remotes, char = self.remotes, self.me_char
        self:send_down(function()
            remotes.ParryAttempt.OnClientEvent:Fire(char)
            remotes.ParryAttemptAll.OnClientEvent:Fire(nil, char)
        end, true)
    end
end

function World:server_tick(t)
    local B = self.sv.ball
    local keep = {}
    for _, r in ipairs(self.sv_req) do
        if r.arrive <= t then self:server_request(r.P, t) else keep[#keep + 1] = r end
    end
    self.sv_req = keep
    if not B or not B.target then return end
    local T = self.sv.players[B.target]
    if not T or not T.alive then return end
    if not T.is_me then self:bot_plan(T, B, t) end
    local tp = self:server_pos(T, t)
    local R = self:deflect_range(B.speed)
    local parrying = t >= (T.win_start or -1) and t <= T.win_until
    if parrying and (B.pos - tp).Magnitude <= R then
        self:server_deflect(T, B, t)
        self:replicate(t)
        return
    end
    local want = tp - B.pos
    local dist = want.Magnitude
    if dist > 1e-6 then B.dir = self:steer(B, B.dir, want / dist, SERVER_DT, t) end
    local p0 = B.pos
    local p1 = p0 + B.dir * B.speed * SERVER_DT
    local floor = self.cfg.floor or 1.5
    if p1.y < floor then p1 = v3(p1.x, floor, p1.z) end
    if parrying then
        local s = seg_entry(p0, p1, tp, R)
        if s then
            B.pos = p0 + (p1 - p0) * s
            self:server_deflect(T, B, t + SERVER_DT * s)
            self:replicate(t)
            return
        end
    end
    local sk = seg_entry(p0, p1, tp, self.cfg.kill_dist)
    if sk then
        B.pos = p0 + (p1 - p0) * sk
        local hit_t = t + SERVER_DT * sk
        if (T.win_until >= hit_t and (T.win_start or -1) <= hit_t) or (not T.is_me and self.cfg.perfect_bots) then
            self:server_deflect(T, B, hit_t)
        else
            self:server_kill(T, B, hit_t)
        end
        self:replicate(t)
        return
    end
    B.pos = p1
    B.speed = B.speed + (self.cfg.accel or 0) * SERVER_DT
    self:replicate(t)
end

function World:replicate(t)
    local B = self.sv.ball
    local pos, vel = B.pos, B.dir * B.speed
    local cl = self.cl
    local zoom, inst, feed = self.zoomies, self.ball_inst, self.feed_remote
    self:send_down(function()
        local snaps = cl.snaps
        snaps[#snaps + 1] = { t = t, pos = pos, vel = vel }
        table.sort(snaps, function(a, b) return a.t < b.t end)
        while #snaps > 90 do table.remove(snaps, 1) end
    end, false)
    if not self.last_vel or (self.last_vel - vel).Magnitude > 1e-6 then
        self.last_vel = vel
        self:send_down(function() zoom.VectorVelocity = vel end, true)
    end
    if feed then
        self:send_down(function() feed.OnClientEvent:Fire(inst, pos) end, false)
    end
end

---------------------------------------------------------------- client view
function World:render_state()
    local cl = self.cl
    local snaps = cl.snaps
    local n = #snaps
    if n == 0 then return self.sv.ball.pos, v3(0, 0, 0) end
    local rt = M.now - self.cfg.rtt * 0.5 - self.cfg.buffer
    if rt >= snaps[n].t then
        local s = snaps[n]
        local ex = math.min(rt - s.t, 0.05)
        return s.pos + s.vel * ex, s.vel
    end
    if rt <= snaps[1].t then return snaps[1].pos, snaps[1].vel end
    for i = n - 1, 1, -1 do
        local a, b = snaps[i], snaps[i + 1]
        if a.t <= rt then
            local f = (rt - a.t) / math.max(b.t - a.t, 1e-6)
            return a.pos:Lerp(b.pos, f), a.vel:Lerp(b.vel, f)
        end
    end
    return snaps[1].pos, snaps[1].vel
end

function World:game_block_press()
    local cl = self.cl
    if M.now < cl.win_until or M.now < cl.cool_until then return end
    cl.win_until, cl.cool_until = M.now + self.cfg.W, M.now + self.cfg.cooldown
    self.out[#self.out + 1] = { kind = "native" }
end

function World:flush_out()
    for _, o in ipairs(self.out) do
        self.sv_req[#self.sv_req + 1] = { P = self.sv.players[self.me_name], arrive = M.now + self:lat("up") }
    end
    self.out = {}
end

function World:build_game(env)
    local cfg = self.cfg
    local game = M.inst("DataModel", "Game")
    local d = rawget(game, "__d")
    local services = {}
    local function svc(name, class)
        local s = M.inst(class or name, name)
        s.Parent = game
        services[name] = s
        return s
    end
    d.props.GetService = function(_, name)
        local s = services[name]
        if not s then s = svc(name) end
        return s
    end
    d.props.JobId = "sim-job"
    d.props.PlaceId = 13772394625
    d.props.HttpGet = function() return "" end

    local ws = svc("Workspace")
    local players = svc("Players")
    local rs = svc("RunService")
    local uis = svc("UserInputService")
    local rep = svc("ReplicatedStorage")
    local stats = svc("Stats")
    local cs = svc("CollectionService")
    local gs = svc("GuiService")
    local vim = svc("VirtualInputManager")
    svc("HttpService"); svc("CoreGui"); svc("TweenService"); svc("Lighting"); svc("StarterGui")

    rawget(ws, "__d").props.GetServerTimeNow = function() return BASE_SERVER_TIME + M.now + (cfg.clock_err or 0) end
    rawget(ws, "__d").props.GetAttribute = nil
    local alive, dead = M.folder("Alive", ws), M.folder("Dead", ws)
    local balls, tballs = M.folder("Balls", ws), M.folder("TrainingBalls", ws)
    self.alive, self.balls = alive, balls

    local cam = M.inst("Camera", "Camera")
    local cd = rawget(cam, "__d")
    cd.props.ViewportSize = M.Vector2.new(800, 600)
    cd.props.CFrame = M.CFrame.lookAt(v3(0, 8, 12), v3(0, 3, -10))
    local F = 400 / math.tan(math.rad(35))
    cd.props.WorldToScreenPoint = function(c, pos)
        local cf = c.CFrame
        local rel = pos - cf.Position
        local z = rel:Dot(cf.LookVector)
        local x, y = rel:Dot(cf.RightVector), rel:Dot(cf.UpVector)
        local zz = math.max(z, 1e-3)
        return v3(400 + F * x / zz, 300 - F * y / zz, z), z > 0
    end
    local function ray(c, x, y)
        local cf = c.CFrame
        local dir = (cf.LookVector * F + cf.RightVector * (x - 400) - cf.UpVector * (y - 300)).Unit
        return { Origin = cf.Position, Direction = dir }
    end
    cd.props.ScreenPointToRay = function(c, x, y) return ray(c, x, y) end
    cd.props.ViewportPointToRay = function(c, x, y) return ray(c, x, y) end
    cam.Parent = ws
    cd.props.Name = nil
    rawget(ws, "__d").props.CurrentCamera = cam

    for _, n in ipairs({ "PreSimulation", "PostSimulation", "PreAnimation", "Heartbeat", "PreRender", "RenderStepped", "Stepped" }) do
        rawget(rs, "__d").props[n] = M.signal()
    end
    rawget(rs, "__d").props.IsStudio = function() return false end
    rawget(rs, "__d").props.BindToRenderStep = function() end
    rawget(rs, "__d").props.UnbindFromRenderStep = function() end
    self.rs = rs

    local ud = rawget(uis, "__d").props
    ud.InputBegan, ud.InputEnded, ud.InputChanged, ud.TouchTapInWorld = M.signal(), M.signal(), M.signal(), M.signal()
    ud.TouchEnabled, ud.MouseEnabled, ud.KeyboardEnabled = false, true, true
    ud.GetMouseLocation = function() return M.Vector2.new(400, 300) end
    ud.GetLastInputType = function() return M.Enum.UserInputType.Keyboard end

    rawget(cs, "__d").props.GetTagged = function(_, tag) return (self.tags and self.tags[tag]) or {} end
    rawget(cs, "__d").props.GetInstanceAddedSignal = function() return M.signal() end
    rawget(gs, "__d").props.ErrorMessageChanged = M.signal()
    rawget(gs, "__d").props.GetGuiInset = function() return M.Vector2.new(0, 36) end
    rawget(vim, "__d").props.SendKeyEvent = function(_, down, key) if down then self.key_pending = true end end

    local net = M.inst("Network", "Network"); net.Parent = stats
    local ssi = M.inst("ServerStatsItem", "ServerStatsItem"); ssi.Parent = net
    local dp = M.inst("StatsItem", "Data Ping"); dp.Parent = ssi
    rawget(dp, "__d").props.GetValue = function()
        return (self.ping_ewma or cfg.rtt) * 1000 * (cfg.ping_bias or 1)
    end

    local remotes = M.folder("Remotes", rep)
    self.remotes = {}
    for _, n in ipairs({ "ParrySuccess", "ParrySuccessAll", "ParryAttempt", "ParryAttemptAll", "NoobParryHappened",
        "TimeHoleHoldBall", "InfinityBall", "DeathBall", "DeathSlashShootActivation" }) do
        self.remotes[n] = M.remote(n, remotes)
    end
    self.remotes.M1Stop = M.bindable("M1Stop", remotes)
    self.remotes.AbilityButtonPress = M.bindable("AbilityButtonPress", remotes)
    local pk = M.folder("Packages", rep)
    local idx = M.folder("_Index", pk)
    local pkg = M.folder("sleitnick_net@0.1.0", idx)
    local netf = M.folder("net", pkg)
    if cfg.feed then
        self.feed_remote = M.remote("URE/feed", netf, "UnreliableRemoteEvent")
    end
    M.remote("RE/decoy", netf)

    self.player_inst = {}
    local function mkchar(name, pos, is_me)
        local plr = M.inst("Player", name)
        local pd = rawget(plr, "__d").props
        pd.UserId = #name * 1000 + 7
        pd.CharacterAdded = M.signal()
        pd.GetNetworkPing = function() return cfg.rtt * 0.5 end
        local up = M.folder("Upgrades", plr)
        local qi = M.inst("IntValue", "Qi-Charge"); rawget(qi, "__d").props.Value = 0; qi.Parent = up
        M.folder("PlayerGui", plr)
        plr.Parent = players
        local char = M.inst("Model", name)
        local root = M.inst("Part", "HumanoidRootPart")
        local rd = rawget(root, "__d").props
        rd.Size = v3(2, 2, 1)
        if is_me then
            M.set_getter(root, "Position", function() return self:me_pos(M.now) end)
            M.set_getter(root, "CFrame", function()
                local p = self:me_pos(M.now)
                return M.CFrame.lookAt(p, p + v3(0, 0, -1))
            end)
            M.set_getter(root, "AssemblyLinearVelocity", function() return self:me_vel(M.now) end)
        else
            rd.Position = pos
            rd.CFrame = M.CFrame.lookAt(pos, self.me_base)
            rd.AssemblyLinearVelocity = v3(0, 0, 0)
        end
        root.Parent = char
        local hum = M.inst("Humanoid", "Humanoid")
        rawget(hum, "__d").props.Health = 100
        rawget(hum, "__d").props.RigType = M.Enum.HumanoidRigType.R6
        hum.Parent = char
        local animator = M.inst("Animator", "Animator")
        rawget(animator, "__d").props.AnimationPlayed = M.signal()
        rawget(animator, "__d").props.GetPlayingAnimationTracks = function() return {} end
        rawget(animator, "__d").props.LoadAnimation = function() error("no animations in sim") end
        animator.Parent = hum
        rawget(char, "__d").props.PrimaryPart = root
        char.Parent = alive
        pd.Character = char
        self.player_inst[name] = plr
        return plr, char
    end
    self.mkchar = mkchar
    rawget(players, "__d").props.GetPlayerFromCharacter = function(_, char)
        for _, p in ipairs(M.raw_children(players)) do if p.Character == char then return p end end
        return nil
    end
    rawget(players, "__d").props.GetPlayers = function() return players:GetChildren() end
    self.players_svc = players
    self.game = game
    self.ws = ws
    return game
end

function World:spawn_ball()
    local ball = M.inst("Part", "Ball")
    rawget(ball, "__d").props.Size = v3(self.cfg.ball_size or 2.2, self.cfg.ball_size or 2.2, self.cfg.ball_size or 2.2)
    ball:SetAttribute("realBall", true)
    ball:SetAttribute("target", "")
    local z = M.inst("LinearVelocity", "zoomies")
    rawget(z, "__d").props.VectorVelocity = v3(0, 0, 0)
    z.Parent = ball
    M.set_getter(ball, "Position", function() local p = self:render_state(); return p end)
    M.set_getter(ball, "AssemblyLinearVelocity", function() local _, v = self:render_state(); return v end)
    M.set_getter(ball, "CFrame", function() return M.CFrame.new(self:render_state()) end)
    self.ball_inst, self.zoomies = ball, z
    ball.Parent = self.balls
    return ball
end

---------------------------------------------------------------- script
function World:make_env(genv)
    local env = {}
    for k, v in pairs(_G) do env[k] = v end
    env._G = env
    env.game = self.game
    env.workspace = self.ws
    env.Workspace = self.ws
    env.Vector3, env.Vector2, env.CFrame, env.Enum = M.Vector3, M.Vector2, M.CFrame, M.Enum
    env.typeof = M.typeof
    env.task = M.task
    env.wait = M.task.wait
    env.spawn = M.task.spawn
    env.delay = M.task.delay
    env.tick = function() return M.now end
    env.time = function() return M.now end
    env.os = { clock = function() return M.now end, date = os.date, time = function() return math.floor(BASE_SERVER_TIME + M.now) end }
    env.table = M.make_table_lib()
    env.math = M.make_math_lib(self.script_rng)
    env.bit32 = M.bit32
    env.getgenv = function() return genv end
    env.isfile = function(p) return p == "BladeBall/echo.txt" end
    env.readfile = function(p) if p == "BladeBall/echo.txt" then return "1" end; error("no file") end
    env.writefile = function() end
    env.appendfile = function(_, line) if self.cfg.log then self.log = self.log or {}; self.log[#self.log + 1] = line end end
    env.makefolder = function() end
    env.isfolder = function() return true end
    env.keypress = function(k) if k == 0x46 then self.key_pending = true end end
    env.keyrelease = function() end
    env.isrbxactive = function() return true end
    env.identifyexecutor = function() return "ParrySim" end
    env.Instance = { new = function(cls) return M.inst(cls, cls) end }
    env.Color3 = { new = function() return {} end, fromRGB = function() return {} end }
    env.print = function(...) if self.cfg.print then print(...) end end
    env.warn = env.print
    return env
end

function World:load_script(chunk, opts)
    local genv = { BBStop = 1 }
    local env = self:make_env(genv)
    setfenv(chunk, env)
    local co = coroutine.create(chunk)
    M.resume(co)
    M.run_deferred()
    local sim = genv.__SIM
    if not sim then error("script did not export __SIM (load failed): " .. tostring(next(M.errors) and select(2, next(M.errors)))) end
    self.sim = sim
    self.genv = genv
    local P = sim.Parry
    local S = P.S
    S.parry_mode = opts.mode or "Remote"
    for k, v in pairs(opts.S or {}) do S[k] = v end
    if opts.after_load then opts.after_load(sim, self) end
    if opts.triggerbot then S.triggerbot = true; sim.Engine.want("triggerbot", true) end
    if opts.autoparry ~= false then S.autoparry = true; sim.Engine.want("autoparry", true) end
    M.run_deferred()
    if S.parry_mode == "Remote" and opts.inject_cap ~= false then
        local core = P.__Core
        local text = tostring(math.floor((BASE_SERVER_TIME + M.now) * 100))
        local key = {}
        for i = 1, #text do key[i] = 0 end
        local remote = M.remote("RE/parry", self.game:GetService("ReplicatedStorage"))
        M.on_fire(remote, function() self.out[#self.out + 1] = { kind = "remote" } end)
        core.cap = { remote = remote, hash = "5455ef47-de02-4074-808c-8d82c2cd12ec", uid = "uid", key = key, len = #text,
            ball2 = false, verified = true, id = 1, win = self.cfg.W }
    end
end

---------------------------------------------------------------- main loop
function World:client_frame(dt)
    self:deliver()
    if self.key_pending then self.key_pending = false; self:game_block_press() end
    local rs = rawget(self.rs, "__d").props
    rs.PreRender:Fire(dt); M.run_deferred()
    rs.RenderStepped:Fire(dt); M.run_deferred()
    rs.PreAnimation:Fire(dt); M.run_deferred()
    rs.PreSimulation:Fire(dt); M.run_deferred()
    rs.Stepped:Fire(M.now, dt); M.run_deferred()
    rs.PostSimulation:Fire(dt); M.run_deferred()
    rs.Heartbeat:Fire(dt); M.run_deferred()
    M.run_timers()
    self:flush_out()
end

function World:run(duration)
    local fdt = 1 / self.cfg.fps
    local t_end = M.now + duration
    while M.now < t_end and not self.done do
        local jitter = self.cfg.frame_jitter or 0
        local dt = fdt * (1 + jitter * (self.rng() * 2 - 1))
        local next_frame = self.client_t + dt
        while self.server_next <= next_frame and not self.done do
            M.now = self.server_next
            self:server_tick(self.server_next)
            self.server_next = self.server_next + SERVER_DT
        end
        if self.done then break end
        M.now = next_frame
        self.client_t = next_frame
        local r = self.cfg.rtt
        self.ping_ewma = (self.ping_ewma or r) * 0.9 + (r + math.abs(self:gauss()) * (self.cfg.jitter or 0) * 2) * 0.1
        self:client_frame(dt)
        if self.tick_hook then self:tick_hook() end
    end
end

function World:init_common()
    self.client_t = 0
    self.server_next = SERVER_DT
    self.cl = { snaps = {}, win_until = -1, cool_until = -1 }
    self.sv = { players = {}, ball = nil }
    self.me_name = "Me"
    if self.cfg.move then
        local dirs = {}
        for i = 1, 8 do
            local a = self:rand(0, 2 * math.pi)
            dirs[i] = v3(math.cos(a), 0, math.sin(a))
        end
        self.move_dirs = dirs
    end
    self.spikes = {}
    for _, s in ipairs(self.cfg.spikes or {}) do self.spikes[#self.spikes + 1] = s end
end

function World:add_player(name, pos, is_me, bot)
    local P = { name = name, pos = pos, is_me = is_me, alive = true, win_until = -1, cool_until = -1, win_start = -1 }
    if bot then for k, v in pairs(bot) do P[k] = v end end
    self.sv.players[name] = P
    local plr, char = self.mkchar(name, pos, is_me)
    if is_me then
        self.me_char = char
        self.me_plr = plr
        rawget(self.players_svc, "__d").props.LocalPlayer = plr
    end
    return P
end

return World

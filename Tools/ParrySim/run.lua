-- Parry simulator runner.
--   luajit Tools/ParrySim/run.lua <suite> <script.lua> [variant] [trials] [seed0]
-- suites: pass | rally | ffa | smoke
-- variants: ap (auto parry, Remote), apkey (auto parry, Keypress), tb (triggerbot, Remote)
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/?.lua;" .. package.path
local M = require("mock")
local World = require("world")
local v3 = M.v3

local suite, script, variant = arg[1] or "smoke", arg[2] or "Games/BladeBallRewrite.lua", arg[3] or "ap"
local trials, seed0 = tonumber(arg[4] or "200"), tonumber(arg[5] or "1")
local filter = os.getenv("SIM_FILTER")

local function load_chunk(path)
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    local n1, n2
    src, n1 = src:gsub("if getgenv%(%)%.BBStop == 1 then",
        "getgenv().__SIM = { Parry = Parry, Engine = Engine, Util = Util, Anim = Anim }; if getgenv().BBStop == 1 then", 1)
    src, n2 = src:gsub("function Parry%.isMe%(name%) return name == me end",
        "function Parry.isMe(name) return name == me end\n    Parry.__Core = Core; Parry.__AP = AP; Parry.__Pred = Pred", 1)
    assert(n1 == 1 and n2 == 1, "patch anchors missing in " .. path)
    src = src:gsub("Core%.last_parry = { t = now, via = via, info = info }",
        "Core.last_parry = { t = now, via = via, info = info }; if getgenv().__ONFIRE then getgenv().__ONFIRE(via, info) end", 1)
    return assert(loadstring(src, "=" .. path))
end
local chunk = load_chunk(script)

local VARIANTS = {
    ap = { mode = "Remote" },
    apkey = { mode = "Keypress" },
    tb = { mode = "Remote", triggerbot = true },
    tbkey = { mode = "Keypress", triggerbot = true },
}
local opts = VARIANTS[variant] or error("unknown variant " .. variant)
if os.getenv("SIM_TRUELAW") then
    local prev = opts.after_load
    opts.after_load = function(sim, w)
        if prev then prev(sim, w) end
        local Pr = sim.Parry.__Pred
        if not Pr then return end
        Pr.globalFit = function()
            local L, h = w.law, w.cfg.homing
            if not L then return nil end
            local tk = 1 / 60
            if L.law == "prop" then return { m = 4, a = L.k * tk, b = 0, al = h.speed_scale or 0, u = 0.06, n = 999 } end
            if L.law == "ramp" then return { m = 4, a = L.k0 * tk, b = L.k1 * tk, al = h.speed_scale or 0, u = 0.06, n = 999 } end
            return { m = 2, a = L.w * tk, b = 0, al = h.speed_scale or 0, u = 0.06, n = 999 }
        end
    end
end
if os.getenv("SIM_NOCAL") then
    local prev = opts.after_load
    opts.after_load = function(sim, w)
        if prev then prev(sim, w) end
        if sim.Parry.__AP then sim.Parry.__AP.addRes = function() end end
    end
end
if os.getenv("SIM_DBG") then
    local prev = opts.after_load
    opts.after_load = function(sim, w)
        if prev then prev(sim, w) end
        sim.Parry.DBG.on = true
        if os.getenv("SIM_LOG") then
            local ev = sim.Parry.DBG.ev
            sim.Parry.DBG.ev = function(text)
                w.log = w.log or {}
                w.log[#w.log + 1] = ("t=%.3f dbg %s\n"):format(M.now, tostring(text))
                return ev(text)
            end
        end
        w.tick_hook = function(w2)
            local e = sim.Parry.DBG.eval
            if e.t and e.t ~= w2.last_eval_t and os.getenv("SIM_EVAL") then
                w2.last_eval_t = e.t
                w2.log = w2.log or {}
                w2.log[#w2.log + 1] = ("t=%.3f eval %s spd %.0f d %.1f head %.2f lo %.3f mid %.3f hi %.3f fire<=%.3f k %s m %s\n"):format(
                    M.now, tostring(e.via), e.speed or 0, e.dist or 0, e.heading or 0, e.lo or 0, e.mid or 0, e.hi or 0, e.lead or 0,
                    tostring(e.k), tostring(e.model))
            end
            local b = sim.Parry.DBG.block
            if b and b ~= w2.last_block then
                w2.last_block = b
                w2.log = w2.log or {}
                w2.log[#w2.log + 1] = ("t=%.3f held: %s\n"):format(M.now, b)
            end
        end
    end
end
local extraS = os.getenv("SIM_S")
if extraS then
    opts.S = opts.S or {}
    for kv in extraS:gmatch("[^,]+") do
        local k, v = kv:match("^(.-)=(.*)$")
        if v == "true" then v = true elseif v == "false" then v = false elseif tonumber(v) then v = tonumber(v) end
        opts.S[k] = v
    end
end

local PINGS = { 20, 60, 100, 150, 200, 250, 300, 400, 500 }
local CURVES = { "straight", "straight", "slight", "high", "side", "backwards", "diagonal", "flick", "random", "sky" }
local LAWS = { "prop", "turn", "ramp" }

local function rnd_params(w, i)
    local p = {}
    p.rtt = PINGS[(i - 1) % #PINGS + 1] / 1000
    p.jitter = w:rand(0.002, 0.012) + p.rtt * w:rand(0.02, 0.08)
    p.fps = w:pick({ 60, 60, 144, 240 })
    p.buffer = w:rand(0.03, 0.12)
    local law = w:pick(LAWS)
    p.homing = { law = law, k = { 3, 14 }, w = { 3, 11 }, k0 = { 1, 5 }, k1 = { 4, 16 } }
    p.dx = w:pick({ 0, 0, 2, 4 })
    p.ds = w:pick({ nil, nil, 0.03 })
    p.ping_bias = w:rand(0.9, 1.1)
    p.deferred = w.rng() < 0.5
    if os.getenv("SIM_SPEEDK") or w.rng() < 0.5 then p.homing.speed_scale = w:rand(0.3, 1.0) end
    if w.rng() < 0.35 then p.move = { speed = w:rand(10, 22), period = w:rand(0.4, 1.4) } end
    if w.rng() < 0.3 then
        local t0 = w:rand(0.2, 2.5)
        p.spikes = { { t0 = t0, t1 = t0 + w:rand(0.2, 1.2), add = w:rand(0.04, 0.2) } }
    end
    return p
end

local function base_world(i, seed, o)
    local probe = World.new({ seed = seed })
    local p = rnd_params(probe, i)
    if o and o.no_move then p.move = nil end
    local cfg = { seed = seed + 17, rtt = p.rtt, jitter = p.jitter, fps = p.fps, buffer = p.buffer, homing = p.homing,
        W = 0.5, cooldown = 1.3, kill_dist = 3.5, deflect_extra = p.dx, deflect_speed = p.ds, move = p.move, spikes = p.spikes,
        ping_bias = p.ping_bias, frame_jitter = 0.1, attr_first = probe.rng() < 0.5, log = os.getenv("SIM_LOG") ~= nil, deferred = p.deferred, wlog = os.getenv("SIM_WLOG") ~= nil, perfect_bots = true }
    if os.getenv("SIM_DEFERRED") then cfg.deferred = os.getenv("SIM_DEFERRED") == "1" end
    if os.getenv("SIM_PINGBIAS") then cfg.ping_bias = tonumber(os.getenv("SIM_PINGBIAS")) end
    if os.getenv("SIM_BUF") then cfg.buffer = tonumber(os.getenv("SIM_BUF")) end
    local w = World.new(cfg)
    w:init_common()
    w:build_game()
    w.me_base = v3(0, 3, 0)
    w:add_player("Me", w.me_base, true)
    return w, p, probe
end

local function start_ball(w, from_pos, target, speed, curve)
    local ball = w:spawn_ball()
    local a = w:rand(0, 2 * math.pi)
    local rd = v3(math.cos(a), w:rand(0.05, 0.4), math.sin(a)).Unit
    local B = { pos = from_pos + rd * math.max(speed * 0.6, 12), speed = speed, dir = -rd }
    w.sv.ball = B
    B.curve = curve
    w:new_pass(B, nil, target, -rd, speed, 0)
    return ball, B
end

---------------------------------------------------------------- suites
local function run_pass(i, seed)
    local w, p, probe = base_world(i, seed)
    local speed = probe:pick({ 40, 70, 110, 160, 230, 320, 450, 650, 900, 1300 })
    local dist = probe:pick({ 12, 20, 30, 45, 65, 90, 120 })
    local curve = probe:pick(CURVES)
    local a = probe:rand(0, 2 * math.pi)
    local botpos = v3(math.cos(a) * dist, 3, math.sin(a) * dist)
    w:add_player("Bot", botpos, false, { lead = probe:rand(0.06, 0.25), up = 0.04 })
    w.scenario = {
        choose_target = function(w2, P) if P.is_me then w2.done = true; return nil end; return "Me" end,
        choose_curve = function() return curve end,
        next_speed = function() return speed end,
    }
    start_ball(w, botpos, "Bot", speed / 1.05, "straight")
    w.on_my_death = function(w2, t, reason)
        w2.done = true
        if w2.log then w2.log[#w2.log + 1] = ("t=%.3f DEATH %s\n"):format(t, tostring(reason)) end
    end
    w:load_script(chunk, opts)
    w:run(9)
    if os.getenv("SIM_DBG") and w.sim then
        w.log = w.log or {}
        for _, e in ipairs(w.sim.Parry.DBG.list) do w.log[#w.log + 1] = ("dbg %.3f %s\n"):format(e.t, e.text) end
    end
    local out = w.stats.success > 0 and "success" or (w.stats.deaths > 0 and ("dead:" .. (w.last_death and w.last_death.reason or "?")) or "timeout")
    return { rtt = p.rtt, speed = speed, dist = dist, curve = curve, out = out, fps = p.fps, law = p.homing.law, uses = w.stats.uses,
        wasted = w.stats.wasted, errs = M.err_count, log = w.log, flight = w.stats.flights[1],
        doubles = w.stats.doubles, shots = w.shots, buf_true = w.cfg.buffer, buf_est = w.sim and w.sim.Parry.__Pred and w.sim.Parry.__Pred.buf, buf_n = w.sim and w.sim.Parry.__Pred and w.sim.Parry.__Pred.buf_n }
end

local function run_rally(i, seed)
    local w, p, probe = base_world(i, seed, { no_move = true })
    local dist = probe:pick({ 10, 14, 18, 24, 32, 45 })
    local a = probe:rand(0, 2 * math.pi)
    local botpos = v3(math.cos(a) * dist, 3, math.sin(a) * dist)
    w:add_player("Bot", botpos, false, { up = 0.04 })
    local growth = probe:rand(0.04, 0.09)
    local MAXH = 30
    w.scenario = {
        choose_target = function(w2, P)
            if P.is_me then
                if w2.stats.my_hits >= MAXH then w2.done = true; return nil end
                return "Bot"
            end
            return "Me"
        end,
        choose_curve = function(w2, P) if P.is_me then return "straight" end; return w2:pick(CURVES) end,
        next_speed = function(w2, s) return s * (1 + growth) + 4 end,
    }
    start_ball(w, botpos, "Bot", probe:rand(35, 70), "straight")
    w.on_my_death = function(w2, t, reason)
        w2.done = true
        if w2.log then w2.log[#w2.log + 1] = ("t=%.3f DEATH %s speed %.0f curve %s\n"):format(t, tostring(reason), w2.sv.ball.speed, tostring(w2.sv.ball.curve)) end
    end
    w:load_script(chunk, opts)
    w:run(60)
    if os.getenv("SIM_DBG") and w.sim then
        w.log = w.log or {}
        for _, e in ipairs(w.sim.Parry.DBG.list) do w.log[#w.log + 1] = ("dbg %.3f %s\n"):format(e.t, e.text) end
    end
    local B = w.sv.ball
    return { doubles = w.stats.doubles, rtt = p.rtt, out = (w.stats.deaths > 0) and ("dead:" .. (w.last_death.reason or "?")) or "survived",
        hits = w.stats.my_hits, speed = B and B.speed or 0, dist = dist, errs = M.err_count, fps = p.fps, log = w.log,
        curve = w.last_death and w.last_death.curve }
end

local function run_ffa(i, seed)
    local w, p, probe = base_world(i, seed)
    local names = {}
    for b = 1, 5 do
        local a = probe:rand(0, 2 * math.pi)
        local r = probe:rand(14, 70)
        local name = "Bot" .. b
        w:add_player(name, v3(math.cos(a) * r, 3, math.sin(a) * r), false, { up = 0.04 })
        names[#names + 1] = name
    end
    local deaths = 0
    w.scenario = {
        choose_target = function(w2, P)
            local opts2 = { "Me" }
            for _, n in ipairs(names) do if n ~= P.name then opts2[#opts2 + 1] = n end end
            return w2:pick(opts2)
        end,
        choose_curve = function(w2, P) if P.is_me then return "straight" end; return w2:pick(CURVES) end,
        next_speed = function(w2, s) return math.min(s * 1.04 + 3, 1400) end,
    }
    local ball, B = start_ball(w, w.sv.players.Bot1.pos, "Bot1", 50, "straight")
    w.on_my_death = function(w2, t)
        deaths = deaths + 1
        local src = w2.sv.players[w2:pick(names)]
        B.pos = src.pos + v3(0, 2, 0)
        w2:new_pass(B, src.name, w2:pick(names), v3(0, 1, 0), 50, t)
    end
    w.on_bot_death = function(w2, P, t)
        B.pos = P.pos + v3(0, 3, 0)
        w2:new_pass(B, P.name, w2:pick(names) == P.name and "Me" or w2:pick(names), v3(0, 1, 0), 50, t)
    end
    w:load_script(chunk, opts)
    w:run(45)
    return { doubles = w.stats.doubles, rtt = p.rtt, deaths = deaths, passes = w.stats.passes, hits = w.stats.my_hits, wasted = w.stats.wasted,
        errs = M.err_count, fps = p.fps, reasons = w.stats.reasons }
end

local function run_session(i, seed)
    local w, p, probe = base_world(i, seed, { no_move = true })
    local dist = probe:pick({ 25, 35, 50, 70, 90 })
    local a = probe:rand(0, 2 * math.pi)
    local botpos = v3(math.cos(a) * dist, 3, math.sin(a) * dist)
    w:add_player("Bot", botpos, false, { up = 0.04 })
    local SPEEDS = { 60, 90, 130, 180, 250, 350, 500 }
    local tries, wins = 0, 0
    w.scenario = {
        choose_target = function(w2, P) if P.is_me then return "Bot" end; tries = tries + 1; return "Me" end,
        choose_curve = function(w2, P) if P.is_me then return "straight" end; return w2:pick(CURVES) end,
        next_speed = function(w2, s, P) if P.is_me then return s end; return w2:pick(SPEEDS) end,
    }
    local ball, B = start_ball(w, botpos, "Bot", 80, "straight")
    w.on_my_success = function() wins = wins + 1 end
    w.on_my_death = function(w2, t)
        B.pos = botpos + v3(0, 2, 0)
        w2:new_pass(B, "Bot", "Bot", v3(0, 1, 0), 60, t)
    end
    w:load_script(chunk, opts)
    w:run(70)
    local ap = w.sim and w.sim.Parry.__AP
    return { rtt = p.rtt, out = "session", hits = wins, tries = tries, deaths = w.stats.deaths, fps = p.fps,
        bias = ap and ap.cal.bias or 0, errs = M.err_count, reasons = w.stats.reasons,
        off = ap and ap.net.off_rem or 0 }
end

local function run_ability(i, seed)
    local w, p, probe = base_world(i, seed, { no_move = true })
    local dist = probe:pick({ 14, 20, 30, 45, 60 })
    local a = probe:rand(0, 2 * math.pi)
    local botpos = v3(math.cos(a) * dist, 3, math.sin(a) * dist)
    w:add_player("Bot", botpos, false, { up = 0.04 })
    local kind = probe:pick({ "singularity", "fury" })
    local o = { dur = probe:rand(0.8, 2.5), orbit_speed = probe:rand(60, 220), to = "Me",
        speed = probe:rand(2, 5) * probe:pick({ 90, 140, 220 }), curve = probe:pick({ "straight", "straight", "slight", "high" }),
        attr = kind == "singularity" and "ClosestSingularity" or "FuryCatch_Bot", value = kind == "singularity" and "Bot" or true,
        target_during = probe.rng() < 0.5 and "Me" or nil }
    w.scenario = {
        choose_target = function(w2, P) if P.is_me then w2.done = true; return nil end; return "Me" end,
        choose_curve = function() return "straight" end,
        next_speed = function(_, s2) return s2 end,
    }
    local ball, B = start_ball(w, botpos, "Bot", 120, "straight")
    w.tick_hook = nil
    local held = false
    local prev = w.on_my_death
    w.on_my_death = function(w2, t, reason)
        w2.done = true
        if w2.log then w2.log[#w2.log + 1] = ("t=%.3f DEATH %s\n"):format(t, tostring(reason)) end
    end
    w:load_script(chunk, opts)
    local orig_bot_plan = w.bot_plan
    w.bot_plan = function(w2, P, B2, t)
        if not held and (B2.pos - P.pos).Magnitude < 25 then
            held = true
            w2:start_hold(B2, P.name, t, o)
            return
        end
        if not held then return orig_bot_plan(w2, P, B2, t) end
    end
    w:run(8)
    local out = w.stats.success > 0 and "success" or (w.stats.deaths > 0 and ("dead:" .. (w.last_death and w.last_death.reason or "?")) or "timeout")
    return { rtt = p.rtt, out = out, speed = math.floor(o.speed), dist = dist, curve = kind .. (o.target_during and "+on-you" or ""),
        fps = p.fps, errs = M.err_count, wasted = w.stats.wasted, doubles = w.stats.doubles, log = w.log,
        flight = w.stats.flights[1] }
end

local function run_dots(i, seed)
    local w, p, probe = base_world(i, seed, { no_move = true })
    local dist = probe:pick({ 8, 11, 14, 17, 20 })
    local a = probe:rand(0, 2 * math.pi)
    local botpos = v3(math.cos(a) * dist, 3, math.sin(a) * dist)
    w:add_player("Bot", botpos, false, { up = 0.04 })
    local growth = probe:rand(0.04, 0.09)
    local MAXH = 20
    w.scenario = {
        choose_target = function(w2, P)
            if P.is_me then
                if w2.stats.my_hits >= MAXH then w2.done = true; return nil end
                return "Bot"
            end
            return "Me"
        end,
        choose_curve = function(w2, P)
            if P.is_me then return "straight" end
            if w2.rng() < 0.75 then return "straight" end
            return w2:pick(CURVES)
        end,
        next_speed = function(w2, s2) return s2 * (1 + growth) + 4 end,
    }
    start_ball(w, botpos, "Bot", probe:rand(35, 70), "straight")
    w.on_my_death = function(w2) w2.done = true end
    w:load_script(chunk, opts)
    w:run(60)
    return { rtt = p.rtt, out = (w.stats.deaths > 0) and ("dead:" .. (w.last_death.reason or "?")) or "survived",
        hits = w.stats.my_hits, dist = dist, errs = M.err_count, fps = p.fps, doubles = w.stats.doubles, log = w.log }
end

local function run_match(i, seed)
    local w, p, probe = base_world(i, seed, { no_move = os.getenv("SIM_MATCH_MOVE") == nil })
    local nbots = tonumber(os.getenv("SIM_BOTS") or "1")
    local names, P = {}, {}
    for b = 1, nbots do
        local a = probe:rand(0, 2 * math.pi)
        local r = probe:rand(15, 70)
        local name = "Bot" .. b
        P[name] = w:add_player(name, v3(math.cos(a) * r, 3, math.sin(a) * r), false, { up = 0.04 })
        names[#names + 1] = name
        local root = w.player_inst[name].Character:FindFirstChild("HumanoidRootPart")
        M.set_getter(root, "Position", function() return P[name].pos end)
        M.set_getter(root, "CFrame", function() return M.CFrame.lookAt(P[name].pos, w.me_base) end)
        P[name].wp = P[name].pos
    end
    w.on_server_tick = function(w2, t)
        for _, n in ipairs(names) do
            local B = P[n]
            local to = B.wp - B.pos
            if to.Magnitude < 1 then
                local a, r = w2:rand(0, 2 * math.pi), w2:rand(12, 80)
                B.wp = w2.me_base + v3(math.cos(a) * r, 0, math.sin(a) * r)
            else
                B.pos = B.pos + to.Unit * math.min(16 / 60, to.Magnitude)
            end
            local off = B.pos - w2.me_base
            local flat = v3(off.X, 0, off.Z)
            if flat.Magnitude < 10 then
                local d = flat.Magnitude > 0.1 and flat.Unit or v3(1, 0, 0)
                B.pos = v3(w2.me_base.X + d.X * 10, B.pos.Y, w2.me_base.Z + d.Z * 10)
            end
        end
    end
    local function next_speed(s2)
        if s2 > 1000 or w.rng() < 0.08 then return w:rand(40, 90) end
        return s2 * w:rand(1.04, 1.08) + 3
    end
    w.scenario = {
        choose_target = function(w2, Pl)
            if Pl.is_me then return w2:pick(names) end
            if nbots == 1 or w2.rng() < 0.5 then return "Me" end
            local o = {}
            for _, n in ipairs(names) do if n ~= Pl.name then o[#o + 1] = n end end
            return w2:pick(o)
        end,
        choose_curve = function(w2, Pl) if Pl.is_me then return "straight" end; return w2:pick(CURVES) end,
        next_speed = function(w2, s2, Pl) return next_speed(s2) end,
    }
    local ball, B = start_ball(w, P[names[1]].pos, names[1], 60, "straight")
    local restart_at
    w.on_my_death = function(w2, t)
        B.target = nil
        restart_at = t + 2
    end
    local move_bots = w.on_server_tick
    w.on_server_tick = function(w2, t)
        move_bots(w2, t)
        if restart_at and t >= restart_at then
            restart_at = nil
            local me = w2.sv.players[w2.me_name]
            me.win_until, me.cool_until, me.win_start = -1, -1, -1
            w2.cl.win_until, w2.cl.cool_until = -1, -1
            local src = P[w2:pick(names)]
            local a = w2:rand(0, 2 * math.pi)
            local rd = v3(math.cos(a), 0.2, math.sin(a)).Unit
            B.pos = src.pos + rd * 30
            w2:new_pass(B, nil, src.name, -rd, w2:rand(40, 90), t)
        end
    end
    w:load_script(chunk, opts)
    w:run(tonumber(os.getenv("SIM_MATCH_SECS") or "90"))
    if os.getenv("SIM_LOG") and w.log then for _, l in ipairs(w.log) do io.write(l) end end
    if os.getenv("SIM_DBG") and w.sim then for _, e in ipairs(w.sim.Parry.DBG.list) do io.write(("dbg %.3f %s\n"):format(e.t, e.text)) end end
    if os.getenv("SIM_GFIT") and w.sim and w.sim.Parry.__Pred then
        local Pr = w.sim.Parry.__Pred
        local gf = Pr.globalFit(M.now + 10)
        local L = w.law or {}
        io.write(("match %d true: %s k %.2f w %s k0 %s k1 %s speedpow %s | learned: %s\n"):format(i, tostring(L.law), L.k or 0, tostring(L.w and ("%.2f"):format(L.w)),
            tostring(L.k0 and ("%.2f"):format(L.k0)), tostring(L.k1 and ("%.2f"):format(L.k1)), tostring(p.homing.speed_scale and ("%.2f"):format(p.homing.speed_scale)),
            gf and ("model %d a %.2f b %.2f pow %.1f fit-err %.0f%% n %d"):format(gf.m, gf.a, gf.b or 0, gf.al, gf.u * 100, gf.n) or "none"))
    end
    return { rtt = p.rtt, out = "match", plog = w.stats.plog, fps = p.fps, errs = M.err_count, doubles = w.stats.doubles,
        law = p.homing.law }
end

---------------------------------------------------------------- report
local function bucket(r) return math.floor(r.rtt * 1000 + 0.5) end
local results = {}
local t0 = os.clock()
local runner = ({ pass = run_pass, rally = run_rally, ffa = run_ffa, smoke = run_pass, session = run_session, ability = run_ability, dots = run_dots, match = run_match })[suite]
if suite == "smoke" then trials = math.min(trials, 3) end
local only = os.getenv("SIM_ONLY")
for i = 1, trials do
    local seed = seed0 * 100003 + i
    if only and tostring(i) ~= only then goto continue end
    local ok, r = pcall(runner, i, seed)
    if not ok then
        io.stderr:write("trial " .. i .. " crashed: " .. tostring(r) .. "\n")
    else
        r.i, r.seed = i, seed
        results[#results + 1] = r
        if suite == "smoke" or os.getenv("SIM_VERBOSE") then
            print(("#%d seed %d rtt %3dms fps %3d %s spd %s dist %s curve %s -> %s errs %d"):format(i, seed, bucket(r), r.fps or 0,
                r.law or "", tostring(r.speed), tostring(r.dist), tostring(r.curve), tostring(r.out or r.deaths), r.errs or 0))
            if r.buf_est and os.getenv("SIM_BUFCHK") then print(("   buffer true %.3f est %.3f (n %d)"):format(r.buf_true, r.buf_est, r.buf_n or 0)) end
            if r.log and os.getenv("SIM_LOG") then for _, l in ipairs(r.log) do io.write("   | " .. l) end end
        end
    end
    ::continue::
end
for _, msg in pairs(M.errors) do io.stderr:write("[script error] " .. msg .. "\n") end
local shots_path = os.getenv("SIM_SHOTS")
if shots_path then
    local f = assert(io.open(shots_path, "w"))
    f:write("i,rtt,speed,u,curve\n")
    for _, r in ipairs(results) do
        for _, sh in ipairs(r.shots or {}) do
            f:write(("%d,%d,%.0f,%.4f,%s\n"):format(r.i, bucket(r), sh.speed, sh.u, tostring(sh.curve)))
        end
    end
    f:close()
end
local csv = os.getenv("SIM_CSV")
if csv then
    local f = assert(io.open(csv, "w"))
    f:write("i,seed,rtt,fps,law,speed,dist,curve,out,hits,wasted,flight,doubles\n")
    for _, r in ipairs(results) do
        f:write(("%d,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d\n"):format(r.i, r.seed, bucket(r), r.fps or 0, tostring(r.law), tostring(r.speed),
            tostring(r.dist), tostring(r.curve), tostring(r.out or r.deaths), tostring(r.hits or ""), tostring(r.wasted or ""),
            r.flight and ("%.4f"):format(r.flight) or "", r.doubles or 0))
    end
    f:close()
end

if suite == "match" and os.getenv("SIM_PLOG") then
    local f = assert(io.open(os.getenv("SIM_PLOG"), "w"))
    f:write("i,rtt,k,flight,ok,reason,speed,curve,law,via,fires,dist,info,fire_at,range_at,e_lo,e_mid,e_hi,vias\n")
    for _, r in ipairs(results) do
        for k, pl in ipairs(r.plog or {}) do
            local via = tostring(pl.via or "none"):gsub(",", ";")
            f:write(("%d,%d,%d,%.4f,%d,%s,%.0f,%s,%s,%s,%d,%.1f,%s,%s"):format(r.i, bucket(r), k, pl.flight, pl.ok and 1 or 0, tostring(pl.reason), pl.speed or 0,
                tostring(pl.curve), tostring(r.law), via, pl.fires or 0, pl.dist or 0, tostring(pl.info or "-"),
                pl.fire_at and ("%.3f"):format(pl.fire_at) or "-") .. "," ..
                (pl.t_range and ("%.3f"):format(pl.t_range - pl.t0) or "-") .. "," ..
                ((pl.E and pl.t_range) and ("%.3f,%.3f,%.3f"):format(pl.E.lo - pl.t_range, pl.E.mid - pl.t_range, pl.E.hi - pl.t_range) or "-,-,-") ..
                "," .. tostring(pl.vias or "-") .. "\n")
        end
    end
    f:close()
end
if suite == "match" then
    local agg, tot = {}, { n = 0, ok = 0, wn = 0, wok = 0, rs = {} }
    local laws = {}
    for _, r in ipairs(results) do
        local b = bucket(r)
        agg[b] = agg[b] or { n = 0, ok = 0, wn = 0, wok = 0, un = 0, uok = 0 }
        local A = agg[b]
        laws[r.law] = laws[r.law] or { n = 0, ok = 0 }
        for k, pl in ipairs(r.plog or {}) do
            if pl.flight >= r.rtt + 0.035 then
                A.n, A.ok = A.n + 1, A.ok + (pl.ok and 1 or 0)
                tot.n, tot.ok = tot.n + 1, tot.ok + (pl.ok and 1 or 0)
                laws[r.law].n, laws[r.law].ok = laws[r.law].n + 1, laws[r.law].ok + (pl.ok and 1 or 0)
                if k > 8 then A.wn, A.wok, tot.wn, tot.wok = A.wn + 1, A.wok + (pl.ok and 1 or 0), tot.wn + 1, tot.wok + (pl.ok and 1 or 0) end
                if not pl.ok then tot.rs[pl.reason or "?"] = (tot.rs[pl.reason or "?"] or 0) + 1 end
            else
                A.un, A.uok = A.un + 1, A.uok + (pl.ok and 1 or 0)
            end
        end
    end
    local ks = {}
    for k in pairs(agg) do ks[#ks + 1] = k end
    table.sort(ks)
    print(("== match | %s | %s | %d matches"):format(script, variant, #results))
    for _, k in ipairs(ks) do
        local A = agg[k]
        print(("ping %3dms  reachable %5.1f%% of %4d  (after the first 8 passes %5.1f%%)  unreachable hit %d/%d"):format(k,
            A.ok / math.max(A.n, 1) * 100, A.n, A.wok / math.max(A.wn, 1) * 100, A.uok, A.un))
    end
    local rs = {}
    for k, v in pairs(tot.rs) do rs[#rs + 1] = k .. " " .. v end
    table.sort(rs)
    local ls = {}
    for k, v in pairs(laws) do ls[#ls + 1] = ("%s %.1f%%"):format(k, v.ok / math.max(v.n, 1) * 100) end
    table.sort(ls)
    print(("total reachable %.1f%% (%d/%d), after warm-up %.1f%%  [%s]  by law: %s"):format(tot.ok / math.max(tot.n, 1) * 100, tot.ok, tot.n,
        tot.wok / math.max(tot.wn, 1) * 100, table.concat(rs, ", "), table.concat(ls, ", ")))
    local dbl = 0
    for _, r in ipairs(results) do dbl = dbl + (r.doubles or 0) end
    print(("double parries: %d"):format(dbl))
    os.exit(0)
end
if suite == "session" then
    local agg = {}
    for _, r in ipairs(results) do
        local b = bucket(r)
        agg[b] = agg[b] or { tries = 0, hits = 0, bias = 0, n = 0, rs = {}, off = 0 }
        local A = agg[b]
        A.tries, A.hits, A.bias, A.n, A.off = A.tries + r.tries, A.hits + r.hits, A.bias + r.bias, A.n + 1, A.off + r.off
        for k, v in pairs(r.reasons or {}) do A.rs[k] = (A.rs[k] or 0) + v end
    end
    local ks = {}
    for k in pairs(agg) do ks[#ks + 1] = k end
    table.sort(ks)
    print(("== session | %s | %s | %d trials"):format(script, variant, #results))
    local T, H = 0, 0
    for _, k in ipairs(ks) do
        local A = agg[k]
        T, H = T + A.tries, H + A.hits
        local rs = {}
        for name, c in pairs(A.rs) do rs[#rs + 1] = name .. " " .. c end
        table.sort(rs)
        print(("ping %3dms  %5.1f%% of %d passes  correction %+.0fms  echo offset %+.0fms  [%s]"):format(k, A.hits / math.max(A.tries, 1) * 100,
            A.tries, A.bias / A.n * 1000, A.off / A.n * 1000, table.concat(rs, ", ")))
    end
    print(("total %.1f%%"):format(H / math.max(T, 1) * 100))
    os.exit(0)
end
local by = {}
for _, r in ipairs(results) do
    local b = bucket(r)
    by[b] = by[b] or { n = 0, ok = 0, reasons = {}, hits = 0, deaths = 0, passes = 0, wasted = 0, uses = {} }
    local B = by[b]
    B.n = B.n + 1
    if suite == "ffa" then
        B.deaths, B.passes, B.wasted, B.hits = B.deaths + r.deaths, B.passes + r.passes, B.wasted + r.wasted, B.hits + r.hits
        for k, v in pairs(r.reasons) do B.reasons[k] = (B.reasons[k] or 0) + v end
    else
        if r.out == "success" or r.out == "survived" then B.ok = B.ok + 1
        elseif r.out ~= "timeout" then local k = r.out:gsub("^dead:", ""); B.reasons[k] = (B.reasons[k] or 0) + 1 end
        if r.out == "timeout" then B.n = B.n - 1 end
        B.hits = B.hits + (r.hits or 0)
        for _, u in ipairs(r.uses or {}) do B.uses[#B.uses + 1] = u end
        B.wasted = B.wasted + (r.wasted or 0)
    end
end
local keys = {}
for k in pairs(by) do keys[#keys + 1] = k end
table.sort(keys)
print(("== %s | %s | %s | %d trials | %.1fs"):format(suite, script, variant, #results, os.clock() - t0))
local tot_n, tot_ok = 0, 0
for _, k in ipairs(keys) do
    local B = by[k]
    local rs = {}
    for name, c in pairs(B.reasons) do rs[#rs + 1] = name .. " " .. c end
    table.sort(rs)
    if suite == "ffa" then
        print(("ping %3dms  deaths/min %.2f  passes %d  hits %d  wasted %d  [%s]"):format(k, B.deaths / (B.n * 0.75), B.passes, B.hits,
            B.wasted, table.concat(rs, ", ")))
    else
        local med
        if #B.uses > 0 then table.sort(B.uses); med = B.uses[math.ceil(#B.uses / 2)] end
        print(("ping %3dms  %5.1f%%  (%d/%d)%s  [%s]%s"):format(k, B.n > 0 and B.ok / B.n * 100 or 0, B.ok, B.n,
            (suite == "rally" or suite == "dots") and ("  avg hits %.1f"):format(B.hits / math.max(B.n, 1)) or "",
            table.concat(rs, ", "), med and ("  window used med %.0fms"):format(med * 1000) or ""))
        tot_n, tot_ok = tot_n + B.n, tot_ok + B.ok
    end
end
if suite ~= "ffa" then print(("total %.1f%% (%d/%d)"):format(tot_ok / math.max(tot_n, 1) * 100, tot_ok, tot_n)) end
local dbl, dtr = 0, 0
for _, r in ipairs(results) do if (r.doubles or 0) > 0 then dbl, dtr = dbl + r.doubles, dtr + 1 end end
print(("double parries: %d extra parries on the same ball, in %d of %d trials"):format(dbl, dtr, #results))

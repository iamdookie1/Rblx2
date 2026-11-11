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
if os.getenv("SIM_NOCAL") then
    local prev = opts.after_load
    opts.after_load = function(sim, w)
        if prev then prev(sim, w) end
        if sim.Parry.__AP then sim.Parry.__AP.addRes = function() end end
    end
end
if os.getenv("SIM_DBG") then
    opts.after_load = function(sim, w)
        sim.Parry.DBG.on = true
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
        ping_bias = p.ping_bias, frame_jitter = 0.1, log = os.getenv("SIM_LOG") ~= nil, deferred = p.deferred, wlog = os.getenv("SIM_WLOG") ~= nil, perfect_bots = true }
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
        buf_true = w.cfg.buffer, buf_est = w.sim and w.sim.Parry.__Pred and w.sim.Parry.__Pred.buf, buf_n = w.sim and w.sim.Parry.__Pred and w.sim.Parry.__Pred.buf_n }
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
    return { rtt = p.rtt, out = (w.stats.deaths > 0) and ("dead:" .. (w.last_death.reason or "?")) or "survived",
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
    return { rtt = p.rtt, deaths = deaths, passes = w.stats.passes, hits = w.stats.my_hits, wasted = w.stats.wasted,
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

---------------------------------------------------------------- report
local function bucket(r) return math.floor(r.rtt * 1000 + 0.5) end
local results = {}
local t0 = os.clock()
local runner = ({ pass = run_pass, rally = run_rally, ffa = run_ffa, smoke = run_pass, session = run_session })[suite]
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
local csv = os.getenv("SIM_CSV")
if csv then
    local f = assert(io.open(csv, "w"))
    f:write("i,seed,rtt,fps,law,speed,dist,curve,out,hits,wasted,flight\n")
    for _, r in ipairs(results) do
        f:write(("%d,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s\n"):format(r.i, r.seed, bucket(r), r.fps or 0, tostring(r.law), tostring(r.speed),
            tostring(r.dist), tostring(r.curve), tostring(r.out or r.deaths), tostring(r.hits or ""), tostring(r.wasted or ""),
            r.flight and ("%.4f"):format(r.flight) or ""))
    end
    f:close()
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
            suite == "rally" and ("  avg hits %.1f"):format(B.hits / math.max(B.n, 1)) or "",
            table.concat(rs, ", "), med and ("  window used med %.0fms"):format(med * 1000) or ""))
        tot_n, tot_ok = tot_n + B.n, tot_ok + B.ok
    end
end
if suite ~= "ffa" then print(("total %.1f%% (%d/%d)"):format(tot_ok / math.max(tot_n, 1) * 100, tot_ok, tot_n)) end

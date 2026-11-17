-- Capture key test: runs the script's real namecall hook against a fake PRY sender that reads the
-- server clock, encodes the token, then fires the remote a moment later (sometimes across a 10ms
-- tick, as on a slow executor). Counts captures whose key is wrong (= "animation, no parry").
--   luajit Tools/ParrySim/capture_test.lua <script.lua> [trials]
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/?.lua;" .. package.path
local M = require("mock")
local World = require("world")
local v3 = M.v3

local script, trials = arg[1] or "Games/BladeBallRewrite.lua", tonumber(arg[2] or "200")
local f = assert(io.open(script, "rb"))
local src = f:read("*a")
f:close()
src = src:gsub("if getgenv%(%)%.BBStop == 1 then",
    "getgenv().__SIM = { Parry = Parry, Engine = Engine, Util = Util, Anim = Anim }; if getgenv().BBStop == 1 then", 1)
src = src:gsub("function Parry%.isMe%(name%) return name == me end",
    "function Parry.isMe(name) return name == me end\n    Parry.__Core = Core", 1)
local chunk = assert(loadstring(src, "=" .. script))

local HASH, BASE = "5455ef47-de02-4074-808c-8d82c2cd12ec", 1794007603
local bad, exact, got, crossed = 0, 0, 0, 0
local paths = { nc = 0, plain = 0 }
for trial = 1, trials do
    local w = World.new({ seed = trial, rtt = 0.08, jitter = 0.005, fps = 60, buffer = 0.06, W = 0.5, cooldown = 1.3,
        kill_dist = 3.5, homing = { law = "prop", k = { 5, 5 } } })
    w:init_common()
    w:build_game()
    w.me_base = v3(0, 3, 0)
    w:add_player("Me", w.me_base, true)
    w:add_player("Bot", v3(40, 3, 0), false)
    w:spawn_ball()
    local nc_hook, fire_hook, method = nil, nil, nil
    local function dispatch(self, ...)
        if method == "GetServerTimeNow" then return BASE + M.now end
        return nil
    end
    local orig_make = w.make_env
    w.make_env = function(self2, genv)
        local env = orig_make(self2, genv)
        env.hookmetamethod = function(_, name, fn) if name == "__namecall" then nc_hook = fn end; return dispatch end
        env.getnamecallmethod = function() return method end
        env.hookfunction = function(fn, body) fire_hook = body; return function() end end
        env.newcclosure = function(fn) return fn end
        env.getrawmetatable = function() return {} end
        env.setreadonly = function() end
        return env
    end
    w.scenario = { choose_target = function() return nil end, choose_curve = function() return "straight" end,
        next_speed = function(_, s) return s end }
    w:load_script(chunk, { mode = "Remote", inject_cap = false })
    w:run(0.2)
    local core = w.sim.Parry.__Core
    if not nc_hook then error("the script did not install its namecall hook") end
    local keystr = ""
    for i = 1, 16 do keystr = keystr .. string.char(33 + math.floor(w.rng() * 90)) end
    local remote = M.remote("RE/real", w.game:GetService("ReplicatedStorage"))
    local phase = w.rng() * 0.01
    M.now = math.floor((M.now + 1) * 100) / 100 + phase
    local delay = w.rng() < 0.5 and w.rng() * 0.0004 or w.rng() * 0.004
    method = "GetServerTimeNow"
    local t = nc_hook(w.ws)
    local text = tostring(math.floor(t * 100))
    local tok = {}
    for i = 1, #text do
        local k = string.byte(keystr, (i - 1) % #keystr + 1)
        tok[i] = string.char(M.bit32.bxor((string.byte(text, i) + i) % 256, k))
    end
    M.now = M.now + delay
    if math.floor((BASE + M.now) * 100) ~= math.floor(t * 100) then crossed = crossed + 1 end
    local plain = fire_hook and w.rng() < 0.5
    if plain then
        method = nil
        fire_hook(remote, HASH, "uid-1", table.concat(tok), 0.5, M.CFrame.new(0, 0, 0), {}, { 400, 300 }, false)
        paths.plain = paths.plain + 1
    else
        method = "FireServer"
        nc_hook(remote, HASH, "uid-1", table.concat(tok), 0.5, M.CFrame.new(0, 0, 0), {}, { 400, 300 }, false)
        paths.nc = paths.nc + 1
    end
    method = nil
    w:run(0.1)
    local cap = core.cap
    if cap then
        got = got + 1
        if cap.exact then exact = exact + 1 end
        local ok = true
        for i = 1, #text do if cap.key[i] ~= string.byte(keystr, (i - 1) % #keystr + 1) then ok = false end end
        if not ok then bad = bad + 1 end
    end
end
for _, msg in pairs(M.errors) do io.stderr:write("[script error] " .. msg .. "\n") end
print(("%s: %d captures of %d (%d namecall, %d plain FireServer), %d crossed a clock tick, %d exact keys, %d WRONG keys (animation, no parry)"):format(
    script, got, trials, paths.nc, paths.plain, crossed, exact, bad))

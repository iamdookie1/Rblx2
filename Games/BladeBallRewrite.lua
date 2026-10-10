-- Blade Ball -- clean rewrite (work in progress)
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else -- no game remotes, no
--   RunService connections, no hooks, no module requires, no remote-folder
--   resolve. Every feature acquires its connections/hooks only when turned ON
--   (Feature:start) and releases them fully when OFF (Feature:stop). All
--   features off == UI-only footprint, which the anti-cheat does not kick.
--
-- Installment 1: foundation + feature framework + Auto Jump.
-- Installment 2: parry capture core (hooks/packet crypto), gated.
-- Installment 3 (this file): anti-curve prediction, target modes, AP settings,
--   and built-in instant retarget -- auto parry reacts the instant a ball's
--   target flips to you (off the attribute signal, as fast as the retarget
--   itself), not on the next frame. Still to come: pre-parry, curve modes,
--   detection pauses, spam/triggerbot, skins, ESP, overlays.

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.3"

-- ---------------------------------------------------------------------------
-- Single instance.
-- ---------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
genv.__BladeBallInstance = INSTANCE
local function is_live() return genv.__BladeBallInstance == INSTANCE end

-- ---------------------------------------------------------------------------
-- Services (references only).
-- ---------------------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService('Players'))
local RunService = cloneref(game:GetService('RunService'))
local UserInputService = cloneref(game:GetService('UserInputService'))
local ReplicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local Workspace = cloneref(game:GetService('Workspace'))
local Stats = cloneref(game:GetService('Stats'))
local CollectionService = cloneref(game:GetService('CollectionService'))
local VirtualInputManager = cloneref(game:GetService('VirtualInputManager'))
local LocalPlayer = Players.LocalPlayer
local clock_ = os.clock
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- ---------------------------------------------------------------------------
-- Feature framework.
-- ---------------------------------------------------------------------------
local Features = {}
local function Feature(name)
    local f = { name = name, on = false, _conns = {} }
    function f:connect(signal, fn)
        local c = signal:Connect(function(...)
            if not is_live() then return end
            fn(...)
        end)
        self._conns[#self._conns + 1] = c
        return c
    end
    function f:release()
        for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
        self._conns = {}
    end
    function f:setEnabled(v)
        v = v and true or false
        if v == self.on then return end
        self.on = v
        if v then if self.start then self.start() end
        else if self.stop then self.stop() end; self:release() end
    end
    Features[name] = f
    return f
end

-- ===========================================================================
-- PARRY CORE (defines only; touches the game only via activate()/arm())
-- ===========================================================================
local Parry = {}
do
    local me = LocalPlayer.Name
    local Core = { cap = nil, pending = nil, misses = 0, interp = 0.14, last_parry = nil }
    Parry.Core = Core
    local G = { until_t = 0, m1 = false, m1_at = 0 }
    local frame_dt = 1 / 60
    local active = false
    local Alive, Remotes

    -- settings (exposed to the UI as Parry.S)
    local TARGET_NAMES = { 'Cursor', 'Camera', 'Closest', 'Farthest', 'Random' }
    local S = {
        accuracy = 50, accuracy_base = 50, divisor_multiplier = 1.1, timing_mult = 1,
        extra_distance = 0, ping_compensation = false, retry_delay = 1,
        random_accuracy = false, random_accuracy_amount = 10,
        target_mode = 1, instant = true,
    }
    Parry.S = S
    Parry.targetNames = TARGET_NAMES
    local function update_divisor() S.divisor_multiplier = 0.7 + (S.accuracy - 1) * (0.9 / 99) end
    local function roll_accuracy()
        local acc = S.accuracy_base
        if S.random_accuracy and S.random_accuracy_amount > 0 then
            acc = acc + math.random(-S.random_accuracy_amount, S.random_accuracy_amount)
        end
        S.accuracy = math.clamp(acc, 1, 100)
        update_divisor()
    end
    Parry.roll = roll_accuracy
    update_divisor()
    function Parry.setTargetMode(name)
        for i, n in ipairs(TARGET_NAMES) do if n == name then S.target_mode = i; return end end
    end

    -- ---------- ping / lag ----------
    local ping_cache = { at = -1, ms = 0 }
    local function getPing()
        local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
        return ok and ping or 0
    end
    local function pingMs()
        local now = clock_()
        if now - ping_cache.at > 0.05 then ping_cache.ms = getPing(); ping_cache.at = now end
        return ping_cache.ms
    end
    local function ping_s() return math.min(pingMs(), 400) / 1000 end
    local Lag = { avg = nil, jit = 0.01, at = -1 }
    local function sample_lag()
        local now = clock_()
        if now - Lag.at < 0.1 then return end
        Lag.at = now
        local p = ping_s()
        if not Lag.avg then Lag.avg = p; return end
        Lag.jit = Lag.jit + (math.abs(p - Lag.avg) - Lag.jit) * 0.15
        Lag.avg = Lag.avg + (p - Lag.avg) * 0.3
    end
    local function jitter() return math.clamp(Lag.jit * 2, 0.005, 0.12) end
    local function reach_time()
        sample_lag()
        local ping = math.max(Lag.avg or ping_s(), ping_s())
        local ping_term = S.ping_compensation and ping or ping * 0.5
        return ping_term + jitter() + Core.interp + frame_dt * 0.5
    end

    local function getRoot()
        local char = LocalPlayer.Character
        return char and char.PrimaryPart
    end

    -- ---------- client parry gate ----------
    local function canParryNow()
        local char = LocalPlayer.Character
        if not char then return false end
        if char:GetAttribute("Stunned") then return false end
        if char:GetAttribute("DoNotParry") then return false end
        if char:GetAttribute("ChargingAdrenaline") then
            local ok, qi = pcall(function() return LocalPlayer.Upgrades["Qi-Charge"].Value end)
            if ok and type(qi) == "number" and qi < 2 then return false end
        end
        if char.Parent == Alive then return true end
        if LocalPlayer:GetAttribute("LobbyParry") then
            return not LocalPlayer:GetAttribute("InLobbyParryCooldown")
        end
        if LocalPlayer:GetAttribute("LobbyTraining") then
            local Dead = Workspace:FindFirstChild("Dead")
            if Dead and char.Parent == Dead then return true end
        end
        return false
    end
    local function in_match()
        local char = LocalPlayer.Character
        return char ~= nil and char.Parent == Alive
    end
    local function ap_root()
        local root = getRoot()
        if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
        return root
    end

    -- ---------- window / gate ----------
    local function parry_window()
        local cw = Core.cap and Core.cap.win
        if cw and cw > 0 then return cw, 1.3 * math.min(cw / 0.5, 1) end
        return 0.5, 1.3
    end
    local function lockout_margin() return math.clamp(0.02 + frame_dt + 0.03, 0.06, 0.15) end
    local function gate_start(why)
        local now = clock_()
        if now < G.until_t then return end
        local n6, n2 = parry_window()
        G.until_t = now + math.max((n6 or 0.5) + 0.1, n2 or 1.3) + lockout_margin()
        G.started_at, G.started_by = now, why or "parry"
    end
    local function gate_open()
        if G.m1 and clock_() - G.m1_at < 3 then return false end
        return clock_() >= G.until_t
    end
    Core.gate_start, Core.gate_open = gate_start, gate_open

    -- ---------- screen points / aim / target ----------
    local function build_screen_points(cam)
        local points, others = {}, {}
        local char = LocalPlayer.Character
        local function add(name, pos)
            local screen = cam:WorldToScreenPoint(pos)
            points[name] = screen
            if not (char and name == char.Name) then
                others[#others + 1] = { name = name, pos = pos, screen = screen }
            end
        end
        local dead = Workspace:FindFirstChild('Dead')
        if dead and char and char.Parent == dead and LocalPlayer:GetAttribute('LobbyTraining') then
            for _, other in ipairs(dead:GetChildren()) do
                local plr = Players:GetPlayerFromCharacter(other)
                local hrp = other:FindFirstChild('HumanoidRootPart')
                if plr and hrp and plr:GetAttribute('LobbyTraining') then add(other.Name, hrp.Position) end
            end
            for _, dummy in ipairs(CollectionService:GetTagged('LobbyTrainingTarget')) do
                if dummy:IsA('BasePart') then add(dummy.Name, dummy.Position) end
            end
        else
            local mode = Workspace:GetAttribute("CurrentlySelectedMode")
            if mode == "Hovergoal" or mode == "Soccer" then
                pcall(function()
                    local team = LocalPlayer:GetAttribute("Team") or (char and char:GetAttribute("Team"))
                    if team == nil and LocalPlayer.Team then team = tonumber(LocalPlayer.Team.Name:match("%d+")) end
                    team = tonumber(team)
                    local want = team and ("Goal%s"):format(tostring(team == 1 and 2 or 1))
                    local root = char and char.PrimaryPart
                    local best, best_d
                    for _, goal in ipairs(CollectionService:GetTagged("HovergoalGoal")) do
                        local t = goal:FindFirstChild("Target")
                        if t then
                            if want then if goal.Name == want then best = goal; break end
                            elseif root then
                                local d = (t.Position - root.Position).Magnitude
                                if not best_d or d > best_d then best, best_d = goal, d end
                            end
                        end
                    end
                    if best then add(best.Name, best.Target.Position) end
                end)
                for _, entity in ipairs(Alive:GetChildren()) do
                    local hrp = entity:FindFirstChild('HumanoidRootPart')
                    if hrp and entity:GetAttribute("IsTheRisingZombie") then add(entity.Name, hrp.Position) end
                end
            else
                for _, entity in ipairs(Alive:GetChildren()) do
                    local hrp = entity:FindFirstChild('HumanoidRootPart')
                    if hrp then add(entity.Name, hrp.Position) end
                end
            end
        end
        return points, others
    end
    local function aim_point(cam)
        local ok, mouse = pcall(UserInputService.GetMouseLocation, UserInputService)
        if ok and mouse then return { mouse.X, mouse.Y } end
        local vp = cam.ViewportSize
        return { vp.X / 2, vp.Y / 2 }
    end
    local PACKET_TTL = 1 / 240
    local packet_cache = { at = -1, points = nil, aim = nil, others = nil }
    local function packet_parts(cam)
        local now = clock_()
        if now - packet_cache.at > PACKET_TTL then
            packet_cache.points, packet_cache.others = build_screen_points(cam)
            packet_cache.aim = aim_point(cam)
            packet_cache.at = now
        end
        return packet_cache.points, packet_cache.aim, packet_cache.others
    end

    -- target modes: who the parry aims at (the server gives the ball to whoever's
    -- screen point is nearest the aim point). Held 0.1s so one parry is coherent.
    local target_hold = { at = -1, mode = nil, name = nil, pos = nil }
    local function choose_target(cam)
        cam = cam or Workspace.CurrentCamera
        local mode = TARGET_NAMES[S.target_mode] or "Cursor"
        local now = clock_()
        if target_hold.mode == mode and now - target_hold.at < 0.1 then
            return target_hold.name, target_hold.pos, mode
        end
        local _, _, others = packet_parts(cam)
        local root = getRoot()
        local origin = root and root.Position or cam.CFrame.Position
        local name, pos
        if others and #others > 0 then
            if mode == "Random" then
                local t = others[math.random(1, #others)]; name, pos = t.name, t.pos
            elseif mode == "Closest" or mode == "Farthest" then
                local best = (mode == "Closest") and math.huge or -1
                for _, t in ipairs(others) do
                    local d = (t.pos - origin).Magnitude
                    if (mode == "Closest" and d < best) or (mode == "Farthest" and d > best) then
                        best, name, pos = d, t.name, t.pos
                    end
                end
            else
                local vp = cam.ViewportSize
                local anchor = Vector2.new(vp.X / 2, vp.Y / 2)
                if mode == "Cursor" and not isMobile then
                    local ok, m = pcall(UserInputService.GetMouseLocation, UserInputService)
                    if ok and m then anchor = m end
                end
                local best = math.huge
                for _, t in ipairs(others) do
                    local s = t.screen
                    if s.Z > 0 and s.X >= 0 and s.Y >= 0 and s.X <= vp.X and s.Y <= vp.Y then
                        local d = (Vector2.new(s.X, s.Y) - anchor).Magnitude
                        if d < best then best, name, pos = d, t.name, t.pos end
                    end
                end
                if not name then
                    best = math.huge
                    for _, t in ipairs(others) do
                        local d = (t.pos - origin).Magnitude
                        if d < best then best, name, pos = d, t.name, t.pos end
                    end
                end
            end
        end
        target_hold.at, target_hold.mode, target_hold.name, target_hold.pos = now, mode, name, pos
        return name, pos, mode
    end

    -- ---------- capture hook (ported verbatim; see installment 2) ----------
    local hookfunction_, restore_ = hookfunction, restorefunction
    local hookmetamethod_, getnamecallmethod_ = hookmetamethod, getnamecallmethod
    local getrawmetatable_ = getrawmetatable
    local setreadonly_ = setreadonly or (make_writeable)
    local newcclosure_ = newcclosure or function(f) return f end
    local select_, pcall_ = select, pcall
    local oth_lib = rawget(getgenv(), "oth"); if type(oth_lib) ~= 'table' then pcall(function() oth_lib = oth end) end
    local oth_hook = type(oth_lib) == 'table' and type(oth_lib.hook) == 'function' and oth_lib.hook or nil
    local oth_unhook = type(oth_lib) == 'table' and type(oth_lib.unhook) == 'function' and oth_lib.unhook or nil
    local FIRE_FN
    local box = { want = false, nc = nil, fire = nil, list = {}, ws = Workspace, now = Workspace.GetServerTimeNow,
        me = "ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net" }
    local HOOK_NAME = "=ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net"
    local NC_SRC = [[
local box, getncm, sel, pc, err, info, typ, find = ...
local function pass(ok, ...)
    if ok then return ... end
    local e = ...
    if typ(e) == "string" and not find(e, "^[^\n]-:%d+: ") then
        for lvl = 2, 12 do
            local src, line = info(lvl, "sl")
            if src == nil then break end
            if src ~= "[C]" and src ~= box.me and line and line > 0 then
                e = src .. ":" .. line .. ": " .. e
                break
            end
        end
    end
    return err(e, 0)
end
return function(self, ...)
    local l = box.list
    if box.want and #l < 4 and getncm() == "FireServer" and sel("#", ...) >= 6 then
        l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)}
    end
    return pass(pc(box.nc, self, ...))
end]]
    local FIRE_SRC = [[
local box, sel = ...
return function(self, ...)
    local l = box.list
    if box.want and #l < 4 and sel("#", ...) >= 6 then
        l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)}
    end
    return box.fire(self, ...)
end]]
    local CLEAN_ENV = {}
    local function build_body(src, ...)
        local args = table.pack(...)
        local ok, fn = pcall(function()
            local factory = loadstring(src, HOOK_NAME)
            if setfenv then setfenv(factory, CLEAN_ENV) end
            return factory(table.unpack(args, 1, args.n))
        end)
        return ok and type(fn) == 'function' and fn or nil
    end
    local NC_BODY = build_body(NC_SRC, box, getnamecallmethod_ or function() return nil end, select,
        pcall, error, debug.info, type, string.find)
    local FIRE_BODY = build_body(FIRE_SRC, box, select)
    if not NC_BODY then
        NC_BODY = function(self, ...)
            local l = box.list
            if box.want and #l < 4 and getnamecallmethod_() == "FireServer" and select_("#", ...) >= 6 then
                l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws) }
            end
            return box.nc(self, ...)
        end
    end
    if not FIRE_BODY then
        FIRE_BODY = function(self, ...)
            local l = box.list
            if box.want and #l < 4 and select_("#", ...) >= 6 then
                l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws) }
            end
            return box.fire(self, ...)
        end
    end
    local H = { fire = nil, nc = nil, want = false, until_t = 0, oth = false, oth_kept = nil }
    local function capture_method()
        local m = getgenv().CaptureHook or "oth"
        if m == "oth" and not (oth_hook and FIRE_FN) then m = "Namecall" end
        return m
    end
    local function restore_namecall(original)
        local ok = pcall_(function()
            local mt = getrawmetatable_(game)
            local was_ro = isreadonly and isreadonly(mt)
            setreadonly_(mt, false)
            rawset(mt, "__namecall", original)
            if was_ro ~= false then setreadonly_(mt, true) end
        end)
        if not ok then pcall_(hookmetamethod_, game, "__namecall", original) end
    end
    local function unhook()
        local fire, nc, was_oth = H.fire, H.nc, H.oth
        H.fire, H.nc, H.want, box.want, H.oth = nil, nil, false, false, false
        if fire and was_oth then
            if not (oth_unhook and pcall_(oth_unhook, FIRE_FN)) then H.oth_kept = fire end
        elseif fire and not (restore_ and pcall_(restore_, FIRE_FN)) then pcall_(hookfunction_, FIRE_FN, fire) end
        if nc then restore_namecall(nc) end
        box.nc = nil
        if not H.oth_kept then box.fire = nil end
    end
    Parry.unhook = unhook
    local JOB_ID = game.JobId
    local function learn(remote, hash, uid, token, a4, t)
        local text = tostring(math.floor(t * 100))
        if #token ~= #text then return end
        local key = {}
        for i = 1, #text do key[i] = bit32.bxor(string.byte(token, i), (string.byte(text, i) + i) % 256) end
        Core.cap = { remote = remote, hash = hash, uid = uid, key = key, len = #text,
            ball2 = typeof(a4) == "CFrame", win = type(a4) == "number" and a4 or nil }
        Core.misses, Core.pending = 0, nil
    end
    local function inspect(entry)
        local self, a = entry[1], entry[3]
        local a1, a2, a3, a4, a5 = a[1], a[2], a[3], a[4], a[5]
        if typeof(self) == 'Instance' and self.ClassName == 'RemoteEvent'
            and type(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type(a2) == 'string' and type(a3) == 'string'
            and ((type(a4) == 'number' and typeof(a5) == 'CFrame') or (typeof(a4) == 'CFrame' and typeof(a5) == 'CFrame')) then
            learn(self, a1, a2, a3, a4, entry[4])
            return true
        end
    end
    local function arm()
        if Core.cap or not is_live() then return false end
        H.want, H.until_t = true, clock_() + 0.35
        if H.fire or H.nc then return true end
        box.list = {}
        local method = capture_method()
        if method == "oth" or (method == "Both" and oth_hook and FIRE_FN) then
            if H.oth_kept then
                H.fire, box.fire, H.oth = H.oth_kept, H.oth_kept, true
            else
                local ok, old = pcall(oth_hook, FIRE_FN, FIRE_BODY)
                if ok and type(old) == 'function' then H.fire, box.fire, H.oth = old, old, true end
            end
        elseif method ~= "Namecall" and hookfunction_ and FIRE_FN then
            local ok, old = pcall(hookfunction_, FIRE_FN, newcclosure_(FIRE_BODY))
            if ok and type(old) == 'function' then H.fire, box.fire = old, old end
        end
        if (method == "Namecall" or method == "Both") and hookmetamethod_ and getnamecallmethod_ then
            local ok, old = pcall(hookmetamethod_, game, "__namecall", newcclosure_(NC_BODY))
            if ok and type(old) == 'function' then H.nc, box.nc = old, old end
        end
        if not (H.fire or H.nc) then H.want = false; return false end
        box.want = true
        task.spawn(function()
            while (H.fire or H.nc) and clock_() < H.until_t do
                task.wait()
                local l = box.list
                for i = 1, #l do if pcall_(inspect, l[i]) and Core.cap then break end end
                if Core.cap then break end
            end
            unhook()
            box.list = {}
        end)
        return true
    end
    local last_press = 0
    local function pressBlockKey()
        if not is_live() then return false end
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        end)
        return true
    end
    local can_since, dry_presses = nil, 0
    local function prime_remote()
        if Core.cap or not is_live() then return end
        if not in_match() or not canParryNow() then can_since = nil; return end
        local now = clock_()
        can_since = can_since or now
        if now - can_since < 1 then return end
        if now - last_press < 1.4 then return end
        if dry_presses >= 3 then
            if now - last_press < 20 then return end
            dry_presses = 0
        end
        last_press = now
        if arm() then dry_presses = dry_presses + 1; pressBlockKey(); gate_start("capture press") end
    end

    -- ---------- token + send ----------
    local tok_cache = { cap = nil, text = nil, tok = nil }
    local function make_token(cap)
        local text = tostring(math.floor(Workspace:GetServerTimeNow() * 100))
        local c = tok_cache
        if c.cap == cap and c.text == text then return c.tok end
        if #text ~= cap.len then return nil end
        local out = table.create(#text)
        for i = 1, #text do out[i] = string.char(bit32.bxor((string.byte(text, i) + i) % 256, cap.key[i])) end
        c.cap, c.text, c.tok = cap, text, table.concat(out)
        return c.tok
    end
    local function send(spam)
        if not is_live() then return "blocked" end
        local cap = Core.cap
        if not cap then return "unarmed" end
        if not canParryNow() then return "blocked" end
        if not cap.remote.Parent then Core.cap = nil; return "unarmed" end
        if not spam and not gate_open() then return "blocked" end
        local window = parry_window()
        local tok = make_token(cap)
        if not tok then Core.cap = nil; return "unarmed" end
        local cam = Workspace.CurrentCamera
        local points, aim = packet_parts(cam)
        -- aim at the chosen target's screen point for every mode but Cursor
        local name, _, mode = choose_target(cam)
        if name and mode ~= "Cursor" then
            local screen = points[name]
            if screen then aim = { screen.X, screen.Y } end
        end
        local cf = cam.CFrame
        if not spam then gate_start() end
        local r = cap.remote
        if cap.ball2 then
            local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
            r:FireServer(cap.hash, cap.uid, tok, cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
        else
            r:FireServer(cap.hash, cap.uid, tok, window, cf, points, aim, false)
        end
        if not spam then Core.pending = clock_() + window + ping_s() + 0.25 end
        return "sent"
    end
    Parry.send = send

    -- ---------- parry distance / lead ----------
    local function parry_distance(speed)
        local ping_ms = pingMs()
        local ping_threshold = math.clamp(ping_ms / 100, 5, 17)
        local capped = math.min(math.max(speed - 9.5, 0), 650)
        local divisor = (2.4 + capped * 0.002) * (S.divisor_multiplier or 1.1)
        local distance = ping_threshold + math.max(speed / divisor, 9.5)
        if S.ping_compensation then distance = distance + speed * (ping_ms / 1000) * 0.5 end
        distance = distance * (0.5 + 0.5 * math.clamp(S.timing_mult or 1, 0, 2))
        return distance + (S.extra_distance or 0)
    end

    -- ---------- ball tracking + prediction ----------
    local tracked = setmetatable({}, { __mode = 'k' })
    local ball_conns = {} -- per-ball target listeners, dropped on deactivate
    local function ball_velocity(ball)
        local z = ball:FindFirstChild('zoomies')
        return z and z.VectorVelocity or ball.AssemblyLinearVelocity
    end
    local function read_ball(ball, root)
        local velocity = ball_velocity(ball)
        local speed = velocity.Magnitude
        local offset = root.Position - ball.Position
        local distance = offset.Magnitude
        if speed < 1 or distance < 0.01 then return 0, speed, distance, velocity end
        local heading = (velocity / speed):Dot(offset / distance)
        return heading, speed, distance, velocity
    end
    local function arc_time(distance, theta, speed, acc)
        local k = theta < 1e-3 and 1 or math.min(theta / math.sin(math.min(theta, 3.0)), 8)
        local path = distance * k
        if acc and acc > 1 then return (math.sqrt(speed * speed + 2 * acc * path) - speed) / acc end
        return path / speed
    end
    local function speed_trend(st, speed, now)
        local s = st.spd_s
        if not s then st.spd_s = { t = now, v = speed, acc = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.05 then
            local a = (speed - s.v) / dt
            s.acc = math.clamp(s.acc * 0.5 + a * 0.5, 0, 600)
            s.t, s.v = now, speed
        end
        return s.acc
    end
    local function angle_trend(st, theta, now)
        local s = st.ang
        if not s then st.ang = { t = now, v = theta, rate = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.05 then
            local rate = (theta - s.v) / dt
            s.rate = s.rate * 0.4 + rate * 0.6
            s.t, s.v = now, theta
        end
        return s.rate
    end
    local live_cache = { at = -1, list = {} }
    local function get_live_balls()
        local now = clock_()
        if now - live_cache.at < 1 / 240 then return live_cache.list end
        local list = {}
        for _, name in ipairs({ "Balls", "TrainingBalls" }) do
            local folder = Workspace:FindFirstChild(name)
            if folder then
                for _, ball in ipairs(folder:GetChildren()) do
                    if ball:GetAttribute('realBall') then list[#list + 1] = ball end
                end
            end
        end
        live_cache.list, live_cache.at = list, now
        return list
    end

    -- one parry per pass (per target change); retry after the lockout
    local function mark_parried(st, now)
        local _, n2 = parry_window()
        local wait = math.max(math.clamp(S.retry_delay or 1, 0.2, 1.5), (n2 or 1.3) + 0.08)
        st.parried, st.parry_until = true, now + wait
    end
    local function pass_busy(st, now)
        if st.landed then return true end
        if st.parried then
            if now < st.parry_until then return true end
            st.parried = false
        end
        return false
    end
    local function fire(st, now, via, info)
        if send(false) ~= "sent" then return false end
        Core.last_parry = { t = now, via = via, info = info }
        mark_parried(st, now)
        return true
    end

    -- the decision for a ball on us. via "retarget" is the instant it turns to us.
    local function decide(ball, st, root, now, via)
        if pass_busy(st, now) then return end
        local heading, speed, distance = read_ball(ball, root)
        if speed < 1 then return end
        local range = parry_distance(speed)
        local lead = range / speed
        local W = parry_window() or 0.5
        local latest = reach_time() + W * 0.7
        if lead > latest then lead, range = latest, latest * speed end
        local theta = math.acos(math.clamp(heading, -1, 1))
        local opening = angle_trend(st, theta, now)
        local info = { speed = speed, dist = distance, heading = heading, lead = lead }
        local point_blank = distance <= math.max(10, speed * 0.12)

        if via == "retarget" then
            -- the ball just turned to us: its new direction isn't in yet, but it
            -- homes straight in at (at least) this speed. Fire now only if that
            -- lands within our lead and it's heading in (or point blank); else let
            -- the per-frame path pick it up when it genuinely arrives.
            local eta = distance / speed * (heading < 0 and 1.2 or 1)
            info.eta = eta
            if eta <= lead and (heading >= 0 or point_blank) then
                return fire(st, now, "instant retarget", info)
            end
            return
        end

        if not point_blank and theta > 0.35 and opening > 0.6 then return end -- curving away: wait
        local eta = arc_time(distance, theta, speed, speed_trend(st, speed, now))
        info.eta = eta
        if point_blank or eta <= lead then return fire(st, now, "auto parry", info) end
    end
    Parry.decide = decide

    local function open_pass(st, now)
        st.pass_open, st.parried, st.landed, st.parry_until = true, false, false, 0
        st.spd_s, st.ang = nil, nil
        if S.random_accuracy then roll_accuracy() end
    end
    local function get_ball_state(ball)
        local st = tracked[ball]
        if st then return st end
        st = { target = ball:GetAttribute('target'), parried = false, parry_until = 0,
            pass_open = false, landed = false }
        tracked[ball] = st
        if st.target == me then open_pass(st, clock_()) end
        ball_conns[#ball_conns + 1] = ball:GetAttributeChangedSignal('target'):Connect(function()
            if not is_live() then return end
            local new = ball:GetAttribute('target')
            st.target = new
            if type(new) == 'string' and new ~= '' and new ~= me then
                st.pass_open, st.parried, st.landed = false, false, false
            end
            if new == me and not st.pass_open then
                open_pass(st, clock_())
                -- BUILT-IN INSTANT RETARGET: react the instant the attribute flips,
                -- straight off the signal -- not on the next frame. Always on.
                if active and S.instant then
                    local root = ap_root()
                    if root then decide(ball, st, root, clock_(), "retarget") end
                end
            end
        end)
        return st
    end

    -- the per-frame step (prime until captured, then decide on the ball on us)
    local function step(dt)
        if dt then frame_dt = math.clamp(dt, 1 / 240, 0.1) end
        if not is_live() then return end
        if not Core.cap then prime_remote() end
        local root = ap_root()
        if not root then return end
        local now = clock_()
        for _, ball in ipairs(get_live_balls()) do
            local st = get_ball_state(ball)
            if st.target == me then decide(ball, st, root, now) end
        end
    end
    Parry.step = step

    -- ---------- activate / deactivate (only game-touching entry points) ----------
    function Parry.activate()
        Alive = Alive or Workspace:FindFirstChild("Alive") or Workspace:WaitForChild("Alive", 5)
        Remotes = Remotes or ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 5)
        if type(FIRE_FN) ~= 'function' and Remotes then
            pcall(function() FIRE_FN = Remotes:FindFirstChild("ParrySuccess") and Remotes.ParrySuccess.FireServer end)
            if type(FIRE_FN) ~= 'function' then
                pcall(function()
                    for _, d in ipairs(Remotes:GetDescendants()) do
                        if d:IsA("RemoteEvent") then FIRE_FN = d.FireServer; break end
                    end
                end)
            end
        end
        active = Remotes ~= nil
        return active
    end
    function Parry.deactivate()
        active = false
        pcall(unhook)
        -- drop every per-ball target listener and forget tracked balls, so turning
        -- Auto Parry off leaves zero game connections (the inert contract).
        for _, c in ipairs(ball_conns) do pcall(function() c:Disconnect() end) end
        ball_conns = {}
        for k in pairs(tracked) do tracked[k] = nil end
        Core.cap, Core.pending, Core.misses = nil, nil, 0
        G.until_t, can_since, dry_presses = 0, nil, 0
    end
    function Parry.remotes() return Remotes end
    Parry.onParrySuccess = function()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.until_t = 0
        local lp = Core.last_parry
        if Core.pending and lp and lp.info and lp.info.eta then
            local took = clock_() - lp.t
            if lp.info.eta < 0.9 and took < 1 then
                Core.interp = math.clamp(Core.interp * 0.7 + (lp.info.eta - took) * 0.3, 0.02, 0.3)
            end
        end
        Core.pending, Core.misses = nil, 0
        for _, st in pairs(tracked) do
            if st.target == me and st.pass_open then st.landed = true end
        end
    end
    Parry.onM1Stop = function(v) G.m1, G.m1_at = v and true or false, clock_() end
end

-- ---------------------------------------------------------------------------
-- UI.
-- ---------------------------------------------------------------------------
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options, Toggles = Library.Options, Library.Toggles

local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "version: " .. SCRIPT_VERSION,
    Icon = "swords",
    Center = true,
    AutoShow = true,
    Resizable = true,
    ToggleKeybind = Enum.KeyCode.LeftControl,
})

local Tabs = {
    Parry = Window:AddTab("Auto Parry", "swords", "Remote auto parry"),
    Player = Window:AddTab("Player", "user", "Movement and avatar"),
    Status = Window:AddTab("Status", "gauge", "Build info and live state"),
}

local StatusBox = Tabs.Status:AddLeftGroupbox("Build", "info")
StatusBox:AddLabel("Version: " .. SCRIPT_VERSION)
StatusBox:AddLabel("Idle = nothing connected. Features connect only when on.")

-- ---------------------------------------------------------------------------
-- FEATURE: Auto Parry.
-- ---------------------------------------------------------------------------
local AutoParry = Feature("AutoParry")
function AutoParry.start()
    if not Parry.activate() then
        Library:Notify({ Title = "Blade Ball", Description = "Couldn't find the game's Remotes.", Time = 4 })
        return
    end
    local Remotes = Parry.remotes()
    pcall(function() AutoParry:connect(Remotes.ParrySuccess.OnClientEvent, Parry.onParrySuccess) end)
    pcall(function() AutoParry:connect(Remotes.NoobParryHappened.OnClientEvent, function()
        task.wait(0.11); Parry.onParrySuccess()
    end) end)
    pcall(function() AutoParry:connect(Remotes.M1Stop.Event, Parry.onM1Stop) end)
    AutoParry:connect(RunService.PreSimulation, function(dt) Parry.step(dt) end)
end
function AutoParry.stop() Parry.deactivate() end

local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {
    Text = "Auto parry",
    Default = false,
    Callback = function(v) AutoParry:setEnabled(v) end,
}):AddKeyPicker("AutoParryKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry" })
AP:AddDropdown("TargetMode", {
    Values = Parry.targetNames,
    Default = "Cursor",
    Text = "Target mode",
    Tooltip = "Who the ball is aimed at when parried. Cursor = under your mouse.",
    Callback = function(v) Parry.setTargetMode(v) end,
})
AP:AddDropdown("CaptureHook", {
    Values = { "oth", "Namecall", "FireServer", "Both" },
    Default = "oth",
    Text = "Capture hook",
    Tooltip = "How the first parry packet is captured. 'oth' (Delta) is the stealthiest.",
    Callback = function(v) getgenv().CaptureHook = v end,
})

local APS = Tabs.Parry:AddRightGroupbox("Settings", "sliders-horizontal")
APS:AddSlider("Accuracy", {
    Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "Higher = tighter / later parry; lower = earlier with more cushion.",
    Callback = function(v) Parry.S.accuracy_base = v; Parry.roll() end,
})
APS:AddSlider("TimingMult", {
    Text = "Timing", Default = 1, Min = 0, Max = 2, Rounding = 2,
    Tooltip = "Shifts the parry earlier (toward 2) or later (toward 0) at any accuracy.",
    Callback = function(v) Parry.S.timing_mult = v end,
})
APS:AddSlider("ExtraDistance", {
    Text = "Extra distance", Default = 0, Min = -20, Max = 40, Rounding = 0, Suffix = " studs",
    Callback = function(v) Parry.S.extra_distance = v end,
})
APS:AddSlider("RetryDelay", {
    Text = "Retry delay", Default = 1, Min = 0.2, Max = 1.5, Rounding = 2, Suffix = "s",
    Tooltip = "If the ball is still on you this long after a parry, parry again.",
    Callback = function(v) Parry.S.retry_delay = v end,
})
APS:AddToggle("PingCompensation", {
    Text = "Ping compensation",
    Default = false,
    Tooltip = "Leads further ahead on high ping. Turn on if parries land late.",
    Callback = function(v) Parry.S.ping_compensation = v end,
})
APS:AddToggle("RandomAccuracy", {
    Text = "Randomize accuracy",
    Default = false,
    Callback = function(v) Parry.S.random_accuracy = v end,
})
APS:AddSlider("RandomAccuracyAmount", {
    Text = "Randomize amount", Default = 10, Min = 0, Max = 50, Rounding = 0, Suffix = " +/-",
    Callback = function(v) Parry.S.random_accuracy_amount = v end,
})

-- ---------------------------------------------------------------------------
-- FEATURE: Auto Jump.
-- ---------------------------------------------------------------------------
local AutoJump = Feature("AutoJump")
do
    local lastGrounded = false
    function AutoJump.start()
        lastGrounded = false
        AutoJump:connect(RunService.Heartbeat, function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then return end
            local grounded = hum.FloorMaterial ~= Enum.Material.Air
            if grounded and not lastGrounded then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            lastGrounded = grounded
        end)
    end
end

local MV = Tabs.Player:AddLeftGroupbox("Movement", "footprints")
MV:AddToggle("AutoJump", {
    Text = "Auto jump",
    Default = false,
    Callback = function(v) AutoJump:setEnabled(v) end,
}):AddKeyPicker("AutoJumpKey", { Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump" })

-- ---------------------------------------------------------------------------
-- Unload.
-- ---------------------------------------------------------------------------
Library:OnUnload(function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    pcall(Parry.deactivate)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end)

genv.__BladeBallShutdown = function()
    pcall(Parry.deactivate)
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

Library:Notify({ Title = "Blade Ball", Description = "Rewrite " .. SCRIPT_VERSION .. " loaded. Idle = inert.", Time = 4 })

end)

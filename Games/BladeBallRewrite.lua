-- Blade Ball -- clean rewrite (work in progress)
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else -- no game remotes, no
--   RunService connections, no hooks, no module requires, no remote-folder
--   resolve. One Engine owns every game connection; it starts when the first
--   parry/spam feature is turned on and tears everything down when the last one
--   is turned off. All features off == UI-only footprint.
--
-- Installment 1: foundation + feature framework + Auto Jump.
-- Installment 2: parry capture core (hooks/packet crypto), gated.
-- Installment 3: prediction, target modes, AP settings, instant retarget.
-- Installment 4 (this file):
--   * anti-curve rebuilt on a real homing simulation (the ball is flown forward
--     at the rate it is actually turning and speeding up), a physics danger zone,
--     and the classic distance trigger as a safety net for straight balls
--   * faster retarget: reacts on the target flip, on the ball's velocity update
--     (the instant its new direction replicates), on ball spawn, and at three
--     points per frame
--   * triggerbot, pre-parry, 22 curve modes with next/prev curve keys
--   * Spam tab: manual spam, auto spam with predictive clash detection, settings

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.4"

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
-- Feature framework (for self-contained features like Auto Jump).
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
-- PARRY + SPAM CORE (defines only; touches the game only after activate())
-- ===========================================================================
local Parry = {}
do
    local me = LocalPlayer.Name
    local Core = { cap = nil, pending = nil, misses = 0, interp = 0.14, last_parry = nil }
    local G = { until_t = 0, m1 = false, m1_at = 0 }
    local frame_dt = 1 / 60
    local active = false
    local Alive, Remotes

    local TARGET_NAMES = { 'Cursor', 'Camera', 'Closest', 'Farthest', 'Random' }
    local CURVE_NAMES = { 'Camera', 'Straight', 'Normal', 'Accelerated', 'High', 'Slow', 'Backwards', 'Random',
        'Speed', 'Down', 'Left', 'Right', 'Sky', 'Ground', 'Alternate', 'Random Side', 'Zigzag', 'Spiral',
        'Cursor', 'Flick', 'Diagonal', 'Reverse' }

    -- auto parry / triggerbot settings
    local S = {
        autoparry = false, triggerbot = false,
        preparry = false, preparry_range = 20, hp_preparry = false,
        anticurve = true,
        accuracy = 50, accuracy_base = 50, divisor_multiplier = 1.1, timing_mult = 1,
        extra_distance = 0, ping_compensation = false, retry_delay = 1,
        random_accuracy = false, random_accuracy_amount = 10,
        target_mode = 1, curve_mode = 1,
    }
    -- spam settings
    local SP = {
        manual = false, auto = false, mode = "Remote", max_rate = 1000, upload_kbps = 0, idle_rate = 20,
        range_bonus = 0, hold = 0.15, sensitivity = 1.3, predictive = true,
        factor = 1, guard_at = -1,
    }
    Parry.S, Parry.SP, Parry.targetNames, Parry.curveNames = S, SP, TARGET_NAMES, CURVE_NAMES

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
    local function index_of(list, name)
        for i, n in ipairs(list) do if n == name then return i end end
    end
    function Parry.setTargetMode(name) S.target_mode = index_of(TARGET_NAMES, name) or 1 end
    function Parry.setCurveMode(name) S.curve_mode = index_of(CURVE_NAMES, name) or 1 end

    -- ---------- ping / lag / reach ----------
    local ping_cache = { at = -1, ms = 0 }
    local function pingMs()
        local now = clock_()
        if now - ping_cache.at > 0.05 then
            local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
            ping_cache.ms, ping_cache.at = ok and ping or 0, now
        end
        return ping_cache.ms
    end
    local function ping_s() return math.min(pingMs(), 400) / 1000 end
    local Lag = { avg = nil, jit = 0.005, at = -1 }
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
    -- seconds from "fire now" until the parry is up, in the timeline of the ball we see
    local function reach_time()
        sample_lag()
        local ping = math.max(Lag.avg or ping_s(), ping_s())
        local ping_term = S.ping_compensation and ping or ping * 0.5
        return ping_term + jitter() + Core.interp + frame_dt * 0.5
    end

    -- ---------- the player ----------
    local function getRoot()
        local char = LocalPlayer.Character
        return char and char.PrimaryPart
    end
    local function character_root(name)
        if type(name) ~= 'string' or name == '' or not Alive then return nil end
        local char = Alive:FindFirstChild(name)
        if not char then
            local dead = Workspace:FindFirstChild('Dead')
            char = dead and dead:FindFirstChild(name)
        end
        return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
    end
    local function canParryNow()
        local char = LocalPlayer.Character
        if not char then return false end
        if char:GetAttribute("Stunned") or char:GetAttribute("DoNotParry") then return false end
        if char:GetAttribute("ChargingAdrenaline") then
            local ok, qi = pcall(function() return LocalPlayer.Upgrades["Qi-Charge"].Value end)
            if ok and type(qi) == "number" and qi < 2 then return false end
        end
        if char.Parent == Alive then return true end
        if LocalPlayer:GetAttribute("LobbyParry") then return not LocalPlayer:GetAttribute("InLobbyParryCooldown") end
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
    local function in_training()
        if LocalPlayer:GetAttribute("LobbyTraining") or LocalPlayer:GetAttribute("LobbyParry") then return true end
        local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
        return char ~= nil and dead ~= nil and char.Parent == dead
    end
    local function ap_root()
        local root = getRoot()
        if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
        return root
    end

    -- ---------- window / lockout gate ----------
    local function parry_window()
        local cw = Core.cap and Core.cap.win
        if cw and cw > 0 then return cw, 1.3 * math.min(cw / 0.5, 1) end
        return 0.5, 1.3
    end
    local function lockout_margin() return math.clamp(jitter() + frame_dt + 0.03, 0.06, 0.15) end
    local function gate_start()
        local now = clock_()
        if now < G.until_t then return end
        local n6, n2 = parry_window()
        G.until_t = now + math.max((n6 or 0.5) + 0.1, n2 or 1.3) + lockout_margin()
    end
    local function gate_open()
        if G.m1 and clock_() - G.m1_at < 3 then return false end
        return clock_() >= G.until_t
    end

    -- ---------- timing: when a parry has to leave ----------
    -- cushion = how far into the window contact lands (Accuracy 100 = latest
    -- that still lands, 1 = 60% in); Timing shifts it later (0) / earlier (2).
    local function cushion_for(speed, W)
        local a = (math.clamp(S.accuracy or 50, 1, 100) - 1) / 99
        local latest = 0.01
        local earliest = math.max(math.min(W - jitter() - 0.03, W * (0.45 + 0.4 * math.clamp((speed - 40) / 120, 0, 1))), latest)
        local tight, loose = jitter(), W * 0.6
        local c = math.clamp(loose + (tight - loose) * a, latest, earliest)
        local m = math.clamp(S.timing_mult or 1, 0, 2)
        if m <= 1 then c = latest + (c - latest) * m else c = c + (earliest - c) * (m - 1) end
        return c
    end
    local function fire_lead(speed)
        local W = parry_window() or 0.5
        local extra = math.clamp((S.extra_distance or 0) / math.max(speed, 1), -0.15, 0.15)
        return reach_time() + cushion_for(speed, W) + extra
    end
    -- the classic distance trigger (the build that "fired reliably")
    local function parry_distance(speed)
        local ping_ms = pingMs()
        local capped = math.min(math.max(speed - 9.5, 0), 650)
        local divisor = (2.4 + capped * 0.002) * (S.divisor_multiplier or 1.1)
        local distance = math.clamp(ping_ms / 100, 5, 17) + math.max(speed / divisor, 9.5)
        if S.ping_compensation then distance = distance + speed * (ping_ms / 1000) * 0.5 end
        distance = distance * (0.5 + 0.5 * math.clamp(S.timing_mult or 1, 0, 2))
        return distance + (S.extra_distance or 0)
    end

    -- ---------- screen points / aim / target ----------
    local function build_screen_points(cam)
        local points, others = {}, {}
        local char = LocalPlayer.Character
        local function add(name, pos)
            local screen = cam:WorldToScreenPoint(pos)
            points[name] = screen
            if not (char and name == char.Name) then others[#others + 1] = { name = name, pos = pos, screen = screen } end
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
    local PACKET_TTL = 1 / 240
    local packet_cache = { at = -1, points = nil, aim = nil, others = nil }
    local function packet_parts(cam)
        local now = clock_()
        if now - packet_cache.at > PACKET_TTL then
            packet_cache.points, packet_cache.others = build_screen_points(cam)
            local ok, mouse = pcall(UserInputService.GetMouseLocation, UserInputService)
            if ok and mouse then packet_cache.aim = { mouse.X, mouse.Y }
            else local vp = cam.ViewportSize; packet_cache.aim = { vp.X / 2, vp.Y / 2 } end
            packet_cache.at = now
        end
        return packet_cache.points, packet_cache.aim, packet_cache.others
    end
    local target_hold = { at = -1, mode = nil, name = nil, pos = nil }
    local function choose_target(cam)
        local mode = TARGET_NAMES[S.target_mode] or "Cursor"
        local now = clock_()
        if target_hold.mode == mode and now - target_hold.at < 0.1 then return target_hold.name, target_hold.pos, mode end
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
                    if (mode == "Closest" and d < best) or (mode == "Farthest" and d > best) then best, name, pos = d, t.name, t.pos end
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

    -- ---------- curve modes: the look direction sent with the parry ----------
    local curve_flip = 1
    local function curve_look(cam)
        local mode = CURVE_NAMES[S.curve_mode] or "Camera"
        if mode == "Camera" then return nil end
        local ccf = cam.CFrame
        local root = getRoot()
        local origin = root and root.Position or ccf.Position
        local _, tpos = choose_target(cam)
        local to = tpos and (tpos - origin) or ccf.LookVector
        if to.Magnitude < 1e-3 then to = ccf.LookVector end
        local toT, up = to.Unit, Vector3.yAxis
        local right = toT:Cross(up)
        right = right.Magnitude > 1e-3 and right.Unit or ccf.RightVector
        local d
        if mode == "Straight" then d = toT
        elseif mode == "Normal" then d = root and root.CFrame.LookVector or ccf.LookVector
        elseif mode == "Accelerated" then d = tpos and (tpos + Vector3.new(0, 5, 0) - origin) or toT
        elseif mode == "High" then d = toT + up * 3
        elseif mode == "Slow" then d = toT - up * 3
        elseif mode == "Backwards" then d = -toT + up * 0.1
        elseif mode == "Random" then d = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
        elseif mode == "Speed" then d = ccf.UpVector
        elseif mode == "Down" then d = -up
        elseif mode == "Left" then d = -ccf.RightVector
        elseif mode == "Right" then d = ccf.RightVector
        elseif mode == "Sky" then d = up
        elseif mode == "Ground" then d = toT * 0.3 - up
        elseif mode == "Alternate" then curve_flip = -curve_flip; d = toT * 0.2 + right * curve_flip
        elseif mode == "Random Side" then d = toT * 0.2 + right * (math.random() < 0.5 and -1 or 1)
        elseif mode == "Zigzag" then curve_flip = -curve_flip; d = toT + up * (1.5 * curve_flip)
        elseif mode == "Spiral" then
            local a = clock_() * 8
            d = toT + (right * math.cos(a) + up * math.sin(a)) * 1.2
        elseif mode == "Cursor" then
            local ok, m = pcall(UserInputService.GetMouseLocation, UserInputService)
            d = (ok and m) and cam:ViewportPointToRay(m.X, m.Y).Direction or ccf.LookVector
        elseif mode == "Flick" then d = toT + right * 2
        elseif mode == "Diagonal" then d = toT + right + up
        elseif mode == "Reverse" then d = -ccf.LookVector
        else return nil end
        if d ~= d or d.Magnitude < 1e-3 then return nil end
        return d.Unit
    end
    local curve_cache = { at = -1, mode = nil, look = nil }
    local function curve_look_cached(cam)
        local now = clock_()
        if now - curve_cache.at > PACKET_TTL or curve_cache.mode ~= S.curve_mode then
            curve_cache.look = curve_look(cam)
            curve_cache.at, curve_cache.mode = now, S.curve_mode
        end
        return curve_cache.look
    end

    -- ---------- capture hook (ported verbatim from the proven script) ----------
    local hookfunction_, restore_ = hookfunction, restorefunction
    local hookmetamethod_, getnamecallmethod_ = hookmetamethod, getnamecallmethod
    local setreadonly_ = setreadonly or (make_writeable)
    local newcclosure_ = newcclosure or function(f) return f end
    local oth_lib = rawget(getgenv(), "oth"); if type(oth_lib) ~= 'table' then pcall(function() oth_lib = oth end) end
    local oth_hook = type(oth_lib) == 'table' and type(oth_lib.hook) == 'function' and oth_lib.hook or nil
    local oth_unhook = type(oth_lib) == 'table' and type(oth_lib.unhook) == 'function' and oth_lib.unhook or nil
    local FIRE_FN
    local box = { want = false, nc = nil, fire = nil, list = {}, ws = Workspace, now = Workspace.GetServerTimeNow,
        me = "ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net" }
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
    local function build_body(src, ...)
        local args = table.pack(...)
        local ok, fn = pcall(function()
            local factory = loadstring(src, "=ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net")
            if setfenv then setfenv(factory, {}) end
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
            if box.want and #l < 4 and getnamecallmethod_() == "FireServer" and select("#", ...) >= 6 then
                l[#l + 1] = { self, select("#", ...), { ... }, box.now(box.ws) }
            end
            return box.nc(self, ...)
        end
    end
    if not FIRE_BODY then
        FIRE_BODY = function(self, ...)
            local l = box.list
            if box.want and #l < 4 and select("#", ...) >= 6 then
                l[#l + 1] = { self, select("#", ...), { ... }, box.now(box.ws) }
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
        local ok = pcall(function()
            local mt = getrawmetatable(game)
            local was_ro = isreadonly and isreadonly(mt)
            setreadonly_(mt, false)
            rawset(mt, "__namecall", original)
            if was_ro ~= false then setreadonly_(mt, true) end
        end)
        if not ok then pcall(hookmetamethod_, game, "__namecall", original) end
    end
    local function unhook()
        local fire, nc, was_oth = H.fire, H.nc, H.oth
        H.fire, H.nc, H.want, box.want, H.oth = nil, nil, false, false, false
        if fire and was_oth then
            if not (oth_unhook and pcall(oth_unhook, FIRE_FN)) then H.oth_kept = fire end
        elseif fire and not (restore_ and pcall(restore_, FIRE_FN)) then pcall(hookfunction_, FIRE_FN, fire) end
        if nc then restore_namecall(nc) end
        box.nc = nil
        if not H.oth_kept then box.fire = nil end
    end
    local JOB_ID = game.JobId
    local function inspect(entry)
        local self, a = entry[1], entry[3]
        local a1, a2, a3, a4, a5 = a[1], a[2], a[3], a[4], a[5]
        if typeof(self) == 'Instance' and self.ClassName == 'RemoteEvent'
            and type(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type(a2) == 'string' and type(a3) == 'string'
            and ((type(a4) == 'number' and typeof(a5) == 'CFrame') or (typeof(a4) == 'CFrame' and typeof(a5) == 'CFrame')) then
            local text = tostring(math.floor(entry[4] * 100))
            if #a3 ~= #text then return false end
            local key = {}
            for i = 1, #text do key[i] = bit32.bxor(string.byte(a3, i), (string.byte(text, i) + i) % 256) end
            Core.cap = { remote = self, hash = a1, uid = a2, key = key, len = #text,
                ball2 = typeof(a4) == "CFrame", win = type(a4) == "number" and a4 or nil }
            Core.misses, Core.pending = 0, nil
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
                for i = 1, #l do if pcall(inspect, l[i]) and Core.cap then break end end
                if Core.cap then break end
            end
            unhook()
            box.list = {}
        end)
        return true
    end
    local function pressBlockKey()
        if not is_live() then return false end
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        end)
        return true
    end
    local Prime = { last = 0, since = nil, dry = 0 }
    local function prime_remote()
        if Core.cap or not is_live() then return end
        if not in_match() or not canParryNow() then Prime.since = nil; return end
        local now = clock_()
        Prime.since = Prime.since or now
        if now - Prime.since < 1 or now - Prime.last < 1.4 then return end
        if Prime.dry >= 3 then
            if now - Prime.last < 20 then return end
            Prime.dry = 0
        end
        Prime.last = now
        if arm() then Prime.dry = Prime.dry + 1; pressBlockKey(); gate_start() end
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
    -- "sent" / "unarmed" / "blocked". spam = true skips the lockout gate.
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
        local name, _, mode = choose_target(cam)
        if name and mode ~= "Cursor" then
            local screen = points[name]
            if screen then aim = { screen.X, screen.Y } end
        end
        local cf = cam.CFrame
        local look = curve_look_cached(cam)
        if look then local o = cf.Position; cf = CFrame.lookAt(o, o + look) end
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

    -- ---------- ball physics ----------
    local tracked = setmetatable({}, { __mode = 'k' })
    local ball_conns = {}
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
        return (velocity / speed):Dot(offset / distance), speed, distance, velocity
    end
    -- the ball touches us when its surface reaches us
    local function contact_gap(ball)
        local ok, size = pcall(function() return ball.Size end)
        if not ok or not size then return 3 end
        return math.max(size.X, size.Y, size.Z) * 0.5 + 1.5
    end
    local function time_to_contact(path, gap, speed, accel)
        local d = math.max(path - gap, 0)
        if accel > 1 then return (math.sqrt(speed * speed + 2 * accel * d) - speed) / accel end
        return d / speed
    end
    -- how fast the ball's direction swings (rad/s), ~33ms samples, follows a sharp turn-in at once
    local function turn_rate(st, velocity, now)
        local speed = velocity.Magnitude
        if speed < 1 then return 0 end
        local dir = velocity / speed
        local s = st.trn
        if not s then st.trn = { t = now, dir = dir, w = 0, n = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.033 then
            local w = math.acos(math.clamp(s.dir:Dot(dir), -1, 1)) / dt
            s.w = s.n == 0 and w or math.max(s.w * 0.5 + w * 0.5, w * 0.85)
            s.n, s.t, s.dir = s.n + 1, now, dir
        end
        return s.w
    end
    -- how fast it's gaining speed (studs/s^2), ~80ms samples
    local function speed_gain(st, speed, now)
        local s = st.spd
        if not s then st.spd = { t = now, v = speed, a = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.08 then
            s.a = s.a * 0.5 + ((speed - s.v) / dt) * 0.5
            s.t, s.v = now, speed
        end
        return math.clamp(s.a, 0, speed * 4)
    end
    -- how fast the angle between its direction and us is changing (rad/s,
    -- positive = opening up, i.e. swinging AWAY from us), ~50ms samples
    local function angle_trend(st, theta, now)
        local s = st.ang
        if not s then st.ang = { t = now, v = theta, rate = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.05 then
            s.rate = s.rate * 0.4 + ((theta - s.v) / dt) * 0.6
            s.t, s.v = now, theta
        end
        return s.rate
    end
    -- ANTI CURVE: fly the ball forward the way it really moves -- swinging toward
    -- us at the rate it's been turning, speeding up at the rate it's been gaining
    -- -- and return the seconds until it touches us (nil if not within horizon).
    local SIM_DT = 1 / 120
    local function predict_contact(ball_pos, velocity, target, gap, turn, accel, horizon)
        local speed = velocity.Magnitude
        if speed < 1 then return nil end
        local pos, dir, t = ball_pos, velocity / speed, 0
        while t < horizon do
            local to = target - pos
            local dist = to.Magnitude
            if dist <= gap then return t end
            local want = to / dist
            local angle = math.acos(math.clamp(dir:Dot(want), -1, 1))
            if angle > 1e-3 and turn > 0 then
                local swing = turn * SIM_DT
                if swing >= angle then dir = want
                else
                    local mixed = dir:Lerp(want, swing / angle)
                    if mixed.Magnitude < 1e-3 then mixed = dir:Cross(Vector3.yAxis) end
                    dir = mixed.Unit
                end
            end
            speed = speed + accel * SIM_DT
            local move = speed * SIM_DT
            if dir:Dot(want) > 0 and move >= dist - gap then return t + (dist - gap) / speed end
            pos = pos + dir * move
            t = t + SIM_DT
        end
        return nil
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

    -- ---------- ball tracking ----------
    local on_retarget, on_velocity -- set below
    local function open_pass(st)
        st.pass_open, st.parried, st.landed, st.parry_until = true, false, false, 0
        st.trn, st.spd, st.ang = nil, nil, nil
        -- a pre-parry fired while the ball was on its last holder counts for this pass
        if st.preparried then
            st.parried, st.parry_until, st.preparried = true, st.preparry_until, false
        end
        if S.random_accuracy then roll_accuracy() end
    end
    local function hook_zoomies(ball, st, z)
        if st.zinst == z then return end
        st.zinst = z
        ball_conns[#ball_conns + 1] = z:GetPropertyChangedSignal('VectorVelocity'):Connect(function()
            if active and is_live() and st.target == me then on_velocity(ball, st) end
        end)
    end
    local function get_ball_state(ball)
        local st = tracked[ball]
        if st then return st end
        st = { target = ball:GetAttribute('target'), swaps = {}, pass_open = false, parried = false,
            landed = false, parry_until = 0, preparried = false, preparry_until = 0 }
        tracked[ball] = st
        if st.target == me then open_pass(st) end
        ball_conns[#ball_conns + 1] = ball:GetAttributeChangedSignal('target'):Connect(function()
            if not active or not is_live() then return end
            local new = ball:GetAttribute('target')
            local now = clock_()
            local swaps = st.swaps
            swaps[#swaps + 1] = { t = now, from = st.target, to = new }
            if #swaps > 16 then table.remove(swaps, 1) end
            st.target = new
            if type(new) == 'string' and new ~= '' and new ~= me then st.pass_open, st.parried, st.landed = false, false, false end
            if new == me and not st.pass_open then open_pass(st) end
            on_retarget(ball, st, new, now)
        end)
        local z = ball:FindFirstChild('zoomies')
        if z then hook_zoomies(ball, st, z) end
        ball_conns[#ball_conns + 1] = ball.ChildAdded:Connect(function(c)
            if c.Name == 'zoomies' then hook_zoomies(ball, st, c) end
        end)
        return st
    end

    -- ===================== AUTO SPAM: clash detection =====================
    -- A clash = the ball traded between you and one player close by faster than
    -- a normal parry can follow. Detected from physics + history, before it hurts:
    --   react = your reach time (ping + view lag + jitter);
    --   back  = gap / (speed * 1.08): how long their return takes to reach you.
    --   back under react * Sensitivity -> a normal parry can't keep up.
    -- START (ball on you): from a player in clash range AND a quick hand-off, or it
    --   lands inside your reaction time, or the two of you are trading parries fast
    --   (ParrySuccessAll from you/them within 0.7s).
    -- START (ball on them, predictive): you just sent it, it's flying into them,
    --   their return comes to you, and it'd be too fast -- spam begins BEFORE the
    --   ball turns back. Two quick hand-offs in a row also start it.
    -- KEEP while it stays between you two (range and tempo get 25-30% slack) plus
    --   the Hold tail; STOP the instant it goes to anyone else or they leave range.
    local AutoSpam = { active_until = 0, ball = nil, partner = nil, reason = nil, was_active = false }
    local parry_all = {} -- recent ParrySuccessAll: {t, who}
    local function clash_range(speed) return math.clamp(18 + speed * 0.08, 18, 50) + (SP.range_bonus or 0) end
    local function ball_owners(st)
        local owners = {}
        for i = #st.swaps, 1, -1 do
            local s = st.swaps[i]
            if type(s.to) == 'string' and s.to ~= '' then
                local last = owners[#owners]
                if last and last.name == s.to then last.t = s.t else owners[#owners + 1] = { name = s.to, t = s.t } end
            end
            if #owners >= 6 then break end
        end
        if #owners == 0 and type(st.target) == 'string' and st.target ~= '' then owners[1] = { name = st.target, t = 0 } end
        return owners
    end
    local function quick_handoffs(owners, partner, tempo)
        local n = 0
        for i = 1, #owners - 1 do
            local cur, prev = owners[i], owners[i + 1]
            local alt = (cur.name == me and prev.name == partner) or (cur.name == partner and prev.name == me)
            if not alt or cur.t - prev.t > tempo then break end
            n = n + 1
        end
        return n
    end
    -- you and them trading landed parries fast. Events that name the parrier count
    -- only for you two; events with no name could be anyone in the server, so
    -- they need a higher bar.
    local function trading_fast(now, partner)
        local known, unknown = 0, 0
        for i = #parry_all, 1, -1 do
            local e = parry_all[i]
            if now - e.t > 0.7 then break end
            if e.who == nil then unknown = unknown + 1
            elseif e.who == me or e.who == partner then known = known + 1 end
        end
        return known >= 2 or unknown >= 3
    end
    local function return_comes_to_us(their, root, partner, gap)
        local to = root.Position - their.Position
        local m = to.Magnitude
        if m < 0.5 or their.CFrame.LookVector:Dot(to / m) > 0.5 then return true end
        for _, model in ipairs(Alive:GetChildren()) do
            if model.Name ~= me and model.Name ~= partner then
                local hrp = model:FindFirstChild('HumanoidRootPart')
                if hrp and (hrp.Position - their.Position).Magnitude < gap then return false end
            end
        end
        return true
    end
    -- partner, why -- or nil. held = this ball is the running clash (keeps it with slack).
    local function clash_on(ball, root, now, held)
        local st = get_ball_state(ball)
        local target = st.target
        if type(target) ~= 'string' or target == '' then return nil end
        local owners = ball_owners(st)
        local partner = (target == me) and (owners[2] and owners[2].name) or target
        if not partner or partner == me then return nil end
        if held and AutoSpam.partner and partner ~= AutoSpam.partner then return nil end
        local their = character_root(partner)
        if not their then return nil end
        local velocity = ball_velocity(ball)
        local speed = math.max(velocity.Magnitude, 1)
        local gap = (their.Position - root.Position).Magnitude
        if gap > clash_range(speed) * (held and 1.3 or 1) then return nil end
        local react = reach_time()
        local sens = math.clamp(SP.sensitivity or 1.3, 0.6, 2.5)
        local back = gap / (speed * 1.08)
        local too_fast = back <= react * sens + 0.08
        local tempo = math.clamp(gap / speed * 2 + react * 2 + 0.15, 0.3, 0.9) * (held and 1.25 or 1)
        local handoffs = quick_handoffs(owners, partner, tempo)
        local trading = trading_fast(now, partner)
        if target == me then
            if handoffs >= 1 then return partner, "quick hand-off" end
            local eta = (ball.Position - root.Position).Magnitude / speed
            if eta <= react * (sens - 0.1) + 0.08 then return partner, ("lands in %.2fs, too fast to react"):format(eta) end
            if trading and speed >= 30 then return partner, "trading parries" end
            if held then return partner, "exchange on" end
            return nil
        end
        if held and owners[1] and now - owners[1].t <= tempo then return partner, "exchange on" end
        local to_them = their.Position - ball.Position
        local d_them = to_them.Magnitude
        if not (d_them < 6 or velocity:Dot(to_them / d_them) > speed * 0.3) then return nil end
        if handoffs >= 2 then return partner, ("%d quick hand-offs"):format(handoffs) end
        if trading and too_fast then return partner, "trading parries" end
        local from_me = owners[2] and owners[2].name == me
        if SP.predictive and from_me and too_fast and return_comes_to_us(their, root, partner, gap) then
            return partner, ("predicted: return in %.2fs, you need %.2fs"):format(back, react)
        end
        return nil
    end
    local function can_auto_spam(root)
        return SP.auto and root and not root:FindFirstChild('SingularityCape') and canParryNow() and not in_training()
    end
    local function mark_clash(ball, now, partner, why)
        AutoSpam.ball, AutoSpam.partner = ball, partner
        AutoSpam.active_until = now + math.clamp(SP.hold or 0.15, 0, 0.5) + 0.02
        AutoSpam.reason = ("vs %s (%s)"):format(partner, why)
    end
    local function end_clash()
        AutoSpam.active_until, AutoSpam.reason, AutoSpam.ball, AutoSpam.partner = 0, nil, nil, nil
    end
    local function has_clash(ball, now) return AutoSpam.ball == ball and now < AutoSpam.active_until end
    local function clash_check(ball, now)
        local root = getRoot()
        if not can_auto_spam(root) then return false end
        local partner, why = clash_on(ball, root, now, AutoSpam.ball == ball)
        if not partner then return false end
        mark_clash(ball, now, partner, why)
        return true
    end
    local function auto_spam_evaluate(now)
        if not SP.auto then if AutoSpam.ball then end_clash() end; return end
        local root = getRoot()
        if not can_auto_spam(root) then if AutoSpam.ball then end_clash() end; return end
        local cur = AutoSpam.ball
        if cur then
            if not cur.Parent then end_clash(); return end
            local target = cur:GetAttribute('target')
            if target ~= me and target ~= AutoSpam.partner then end_clash(); return end
            local partner, why = clash_on(cur, root, now, true)
            if partner then mark_clash(cur, now, partner, why); return end
            if now < AutoSpam.active_until then return end -- the Hold tail
            end_clash()
        end
        for _, ball in ipairs(get_live_balls()) do
            local partner, why = clash_on(ball, root, now, false)
            if partner then mark_clash(ball, now, partner, why); return end
        end
    end

    -- ===================== SPAM PUMP =====================
    local Pump = { credit = 0, last = clock_(), on = false, frame = 0, frame_fires = 0, fired_frame = -1 }
    local SpamMeter = { count = 0, since = clock_(), rate = 0 }
    local function current_source(now)
        if SP.manual then return "manual" end
        if SP.auto and now < AutoSpam.active_until then return "auto" end
        return nil
    end
    local function spam_focus()
        local root = getRoot()
        if not root then return false end
        local horizon = reach_time() + 0.25
        for _, ball in ipairs(get_live_balls()) do
            local st = get_ball_state(ball)
            if st.target == me then return true end
            local speed = ball_velocity(ball).Magnitude
            if speed > 1 and (ball.Position - root.Position).Magnitude / speed <= horizon then return true end
        end
        return false
    end
    local function upload_factor(now)
        if SP.upload_kbps <= 0 then SP.factor = 1; return 1 end
        if now - SP.guard_at < 0.1 then return SP.factor end
        SP.guard_at = now
        local ok, kbps = pcall(function() return Stats.DataSendKbps end)
        if ok and type(kbps) == 'number' and kbps > 0 then
            SP.factor = math.clamp(SP.factor * math.clamp(SP.upload_kbps / kbps, 0.5, 1.15), 0.1, 1)
        end
        return SP.factor
    end
    local function target_rate(now)
        local rate = math.clamp(SP.max_rate or 1000, 1, 2000) * upload_factor(now)
        if SP.mode == "Keypress" then rate = math.min(rate, 1 / frame_dt) end
        if not spam_focus() then rate = math.min(rate, SP.idle_rate) end
        return math.max(rate, 1)
    end
    local function fire_one()
        if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
        if SP.mode == "Keypress" and Pump.frame_fires >= 1 then return false end
        local ok
        if SP.mode == "Keypress" then ok = pressBlockKey() else ok = send(true) == "sent" end
        Pump.frame_fires = Pump.frame_fires + 1
        if ok then SpamMeter.count = SpamMeter.count + 1 end
        return ok
    end
    -- credit grows with real time, so the rate is exact at any FPS; a hitch can't dump a backlog
    local function spam_tick(now)
        local elapsed = math.min(now - Pump.last, 0.05)
        Pump.last = now
        local span = now - SpamMeter.since
        if span >= 0.5 then SpamMeter.rate, SpamMeter.count, SpamMeter.since = SpamMeter.count / span, 0, now end
        if not current_source(now) or not LocalPlayer.Character then Pump.credit, Pump.on = 0, false; return end
        local rate = target_rate(now)
        if Pump.on then Pump.credit = math.min(Pump.credit + elapsed * rate, 1 + rate * 0.015)
        else Pump.credit, Pump.on = 1, true end
        while Pump.credit >= 1 - 1e-6 do
            Pump.credit = Pump.credit - 1
            if fire_one() == false and SP.mode == "Keypress" then Pump.credit = math.min(Pump.credit, 0); break end
        end
    end
    -- the moments a fresh spam parry matters most: fire from the event itself
    local function spam_instant()
        if not current_source(clock_()) or not LocalPlayer.Character then return end
        Pump.credit, Pump.on = math.max(Pump.credit - 1, -1), true
        fire_one()
    end

    -- ===================== AUTO PARRY / TRIGGERBOT / PRE-PARRY =====================
    local function mark_parried(st, now)
        local _, n2 = parry_window()
        st.parried, st.parry_until = true, now + math.max(math.clamp(S.retry_delay or 1, 0.2, 1.5), (n2 or 1.3) + 0.08)
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

    local MIN_TURN = 3 -- rad/s floor for a ball whose turn isn't measured yet
    -- The decision for a ball on us. via: "retarget" (it just turned to us),
    -- "velocity" (its new direction just replicated), or nil (a frame point).
    local function decide(ball, st, root, now, via)
        if pass_busy(st, now) or has_clash(ball, now) then return end
        local heading, speed, dist, vel = read_ball(ball, root)
        if speed < 1 then return end
        local W = parry_window() or 0.5
        local reach = reach_time()
        local lead = math.min(fire_lead(speed), reach + W * 0.85)
        local gap = contact_gap(ball)
        local accel = speed_gain(st, speed, now)
        local turn = turn_rate(st, vel, now)
        local opening = angle_trend(st, math.acos(math.clamp(heading, -1, 1)), now)
        local info = { speed = speed, dist = dist, heading = heading, lead = lead }
        -- DANGER ZONE: it reaches us inside our reach time however it curves --
        -- waiting can only make the parry late.
        if dist <= 10 or dist - gap <= speed * reach * 1.05 + 1 then
            info.eta = math.max(dist - gap, 0) / speed
            return fire(st, now, via == "retarget" and "instant retarget" or "point blank", info)
        end
        if via == "retarget" then
            -- its new direction isn't in yet; it homes straight in at (at least)
            -- this speed. Fire now if that lands in our lead and it isn't flying
            -- clearly away; otherwise the velocity update / next frame decides.
            local eta = time_to_contact(dist, gap, speed, 0)
            info.eta = eta
            if eta <= lead and heading >= -0.25 then return fire(st, now, "instant retarget", info) end
            return
        end
        local eta
        if not S.anticurve then
            if heading <= 0 then return end
            eta = time_to_contact(dist, gap, speed, accel)
        elseif heading >= 0.97 then
            eta = time_to_contact(dist, gap, speed, accel) -- coming straight in
        else
            -- The measured turn rate only says HOW HARD it's turning, not which way.
            -- Swinging away from us (a curve bait / wide curve), it's not homing in
            -- yet: assume the slow floor so we wait for it to come round. Closing
            -- in, trust the measured rate.
            local eff_turn = opening > 0.6 and MIN_TURN or math.max(turn, MIN_TURN)
            eta = predict_contact(ball.Position, vel, root.Position, gap, eff_turn, accel, lead + 0.25) or math.huge
        end
        info.eta = eta
        -- safety net: the classic distance trigger for a ball coming in fairly
        -- straight, kept inside the window
        local net = heading >= 0.7 and dist <= parry_distance(speed) and (dist - gap) / speed <= reach + W * 0.85
        if eta <= lead or net then return fire(st, now, via == "velocity" and "auto parry (velocity)" or "auto parry", info) end
    end

    -- triggerbot: parry the moment the ball is on us, any distance, one per pass
    local function trigger(ball, st, now)
        if pass_busy(st, now) or has_clash(ball, now) then return end
        fire(st, now, "triggerbot", nil)
    end

    -- pre-parry: the ball is on a player right next to us and their return would
    -- beat our reach -- time it as if it were already coming.
    local function try_preparry(ball, st, root, now)
        if st.preparried then
            if now < st.preparry_until then return end
            st.preparried = false
        end
        if not (S.preparry or (S.hp_preparry and (Lag.avg or ping_s()) >= 0.08)) then return end
        if not Core.cap then return end
        local target = st.target
        if type(target) ~= 'string' or target == '' or target == me then return end
        local their = character_root(target)
        if not their then return end
        local gap = (their.Position - root.Position).Magnitude
        if gap > (S.preparry_range or 20) then return end
        local vel = ball_velocity(ball)
        local speed = vel.Magnitude
        if speed < 1 then return end
        local to_them = their.Position - ball.Position
        local d_them = to_them.Magnitude
        if d_them > 3 and vel:Dot(to_them / d_them) < speed * 0.3 then return end
        local back = gap / (speed * 1.1)
        local reach = reach_time()
        if back > reach + frame_dt * 2 then return end -- we'd have time to react
        local eta = d_them / speed + back
        if eta > fire_lead(speed) or has_clash(ball, now) then return end
        if send(false) == "sent" then
            local W, n2 = parry_window()
            st.preparried = true
            st.preparry_until = now + math.max((W or 0.5) + reach + 0.15, (n2 or 1.3) + 0.08)
            Core.last_parry = { t = now, via = "pre-parry", info = { eta = eta, lead = fire_lead(speed) } }
        end
    end

    on_retarget = function(ball, st, new, now)
        if new == me then
            if SP.auto then clash_check(ball, now) end
            if has_clash(ball, now) then spam_instant(); return end
            local root = ap_root()
            if root then
                if S.triggerbot then trigger(ball, st, now)
                elseif S.autoparry then decide(ball, st, root, now, "retarget") end
            end
            if SP.manual then spam_instant() end
        elseif SP.auto then
            clash_check(ball, now) -- predictive start as it goes to them
        end
    end
    on_velocity = function(ball, st)
        if not S.autoparry or S.triggerbot then return end
        local root = ap_root()
        if root then decide(ball, st, root, clock_(), "velocity") end
    end

    -- ===================== per-frame (3 points a frame) =====================
    function Parry.frame(dt, point)
        if not active or not is_live() then return end
        local now = clock_()
        if point == 1 then
            if dt then frame_dt = math.clamp(dt, 1 / 240, 0.1) end
            Pump.frame = Pump.frame + 1
            -- two unanswered parries in a row: the capture went stale, take a fresh one
            if Core.pending and now > Core.pending then
                Core.pending, Core.misses = nil, Core.misses + 1
                if Core.misses >= 2 then Core.cap, Core.misses = nil, 0 end
            end
            if not Core.cap then prime_remote() end
            auto_spam_evaluate(now)
            local act = now < AutoSpam.active_until
            if act and not AutoSpam.was_active and not SP.manual then spam_instant() end
            AutoSpam.was_active = act
        end
        if S.autoparry or S.triggerbot then
            local root = ap_root()
            if root then
                for _, ball in ipairs(get_live_balls()) do
                    local st = get_ball_state(ball)
                    if st.target == me then
                        if S.triggerbot then trigger(ball, st, now) else decide(ball, st, root, now) end
                    else
                        try_preparry(ball, st, root, now)
                    end
                end
            end
        elseif SP.auto or SP.manual then
            for _, ball in ipairs(get_live_balls()) do get_ball_state(ball) end -- keep owner history live
        end
        spam_tick(now)
    end

    -- a new ball: track it immediately (its first target counts as a retarget)
    function Parry.onBallAdded(ball)
        task.defer(function()
            if not active or not ball.Parent or not ball:GetAttribute('realBall') then return end
            local st = get_ball_state(ball)
            if st.target == me then on_retarget(ball, st, me, clock_()) end
        end)
    end
    function Parry.ballFolders()
        local list = {}
        for _, name in ipairs({ "Balls", "TrainingBalls" }) do
            local f = Workspace:FindFirstChild(name)
            if f then list[#list + 1] = f end
        end
        return list
    end

    function Parry.onParrySuccess()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.until_t = 0
        local lp = Core.last_parry
        if Core.pending and lp and lp.info and lp.info.eta and lp.info.eta < 0.9 then
            local took = clock_() - lp.t
            if took < 1 then Core.interp = math.clamp(Core.interp * 0.7 + (lp.info.eta - took) * 0.3, 0.02, 0.3) end
        end
        Core.pending, Core.misses = nil, 0
        for _, st in pairs(tracked) do if st.target == me and st.pass_open then st.landed = true end end
        spam_instant()
    end
    function Parry.onParryAll(...)
        local who
        for i = 1, select('#', ...) do
            local a = select(i, ...)
            if typeof(a) == 'Instance' then who = a.Name; break end
            if type(a) == 'string' and Players:FindFirstChild(a) then who = a; break end
        end
        parry_all[#parry_all + 1] = { t = clock_(), who = who }
        if #parry_all > 16 then table.remove(parry_all, 1) end
        if AutoSpam.ball or SP.manual then spam_instant() end
    end
    function Parry.onNoobParry() task.wait(0.11); G.until_t = 0 end
    function Parry.onM1Stop(v) G.m1, G.m1_at = v and true or false, clock_() end

    function Parry.status()
        local lp = Core.last_parry
        local last = "none"
        if lp then
            last = ("%s, %.1fs ago"):format(lp.via or "?", clock_() - lp.t)
            if lp.info and lp.info.eta then last = last .. (" (eta %.2fs / lead %.2fs)"):format(lp.info.eta, lp.info.lead or 0) end
        end
        local clash = not SP.auto and "off"
            or (clock_() < AutoSpam.active_until and ("SPAMMING " .. tostring(AutoSpam.reason)) or "watching for clashes")
        return {
            armed = Core.cap and ("armed (" .. capture_method() .. ")") or "not armed yet",
            last = last, clash = clash, rate = SpamMeter.rate, ping = pingMs(),
            curve = CURVE_NAMES[S.curve_mode] or "?",
        }
    end

    -- ---------- activate / deactivate (the only game-touching entry points) ----------
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
        active = Remotes ~= nil and Alive ~= nil
        return active
    end
    -- Drops every hook and per-ball listener. The learned capture is kept (plain
    -- data, no footprint) so turning a feature back on parries straight away.
    function Parry.deactivate()
        active = false
        pcall(unhook)
        for _, c in ipairs(ball_conns) do pcall(function() c:Disconnect() end) end
        ball_conns = {}
        for k in pairs(tracked) do tracked[k] = nil end
        end_clash()
        Pump.credit, Pump.on = 0, false
        Core.pending, Core.misses = nil, 0
        G.until_t, Prime.since, Prime.dry = 0, nil, 0
    end
    function Parry.remotes() return Remotes end
    function Parry.spamRate() return SpamMeter.rate end
    function Parry.clashText()
        if not SP.auto then return "off" end
        if clock_() < AutoSpam.active_until then return "SPAMMING " .. tostring(AutoSpam.reason) end
        return "watching for clashes"
    end
end

-- ===========================================================================
-- ENGINE: the one owner of every game connection. Starts when the first
-- parry/spam feature turns on, stops (and tears everything down) when the last
-- one turns off.
-- ===========================================================================
local Library -- set after the UI loads
local StatusHook -- set by the UI
local Engine = { users = {}, conns = {}, running = false, status_at = 0 }
local function econnect(signal, fn)
    local c = signal:Connect(function(...)
        if not is_live() then return end
        fn(...)
    end)
    Engine.conns[#Engine.conns + 1] = c
end
function Engine.start()
    if not Parry.activate() then
        if Library then Library:Notify({ Title = "Blade Ball", Description = "Couldn't find the game's Remotes / Alive.", Time = 4 }) end
        return false
    end
    local R = Parry.remotes()
    -- each wrapped in a closure: indexing a missing remote must fail inside pcall
    pcall(function() econnect(R.ParrySuccess.OnClientEvent, Parry.onParrySuccess) end)
    pcall(function() econnect(R.ParrySuccessAll.OnClientEvent, Parry.onParryAll) end)
    pcall(function() econnect(R.NoobParryHappened.OnClientEvent, Parry.onNoobParry) end)
    pcall(function() econnect(R.M1Stop.Event, Parry.onM1Stop) end)
    for _, folder in ipairs(Parry.ballFolders()) do econnect(folder.ChildAdded, Parry.onBallAdded) end
    econnect(RunService.PreSimulation, function(dt) Parry.frame(dt, 1) end)
    econnect(RunService.Heartbeat, function()
        Parry.frame(nil, 2)
        local now = clock_()
        if StatusHook and now - Engine.status_at > 0.25 then
            Engine.status_at = now
            pcall(StatusHook, Parry.status())
        end
    end)
    pcall(function() econnect(RunService.PreRender, function() Parry.frame(nil, 3) end) end)
    Engine.running = true
    return true
end
function Engine.stop()
    for _, c in ipairs(Engine.conns) do pcall(function() c:Disconnect() end) end
    Engine.conns = {}
    pcall(Parry.deactivate)
    Engine.running = false
    if StatusHook then pcall(StatusHook, nil) end
end
function Engine.want(name, on)
    Engine.users[name] = on and true or nil
    local any = next(Engine.users) ~= nil
    if any and not Engine.running then
        if not Engine.start() then Engine.users[name] = nil end
    elseif not any and Engine.running then
        Engine.stop()
    end
end

-- ---------------------------------------------------------------------------
-- UI.
-- ---------------------------------------------------------------------------
Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options, Toggles = Library.Options, Library.Toggles
local S, SP = Parry.S, Parry.SP

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
    Parry = Window:AddTab("Auto Parry", "swords", "Auto parry, triggerbot, curves"),
    Spam = Window:AddTab("Spam", "zap", "Manual and auto spam"),
    Player = Window:AddTab("Player", "user", "Movement"),
    Status = Window:AddTab("Status", "gauge", "Live state"),
}

-- ----- Auto Parry tab -----
local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {
    Text = "Auto parry", Default = false,
    Callback = function(v) S.autoparry = v; Engine.want("autoparry", v) end,
}):AddKeyPicker("AutoParryKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry" })
AP:AddToggle("Triggerbot", {
    Text = "Triggerbot", Default = false,
    Tooltip = "Parries the instant the ball is on you, at any distance. Overrides auto parry's timing while on.",
    Callback = function(v) S.triggerbot = v; Engine.want("triggerbot", v) end,
}):AddKeyPicker("TriggerbotKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Triggerbot" })
AP:AddToggle("AntiCurve", {
    Text = "Anti curve", Default = true,
    Tooltip = "Times curving balls with a homing simulation. Off = straight-line timing only.",
    Callback = function(v) S.anticurve = v end,
})
AP:AddToggle("PreParry", {
    Text = "Pre-parry", Default = false,
    Tooltip = "When the ball is on a player right next to you and their return would beat your reaction, parry ahead of it.",
    Callback = function(v) S.preparry = v end,
})
AP:AddSlider("PreParryRange", {
    Text = "Pre-parry range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Callback = function(v) S.preparry_range = v end,
})
AP:AddToggle("HighPingPreParry", {
    Text = "Auto pre-parry at high ping", Default = false,
    Tooltip = "Pre-parry turns on by itself while your ping is 80ms or more.",
    Callback = function(v) S.hp_preparry = v end,
})
AP:AddDropdown("TargetMode", {
    Values = Parry.targetNames, Default = "Cursor", Text = "Target mode",
    Tooltip = "Who the ball is aimed at when you parry.",
    Callback = function(v) Parry.setTargetMode(v) end,
})
AP:AddDropdown("CaptureHook", {
    Values = { "oth", "Namecall", "FireServer", "Both" }, Default = "oth", Text = "Capture hook",
    Tooltip = "How the first parry packet is captured. 'oth' (Delta) is the stealthiest.",
    Callback = function(v) getgenv().CaptureHook = v end,
})

local APS = Tabs.Parry:AddRightGroupbox("Timing", "sliders-horizontal")
APS:AddSlider("Accuracy", {
    Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "Higher = contact lands later in the parry (tighter); lower = earlier with more cushion.",
    Callback = function(v) S.accuracy_base = v; Parry.roll() end,
})
APS:AddSlider("TimingMult", {
    Text = "Timing", Default = 1, Min = 0, Max = 2, Rounding = 2,
    Tooltip = "Toward 2 = parry earlier, toward 0 = later. Works at any accuracy.",
    Callback = function(v) S.timing_mult = v end,
})
APS:AddSlider("ExtraDistance", {
    Text = "Extra distance", Default = 0, Min = -20, Max = 40, Rounding = 0, Suffix = " studs",
    Callback = function(v) S.extra_distance = v end,
})
APS:AddSlider("RetryDelay", {
    Text = "Retry delay", Default = 1, Min = 0.2, Max = 1.5, Rounding = 2, Suffix = "s",
    Tooltip = "Still on you this long after a parry (and past the lockout): parry again.",
    Callback = function(v) S.retry_delay = v end,
})
APS:AddToggle("PingCompensation", {
    Text = "Ping compensation", Default = false,
    Tooltip = "Leads further ahead on high ping. Turn on if parries land late.",
    Callback = function(v) S.ping_compensation = v end,
})
APS:AddToggle("RandomAccuracy", {
    Text = "Randomize accuracy", Default = false,
    Callback = function(v) S.random_accuracy = v end,
})
APS:AddSlider("RandomAccuracyAmount", {
    Text = "Randomize amount", Default = 10, Min = 0, Max = 50, Rounding = 0, Suffix = " +/-",
    Callback = function(v) S.random_accuracy_amount = v end,
})

local CV = Tabs.Parry:AddRightGroupbox("Curve", "spline")
CV:AddDropdown("CurveMode", {
    Values = Parry.curveNames, Default = "Camera", Text = "Curve mode", Searchable = true,
    Tooltip = "The direction sent with every parry (auto parry, triggerbot and spam).",
    Callback = function(v) Parry.setCurveMode(v) end,
})
local function cycle_curve(dir)
    local names = Parry.curveNames
    local idx = (S.curve_mode - 1 + dir) % #names + 1
    pcall(function() Options.CurveMode:SetValue(names[idx]) end)
    Library:Notify({ Title = "Curve", Description = names[idx], Time = 1 })
end
CV:AddLabel("Next curve"):AddKeyPicker("NextCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Next curve", Callback = function() cycle_curve(1) end,
})
CV:AddLabel("Previous curve"):AddKeyPicker("PrevCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Previous curve", Callback = function() cycle_curve(-1) end,
})

-- ----- Spam tab -----
local MS = Tabs.Spam:AddLeftGroupbox("Manual Spam", "zap")
MS:AddToggle("ManualSpam", {
    Text = "Manual spam", Default = false,
    Callback = function(v) SP.manual = v; Engine.want("manualspam", v) end,
}):AddKeyPicker("ManualSpamKey", { Default = "E", Mode = "Hold", SyncToggleState = true, Text = "Manual spam" })
MS:AddDropdown("SpamMode", {
    Values = { "Remote", "Keypress" }, Default = "Remote", Text = "Mode",
    Tooltip = "Remote sends the captured parry packet; Keypress presses block (max one a frame).",
    Callback = function(v) SP.mode = v end,
})
MS:AddSlider("SpamMaxRate", {
    Text = "Max rate", Default = 1000, Min = 20, Max = 2000, Rounding = 0, Suffix = "/s",
    Tooltip = "Parries a second for manual and auto spam.",
    Callback = function(v) SP.max_rate = v end,
})
MS:AddSlider("SpamIdleRate", {
    Text = "Idle rate", Default = 20, Min = 1, Max = 200, Rounding = 0, Suffix = "/s",
    Tooltip = "Rate while no ball is on you or about to reach you.",
    Callback = function(v) SP.idle_rate = v end,
})
MS:AddSlider("SpamUploadLimit", {
    Text = "Upload limit", Default = 0, Min = 0, Max = 1500, Rounding = 0, Suffix = " kbps",
    Tooltip = "0 = off. Set ~200-400 if spam makes your movement rubber-band.",
    Callback = function(v) SP.upload_kbps = v end,
})
local SpamRateLabel = MS:AddLabel("Actual: 0/s", true)

local AS = Tabs.Spam:AddRightGroupbox("Auto Spam", "activity")
AS:AddToggle("AutoSpam", {
    Text = "Auto spam", Default = false,
    Tooltip = "Spams through clashes: detected from physics and parry history, often before the ball even comes back.",
    Callback = function(v) SP.auto = v; Engine.want("autospam", v) end,
}):AddKeyPicker("AutoSpamKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto spam" })
AS:AddToggle("PredictiveClash", {
    Text = "Predictive start", Default = true,
    Tooltip = "Start spamming as you send the ball to a close player whose return would be too fast to react to.",
    Callback = function(v) SP.predictive = v end,
})
AS:AddSlider("ClashSensitivity", {
    Text = "Sensitivity", Default = 1.3, Min = 0.6, Max = 2.5, Rounding = 2,
    Tooltip = "Higher = calls a clash sooner (slower exchanges count). Lower = only very fast ones.",
    Callback = function(v) SP.sensitivity = v end,
})
AS:AddSlider("ClashRangeBonus", {
    Text = "Clash range", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Tooltip = "Added to the speed-scaled clash range (18-50 studs).",
    Callback = function(v) SP.range_bonus = v end,
})
AS:AddSlider("ClashHold", {
    Text = "Hold", Default = 0.15, Min = 0, Max = 0.5, Rounding = 2, Suffix = "s",
    Tooltip = "Keeps spamming this long after the clash stops looking like one.",
    Callback = function(v) SP.hold = v end,
})
local ClashLabel = AS:AddLabel("Status: off", true)

-- ----- Player tab -----
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
    Text = "Auto jump", Default = false,
    Callback = function(v) AutoJump:setEnabled(v) end,
}):AddKeyPicker("AutoJumpKey", { Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump" })

-- ----- Status tab -----
local ST = Tabs.Status:AddLeftGroupbox("Live", "activity")
local L_capture = ST:AddLabel("Capture: idle", true)
local L_last = ST:AddLabel("Last parry: none", true)
local L_clash = ST:AddLabel("Auto spam: off", true)
local L_rate = ST:AddLabel("Spam rate: 0/s", true)
local L_ping = ST:AddLabel("Ping: -", true)
local L_curve = ST:AddLabel("Curve: Camera", true)
local SB = Tabs.Status:AddRightGroupbox("Build", "info")
SB:AddLabel("Version: " .. SCRIPT_VERSION)
SB:AddLabel("Idle = nothing connected. The engine runs only while a parry/spam feature is on.", true)

StatusHook = function(s)
    if not s then
        L_capture:SetText("Capture: idle (engine off)")
        L_clash:SetText("Auto spam: off")
        L_rate:SetText("Spam rate: 0/s")
        SpamRateLabel:SetText("Actual: 0/s")
        ClashLabel:SetText("Status: off")
        return
    end
    if not Library.Toggled then return end
    L_capture:SetText("Capture: " .. s.armed)
    L_last:SetText("Last parry: " .. s.last)
    L_clash:SetText("Auto spam: " .. s.clash)
    L_rate:SetText(("Spam rate: %d/s"):format(math.floor(s.rate + 0.5)))
    L_ping:SetText(("Ping: %dms"):format(math.floor(s.ping + 0.5)))
    L_curve:SetText("Curve: " .. s.curve)
    SpamRateLabel:SetText(("Actual: %d/s"):format(math.floor(s.rate + 0.5)))
    ClashLabel:SetText("Status: " .. s.clash)
end

-- ---------------------------------------------------------------------------
-- Unload.
-- ---------------------------------------------------------------------------
Library:OnUnload(function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    Engine.users = {}
    pcall(Engine.stop)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end)

genv.__BladeBallShutdown = function()
    Engine.users = {}
    pcall(Engine.stop)
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

Library:Notify({ Title = "Blade Ball", Description = "Rewrite " .. SCRIPT_VERSION .. " loaded. Idle = inert.", Time = 4 })

end)

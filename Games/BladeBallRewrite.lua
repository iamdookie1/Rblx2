-- Blade Ball -- clean rewrite
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else -- no game remotes, no
--   RunService connections, no hooks, no module requires, no remote-folder
--   resolve. One Engine owns every parry/spam connection; it starts with the
--   first parry/spam feature and tears everything down with the last. Every
--   other feature (detections, cosmetics, ESP, overlays, skins...) owns its own
--   connections and releases them when turned off. All off == UI-only footprint.
--
-- Installments: 1 foundation + Auto Jump | 2 capture core | 3 prediction, target
-- modes, instant retarget | 4 triggerbot, pre-parry, curves, spam + clash |
-- 5 (this file):
--   * anti curve v3: three independent arrival estimators (proportional homing
--     sim with a learned gain, constant-turn sim, and a model-free one from the
--     ball's real closing speed + acceleration) -> median, so one wrong model
--     can't fire the parry. Direction-aware danger zone (0.4's speed-scaled one
--     parried curving balls far too early). "Dot" mode as an alternative.
--   * spam that knows when to stop: auto spam ends the moment the exchange does
--     (third player, partner gone/out of range, ball left, slowed, not returned);
--     manual spam only fires while a ball is actually a threat (Smart stop)
--   * mobile manual-spam orb (tap to toggle, drag to move);
--     no on-screen UI on PC
--   * everything else: auto-parry Keypress mode, random curve, auto ability,
--     cooldown protection, Infinity / Death Slash / Time Hole / Phantom /
--     Slashes of Fury detection, avatar changer, headless, korblox, ball velocity
--     and ping overlays, ability ESP, skin changer, no render, unlock all, parry log

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.5.2"

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
local HttpService = cloneref(game:GetService('HttpService'))
local CoreGui = cloneref(game:GetService('CoreGui'))
local Debris = cloneref(game:GetService('Debris'))
local LocalPlayer = Players.LocalPlayer
local clock_ = os.clock
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
-- on-screen controls only on touch devices with no keyboard (no UI on PC)
local touchUI = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- every GUI we make goes in the executor's hidden container
local function hui()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and typeof(h) == 'Instance' then return h end
    return CoreGui
end
local function getRoot()
    local char = LocalPlayer.Character
    return char and char.PrimaryPart
end

-- ---------------------------------------------------------------------------
-- Feature framework: a feature owns its connections, instances and loops;
-- turning it off releases all of them.
-- ---------------------------------------------------------------------------
local Features = {}
local function Feature(name)
    local f = { name = name, on = false, _conns = {}, _insts = {}, _token = nil }
    function f:connect(signal, fn)
        local c = signal:Connect(function(...)
            if not is_live() then return end
            fn(...)
        end)
        self._conns[#self._conns + 1] = c
        return c
    end
    function f:own(inst) self._insts[#self._insts + 1] = inst; return inst end
    -- a loop that lives exactly as long as this activation of the feature
    function f:loop(interval, fn)
        local token = self._token
        task.spawn(function()
            while self.on and self._token == token and is_live() do
                pcall(fn)
                task.wait(interval)
            end
        end)
    end
    function f:alive(token) return self.on and self._token == token and is_live() end
    function f:release()
        for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
        for _, i in ipairs(self._insts) do pcall(function() i:Destroy() end) end
        self._conns, self._insts = {}, {}
    end
    function f:setEnabled(v)
        v = v and true or false
        if v == self.on then return end
        self.on = v
        if v then
            self._token = {}
            if self.start then pcall(self.start) end
        else
            self._token = nil
            if self.stop then pcall(self.stop) end
            self:release()
        end
    end
    Features[name] = f
    return f
end

-- ===========================================================================
-- PARRY + SPAM CORE (defines only; touches the game only after resolve())
-- ===========================================================================
local Parry = {}

-- ===========================================================================
-- PARRY ANIMATION (mirrors the game's own block action, so remote parries and
-- spam look like real presses). Defines only; the game's SwordAPI folder is read
-- the first time a swing is actually played.
--   * which tracks: every animation in the sword's set (the skin's set while the
--     skin changer is on) tagged Parry or GrabParry, picked by attribute;
--   * how: loaded once per animator with the Animation's attributes copied onto
--     the track (PlaySpeed, PlayFadeTime, StopFadeTime...) -- the game's success
--     handler finds what to stop by those, so block and success swing never stack;
--   * when: like the game, a new block starts only once the last one landed
--     (ParrySuccess) or its 1.3s cooldown ran out, and after a landed parry it
--     waits for the success swing to show and the ball to be back on you. So spam
--     at hundreds a second reads as block -> success swing -> block, exactly what
--     a real held key looks like, instead of restarting the swing every few ms.
-- ===========================================================================
local Anim = { enabled = true, spam = true, skin = nil }
do
    local BLOCK_COOLDOWN, SWING_SHOW = 1.3, 0.08
    local info_cache = {}
    local own_tracks = setmetatable({}, { __mode = 'k' }) -- animator -> {[Animation] = track}
    local r15_clones = {}
    local own_swing = setmetatable({}, { __mode = 'k' })  -- track -> when we played it
    local gate = { last = -math.huge, landed = true, landed_at = -math.huge }
    local success_at, grab_track = -math.huge, nil
    local function sword_info(char)
        local name = (Anim.skin and Anim.skin()) or char:GetAttribute("CurrentlyEquippedSword") or ""
        local info = info_cache[name]
        if info then return info end
        info = { collection = "Default" }
        if name ~= "" then
            local ok, data = pcall(function() return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(name) end)
            if ok and type(data) == "table" and data.AnimationType then info.collection = data.AnimationType end
        end
        info_cache[name] = info
        return info
    end
    local function find_animations(info)
        local list = {}
        local ok, folder = pcall(function()
            local col = ReplicatedStorage.Shared.SwordAPI:FindFirstChild("Collection")
            return col and (col:FindFirstChild(info.collection) or col:FindFirstChild("Default"))
        end)
        if ok and folder then
            for _, anim in ipairs(folder:GetChildren()) do
                if anim:IsA("Animation") and (anim:GetAttribute("Parry") or anim:GetAttribute("GrabParry")) then
                    list[#list + 1] = anim
                end
            end
        end
        return list
    end
    local function load_track(animator, humanoid, anim)
        local per = own_tracks[animator]
        if not per then per = {}; own_tracks[animator] = per end
        local track = per[anim]
        if track then return track end
        local source = anim
        local r15 = anim:GetAttribute("R15Id")
        if r15 and humanoid.RigType == Enum.HumanoidRigType.R15 then
            source = r15_clones[anim]
            if not source then source = Instance.new("Animation"); source.AnimationId = r15; r15_clones[anim] = source end
        end
        track = animator:LoadAnimation(source)
        for k, v in pairs(anim:GetAttributes()) do pcall(track.SetAttribute, track, k, v) end
        per[anim] = track
        return track
    end
    local function play_block()
        local char = LocalPlayer.Character
        if not char or char:GetAttribute("InOverdriveMech") then return end
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if not animator then return end
        local now = os.clock()
        -- the last block didn't land: no new one inside the game's block cooldown
        if not gate.landed and now - gate.last < BLOCK_COOLDOWN then return end
        -- it landed: let the success swing show, and start the next block when the
        -- ball is back on us (give up waiting after the cooldown)
        if gate.landed and gate.landed_at > gate.last then
            if now - gate.landed_at < SWING_SHOW then return end
            if not Parry.ballOnMe() and now - gate.landed_at < BLOCK_COOLDOWN then return end
        end
        gate.last, gate.landed = now, false
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then track:Stop(track:GetAttribute("StopFadeTime")) end
        end
        local parry_time = char:GetAttribute("ParryTime") or 0
        for _, anim in ipairs(find_animations(sword_info(char))) do
            local ok, track = pcall(load_track, animator, humanoid, anim)
            if ok and track then
                local speed = track:GetAttribute("PlaySpeed") or 1
                own_swing[track] = os.clock()
                track:Play(track:GetAttribute("PlayFadeTime"), track:GetAttribute("PlayWeight"), speed)
                grab_track = track
                local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
                if left > parry_time then parry_time = left end
            end
        end
        pcall(char.SetAttribute, char, "ParryTime", parry_time)
    end
    -- a single parry (auto parry, triggerbot, pre-parry)
    function Anim.block() if Anim.enabled then pcall(play_block) end end
    -- spam: same gate, so it plays like a held key
    function Anim.spamBlock() if Anim.enabled and Anim.spam then pcall(play_block) end end
    function Anim.onSuccess()
        local now = os.clock()
        success_at, gate.landed, gate.landed_at = now, true, now
        -- the game plays its own success swing now; take our block pose off it
        if grab_track then pcall(function() grab_track:Stop(grab_track:GetAttribute("StopFadeTime")) end) end
    end
    function Anim.reset() gate.last, gate.landed, gate.landed_at, grab_track = -math.huge, true, -math.huge, nil end
    -- a swing the GAME started from a real press (yours, tap to block, a capture
    -- press) -- not our own swing and not a landed parry's success swing
    function Anim.isGamePress(track)
        if track:GetAttribute("SuccessParry") then return false end
        if not (track:GetAttribute("Parry") or track:GetAttribute("GrabParry")) then return false end
        local now = os.clock()
        if now - success_at < 0.35 then return false end
        local at = own_swing[track]
        if at and now - at < 0.25 then return false end
        return true
    end
end

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

    local S = {
        autoparry = false, triggerbot = false, parry_mode = "Remote",
        preparry = false, preparry_range = 20, hp_preparry = false,
        anticurve = "Smart", dot_threshold = 0.5, curve_bias = 0.5,
        accuracy = 50, accuracy_base = 50, divisor_multiplier = 1.1, timing_mult = 1,
        extra_distance = 0, ping_compensation = false, retry_delay = 1,
        random_accuracy = false, random_accuracy_amount = 10,
        target_mode = 1, curve_mode = 1, random_curve = false,
        auto_ability = false, cooldown_protection = false,
    }
    local SP = {
        manual = false, auto = false, mode = "Remote", max_rate = 1000, upload_kbps = 0, idle_rate = 20,
        smart = true, range_bonus = 0, hold = 0.15, sensitivity = 1.3, predictive = true,
        factor = 1, guard_at = -1,
    }
    -- detection state (written by the detection features, read here)
    local Det = { infinity = false, deathslash = false, timehole = false, slashes = false, phantom_until = 0 }
    Parry.S, Parry.SP, Parry.Det, Parry.targetNames, Parry.curveNames = S, SP, Det, TARGET_NAMES, CURVE_NAMES

    -- parry log: a ring buffer the Status tab drains
    local LOG, log_new = {}, 0
    local function logp(text)
        LOG[#LOG + 1] = text
        if #LOG > 60 then table.remove(LOG, 1) end
        log_new = math.min(log_new + 1, 60)
    end
    function Parry.drainLog()
        local out = {}
        for i = #LOG - log_new + 1, #LOG do if LOG[i] then out[#out + 1] = LOG[i] end end
        log_new = 0
        return out
    end

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
    Parry.pingMs = pingMs
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
    local function blocked_by_detection()
        return Det.infinity or Det.deathslash or Det.timehole or Det.slashes or clock_() < Det.phantom_until
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

    -- ---------- timing ----------
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
        if S.random_curve then mode = CURVE_NAMES[math.random(1, #CURVE_NAMES)] end
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
            logp("captured the parry packet (" .. capture_method() .. ")")
            return true
        end
    end
    -- Hook up for one capture press, at most `window` seconds; it comes down the
    -- frame the parry is caught, whichever is first.
    local function arm(window)
        if Core.cap or not is_live() then return false end
        H.want, H.until_t = true, clock_() + (window or 0.12)
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
    -- Lobby training sends the same parry packet as a match (its screen points
    -- are the trainees + dummies, built in build_screen_points), so capture there
    -- too. Plain lobby parry (no training) is still skipped.
    local function in_lobby_training()
        if not LocalPlayer:GetAttribute("LobbyTraining") then return false end
        local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
        return char ~= nil and dead ~= nil and char.Parent == dead
    end
    local Prime = { last = 0, since = nil, dry = 0 }
    local function prime_remote()
        if not is_live() then return end
        if Core.cap then Prime.dry = 0; return end
        if not (in_match() or in_lobby_training()) or not canParryNow() then Prime.since = nil; return end
        local now = clock_()
        Prime.since = Prime.since or now
        if now - Prime.since < 1 or now - Prime.last < 1.4 then return end
        if Prime.dry >= 3 then
            if now - Prime.last < 20 then return end
            Prime.dry = 0
        end
        Prime.last = now
        -- Short hook window: ~4 frames (0.08s floor, 0.2s at low FPS) -- the game
        -- sends its parry a frame or two after the press. Only if a press comes up
        -- dry does the next one get longer (x1.5, x2), capped at 0.3s.
        local window = math.min(math.clamp(frame_dt * 4, 0.08, 0.2) * (1 + 0.5 * Prime.dry), 0.3)
        if arm(window) then
            Prime.dry = Prime.dry + 1
            pressBlockKey(); gate_start()
            logp(("capture press %d (%s, hook up <= %.2fs%s)"):format(Prime.dry, capture_method(), window,
                in_lobby_training() and ", training" or ""))
        end
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

    -- ---------- abilities (auto ability / cooldown protection) ----------
    local ABILITY_PARRY = { "Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash" }
    local ABILITY_PROTECT = { "Raging Deflection", "Rapture", "Calming Deflection" }
    local function ability_ready()
        local ok, ready = pcall(function() return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5 end)
        return ok and ready
    end
    local function has_ability(list)
        local abilities = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Abilities")
        if not abilities then return false end
        for _, name in ipairs(list) do
            local ability = abilities:FindFirstChild(name)
            if ability then
                local ok, enabled = pcall(function() return ability.Enabled end)
                if ok and enabled then return true end
            end
        end
        return false
    end
    local function ability_press()
        local ok = pcall(function() Remotes.AbilityButtonPress:Fire() end)
        return ok
    end
    Parry.abilityPress = ability_press
    local function try_ability()
        if not (S.auto_ability or S.cooldown_protection) or not Remotes or not ability_ready() then return false end
        if S.auto_ability and has_ability(ABILITY_PARRY) then
            if not ability_press() then return false end
            task.delay(2.432, function()
                local ds = Remotes and Remotes:FindFirstChild("DeathSlashShootActivation")
                if ds then pcall(function() ds:FireServer(true) end) end
            end)
            return true
        end
        if S.cooldown_protection and has_ability(ABILITY_PROTECT) then return ability_press() end
        return false
    end

    -- ---------- ball physics ----------
    local tracked = setmetatable({}, { __mode = 'k' })
    local ball_conns = {}
    local function ball_velocity(ball)
        local z = ball:FindFirstChild('zoomies')
        return z and z.VectorVelocity or ball.AssemblyLinearVelocity
    end
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

    -- ===================== ANTI CURVE v3 =====================
    -- Per pass we measure, every ~30ms:
    --   w     how fast the ball's direction is swinging (rad/s);
    --   k     the homing GAIN: swing rate / sin(angle off the line to us). A ball
    --         steered by "lerp toward the target" turns at k*sin(angle), so k is
    --         constant along its path even though the swing rate isn't;
    --   away  the swing is carrying it AWAY from us (curve bait / wide curve);
    --   distance samples -> its real closing speed and how fast that's rising.
    -- Three arrival estimates are made from that, each wrong in different
    -- situations, and the MEDIAN is used, never less than flying straight in.
    local K_DEFAULT, K_MIN, K_MAX = 5, 0.8, 40
    local W_DEFAULT, W_MIN = 4, 1
    local SIM_DT = 1 / 120
    local function track_homing(st, dir, want, dist, now)
        local h = st.hm
        if not h then
            h = { t = now, dir = dir, want = want, k = nil, w = nil, away = false, n = 0, samples = { { t = now, d = dist } } }
            st.hm = h
            return h
        end
        local dt = now - h.t
        if dt >= 0.03 then
            local turned = math.acos(math.clamp(h.dir:Dot(dir), -1, 1))
            local omega = turned / dt
            local th = math.acos(math.clamp(h.dir:Dot(h.want), -1, 1))
            local perp = h.want - h.dir * h.dir:Dot(h.want)
            local toward = perp.Magnitude < 1e-4 or (dir - h.dir):Dot(perp) >= 0
            if turned > 2e-3 then
                if toward then
                    h.away = false
                    h.w = h.w and math.max(h.w * 0.5 + omega * 0.5, omega * 0.85) or omega
                    if th > 0.06 then
                        local ks = omega / math.max(math.sin(th), 0.15)
                        h.k = h.k and (h.k * 0.4 + ks * 0.6) or ks
                    end
                elseif omega > 0.5 then
                    h.away = true
                end
            end
            h.t, h.dir, h.want, h.n = now, dir, want, h.n + 1
            local s = h.samples
            s[#s + 1] = { t = now, d = dist }
            if #s > 4 then table.remove(s, 1) end
        end
        return h
    end
    -- model-free: extrapolate the measured closing speed and its rise (capped at the ball's speed)
    local function radial_eta(h, rem, speed)
        local s = h.samples
        local n = #s
        if n < 3 then return nil end
        local a, b, c = s[n - 2], s[n - 1], s[n]
        local dt1, dt2 = b.t - a.t, c.t - b.t
        if dt1 <= 0 or dt2 <= 0 then return nil end
        local c1, c2 = (a.d - b.d) / dt1, (b.d - c.d) / dt2
        if c2 <= 1 then return nil end
        c2 = math.min(c2, speed)
        local acc = (c2 - c1) / ((dt1 + dt2) * 0.5)
        if acc > 1 then
            local t1 = (speed - c2) / acc
            local d1 = c2 * t1 + 0.5 * acc * t1 * t1
            if d1 >= rem then return (math.sqrt(c2 * c2 + 2 * acc * rem) - c2) / acc end
            return t1 + (rem - d1) / speed
        end
        return rem / c2
    end
    -- proportional homing: each step the direction lerps toward us by k*dt
    local function sim_prop(pos, vel, target, gap, k, accel, horizon)
        local speed = vel.Magnitude
        if speed < 1 then return nil end
        local dir, t = vel / speed, 0
        local a = math.clamp(k * SIM_DT, 0, 1)
        while t < horizon do
            local to = target - pos
            local dist = to.Magnitude
            if dist <= gap then return t end
            local want = to / dist
            local mixed = dir + (want - dir) * a
            if mixed.Magnitude < 1e-3 then
                mixed = dir:Cross(Vector3.yAxis)
                if mixed.Magnitude < 1e-3 then mixed = want end
            end
            dir = mixed.Unit
            speed = speed + accel * SIM_DT
            local move = speed * SIM_DT
            if dir:Dot(want) > 0 and move >= dist - gap then return t + (dist - gap) / speed end
            pos = pos + dir * move
            t = t + SIM_DT
        end
        return nil
    end
    -- constant turn rate toward us
    local function sim_const(pos, vel, target, gap, turn, accel, horizon)
        local speed = vel.Magnitude
        if speed < 1 then return nil end
        local dir, t = vel / speed, 0
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
    local function median3(a, b, c)
        if a > b then a, b = b, a end
        if c < a then return a elseif c > b then return b end
        return c
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
    -- the ball that matters: the one on us, else the first live one
    function Parry.ballOnMe()
        for _, b in ipairs(get_live_balls()) do if b:GetAttribute('target') == me then return true end end
        return false
    end
    function Parry.mainBall()
        local balls = get_live_balls()
        for _, b in ipairs(balls) do if b:GetAttribute('target') == me then return b end end
        return balls[1]
    end
    Parry.ballVelocity = ball_velocity

    -- ---------- ball tracking ----------
    local on_retarget, on_velocity -- set below
    local function open_pass(st)
        st.pass_open, st.parried, st.landed, st.parry_until = true, false, false, 0
        st.spd, st.hm = nil, nil
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
    -- START: a player within clash range AND (a quick hand-off, or the ball lands
    -- inside your reaction time, or you two are trading landed parries fast, or --
    -- predictive -- you just sent it to them and their return would be too fast).
    -- KEEP while it stays between you two (25-30% slack) plus the Hold tail.
    -- STOP at once on any hard sign the exchange is over (clash_stop): the ball
    -- goes to a third player, disappears, flies off, slows right down, or they
    -- don't send it back in time; or the partner dies / leaves range. A stopped
    -- ball then cools for 0.25s so a stale reading can't restart it.
    local AutoSpam = { active_until = 0, ball = nil, partner = nil, reason = nil, was_active = false,
        peak = 0, cool_ball = nil, cool_until = 0 }
    local parry_all = {}
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
    -- partner, why, strong -- or nil. held = this ball is the running clash.
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
            if handoffs >= 1 then return partner, "quick hand-off", true end
            local eta = (ball.Position - root.Position).Magnitude / speed
            if eta <= react * (sens - 0.1) + 0.08 then return partner, ("lands in %.2fs, too fast to react"):format(eta), true end
            if trading and speed >= 30 then return partner, "trading parries", false end
            if held then return partner, "exchange on", false end
            return nil
        end
        if held and owners[1] and now - owners[1].t <= tempo then return partner, "exchange on", false end
        local to_them = their.Position - ball.Position
        local d_them = to_them.Magnitude
        if not (d_them < 6 or velocity:Dot(to_them / d_them) > speed * 0.3) then return nil end
        if handoffs >= 2 then return partner, ("%d quick hand-offs"):format(handoffs), true end
        if trading and too_fast then return partner, "trading parries", false end
        local from_me = owners[2] and owners[2].name == me
        if SP.predictive and from_me and too_fast and return_comes_to_us(their, root, partner, gap) then
            return partner, ("predicted: return in %.2fs, you need %.2fs"):format(back, react), false
        end
        return nil
    end
    -- a hard reason the running exchange is over, or nil
    local function clash_stop(ball, root, now)
        if not ball.Parent or not ball:GetAttribute('realBall') then return "ball gone" end
        local partner = AutoSpam.partner
        local target = ball:GetAttribute('target')
        if type(target) == 'string' and target ~= '' and target ~= me and target ~= partner then
            return "ball went to " .. target
        end
        local their = character_root(partner)
        if not their then return "partner gone" end
        local speed = math.max(ball_velocity(ball).Magnitude, 1)
        AutoSpam.peak = math.max(AutoSpam.peak, speed)
        local range = clash_range(speed)
        local gap = (their.Position - root.Position).Magnitude
        if gap > range * 1.4 then return "partner out of range" end
        local bpos = ball.Position
        if math.min((bpos - root.Position).Magnitude, (bpos - their.Position).Magnitude) > range * 1.5 + 10 then
            return "ball left the exchange"
        end
        if speed < 60 and speed < AutoSpam.peak * 0.35 then return "ball slowed down" end
        local st = tracked[ball]
        if st then
            local o = ball_owners(st)[1]
            if o and o.name == partner and o.t > 0 then
                local limit = math.max(math.clamp(gap / speed * 2 + reach_time() * 2 + 0.15, 0.3, 0.9) * 2, 0.6)
                if now - o.t > limit then return "they stopped returning it" end
            end
        end
        return nil
    end
    local function can_auto_spam(root)
        return SP.auto and root and not root:FindFirstChild('SingularityCape') and canParryNow()
            and not in_training() and not blocked_by_detection()
    end
    local function mark_clash(ball, now, partner, why)
        if AutoSpam.ball ~= ball or AutoSpam.partner ~= partner then
            logp(("auto spam ON vs %s (%s)"):format(tostring(partner), why))
            AutoSpam.peak = 0
        end
        AutoSpam.ball, AutoSpam.partner = ball, partner
        AutoSpam.active_until = now + math.clamp(SP.hold or 0.15, 0, 0.5) + 0.02
        AutoSpam.reason = ("vs %s (%s)"):format(partner, why)
    end
    local function end_clash(why, cool)
        if AutoSpam.ball then
            logp("auto spam OFF: " .. tostring(why))
            if cool then AutoSpam.cool_ball, AutoSpam.cool_until = AutoSpam.ball, clock_() + 0.25 end
        end
        AutoSpam.active_until, AutoSpam.reason, AutoSpam.ball, AutoSpam.partner = 0, nil, nil, nil
    end
    local function has_clash(ball, now) return AutoSpam.ball == ball and now < AutoSpam.active_until end
    local function cooling(ball, now) return ball == AutoSpam.cool_ball and now < AutoSpam.cool_until end
    local function clash_check(ball, now)
        local root = getRoot()
        if not can_auto_spam(root) then return false end
        local held = AutoSpam.ball == ball
        local partner, why, strong = clash_on(ball, root, now, held)
        if not partner or (not held and cooling(ball, now) and not strong) then return false end
        mark_clash(ball, now, partner, why)
        return true
    end
    local function auto_spam_evaluate(now)
        if not SP.auto then if AutoSpam.ball then end_clash("auto spam off") end; return end
        local root = getRoot()
        if not can_auto_spam(root) then if AutoSpam.ball then end_clash("can't spam here") end; return end
        local cur = AutoSpam.ball
        if cur then
            local why = clash_stop(cur, root, now)
            if why then
                end_clash(why, true)
            else
                local partner, reason = clash_on(cur, root, now, true)
                if partner then mark_clash(cur, now, partner, reason); return end
                if now < AutoSpam.active_until then return end -- the Hold tail
                end_clash("clash over", true)
            end
        end
        for _, ball in ipairs(get_live_balls()) do
            local partner, why, strong = clash_on(ball, root, now, false)
            if partner and (strong or not cooling(ball, now)) then mark_clash(ball, now, partner, why); return end
        end
    end

    -- ===================== SPAM PUMP =====================
    local Pump = { credit = 0, last = clock_(), on = false, frame = 0, frame_fires = 0, fired_frame = -1, waiting = false }
    local SpamMeter = { count = 0, since = clock_(), rate = 0 }
    local function current_source(now)
        if SP.manual then return "manual" end
        if SP.auto and now < AutoSpam.active_until then return "auto" end
        return nil
    end
    -- a ball is a threat right now: on us, close to us, or heading in within reach
    local function spam_focus()
        local root = getRoot()
        if not root then return false end
        local horizon = reach_time() + 0.25
        for _, ball in ipairs(get_live_balls()) do
            local st = get_ball_state(ball)
            if st.target == me then return true end
            local vel = ball_velocity(ball)
            local speed = vel.Magnitude
            local off = root.Position - ball.Position
            local d = off.Magnitude
            if d <= 20 + speed * 0.05 then return true end
            if speed > 1 and d > 0.01 and (vel / speed):Dot(off / d) > 0.3 and d / speed <= horizon then return true end
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
    local function fire_one()
        if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
        if SP.mode == "Keypress" and Pump.frame_fires >= 1 then return false end
        local ok
        if SP.mode == "Keypress" then ok = pressBlockKey() else ok = send(true) == "sent" end
        Pump.frame_fires = Pump.frame_fires + 1
        if ok then SpamMeter.count = SpamMeter.count + 1 end
        return ok
    end
    local function spam_tick(now)
        local elapsed = math.min(now - Pump.last, 0.05)
        Pump.last = now
        local span = now - SpamMeter.since
        if span >= 0.5 then SpamMeter.rate, SpamMeter.count, SpamMeter.since = SpamMeter.count / span, 0, now end
        local source = current_source(now)
        if not source or not LocalPlayer.Character then Pump.credit, Pump.on, Pump.waiting = 0, false, false; return end
        local focus = spam_focus()
        -- Smart stop: manual spam holds fire while nothing is a threat
        if source == "manual" and SP.smart and not focus then Pump.credit, Pump.on, Pump.waiting = 0, false, true; return end
        Pump.waiting = false
        local rate = math.clamp(SP.max_rate or 1000, 1, 2000) * upload_factor(now)
        if SP.mode == "Keypress" then rate = math.min(rate, 1 / frame_dt) end
        if not focus then rate = math.min(rate, SP.idle_rate) end
        rate = math.max(rate, 1)
        if Pump.on then Pump.credit = math.min(Pump.credit + elapsed * rate, 1 + rate * 0.015)
        else Pump.credit, Pump.on = 1, true end
        local sent = false
        while Pump.credit >= 1 - 1e-6 do
            Pump.credit = Pump.credit - 1
            local ok = fire_one()
            if ok then sent = true end
            if ok == false and SP.mode == "Keypress" then Pump.credit = math.min(Pump.credit, 0); break end
        end
        -- one animation call per tick, through the held-key gate (Keypress mode:
        -- the game animates its own presses)
        if sent and SP.mode == "Remote" then Anim.spamBlock() end
    end
    local function spam_instant()
        local source = current_source(clock_())
        if not source or not LocalPlayer.Character then return end
        if source == "manual" and SP.smart and not spam_focus() then return end
        Pump.credit, Pump.on = math.max(Pump.credit - 1, -1), true
        if fire_one() and SP.mode == "Remote" then Anim.spamBlock() end
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
        local how
        if try_ability() then how = "ability"
        elseif S.parry_mode == "Keypress" then
            if not gate_open() or not canParryNow() then return false end
            pressBlockKey(); gate_start(); how = "key"
        else
            if send(false) ~= "sent" then return false end
            how = "remote"
            Anim.block() -- a remote parry has no swing of its own; the key and abilities do
        end
        Core.last_parry = { t = now, via = via, info = info }
        mark_parried(st, now)
        if info then
            logp(("%s [%s] dist %.0f spd %.0f head %.2f eta %.2f lead %.2f%s"):format(via, how, info.dist or 0,
                info.speed or 0, info.heading or 0, math.min(info.eta or 0, 9.99), info.lead or 0,
                info.k and (" k %.1f"):format(info.k) or ""))
        else
            logp(("%s [%s]"):format(via, how))
        end
        return true
    end

    -- The decision for a ball on us. via: "retarget" (it just turned to us),
    -- "velocity" (its new direction just replicated), or nil (a frame point).
    local function decide(ball, st, root, now, via)
        if pass_busy(st, now) or has_clash(ball, now) or blocked_by_detection() then return end
        local rpos, bpos = root.Position, ball.Position
        local vel = ball_velocity(ball)
        local speed = vel.Magnitude
        if speed < 1 then return end
        local offset = rpos - bpos
        local dist = offset.Magnitude
        if dist < 0.01 then return end
        local dir, want = vel / speed, offset / dist
        local heading = dir:Dot(want)
        local W = parry_window() or 0.5
        local reach = reach_time()
        local gap = contact_gap(ball)
        local rem = math.max(dist - gap, 0)
        local accel = speed_gain(st, speed, now)
        local straight = time_to_contact(dist, gap, speed, accel) -- the earliest it could possibly land
        local h = track_homing(st, dir, want, dist, now)
        local lead = math.min(fire_lead(speed), reach + W * 0.85)
        local info = { speed = speed, dist = dist, heading = heading, lead = lead, eta = straight }
        -- touching, or coming dead at us and already inside our reach time: now or
        -- never. Only near-straight balls take this shortcut -- one pointing half
        -- sideways can look "inside reach" while it actually curves past (the
        -- bench caught exactly that); those go through the estimators below.
        if rem <= 3 or (straight <= reach and heading >= 0.9) then
            return fire(st, now, via == "retarget" and "instant retarget" or "point blank", info)
        end
        if via == "retarget" then
            -- its velocity may still be the old one at the flip: fire straight off
            -- the event only if it's clearly coming at us; else the velocity update
            -- (a moment later) or the next frame point decides.
            if heading >= 0.5 and straight <= lead then return fire(st, now, "instant retarget", info) end
            return
        end
        local mode = S.anticurve
        local eta = straight
        if mode == "Off" then
            if heading <= 0 then return end
        elseif mode == "Dot" then
            -- classic: wait until it points at us, then fire on time or distance
            local thr = math.clamp((S.dot_threshold or 0.5) - pingMs() / 1000, -0.2, 0.95)
            if heading < thr then return end
            if dist <= parry_distance(speed) then return fire(st, now, "auto parry (dot)", info) end
        elseif heading < 0.985 then
            -- SMART: median of three arrival estimates
            local horizon = lead + 0.35
            local k = h.away and K_MIN or math.clamp(h.k or K_DEFAULT, K_MIN, K_MAX)
            local w = h.away and W_MIN or math.max(h.w or W_DEFAULT, W_MIN)
            local e1 = sim_prop(bpos, vel, rpos, gap, k, accel, horizon) or math.huge
            local e2 = sim_const(bpos, vel, rpos, gap, w, accel, horizon) or math.huge
            local e3 = (not h.away) and radial_eta(h, rem, speed) or nil
            if e3 then
                eta = median3(e1, e2, e3)
            elseif e1 == math.huge or e2 == math.huge then
                eta = h.away and math.max(e1, e2) or math.min(e1, e2)
            else
                eta = (e1 + e2) * 0.5
            end
            eta = math.max(eta, straight)
            info.k = k
            -- curving: lean a little earlier -- inside the window early is safe, late is fatal
            lead = math.min(lead + W * 0.25 * (S.curve_bias or 0.5) * (1 - math.max(heading, 0)), reach + W * 0.85)
            info.lead = lead
        end
        info.eta = eta
        -- safety net: the classic distance trigger for a ball coming in nearly straight
        local net = heading >= 0.85 and dist <= parry_distance(speed) and straight <= reach + W * 0.85
        if eta <= lead or net then
            return fire(st, now, via == "velocity" and "auto parry (velocity)" or "auto parry", info)
        end
    end

    local function trigger(ball, st, now)
        if pass_busy(st, now) or has_clash(ball, now) or blocked_by_detection() then return end
        fire(st, now, "triggerbot", nil)
    end

    local function try_preparry(ball, st, root, now)
        if st.preparried then
            if now < st.preparry_until then return end
            st.preparried = false
        end
        if not (S.preparry or (S.hp_preparry and (Lag.avg or ping_s()) >= 0.08)) then return end
        if not Core.cap or blocked_by_detection() then return end
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
        if back > reach + frame_dt * 2 then return end
        local eta = d_them / speed + back
        local lead = fire_lead(speed)
        if eta > lead or has_clash(ball, now) then return end
        if send(false) == "sent" then
            Anim.block()
            local W, n2 = parry_window()
            st.preparried = true
            st.preparry_until = now + math.max((W or 0.5) + reach + 0.15, (n2 or 1.3) + 0.08)
            Core.last_parry = { t = now, via = "pre-parry", info = { eta = eta, lead = lead } }
            logp(("pre-parry: return in %.2fs, lead %.2fs, gap %.0f"):format(eta, lead, gap))
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
            if AutoSpam.ball == ball and type(new) == 'string' and new ~= '' and new ~= AutoSpam.partner then
                end_clash("ball went to " .. new, true)
            else
                clash_check(ball, now)
            end
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
            if Core.pending and now > Core.pending then
                Core.pending, Core.misses = nil, Core.misses + 1
                if Core.misses >= 2 then
                    Core.cap, Core.misses = nil, 0
                    logp("2 parries unanswered: capture went stale, taking a fresh one")
                end
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
            for _, ball in ipairs(get_live_balls()) do get_ball_state(ball) end
        end
        spam_tick(now)
    end

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
        Anim.onSuccess()
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
            if lp.info and lp.info.eta then last = last .. (" (eta %.2fs / lead %.2fs)"):format(math.min(lp.info.eta, 9.99), lp.info.lead or 0) end
        end
        local clash
        if not SP.auto then clash = "off"
        elseif clock_() < AutoSpam.active_until then clash = "SPAMMING " .. tostring(AutoSpam.reason)
        else clash = "watching for clashes" end
        local manual = not SP.manual and "off" or (Pump.waiting and "waiting for a threat" or "spamming")
        return {
            armed = Core.cap and ("armed (" .. capture_method() .. ")") or "not armed yet",
            last = last, clash = clash, manual = manual, rate = SpamMeter.rate, ping = pingMs(),
            curve = S.random_curve and "Random each parry" or (CURVE_NAMES[S.curve_mode] or "?"),
            detect = blocked_by_detection() and "PAUSED (ability detected)" or "clear",
        }
    end

    -- ---------- resolve / activate / deactivate ----------
    function Parry.resolve()
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
        return Remotes ~= nil and Alive ~= nil
    end
    function Parry.activate()
        active = Parry.resolve()
        return active
    end
    function Parry.deactivate()
        active = false
        pcall(unhook)
        for _, c in ipairs(ball_conns) do pcall(function() c:Disconnect() end) end
        ball_conns = {}
        for k in pairs(tracked) do tracked[k] = nil end
        end_clash("engine off")
        Pump.credit, Pump.on, Pump.waiting = 0, false, false
        Core.pending, Core.misses = nil, 0
        G.until_t, Prime.since, Prime.dry = 0, nil, 0
    end
    -- one parry outside the engine (Slashes of Fury): remote if armed, else the key
    function Parry.spamParry()
        if not Parry.resolve() then return false end
        if Core.cap and send(true) == "sent" then Anim.spamBlock(); return true end
        return pressBlockKey()
    end
    -- the game started a block swing from a real press (yours, a capture press):
    -- its lockout is running, so a remote parry now would only play the swing
    function Parry.gameSwing() gate_start() end
    function Parry.remotes() return Remotes end
    function Parry.spamRate() return SpamMeter.rate end
    function Parry.isMe(name) return name == me end
end

-- ===========================================================================
-- ENGINE: owner of every parry/spam connection.
-- ===========================================================================
local Library
local StatusHook, UiTick
local Engine = { users = {}, conns = {}, running = false, status_at = 0, tick_at = 0 }
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
    Engine.running = true -- before anything below that may run synchronously
    local R = Parry.remotes()
    pcall(function() econnect(R.ParrySuccess.OnClientEvent, Parry.onParrySuccess) end)
    pcall(function() econnect(R.ParrySuccessAll.OnClientEvent, Parry.onParryAll) end)
    pcall(function() econnect(R.NoobParryHappened.OnClientEvent, Parry.onNoobParry) end)
    pcall(function() econnect(R.M1Stop.Event, Parry.onM1Stop) end)
    for _, folder in ipairs(Parry.ballFolders()) do econnect(folder.ChildAdded, Parry.onBallAdded) end
    -- the game's own block swings (your presses, capture presses) start its
    -- lockout; seen on the animator, no hooks
    local function watch_animator(char)
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if not animator or not Engine.running then return end
            econnect(animator.AnimationPlayed, function(track)
                if Anim.isGamePress(track) then Parry.gameSwing() end
            end)
        end)
    end
    if LocalPlayer.Character then watch_animator(LocalPlayer.Character) end
    econnect(LocalPlayer.CharacterAdded, function(char) Anim.reset(); watch_animator(char) end)
    econnect(RunService.PreSimulation, function(dt) Parry.frame(dt, 1) end)
    econnect(RunService.Heartbeat, function()
        Parry.frame(nil, 2)
        local now = clock_()
        if UiTick and now - Engine.tick_at > 0.1 then Engine.tick_at = now; pcall(UiTick, Parry.spamRate()) end
        if StatusHook and now - Engine.status_at > 0.25 then Engine.status_at = now; pcall(StatusHook, Parry.status()) end
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
    if UiTick then pcall(UiTick, 0) end
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

-- ===========================================================================
-- MOBILE MANUAL-SPAM ORB (touch devices only). Tap to toggle spam on/off, drag
-- to move. The ring pulses and shows the live rate while it spams.
-- ===========================================================================
local Orb = {}
do
    local SP = Parry.SP
    local gui, button, ring, title, sub, pill
    local pressing, dragging = false, false
    local press_input, press_pos, start_abs = nil, nil, nil
    local press_conns = {}
    local IDLE, ACTIVE = Color3.fromRGB(110, 112, 128), Color3.fromRGB(0, 225, 130)
    local function set_spam(on) SP.manual = on and true or false end
    local function drop_press_conns()
        for _, c in ipairs(press_conns) do pcall(function() c:Disconnect() end) end
        press_conns = {}
    end
    local function paint(rate)
        if not button then return end
        local on = SP.manual
        ring.Color = on and ACTIVE or IDLE
        ring.Transparency = on and (0.1 + 0.4 * (0.5 + 0.5 * math.sin(clock_() * 12))) or 0.3
        title.TextColor3 = on and ACTIVE or Color3.fromRGB(235, 235, 240)
        if on then sub.Text = (rate and rate >= 1) and (math.floor(rate + 0.5) .. "/s") or "waiting"
        else sub.Text = "tap" end
        pill.Text = on and "ON" or "OFF"
        pill.BackgroundColor3 = on and Color3.fromRGB(0, 150, 95) or Color3.fromRGB(32, 33, 40)
    end
    function Orb.tick(rate) paint(rate) end
    -- a press that didn't turn into a drag toggles spam
    local function release_press()
        pressing = false
        drop_press_conns()
        if dragging then dragging = false
        else set_spam(not SP.manual) end
        paint()
    end
    function Orb.show()
        if gui or not touchUI then return end
        gui = Instance.new("ScreenGui")
        gui.Name = "BB_SpamOrb"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 9999
        button = Instance.new("TextButton")
        button.Name = "Orb"; button.Text = ""; button.AutoButtonColor = false
        button.Size = UDim2.fromOffset(86, 86); button.AnchorPoint = Vector2.new(0.5, 0.5)
        button.Position = UDim2.new(0.86, 0, 0.55, 0)
        button.BackgroundColor3 = Color3.fromRGB(16, 17, 22); button.BackgroundTransparency = 0.12
        button.Parent = gui
        Instance.new("UICorner", button).CornerRadius = UDim.new(1, 0)
        ring = Instance.new("UIStroke", button); ring.Thickness = 3; ring.Color = IDLE
        local core = Instance.new("Frame")
        core.Size = UDim2.fromOffset(62, 62); core.AnchorPoint = Vector2.new(0.5, 0.5)
        core.Position = UDim2.fromScale(0.5, 0.5); core.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
        core.BackgroundTransparency = 0.05; core.Active = false; core.Parent = button
        Instance.new("UICorner", core).CornerRadius = UDim.new(1, 0)
        local grad = Instance.new("UIGradient", core)
        grad.Rotation = 90
        grad.Color = ColorSequence.new(Color3.fromRGB(48, 50, 62), Color3.fromRGB(20, 21, 27))
        title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1; title.Size = UDim2.new(1, 0, 0, 20); title.Position = UDim2.new(0, 0, 0.5, -14)
        title.Font = Enum.Font.GothamBlack; title.TextSize = 15; title.Text = "SPAM"
        title.TextColor3 = Color3.fromRGB(235, 235, 240); title.Parent = button
        sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1; sub.Size = UDim2.new(1, 0, 0, 14); sub.Position = UDim2.new(0, 0, 0.5, 5)
        sub.Font = Enum.Font.GothamMedium; sub.TextSize = 11; sub.Text = "tap"
        sub.TextColor3 = Color3.fromRGB(170, 172, 185); sub.Parent = button
        pill = Instance.new("TextLabel")
        pill.Size = UDim2.fromOffset(58, 18); pill.AnchorPoint = Vector2.new(0.5, 1)
        pill.Position = UDim2.new(0.5, 0, 0, -6); pill.Font = Enum.Font.GothamBold; pill.TextSize = 10
        pill.Text = "OFF"; pill.TextColor3 = Color3.fromRGB(240, 240, 245)
        pill.BackgroundColor3 = Color3.fromRGB(32, 33, 40); pill.Parent = button
        Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
        button.InputBegan:Connect(function(input)
            local t = input.UserInputType
            if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
            if pressing then return end
            pressing, dragging = true, false
            press_input, press_pos = input, input.Position
            start_abs = button.AbsolutePosition + button.AbsoluteSize * 0.5
            -- move / release are tracked only while a press is live
            press_conns[#press_conns + 1] = UserInputService.InputChanged:Connect(function(i)
                if not pressing then return end
                if i ~= press_input and i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                local d = i.Position - press_pos
                if not dragging and Vector2.new(d.X, d.Y).Magnitude > 14 then dragging = true end
                if dragging then
                    button.AnchorPoint = Vector2.new(0.5, 0.5)
                    button.Position = UDim2.fromOffset(start_abs.X + d.X, start_abs.Y + d.Y)
                end
            end)
            press_conns[#press_conns + 1] = UserInputService.InputEnded:Connect(function(i)
                if not pressing then return end
                if i == press_input or i.UserInputType == Enum.UserInputType.MouseButton1 then release_press() end
            end)
        end)
        gui.Parent = hui()
        paint()
    end
    function Orb.hide()
        drop_press_conns()
        pressing, dragging = false, false
        set_spam(false)
        if gui then pcall(function() gui:Destroy() end) end
        gui, button = nil, nil
    end
end

-- ===========================================================================
-- UI
-- ===========================================================================
Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options, Toggles = Library.Options, Library.Toggles
local S, SP, Det = Parry.S, Parry.SP, Parry.Det
local function Notify(title, text, time) pcall(function() Library:Notify({ Title = title, Description = text, Time = time or 3 }) end) end

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
    Parry = Window:AddTab("Auto Parry", "swords", "Auto parry, triggerbot, curves, abilities"),
    Detection = Window:AddTab("Detection", "shield-alert", "Pause parrying during enemy abilities"),
    Spam = Window:AddTab("Spam", "zap", "Manual and auto spam"),
    Player = Window:AddTab("Player", "user", "Avatar, cosmetics, movement"),
    Visuals = Window:AddTab("Visuals", "eye", "Overlays and ESP"),
    Misc = Window:AddTab("Misc", "wrench", "Skin changer and extras"),
    Status = Window:AddTab("Status", "gauge", "Live state and parry log"),
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
AP:AddToggle("ParryAnimation", {
    Text = "Parry animation", Default = true,
    Tooltip = "Plays your sword's block swing on remote parries (Keypress mode and abilities animate themselves). Off = no animations from the script at all.",
    Callback = function(v) Anim.enabled = v end,
})
AP:AddDropdown("ParryMode", {
    Values = { "Remote", "Keypress" }, Default = "Remote", Text = "Parry mode",
    Tooltip = "Remote sends the captured packet (curves, no cooldown tell). Keypress presses block.",
    Callback = function(v) S.parry_mode = v end,
})
AP:AddDropdown("AntiCurve", {
    Values = { "Smart", "Dot", "Off" }, Default = "Smart", Text = "Anti curve",
    Tooltip = "Smart: median of three arrival estimates (homing sims + real closing speed). Dot: wait until the ball points at you. Off: straight-line timing.",
    Callback = function(v) S.anticurve = v end,
})
AP:AddSlider("CurveBias", {
    Text = "Curve early bias", Default = 50, Min = 0, Max = 100, Rounding = 0, Suffix = "%",
    Tooltip = "Smart mode: how much earlier to parry a curving ball (inside the window, early is safe).",
    Callback = function(v) S.curve_bias = v / 100 end,
})
AP:AddSlider("DotThreshold", {
    Text = "Dot threshold", Default = 0.5, Min = -0.2, Max = 0.95, Rounding = 2,
    Tooltip = "Dot mode: how directly the ball must point at you before it can be parried.",
    Callback = function(v) S.dot_threshold = v end,
})
AP:AddToggle("PreParry", {
    Text = "Pre-parry", Default = false,
    Tooltip = "Ball on a player right next to you whose return would beat your reaction: parry ahead of it.",
    Callback = function(v) S.preparry = v end,
})
AP:AddSlider("PreParryRange", {
    Text = "Pre-parry range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Callback = function(v) S.preparry_range = v end,
})
AP:AddToggle("HighPingPreParry", {
    Text = "Auto pre-parry at high ping", Default = false,
    Tooltip = "Pre-parry turns itself on while your ping is 80ms or more.",
    Callback = function(v) S.hp_preparry = v end,
})
AP:AddDropdown("TargetMode", {
    Values = Parry.targetNames, Default = "Cursor", Text = "Target mode",
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
    Tooltip = "Toward 2 = parry earlier, toward 0 = later.",
    Callback = function(v) S.timing_mult = v end,
})
APS:AddSlider("ExtraDistance", {
    Text = "Extra distance", Default = 0, Min = -20, Max = 40, Rounding = 0, Suffix = " studs",
    Callback = function(v) S.extra_distance = v end,
})
APS:AddSlider("RetryDelay", {
    Text = "Retry delay", Default = 1, Min = 0.2, Max = 1.5, Rounding = 2, Suffix = "s",
    Callback = function(v) S.retry_delay = v end,
})
APS:AddToggle("PingCompensation", {
    Text = "Ping compensation", Default = false,
    Tooltip = "Leads further ahead on high ping. Turn on if parries land late.",
    Callback = function(v) S.ping_compensation = v end,
})
APS:AddToggle("RandomAccuracy", { Text = "Randomize accuracy", Default = false, Callback = function(v) S.random_accuracy = v end })
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
CV:AddToggle("RandomCurve", { Text = "Random curve each parry", Default = false, Callback = function(v) S.random_curve = v end })
local function cycle_curve(dir)
    local names = Parry.curveNames
    local idx = (S.curve_mode - 1 + dir) % #names + 1
    pcall(function() Options.CurveMode:SetValue(names[idx]) end)
    Notify("Curve", names[idx], 1)
end
CV:AddLabel("Next curve"):AddKeyPicker("NextCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Next curve", Callback = function() cycle_curve(1) end,
})
CV:AddLabel("Previous curve"):AddKeyPicker("PrevCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Previous curve", Callback = function() cycle_curve(-1) end,
})

local AB = Tabs.Parry:AddLeftGroupbox("Abilities", "sparkles")
AB:AddToggle("AutoAbility", {
    Text = "Auto ability", Default = false,
    Tooltip = "Parry with your ability when it's ready and is a parry ability (Raging/Calming Deflection, Rapture, Aerodynamic Slash, Fracture, Death Slash).",
    Callback = function(v) S.auto_ability = v end,
})
AB:AddToggle("CooldownProtection", {
    Text = "Cooldown protection", Default = false,
    Tooltip = "Use Raging/Calming Deflection or Rapture as the parry when they're ready.",
    Callback = function(v) S.cooldown_protection = v end,
})

-- ----- Detection tab -----
-- Each detection owns its listeners; they exist only while its toggle is on.
local function get_remotes() return ReplicatedStorage:FindFirstChild("Remotes") end
local function get_net()
    local ok, net = pcall(function() return ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"].net end)
    return ok and net or nil
end
local function is_local(player)
    return player == LocalPlayer or player == LocalPlayer.Name or (typeof(player) == 'Instance' and player.Name == LocalPlayer.Name)
end

local DetInfinity = Feature("DetInfinity")
function DetInfinity.start()
    local R = get_remotes()
    if R and R:FindFirstChild("InfinityBall") then
        DetInfinity:connect(R.InfinityBall.OnClientEvent, function(_, b) Det.infinity = b and true or false end)
    end
end
function DetInfinity.stop() Det.infinity = false end

local DetDeathSlash = Feature("DetDeathSlash")
function DetDeathSlash.start()
    local R = get_remotes()
    if R and R:FindFirstChild("DeathBall") then
        DetDeathSlash:connect(R.DeathBall.OnClientEvent, function(_, d) Det.deathslash = d and true or false end)
    end
end
function DetDeathSlash.stop() Det.deathslash = false end

local DetTimeHole = Feature("DetTimeHole")
function DetTimeHole.start()
    local net = get_net()
    if not net then return end
    pcall(function() DetTimeHole:connect(net["RE/TimeHoleActivate"].OnClientEvent, function(p) if is_local(p) then Det.timehole = true end end) end)
    pcall(function() DetTimeHole:connect(net["RE/TimeHoleDeactivate"].OnClientEvent, function() Det.timehole = false end) end)
end
function DetTimeHole.stop() Det.timehole = false end

-- Slashes of Fury: while it's on you, parry it out (spam path), capped and paced.
local Slashes = { delay = 0.05, max = 36, count = 0, looping = false }
local DetSlashes = Feature("DetSlashes")
local function run_slashes()
    if Slashes.looping or not Det.slashes then return end
    Slashes.looping = true
    local token = DetSlashes._token
    task.spawn(function()
        local sent = 0
        while DetSlashes:alive(token) and Det.slashes and sent < Slashes.max and Slashes.count < Slashes.max and LocalPlayer.Character do
            Parry.spamParry()
            sent = sent + 1
            task.wait(Slashes.delay)
        end
        Slashes.looping = false
    end)
end
function DetSlashes.start()
    local net = get_net()
    if not net then return end
    pcall(function() DetSlashes:connect(net["RE/SlashesOfFuryActivate"].OnClientEvent, function(p)
        if is_local(p) then Det.slashes, Slashes.count = true, 0; run_slashes() end
    end) end)
    pcall(function() DetSlashes:connect(net["RE/SlashesOfFuryEnd"].OnClientEvent, function()
        Det.slashes, Slashes.count, Slashes.looping = false, 0, false
    end) end)
    pcall(function() DetSlashes:connect(net["RE/SlashesOfFuryParry"].OnClientEvent, function() Slashes.count = Slashes.count + 1 end) end)
    pcall(function() DetSlashes:connect(net["RE/SlashesOfFuryCatch"].OnClientEvent, function() run_slashes() end) end)
end
function DetSlashes.stop() Det.slashes, Slashes.count, Slashes.looping = false, 0, false end

-- Anti-Phantom: when Phantom's transmission part gets welded to you, cut the
-- weld and fire your ability the moment the ball is highlighted on you.
local DetPhantom = Feature("DetPhantom")
function DetPhantom.start()
    local runtime = Workspace:FindFirstChild("Runtime")
    if not runtime then return end
    DetPhantom:connect(runtime.ChildAdded, function(obj)
        if obj.Name ~= "maxTransmission" and obj.Name ~= "transmissionpart" then return end
        local weld = obj:FindFirstChildWhichIsA("WeldConstraint")
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not weld or not root or weld.Part1 ~= root then return end
        local ball = Parry.mainBall()
        pcall(function() weld:Destroy() end)
        if not ball then return end
        local watch
        watch = RunService.RenderStepped:Connect(function()
            local hl = ball:GetAttribute("highlighted")
            if hl == true then
                Parry.resolve(); Parry.abilityPress()
                Det.phantom_until = clock_() + 1
            elseif hl == false then
                watch:Disconnect()
            end
        end)
        task.delay(3, function() if watch and watch.Connected then watch:Disconnect() end end)
    end)
end
function DetPhantom.stop() Det.phantom_until = 0 end

local DL = Tabs.Detection:AddLeftGroupbox("Abilities", "shield-alert")
DL:AddToggle("DetInfinity", { Text = "Infinity detection", Default = false, Callback = function(v) DetInfinity:setEnabled(v) end })
DL:AddToggle("DetDeathSlash", { Text = "Death Slash detection", Default = false, Callback = function(v) DetDeathSlash:setEnabled(v) end })
DL:AddToggle("DetTimeHole", { Text = "Time Hole detection", Default = false, Callback = function(v) DetTimeHole:setEnabled(v) end })
DL:AddToggle("DetPhantom", { Text = "Anti-Phantom [BETA]", Default = false, Callback = function(v) DetPhantom:setEnabled(v) end })
local DR = Tabs.Detection:AddRightGroupbox("Slashes Of Fury", "swords")
DR:AddToggle("DetSlashes", { Text = "Slashes detection", Default = false, Callback = function(v) DetSlashes:setEnabled(v) end })
DR:AddSlider("SlashesDelay", { Text = "Parry delay", Default = 0.05, Min = 0.05, Max = 0.25, Rounding = 2, Suffix = "s", Callback = function(v) Slashes.delay = v end })
DR:AddSlider("SlashesMax", { Text = "Max parry count", Default = 36, Min = 1, Max = 100, Rounding = 0, Callback = function(v) Slashes.max = v end })

-- ----- Spam tab -----
local MS = Tabs.Spam:AddLeftGroupbox("Manual Spam", "zap")
MS:AddToggle("ManualSpam", {
    Text = touchUI and "Manual spam (show orb)" or "Manual spam", Default = false,
    Tooltip = touchUI and "Shows the spam orb: tap it to turn spam on/off, drag to move."
        or "Press the key (E by default) to turn spam on, press again to turn it off.",
    Callback = function(v)
        if touchUI then
            -- the toggle shows the orb; the orb decides when to actually spam
            if v then Orb.show() else Orb.hide() end
        else
            SP.manual = v
        end
        Engine.want("manualspam", v)
    end,
}):AddKeyPicker("ManualSpamKey", { Default = "E", Mode = "Toggle", SyncToggleState = not touchUI, Text = "Manual spam" })
MS:AddToggle("SpamAnimation", {
    Text = "Spam animation", Default = true,
    Tooltip = "Plays the block swing with spam the way a real held key looks: block, success swing, block -- never restarted every parry.",
    Callback = function(v) Anim.spam = v end,
})
MS:AddToggle("SmartStop", {
    Text = "Smart stop", Default = true,
    Tooltip = "Only spams while a ball is on you, close to you, or heading at you -- stops by itself the rest of the time.",
    Callback = function(v) SP.smart = v end,
})
MS:AddDropdown("SpamMode", {
    Values = { "Remote", "Keypress" }, Default = "Remote", Text = "Mode",
    Callback = function(v) SP.mode = v end,
})
MS:AddSlider("SpamMaxRate", {
    Text = "Max rate", Default = 1000, Min = 20, Max = 2000, Rounding = 0, Suffix = "/s",
    Callback = function(v) SP.max_rate = v end,
})
MS:AddSlider("SpamIdleRate", {
    Text = "Idle rate", Default = 20, Min = 1, Max = 200, Rounding = 0, Suffix = "/s",
    Tooltip = "With Smart stop off: the rate while nothing is a threat.",
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
    Tooltip = "Spams through clashes and stops the moment the exchange is over.",
    Callback = function(v) SP.auto = v; Engine.want("autospam", v) end,
}):AddKeyPicker("AutoSpamKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto spam" })
AS:AddToggle("PredictiveClash", {
    Text = "Predictive start", Default = true,
    Tooltip = "Start as you send the ball to a close player whose return would be too fast to react to.",
    Callback = function(v) SP.predictive = v end,
})
AS:AddSlider("ClashSensitivity", {
    Text = "Sensitivity", Default = 1.3, Min = 0.6, Max = 2.5, Rounding = 2,
    Tooltip = "Higher = calls a clash sooner. Lower = only very fast exchanges.",
    Callback = function(v) SP.sensitivity = v end,
})
AS:AddSlider("ClashRangeBonus", {
    Text = "Clash range", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Callback = function(v) SP.range_bonus = v end,
})
AS:AddSlider("ClashHold", {
    Text = "Hold", Default = 0.15, Min = 0, Max = 0.5, Rounding = 2, Suffix = "s",
    Tooltip = "Keeps spamming this long once the clash fades (hard stops still end it at once).",
    Callback = function(v) SP.hold = v end,
})
local ClashLabel = AS:AddLabel("Status: off", true)

-- ----- Player tab -----
-- Avatar changer
local Avatar = { target = "", original = nil }
local AvatarChanger = Feature("AvatarChanger")
do
    local function strip(char)
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants")
                or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
    end
    local function save_original()
        if Avatar.original then return end
        local char = LocalPlayer.Character; if not char then return end
        local o = { Accessories = {}, CharacterMeshes = {} }
        local head = char:FindFirstChild("Head")
        if head then
            local face = head:FindFirstChildOfClass("Decal"); if face then o.Face = face.Texture end
            local hm = head:FindFirstChildOfClass("SpecialMesh"); if hm then o.HeadMesh = hm:Clone() end
        end
        local shirt = char:FindFirstChildOfClass("Shirt"); if shirt then o.Shirt = shirt.ShirtTemplate end
        local pants = char:FindFirstChildOfClass("Pants"); if pants then o.Pants = pants.PantsTemplate end
        local bc = char:FindFirstChildOfClass("BodyColors")
        if bc then
            o.BodyColors = { HeadColor3 = bc.HeadColor3, LeftArmColor3 = bc.LeftArmColor3, RightArmColor3 = bc.RightArmColor3,
                LeftLegColor3 = bc.LeftLegColor3, RightLegColor3 = bc.RightLegColor3, TorsoColor3 = bc.TorsoColor3 }
        end
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") then o.Accessories[#o.Accessories + 1] = obj:Clone()
            elseif obj:IsA("CharacterMesh") then o.CharacterMeshes[#o.CharacterMeshes + 1] = obj:Clone() end
        end
        Avatar.original = o
    end
    local function restore()
        local char, o = LocalPlayer.Character, Avatar.original
        if not char or not o then return end
        pcall(function()
            strip(char)
            local head = char:FindFirstChild("Head")
            if head then
                local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
                if o.Face then local f = Instance.new("Decal"); f.Name = "face"; f.Texture = o.Face; f.Parent = head end
                local hm = head:FindFirstChildOfClass("SpecialMesh"); if hm then hm:Destroy() end
                if o.HeadMesh then o.HeadMesh:Clone().Parent = head end
            end
            if o.Shirt then local s = Instance.new("Shirt"); s.Name = "Shirt"; s.ShirtTemplate = o.Shirt; s.Parent = char end
            if o.Pants then local p = Instance.new("Pants"); p.Name = "Pants"; p.PantsTemplate = o.Pants; p.Parent = char end
            if o.BodyColors then local bc = Instance.new("BodyColors"); for k, v in pairs(o.BodyColors) do bc[k] = v end; bc.Parent = char end
            for _, m in ipairs(o.CharacterMeshes) do m:Clone().Parent = char end
            for _, a in ipairs(o.Accessories) do a:Clone().Parent = char end
        end)
    end
    local function attach(char, acc)
        local handle = acc:FindFirstChild("Handle")
        if not handle or not handle:IsA("BasePart") then return end
        local accAtt = handle:FindFirstChildOfClass("Attachment")
        local charAtt
        if accAtt then
            for _, part in ipairs(char:GetChildren()) do
                if part:IsA("BasePart") then charAtt = part:FindFirstChild(accAtt.Name); if charAtt then break end end
            end
        end
        local part = charAtt and charAtt.Parent or char:FindFirstChild("Head")
        if not part then acc.Parent = char; return end
        acc.Parent = char; handle.CanCollide = false; handle.Anchored = false
        local weld = Instance.new("Weld"); weld.Name = "AccessoryWeld"; weld.Part0 = handle; weld.Part1 = part
        if charAtt and charAtt:IsA("Attachment") and accAtt then
            handle.CFrame = part.CFrame * charAtt.CFrame * accAtt.CFrame:Inverse()
            weld.C0, weld.C1 = accAtt.CFrame, charAtt.CFrame
        else
            handle.CFrame = part.CFrame * CFrame.new(0, 0.6, 0)
            weld.C0, weld.C1 = CFrame.new(0, 0.6, 0), CFrame.new()
        end
        weld.Parent = handle
    end
    local function apply(userId)
        local char = LocalPlayer.Character; if not char then return false end
        local ok, model = pcall(function() return Players:CreateHumanoidModelFromUserId(userId) end)
        if not ok or not model then return false end
        pcall(function()
            strip(char)
            local head, mhead = char:FindFirstChild("Head"), model:FindFirstChild("Head")
            if head and mhead then
                local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
                local mface = mhead:FindFirstChildOfClass("Decal"); if mface then mface:Clone().Parent = head end
                local hm, mm = head:FindFirstChildOfClass("SpecialMesh"), mhead:FindFirstChildOfClass("SpecialMesh")
                if hm then hm:Destroy() end
                if mm then mm:Clone().Parent = head end
                head.Size = mhead.Size; head.Color = mhead.Color
            end
            for _, obj in ipairs(model:GetChildren()) do
                if obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("ShirtGraphic") or obj:IsA("CharacterMesh") then
                    obj:Clone().Parent = char
                elseif obj:IsA("Accessory") or obj:IsA("Accoutrement") then
                    pcall(attach, char, obj:Clone())
                end
            end
            model:Destroy()
        end)
        return true
    end
    local function resolve_id(value)
        if value == nil or value == "" then return nil end
        local id = tonumber(value); if id then return id end
        local ok, r = pcall(function() return Players:GetUserIdFromNameAsync(value) end)
        return ok and r or nil
    end
    function AvatarChanger.start()
        local token = AvatarChanger._token
        task.spawn(function()
            local id = resolve_id(Avatar.target)
            if not AvatarChanger:alive(token) then return end
            if not id then Notify("Avatar Changer", "Invalid username or id", 3); return end
            save_original()
            if apply(id) then Notify("Avatar Changer", "Appearance changed", 3) end
            -- keep it after a respawn
            AvatarChanger:connect(LocalPlayer.CharacterAdded, function()
                task.wait(1)
                if AvatarChanger:alive(token) then apply(id) end
            end)
        end)
    end
    function AvatarChanger.stop() restore() end
end

local AVC = Tabs.Player:AddLeftGroupbox("Avatar Changer", "user")
AVC:AddInput("AvatarTarget", { Text = "Target", Placeholder = "Username or user id", Default = "", Finished = true,
    Callback = function(t) Avatar.target = t end })
AVC:AddToggle("AvatarChanger", { Text = "Avatar changer", Default = false, Callback = function(v) AvatarChanger:setEnabled(v) end })

-- Headless / Korblox
local function apply_headless(char, on)
    local head = char and char:FindFirstChild("Head"); if not head then return end
    head.Transparency = on and 1 or 0
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = on and 1 or 0
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            if on and not child:GetAttribute("OriginalScale") then
                child:SetAttribute("OriginalScale", child.Scale); child.Scale = Vector3.new(0, 0, 0)
            elseif not on then
                local orig = child:GetAttribute("OriginalScale")
                if orig then child.Scale = orig; child:SetAttribute("OriginalScale", nil) end
            end
        end
    end
end
local function apply_korblox(char, on)
    local leg = char and char:FindFirstChild("Right Leg"); if not leg then return end
    if on then
        if leg:FindFirstChild("KorbloxMesh") then return end
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
        local m = Instance.new("SpecialMesh"); m.Name = "KorbloxMesh"
        m.MeshId = "rbxassetid://902942096"; m.TextureId = "rbxassetid://902843398"
        m.Offset = Vector3.new(0, 0.7, 0); m.Parent = leg
    else
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
    end
end
local Headless = Feature("Headless")
function Headless.start()
    pcall(apply_headless, LocalPlayer.Character, true)
    Headless:connect(LocalPlayer.CharacterAdded, function(c) task.wait(0.5); if Headless.on then pcall(apply_headless, c, true) end end)
end
function Headless.stop() pcall(apply_headless, LocalPlayer.Character, false) end
local Korblox = Feature("Korblox")
function Korblox.start()
    pcall(apply_korblox, LocalPlayer.Character, true)
    Korblox:connect(LocalPlayer.CharacterAdded, function(c) task.wait(0.5); if Korblox.on then pcall(apply_korblox, c, true) end end)
end
function Korblox.stop() pcall(apply_korblox, LocalPlayer.Character, false) end

local HK = Tabs.Player:AddRightGroupbox("Cosmetics", "shirt")
HK:AddToggle("Headless", { Text = "Headless", Default = false, Callback = function(v) Headless:setEnabled(v) end })
HK:AddToggle("Korblox", { Text = "Korblox", Default = false, Callback = function(v) Korblox:setEnabled(v) end })

-- Auto jump
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
local MV = Tabs.Player:AddRightGroupbox("Movement", "footprints")
MV:AddToggle("AutoJump", {
    Text = "Auto jump", Default = false,
    Callback = function(v) AutoJump:setEnabled(v) end,
}):AddKeyPicker("AutoJumpKey", { Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump" })

-- ----- Visuals tab -----
local function hexc(c) return ("%02x%02x%02x"):format(math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255)) end
local function speed_color(s)
    if s > 2000 then return Color3.fromRGB(255, 0, 0) elseif s > 1500 then return Color3.fromRGB(255, 165, 0)
    elseif s > 1000 then return Color3.fromRGB(255, 215, 0) end
    return Color3.fromRGB(255, 255, 0)
end
local function panel(name, size, pos, title_text)
    local gui = Instance.new("ScreenGui"); gui.Name = name; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    local frame = Instance.new("Frame"); frame.Size = size; frame.Position = pos
    frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18); frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0; frame.Active = true; frame.Draggable = true; frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(60, 60, 70)
    if title_text then
        local t = Instance.new("TextLabel", frame); t.Size = UDim2.new(1, 0, 0, 18); t.Position = UDim2.new(0, 0, 0, 4)
        t.BackgroundTransparency = 1; t.Text = title_text; t.TextColor3 = Color3.fromRGB(255, 255, 255)
        t.Font = Enum.Font.GothamBold; t.TextSize = 13
    end
    local function line(y)
        local l = Instance.new("TextLabel", frame); l.Size = UDim2.new(1, -12, 0, 20); l.Position = UDim2.new(0, 6, 0, y)
        l.BackgroundTransparency = 1; l.TextColor3 = Color3.fromRGB(255, 255, 255); l.Font = Enum.Font.GothamBold
        l.TextSize = 14; l.RichText = true; l.TextXAlignment = Enum.TextXAlignment.Left
        return l
    end
    gui.Parent = hui()
    return gui, line
end

local BallVelocity = Feature("BallVelocity")
function BallVelocity.start()
    local gui, line = panel("BB_BallVelocity", UDim2.new(0, 200, 0, 70), UDim2.new(0, 10, 0.78, 0), "Ball Status")
    BallVelocity:own(gui)
    local cur, peakl = line(24), line(44)
    local peak, last_ball = 0, nil
    BallVelocity:connect(RunService.RenderStepped, function()
        pcall(Parry.resolve)
        local ball = Parry.mainBall()
        if not ball then cur.Text = "Current: 0"; return end
        if ball ~= last_ball then peak, last_ball = 0, ball end
        local s = Parry.ballVelocity(ball).Magnitude
        if s > peak then peak = s end
        cur.Text = ("Current: <font color='#%s'>%.1f</font>"):format(hexc(speed_color(s)), s)
        peakl.Text = ("Peak: <font color='#%s'>%.1f</font>"):format(hexc(speed_color(peak)), peak)
    end)
end

local PingOverlay = Feature("PingOverlay")
function PingOverlay.start()
    local gui, line = panel("BB_Ping", UDim2.new(0, 110, 0, 32), UDim2.new(0, 15, 0.9, 0), nil)
    PingOverlay:own(gui)
    local l = line(6)
    l.TextXAlignment = Enum.TextXAlignment.Center
    PingOverlay:loop(0.5, function()
        local p = Parry.pingMs()
        local c = p < 80 and Color3.fromRGB(0, 255, 0) or (p < 150 and Color3.fromRGB(255, 220, 0) or Color3.fromRGB(255, 60, 60))
        l.Text = ("Ping: <font color='#%s'>%dms</font>"):format(hexc(c), math.floor(p + 0.5))
    end)
end

-- Ability ESP
local EspCfg = { Color = Color3.fromRGB(255, 255, 255), TextSize = 14, Height = 3.5, ShowName = true, ShowDistance = false,
    OnlyWithAbility = false, MaxDistance = 0, ShowActive = true, ShowCooldown = true }
local AbilityESP = Feature("AbilityESP")
do
    local entries = {}
    local function esc(s) return (tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
    local function info(player, character)
        local ability = player:GetAttribute('EquippedAbility') or (character and character:GetAttribute('Ability'))
        if not ability or ability == '' then return nil end
        local name = tostring(ability)
        local up = player:FindFirstChild('Upgrades')
        local lv = up and up:FindFirstChild(name)
        if lv and type(lv.Value) == 'number' and lv.Value > 0 then name = name .. ' V' .. lv.Value end
        local now = Workspace:GetServerTimeNow()
        local status
        if EspCfg.ShowActive then
            local start, dur = player:GetAttribute('AbilityDurationStart') or 0, player:GetAttribute('AbilityDuration') or 0
            local left = (start > 0 and dur > 0) and (start + dur - now) or 0
            if left > 0 then status = ('<font color="#5CFF7A">ACTIVE %.1fs</font>'):format(left)
            elseif character and character:GetAttribute('AbilityActive') then status = '<font color="#5CFF7A">ACTIVE</font>' end
        end
        if not status and EspCfg.ShowCooldown then
            local exp = (character and character:GetAttribute('CooldownExpiration')) or player:GetAttribute('CooldownExpiration')
            if type(exp) == 'number' then
                local left = exp - now
                status = (left > 0 and left < 600) and ('<font color="#FF6A6A">CD %.1fs</font>'):format(left) or '<font color="#B4B4B4">READY</font>'
            end
        end
        return name, status
    end
    local function remove(player)
        local e = entries[player]
        if e then pcall(function() e.bb:Destroy() end) end
        entries[player] = nil
    end
    local function create(player, token)
        task.spawn(function()
            local character = player.Character
            while AbilityESP:alive(token) and (not character or not character.Parent) do task.wait(0.5); character = player.Character end
            if not character then return end
            local head = character:WaitForChild('Head', 10)
            if not head or not AbilityESP:alive(token) then return end
            remove(player)
            local bb = Instance.new('BillboardGui')
            bb.Name = 'BB_AbilityESP'; bb.Adornee = head; bb.Size = UDim2.new(0, 220, 0, 60)
            bb.StudsOffset = Vector3.new(0, EspCfg.Height, 0); bb.AlwaysOnTop = true
            local label = Instance.new('TextLabel')
            label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1; label.TextColor3 = EspCfg.Color
            label.TextSize = EspCfg.TextSize; label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
            label.RichText = true; label.Visible = false; label.Parent = bb
            bb.Parent = hui()
            entries[player] = { bb = bb, label = label, character = character, head = head }
        end)
    end
    local function update()
        local my = getRoot()
        for player, e in pairs(entries) do
            if not (e.character and e.character.Parent and e.head and e.head.Parent) then remove(player)
            else
                local dist = my and (my.Position - e.head.Position).Magnitude
                local name, status = info(player, e.character)
                local vis = not (EspCfg.MaxDistance > 0 and dist and dist > EspCfg.MaxDistance) and not (EspCfg.OnlyWithAbility and not name)
                e.label.Visible = vis
                if vis then
                    e.label.TextColor3, e.label.TextSize = EspCfg.Color, EspCfg.TextSize
                    e.bb.StudsOffset = Vector3.new(0, EspCfg.Height, 0)
                    local parts = {}
                    if EspCfg.ShowName then parts[#parts + 1] = esc(player.DisplayName) end
                    if name then parts[#parts + 1] = '[' .. esc(name) .. ']' end
                    if EspCfg.ShowDistance and dist then parts[#parts + 1] = ('%.0fm'):format(dist) end
                    if #parts == 0 then parts[1] = esc(player.DisplayName) end
                    local text = '<b>' .. table.concat(parts, ' ') .. '</b>' .. (status and ('\n' .. status) or '')
                    if text ~= e.text then e.text = text; e.label.Text = text end
                end
            end
        end
    end
    local function add(player, token)
        if player == LocalPlayer then return end
        AbilityESP:connect(player.CharacterAdded, function() create(player, token) end)
        if player.Character then create(player, token) end
    end
    function AbilityESP.start()
        local token = AbilityESP._token
        for _, p in ipairs(Players:GetPlayers()) do add(p, token) end
        AbilityESP:connect(Players.PlayerAdded, function(p) add(p, token) end)
        AbilityESP:connect(Players.PlayerRemoving, function(p) remove(p) end)
        AbilityESP:loop(0.1, update)
    end
    function AbilityESP.stop() for p in pairs(entries) do remove(p) end end
end

local VS = Tabs.Visuals:AddLeftGroupbox("Overlays", "monitor")
VS:AddToggle("BallVelocity", { Text = "Ball velocity overlay", Default = false, Callback = function(v) BallVelocity:setEnabled(v) end })
VS:AddToggle("ShowPing", { Text = "Ping overlay", Default = false, Callback = function(v) PingOverlay:setEnabled(v) end })

local AE = Tabs.Visuals:AddRightGroupbox("Ability ESP", "eye")
AE:AddToggle("AbilityESP", { Text = "Ability ESP", Default = false, Callback = function(v) AbilityESP:setEnabled(v) end })
AE:AddToggle("AbilityESPName", { Text = "Show name", Default = true, Callback = function(v) EspCfg.ShowName = v end })
AE:AddToggle("AbilityESPDistance", { Text = "Show distance", Default = false, Callback = function(v) EspCfg.ShowDistance = v end })
AE:AddToggle("AbilityESPOnlyWith", { Text = "Only players with an ability", Default = false, Callback = function(v) EspCfg.OnlyWithAbility = v end })
AE:AddToggle("AbilityESPActive", { Text = "Show active time", Default = true, Callback = function(v) EspCfg.ShowActive = v end })
AE:AddToggle("AbilityESPCooldown", { Text = "Show cooldown", Default = true, Callback = function(v) EspCfg.ShowCooldown = v end })
AE:AddSlider("AbilityESPTextSize", { Text = "Text size", Default = 14, Min = 8, Max = 30, Rounding = 0, Callback = function(v) EspCfg.TextSize = v end })
AE:AddSlider("AbilityESPHeight", { Text = "Height offset", Default = 3.5, Min = 0, Max = 15, Rounding = 1, Suffix = " studs", Callback = function(v) EspCfg.Height = v end })
AE:AddSlider("AbilityESPMaxDistance", { Text = "Max distance", Default = 0, Min = 0, Max = 2000, Rounding = 0, Suffix = " studs",
    Tooltip = "0 = unlimited.", Callback = function(v) EspCfg.MaxDistance = v end })
AE:AddLabel("Text color"):AddColorPicker("AbilityESPColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Ability ESP color",
    Callback = function(v) EspCfg.Color = v end })

-- ----- Misc tab -----
-- Skin changer: everything (module require, controller lookup, resolver remap,
-- upkeep loop, respawn hook) happens only while it's on.
local Skin = { name = "", file = "BladeBall/skin.json" }
pcall(function()
    if isfile and isfile(Skin.file) then
        local d = HttpService:JSONDecode(readfile(Skin.file))
        if type(d) == "table" and type(d.swordModel) == "string" then Skin.name = d.swordModel end
    end
end)
local function save_skin()
    pcall(function()
        if makefolder and isfolder and not isfolder("BladeBall") then makefolder("BladeBall") end
        if writefile then writefile(Skin.file, HttpService:JSONEncode({ swordModel = Skin.name })) end
    end)
end
local SkinChanger = Feature("SkinChanger")
do
    local swords, controller, realGetSword
    local function our_sword(name)
        return type(name) == "string" and name ~= "" and (name == LocalPlayer:GetAttribute("CurrentlyEquippedSword") or name == Skin.name)
    end
    local function set_sword()
        if not SkinChanger.on or Skin.name == "" or not swords or not LocalPlayer.Character then return end
        pcall(function()
            local f = rawget(swords, "EquipSwordTo")
            if type(f) == "function" and getupvalues and setupvalue then
                local ups = getupvalues(f)
                for i = 1, #ups do if type(ups[i]) == "boolean" then setupvalue(f, i, false); break end end
            end
        end)
        pcall(function() swords:EquipSwordTo(LocalPlayer.Character, Skin.name) end)
        if controller then
            pcall(function() if controller.SetSword then controller:SetSword(Skin.name) end end)
            pcall(function()
                local R = get_remotes()
                if R and R:FindFirstChild("FireSwordInfo") then R.FireSwordInfo:FireServer(Skin.name) end
                if controller.currentSword ~= nil then controller.currentSword = Skin.name end
                if controller.SwordFX ~= nil then controller.SwordFX = Skin.name end
            end)
        end
    end
    function SkinChanger.apply() if SkinChanger.on then save_skin(); set_sword() end end
    function SkinChanger.start()
        local token = SkinChanger._token
        task.spawn(function()
            local ok = pcall(function()
                swords = swords or require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("ReplicatedInstances", 10):WaitForChild("Swords", 10))
            end)
            if not ok or not swords or not SkinChanger:alive(token) then
                if SkinChanger:alive(token) then Notify("Skin Changer", "Couldn't load the game's sword list.", 4) end
                return
            end
            -- the game's effects resolve sword names through Swords:GetSword; hand
            -- back the skin's real data for the sword we have equipped
            pcall(function()
                realGetSword = realGetSword or swords.GetSword
                if type(realGetSword) == "function" then
                    rawset(swords, "GetSword", function(self, name, ...)
                        if SkinChanger.on and Skin.name ~= "" and Skin.name ~= name and our_sword(name) then
                            local ok2, data = pcall(realGetSword, self, Skin.name, ...)
                            if ok2 and type(data) == "table" then return data end
                        end
                        return realGetSword(self, name, ...)
                    end)
                end
            end)
            -- find the swords controller (bounded: ~10s, only while on)
            local tries = 0
            while not controller and tries < 40 and SkinChanger:alive(token) do
                pcall(function()
                    local R = get_remotes()
                    local conns = R and getconnections and getconnections(R.FireSwordInfo.OnClientEvent)
                    for _, c in ipairs(conns or {}) do
                        if c.Function and islclosure and islclosure(c.Function) then
                            local up = getupvalues(c.Function)
                            if #up == 1 and type(up[1]) == "table" then controller = up[1]; break end
                        end
                    end
                end)
                tries = tries + 1
                if not controller then task.wait(0.25) end
            end
            if not SkinChanger:alive(token) then return end
            set_sword()
            SkinChanger:connect(LocalPlayer.CharacterAdded, function()
                task.wait(2.5)
                if SkinChanger:alive(token) then set_sword() end
            end)
            SkinChanger:loop(1, function()
                if Skin.name == "" then return end
                local char = LocalPlayer.Character
                if not char then return end
                if LocalPlayer:GetAttribute("CurrentlyEquippedSword") ~= Skin.name or not char:FindFirstChild(Skin.name) then set_sword() end
                for _, v in ipairs(char:GetChildren()) do
                    if v:IsA("Model") and v.Name ~= Skin.name and swords and pcall(function() return realGetSword(swords, v.Name) end) then
                        local ok3, data = pcall(realGetSword, swords, v.Name)
                        if ok3 and type(data) == "table" then v:Destroy() end
                    end
                end
            end)
        end)
    end
    function SkinChanger.stop()
        -- put the game's own resolver back
        if swords and realGetSword then pcall(function() rawset(swords, "GetSword", realGetSword) end) end
    end
end

local SC = Tabs.Misc:AddLeftGroupbox("Skin Changer", "palette")
SC:AddInput("SkinName", { Text = "Sword name", Placeholder = "e.g. DualPrince", Default = Skin.name, Finished = true,
    Callback = function(t) Skin.name = t; save_skin(); SkinChanger.apply() end })
SC:AddToggle("SkinChanger", { Text = "Skin changer", Default = false, Callback = function(v) SkinChanger:setEnabled(v) end })
-- parry swings use the skin's animation set while the skin changer is on
Anim.skin = function() return (SkinChanger.on and Skin.name ~= "") and Skin.name or nil end

-- No render: turn off the game's ability / parry effects
local NoRender = Feature("NoRender")
function NoRender.start()
    pcall(function() LocalPlayer.PlayerScripts.EffectScripts.ClientFX.Disabled = true end)
    local runtime = Workspace:FindFirstChild("Runtime")
    if runtime then NoRender:connect(runtime.ChildAdded, function(v) Debris:AddItem(v, 0) end) end
end
function NoRender.stop() pcall(function() LocalPlayer.PlayerScripts.EffectScripts.ClientFX.Disabled = false end) end
local NR = Tabs.Misc:AddRightGroupbox("Performance", "cpu")
NR:AddToggle("NoRender", { Text = "No render", Default = false, Tooltip = "Turns off ability and parry effects.",
    Callback = function(v) NoRender:setEnabled(v) end })

local UA = Tabs.Misc:AddRightGroupbox("Unlock All", "unlock")
UA:AddButton({ Text = "Load unlock all", Risky = true, DoubleClick = true,
    Tooltip = "Runs a third-party script from flowauth.net (double-click). Its code is not part of this repo.",
    Func = function()
        Notify("Unlock All", "Loading script...", 3)
        local ok, err = pcall(function() loadstring(game:HttpGet("https://flowauth.net/v1/loaders/5d423493a8f0aa8432cda8455a5f8906.lua"))() end)
        Notify("Unlock All", ok and "Script loaded" or ("Error: " .. tostring(err)), ok and 3 or 5)
    end })
UA:AddButton({ Text = "Remove unlock UI", Func = function()
    task.spawn(function()
        local n = 0
        local keys = { "unlock", "unlocksuite", "flowauth", "flow", "authui", "hubui", "keyui", "keysystem", "key", "loader" }
        local function sweep(parent)
            if not parent then return end
            for _, g in ipairs(parent:GetChildren()) do
                if g:IsA("ScreenGui") then
                    local nm = tostring(g.Name):lower()
                    for _, k in ipairs(keys) do
                        if nm:find(k, 1, true) and not nm:find("bb_", 1, true) then
                            if pcall(function() g:Destroy() end) then n = n + 1 end
                            break
                        end
                    end
                end
            end
        end
        sweep(LocalPlayer:FindFirstChildOfClass("PlayerGui"))
        pcall(sweep, CoreGui)
        pcall(function() if gethui then sweep(gethui()) end end)
        Notify("Unlock All", n > 0 and ("Removed " .. n .. " UI") or "No UI found", 3)
    end)
end })

-- ----- Status tab -----
local PL = Tabs.Status:AddBigGroupbox({ Name = "Parry log", Description = "Every parry with its timing -- use it to tune", IconName = "scroll-text" })
local ParryLog = PL:AddLog("ParryLogLines", { Height = 170, MaxLines = 150, Timestamps = true })
local ST = Tabs.Status:AddLeftGroupbox("Live", "activity")
local L_capture = ST:AddLabel("Capture: idle", true)
local L_last = ST:AddLabel("Last parry: none", true)
local L_detect = ST:AddLabel("Detection: clear", true)
local L_clash = ST:AddLabel("Auto spam: off", true)
local L_manual = ST:AddLabel("Manual spam: off", true)
local L_rate = ST:AddLabel("Spam rate: 0/s", true)
local L_ping = ST:AddLabel("Ping: -", true)
local L_curve = ST:AddLabel("Curve: Camera", true)
local SB = Tabs.Status:AddRightGroupbox("Build", "info")
SB:AddLabel("Version: " .. SCRIPT_VERSION)
SB:AddLabel("Idle = nothing connected. Each feature connects only while it's on.", true)

local function set(label, text) pcall(function() label:SetText(text) end) end
StatusHook = function(s)
    if not s then
        set(L_capture, "Capture: idle (engine off)")
        set(L_clash, "Auto spam: off"); set(L_manual, "Manual spam: off")
        set(L_rate, "Spam rate: 0/s"); set(SpamRateLabel, "Actual: 0/s"); set(ClashLabel, "Status: off")
        return
    end
    for _, line in ipairs(Parry.drainLog()) do pcall(function() ParryLog:Log(line) end) end
    if not Library.Toggled then return end
    set(L_capture, "Capture: " .. s.armed)
    set(L_last, "Last parry: " .. s.last)
    set(L_detect, "Detection: " .. s.detect)
    set(L_clash, "Auto spam: " .. s.clash)
    set(L_manual, "Manual spam: " .. s.manual)
    set(L_rate, ("Spam rate: %d/s"):format(math.floor(s.rate + 0.5)))
    set(L_ping, ("Ping: %dms"):format(math.floor(s.ping + 0.5)))
    set(L_curve, "Curve: " .. s.curve)
    set(SpamRateLabel, ("Actual: %d/s (%s)"):format(math.floor(s.rate + 0.5), s.manual))
    set(ClashLabel, "Status: " .. s.clash)
end
UiTick = function(rate) Orb.tick(rate) end

-- ---------------------------------------------------------------------------
-- Unload.
-- ---------------------------------------------------------------------------
Library:OnUnload(function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    pcall(Orb.hide)
    Engine.users = {}
    pcall(Engine.stop)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end)

genv.__BladeBallShutdown = function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    pcall(Orb.hide)
    Engine.users = {}
    pcall(Engine.stop)
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

Notify("Blade Ball", "Rewrite " .. SCRIPT_VERSION .. " loaded. " .. (touchUI and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)

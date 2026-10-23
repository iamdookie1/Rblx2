-- Blade Ball -- clean rewrite
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else -- no game remotes, no
--   RunService connections, no hooks, no module requires, no remote-folder
--   resolve -- only a listener for the kick message, so the log file can say
--   what was on when it came. One Engine owns every parry/spam connection; it starts with the
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
--   * mobile manual-spam switch (tap to toggle, drag to move);
--     no on-screen UI on PC
--   * everything else: auto-parry Keypress mode, random curve, auto ability,
--     cooldown protection, Infinity / Death Slash / Time Hole / Phantom /
--     Slashes of Fury detection, avatar changer, headless, korblox, ball velocity
--     and ping overlays, ability ESP, skin changer, no render, unlock all, parry log

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.5.62"

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
local LOAD_T = clock_()
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
-- on-screen controls only on touch devices with no keyboard (no UI on PC)
local touchUI = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- every GUI we make goes in the executor's hidden container
local function hui()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and typeof(h) == 'Instance' then return h end
    return CoreGui
end
-- A random, innocuous instance name (no "BB_*" giveaway for a name scan).
local function randName()
    local t = {}
    for i = 1, 12 do t[i] = string.char(math.random(97, 122)) end
    return table.concat(t)
end
-- Park a GUI in the hidden container AND mark it protected where the executor
-- supports it, so a CoreGui/instance scan the game can run cannot enumerate it.
-- gethui alone hides it on most executors; protect_gui/protectgui is the
-- belt-and-braces for builds where it doesn't. Our hand-made GUIs (the mobile
-- spam switch, ability ESP, overlays) went in with a plain parent and a
-- distinctive name before this -- unlike the menu library, which protects
-- itself -- so they were the one scannable thing we left in the lobby.
local function hideGui(gui)
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    pcall(function() if protectgui then protectgui(gui) end end)
    pcall(function() if protect_gui then protect_gui(gui) end end)
    pcall(function() gui.Parent = hui() end)
    return gui
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
local feature_log -- the log file writer (set once it exists, below)
-- Round gate for features that listen to game signals / touch game objects:
-- like the original (v91, e852d9c), which bisected the LOBBY reason-24 kick to
-- exactly such listeners attached at load (ability-detection remotes,
-- Runtime.ChildAdded, ...), they only run while you're in a round / training /
-- lobby parry and are torn down the moment you leave. Set below once in_play
-- exists; until then nothing round-only starts.
local round_check = nil
local function Feature(name)
    local f = { name = name, on = false, want = false, round_only = false, _conns = {}, _insts = {}, _token = nil }
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
        self.want = v
        if v and self.round_only and not (round_check and round_check()) then v = false end
        if v == self.on then return end
        self.on = v
        if feature_log then pcall(feature_log, ("%s %s"):format(name, v and "ON" or "OFF")) end
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
    local Core = { cap = nil, pending = nil, misses = 0, interp = 0.14, last_parry = nil,
        ctx = "match", caps = {}, gen = 0, last_send_at = -math.huge }
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
        anticurve = "Smart", dot_threshold = 0.5, curve_bias = 0.5, close_anticurve = true, close_range = 30, instant_retarget = true,
        accuracy = 50, accuracy_base = 50, divisor_multiplier = 1.1, timing_mult = 1,
        extra_distance = 0, ping_compensation = false, retry_delay = 1,
        random_accuracy = false, random_accuracy_amount = 10,
        target_mode = 1, curve_mode = 1, random_curve = false,
        auto_ability = false, cooldown_protection = false,
    }
    local SP = {
        manual = false, auto = false, mode = "Remote", max_rate = 1000, speed_mode = "700/s",
        smart = true, range_bonus = 0, hold = 0.15, sensitivity = 1.3, predictive = true,
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
        if Parry.onLog then pcall(Parry.onLog, text) end -- the log file (see Flight)
    end
    Parry.logp = logp
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

    -- ---------- capture hook (BladeBall.lua v63 @5a84254, ported verbatim) ----------
    -- Swapped in from the proven legacy script per request, in place of the
    -- rewrite's own hook. The hook exists only for the one capture press. While
    -- up it sits on the game's call stack, so the bodies: reject non-parry calls
    -- on the cheapest check first (arg count); are compiled under the Net module's
    -- chunk name so debug.info shows a game path, not ours; run in a clean game
    -- env (getrenv globals, no writefile); and call nothing of ours -- they drop
    -- the send into `box` and pass the call straight on. Our own thread reads the
    -- box and takes the hook down the moment the parry is in (H.check right after
    -- the press -> 0 frames up when the game sends inside the press).
    --
    -- Capture hook dropdown (getgenv.CaptureHook): "Namecall" (__namecall only),
    -- "FireServer" (the FireServer function only), "Both". v63 has no "oth" mode,
    -- so an "oth" setting hooks both channels (it is neither "Namecall" nor
    -- "FireServer"), which still captures.

    -- cached globals the ported hook / body use
    local pcall_, type_, typeof_, tostring_ = pcall, type, typeof, tostring
    local floor_, bxor_, byte_, select_ = math.floor, bit32.bxor, string.byte, select
    local hookfunction_      = hookfunction
    local restore_           = restorefunction
    local hookmetamethod_    = hookmetamethod
    local getnamecallmethod_ = getnamecallmethod
    local getrawmetatable_   = getrawmetatable
    local setreadonly_       = setreadonly or make_writeable
    local newcclosure_       = newcclosure or function(f) return f end
    local flight = logp
    -- the remote's FireServer, resolved in Parry.resolve() (never at load)
    local FIRE_FN
    local JOB_ID = game.JobId

    local H = { fire = nil, nc = nil, want = false, until_t = 0 }

    -- Which hook(s) a capture press uses (Parry tab -> "Capture hook").
    -- getgc (reflection: getgc/getupvalues/getconstants) is detected -- it kicks
    -- even from the lobby, and getgenv().CaptureHook persists across reloads, so
    -- a stale "getgc" is migrated to "Both" here and can never run the scan again.
    -- Default "Namecall": a __namecall hook (hookmetamethod) lives in game's
    -- LOCKED metatable, which a game LocalScript cannot read (getrawmetatable is
    -- exploit-only) -- so the anticheat cannot see it. "Both"/"FireServer" also
    -- replace the shared FireServer function, whose identity a game script CAN
    -- cache and compare, so they are the detectable ones. getgc (reflection) is
    -- always migrated away.
    local function capture_method()
        local m = getgenv().CaptureHook
        if m == nil or m == "getgc" then m = "Namecall" end
        return m
    end
    Core.capture_method = capture_method

    -- __namecall goes back exactly: the original function object written straight
    -- into the metatable (hookmetamethod can re-wrap it on some executors).
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

    -- Builds the capture from a send, on OUR thread (never inside the game's call).
    -- t is the server time the hook read at the moment of the send.
    local function learn(remote, hash, uid, token, a4, t)
        local text = tostring_(floor_(t * 100))
        if #token ~= #text then return end
        local key = {}
        for i = 1, #text do key[i] = bxor_(byte_(token, i), (byte_(text, i) + i) % 256) end
        local prev = Core.cap
        Core.cap = { remote = remote, hash = hash, uid = uid, key = key, len = #text, ball2 = typeof_(a4) == "CFrame" }
        Core.misses, Core.pending = 0, nil
        Core.new_capture = { prev = prev }
    end

    -- A real parry: (hash, id, token, window, cameraCF, points, aim, flag), or on
    -- UseBall2 servers (hash, id, token, cameraCF, mouseCF, flag). Decoy reports
    -- (JobId first) never match.
    local function inspect(entry)
        local self, a = entry[1], entry[3]
        local a1, a2, a3, a4, a5 = a[1], a[2], a[3], a[4], a[5]
        if typeof_(self) == 'Instance' and self.ClassName == 'RemoteEvent'
            and type_(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type_(a2) == 'string' and type_(a3) == 'string'
            and ((type_(a4) == 'number' and typeof_(a5) == 'CFrame') or (typeof_(a4) == 'CFrame' and typeof_(a5) == 'CFrame')) then
            learn(self, a1, a2, a3, a4, entry[4])
            return true
        end
        return false
    end

    -- ISOLATED HOOK BODIES. Compiled under the Net module's chunk name, run in a
    -- clean game env, and cut off from us: they drop the send into `box` and pass
    -- the call straight on. The cheapest check (arg count) is first, so almost
    -- every call the game makes while the hook is up costs one select() before
    -- passing on.
    local box = { want = false, nc = nil, fire = nil, list = {}, ws = Workspace, now = Workspace.GetServerTimeNow }
    local HOOK_NAME = "=ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net"
    local NC_SRC = [[
local box, getncm, sel = ...
return function(self, ...)
    if sel("#", ...) >= 6 and box.want and getncm() == "FireServer" then
        local l = box.list
        if #l < 4 then l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)} end
    end
    return box.nc(self, ...)
end]]
    local FIRE_SRC = [[
local box, sel = ...
return function(self, ...)
    if sel("#", ...) >= 6 and box.want then
        local l = box.list
        if #l < 4 then l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)} end
    end
    return box.fire(self, ...)
end]]
    local CLEAN_ENV
    do
        local ok, renv = pcall(function() return getrenv and getrenv() end)
        CLEAN_ENV = (ok and type(renv) == 'table' and renv.writefile == nil) and setmetatable({}, { __index = renv }) or {}
    end
    local function build_body(src, chunk, ...)
        local args = table.pack(...)
        local ok, fn = pcall(function()
            local factory = loadstring(src, chunk or HOOK_NAME)
            if setfenv then setfenv(factory, CLEAN_ENV) end
            return factory(table.unpack(args, 1, args.n))
        end)
        return ok and type(fn) == 'function' and fn or nil
    end
    -- PLAIN closures -- NO loadstring, NO chunk-name disguise. The old isolated
    -- bodies were compiled at LOAD under a chunk name that impersonated the real
    -- Net module path (=ReplicatedStorage...sleitnick_net....net); creating that
    -- impostor chunk at load is what the anticheat kicked on in the lobby (with
    -- every feature off, hook never armed). It bought nothing: the sender's two
    -- honeypots (debug.info hooked, writefile in a getfenv(i) walk) run at the
    -- TOP of the sender, BEFORE it calls FireServer, so our hook is never on the
    -- stack during that walk -- the hook body's env/name is irrelevant to them.
    -- So these are ordinary closures, built with no loadstring at all.
    Core.isolated = false
    local NC_BODY = function(self, ...)
        if select_("#", ...) >= 6 and box.want and getnamecallmethod_() == "FireServer" then
            local l = box.list
            if #l < 4 then l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws) } end
        end
        return box.nc(self, ...)
    end
    local FIRE_BODY = function(self, ...)
        if select_("#", ...) >= 6 and box.want then
            local l = box.list
            if #l < 4 then l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws) } end
        end
        return box.fire(self, ...)
    end

    local function unhook()
        local fire, nc = H.fire, H.nc
        H.fire, H.nc, H.want, box.want = nil, nil, false, false
        if fire and not (restore_ and pcall_(restore_, FIRE_FN)) then pcall_(hookfunction_, FIRE_FN, fire) end
        if nc then restore_namecall(nc) end
        box.nc, box.fire = nil, nil
    end
    Core.unhook = unhook

    -- Up for one capture press. Our thread watches the box every frame; the first
    -- real parry in it becomes the capture and the hook comes off. H.check lets a
    -- caller take it down synchronously right after the press (0 frames up when
    -- the game sent inside the press).
    local function arm(hold)
        if Core.cap or not is_live() then return false end
        if capture_method() == "getgc" then return false end -- getgc method never hooks
        H.want, H.until_t = true, clock_() + (hold or 0.2)
        if H.fire or H.nc then return true end
        box.list = {}
        local method = capture_method()
        if method ~= "Namecall" and hookfunction_ and FIRE_FN then
            local ok, old = pcall(hookfunction_, FIRE_FN, newcclosure_(FIRE_BODY))
            if ok and type(old) == 'function' then H.fire, box.fire = old, old end
        end
        if method ~= "FireServer" and hookmetamethod_ and getnamecallmethod_ then
            local ok, old = pcall(hookmetamethod_, game, "__namecall", newcclosure_(NC_BODY))
            if ok and type(old) == 'function' then H.nc, box.nc = old, old end
        end
        if not (H.fire or H.nc) then H.want = false; return false end
        box.want = true
        local up_at = clock_()
        local done = false
        local function finish()
            if done then return end
            done = true
            unhook()
            box.list = {}
            pcall(flight, ("hook (%s) was up %.1fms -- %s"):format(capture_method(), (clock_() - up_at) * 1000,
                Core.cap and "caught the parry" or "nothing caught"))
        end
        -- Checks what the hook has seen; takes it down the moment the parry is in.
        H.check = function()
            if done then return true end
            local l = box.list
            for i = 1, #l do
                if pcall_(inspect, l[i]) and Core.cap then break end
            end
            if Core.cap then finish(); return true end
            return false
        end
        task.spawn(function()
            while not done and (H.fire or H.nc) and clock_() < H.until_t do
                task.wait()
                if H.check() then return end
            end
            finish()
        end)
        return true
    end

    -- hook state line for the Status tab / flight log
    function Parry.hookState()
        if H.fire or H.nc then return "UP right now (capturing)" end
        return "down"
    end

    -- ---------- glue the rest of the rewrite calls ----------
    -- Kept from the rewrite so nothing outside the hook changes. The v63 hook does
    -- not size its own window or track dry/lat, so capture_window is a fixed hold
    -- and the Capture table just carries the fields prime_capture / spam read.
    local Capture = { mode = "Your press", armed_at = 0, dry = 0, last_spam_key = -math.huge, lat = nil, last_press = -math.huge, since = nil }
    Parry.Capture = Capture
    local function capture_window() return 0.2 end
    local function pressBlockKey()
        if not is_live() then return false end
        Core.last_send_at = clock_()
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        end)
        return true
    end
    -- a native block press (the game sends the parry and animates it); with
    -- capture = true the hook is up for it so its packet becomes the capture.
    -- H.check right after the press takes the hook down inside the press when the
    -- game already sent (0 frames up).
    local function key_parry(capture)
        if capture then arm(capture_window()) end
        local r = pressBlockKey()
        if capture and H.check then H.check() end
        return r
    end
    local function in_lobby_training()
        if not LocalPlayer:GetAttribute("LobbyTraining") then return false end
        local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
        return char ~= nil and dead ~= nil and char.Parent == dead
    end

    -- ---------- no-hook reflection probe (read-only) ----------
    -- Step 1 of the hook-free "forge" path. It walks the game's own parry handler
    -- (UserInputService.InputBegan -> the controller's block handler -> v190 ->
    -- v50 -> v31, the sender) purely with getconnections + getupvalues and LOGS
    -- what it finds -- the remote, the 36-char hash, the uid holder and the key
    -- deriver. It only READS upvalues; it never calls the sender or the deriver,
    -- so the sender's honeypots (which fire only when it is CALLED) stay quiet.
    -- Safe to run anywhere. The log tells us the exact upvalue layout to wire the
    -- live forge (build a token from the key, FireServer ourselves -- no hook).
    local function reflect_getups()
        local g = (getgenv and getgenv()) or {}
        return rawget(g, "getupvalues") or getupvalues or (debug and debug.getupvalues)
    end
    local function reflect_connfn(c)
        for _, k in ipairs({ "Function", "function" }) do
            local ok, f = pcall(function() return c[k] end)
            if ok and type(f) == "function" then return f end
        end
        return nil
    end
    local function reflect_isNet(v)
        if typeof(v) ~= "table" then return false end
        local re; pcall(function() re = rawget(v, "RemoteEvent") or v.RemoteEvent end)
        return type(re) == "function"
    end
    local function reflect_classify(v)
        local t = typeof(v)
        if t == "string" then return ("string(#%d)%s"):format(#v, #v == 36 and " <-- hash?" or "") end
        if t == "Instance" then return ("Instance<%s \"%s\">"):format(v.ClassName, v.Name) end
        if t == "function" then
            local ok, s = pcall(function() return debug.info(v, "s") end)
            return "function" .. (ok and (" @" .. tostring(s)) or "")
        end
        if t == "table" then return reflect_isNet(v) and "table <-- Net?" or "table" end
        return t
    end
    -- dump a function's upvalues (optionally one level into table upvalues) to the log
    local function reflect_dump(fn, getups, label)
        local ok, ups = pcall(getups, fn)
        if not ok or type(ups) ~= "table" then logp(("reflect: getupvalues(%s) failed: %s"):format(label, tostring(ups))); return false end
        local n = 0
        for i, v in pairs(ups) do
            n = n + 1
            logp(("   %s up[%s] = %s"):format(label, tostring(i), reflect_classify(v)))
            -- one level into a Net-ish or uid-ish table so we can spot hash/uid strings
            if typeof(v) == "table" and not reflect_isNet(v) then
                local ok2 = pcall(function()
                    local c = 0
                    for k, vv in pairs(v) do
                        c = c + 1; if c > 6 then break end
                        logp(("       .%s = %s"):format(tostring(k), reflect_classify(vv)))
                    end
                end)
            end
        end
        if n == 0 then logp(("reflect: %s has no upvalues (maybe stripped)"):format(label)) end
        return true
    end
    local function reflect_trunc(s) s = tostring(s); return #s > 64 and (s:sub(1, 64) .. "..") or s end
    -- dump a function's string constants (reveals method names, "TIME", marker
    -- strings, arg patterns -- i.e. the real send logic vs decoy/snitch paths)
    local function reflect_consts(fn, label)
        local gc = debug and debug.getconstants
        if type(gc) ~= "function" then return false end
        local ok, cs = pcall(gc, fn)
        if not ok or type(cs) ~= "table" then return true end
        local out, n = {}, 0
        for _, c in pairs(cs) do
            if type(c) == "string" and #c > 0 then n = n + 1; out[#out + 1] = reflect_trunc(c); if n >= 48 then break end end
        end
        if #out > 0 then logp(("reflect: %s consts: %s"):format(label, table.concat(out, " | "))) end
        return true
    end
    -- read-only deep dump of the sender: concrete string-upvalue values (hashes /
    -- keys), the resolved uid, the Net table's keys, and the sender's + nested
    -- protos' string constants (the real FireServer/token logic usually lives in a
    -- nested proto). Nothing is called or fired.
    local function reflect_deep(v31, getups)
        local ok, ups = pcall(getups, v31)
        if not ok or type(ups) ~= "table" then return end
        for i, v in pairs(ups) do
            if type(v) == "string" then logp(("reflect: up[%s] value = %s"):format(tostring(i), reflect_trunc(v))) end
            if typeof(v) == "table" and not reflect_isNet(v) then
                pcall(function()
                    local idx, tbl = v[1], v[2]
                    if type(tbl) == "table" and idx ~= nil then
                        logp(("reflect: up[%s] uid-holder? [1]=%s [3]=%s -> [2][[1]]=%s"):format(
                            tostring(i), tostring(idx), reflect_trunc(v[3]), reflect_trunc(tbl[idx])))
                    end
                end)
            end
            if reflect_isNet(v) then
                pcall(function()
                    local ks = {}
                    for k in pairs(v) do ks[#ks + 1] = tostring(k); if #ks >= 14 then break end end
                    logp(("reflect: up[%s] (Net) keys: %s"):format(tostring(i), table.concat(ks, ", ")))
                end)
            end
        end
        local gotc = reflect_consts(v31, "v31")
        if not gotc then logp("reflect: debug.getconstants unavailable") end
        local gp = debug and debug.getprotos
        if type(gp) == "function" then
            local ok2, ps = pcall(gp, v31)
            if ok2 and type(ps) == "table" then
                logp(("reflect: v31 has %d nested proto(s)"):format(#ps))
                for pi, pf in ipairs(ps) do reflect_consts(pf, "proto#" .. pi); if pi >= 6 then break end end
            end
        else
            logp("reflect: debug.getprotos unavailable")
        end
    end
    function Parry.reflectProbe()
        local getups = reflect_getups()
        if type(getups) ~= "function" then logp("reflect: getupvalues NOT available on this executor"); return end
        -- Primary: the sender is require(ReplicatedStorage.Controllers.SwordsController.PRY).
        -- Requiring an already-loaded ModuleScript returns its CACHED value -- no code
        -- runs, no traps -- and it is the same sender the game uses, so its upvalues
        -- (remote, hash, uid, key deriver) are readable directly. No getgc, no hook.
        -- Names on this path carry an invisible/odd character (the dump shows
        -- "SwordsController .PRY" with a stray space), so FindFirstChild by exact
        -- name misses. Match on alphanumerics only, which drops any such char.
        local function clean(s) return (tostring(s):gsub("[^%w]", "")) end
        local pry
        pcall(function()
            local c = ReplicatedStorage:FindFirstChild("Controllers")
            local sc = c and c:FindFirstChild("SwordsController")
            pry = sc and sc:FindFirstChild("PRY")
        end)
        if not pry then
            pcall(function()
                for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
                    if d:IsA("ModuleScript") and clean(d.Name):upper() == "PRY" then
                        local p = d.Parent
                        if p and clean(p.Name):find("[Ss]word") then pry = d; break end
                        pry = pry or d
                    end
                end
            end)
        end
        if pry then
            logp(("reflect: found module '%s' at %s"):format(pry.Name, pry:GetFullName()))
            logp("reflect: name bytes = " .. table.concat({ string.byte(pry.Name, 1, math.min(#pry.Name, 20)) }, ","))
            logp("reflect: requiring (cached, read-only)...")
            local ok, v31 = pcall(require, pry)
            if not ok then
                logp("reflect: require(PRY) errored: " .. tostring(v31))
            elseif type(v31) == "function" then
                logp("reflect: PRY returned a FUNCTION (the sender). Upvalues:")
                reflect_dump(v31, getups, "v31")
                reflect_deep(v31, getups)
                logp("reflect: done (read-only, nothing called/fired). Send me these lines.")
                return
            elseif type(v31) == "table" then
                logp("reflect: PRY returned a TABLE; dumping its function fields' upvalues:")
                local c = 0
                for k, vv in pairs(v31) do
                    if type(vv) == "function" then c = c + 1; reflect_dump(vv, getups, "PRY." .. tostring(k)) end
                    if c > 8 then break end
                end
                logp("reflect: done (read-only). Send me these lines.")
                return
            else
                logp("reflect: PRY returned a " .. typeof(v31) .. " (unexpected).")
            end
        else
            logp("reflect: ReplicatedStorage.Controllers.SwordsController.PRY not found (path changed?)")
        end
        -- Fallback: walk InputBegan handlers' upvalues (no getgc).
        local getconns = getconnections
        if type(getconns) ~= "function" then logp("reflect: getconnections unavailable; cannot fall back"); return end
        local ok, conns = pcall(getconns, UserInputService.InputBegan)
        if not ok or type(conns) ~= "table" then logp("reflect: getconnections(InputBegan) failed: " .. tostring(conns)); return end
        logp(("reflect: fallback -- scanning %d InputBegan handlers (read-only)..."):format(#conns))
        local seen, found = {}, {}
        local function scan(fn, depth)
            if depth > 6 or type(fn) ~= "function" or seen[fn] then return end
            seen[fn] = true
            local ok2, ups = pcall(getups, fn)
            if not ok2 or type(ups) ~= "table" then return end
            local has36, hasNet = false, false
            for _, v in pairs(ups) do
                if typeof(v) == "string" and #v == 36 then has36 = true end
                if reflect_isNet(v) then hasNet = true end
            end
            if has36 and hasNet then found[#found + 1] = fn end
            for _, v in pairs(ups) do if type(v) == "function" then scan(v, depth + 1) end end
        end
        for _, c in ipairs(conns) do local f = reflect_connfn(c); if f then scan(f, 0) end end
        if #found == 0 then
            logp("reflect: fallback found no sender candidate either. Send me the PRY lines above.")
            return
        end
        logp(("reflect: fallback found %d candidate(s):"):format(#found))
        for n, fn in ipairs(found) do reflect_dump(fn, getups, "cand" .. n); if n >= 2 then break end end
        logp("reflect: done (read-only). Send me these lines.")
    end

    -- ---------- getgc capture backend (CaptureHook = "getgc") ----------
    -- No hook, no key press, no getupvalues, no forging: it acquires the game's
    -- own parry sender closure (require(PRY), or a getgc scan) and parries by
    -- CALLING it on a clean thread -- the game builds the real token and fires
    -- the real remote itself. See the gc_acquire / gc_fire block below.
    local function forge_find_pry()
        local function clean(s) return (tostring(s):gsub("[^%w]", "")) end
        local p
        pcall(function()
            local c = ReplicatedStorage:FindFirstChild("Controllers")
            local sc = c and c:FindFirstChild("SwordsController")
            p = sc and sc:FindFirstChild("PRY")
        end)
        if not p then
            pcall(function()
                for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
                    if d:IsA("ModuleScript") and clean(d.Name):upper() == "PRY" then
                        local par = d.Parent
                        if par and clean(par.Name):find("[Ss]word") then p = d; break end
                        p = p or d
                    end
                end
            end)
        end
        return p
    end
    local GC = { last_msg = nil }
    function GC.clean(s) return (tostring(s):gsub("[^%w]", "")) end
    function GC.is_lua(f)
        if type(f) ~= "function" then return false end
        if type(iscclosure) == "function" then
            local ok, c = pcall(iscclosure, f)
            if ok then return not c end
        end
        local ok, src = pcall(debug.info, f, "s")
        return ok and src ~= "[C]"
    end
    -- The game's own F-key parry handler v186 (SwordsController, Bbs dump):
    --   v7.InputBegan:Connect(function(p32,p33) if ... UseBind(p32,"Block") then v186() end end)
    --   local function v186(p31) xpcall(...Deactivate...);
    --       return not not v49(v184.CharacterSword or "Base Sword",
    --           v184.SwordType or "Single", v184.AnimationCollection or "Single", not not p31) end
    -- v186 -> v49 computes the SERVER-VALIDATED parry window (n6, from timesParried:
    -- 1.5/1.25/1.0/0.75/0.625...), builds the target points, PLAYS the parry
    -- animation, and only then calls the real sender v31. Calling v31 raw (0.5.42)
    -- skipped the window and the animation -> server kicked "[CODE HSH-2]". So call
    -- v186() with no args, exactly as the key press does -- the game does the rest.
    -- v186 is identified by its string constants ("CharacterSword","Base Sword",
    -- "AnimationCollection") via getconstants -- NOT getupvalues (the detected op).
    local function fn_consts(f)
        local gc = (debug and debug.getconstants) or getconstants
        if type(gc) ~= "function" then return nil end
        local ok, cs = pcall(gc, f)
        return ok and type(cs) == "table" and cs or nil
    end
    local function is_handler(o)
        local cs = fn_consts(o)
        if not cs then return false end
        local hasCS, hasBase, hasAC = false, false, false
        for _, c in pairs(cs) do
            if c == "CharacterSword" then hasCS = true
            elseif c == "Base Sword" then hasBase = true
            elseif c == "AnimationCollection" then hasAC = true end
        end
        return hasCS and hasBase and hasAC
    end
    local gc_scan = { handler = nil, started = false, done = false }
    local function gc_scan_start()
        if gc_scan.started then return end
        if type(getgc) ~= "function" then gc_scan.done = true; return end
        gc_scan.started = true
        task.spawn(function()
            local list
            pcall(function() list = getgc(false) end)
            if type(list) == "table" then
                for idx = 1, #list do
                    if not is_live() then break end
                    local o = list[idx]
                    if type(o) == "function" and GC.is_lua(o) then
                        local oks, src = pcall(debug.info, o, "s")
                        if oks and type(src) == "string" then
                            local c = GC.clean(src)
                            if c:find("SwordsController") and not c:find("PRY") and is_handler(o) then
                                gc_scan.handler = o; break
                            end
                        end
                    end
                    if idx % 300 == 0 then task.wait() end
                end
            end
            list = nil
            gc_scan.done = true
            logp(gc_scan.handler and "getgc: parry handler (v186) found -- calling it directly"
                or "getgc: parry handler not found in scan")
        end)
    end

    -- ---------- getgc: CALL the game's own parry handler (no upvalues, no key) ----
    local gc_fail_at = -math.huge
    function GC.log(msg) if msg ~= GC.last_msg then GC.last_msg = msg; logp(msg) end end
    local function gc_acquire()
        if type(GC.dispatcher) == "function" then
            if not Core.cap then Core.cap = { gc = true } end
            return true
        end
        if clock_() - gc_fail_at < 1 then return false end
        -- "handler" (default) = call v186 (the real F-key handler, found via getgc);
        -- "pry" = call the raw sender v31 from require(PRY) (0.5.42 behaviour, for
        -- comparison only -- it sends the wrong window and HSH-2 kicks).
        local mode = getgenv().GcSender or "handler"
        local fn, kind
        if mode == "pry" then
            local pry = forge_find_pry()
            if pry then local ok, m = pcall(require, pry); if ok and type(m) == "function" then fn, kind = m, "pry" end end
        else
            if type(gc_scan.handler) == "function" then fn, kind = gc_scan.handler, "handler"
            else
                gc_scan_start()
                if not gc_scan.done then return false end     -- still scanning; quiet
                fn = gc_scan.handler; if type(fn) == "function" then kind = "handler" end
            end
        end
        if type(fn) ~= "function" then gc_fail_at = clock_(); GC.log("getgc: parry function not found (mode=" .. mode .. ")"); return false end
        -- the ONE clean dispatcher, built once. task.spawn(dispatcher) runs it as
        -- the thread's main function, so when the sender's getfenv(i) stack-walk
        -- runs (inside v31, reached via v186->v49), every frame up to ours is game
        -- code and the top frame is this clean wrapper (writefile nil) -- both
        -- honeypots pass. GcChunk=false skips the single debug.info source read.
        local chunk
        if getgenv().GcChunk ~= false then pcall(function() chunk = debug.info(fn, "s") end) end
        local job = { n = 0 }
        local disp = build_body([[
local job, fn = ...
return function() fn(table.unpack(job, 1, job.n)) end]], chunk, job, fn)
        if type(disp) ~= "function" then gc_fail_at = clock_(); GC.log("getgc: could not build a clean dispatcher (no loadstring?)"); return false end
        GC.fn, GC.kind, GC.job, GC.dispatcher = fn, kind, job, disp
        Core.cap = { gc = true }
        Core.misses, Core.pending = 0, nil
        GC.log("getgc: parry acquired (" .. kind .. ") -- calling the game's own parry function (no upvalues, no key, no forge)")
        return true
    end
    -- fire one real parry on a fresh clean thread
    local function gc_fire(spam)
        if type(GC.dispatcher) ~= "function" then return "unarmed" end
        if not is_live() then return "blocked" end
        if not canParryNow() then return "blocked" end
        if not spam and not gate_open() then return "blocked" end
        if not spam then gate_start() end
        Core.last_send_at = clock_()
        local job = GC.job
        if GC.kind == "handler" then
            -- v186(): no args, exactly as the F-key / tap handler calls it. v186 ->
            -- v49 builds the correct window, targets and animation and fires itself.
            job.n = 0
        else
            -- raw sender v31(window, cameraCF, points, aim, flag) -- comparison only
            local cam = Workspace.CurrentCamera
            if not cam then return "blocked" end
            local window = parry_window()
            local points, aim = packet_parts(cam)
            local name, _, mode = choose_target(cam)
            if name and mode ~= "Cursor" then local sp = points[name]; if sp then aim = { sp.X, sp.Y } end end
            local cf = cam.CFrame
            local look = curve_look_cached(cam)
            if look then local o = cf.Position; cf = CFrame.lookAt(o, o + look) end
            if getgenv().GcBall2 then
                local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
                job[1], job[2], job[3], job[4], job[5] = cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false, nil, nil
                job.n = 3
            else
                job[1], job[2], job[3], job[4], job[5] = window, cf, points, aim, false
                job.n = 5
            end
        end
        task.spawn(GC.dispatcher)
        if not spam then Core.pending = clock_() + (parry_window() or 0.5) + ping_s() + 0.25 end
        return "sent"
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
        if cap.gc then return gc_fire(spam) end   -- getgc: call the game's own sender
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
        Core.last_send_at = clock_()
        local r = cap.remote
        if cap.ball2 then
            local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
            r:FireServer(cap.hash, cap.uid, tok, cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
        else
            r:FireServer(cap.hash, cap.uid, tok, window, cf, points, aim, false)
        end
        if not spam then Core.pending = clock_() + window + ping_s() + 0.25; cap.sent = (cap.sent or 0) + 1 end
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
        if st.hm and st.hm.k then st.k_mem = st.hm.k end -- the ball's turn, kept for the next pass
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
            local was_me = st.target == me
            st.target = new
            if type(new) == 'string' and new ~= '' and new ~= me then
                st.pass_open, st.parried, st.landed = false, false, false
                -- it left US for someone else: our parry landed (only a parry sends
                -- it on). Open the lockout now instead of waiting a ping for the
                -- ParrySuccess message -- in a close exchange the ball is often
                -- back before that message, and the gate held the parry.
                if was_me then G.until_t = 0 end
            end
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
    local function fire_one()
        if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
        if SP.mode == "Keypress" and Pump.frame_fires >= 1 then return false end
        local ok, remote = false, false
        if SP.mode == "Keypress" then ok = pressBlockKey()
        elseif not Core.cap and capture_method() == "getgc" then
            -- getgc method: acquire the sender (no hook, no press, no upvalues)
            if clock_() - Capture.last_spam_key < 0.3 then return false end
            Capture.last_spam_key = clock_()
            if gc_acquire() then ok = send(true) == "sent"; remote = ok end
        elseif not Core.cap then
            -- no capture yet. Default: wait for the player's own real parry (no
            -- synthetic press). "Auto press" capture bootstraps with a native press.
            if Capture.mode ~= "Auto press" then return false end
            if clock_() - Capture.last_spam_key < 0.3 then return false end
            Capture.last_spam_key = clock_()
            ok = key_parry(true)
        else
            ok = send(true) == "sent"
            remote = ok
        end
        Pump.frame_fires = Pump.frame_fires + 1
        if ok then SpamMeter.count = SpamMeter.count + 1 end
        -- getgc's handler plays the game's own swing; don't add ours on top
        if capture_method() == "getgc" then remote = false end
        Pump.remote_sent = Pump.remote_sent or remote
        return ok
    end
    -- Holds the parries-a-second at the slider value at any FPS:
    --   * credit grows with real time and carries ~2 frames (>= 50ms), so a 30 FPS
    --     frame (33ms) no longer overflows it (0.5.2 kept 15ms: ~5% short at 30 FPS,
    --     up to 12% short across hitches);
    --   * a parry that can't go out right now (stunned, respawning, no capture)
    --     keeps its credit instead of being counted as sent (0.5.2 lost ~5% there).
    -- Simulated against real frame timing (3 signal points a frame, jitter,
    -- hitches, blocked moments): 100% of target from 30 to 240 FPS, 300-2000/s.
    -- Spam speed: the picked rate ("50/s" .. "1000/s"), held exactly by the
    -- bucket below at any FPS.
    function SP.rate_now(now)
        return tonumber(tostring(SP.speed_mode):match("%d+")) or 700
    end
    local function spam_tick(now)
        local elapsed = math.min(now - Pump.last, 0.25)
        Pump.last = now
        local span = now - SpamMeter.since
        if span >= 1 then SpamMeter.rate, SpamMeter.count, SpamMeter.since = SpamMeter.count / span, 0, now end
        local source = current_source(now)
        if not source or not LocalPlayer.Character then Pump.on, Pump.waiting = false, false; return end
        local focus = spam_focus()
        -- Smart stop: manual spam holds fire while nothing is a threat
        if source == "manual" and SP.smart and not focus then Pump.on, Pump.waiting = false, true; return end
        Pump.waiting = false
        -- the rate is EXACTLY the slider value (20-2000/s), no network throttle.
        local rate = math.clamp(SP.rate_now(now), 1, 2000)
        if SP.mode == "Keypress" then rate = math.min(rate, 1 / frame_dt) end
        rate = math.max(rate, 1)
        -- STRICT time bucket: the number allowed so far is rate x (time since the
        -- bucket started); fire until sent reaches it, so the average is exactly
        -- the slider at any FPS (a long frame pays exactly what it owes). When a
        -- fire is blocked (stunned, respawn, no capture), the owed backlog is
        -- forgiven -- the start slides to now -- so it never bursts over the rate
        -- once it can fire again.
        if not Pump.on then Pump.on, Pump.rate, Pump.t0, Pump.sent = true, rate, now, 0
        elseif Pump.rate ~= rate then Pump.rate, Pump.t0 = rate, now - Pump.sent / rate end -- re-rate, no burst
        local allowed = math.floor((now - Pump.t0) * rate) + 1
        local sent = false
        while Pump.sent < allowed do
            if not fire_one() then Pump.t0 = now - (Pump.sent - 1) / rate; break end
            Pump.sent = Pump.sent + 1
            sent = true
        end
        -- one animation call per tick, through the held-key gate, and only for
        -- remote sends (a native press -- Keypress mode or a capture press -- has
        -- the game's own swing)
        if sent and Pump.remote_sent then Anim.spamBlock() end
        Pump.remote_sent = false
    end
    local function spam_instant()
        local source = current_source(clock_())
        if not source or not LocalPlayer.Character then return end
        if source == "manual" and SP.smart and not spam_focus() then return end
        -- counted against the same bucket (at most one ahead of it), so instant
        -- fires on retarget / parry success never push the average over the slider
        local now = clock_()
        local rate = math.max(math.clamp(SP.rate_now(now), 1, 2000), 1)
        if not Pump.on then Pump.on, Pump.rate, Pump.t0, Pump.sent = true, rate, now, 0
        elseif Pump.rate ~= rate then Pump.rate, Pump.t0 = rate, now - Pump.sent / rate end
        if Pump.sent > math.floor((now - Pump.t0) * rate) + 1 then return end
        if fire_one() then
            Pump.sent = Pump.sent + 1
            if Pump.remote_sent then Anim.spamBlock() end
        end
        Pump.remote_sent = false
    end
    function Parry.spamWaiting() return Pump.waiting end

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
    local function fire(st, now, via, info, ball)
        local how
        -- getgc capture method: get / refresh the capture by reflection (never a
        -- hook, never a press), and if that can't produce one, skip rather than
        -- fall back to a hook.
        if capture_method() == "getgc" and S.parry_mode ~= "Keypress" then
            if not Core.cap then pcall(gc_acquire) end
            if not Core.cap then return false end
        end
        -- Wait-for-your-parry hook capture (the default): never synthesize a press
        -- to capture or refresh -- forge only once the player's own parry has been
        -- read. With no key yet, do nothing and let prime_capture read the next
        -- real block. The "Auto press" capture mode restores the synthetic bootstrap.
        local hookmode = capture_method() ~= "getgc" and S.parry_mode ~= "Keypress"
        if hookmode and Capture.mode ~= "Auto press" and not Core.cap then return false end
        -- no capture yet, or the last remote parry went unanswered (the capture
        -- may be stale): this parry is a native press, which parries by itself
        -- and takes / refreshes the capture on the way. Only in "Auto press" capture mode;
        -- getgc never goes "fresh" (it calls the game's own sender).
        local fresh = hookmode and Capture.mode == "Auto press" and (not Core.cap or Core.misses >= 1)
        if try_ability() then how = "ability"
        elseif S.parry_mode == "Keypress" or fresh then
            if not gate_open() or not canParryNow() then return false end
            key_parry(fresh); gate_start()
            how = not fresh and "key" or (Core.cap and "key, refreshing capture" or "key, capturing")
        else
            if send(false) ~= "sent" then return false end
            how = "remote"
            -- getgc calls the game's own parry handler, which plays the real
            -- swing; only a forged remote parry needs our animation
            if capture_method() ~= "getgc" then Anim.block() end
        end
        Core.last_parry = { t = now, via = via, info = info }
        -- a key press is answered (or not) like a remote parry: same miss check
        if how ~= "remote" and how ~= "ability" then Core.pending = clock_() + (parry_window() or 0.5) + ping_s() + 0.3 end
        -- watch this ball until the parry is answered: when it actually got
        -- closest to us says whether a miss was early, late, or on time
        local root = getRoot()
        Core.watch = ball and root and { ball = ball, t = now, how = how, d0 = (ball.Position - root.Position).Magnitude,
            min_d = math.huge, min_t = now, ping = ping_s(), W = parry_window() or 0.5, lead = info and info.lead,
            cap = how == "remote" and Core.cap or nil } or nil
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
    -- The decision for a ball on us. via: "retarget" (it just switched to us),
    -- "velocity" (its new direction just replicated), or nil (a frame point).
    -- One model for all of them (retarget and close range are built in):
    --   earliest = flying straight in from here (it can't land sooner);
    --   eta      = its real path: straight in, or its homing turn simulated from
    --              where it points now (the gain measured on this ball, kept
    --              across passes, taken at the slow end -- a longer path is the
    --              safe side). At a retarget its velocity still points at the old
    --              target, which is exactly the turn the sim plays out.
    -- Fire when eta is down to the lead (accuracy/cushion inside the window), or
    -- NOW when even flying straight it lands before the next chance to fire --
    -- that is close range by TIME, not by distance, whatever direction it reads.
    local function decide(ball, st, root, now, via)
        if pass_busy(st, now) or blocked_by_detection() then return end
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
        local h = track_homing(st, dir, want, dist, now)
        local earliest = time_to_contact(dist, gap, speed, accel)
        local lead = math.min(fire_lead(speed), reach + W * 0.85)
        local eta = earliest
        if heading < 0.97 then
            if h.k then st.k_mem = h.k end
            local k = math.clamp((h.k or st.k_mem or K_DEFAULT) * 0.85, K_MIN, K_MAX)
            local v = vel
            if heading < -0.95 then
                -- dead away: nudge it off the line so the sim can turn it round
                local side = dir:Cross(Vector3.yAxis)
                if side.Magnitude < 1e-3 then side = dir:Cross(Vector3.xAxis) end
                v = (dir + side.Unit * 0.08).Unit * speed
            end
            eta = math.max(sim_prop(bpos, v, rpos, gap, k, accel, reach + W + 0.8) or math.huge, earliest)
            -- curving: lean a little earlier -- inside the window early is safe, late is fatal
            lead = math.min(lead + W * 0.25 * (S.curve_bias or 0.5) * (1 - math.max(heading, 0)), reach + W * 0.85)
        end
        local info = { speed = speed, dist = dist, heading = heading, lead = lead, eta = eta }
        local name = via == "retarget" and "retarget" or (via == "velocity" and "auto parry (velocity)" or "auto parry")
        -- now or never
        local margin = math.max(frame_dt * 2, jitter()) + 0.02
        if rem <= 3 or (earliest <= reach + margin and (heading > -0.5 or dist <= 14)) then
            info.eta = earliest
            return fire(st, now, name .. " (close)", info, ball)
        end
        if eta <= lead then return fire(st, now, name, info, ball) end
        -- classic distance net for a ball coming nearly straight in
        if heading >= 0.85 and dist <= parry_distance(speed) and earliest <= reach + W * 0.85 then
            return fire(st, now, name, info, ball)
        end
    end

    local function trigger(ball, st, now)
        if pass_busy(st, now) or has_clash(ball, now) or blocked_by_detection() then return end
        fire(st, now, "triggerbot", nil, ball)
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
            if has_clash(ball, now) then spam_instant() end
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
    -- ===================== proactive capture =====================
    -- The old method, made safe: with no capture, press block to take one ahead
    -- of time -- 1s after you can parry, then every 1.4s until it's in, pausing
    -- 20s after 3 dry presses -- so you're armed before any ball comes to you.
    -- The press is a real swing that opens the game's 1.3s lockout, so it only
    -- goes when no ball can reach you inside that lockout (before 0.5.4 it
    -- pressed regardless, and a ball arriving just after was parried late --
    -- "animation, no parry"). If a ball is due before a safe moment comes, the
    -- parry itself is a native press that captures (see fire).
    local function capture_safe()
        local root = getRoot()
        if not root then return false end
        for _, ball in ipairs(get_live_balls()) do
            if ball:GetAttribute('target') == me then return false end
            local speed = ball_velocity(ball).Magnitude
            local d = (ball.Position - root.Position).Magnitude
            -- could turn to us and land before the lockout's over
            if d < 20 or (speed > 1 and d / speed < 1.6) then return false end
        end
        return true
    end
    local function needs_capture()
        return ((S.autoparry or S.triggerbot) and S.parry_mode ~= "Keypress") or ((SP.manual or SP.auto) and SP.mode ~= "Keypress")
    end
    local function prime_capture(now)
        if Core.cap or not needs_capture() then return end
        if capture_method() == "getgc" then pcall(gc_acquire); return end
        if not (in_match() or in_lobby_training()) or not canParryNow() then Capture.since = nil; return end
        Capture.since = Capture.since or now
        -- Synthetic-press bootstrap ("Auto press" capture mode): when no
        -- ball is near, a VirtualInputManager Block press goes out and the hook
        -- reads its packet. Off by default -- synthetic input can be flagged, and
        -- a press that does not actually parry captures nothing.
        if Capture.mode == "Auto press" then
            if now - Capture.since < 1 or now - Capture.last_press < 1.4 then return end
            if Capture.dry >= 3 then
                if now - Capture.last_press < 20 then return end
                Capture.dry = 0
            end
            if not gate_open() or not capture_safe() then return end
            Capture.last_press = now
            local window = capture_window()
            if arm(window) then
                pressBlockKey(); gate_start()
                logp(("capture press (%s, %s, hook up <= %.0fms, no ball near)"):format(capture_method(), Core.ctx, window * 1000))
            end
            return
        end
        if Capture.mode ~= "Incoming ball" then return end
        -- "Incoming ball": capture the player's OWN real parry. Arm the hook ONLY when a
        -- ball is actually targeting the player and arriving -- i.e. a real parry
        -- is genuinely about to happen -- NOT on any nearby ball or screen tap.
        -- capture_safe() was too loose (any ball within 20 studs, no targeting
        -- check), so on mobile it armed on taps/passing balls that would never
        -- parry. parry_imminent() requires target == me and an incoming path, so
        -- the hook is up only for the fraction of a second the player blocks.
        -- inspect still accepts only a genuine parry packet; nothing synthetic.
        -- parry imminent = a ball targeting the player, point blank or arriving
        -- within reach + the window (inlined; the outer scope is at its local cap)
        local imminent = false
        do
            local root = getRoot()
            if root then
                local horizon = reach_time() + (parry_window() or 0.5)
                for _, ball in ipairs(get_live_balls()) do
                    if ball:GetAttribute('target') == me then
                        local vel = ball_velocity(ball)
                        local speed = vel.Magnitude
                        local off = root.Position - ball.Position
                        local d = off.Magnitude
                        if d <= 18 or (speed > 1 and d > 0.01 and (vel / speed):Dot(off / d) > 0 and d / speed <= horizon) then
                            imminent = true; break
                        end
                    end
                end
            end
        end
        if not imminent then return end
        if now - Capture.last_press < 0.3 then return end
        Capture.last_press = now
        -- short window = less time the hook is up; tune with getgenv().CaptureWindow
        if arm(math.clamp(tonumber(getgenv().CaptureWindow) or 0.4, 0.12, 1.5)) and now - (Capture.notified or 0) > 5 then
            Capture.notified = now
            logp("capture: block this ball yourself -- the hook reads that one real parry, then auto-forge takes over (" .. capture_method() .. ")")
        end
    end

    -- "Your press" capture (default). The hook goes up ONLY for an input the game
    -- itself turns into a parry -- the same test its own handler uses
    -- (SwordsController: `if not gameProcessed and UseBind(input, "Block") then
    -- parry() end`, Bbs dump):
    --   * keyboard / mouse / controller: one of your Block binds (game defaults
    --     F, left click, R1; a rebound key is learned from your own real block
    --     swings) and NOT swallowed by a GUI -- so opening a menu, clicking UI,
    --     typing or emoting never puts it up;
    --   * touch: only a press that lands on the game's Block button (tap-to-block
    --     in the world is ignored). That button parries on release, so the hook
    --     is already up when the packet goes.
    -- And you must be able to parry right now (alive / training / lobby zone).
    -- Nothing synthetic; inspect still only accepts a genuine parry packet.
    Capture.binds = { F = true, MouseButton1 = true, ButtonR1 = true }
    Capture.learn = {}
    function Capture.on_block_button(pos)
        Capture.gui = Capture.gui or cloneref(game:GetService("GuiService"))
        local inset = Capture.gui:GetGuiInset()
        for _, b in ipairs(CollectionService:GetTagged("BlockButton")) do
            if b:IsA("GuiObject") and b.Visible then
                local p, sz = b.AbsolutePosition, b.AbsoluteSize
                for _, dy in ipairs({ 0, inset.Y }) do
                    local x, y = pos.X, pos.Y + dy
                    if x >= p.X - 6 and x <= p.X + sz.X + 6 and y >= p.Y - 6 and y <= p.Y + sz.Y + 6 then return true end
                end
            end
        end
        return false
    end
    function Parry.onInput(input, processed)
        if not is_live() then return end
        local t, k = input.UserInputType, input.KeyCode
        local touch = t == Enum.UserInputType.Touch
        local name = (k ~= Enum.KeyCode.Unknown) and k.Name or t.Name
        if not touch and not processed then Capture.last_in, Capture.last_in_at = name, clock_() end
        if Core.cap or Capture.mode ~= "Your press" or not needs_capture() then return end
        local block
        if touch then
            local ok, hit = pcall(Capture.on_block_button, input.Position)
            block = ok and hit
        else
            block = not processed and Capture.binds[name] == true
        end
        if not block or not canParryNow() then return end
        local now = clock_()
        if now - Capture.last_press < 0.15 then return end
        Capture.last_press = now
        if arm(touch and 0.8 or 0.3) and now - (Capture.notified or 0) > 5 then
            Capture.notified = now
            logp("capture: reading your block press (" .. capture_method() .. ")")
        end
    end
    -- A real block swing just played (seen on the animator, no hooks): the
    -- unprocessed key pressed right before it is a Block bind. Learned after two
    -- swings on the same key, so a stray key can't sneak in.
    function Parry.learnBind()
        local n, at = Capture.last_in, Capture.last_in_at or -math.huge
        if not n or Capture.binds[n] or clock_() - at > 0.2 then return end
        Capture.learn[n] = (Capture.learn[n] or 0) + 1
        if Capture.learn[n] >= 2 then
            Capture.binds[n] = true
            logp("capture: learned your block key " .. n)
        end
    end

    -- Why a parry went unanswered. Our parry reaches the server about half a
    -- round trip after we fire, and the server's ball is about half a round trip
    -- ahead of the one we see, so (in what we see) the parry is up from about
    -- `ping` after the fire for `W`. Where the ball's closest approach fell
    -- against that says early / late / on time.
    local function miss_verdict(w)
        if not w then return "parry unanswered (no ball watched)" end
        local head = ("parry unanswered [%s]: fired at %.0f studs"):format(tostring(w.how), w.d0)
        if w.min_d == math.huge then return head .. " -- ball gone before it got near" end
        local dt = w.min_t - w.t
        local open, close = w.ping, w.ping + w.W
        local tail = ("; closest %.0f studs, %.2fs after the fire (parry up ~%.2f-%.2fs, ping %.0fms%s)"):format(
            w.min_d, dt, open, close, w.ping * 1000, w.lead and (", lead %.2f"):format(w.lead) or "")
        local verdict
        if w.min_d > 15 then verdict = " -> ball never reached you (curved off / went elsewhere): not a timing miss"
        elseif dt > close then verdict = (" -> EARLY by %.2fs"):format(dt - close)
        elseif dt < open then verdict = (" -> LATE by %.2fs"):format(open - dt)
        else verdict = " -> ON TIME by what we see: the server didn't count it" end
        local c = w.cap
        local capinfo = c and ("\n    capture #%d (taken %.0fms after its press): %d of %d remote parries landed"):format(
            c.id or 0, (c.lat or 0) * 1000, c.landed or 0, c.sent or 0) or ""
        return head .. tail .. verdict .. capinfo
    end

    function Parry.frame(dt, point)
        if not active or not is_live() then return end
        local now = clock_()
        if point == 1 then
            if dt then frame_dt = math.clamp(dt, 1 / 240, 0.1) end
            Pump.frame = Pump.frame + 1
            -- captures are per place: entering / leaving lobby training swaps them
            local ctx = in_lobby_training() and "training" or "match"
            if ctx ~= Core.ctx then
                -- dying in training ends it (this swap) before the parry's answer
                -- deadline: say why it missed first (until 0.5.11 it was dropped
                -- silently, so no training death ever got a verdict)
                if Core.pending then logp(miss_verdict(Core.watch) .. " [round ended]") end
                Core.caps[Core.ctx] = Core.cap
                Core.ctx, Core.cap = ctx, Core.caps[ctx]
                Core.misses, Core.pending, Core.watch = 0, nil, nil
            end
            local w = Core.watch
            if w then
                local root = getRoot()
                if w.ball.Parent and root and now - w.t < 2.5 then
                    local d = (w.ball.Position - root.Position).Magnitude
                    if d < w.min_d then w.min_d, w.min_t = d, now end
                end
            end
            if Core.pending and now > Core.pending then
                Core.pending, Core.misses = nil, Core.misses + 1
                logp(miss_verdict(Core.watch))
                Core.watch = nil
                if S.parry_mode == "Keypress" then
                    Core.misses = 0
                elseif Core.misses >= 2 then
                    Core.cap, Core.misses = nil, 0
                    logp("  2 unanswered in a row: capture dropped, the next parry takes a fresh one")
                else
                    logp("  the next parry is a native press that refreshes the capture")
                end
            end
            if not Core.cap then prime_capture(now) end
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
        local w = Core.watch
        if Core.pending and w then
            if w.cap then w.cap.landed = (w.cap.landed or 0) + 1 end
            logp(("  -> landed %.2fs after the parry (fired at %.0f studs)"):format(clock_() - w.t, w.d0))
        end
        Core.watch = nil
        -- Core.interp stays fixed. Until 0.5.8 every landed remote parry nudged it
        -- by (predicted eta - time until this event). The event comes back about
        -- one round trip after the send, not at contact, so each hit pushed it up
        -- (0.14 -> 0.30 in ~5 hits), and a missed parry never pulled it back down.
        -- Every parry fired a little earlier than the one before; once the ball
        -- was fast, it went ~75 studs early: "animation, no parry after a few
        -- hits", on every mode.
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
            armed = Core.cap and ("armed (" .. capture_method() .. ", " .. Core.ctx .. ")")
                or (Capture.mode == "Your press" and "not armed -- press block once" or "not armed -- capturing at the next chance"),
            last = last, clash = clash, manual = manual, rate = SpamMeter.rate, ping = pingMs(),
            target = SP.rate_now(clock_()), speed_mode = SP.speed_mode,
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
        if Core.pending then pcall(function() logp(miss_verdict(Core.watch) .. " [engine stopped]") end) end
        Core.pending, Core.misses, Core.watch = nil, 0, nil
        G.until_t, Capture.dry, Capture.since = 0, 0, nil
    end
    -- one parry outside the engine (Slashes of Fury): remote if armed, else a
    -- native press that also captures
    function Parry.spamParry()
        if not Parry.resolve() then return false end
        -- both modes on Keypress: a plain press, never a hook
        if S.parry_mode == "Keypress" and SP.mode == "Keypress" then return pressBlockKey() end
        if Core.cap and send(true) == "sent" then Anim.spamBlock(); return true end
        return key_parry(Core.cap == nil)
    end
    -- REHOOK: throw the capture away (this place's and the other's) and take a
    -- fresh one at the next safe moment -- no 1s settle, no 1.4s spacing, no dry
    -- backoff -- with the hook picked in Capture hook (or on the next parry, if a
    -- ball comes first).
    function Parry.rehook()
        pcall(unhook)
        Core.cap, Core.pending, Core.misses, Core.caps = nil, nil, 0, {}
        tok_cache.cap = nil
        Capture.dry, Capture.last_press = 0, -math.huge
        Capture.since = canParryNow() and (clock_() - 1) or nil
        logp("rehook: capture dropped -- taking a fresh one at the next safe moment (" .. capture_method() .. ")")
        return active
    end
    -- The game started a block swing. If it came from a real press of yours, its
    -- lockout is running and a remote parry now would only play the swing -- so
    -- start our gate. Swings within 0.5s of a send of ours are the game showing
    -- OUR parry (spam included) and are ignored: read as presses, they used to
    -- close the gate for 1.4s after a clash and make auto parry fire late.
    function Parry.gameSwing()
        if clock_() - Core.last_send_at < 0.5 then return end
        gate_start()
    end
    function Parry.remotes() return Remotes end
    function Parry.spamRate() return SpamMeter.rate end
    function Parry.isMe(name) return name == me end
end

-- ===========================================================================
-- ENGINE: owner of every parry/spam connection.
-- ===========================================================================
local Library
local StatusHook, UiTick

-- Log file: workspace/BladeBall/rewrite_log.txt. Everything the parry log shows
-- plus engine wake/sleep, hook state and the kick message, so after a kick the
-- last lines say exactly what the script was doing. Written by the executor;
-- the game can't see it. Until 0.5.9 the kick listener only existed while a
-- parry/spam feature was on, so a kick with everything off (on load) wrote
-- nothing at all. Now it's there from load, and the kick line carries how long
-- after load it came, every feature that was on, and whether / how long ago the
-- capture hook was up -- one kick tells "detected by load" from "by the hook".
local Flight = { path = "BladeBall/rewrite_log.txt", started = false }
function Flight.write(line)
    pcall(function()
        if not Flight.started then
            Flight.started = true
            if makefolder and isfolder and not isfolder("BladeBall") then makefolder("BladeBall") end
            if writefile then writefile(Flight.path, ("==== %s session %s\n"):format(SCRIPT_VERSION, os.date("%Y-%m-%d %H:%M:%S"))) end
        end
        if appendfile then appendfile(Flight.path, ("[%s +%6.1fs] %s\n"):format(os.date("%H:%M:%S"), clock_() - LOAD_T, tostring(line))) end
    end)
end
Parry.onLog = Flight.write
feature_log = Flight.write

local Engine = { users = {}, conns = {}, watch = {}, running = false, armed = false, status_at = 0, tick_at = 0, sleep_tok = nil }
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
    econnect(UserInputService.InputBegan, Parry.onInput)
    for _, folder in ipairs(Parry.ballFolders()) do econnect(folder.ChildAdded, Parry.onBallAdded) end
    -- the game's own block swings (your presses, capture presses) start its
    -- lockout; seen on the animator, no hooks
    local function watch_animator(char)
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if not animator or not Engine.running then return end
            econnect(animator.AnimationPlayed, function(track)
                if Anim.isGamePress(track) then Parry.gameSwing(); pcall(Parry.learnBind) end
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
    if StatusHook then pcall(StatusHook, nil, Engine.armed) end
end

-- SLEEP OUTSIDE A ROUND. With a parry/spam feature on, the engine above runs
-- only while there's something to parry: you're in a round (your character
-- under Workspace.Alive), in lobby training, or in lobby parry. Anywhere else --
-- just standing in the lobby -- it sleeps: no per-frame loops, no game-remote
-- listeners, no polling; only these event watchers, which wake it the moment
-- you join a round, start training or lobby parry. Before 0.5.6 it ran in the
-- lobby exactly as in a round (3 per-frame loops, 4 remote listeners, Stats
-- reads), which is the footprint the old script's idle kicks had.
local function in_play()
    local char = LocalPlayer.Character
    if not char or not char.Parent then return false end
    local alive = Workspace:FindFirstChild("Alive")
    if alive and char.Parent == alive then return true end
    if LocalPlayer:GetAttribute("LobbyParry") then return true end
    if LocalPlayer:GetAttribute("LobbyTraining") then
        local dead = Workspace:FindFirstChild("Dead")
        if dead and char.Parent == dead then return true end
    end
    return false
end
round_check = in_play
do
    -- re-apply round-only features when you enter / leave a round
    local function sync()
        for _, f in pairs(Features) do
            if f.round_only and (f.want or f.on) then pcall(function() f:setEnabled(f.want) end) end
        end
    end
    local function on_change() task.defer(sync) end
    local function watch_char(char) char.AncestryChanged:Connect(on_change) end
    if LocalPlayer.Character then watch_char(LocalPlayer.Character) end
    LocalPlayer.CharacterAdded:Connect(function(c) watch_char(c); on_change() end)
    LocalPlayer:GetAttributeChangedSignal("LobbyTraining"):Connect(on_change)
    LocalPlayer:GetAttributeChangedSignal("LobbyParry"):Connect(on_change)
    on_change()
end
local function wconnect(signal, fn)
    local c = signal:Connect(function(...)
        if not is_live() then return end
        fn(...)
    end)
    Engine.watch[#Engine.watch + 1] = c
end
local function reevaluate()
    if not Engine.armed then return end
    if in_play() then
        Engine.sleep_tok = nil
        if not Engine.running then
            if Engine.start() then Flight.write("engine AWAKE (in a round / training / lobby parry)") end
        end
    elseif Engine.running and not Engine.sleep_tok then
        -- a short grace so a respawn or a quick hop doesn't flap it
        local tok = {}
        Engine.sleep_tok = tok
        task.delay(1.5, function()
            if Engine.sleep_tok ~= tok then return end
            Engine.sleep_tok = nil
            if Engine.armed and Engine.running and not in_play() then
                Engine.stop()
                Flight.write("engine ASLEEP (lobby) -- no loops, no remote listeners; hook: " .. Parry.hookState())
            end
        end)
    end
end
function Engine.arm()
    if Engine.armed then return end
    Engine.armed = true
    local function on_change() task.defer(reevaluate) end
    local function watch_char(char) wconnect(char.AncestryChanged, on_change) end
    if LocalPlayer.Character then watch_char(LocalPlayer.Character) end
    wconnect(LocalPlayer.CharacterAdded, function(c) watch_char(c); on_change() end)
    wconnect(LocalPlayer:GetAttributeChangedSignal("LobbyTraining"), on_change)
    wconnect(LocalPlayer:GetAttributeChangedSignal("LobbyParry"), on_change)
    Flight.write("parry/spam feature on -- engine " .. (in_play() and "waking" or "asleep until a round"))
    reevaluate()
    if not Engine.running and StatusHook then pcall(StatusHook, nil, true) end
end
function Engine.disarm()
    if not Engine.armed then return end
    Engine.armed, Engine.sleep_tok = false, nil
    for _, c in ipairs(Engine.watch) do pcall(function() c:Disconnect() end) end
    Engine.watch = {}
    if Engine.running then Engine.stop() end
    if StatusHook then pcall(StatusHook, nil, false) end
    Flight.write("all parry/spam features off -- engine off; hook: " .. Parry.hookState())
end
function Engine.want(name, on)
    if (Engine.users[name] ~= nil) ~= (on and true or false) then Flight.write(("%s %s"):format(name, on and "ON" or "OFF")) end
    Engine.users[name] = on and true or nil
    if next(Engine.users) ~= nil then Engine.arm() else Engine.disarm() end
end

-- From load: a load line, then (only if it happens) the kick with full context.
do
    local exec = "?"
    pcall(function() exec = table.concat({ identifyexecutor() }, " ") end)
    Flight.write(("loaded | executor %s | place %s"):format(exec, tostring(game.PlaceId)))
    pcall(function()
        local GuiService = cloneref(game:GetService("GuiService"))
        Flight.kick_conn = GuiService.ErrorMessageChanged:Connect(function(msg)
            if not is_live() then return end
            local on = {}
            for name, f in pairs(Features) do if f.on then on[#on + 1] = name end end
            for name in pairs(Engine.users) do on[#on + 1] = name end
            table.sort(on)
            Flight.write(("!!!! KICK / ERROR: %s"):format(tostring(msg)))
            Flight.write(("     %.1fs after load | on: %s | engine %s | hook %s"):format(clock_() - LOAD_T,
                #on > 0 and table.concat(on, ", ") or "NOTHING", Engine.running and "awake" or "asleep", Parry.hookState()))
        end)
    end)
end

-- ===========================================================================
-- MOBILE MANUAL-SPAM SWITCH (touch devices only; no on-screen UI on PC).
-- A capsule switch: tap to turn spam on/off, drag to move it. The thumb slides
-- across, the track fills with a green->cyan gradient that shimmers while it
-- spams, dims while Smart stop is waiting for a threat, and shows the live rate.
-- ===========================================================================
local Orb = {}
do
    local SP = Parry.SP
    local TweenService = cloneref(game:GetService("TweenService"))
    local W, H, PAD = 172, 58, 6
    local THUMB = H - PAD * 2
    local C = {
        track_off = Color3.fromRGB(22, 23, 29), track_on = Color3.fromRGB(10, 32, 26),
        stroke = Color3.fromRGB(255, 255, 255),
        g1 = Color3.fromRGB(0, 232, 140), g2 = Color3.fromRGB(0, 186, 255),
        thumb_off = Color3.fromRGB(58, 60, 72), thumb_on = Color3.fromRGB(246, 255, 251),
        icon_off = Color3.fromRGB(205, 208, 220), icon_on = Color3.fromRGB(0, 150, 95),
        text = Color3.fromRGB(238, 240, 246), dim = Color3.fromRGB(148, 152, 168),
    }
    local gui, root, track, fill, grad, thumb, ring, bar, notch, textbox, title, sub
    local pressing, dragging = false, false
    local press_input, press_pos, start_abs = nil, nil, nil
    local press_conns, painted, last_rate = {}, nil, 0
    local function tween(obj, props, t)
        TweenService:Create(obj, TweenInfo.new(t or 0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
    end
    local function corner(obj, r) local c = Instance.new("UICorner"); c.CornerRadius = r or UDim.new(1, 0); c.Parent = obj; return c end
    local function set_spam(on) SP.manual = on and true or false end
    local function drop_press_conns()
        for _, c in ipairs(press_conns) do pcall(function() c:Disconnect() end) end
        press_conns = {}
    end
    local function paint(rate)
        if not track then return end
        if rate then last_rate = rate end
        local on = SP.manual
        local state = not on and "off" or (Parry.spamWaiting() and "wait" or "on")
        if state ~= painted then
            painted = state
            tween(thumb, {
                Position = on and UDim2.fromOffset(W - PAD - THUMB, PAD) or UDim2.fromOffset(PAD, PAD),
                BackgroundColor3 = on and C.thumb_on or C.thumb_off,
            })
            tween(fill, { BackgroundTransparency = state == "on" and 0.05 or (state == "wait" and 0.55 or 1) })
            tween(track, { BackgroundColor3 = on and C.track_on or C.track_off })
            tween(textbox, { Position = on and UDim2.fromOffset(PAD * 3, 0) or UDim2.fromOffset(THUMB + PAD * 3, 0) })
            local ic = on and C.icon_on or C.icon_off
            tween(ring, { Color = ic }); tween(bar, { BackgroundColor3 = ic })
            tween(notch, { BackgroundColor3 = on and C.thumb_on or C.thumb_off })
        end
        if state == "off" then sub.Text, sub.TextColor3 = "tap to start", C.dim
        elseif state == "wait" then sub.Text, sub.TextColor3 = "ready", C.dim
        else sub.Text, sub.TextColor3 = (math.floor(last_rate + 0.5) .. "/s"), C.g1 end
        -- shimmer while spamming
        if state == "on" then grad.Offset = Vector2.new(math.sin(clock_() * 3) * 0.3, 0) end
    end
    function Orb.tick(rate) paint(rate) end
    -- a press that didn't turn into a drag toggles spam
    local function release_press()
        pressing = false
        drop_press_conns()
        if dragging then dragging = false
        else
            set_spam(not SP.manual)
            -- a little squish so the tap feels physical
            root.Size = UDim2.fromOffset(W * 0.96, H * 0.96)
            tween(root, { Size = UDim2.fromOffset(W, H) }, 0.25)
        end
        paint()
    end
    function Orb.show()
        if gui or not touchUI then return end
        gui = Instance.new("ScreenGui")
        gui.Name = randName(); gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 9999
        root = Instance.new("Frame")
        root.Size = UDim2.fromOffset(W, H); root.AnchorPoint = Vector2.new(0.5, 0.5)
        root.Position = UDim2.new(1, -(W / 2 + 18), 0.62, 0); root.BackgroundTransparency = 1
        root.Parent = gui
        -- soft drop shadow (two stacked translucent capsules)
        for i, a in ipairs({ 0.82, 0.9 }) do
            local sh = Instance.new("Frame")
            sh.Size = UDim2.new(1, i * 6, 1, i * 6); sh.AnchorPoint = Vector2.new(0.5, 0.5)
            sh.Position = UDim2.new(0.5, 0, 0.5, 3); sh.BackgroundColor3 = Color3.new(0, 0, 0)
            sh.BackgroundTransparency = a; sh.ZIndex = 0; sh.Parent = root; corner(sh)
        end
        track = Instance.new("TextButton")
        track.Name = "Track"; track.Text = ""; track.AutoButtonColor = false
        track.Size = UDim2.fromScale(1, 1); track.BackgroundColor3 = C.track_off; track.ZIndex = 1
        track.Parent = root; corner(track)
        local st = Instance.new("UIStroke"); st.Color = C.stroke; st.Transparency = 0.86; st.Thickness = 1.2
        st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; st.Parent = track
        fill = Instance.new("Frame")
        fill.Size = UDim2.fromScale(1, 1); fill.BackgroundColor3 = Color3.new(1, 1, 1); fill.BackgroundTransparency = 1
        fill.ZIndex = 2; fill.Active = false; fill.Parent = track; corner(fill)
        grad = Instance.new("UIGradient"); grad.Color = ColorSequence.new(C.g1, C.g2); grad.Parent = fill
        textbox = Instance.new("Frame")
        textbox.Size = UDim2.fromOffset(W - THUMB - PAD * 5, H); textbox.Position = UDim2.fromOffset(THUMB + PAD * 3, 0)
        textbox.BackgroundTransparency = 1; textbox.ZIndex = 3; textbox.Parent = track
        title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1; title.Size = UDim2.new(1, 0, 0, 20); title.Position = UDim2.new(0, 0, 0.5, -18)
        title.Font = Enum.Font.GothamBlack; title.TextSize = 16; title.Text = "SPAM"; title.TextColor3 = C.text
        title.TextXAlignment = Enum.TextXAlignment.Left; title.ZIndex = 3; title.Parent = textbox
        sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1; sub.Size = UDim2.new(1, 0, 0, 16); sub.Position = UDim2.new(0, 0, 0.5, 2)
        sub.Font = Enum.Font.GothamMedium; sub.TextSize = 12; sub.Text = "tap to start"; sub.TextColor3 = C.dim
        sub.TextXAlignment = Enum.TextXAlignment.Left; sub.ZIndex = 3; sub.Parent = textbox
        thumb = Instance.new("Frame")
        thumb.Size = UDim2.fromOffset(THUMB, THUMB); thumb.Position = UDim2.fromOffset(PAD, PAD)
        thumb.BackgroundColor3 = C.thumb_off; thumb.ZIndex = 4; thumb.Active = false; thumb.Parent = track; corner(thumb)
        -- power icon: an open ring with a bar through the gap
        local icon = Instance.new("Frame")
        icon.Size = UDim2.fromOffset(18, 18); icon.AnchorPoint = Vector2.new(0.5, 0.5); icon.Position = UDim2.fromScale(0.5, 0.52)
        icon.BackgroundTransparency = 1; icon.ZIndex = 5; icon.Parent = thumb; corner(icon)
        ring = Instance.new("UIStroke"); ring.Thickness = 2.4; ring.Color = C.icon_off; ring.Parent = icon
        notch = Instance.new("Frame")
        notch.Size = UDim2.fromOffset(8, 6); notch.AnchorPoint = Vector2.new(0.5, 0.5); notch.Position = UDim2.new(0.5, 0, 0, -1)
        notch.BackgroundColor3 = C.thumb_off; notch.BorderSizePixel = 0; notch.ZIndex = 6; notch.Parent = icon
        bar = Instance.new("Frame")
        bar.Size = UDim2.fromOffset(2.6, 10); bar.AnchorPoint = Vector2.new(0.5, 0); bar.Position = UDim2.new(0.5, 0, 0, -3)
        bar.BackgroundColor3 = C.icon_off; bar.BorderSizePixel = 0; bar.ZIndex = 7; bar.Parent = icon; corner(bar)
        track.InputBegan:Connect(function(input)
            local t = input.UserInputType
            if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
            if pressing then return end
            pressing, dragging = true, false
            press_input, press_pos = input, input.Position
            start_abs = root.AbsolutePosition + root.AbsoluteSize * 0.5
            -- move / release are tracked only while a press is live
            press_conns[#press_conns + 1] = UserInputService.InputChanged:Connect(function(i)
                if not pressing then return end
                if i ~= press_input and i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                local d = i.Position - press_pos
                if not dragging and Vector2.new(d.X, d.Y).Magnitude > 14 then dragging = true end
                if dragging then root.Position = UDim2.fromOffset(start_abs.X + d.X, start_abs.Y + d.Y) end
            end)
            press_conns[#press_conns + 1] = UserInputService.InputEnded:Connect(function(i)
                if not pressing then return end
                if i == press_input or i.UserInputType == Enum.UserInputType.MouseButton1 then release_press() end
            end)
        end)
        hideGui(gui)
        painted = nil
        paint()
    end
    function Orb.hide()
        drop_press_conns()
        pressing, dragging = false, false
        set_spam(false)
        if gui then pcall(function() gui:Destroy() end) end
        gui, root, track = nil, nil, nil
        painted = nil
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
AP:AddSlider("CurveBias", {
    Text = "Curve early bias", Default = 50, Min = 0, Max = 100, Rounding = 0, Suffix = "%",
    Tooltip = "How much earlier to parry a curving ball (inside the window, early is safe).",
    Callback = function(v) S.curve_bias = v / 100 end,
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
    Values = { "Namecall", "FireServer", "Both" }, Default = "Namecall", Text = "Capture hook",
    Tooltip = "How the key is captured, then every parry is forged (curve, targeting, all options work). Default Namecall uses a __namecall hook (hookmetamethod) that lives in game's locked metatable -- a game script cannot see it, so it is the stealthiest. FireServer/Both also hook the shared FireServer function (identity a game script can compare) -- less stealthy but catch every parry. The hook is up only around the one press it reads (see 'Capture on'), then stays down for the session.",
    Callback = function(v) getgenv().CaptureHook = v end,
})
AP:AddDropdown("CaptureTrigger", {
    Values = { "Your press", "Incoming ball", "Auto press" }, Default = "Your press", Text = "Capture on",
    Tooltip = "When the one-time key capture happens. Your press: the first time you press block anywhere you can parry -- only your real Block key / the Block button, never UI clicks, menus or emotes. Incoming ball: when a ball is about to hit you. Auto press: the script presses block itself once (synthetic input).",
    Callback = function(v) Parry.Capture.mode = v end,
})
AP:AddButton({
    Text = "Rehook",
    Tooltip = "Drop the current capture and take a fresh one as soon as no ball is near you (uses the Capture hook above). Use it if parries stop landing.",
    Func = function()
        if Parry.rehook() then
            Notify("Rehook", "Capture dropped -- taking a fresh one as soon as no ball is near you.", 3)
        else
            Notify("Rehook", "Capture dropped. Turn on Auto parry or spam to take a fresh one.", 4)
        end
    end,
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
DetInfinity.round_only = true -- game-signal listeners: rounds only (lobby kick)
function DetInfinity.start()
    local R = get_remotes()
    if R and R:FindFirstChild("InfinityBall") then
        DetInfinity:connect(R.InfinityBall.OnClientEvent, function(_, b) Det.infinity = b and true or false end)
    end
end
function DetInfinity.stop() Det.infinity = false end

local DetDeathSlash = Feature("DetDeathSlash")
DetDeathSlash.round_only = true -- game-signal listeners: rounds only (lobby kick)
function DetDeathSlash.start()
    local R = get_remotes()
    if R and R:FindFirstChild("DeathBall") then
        DetDeathSlash:connect(R.DeathBall.OnClientEvent, function(_, d) Det.deathslash = d and true or false end)
    end
end
function DetDeathSlash.stop() Det.deathslash = false end

local DetTimeHole = Feature("DetTimeHole")
DetTimeHole.round_only = true -- game-signal listeners: rounds only (lobby kick)
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
DetSlashes.round_only = true -- game-signal listeners: rounds only (lobby kick)
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
DetPhantom.round_only = true -- game-signal listeners: rounds only (lobby kick)
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
    Text = touchUI and "Manual spam (show switch)" or "Manual spam", Default = false,
    Tooltip = touchUI and "Shows the spam switch: tap it to turn spam on/off, drag to move it."
        or "Press the key (E by default) to turn spam on, press again to turn it off.",
    Callback = function(v)
        if touchUI then
            -- the toggle shows the switch; the switch decides when to actually spam
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
local SPAM_SPEEDS = {}
for r = 50, 1000, 50 do SPAM_SPEEDS[#SPAM_SPEEDS + 1] = r .. "/s" end
MS:AddDropdown("SpamSpeed", {
    Values = SPAM_SPEEDS, Default = "700/s", Text = "Speed",
    Tooltip = "Parries a second for manual and auto spam, held exactly at this rate at any FPS.",
    Callback = function(v) SP.speed_mode = v end,
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
    local gui = Instance.new("ScreenGui"); gui.Name = randName(); gui.ResetOnSpawn = false
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
    hideGui(gui)
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
    OnlyWithAbility = false, MaxDistance = 0, ShowActive = true, ShowCooldown = true, ShowSelf = true }
local AbilityESP = Feature("AbilityESP")
do
    -- Ported from the original Games/BladeBall.lua ability ESP (the one that
    -- worked): one BillboardGui per player pointed at the head (Adornee), put in
    -- the executor's hidden container (gethui, else CoreGui) WITHOUT protect_gui --
    -- the rewrite's protect_gui / CoreGui variants never drew. Built when the
    -- character spawns (WaitForChild Head); one shared 10 Hz Heartbeat updater
    -- writes text / style only when they change.
    -- Ability: the player's EquippedAbility attribute if the game sets it, else
    -- the Enabled script under character.Abilities (what the game ships now).
    local HUI = CoreGui
    pcall(function() local h = gethui and gethui(); if typeof(h) == 'Instance' then HUI = h end end)
    -- a billboard nested inside a ScreenGui never draws: if gethui is one, use CoreGui
    pcall(function()
        if HUI ~= CoreGui and (HUI:IsA("LayerCollector") or HUI:FindFirstAncestorWhichIsA("LayerCollector")) then HUI = CoreGui end
    end)
    local entries = {}   -- player -> { billboard, label, character, head, text, color, size, height }
    local function esc(t) return (tostring(t):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
    local function equipped(player, character)
        local a = player:GetAttribute('EquippedAbility') or (character and character:GetAttribute('Ability'))
        if a and a ~= '' then return tostring(a) end
        local ab = character and character:FindFirstChild('Abilities')
        if not ab then return nil end
        for _, s in ipairs(ab:GetChildren()) do
            local ok, en = pcall(function() return s.Enabled end)
            if ok and en then return s.Name end
        end
        return nil
    end
    local function info(player, e)
        local now = Workspace:GetServerTimeNow()
        local clock = os.clock()
        if clock - (e.ab_at or 0) > 1 then e.ab_at, e.ability = clock, equipped(player, e.character) end
        local name = e.ability
        if name then
            local up = player:FindFirstChild('Upgrades')
            local lv = up and up:FindFirstChild(name)
            if lv and type(lv.Value) == 'number' and lv.Value > 0 then name = name .. ' V' .. lv.Value end
        end
        local status
        if EspCfg.ShowCooldown then
            local exp = e.character:GetAttribute('CooldownExpiration') or player:GetAttribute('CooldownExpiration')
            if type(exp) == 'number' then
                local left = exp - now
                status = (left > 0 and left < 600) and ('<font color="#FF6A6A">CD %.1fs</font>'):format(left)
                    or '<font color="#5CFF7A">READY</font>'
            end
        end
        return name, status
    end
    local function remove(player)
        local e = entries[player]
        if e then pcall(function() e.billboard:Destroy() end) end
        entries[player] = nil
    end
    local function clear_all() for p in pairs(entries) do remove(p) end end
    local function create(player)
        task.spawn(function()
            local character = player.Character
            while AbilityESP.on and (not character or not character.Parent) do task.wait(0.5); character = player.Character end
            if not character or not AbilityESP.on then return end
            local head = character:WaitForChild('Head', 10)
            if not head or not AbilityESP.on then return end
            remove(player)
            local billboard = Instance.new('BillboardGui')
            billboard.Name = randName(); billboard.Adornee = head
            billboard.Size = UDim2.new(0, 220, 0, 60)
            billboard.StudsOffset = Vector3.new(0, EspCfg.Height, 0); billboard.AlwaysOnTop = true
            billboard.Parent = HUI
            local label = Instance.new('TextLabel')
            label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1
            label.TextColor3 = EspCfg.Color; label.TextSize = EspCfg.TextSize
            label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
            label.RichText = true; label.TextXAlignment = Enum.TextXAlignment.Center
            label.TextYAlignment = Enum.TextYAlignment.Center; label.Parent = billboard
            label.Visible = false
            entries[player] = { billboard = billboard, label = label, character = character, head = head,
                color = EspCfg.Color, size = EspCfg.TextSize, height = EspCfg.Height }
            if not EspCfg.logged then
                EspCfg.logged = true
                pcall(function() Parry.logp(("ability esp: first label on %s (container %s %s)"):format(
                    player.Name, HUI.ClassName, HUI.Name)) end)
            end
        end)
    end
    local function add(player)
        if player == LocalPlayer and not EspCfg.ShowSelf then return end
        AbilityESP:connect(player.CharacterAdded, function() create(player) end)
        if player.Character then create(player) end
    end
    local function update()
        local my = getRoot()
        for player, e in pairs(entries) do
            local character, head = e.character, e.head
            if not (character and character.Parent and head and head.Parent) or player.Parent ~= Players then
                remove(player)
            else
                local dist = my and player ~= LocalPlayer and (my.Position - head.Position).Magnitude or nil
                local name, status = info(player, e)
                local visible = not (EspCfg.MaxDistance > 0 and dist and dist > EspCfg.MaxDistance)
                    and not (EspCfg.OnlyWithAbility and not name)
                if e.label.Visible ~= visible then e.label.Visible = visible end
                if visible then
                    if e.color ~= EspCfg.Color then e.color = EspCfg.Color; e.label.TextColor3 = EspCfg.Color end
                    if e.size ~= EspCfg.TextSize then e.size = EspCfg.TextSize; e.label.TextSize = EspCfg.TextSize end
                    if e.height ~= EspCfg.Height then e.height = EspCfg.Height; e.billboard.StudsOffset = Vector3.new(0, EspCfg.Height, 0) end
                    local parts = {}
                    if EspCfg.ShowName then parts[#parts + 1] = esc(player.DisplayName) end
                    if name then parts[#parts + 1] = '[' .. esc(name) .. ']' end
                    if EspCfg.ShowDistance and dist then parts[#parts + 1] = ('%.0fm'):format(dist) end
                    if #parts == 0 then parts[1] = esc(player.DisplayName) end
                    local text = '<b>' .. table.concat(parts, ' ') .. '</b>'
                    if status then text = text .. '\n' .. status end
                    if text ~= e.text then e.text = text; e.label.Text = text end
                end
            end
        end
    end
    function AbilityESP.start()
        EspCfg.logged = false
        pcall(function() Parry.logp(("ability esp ON: %d other player(s) in this server%s"):format(
            #Players:GetPlayers() - 1, EspCfg.ShowSelf and " + you" or "")) end)
        for _, player in ipairs(Players:GetPlayers()) do add(player) end
        AbilityESP:connect(Players.PlayerAdded, add)
        AbilityESP:connect(Players.PlayerRemoving, remove)
        local acc = 0
        AbilityESP:connect(RunService.Heartbeat, function(dt)
            acc = acc + dt
            if acc < 0.1 then return end
            acc = 0
            pcall(update)
        end)
    end
    function AbilityESP.stop() clear_all() end
end

local VS = Tabs.Visuals:AddLeftGroupbox("Overlays", "monitor")
VS:AddToggle("BallVelocity", { Text = "Ball velocity overlay", Default = false, Callback = function(v) BallVelocity:setEnabled(v) end })
VS:AddToggle("ShowPing", { Text = "Ping overlay", Default = false, Callback = function(v) PingOverlay:setEnabled(v) end })

local AE = Tabs.Visuals:AddRightGroupbox("Ability ESP", "eye")
AE:AddToggle("AbilityESP", { Text = "Ability ESP", Default = false, Callback = function(v) AbilityESP:setEnabled(v) end })
AE:AddToggle("AbilityESPSelf", { Text = "Show on yourself", Default = true,
    Callback = function(v) EspCfg.ShowSelf = v; if AbilityESP.on then AbilityESP:setEnabled(false); AbilityESP:setEnabled(true) end end })
AE:AddToggle("AbilityESPName", { Text = "Show name", Default = true, Callback = function(v) EspCfg.ShowName = v end })
AE:AddToggle("AbilityESPDistance", { Text = "Show distance", Default = false, Callback = function(v) EspCfg.ShowDistance = v end })
AE:AddToggle("AbilityESPOnlyWith", { Text = "Only players with an ability", Default = false, Callback = function(v) EspCfg.OnlyWithAbility = v end })
AE:AddToggle("AbilityESPCooldown", { Text = "Show ready / cooldown", Default = true, Callback = function(v) EspCfg.ShowCooldown = v end })
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
NoRender.round_only = true -- game-signal listeners: rounds only (lobby kick)
-- What "No render" removes is picked in the dropdown below. Everything it turns
-- off is remembered and put back exactly when it's turned off or the pick changes.
local NR_SEL = { ["Ability effects"] = true, ["Parry effects"] = true }
local NR_FX = { ParticleEmitter = true, Trail = true, Beam = true, Smoke = true, Fire = true, Sparkles = true }
local NR_POST = { BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true, SunRaysEffect = true, DepthOfFieldEffect = true }
local nr_saved = {}
local function nr_set(inst, prop, val)
    local ok, old = pcall(function() return inst[prop] end)
    if not ok or old == val then return end
    nr_saved[inst] = nr_saved[inst] or {}
    if nr_saved[inst][prop] == nil then nr_saved[inst][prop] = old end
    pcall(function() inst[prop] = val end)
end
local function nr_fx(inst) if NR_FX[inst.ClassName] then nr_set(inst, "Enabled", false) end end
-- turn off every effect under root now and as it appears (big trees in slices)
local function nr_tree(root, token)
    if not root then return end
    NoRender:connect(root.DescendantAdded, nr_fx)
    task.spawn(function()
        local list = root:GetDescendants()
        for k = 1, #list do
            if not NoRender:alive(token) then return end
            nr_fx(list[k])
            if k % 2000 == 0 then task.wait() end
        end
    end)
end
function NoRender.start()
    local token, sel = NoRender._token, NR_SEL
    if sel["Parry effects"] then
        pcall(function() nr_set(LocalPlayer.PlayerScripts.EffectScripts.ClientFX, "Disabled", true) end)
    end
    if sel["Ability effects"] then
        local runtime = Workspace:FindFirstChild("Runtime")
        if runtime then NoRender:connect(runtime.ChildAdded, function(v) Debris:AddItem(v, 0) end) end
    end
    if sel["All particles"] then
        nr_tree(Workspace, token)
    else
        if sel["Ball trails"] then
            for _, name in ipairs({ "Balls", "TrainingBalls" }) do nr_tree(Workspace:FindFirstChild(name), token) end
        end
        if sel["Character effects"] then
            for _, name in ipairs({ "Alive", "Dead" }) do nr_tree(Workspace:FindFirstChild(name), token) end
        end
    end
    if sel["Post effects"] or sel["Shadows"] then
        local Lighting = game:GetService("Lighting")
        if sel["Shadows"] then nr_set(Lighting, "GlobalShadows", false) end
        if sel["Post effects"] then
            for _, v in ipairs(Lighting:GetDescendants()) do if NR_POST[v.ClassName] then nr_set(v, "Enabled", false) end end
            pcall(function()
                for _, v in ipairs(Workspace.CurrentCamera:GetChildren()) do if NR_POST[v.ClassName] then nr_set(v, "Enabled", false) end end
            end)
            NoRender:connect(Lighting.DescendantAdded, function(v) if NR_POST[v.ClassName] then nr_set(v, "Enabled", false) end end)
        end
    end
end
function NoRender.stop()
    local saved = nr_saved
    nr_saved = {}
    for inst, props in pairs(saved) do
        for prop, old in pairs(props) do pcall(function() inst[prop] = old end) end
    end
end
local NR = Tabs.Misc:AddRightGroupbox("Performance", "cpu")
NR:AddToggle("NoRender", { Text = "No render", Default = false, Tooltip = "Turns off what's picked below.",
    Callback = function(v) NoRender:setEnabled(v) end })
NR:AddDropdown("NoRenderWhat", {
    Values = { "Ability effects", "Parry effects", "Ball trails", "Character effects", "All particles", "Post effects", "Shadows" },
    Default = { "Ability effects", "Parry effects" }, Multi = true, Text = "Removes",
    Tooltip = "Ability effects: spawned ability visuals. Parry effects: the game's hit/parry FX script. Ball trails / Character effects: particles, trails and beams on balls / players. All particles: every particle, trail and beam in the map. Post effects: bloom, blur, color correction, sun rays, depth of field. Shadows: global shadows.",
    Callback = function(v)
        NR_SEL = {}
        for name, on in pairs(type(v) == "table" and v or {}) do if on then NR_SEL[name] = true end end
        if NoRender.on then NoRender:setEnabled(false); NoRender:setEnabled(true) end
    end,
})

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
StatusHook = function(s, armed)
    if not s then
        set(L_capture, armed and "Capture: engine asleep in the lobby -- wakes when you join a round" or "Capture: idle (engine off)")
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
    set(SpamRateLabel, ("Actual: %d/s of %d (%s, %s)"):format(math.floor(s.rate + 0.5), math.floor((s.target or 0) + 0.5), tostring(s.speed_mode), s.manual))
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
    pcall(Engine.disarm)
    pcall(Engine.stop)
    pcall(function() Flight.kick_conn:Disconnect() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end)

genv.__BladeBallShutdown = function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    pcall(Orb.hide)
    Engine.users = {}
    pcall(Engine.disarm)
    pcall(Engine.stop)
    pcall(function() Flight.kick_conn:Disconnect() end)
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

Notify("Blade Ball", "Rewrite " .. SCRIPT_VERSION .. " loaded. " .. (touchUI and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)

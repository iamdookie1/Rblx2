task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.5.116"

local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
genv.__BladeBallInstance = INSTANCE
local function isLive() return genv.__BladeBallInstance == INSTANCE end

local cloneref = cloneref or function(x) return x end
local Players, RunService = cloneref(game:GetService('Players')), cloneref(game:GetService('RunService'))
local UserInputService, ReplicatedStorage = cloneref(game:GetService('UserInputService')), cloneref(game:GetService('ReplicatedStorage'))
local Workspace, Stats = cloneref(game:GetService('Workspace')), cloneref(game:GetService('Stats'))
local CollectionService, HttpService = cloneref(game:GetService('CollectionService')), cloneref(game:GetService('HttpService'))
local CoreGui, LocalPlayer = cloneref(game:GetService('CoreGui')), Players.LocalPlayer
if getgenv().BBStop == 0 then return end
local clock_ = os.clock
local LOAD_T, isMobile = clock_(), UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local touchUI = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function hui()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and typeof(h) == 'Instance' then return h end
    return CoreGui
end
local function randName()
    local t = {}
    for i = 1, 12 do t[i] = string.char(math.random(97, 122)) end
    return table.concat(t)
end
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

local Features, Gui, Mods, Util = {}, {}, {}, {}
local featureLog
local Stagger = { t0 = os.clock(), delay = tonumber(getgenv().BBStagger) or 0, gap = 6, queue = {}, running = false,
    round_check = nil }
function Stagger.active() return Stagger.delay > 0 and os.clock() - Stagger.t0 < Stagger.delay end
function Stagger.push(key, label, fn)
    for i, e in ipairs(Stagger.queue) do if e.key == key then table.remove(Stagger.queue, i); break end end
    Stagger.queue[#Stagger.queue + 1] = { key = key, label = label, fn = fn }
    if Stagger.running then return end
    Stagger.running = true
    task.spawn(function()
        task.wait(math.max(Stagger.delay - (os.clock() - Stagger.t0), 0))
        while #Stagger.queue > 0 do
            local e = table.remove(Stagger.queue, 1)
            if featureLog then pcall(featureLog, "staged start: " .. tostring(e.label)) end
            pcall(e.fn)
            if #Stagger.queue > 0 then task.wait(Stagger.gap) end
        end
        Stagger.running = false
    end)
end
local function Feature(name)
    local f = { name = name, on = false, want = false, round_only = false, _conns = {}, _insts = {}, _token = nil }
    function f:connect(signal, fn)
        local c = signal:Connect(function(...)
            if not isLive() then return end
            fn(...)
        end)
        self._conns[#self._conns + 1] = c
        return c
    end
    function f:own(inst) self._insts[#self._insts + 1] = inst; return inst end
    function f:loop(interval, fn)
        local token = self._token
        task.spawn(function()
            while self.on and self._token == token and isLive() do
                pcall(fn)
                task.wait(interval)
            end
        end)
    end
    function f:alive(token) return self.on and self._token == token and isLive() end
    function f:release()
        for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
        for _, i in ipairs(self._insts) do pcall(function() i:Destroy() end) end
        self._conns, self._insts = {}, {}
    end
    function f:setEnabled(v)
        v = v and true or false
        self.want = v
        if v and not self.on and Stagger.active() then
            Stagger.push(self, name, function() self:setEnabled(self.want) end)
            return
        end
        if v and self.round_only and not (Stagger.round_check and Stagger.round_check()) then v = false end
        if v == self.on then return end
        self.on = v
        if featureLog then pcall(featureLog, ("%s %s"):format(name, v and "ON" or "OFF")) end
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

local Parry = {}

local Anim = { enabled = true, spam = true, skin = nil }
do
    local BLOCK_COOLDOWN, SWING_SHOW = 1.3, 0.08
    local infoCache, ownTracks, r15Clones, ownSwing = {}, setmetatable({}, { __mode = 'k' }), {}, setmetatable({}, { __mode = 'k' })
    local gate = { last = -math.huge, landed = true, landed_at = -math.huge }
    local successAt, swingTracks = -math.huge, {}
    local function cooldown()
        local n2 = Parry.lockout and Parry.lockout()
        return (type(n2) == "number" and n2 > 0) and n2 or BLOCK_COOLDOWN
    end
    local function swordInfo(char)
        local name = (Anim.skin and Anim.skin()) or char:GetAttribute("CurrentlyEquippedSword") or ""
        local info = infoCache[name]
        if info then return info end
        info = { collection = "Default", sword_type = "Single" }
        if name ~= "" then
            local ok, data = pcall(function() return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(name) end)
            if ok and type(data) == "table" then
                if data.AnimationType then info.collection = data.AnimationType end
                if data.SwordType then info.sword_type = data.SwordType end
            end
        end
        infoCache[name] = info
        return info
    end
    local function resolveFolder(char, col, root)
        local sub = col:FindFirstChild(char:GetAttribute("HasAccessoryEquipped") and "Accessory" or "Base")
        if not sub then return col end
        local style = sub:FindFirstChild(char:GetAttribute("AnimationStyle") or "Default") or sub
        if style:IsA("StringValue") then return root:FindFirstChild(style.Value) end
        return style
    end
    local function findAnims(info, char)
        local list = {}
        pcall(function()
            local root = ReplicatedStorage.Shared.SwordAPI:FindFirstChild("Collection")
            if not root then return end
            local cols, seen = {}, {}
            for _, name in ipairs({ info.collection, info.sword_type, "Default" }) do
                local c = name and root:FindFirstChild(name)
                if c and not seen[c] then seen[c] = true; cols[#cols + 1] = c end
            end
            for _, tag in ipairs({ "Parry", "GrabParry" }) do
                for _, col in ipairs(cols) do
                    local folder = resolveFolder(char, col, root)
                    if folder then
                        for _, anim in ipairs(folder:GetChildren()) do
                            if anim:IsA("Animation") and anim:GetAttribute(tag) then list[#list + 1] = anim end
                        end
                        if #list > 0 then return end
                    end
                end
            end
        end)
        return list
    end
    local function loadTrack(animator, humanoid, anim)
        local per = ownTracks[animator]
        if not per then per = {}; ownTracks[animator] = per end
        local track = per[anim]
        if track then return track end
        local source, r15 = anim, anim:GetAttribute("R15Id")
        if r15 and humanoid.RigType == Enum.HumanoidRigType.R15 then
            source = r15Clones[anim]
            if not source then source = Instance.new("Animation"); source.AnimationId = r15; r15Clones[anim] = source end
        end
        track = animator:LoadAnimation(source)
        for k, v in pairs(anim:GetAttributes()) do pcall(track.SetAttribute, track, k, v) end
        per[anim] = track
        return track
    end
    local function playBlock()
        local char = LocalPlayer.Character
        if not char or char:GetAttribute("InOverdriveMech") then return end
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if not animator then return end
        local now, cd = os.clock(), cooldown()
        if not gate.landed and now - gate.last < cd then return end
        if gate.landed and gate.landed_at > gate.last then
            if now - gate.landed_at < SWING_SHOW then return end
            if not Parry.ballOnMe() and now - gate.landed_at < cd then return end
        end
        gate.last, gate.landed = now, false
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then track:Stop(track:GetAttribute("StopFadeTime")) end
        end
        local times = Parry.timesParried and Parry.timesParried()
        local noob, parryTime = type(times) == "number" and times < 5, char:GetAttribute("ParryTime") or 0
        swingTracks = {}
        for _, anim in ipairs(findAnims(swordInfo(char), char)) do
            local ok, track = pcall(loadTrack, animator, humanoid, anim)
            if ok and track then
                local speed = noob and (times / 5 + 1) or track:GetAttribute("PlaySpeed") or 1
                ownSwing[track] = os.clock()
                if noob then track:Play(0.05, 1, speed)
                else track:Play(track:GetAttribute("PlayFadeTime"), track:GetAttribute("PlayWeight"), speed) end
                swingTracks[#swingTracks + 1] = track
                local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
                if left > parryTime then parryTime = left end
            end
        end
        pcall(char.SetAttribute, char, "ParryTime", parryTime)
    end
    function Anim.block() if Anim.enabled then pcall(playBlock) end end
    function Anim.spamBlock() if Anim.enabled and Anim.spam then pcall(playBlock) end end
    function Anim.onSuccess()
        local now = os.clock()
        successAt, gate.landed, gate.landed_at = now, true, now
        for _, t in ipairs(swingTracks) do pcall(function() t:Stop(t:GetAttribute("StopFadeTime")) end) end
        swingTracks = {}
    end
    function Anim.reset() gate.last, gate.landed, gate.landed_at, swingTracks = -math.huge, true, -math.huge, {} end
    function Anim.isGamePress(track)
        if track:GetAttribute("SuccessParry") then return false end
        if not (track:GetAttribute("Parry") or track:GetAttribute("GrabParry")) then return false end
        local now = os.clock()
        if now - successAt < 0.35 then return false end
        local at = ownSwing[track]
        if at and now - at < 0.25 then return false end
        return true
    end
end

do
    local me = LocalPlayer.Name
    local Core = { cap = nil, pending = nil, misses = 0, interp = 0.14, last_parry = nil,
        ctx = "match", gen = 0, last_send_at = -math.huge, tune = 0, verdict = nil,
        echo = { at = -math.huge, forged_ok = false, rtt = nil, seen = 0 }, await = nil,
        last_spam_at = -math.huge, cap_n = 0,
        diag = { fired = 0, landed = 0, early = 0, late = 0, ontime = 0, refused = 0, rescued = 0, bias = nil, spread = 0, n = 0 },
        feed = { n = 0, total = 0, since = 0, ahead = nil, urs = 0,
            pos = setmetatable({}, { __mode = "k" }), at = setmetatable({}, { __mode = "k" }) } }
    local G, frameDt, active = { until_t = 0, m1 = false, m1_at = 0 }, 1 / 60, false
    local Alive, Remotes

    Util.TARGET_NAMES = { 'Cursor', 'Camera', 'Closest', 'Farthest', 'Random' }
    Util.CURVE_NAMES = { 'Camera', 'Straight', 'Normal', 'Accelerated', 'High', 'Slow', 'Backwards', 'Random',
        'Speed', 'Down', 'Left', 'Right', 'Sky', 'Ground', 'Alternate', 'Random Side', 'Zigzag', 'Spiral',
        'Cursor', 'Flick', 'Diagonal', 'Reverse' }

    local S = {
        autoparry = false, triggerbot = false, parry_mode = "Remote",
        one_parry_capture = true, rescue_press = true, preparry = false, preparry_range = 20, hp_preparry = false, hard_curve = false, self_tune = false, fast_retarget = false,
        anticurve = "Smart", dot_threshold = 0.5, curve_bias = 0.5, close_anticurve = true, close_range = 30, instant_retarget = true,
        accuracy = 50, accuracy_base = 50, divisor_multiplier = 1.1, timing_mult = 1,
        extra_distance = 0, ping_compensation = false, retry_delay = 1,
        random_accuracy = false, random_accuracy_amount = 10,
        target_mode = 1, target_method = "Angle", curve_mode = 1, random_curve = false,
        auto_ability = false, cooldown_protection = false,
    }
    local SP = {
        manual = false, auto = false, mode = "Remote", max_rate = 1000, speed_mode = "700/s", method = "Fixed rate",
        per_frame = false, per_frame_count = 1, timing = "Per second", interval_ms = 2,
        hs_fix = false, hs_speed = 400, hs_per_tick = 2,
        smart = true, range_bonus = 0, hold = 0.15, sensitivity = 1.3, predictive = true,
    }
    local Det = { infinity = false, deathslash = false, timehole = false, slashes = false, phantom_until = 0,
        inf = setmetatable({}, { __mode = "k" }), death = setmetatable({}, { __mode = "k" }),
        th_hold = setmetatable({}, { __mode = "k" }), timehole_on = false,
        tor = setmetatable({}, { __mode = "k" }), tor_fid = -1, tor_list = {} }
    Parry.S, Parry.SP, Parry.Det, Parry.targetNames, Parry.curveNames = S, SP, Det, Util.TARGET_NAMES, Util.CURVE_NAMES

    local LOG, logNew = {}, 0
    local function logp(text)
        LOG[#LOG + 1] = text
        if #LOG > 60 then table.remove(LOG, 1) end
        logNew = math.min(logNew + 1, 60)
        if Parry.onLog then pcall(Parry.onLog, text) end
    end
    Parry.logp = logp
    local DBG = { on = false, list = {}, eval = {}, block = nil, block_at = 0,
        counts = { vel = 0, feed = 0, since = clock_() }, rates = { vel = 0, feed = 0 } }
    Parry.DBG = DBG
    function DBG.ev(text)
        if not DBG.on then return end
        local l = DBG.list
        l[#l + 1] = { t = clock_(), text = text }
        if #l > 40 then table.remove(l, 1) end
    end
    function DBG.held(why, now) if DBG.on then DBG.block, DBG.block_at = why, now end end
    function Parry.drainLog()
        local out = {}
        for i = #LOG - logNew + 1, #LOG do if LOG[i] then out[#out + 1] = LOG[i] end end
        logNew = 0
        return out
    end

    function Util.updDivisor() S.divisor_multiplier = 0.7 + (S.accuracy - 1) * (0.9 / 99) end
    function Util.rollAcc()
        local acc = S.accuracy_base
        if S.random_accuracy and S.random_accuracy_amount > 0 then
            acc = acc + math.random(-S.random_accuracy_amount, S.random_accuracy_amount)
        end
        S.accuracy = math.clamp(acc, 1, 100)
        Util.updDivisor()
    end
    Parry.roll = Util.rollAcc
    function Parry.resetTune() Core.tune = 0 end
    Util.updDivisor()
    function Util.indexOf(list, name)
        for i, n in ipairs(list) do if n == name then return i end end
    end
    function Parry.setTargetMode(name) S.target_mode = Util.indexOf(Util.TARGET_NAMES, name) or 1 end
    function Parry.setCurveMode(name) S.curve_mode = Util.indexOf(Util.CURVE_NAMES, name) or 1 end

    local pingCache = { at = -1, ms = 0 }
    local function pingMs()
        local now = clock_()
        if now - pingCache.at > 0.05 then
            local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
            ping = ok and tonumber(ping) or 0
            if ping <= 0 then
                local ok2, np = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
                if ok2 and type(np) == "number" and np > 0 then ping = np * 2000 end
            end
            pingCache.ms, pingCache.at = ping, now
        end
        return pingCache.ms
    end
    Parry.pingMs = pingMs
    local function pingS() return math.min(pingMs(), 400) / 1000 end
    local Lag = { avg = nil, jit = 0.005, at = -1, win = {}, dev = 0.005, echo = nil }
    local function sampleLag()
        local now = clock_()
        if now - Lag.at < 0.1 then return end
        Lag.at = now
        local p = pingS()
        if p <= 0 then return end
        local w = Lag.win
        w[#w + 1] = p
        if #w > 30 then table.remove(w, 1) end
        local sorted = table.clone(w)
        table.sort(sorted)
        local n = #sorted
        local med, p90 = sorted[math.ceil(n * 0.5)], sorted[math.max(math.ceil(n * 0.9), 1)]
        Lag.dev = Lag.dev + (math.abs(p - med) - Lag.dev) * 0.15
        Lag.avg = med
        Lag.jit = math.max(Lag.dev, (p90 - med) * 0.5)
    end
    local function jitter() return math.clamp(Lag.jit * 2, 0.005, 0.12) end
    local function reachT()
        if Core.rt_fid == Core.fid then return Core.rt end
        sampleLag()
        Core.rt = (Lag.avg or pingS()) * 0.5 + jitter() + Core.interp + frameDt * 0.5
        Core.rt_fid = Core.fid
        return Core.rt
    end

    local function charRoot(name)
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
    function Util.inMatch()
        local char = LocalPlayer.Character
        return char ~= nil and char.Parent == Alive
    end
    function Util.inTrain()
        if LocalPlayer:GetAttribute("LobbyTraining") or LocalPlayer:GetAttribute("LobbyParry") then return true end
        local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
        return char ~= nil and dead ~= nil and char.Parent == dead
    end
    local function apRoot()
        local root = getRoot()
        if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
        return root
    end
    function Det.ball_detected(ball)
        if typeof(ball) ~= "Instance" or not ball.Parent then return nil end
        local now, u = clock_(), Det.inf[ball]
        if u and now < u then return "infinity" end
        u = Det.death[ball]
        if u and now < u then return "death slash" end
        if Det.timehole_on then
            if ball:GetAttribute("IsInTimeHoleAOE") then return "time hole" end
            u = Det.th_hold[ball]
            if u and now < u then return "time hole" end
        end
        return nil
    end
    local function blocked(ball)
        if Det.slashes or clock_() < Det.phantom_until then return true end
        if ball then return Det.ball_detected(ball) ~= nil end
        for _, name in ipairs({ "Balls", "TrainingBalls" }) do
            local folder = Workspace:FindFirstChild(name)
            for _, b in ipairs(folder and folder:GetChildren() or {}) do
                if b:GetAttribute("realBall") and b:GetAttribute("target") == LocalPlayer.Name and Det.ball_detected(b) then return true end
            end
        end
        return false
    end

    Core.noob_windows = { [1.5] = 0, [1.25] = 1, [1] = 2, [0.75] = 3, [0.625] = 4 }
    function Parry.timesParried()
        local w = Core.cap and Core.cap.win
        return w and Core.noob_windows[w] or nil
    end
    local function parryWin()
        local cw = Core.cap and Core.cap.win
        if cw and cw > 0 then return cw, cw == 1.5 and 1.5 or 1.3 * math.min(cw / 0.5, 1) end
        return 0.5, 1.3
    end
    function Parry.lockout() local _, n2 = parryWin(); return n2 end
    local function lockMargin() return math.clamp(jitter() + frameDt + 0.03, 0.06, 0.15) end
    local function gateStart()
        local now = clock_()
        if now < G.until_t then return end
        local n6, n2 = parryWin()
        G.until_t = now + math.max((n6 or 0.5) + 0.1, n2 or 1.3) + lockMargin()
    end
    local function gateOpen()
        if G.m1 and clock_() - G.m1_at < 3 then return false end
        return clock_() >= G.until_t
    end

    local function safeMargin() return jitter() + frameDt + 0.01 end
    local function cushion(speed, W)
        local a, sp = (math.clamp(S.accuracy or 50, 1, 100) - 1) / 99, math.max(speed or 1, 1)
        local f, safe = 1 - a, math.max(safeMargin(), 5 / sp)
        local cap, want = math.max(math.min(W or 0.5, 0.6) - (jitter() + frameDt + 0.03), safe), math.max((5 + 30 * f) / sp, 0.12 * f, safe)
        return math.min(want, cap)
    end
    local function fireLead(speed)
        return reachT() + cushion(speed, parryWin() or 0.5)
    end

    local function screenPts(cam)
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
                local plr, hrp = Players:GetPlayerFromCharacter(other), other:FindFirstChild('HumanoidRootPart')
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
                    local want, root = team and ("Goal%s"):format(tostring(team == 1 and 2 or 1)), char and char.PrimaryPart
                    local best, bestD
                    for _, goal in ipairs(CollectionService:GetTagged("HovergoalGoal")) do
                        local t = goal:FindFirstChild("Target")
                        if t then
                            if want then if goal.Name == want then best = goal; break end
                            elseif root then
                                local d = (t.Position - root.Position).Magnitude
                                if not bestD or d > bestD then best, bestD = goal, d end
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
    Util.PACKET_TTL = 1 / 240
    local packetCache = { at = -1, points = nil, aim = nil, others = nil }
    local function packetParts(cam)
        local now = clock_()
        if now - packetCache.at > Util.PACKET_TTL then
            packetCache.points, packetCache.others = screenPts(cam)
            local ok, mouse = pcall(UserInputService.GetMouseLocation, UserInputService)
            if ok and mouse then packetCache.aim = { mouse.X, mouse.Y }
            else local vp = cam.ViewportSize; packetCache.aim = { vp.X / 2, vp.Y / 2 } end
            packetCache.at = now
        end
        return packetCache.points, packetCache.aim, packetCache.others
    end
    local targetHold = { at = -1, mode = nil, name = nil, pos = nil }
    local function pickTarget(cam)
        local mode, now = Util.TARGET_NAMES[S.target_mode] or "Cursor", clock_()
        if targetHold.mode == mode and now - targetHold.at < 1 / 60 then return targetHold.name, targetHold.pos, mode end
        local _, _, others = packetParts(cam)
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
                local method, ccf = S.target_method or "Angle", cam.CFrame
                local o, look = ccf.Position, ccf.LookVector
                local vp = cam.ViewportSize
                local anchor = Vector2.new(vp.X / 2, vp.Y / 2)
                if mode == "Cursor" and not isMobile then
                    local ok, m = pcall(UserInputService.GetMouseLocation, UserInputService)
                    if ok and m then
                        anchor = m
                        local ray = cam:ScreenPointToRay(m.X, m.Y, 0)
                        o, look = ray.Origin, ray.Direction.Unit
                    end
                end
                local best = math.huge
                for _, t in ipairs(others) do
                    local m = Alive and Alive:FindFirstChild(t.name)
                    local hum = m and m:FindFirstChildOfClass("Humanoid")
                    if not (hum and hum.Health <= 0) then
                        local to = t.pos - o
                        local d = to.Magnitude
                        local score
                        if method == "Screen" then
                            local sc = t.screen
                            if sc.Z > 0 and sc.X >= 0 and sc.Y >= 0 and sc.X <= vp.X and sc.Y <= vp.Y then
                                score = (Vector2.new(sc.X, sc.Y) - anchor).Magnitude
                            end
                        elseif d > 1e-3 then
                            local along = look:Dot(to)
                            if along > 0 then
                                local ang = math.acos(math.clamp(along / d, -1, 1))
                                if method == "Ray distance" then score = (to - look * along).Magnitude
                                elseif method == "Weighted" then score = ang * (1 + d / 150)
                                else score = ang + d * 0.0004 end
                            end
                        end
                        if score and score < best then best, name, pos = score, t.name, t.pos end
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
        targetHold.at, targetHold.mode, targetHold.name, targetHold.pos = now, mode, name, pos
        return name, pos, mode
    end

    local curveFlip = 1
    local function curveLook(cam)
        local mode = Util.CURVE_NAMES[S.curve_mode] or "Camera"
        if S.random_curve then mode = Util.CURVE_NAMES[math.random(1, #Util.CURVE_NAMES)] end
        if mode == "Camera" then return nil end
        local ccf, root = cam.CFrame, getRoot()
        local origin = root and root.Position or ccf.Position
        local _, tpos = pickTarget(cam)
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
        elseif mode == "Alternate" then curveFlip = -curveFlip; d = toT * 0.2 + right * curveFlip
        elseif mode == "Random Side" then d = toT * 0.2 + right * (math.random() < 0.5 and -1 or 1)
        elseif mode == "Zigzag" then curveFlip = -curveFlip; d = toT + up * (1.5 * curveFlip)
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
    local curveCache = { at = -1, mode = nil, look = nil }
    local function curveLookC(cam)
        local now = clock_()
        if now - curveCache.at > Util.PACKET_TTL or curveCache.mode ~= S.curve_mode then
            curveCache.look = curveLook(cam)
            curveCache.at, curveCache.mode = now, S.curve_mode
        end
        return curveCache.look
    end

    local pcall_, type_, typeof_, tostring_ = pcall, type, typeof, tostring
    local floor_, bxor_, byte_, select_ = math.floor, bit32.bxor, string.byte, select
    local hookfunction_, restore_, hookmetamethod_, getnamecallmethod_ = hookfunction, restorefunction, hookmetamethod, getnamecallmethod
    local getrawmetatable_, setreadonly_ = getrawmetatable, setreadonly or make_writeable
    local newcclosure_       = newcclosure or function(f) return f end
    local flight = logp
    local FIRE_FN
    local JOB_ID = game.JobId
    function Core.bac()
        local ok, g = pcall(function() return getrenv and getrenv()._G end)
        if not ok or type(g) ~= "table" then return nil end
        local real, f1, f2 = rawget(g, "BAC_HASH"), rawget(g, "BAC_FAKE_1"), rawget(g, "BAC_FAKE_2")
        return type(real) == "string" and #real == 36 and real or nil, f1, f2
    end
    Core.known_real = "5455ef47-de02-4074-808c-8d82c2cd12ec"
    Core.known_fakes = { ["90fa5062-066f-4376-b9e9-8adc47fbd983"] = true, ["2983784e-7f10-4278-a8d1-259db4906a2b"] = true }

    local H = { fire = nil, nc = nil, want = false, until_t = 0 }

    local function capMethod() return S.one_parry_capture and "Both" or "Namecall" end
    Core.capture_method = capMethod

    local function restoreNc(original)
        local ok = pcall_(function()
            local mt = getrawmetatable_(game)
            local wasRo = isreadonly and isreadonly(mt)
            setreadonly_(mt, false)
            rawset(mt, "__namecall", original)
            if wasRo ~= false then setreadonly_(mt, true) end
        end)
        if not ok then pcall_(hookmetamethod_, game, "__namecall", original) end
    end

    local function learn(remote, hash, uid, token, a4, t)
        local text = tostring_(floor_(t * 100))
        if #token ~= #text then return end
        local key = {}
        for i = 1, #text do key[i] = bxor_(byte_(token, i), (byte_(text, i) + i) % 256) end
        local prev = Core.cap
        Core.cap_n = Core.cap_n + 1
        Core.cap = { remote = remote, hash = hash, uid = uid, key = key, len = #text, ball2 = typeof_(a4) == "CFrame",
            verified = Core.bac() == hash or hash == Core.known_real, id = Core.cap_n,
            win = type_(a4) == "number" and a4 or nil }
        local text2 = tostring_(floor_(t * 100) - 1)
        if #text2 == #token then
            local alt, differs = {}, false
            for i = 1, #text2 do
                alt[i] = bxor_(byte_(token, i), (byte_(text2, i) + i) % 256)
                if alt[i] ~= key[i] then differs = true end
            end
            if differs then Core.cap.alt_key = alt end
        end
        Core.misses, Core.pending = 0, nil
        Core.new_capture = { prev = prev }
        if Parry.onCapture then task.defer(pcall, Parry.onCapture, Core.cap) end
        DBG.ev(Core.cap.verified and "CAPTURE: real parry hash confirmed" or "CAPTURE: taken (real hash not readable)")
    end

    local function inspect(entry)
        local self, a = entry[1], entry[3]
        local a1, a2, a3, a4, a5 = a[1], a[2], a[3], a[4], a[5]
        local real, f1, f2 = Core.bac()
        if a1 == f1 or a1 == f2 or Core.known_fakes[a1] then return false end
        if real and a1 ~= real then return false end
        if entry[5] == "fire" and not (a1 == (real or Core.known_real)) then return false end
        if typeof_(self) == 'Instance' and self.ClassName == 'RemoteEvent'
            and type_(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type_(a2) == 'string' and type_(a3) == 'string'
            and ((type_(a4) == 'number' and typeof_(a5) == 'CFrame') or (typeof_(a4) == 'CFrame' and typeof_(a5) == 'CFrame')) then
            learn(self, a1, a2, a3, a4, entry[4])
            return true
        end
        return false
    end

    local box = { want = false, nc = nil, fire = nil, list = {}, ws = Workspace, now = Workspace.GetServerTimeNow }
    Util.HOOK_NAME = "=ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net"
    Util.NC_SRC = [[
local box, getncm, sel = ...
return function(self, ...)
    if sel("#", ...) >= 6 and box.want and getncm() == "FireServer" then
        local l = box.list
        if #l < 4 then l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)} end
    end
    return box.nc(self, ...)
end]]
    Util.FIRE_SRC = [[
local box, sel = ...
return function(self, ...)
    if sel("#", ...) >= 6 and box.want then
        local l = box.list
        if #l < 4 then l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)} end
    end
    return box.fire(self, ...)
end]]
    
    do
        local ok, renv = pcall(function() return getrenv and getrenv() end)
        Util.CLEAN_ENV = (ok and type(renv) == 'table' and renv.writefile == nil) and setmetatable({}, { __index = renv }) or {}
    end
    function Util.mkBody(src, chunk, ...)
        local args = table.pack(...)
        local ok, fn = pcall(function()
            local factory = loadstring(src, chunk or Util.HOOK_NAME)
            if setfenv then setfenv(factory, Util.CLEAN_ENV) end
            return factory(table.unpack(args, 1, args.n))
        end)
        return ok and type(fn) == 'function' and fn or nil
    end
    Core.isolated = false
    local NC_BODY = function(self, ...)
        if select_("#", ...) >= 6 and box.want and getnamecallmethod_() == "FireServer" then
            local l = box.list
            if #l < 4 then l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws), "nc" } end
        end
        return box.nc(self, ...)
    end
    local FIRE_BODY = function(self, ...)
        if select_("#", ...) >= 6 and box.want then
            local l = box.list
            if #l < 4 then l[#l + 1] = { self, select_("#", ...), { ... }, box.now(box.ws), "fire" } end
        end
        return box.fire(self, ...)
    end

    local function unhook()
        local fire, nc = H.fire, H.nc
        H.fire, H.nc, H.want, box.want = nil, nil, false, false
        if fire and not (restore_ and pcall_(restore_, FIRE_FN)) then pcall_(hookfunction_, FIRE_FN, fire) end
        if nc then restoreNc(nc) end
        box.nc, box.fire = nil, nil
    end
    Core.unhook = unhook

    local function arm(hold)
        if Core.cap or not isLive() then return false end
        if capMethod() == "getgc" then return false end
        H.want, H.until_t = true, clock_() + (hold or 0.2)
        if H.fire or H.nc then return true end
        box.list = {}
        local method = capMethod()
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
        local upAt, done = clock_(), false
        local function finish()
            if done then return end
            done = true
            unhook()
            box.list = {}
            pcall(flight, ("hook (%s) was up %.1fms -- %s"):format(capMethod(), (clock_() - upAt) * 1000,
                Core.cap and "caught the parry" or "nothing caught"))
        end
        H.check = function()
            if done then return true end
            local l = box.list
            for i = 1, #l do
                if pcall_(inspect, l[i]) and Core.cap then break end
            end
            if Core.cap then finish(); return true end
            if #l > 0 then box.list = {} end
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

    function Parry.hookState()
        if H.fire or H.nc then return "UP right now (capturing)" end
        return "down"
    end

    local Capture = { mode = "Your press", armed_at = 0, dry = 0, last_spam_key = -math.huge, lat = nil, last_press = -math.huge, since = nil }
    function Capture.auto() return Capture.mode == "Auto parry" or Capture.mode == "Spam" or Capture.mode == "Auto press" end
    Parry.Capture = Capture
    function Util.capWin() return 0.2 end
    local function pressBlockKey()
        if not isLive() then return false end
        Core.last_send_at = clock_()
        if type(keypress) == "function" and type(keyrelease) == "function" then
            if type(isrbxactive) == "function" then
                local okA, active = pcall(isrbxactive)
                if okA and active == false then return false end
            end
            local ok = pcall(function() keypress(0x46); keyrelease(0x46) end)
            if ok then return true end
        end
        local ok = pcall(function()
            local vim = cloneref(game:GetService('VirtualInputManager'))
            vim:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            vim:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        end)
        return ok
    end
    local function keyParry(capture)
        if capture then arm(Util.capWin()) end
        local r = pressBlockKey()
        if capture and H.check then H.check() end
        return r
    end
    function Util.inLobbyTrain()
        if not LocalPlayer:GetAttribute("LobbyTraining") then return false end
        local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
        return char ~= nil and dead ~= nil and char.Parent == dead
    end

    function Util.rGetUps()
        local g = (getgenv and getgenv()) or {}
        return rawget(g, "getupvalues") or getupvalues or (debug and debug.getupvalues)
    end
    function Util.rConnFn(c)
        for _, k in ipairs({ "Function", "function" }) do
            local ok, f = pcall(function() return c[k] end)
            if ok and type(f) == "function" then return f end
        end
        return nil
    end
    function Util.rIsNet(v)
        if typeof(v) ~= "table" then return false end
        local re; pcall(function() re = rawget(v, "RemoteEvent") or v.RemoteEvent end)
        return type(re) == "function"
    end
    function Util.rClass(v)
        local t = typeof(v)
        if t == "string" then return ("string(#%d)%s"):format(#v, #v == 36 and " <-- hash?" or "") end
        if t == "Instance" then return ("Instance<%s \"%s\">"):format(v.ClassName, v.Name) end
        if t == "function" then
            local ok, s = pcall(function() return debug.info(v, "s") end)
            return "function" .. (ok and (" @" .. tostring(s)) or "")
        end
        if t == "table" then return Util.rIsNet(v) and "table <-- Net?" or "table" end
        return t
    end
    function Util.rDump(fn, getups, label)
        local ok, ups = pcall(getups, fn)
        if not ok or type(ups) ~= "table" then logp(("reflect: getupvalues(%s) failed: %s"):format(label, tostring(ups))); return false end
        local n = 0
        for i, v in pairs(ups) do
            n = n + 1
            logp(("   %s up[%s] = %s"):format(label, tostring(i), Util.rClass(v)))
            if typeof(v) == "table" and not Util.rIsNet(v) then
                local ok2 = pcall(function()
                    local c = 0
                    for k, vv in pairs(v) do
                        c = c + 1; if c > 6 then break end
                        logp(("       .%s = %s"):format(tostring(k), Util.rClass(vv)))
                    end
                end)
            end
        end
        if n == 0 then logp(("reflect: %s has no upvalues (maybe stripped)"):format(label)) end
        return true
    end
    function Util.rTrunc(s) s = tostring(s); return #s > 64 and (s:sub(1, 64) .. "..") or s end
    function Util.rConsts(fn, label)
        local gc = debug and debug.getconstants
        if type(gc) ~= "function" then return false end
        local ok, cs = pcall(gc, fn)
        if not ok or type(cs) ~= "table" then return true end
        local out, n = {}, 0
        for _, c in pairs(cs) do
            if type(c) == "string" and #c > 0 then n = n + 1; out[#out + 1] = Util.rTrunc(c); if n >= 48 then break end end
        end
        if #out > 0 then logp(("reflect: %s consts: %s"):format(label, table.concat(out, " | "))) end
        return true
    end
    function Util.rDeep(v31, getups)
        local ok, ups = pcall(getups, v31)
        if not ok or type(ups) ~= "table" then return end
        for i, v in pairs(ups) do
            if type(v) == "string" then logp(("reflect: up[%s] value = %s"):format(tostring(i), Util.rTrunc(v))) end
            if typeof(v) == "table" and not Util.rIsNet(v) then
                pcall(function()
                    local idx, tbl = v[1], v[2]
                    if type(tbl) == "table" and idx ~= nil then
                        logp(("reflect: up[%s] uid-holder? [1]=%s [3]=%s -> [2][[1]]=%s"):format(
                            tostring(i), tostring(idx), Util.rTrunc(v[3]), Util.rTrunc(tbl[idx])))
                    end
                end)
            end
            if Util.rIsNet(v) then
                pcall(function()
                    local ks = {}
                    for k in pairs(v) do ks[#ks + 1] = tostring(k); if #ks >= 14 then break end end
                    logp(("reflect: up[%s] (Net) keys: %s"):format(tostring(i), table.concat(ks, ", ")))
                end)
            end
        end
        local gotc = Util.rConsts(v31, "v31")
        if not gotc then logp("reflect: debug.getconstants unavailable") end
        local gp = debug and debug.getprotos
        if type(gp) == "function" then
            local ok2, ps = pcall(gp, v31)
            if ok2 and type(ps) == "table" then
                logp(("reflect: v31 has %d nested proto(s)"):format(#ps))
                for pi, pf in ipairs(ps) do Util.rConsts(pf, "proto#" .. pi); if pi >= 6 then break end end
            end
        else
            logp("reflect: debug.getprotos unavailable")
        end
    end
    function Parry.reflectProbe()
        local getups = Util.rGetUps()
        if type(getups) ~= "function" then logp("reflect: getupvalues NOT available on this executor"); return end
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
                Util.rDump(v31, getups, "v31")
                Util.rDeep(v31, getups)
                logp("reflect: done (read-only, nothing called/fired). Send me these lines.")
                return
            elseif type(v31) == "table" then
                logp("reflect: PRY returned a TABLE; dumping its function fields' upvalues:")
                local c = 0
                for k, vv in pairs(v31) do
                    if type(vv) == "function" then c = c + 1; Util.rDump(vv, getups, "PRY." .. tostring(k)) end
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
                if Util.rIsNet(v) then hasNet = true end
            end
            if has36 and hasNet then found[#found + 1] = fn end
            for _, v in pairs(ups) do if type(v) == "function" then scan(v, depth + 1) end end
        end
        for _, c in ipairs(conns) do local f = Util.rConnFn(c); if f then scan(f, 0) end end
        if #found == 0 then
            logp("reflect: fallback found no sender candidate either. Send me the PRY lines above.")
            return
        end
        logp(("reflect: fallback found %d candidate(s):"):format(#found))
        for n, fn in ipairs(found) do Util.rDump(fn, getups, "cand" .. n); if n >= 2 then break end end
        logp("reflect: done (read-only). Send me these lines.")
    end

    function Util.findPry()
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
    function Core.game_call(nowait, fn, ...)
        local args = table.pack(...)
        local env
        pcall(function() env = getrenv and getrenv() end)
        local setenv, box = setfenv, { done = false }
        local caller = function()
            if env and setenv then pcall(setenv, 0, env) end
            box.res = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            box.done = true
        end
        if env and setenv then pcall(setenv, caller, env) end
        task.spawn(caller)
        if not box.done and not nowait then
            local t0 = clock_()
            while not box.done and clock_() - t0 < 3 do task.wait() end
        end
        if not box.done or not box.res[1] then return nil end
        return table.unpack(box.res, 2, box.res.n)
    end
    function Core.holder_value(h)
        if type(h) ~= "table" then return nil end
        local k, inner = rawget(h, 1), rawget(h, 2)
        if k == nil or k ~= k or type(inner) ~= "table" then return nil end
        return rawget(inner, k)
    end
    function Core.key_for(token, uid, nowait)
        local k = Core.game_call(nowait, token, uid, "TIME")
        if type(k) ~= "string" or #k == 0 then return nil end
        local len, key = #tostring(math.floor(Workspace:GetServerTimeNow() * 100)), {}
        for i = 1, len do key[i] = string.byte(k, (i - 1) % #k + 1) end
        return key, len
    end
    function Core.find_sender()
        local getups = Util.rGetUps()
        if type(getups) ~= "function" then return nil, "getupvalues not available", 0 end
        local pry = Util.findPry()
        if not pry then return nil, "PRY not found", 0 end
        local ok, entry = pcall(require, pry)
        if not ok or type(entry) ~= "function" then return nil, "require(PRY) gave " .. typeof(entry), 0 end
        local function isNet(v) return type(v) == "table" and type(rawget(v, "RemoteEvent")) == "function" end
        local function isHolder(v)
            if isNet(v) then return false end
            local val = Core.holder_value(v)
            return val ~= nil and type(val) ~= "function"
        end
        local grm = getrawmetatable
        local seen, queue, found, nodes = {}, { { entry, 0 } }, nil, 0
        while #queue > 0 and not found and nodes < 400 do
            local item = table.remove(queue, 1)
            local fn, depth = item[1], item[2]
            if type(fn) == "function" and not seen[fn] then
                seen[fn] = true
                nodes = nodes + 1
                local okU, ups = pcall(getups, fn)
                if okU and type(ups) == "table" then
                    local hasRemote, token, netI, holder = false, nil, nil, nil
                    local n = 0
                    for i, v in pairs(ups) do if type(i) == "number" and i > n then n = i end end
                    for i = 1, n do
                        local v = ups[i]
                        local t = typeof(v)
                        if t == "Instance" then
                            local okR, r = pcall(function() return v.ClassName == "RemoteEvent" end)
                            if okR and r then hasRemote = true end
                        elseif t == "function" then
                            if not token then token = v end
                            if depth < 4 then queue[#queue + 1] = { v, depth + 1 } end
                        elseif t == "table" then
                            if not netI and isNet(v) then netI = i
                            elseif not holder and isHolder(v) then holder = v
                            elseif depth < 4 and not (grm and grm(v)) then
                                for j = 1, 32 do
                                    local f = rawget(v, j)
                                    if type(f) == "function" then queue[#queue + 1] = { f, depth + 1 } end
                                end
                            end
                        end
                    end
                    if hasRemote and token and netI and holder and type(ups[netI + 1]) == "string" then
                        found = { token = token, net = ups[netI], name = ups[netI + 1], first = ups[netI + 2], holder = holder }
                    end
                end
            end
        end
        if not found then return nil, "send function not found -- the layout changed", nodes end
        return found, nil, nodes
    end
    function Parry.hooklessCapture()
        local function say(t) logp("hookless capture: " .. t); DBG.ev("hookless: " .. t) end
        local found, why, nodes = Core.find_sender()
        if not found then
            say(("%s (%d functions read)"):format(why, nodes))
            return false, why
        end
        say(("send function found after reading %d function(s)"):format(nodes))
        local uid = Core.holder_value(found.holder)
        if type(uid) ~= "string" then say("uid holder is empty"); return false, "no uid" end
        local real = Core.bac()
        local hash = real or (type(found.first) == "string" and #found.first == 36 and found.first) or nil
        if not hash then say("no hash (no _G.BAC_HASH and no 36-char first argument)"); return false, "no hash" end
        local key, len = Core.key_for(found.token, uid, false)
        if not key then say("the token function gave no key"); return false, "no key" end
        local remote = Core.game_call(false, rawget(found.net, "RemoteEvent"), found.net, found.name)
        if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then say("Net:RemoteEvent(name) found no remote"); return false, "no remote" end
        local cap = { remote = remote, hash = hash, uid = uid, key = key, len = len, ball2 = false,
            verified = real ~= nil and hash == real, hookless = true, holder = found.holder, token = found.token, key_uid = uid }
        if H.fire or H.nc then pcall(Core.unhook) end
        Core.cap, Core.misses, Core.pending = cap, 0, nil
        say(("ARMED with no parry: remote %s, hash %s, uid %d chars, key %d bytes"):format(remote.Name,
            cap.verified and "real (BAC_HASH)" or "from the sender", #uid, #key))
        return true
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
    function Util.fnConsts(f)
        local gc = (debug and debug.getconstants) or getconstants
        if type(gc) ~= "function" then return nil end
        local ok, cs = pcall(gc, f)
        return ok and type(cs) == "table" and cs or nil
    end
    function Util.isHandler(o)
        local cs = Util.fnConsts(o)
        if not cs then return false end
        local hasCS, hasBase, hasAC = false, false, false
        for _, c in pairs(cs) do
            if c == "CharacterSword" then hasCS = true
            elseif c == "Base Sword" then hasBase = true
            elseif c == "AnimationCollection" then hasAC = true end
        end
        return hasCS and hasBase and hasAC
    end
    Util.gcScan = { handler = nil, started = false, done = false }
    function Util.gcStart()
        if Util.gcScan.started then return end
        if type(getgc) ~= "function" then Util.gcScan.done = true; return end
        Util.gcScan.started = true
        task.spawn(function()
            local list
            pcall(function() list = getgc(false) end)
            if type(list) == "table" then
                for idx = 1, #list do
                    if not isLive() then break end
                    local o = list[idx]
                    if type(o) == "function" and GC.is_lua(o) then
                        local oks, src = pcall(debug.info, o, "s")
                        if oks and type(src) == "string" then
                            local c = GC.clean(src)
                            if c:find("SwordsController") and not c:find("PRY") and Util.isHandler(o) then
                                Util.gcScan.handler = o; break
                            end
                        end
                    end
                    if idx % 300 == 0 then task.wait() end
                end
            end
            list = nil
            Util.gcScan.done = true
            logp(Util.gcScan.handler and "getgc: parry handler (v186) found -- calling it directly"
                or "getgc: parry handler not found in scan")
        end)
    end

    Util.gcFailAt = -math.huge
    function GC.log(msg) if msg ~= GC.last_msg then GC.last_msg = msg; logp(msg) end end
    function Util.gcGet()
        if type(GC.dispatcher) == "function" then
            if not Core.cap then Core.cap = { gc = true } end
            return true
        end
        if clock_() - Util.gcFailAt < 1 then return false end
        local mode = getgenv().GcSender or "handler"
        local fn, kind
        if mode == "pry" then
            local pry = Util.findPry()
            if pry then local ok, m = pcall(require, pry); if ok and type(m) == "function" then fn, kind = m, "pry" end end
        else
            if type(Util.gcScan.handler) == "function" then fn, kind = Util.gcScan.handler, "handler"
            else
                Util.gcStart()
                if not Util.gcScan.done then return false end
                fn = Util.gcScan.handler; if type(fn) == "function" then kind = "handler" end
            end
        end
        if type(fn) ~= "function" then Util.gcFailAt = clock_(); GC.log("getgc: parry function not found (mode=" .. mode .. ")"); return false end
        local chunk
        if getgenv().GcChunk ~= false then pcall(function() chunk = debug.info(fn, "s") end) end
        local job = { n = 0 }
        local disp = Util.mkBody([[
local job, fn = ...
return function() fn(table.unpack(job, 1, job.n)) end]], chunk, job, fn)
        if type(disp) ~= "function" then Util.gcFailAt = clock_(); GC.log("getgc: could not build a clean dispatcher (no loadstring?)"); return false end
        GC.fn, GC.kind, GC.job, GC.dispatcher = fn, kind, job, disp
        Core.cap = { gc = true }
        Core.misses, Core.pending = 0, nil
        GC.log("getgc: parry acquired (" .. kind .. ") -- calling the game's own parry function (no upvalues, no key, no forge)")
        return true
    end
    function Util.gcFire(spam)
        if type(GC.dispatcher) ~= "function" then return "unarmed" end
        if not isLive() then return "blocked" end
        if not canParryNow() then return "blocked" end
        if not spam and not gateOpen() then return "blocked" end
        if not spam then gateStart() end
        Core.last_send_at = clock_()
        local job = GC.job
        if GC.kind == "handler" then
            job.n = 0
        else
            local cam = Workspace.CurrentCamera
            if not cam then return "blocked" end
            local window = parryWin()
            local points, aim = packetParts(cam)
            local name, _, mode = pickTarget(cam)
            if name and mode ~= "Cursor" then local sp = points[name]; if sp then aim = { sp.X, sp.Y } end end
            local cf, look = cam.CFrame, curveLookC(cam)
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
        if not spam then Core.pending = clock_() + (parryWin() or 0.5) + pingS() + 0.25 end
        return "sent"
    end

    local tokCache = { cap = nil, key = nil, text = nil, tok = nil }
    local function mkToken(cap)
        local text, c = tostring(math.floor(Workspace:GetServerTimeNow() * 100)), tokCache
        if c.cap == cap and c.key == cap.key and c.text == text then return c.tok end
        if #text ~= cap.len then return nil end
        local out = table.create(#text)
        for i = 1, #text do out[i] = string.char(bit32.bxor((string.byte(text, i) + i) % 256, cap.key[i])) end
        c.cap, c.key, c.text, c.tok = cap, cap.key, text, table.concat(out)
        return c.tok
    end
    local function send(spam)
        if not isLive() then return "blocked" end
        local cap = Core.cap
        if not cap then return "unarmed" end
        if cap.gc then return Util.gcFire(spam) end
        if not canParryNow() then return "blocked" end
        if not cap.remote.Parent then Core.cap = nil; return "unarmed" end
        local real = Core.bac()
        if real and cap.hash ~= real then
            cap.hash, cap.verified, cap.adopted, Core.misses = real, true, true, 0
            tokCache.cap = nil
            logp("capture: the game's real hash changed -- carried the capture onto it")
        end
        if not spam and not gateOpen() then return "blocked" end
        if cap.holder then
            local uid = Core.holder_value(cap.holder)
            if type(uid) == "string" and uid ~= cap.key_uid then
                local key, len = Core.key_for(cap.token, uid, true)
                if not key then return "blocked" end
                cap.uid, cap.key, cap.len, cap.key_uid = uid, key, len, uid
            end
        end
        local window, tok = parryWin(), mkToken(cap)
        if not tok then Core.cap = nil; return "unarmed" end
        local cam = Workspace.CurrentCamera
        local points, aim = packetParts(cam)
        local name, _, mode = pickTarget(cam)
        if name and mode ~= "Cursor" then
            local screen = points[name]
            if screen then aim = { screen.X, screen.Y } end
        end
        local cf, look = cam.CFrame, curveLookC(cam)
        if look then local o = cf.Position; cf = CFrame.lookAt(o, o + look) end
        if not spam then gateStart() end
        Core.last_send_at = clock_()
        local r = cap.remote
        if cap.ball2 then
            local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
            r:FireServer(cap.hash, cap.uid, tok, cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
        else
            r:FireServer(cap.hash, cap.uid, tok, window, cf, points, aim, false)
        end
        if not spam then Core.pending = clock_() + window + pingS() + 0.25; cap.sent = (cap.sent or 0) + 1
        else Core.last_spam_at = Core.last_send_at end
        return "sent"
    end

    Util.ABILITY_PARRY = { "Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash" }
    Util.ABILITY_PROTECT = { "Raging Deflection", "Rapture", "Calming Deflection" }
    function Util.abReady()
        local ok, ready = pcall(function() return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5 end)
        return ok and ready
    end
    function Util.hasAbility(list)
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
    function Util.abPress()
        local ok = pcall(function() Remotes.AbilityButtonPress:Fire() end)
        return ok
    end
    Parry.abilityPress = Util.abPress
    function Util.tryAbility()
        if not (S.auto_ability or S.cooldown_protection) or not Remotes or not Util.abReady() then return false end
        if S.auto_ability and Util.hasAbility(Util.ABILITY_PARRY) then
            if not Util.abPress() then return false end
            task.delay(2.432, function()
                local ds = Remotes and Remotes:FindFirstChild("DeathSlashShootActivation")
                if ds then pcall(function() ds:FireServer(true) end) end
            end)
            return true
        end
        if S.cooldown_protection and Util.hasAbility(Util.ABILITY_PROTECT) then return Util.abPress() end
        return false
    end

    local tracked, ballConns = setmetatable({}, { __mode = 'k' }), {}
    local function ballVel(ball)
        local z = ball:FindFirstChild('zoomies')
        return z and z.VectorVelocity or ball.AssemblyLinearVelocity
    end
    local function contactGap(ball)
        local ok, size = pcall(function() return ball.Size end)
        if not ok or not size then return 3 end
        return math.max(size.X, size.Y, size.Z) * 0.5 + 1.5
    end
    function Core.ap_gap(ball) return contactGap(ball) + 1.5 end
    local function ttc(path, gap, speed, accel)
        local d = math.max(path - gap, 0)
        if accel > 1 then return (math.sqrt(speed * speed + 2 * accel * d) - speed) / accel end
        return d / speed
    end
    local function speedGain(st, speed, now)
        local s = st.spd
        if not s then st.spd = { t = now, v = speed, a = 0 }; return 0 end
        local dt = now - s.t
        if dt >= 0.08 then
            if speed > s.v * 1.25 or speed < s.v * 0.75 then s.a = 0
            else s.a = s.a * 0.5 + ((speed - s.v) / dt) * 0.5 end
            s.t, s.v = now, speed
        end
        return math.clamp(s.a, 0, speed * 4)
    end

    local K_DEFAULT, K_MIN, K_MAX = 5, 0.8, 40
    Util.SIM_DT = 1 / 120
    local function trackHoming(st, dir, want, dist, now)
        local h = st.hm
        if not h then
            h = { t = now, dir = dir, want = want, k = nil, w = nil, away = false, n = 0, samples = { { t = now, d = dist } } }
            st.hm = h
            return h
        end
        local dt = now - h.t
        if dt > 0.2 then
            h.t, h.dir, h.want, h.samples = now, dir, want, { { t = now, d = dist } }
            return h
        end
        if dt >= 0.03 then
            local turned = math.acos(math.clamp(h.dir:Dot(dir), -1, 1))
            local omega = turned / dt
            local th = (math.acos(math.clamp(h.dir:Dot(h.want), -1, 1)) + math.acos(math.clamp(dir:Dot(want), -1, 1))) * 0.5
            local perp = h.want - h.dir * h.dir:Dot(h.want)
            local toward, expect = perp.Magnitude < 1e-4 or (dir - h.dir):Dot(perp) >= 0, (h.k or K_DEFAULT) * math.max(math.sin(th), 0.15)
            local snap = turned > 0.35 and (not toward or omega > expect * 3 + 4)
            if snap then
                h.k, h.kn, h.kspread, h.w, h.away = nil, 0, nil, nil, false
                h.samples, h.snap_at = {}, now
                st.k_mem = nil
                if DBG.on then DBG.ev(("sudden turn: %.0f deg in %.0fms -- curve tracking restarted"):format(math.deg(turned), dt * 1000)) end
            end
            if turned > 2e-3 and not snap then
                if toward then
                    h.away = false
                    h.w = h.w and math.max(h.w * 0.5 + omega * 0.5, omega * 0.85) or omega
                    if th > 0.06 then
                        local ks = math.min(omega / math.max(math.sin(th), 0.15), K_MAX * 1.5)
                        local wgt = (h.k and ks > h.k * 2.5) and 0.25 or 0.6
                        if h.k then
                            local rel = math.abs(ks - h.k) / math.max(h.k, K_MIN)
                            h.kspread = h.kspread and (h.kspread * 0.6 + rel * 0.4) or rel
                        end
                        h.k = h.k and (h.k * (1 - wgt) + ks * wgt) or ks
                        h.kn = (h.kn or 0) + 1
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
    local function radialEta(h, rem, speed)
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
    local function simProp(pos, vel, target, gap, k, accel, horizon, tvel)
        local speed = vel.Magnitude
        if speed < 1 then return nil end
        local dir, t = vel / speed, 0
        local a, tstep = math.clamp(k * Util.SIM_DT, 0, 1), tvel and tvel * Util.SIM_DT or nil
        while t < horizon do
            if tstep then target = target + tstep end
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
            speed = speed + accel * Util.SIM_DT
            local move = speed * Util.SIM_DT
            if dir:Dot(want) > 0 and move >= dist - gap then return t + (dist - gap) / speed end
            pos = pos + dir * move
            t = t + Util.SIM_DT
        end
        return nil
    end

    local liveCache = { at = -1, list = {} }
    local function liveBalls()
        local now = clock_()
        if now - liveCache.at < 1 / 240 then return liveCache.list end
        local list = {}
        for _, name in ipairs({ "Balls", "TrainingBalls" }) do
            local folder = Workspace:FindFirstChild(name)
            if folder then
                for _, ball in ipairs(folder:GetChildren()) do
                    if ball:GetAttribute('realBall') then list[#list + 1] = ball end
                end
            end
        end
        liveCache.list, liveCache.at = list, now
        return list
    end
    function Parry.ballOnMe()
        for _, b in ipairs(liveBalls()) do if b:GetAttribute('target') == me then return true end end
        return false
    end
    function Parry.mainBall()
        local balls = liveBalls()
        for _, b in ipairs(balls) do if b:GetAttribute('target') == me then return b end end
        return balls[1]
    end
    Parry.ballVelocity = ballVel

    local onRetarget, onVelocity
    function Util.openPass(st)
        st.pass_open, st.parried, st.landed, st.parry_until = true, false, false, 0
        st.dbg_seen = nil
        if st.hm and st.hm.k then st.k_mem = st.hm.k end
        st.spd, st.hm = nil, nil
        if st.preparried then
            st.parried, st.parry_until, st.preparried = true, st.preparry_until, false
        end
        if S.random_accuracy then Util.rollAcc() end
    end
    function Util.hookZoomies(ball, st, z)
        if st.zinst == z then return end
        st.zinst = z
        ballConns[#ballConns + 1] = z:GetPropertyChangedSignal('VectorVelocity'):Connect(function()
            if active and isLive() and st.target == me then onVelocity(ball, st) end
        end)
    end
    local function ballState(ball)
        local st = tracked[ball]
        if st then return st end
        st = { target = ball:GetAttribute('target'), swaps = {}, pass_open = false, parried = false,
            landed = false, parry_until = 0, preparried = false, preparry_until = 0 }
        tracked[ball] = st
        if st.target == me then Util.openPass(st) end
        ballConns[#ballConns + 1] = ball:GetAttributeChangedSignal('target'):Connect(function()
            if not active or not isLive() then return end
            local new, now, swaps = ball:GetAttribute('target'), clock_(), st.swaps
            swaps[#swaps + 1] = { t = now, from = st.target, to = new }
            if #swaps > 16 then table.remove(swaps, 1) end
            local wasMe = st.target == me
            if DBG.on then
                local r = getRoot()
                local d = r and (ball.Position - r.Position).Magnitude or 0
                DBG.ev(("retarget %s -> %s  (%.0f studs, spd %.0f)%s"):format(tostring(st.target), tostring(new), d,
                    ballVel(ball).Magnitude, new == me and "  << ON YOU" or (wasMe and "  (left you)" or "")))
            end
            if new == me and type(st.target) == 'string' and st.target ~= '' and st.target_at then
                local their, root = charRoot(st.target), getRoot()
                local spd = ballVel(ball).Magnitude
                if their and root and spd > 1 then
                    local r = math.clamp(now - st.target_at - (their.Position - root.Position).Magnitude / spd, 0, 0.3)
                    st.react = st.react and (st.react * 0.5 + r * 0.5) or r
                end
            end
            st.target_at = now
            st.target = new
            if type(new) == 'string' and new ~= '' and new ~= me then
                st.pass_open, st.parried, st.landed = false, false, false
                if wasMe then G.until_t = 0 end
            end
            if new == me and not st.pass_open then Util.openPass(st) end
            onRetarget(ball, st, new, now)
        end)
        local z = ball:FindFirstChild('zoomies')
        if z then Util.hookZoomies(ball, st, z) end
        ballConns[#ballConns + 1] = ball.ChildAdded:Connect(function(c)
            if c.Name == 'zoomies' then Util.hookZoomies(ball, st, c) end
        end)
        return st
    end

    local AutoSpam = { active_until = 0, ball = nil, partner = nil, reason = nil, was_active = false,
        peak = 0, cool_ball = nil, cool_until = 0 }
    local parryAll = {}
    function Core.ball_now(ball)
        local F, now = Core.feed, clock_()
        local fp, ft = F.pos[ball], F.at[ball]
        if fp and ft and F.ahead and now - ft < 0.12 then
            return fp + ballVel(ball) * (now - ft), math.clamp(F.ahead, 0, Core.interp - 0.02)
        end
        return ball.Position, 0
    end
    function Util.clashRange(speed) return math.clamp(18 + speed * 0.08, 18, 50) + (SP.range_bonus or 0) end
    function Util.ballOwners(st)
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
    function Util.quickHandoffs(owners, partner, tempo)
        local n = 0
        for i = 1, #owners - 1 do
            local cur, prev = owners[i], owners[i + 1]
            local alt = (cur.name == me and prev.name == partner) or (cur.name == partner and prev.name == me)
            if not alt or cur.t - prev.t > tempo then break end
            n = n + 1
        end
        return n
    end
    function Util.tradingFast(now, partner)
        local mine, theirs, unknown = 0, 0, 0
        for i = #parryAll, 1, -1 do
            local e = parryAll[i]
            if now - e.t > 0.7 then break end
            if e.who == nil then unknown = unknown + 1
            elseif e.who == me then mine = mine + 1
            elseif e.who == partner then theirs = theirs + 1 end
        end
        return mine >= 1 and (theirs + unknown) >= 1
    end
    function Util.returnsToUs(their, root, partner, gap)
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
    local function clashOn(ball, root, now, held)
        local st = ballState(ball)
        local target = st.target
        if type(target) ~= 'string' or target == '' then return nil end
        local owners = Util.ballOwners(st)
        local partner = (target == me) and (owners[2] and owners[2].name) or target
        if not partner or partner == me then return nil end
        if held and AutoSpam.partner and partner ~= AutoSpam.partner then return nil end
        local their = charRoot(partner)
        if not their then return nil end
        local velocity = ballVel(ball)
        local speed, gap = math.max(velocity.Magnitude, 1), (their.Position - root.Position).Magnitude
        if gap > Util.clashRange(speed) * (held and 1.3 or 1) then return nil end
        local bnow, adj = Core.ball_now(ball)
        local react, sens, back = reachT() - adj, math.clamp(SP.sensitivity or 1.3, 0.6, 2.5), gap / (speed * 1.08)
        local tooFast, tempo = back <= react * sens + 0.08, math.clamp(gap / speed * 2 + react * 2 + 0.15, 0.3, 0.9) * (held and 1.25 or 1)
        local handoffs, trading = Util.quickHandoffs(owners, partner, tempo), Util.tradingFast(now, partner)
        if target == me then
            local off = root.Position - bnow
            local dist = off.Magnitude
            local heading, eta = dist > 0.01 and (velocity / speed):Dot(off / dist) or 1, dist / speed
            if heading < 0.97 then
                local h = st.hm
                if h and h.away then eta = math.huge
                else
                    local k = math.clamp((h and h.k) or st.k_mem or K_DEFAULT, K_MIN, K_MAX)
                    eta = math.max(simProp(bnow, velocity, root.Position, Core.ap_gap(ball), k, 0, react * sens + 0.3) or math.huge, eta)
                end
            end
            if eta <= react * sens + 0.08 + frameDt then return partner, ("lands in %.2fs, too fast to react"):format(eta), true end
            if handoffs >= 1 and tooFast then return partner, "quick hand-off", true end
            if trading and tooFast then return partner, "trading parries", false end
            if held then return partner, "exchange on", false end
            return nil
        end
        if held and owners[1] and now - owners[1].t <= tempo then return partner, "exchange on", false end
        if not (owners[2] and owners[2].name == me) then return nil end
        local toThem = their.Position - bnow
        local dThem = toThem.Magnitude
        if not (dThem < 6 or velocity:Dot(toThem / dThem) > speed * 0.3) then return nil end
        if handoffs >= 2 then return partner, ("%d quick hand-offs"):format(handoffs), true end
        if trading and tooFast then return partner, "trading parries", false end
        local fromMe = owners[2] and owners[2].name == me
        if SP.predictive and fromMe and tooFast and Util.returnsToUs(their, root, partner, gap) then
            return partner, ("predicted: return in %.2fs, you need %.2fs"):format(back, react), false
        end
        return nil
    end
    local function clashStop(ball, root, now)
        if not ball.Parent or not ball:GetAttribute('realBall') then return "ball gone" end
        local partner, target = AutoSpam.partner, ball:GetAttribute('target')
        if type(target) == 'string' and target ~= '' and target ~= me and target ~= partner then
            return "ball went to " .. target
        end
        local their = charRoot(partner)
        if not their then return "partner gone" end
        local speed = math.max(ballVel(ball).Magnitude, 1)
        AutoSpam.peak = math.max(AutoSpam.peak, speed)
        local range, gap = Util.clashRange(speed), (their.Position - root.Position).Magnitude
        if gap > range * 1.4 then return "partner out of range" end
        local bpos = Core.ball_now(ball)
        if math.min((bpos - root.Position).Magnitude, (bpos - their.Position).Magnitude) > range * 1.5 + 10 then
            return "ball left the exchange"
        end
        if speed < 60 and speed < AutoSpam.peak * 0.35 then return "ball slowed down" end
        local st = tracked[ball]
        if st then
            local o = Util.ballOwners(st)[1]
            if o and o.name == partner and o.t > 0 then
                local limit = math.max(math.clamp(gap / speed * 2 + reachT() * 2 + 0.15, 0.3, 0.9) * 2, 0.6)
                if now - o.t > limit then return "they stopped returning it" end
            end
        end
        return nil
    end
    local function canSpam(root)
        return SP.auto and root and not root:FindFirstChild('SingularityCape') and canParryNow()
            and not Util.inTrain() and not blocked()
    end
    function Util.markClash(ball, now, partner, why)
        if AutoSpam.ball ~= ball or AutoSpam.partner ~= partner then
            logp(("auto spam ON vs %s (%s)"):format(tostring(partner), why))
            AutoSpam.peak = 0
        end
        AutoSpam.ball, AutoSpam.partner = ball, partner
        AutoSpam.active_until = now + math.clamp(SP.hold or 0.15, 0, 0.5) + 0.02
        AutoSpam.reason = ("vs %s (%s)"):format(partner, why)
    end
    function Util.endClash(why, cool)
        if AutoSpam.ball then
            logp("auto spam OFF: " .. tostring(why))
            if cool then AutoSpam.cool_ball, AutoSpam.cool_until = AutoSpam.ball, clock_() + 0.25 end
        end
        AutoSpam.active_until, AutoSpam.reason, AutoSpam.ball, AutoSpam.partner = 0, nil, nil, nil
    end
    function Util.hasClash(ball, now) return AutoSpam.ball == ball and now < AutoSpam.active_until end
    local function cooling(ball, now) return ball == AutoSpam.cool_ball and now < AutoSpam.cool_until end
    local function clashCheck(ball, now)
        local root = getRoot()
        if not canSpam(root) then return false end
        local held = AutoSpam.ball == ball
        local partner, why, strong = clashOn(ball, root, now, held)
        if not partner or (not held and cooling(ball, now) and not strong) then return false end
        Util.markClash(ball, now, partner, why)
        return true
    end
    local function spamEval(now)
        if not SP.auto then if AutoSpam.ball then Util.endClash("auto spam off") end; return end
        local root = getRoot()
        if not canSpam(root) then if AutoSpam.ball then Util.endClash("can't spam here") end; return end
        local cur = AutoSpam.ball
        if cur then
            local why = clashStop(cur, root, now)
            if why then
                Util.endClash(why, true)
            else
                local partner, reason = clashOn(cur, root, now, true)
                if partner then Util.markClash(cur, now, partner, reason); return end
                if now < AutoSpam.active_until then return end
                Util.endClash("clash over", true)
            end
        end
        for _, ball in ipairs(liveBalls()) do
            local partner, why, strong = clashOn(ball, root, now, false)
            if partner and (strong or not cooling(ball, now)) then Util.markClash(ball, now, partner, why); return end
        end
    end

    local Pump = { credit = 0, last = clock_(), on = false, frame = 0, frame_fires = 0, fired_frame = -1, waiting = false }
    local SpamMeter = { count = 0, since = clock_(), rate = 0 }
    local function curSource(now)
        if SP.manual then return "manual" end
        if SP.auto and now < AutoSpam.active_until then return "auto" end
        return nil
    end
    local function spamFocus()
        local root = getRoot()
        if not root then return false end
        local horizon = reachT() + 0.25
        for _, ball in ipairs(liveBalls()) do
            local st = ballState(ball)
            if st.target == me then return true end
            local vel = ballVel(ball)
            local speed, off = vel.Magnitude, root.Position - ball.Position
            local d = off.Magnitude
            if d <= 20 + speed * 0.05 then return true end
            if speed > 1 and d > 0.01 and (vel / speed):Dot(off / d) > 0.3 and d / speed <= horizon then return true end
        end
        return false
    end
    local function fireOne()
        if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
        if SP.mode == "Keypress" and Pump.frame_fires >= 1 then return false end
        local ok, remote = false, false
        if SP.mode == "Keypress" then ok = pressBlockKey()
        elseif not Core.cap and capMethod() == "getgc" then
            if clock_() - Capture.last_spam_key < 0.3 then return false end
            Capture.last_spam_key = clock_()
            if Util.gcGet() then ok = send(true) == "sent"; remote = ok end
        elseif not Core.cap then
            if not Capture.auto() then return false end
            if clock_() - Capture.last_spam_key < 0.3 then return false end
            Capture.last_spam_key = clock_()
            ok = keyParry(true)
        else
            ok = send(true) == "sent"
            remote = ok
        end
        Pump.frame_fires = Pump.frame_fires + 1
        if ok then SpamMeter.count = SpamMeter.count + 1 end
        if capMethod() == "getgc" then remote = false end
        Pump.remote_sent = Pump.remote_sent or remote
        return ok
    end
    function SP.rate_now(now)
        if SP.timing == "Every X ms" then return 1000 / math.max(tonumber(SP.interval_ms) or 2, 0.5) end
        return tonumber(tostring(SP.speed_mode):match("%d+")) or 700
    end
    function SP.ball_speed()
        local b = AutoSpam.ball
        if b and b.Parent then return ballVel(b).Magnitude end
        local best = 0
        for _, ball in ipairs(liveBalls()) do
            if ball:GetAttribute('target') == me then best = math.max(best, ballVel(ball).Magnitude) end
        end
        return best
    end
    function SP.high_speed() return SP.hs_fix and SP.ball_speed() >= (SP.hs_speed or 400) end
    function SP.per_frame_on() return (SP.per_frame or SP.method == "Per frame") and not SP.high_speed() end
    function SP.frame_burst()
        local n = math.clamp(math.floor(tonumber(SP.per_frame_count) or 1), 1, 20)
        if SP.mode == "Keypress" then n = 1 end
        local sent = false
        while Pump.frame_fires < n do
            if not fireOne() then break end
            sent = true
        end
        return sent
    end
    function SP.on_ball_now()
        local root = getRoot()
        if not root then return false end
        for _, ball in ipairs(liveBalls()) do
            local st = ballState(ball)
            if st.target == me then return true end
            local bp = Core.ball_now(ball)
            if (bp - root.Position).Magnitude <= 12 then return true end
        end
        return false
    end
    function SP.method_rate(rate)
        if SP.method == "Ping adaptive" then
            rate = math.min(rate, math.max(60, 12 / math.max(pingS(), 0.02)))
        end
        if SP.high_speed() then
            rate = math.min(rate, 60 * math.clamp(math.floor(SP.hs_per_tick or 2), 1, 6))
        end
        return rate
    end
    local function spamTick(now, point)
        local elapsed = math.min(now - Pump.last, 0.25)
        Pump.last = now
        local span = now - SpamMeter.since
        if span >= 1 then SpamMeter.rate, SpamMeter.count, SpamMeter.since = SpamMeter.count / span, 0, now end
        local source = curSource(now)
        if not source or not LocalPlayer.Character then Pump.on, Pump.waiting = false, false; return end
        local focus = spamFocus()
        if source == "manual" and SP.smart and not focus then Pump.on, Pump.waiting = false, true; return end
        Pump.waiting = false
        if SP.method == "On ball" and not SP.on_ball_now() then Pump.on = false; return end
        if SP.per_frame_on() then
            if point == 1 then
                Pump.on, Pump.sent = true, nil
                if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
                if SP.frame_burst() and Pump.remote_sent then Anim.spamBlock() end
                Pump.remote_sent = false
            end
            return
        end
        local rate = SP.method_rate(math.clamp(SP.rate_now(now), 1, 2000))
        if SP.mode == "Keypress" then rate = math.min(rate, 1 / frameDt) end
        rate = math.max(rate, 1)
        if not Pump.on or not Pump.sent then Pump.on, Pump.rate, Pump.t0, Pump.sent = true, rate, now, 0
        elseif Pump.rate ~= rate then Pump.rate, Pump.t0 = rate, now - Pump.sent / rate end
        local allowed, sent = math.floor((now - Pump.t0) * rate) + 1, false
        while Pump.sent < allowed do
            if not fireOne() then Pump.t0 = now - (Pump.sent - 1) / rate; break end
            Pump.sent = Pump.sent + 1
            sent = true
        end
        if sent and Pump.remote_sent then Anim.spamBlock() end
        Pump.remote_sent = false
    end
    local function spamInstant()
        local source = curSource(clock_())
        if not source or not LocalPlayer.Character then return end
        if source == "manual" and SP.smart and not spamFocus() then return end
        if SP.per_frame_on() then
            if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
            local n = (SP.mode == "Keypress") and 1 or math.clamp(math.floor(tonumber(SP.per_frame_count) or 1), 1, 20)
            if Pump.frame_fires < n and fireOne() and Pump.remote_sent then Anim.spamBlock() end
            Pump.remote_sent = false
            return
        end
        if SP.method == "On ball" and not SP.on_ball_now() then return end
        local now = clock_()
        local rate = math.max(SP.method_rate(math.clamp(SP.rate_now(now), 1, 2000)), 1)
        if not Pump.on or not Pump.sent then Pump.on, Pump.rate, Pump.t0, Pump.sent = true, rate, now, 0
        elseif Pump.rate ~= rate then Pump.rate, Pump.t0 = rate, now - Pump.sent / rate end
        if Pump.sent > math.floor((now - Pump.t0) * rate) + 1 then return end
        if fireOne() then
            Pump.sent = Pump.sent + 1
            if Pump.remote_sent then Anim.spamBlock() end
        end
        Pump.remote_sent = false
    end
    function Parry.spamWaiting() return Pump.waiting end

    local function markParried(st, now)
        local _, n2 = parryWin()
        st.parried, st.parry_until = true, now + (n2 or 1.3) + 0.08
    end
    local function passBusy(st, now)
        if st.landed then return true end
        if st.parried then
            if now < st.parry_until then return true end
            st.parried = false
        end
        return false
    end
    local function fire(st, now, via, info, ball)
        local how
        if capMethod() == "getgc" and S.parry_mode ~= "Keypress" then
            if not Core.cap then pcall(Util.gcGet) end
            if not Core.cap then return false end
        end
        local hookmode = capMethod() ~= "getgc" and S.parry_mode ~= "Keypress"
        local rescue = st.rescue and S.rescue_press and S.parry_mode ~= "Keypress"
        if hookmode and not Capture.auto() and not Core.cap and not rescue then return false end
        local fresh = hookmode and Capture.auto() and (not Core.cap or Core.misses >= 1)
        if Util.tryAbility() then how = "ability"
        elseif S.parry_mode == "Keypress" or fresh or rescue then
            if not gateOpen() or not canParryNow() then return false end
            local capturing = fresh or (rescue and not Core.cap)
            keyParry(capturing); gateStart()
            how = rescue and "key, rescue" or (not fresh and "key" or (Core.cap and "key, refreshing capture" or "key, capturing"))
            if rescue then st.rescue = nil; Core.diag.rescued = Core.diag.rescued + 1 end
        else
            if send(false) ~= "sent" then return false end
            how = "remote"
            local tSend = clock_()
            Core.await = { t = tSend, ball = ball, st = st, cap = Core.cap, spam_at = Core.last_spam_at,
                gap = tSend - (Core.last_single_at or -math.huge) }
            Core.last_single_at = tSend
            if capMethod() ~= "getgc" then Anim.block() end
        end
        Core.last_parry = { t = now, via = via, info = info }
        Core.diag.fired = Core.diag.fired + 1
        if DBG.on then
            DBG.ev(info and ("FIRE %s [%s] d %.0f spd %.0f eta %.2f lead %.2f"):format(via, how, info.dist or 0,
                info.speed or 0, math.min(info.eta or 0, 9.99), info.lead or 0) or ("FIRE %s [%s]"):format(via, how))
        end
        if how ~= "remote" and how ~= "ability" then Core.pending = clock_() + (parryWin() or 0.5) + pingS() + 0.3 end
        local root = getRoot()
        Core.watch = ball and root and { ball = ball, t = now, how = how, d0 = (ball.Position - root.Position).Magnitude,
            min_d = math.huge, min_t = now, ping = pingS(), W = parryWin() or 0.5, lead = info and info.lead,
            eta = info and info.eta,
            cap = how == "remote" and Core.cap or nil } or nil
        markParried(st, now)
        if info then
            logp(("%s [%s] dist %.0f spd %.0f head %.2f eta %.2f lead %.2f%s"):format(via, how, info.dist or 0,
                info.speed or 0, info.heading or 0, math.min(info.eta or 0, 9.99), info.lead or 0,
                info.k and (" k %.1f"):format(info.k) or ""))
        else
            logp(("%s [%s]"):format(via, how))
        end
        return true
    end

    function Det.tornado(ball, now)
        if Det.tor_fid ~= Core.fid then
            Det.tor_fid = Core.fid
            local list = {}
            for _, t in ipairs(CollectionService:GetTagged("AerodynamicSlashTornado")) do
                local first = Det.tor[t]
                if not first then
                    first = now; Det.tor[t] = first
                    DBG.ev(("aerodynamic slash tornado on %s: holding %.1fs"):format(tostring(t:GetAttribute("Ball")),
                        tonumber(t:GetAttribute("TornadoTime")) or 1))
                    logp(("aerodynamic slash on %s: holding the parry %.1fs while it spins"):format(
                        tostring(t:GetAttribute("Ball")), tonumber(t:GetAttribute("TornadoTime")) or 1))
                end
                local name = t:GetAttribute("Ball")
                if name and now - first < (tonumber(t:GetAttribute("TornadoTime")) or 1) + 0.05 then list[name] = true end
            end
            Det.tor_list = list
        end
        return Det.tor_list[ball.Name] == true
    end
    local function decide(ball, st, root, now, via)
        if passBusy(st, now) then DBG.held(st.landed and "this pass landed" or "already fired on this pass", now); return end
        if blocked(ball) then DBG.held("ability detection: " .. (Det.ball_detected(ball) or "you"), now); return end
        if Det.tornado(ball, now) then DBG.held("aerodynamic slash tornado", now); return end
        local vel = ballVel(ball)
        local speed = vel.Magnitude
        if speed < 1 then return end
        local bpos, adj = Core.ball_now(ball)
        local rpos = root.Position
        local offset = rpos - bpos
        local dist = offset.Magnitude
        if dist < 0.01 then return end
        local dir, want = vel / speed, offset / dist
        local heading, W, reach, gap = dir:Dot(want), parryWin() or 0.5, reachT() - jitter() - adj, Core.ap_gap(ball)
        local rem, accel, h = math.max(dist - gap, 0), speedGain(st, speed, now), trackHoming(st, dir, want, dist, now)
        local tune = S.self_tune and Core.tune or 0
        local mustBy = reach + safeMargin() + math.max(tune, 0)
        local lead, half, mv = math.max(reach + cushion(speed, W) + tune, mustBy), frameDt * 0.5, root.AssemblyLinearVelocity
        local closeSpd = math.clamp(speed - Vector3.new(mv.X, 0, mv.Z):Dot(want), speed * 0.5, speed * 1.5)
        local tMin = ttc(dist, gap, closeSpd, accel)
        local info = { speed = speed, dist = dist, heading = heading, lead = lead, eta = tMin }
        if DBG.on then
            local e = DBG.eval
            e.t, e.via, e.speed, e.dist, e.heading, e.reach, e.lead, e.t_min, e.k, e.feed = now, via or "frame",
                speed, dist, heading, reach, lead, tMin, h.k, adj > 0
            e.fast, e.slow, e.radial = nil, nil, nil
            info.dbg = e
            if not st.dbg_seen then
                st.dbg_seen = true
                if tMin < reach then
                    DBG.ev(("LATE: first seen %.2fs from landing, reach %.2fs (%s) -- already too close when the data arrived"):format(
                        tMin, reach, via or "frame"))
                end
            end
        end
        local tag = (via and ("auto parry (" .. via .. ")") or "auto parry") .. ((adj > 0 and via ~= "feed") and " [feed]" or "")
        if rem <= 3 then return fire(st, now, tag .. " (contact)", info, ball) end
        if tMin > lead + half then return end
        if heading >= 0.996 then return fire(st, now, tag, info, ball) end
        local measured, guess = h.k and (h.kn or 0) >= 2, st.k_mem or K_DEFAULT
        local km = math.clamp(h.k or guess, K_MIN, K_MAX)
        local kmHi = measured and km or math.clamp(math.max(km, guess, K_DEFAULT), K_MIN, K_MAX)
        local kmLo, v = measured and km or math.clamp(math.min(km, guess, K_DEFAULT), K_MIN, K_MAX), vel
        if heading < -0.95 then
            local side = dir:Cross(Vector3.yAxis)
            if side.Magnitude < 1e-3 then side = dir:Cross(Vector3.xAxis) end
            v = (dir + side.Unit * 0.08).Unit * speed
        end
        local rv = root.AssemblyLinearVelocity
        local tvel = Vector3.new(rv.X, 0, rv.Z)
        if tvel.Magnitude < 1 then tvel = nil end
        local snapped = h.snap_at and now - h.snap_at < 0.15
        local kFast = (S.hard_curve or snapped) and K_MAX or math.min(kmHi * 1.25, K_MAX)
        local fast = math.max(simProp(bpos, v, rpos, gap, kFast, accel, mustBy + 0.05, tvel) or math.huge, tMin)
        info.fast = fast
        if info.dbg then info.dbg.fast = fast end
        if fast <= mustBy + half then
            info.eta = fast
            return fire(st, now, tag .. " (curve, must)", info, ball)
        end
        if h.away and heading < 0.97 then return end
        local slowF = 0.75
        if measured and (h.kn or 0) >= 3 and h.kspread and h.kspread < 0.4 then
            slowF = math.clamp(1 - h.kspread * 0.5, 0.8, 0.95)
        end
        local slow = math.max(simProp(bpos, v, rpos, gap, math.max(kmLo * slowF, K_MIN), accel, lead + 0.05, tvel) or math.huge, tMin)
        info.eta, info.slow, info.k = slow, slow, km
        if info.dbg then info.dbg.slow = slow end
        if slow <= lead + half then return fire(st, now, tag .. " (curve)", info, ball) end
        local s = h.samples
        local closing = #s >= 2 and (s[#s - 1].d - s[#s].d) / math.max(s[#s].t - s[#s - 1].t, 1e-3) or 0
        if closing >= speed * 0.35 then
            local radial = radialEta(h, rem, speed)
            if radial then
                radial = math.max(radial, tMin)
                if info.dbg then info.dbg.radial = radial end
                if radial <= lead + half then
                    info.eta = radial
                    return fire(st, now, tag .. " (curve, closing)", info, ball)
                end
            end
        end
    end

    local function trigger(ball, st, now)
        if passBusy(st, now) or Util.hasClash(ball, now) or blocked(ball) then return end
        fire(st, now, "triggerbot", nil, ball)
    end

    local function tryPreparry(ball, st, root, now)
        if st.preparried then
            if now < st.preparry_until then return end
            st.preparried = false
        end
        if not (S.preparry or (S.hp_preparry and (Lag.avg or pingS()) >= 0.08)) then return end
        if not Core.cap or blocked(ball) then return end
        local target = st.target
        if type(target) ~= 'string' or target == '' or target == me then return end
        local their = charRoot(target)
        if not their then return end
        local vel = ballVel(ball)
        local speed = vel.Magnitude
        if speed < 1 then return end
        local gap = (their.Position - root.Position).Magnitude
        if gap > (S.preparry_range or 20) then return end
        local toThem = their.Position - ball.Position
        local dThem = toThem.Magnitude
        if dThem > 3 and vel:Dot(toThem / dThem) < speed * 0.3 then return end
        local back, reach = gap / (speed * 1.1), reachT()
        if back > reach + frameDt * 2 then return end
        local eta, lead = dThem / speed + math.clamp(st.react or 0.05, 0, 0.3) + back, fireLead(speed)
        if eta > lead or Util.hasClash(ball, now) then return end
        if send(false) == "sent" then
            Anim.block()
            local W, n2 = parryWin()
            st.preparried = true
            st.preparry_until = now + math.max((W or 0.5) + reach + 0.15, (n2 or 1.3) + 0.08)
            Core.last_parry = { t = now, via = "pre-parry", info = { eta = eta, lead = lead } }
            logp(("pre-parry: return in %.2fs, lead %.2fs, gap %.0f, spd %.0f"):format(eta, lead, gap, speed))
        end
    end

    function Core.fast_retarget(ball, st, root, now)
        if passBusy(st, now) or blocked(ball) or Det.tornado(ball, now) then return false end
        local speed = ballVel(ball).Magnitude
        if speed < 1 then return false end
        local bpos, adj = Core.ball_now(ball)
        local dist, gap = (root.Position - bpos).Magnitude, Core.ap_gap(ball)
        local soonest, W, reach = math.max(dist - gap, 0) / speed, math.min(parryWin() or 0.5, 0.6), reachT() - jitter() - adj
        local mustBy = reach + safeMargin()
        local lead, holds = math.max(reach + cushion(speed, W), mustBy), reach + W - (jitter() + frameDt + 0.03)
        local info = { speed = speed, dist = dist, heading = 0, lead = lead, eta = soonest }
        if soonest <= mustBy then return fire(st, now, "fast retarget (must)", info, ball) end
        if soonest > lead then
            DBG.held(("fast retarget: not due (%.2fs > lead %.2fs)"):format(soonest, lead), now)
            return false
        end
        if soonest * 2 > holds then
            DBG.held(("fast retarget: a curve could outlast the parry (%.2fs x2 > %.2fs)"):format(soonest, holds), now)
            return false
        end
        return fire(st, now, "fast retarget", info, ball)
    end
    onRetarget = function(ball, st, new, now)
        if new == me then
            if S.fast_retarget and S.autoparry and not S.triggerbot then
                local root = apRoot()
                if root then Core.fast_retarget(ball, st, root, now) end
            end
            if SP.auto then clashCheck(ball, now) end
            if Util.hasClash(ball, now) then spamInstant() end
            if S.autoparry and not S.triggerbot then
                task.defer(function()
                    if not active or not isLive() or st.target ~= me then return end
                    local root = apRoot()
                    if root then decide(ball, st, root, clock_(), "retarget") end
                end)
            end
            if S.triggerbot then
                local root = apRoot()
                if root then trigger(ball, st, now) end
            end
            if SP.manual then spamInstant() end
        elseif SP.auto then
            if AutoSpam.ball == ball and type(new) == 'string' and new ~= '' and new ~= AutoSpam.partner then
                Util.endClash("ball went to " .. new, true)
            else
                clashCheck(ball, now)
            end
        end
    end
    onVelocity = function(ball, st)
        DBG.counts.vel = DBG.counts.vel + 1
        if not (S.autoparry or S.triggerbot) then return end
        local root = apRoot()
        if not root then return end
        if st.reopen_until and clock_() < st.reopen_until and (st.parried or st.landed)
            and ballVel(ball):Dot(root.Position - Core.ball_now(ball)) > 0 then
            st.reopen_until = nil
            Util.openPass(st); G.until_t = 0
        end
        if S.triggerbot then trigger(ball, st, clock_()) else decide(ball, st, root, clock_(), "velocity") end
    end

    local function capSafe()
        local root = getRoot()
        if not root then return false end
        for _, ball in ipairs(liveBalls()) do
            if ball:GetAttribute('target') == me then return false end
            local speed, d = ballVel(ball).Magnitude, (ball.Position - root.Position).Magnitude
            if d < 20 or (speed > 1 and d / speed < 1.6) then return false end
        end
        return true
    end
    local function needsCap()
        return ((S.autoparry or S.triggerbot) and S.parry_mode ~= "Keypress") or ((SP.manual or SP.auto) and SP.mode ~= "Keypress")
    end
    local function primeCap(now)
        if Core.cap or not needsCap() then return end
        if capMethod() == "getgc" then pcall(Util.gcGet); return end
        if not (Util.inMatch() or Util.inLobbyTrain()) or not canParryNow() then Capture.since = nil; return end
        Capture.since = Capture.since or now
        if capMethod() ~= "getgc" and Capture.mode == "Spam" then
            local wasUp = (H.nc or H.fire) ~= nil
            if arm(0.5) and not wasUp then logp(("capture: spamming F until the remote is read (%s hook)"):format(capMethod())) end
            if now - Capture.last_press >= 0.1 then
                Capture.last_press = now
                pressBlockKey()
                if H.check then H.check() end
            end
            return
        end
        if capMethod() ~= "getgc" and Capture.mode ~= "Auto press" then
            local wasUp = (H.nc or H.fire) ~= nil
            if arm(0.5) and not wasUp then
                logp(("capture: %s hook up until %s"):format(capMethod(),
                    Capture.mode == "Auto parry" and "auto parry's first press" or "your first real parry"))
            end
            return
        end
        if Capture.mode == "Auto press" then
            if now - Capture.since < 1 or now - Capture.last_press < 1.4 then return end
            if Capture.dry >= 3 then
                if now - Capture.last_press < 20 then return end
                Capture.dry = 0
            end
            if not gateOpen() or not capSafe() then return end
            Capture.last_press = now
            local window = Util.capWin()
            if arm(window) then
                pressBlockKey(); gateStart()
                logp(("capture press (%s, %s, hook up <= %.0fms, no ball near)"):format(capMethod(), Core.ctx, window * 1000))
            end
            return
        end
        if Capture.mode ~= "Incoming ball" then return end
        local imminent = false
        do
            local root = getRoot()
            if root then
                local horizon = reachT() + (parryWin() or 0.5)
                for _, ball in ipairs(liveBalls()) do
                    if ball:GetAttribute('target') == me then
                        local vel = ballVel(ball)
                        local speed, off = vel.Magnitude, root.Position - ball.Position
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
        if arm(math.clamp(tonumber(getgenv().CaptureWindow) or 0.4, 0.12, 1.5)) and now - (Capture.notified or 0) > 5 then
            Capture.notified = now
            logp("capture: block this ball yourself -- the hook reads that one real parry, then auto-forge takes over (" .. capMethod() .. ")")
        end
    end

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
        if not isLive() then return end
        local t, k = input.UserInputType, input.KeyCode
        local touch, name = t == Enum.UserInputType.Touch, (k ~= Enum.KeyCode.Unknown) and k.Name or t.Name
        if not touch and not processed then Capture.last_in, Capture.last_in_at = name, clock_() end
        if Core.cap or Capture.mode ~= "Your press" or not needsCap() then return end
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
            logp("capture: reading your block press (" .. capMethod() .. ")")
        end
    end
    function Parry.learnBind()
        local n, at = Capture.last_in, Capture.last_in_at or -math.huge
        if not n or Capture.binds[n] or clock_() - at > 0.2 then return end
        Capture.learn[n] = (Capture.learn[n] or 0) + 1
        if Capture.learn[n] >= 2 then
            Capture.binds[n] = true
            logp("capture: learned your block key " .. n)
        end
    end

    function Util.missVerdict(w)
        if not w then return "parry unanswered (no ball watched)" end
        local head = ("parry unanswered [%s]: fired at %.0f studs"):format(tostring(w.how), w.d0)
        if w.min_d == math.huge then return head .. " -- ball gone before it got near" end
        local dt = w.min_t - w.t
        local open, close = w.ping, w.ping + w.W
        local tail = ("; closest %.0f studs, %.2fs after the fire (parry up ~%.2f-%.2fs, ping %.0fms%s)"):format(
            w.min_d, dt, open, close, w.ping * 1000, w.lead and (", lead %.2f"):format(w.lead) or "")
        local verdict
        if w.min_d > 15 then verdict = " -> ball never reached you (curved off / went elsewhere): not a timing miss"
        elseif dt > close then verdict = (" -> EARLY by %.2fs"):format(dt - close); Core.verdict = -(dt - close)
        elseif dt < open then verdict = (" -> LATE by %.2fs"):format(open - dt); Core.verdict = open - dt
        else verdict = " -> ON TIME by what we see: the server didn't count it" end
        local c = w.cap
        local capinfo = c and ("\n    capture #%d (taken %.0fms after its press): %d of %d remote parries landed"):format(
            c.id or 0, (c.lat or 0) * 1000, c.landed or 0, c.sent or 0) or ""
        return head .. tail .. verdict .. capinfo
    end

    function Parry.frame(dt, point)
        if not active or not isLive() then return end
        local now = clock_()
        if point == 1 then
            if dt then frameDt = math.clamp(dt, 1 / 240, 0.1) end
            Core.fid = (Core.fid or 0) + 1
            Pump.frame = Pump.frame + 1
            local ctx = Util.inLobbyTrain() and "training" or "match"
            if ctx ~= Core.ctx then
                if Core.pending then logp(Util.missVerdict(Core.watch) .. " [round ended]") end
                Core.ctx = ctx
                Core.misses, Core.pending, Core.watch = 0, nil, nil
            end
            local aw = Core.await
            if aw then
                local E = Core.echo
                local fair = E.forged_ok and aw.cap == Core.cap and aw.t - aw.spam_at > 1.5
                    and Core.last_spam_at <= aw.spam_at and (aw.gap or math.huge) > 1.45
                if not fair then
                    if now - aw.t > 1 then Core.await = nil end
                else
                    local limit = math.max((E.rtt or pingS()) * 2 + 0.03, pingS() * 1.5 + jitter() * 2 + frameDt * 2 + 0.06)
                    if now - aw.t > limit then
                        Core.await = nil
                        Core.refused(aw, now, now - aw.t)
                    end
                end
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
                Core.verdict = nil
                logp(Util.missVerdict(Core.watch))
                do
                    local D = Core.diag
                    if Core.verdict then
                        if Core.verdict > 0 then D.late = D.late + 1 else D.early = D.early + 1 end
                    elseif Core.watch and Core.watch.min_d <= 15 then D.ontime = D.ontime + 1 end
                end
                if Core.cap and Core.cap.adopted and Core.misses >= 2 then
                    Core.cap = nil
                    logp("capture: two parries unanswered on the carried-over hash -- dropped, parry once to recapture")
                end
                if DBG.on then DBG.ev("MISS: " .. Util.missVerdict(Core.watch):gsub("\n.*", "")) end
                if S.self_tune and Core.verdict then
                    Core.tune = math.clamp(Core.tune + math.clamp(Core.verdict * 0.5, -0.015, 0.015), -0.04, 0.04)
                    logp(("  self-tune: now firing %+.0fms"):format(Core.tune * 1000))
                end
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
            if not Core.cap then primeCap(now) end
            spamEval(now)
            local act = now < AutoSpam.active_until
            if act and not AutoSpam.was_active and not SP.manual then spamInstant() end
            AutoSpam.was_active = act
        end
        if S.autoparry or S.triggerbot then
            local root = apRoot()
            if root then
                local mine
                for _, ball in ipairs(liveBalls()) do
                    local st = ballState(ball)
                    if st.target == me then
                        if not mine then mine = { ball, st }
                        else
                            if not mine.list then mine = { list = { { ball = mine[1], st = mine[2] } } } end
                            mine.list[#mine.list + 1] = { ball = ball, st = st }
                        end
                    else
                        tryPreparry(ball, st, root, now)
                    end
                end
                if mine and not mine.list then
                    if S.triggerbot then trigger(mine[1], mine[2], now) else decide(mine[1], mine[2], root, now) end
                elseif mine then
                    local rp = root.Position
                    for _, e in ipairs(mine.list) do
                        e.eta = (Core.ball_now(e.ball) - rp).Magnitude / math.max(ballVel(e.ball).Magnitude, 1)
                    end
                    table.sort(mine.list, function(x, y) return x.eta < y.eta end)
                    for _, e in ipairs(mine.list) do
                        if S.triggerbot then trigger(e.ball, e.st, now) else decide(e.ball, e.st, root, now) end
                    end
                end
            end
        elseif SP.auto or SP.manual then
            for _, ball in ipairs(liveBalls()) do ballState(ball) end
        end
        spamTick(now, point)
    end

    function Parry.onBallFeed(ball, p)
        if typeof(ball) ~= "Instance" or not ball:IsA("BasePart") then return end
        if typeof(p) == "CFrame" then p = p.Position end
        if typeof(p) ~= "Vector3" then return end
        local F, now = Core.feed, clock_()
        if F.since == 0 then F.since = now end
        F.n, F.total = F.n + 1, F.total + 1
        DBG.counts.feed = DBG.counts.feed + 1
        F.pos[ball], F.at[ball] = p, now
        local v = ballVel(ball)
        local sp = v.Magnitude
        if sp > 20 then
            local ahead = (p - ball.Position):Dot(v / sp) / sp
            if math.abs(ahead) < 0.5 then F.ahead = F.ahead and (F.ahead * 0.9 + ahead * 0.1) or ahead end
        end
        if active and SP.method == "On ball" then
            local st = tracked[ball]
            if st and st.target == me then spamInstant() end
        end
        if active and (S.autoparry or S.triggerbot) then
            local st = tracked[ball]
            if st and st.target == me then
                local root = apRoot()
                if root then
                    if S.triggerbot then trigger(ball, st, now) else decide(ball, st, root, now, "feed") end
                end
            end
        end
        if now - F.since >= 30 then
            logp(("server ball feed: %.0f msgs/s, ahead of the physics ball by %s (Core.interp %.0fms)"):format(
                F.n / (now - F.since), F.ahead and ("%.0fms"):format(F.ahead * 1000) or "n/a (ball slow)", Core.interp * 1000))
            F.n, F.since = 0, now
        end
    end
    function Parry.feedUrs(n) Core.feed.urs = n end
    function Parry.feedCheck()
        local F = Core.feed
        if F.total == 0 then logp(("server ball feed: no messages on %d unreliable remote(s) yet -- try the game's Settings > Misc > Lag-Ball on"):format(F.urs)) end
    end
    function Parry.onBallAdded(ball)
        task.defer(function()
            if not active or not ball.Parent or not ball:GetAttribute('realBall') then return end
            local st = ballState(ball)
            if st.target == me then onRetarget(ball, st, me, clock_()) end
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
    pcall(function()
        if isfile and isfile("BladeBall/echo.txt") and readfile("BladeBall/echo.txt") == "1" then Core.echo.forged_ok = true end
    end)
    function Parry.onAttempt(who)
        if who ~= nil and who ~= LocalPlayer.Character then return end
        local E, now = Core.echo, clock_()
        E.at, E.seen = now, E.seen + 1
        local aw = Core.await
        if not aw then return end
        Core.await = nil
        local rtt = now - aw.t
        if rtt < 0 or rtt > pingS() * 2.5 + 0.12 then return end
        E.rtt = E.rtt and (E.rtt * 0.7 + rtt * 0.3) or rtt
        Lag.echo = E.rtt
        if aw.cap then aw.cap.taken, aw.cap.refused_row = (aw.cap.taken or 0) + 1, 0 end
        if not E.forged_ok then
            E.forged_ok = true
            logp(("the server answers remote parry attempts (%.0fms round trip): captures are checked on every parry from now on"):format(rtt * 1000))
            pcall(function()
                if makefolder and isfolder and not isfolder("BladeBall") then makefolder("BladeBall") end
                if writefile then writefile("BladeBall/echo.txt", "1") end
            end)
        end
    end
    function Core.refused(aw, now, waited)
        local cap, D = aw.cap, Core.diag
        D.refused = D.refused + 1
        if cap then
            cap.refused, cap.refused_row = (cap.refused or 0) + 1, (cap.refused_row or 0) + 1
            logp(("remote parry NOT taken by the server (no attempt answer in %.0fms): capture #%d, %d taken / %d refused"):format(
                waited * 1000, cap.id or 0, cap.taken or 0, cap.refused))
            if DBG.on then DBG.ev(("NOT TAKEN: no attempt answer in %.0fms"):format(waited * 1000)) end
            if Core.cap == cap then
                local never = (cap.taken or 0) == 0 and (cap.landed or 0) == 0
                if never and cap.alt_key and not cap.alt_tried then
                    cap.key, cap.alt_key, cap.alt_tried, cap.refused_row = cap.alt_key, cap.key, true, 0
                    logp("  trying this capture's second key (the sender's clock ticked before the hook read it)")
                elseif never or cap.refused_row >= 2 then
                    Core.cap, Core.misses = nil, 0
                    logp("  capture dropped: the server isn't taking it -- parry once to take a fresh one")
                    if Parry.onCaptureBad then task.defer(pcall, Parry.onCaptureBad) end
                end
            end
        end
        local st, ball = aw.st, aw.ball
        if st and ball and ball.Parent and st.target == me and not st.landed then
            st.parried, st.parry_until = false, 0
            G.until_t, Core.pending, Core.watch = 0, nil, nil
            if S.rescue_press then st.rescue = true end
            local root = apRoot()
            if root and S.autoparry and not S.triggerbot then decide(ball, st, root, now, "not taken") end
        end
    end
    function Parry.timingLines()
        local D, E, L = Core.diag, Core.echo, {}
        L[#L + 1] = ("parries: %d fired, %d landed, %d early, %d late, %d on time but not counted, %d not taken, %d rescued"):format(
            D.fired, D.landed, D.early, D.late, D.ontime, D.refused, D.rescued)
        if D.bias then
            local b = D.bias * 1000
            L[#L + 1] = ("prediction: the ball lands %+.0fms vs predicted (spread %.0fms, %d parries) -- %s"):format(b, D.spread * 1000, D.n,
                math.abs(b) <= 15 and "on the mark" or (b > 0 and "firing a little early" or "firing a little late"))
        else
            L[#L + 1] = "prediction: no landed parries measured yet"
        end
        L[#L + 1] = ("latency: ping %.0fms (median of 3s), jitter %.0fms, reach %.0fms, parry round trip %s"):format(
            (Lag.avg or 0) * 1000, jitter() * 1000, reachT() * 1000, E.rtt and ("%.0fms"):format(E.rtt * 1000) or "not measured")
        local cap = Core.cap
        L[#L + 1] = cap and ("capture #%d: %d taken, %d refused%s%s"):format(cap.id or 0, cap.taken or 0, cap.refused or 0,
                cap.alt_tried and ", on its second key" or "", E.forged_ok and "" or " (server answers not seen yet: can't be checked)")
            or "capture: none"
        return L
    end
    function Parry.onParrySuccess()
        DBG.ev("our parry LANDED")
        Anim.onSuccess()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.until_t = 0
        local w = Core.watch
        Core.await = nil
        local D = Core.diag
        D.landed = D.landed + 1
        if Core.pending and w then
            if w.cap then w.cap.landed = (w.cap.landed or 0) + 1 end
            local took, note = clock_() - w.t, ""
            if w.eta and w.eta < 5 then
                local err = took - w.ping * 0.5 - w.eta
                if math.abs(err) < 0.5 then
                    D.bias = D.bias and (D.bias * 0.8 + err * 0.2) or err
                    D.spread = D.spread * 0.8 + math.abs(err - D.bias) * 0.2
                    D.n = D.n + 1
                    note = (", ball %+.0fms vs predicted"):format(err * 1000)
                end
            end
            logp(("  -> landed %.2fs after the parry (fired at %.0f studs%s)"):format(took, w.d0, note))
            if D.landed % 10 == 0 then for _, l in ipairs(Parry.timingLines()) do logp("  [timing] " .. l) end end
        end
        local firedBall = w and w.ball
        Core.watch = nil
        Core.pending, Core.misses = nil, 0
        Core.tune = Core.tune * 0.9
        local fst = firedBall and tracked[firedBall]
        if fst and fst.target == me and fst.pass_open and fst.parried then
            fst.landed = true
        else
            for _, st in pairs(tracked) do if st.target == me and st.pass_open and st.parried then st.landed = true end end
        end
        spamInstant()
        if S.autoparry and not S.triggerbot then
            local root = apRoot()
            if root then
                local now = clock_()
                for ball, st in pairs(tracked) do
                    if ball ~= firedBall and st.target == me and ball.Parent and not st.landed then
                        decide(ball, st, root, now, "after a landed parry")
                    end
                end
            end
        end
    end
    function Util.parryAllWho(...)
        local n = select('#', ...)
        for i = 1, n do
            local a = select(i, ...)
            if typeof(a) == 'Instance' and a:IsA('Player') then return a.Name end
        end
        for i = 1, n do
            local a = select(i, ...)
            if typeof(a) == 'Instance' then
                local m = a:IsA('Model') and a or a:FindFirstAncestorOfClass('Model')
                if m and Players:FindFirstChild(m.Name) then return m.Name end
            elseif type(a) == 'string' and Players:FindFirstChild(a) then
                return a
            end
        end
        return nil
    end
    function Parry.onParryAll(...)
        local who, now = Util.parryAllWho(...), clock_()
        parryAll[#parryAll + 1] = { t = now, who = who }
        if #parryAll > 16 then table.remove(parryAll, 1) end
        if who and who ~= me and active then
            local reopened, r, their = false, getRoot(), charRoot(who)
            for ball, st in pairs(tracked) do
                local near = false
                if their and ball.Parent then
                    local spd = ballVel(ball).Magnitude
                    near = (their.Position - Core.ball_now(ball)).Magnitude <= Util.clashRange(spd) + spd * (pingS() + 0.1)
                end
                if r and st.target == me and (st.landed or (st.parried and near)) and ball.Parent then
                    if ballVel(ball):Dot(r.Position - Core.ball_now(ball)) > 0 then
                        Util.openPass(st); reopened = true
                    else
                        st.reopen_until = now + 0.5
                    end
                end
            end
            if reopened then G.until_t = 0 end
            DBG.ev(("parry by %s%s"):format(who, reopened and "  -> ball coming back: new pass opened" or ""))
            if S.fast_retarget and S.autoparry and not S.triggerbot and Util.inMatch() then
                local alive = 0
                for _, m in ipairs(Alive:GetChildren()) do
                    if m:FindFirstChildOfClass("Humanoid") then alive = alive + 1 end
                end
                if alive == 2 then
                    local root = apRoot()
                    if root then
                        for ball, st in pairs(tracked) do
                            if st.target == who and ball.Parent then
                                if not st.pass_open then Util.openPass(st) end
                                DBG.ev(("1v1: %s parried -- taken as the retarget to you"):format(who))
                                Core.fast_retarget(ball, st, root, now)
                            end
                        end
                    end
                end
            end
            if S.autoparry or S.triggerbot then
                local root = apRoot()
                if root then
                    for ball, st in pairs(tracked) do
                        if st.target == me and ball.Parent then
                            if S.triggerbot then trigger(ball, st, now) else decide(ball, st, root, now, "their parry") end
                        end
                    end
                end
            end
        end
        if AutoSpam.ball or SP.manual then spamInstant() end
    end
    function Parry.onNoobParry() task.wait(0.11); G.until_t = 0 end
    function Parry.onM1Stop(v) G.m1, G.m1_at = v and true or false, clock_() end

    function Parry.debugLines()
        local now = clock_()
        local c, R = DBG.counts, DBG.rates
        local span = now - c.since
        if span >= 1 then R.vel, R.feed = c.vel / span, c.feed / span; c.vel, c.feed, c.since = 0, 0, now end
        local L = {}
        L[#L + 1] = ("ping %.0fms (avg %.0f)  jitter %.0fms  reach %.0fms"):format(pingMs(), (Lag.avg or 0) * 1000,
            jitter() * 1000, reachT() * 1000)
        local F = Core.feed
        L[#L + 1] = ("server feed %.0f/s (ahead %s)  velocity updates %.0f/s"):format(R.feed,
            F.ahead and ("%.0fms"):format(F.ahead * 1000) or "-", R.vel)
        local cap = Core.cap
        L[#L + 1] = cap and ("capture: yes, %s"):format(cap.verified and "real hash confirmed" or "hash not confirmed")
            or ("capture: none (hook %s)"):format(Parry.hookState())
        L[#L + 1] = gateOpen() and "parry gate: open" or ("parry gate: locked %.2fs"):format(math.max(G.until_t - now, 0))
        local onMe
        for _, b in ipairs(liveBalls()) do
            local st = tracked[b]
            if st and st.target == me then onMe = st; break end
        end
        L[#L + 1] = onMe and ("ball ON YOU, pass: %s"):format(onMe.landed and "landed" or (onMe.parried and "fired" or "open"))
            or "no ball on you"
        local e = DBG.eval
        if e.t and now - e.t < 1.5 then
            L[#L + 1] = ("check (%s%s): spd %.0f  d %.0f  heading %.2f"):format(e.via, e.feed and ", feed" or "", e.speed, e.dist, e.heading)
            L[#L + 1] = ("  soonest %.2fs  lead %.2fs  reach %.2fs%s%s%s%s"):format(math.min(e.t_min, 9.99), e.lead, e.reach,
                e.fast and ("  curve fast %.2f"):format(math.min(e.fast, 9.99)) or "",
                e.slow and (" slow %.2f"):format(math.min(e.slow, 9.99)) or "",
                e.radial and (" closing %.2f"):format(math.min(e.radial, 9.99)) or "",
                e.k and ("  k %.1f"):format(e.k) or "")
        end
        if DBG.block and now - DBG.block_at < 2 then L[#L + 1] = ("held: %s (%.1fs ago)"):format(DBG.block, now - DBG.block_at) end
        for _, l in ipairs(Parry.timingLines()) do L[#L + 1] = l end
        return L
    end
    function Parry.status()
        local lp, last = Core.last_parry, "none"
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
            armed = Core.cap and ("YES%s -- %d parries taken%s"):format(Core.cap.verified and " (real hash confirmed)" or "",
                    math.max(Core.cap.taken or 0, Core.cap.landed or 0),
                    (Core.cap.refused or 0) > 0 and (", %d refused"):format(Core.cap.refused) or "")
                or (Capture.mode == "Your press" and "NO -- parry once yourself" or "NO -- taking one at the next chance"),
            last = last, clash = clash, manual = manual, rate = SpamMeter.rate, ping = pingMs(),
            target = SP.rate_now(clock_()), speed_mode = SP.speed_mode,
            curve = S.random_curve and "Random each parry" or (Util.CURVE_NAMES[S.curve_mode] or "?"),
            detect = blocked() and "PAUSED (ability detected)" or "clear",
        }
    end

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
        for _, c in ipairs(ballConns) do pcall(function() c:Disconnect() end) end
        ballConns = {}
        for k in pairs(tracked) do tracked[k] = nil end
        Util.endClash("engine off")
        Pump.credit, Pump.on, Pump.waiting = 0, false, false
        if Core.pending then pcall(function() logp(Util.missVerdict(Core.watch) .. " [engine stopped]") end) end
        Core.pending, Core.misses, Core.watch = nil, 0, nil
        G.until_t, Capture.dry, Capture.since = 0, 0, nil
    end
    function Parry.spamParry()
        if not Parry.resolve() then return false end
        if S.parry_mode == "Keypress" and SP.mode == "Keypress" then return pressBlockKey() end
        if Core.cap and send(true) == "sent" then Anim.spamBlock(); return true end
        return keyParry(Core.cap == nil)
    end
    function Parry.rehook()
        pcall(unhook)
        Core.cap, Core.pending, Core.misses = nil, nil, 0
        tokCache.cap = nil
        Capture.dry, Capture.last_press = 0, -math.huge
        Capture.since = canParryNow() and (clock_() - 1) or nil
        logp("rehook: capture dropped -- taking a fresh one at the next safe moment (" .. capMethod() .. ")")
        return active
    end
    function Parry.gameSwing()
        if clock_() - Core.last_send_at < 0.5 then return end
        gateStart()
    end
    function Parry.remotes() return Remotes end
    function Parry.spamRate() return SpamMeter.rate end
    function Parry.isMe(name) return name == me end
end

local Library
local StatusHook, UiTick

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
featureLog = Flight.write

local Engine = { users = {}, conns = {}, watch = {}, running = false, armed = false, status_at = 0, tick_at = 0, sleep_tok = nil }
local function econnect(signal, fn)
    local c = signal:Connect(function(...)
        if not isLive() then return end
        fn(...)
    end)
    Engine.conns[#Engine.conns + 1] = c
end
function Engine.start()
    if not Parry.activate() then
        if Library then Library:Notify({ Title = "Blade Ball", Description = "Couldn't find the game's Remotes / Alive.", Time = 4 }) end
        return false
    end
    Engine.running = true
    local R = Parry.remotes()
    pcall(function() econnect(R.ParrySuccess.OnClientEvent, Parry.onParrySuccess) end)
    pcall(function() econnect(R.ParrySuccessAll.OnClientEvent, Parry.onParryAll) end)
    pcall(function() econnect(R.ParryAttempt.OnClientEvent, function() Parry.onAttempt(nil) end) end)
    pcall(function() econnect(R.ParryAttemptAll.OnClientEvent, function(_, char) if char ~= nil then Parry.onAttempt(char) end end) end)
    pcall(function() econnect(R.NoobParryHappened.OnClientEvent, Parry.onNoobParry) end)
    pcall(function() econnect(R.M1Stop.Event, Parry.onM1Stop) end)
    econnect(UserInputService.InputBegan, Parry.onInput)
    for _, folder in ipairs(Parry.ballFolders()) do econnect(folder.ChildAdded, Parry.onBallAdded) end
    pcall(function()
        local idx = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("_Index")
        local pkg = idx and idx:FindFirstChild("sleitnick_net@0.1.0")
        local net = pkg and pkg:FindFirstChild("net")
        if not net then return end
        local n = 0
        for _, r in ipairs(net:GetChildren()) do
            if r.ClassName == "UnreliableRemoteEvent" then econnect(r.OnClientEvent, Parry.onBallFeed); n = n + 1 end
        end
        Parry.feedUrs(n)
        task.delay(20, function() if Engine.running then pcall(Parry.feedCheck) end end)
    end)
    local function watchAnimator(char)
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if not animator or not Engine.running then return end
            econnect(animator.AnimationPlayed, function(track)
                if Anim.isGamePress(track) then Parry.gameSwing(); pcall(Parry.learnBind) end
            end)
        end)
    end
    if LocalPlayer.Character then watchAnimator(LocalPlayer.Character) end
    econnect(LocalPlayer.CharacterAdded, function(char) Anim.reset(); watchAnimator(char) end)
    econnect(RunService.PreSimulation, function(dt) Parry.frame(dt, 1) end)
    pcall(function() econnect(RunService.PostSimulation, function() Parry.frame(nil, 2) end) end)
    pcall(function() econnect(RunService.PreAnimation, function() Parry.frame(nil, 4) end) end)
    econnect(RunService.Heartbeat, function()
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

local function inPlay()
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
Stagger.round_check = inPlay
do
    task.spawn(function()
        local last = nil
        while isLive() do
            local inr = inPlay()
            if inr ~= last then
                last = inr
                for _, f in pairs(Features) do
                    if f.round_only and (f.want or f.on) then pcall(function() f:setEnabled(f.want) end) end
                end
            end
            task.wait(0.4)
        end
    end)
end
local function wconnect(signal, fn)
    local c = signal:Connect(function(...)
        if not isLive() then return end
        fn(...)
    end)
    Engine.watch[#Engine.watch + 1] = c
end
local function reevaluate()
    if not Engine.armed then return end
    if inPlay() then
        Engine.sleep_tok = nil
        if not Engine.running then
            if Engine.start() then Flight.write("engine AWAKE (in a round / training / lobby parry)") end
        end
    elseif Engine.running and not Engine.sleep_tok then
        local tok = {}
        Engine.sleep_tok = tok
        task.delay(1.5, function()
            if Engine.sleep_tok ~= tok then return end
            Engine.sleep_tok = nil
            if Engine.armed and Engine.running and not inPlay() then
                Engine.stop()
                Flight.write("engine ASLEEP (lobby) -- no loops, no remote listeners; hook: " .. Parry.hookState())
            end
        end)
    end
end
function Engine.arm()
    if Engine.armed then return end
    Engine.armed = true
    local tok = {}
    Engine.poll_tok = tok
    task.spawn(function()
        while Engine.armed and Engine.poll_tok == tok and isLive() do
            pcall(reevaluate)
            task.wait(0.4)
        end
    end)
    Flight.write("parry/spam feature on -- engine " .. (inPlay() and "waking" or "asleep until a round"))
    reevaluate()
    if not Engine.running and StatusHook then pcall(StatusHook, nil, true) end
end
function Engine.disarm()
    if not Engine.armed then return end
    Engine.armed, Engine.sleep_tok, Engine.poll_tok = false, nil, nil
    for _, c in ipairs(Engine.watch) do pcall(function() c:Disconnect() end) end
    Engine.watch = {}
    if Engine.running then Engine.stop() end
    if StatusHook then pcall(StatusHook, nil, false) end
    Flight.write("all parry/spam features off -- engine off; hook: " .. Parry.hookState())
end
Engine.pending = {}
function Engine.want(name, on)
    Engine.pending[name] = on and true or false
    if on and Stagger.active() then
        Stagger.push("engine:" .. name, name, function() Engine.want_now(name, Engine.pending[name]) end)
        return
    end
    Engine.want_now(name, on)
end
function Engine.want_now(name, on)
    if (Engine.users[name] ~= nil) ~= (on and true or false) then Flight.write(("%s %s"):format(name, on and "ON" or "OFF")) end
    Engine.users[name] = on and true or nil
    if next(Engine.users) ~= nil then Engine.arm() else Engine.disarm() end
end

do
    local exec = "?"
    pcall(function() exec = table.concat({ identifyexecutor() }, " ") end)
    Flight.write(("loaded | executor %s | place %s"):format(exec, tostring(game.PlaceId)))
    if Stagger.delay > 0 then
        Flight.write(("load stagger: config features start %ds after load, %ds apart (getgenv().BBStagger = seconds, 0 = off)"):format(Stagger.delay, Stagger.gap))
    end
    pcall(function()
        local GuiService = cloneref(game:GetService("GuiService"))
        Flight.kick_conn = GuiService.ErrorMessageChanged:Connect(function(msg)
            if not isLive() then return end
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

if getgenv().BBStop == 1 then Flight.write("BBStop 1: stopped after the core (no UI)"); return end

local Orb = {}
do
    local SP, TweenService = Parry.SP, cloneref(game:GetService("TweenService"))
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
    local pressInput, pressPos, startAbs = nil, nil, nil
    local pressConns, painted, lastRate = {}, nil, 0
    local function tween(obj, props, t)
        TweenService:Create(obj, TweenInfo.new(t or 0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
    end
    local function corner(obj, r) local c = Instance.new("UICorner"); c.CornerRadius = r or UDim.new(1, 0); c.Parent = obj; return c end
    local function setSpam(on) SP.manual = on and true or false end
    local function dropPress()
        for _, c in ipairs(pressConns) do pcall(function() c:Disconnect() end) end
        pressConns = {}
    end
    local function paint(rate)
        if not track then return end
        if rate then lastRate = rate end
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
        else sub.Text, sub.TextColor3 = (math.floor(lastRate + 0.5) .. "/s"), C.g1 end
        if state == "on" then grad.Offset = Vector2.new(math.sin(clock_() * 3) * 0.3, 0) end
    end
    function Orb.tick(rate) paint(rate) end
    local function releasePress()
        pressing = false
        dropPress()
        if dragging then dragging = false
        else
            setSpam(not SP.manual)
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
            pressInput, pressPos = input, input.Position
            startAbs = root.AbsolutePosition + root.AbsoluteSize * 0.5
            pressConns[#pressConns + 1] = UserInputService.InputChanged:Connect(function(i)
                if not pressing then return end
                if i ~= pressInput and i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                local d = i.Position - pressPos
                if not dragging and Vector2.new(d.X, d.Y).Magnitude > 14 then dragging = true end
                if dragging then root.Position = UDim2.fromOffset(startAbs.X + d.X, startAbs.Y + d.Y) end
            end)
            pressConns[#pressConns + 1] = UserInputService.InputEnded:Connect(function(i)
                if not pressing then return end
                if i == pressInput or i.UserInputType == Enum.UserInputType.MouseButton1 then releasePress() end
            end)
        end)
        hideGui(gui)
        painted = nil
        paint()
    end
    function Orb.hide()
        dropPress()
        pressing, dragging = false, false
        setSpam(false)
        if gui then pcall(function() gui:Destroy() end) end
        gui, root, track = nil, nil, nil
        painted = nil
    end
end

do
    local fn = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))
    local function quiet(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
        pcall(Flight.write, "ui (kept off the console): " .. table.concat(t, " "))
    end
    pcall(function() setfenv(fn, setmetatable({ warn = quiet, print = quiet }, { __index = getfenv(fn) })) end)
    Library = fn()
end
if getgenv().BBStop == 2 then Flight.write("BBStop 2: stopped after loading the menu library (no window)"); return end
local Options, Toggles = Library.Options, Library.Toggles
local S, SP, Det = Parry.S, Parry.SP, Parry.Det
local function Notify(title, text, time) pcall(function() Library:Notify({ Title = title, Description = text, Time = time or 3 }) end) end

Gui.Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "version: " .. SCRIPT_VERSION,
    Icon = "swords",
    Center = true,
    AutoShow = true,
    Resizable = true,
    ToggleKeybind = Enum.KeyCode.LeftControl,
})

Gui.Tabs = {
    Parry = Gui.Window:AddTab("Auto Parry", "swords", "Auto parry, triggerbot, curves, abilities"),
    Detection = Gui.Window:AddTab("Detection", "shield-alert", "Pause parrying during enemy abilities"),
    Spam = Gui.Window:AddTab("Spam", "zap", "Manual and auto spam"),
    Player = Gui.Window:AddTab("Player", "user", "Avatar, cosmetics, movement"),
    Visuals = Gui.Window:AddTab("Visuals", "eye", "Overlays and ESP"),
    Orbit = Gui.Window:AddTab("Orbit", "orbit", "Circle a point you can walk, or the ball"),
    Misc = Gui.Window:AddTab("Misc", "wrench", "Skin changer and extras"),
    Debug = Gui.Window:AddTab("Debug", "bug", "On-screen debug overlay"),
}

Gui.AP = Gui.Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
Gui.AP:AddToggle("AutoParry", {
    Text = "Auto parry", Default = false,
    Tooltip = "Parries every ball sent at you, curves included, at the Accuracy you set.",
    Callback = function(v) S.autoparry = v; Engine.want("autoparry", v) end,
}):AddKeyPicker("AutoParryKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry" })
Gui.AP:AddToggle("Triggerbot", {
    Text = "Triggerbot", Default = false,
    Tooltip = "Parries the instant the ball turns to you, at any distance. Overrides auto parry's timing while on.",
    Callback = function(v) S.triggerbot = v; Engine.want("triggerbot", v) end,
}):AddKeyPicker("TriggerbotKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Triggerbot" })
Gui.AP:AddDropdown("ParryMode", {
    Values = { "Remote", "Keypress" }, Default = "Remote", Text = "Parry mode",
    Tooltip = "Remote: the captured parry, forged (curve and target options work). Keypress: presses block.",
    Callback = function(v) S.parry_mode = v end,
})
Gui.AP:AddToggle("ParryAnimation", {
    Text = "Parry animation", Default = true,
    Tooltip = "Plays your sword's block swing on remote parries.",
    Callback = function(v) Anim.enabled = v end,
})
Gui.AP:AddToggle("UnlockFPS", {
    Text = "Unlock FPS", Default = true,
    Tooltip = "Frame cap 240: auto parry checks the ball 4 times a frame, so more frames = more checks.",
    Callback = function(v)
        local function apply() pcall(function() if type(setfpscap) == "function" then setfpscap(v and 240 or 60) end end) end
        if v and Stagger.active() then Stagger.push("fps", "Unlock FPS", apply) else apply() end
    end,
})

Gui.APS = Gui.Tabs.Parry:AddRightGroupbox("Timing", "sliders-horizontal")
Gui.APS:AddSlider("Accuracy", {
    Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "How close the ball gets before the parry: 100 = ~5 studs ahead, 1 = ~35 studs ahead, straight in between (50 = ~20 studs), and never less than a little time on fast balls (up to 0.12s at 1) so fast balls don't become perfect parries. Never past the parry window. Curves follow it too.",
    Callback = function(v) S.accuracy_base = v; Parry.roll() end,
})
Gui.APS:AddToggle("RandomAccuracy", { Text = "Randomize accuracy", Default = false, Callback = function(v) S.random_accuracy = v end })
Gui.APS:AddSlider("RandomAccuracyAmount", {
    Text = "Randomize amount", Default = 10, Min = 0, Max = 50, Rounding = 0, Suffix = " +/-",
    Callback = function(v) S.random_accuracy_amount = v end,
})
Gui.APS:AddToggle("HardCurveGuard", {
    Text = "Hard curve guard", Default = false,
    Tooltip = "Treats every curve as the hardest turn possible for the must-fire check. Saves sudden whip-ins; downside: can parry curve-bait balls early.",
    Callback = function(v) S.hard_curve = v end,
})
Gui.APS:AddToggle("SelfTune", {
    Text = "Self-tune timing", Default = false,
    Tooltip = "Each EARLY / LATE miss nudges the fire time the other way (max 15ms a step, +/-40ms total); landed parries ease it back. Downside: a few odd misses can pull it off for a while.",
    Callback = function(v) S.self_tune = v; if not v then Parry.resetTune() end end,
})

Gui.AIM = Gui.Tabs.Parry:AddRightGroupbox("Aim & Curve", "spline")
Gui.AIM:AddDropdown("TargetMode", {
    Values = Parry.targetNames, Default = "Cursor", Text = "Target mode",
    Callback = function(v) Parry.setTargetMode(v) end,
})
Gui.AIM:AddDropdown("TargetMethod", {
    Values = { "Angle", "Ray distance", "Weighted", "Screen" }, Default = "Angle", Text = "Aim method (Camera / Cursor)",
    Tooltip = "How Camera and Cursor pick who you're aiming at. Angle: smallest angle off your view (best all-round). Ray distance: whoever your aim line passes closest to, in studs. Weighted: angle, leaning toward nearer players (crowds). Screen: pixel distance on screen (the old way).",
    Callback = function(v) S.target_method = v end,
})
Gui.AIM:AddDropdown("CurveMode", {
    Values = Parry.curveNames, Default = "Camera", Text = "Curve mode", Searchable = true,
    Tooltip = "The direction sent with every parry (auto parry, triggerbot and spam).",
    Callback = function(v) Parry.setCurveMode(v) end,
})
Gui.AIM:AddToggle("RandomCurve", { Text = "Random curve each parry", Default = false, Callback = function(v) S.random_curve = v end })
function Mods.cycleCurve(dir)
    local names = Parry.curveNames
    local idx = (S.curve_mode - 1 + dir) % #names + 1
    pcall(function() Options.CurveMode:SetValue(names[idx]) end)
    Notify("Curve", names[idx], 1)
end
Gui.AIM:AddLabel("Next curve"):AddKeyPicker("NextCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Next curve", Callback = function() Mods.cycleCurve(1) end,
})
Gui.AIM:AddLabel("Previous curve"):AddKeyPicker("PrevCurveKey", {
    Default = "None", Mode = "Toggle", Text = "Previous curve", Callback = function() Mods.cycleCurve(-1) end,
})

Gui.CAP = Gui.Tabs.Parry:AddLeftGroupbox("Capture", "key-round")
Gui.CapLabel = Gui.CAP:AddLabel("Capture: off (turn on auto parry or spam)", true)
Gui.CAP:AddLabel("Parry once yourself: the hook reads that real parry (the real hash only, never the game's decoys) and auto parry takes over. A notification says when it has it.", true)
Gui.CAP:AddToggle("OneParryCapture", {
    Text = "One-parry capture", Default = true,
    Tooltip = "Catches your first parry every time: also hooks FireServer while there's no capture (the game sends half its parries that way). That path only takes the game's real hash. Off = namecall only, which can take a few parries.",
    Callback = function(v) S.one_parry_capture = v end,
})
Gui.CAP:AddToggle("RescuePress", {
    Text = "Rescue press", Default = true,
    Tooltip = "When the server doesn't answer a remote parry (a bad capture: the swing plays, nothing is parried), that ball is parried with a real F press instead, and a dropped capture is retaken on that press.",
    Callback = function(v) S.rescue_press = v end,
})
Gui.CAPTURE_MODES = { ["Your press"] = "Your press", ["Auto parry"] = "Auto parry", ["Spam"] = "Spam", ["Safe press"] = "Auto press" }
Gui.CAP:AddDropdown("AutoCaptureMode", {
    Values = { "Your press", "Auto parry", "Spam", "Safe press" }, Default = "Your press", Text = "Auto capture",
    Tooltip = "Your press: parry once yourself. Auto parry: auto parry presses F itself (a real parry) until the remote is read. Spam: presses F every 0.1s in a round / training until it's read. Safe press: one press when no ball is near. Presses use keypress (F), only while Roblox is focused.",
    Callback = function(v) Parry.Capture.mode = Gui.CAPTURE_MODES[v] or "Your press" end,
})
Parry.onCaptureBad = function()
    Notify("Capture dropped", "The server wasn't taking its parries. Parry once to take a fresh one.", 5)
end
Parry.onCapture = function(cap)
    Notify("Parry remote captured", cap.verified and "Real parry hash confirmed -- auto parry is armed."
        or "Captured (couldn't read the game's real hash to confirm it).", 4)
end
Gui.CAP:AddButton({
    Text = "Rehook",
    Tooltip = "Drop the capture and take a fresh one. Use it if parries stop landing.",
    Func = function()
        if Parry.rehook() then
            Notify("Rehook", "Capture dropped -- taking a fresh one.", 3)
        else
            Notify("Rehook", "Capture dropped. Turn on Auto parry or spam to take a fresh one.", 4)
        end
    end,
})

Gui.PP = Gui.Tabs.Parry:AddLeftGroupbox("Pre-parry", "fast-forward")
Gui.PP:AddToggle("PreParry", {
    Text = "Pre-parry", Default = false,
    Tooltip = "Ball on a player right next to you whose return would beat your reaction: parry ahead of it.",
    Callback = function(v) S.preparry = v end,
})
Gui.PP:AddSlider("PreParryRange", {
    Text = "Pre-parry range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Callback = function(v) S.preparry_range = v end,
})
Gui.PP:AddToggle("HighPingPreParry", {
    Text = "Auto pre-parry at high ping", Default = false,
    Tooltip = "Pre-parry turns itself on while your ping is 80ms or more.",
    Callback = function(v) S.hp_preparry = v end,
})

Gui.AB = Gui.Tabs.Parry:AddLeftGroupbox("Abilities", "sparkles")
Gui.AB:AddToggle("AutoAbility", {
    Text = "Auto ability", Default = false,
    Tooltip = "Parry with your ability when it's ready and is a parry ability (Raging/Calming Deflection, Rapture, Aerodynamic Slash, Fracture, Death Slash).",
    Callback = function(v) S.auto_ability = v end,
})
Gui.AB:AddToggle("CooldownProtection", {
    Text = "Cooldown protection", Default = false,
    Tooltip = "Use Raging/Calming Deflection or Rapture as the parry when they're ready.",
    Callback = function(v) S.cooldown_protection = v end,
})

local function getRemotes() return ReplicatedStorage:FindFirstChild("Remotes") end

Mods.DetInfinity = Feature("DetInfinity")
Mods.DetInfinity.round_only = true
function Mods.DetInfinity.start()
    local R = getRemotes()
    if R and R:FindFirstChild("InfinityBall") then
        Mods.DetInfinity:connect(R.InfinityBall.OnClientEvent, function(ball, on)
            if typeof(ball) == "Instance" then Det.inf[ball] = on and (clock_() + 15) or nil end
        end)
    end
end
function Mods.DetInfinity.stop() table.clear(Det.inf) end

Mods.DetDeathSlash = Feature("DetDeathSlash")
Mods.DetDeathSlash.round_only = true
function Mods.DetDeathSlash.start()
    local R = getRemotes()
    if R and R:FindFirstChild("DeathBall") then
        Mods.DetDeathSlash:connect(R.DeathBall.OnClientEvent, function(ball, on)
            if typeof(ball) == "Instance" then Det.death[ball] = on and (clock_() + 8) or nil end
        end)
    end
end
function Mods.DetDeathSlash.stop() table.clear(Det.death) end

Mods.DetTimeHole = Feature("DetTimeHole")
Mods.DetTimeHole.round_only = true
function Mods.DetTimeHole.start()
    Det.timehole_on = true
    local R = getRemotes()
    if R and R:FindFirstChild("TimeHoleHoldBall") then
        Mods.DetTimeHole:connect(R.TimeHoleHoldBall.OnClientEvent, function(ball, on)
            if typeof(ball) == "Instance" then Det.th_hold[ball] = on and (clock_() + 15) or nil end
        end)
    end
end
function Mods.DetTimeHole.stop() Det.timehole_on = false; table.clear(Det.th_hold) end

Mods.Slashes = { delay = 0.05, max = 36, count = 0, looping = false }
Mods.DetSlashes = Feature("DetSlashes")
Mods.DetSlashes.round_only = true
function Mods.runSlashes()
    if Mods.Slashes.looping or not Det.slashes then return end
    Mods.Slashes.looping = true
    local token = Mods.DetSlashes._token
    task.spawn(function()
        local sent = 0
        while Mods.DetSlashes:alive(token) and Det.slashes and sent < Mods.Slashes.max and LocalPlayer.Character do
            Parry.spamParry()
            sent = sent + 1
            task.wait(Mods.Slashes.delay)
        end
        Mods.Slashes.looping = false
    end)
end
function Mods.watchFury(char)
    if not char then return end
    local function update()
        local on = char:GetAttribute("FuryCatch") and true or false
        if on and not Det.slashes then Det.slashes, Mods.Slashes.count = true, 0; Mods.runSlashes()
        elseif not on then Det.slashes = false end
    end
    Mods.DetSlashes:connect(char:GetAttributeChangedSignal("FuryCatch"), update)
    update()
end
function Mods.DetSlashes.start()
    Mods.watchFury(LocalPlayer.Character)
    Mods.DetSlashes:connect(LocalPlayer.CharacterAdded, function(char) Det.slashes = false; Mods.watchFury(char) end)
end
function Mods.DetSlashes.stop() Det.slashes, Mods.Slashes.count, Mods.Slashes.looping = false, 0, false end

Mods.DetPhantom = Feature("DetPhantom")
Mods.DetPhantom.round_only = true
function Mods.DetPhantom.start()
    local runtime = Workspace:FindFirstChild("Runtime")
    if not runtime then return end
    Mods.DetPhantom:connect(runtime.ChildAdded, function(obj)
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
function Mods.DetPhantom.stop() Det.phantom_until = 0 end

local DL = Gui.Tabs.Detection:AddLeftGroupbox("Abilities", "shield-alert")
DL:AddToggle("DetInfinity", { Text = "Infinity detection", Default = false, Callback = function(v) Mods.DetInfinity:setEnabled(v) end })
DL:AddToggle("DetDeathSlash", { Text = "Death Slash detection", Default = false, Callback = function(v) Mods.DetDeathSlash:setEnabled(v) end })
DL:AddToggle("DetTimeHole", { Text = "Time Hole detection", Default = false, Callback = function(v) Mods.DetTimeHole:setEnabled(v) end })
DL:AddToggle("DetPhantom", { Text = "Anti-Phantom [BETA]", Default = false, Callback = function(v) Mods.DetPhantom:setEnabled(v) end })
Gui.DR = Gui.Tabs.Detection:AddRightGroupbox("Slashes Of Fury", "swords")
Gui.DR:AddToggle("DetSlashes", { Text = "Slashes detection", Default = false, Callback = function(v) Mods.DetSlashes:setEnabled(v) end })
Gui.DR:AddSlider("SlashesDelay", { Text = "Parry delay", Default = 0.05, Min = 0.05, Max = 0.25, Rounding = 2, Suffix = "s", Callback = function(v) Mods.Slashes.delay = v end })
Gui.DR:AddSlider("SlashesMax", { Text = "Max parry count", Default = 36, Min = 1, Max = 100, Rounding = 0, Callback = function(v) Mods.Slashes.max = v end })

Gui.MS = Gui.Tabs.Spam:AddLeftGroupbox("Manual Spam", "zap")
Gui.MS:AddToggle("ManualSpam", {
    Text = touchUI and "Manual spam (show switch)" or "Manual spam", Default = false,
    Tooltip = touchUI and "Shows the spam switch: tap it to turn spam on/off, drag to move it."
        or "Press the key (E by default) to turn spam on, press again to turn it off.",
    Callback = function(v)
        if touchUI then
            if v then Orb.show() else Orb.hide() end
        else
            SP.manual = v
        end
        Engine.want("manualspam", v)
    end,
}):AddKeyPicker("ManualSpamKey", { Default = "E", Mode = "Toggle", SyncToggleState = not touchUI, Text = "Manual spam" })
Gui.MS:AddToggle("SpamAnimation", {
    Text = "Spam animation", Default = true,
    Tooltip = "Plays the block swing with spam the way a real held key looks: block, success swing, block -- never restarted every parry.",
    Callback = function(v) Anim.spam = v end,
})
Gui.MS:AddToggle("SmartStop", {
    Text = "Smart stop", Default = true,
    Tooltip = "Only spams while a ball is on you, close to you, or heading at you -- stops by itself the rest of the time.",
    Callback = function(v) SP.smart = v end,
})
Gui.MS:AddDropdown("SpamMode", {
    Values = { "Remote", "Keypress" }, Default = "Remote", Text = "Mode",
    Callback = function(v) SP.mode = v end,
})
Gui.MS:AddDropdown("SpamMethod", {
    Values = { "Fixed rate", "Per frame", "Ping adaptive", "On ball" }, Default = "Fixed rate", Text = "Method",
    Tooltip = "Fixed rate: exactly the Speed. Per frame: one a frame (your FPS). Ping adaptive: the Speed, capped at 12 per round trip so high ping doesn't clog. On ball: the Speed only while a ball is on you, plus one instantly on each server update of it.",
    Callback = function(v) SP.method = v end,
})
Gui.SPAM_SPEEDS = {}
for r = 50, 1000, 50 do Gui.SPAM_SPEEDS[#Gui.SPAM_SPEEDS + 1] = r .. "/s" end
Gui.MS:AddDropdown("SpamSpeed", {
    Values = Gui.SPAM_SPEEDS, Default = "700/s", Text = "Speed",
    Tooltip = "Parries a second for manual and auto spam, held exactly at this rate at any FPS.",
    Callback = function(v) SP.speed_mode = v end,
})
Gui.MS:AddToggle("SpamPerFrame", {
    Text = "Per frame", Default = false,
    Tooltip = "Fire a set number of parries every frame (your FPS x Count a second) instead of the timing below.",
    Callback = function(v) SP.per_frame = v end,
})
Gui.MS:AddSlider("SpamPerFrameCount", {
    Text = "Per frame count", Default = 1, Min = 1, Max = 20, Rounding = 0,
    Tooltip = "Parries each frame while Per frame is on.",
    Callback = function(v) SP.per_frame_count = v end,
})
Gui.MS:AddDropdown("SpamTiming", {
    Values = { "Per second", "Every X ms" }, Default = "Per second", Text = "Timing",
    Tooltip = "Per second: the Speed above. Every X ms: one parry every Interval ms. Ignored while Per frame is on.",
    Callback = function(v) SP.timing = v end,
})
Gui.MS:AddInput("SpamIntervalMs", {
    Text = "Interval (ms)", Default = "2", Numeric = true, Finished = true, Placeholder = "e.g. 2",
    Tooltip = "Milliseconds between parries for Every X ms (0.5 - 1000). 2 ms = 500/s, 1 ms = 1000/s.",
    Callback = function(v)
        local n = tonumber(v)
        if n then SP.interval_ms = math.clamp(n, 0.5, 1000) end
    end,
})
Gui.MS:AddToggle("SpamHighSpeedFix", {
    Text = "High speed fix", Default = false,
    Tooltip = "Very fast balls are decided in server ticks (~60 a second): more than a couple of parries per tick just queue. While the ball is at least High speed at, every spam mode is paced to Sends per tick x 60/s, evenly, so every tick still gets one.",
    Callback = function(v) SP.hs_fix = v end,
})
Gui.MS:AddSlider("SpamHighSpeedAt", {
    Text = "High speed at", Default = 400, Min = 150, Max = 1500, Rounding = 0, Suffix = " sps",
    Callback = function(v) SP.hs_speed = v end,
})
Gui.MS:AddSlider("SpamHighSpeedPerTick", {
    Text = "Sends per tick", Default = 2, Min = 1, Max = 6, Rounding = 0,
    Tooltip = "Parries per server tick while the high speed fix is pacing (2 = 120/s).",
    Callback = function(v) SP.hs_per_tick = v end,
})
Gui.SpamRateLabel = Gui.MS:AddLabel("Actual: 0/s", true)

Gui.AS = Gui.Tabs.Spam:AddRightGroupbox("Auto Spam", "activity")
Gui.AS:AddToggle("AutoSpam", {
    Text = "Auto spam", Default = false,
    Tooltip = "Spams through clashes and stops the moment the exchange is over.",
    Callback = function(v) SP.auto = v; Engine.want("autospam", v) end,
}):AddKeyPicker("AutoSpamKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto spam" })
Gui.AS:AddToggle("PredictiveClash", {
    Text = "Predictive start", Default = true,
    Tooltip = "Start as you send the ball to a close player whose return would be too fast to react to.",
    Callback = function(v) SP.predictive = v end,
})
Gui.AS:AddSlider("ClashSensitivity", {
    Text = "Sensitivity", Default = 1.3, Min = 0.6, Max = 2.5, Rounding = 2,
    Tooltip = "Higher = calls a clash sooner. Lower = only very fast exchanges.",
    Callback = function(v) SP.sensitivity = v end,
})
Gui.AS:AddSlider("ClashRangeBonus", {
    Text = "Clash range", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Callback = function(v) SP.range_bonus = v end,
})
Gui.AS:AddSlider("ClashHold", {
    Text = "Hold", Default = 0.15, Min = 0, Max = 0.5, Rounding = 2, Suffix = "s",
    Tooltip = "Keeps spamming this long once the clash fades (hard stops still end it at once).",
    Callback = function(v) SP.hold = v end,
})
Gui.ClashLabel = Gui.AS:AddLabel("Status: off", true)

Mods.Avatar = { target = "", original = nil }
Mods.AvatarChanger = Feature("AvatarChanger")
do
    local function strip(char)
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants")
                or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
    end
    local function saveOrig()
        if Mods.Avatar.original then return end
        local char = LocalPlayer.Character; if not char then return end
        local o, head = { Accessories = {}, CharacterMeshes = {} }, char:FindFirstChild("Head")
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
        Mods.Avatar.original = o
    end
    local function restore()
        local char, o = LocalPlayer.Character, Mods.Avatar.original
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
    local function resolveId(value)
        if value == nil or value == "" then return nil end
        local id = tonumber(value); if id then return id end
        local ok, r = pcall(function() return Players:GetUserIdFromNameAsync(value) end)
        return ok and r or nil
    end
    function Mods.AvatarChanger.start()
        local token = Mods.AvatarChanger._token
        task.spawn(function()
            local id = resolveId(Mods.Avatar.target)
            if not Mods.AvatarChanger:alive(token) then return end
            if not id then Notify("Avatar Changer", "Invalid username or id", 3); return end
            saveOrig()
            if apply(id) then Notify("Avatar Changer", "Appearance changed", 3) end
            Mods.AvatarChanger:connect(LocalPlayer.CharacterAdded, function()
                task.wait(1)
                if Mods.AvatarChanger:alive(token) then apply(id) end
            end)
        end)
    end
    function Mods.AvatarChanger.stop() restore() end
end

Gui.AVC = Gui.Tabs.Player:AddLeftGroupbox("Avatar Changer", "user")
Gui.AVC:AddInput("AvatarTarget", { Text = "Target", Placeholder = "Username or user id", Default = "", Finished = true,
    Callback = function(t) Mods.Avatar.target = t end })
Gui.AVC:AddToggle("AvatarChanger", { Text = "Avatar changer", Default = false, Callback = function(v) Mods.AvatarChanger:setEnabled(v) end })

Mods.headlessOrig = setmetatable({}, { __mode = "k" })
function Mods.setHeadless(char, on)
    local head = char and char:FindFirstChild("Head"); if not head then return end
    head.Transparency = on and 1 or 0
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = on and 1 or 0
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            if on and Mods.headlessOrig[child] == nil then
                Mods.headlessOrig[child] = child.Scale; child.Scale = Vector3.new(0, 0, 0)
            elseif not on and Mods.headlessOrig[child] ~= nil then
                child.Scale = Mods.headlessOrig[child]; Mods.headlessOrig[child] = nil
            end
        end
    end
end
Mods.korbloxMesh = setmetatable({}, { __mode = "k" })
function Mods.setKorblox(char, on)
    local leg = char and char:FindFirstChild("Right Leg"); if not leg then return end
    if on then
        local mine = Mods.korbloxMesh[leg]
        if mine and mine.Parent == leg then return end
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
        local m = Instance.new("SpecialMesh"); m.Name = "Mesh"; Mods.korbloxMesh[leg] = m
        m.MeshId = "rbxassetid://902942096"; m.TextureId = "rbxassetid://902843398"
        m.Offset = Vector3.new(0, 0.7, 0); m.Parent = leg
    else
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
    end
end
Mods.Headless = Feature("Headless")
function Mods.Headless.start()
    pcall(Mods.setHeadless, LocalPlayer.Character, true)
    Mods.Headless:connect(LocalPlayer.CharacterAdded, function(c) task.wait(0.5); if Mods.Headless.on then pcall(Mods.setHeadless, c, true) end end)
end
function Mods.Headless.stop() pcall(Mods.setHeadless, LocalPlayer.Character, false) end
Mods.Korblox = Feature("Korblox")
function Mods.Korblox.start()
    pcall(Mods.setKorblox, LocalPlayer.Character, true)
    Mods.Korblox:connect(LocalPlayer.CharacterAdded, function(c) task.wait(0.5); if Mods.Korblox.on then pcall(Mods.setKorblox, c, true) end end)
end
function Mods.Korblox.stop() pcall(Mods.setKorblox, LocalPlayer.Character, false) end

Gui.HK = Gui.Tabs.Player:AddRightGroupbox("Cosmetics", "shirt")
Gui.HK:AddToggle("Headless", { Text = "Headless", Default = false, Callback = function(v) Mods.Headless:setEnabled(v) end })
Gui.HK:AddToggle("Korblox", { Text = "Korblox", Default = false, Callback = function(v) Mods.Korblox:setEnabled(v) end })

Mods.AutoJump = Feature("AutoJump")
Mods.AutoJump.round_only = true
do
    local lastGrounded = false
    function Mods.AutoJump.start()
        lastGrounded = false
        Mods.AutoJump:connect(RunService.Heartbeat, function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then return end
            local grounded = hum.FloorMaterial ~= Enum.Material.Air
            if grounded and not lastGrounded then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            lastGrounded = grounded
        end)
    end
end
Gui.MV = Gui.Tabs.Player:AddRightGroupbox("Movement", "footprints")
Gui.MV:AddToggle("AutoJump", {
    Text = "Auto jump", Default = false,
    Callback = function(v) Mods.AutoJump:setEnabled(v) end,
}):AddKeyPicker("AutoJumpKey", { Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump" })

Mods.OrbitCfg = { Center = "Yourself", Shape = "Circle", Radius = 8, Speed = 0.5, Clockwise = false, Height = 0,
    Walk = 1, Face = false, Bob = false, BobAmp = 25, BobMode = "Range", BobRange = 30 }
function Mods.orbitCtx()
    local char = LocalPlayer.Character
    if not char or not char.Parent then return nil end
    local alive = Workspace:FindFirstChild("Alive")
    if alive and char.Parent == alive then return "match" end
    if LocalPlayer:GetAttribute("LobbyTraining") then
        local dead = Workspace:FindFirstChild("Dead")
        if dead and char.Parent == dead then return "training" end
    end
    return nil
end
function Mods.orbitBall(ctx)
    local folder = Workspace:FindFirstChild(ctx == "training" and "TrainingBalls" or "Balls")
    if not folder then return nil end
    local first
    for _, b in ipairs(folder:GetChildren()) do
        if b:IsA("BasePart") and (ctx == "training" or b:GetAttribute("realBall")) then
            if b:GetAttribute("target") == LocalPlayer.Name then return b end
            first = first or b
        end
    end
    return first
end
function Mods.shapePt(shape, t)
    if shape == "Ellipse" then return math.cos(t), math.sin(t) * 0.5 end
    if shape == "Figure 8" then return math.sin(t), math.sin(t) * math.cos(t) end
    if shape == "Flower" then local r = math.cos(3 * t); return r * math.cos(t), r * math.sin(t) end
    local n, inner
    if shape == "Triangle" then n = 3 elseif shape == "Square" then n = 4 elseif shape == "Hexagon" then n = 6
    elseif shape == "Star" then n, inner = 10, 0.45 else return math.cos(t), math.sin(t) end
    local u = (t / (2 * math.pi)) * n
    local i0 = math.floor(u)
    local f = u - i0
    local function vert(k)
        local a, r = 2 * math.pi * (k % n) / n - math.pi / 2, (inner and k % 2 == 1) and inner or 1
        return math.cos(a) * r, math.sin(a) * r
    end
    local x1, z1 = vert(i0)
    local x2, z2 = vert(i0 + 1)
    return x1 + (x2 - x1) * f, z1 + (z2 - z1) * f
end
Mods.Bob = { flip = false, base = nil, last = nil, avoid_p = nil }
function Mods.Bob.vel(b)
    local z = b:FindFirstChild("zoomies")
    return z and z.VectorVelocity or b.AssemblyLinearVelocity
end
function Mods.Bob.dodge(ctx, home, dt)
    local b = Mods.orbitBall(ctx)
    if not b or b:GetAttribute("target") ~= LocalPlayer.Name then return nil end
    local v = Mods.Bob.vel(b)
    local speed, to = v.Magnitude, home - b.Position
    local dist, step = to.Magnitude, speed * math.max(dt, 1 / 60)
    if dist > 15 + speed * 0.35 then return nil end
    local range = math.max(Mods.OrbitCfg.BobRange, step * 1.5 + 6)
    local dir = speed > 1 and v / speed or (dist > 0.01 and -to / dist or Vector3.yAxis)
    local off = to - dir * to:Dot(dir)
    if off.Magnitude < 0.5 then
        off = dir:Cross(Vector3.yAxis)
        if off.Magnitude < 0.5 then off = Vector3.xAxis end
    end
    local n = off.Unit
    if n.Y < 0 then n = Vector3.new(n.X, -n.Y, n.Z) end
    if dist > 0.01 then n = (n + (to / dist) * 0.25).Unit end
    return n * range, dist <= step * 3 + 10
end
function Mods.Bob.delta(ctx, home, dt)
    if not Mods.OrbitCfg.Bob then Mods.Bob.flip = false; return Vector3.zero end
    Mods.Bob.flip = not Mods.Bob.flip
    if Mods.OrbitCfg.BobMode ~= "Range" then return Mods.Bob.flip and Vector3.new(0, Mods.OrbitCfg.BobAmp, 0) or Vector3.zero end
    local d, close = Mods.Bob.dodge(ctx, home, dt)
    if not d then return Mods.Bob.flip and Vector3.new(0, Mods.OrbitCfg.BobRange, 0) or Vector3.zero end
    return (Mods.Bob.flip or close) and d or Vector3.zero
end
function Mods.Bob.avoid(ctx, anchor, r)
    local b = Mods.orbitBall(ctx)
    if not b then Mods.Bob.avoid_p = nil; return anchor end
    local bp, v = b.Position, Mods.Bob.vel(b)
    local function score(p)
        local s = math.huge
        for i = 0, 3 do
            local q = bp + v * (i * 0.1)
            s = math.min(s, Vector3.new(p.X - q.X, 0, p.Z - q.Z).Magnitude)
        end
        return s
    end
    local best, bestS = anchor, score(anchor)
    for i = 0, 23 do
        local a = i * math.pi / 12
        local p = anchor + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
        local sc = score(p)
        if sc > bestS then best, bestS = p, sc end
    end
    local old = Mods.Bob.avoid_p
    if old and (Vector3.new(old.X - anchor.X, 0, old.Z - anchor.Z)).Magnitude <= r + 0.01 and score(old) >= bestS - 2 then
        best = old
    end
    Mods.Bob.avoid_p = best
    return best
end
Mods.Orbit = Feature("Orbit")
Mods.SemiImmortal = Feature("SemiImmortal")
Mods.orbitSaved = { hum = nil, autorotate = nil }
function Mods.camReset()
    local h = Mods.orbitSaved.hum
    if h then
        pcall(function() h.CameraOffset = Vector3.zero end)
        if Mods.orbitSaved.autorotate ~= nil then pcall(function() h.AutoRotate = Mods.orbitSaved.autorotate end) end
    end
    Mods.orbitSaved.hum, Mods.orbitSaved.autorotate = nil, nil
end
function Mods.camHold(hum)
    if Mods.orbitSaved.hum ~= hum then
        Mods.camReset()
        Mods.orbitSaved.hum, Mods.orbitSaved.autorotate = hum, hum.AutoRotate
        hum.AutoRotate = false
    end
end
do
    local anchor, angle, charSeen = nil, 0, nil
    local function step(dt)
        local ctx, char = Mods.orbitCtx(), LocalPlayer.Character
        local hrp, hum = char and char:FindFirstChild("HumanoidRootPart"), char and char:FindFirstChildOfClass("Humanoid")
        if not ctx or not hrp or not hum or hum.Health <= 0 then anchor, Mods.Bob.base, Mods.Bob.last = nil, nil, nil; Mods.camReset(); return end
        if char ~= charSeen then charSeen, anchor, Mods.Bob.base, Mods.Bob.last = char, nil, nil, nil end
        local r = Mods.OrbitCfg.Radius
        local center, selfMode
        if Mods.OrbitCfg.Center == "Ball" then
            local b = Mods.orbitBall(ctx)
            if not b then anchor = nil; Mods.camReset(); return end
            center, anchor = b.Position, nil
        else
            selfMode = true
            if not anchor or (Vector3.new(anchor.X, 0, anchor.Z) - Vector3.new(hrp.Position.X, 0, hrp.Position.Z)).Magnitude > r * 2 + 40 then
                anchor = hrp.Position
            end
            local md = hum.MoveDirection
            if md.Magnitude > 0.01 then
                anchor = anchor + Vector3.new(md.X, 0, md.Z).Unit * hum.WalkSpeed * Mods.OrbitCfg.Walk * dt
            end
            center = anchor
        end
        angle = (angle + Mods.OrbitCfg.Speed * 2 * math.pi * (Mods.OrbitCfg.Clockwise and -1 or 1) * dt) % (2 * math.pi)
        local ox, oz = Mods.shapePt(Mods.OrbitCfg.Shape, angle)
        local hover = Mods.OrbitCfg.Height ~= 0
        local baseY
        if hover then
            baseY = center.Y + Mods.OrbitCfg.Height
        elseif Mods.OrbitCfg.Bob then
            Mods.Bob.base = Mods.Bob.base or hrp.Position.Y
            baseY = Mods.Bob.base
        else
            Mods.Bob.base = nil
            baseY = hrp.Position.Y
        end
        local home
        if Mods.OrbitCfg.Center == "Avoid ball" then
            local a = Mods.Bob.avoid(ctx, center, r)
            home = Vector3.new(a.X, baseY, a.Z)
        else
            home = Vector3.new(center.X + ox * r, baseY, center.Z + oz * r)
        end
        local off = Mods.Bob.delta(ctx, home, dt)
        Mods.Bob.last = off
        local pos = home + off
        local rot = Mods.OrbitCfg.Face and CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)).Rotation or hrp.CFrame.Rotation
        Mods.camHold(hum)
        hrp.CFrame = CFrame.new(pos) * rot
        local v = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(0, (hover or Mods.OrbitCfg.Bob) and 0 or v.Y, 0)
        local focus = selfMode and Vector3.new(center.X, baseY, center.Z) or home
        hum.CameraOffset = hrp.CFrame:VectorToObjectSpace(focus - hrp.Position)
    end
    function Mods.Orbit.start()
        anchor, charSeen, Mods.Bob.base = nil, nil, nil
        local tok = Mods.Orbit._token
        task.spawn(function()
            local last = os.clock()
            while Mods.Orbit:alive(tok) do
                local now = os.clock()
                local dt = math.min(now - last, 0.1)
                last = now
                pcall(step, dt)
                task.wait()
            end
        end)
    end
    function Mods.Orbit.stop() anchor, Mods.Bob.base, Mods.Bob.avoid_p = nil, nil, nil; Mods.camReset() end
end
function Mods.SemiImmortal.start()
    local tok = Mods.SemiImmortal._token
    Mods.Bob.base, Mods.Bob.last = nil, nil
    task.spawn(function()
        local lastT = os.clock()
        while Mods.SemiImmortal:alive(tok) do
            local now = os.clock()
            local dt = math.min(now - lastT, 0.1)
            lastT = now
            pcall(function()
                if Mods.Orbit.on then return end
                local char = LocalPlayer.Character
                local hrp, hum = char and char:FindFirstChild("HumanoidRootPart"), char and char:FindFirstChildOfClass("Humanoid")
                local ctx = Mods.orbitCtx()
                if not ctx or not hrp or not hum or hum.Health <= 0 then Mods.Bob.base, Mods.Bob.last = nil, nil; Mods.camReset(); return end
                local p = hrp.Position - (Mods.Bob.last or Vector3.zero)
                Mods.Bob.base = Mods.Bob.base or p.Y
                local home = Vector3.new(p.X, Mods.Bob.base, p.Z)
                local off = Mods.Bob.delta(ctx, home, dt)
                Mods.camHold(hum)
                hrp.CFrame = CFrame.new(home + off) * hrp.CFrame.Rotation
                Mods.Bob.last = off
                local v = hrp.AssemblyLinearVelocity
                hrp.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
                hum.CameraOffset = hrp.CFrame:VectorToObjectSpace(-off)
            end)
            task.wait()
        end
    end)
end
function Mods.SemiImmortal.stop() Mods.Bob.base, Mods.Bob.last = nil, nil; if not Mods.Orbit.on then Mods.camReset() end end

Gui.OB = Gui.Tabs.Orbit:AddLeftGroupbox("Orbit", "orbit")
Gui.OB:AddToggle("Orbit", {
    Text = "Orbit", Default = false,
    Tooltip = "Works in a match and in lobby training; does nothing in the lobby. Fast orbits move you faster than walking.",
    Callback = function(v) Mods.Orbit:setEnabled(v) end,
}):AddKeyPicker("OrbitKey", { Default = "O", Mode = "Toggle", SyncToggleState = true, Text = "Orbit" })
Gui.OB:AddDropdown("OrbitCenter", {
    Values = { "Yourself", "Ball", "Avoid ball" }, Default = "Yourself", Text = "Orbit around",
    Tooltip = "Yourself: the spot you were standing on -- walking moves that spot and the camera stays on it. Ball: the match ball in a match, your training ball in training. Avoid ball: walkable like Yourself, but you stand on the point within Radius farthest from the ball and its path.",
    Callback = function(v) Mods.OrbitCfg.Center = v end,
})
Gui.OB:AddDropdown("OrbitShape", {
    Values = { "Circle", "Ellipse", "Triangle", "Square", "Hexagon", "Star", "Figure 8", "Flower" }, Default = "Circle", Text = "Shape",
    Callback = function(v) Mods.OrbitCfg.Shape = v end,
})
Gui.OB:AddSlider("OrbitRadius", { Text = "Radius", Default = 8, Min = 2, Max = 80, Rounding = 1, Suffix = " studs",
    Callback = function(v) Mods.OrbitCfg.Radius = v end })
Gui.OB:AddSlider("OrbitSpeed", { Text = "Speed", Default = 0.5, Min = 0.05, Max = 20, Rounding = 2, Suffix = " laps/s",
    Callback = function(v) Mods.OrbitCfg.Speed = v end })
Gui.OB:AddDropdown("OrbitDirection", { Values = { "Counter-clockwise", "Clockwise" }, Default = "Counter-clockwise", Text = "Direction",
    Callback = function(v) Mods.OrbitCfg.Clockwise = v == "Clockwise" end })
Gui.OB:AddSlider("OrbitHeight", { Text = "Height", Default = 0, Min = -10, Max = 40, Rounding = 1, Suffix = " studs",
    Tooltip = "0 = stay on the ground (gravity and jumping still work). Anything else holds you that high above the centre.",
    Callback = function(v) Mods.OrbitCfg.Height = v end })
Gui.OB:AddSlider("OrbitWalk", { Text = "Walk speed", Default = 1, Min = 0, Max = 3, Rounding = 2, Suffix = "x",
    Tooltip = "How fast your movement input moves the centre (x your walk speed). 0 = the centre stays put.",
    Callback = function(v) Mods.OrbitCfg.Walk = v end })
Gui.OB:AddToggle("OrbitFace", { Text = "Face the centre", Default = false,
    Callback = function(v) Mods.OrbitCfg.Face = v end })
Gui.SI = Gui.Tabs.Orbit:AddRightGroupbox("Semi immortal", "shield")
Gui.SI:AddToggle("SemiImmortal", { Text = "Semi immortal", Default = false,
    Tooltip = "Moves you off your spot and back every frame, so the ball can't settle on you. Works with or without orbit; the camera ignores it. In a match / training only.",
    Callback = function(v) Mods.OrbitCfg.Bob = v; Mods.SemiImmortal:setEnabled(v) end })
Gui.SI:AddDropdown("SemiImmortalMode", { Values = { "Range", "Flip" }, Default = "Range", Text = "Mode",
    Tooltip = "Range: to the point within Range farthest off the incoming ball's line, farther for faster balls (1000+ speed), and every frame once it's about to land. Flip: straight up by Flip height.",
    Callback = function(v) Mods.OrbitCfg.BobMode = v end })
Gui.SI:AddSlider("SemiImmortalRange", { Text = "Range", Default = 30, Min = 5, Max = 120, Rounding = 0, Suffix = " studs",
    Tooltip = "Minimum distance for Range mode; fast balls push it further automatically.",
    Callback = function(v) Mods.OrbitCfg.BobRange = v end })
Gui.SI:AddSlider("SemiImmortalAmp", { Text = "Flip height", Default = 25, Min = 5, Max = 120, Rounding = 0, Suffix = " studs",
    Callback = function(v) Mods.OrbitCfg.BobAmp = v end })

function Mods.hexc(c) return ("%02x%02x%02x"):format(math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255)) end
function Mods.speedColor(s)
    if s > 2000 then return Color3.fromRGB(255, 0, 0) elseif s > 1500 then return Color3.fromRGB(255, 165, 0)
    elseif s > 1000 then return Color3.fromRGB(255, 215, 0) end
    return Color3.fromRGB(255, 255, 0)
end
function Mods.panel(name, size, pos, titleText)
    local gui = Instance.new("ScreenGui"); gui.Name = randName(); gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    local frame = Instance.new("Frame"); frame.Size = size; frame.Position = pos
    frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18); frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0; frame.Active = true; frame.Draggable = true; frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(60, 60, 70)
    if titleText then
        local t = Instance.new("TextLabel", frame); t.Size = UDim2.new(1, 0, 0, 18); t.Position = UDim2.new(0, 0, 0, 4)
        t.BackgroundTransparency = 1; t.Text = titleText; t.TextColor3 = Color3.fromRGB(255, 255, 255)
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

Mods.BallVelocity = Feature("BallVelocity")
Mods.BallVelocity.round_only = true
function Mods.BallVelocity.start()
    local gui, line = Mods.panel("BB_BallVelocity", UDim2.new(0, 200, 0, 70), UDim2.new(0, 10, 0.78, 0), "Ball Status")
    Mods.BallVelocity:own(gui)
    local cur, peakl = line(24), line(44)
    local peak, lastBall = 0, nil
    pcall(Parry.resolve)
    Mods.BallVelocity:connect(RunService.RenderStepped, function()
        local ball = Parry.mainBall()
        if not ball then cur.Text = "Current: 0"; return end
        if ball ~= lastBall then peak, lastBall = 0, ball end
        local s = Parry.ballVelocity(ball).Magnitude
        if s > peak then peak = s end
        cur.Text = ("Current: <font color='#%s'>%.1f</font>"):format(Mods.hexc(Mods.speedColor(s)), s)
        peakl.Text = ("Peak: <font color='#%s'>%.1f</font>"):format(Mods.hexc(Mods.speedColor(peak)), peak)
    end)
end

Mods.PingOverlay = Feature("PingOverlay")
function Mods.PingOverlay.start()
    local gui, line = Mods.panel("BB_Ping", UDim2.new(0, 110, 0, 32), UDim2.new(0, 15, 0.9, 0), nil)
    Mods.PingOverlay:own(gui)
    local l = line(6)
    l.TextXAlignment = Enum.TextXAlignment.Center
    Mods.PingOverlay:loop(0.5, function()
        local p = Parry.pingMs()
        local c = p < 80 and Color3.fromRGB(0, 255, 0) or (p < 150 and Color3.fromRGB(255, 220, 0) or Color3.fromRGB(255, 60, 60))
        l.Text = ("Ping: <font color='#%s'>%dms</font>"):format(Mods.hexc(c), math.floor(p + 0.5))
    end)
end

Mods.EspCfg = { Color = Color3.fromRGB(255, 255, 255), TextSize = 14, Height = 3.5, ShowName = true, ShowDistance = false,
    OnlyWithAbility = false, MaxDistance = 0, ShowActive = true, ShowCooldown = true, ShowSelf = true }
Mods.AbilityESP = Feature("AbilityESP")
do
    local gui, entries = nil, {}
    local function esc(t) return (tostring(t):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
    local function equipped(player, character)
        local a = player:GetAttribute('EquippedAbility') or (character and character:GetAttribute('Ability'))
        if a and a ~= '' then return tostring(a) end
        local ab = character and character:FindFirstChild('Abilities')
        if not ab then return nil end
        for _, sc in ipairs(ab:GetChildren()) do
            local ok, en = pcall(function() return sc.Enabled end)
            if ok and en then return sc.Name end
        end
        return nil
    end
    local function mkGui()
        local g = Instance.new("ScreenGui")
        g.Name = randName(); g.IgnoreGuiInset = true; g.ResetOnSpawn = false; g.DisplayOrder = 2
        pcall(function() if protectgui then protectgui(g) elseif syn and syn.protect_gui then syn.protect_gui(g) end end)
        if not pcall(function() g.Parent = hui() end) or not g.Parent then pcall(function() g.Parent = CoreGui end) end
        return g
    end
    local function remove(player)
        local e = entries[player]
        if e then pcall(function() e.label:Destroy() end) end
        entries[player] = nil
    end
    local function clearAll()
        for p in pairs(entries) do remove(p) end
        if gui then pcall(function() gui:Destroy() end); gui = nil end
    end
    local function newLabel()
        local l = Instance.new("TextLabel")
        l.AnchorPoint = Vector2.new(0.5, 1)
        l.Size = UDim2.fromOffset(320, 44)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.GothamBold
        l.RichText = true
        l.TextStrokeTransparency = 0.15
        l.TextYAlignment = Enum.TextYAlignment.Bottom
        l.Visible = false
        l.Parent = gui
        return l
    end
    local function refresh()
        local my, now, clock, seen = getRoot(), Workspace:GetServerTimeNow(), os.clock(), {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer or Mods.EspCfg.ShowSelf then
                local character = player.Character
                local head = character and character.Parent and (character:FindFirstChild('Head') or character.PrimaryPart)
                if head then
                    seen[player] = true
                    local e = entries[player]
                    if not e then e = { label = newLabel() }; entries[player] = e end
                    if e.char ~= character then e.char, e.ab_at = character, 0 end
                    e.head = head
                    if clock - e.ab_at > 1 then e.ab_at, e.ability = clock, equipped(player, character) end
                    local dist = my and player ~= LocalPlayer and (my.Position - head.Position).Magnitude or nil
                    e.show = not (Mods.EspCfg.MaxDistance > 0 and dist and dist > Mods.EspCfg.MaxDistance)
                        and not (Mods.EspCfg.OnlyWithAbility and not e.ability)
                    if e.show then
                        local name = e.ability
                        if name then
                            local up = player:FindFirstChild('Upgrades')
                            local lv = up and up:FindFirstChild(name)
                            if lv and type(lv.Value) == 'number' and lv.Value > 0 then name = name .. ' V' .. lv.Value end
                        end
                        local parts = {}
                        if Mods.EspCfg.ShowName then parts[#parts + 1] = esc(player.DisplayName) end
                        if name then parts[#parts + 1] = '[' .. esc(name) .. ']' end
                        if Mods.EspCfg.ShowDistance and dist then parts[#parts + 1] = ('%.0fm'):format(dist) end
                        if #parts == 0 then parts[1] = esc(player.DisplayName) end
                        local text = '<b>' .. table.concat(parts, ' ') .. '</b>'
                        if Mods.EspCfg.ShowCooldown then
                            local exp = character:GetAttribute('CooldownExpiration') or player:GetAttribute('CooldownExpiration')
                            if type(exp) == 'number' then
                                local left = exp - now
                                text = text .. ((left > 0 and left < 600) and ('\n<font color="#FF6A6A">CD %.1fs</font>'):format(left)
                                    or '\n<font color="#5CFF7A">READY</font>')
                            end
                        end
                        if text ~= e.text then e.text = text; e.label.Text = text end
                        if e.size ~= Mods.EspCfg.TextSize then e.size = Mods.EspCfg.TextSize; e.label.TextSize = Mods.EspCfg.TextSize end
                        if e.color ~= Mods.EspCfg.Color then e.color = Mods.EspCfg.Color; e.label.TextColor3 = Mods.EspCfg.Color end
                    end
                end
            end
        end
        for player in pairs(entries) do if not seen[player] then remove(player) end end
    end
    local function place()
        local cam = Workspace.CurrentCamera
        if not cam then return end
        local up = Vector3.new(0, Mods.EspCfg.Height, 0)
        for _, e in pairs(entries) do
            local head, vis = e.head, false
            if e.show and head and head.Parent then
                local p, on = cam:WorldToViewportPoint(head.Position + up)
                if on and p.Z > 0 then
                    e.label.Position = UDim2.fromOffset(math.floor(p.X + 0.5), math.floor(p.Y + 0.5))
                    vis = true
                end
            end
            if e.label.Visible ~= vis then e.label.Visible = vis end
        end
    end
    function Mods.AbilityESP.start()
        local tok = Mods.AbilityESP._token
        gui = mkGui()
        pcall(function() Parry.logp(("ability esp ON: %d other player(s)%s, overlay in %s"):format(
            #Players:GetPlayers() - 1, Mods.EspCfg.ShowSelf and " + you" or "", tostring(gui.Parent and gui.Parent.ClassName))) end)
        task.spawn(function()
            while Mods.AbilityESP:alive(tok) do pcall(refresh); task.wait(0.1) end
        end)
        task.spawn(function()
            while Mods.AbilityESP:alive(tok) do pcall(place); task.wait() end
        end)
    end
    function Mods.AbilityESP.stop() clearAll() end
end

Gui.VS = Gui.Tabs.Visuals:AddLeftGroupbox("Overlays", "monitor")
Gui.VS:AddToggle("BallVelocity", { Text = "Ball velocity overlay", Default = false, Callback = function(v) Mods.BallVelocity:setEnabled(v) end })
Gui.VS:AddToggle("ShowPing", { Text = "Ping overlay", Default = false, Callback = function(v) Mods.PingOverlay:setEnabled(v) end })

Gui.AE = Gui.Tabs.Visuals:AddRightGroupbox("Ability ESP", "eye")
Gui.AE:AddToggle("AbilityESP", { Text = "Ability ESP", Default = false, Callback = function(v) Mods.AbilityESP:setEnabled(v) end })
Gui.AE:AddToggle("AbilityESPSelf", { Text = "Show on yourself", Default = true,
    Callback = function(v) Mods.EspCfg.ShowSelf = v; if Mods.AbilityESP.on then Mods.AbilityESP:setEnabled(false); Mods.AbilityESP:setEnabled(true) end end })
Gui.AE:AddToggle("AbilityESPName", { Text = "Show name", Default = true, Callback = function(v) Mods.EspCfg.ShowName = v end })
Gui.AE:AddToggle("AbilityESPDistance", { Text = "Show distance", Default = false, Callback = function(v) Mods.EspCfg.ShowDistance = v end })
Gui.AE:AddToggle("AbilityESPOnlyWith", { Text = "Only players with an ability", Default = false, Callback = function(v) Mods.EspCfg.OnlyWithAbility = v end })
Gui.AE:AddToggle("AbilityESPCooldown", { Text = "Show ready / cooldown", Default = true, Callback = function(v) Mods.EspCfg.ShowCooldown = v end })
Gui.AE:AddSlider("AbilityESPTextSize", { Text = "Text size", Default = 14, Min = 8, Max = 30, Rounding = 0, Callback = function(v) Mods.EspCfg.TextSize = v end })
Gui.AE:AddSlider("AbilityESPHeight", { Text = "Height offset", Default = 3.5, Min = 0, Max = 15, Rounding = 1, Suffix = " studs", Callback = function(v) Mods.EspCfg.Height = v end })
Gui.AE:AddSlider("AbilityESPMaxDistance", { Text = "Max distance", Default = 0, Min = 0, Max = 2000, Rounding = 0, Suffix = " studs",
    Tooltip = "0 = unlimited.", Callback = function(v) Mods.EspCfg.MaxDistance = v end })
Gui.AE:AddLabel("Text color"):AddColorPicker("AbilityESPColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Ability ESP color",
    Callback = function(v) Mods.EspCfg.Color = v end })

Mods.Skin = { name = "", file = "BladeBall/skin.json" }
pcall(function()
    if isfile and isfile(Mods.Skin.file) then
        local d = HttpService:JSONDecode(readfile(Mods.Skin.file))
        if type(d) == "table" and type(d.swordModel) == "string" then Mods.Skin.name = d.swordModel end
    end
end)
function Mods.saveSkin()
    pcall(function()
        if makefolder and isfolder and not isfolder("BladeBall") then makefolder("BladeBall") end
        if writefile then writefile(Mods.Skin.file, HttpService:JSONEncode({ swordModel = Mods.Skin.name })) end
    end)
end
Mods.SkinChanger = Feature("SkinChanger")
do
    local swords, controller, realGetSword
    local function ourSword(name)
        return type(name) == "string" and name ~= "" and (name == LocalPlayer:GetAttribute("CurrentlyEquippedSword") or name == Mods.Skin.name)
    end
    local function setSword()
        if not Mods.SkinChanger.on or Mods.Skin.name == "" or not swords or not LocalPlayer.Character then return end
        pcall(function()
            local f = rawget(swords, "EquipSwordTo")
            if type(f) == "function" and getupvalues and setupvalue then
                local ups = getupvalues(f)
                for i = 1, #ups do if type(ups[i]) == "boolean" then setupvalue(f, i, false); break end end
            end
        end)
        pcall(function() swords:EquipSwordTo(LocalPlayer.Character, Mods.Skin.name) end)
        if controller then
            pcall(function() if controller.SetSword then controller:SetSword(Mods.Skin.name) end end)
            pcall(function()
                local R = getRemotes()
                if R and R:FindFirstChild("FireSwordInfo") then R.FireSwordInfo:FireServer(Mods.Skin.name) end
                if controller.currentSword ~= nil then controller.currentSword = Mods.Skin.name end
                if controller.SwordFX ~= nil then controller.SwordFX = Mods.Skin.name end
            end)
        end
    end
    local fxPaused, fxWraps = {}, {}
    local function skinSlash()
        local ok, data = pcall(realGetSword, swords, Mods.Skin.name)
        return (ok and type(data) == "table" and type(data.SlashName) == "string") and data.SlashName or "SlashEffect"
    end
    local function prefetch()
        task.spawn(function()
            pcall(function() ReplicatedStorage.Shared.ReplicatedInstances.SwordFX.GetInstance:Invoke(skinSlash()) end)
        end)
    end
    local function fxScript()
        local ok, s = pcall(function() return LocalPlayer.PlayerScripts.EffectScripts.ClientFX end)
        return ok and s or nil
    end
    local function swapFx()
        local R = getRemotes()
        if not (R and getconnections) then return false end
        local isours, found = isexecutorclosure or is_synapse_function or isourclosure, false
        for _, sig in ipairs({ R:FindFirstChild("ParrySuccessAll") and R.ParrySuccessAll.OnClientEvent,
                R:FindFirstChild("ParrySuccessClient") and R.ParrySuccessClient.Event }) do
            for _, c in ipairs(sig and getconnections(sig) or {}) do
                local f = c.Function
                if type(f) == "function" and not fxPaused[c] and (not isours or not isours(f))
                    and (not islclosure or islclosure(f)) then
                    fxPaused[c] = true
                    found = true
                    c:Disable()
                    fxWraps[#fxWraps + 1] = sig:Connect(function(...)
                        local cfx = fxScript()
                        if cfx and cfx.Disabled then return end
                        local args = table.pack(...)
                        if isLive() and Mods.SkinChanger.on and Mods.Skin.name ~= "" and args[4] == LocalPlayer then
                            pcall(function() args[1], args[3] = skinSlash(), Mods.Skin.name end)
                        end
                        f(table.unpack(args, 1, args.n))
                    end)
                end
            end
        end
        return found
    end
    local function unswapFx()
        for c in pairs(fxPaused) do pcall(function() c:Enable() end) end
        for _, c in ipairs(fxWraps) do pcall(function() c:Disconnect() end) end
        fxPaused, fxWraps = {}, {}
    end
    function Mods.SkinChanger.apply() if Mods.SkinChanger.on then Mods.saveSkin(); setSword(); if swords then prefetch() end end end
    function Mods.SkinChanger.start()
        local token = Mods.SkinChanger._token
        task.spawn(function()
            local ok = pcall(function()
                swords = swords or require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("ReplicatedInstances", 10):WaitForChild("Swords", 10))
            end)
            if not ok or not swords or not Mods.SkinChanger:alive(token) then
                if Mods.SkinChanger:alive(token) then Notify("Skin Changer", "Couldn't load the game's sword list.", 4) end
                return
            end
            pcall(function()
                realGetSword = realGetSword or swords.GetSword
                if type(realGetSword) == "function" then
                    rawset(swords, "GetSword", function(self, name, ...)
                        if Mods.SkinChanger.on and Mods.Skin.name ~= "" and Mods.Skin.name ~= name and ourSword(name) then
                            local ok2, data = pcall(realGetSword, self, Mods.Skin.name, ...)
                            if ok2 and type(data) == "table" then return data end
                        end
                        return realGetSword(self, name, ...)
                    end)
                end
            end)
            local tries = 0
            while not controller and tries < 40 and Mods.SkinChanger:alive(token) do
                pcall(function()
                    local R = getRemotes()
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
            if not Mods.SkinChanger:alive(token) then return end
            setSword()
            prefetch()
            Mods.SkinChanger:connect(LocalPlayer.CharacterAdded, function()
                task.wait(2.5)
                if Mods.SkinChanger:alive(token) then setSword() end
            end)
            Mods.SkinChanger:loop(1, function()
                local inr = Stagger.round_check and Stagger.round_check()
                if inr and Mods.Skin.name ~= "" and next(fxPaused) == nil then swapFx()
                elseif not inr and next(fxPaused) ~= nil then unswapFx() end
                if Mods.Skin.name == "" then return end
                local char = LocalPlayer.Character
                if not char then return end
                if LocalPlayer:GetAttribute("CurrentlyEquippedSword") ~= Mods.Skin.name or not char:FindFirstChild(Mods.Skin.name) then setSword() end
                for _, v in ipairs(char:GetChildren()) do
                    if v:IsA("Model") and v.Name ~= Mods.Skin.name and swords and pcall(function() return realGetSword(swords, v.Name) end) then
                        local ok3, data = pcall(realGetSword, swords, v.Name)
                        if ok3 and type(data) == "table" then v:Destroy() end
                    end
                end
            end)
        end)
    end
    function Mods.SkinChanger.stop()
        if swords and realGetSword then pcall(function() rawset(swords, "GetSword", realGetSword) end) end
        unswapFx()
    end
end

Gui.SC = Gui.Tabs.Misc:AddLeftGroupbox("Skin Changer", "palette")
Gui.SC:AddInput("SkinName", { Text = "Sword name", Placeholder = "e.g. DualPrince", Default = Mods.Skin.name, Finished = true,
    Callback = function(t) Mods.Skin.name = t; Mods.saveSkin(); Mods.SkinChanger.apply() end })
Gui.SC:AddToggle("SkinChanger", { Text = "Skin changer", Default = false, Callback = function(v) Mods.SkinChanger:setEnabled(v) end })
Anim.skin = function() return (Mods.SkinChanger.on and Mods.Skin.name ~= "") and Mods.Skin.name or nil end

Mods.NoRender = Feature("NoRender")
Mods.NoRender.round_only = true
Mods.NR_SEL = { ["Ability effects"] = true, ["Parry effects"] = true }
Mods.NR_FX = { ParticleEmitter = true, Trail = true, Beam = true, Smoke = true, Fire = true, Sparkles = true }
Mods.NR_POST = { BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true, SunRaysEffect = true, DepthOfFieldEffect = true }
Mods.nrSaved = {}
function Mods.nrSet(inst, prop, val)
    local ok, old = pcall(function() return inst[prop] end)
    if not ok or old == val then return end
    Mods.nrSaved[inst] = Mods.nrSaved[inst] or {}
    if Mods.nrSaved[inst][prop] == nil then Mods.nrSaved[inst][prop] = old end
    pcall(function() inst[prop] = val end)
end
function Mods.nrFx(inst) if Mods.NR_FX[inst.ClassName] then Mods.nrSet(inst, "Enabled", false) end end
function Mods.nrTree(root, token)
    if not root then return end
    Mods.NoRender:connect(root.DescendantAdded, Mods.nrFx)
    task.spawn(function()
        local list = root:GetDescendants()
        for k = 1, #list do
            if not Mods.NoRender:alive(token) then return end
            Mods.nrFx(list[k])
            if k % 2000 == 0 then task.wait() end
        end
    end)
end
function Mods.NoRender.start()
    local token, sel = Mods.NoRender._token, Mods.NR_SEL
    if sel["Parry effects"] then
        pcall(function() Mods.nrSet(LocalPlayer.PlayerScripts.EffectScripts.ClientFX, "Disabled", true) end)
    end
    if sel["Ability effects"] then
        local runtime = Workspace:FindFirstChild("Runtime")
        if runtime then Mods.NoRender:connect(runtime.ChildAdded, function(v) task.defer(pcall, v.Destroy, v) end) end
    end
    if sel["All particles"] then
        Mods.nrTree(Workspace, token)
    else
        if sel["Ball trails"] then
            for _, name in ipairs({ "Balls", "TrainingBalls" }) do Mods.nrTree(Workspace:FindFirstChild(name), token) end
        end
        if sel["Character effects"] then
            for _, name in ipairs({ "Alive", "Dead" }) do Mods.nrTree(Workspace:FindFirstChild(name), token) end
        end
    end
    if sel["Post effects"] or sel["Shadows"] then
        local Lighting = game:GetService("Lighting")
        if sel["Shadows"] then Mods.nrSet(Lighting, "GlobalShadows", false) end
        if sel["Post effects"] then
            for _, v in ipairs(Lighting:GetDescendants()) do if Mods.NR_POST[v.ClassName] then Mods.nrSet(v, "Enabled", false) end end
            pcall(function()
                for _, v in ipairs(Workspace.CurrentCamera:GetChildren()) do if Mods.NR_POST[v.ClassName] then Mods.nrSet(v, "Enabled", false) end end
            end)
            Mods.NoRender:connect(Lighting.DescendantAdded, function(v) if Mods.NR_POST[v.ClassName] then Mods.nrSet(v, "Enabled", false) end end)
        end
    end
end
function Mods.NoRender.stop()
    local saved = Mods.nrSaved
    Mods.nrSaved = {}
    for inst, props in pairs(saved) do
        for prop, old in pairs(props) do pcall(function() inst[prop] = old end) end
    end
end
Mods.DeviceSpoof = { on = false, device = "PC", hooked = false, real = nil, p = nil, lastfn = nil,
    skip = setmetatable({}, { __mode = "k" }), dl = setmetatable({}, { __mode = "k" }) }
function Mods.deviceProfiles()
    local PI = {}
    pcall(function() PI.kbm, PI.touch, PI.pad = Enum.PreferredInput.KeyboardAndMouse, Enum.PreferredInput.Touch, Enum.PreferredInput.Gamepad end)
    return {
        PC = { TouchEnabled = false, KeyboardEnabled = true, MouseEnabled = true, GamepadEnabled = false,
            PreferredInput = PI.kbm, last = Enum.UserInputType.MouseMovement },
        Phone = { TouchEnabled = true, KeyboardEnabled = false, MouseEnabled = false, GamepadEnabled = false,
            PreferredInput = PI.touch, last = Enum.UserInputType.Touch, vpY = 400 },
        Tablet = { TouchEnabled = true, KeyboardEnabled = false, MouseEnabled = false, GamepadEnabled = false,
            PreferredInput = PI.touch, last = Enum.UserInputType.Touch, vpY = 900 },
        Console = { TouchEnabled = false, KeyboardEnabled = false, MouseEnabled = false, GamepadEnabled = true,
            PreferredInput = PI.pad, last = Enum.UserInputType.Gamepad1 },
    }
end
function Mods.DeviceSpoof.install()
    if Mods.DeviceSpoof.hooked then return true end
    if type(hookmetamethod) ~= "function" or type(checkcaller) ~= "function" then return false end
    local RealUIS, RealGui, RealCore = game:GetService("UserInputService"), game:GetService("GuiService"), game:GetService("CoreGui")
    local getcs = getcallingscript
    local UIS_KEYS = { TouchEnabled = true, KeyboardEnabled = true, MouseEnabled = true, GamepadEnabled = true,
        PreferredInput = true, GetLastInputType = true }
    local function gameScript()
        if type(getcs) ~= "function" then return false end
        local ok, sc = pcall(getcs)
        if not ok or typeof(sc) ~= "Instance" then return false end
        local c = Mods.DeviceSpoof.skip[sc]
        if c == nil then
            local ok2, keepReal = pcall(function()
                return sc:FindFirstAncestor("PlayerModule") ~= nil or sc:IsDescendantOf(RealCore)
            end)
            c = ok2 and not keepReal
            Mods.DeviceSpoof.skip[sc] = c
        end
        return c, sc
    end
    Mods.DeviceSpoof.lastfn = newcclosure(function() return Mods.DeviceSpoof.p and Mods.DeviceSpoof.p.last end)
    local old
    local ok = pcall(function()
        old = hookmetamethod(game, "__index", newcclosure(function(self, k)
            if Mods.DeviceSpoof.on and type(k) == "string" and not checkcaller() then
                local p = Mods.DeviceSpoof.p
                if p then
                    if UIS_KEYS[k] and rawequal(self, RealUIS) then
                        if gameScript() then
                            if k == "GetLastInputType" then return Mods.DeviceSpoof.lastfn end
                            local v = p[k]
                            if v ~= nil then return v end
                        end
                    elseif k == "TouchControlsEnabled" and rawequal(self, RealGui) then
                        if gameScript() then return p.TouchEnabled end
                    elseif k == "ViewportSize" and p.vpY then
                        local gs, sc = gameScript()
                        if gs then
                            local isDl = Mods.DeviceSpoof.dl[sc]
                            if isDl == nil then
                                local okn, n = pcall(function() return sc.Name end)
                                isDl = okn and n == "DeviceListener"
                                Mods.DeviceSpoof.dl[sc] = isDl
                            end
                            if isDl then
                                local real = old(self, k)
                                return Vector2.new(real.X, p.vpY)
                            end
                        end
                    end
                end
            end
            return old(self, k)
        end))
    end)
    Mods.DeviceSpoof.hooked = ok and type(old) == "function"
    return Mods.DeviceSpoof.hooked
end
function Mods.DeviceSpoof.apply()
    pcall(function()
        local DL = require(ReplicatedStorage.ClientGameModules.DeviceListener)
        if Mods.DeviceSpoof.real == nil then Mods.DeviceSpoof.real = DL.Device end
        local dev = Mods.DeviceSpoof.on and Mods.DeviceSpoof.device or Mods.DeviceSpoof.real
        if dev and DL.Device ~= dev then
            DL.Device = dev
            pcall(function() DL.State:Set(dev) end)
            pcall(function() DL.OnChange:Fire(dev) end)
        end
    end)
end
Mods.DeviceSpoofF = Feature("DeviceSpoof")
function Mods.DeviceSpoofF.start()
    Mods.DeviceSpoof.p = Mods.deviceProfiles()[Mods.DeviceSpoof.device] or Mods.deviceProfiles().PC
    if not Mods.DeviceSpoof.install() then
        Notify("Device spoofer", "Your executor is missing hookmetamethod / checkcaller.", 4)
        return
    end
    Mods.DeviceSpoof.apply()
    Mods.DeviceSpoof.on = true
    Mods.DeviceSpoof.apply()
    Mods.DeviceSpoofF:loop(2, function() Mods.DeviceSpoof.apply() end)
end
function Mods.DeviceSpoofF.stop()
    Mods.DeviceSpoof.on = false
    Mods.DeviceSpoof.apply()
end

Gui.DS = Gui.Tabs.Misc:AddLeftGroupbox("Device spoofer", "smartphone")
Gui.DS:AddToggle("DeviceSpoof", {
    Text = "Device spoofer", Default = false,
    Tooltip = "The game treats you as the device below (its mobile buttons, layouts and anything it decides by device). Your real thumbstick and camera keep working. Off puts your real device back.",
    Callback = function(v) Mods.DeviceSpoofF:setEnabled(v) end,
})
Gui.DS:AddDropdown("DeviceSpoofType", {
    Values = { "PC", "Phone", "Tablet", "Console" }, Default = "PC", Text = "Device",
    Callback = function(v)
        Mods.DeviceSpoof.device = v
        Mods.DeviceSpoof.p = Mods.deviceProfiles()[v]
        if Mods.DeviceSpoof.on then Mods.DeviceSpoof.apply() end
    end,
})

Mods.InfAbility = { on = false, last = -math.huge, direction = "Move", gap = 0.2, fov_base = nil, fov_until = 0, tracks = setmetatable({}, { __mode = 'k' }) }
Mods.INF_ABILITIES = {
    ["Blink"] = { kind = "tp", remote = "Blinked", dist = function(up) return 16 + 5 * up end },
    ["Thunder Dash"] = { kind = "tp", remote = "ThunderDash", dist = function(up) return 22 + 10 * up end },
    ["Dash"] = { kind = "dash" },
}
function Mods.infEquipped(char)
    local name = LocalPlayer:GetAttribute("AbilityOverride") or LocalPlayer:GetAttribute("CurrentlyEquippedAbility")
        or LocalPlayer:GetAttribute("EquippedAbility")
    local folder = char:FindFirstChild("Abilities")
    if type(name) == "string" then
        if Mods.INF_ABILITIES[name] and (not folder or folder:FindFirstChild(name)) then return name, Mods.INF_ABILITIES[name] end
        return nil
    end
    if folder then
        for n, def in pairs(Mods.INF_ABILITIES) do
            local sc = folder:FindFirstChild(n)
            if sc and sc:IsA("LocalScript") and sc.Enabled then return n, def end
        end
    end
    return nil
end
function Mods.infDir(hum)
    if Mods.InfAbility.direction == "Camera" then
        local look = Workspace.CurrentCamera.CFrame.LookVector
        local flat = Vector3.new(look.X, 0, look.Z)
        if flat.Magnitude > 1e-3 then return flat.Unit end
    end
    local md = hum.MoveDirection
    if md.Magnitude > 1e-3 then return md.Unit end
    return nil
end
function Mods.infTp(char, hrp, def, up, dir)
    local dist, pos = def.dist(up), hrp.Position
    pcall(function()
        ReplicatedStorage.Remotes[def.remote]:FireServer(pos, { char.Head.CFrame, char["Left Arm"].CFrame,
            char["Right Arm"].CFrame, char["Right Leg"].CFrame, char["Left Leg"].CFrame, char.Torso.CFrame })
    end)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local skip = {}
    for _, n in ipairs({ "Runtime", "Alive", "Dead", "Balls", "TrainingBalls" }) do
        local f = Workspace:FindFirstChild(n)
        if f then skip[#skip + 1] = f end
    end
    params.FilterDescendantsInstances = skip
    local hit = Workspace:Raycast(pos, dir * dist, params)
    if hit and hit.Instance then hrp.CFrame = CFrame.new(hit.Position)
    else hrp.CFrame = hrp.CFrame + dir * dist end
end
function Mods.infDash(char, hum, hrp, up, dir)
    local now = clock_()
    pcall(function() ReplicatedStorage.Remotes.PlrDashed:FireServer() end)
    pcall(function()
        local cam = Workspace.CurrentCamera
        if now >= Mods.InfAbility.fov_until or not Mods.InfAbility.fov_base then Mods.InfAbility.fov_base = cam.FieldOfView end
        Mods.InfAbility.fov_until = now + 0.5
        cam.FieldOfView = Mods.InfAbility.fov_base
        game:GetService("TweenService"):Create(cam, TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, true, 0),
            { FieldOfView = Mods.InfAbility.fov_base * 1.25 }):Play()
    end)
    pcall(function()
        local anim, animator = char.Abilities.Dash:FindFirstChild("Dash"), hum:FindFirstChildOfClass("Animator")
        if anim and animator then
            local t = Mods.InfAbility.tracks[animator]
            if not t then t = animator:LoadAnimation(anim); Mods.InfAbility.tracks[animator] = t end
            t:Play()
        end
    end)
    local power, scale = (up == 1 and 180) or (up == 2 and 200) or 160, 1
    pcall(function() scale = char:GetScale() end)
    if scale > 1 then power = power * scale end
    local cf = hrp.CFrame
    local look, right = cf.LookVector, cf.RightVector
    local top = 1 - 1e-8
    local f, r = math.clamp(dir:Dot(look), -1, top), math.clamp(dir:Dot(right), -1, top)
    local att = Instance.new("Attachment")
    att.Parent = hrp
    local lv = Instance.new("LinearVelocity")
    lv.Name = "Dash"
    lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
    lv.MaxAxesForce = Vector3.new(100000, 0, 100000)
    lv.Attachment0 = att
    lv.VectorVelocity = look * f * power + right * r * power
    lv.Parent = att
    task.delay(0.01, function() pcall(att.Destroy, att) end)
    local made = {}
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("BasePart") and not v.Massless then v.Massless = true; made[#made + 1] = v end
    end
    local pin
    pcall(function() pin = char.Colliders.Pin:FindFirstChildWhichIsA("RigidConstraint") end)
    if pin then pin.Enabled = false end
    task.delay(0.3, function()
        for _, v in ipairs(made) do pcall(function() v.Massless = false end) end
        if pin then pcall(function() pin.Enabled = true end) end
        local pp = char.PrimaryPart
        if pp then pp.AssemblyLinearVelocity, pp.AssemblyAngularVelocity = Vector3.zero, Vector3.zero end
    end)
end
function Mods.InfAbility.use()
    if not Mods.InfAbility.on or not isLive() then return end
    local now = clock_()
    if now - Mods.InfAbility.last < Mods.InfAbility.gap then return end
    local char = LocalPlayer.Character
    local hum, hrp = char and char:FindFirstChildOfClass("Humanoid"), char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp) or hum.Health <= 0 or char.Parent ~= Workspace:FindFirstChild("Alive") then return end
    local okr, red = pcall(function() return LocalPlayer.PlayerGui.Hotbar.Ability.Red.Visible end)
    if okr and red ~= false then return end
    if char.PrimaryPart and char.PrimaryPart:FindFirstChild("FREEZER") then return end
    local name, def = Mods.infEquipped(char)
    if not name then Notify("Infinite ability", "Equip Blink, Thunder Dash or Dash.", 3); return end
    local dir = Mods.infDir(hum)
    if not dir then return end
    Mods.InfAbility.last = now
    local up = 0
    pcall(function() up = LocalPlayer.Upgrades[name].Value end)
    if def.kind == "dash" then Mods.infDash(char, hum, hrp, up, dir) else Mods.infTp(char, hrp, def, up, dir) end
end
Mods.InfAbility.paused, Mods.InfAbility.conn = {}, nil
function Mods.infUnroute()
    for c in pairs(Mods.InfAbility.paused) do pcall(function() c:Enable() end) end
    Mods.InfAbility.paused = {}
    if Mods.InfAbility.conn then pcall(function() Mods.InfAbility.conn:Disconnect() end); Mods.InfAbility.conn = nil end
end
function Mods.infRoute(char, name)
    local ev = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("AbilityButtonPress")
    if not (ev and getconnections) then return end
    local tail = "Abilities." .. name
    for _, c in ipairs(getconnections(ev.Event)) do
        local f = c.Function
        if type(f) == "function" and not Mods.InfAbility.paused[c] then
            local ok, src = pcall(debug.info, f, "s")
            if ok and type(src) == "string" and src:sub(-#tail) == tail then
                Mods.InfAbility.paused[c] = true
                pcall(function() c:Disable() end)
            end
        end
    end
    if not Mods.InfAbility.conn then
        Mods.InfAbility.conn = ev.Event:Connect(function()
            if Mods.InfAbility.on and isLive() then Mods.InfAbility.use() end
        end)
    end
end
function Mods.InfAbility.watch()
    if Mods.InfAbility.watching then return end
    Mods.InfAbility.watching = true
    task.spawn(function()
        while Mods.InfAbility.on and isLive() do
            local char = LocalPlayer.Character
            local name = char and char.Parent == Workspace:FindFirstChild("Alive") and Mods.infEquipped(char)
            if name then pcall(Mods.infRoute, char, name) elseif next(Mods.InfAbility.paused) or Mods.InfAbility.conn then Mods.infUnroute() end
            task.wait(0.5)
        end
        Mods.infUnroute()
        Mods.InfAbility.watching = false
    end)
end
Gui.IA = Gui.Tabs.Misc:AddRightGroupbox("Abilities", "zap")
Gui.IA:AddToggle("InfAbility", {
    Text = "Infinite Blink / Thunder Dash / Dash", Default = false,
    Tooltip = "Uses your equipped Blink, Thunder Dash or Dash like the game does, with no charges or cooldown (the game keeps those on your side). PC: the key below. Phone: your normal ability button does it while this is on. Experimental: the server sees every use -- if it kicks, turn it off.",
    Callback = function(v) Mods.InfAbility.on = v; if v then Mods.InfAbility.watch() end end,
})
Gui.IA:AddDropdown("InfAbilityDir", {
    Values = { "Move", "Camera" }, Default = "Move", Text = "Direction",
    Tooltip = "Move: the way you're walking (the game's way). Camera: where you're looking, flat -- works standing still.",
    Callback = function(v) Mods.InfAbility.direction = v end,
})
Gui.IA:AddSlider("InfAbilityGap", {
    Text = "Min time between uses", Default = 0.2, Min = 0.05, Max = 2, Rounding = 2, Suffix = "s",
    Callback = function(v) Mods.InfAbility.gap = v end,
})
Gui.IA:AddLabel("Ability key"):AddKeyPicker("InfAbilityKey", {
    Default = "None", Mode = "Toggle", Text = "Infinite ability", Callback = function() Mods.InfAbility.use() end,
})

Mods.Panel = { sel = {}, spam = false, spam_for = 10, spam_every = 0.25, token = nil }
Mods.PANEL_PLACE = 15234596844
function Mods.Panel.gui() return LocalPlayer.PlayerGui:FindFirstChild("TrainingModeServerPanel") end
function Mods.Panel.owner()
    if LocalPlayer:GetAttribute("ServerAdminAccess") == true then return true end
    local training = game.PlaceId == Mods.PANEL_PLACE or Mods.Panel.gui() ~= nil
    if not training then return false end
    local info = ReplicatedStorage:FindFirstChild("ServerInfo")
    local so = info and info:FindFirstChild("serverOwner")
    if so then return so.Value == LocalPlayer.UserId end
    return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == LocalPlayer.UserId
end
function Mods.Panel.press(btn)
    if typeof(btn) ~= "Instance" or not btn:IsA("GuiButton") then return false end
    if type(firesignal) == "function" and pcall(firesignal, btn.Activated) then return true end
    local ok, conns = pcall(getconnections, btn.Activated)
    if not ok or type(conns) ~= "table" or #conns == 0 then return false end
    for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
    return true
end
function Mods.Panel.button(path)
    if not Mods.Panel.owner() then Notify("Panel", "You're not the owner of this training server.", 3); return nil end
    local gui = Mods.Panel.gui()
    if not gui then Notify("Panel", "No training server panel here.", 3); return nil end
    local node = gui
    for _, part in ipairs(path) do
        node = node and node:FindFirstChild(part)
    end
    if not node then Notify("Panel", "Couldn't find " .. table.concat(path, ".") .. " in the game's panel.", 3) end
    return node
end
function Mods.Panel.click(path) local b = Mods.Panel.button(path); return b ~= nil and Mods.Panel.press(b) end
function Mods.Panel.selected()
    local list = {}
    for name, on in pairs(Mods.Panel.sel) do
        local plr = on and Players:FindFirstChild(name)
        if plr and plr:IsA("Player") then list[#list + 1] = plr end
    end
    return list
end
function Mods.Panel.names()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do list[#list + 1] = plr.Name end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    return list
end
function Mods.Panel.row(plr)
    local gui = Mods.Panel.gui()
    local pp = gui and gui:FindFirstChild("PlayerPanel")
    if not pp then return nil end
    local want = "@" .. plr.Name
    for _, list in ipairs({ pp:FindFirstChild("Playing"), pp:FindFirstChild("NotPlaying") }) do
        for _, row in ipairs(list and list:GetChildren() or {}) do
            local u = row:FindFirstChild("Username")
            if u and u:IsA("TextLabel") and u.Text == want then return row end
        end
    end
    return nil
end
function Mods.Panel.player_action(plr, which)
    if not Mods.Panel.owner() then Notify("Panel", "You're not the owner of this training server.", 3); return false end
    local row = Mods.Panel.row(plr)
    local btn = row and row:FindFirstChild(which)
    if not btn then return false end
    return Mods.Panel.press(btn)
end
function Mods.Panel.checked(path)
    local ok, v = pcall(function()
        local f = Mods.Panel.gui().Frame
        for _, part in ipairs(path) do f = f[part] end
        return f.CheckFrame.CheckIcon.Visible
    end)
    if ok then return v end
    return nil
end
function Mods.Panel.options(group, list)
    local names = {}
    pcall(function()
        for _, c in ipairs(Mods.Panel.gui().Frame[group][list]:GetChildren()) do
            if c:IsA("GuiButton") and c.Name ~= "Custom" then names[#names + 1] = c.Name end
        end
    end)
    table.sort(names)
    return names
end
function Mods.Panel.bot_count()
    local ok, n = pcall(function() return tonumber(Mods.Panel.gui().Frame.Bots.Counter.Count.Text:match("^(%d+)")) end)
    return ok and n or nil
end
function Mods.Panel.set_bots(want)
    task.spawn(function()
        for _ = 1, 12 do
            local n = Mods.Panel.bot_count()
            if not n or n == want then return end
            if not Mods.Panel.click({ "Frame", "Bots", n < want and "BotIncrease" or "BotDecrease" }) then return end
            task.wait(0.15)
        end
    end)
end
function Mods.Panel.reset_selected()
    local n = 0
    for _, plr in ipairs(Mods.Panel.selected()) do
        if Mods.Panel.player_action(plr, "Reset") then n = n + 1 end
    end
    return n
end
function Mods.Panel.spam_start()
    local token = {}
    Mods.Panel.token = token
    task.spawn(function()
        local t0 = clock_()
        while Mods.Panel.spam and Mods.Panel.token == token and isLive() do
            if not Mods.Panel.owner() then Notify("Panel", "Spam reset stopped: you're not the owner.", 3); break end
            if Mods.Panel.spam_for > 0 and clock_() - t0 >= Mods.Panel.spam_for then break end
            Mods.Panel.reset_selected()
            task.wait(Mods.Panel.spam_every)
        end
        if Mods.Panel.token == token then
            Mods.Panel.spam, Mods.Panel.token = false, nil
            pcall(function() Toggles.PanelSpamReset:SetValue(false) end)
        end
    end)
end

function Mods.mkPanel()
local PO = Gui.Tabs.Panel:AddLeftGroupbox("Server", "crown")
local PanelStatus = PO:AddLabel("Owner: checking...", true)
local function panelStatus()
    pcall(function()
        PanelStatus:SetText(Mods.Panel.owner() and "Owner: yes -- panel actions work here."
            or "Owner: no -- the server only takes these from its owner.")
    end)
end
PO:AddButton({ Text = "Start match", Func = function() Mods.Panel.click({ "Frame", "Server", "StartRound" }) end })
PO:AddButton({ Text = "End match", Func = function() Mods.Panel.click({ "Frame", "Server", "EndRound" }) end })
PO:AddSlider("PanelBots", { Text = "Bots", Default = 1, Min = 0, Max = 10, Rounding = 0,
    Callback = function(v) Mods.Panel.bots = v end })
PO:AddButton({ Text = "Set bots", Func = function() Mods.Panel.set_bots(Mods.Panel.bots or 1) end })
local PanelDiff = PO:AddDropdown("PanelDifficulty", { Values = {}, Text = "Difficulty",
    Tooltip = "Filled from the game's panel -- press Refresh options if it's empty.",
    Callback = function(v) Mods.Panel.difficulty = v end })
PO:AddButton({ Text = "Set difficulty", Func = function()
    if Mods.Panel.difficulty then Mods.Panel.click({ "Frame", "Bots", "Difficulties", Mods.Panel.difficulty }) end
end })
local PanelMode = PO:AddDropdown("PanelMode", { Values = {}, Text = "Game mode",
    Callback = function(v) Mods.Panel.mode = v end })
PO:AddButton({ Text = "Set game mode", Func = function()
    if Mods.Panel.mode then Mods.Panel.click({ "Frame", "Game", "Modes", Mods.Panel.mode }) end
end })
for _, cb in ipairs({ { "Respawn", { "Bots", "Respawn" } }, { "BotsMove", { "Bots", "Move" } },
        { "AutoStart", { "Server", "AutoStart" } }, { "ChangeAbilitiesMiddleRound", { "Game", "Abilitymidround" } } }) do
    PO:AddButton({ Text = "Toggle " .. cb[1], Func = function()
        Mods.Panel.click({ "Frame", cb[2][1], cb[2][2], "CheckFrame" })
    end })
end
PO:AddButton({ Text = "Refresh options", Func = function()
    pcall(function() PanelDiff:SetValues(Mods.Panel.options("Bots", "Difficulties")) end)
    pcall(function() PanelMode:SetValues(Mods.Panel.options("Game", "Modes")) end)
    panelStatus()
end })

local PP2 = Gui.Tabs.Panel:AddRightGroupbox("Players", "users")
local PanelPlayers = PP2:AddDropdown("PanelPlayers", { Values = Mods.Panel.names(), Default = {}, Multi = true, Text = "Players",
    Searchable = true,
    Callback = function(v)
        Mods.Panel.sel = {}
        for name, on in pairs(type(v) == "table" and v or {}) do if on then Mods.Panel.sel[name] = true end end
    end })
PP2:AddButton({ Text = "Refresh players", Func = function()
    pcall(function() PanelPlayers:SetValues(Mods.Panel.names()) end)
    panelStatus()
end })
PP2:AddButton({ Text = "Reset selected", Func = function()
    local n = Mods.Panel.reset_selected()
    if n == 0 and #Mods.Panel.selected() == 0 then Notify("Panel", "No players selected.", 2) end
end })
PP2:AddButton({ Text = "Add / remove selected", Tooltip = "Adds or removes them from the round queue (the game won't toggle you).",
    Func = function()
        for _, plr in ipairs(Mods.Panel.selected()) do
            if plr ~= LocalPlayer then Mods.Panel.player_action(plr, "Toggle") end
        end
    end })
PP2:AddToggle("PanelSpamReset", { Text = "Spam reset selected", Default = false,
    Tooltip = "Keeps resetting the selected players for the time below, at the speed below. Owner only; stops by itself.",
    Callback = function(v)
        Mods.Panel.spam = v
        if v then
            if #Mods.Panel.selected() == 0 then Notify("Panel", "Select players first.", 2) end
            Mods.Panel.spam_start()
        else Mods.Panel.token = nil end
    end })
local PANEL_FOR = { ["5s"] = 5, ["10s"] = 10, ["30s"] = 30, ["1 min"] = 60, ["5 min"] = 300, ["Until off"] = 0 }
PP2:AddDropdown("PanelSpamFor", { Values = { "5s", "10s", "30s", "1 min", "5 min", "Until off" }, Default = "10s", Text = "For",
    Callback = function(v) Mods.Panel.spam_for = PANEL_FOR[v] or 10 end })
local PANEL_EVERY = { ["0.1s"] = 0.1, ["0.25s"] = 0.25, ["0.5s"] = 0.5, ["1s"] = 1, ["2s"] = 2, ["5s"] = 5 }
PP2:AddDropdown("PanelSpamEvery", { Values = { "0.1s", "0.25s", "0.5s", "1s", "2s", "5s" }, Default = "0.25s", Text = "Every",
    Callback = function(v) Mods.Panel.spam_every = PANEL_EVERY[v] or 0.25 end })
task.defer(panelStatus)
end
function Mods.panelTry()
    if Mods.Panel.built or not isLive() then return end
    local admin = LocalPlayer:GetAttribute("ServerAdminAccess") == true
    if not admin and not (game.PlaceId == Mods.PANEL_PLACE and Mods.Panel.owner()) then return end
    Mods.Panel.built = true
    Gui.Tabs.Panel = Gui.Window:AddTab("Panel", "crown", "Training server owner panel")
    Mods.mkPanel()
end
pcall(Mods.panelTry)
if not Mods.Panel.built then
    task.spawn(function()
        while isLive() and not Mods.Panel.built do
            task.wait(3)
            pcall(Mods.panelTry)
        end
    end)
end

Gui.NR = Gui.Tabs.Misc:AddRightGroupbox("Performance", "cpu")
Gui.NR:AddToggle("NoRender", { Text = "No render", Default = false, Tooltip = "Turns off what's picked below.",
    Callback = function(v) Mods.NoRender:setEnabled(v) end })
Gui.NR:AddDropdown("NoRenderWhat", {
    Values = { "Ability effects", "Parry effects", "Ball trails", "Character effects", "All particles", "Post effects", "Shadows" },
    Default = { "Ability effects", "Parry effects" }, Multi = true, Text = "Removes",
    Tooltip = "Ability effects: spawned ability visuals. Parry effects: the game's hit/parry FX script. Ball trails / Character effects: particles, trails and beams on balls / players. All particles: every particle, trail and beam in the map. Post effects: bloom, blur, color correction, sun rays, depth of field. Shadows: global shadows.",
    Callback = function(v)
        Mods.NR_SEL = {}
        for name, on in pairs(type(v) == "table" and v or {}) do if on then Mods.NR_SEL[name] = true end end
        if Mods.NoRender.on then Mods.NoRender:setEnabled(false); Mods.NoRender:setEnabled(true) end
    end,
})

Mods.Unlock = Feature("UnlockAll")
do
    local U = { bypass = false }
    local function ups(f)
        local g = getupvalues or (debug and debug.getupvalues)
        if type(g) ~= "function" or type(f) ~= "function" then return {} end
        local ok, t = pcall(g, f)
        return ok and type(t) == "table" and t or {}
    end
    local function owned(name)
        U.bypass = true
        local ok, ids = pcall(function() return U.inv.Client:FindItems("Sword", name) end)
        U.bypass = false
        return ok and type(ids) == "table" and ids[1] or nil
    end
    local function nameOf(arg)
        local n = arg:match("^virtual_%d+_Sword_(.+)$")
        if n then return n end
        local ok, it = pcall(function() return U.inv.Client:GetItem("Sword", arg) end)
        return ok and type(it) == "table" and type(it.Name) == "string" and it.Name or arg
    end
    local function equipState()
        if not U.api then return nil end
        for _, v in pairs(ups(rawget(U.api, "GetSwordData") or U.api.GetSwordData)) do
            local st = type(v) == "table" and rawget(v, "Sword")
            if type(st) == "table" and rawget(v, "Booth") ~= nil and type(st.Set) == "function" and type(st.Get) == "function" then return st end
        end
    end
    local function refresh()
        if not (U.api and U.inv) then return end
        local C = U.inv.Client
        for kind, fn in pairs({ Sword = "GetSwordData", Explosion = "GetExplosionData", Ability = "GetAbilityData", Emote = "GetEmoteData", Booth = "GetBoothData" }) do
            for _, cache in pairs(ups(rawget(U.api, fn) or U.api[fn])) do
                local e = type(cache) == "table" and select(2, next(cache)) or nil
                if type(e) == "table" and rawget(e, "OwnedCopies") and rawget(e, "ParsedItemKey") then
                    for key, d in pairs(cache) do
                        pcall(function()
                            local n = #C:FindItemsWithKey(kind, key)
                            d.OwnedCopies:Set(n)
                            U.api:GetItemBaseOwnedState(kind, C:KeyToItem(key).Name):SetTag(key, n > 0)
                        end)
                    end
                end
            end
        end
    end
    local function pick(name)
        if not Mods.Unlock.on or name == "" then return end
        Mods.Skin.name = name
        Mods.saveSkin()
        pcall(function() Options.SkinName:SetValue(name) end)
        if not Mods.SkinChanger.on then pcall(function() Toggles.SkinChanger:SetValue(true) end) end
        if not Mods.SkinChanger.on then Mods.SkinChanger:setEnabled(true) end
        Mods.SkinChanger.apply()
        pcall(function() equipState():Set({ Name = name, Id = ("virtual_%d_Sword_%s"):format(LocalPlayer.UserId, name) }) end)
        Notify("Unlock All", "Sword: " .. name, 2)
    end
    local function route(remote, arg)
        if type(arg) ~= "string" then return nil end
        local kind = remote:match("RequestEquip(%a+)$")
        if kind == "Sword" or kind == "SwordSkin" then
            local name = nameOf(arg)
            local real = owned(name)
            task.spawn(pick, name)
            if real then return "pass", real end
            return "stop", true
        end
        if kind and arg:sub(1, 8) == "virtual_" then return "stop", false end
        return nil
    end
    local function body(self, ...)
        if Mods.Unlock.on and getnamecallmethod() == "InvokeServer" and typeof(self) == "Instance" and self.ClassName == "RemoteFunction" then
            local ok, act, v = pcall(route, self.Name, ...)
            if ok and act == "stop" then return v end
            if ok and act == "pass" then return U.old(self, v, select(2, ...)) end
        end
        return U.old(self, ...)
    end
    local function current()
        local ok, mt = pcall(getrawmetatable, game)
        return ok and type(mt) == "table" and rawget(mt, "__namecall") or nil
    end
    local function hook()
        if not (hookmetamethod and getnamecallmethod) then return false end
        if U.fn and current() == U.fn then return true end
        local f = newcclosure and newcclosure(body) or body
        local ok, old = pcall(hookmetamethod, game, "__namecall", f)
        if ok and type(old) == "function" then U.old, U.fn = old, f; return true end
        return false
    end
    local function unhook()
        if U.fn and U.old and current() == U.fn then pcall(hookmetamethod, game, "__namecall", U.old) end
        U.fn = nil
    end
    function Mods.Unlock.start()
        local token = Mods.Unlock._token
        task.spawn(function()
            local ok = pcall(function()
                local sh = ReplicatedStorage:WaitForChild("Shared", 10)
                U.inv = U.inv or require(sh:WaitForChild("Inventory", 10))
                U.vi = U.vi or require(sh.Inventory:WaitForChild("Internal", 10):WaitForChild("VirtualInventory", 10))
            end)
            if not ok or not U.vi or not U.inv or not Mods.Unlock:alive(token) then
                if Mods.Unlock:alive(token) then Notify("Unlock All", "Couldn't load the game's inventory.", 4) end
                return
            end
            pcall(function() U.api = U.api or require(ReplicatedStorage.Controllers.UI.ShopControllerAPI) end)
            U.real = U.real or U.vi.IsEnabledFor
            local set = pcall(rawset, U.vi, "IsEnabledFor", function(self, p, ...)
                if Mods.Unlock.on and not U.bypass and (p == nil or p == LocalPlayer) then return true end
                return U.real(self, p, ...)
            end)
            if not set then Notify("Unlock All", "Couldn't patch the inventory.", 4); return end
            if not hook() then Notify("Unlock All", "No namecall hook: equips won't switch the skin.", 4) end
            refresh()
            Mods.Unlock:loop(1, function() if Parry.hookState() == "down" then hook() end end)
        end)
    end
    function Mods.Unlock.stop()
        if U.vi and U.real then pcall(rawset, U.vi, "IsEnabledFor", U.real) end
        unhook()
        task.spawn(function()
            refresh()
            pcall(function() equipState():Set(U.api:GetEquippedItem("Sword")) end)
        end)
    end
end

Gui.UA = Gui.Tabs.Misc:AddRightGroupbox("Unlock All", "unlock")
Gui.UA:AddToggle("UnlockAll", { Text = "Unlock all", Default = false,
    Tooltip = "Shows every item as owned in your inventory (only you see it). Equipping a sword puts it on with the skin changer; other items stay visual.",
    Callback = function(v) Mods.Unlock:setEnabled(v) end })

local function set(label, text) if label then pcall(function() label:SetText(text) end) end end
StatusHook = function(s, armed)
    if not s then
        set(Gui.CapLabel, armed and "Capture: asleep in the lobby -- wakes when you join a round" or "Capture: off (turn on auto parry or spam)")
        set(Gui.SpamRateLabel, "Actual: 0/s"); set(Gui.ClashLabel, "Status: off")
        return
    end
    Parry.drainLog()
    if not Library.Toggled then return end
    set(Gui.CapLabel, "Capture: " .. s.armed)
    set(Gui.SpamRateLabel, ("Actual: %d/s of %d (%s, %s)"):format(math.floor(s.rate + 0.5), math.floor((s.target or 0) + 0.5), tostring(s.speed_mode), s.manual))
    set(Gui.ClashLabel, "Status: " .. s.clash)
    if Gui.TimingLabel then set(Gui.TimingLabel, table.concat(Parry.timingLines(), "\n")) end
end
UiTick = function(rate) Orb.tick(rate) end

Mods.DebugCfg = { Size = 1 }
Mods.DebugUI = Feature("DebugUI")
function Mods.DebugUI.start()
    Parry.DBG.on = true
    local W0, H0 = 360, 330
    local gui = Instance.new("ScreenGui"); gui.Name = randName(); gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 1000
    local frame = Instance.new("Frame"); frame.Size = UDim2.fromOffset(W0, H0); frame.Position = UDim2.fromOffset(16, 90)
    frame.BackgroundColor3 = Color3.fromRGB(12, 12, 16); frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0; frame.Active = true; frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(70, 70, 85)
    local scale = Instance.new("UIScale", frame)
    local function label(y, h, size, font)
        local l = Instance.new("TextLabel", frame)
        l.Position, l.Size = UDim2.fromOffset(8, y), UDim2.new(1, -16, 0, h)
        l.BackgroundTransparency = 1; l.TextColor3 = Color3.fromRGB(235, 235, 240)
        l.Font = font or Enum.Font.Code; l.TextSize = size or 12
        l.TextXAlignment = Enum.TextXAlignment.Left; l.TextYAlignment = Enum.TextYAlignment.Top
        l.TextWrapped = true; l.RichText = false; l.Text = ""
        return l
    end
    local title = label(5, 16, 13, Enum.Font.GothamBold); title.Text = "Debug  (drag to move)"
    local live = label(24, 128)
    local sep = Instance.new("Frame", frame); sep.Position, sep.Size = UDim2.fromOffset(8, 155), UDim2.new(1, -16, 0, 1)
    sep.BackgroundColor3 = Color3.fromRGB(70, 70, 85); sep.BorderSizePixel = 0
    local events = label(160, H0 - 166)
    events.ClipsDescendants = true
    hideGui(gui)
    Mods.DebugUI:own(gui)

    local function fit()
        local cam = Workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        local s = math.min(Mods.DebugCfg.Size, (vp.X * 0.96) / W0, (vp.Y * 0.92) / H0)
        scale.Scale = math.max(s, 0.3)
    end
    local function place(x, y)
        local cam = Workspace.CurrentCamera
        local vp, sz = cam and cam.ViewportSize or Vector2.new(800, 600), frame.AbsoluteSize
        x = math.clamp(x, 0, math.max(vp.X - sz.X, 0))
        y = math.clamp(y, 0, math.max(vp.Y - sz.Y, 0))
        frame.Position = UDim2.fromOffset(x, y)
    end
    local drag
    local function grab(i)
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            drag = { at = i.Position, from = frame.AbsolutePosition, input = t }
        end
    end
    Mods.DebugUI:connect(frame.InputBegan, grab)
    for _, c in ipairs(frame:GetChildren()) do
        if c:IsA("GuiObject") then Mods.DebugUI:connect(c.InputBegan, grab) end
    end
    Mods.DebugUI:connect(UserInputService.InputChanged, function(i)
        if not drag then return end
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
            local d = i.Position - drag.at
            place(drag.from.X + d.X, drag.from.Y + d.Y)
        end
    end)
    Mods.DebugUI:connect(UserInputService.InputEnded, function(i)
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then drag = nil end
    end)

    Mods.DebugUI:loop(0.1, function()
        fit()
        if not drag then place(frame.AbsolutePosition.X, frame.AbsolutePosition.Y) end
        local ok, lines = pcall(Parry.debugLines)
        live.Text = ok and table.concat(lines, "\n") or ("debug error: " .. tostring(lines))
        local now, out, list = os.clock(), {}, Parry.DBG.list
        for i = #list, math.max(#list - 13, 1), -1 do
            local e = list[i]
            out[#out + 1] = ("%5.1fs  %s"):format(now - e.t, e.text)
        end
        events.Text = #out > 0 and table.concat(out, "\n") or "(no events yet -- they show here as they happen)"
    end)
end
function Mods.DebugUI.stop() Parry.DBG.on = false end

Gui.DBGTM = Gui.Tabs.Debug:AddRightGroupbox("Timing", "timer")
Gui.TimingLabel = Gui.DBGTM:AddLabel("Timing: turn on auto parry and play a few parries.", true)
Gui.DBGTM:AddLabel("Lands + = the ball came later than predicted (firing early); - = sooner (firing late). Not taken = the server ignored a remote parry (bad capture).", true)
Gui.DBGB = Gui.Tabs.Debug:AddLeftGroupbox("Debug overlay", "bug")
Gui.DBGB:AddToggle("DebugUI", {
    Text = "Debug overlay", Default = false,
    Tooltip = "On-screen panel: live ping / reach / feed / capture / gate / the ball on you and the last decision, plus the newest events (retargets, fires, landed / missed, their parries, captures).",
    Callback = function(v) Mods.DebugUI:setEnabled(v) end,
})
Gui.DBGB:AddSlider("DebugUISize", {
    Text = "Size", Default = 100, Min = 50, Max = 200, Rounding = 0, Suffix = "%",
    Tooltip = "It never gets bigger than the screen, whatever this says.",
    Callback = function(v) Mods.DebugCfg.Size = v / 100 end,
})
Gui.DBGB:AddButton({ Text = "Clear events", Func = function() table.clear(Parry.DBG.list) end })

Mods.PcMoveCfg = { Snap = true, bind = nil, cur = nil }
Mods.PcMove = Feature("PcMove")
function Mods.PcMove.start()
    local name = randName()
    Mods.PcMoveCfg.bind = name
    pcall(function()
        RunService:BindToRenderStep(name, Enum.RenderPriority.Input.Value + 1, function()
            if not isLive() then return end
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then return end
            local md = hum.MoveDirection
            local flat = Vector3.new(md.X, 0, md.Z)
            if flat.Magnitude < 0.05 then Mods.PcMoveCfg.cur = nil; return end
            local dir = flat.Unit
            if Mods.PcMoveCfg.Snap then
                local cam = Workspace.CurrentCamera
                if cam then
                    local f = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
                    local r = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
                    if f.Magnitude > 0.01 and r.Magnitude > 0.01 then
                        f, r = f.Unit, r.Unit
                        local a, step = math.atan2(dir:Dot(r), dir:Dot(f)), math.pi / 4
                        local function off(idx)
                            local d = (a - idx * step + math.pi) % (2 * math.pi) - math.pi
                            return math.abs(d)
                        end
                        local best, bestD
                        for idx = 0, 7 do
                            local d = off(idx) - (idx % 2 == 0 and math.rad(8) or 0)
                            if not bestD or d < bestD then best, bestD = idx, d end
                        end
                        local cur = Mods.PcMoveCfg.cur
                        if cur and cur ~= best and off(cur) < step / 2 + math.rad(15) then best = cur end
                        Mods.PcMoveCfg.cur = best
                        local sa = best * step
                        dir = f * math.cos(sa) + r * math.sin(sa)
                    end
                end
            end
            hum:Move(dir, false)
        end)
    end)
end
function Mods.PcMove.stop()
    if Mods.PcMoveCfg.bind then pcall(function() RunService:UnbindFromRenderStep(Mods.PcMoveCfg.bind) end) end
    Mods.PcMoveCfg.bind = nil
end

Gui.DBGM = Gui.Tabs.Debug:AddLeftGroupbox("Movement", "gamepad-2")
Gui.DBGM:AddToggle("PcMovement", {
    Text = "PC-style movement", Default = false,
    Tooltip = "Mobile thumbstick moves like WASD: any tilt is full walk speed (no slow part-tilt walking).",
    Callback = function(v) Mods.PcMove:setEnabled(v) end,
})
Gui.DBGM:AddToggle("PcMovementSnap", {
    Text = "Snap to 8 directions", Default = true,
    Tooltip = "Like W, A, S, D and the diagonals: the stick's direction rounds to the nearest of 8, relative to the camera.",
    Callback = function(v) Mods.PcMoveCfg.Snap = v end,
})

Gui.DBGT = Gui.Tabs.Debug:AddRightGroupbox("Experimental", "flask-conical")
Gui.DBGT:AddButton({
    Text = "Capture without parrying (this server)",
    Tooltip = "Arms auto parry with NO parry and NO hook: reads the game's parry sender (require + upvalue reads, raw only) and asks its own token function for the key on a game-env thread. For this server only. Experimental -- if it ever kicks, drop it.",
    Func = function()
        task.spawn(function()
            local ok, ok2, why = pcall(Parry.hooklessCapture)
            if ok and ok2 then
                Notify("Hookless capture", "Armed with no parry -- auto parry is ready for this server.", 5)
            else
                Notify("Hookless capture", "Didn't work: " .. tostring(ok and why or ok2) .. " (details in the debug overlay / log)", 6)
            end
        end)
    end,
})
Gui.DBGT:AddToggle("FastRetarget", {
    Text = "Fast retarget", Default = false,
    Tooltip = "Auto parry decides the instant the ball turns to you, before its new direction arrives -- but only fires when it should: it's due at your Accuracy, and even a curve twice as long would still land inside the parry (or it's fire-or-die close). Otherwise the normal checks take it a moment later. In a 1v1 the other player's parry counts as the retarget (it can only be coming to you).",
    Callback = function(v) Parry.S.fast_retarget = v end,
})
Gui.DBGB:AddLabel("Times in the event list are seconds ago. 'soonest' = the earliest the ball can land, 'lead' = when auto parry fires, 'reach' = your ping delay.", true)

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

if getgenv().BBStop == 3 then Flight.write("BBStop 3: whole menu + config loaded, stopping before the loaded notice") end
Notify("Blade Ball", "Rewrite " .. SCRIPT_VERSION .. " loaded. " .. (touchUI and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)


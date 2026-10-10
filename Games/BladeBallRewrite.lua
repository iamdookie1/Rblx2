-- Blade Ball -- clean rewrite (work in progress)
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else. It does not connect to
--   any game RemoteEvent, connect any RunService signal, install any hook, read
--   any service in a loop, require any game module, or resolve the game's remote
--   folder. Every feature acquires its connections/hooks only when it is turned
--   ON (Feature:start) and releases them fully when turned OFF (Feature:stop).
--   With every feature off the script holds zero game footprint -- the same
--   state as the UI library's own example, which the anti-cheat does not kick.
--   The old script's idle "nothing on" kick came from things it ran at load;
--   the rewrite runs nothing at load.
--
-- Installment 1: foundation + feature framework + Auto Jump.
-- Installment 2: parry capture core + Auto Parry (this file). The capture/send
--   crypto is ported faithfully from the proven script; its ACTIVATION is gated,
--   so hooks and remote listeners exist only while Auto Parry is on. The parry
--   trigger here is the straight-line baseline; the anti-curve prediction,
--   target modes, accuracy, pre-parry and clash come in later installments.

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.2"

-- ---------------------------------------------------------------------------
-- Single instance.
-- ---------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
genv.__BladeBallInstance = INSTANCE
local function is_live() return genv.__BladeBallInstance == INSTANCE end

-- ---------------------------------------------------------------------------
-- Services (references only -- touches nothing in the game).
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

-- ---------------------------------------------------------------------------
-- Feature framework. start() acquires connections/hooks, stop()/release() drop
-- ALL of them. "All features off" == UI-only footprint, by construction.
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
-- PARRY CAPTURE CORE
-- ===========================================================================
-- Everything in this block only DEFINES functions and a state table. Nothing
-- here touches the game until Parry.activate() runs (called by the Auto Parry
-- feature's start). Parry.deactivate() unhooks and forgets, leaving no footprint.
local Parry = {}
do
    local me = LocalPlayer.Name
    local Core = { cap = nil, pending = nil, misses = 0, interp = 0.14, told = false }
    Parry.Core = Core
    local G = { until_t = 0, m1 = false, m1_at = 0 } -- parry lockout gate
    local frame_dt = 1 / 60

    -- game-tree handles, resolved on activate (never at load)
    local Alive, Remotes

    -- ---------- ping ----------
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

    local function getRoot()
        local char = LocalPlayer.Character
        return char and char.PrimaryPart
    end

    -- ---------- parry gate (mirrors the game's own client parry conditions) ----------
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

    -- ---------- the window the game itself put in the captured packet ----------
    local function parry_window()
        local cw = Core.cap and Core.cap.win
        if cw and cw > 0 then return cw, 1.3 * math.min(cw / 0.5, 1) end
        return 0.5, 1.3
    end
    local function lockout_margin()
        return math.clamp(0.02 + frame_dt + 0.03, 0.06, 0.15)
    end
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

    -- ---------- screen points / aim (built the way the game's parry handler does) ----------
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
    local packet_cache = { at = -1, points = nil, aim = nil }
    local function packet_parts(cam)
        local now = clock_()
        if now - packet_cache.at > PACKET_TTL then
            packet_cache.points = (build_screen_points(cam))
            packet_cache.aim = aim_point(cam)
            packet_cache.at = now
        end
        return packet_cache.points, packet_cache.aim
    end

    -- ---------- the capture hook (isolated bodies, no footprint) ----------
    -- Ported verbatim from the proven script: the hook bodies run on another
    -- thread, in an empty env, under a game chunk name, and never call our code.
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

    -- learn / inspect: turn a captured send into Core.cap (remote, hash, uid, key)
    local JOB_ID = game.JobId
    local function learn(remote, hash, uid, token, a4, t)
        local text = tostring(math.floor(t * 100))
        if #token ~= #text then return end
        local key = {}
        for i = 1, #text do key[i] = bit32.bxor(string.byte(token, i), (string.byte(text, i) + i) % 256) end
        Core.cap = { remote = remote, hash = hash, uid = uid, key = key, len = #text,
            ball2 = typeof(a4) == "CFrame", win = type(a4) == "number" and a4 or nil }
        Core.misses, Core.pending = 0, nil
        Core.told = false
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

    -- Up for one capture press (<=0.35s). Our thread watches the box every frame.
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

    -- press block (F) -- forces the game to send one real parry we read the packet from
    local last_press = 0
    local function pressBlockKey()
        if not is_live() then return false end
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
        end)
        return true
    end
    -- capture press cadence: F, 1s after you can parry, then every 1.4s until armed
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
        if arm() then
            dry_presses = dry_presses + 1
            pressBlockKey()
            gate_start("capture press")
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

    -- send a parry packet. "sent" / "unarmed" / "blocked".
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

    -- ---------- ball tracking ----------
    local tracked = setmetatable({}, { __mode = 'k' })
    local function ball_velocity(ball)
        local z = ball:FindFirstChild('zoomies')
        return z and z.VectorVelocity or ball.AssemblyLinearVelocity
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
    local function get_ball_state(ball)
        local st = tracked[ball]
        if st then return st end
        st = { target = ball:GetAttribute('target'), parried = false, parry_until = 0 }
        tracked[ball] = st
        ball:GetAttributeChangedSignal('target'):Connect(function()
            local new = ball:GetAttribute('target')
            st.target = new
            if new ~= me then st.parried = false end
        end)
        return st
    end

    -- ---------- the trigger (straight-line baseline) ----------
    -- Fire when the ball on us will arrive within `lead` seconds (latency + view
    -- lag + a frame of margin), or is already inside close range. One parry per
    -- pass until the retry delay, like the proven core.
    local CLOSE_RANGE = 20
    local function decide(ball, st, root, now)
        if st.parried and now < st.parry_until then return end
        if st.parried then st.parried = false end
        local bpos = ball.Position
        local dist = (bpos - root.Position).Magnitude
        local speed = ball_velocity(ball).Magnitude
        local eta = dist / math.max(speed, 1)
        local lead = ping_s() + (Core.interp or 0.14) + lockout_margin()
        if dist <= CLOSE_RANGE or eta <= lead then
            if send(false) == "sent" then
                st.parried, st.parry_until = true, now + 1.0
            end
        end
    end

    local function step(dt)
        if dt then frame_dt = math.clamp(dt, 1 / 240, 0.1) end
        if not is_live() then return end
        local root = getRoot()
        if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return end
        local now = clock_()
        for _, ball in ipairs(get_live_balls()) do
            local st = get_ball_state(ball)
            if st.target == me then decide(ball, st, root, now) end
        end
    end
    Parry.step = step

    -- housekeeping: prime the capture until armed. Runs each frame while active.
    local function housekeeping()
        if not is_live() then return end
        if not Core.cap then prime_remote() end
    end
    Parry.housekeeping = housekeeping

    -- ---------- activate / deactivate (the only things that touch the game) ----------
    function Parry.activate()
        Alive = Alive or Workspace:FindFirstChild("Alive") or Workspace:WaitForChild("Alive", 5)
        Remotes = Remotes or ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 5)
        -- discover the shared FireServer function off a remote the game already
        -- has (creates no instance).
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
        return Remotes ~= nil
    end
    function Parry.deactivate()
        pcall(unhook)
        Core.cap, Core.pending, Core.misses = nil, nil, 0
        G.until_t, can_since, dry_presses = 0, nil, 0
    end

    -- listeners the feature wires on start (so none exist at idle)
    function Parry.remotes() return Remotes end
    Parry.onParrySuccess = function()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.until_t = 0
        Core.pending, Core.misses = nil, 0
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
-- FEATURE: Auto Parry. On: resolve remotes, wire the ParrySuccess/M1Stop
-- listeners, run the capture priming + parry step every frame. Off: unhook and
-- disconnect everything.
-- ---------------------------------------------------------------------------
local AutoParry = Feature("AutoParry")
function AutoParry.start()
    if not Parry.activate() then
        Library:Notify({ Title = "Blade Ball", Description = "Couldn't find the game's Remotes.", Time = 4 })
        return
    end
    local Remotes = Parry.remotes()
    -- parry success / M1 listeners (connected only while on)
    pcall(function() AutoParry:connect(Remotes.ParrySuccess.OnClientEvent, Parry.onParrySuccess) end)
    pcall(function() AutoParry:connect(Remotes.NoobParryHappened.OnClientEvent, function()
        task.wait(0.11); Parry.onParrySuccess()
    end) end)
    pcall(function() AutoParry:connect(Remotes.M1Stop.Event, Parry.onM1Stop) end)
    -- the per-frame work: prime until captured, then parry
    AutoParry:connect(RunService.PreSimulation, function(dt)
        Parry.housekeeping()
        Parry.step(dt)
    end)
end
function AutoParry.stop()
    Parry.deactivate()
end

local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {
    Text = "Auto parry",
    Default = false,
    Callback = function(v) AutoParry:setEnabled(v) end,
}):AddKeyPicker("AutoParryKey", {
    Default = "None",
    Mode = "Toggle",
    SyncToggleState = true,
    Text = "Auto parry",
})
AP:AddDropdown("CaptureHook", {
    Values = { "oth", "Namecall", "FireServer", "Both" },
    Default = "oth",
    Text = "Capture hook",
    Tooltip = "How the first parry packet is captured. 'oth' (Delta) is the stealthiest.",
    Callback = function(v) getgenv().CaptureHook = v end,
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
}):AddKeyPicker("AutoJumpKey", {
    Default = "J",
    Mode = "Toggle",
    SyncToggleState = true,
    Text = "Auto jump",
})

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

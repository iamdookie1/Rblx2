--// szm's customs ---------------------------------------------------------------------------------
-- place 122247782020804 (game 10772578775), built against version 974. Built on Ui3.
-- Dump: Dumps/SzmsCustomsDump.txt. How the game works, from its own client scripts:
--   Ball     Parts tagged "Wisp" in workspace (server ball). Attributes are renamed: Yarrow = the match it
--            belongs to ("FFA" when none), Zephyr = a signed owner slot, Lumen = parry window, Maple = parry
--            cooldown. A client-drawn copy of the ball is what you see (BallRenderer).
--   Parry    PlayerClient builds the whole parry packet itself: a per-session remote name (the "route", sent
--            by SettingsSync), your camera CFrame, a signed (pitch, yaw, server time) sample and whether the
--            ball is yours. So this script never forges it: it fires PlayerClient.ParryRequest, a
--            BindableEvent the game listens to itself (Fire(true) aims at the cursor, Fire(false) at the
--            camera). The game's own gate does the rest: nothing is sent until LocalDoomedAt (set by
--            BallRenderer when the ball is inside its hit range) has passed, and not while ParryCooldownEnd
--            is in the future. "Parry late for a bigger curve" is the game's own tip.
--   Helpers  The settings table PlayerClient keeps as an upvalue has slot(ball) (the UserId the ball is
--            on: it's yours when that equals your UserId) and active(ball) (rejects decoy balls). They are
--            found through the ParryRequest connection's upvalues; without them it falls back to the tag.
--   Abilities PlayerScripts.Dash listens to DashRequest: Dash runs locally, every other ability is
--            UseAbility:FireServer(). DashReadyAt (os.clock) says when it is ready.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__SzmUnload then
    pcall(Genv.__SzmUnload)
end
Genv.__SzmRun = (Genv.__SzmRun or 0) + 1
local RUN = Genv.__SzmRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__SzmRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local Settings = {
    -- parry
    AutoParry = false, Trigger = false, Spam = false,
    ParryTiming = "Middle", LeadMs = 150,
    ParryMethod = "Forged remote (like Blade Ball)", AimMode = "Cursor", Jitter = 0, Animation = true,
    SpamMode = "Smart (clash)", SpamEta = 300, CheckCooldown = true, SpamRate = 30, SpamRange = 60,
    -- abilities
    AutoAbility = false, AbilityWhen = "Ball on me + parry on cooldown", AbilityRange = 40, IncludeDash = false,
    -- esp
    EspBall = true, EspBallLine = true, EspPlayers = false, EspTracers = false, EspDistance = 1500, PredictTime = 0.5,
    -- hud
    Hud = true,
    -- visuals
    AntiAfk = true, FpsOn = false, FpsCap = 240, NoFog = false, NoPost = false, FovOn = false, Fov = 90, HideVfx = false,
    -- movement
    SpeedOn = false, WalkSpeed = 24, JumpOn = false, JumpPower = 60, InfJump = false,
    Fly = false, FlySpeed = 70, Noclip = false, MoveInMatch = false,
}

local Connections, Cleanups = {}, {}
local function connect(signal, fn)
    local c = signal:Connect(fn)
    Connections[#Connections + 1] = c
    return c
end
local function onCleanup(fn)
    Cleanups[#Cleanups + 1] = fn
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "szm's customs", Description = text, Time = seconds or 3 })
end
local function myChar()
    return LocalPlayer.Character
end
local function myHum()
    local c = myChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function myRoot()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function myMatch()
    return LocalPlayer:GetAttribute("Match")
end
local function inMatch()
    return myMatch() ~= nil
end
local function aliveInMatch()
    local h = myHum()
    return inMatch() and h ~= nil and h.Health > 0 and LocalPlayer:GetAttribute("DuelOut") ~= true
end

--// Game hooks \\--
local Game = { ev = nil, dashEv = nil, S = nil, myBall = nil, parry = nil, swing = nil, info = "looking for the game's parry code" }
local function findEvent(scriptName, eventName)
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    local s = ps and ps:FindFirstChild(scriptName)
    return s and s:FindFirstChild(eventName)
end
local function dive(fn, depth, seen, out)
    if type(fn) ~= "function" or depth < 0 or seen[fn] then
        return
    end
    seen[fn] = true
    local ok, ups = pcall(debug.getupvalues, fn)
    if not ok or type(ups) ~= "table" then
        return
    end
    local n = 0
    for _ in pairs(ups) do
        n = n + 1
    end
    for _, v in pairs(ups) do
        if type(v) == "table" then
            if type(rawget(v, "slot")) == "function" and type(rawget(v, "active")) == "function" then
                out.S = v
                -- the parry function has the most upvalues of the ones that hold the settings table
                if n > (out.parryN or 0) then
                    out.parry, out.parryN = fn, n
                end
                if n < (out.smallN or math.huge) then
                    out.small, out.smallN = fn, n
                end
            end
        elseif type(v) == "function" then
            local okn, name = pcall(debug.info, v, "n")
            if okn and name == "myBall" then
                out.myBall = v
            elseif okn and name == "swing" then
                out.swing = v
            end
            dive(v, depth - 1, seen, out)
        end
    end
end
local function discover()
    if not Game.ev or not Game.ev.Parent then
        Game.ev = findEvent("PlayerClient", "ParryRequest")
    end
    if not Game.dashEv or not Game.dashEv.Parent then
        Game.dashEv = findEvent("Dash", "DashRequest")
    end
    if Game.S and Game.S.slot then
        return
    end
    if not Game.ev then
        Game.info = "waiting for PlayerClient.ParryRequest"
        return
    end
    local out = {}
    if typeof(getconnections) == "function" then
        local ok, conns = pcall(getconnections, Game.ev.Event)
        if ok and type(conns) == "table" then
            for _, c in pairs(conns) do
                local fn = c.Function
                if type(fn) == "function" then
                    dive(fn, 4, {}, out)
                end
            end
        end
    end
    if out.S then
        Game.S, Game.parry, Game.swing = out.S, out.parry, out.swing
        Game.myBall = out.myBall or (out.small ~= out.parry and out.small) or nil
        Game.info = "hooked the game's own ball helpers"
    else
        Game.info = "ParryRequest found, ball helpers not (using the Wisp tag)"
    end
end
task.spawn(function()
    while alive() do
        pcall(discover)
        task.wait((Game.S and Game.S.slot) and 3 or 1)
    end
end)

--// Balls and players \\--
local Track = setmetatable({}, { __mode = "k" })
local function ballsInMatch()
    local out = {}
    local match = myMatch()
    for _, b in ipairs(CollectionService:GetTagged("Wisp")) do
        if b:IsA("BasePart") and b.Parent == Workspace and (b:GetAttribute("Yarrow") or "FFA") == match then
            local ok = true
            if Game.S then
                local okA, r = pcall(Game.S.active, b)
                ok = okA and r == true
            end
            if ok then
                out[#out + 1] = b
            end
        end
    end
    return out
end
local function ballOwnerId(b)
    if not Game.S then
        return nil
    end
    local ok, id = pcall(Game.S.slot, b)
    if ok and type(id) == "number" and id ~= 0 then
        return id
    end
    return nil
end
local function nameOf(id)
    if not id then
        return "?"
    end
    local p = Players:GetPlayerByUserId(id)
    if p then
        return p.DisplayName
    end
    for _, m in ipairs(CollectionService:GetTagged("MatchBot")) do
        if m:GetAttribute("UserId") == id then
            return m.Name
        end
    end
    return tostring(id)
end
-- Harbor = "leg|fromUserId|toUserId|travel": the ball's current hit between two players, only set during a
-- clash (BallRenderer's updateClash). A new value is a new hit.
local function readLegs(b, t, now)
    local h = b:GetAttribute("Harbor")
    if h ~= t.harbor then
        t.harbor = h
        if type(h) == "string" and h ~= "" then
            local parts = string.split(h, "|")
            t.legFrom, t.legTo = tonumber(parts[2]), tonumber(parts[3])
            t.legAt = now
        else
            t.legFrom, t.legTo = nil, nil
        end
    end
end
local function sample(b, now)
    local t = Track[b]
    if not t then
        t = { pos = b.Position, t = now, vel = Vector3.new(0, 0, 0), speed = 0 }
        Track[b] = t
        readLegs(b, t, now)
        return t
    end
    readLegs(b, t, now)
    local dt = now - t.t
    if dt > 0.004 then
        local v = (b.Position - t.pos) / dt
        t.vel = t.vel:Lerp(v, 0.35)
        t.speed = t.vel.Magnitude
        t.pos, t.t = b.Position, now
    end
    return t
end
-- the ball that is on you (or, without the game's helpers, the nearest one)
local function ballOnMe(list)
    local root = myRoot()
    local best, bd = nil, math.huge
    for _, b in ipairs(list) do
        if Game.S then
            if ballOwnerId(b) == LocalPlayer.UserId then
                return b
            end
        elseif root then
            local d = (b.Position - root.Position).Magnitude
            if d < bd then
                best, bd = b, d
            end
        end
    end
    return best
end
local function ballWindow(b)
    local w = b and b:GetAttribute("Lumen")
    if type(w) ~= "number" or w <= 0 then
        w = 0.4
    end
    return w
end
-- who you can hit the ball at: players and bots in your match, not out, not your side
local function enemies()
    local out = {}
    local match = myMatch()
    local mySide = LocalPlayer:GetAttribute("DuelSide")
    local function consider(inst, attrHolder)
        if attrHolder:GetAttribute("Match") ~= match or attrHolder:GetAttribute("DuelOut") == true then
            return
        end
        local side = attrHolder:GetAttribute("DuelSide")
        if mySide ~= nil and side == mySide then
            return
        end
        local char = inst:IsA("Player") and inst.Character or inst
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hum and hrp and hum.Health > 0 then
            out[#out + 1] = { name = inst:IsA("Player") and inst.DisplayName or inst.Name, hrp = hrp, hum = hum }
        end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            consider(p, p)
        end
    end
    for _, m in ipairs(CollectionService:GetTagged("MatchBot")) do
        if m:IsA("Model") then
            consider(m, m)
        end
    end
    return out
end

--// Parry \\--
-- The parry is one RemoteEvent whose name is a per-session "route" (settings.route()). PlayerClient fires it as
--   FireServer(cameraCFrame, ballIsMine, pickCFrame, settings.sample(pitch, yaw, serverTime), source, touch)
-- and nothing on the client stops a press before the ball is in range (only your cooldown), so it is built here
-- the same way and sent directly. pickCFrame is the ray the ball is curved along: it is where the aim options act.
local Log = {}
local function addLog(ctx)
    ctx.t = os.clock()
    Log[#Log + 1] = ctx
    if #Log > 6 then
        table.remove(Log, 1)
    end
end
local Parry = { count = 0, landed = 0, sent = 0, how = "-", lastTry = 0, blockUntil = 0, info = "off", ping = 0.05, eta = nil }
connect(LocalPlayer:GetAttributeChangedSignal("ParryCooldownEnd"), function()
    if (LocalPlayer:GetAttribute("ParryCooldownEnd") or 0) > Workspace:GetServerTimeNow() then
        Parry.count = Parry.count + 1
    end
end)
task.spawn(function()
    local fx = ReplicatedStorage:WaitForChild("ParryFX", 30)
    if fx and alive() then
        connect(fx.OnClientEvent, function(char)
            if char == LocalPlayer.Character then
                Parry.landed = Parry.landed + 1
                for i = #Log, 1, -1 do
                    if not Log[i].result and os.clock() - Log[i].t < 1.5 then
                        Log[i].result = "landed"
                        break
                    end
                end
            end
        end)
    end
end)
task.spawn(function()
    while alive() do
        local ok, p = pcall(function()
            return LocalPlayer:GetNetworkPing()
        end)
        if ok and type(p) == "number" then
            Parry.ping = math.clamp(p, 0, 1)
        end
        task.wait(1)
    end
end)
local function pickTarget(mode)
    local list = enemies()
    if #list == 0 then
        return nil
    end
    local root, cam = myRoot(), Workspace.CurrentCamera
    if mode == "Random player" then
        return list[math.random(1, #list)]
    end
    local best, bs = nil, math.huge
    for _, e in ipairs(list) do
        local s
        if mode == "Lowest health" then
            s = e.hum.Health
        elseif mode == "Closest to crosshair" and cam then
            local to = e.hrp.Position - cam.CFrame.Position
            s = math.acos(math.clamp(cam.CFrame.LookVector:Dot(to.Unit), -1, 1))
        else
            s = root and (e.hrp.Position - root.Position).Magnitude or 0
        end
        if s < bs then
            best, bs = e, s
        end
    end
    return best
end
-- what the game calls the source of a press (your Parry key's name)
local Keybinds, srcAt, srcCached = nil, -10, "F"
local function parrySource()
    if os.clock() - srcAt < 3 then
        return srcCached
    end
    srcAt = os.clock()
    if Keybinds == nil then
        local ok, m = pcall(function()
            return require(ReplicatedStorage:WaitForChild("Shared", 5):WaitForChild("Keybinds", 5))
        end)
        Keybinds = ok and m or false
    end
    if Keybinds then
        for slot = 1, (Keybinds.SLOTS or 2) do
            local ok, k = pcall(Keybinds.Get, "Parry", slot)
            if ok and typeof(k) == "EnumItem" and k.EnumType == Enum.KeyCode then
                local okn, name = pcall(Keybinds.Name, k)
                srcCached = (okn and type(name) == "string") and name or k.Name
                return srcCached
            end
        end
    end
    return srcCached
end
local function pickCFrame(cam, aimCursor)
    local mode = Settings.AimMode
    if mode ~= "Cursor" and mode ~= "Camera" then
        local t = pickTarget(mode)
        if t then
            return CFrame.lookAt(cam.CFrame.Position, t.hrp.Position)
        end
    end
    if mode == "Camera" or not UserInputService.MouseEnabled then
        return cam.CFrame
    end
    local m = UserInputService:GetMouseLocation()
    local ray = cam:ViewportPointToRay(m.X, m.Y)
    return CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction)
end
local function forgeParry(balls)
    local S = Game.S
    if not (S and S.route and S.sample) then
        return false, "the game's helpers weren't found"
    end
    local okR, route = pcall(S.route)
    if not okR or type(route) ~= "string" then
        return false, "no parry route yet (settings not synced)"
    end
    local remote = ReplicatedStorage:FindFirstChild(route)
    local cam = Workspace.CurrentCamera
    if not remote or not cam then
        return false, "parry remote missing"
    end
    local camCF = cam.CFrame
    local pitch, yaw = camCF:ToEulerAnglesYXZ()
    local sample = S.sample(pitch, yaw, Workspace:GetServerTimeNow())
    local first = Game.myBall and select(2, pcall(Game.myBall)) or balls[1]
    local mine = false
    if typeof(first) == "Instance" then
        local okS, id = pcall(S.slot, first)
        mine = okS and id == LocalPlayer.UserId
    end
    local pick = pickCFrame(cam)
    remote:FireServer(camCF, mine, pick, sample, parrySource(), false)
    -- what the game's own press does on your side (the ball's local prediction and the white flash use these)
    local now = Workspace:GetServerTimeNow()
    local cd = (typeof(first) == "Instance" and first:GetAttribute("Maple")) or 1.5
    LocalPlayer:SetAttribute("LocalParryAim", camCF)
    LocalPlayer:SetAttribute("LocalParryPick", pick)
    LocalPlayer:SetAttribute("LocalParryAt", os.clock())
    LocalPlayer:SetAttribute("LocalWhiteStart", now)
    LocalPlayer:SetAttribute("LocalWhiteEnd", now + cd)
    if Settings.Animation then
        -- the game's own swing animation and sound, as its press path plays them
        local played = false
        if Game.swing then
            played = pcall(Game.swing)
        end
        if not played then
            LocalPlayer:SetAttribute("SwingCount", (LocalPlayer:GetAttribute("SwingCount") or 0) + 1)
        end
        pcall(function()
            local fx = require(ReplicatedStorage:WaitForChild("Shared", 5):WaitForChild("SlashFX", 5))
            fx.PlaySwing(LocalPlayer.Character)
        end)
    end
    return true, "forged remote"
end
local function fireParry(balls, ctx)
    Parry.lastTry = os.clock()
    if ctx then
        addLog(ctx)
    end
    Parry.blockUntil = Parry.lastTry + 0.35
    Parry.sent = Parry.sent + 1
    local method = Settings.ParryMethod
    if method == "Game function (direct call)" and Game.parry then
        local ok = pcall(Game.parry, Settings.AimMode ~= "Camera", parrySource())
        Parry.how = ok and "the game's parry function" or "the game's parry function (errored)"
        return ok
    elseif method == "ParryRequest (mobile tap path)" and Game.ev then
        Game.ev:Fire(Settings.AimMode ~= "Camera")
        Parry.how = "ParryRequest (tagged TAP)"
        return true
    end
    local ok, why = forgeParry(balls or {})
    Parry.how = ok and why or ("failed: " .. why)
    return ok
end
local function parryReady()
    if not aliveInMatch() then
        return false
    end
    if Settings.CheckCooldown then
        local cd = (LocalPlayer:GetAttribute("ParryCooldownEnd") or 0) - Workspace:GetServerTimeNow()
        if cd > 0 then
            return false
        end
    end
    return true
end
-- seconds until the ball reaches you (its closing speed along the line to you)
local function etaOf(b)
    local root = myRoot()
    if not root then
        return nil
    end
    local t = Track[b]
    if not t then
        return nil
    end
    local to = root.Position - b.Position
    local d = to.Magnitude
    local reach = b:GetAttribute("Pearl")
    if type(reach) ~= "number" then
        reach = 5
    end
    local closing = t.vel:Dot(d > 1e-3 and to / d or Vector3.new(0, 0, 0))
    if d - reach <= 0 then
        return 0
    end
    if closing < 8 then
        return nil
    end
    return (d - reach) / closing
end
local function leadFor(window)
    local m = Settings.ParryTiming
    local lead
    if m == "Early" then
        lead = window * 0.9
    elseif m == "Middle" then
        lead = window * 0.5
    elseif m == "Late (bigger curve)" then
        lead = window * 0.2
    else
        lead = Settings.LeadMs / 1000
    end
    if Settings.Jitter > 0 then
        lead = lead + (math.random() * 2 - 1) * Settings.Jitter / 1000
    end
    return math.max(lead, 0) + Parry.ping
end
local lastSpam = 0
local armedLead = nil
local function distTo(b)
    local root = myRoot()
    return root and (b.Position - root.Position).Magnitude or math.huge
end
local function nearestEnemyDist()
    local root = myRoot()
    if not root then
        return math.huge
    end
    local best = math.huge
    for _, e in ipairs(enemies()) do
        best = math.min(best, (e.hrp.Position - root.Position).Magnitude)
    end
    return best
end
local function ctxFor(b, why)
    local t = b and Track[b]
    return { why = why, dist = b and distTo(b) or 0, speed = t and t.speed or 0, eta = b and etaOf(b) }
end
local function parryStep(now, balls)
    local b = ballOnMe(balls)
    for _, ball in ipairs(balls) do
        sample(ball, now)
    end
    local uid = LocalPlayer.UserId
    if not b then
        Parry.eta, armedLead = nil, nil
        Parry.info = "no ball on you"
    else
        local window = ballWindow(b)
        local eta = etaOf(b)
        Parry.eta = eta
        local doomed = LocalPlayer:GetAttribute("LocalDoomedAt")
        local inRange = type(doomed) == "number"
        if not armedLead then
            armedLead = leadFor(window)
        end
        local ready = parryReady()
        if Settings.Trigger then
            Parry.info = ready and "triggerbot: pressing" or "triggerbot: waiting for the cooldown"
            if ready and now >= Parry.blockUntil then
                fireParry(balls, ctxFor(b, "trigger"))
            end
        elseif Settings.AutoParry then
            if not ready then
                Parry.info = "parry on cooldown"
            elseif now < Parry.blockUntil then
                Parry.info = "just pressed"
            elseif inRange or (eta and eta <= armedLead) then
                Parry.info = "pressing"
                if fireParry(balls, ctxFor(b, inRange and "game says in range" or "eta under lead")) then
                    armedLead = nil
                end
            else
                Parry.info = eta and ("ball in %dms, pressing at %dms"):format(math.floor(eta * 1000), math.floor(armedLead * 1000))
                    or "ball on you, not closing in"
            end
        end
    end
    Parry.spamInfo = "off"
    if Settings.Spam and aliveInMatch() then
        local gap = 1 / math.max(Settings.SpamRate, 1)
        local go, why, target = false, nil, nil
        if Settings.SpamMode == "Range only" then
            for _, ball in ipairs(balls) do
                if distTo(ball) <= Settings.SpamRange then
                    go, why, target = true, "ball in range", ball
                    break
                end
            end
        else
            -- a clash: the ball is bouncing between you and someone close (the game marks each hit in Harbor)
            for _, ball in ipairs(balls) do
                local t = Track[ball]
                if t and t.legAt and now - t.legAt < 0.8 and (t.legFrom == uid or t.legTo == uid) and distTo(ball) <= Settings.SpamRange then
                    go, why, target = true, "clash with someone", ball
                    break
                end
            end
            -- about to become one: the ball is on you, about to land, and an opponent is right next to you
            if not go and b then
                local eta = etaOf(b)
                if eta and eta <= Settings.SpamEta / 1000 + Parry.ping and nearestEnemyDist() <= Settings.SpamRange then
                    go, why, target = true, "ball arriving, opponent close", b
                end
            end
        end
        Parry.spamInfo = go and why or "waiting for a clash"
        if go and now - lastSpam >= gap and now - Parry.lastTry >= 0.02 then
            lastSpam = now
            fireParry(balls, ctxFor(target, "spam: " .. why))
        end
    end
end
local function logText()
    local now = os.clock()
    local lines = {}
    for i = #Log, math.max(#Log - 3, 1), -1 do
        local e = Log[i]
        local res = e.result or (now - e.t > 1.5 and "no hit" or "...")
        lines[#lines + 1] = ("%s · d %d · %d st/s · eta %s → %s"):format(e.why or "?", math.floor(e.dist or 0), math.floor(e.speed or 0),
            e.eta and (math.floor(e.eta * 1000) .. "ms") or "?", res)
    end
    return #lines > 0 and table.concat(lines, "\n") or "no presses yet"
end

--// Abilities \\--
local lastAbility = 0
local function abilityStep(now, balls)
    if not Settings.AutoAbility or now - lastAbility < 0.5 or not aliveInMatch() then
        return
    end
    local locked = LocalPlayer:GetAttribute("AbilityLocked")
    if locked == true or (locked ~= nil and locked == myMatch()) then
        return
    end
    local id = LocalPlayer:GetAttribute("Ability") or "Dash"
    if id == "Dash" and not Settings.IncludeDash then
        return
    end
    if now < (LocalPlayer:GetAttribute("DashReadyAt") or 0) or not Game.dashEv then
        return
    end
    local when = Settings.AbilityWhen
    local fire = (when == "Whenever ready")
    if not fire then
        local b = ballOnMe(balls)
        local root = myRoot()
        if b and root and (b.Position - root.Position).Magnitude <= Settings.AbilityRange then
            fire = true
            if when == "Ball on me + parry on cooldown" then
                fire = (LocalPlayer:GetAttribute("ParryCooldownEnd") or 0) - Workspace:GetServerTimeNow() > 0
            end
        end
    end
    if fire then
        lastAbility = now
        Game.dashEv:Fire()
    end
end

connect(RunService.Heartbeat, function()
    if not alive() then
        return
    end
    local now = os.clock()
    local need = Settings.AutoParry or Settings.Trigger or Settings.Spam or Settings.AutoAbility
    if not need then
        return
    end
    local balls = inMatch() and ballsInMatch() or {}
    parryStep(now, balls)
    abilityStep(now, balls)
end)

--// ESP (Drawing) \\--
local hasDrawing = pcall(function()
    return Drawing.new
end)
local Pool, Used = { Text = {}, Line = {}, Circle = {}, Square = {} }, { Text = 0, Line = 0, Circle = 0, Square = 0 }
local function acquire(kind)
    Used[kind] = Used[kind] + 1
    local o = Pool[kind][Used[kind]]
    if not o then
        o = Drawing.new(kind)
        if kind == "Text" then
            o.Center, o.Outline, o.Size = true, true, 14
        elseif kind == "Circle" then
            o.NumSides, o.Thickness, o.Filled = 24, 1.5, false
        elseif kind == "Line" then
            o.Thickness = 1.3
        elseif kind == "Square" then
            o.Thickness, o.Filled = 1.3, false
        end
        Pool[kind][Used[kind]] = o
    end
    o.Visible = true
    return o
end
local function espBegin()
    Used.Text, Used.Line, Used.Circle, Used.Square = 0, 0, 0, 0
end
local function espEnd()
    for kind, list in pairs(Pool) do
        for i = Used[kind] + 1, #list do
            list[i].Visible = false
        end
    end
end
onCleanup(function()
    for _, list in pairs(Pool) do
        for _, o in ipairs(list) do
            pcall(function()
                o:Remove()
            end)
        end
    end
end)
local RED, WHITE, YELLOW = Color3.fromRGB(255, 70, 70), Color3.fromRGB(235, 235, 235), Color3.fromRGB(255, 220, 90)
local function toScreen(cam, pos)
    local v, on = cam:WorldToViewportPoint(pos)
    return Vector2.new(v.X, v.Y), on and v.Z > 0, v.Z
end
local function espFrame(now)
    local cam = Workspace.CurrentCamera
    local root = myRoot()
    if not cam then
        return
    end
    local size = cam.ViewportSize
    local from = Vector2.new(size.X / 2, size.Y)
    local balls = (Settings.EspBall or Settings.EspPlayers) and inMatch() and ballsInMatch() or {}
    local mine = ballOnMe(balls)
    if Settings.EspBall then
        for _, b in ipairs(balls) do
            local t = sample(b, now)
            local p, on = toScreen(cam, b.Position)
            local onMe = (b == mine)
            local col = onMe and RED or WHITE
            if on then
                local c = acquire("Circle")
                c.Position, c.Radius, c.Color = p, 9, col
                local owner = ballOwnerId(b)
                local d = root and (b.Position - root.Position).Magnitude or 0
                local txt = acquire("Text")
                txt.Position = p + Vector2.new(0, 14)
                txt.Color = col
                txt.Text = ("%d st/s · %dm%s"):format(math.floor(t.speed), math.floor(d),
                    owner and (" · " .. (owner == LocalPlayer.UserId and "YOU" or nameOf(owner))) or "")
                if Settings.EspBallLine then
                    local l = acquire("Line")
                    l.From, l.To, l.Color = from, p, col
                end
            end
            if Settings.EspBallLine and t.speed > 5 then
                local p2, on2 = toScreen(cam, b.Position + t.vel * Settings.PredictTime)
                if on or on2 then
                    local l = acquire("Line")
                    l.From, l.To, l.Color = p, p2, YELLOW
                end
            end
        end
    end
    if Settings.EspPlayers and inMatch() then
        for _, e in ipairs(enemies()) do
            local d = root and (e.hrp.Position - root.Position).Magnitude or 0
            if d <= Settings.EspDistance then
                local top, on1 = toScreen(cam, e.hrp.Position + Vector3.new(0, 3, 0))
                local bot, on2 = toScreen(cam, e.hrp.Position - Vector3.new(0, 3.2, 0))
                if on1 and on2 then
                    local h = math.abs(bot.Y - top.Y)
                    local w = h * 0.55
                    local col = WHITE
                    local sq = acquire("Square")
                    sq.Position, sq.Size, sq.Color = Vector2.new(top.X - w / 2, top.Y), Vector2.new(w, h), col
                    local txt = acquire("Text")
                    txt.Position = Vector2.new(top.X, top.Y - 16)
                    txt.Color = col
                    txt.Text = ("%s · %d hp · %dm"):format(e.name, math.floor(e.hum.Health), math.floor(d))
                    if Settings.EspTracers then
                        local l = acquire("Line")
                        l.From, l.To, l.Color = from, Vector2.new(bot.X, bot.Y), col
                    end
                end
            end
        end
    end
end
connect(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    if hasDrawing and (Settings.EspBall or Settings.EspPlayers) then
        espBegin()
        pcall(espFrame, os.clock())
        espEnd()
    elseif hasDrawing then
        espBegin()
        espEnd()
    end
    if Settings.FovOn and Workspace.CurrentCamera then
        Workspace.CurrentCamera.FieldOfView = Settings.Fov
    end
end)

--// HUD text \\--
local function hudText()
    local balls = inMatch() and ballsInMatch() or {}
    local b = ballOnMe(balls)
    local cd = math.max((LocalPlayer:GetAttribute("ParryCooldownEnd") or 0) - Workspace:GetServerTimeNow(), 0)
    local lines = {}
    lines[#lines + 1] = inMatch() and ("Match: %s"):format(tostring(myMatch())) or "In the lobby (nothing to parry)"
    lines[#lines + 1] = cd > 0 and ("Parry: cooldown %.1fs"):format(cd) or "Parry: ready"
    if b then
        local t = Track[b]
        local root = myRoot()
        lines[#lines + 1] = ("Ball on you: %d st/s, %dm"):format(t and math.floor(t.speed) or 0,
            root and math.floor((b.Position - root.Position).Magnitude) or 0)
    else
        lines[#lines + 1] = "Ball: not on you"
    end
    local doomed = LocalPlayer:GetAttribute("LocalDoomedAt")
    lines[#lines + 1] = Parry.eta and ("Ball arrives in %dms"):format(math.floor(Parry.eta * 1000)) or "Ball arrival: unknown"
    lines[#lines + 1] = type(doomed) == "number" and ("Game says in hit range (%+.2fs)"):format(os.clock() - doomed) or "Game says in hit range: no"
    lines[#lines + 1] = ("Auto parry: %s"):format(Parry.info)
    lines[#lines + 1] = ("Auto spam: %s"):format(Parry.spamInfo or "off")
    lines[#lines + 1] = ("Presses %d · landed %d · server cooldowns %d · ping %dms"):format(Parry.sent, Parry.landed, Parry.count, math.floor(Parry.ping * 1000))
    lines[#lines + 1] = ("Last press: %s"):format(Parry.how)
    lines[#lines + 1] = "Game hook: " .. Game.info
    lines[#lines + 1] = "Recent presses:\n" .. logText()
    return table.concat(lines, "\n")
end

--// Visuals \\--
connect(LocalPlayer.Idled, function()
    if alive() and Settings.AntiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)
local function applyFps()
    if typeof(setfpscap) == "function" then
        pcall(setfpscap, Settings.FpsOn and Settings.FpsCap or 60)
    end
end
local fogSaved
local function applyFog(on)
    if on then
        if not fogSaved then
            fogSaved = { end_ = Lighting.FogEnd, start = Lighting.FogStart, atmo = {} }
            for _, a in ipairs(Lighting:GetChildren()) do
                if a:IsA("Atmosphere") then
                    fogSaved.atmo[a] = a.Density
                end
            end
        end
        Lighting.FogEnd, Lighting.FogStart = 1e9, 1e9
        for a in pairs(fogSaved.atmo) do
            a.Density = 0
        end
    elseif fogSaved then
        Lighting.FogEnd, Lighting.FogStart = fogSaved.end_, fogSaved.start
        for a, d in pairs(fogSaved.atmo) do
            a.Density = d
        end
        fogSaved = nil
    end
end
local postSaved = {}
local function applyPost(on)
    if on then
        for _, e in ipairs(Lighting:GetChildren()) do
            if (e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("BloomEffect") or e:IsA("DepthOfFieldEffect")
                or e:IsA("ColorCorrectionEffect")) and e.Enabled then
                postSaved[e] = true
                e.Enabled = false
            end
        end
    else
        for e in pairs(postSaved) do
            e.Enabled = true
        end
        postSaved = {}
    end
end
local function quiet(inst)
    if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
        inst.Enabled = false
    elseif inst:IsA("BasePart") then
        inst.Transparency = 1
    end
end
local vfxConn
local function applyVfx(on)
    if vfxConn then
        vfxConn:Disconnect()
        vfxConn = nil
    end
    if not on then
        return
    end
    local folder = Workspace:FindFirstChild("VFX")
    if folder then
        for _, d in ipairs(folder:GetDescendants()) do
            quiet(d)
        end
        vfxConn = folder.DescendantAdded:Connect(quiet)
    end
end
onCleanup(function()
    if vfxConn then
        vfxConn:Disconnect()
    end
    applyFog(false)
    applyPost(false)
    if typeof(setfpscap) == "function" then
        pcall(setfpscap, 60)
    end
end)

--// Movement \\--
local flyKeys = { W = false, A = false, S = false, D = false, Space = false, LeftControl = false }
connect(UserInputService.InputBegan, function(input, gpe)
    if not gpe and flyKeys[input.KeyCode.Name] ~= nil then
        flyKeys[input.KeyCode.Name] = true
    end
end)
connect(UserInputService.InputEnded, function(input)
    if flyKeys[input.KeyCode.Name] ~= nil then
        flyKeys[input.KeyCode.Name] = false
    end
end)
connect(UserInputService.JumpRequest, function()
    local h = myHum()
    if alive() and Settings.InfJump and h then
        h:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)
local function moveAllowed()
    return Settings.MoveInMatch or not inMatch()
end
connect(RunService.Heartbeat, function()
    if not alive() then
        return
    end
    local h, root = myHum(), myRoot()
    if not h or not root then
        return
    end
    if Settings.SpeedOn then
        h.WalkSpeed = Settings.WalkSpeed
    end
    if Settings.JumpOn then
        h.UseJumpPower = true
        h.JumpPower = Settings.JumpPower
    end
    if Settings.Fly and moveAllowed() then
        local cam = Workspace.CurrentCamera
        if cam then
            local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
            local dir = Vector3.new(0, 0, 0)
            if flyKeys.W then dir = dir + look end
            if flyKeys.S then dir = dir - look end
            if flyKeys.D then dir = dir + right end
            if flyKeys.A then dir = dir - right end
            if flyKeys.Space then dir = dir + Vector3.new(0, 1, 0) end
            if flyKeys.LeftControl then dir = dir - Vector3.new(0, 1, 0) end
            root.AssemblyLinearVelocity = dir.Magnitude > 0.01 and dir.Unit * Settings.FlySpeed or Vector3.new(0, 0, 0)
        end
    end
end)
connect(RunService.Stepped, function()
    if alive() and Settings.Noclip and moveAllowed() then
        local c = myChar()
        if c then
            for _, p in ipairs(c:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide then
                    p.CanCollide = false
                end
            end
        end
    end
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "szm's customs",
    Footer = "dookie hub · Ui3",
    Icon = "swords",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/SzmsCustoms",
})
local Options = {}
local function toggle(box, key, text, tip, after)
    Options[key] = box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
    return Options[key]
end
local function slider(box, key, text, min, max, rounding, suffix, tip)
    return box:AddSlider(key, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.4)
        end
    end)
end

do
    local Tab = Window:AddTab("Parry", "swords", "Auto parry, triggerbot, spam")
    local A = Tab:AddLeftGroupbox("Auto parry", "shield")
    toggle(A, "AutoParry", "Auto parry",
        "Sends the parry when the ball on you is about to reach you: its time to arrive (from its measured speed) is under the lead below plus your ping")
    dropdown(A, "ParryMethod", "How it parries", { "Forged remote (like Blade Ball)", "Game function (direct call)", "ParryRequest (mobile tap path)" },
        "Forged remote: builds the packet itself with the game's own route and signed sample (aim options work). Game function: calls the game's parry code directly. ParryRequest: the game's mobile-tap path (tagged TAP)")
    dropdown(A, "ParryTiming", "Timing", { "Early", "Middle", "Late (bigger curve)", "Custom" },
        "How long before the ball arrives it presses, as a share of the parry window. Late curves the ball harder (the game's own tip) but leaves less room")
    slider(A, "LeadMs", "Custom lead", 0, 500, 0, " ms", "For Custom timing")
    slider(A, "Jitter", "Random +/-", 0, 120, 0, " ms", "Varies the lead each ball")
    toggle(A, "Animation", "Play the parry animation", "Swing animation and sound on every press, like a normal parry (forged remote only: the game's other paths play it themselves)")
    toggle(A, "CheckCooldown", "Check the cooldown first", "Skips the press while your parry is on cooldown (the server would refuse it anyway)")
    local T = Tab:AddLeftGroupbox("Triggerbot & spam", "zap")
    toggle(T, "Trigger", "Triggerbot", "Presses as soon as a ball is on you, at any distance (usually early). Overrides auto parry's timing")
    toggle(T, "Spam", "Auto spam", "Smart: only spams in a real clash (the ball bouncing between you and someone close) or when the ball is about to land on you with the opponent right next to you. Range only: spams whenever a ball is in range")
    dropdown(T, "SpamMode", "Spam mode", { "Smart (clash)", "Range only" })
    slider(T, "SpamRate", "Spam rate", 5, 120, 0, " /s")
    slider(T, "SpamRange", "Spam range", 10, 300, 0, " studs", "Smart: how close the clash / opponent has to be. Range only: how close the ball has to be")
    slider(T, "SpamEta", "Start spam when ball is", 50, 800, 0, " ms away", "Smart mode, when it's not in a clash yet")
    local C = Tab:AddRightGroupbox("Curve & aim", "spline")
    dropdown(C, "AimMode", "Aim at", { "Cursor", "Camera", "Closest to crosshair", "Nearest player", "Lowest health", "Random player" },
        "Where the parried ball is sent: your cursor, your camera, or a player (nearest, lowest health, random, closest to your crosshair)")
    C:AddButton({ Text = "Test parry now", Func = function()
        fireParry(inMatch() and ballsInMatch() or {})
    end })
    local S = Tab:AddRightGroupbox("Status", "layout-dashboard")
    status(S, hudText)
end

do
    local Tab = Window:AddTab("Abilities", "sparkles", "Dash, Force, Speed, Rage")
    local A = Tab:AddLeftGroupbox("Auto ability", "sparkles")
    toggle(A, "AutoAbility", "Auto ability", "Uses your equipped ability through the game's own request when the rule below fits")
    dropdown(A, "AbilityWhen", "Use when", { "Ball on me + parry on cooldown", "Ball on me", "Whenever ready" })
    slider(A, "AbilityRange", "Ball within", 10, 120, 0, " studs")
    toggle(A, "IncludeDash", "Include Dash", "Off by default: a dash moves you, the other abilities don't")
end

do
    local Tab = Window:AddTab("Visuals", "eye", "ESP, HUD, camera")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    if not hasDrawing then
        E:AddLabel("This executor has no Drawing library: ESP is off.", true)
    end
    toggle(E, "EspBall", "Ball", "Circle, speed, distance and who it's on (red = you)")
    toggle(E, "EspBallLine", "Ball tracer & path", "A line to the ball and where it's heading")
    slider(E, "PredictTime", "Path length", 0.1, 1.5, 1, " s")
    toggle(E, "EspPlayers", "Players", "Box, health and distance for everyone in your match")
    toggle(E, "EspTracers", "Player tracers")
    slider(E, "EspDistance", "Max distance", 100, 3000, 0, " studs")
    local V = Tab:AddRightGroupbox("Camera & world", "camera")
    toggle(V, "FovOn", "Field of view")
    slider(V, "Fov", "FOV", 40, 120, 0)
    toggle(V, "NoFog", "Remove fog", nil, applyFog)
    toggle(V, "NoPost", "Remove screen effects", "Blur, bloom, sun rays, depth of field, colour correction", applyPost)
    toggle(V, "HideVfx", "Hide effects (VFX)", "Particles and trails in workspace.VFX: parry bursts, ball trails", applyVfx)
    local P = Tab:AddRightGroupbox("Performance", "gauge")
    toggle(P, "FpsOn", "Unlock FPS", nil, applyFps)
    slider(P, "FpsCap", "FPS cap", 60, 360, 0, nil, "Applies when Unlock FPS is on")
    P:AddButton({ Text = "Apply FPS cap", Func = applyFps })
    toggle(P, "AntiAfk", "Anti-AFK")
end

do
    local Tab = Window:AddTab("Player", "user", "Speed, jump, fly")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Walk speed", "The game's Speed ability may set it back")
    slider(M, "WalkSpeed", "Speed", 16, 120, 0)
    toggle(M, "JumpOn", "Jump power")
    slider(M, "JumpPower", "Power", 50, 250, 0)
    toggle(M, "InfJump", "Infinite jump")
    local F = Tab:AddRightGroupbox("Fly & noclip", "plane")
    toggle(F, "Fly", "Fly", "W A S D, Space up, Left Ctrl down")
    slider(F, "FlySpeed", "Fly speed", 20, 250, 0)
    toggle(F, "Noclip", "Noclip")
    toggle(F, "MoveInMatch", "Allow in a match", "Off: fly and noclip only work in the lobby (in a match they are far more likely to get you kicked)")
    local O = Tab:AddRightGroupbox("Other", "settings")
    O:AddButton({ Text = "Unload", Func = function()
        if Genv.__SzmUnload then
            Genv.__SzmUnload()
        end
    end })
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in ipairs(Connections) do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__SzmUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded" .. (Game.ev and "" or " (waiting for the game's parry code)"), 4)

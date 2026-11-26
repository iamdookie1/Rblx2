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
    ParryTiming = "Instant", DelayMs = 60, LateFrac = 50, RandMin = 20, RandMax = 160,
    AimMode = "Camera", CheckCooldown = true, SpamRate = 30, SpamRange = 35,
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
local Game = { ev = nil, dashEv = nil, S = nil, myBall = nil, info = "looking for the game's parry code" }
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
    for _, v in pairs(ups) do
        if type(v) == "table" then
            if type(rawget(v, "slot")) == "function" and type(rawget(v, "active")) == "function" then
                out.S = v
            end
        elseif type(v) == "function" then
            local okn, name = pcall(debug.info, v, "n")
            if okn and name == "myBall" then
                out.myBall = v
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
        Game.S, Game.myBall = out.S, out.myBall
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
local function sample(b, now)
    local t = Track[b]
    if not t then
        t = { pos = b.Position, t = now, vel = Vector3.new(0, 0, 0), speed = 0 }
        Track[b] = t
        return t
    end
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
local Parry = { count = 0, sent = 0, doomed = nil, delay = 0, countAtDoom = 0, lastTry = 0, info = "off", ping = 0.05 }
connect(LocalPlayer:GetAttributeChangedSignal("LocalParryAt"), function()
    Parry.count = Parry.count + 1
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
local function fireParry()
    local ev = Game.ev
    if not ev then
        return false
    end
    Parry.lastTry = os.clock()
    Parry.sent = Parry.sent + 1
    local mode = Settings.AimMode
    if mode == "Cursor" then
        ev:Fire(true)
        return true
    end
    local cam = Workspace.CurrentCamera
    local target = (mode ~= "Camera") and cam and pickTarget(mode) or nil
    if not target then
        ev:Fire(false)
        return true
    end
    -- the game sends your camera CFrame and the ray it picks the curve from: look at them for the press
    local saved = cam.CFrame
    cam.CFrame = CFrame.lookAt(saved.Position, target.hrp.Position)
    ev:Fire(false)
    task.defer(function()
        cam.CFrame = saved
    end)
    return true
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
local function pickDelay(window)
    local m = Settings.ParryTiming
    local d = 0
    if m == "Delay" then
        d = Settings.DelayMs / 1000
    elseif m == "Late (bigger curve)" then
        d = window * Settings.LateFrac / 100
    elseif m == "Random" then
        d = (Settings.RandMin + math.random() * math.max(Settings.RandMax - Settings.RandMin, 0)) / 1000
    end
    return math.min(d, math.max(window - 0.06 - Parry.ping * 0.5, 0))
end
local lastSpam = 0
local function parryStep(now, balls)
    local doomed = LocalPlayer:GetAttribute("LocalDoomedAt")
    if type(doomed) ~= "number" then
        Parry.doomed = nil
        Parry.info = "no ball on you"
    end
    local ready = parryReady()
    if Settings.Trigger then
        if type(doomed) == "number" then
            Parry.info = ready and "triggerbot: pressing" or "triggerbot: waiting for the cooldown"
            if ready and now - Parry.lastTry >= 0.03 then
                fireParry()
            end
        end
    elseif Settings.AutoParry and type(doomed) == "number" then
        if doomed ~= Parry.doomed then
            Parry.doomed = doomed
            Parry.countAtDoom = Parry.count
            Parry.delay = pickDelay(ballWindow(ballOnMe(balls)))
        end
        local window = ballWindow(ballOnMe(balls))
        if Parry.count > Parry.countAtDoom then
            Parry.info = "parried"
        elseif not ready then
            Parry.info = "ball in range, parry on cooldown"
        elseif now > doomed + window + 0.15 then
            Parry.info = "window passed"
        elseif now >= doomed + Parry.delay then
            Parry.info = "pressing"
            if now - Parry.lastTry >= 0.04 then
                fireParry()
            end
        else
            Parry.info = ("waiting %dms"):format(math.floor((doomed + Parry.delay - now) * 1000))
        end
    end
    if Settings.Spam and aliveInMatch() then
        local root = myRoot()
        local gap = 1 / math.max(Settings.SpamRate, 1)
        if root and now - lastSpam >= gap and now - Parry.lastTry >= 0.02 then
            for _, b in ipairs(balls) do
                if (b.Position - root.Position).Magnitude <= Settings.SpamRange then
                    lastSpam = now
                    fireParry()
                    break
                end
            end
        end
    end
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
    lines[#lines + 1] = type(doomed) == "number" and ("In hit range: %+.2fs"):format(os.clock() - doomed) or "In hit range: no"
    lines[#lines + 1] = ("Auto parry: %s"):format(Parry.info)
    lines[#lines + 1] = ("Parries landed locally %d · presses %d · ping %dms"):format(Parry.count, Parry.sent, math.floor(Parry.ping * 1000))
    lines[#lines + 1] = "Game hook: " .. Game.info
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
        "Presses the game's own parry the moment the ball is in hit range (the game ignores presses before that), then waits the timing below")
    dropdown(A, "ParryTiming", "Timing", { "Instant", "Delay", "Late (bigger curve)", "Random" },
        "Instant: first moment the game allows it. Late: the game curves the ball harder the later you parry inside the window")
    slider(A, "DelayMs", "Delay", 0, 400, 0, " ms", "For Delay timing")
    slider(A, "LateFrac", "Late amount", 0, 90, 0, "%", "How far into the parry window Late waits. Too high and the ball gets through")
    slider(A, "RandMin", "Random from", 0, 400, 0, " ms")
    slider(A, "RandMax", "Random to", 0, 400, 0, " ms")
    toggle(A, "CheckCooldown", "Check the cooldown first", "Skips the press while your parry is on cooldown (the game would ignore it anyway)")
    local T = Tab:AddLeftGroupbox("Triggerbot & spam", "zap")
    toggle(T, "Trigger", "Triggerbot", "Presses every frame while a ball is on you; the game lets the first valid one through. Overrides auto parry's timing")
    toggle(T, "Spam", "Auto spam", "Presses at a capped rate while a ball is close to you, on you or not (clashes)")
    slider(T, "SpamRate", "Spam rate", 5, 60, 0, " /s")
    slider(T, "SpamRange", "Spam range", 10, 80, 0, " studs")
    local C = Tab:AddRightGroupbox("Curve & aim", "spline")
    dropdown(C, "AimMode", "Aim at", { "Camera", "Cursor", "Closest to crosshair", "Nearest player", "Lowest health", "Random player" },
        "Where the parried ball goes. Camera and Cursor are the game's own; the others turn your camera to that player for the press")
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

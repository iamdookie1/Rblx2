--// RIVALS ------------------------------------------------------------------------------------
-- place 17625359962 (game 6035872082). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Shots   ItemTypes.Gun:StartShooting returns ClientFighter:GetCameraData()
--           and the server traces the shot from your camera, so a hit is
--           wherever your real camera points when you fire. Spread is
--           reproduced on the server.
--   Camera  Controllers.CameraController keeps Rotation (pitch, yaw) and
--           mouse input reaches it through ApplyRotationDelta; your camera is
--           also streamed to the server (UpdateCameraRotation) and a
--           protected module, CameraSecurity, watches it. Moderators see
--           automatic RedFlags on your account.
--   Fighter CameraController:GetCurrentSubject() is your ClientFighter; its
--           EquippedItem.Info has IsRaycast / ProjectileSpeed /
--           ProjectileGravity, and fighter:Input("StartShooting" /
--           "FinishShooting") is what the game itself calls to shoot.
--   Teams   Players carry EnvironmentID (which duel you're in) and TeamID.
--
-- The ESP and the prediction arc are drawn with the Drawing API and never
-- touch the game or the network. The aimbot moves your real camera (by real
-- mouse movement, or the game's own ApplyRotationDelta on mobile), so shots
-- go where your camera actually looks. It is still the kind of thing
-- CameraSecurity is there to catch: smooth it, keep the FOV small, use an alt.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__RivalsUnload then
    pcall(Genv.__RivalsUnload)
end
Genv.__RivalsRun = (Genv.__RivalsRun or 0) + 1
local RUN = Genv.__RivalsRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__RivalsRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local Settings = {
    -- aimbot
    Aimbot = false, AimMethod = IsTouch and "Camera" or "Mouse", AimWhen = IsTouch and "Always" or "While aiming (right click)",
    AimPart = "Head", AimFOV = 120, ShowFOV = true, FOVColor = Color3.fromRGB(255, 255, 255),
    Smoothness = 6, AimMaxDistance = 400, VisibleOnly = true, StickyTarget = true,
    -- prediction
    Prediction = true, PredictionScale = 100, HitscanLead = 0, LeadPing = true, ShowPredicted = false,
    AimJitter = 0, AimReaction = 0,
    -- triggerbot
    Triggerbot = false, TriggerMode = "Tap", TriggerDelayMin = 40, TriggerDelayMax = 90, TriggerHold = 0.06,
    TriggerRadius = 6, TriggerOnlyAiming = false, TriggerHeadOnly = false, TriggerUsePrediction = true,
    TriggerOnlyAimbotTarget = false,
    -- katana
    AutoDeflect = false, DeflectProjectiles = true, DeflectHitscan = true, DeflectWhenAimed = false,
    DeflectRange = 120, DeflectAimAngle = 4, DeflectAimRange = 40, DeflectTiming = 0.35,
    -- recoil
    RecoilOn = false, RecoilScale = 50,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspHealth = true, EspDistance = true, EspTracer = false,
    EspMax = 600, EspTeammates = false, EspVisibleColor = true,
    EnemyColor = Color3.fromRGB(255, 70, 70), VisibleColor = Color3.fromRGB(90, 255, 120), TeamColor = Color3.fromRGB(90, 170, 255),
    -- projectile
    ShowArc = false, ArcColor = Color3.fromRGB(255, 200, 60),
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "RIVALS", Description = text, Time = seconds or 3 })
end
local function myChar()
    return LocalPlayer.Character
end
local function camera()
    return Workspace.CurrentCamera
end

--// The game's camera controller and your fighter \\--
local Game = {}
do
    local ok, cc = pcall(function()
        return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controllers"):WaitForChild("CameraController", 10))
    end)
    Game.Camera = ok and type(cc) == "table" and cc or nil
    function Game.fighter()
        local cc = Game.Camera
        if not cc then
            return nil
        end
        local ok2, f = pcall(cc.GetCurrentSubject, cc)
        return ok2 and type(f) == "table" and f or nil
    end
    function Game.item()
        local f = Game.fighter()
        local item = f and f.EquippedItem
        return type(item) == "table" and item or nil
    end
    function Game.info()
        local item = Game.item()
        local info = item and item.Info
        return type(info) == "table" and info or nil
    end
    function Game.aiming()
        local item = Game.item()
        if item and type(item.Get) == "function" then
            local ok2, v = pcall(item.Get, item, "IsAiming")
            if ok2 and v ~= nil then
                return v == true
            end
        end
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end
end

--// Who's an enemy \\--
local Targets = {}
do
    function Targets.sameMatch(p)
        local mine, theirs = LocalPlayer:GetAttribute("EnvironmentID"), p:GetAttribute("EnvironmentID")
        return (mine or "") == (theirs or "")
    end
    function Targets.teammate(p)
        local mine, theirs = LocalPlayer:GetAttribute("TeamID"), p:GetAttribute("TeamID")
        return mine ~= nil and mine ~= "" and mine == theirs
    end
    function Targets.alive(p)
        local c = p.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local root = c and c:FindFirstChild("HumanoidRootPart")
        return c and hum and root and hum.Health > 0, c, hum, root
    end
    -- Enemies only (or teammates too, for ESP).
    function Targets.list(includeTeam)
        local out = {}
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and Targets.sameMatch(p) then
                local ok, c, hum, root = Targets.alive(p)
                if ok and (includeTeam or not Targets.teammate(p)) then
                    table.insert(out, { player = p, char = c, hum = hum, root = root, team = Targets.teammate(p) })
                end
            end
        end
        return out
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    function Targets.visible(part, char)
        local cam = camera()
        if not (cam and part) then
            return false
        end
        local ignore = { cam }
        local me = myChar()
        if me then
            table.insert(ignore, me)
        end
        params.FilterDescendantsInstances = ignore
        local from = cam.CFrame.Position
        local hit = Workspace:Raycast(from, part.Position - from, params)
        return hit == nil or hit.Instance:IsDescendantOf(char)
    end
    function Targets.part(char, choice)
        if choice == "Torso" then
            return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
        elseif choice == "Closest to crosshair" then
            local cam = camera()
            local centre = cam.ViewportSize / 2
            local best, bestD
            for _, name in { "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso" } do
                local part = char:FindFirstChild(name)
                if part then
                    local sp, on = cam:WorldToViewportPoint(part.Position)
                    if on then
                        local d = (Vector2.new(sp.X, sp.Y) - centre).Magnitude
                        if not bestD or d < bestD then
                            best, bestD = part, d
                        end
                    end
                end
            end
            return best or char:FindFirstChild("Head")
        end
        return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    end
end

--// Prediction \\--
-- Projectile weapons: where to aim so a shot of the weapon's own speed and
-- drop meets the target, scaled by the strength slider. Hitscan weapons: a
-- small lead by your ping plus the extra you set, because the server traces
-- the shot from where you were looking when it arrives.
local Lead = {}
do
    function Lead.time()
        local t = Settings.HitscanLead / 1000
        if Settings.LeadPing then
            local ok, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
            t += ok and type(ping) == "number" and ping or 0
        end
        return t
    end
    function Lead.point(part, root)
        local cam = camera()
        if not (Settings.Prediction and cam and part) then
            return part and part.Position
        end
        local info = Game.info()
        local scale = Settings.PredictionScale / 100
        local vel = root and root.AssemblyLinearVelocity or Vector3.zero
        if not info or info.IsRaycast then
            return part.Position + vel * Lead.time() * scale
        end
        local speed = tonumber(info.ProjectileSpeed) or 300
        local grav = math.abs(tonumber(info.ProjectileGravity) or 0)
        if speed <= 0 then
            return part.Position
        end
        local from = cam.CFrame.Position
        local at = part.Position
        for _ = 1, 4 do
            local t = (at - from).Magnitude / speed
            local tt = t * scale
            at = part.Position + vel * tt + Vector3.new(0, 0.5 * grav * tt * tt, 0)
        end
        return at
    end
end

--// Drawing helpers \\--
local Draw = {}
do
    Draw.ok = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
    local all = {}
    function Draw.new(kind, props)
        if not Draw.ok then
            return nil
        end
        local ok, d = pcall(Drawing.new, kind)
        if not ok then
            return nil
        end
        for k, v in props or {} do
            pcall(function()
                d[k] = v
            end)
        end
        table.insert(all, d)
        return d
    end
    table.insert(Cleanups, function()
        for _, d in all do
            pcall(d.Remove, d)
        end
    end)
end

--// Aimbot \\--
local Aim = { target = nil, info = "off" }
do
    local fov = Draw.new("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Transparency = 0.8, Visible = false })
    local dot = Draw.new("Circle", { Thickness = 2, NumSides = 16, Radius = 4, Filled = true, Visible = false })
    function Aim.showPredicted(point)
        if not dot then
            return
        end
        local cam = camera()
        if not (point and cam and Settings.ShowPredicted) then
            dot.Visible = false
            return
        end
        local sp, on = cam:WorldToViewportPoint(point)
        dot.Visible = on
        dot.Position = Vector2.new(sp.X, sp.Y)
        dot.Color = Settings.ArcColor
    end
    local wantSince = nil
    local function active()
        local when = Settings.AimWhen
        if when == "Always" then
            return true
        elseif when == "While shooting (left click)" then
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end
        return Game.aiming()
    end
    local function wrap(a)
        return (a + math.pi) % (2 * math.pi) - math.pi
    end
    function Aim.pick()
        local cam = camera()
        if not cam then
            return nil
        end
        local centre = cam.ViewportSize / 2
        local me = myChar()
        local myRoot = me and me:FindFirstChild("HumanoidRootPart")
        local function score(t)
            local part = Targets.part(t.char, Settings.AimPart)
            if not part then
                return nil
            end
            if myRoot and (t.root.Position - myRoot.Position).Magnitude > Settings.AimMaxDistance then
                return nil
            end
            local sp, on = cam:WorldToViewportPoint(part.Position)
            if not on then
                return nil
            end
            local d = (Vector2.new(sp.X, sp.Y) - centre).Magnitude
            if d > Settings.AimFOV then
                return nil
            end
            if Settings.VisibleOnly and not Targets.visible(part, t.char) then
                return nil
            end
            return d, part
        end
        -- Keep the current target while it's still valid.
        if Settings.StickyTarget and Aim.target then
            for _, t in Targets.list(false) do
                if t.player == Aim.target.player then
                    local d, part = score(t)
                    if d then
                        t.part = part
                        return t
                    end
                end
            end
        end
        local best, bestD
        for _, t in Targets.list(false) do
            local d, part = score(t)
            if d and (not bestD or d < bestD) then
                t.part = part
                best, bestD = t, d
            end
        end
        return best
    end
    bind(RunService.RenderStepped, function(dt)
        local cam = camera()
        if fov then
            fov.Visible = alive() and Settings.Aimbot and Settings.ShowFOV
            if fov.Visible and cam then
                fov.Radius = Settings.AimFOV
                fov.Position = cam.ViewportSize / 2
                fov.Color = Aim.target and Settings.EnemyColor or Settings.FOVColor
            end
        end
        -- The predicted point, shown whether or not the aimbot is turning you.
        if Settings.ShowPredicted then
            local shown = Aim.target or Aim.pick()
            Aim.showPredicted(shown and Lead.point(shown.part, shown.root))
        else
            Aim.showPredicted(nil)
        end
        if not (alive() and Settings.Aimbot and cam and active()) then
            Aim.target, wantSince = nil, nil
            Aim.info = Settings.Aimbot and "waiting (not active)" or "off"
            return
        end
        local t = Aim.pick()
        if not t then
            Aim.target, wantSince = nil, nil
            Aim.info = "no target in the circle"
            return
        end
        if not Aim.target or Aim.target.player ~= t.player then
            wantSince = os.clock()
        end
        Aim.target = t
        -- Reaction time before it starts moving.
        if os.clock() - (wantSince or 0) < Settings.AimReaction / 1000 then
            Aim.info = "reacting to " .. t.player.DisplayName
            return
        end
        local point = Lead.point(t.part, t.root)
        if Settings.AimJitter > 0 then
            local j = Settings.AimJitter / 10
            point += Vector3.new((math.random() - 0.5) * j, (math.random() - 0.5) * j, (math.random() - 0.5) * j)
        end
        local smooth = math.max(1, Settings.Smoothness)
        if Settings.AimMethod == "Mouse" and typeof(mousemoverel) == "function" then
            local sp = cam:WorldToViewportPoint(point)
            local centre = cam.ViewportSize / 2
            local dx, dy = (sp.X - centre.X) / smooth, (sp.Y - centre.Y) / smooth
            if math.abs(dx) > 0.05 or math.abs(dy) > 0.05 then
                mousemoverel(dx, dy)
            end
        elseif Game.Camera and type(Game.Camera.ApplyRotationDelta) == "function" then
            local dir = (point - cam.CFrame.Position)
            if dir.Magnitude < 0.01 then
                return
            end
            dir = dir.Unit
            -- CameraController.Rotation is (pitch, yaw), look = Y-rotation then X.
            local pitch = math.asin(math.clamp(dir.Y, -1, 1))
            local yaw = math.atan2(-dir.X, -dir.Z)
            local cur = Game.Camera.Rotation
            if typeof(cur) ~= "Vector2" then
                return
            end
            local delta = Vector2.new(pitch - cur.X, wrap(yaw - cur.Y)) / smooth
            pcall(Game.Camera.ApplyRotationDelta, Game.Camera, delta, true)
        end
        Aim.info = ("locked on %s"):format(t.player.DisplayName)
    end)
end

--// Triggerbot \\--
-- Fires through fighter:Input("StartShooting"/"FinishShooting"), the same
-- calls the game makes. "On target" is either the crosshair ray touching
-- them, or (with prediction) the predicted point being within a few pixels
-- of the crosshair, so moving targets count. It waits a random reaction
-- time, skips when you're out of ammo or reloading, and fires again as soon
-- as the gun's own cooldown allows. Hold mode keeps the trigger down while
-- you stay on them (for automatic guns).
local Trigger = { info = "off", shots = 0 }
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local onSince, needDelay, holding, busy = nil, 0, false, false
    local function rayTarget(cam)
        local ignore = { cam }
        local me = myChar()
        if me then
            table.insert(ignore, me)
        end
        params.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 2000, params)
        if not hit then
            return nil
        end
        for _, t in Targets.list(false) do
            if hit.Instance:IsDescendantOf(t.char) then
                if Settings.TriggerHeadOnly and hit.Instance.Name ~= "Head" then
                    return nil
                end
                return t
            end
        end
        return nil
    end
    local function predictedTarget(cam)
        local centre = cam.ViewportSize / 2
        for _, t in Targets.list(false) do
            local part = Settings.TriggerHeadOnly and t.char:FindFirstChild("Head") or Targets.part(t.char, "Closest to crosshair")
            if part and Targets.visible(part, t.char) then
                local point = Lead.point(part, t.root)
                local sp, on = cam:WorldToViewportPoint(point)
                if on and (Vector2.new(sp.X, sp.Y) - centre).Magnitude <= Settings.TriggerRadius then
                    return t
                end
            end
        end
        return nil
    end
    local function gunReady(item)
        if not item then
            return false, "no weapon"
        end
        local info = item.Info
        if type(info) ~= "table" or info.ShootCooldown == nil then
            return false, "not a gun"
        end
        local okA, ammo = pcall(item.Get, item, "Ammo")
        if okA and type(ammo) == "number" and ammo <= 0 then
            return false, "out of ammo"
        end
        if type(item._reload_cooldown) == "number" and tick() < item._reload_cooldown then
            return false, "reloading"
        end
        return true
    end
    local function release(f)
        if holding then
            holding = false
            pcall(f.Input, f, "FinishShooting")
        end
    end
    bind(RunService.Heartbeat, function()
        local f = Game.fighter()
        if not (alive() and Settings.Triggerbot) then
            if f and holding then
                release(f)
            end
            onSince = nil
            Trigger.info = "off"
            return
        end
        if not (f and type(f.Input) == "function") then
            Trigger.info = "your fighter isn't loaded"
            return
        end
        local cam = camera()
        if not cam or (Settings.TriggerOnlyAiming and not Game.aiming()) then
            release(f)
            onSince = nil
            Trigger.info = cam and "waiting (not aiming)" or "no camera"
            return
        end
        local t = rayTarget(cam) or (Settings.TriggerUsePrediction and Settings.Prediction and predictedTarget(cam))
        if t and Settings.TriggerOnlyAimbotTarget and not (Aim.target and Aim.target.player == t.player) then
            t = nil
        end
        local item = Game.item()
        local ready, why = gunReady(item)
        if not t or not ready then
            release(f)
            onSince = nil
            Trigger.info = not t and "crosshair not on anyone" or why
            return
        end
        if not onSince then
            onSince = os.clock()
            local lo, hi = math.min(Settings.TriggerDelayMin, Settings.TriggerDelayMax), math.max(Settings.TriggerDelayMin, Settings.TriggerDelayMax)
            needDelay = (lo + math.random() * (hi - lo)) / 1000
        end
        if os.clock() - onSince < needDelay then
            Trigger.info = "reacting..."
            return
        end
        Trigger.info = "shooting " .. t.player.DisplayName
        if Settings.TriggerMode == "Hold" then
            if not holding then
                holding = true
                Trigger.shots += 1
                pcall(f.Input, f, "StartShooting")
            end
            return
        end
        -- Tap: press again whenever the gun's own cooldown has run out.
        if busy or (type(item._shoot_cooldown) == "number" and tick() < item._shoot_cooldown) then
            return
        end
        busy = true
        Trigger.shots += 1
        task.spawn(function()
            pcall(f.Input, f, "StartShooting")
            task.wait(Settings.TriggerHold)
            pcall(f.Input, f, "FinishShooting")
            busy = false
        end)
    end)
end

--// Auto deflect (katana) \\--
-- The katana's right click is a deflect: Info.DeflectDuration (1s) then
-- Info.DeflectCooldown (4s), sent as fighter:Input("StartAiming"). Enemy
-- shots reach your client as Gun.ReplicateFromServer("ShootEffect" /
-- "ProjectileEffect") on their gun, so the moment one fires at you:
--   projectiles  the deflect is timed to the projectile's flight time, so the
--                window is up when it arrives
--   hitscan      the first bullet is already decided on the server, but the
--                deflect is up for the rest of an automatic spray
--   aimed at     (optional) deflects early when someone close by is aiming
--                right at you
local Deflect = { info = "off", count = 0 }
do
    local pending = false
    local function myKatana()
        local item = Game.item()
        local info = item and item.Info
        if type(info) == "table" and info.DeflectDuration then
            return item, info
        end
        return nil
    end
    local function ready(item)
        return type(item._deflect_cooldown) ~= "number" or tick() >= item._deflect_cooldown
    end
    local function deflect(reason)
        local f = Game.fighter()
        local item = myKatana()
        if not (f and item and ready(item)) then
            return false
        end
        Deflect.count += 1
        Deflect.info = "deflected " .. reason
        task.spawn(function()
            pcall(f.Input, f, "StartAiming")
            task.wait(0.08)
            pcall(f.Input, f, "FinishAiming")
        end)
        return true
    end
    -- Is this shooter pointed at me, within the range?
    local function aimedAtMe(fromPos, lookDir, maxAngle, range)
        local me = myChar()
        local root = me and me:FindFirstChild("HumanoidRootPart")
        if not (root and fromPos and lookDir) then
            return false
        end
        local to = root.Position - fromPos
        if to.Magnitude > range or lookDir.Magnitude < 0.01 then
            return false
        end
        local angle = math.deg(math.acos(math.clamp(lookDir.Unit:Dot(to.Unit), -1, 1)))
        return angle <= maxAngle, to.Magnitude
    end
    local function shooterOf(item)
        local cf = type(item) == "table" and item.ClientFighter
        if type(cf) ~= "table" or cf.IsLocalPlayer then
            return nil
        end
        local entity = cf.Entity
        local root = type(entity) == "table" and entity.RootPart
        if typeof(root) ~= "Instance" then
            return nil
        end
        local p = Players:GetPlayerFromCharacter(root.Parent)
        if p and (Targets.teammate(p) or not Targets.sameMatch(p)) then
            return nil
        end
        return root, p
    end
    local function lookOf(root)
        local head = root.Parent and root.Parent:FindFirstChild("Head")
        return (head or root).CFrame.LookVector, (head or root).Position
    end

    local ok, Gun = pcall(function()
        return require(LocalPlayer.PlayerScripts:WaitForChild("Modules"):WaitForChild("ItemTypes"):WaitForChild("Gun", 10))
    end)
    if ok and type(Gun) == "table" and type(Gun.ReplicateFromServer) == "function" then
        local saved = Genv.__RivalsGunReplicateOriginal
        if saved then
            Gun.ReplicateFromServer = saved
        end
        local orig = Gun.ReplicateFromServer
        Genv.__RivalsGunReplicateOriginal = orig
        Gun.ReplicateFromServer = function(self, kind, ...)
            if alive() and Settings.AutoDeflect and (kind == "ShootEffect" or kind == "ProjectileEffect") then
                pcall(function()
                    local root = shooterOf(self)
                    local katana = root and myKatana()
                    if not katana then
                        return
                    end
                    local look, from = lookOf(root)
                    -- Generous angle: they only need to be shooting roughly at you.
                    local at, dist = aimedAtMe(from, look, 25, Settings.DeflectRange)
                    if not at then
                        return
                    end
                    if kind == "ShootEffect" and Settings.DeflectHitscan then
                        deflect("a shot")
                    elseif kind == "ProjectileEffect" and Settings.DeflectProjectiles and not pending then
                        local info = type(self.Info) == "table" and self.Info or {}
                        local speed = math.max(tonumber(info.ProjectileSpeed) or 300, 1)
                        local wait = math.max(0, dist / speed - Settings.DeflectTiming)
                        pending = true
                        task.delay(wait, function()
                            pending = false
                            deflect("a projectile")
                        end)
                    end
                end)
            end
            return orig(self, kind, ...)
        end
        table.insert(Cleanups, function()
            Gun.ReplicateFromServer = orig
            Genv.__RivalsGunReplicateOriginal = nil
        end)
        Deflect.status = "ready"
    else
        Deflect.status = "gun module not found"
    end

    -- Early deflect when someone close is lined up on you.
    bind(RunService.Heartbeat, function()
        if not (alive() and Settings.AutoDeflect) then
            Deflect.info = "off"
            return
        end
        local item = myKatana()
        if not item then
            Deflect.info = "hold a katana"
            return
        end
        if not ready(item) then
            Deflect.info = ("cooldown %.1fs"):format(item._deflect_cooldown - tick())
            return
        end
        Deflect.info = "ready"
        if not Settings.DeflectWhenAimed then
            return
        end
        for _, t in Targets.list(false) do
            local look, from = lookOf(t.root)
            if aimedAtMe(from, look, Settings.DeflectAimAngle, Settings.DeflectAimRange) and Targets.visible(t.root, t.char) then
                deflect(t.player.DisplayName .. " aiming at you")
                return
            end
        end
    end)
end

--// Recoil: the game's own recoil, scaled \\--
-- Gun:StartShooting calls self:_Recoil(multiplier); _Recoil lives on
-- ClientItem, which every gun inherits from.
local Recoil = { status = "ClientItem not found" }
do
    local ok, ClientItem = pcall(function()
        return require(LocalPlayer.PlayerScripts:WaitForChild("Modules"):WaitForChild("ClientReplicatedClasses")
            :WaitForChild("ClientFighter"):WaitForChild("ClientItem", 10))
    end)
    if ok and type(ClientItem) == "table" then
        local saved = Genv.__RivalsRecoilOriginal
        if saved then
            rawset(ClientItem, "_Recoil", saved)
        end
        local orig = rawget(ClientItem, "_Recoil") or ClientItem._Recoil
        if type(orig) == "function" then
            Genv.__RivalsRecoilOriginal = orig
            rawset(ClientItem, "_Recoil", function(self, mult, ...)
                if alive() and Settings.RecoilOn then
                    local scale = Settings.RecoilScale / 100
                    if scale <= 0 then
                        return
                    end
                    mult = (tonumber(mult) or 1) * scale
                end
                return orig(self, mult, ...)
            end)
            table.insert(Cleanups, function()
                rawset(ClientItem, "_Recoil", orig)
                Genv.__RivalsRecoilOriginal = nil
            end)
            Recoil.status = "ready"
        else
            Recoil.status = "recoil function not found"
        end
    end
end

--// ESP \\--
do
    local pool = {}
    local function entry(p)
        local e = pool[p]
        if e then
            return e
        end
        e = {
            box = Draw.new("Square", { Thickness = 1.5, Filled = false, Visible = false }),
            name = Draw.new("Text", { Size = 14, Center = true, Outline = true, Visible = false }),
            dist = Draw.new("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            hpBack = Draw.new("Square", { Filled = true, Color = Color3.new(0, 0, 0), Transparency = 0.6, Visible = false }),
            hp = Draw.new("Square", { Filled = true, Visible = false }),
            tracer = Draw.new("Line", { Thickness = 1, Visible = false }),
        }
        pool[p] = e
        return e
    end
    local function hide(e)
        for _, d in e do
            if d then
                d.Visible = false
            end
        end
    end
    local function drop(p)
        local e = pool[p]
        if e then
            for _, d in e do
                if d then
                    pcall(d.Remove, d)
                end
            end
            pool[p] = nil
        end
    end
    bind(Players.PlayerRemoving, drop)
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local on = alive() and Settings.Esp and Draw.ok and cam
        local seen = {}
        if on then
            local me = myChar()
            local myRoot = me and me:FindFirstChild("HumanoidRootPart")
            for _, t in Targets.list(Settings.EspTeammates) do
                local e = entry(t.player)
                seen[t.player] = true
                local dist = myRoot and (t.root.Position - myRoot.Position).Magnitude or 0
                local head = t.char:FindFirstChild("Head") or t.root
                local top, onTop = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 0.8, 0))
                local bottom, onBottom = cam:WorldToViewportPoint(t.root.Position - Vector3.new(0, 3, 0))
                if dist > Settings.EspMax or not (onTop or onBottom) then
                    hide(e)
                else
                    local color = t.team and Settings.TeamColor or Settings.EnemyColor
                    if not t.team and Settings.EspVisibleColor and Targets.visible(head, t.char) then
                        color = Settings.VisibleColor
                    end
                    local h = math.abs(bottom.Y - top.Y)
                    local w = h * 0.55
                    local x, y = top.X - w / 2, top.Y
                    if e.box then
                        e.box.Visible = Settings.EspBox
                        e.box.Position = Vector2.new(x, y)
                        e.box.Size = Vector2.new(w, h)
                        e.box.Color = color
                    end
                    if e.name then
                        e.name.Visible = Settings.EspName
                        e.name.Text = t.player.DisplayName
                        e.name.Position = Vector2.new(top.X, y - 16)
                        e.name.Color = color
                    end
                    if e.dist then
                        e.dist.Visible = Settings.EspDistance
                        e.dist.Text = ("%dm"):format(math.floor(dist))
                        e.dist.Position = Vector2.new(top.X, y + h + 2)
                        e.dist.Color = color
                    end
                    if e.hp and e.hpBack then
                        local frac = math.clamp(t.hum.Health / math.max(t.hum.MaxHealth, 1), 0, 1)
                        e.hpBack.Visible = Settings.EspHealth
                        e.hpBack.Position = Vector2.new(x - 6, y)
                        e.hpBack.Size = Vector2.new(4, h)
                        e.hp.Visible = Settings.EspHealth
                        e.hp.Position = Vector2.new(x - 6, y + h * (1 - frac))
                        e.hp.Size = Vector2.new(4, h * frac)
                        e.hp.Color = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(80, 255, 100), frac)
                    end
                    if e.tracer then
                        e.tracer.Visible = Settings.EspTracer
                        e.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                        e.tracer.To = Vector2.new(top.X, y + h)
                        e.tracer.Color = color
                    end
                end
            end
        end
        for p, e in pool do
            if not seen[p] then
                hide(e)
            end
        end
    end)
end

--// Projectile arc \\--
do
    local SEGMENTS = 30
    local lines = {}
    for i = 1, SEGMENTS do
        lines[i] = Draw.new("Line", { Thickness = 2, Visible = false })
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local info = Game.info()
        local show = alive() and Settings.ShowArc and cam and info and not info.IsRaycast
        if not show then
            for _, l in lines do
                if l then
                    l.Visible = false
                end
            end
            return
        end
        local speed = tonumber(info.ProjectileSpeed) or 300
        local grav = math.abs(tonumber(info.ProjectileGravity) or 0)
        local life = math.min(tonumber(info.ProjectileLifetime) or 5, 3)
        local ignore = { cam }
        local me = myChar()
        if me then
            table.insert(ignore, me)
        end
        params.FilterDescendantsInstances = ignore
        local pos = cam.CFrame.Position + cam.CFrame.LookVector * 2
        local vel = cam.CFrame.LookVector * speed
        local dt = life / SEGMENTS
        local stopped = false
        for i = 1, SEGMENTS do
            local l = lines[i]
            local nextVel = vel - Vector3.new(0, grav * dt, 0)
            local nextPos = pos + nextVel * dt
            local hit = not stopped and Workspace:Raycast(pos, nextPos - pos, params)
            if hit then
                nextPos = hit.Position
            end
            local a, onA = cam:WorldToViewportPoint(pos)
            local b, onB = cam:WorldToViewportPoint(nextPos)
            if l then
                l.Visible = not stopped and onA and onB
                l.From = Vector2.new(a.X, a.Y)
                l.To = Vector2.new(b.X, b.Y)
                l.Color = Settings.ArcColor
            end
            if hit then
                stopped = true
            end
            pos, vel = nextPos, nextVel
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "RIVALS",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/Rivals",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
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
local function color(t, key, title)
    if t and t.AddColorPicker then
        t:AddColorPicker(key .. "Pick", {
            Default = Settings[key], Title = title,
            Callback = function(c)
                Settings[key] = c
            end,
        })
    end
end

do
    local Tab = Window:AddTab("Aimbot", "crosshair", "Aim and triggerbot")
    local Box = Tab:AddLeftGroupbox("Aimbot", "crosshair")
    toggle(Box, "Aimbot", "Aimbot",
        "Turns your real camera onto a target inside the circle, so shots go where the camera looks. CameraSecurity watches the camera: smooth it and use an alt")
    dropdown(Box, "AimMethod", "Method", { "Mouse", "Camera" },
        "Mouse: real mouse movement (PC, the most natural). Camera: the game's own camera turn (works on mobile)")
    dropdown(Box, "AimWhen", "Active", { "While aiming (right click)", "While shooting (left click)", "Always" })
    dropdown(Box, "AimPart", "Aim at", { "Head", "Torso", "Closest to crosshair" })
    slider(Box, "Smoothness", "Smoothness", 1, 30, 1, "", "1 snaps instantly. Higher is slower and looks more human")
    slider(Box, "AimFOV", "Circle size", 20, 600, 0, " px")
    color(toggle(Box, "ShowFOV", "Show circle"), "FOVColor", "Circle colour")
    slider(Box, "AimMaxDistance", "Max distance", 25, 1500, 0, " studs")
    toggle(Box, "VisibleOnly", "Only visible targets", "Skips anyone behind a wall")
    toggle(Box, "StickyTarget", "Stick to target", "Keeps the same target while they stay in the circle")
    slider(Box, "AimReaction", "Reaction time", 0, 400, 0, " ms", "Wait this long after a new target appears before moving")
    slider(Box, "AimJitter", "Humanize jitter", 0, 20, 0, "", "A little random offset so it isn't pixel perfect")
    local AimLabel = Box:AddLabel("...", true)

    local Pred = Tab:AddLeftGroupbox("Prediction", "move-right")
    toggle(Pred, "Prediction", "Prediction",
        "Aims where the target will be: projectile guns use the weapon's own speed and drop, hitscan guns lead by your ping and the extra below")
    slider(Pred, "PredictionScale", "Strength", 0, 200, 0, "%", "100 is the physics answer. Raise it if you hit behind moving targets, lower it if you hit ahead")
    slider(Pred, "HitscanLead", "Hitscan extra lead", 0, 300, 0, " ms", "Extra lead for hitscan guns, on top of ping")
    toggle(Pred, "LeadPing", "Lead by ping", "Adds your ping to the hitscan lead")
    toggle(Pred, "ShowPredicted", "Show predicted point", "A dot where the prediction aims, on the target nearest your crosshair")

    local Trig = Tab:AddRightGroupbox("Triggerbot", "zap")
    toggle(Trig, "Triggerbot", "Triggerbot",
        "Shoots when you're on an enemy, through the game's own shoot input (no clicks). Waits for the gun's own cooldown, skips while reloading or empty")
    dropdown(Trig, "TriggerMode", "Mode", { "Tap", "Hold" }, "Tap: one press per shot, as fast as the gun allows. Hold: trigger down while you stay on them (automatic guns)")
    slider(Trig, "TriggerDelayMin", "Reaction min", 0, 400, 0, " ms")
    slider(Trig, "TriggerDelayMax", "Reaction max", 0, 600, 0, " ms", "A random reaction between min and max each time you get on a target")
    slider(Trig, "TriggerHold", "Tap length", 0.02, 0.4, 2, " s")
    toggle(Trig, "TriggerUsePrediction", "Use prediction", "Also counts as on target when the predicted point is near your crosshair")
    slider(Trig, "TriggerRadius", "Prediction radius", 1, 30, 0, " px")
    toggle(Trig, "TriggerOnlyAiming", "Only while aiming")
    toggle(Trig, "TriggerHeadOnly", "Only on the head")
    toggle(Trig, "TriggerOnlyAimbotTarget", "Only the aimbot's target")
    local TrigLabel = Trig:AddLabel("...", true)

    local Kat = Tab:AddRightGroupbox("Katana", "swords")
    toggle(Kat, "AutoDeflect", "Auto deflect",
        "Holding a katana, deflects (1s window, 4s cooldown) when an enemy shoots at you: timed to a projectile's flight, or at once for hitscan sprays")
    toggle(Kat, "DeflectProjectiles", "Projectiles", "Rockets, arrows, grenades... timed so the deflect is up when it arrives")
    toggle(Kat, "DeflectHitscan", "Hitscan shots", "The first bullet is already decided by the server, but the rest of a spray gets deflected")
    slider(Kat, "DeflectTiming", "Projectile timing", 0.1, 0.9, 2, " s", "How long before a projectile arrives the deflect goes up")
    slider(Kat, "DeflectRange", "Range", 20, 400, 0, " studs")
    toggle(Kat, "DeflectWhenAimed", "Deflect when aimed at", "Deflects early when someone close is aiming right at you")
    slider(Kat, "DeflectAimAngle", "Aimed within", 1, 15, 0, "°")
    slider(Kat, "DeflectAimRange", "Aimed within distance", 5, 150, 0, " studs")
    local KatLabel = Kat:AddLabel("...", true)

    local Rec = Tab:AddRightGroupbox("Recoil", "move")
    toggle(Rec, "RecoilOn", "Change recoil", "Scales the game's own camera kick when you shoot")
    slider(Rec, "RecoilScale", "Recoil", 0, 100, 0, "%", "100 is normal, 0 is none")
    local RecLabel = Rec:AddLabel("...", true)

    task.spawn(function()
        while alive() do
            pcall(function()
                AimLabel:SetText(("Now: %s\nCamera controller: %s"):format(Aim.info, Game.Camera and "found" or "not found"))
                TrigLabel:SetText(("Now: %s\nShots: %d"):format(Trigger.info, Trigger.shots))
                RecLabel:SetText("Recoil: " .. Recoil.status)
                KatLabel:SetText(("Deflect: %s\nHooked: %s\nDeflects: %d"):format(Deflect.info, Deflect.status or "?", Deflect.count))
            end)
            task.wait(0.3)
        end
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "See everyone")
    local Box = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(Box, "Esp", "ESP", "Drawn on your screen only: nothing is added to the game")
    toggle(Box, "EspBox", "Box")
    toggle(Box, "EspName", "Name")
    toggle(Box, "EspHealth", "Health bar")
    toggle(Box, "EspDistance", "Distance")
    toggle(Box, "EspTracer", "Tracers")
    slider(Box, "EspMax", "Max distance", 50, 3000, 0, " studs")
    local Col = Tab:AddRightGroupbox("Colours", "palette")
    color(toggle(Col, "EspVisibleColor", "Different colour when visible"), "VisibleColor", "Visible colour")
    color(toggle(Col, "EspTeammates", "Show teammates"), "TeamColor", "Teammate colour")
    Col:AddLabel("Enemy colour", false)
    if Col.AddColorPicker then
        pcall(function()
            Col:AddColorPicker("EnemyColorPick", {
                Default = Settings.EnemyColor, Title = "Enemy colour",
                Callback = function(c)
                    Settings.EnemyColor = c
                end,
            })
        end)
    end
end

do
    local Tab = Window:AddTab("Weapons", "target", "Projectile helper")
    local Box = Tab:AddLeftGroupbox("Projectiles", "target")
    color(toggle(Box, "ShowArc", "Projectile arc",
        "With a projectile weapon out (RPG, bow, grenade launcher...), draws where a shot fired now will fly and land"), "ArcColor", "Arc colour")
    local InfoLabel = Box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                local item, info = Game.item(), Game.info()
                InfoLabel:SetText(info and ("Holding: %s\n%s"):format(tostring(item.Name or "?"),
                    info.IsRaycast and "hitscan (no arc)" or ("projectile, speed %s, drop %s"):format(tostring(info.ProjectileSpeed or 300),
                        tostring(info.ProjectileGravity or 0))) or "No weapon out")
            end)
            task.wait(0.5)
        end
    end)
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__RivalsUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(("Loaded%s%s"):format(Game.Camera and "" or " (camera controller not found)", Draw.ok and "" or " (no Drawing API: ESP off)"), 4)

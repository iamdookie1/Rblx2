--// OPERATION ONE ------------------------------------------------------------------------------
-- place 72920620366355 (game 8307114974), built against version 2045. Built on Ui3.
-- Works with mouse and touch: nothing here needs a mouse, the shoot button or a key.
--
-- How the game works (as the client shows it, from the dump):
--   Bodies     Every player is a Model in Workspace tagged "Character" with attributes Team
--              ("Red" / "Blue"), UserId, ID, Revealed. It keeps a Humanoid (real Health) and a
--              HumanoidRootPart, but the visible body is ten anchored parts (head, torso, leg1,
--              leg2, arm1, arm2, shoulder1, shoulder2, hip1, hip2) that setup_viewmodels moves
--              into Workspace.Viewmodels.Viewmodel[n]. Yours is LocalViewmodel. Dead players'
--              models go to ReplicatedStorage.Garbage.
--   State      ReplicatedStorage.Modules.StateObject.get_all("Character") gives every Character
--              state object keyed by its model: .instance, .states, .values.
--                states.equipped / look / class_name / speed_multiplier ...
--                values.viewmodels   the Viewmodel model of that body
--                values.equipped     your gun's item object (.states, .instance, .shoot_hold)
--   Camera     CameraType stays Custom: Roblox's own camera module turns the view from mouse or
--              touch, then Character.render_camera layers lean / recoil / bobbing on top and takes
--              the same offset off again next frame. Rotating Camera.CFrame after all of that
--              (late render step) is what the game's own input does too, on every device.
--   Shots      Gun.send_shoot calls item:get_shoot_look() for the muzzle CFrame. Because guns are
--              client_sided_hitscan it traces the rays itself from that CFrame (spread included)
--              and fires states.shoot:fire_instant(look, hits). Whatever get_shoot_look returns is
--              both where the rays go and the look that is sent. That is the one place silent aim
--              needs: this script wraps get_shoot_look on the gun in your hand.
--   Firing     item:input_shoot(down) is what the fire button, the mouse and the mobile joystick
--              all call; item.shoot_hold is true while a shot is held; item.states.sights is ADS.
--   Gun states Numbers in item.states[x].value: recoil_up, recoil_side, spread, firerate, ads
--              (seconds to aim), reload_speed (higher is faster). The game reads .value locally.
--   Speed      Humanoid.WalkSpeed = states.speed x held item speed x states.speed_multiplier.
--   Teams      Player and Character attribute Team, colours in game.Teams[team]:GetAttribute("Color").
--              Workspace attributes Gamemode, CurrentMap, Round, BestOf, DefuserAvailable.
--   Tags       Claymore, NeedleMine, ProximityAlarm, RemoteC4, ThermiteCharge, BreachCharge,
--              HardBreachCharge, IncendiaryCanister, ToxicCharge, ShockBattery, SignalDisruptor,
--              BarbedWire, StickyCamera, BulletproofCamera, Drone, DeployableShield, the grenades
--              (Frag, Smoke, Stun, EMP, Impact, Incendiary, Launched) and Bomb (Root part).
--   Smoke      Smoke grenades clone their script.SmokePart into Workspace.
--
-- No remote is fired. The ESP and circles are Drawing objects, the aimbot only turns your camera,
-- the gun changes are local values the game's own client reads. Silent aim changes the look and
-- hit list your client reports with each shot: what the server does with a look that is not where
-- your camera points is the one thing the dump cannot show, so test it before a match that matters.
-- The game has player reports ("cheating") and a ranked queue.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__OperationOneUnload then
    pcall(Genv.__OperationOneUnload)
end
Genv.__OperationOneRun = (Genv.__OperationOneRun or 0) + 1
local RUN = Genv.__OperationOneRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__OperationOneRun == RUN
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

local IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local Settings = {
    -- aimbot (turns the camera)
    Aimbot = false, AimWhen = IsTouch and "While shooting" or "Aiming down sights", AimPart = "Head",
    AimFOV = 140, ShowFOV = true, Smoothness = 6, AimMaxDistance = 300, VisibleOnly = true,
    StickyTarget = true, AimTeammates = false,
    -- silent aim (the shot goes to the target, the camera stays)
    SilentAim = false, SilentPart = "Head", SilentFOV = 200, SilentShowFOV = true, SilentHitChance = 100,
    SilentMaxDistance = 400, SilentVisible = true, SilentLook = false,
    -- triggerbot
    Triggerbot = false, TriggerDelay = 60, TriggerHeadOnly = false, TriggerOnlyAiming = not IsTouch,
    -- gun
    NoRecoil = false, NoSpread = false, RapidFire = false, RapidScale = 1.5, FastAds = false,
    FastReload = false, ReloadScale = 1.6, AutoReload = false,
    -- player
    SpeedHack = false, SpeedScale = 1.2,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspHealth = true, EspDistance = true, EspWeapon = true,
    EspClass = false, EspSkeleton = false, EspLook = false, EspTracer = false, EspTeammates = false,
    EspChams = false, EspMax = 600,
    UtilTraps = false, UtilCameras = false, UtilGrenades = false, BombEsp = false, UtilMax = 250,
    -- world
    Fullbright = false, NoFlash = false, NoSmoke = false, FovChanger = false, FovValue = 80,
    -- misc
    AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "OPERATION ONE", Description = text, Time = seconds or 3 })
end
local function camera()
    return Workspace.CurrentCamera
end

--// The game's state objects \\--
local Game = {}
do
    local ok, mod = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Modules", 10):WaitForChild("StateObject", 10))
    end)
    Game.SO = ok and type(mod) == "table" and mod or nil

    function Game.characters()
        local so = Game.SO
        if not so then
            return {}
        end
        local ok2, all = pcall(so.get_all, "Character")
        return ok2 and type(all) == "table" and all or {}
    end
    function Game.me()
        local char = LocalPlayer.Character
        return char and Game.characters()[char] or nil
    end
    -- The gun in your hand (any item with the gun states), or nil.
    function Game.gun()
        local me = Game.me()
        local item = me and me.values and me.values.equipped
        if type(item) == "table" and type(item.states) == "table" and item.states.recoil_up then
            return item
        end
        return nil
    end
    function Game.teamColor(name)
        local t = name and game:GetService("Teams"):FindFirstChild(name)
        local c = t and t:GetAttribute("Color")
        if typeof(c) == "Color3" then
            return c
        end
        if t and typeof(t.TeamColor) == "BrickColor" then
            return t.TeamColor.Color
        end
        return nil
    end
end

--// Who is a target \\--
local Targets = {}
do
    local ENEMY, TEAM = Color3.fromRGB(255, 70, 70), Color3.fromRGB(90, 170, 255)

    function Targets.teammate(model)
        local mine, theirs = LocalPlayer:GetAttribute("Team"), model:GetAttribute("Team")
        return mine ~= nil and mine ~= "" and mine == theirs
    end
    function Targets.color(model, team)
        return Game.teamColor(model:GetAttribute("Team")) or (team and TEAM or ENEMY)
    end
    -- Every other living body that is in the world right now.
    function Targets.list(includeTeam)
        local out = {}
        local mine = LocalPlayer.Character
        for model, obj in Game.characters() do
            if model ~= mine and model.Parent == Workspace then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local root = model:FindFirstChild("HumanoidRootPart")
                if hum and root and hum.Health > 0 then
                    local team = Targets.teammate(model)
                    if includeTeam or not team then
                        local vm = obj.values and obj.values.viewmodels
                        table.insert(out, {
                            model = model, obj = obj, hum = hum, root = root, team = team,
                            vm = (typeof(vm) == "Instance" and vm.Parent) and vm or nil,
                        })
                    end
                end
            end
        end
        return out
    end
    function Targets.part(t, choice)
        if choice == "Random" then
            choice = math.random() < 0.5 and "Head" or "Torso"
        end
        local vm = t.vm
        if vm then
            local p = vm:FindFirstChild(choice == "Head" and "head" or "torso")
            if p then
                return p
            end
        end
        return t.root
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    -- Nothing solid between your camera and the part (bodies don't count).
    function Targets.visible(part)
        local cam = camera()
        if not (cam and part) then
            return false
        end
        local ignore = { cam }
        local vms = Workspace:FindFirstChild("Viewmodels")
        if vms then
            table.insert(ignore, vms)
        end
        for model in Game.characters() do
            table.insert(ignore, model)
        end
        params.FilterDescendantsInstances = ignore
        local from = cam.CFrame.Position
        return Workspace:Raycast(from, part.Position - from, params) == nil
    end
    function Targets.screen(pos)
        local sp = camera():WorldToViewportPoint(pos)
        return Vector2.new(sp.X, sp.Y), sp.Z > 0
    end
    -- The enemy closest to the middle of the screen inside a FOV (px), or nil.
    -- opts: fov, maxDist, visible, part, teammates
    function Targets.pick(opts)
        local cam = camera()
        local centre = cam.ViewportSize / 2
        local best, bestD
        for _, t in Targets.list(opts.teammates) do
            local part = Targets.part(t, opts.part)
            local sp, front = Targets.screen(part.Position)
            if front then
                local d = (sp - centre).Magnitude
                local dist = (part.Position - cam.CFrame.Position).Magnitude
                if d <= opts.fov and dist <= opts.maxDist and (not bestD or d < bestD)
                    and (not opts.visible or Targets.visible(part)) then
                    best, bestD = { t = t, part = part, d = d }, d
                end
            end
        end
        return best
    end
end

--// Gun values (local only) \\--
local Gun = {}
local Scaled = setmetatable({}, { __mode = "k" })
do
    -- Multiplies a State's .value by `mult`, remembering what the game itself set so that a
    -- change the game makes (equip, attachment, effect) becomes the new base.
    local function scale(state, mult)
        if type(state) ~= "table" or type(state.value) ~= "number" then
            return
        end
        local rec = Scaled[state]
        if not rec then
            if mult == 1 then
                return
            end
            rec = { base = state.value, last = state.value }
            Scaled[state] = rec
        end
        if math.abs(state.value - rec.last) > 1e-4 then
            rec.base = state.value
        end
        rec.last = rec.base * mult
        state.value = rec.last
    end
    Gun.scale = scale

    function Gun.step()
        local item = Game.gun()
        if item then
            local s = item.states
            scale(s.recoil_up, Settings.NoRecoil and 0 or 1)
            scale(s.recoil_side, Settings.NoRecoil and 0 or 1)
            scale(s.spread, Settings.NoSpread and 0 or 1)
            scale(s.firerate, Settings.RapidFire and Settings.RapidScale or 1)
            scale(s.ads, Settings.FastAds and 0.15 or 1)
            scale(s.reload_speed, Settings.FastReload and Settings.ReloadScale or 1)
        end
        local me = Game.me()
        if me then
            scale(me.states.speed_multiplier, Settings.SpeedHack and Settings.SpeedScale or 1)
        end
    end
    function Gun.restore()
        for state, rec in Scaled do
            if type(state.value) == "number" and math.abs(state.value - rec.last) < 1e-4 then
                state.value = rec.base
            end
        end
    end
    table.insert(Cleanups, Gun.restore)

    -- Reloads on its own when the magazine is empty (the game's own reload, so it still takes
    -- the normal time and its own checks apply).
    local lastReload = 0
    function Gun.autoReload()
        if not Settings.AutoReload then
            return
        end
        local item = Game.gun()
        if not (item and item.states.mag and item.states.bullets and type(item.prepare_reload) == "function") then
            return
        end
        if item.states.mag:get() <= 0 and item.states.bullets:get() > 0 and os.clock() - lastReload > 0.6 then
            lastReload = os.clock()
            pcall(item.prepare_reload, item)
        end
    end
end

--// Silent aim \\--
local Silent = { last = nil, hooked = setmetatable({}, { __mode = "k" }) }
do
    local OPTS = {}
    -- What the shot's look becomes: from the muzzle straight at the target part.
    function Silent.redirect(cf)
        if Settings.SilentHitChance < 100 and math.random() * 100 >= Settings.SilentHitChance then
            return cf
        end
        OPTS.fov, OPTS.maxDist, OPTS.visible = Settings.SilentFOV, Settings.SilentMaxDistance, Settings.SilentVisible
        OPTS.part, OPTS.teammates = Settings.SilentPart, false
        local pick = Targets.pick(OPTS)
        if not pick then
            return cf
        end
        local to = pick.part.Position
        if (to - cf.Position).Magnitude < 0.5 then
            return cf
        end
        Silent.last = { name = pick.t.model.Name, at = os.clock() }
        if Settings.SilentLook then
            local me = Game.me()
            if me and me.states.look then
                pcall(me.states.look.set, me.states.look, (to - cf.Position).Unit)
            end
        end
        return CFrame.lookAt(cf.Position, to)
    end

    -- Wraps get_shoot_look on the item in your hand. Everything else about the shot stays the
    -- game's own: the rays, the spread, the hit list, what gets sent.
    function Silent.attach(item)
        if Silent.hooked[item] then
            return
        end
        local orig = item.get_shoot_look
        if type(orig) ~= "function" then
            return
        end
        Silent.hooked[item] = true
        rawset(item, "get_shoot_look", function(self, ...)
            local cf = orig(self, ...)
            if not (alive() and Settings.SilentAim) then
                return cf
            end
            local ok, res = pcall(Silent.redirect, cf)
            if ok and typeof(res) == "CFrame" then
                return res
            end
            return cf
        end)
    end
    function Silent.detach()
        for item in Silent.hooked do
            pcall(rawset, item, "get_shoot_look", nil)
        end
        table.clear(Silent.hooked)
    end
    function Silent.step()
        local item = Game.gun()
        if item then
            Silent.attach(item)
        end
    end
    table.insert(Cleanups, Silent.detach)
end

--// Aimbot + triggerbot \\--
local Aim = { target = nil }
local FovCircle, SilentCircle
do
    local OPTS = {}
    local function holding(item)
        local when = Settings.AimWhen
        if when == "Always" then
            return true
        elseif when == "Aiming down sights" then
            return item ~= nil and item.states.sights and item.states.sights:get() == true
        elseif when == "While shooting" then
            return item ~= nil and item.shoot_hold == true
        elseif when == "Left mouse" then
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end

    local function stillValid(a)
        if not (a and a.t.model.Parent == Workspace and a.t.hum.Health > 0) then
            return false
        end
        local part = Targets.part(a.t, Settings.AimPart)
        a.part = part
        local sp, front = Targets.screen(part.Position)
        if not front or (sp - camera().ViewportSize / 2).Magnitude > Settings.AimFOV * 1.5 then
            return false
        end
        return not Settings.VisibleOnly or Targets.visible(part)
    end

    -- Turns the camera toward `to` by a fraction of the angle, keeping its roll (the game's
    -- lean) and its position untouched.
    local function turn(cam, to, alpha)
        local cf = cam.CFrame
        local look = cf.LookVector
        local dir = (to - cf.Position).Unit
        local axis = look:Cross(dir)
        if axis.Magnitude < 1e-4 then
            return
        end
        local angle = math.acos(math.clamp(look:Dot(dir), -1, 1)) * alpha
        cam.CFrame = CFrame.new(cf.Position) * CFrame.fromAxisAngle(axis.Unit, angle) * (cf - cf.Position)
    end

    function Aim.step(dt)
        if not Settings.Aimbot or camera().CameraType == Enum.CameraType.Scriptable then
            Aim.target = nil
            return
        end
        local item = Game.gun()
        if not holding(item) then
            Aim.target = nil
            return
        end
        if not (Settings.StickyTarget and stillValid(Aim.target)) then
            OPTS.fov, OPTS.maxDist, OPTS.visible = Settings.AimFOV, Settings.AimMaxDistance, Settings.VisibleOnly
            OPTS.part, OPTS.teammates = Settings.AimPart, Settings.AimTeammates
            Aim.target = Targets.pick(OPTS)
        end
        local a = Aim.target
        if not a then
            return
        end
        local k = math.max(Settings.Smoothness, 1)
        local alpha = 1 - (1 - 1 / k) ^ (math.clamp(dt, 0, 0.1) * 60)
        turn(camera(), a.part.Position, alpha)
    end

    -- Trigger: fires the game's own input_shoot when your crosshair is on an enemy body.
    local lastShot, armedAt = 0, nil
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    function Aim.trigger()
        local item = Game.gun()
        if not (Settings.Triggerbot and item and type(item.input_shoot) == "function") then
            armedAt = nil
            return
        end
        if Settings.TriggerOnlyAiming and not (item.states.sights and item.states.sights:get()) then
            armedAt = nil
            return
        end
        local cam = camera()
        local ignore = { cam }
        if LocalPlayer.Character then
            table.insert(ignore, LocalPlayer.Character)
        end
        local vms = Workspace:FindFirstChild("Viewmodels")
        local mine = vms and vms:FindFirstChild("LocalViewmodel")
        if mine then
            table.insert(ignore, mine)
        end
        rayParams.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * Settings.AimMaxDistance, rayParams)
        local inst = hit and hit.Instance
        local onEnemy = false
        if inst and inst:GetAttribute("Humanoid") then
            for _, t in Targets.list(Settings.AimTeammates) do
                if t.vm and inst.Parent == t.vm then
                    onEnemy = not Settings.TriggerHeadOnly or inst.Name == "head"
                    break
                end
            end
        end
        if not onEnemy then
            armedAt = nil
            return
        end
        local now = os.clock()
        armedAt = armedAt or now
        if now - armedAt >= Settings.TriggerDelay / 1000 and now - lastShot >= 0.08 then
            lastShot = now
            pcall(item.input_shoot, item, true)
            task.delay(0.04, function()
                pcall(item.input_shoot, item, false)
            end)
        end
    end

    local function circle(color)
        local ok, c = pcall(Drawing.new, "Circle")
        if not ok then
            return nil
        end
        c.Thickness, c.NumSides, c.Filled, c.Color, c.Transparency, c.Visible = 1, 64, false, color, 0.9, false
        return c
    end
    FovCircle = circle(Color3.new(1, 1, 1))
    SilentCircle = circle(Color3.fromRGB(255, 120, 200))
    table.insert(Cleanups, function()
        for _, c in { FovCircle, SilentCircle } do
            pcall(c.Remove, c)
        end
    end)
end

--// ESP \\--
local Esp = { drawings = {}, chams = {}, util = {}, utilList = {}, utilAt = 0 }
do
    local SKELETON = {
        { "head", "torso" }, { "torso", "shoulder1" }, { "shoulder1", "arm1" }, { "torso", "shoulder2" },
        { "shoulder2", "arm2" }, { "torso", "hip1" }, { "hip1", "leg1" }, { "torso", "hip2" }, { "hip2", "leg2" },
    }
    local UTIL = {
        { group = "UtilTraps", label = "Claymore", tag = "Claymore" },
        { group = "UtilTraps", label = "Needle mine", tag = "NeedleMine" },
        { group = "UtilTraps", label = "Proximity alarm", tag = "ProximityAlarm" },
        { group = "UtilTraps", label = "Remote C4", tag = "RemoteC4" },
        { group = "UtilTraps", label = "Thermite", tag = "ThermiteCharge" },
        { group = "UtilTraps", label = "Breach charge", tag = "BreachCharge" },
        { group = "UtilTraps", label = "Hard breach", tag = "HardBreachCharge" },
        { group = "UtilTraps", label = "Incendiary", tag = "IncendiaryCanister" },
        { group = "UtilTraps", label = "Toxic charge", tag = "ToxicCharge" },
        { group = "UtilTraps", label = "Shock battery", tag = "ShockBattery" },
        { group = "UtilTraps", label = "Signal disruptor", tag = "SignalDisruptor" },
        { group = "UtilTraps", label = "Barbed wire", tag = "BarbedWire" },
        { group = "UtilCameras", label = "Sticky camera", tag = "StickyCamera" },
        { group = "UtilCameras", label = "Bulletproof camera", tag = "BulletproofCamera" },
        { group = "UtilCameras", label = "Drone", tag = "Drone" },
        { group = "UtilGrenades", label = "Frag", tag = "FragGrenade" },
        { group = "UtilGrenades", label = "Smoke", tag = "SmokeGrenade" },
        { group = "UtilGrenades", label = "Stun", tag = "StunGrenade" },
        { group = "UtilGrenades", label = "EMP", tag = "EMPGrenade" },
        { group = "UtilGrenades", label = "Impact", tag = "ImpactGrenade" },
        { group = "UtilGrenades", label = "Incendiary", tag = "IncendiaryGrenade" },
        { group = "UtilGrenades", label = "Launched", tag = "LaunchedGrenade" },
        { group = "BombEsp", label = "BOMB", tag = "Bomb" },
    }

    local function make(class, props)
        local ok, d = pcall(Drawing.new, class)
        if not ok then
            return nil
        end
        for k, v in props do
            d[k] = v
        end
        return d
    end
    local function newEntry()
        local e = {
            box = make("Square", { Thickness = 1, Filled = false, Visible = false }),
            outline = make("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0), Visible = false }),
            name = make("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            info = make("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
            hpBack = make("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
            hp = make("Line", { Thickness = 2, Visible = false }),
            tracer = make("Line", { Thickness = 1, Visible = false }),
            look = make("Line", { Thickness = 1, Visible = false }),
            bones = {},
        }
        for i = 1, #SKELETON do
            e.bones[i] = make("Line", { Thickness = 1, Visible = false })
        end
        return e
    end
    local function each(e, fn)
        for k, d in e do
            if k == "bones" then
                for _, b in d do
                    fn(b)
                end
            else
                fn(d)
            end
        end
    end
    local function hide(e)
        each(e, function(d)
            d.Visible = false
        end)
    end
    local function kill(e)
        each(e, function(d)
            pcall(d.Remove, d)
        end)
    end
    local function chamsParent()
        return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    end

    local function bounds(t)
        local cam = camera()
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local any = false
        local function add(pos)
            local sp = cam:WorldToViewportPoint(pos)
            if sp.Z > 0 then
                any = true
                minX, maxX = math.min(minX, sp.X), math.max(maxX, sp.X)
                minY, maxY = math.min(minY, sp.Y), math.max(maxY, sp.Y)
            end
        end
        if t.vm then
            for _, p in t.vm:GetChildren() do
                if p:IsA("BasePart") then
                    add(p.Position)
                    if p.Name == "head" then
                        add(p.Position + Vector3.new(0, p.Size.Y * 0.7, 0))
                    end
                end
            end
        else
            add(t.root.Position + Vector3.new(0, 2.8, 0))
            add(t.root.Position - Vector3.new(0, 3, 0))
        end
        if not any then
            return nil
        end
        return minX - 8, minY - 6, maxX + 8, maxY + 6
    end

    local function equippedName(obj)
        local ok, inst = pcall(function()
            return obj.states.equipped:get()
        end)
        if ok and typeof(inst) == "Instance" then
            return inst.Name
        end
    end
    local function className(obj)
        local ok, v = pcall(function()
            return obj.states.class_name:get()
        end)
        return ok and v or nil
    end
    local function line(d, a, b, color)
        local sa, fa = Targets.screen(a)
        local sb, fb = Targets.screen(b)
        if fa and fb then
            d.From, d.To, d.Color, d.Visible = sa, sb, color, true
        else
            d.Visible = false
        end
    end

    local function players()
        local seen = {}
        if Settings.Esp then
            local cam = camera()
            local viewport = cam.ViewportSize
            for _, t in Targets.list(Settings.EspTeammates) do
                local dist = (t.root.Position - cam.CFrame.Position).Magnitude
                if dist <= Settings.EspMax then
                    seen[t.model] = true
                    local e = Esp.drawings[t.model]
                    if not e then
                        e = newEntry()
                        Esp.drawings[t.model] = e
                    end
                    local x1, y1, x2, y2 = bounds(t)
                    if not x1 then
                        hide(e)
                    else
                        local color = Targets.color(t.model, t.team)
                        local w, h = x2 - x1, y2 - y1
                        local mid = (x1 + x2) / 2
                        if Settings.EspBox and e.box then
                            e.outline.Position, e.outline.Size, e.outline.Visible = Vector2.new(x1, y1), Vector2.new(w, h), true
                            e.box.Position, e.box.Size, e.box.Color, e.box.Visible = Vector2.new(x1, y1), Vector2.new(w, h), color, true
                        else
                            e.box.Visible, e.outline.Visible = false, false
                        end
                        if Settings.EspName and e.name then
                            local owner = Players:GetPlayerFromCharacter(t.model)
                            e.name.Text = owner and owner.DisplayName or t.model.Name
                            e.name.Position, e.name.Color, e.name.Visible = Vector2.new(mid, y1 - 16), color, true
                        else
                            e.name.Visible = false
                        end
                        if Settings.EspHealth and e.hp then
                            local frac = math.clamp(t.hum.Health / math.max(t.hum.MaxHealth, 1), 0, 1)
                            e.hpBack.From, e.hpBack.To, e.hpBack.Visible = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y1), true
                            e.hp.From, e.hp.To = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y2 - h * frac)
                            e.hp.Color, e.hp.Visible = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(80, 255, 110), frac), true
                        else
                            e.hp.Visible, e.hpBack.Visible = false, false
                        end
                        local bits = {}
                        if Settings.EspWeapon then
                            bits[#bits + 1] = equippedName(t.obj)
                        end
                        if Settings.EspClass then
                            bits[#bits + 1] = className(t.obj)
                        end
                        if Settings.EspDistance then
                            bits[#bits + 1] = ("%dm"):format(math.floor(dist))
                        end
                        if #bits > 0 and e.info then
                            e.info.Text = table.concat(bits, "  ")
                            e.info.Position, e.info.Color, e.info.Visible = Vector2.new(mid, y2 + 2), Color3.new(1, 1, 1), true
                        else
                            e.info.Visible = false
                        end
                        if Settings.EspTracer and e.tracer then
                            e.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                            e.tracer.To, e.tracer.Color, e.tracer.Visible = Vector2.new(mid, y2), color, true
                        else
                            e.tracer.Visible = false
                        end
                        local vm = t.vm
                        for i, pair in SKELETON do
                            local a = Settings.EspSkeleton and vm and vm:FindFirstChild(pair[1])
                            local b = a and vm:FindFirstChild(pair[2])
                            if a and b and e.bones[i] then
                                line(e.bones[i], a.Position, b.Position, color)
                            elseif e.bones[i] then
                                e.bones[i].Visible = false
                            end
                        end
                        local head = vm and vm:FindFirstChild("head")
                        local ok, dir = pcall(function()
                            return t.obj.states.look:get()
                        end)
                        if Settings.EspLook and head and ok and typeof(dir) == "Vector3" and dir.Magnitude > 0.01 and e.look then
                            line(e.look, head.Position, head.Position + dir.Unit * 8, Color3.fromRGB(255, 220, 80))
                        elseif e.look then
                            e.look.Visible = false
                        end
                    end
                end
            end
        end
        for model, e in Esp.drawings do
            if not seen[model] then
                kill(e)
                Esp.drawings[model] = nil
            end
        end

        -- Chams: a highlight over the visible body, through walls.
        local chamSeen = {}
        if Settings.Esp and Settings.EspChams then
            for _, t in Targets.list(Settings.EspTeammates) do
                if t.vm then
                    chamSeen[t.model] = true
                    local h = Esp.chams[t.model]
                    if not h or h.Adornee ~= t.vm then
                        if h then
                            h:Destroy()
                        end
                        h = Instance.new("Highlight")
                        h.Adornee = t.vm
                        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        h.FillTransparency = 0.6
                        h.OutlineTransparency = 0
                        h.Parent = chamsParent()
                        Esp.chams[t.model] = h
                    end
                    local color = Targets.color(t.model, t.team)
                    h.FillColor, h.OutlineColor = color, color
                end
            end
        end
        for model, h in Esp.chams do
            if not chamSeen[model] then
                pcall(h.Destroy, h)
                Esp.chams[model] = nil
            end
        end
    end

    -- Placed gear, grenades and the bomb, found by their tags (refreshed twice a second).
    local function gear()
        local now = os.clock()
        if now - Esp.utilAt > 0.5 then
            Esp.utilAt = now
            table.clear(Esp.utilList)
            local vms = Workspace:FindFirstChild("Viewmodels")
            for _, def in UTIL do
                if Settings[def.group] then
                    for _, inst in CollectionService:GetTagged(def.tag) do
                        if inst:IsDescendantOf(Workspace) and not (vms and inst:IsDescendantOf(vms)) then
                            table.insert(Esp.utilList, { inst = inst, label = def.label })
                        end
                    end
                end
            end
        end
        local cam = camera()
        local seen = {}
        for _, item in Esp.utilList do
            local inst = item.inst
            if inst.Parent then
                local pos
                if inst:IsA("Model") then
                    pos = inst:GetPivot().Position
                elseif inst:IsA("BasePart") then
                    pos = inst.Position
                end
                if pos then
                    local dist = (pos - cam.CFrame.Position).Magnitude
                    local sp, front = Targets.screen(pos)
                    if front and dist <= Settings.UtilMax then
                        seen[inst] = true
                        local d = Esp.util[inst]
                        if not d then
                            d = make("Text", { Size = 13, Center = true, Outline = true, Color = Color3.fromRGB(255, 200, 60) })
                            Esp.util[inst] = d
                        end
                        if d then
                            d.Text = ("%s %dm"):format(item.label, math.floor(dist))
                            d.Position, d.Visible = sp, true
                        end
                    end
                end
            end
        end
        for inst, d in Esp.util do
            if not seen[inst] then
                pcall(d.Remove, d)
                Esp.util[inst] = nil
            end
        end
    end

    function Esp.step()
        players()
        gear()
    end
    function Esp.clear()
        for model, e in Esp.drawings do
            kill(e)
            Esp.drawings[model] = nil
        end
        for model, h in Esp.chams do
            pcall(h.Destroy, h)
            Esp.chams[model] = nil
        end
        for inst, d in Esp.util do
            pcall(d.Remove, d)
            Esp.util[inst] = nil
        end
    end
    table.insert(Cleanups, Esp.clear)
end

--// World \\--
local World = {}
do
    local saved
    function World.fullbright(on)
        if on then
            saved = saved or {
                Brightness = Lighting.Brightness, FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            }
            Lighting.Brightness = 2
            Lighting.FogEnd = 1e6
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(190, 190, 190)
            Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190)
        elseif saved then
            for k, v in saved do
                Lighting[k] = v
            end
            saved = nil
        end
    end
    table.insert(Cleanups, function()
        World.fullbright(false)
    end)

    -- The game restores the camera to its own OriginalFOV attribute after every zoom, so that
    -- is the value to change. Scoped views are left alone.
    local originalFov
    function World.fov()
        local cam = camera()
        if not cam then
            return
        end
        if Settings.FovChanger then
            local current = cam:GetAttribute("OriginalFOV")
            if originalFov == nil then
                originalFov = current
            end
            if current ~= Settings.FovValue then
                local zoomed = cam.FieldOfView < (current or 70) - 1
                cam:SetAttribute("OriginalFOV", Settings.FovValue)
                if not zoomed then
                    cam.FieldOfView = Settings.FovValue
                end
            end
        elseif originalFov ~= nil then
            cam:SetAttribute("OriginalFOV", originalFov)
            originalFov = nil
        end
    end
    table.insert(Cleanups, function()
        Settings.FovChanger = false
        pcall(World.fov)
    end)

    -- Flashbangs paint a full-screen frame called Flash; keep it invisible.
    local flash
    function World.noFlash()
        if not Settings.NoFlash then
            if flash and flash.Parent then
                flash.Visible = true
            end
            return
        end
        if not (flash and flash.Parent) then
            local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local found = gui and gui:FindFirstChild("Flash", true)
            flash = found and found:FindFirstChild("Frame") or nil
        end
        if flash then
            flash.Visible = false
        end
    end

    -- Smoke clouds are parts called SmokePart dropped into Workspace. Hide them (and their
    -- particles) the moment they appear.
    local function hideSmoke(part)
        if part.Name ~= "SmokePart" or not Settings.NoSmoke then
            return
        end
        task.defer(function()
            if part:IsA("BasePart") then
                part.Transparency = 1
            end
            for _, d in part:GetDescendants() do
                if d:IsA("ParticleEmitter") then
                    d.Enabled = false
                elseif d:IsA("BasePart") then
                    d.Transparency = 1
                end
            end
        end)
    end
    bind(Workspace.DescendantAdded, function(d)
        if d.Name == "SmokePart" then
            hideSmoke(d)
        end
    end)
end

--// Anti-AFK \\--
bind(LocalPlayer.Idled, function()
    if Settings.AntiAfk and alive() then
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end
end)

--// Main loop \\--
-- The camera step runs after everything else bound to the render step, so the game's own
-- offsets are already on the frame it turns.
local BIND = "OperationOneAim"
pcall(RunService.UnbindFromRenderStep, RunService, BIND)
RunService:BindToRenderStep(BIND, Enum.RenderPriority.Last.Value + 10, function(dt)
    if alive() then
        pcall(Aim.step, dt)
    end
end)
table.insert(Cleanups, function()
    pcall(RunService.UnbindFromRenderStep, RunService, BIND)
end)

bind(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    pcall(function()
        local centre = camera().ViewportSize / 2
        if FovCircle then
            FovCircle.Visible = Settings.Aimbot and Settings.ShowFOV
            FovCircle.Radius, FovCircle.Position = Settings.AimFOV, centre
        end
        if SilentCircle then
            SilentCircle.Visible = Settings.SilentAim and Settings.SilentShowFOV
            SilentCircle.Radius, SilentCircle.Position = Settings.SilentFOV, centre
        end
        Silent.step()
        Gun.step()
        Gun.autoReload()
        Aim.trigger()
        Esp.step()
        World.fov()
        World.noFlash()
    end)
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "OPERATION ONE",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = IsTouch and UDim2.fromOffset(520, 340) or UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/OperationOne",
})
local function toggle(box, key, text, tip, after)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
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
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.5)
        end
    end)
end

do
    local Tab = Window:AddTab("Aim", "crosshair", "Aimbot, silent aim, trigger")
    local A = Tab:AddLeftGroupbox("Aimbot", "crosshair")
    toggle(A, "Aimbot", "Aimbot", "Turns your camera toward the enemy closest to your crosshair. Works with touch")
    dropdown(A, "AimWhen", "Aim when", { "Aiming down sights", "While shooting", "Always", "Right mouse", "Left mouse" },
        "Sights and shooting come from the gun itself, so they work on mobile")
    dropdown(A, "AimPart", "Aim at", { "Head", "Torso" })
    slider(A, "AimFOV", "FOV", 30, 600, 0, " px")
    slider(A, "Smoothness", "Smoothness", 1, 30, 0, "", "1 snaps, higher is slower and harder to spot")
    slider(A, "AimMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(A, "VisibleOnly", "Visible only", "Ignores enemies behind walls (bullets pass some thin walls, this doesn't)")
    toggle(A, "StickyTarget", "Sticky target")
    toggle(A, "AimTeammates", "Include teammates")
    toggle(A, "ShowFOV", "Show FOV circle")

    local S = Tab:AddRightGroupbox("Silent aim", "ghost")
    toggle(S, "SilentAim", "Silent aim", "The shot goes at the target; your camera doesn't move")
    dropdown(S, "SilentPart", "Aim at", { "Head", "Torso", "Random" })
    slider(S, "SilentFOV", "FOV", 30, 800, 0, " px", "Measured from the middle of the screen")
    slider(S, "SilentHitChance", "Hit chance", 1, 100, 0, "%", "Chance per shot that it is redirected")
    slider(S, "SilentMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(S, "SilentVisible", "Visible only", "Bullets stop at walls, so shots at hidden players just hit the wall")
    toggle(S, "SilentLook", "Face target on shot", "Also sets your replicated look direction. Try it if shots don't register")
    toggle(S, "SilentShowFOV", "Show FOV circle")
    status(S, function()
        local l = Silent.last
        if l and os.clock() - l.at < 3 then
            return "Last redirect: " .. l.name
        end
        return Game.gun() and "Waiting for a shot" or "No gun in hand"
    end)

    local T = Tab:AddRightGroupbox("Triggerbot", "mouse-pointer-click")
    toggle(T, "Triggerbot", "Triggerbot", "Fires the game's own shoot when your crosshair is on an enemy. Works with touch")
    slider(T, "TriggerDelay", "Delay", 0, 300, 0, " ms")
    toggle(T, "TriggerHeadOnly", "Head only")
    toggle(T, "TriggerOnlyAiming", "Only while aiming", "Needs the sights up")
end

do
    local Tab = Window:AddTab("Gun", "target", "Recoil, fire rate, reload")
    local G = Tab:AddLeftGroupbox("Gun", "target")
    toggle(G, "NoRecoil", "No recoil")
    toggle(G, "NoSpread", "No spread")
    toggle(G, "FastAds", "Fast aim", "Brings the sights up almost instantly")
    toggle(G, "FastReload", "Fast reload", "Raises reload_speed. The server may still make you wait")
    slider(G, "ReloadScale", "Reload speed", 1, 3, 1, "x")
    toggle(G, "RapidFire", "Rapid fire", "Raises the fire rate your client allows. Risky: the server may cap it")
    slider(G, "RapidScale", "Fire rate", 1, 3, 1, "x")
    toggle(G, "AutoReload", "Auto reload", "Reloads when the magazine is empty")
    status(G, function()
        local item = Game.gun()
        if not item then
            return "No gun in hand"
        end
        local s = item.states
        return ("%s\nrecoil %.1f/%.1f  spread %.2f  rate %d"):format(
            item.instance and item.instance.Name or "gun", s.recoil_up.value or 0, s.recoil_side.value or 0,
            s.spread.value or 0, math.floor(s.firerate.value or 0))
    end)
    local P = Tab:AddRightGroupbox("Player", "user")
    toggle(P, "SpeedHack", "Speed boost", "Multiplies your speed_multiplier. Risky: the server may pull you back")
    slider(P, "SpeedScale", "Speed", 1, 2, 2, "x")
end

do
    local Tab = Window:AddTab("ESP", "eye", "Players, gear, bomb")
    local E = Tab:AddLeftGroupbox("Players", "eye")
    toggle(E, "Esp", "ESP")
    toggle(E, "EspBox", "Boxes")
    toggle(E, "EspName", "Names")
    toggle(E, "EspHealth", "Health bar")
    toggle(E, "EspDistance", "Distance")
    toggle(E, "EspWeapon", "Weapon")
    toggle(E, "EspClass", "Class")
    toggle(E, "EspSkeleton", "Skeleton")
    toggle(E, "EspLook", "Look direction", "A line along where each player is aiming")
    toggle(E, "EspTracer", "Tracers")
    toggle(E, "EspChams", "Chams", "A see-through-walls highlight on each body")
    toggle(E, "EspTeammates", "Teammates too")
    slider(E, "EspMax", "Max distance", 50, 1500, 0, " studs")
    local B = Tab:AddRightGroupbox("Gear", "map")
    toggle(B, "UtilTraps", "Traps and charges", "Claymores, mines, alarms, C4, breach charges, thermite, barbed wire...")
    toggle(B, "UtilCameras", "Cameras and drones")
    toggle(B, "UtilGrenades", "Grenades", "Thrown and launched ones")
    toggle(B, "BombEsp", "Bomb", "Where the bomb is, in the Bomb gamemode")
    slider(B, "UtilMax", "Max distance", 50, 600, 0, " studs")
    status(B, function()
        local ws = Workspace
        return ("%s on %s\nRound %s / %s\nYou: %s"):format(
            tostring(ws:GetAttribute("Gamemode") or "?"), tostring(ws:GetAttribute("CurrentMap") or "?"),
            tostring(ws:GetAttribute("Round") or "?"), tostring(ws:GetAttribute("BestOf") or "?"),
            tostring(LocalPlayer:GetAttribute("Team") or "no team"))
    end)
end

do
    local Tab = Window:AddTab("Misc", "settings", "World and script")
    local W = Tab:AddLeftGroupbox("World", "sun")
    toggle(W, "Fullbright", "Fullbright", nil, World.fullbright)
    toggle(W, "NoFlash", "No flashbang", "Hides the white-out frame (the ringing still plays)")
    toggle(W, "NoSmoke", "No smoke", "Hides smoke clouds as they appear")
    toggle(W, "FovChanger", "FOV changer", "Changes the game's own base FOV; scopes still zoom")
    slider(W, "FovValue", "FOV", 60, 120, 0, "")
    local M = Tab:AddRightGroupbox("Script", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__OperationOneUnload then
            Genv.__OperationOneUnload()
        end
    end })
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
Genv.__OperationOneUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(Game.SO and "Loaded" or "Loaded (StateObject module not found: gun and body data won't work)", 4)

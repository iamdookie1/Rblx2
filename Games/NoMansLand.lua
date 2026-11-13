--// No Man's Land -------------------------------------------------------------------
-- place 117090155680637. Built on Ui3.
--
-- How the game works (as the client sees it):
--   Aim     Client.Shared.InputManager.aimRaycast / getAimRay give the point
--           under the crosshair. Guns (Tools.GunController) shoot from the
--           barrel toward it and send GunShoot { tool, aimDirection, shotId };
--           the bullet is simulated here and its hit is reported. Melee
--           (Tools.MeleeController) sends MeleeSwing { targetPosition } and
--           checks a sphere of MeleeRange/2, 3 studs in front of you.
--           Players can't be hit: only mobs (tag Mob) and Damageable parts.
--   Loot    ProximityPrompts: "Open" on loot boxes (0.5 s hold, 4.9 studs),
--           "Pick up" on items (0.8 s, 6 studs).
--   Fishing FishingCatch starts the HUD.FishingMinigame bar; a click with the
--           cursor inside TargetZone lands the fish.
--   Speed   Shared.WalkSpeedManager.SetMultiplier(name, x) stacks on 16.
--
-- Everything goes through the game's own aim, buttons and prompts, from where
-- you really are. Nothing fakes a hit, a position or a result, and nothing
-- simulates mouse or touch input (that broke mobile).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__NmlUnload then
    pcall(Genv.__NmlUnload)
end
Genv.__NmlRun = (Genv.__NmlRun or 0) + 1
local RUN = Genv.__NmlRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__NmlRun == RUN
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

local Settings = {
    -- combat
    SilentAim = false, AimPart = "Head", FOV = 180, ShowFOV = true, AimRange = 500, VisibleOnly = true,
    AutoShoot = false, AutoMelee = false, FaceTarget = true, AutoReload = false, NoRecoil = false,
    AutoHeal = false, HealAt = 50,
    -- gun mods
    FastBullets = false, BulletSpeed = 2500, NoDrop = false, NoBounce = false, InstantSpin = false, NoMinigunSlow = false,
    -- loot
    AutoOpen = false, AutoPickup = false, PickupFilter = "",
    -- fishing
    AutoCast = false, AutoReel = false,
    -- esp
    EspMobs = false, EspPlayers = false, EspLoot = false, EspItems = false, EspDrift = false, EspTraders = false,
    EspHealth = true, EspDistance = true, EspMax = 600,
    -- movement / world
    SpeedOn = false, Speed = 1.4, InfJump = false, Fullbright = false, NoFog = false,
    Fly = false, FlySpeed = 50, Noclip = false, WaterWalk = false, FastSwim = false, AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[NoMansLand] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "No Man's Land", Description = text, Time = seconds or 3 })
end
local function character()
    return LocalPlayer.Character
end
local function rootPart()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function equipped()
    local c = character()
    return c and c:FindFirstChildOfClass("Tool")
end

local Client
pcall(function()
    Client = LocalPlayer:WaitForChild("PlayerScripts", 10):WaitForChild("Client", 10)
end)
local function clientModule(path)
    local inst = Client
    for name in path:gmatch("[^%.]+") do
        inst = inst and inst:WaitForChild(name, 5)
    end
    if not inst then
        return nil
    end
    local ok, mod = pcall(require, inst)
    return ok and type(mod) == "table" and mod or nil
end
local InputManager = clientModule("Shared.InputManager")
local WalkSpeedManager = clientModule("Shared.WalkSpeedManager")

local MobileButtons = clientModule("Shared.MobileButtonManager")
local GunAmmoState = clientModule("Shared.GunAmmoState")
local GunMods = {}
local function sharedModule(name)
    local ok, mod = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Shared", 5):WaitForChild(name, 5))
    end)
    return ok and type(mod) == "table" and mod or nil
end
local GunConfig = sharedModule("GunConfig")
local GameConfig = sharedModule("GameConfig")
local OceanWaveAPI = sharedModule("OceanWaveAPI")

--// Buttons: the game's own action handlers, no fake input \\--
-- Every tool registers its action with MobileButtonManager:CreateButton(name,
-- { OnInputBegan, OnInputEnded }) on equip, on PC too (only the on-screen
-- button is mobile-only). Calling those handlers is exactly what tapping the
-- Shoot / Swing / Cast / Heal / Reload button does, so nothing touches the
-- mouse, the touch screen or the camera. (VirtualInputManager clicks landed on
-- the mobile UI and dragged the camera.)
local Buttons = { seen = {} }
do
    local registry
    if MobileButtons then
        -- HasButton's only upvalue is the name -> options table.
        pcall(function()
            if debug.getupvalues then
                local ups = debug.getupvalues(MobileButtons.HasButton)
                registry = type(ups) == "table" and type(ups[1]) == "table" and ups[1] or nil
            end
            if not registry and debug.getupvalue then
                local up = debug.getupvalue(MobileButtons.HasButton, 1)
                registry = type(up) == "table" and up or nil
            end
        end)
        -- Also record new registrations ourselves, in case upvalues aren't readable.
        local saved = Genv.__NmlButtonOriginals
        if saved then
            MobileButtons.CreateButton, MobileButtons.RemoveButton = saved.create, saved.remove
        end
        local origCreate, origRemove = MobileButtons.CreateButton, MobileButtons.RemoveButton
        if type(origCreate) == "function" and type(origRemove) == "function" then
            Genv.__NmlButtonOriginals = { create = origCreate, remove = origRemove }
            MobileButtons.CreateButton = function(self, name, opts, ...)
                Buttons.seen[name] = opts
                return origCreate(self, name, opts, ...)
            end
            MobileButtons.RemoveButton = function(self, name, ...)
                Buttons.seen[name] = nil
                return origRemove(self, name, ...)
            end
            table.insert(Cleanups, function()
                MobileButtons.CreateButton, MobileButtons.RemoveButton = origCreate, origRemove
                Genv.__NmlButtonOriginals = nil
            end)
        end
    end
    function Buttons.get(name)
        local opts = (registry and registry[name]) or Buttons.seen[name]
        return type(opts) == "table" and opts or nil
    end
    function Buttons.begin(name)
        local opts = Buttons.get(name)
        if opts and type(opts.OnInputBegan) == "function" then
            task.spawn(opts.OnInputBegan)
            return true
        end
        return false
    end
    function Buttons.finish(name)
        local opts = Buttons.get(name)
        if opts and type(opts.OnInputEnded) == "function" then
            task.spawn(opts.OnInputEnded)
        end
    end
    -- A quick tap: press and let go.
    function Buttons.tap(name)
        if Buttons.begin(name) then
            task.delay(0.03, Buttons.finish, name)
            return true
        end
        return false
    end
    Buttons.status = registry and "ready" or (MobileButtons and "ready (hooked)" or "button manager not found")
end

--// Mobs \\--
local Mobs = {}
do
    function Mobs.alive(model)
        local hum = model and model:FindFirstChildOfClass("Humanoid")
        return hum and hum.Health > 0 and model:FindFirstChild("HumanoidRootPart") ~= nil, hum
    end
    function Mobs.list()
        local out = {}
        for _, m in CollectionService:GetTagged("Mob") do
            if m:IsA("Model") and m:IsDescendantOf(Workspace) and Mobs.alive(m) then
                table.insert(out, m)
            end
        end
        return out
    end
    function Mobs.part(model)
        return model:FindFirstChild(Settings.AimPart) or model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
    end
end

--// Targeting \\--
local Target = { model = nil, part = nil }
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local function crosshair()
        if InputManager and type(InputManager.CrosshairX) == "number" and type(InputManager.CrosshairY) == "number" then
            return Vector2.new(InputManager.CrosshairX, InputManager.CrosshairY)
        end
        local cam = Workspace.CurrentCamera
        if UserInputService.MouseEnabled and not UserInputService.TouchEnabled then
            return UserInputService:GetMouseLocation()
        end
        return cam and cam.ViewportSize / 2 or Vector2.zero
    end
    Target.crosshair = crosshair
    function Target.visible(part, model)
        local head = character() and character():FindFirstChild("Head")
        if not head then
            return false
        end
        local ignore = { character(), model }
        local tracers = Workspace:FindFirstChild("LocalBulletTracers")
        if tracers then
            table.insert(ignore, tracers)
        end
        params.FilterDescendantsInstances = ignore
        params.RespectCanCollide = true
        return Workspace:Raycast(head.Position, part.Position - head.Position, params) == nil
    end
    function Target.pick()
        local cam = Workspace.CurrentCamera
        local root = rootPart()
        if not (cam and root) then
            return nil
        end
        local center = crosshair()
        local best, bestScore, bestPart
        for _, m in Mobs.list() do
            local part = Mobs.part(m)
            local dist = (part.Position - root.Position).Magnitude
            if dist <= Settings.AimRange then
                local screen, onScreen = cam:WorldToViewportPoint(part.Position)
                if onScreen then
                    local px = (Vector2.new(screen.X, screen.Y) - center).Magnitude
                    if px <= Settings.FOV and (not Settings.VisibleOnly or Target.visible(part, m)) then
                        local score = px + dist * 0.05
                        if not bestScore or score < bestScore then
                            best, bestScore, bestPart = m, score, part
                        end
                    end
                end
            end
        end
        return best, bestPart
    end
    loop(0.05, function()
        if Settings.SilentAim or Settings.AutoShoot then
            Target.model, Target.part = Target.pick()
        else
            Target.model, Target.part = nil, nil
        end
    end)
end

--// Silent aim: the game's own aim points at the target \\--
local Aim = { status = "InputManager not found" }
do
    local saved = Genv.__NmlAimOriginals
    if InputManager and saved then
        InputManager.aimRaycast, InputManager.getAimRay = saved.cast, saved.ray
    end
    if InputManager and type(InputManager.aimRaycast) == "function" and type(InputManager.getAimRay) == "function" then
        local origCast, origRay = InputManager.aimRaycast, InputManager.getAimRay
        Genv.__NmlAimOriginals = { cast = origCast, ray = origRay }
        local function weaponOut()
            local tool, c = equipped(), character()
            if c and c:GetAttribute("InMountedGun") then
                return true
            end
            return tool and (CollectionService:HasTag(tool, "Gun") or CollectionService:HasTag(tool, "Shotgun")
                or CollectionService:HasTag(tool, "Sniper") or CollectionService:HasTag(tool, "Bazooka")
                or CollectionService:HasTag(tool, "Minigun") or CollectionService:HasTag(tool, "Melee"))
        end
        local function aimPoint()
            if not (alive() and Settings.SilentAim and weaponOut()) then
                return nil
            end
            local part = Target.part
            if part and part.Parent and Mobs.alive(Target.model) then
                return part.Position
            end
            return nil
        end
        InputManager.getAimRay = function(...)
            local ray = origRay(...)
            local at = aimPoint()
            if at and typeof(ray) == "Ray" then
                return Ray.new(ray.Origin, (at - ray.Origin).Unit)
            end
            return ray
        end
        InputManager.aimRaycast = function(maxDist, params, ...)
            -- maxDist 100 is the game's own mobile "fire when the crosshair is on
            -- a mob" check. Leave it alone unless auto shoot is on, or silent aim
            -- would make your gun fire by itself on mobile.
            local at = (maxDist ~= 100 or Settings.AutoShoot) and aimPoint() or nil
            if at then
                local cam = Workspace.CurrentCamera
                local from = cam and cam.CFrame.Position or at
                local dir = at - from
                local hit = Workspace:Raycast(from, dir * 1.02, params or RaycastParams.new())
                return hit, at
            end
            return origCast(maxDist, params, ...)
        end
        Aim.status = "ready"
        table.insert(Cleanups, function()
            InputManager.aimRaycast, InputManager.getAimRay = origCast, origRay
            Genv.__NmlAimOriginals = nil
        end)
    end
end

-- FOV circle
do
    local ok, circle = pcall(function()
        local c = Drawing.new("Circle")
        c.Thickness = 1.5
        c.NumSides = 64
        c.Filled = false
        c.Color = Color3.fromRGB(255, 255, 255)
        c.Transparency = 0.7
        return c
    end)
    if ok and circle then
        bind(RunService.RenderStepped, function()
            circle.Visible = alive() and Settings.ShowFOV and (Settings.SilentAim or Settings.AutoShoot)
            circle.Radius = Settings.FOV
            circle.Position = Target.crosshair()
            circle.Color = Target.model and Color3.fromRGB(255, 80, 80) or Color3.fromRGB(255, 255, 255)
        end)
        table.insert(Cleanups, function()
            pcall(circle.Remove, circle)
        end)
    end
end

--// Auto shoot and auto melee \\--
-- Holds the game's own Shoot / Swing button while there's a target, so the
-- gun fires at its real fire rate (minigun spin-up included) and lets go after.
local function isGun(tool)
    return tool and (CollectionService:HasTag(tool, "Gun") or CollectionService:HasTag(tool, "Shotgun")
        or CollectionService:HasTag(tool, "Sniper") or CollectionService:HasTag(tool, "Bazooka")
        or CollectionService:HasTag(tool, "Minigun"))
end
do
    local function holder(button)
        local h = { tool = nil }
        function h.set(tool, on)
            if on and h.tool ~= tool then
                if h.tool then
                    Buttons.finish(button)
                end
                h.tool = Buttons.begin(button) and tool or nil
            elseif not on and h.tool then
                h.tool = nil
                Buttons.finish(button)
            end
        end
        table.insert(Cleanups, function()
            h.set(nil, false)
        end)
        return h
    end
    local Trigger, Swing, Mounted = holder("GunShoot"), holder("MeleeSwing"), holder("MountedGunFire")

    loop(0.05, function()
        local tool, c = equipped(), character()
        local firing = Settings.AutoShoot and Settings.SilentAim and Target.model ~= nil
            and not (c and c:GetAttribute("IsReloading"))
        -- Mounted guns on rafts: the same aim, their own Fire button.
        local mounted = c and c:GetAttribute("InMountedGun")
        Mounted.set("mounted", firing and mounted)
        local want = firing and not mounted and isGun(tool)
        -- Bazooka and sniper fire once per press, so press again each tick
        -- (the game's own fire rate check spaces the shots).
        if want and (CollectionService:HasTag(tool, "Bazooka") or CollectionService:HasTag(tool, "Sniper")) then
            Trigger.set(nil, false)
            Buttons.tap("GunShoot")
            return
        end
        Trigger.set(tool, want)
    end)

    -- Melee: the swing checks a sphere MeleeRange/2 wide, 3 studs in front.
    loop(0.1, function()
        local tool = equipped()
        local root = rootPart()
        if not (Settings.AutoMelee and tool and root and CollectionService:HasTag(tool, "Melee")) then
            Swing.set(nil, false)
            return
        end
        local range = tool:GetAttribute("MeleeRange") or 10
        local best, bestD
        for _, m in Mobs.list() do
            local d = (m.HumanoidRootPart.Position - root.Position).Magnitude
            if d <= 3 + range / 2 + 1.5 and (not bestD or d < bestD) then
                best, bestD = m, d
            end
        end
        if best then
            if Settings.FaceTarget then
                local at = best.HumanoidRootPart.Position
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(at.X, root.Position.Y, at.Z))
            end
            Target.model, Target.part = best, best.HumanoidRootPart
        end
        Swing.set(tool, best ~= nil)
    end)

    -- Auto reload: the Reload button once the magazine is empty.
    loop(0.3, function()
        if not (Settings.AutoReload and GunAmmoState and GunAmmoState.currentGun) then
            return
        end
        local c = character()
        if GunAmmoState.ammoSynced and GunAmmoState.currentAmmo <= 0 and not (c and c:GetAttribute("IsReloading")) then
            Buttons.tap("GunReload")
        end
    end)
end

--// No recoil: guns read KickbackIntensity from GunConfig.GetGunData \\--
do
    local saved = Genv.__NmlGunDataOriginal
    if GunConfig and saved then
        GunConfig.GetGunData = saved
    end
    if GunConfig and type(GunConfig.GetGunData) == "function" then
        local orig = GunConfig.GetGunData
        Genv.__NmlGunDataOriginal = orig
        GunConfig.GetGunData = function(...)
            local data = orig(...)
            if alive() and Settings.NoRecoil and type(data) == "table" then
                data.KickbackIntensity = 0
            end
            return data
        end
        table.insert(Cleanups, function()
            GunConfig.GetGunData = orig
            Genv.__NmlGunDataOriginal = nil
        end)
    end
end

--// Gun mods \\--
-- The bullet is simulated on your side (GunController + FastCast) and reads
-- these GunConfig numbers on every shot, so changing them changes your bullets.
do
    local KEYS = { "TracerSpeed", "BulletGravityDistance", "MinigunSpinupTime" }
    local orig = Genv.__NmlGunConfigOriginal or {}
    if GunConfig then
        for _, k in KEYS do
            if orig[k] == nil then
                orig[k] = GunConfig[k]
            end
        end
        Genv.__NmlGunConfigOriginal = orig
        loop(0.3, function()
            GunConfig.TracerSpeed = Settings.FastBullets and Settings.BulletSpeed or orig.TracerSpeed
            GunConfig.BulletGravityDistance = Settings.NoDrop and 1e6 or orig.BulletGravityDistance
            GunConfig.MinigunSpinupTime = Settings.InstantSpin and 0 or orig.MinigunSpinupTime
        end)
        table.insert(Cleanups, function()
            for _, k in KEYS do
                GunConfig[k] = orig[k]
            end
            Genv.__NmlGunConfigOriginal = nil
        end)
    end

    -- No water skip: bullets check OceanWaveAPI:GetHeight to bounce off waves.
    -- Only GunController's calls get a sea that's out of reach.
    local savedHeight = Genv.__NmlGetHeightOriginal
    if OceanWaveAPI and savedHeight then
        OceanWaveAPI.GetHeight = savedHeight
    end
    if OceanWaveAPI and type(OceanWaveAPI.GetHeight) == "function" then
        local origHeight = OceanWaveAPI.GetHeight
        Genv.__NmlGetHeightOriginal = origHeight
        OceanWaveAPI.GetHeight = function(self, ...)
            if Settings.NoBounce and alive() then
                -- Level 2 is whoever called GetHeight (no pcall here: it would add a frame).
                local src = debug.info(2, "s")
                if type(src) == "string" and src:find("GunController", 1, true) then
                    return -1e9
                end
            end
            return origHeight(self, ...)
        end
        GunMods = { height = origHeight }
        table.insert(Cleanups, function()
            OceanWaveAPI.GetHeight = origHeight
            Genv.__NmlGetHeightOriginal = nil
        end)
    end

    -- No minigun slowdown: the minigun sets a 0.5 "Minigun" walk speed multiplier.
    local savedSet = Genv.__NmlSetMultiplierOriginal
    if WalkSpeedManager and savedSet then
        WalkSpeedManager.SetMultiplier = savedSet
    end
    if WalkSpeedManager and type(WalkSpeedManager.SetMultiplier) == "function" then
        local origSet = WalkSpeedManager.SetMultiplier
        Genv.__NmlSetMultiplierOriginal = origSet
        WalkSpeedManager.SetMultiplier = function(name, ...)
            if name == "Minigun" and Settings.NoMinigunSlow and alive() then
                return WalkSpeedManager.ClearMultiplier(name)
            end
            return origSet(name, ...)
        end
        table.insert(Cleanups, function()
            WalkSpeedManager.SetMultiplier = origSet
            Genv.__NmlSetMultiplierOriginal = nil
        end)
    end
end

--// Auto heal: equip a bandage, hold Heal, switch back \\--
local Heal = { info = "idle" }
do
    local busy = false
    local function findBandage()
        local c = character()
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        for _, holder in { c, bp } do
            if holder then
                for _, t in holder:GetChildren() do
                    if t:IsA("Tool") and CollectionService:HasTag(t, "Bandage") then
                        return t
                    end
                end
            end
        end
        return nil
    end
    local function progressVisible()
        local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hud = gui and gui:FindFirstChild("HUD")
        local bar = hud and hud:FindFirstChild("BandageProgress")
        return bar and bar.Visible
    end
    loop(0.5, function()
        if busy or not Settings.AutoHeal then
            return
        end
        local hum, c = humanoid(), character()
        if not (hum and c and hum.Health > 0 and hum.Health / hum.MaxHealth * 100 < Settings.HealAt) then
            return
        end
        local bandage = findBandage()
        if not bandage then
            Heal.info = "no bandages"
            return
        end
        busy = true
        Heal.info = "healing"
        local ok, err = pcall(Heal.run, bandage, hum, c)
        if not ok then
            warn("[NoMansLand] heal: " .. tostring(err))
        end
        Heal.info = "idle"
        task.wait(1)
        busy = false
    end)
    function Heal.run(bandage, hum, c)
        local before = equipped()
        if bandage.Parent ~= c then
            hum:EquipTool(bandage)
        end
        -- Wait for BandageTool to register its Heal button.
        local t0 = os.clock()
        while alive() and not Buttons.get("BandageHeal") and os.clock() - t0 < 2 do
            task.wait(0.1)
        end
        if Buttons.begin("BandageHeal") then
            task.wait(0.4)
            t0 = os.clock()
            while alive() and progressVisible() and bandage.Parent == c and os.clock() - t0 < 10 do
                task.wait(0.1)
            end
            Buttons.finish("BandageHeal")
        end
        if before and before ~= bandage and before.Parent == LocalPlayer:FindFirstChildOfClass("Backpack") then
            task.wait(0.2)
            local h = humanoid()
            if h then
                h:EquipTool(before)
            end
        end
    end
end

--// Loot \\--
local Loot = { opened = 0, picked = 0 }
do
    local function firePrompt(prompt)
        if typeof(fireproximityprompt) ~= "function" then
            return false
        end
        local hold = prompt.HoldDuration
        prompt.HoldDuration = 0
        local ok = pcall(fireproximityprompt, prompt)
        prompt.HoldDuration = hold
        return ok
    end
    local function wanted(prompt)
        local filter = Settings.PickupFilter
        if filter == "" then
            return true
        end
        local item = prompt:FindFirstAncestorOfClass("Tool") or (prompt.Parent and prompt.Parent.Parent)
        local name = item and item.Name:lower() or ""
        for word in filter:lower():gmatch("[^,]+") do
            word = word:gsub("^%s+", ""):gsub("%s+$", "")
            if word ~= "" and name:find(word, 1, true) then
                return true
            end
        end
        return false
    end
    local cache, cacheAt = {}, -math.huge
    local function prompts()
        if os.clock() - cacheAt > 2 then
            cacheAt = os.clock()
            cache = {}
            for _, d in Workspace:GetDescendants() do
                if d:IsA("ProximityPrompt") and (d.Name == "OpenPrompt" or d.Name == "PickupPrompt") then
                    table.insert(cache, d)
                end
            end
        end
        return cache
    end
    local tried = setmetatable({}, { __mode = "k" })
    loop(0.25, function()
        if not (Settings.AutoOpen or Settings.AutoPickup) then
            return
        end
        local root = rootPart()
        if not root then
            return
        end
        for _, p in prompts() do
            if p.Parent and p.Enabled and (not tried[p] or os.clock() - tried[p] > 1.5) then
                local open = p.Name == "OpenPrompt"
                if (open and Settings.AutoOpen) or (not open and Settings.AutoPickup and wanted(p)) then
                    local holder = p.Parent
                    local pos = holder:IsA("Attachment") and holder.WorldPosition
                        or (holder:IsA("BasePart") and holder.Position) or nil
                    if pos and (pos - root.Position).Magnitude <= p.MaxActivationDistance - 0.3 then
                        tried[p] = os.clock()
                        if firePrompt(p) then
                            if open then
                                Loot.opened += 1
                            else
                                Loot.picked += 1
                            end
                        end
                    end
                end
            end
        end
    end)
end

--// Fishing \\--
local Fish = { info = "idle", caught = 0 }
do
    local function rod()
        local tool = equipped()
        return tool and CollectionService:HasTag(tool, "FishingRod") and tool or nil
    end
    local lastCast = -math.huge
    loop(0.5, function()
        if not Settings.AutoCast then
            return
        end
        local tool, c = rod(), character()
        if not (tool and c) then
            Fish.info = "equip a fishing rod"
            return
        end
        if c:GetAttribute("FishingBuoyActive") or c:GetAttribute("FishingReelInActive") then
            Fish.info = "waiting for a bite"
            return
        end
        if os.clock() - lastCast > 3 then
            lastCast = os.clock()
            Fish.info = "casting"
            -- The Cast button's handler. tool:Activate() is ignored on mobile.
            if not Buttons.tap("FishingRodCast") then
                pcall(tool.Activate, tool)
            end
        end
    end)

    -- The minigame's own click handler (onPlayerClick in UI.FishingMinigame):
    -- it checks the cursor against the zone and sends the result itself.
    local reelFn, searchedAt = nil, -math.huge
    local function fromMinigame(f)
        local ok, src = pcall(debug.info, f, "s")
        return ok and type(src) == "string" and src:find("FishingMinigame", 1, true) ~= nil
    end
    local function findReel()
        if reelFn or os.clock() - searchedAt < 5 or typeof(getgc) ~= "function" then
            return reelFn
        end
        searchedAt = os.clock()
        pcall(function()
            for _, f in getgc() do
                if type(f) == "function" and (typeof(islclosure) ~= "function" or islclosure(f)) then
                    local okN, name = pcall(debug.info, f, "n")
                    if okN and name == "onPlayerClick" and fromMinigame(f) then
                        reelFn = f
                        break
                    end
                end
            end
        end)
        return reelFn
    end
    -- Backup: the InputBegan connection the minigame opens while it runs, fed a tap.
    local FAKE_TAP = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown,
        UserInputState = Enum.UserInputState.Begin, Position = Vector3.zero }
    local function tapMinigame()
        local fn = findReel()
        if fn then
            return pcall(fn)
        end
        if typeof(getconnections) ~= "function" then
            return false
        end
        local hit = false
        for _, conn in getconnections(UserInputService.InputBegan) do
            local f = conn.Function
            if type(f) == "function" and fromMinigame(f) then
                hit = pcall(f, FAKE_TAP, false) or hit
            end
        end
        return hit
    end
    task.spawn(findReel)

    -- The bar sweeps back and forth; reel while the cursor is in the zone.
    local clickedAt = -math.huge
    local function click()
        if not tapMinigame() then
            Fish.info = "couldn't reach the minigame (needs getgc or getconnections)"
        end
    end
    bind(RunService.RenderStepped, function()
        if not (alive() and Settings.AutoReel) then
            return
        end
        local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hud = gui and gui:FindFirstChild("HUD")
        local game_ = hud and hud:FindFirstChild("FishingMinigame")
        if not (game_ and game_.Visible) then
            return
        end
        local cursor, zone = game_:FindFirstChild("Cursor"), game_:FindFirstChild("TargetZone")
        if not (cursor and zone) or os.clock() - clickedAt < 1.5 then
            return
        end
        local x = cursor.Position.X.Scale
        local mid, half = zone.Position.X.Scale, zone.Size.X.Scale / 2
        if x >= mid - half * 0.7 and x <= mid + half * 0.7 then
            clickedAt = os.clock()
            Fish.caught += 1
            Fish.info = "reeled in"
            task.spawn(click)
        end
    end)
end

--// ESP \\--
local Esp = { folder = Instance.new("Folder"), items = {} }
Esp.folder.Name = "NmlEsp"
Esp.folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
table.insert(Cleanups, function()
    Esp.folder:Destroy()
end)
do
    local COLORS = {
        Mob = Color3.fromRGB(255, 70, 70), Player = Color3.fromRGB(80, 160, 255), Loot = Color3.fromRGB(255, 200, 60),
        Item = Color3.fromRGB(90, 255, 120), Drift = Color3.fromRGB(80, 230, 230), Trader = Color3.fromRGB(220, 120, 255),
    }
    local function entry(obj, kind)
        local e = Esp.items[obj]
        if e then
            return e
        end
        local hl = Instance.new("Highlight")
        hl.FillTransparency = 0.75
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = obj
        hl.Parent = Esp.folder
        local bb = Instance.new("BillboardGui")
        bb.AlwaysOnTop = true
        bb.Size = UDim2.fromOffset(200, 34)
        bb.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
        bb.LightInfluence = 0
        local text = Instance.new("TextLabel")
        text.BackgroundTransparency = 1
        text.Size = UDim2.fromScale(1, 1)
        text.Font = Enum.Font.GothamBold
        text.TextSize = 13
        text.TextStrokeTransparency = 0.3
        text.Parent = bb
        bb.Parent = Esp.folder
        e = { hl = hl, bb = bb, text = text, kind = kind }
        Esp.items[obj] = e
        return e
    end
    local function drop(obj)
        local e = Esp.items[obj]
        if e then
            e.hl:Destroy()
            e.bb:Destroy()
            Esp.items[obj] = nil
        end
    end
    local function anchorOf(obj)
        if obj:IsA("BasePart") then
            return obj
        end
        return obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChild("HumanoidRootPart") or obj:FindFirstChildWhichIsA("BasePart", true))
            or (obj:IsA("Tool") and obj:FindFirstChild("Handle"))
    end
    local function inWorld(obj)
        return obj:IsDescendantOf(Workspace) and not obj:FindFirstAncestorOfClass("Backpack")
            and not (obj:IsA("Tool") and obj.Parent and obj.Parent:FindFirstChildOfClass("Humanoid"))
    end
    local function wantedObjects()
        local list = {}
        local function addTag(tag, kind, on)
            if not on then
                return
            end
            for _, o in CollectionService:GetTagged(tag) do
                if inWorld(o) then
                    list[o] = kind
                end
            end
        end
        addTag("Mob", "Mob", Settings.EspMobs)
        addTag("LootBox", "Loot", Settings.EspLoot)
        addTag("PickupableTool", "Item", Settings.EspItems)
        addTag("DriftingLoot", "Drift", Settings.EspDrift)
        addTag("Trader", "Trader", Settings.EspTraders)
        if Settings.EspPlayers then
            for _, p in Players:GetPlayers() do
                if p ~= LocalPlayer and p.Character then
                    list[p.Character] = "Player"
                end
            end
        end
        return list
    end
    loop(0.4, function()
        local root = rootPart()
        local want = wantedObjects()
        for obj in Esp.items do
            if not want[obj] then
                drop(obj)
            end
        end
        for obj, kind in want do
            local anchor = anchorOf(obj)
            local dist = (root and anchor) and (anchor.Position - root.Position).Magnitude or 0
            local mobAlive, hum = true, obj:FindFirstChildOfClass("Humanoid")
            if kind == "Mob" then
                mobAlive = Mobs.alive(obj)
            end
            if anchor and dist <= Settings.EspMax and mobAlive then
                local e = entry(obj, kind)
                local color = COLORS[kind]
                e.hl.FillColor, e.hl.OutlineColor = color, color
                e.bb.Adornee = anchor
                e.text.TextColor3 = color
                local name = obj:GetAttribute("ObjectName") or (kind == "Player" and obj.Name) or obj.Name
                local line = name
                if Settings.EspHealth and hum then
                    line ..= ("  %d/%d"):format(math.floor(hum.Health), math.floor(hum.MaxHealth))
                end
                if Settings.EspDistance then
                    line ..= ("  [%dm]"):format(math.floor(dist))
                end
                e.text.Text = line
            else
                drop(obj)
            end
        end
    end)
end

--// Movement and world \\--
do
    loop(0.5, function()
        if WalkSpeedManager and type(WalkSpeedManager.SetMultiplier) == "function" then
            if Settings.SpeedOn then
                WalkSpeedManager.SetMultiplier("DookieHub", Settings.Speed)
            else
                WalkSpeedManager.ClearMultiplier("DookieHub")
            end
        end
    end)
    table.insert(Cleanups, function()
        if WalkSpeedManager then
            pcall(WalkSpeedManager.ClearMultiplier, "DookieHub")
        end
    end)
    bind(UserInputService.JumpRequest, function()
        local hum = humanoid()
        if alive() and Settings.InfJump and hum and hum:GetState() == Enum.HumanoidStateType.Freefall then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)
    local saved = { Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
        FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows }
    local atmos = {}
    loop(0.5, function()
        if Settings.Fullbright then
            Lighting.Brightness = 2
            Lighting.Ambient = Color3.fromRGB(170, 170, 170)
            Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
            Lighting.GlobalShadows = false
        end
        if Settings.NoFog then
            Lighting.FogEnd = 1e6
            for _, a in Lighting:GetChildren() do
                if a:IsA("Atmosphere") then
                    atmos[a] = atmos[a] or a.Density
                    a.Density = 0
                end
            end
        end
    end)
    function Settings.restoreLighting()
        for k, v in saved do
            pcall(function()
                Lighting[k] = v
            end)
        end
        for a, d in atmos do
            pcall(function()
                a.Density = d
            end)
        end
        table.clear(atmos)
    end
    table.insert(Cleanups, Settings.restoreLighting)
end

--// Fly, noclip, water walk, fast swim, anti-AFK \\--
do
    -- Fly: a LinearVelocity on you, steered by your normal move input (the
    -- thumbstick on mobile) toward where the camera looks. Jump goes up.
    local fly = {}
    local function stopFly()
        if fly.lv then
            fly.lv:Destroy()
            fly.att:Destroy()
            fly.lv, fly.att = nil, nil
        end
    end
    bind(RunService.Heartbeat, function()
        local root, hum, cam = rootPart(), humanoid(), Workspace.CurrentCamera
        if not (alive() and Settings.Fly and root and hum and cam and hum.Health > 0) then
            stopFly()
            return
        end
        if not (fly.lv and fly.lv.Parent and fly.att.Parent == root) then
            stopFly()
            fly.att = Instance.new("Attachment")
            fly.att.Name = "NmlFly"
            fly.att.Parent = root
            fly.lv = Instance.new("LinearVelocity")
            fly.lv.Attachment0 = fly.att
            fly.lv.RelativeTo = Enum.ActuatorRelativeTo.World
            fly.lv.MaxForce = math.huge
            fly.lv.Parent = root
        end
        local move = hum.MoveDirection
        local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
        local flatLook = Vector3.new(look.X, 0, look.Z)
        local flatRight = Vector3.new(right.X, 0, right.Z)
        local vel = Vector3.zero
        if move.Magnitude > 0.05 and flatLook.Magnitude > 0.01 then
            vel = look * move:Dot(flatLook.Unit) + right * move:Dot(flatRight.Unit)
        end
        if hum.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            vel += Vector3.yAxis
        elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
            vel -= Vector3.yAxis
        end
        fly.lv.VectorVelocity = vel.Magnitude > 0 and vel.Unit * Settings.FlySpeed or Vector3.zero
    end)
    table.insert(Cleanups, stopFly)

    -- Noclip: your own parts stop colliding while it's on.
    local collided = setmetatable({}, { __mode = "k" })
    local function restoreCollide()
        for part, was in collided do
            if part.Parent then
                part.CanCollide = was
            end
        end
        table.clear(collided)
    end
    bind(RunService.Stepped, function()
        local c = character()
        if not (alive() and Settings.Noclip and c) then
            if next(collided) then
                restoreCollide()
            end
            return
        end
        for _, part in c:GetDescendants() do
            if part:IsA("BasePart") and part.CanCollide then
                if collided[part] == nil then
                    collided[part] = true
                end
                part.CanCollide = false
            end
        end
    end)
    table.insert(Cleanups, restoreCollide)

    -- Water walk: a hidden platform at the wave height under you, only when
    -- nothing else (your raft, a ship) is under your feet.
    local pad = Instance.new("Part")
    pad.Name = "NmlWaterWalk"
    pad.Size = Vector3.new(6, 1, 6)
    pad.Anchored = true
    pad.CanCollide = false
    pad.CanQuery = false
    pad.CanTouch = false
    pad.Transparency = 1
    pad.Parent = Workspace
    table.insert(Cleanups, function()
        pad:Destroy()
    end)
    local downParams = RaycastParams.new()
    downParams.FilterType = Enum.RaycastFilterType.Exclude
    local getHeight = function(pos)
        local fn = GunMods.height or (OceanWaveAPI and OceanWaveAPI.GetHeight)
        return fn(OceanWaveAPI, pos)
    end
    bind(RunService.Heartbeat, function()
        local root, c = rootPart(), character()
        if not (alive() and Settings.WaterWalk and not Settings.Fly and root and c and OceanWaveAPI) then
            pad.CanCollide = false
            return
        end
        local ok, h = pcall(getHeight, root.Position)
        if not ok or type(h) ~= "number" then
            pad.CanCollide = false
            return
        end
        -- Swimming: pop up onto the surface first.
        if c:GetAttribute("IsSwimming") and root.Position.Y < h + 2 then
            root.CFrame = root.CFrame + Vector3.new(0, h + 3.5 - root.Position.Y, 0)
            root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
        end
        downParams.FilterDescendantsInstances = { c, pad }
        local below = Workspace:Raycast(root.Position, Vector3.new(0, -(root.Position.Y - h) - 0.5, 0), downParams)
        local onSomething = below and below.Position.Y > h - 0.2
        pad.CanCollide = not onSomething and root.Position.Y > h - 0.5
        pad.CFrame = CFrame.new(root.Position.X, h - 0.5, root.Position.Z)
    end)

    -- Fast swim: the game's own dev switch (30 instead of 10 swim speed).
    local savedDev = Genv.__NmlDevAttributeOriginal
    if GameConfig and savedDev then
        GameConfig.GetDevAttribute = savedDev
    end
    if GameConfig and type(GameConfig.GetDevAttribute) == "function" then
        local origDev = GameConfig.GetDevAttribute
        Genv.__NmlDevAttributeOriginal = origDev
        GameConfig.GetDevAttribute = function(name, ...)
            if name == "FastSwim" and Settings.FastSwim and alive() then
                return true
            end
            return origDev(name, ...)
        end
        table.insert(Cleanups, function()
            GameConfig.GetDevAttribute = origDev
            Genv.__NmlDevAttributeOriginal = nil
        end)
    end

    -- Anti-AFK: switch off the 20 minute idle kick (LocalPlayer.Idled).
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, conn in getconnections(LocalPlayer.Idled) do
                if not idled[conn] and pcall(conn.Disable, conn) then
                    idled[conn] = true
                end
            end
        elseif next(idled) then
            for conn in idled do
                pcall(conn.Enable, conn)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for conn in idled do
            pcall(conn.Enable, conn)
        end
    end)
end

-- Back to your raft: the raft's mass centre, a little above it.
local function toRaft()
    local root = rootPart()
    local centre = CollectionService:GetTagged("PlayerRaftMassCenter")[1]
    if not (root and centre and centre:IsA("BasePart")) then
        notify("No raft found")
        return
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.new(centre.Position + Vector3.new(0, 5, 0))
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "No Man's Land",
    Footer = "dookie hub · Ui3",
    Icon = "anchor",
    Size = UDim2.fromOffset(640, 500),
    ConfigFolder = "Ui3/NoMansLand",
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

do
    local Tab = Window:AddTab("Combat", "crosshair", "Aim, shooting and melee")
    local AimBox = Tab:AddLeftGroupbox("Silent aim", "crosshair")
    toggle(AimBox, "SilentAim", "Silent aim", "Your guns and melee aim at the mob nearest your crosshair, inside the circle. The game's own aim, so the real shot goes there")
    AimBox:AddDropdown("AimPart", {
        Text = "Aim at", Values = { "Head", "HumanoidRootPart" }, Default = Settings.AimPart,
        Callback = function(v)
            Settings.AimPart = v
        end,
    })
    slider(AimBox, "FOV", "Circle size", 30, 600, 0, " px")
    toggle(AimBox, "ShowFOV", "Show circle")
    toggle(AimBox, "VisibleOnly", "Only if in sight", "Skip mobs behind walls (bullets would hit the wall)")
    slider(AimBox, "AimRange", "Range", 50, 1000, 0, " studs")
    local AimLabel = AimBox:AddLabel("...", true)

    local AutoBox = Tab:AddRightGroupbox("Auto", "zap")
    toggle(AutoBox, "AutoShoot", "Auto shoot", "Fires your gun, or the mounted gun you're on, while silent aim has a mob. Your gun's own fire rate and ammo")
    toggle(AutoBox, "AutoMelee", "Auto melee", "Swings when a mob is in your weapon's reach")
    toggle(AutoBox, "FaceTarget", "Turn to face it", "Melee hits in front of you, so this turns you toward the mob first")
    toggle(AutoBox, "AutoReload", "Auto reload", "Reloads when the magazine is empty, if you have ammo")
    toggle(AutoBox, "NoRecoil", "No recoil", "Your camera doesn't kick up when you shoot")

    local GunBox = Tab:AddLeftGroupbox("Gun mods", "zap")
    toggle(GunBox, "FastBullets", "Fast bullets", "Your bullets fly faster, so moving mobs are easier to hit")
    slider(GunBox, "BulletSpeed", "Bullet speed", 500, 5000, 0, " studs/s", "The game's default is 500")
    toggle(GunBox, "NoDrop", "No bullet drop", "Bullets stay straight past 800 studs")
    toggle(GunBox, "NoBounce", "No water skip", "Bullets go into the water instead of skipping off waves")
    toggle(GunBox, "InstantSpin", "Instant minigun spin-up", "No 3 second wind-up before the minigun fires")
    toggle(GunBox, "NoMinigunSlow", "No minigun slowdown", "Walk at full speed while the minigun fires")

    local HealBox = Tab:AddRightGroupbox("Healing", "heart")
    toggle(HealBox, "AutoHeal", "Auto bandage", "Below the health you set, takes out a bandage, heals, then switches back to what you held")
    slider(HealBox, "HealAt", "Heal below", 10, 95, 0, "%")
    local HealLabel = HealBox:AddLabel("...", true)
    loop(0.3, function()
        local t = Target.model
        AimLabel:SetText(("Aim: %s\nButtons: %s\nTarget: %s"):format(Aim.status, Buttons.status,
            t and ((t:GetAttribute("ObjectName") or t.Name) .. (Mobs.alive(t) and "" or " (dead)")) or "none"))
        HealLabel:SetText("Bandage: " .. Heal.info)
    end)
end

do
    local Tab = Window:AddTab("Loot", "package", "Loot and fishing")
    local LootBox = Tab:AddLeftGroupbox("Loot", "package")
    toggle(LootBox, "AutoOpen", "Auto open loot boxes", "Opens barrels and crates you walk past, within their normal reach")
    toggle(LootBox, "AutoPickup", "Auto pick up", "Picks up items you walk past, within their normal reach")
    LootBox:AddInput("PickupFilter", {
        Text = "Only pick up", Default = "", Finished = true, Placeholder = "empty = everything, or: ammo, bandage, pistol",
        Callback = function(v)
            Settings.PickupFilter = v
        end,
    })
    local LootLabel = LootBox:AddLabel("...", true)

    local FishBox = Tab:AddRightGroupbox("Fishing", "fish")
    toggle(FishBox, "AutoCast", "Auto cast", "Casts your rod whenever it's out of the water. Hold the rod")
    toggle(FishBox, "AutoReel", "Auto reel", "Reels in when the bar is in the zone. Works on mobile")
    local FishLabel = FishBox:AddLabel("...", true)
    loop(0.4, function()
        LootLabel:SetText(("Opened %d, picked up %d"):format(Loot.opened, Loot.picked))
        FishLabel:SetText(("Fishing: %s\nCaught: %d"):format(Fish.info, Fish.caught))
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "See through walls")
    local Box = Tab:AddLeftGroupbox("Show", "eye")
    toggle(Box, "EspMobs", "Mobs")
    toggle(Box, "EspPlayers", "Players")
    toggle(Box, "EspLoot", "Loot boxes")
    toggle(Box, "EspItems", "Items on the ground")
    toggle(Box, "EspDrift", "Drifting loot")
    toggle(Box, "EspTraders", "Traders")
    local Opt = Tab:AddRightGroupbox("Options", "settings")
    toggle(Opt, "EspHealth", "Health")
    toggle(Opt, "EspDistance", "Distance")
    slider(Opt, "EspMax", "Max distance", 50, 3000, 0, " studs")
end

do
    local Tab = Window:AddTab("Player", "user", "Movement and world")
    local Move = Tab:AddLeftGroupbox("Movement", "move")
    toggle(Move, "SpeedOn", "Speed boost", "Through the game's own walk speed system, on top of armor and potions")
    slider(Move, "Speed", "Speed", 1, 2.5, 2, "x")
    toggle(Move, "InfJump", "Jump in the air")
    toggle(Move, "Fly", "Fly", "Move where the camera looks. Jump (or Space) goes up, Ctrl goes down. Works with the mobile thumbstick")
    slider(Move, "FlySpeed", "Fly speed", 10, 150, 0, " studs/s")
    toggle(Move, "Noclip", "Noclip", "Walk through walls")
    toggle(Move, "WaterWalk", "Walk on water", "Stand on the sea like a floor. Off your raft only")
    toggle(Move, "FastSwim", "Fast swim", "The game's own fast swim (3x)")
    Move:AddButton({ Text = "Back to my raft", Func = toRaft, Tooltip = "Puts you on your raft if you fell off" })
    local World = Tab:AddRightGroupbox("World", "sun")
    toggle(World, "Fullbright", "Fullbright", nil, function(v)
        if not v then
            Settings.restoreLighting()
        end
    end)
    toggle(World, "NoFog", "No fog", nil, function(v)
        if not v then
            Settings.restoreLighting()
        end
    end)
    toggle(World, "AntiAfk", "Anti-AFK", "Stops Roblox kicking you after 20 minutes idle")
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
Genv.__NmlUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded" .. (Aim.status == "ready" and "" or (" (silent aim off: " .. Aim.status .. ")")), 4)

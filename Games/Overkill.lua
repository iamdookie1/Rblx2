--// OVERKILL -- silent aim, aim assist, triggerbot, auto shield, gun tweaks,
--// player / bullet / storm ESP, on Ui3.
--
-- Built against a script dump of the live game (lobby place 74996816424339,
-- match place 101878803733802, game 7872343282, version 112). What the game's
-- own client scripts show:
--  * Shooting is PlayerScripts.Combat.Bullets' shootBullet. The launch
--    direction comes from Utilities.Direction.Calculate(origin, cameraCFrame,
--    bulletSpeed, bulletGravity), then spread from Libraries.Math, then
--    BulletInit(serverTime, {id, origin, direction}, ...) goes to the server.
--    Bullets are projectiles; the server works out what they hit.
--  * A bullet flies along Utilities.Trajectory's path: origin + speed * dir * t,
--    dropping 0.5 * gravity * (|dir.Y|^4 * 0.5 + 1) * t^2. Every bullet, yours
--    and everyone's, is registered through Trajectory.Add / AddPath / LockOn.
--  * Firing listens to the game's own Input library ("MouseClick"), the shield
--    to "E". Pressing them through that library runs the game's own checks:
--    ammo, cooldown, reload, shield charge.
--  * The shield comes up 0.1s after it is pressed and reflects bullets.
--  * Characters live in workspace.Characters.Alive (moved into its Allies /
--    Enemies models in team modes). Teams come from Info "Team".
--  * The storm is a circle around the map's middle, radius in Utilities.Storm.
--
-- The game's own modules are found through getgc, so the hooks land on the
-- exact tables the game uses. Every hook is a field swap that unload puts
-- back. Nothing yields in a frame loop and every loop is bounded.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__OverkillStop) == "function" then pcall(Genv.__OverkillStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

--// settings ----------------------------------------------------------------

local Aim = {
    Silent = false,
    HitChance = 100,          -- % of shots that get aimed
    Part = "Head",            -- Head / Torso / Root / Nearest to crosshair
    Priority = "Crosshair",   -- Crosshair / Distance / Lowest health
    Sticky = true,
    TeamCheck = true,
    VisibleOnly = true,
    SkipShielding = true,     -- a raised shield reflects your shot back
    Predict = true,
    PredictScale = 1,
    ExtraLead = 0,            -- ms, for ping
    AutoPing = false,         -- add your measured ping to the lead
    PredictFalls = true,      -- targets in the air follow gravity down to the floor
    FallbackPart = true,      -- part hidden: use any other part of them that is visible
    ShowPoint = false,        -- dot where the shot is aimed to land
    PointColor = Color3.fromRGB(255, 255, 0),
    MaxDistance = 800,
    FOV = true,
    FOVCenter = true,         -- FOV and crosshair at the middle of the screen, not the mouse
    FOVRadius = 250,
    ShowFOV = true,
    FOVColor = Color3.fromRGB(255, 255, 255),
    ShowTarget = true,
    TargetColor = Color3.fromRGB(255, 80, 80),
}

local Assist = {
    Enabled = false,
    OnlyRightMouse = true,    -- only while aiming down with right mouse
    Method = "Mouse move",    -- Mouse move / Camera
    Smooth = 0.25,            -- share of the gap closed each frame
}

local Trigger = {
    Enabled = false,
    Delay = 0.05,             -- s before the shot
    Hold = 0.12,              -- s the trigger is held
    Radius = 35,              -- px from crosshair (without silent aim)
    WithSilent = true,        -- with silent aim on, fire whenever there is a target
    NeedAmmo = true,          -- don't pull the trigger on an empty gun or with the shield up
}

local Gun = {
    NoRecoil = false,
    NoShake = false,
    SpreadScale = 1,
}

local Shield = {
    Auto = false,
    Lead = 0.2,               -- s before impact to raise it
    Margin = 1.5,             -- studs of room counted as a hit
    IgnoreAllies = true,
}

local Esp = {
    Enabled = false,
    Allies = false,
    Chams = true,
    Names = true,
    Health = true,
    Distance = true,
    Cards = false,
    ShieldState = true,
    Tracers = false,
    Boxes = false,
    TracerFrom = "Bottom",    -- Bottom / Center / Crosshair
    MaxDistance = 1200,
    Transparency = 0.6,
    EnemyColor = Color3.fromRGB(255, 70, 70),
    AllyColor = Color3.fromRGB(80, 170, 255),
}

local BulletEsp = {
    Enabled = false,
    Own = false,
    Ahead = 0.4,              -- s of path drawn ahead
    Color = Color3.fromRGB(255, 220, 90),
    ThreatColor = Color3.fromRGB(255, 50, 50),
}

local StormEsp = {
    Ring = false,
    Warning = true,
    Color = Color3.fromRGB(170, 90, 255),
}

local Diag = {
    Modules = {}, Target = "none", Bullets = 0, Shields = 0,
    SilentShots = 0, Triggers = 0, Gc = typeof(getgc) == "function",
}

--// the game's modules ----------------------------------------------------------

local Core
local Mods = {}

local WANT = {
    Direction = { "Utilities.Direction", "Calculate" },
    Trajectory = { "Utilities.Trajectory", "Add" },
    Recoil = { "Utilities.Recoil", "Fire" },
    Cards = { "Utilities.Cards", "GetBulletSettings" },
    Reload = { "Utilities.Reload", "GetShieldable" },
    Health = { "Utilities.Health", "GetHealth" },
    Storm = { "Utilities.Storm", "GetDistance" },
}

local function endsWith(s, suffix)
    return type(s) == "string" and #s >= #suffix and s:sub(-#suffix) == suffix
end

local function findModules()
    if Diag.Gc and typeof(debug) == "table" and type(debug.info) == "function" then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" then
                    if not Core and type(rawget(v, "Libraries")) == "table" and type(rawget(v, "Services")) == "table" then
                        Core = v
                    end
                    for name, spec in pairs(WANT) do
                        if not Mods[name] then
                            local fn = rawget(v, spec[2])
                            if type(fn) == "function" then
                                local ok, src = pcall(debug.info, fn, "s")
                                if ok and endsWith(src, spec[1]) then Mods[name] = v end
                            end
                        end
                    end
                end
            end
        end)
    end
    -- anything not found that way: required, which in most executors hands
    -- back the game's own cached copy
    if not Core then
        local ok, result = pcall(require, ReplicatedStorage:FindFirstChild("Core"))
        if ok and type(result) == "table" then Core = result end
    end
    local utilities = ReplicatedStorage:FindFirstChild("Utilities")
    for name in pairs(WANT) do
        if not Mods[name] and utilities then
            local module = utilities:FindFirstChild(name)
            if module and module:IsA("ModuleScript") then
                local ok, result = pcall(require, module)
                if ok and type(result) == "table" then Mods[name] = result end
            end
        end
        Diag.Modules[name] = Mods[name] ~= nil
    end
    Diag.Modules.Core = Core ~= nil
end

findModules()

local Libs = Core and Core.Libraries or {}
local Info, Input, MathLib, ScreenShake = Libs.Info, Libs.Input, Libs.Math, Libs.ScreenShake

local function infoGet(a, b)
    if not Info or type(Info.Get) ~= "function" then return nil end
    local ok, value = pcall(Info.Get, a, b)
    return ok and value or nil
end

local function call(module, name, ...)
    local fn = module and module[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function press(key)
    if Input and type(Input.KeyDownInput) == "function" then pcall(Input.KeyDownInput, key) end
end

local function release(key)
    if Input and type(Input.KeyUpInput) == "function" then pcall(Input.KeyUpInput, key) end
end

--// hooks -------------------------------------------------------------------------
-- Each hook swaps one field on a game table and remembers the original.

local Hooks = {}

local function hook(tbl, key, make)
    if type(tbl) ~= "table" or type(tbl[key]) ~= "function" then return false end
    local original = tbl[key]
    local ok = pcall(function() tbl[key] = make(original) end)
    if ok then Hooks[#Hooks + 1] = { tbl, key, original } end
    return ok
end

local function unhookAll()
    for i = #Hooks, 1, -1 do
        local h = Hooks[i]
        pcall(function() h[1][h[2]] = h[3] end)
    end
    table.clear(Hooks)
end

--// characters --------------------------------------------------------------------

local CharactersFolder = Workspace:FindFirstChild("Characters")
local AliveFolder = CharactersFolder and CharactersFolder:FindFirstChild("Alive")
local BulletsFolder = Workspace:FindFirstChild("Bullets")

local function aliveFolder()
    if AliveFolder and AliveFolder.Parent then return AliveFolder end
    CharactersFolder = Workspace:FindFirstChild("Characters")
    AliveFolder = CharactersFolder and CharactersFolder:FindFirstChild("Alive")
    return AliveFolder
end

local function myRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart"), char
end

local function teamsOn()
    return infoGet("Game", "Teams") and true or false
end

local function isAlly(player)
    if player == LocalPlayer then return true end
    if not teamsOn() then return false end
    return (infoGet(player, "Team") or "Team2") == (infoGet(LocalPlayer, "Team") or "Team1")
end

local function healthOf(char)
    local hp = call(Mods.Health, "GetHealth", char)
    local max = call(Mods.Health, "GetMaxHealth", char)
    return hp, max
end

-- every living character model with its player, the Allies / Enemies models
-- unwrapped
local Roster = {}

local function refreshRoster()
    table.clear(Roster)
    local alive = aliveFolder()
    if not alive then return end
    local function take(model)
        if model:IsA("Model") and model.Name ~= "Allies" and model.Name ~= "Enemies" then
            local player = Players:GetPlayerFromCharacter(model)
            local root = model:FindFirstChild("HumanoidRootPart")
            if player and player ~= LocalPlayer and root then
                Roster[#Roster + 1] = { Model = model, Player = player, Root = root }
            end
        end
    end
    for _, child in ipairs(alive:GetChildren()) do
        if child.Name == "Allies" or child.Name == "Enemies" then
            for _, inner in ipairs(child:GetChildren()) do take(inner) end
        else
            take(child)
        end
    end
end

-- Velocity of each character measured from its own movement, since the others
-- are moved by the game's interpolation rather than by physics.
local Motion = setmetatable({}, { __mode = "k" })

-- A short window of samples, velocity taken across the whole window: the
-- interpolation the game moves others with jitters frame to frame, a window
-- of ~0.2s doesn't.
local WINDOW = 0.2

local function updateMotion(entry, now)
    local m = Motion[entry.Model]
    local pos = entry.Root.Position
    if not m then
        Motion[entry.Model] = { Samples = { { pos, now } }, Vel = Vector3.zero }
        return
    end
    local samples = m.Samples
    local last = samples[#samples]
    if now - last[2] < 1 / 240 then return end
    if (pos - last[1]).Magnitude > 40 then
        -- a teleport or respawn, not motion: start over
        m.Samples, m.Vel = { { pos, now } }, Vector3.zero
        return
    end
    samples[#samples + 1] = { pos, now }
    while #samples > 2 and now - samples[2][2] >= WINDOW do table.remove(samples, 1) end
    if #samples > 24 then table.remove(samples, 1) end
    local first = samples[1]
    local span = now - first[2]
    if span >= 0.04 then
        local raw = (pos - first[1]) / span
        if raw.Magnitude > 250 then raw = Vector3.zero end
        m.Vel = m.Vel:Lerp(raw, 0.6)
    end
end

local function velocityOf(model)
    local m = Motion[model]
    return m and m.Vel or Vector3.zero
end

--// targeting ---------------------------------------------------------------------

local VisParams = RaycastParams.new()
VisParams.FilterType = Enum.RaycastFilterType.Exclude
VisParams.IgnoreWater = true

local function visible(from, part)
    local ignore = { LocalPlayer.Character }
    if CharactersFolder then ignore[#ignore + 1] = CharactersFolder end
    if BulletsFolder then ignore[#ignore + 1] = BulletsFolder end
    VisParams.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(from, part.Position - from, VisParams)
    return hit == nil
end

-- where the FOV and "lined up" are measured from: the middle of the screen,
-- or the mouse
local function mousePos()
    if Aim.FOVCenter and Camera then return Camera.ViewportSize / 2 end
    return UserInputService:GetMouseLocation()
end

-- where the real crosshair is right now, for moving it
local function cursorPos()
    if Camera and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return Camera.ViewportSize / 2
    end
    return UserInputService:GetMouseLocation()
end

local function screenGap(position)
    if not Camera then return math.huge, false end
    local point, onScreen = Camera:WorldToViewportPoint(position)
    if not onScreen or point.Z <= 0 then return math.huge, false end
    return (Vector2.new(point.X, point.Y) - mousePos()).Magnitude, true
end

local PART_NAMES = {
    Head = { "Head" },
    Torso = { "UpperTorso", "Torso" },
    Root = { "HumanoidRootPart" },
}

local function aimPart(model)
    if Aim.Part == "Nearest to crosshair" then
        local best, bestGap = nil, math.huge
        for _, name in ipairs({ "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart" }) do
            local part = model:FindFirstChild(name)
            if part then
                local gap = screenGap(part.Position)
                if gap < bestGap then best, bestGap = part, gap end
            end
        end
        return best or model:FindFirstChild("HumanoidRootPart")
    end
    for _, name in ipairs(PART_NAMES[Aim.Part] or PART_NAMES.Head) do
        local part = model:FindFirstChild(name)
        if part then return part end
    end
    return model:FindFirstChild("HumanoidRootPart")
end

local FALLBACK_PARTS = { "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" }

local Current -- { Model, Player, Part }

local function validTarget(entry, root, fovScale)
    if Aim.TeamCheck and isAlly(entry.Player) then return nil end
    local hp = healthOf(entry.Model)
    if hp and hp <= 0 then return nil end
    if Aim.SkipShielding and call(Mods.Reload, "GetShielding", entry.Player) then return nil end
    local part = aimPart(entry.Model)
    if not part then return nil end
    local distance = (part.Position - root.Position).Magnitude
    if distance > Aim.MaxDistance then return nil end
    local function usable(candidate)
        local gap, onScreen = screenGap(candidate.Position)
        if Aim.FOV and (not onScreen or gap > Aim.FOVRadius * fovScale) then return nil end
        if Aim.VisibleOnly and Camera and not visible(Camera.CFrame.Position, candidate) then return nil end
        return gap
    end
    local gap = usable(part)
    if not gap and Aim.FallbackPart then
        for _, name in ipairs(FALLBACK_PARTS) do
            local other = entry.Model:FindFirstChild(name)
            if other and other ~= part then
                gap = usable(other)
                if gap then
                    part = other
                    break
                end
            end
        end
    end
    if not gap then return nil end
    return part, distance, gap, hp or 100
end

local function pickTarget(root)
    if Aim.Sticky and Current and Current.Model.Parent then
        for _, entry in ipairs(Roster) do
            if entry.Model == Current.Model then
                local part = validTarget(entry, root, 1.4)
                if part then
                    Current.Part = part
                    return Current
                end
                break
            end
        end
    end
    local best, bestScore = nil, math.huge
    for _, entry in ipairs(Roster) do
        local part, distance, gap, hp = validTarget(entry, root, 1)
        if part then
            local score
            if Aim.Priority == "Distance" then
                score = distance
            elseif Aim.Priority == "Lowest health" then
                score = hp * 1000 + gap
            else
                score = gap
            end
            if score < bestScore then
                best, bestScore = { Model = entry.Model, Player = entry.Player, Part = part }, score
            end
        end
    end
    return best
end

-- Where to send a bullet from origin so it meets the part, flight time and
-- drop included: the game's own path played forward until the aim settles.
local FloorParams = RaycastParams.new()
FloorParams.FilterType = Enum.RaycastFilterType.Exclude

local function leadTime()
    local extra = Aim.ExtraLead / 1000
    if Aim.AutoPing then
        local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
        if ok and type(ping) == "number" then extra += math.clamp(ping, 0, 0.5) end
    end
    return extra
end

-- where the part will be t seconds from now: along its velocity, and down
-- under gravity onto the floor when it is in the air
local function predictor(part, model)
    local start = part.Position
    local velocity = Aim.Predict and velocityOf(model) * Aim.PredictScale or Vector3.zero
    local falling = Aim.Predict and Aim.PredictFalls and math.abs(velocity.Y) > 3
    local floorY = -math.huge
    if falling then
        FloorParams.FilterDescendantsInstances = { model, LocalPlayer.Character, CharactersFolder, BulletsFolder }
        local hit = Workspace:Raycast(start, Vector3.new(0, -120, 0), FloorParams)
        local root = model:FindFirstChild("HumanoidRootPart")
        -- the part's height above the feet, kept when it lands
        local above = root and (start.Y - root.Position.Y) + 3 or 3
        floorY = hit and (hit.Position.Y + above) or (start.Y - 120)
    end
    local gravity = Workspace.Gravity
    return function(t)
        if not falling then return start + velocity * t end
        local y = math.max(floorY, start.Y + velocity.Y * t - 0.5 * gravity * t * t)
        return Vector3.new(start.X + velocity.X * t, y, start.Z + velocity.Z * t)
    end
end

-- Where to send a bullet from origin so it meets the part, flight time and
-- drop included: the game's own path played forward until the aim settles.
local function solve(origin, speed, gravity, part, model)
    local at = predictor(part, model)
    local extra = leadTime()
    local aim, t = at(extra), 0
    local predicted = aim
    for _ = 1, 10 do
        local offset = aim - origin
        if offset.Magnitude < 0.05 then break end
        local unit = offset.Unit
        local horizontal = math.sqrt(unit.X * unit.X + unit.Z * unit.Z)
        predicted = at(t + extra)
        local flatGap = Vector3.new(predicted.X - origin.X, 0, predicted.Z - origin.Z).Magnitude
        local nextT
        if horizontal > 0.05 then
            nextT = flatGap / (speed * horizontal)
        else
            nextT = (predicted - origin).Magnitude / speed
        end
        nextT = math.min(nextT, 5)
        predicted = at(nextT + extra)
        local g = gravity * (math.abs(unit.Y) ^ 4 * 0.5 + 1)
        aim = predicted + Vector3.new(0, 0.5 * g * nextT * nextT, 0)
        local settled = math.abs(nextT - t) < 0.0005
        t = nextT
        if settled then break end
    end
    local offset = aim - origin
    if offset.Magnitude < 0.05 then return nil end
    return offset.Unit, t, predicted
end

--// silent aim, spread, recoil, shake ---------------------------------------------

local SilentHooked = hook(Mods.Direction, "Calculate", function(original)
    return function(origin, cameraCFrame, speed, gravity, ...)
        local base = original(origin, cameraCFrame, speed, gravity, ...)
        if Unloaded or not Aim.Silent or not Current then return base end
        if math.random() * 100 > Aim.HitChance then return base end
        local ok, dir = pcall(function()
            local part = Current.Part
            if not (part and part.Parent) then return nil end
            return (solve(origin, speed or 300, gravity or 0, part, Current.Model))
        end)
        if ok and typeof(dir) == "Vector3" then
            Diag.SilentShots += 1
            return dir
        end
        return base
    end
end)

local SpreadHooked = hook(MathLib, "ApplySpreadToDirection", function(original)
    return function(dir, spread, ...)
        if not Unloaded and type(spread) == "number" then spread *= Gun.SpreadScale end
        return original(dir, spread, ...)
    end
end)
hook(MathLib, "GenerateSpreadDirections", function(original)
    return function(dir, spread, ...)
        if not Unloaded and type(spread) == "number" then spread *= Gun.SpreadScale end
        return original(dir, spread, ...)
    end
end)

local RecoilHooked = hook(Mods.Recoil, "Fire", function(original)
    return function(...)
        if not Unloaded and Gun.NoRecoil then return nil end
        return original(...)
    end
end)

local ShakeHooked = hook(ScreenShake, "AddShake", function(original)
    return function(...)
        if not Unloaded and Gun.NoShake then return nil end
        return original(...)
    end
end)

--// bullet tracking -----------------------------------------------------------------
-- Every bullet registered with Trajectory, played forward by the same path
-- formula the game uses.

local Tracked = {}
local TrackedCount = 0
local MAX_TRACKED = 80

local function forget(id)
    if Tracked[id] then
        Tracked[id] = nil
        TrackedCount -= 1
    end
end

local TrajectoryHooked = hook(Mods.Trajectory, "Add", function(original)
    return function(player, id, startTime, position, direction, settings, isLocal, offset, ...)
        pcall(function()
            if id == nil or typeof(position) ~= "Vector3" or typeof(direction) ~= "Vector3" then return end
            if not Tracked[id] then
                if TrackedCount >= MAX_TRACKED then return end
                TrackedCount += 1
            end
            local size = 1
            if Mods.Trajectory and type(settings) == "table" then
                local ok, _, _, _, hitbox = pcall(Mods.Trajectory.GetSize, settings)
                if ok and type(hitbox) == "number" then size = hitbox end
            end
            Tracked[id] = {
                Player = player,
                Local = isLocal or player == LocalPlayer,
                Born = os.clock(),
                Gravity = type(settings) == "table" and settings["Bullet Gravity"] or 0,
                Radius = size,
                Paths = { {
                    Pos = position, Dir = direction,
                    Speed = type(settings) == "table" and settings["Bullet Speed"] or 300,
                    Time = startTime, GravityAt = startTime,
                } },
            }
        end)
        return original(player, id, startTime, position, direction, settings, isLocal, offset, ...)
    end
end)

hook(Mods.Trajectory, "AddPath", function(original)
    return function(id, position, direction, speed, time, ...)
        pcall(function()
            local b = Tracked[id]
            if b and #b.Paths < 8 then
                table.insert(b.Paths, { Pos = position, Dir = direction, Speed = speed, Time = time, GravityAt = time + 0.1 })
            end
        end)
        return original(id, position, direction, speed, time, ...)
    end
end)

hook(Mods.Trajectory, "LockOn", function(original)
    return function(id, instance, time, ...)
        local b = Tracked[id]
        if b then b.LockOn = instance end
        return original(id, instance, time, ...)
    end
end)

hook(Mods.Trajectory, "Remove", function(original)
    return function(id, ...)
        forget(id)
        return original(id, ...)
    end
end)

local function bulletAt(b, t)
    local path = b.Paths[1]
    for i = 2, #b.Paths do
        if b.Paths[i].Time <= t then path = b.Paths[i] end
    end
    local dt = t - path.Time
    local fall = math.max(0, t - path.GravityAt)
    local g = b.Gravity * (math.abs(path.Dir.Y) ^ 4 * 0.5 + 1)
    return path.Pos + path.Dir * path.Speed * dt - Vector3.new(0, 0.5 * g * fall * fall, 0)
end

-- worked out each frame for the shield and the bullet ESP
local Incoming = {} -- id -> { Now, Ahead, HitIn }

local SIM_STEP = 1 / 60

local function bulletStep()
    table.clear(Incoming)
    if not (Shield.Auto or BulletEsp.Enabled) then return end
    local root, char = myRoot()
    local now = Workspace:GetServerTimeNow()
    local clock = os.clock()
    local myPos = root and root.Position
    local myVel = root and root.AssemblyLinearVelocity or Vector3.zero
    local horizon = math.max(Shield.Lead + 0.15, BulletEsp.Ahead)
    local steps = math.clamp(math.ceil(horizon / SIM_STEP), 1, 60)
    local count = 0
    for id, b in pairs(Tracked) do
        if clock - b.Born > 10 then
            forget(id)
        elseif now >= b.Paths[1].Time then
            count += 1
            local entry = { Now = bulletAt(b, now), Ahead = bulletAt(b, now + BulletEsp.Ahead), Local = b.Local }
            local hostile = not b.Local and not (Shield.IgnoreAllies and b.Player and isAlly(b.Player))
            if hostile and myPos then
                local reach = 2.6 + b.Radius * 0.5 + Shield.Margin
                if b.LockOn and char and typeof(b.LockOn) == "Instance" and b.LockOn:IsDescendantOf(char) then
                    -- homing onto you: it arrives about when its speed says
                    local speed = b.Paths[#b.Paths].Speed
                    entry.HitIn = speed > 0 and (myPos - entry.Now).Magnitude / speed or nil
                else
                    for i = 1, steps do
                        local t = i * SIM_STEP
                        local me = myPos + myVel * t
                        if (bulletAt(b, now + t) - me).Magnitude <= reach then
                            entry.HitIn = t
                            break
                        end
                    end
                end
            end
            Incoming[id] = entry
        end
    end
    Diag.Bullets = count
end

--// auto shield ---------------------------------------------------------------------

local LastShield = 0

local function shieldStep()
    if not Shield.Auto then return end
    if os.clock() - LastShield < 0.3 then return end
    if call(Mods.Reload, "GetShieldable") == false then return end
    if call(Mods.Reload, "GetShielding") then return end
    local soonest
    for _, entry in pairs(Incoming) do
        if entry.HitIn and (not soonest or entry.HitIn < soonest) then soonest = entry.HitIn end
    end
    if soonest and soonest <= Shield.Lead then
        LastShield = os.clock()
        press("E")
        release("E")
        Diag.Shields += 1
    end
end

--// triggerbot ------------------------------------------------------------------------

local TriggerBusy = false

local function triggerStep()
    if not Trigger.Enabled or TriggerBusy or not Current then return end
    local part = Current.Part
    if not (part and part.Parent) then return end
    if Trigger.NeedAmmo then
        if call(Mods.Reload, "GetAmmo") == 0 then return end
        if call(Mods.Reload, "GetShielding") then return end
    end
    local onTarget = Aim.Silent and Trigger.WithSilent
    if not onTarget then
        onTarget = screenGap(part.Position) <= Trigger.Radius
    end
    if not onTarget then return end
    TriggerBusy = true
    task.delay(Trigger.Delay, function()
        if Unloaded then
            TriggerBusy = false
            return
        end
        press("MouseClick")
        Diag.Triggers += 1
        task.delay(Trigger.Hold, function()
            release("MouseClick")
            TriggerBusy = false
        end)
    end)
end

--// aim assist --------------------------------------------------------------------------

local function assistStep()
    if not Assist.Enabled or not Current or not Camera then return end
    if Assist.OnlyRightMouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then return end
    local part = Current.Part
    if not (part and part.Parent) then return end
    local origin = Camera.CFrame.Position
    local settings = call(Mods.Cards, "GetBulletSettings")
    local speed = type(settings) == "table" and settings["Bullet Speed"] or 300
    local t = (part.Position - origin).Magnitude / math.max(speed, 1)
    local point = predictor(part, Current.Model)(t + leadTime())
    if Assist.Method == "Mouse move" and typeof(mousemoverel) == "function" then
        local screen, onScreen = Camera:WorldToViewportPoint(point)
        if not onScreen then return end
        local delta = (Vector2.new(screen.X, screen.Y) - cursorPos()) * Assist.Smooth
        pcall(mousemoverel, delta.X, delta.Y)
    else
        local cf = Camera.CFrame
        Camera.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, point), Assist.Smooth)
    end
end

--// frame loop --------------------------------------------------------------------------

local LastError = 0
local function guarded(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and os.clock() - LastError > 2 then
        LastError = os.clock()
        warn(("[OVERKILL] %s: %s"):format(name, tostring(err)))
    end
end

local NextRoster = 0
track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    local now = os.clock()
    if now >= NextRoster then
        NextRoster = now + 0.25
        guarded("roster", refreshRoster)
    end
    for _, entry in ipairs(Roster) do
        if entry.Model.Parent then updateMotion(entry, now) end
    end
    guarded("target", function()
        local root = myRoot()
        local wants = Aim.Silent or Assist.Enabled or Trigger.Enabled
        Current = (wants and root) and pickTarget(root) or nil
        Diag.Target = Current and Current.Player.Name or "none"
    end)
    guarded("bullets", bulletStep)
    guarded("shield", shieldStep)
    guarded("trigger", triggerStep)
end))

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    guarded("assist", assistStep)
end))

--// player ESP --------------------------------------------------------------------------

local EspGui = Instance.new("Folder")
EspGui.Name = "OkVisuals"
pcall(function()
    EspGui.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
end)
if not EspGui.Parent then EspGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local EspObjects = {} -- model -> objects

local HasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
local function newDrawing(kind, props)
    if not HasDrawing then return nil end
    local ok, obj = pcall(Drawing.new, kind)
    if not ok then return nil end
    for k, v in pairs(props) do pcall(function() obj[k] = v end) end
    return obj
end

local function removeDrawing(obj)
    if obj then pcall(function() obj:Remove() end) end
end

local function destroyEsp(model)
    local objs = EspObjects[model]
    if not objs then return end
    pcall(function() objs.Highlight:Destroy() end)
    pcall(function() objs.Billboard:Destroy() end)
    removeDrawing(objs.Tracer)
    removeDrawing(objs.Box)
    EspObjects[model] = nil
end

local function buildEsp(model, root)
    local objs = {}
    local hl = Instance.new("Highlight")
    hl.Name = "OkHl"
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.OutlineTransparency = 0
    hl.Adornee = model
    hl.Parent = EspGui
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "OkTag"
    billboard.Adornee = root
    billboard.Size = UDim2.fromOffset(220, 46)
    billboard.StudsOffset = Vector3.new(0, 3.6, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = math.huge
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextStrokeTransparency = 0.35
    label.TextYAlignment = Enum.TextYAlignment.Bottom
    label.Parent = billboard
    billboard.Parent = EspGui
    objs.Highlight, objs.Billboard, objs.Label = hl, billboard, label
    objs.Tracer = newDrawing("Line", { Thickness = 1.5, Visible = false })
    objs.Box = newDrawing("Square", { Thickness = 1.5, Filled = false, Visible = false })
    EspObjects[model] = objs
    return objs
end

local function cardText(player)
    local list = call(Mods.Cards, "GetPlayerCards", player)
    if type(list) ~= "table" or #list == 0 then return nil end
    if #list > 4 then
        return ("%d cards: %s, %s, %s..."):format(#list, tostring(list[1]), tostring(list[2]), tostring(list[3]))
    end
    local names = {}
    for i, name in ipairs(list) do names[i] = tostring(name) end
    return table.concat(names, ", ")
end

local function tracerOrigin()
    local size = Camera and Camera.ViewportSize or Vector2.new(800, 600)
    if Esp.TracerFrom == "Center" then return size / 2 end
    if Esp.TracerFrom == "Crosshair" then return mousePos() end
    return Vector2.new(size.X / 2, size.Y)
end

-- labels and highlights at 10 Hz, tracers every frame
task.spawn(function()
    while not Unloaded do
        pcall(function()
            local root = myRoot()
            local seen = {}
            if Esp.Enabled and root then
                for _, entry in ipairs(Roster) do
                    local model = entry.Model
                    local ally = isAlly(entry.Player)
                    local distance = (entry.Root.Position - root.Position).Magnitude
                    if model.Parent and (Esp.Allies or not ally) and distance <= Esp.MaxDistance then
                        seen[model] = true
                        local objs = EspObjects[model] or buildEsp(model, entry.Root)
                        local color = ally and Esp.AllyColor or Esp.EnemyColor
                        if Current and Current.Model == model and Aim.ShowTarget then color = Aim.TargetColor end
                        objs.Highlight.Enabled = Esp.Chams
                        objs.Highlight.FillColor = color
                        objs.Highlight.OutlineColor = color
                        objs.Highlight.FillTransparency = Esp.Transparency
                        local lines = {}
                        local top = {}
                        if Esp.Names then top[#top + 1] = entry.Player.DisplayName end
                        if Esp.Distance then top[#top + 1] = ("[%dm]"):format(math.floor(distance)) end
                        if #top > 0 then lines[#lines + 1] = table.concat(top, " ") end
                        local info = {}
                        if Esp.Health then
                            local hp, max = healthOf(model)
                            if hp then info[#info + 1] = ("%d/%d hp"):format(math.floor(hp), math.floor(max or 100)) end
                        end
                        if Esp.ShieldState then
                            if call(Mods.Reload, "GetShielding", entry.Player) then
                                info[#info + 1] = "SHIELD UP"
                            elseif call(Mods.Reload, "GetShieldable", entry.Player) == false then
                                info[#info + 1] = "no shield"
                            end
                        end
                        if #info > 0 then lines[#lines + 1] = table.concat(info, "  ") end
                        if Esp.Cards then
                            local cards = cardText(entry.Player)
                            if cards then lines[#lines + 1] = cards end
                        end
                        objs.Label.Text = table.concat(lines, "\n")
                        objs.Label.TextColor3 = color
                        objs.Billboard.Enabled = #lines > 0
                        objs.Color = color
                        objs.Root = entry.Root
                        objs.Head = model:FindFirstChild("Head")
                    end
                end
            end
            for model in pairs(EspObjects) do
                if not seen[model] then destroyEsp(model) end
            end
        end)
        task.wait(0.1)
    end
end)

--// drawings: fov, target line, tracers, bullets, storm ---------------------------------

local Draw = {
    Fov = newDrawing("Circle", { Thickness = 1, NumSides = 64, Filled = false, Transparency = 0.7, Visible = false }),
    TargetLine = newDrawing("Line", { Thickness = 1.5, Visible = false }),
    Point = newDrawing("Circle", { Radius = 4, Thickness = 2, NumSides = 16, Filled = true, Visible = false }),
    StormText = newDrawing("Text", { Size = 18, Center = true, Outline = true, Visible = false }),
}

local BulletLines = {}
for i = 1, 40 do BulletLines[i] = newDrawing("Line", { Thickness = 2, Visible = false }) end

local STORM_SEGMENTS = 64
local StormLines = {}
for i = 1, STORM_SEGMENTS do StormLines[i] = newDrawing("Line", { Thickness = 2, Visible = false }) end

local function project(position)
    local point, onScreen = Camera:WorldToViewportPoint(position)
    return Vector2.new(point.X, point.Y), onScreen and point.Z > 0
end

local function drawLine(line, a, b, color)
    if not line then return end
    local pa, onA = project(a)
    local pb, onB = project(b)
    if onA and onB then
        line.From, line.To, line.Color, line.Visible = pa, pb, color, true
    else
        line.Visible = false
    end
end

track(RunService.RenderStepped:Connect(function()
    if Unloaded or not Camera then return end
    pcall(function()
        if Draw.Fov then
            local show = (Aim.Silent or Assist.Enabled or Trigger.Enabled) and Aim.FOV and Aim.ShowFOV
            Draw.Fov.Visible = show
            if show then
                Draw.Fov.Radius = Aim.FOVRadius
                Draw.Fov.Position = mousePos()
                Draw.Fov.Color = Aim.FOVColor
            end
        end

        if Draw.TargetLine then
            local part = Aim.ShowTarget and Current and Current.Part
            if part and part.Parent then
                local p, on = project(part.Position)
                Draw.TargetLine.Visible = on
                if on then
                    Draw.TargetLine.From, Draw.TargetLine.To, Draw.TargetLine.Color = mousePos(), p, Aim.TargetColor
                end
            else
                Draw.TargetLine.Visible = false
            end
        end

        if Draw.Point then
            local part = Aim.ShowPoint and Current and Current.Part
            local shown = false
            if part and part.Parent then
                local settings = call(Mods.Cards, "GetBulletSettings")
                local speed = type(settings) == "table" and settings["Bullet Speed"] or 300
                local gravity = type(settings) == "table" and settings["Bullet Gravity"] or 0
                local _, _, point = solve(Camera.CFrame.Position, speed, gravity, part, Current.Model)
                if point then
                    local p, on = project(point)
                    if on then
                        Draw.Point.Position, Draw.Point.Color = p, Aim.PointColor
                        shown = true
                    end
                end
            end
            Draw.Point.Visible = shown
        end

        for model, objs in pairs(EspObjects) do
            local box = objs.Box
            if box then
                local root = objs.Root
                if Esp.Enabled and Esp.Boxes and root and root.Parent and model.Parent then
                    local head = objs.Head
                    local topWorld = (head and head.Parent and head.Position or root.Position + Vector3.new(0, 1.5, 0)) + Vector3.new(0, 0.9, 0)
                    local top, onTop = project(topWorld)
                    local bottom, onBottom = project(root.Position - Vector3.new(0, 3.2, 0))
                    if onTop and onBottom then
                        local height = math.abs(bottom.Y - top.Y)
                        local width = height * 0.6
                        box.Size = Vector2.new(width, height)
                        box.Position = Vector2.new((top.X + bottom.X) / 2 - width / 2, math.min(top.Y, bottom.Y))
                        box.Color = objs.Color or Esp.EnemyColor
                        box.Visible = true
                    else
                        box.Visible = false
                    end
                else
                    box.Visible = false
                end
            end
            local tracer = objs.Tracer
            if tracer then
                if Esp.Enabled and Esp.Tracers and objs.Root and objs.Root.Parent and model.Parent then
                    local p, on = project(objs.Root.Position)
                    tracer.Visible = on
                    if on then tracer.From, tracer.To, tracer.Color = tracerOrigin(), p, objs.Color or Esp.EnemyColor end
                else
                    tracer.Visible = false
                end
            end
        end

        local used = 0
        if BulletEsp.Enabled then
            for _, entry in pairs(Incoming) do
                if used >= #BulletLines then break end
                if BulletEsp.Own or not entry.Local then
                    used += 1
                    drawLine(BulletLines[used], entry.Now, entry.Ahead, entry.HitIn and BulletEsp.ThreatColor or BulletEsp.Color)
                end
            end
        end
        for i = used + 1, #BulletLines do
            if BulletLines[i] then BulletLines[i].Visible = false end
        end

        local root = myRoot()
        local radius = call(Mods.Storm, "GetDistance")
        local inMatch = not infoGet("Game", "Lobby")
        local showRing = StormEsp.Ring and root and type(radius) == "number" and inMatch
        for i = 1, STORM_SEGMENTS do
            local line = StormLines[i]
            if line then
                if showRing then
                    local a0 = (i - 1) / STORM_SEGMENTS * math.pi * 2
                    local a1 = i / STORM_SEGMENTS * math.pi * 2
                    local y = root.Position.Y - 2.5
                    drawLine(line, Vector3.new(math.cos(a0) * radius, y, math.sin(a0) * radius),
                        Vector3.new(math.cos(a1) * radius, y, math.sin(a1) * radius), StormEsp.Color)
                else
                    line.Visible = false
                end
            end
        end
        if Draw.StormText then
            if StormEsp.Warning and root and type(radius) == "number" and inMatch then
                local fromCenter = Vector3.new(root.Position.X, 0, root.Position.Z).Magnitude
                local gap = radius - fromCenter
                local size = Camera.ViewportSize
                Draw.StormText.Position = Vector2.new(size.X / 2, 60)
                if gap < 0 then
                    Draw.StormText.Text = ("OUTSIDE THE STORM, %d studs back in"):format(math.ceil(-gap))
                    Draw.StormText.Color = Color3.fromRGB(255, 70, 70)
                else
                    Draw.StormText.Text = ("storm edge %d studs away"):format(math.floor(gap))
                    Draw.StormText.Color = gap < 25 and Color3.fromRGB(255, 200, 80) or Color3.fromRGB(220, 220, 220)
                end
                Draw.StormText.Visible = true
            else
                Draw.StormText.Visible = false
            end
        end
    end)
end))

--// teardown --------------------------------------------------------------------------

local Library

local function unload()
    if Unloaded then return end
    Unloaded = true
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    unhookAll()
    if TriggerBusy then release("MouseClick") end
    for model in pairs(EspObjects) do destroyEsp(model) end
    pcall(function() EspGui:Destroy() end)
    for _, obj in pairs(Draw) do removeDrawing(obj) end
    for _, obj in ipairs(BulletLines) do removeDrawing(obj) end
    for _, obj in ipairs(StormLines) do removeDrawing(obj) end
    table.clear(Tracked)
end

Genv.__OverkillStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ---------------------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'OVERKILL',
    Footer = 'combat + visuals',
    Icon = 'crosshair',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ocean',
    ConfigFolder = 'Overkill',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

local function notify(text, icon)
    pcall(function() Library:Notify({ Title = 'OVERKILL', Description = text, Time = 6, Icon = icon or 'bell' }) end)
end

if not SilentHooked then
    notify('Could not reach the game\'s aim code, silent aim is unavailable. Aim assist and the rest still work.', 'circle-x')
end
if not TrajectoryHooked then
    notify('Could not reach the game\'s bullet tracker, auto shield and bullet ESP are unavailable.', 'circle-x')
end

do
    local Tab = Window:AddTab('Combat', 'crosshair', 'Aim, trigger and shield')

    local overview = Tab:AddBigGroupbox('Status', 'gauge')
    local status = overview:AddLabel('-', true)
    every(0.2, function()
        local ammo = call(Mods.Reload, "GetAmmo")
        local shieldReady = call(Mods.Reload, "GetShieldable")
        status:SetText(("target: %s\nammo: %s   shield: %s\nsilent shots: %d   trigger pulls: %d   auto shields: %d   bullets in the air: %d"):format(
            Diag.Target, ammo ~= nil and tostring(ammo) or "-",
            call(Mods.Reload, "GetShielding") and "up" or (shieldReady == false and "recharging" or "ready"),
            Diag.SilentShots, Diag.Triggers, Diag.Shields, Diag.Bullets))
    end)

    local silent = Tab:AddLeftGroupbox('Silent aim', 'crosshair')

    silent:AddToggle('ok_silent', {
        Text = 'Silent aim',
        Tooltip = 'your shots launch at the target, drop and its movement worked out, wherever your crosshair is',
        Default = false,
        Callback = function(v) Aim.Silent = v end,
    }):AddKeyPicker('ok_silent_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Silent aim' })

    silent:AddSlider('ok_hitchance', {
        Text = 'Hit chance',
        Tooltip = 'share of shots that get aimed. the rest go where you aimed yourself',
        Min = 0, Max = 100, Default = Aim.HitChance, Rounding = 0, Suffix = '%',
        Callback = function(v) Aim.HitChance = v end,
    })

    silent:AddDropdown('ok_part', {
        Text = 'Aim at',
        Values = { 'Head', 'Torso', 'Root', 'Nearest to crosshair' },
        Default = Aim.Part,
        Callback = function(v) Aim.Part = v or "Head" end,
    })

    silent:AddDropdown('ok_priority', {
        Text = 'Pick targets by',
        Values = { 'Crosshair', 'Distance', 'Lowest health' },
        Default = Aim.Priority,
        Callback = function(v) Aim.Priority = v or "Crosshair" end,
    })

    silent:AddToggle('ok_sticky', {
        Text = 'Stick to target',
        Tooltip = 'keeps the same target while it stays valid instead of hopping each frame',
        Default = Aim.Sticky,
        Callback = function(v) Aim.Sticky = v end,
    })

    local filters = Tab:AddRightGroupbox('Targets', 'users')

    filters:AddToggle('ok_teamcheck', { Text = 'Skip teammates', Default = Aim.TeamCheck, Callback = function(v) Aim.TeamCheck = v end })
    filters:AddToggle('ok_visible', {
        Text = 'Only visible targets',
        Tooltip = 'skips anyone behind a wall',
        Default = Aim.VisibleOnly,
        Callback = function(v) Aim.VisibleOnly = v end,
    })
    filters:AddToggle('ok_skipshield', {
        Text = 'Skip raised shields',
        Tooltip = 'a raised shield reflects the shot back at you',
        Default = Aim.SkipShielding,
        Callback = function(v) Aim.SkipShielding = v end,
    })
    filters:AddToggle('ok_fallback', {
        Text = 'Any visible part as a fallback',
        Tooltip = 'when the part you aim at is hidden, use whatever part of them is visible instead of skipping them',
        Default = Aim.FallbackPart,
        Callback = function(v) Aim.FallbackPart = v end,
    })
    filters:AddSlider('ok_maxdist', {
        Text = 'Max distance',
        Min = 50, Max = 2000, Default = Aim.MaxDistance, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Aim.MaxDistance = v end,
    })

    local lead = Tab:AddLeftGroupbox('Prediction', 'move-right')

    lead:AddToggle('ok_predict', {
        Text = 'Lead moving targets',
        Tooltip = 'aims where the target will be when the bullet gets there',
        Default = Aim.Predict,
        Callback = function(v) Aim.Predict = v end,
    })
    lead:AddSlider('ok_predict_scale', {
        Text = 'Lead strength',
        Min = 0, Max = 2, Default = Aim.PredictScale, Rounding = 2, Suffix = 'x',
        Callback = function(v) Aim.PredictScale = v end,
    })
    lead:AddToggle('ok_falls', {
        Text = 'Predict jumps and falls',
        Tooltip = 'a target in the air is led along its fall, down to the floor under it',
        Default = Aim.PredictFalls,
        Callback = function(v) Aim.PredictFalls = v end,
    })
    lead:AddToggle('ok_autoping', {
        Text = 'Add my ping to the lead',
        Default = Aim.AutoPing,
        Callback = function(v) Aim.AutoPing = v end,
    })
    lead:AddSlider('ok_extra', {
        Text = 'Extra lead for ping',
        Min = 0, Max = 300, Default = Aim.ExtraLead, Rounding = 0, Suffix = ' ms',
        Callback = function(v) Aim.ExtraLead = v end,
    })

    local fov = Tab:AddRightGroupbox('FOV', 'circle-dashed')

    fov:AddToggle('ok_fov', {
        Text = 'Only targets near the crosshair',
        Default = Aim.FOV,
        Callback = function(v) Aim.FOV = v end,
    })
    fov:AddToggle('ok_fov_center', {
        Text = 'FOV at the middle of the screen',
        Tooltip = 'on: the FOV circle, target picking and the triggerbot all measure from the middle of the screen. off: from your mouse',
        Default = Aim.FOVCenter,
        Callback = function(v) Aim.FOVCenter = v end,
    })
    fov:AddSlider('ok_fov_radius', {
        Text = 'FOV radius',
        Min = 20, Max = 1000, Default = Aim.FOVRadius, Rounding = 0, Suffix = ' px',
        Callback = function(v) Aim.FOVRadius = v end,
    })
    fov:AddToggle('ok_fov_show', { Text = 'Show FOV circle', Default = Aim.ShowFOV, Callback = function(v) Aim.ShowFOV = v end })
        :AddColorPicker('ok_fov_color', { Default = Aim.FOVColor, Title = 'FOV circle', Callback = function(c) Aim.FOVColor = c end })
    fov:AddToggle('ok_point_show', {
        Text = 'Show where the shot lands',
        Tooltip = 'a dot on the spot the shot is aimed at, lead included',
        Default = Aim.ShowPoint,
        Callback = function(v) Aim.ShowPoint = v end,
    }):AddColorPicker('ok_point_color', { Default = Aim.PointColor, Title = 'Shot point', Callback = function(c) Aim.PointColor = c end })
    fov:AddToggle('ok_target_show', { Text = 'Show target', Default = Aim.ShowTarget, Callback = function(v) Aim.ShowTarget = v end })
        :AddColorPicker('ok_target_color', { Default = Aim.TargetColor, Title = 'Target', Callback = function(c) Aim.TargetColor = c end })

    local assist = Tab:AddLeftGroupbox('Aim assist', 'mouse-pointer-2')

    assist:AddToggle('ok_assist', {
        Text = 'Aim assist',
        Tooltip = 'pulls your real crosshair onto the target, lead included',
        Default = false,
        Callback = function(v) Assist.Enabled = v end,
    }):AddKeyPicker('ok_assist_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Aim assist' })
    assist:AddToggle('ok_assist_rmb', {
        Text = 'Only while holding right mouse',
        Default = Assist.OnlyRightMouse,
        Callback = function(v) Assist.OnlyRightMouse = v end,
    })
    assist:AddDropdown('ok_assist_method', {
        Text = 'Move with',
        Tooltip = 'mouse move: moves the mouse (needs mousemoverel). camera: turns the camera directly',
        Values = { 'Mouse move', 'Camera' },
        Default = Assist.Method,
        Callback = function(v) Assist.Method = v or "Mouse move" end,
    })
    assist:AddSlider('ok_assist_smooth', {
        Text = 'Strength',
        Tooltip = 'how much of the gap is closed each frame. low looks human, 1 snaps',
        Min = 0.02, Max = 1, Default = Assist.Smooth, Rounding = 2,
        Callback = function(v) Assist.Smooth = v end,
    })

    local trigger = Tab:AddRightGroupbox('Triggerbot', 'zap')

    trigger:AddToggle('ok_trigger', {
        Text = 'Triggerbot',
        Tooltip = 'fires through the game\'s own trigger when a target is lined up, so ammo, reload and cooldown still apply',
        Default = false,
        Callback = function(v) Trigger.Enabled = v end,
    }):AddKeyPicker('ok_trigger_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Triggerbot' })
    trigger:AddToggle('ok_trigger_silent', {
        Text = 'Fire on any target with silent aim',
        Tooltip = 'with silent aim on, shoots whenever there is a target, since the shot goes to it anyway',
        Default = Trigger.WithSilent,
        Callback = function(v) Trigger.WithSilent = v end,
    })
    trigger:AddToggle('ok_trigger_ammo', {
        Text = 'Not on an empty gun or shield',
        Tooltip = 'skips pulling the trigger while you are out of ammo or have your shield up, so it doesn\'t spam the empty sound',
        Default = Trigger.NeedAmmo,
        Callback = function(v) Trigger.NeedAmmo = v end,
    })
    trigger:AddSlider('ok_trigger_radius', {
        Text = 'Lined up within',
        Min = 5, Max = 200, Default = Trigger.Radius, Rounding = 0, Suffix = ' px',
        Callback = function(v) Trigger.Radius = v end,
    })
    trigger:AddSlider('ok_trigger_delay', {
        Text = 'Reaction delay',
        Min = 0, Max = 0.5, Default = Trigger.Delay, Rounding = 2, Suffix = 's',
        Callback = function(v) Trigger.Delay = v end,
    })
    trigger:AddSlider('ok_trigger_hold', {
        Text = 'Hold trigger for',
        Min = 0.03, Max = 1, Default = Trigger.Hold, Rounding = 2, Suffix = 's',
        Callback = function(v) Trigger.Hold = v end,
    })

    local shield = Tab:AddLeftGroupbox('Auto shield', 'shield')

    shield:AddToggle('ok_shield', {
        Text = 'Auto shield',
        Tooltip = 'plays every enemy bullet forward and raises your shield just before one would hit, so it reflects',
        Default = false,
        Callback = function(v) Shield.Auto = v end,
    }):AddKeyPicker('ok_shield_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto shield' })
    shield:AddSlider('ok_shield_lead', {
        Text = 'Raise it before impact',
        Tooltip = 'the shield takes 0.1s to come up, so keep this above that and below how long your shield lasts',
        Min = 0.1, Max = 0.6, Default = Shield.Lead, Rounding = 2, Suffix = 's',
        Callback = function(v) Shield.Lead = v end,
    })
    shield:AddSlider('ok_shield_margin', {
        Text = 'Safety room',
        Min = 0, Max = 6, Default = Shield.Margin, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Shield.Margin = v end,
    })
    shield:AddToggle('ok_shield_allies', {
        Text = 'Ignore teammates\' bullets',
        Default = Shield.IgnoreAllies,
        Callback = function(v) Shield.IgnoreAllies = v end,
    })

    local gun = Tab:AddRightGroupbox('Gun', 'wrench')

    gun:AddToggle('ok_norecoil', { Text = 'No recoil', Default = false, Callback = function(v) Gun.NoRecoil = v end })
    gun:AddToggle('ok_noshake', { Text = 'No screen shake', Default = false, Callback = function(v) Gun.NoShake = v end })
    gun:AddSlider('ok_spread', {
        Text = 'Spread',
        Tooltip = '100% is the game\'s own spread, 0% sends every pellet dead straight',
        Min = 0, Max = 1, Default = Gun.SpreadScale, Rounding = 2, Suffix = 'x',
        Callback = function(v) Gun.SpreadScale = v end,
    })
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'ESP')

    local esp = Tab:AddLeftGroupbox('Player ESP', 'scan-eye')

    esp:AddToggle('ok_esp', { Text = 'Player ESP', Default = false, Callback = function(v) Esp.Enabled = v end })
        :AddKeyPicker('ok_esp_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Player ESP' })
    esp:AddToggle('ok_esp_chams', { Text = 'Chams', Default = Esp.Chams, Callback = function(v) Esp.Chams = v end })
    esp:AddToggle('ok_esp_names', { Text = 'Names', Default = Esp.Names, Callback = function(v) Esp.Names = v end })
    esp:AddToggle('ok_esp_health', { Text = 'Health', Default = Esp.Health, Callback = function(v) Esp.Health = v end })
    esp:AddToggle('ok_esp_distance', { Text = 'Distance', Default = Esp.Distance, Callback = function(v) Esp.Distance = v end })
    esp:AddToggle('ok_esp_shield', {
        Text = 'Shield state',
        Tooltip = 'shows when someone has their shield up, or has used it and is waiting on the regen',
        Default = Esp.ShieldState,
        Callback = function(v) Esp.ShieldState = v end,
    })
    esp:AddToggle('ok_esp_cards', { Text = 'Their cards', Default = Esp.Cards, Callback = function(v) Esp.Cards = v end })
    esp:AddToggle('ok_esp_boxes', { Text = 'Boxes', Default = Esp.Boxes, Callback = function(v) Esp.Boxes = v end })
    esp:AddToggle('ok_esp_tracers', { Text = 'Tracers', Default = Esp.Tracers, Callback = function(v) Esp.Tracers = v end })
    esp:AddDropdown('ok_esp_tracer_from', {
        Text = 'Tracers from',
        Values = { 'Bottom', 'Center', 'Crosshair' },
        Default = Esp.TracerFrom,
        Callback = function(v) Esp.TracerFrom = v or "Bottom" end,
    })

    local look = Tab:AddRightGroupbox('ESP look', 'settings-2')

    look:AddToggle('ok_esp_allies', { Text = 'Show teammates', Default = Esp.Allies, Callback = function(v) Esp.Allies = v end })
        :AddColorPicker('ok_esp_ally_color', { Default = Esp.AllyColor, Title = 'Teammates', Callback = function(c) Esp.AllyColor = c end })
    look:AddLabel('Enemy colour'):AddColorPicker('ok_esp_enemy_color', {
        Default = Esp.EnemyColor, Title = 'Enemies', Callback = function(c) Esp.EnemyColor = c end,
    })
    look:AddSlider('ok_esp_transparency', {
        Text = 'Chams fill transparency',
        Min = 0, Max = 1, Default = Esp.Transparency, Rounding = 2,
        Callback = function(v) Esp.Transparency = v end,
    })
    look:AddSlider('ok_esp_max', {
        Text = 'Max distance',
        Min = 100, Max = 3000, Default = Esp.MaxDistance, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Esp.MaxDistance = v end,
    })

    local bullets = Tab:AddLeftGroupbox('Bullet ESP', 'move-up-right')

    bullets:AddToggle('ok_bullets', {
        Text = 'Bullet paths',
        Tooltip = 'draws where every bullet in the air is about to go. ones about to hit you turn red',
        Default = false,
        Callback = function(v) BulletEsp.Enabled = v end,
    }):AddColorPicker('ok_bullets_color', { Default = BulletEsp.Color, Title = 'Bullets', Callback = function(c) BulletEsp.Color = c end })
    bullets:AddLabel('About to hit you'):AddColorPicker('ok_bullets_threat', {
        Default = BulletEsp.ThreatColor, Title = 'About to hit you', Callback = function(c) BulletEsp.ThreatColor = c end,
    })
    bullets:AddToggle('ok_bullets_own', { Text = 'Your own bullets too', Default = BulletEsp.Own, Callback = function(v) BulletEsp.Own = v end })
    bullets:AddSlider('ok_bullets_ahead', {
        Text = 'Path length',
        Min = 0.1, Max = 1.5, Default = BulletEsp.Ahead, Rounding = 2, Suffix = 's',
        Callback = function(v) BulletEsp.Ahead = v end,
    })

    local storm = Tab:AddRightGroupbox('Storm', 'cloud-lightning')

    storm:AddToggle('ok_storm_ring', { Text = 'Storm edge ring', Default = false, Callback = function(v) StormEsp.Ring = v end })
        :AddColorPicker('ok_storm_color', { Default = StormEsp.Color, Title = 'Storm ring', Callback = function(c) StormEsp.Color = c end })
    storm:AddToggle('ok_storm_warning', {
        Text = 'Storm distance and warning',
        Default = StormEsp.Warning,
        Callback = function(v) StormEsp.Warning = v end,
    })
end

do
    local Tab = Window:AddTab('Info', 'info', 'Diagnostics')
    local box = Tab:AddLeftGroupbox('Diagnostics', 'activity')
    local label = box:AddLabel('-', true)
    every(0.5, function()
        local found = {}
        for _, name in ipairs({ 'Core', 'Direction', 'Trajectory', 'Recoil', 'Cards', 'Reload', 'Health', 'Storm' }) do
            found[#found + 1] = ("%s %s"):format(name, Diag.Modules[name] and "ok" or "MISSING")
        end
        label:SetText(("getgc: %s\n%s\nsilent aim hook: %s   bullet tracker: %s\nspread hook: %s   recoil hook: %s   shake hook: %s\ndrawing: %s   mousemoverel: %s"):format(
            Diag.Gc and "yes" or "no", table.concat(found, "\n"),
            SilentHooked and "on" or "FAILED", TrajectoryHooked and "on" or "FAILED",
            SpreadHooked and "on" or "FAILED", RecoilHooked and "on" or "FAILED", ShakeHooked and "on" or "FAILED",
            HasDrawing and "yes" or "no", typeof(mousemoverel) == "function" and "yes" or "no"))
    end)
    box:AddLabel('Silent shots should climb as you fire at a target. If a hook says FAILED or a module is MISSING, that feature is unavailable on this executor or the game changed.', true)
end

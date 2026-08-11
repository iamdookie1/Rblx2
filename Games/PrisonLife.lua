--// Prison Life ------------------------------------------------------------------
-- Full rewrite. Built against a fresh script dump of the live game, so every
-- remote call below is the real signature the game's own client scripts use,
-- not a guess:
--
--   Remotes.ArrestPlayer      :InvokeServer(targetPlayer, 1)  -- 7.5 stud range, 7s cooldown
--   Remotes.RequestTeamChange :InvokeServer(teamInstance, 1)  -- 6s cooldown
--   meleeEvent                :FireServer(target, 1, 1)       -- punch
--
-- Where something is unverifiable from the client (server-side validation,
-- tool scripts that only exist while held), it says so at the point of use
-- rather than pretending it's guaranteed.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Modern RunService events --------------------------------------------------
-- PreRender / PreSimulation / PostSimulation are the current names for what
-- used to be RenderStepped / Stepped / Heartbeat, and they say what they
-- actually do relative to the frame instead of describing it by side effect.
-- Each one is resolved through a pcall because indexing a property a client
-- doesn't have throws rather than returning nil, so an older client falls
-- back to the legacy name instead of erroring the whole script at load.
local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle ------------------------------------------------------------------
-- Everything that hooks into the game registers here so unloading actually
-- unloads instead of leaving loops and connections running against a
-- destroyed UI.
local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

-- Background loops don't get cancelled on unload, they check Unloading and
-- exit on their own - cancelling a thread mid-iteration could strand it
-- halfway through restoring something.
local function spawnLoop(fn)
    return task.spawn(fn)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Remotes --------------------------------------------------------------------
local function waitForPath(root, path, timeout)
    local current = root
    for _, name in ipairs(path) do
        if not current then return nil end
        local ok, child = pcall(function() return current:WaitForChild(name, timeout or 10) end)
        if not ok then return nil end
        current = child
    end
    return current
end

local RemotesFolder = waitForPath(ReplicatedStorage, { "Remotes" })
local ArrestPlayer = RemotesFolder and RemotesFolder:FindFirstChild("ArrestPlayer")
local RequestTeamChange = RemotesFolder and RemotesFolder:FindFirstChild("RequestTeamChange")
local MeleeEvent = ReplicatedStorage:FindFirstChild("meleeEvent")
local GunRemotes = ReplicatedStorage:FindFirstChild("GunRemotes")
local ShootEvent = GunRemotes and GunRemotes:FindFirstChild("ShootEvent")

local DEFAULT_WALKSPEED = 16
local DEFAULT_JUMPPOWER = 50

--// Config ---------------------------------------------------------------------
local Aim = {
    SilentAim = false,
    CameraLock = false,
    CameraLockSmooth = 0.35,
    TeamCheck = true,
    WallCheck = true,
    AimPart = "Head",
    MaxRange = 300,
    FOVEnabled = true,
    FOVRadius = 200,
    FOVTransparency = 0.6,
    FOVFollowMouse = true,
}

local Combat = {
    InstaKillPunch = false,
    PunchHits = 10,
    AutoPunch = false,
    AutoPunchRange = 8,
    AutoPunchDelay = 0.35,
    InfiniteAmmo = false,
}

local Arrest = {
    AutoArrest = false,
    Cooldown = 7.2,
    Range = 7.5,
    SettleFrames = 3,
    ReturnAfter = true,
    Selected = nil,
}

local Move = {
    SpeedEnabled = false,
    WalkSpeed = DEFAULT_WALKSPEED,
    JumpEnabled = false,
    JumpPower = DEFAULT_JUMPPOWER,
    InfiniteJump = false,
    Noclip = false,
    Fly = false,
    FlySpeed = 60,
    ClickTP = false,
    AntiAFK = true,
}

local Visual = {
    Enabled = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    ShowHealth = true,
    ShowDistance = true,
    TeamColor = true,
    Fullbright = false,
    NoFog = false,
}

--// Character helpers -----------------------------------------------------------
local function getCharacter()
    return LocalPlayer.Character
end

local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isAlive()
    local hum = getHumanoid()
    return hum ~= nil and hum.Health > 0
end

local function rootOf(plr)
    local char = plr.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function humanoidOf(plr)
    local char = plr.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function distanceTo(position)
    local root = getRoot()
    if not root then return math.huge end
    return (root.Position - position).Magnitude
end

--// Targeting ------------------------------------------------------------------
-- Team rules straight out of the game's own arrest script: Guards can't act
-- on other Guards, and an Inmate is only a legal target if the server has
-- flagged them Hostile or Trespassing (attributes on the character model).
local function charAttribute(char, name)
    local ok, value = pcall(function() return char:GetAttribute(name) end)
    if ok then return value end
    return nil
end

local function isHostile(char)
    local attr = charAttribute(char, "Hostile")
    if attr ~= nil then return attr == true end
    local value = char:FindFirstChild("Hostile")
    if value and value:IsA("BoolValue") then return value.Value end
    return false
end

local function canDamage(plr)
    if plr == LocalPlayer then return false end
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if char:FindFirstChildOfClass("ForceField") then return false end
    if Aim.TeamCheck then
        local myTeam, theirTeam = LocalPlayer.Team, plr.Team
        if myTeam and theirTeam and myTeam == theirTeam then return false end
        if myTeam == Teams:FindFirstChild("Guards") and not isHostile(char) then
            -- Guards shooting non-hostile inmates gets you nothing; the
            -- server won't credit it and it flags you instead.
            if theirTeam == Teams:FindFirstChild("Inmates") then return false end
        end
    end
    return true
end

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.IgnoreWater = true

local function isVisible(char, origin)
    if not Aim.WallCheck then return true end
    local target = char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart")
    if not target then return false end
    local params = visionParams
    params.FilterDescendantsInstances = { getCharacter(), char }
    local direction = target.Position - origin
    local ok, result = pcall(function() return Workspace:Raycast(origin, direction, params) end)
    if not ok then return true end
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

local function screenAnchor()
    if Aim.FOVFollowMouse then
        return UserInputService:GetMouseLocation()
    end
    local viewport = Camera.ViewportSize
    return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

local function getTarget(origin)
    origin = origin or Camera.CFrame.Position
    local anchor = screenAnchor()
    local best, bestScore

    for _, plr in ipairs(Players:GetPlayers()) do
        if canDamage(plr) then
            local char = plr.Character
            local part = char and (char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart"))
            if part then
                local dist = (part.Position - origin).Magnitude
                if dist <= Aim.MaxRange then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
                    if onScreen then
                        local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - anchor).Magnitude
                        if not Aim.FOVEnabled or screenDist <= Aim.FOVRadius then
                            if isVisible(char, origin) then
                                if not bestScore or screenDist < bestScore then
                                    bestScore = screenDist
                                    best = part
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

--// Target cache ----------------------------------------------------------------
-- getTarget raycasts once per player, and the shot path can call into it a
-- lot: ProjectileCount up to 20 means 20 casts per shot, and FireRate down
-- to 0.02 means 50 shots a second. That is 1000 casts/sec, each previously
-- doing a full player scan with a raycast each - tens of thousands of
-- raycasts per second on a busy server, which is what was actually killing
-- the client whenever gun mods were on.
--
-- Nothing about the answer changes 1000 times a second, so it's computed at
-- most once per frame and every cast just reads the result. This makes the
-- shot path O(1) no matter how the gun is configured.
local cachedTarget = nil
local cachedTargetAt = 0
local TARGET_CACHE_SECONDS = 1 / 30

local function getCachedTarget(origin)
    local now = os.clock()
    if cachedTarget and cachedTarget.Parent and (now - cachedTargetAt) < TARGET_CACHE_SECONDS then
        return cachedTarget
    end
    cachedTargetAt = now
    local ok, result = pcall(getTarget, origin)
    cachedTarget = ok and result or nil
    return cachedTarget
end

--// Silent aim -----------------------------------------------------------------
-- The gun tool's fire script never appears in a dump (it only exists in your
-- Backpack while a gun is actually held, and it isn't decompilable from
-- there either), so the raycast it shoots through can't be referenced by
-- name. It can be found at runtime instead: walk the GC for a function
-- literally named "castRay" and swap it for one that returns our target.
--
-- getgc() and NOT getgc(true) - the `true` variant also returns every live
-- table in the game, which on a populated server is a heap walk big enough
-- to hitch or crash the client outright. Only functions are ever inspected
-- here, so tables were never needed.
local silentAimAPIAvailable = typeof(getgc) == "function"
    and typeof(hookfunction) == "function"
    and typeof(debug) == "table"
    and typeof(debug.getinfo) == "function"

local castRayHookFound = false
local hookScanStarted = false

local function toolAttribute(tool, name)
    if typeof(tool) ~= "Instance" then return nil end
    local ok, value = pcall(function() return tool:GetAttribute(name) end)
    if ok then return value end
    return nil
end

-- The real castRay is called with a flexible argument order depending on the
-- gun, so both wrappers below sniff the arguments by type rather than
-- assuming positions.
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.CollisionGroup = "ClientBullet"

local function normalCast(p1, p2, p3)
    local origin, aim, tool
    if typeof(p1) == "Vector3" then
        origin = p1
        if typeof(p2) == "Vector3" then aim = p2 elseif typeof(p3) == "Vector3" then aim = p3 end
        if typeof(p2) == "Instance" then tool = p2 elseif typeof(p3) == "Instance" then tool = p3 end
    else
        tool = p1
        if typeof(p2) == "Vector3" then origin = p2 end
        if typeof(p3) == "Vector3" then aim = p3 elseif typeof(p2) == "Vector3" then aim = p2 end
    end

    if not origin or not aim then
        return nil, Vector3.new()
    end

    local direction = aim - origin
    if direction.Magnitude <= 0 then direction = Vector3.new(0, 0, -1) end

    local range = toolAttribute(tool, "Range") or 200
    -- Reused rather than allocated per cast: this runs on the shot path,
    -- which a modded fire rate and projectile count can drive into the
    -- hundreds of calls a second.
    local params = castParams
    params.FilterDescendantsInstances = getCharacter() and { getCharacter() } or {}

    local result = Workspace:Raycast(origin, direction.Unit * range, params)
    if result then
        return result.Instance, result.Position
    end
    return nil, origin + direction.Unit * range
end

-- Deliberately never delegates to a captured "original". hookfunction hands
-- back a callable trampoline which is itself a live function named castRay,
-- so a later scan could hook that too - and then calling the original would
-- re-enter the hook and recurse until the stack blew. Falling back to our
-- own normalCast has no such cycle.
local function hookedCast(p1, p2, p3)
    if not Aim.SilentAim then
        return normalCast(p1, p2, p3)
    end

    local origin
    if typeof(p1) == "Vector3" then origin = p1
    elseif typeof(p2) == "Vector3" then origin = p2
    elseif typeof(p3) == "Vector3" then origin = p3 end

    if origin then
        local root = getRoot()
        -- Only redirect casts that plausibly originate from our own gun -
        -- anything far from us is somebody else's shot being simulated
        -- locally, and rewriting those does nothing but corrupt visuals.
        if root and (origin - root.Position).Magnitude <= 75 then
            local target = getCachedTarget(origin)
            if target and target.Parent then
                return target, target.Position
            end
        end
    end

    return normalCast(p1, p2, p3)
end

-- Every function we've already replaced. Without this the scan re-hooks the
-- same castRay on every pass, and hookfunction stacks: each new hook wraps
-- the previous one, so after a few minutes a single shot walks a chain
-- hundreds of trampolines deep. That is a slow-building framerate leak that
-- ends in a crash, and it also silently defeated the old backoff (a pass
-- that "successfully" re-hooked always looked productive, so the scan never
-- went quiet). Weak-keyed so a function that gets collected stops being
-- pinned here.
local hookedFunctions = setmetatable({}, { __mode = "k" })

-- One pass over the GC. Returns how many genuinely new functions it hooked.
local function scanForCastRay()
    if not silentAimAPIAvailable then return 0 end

    local newHooks = 0
    pcall(function()
        for _, object in ipairs(getgc()) do
            if type(object) == "function"
                and not hookedFunctions[object]
                -- Never hook our own replacements, or the hook ends up
                -- calling itself.
                and object ~= hookedCast
                and object ~= normalCast
            then
                local info = debug.getinfo(object)
                if info and info.name == "castRay" then
                    local ok, previous = pcall(hookfunction, object, hookedCast)
                    if ok then
                        hookedFunctions[object] = true
                        -- The returned trampoline is itself a live function
                        -- named castRay; mark it hooked so a later pass
                        -- never wraps it and builds a cycle.
                        if type(previous) == "function" then
                            hookedFunctions[previous] = true
                        end
                        castRayHookFound = true
                        newHooks = newHooks + 1
                    end
                end
            end
        end
    end)
    return newHooks
end

-- A gun only registers a new castRay when it's actually equipped, so that's
-- the event worth reacting to - far cheaper and more accurate than walking
-- the whole heap on a timer forever.
local function scanSoon()
    if not silentAimAPIAvailable or Unloading then return end
    task.delay(0.35, function()
        if not Unloading and Aim.SilentAim then scanForCastRay() end
    end)
end

local function watchCharacterForTools(char)
    track(char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then scanSoon() end
    end))
end

local function startSilentAimHookScan()
    if hookScanStarted or not silentAimAPIAvailable then return end
    hookScanStarted = true

    local char = getCharacter()
    if char then watchCharacterForTools(char) end
    track(LocalPlayer.CharacterAdded:Connect(function(newChar)
        watchCharacterForTools(newChar)
        scanSoon()
    end))

    spawnLoop(function()
        -- A few opening passes to catch a gun that was already equipped
        -- before silent aim was switched on, then this loop is done for
        -- good - equip events take over from here.
        local emptyPasses = 0
        while not Unloading and emptyPasses < 4 do
            if scanForCastRay() > 0 then
                emptyPasses = 0
            else
                emptyPasses = emptyPasses + 1
            end
            task.wait(2)
        end
    end)
end

--// Camera lock ----------------------------------------------------------------
-- Bound one priority above Camera so it writes after the game's own camera
-- module has already run for the frame, instead of fighting it mid-update.
-- Deliberately smoothed: snapping the camera exactly onto a head every frame
-- is the single most obvious thing a spectator can see.
local CAMERA_LOCK_BIND = "PrisonLifeCameraLock"

pcall(function() RunService:UnbindFromRenderStep(CAMERA_LOCK_BIND) end)

RunService:BindToRenderStep(CAMERA_LOCK_BIND, Enum.RenderPriority.Camera.Value + 1, function()
    if Unloading then return end
    -- Camera lock is its own toggle, but it also covers for silent aim when
    -- the castRay hook never landed - otherwise "silent aim on" would sit
    -- there doing nothing at all on an executor without hookfunction.
    local wantLock = Aim.CameraLock or (Aim.SilentAim and not castRayHookFound)
    if not wantLock then return end

    -- Shares the cache with the shot path so turning both on doesn't scan
    -- the player list twice per frame.
    local target = getCachedTarget(Camera.CFrame.Position)
    if not target then return end

    local goal = CFrame.new(Camera.CFrame.Position, target.Position)
    local alpha = math.clamp(Aim.CameraLockSmooth, 0.01, 1)
    Camera.CFrame = Camera.CFrame:Lerp(goal, alpha)
end)

--// FOV circle -----------------------------------------------------------------
local fovCircle
if typeof(Drawing) == "table" then
    pcall(function()
        fovCircle = Drawing.new("Circle")
        fovCircle.Thickness = 1.5
        fovCircle.NumSides = 64
        fovCircle.Filled = false
        fovCircle.Color = Color3.fromRGB(255, 255, 255)
        fovCircle.Visible = false
    end)
end

track(PreRender:Connect(function()
    if not fovCircle or Unloading then return end
    fovCircle.Visible = Aim.FOVEnabled
    if not Aim.FOVEnabled then return end
    fovCircle.Radius = Aim.FOVRadius
    -- Drawing treats Transparency as opacity (1 = solid), the inverse of
    -- Roblox's own convention, so the slider is flipped to match what the
    -- rest of the menu means by "transparency".
    fovCircle.Transparency = 1 - Aim.FOVTransparency
    fovCircle.Position = screenAnchor()
end))

--// Auto arrest ----------------------------------------------------------------
-- The real constraint here isn't finding a target, it's that the server only
-- honours an arrest when you're genuinely within 7.5 studs. So this moves
-- you there, waits a few simulation steps for that position to actually
-- replicate (setting CFrame and invoking in the same frame just gets
-- rejected), fires, then puts you back.
local lastArrestAt = 0

local function isArrestable(plr)
    if plr == LocalPlayer then return false end
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if char:FindFirstChildOfClass("ForceField") then return false end

    local criminals = Teams:FindFirstChild("Criminals")
    local inmates = Teams:FindFirstChild("Inmates")

    if plr.Team == criminals then return true end
    if plr.Team == inmates then
        local attrs = {}
        pcall(function() attrs = char:GetAttributes() end)
        if attrs.Hostile and attrs.Tased then return true end
        if attrs.Trespassing then return true end
    end
    return false
end

local function arrestPlayer(plr)
    if not ArrestPlayer then return false, "ArrestPlayer remote missing" end
    if not isAlive() then return false, "you are dead" end

    local myRoot = getRoot()
    local theirRoot = rootOf(plr)
    if not myRoot or not theirRoot then return false, "no character" end

    local saved = myRoot.CFrame
    -- Stand just behind them rather than inside them; overlapping bodies can
    -- get shoved apart by physics before the invoke lands.
    myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 3)

    for _ = 1, math.max(1, Arrest.SettleFrames) do
        PostSimulation:Wait()
    end

    local ok, result = pcall(function() return ArrestPlayer:InvokeServer(plr, 1) end)

    if Arrest.ReturnAfter then
        local rootNow = getRoot()
        if rootNow then rootNow.CFrame = saved end
    end

    if not ok then return false, tostring(result) end
    if not result then return false, "server declined" end
    return true, "ok"
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.15)
        if Arrest.AutoArrest and isAlive() then
            local now = os.clock()
            if now - lastArrestAt >= Arrest.Cooldown then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if Unloading or not Arrest.AutoArrest then break end
                    if isArrestable(plr) then
                        local success = arrestPlayer(plr)
                        if success then
                            lastArrestAt = os.clock()
                            break
                        end
                    end
                end
            end
        end
    end
end)

--// Melee ----------------------------------------------------------------------
-- meleeEvent:FireServer(target, 1, 1) is exactly what the game's own input
-- handler fires when a punch animation reaches its hit marker. Firing it N
-- times in a row is the whole "insta kill" trick - there's no damage
-- argument to inflate, just repetition.
local INSTA_KILL_BATCH = 20
local INSTA_KILL_MAX_BURSTS = 2
local instaKillBursts = 0

local function queueInstaKill(target)
    if not MeleeEvent then return end
    -- Holding down punch fires this repeatedly, and each burst can be up to
    -- PunchHits remote calls - without a cap they stack into a self-inflicted
    -- flood that lags the client long before it kills anything.
    if instaKillBursts >= INSTA_KILL_MAX_BURSTS then return end
    instaKillBursts = instaKillBursts + 1
    spawnLoop(function()
        -- Minus one: the punch that triggered this hook is already on its
        -- way, so PunchHits counts total hits, not extra ones.
        local remaining = math.max(0, Combat.PunchHits - 1)
        while remaining > 0 and not Unloading do
            local batch = math.min(INSTA_KILL_BATCH, remaining)
            for _ = 1, batch do
                pcall(function() MeleeEvent:FireServer(target, 1, 1) end)
            end
            remaining = remaining - batch
            -- Yield between batches so a large count never blocks the frame
            -- the hook fired on.
            task.wait()
        end
        instaKillBursts = instaKillBursts - 1
    end)
end

-- Recorded from the first real ShootEvent call so the argument shape can be
-- read off the settings tab instead of guessed at.
local shootSignature = nil

local function describeArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        local kind = typeof(value)
        if kind == "Instance" then
            parts[#parts + 1] = ("%d:%s(%s)"):format(i, kind, value.ClassName)
        else
            parts[#parts + 1] = ("%d:%s"):format(i, kind)
        end
    end
    return table.concat(parts, "  ")
end

-- Rewrites whatever in the outgoing shot describes what was hit. The gun
-- script isn't dumpable so the exact parameter order isn't known, but it
-- doesn't need to be: any argument that is another character's BasePart
-- becomes our target's part, and any Vector3 that reads as a hit position
-- becomes our target's position. Everything else passes through untouched.
local function redirectShotArgs(target, ...)
    local args = table.pack(...)
    local changed = false

    for i = 1, args.n do
        local value = args[i]
        local kind = typeof(value)
        if kind == "Instance" and value:IsA("BasePart") then
            local model = value:FindFirstAncestorOfClass("Model")
            if model and model ~= LocalPlayer.Character and model:FindFirstChildOfClass("Humanoid") then
                args[i] = target
                changed = true
            end
        elseif kind == "Vector3" then
            local root = getRoot()
            -- Only positions out in the world, not local offsets/directions.
            if root and (value - root.Position).Magnitude > 1 then
                args[i] = target.Position
                changed = true
            end
        end
    end

    if not changed then return false end
    return true, table.unpack(args, 1, args.n)
end

if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local originalNamecall
    originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if not Unloading then
            local method = getnamecallmethod()

            if Combat.InstaKillPunch and self == MeleeEvent and method == "FireServer" then
                local target = ...
                -- Return immediately and let the repeats happen off-frame:
                -- this metamethod fires for every method call in the entire
                -- game, so blocking in here is not an option.
                queueInstaKill(target)

            elseif self == ShootEvent and method == "FireServer" then
                if not shootSignature then
                    shootSignature = describeArgs(...)
                end
                -- The deterministic half of silent aim. Hooking castRay
                -- depends on finding a function by name in the GC, which is
                -- fragile and was silently doing nothing some rounds; this
                -- fires on the actual shot every time. Reads the cached
                -- target, so a 20-pellet burst costs one lookup, not twenty
                -- player scans.
                if Aim.SilentAim then
                    local target = getCachedTarget(Camera.CFrame.Position)
                    if target and target.Parent then
                        local ok, a, b, c, d, e, f = redirectShotArgs(target, ...)
                        if ok then
                            return originalNamecall(self, a, b, c, d, e, f)
                        end
                    end
                end
            end
        end
        return originalNamecall(self, ...)
    end)
end

spawnLoop(function()
    while not Unloading do
        task.wait(Combat.AutoPunchDelay)
        if Combat.AutoPunch and isAlive() and MeleeEvent then
            local root = getRoot()
            if root then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if canDamage(plr) then
                        local theirRoot = rootOf(plr)
                        if theirRoot and (theirRoot.Position - root.Position).Magnitude <= Combat.AutoPunchRange then
                            pcall(function() MeleeEvent:FireServer(plr, 1, 1) end)
                        end
                    end
                end
            end
        end
    end
end)

--// Gun mods ------------------------------------------------------------------
-- These are attributes on your own Tool instances. The script that reads
-- them lives inside the gun tool and isn't dumpable, so which of these the
-- server re-validates and which it trusts is genuinely unknown - treat the
-- whole tab as "try it and see", not as guaranteed.
local GunModStats = {
    { Key = "Damage", Title = "damage", Min = 1, Max = 300, Increment = 1, Default = 19 },
    { Key = "FireRate", Title = "fire rate", Min = 0.02, Max = 1, Increment = 0.01, Default = 0.12, Suffix = "s" },
    { Key = "Range", Title = "range", Min = 100, Max = 5000, Increment = 50, Default = 1500, Suffix = " studs" },
    { Key = "AccurateRange", Title = "accurate range", Min = 10, Max = 500, Increment = 5, Default = 110, Suffix = " studs" },
    { Key = "SpreadRadius", Title = "spread radius", Min = 0, Max = 0.1, Increment = 0.001, Default = 0 },
    { Key = "ReloadTime", Title = "reload time", Min = 0, Max = 5, Increment = 0.1, Default = 2, Suffix = "s" },
    { Key = "MaxAmmo", Title = "max ammo", Min = 1, Max = 999, Increment = 1, Default = 15 },
    { Key = "ProjectileCount", Title = "projectile count", Min = 1, Max = 20, Increment = 1, Default = 5 },
}

local GunModConfig = {}
for _, stat in ipairs(GunModStats) do
    GunModConfig[stat.Key] = { Enabled = false, Value = stat.Default }
end
local AutoFireConfig = { Enabled = false, Value = true }

local function forEachOwnedTool(fn)
    local char = getCharacter()
    if char then
        for _, inst in ipairs(char:GetChildren()) do
            if inst:IsA("Tool") then fn(inst) end
        end
    end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, inst in ipairs(backpack:GetChildren()) do
            if inst:IsA("Tool") then fn(inst) end
        end
    end
end

local function applyGunModsToTool(tool)
    for _, stat in ipairs(GunModStats) do
        local cfg = GunModConfig[stat.Key]
        if cfg.Enabled and tool:GetAttribute(stat.Key) ~= nil then
            pcall(function() tool:SetAttribute(stat.Key, cfg.Value) end)
        end
    end
    if AutoFireConfig.Enabled and tool:GetAttribute("AutoFire") ~= nil then
        pcall(function() tool:SetAttribute("AutoFire", AutoFireConfig.Value) end)
    end
    if Combat.InfiniteAmmo then
        local maxAmmo = tool:GetAttribute("MaxAmmo")
        if maxAmmo ~= nil and tool:GetAttribute("CurrentAmmo") ~= nil then
            pcall(function() tool:SetAttribute("CurrentAmmo", maxAmmo) end)
        end
    end
end

local function applyGunModsNow()
    forEachOwnedTool(applyGunModsToTool)
end

-- Every toggle applies instantly on change, so this loop exists purely to
-- re-apply after the game resets something itself (a reload writing
-- CurrentAmmo back down). It does not need to be anywhere near per-frame.
spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        applyGunModsNow()
    end
end)

--// Movement -------------------------------------------------------------------
local noclipConnection
local flyVelocity, flyGyro
local flyDirection = Vector3.new()

local function setNoclip(state)
    if noclipConnection then
        noclipConnection:Disconnect()
        noclipConnection = nil
    end
    if not state then
        local char = getCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide == false and part.Name ~= "HumanoidRootPart" then
                    part.CanCollide = true
                end
            end
        end
        return
    end
    -- PreSimulation, not PostSimulation: collisions have to be off *before*
    -- the physics step resolves them, not after it already pushed us out.
    -- Deliberately not registered in Connections - it's owned by
    -- noclipConnection and replaced on every toggle, so tracking it would
    -- just grow that list by one dead entry per toggle.
    noclipConnection = PreSimulation:Connect(function()
        if not Move.Noclip or Unloading then return end
        local char = getCharacter()
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end)
end

local function stopFly()
    if flyVelocity then flyVelocity:Destroy() flyVelocity = nil end
    if flyGyro then flyGyro:Destroy() flyGyro = nil end
    local hum = getHumanoid()
    if hum then
        pcall(function() hum.PlatformStand = false end)
    end
end

local function startFly()
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum then return end
    stopFly()

    flyVelocity = Instance.new("BodyVelocity")
    flyVelocity.MaxForce = Vector3.new(1, 1, 1) * 9e9
    flyVelocity.Velocity = Vector3.new()
    flyVelocity.Parent = root

    flyGyro = Instance.new("BodyGyro")
    flyGyro.MaxTorque = Vector3.new(1, 1, 1) * 9e9
    flyGyro.P = 9e4
    flyGyro.CFrame = Camera.CFrame
    flyGyro.Parent = root
end

track(PostSimulation:Connect(function()
    if Unloading then return end
    if not Move.Fly then return end
    if not flyVelocity or not flyGyro then return end
    local root = getRoot()
    if not root then return end

    local direction = Vector3.new()
    local camCF = Camera.CFrame
    if flyDirection.Z ~= 0 then direction = direction + camCF.LookVector * -flyDirection.Z end
    if flyDirection.X ~= 0 then direction = direction + camCF.RightVector * flyDirection.X end
    if flyDirection.Y ~= 0 then direction = direction + Vector3.new(0, flyDirection.Y, 0) end

    if direction.Magnitude > 0 then
        flyVelocity.Velocity = direction.Unit * Move.FlySpeed
    else
        flyVelocity.Velocity = Vector3.new()
    end
    flyGyro.CFrame = camCF
end))

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloading or processed then return end
    if input.KeyCode == Enum.KeyCode.W then flyDirection = flyDirection + Vector3.new(0, 0, 1) end
    if input.KeyCode == Enum.KeyCode.S then flyDirection = flyDirection - Vector3.new(0, 0, 1) end
    if input.KeyCode == Enum.KeyCode.A then flyDirection = flyDirection - Vector3.new(1, 0, 0) end
    if input.KeyCode == Enum.KeyCode.D then flyDirection = flyDirection + Vector3.new(1, 0, 0) end
    if input.KeyCode == Enum.KeyCode.Space then flyDirection = flyDirection + Vector3.new(0, 1, 0) end
    if input.KeyCode == Enum.KeyCode.LeftShift then flyDirection = flyDirection - Vector3.new(0, 1, 0) end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if Unloading then return end
    if input.KeyCode == Enum.KeyCode.W then flyDirection = flyDirection - Vector3.new(0, 0, 1) end
    if input.KeyCode == Enum.KeyCode.S then flyDirection = flyDirection + Vector3.new(0, 0, 1) end
    if input.KeyCode == Enum.KeyCode.A then flyDirection = flyDirection + Vector3.new(1, 0, 0) end
    if input.KeyCode == Enum.KeyCode.D then flyDirection = flyDirection - Vector3.new(1, 0, 0) end
    if input.KeyCode == Enum.KeyCode.Space then flyDirection = flyDirection - Vector3.new(0, 1, 0) end
    if input.KeyCode == Enum.KeyCode.LeftShift then flyDirection = flyDirection + Vector3.new(0, 1, 0) end
end))

-- Infinite jump: the Jumping state fires every time the humanoid decides to
-- jump, so re-arming inside it is what turns one jump into unlimited ones.
track(UserInputService.JumpRequest:Connect(function()
    if Unloading or not Move.InfiniteJump then return end
    local hum = getHumanoid()
    if hum then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end))

-- Speed and jump are only ever written while their own toggle is on, so the
-- game's own crouch/prone/tase speed changes aren't constantly fought.
track(PostSimulation:Connect(function()
    if Unloading then return end
    local hum = getHumanoid()
    if not hum then return end
    if Move.SpeedEnabled then hum.WalkSpeed = Move.WalkSpeed end
    if Move.JumpEnabled then hum.JumpPower = Move.JumpPower end
end))

local function performClickTP(screenPos)
    local root = getRoot()
    if not root then return end
    local ray = Camera:ViewportPointToRay(screenPos.X, screenPos.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getCharacter() }
    local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
    if result then
        root.CFrame = CFrame.new(result.Position + Vector3.new(0, 3, 0))
    end
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloading or processed or not Move.ClickTP then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        local pos = input.Position
        performClickTP(Vector2.new(pos.X, pos.Y))
    end
end))

track(LocalPlayer.Idled:Connect(function()
    if Unloading or not Move.AntiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

track(LocalPlayer.CharacterAdded:Connect(function(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    if Move.SpeedEnabled then hum.WalkSpeed = Move.WalkSpeed end
    if Move.JumpEnabled then hum.JumpPower = Move.JumpPower end
    if Move.Noclip then setNoclip(true) end
    if Move.Fly then task.wait(0.5) startFly() end
end))

--// Teleports ------------------------------------------------------------------
-- Resolved by name from the live workspace rather than hardcoded coordinates,
-- so these keep working if the map shifts. Every name here was confirmed
-- present in the dump.
local TeleportTargets = {
    { Title = "prison spawn", Path = "Prison_spawn" },
    { Title = "cellblock", Path = "Prison_Cellblock" },
    { Title = "cell doors", Path = "CellDoors" },
    { Title = "yard / grounds", Path = "Prison_Grounds" },
    { Title = "armory (gun racks)", Path = "Gun racks" },
    { Title = "swat gun rack", Path = "SWAT gun rack" },
    { Title = "guard booth", Path = "GuardBooth" },
    { Title = "guard tower", Path = "Prison_guardtower" },
    { Title = "criminal base", Path = "Criminals Spawn" },
    { Title = "neutral spawn", Path = "NEUTRAL SPAWNLOCATIONS" },
    { Title = "sewer", Path = "Sewer" },
    { Title = "parking lot", Path = "Prison_Parking" },
    { Title = "garages", Path = "Garages" },
}

local function pivotOf(instance)
    if instance:IsA("BasePart") then return instance.CFrame end
    if instance:IsA("Model") then
        local ok, cf = pcall(function() return instance:GetPivot() end)
        if ok then return cf end
        if instance.PrimaryPart then return instance.PrimaryPart.CFrame end
    end
    -- Folders have no pivot of their own; borrow the first real part inside.
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then return descendant.CFrame end
    end
    return nil
end

local function teleportTo(cframe)
    local root = getRoot()
    if not root or not cframe then return false end
    root.CFrame = cframe + Vector3.new(0, 4, 0)
    return true
end

local function teleportToNamed(name)
    local instance = Workspace:FindFirstChild(name)
    if not instance then return false, "not found in workspace" end
    local cf = pivotOf(instance)
    if not cf then return false, "no parts to teleport to" end
    return teleportTo(cf), "ok"
end

local savedWaypoint = nil
local selectedTpPlayer = nil

--// ESP ------------------------------------------------------------------------
local espObjects = {}

local function teamColorFor(plr)
    if not Visual.TeamColor then return Color3.fromRGB(230, 60, 60) end
    local team = plr.Team
    if team == Teams:FindFirstChild("Guards") then return Color3.fromRGB(70, 140, 255) end
    if team == Teams:FindFirstChild("Criminals") then return Color3.fromRGB(230, 60, 60) end
    if team == Teams:FindFirstChild("Inmates") then return Color3.fromRGB(255, 170, 60) end
    return Color3.fromRGB(200, 200, 200)
end

local function destroyEspFor(plr)
    local objs = espObjects[plr]
    if not objs then return end
    if objs.Highlight then objs.Highlight:Destroy() end
    if objs.Billboard then objs.Billboard:Destroy() end
    if objs.Box then pcall(function() objs.Box:Remove() end) end
    if objs.Tracer then pcall(function() objs.Tracer:Remove() end) end
    espObjects[plr] = nil
end

local function buildEspFor(plr, char)
    destroyEspFor(plr)
    local color = teamColorFor(plr)
    local objs = { Char = char, Method = Visual.Method, ShowNames = Visual.ShowNames }
    espObjects[plr] = objs

    if Visual.Method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = color
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = char
        objs.Highlight = hl
    elseif typeof(Drawing) == "table" then
        pcall(function()
            if Visual.Method == "Box" then
                local box = Drawing.new("Square")
                box.Thickness = 1.5
                box.Filled = false
                box.Color = color
                box.Visible = false
                objs.Box = box
            elseif Visual.Method == "Tracers" then
                local line = Drawing.new("Line")
                line.Thickness = 1.5
                line.Color = color
                line.Visible = false
                objs.Tracer = line
            end
        end)
    end

    if Visual.ShowNames then
        local head = char:FindFirstChild("Head")
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "PrisonLifeESP"
        billboard.Adornee = head or char.PrimaryPart
        billboard.Size = UDim2.fromOffset(200, 40)
        billboard.StudsOffset = Vector3.new(0, 1.4, 0)
        billboard.AlwaysOnTop = true
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = color
        label.TextStrokeTransparency = 0.4
        label.Text = plr.Name
        label.Parent = billboard
        billboard.Parent = char
        objs.Billboard = billboard
        objs.NameLabel = label
    end
end

-- Slow-changing things (colour, name text, health readout, roster churn) run
-- on a poll; only the screen-space maths that has to track the camera runs
-- per frame.
spawnLoop(function()
    while not Unloading do
        task.wait(0.4)
        if Visual.Enabled then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    local char = plr.Character
                    local objs = espObjects[plr]
                    if not char then
                        if objs then destroyEspFor(plr) end
                    elseif not objs or objs.Char ~= char or objs.Method ~= Visual.Method or objs.ShowNames ~= Visual.ShowNames then
                        buildEspFor(plr, char)
                    else
                        local color = teamColorFor(plr)
                        if objs.Highlight then
                            objs.Highlight.FillTransparency = Visual.Transparency
                            objs.Highlight.FillColor = color
                            objs.Highlight.OutlineColor = color
                        end
                        if objs.NameLabel then
                            local text = plr.Name
                            local hum = humanoidOf(plr)
                            if Visual.ShowHealth and hum then
                                text = text .. (" [%d hp]"):format(math.floor(hum.Health))
                            end
                            if Visual.ShowDistance then
                                local root = rootOf(plr)
                                if root then
                                    text = text .. (" [%d]"):format(math.floor(distanceTo(root.Position)))
                                end
                            end
                            objs.NameLabel.Text = text
                            objs.NameLabel.TextColor3 = color
                        end
                    end
                end
            end
        else
            for plr in pairs(espObjects) do
                destroyEspFor(plr)
            end
        end
    end
end)

track(PreRender:Connect(function()
    if Unloading or not Visual.Enabled then return end
    for plr, objs in pairs(espObjects) do
        local char = plr.Character
        if not char or not char.Parent then
            destroyEspFor(plr)
        else
            local root = char:FindFirstChild("HumanoidRootPart")
            local color = teamColorFor(plr)

            if objs.Box and root then
                local head = char:FindFirstChild("Head")
                local topPos = head and (head.Position + Vector3.new(0, 0.5, 0)) or (root.Position + Vector3.new(0, 2, 0))
                local bottomPos = root.Position - Vector3.new(0, 3, 0)
                local topScreen, onScreen = Camera:WorldToViewportPoint(topPos)
                local bottomScreen = Camera:WorldToViewportPoint(bottomPos)
                if onScreen then
                    local height = bottomScreen.Y - topScreen.Y
                    local width = height * 0.6
                    objs.Box.Visible = true
                    objs.Box.Color = color
                    objs.Box.Transparency = 1 - Visual.Transparency
                    objs.Box.Position = Vector2.new(topScreen.X - width / 2, topScreen.Y)
                    objs.Box.Size = Vector2.new(width, height)
                else
                    objs.Box.Visible = false
                end
            end

            if objs.Tracer and root then
                local screenPoint, onScreen = Camera:WorldToViewportPoint(root.Position)
                if onScreen then
                    objs.Tracer.Visible = true
                    objs.Tracer.Color = color
                    objs.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                    objs.Tracer.To = Vector2.new(screenPoint.X, screenPoint.Y)
                else
                    objs.Tracer.Visible = false
                end
            end
        end
    end
end))

track(Players.PlayerRemoving:Connect(destroyEspFor))

--// World visuals --------------------------------------------------------------
local savedLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
}

local function applyFullbright(state)
    if state then
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
    else
        Lighting.Brightness = savedLighting.Brightness
        Lighting.ClockTime = savedLighting.ClockTime
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.Ambient = savedLighting.Ambient
    end
end

local function applyNoFog(state)
    Lighting.FogEnd = state and 1e6 or savedLighting.FogEnd
end

--// UI -------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'prison life',
    SubTitle = 'assist',
    Folder = 'PrisonLifeAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(70, 160, 255),
})

local function notify(content, kind, duration)
    Centrl:Notify({
        Title = 'prison life',
        Content = content,
        Type = kind or 'success',
        Duration = duration or 5,
    })
end

if not ArrestPlayer then
    notify('Remotes.ArrestPlayer not found - the arrest tab will not work.', 'error', 8)
end

--// Combat tab
local CombatTab = Window:Tab({ Title = 'combat', Icon = 'crosshair' })
local AimSection = CombatTab:Section({ Title = 'aim', Side = 'left' })

AimSection:Toggle({
    Title = 'silent aim',
    Flag = 'pl_silent_aim',
    Default = false,
    Callback = function(v)
        Aim.SilentAim = v
        if v then
            startSilentAimHookScan()
            if not silentAimAPIAvailable then
                notify('getgc/hookfunction unavailable - falling back to visible camera lock.', 'warning')
            end
        end
    end,
})

AimSection:Toggle({
    Title = 'camera lock',
    Flag = 'pl_camera_lock',
    Default = false,
    Callback = function(v) Aim.CameraLock = v end,
})

AimSection:Slider({
    Title = 'camera lock smoothing',
    Flag = 'pl_camera_smooth',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = 0.35,
    Callback = function(v) Aim.CameraLockSmooth = v end,
})

AimSection:Toggle({
    Title = 'team check',
    Flag = 'pl_team_check',
    Default = true,
    Callback = function(v) Aim.TeamCheck = v end,
})

AimSection:Toggle({
    Title = 'wall check',
    Flag = 'pl_wall_check',
    Default = true,
    Callback = function(v) Aim.WallCheck = v end,
})

AimSection:Dropdown({
    Title = 'aim at',
    Flag = 'pl_aim_part',
    Options = { 'Head', 'HumanoidRootPart', 'Torso', 'UpperTorso' },
    Default = 'Head',
    Callback = function(v) Aim.AimPart = v end,
})

AimSection:Slider({
    Title = 'max range',
    Flag = 'pl_max_range',
    Min = 0,
    Max = 1500,
    Increment = 25,
    Default = 300,
    Suffix = ' studs',
    Callback = function(v) Aim.MaxRange = v end,
})

local FovSection = CombatTab:Section({ Title = 'fov', Side = 'right' })

FovSection:Toggle({
    Title = 'fov circle',
    Flag = 'pl_fov',
    Default = true,
    Callback = function(v) Aim.FOVEnabled = v end,
})

FovSection:Toggle({
    Title = 'fov follows mouse',
    Flag = 'pl_fov_follow',
    Default = true,
    Callback = function(v) Aim.FOVFollowMouse = v end,
})

FovSection:Slider({
    Title = 'fov size',
    Flag = 'pl_fov_size',
    Min = 20,
    Max = 800,
    Increment = 5,
    Default = 200,
    Suffix = ' px',
    Callback = function(v) Aim.FOVRadius = v end,
})

FovSection:Slider({
    Title = 'fov transparency',
    Flag = 'pl_fov_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.6,
    Callback = function(v) Aim.FOVTransparency = v end,
})

local MeleeSection = CombatTab:Section({ Title = 'melee', Side = 'left' })

MeleeSection:Toggle({
    Title = 'insta kill punch',
    Flag = 'pl_insta_kill',
    Default = false,
    Callback = function(v)
        Combat.InstaKillPunch = v
        if v and not MeleeEvent then
            notify('meleeEvent not found - insta kill punch cannot work.', 'error')
        end
    end,
})

MeleeSection:Slider({
    Title = 'punch hits',
    Flag = 'pl_punch_hits',
    Min = 1,
    Max = 1000,
    Increment = 1,
    Default = 10,
    Callback = function(v) Combat.PunchHits = v end,
})

MeleeSection:Toggle({
    Title = 'auto punch nearby',
    Flag = 'pl_auto_punch',
    Default = false,
    Callback = function(v) Combat.AutoPunch = v end,
})

MeleeSection:Slider({
    Title = 'auto punch range',
    Flag = 'pl_auto_punch_range',
    Min = 3,
    Max = 30,
    Increment = 1,
    Default = 8,
    Suffix = ' studs',
    Callback = function(v) Combat.AutoPunchRange = v end,
})

MeleeSection:Paragraph({
    Title = 'how this works',
    Text = 'Punching fires meleeEvent:FireServer(target, 1, 1) - there is no damage value to raise, so "insta kill" just means firing it many times per swing. Very high counts are more likely to be noticed or rate-limited server-side.',
})

--// Arrest tab
local ArrestTab = Window:Tab({ Title = 'arrest', Icon = 'gavel' })
local AutoArrestSection = ArrestTab:Section({ Title = 'auto arrest', Side = 'left' })

AutoArrestSection:Toggle({
    Title = 'auto arrest',
    Flag = 'pl_auto_arrest',
    Default = false,
    Callback = function(v)
        Arrest.AutoArrest = v
        if v and LocalPlayer.Team ~= Teams:FindFirstChild("Guards") then
            notify('You are not on the Guards team - the server will refuse arrests.', 'warning', 6)
        end
    end,
})

AutoArrestSection:Toggle({
    Title = 'return after arrest',
    Flag = 'pl_arrest_return',
    Default = true,
    Callback = function(v) Arrest.ReturnAfter = v end,
})

AutoArrestSection:Slider({
    Title = 'cooldown',
    Flag = 'pl_arrest_cooldown',
    Min = 1,
    Max = 15,
    Increment = 0.2,
    Default = 7.2,
    Suffix = 's',
    Callback = function(v) Arrest.Cooldown = v end,
})

AutoArrestSection:Slider({
    Title = 'settle frames',
    Flag = 'pl_arrest_settle',
    Min = 1,
    Max = 10,
    Increment = 1,
    Default = 3,
    Callback = function(v) Arrest.SettleFrames = v end,
})

AutoArrestSection:Paragraph({
    Title = 'why it teleports',
    Text = 'The server only accepts an arrest from within 7.5 studs, so this moves you next to the target, waits a few simulation steps for that position to replicate, fires, then returns you. The game itself enforces a 7 second gap between arrests - dropping the cooldown below that mostly just produces refusals.',
})

local ManualArrestSection = ArrestTab:Section({ Title = 'manual', Side = 'right' })

local arrestDropdown = ManualArrestSection:Dropdown({
    Title = 'target',
    Flag = 'pl_arrest_target',
    Options = { 'none' },
    Default = 'none',
    Callback = function(v) Arrest.Selected = v end,
})

ManualArrestSection:Button({
    Title = 'refresh player list',
    Callback = function()
        local names = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then names[#names + 1] = plr.Name end
        end
        if #names == 0 then names = { 'none' } end
        pcall(function() arrestDropdown:SetOptions(names) end)
    end,
})

ManualArrestSection:Button({
    Title = 'arrest selected',
    Callback = function()
        if not Arrest.Selected or Arrest.Selected == 'none' then
            notify('No target selected.', 'warning')
            return
        end
        local target = Players:FindFirstChild(Arrest.Selected)
        if not target then
            notify('That player has left.', 'warning')
            return
        end
        local ok, reason = arrestPlayer(target)
        if ok then
            lastArrestAt = os.clock()
            notify('Arrested ' .. target.Name .. '.')
        else
            notify('Arrest failed: ' .. tostring(reason), 'error')
        end
    end,
})

ManualArrestSection:Button({
    Title = 'arrest everyone (queued)',
    Callback = function()
        spawnLoop(function()
            local count = 0
            for _, plr in ipairs(Players:GetPlayers()) do
                if Unloading then break end
                if isArrestable(plr) then
                    local ok = arrestPlayer(plr)
                    if ok then
                        count = count + 1
                        lastArrestAt = os.clock()
                        task.wait(Arrest.Cooldown)
                    end
                end
            end
            notify(('Arrest sweep finished (%d arrested).'):format(count))
        end)
    end,
})

--// Teleports tab
local TeleportTab = Window:Tab({ Title = 'teleports', Icon = 'map-pin' })
local LocationSection = TeleportTab:Section({ Title = 'locations', Side = 'left' })

for _, entry in ipairs(TeleportTargets) do
    LocationSection:Button({
        Title = entry.Title,
        Callback = function()
            local ok, reason = teleportToNamed(entry.Path)
            if not ok then
                notify(('Could not teleport to %s (%s).'):format(entry.Title, tostring(reason)), 'error')
            end
        end,
    })
end

local PlayerTpSection = TeleportTab:Section({ Title = 'players & waypoints', Side = 'right' })

local tpDropdown = PlayerTpSection:Dropdown({
    Title = 'teleport to player',
    Flag = 'pl_tp_target',
    Options = { 'none' },
    Default = 'none',
    Callback = function(v) selectedTpPlayer = v end,
})

PlayerTpSection:Button({
    Title = 'refresh player list',
    Callback = function()
        local names = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then names[#names + 1] = plr.Name end
        end
        if #names == 0 then names = { 'none' } end
        pcall(function() tpDropdown:SetOptions(names) end)
    end,
})

PlayerTpSection:Button({
    Title = 'teleport to selected',
    Callback = function()
        local name = selectedTpPlayer
        if not name or name == 'none' then
            notify('No player selected.', 'warning')
            return
        end
        local target = Players:FindFirstChild(name)
        local root = target and rootOf(target)
        if not root then
            notify('That player has no character right now.', 'warning')
            return
        end
        teleportTo(root.CFrame * CFrame.new(0, 0, 4))
    end,
})

PlayerTpSection:Button({
    Title = 'save waypoint',
    Callback = function()
        local root = getRoot()
        if not root then
            notify('No character to save a position from.', 'warning')
            return
        end
        savedWaypoint = root.CFrame
        notify('Waypoint saved.')
    end,
})

PlayerTpSection:Button({
    Title = 'return to waypoint',
    Callback = function()
        if not savedWaypoint then
            notify('No waypoint saved yet.', 'warning')
            return
        end
        teleportTo(savedWaypoint)
    end,
})

--// Player tab
local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local MovementSection = PlayerTab:Section({ Title = 'movement', Side = 'left' })

MovementSection:Toggle({
    Title = 'walkspeed',
    Flag = 'pl_speed_enabled',
    Default = false,
    Callback = function(v)
        Move.SpeedEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.WalkSpeed = DEFAULT_WALKSPEED end
        end
    end,
})

MovementSection:Slider({
    Title = 'walkspeed value',
    Flag = 'pl_walkspeed',
    Min = 16,
    Max = 200,
    Increment = 2,
    Default = 16,
    Callback = function(v) Move.WalkSpeed = v end,
})

MovementSection:Toggle({
    Title = 'jump power',
    Flag = 'pl_jump_enabled',
    Default = false,
    Callback = function(v)
        Move.JumpEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.JumpPower = DEFAULT_JUMPPOWER end
        end
    end,
})

MovementSection:Slider({
    Title = 'jump power value',
    Flag = 'pl_jumppower',
    Min = 50,
    Max = 300,
    Increment = 5,
    Default = 50,
    Callback = function(v) Move.JumpPower = v end,
})

MovementSection:Toggle({
    Title = 'infinite jump',
    Flag = 'pl_infinite_jump',
    Default = false,
    Callback = function(v) Move.InfiniteJump = v end,
})

local UtilitySection = PlayerTab:Section({ Title = 'utility', Side = 'right' })

UtilitySection:Toggle({
    Title = 'noclip',
    Flag = 'pl_noclip',
    Default = false,
    Callback = function(v)
        Move.Noclip = v
        setNoclip(v)
    end,
})

UtilitySection:Toggle({
    Title = 'fly',
    Flag = 'pl_fly',
    Default = false,
    Callback = function(v)
        Move.Fly = v
        if v then startFly() else stopFly() end
    end,
})

UtilitySection:Slider({
    Title = 'fly speed',
    Flag = 'pl_fly_speed',
    Min = 10,
    Max = 300,
    Increment = 5,
    Default = 60,
    Callback = function(v) Move.FlySpeed = v end,
})

UtilitySection:Toggle({
    Title = 'click teleport',
    Flag = 'pl_click_tp',
    Default = false,
    Callback = function(v) Move.ClickTP = v end,
})

UtilitySection:Toggle({
    Title = 'anti afk',
    Flag = 'pl_anti_afk',
    Default = true,
    Callback = function(v) Move.AntiAFK = v end,
})

UtilitySection:Paragraph({
    Title = 'fly controls',
    Text = 'WASD to move, Space to rise, Left Shift to descend, and your camera decides the direction. Fly re-arms itself after respawning.',
})

local TeamSection = PlayerTab:Section({ Title = 'team', Side = 'left' })

for _, teamName in ipairs({ 'Guards', 'Inmates', 'Criminals', 'Neutral' }) do
    TeamSection:Button({
        Title = 'join ' .. teamName:lower(),
        Callback = function()
            if not RequestTeamChange then
                notify('RequestTeamChange remote not found.', 'error')
                return
            end
            local team = Teams:FindFirstChild(teamName)
            if not team then
                notify('Team ' .. teamName .. ' not found.', 'error')
                return
            end
            local ok, result = pcall(function() return RequestTeamChange:InvokeServer(team, 1) end)
            if ok and result then
                notify('Joined ' .. teamName .. '.')
            else
                notify('Team change refused (the game rate-limits this to once every 6s).', 'warning')
            end
        end,
    })
end

--// Gun mods tab
local GunTab = Window:Tab({ Title = 'gun mods', Icon = 'wrench' })
local AmmoSection = GunTab:Section({ Title = 'ammo', Side = 'left' })

AmmoSection:Toggle({
    Title = 'infinite ammo',
    Flag = 'pl_infinite_ammo',
    Default = false,
    Callback = function(v)
        Combat.InfiniteAmmo = v
        applyGunModsNow()
    end,
})

AmmoSection:Toggle({
    Title = 'force auto fire',
    Flag = 'pl_auto_fire',
    Default = false,
    Callback = function(v)
        AutoFireConfig.Enabled = v
        applyGunModsNow()
    end,
})

AmmoSection:Paragraph({
    Title = 'unverified by design',
    Text = 'These write attributes on your own tools. The script that reads them lives inside the gun and cannot be dumped, so whether the server re-validates any given value is unknown. If a stat does nothing, that is the server overruling it, not the toggle failing.',
})

local StatsSection = GunTab:Section({ Title = 'stats', Side = 'right' })

for _, stat in ipairs(GunModStats) do
    StatsSection:Toggle({
        Title = stat.Title,
        Flag = 'pl_gunmod_' .. stat.Key,
        Default = false,
        Callback = function(v)
            GunModConfig[stat.Key].Enabled = v
            applyGunModsNow()
        end,
    })
    StatsSection:Slider({
        Title = stat.Title .. ' value',
        Flag = 'pl_gunmod_val_' .. stat.Key,
        Min = stat.Min,
        Max = stat.Max,
        Increment = stat.Increment,
        Default = stat.Default,
        Suffix = stat.Suffix,
        Callback = function(v)
            GunModConfig[stat.Key].Value = v
            applyGunModsNow()
        end,
    })
end

--// Visual tab
local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Flag = 'pl_esp',
    Default = false,
    Callback = function(v) Visual.Enabled = v end,
})

EspSection:Dropdown({
    Title = 'method',
    Flag = 'pl_esp_method',
    Options = { 'Highlight', 'Box', 'Tracers' },
    Default = 'Highlight',
    Callback = function(v) Visual.Method = v end,
})

EspSection:Toggle({
    Title = 'names',
    Flag = 'pl_esp_names',
    Default = true,
    Callback = function(v) Visual.ShowNames = v end,
})

EspSection:Toggle({
    Title = 'health',
    Flag = 'pl_esp_health',
    Default = true,
    Callback = function(v) Visual.ShowHealth = v end,
})

EspSection:Toggle({
    Title = 'distance',
    Flag = 'pl_esp_distance',
    Default = true,
    Callback = function(v) Visual.ShowDistance = v end,
})

EspSection:Toggle({
    Title = 'team colors',
    Flag = 'pl_esp_team_color',
    Default = true,
    Callback = function(v) Visual.TeamColor = v end,
})

local WorldSection = VisualTab:Section({ Title = 'world', Side = 'right' })

WorldSection:Slider({
    Title = 'esp transparency',
    Flag = 'pl_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) Visual.Transparency = v end,
})

WorldSection:Toggle({
    Title = 'fullbright',
    Flag = 'pl_fullbright',
    Default = false,
    Callback = function(v)
        Visual.Fullbright = v
        applyFullbright(v)
    end,
})

WorldSection:Toggle({
    Title = 'no fog',
    Flag = 'pl_no_fog',
    Default = false,
    Callback = function(v)
        Visual.NoFog = v
        applyNoFog(v)
    end,
})

WorldSection:Paragraph({
    Title = 'team colors',
    Text = 'Blue is Guards, red is Criminals, orange is Inmates. With team colors off everything draws red instead.',
})

--// Settings tab
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local InfoSection = SettingsTab:Section({ Title = 'info', Side = 'left' })

InfoSection:Paragraph({
    Title = 'about',
    Text = 'Built against a live script dump of Prison Life, so the arrest, team change and melee calls are the real signatures the game itself uses. Anything that depends on server-side validation is labelled where it appears.',
})

InfoSection:Label({ Title = 'RightShift toggles the menu' })

local statusLabel = InfoSection:Label({ Title = 'castRay hook: not attempted' })
local remoteLabel = InfoSection:Label({ Title = 'shoot remote: waiting for a shot' })

spawnLoop(function()
    while not Unloading do
        task.wait(1)

        local text
        if not silentAimAPIAvailable then
            text = 'castRay hook: unsupported executor'
        elseif castRayHookFound then
            local count = 0
            for _ in pairs(hookedFunctions) do count = count + 1 end
            -- The count should settle at a small number and stay there. If it
            -- climbs steadily, something is re-hooking and the frame time is
            -- about to go with it.
            text = ('castRay hook: active (%d hooked)'):format(count)
        elseif hookScanStarted then
            text = 'castRay hook: none found - shoot remote covering'
        else
            text = 'castRay hook: not attempted'
        end
        pcall(function() statusLabel:Set(text) end)

        local remoteText
        if not ShootEvent then
            remoteText = 'shoot remote: GunRemotes.ShootEvent not found'
        elseif shootSignature then
            remoteText = 'shoot args: ' .. shootSignature
        else
            remoteText = 'shoot remote: waiting for a shot'
        end
        pcall(function() remoteLabel:Set(remoteText) end)
    end
end)

InfoSection:Paragraph({
    Title = 'if silent aim misses',
    Text = 'Send me the "shoot args" line above. It records the real argument shape of the first shot you fire, which is the one thing the script cannot learn from a dump - the gun code only exists while a gun is held and does not decompile. With that line the redirect stops being generic and becomes exact.',
})

local ControlSection = SettingsTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        pcall(function() RunService:UnbindFromRenderStep(CAMERA_LOCK_BIND) end)

        for plr in pairs(espObjects) do
            destroyEspFor(plr)
        end
        if fovCircle then pcall(function() fovCircle:Remove() end) end

        setNoclip(false)
        stopFly()
        applyFullbright(false)
        applyNoFog(false)

        local hum = getHumanoid()
        if hum then
            hum.WalkSpeed = DEFAULT_WALKSPEED
            hum.JumpPower = DEFAULT_JUMPPOWER
        end

        Centrl:Unload()
    end,
})

ControlSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every hook and loop, clears ESP and drawings, restores lighting and your walkspeed/jump, then closes the menu. The castRay function hook cannot be reversed without rejoining.',
})

Window:Load()

notify('Loaded. RightShift toggles the menu.', 'success', 5)

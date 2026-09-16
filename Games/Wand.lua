--// Wand -- combat, patterns, esp and movement for the wand game.
--
-- The wand's Fire remote takes one CFrame whose *position* is where the
-- projectile spawns and whose *look vector* is the direction it travels. That
-- one fact is the whole engine: every pattern below is just a rule for
-- generating (origin, aim) pairs, and every shot goes through the same fire().

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local Toggles = Library.Toggles
local Options = Library.Options

--// lifecycle ---------------------------------------------------------------

local Unloading = false
local Connections = {}
local Drawings = {}

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function draw(class)
    local ok, object = pcall(function() return Drawing.new(class) end)
    if not ok or not object then return nil end
    Drawings[#Drawings + 1] = object
    return object
end

local HasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"

--// state --------------------------------------------------------------------

local Combat = {
    AutoShoot = false,
    Delay = 0.05,
    Part = "Head",
    Priority = "Distance",
    TeamCheck = true,
    WallCheck = true,
    FovLimit = false,
    FovRadius = 500,
    Range = 500,
    TargetLock = false,
    KillAura = false,
    AuraRange = 30,
    TriggerBot = false,
    TriggerDelay = 0.1,

    -- remote payload constants, exposed because they are the game's numbers
    Speed = 100,
    Size = 1.5,
    Damage = 15,
}

local Predict = {
    Enabled = true,
    Time = 0.165,
    Scale = 1.2,
    Gravity = true,
    Iterations = 2,
}

local Burst = {
    Enabled = false,
    Pattern = "Ring",
    Anchor = "Self",
    Bullets = 12,
    Delay = 0.08,
    Radius = 12,
    Height = 8,
    Layers = 1,
    Spin = 2,
    Spread = 1,
    Chaos = 0,
}

local Esp = {
    Enabled = false,
    Boxes = true,
    Names = true,
    Health = true,
    Distance = true,
    Tracers = false,
    TeamColor = false,
    TeamCheck = true,
    Color = Color3.fromRGB(255, 60, 60),
    Range = 1000,
}

local Visual = {
    FovCircle = false,
    FovColor = Color3.fromRGB(255, 255, 255),
}

local fovCircle

local Move = {
    Speed = false,
    SpeedValue = 16,
    Jump = false,
    JumpValue = 50,
    Gravity = false,
    GravityValue = 196.2,
    Fly = false,
    FlySpeed = 60,
    Noclip = false,
    InfiniteJump = false,
    NoFallDamage = false,
}

local Stats = { shots = 0, bursts = 0 }

local lockedTarget = nil
local selectedPlayer = "None"

local DEFAULT_GRAVITY = Workspace.Gravity

--// helpers ------------------------------------------------------------------

local function alive(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return char ~= nil and hum ~= nil and hum.Health > 0, char, hum
end

local function myRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart"), char
end

local function isTeammate(plr)
    if not plr.Team or not LocalPlayer.Team then return false end
    return plr.Team == LocalPlayer.Team
end

local function sameTeam(plr)
    return Combat.TeamCheck and isTeammate(plr)
end

local function hasForceField(char)
    return char ~= nil and char:FindFirstChildOfClass("ForceField") ~= nil
end

-- The wand is a tool in the character; the remote is a child of it. Both are
-- re-found rather than cached across respawns, but never with a yielding
-- WaitForChild the way the old script did on every single shot.
local function getWand()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    local wand = char:FindFirstChild("Wand")
    if not wand then return nil, nil end
    return wand, wand:FindFirstChild("Fire")
end

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true

-- Replaces the old Ray.new / FindPartOnRayWithIgnoreList pair, which are the
-- legacy API. A hit that belongs to a character does not count as a wall.
local function blocked(from, to, targetChar)
    if not Combat.WallCheck then return false end

    local direction = to - from
    if direction.Magnitude < 0.1 then return false end

    local char = LocalPlayer.Character
    sightParams.FilterDescendantsInstances = { char, targetChar }

    local ok, result = pcall(function()
        return Workspace:Raycast(from, direction, sightParams)
    end)
    if not ok or not result then return false end

    local hit = result.Instance
    if hit and Players:GetPlayerFromCharacter(hit.Parent) then return false end
    return true
end

local function onScreenDistance(position)
    local screen, visible = Camera:WorldToViewportPoint(position)
    if not visible then return nil end
    local centre = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    return (Vector2.new(screen.X, screen.Y) - centre).Magnitude, Vector2.new(screen.X, screen.Y)
end

local PART_NAMES = {
    Head = { "Head", "UpperTorso", "HumanoidRootPart" },
    Torso = { "HumanoidRootPart", "UpperTorso", "Torso" },
}

local function aimPart(char)
    if Combat.Part == "Closest" then
        local origin = Camera.CFrame.Position
        local best, bestDist = nil, math.huge
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") then
                local d = (part.Position - origin).Magnitude
                if d < bestDist then best, bestDist = part, d end
            end
        end
        return best or char:FindFirstChild("HumanoidRootPart")
    end

    for _, name in ipairs(PART_NAMES[Combat.Part] or PART_NAMES.Torso) do
        local part = char:FindFirstChild(name)
        if part then return part end
    end
    return char:FindFirstChild("HumanoidRootPart")
end

local function velocityOf(root)
    local ok, velocity = pcall(function() return root.AssemblyLinearVelocity end)
    if ok and typeof(velocity) == "Vector3" then return velocity end
    return Vector3.zero
end

-- Straight ballistic lead. The old version called
-- :GetPropertyChangedSignal():Wait() in here, which yields forever and hangs
-- whatever called it; there is nothing to wait for, the velocity is readable now.
local function leadPosition(char, part)
    local target = part.Position
    if not Predict.Enabled then return target end

    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return target end

    local velocity = velocityOf(root)
    local origin = Camera.CFrame.Position
    local flight = Predict.Time

    -- Re-solve the flight time against the distance the lead itself produces,
    -- so a target running away is not under-led at range.
    for _ = 1, math.max(1, Predict.Iterations) do
        local guess = target + velocity * flight * Predict.Scale
        if Combat.Speed > 0 then
            flight = Predict.Time + (guess - origin).Magnitude / Combat.Speed
        end
    end

    local lead = target + velocity * flight * Predict.Scale
    if Predict.Gravity and math.abs(velocity.Y) > 1 then
        lead = lead - Vector3.new(0, 0.5 * Workspace.Gravity * flight * flight, 0)
    end
    return lead
end

--// targeting ----------------------------------------------------------------

local function validTarget(plr, range)
    if plr == LocalPlayer then return false end
    if sameTeam(plr) then return false end

    local ok, char = alive(plr)
    if not ok then return false end
    if hasForceField(char) then return false end

    local root = myRoot()
    if not root then return false end

    local part = aimPart(char)
    if not part then return false end

    if (part.Position - root.Position).Magnitude > (range or Combat.Range) then return false end
    if Combat.FovLimit then
        local dist = onScreenDistance(part.Position)
        if not dist or dist > Combat.FovRadius then return false end
    end
    if blocked(root.Position, part.Position, char) then return false end

    return true, char, part
end

local function scoreOf(char, part, root)
    if Combat.Priority == "Health" then
        local hum = char:FindFirstChildOfClass("Humanoid")
        return hum and hum.Health or math.huge
    end
    if Combat.Priority == "Crosshair" then
        return onScreenDistance(part.Position) or math.huge
    end
    return (part.Position - root.Position).Magnitude
end

local function pickTarget(range)
    local root = myRoot()
    if not root then return nil end

    if Combat.TargetLock and lockedTarget then
        local ok, char, part = validTarget(lockedTarget, range)
        if ok then return lockedTarget, char, part end
        lockedTarget = nil
    end

    local best, bestChar, bestPart, bestScore = nil, nil, nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        local ok, char, part = validTarget(plr, range)
        if ok then
            local score = scoreOf(char, part, root)
            if score < bestScore then
                best, bestChar, bestPart, bestScore = plr, char, part, score
            end
        end
    end

    if Combat.TargetLock and best then lockedTarget = best end
    return best, bestChar, bestPart
end

--// firing -------------------------------------------------------------------

local function fire(origin, aim)
    if Unloading then return false end

    local wand, remote = getWand()
    if not wand or not remote then return false end

    local char = LocalPlayer.Character
    if not char then return false end

    if (aim - origin).Magnitude < 0.05 then
        aim = origin + Camera.CFrame.LookVector
    end

    local ok = pcall(function()
        remote:FireServer(CFrame.lookAt(origin, aim), Combat.Speed, Combat.Size, wand, Combat.Damage, char)
    end)
    if ok then Stats.shots = Stats.shots + 1 end
    return ok
end

local function shootAt(char, part)
    local root = myRoot()
    if not root or not part then return false end
    return fire(root.Position, leadPosition(char, part))
end

--// pattern engine -----------------------------------------------------------
--
-- The old script carried twenty-odd tables of near-identical knobs and never
-- read a single one of them. These are the same shapes expressed as functions
-- of (index, count, time) over one shared set of controls, so adding a shape
-- costs a few lines instead of a hundred.

local TAU = math.pi * 2
local BURST_CHUNK = 20

local function jitter(amount)
    if amount <= 0 then return Vector3.zero end
    return Vector3.new(
        (math.random() * 2 - 1) * amount,
        (math.random() * 2 - 1) * amount,
        (math.random() * 2 - 1) * amount
    )
end

local Patterns = {}
local PatternNames = {}

local function pattern(name, solve)
    Patterns[name] = solve
    PatternNames[#PatternNames + 1] = name
end

-- ctx carries the anchor and a basis built from it: centre, look, right, up.
-- Each solver returns the spawn point and the point it travels toward.

pattern("Ring", function(ctx, i, n, cfg)
    local layer = (i - 1) % cfg.Layers
    local step = math.floor((i - 1) / cfg.Layers)
    local angle = (step / math.max(1, n / cfg.Layers)) * TAU + ctx.clock * cfg.Spin
    local radius = cfg.Radius * (1 - layer * 0.18)
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, cfg.Height, math.sin(angle) * radius)
    return origin, ctx.centre
end)

pattern("Rain", function(ctx, i, n, cfg)
    local angle = math.random() * TAU
    local radius = math.sqrt(math.random()) * cfg.Radius
    local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
    local origin = ctx.centre + offset + Vector3.new(0, cfg.Height, 0)
    return origin, ctx.centre + offset * 0.25
end)

pattern("Spiral", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1)
    local angle = t * TAU * cfg.Spread + ctx.clock * cfg.Spin
    local radius = cfg.Radius * t
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, cfg.Height * t, math.sin(angle) * radius)
    return origin, ctx.centre
end)

pattern("Cone", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1)
    local angle = t * TAU * cfg.Spread
    local spread = math.rad(30 * cfg.Spread)
    local radius = math.tan(spread) * cfg.Radius
    local offset = ctx.right * (math.cos(angle) * radius) + ctx.up * (math.sin(angle) * radius)
    local tip = ctx.centre + ctx.look * cfg.Radius
    return ctx.centre + offset * 0.2, tip + offset
end)

pattern("Cylinder", function(ctx, i, n, cfg)
    local perLayer = math.max(1, math.floor(n / cfg.Layers))
    local layer = math.floor((i - 1) / perLayer)
    local step = (i - 1) % perLayer
    local angle = (step / perLayer) * TAU + ctx.clock * cfg.Spin
    -- layers span the full height, so the top ring sits at Height rather than
    -- one layer short of it
    local y = cfg.Layers > 1 and (layer / (cfg.Layers - 1)) * cfg.Height or cfg.Height * 0.5
    local origin = ctx.centre + Vector3.new(math.cos(angle) * cfg.Radius, y, math.sin(angle) * cfg.Radius)
    return origin, ctx.centre + Vector3.new(0, y, 0)
end)

pattern("Shockwave", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n)
    local angle = t * TAU
    local wave = (ctx.clock * cfg.Spin) % 1
    local radius = cfg.Radius * (0.2 + wave * 0.8)
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, 1, math.sin(angle) * radius)
    return origin, origin + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 6
end)

pattern("Tornado", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1)
    local angle = t * TAU * cfg.Spread + ctx.clock * cfg.Spin * 2
    local radius = cfg.Radius * (0.3 + t * 0.7)
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, t * cfg.Height, math.sin(angle) * radius)
    return origin, ctx.centre + Vector3.new(0, t * cfg.Height, 0)
end)

pattern("Nova", function(ctx, i, n, cfg)
    -- even-ish sphere via the golden-angle spiral
    local t = (i - 0.5) / n
    local y = 1 - t * 2
    local r = math.sqrt(math.max(0, 1 - y * y))
    local angle = i * 2.399963 + ctx.clock * cfg.Spin
    local dir = Vector3.new(math.cos(angle) * r, y, math.sin(angle) * r)
    return ctx.centre + dir * (cfg.Radius * 0.25), ctx.centre + dir * cfg.Radius
end)

pattern("Vortex", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1)
    local angle = t * TAU * cfg.Spread - ctx.clock * cfg.Spin
    local radius = cfg.Radius * (1 - t * 0.8)
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, cfg.Height * (1 - t), math.sin(angle) * radius)
    return origin, ctx.centre
end)

pattern("Galaxy", function(ctx, i, n, cfg)
    local arms = math.max(2, math.floor(cfg.Layers + 2))
    local arm = (i - 1) % arms
    local t = math.floor((i - 1) / arms) / math.max(1, n / arms)
    local angle = (arm / arms) * TAU + t * TAU * 0.5 + ctx.clock * cfg.Spin * 0.3
    local radius = cfg.Radius * t
    local origin = ctx.centre + Vector3.new(math.cos(angle) * radius, math.sin(t * math.pi) * cfg.Height * 0.4, math.sin(angle) * radius)
    return origin, ctx.centre
end)

pattern("Meteor", function(ctx, i, n, cfg)
    local angle = math.random() * TAU
    local radius = cfg.Radius * (0.6 + math.random() * 0.6)
    local impact = ctx.centre + Vector3.new(math.cos(angle) * radius * 0.4, 0, math.sin(angle) * radius * 0.4)
    local origin = impact + Vector3.new(math.cos(angle) * radius, cfg.Height * 2, math.sin(angle) * radius)
    return origin, impact
end)

pattern("Helix", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1)
    local strand = ((i - 1) % 2 == 0) and 0 or math.pi
    local angle = t * TAU * cfg.Spread + strand + ctx.clock * cfg.Spin
    local along = ctx.look * (t * cfg.Radius * 2)
    local offset = ctx.right * (math.cos(angle) * cfg.Radius * 0.35)
        + ctx.up * (math.sin(angle) * cfg.Radius * 0.35)
    return ctx.centre + along + offset, ctx.centre + along
end)

pattern("Curtain", function(ctx, i, n, cfg)
    local t = (i - 1) / math.max(1, n - 1) - 0.5
    local offset = ctx.right * (t * cfg.Radius * 2)
    local origin = ctx.centre + offset + Vector3.new(0, cfg.Height, 0) + ctx.look * cfg.Radius
    return origin, ctx.centre + offset + ctx.look * cfg.Radius
end)

pattern("Storm", function(ctx, i, n, cfg)
    local angle = math.random() * TAU
    local radius = math.random() * cfg.Radius
    local origin = ctx.centre
        + Vector3.new(math.cos(angle) * radius, cfg.Height * (0.4 + math.random() * 0.6), math.sin(angle) * radius)
    local aim = ctx.centre + Vector3.new((math.random() * 2 - 1) * cfg.Radius, 0, (math.random() * 2 - 1) * cfg.Radius)
    return origin, aim
end)

local function burstContext()
    local root = myRoot()
    if not root then return nil end

    local look = Camera.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude > 0.01 then flat = flat.Unit else flat = Vector3.new(0, 0, -1) end

    local centre = root.Position
    if Burst.Anchor == "Look ahead" then
        centre = centre + flat * Burst.Radius
    elseif Burst.Anchor == "Target" then
        local _, _, part = pickTarget()
        if part then centre = part.Position end
    end

    local right = flat:Cross(Vector3.yAxis)
    if right.Magnitude < 0.01 then right = Vector3.xAxis else right = right.Unit end

    return {
        centre = centre,
        look = flat,
        right = right,
        up = right:Cross(flat).Unit,
        clock = os.clock(),
    }
end

local function runBurst()
    local solve = Patterns[Burst.Pattern]
    if not solve then return end

    local ctx = burstContext()
    if not ctx then return end

    local count = math.clamp(math.floor(Burst.Bullets), 1, 200)
    local cfg = {
        Radius = Burst.Radius,
        Height = Burst.Height,
        Layers = math.max(1, math.floor(Burst.Layers)),
        Spin = Burst.Spin,
        Spread = math.max(0.05, Burst.Spread),
    }

    for i = 1, count do
        if Unloading or not Burst.Enabled then return end

        local ok, origin, aim = pcall(solve, ctx, i, count, cfg)
        if ok and typeof(origin) == "Vector3" and typeof(aim) == "Vector3" then
            fire(origin + jitter(Burst.Chaos), aim + jitter(Burst.Chaos * 0.5))
        end

        -- a 200 bullet burst is 200 remote calls; firing them all in one frame
        -- stutters the client, so hand the frame back every so often
        if i % BURST_CHUNK == 0 then task.wait() end
    end

    Stats.bursts = Stats.bursts + 1
end

--// loops --------------------------------------------------------------------

task.spawn(function()
    while not Unloading do
        if Combat.AutoShoot then
            pcall(function()
                local _, char, part = pickTarget()
                if char and part then shootAt(char, part) end
            end)
            task.wait(math.max(0, Combat.Delay))
        else
            task.wait(0.1)
        end
    end
end)

task.spawn(function()
    while not Unloading do
        if Combat.KillAura then
            pcall(function()
                local root = myRoot()
                if not root then return end
                for _, plr in ipairs(Players:GetPlayers()) do
                    local ok, char, part = validTarget(plr, Combat.AuraRange)
                    if ok then shootAt(char, part) end
                end
            end)
            task.wait(math.max(0.05, Combat.Delay))
        else
            task.wait(0.15)
        end
    end
end)

task.spawn(function()
    while not Unloading do
        if Burst.Enabled then
            pcall(runBurst)
            task.wait(math.max(0.02, Burst.Delay))
        else
            task.wait(0.1)
        end
    end
end)

-- Trigger bot: fire only while the crosshair is actually over a valid target.
task.spawn(function()
    local armed = false
    while not Unloading do
        if Combat.TriggerBot then
            local ok = pcall(function()
                local origin = Camera.CFrame.Position
                local direction = Camera.CFrame.LookVector * Combat.Range
                sightParams.FilterDescendantsInstances = { LocalPlayer.Character }
                local result = Workspace:Raycast(origin, direction, sightParams)
                local hit = result and result.Instance
                local plr = hit and Players:GetPlayerFromCharacter(hit.Parent)

                if plr and validTarget(plr) then
                    if not armed then
                        armed = true
                        task.wait(Combat.TriggerDelay)
                    end
                    local good, char, part = validTarget(plr)
                    if good then shootAt(char, part) end
                else
                    armed = false
                end
            end)
            if not ok then armed = false end
            task.wait(0.03)
        else
            armed = false
            task.wait(0.15)
        end
    end
end)

--// movement -----------------------------------------------------------------

local flyVelocity, flyGyro

local function stopFly()
    if flyVelocity then flyVelocity:Destroy() flyVelocity = nil end
    if flyGyro then flyGyro:Destroy() flyGyro = nil end
end

local function startFly()
    stopFly()
    local root = myRoot()
    if not root then return end

    flyVelocity = Instance.new("BodyVelocity")
    flyVelocity.MaxForce = Vector3.new(1, 1, 1) * 9e9
    flyVelocity.Velocity = Vector3.zero
    flyVelocity.Parent = root

    flyGyro = Instance.new("BodyGyro")
    flyGyro.MaxTorque = Vector3.new(1, 1, 1) * 9e9
    flyGyro.P = 9e4
    flyGyro.CFrame = Camera.CFrame
    flyGyro.Parent = root
end

track(RunService.Heartbeat:Connect(function()
    if Unloading then return end

    pcall(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")

        if hum then
            if Move.Speed then hum.WalkSpeed = Move.SpeedValue end
            if Move.Jump then
                if hum.UseJumpPower then
                    hum.JumpPower = Move.JumpValue
                else
                    hum.JumpHeight = Move.JumpValue / 10
                end
            end
        end

        if Move.Noclip and char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end

        if Move.Fly then
            if not flyVelocity or not flyVelocity.Parent then startFly() end
            if flyVelocity and flyGyro then
                local direction = Vector3.zero
                local cf = Camera.CFrame
                if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + cf.LookVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - cf.LookVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - cf.RightVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + cf.RightVector end
                if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.yAxis end
                if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then direction = direction - Vector3.yAxis end

                flyVelocity.Velocity = (direction.Magnitude > 0 and direction.Unit or Vector3.zero) * Move.FlySpeed
                flyGyro.CFrame = cf
            end
        elseif flyVelocity then
            stopFly()
        end
    end)
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloading or not Move.InfiniteJump then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

local function hookCharacter(char)
    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    if not hum then return end
    track(hum.StateChanged:Connect(function(_, new)
        if Unloading or not Move.NoFallDamage then return end
        if new == Enum.HumanoidStateType.Freefall then
            hum:ChangeState(Enum.HumanoidStateType.Landed)
        end
    end))
end

if LocalPlayer.Character then task.spawn(hookCharacter, LocalPlayer.Character) end
track(LocalPlayer.CharacterAdded:Connect(function(char)
    stopFly()
    lockedTarget = nil
    task.spawn(hookCharacter, char)
end))

--// esp ----------------------------------------------------------------------

local espPool = {}

local function newEspEntry()
    local entry = {
        box = draw("Square"),
        name = draw("Text"),
        health = draw("Line"),
        healthBack = draw("Line"),
        tracer = draw("Line"),
    }
    if entry.box then
        entry.box.Thickness = 1
        entry.box.Filled = false
        entry.box.Transparency = 1
    end
    if entry.name then
        entry.name.Size = 13
        entry.name.Center = true
        entry.name.Outline = true
        entry.name.Transparency = 1
    end
    for _, key in ipairs({ "health", "healthBack", "tracer" }) do
        if entry[key] then
            entry[key].Thickness = 1
            entry[key].Transparency = 1
        end
    end
    return entry
end

local function hideEntry(entry)
    for _, object in pairs(entry) do
        if object then object.Visible = false end
    end
end

local function espColorFor(plr)
    if Esp.TeamColor and plr.Team then return plr.TeamColor.Color end
    return Esp.Color
end

track(RunService.RenderStepped:Connect(function()
    if Unloading then return end

    if fovCircle then
        fovCircle.Visible = Visual.FovCircle
        if Visual.FovCircle then
            fovCircle.Radius = Combat.FovRadius
            fovCircle.Color = Visual.FovColor
            fovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
        end
    end

    if not Esp.Enabled or not HasDrawing then
        for _, entry in pairs(espPool) do hideEntry(entry) end
        return
    end

    pcall(function()
        local root = myRoot()
        local seen = {}

        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local entry = espPool[plr]
                if not entry then
                    entry = newEspEntry()
                    espPool[plr] = entry
                end
                seen[plr] = true

                local ok, char, hum = alive(plr)
                local skip = not ok or (Esp.TeamCheck and isTeammate(plr))

                local head = char and char:FindFirstChild("Head")
                local torso = char and char:FindFirstChild("HumanoidRootPart")

                if skip or not head or not torso or not root then
                    hideEntry(entry)
                else
                    local distance = (torso.Position - root.Position).Magnitude
                    if distance > Esp.Range then
                        hideEntry(entry)
                    else
                        local topPos, topVisible = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.6, 0))
                        local botPos = Camera:WorldToViewportPoint(torso.Position - Vector3.new(0, 3, 0))

                        if not topVisible then
                            hideEntry(entry)
                        else
                            local height = math.abs(botPos.Y - topPos.Y)
                            local width = height * 0.55
                            local left = topPos.X - width / 2
                            local colour = espColorFor(plr)

                            if entry.box then
                                entry.box.Visible = Esp.Boxes
                                entry.box.Color = colour
                                entry.box.Size = Vector2.new(width, height)
                                entry.box.Position = Vector2.new(left, topPos.Y)
                            end

                            if entry.name then
                                entry.name.Visible = Esp.Names or Esp.Distance
                                entry.name.Color = colour
                                local text = Esp.Names and plr.Name or ""
                                if Esp.Distance then
                                    text = text .. (Esp.Names and " " or "") .. ("[%d]"):format(distance)
                                end
                                entry.name.Text = text
                                entry.name.Position = Vector2.new(topPos.X, topPos.Y - 16)
                            end

                            local ratio = hum and hum.MaxHealth > 0 and (hum.Health / hum.MaxHealth) or 0
                            if entry.healthBack then
                                entry.healthBack.Visible = Esp.Health
                                entry.healthBack.Color = Color3.new(0, 0, 0)
                                entry.healthBack.From = Vector2.new(left - 4, topPos.Y)
                                entry.healthBack.To = Vector2.new(left - 4, topPos.Y + height)
                            end
                            if entry.health then
                                entry.health.Visible = Esp.Health
                                entry.health.Color = Color3.fromRGB(80, 230, 110):Lerp(Color3.fromRGB(230, 70, 70), 1 - ratio)
                                entry.health.From = Vector2.new(left - 4, topPos.Y + height)
                                entry.health.To = Vector2.new(left - 4, topPos.Y + height - height * ratio)
                            end

                            if entry.tracer then
                                entry.tracer.Visible = Esp.Tracers
                                entry.tracer.Color = colour
                                entry.tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                                entry.tracer.To = Vector2.new(topPos.X, topPos.Y + height)
                            end
                        end
                    end
                end
            end
        end

        for plr, entry in pairs(espPool) do
            if not seen[plr] then
                hideEntry(entry)
                espPool[plr] = nil
            end
        end
    end)
end))

--// ui -----------------------------------------------------------------------

local Window = Library:CreateWindow({
    Title = "Wand",
    Footer = "place " .. tostring(game.PlaceId),
    Icon = "wand-sparkles",
    NotifySide = "Right",
    ToggleKeybind = Enum.KeyCode.RightShift,
    ShowCustomCursor = true,
    Size = UDim2.fromOffset(760, 620),
})

local Tabs = {
    Combat = Window:AddTab("Combat", "crosshair"),
    Patterns = Window:AddTab("Patterns", "sparkles"),
    Visuals = Window:AddTab("Visuals", "eye"),
    Player = Window:AddTab("Player", "user"),
    Settings = Window:AddTab("Settings", "settings"),
}

--// combat tab

local AimBox = Tabs.Combat:AddLeftGroupbox("Aim", "crosshair")

AimBox:AddToggle("AutoShoot", {
    Text = "Auto shoot",
    Tooltip = "Fires at the best target on the delay below",
    Default = false,
    Callback = function(v) Combat.AutoShoot = v end,
})

AimBox:AddSlider("ShootDelay", {
    Text = "Shoot delay",
    Default = 0.05,
    Min = 0,
    Max = 1,
    Rounding = 3,
    Suffix = "s",
    Callback = function(v) Combat.Delay = v end,
})

AimBox:AddDropdown("AimPart", {
    Text = "Aim part",
    Values = { "Head", "Torso", "Closest" },
    Default = "Head",
    Callback = function(v) Combat.Part = v end,
})

AimBox:AddDropdown("Priority", {
    Text = "Priority",
    Values = { "Distance", "Crosshair", "Health" },
    Default = "Distance",
    Tooltip = "How the valid targets get ranked",
    Callback = function(v) Combat.Priority = v end,
})

AimBox:AddSlider("Range", {
    Text = "Range",
    Default = 500,
    Min = 50,
    Max = 2000,
    Rounding = 0,
    Suffix = " studs",
    Callback = function(v) Combat.Range = v end,
})

AimBox:AddToggle("TargetLock", {
    Text = "Target lock",
    Tooltip = "Keeps the current target until it stops being valid",
    Default = false,
    Callback = function(v)
        Combat.TargetLock = v
        if not v then lockedTarget = nil end
    end,
})

local FilterBox = Tabs.Combat:AddRightGroupbox("Filters", "filter")

FilterBox:AddToggle("TeamCheck", {
    Text = "Team check",
    Default = true,
    Callback = function(v) Combat.TeamCheck = v end,
})

FilterBox:AddToggle("WallCheck", {
    Text = "Wall check",
    Tooltip = "Needs a clear line from you to the target",
    Default = true,
    Callback = function(v) Combat.WallCheck = v end,
})

FilterBox:AddToggle("FovLimit", {
    Text = "FOV limit",
    Default = false,
    Callback = function(v) Combat.FovLimit = v end,
})

local FovDep = FilterBox:AddDependencyBox()
FovDep:AddSlider("FovRadius", {
    Text = "FOV radius",
    Default = 500,
    Min = 50,
    Max = 1000,
    Rounding = 0,
    Suffix = "px",
    Callback = function(v) Combat.FovRadius = v end,
})
FovDep:SetupDependencies({ { Toggles.FovLimit, true } })

local PredictBox = Tabs.Combat:AddLeftGroupbox("Prediction", "activity")

PredictBox:AddToggle("Predict", {
    Text = "Predict movement",
    Default = true,
    Callback = function(v) Predict.Enabled = v end,
})

local PredictDep = PredictBox:AddDependencyBox()

PredictDep:AddSlider("PredictTime", {
    Text = "Base lead",
    Default = 0.165,
    Min = 0,
    Max = 1,
    Rounding = 3,
    Suffix = "s",
    Tooltip = "Added on top of the distance-based flight time",
    Callback = function(v) Predict.Time = v end,
})

PredictDep:AddSlider("PredictScale", {
    Text = "Lead scale",
    Default = 1.2,
    Min = 0.1,
    Max = 3,
    Rounding = 2,
    Suffix = "x",
    Callback = function(v) Predict.Scale = v end,
})

PredictDep:AddSlider("PredictIterations", {
    Text = "Solve passes",
    Default = 2,
    Min = 1,
    Max = 5,
    Rounding = 0,
    Tooltip = "How many times the flight time re-solves against its own answer",
    Callback = function(v) Predict.Iterations = v end,
})

PredictDep:AddToggle("PredictGravity", {
    Text = "Drop for falling targets",
    Default = true,
    Callback = function(v) Predict.Gravity = v end,
})

PredictDep:SetupDependencies({ { Toggles.Predict, true } })

local ExtraBox = Tabs.Combat:AddRightGroupbox("Extras", "zap")

ExtraBox:AddToggle("KillAura", {
    Text = "Kill aura",
    Tooltip = "Fires at every valid target inside the range below",
    Default = false,
    Callback = function(v) Combat.KillAura = v end,
})

local AuraDep = ExtraBox:AddDependencyBox()
AuraDep:AddSlider("AuraRange", {
    Text = "Aura range",
    Default = 30,
    Min = 5,
    Max = 200,
    Rounding = 0,
    Suffix = " studs",
    Callback = function(v) Combat.AuraRange = v end,
})
AuraDep:SetupDependencies({ { Toggles.KillAura, true } })

ExtraBox:AddToggle("TriggerBot", {
    Text = "Trigger bot",
    Tooltip = "Only fires while your crosshair is already on someone",
    Default = false,
    Callback = function(v) Combat.TriggerBot = v end,
})

local TriggerDep = ExtraBox:AddDependencyBox()
TriggerDep:AddSlider("TriggerDelay", {
    Text = "Trigger delay",
    Default = 100,
    Min = 0,
    Max = 500,
    Rounding = 0,
    Suffix = "ms",
    Callback = function(v) Combat.TriggerDelay = v / 1000 end,
})
TriggerDep:SetupDependencies({ { Toggles.TriggerBot, true } })

local RemoteBox = Tabs.Combat:AddLeftGroupbox("Projectile", "settings-2")
RemoteBox:AddLabel("These are the values the game's own Fire remote takes.", true)

RemoteBox:AddSlider("ProjSpeed", {
    Text = "Speed",
    Default = 100,
    Min = 10,
    Max = 500,
    Rounding = 0,
    Callback = function(v) Combat.Speed = v end,
})

RemoteBox:AddSlider("ProjSize", {
    Text = "Size",
    Default = 1.5,
    Min = 0.1,
    Max = 10,
    Rounding = 2,
    Callback = function(v) Combat.Size = v end,
})

RemoteBox:AddSlider("ProjDamage", {
    Text = "Damage",
    Default = 15,
    Min = 1,
    Max = 100,
    Rounding = 0,
    Callback = function(v) Combat.Damage = v end,
})

--// patterns tab

local BurstBox = Tabs.Patterns:AddLeftGroupbox("Burst", "sparkles")

BurstBox:AddToggle("BurstEnabled", {
    Text = "Enable",
    Default = false,
    Callback = function(v) Burst.Enabled = v end,
})

BurstBox:AddDropdown("BurstPattern", {
    Text = "Pattern",
    Values = PatternNames,
    Default = "Ring",
    Callback = function(v) Burst.Pattern = v end,
})

BurstBox:AddDropdown("BurstAnchor", {
    Text = "Anchor",
    Values = { "Self", "Look ahead", "Target" },
    Default = "Self",
    Tooltip = "Where the shape is built around",
    Callback = function(v) Burst.Anchor = v end,
})

BurstBox:AddSlider("BurstBullets", {
    Text = "Bullets per burst",
    Default = 12,
    Min = 1,
    Max = 200,
    Rounding = 0,
    Callback = function(v) Burst.Bullets = v end,
})

BurstBox:AddSlider("BurstDelay", {
    Text = "Burst delay",
    Default = 0.08,
    Min = 0.02,
    Max = 1,
    Rounding = 3,
    Suffix = "s",
    Callback = function(v) Burst.Delay = v end,
})

local ShapeBox = Tabs.Patterns:AddRightGroupbox("Shape", "shapes")
ShapeBox:AddLabel("One set of controls drives every pattern, so the same numbers mean the same thing whichever you pick.", true)

ShapeBox:AddSlider("BurstRadius", {
    Text = "Radius",
    Default = 12,
    Min = 1,
    Max = 60,
    Rounding = 1,
    Suffix = " studs",
    Callback = function(v) Burst.Radius = v end,
})

ShapeBox:AddSlider("BurstHeight", {
    Text = "Height",
    Default = 8,
    Min = 0,
    Max = 80,
    Rounding = 1,
    Suffix = " studs",
    Callback = function(v) Burst.Height = v end,
})

ShapeBox:AddSlider("BurstLayers", {
    Text = "Layers / arms",
    Default = 1,
    Min = 1,
    Max = 8,
    Rounding = 0,
    Callback = function(v) Burst.Layers = v end,
})

ShapeBox:AddSlider("BurstSpin", {
    Text = "Spin",
    Default = 2,
    Min = 0,
    Max = 10,
    Rounding = 1,
    Tooltip = "How fast the shape rotates over time",
    Callback = function(v) Burst.Spin = v end,
})

ShapeBox:AddSlider("BurstSpread", {
    Text = "Spread / turns",
    Default = 1,
    Min = 0.1,
    Max = 6,
    Rounding = 2,
    Callback = function(v) Burst.Spread = v end,
})

ShapeBox:AddSlider("BurstChaos", {
    Text = "Chaos",
    Default = 0,
    Min = 0,
    Max = 10,
    Rounding = 1,
    Tooltip = "Random offset added to every bullet",
    Callback = function(v) Burst.Chaos = v end,
})

local BurstStatBox = Tabs.Patterns:AddLeftGroupbox("Stats", "chart-line")
local ShotsLabel = BurstStatBox:AddLabel("Shots fired: 0")
local BurstsLabel = BurstStatBox:AddLabel("Bursts: 0")
BurstStatBox:AddButton({
    Text = "Reset counters",
    Func = function()
        Stats.shots = 0
        Stats.bursts = 0
    end,
})

--// visuals tab

local EspBox = Tabs.Visuals:AddLeftGroupbox("ESP", "eye")

if not HasDrawing then
    EspBox:AddLabel("This executor has no Drawing API, so ESP cannot render here.", true)
end

EspBox:AddToggle("EspEnabled", {
    Text = "Enable",
    Default = false,
    Disabled = not HasDrawing,
    Callback = function(v) Esp.Enabled = v end,
})

local EspDep = EspBox:AddDependencyBox()

EspDep:AddToggle("EspBoxes", { Text = "Boxes", Default = true, Callback = function(v) Esp.Boxes = v end })
EspDep:AddToggle("EspNames", { Text = "Names", Default = true, Callback = function(v) Esp.Names = v end })
EspDep:AddToggle("EspHealth", { Text = "Health bars", Default = true, Callback = function(v) Esp.Health = v end })
EspDep:AddToggle("EspDistance", { Text = "Distance", Default = true, Callback = function(v) Esp.Distance = v end })
EspDep:AddToggle("EspTracers", { Text = "Tracers", Default = false, Callback = function(v) Esp.Tracers = v end })
EspDep:AddToggle("EspTeamCheck", { Text = "Hide teammates", Default = true, Callback = function(v) Esp.TeamCheck = v end })
EspDep:AddToggle("EspTeamColor", { Text = "Use team colour", Default = false, Callback = function(v) Esp.TeamColor = v end })

EspDep:AddSlider("EspRange", {
    Text = "Range",
    Default = 1000,
    Min = 50,
    Max = 5000,
    Rounding = 0,
    Suffix = " studs",
    Callback = function(v) Esp.Range = v end,
})

EspDep:AddLabel("Colour"):AddColorPicker("EspColor", {
    Default = Color3.fromRGB(255, 60, 60),
    Callback = function(v) Esp.Color = v end,
})

EspDep:SetupDependencies({ { Toggles.EspEnabled, true } })

local FovBox = Tabs.Visuals:AddRightGroupbox("Crosshair", "circle-dot")

FovBox:AddToggle("FovCircle", {
    Text = "Show FOV circle",
    Default = false,
    Disabled = not HasDrawing,
    Callback = function(v) Visual.FovCircle = v end,
})

FovBox:AddLabel("Circle colour"):AddColorPicker("FovColor", {
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(v) Visual.FovColor = v end,
})

if HasDrawing then
    fovCircle = draw("Circle")
    if fovCircle then
        fovCircle.Thickness = 2
        fovCircle.NumSides = 64
        fovCircle.Filled = false
        fovCircle.Transparency = 1
        fovCircle.Visible = false
    end
end

--// player tab

local MoveBox = Tabs.Player:AddLeftGroupbox("Movement", "footprints")

MoveBox:AddToggle("SpeedToggle", { Text = "Walk speed", Default = false, Callback = function(v)
    Move.Speed = v
    if not v then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = 16 end
    end
end })

local SpeedDep = MoveBox:AddDependencyBox()
SpeedDep:AddSlider("SpeedValue", {
    Text = "Speed", Default = 16, Min = 16, Max = 250, Rounding = 0,
    Callback = function(v) Move.SpeedValue = v end,
})
SpeedDep:SetupDependencies({ { Toggles.SpeedToggle, true } })

MoveBox:AddToggle("JumpToggle", { Text = "Jump power", Default = false, Callback = function(v)
    Move.Jump = v
    if not v then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            if hum.UseJumpPower then hum.JumpPower = 50 else hum.JumpHeight = 7.2 end
        end
    end
end })

local JumpDep = MoveBox:AddDependencyBox()
JumpDep:AddSlider("JumpValue", {
    Text = "Jump power", Default = 50, Min = 50, Max = 400, Rounding = 0,
    Callback = function(v) Move.JumpValue = v end,
})
JumpDep:SetupDependencies({ { Toggles.JumpToggle, true } })

MoveBox:AddToggle("GravityToggle", { Text = "Gravity", Default = false, Callback = function(v)
    Move.Gravity = v
    Workspace.Gravity = v and Move.GravityValue or DEFAULT_GRAVITY
end })

local GravityDep = MoveBox:AddDependencyBox()
GravityDep:AddSlider("GravityValue", {
    Text = "Gravity", Default = 196.2, Min = 0, Max = 400, Rounding = 1,
    Callback = function(v)
        Move.GravityValue = v
        if Move.Gravity then Workspace.Gravity = v end
    end,
})
GravityDep:SetupDependencies({ { Toggles.GravityToggle, true } })

local UtilBox = Tabs.Player:AddRightGroupbox("Utility", "wrench")

UtilBox:AddToggle("Fly", { Text = "Fly", Tooltip = "WASD to move, space up, shift down", Default = false, Callback = function(v)
    Move.Fly = v
    if not v then stopFly() end
end })

local FlyDep = UtilBox:AddDependencyBox()
FlyDep:AddSlider("FlySpeed", {
    Text = "Fly speed", Default = 60, Min = 10, Max = 400, Rounding = 0,
    Callback = function(v) Move.FlySpeed = v end,
})
FlyDep:SetupDependencies({ { Toggles.Fly, true } })

UtilBox:AddToggle("Noclip", { Text = "Noclip", Default = false, Callback = function(v) Move.Noclip = v end })
UtilBox:AddToggle("InfiniteJump", { Text = "Infinite jump", Default = false, Callback = function(v) Move.InfiniteJump = v end })
UtilBox:AddToggle("NoFallDamage", { Text = "No fall damage", Default = false, Callback = function(v) Move.NoFallDamage = v end })

local TeleBox = Tabs.Player:AddLeftGroupbox("Teleport", "map-pin")

local PlayerDropdown = TeleBox:AddDropdown("TeleTarget", {
    Text = "Player",
    Values = { "None" },
    Default = "None",
    Callback = function(v) selectedPlayer = v end,
})

TeleBox:AddButton({
    Text = "Teleport to player",
    Func = function()
        if selectedPlayer == "None" then return end
        local target = Players:FindFirstChild(selectedPlayer)
        local root = myRoot()
        local theirRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
        if root and theirRoot then
            root.CFrame = theirRoot.CFrame + Vector3.new(0, 4, 0)
        else
            Library:Notify({ Title = "Wand", Description = "That player has no character right now.", Time = 3 })
        end
    end,
})

task.spawn(function()
    while not Unloading do
        pcall(function()
            local names = { "None" }
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then names[#names + 1] = plr.Name end
            end
            PlayerDropdown:SetValues(names)
        end)
        task.wait(3)
    end
end)

--// settings tab

local MenuBox = Tabs.Settings:AddLeftGroupbox("Menu", "menu")
MenuBox:AddLabel("Right Shift toggles the menu.", true)

MenuBox:AddLabel("Menu keybind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI = true,
    Text = "Menu keybind",
})

MenuBox:AddButton({
    Text = "Unload",
    Func = function()
        Library:Unload()
    end,
})

-- Handing the picker itself to ToggleKeybind rather than a raw KeyCode is what
-- lets the rebind above actually take effect; the library compares against the
-- picker object when one is set.
Library.ToggleKeybind = Options.MenuKeybind

ThemeManager:SetFolder("WandScript")
SaveManager:SetFolder("WandScript/" .. tostring(game.PlaceId))
SaveManager:SetLibrary(Library)
ThemeManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

--// stat refresh -------------------------------------------------------------

task.spawn(function()
    while not Unloading do
        pcall(function()
            ShotsLabel:SetText("Shots fired: " .. tostring(Stats.shots))
            BurstsLabel:SetText("Bursts: " .. tostring(Stats.bursts))
        end)
        task.wait(0.5)
    end
end)

--// teardown ----------------------------------------------------------------

Library:OnUnload(function()
    Unloading = true

    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end

    stopFly()
    Workspace.Gravity = DEFAULT_GRAVITY

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            hum.WalkSpeed = 16
            if hum.UseJumpPower then hum.JumpPower = 50 else hum.JumpHeight = 7.2 end
        end)
    end

    for _, object in ipairs(Drawings) do
        pcall(function() object:Remove() end)
    end
    table.clear(Drawings)
    table.clear(espPool)
end)

SaveManager:LoadAutoloadConfig()

Library:Notify({
    Title = "Wand",
    Description = "Loaded. Right Shift toggles the menu.",
    Time = 5,
})

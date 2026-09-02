--// Tanks -------------------------------------------------------------------------
-- Built against a script dump of the live game.
--
-- The whole gameplay protocol is one Blink packet. The client reports where it
-- is, where it is aiming, and whether it is shooting:
--
--   Blink.Snapshot.SendRecord.Fire({
--       t = frameTime,      -- tick
--       r = rotation,       -- aim angle, radians
--       x = position.x,     -- client-reported position
--       z = position.z,
--       a = firing,         -- shooting this tick
--       d = distance,       -- aim distance
--   })
--
-- Silent aim is therefore just rewriting `r` on the way out. There is no
-- raycast to hook and no argument order to guess at - the server takes the
-- rotation the client hands it. `r` is built by the game as
-- math.atan2(-dir.x, -dir.z) from a normalised XZ direction, and that exact
-- convention is reproduced below so the value means the same thing.
--
-- Everything is 2D. There is no Y anywhere in the protocol.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle -------------------------------------------------------------------
local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function spawnLoop(fn) return task.spawn(fn) end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Config ----------------------------------------------------------------------
local Aim = {
    Enabled = false,
    TargetPlayers = true,
    TargetFood = true,
    TargetCrates = false,
    Priority = "Closest",
    Predict = true,
    PredictScale = 1,
    RangeCheck = true,
    RangeMode = "Auto",
    ManualRange = 300,
    FOVEnabled = false,
    FOVRadius = 400,
    AutoFire = false,
    ShowTargetLine = true,
}

local Visual = {
    Players = false,
    Food = false,
    Crates = false,
    Chests = false,
    Names = true,
    Distance = true,
    MaxDistance = 2000,
    Transparency = 0.5,
}

local Diag = {
    BlinkHooked = false,
    FormulaRange = nil,
    MeasuredRange = nil,
    Calibrating = false,
    RecordsSeen = 0,
    LastTarget = "none",
}

--// Game paths ------------------------------------------------------------------
local LiveFolder = Workspace:WaitForChild("Live", 20)
local FoodFolder = Workspace:WaitForChild("Food", 20)
local CratesFolder = Workspace:FindFirstChild("Crates")
local ChestsFolder = Workspace:FindFirstChild("Chests")

local function requireIfPresent(parent, name)
    local module = parent and parent:FindFirstChild(name)
    if not module or not module:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, module)
    if ok then return result end
    return nil
end

local DataFolder = ReplicatedStorage:FindFirstChild("Data")
local Formulas = requireIfPresent(DataFolder, "Formulas")
local Cannons = requireIfPresent(DataFolder, "Cannons")

--// Our tank --------------------------------------------------------------------
local function getOwnModel()
    return LiveFolder and LiveFolder:FindFirstChild(LocalPlayer.Name)
end

local function getOwnRoot()
    local model = getOwnModel()
    return model and model:FindFirstChild("HumanoidRootPart")
end

local function isAlive()
    return getOwnRoot() ~= nil
end

--// Range ------------------------------------------------------------------------
-- "Will the bullet actually get there" needs a real number, and there are three
-- ways to get one, in descending order of trustworthiness:
--
--   1. Measured  - watch our own shots and see how far they actually travel.
--   2. Computed  - Data.Formulas gives Lifetime(base, speed) = base*(30/speed)^0.5
--                  and BulletSpeed(base, mult, points) = base*(points*mult+1),
--                  so range is roughly speed * lifetime.
--   3. Manual    - a slider, for when neither of the above is available.
--
-- Whichever is available wins, and the UI says which one is in play rather than
-- quietly presenting a guess as fact.
local function computeFormulaRange()
    if not Formulas or typeof(Formulas) ~= "table" then return nil end
    if typeof(Formulas.Lifetime) ~= "function" or typeof(Formulas.BulletSpeed) ~= "function" then
        return nil
    end

    -- Base numbers from a representative cannon when one can be read, and
    -- otherwise the neutral 1x values the config tables use.
    local baseSpeed, baseLifetime = 1, 3
    if Cannons and typeof(Cannons) == "table" then
        for _, entry in pairs(Cannons) do
            if typeof(entry) == "table" then
                local speed = entry.Speed or (entry.Bullet and entry.Bullet.Speed)
                local life = entry.Lifetime or (entry.Bullet and entry.Bullet.Lifetime)
                if typeof(speed) == "number" and typeof(life) == "number" then
                    baseSpeed, baseLifetime = speed, life
                    break
                end
            end
        end
    end

    local ok, range = pcall(function()
        local speed = Formulas.BulletSpeed(baseSpeed, 0.05, 0)
        local lifetime = Formulas.Lifetime(baseLifetime, math.max(speed, 0.01))
        return speed * lifetime
    end)
    if ok and typeof(range) == "number" and range > 0 and range == range then
        return range
    end
    return nil
end

Diag.FormulaRange = computeFormulaRange()

local function effectiveRange()
    if Aim.RangeMode == "Manual" then return Aim.ManualRange end
    if Diag.MeasuredRange then return Diag.MeasuredRange end
    if Diag.FormulaRange then return Diag.FormulaRange end
    return Aim.ManualRange
end

-- Calibration watches for anything new that appears near our barrel after a
-- shot and follows how far it gets. It is deliberately empirical: whatever the
-- upgrades happen to be, the furthest a bullet actually travels is the honest
-- answer, and it re-runs whenever the build changes.
local function calibrateRange(seconds)
    if Diag.Calibrating then return end
    local root = getOwnRoot()
    if not root then return end

    Diag.Calibrating = true
    spawnLoop(function()
        local origin = root.Position
        local tracked = {}
        local furthest = 0
        local deadline = tick() + (seconds or 6)

        local watchRoots = { Workspace:FindFirstChild("PhysicsObjects"), Workspace:FindFirstChild("Debris") }
        local conns = {}
        for _, folder in ipairs(watchRoots) do
            if folder then
                conns[#conns + 1] = folder.DescendantAdded:Connect(function(inst)
                    if inst:IsA("BasePart") then
                        local rootNow = getOwnRoot()
                        if rootNow and (inst.Position - rootNow.Position).Magnitude < 40 then
                            tracked[inst] = rootNow.Position
                        end
                    end
                end)
            end
        end

        while tick() < deadline and not Unloading do
            for part, from in pairs(tracked) do
                if part.Parent then
                    local travelled = (part.Position - from).Magnitude
                    if travelled > furthest and travelled < 5000 then
                        furthest = travelled
                    end
                else
                    tracked[part] = nil
                end
            end
            PostSimulation:Wait()
        end

        for _, conn in ipairs(conns) do
            pcall(function() conn:Disconnect() end)
        end

        if furthest > 10 then
            Diag.MeasuredRange = furthest
        end
        Diag.Calibrating = false
    end)
end

--// Targets ----------------------------------------------------------------------
local function flatten(position)
    return Vector3.new(position.X, 0, position.Z)
end

-- The game builds its aim angle as atan2(-dir.x, -dir.z) from a normalised XZ
-- direction. Reproducing that exactly is what makes a rewritten `r` mean the
-- same thing to the server as one the client produced itself.
local function angleTo(fromPosition, toPosition)
    local delta = flatten(toPosition) - flatten(fromPosition)
    if delta.Magnitude <= 0.001 then return nil end
    local dir = delta.Unit
    return math.atan2(-dir.X, -dir.Z)
end

local velocityCache = {}

local function velocityOf(part)
    local entry = velocityCache[part]
    local now = os.clock()
    local position = part.Position
    if entry and now > entry.At then
        local dt = now - entry.At
        if dt > 0 then
            entry.Velocity = (position - entry.Position) / dt
        end
        entry.Position = position
        entry.At = now
        return entry.Velocity or Vector3.new()
    end
    velocityCache[part] = { Position = position, At = now, Velocity = Vector3.new() }
    return Vector3.new()
end

local function collectTargets()
    local list = {}
    local root = getOwnRoot()
    if not root then return list end
    local ownModel = getOwnModel()
    local origin = root.Position
    local range = effectiveRange()

    local function consider(part, label, kind, health)
        if not part then return end
        local distance = (flatten(part.Position) - flatten(origin)).Magnitude
        -- The range check is the whole point of asking whether a bullet will
        -- make it: something outside it is not a target, it is a waste of a
        -- reload.
        if Aim.RangeCheck and distance > range then return end
        list[#list + 1] = {
            Part = part, Label = label, Kind = kind,
            Distance = distance, Health = health,
        }
    end

    if Aim.TargetPlayers and LiveFolder then
        for _, model in ipairs(LiveFolder:GetChildren()) do
            if model ~= ownModel then
                local part = model:FindFirstChild("HumanoidRootPart")
                if part then consider(part, model.Name, "Player", nil) end
            end
        end
    end

    if Aim.TargetFood and FoodFolder then
        for _, model in ipairs(FoodFolder:GetChildren()) do
            local part = model:FindFirstChild("Hitbox") or model:FindFirstChildWhichIsA("BasePart")
            if part then consider(part, model.Name, "Food", nil) end
        end
    end

    if Aim.TargetCrates and CratesFolder then
        for _, model in ipairs(CratesFolder:GetChildren()) do
            local part = model:FindFirstChildWhichIsA("BasePart", true)
            if part then consider(part, model.Name, "Crate", nil) end
        end
    end

    return list
end

local function pickTarget()
    local root = getOwnRoot()
    if not root then return nil end

    local candidates = collectTargets()
    if #candidates == 0 then return nil end

    if Aim.FOVEnabled then
        local filtered = {}
        local anchor = UserInputService:GetMouseLocation()
        for _, entry in ipairs(candidates) do
            local screenPos, onScreen = Camera:WorldToViewportPoint(entry.Part.Position)
            if onScreen then
                local gap = (Vector2.new(screenPos.X, screenPos.Y) - anchor).Magnitude
                if gap <= Aim.FOVRadius then
                    entry.ScreenGap = gap
                    filtered[#filtered + 1] = entry
                end
            end
        end
        candidates = filtered
        if #candidates == 0 then return nil end
    end

    local best
    for _, entry in ipairs(candidates) do
        if not best then
            best = entry
        elseif Aim.Priority == "Closest" then
            if entry.Distance < best.Distance then best = entry end
        elseif Aim.Priority == "Players first" then
            local entryScore = entry.Kind == "Player" and 0 or 1
            local bestScore = best.Kind == "Player" and 0 or 1
            if entryScore < bestScore or (entryScore == bestScore and entry.Distance < best.Distance) then
                best = entry
            end
        elseif Aim.Priority == "Food first" then
            local entryScore = entry.Kind == "Food" and 0 or 1
            local bestScore = best.Kind == "Food" and 0 or 1
            if entryScore < bestScore or (entryScore == bestScore and entry.Distance < best.Distance) then
                best = entry
            end
        else
            if entry.Distance < best.Distance then best = entry end
        end
    end

    return best
end

-- Leads the shot so a moving target is aimed at where it will be, not where it
-- is. Bullet speed comes from the same range estimate, so a build with slow
-- shots automatically leads further.
local function aimPointFor(entry, origin)
    local point = entry.Part.Position
    if not Aim.Predict then return point end

    local range = effectiveRange()
    -- Range is speed * lifetime, and lifetime sits around 3s in the configs,
    -- so this recovers a workable speed without needing the exact build.
    local approxSpeed = math.max(range / 3, 1)
    local travelTime = entry.Distance / approxSpeed
    local velocity = velocityOf(entry.Part)
    return point + velocity * travelTime * Aim.PredictScale
end

--// Blink hook -------------------------------------------------------------------
-- The game calls Blink.Snapshot.SendRecord.Fire(record) by indexing the module
-- at call time, so replacing that field is enough - no metamethod hooking, and
-- the game's own cadence and timing are left completely intact.
local Blink = requireIfPresent(ReplicatedStorage:FindFirstChild("Packages"), "Blink")

if Blink and typeof(Blink) == "table" and Blink.Snapshot and Blink.Snapshot.SendRecord then
    local original = Blink.Snapshot.SendRecord.Fire
    if typeof(original) == "function" then
        Blink.Snapshot.SendRecord.Fire = function(record)
            if not Unloading and typeof(record) == "table" then
                Diag.RecordsSeen = Diag.RecordsSeen + 1
                if Aim.Enabled then
                    local root = getOwnRoot()
                    if root then
                        local entry = pickTarget()
                        if entry then
                            local point = aimPointFor(entry, root.Position)
                            local angle = angleTo(root.Position, point)
                            if angle then
                                record.r = angle
                                record.d = entry.Distance
                                Diag.LastTarget = ("%s (%s) %d studs"):format(
                                    entry.Label, entry.Kind, math.floor(entry.Distance))
                                if Aim.AutoFire then record.a = true end
                            end
                        else
                            Diag.LastTarget = "none in range"
                        end
                    end
                end
            end
            return original(record)
        end
        Diag.BlinkHooked = true
    end
end

--// Anti rubber-band ---------------------------------------------------------------
-- The server never moves you. It sends Snapshot.Rejection(x, z, id) and the
-- CLIENT does this to itself:
--
--   root.CFrame = CFrame.new(x, y, z) * rotation
--   root.AssemblyLinearVelocity = Vector3.zero
--   linearVelocity.PlaneVelocity = Vector2.zero
--   forceAccumulator, lastVelocity, lastDirection = zero
--
-- So the snap back is bad twice over: it moves you, and it kills every scrap of
-- momentum you had. Most of those corrections are sub-stud lag noise, and
-- eating a dead stop for half a stud is what makes normal play feel awful.
--
-- Blink's .On assigns a single handler slot rather than appending, so
-- re-registering replaces the game's handler outright and we decide what a
-- correction actually does. The acknowledgement is always sent either way, so
-- from the server's side nothing looks unusual.
local Rubber = {
    Enabled = false,
    Threshold = 6,
    KeepMomentum = true,
    Smooth = true,
    SmoothAlpha = 0.35,

    Seen = 0,
    Ignored = 0,
    LastDistance = 0,
}

local function installRejectionHandler()
    if not (Blink and Blink.Snapshot and Blink.Snapshot.Rejection) then return false end
    if typeof(Blink.Snapshot.Rejection.On) ~= "function" then return false end

    Blink.Snapshot.Rejection.On(function(x, z, id)
        -- Acknowledge first and unconditionally: the server is waiting on this,
        -- and staying silent is the part that would actually look suspicious.
        pcall(function()
            if Blink.Snapshot.AcknowledgeRejection then
                Blink.Snapshot.AcknowledgeRejection.Fire(id, os.clock())
            end
        end)

        local root = getOwnRoot()
        if not root then return end

        local here = root.Position
        local target = Vector3.new(x, here.Y, z)
        local distance = (Vector3.new(here.X, 0, here.Z) - Vector3.new(x, 0, z)).Magnitude

        Rubber.Seen = Rubber.Seen + 1
        Rubber.LastDistance = distance

        if not Rubber.Enabled then
            -- Faithful reproduction of the game's own behaviour.
            root.CFrame = CFrame.new(target) * root.CFrame.Rotation
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            return
        end

        -- Small corrections are lag noise, not the server disagreeing about
        -- where you are. Riding through them is what removes the twitch.
        if distance <= Rubber.Threshold then
            Rubber.Ignored = Rubber.Ignored + 1
            return
        end

        local velocity = root.AssemblyLinearVelocity
        if Rubber.Smooth then
            -- Ease onto the corrected spot instead of snapping, so a real
            -- correction reads as being pushed rather than teleported.
            local blended = here:Lerp(target, math.clamp(Rubber.SmoothAlpha, 0.05, 1))
            root.CFrame = CFrame.new(blended) * root.CFrame.Rotation
        else
            root.CFrame = CFrame.new(target) * root.CFrame.Rotation
        end

        -- Keeping momentum is the half that matters most: the position is the
        -- server's call, but being stopped dead is not required by anything.
        if Rubber.KeepMomentum then
            root.AssemblyLinearVelocity = velocity
        else
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end
    end)

    return true
end

local rejectionHooked = installRejectionHandler()

--// ESP --------------------------------------------------------------------------
local espObjects = {}

local function espColor(kind)
    if kind == "Player" then return Color3.fromRGB(255, 70, 70) end
    if kind == "Food" then return Color3.fromRGB(120, 220, 120) end
    if kind == "Crate" then return Color3.fromRGB(255, 200, 60) end
    return Color3.fromRGB(120, 170, 255)
end

local function destroyEsp(model)
    local objs = espObjects[model]
    if not objs then return end
    if objs.Highlight then objs.Highlight:Destroy() end
    if objs.Billboard then objs.Billboard:Destroy() end
    espObjects[model] = nil
end

local function buildEsp(model, part, label, kind)
    destroyEsp(model)
    local color = espColor(kind)
    local objs = { Kind = kind, Names = Visual.Names }
    espObjects[model] = objs

    local hl = Instance.new("Highlight")
    hl.FillColor = color
    hl.OutlineColor = color
    hl.FillTransparency = Visual.Transparency
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = model
    objs.Highlight = hl

    if Visual.Names then
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "TankEsp"
        billboard.Adornee = part
        billboard.Size = UDim2.fromOffset(190, 30)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.AlwaysOnTop = true
        local text = Instance.new("TextLabel")
        text.BackgroundTransparency = 1
        text.Size = UDim2.fromScale(1, 1)
        text.Font = Enum.Font.GothamBold
        text.TextSize = 13
        text.TextColor3 = color
        text.TextStrokeTransparency = 0.4
        text.Text = label
        text.Parent = billboard
        billboard.Parent = model
        objs.Billboard = billboard
        objs.Label = text
    end
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.4)
        local root = getOwnRoot()
        local seen = {}

        if root then
            local ownModel = getOwnModel()

            local function pass(folder, kind, enabled)
                if not enabled or not folder then return end
                for _, model in ipairs(folder:GetChildren()) do
                    if model ~= ownModel and model:IsA("Model") then
                        local part = model:FindFirstChild("HumanoidRootPart")
                            or model:FindFirstChild("Hitbox")
                            or model:FindFirstChildWhichIsA("BasePart", true)
                        if part then
                            local distance = (part.Position - root.Position).Magnitude
                            if distance <= Visual.MaxDistance then
                                seen[model] = true
                                local objs = espObjects[model]
                                if not objs or objs.Names ~= Visual.Names then
                                    buildEsp(model, part, model.Name, kind)
                                    objs = espObjects[model]
                                end
                                if objs then
                                    if objs.Highlight then
                                        objs.Highlight.FillTransparency = Visual.Transparency
                                    end
                                    if objs.Label then
                                        if Visual.Distance then
                                            objs.Label.Text = ("%s [%d]"):format(model.Name, math.floor(distance))
                                        else
                                            objs.Label.Text = model.Name
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            pass(LiveFolder, "Player", Visual.Players)
            pass(FoodFolder, "Food", Visual.Food)
            pass(CratesFolder, "Crate", Visual.Crates)
            pass(ChestsFolder, "Chest", Visual.Chests)
        end

        for model in pairs(espObjects) do
            if not seen[model] then destroyEsp(model) end
        end
    end
end)

--// Target line -------------------------------------------------------------------
local targetLine
if typeof(Drawing) == "table" then
    pcall(function()
        targetLine = Drawing.new("Line")
        targetLine.Thickness = 1.5
        targetLine.Color = Color3.fromRGB(255, 90, 90)
        targetLine.Visible = false
    end)
end

track(PreRender:Connect(function()
    if not targetLine or Unloading then return end
    if not (Aim.Enabled and Aim.ShowTargetLine) then
        targetLine.Visible = false
        return
    end
    local root = getOwnRoot()
    local entry = root and pickTarget()
    if not entry then
        targetLine.Visible = false
        return
    end
    local fromScreen, fromOn = Camera:WorldToViewportPoint(root.Position)
    local toScreen, toOn = Camera:WorldToViewportPoint(entry.Part.Position)
    if fromOn and toOn then
        targetLine.Visible = true
        targetLine.From = Vector2.new(fromScreen.X, fromScreen.Y)
        targetLine.To = Vector2.new(toScreen.X, toScreen.Y)
    else
        targetLine.Visible = false
    end
end))

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib4.lua'))()

local Window = Centrl:Window({
    Title = 'tanks',
    SubTitle = 'assist',
    Folder = 'TanksAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(90, 200, 255),
})

local function notify(content, kind, duration)
    Centrl:Notify({ Title = 'tanks', Content = content, Type = kind or 'success', Duration = duration or 5 })
end

if not Diag.BlinkHooked then
    notify('Could not hook Blink.Snapshot.SendRecord - silent aim is unavailable. The game may have changed.', 'error', 9)
end

--// Main tab
local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })
local AimSection = MainTab:Section({ Title = 'silent aim', Side = 'left' })

AimSection:Toggle({
    Title = 'silent aim',
    Flag = 'tk_aim',
    Default = false,
    Callback = function(v) Aim.Enabled = v end,
})

AimSection:Toggle({
    Title = 'target players',
    Flag = 'tk_target_players',
    Default = true,
    Callback = function(v) Aim.TargetPlayers = v end,
})

AimSection:Toggle({
    Title = 'target food',
    Flag = 'tk_target_food',
    Default = true,
    Callback = function(v) Aim.TargetFood = v end,
})

AimSection:Toggle({
    Title = 'target crates',
    Flag = 'tk_target_crates',
    Default = false,
    Callback = function(v) Aim.TargetCrates = v end,
})

AimSection:Dropdown({
    Title = 'priority',
    Flag = 'tk_priority',
    Options = { 'Closest', 'Players first', 'Food first' },
    Default = 'Closest',
    Callback = function(v) Aim.Priority = v end,
})

AimSection:Toggle({
    Title = 'auto fire',
    Flag = 'tk_auto_fire',
    Default = false,
    Callback = function(v) Aim.AutoFire = v end,
})

AimSection:Toggle({
    Title = 'draw target line',
    Flag = 'tk_target_line',
    Default = true,
    Callback = function(v) Aim.ShowTargetLine = v end,
})

local RangeSection = MainTab:Section({ Title = 'range & lead', Side = 'right' })

local rangeLabel = RangeSection:Label({ Title = 'range: --' })
local targetLabel = RangeSection:Label({ Title = 'target: none' })

RangeSection:Toggle({
    Title = 'only aim at what bullets reach',
    Flag = 'tk_range_check',
    Default = true,
    Callback = function(v) Aim.RangeCheck = v end,
})

RangeSection:Dropdown({
    Title = 'range source',
    Flag = 'tk_range_mode',
    Options = { 'Auto', 'Manual' },
    Default = 'Auto',
    Callback = function(v) Aim.RangeMode = v end,
})

RangeSection:Slider({
    Title = 'manual range',
    Flag = 'tk_manual_range',
    Min = 50,
    Max = 3000,
    Increment = 25,
    Default = 300,
    Suffix = ' studs',
    Callback = function(v) Aim.ManualRange = v end,
})

RangeSection:Button({
    Title = 'calibrate from your shots',
    Callback = function()
        if not isAlive() then
            notify('Spawn first - calibration watches your own bullets.', 'warning')
            return
        end
        notify('Hold fire for a few seconds while it measures.', 'success', 6)
        calibrateRange(6)
    end,
})

RangeSection:Toggle({
    Title = 'lead moving targets',
    Flag = 'tk_predict',
    Default = true,
    Callback = function(v) Aim.Predict = v end,
})

RangeSection:Slider({
    Title = 'lead strength',
    Flag = 'tk_predict_scale',
    Min = 0,
    Max = 2,
    Increment = 0.05,
    Default = 1,
    Callback = function(v) Aim.PredictScale = v end,
})

local RubberSection = MainTab:Section({ Title = 'anti rubber-band', Side = 'left' })

local rubberLabel = RubberSection:Label({ Title = 'corrections: 0 (0 ignored)' })

RubberSection:Toggle({
    Title = 'stop the snap back',
    Flag = 'tk_rubber',
    Default = false,
    Callback = function(v)
        Rubber.Enabled = v
        if v and not rejectionHooked then
            notify('Could not take over the rejection handler - the game may have changed.', 'error', 8)
        end
    end,
})

RubberSection:Toggle({
    Title = 'keep momentum',
    Flag = 'tk_rubber_momentum',
    Default = true,
    Callback = function(v) Rubber.KeepMomentum = v end,
})

RubberSection:Toggle({
    Title = 'ease instead of snap',
    Flag = 'tk_rubber_smooth',
    Default = true,
    Callback = function(v) Rubber.Smooth = v end,
})

RubberSection:Slider({
    Title = 'ignore corrections under',
    Flag = 'tk_rubber_threshold',
    Min = 0,
    Max = 40,
    Increment = 0.5,
    Default = 6,
    Suffix = ' studs',
    Callback = function(v) Rubber.Threshold = v end,
})

RubberSection:Slider({
    Title = 'ease strength',
    Flag = 'tk_rubber_alpha',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = 0.35,
    Callback = function(v) Rubber.SmoothAlpha = v end,
})

RubberSection:Paragraph({
    Title = 'what this is doing',
    Text = 'The server never moves you - it sends a correction and your own client snaps you to it and zeroes every bit of velocity you had, which is why a half stud of lag costs you a dead stop. This takes over that handler: corrections under the threshold are ridden through, larger ones are eased onto instead of snapped, and your momentum is kept either way. The acknowledgement the server waits for is always sent, so nothing looks unusual from its side.',
})

RubberSection:Paragraph({
    Title = 'tuning it',
    Text = 'Watch the ignored count. If it climbs constantly during ordinary driving the threshold is doing its job. Push it too high and you will drift out of step with where the server thinks you are, which costs you hits rather than winning them - around five or six studs covers normal lag without arguing about real disagreements.',
})

local FovSection = MainTab:Section({ Title = 'fov', Side = 'left' })

FovSection:Toggle({
    Title = 'limit to fov',
    Flag = 'tk_fov',
    Default = false,
    Callback = function(v) Aim.FOVEnabled = v end,
})

FovSection:Slider({
    Title = 'fov radius',
    Flag = 'tk_fov_radius',
    Min = 50,
    Max = 1200,
    Increment = 25,
    Default = 400,
    Suffix = ' px',
    Callback = function(v) Aim.FOVRadius = v end,
})

FovSection:Paragraph({
    Title = 'how the aim works',
    Text = 'The game sends one packet a tick saying where you are, where you are aiming and whether you are firing. Silent aim rewrites only the aim angle on the way out, using the same atan2 form the game builds it with, so the server reads it exactly as if you had aimed there yourself. Nothing else in the packet is touched.',
})

FovSection:Paragraph({
    Title = 'why range matters',
    Text = 'Aiming at something a bullet cannot reach just wastes the shot, so targets past your effective range are skipped. Auto prefers a figure measured from your own shots, falls back to one computed from the game formulas, and finally to the manual slider. Recalibrate after upgrading bullet speed.',
})

--// Visual tab
local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'players',
    Flag = 'tk_esp_players',
    Default = false,
    Callback = function(v) Visual.Players = v end,
})

EspSection:Toggle({
    Title = 'food',
    Flag = 'tk_esp_food',
    Default = false,
    Callback = function(v) Visual.Food = v end,
})

EspSection:Toggle({
    Title = 'crates',
    Flag = 'tk_esp_crates',
    Default = false,
    Callback = function(v) Visual.Crates = v end,
})

EspSection:Toggle({
    Title = 'chests',
    Flag = 'tk_esp_chests',
    Default = false,
    Callback = function(v) Visual.Chests = v end,
})

local EspConfig = VisualTab:Section({ Title = 'esp config', Side = 'right' })

EspConfig:Toggle({
    Title = 'names',
    Flag = 'tk_esp_names',
    Default = true,
    Callback = function(v) Visual.Names = v end,
})

EspConfig:Toggle({
    Title = 'distance',
    Flag = 'tk_esp_distance',
    Default = true,
    Callback = function(v) Visual.Distance = v end,
})

EspConfig:Slider({
    Title = 'transparency',
    Flag = 'tk_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) Visual.Transparency = v end,
})

EspConfig:Slider({
    Title = 'max distance',
    Flag = 'tk_esp_max',
    Min = 200,
    Max = 6000,
    Increment = 100,
    Default = 2000,
    Suffix = ' studs',
    Callback = function(v) Visual.MaxDistance = v end,
})

--// Settings tab
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'left' })

local hookLabel = DiagSection:Label({ Title = 'blink hook: checking' })
local sourceLabel = DiagSection:Label({ Title = 'range source: --' })
local recordLabel = DiagSection:Label({ Title = 'records sent: 0' })

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        pcall(function()
            hookLabel:Set(Diag.BlinkHooked and 'blink hook: active' or 'blink hook: FAILED')

            local source
            if Aim.RangeMode == "Manual" then
                source = ('range source: manual (%d)'):format(Aim.ManualRange)
            elseif Diag.MeasuredRange then
                source = ('range source: measured (%d)'):format(math.floor(Diag.MeasuredRange))
            elseif Diag.FormulaRange then
                source = ('range source: formulas (%d)'):format(math.floor(Diag.FormulaRange))
            else
                source = ('range source: manual fallback (%d)'):format(Aim.ManualRange)
            end
            sourceLabel:Set(source .. (Diag.Calibrating and '  [calibrating]' or ''))

            rangeLabel:Set(('range: %d studs'):format(math.floor(effectiveRange())))
            targetLabel:Set('target: ' .. tostring(Diag.LastTarget))
            recordLabel:Set(('records sent: %d'):format(Diag.RecordsSeen))
            rubberLabel:Set(('corrections: %d (%d ignored, last %.1f studs)')
                :format(Rubber.Seen, Rubber.Ignored, Rubber.LastDistance))
        end)
    end
end)

DiagSection:Paragraph({
    Title = 'records sent',
    Text = 'This should climb steadily while you are alive and moving. If it is stuck at zero the aim packet is not passing through the hook, which means silent aim will do nothing no matter what else is set.',
})

local ControlSection = SettingsTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        for model in pairs(espObjects) do destroyEsp(model) end
        if targetLine then pcall(function() targetLine:Remove() end) end
        Centrl:Unload()
    end,
})

ControlSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects the loops and clears ESP and drawings. The Blink field stays replaced until you rejoin, but it passes records straight through once unloaded.',
})

Window:Load()

notify('Loaded. RightShift toggles the menu.', 'success', 5)

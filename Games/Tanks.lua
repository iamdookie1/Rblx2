--// Tanks -------------------------------------------------------------------------
-- Silent aim, look spoofing, anti rubber-band and ESP, on Ui3.
--
-- Built against a script dump of the live game. The whole gameplay protocol
-- is one Blink packet. Every tick the client reports where it is, where it is
-- aiming and whether it is shooting:
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
-- Silent aim is rewriting `r` (and `d`) on the way out. The server takes the
-- rotation the client hands it, for the shot and for the turret everyone else
-- sees. `r` is math.atan2(-dir.x, -dir.z) of a normalised XZ direction, and
-- that exact convention is reproduced below.
--
-- Because that one angle is also what other players see, a turret that snaps
-- straight onto every target is a giveaway. Look spoofing decides what goes
-- out instead: your real aim while you aren't shooting, a turret that turns at
-- a human speed rather than teleporting, and fire held back until the turret
-- has actually come round onto the target.
--
-- Everything is 2D. There is no Y anywhere in the protocol.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__TanksStop) == "function" then pcall(Genv.__TanksStop) end

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
    Enabled = false,
    TargetPlayers = true,
    TargetFood = true,
    TargetCrates = false,
    Priority = "Closest",        -- Closest / Closest to mouse / Players first / Food first
    Sticky = true,               -- keep the same target while it stays valid
    Predict = true,
    PredictScale = 1,
    RangeCheck = true,
    RangeMode = "Auto",          -- Auto / Manual
    ManualRange = 300,
    FOVEnabled = false,
    FOVRadius = 400,
    ShowFOV = true,
    AutoFire = false,
    ShowTargetLine = true,
}

-- what goes out as your aim angle
local Spoof = {
    Enabled = true,
    OnlyWhileShooting = true,    -- real aim the rest of the time
    HoldAfterShot = 0.25,        -- seconds to stay on target after the trigger lets go
    TurnSpeed = 720,             -- degrees per second the turret may turn, 0 = instant
    WaitUntilAimed = true,       -- hold fire until the turret is on target
    AimedWithin = 4,             -- degrees that count as "on target"
    Jitter = 0,                  -- degrees of random wobble on the aim
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
    PlayerColor = Color3.fromRGB(255, 70, 70),
    FoodColor = Color3.fromRGB(120, 220, 120),
    CrateColor = Color3.fromRGB(255, 200, 60),
    ChestColor = Color3.fromRGB(120, 170, 255),
}

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

local Diag = {
    BlinkHooked = false,
    FormulaRange = nil,
    MeasuredRange = nil,
    Calibrating = false,
    RecordsSeen = 0,
    LastTarget = "none",
    Spoofing = "off",
}

--// game paths --------------------------------------------------------------

local LiveFolder = Workspace:WaitForChild("Live", 20)
local FoodFolder = Workspace:WaitForChild("Food", 20)
local CratesFolder = Workspace:FindFirstChild("Crates")
local ChestsFolder = Workspace:FindFirstChild("Chests")

local function requireIfPresent(parent, name)
    local module = parent and parent:FindFirstChild(name)
    if not module or not module:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, module)
    return ok and result or nil
end

local DataFolder = ReplicatedStorage:FindFirstChild("Data")
local Formulas = requireIfPresent(DataFolder, "Formulas")
local Cannons = requireIfPresent(DataFolder, "Cannons")

local function getOwnModel()
    return LiveFolder and LiveFolder:FindFirstChild(LocalPlayer.Name)
end

local function getOwnRoot()
    local model = getOwnModel()
    return model and model:FindFirstChild("HumanoidRootPart")
end

--// range -------------------------------------------------------------------
-- Whether a bullet will get there needs a real number, best source first:
--   1. Measured - watch our own shots and see how far they actually travel.
--   2. Computed - Data.Formulas: Lifetime(base, speed) = base*(30/speed)^0.5
--      and BulletSpeed(base, mult, points) = base*(points*mult+1), so range
--      is about speed * lifetime.
--   3. Manual   - a slider, when neither is available.

local function computeFormulaRange()
    if type(Formulas) ~= "table" then return nil end
    if type(Formulas.Lifetime) ~= "function" or type(Formulas.BulletSpeed) ~= "function" then return nil end
    local baseSpeed, baseLifetime = 1, 3
    if type(Cannons) == "table" then
        for _, entry in pairs(Cannons) do
            if type(entry) == "table" then
                local speed = entry.Speed or (type(entry.Bullet) == "table" and entry.Bullet.Speed)
                local life = entry.Lifetime or (type(entry.Bullet) == "table" and entry.Bullet.Lifetime)
                if type(speed) == "number" and type(life) == "number" then
                    baseSpeed, baseLifetime = speed, life
                    break
                end
            end
        end
    end
    local ok, range = pcall(function()
        local speed = Formulas.BulletSpeed(baseSpeed, 0.05, 0)
        return speed * Formulas.Lifetime(baseLifetime, math.max(speed, 0.01))
    end)
    if ok and type(range) == "number" and range > 0 and range == range then return range end
    return nil
end

Diag.FormulaRange = computeFormulaRange()

local function effectiveRange()
    if Aim.RangeMode == "Manual" then return Aim.ManualRange end
    return Diag.MeasuredRange or Diag.FormulaRange or Aim.ManualRange
end

-- Follows anything new that appears near our barrel after a shot and records
-- how far it gets: whatever the upgrades are, that is the honest range.
local function calibrateRange(seconds)
    if Diag.Calibrating or not getOwnRoot() then return false end
    Diag.Calibrating = true
    task.spawn(function()
        local tracked, furthest = {}, 0
        local deadline = os.clock() + (seconds or 6)
        local conns = {}
        for _, name in ipairs({ "PhysicsObjects", "Debris" }) do
            local folder = Workspace:FindFirstChild(name)
            if folder then conns[#conns + 1] = folder.DescendantAdded:Connect(function(inst)
                local root = getOwnRoot()
                if inst:IsA("BasePart") and root and (inst.Position - root.Position).Magnitude < 40 then
                    tracked[inst] = root.Position
                end
            end) end
        end
        while os.clock() < deadline and not Unloaded do
            for part, from in pairs(tracked) do
                if part.Parent then
                    local travelled = (part.Position - from).Magnitude
                    if travelled > furthest and travelled < 5000 then furthest = travelled end
                else
                    tracked[part] = nil
                end
            end
            RunService.Heartbeat:Wait()
        end
        for _, conn in ipairs(conns) do pcall(function() conn:Disconnect() end) end
        if furthest > 10 then Diag.MeasuredRange = furthest end
        Diag.Calibrating = false
    end)
    return true
end

--// targets -----------------------------------------------------------------

local function flatten(position)
    return Vector3.new(position.X, 0, position.Z)
end

-- the game's own aim convention, so a rewritten r means the same thing
local function angleTo(fromPosition, toPosition)
    local delta = flatten(toPosition) - flatten(fromPosition)
    if delta.Magnitude <= 0.001 then return nil end
    local dir = delta.Unit
    return math.atan2(-dir.X, -dir.Z)
end

-- shortest signed turn from a to b, in radians
local function angleDelta(a, b)
    local d = (b - a) % (2 * math.pi)
    if d > math.pi then d -= 2 * math.pi end
    return d
end

-- smoothed velocity per part, from how it moved between looks
local Velocity = setmetatable({}, { __mode = "k" })

local function velocityOf(part)
    local now = os.clock()
    local position = part.Position
    local entry = Velocity[part]
    if not entry then
        Velocity[part] = { Position = position, At = now, Value = Vector3.zero }
        return Vector3.zero
    end
    local dt = now - entry.At
    if dt > 1 / 120 then
        local raw = (position - entry.Position) / dt
        entry.Value = entry.Value:Lerp(raw, math.clamp(dt * 10, 0, 1))
        entry.Position, entry.At = position, now
    end
    return entry.Value
end

local function partOf(model)
    return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Hitbox")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function collectTargets(origin)
    local list = {}
    local ownModel = getOwnModel()
    local range = effectiveRange()
    local function consider(model, kind)
        local part = partOf(model)
        if not part then return end
        local distance = (flatten(part.Position) - flatten(origin)).Magnitude
        if Aim.RangeCheck and distance > range then return end
        list[#list + 1] = { Model = model, Part = part, Label = model.Name, Kind = kind, Distance = distance }
    end
    if Aim.TargetPlayers and LiveFolder then
        for _, model in ipairs(LiveFolder:GetChildren()) do
            if model ~= ownModel then consider(model, "Player") end
        end
    end
    if Aim.TargetFood and FoodFolder then
        for _, model in ipairs(FoodFolder:GetChildren()) do consider(model, "Food") end
    end
    if Aim.TargetCrates and CratesFolder then
        for _, model in ipairs(CratesFolder:GetChildren()) do consider(model, "Crate") end
    end
    return list
end

local function screenGap(entry)
    if not Camera then return nil end
    local screen, onScreen = Camera:WorldToViewportPoint(entry.Part.Position)
    if not onScreen then return nil end
    return (Vector2.new(screen.X, screen.Y) - UserInputService:GetMouseLocation()).Magnitude
end

local KIND_FIRST = { ["Players first"] = "Player", ["Food first"] = "Food" }
local Current = nil -- the target being aimed at, kept while sticky

local function pickTarget(origin)
    local candidates = collectTargets(origin)
    if Aim.FOVEnabled or Aim.Priority == "Closest to mouse" then
        local kept = {}
        for _, entry in ipairs(candidates) do
            local gap = screenGap(entry)
            if gap and (not Aim.FOVEnabled or gap <= Aim.FOVRadius) then
                entry.Gap = gap
                kept[#kept + 1] = entry
            elseif not Aim.FOVEnabled then
                entry.Gap = math.huge
                kept[#kept + 1] = entry
            end
        end
        candidates = kept
    end
    if #candidates == 0 then
        Current = nil
        return nil
    end
    if Aim.Sticky and Current then
        for _, entry in ipairs(candidates) do
            if entry.Model == Current then return entry end
        end
    end
    local first = KIND_FIRST[Aim.Priority]
    local best
    for _, entry in ipairs(candidates) do
        if not best then
            best = entry
        elseif Aim.Priority == "Closest to mouse" then
            if entry.Gap < best.Gap then best = entry end
        elseif first then
            local a, b = entry.Kind == first and 0 or 1, best.Kind == first and 0 or 1
            if a < b or (a == b and entry.Distance < best.Distance) then best = entry end
        elseif entry.Distance < best.Distance then
            best = entry
        end
    end
    Current = best.Model
    return best
end

-- Where to aim so the shot meets a moving target: solves for the time a bullet
-- at the estimated speed and the target on its current course arrive at the
-- same point, instead of a one-shot guess.
local function aimPointFor(entry, origin)
    local point = entry.Part.Position
    if not Aim.Predict then return point end
    local speed = math.max(effectiveRange() / 3, 1) -- range is speed x ~3s lifetime
    local velocity = flatten(velocityOf(entry.Part)) * Aim.PredictScale
    local rel = flatten(point) - flatten(origin)
    -- |rel + v t| = speed t  ->  (v.v - s^2) t^2 + 2 (rel.v) t + rel.rel = 0
    local a = velocity:Dot(velocity) - speed * speed
    local b = 2 * rel:Dot(velocity)
    local c = rel:Dot(rel)
    local t
    if math.abs(a) < 1e-6 then
        t = b ~= 0 and -c / b or nil
    else
        local disc = b * b - 4 * a * c
        if disc >= 0 then
            local root = math.sqrt(disc)
            local t1, t2 = (-b - root) / (2 * a), (-b + root) / (2 * a)
            t = (t1 > 0 and t2 > 0) and math.min(t1, t2) or math.max(t1, t2)
        end
    end
    if not t or t <= 0 or t > 5 then t = entry.Distance / speed end
    return point + velocity * t
end

--// blink hook --------------------------------------------------------------
-- The game calls Blink.Snapshot.SendRecord.Fire(record) by indexing the module
-- each time, so replacing that field is enough: no metamethod hooking, and the
-- game's own cadence is untouched. The original is kept across re-runs so a
-- second copy never wraps the first.

local Blink = requireIfPresent(ReplicatedStorage:FindFirstChild("Packages"), "Blink")
local SendRecord = type(Blink) == "table" and type(Blink.Snapshot) == "table" and Blink.Snapshot.SendRecord or nil
local OriginalFire = Genv.__TanksOriginalFire or (SendRecord and SendRecord.Fire)

local Out = { Angle = nil, At = os.clock(), LastShot = -math.huge, Returning = false, WasOn = false }

local function decide(record)
    local now = os.clock()
    local dt = math.clamp(now - Out.At, 0, 0.25)
    Out.At = now
    local realAngle = type(record.r) == "number" and record.r or nil
    if not realAngle then return end
    if record.a then Out.LastShot = now end

    local wanted, entry = nil, nil
    if Aim.Enabled then
        local root = getOwnRoot()
        entry = root and pickTarget(root.Position)
        if entry then
            local point = aimPointFor(entry, root.Position)
            wanted = angleTo(root.Position, point)
            Diag.LastTarget = ("%s (%s) %d studs"):format(entry.Label, entry.Kind, math.floor(entry.Distance))
        else
            Diag.LastTarget = "none in range"
        end
    end

    if not Spoof.Enabled then
        Out.Angle = wanted or realAngle
        if wanted then
            record.r = wanted
            record.d = entry.Distance
            if Aim.AutoFire then record.a = true end
        end
        Diag.Spoofing = "off"
        return
    end

    -- whether the aim should be on the target this tick
    local shooting = record.a or Aim.AutoFire
    local recentShot = now - Out.LastShot <= Spoof.HoldAfterShot
    local onTarget = wanted ~= nil and (not Spoof.OnlyWhileShooting or shooting or recentShot)
    local goal = onTarget and wanted or realAngle
    if onTarget and Spoof.Jitter > 0 then
        goal += math.rad((math.random() * 2 - 1) * Spoof.Jitter)
    end

    -- coming off a target the turret swings back at the turn speed; otherwise
    -- it follows your own aim exactly, so your manual shots never lag
    if Out.WasOn and not onTarget then Out.Returning = true end
    if onTarget or (record.a and not onTarget) then Out.Returning = false end
    Out.WasOn = onTarget
    local sent = Out.Angle or realAngle
    if not onTarget and not Out.Returning then
        sent = goal
    elseif Spoof.TurnSpeed > 0 then
        local maxStep = math.rad(Spoof.TurnSpeed) * math.max(dt, 1 / 60)
        local step = angleDelta(sent, goal)
        sent += math.clamp(step, -maxStep, maxStep)
    else
        sent = goal
    end
    if Out.Returning and math.abs(math.deg(angleDelta(sent, realAngle))) <= Spoof.AimedWithin then
        Out.Returning = false
        sent = realAngle
    end
    Out.Angle = sent
    record.r = sent
    if onTarget then record.d = entry.Distance end

    if onTarget then
        local aimed = math.abs(math.deg(angleDelta(sent, wanted))) <= Spoof.AimedWithin
        if Aim.AutoFire then record.a = true end
        -- fire only once the turret really points at it, so no shot ever
        -- leaves sideways from a turret everyone can see
        if Spoof.WaitUntilAimed and record.a and not aimed then record.a = false end
        Diag.Spoofing = aimed and "on target" or "turning"
    else
        Diag.Spoofing = "your aim"
    end
end

if SendRecord and type(OriginalFire) == "function" then
    Genv.__TanksOriginalFire = OriginalFire
    SendRecord.Fire = function(record)
        if not Unloaded and type(record) == "table" then
            Diag.RecordsSeen += 1
            pcall(decide, record)
        end
        return OriginalFire(record)
    end
    Diag.BlinkHooked = true
end

--// anti rubber-band --------------------------------------------------------
-- The server never moves you. It sends Snapshot.Rejection(x, z, id) and the
-- client snaps itself there and zeroes its velocity. Most corrections are
-- sub-stud lag noise, and a dead stop for half a stud is what makes normal
-- play feel awful. Blink's .On assigns a single handler slot, so registering
-- replaces the game's handler; the acknowledgement is always sent either way.

local function installRejectionHandler()
    local rejection = type(Blink) == "table" and type(Blink.Snapshot) == "table" and Blink.Snapshot.Rejection
    if not rejection or type(rejection.On) ~= "function" then return false end
    rejection.On(function(x, z, id)
        pcall(function()
            if Blink.Snapshot.AcknowledgeRejection then
                Blink.Snapshot.AcknowledgeRejection.Fire(id, os.clock())
            end
        end)
        local root = getOwnRoot()
        if not root then return end
        local here = root.Position
        local target = Vector3.new(x, here.Y, z)
        local distance = (flatten(here) - Vector3.new(x, 0, z)).Magnitude
        Rubber.Seen += 1
        Rubber.LastDistance = distance
        if Unloaded or not Rubber.Enabled then
            -- the game's own behaviour
            root.CFrame = CFrame.new(target) * root.CFrame.Rotation
            root.AssemblyLinearVelocity = Vector3.zero
            return
        end
        if distance <= Rubber.Threshold then
            Rubber.Ignored += 1
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local place = Rubber.Smooth and here:Lerp(target, math.clamp(Rubber.SmoothAlpha, 0.05, 1)) or target
        root.CFrame = CFrame.new(place) * root.CFrame.Rotation
        root.AssemblyLinearVelocity = Rubber.KeepMomentum and velocity or Vector3.zero
    end)
    return true
end

local RejectionHooked = installRejectionHandler()

--// esp ---------------------------------------------------------------------

local EspObjects = {}

local function espColor(kind)
    if kind == "Player" then return Visual.PlayerColor end
    if kind == "Food" then return Visual.FoodColor end
    if kind == "Crate" then return Visual.CrateColor end
    return Visual.ChestColor
end

local function destroyEsp(model)
    local objs = EspObjects[model]
    if not objs then return end
    if objs.Highlight then pcall(function() objs.Highlight:Destroy() end) end
    if objs.Billboard then pcall(function() objs.Billboard:Destroy() end) end
    EspObjects[model] = nil
end

local function buildEsp(model, part, kind)
    destroyEsp(model)
    local objs = { Kind = kind }
    EspObjects[model] = objs
    local hl = Instance.new("Highlight")
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.OutlineTransparency = 0
    hl.Parent = model
    objs.Highlight = hl
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
    text.TextStrokeTransparency = 0.4
    text.Parent = billboard
    billboard.Parent = model
    objs.Billboard, objs.Label = billboard, text
end

task.spawn(function()
    while not Unloaded do
        task.wait(0.3)
        pcall(function()
            local root = getOwnRoot()
            local seen = {}
            if root then
                local ownModel = getOwnModel()
                local function pass(folder, kind, enabled)
                    if not enabled or not folder then return end
                    for _, model in ipairs(folder:GetChildren()) do
                        if model ~= ownModel and model:IsA("Model") then
                            local part = partOf(model)
                            local distance = part and (part.Position - root.Position).Magnitude
                            if distance and distance <= Visual.MaxDistance then
                                seen[model] = true
                                local objs = EspObjects[model]
                                if not objs then
                                    buildEsp(model, part, kind)
                                    objs = EspObjects[model]
                                end
                                local color = espColor(kind)
                                objs.Highlight.FillColor = color
                                objs.Highlight.OutlineColor = color
                                objs.Highlight.FillTransparency = Visual.Transparency
                                objs.Label.TextColor3 = color
                                objs.Billboard.Enabled = Visual.Names or Visual.Distance
                                local name = Visual.Names and model.Name or ""
                                local dist = Visual.Distance and ("[%d]"):format(math.floor(distance)) or ""
                                objs.Label.Text = (name .. " " .. dist):gsub("^%s+", "")
                            end
                        end
                    end
                end
                pass(LiveFolder, "Player", Visual.Players)
                pass(FoodFolder, "Food", Visual.Food)
                pass(CratesFolder, "Crate", Visual.Crates)
                pass(ChestsFolder, "Chest", Visual.Chests)
            end
            for model in pairs(EspObjects) do
                if not seen[model] then destroyEsp(model) end
            end
        end)
    end
end)

--// target line and fov circle ------------------------------------------------

local Draw = {}
if typeof(Drawing) == "table" or typeof(Drawing) == "userdata" then
    pcall(function()
        Draw.Line = Drawing.new("Line")
        Draw.Line.Thickness = 1.5
        Draw.Line.Color = Color3.fromRGB(255, 90, 90)
        Draw.Line.Visible = false
        Draw.Circle = Drawing.new("Circle")
        Draw.Circle.Thickness = 1
        Draw.Circle.NumSides = 64
        Draw.Circle.Filled = false
        Draw.Circle.Color = Color3.fromRGB(255, 255, 255)
        Draw.Circle.Transparency = 0.6
        Draw.Circle.Visible = false
    end)
end

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    pcall(function()
        if Draw.Circle then
            Draw.Circle.Visible = Aim.Enabled and Aim.FOVEnabled and Aim.ShowFOV
            Draw.Circle.Radius = Aim.FOVRadius
            Draw.Circle.Position = UserInputService:GetMouseLocation()
        end
        if not Draw.Line then return end
        local root = getOwnRoot()
        local model = Aim.Enabled and Aim.ShowTargetLine and Current
        local part = model and model.Parent and partOf(model)
        if not (root and part and Camera) then
            Draw.Line.Visible = false
            return
        end
        local from, fromOn = Camera:WorldToViewportPoint(root.Position)
        local to, toOn = Camera:WorldToViewportPoint(part.Position)
        Draw.Line.Visible = fromOn and toOn
        Draw.Line.From = Vector2.new(from.X, from.Y)
        Draw.Line.To = Vector2.new(to.X, to.Y)
    end)
end))

--// teardown ----------------------------------------------------------------

local Library

local function unload()
    if Unloaded then return end
    Unloaded = true
    Aim.Enabled = false
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    -- hand the packet back to the game untouched
    if SendRecord and type(OriginalFire) == "function" then
        pcall(function() SendRecord.Fire = OriginalFire end)
    end
    for model in pairs(EspObjects) do destroyEsp(model) end
    for _, drawing in pairs(Draw) do pcall(function() drawing:Remove() end) end
end

Genv.__TanksStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Tanks',
    Footer = 'assist',
    Icon = 'crosshair',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ocean',
    ConfigFolder = 'Tanks',
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
    pcall(function() Library:Notify({ Title = 'Tanks', Description = text, Time = 6, Icon = icon or 'bell' }) end)
end

if not Diag.BlinkHooked then
    notify('Could not hook Blink.Snapshot.SendRecord, silent aim is unavailable. The game may have changed.', 'circle-x')
end

do
    local Tab = Window:AddTab('Aim', 'crosshair', 'Silent aim and look spoofing')

    local overview = Tab:AddBigGroupbox('Status', 'gauge')
    local status = overview:AddLabel('target: none', true)
    every(0.2, function()
        status:SetText(("target: %s\naim out: %s   range: %d studs   packet hook: %s"):format(
            tostring(Diag.LastTarget), Diag.Spoofing, math.floor(effectiveRange()),
            Diag.BlinkHooked and "on" or "FAILED"))
    end)

    local aim = Tab:AddLeftGroupbox('Silent aim', 'crosshair')

    aim:AddToggle('tk_aim', {
        Text = 'Silent aim',
        Tooltip = 'rewrites the aim angle the game sends, so shots go at the target whatever your mouse is on',
        Default = false,
        Callback = function(v) Aim.Enabled = v end,
    }):AddKeyPicker('tk_aim_key', {
        Default = 'None',
        Mode = 'Toggle',
        SyncToggleState = true,
        Text = 'Silent aim',
    })

    aim:AddToggle('tk_target_players', { Text = 'Target players', Default = true, Callback = function(v) Aim.TargetPlayers = v end })
    aim:AddToggle('tk_target_food', { Text = 'Target food', Default = true, Callback = function(v) Aim.TargetFood = v end })
    aim:AddToggle('tk_target_crates', { Text = 'Target crates', Default = false, Callback = function(v) Aim.TargetCrates = v end })

    aim:AddDropdown('tk_priority', {
        Text = 'Priority',
        Values = { 'Closest', 'Closest to mouse', 'Players first', 'Food first' },
        Default = Aim.Priority,
        Callback = function(v) Aim.Priority = v or "Closest" end,
    })

    aim:AddToggle('tk_sticky', {
        Text = 'Stick to target',
        Tooltip = 'keeps the same target while it stays in range, instead of hopping to whatever is closest each tick',
        Default = Aim.Sticky,
        Callback = function(v) Aim.Sticky = v end,
    })

    aim:AddToggle('tk_autofire', {
        Text = 'Auto fire',
        Tooltip = 'shoots whenever there is a target',
        Default = false,
        Callback = function(v) Aim.AutoFire = v end,
    })

    aim:AddToggle('tk_line', { Text = 'Target line', Default = true, Callback = function(v) Aim.ShowTargetLine = v end })

    local spoof = Tab:AddRightGroupbox('Look spoof', 'eye-off')

    spoof:AddLabel('Your aim angle is also what everyone else sees your turret do. This keeps it looking like a person aiming.', true)

    spoof:AddToggle('tk_spoof', {
        Text = 'Spoof where you look',
        Default = Spoof.Enabled,
        Callback = function(v) Spoof.Enabled = v end,
    })

    spoof:AddToggle('tk_spoof_shooting', {
        Text = 'Only aim while shooting',
        Tooltip = 'your real aim goes out the rest of the time, so the turret only swings onto targets when you fire',
        Default = Spoof.OnlyWhileShooting,
        Callback = function(v) Spoof.OnlyWhileShooting = v end,
    })

    spoof:AddSlider('tk_spoof_hold', {
        Text = 'Stay on target after a shot',
        Min = 0, Max = 2, Default = Spoof.HoldAfterShot, Rounding = 2, Suffix = 's',
        Callback = function(v) Spoof.HoldAfterShot = v end,
    })

    spoof:AddSlider('tk_spoof_turn', {
        Text = 'Turret turn speed',
        Tooltip = 'how fast the turret may turn, in degrees a second. 0 snaps instantly',
        Min = 0, Max = 2000, Default = Spoof.TurnSpeed, Rounding = 0, Suffix = ' deg/s',
        Callback = function(v) Spoof.TurnSpeed = v end,
    })

    spoof:AddToggle('tk_spoof_wait', {
        Text = 'Hold fire until aimed',
        Tooltip = 'a shot only goes out once the turret has turned onto the target, so nothing fires sideways',
        Default = Spoof.WaitUntilAimed,
        Callback = function(v) Spoof.WaitUntilAimed = v end,
    })

    spoof:AddSlider('tk_spoof_within', {
        Text = 'On target within',
        Min = 0.5, Max = 20, Default = Spoof.AimedWithin, Rounding = 1, Suffix = ' deg',
        Callback = function(v) Spoof.AimedWithin = v end,
    })

    spoof:AddSlider('tk_spoof_jitter', {
        Text = 'Aim wobble',
        Tooltip = 'a little random error on the aim, like a hand on a mouse. keep it small or shots miss',
        Min = 0, Max = 10, Default = Spoof.Jitter, Rounding = 1, Suffix = ' deg',
        Callback = function(v) Spoof.Jitter = v end,
    })

    local range = Tab:AddLeftGroupbox('Range and lead', 'ruler')

    range:AddToggle('tk_range_check', {
        Text = 'Only aim at what shots reach',
        Default = Aim.RangeCheck,
        Callback = function(v) Aim.RangeCheck = v end,
    })

    range:AddDropdown('tk_range_mode', {
        Text = 'Range from',
        Tooltip = 'auto: measured from your shots, else the game\'s formulas, else the manual value',
        Values = { 'Auto', 'Manual' },
        Default = Aim.RangeMode,
        Callback = function(v) Aim.RangeMode = v or "Auto" end,
    })

    range:AddSlider('tk_manual_range', {
        Text = 'Manual range',
        Min = 50, Max = 3000, Default = Aim.ManualRange, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Aim.ManualRange = v end,
    })

    range:AddButton({
        Text = 'Measure range from shots',
        Func = function()
            if calibrateRange(6) then
                notify('Fire for a few seconds while it measures.', 'ruler')
            else
                notify('Spawn first: it measures your own bullets.', 'triangle-alert')
            end
        end,
    })

    range:AddToggle('tk_predict', {
        Text = 'Lead moving targets',
        Default = Aim.Predict,
        Callback = function(v) Aim.Predict = v end,
    })

    range:AddSlider('tk_predict_scale', {
        Text = 'Lead strength',
        Min = 0, Max = 2, Default = Aim.PredictScale, Rounding = 2, Suffix = 'x',
        Callback = function(v) Aim.PredictScale = v end,
    })

    local fov = Tab:AddRightGroupbox('FOV', 'circle-dashed')

    fov:AddToggle('tk_fov', {
        Text = 'Only targets near the mouse',
        Default = Aim.FOVEnabled,
        Callback = function(v) Aim.FOVEnabled = v end,
    })

    fov:AddSlider('tk_fov_radius', {
        Text = 'FOV radius',
        Min = 50, Max = 1200, Default = Aim.FOVRadius, Rounding = 0, Suffix = ' px',
        Callback = function(v) Aim.FOVRadius = v end,
    })

    fov:AddToggle('tk_fov_show', {
        Text = 'Show FOV circle',
        Default = Aim.ShowFOV,
        Callback = function(v) Aim.ShowFOV = v end,
    })
end

do
    local Tab = Window:AddTab('Movement', 'move', 'Anti rubber-band')
    local box = Tab:AddLeftGroupbox('Anti rubber-band', 'magnet')

    local counts = box:AddLabel('corrections: 0', true)
    every(0.5, function()
        counts:SetText(("corrections: %d (%d ignored, last %.1f studs)"):format(Rubber.Seen, Rubber.Ignored, Rubber.LastDistance))
    end)

    box:AddToggle('tk_rubber', {
        Text = 'Stop the snap back',
        Tooltip = 'small corrections are ridden through, bigger ones eased onto, momentum kept. the server still gets its acknowledgement',
        Default = false,
        Callback = function(v)
            Rubber.Enabled = v
            if v and not RejectionHooked then notify('Could not take over the correction handler. The game may have changed.', 'circle-x') end
        end,
    })

    box:AddToggle('tk_rubber_momentum', { Text = 'Keep momentum', Default = Rubber.KeepMomentum, Callback = function(v) Rubber.KeepMomentum = v end })
    box:AddToggle('tk_rubber_smooth', { Text = 'Ease instead of snap', Default = Rubber.Smooth, Callback = function(v) Rubber.Smooth = v end })

    box:AddSlider('tk_rubber_threshold', {
        Text = 'Ignore corrections under',
        Tooltip = 'around 5-6 studs covers normal lag. too high and you drift out of step with the server',
        Min = 0, Max = 40, Default = Rubber.Threshold, Rounding = 1, Suffix = ' studs',
        Callback = function(v) Rubber.Threshold = v end,
    })

    box:AddSlider('tk_rubber_alpha', {
        Text = 'Ease strength',
        Min = 0.05, Max = 1, Default = Rubber.SmoothAlpha, Rounding = 2,
        Callback = function(v) Rubber.SmoothAlpha = v end,
    })
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'ESP')
    local esp = Tab:AddLeftGroupbox('ESP', 'scan-eye')

    esp:AddToggle('tk_esp_players', { Text = 'Players', Default = false, Callback = function(v) Visual.Players = v end })
        :AddColorPicker('tk_esp_players_color', { Default = Visual.PlayerColor, Title = 'Players', Callback = function(c) Visual.PlayerColor = c end })
    esp:AddToggle('tk_esp_food', { Text = 'Food', Default = false, Callback = function(v) Visual.Food = v end })
        :AddColorPicker('tk_esp_food_color', { Default = Visual.FoodColor, Title = 'Food', Callback = function(c) Visual.FoodColor = c end })
    esp:AddToggle('tk_esp_crates', { Text = 'Crates', Default = false, Callback = function(v) Visual.Crates = v end })
        :AddColorPicker('tk_esp_crates_color', { Default = Visual.CrateColor, Title = 'Crates', Callback = function(c) Visual.CrateColor = c end })
    esp:AddToggle('tk_esp_chests', { Text = 'Chests', Default = false, Callback = function(v) Visual.Chests = v end })
        :AddColorPicker('tk_esp_chests_color', { Default = Visual.ChestColor, Title = 'Chests', Callback = function(c) Visual.ChestColor = c end })

    local config = Tab:AddRightGroupbox('ESP look', 'settings-2')
    config:AddToggle('tk_esp_names', { Text = 'Names', Default = Visual.Names, Callback = function(v) Visual.Names = v end })
    config:AddToggle('tk_esp_distance', { Text = 'Distance', Default = Visual.Distance, Callback = function(v) Visual.Distance = v end })
    config:AddSlider('tk_esp_transparency', {
        Text = 'Fill transparency',
        Min = 0, Max = 1, Default = Visual.Transparency, Rounding = 2,
        Callback = function(v) Visual.Transparency = v end,
    })
    config:AddSlider('tk_esp_max', {
        Text = 'Max distance',
        Min = 200, Max = 6000, Default = Visual.MaxDistance, Rounding = 0, Suffix = ' studs',
        Callback = function(v) Visual.MaxDistance = v end,
    })
end

do
    local Tab = Window:AddTab('Info', 'info', 'Diagnostics')
    local box = Tab:AddLeftGroupbox('Diagnostics', 'activity')
    local info = box:AddLabel('-', true)
    every(0.5, function()
        local source
        if Aim.RangeMode == "Manual" then
            source = ("manual (%d)"):format(Aim.ManualRange)
        elseif Diag.MeasuredRange then
            source = ("measured (%d)"):format(math.floor(Diag.MeasuredRange))
        elseif Diag.FormulaRange then
            source = ("formulas (%d)"):format(math.floor(Diag.FormulaRange))
        else
            source = ("manual fallback (%d)"):format(Aim.ManualRange)
        end
        info:SetText(("packet hook: %s\ncorrection handler: %s\npackets sent: %d\nrange from: %s%s"):format(
            Diag.BlinkHooked and "on" or "FAILED", RejectionHooked and "on" or "not found",
            Diag.RecordsSeen, source, Diag.Calibrating and " (measuring)" or ""))
    end)
    box:AddLabel('Packets sent should climb steadily while you are alive. If it stays at 0, the aim packet is not passing through the hook and silent aim does nothing.', true)
end

notify('Loaded. Right Shift toggles the menu.', 'check')

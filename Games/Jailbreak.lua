--// Jailbreak ----------------------------------------------------------------
-- Built against a Dumper v6 dump of place 606849621 (version 1584). The game's
-- own client modules do the heavy lifting where they can, so the features
-- below use the same calls the game makes rather than guessing:
--
--   Vehicle.VehicleUtils             GetLocalVehiclePacket(), nitroState
--   Module.AlexChassis               reads packet.EngineSpeedMult / Height /
--                                    TurnSpeed / GarageBrakes every frame
--   Game.ItemSystem.BulletEmitter    Emit(origin, direction, speed) fires every
--                                    bullet; hits are found on the client
--   Game.ItemSystem.ItemSystem       GetEquipped(player)
--   Game.Item.Item                   ProjectMouseLocationToWorld: where a held
--                                    gun points and what it replicates
--   Game.ItemConfig.*                gun configs (CamShakeMagnitude, BulletSpread)
--   Module.UI .CircleAction          the "hold E" prompt list (Specs) that loot,
--                                    hacks, glass, cash drops and doors all use
--   Robbery.RobberyConsts            robbery ids and names; ReplicatedStorage.
--                                    RobberyState holds each one's status
--
-- The server can still check speed, teleports, hold timers and fire rate, so
-- those options are marked Risky in the menu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local genv = (getgenv and getgenv()) or _G

-- Running the script twice would stack hooks and loops, so the old copy
-- unloads itself first.
if type(genv.JailbreakHubUnload) == "function" then
    pcall(genv.JailbreakHubUnload)
end

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle ------------------------------------------------------------------
local Connections = {}
local Cleanups = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function onCleanup(fn)
    Cleanups[#Cleanups + 1] = fn
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

--// UI library (Ui3) -------------------------------------------------------------
-- raw.githubusercontent.com caches by path and ignores query strings, so the
-- current commit sha is resolved first to dodge a stale copy of the branch.
local function loadLibrary()
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and type(sha) == "string" then
        ref = sha
    end
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/" .. ref .. "/Ui.lua"))()
end

local Library = loadLibrary()
local Toggles = Library.Toggles
local Options = Library.Options

local function on(index)
    local toggle = Toggles[index]
    return toggle ~= nil and toggle.Value == true
end

local function opt(index, default)
    local option = Options[index]
    if option == nil or option.Value == nil then
        return default
    end
    return option.Value
end

local function notify(title, description, time)
    pcall(function()
        Library:Notify({ Title = title, Description = description or "", Time = time or 3 })
    end)
end

--// Game modules -----------------------------------------------------------------
local function findPath(root, path)
    local current = root
    for name in string.gmatch(path, "[^%.]+") do
        if not current then return nil end
        current = current:FindFirstChild(name)
    end
    return current
end

local function waitPath(root, path, timeout)
    local current = root
    for name in string.gmatch(path, "[^%.]+") do
        if not current then return nil end
        current = current:FindFirstChild(name) or current:WaitForChild(name, timeout)
    end
    return current
end

local function gameModule(path)
    local module = waitPath(ReplicatedStorage, path, 10)
    if not module or not module:IsA("ModuleScript") then
        warn("[Jailbreak] missing module " .. path)
        return nil
    end
    local ok, result = pcall(require, module)
    if ok then
        return result
    end
    warn("[Jailbreak] require " .. path .. " failed: " .. tostring(result))
    return nil
end

local VehicleUtils = gameModule("Vehicle.VehicleUtils")
local ItemSystem = gameModule("Game.ItemSystem.ItemSystem")
local BulletEmitter = gameModule("Game.ItemSystem.BulletEmitter")
local ItemBase = gameModule("Game.Item.Item")
local GameUI = gameModule("Module.UI")
local CircleAction = GameUI and GameUI.CircleAction
local RobberyConsts = gameModule("Robbery.RobberyConsts")

local Controls
task.spawn(function()
    local ok, result = pcall(function()
        local playerScripts = LocalPlayer:WaitForChild("PlayerScripts", 10)
        return require(playerScripts:WaitForChild("PlayerModule", 10)):GetControls()
    end)
    if ok then Controls = result end
end)

--// Character / team helpers -----------------------------------------------------
local function getHumanoid(character)
    character = character or LocalPlayer.Character
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRoot(character)
    character = character or LocalPlayer.Character
    return character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
end

local function teamName(player)
    local team = player.Team
    return team and team.Name or "None"
end

local function isEnemy(player)
    local mine, theirs = teamName(LocalPlayer), teamName(player)
    if mine == "Police" then
        if theirs == "Criminal" then return true end
        return theirs == "Prisoner" and on("AimPrisoners")
    end
    return theirs == "Police"
end

--// Vehicle helpers ----------------------------------------------------------------
-- Jailbreak seats are plain Parts with a PlayerName StringValue, not Seat
-- instances, so Humanoid.SeatPart is never set. The game's own packet is used
-- first; scanning the Vehicles folder is only a fallback.
local function findVehicleBySeat()
    local folder = Workspace:FindFirstChild("Vehicles")
    if not folder then return nil end
    for _, model in ipairs(folder:GetChildren()) do
        for _, child in ipairs(model:GetChildren()) do
            if child.Name == "Seat" or child.Name == "Passenger" then
                local playerName = child:FindFirstChild("PlayerName")
                if playerName and playerName.Value == LocalPlayer.Name then
                    return model, child.Name == "Passenger"
                end
            end
        end
    end
    return nil
end

-- Returns model, packet (may be nil), isDriver. Several loops ask every
-- frame, so the answer is reused for a few milliseconds.
local VehicleCache = { At = -1 }

local function lookupVehicle()
    if VehicleUtils and type(VehicleUtils.GetLocalVehiclePacket) == "function" then
        local ok, packet = pcall(VehicleUtils.GetLocalVehiclePacket)
        if ok and type(packet) == "table" and typeof(packet.Model) == "Instance" and packet.Model:IsDescendantOf(Workspace) then
            return packet.Model, packet, not packet.Passenger
        end
        if ok then
            return nil
        end
    end
    local model, passenger = findVehicleBySeat()
    if model then
        return model, nil, not passenger
    end
    return nil
end

local function getVehicle()
    local now = os.clock()
    if now - VehicleCache.At > 0.01 then
        VehicleCache.At = now
        VehicleCache.Model, VehicleCache.Packet, VehicleCache.Driver = lookupVehicle()
    end
    return VehicleCache.Model, VehicleCache.Packet, VehicleCache.Driver
end

local function getVehicleRoot(model)
    return model.PrimaryPart or model:FindFirstChild("Engine") or model:FindFirstChild("Seat")
end

--// Overlay (FOV circle, tracers, ESP, mobile buttons) ------------------------------
local function guiParent()
    if gethui then
        local ok, result = pcall(gethui)
        if ok and result then return result end
    end
    local ok, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if ok and coreGui then
        local test = pcall(function()
            local probe = Instance.new("Folder")
            probe.Parent = coreGui
            probe:Destroy()
        end)
        if test then return coreGui end
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local Overlay = Instance.new("ScreenGui")
Overlay.Name = HttpService:GenerateGUID(false)
Overlay.IgnoreGuiInset = true
Overlay.ResetOnSpawn = false
Overlay.DisplayOrder = 50
Overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Overlay.Parent = guiParent()

local EspFolder = Instance.new("Folder")
EspFolder.Name = "Esp"
EspFolder.Parent = Overlay

onCleanup(function()
    Overlay:Destroy()
end)

local function newLine()
    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.Parent = Overlay
    return frame
end

local function drawLine(frame, from, to, color, thickness)
    local delta = to - from
    frame.Size = UDim2.fromOffset(delta.Magnitude, thickness)
    frame.Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2)
    frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
    frame.BackgroundColor3 = color
    frame.Visible = true
end

local function viewportSize()
    return Camera and Camera.ViewportSize or Vector2.new(1280, 720)
end

--// Input (keyboard, thumbstick, mobile buttons) ------------------------------------
local MobileHold = { Up = false, Down = false, Forward = false, Back = false }

local function keyDown(key)
    return UserInputService:IsKeyDown(key)
end

-- Forward, right and up in -1..1. Uses the control module's move vector (which
-- covers keyboard and the touch thumbstick), then plain keys if that's zero
-- (Jailbreak takes over input in vehicles), then the on-screen buttons.
local function getMoveInput()
    local forward, right, up = 0, 0, 0
    if Controls then
        local ok, move = pcall(function() return Controls:GetMoveVector() end)
        if ok and typeof(move) == "Vector3" then
            right += move.X
            forward -= move.Z
        end
    end
    if not UserInputService:GetFocusedTextBox() then
        if forward == 0 and right == 0 then
            if keyDown(Enum.KeyCode.W) then forward += 1 end
            if keyDown(Enum.KeyCode.S) then forward -= 1 end
            if keyDown(Enum.KeyCode.D) then right += 1 end
            if keyDown(Enum.KeyCode.A) then right -= 1 end
        end
        if keyDown(Enum.KeyCode.E) or keyDown(Enum.KeyCode.Space) then up += 1 end
        if keyDown(Enum.KeyCode.Q) or keyDown(Enum.KeyCode.LeftControl) then up -= 1 end
    end
    if MobileHold.Forward then forward += 1 end
    if MobileHold.Back then forward -= 1 end
    if MobileHold.Up then up += 1 end
    if MobileHold.Down then up -= 1 end
    return math.clamp(forward, -1, 1), math.clamp(right, -1, 1), math.clamp(up, -1, 1)
end

local function flyVelocity(speed, verticalSpeed)
    local forward, right, up = getMoveInput()
    local cf = Camera.CFrame
    local direction = cf.LookVector * forward + cf.RightVector * right
    if direction.Magnitude > 1 then
        direction = direction.Unit
    end
    return direction * speed + Vector3.new(0, up * (verticalSpeed or speed), 0)
end

--// Teleport / travel -----------------------------------------------------------
local Travel = { Token = 0, Active = false, Label = "idle", Remaining = 0, Speed = 0, Following = false }

-- What moves: your vehicle if you're driving one, otherwise your character.
local function getMover()
    local model, _, isDriver = getVehicle()
    if model then
        if not isDriver then
            return nil, "You're a passenger. Only the driver can move the car."
        end
        if not on("TPUseVehicle") then
            return nil, "You're in a vehicle. Turn on \"Use vehicle\" or get out first."
        end
        local root = getVehicleRoot(model)
        if root then
            return { Root = root, Model = model, Vehicle = true }
        end
        return nil, "Couldn't find your vehicle's root part."
    end
    local root = getRoot()
    if root then
        return { Root = root, Model = LocalPlayer.Character, Vehicle = false }
    end
    return nil, "No character."
end

-- Moving the assembly root moves everything welded to it, so this carries the
-- whole car (and you in it), or your whole character. Velocity is set to the
-- travel velocity rather than zero so the motion reads as smooth movement
-- instead of a string of jumps.
local function placeMover(mover, position, velocity, facing)
    local root = mover.Root
    local rotation = root.CFrame - root.Position
    if facing and on("TPFaceDirection") then
        local flat = Vector3.new(facing.X, 0, facing.Z)
        if flat.Magnitude > 0.1 then
            local wanted = CFrame.lookAt(Vector3.zero, flat.Unit)
            rotation = rotation:Lerp(wanted, 0.2)
        end
    end
    root.CFrame = CFrame.new(position) * rotation
    root.AssemblyLinearVelocity = velocity or Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function stopTravel()
    Travel.Token += 1
    Travel.Active = false
    Travel.Following = false
    Travel.Label = "idle"
    Travel.Speed = 0
    Travel.Remaining = 0
end

local TravelRayParams = RaycastParams.new()
TravelRayParams.FilterType = Enum.RaycastFilterType.Exclude
pcall(function() TravelRayParams.RespectCanCollide = true end)

local function refreshTravelIgnore(mover)
    local ignore = { Overlay }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    if mover and mover.Model then table.insert(ignore, mover.Model) end
    TravelRayParams.FilterDescendantsInstances = ignore
end

local function groundHeight(position)
    local hit = Workspace:Raycast(position + Vector3.new(0, 300, 0), Vector3.new(0, -1200, 0), TravelRayParams)
    return hit and hit.Position.Y or nil
end

local function noclipCharacter()
    local character = LocalPlayer.Character
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            part.CanCollide = false
        end
    end
end

-- target: a Vector3, or a function returning one (players, moving robberies).
-- options.Follow keeps you on a moving target until you press Stop.
--
-- Routes:
--   Sky     straight up, across at altitude, straight down
--   Ground  hugs the terrain a few studs up, looking ahead for slopes
--   Direct  a straight line
-- Speed ramps up by the acceleration setting and, with Smooth on, brakes so
-- you arrive at a crawl instead of slamming into the spot.
local function travelTo(target, label, options)
    options = options or {}
    local mover, reason = getMover()
    if not mover then
        notify("Teleport", reason, 4)
        return
    end

    local resolve = type(target) == "function" and target or function() return target end
    local first = resolve()
    if typeof(first) ~= "Vector3" then
        notify("Teleport", "That destination isn't available right now.", 3)
        return
    end

    Travel.Token += 1
    local token = Travel.Token
    Travel.Active = true
    Travel.Following = options.Follow == true
    Travel.Label = label or "destination"
    Travel.Speed = 0

    task.spawn(function()
        local arrived = false

        if opt("TPMode", "Tween") == "Instant" and not options.Follow then
            placeMover(mover, first)
            arrived = true
        else
            local route = opt("TPRoute", "Sky")
            local start = mover.Root.Position
            local altitude = math.max(start.Y, first.Y) + opt("TPSkyHeight", 150)
            local phase = route == "Sky" and 1 or 2
            local speed = 0

            while Travel.Token == token and not Unloading do
                local dt = PreSimulation:Wait()
                if Travel.Token ~= token or Unloading then break end

                mover = getMover()
                if not mover then break end
                local humanoid = getHumanoid()
                if humanoid and humanoid.Health <= 0 then break end
                local goal = resolve()
                if typeof(goal) ~= "Vector3" then break end

                refreshTravelIgnore(mover)
                local position = mover.Root.Position
                local flat = Vector3.new(goal.X - position.X, 0, goal.Z - position.Z)
                local maxSpeed = mover.Vehicle and opt("TPVehicleSpeed", 350) or opt("TPSpeed", 120)
                local waypoint

                if phase == 1 then
                    -- A moving target can pull the cruise altitude up.
                    altitude = math.max(altitude, goal.Y + 20)
                    if position.Y >= altitude - 2 or flat.Magnitude < 10 then
                        phase = 2
                    else
                        waypoint = Vector3.new(position.X, altitude, position.Z)
                    end
                end
                if phase == 2 then
                    if route == "Sky" then
                        if flat.Magnitude < 4 then
                            phase = 3
                        else
                            waypoint = Vector3.new(goal.X, altitude, goal.Z)
                        end
                    elseif route == "Ground" then
                        if flat.Magnitude < 25 then
                            phase = 3
                        else
                            local ahead = position + flat.Unit * math.min(flat.Magnitude, 40)
                            local hover = opt("TPGroundHeight", 6)
                            local groundHere = groundHeight(position) or position.Y - hover
                            local groundAhead = groundHeight(ahead) or groundHere
                            local y = math.max(groundHere, groundAhead) + hover
                            waypoint = Vector3.new(goal.X, y, goal.Z)
                            -- Stay level and only change height toward y,
                            -- otherwise the far-off goal height would drag us
                            -- through hills.
                            waypoint = position + flat.Unit * math.min(flat.Magnitude, 60) + Vector3.new(0, y - position.Y, 0)
                        end
                    else
                        phase = 3
                    end
                end
                if phase == 3 then
                    waypoint = goal
                end

                local delta = waypoint - position
                local remaining = (goal - position).Magnitude
                if phase == 1 then
                    remaining = (waypoint - position).Magnitude + (Vector3.new(goal.X, altitude, goal.Z) - waypoint).Magnitude + math.abs(altitude - goal.Y)
                elseif phase == 2 and route == "Sky" then
                    remaining = flat.Magnitude + math.abs(altitude - goal.Y)
                end
                Travel.Remaining = remaining

                local accel = opt("TPAccel", 250)
                speed = math.min(maxSpeed, speed + accel * dt)
                if on("TPSmooth") then
                    speed = math.min(speed, math.max(12, math.sqrt(2 * accel * remaining)))
                end
                Travel.Speed = speed

                local step = speed * dt
                if phase == 3 and delta.Magnitude <= math.max(step, 0.5) then
                    local carry = Vector3.zero
                    if options.Follow and options.Velocity then
                        carry = options.Velocity() or Vector3.zero
                    end
                    placeMover(mover, goal, carry)
                    if not mover.Vehicle then noclipCharacter() end
                    if not options.Follow then
                        arrived = true
                        break
                    end
                    speed = math.min(speed, 40)
                else
                    local direction = delta.Magnitude > 0.001 and delta.Unit or Vector3.zero
                    local nextPosition = delta.Magnitude <= step and waypoint or position + direction * step
                    placeMover(mover, nextPosition, direction * speed, flat.Magnitude > 2 and flat or nil)
                    if not mover.Vehicle then noclipCharacter() end
                end
            end
        end

        -- Hold still for a moment so physics doesn't bounce you off the spot.
        if arrived and Travel.Token == token then
            local settleUntil = os.clock() + 0.3
            while os.clock() < settleUntil and Travel.Token == token and not Unloading do
                local current = getMover()
                if not current then break end
                current.Root.AssemblyLinearVelocity = Vector3.zero
                current.Root.AssemblyAngularVelocity = Vector3.zero
                PreSimulation:Wait()
            end
        end

        if Travel.Token == token then
            Travel.Active = false
            Travel.Following = false
            Travel.Label = "idle"
            Travel.Speed = 0
            Travel.Remaining = 0
        end
    end)
end

local function travelStatusText()
    if not Travel.Active then return "Status: idle" end
    if Travel.Following then
        return ("Status: following %s"):format(Travel.Label)
    end
    local eta = Travel.Speed > 1 and Travel.Remaining / Travel.Speed or 0
    return ("Status: %s - %d studs, %.1fs"):format(Travel.Label, Travel.Remaining, eta)
end

local function instancePosition(instance)
    if not instance then return nil end
    if instance:IsA("BasePart") then
        return instance.Position, instance.Size
    end
    if instance:IsA("Attachment") then
        return instance.WorldPosition, nil
    end
    if instance:IsA("Model") then
        local ok, cf, size = pcall(instance.GetBoundingBox, instance)
        if ok then return cf.Position, size end
    end
    return nil
end

-- Drops a ray from above the spot and lands on whatever is there, so you
-- don't arrive inside a wall or under the map.
local function landingPoint(position, size)
    local height = size and size.Y or 0
    local top = position + Vector3.new(0, height / 2 + 15, 0)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { Overlay }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local vehicle = getVehicle()
    if vehicle then table.insert(ignore, vehicle) end
    params.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(top, Vector3.new(0, -(height + 400), 0), params)
    local lift = vehicle and 7 or 4
    if hit then
        return hit.Position + Vector3.new(0, lift, 0)
    end
    return top
end

local LOCATIONS = {
    { Name = "Prison", Paths = { "Map.Prison", "MaxSecurity", "Interior_Cells" } },
    { Name = "Police Station", Paths = { "PoliceStation" } },
    { Name = "Police HQ", Paths = { "PoliceHQ" } },
    { Name = "Military Base", Paths = { "MilitaryBase", "MilitaryIsland" } },
    { Name = "Criminal Base", Paths = { "SecretBaseCriminal" } },
    { Name = "Police Secret Base", Paths = { "SecretBasePolice" } },
    { Name = "Gun Shop", Paths = { "GunShop1" } },
    { Name = "Glider Shop", Paths = { "GliderShop" } },
    { Name = "Pet Store", Paths = { "PetStore" } },
    { Name = "Donut Shop", Paths = { "DonutShop" } },
    { Name = "Gas Station", Paths = { "GasBuilding", "RetroGasStation" } },
    { Name = "Crown City", Paths = { "CrownCity" } },
    { Name = "Pirate Cove", Paths = { "PirateCove" } },
    { Name = "Airport", Paths = { "AirportCrates" } },
    { Name = "Train Station", Paths = { "StartStation", "Station" } },
    { Name = "Trade Ship", Paths = { "TradeShip" } },
    { Name = "Mansion (outside)", Paths = { "TheManor" } },
}

local LocationNames = {}
for _, location in ipairs(LOCATIONS) do
    table.insert(LocationNames, location.Name)
end

local function locationPosition(name)
    for _, location in ipairs(LOCATIONS) do
        if location.Name == name then
            for _, path in ipairs(location.Paths) do
                local position, size = instancePosition(findPath(Workspace, path))
                if position then
                    return landingPoint(position, size)
                end
            end
        end
    end
    return nil
end

--// Robberies ------------------------------------------------------------------
local FALLBACK_ROBBERIES = {
    { "BANK", "Bank", "Bank" }, { "JEWELRY", "Jewelry Store", "Jewelry" }, { "MUSEUM", "Museum", "Museum" },
    { "POWER_PLANT", "Power Plant", "PowerPlant" }, { "TRAIN_PASSENGER", "Passenger Train", "TrainPassenger" },
    { "TRAIN_CARGO", "Cargo Train", "TrainCargo" }, { "CARGO_SHIP", "Cargo Ship", "CargoShip" },
    { "CARGO_PLANE", "Cargo Plane", "CargoPlane" }, { "STORE_GAS", "Gas Station", "Gas" },
    { "STORE_DONUT", "Donut Store", "Donut" }, { "STORE_GROCERY", "Grocery Store", "Grocery" },
    { "MONEY_TRUCK", "Money Truck", "MoneyTruck" }, { "HOME_VAULT", "Home Vault", "HomeVault" },
    { "TOMB", "Tomb", "Tomb" }, { "CROWN_JEWEL", "Crown Jewel", "Casino" }, { "MANSION", "Mansion", "Mansion" },
    { "OIL_RIG", "Oil Rig", "OilRig" },
}

-- Robberies that aren't findable by their world marker fall back to these.
local ROBBERY_PATHS = {
    BANK = { "Banks.Bank" },
    JEWELRY = { "Jewelrys.Jewelry" },
    MUSEUM = { "Museum" },
    POWER_PLANT = { "PowerPlant" },
    CROWN_JEWEL = { "Casino" },
    TOMB = { "RobberyTomb" },
    MANSION = { "MansionRobbery" },
    OIL_RIG = { "OilRig" },
    STORE_GAS = { "GasBuilding", "Interior_GasStation" },
    STORE_DONUT = { "Interior_Donut", "Donut" },
}

local Robberies = {}
do
    local ok = pcall(function()
        assert(RobberyConsts)
        for _, key in ipairs(RobberyConsts.LIST_ROBBERY) do
            local id = RobberyConsts.ENUM_ROBBERY[key]
            local data = RobberyConsts.DATA_ROBBERY[id]
            if key ~= "HOME_VAULT" then
                table.insert(Robberies, { Id = id, Key = key, Name = data.name, Marker = data.markerName })
            end
        end
    end)
    if not ok or #Robberies == 0 then
        table.clear(Robberies)
        for index, entry in ipairs(FALLBACK_ROBBERIES) do
            if entry[1] ~= "HOME_VAULT" then
                table.insert(Robberies, { Id = index, Key = entry[1], Name = entry[2], Marker = entry[3] })
            end
        end
    end
end

local STATUS = { OPENED = 1, STARTED = 2, CLOSED = 3 }
pcall(function()
    STATUS.OPENED = RobberyConsts.ENUM_STATUS.OPENED
    STATUS.STARTED = RobberyConsts.ENUM_STATUS.STARTED
    STATUS.CLOSED = RobberyConsts.ENUM_STATUS.CLOSED
end)

local RobberyNames = {}
for _, robbery in ipairs(Robberies) do
    table.insert(RobberyNames, robbery.Name)
end

local function robberyStatus(robbery)
    local folder = ReplicatedStorage:FindFirstChild("RobberyState")
    local value = folder and folder:FindFirstChild(tostring(robbery.Id))
    return value and value.Value or nil
end

local function statusText(status)
    if status == STATUS.OPENED then return "open" end
    if status == STATUS.STARTED then return "in progress" end
    if status == STATUS.CLOSED then return "closed" end
    return "not loaded"
end

local function robberyMarker(robbery)
    if not robbery.Marker then return nil end
    for _, marker in ipairs(CollectionService:GetTagged("RobberyMarker")) do
        if marker.Name == robbery.Marker and marker:IsDescendantOf(Workspace) then
            return marker
        end
    end
    return nil
end

local function robberyInstance(robbery)
    if robbery.Key == "MONEY_TRUCK" then
        local ref = findPath(Workspace, "RobberyFolder.MoneyTruck.VehicleModel")
        if ref and ref.Value then return ref.Value end
    end
    local marker = robberyMarker(robbery)
    if marker then return marker end
    for _, path in ipairs(ROBBERY_PATHS[robbery.Key] or {}) do
        local instance = findPath(Workspace, path)
        if instance then return instance end
    end
    return nil
end

local function robberyByName(name)
    for _, robbery in ipairs(Robberies) do
        if robbery.Name == name then return robbery end
    end
    return nil
end

--// Waypoints (saved per executor) -------------------------------------------------
local WAYPOINT_FILE = "Rblx2/Jailbreak/waypoints.json"
local Waypoints = {}

local function loadWaypoints()
    if not (isfile and readfile) then return end
    local ok, data = pcall(function()
        if isfile(WAYPOINT_FILE) then
            return HttpService:JSONDecode(readfile(WAYPOINT_FILE))
        end
    end)
    if ok and type(data) == "table" then
        for name, coords in pairs(data) do
            if type(coords) == "table" and #coords == 3 then
                Waypoints[name] = Vector3.new(coords[1], coords[2], coords[3])
            end
        end
    end
end

local function saveWaypoints()
    if not (writefile and makefolder and isfolder) then return false end
    local data = {}
    for name, position in pairs(Waypoints) do
        data[name] = { position.X, position.Y, position.Z }
    end
    return pcall(function()
        if not isfolder("Rblx2") then makefolder("Rblx2") end
        if not isfolder("Rblx2/Jailbreak") then makefolder("Rblx2/Jailbreak") end
        writefile(WAYPOINT_FILE, HttpService:JSONEncode(data))
    end)
end

local function waypointNames()
    local names = {}
    for name in pairs(Waypoints) do table.insert(names, name) end
    table.sort(names)
    return names
end

loadWaypoints()

--// Bounties ---------------------------------------------------------------------
local Bounties = {}
local function refreshBounties()
    table.clear(Bounties)
    local value = ReplicatedStorage:FindFirstChild("BountyData")
    if not value then return end
    local ok, list = pcall(HttpService.JSONDecode, HttpService, value.Value)
    if ok and type(list) == "table" then
        for _, entry in ipairs(list) do
            if type(entry) == "table" and entry.UserId then
                Bounties[tonumber(entry.UserId)] = tonumber(entry.Bounty) or 0
            end
        end
    end
end
task.spawn(function()
    local value = ReplicatedStorage:WaitForChild("BountyData", 10)
    if value then
        refreshBounties()
        track(value:GetPropertyChangedSignal("Value"):Connect(refreshBounties))
    end
end)

local function formatCash(amount)
    local text = tostring(math.floor(amount))
    local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if formatted:sub(1, 1) == "," then formatted = formatted:sub(2) end
    return "$" .. formatted
end

local function equippedName(player)
    if not ItemSystem or type(ItemSystem.GetEquipped) ~= "function" then return nil end
    local ok, item = pcall(ItemSystem.GetEquipped, player)
    if ok and type(item) == "table" then
        return item.__ClassName
    end
    return nil
end

--// Window -----------------------------------------------------------------------
local Window = Library:CreateWindow({
    Title = "Jailbreak",
    Footer = "Rblx2",
    Icon = "car",
    ConfigFolder = "Rblx2/Jailbreak",
    AutoShow = true,
})

local CombatTab = Window:AddTab("Combat", "crosshair", "Silent aim and gun mods")
local VisualsTab = Window:AddTab("Visuals", "eye", "Player and world ESP")
local MovementTab = Window:AddTab("Movement", "footprints", "Speed, jump, noclip and fly")
local VehicleTab = Window:AddTab("Vehicle", "car", "Car mods and car fly")
local TeleportTab = Window:AddTab("Teleport", "map-pin", "Places, robberies, players and waypoints")
local RobberyTab = Window:AddTab("Robbery", "landmark", "Robbery status and helpers")
local MiscTab = Window:AddTab("Misc", "wrench", "Utility, server and mobile")

local function vehicleIsFree(model)
    local seat = model:FindFirstChild("Seat")
    local playerName = seat and seat:FindFirstChild("PlayerName")
    if not playerName or playerName.Value ~= "" then return false end
    if model:GetAttribute("Locked") == true then return false end
    local restrict = model:GetAttribute("TeamRestrict")
    if restrict and restrict ~= "" and restrict ~= teamName(LocalPlayer) then return false end
    return true
end

local TravelStatus
local StatusLabels = {}

do
-- Combat ---------------------------------------------------------------------------
local AimBox = CombatTab:AddLeftGroupbox("Silent aim", "crosshair")
AimBox:AddToggle("SilentAim", {
    Text = "Silent aim",
    Default = false,
    Risky = true,
    Tooltip = "Bends your bullets toward the target nearest the cursor, inside the FOV circle.",
}):AddKeyPicker("SilentAimKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Silent aim" })
AimBox:AddSlider("AimFOV", { Text = "FOV radius", Default = 150, Min = 20, Max = 800, Rounding = 0, Suffix = " px" })
AimBox:AddToggle("ShowFOV", { Text = "Show FOV circle", Default = true })
    :AddColorPicker("FOVColor", { Default = Color3.fromRGB(255, 151, 227), Title = "FOV color" })
AimBox:AddToggle("ShowAimTarget", { Text = "Show target line", Default = true })
AimBox:AddToggle("AimPointGun", {
    Text = "Point gun at target",
    Default = true,
    Tooltip = "Your arms and the aim others see follow the target too, so shots line up with what the server is told.",
})
AimBox:AddDropdown("AimPart", {
    Text = "Aim at",
    Values = { "Hitbox (root)", "Head", "UpperTorso", "Random" },
    Default = "Hitbox (root)",
    Tooltip = "Jailbreak checks hits with a sphere around the root part, so Hitbox is the most reliable.",
})
AimBox:AddSlider("AimHitChance", { Text = "Hit chance", Default = 100, Min = 1, Max = 100, Rounding = 0, Suffix = "%" })
AimBox:AddDropdown("AimOrigin", {
    Text = "FOV origin",
    Values = { "Mouse", "Screen center" },
    Default = Library.IsMobile and "Screen center" or "Mouse",
    Tooltip = "On mobile there's no mouse, so the screen center is used.",
})
AimBox:AddToggle("AimSticky", { Text = "Stay on target", Default = true, Tooltip = "Keeps the same target until it dies, hides or leaves the circle." })
AimBox:AddToggle("AutoShoot", {
    Text = "Auto shoot",
    Default = false,
    Risky = true,
    Tooltip = "Fires your held gun when a target is in the circle and in clear view. Ammo, reloads and fire rate still apply.",
}):AddKeyPicker("AutoShootKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto shoot" })
AimBox:AddSlider("AutoShootDelay", { Text = "Auto shoot delay", Default = 120, Min = 0, Max = 1000, Rounding = 0, Suffix = " ms" })

local TargetBox = CombatTab:AddRightGroupbox("Targeting", "users")
TargetBox:AddToggle("AimEnemiesOnly", {
    Text = "Enemies only",
    Default = true,
    Tooltip = "Police aim at criminals, everyone else aims at police.",
})
TargetBox:AddToggle("AimPrisoners", { Text = "Police: include prisoners", Default = false })
TargetBox:AddToggle("AimVisibleOnly", { Text = "Visible only", Default = false, Tooltip = "Skips targets behind walls." })
TargetBox:AddToggle("AimNPCs", { Text = "Target NPCs (guards etc.)", Default = true })
TargetBox:AddToggle("AimSkipDocile", { Text = "Skip docile NPCs", Default = false, Tooltip = "Docile guards don't shoot back." })
TargetBox:AddToggle("AimSkipForcefield", { Text = "Skip spawn-protected", Default = true })
TargetBox:AddToggle("AimPrediction", { Text = "Lead moving targets", Default = true })
TargetBox:AddSlider("AimPredictionScale", { Text = "Lead amount", Default = 1, Min = 0, Max = 2, Rounding = 2, Suffix = "x" })
TargetBox:AddToggle("AimPredictVertical", { Text = "Lead up/down movement", Default = true, Tooltip = "Turn off if jumping targets make it miss." })
TargetBox:AddToggle("AimPingComp", { Text = "Ping compensation", Default = true, Tooltip = "Leads a bit more by your ping, since other players are drawn slightly in the past." })
TargetBox:AddSlider("AimMaxDistance", { Text = "Max distance", Default = 800, Min = 50, Max = 2000, Rounding = 0, Suffix = " studs" })
TargetBox:AddDropdown("AimPriority", { Text = "Priority", Values = { "Closest to cursor", "Closest to you", "Lowest health" }, Default = "Closest to cursor" })

local GunBox = CombatTab:AddRightGroupbox("Gun mods", "zap")
GunBox:AddToggle("NoRecoil", { Text = "No recoil", Default = false, Tooltip = "Zeroes the camera kick from each shot." })
GunBox:AddToggle("NoSpread", { Text = "No spread", Default = false, Risky = true })
GunBox:AddToggle("AutoFire", { Text = "Full auto on every gun", Default = false, Risky = true, Tooltip = "Hold to fire. The server still limits fire rate." })

-- Visuals --------------------------------------------------------------------------
local EspBox = VisualsTab:AddLeftGroupbox("Player ESP", "users")
EspBox:AddToggle("ESP", { Text = "Enabled", Default = false }):AddKeyPicker("ESPKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "ESP" })
EspBox:AddDropdown("ESPTeams", {
    Text = "Teams",
    Values = { "Police", "Criminal", "Prisoner" },
    Default = { "Police", "Criminal", "Prisoner" },
    Multi = true,
})
EspBox:AddToggle("ESPChams", { Text = "Chams (highlight)", Default = true })
EspBox:AddToggle("ESPName", { Text = "Names", Default = true })
EspBox:AddToggle("ESPDistance", { Text = "Distance", Default = true })
EspBox:AddToggle("ESPHealth", { Text = "Health", Default = true })
EspBox:AddToggle("ESPItem", { Text = "Held item", Default = true })
EspBox:AddToggle("ESPBounty", { Text = "Bounty", Default = true })
EspBox:AddToggle("ESPTracers", { Text = "Tracers", Default = false })
EspBox:AddSlider("ESPMaxDistance", { Text = "Max distance", Default = 3000, Min = 100, Max = 10000, Rounding = 0, Suffix = " studs" })

local EspStyle = VisualsTab:AddRightGroupbox("Style", "palette")
EspStyle:AddLabel("Police"):AddColorPicker("ColorPolice", { Default = Color3.fromRGB(70, 150, 255), Title = "Police" })
EspStyle:AddLabel("Criminal"):AddColorPicker("ColorCriminal", { Default = Color3.fromRGB(255, 70, 70), Title = "Criminal" })
EspStyle:AddLabel("Prisoner"):AddColorPicker("ColorPrisoner", { Default = Color3.fromRGB(255, 170, 40), Title = "Prisoner" })
EspStyle:AddToggle("ESPUseTarget", { Text = "Color silent aim target", Default = true })
    :AddColorPicker("ColorTarget", { Default = Color3.fromRGB(255, 255, 255), Title = "Target" })
EspStyle:AddSlider("ESPFill", { Text = "Chams fill", Default = 0.65, Min = 0, Max = 1, Rounding = 2 })
EspStyle:AddSlider("ESPTextSize", { Text = "Text size", Default = 13, Min = 8, Max = 22, Rounding = 0 })
EspStyle:AddDropdown("TracerOrigin", { Text = "Tracer from", Values = { "Bottom", "Center", "Mouse" }, Default = "Bottom" })
EspStyle:AddSlider("TracerThickness", { Text = "Tracer thickness", Default = 1, Min = 1, Max = 4, Rounding = 0 })

local WorldEspBox = VisualsTab:AddRightGroupbox("World ESP", "globe")
WorldEspBox:AddToggle("ESPRobberies", { Text = "Robberies (open/closed)", Default = false })
WorldEspBox:AddToggle("ESPAirdrops", { Text = "Airdrops", Default = false })
WorldEspBox:AddToggle("ESPCash", { Text = "Dropped cash", Default = false })
WorldEspBox:AddToggle("ESPVehicles", { Text = "Empty vehicles", Default = false })
WorldEspBox:AddToggle("ESPNPCs", { Text = "NPCs (guards etc.)", Default = false })

-- Movement -------------------------------------------------------------------------
local CharBox = MovementTab:AddLeftGroupbox("Character", "user")
CharBox:AddToggle("WalkSpeedOn", { Text = "Walk speed", Default = false, Risky = true })
    :AddKeyPicker("WalkSpeedKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Walk speed" })
CharBox:AddSlider("WalkSpeed", { Text = "Speed", Default = 30, Min = 16, Max = 150, Rounding = 0 })
CharBox:AddToggle("JumpPowerOn", { Text = "Jump power", Default = false })
CharBox:AddSlider("JumpPower", { Text = "Power", Default = 75, Min = 50, Max = 300, Rounding = 0 })
CharBox:AddToggle("InfiniteJump", { Text = "Infinite jump", Default = false, Risky = true })
CharBox:AddToggle("Noclip", { Text = "Noclip", Default = false, Risky = true })
    :AddKeyPicker("NoclipKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Noclip" })

local FlyBox = MovementTab:AddRightGroupbox("Fly", "plane")
FlyBox:AddToggle("Fly", { Text = "Fly", Default = false, Risky = true })
    :AddKeyPicker("FlyKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
FlyBox:AddSlider("FlySpeed", { Text = "Speed", Default = 60, Min = 10, Max = 300, Rounding = 0 })
FlyBox:AddLabel("Move with WASD or the thumbstick. Up: Space or E. Down: Q or Left Ctrl. On mobile, use the Up and Down buttons.", true)

-- Vehicle --------------------------------------------------------------------------
local CarBox = VehicleTab:AddLeftGroupbox("Car mods", "gauge")
CarBox:AddLabel("These work on cars (Chassis). Helis and jets aren't affected; car fly works on all of them.", true)
CarBox:AddToggle("CarSpeed", { Text = "Engine speed", Default = false, Risky = true })
CarBox:AddSlider("CarSpeedMult", { Text = "Engine multiplier", Default = 1.6, Min = 1, Max = 6, Rounding = 2, Suffix = "x" })
CarBox:AddToggle("CarTurn", { Text = "Turn speed", Default = false })
CarBox:AddSlider("CarTurnMult", { Text = "Turn multiplier", Default = 1.5, Min = 0.5, Max = 4, Rounding = 2, Suffix = "x" })
CarBox:AddToggle("CarHeight", { Text = "Suspension height", Default = false })
CarBox:AddSlider("CarHeightMult", { Text = "Height multiplier", Default = 1.5, Min = 0.5, Max = 4, Rounding = 2, Suffix = "x" })
CarBox:AddToggle("CarBrakes", { Text = "Stronger brakes", Default = false })
CarBox:AddSlider("CarBrakesAdd", { Text = "Extra braking", Default = 2, Min = 0, Max = 10, Rounding = 1 })
CarBox:AddToggle("InfNitro", { Text = "Infinite nitro", Default = false, Risky = true })
CarBox:AddToggle("AntiFlip", { Text = "Auto flip upright", Default = true })

local CarFlyBox = VehicleTab:AddRightGroupbox("Car fly", "plane")
CarFlyBox:AddToggle("CarFly", { Text = "Car fly", Default = false, Risky = true })
    :AddKeyPicker("CarFlyKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Car fly" })
CarFlyBox:AddSlider("CarFlySpeed", { Text = "Speed", Default = 150, Min = 20, Max = 600, Rounding = 0 })
CarFlyBox:AddToggle("CarFlyFaceCamera", { Text = "Face where you look", Default = true })
CarFlyBox:AddLabel("Same controls as fly. On mobile, use Fwd, Back, Up and Down.", true)

local CarTools = VehicleTab:AddRightGroupbox("Tools", "wrench")
CarTools:AddLabel("Boost"):AddKeyPicker("CarBoostKey", { Default = "B", Mode = "Toggle", NoMode = true, Text = "Boost" })
CarTools:AddSlider("CarBoostPower", { Text = "Boost power", Default = 120, Min = 20, Max = 500, Rounding = 0 })
CarTools:AddButton({
    Text = "Lock / unlock my car",
    Func = function()
        if VehicleUtils and type(VehicleUtils.toggleLocalLocked) == "function" then
            if type(VehicleUtils.canLocalLock) == "function" and not VehicleUtils.canLocalLock() then
                notify("Vehicle", "Get in the driver's seat of a car you can lock.", 4)
                return
            end
            local ok, err = pcall(VehicleUtils.toggleLocalLocked)
            if not ok then notify("Vehicle", "Couldn't lock: " .. tostring(err), 4) end
        else
            notify("Vehicle", "Lock isn't available until you've been in a car.", 4)
        end
    end,
})

-- Teleport -------------------------------------------------------------------------
local TravelBox = TeleportTab:AddLeftGroupbox("Travel settings", "navigation")
TravelBox:AddDropdown("TPMode", {
    Text = "Mode",
    Values = { "Tween", "Instant" },
    Default = "Tween",
    Tooltip = "Tween flies you there at the speeds below. Instant on foot is very likely to get you sent back or killed.",
})
TravelBox:AddSlider("TPSpeed", { Text = "On-foot speed", Default = 120, Min = 20, Max = 500, Rounding = 0 })
TravelBox:AddSlider("TPVehicleSpeed", { Text = "Vehicle speed", Default = 350, Min = 50, Max = 1500, Rounding = 0 })
TravelBox:AddToggle("TPUseVehicle", { Text = "Use vehicle if driving", Default = true, Tooltip = "Moves your car with you in it. Much safer than on foot." })
TravelBox:AddDropdown("TPRoute", {
    Text = "Route",
    Values = { "Sky", "Ground", "Direct" },
    Default = "Sky",
    Tooltip = "Sky: up, across, down. Ground: hugs the terrain a few studs up. Direct: a straight line.",
})
TravelBox:AddSlider("TPSkyHeight", { Text = "Sky height", Default = 150, Min = 30, Max = 600, Rounding = 0, Suffix = " studs" })
TravelBox:AddSlider("TPGroundHeight", { Text = "Ground hover", Default = 6, Min = 2, Max = 40, Rounding = 0, Suffix = " studs" })
TravelBox:AddToggle("TPSmooth", { Text = "Smooth start and stop", Default = true, Tooltip = "Speeds up gradually and brakes before arriving." })
TravelBox:AddSlider("TPAccel", { Text = "Acceleration", Default = 250, Min = 30, Max = 2000, Rounding = 0, Suffix = " studs/s²" })
TravelBox:AddToggle("TPFaceDirection", { Text = "Face where you're going", Default = true })
TravelBox:AddToggle("ClickTP", { Text = "Ctrl + click to travel", Default = false, Tooltip = "Hold Left Ctrl and click a spot to travel there with these settings." })
TravelStatus = TravelBox:AddLabel("Status: idle")
TravelBox:AddButton({ Text = "Stop", Func = stopTravel })

local PlacesBox = TeleportTab:AddLeftGroupbox("Places", "map")
PlacesBox:AddDropdown("TPLocation", { Text = "Place", Values = LocationNames, Default = 1, Searchable = true })
PlacesBox:AddButton({
    Text = "Go to place",
    Func = function()
        local name = opt("TPLocation")
        local position = name and locationPosition(name)
        if position then
            travelTo(position, name)
        else
            notify("Teleport", "Couldn't find " .. tostring(name) .. " in the map.", 4)
        end
    end,
})
PlacesBox:AddDropdown("TPRobbery", { Text = "Robbery", Values = RobberyNames, Default = 1, Searchable = true })
PlacesBox:AddButton({
    Text = "Go to robbery",
    Func = function()
        local robbery = robberyByName(opt("TPRobbery"))
        local instance = robbery and robberyInstance(robbery)
        local position, size = instancePosition(instance)
        if position then
            -- Trains, the money truck, the ship and the plane move, so the
            -- goal is re-read each frame; still robberies land on top once.
            local moving = robbery.Key:find("TRAIN") or robbery.Key == "MONEY_TRUCK"
                or robbery.Key == "CARGO_SHIP" or robbery.Key == "CARGO_PLANE"
            if moving then
                travelTo(function()
                    local current = robberyInstance(robbery)
                    local at, extent = instancePosition(current)
                    if not at then return nil end
                    return at + Vector3.new(0, (extent and extent.Y / 2 or 0) + 5, 0)
                end, robbery.Name)
            else
                travelTo(landingPoint(position, size), robbery.Name)
            end
        else
            notify("Teleport", "That robbery isn't in the map right now.", 4)
        end
    end,
})

local function nearestTagged(tag, filter)
    local root = getRoot()
    if not root then return nil end
    local best, bestDistance
    for _, instance in ipairs(CollectionService:GetTagged(tag)) do
        if instance:IsDescendantOf(Workspace) and (not filter or filter(instance)) then
            local position = instancePosition(instance)
            if position then
                local distance = (position - root.Position).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = instance, distance
                end
            end
        end
    end
    return best
end


PlacesBox:AddButton({
    Text = "Nearest free car",
    Func = function()
        local root = getRoot()
        local folder = Workspace:FindFirstChild("Vehicles")
        if not root or not folder then return end
        local best, bestDistance
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and vehicleIsFree(model) then
                local seat = model:FindFirstChild("Seat")
                local distance = (seat.Position - root.Position).Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = seat, distance
                end
            end
        end
        if best then
            travelTo(best.Position + Vector3.new(0, 4, 0), "free car")
        else
            notify("Teleport", "No free cars found.", 3)
        end
    end,
}):AddButton({
    Text = "Nearest airdrop",
    Func = function()
        local briefcase = nearestTagged("Briefcase", function(instance)
            return instance:GetAttribute("BriefcaseCollected") ~= true
        end)
        local position = instancePosition(briefcase)
        if position then
            travelTo(position + Vector3.new(0, 4, 0), "airdrop")
        else
            notify("Teleport", "No airdrop right now.", 3)
        end
    end,
})

local PeopleBox = TeleportTab:AddRightGroupbox("Players", "users")
PeopleBox:AddDropdown("TPPlayer", { Text = "Player", SpecialType = "Player", ExcludeLocalPlayer = true })
local function selectedPlayer()
    local player = Players:FindFirstChild(tostring(opt("TPPlayer", "")))
    if player and getRoot(player.Character) then return player end
    notify("Teleport", "Pick a player who has spawned.", 3)
    return nil
end

-- Re-read every frame, so you end up where they are now rather than where
-- they were when you clicked.
local function playerGoal(player)
    return function()
        local root = player.Parent and getRoot(player.Character)
        if not root then return nil end
        return root.Position - root.CFrame.LookVector * opt("TPFollowDistance", 4) + Vector3.new(0, 3, 0)
    end
end

PeopleBox:AddButton({
    Text = "Go to player",
    Func = function()
        local player = selectedPlayer()
        if player then travelTo(playerGoal(player), player.DisplayName) end
    end,
}):AddButton({
    Text = "Follow",
    Func = function()
        local player = selectedPlayer()
        if not player then return end
        travelTo(playerGoal(player), player.DisplayName, {
            Follow = true,
            Velocity = function()
                local root = getRoot(player.Character)
                return root and root.AssemblyLinearVelocity or nil
            end,
        })
    end,
})
PeopleBox:AddSlider("TPFollowDistance", { Text = "Stay behind by", Default = 4, Min = 0, Max = 30, Rounding = 0, Suffix = " studs" })
PeopleBox:AddButton({
    Text = "Spectate / stop spectating",
    Func = function()
        local mine = getHumanoid()
        if mine and Camera.CameraSubject ~= mine then
            Camera.CameraSubject = mine
            return
        end
        local player = selectedPlayer()
        local target = player and getHumanoid(player.Character)
        if target then Camera.CameraSubject = target end
    end,
})

local WaypointBox = TeleportTab:AddRightGroupbox("Waypoints", "bookmark")
WaypointBox:AddInput("WaypointName", { Text = "Name", Placeholder = "My spot", Finished = false })
WaypointBox:AddDropdown("WaypointList", { Text = "Saved", Values = waypointNames(), AllowNull = true, Searchable = true })
WaypointBox:AddButton({
    Text = "Save here",
    Func = function()
        local root = getRoot()
        local name = tostring(opt("WaypointName", "")):gsub("^%s+", ""):gsub("%s+$", "")
        if not root then return end
        if name == "" then name = ("Spot %d"):format(#waypointNames() + 1) end
        Waypoints[name] = root.Position
        Options.WaypointList:SetValues(waypointNames())
        if not saveWaypoints() then
            notify("Waypoints", "Saved for this session only (no file access).", 3)
        else
            notify("Waypoints", "Saved " .. name, 2)
        end
    end,
}):AddButton({
    Text = "Go",
    Func = function()
        local position = Waypoints[opt("WaypointList", "")]
        if position then travelTo(position, opt("WaypointList")) end
    end,
})
WaypointBox:AddButton({
    Text = "Delete selected",
    DoubleClick = true,
    Func = function()
        local name = opt("WaypointList")
        if name and Waypoints[name] then
            Waypoints[name] = nil
            Options.WaypointList:SetValues(waypointNames())
            saveWaypoints()
        end
    end,
})

-- Robbery --------------------------------------------------------------------------
local StatusBox = RobberyTab:AddLeftGroupbox("Status", "activity")
for _, robbery in ipairs(Robberies) do
    StatusLabels[robbery] = StatusBox:AddLabel(robbery.Name .. ": ...")
end
StatusBox:AddToggle("NotifyRobberies", { Text = "Notify when one opens", Default = true })

local HelperBox = RobberyTab:AddRightGroupbox("Helpers", "shield")
HelperBox:AddToggle("NoHazards", {
    Text = "Disable lasers and traps",
    Default = false,
    Risky = true,
    Tooltip = "Stops lasers, barbed wire, spikes, lava, security cameras and the casino alarm from touching you.",
})
HelperBox:AddToggle("InstantInteract", {
    Text = "Instant hold prompts",
    Default = false,
    Risky = true,
    Tooltip = "Removes the hold time on E prompts. The server may still check some of them.",
})
HelperBox:AddToggle("InteractRange", { Text = "Longer prompt range", Default = false })
HelperBox:AddSlider("InteractRangeValue", { Text = "Prompt range", Default = 16, Min = 8, Max = 40, Rounding = 0, Suffix = " studs" })

local AutoBox = RobberyTab:AddRightGroupbox("Auto interact", "hand")
AutoBox:AddToggle("AutoInteract", {
    Text = "Auto interact",
    Default = false,
    Risky = true,
    Tooltip = "Presses nearby prompts whose name contains one of the words below.",
}):AddKeyPicker("AutoInteractKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto interact" })
AutoBox:AddInput("AutoInteractWords", {
    Text = "Prompt words (comma separated)",
    Default = "Collect, Break, Hack, Grab, Crack, Open Briefcase",
})
AutoBox:AddSlider("AutoInteractRange", { Text = "Range", Default = 12, Min = 4, Max = 40, Rounding = 0, Suffix = " studs" })
AutoBox:AddDropdown("NearbyPrompts", { Text = "Prompts near you", Values = {}, AllowNull = true })
AutoBox:AddButton({
    Text = "Scan nearby",
    Func = function()
        if not CircleAction then
            notify("Auto interact", "The game's prompt module didn't load.", 4)
            return
        end
        local root = getRoot()
        if not root then return end
        local names, seen = {}, {}
        for _, spec in ipairs(CircleAction.Specs) do
            local position
            if typeof(spec.WorldPosition) == "Vector3" then
                position = spec.WorldPosition
            elseif spec.Attachment and spec.Attachment.Parent then
                position = spec.Attachment.WorldPosition
            elseif spec.Part and spec.Part.Parent then
                position = spec.Part.Position
            end
            local name = type(spec.Name) == "string" and spec.Name or ""
            if position and name ~= "" and not seen[name] and (position - root.Position).Magnitude <= 80 then
                seen[name] = true
                table.insert(names, name)
            end
        end
        table.sort(names)
        Options.NearbyPrompts:SetValues(names)
        notify("Auto interact", #names .. " prompt(s) within 80 studs.", 3)
    end,
}):AddButton({
    Text = "Add selected",
    Func = function()
        local name = opt("NearbyPrompts")
        if not name or name == "" then return end
        local current = tostring(opt("AutoInteractWords", ""))
        Options.AutoInteractWords:SetValue(current == "" and name or (current .. ", " .. name))
    end,
})

-- Misc -------------------------------------------------------------------------------
local UtilBox = MiscTab:AddLeftGroupbox("Utility", "sun")
UtilBox:AddToggle("Fullbright", { Text = "Fullbright", Default = false })
UtilBox:AddToggle("NoFog", { Text = "No fog", Default = false })
UtilBox:AddToggle("CustomFOV", { Text = "Camera FOV", Default = false })
UtilBox:AddSlider("FOVValue", { Text = "FOV", Default = 90, Min = 50, Max = 120, Rounding = 0 })
UtilBox:AddToggle("AntiAFK", { Text = "Anti AFK", Default = true })

local ServerBox = MiscTab:AddRightGroupbox("Server", "server")
ServerBox:AddButton({
    Text = "Rejoin",
    Func = function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end,
})
ServerBox:AddButton({
    Text = "Server hop",
    Func = function()
        local ok, result = pcall(function()
            return HttpService:JSONDecode(game:HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)))
        end)
        if not ok or type(result) ~= "table" or type(result.data) ~= "table" then
            notify("Server hop", "Couldn't get the server list.", 4)
            return
        end
        local choices = {}
        for _, server in ipairs(result.data) do
            if server.id ~= game.JobId and tonumber(server.playing) and tonumber(server.maxPlayers) and server.playing < server.maxPlayers then
                table.insert(choices, server.id)
            end
        end
        if #choices == 0 then
            notify("Server hop", "No other open servers found.", 4)
            return
        end
        TeleportService:TeleportToPlaceInstance(game.PlaceId, choices[math.random(1, #choices)], LocalPlayer)
    end,
})

local MobileBox = MiscTab:AddRightGroupbox("Mobile", "smartphone")
MobileBox:AddToggle("MobileButtons", {
    Text = "On-screen buttons",
    Default = Library.IsMobile,
    Tooltip = "Fly, car fly, aim and noclip toggles, plus Up/Down/Fwd/Back/Boost for flying.",
})
MobileBox:AddSlider("MobileButtonSize", { Text = "Button size", Default = 52, Min = 36, Max = 80, Rounding = 0 })

end

Library:SetIgnoreIndexes({ "TPPlayer", "NearbyPrompts", "WaypointName", "WaypointList" })

--// Silent aim -------------------------------------------------------------------
local Aim = { Target = nil, Part = nil, Character = nil }

local FOVCircle = Instance.new("Frame")
FOVCircle.AnchorPoint = Vector2.new(0.5, 0.5)
FOVCircle.BackgroundTransparency = 1
FOVCircle.Visible = false
FOVCircle.Parent = Overlay
local FOVCorner = Instance.new("UICorner")
FOVCorner.CornerRadius = UDim.new(1, 0)
FOVCorner.Parent = FOVCircle
local FOVStroke = Instance.new("UIStroke")
FOVStroke.Thickness = 1.5
FOVStroke.Transparency = 0.2
FOVStroke.Parent = FOVCircle

local TargetLabel = Instance.new("TextLabel")
TargetLabel.AnchorPoint = Vector2.new(0.5, 0)
TargetLabel.BackgroundTransparency = 1
TargetLabel.Font = Enum.Font.GothamBold
TargetLabel.TextSize = 13
TargetLabel.TextColor3 = Color3.new(1, 1, 1)
TargetLabel.TextStrokeTransparency = 0.4
TargetLabel.Size = UDim2.fromOffset(240, 18)
TargetLabel.Visible = false
TargetLabel.Parent = Overlay

local TargetLine = newLine()

local function aimOrigin()
    if opt("AimOrigin", "Mouse") == "Screen center" or not UserInputService.MouseEnabled then
        return viewportSize() / 2
    end
    return UserInputService:GetMouseLocation()
end

-- Bullets hit by a sphere test around each target's root part (BulletEmitter
-- Update, via the "Humanoid" tag), not by touching limbs, so the root part is
-- the surest thing to aim at. Other parts still land inside that sphere at
-- normal ranges.
local AIM_PARTS = {
    ["Hitbox (root)"] = "HumanoidRootPart",
    Head = "Head",
    UpperTorso = "UpperTorso",
    HumanoidRootPart = "HumanoidRootPart",
}

local function aimPartFor(character, randomPick)
    local choice = opt("AimPart", "Hitbox (root)")
    if choice == "Random" then
        choice = randomPick or "HumanoidRootPart"
    end
    local name = AIM_PARTS[choice] or "HumanoidRootPart"
    return character:FindFirstChild(name) or getRoot(character)
end

local AimRayParams = RaycastParams.new()
AimRayParams.FilterType = Enum.RaycastFilterType.Exclude
-- Bullets fly through anything that doesn't collide, so the wall check does too.
pcall(function() AimRayParams.RespectCanCollide = true end)

local function isVisible(part, character)
    local origin = Camera.CFrame.Position
    local ignore = { character, Overlay }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local vehicle = getVehicle()
    if vehicle then table.insert(ignore, vehicle) end
    local items = Workspace:FindFirstChild("Items")
    if items then table.insert(ignore, items) end
    AimRayParams.FilterDescendantsInstances = ignore
    local hit = Workspace:Raycast(origin, part.Position - origin, AimRayParams)
    if not hit then return true end
    -- Glass and the like are tagged by the game to let bullets through.
    return hit.Instance:GetAttribute("InvisibleToBullets") == true
end

-- NPCs: guards carry the "GuardNPC" tag on their model, and every humanoid the
-- game's bullets can hit carries the "Humanoid" tag. Anything tagged that
-- isn't a player's character counts as an NPC. Rebuilt twice a second.
local NpcCache = { At = 0, List = {} }

local function getNpcs()
    local now = os.clock()
    if now - NpcCache.At < 0.5 then
        return NpcCache.List
    end
    NpcCache.At = now
    local list, seen = {}, {}
    local function add(model)
        if seen[model] or not model:IsA("Model") or not model:IsDescendantOf(Workspace) then return end
        if Players:GetPlayerFromCharacter(model) then return end
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        if not humanoid then return end
        seen[model] = true
        table.insert(list, {
            Character = model,
            Name = CollectionService:HasTag(model, "GuardNPC") and "Guard" or model.Name,
            Docile = model:GetAttribute("IsDocile") == true,
            Npc = true,
        })
    end
    for _, model in ipairs(CollectionService:GetTagged("GuardNPC")) do
        add(model)
    end
    for _, humanoid in ipairs(CollectionService:GetTagged("Humanoid")) do
        if humanoid:IsA("Humanoid") and humanoid.Parent then
            add(humanoid.Parent)
        end
    end
    local folder = Workspace:FindFirstChild("GuardNPCPlayers")
    if folder then
        for _, descendant in ipairs(folder:GetDescendants()) do
            if descendant:IsA("Humanoid") and descendant.Parent then
                add(descendant.Parent)
            end
        end
    end
    NpcCache.List = list
    return list
end

local function aimCandidates()
    local list = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and (not on("AimEnemiesOnly") or isEnemy(player)) then
            table.insert(list, { Character = player.Character, Name = player.DisplayName, Player = player })
        end
    end
    if on("AimNPCs") then
        for _, npc in ipairs(getNpcs()) do
            if not (npc.Docile and on("AimSkipDocile")) then
                table.insert(list, npc)
            end
        end
    end
    return list
end

local function myPosition()
    local root = getRoot()
    return root and root.Position or Camera.CFrame.Position
end

-- Scores one candidate, or returns nil if it can't be targeted right now.
local function scoreCandidate(candidate, origin2D, radius)
    local character = candidate.Character
    local humanoid = getHumanoid(character)
    local root = getRoot(character)
    if not humanoid or not root or humanoid.Health <= 0 or not character:IsDescendantOf(Workspace) then
        return nil
    end
    if character:FindFirstChildOfClass("ForceField") and on("AimSkipForcefield") then
        return nil
    end
    local distance = (root.Position - myPosition()).Magnitude
    if distance > opt("AimMaxDistance", 800) then return nil end
    local part = aimPartFor(character, candidate.RandomPart)
    local screen, onScreen = Camera:WorldToViewportPoint(part.Position)
    if not onScreen or screen.Z <= 0 then return nil end
    local cursorDistance = (Vector2.new(screen.X, screen.Y) - origin2D).Magnitude
    if cursorDistance > radius then return nil end
    if on("AimVisibleOnly") and not isVisible(part, character) then return nil end
    local priority = opt("AimPriority", "Closest to cursor")
    if priority == "Closest to you" then return distance end
    if priority == "Lowest health" then return humanoid.Health end
    return cursorDistance
end

local RANDOM_PARTS = { "Head", "UpperTorso", "HumanoidRootPart" }

local function updateAimTarget()
    if not on("SilentAim") then
        Aim.Target, Aim.Part, Aim.Character = nil, nil, nil
        return
    end

    local origin2D = aimOrigin()
    local radius = opt("AimFOV", 150)

    -- Sticky: keep the current target while it stays valid, with some slack
    -- on the circle so it doesn't flick off at the edge.
    if on("AimSticky") and Aim.Target then
        if scoreCandidate(Aim.Target, origin2D, radius * 1.5) then
            Aim.Part = aimPartFor(Aim.Target.Character, Aim.Target.RandomPart)
            return
        end
    end

    local best, bestScore
    for _, candidate in ipairs(aimCandidates()) do
        local score = scoreCandidate(candidate, origin2D, radius)
        if score and (not bestScore or score < bestScore) then
            best, bestScore = candidate, score
        end
    end

    if best then
        if not Aim.Target or Aim.Target.Character ~= best.Character then
            best.RandomPart = RANDOM_PARTS[math.random(1, #RANDOM_PARTS)]
        else
            best.RandomPart = Aim.Target.RandomPart
        end
        Aim.Target = best
        Aim.Character = best.Character
        Aim.Part = aimPartFor(best.Character, best.RandomPart)
    else
        Aim.Target, Aim.Part, Aim.Character = nil, nil, nil
    end
end

local function networkDelay()
    if not on("AimPingComp") then return 0 end
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(ping) == "number" then
        return math.clamp(ping, 0, 0.5)
    end
    return 0
end

-- Where to send the bullet from the gun's tip. Bullets keep a fixed speed and
-- get pulled down by GravityVector, so this leads the target by the travel
-- time (re-solved a few times, since leading changes the distance), adds the
-- network delay because what you see of other players is slightly old, then
-- aims high by the drop over that time.
local function solveAim(origin, speed, gravity, part)
    local position = part.Position
    if type(speed) ~= "number" or speed <= 0 then
        local direction = position - origin
        return direction.Magnitude > 0.01 and direction.Unit or nil
    end

    local velocity = Vector3.zero
    if on("AimPrediction") then
        velocity = part.AssemblyLinearVelocity * opt("AimPredictionScale", 1)
        if not on("AimPredictVertical") then
            velocity = Vector3.new(velocity.X, 0, velocity.Z)
        end
    end
    local delay = networkDelay()

    local predicted = position
    local time = (position - origin).Magnitude / speed
    for _ = 1, 4 do
        predicted = position + velocity * (time + delay)
        time = (predicted - origin).Magnitude / speed
    end
    if typeof(gravity) == "Vector3" then
        predicted -= 0.5 * gravity * time * time
    end

    local direction = predicted - origin
    if direction.Magnitude < 0.01 then return nil end
    return direction.Unit
end

if BulletEmitter and type(BulletEmitter.Emit) == "function" then
    local originalEmit = BulletEmitter.Emit
    local lastRoll, lastRollHit = 0, true
    BulletEmitter.Emit = function(self, origin, direction, speed, ...)
        if not Unloading and type(self) == "table" and self.Local and on("SilentAim") then
            local part = Aim.Part
            if part and part.Parent and typeof(origin) == "Vector3" then
                -- One roll per shot, so every shotgun pellet goes the same way.
                local now = os.clock()
                if now - lastRoll > 0.03 then
                    lastRoll = now
                    lastRollHit = math.random(1, 100) <= opt("AimHitChance", 100)
                end
                if lastRollHit then
                    local ok, aimed = pcall(solveAim, origin, speed, self.GravityVector, part)
                    if ok and aimed then
                        direction = aimed
                    end
                end
            end
        end
        return originalEmit(self, origin, direction, speed, ...)
    end
    onCleanup(function()
        BulletEmitter.Emit = originalEmit
    end)
else
    task.defer(notify, "Silent aim", "The game's bullet module didn't load, so silent aim is off.", 5)
end

-- Auto shoot: the same call the gun makes on a click (_attemptShoot), which
-- still checks ammo, reloads and the fire-rate cooldown itself.
local LastAutoShot = 0

local function autoShootStep()
    if not on("AutoShoot") or not on("SilentAim") then return end
    local part = Aim.Part
    if not part or not part.Parent or not Aim.Character then return end
    if os.clock() - LastAutoShot < opt("AutoShootDelay", 120) / 1000 then return end
    if not ItemSystem or type(ItemSystem.GetEquipped) ~= "function" then return end
    local ok, item = pcall(ItemSystem.GetEquipped, LocalPlayer)
    if not ok or type(item) ~= "table" or item.BulletEmitter == nil or type(item._attemptShoot) ~= "function" then
        return
    end
    if not isVisible(part, Aim.Character) then return end
    LastAutoShot = os.clock()
    pcall(item._attemptShoot, item)
end

-- Guns turn the mouse into a world point here every frame; it sets the tip
-- direction and is what gets sent to the server as your aim.
if ItemBase and type(ItemBase.ProjectMouseLocationToWorld) == "function" then
    local originalProject = ItemBase.ProjectMouseLocationToWorld
    ItemBase.ProjectMouseLocationToWorld = function(self, location, ...)
        if not Unloading and type(self) == "table" and self.Local and self.BulletEmitter ~= nil
            and on("SilentAim") and on("AimPointGun") then
            local part = Aim.Part
            if part and part.Parent then
                return part.Position
            end
        end
        return originalProject(self, location, ...)
    end
    onCleanup(function()
        ItemBase.ProjectMouseLocationToWorld = originalProject
    end)
end

--// Gun mods -------------------------------------------------------------------
local GunBackup = {}

local function applyGunMods()
    local folder = findPath(ReplicatedStorage, "Game.ItemConfig")
    if not folder then return end
    for _, module in ipairs(folder:GetChildren()) do
        if module:IsA("ModuleScript") then
            local ok, config = pcall(require, module)
            if ok and type(config) == "table" and config.BulletSpeed ~= nil then
                local backup = GunBackup[config]
                if not backup then
                    backup = {
                        CamShakeMagnitude = config.CamShakeMagnitude,
                        BulletSpread = config.BulletSpread,
                        FireAuto = config.FireAuto,
                    }
                    GunBackup[config] = backup
                end
                pcall(function()
                    config.CamShakeMagnitude = (on("NoRecoil") and not Unloading) and 0 or backup.CamShakeMagnitude
                    config.BulletSpread = (on("NoSpread") and not Unloading) and 0 or backup.BulletSpread
                    config.FireAuto = (on("AutoFire") and not Unloading) and true or backup.FireAuto
                end)
            end
        end
    end
end

for _, index in ipairs({ "NoRecoil", "NoSpread", "AutoFire" }) do
    Toggles[index]:OnChanged(applyGunMods)
end
onCleanup(applyGunMods)

--// Player ESP -----------------------------------------------------------------
local Esp = {}

local function teamColor(team)
    if team == "Police" then return opt("ColorPolice", Color3.fromRGB(70, 150, 255)) end
    if team == "Criminal" then return opt("ColorCriminal", Color3.fromRGB(255, 70, 70)) end
    if team == "Prisoner" then return opt("ColorPrisoner", Color3.fromRGB(255, 170, 40)) end
    return Color3.new(1, 1, 1)
end

local function espCreate(player)
    local entry = {}

    local highlight = Instance.new("Highlight")
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.OutlineTransparency = 0
    highlight.Enabled = false
    highlight.Parent = EspFolder
    entry.Highlight = highlight

    local billboard = Instance.new("BillboardGui")
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.Size = UDim2.fromOffset(240, 64)
    billboard.StudsOffset = Vector3.new(0, 3.2, 0)
    billboard.Enabled = false
    billboard.Parent = EspFolder
    entry.Billboard = billboard

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextStrokeTransparency = 0.35
    label.TextYAlignment = Enum.TextYAlignment.Bottom
    label.Parent = billboard
    entry.Label = label

    entry.Tracer = newLine()
    entry.NextText = 0

    Esp[player] = entry
    return entry
end

local function espRemove(player)
    local entry = Esp[player]
    if not entry then return end
    entry.Highlight:Destroy()
    entry.Billboard:Destroy()
    entry.Tracer:Destroy()
    Esp[player] = nil
end

track(Players.PlayerRemoving:Connect(espRemove))

local function tracerOrigin()
    local choice = opt("TracerOrigin", "Bottom")
    local size = viewportSize()
    if choice == "Center" then return size / 2 end
    if choice == "Mouse" then return UserInputService:GetMouseLocation() end
    return Vector2.new(size.X / 2, size.Y - 2)
end

local function espUpdate()
    local enabled = on("ESP")
    local teams = opt("ESPTeams", {})
    local myRoot = getRoot()
    local now = os.clock()
    local origin = enabled and on("ESPTracers") and tracerOrigin()

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local entry = Esp[player] or espCreate(player)
            local character = player.Character
            local root = character and getRoot(character)
            local humanoid = character and getHumanoid(character)
            local team = teamName(player)
            local show = enabled and root ~= nil and humanoid ~= nil and humanoid.Health > 0 and teams[team] == true
            local distance = 0
            if show then
                distance = (root.Position - (myRoot and myRoot.Position or Camera.CFrame.Position)).Magnitude
                show = distance <= opt("ESPMaxDistance", 3000)
            end

            local color = teamColor(team)
            if show and on("ESPUseTarget") and Aim.Character == character then
                color = opt("ColorTarget", Color3.new(1, 1, 1))
            end

            local chams = show and on("ESPChams")
            entry.Highlight.Enabled = chams
            if chams then
                entry.Highlight.Adornee = character
                entry.Highlight.FillColor = color
                entry.Highlight.OutlineColor = color
                entry.Highlight.FillTransparency = opt("ESPFill", 0.65)
            end

            local text = show and (on("ESPName") or on("ESPDistance") or on("ESPHealth") or on("ESPItem") or on("ESPBounty"))
            entry.Billboard.Enabled = text
            if text then
                entry.Billboard.Adornee = character:FindFirstChild("Head") or root
                entry.Label.TextColor3 = color
                entry.Label.TextSize = opt("ESPTextSize", 13)
                if now >= entry.NextText then
                    entry.NextText = now + 0.15
                    local lines = {}
                    if on("ESPName") then
                        table.insert(lines, player.DisplayName)
                    end
                    local info = {}
                    if on("ESPDistance") then table.insert(info, ("%dm"):format(distance)) end
                    if on("ESPHealth") then table.insert(info, ("%d HP"):format(humanoid.Health)) end
                    if #info > 0 then table.insert(lines, table.concat(info, "  ")) end
                    if on("ESPItem") then
                        local item = equippedName(player)
                        if item then table.insert(lines, item) end
                    end
                    if on("ESPBounty") then
                        local bounty = Bounties[player.UserId]
                        if bounty and bounty > 0 then table.insert(lines, "Bounty " .. formatCash(bounty)) end
                    end
                    entry.Label.Text = table.concat(lines, "\n")
                end
            end

            local tracerShown = false
            if show and origin then
                local screen, onScreen = Camera:WorldToViewportPoint(root.Position)
                if onScreen and screen.Z > 0 then
                    drawLine(entry.Tracer, origin, Vector2.new(screen.X, screen.Y), color, opt("TracerThickness", 1))
                    tracerShown = true
                end
            end
            if not tracerShown then
                entry.Tracer.Visible = false
            end
        end
    end
end

--// World ESP -----------------------------------------------------------------
local WorldEsp = {}

local function worldEspSet(key, adornee, text, color, wanted)
    wanted[key] = true
    local entry = WorldEsp[key]
    if not entry then
        local billboard = Instance.new("BillboardGui")
        billboard.AlwaysOnTop = true
        billboard.LightInfluence = 0
        billboard.Size = UDim2.fromOffset(200, 36)
        billboard.Parent = EspFolder
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 13
        label.TextStrokeTransparency = 0.35
        label.Parent = billboard
        entry = { Billboard = billboard, Label = label }
        WorldEsp[key] = entry
    end
    entry.Billboard.Adornee = adornee
    entry.Label.Text = text
    entry.Label.TextColor3 = color
end

local function adorneeFor(instance)
    if instance:IsA("BasePart") or instance:IsA("Attachment") then return instance end
    if instance:IsA("Model") then
        return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function worldEspUpdate()
    local wanted = {}
    local root = getRoot()
    local function distanceTo(instance)
        local position = instancePosition(instance)
        if not position or not root then return "" end
        return (" [%dm]"):format((position - root.Position).Magnitude)
    end

    if on("ESPRobberies") then
        for _, robbery in ipairs(Robberies) do
            local instance = robberyInstance(robbery)
            local adornee = instance and adorneeFor(instance)
            if adornee then
                local status = robberyStatus(robbery)
                local color = status == STATUS.OPENED and Color3.fromRGB(90, 230, 110)
                    or status == STATUS.STARTED and Color3.fromRGB(255, 200, 60)
                    or Color3.fromRGB(230, 80, 80)
                worldEspSet("robbery:" .. robbery.Key, adornee, robbery.Name .. " (" .. statusText(status) .. ")" .. distanceTo(instance), color, wanted)
            end
        end
    end

    if on("ESPAirdrops") then
        for _, briefcase in ipairs(CollectionService:GetTagged("Briefcase")) do
            if briefcase:IsDescendantOf(Workspace) and briefcase:GetAttribute("BriefcaseCollected") ~= true then
                local adornee = adorneeFor(briefcase)
                if adornee then
                    worldEspSet(briefcase, adornee, "Airdrop" .. distanceTo(briefcase), Color3.fromRGB(120, 200, 255), wanted)
                end
            end
        end
    end

    if on("ESPCash") then
        for _, drop in ipairs(CollectionService:GetTagged("CashDrop")) do
            if drop:IsDescendantOf(Workspace) then
                local adornee = adorneeFor(drop)
                local amount = drop:FindFirstChild("Amount")
                if adornee then
                    local text = amount and formatCash(amount.Value) or "Cash"
                    worldEspSet(drop, adornee, text .. distanceTo(drop), Color3.fromRGB(110, 230, 120), wanted)
                end
            end
        end
    end

    if on("ESPVehicles") then
        local folder = Workspace:FindFirstChild("Vehicles")
        if folder and root then
            for _, model in ipairs(folder:GetChildren()) do
                if model:IsA("Model") and vehicleIsFree(model) then
                    local seat = model:FindFirstChild("Seat")
                    if seat and (seat.Position - root.Position).Magnitude <= 1500 then
                        worldEspSet(model, seat, model.Name .. distanceTo(seat), Color3.fromRGB(220, 220, 220), wanted)
                    end
                end
            end
        end
    end

    if on("ESPNPCs") then
        for _, npc in ipairs(getNpcs()) do
            local humanoid = getHumanoid(npc.Character)
            local npcRoot = getRoot(npc.Character)
            if humanoid and npcRoot and humanoid.Health > 0 then
                local text = ("%s  %d HP%s"):format(npc.Name, humanoid.Health, npc.Docile and " (docile)" or "")
                local color = npc.Docile and Color3.fromRGB(170, 170, 170) or Color3.fromRGB(255, 120, 60)
                worldEspSet(npc.Character, npc.Character:FindFirstChild("Head") or npcRoot, text .. distanceTo(npcRoot), color, wanted)
            end
        end
    end

    for key, entry in pairs(WorldEsp) do
        if not wanted[key] then
            entry.Billboard:Destroy()
            WorldEsp[key] = nil
        end
    end
end

--// Movement --------------------------------------------------------------------
local Movement = { SavedWalkSpeed = nil, SavedJumpPower = nil, SavedUseJumpPower = nil, NoclipWasOn = false }

track(UserInputService.JumpRequest:Connect(function()
    if on("InfiniteJump") then
        local humanoid = getHumanoid()
        if humanoid then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end))

local function movementStep()
    local humanoid = getHumanoid()
    if humanoid then
        if on("WalkSpeedOn") then
            if Movement.SavedWalkSpeed == nil then Movement.SavedWalkSpeed = humanoid.WalkSpeed end
            humanoid.WalkSpeed = opt("WalkSpeed", 30)
        elseif Movement.SavedWalkSpeed ~= nil then
            humanoid.WalkSpeed = Movement.SavedWalkSpeed
            Movement.SavedWalkSpeed = nil
        end

        if on("JumpPowerOn") then
            if Movement.SavedJumpPower == nil then
                Movement.SavedJumpPower = humanoid.JumpPower
                Movement.SavedUseJumpPower = humanoid.UseJumpPower
            end
            humanoid.UseJumpPower = true
            humanoid.JumpPower = opt("JumpPower", 75)
        elseif Movement.SavedJumpPower ~= nil then
            humanoid.JumpPower = Movement.SavedJumpPower
            humanoid.UseJumpPower = Movement.SavedUseJumpPower
            Movement.SavedJumpPower = nil
        end
    end
end

local function restoreMovement()
    local humanoid = getHumanoid()
    if humanoid then
        if Movement.SavedWalkSpeed then humanoid.WalkSpeed = Movement.SavedWalkSpeed end
        if Movement.SavedJumpPower then
            humanoid.JumpPower = Movement.SavedJumpPower
            humanoid.UseJumpPower = Movement.SavedUseJumpPower
        end
    end
end
onCleanup(restoreMovement)

-- Collisions are turned off before physics runs each frame. Turning noclip off
-- puts the character's collidable parts back.
local function noclipStep()
    local character = LocalPlayer.Character
    if not character then return end
    if on("Noclip") or (on("Fly") and not getVehicle()) then
        Movement.NoclipWasOn = true
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    elseif Movement.NoclipWasOn then
        Movement.NoclipWasOn = false
        for _, name in ipairs({ "HumanoidRootPart", "UpperTorso", "LowerTorso", "Head" }) do
            local part = character:FindFirstChild(name)
            if part and part:IsA("BasePart") then part.CanCollide = true end
        end
    end
end

local function flyStep()
    if not on("Fly") then return end
    if getVehicle() then return end
    local root = getRoot()
    if not root then return end
    local speed = opt("FlySpeed", 60)
    root.AssemblyLinearVelocity = flyVelocity(speed, speed * 0.8)
    root.AssemblyAngularVelocity = Vector3.zero
end

--// Vehicle mods ------------------------------------------------------------------
local PacketBackup = setmetatable({}, { __mode = "k" })
local CAR_FIELDS = { "EngineSpeedMult", "Height", "TurnSpeed", "GarageBrakes" }
local LastPacket = nil
local FlippedSince = nil

local function restorePacket(packet)
    local backup = packet and PacketBackup[packet]
    if not backup then return end
    for _, field in ipairs(CAR_FIELDS) do
        packet[field] = backup[field]
    end
    PacketBackup[packet] = nil
end

local function carModsStep()
    local model, packet, isDriver = getVehicle()

    if LastPacket and LastPacket ~= packet then
        restorePacket(LastPacket)
    end
    LastPacket = packet

    if not model or not isDriver then
        FlippedSince = nil
        return
    end

    if packet then
        local wantMods = on("CarSpeed") or on("CarTurn") or on("CarHeight") or on("CarBrakes")
        if wantMods then
            local backup = PacketBackup[packet]
            if not backup then
                backup = {}
                for _, field in ipairs(CAR_FIELDS) do backup[field] = packet[field] end
                PacketBackup[packet] = backup
            end
            if on("CarSpeed") then
                packet.EngineSpeedMult = (backup.EngineSpeedMult or 1) * opt("CarSpeedMult", 1.6)
            else
                packet.EngineSpeedMult = backup.EngineSpeedMult
            end
            if type(backup.TurnSpeed) == "number" then
                packet.TurnSpeed = on("CarTurn") and backup.TurnSpeed * opt("CarTurnMult", 1.5) or backup.TurnSpeed
            end
            if type(backup.Height) == "number" then
                packet.Height = on("CarHeight") and backup.Height * opt("CarHeightMult", 1.5) or backup.Height
            end
            if type(backup.GarageBrakes) == "number" then
                packet.GarageBrakes = on("CarBrakes") and backup.GarageBrakes + opt("CarBrakesAdd", 2) or backup.GarageBrakes
            end
        elseif PacketBackup[packet] then
            restorePacket(packet)
        end
    end

    if on("InfNitro") and VehicleUtils and type(VehicleUtils.nitroState) == "table" then
        local state = VehicleUtils.nitroState
        local max = tonumber(state.NitroLastMax) or 50
        if (tonumber(state.Nitro) or 0) < max then
            state.Nitro = max
            state.NitroForceUIUpdate = true
        end
    end

    if on("AntiFlip") and not on("CarFly") then
        local root = getVehicleRoot(model)
        if root then
            if root.CFrame.UpVector.Y < 0.2 then
                FlippedSince = FlippedSince or os.clock()
                if os.clock() - FlippedSince > 1.5 then
                    FlippedSince = nil
                    local look = root.CFrame.LookVector
                    local flat = Vector3.new(look.X, 0, look.Z)
                    if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
                    root.CFrame = CFrame.lookAt(root.Position + Vector3.new(0, 4, 0), root.Position + Vector3.new(0, 4, 0) + flat.Unit)
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end
            else
                FlippedSince = nil
            end
        end
    end
end

onCleanup(function()
    if LastPacket then restorePacket(LastPacket) end
end)

local function carFlyStep()
    if not on("CarFly") then return end
    local model, _, isDriver = getVehicle()
    if not model or not isDriver then return end
    local root = getVehicleRoot(model)
    if not root then return end
    local speed = opt("CarFlySpeed", 150)
    local velocity = flyVelocity(speed, speed * 0.6)
    if on("CarFlyFaceCamera") then
        local look = Camera.CFrame.LookVector
        local flat = Vector3.new(look.X, 0, look.Z)
        if flat.Magnitude > 0.01 then
            root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
        end
    end
    root.AssemblyLinearVelocity = velocity
    root.AssemblyAngularVelocity = Vector3.zero
end

local function carBoost()
    local model, _, isDriver = getVehicle()
    if not model or not isDriver then return end
    local root = getVehicleRoot(model)
    if not root then return end
    root.AssemblyLinearVelocity += root.CFrame.LookVector * opt("CarBoostPower", 120)
end

pcall(function()
    Options.CarBoostKey:OnClick(carBoost)
end)

--// Interaction helpers --------------------------------------------------------------
local SpecBackup = setmetatable({}, { __mode = "k" })
local SpecBusy = setmetatable({}, { __mode = "k" })

local function specPosition(spec)
    if typeof(spec.WorldPosition) == "Vector3" then return spec.WorldPosition end
    if typeof(spec.Attachment) == "Instance" and spec.Attachment.Parent then return spec.Attachment.WorldPosition end
    if typeof(spec.Part) == "Instance" and spec.Part.Parent then return spec.Part.Position end
    return nil
end

local function interactWords()
    local words = {}
    for word in string.gmatch(tostring(opt("AutoInteractWords", "")), "[^,]+") do
        word = word:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if word ~= "" then table.insert(words, word) end
    end
    return words
end

local function specMatches(spec, words)
    local name = type(spec.Name) == "string" and spec.Name:lower() or ""
    if name == "" then return false end
    for _, word in ipairs(words) do
        if string.find(name, word, 1, true) then return true end
    end
    return false
end

-- Applies (or undoes) instant prompts and range to every registered prompt.
local function specTweaksStep()
    if not CircleAction or type(CircleAction.Specs) ~= "table" then return end
    local instant = on("InstantInteract") and not Unloading
    local range = on("InteractRange") and not Unloading and opt("InteractRangeValue", 16)
    for _, spec in ipairs(CircleAction.Specs) do
        if type(spec) == "table" then
            local backup = SpecBackup[spec]
            if (instant or range) and not backup then
                backup = { Duration = spec.Duration, Dist = spec.Dist }
                SpecBackup[spec] = backup
            end
            if backup then
                if instant and spec.Timed and type(backup.Duration) == "number" then
                    spec.Duration = 0.05
                else
                    spec.Duration = backup.Duration
                end
                if range and type(backup.Dist) == "number" then
                    spec.Dist = math.max(backup.Dist, range)
                else
                    spec.Dist = backup.Dist
                end
                if not instant and not range then
                    SpecBackup[spec] = nil
                end
            end
        end
    end
end
onCleanup(specTweaksStep)

local function autoInteractStep()
    if not on("AutoInteract") or not CircleAction or type(CircleAction.Specs) ~= "table" then return end
    local root = getRoot()
    if not root then return end
    local words = interactWords()
    if #words == 0 then return end
    local range = opt("AutoInteractRange", 12)
    for _, spec in ipairs(CircleAction.Specs) do
        if type(spec) == "table" and not SpecBusy[spec] and spec.Enabled ~= false and type(spec.Callback) == "function" and specMatches(spec, words) then
            local position = specPosition(spec)
            if position and (position - root.Position).Magnitude <= range then
                SpecBusy[spec] = true
                task.spawn(function()
                    -- Same order the game uses: a press, the hold, then the
                    -- completed callback.
                    pcall(spec.Callback, spec, false)
                    if spec.Timed then
                        task.wait((tonumber(spec.Duration) or 0) + 0.05)
                    end
                    if not Unloading and on("AutoInteract") then
                        pcall(spec.Callback, spec, true)
                        if type(spec.ReleaseCallback) == "function" then
                            pcall(spec.ReleaseCallback, spec, true)
                        end
                    end
                    task.wait(0.6)
                    SpecBusy[spec] = nil
                end)
            end
        end
    end
end

--// Hazards ---------------------------------------------------------------------
local HAZARD_NAMES = { Laser = true, LaserTouch = true, BarbedWire = true, LavaKill = true, PowerWire = true }
local HAZARD_ANCESTORS = {
    Lasers = true, LasersMoving = true, LaserCarousel = true, VaultLaserControl = true,
    MovingLasers = true, MilitaryLasers = true, CamerasMoving = true, Spikes = true,
    InteractiveButtonLasers = true,
}
local Hazards = {}
local HazardConnection = nil

local function isHazard(part)
    if not part:IsA("BasePart") then return false end
    if HAZARD_NAMES[part.Name] then return true end
    if CollectionService:HasTag(part, "CasinoTriggerAlarm") then return true end
    if not part:FindFirstChildOfClass("TouchTransmitter") then return false end
    local ancestor = part.Parent
    for _ = 1, 6 do
        if not ancestor or ancestor == Workspace then break end
        if HAZARD_ANCESTORS[ancestor.Name] then return true end
        ancestor = ancestor.Parent
    end
    return false
end

local function disableHazard(part)
    if Hazards[part] == nil and isHazard(part) then
        Hazards[part] = part.CanTouch
        part.CanTouch = false
    end
end

local function setHazards(enabled)
    if enabled then
        if HazardConnection then return end
        for _, descendant in ipairs(Workspace:GetDescendants()) do
            disableHazard(descendant)
        end
        for _, part in ipairs(CollectionService:GetTagged("CasinoTriggerAlarm")) do
            disableHazard(part)
        end
        HazardConnection = Workspace.DescendantAdded:Connect(function(descendant)
            -- A part's TouchInterest can show up a moment after the part.
            task.defer(disableHazard, descendant)
        end)
    else
        if HazardConnection then
            HazardConnection:Disconnect()
            HazardConnection = nil
        end
        for part, canTouch in pairs(Hazards) do
            if part.Parent then part.CanTouch = canTouch end
        end
        table.clear(Hazards)
    end
end

Toggles.NoHazards:OnChanged(function(value)
    setHazards(value and not Unloading)
end)
onCleanup(function() setHazards(false) end)

--// Robbery status -------------------------------------------------------------------
local LastStatus = {}

local function robberyStatusStep()
    for _, robbery in ipairs(Robberies) do
        local status = robberyStatus(robbery)
        local label = StatusLabels[robbery]
        if label then
            label:SetText(robbery.Name .. ": " .. statusText(status))
        end
        local previous = LastStatus[robbery]
        if previous ~= nil and status ~= previous and status == STATUS.OPENED and on("NotifyRobberies") then
            notify("Robbery open", robbery.Name .. " just opened.", 5)
        end
        LastStatus[robbery] = status
    end
end

--// Utility -------------------------------------------------------------------------
local LightingBackup = nil
local FogBackup = nil
local FOVWasOn = false

local function lightingStep()
    if on("Fullbright") and not Unloading then
        if not LightingBackup then
            LightingBackup = {
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    elseif LightingBackup then
        for key, value in pairs(LightingBackup) do
            Lighting[key] = value
        end
        LightingBackup = nil
    end

    if on("NoFog") and not Unloading then
        if not FogBackup then
            local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
            FogBackup = { FogEnd = Lighting.FogEnd, Atmosphere = atmosphere, Density = atmosphere and atmosphere.Density }
        end
        Lighting.FogEnd = 1e6
        if FogBackup.Atmosphere then FogBackup.Atmosphere.Density = 0 end
    elseif FogBackup then
        Lighting.FogEnd = FogBackup.FogEnd
        if FogBackup.Atmosphere and FogBackup.Atmosphere.Parent then
            FogBackup.Atmosphere.Density = FogBackup.Density
        end
        FogBackup = nil
    end

    if on("CustomFOV") and not Unloading then
        FOVWasOn = true
        Camera.FieldOfView = opt("FOVValue", 90)
    elseif FOVWasOn then
        FOVWasOn = false
        Camera.FieldOfView = 70
    end
end
onCleanup(lightingStep)

track(LocalPlayer.Idled:Connect(function()
    if on("AntiAFK") then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

--// Mobile buttons ------------------------------------------------------------------
local MobilePanel = Instance.new("Frame")
MobilePanel.Name = "MobileButtons"
MobilePanel.AnchorPoint = Vector2.new(1, 0.5)
MobilePanel.Position = UDim2.new(1, -12, 0.45, 0)
MobilePanel.BackgroundColor3 = Color3.fromRGB(14, 14, 14)
MobilePanel.BackgroundTransparency = 0.25
MobilePanel.AutomaticSize = Enum.AutomaticSize.XY
MobilePanel.Visible = false
MobilePanel.Parent = Overlay
do
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = MobilePanel
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 151, 227)
    stroke.Transparency = 0.4
    stroke.Parent = MobilePanel
    local padding = Instance.new("UIPadding")
    for _, side in ipairs({ "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" }) do
        padding[side] = UDim.new(0, 6)
    end
    padding.Parent = MobilePanel
    local grid = Instance.new("UIGridLayout")
    grid.CellPadding = UDim2.fromOffset(6, 6)
    grid.FillDirectionMaxCells = 3
    grid.SortOrder = Enum.SortOrder.LayoutOrder
    grid.Parent = MobilePanel
end

local MobileButtons = {}

local function mobileButton(text, order)
    local button = Instance.new("TextButton")
    button.LayoutOrder = order
    button.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
    button.AutoButtonColor = true
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Text = text
    button.Parent = MobilePanel
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = button
    table.insert(MobileButtons, button)
    return button
end

local MobileToggles = {
    { Text = "Fly", Index = "Fly" },
    { Text = "Car fly", Index = "CarFly" },
    { Text = "Aim", Index = "SilentAim" },
    { Text = "Noclip", Index = "Noclip" },
    { Text = "ESP", Index = "ESP" },
    { Text = "Interact", Index = "AutoInteract" },
}

for order, info in ipairs(MobileToggles) do
    local button = mobileButton(info.Text, order)
    info.Button = button
    button.Activated:Connect(function()
        local toggle = Toggles[info.Index]
        if toggle then toggle:SetValue(not toggle.Value) end
    end)
end

local function holdButton(text, order, key)
    local button = mobileButton(text, order)
    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            MobileHold[key] = true
        end
    end)
    button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            MobileHold[key] = false
        end
    end)
    return button
end

holdButton("Up", 10, "Up")
holdButton("Fwd", 11, "Forward")
holdButton("Down", 12, "Down")
holdButton("Back", 14, "Back")
mobileButton("Boost", 13).Activated:Connect(carBoost)
mobileButton("Stop TP", 15).Activated:Connect(stopTravel)

-- Drag the panel by its background.
do
    local dragging, dragStart, startPosition
    MobilePanel.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, dragStart, startPosition = true, input.Position, MobilePanel.Position
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
            local delta = input.Position - dragStart
            MobilePanel.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))
end

local ACCENT = Color3.fromRGB(255, 151, 227)

local function mobileStep()
    local visible = on("MobileButtons")
    MobilePanel.Visible = visible
    if not visible then
        for key in pairs(MobileHold) do MobileHold[key] = false end
        return
    end
    local size = opt("MobileButtonSize", 52)
    local grid = MobilePanel:FindFirstChildOfClass("UIGridLayout")
    if grid then grid.CellSize = UDim2.fromOffset(size, math.floor(size * 0.75)) end
    for _, info in ipairs(MobileToggles) do
        local active = on(info.Index)
        info.Button.BackgroundColor3 = active and ACCENT or Color3.fromRGB(24, 24, 24)
        info.Button.TextColor3 = active and Color3.fromRGB(14, 14, 14) or Color3.new(1, 1, 1)
    end
end

--// Main loops ------------------------------------------------------------------
track(PreSimulation:Connect(function()
    if Unloading then return end
    noclipStep()
    flyStep()
    carFlyStep()
end))

track(PostSimulation:Connect(function()
    if Unloading then return end
    movementStep()
    carModsStep()
end))

track(PreRender:Connect(function()
    if Unloading then return end
    updateAimTarget()
    autoShootStep()

    local showCircle = on("SilentAim") and on("ShowFOV")
    FOVCircle.Visible = showCircle
    local origin = aimOrigin()
    if showCircle then
        local radius = opt("AimFOV", 150)
        FOVCircle.Size = UDim2.fromOffset(radius * 2, radius * 2)
        FOVCircle.Position = UDim2.fromOffset(origin.X, origin.Y)
        FOVStroke.Color = opt("FOVColor", ACCENT)
    end

    local part = Aim.Part
    local lineShown = false
    if part and part.Parent and on("SilentAim") and on("ShowAimTarget") then
        local screen, onScreen = Camera:WorldToViewportPoint(part.Position)
        if onScreen and screen.Z > 0 then
            drawLine(TargetLine, origin, Vector2.new(screen.X, screen.Y), opt("FOVColor", ACCENT), 1)
            lineShown = true
        end
        TargetLabel.Visible = true
        TargetLabel.Text = "Target: " .. tostring(Aim.Target and Aim.Target.Name or "?")
        TargetLabel.Position = UDim2.fromOffset(origin.X, origin.Y + opt("AimFOV", 150) + 6)
    else
        TargetLabel.Visible = false
    end
    if not lineShown then TargetLine.Visible = false end

    espUpdate()
end))

task.spawn(function()
    while not Unloading do
        specTweaksStep()
        autoInteractStep()
        TravelStatus:SetText(travelStatusText())
        mobileStep()
        task.wait(0.15)
    end
end)

task.spawn(function()
    while not Unloading do
        pcall(worldEspUpdate)
        pcall(robberyStatusStep)
        pcall(lightingStep)
        task.wait(1)
    end
end)

-- Fullbright fights the game's day/night cycle, so it's reapplied every frame
-- while on rather than once a second.
track(PostSimulation:Connect(function()
    if Unloading then return end
    if on("Fullbright") or on("CustomFOV") then
        lightingStep()
    end
end))

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or not on("ClickTP") then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not keyDown(Enum.KeyCode.LeftControl) then return end
    local mouse = UserInputService:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(mouse.X, mouse.Y)
    local mover = getMover()
    refreshTravelIgnore(mover)
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 5000, TravelRayParams)
    if hit then
        travelTo(hit.Position + Vector3.new(0, mover and mover.Vehicle and 6 or 4, 0), "clicked spot")
    end
end))

onCleanup(function()
    local humanoid = getHumanoid()
    if humanoid and Camera.CameraSubject ~= humanoid then
        Camera.CameraSubject = humanoid
    end
end)

--// Unload --------------------------------------------------------------------------
local unloadFromOutside

local function unload()
    if Unloading then return end
    Unloading = true
    stopTravel()
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    for _, player in ipairs(Players:GetPlayers()) do
        espRemove(player)
    end
    for _, cleanup in ipairs(Cleanups) do
        pcall(cleanup)
    end
    table.clear(Cleanups)
    if genv.JailbreakHubUnload == unloadFromOutside then
        genv.JailbreakHubUnload = nil
    end
end

unloadFromOutside = function()
    pcall(Library.Unload, Library)
    unload()
end

Library:OnUnload(unload)
genv.JailbreakHubUnload = unloadFromOutside

applyGunMods()
if on("NoHazards") then setHazards(true) end

notify("Jailbreak", Library.IsMobile and "Loaded. Tap Toggle to open the menu." or "Loaded. RightControl opens the menu.", 5)

--// 3008 -------------------------------------------------------------------------
-- Built against a script dump of the live game.
--
-- Nearly everything the client asks the server to do goes through two remotes
-- that live on your own character:
--
--   Character.System.Action : RemoteFunction : InvokeServer("Name", {table})
--   Character.System.Event  : RemoteEvent    : FireServer("Name", {table})
--
-- Verified signatures used below:
--   Action:InvokeServer("Pickup",            {Model = model})
--   Action:InvokeServer("Drop",              {EndCFrame = cf, Throw = bool,
--                                             CameraCFrame = v3, ThrowPower = n})
--   Action:InvokeServer("Store",             {Model = model})
--   Action:InvokeServer("Interact",          {Model = model})
--   Action:InvokeServer("Inventory_Consume", {Tool = toolName})
--   Action:InvokeServer("ShoveEmployee",     {Humanoid = humanoid})
--   Action:InvokeServer("Whistle")
--   Event :FireServer  ("FallDamage",        data)
--   Event :FireServer  ("DecreaseStat",      {Stats = {Energy = n}})
--
-- Where the server is authoritative, the UI says so instead of shipping a
-- toggle that only lies to your own HUD.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle -------------------------------------------------------------------
local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function spawnLoop(fn)
    return task.spawn(fn)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Config ----------------------------------------------------------------------
local Main = {
    AutoCollect = false,
    CollectRadius = 60,
    CollectFood = true,
    CollectAll = false,
    CollectDelay = 0.35,

    AutoEat = false,
    HungerThreshold = 40,
    AutoHeal = false,
    HealthThreshold = 50,

    RemoteShove = false,
    ShoveRadius = 40,
    ShoveDelay = 1.2,
}

local Finder = {
    Altitude = 400,
    RingStep = 350,
    MaxRings = 14,
    Dwell = 0.45,
    ReturnAfter = true,
    UseCache = true,
    Searching = false,
    Status = "idle",
}

local Player = {
    InfiniteEnergy = false,
    NoFallDamage = false,

    SpeedEnabled = false,
    WalkSpeed = 16,
    JumpEnabled = false,
    JumpPower = 50,
    InfiniteJump = false,
    Noclip = false,
    Fly = false,
    FlySpeed = 70,
    ReachEnabled = false,
    Reach = 30,
    AntiAFK = true,
}

local Visual = {
    Employees = false,
    Items = false,
    PlayersEsp = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    ShowDistance = true,
    ItemFilter = "Food",
    MaxEspDistance = 1500,

    Fullbright = false,
    NoFog = false,
    StripCeiling = false,
}

--// Paths -----------------------------------------------------------------------
local GameObjects = Workspace:WaitForChild("GameObjects", 20)
local Physical = GameObjects and GameObjects:WaitForChild("Physical", 20)
local EmployeesFolder = Physical and Physical:WaitForChild("Employees", 20)
local ItemsFolder = Physical and Physical:WaitForChild("Items", 20)
local MapFolder = Physical and Physical:WaitForChild("Map", 20)

-- Named specials worth a distinct colour - a BEAR 5 should not look like a
-- shelf stocker on your screen.
local SpecialEmployees = {
    ["BEAR 5"] = true, ["BEAR 5 PRIME"] = true, ["Jim Scary"] = true,
    ["King"] = true, ["Harold"] = true, ["Hubert"] = true, ["Dave"] = true,
    ["Ben"] = true, ["MrEgg"] = true, ["ChickenNugget"] = true,
    ["Snowball"] = true, ["Abomination Employee"] = true, ["EnergyOrb"] = true,
}

local FoodNames = {
    Pizza = true, Burger = true, Cookie = true, Hotdog = true, Chips = true,
    Lemon = true, ["Lemon Slice"] = true, Banana = true, Water = true,
    ["Ice Cream"] = true, ["Bloxy Soda"] = true, Medkit = true,
}

--// Character helpers ------------------------------------------------------------
local function getCharacter() return LocalPlayer.Character end

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

-- The System remotes are parented to the character, so they are replaced on
-- every respawn and must be re-fetched rather than cached at load.
local function getSystem()
    local char = getCharacter()
    local system = char and char:FindFirstChild("System")
    if not system then return nil, nil end
    return system:FindFirstChild("Action"), system:FindFirstChild("Event")
end

local function invokeAction(name, payload)
    local action = select(1, getSystem())
    if not action then return false, "no System.Action" end
    local ok, a, b = pcall(function() return action:InvokeServer(name, payload) end)
    if not ok then return false, tostring(a) end
    return a, b
end

--// Namecall hook: energy + fall damage -------------------------------------------
-- Both of these are the client volunteering something to the server. Dropping
-- the call is the whole exploit - there is nothing to spoof, just something
-- not to say.
local HAS_NAMECALL = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if HAS_NAMECALL then
    local originalNamecall
    originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if not Unloading and typeof(self) == "Instance" and getnamecallmethod() == "FireServer" then
            local okName = pcall(function() return self.Name end)
            if okName and self.Name == "Event" then
                local parent = self.Parent
                if parent and parent.Name == "System" then
                    local action = ...
                    if action == "FallDamage" and Player.NoFallDamage then
                        return
                    end
                    if action == "DecreaseStat" and Player.InfiniteEnergy then
                        return
                    end
                end
            end
        end
        return originalNamecall(self, ...)
    end)
end

-- The other half of infinite energy. Server-side drain still replicates down
-- and overwrites the attribute, but every gate that stops you sprinting or
-- sliding (StartRun / StartSlide) reads this value on the client, so keeping
-- it topped up keeps those gates open regardless of what the server thinks.
track(PostSimulation:Connect(function()
    if Unloading or not Player.InfiniteEnergy then return end
    local hum = getHumanoid()
    if not hum then return end
    local maxEnergy = hum:GetAttribute("MaxEnergy")
    if maxEnergy and (hum:GetAttribute("Energy") or 0) < maxEnergy then
        pcall(function() hum:SetAttribute("Energy", maxEnergy) end)
    end
end))

--// Last-known position cache -----------------------------------------------------
-- This game streams player characters out: a distant player's model still
-- replicates (Humanoid, scripts, clothing) but carries no BaseParts at all,
-- so there is no position to read. Recording positions while they ARE loaded
-- is the only way to teleport to someone instantly, and it costs nothing.
local lastSeen = {}

spawnLoop(function()
    while not Unloading do
        task.wait(0.25)
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then
                    lastSeen[plr] = { Position = root.Position, At = os.clock() }
                end
            end
        end
    end
end)

track(Players.PlayerRemoving:Connect(function(plr)
    lastSeen[plr] = nil
end))

local function isStreamedIn(plr)
    local char = plr.Character
    return (char and char:FindFirstChild("HumanoidRootPart")) ~= nil
end

--// Streaming radius probe ---------------------------------------------------------
-- The effective streaming radius is not readable as a property from the
-- client, and it decides how far apart the search rings can be. So measure it
-- instead of guessing: sample streamed-in map parts and report the furthest.
-- Sampled and capped, because Map can hold thousands of parts.
local measuredRadius = 0

spawnLoop(function()
    while not Unloading do
        task.wait(2)
        local root = getRoot()
        if root and MapFolder then
            local furthest = 0
            local budget = 400
            local origin = root.Position
            for _, folder in ipairs(MapFolder:GetChildren()) do
                if budget <= 0 then break end
                local children = folder:GetChildren()
                -- Stride through rather than walking every part: a sample is
                -- plenty to find the outer edge, and this keeps the probe off
                -- the frame budget entirely.
                local stride = math.max(1, math.floor(#children / 60))
                for i = 1, #children, stride do
                    if budget <= 0 then break end
                    local part = children[i]
                    local pivotOk, pivot = pcall(function() return part:GetPivot().Position end)
                    if pivotOk then
                        local d = (pivot - origin).Magnitude
                        if d > furthest then furthest = d end
                    end
                    budget = budget - 1
                end
            end
            if furthest > 0 then
                measuredRadius = furthest
            end
        end
    end
end)

--// Player finder ------------------------------------------------------------------
local function teleportTo(cframe)
    local root = getRoot()
    if not root or not cframe then return false end
    root.CFrame = cframe
    return true
end

local function requestStreamAround(position)
    pcall(function()
        LocalPlayer:RequestStreamAroundAsync(position)
    end)
end

-- Rings outward from wherever you are, at altitude. Height is the point: high
-- enough that you are not standing in someone's aisle while the chunk loads,
-- and the stream radius is spherical so altitude costs very little coverage.
--
-- Note this genuinely moves your character. RequestStreamAroundAsync alone is
-- best-effort and the server can stream the region straight back out, because
-- your ReplicationFocus stays on your character - so the character has to
-- actually go there for the chunk to hold.
local function searchForPlayer(plr, onUpdate)
    local root = getRoot()
    if not root then return false, "no character" end

    local origin = root.CFrame
    Finder.Searching = true

    local function finish(found, reason)
        Finder.Searching = false
        Finder.Status = reason
        if Finder.ReturnAfter then
            local rootNow = getRoot()
            if rootNow then rootNow.CFrame = origin end
        end
        return found, reason
    end

    local start = origin.Position
    local step = math.max(50, Finder.RingStep)

    for ring = 0, math.max(0, Finder.MaxRings) do
        if Unloading or not Finder.Searching then
            return finish(false, "cancelled")
        end

        -- Ring 0 is a single probe straight up from where you stand; each
        -- ring after that is a square perimeter, so nothing already covered
        -- gets revisited.
        local points = {}
        if ring == 0 then
            points[1] = Vector3.new(start.X, Finder.Altitude, start.Z)
        else
            local span = ring * step
            local count = math.max(1, ring * 2)
            for i = -count, count do
                local offset = (i / count) * span
                points[#points + 1] = Vector3.new(start.X + offset, Finder.Altitude, start.Z - span)
                points[#points + 1] = Vector3.new(start.X + offset, Finder.Altitude, start.Z + span)
                points[#points + 1] = Vector3.new(start.X - span, Finder.Altitude, start.Z + offset)
                points[#points + 1] = Vector3.new(start.X + span, Finder.Altitude, start.Z + offset)
            end
        end

        for index, point in ipairs(points) do
            if Unloading or not Finder.Searching then
                return finish(false, "cancelled")
            end

            Finder.Status = ("ring %d, point %d/%d"):format(ring, index, #points)
            if onUpdate then onUpdate(Finder.Status) end

            requestStreamAround(point)
            teleportTo(CFrame.new(point))
            task.wait(Finder.Dwell)

            if isStreamedIn(plr) then
                local target = plr.Character:FindFirstChild("HumanoidRootPart")
                if target then
                    -- Found: drop next to them rather than inside them.
                    Finder.Searching = false
                    Finder.Status = "found " .. plr.Name
                    local rootNow = getRoot()
                    if rootNow then
                        rootNow.CFrame = target.CFrame * CFrame.new(0, 0, 4)
                    end
                    return true, "found"
                end
            end
        end
    end

    return finish(false, "not found")
end

local function gotoPlayer(plr, onUpdate)
    if not plr then return false, "no target" end

    if isStreamedIn(plr) then
        local target = plr.Character:FindFirstChild("HumanoidRootPart")
        if target then
            teleportTo(target.CFrame * CFrame.new(0, 0, 4))
            return true, "already loaded"
        end
    end

    if Finder.UseCache then
        local cached = lastSeen[plr]
        if cached then
            requestStreamAround(cached.Position)
            teleportTo(CFrame.new(cached.Position + Vector3.new(0, 6, 0)))
            task.wait(Finder.Dwell)
            if isStreamedIn(plr) then
                local target = plr.Character:FindFirstChild("HumanoidRootPart")
                if target then
                    teleportTo(target.CFrame * CFrame.new(0, 0, 4))
                    return true, "from last known position"
                end
            end
            -- Cache was stale; fall through to the sweep.
        end
    end

    return searchForPlayer(plr, onUpdate)
end

--// Items ---------------------------------------------------------------------------
local function itemMatchesFilter(model)
    if Visual.ItemFilter == "All" then return true end
    if Visual.ItemFilter == "Food" then return FoodNames[model.Name] == true end
    return true
end

local function collectibleItems(radius, foodOnly)
    local root = getRoot()
    local list = {}
    if not root or not ItemsFolder then return list end
    for _, model in ipairs(ItemsFolder:GetChildren()) do
        if model:IsA("Model") then
            if not foodOnly or FoodNames[model.Name] then
                local ok, pivot = pcall(function() return model:GetPivot().Position end)
                if ok and (pivot - root.Position).Magnitude <= radius then
                    list[#list + 1] = model
                end
            end
        end
    end
    return list
end

-- Pickup takes a model reference and the range check lives on the client
-- (GetModelAtCrosshair), so this asks for items you are not looking at. If the
-- server re-validates distance it simply refuses - hence the radius slider,
-- so you can find where that limit actually is.
local function pickupModel(model)
    return invokeAction("Pickup", { Model = model })
end

local function storeModel(model)
    return invokeAction("Store", { Model = model })
end

-- Drop carries a client-supplied EndCFrame: the client decides where the held
-- item lands. That is what lets items be moved without moving yourself.
local function dropAt(cframe, throwPower)
    return invokeAction("Drop", {
        EndCFrame = cframe,
        Throw = false,
        CameraCFrame = Camera.CFrame.LookVector,
        ThrowPower = throwPower or 0,
    })
end

spawnLoop(function()
    while not Unloading do
        task.wait(Main.CollectDelay)
        if Main.AutoCollect and isAlive() then
            local items = collectibleItems(Main.CollectRadius, not Main.CollectAll and Main.CollectFood)
            for _, model in ipairs(items) do
                if Unloading or not Main.AutoCollect then break end
                if model.Parent then
                    local ok = pickupModel(model)
                    if ok then
                        -- Straight into the bag; holding it would block the
                        -- next pickup.
                        storeModel(model)
                    end
                    task.wait(0.15)
                end
            end
        end
    end
end)

--// Consumables ----------------------------------------------------------------------
local function inventoryToolNames()
    local names = {}
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then names[#names + 1] = tool.Name end
        end
    end
    local char = getCharacter()
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") then names[#names + 1] = tool.Name end
        end
    end
    return names
end

local function consume(toolName)
    return invokeAction("Inventory_Consume", { Tool = toolName })
end

-- Hunger and Health are server-authoritative in this game, so there is no
-- attribute to pin. Eating is the only real route, which makes automating it
-- the actual feature rather than a workaround.
spawnLoop(function()
    while not Unloading do
        task.wait(1.5)
        local hum = getHumanoid()
        if hum and isAlive() then
            if Main.AutoEat then
                local hunger = hum:GetAttribute("Hunger")
                if hunger and hunger <= Main.HungerThreshold then
                    for _, name in ipairs(inventoryToolNames()) do
                        if FoodNames[name] and name ~= "Medkit" then
                            consume(name)
                            break
                        end
                    end
                end
            end
            if Main.AutoHeal and hum.Health <= (hum.MaxHealth * (Main.HealthThreshold / 100)) then
                for _, name in ipairs(inventoryToolNames()) do
                    if name == "Medkit" then
                        consume("Medkit")
                        break
                    end
                end
            end
        end
    end
end)

--// Employees -------------------------------------------------------------------------
local function nearbyEmployees(radius)
    local root = getRoot()
    local list = {}
    if not root or not EmployeesFolder then return list end
    for _, model in ipairs(EmployeesFolder:GetChildren()) do
        local hum = model:FindFirstChildOfClass("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if hum and hrp and hum.Health > 0 then
            if (hrp.Position - root.Position).Magnitude <= radius then
                list[#list + 1] = { Model = model, Humanoid = hum }
            end
        end
    end
    return list
end

-- ShoveEmployee takes a Humanoid reference with no position in the payload,
-- same shape as Pickup, so range enforcement is the server's choice alone.
spawnLoop(function()
    while not Unloading do
        task.wait(Main.ShoveDelay)
        if Main.RemoteShove and isAlive() then
            for _, entry in ipairs(nearbyEmployees(Main.ShoveRadius)) do
                if Unloading or not Main.RemoteShove then break end
                invokeAction("ShoveEmployee", { Humanoid = entry.Humanoid })
                task.wait(0.1)
            end
        end
    end
end)

--// Movement ---------------------------------------------------------------------------
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
                if part:IsA("BasePart") and not part.CanCollide then
                    part.CanCollide = true
                end
            end
        end
        return
    end
    -- PreSimulation: collisions have to be cleared before the physics step
    -- resolves them, not after it has already pushed you out of the shelf.
    noclipConnection = PreSimulation:Connect(function()
        if not Player.Noclip or Unloading then return end
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
end

local function startFly()
    local root = getRoot()
    if not root then return end
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
    if Unloading or not Player.Fly then return end
    if not flyVelocity or not flyGyro then return end
    local direction = Vector3.new()
    local camCF = Camera.CFrame
    if flyDirection.Z ~= 0 then direction = direction + camCF.LookVector * -flyDirection.Z end
    if flyDirection.X ~= 0 then direction = direction + camCF.RightVector * flyDirection.X end
    if flyDirection.Y ~= 0 then direction = direction + Vector3.new(0, flyDirection.Y, 0) end
    if direction.Magnitude > 0 then
        flyVelocity.Velocity = direction.Unit * Player.FlySpeed
    else
        flyVelocity.Velocity = Vector3.new()
    end
    flyGyro.CFrame = camCF
end))

local flyKeys = {
    [Enum.KeyCode.W] = Vector3.new(0, 0, 1),
    [Enum.KeyCode.S] = Vector3.new(0, 0, -1),
    [Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
    [Enum.KeyCode.D] = Vector3.new(1, 0, 0),
    [Enum.KeyCode.Space] = Vector3.new(0, 1, 0),
    [Enum.KeyCode.LeftShift] = Vector3.new(0, -1, 0),
}

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloading or processed then return end
    local delta = flyKeys[input.KeyCode]
    if delta then flyDirection = flyDirection + delta end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if Unloading then return end
    local delta = flyKeys[input.KeyCode]
    if delta then flyDirection = flyDirection - delta end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloading or not Player.InfiniteJump then return end
    local hum = getHumanoid()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end) end
end))

track(PostSimulation:Connect(function()
    if Unloading then return end
    local hum = getHumanoid()
    if not hum then return end
    if Player.SpeedEnabled then hum.WalkSpeed = Player.WalkSpeed end
    if Player.JumpEnabled then hum.JumpPower = Player.JumpPower end
    -- ScrollDistance is the clamp on how far you can hold and place an item.
    -- It is a plain attribute the client reads, so raising it extends your
    -- legitimate placement reach without touching a remote.
    if Player.ReachEnabled then
        pcall(function() hum:SetAttribute("ScrollDistance", Player.Reach) end)
    end
end))

track(LocalPlayer.Idled:Connect(function()
    if Unloading or not Player.AntiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

track(LocalPlayer.CharacterAdded:Connect(function(char)
    char:WaitForChild("Humanoid", 10)
    if Player.Noclip then setNoclip(true) end
    if Player.Fly then task.wait(0.5) startFly() end
end))

--// ESP ---------------------------------------------------------------------------------
local espObjects = {}

local function espColor(kind, name)
    if kind == "Employee" then
        if SpecialEmployees[name] then return Color3.fromRGB(255, 70, 70) end
        return Color3.fromRGB(255, 150, 60)
    elseif kind == "Item" then
        return Color3.fromRGB(255, 220, 70)
    end
    return Color3.fromRGB(80, 180, 255)
end

local function espAnchor(model)
    return model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Head")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
end

local function destroyEsp(key)
    local objs = espObjects[key]
    if not objs then return end
    if objs.Highlight then objs.Highlight:Destroy() end
    if objs.Billboard then objs.Billboard:Destroy() end
    if objs.Box then pcall(function() objs.Box:Remove() end) end
    espObjects[key] = nil
end

local function buildEsp(model, label, kind)
    destroyEsp(model)
    local color = espColor(kind, model.Name)
    local objs = { Kind = kind, Method = Visual.Method, ShowNames = Visual.ShowNames }
    espObjects[model] = objs

    if Visual.Method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = color
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = model
        objs.Highlight = hl
    elseif typeof(Drawing) == "table" and Visual.Method == "Box" then
        pcall(function()
            local box = Drawing.new("Square")
            box.Thickness = 1.5
            box.Filled = false
            box.Color = color
            box.Visible = false
            objs.Box = box
        end)
    end

    if Visual.ShowNames then
        local anchor = espAnchor(model)
        if anchor then
            local billboard = Instance.new("BillboardGui")
            billboard.Name = "Esp3008"
            billboard.Adornee = anchor
            billboard.Size = UDim2.fromOffset(200, 34)
            billboard.StudsOffset = Vector3.new(0, 2, 0)
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
            objs.NameLabel = text
        end
    end
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.4)
        local root = getRoot()
        local seen = {}

        if root then
            local function consider(model, kind, label)
                local anchor = espAnchor(model)
                if not anchor then return end
                local dist = (anchor.Position - root.Position).Magnitude
                if dist > Visual.MaxEspDistance then return end
                seen[model] = true
                local objs = espObjects[model]
                if not objs or objs.Method ~= Visual.Method or objs.ShowNames ~= Visual.ShowNames then
                    buildEsp(model, label, kind)
                    objs = espObjects[model]
                end
                if objs then
                    if objs.Highlight then
                        objs.Highlight.FillTransparency = Visual.Transparency
                    end
                    if objs.NameLabel then
                        if Visual.ShowDistance then
                            objs.NameLabel.Text = ("%s [%d]"):format(label, math.floor(dist))
                        else
                            objs.NameLabel.Text = label
                        end
                    end
                end
            end

            if Visual.Employees and EmployeesFolder then
                for _, model in ipairs(EmployeesFolder:GetChildren()) do
                    local hum = model:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        consider(model, "Employee", model.Name)
                    end
                end
            end

            if Visual.Items and ItemsFolder then
                for _, model in ipairs(ItemsFolder:GetChildren()) do
                    if model:IsA("Model") and itemMatchesFilter(model) then
                        consider(model, "Item", model.Name)
                    end
                end
            end

            if Visual.PlayersEsp then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer and plr.Character then
                        consider(plr.Character, "Player", plr.Name)
                    end
                end
            end
        end

        for key in pairs(espObjects) do
            if not seen[key] then destroyEsp(key) end
        end
    end
end)

track(PreRender:Connect(function()
    if Unloading then return end
    for model, objs in pairs(espObjects) do
        if objs.Box then
            if not model.Parent then
                destroyEsp(model)
            else
                local anchor = espAnchor(model)
                if anchor then
                    local top, onScreen = Camera:WorldToViewportPoint(anchor.Position + Vector3.new(0, 3, 0))
                    local bottom = Camera:WorldToViewportPoint(anchor.Position - Vector3.new(0, 3, 0))
                    if onScreen then
                        local height = bottom.Y - top.Y
                        local width = height * 0.6
                        objs.Box.Visible = true
                        objs.Box.Transparency = 1 - Visual.Transparency
                        objs.Box.Position = Vector2.new(top.X - width / 2, top.Y)
                        objs.Box.Size = Vector2.new(width, height)
                    else
                        objs.Box.Visible = false
                    end
                end
            end
        end
    end
end))

--// World visuals ---------------------------------------------------------------------
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

-- Purely local: hiding the ceiling only changes your own view, nobody else
-- sees through anything, and it comes back when the chunk re-streams.
local strippedParts = setmetatable({}, { __mode = "k" })

local function setCeilingHidden(state)
    if not MapFolder then return end
    for _, name in ipairs({ "Ceiling", "CeilingDecor" }) do
        local folder = MapFolder:FindFirstChild(name)
        if folder then
            for _, descendant in ipairs(folder:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    if state then
                        if strippedParts[descendant] == nil then
                            strippedParts[descendant] = descendant.LocalTransparencyModifier
                        end
                        descendant.LocalTransparencyModifier = 1
                    elseif strippedParts[descendant] ~= nil then
                        descendant.LocalTransparencyModifier = strippedParts[descendant]
                        strippedParts[descendant] = nil
                    end
                end
            end
        end
    end
end

--// UI ---------------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = '3008',
    SubTitle = 'assist',
    Folder = '3008Assist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 190, 60),
})

local function notify(content, kind, duration)
    Centrl:Notify({
        Title = '3008',
        Content = content,
        Type = kind or 'success',
        Duration = duration or 5,
    })
end

if not Physical then
    notify('Workspace.GameObjects.Physical not found - the game may have changed.', 'error', 8)
end

--// Main tab
local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })

local FindSection = MainTab:Section({ Title = 'find player', Side = 'left' })
local FindStatus = FindSection:Label({ Title = 'status: idle' })

local selectedPlayer = nil
local playerDropdown = FindSection:Dropdown({
    Title = 'player',
    Flag = 'tv_find_target',
    Options = { 'none' },
    Default = 'none',
    Callback = function(v) selectedPlayer = v end,
})

FindSection:Button({
    Title = 'refresh players',
    Callback = function()
        local names = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local mark = isStreamedIn(plr) and ' (loaded)' or (lastSeen[plr] and ' (cached)' or '')
                names[#names + 1] = plr.Name .. mark
            end
        end
        if #names == 0 then names = { 'none' } end
        pcall(function() playerDropdown:SetOptions(names) end)
    end,
})

local function resolveSelected()
    if not selectedPlayer or selectedPlayer == 'none' then return nil end
    local clean = selectedPlayer:gsub(" %(loaded%)", ""):gsub(" %(cached%)", "")
    return Players:FindFirstChild(clean)
end

FindSection:Button({
    Title = 'go to player',
    Callback = function()
        local target = resolveSelected()
        if not target then
            notify('Pick a player first (refresh the list).', 'warning')
            return
        end
        spawnLoop(function()
            local ok, reason = gotoPlayer(target, function(status)
                pcall(function() FindStatus:Set('status: ' .. status) end)
            end)
            pcall(function() FindStatus:Set('status: ' .. tostring(reason)) end)
            if ok then
                notify(('Reached %s (%s).'):format(target.Name, tostring(reason)))
            else
                notify(('Could not reach %s: %s'):format(target.Name, tostring(reason)), 'error', 6)
            end
        end)
    end,
})

FindSection:Button({
    Title = 'stop search',
    Callback = function()
        Finder.Searching = false
        pcall(function() FindStatus:Set('status: cancelled') end)
    end,
})

local SweepSection = MainTab:Section({ Title = 'sweep settings', Side = 'right' })

SweepSection:Toggle({
    Title = 'use last known position first',
    Flag = 'tv_use_cache',
    Default = true,
    Callback = function(v) Finder.UseCache = v end,
})

SweepSection:Slider({
    Title = 'search altitude',
    Flag = 'tv_altitude',
    Min = 100,
    Max = 2000,
    Increment = 50,
    Default = 400,
    Suffix = ' studs',
    Callback = function(v) Finder.Altitude = v end,
})

SweepSection:Slider({
    Title = 'ring spacing',
    Flag = 'tv_ring_step',
    Min = 100,
    Max = 1000,
    Increment = 50,
    Default = 350,
    Suffix = ' studs',
    Callback = function(v) Finder.RingStep = v end,
})

SweepSection:Slider({
    Title = 'max rings',
    Flag = 'tv_max_rings',
    Min = 1,
    Max = 30,
    Increment = 1,
    Default = 14,
    Callback = function(v) Finder.MaxRings = v end,
})

SweepSection:Slider({
    Title = 'dwell per point',
    Flag = 'tv_dwell',
    Min = 0.15,
    Max = 2,
    Increment = 0.05,
    Default = 0.45,
    Suffix = 's',
    Callback = function(v) Finder.Dwell = v end,
})

SweepSection:Toggle({
    Title = 'return to start after',
    Flag = 'tv_return',
    Default = true,
    Callback = function(v) Finder.ReturnAfter = v end,
})

local radiusLabel = SweepSection:Label({ Title = 'measured stream radius: --' })

SweepSection:Paragraph({
    Title = 'tuning the spacing',
    Text = 'Set ring spacing to roughly the measured stream radius above, or a little under it so rings overlap. Too wide and the sweep skips over people; too narrow and it just takes longer. The sweep genuinely moves you - a stream request alone gets undone because the server keeps your replication focus on your character.',
})

local LootSection = MainTab:Section({ Title = 'looting', Side = 'left' })

LootSection:Toggle({
    Title = 'auto collect',
    Flag = 'tv_auto_collect',
    Default = false,
    Callback = function(v) Main.AutoCollect = v end,
})

LootSection:Toggle({
    Title = 'collect everything (not just food)',
    Flag = 'tv_collect_all',
    Default = false,
    Callback = function(v) Main.CollectAll = v end,
})

LootSection:Slider({
    Title = 'collect radius',
    Flag = 'tv_collect_radius',
    Min = 10,
    Max = 500,
    Increment = 10,
    Default = 60,
    Suffix = ' studs',
    Callback = function(v) Main.CollectRadius = v end,
})

LootSection:Button({
    Title = 'collect nearest item now',
    Callback = function()
        local items = collectibleItems(Main.CollectRadius, not Main.CollectAll)
        if #items == 0 then
            notify('Nothing in range.', 'warning')
            return
        end
        local ok = pickupModel(items[1])
        notify(ok and ('Picked up ' .. items[1].Name) or 'Server refused the pickup.', ok and 'success' or 'warning')
    end,
})

LootSection:Paragraph({
    Title = 'range is the experiment',
    Text = 'Pickup takes a model reference and the range check is client side, so this asks for items you are not looking at. If the server checks distance it just refuses - raise the radius until pickups start failing and you have found the real limit.',
})

local ActionSection = MainTab:Section({ Title = 'actions', Side = 'right' })

ActionSection:Toggle({
    Title = 'auto eat when hungry',
    Flag = 'tv_auto_eat',
    Default = false,
    Callback = function(v) Main.AutoEat = v end,
})

ActionSection:Slider({
    Title = 'eat below hunger',
    Flag = 'tv_hunger_threshold',
    Min = 5,
    Max = 90,
    Increment = 5,
    Default = 40,
    Callback = function(v) Main.HungerThreshold = v end,
})

ActionSection:Toggle({
    Title = 'auto medkit',
    Flag = 'tv_auto_heal',
    Default = false,
    Callback = function(v) Main.AutoHeal = v end,
})

ActionSection:Slider({
    Title = 'heal below health %',
    Flag = 'tv_health_threshold',
    Min = 10,
    Max = 90,
    Increment = 5,
    Default = 50,
    Callback = function(v) Main.HealthThreshold = v end,
})

ActionSection:Toggle({
    Title = 'auto shove employees',
    Flag = 'tv_remote_shove',
    Default = false,
    Callback = function(v) Main.RemoteShove = v end,
})

ActionSection:Slider({
    Title = 'shove radius',
    Flag = 'tv_shove_radius',
    Min = 5,
    Max = 300,
    Increment = 5,
    Default = 40,
    Suffix = ' studs',
    Callback = function(v) Main.ShoveRadius = v end,
})

ActionSection:Button({
    Title = 'whistle',
    Callback = function()
        local ok = invokeAction("Whistle")
        notify(ok and 'Whistled.' or 'Whistle refused (15s cooldown).', ok and 'success' or 'warning')
    end,
})

ActionSection:Button({
    Title = 'drop held item here',
    Callback = function()
        local root = getRoot()
        if not root then return end
        local ok = dropAt(root.CFrame * CFrame.new(0, 0, -4))
        notify(ok and 'Dropped.' or 'Nothing held, or server refused.', ok and 'success' or 'warning')
    end,
})

ActionSection:Paragraph({
    Title = 'why health and hunger have no toggle',
    Text = 'Both are server-owned in this game: the client only ever reads them to draw the bars. Pinning them would make your HUD lie while you still starve, so eating and medkits are automated instead. Energy is different - the client decides whether you can sprint, which is why infinite energy is real.',
})

--// Player tab
local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local StatsSection = PlayerTab:Section({ Title = 'stats', Side = 'left' })

StatsSection:Toggle({
    Title = 'infinite energy',
    Flag = 'tv_inf_energy',
    Default = false,
    Callback = function(v)
        Player.InfiniteEnergy = v
        if v and not HAS_NAMECALL then
            notify('No namecall hooking on this executor - energy is pinned locally but slide drain still reaches the server.', 'warning', 6)
        end
    end,
})

StatsSection:Toggle({
    Title = 'no fall damage',
    Flag = 'tv_no_fall',
    Default = false,
    Callback = function(v)
        Player.NoFallDamage = v
        if v and not HAS_NAMECALL then
            notify('No namecall hooking on this executor - fall damage cannot be blocked.', 'error', 6)
        end
    end,
})

StatsSection:Paragraph({
    Title = 'how these work',
    Text = 'Your client volunteers both of these. It calculates its own fall damage and asks the server to apply it, and it spends its own energy when sliding. Blocking those two calls is the entire trick - nothing is being faked.',
})

local MoveSection = PlayerTab:Section({ Title = 'movement', Side = 'right' })

MoveSection:Toggle({
    Title = 'walkspeed',
    Flag = 'tv_speed_enabled',
    Default = false,
    Callback = function(v)
        Player.SpeedEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.WalkSpeed = 16 end
        end
    end,
})

MoveSection:Slider({
    Title = 'walkspeed value',
    Flag = 'tv_walkspeed',
    Min = 16,
    Max = 250,
    Increment = 2,
    Default = 16,
    Callback = function(v) Player.WalkSpeed = v end,
})

MoveSection:Toggle({
    Title = 'jump power',
    Flag = 'tv_jump_enabled',
    Default = false,
    Callback = function(v)
        Player.JumpEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.JumpPower = 50 end
        end
    end,
})

MoveSection:Slider({
    Title = 'jump power value',
    Flag = 'tv_jumppower',
    Min = 50,
    Max = 400,
    Increment = 10,
    Default = 50,
    Callback = function(v) Player.JumpPower = v end,
})

MoveSection:Toggle({
    Title = 'infinite jump',
    Flag = 'tv_inf_jump',
    Default = false,
    Callback = function(v) Player.InfiniteJump = v end,
})

MoveSection:Toggle({
    Title = 'noclip',
    Flag = 'tv_noclip',
    Default = false,
    Callback = function(v)
        Player.Noclip = v
        setNoclip(v)
    end,
})

MoveSection:Toggle({
    Title = 'fly',
    Flag = 'tv_fly',
    Default = false,
    Callback = function(v)
        Player.Fly = v
        if v then startFly() else stopFly() end
    end,
})

MoveSection:Slider({
    Title = 'fly speed',
    Flag = 'tv_fly_speed',
    Min = 10,
    Max = 400,
    Increment = 10,
    Default = 70,
    Callback = function(v) Player.FlySpeed = v end,
})

local ReachSection = PlayerTab:Section({ Title = 'reach', Side = 'left' })

ReachSection:Toggle({
    Title = 'extended item reach',
    Flag = 'tv_reach_enabled',
    Default = false,
    Callback = function(v) Player.ReachEnabled = v end,
})

ReachSection:Slider({
    Title = 'reach distance',
    Flag = 'tv_reach',
    Min = 5,
    Max = 200,
    Increment = 5,
    Default = 30,
    Suffix = ' studs',
    Callback = function(v) Player.Reach = v end,
})

ReachSection:Toggle({
    Title = 'anti afk',
    Flag = 'tv_anti_afk',
    Default = true,
    Callback = function(v) Player.AntiAFK = v end,
})

ReachSection:Paragraph({
    Title = 'reach',
    Text = 'ScrollDistance is the attribute clamping how far you can hold and place an item. It is read on the client, so raising it extends how far out you can carry and position things without touching a remote at all.',
})

--// Visual tab
local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'employee esp',
    Flag = 'tv_esp_employees',
    Default = false,
    Callback = function(v) Visual.Employees = v end,
})

EspSection:Toggle({
    Title = 'item esp',
    Flag = 'tv_esp_items',
    Default = false,
    Callback = function(v) Visual.Items = v end,
})

EspSection:Toggle({
    Title = 'player esp',
    Flag = 'tv_esp_players',
    Default = false,
    Callback = function(v) Visual.PlayersEsp = v end,
})

EspSection:Dropdown({
    Title = 'item filter',
    Flag = 'tv_item_filter',
    Options = { 'Food', 'All' },
    Default = 'Food',
    Callback = function(v) Visual.ItemFilter = v end,
})

EspSection:Dropdown({
    Title = 'method',
    Flag = 'tv_esp_method',
    Options = { 'Highlight', 'Box' },
    Default = 'Highlight',
    Callback = function(v) Visual.Method = v end,
})

local EspConfigSection = VisualTab:Section({ Title = 'esp config', Side = 'right' })

EspConfigSection:Toggle({
    Title = 'names',
    Flag = 'tv_esp_names',
    Default = true,
    Callback = function(v) Visual.ShowNames = v end,
})

EspConfigSection:Toggle({
    Title = 'distance',
    Flag = 'tv_esp_distance',
    Default = true,
    Callback = function(v) Visual.ShowDistance = v end,
})

EspConfigSection:Slider({
    Title = 'transparency',
    Flag = 'tv_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) Visual.Transparency = v end,
})

EspConfigSection:Slider({
    Title = 'max esp distance',
    Flag = 'tv_esp_max_dist',
    Min = 100,
    Max = 5000,
    Increment = 100,
    Default = 1500,
    Suffix = ' studs',
    Callback = function(v) Visual.MaxEspDistance = v end,
})

EspConfigSection:Paragraph({
    Title = 'colours',
    Text = 'Named specials (BEAR 5, BEAR 5 PRIME, Jim Scary, King, Harold, Hubert, Dave, Ben, MrEgg, ChickenNugget, Snowball, Abomination) draw red so they never get mistaken for an ordinary employee, which draws orange. Items are yellow, players blue.',
})

local WorldSection = VisualTab:Section({ Title = 'world', Side = 'left' })

WorldSection:Toggle({
    Title = 'fullbright',
    Flag = 'tv_fullbright',
    Default = false,
    Callback = function(v)
        Visual.Fullbright = v
        applyFullbright(v)
    end,
})

WorldSection:Toggle({
    Title = 'no fog',
    Flag = 'tv_no_fog',
    Default = false,
    Callback = function(v)
        Visual.NoFog = v
        applyNoFog(v)
    end,
})

WorldSection:Toggle({
    Title = 'hide ceiling',
    Flag = 'tv_strip_ceiling',
    Default = false,
    Callback = function(v)
        Visual.StripCeiling = v
        setCeilingHidden(v)
    end,
})

WorldSection:Paragraph({
    Title = 'hide ceiling',
    Text = 'Local only - it changes your view and nothing else, nobody else sees through anything. Newly streamed chunks come back solid, so toggle it again after moving a long way.',
})

--// Settings tab
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'left' })

local systemLabel = DiagSection:Label({ Title = 'System remotes: checking' })
local streamLabel = DiagSection:Label({ Title = 'stream radius: --' })
local cacheLabel = DiagSection:Label({ Title = 'cached players: 0' })

spawnLoop(function()
    while not Unloading do
        task.wait(1)

        local action, event = getSystem()
        local systemText
        if action and event then
            systemText = 'System remotes: found (Action + Event)'
        elseif action or event then
            systemText = 'System remotes: partial'
        else
            systemText = 'System remotes: missing'
        end
        pcall(function() systemLabel:Set(systemText) end)

        local radiusText = measuredRadius > 0
            and ('stream radius: ~%d studs'):format(math.floor(measuredRadius))
            or 'stream radius: measuring...'
        pcall(function() streamLabel:Set(radiusText) end)
        pcall(function() radiusLabel:Set('measured stream radius: ' .. (measuredRadius > 0 and (math.floor(measuredRadius) .. ' studs') or '--')) end)

        local count = 0
        for _ in pairs(lastSeen) do count = count + 1 end
        pcall(function() cacheLabel:Set(('cached players: %d'):format(count)) end)
    end
end)

DiagSection:Paragraph({
    Title = 'stream radius',
    Text = 'Measured live by sampling how far the furthest loaded map part sits from you, because the real streaming radius is not readable as a property from the client. Use it to set the ring spacing on the main tab rather than guessing.',
})

local ControlSection = SettingsTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'clear position cache',
    Callback = function()
        for key in pairs(lastSeen) do lastSeen[key] = nil end
        notify('Position cache cleared.')
    end,
})

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        Finder.Searching = false

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end

        for key in pairs(espObjects) do destroyEsp(key) end
        setNoclip(false)
        stopFly()
        applyFullbright(false)
        applyNoFog(false)
        setCeilingHidden(false)

        local hum = getHumanoid()
        if hum then
            hum.WalkSpeed = 16
            hum.JumpPower = 50
        end

        Centrl:Unload()
    end,
})

ControlSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every loop and hook, clears ESP, restores lighting, collisions and your walkspeed. The namecall hook itself cannot be removed without rejoining, but it goes inert once unloaded.',
})

Window:Load()

notify('Loaded. RightShift toggles the menu.', 'success', 5)

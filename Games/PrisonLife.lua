local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
end)

local DEFAULT_WALKSPEED = 16
local DEFAULT_JUMPPOWER = 50

local Config = {
    SilentAim = false,
    TeamCheck = true,
    WallCheck = true,
    AimPart = "Head",
    MaxRange = 300,
    FOVEnabled = true,
    FOVRadius = 360,
    FOVTransparency = 0.6,

    InfiniteAmmo = false,

    InstaKillPunch = false,
    PunchHits = 10,

    ClickTP = false,

    SpeedEnabled = false,
    WalkSpeed = DEFAULT_WALKSPEED,
    JumpEnabled = false,
    JumpPower = DEFAULT_JUMPPOWER,
}

local ESPConfig = {
    Enabled = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    TeamColor = true,
}

local function getHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

--// Silent aim ----------------------------------------------------------------
-- Ported from a working reference implementation: it locates the internal
-- "castRay" function every gun actually raycasts through (found at runtime
-- via getgc, since it isn't exposed by name anywhere reachable statically)
-- and hookfunction's it to redirect the shot, instead of guessing at
-- ShootEvent's argument shape. Falls back to the old camera-lock technique
-- if the executor doesn't support getgc/hookfunction.
local function isHostile(char)
    local ok, val = pcall(function() return char:GetAttribute("Hostile") end)
    if ok and val ~= nil then return val == true end
    local v = char:FindFirstChild("Hostile")
    if v and v:IsA("BoolValue") then return v.Value end
    return false
end

local function canDamage(plr)
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if char:FindFirstChild("ForceField") then return false end
    if Config.TeamCheck then
        local myTeam, theirTeam = LocalPlayer.Team, plr.Team
        if myTeam and theirTeam and myTeam == theirTeam then return false end
        if myTeam and myTeam.Name == "Guards" and not isHostile(char) then return false end
    end
    return true
end

local function isVisible(char, origin)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = LocalPlayer.Character and { LocalPlayer.Character } or {}

    local checkParts = {
        char:FindFirstChild(Config.AimPart),
        char:FindFirstChild("Head"),
        char:FindFirstChild("HumanoidRootPart"),
        char:FindFirstChild("UpperTorso"),
        char:FindFirstChild("LowerTorso"),
        char:FindFirstChild("Torso"),
    }

    for _, part in ipairs(checkParts) do
        if part then
            local dir = part.Position - origin
            local dist = dir.Magnitude
            if dist > 0 then
                local result = Workspace:Raycast(origin, dir, params)
                if not result or result.Instance:FindFirstAncestorOfClass("Model") == char then
                    return part
                end
            end
        end
    end

    return nil
end

local function getSilentAimTarget(origin)
    if typeof(origin) ~= "Vector3" then
        origin = Camera and Camera.CFrame.Position or Vector3.new()
    end
    if not Camera then return nil end

    local bestDist = Config.FOVEnabled and Config.FOVRadius or math.huge
    local bestPart = nil
    local mouse = UserInputService:GetMouseLocation()

    for _, plr in pairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and canDamage(plr) then
            local char = plr.Character
            local part = char:FindFirstChild(Config.AimPart) or char:FindFirstChild("Head")
            if part and (Config.MaxRange <= 0 or (origin - part.Position).Magnitude <= Config.MaxRange) then
                local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen and (part.Position - Camera.CFrame.Position):Dot(Camera.CFrame.LookVector) > 0 then
                    local screenDist = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
                    if screenDist < bestDist then
                        local finalPart = part
                        if Config.WallCheck then
                            finalPart = isVisible(char, origin)
                        else
                            local params = RaycastParams.new()
                            params.FilterType = Enum.RaycastFilterType.Exclude
                            params.FilterDescendantsInstances = LocalPlayer.Character and { LocalPlayer.Character } or {}
                            local result = Workspace:Raycast(origin, part.Position - origin, params)
                            if result and result.Instance:FindFirstAncestorOfClass("Model") ~= char then
                                finalPart = nil
                            end
                        end
                        if finalPart then
                            bestPart, bestDist = finalPart, screenDist
                        end
                    end
                end
            end
        end
    end

    return bestPart
end

local function getToolAttribute(tool, attr)
    if typeof(tool) == "Instance" then
        local ok, val = pcall(function() return tool:GetAttribute(attr) end)
        if ok then return val end
    end
    return nil
end

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

    local dir = aim - origin
    if dir.Magnitude <= 0 then dir = Vector3.new(0, 0, -1) end

    local range = getToolAttribute(tool, "Range") or 200

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = LocalPlayer.Character and { LocalPlayer.Character } or {}
    params.CollisionGroup = "ClientBullet"

    local result = Workspace:Raycast(origin, dir.Unit * range, params)
    if result then
        return result.Instance, result.Position
    end
    return nil, origin + dir.Unit * range
end

local function hookedCast(p1, p2, p3)
    if not Config.SilentAim then
        return normalCast(p1, p2, p3)
    end

    local origin
    if typeof(p1) == "Vector3" then origin = p1
    elseif typeof(p2) == "Vector3" then origin = p2
    elseif typeof(p3) == "Vector3" then origin = p3 end

    if origin then
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and (origin - root.Position).Magnitude <= 75 then
            local ok, target = pcall(getSilentAimTarget, origin)
            if ok and target and target.Parent then
                return target, target.Position
            end
        end
    end

    return normalCast(p1, p2, p3)
end

local silentAimHookAvailable = typeof(getgc) == "function" and typeof(hookfunction) == "function"
    and typeof(debug) == "table" and typeof(debug.getinfo) == "function"

if silentAimHookAvailable then
    task.spawn(function()
        local hooked = {}
        for _ = 1, 20 do
            pcall(function()
                for _, func in next, getgc(true) do
                    if type(func) == "function" and not hooked[func] then
                        local info = debug.getinfo(func, "nS")
                        if info and info.name == "castRay" then
                            pcall(hookfunction, func, hookedCast)
                            hooked[func] = true
                        end
                    end
                end
            end)
            task.wait(3)
        end
    end)
else
    -- Fallback: camera-lock at Camera render priority + 1, so any mouse-aimed
    -- fire logic reads the redirected orientation without us touching the
    -- camera module's own stored angles.
    RunService:BindToRenderStep("PrisonLifeSilentAimFallback", Enum.RenderPriority.Camera.Value + 1, function()
        if not Config.SilentAim then return end
        local target = getSilentAimTarget(Camera.CFrame.Position)
        if not target then return end
        Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, target.Position)
    end)
end

local fovCircle = nil
if typeof(Drawing) == "table" then
    pcall(function()
        fovCircle = Drawing.new("Circle")
        fovCircle.Thickness = 1.5
        fovCircle.NumSides = 48
        fovCircle.Filled = false
        fovCircle.Color = Color3.fromRGB(255, 255, 255)
        fovCircle.Visible = false
    end)
end

RunService.RenderStepped:Connect(function()
    if not fovCircle then return end
    local show = Config.SilentAim and Config.FOVEnabled
    fovCircle.Visible = show
    if show then
        fovCircle.Radius = Config.FOVRadius
        -- Drawing's Transparency is opacity-flavored (1 = fully opaque), the
        -- opposite of Roblox's own convention, so the slider (Roblox-style,
        -- higher = more see-through) gets inverted here.
        fovCircle.Transparency = 1 - Config.FOVTransparency
        fovCircle.Position = UserInputService:GetMouseLocation()
    end
end)

--// ESP ------------------------------------------------------------------------
local espObjects = {}

local function espColorFor(plr)
    if ESPConfig.TeamColor then
        local myTeam = LocalPlayer.Team
        if myTeam and plr.Team == myTeam then
            return Color3.fromRGB(80, 220, 120)
        end
    end
    return Color3.fromRGB(230, 60, 60)
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
    local objs = { Char = char, Method = ESPConfig.Method, ShowNames = ESPConfig.ShowNames }
    espObjects[plr] = objs

    if ESPConfig.Method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = espColorFor(plr)
        hl.OutlineColor = espColorFor(plr)
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = char
        objs.Highlight = hl
    elseif typeof(Drawing) == "table" then
        pcall(function()
            if ESPConfig.Method == "Box" then
                local box = Drawing.new("Square")
                box.Thickness = 1.5
                box.Filled = false
                box.Color = espColorFor(plr)
                box.Visible = false
                objs.Box = box
            elseif ESPConfig.Method == "Tracers" then
                local line = Drawing.new("Line")
                line.Thickness = 1.5
                line.Color = espColorFor(plr)
                line.Visible = false
                objs.Tracer = line
            end
        end)
    end

    if ESPConfig.ShowNames then
        local head = char:FindFirstChild("Head")
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "PrisonLifeESPName"
        billboard.Adornee = head or char.PrimaryPart
        billboard.Size = UDim2.fromOffset(160, 36)
        billboard.StudsOffset = Vector3.new(0, 1.2, 0)
        billboard.AlwaysOnTop = true
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = espColorFor(plr)
        label.TextStrokeTransparency = 0.5
        label.Text = plr.Name
        label.Parent = billboard
        billboard.Parent = char
        objs.Billboard = billboard
        objs.NameLabel = label
    end
end

Players.PlayerRemoving:Connect(destroyEspFor)

task.spawn(function()
    while true do
        task.wait(0.5)
        if ESPConfig.Enabled then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    local char = plr.Character
                    local objs = espObjects[plr]
                    if not char then
                        if objs then destroyEspFor(plr) end
                    elseif not objs or objs.Char ~= char or objs.Method ~= ESPConfig.Method or objs.ShowNames ~= ESPConfig.ShowNames then
                        buildEspFor(plr, char)
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

RunService.RenderStepped:Connect(function()
    if not ESPConfig.Enabled then return end
    for plr, objs in pairs(espObjects) do
        local char = plr.Character
        if not char or not char.Parent then
            destroyEspFor(plr)
        else
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local color = espColorFor(plr)

            if objs.Highlight then
                objs.Highlight.FillTransparency = ESPConfig.Transparency
                objs.Highlight.FillColor = color
                objs.Highlight.OutlineColor = color
            end

            if objs.NameLabel and hrp then
                local dist = (Camera.CFrame.Position - hrp.Position).Magnitude
                objs.NameLabel.Text = ("%s [%d]"):format(plr.Name, math.floor(dist))
                objs.NameLabel.TextColor3 = color
            end

            if objs.Box and hrp then
                local head = char:FindFirstChild("Head")
                local topPos = head and (head.Position + Vector3.new(0, 0.5, 0)) or (hrp.Position + Vector3.new(0, 2, 0))
                local bottomPos = hrp.Position - Vector3.new(0, 3, 0)
                local topScreen, topOnScreen = Camera:WorldToViewportPoint(topPos)
                local bottomScreen = Camera:WorldToViewportPoint(bottomPos)
                if topOnScreen then
                    local height = bottomScreen.Y - topScreen.Y
                    local width = height * 0.6
                    objs.Box.Visible = true
                    objs.Box.Color = color
                    objs.Box.Transparency = 1 - ESPConfig.Transparency
                    objs.Box.Position = Vector2.new(topScreen.X - width / 2, topScreen.Y)
                    objs.Box.Size = Vector2.new(width, height)
                else
                    objs.Box.Visible = false
                end
            end

            if objs.Tracer and hrp then
                local screenPoint, onScreen = Camera:WorldToViewportPoint(hrp.Position)
                if onScreen then
                    objs.Tracer.Visible = true
                    objs.Tracer.Color = color
                    objs.Tracer.Transparency = 1 - ESPConfig.Transparency
                    objs.Tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                    objs.Tracer.To = Vector2.new(screenPoint.X, screenPoint.Y)
                else
                    objs.Tracer.Visible = false
                end
            end
        end
    end
end)

--// Gun mods -------------------------------------------------------------------
-- Attributes set directly on your own Tool instances - the fire script that
-- would actually read these wasn't in the dump either, so which of these
-- functionally matter vs. get silently re-validated server-side is unverified.
-- Applied to every Tool in both Character and Backpack that already has the
-- attribute, so it covers your whole loadout, not just whatever's equipped.
-- Every toggle/slider applies immediately on change (not just the poll loop
-- below) so dragging a slider updates your held gun's behavior right away.
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
    local char = LocalPlayer.Character
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
            tool:SetAttribute(stat.Key, cfg.Value)
        end
    end
    if AutoFireConfig.Enabled and tool:GetAttribute("AutoFire") ~= nil then
        tool:SetAttribute("AutoFire", AutoFireConfig.Value)
    end
    if Config.InfiniteAmmo then
        local maxAmmo = tool:GetAttribute("MaxAmmo")
        if maxAmmo ~= nil and tool:GetAttribute("CurrentAmmo") ~= nil then
            tool:SetAttribute("CurrentAmmo", maxAmmo)
        end
    end
end

local function applyGunModsNow()
    forEachOwnedTool(applyGunModsToTool)
end

task.spawn(function()
    while true do
        task.wait(0.03)
        applyGunModsNow()
    end
end)

--// Insta kill punch -----------------------------------------------------------
-- Confirmed from the dump: both ClientInputHandler (bare fists) and
-- MeleeToolScript (melee tools) resolve a hit locally, then just call
-- meleeEvent:FireServer(target, arg2, 1) - a per-swing flag stops the client
-- from calling it more than once per swing, but nothing server-visible in
-- either script suggests the server itself rate-limits the remote. Hooking
-- __namecall replays whatever real call the game's own script makes N times
-- instead of reimplementing hit detection - it only ever fires calls the
-- unmodified game logic already decided were legitimate.
local meleeEvent = ReplicatedStorage:WaitForChild("meleeEvent")
local originalNamecall = nil
local instaKillHookAvailable = false

if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local ok = pcall(function()
        originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if Config.InstaKillPunch and self == meleeEvent and getnamecallmethod() == "FireServer" then
                local args = { ... }
                for _ = 1, Config.PunchHits do
                    originalNamecall(self, table.unpack(args))
                end
                return
            end
            return originalNamecall(self, ...)
        end)
    end)
    instaKillHookAvailable = ok
end

--// Click TP (mobile-aware) ----------------------------------------------------
local function performClickTP(screenPos)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or not Camera then return end

    local ray = Camera:ViewportPointToRay(screenPos.X, screenPos.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char }

    local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
    if result then
        hrp.CFrame = CFrame.new(result.Position + Vector3.new(0, 3, 0))
    end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or not Config.ClickTP then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        performClickTP(Vector2.new(input.Position.X, input.Position.Y))
    end
end)

--// Player stats (speed / jump) ------------------------------------------------
-- Only ever writes WalkSpeed/JumpPower while its own toggle is on, so it
-- never fights the game's own changes (crouch, prone, being tased). The
-- toggle's own callback does a one-time reset back to the Roblox default the
-- moment it's switched off, satisfying "back to normal" without a
-- continuous fight the rest of the time.
task.spawn(function()
    while true do
        task.wait(0.1)
        local humanoid = getHumanoid()
        if humanoid then
            if Config.SpeedEnabled and humanoid.WalkSpeed ~= Config.WalkSpeed then
                humanoid.WalkSpeed = Config.WalkSpeed
            end
            if Config.JumpEnabled and humanoid.JumpPower ~= Config.JumpPower then
                humanoid.JumpPower = Config.JumpPower
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    local humanoid = char:WaitForChild("Humanoid", 5)
    if not humanoid then return end
    if Config.SpeedEnabled then humanoid.WalkSpeed = Config.WalkSpeed end
    if Config.JumpEnabled then humanoid.JumpPower = Config.JumpPower end
end)

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'prison life',
    SubTitle = 'assist',
    Folder = 'PrisonLifeAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(70, 160, 255),
})

local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })

local SilentAimSection = MainTab:Section({ Title = 'silent aim', Side = 'left' })

SilentAimSection:Toggle({
    Title = 'silent aim',
    Flag = 'pl_silent_aim',
    Default = false,
    Callback = function(v) Config.SilentAim = v end,
})

SilentAimSection:Toggle({
    Title = 'team check',
    Flag = 'pl_team_check',
    Default = true,
    Callback = function(v) Config.TeamCheck = v end,
})

SilentAimSection:Toggle({
    Title = 'wall check',
    Flag = 'pl_wall_check',
    Default = true,
    Callback = function(v) Config.WallCheck = v end,
})

SilentAimSection:Dropdown({
    Title = 'aim at',
    Flag = 'pl_aim_part',
    Options = { 'Head', 'HumanoidRootPart', 'UpperTorso', 'Torso' },
    Default = 'Head',
    Callback = function(v) Config.AimPart = v end,
})

SilentAimSection:Slider({
    Title = 'max range',
    Flag = 'pl_max_range',
    Min = 0,
    Max = 1500,
    Increment = 25,
    Default = 300,
    Suffix = ' studs',
    Callback = function(v) Config.MaxRange = v end,
})

local FovSection = MainTab:Section({ Title = 'fov circle', Side = 'right' })

FovSection:Toggle({
    Title = 'fov',
    Flag = 'pl_fov',
    Default = true,
    Callback = function(v) Config.FOVEnabled = v end,
})

FovSection:Slider({
    Title = 'fov size',
    Flag = 'pl_fov_size',
    Min = 20,
    Max = 800,
    Increment = 5,
    Default = 360,
    Suffix = ' px',
    Callback = function(v) Config.FOVRadius = v end,
})

FovSection:Slider({
    Title = 'fov transparency',
    Flag = 'pl_fov_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.6,
    Callback = function(v) Config.FOVTransparency = v end,
})

FovSection:Paragraph({
    Title = 'targeting',
    Text = 'FOV off targets anyone visible on screen. FOV on restricts targeting (and the drawn circle) to the radius above, centered on your mouse cursor.',
})

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Flag = 'pl_esp_enabled',
    Default = false,
    Callback = function(v) ESPConfig.Enabled = v end,
})

EspSection:Dropdown({
    Title = 'esp method',
    Flag = 'pl_esp_method',
    Options = { 'Highlight', 'Box', 'Tracers' },
    Default = 'Highlight',
    Callback = function(v) ESPConfig.Method = v end,
})

EspSection:Toggle({
    Title = 'show names',
    Flag = 'pl_esp_names',
    Default = true,
    Callback = function(v) ESPConfig.ShowNames = v end,
})

local EspConfigSection = VisualTab:Section({ Title = 'esp config', Side = 'right' })

EspConfigSection:Slider({
    Title = 'transparency',
    Flag = 'pl_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) ESPConfig.Transparency = v end,
})

EspConfigSection:Toggle({
    Title = 'team color',
    Flag = 'pl_esp_teamcolor',
    Default = true,
    Callback = function(v) ESPConfig.TeamColor = v end,
})

EspConfigSection:Paragraph({
    Title = 'methods',
    Text = 'Highlight sees through walls by default. Box and Tracers need a Drawing-capable executor and only draw while the target is on screen.',
})

local GunModsTab = Window:Tab({ Title = 'gun mods', Icon = 'wrench' })
local StatsSection = GunModsTab:Section({ Title = 'stat overrides', Side = 'left' })

for _, stat in ipairs(GunModStats) do
    StatsSection:Toggle({
        Title = stat.Title,
        Flag = 'pl_gm_' .. stat.Key .. '_enabled',
        Default = false,
        Callback = function(v)
            GunModConfig[stat.Key].Enabled = v
            applyGunModsNow()
        end,
    })
    StatsSection:Slider({
        Title = stat.Title .. ' value',
        Flag = 'pl_gm_' .. stat.Key .. '_value',
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

local MiscSection = GunModsTab:Section({ Title = 'misc', Side = 'right' })

MiscSection:Toggle({
    Title = 'auto fire (force full-auto)',
    Flag = 'pl_gm_autofire',
    Default = false,
    Callback = function(v)
        AutoFireConfig.Enabled = v
        applyGunModsNow()
    end,
})

MiscSection:Toggle({
    Title = 'infinite ammo',
    Flag = 'pl_gm_infinite_ammo',
    Default = false,
    Callback = function(v)
        Config.InfiniteAmmo = v
        applyGunModsNow()
    end,
})

MiscSection:Paragraph({
    Title = 'what actually works',
    Text = "These write Attributes on your own gun instances - the fire script that reads them wasn't in the dump, so this isn't fully verified. Fire Rate / Spread Radius / Reload Time gate your own client's input timing and are the most likely to matter. Damage is the most likely to be re-checked server-side and stay cosmetic only.",
})

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local PunchSection = PlayerTab:Section({ Title = 'insta kill punch', Side = 'left' })

local InstaKillToggle = PunchSection:Toggle({
    Title = 'insta kill punch',
    Flag = 'pl_instakill',
    Default = false,
    Callback = function(v)
        if v and not instaKillHookAvailable then
            Centrl:Notify({
                Title = 'prison life',
                Content = 'hookmetamethod is not available on this executor - insta kill punch needs it.',
                Type = 'error',
                Duration = 5,
            })
            Config.InstaKillPunch = false
            InstaKillToggle:Set(false, true)
            return
        end
        Config.InstaKillPunch = v
    end,
})

PunchSection:Slider({
    Title = 'hits per punch',
    Flag = 'pl_instakill_hits',
    Min = 1,
    Max = 1000,
    Increment = 5,
    Default = 10,
    Callback = function(v) Config.PunchHits = v end,
})

local PunchInfo = PlayerTab:Section({ Title = 'behavior', Side = 'right' })
PunchInfo:Paragraph({
    Title = 'how it works',
    Text = "Every landed punch (fists or a melee tool) still calls the game's real meleeEvent once, same as normal - this just replays that exact same call the number of times set above, so one real hit becomes that many damage instances instead of a bigger single number.",
})

local MovementSection = PlayerTab:Section({ Title = 'movement', Side = 'left' })

MovementSection:Toggle({
    Title = 'click tp',
    Flag = 'pl_click_tp',
    Default = false,
    Callback = function(v) Config.ClickTP = v end,
})

MovementSection:Paragraph({
    Title = 'mobile support',
    Text = 'Works with a tap the same as a click - checks both MouseButton1 and Touch input.',
})

local StatsPlayerSection = PlayerTab:Section({ Title = 'stats', Side = 'right' })

StatsPlayerSection:Toggle({
    Title = 'walkspeed',
    Flag = 'pl_speed_enabled',
    Default = false,
    Callback = function(v)
        Config.SpeedEnabled = v
        local humanoid = getHumanoid()
        if humanoid then
            humanoid.WalkSpeed = v and Config.WalkSpeed or DEFAULT_WALKSPEED
        end
    end,
})

StatsPlayerSection:Slider({
    Title = 'walkspeed value',
    Flag = 'pl_speed_value',
    Min = 16,
    Max = 300,
    Increment = 1,
    Default = DEFAULT_WALKSPEED,
    Callback = function(v)
        Config.WalkSpeed = v
        if Config.SpeedEnabled then
            local humanoid = getHumanoid()
            if humanoid then humanoid.WalkSpeed = v end
        end
    end,
})

StatsPlayerSection:Toggle({
    Title = 'jump power',
    Flag = 'pl_jump_enabled',
    Default = false,
    Callback = function(v)
        Config.JumpEnabled = v
        local humanoid = getHumanoid()
        if humanoid then
            humanoid.JumpPower = v and Config.JumpPower or DEFAULT_JUMPPOWER
        end
    end,
})

StatsPlayerSection:Slider({
    Title = 'jump power value',
    Flag = 'pl_jump_value',
    Min = 50,
    Max = 400,
    Increment = 5,
    Default = DEFAULT_JUMPPOWER,
    Callback = function(v)
        Config.JumpPower = v
        if Config.JumpEnabled then
            local humanoid = getHumanoid()
            if humanoid then humanoid.JumpPower = v end
        end
    end,
})

Window:Load()

Centrl:Notify({
    Title = 'prison life',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

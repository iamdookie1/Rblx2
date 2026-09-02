local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
end)

local Events = ReplicatedStorage:WaitForChild("Events", 10)
local Remotes = Events and Events:WaitForChild("Remotes", 10)
local RequestCharacterAction = Remotes and Remotes:WaitForChild("RequestCharacterAction", 10)

local Config = {
    SilentAim = false,
    AimMode = "Camera",
    AimPart = "Head",
    TargetPlayers = true,
    TargetMonsters = true,
    MaxRange = 400,
    FOVEnabled = true,
    FOVRadius = 200,
    FOVTransparency = 0.6,
    WallCheck = true,

    SpeedEnabled = false,
    WalkSpeed = 32,
    SpeedBoost = 0,

    InfiniteStats = false,
}

local ESPConfig = {
    Enabled = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    Players = true,
    Monsters = true,
    Items = false,
}

local function getAimPart(model)
    return model:FindFirstChild(Config.AimPart) or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
end

local function hasLineOfSight(fromPos, toPos, ignoreInstances)
    if not Config.WallCheck then return true end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = ignoreInstances
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true
    local dir = toPos - fromPos
    local ok, result = pcall(function() return Workspace:Raycast(fromPos, dir, params) end)
    if not ok or not result then return true end
    return (result.Position - fromPos).Magnitude >= dir.Magnitude - 1.5
end

local function collectCandidates()
    local list = {}
    if Config.TargetPlayers then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if char and hum and hum.Health > 0 then
                    list[#list + 1] = { Model = char }
                end
            end
        end
    end
    if Config.TargetMonsters then
        local monsters = Workspace:FindFirstChild("_Monsters")
        if monsters then
            for _, model in ipairs(monsters:GetChildren()) do
                if model:IsA("Model") then
                    local hum = model:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        list[#list + 1] = { Model = model }
                    end
                end
            end
        end
    end
    return list
end

local function getBestTarget()
    local myChar = LocalPlayer.Character
    if not myChar then return nil end
    local camPos = Camera.CFrame.Position
    local viewSize = Camera.ViewportSize
    local center = Vector2.new(viewSize.X / 2, viewSize.Y / 2)

    local best, bestScore
    for _, candidate in ipairs(collectCandidates()) do
        local aimPart = getAimPart(candidate.Model)
        if aimPart then
            local distance = (aimPart.Position - camPos).Magnitude
            if distance <= Config.MaxRange then
                local screenPos, onScreen = Camera:WorldToViewportPoint(aimPart.Position)
                if onScreen then
                    local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                    if not Config.FOVEnabled or screenDist <= Config.FOVRadius then
                        if hasLineOfSight(camPos, aimPart.Position, { myChar, candidate.Model }) then
                            if not bestScore or screenDist < bestScore then
                                bestScore = screenDist
                                best = aimPart
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local HAS_NAMECALL_HOOK = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"
local originalNamecall

if HAS_NAMECALL_HOOK and RequestCharacterAction then
    originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if Config.SilentAim and Config.AimMode == "Silent" and self == RequestCharacterAction and getnamecallmethod() == "FireServer" then
            local action, payload = ...
            if action == "UseItem" and typeof(payload) == "table" and payload.MousePosition ~= nil then
                local aimPart = getBestTarget()
                if aimPart then
                    local newPayload = {}
                    for k, v in pairs(payload) do newPayload[k] = v end
                    newPayload.MousePosition = aimPart.Position
                    return originalNamecall(self, action, newPayload)
                end
            end
        end
        return originalNamecall(self, ...)
    end)
end

local function applyCameraLock()
    if not (Config.SilentAim and Config.AimMode == "Camera") then return end
    local aimPart = getBestTarget()
    if not aimPart then return end
    Camera.CFrame = CFrame.new(Camera.CFrame.Position, aimPart.Position)
end

pcall(function()
    RunService:BindToRenderStep("SurvivalAimLock", Enum.RenderPriority.Camera.Value + 1, applyCameraLock)
end)

local fovCircle
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

    local show = Config.FOVEnabled
    fovCircle.Visible = show
    if show then
        fovCircle.Radius = Config.FOVRadius

        fovCircle.Transparency = 1 - Config.FOVTransparency
        fovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
end)

local espObjects = {}

local function espColorFor(kind)
    if kind == "Monster" then return Color3.fromRGB(255, 170, 60) end
    if kind == "Item" then return Color3.fromRGB(255, 220, 60) end
    return Color3.fromRGB(230, 60, 60)
end

local function espAnchor(model, kind)
    if kind == "Item" then
        return model:FindFirstChild("Handle") or model.PrimaryPart
    end
    return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
end

local function destroyEsp(model)
    local objs = espObjects[model]
    if not objs then return end
    if objs.Highlight then objs.Highlight:Destroy() end
    if objs.Billboard then objs.Billboard:Destroy() end
    if objs.Box then pcall(function() objs.Box:Remove() end) end
    if objs.Tracer then pcall(function() objs.Tracer:Remove() end) end
    espObjects[model] = nil
end

local function buildEsp(model, name, kind)
    destroyEsp(model)
    local color = espColorFor(kind)
    local objs = { Method = ESPConfig.Method, ShowNames = ESPConfig.ShowNames, Kind = kind }
    espObjects[model] = objs

    if ESPConfig.Method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = color
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = model
        objs.Highlight = hl
    elseif typeof(Drawing) == "table" then
        pcall(function()
            if ESPConfig.Method == "Box" then
                local box = Drawing.new("Square")
                box.Thickness = 1.5
                box.Filled = false
                box.Color = color
                box.Visible = false
                objs.Box = box
            elseif ESPConfig.Method == "Tracers" then
                local line = Drawing.new("Line")
                line.Thickness = 1.5
                line.Color = color
                line.Visible = false
                objs.Tracer = line
            end
        end)
    end

    if ESPConfig.ShowNames then
        local anchor = espAnchor(model, kind)
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "SurvivalESPName"
        billboard.Adornee = anchor or model.PrimaryPart
        billboard.Size = UDim2.fromOffset(160, 36)
        billboard.StudsOffset = Vector3.new(0, 1.2, 0)
        billboard.AlwaysOnTop = true
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 14
        label.TextColor3 = color
        label.TextStrokeTransparency = 0.5
        label.Text = name
        label.Parent = billboard
        billboard.Parent = model
        objs.Billboard = billboard
        objs.NameLabel = label
    end
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if ESPConfig.Enabled then
            local seen = {}

            if ESPConfig.Players then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer then
                        local char = plr.Character
                        local hum = char and char:FindFirstChildOfClass("Humanoid")
                        if char and hum and hum.Health > 0 then
                            seen[char] = true
                            local objs = espObjects[char]
                            if not objs or objs.Method ~= ESPConfig.Method or objs.ShowNames ~= ESPConfig.ShowNames then
                                buildEsp(char, plr.Name, "Player")
                                objs = espObjects[char]
                            end
                            if objs then
                                local color = espColorFor("Player")
                                if objs.Highlight then
                                    objs.Highlight.FillTransparency = ESPConfig.Transparency
                                    objs.Highlight.FillColor = color
                                    objs.Highlight.OutlineColor = color
                                end
                                if objs.NameLabel then
                                    local hrp = char:FindFirstChild("HumanoidRootPart")
                                    local dist = hrp and (Camera.CFrame.Position - hrp.Position).Magnitude or 0
                                    objs.NameLabel.Text = ("%s [%d]"):format(plr.Name, math.floor(dist))
                                end
                            end
                        end
                    end
                end
            end

            if ESPConfig.Monsters then
                local monsters = Workspace:FindFirstChild("_Monsters")
                if monsters then
                    for _, model in ipairs(monsters:GetChildren()) do
                        if model:IsA("Model") then
                            local hum = model:FindFirstChildOfClass("Humanoid")
                            if hum and hum.Health > 0 then
                                seen[model] = true
                                local objs = espObjects[model]
                                if not objs or objs.Method ~= ESPConfig.Method or objs.ShowNames ~= ESPConfig.ShowNames then
                                    buildEsp(model, model.Name, "Monster")
                                    objs = espObjects[model]
                                end
                                if objs then
                                    local color = espColorFor("Monster")
                                    if objs.Highlight then
                                        objs.Highlight.FillTransparency = ESPConfig.Transparency
                                        objs.Highlight.FillColor = color
                                        objs.Highlight.OutlineColor = color
                                    end
                                    if objs.NameLabel then
                                        local hrp = model:FindFirstChild("HumanoidRootPart")
                                        local dist = hrp and (Camera.CFrame.Position - hrp.Position).Magnitude or 0
                                        objs.NameLabel.Text = ("%s [%d]"):format(model.Name, math.floor(dist))
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if ESPConfig.Items then
                local items = Workspace:FindFirstChild("_Items")
                if items then
                    for _, model in ipairs(items:GetChildren()) do
                        if model:IsA("Model") and model:FindFirstChild("Handle") then
                            seen[model] = true
                            local objs = espObjects[model]
                            if not objs or objs.Method ~= ESPConfig.Method or objs.ShowNames ~= ESPConfig.ShowNames then
                                buildEsp(model, model.Name, "Item")
                                objs = espObjects[model]
                            end
                            if objs then
                                local color = espColorFor("Item")
                                if objs.Highlight then
                                    objs.Highlight.FillTransparency = ESPConfig.Transparency
                                    objs.Highlight.FillColor = color
                                    objs.Highlight.OutlineColor = color
                                end
                                if objs.NameLabel then
                                    local handle = model:FindFirstChild("Handle")
                                    local dist = handle and (Camera.CFrame.Position - handle.Position).Magnitude or 0
                                    objs.NameLabel.Text = ("%s [%d]"):format(model.Name, math.floor(dist))
                                end
                            end
                        end
                    end
                end
            end

            for model in pairs(espObjects) do
                if not seen[model] then destroyEsp(model) end
            end
        else
            for model in pairs(espObjects) do
                destroyEsp(model)
            end
        end
    end
end)

RunService.RenderStepped:Connect(function()
    if not ESPConfig.Enabled then return end
    for model, objs in pairs(espObjects) do
        if not model.Parent then
            destroyEsp(model)
        else
            local anchor = espAnchor(model, objs.Kind)
            local color = espColorFor(objs.Kind)

            if objs.Box and anchor then

                local topPos, bottomPos
                if objs.Kind == "Item" then
                    topPos = anchor.Position + Vector3.new(0, 0.75, 0)
                    bottomPos = anchor.Position - Vector3.new(0, 0.75, 0)
                else
                    local head = model:FindFirstChild("Head")
                    topPos = head and (head.Position + Vector3.new(0, 0.5, 0)) or (anchor.Position + Vector3.new(0, 2, 0))
                    bottomPos = anchor.Position - Vector3.new(0, 3, 0)
                end
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

            if objs.Tracer and anchor then
                local screenPoint, onScreen = Camera:WorldToViewportPoint(anchor.Position)
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
end)

Players.PlayerRemoving:Connect(function(plr)
    local char = plr.Character
    if char then destroyEsp(char) end
end)

local originalWalkSpeed = nil

RunService.Heartbeat:Connect(function(dt)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hum then return end

    if Config.SpeedEnabled then
        if originalWalkSpeed == nil then
            originalWalkSpeed = hum.WalkSpeed
        end
        hum.WalkSpeed = Config.WalkSpeed

        if hrp and Config.SpeedBoost > 0 then
            local moveDir = hum.MoveDirection
            if moveDir.Magnitude > 0.05 then
                hrp.CFrame = hrp.CFrame + moveDir.Unit * Config.SpeedBoost * dt
            end
        end
    elseif originalWalkSpeed ~= nil then
        hum.WalkSpeed = originalWalkSpeed
        originalWalkSpeed = nil
    end
end)

local MAX_STAT = 100

RunService.Heartbeat:Connect(function()
    if not Config.InfiniteStats then return end
    local char = LocalPlayer.Character
    local values = char and char:FindFirstChild("Values")
    if not values then return end
    for _, name in ipairs({ "Stamina", "Hydration", "Satiation" }) do
        local stat = values:FindFirstChild(name)
        if stat and stat.Value < MAX_STAT then
            stat.Value = MAX_STAT
        end
    end
end)

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib4.lua'))()

local Window = Centrl:Window({
    Title = 'a quiet place',
    SubTitle = 'assist',
    Folder = 'AQuietPlaceAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(70, 200, 130),
})

if not RequestCharacterAction then
    Centrl:Notify({
        Title = 'a quiet place',
        Content = 'Could not find Events.Remotes.RequestCharacterAction - silent aim will not work. The game may have changed since this was built.',
        Type = 'error',
        Duration = 8,
    })
end

local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })

local AimSection = MainTab:Section({ Title = 'aim', Side = 'left' })

AimSection:Toggle({
    Title = 'silent aim',
    Flag = 'sv_silent_aim',
    Default = false,
    Callback = function(v)
        Config.SilentAim = v
        if v and Config.AimMode == "Silent" and not HAS_NAMECALL_HOOK then
            Centrl:Notify({
                Title = 'a quiet place',
                Content = 'hookmetamethod/getnamecallmethod not available on this executor - switch aim mode to Camera instead.',
                Type = 'warning',
                Duration = 5,
            })
        end
    end,
})

AimSection:Dropdown({
    Title = 'aim mode',
    Flag = 'sv_aim_mode',
    Options = { 'Camera', 'Silent' },
    Default = 'Camera',
    Callback = function(v) Config.AimMode = v end,
})

AimSection:Toggle({
    Title = 'target players',
    Flag = 'sv_target_players',
    Default = true,
    Callback = function(v) Config.TargetPlayers = v end,
})

AimSection:Toggle({
    Title = 'target monsters',
    Flag = 'sv_target_monsters',
    Default = true,
    Callback = function(v) Config.TargetMonsters = v end,
})

AimSection:Toggle({
    Title = 'wall check',
    Flag = 'sv_wall_check',
    Default = true,
    Callback = function(v) Config.WallCheck = v end,
})

AimSection:Dropdown({
    Title = 'aim at',
    Flag = 'sv_aim_part',
    Options = { 'Head', 'HumanoidRootPart' },
    Default = 'Head',
    Callback = function(v) Config.AimPart = v end,
})

AimSection:Slider({
    Title = 'max range',
    Flag = 'sv_max_range',
    Min = 0,
    Max = 1500,
    Increment = 25,
    Default = 400,
    Suffix = ' studs',
    Callback = function(v) Config.MaxRange = v end,
})

local FovSection = MainTab:Section({ Title = 'fov circle', Side = 'right' })

FovSection:Toggle({
    Title = 'fov',
    Flag = 'sv_fov',
    Default = true,
    Callback = function(v) Config.FOVEnabled = v end,
})

FovSection:Slider({
    Title = 'fov size',
    Flag = 'sv_fov_size',
    Min = 20,
    Max = 800,
    Increment = 5,
    Default = 200,
    Suffix = ' px',
    Callback = function(v) Config.FOVRadius = v end,
})

FovSection:Slider({
    Title = 'fov transparency',
    Flag = 'sv_fov_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.6,
    Callback = function(v) Config.FOVTransparency = v end,
})

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Flag = 'sv_esp_enabled',
    Default = false,
    Callback = function(v) ESPConfig.Enabled = v end,
})

EspSection:Dropdown({
    Title = 'esp method',
    Flag = 'sv_esp_method',
    Options = { 'Highlight', 'Box', 'Tracers' },
    Default = 'Highlight',
    Callback = function(v) ESPConfig.Method = v end,
})

EspSection:Toggle({
    Title = 'show names',
    Flag = 'sv_esp_names',
    Default = true,
    Callback = function(v) ESPConfig.ShowNames = v end,
})

EspSection:Toggle({
    Title = 'esp players',
    Flag = 'sv_esp_players',
    Default = true,
    Callback = function(v) ESPConfig.Players = v end,
})

EspSection:Toggle({
    Title = 'esp monsters',
    Flag = 'sv_esp_monsters',
    Default = true,
    Callback = function(v) ESPConfig.Monsters = v end,
})

EspSection:Toggle({
    Title = 'esp items',
    Flag = 'sv_esp_items',
    Default = false,
    Callback = function(v) ESPConfig.Items = v end,
})

local EspConfigSection = VisualTab:Section({ Title = 'esp config', Side = 'right' })

EspConfigSection:Slider({
    Title = 'transparency',
    Flag = 'sv_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) ESPConfig.Transparency = v end,
})

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local SpeedSection = PlayerTab:Section({ Title = 'speed', Side = 'left' })

SpeedSection:Toggle({
    Title = 'speed',
    Flag = 'sv_speed_enabled',
    Default = false,
    Callback = function(v) Config.SpeedEnabled = v end,
})

SpeedSection:Slider({
    Title = 'walkspeed',
    Flag = 'sv_walkspeed',
    Min = 16,
    Max = 200,
    Increment = 2,
    Default = 32,
    Callback = function(v) Config.WalkSpeed = v end,
})

SpeedSection:Slider({
    Title = 'extra boost',
    Flag = 'sv_speed_boost',
    Min = 0,
    Max = 100,
    Increment = 2,
    Default = 0,
    Suffix = ' studs/s',
    Callback = function(v) Config.SpeedBoost = v end,
})

local StatsSection = PlayerTab:Section({ Title = 'stats', Side = 'right' })

StatsSection:Toggle({
    Title = 'infinite stamina / hydration / satiation',
    Flag = 'sv_infinite_stats',
    Default = false,
    Callback = function(v) Config.InfiniteStats = v end,
})

Window:Load()

Centrl:Notify({
    Title = 'a quiet place',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

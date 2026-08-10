local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
end)

-- The fire remote takes an action name ("UseItem", "DropItem", ...) and,
-- for weapons, a MousePosition the server trusts as the aim point - not a
-- 2D screen coordinate, but the world hit of a Raycast straight out of the
-- camera's LookVector (see Player.Utilities' GetMouseHit: it ignores the
-- actual mouse cursor entirely). That's what makes both aim techniques
-- below work: camera-lock because turning the camera IS turning the aim
-- ray, and the silent remote hook because replacing MousePosition replaces
-- exactly what the server already trusts.
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local Remotes = Events and Events:WaitForChild("Remotes", 10)
local RequestCharacterAction = Remotes and Remotes:WaitForChild("RequestCharacterAction", 10)

local Config = {
    SilentAim = false,
    AimMode = "Camera", -- "Camera" (visible, always works) or "Silent" (invisible, needs namecall hooking)
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
}

local ESPConfig = {
    Enabled = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    Players = true,
    Monsters = true,
}

--// Targeting --------------------------------------------------------------------
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

-- Monsters live under a flat Workspace._Monsters folder, each entry a Model
-- with its own Humanoid - same shape as a player's character, so targeting
-- treats both the same way once collected.
local function collectCandidates()
    local list = {}
    if Config.TargetPlayers then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if char and hum and hum.Health > 0 then
                    list[#list + 1] = { Model = char, IsMonster = false }
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
                        list[#list + 1] = { Model = model, IsMonster = true }
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

--// Silent aim (remote hook) -----------------------------------------------------
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

--// Camera-lock aim (always works, visibly turns the camera) --------------------
local function applyCameraLock()
    if not (Config.SilentAim and Config.AimMode == "Camera") then return end
    local aimPart = getBestTarget()
    if not aimPart then return end
    Camera.CFrame = CFrame.new(Camera.CFrame.Position, aimPart.Position)
end

pcall(function()
    RunService:BindToRenderStep("SurvivalAimLock", Enum.RenderPriority.Camera.Value + 1, applyCameraLock)
end)

--// FOV circle --------------------------------------------------------------------
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
    local show = Config.SilentAim and Config.FOVEnabled
    fovCircle.Visible = show
    if show then
        fovCircle.Radius = Config.FOVRadius
        -- Drawing's Transparency is opacity-flavored (1 = fully opaque), the
        -- opposite of Roblox's own convention, so the slider (Roblox-style,
        -- higher = more see-through) gets inverted here.
        fovCircle.Transparency = 1 - Config.FOVTransparency
        fovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
end)

--// ESP ------------------------------------------------------------------------
local espObjects = {} -- [model] = objs

local function espColorFor(isMonster)
    if isMonster then return Color3.fromRGB(255, 170, 60) end
    return Color3.fromRGB(230, 60, 60)
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

local function buildEsp(model, name, isMonster)
    destroyEsp(model)
    local color = espColorFor(isMonster)
    local objs = { Method = ESPConfig.Method, ShowNames = ESPConfig.ShowNames, IsMonster = isMonster }
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
        local head = model:FindFirstChild("Head")
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "SurvivalESPName"
        billboard.Adornee = head or model.PrimaryPart
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

-- Highlight color/transparency and the name+distance text only need to
-- track loosely, not every frame - bundled into one roster-refresh poll so
-- RenderStepped below stays limited to what actually needs per-frame
-- smoothness (Box/Tracer screen positions, which move with the camera).
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
                                buildEsp(char, plr.Name, false)
                                objs = espObjects[char]
                            end
                            if objs then
                                local color = espColorFor(false)
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
                                    buildEsp(model, model.Name, true)
                                    objs = espObjects[model]
                                end
                                if objs then
                                    local color = espColorFor(true)
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
            local hrp = model:FindFirstChild("HumanoidRootPart")
            local color = espColorFor(objs.IsMonster)

            if objs.Box and hrp then
                local head = model:FindFirstChild("Head")
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

--// Player: speed ------------------------------------------------------------------
local originalWalkSpeed = nil

local function getMyHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

RunService.Heartbeat:Connect(function()
    local hum = getMyHumanoid()
    if not hum then return end
    if Config.SpeedEnabled then
        if originalWalkSpeed == nil then
            originalWalkSpeed = hum.WalkSpeed
        end
        hum.WalkSpeed = Config.WalkSpeed
    elseif originalWalkSpeed ~= nil then
        hum.WalkSpeed = originalWalkSpeed
        originalWalkSpeed = nil
    end
end)

--// UI -----------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'survival',
    SubTitle = 'assist',
    Folder = 'SurvivalAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(70, 200, 130),
})

if not RequestCharacterAction then
    Centrl:Notify({
        Title = 'survival',
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
                Title = 'survival',
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

FovSection:Paragraph({
    Title = 'how aiming works here',
    Text = 'This game aims from the center of your screen (a straight ray out of the camera), not your mouse cursor - so the FOV circle is centered on screen, and "Camera" mode works by turning your view onto the target, same as aiming normally. "Silent" mode instead rewrites the aim point sent to the server without moving your camera, but needs namecall hooking support.',
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

Window:Load()

Centrl:Notify({
    Title = 'survival',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

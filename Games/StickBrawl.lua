local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Connections = {}
local function track(conn)
    Connections[#Connections + 1] = conn
    return conn
end

local function getChar()
    return LocalPlayer.Character
end
local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local char = getChar()
    return char and char:FindFirstChild("HumanoidRootPart")
end
local function getTool()
    local char = getChar()
    return char and char:FindFirstChildOfClass("Tool")
end
local function inSafeZone()
    local char = getChar()
    return char ~= nil and char:GetAttribute("SafeZone") == true
end

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'stick brawl',
    SubTitle = 'esp + combat',
    Folder = 'StickBrawl',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 90, 90),
})

local function notify(title, content, kind, duration)
    Centrl:Notify({ Title = title, Content = content, Type = kind or 'info', Duration = duration or 4 })
end

--// esp -----------------------------------------------------------------------

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })
local EspColorSection = VisualTab:Section({ Title = 'esp appearance', Side = 'right' })

local EspConfig = {
    Enabled = false,
    Mode = 'Both',
    FillColor = Color3.fromRGB(255, 60, 60),
    OutlineColor = Color3.fromRGB(255, 255, 255),
    FillTransparency = 0.6,
    OutlineTransparency = 0,
    BoxColor = Color3.fromRGB(255, 60, 60),
    BoxThickness = 2,
    ShowNames = true,
    ShowDistance = true,
    ShowHealth = true,
    MaxDistance = 500,
}

EspSection:Toggle({
    Title = 'enabled',
    Flag = 'esp_enabled',
    Default = false,
    Callback = function(state) EspConfig.Enabled = state end,
})

EspSection:Dropdown({
    Title = 'mode',
    Values = { 'Highlight', 'Box', 'Both' },
    Default = 'Both',
    Flag = 'esp_mode',
    Callback = function(v) EspConfig.Mode = v end,
})

EspSection:Toggle({
    Title = 'show names',
    Flag = 'esp_names',
    Default = true,
    Callback = function(state) EspConfig.ShowNames = state end,
})

EspSection:Toggle({
    Title = 'show distance',
    Flag = 'esp_distance',
    Default = true,
    Callback = function(state) EspConfig.ShowDistance = state end,
})

EspSection:Toggle({
    Title = 'show health',
    Flag = 'esp_health',
    Default = true,
    Callback = function(state) EspConfig.ShowHealth = state end,
})

EspSection:Slider({
    Title = 'max distance',
    Flag = 'esp_maxdist',
    Min = 50, Max = 2000, Increment = 50, Default = 500,
    Suffix = 'st',
    Callback = function(v) EspConfig.MaxDistance = v end,
})

EspColorSection:Colorpicker({
    Title = 'highlight fill',
    Flag = 'esp_fillcolor',
    Default = Color3.fromRGB(255, 60, 60),
    Callback = function(c) EspConfig.FillColor = c end,
})

EspColorSection:Slider({
    Title = 'fill transparency',
    Flag = 'esp_filltransparency',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.6,
    Callback = function(v) EspConfig.FillTransparency = v end,
})

EspColorSection:Colorpicker({
    Title = 'highlight outline',
    Flag = 'esp_outlinecolor',
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) EspConfig.OutlineColor = c end,
})

EspColorSection:Slider({
    Title = 'outline transparency',
    Flag = 'esp_outlinetransparency',
    Min = 0, Max = 1, Increment = 0.05, Default = 0,
    Callback = function(v) EspConfig.OutlineTransparency = v end,
})

EspColorSection:Colorpicker({
    Title = 'box color',
    Flag = 'esp_boxcolor',
    Default = Color3.fromRGB(255, 60, 60),
    Callback = function(c) EspConfig.BoxColor = c end,
})

EspColorSection:Slider({
    Title = 'box thickness',
    Flag = 'esp_boxthickness',
    Min = 1, Max = 5, Increment = 1, Default = 2,
    Suffix = 'px',
    Callback = function(v) EspConfig.BoxThickness = v end,
})

local espGui = Instance.new("ScreenGui")
espGui.Name = "stickbrawl_esp"
espGui.ResetOnSpawn = false
espGui.IgnoreGuiInset = true
espGui.DisplayOrder = 50
espGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local espEntries = {}

local function destroyEspEntry(entry)
    if entry.highlight then entry.highlight:Destroy() end
    if entry.frame then entry.frame:Destroy() end
end

local function clearEsp()
    for _, entry in pairs(espEntries) do
        destroyEspEntry(entry)
    end
    espEntries = {}
end

local function ensureEspEntry(plr)
    local entry = espEntries[plr]
    if entry then return entry end
    entry = {}
    local highlight = Instance.new("Highlight")
    highlight.FillColor = EspConfig.FillColor
    highlight.OutlineColor = EspConfig.OutlineColor
    highlight.FillTransparency = EspConfig.FillTransparency
    highlight.OutlineTransparency = EspConfig.OutlineTransparency
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = false
    highlight.Parent = espGui
    entry.highlight = highlight

    local frame = Instance.new("Frame")
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.Parent = espGui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = EspConfig.BoxThickness
    stroke.Color = EspConfig.BoxColor
    stroke.Parent = frame
    entry.frame = frame
    entry.stroke = stroke

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 16)
    label.Position = UDim2.new(0, 0, 0, -18)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextStrokeTransparency = 0.3
    label.Text = ""
    label.Parent = frame
    entry.label = label

    espEntries[plr] = entry
    return entry
end

local function screenBoxFor(char)
    local ok, cf, size = pcall(function() return char:GetBoundingBox() end)
    if not ok or not cf then return nil end
    local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local anyOnScreen = false
    for xs = -1, 1, 2 do
        for ys = -1, 1, 2 do
            for zs = -1, 1, 2 do
                local corner = cf.Position
                    + cf.RightVector * (hx * xs)
                    + cf.UpVector * (hy * ys)
                    + cf.LookVector * (hz * zs)
                local point, onScreen = Camera:WorldToViewportPoint(corner)
                if point.Z > 0 then
                    if onScreen then anyOnScreen = true end
                    minX = math.min(minX, point.X)
                    minY = math.min(minY, point.Y)
                    maxX = math.max(maxX, point.X)
                    maxY = math.max(maxY, point.Y)
                end
            end
        end
    end
    if not anyOnScreen then return nil end
    return minX, minY, maxX - minX, maxY - minY
end

track(RunService.RenderStepped:Connect(function(dt)
    if not EspConfig.Enabled then
        if next(espEntries) then clearEsp() end
        return
    end

    local root = getRoot()
    local live = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local char = plr.Character
            local hum = char:FindFirstChildOfClass("Humanoid")
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and hrp then
                local distance = root and (hrp.Position - root.Position).Magnitude or 0
                if distance <= EspConfig.MaxDistance then
                    live[plr] = true
                    local entry = ensureEspEntry(plr)

                    entry.highlight.Adornee = char
                    entry.highlight.FillColor = EspConfig.FillColor
                    entry.highlight.OutlineColor = EspConfig.OutlineColor
                    entry.highlight.FillTransparency = EspConfig.FillTransparency
                    entry.highlight.OutlineTransparency = EspConfig.OutlineTransparency
                    entry.highlight.Enabled = EspConfig.Mode == 'Highlight' or EspConfig.Mode == 'Both'

                    local wantBox = EspConfig.Mode == 'Box' or EspConfig.Mode == 'Both'
                    if wantBox then
                        local x, y, w, h = screenBoxFor(char)
                        if x then
                            entry.frame.Position = UDim2.fromOffset(x, y)
                            entry.frame.Size = UDim2.fromOffset(w, h)
                            entry.stroke.Thickness = EspConfig.BoxThickness
                            entry.stroke.Color = EspConfig.BoxColor
                            entry.frame.Visible = true
                        else
                            entry.frame.Visible = false
                        end
                    else
                        entry.frame.Visible = false
                    end

                    local parts = {}
                    if EspConfig.ShowNames then parts[#parts + 1] = plr.Name end
                    if EspConfig.ShowHealth then
                        parts[#parts + 1] = ('%d/%d hp'):format(math.floor(hum.Health), math.floor(hum.MaxHealth))
                    end
                    if EspConfig.ShowDistance then
                        parts[#parts + 1] = ('%dst'):format(distance)
                    end
                    entry.label.Text = table.concat(parts, ' | ')
                    entry.label.Visible = #parts > 0 and (entry.highlight.Enabled or entry.frame.Visible)
                end
            end
        end
    end

    for plr, entry in pairs(espEntries) do
        if not live[plr] then
            destroyEspEntry(entry)
            espEntries[plr] = nil
        end
    end
end))

--// combat ---------------------------------------------------------------------

local CombatTab = Window:Tab({ Title = 'combat', Icon = 'sword' })
local FaceSection = CombatTab:Section({ Title = 'auto face', Side = 'left' })
local AttackSection = CombatTab:Section({ Title = 'auto attack', Side = 'right' })

local CombatConfig = {
    -- The actual melee hitbox is a fixed OverlapParams block, Vector3.new(4.5, 4, 6),
    -- centered a short offset in front of your own HumanoidRootPart - found
    -- identical across every stick's swing code in the dump, not tied to the
    -- equipped tool's Handle at all (there is no per-stick reach value to read).
    -- 7 studs is that box's real forward reach plus a small margin, not a
    -- guess - attacking from farther than this cannot land regardless of
    -- what auto attack does.
    AttackRange = 7,
    -- Auto face has no equivalent real number to ground it in - how far out
    -- you want to start turning toward someone is just a preference, so it
    -- stays independent and a plain default.
    FaceRange = 20,
    Priority = 'Nearest',
    AutoFaceEnabled = false,
    AutoFaceSpeed = 10,
    AutoFaceRequireCone = false,
    AutoFaceCone = 120,
    -- Targets a lead position (current position + AssemblyLinearVelocity *
    -- lead time) instead of where they are right now. Against someone
    -- strafing or running, "right now" is already behind them by the time
    -- you finish turning or the swing actually connects.
    FacePredictionEnabled = false,
    FacePredictionTime = 0.15,
    AutoAttackEnabled = false,
    AttackInterval = 0.15,
    AttackPredictionEnabled = false,
    AttackPredictionTime = 0.15,
    Attempts = 0,
}

FaceSection:Paragraph({
    Title = 'auto m1',
    Text = 'Auto attack calls the stick tool the same way a real click does (Tool:Activate), so it goes through the game\'s own swing/animation/cooldown - it does not fake a hit. Auto face turns your character toward the current target so swings actually land on it. They pick targets independently, each within its own range - auto attack\'s default is grounded in the real melee hitbox size found in the game\'s own code, not guessed. Each has its own "predict movement" toggle: with it on, a target\'s real AssemblyLinearVelocity is used to aim/range-check a lead position (current position + velocity * prediction time) instead of where they physically are the instant this reads them - a fast-moving target is otherwise always a little behind by the time you finish turning or the swing lands.',
})

FaceSection:Slider({
    Title = 'auto face range',
    Flag = 'combat_face_range',
    Min = 5, Max = 100, Increment = 1, Default = 20,
    Suffix = 'st',
    Callback = function(v) CombatConfig.FaceRange = v end,
})

FaceSection:Dropdown({
    Title = 'target priority',
    Values = { 'Nearest', 'Lowest Health' },
    Default = 'Nearest',
    Flag = 'combat_priority',
    Callback = function(v) CombatConfig.Priority = v end,
})

FaceSection:Toggle({
    Title = 'auto face',
    Flag = 'combat_face_enabled',
    Default = false,
    Callback = function(state) CombatConfig.AutoFaceEnabled = state end,
})

FaceSection:Slider({
    Title = 'auto face speed',
    Flag = 'combat_face_speed',
    Min = 1, Max = 30, Increment = 1, Default = 10,
    Callback = function(v) CombatConfig.AutoFaceSpeed = v end,
})

FaceSection:Toggle({
    Title = 'only face targets in cone',
    Flag = 'combat_face_cone_on',
    Default = false,
    Callback = function(state) CombatConfig.AutoFaceRequireCone = state end,
})

FaceSection:Slider({
    Title = 'face cone',
    Flag = 'combat_face_cone',
    Min = 10, Max = 180, Increment = 5, Default = 120,
    Suffix = ' deg',
    Callback = function(v) CombatConfig.AutoFaceCone = v end,
})

FaceSection:Toggle({
    Title = 'predict movement',
    Flag = 'combat_face_predict',
    Default = false,
    Callback = function(state) CombatConfig.FacePredictionEnabled = state end,
})

FaceSection:Slider({
    Title = 'prediction time',
    Flag = 'combat_face_predict_time',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.15,
    Suffix = 's',
    Callback = function(v) CombatConfig.FacePredictionTime = v end,
})

local FaceStatus = FaceSection:Stat({ Title = 'status', Value = 'idle' })

AttackSection:Toggle({
    Title = 'auto attack',
    Flag = 'combat_attack_enabled',
    Default = false,
    Callback = function(state) CombatConfig.AutoAttackEnabled = state end,
})

AttackSection:Slider({
    Title = 'auto attack range',
    Flag = 'combat_attack_range',
    Min = 4, Max = 25, Increment = 0.5, Default = 7,
    Suffix = 'st',
    Callback = function(v) CombatConfig.AttackRange = v end,
})

AttackSection:Toggle({
    Title = 'predict movement',
    Flag = 'combat_attack_predict',
    Default = false,
    Callback = function(state) CombatConfig.AttackPredictionEnabled = state end,
})

AttackSection:Slider({
    Title = 'prediction time',
    Flag = 'combat_attack_predict_time',
    Min = 0, Max = 1, Increment = 0.05, Default = 0.15,
    Suffix = 's',
    Callback = function(v) CombatConfig.AttackPredictionTime = v end,
})

AttackSection:Slider({
    Title = 'attack interval',
    Flag = 'combat_attack_interval',
    Min = 0.05, Max = 1, Increment = 0.05, Default = 0.15,
    Suffix = 's',
    Callback = function(v) CombatConfig.AttackInterval = v end,
})

local AttackStatus = AttackSection:Stat({ Title = 'status', Value = 'idle' })
local AttackCount = AttackSection:Stat({ Title = 'attempts', Value = '0' })

-- AssemblyLinearVelocity is the part's real current velocity (Roblox
-- engine property, not something the game has to expose) - a plain,
-- reliable way to lead a moving target without needing anything
-- game-specific.
local function predictedPosition(hrp, leadTime)
    if leadTime <= 0 then return hrp.Position end
    return hrp.Position + hrp.AssemblyLinearVelocity * leadTime
end

-- Returns both the real HumanoidRootPart (for cooldown/tool checks and
-- naming in status text) and the position actually worth aiming at, which
-- is the predicted lead position when prediction is on for that caller,
-- otherwise just where they really are. Range is checked against that same
-- aim position, so a fast target closing in from just past the range slider
-- can already be picked up before it visibly enters it, and one moving away
-- can drop out early.
local function findTarget(range, predict, leadTime)
    local root = getRoot()
    if not root then return nil end
    local best, bestScore, bestAimPos = nil, nil, nil
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local hum = plr.Character:FindFirstChildOfClass("Humanoid")
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and hrp then
                local aimPos = predict and predictedPosition(hrp, leadTime) or hrp.Position
                local dist = (aimPos - root.Position).Magnitude
                if dist <= range then
                    local score = CombatConfig.Priority == 'Lowest Health' and hum.Health or dist
                    if not best or score < bestScore then
                        best, bestScore, bestAimPos = hrp, score, aimPos
                    end
                end
            end
        end
    end
    return best, bestAimPos
end

local function inCone(root, targetPos, coneDeg)
    local flat = (targetPos - root.Position) * Vector3.new(1, 0, 1)
    if flat.Magnitude < 0.01 then return true end
    local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
    if look.Magnitude < 0.01 then return true end
    local dot = math.clamp(look.Unit:Dot(flat.Unit), -1, 1)
    return math.deg(math.acos(dot)) <= coneDeg
end

local lastAttack = 0
track(RunService.Heartbeat:Connect(function(dt)
    if not (CombatConfig.AutoFaceEnabled or CombatConfig.AutoAttackEnabled) then return end
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or hum.Health <= 0 or not root then return end
    if inSafeZone() then
        if CombatConfig.AutoFaceEnabled then FaceStatus:Set('in safe zone') end
        if CombatConfig.AutoAttackEnabled then AttackStatus:Set('in safe zone') end
        return
    end

    if CombatConfig.AutoFaceEnabled then
        local faceTarget, aimPos = findTarget(CombatConfig.FaceRange,
            CombatConfig.FacePredictionEnabled, CombatConfig.FacePredictionTime)
        if not faceTarget then
            FaceStatus:Set('no target in range')
        else
            local flat = (aimPos - root.Position) * Vector3.new(1, 0, 1)
            if flat.Magnitude > 0.1 then
                local allowed = not CombatConfig.AutoFaceRequireCone
                    or inCone(root, aimPos, CombatConfig.AutoFaceCone)
                if allowed then
                    local desired = CFrame.lookAt(root.Position, root.Position + flat)
                    local alpha = math.clamp(CombatConfig.AutoFaceSpeed * dt, 0, 1)
                    root.CFrame = root.CFrame:Lerp(desired, alpha)
                    FaceStatus:Set('facing ' .. (faceTarget.Parent and faceTarget.Parent.Name or '?'))
                else
                    FaceStatus:Set('target outside cone')
                end
            end
        end
    end

    if CombatConfig.AutoAttackEnabled then
        local attackTarget = findTarget(CombatConfig.AttackRange,
            CombatConfig.AttackPredictionEnabled, CombatConfig.AttackPredictionTime)
        if not attackTarget then
            AttackStatus:Set('no target in attack range')
            return
        end
        local tool = getTool()
        if not tool then
            AttackStatus:Set('no stick equipped')
            return
        end
        local now = os.clock()
        if now - lastAttack >= CombatConfig.AttackInterval then
            lastAttack = now
            local ok = pcall(function() tool:Activate() end)
            if ok then
                CombatConfig.Attempts = CombatConfig.Attempts + 1
                AttackCount:Set(tostring(CombatConfig.Attempts))
                AttackStatus:Set('attacking ' .. (attackTarget.Parent and attackTarget.Parent.Name or '?'))
            end
        end
    end
end))

--// control -------------------------------------------------------------------

local StatusTab = Window:Tab({ Title = 'status', Icon = 'info' })
local ControlSec = StatusTab:Section({ Title = 'control', Side = 'left' })

ControlSec:Button({
    Title = 'unload',
    Callback = function()
        EspConfig.Enabled = false
        CombatConfig.AutoFaceEnabled = false
        CombatConfig.AutoAttackEnabled = false
        clearEsp()
        espGui:Destroy()
        for _, conn in ipairs(Connections) do
            pcall(function() conn:Disconnect() end)
        end
        Window:Destroy()
    end,
})

Window:Load()
notify('stick brawl', 'loaded', 'success', 3)

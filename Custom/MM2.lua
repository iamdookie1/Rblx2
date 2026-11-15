local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__CustomMM2Unload then
    pcall(Genv.__CustomMM2Unload)
end

local Unloaded = false
local Connections = {}
local function track(c)
    table.insert(Connections, c)
    return c
end

local LumeUI = loadstring(game:HttpGet("https://github.com/SSHRKs/LumeUI/releases/latest/download/main.lua"))()

local Settings = {
    GunAim = 0,
    KnifeAim = 0,
    Esp = false,
    AntiFling = false,
}

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local Gameplay = Remotes and Remotes:WaitForChild("Gameplay", 10)
local GetCurrentPlayerData = Gameplay and Gameplay:FindFirstChild("GetCurrentPlayerData")
local PlayerDataChanged = Gameplay and Gameplay:FindFirstChild("PlayerDataChanged")

local RoundData = {}
local function refreshRound()
    if not GetCurrentPlayerData then
        return
    end
    local ok, data = pcall(GetCurrentPlayerData.InvokeServer, GetCurrentPlayerData)
    if ok and type(data) == "table" then
        RoundData = data
    end
end
task.spawn(refreshRound)
if PlayerDataChanged then
    track(PlayerDataChanged.OnClientEvent:Connect(function(data)
        if type(data) == "table" then
            RoundData = data
        end
    end))
end
task.spawn(function()
    while not Unloaded do
        task.wait(3)
        refreshRound()
    end
end)

local function isGun(item)
    if not item:IsA("Tool") then
        return false
    end
    local tagged = false
    pcall(function()
        tagged = CollectionService:HasTag(item, "Weapon_Gun")
    end)
    return item.Name == "Gun" or tagged or item:FindFirstChild("IsGun") ~= nil
end

local function isKnife(item)
    return item:IsA("Tool") and (item.Name == "Knife" or item:FindFirstChild("KnifeClient") ~= nil)
end

local function carried(plr)
    local found
    for _, holder in { plr.Character, plr:FindFirstChildOfClass("Backpack") } do
        if holder then
            for _, item in holder:GetChildren() do
                if isKnife(item) then
                    return "Knife"
                elseif isGun(item) then
                    found = "Gun"
                end
            end
        end
    end
    return found
end

local function roleOf(plr)
    local entry = RoundData[plr.Name]
    local role = type(entry) == "table" and entry.Role or nil
    local dead = type(entry) == "table" and (entry.Dead == true or entry.Killed == true)
    local held = carried(plr)
    if held == "Knife" then
        role = "Murderer"
    elseif held == "Gun" and role ~= "Sheriff" then
        role = role == "Murderer" and role or "Hero"
    end
    return role, dead
end

local function aliveRoot(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 then
        return root, hum, char
    end
    return nil
end

local function ignoreList(extra)
    local list = { LocalPlayer.Character }
    if extra then
        table.insert(list, extra)
    end
    for _, inst in CollectionService:GetTagged("WeaponPassthrough") do
        table.insert(list, inst)
    end
    return list
end

local function clearLine(from, to, targetChar)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local list = ignoreList(targetChar)
    params.FilterDescendantsInstances = list
    local dir = to - from
    for _ = 1, 8 do
        local hit = Workspace:Raycast(from, dir, params)
        if not hit then
            return true
        end
        if hit.Instance.Transparency < 1 then
            return false
        end
        table.insert(list, hit.Instance)
        params.FilterDescendantsInstances = list
    end
    return false
end

local lastTap, lastTapAt = nil, 0
track(UserInputService.TouchTapInWorld:Connect(function(pos, processed)
    if not processed then
        lastTap, lastTapAt = pos, os.clock()
    end
end))

local function mouseLocked()
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    local ml = ps and ps:FindFirstChild("MouseLock")
    return ml and ml:GetAttribute("Enabled") == true
end

local function aimPoint()
    local cam = Workspace.CurrentCamera
    local vp = cam.ViewportSize
    if UserInputService.TouchEnabled and lastTap and os.clock() - lastTapAt < 0.35 then
        return Vector2.new(lastTap.X, lastTap.Y)
    end
    if mouseLocked() or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return vp / 2
    end
    if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
        return vp / 2
    end
    return UserInputService:GetMouseLocation()
end

local function fovRadius(value)
    local vp = Workspace.CurrentCamera.ViewportSize
    return value / 100 * vp.Magnitude / 2
end

local KNIFE_SPEED = 96
track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(function(k)
    local s = k:GetAttribute("ThrowSpeed")
    if type(s) == "number" and s > 0 then
        KNIFE_SPEED = s
    end
end))

local function ping()
    local ok, p = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    return ok and type(p) == "number" and math.clamp(p, 0, 0.5) or 0.06
end

local function predict(root, hum, from, speed)
    local vel = root.AssemblyLinearVelocity
    local flat = Vector3.new(vel.X, 0, vel.Z)
    local maxFlat = math.max(hum.WalkSpeed * 1.6, 24)
    if flat.Magnitude > maxFlat then
        flat = flat.Unit * maxFlat
    end
    local vy = math.clamp(vel.Y, -80, 60)
    local grounded = hum.FloorMaterial ~= Enum.Material.Air
    local g = Workspace.Gravity
    local base = root.Position
    local lead = ping() + 0.02
    local t = lead
    local pos = base
    for _ = 1, 4 do
        if speed then
            t = (pos - from).Magnitude / speed + lead
        end
        local drop = 0
        if not grounded then
            drop = vy * t - 0.5 * g * t * t
            drop = math.max(drop, -(root.Position.Y - (base.Y - 12)))
        end
        pos = base + flat * t + Vector3.new(0, drop, 0)
    end
    return pos
end

local function pickTarget(kind, value)
    local me = aliveRoot(LocalPlayer)
    if not me or value <= 0 then
        return nil
    end
    local cam = Workspace.CurrentCamera
    local center = aimPoint()
    local radius = fovRadius(value)
    local anywhere = value >= 100
    local head = LocalPlayer.Character:FindFirstChild("Head")
    local eye = head and head.Position or me.Position
    local best, bestScore
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local root, hum, char = aliveRoot(plr)
            local role, dead = roleOf(plr)
            local wanted = root and not dead
            if wanted and kind == "Gun" then
                wanted = role == "Murderer"
            end
            if wanted then
                local sp, onScreen = cam:WorldToViewportPoint(root.Position)
                local screenDist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                local inFov = onScreen and sp.Z > 0 and screenDist <= radius
                if inFov or anywhere then
                    local seen = clearLine(eye, root.Position, char)
                    local score = (inFov and screenDist or radius + (root.Position - me.Position).Magnitude * 4)
                    if not seen then
                        score += 100000
                    end
                    if kind == "Knife" and (role == "Sheriff" or role == "Hero") then
                        score -= 40
                    end
                    if not bestScore or score < bestScore then
                        best, bestScore = { root = root, hum = hum, char = char }, score
                    end
                end
            end
        end
    end
    return best
end

local function redirect(kind, origin)
    local value = kind == "Gun" and Settings.GunAim or Settings.KnifeAim
    local target = pickTarget(kind, value)
    if not target then
        return nil
    end
    local from = typeof(origin) == "CFrame" and origin.Position or target.root.Position
    local pos = predict(target.root, target.hum, from, kind == "Knife" and KNIFE_SPEED or nil)
    if kind == "Gun" then
        local torso = target.char:FindFirstChild("UpperTorso") or target.char:FindFirstChild("Torso")
        if torso then
            pos += torso.Position - target.root.Position
        end
    end
    return CFrame.new(pos)
end

local hooked = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local original
    local function onNamecall(self, ...)
        if Unloaded or (Settings.GunAim <= 0 and Settings.KnifeAim <= 0) or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
            return original(self, ...)
        end
        if self.Name == "Shoot" and self.Parent and self.Parent:IsA("Tool") and Settings.GunAim > 0 then
            local origin = ...
            local ok, cf = pcall(redirect, "Gun", origin)
            if ok and cf then
                return original(self, origin, cf, select(3, ...))
            end
        elseif self.Name == "KnifeThrown" and Settings.KnifeAim > 0 then
            local events = self.Parent
            local tool = events and events.Parent
            if tool and tool:IsA("Tool") then
                local handle = ...
                local ok, cf = pcall(redirect, "Knife", handle)
                if ok and cf then
                    return original(self, handle, cf, select(3, ...))
                end
            end
        end
        return original(self, ...)
    end
    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end
    original = hookmetamethod(game, "__namecall", onNamecall)
    hooked = true
end

local WeaponService
pcall(function()
    WeaponService = require(ReplicatedStorage:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local origMouse, origTarget
if not hooked and type(WeaponService) == "table" then
    origMouse, origTarget = WeaponService.GetMouseTargetCFrame, WeaponService.GetTargetPosition
    local function heldKind()
        local char = LocalPlayer.Character
        if not char then
            return nil
        end
        for _, item in char:GetChildren() do
            if isKnife(item) then
                return "Knife"
            elseif isGun(item) then
                return "Gun"
            end
        end
        return nil
    end
    local function handleOrigin()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        local h = tool and tool:FindFirstChild("Handle")
        return h and h.CFrame
    end
    WeaponService.GetMouseTargetCFrame = function(self, ...)
        local kind = heldKind()
        if kind and not Unloaded then
            local ok, cf = pcall(redirect, kind, handleOrigin())
            if ok and cf then
                return cf
            end
        end
        return origMouse(self, ...)
    end
    WeaponService.GetTargetPosition = function(self, x, y, ...)
        lastTap, lastTapAt = Vector2.new(x, y), os.clock()
        local kind = heldKind()
        if kind and not Unloaded then
            local ok, cf = pcall(redirect, kind, handleOrigin())
            if ok and cf then
                return cf
            end
        end
        return origTarget(self, x, y, ...)
    end
end

local Circle
if typeof(Drawing) == "table" and Drawing.new then
    pcall(function()
        Circle = Drawing.new("Circle")
        Circle.Thickness = 1.5
        Circle.NumSides = 64
        Circle.Filled = false
        Circle.Transparency = 0.6
        Circle.Color = Color3.fromRGB(255, 255, 255)
        Circle.Visible = false
    end)
end
track(RunService.RenderStepped:Connect(function()
    if not Circle then
        return
    end
    local char = LocalPlayer.Character
    local value = 0
    if char then
        for _, item in char:GetChildren() do
            if isKnife(item) then
                value = Settings.KnifeAim
            elseif isGun(item) then
                value = Settings.GunAim
            end
        end
    end
    if value > 0 and value < 100 then
        Circle.Position = aimPoint()
        Circle.Radius = fovRadius(value)
        Circle.Visible = true
    else
        Circle.Visible = false
    end
end))

local EspFolder = Instance.new("Folder")
EspFolder.Name = "\0"
EspFolder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local Marks = {}
local COLORS = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function dropMark(plr)
    local m = Marks[plr]
    if m then
        m.hl:Destroy()
        m.bb:Destroy()
        Marks[plr] = nil
    end
end
track(Players.PlayerRemoving:Connect(dropMark))
local function espStep()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local root, _, char = aliveRoot(plr)
            local role, dead = roleOf(plr)
            if Settings.Esp and root and not dead then
                local color = COLORS[role] or COLORS.Innocent
                local m = Marks[plr]
                if not m or m.char ~= char then
                    dropMark(plr)
                    local hl = Instance.new("Highlight")
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.55
                    hl.OutlineTransparency = 0
                    hl.Adornee = char
                    hl.Parent = EspFolder
                    local bb = Instance.new("BillboardGui")
                    bb.AlwaysOnTop = true
                    bb.Size = UDim2.fromOffset(160, 22)
                    bb.StudsOffset = Vector3.new(0, 3.4, 0)
                    bb.Adornee = root
                    bb.Parent = EspFolder
                    local label = Instance.new("TextLabel")
                    label.BackgroundTransparency = 1
                    label.Size = UDim2.fromScale(1, 1)
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 13
                    label.TextStrokeTransparency = 0.4
                    label.Text = plr.DisplayName
                    label.Parent = bb
                    m = { hl = hl, bb = bb, label = label, char = char }
                    Marks[plr] = m
                end
                m.hl.FillColor = color
                m.hl.OutlineColor = color
                m.label.TextColor3 = color
            else
                dropMark(plr)
            end
        end
    end
end
task.spawn(function()
    while not Unloaded do
        pcall(espStep)
        task.wait(0.25)
    end
end)

local Flagged = {}
local safeCFrame
local function partsOf(char)
    local out = {}
    for _, d in char:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end
    return out
end
track(RunService.Stepped:Connect(function()
    if not Settings.AntiFling then
        return
    end
    local me = aliveRoot(LocalPlayer)
    local now = os.clock()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local spin = root.AssemblyAngularVelocity.Magnitude
                local speed = root.AssemblyLinearVelocity.Magnitude
                local near = me and (root.Position - me.Position).Magnitude < 60
                if near and (spin > 25 or speed > 120) then
                    Flagged[plr] = now + 3
                end
            end
            if Flagged[plr] then
                if now > Flagged[plr] then
                    Flagged[plr] = nil
                elseif char then
                    for _, p in partsOf(char) do
                        p.CanCollide = false
                        p.AssemblyLinearVelocity = Vector3.zero
                        p.AssemblyAngularVelocity = Vector3.zero
                    end
                end
            end
        end
    end
end))
track(RunService.Heartbeat:Connect(function()
    if not Settings.AntiFling then
        safeCFrame = nil
        return
    end
    local root, hum = aliveRoot(LocalPlayer)
    if not root then
        safeCFrame = nil
        return
    end
    local v = root.AssemblyLinearVelocity
    local flat = Vector3.new(v.X, 0, v.Z).Magnitude
    local spin = root.AssemblyAngularVelocity.Magnitude
    local flung = flat > math.max(hum.WalkSpeed * 5, 90) or v.Y > 140 or spin > 35
    if flung and safeCFrame then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.CFrame = safeCFrame
    elseif flat < hum.WalkSpeed * 2 + 4 and spin < 8 and math.abs(v.Y) < 60 then
        safeCFrame = root.CFrame
    end
end))

local Window = LumeUI:CreateWindow({
    Name = "MM2",
    Author = "dookie hub",
    Icon = "swords",
    SideBarWidth = 130,
    ToggleKey = Enum.KeyCode.RightShift,
    Size = UDim2.fromOffset(460, 300),
    Elements = {
        Minimized = false,
        Close = false,
    },
})

local MARKER = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    Window:EditOpenButton({
        Title = MARKER,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local function hideOpenButton()
    local roots = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(roots, gethui())
    end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        table.insert(roots, pg)
    end
    for _, r in roots do
        local ok, list = pcall(r.GetDescendants, r)
        if ok then
            for _, d in list do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == MARKER then
                    local top = d
                    local p = d.Parent
                    while p and p:IsA("GuiObject") and p.AbsoluteSize.X * p.AbsoluteSize.Y < 320 * 160 do
                        top = p
                        p = p.Parent
                    end
                    if top:IsA("GuiObject") then
                        top.Visible = false
                    end
                end
            end
        end
    end
end
task.spawn(function()
    while not Unloaded do
        pcall(hideOpenButton)
        task.wait(0.5)
    end
end)

local Main = Window:Tab({ Title = "Main", Icon = "crosshair" })
Main:Section({ Title = "Silent Aim" })
Main:Slider({
    Title = "Gun Silent Aim",
    Step = 1,
    Value = { Min = 0, Max = 100, Default = 0 },
    Callback = function(v)
        Settings.GunAim = tonumber(v) or 0
    end,
})
Main:Slider({
    Title = "Knife Silent Aim",
    Step = 1,
    Value = { Min = 0, Max = 100, Default = 0 },
    Callback = function(v)
        Settings.KnifeAim = tonumber(v) or 0
    end,
})
Main:Section({ Title = "Other" })
Main:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(state)
        Settings.Esp = state
    end,
})
Main:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(state)
        Settings.AntiFling = state
        if not state then
            table.clear(Flagged)
        end
    end,
})

local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })
local Bind = SettingsTab:Keybind({
    Title = "Toggle UI",
    Callback = function(key)
        local code = typeof(key) == "EnumItem" and key or Enum.KeyCode[tostring(key)]
        if code then
            pcall(Window.SetToggleKey, Window, code)
        end
    end,
})
pcall(function()
    Bind:SetValue("RightShift")
end)

Genv.__CustomMM2Unload = function()
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for plr in Marks do
        dropMark(plr)
    end
    EspFolder:Destroy()
    if Circle then
        pcall(Circle.Remove, Circle)
    end
    if origMouse and WeaponService then
        WeaponService.GetMouseTargetCFrame = origMouse
        WeaponService.GetTargetPosition = origTarget
    end
    pcall(Window.Close, Window)
end

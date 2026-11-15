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
    GunAim = false,
    KnifeAim = false,
    GunPrediction = 0,
    KnifePrediction = 0,
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

local KNIFE_SPEED = 96
track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(function(k)
    local s = k:GetAttribute("ThrowSpeed")
    if type(s) == "number" and s > 0 then
        KNIFE_SPEED = s
    end
end))

local Motion = {}
track(RunService.PreSimulation:Connect(function(dt)
    if not (Settings.GunAim or Settings.KnifeAim) or dt <= 0 then
        return
    end
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local pos = root.Position
                local m = Motion[plr]
                if not m or m.root ~= root then
                    Motion[plr] = { root = root, pos = pos, vel = Vector3.zero }
                else
                    local step = (pos - m.pos) / dt
                    if step.Magnitude > 80 then
                        m.vel = Vector3.zero
                    else
                        m.vel = m.vel:Lerp(step, math.clamp(dt * 12, 0, 1))
                    end
                    m.pos = pos
                end
            else
                Motion[plr] = nil
            end
        end
    end
end))
track(Players.PlayerRemoving:Connect(function(plr)
    Motion[plr] = nil
end))

local function ping()
    local ok, p = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    return ok and type(p) == "number" and math.clamp(p, 0, 0.3) or 0.05
end

local function worldParams(extra)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local list = ignoreList(extra)
    for _, plr in Players:GetPlayers() do
        if plr.Character then
            table.insert(list, plr.Character)
        end
    end
    params.FilterDescendantsInstances = list
    return params
end

local function predict(target, from, speed, extra)
    local root, hum = target.root, target.hum
    local m = Motion[target.plr]
    local vel = (m and m.root == root) and m.vel or root.AssemblyLinearVelocity
    local flat = Vector3.new(vel.X, 0, vel.Z)
    local maxFlat = math.max(hum.WalkSpeed, 16) * 1.25
    if flat.Magnitude > maxFlat then
        flat = flat.Unit * maxFlat
    end
    local base = root.Position
    local lead = ping() + (extra or 0)
    local t = lead
    if speed then
        for _ = 1, 3 do
            t = ((base + flat * t) - from).Magnitude / speed + lead
        end
    end
    local goal = base + flat * t
    if hum.FloorMaterial == Enum.Material.Air then
        local vy = math.clamp(vel.Y, -60, 50)
        local rise = vy * math.min(t, 0.4)
        goal += Vector3.new(0, math.clamp(rise, -6, 6), 0)
    end
    local params = worldParams()
    local move = goal - base
    if move.Magnitude > 0.05 then
        local hit = Workspace:Raycast(base, move, params)
        if hit then
            goal = hit.Position - move.Unit * 1.2
        end
    end
    local down = Workspace:Raycast(goal + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), params)
    if down and goal.Y < down.Position.Y + 1 then
        goal = Vector3.new(goal.X, down.Position.Y + 1.5, goal.Z)
    end
    return goal
end

local function pickTarget(kind)
    local me = aliveRoot(LocalPlayer)
    if not me then
        return nil
    end
    local cam = Workspace.CurrentCamera
    local center = aimPoint()
    local fov = math.max(cam.ViewportSize.Y * 0.45, 220)
    local head = LocalPlayer.Character:FindFirstChild("Head")
    local eye = head and head.Position or me.Position
    local list, murderer = {}, false
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local root, hum, char = aliveRoot(plr)
            if root then
                local role, dead = roleOf(plr)
                if not dead and role == "Murderer" then
                    murderer = true
                end
                if not dead then
                    local sp, onScreen = cam:WorldToViewportPoint(root.Position)
                    local dist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if onScreen and sp.Z > 0 and dist <= fov then
                        local tHead = char:FindFirstChild("Head")
                        if clearLine(eye, root.Position, char) or (tHead and clearLine(eye, tHead.Position, char)) then
                            table.insert(list, { plr = plr, root = root, hum = hum, char = char, role = role, dist = dist })
                        end
                    end
                end
            end
        end
    end
    local best
    for _, c in list do
        if kind ~= "Gun" or not murderer or c.role == "Murderer" then
            local score = c.dist
            if kind == "Knife" and (c.role == "Sheriff" or c.role == "Hero") then
                score -= 40
            end
            if not best or score < best.score then
                c.score = score
                best = c
            end
        end
    end
    return best
end

local function redirect(kind, origin)
    local on = kind == "Gun" and Settings.GunAim or kind == "Knife" and Settings.KnifeAim
    local target = on and pickTarget(kind)
    if not target then
        return nil
    end
    local from = typeof(origin) == "CFrame" and origin.Position or target.root.Position
    local extra = kind == "Gun" and Settings.GunPrediction or Settings.KnifePrediction
    local pos = predict(target, from, kind == "Knife" and KNIFE_SPEED or nil, tonumber(extra) or 0)
    if kind == "Gun" then
        local torso = target.char:FindFirstChild("UpperTorso") or target.char:FindFirstChild("Torso")
        if torso then
            pos += torso.Position - target.root.Position
        end
    end
    if not clearLine(from, pos, target.char) then
        pos = target.root.Position
    end
    return CFrame.new(pos)
end

if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local original
    local function onNamecall(self, ...)
        if Unloaded or not (Settings.GunAim or Settings.KnifeAim) or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
            return original(self, ...)
        end
        if self.ClassName ~= "RemoteEvent" then
            return original(self, ...)
        end
        local kind
        local parent = self.Parent
        if self.Name == "Shoot" and Settings.GunAim and parent and parent.ClassName == "Tool" then
            kind = "Gun"
        elseif self.Name == "KnifeThrown" and Settings.KnifeAim and parent and parent.Parent and parent.Parent.ClassName == "Tool" then
            kind = "Knife"
        end
        if not kind then
            return original(self, ...)
        end
        local args = table.pack(...)
        local fire = self.FireServer
        local ok, cf = pcall(redirect, kind, args[1])
        if not ok then
            warn("[MM2] " .. tostring(cf))
        end
        if ok and cf then
            args[2] = cf
        end
        return fire(self, table.unpack(args, 1, args.n))
    end
    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end
    original = hookmetamethod(game, "__namecall", onNamecall)
end

local WeaponService
pcall(function()
    WeaponService = require(ReplicatedStorage:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local origMouse, origTarget
if type(WeaponService) == "table" then
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
                if m.color ~= color then
                    m.color = color
                    m.hl.FillColor = color
                    m.hl.OutlineColor = color
                    m.label.TextColor3 = color
                end
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
local PartCache = {}
local safeCFrame
local function partsOf(char)
    local cached = PartCache[char]
    if cached then
        return cached
    end
    local out = {}
    for _, d in char:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end
    PartCache[char] = out
    local conn
    conn = char.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end)
    char.AncestryChanged:Once(function()
        PartCache[char] = nil
        conn:Disconnect()
    end)
    return out
end
track(RunService.PreSimulation:Connect(function()
    if not Settings.AntiFling then
        safeCFrame = nil
        return
    end
    local me, myHum = aliveRoot(LocalPlayer)
    local now = os.clock()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root and me then
                local offset = root.Position - me.Position
                if offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z < 3600 then
                    local spin = root.AssemblyAngularVelocity
                    local speed = root.AssemblyLinearVelocity
                    if spin:Dot(spin) > 625 or speed:Dot(speed) > 14400 then
                        Flagged[plr] = now + 3
                    end
                end
            end
            local until_ = Flagged[plr]
            if until_ then
                if now > until_ or not char then
                    Flagged[plr] = nil
                else
                    for _, part in partsOf(char) do
                        if part.CanCollide then
                            part.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not me then
        safeCFrame = nil
        return
    end
    local v = me.AssemblyLinearVelocity
    local flat = math.sqrt(v.X * v.X + v.Z * v.Z)
    local spin = me.AssemblyAngularVelocity.Magnitude
    local walk = myHum.WalkSpeed
    if (flat > math.max(walk * 5, 90) or v.Y > 140 or spin > 35) and safeCFrame then
        me.AssemblyLinearVelocity = Vector3.zero
        me.AssemblyAngularVelocity = Vector3.zero
        me.CFrame = safeCFrame
    elseif flat < walk * 2 + 4 and spin < 8 and math.abs(v.Y) < 60 then
        safeCFrame = me.CFrame
    end
end))

local Window = LumeUI:CreateWindow({
    Name = "MM2",
    Author = "ily",
    Icon = "swords",
    SideBarWidth = 130,
    ToggleKey = Enum.KeyCode.K,
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
local Hidden = {}
local function hideOpenButton()
    local roots = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(roots, gethui())
    end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        table.insert(roots, pg)
    end
    local found = false
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
                    if top:IsA("GuiObject") and not Hidden[top] then
                        Hidden[top] = true
                        top.Visible = false
                        track(top:GetPropertyChangedSignal("Visible"):Connect(function()
                            if top.Visible then
                                top.Visible = false
                            end
                        end))
                    end
                    found = true
                end
            end
        end
    end
    return found
end
task.spawn(function()
    for _, delay in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(delay)
        if Unloaded then
            return
        end
        local ok, found = pcall(hideOpenButton)
        if ok and found then
            return
        end
    end
end)
local ToggleKey = Enum.KeyCode.K
track(UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == ToggleKey then
        task.delay(0.15, pcall, hideOpenButton)
        task.delay(0.6, pcall, hideOpenButton)
    end
end))

local Main = Window:Tab({ Title = "Main", Icon = "crosshair" })
Main:Section({ Title = "Silent Aim" })
Main:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(state)
        Settings.GunAim = state
    end,
})
Main:Slider({
    Title = "Gun Prediction",
    Step = 0.05,
    Value = { Min = 0, Max = 3, Default = 0 },
    Callback = function(v)
        Settings.GunPrediction = tonumber(v) or 0
    end,
})
Main:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(state)
        Settings.KnifeAim = state
    end,
})
Main:Slider({
    Title = "Murderer Prediction",
    Step = 0.05,
    Value = { Min = 0, Max = 3, Default = 0 },
    Callback = function(v)
        Settings.KnifePrediction = tonumber(v) or 0
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
            ToggleKey = code
            pcall(Window.SetToggleKey, Window, code)
        end
    end,
})
pcall(function()
    Bind:SetValue("K")
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
    if origMouse and WeaponService then
        WeaponService.GetMouseTargetCFrame = origMouse
        WeaponService.GetTargetPosition = origTarget
    end
    pcall(Window.Close, Window)
end

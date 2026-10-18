--// Telekinesis ----------------------------------------------------------------------
-- Pick up, carry, spin and throw loose parts in any game, or pull every loose
-- part around you into an orbit, a shield wall or a swarm. It runs on its own,
-- outside the hub:
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Universal/Telekinesis.lua'))()
--
-- How it can move anything: a part that isn't anchored is simulated by one
-- machine, its network owner, and Roblox hands a loose part to the player
-- nearest it. On the owner's machine its physics is the real one: whatever
-- moves it there moves it for everyone. So this moves the parts you own, and
-- shows the rest as not yours (yellow) until you get close enough for Roblox
-- to hand them to you; a grabbed part that isn't yours yet starts moving the
-- moment it is. Anchored parts, parts welded to anchored ones (red) and other
-- players' characters can't be moved by anyone but the server.
--
-- A part is held by an AlignPosition (and an AlignOrientation) made on your
-- side only, on the part's assembly root, so a whole welded model moves as
-- one and nothing shows up for anyone else but the motion.
--
-- PC: G grabs or lets go of what's under the mouse, F throws it, Z / X (or
-- the mouse wheel) bring it closer or push it away, R turns it, T tilts it,
-- RightControl hides the menu. Phone: Pick, then tap a part; the buttons do
-- the rest, and a held part goes where the middle of the screen looks.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__TelekinesisStop) == "function" then pcall(Genv.__TelekinesisStop) end

local S = {
    ClickGrab = false,      -- left click grabs / lets go too (off: G only, so tools still click)
    Keys = true,            -- the G F Z X R T keys
    Distance = 14,          -- how far in front of the camera a held part floats
    Strength = 80,          -- how hard the hold pulls (responsiveness)
    Rigid = false,          -- snap straight to the spot instead of pulling
    KeepRotation = true,    -- a held part keeps its turn relative to where you look
    Spin = false,
    SpinSpeed = 4,          -- radians per second
    NoHitMe = true,         -- held parts pass through your own character
    Phase = false,          -- held parts pass through everything
    ThrowPower = 150,

    Formation = "Orbit",    -- Orbit / Shield / Above me / At aim / Freeze
    Range = 60,             -- how far around you Gather looks
    MaxParts = 25,
    OwnedOnly = true,       -- Gather only takes parts that are yours right now
    Radius = 10,            -- orbit radius, and how far out the shield stands
    OrbitSpeed = 1.5,
    Height = 2,

    Highlight = true,
}

local FORMATIONS = { "Orbit", "Shield", "Above me", "At aim", "Freeze" }
local MIN_DISTANCE, MAX_DISTANCE = 3, 300
local TAG = "TK" .. tostring(math.random(100000, 999999))

--// lifecycle ---------------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// what a part is ----------------------------------------------------------------

local hasOwnerCheck = typeof(isnetworkowner) == "function"

-- Yours to move: the executor's isnetworkowner when there is one, else
-- ReceiveAge, which stays 0 for a part your own machine simulates.
local function owned(part)
    if hasOwnerCheck then
        local ok, result = pcall(isnetworkowner, part)
        if ok and type(result) == "boolean" then return result end
    end
    local ok, age = pcall(function() return part.ReceiveAge end)
    return ok and age == 0
end

local function isPlayerCharacter(inst)
    local model = inst:FindFirstAncestorOfClass("Model")
    while model do
        if Players:GetPlayerFromCharacter(model) then return true end
        model = model:FindFirstAncestorOfClass("Model")
    end
    return false
end

local function rootOf(part)
    return part.AssemblyRootPart or part
end

-- "yours", "not yours" (loose, someone else simulates it), "fixed"
-- (anchored, or welded to something anchored) or "player"; nil for no part
local function classify(part)
    if typeof(part) ~= "Instance" or not part:IsA("BasePart") then return nil end
    if part.Anchored then return "fixed" end
    local okGrounded, grounded = pcall(function() return part:IsGrounded() end)
    if okGrounded and grounded then return "fixed" end
    local root = rootOf(part)
    if isPlayerCharacter(root) or isPlayerCharacter(part) then return "player" end
    return owned(root) and "yours" or "not yours"
end

local KIND_COLOR = {
    yours = Color3.fromRGB(110, 230, 140),
    ["not yours"] = Color3.fromRGB(255, 205, 90),
    fixed = Color3.fromRGB(255, 95, 95),
    player = Color3.fromRGB(255, 95, 95),
}
local KIND_TEXT = {
    yours = "yours, can be moved",
    ["not yours"] = "loose, not yours yet (get closer)",
    fixed = "anchored, can't be moved",
    player = "a player, can't be moved",
}

--// aiming ------------------------------------------------------------------------

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

local function myRoot()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart"), char
end

local function touchOnly()
    return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

-- the camera ray through a tap (screen position), the mouse, or on a phone
-- the middle of the screen
local function aimRay(screenPos)
    local cam = Workspace.CurrentCamera
    if screenPos then return cam:ScreenPointToRay(screenPos.X, screenPos.Y) end
    if touchOnly() then
        local size = cam.ViewportSize
        return cam:ViewportPointToRay(size.X / 2, size.Y / 2)
    end
    local mouse = UserInputService:GetMouseLocation()
    return cam:ViewportPointToRay(mouse.X, mouse.Y)
end

local function partAt(screenPos, ignore)
    local list = { LocalPlayer.Character }
    for _, inst in ipairs(ignore or {}) do list[#list + 1] = inst end
    RayParams.FilterDescendantsInstances = list
    local ray = aimRay(screenPos)
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, RayParams)
    return hit and hit.Instance, hit and hit.Position, ray
end

-- the camera's turn around the vertical only
local function yawCFrame()
    local look = Workspace.CurrentCamera.CFrame.LookVector
    return CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
end

--// holding -------------------------------------------------------------------------

local Gui -- the menu's ScreenGui, also home to the selection boxes
local Held = {}     -- [assembly root] = record
local Grabbed = nil -- the record held at your aim
local NextIndex = 0

local function assemblyParts(root)
    local ok, parts = pcall(function() return root:GetConnectedParts(true) end)
    if not ok or type(parts) ~= "table" then return { root } end
    if #parts > 40 then
        local cut = {}
        for i = 1, 40 do cut[i] = parts[i] end
        return cut
    end
    return parts
end

local function hold(root, mode)
    local rec = Held[root]
    if rec then
        rec.Mode = mode
        return rec
    end
    rec = { Root = root, Mode = mode, Made = {}, Collide = nil, Extra = CFrame.identity, Turned = false }
    rec.RotOffset = yawCFrame():Inverse() * root.CFrame.Rotation
    rec.Anchor = root.Position
    rec.Span = math.max(root.Size.X, root.Size.Y, root.Size.Z)
    NextIndex += 1
    rec.Index = NextIndex

    local att = Instance.new("Attachment")
    att.Name = TAG
    att.Parent = root
    rec.Made[#rec.Made + 1] = att

    local ap = Instance.new("AlignPosition")
    ap.Name = TAG
    ap.Mode = Enum.PositionAlignmentMode.OneAttachment
    ap.Attachment0 = att
    ap.ApplyAtCenterOfMass = true
    ap.MaxForce = math.huge
    ap.MaxVelocity = math.huge
    ap.Responsiveness = S.Strength
    ap.RigidityEnabled = S.Rigid
    ap.Position = root.Position
    ap.Parent = att
    rec.AP = ap

    local ao = Instance.new("AlignOrientation")
    ao.Name = TAG
    ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0 = att
    ao.MaxTorque = math.huge
    ao.MaxAngularVelocity = math.huge
    ao.Responsiveness = S.Strength
    ao.RigidityEnabled = S.Rigid
    ao.CFrame = root.CFrame.Rotation
    ao.Enabled = false
    ao.Parent = att
    rec.AO = ao

    local box = Instance.new("SelectionBox")
    box.Name = TAG
    box.LineThickness = 0.04
    box.SurfaceTransparency = 0.9
    box.Adornee = root
    box.Visible = S.Highlight
    box.Parent = Gui
    rec.Box = box
    rec.Made[#rec.Made + 1] = box

    local parts = assemblyParts(root)
    if S.Phase then
        rec.Collide = {}
        for _, part in ipairs(parts) do
            rec.Collide[part] = part.CanCollide
            part.CanCollide = false
        end
    elseif S.NoHitMe then
        local _, char = myRoot()
        if char then
            local mine = {}
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and (part.CanCollide or part.Name == "HumanoidRootPart") then mine[#mine + 1] = part end
            end
            -- a gathered part only by its root, so a big gather stays cheap
            for _, part in ipairs(mode == "group" and { root } or parts) do
                for _, limb in ipairs(mine) do
                    local nc = Instance.new("NoCollisionConstraint")
                    nc.Name = TAG
                    nc.Part0, nc.Part1 = part, limb
                    nc.Parent = att
                end
            end
        end
    end

    Held[root] = rec
    return rec
end

local function release(root, velocity)
    local rec = Held[root]
    if not rec then return end
    Held[root] = nil
    if Grabbed == rec then Grabbed = nil end
    for _, inst in ipairs(rec.Made) do pcall(function() inst:Destroy() end) end
    if rec.Collide then
        for part, was in pairs(rec.Collide) do pcall(function() part.CanCollide = was end) end
    end
    if velocity and root.Parent then
        pcall(function()
            root.AssemblyLinearVelocity = velocity
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

local function releaseAll()
    for root in pairs(Held) do release(root) end
end

local function groupList()
    local list = {}
    for _, rec in pairs(Held) do
        if rec.Mode == "group" then list[#list + 1] = rec end
    end
    table.sort(list, function(a, b) return a.Index < b.Index end)
    return list
end

local function heldRoots()
    local list = {}
    for root in pairs(Held) do list[#list + 1] = root end
    return list
end

local function setStrength()
    for _, rec in pairs(Held) do
        rec.AP.Responsiveness, rec.AO.Responsiveness = S.Strength, S.Strength
        rec.AP.RigidityEnabled, rec.AO.RigidityEnabled = S.Rigid, S.Rigid
    end
end

--// actions -----------------------------------------------------------------------------

local Status = { Note = "" }
local DistanceSlider -- set once the menu is built, so the slider follows the wheel and keys

local function note(text)
    Status.Note, Status.NoteAt = text, os.clock()
end

local function setDistance(value)
    S.Distance = math.clamp(value, MIN_DISTANCE, MAX_DISTANCE)
    if DistanceSlider then DistanceSlider.Refresh() end
end

local function grab(part)
    local kind = classify(part)
    if kind ~= "yours" and kind ~= "not yours" then
        note(kind and ("can't grab that: " .. KIND_TEXT[kind]) or "nothing there to grab")
        return
    end
    local root = rootOf(part)
    if Grabbed then release(Grabbed.Root) end
    if Held[root] then release(root) end
    Grabbed = hold(root, "grab")
    -- it stays as far away as it was picked up
    setDistance((root.Position - Workspace.CurrentCamera.CFrame.Position).Magnitude)
    note(kind == "yours" and ("grabbed " .. root.Name) or ("grabbed " .. root.Name .. ", it moves once it's yours"))
end

local function letGo()
    if Grabbed then
        note("let go of " .. Grabbed.Root.Name)
        release(Grabbed.Root)
    end
end

local function grabOrLetGo()
    if Grabbed then
        letGo()
    else
        grab((partAt()))
    end
end

local function throw()
    if not Grabbed then
        note("not holding anything")
        return
    end
    local _, hitPos, ray = partAt(nil, heldRoots())
    local root = Grabbed.Root
    local target = hitPos or (ray.Origin + ray.Direction * 500)
    local dir = target - root.Position
    dir = dir.Magnitude > 0.1 and dir.Unit or ray.Direction
    note("threw " .. root.Name)
    release(root, dir * S.ThrowPower)
end

local function turn(axis)
    if not Grabbed then return end
    Grabbed.Turned = true
    if axis == "yaw" then
        Grabbed.Extra = CFrame.Angles(0, math.rad(45), 0) * Grabbed.Extra
    else
        Grabbed.Extra = CFrame.Angles(math.rad(45), 0, 0) * Grabbed.Extra
    end
end

local Overlap = OverlapParams.new()
Overlap.FilterType = Enum.RaycastFilterType.Exclude

local function gather()
    local me, char = myRoot()
    if not me then
        note("no character")
        return
    end
    Overlap.FilterDescendantsInstances = { char }
    local ok, parts = pcall(function() return Workspace:GetPartBoundsInRadius(me.Position, S.Range, Overlap) end)
    if not ok then return end
    local seen, found = {}, {}
    for _, part in ipairs(parts) do
        local root = rootOf(part)
        if not seen[root] then
            seen[root] = true
            if not Held[root] then
                local kind = classify(root)
                if kind == "yours" or (kind == "not yours" and not S.OwnedOnly) then
                    found[#found + 1] = { Root = root, Distance = (root.Position - me.Position).Magnitude }
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.Distance < b.Distance end)
    local room = S.MaxParts - #groupList()
    local added = 0
    for i = 1, math.min(#found, room) do
        hold(found[i].Root, "group")
        added += 1
    end
    if room <= 0 then
        note(("already holding %d (the max), raise Max parts for more"):format(S.MaxParts))
    else
        note(added > 0 and ("pulled in %d part%s"):format(added, added == 1 and "" or "s")
            or (S.OwnedOnly and "no loose parts of yours in range" or "no loose parts in range"))
    end
end

local function blast()
    local me = myRoot()
    local count = 0
    for root in pairs(Held) do
        local away = me and (root.Position - me.Position) or Vector3.yAxis
        away = away.Magnitude > 0.1 and away.Unit or Vector3.yAxis
        release(root, away * S.ThrowPower + Vector3.new(0, S.ThrowPower * 0.25, 0))
        count += 1
    end
    note(("blasted %d part%s away"):format(count, count == 1 and "" or "s"))
end

local Barraging = false
local function barrage()
    if Barraging then return end
    local list = groupList()
    if #list == 0 then
        note("nothing gathered to fire")
        return
    end
    Barraging = true
    task.spawn(function()
        for _, rec in ipairs(list) do
            if Unloaded then break end
            if Held[rec.Root] == rec and rec.Root.Parent then
                local _, hitPos, ray = partAt(nil, heldRoots())
                local target = hitPos or (ray.Origin + ray.Direction * 500)
                local dir = target - rec.Root.Position
                if dir.Magnitude > 0.1 then release(rec.Root, dir.Unit * S.ThrowPower) end
                task.wait(0.08)
            end
        end
        Barraging = false
    end)
    note(("firing %d part%s at your aim"):format(#list, #list == 1 and "" or "s"))
end

local function dropAll()
    local count = 0
    for _ in pairs(Held) do count += 1 end
    releaseAll()
    note(("dropped %d part%s"):format(count, count == 1 and "" or "s"))
end

--// every frame ---------------------------------------------------------------------------

local HoldKeys = { Closer = false, Farther = false }

local function formationGoal(i, n, center, now, rec, spacing)
    local f = S.Formation
    local spread = (i - 1) / n * math.pi * 2
    if f == "Orbit" then
        local a = now * S.OrbitSpeed + spread
        return center + Vector3.new(math.cos(a) * S.Radius, S.Height, math.sin(a) * S.Radius)
    elseif f == "Shield" then
        -- a wall standing between you and where you look
        local cols = math.ceil(math.sqrt(n))
        local row, col = math.floor((i - 1) / cols), (i - 1) % cols
        local offset = Vector3.new((col - (cols - 1) / 2) * spacing, row * spacing + S.Height, -S.Radius)
        return center + yawCFrame():VectorToWorldSpace(offset)
    elseif f == "Above me" then
        local a = now * S.OrbitSpeed + spread
        local r = 2 + n * 0.25
        return center + Vector3.new(math.cos(a) * r, 6 + S.Height + (i % 3) * 2, math.sin(a) * r)
    elseif f == "At aim" then
        local ray = aimRay()
        local base = ray.Origin + ray.Direction * S.Distance
        local a = now * S.OrbitSpeed + spread
        local r = 1 + n * 0.2
        return base + Vector3.new(math.cos(a) * r, math.sin(a * 0.7) * r * 0.4, math.sin(a) * r)
    end
    return rec.Anchor -- Freeze
end

local function step(dt)
    local now = os.clock()
    local me = myRoot()

    if Grabbed then
        local rec = Grabbed
        if not rec.Root.Parent then
            release(rec.Root)
        else
            if HoldKeys.Closer then setDistance(S.Distance - math.max(10, S.Distance) * 1.5 * dt) end
            if HoldKeys.Farther then setDistance(S.Distance + math.max(10, S.Distance) * 1.5 * dt) end
            local ray = aimRay()
            rec.AP.Position = ray.Origin + ray.Direction * S.Distance
            if S.Spin then rec.Extra = CFrame.Angles(0, S.SpinSpeed * dt, 0) * rec.Extra end
            rec.AO.Enabled = S.KeepRotation or S.Spin or rec.Turned
            rec.AO.CFrame = yawCFrame() * rec.Extra * rec.RotOffset
        end
    end

    local list = groupList()
    local n = #list
    if n > 0 then
        local center = me and me.Position or list[1].Root.Position
        local spacing = 3
        for _, rec in ipairs(list) do spacing = math.max(spacing, math.min(rec.Span, 12) + 1) end
        local shield = S.Formation == "Shield"
        local yaw = shield and yawCFrame() or nil
        for i, rec in ipairs(list) do
            if not rec.Root.Parent then
                release(rec.Root)
            else
                rec.AP.Position = formationGoal(i, n, center, now, rec, spacing)
                rec.AO.Enabled = shield or S.Spin
                if shield then
                    rec.AO.CFrame = yaw
                elseif S.Spin then
                    rec.Extra = CFrame.Angles(0, S.SpinSpeed * dt, 0) * rec.Extra
                    rec.AO.CFrame = rec.Extra * rec.RotOffset
                end
            end
        end
    end
end

local okPre = pcall(function()
    track(RunService.PreSimulation:Connect(function(dt)
        if not Unloaded then pcall(step, dt) end
    end))
end)
if not okPre then
    track(RunService.Stepped:Connect(function(_, dt)
        if not Unloaded then pcall(step, dt) end
    end))
end

--// menu ------------------------------------------------------------------------------------
-- Plain and small on purpose: a dark panel you can drag by its title, with
-- switches, sliders and buttons. Works with a mouse or a finger.

local Theme = {
    Back = Color3.fromRGB(20, 21, 26),
    Panel = Color3.fromRGB(31, 33, 40),
    Line = Color3.fromRGB(50, 53, 64),
    Text = Color3.fromRGB(232, 234, 240),
    Dim = Color3.fromRGB(145, 150, 165),
    Accent = Color3.fromRGB(124, 156, 255),
    Off = Color3.fromRGB(62, 65, 78),
}

local function new(class, props, children)
    local obj = Instance.new(class)
    local parent = props.Parent
    props.Parent = nil
    for key, value in pairs(props) do obj[key] = value end
    for _, child in ipairs(children or {}) do child.Parent = obj end
    obj.Parent = parent
    return obj
end

local function corner(radius)
    return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function text(props)
    props.BackgroundTransparency = 1
    props.Font = props.Font or Enum.Font.Gotham
    props.TextSize = props.TextSize or 13
    props.TextColor3 = props.TextColor3 or Theme.Text
    props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
    return new("TextLabel", props)
end

Gui = new("ScreenGui", {
    Name = TAG,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 50,
})
do
    local placed = pcall(function()
        Gui.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    end)
    if not placed or not Gui.Parent then Gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end
end

local HoverBox = new("SelectionBox", { Name = TAG, LineThickness = 0.05, SurfaceTransparency = 0.85, Parent = Gui })

local Window = new("Frame", {
    Size = UDim2.fromOffset(260, 400),
    Position = UDim2.new(0, 24, 0.5, -200),
    BackgroundColor3 = Theme.Back,
    BorderSizePixel = 0,
    Parent = Gui,
}, { corner(8), new("UIStroke", { Color = Theme.Line, Thickness = 1 }) })

-- smaller screens get a smaller menu
local Scale = new("UIScale", { Parent = Window })
local function fitScreen()
    local size = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    Scale.Scale = math.clamp(size.Y / 560, 0.65, 1)
end
fitScreen()
track(Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScreen))

local TitleBar = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Parent = Window })
text({ Text = "Telekinesis", Font = Enum.Font.GothamBold, TextSize = 14, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -80, 1, 0), Parent = TitleBar })

local function titleButton(label, x)
    return new("TextButton", {
        Text = label, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Dim,
        BackgroundColor3 = Theme.Panel, AutoButtonColor = true, BorderSizePixel = 0,
        Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, x, 0, 5), Parent = TitleBar,
    }, { corner(5) })
end
local MinButton = titleButton("–", -58)
local CloseButton = titleButton("×", -30)

local Body = new("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 32),
    Size = UDim2.new(1, 0, 1, -32),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = Theme.Line,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = Window,
}, {
    new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
    new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10) }),
})

-- dragging, by the title bar, with a mouse or a finger
do
    local dragInput, dragStart, startPos
    TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragInput, dragStart, startPos = input, input.Position, Window.Position
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if not dragInput then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input == dragInput then
            local delta = (input.Position - dragStart) / Scale.Scale
            Window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then dragInput = nil end
    end))
end

local Minimized = false
MinButton.Activated:Connect(function()
    Minimized = not Minimized
    Body.Visible = not Minimized
    Window.Size = Minimized and UDim2.fromOffset(260, 32) or UDim2.fromOffset(260, 400)
end)

local order = 0
local function nextOrder()
    order += 1
    return order
end

local function section(title)
    text({ Text = title:upper(), Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Theme.Dim, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = nextOrder(), Parent = Body })
end

local function row(height)
    return new("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, LayoutOrder = nextOrder(), Parent = Body }, { corner(6) })
end

local function toggle(label, key, changed)
    local r = row(30)
    text({ Text = label, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -60, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = r })
    local track_ = new("Frame", { Size = UDim2.fromOffset(34, 18), Position = UDim2.new(1, -44, 0.5, -9), BackgroundColor3 = Theme.Off, BorderSizePixel = 0, Parent = r }, { corner(9) })
    local knob = new("Frame", { Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Theme.Text, BorderSizePixel = 0, Parent = track_ }, { corner(7) })
    local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
    local function paint()
        local on = S[key]
        track_.BackgroundColor3 = on and Theme.Accent or Theme.Off
        knob.Position = on and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
    end
    paint()
    hit.Activated:Connect(function()
        S[key] = not S[key]
        paint()
        if changed then pcall(changed, S[key]) end
    end)
    return { Refresh = paint }
end

local function slider(label, key, low, high, stepSize, suffix, changed)
    local r = row(46)
    text({ Text = label, Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -90, 0, 16), Parent = r })
    local valueText = text({ Text = "", TextColor3 = Theme.Dim, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -80, 0, 5), Size = UDim2.fromOffset(70, 16), Parent = r })
    local bar = new("Frame", { Position = UDim2.new(0, 10, 0, 30), Size = UDim2.new(1, -20, 0, 6), BackgroundColor3 = Theme.Off, BorderSizePixel = 0, Parent = r }, { corner(3) })
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = bar }, { corner(3) })
    local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 26), Parent = r })
    local decimals = stepSize < 1 and 1 or 0
    local function show()
        local v = S[key]
        fill.Size = UDim2.fromScale(math.clamp((v - low) / (high - low), 0, 1), 1)
        valueText.Text = (decimals > 0 and ("%.1f"):format(v) or tostring(math.floor(v + 0.5))) .. (suffix or "")
    end
    local function setFrom(x)
        local alpha = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        local v = low + alpha * (high - low)
        v = math.clamp(math.floor(v / stepSize + 0.5) * stepSize, low, high)
        S[key] = v
        show()
        if changed then pcall(changed, v) end
    end
    local dragInput = nil
    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
            setFrom(input.Position.X)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragInput and (input.UserInputType == Enum.UserInputType.MouseMovement or input == dragInput) then
            setFrom(input.Position.X)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then dragInput = nil end
    end))
    show()
    return { Refresh = show }
end

-- a row of buttons side by side; `hold` buttons call back with true / false
-- while pressed instead of once
local function buttons(list)
    local r = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = nextOrder(), Parent = Body }, {
        new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
    local count = #list
    for i, spec in ipairs(list) do
        local b = new("TextButton", {
            Text = spec[1], Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Theme.Text,
            BackgroundColor3 = Theme.Panel, AutoButtonColor = true, BorderSizePixel = 0, LayoutOrder = i,
            Size = UDim2.new(1 / count, -(5 * (count - 1)) / count, 1, 0), Parent = r,
        }, { corner(6) })
        if spec.Hold then
            b.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    pcall(spec[2], true)
                end
            end)
            b.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    pcall(spec[2], false)
                end
            end)
        else
            b.Activated:Connect(function() pcall(spec[2]) end)
        end
    end
end

local function cycle(label, key, values, changed)
    local r = row(30)
    text({ Text = label, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, -10, 1, 0), Parent = r })
    local b = new("TextButton", {
        Text = "", Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Theme.Accent,
        BackgroundColor3 = Theme.Back, AutoButtonColor = true, BorderSizePixel = 0,
        Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.new(0.5, -6, 1, -8), Parent = r,
    }, { corner(5) })
    local function show() b.Text = "‹  " .. tostring(S[key]) .. "  ›" end
    show()
    b.Activated:Connect(function()
        local i = table.find(values, S[key]) or 0
        S[key] = values[i % #values + 1]
        show()
        if changed then pcall(changed, S[key]) end
    end)
end

-- picking: the next tap or click on the world grabs what it lands on
local Picking = false

section("Status")
local StatusLabel = text({
    Text = "", TextColor3 = Theme.Dim, TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = Body,
})

section("Grab")
buttons({
    { "Pick", function()
        Picking = true
        note(touchOnly() and "tap a part to grab it" or "click a part to grab it")
    end },
    { "Let go", letGo },
    { "Throw", throw },
})
buttons({
    { "Closer", function(down) HoldKeys.Closer = down end, Hold = true },
    { "Farther", function(down) HoldKeys.Farther = down end, Hold = true },
    { "Turn", function() turn("yaw") end },
    { "Tilt", function() turn("pitch") end },
})
DistanceSlider = slider("Distance", "Distance", MIN_DISTANCE, 120, 1, " studs")
slider("Strength", "Strength", 5, 200, 1, "", setStrength)
slider("Throw power", "ThrowPower", 20, 600, 5, "")
toggle("Snap (rigid hold)", "Rigid", setStrength)
toggle("Keep its rotation", "KeepRotation")
toggle("Spin", "Spin")
slider("Spin speed", "SpinSpeed", 0.5, 20, 0.5, "")
toggle("Don't hit me", "NoHitMe")
toggle("Pass through walls", "Phase")
toggle("Left click grabs too", "ClickGrab")
toggle("Keys (G F Z X R T)", "Keys")

section("Gather")
cycle("Formation", "Formation", FORMATIONS, function(value)
    if value == "Freeze" then
        for _, rec in ipairs(groupList()) do rec.Anchor = rec.Root.Position end
    end
end)
buttons({ { "Gather", gather }, { "Fire", barrage }, { "Blast", blast }, { "Drop", dropAll } })
slider("Range", "Range", 10, 200, 5, " studs")
slider("Max parts", "MaxParts", 1, 80, 1, "")
toggle("Only parts that are mine", "OwnedOnly")
slider("Radius", "Radius", 3, 40, 1, " studs")
slider("Orbit speed", "OrbitSpeed", 0, 6, 0.1, "")
slider("Height", "Height", -5, 20, 1, " studs")

section("Look")
toggle("Outline parts", "Highlight", function(on)
    for _, rec in pairs(Held) do rec.Box.Visible = on end
end)

--// input --------------------------------------------------------------------------------

local function isClick(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloaded then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        Window.Visible = not Window.Visible
        return
    end
    if processed then return end
    if Picking and isClick(input) then
        Picking = false
        local pos = input.UserInputType == Enum.UserInputType.Touch and Vector2.new(input.Position.X, input.Position.Y) or nil
        grab((partAt(pos)))
        return
    end
    if S.ClickGrab and input.UserInputType == Enum.UserInputType.MouseButton1 then
        grabOrLetGo()
        return
    end
    if not S.Keys or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local key = input.KeyCode
    if key == Enum.KeyCode.G then
        grabOrLetGo()
    elseif key == Enum.KeyCode.F then
        throw()
    elseif key == Enum.KeyCode.Z then
        HoldKeys.Closer = true
    elseif key == Enum.KeyCode.X then
        HoldKeys.Farther = true
    elseif key == Enum.KeyCode.R then
        turn("yaw")
    elseif key == Enum.KeyCode.T then
        turn("pitch")
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.Z then HoldKeys.Closer = false end
    if input.KeyCode == Enum.KeyCode.X then HoldKeys.Farther = false end
end))

-- the wheel pushes a held part away (up) or brings it in (down)
track(UserInputService.InputChanged:Connect(function(input, processed)
    if processed or not Grabbed or input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
    setDistance(S.Distance * (1 + 0.12 * input.Position.Z))
end))

--// hover outline and status ------------------------------------------------------------------

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    if touchOnly() or not S.Highlight or Grabbed then
        HoverBox.Adornee = nil
        return
    end
    local part = partAt()
    local kind = classify(part)
    HoverBox.Adornee = kind and part or nil
    if kind then
        HoverBox.Color3 = KIND_COLOR[kind]
        HoverBox.SurfaceColor3 = KIND_COLOR[kind]
    end
end))

local function statusText()
    local lines = {}
    if Grabbed then
        local yours = owned(Grabbed.Root)
        lines[#lines + 1] = ("holding %s, %s"):format(Grabbed.Root.Name, yours and "yours" or "not yours yet, get closer")
    elseif not touchOnly() then
        local part = partAt()
        local kind = classify(part)
        lines[#lines + 1] = kind and ("aiming at %s: %s"):format(part.Name, KIND_TEXT[kind]) or "aiming at nothing loose"
    end
    local list = groupList()
    if #list > 0 then
        local mine = 0
        for _, rec in ipairs(list) do
            if owned(rec.Root) then mine += 1 end
        end
        lines[#lines + 1] = ("gathered %d (%d yours), %s"):format(#list, mine, S.Formation:lower())
    end
    if Status.Note ~= "" and os.clock() - (Status.NoteAt or 0) < 4 then lines[#lines + 1] = Status.Note end
    if Picking then lines[#lines + 1] = touchOnly() and "tap a part..." or "click a part..." end
    lines[#lines + 1] = hasOwnerCheck and "ownership: isnetworkowner" or "ownership: ReceiveAge"
    return table.concat(lines, "\n")
end

task.spawn(function()
    while not Unloaded do
        pcall(function()
            StatusLabel.Text = statusText()
            -- held parts' outlines: green while yours, yellow while not
            for _, rec in pairs(Held) do
                local color = owned(rec.Root) and KIND_COLOR.yours or KIND_COLOR["not yours"]
                rec.Box.Color3, rec.Box.SurfaceColor3 = color, color
            end
        end)
        task.wait(0.2)
    end
end)

--// shutdown -------------------------------------------------------------------------------

local function shutdown()
    if Unloaded then return end
    Unloaded = true
    pcall(releaseAll)
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    pcall(function() Gui:Destroy() end)
    if Genv.__TelekinesisStop == shutdown then Genv.__TelekinesisStop = nil end
end
Genv.__TelekinesisStop = shutdown
CloseButton.Activated:Connect(shutdown)

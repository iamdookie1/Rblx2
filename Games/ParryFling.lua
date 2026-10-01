--// [OMNI PARRY] parry fling but its hard -- auto parry, auto perfect and omni
--// parry, entity parries, pvp parry and antis.
--
-- What the game's own client scripts show:
--  * E (or the mobile parry button) runs parry() in PlayerGui.NoResetOnSpawn.
--    ParryPart. It freezes you for 0.2 s, then looks for a part in a 0.95 x 4
--    x 0.95 box 3.5 studs over your root (with directional parry, a 0.95 x
--    0.95 x 4 box 3.5 studs out along the camera, its pitch scaled by 1.125).
--    Parts in NoParry or the tower's Frame, your own character, anything not
--    CanCollide, and other players unless Parry Players is on do not count.
--    Found one: you launch 250 up (or along the camera). None: you are punished
--    (thrown down, double jumps reset, damage or death if those are on).
--  * Pressing again while frozen fails the parry, except in the perfect window:
--    the last 0.2 x PParryWindow s of the freeze (25 ms at the default 0.125).
--    The game turns ParryScreen.Frame blue (0.5, 0.5, 1) the moment it opens.
--    A perfect parry stops time for 2 s (Lighting.ParryEffect on), then 400.
--  * With OmniParry on, a press in the last 15 ms of those 2 s (a flag raised
--    1.985 s in and dropped at 2 s) plays the omni cutscene, then 800.
--  * Roguelike entities live in PlayerGui.Roguelike. Ad, Chatbox, Noob and
--    builderman each raise a CanParry value for a short window; a parry started
--    inside it beats them, otherwise they deal 100 (60 for builderman). Bacon
--    only needs your parry on cooldown within a second of showing up. Cowboy's
--    bullet checks a 1 stud cube where you stood when it fired, 0.3 s later.
--    Shadows (_shadowN) are a delayed copy of you that kills on touch.
--  * PVP: while the Shadow entity is on, and Parry Players is on or a round is
--    running, a parry also checks a 9 stud box around you for other players
--    and your shadow, and one with somebody in it lands.
--  * Curses are client side values the shop sets: Curses.Platforms, Curses.Legs,
--    NoParryJump (Wings) and a workspace gravity of 236.2 (Jupiter).
--
-- Every parry here goes through the game's own parry button, so it does
-- exactly what your own press would. Everything is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local Genv = _G
pcall(function()
    local env = getgenv()
    if type(env) == "table" then Genv = env end
end)
if type(Genv.__ParryFlingStop) == "function" then pcall(Genv.__ParryFlingStop) end

--// lifecycle -----------------------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// settings ------------------------------------------------------------------------------

local Auto = { Enabled = false, AirOnly = false, Delay = 0, seenAt = nil, count = 0, inRange = 0 }
local Perfect = { Enabled = false, Omni = false, count = 0, omni = 0, missed = 0, held = 0 }
local Entities = {
    Ad = false, Chatbox = false, Noob = false, builderman = false, Bacon = false,
    Cowboy = false, Shadow = false, ShadowSafe = false, ShadowEsp = false,
    parried = 0, dodged = 0, blocked = 0,
}
local Pvp = { Enabled = false, count = 0, active = false, players = 0 }
local Anti = { KillBricks = false, Platforms = false, Legs = false, Wings = false, Jupiter = false }

local DODGE_DISTANCE = 4.5

--// game state ----------------------------------------------------------------------------

local function character()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function valueOf(parent, name)
    local object = parent and parent:FindFirstChild(name)
    if object and object:IsA("ValueBase") then return object.Value end
    return nil
end

local function gui(name) return valueOf(PlayerGui, name) end

-- times an entity's parry window opens, so nothing else starts a parry that
-- would still be running then
local Danger = {}

local function addDanger(at) Danger[#Danger + 1] = at end

local function dangerWithin(now, seconds)
    local soon = false
    for i = #Danger, 1, -1 do
        local at = Danger[i]
        if now > at + 0.25 then
            table.remove(Danger, i)
        elseif at - now <= seconds then
            soon = true
        end
    end
    return soon
end

--// pressing parry ------------------------------------------------------------------------
-- The game's parry is a local function, but its mobile button calls it through
-- a plain connection, so that connection is a direct line to it: calling it runs
-- the parry right now, in this frame, on PC as well as mobile.

local Press = { fn = nil, parry = nil, at = -math.huge, count = 0, lookedAt = -math.huge }

local function parryButton()
    local mobile = PlayerGui:FindFirstChild("Mobile")
    return mobile and mobile:FindFirstChild("TextButton")
end

local function findPress()
    if Press.fn then return Press.fn end
    local now = os.clock()
    if now - Press.lookedAt < 1 then return nil end
    Press.lookedAt = now
    local button = parryButton()
    if not button or typeof(getconnections) ~= "function" then return nil end
    local ok, list = pcall(getconnections, button.MouseButton1Click)
    if not ok or type(list) ~= "table" then return nil end
    local found, only, count = nil, nil, 0
    for _, connection in ipairs(list) do
        local okFn, fn = pcall(function() return connection.Function end)
        if okFn and type(fn) == "function" then
            count = count + 1
            only = fn
            local okSource, source = pcall(debug.info, fn, "s")
            if okSource and type(source) == "string" and source:find("ParryPart", 1, true) then
                found = fn
                break
            end
        end
    end
    found = found or (count == 1 and only) or nil
    if not found then return nil end
    Press.fn = found
    -- the parry function itself, whose flags show the omni window: the button's
    -- connection only calls it, unless it is the connection
    if type(debug.getupvalue) == "function" then
        local okUp, a, b = pcall(debug.getupvalue, found, 1)
        if okUp and type(a) == "function" then
            Press.parry = a
        elseif okUp and type(b) == "function" then
            Press.parry = b
        elseif type(debug.getupvalues) == "function" then
            local okAll, all = pcall(debug.getupvalues, found)
            local n = 0
            if okAll and type(all) == "table" then
                for _ in pairs(all) do n = n + 1 end
            end
            if n >= 5 then Press.parry = found end
        end
    end
    return found
end

local function pressHow()
    if Press.fn then return 'parry button' end
    if typeof(firesignal) == "function" then return 'firesignal' end
    if VirtualInputManager then return 'E key' end
    return 'nothing to press with'
end

local function press()
    local fn = findPress()
    local pressed = false
    if fn then
        -- runs the parry up to its first wait, right now
        local ok, err = coroutine.resume(coroutine.create(fn))
        if ok then
            pressed = true
        else
            warn('[parry assist] the parry button connection failed, falling back: ' .. tostring(err))
            Press.fn, Press.parry = nil, nil
        end
    end
    if not pressed then
        local button = parryButton()
        if button and typeof(firesignal) == "function" and pcall(firesignal, button.MouseButton1Click) then
            pressed = true
        elseif VirtualInputManager then
            -- a key press only lands next frame, which can be too late for a window
            pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
            task.delay(0.03, function()
                pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game) end)
            end)
            pressed = true
        else
            return false
        end
    end
    Press.at = os.clock()
    Press.count = Press.count + 1
    return true
end

-- a fresh parry, not a second press (which fails the one already running)
local function canStart(char)
    if gui("CanParry") == false then return false end
    if gui("ParryCD") == true then return false end
    if os.clock() - Press.at < 0.15 then return false end
    if char:FindFirstChild("Fly") then return false end
    return true
end

--// the parry hitbox ----------------------------------------------------------------------

local function newProbe(name)
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Transparency = 1
    part.Parent = Workspace
    return part
end

local Probe = newProbe("ParryAssistProbe")
local PvpProbe = newProbe("ParryAssistPvpProbe")
PvpProbe.Size = Vector3.new(9, 9, 9)

local probeParams = OverlapParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.RespectCanCollide = true

local pvpParams = OverlapParams.new()
pvpParams.FilterType = Enum.RaycastFilterType.Exclude

local function towerFrame()
    local tower = Workspace:FindFirstChild("CurrentTower")
    local folder = tower and tower:FindFirstChildOfClass("Folder")
    return folder and folder:FindFirstChild("Frame")
end

-- the same box the game checks once the freeze is over (you cannot move while
-- frozen, so it is the box where you are now)
local function parryBox(root)
    local camera = Workspace.CurrentCamera
    if gui("DirectionalParry") == true and camera then
        local rx, ry, rz = camera.CFrame:ToOrientation()
        local turn = CFrame.fromOrientation(rx * 1.125, ry, rz)
        return CFrame.new(root.Position + turn.LookVector * 3.5) * turn, Vector3.new(0.95, 0.95, 4)
    end
    return CFrame.new(root.Position + Vector3.new(0, 3.5, 0)), Vector3.new(0.95, 4, 0.95)
end

local exclude = {}

local function parryTargets(char, root)
    local box, size = parryBox(root)
    Probe.Size = size
    Probe.CFrame = box
    table.clear(exclude)
    exclude[1], exclude[2], exclude[3] = char, Probe, PvpProbe
    local noParry = Workspace:FindFirstChild("NoParry")
    if noParry then exclude[#exclude + 1] = noParry end
    local frame = towerFrame()
    if frame then exclude[#exclude + 1] = frame end
    probeParams.FilterDescendantsInstances = exclude
    local players = gui("ParryPlayers") == true
    local count = 0
    for _, part in ipairs(Workspace:GetPartsInPart(Probe, probeParams)) do
        local parent = part.Parent
        if part.CanCollide and not (parent and parent:FindFirstChild("Humanoid") and not players) then
            count = count + 1
        end
    end
    return count
end

local function pvpOn()
    local shadow = valueOf(PlayerGui:FindFirstChild("Roguelike"), "Shadow")
    if not shadow or shadow <= 0 then return false end
    local intermission = Lighting:FindFirstChild("Intermission")
    return gui("ParryPlayers") == true or not (intermission and intermission.Value)
end

-- other players and your shadow in the game's 9 stud pvp box
local function pvpTargets(char, root)
    local _, yaw = root.CFrame:ToOrientation()
    PvpProbe.CFrame = CFrame.new(root.Position) * CFrame.fromOrientation(0, yaw, 0)
    pvpParams.FilterDescendantsInstances = { char, Probe, PvpProbe }
    local players = gui("ParryPlayers") == true
    local people, shadows = 0, 0
    for _, part in ipairs(Workspace:GetPartsInPart(PvpProbe, pvpParams)) do
        local parent = part.Parent
        if parent then
            if parent.Name:sub(1, 7) == "_shadow" then
                shadows = shadows + 1
            elseif players and parent ~= char and Players:GetPlayerFromCharacter(parent)
                and parent:FindFirstChild("HumanoidRootPart") then
                people = people + 1
            end
        end
    end
    return people, shadows
end

--// perfect parry -------------------------------------------------------------------------
-- The blue parry screen is the perfect window opening: press again on it.

local function windowColor(color)
    return math.abs(color.R - 0.5) < 0.02 and math.abs(color.G - 0.5) < 0.02 and math.abs(color.B - 1) < 0.02
end

local function bindParryScreen(screen)
    if screen.Name ~= "ParryScreen" then return end
    task.spawn(function()
        local frame = screen:WaitForChild("Frame", 10)
        if not frame or Unloaded then return end
        track(frame:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
            if Unloaded or not Perfect.Enabled or not windowColor(frame.BackgroundColor3) then return end
            if gui("CanPerfPar") == false or gui("PerfPar") == true then return end
            -- a perfect parry holds you for 2 s: not with an entity about to need a parry
            if dangerWithin(os.clock(), 2.4) then
                Perfect.held = Perfect.held + 1
                return
            end
            if press() then Perfect.count = Perfect.count + 1 end
        end))
    end)
end

--// omni parry ----------------------------------------------------------------------------
-- The window is a flag in the parry function, raised 1.985 s into the perfect
-- parry's slow motion and dropped at 2 s. With the debug library that flag is
-- watched directly: the one true/false value that flips on in that span. Without
-- it, the press goes in on the first frame after 1.985 s.

local Omni = { watching = false, t0 = 0, before = nil, beat = 0 }

local function omniStart()
    findPress()
    if not Perfect.Omni or gui("OmniParry") ~= true or gui("AutoOmniParry") == true then return end
    Omni.watching, Omni.t0, Omni.before, Omni.beat = true, os.clock(), nil, 0
end

local function omniFire()
    Omni.watching = false
    -- the cutscene holds you for about ten seconds
    if dangerWithin(os.clock(), 10) then
        Perfect.held = Perfect.held + 1
        return
    end
    if press() then Perfect.omni = Perfect.omni + 1 end
end

local function parryFlags()
    if not Press.parry or type(debug.getupvalues) ~= "function" then return nil end
    local ok, list = pcall(debug.getupvalues, Press.parry)
    if ok and type(list) == "table" then return list end
    return nil
end

local function omniCheck(phase)
    if not Omni.watching then return end
    local elapsed = os.clock() - Omni.t0
    if elapsed > 2.25 then
        Omni.watching = false
        Perfect.missed = Perfect.missed + 1
        return
    end
    local flags = parryFlags()
    if flags then
        if elapsed < 1.96 then
            local before = {}
            for key, value in pairs(flags) do
                if type(value) == "boolean" then before[key] = value end
            end
            Omni.before = before
            return
        end
        if not Omni.before then return end
        for key, value in pairs(flags) do
            if value == true and Omni.before[key] == false then
                omniFire()
                return
            end
        end
        return
    end
    if phase == "beat" then
        Omni.beat = elapsed
    elseif phase == "render" and Omni.beat >= 1.987 and Omni.beat < 1.998 then
        omniFire()
    end
end

--// entities ------------------------------------------------------------------------------

local Controls = nil
local frozenUntil = 0

local function controls()
    if Controls == nil then
        local ok, result = pcall(function()
            local module = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 2)
            return require(module):GetControls()
        end)
        Controls = ok and result or false
    end
    return Controls or nil
end

-- chatbox only hurts you if you move in its window: when a parry is already
-- running and cannot be started, stand still instead
local function freezeMovement(seconds)
    local module = controls()
    if not module then return end
    frozenUntil = math.max(frozenUntil, os.clock() + seconds)
    pcall(function() module:Disable() end)
    task.delay(seconds + 0.05, function()
        if os.clock() >= frozenUntil then pcall(function() module:Enable() end) end
    end)
end

local Chat = { at = -math.huge }

local function entityPress(kind)
    if Unloaded or not Entities[kind] or not character() then return end
    local rogue = PlayerGui:FindFirstChild("Roguelike")
    if kind == "Chatbox" then
        -- too late to parry it now (see chatboxEyes): if the eyes were missed,
        -- keeping still is all that is left
        if os.clock() - Chat.at > 0.6 then freezeMovement(0.3) end
        return
    end
    if kind == "builderman" and valueOf(rogue and rogue:FindFirstChild("BuildermanScript"), "IFrame") == true then
        return   -- a perfect parry's slow motion: its hits do not count
    end
    if gui("ParryCD") == true or gui("CanParry") == false then
        Entities.blocked = Entities.blocked + 1
        return
    end
    if press() then Entities.parried = Entities.parried + 1 end
end

-- the chatbox's CanParry lasts 0.15 s, but the parry only reads it when the
-- freeze ends 0.2 s after the press, so the press goes in just after its eyes
-- show up, 0.2 s before the window, and you keep still through it as well
local function chatboxEyes()
    Chat.at = os.clock()
    if not Entities.Chatbox then return end
    task.delay(0.07, function()
        if Unloaded or not Entities.Chatbox or not character() then return end
        if gui("ParryCD") ~= true and gui("CanParry") ~= false and press() then
            Entities.parried = Entities.parried + 1
        else
            Entities.blocked = Entities.blocked + 1
        end
        freezeMovement(0.45)
    end)
end

local KINDS = { AdScript = "Ad", ChatboxScript = "Chatbox", NoobScript = "Noob", BuildermanScript = "builderman" }

local function bindFlag(holder, kind)
    task.spawn(function()
        local flag = holder:WaitForChild("CanParry", 10)
        if not flag or Unloaded then return end
        track(flag.Changed:Connect(function()
            if flag.Value == true then entityPress(kind) end
        end))
    end)
end

-- bacons that showed up and still need the parry on cooldown
local Bacons = {}

local function roguelikeChild(child)
    local kind = KINDS[child.Name]
    if kind then
        bindFlag(child, kind)
    elseif child.Name == "AdvertisementClone" then
        addDanger(os.clock() + 1.8)
    elseif child.Name == "BaconClone" then
        Bacons[#Bacons + 1] = os.clock()
    end
end

local function bindRoguelike(holder)
    if holder.Name ~= "Roguelike" then return end
    for _, child in ipairs(holder:GetChildren()) do roguelikeChild(child) end
    track(holder.ChildAdded:Connect(roguelikeChild))
    -- the chatbox types "..." 1.3 s before its eyes
    task.spawn(function()
        local box = holder:WaitForChild("TheChatbox", 10)
        local text = box and box:WaitForChild("Text", 10)
        if not text or Unloaded then return end
        track(text:GetPropertyChangedSignal("Text"):Connect(function()
            if text.Text == "..." then
                addDanger(os.clock() + 1.37)
            elseif text.Text == "\u{1F440}" then
                chatboxEyes()
            end
        end))
    end)
end

local dodgeParams = RaycastParams.new()
dodgeParams.FilterType = Enum.RaycastFilterType.Exclude

-- the bullet checks where you stood when it fired, 0.3 s later: be elsewhere
local function dodge()
    if Unloaded or not Entities.Cowboy then return end
    local char, root, hum = character()
    if not char then return end
    if not root.Anchored and (root.AssemblyLinearVelocity * 0.3).Magnitude > 4 then return end
    dodgeParams.FilterDescendantsInstances = { char, Probe, PvpProbe }
    local look = root.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
    local right = Vector3.new(-flat.Z, 0, flat.X)
    local grounded = hum.FloorMaterial ~= Enum.Material.Air
    for _, dir in ipairs({ right, -right, -flat, flat }) do
        local offset = dir * DODGE_DISTANCE
        if not Workspace:Raycast(root.Position, dir * (DODGE_DISTANCE + 1.5), dodgeParams)
            and (not grounded or Workspace:Raycast(root.Position + offset, Vector3.new(0, -8, 0), dodgeParams)) then
            char:PivotTo(char:GetPivot() + offset)
            Entities.dodged = Entities.dodged + 1
            return
        end
    end
    -- boxed in: up, and still rising when it checks
    char:PivotTo(char:GetPivot() + Vector3.new(0, DODGE_DISTANCE, 0))
    if not root.Anchored then root.AssemblyLinearVelocity = Vector3.new(0, 40, 0) end
    Entities.dodged = Entities.dodged + 1
end

local ShadowMark = Instance.new("Highlight")
ShadowMark.Name = "ParryAssistShadow"
ShadowMark.FillColor = Color3.fromRGB(150, 60, 255)
ShadowMark.OutlineColor = Color3.fromRGB(220, 180, 255)
ShadowMark.FillTransparency = 0.6
ShadowMark.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
ShadowMark.Enabled = false
pcall(function()
    local root = typeof(gethui) == "function" and gethui() or game:GetService("CoreGui")
    ShadowMark.Parent = root
end)
if not ShadowMark.Parent then ShadowMark.Parent = PlayerGui end

local LastShadow = nil

-- a shadow is rebuilt every frame, so each new copy is marked and made harmless
local function shadowAdded(model)
    LastShadow = model
    if Entities.ShadowEsp then
        ShadowMark.Adornee = model
        ShadowMark.Enabled = true
    end
    if Entities.ShadowSafe then
        local function safe(part)
            if part:IsA("BasePart") then part.CanTouch = false end
        end
        for _, part in ipairs(model:GetChildren()) do safe(part) end
        model.ChildAdded:Connect(safe)
    end
end

--// antis ---------------------------------------------------------------------------------

local KillBricks = {}   -- part -> CanTouch before

local function isKillBrick(part)
    if not part:IsA("BasePart") then return false end
    if part.Name:lower():sub(1, 4) == "kill" then return true end
    return part:FindFirstChild("kills") ~= nil or part:FindFirstChild("DamageScript") ~= nil
end

local function guardKillBrick(part)
    if Anti.KillBricks and KillBricks[part] == nil and isKillBrick(part) then
        KillBricks[part] = part.CanTouch
        part.CanTouch = false
    end
end

local function setKillBricks(on)
    Anti.KillBricks = on
    if on then
        local tower = Workspace:FindFirstChild("CurrentTower")
        if tower then
            for _, part in ipairs(tower:GetDescendants()) do guardKillBrick(part) end
        end
    else
        for part, before in pairs(KillBricks) do
            pcall(function() part.CanTouch = before end)
        end
        table.clear(KillBricks)
    end
end

-- the curses only exist as these values, so an anti just keeps them off, and
-- puts back whatever they were when it is switched off again
local Pins = {}

local function pin(key, on, object, forced)
    local held = Pins[key]
    if on then
        if object and object.Value ~= forced then
            Pins[key] = { object = object, wanted = object.Value }
            object.Value = forced
        end
    elseif held then
        Pins[key] = nil
        if held.object.Parent and held.object.Value == forced then held.object.Value = held.wanted end
    end
end

local function curses()
    local folder = PlayerGui:FindFirstChild("Curses")
    pin("Platforms", Anti.Platforms, folder and folder:FindFirstChild("Platforms"), false)
    pin("Legs", Anti.Legs, folder and folder:FindFirstChild("Legs"), false)
    pin("Wings", Anti.Wings, PlayerGui:FindFirstChild("NoParryJump"), false)
    if Anti.Jupiter then
        if math.abs(Workspace.Gravity - 236.2) < 0.01 then
            Pins.Gravity = true
            Workspace.Gravity = 196.2
        end
    elseif Pins.Gravity then
        Pins.Gravity = nil
        if math.abs(Workspace.Gravity - 196.2) < 0.01 then Workspace.Gravity = 236.2 end
    end
end

--// frame loop ----------------------------------------------------------------------------

local function step()
    findPress()
    curses()
    local char, root, hum = character()
    if not char then
        Auto.seenAt, Auto.inRange = nil, 0
        return
    end
    local now = os.clock()
    local ready = canStart(char)
    local hits = nil

    -- bacon: any parry on cooldown within the second covers you; a real one if
    -- a part comes into range in time, a missed one if not
    while #Bacons > 0 and (gui("ParryCD") == true or now - Bacons[1] > 1.2) do table.remove(Bacons, 1) end
    if #Bacons > 0 and Entities.Bacon and ready then
        hits = parryTargets(char, root)
        if (hits > 0 or now - Bacons[1] >= 0.8) and press() then
            table.remove(Bacons, 1)
            Entities.parried = Entities.parried + 1
            return
        end
    end

    if Auto.Enabled then
        hits = hits or parryTargets(char, root)
        Auto.inRange = hits
        if hits == 0 then
            Auto.seenAt = nil
        elseif ready and not (Auto.AirOnly and hum.FloorMaterial ~= Enum.Material.Air) and not dangerWithin(now, 0.45) then
            Auto.seenAt = Auto.seenAt or now
            if now - Auto.seenAt >= Auto.Delay / 1000 and press() then
                Auto.seenAt = nil
                Auto.count = Auto.count + 1
                return
            end
        end
    else
        Auto.inRange = 0
    end

    Pvp.active = pvpOn()
    if Pvp.active and (Pvp.Enabled or Entities.Shadow) then
        local people, shadows = pvpTargets(char, root)
        Pvp.players = people
        if ready and not dangerWithin(now, 0.45)
            and ((Pvp.Enabled and people > 0) or (Entities.Shadow and shadows > 0)) and press() then
            Pvp.count = Pvp.count + 1
        end
    else
        Pvp.players = 0
    end
end

local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn('[parry assist] ' .. tostring(err)) end
end

track(RunService.RenderStepped:Connect(function() guarded(omniCheck, "render") end))
track(RunService.Stepped:Connect(function() guarded(omniCheck, "step") end))
track(RunService.Heartbeat:Connect(function()
    guarded(omniCheck, "beat")
    guarded(step)
end))

for _, child in ipairs(PlayerGui:GetChildren()) do
    bindParryScreen(child)
    bindRoguelike(child)
end
track(PlayerGui.ChildAdded:Connect(function(child)
    bindParryScreen(child)
    bindRoguelike(child)
end))

-- deferred: the bullet's aim is taken right after it is parented, and a shadow
-- is parented before it is named
track(Workspace.ChildAdded:Connect(function(child)
    if child.Name == "Bullet" then
        task.defer(guarded, dodge)
    elseif child:IsA("Model") then
        task.defer(function()
            if child.Parent and child.Name:sub(1, 7) == "_shadow" then guarded(shadowAdded, child) end
        end)
    end
end))

local function bindTower(tower)
    if tower.Name ~= "CurrentTower" then return end
    track(tower.DescendantAdded:Connect(guardKillBrick))
end
local currentTower = Workspace:FindFirstChild("CurrentTower")
if currentTower then bindTower(currentTower) end
track(Workspace.ChildAdded:Connect(bindTower))

task.spawn(function()
    local effect = Lighting:WaitForChild("ParryEffect", 30)
    if not effect or Unloaded then return end
    track(effect:GetPropertyChangedSignal("Enabled"):Connect(function()
        if effect.Enabled then omniStart() else Omni.watching = false end
    end))
end)

local Onyx

local function unload()
    if Unloaded then return end
    Unloaded = true
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    Anti.Platforms, Anti.Legs, Anti.Wings, Anti.Jupiter = false, false, false, false
    pcall(curses)
    setKillBricks(false)
    if Controls then pcall(function() Controls:Enable() end) end
    pcall(function() Probe:Destroy() end)
    pcall(function() PvpProbe:Destroy() end)
    pcall(function() ShadowMark:Destroy() end)
    if Genv.__ParryFlingStop == unload then Genv.__ParryFlingStop = nil end
    if Onyx and not Onyx.Unloaded then pcall(function() Onyx:Unload() end) end
end
Genv.__ParryFlingStop = unload
Genv.ParryFling = { Auto = Auto, Perfect = Perfect, Entities = Entities, Pvp = Pvp, Anti = Anti, Press = Press, Unload = unload }

--// ui ------------------------------------------------------------------------------------

do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Onyx] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/Ui.lua'):format(ref)
    Onyx = loadstring(game:HttpGet(url))()
end

local Window = Onyx:CreateWindow({
    Title = 'parry fling',
    SubTitle = 'assist',
    Folder = 'ParryFling',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 170, 60),
})

-- closing the menu from its own settings tears the script down too
Onyx.OnUnload = unload

local function toggle(section, title, description, flag, owner, key, changed)
    section:Toggle({
        Title = title,
        Description = description,
        Default = owner[key],
        Flag = flag,
        Callback = function(state)
            state = state == true
            owner[key] = state
            if changed then changed(state) end
        end,
    })
end

local function plural(n) return n == 1 and '' or 's' end

do
    local Tab = Window:CreateTab({ Title = 'parry', Default = true })

    local section = Tab:CreateSection('auto parry')
    toggle(section, 'auto parry', 'parries the moment a part is in the parry hitbox, so it never misses and never punishes you', 'pf_auto', Auto, 'Enabled')
    toggle(section, 'only in the air', 'leaves it alone while you stand on something', 'pf_air', Auto, 'AirOnly')
    section:Slider({
        Title = 'reaction delay',
        Min = 0,
        Max = 300,
        Default = Auto.Delay,
        Increment = 5,
        Suffix = ' ms',
        Flag = 'pf_delay',
        Callback = function(value) if type(value) == "number" then Auto.Delay = value end end,
    })

    local perfect = Tab:CreateSection('perfect and omni')
    toggle(perfect, 'auto perfect parry', 'presses again the instant the perfect window opens (the game turns the parry screen blue), for the 400 launch. works on your own presses too', 'pf_perfect', Perfect, 'Enabled')
    toggle(perfect, 'auto omni parry', 'presses in the 15 ms omni window at the end of a perfect parry, for the 800 launch. needs omni parry switched on in the game', 'pf_omni', Perfect, 'Omni')

    local status = Tab:CreateSection('status')
    status:Label({ Title = function()
        return ('press: %s%s'):format(pressHow(), Press.parry and ' (omni flag found)' or '')
    end })
    status:Label({ Title = function()
        return ('auto %d  |  perfect %d  |  omni %d  |  omni missed %d'):format(Auto.count, Perfect.count, Perfect.omni, Perfect.missed)
    end })
    status:Label({ Title = function()
        local cd = gui("ParryCD") == true and 'on cooldown' or 'ready'
        local omni = gui("OmniParry") == true and 'on' or 'off'
        return ('parts in range %d  |  %s  |  omni in game %s'):format(Auto.inRange, cd, omni)
    end })
end

do
    local Tab = Window:CreateTab({ Title = 'entities' })

    local section = Tab:CreateSection('auto parry entities')
    toggle(section, 'ad', 'parries in the ad\'s window', 'pf_ad', Entities, 'Ad')
    toggle(section, 'chatbox', 'parries the eyes and keeps you still through them', 'pf_chatbox', Entities, 'Chatbox')
    toggle(section, 'noob', 'parries when its dash reaches you', 'pf_noob', Entities, 'Noob')
    toggle(section, 'builderman', 'parries every attack that hits you', 'pf_builderman', Entities, 'builderman')
    toggle(section, 'bacon', 'gets your parry on cooldown in time: a real parry if a part comes into range, a missed one if not', 'pf_bacon', Entities, 'Bacon')

    local other = Tab:CreateSection('cowboy and shadow')
    toggle(other, 'cowboy dodge', 'steps aside when it fires, since the bullet only checks where you stood', 'pf_cowboy', Entities, 'Cowboy')
    toggle(other, 'parry your shadow', 'parries when your shadow gets within the pvp box, which launches you away from it', 'pf_shadow', Entities, 'Shadow')
    toggle(other, "shadow can't kill you", 'your shadow stops counting touches', 'pf_shadow_safe', Entities, 'ShadowSafe')
    toggle(other, 'shadow esp', nil, 'pf_shadow_esp', Entities, 'ShadowEsp', function(state)
        ShadowMark.Enabled = state and LastShadow ~= nil and LastShadow.Parent ~= nil
        if state and LastShadow then ShadowMark.Adornee = LastShadow end
    end)

    local pvp = Tab:CreateSection('pvp')
    toggle(pvp, 'auto pvp parry', 'parries when another player is in the game\'s 9 stud pvp box. the game only has pvp parries while the shadow entity is on, with parry players on or a round running', 'pf_pvp', Pvp, 'Enabled')

    local status = Tab:CreateSection('status')
    status:Label({ Title = function()
        local rogue = PlayerGui:FindFirstChild("Roguelike")
        local list = {}
        for _, name in ipairs({ "Ad", "Bacon", "Chatbox", "Cowboy", "Noob", "Shadow", "builderman" }) do
            local count = valueOf(rogue, name)
            if type(count) == "number" and count > 0 then list[#list + 1] = ('%s %d'):format(name, count) end
        end
        return 'entities: ' .. (#list > 0 and table.concat(list, ', ') or 'none')
    end })
    status:Label({ Title = function()
        return ('parried %d  |  dodged %d  |  could not parry %d'):format(Entities.parried, Entities.dodged, Entities.blocked)
    end })
    status:Label({ Title = function()
        if not Pvp.active then return 'pvp: off in this round' end
        return ('pvp: on  |  %d player%s in range  |  pvp parries %d'):format(Pvp.players, plural(Pvp.players), Pvp.count)
    end })
end

do
    local Tab = Window:CreateTab({ Title = 'extra' })

    local section = Tab:CreateSection('anti')
    toggle(section, 'anti kill bricks', 'kill bricks stop registering your touch', 'pf_anti_kill', Anti, 'KillBricks', setKillBricks)
    toggle(section, 'anti platforms curse', 'platforms stop disappearing', 'pf_anti_platforms', Anti, 'Platforms')
    toggle(section, 'anti legs curse', 'double jumps stop failing', 'pf_anti_legs', Anti, 'Legs')
    toggle(section, 'anti wings curse', 'parries give their double jump back', 'pf_anti_wings', Anti, 'Wings')
    toggle(section, 'anti jupiter curse', 'normal gravity', 'pf_anti_jupiter', Anti, 'Jupiter')

    local scriptSection = Tab:CreateSection('script')
    scriptSection:Button({ Title = 'unload', Callback = unload })
end

Onyx:Notify({ Title = 'parry fling', Content = 'Loaded. Turn on auto parry to start.', Type = 'success', Duration = 5 })

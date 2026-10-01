--// [OMNI PARRY] parry fling but its hard -- auto parry, auto perfect and omni
--// parry, faster slow motion and cutscene, entity parries, pvp parry and antis.
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
--  * The slow motion and the cutscene are plain task.wait calls inside that
--    script, so swapping its task for one that shortens just those waits speeds
--    them up for every parry, yours included.
--  * Roguelike entities live in PlayerGui.Roguelike. Ad, Chatbox, Noob and
--    builderman each raise a CanParry value for a short window; a parry started
--    inside it beats them, otherwise they deal 100 (60 for builderman). The
--    chatbox's is read only when the 0.2 s freeze ends, so its press goes in
--    just after the eyes. Bacon only needs your parry on cooldown within a
--    second. Cowboy's bullet checks a 1 stud cube where you stood when it fired,
--    0.3 s later. Shadows (_shadowN) are a delayed copy of you that kills on
--    touch. builderman drops glitch orbs (Orb) that hurt him when touched.
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
local TweenService = game:GetService("TweenService")
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

local Auto = { Enabled = false, AirOnly = false, Delay = 0, Predict = true, seenAt = nil, count = 0, inRange = 0 }
local Perfect = { Enabled = false, Omni = false, count = 0, omni = 0, missed = 0, held = 0 }
local Fast = { Slowmo = false, Cutscene = false, env = nil, had = nil, cut = 0, failed = false }
local Entities = {
    Ad = false, Chatbox = false, Noob = false, builderman = false, Bacon = false,
    Cowboy = false, Shadow = false, ShadowSafe = false, ShadowEsp = false,
    Orbs = false, Esp = false, HideAds = false,
    parried = 0, dodged = 0, blocked = 0, orbs = 0,
}
local Pvp = { Enabled = false, count = 0, active = false, players = 0 }
local Anti = { KillBricks = false, Platforms = false, Legs = false, Wings = false, Jupiter = false, Void = false, saves = 0 }
local Show = { Indicator = false }
local Bot = {
    Enabled = false, Perfect = false, Omni = false, Missed = true, DoubleJumps = true, Protect = true,
    StopOnWin = true, ShowPad = false,
    mode = 'off', tower = nil, pad = nil, parts = {}, bounds = nil, scannedAt = -math.huge,
    lastLaunch = -math.huge, noclip = 0, prevVy = 0, bestY = -math.huge, bestAt = 0,
    avoid = {}, wanderUntil = 0, wanderDir = nil, target = nil, jumpedAt = -math.huge,
    misses = 0, startedAt = 0, took = nil, wins = 0, winsAt = nil, wonBefore = false,
    protecting = false, holding = false, skipPerfect = false, skipOmni = false, handle = nil,
}
local Frame = { dt = 1 / 60 }

local DODGE_DISTANCE = 4.5
local LEAD = 0.22          -- press to the end of the freeze, with a frame of rounding
local SLOWMO = 0.3         -- a perfect parry's slow motion, sped up
local OMNI_SPAN = 0.05     -- and the omni window at its end

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

local function guiRoot()
    local ok, root = pcall(function() return typeof(gethui) == "function" and gethui() or game:GetService("CoreGui") end)
    return ok and root or PlayerGui
end
local GuiRoot = guiRoot()

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

--// speed ---------------------------------------------------------------------------------
-- The parry script's own task, with its two long waits shortened: the 2 s slow
-- motion (2 s while Lighting.ParryEffect is on; the punish's 2 s is left alone)
-- and the omni cutscene's waits (while the camera is Scriptable). The omni flag's
-- 1.985 s moves with the slow motion so the omni window stays at its end.

local realTask = task
local CUTSCENE = { 7 / 6, 0.75, 1, 7 / 3 }

local function slowmoRunning()
    local effect = Lighting:FindFirstChild("ParryEffect")
    return effect ~= nil and effect.Enabled == true
end

local function inCutscene()
    local camera = Workspace.CurrentCamera
    return camera ~= nil and camera.CameraType == Enum.CameraType.Scriptable
end

local FastTask = setmetatable({
    wait = function(t)
        if type(t) == "number" then
            if Fast.Slowmo and t == 2 and slowmoRunning() then
                t = SLOWMO
                Fast.cut = Fast.cut + 1
            elseif Fast.Cutscene and inCutscene() then
                for _, long in ipairs(CUTSCENE) do
                    if math.abs(t - long) < 1e-6 then
                        t = 0.03
                        Fast.cut = Fast.cut + 1
                        break
                    end
                end
            end
        end
        return realTask.wait(t)
    end,
    delay = function(t, ...)
        if Fast.Slowmo and t == 1.985 then t = SLOWMO - OMNI_SPAN end
        return realTask.delay(t, ...)
    end,
}, { __index = realTask })

local function installFast()
    if Fast.env or Fast.failed then return end
    local fn = Press.parry or Press.fn
    if not fn then return end
    -- getfenv also turns off the script's cached globals, so the swap is seen
    local ok, env = pcall(getfenv, fn)
    if not ok or type(env) ~= "table" then
        Fast.failed = true
        return
    end
    Fast.had = rawget(env, "task")
    rawset(env, "task", FastTask)
    Fast.env = env
end

local function removeFast()
    if not Fast.env then return end
    pcall(rawset, Fast.env, "task", Fast.had)
    Fast.env = nil
end

-- a sped up cutscene leaves its last camera tween running for a second and a
-- half after the camera is handed back: stop it there
local lastCameraType = nil
local function cameraWatch()
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local kind = camera.CameraType
    if Fast.env and Fast.Cutscene and lastCameraType == Enum.CameraType.Scriptable and kind ~= Enum.CameraType.Scriptable then
        TweenService:Create(camera, TweenInfo.new(0), { CFrame = camera.CFrame, FieldOfView = camera.FieldOfView }):Play()
    end
    lastCameraType = kind
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
local Ahead = newProbe("ParryAssistAhead")
local PvpProbe = newProbe("ParryAssistPvpProbe")
PvpProbe.Size = Vector3.new(9, 9, 9)

local probeParams = OverlapParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.RespectCanCollide = true

local aheadParams = OverlapParams.new()
aheadParams.FilterType = Enum.RaycastFilterType.Include

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

-- a part on the move (a swinging or falling platform) has to still be in the
-- box when the freeze ends, or the parry misses and punishes you
local Motion = setmetatable({}, { __mode = "k" })

local function stillThere(part, box, size, now)
    local pos = part.Position
    local seen = Motion[part]
    Motion[part] = { pos = pos, t = now }
    local okV, velocity = pcall(function() return part:GetVelocityAtPosition(box.Position) end)
    if not okV or typeof(velocity) ~= "Vector3" then velocity = part.AssemblyLinearVelocity end
    if seen and now - seen.t > 0 and now - seen.t < 0.1 then
        local moved = (pos - seen.pos) / (now - seen.t)
        if moved.Magnitude > velocity.Magnitude then velocity = moved end
    end
    if velocity.Magnitude < 1 then return true end
    Ahead.Size = size
    Ahead.CFrame = box - velocity * LEAD
    aheadParams.FilterDescendantsInstances = { part }
    return #Workspace:GetPartsInPart(Ahead, aheadParams) > 0
end

local exclude = {}

local function parryTargets(char, root)
    local box, size = parryBox(root)
    Probe.Size = size
    Probe.CFrame = box
    table.clear(exclude)
    exclude[1], exclude[2], exclude[3], exclude[4] = char, Probe, PvpProbe, Ahead
    local noParry = Workspace:FindFirstChild("NoParry")
    if noParry then exclude[#exclude + 1] = noParry end
    local frame = towerFrame()
    if frame then exclude[#exclude + 1] = frame end
    probeParams.FilterDescendantsInstances = exclude
    local players = gui("ParryPlayers") == true
    local now = os.clock()
    local count = 0
    for _, part in ipairs(Workspace:GetPartsInPart(Probe, probeParams)) do
        local parent = part.Parent
        if part.CanCollide and not (parent and parent:FindFirstChild("Humanoid") and not players)
            and (not Auto.Predict or stillThere(part, box, size, now)) then
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

-- a player who is about to leave the box will be gone when the freeze ends
local function staysInBox(model, box)
    local root = model:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local inverse = box:Inverse()
    for _, point in ipairs({ root.Position, root.Position + root.AssemblyLinearVelocity * LEAD }) do
        local p = inverse * point
        if math.abs(p.X) > 4.25 or math.abs(p.Y) > 4.25 or math.abs(p.Z) > 4.25 then return false end
    end
    return true
end

-- other players and your shadow in the game's 9 stud pvp box
local function pvpTargets(char, root)
    local _, yaw = root.CFrame:ToOrientation()
    local box = CFrame.new(root.Position) * CFrame.fromOrientation(0, yaw, 0)
    PvpProbe.CFrame = box
    pvpParams.FilterDescendantsInstances = { char, Probe, PvpProbe, Ahead }
    local players = gui("ParryPlayers") == true
    local people, shadows, seen = 0, 0, {}
    for _, part in ipairs(Workspace:GetPartsInPart(PvpProbe, pvpParams)) do
        local parent = part.Parent
        if parent and not seen[parent] then
            seen[parent] = true
            if parent.Name:sub(1, 7) == "_shadow" then
                shadows = shadows + 1
            elseif players and parent ~= char and Players:GetPlayerFromCharacter(parent) and staysInBox(parent, box) then
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

-- how long a perfect parry holds you
local function perfectHold()
    return (Fast.env and Fast.Slowmo) and SLOWMO + 0.35 or 2.4
end

local function bindParryScreen(screen)
    if screen.Name ~= "ParryScreen" then return end
    task.spawn(function()
        local frame = screen:WaitForChild("Frame", 10)
        if not frame or Unloaded then return end
        track(frame:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
            local wanted = Perfect.Enabled or (Bot.Enabled and Bot.Perfect and not Bot.skipPerfect)
            if Unloaded or not wanted or not windowColor(frame.BackgroundColor3) then return end
            if gui("CanPerfPar") == false or gui("PerfPar") == true then return end
            -- not with an entity about to need a parry while it holds you
            if dangerWithin(os.clock(), perfectHold()) then
                Perfect.held = Perfect.held + 1
                return
            end
            if press() then Perfect.count = Perfect.count + 1 end
        end))
    end)
end

--// omni parry ----------------------------------------------------------------------------
-- The window is a flag in the parry function, raised 1.985 s into the perfect
-- parry's slow motion and dropped at 2 s (0.25 and 0.3 s sped up). With the
-- debug library that flag is watched directly: the one true/false value that
-- flips on in that span. Without it, the press goes in by the clock.

local Omni = { watching = false, t0 = 0, before = nil, beat = 0, flagAt = 1.985, endAt = 2 }

local function omniStart()
    findPress()
    local wanted = Perfect.Omni or (Bot.Enabled and Bot.Omni and not Bot.skipOmni)
    if not wanted or gui("OmniParry") ~= true or gui("AutoOmniParry") == true then return end
    Omni.watching, Omni.t0, Omni.before, Omni.beat = true, os.clock(), nil, 0
    if Fast.env and Fast.Slowmo then
        Omni.flagAt, Omni.endAt = SLOWMO - OMNI_SPAN, SLOWMO
    else
        Omni.flagAt, Omni.endAt = 1.985, 2
    end
end

local function omniFire()
    Omni.watching = false
    -- the cutscene holds you for about ten seconds (a blink sped up)
    if dangerWithin(os.clock(), (Fast.env and Fast.Cutscene) and 1 or 10) then
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
    if elapsed > Omni.endAt + 0.25 then
        Omni.watching = false
        Perfect.missed = Perfect.missed + 1
        return
    end
    local flags = parryFlags()
    if flags then
        if elapsed < Omni.flagAt - 0.025 then
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
    elseif phase == "render" and Omni.beat >= Omni.flagAt + 0.002 and Omni.beat < Omni.endAt - 0.002 then
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

-- chatbox only hurts you if you move in its window: stand still through it
local function freezeMovement(seconds)
    local module = controls()
    if not module then return end
    frozenUntil = math.max(frozenUntil, os.clock() + seconds)
    pcall(function() module:Disable() end)
    task.delay(seconds + 0.05, function()
        if os.clock() >= frozenUntil and not Bot.holding then pcall(function() module:Enable() end) end
    end)
end

local Chat = { at = -math.huge, pressedAt = -math.huge }

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

local function chatboxPress()
    if Unloaded or not Entities.Chatbox or not character() then return end
    local now = os.clock()
    if now - Chat.pressedAt < 1 then return end
    Chat.pressedAt = now
    if gui("ParryCD") ~= true and gui("CanParry") ~= false and press() then
        Entities.parried = Entities.parried + 1
    else
        Entities.blocked = Entities.blocked + 1
    end
    freezeMovement(0.5)
end

-- The chatbox is open from 0.2 to 0.35 s after its eyes, and the parry reads it
-- when its own 0.2 s freeze ends, each wait rounded up to whole frames: aim for
-- the middle, which at a low frame rate means pressing on the eyes themselves.
local function chatboxLead()
    return math.clamp(0.07 - 1.5 * Frame.dt, 0, 0.05)
end

local function chatboxEyes()
    Chat.at = os.clock()
    if not Entities.Chatbox then return end
    local lead = chatboxLead()
    if lead <= 0 then chatboxPress() else task.delay(lead, chatboxPress) end
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
        -- after the ad script has shown it
        if Entities.HideAds then task.defer(function() child.Visible = false end) end
    elseif child.Name == "BaconClone" then
        Bacons[#Bacons + 1] = os.clock()
    end
end

local function bindRoguelike(holder)
    if holder.Name ~= "Roguelike" then return end
    for _, child in ipairs(holder:GetChildren()) do roguelikeChild(child) end
    track(holder.ChildAdded:Connect(roguelikeChild))
    -- the chatbox types "..." 1.3 s before its eyes, and ":eyes" 0.33 s before
    task.spawn(function()
        local box = holder:WaitForChild("TheChatbox", 10)
        local text = box and box:WaitForChild("Text", 10)
        if not text or Unloaded then return end
        track(text:GetPropertyChangedSignal("Text"):Connect(function()
            local said = text.Text
            if said == "..." then
                addDanger(os.clock() + 1.35)
            elseif said == ":eyes" then
                -- in case the eyes themselves never show up as text
                local typed = os.clock()
                task.delay(0.33 + chatboxLead() + 0.05, function()
                    if Chat.at < typed then chatboxPress() end
                end)
            elseif said == "\u{1F440}" then
                chatboxEyes()
            end
        end))
    end)
end

local dodgeParams = RaycastParams.new()
dodgeParams.FilterType = Enum.RaycastFilterType.Exclude

-- moves the whole character so its root lands on target
local function moveRootTo(char, root, target)
    char:PivotTo(target * (root.CFrame:Inverse() * char:GetPivot()))
end

-- the bullet checks where you stood when it fired, 0.3 s later: be elsewhere
local function dodge()
    if Unloaded or not Entities.Cowboy then return end
    local char, root, hum = character()
    if not char then return end
    if not root.Anchored and (root.AssemblyLinearVelocity * 0.3).Magnitude > 4 then return end
    dodgeParams.FilterDescendantsInstances = { char, Probe, PvpProbe, Ahead }
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

local function highlight(name, fill, outline)
    local mark = Instance.new("Highlight")
    mark.Name = name
    mark.FillColor = fill
    mark.OutlineColor = outline
    mark.FillTransparency = 0.6
    mark.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    mark.Parent = GuiRoot
    return mark
end

local ShadowMark = highlight("ParryAssistShadow", Color3.fromRGB(150, 60, 255), Color3.fromRGB(220, 180, 255))
ShadowMark.Enabled = false

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

-- noob, cowboy and builderman's orbs
local Marks = {}
local MARK_COLORS = {
    _noob = Color3.fromRGB(255, 70, 70),
    Cowboy = Color3.fromRGB(255, 200, 60),
    Orb = Color3.fromRGB(200, 90, 255),
}

local function markEntity(model)
    local color = MARK_COLORS[model.Name]
    if not color or not Entities.Esp or Marks[model] then return end
    local mark = highlight("ParryAssistMark", color, Color3.new(1, 1, 1))
    mark.Adornee = model
    Marks[model] = mark
end

local function clearMarks(all)
    for model, mark in pairs(Marks) do
        if all or not model.Parent then
            pcall(function() mark:Destroy() end)
            Marks[model] = nil
        end
    end
end

local function scanEntities()
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") then markEntity(child) end
    end
    local tower = Workspace:FindFirstChild("CurrentTower")
    if tower then
        for _, d in ipairs(tower:GetDescendants()) do
            if d.Name == "Orb" and d:IsA("Model") then markEntity(d) end
        end
    end
end

-- an orb hurts builderman when you touch it: bring it to you
local function collectOrb(model)
    if Unloaded or not Entities.Orbs or not model.Parent then return end
    local char, root = character()
    if not char then return end
    local touched = false
    for _, part in ipairs(model:GetChildren()) do
        if part:IsA("BasePart") then
            part.CFrame = root.CFrame
            touched = true
            if typeof(firetouchinterest) == "function" then
                pcall(firetouchinterest, root, part, 0)
                pcall(firetouchinterest, root, part, 1)
            end
        end
    end
    if touched then Entities.orbs = Entities.orbs + 1 end
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

-- anti void: the void under the map stops counting you, and a fall toward it
-- puts you back where you last stood
local Safe = { cf = nil, at = -math.huge, void = nil, voidTouch = nil }

local function voidPart()
    local folder = Workspace:FindFirstChild("NoParry")
    local void = folder and folder:FindFirstChild("Void")
    return void and void:IsA("BasePart") and void or nil
end

local function setVoid(on)
    Anti.Void = on
    local void = voidPart()
    if on and void then
        if Safe.void ~= void then
            Safe.void, Safe.voidTouch = void, void.CanTouch
        end
        void.CanTouch = false
    elseif Safe.void then
        pcall(function() Safe.void.CanTouch = Safe.voidTouch end)
        Safe.void = nil
    end
end

local function voidGuard(char, root, hum, now)
    if hum.FloorMaterial ~= Enum.Material.Air and not root.Anchored then
        if now - Safe.at > 0.25 then Safe.cf, Safe.at = root.CFrame, now end
        return
    end
    if not Safe.cf then return end
    local void = voidPart()
    local floor = void and (void.Position.Y + void.Size.Y / 2) or (Workspace.FallenPartsDestroyHeight + 60)
    local falling = math.min(root.AssemblyLinearVelocity.Y, 0)
    if root.Position.Y + falling * 0.1 < floor + 6 then
        moveRootTo(char, root, Safe.cf + Vector3.new(0, 3, 0))
        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        Anti.saves = Anti.saves + 1
    end
end

--// parry indicator -----------------------------------------------------------------------

local Indicator = {}

local function showIndicator(ready)
    if not Indicator.gui then
        local screen = Instance.new("ScreenGui")
        screen.Name = "ParryAssistIndicator"
        screen.ResetOnSpawn = false
        screen.IgnoreGuiInset = true
        local dot = Instance.new("Frame")
        dot.Size = UDim2.fromOffset(18, 18)
        dot.Position = UDim2.new(0.5, -9, 0.8, 0)
        dot.BorderSizePixel = 0
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = dot
        dot.Parent = screen
        screen.Parent = GuiRoot
        Indicator.gui, Indicator.dot = screen, dot
    end
    Indicator.gui.Enabled = Show.Indicator
    Indicator.dot.BackgroundColor3 = ready and Color3.fromRGB(80, 230, 120) or Color3.fromRGB(90, 90, 90)
end


local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn('[parry assist] ' .. tostring(err)) end
end

--// bot -------------------------------------------------------------------------------------
-- Beats the tower with the game's own moves. Every parry off the underside of a
-- platform adds 250 to your climb (400 perfect, 800 omni) and lets you pass
-- through the tower for a moment, so the bot keeps chaining them: in the air it
-- steers to the platform it can get under soonest before it stops rising, on
-- the ground it walks under one and jumps. Near the top it goes for the win pad,
-- flying into it from below or dropping onto it; overshot, a deliberate missed
-- parry throws you down at 200.

local PROBE_LOW, PROBE_HIGH = 1.5, 5.5

local function towerFolder()
    local current = Workspace:FindFirstChild("CurrentTower")
    if not current then return nil end
    for _, child in ipairs(current:GetChildren()) do
        if child:IsA("Folder") and child:FindFirstChild("Obby") then return child end
    end
    return current:FindFirstChildOfClass("Folder")
end

local function findPad(tower)
    local best, bestScore = nil, 0
    for _, d in ipairs(tower:GetDescendants()) do
        if d:IsA("BasePart") then
            local name = d.Name:lower()
            local score = (d.Name == "WinPad" and 3) or (d:FindFirstChild("WinScript") and 2)
                or ((name:find("win", 1, true) or name:find("finish", 1, true)) and 1) or 0
            if score > bestScore or (score > 0 and score == bestScore and d.Position.Y > best.Position.Y) then
                best, bestScore = d, score
            end
        end
    end
    return best
end

-- a part's box in the world
local function boxOf(part)
    local cf, s = part.CFrame, part.Size / 2
    local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
    local hx = math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z
    local hy = math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z
    local hz = math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
    local p = cf.Position
    return p.X - hx, p.X + hx, p.Y - hy, p.Y + hy, p.Z - hz, p.Z + hz
end

local function scanTower()
    local tower = towerFolder()
    Bot.tower, Bot.scannedAt = tower, os.clock()
    Bot.pad = tower and findPad(tower) or nil
    local list, walls = {}, nil
    if tower then
        local frame = tower:FindFirstChild("Frame")
        for _, d in ipairs(tower:GetDescendants()) do
            if d:IsA("BasePart") then
                local x0, x1, y0, y1, z0, z1 = boxOf(d)
                if walls then
                    walls.x0, walls.x1 = math.min(walls.x0, x0), math.max(walls.x1, x1)
                    walls.y0, walls.z0, walls.z1 = math.min(walls.y0, y0), math.min(walls.z0, z0), math.max(walls.z1, z1)
                else
                    walls = { x0 = x0, x1 = x1, y0 = y0, z0 = z0, z1 = z1 }
                end
                if not (frame and d:IsDescendantOf(frame)) and d ~= Bot.pad and d.CanCollide and not isKillBrick(d) then
                    list[#list + 1] = { part = d, moving = not d.Anchored, x0 = x0, x1 = x1, y0 = y0, y1 = y1, z0 = z0, z1 = z1 }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.y0 < b.y0 end)
    Bot.parts, Bot.bounds = list, walls
end

local function insideTower(p)
    local b = Bot.bounds
    if not b then return true end
    return p.X > b.x0 - 8 and p.X < b.x1 + 8 and p.Z > b.z0 - 8 and p.Z < b.z1 + 8 and p.Y > b.y0 - 20
end

-- how long a rise at vy takes to reach height h (nil if it never does)
local function riseTime(y, vy, h, g)
    local dy = h - y
    if dy <= 0 then return 0 end
    if vy <= 0 then return nil end
    local disc = vy * vy - 2 * g * dy
    if disc < 0 then return nil end
    return (vy - math.sqrt(disc)) / g
end

-- the nearest point to (x, z) on a footprint, kept a margin in from its edges
local function inside(x0, x1, z0, z1, x, z, margin)
    local mx, mz = math.min(margin, (x1 - x0) / 2), math.min(margin, (z1 - z0) / 2)
    return math.clamp(x, x0 + mx, x1 - mx), math.clamp(z, z0 + mz, z1 - mz)
end

local function flatDistance(p, x, z)
    return math.sqrt((x - p.X) ^ 2 + (z - p.Z) ^ 2)
end

-- first platform whose underside is above height y
local function firstAbove(y)
    local list = Bot.parts
    local lo, hi = 1, #list + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if list[mid].y0 <= y then lo = mid + 1 else hi = mid end
    end
    return lo
end

local function usable(e, now)
    if not e.part.Parent or (Bot.avoid[e.part] or 0) > now then return false end
    if e.moving then e.x0, e.x1, e.y0, e.y1, e.z0, e.z1 = boxOf(e.part) end
    return true
end

-- in the air: the platform you can get under soonest while still rising at vy
-- (one you would pass through anyway before the tower turns solid again is no use)
local function choose(p, vy, speed, g, noclipLeft, now, padX, padZ)
    if vy <= 0 then return nil end
    local apex = p.Y + vy * vy / (2 * g)
    local list = Bot.parts
    local best, bestScore, bx, bz
    local checked = 0
    for i = firstAbove(p.Y + PROBE_LOW), #list do
        local e = list[i]
        if e.y0 > apex + PROBE_HIGH then break end
        checked = checked + 1
        if checked > 600 then break end
        if usable(e, now) and e.y0 > p.Y + PROBE_LOW then
            -- the box sees it from when your root is 5.5 under it until 1.5 under it
            -- (or the top of your rise): you have until then to get under it
            local t = riseTime(p.Y, vy, e.y0 - PROBE_HIGH + 0.4, g)
            local last = t and riseTime(p.Y, vy, math.min(apex - 0.05, e.y0 - PROBE_LOW - 0.2), g)
            if t and last and last >= noclipLeft then
                local ax, az = inside(e.x0, e.x1, e.z0, e.z1, p.X, p.Z, 0.6)
                if flatDistance(p, ax, az) <= speed * last + 0.3 then
                    local score = t + 0.002 * math.sqrt((ax - padX) ^ 2 + (az - padZ) ^ 2)
                    if not best or score < bestScore then best, bestScore, bx, bz = e, score, ax, az end
                end
            end
        end
    end
    return best, bx, bz
end

local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude

-- standing: the nearest platform above that a jump (and a double jump) reaches,
-- with floor under the spot to jump from
local function chooseFromGround(char, p, reach, now)
    local list = Bot.parts
    floorParams.FilterDescendantsInstances = { char, Probe, PvpProbe, Ahead }
    local best, bestD, bx, bz
    local checked = 0
    for i = firstAbove(p.Y + PROBE_LOW), #list do
        local e = list[i]
        if e.y0 > p.Y + reach + PROBE_HIGH - 0.4 then break end
        checked = checked + 1
        if checked > 400 then break end
        if usable(e, now) then
            local ax, az = inside(e.x0, e.x1, e.z0, e.z1, p.X, p.Z, 0.6)
            local d = flatDistance(p, ax, az)
            if d < 40 and (not best or d < bestD)
                and (d < 1 or Workspace:Raycast(Vector3.new(ax, p.Y, az), Vector3.new(0, -4.5, 0), floorParams)) then
                best, bestD, bx, bz = e, d, ax, az
            end
        end
    end
    return best, bx, bz, bestD
end

local function jumpPower(hum)
    local power = hum.JumpPower
    return (type(power) == "number" and power > 0) and power or 50
end

-- the game's own double jump (its space key handler), so its jump count and curses apply
local Jumper = { fn = nil, lookedAt = -math.huge }

local function doubleJump()
    if gui("CanDoubleJump") == false or (gui("TempJumps") or 0) <= 0 then return false end
    if not Jumper.fn and os.clock() - Jumper.lookedAt > 2 and typeof(getconnections) == "function" then
        Jumper.lookedAt = os.clock()
        local ok, list = pcall(getconnections, game:GetService("UserInputService").InputBegan)
        if ok and type(list) == "table" then
            for _, connection in ipairs(list) do
                local okFn, fn = pcall(function() return connection.Function end)
                if okFn and type(fn) == "function" then
                    local okSource, source = pcall(debug.info, fn, "s")
                    if okSource and type(source) == "string" and source:find("DoubleJump", 1, true) then
                        Jumper.fn = fn
                        break
                    end
                end
            end
        end
    end
    if Jumper.fn then
        return (pcall(Jumper.fn, { KeyCode = Enum.KeyCode.Space }, false))
    end
    if VirtualInputManager then
        pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
        task.delay(0.03, function()
            pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
        end)
        return true
    end
    return false
end

-- a missed parry throws you down at 200, unless it would kill you or do nothing
local function missAllowed(hum)
    if gui("NoPunish") == true then return false end
    if valueOf(PlayerGui:FindFirstChild("NoResetOnSpawn"), "DeathPunish") == true then return false end
    if gui("DamagePunish") == true and hum.Health <= 45 then return false end
    return true
end

local function botMove(hum, direction)
    Bot.move = direction
    hum:Move(direction, false)
end

local function steerTo(hum, root, x, z)
    local dx, dz = x - root.Position.X, z - root.Position.Z
    local d = math.sqrt(dx * dx + dz * dz)
    botMove(hum, d < 0.2 and Vector3.new(0, 0, 0) or Vector3.new(dx / d, 0, dz / d))
end

local PadMark = nil

local function markPad()
    local want = Bot.ShowPad and Bot.pad ~= nil and Bot.pad.Parent ~= nil
    if want and not PadMark then
        PadMark = Instance.new("Highlight")
        PadMark.Name = "ParryAssistWinPad"
        PadMark.FillColor = Color3.fromRGB(80, 255, 120)
        PadMark.OutlineColor = Color3.new(1, 1, 1)
        PadMark.FillTransparency = 0.4
        PadMark.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        PadMark.Parent = GuiRoot
    end
    if PadMark then
        PadMark.Enabled = want
        if want then PadMark.Adornee = Bot.pad end
    end
end

local function botWon()
    local wins = valueOf(LocalPlayer:FindFirstChild("leaderstats"), "Wins")
    if type(wins) == "number" and type(Bot.winsAt) == "number" and wins > Bot.winsAt then return true end
    return gui("HasWon") == true and not Bot.wonBefore
end

local function releaseBot()
    if Bot.holding then
        local module = controls()
        if module then pcall(function() module:Enable() end) end
        Bot.holding = false
    end
    local _, _, hum = character()
    if hum then pcall(function() hum:Move(Vector3.new(0, 0, 0), false) end) end
    Bot.move = nil
    if Bot.protecting then
        Bot.protecting = false
        setKillBricks(false)
    end
    Bot.mode, Bot.target, Bot.skipPerfect, Bot.skipOmni = 'off', nil, false, false
end

local function setBot(on)
    Bot.Enabled = on
    if not on then
        releaseBot()
        return
    end
    local now = os.clock()
    Bot.startedAt, Bot.took, Bot.misses = now, nil, 0
    Bot.bestY, Bot.bestAt, Bot.wanderUntil = -math.huge, now, 0
    Bot.avoid = {}
    Bot.winsAt = valueOf(LocalPlayer:FindFirstChild("leaderstats"), "Wins")
    Bot.wonBefore = gui("HasWon") == true
    scanTower()
    if Bot.Protect and not Anti.KillBricks then
        setKillBricks(true)
        Bot.protecting = true
    end
end

local function botStep(char, root, hum, now)
    if (now - Bot.scannedAt > 20 or not (Bot.tower and Bot.tower.Parent)) and now - Bot.lastLaunch > 1.5 then
        scanTower()
    end
    markPad()
    if botWon() then
        Bot.wins = Bot.wins + 1
        Bot.took = now - Bot.startedAt
        Bot.winsAt = valueOf(LocalPlayer:FindFirstChild("leaderstats"), "Wins")
        Bot.wonBefore = true
        if Bot.onWin then pcall(Bot.onWin, Bot.took) end
        if Bot.StopOnWin then
            if Bot.handle then pcall(function() Bot.handle:Set(false) end) end
            if Bot.Enabled then setBot(false) end
            return
        end
        Bot.startedAt = now
    end
    local pad = Bot.pad
    if not pad or not pad.Parent then
        Bot.mode = 'no win pad found'
        return
    end
    if not Bot.holding then
        local module = controls()
        if module then
            pcall(function() module:Disable() end)
            Bot.holding = true
        end
    end

    local g = Workspace.Gravity
    local v = root.AssemblyLinearVelocity
    -- a launch shows as a jump in climbing speed; the tower lets you through for a while after
    if v.Y - Bot.prevVy > 150 then
        local gain = v.Y - math.max(Bot.prevVy, 0)
        Bot.lastLaunch = now
        Bot.noclip = (gain > 650 and 1.35) or (gain > 330 and 0.75) or 0.45
    end
    Bot.prevVy = v.Y
    local noclipLeft = math.max(0, Bot.lastLaunch + Bot.noclip - now)
    local p = root.Position
    local px0, px1, py0, py1, pz0, pz1 = boxOf(pad)
    local cx, cz = (px0 + px1) / 2, (pz0 + pz1) / 2
    local speed = math.max(hum.WalkSpeed, 1)
    local grounded = hum.FloorMaterial ~= Enum.Material.Air

    -- a normal launch already gets there: no slow motion this close
    Bot.skipPerfect = py0 - p.Y < 150
    Bot.skipOmni = py0 - p.Y < 420
    if p.Y > Bot.bestY + 4 then Bot.bestY, Bot.bestAt = p.Y, now end

    if gui("DirectionalParry") == true then
        -- the climb is planned around the box over your head
        Bot.mode = 'directional parry is on: the bot needs it off'
        botMove(hum, Vector3.new(0, 0, 0))
        return
    end
    if now - Chat.at < 0.5 then
        -- the chatbox's eyes are up: keep still through its window
        Bot.mode = 'keeping still for the chatbox'
        botMove(hum, Vector3.new(0, 0, 0))
        return
    end

    local folder = Workspace:FindFirstChild("NoParry")
    local teleports = folder and folder:FindFirstChild("Teleports")
    local door = teleports and Bot.tower and teleports:FindFirstChild(Bot.tower.Name)
    if not insideTower(p) and door and door:IsA("BasePart") then
        Bot.mode = 'walking to the ' .. Bot.tower.Name .. ' teleport'
        steerTo(hum, root, door.Position.X, door.Position.Z)
        if grounded and now - Bot.bestAt > 2 and now - Bot.jumpedAt > 0.6 then
            hum.Jump = true
            Bot.jumpedAt = now
        end
        return
    end

    -- overshot: come down onto the pad
    if p.Y - 3 > py1 + 0.5 then
        Bot.mode = 'dropping onto the pad'
        local ax, az = inside(px0, px1, pz0, pz1, p.X, p.Z, 1)
        steerTo(hum, root, ax, az)
        -- a missed parry freezes you for 0.2 s and then throws you down at 200:
        -- only when that fall still lets you line up with the pad
        local drop = p.Y - 3 - py1
        local fall = 0.2 + drop / (200 + 0.5 * g * drop / 200)
        if Bot.Missed and not root.Anchored and missAllowed(hum) and canStart(char)
            and (v.Y > 5 or drop > 30) and flatDistance(p, ax, az) <= speed * (fall - 0.2) + 0.3
            and parryTargets(char, root) == 0 and press() then
            Bot.misses = Bot.misses + 1
        end
        return
    end

    -- no progress for a while: wander off and jump, and leave that platform alone
    if now < Bot.wanderUntil and Bot.wanderDir then
        Bot.mode = 'getting unstuck'
        botMove(hum, Bot.wanderDir)
        if grounded and now - Bot.jumpedAt > 0.5 then
            hum.Jump = true
            Bot.jumpedAt = now
        end
        return
    end
    if now - Bot.bestAt > 6 then
        if Bot.target then Bot.avoid[Bot.target.part] = now + 8 end
        local a = math.random() * math.pi * 2
        Bot.wanderDir = Vector3.new(math.cos(a), 0, math.sin(a))
        Bot.wanderUntil = now + 1.2
        Bot.bestY, Bot.bestAt = p.Y, now
        return
    end

    -- the pad within this rise (or a jump): straight for it
    local power = jumpPower(hum)
    local tPad = riseTime(p.Y, grounded and power or v.Y, py0 - 2.5, g)
    if tPad then
        local ax, az = inside(px0, px1, pz0, pz1, p.X, p.Z, 1)
        local d = flatDistance(p, ax, az)
        if grounded or d <= speed * tPad + 0.5 then
            Bot.mode, Bot.target = 'going for the pad', nil
            steerTo(hum, root, ax, az)
            if grounded and d < 0.6 and now - Bot.jumpedAt > 0.4 then
                hum.Jump = true
                Bot.jumpedAt = now
            end
            return
        end
    end

    if grounded then
        local jumpHeight = power * power / (2 * g)
        local reach = jumpHeight
        if Bot.DoubleJumps and (gui("TempJumps") or 0) > 0 then reach = reach * 2 end
        local pick, ax, az, d = chooseFromGround(char, p, reach, now)
        if pick then
            Bot.mode, Bot.target = 'getting under a platform', pick
            steerTo(hum, root, ax, az)
            if d < 0.5 and now - Bot.jumpedAt > 0.4 then
                hum.Jump = true
                Bot.jumpedAt = now
            end
            return
        end
        Bot.mode, Bot.target = 'heading for the pad', nil
        steerTo(hum, root, cx, cz)
        return
    end

    local pick, ax, az = choose(p, v.Y, speed, g, noclipLeft, now, cx, cz)
    if not pick and Bot.DoubleJumps and v.Y < 15 and not root.Anchored and (gui("TempJumps") or 0) > 0 then
        local again, ax2, az2 = choose(p, power, speed, g, noclipLeft, now, cx, cz)
        if again and doubleJump() then pick, ax, az = again, ax2, az2 end
    end
    if pick then
        Bot.mode, Bot.target = 'climbing', pick
        steerTo(hum, root, ax, az)
        return
    end
    local held = Bot.target
    if held and usable(held, now) and held.y0 > p.Y + PROBE_LOW then
        Bot.mode = 'going for the platform it jumped to'
        steerTo(hum, root, inside(held.x0, held.x1, held.z0, held.z1, p.X, p.Z, 0.6))
    elseif py0 - p.Y < 160 or noclipLeft > 0 then
        Bot.mode, Bot.target = 'lining up with the pad', nil
        steerTo(hum, root, cx, cz)
    else
        -- nothing to reach this time: come straight back down where you were
        Bot.mode, Bot.target = 'waiting to land', nil
        botMove(hum, Vector3.new(0, 0, 0))
    end
end

--// frame loop ----------------------------------------------------------------------------

local lastClean = 0

local function step()
    findPress()
    curses()
    if Fast.Slowmo or Fast.Cutscene then installFast() elseif Fast.env then removeFast() end
    local now = os.clock()
    if now - lastClean > 0.5 then
        lastClean = now
        clearMarks(false)
    end
    local char, root, hum = character()
    if not char then
        Auto.seenAt, Auto.inRange = nil, 0
        if Indicator.gui then Indicator.gui.Enabled = false end
        return
    end
    if Anti.Void then
        if voidPart() ~= Safe.void then setVoid(true) end
        voidGuard(char, root, hum, now)
    end
    if Bot.Enabled then guarded(botStep, char, root, hum, now) end
    local ready = canStart(char)
    local hits = nil
    -- the bot parries like auto parry, except while it drops onto the pad
    local autoOn = Auto.Enabled or (Bot.Enabled and Bot.mode ~= 'dropping onto the pad')

    -- bacon: any parry on cooldown within the second covers you; a real one if
    -- a part comes into range in time, a missed one if not
    while #Bacons > 0 and (gui("ParryCD") == true or now - Bacons[1] > 1.2) do table.remove(Bacons, 1) end
    if #Bacons > 0 and Entities.Bacon and ready then
        hits = parryTargets(char, root)
        if (hits > 0 or now - Bacons[1] >= 0.35) and press() then
            table.remove(Bacons, 1)
            Entities.parried = Entities.parried + 1
            return
        end
    end

    if autoOn or Show.Indicator then
        hits = hits or parryTargets(char, root)
    end
    Auto.inRange = hits or 0
    if Show.Indicator then showIndicator(ready and Auto.inRange > 0) elseif Indicator.gui then Indicator.gui.Enabled = false end

    if autoOn then
        if Auto.inRange == 0 then
            Auto.seenAt = nil
        elseif ready and not (Auto.AirOnly and not Bot.Enabled and hum.FloorMaterial ~= Enum.Material.Air) and not dangerWithin(now, 0.45) then
            Auto.seenAt = Auto.seenAt or now
            if now - Auto.seenAt >= (Bot.Enabled and 0 or Auto.Delay / 1000) and press() then
                Auto.seenAt = nil
                Auto.count = Auto.count + 1
                return
            end
        end
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

track(RunService.RenderStepped:Connect(function()
    guarded(omniCheck, "render")
    guarded(cameraWatch)
end))
track(RunService.Stepped:Connect(function() guarded(omniCheck, "step") end))
-- after the control module, so the bot's steering holds even when it cannot switch it off
pcall(function()
    RunService:BindToRenderStep("ParryAssistBot", Enum.RenderPriority.Input.Value + 1, function()
        if not Bot.Enabled or not Bot.move then return end
        local _, _, hum = character()
        if hum then hum:Move(Bot.move, false) end
    end)
end)
track(LocalPlayer.CharacterAdded:Connect(function() Jumper.fn = nil end))
track(RunService.Heartbeat:Connect(function(dt)
    if type(dt) == "number" and dt > 0 and dt < 0.5 then Frame.dt = Frame.dt * 0.9 + dt * 0.1 end
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
            if not child.Parent then return end
            if child.Name:sub(1, 7) == "_shadow" then
                guarded(shadowAdded, child)
            else
                markEntity(child)
            end
        end)
    end
end))

local function towerAdded(d)
    guardKillBrick(d)
    if d.Name == "Orb" and d:IsA("Model") then
        -- after builderman has put its parts in
        task.defer(function()
            markEntity(d)
            guarded(collectOrb, d)
        end)
    end
end

local function bindTower(tower)
    if tower.Name ~= "CurrentTower" then return end
    track(tower.DescendantAdded:Connect(towerAdded))
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
    removeFast()
    pcall(function() RunService:UnbindFromRenderStep("ParryAssistBot") end)
    if Bot.Enabled then
        Bot.Enabled = false
        releaseBot()
    end
    if PadMark then pcall(function() PadMark:Destroy() end) end
    Anti.Platforms, Anti.Legs, Anti.Wings, Anti.Jupiter = false, false, false, false
    pcall(curses)
    setKillBricks(false)
    setVoid(false)
    if Controls then pcall(function() Controls:Enable() end) end
    clearMarks(true)
    for _, thing in ipairs({ Probe, Ahead, PvpProbe, ShadowMark, Indicator.gui or false }) do
        if thing then pcall(function() thing:Destroy() end) end
    end
    if Genv.__ParryFlingStop == unload then Genv.__ParryFlingStop = nil end
    if Onyx and not Onyx.Unloaded then pcall(function() Onyx:Unload() end) end
end
Genv.__ParryFlingStop = unload
Genv.ParryFling = {
    Auto = Auto, Perfect = Perfect, Fast = Fast, Entities = Entities, Pvp = Pvp, Anti = Anti,
    Show = Show, Press = Press, Frame = Frame, Bot = Bot, Unload = unload,
}

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
    return section:Toggle({
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
    toggle(section, 'moving parts', 'a swinging or falling part only counts if it will still be in the hitbox when the parry lands', 'pf_predict', Auto, 'Predict')
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
    toggle(section, 'parry indicator', 'a dot on screen that turns green when a parry would land right now', 'pf_indicator', Show, 'Indicator')

    local perfect = Tab:CreateSection('perfect and omni')
    toggle(perfect, 'auto perfect parry', 'presses again the instant the perfect window opens (the game turns the parry screen blue), for the 400 launch. works on your own presses too', 'pf_perfect', Perfect, 'Enabled')
    toggle(perfect, 'auto omni parry', 'presses in the omni window at the end of a perfect parry, for the 800 launch. needs omni parry switched on in the game', 'pf_omni', Perfect, 'Omni')

    local speed = Tab:CreateSection('speed')
    toggle(speed, 'fast perfect parry', 'cuts the perfect parry\'s 2 s slow motion to 0.3 s, for your own presses too. auto omni still works: its window moves to the end of the shorter slow motion', 'pf_fast_slowmo', Fast, 'Slowmo')
    toggle(speed, 'skip omni cutscene', 'plays the omni cutscene in a blink and launches you straight away', 'pf_fast_cutscene', Fast, 'Cutscene')

    local status = Tab:CreateSection('status')
    status:Label({ Title = function()
        local speedText = 'off'
        if Fast.Slowmo or Fast.Cutscene then
            speedText = Fast.env and ('on, %d waits cut'):format(Fast.cut) or (Fast.failed and 'not supported here' or 'waiting for the parry button')
        end
        return ('press: %s%s  |  speed: %s'):format(pressHow(), Press.parry and ' (omni flag found)' or '', speedText)
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
    toggle(section, 'chatbox', 'parries the eyes, timed to your frame rate, and keeps you still through them', 'pf_chatbox', Entities, 'Chatbox')
    toggle(section, 'noob', 'parries when its dash reaches you', 'pf_noob', Entities, 'Noob')
    toggle(section, 'builderman', 'parries every attack that hits you', 'pf_builderman', Entities, 'builderman')
    toggle(section, 'bacon', 'gets your parry on cooldown in time: a real parry if a part comes into range, a missed one if not', 'pf_bacon', Entities, 'Bacon')

    local other = Tab:CreateSection('cowboy, shadow and builderman')
    toggle(other, 'cowboy dodge', 'steps aside when it fires, since the bullet only checks where you stood', 'pf_cowboy', Entities, 'Cowboy')
    toggle(other, 'parry your shadow', 'parries when your shadow gets within the pvp box, which launches you away from it', 'pf_shadow', Entities, 'Shadow')
    toggle(other, "shadow can't kill you", 'your shadow stops counting touches', 'pf_shadow_safe', Entities, 'ShadowSafe')
    toggle(other, 'shadow esp', nil, 'pf_shadow_esp', Entities, 'ShadowEsp', function(state)
        ShadowMark.Enabled = state and LastShadow ~= nil and LastShadow.Parent ~= nil
        if state and LastShadow then ShadowMark.Adornee = LastShadow end
    end)
    toggle(other, 'auto collect orbs', 'brings builderman\'s glitch orbs to you the moment they drop, so each one hurts him', 'pf_orbs', Entities, 'Orbs', function(state)
        if not state then return end
        local tower = Workspace:FindFirstChild("CurrentTower")
        if not tower then return end
        for _, d in ipairs(tower:GetDescendants()) do
            if d.Name == "Orb" and d:IsA("Model") then guarded(collectOrb, d) end
        end
    end)

    local look = Tab:CreateSection('see them')
    toggle(look, 'entity esp', 'highlights the noob, the cowboy and builderman\'s orbs through walls', 'pf_esp', Entities, 'Esp', function(state)
        if state then scanEntities() else clearMarks(true) end
    end)
    toggle(look, 'hide ads', 'the ad popups stop covering your screen (the ad still needs its parry)', 'pf_hide_ads', Entities, 'HideAds')

    local pvp = Tab:CreateSection('pvp')
    toggle(pvp, 'auto pvp parry', 'parries when another player is in the game\'s 9 stud pvp box and will still be there when it lands. the game only has pvp parries while the shadow entity is on, with parry players on or a round running', 'pf_pvp', Pvp, 'Enabled')

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
        return ('parried %d  |  dodged %d  |  orbs %d  |  could not parry %d'):format(Entities.parried, Entities.dodged, Entities.orbs, Entities.blocked)
    end })
    status:Label({ Title = function()
        if not Pvp.active then return 'pvp: off in this round' end
        return ('pvp: on  |  %d player%s in range  |  pvp parries %d'):format(Pvp.players, plural(Pvp.players), Pvp.count)
    end })
end

do
    local Tab = Window:CreateTab({ Title = 'extra' })

    local section = Tab:CreateSection('anti')
    toggle(section, 'anti void', 'the void stops counting you, and a fall toward it puts you back where you last stood', 'pf_anti_void', Anti, 'Void', setVoid)
    toggle(section, 'anti kill bricks', 'kill bricks stop registering your touch', 'pf_anti_kill', Anti, 'KillBricks', setKillBricks)
    toggle(section, 'anti platforms curse', 'platforms stop disappearing', 'pf_anti_platforms', Anti, 'Platforms')
    toggle(section, 'anti legs curse', 'double jumps stop failing', 'pf_anti_legs', Anti, 'Legs')
    toggle(section, 'anti wings curse', 'parries give their double jump back', 'pf_anti_wings', Anti, 'Wings')
    toggle(section, 'anti jupiter curse', 'normal gravity', 'pf_anti_jupiter', Anti, 'Jupiter')
    section:Label({ Title = function() return ('void saves %d'):format(Anti.saves) end })

    local scriptSection = Tab:CreateSection('script')
    scriptSection:Button({ Title = 'unload', Callback = unload })
end


do
    local Tab = Window:CreateTab({ Title = 'bot' })

    local section = Tab:CreateSection('auto beat tower')
    Bot.handle = toggle(section, 'auto beat tower', 'climbs to the win pad by itself with parries: chains launches off the platforms above you, steering in the air to the next one it can reach, then flies into the pad or drops onto it. it finds the tower and its win pad by itself', 'pf_bot', Bot, 'Enabled', setBot)
    toggle(section, 'use perfect parries', 'perfect parries launch 400 instead of 250 (skipped close to the top). turn on fast perfect parry in the parry tab, or each one holds you for 2 s', 'pf_bot_perfect', Bot, 'Perfect')
    toggle(section, 'use omni parries', '800 launches when omni parry is on in the game (skipped close to the top)', 'pf_bot_omni', Bot, 'Omni')
    toggle(section, 'missed parries to drop down', 'overshot the pad: a deliberate missed parry throws you down at 200. never used with death punish on', 'pf_bot_missed', Bot, 'Missed')
    toggle(section, 'double jumps', 'uses your double jumps to reach a platform that is just too high', 'pf_bot_double', Bot, 'DoubleJumps')
    toggle(section, 'protect from kill bricks', 'turns on anti kill bricks while it runs, since a launch passes through them', 'pf_bot_protect', Bot, 'Protect')
    toggle(section, 'stop after a win', nil, 'pf_bot_stop', Bot, 'StopOnWin')
    toggle(section, 'show the win pad', 'highlights the win pad through walls', 'pf_bot_pad', Bot, 'ShowPad', function()
        if not Bot.pad then scanTower() end
        markPad()
    end)

    local status = Tab:CreateSection('status')
    status:Label({ Title = function()
        if not Bot.tower then return 'tower: not found yet' end
        local pad = Bot.pad
        return ('tower: %s  |  win pad: %s'):format(Bot.tower.Name, pad and ('%d studs up'):format(math.floor(pad.Position.Y + 0.5)) or 'not found')
    end })
    status:Label({ Title = function()
        local _, root = character()
        local height = root and ('%d'):format(math.floor(root.Position.Y + 0.5)) or '-'
        return ('bot: %s  |  height %s'):format(Bot.Enabled and Bot.mode or 'off', height)
    end })
    status:Label({ Title = function()
        local run = Bot.Enabled and ('%.1f s'):format(os.clock() - Bot.startedAt) or '-'
        local last = Bot.took and ('%.1f s'):format(Bot.took) or '-'
        return ('this run %s  |  last win %s  |  wins %d  |  drop misses %d'):format(run, last, Bot.wins, Bot.misses)
    end })
end

Bot.onWin = function(took)
    Onyx:Notify({ Title = 'parry fling', Content = ('Tower beaten in %.1f s.'):format(took), Type = 'success', Duration = 6 })
end

Onyx:Notify({ Title = 'parry fling', Content = 'Loaded. Turn on auto parry to start.', Type = 'success', Duration = 5 })

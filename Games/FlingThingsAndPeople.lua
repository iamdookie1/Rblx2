--// Fling Things and People --------------------------------------------------
-- Built against a fresh script dump of the live game (place 6961824067). The
-- grab/throw system is entirely client authoritative: the server hands the
-- grabbing client network ownership of whatever it grabbed, and the client's
-- own LocalScript sets the grabbed part's Velocity directly with no server
-- validation of the magnitude. That's confirmed from the dump's own throw()
-- function - a plain property write, not a remote call.
--
-- Remotes confirmed from the dump (ReplicatedStorage.GrabEvents /
-- CharacterEvents):
--   GrabEvents.CreateGrabLine  :FireServer(grabbedPart, hitOffsetCFrame)
--   GrabEvents.DestroyGrabLine :FireServer(grabbedPart)
--   CharacterEvents.Struggle   :FireServer()  -- escape a grab, normally spammed
--                                                 by pressing Escape
--   LocalPlayer.IsHeld    (BoolValue)   -- true while someone else is holding you
--   LocalPlayer.HeldTimer (NumberValue) -- must be > 0 for Struggle to matter
--
-- Default controls, from the game's own CASButtonModule bind table:
--   Grab / Drop : MouseButton1 (left click grabs when empty handed, the same
--                 click ends the grab without throwing when already holding -
--                 the game itself calls that second case "GrabDrop")
--   Throw       : MouseButton2 (right click, only does anything while holding)
--
-- The grabbed instance is tracked here by reading the first argument of
-- CreateGrabLine's own FireServer call, not by guessing at the private
-- LocalScript's local variables - the same network-boundary approach used for
-- every other game in this repo. This hook only reads, it never rewrites
-- those two calls, so it does not need to be namecall-safe the way a redirect
-- hook does; it always forwards to the real remote unchanged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

local function waitForPath(root, path, timeout)
    local current = root
    for _, name in ipairs(path) do
        if not current then return nil end
        local ok, child = pcall(function() return current:WaitForChild(name, timeout or 10) end)
        if not ok then return nil end
        current = child
    end
    return current
end

local GrabEvents = waitForPath(ReplicatedStorage, { "GrabEvents" })
local CreateGrabLine = GrabEvents and GrabEvents:FindFirstChild("CreateGrabLine")
local DestroyGrabLine = GrabEvents and GrabEvents:FindFirstChild("DestroyGrabLine")

local CharacterEvents = waitForPath(ReplicatedStorage, { "CharacterEvents" })
local StruggleRemote = CharacterEvents and CharacterEvents:FindFirstChild("Struggle")

--// throw / drop multiplier -----------------------------------------------------

local Tune = {
    ThrowEnabled = false,
    ThrowMultiplier = 1.6,
    DropEnabled = false,
    DropMultiplier = 1.3,
}

-- A first version of this set an absolute velocity the instant
-- DestroyGrabLine fired. That is exactly where the game's own throw()
-- calls DestroyGrabLine too - as its first step, before it goes on to set
-- Velocity itself a few lines later in the same, non-yielding call. Our
-- write landed first and the game's own write landed right after it,
-- silently overwriting it every time - which is why throw did nothing.
--
-- This scales whatever velocity actually ends up on the part instead of
-- racing to set one first: for a throw that is the game's own computed
-- value, still pointed the same direction it chose, just faster or slower
-- by the multiplier. A plain drop never has its own velocity write at all
-- (throw() is the only place that sets it), so there nothing arrives to
-- react to and this scales whatever velocity the part already carries from
-- being dragged around on the beam - which is also "how fast they sent the
-- thing", just without a throw behind it.
--
-- The vertical part of that velocity is handled on its own rather than
-- scaled along with everything else. A held object sags a little under
-- gravity even sitting still, and scaling the raw vector straight through
-- would blow that small constant sag up into a real downward launch on
-- every release, aimed down or not. Below DOWN_THRESHOLD it is left alone
-- entirely - only a release that was already meaningfully aimed downward
-- gets its vertical speed scaled too, same as the direction it actually
-- went.
local DOWN_THRESHOLD = 3

local function scaleReleaseVelocity(rootPart, multiplier)
    if not rootPart or not rootPart.Parent or multiplier == 1 then return end

    local targets = { rootPart }
    local parent = rootPart.Parent
    if parent and parent:IsA("Model") and parent.Name ~= "Workspace" then
        targets = {}
        for _, sibling in ipairs(parent:GetChildren()) do
            if sibling:IsA("BasePart") then
                targets[#targets + 1] = sibling
            end
        end
    end

    local sawChange = false
    local ok, conn = pcall(function()
        return rootPart:GetPropertyChangedSignal("Velocity"):Connect(function()
            sawChange = true
        end)
    end)

    -- The native throw() calls DestroyGrabLine as its first step and only
    -- sets Velocity a few lines later in that same, non-yielding call, so
    -- the write is not there yet the instant we get here - but every line
    -- between those two points runs before the next frame, with nothing in
    -- between to yield on. One frame is enough to be sure the game's own
    -- write has landed, and it is also as little as this can possibly wait:
    -- gravity is already curving the object's real velocity every frame it
    -- flies, so any longer than that and what gets scaled is no longer the
    -- angle it actually left on - which read as a scripted, off-angle
    -- correction rather than a stronger throw, and it was one.
    if not sawChange then
        task.wait()
    end
    if ok and conn then conn:Disconnect() end

    -- The game computes one velocity vector and applies that same vector to
    -- every part of a thrown model - it never reads each part's own speed
    -- back. Reading rootPart's velocity once and reusing that one vector for
    -- every sibling matches that. Reading and scaling each part's own
    -- velocity independently was the actual bug behind heavy things flying
    -- while simple ones did not: a multi-part model has joints, and a joint
    -- can already be pulling a limb's own velocity away from the vector the
    -- game set the instant it lands, well before this even runs. Scaling
    -- each of those independently drifted values separately amplifies
    -- whatever a limb had already picked up on its own - which a single
    -- rigid part, with nothing to diverge from itself, never could.
    local ok2, baseVelocity = pcall(function() return rootPart.Velocity end)
    if not ok2 then return end

    local verticalSpeed = baseVelocity.Y
    if verticalSpeed < -DOWN_THRESHOLD then
        verticalSpeed = verticalSpeed * multiplier
    end
    local scaled = Vector3.new(baseVelocity.X * multiplier, verticalSpeed, baseVelocity.Z * multiplier)

    for _, part in ipairs(targets) do
        if part.Parent and not part.Anchored then
            pcall(function() part.Velocity = scaled end)
        end
    end
end

-- Runs outside the namecall hook (see below), so it is free to make its own
-- method calls - :IsMouseButtonPressed, :GetPropertyChangedSignal, the :IsA
-- calls inside scaleReleaseVelocity - without any risk to the hook's own
-- pending dispatch.
local function handleRelease(released)
    if not released then return end

    local throwing = false
    pcall(function()
        throwing = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end)

    if throwing then
        if Tune.ThrowEnabled then scaleReleaseVelocity(released, Tune.ThrowMultiplier) end
    else
        if Tune.DropEnabled then scaleReleaseVelocity(released, Tune.DropMultiplier) end
    end
end

--// grab tracking --------------------------------------------------------------

-- The currently grabbed part, tracked by reading CreateGrabLine/
-- DestroyGrabLine's own FireServer arguments rather than the private
-- LocalScript's locals. Whichever mouse button is held right as
-- DestroyGrabLine fires is what actually tells throw and drop apart: the
-- game's own throw() calls DestroyGrabLine as its very first step, while
-- MouseButton2 is still down from the click that triggered it, and a plain
-- drop (re-pressing Grab, or dying) never has it down at that instant.
local currentGrab = nil

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall

    local function onNamecall(self, ...)
        if not Unloading and typeof(self) == "Instance" and getnamecallmethod() == "FireServer" then
            if self == CreateGrabLine then
                local grabbed = ...
                if typeof(grabbed) == "Instance" then
                    currentGrab = grabbed
                end
            elseif self == DestroyGrabLine then
                local releasing = currentGrab
                currentGrab = nil
                if releasing then
                    task.spawn(handleRelease, releasing)
                end
            end
        end
        return originalNamecall(self, ...)
    end

    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end

    originalNamecall = hookmetamethod(game, "__namecall", onNamecall)
end

--// anti grab / auto struggle --------------------------------------------------

local AntiGrab = {
    Enabled = false,
    Rate = 0.05,
}

local isHeldValue = LocalPlayer:FindFirstChild("IsHeld")
if not isHeldValue then
    task.spawn(function()
        local ok, value = pcall(function() return LocalPlayer:WaitForChild("IsHeld", 15) end)
        if ok then isHeldValue = value end
    end)
end

task.spawn(function()
    while not Unloading do
        if AntiGrab.Enabled and isHeldValue and isHeldValue.Value == true and StruggleRemote then
            pcall(function() StruggleRemote:FireServer() end)
            task.wait(AntiGrab.Rate)
        else
            task.wait(0.1)
        end
    end
end)

--// ui ---------------------------------------------------------------------

local function resolveLatestRef()
    local ref = 'main'
    pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Rblx2/commits/main'))
        if commit and commit.sha then
            ref = commit.sha
        end
    end)
    return ref
end

local Onyx = loadstring(game:HttpGet(('https://raw.githubusercontent.com/iamdookie1/Rblx2/%s/UI/Ui2.lua'):format(resolveLatestRef())))()

local function addStat(section, cfg)
    local title = cfg.Title
    local label = section:Label({ Title = title .. ': ' .. tostring(cfg.Value), Color = cfg.Color })
    local api = {}
    function api.Set(value, color)
        label:SetText(title .. ': ' .. tostring(value))
        if color then label:SetColor(color) end
    end
    return api
end

local Window = Onyx:CreateWindow({
    Title = 'fling',
    SubTitle = 'assist',
    Folder = 'FlingAssist',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 170, 60),
})

local MainTab = Window:CreateTab({ Title = 'main', Default = true })

local ThrowSection = MainTab:CreateSection('throw')

ThrowSection:Toggle({
    Title = 'throw multiplier',
    Description = 'right click already throws whatever you are holding at whatever speed the game itself picks, in whatever direction it computed. this scales that speed by the number below instead of replacing it, so the throw is still the game\'s own - just harder. only touches an actual throw, never a plain drop',
    Flag = 'fling_throw_enabled',
    Default = false,
    Callback = function(state) Tune.ThrowEnabled = state end,
})

ThrowSection:Input({
    Title = 'throw multiplier (x)',
    Placeholder = tostring(Tune.ThrowMultiplier),
    Default = tostring(Tune.ThrowMultiplier),
    Numeric = true,
    Flag = 'fling_throw_multiplier',
    Callback = function(value)
        local number = tonumber(value)
        if number then Tune.ThrowMultiplier = math.max(0, number) end
    end,
})

local DropSection = MainTab:CreateSection('drop')

DropSection:Toggle({
    Title = 'drop multiplier',
    Description = 'left click grabs when your hands are empty, and drops without throwing when you already have something - the game sets no new velocity at all on that second click, so whatever the object was carrying from being dragged around is what it keeps. this scales that leftover speed instead, so it only ever affects a plain drop, never a throw',
    Flag = 'fling_drop_enabled',
    Default = false,
    Callback = function(state) Tune.DropEnabled = state end,
})

DropSection:Input({
    Title = 'drop multiplier (x)',
    Placeholder = tostring(Tune.DropMultiplier),
    Default = tostring(Tune.DropMultiplier),
    Numeric = true,
    Flag = 'fling_drop_multiplier',
    Callback = function(value)
        local number = tonumber(value)
        if number then Tune.DropMultiplier = math.max(0, number) end
    end,
})

local GrabStatSection = MainTab:CreateSection('status')

local holdingStat = addStat(GrabStatSection, { Title = 'holding', Value = 'nothing' })
local heldStat = addStat(GrabStatSection, { Title = 'held by someone', Value = 'no' })

local AntiGrabSection = MainTab:CreateSection('anti grab')

AntiGrabSection:Toggle({
    Title = 'anti grab',
    Description = 'the game already lets you escape a grab by mashing escape, which fires the same Struggle remote every press. this just presses it for you, as fast as the rate below, the instant you are held - so a grab barely has time to register before you are already out of it',
    Flag = 'fling_anti_grab',
    Default = false,
    Callback = function(state) AntiGrab.Enabled = state end,
})

AntiGrabSection:Input({
    Title = 'struggle rate (seconds)',
    Placeholder = tostring(AntiGrab.Rate),
    Default = tostring(AntiGrab.Rate),
    Numeric = true,
    Flag = 'fling_struggle_rate',
    Callback = function(value)
        local number = tonumber(value)
        if number then AntiGrab.Rate = math.clamp(number, 0.02, 1) end
    end,
})

AntiGrabSection:Label('The further reach gamepass (20 to 30 stud grab range) is a real purchase in this game, checked with the server - this script does not touch it.')

local SessionSection = MainTab:CreateSection('session')

SessionSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        Onyx:Unload()
    end,
})

task.spawn(function()
    while not Unloading do
        task.wait(0.25)
        pcall(function()
            holdingStat.Set(currentGrab and currentGrab.Name or 'nothing')
            local held = isHeldValue ~= nil and isHeldValue.Value == true
            heldStat.Set(held and 'YES' or 'no', held and Color3.fromRGB(255, 96, 106) or nil)
        end)
    end
end)

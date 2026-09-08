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

--// throw / drop power ---------------------------------------------------------

local Tune = {
    ThrowEnabled = false,
    ThrowPower = 120,
    DropEnabled = false,
    DropPower = 25,
}

-- Mirrors the dump's own throw() logic for what actually gets the velocity:
-- a single part, or every BasePart of the model it belongs to when that
-- model is the grabbed thing's real parent (a ragdolled player, for
-- instance) rather than loose in Workspace.
local function applyVelocity(part, speed)
    if not part or not part.Parent then return end

    local direction = Camera.CFrame.LookVector
    local velocity = direction * speed

    local parent = part.Parent
    if parent and parent:IsA("Model") and parent.Name ~= "Workspace" then
        for _, sibling in ipairs(parent:GetChildren()) do
            if sibling:IsA("BasePart") and not sibling.Anchored then
                pcall(function() sibling.Velocity = velocity end)
            end
        end
        return
    end

    if not part.Anchored then
        pcall(function() part.Velocity = velocity end)
    end
end

-- Runs outside the namecall hook (see below), so it is free to make its own
-- method calls - :IsMouseButtonPressed and the :IsA calls inside
-- applyVelocity - without any risk to the hook's own pending dispatch.
local function handleRelease(released)
    if not released then return end

    local throwing = false
    pcall(function()
        throwing = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end)

    if throwing then
        if Tune.ThrowEnabled then applyVelocity(released, Tune.ThrowPower) end
    else
        if Tune.DropEnabled then applyVelocity(released, Tune.DropPower) end
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

local Onyx = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Ui2.lua'))()

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
    Title = 'custom throw power',
    Desc = 'right click already throws whatever you are holding at whatever speed the game itself picks. this overrides that speed with the input below the moment you right click, and only while you are actually holding something - it never touches a plain drop',
    Flag = 'fling_throw_enabled',
    Default = false,
    Callback = function(state) Tune.ThrowEnabled = state end,
})

ThrowSection:Input({
    Title = 'throw power (studs/s)',
    Placeholder = tostring(Tune.ThrowPower),
    Default = tostring(Tune.ThrowPower),
    Numeric = true,
    Flag = 'fling_throw_power',
    Callback = function(value)
        local number = tonumber(value)
        if number then Tune.ThrowPower = math.max(0, number) end
    end,
})

local DropSection = MainTab:CreateSection('drop')

DropSection:Toggle({
    Title = 'custom drop power',
    Desc = 'left click grabs when your hands are empty, and drops without throwing when you already have something - the game applies no velocity at all on that second click. this gives that plain drop its own speed, entirely separate from throw',
    Flag = 'fling_drop_enabled',
    Default = false,
    Callback = function(state) Tune.DropEnabled = state end,
})

DropSection:Input({
    Title = 'drop power (studs/s)',
    Placeholder = tostring(Tune.DropPower),
    Default = tostring(Tune.DropPower),
    Numeric = true,
    Flag = 'fling_drop_power',
    Callback = function(value)
        local number = tonumber(value)
        if number then Tune.DropPower = math.max(0, number) end
    end,
})

local GrabStatSection = MainTab:CreateSection('status')

local holdingStat = addStat(GrabStatSection, { Title = 'holding', Value = 'nothing' })
local heldStat = addStat(GrabStatSection, { Title = 'held by someone', Value = 'no' })

local AntiGrabSection = MainTab:CreateSection('anti grab')

AntiGrabSection:Toggle({
    Title = 'anti grab',
    Desc = 'the game already lets you escape a grab by mashing escape, which fires the same Struggle remote every press. this just presses it for you, as fast as the rate below, the instant you are held - so a grab barely has time to register before you are already out of it',
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

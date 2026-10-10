-- Blade Ball -- clean rewrite (work in progress)
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).
--
-- DESIGN CONTRACT -- "inert until enabled":
--   At load this script builds the UI and NOTHING else. It does not connect to
--   any game RemoteEvent, connect any RunService signal, install any hook, read
--   any service in a loop, or require any game module. Every feature acquires
--   its connections/hooks only when it is turned ON (Feature:start) and releases
--   them fully when turned OFF (Feature:stop). With every feature off the script
--   holds zero game footprint -- the same state as the UI library's own example,
--   which the anti-cheat does not kick. This is the whole point of the rewrite:
--   the idle "nothing on" kick came from things the old script ran at load, so
--   the rewrite runs nothing at load.
--
-- This file is built up in installments; each one is independently testable so a
-- kick, if it ever reappears, points at exactly one feature. Installment 1:
-- foundation + the feature framework + Auto Jump.

task.spawn(function()

local SCRIPT_VERSION = "rewrite-0.1"

-- ---------------------------------------------------------------------------
-- Single instance: running the script again shuts the previous copy down first,
-- so two copies never both act. Every feature also checks is_live(), so a copy
-- that has been replaced can't do anything even if a connection lingers a frame.
-- ---------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
genv.__BladeBallInstance = INSTANCE
local function is_live() return genv.__BladeBallInstance == INSTANCE end

-- ---------------------------------------------------------------------------
-- Services. cloneref keeps the script's references from being traced back to it.
-- Reading a service reference touches nothing in the game by itself.
-- ---------------------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService('Players'))
local RunService = cloneref(game:GetService('RunService'))
local UserInputService = cloneref(game:GetService('UserInputService'))
local Workspace = cloneref(game:GetService('Workspace'))
local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- Feature framework. A Feature is a named on/off unit that owns every connection
-- and hook it needs. start() acquires them; stop() releases ALL of them. The
-- framework guarantees stop() leaves nothing behind, so "all features off" is
-- byte-for-byte the same footprint as a UI-only script.
-- ---------------------------------------------------------------------------
local Features = {} -- registry, for unload
local function Feature(name)
    local f = { name = name, on = false, _conns = {} }
    -- Connect a signal and remember it so stop() can drop it.
    function f:connect(signal, fn)
        local c = signal:Connect(function(...)
            if not is_live() then return end
            fn(...)
        end)
        self._conns[#self._conns + 1] = c
        return c
    end
    -- Release every connection/hook this feature holds. Safe to call twice.
    function f:release()
        for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
        self._conns = {}
    end
    -- start/stop default to no-ops; features override start()/stop().
    function f:setEnabled(v)
        v = v and true or false
        if v == self.on then return end
        self.on = v
        if v then
            if self.start then self.start() end
        else
            if self.stop then self.stop() end
            self:release()
        end
    end
    Features[name] = f
    return f
end

-- ---------------------------------------------------------------------------
-- UI. Building the menu is the only thing that happens at load.
-- ---------------------------------------------------------------------------
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options, Toggles = Library.Options, Library.Toggles

local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "version: " .. SCRIPT_VERSION,
    Icon = "swords",
    Center = true,
    AutoShow = true,
    Resizable = true,
    ToggleKeybind = Enum.KeyCode.LeftControl,
})

local Tabs = {
    Status = Window:AddTab("Status", "gauge", "Build info and live state"),
    Player = Window:AddTab("Player", "user", "Movement and avatar"),
}

-- Status tab: a plain, game-untouching readout so you can see the build loaded.
local StatusBox = Tabs.Status:AddLeftGroupbox("Build", "info")
StatusBox:AddLabel("Version: " .. SCRIPT_VERSION)
StatusBox:AddLabel("Idle = nothing connected. Features connect only when on.")

-- ---------------------------------------------------------------------------
-- FEATURE: Auto Jump. Jumps the instant you land, so holding jump keeps bouncing.
-- The Heartbeat exists only while the toggle is on; off = no per-frame anything.
-- ---------------------------------------------------------------------------
local AutoJump = Feature("AutoJump")
do
    local lastGrounded = false
    function AutoJump.start()
        lastGrounded = false
        AutoJump:connect(RunService.Heartbeat, function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum then return end
            local grounded = hum.FloorMaterial ~= Enum.Material.Air
            if grounded and not lastGrounded then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            lastGrounded = grounded
        end)
    end
    -- stop() needs no extra work: release() (called by the framework) drops the
    -- Heartbeat, which is the only thing this feature holds.
end

local MV = Tabs.Player:AddLeftGroupbox("Movement", "footprints")
MV:AddToggle("AutoJump", {
    Text = "Auto jump",
    Default = false,
    Callback = function(v) AutoJump:setEnabled(v) end,
}):AddKeyPicker("AutoJumpKey", {
    Default = "J",
    Mode = "Toggle",
    SyncToggleState = true,
    Text = "Auto jump",
})

-- ---------------------------------------------------------------------------
-- Unload. Turn every feature off (releasing its connections), then drop the
-- instance so is_live() is false for anything that somehow lingers.
-- ---------------------------------------------------------------------------
Library:OnUnload(function()
    for _, f in pairs(Features) do pcall(function() f:setEnabled(false) end) end
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end)

-- The next copy calls this before it starts, so the old copy tears itself down.
genv.__BladeBallShutdown = function()
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

Library:Notify({ Title = "Blade Ball", Description = "Rewrite " .. SCRIPT_VERSION .. " loaded. Idle = inert.", Time = 4 })

end)

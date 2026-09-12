local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

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
local Onyx = loadstring(game:HttpGet(url))()

local Unloading = false

local function waitPath(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        node = node:WaitForChild(name)
    end
    return node
end

local MovementScript = waitPath(ReplicatedStorage, "Objects", "Game", "Character", "Client", "Movement")
local MovementClass = require(MovementScript)
local FunctionsScript = waitPath(MovementScript, "MoveFunction", "Functions")
local Functions = require(FunctionsScript)
local CharacterServiceScript = waitPath(ReplicatedStorage, "Services", "Asset", "CharacterService")
local CharacterService = require(CharacterServiceScript)
local GamemodesFolder = waitPath(ReplicatedStorage, "Info", "Gamemodes")

local DEFAULT_SPEED = 1500 / 90
local DEFAULT_SPRINT_CAP = 2
local DEFAULT_JUMP_HEIGHT = 3
local DEFAULT_JUMP_SPEED_MULT = 1.45
local DEFAULT_JUMP_CAP = 1
local DEFAULT_GROUNDED_DIST = 2.9
local DEFAULT_AIR_ACCEL = 1
local DEFAULT_AIR_STRAFE_ACCEL = 182
local DEFAULT_SLIDE_MAX_SPEED = 5000 / 90

local Tune = {
    BaseSpeed = DEFAULT_SPEED,
    SprintCap = DEFAULT_SPRINT_CAP,
    JumpHeight = DEFAULT_JUMP_HEIGHT,
    JumpSpeedMultiplier = DEFAULT_JUMP_SPEED_MULT,
    JumpCap = DEFAULT_JUMP_CAP,
    BhopEnabled = false,
    GroundedDistCheck = DEFAULT_GROUNDED_DIST,
    AirAcceleration = DEFAULT_AIR_ACCEL,
    AirStrafeAcceleration = DEFAULT_AIR_STRAFE_ACCEL,

    TrimpBoostEnabled = false,
    TrimpBoostMultiplier = 1,

    SlideOverrideEnabled = false,
    SlideMultiplier = 1,
    SlideMaxSpeed = DEFAULT_SLIDE_MAX_SPEED,

    ReviveOverrideEnabled = false,
    ReviveTime = 0,
}

local function applyMovementTune(stats)
    stats.BaseSpeed = Tune.BaseSpeed * 90
    stats.Speed = Tune.BaseSpeed * 90
    stats.BaseSprintCap = Tune.SprintCap
    stats.SprintCap = Tune.SprintCap
    stats.JumpHeight = Tune.JumpHeight
    stats.JumpSpeedMultiplier = Tune.JumpSpeedMultiplier
    stats.JumpCap = Tune.JumpCap
    stats.BhopEnabled = Tune.BhopEnabled
    stats.GroundedDistCheck = Tune.GroundedDistCheck
    stats.AirAcceleration = Tune.AirAcceleration
    stats.AirStrafeAcceleration = Tune.AirStrafeAcceleration
end

local function getLocalMoveStats()
    local character = CharacterService:GetLocalCharacter()
    local movement = character and character.Movement
    local statsComponent = movement and movement.MoveStats
    return statsComponent and statsComponent.MoveStats
end

task.spawn(function()
    while not Unloading do
        local stats = getLocalMoveStats()
        if stats then
            applyMovementTune(stats)
        end
        task.wait(0.5)
    end
end)

local function deepPatchReviveTime(tbl, value, seen)
    for key, value2 in pairs(tbl) do
        if key == "ReviveTime" then
            tbl[key] = value
        elseif type(value2) == "table" and not seen[value2] then
            seen[value2] = true
            deepPatchReviveTime(value2, value, seen)
        end
    end
end

local function applyReviveOverride()
    if not Tune.ReviveOverrideEnabled then return end
    for _, gamemodeModule in ipairs(GamemodesFolder:GetChildren()) do
        if gamemodeModule:IsA("ModuleScript") then
            local ok, data = pcall(require, gamemodeModule)
            if ok and type(data) == "table" then
                deepPatchReviveTime(data, Tune.ReviveTime, { [data] = true })
            end
        end
    end
end

-- restored on unload; scoped to only our own character's slide so other
-- players/nextbots simulated client-side keep their native slide feel
local originalSlide = Functions.Slide
Functions.Slide = function(dt, moveConfig, dataRegistry, character, moveStats)
    local mover, terms = originalSlide(dt, moveConfig, dataRegistry, character, moveStats)
    if Tune.SlideOverrideEnabled and character == LocalPlayer.Character
        and mover and mover.BaseMover and mover.BaseMover.PlaneVelocity then
        local plane = mover.BaseMover.PlaneVelocity
        local scaled = Vector3.new(plane.X, 0, plane.Y) * Tune.SlideMultiplier
        local cap = Tune.SlideMaxSpeed * 90
        if scaled.Magnitude > cap then
            scaled = scaled.Unit * cap
        end
        mover.BaseMover.PlaneVelocity = Vector2.new(scaled.X, scaled.Z)
        if terms then
            local oldVelocity = terms.Velocity or Vector3.new()
            terms.Velocity = Vector3.new(scaled.X, oldVelocity.Y, scaled.Z)
        end
    end
    return mover, terms
end

-- same restore-on-unload contract as Slide; scoped by comparing the live
-- character model rather than a captured reference so it survives respawns
local originalJump = MovementClass.Jump
MovementClass.Jump = function(self, ...)
    local boost = Tune.TrimpBoostEnabled and self.Character == LocalPlayer.Character
    local a, b = originalJump(self, ...)
    if boost then
        local velocity = self.DataRegistry:Get("Velocity")
        if velocity then
            local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
            if horizontal.Magnitude > 1 then
                local boosted = horizontal * Tune.TrimpBoostMultiplier
                self.DataRegistry:Set("Velocity", Vector3.new(boosted.X, velocity.Y, boosted.Z))
            end
        end
    end
    return a, b
end

local Window = Onyx:CreateWindow({
    Title = 'evade',
    SubTitle = 'movement test',
    Folder = 'EvadeTest',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(210, 45, 45),
})

local MovementTab = Window:CreateTab({ Title = 'movement' })

local LiveSection = MovementTab:CreateSection('live')
LiveSection:Stats({
    Columns = 2,
    Items = {
        { Label = 'Speed', Value = function()
            local character = CharacterService:GetLocalCharacter()
            local speed = character and character.DataRegistry and character.DataRegistry:Get("Speed")
            return speed and (('%.1f studs/s'):format(speed)) or '-'
        end },
        { Label = 'Sprint', Value = function()
            local character = CharacterService:GetLocalCharacter()
            local sprint = character and character.DataRegistry and character.DataRegistry:Get("Sprint")
            return sprint and (('%.2fx'):format(sprint)) or '-'
        end },
    },
})

local PresetSection = MovementTab:CreateSection('preset')
local BaseSpeedSlider, SprintCapSlider, JumpHeightSlider, JumpMultSlider

PresetSection:Segmented({
    Title = 'quick preset',
    Values = { 'Default', 'Speedy', 'Extreme' },
    Default = 'Default',
    Callback = function(value)
        local presets = {
            Default = { Speed = DEFAULT_SPEED, Sprint = DEFAULT_SPRINT_CAP, Jump = DEFAULT_JUMP_HEIGHT, JumpMult = DEFAULT_JUMP_SPEED_MULT },
            Speedy = { Speed = DEFAULT_SPEED * 1.5, Sprint = DEFAULT_SPRINT_CAP * 1.5, Jump = DEFAULT_JUMP_HEIGHT * 1.3, JumpMult = DEFAULT_JUMP_SPEED_MULT * 1.3 },
            Extreme = { Speed = DEFAULT_SPEED * 2.5, Sprint = DEFAULT_SPRINT_CAP * 2.5, Jump = DEFAULT_JUMP_HEIGHT * 2, JumpMult = DEFAULT_JUMP_SPEED_MULT * 2 },
        }
        local preset = presets[value]
        if not preset then return end
        Tune.BaseSpeed = preset.Speed
        Tune.SprintCap = preset.Sprint
        Tune.JumpHeight = preset.Jump
        Tune.JumpSpeedMultiplier = preset.JumpMult
        if BaseSpeedSlider then BaseSpeedSlider:Set(preset.Speed) end
        if SprintCapSlider then SprintCapSlider:Set(preset.Sprint) end
        if JumpHeightSlider then JumpHeightSlider:Set(preset.Jump) end
        if JumpMultSlider then JumpMultSlider:Set(preset.JumpMult) end
    end,
})

local SpeedSection = MovementTab:CreateSection('speed & sprint')

BaseSpeedSlider = SpeedSection:Slider({
    Title = 'base speed',
    Min = 5,
    Max = 100,
    Increment = 1,
    Default = DEFAULT_SPEED,
    Suffix = ' studs/s',
    Flag = 'evade_base_speed',
    Callback = function(value) Tune.BaseSpeed = value end,
})

SprintCapSlider = SpeedSection:Slider({
    Title = 'sprint cap',
    Min = 1,
    Max = 8,
    Increment = 0.1,
    Default = DEFAULT_SPRINT_CAP,
    Suffix = 'x',
    Flag = 'evade_sprint_cap',
    Callback = function(value) Tune.SprintCap = value end,
})

local JumpSection = MovementTab:CreateSection('jump & trimp')

JumpHeightSlider = JumpSection:Slider({
    Title = 'jump height',
    Min = 1,
    Max = 20,
    Increment = 0.5,
    Default = DEFAULT_JUMP_HEIGHT,
    Suffix = ' studs',
    Flag = 'evade_jump_height',
    Callback = function(value) Tune.JumpHeight = value end,
})

JumpMultSlider = JumpSection:Slider({
    Title = 'jump speed multiplier',
    Description = 'the native trimp boost - how much of your run/slide speed converts into a jump forward when you jump while looking where you are moving',
    Min = 0.5,
    Max = 6,
    Increment = 0.05,
    Default = DEFAULT_JUMP_SPEED_MULT,
    Suffix = 'x',
    Flag = 'evade_jump_speed_mult',
    Callback = function(value) Tune.JumpSpeedMultiplier = value end,
})

JumpSection:Slider({
    Title = 'jump cap',
    Description = 'max jumps before touching the ground again',
    Min = 1,
    Max = 5,
    Increment = 1,
    Default = DEFAULT_JUMP_CAP,
    Flag = 'evade_jump_cap',
    Callback = function(value) Tune.JumpCap = value end,
})

JumpSection:Toggle({
    Title = 'bunny hop',
    Description = 'off natively - lets jumping repeatedly skip the run-up friction that normally caps your speed',
    Flag = 'evade_bhop',
    Default = false,
    Callback = function(state) Tune.BhopEnabled = state end,
})

JumpSection:Slider({
    Title = 'grounded check distance',
    Description = 'how far below your feet still counts as grounded - higher forgives small gaps and ramps',
    Min = 1,
    Max = 10,
    Increment = 0.1,
    Default = DEFAULT_GROUNDED_DIST,
    Suffix = ' studs',
    Flag = 'evade_grounded_dist',
    Callback = function(value) Tune.GroundedDistCheck = value end,
})

JumpSection:Toggle({
    Title = 'extra trimp boost',
    Description = 'multiplies whatever horizontal speed a jump already leaves you with, on top of the jump speed multiplier above - a second, separate boost to test against the native one',
    Flag = 'evade_trimp_boost_enabled',
    Default = false,
    Callback = function(state) Tune.TrimpBoostEnabled = state end,
})

JumpSection:Slider({
    Title = 'extra trimp boost multiplier',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_trimp_boost_mult',
    Callback = function(value) Tune.TrimpBoostMultiplier = value end,
})

local SlideSection = MovementTab:CreateSection('slide')

SlideSection:Toggle({
    Title = 'override slide',
    Description = 'scales the speed sliding down a ramp gives you and caps it at the value below, instead of the native ~55 studs/s ceiling',
    Flag = 'evade_slide_override',
    Default = false,
    Callback = function(state) Tune.SlideOverrideEnabled = state end,
})

SlideSection:Slider({
    Title = 'slide speed multiplier',
    Min = 0.25,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_slide_mult',
    Callback = function(value) Tune.SlideMultiplier = value end,
})

SlideSection:Slider({
    Title = 'slide max speed',
    Min = 10,
    Max = 250,
    Increment = 5,
    Default = DEFAULT_SLIDE_MAX_SPEED,
    Suffix = ' studs/s',
    Flag = 'evade_slide_max_speed',
    Callback = function(value) Tune.SlideMaxSpeed = value end,
})

local AirSection = MovementTab:CreateSection('air control')

AirSection:Slider({
    Title = 'air acceleration',
    Min = 0.1,
    Max = 10,
    Increment = 0.1,
    Default = DEFAULT_AIR_ACCEL,
    Flag = 'evade_air_accel',
    Callback = function(value) Tune.AirAcceleration = value end,
})

AirSection:Slider({
    Title = 'air strafe acceleration',
    Min = 20,
    Max = 800,
    Increment = 10,
    Default = DEFAULT_AIR_STRAFE_ACCEL,
    Flag = 'evade_air_strafe_accel',
    Callback = function(value) Tune.AirStrafeAcceleration = value end,
})

local ReviveTab = Window:CreateTab({ Title = 'revive' })
local ReviveSection = ReviveTab:CreateSection('manual revive')

ReviveSection:Toggle({
    Title = 'override revive time',
    Description = 'patches every gamemode\'s revive-hold duration to the value below. this is a client-side data edit - if the server independently times the hold, this will only change what you see locally, not what actually completes it',
    Flag = 'evade_revive_override',
    Default = false,
    Callback = function(state)
        Tune.ReviveOverrideEnabled = state
        if state then applyReviveOverride() end
    end,
})

ReviveSection:Slider({
    Title = 'revive time',
    Min = 0,
    Max = 1.4,
    Increment = 0.1,
    Default = 0,
    Suffix = ' s',
    Flag = 'evade_revive_time',
    Callback = function(value)
        Tune.ReviveTime = value
        applyReviveOverride()
    end,
})

ReviveSection:Button({
    Title = 'reapply now',
    Callback = applyReviveOverride,
})

local SessionTab = Window:CreateTab({ Title = 'session' })
local SessionSection = SessionTab:CreateSection('session')

SessionSection:Button({
    Title = 'unload',
    Confirm = true,
    Callback = function()
        Unloading = true
        Functions.Slide = originalSlide
        MovementClass.Jump = originalJump
        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Content = 'Restores the slide and jump functions to their original behavior, stops the movement-stat loop, then closes the menu.',
})

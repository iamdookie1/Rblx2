local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
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
local UseSettingsScript = waitPath(ReplicatedStorage, "Shared", "UserData", "ClientHooks", "useSettings")
local UseSettings = require(UseSettingsScript)
local ServerStateRegistryScript = waitPath(ReplicatedStorage, "Services", "Data", "ServerStateRegistryService")
local ServerStateRegistry = require(ServerStateRegistryScript)

local DEFAULT_SPEED = 1500 / 90
local DEFAULT_SPRINT_CAP = 2
local DEFAULT_JUMP_HEIGHT = 3
local DEFAULT_JUMP_SPEED_MULT = 1.45
local DEFAULT_JUMP_CAP = 1
local DEFAULT_GROUNDED_DIST = 2.9
local DEFAULT_AIR_ACCEL = 1
local DEFAULT_AIR_STRAFE_ACCEL = 182
local DEFAULT_SLIDE_MAX_SPEED = 5000 / 90
local DEFAULT_RUN_ACCEL = 1
local DEFAULT_RUN_DEACCEL = 700
local DEFAULT_FRICTION = 5
local DEFAULT_SPRINT_ACCEL = 1
local DEFAULT_WALK_SPEED_MULT = 1

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
    RunAccel = DEFAULT_RUN_ACCEL,
    RunDeaccel = DEFAULT_RUN_DEACCEL,
    Friction = DEFAULT_FRICTION,
    SprintAcceleration = DEFAULT_SPRINT_ACCEL,
    WalkSpeedMultiplier = DEFAULT_WALK_SPEED_MULT,

    JumpTrimpEnabled = false,
    JumpTrimpMultiplier = 1,
    ObjectTrimpEnabled = false,
    ObjectTrimpMultiplier = 1,

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
    stats.RunAccel = Tune.RunAccel
    stats.RunDeaccel = Tune.RunDeaccel
    stats.Friction = Tune.Friction
    stats.SprintAcceleration = Tune.SprintAcceleration
    stats.WalkSpeedMultiplier = Tune.WalkSpeedMultiplier
end

local function getLocalMoveStats()
    local character = CharacterService:GetLocalCharacter()
    local movement = character and character.Movement
    local statsComponent = movement and movement.MoveStats
    return statsComponent and statsComponent.MoveStats
end

task.spawn(function()
    while not Unloading do
        pcall(function()
            local stats = getLocalMoveStats()
            if stats then
                applyMovementTune(stats)
            end
        end)
        task.wait(0.5)
    end
end)

local ReviveState = { PatchedCount = 0 }

local function deepPatchReviveTime(tbl, value, seen)
    local count = 0
    for key, value2 in pairs(tbl) do
        if key == "ReviveTime" then
            tbl[key] = value
            count = count + 1
        elseif type(value2) == "table" and not seen[value2] then
            seen[value2] = true
            count = count + deepPatchReviveTime(value2, value, seen)
        end
    end
    return count
end

local function applyReviveOverride()
    if not Tune.ReviveOverrideEnabled then
        ReviveState.PatchedCount = 0
        return
    end
    local modules = GamemodesFolder:GetDescendants()
    local count = 0
    for _, gamemodeModule in ipairs(modules) do
        if gamemodeModule:IsA("ModuleScript") then
            local ok, data = pcall(require, gamemodeModule)
            if ok and type(data) == "table" then
                count = count + deepPatchReviveTime(data, Tune.ReviveTime, { [data] = true })
            end
        end
    end
    ReviveState.PatchedCount = count
end

task.spawn(function()
    for _ = 1, 20 do
        if #GamemodesFolder:GetDescendants() > 0 then break end
        task.wait(0.5)
    end
    while not Unloading do
        pcall(applyReviveOverride)
        task.wait(2)
    end
end)

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

local function boostHorizontalVelocity(dataRegistry, multiplier)
    local velocity = dataRegistry:Get("Velocity")
    if not velocity then return end
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    if horizontal.Magnitude > 1 then
        local boosted = horizontal * multiplier
        dataRegistry:Set("Velocity", Vector3.new(boosted.X, velocity.Y, boosted.Z))
    end
end

-- same restore-on-unload contract as Slide; scoped by comparing the live
-- character model rather than a captured reference so it survives respawns
local originalJump = MovementClass.Jump
MovementClass.Jump = function(self, ...)
    local boost = Tune.JumpTrimpEnabled and self.Character == LocalPlayer.Character
    local a, b = originalJump(self, ...)
    if boost then
        boostHorizontalVelocity(self.DataRegistry, Tune.JumpTrimpMultiplier)
    end
    return a, b
end

-- the native Slide state only reads slope off workspace.Map.Parts (its own
-- raycast is whitelisted to exactly that), so a crate or prop never gets
-- ramp treatment no matter how it's shaped. object trimp used to require
-- reading a tilted surface normal to fire, but trimping off an object isn't
-- actually about geometric slope - it can happen leaving a perfectly flat
-- crate too - so this now fires off leaving ANY grounded surface that
-- wasn't part of that native whitelist, tilted or not
local MapPartsContainer
do
    local mapFolder = workspace:WaitForChild("Map", 10)
    MapPartsContainer = mapFolder and mapFolder:WaitForChild("Parts", 10)
end

local lastGroundWasObject = false
local wasGrounded = false

local trimpConnection = RunService.Heartbeat:Connect(function()
    if not Tune.ObjectTrimpEnabled then return end
    local ok = pcall(function()
        local character = CharacterService:GetLocalCharacter()
        if not character or not character.Model or not character.Model.PrimaryPart then return end
        local root = character.Model.PrimaryPart
        local grounded = character.DataRegistry:Get("Grounded") == true

        if grounded then
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { character.Model }
            local result = workspace:Raycast(root.Position, Vector3.new(0, -4, 0), params)
            lastGroundWasObject = result ~= nil
                and not (MapPartsContainer and result.Instance:IsDescendantOf(MapPartsContainer))
        elseif wasGrounded and lastGroundWasObject then
            boostHorizontalVelocity(character.DataRegistry, Tune.ObjectTrimpMultiplier)
            lastGroundWasObject = false
        end

        wasGrounded = grounded
    end)
    if not ok then
        lastGroundWasObject = false
        wasGrounded = false
    end
end)

local OriginalLighting = {
    Brightness = Lighting.Brightness,
    ExposureCompensation = Lighting.ExposureCompensation,
    ClockTime = Lighting.ClockTime,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
}

local function restoreLighting()
    Lighting.Brightness = OriginalLighting.Brightness
    Lighting.ExposureCompensation = OriginalLighting.ExposureCompensation
    Lighting.ClockTime = OriginalLighting.ClockTime
    Lighting.Ambient = OriginalLighting.Ambient
    Lighting.OutdoorAmbient = OriginalLighting.OutdoorAmbient
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
        { Label = 'Air Accel (live)', Value = function()
            local stats = getLocalMoveStats()
            return stats and tostring(stats.AirAcceleration) or '-'
        end },
        { Label = 'Air Strafe (live)', Value = function()
            local stats = getLocalMoveStats()
            return stats and tostring(stats.AirStrafeAcceleration) or '-'
        end },
    },
})
LiveSection:Paragraph({
    Title = 'reading this',
    Content = 'the two "(live)" values read straight from the character\'s real movement table, not from this menu\'s own copy - if a slider below is moved and the matching live value here does not change within about half a second, the setting genuinely is not applying. if it does change and the game still feels the same, the setting is applying but its effect is naturally subtle (air acceleration only changes how fast you reach your air speed cap, not the cap itself, and air strafe acceleration only kicks in when moving purely sideways with no forward/back input at all)',
})

local RoundSection = MovementTab:CreateSection('round info')
RoundSection:Stats({
    Columns = 2,
    Items = {
        { Label = 'gamemode', Value = function()
            local ok, value = pcall(function() return ServerStateRegistry:Get("Gamemode") end)
            return (ok and value) and tostring(value) or '-'
        end },
        { Label = 'special round', Value = function()
            local ok, value = pcall(function() return ServerStateRegistry:Get("SpecialRound") end)
            return (ok and value) and tostring(value) or 'none'
        end },
    },
})

local PresetSection = MovementTab:CreateSection('preset')
local BaseSpeedSlider, SprintCapSlider, JumpHeightSlider, JumpMultSlider

PresetSection:Segmented({
    Title = 'quick preset',
    Values = { 'Default', 'Speedy', 'Extreme' },
    Default = 'Default',
    Flag = 'evade_movement_preset',
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
    Title = 'jump trimp boost',
    Description = 'multiplies whatever horizontal speed a jump already leaves you with, on top of the jump speed multiplier above - a second, separate boost stacked on top of the native trimp, tested purely through jumping',
    Flag = 'evade_jump_trimp_enabled',
    Default = false,
    Callback = function(state) Tune.JumpTrimpEnabled = state end,
})

JumpSection:Slider({
    Title = 'jump trimp multiplier',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_jump_trimp_mult',
    Callback = function(value) Tune.JumpTrimpMultiplier = value end,
})

JumpSection:Toggle({
    Title = 'object trimp boost',
    Description = 'boosts your horizontal speed the instant you leave any grounded surface that is not part of workspace.Map.Parts - the exact whitelist the native ramp slide uses, which is why props and crates never get ramp treatment on their own. this fires on any such surface, flat or tilted, since trimping off an object is not really about slope angle - independent from the jump trimp boost above, with its own multiplier below',
    Flag = 'evade_object_trimp_enabled',
    Default = false,
    Callback = function(state) Tune.ObjectTrimpEnabled = state end,
})

JumpSection:Slider({
    Title = 'object trimp multiplier',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_object_trimp_mult',
    Callback = function(value) Tune.ObjectTrimpMultiplier = value end,
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

local GroundSection = MovementTab:CreateSection('ground control')

GroundSection:Slider({
    Title = 'run acceleration',
    Description = 'how fast you speed up from a standstill on the ground',
    Min = 0.1,
    Max = 20,
    Increment = 0.1,
    Default = DEFAULT_RUN_ACCEL,
    Flag = 'evade_run_accel',
    Callback = function(value) Tune.RunAccel = value end,
})

GroundSection:Slider({
    Title = 'run deceleration',
    Description = 'how fast you slow down on the ground when you let go of movement keys - higher stops you almost instantly, lower lets you slide to a stop',
    Min = 50,
    Max = 3000,
    Increment = 50,
    Default = DEFAULT_RUN_DEACCEL,
    Flag = 'evade_run_deaccel',
    Callback = function(value) Tune.RunDeaccel = value end,
})

GroundSection:Slider({
    Title = 'friction',
    Description = 'the ground friction constant the run and slide states both use - lower makes the ground itself feel slicker',
    Min = 0,
    Max = 20,
    Increment = 0.5,
    Default = DEFAULT_FRICTION,
    Flag = 'evade_friction',
    Callback = function(value) Tune.Friction = value end,
})

GroundSection:Slider({
    Title = 'sprint ramp-up speed',
    Description = 'how fast the sprint multiplier climbs from 1x toward the sprint cap after you start holding forward',
    Min = 0.1,
    Max = 10,
    Increment = 0.1,
    Default = DEFAULT_SPRINT_ACCEL,
    Flag = 'evade_sprint_accel',
    Callback = function(value) Tune.SprintAcceleration = value end,
})

GroundSection:Slider({
    Title = 'walk speed multiplier',
    Description = 'a baseline speed multiplier applied even while not sprinting - 1 is default, higher makes ordinary walking noticeably faster on its own',
    Min = 0.5,
    Max = 3,
    Increment = 0.05,
    Default = DEFAULT_WALK_SPEED_MULT,
    Flag = 'evade_walk_speed_mult',
    Callback = function(value) Tune.WalkSpeedMultiplier = value end,
})

local AirSection = MovementTab:CreateSection('air control')

AirSection:Slider({
    Title = 'air acceleration',
    Description = 'how fast you reach your air speed cap while airborne and moving with your current velocity - does not raise the cap itself',
    Min = 0.1,
    Max = 50,
    Increment = 0.1,
    Default = DEFAULT_AIR_ACCEL,
    Flag = 'evade_air_accel',
    Callback = function(value) Tune.AirAcceleration = value end,
})

AirSection:Slider({
    Title = 'air strafe acceleration',
    Description = 'only used while holding pure sideways movement in the air with no forward/back input at all - test it that way specifically, since forward-air movement never reads this value',
    Min = 20,
    Max = 3000,
    Increment = 20,
    Default = DEFAULT_AIR_STRAFE_ACCEL,
    Flag = 'evade_air_strafe_accel',
    Callback = function(value) Tune.AirStrafeAcceleration = value end,
})

local EspTune = {
    Nextbot = false,
    Downed = false,
    Players = false,
    NextbotColor = Color3.fromRGB(255, 60, 60),
    DownedColor = Color3.fromRGB(255, 210, 60),
    PlayersColor = Color3.fromRGB(80, 170, 255),
    FillTransparency = 0.5,
    MaxDistance = 250,
    DistanceText = false,
    NameText = false,
}

local espHighlights = {}
local espLabels = {}

local function setHighlight(model, enabled, color)
    local highlight = espHighlights[model]
    if enabled then
        if not highlight then
            highlight = Instance.new("Highlight")
            highlight.OutlineTransparency = 0
            highlight.Parent = model
            espHighlights[model] = highlight
        end
        highlight.FillTransparency = EspTune.FillTransparency
        highlight.FillColor = color
        highlight.OutlineColor = color
    elseif highlight then
        highlight:Destroy()
        espHighlights[model] = nil
    end

    local label = espLabels[model]
    if enabled and (EspTune.DistanceText or EspTune.NameText) then
        if not label then
            local billboard = Instance.new("BillboardGui")
            billboard.Name = "EvadeEspDistance"
            billboard.Size = UDim2.fromOffset(100, 20)
            billboard.StudsOffset = Vector3.new(0, 3, 0)
            billboard.AlwaysOnTop = true
            billboard.Parent = model
            local text = Instance.new("TextLabel")
            text.BackgroundTransparency = 1
            text.Size = UDim2.fromScale(1, 1)
            text.Font = Enum.Font.GothamBold
            text.TextSize = 14
            text.TextStrokeTransparency = 0.3
            text.Parent = billboard
            label = { Billboard = billboard, Text = text }
            espLabels[model] = label
        end
        label.Text.TextColor3 = color
    elseif label then
        label.Billboard:Destroy()
        espLabels[model] = nil
    end
end

local function clearAllHighlights()
    for model, highlight in pairs(espHighlights) do
        highlight:Destroy()
        espHighlights[model] = nil
    end
    for model, label in pairs(espLabels) do
        label.Billboard:Destroy()
        espLabels[model] = nil
    end
end

local PlayersFolder = waitPath(workspace, "Players")

-- scans workspace.Players directly rather than only CharacterService's own
-- tracked list - confirmed from the dump this is exactly how the game's own
-- Fear/vignette code finds nextbots (workspace.Players:GetChildren(), then
-- GetAttribute("Team")), so identification no longer depends on whatever
-- CharacterService's own populate timing/filters happen to catch. Downed
-- state still needs CharacterService (DataRegistry lives on its wrapper,
-- not the raw model), built into a model->downed lookup once per tick
task.spawn(function()
    while not Unloading do
        pcall(function()
            local localCharacterModel = LocalPlayer.Character
            local myRoot = localCharacterModel and localCharacterModel:FindFirstChild("HumanoidRootPart")

            local downedByModel = {}
            for _, entry in ipairs(CharacterService:GetCharacters()) do
                if entry.Model and entry.DataRegistry then
                    downedByModel[entry.Model] = entry.DataRegistry:Get("Downed") == true
                end
            end

            local tracked = {}
            for _, model in ipairs(PlayersFolder:GetChildren()) do
                if model ~= localCharacterModel and model:IsA("Model") and model.PrimaryPart then
                    tracked[model] = true
                    local isNextbot = model:GetAttribute("Team") == "Nextbot"
                    local isDowned = downedByModel[model] == true
                    local distance = myRoot and (model.PrimaryPart.Position - myRoot.Position).Magnitude or 0
                    local inRange = distance <= EspTune.MaxDistance
                    local wantHighlight, color = false, nil

                    if inRange and EspTune.Downed and isDowned then
                        wantHighlight, color = true, EspTune.DownedColor
                    elseif inRange and EspTune.Nextbot and isNextbot then
                        wantHighlight, color = true, EspTune.NextbotColor
                    elseif inRange and EspTune.Players and not isNextbot then
                        wantHighlight, color = true, EspTune.PlayersColor
                    end

                    setHighlight(model, wantHighlight, color)
                    if wantHighlight and espLabels[model] then
                        local parts = {}
                        if EspTune.NameText then
                            local plr = Players:GetPlayerFromCharacter(model)
                            table.insert(parts, plr and plr.Name or model.Name)
                        end
                        if EspTune.DistanceText then
                            table.insert(parts, ('%d studs'):format(distance))
                        end
                        espLabels[model].Text.Text = table.concat(parts, ' - ')
                    end
                end
            end

            for model in pairs(espHighlights) do
                if not tracked[model] then
                    setHighlight(model, false)
                end
            end
        end)

        task.wait(0.5)
    end
end)

local VisualsTab = Window:CreateTab({ Title = 'visuals' })
local EspSection = VisualsTab:CreateSection('esp')

EspSection:Toggle({
    Title = 'nextbot esp',
    Description = 'highlights every character on the Nextbot team',
    Flag = 'evade_esp_nextbot',
    Default = false,
    Callback = function(state) EspTune.Nextbot = state end,
})

EspSection:Colorpicker({
    Title = 'nextbot color',
    Default = EspTune.NextbotColor,
    Flag = 'evade_esp_nextbot_color',
    Callback = function(color) EspTune.NextbotColor = color end,
})

EspSection:Toggle({
    Title = 'downed player esp',
    Description = 'highlights any character currently downed, regardless of team - useful for spotting revive targets',
    Flag = 'evade_esp_downed',
    Default = false,
    Callback = function(state) EspTune.Downed = state end,
})

EspSection:Colorpicker({
    Title = 'downed color',
    Default = EspTune.DownedColor,
    Flag = 'evade_esp_downed_color',
    Callback = function(color) EspTune.DownedColor = color end,
})

EspSection:Toggle({
    Title = 'player esp',
    Description = 'highlights every other non-nextbot character',
    Flag = 'evade_esp_players',
    Default = false,
    Callback = function(state) EspTune.Players = state end,
})

EspSection:Colorpicker({
    Title = 'player color',
    Default = EspTune.PlayersColor,
    Flag = 'evade_esp_players_color',
    Callback = function(color) EspTune.PlayersColor = color end,
})

local EspSettingsSection = VisualsTab:CreateSection('esp settings')

EspSettingsSection:Slider({
    Title = 'fill transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = EspTune.FillTransparency,
    Flag = 'evade_esp_fill_transparency',
    Callback = function(value) EspTune.FillTransparency = value end,
})

EspSettingsSection:Slider({
    Title = 'max distance',
    Min = 20,
    Max = 1000,
    Increment = 10,
    Default = EspTune.MaxDistance,
    Suffix = ' studs',
    Flag = 'evade_esp_max_distance',
    Callback = function(value) EspTune.MaxDistance = value end,
})

EspSettingsSection:Toggle({
    Title = 'distance text',
    Description = 'shows the live distance above anything currently highlighted',
    Flag = 'evade_esp_distance_text',
    Default = false,
    Callback = function(state) EspTune.DistanceText = state end,
})

EspSettingsSection:Toggle({
    Title = 'name text',
    Description = 'shows the player name (or the nextbot model name) above anything currently highlighted',
    Flag = 'evade_esp_name_text',
    Default = false,
    Callback = function(state) EspTune.NameText = state end,
})

local ComfortSection = VisualsTab:CreateSection('comfort')

local nextbotVignetteDefault = true
pcall(function()
    local current = UseSettings.Get("NextbotVignette")
    if current ~= nil then nextbotVignetteDefault = current end
end)

ComfortSection:Toggle({
    Title = 'nextbot vignette',
    Description = 'the game\'s own accessibility setting for the darkened-vision effect a nearby nextbot causes - this just flips it through the real settings system (Shared.UserData.ClientHooks.useSettings), same as toggling it in the game\'s own settings menu, so it is not a client-only hack',
    Flag = 'evade_nextbot_vignette',
    Default = nextbotVignetteDefault,
    Callback = function(state)
        pcall(function() UseSettings.SetSetting("NextbotVignette", state) end)
    end,
})

-- there is no separate camera-shake setting - checked the real settings
-- config (Shared.UserData.Settings.Config) and nextbot camera shake and the
-- vignette darkening are driven by the same Enabled flag on the same Fear
-- service, so the toggle above already covers both. these are the other
-- real, confirmed settings from that same config, exposed the same
-- legitimate way rather than a client-only hack
local function getSettingDefault(key, fallback)
    local ok, value = pcall(function() return UseSettings.Get(key) end)
    if ok and value ~= nil then return value end
    return fallback
end

local function setSetting(key, value)
    pcall(function() UseSettings.SetSetting(key, value) end)
end

local originalFov = getSettingDefault("FOV", 70)
local originalLowGraphics = getSettingDefault("LowGraphics", false)
local originalMapShadows = getSettingDefault("MapShadows", true)
local originalViewbob = getSettingDefault("Viewbob", true)
local originalPovScroll = getSettingDefault("POVScroll", true)

ComfortSection:Slider({
    Title = 'field of view',
    Min = 70,
    Max = 100,
    Increment = 1,
    Default = originalFov,
    Flag = 'evade_setting_fov',
    Callback = function(value) setSetting("FOV", value) end,
})

ComfortSection:Toggle({
    Title = 'low graphics',
    Flag = 'evade_setting_low_graphics',
    Default = originalLowGraphics,
    Callback = function(state) setSetting("LowGraphics", state) end,
})

ComfortSection:Toggle({
    Title = 'map shadows',
    Flag = 'evade_setting_map_shadows',
    Default = originalMapShadows,
    Callback = function(state) setSetting("MapShadows", state) end,
})

ComfortSection:Toggle({
    Title = 'view bob',
    Flag = 'evade_setting_viewbob',
    Default = originalViewbob,
    Callback = function(state) setSetting("Viewbob", state) end,
})

ComfortSection:Toggle({
    Title = 'scroll to change pov',
    Flag = 'evade_setting_pov_scroll',
    Default = originalPovScroll,
    Callback = function(state) setSetting("POVScroll", state) end,
})

local LightingSection = VisualsTab:CreateSection('lighting')
local FullbrightEnabled = false
local BrightnessSlider, ExposureSlider, ClockTimeSlider

BrightnessSlider = LightingSection:Slider({
    Title = 'brightness',
    Min = 0,
    Max = 10,
    Increment = 0.1,
    Default = OriginalLighting.Brightness,
    Flag = 'evade_lighting_brightness',
    Callback = function(value)
        if not FullbrightEnabled then Lighting.Brightness = value end
    end,
})

ExposureSlider = LightingSection:Slider({
    Title = 'exposure compensation',
    Min = -1,
    Max = 2,
    Increment = 0.05,
    Default = OriginalLighting.ExposureCompensation,
    Flag = 'evade_lighting_exposure',
    Callback = function(value)
        if not FullbrightEnabled then Lighting.ExposureCompensation = value end
    end,
})

ClockTimeSlider = LightingSection:Slider({
    Title = 'clock time',
    Description = 'forces the time of day - 14 is the map\'s own default afternoon setting, useful for undoing a darkness special round',
    Min = 0,
    Max = 24,
    Increment = 0.5,
    Default = OriginalLighting.ClockTime,
    Flag = 'evade_lighting_clocktime',
    Callback = function(value)
        if not FullbrightEnabled then Lighting.ClockTime = value end
    end,
})

LightingSection:Toggle({
    Title = 'fullbright',
    Description = 'cranks brightness, exposure and ambient light to a flat maximum and locks the time to midday, overriding the sliders above while on - the fastest way to just see everything regardless of round or map',
    Flag = 'evade_fullbright',
    Default = false,
    Callback = function(state)
        FullbrightEnabled = state
        if state then
            Lighting.Brightness = 5
            Lighting.ExposureCompensation = 1
            Lighting.ClockTime = 14
            Lighting.Ambient = Color3.fromRGB(150, 150, 150)
            Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
        else
            Lighting.Brightness = BrightnessSlider:Get()
            Lighting.ExposureCompensation = ExposureSlider:Get()
            Lighting.ClockTime = ClockTimeSlider:Get()
            Lighting.Ambient = OriginalLighting.Ambient
            Lighting.OutdoorAmbient = OriginalLighting.OutdoorAmbient
        end
    end,
})

local ReviveTab = Window:CreateTab({ Title = 'revive' })
local ReviveSection = ReviveTab:CreateSection('manual revive')

ReviveSection:Stats({
    Columns = 1,
    Items = {
        { Label = 'patched configs', Value = function()
            return Tune.ReviveOverrideEnabled and tostring(ReviveState.PatchedCount) or 'off'
        end },
    },
})

ReviveSection:Toggle({
    Title = 'instant revive',
    Description = 'patches every gamemode\'s revive-hold duration to the value below (0 by default) and keeps reapplying it every couple seconds. this is a client-side data edit - if the server independently times the hold, this only changes what you see locally, not what actually completes it. the stat above shows how many configs it actually found and patched',
    Flag = 'evade_revive_override',
    Default = false,
    Callback = function(state)
        Tune.ReviveOverrideEnabled = state
        applyReviveOverride()
    end,
})

ReviveSection:Slider({
    Title = 'custom revive time (advanced)',
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

local function getFloatingGuiParent()
    local target
    local ok = pcall(function()
        if typeof(gethui) == "function" then target = gethui() end
    end)
    if not ok or not target then
        local ok2 = pcall(function()
            local coreGui = game:GetService("CoreGui")
            local probe = Instance.new("ScreenGui")
            probe.Parent = coreGui
            probe:Destroy()
            target = coreGui
        end)
        if not ok2 then target = nil end
    end
    if not target then
        target = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
    end
    return target
end

local floatingPanelOffset = 0

-- a compact draggable pill instead of a full Onyx window - just a label and
-- a switch, no topbar/rail/settings overhead. drag tracks the exact
-- InputObject that pressed it (not a global InputChanged listener), so a
-- second finger moving elsewhere on screen - a touch joystick, say - can
-- never drag it by mistake
local function createFloatingPanel(title, initialActive, onToggle)
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "EvadeFloating_" .. title:gsub("%s+", "")
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 9999
    screenGui.Parent = getFloatingGuiParent()

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Size = UDim2.fromOffset(150, 40)
    frame.Position = UDim2.fromOffset(16, 160 + floatingPanelOffset)
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 27)
    frame.BorderSizePixel = 0
    frame.Parent = screenGui
    floatingPanelOffset = floatingPanelOffset + 48

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.85
    stroke.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -54, 1, 0)
    label.Position = UDim2.fromOffset(10, 0)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(230, 230, 235)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Text = title
    label.Parent = frame

    local button = Instance.new("TextButton")
    button.Name = "Toggle"
    button.AutoButtonColor = false
    button.Text = ""
    button.Size = UDim2.fromOffset(34, 20)
    button.Position = UDim2.new(1, -44, 0.5, -10)
    button.BackgroundColor3 = Color3.fromRGB(60, 60, 66)
    button.Parent = frame

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(1, 0)
    buttonCorner.Parent = button

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(16, 16)
    knob.Position = UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = Color3.fromRGB(230, 230, 235)
    knob.BorderSizePixel = 0
    knob.Parent = button

    local knobCorner = Instance.new("UICorner")
    knobCorner.CornerRadius = UDim.new(1, 0)
    knobCorner.Parent = knob

    local active = initialActive
    local function render()
        if active then
            button.BackgroundColor3 = Color3.fromRGB(210, 45, 45)
            knob.Position = UDim2.fromOffset(16, 2)
        else
            button.BackgroundColor3 = Color3.fromRGB(60, 60, 66)
            knob.Position = UDim2.fromOffset(2, 2)
        end
    end
    render()

    local moved = false
    frame.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        moved = false
        local startInput = input.Position
        local startPos = frame.Position
        local conn
        conn = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                conn:Disconnect()
                return
            end
            local delta = input.Position - startInput
            if math.abs(delta.X) + math.abs(delta.Y) > 8 then moved = true end
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end)
    end)

    button.MouseButton1Click:Connect(function()
        if moved then return end
        active = not active
        render()
        onToggle(active)
    end)

    return {
        SetActive = function(state)
            active = state
            render()
        end,
        Destroy = function() screenGui:Destroy() end,
    }
end

local AutoJumpPanel
local AutoJumpElement
local AutoJumpActive = false
local AutoJumpInterval = 0.15

-- the panel is quick access to flip the feature on/off without reopening
-- this menu, so turning it off FROM THE PANEL must never remove the panel
-- itself - only the main toggle (fromPanel == false) installs/uninstalls
-- it. syncing the main toggle's own visual after a panel click still fires
-- that toggle's callback though (Onyx's :Set always does), so the suppress
-- flag stops that echoed call from re-running the install/uninstall logic
local suppressJumpPanelSync = false
local function setAutoJumpActive(state, fromPanel)
    AutoJumpActive = state

    if fromPanel then
        if AutoJumpElement then
            suppressJumpPanelSync = true
            AutoJumpElement:Set(state)
            suppressJumpPanelSync = false
        end
        return
    end

    if suppressJumpPanelSync then return end

    if state then
        if AutoJumpPanel then
            AutoJumpPanel.SetActive(true)
        else
            AutoJumpPanel = createFloatingPanel('auto jump', true, function(panelState)
                setAutoJumpActive(panelState, true)
            end)
        end
    elseif AutoJumpPanel then
        AutoJumpPanel.Destroy()
        AutoJumpPanel = nil
    end
end

-- AttemptJump() is a plain, single, non-blocking jump attempt.
-- JumpReact() (what a real key-down calls) is NOT: it sets JumpHeldDown and
-- then yields on Heartbeat in a loop until something calls it again with a
-- matching release, exactly like holding a key down and letting go. calling
-- it here with no release ever coming left this coroutine permanently
-- parked inside that wait after the first jump - which is why "auto jump"
-- jumped once and then simply stopped
task.spawn(function()
    while not Unloading do
        if AutoJumpActive then
            pcall(function()
                local character = CharacterService:GetLocalCharacter()
                local movement = character and character.Movement
                if movement then movement:AttemptJump() end
            end)
        end
        task.wait(AutoJumpInterval)
    end
end)

local RELEASE_RANGE_MARGIN = 2
local MIN_HOLD_TIME = 0.3

local function findDownedTeammate(maxRange)
    local localCharacter = CharacterService:GetLocalCharacter()
    if not localCharacter or not localCharacter.Model or not localCharacter.Model.PrimaryPart then
        return nil
    end
    local myTeam = localCharacter.Model:GetAttribute("Team")
    local myPosition = localCharacter.Model.PrimaryPart.Position
    for _, entry in ipairs(CharacterService:GetCharacters()) do
        if entry ~= localCharacter and entry.Model and entry.Model.PrimaryPart
            and myTeam ~= nil and entry.Model:GetAttribute("Team") == myTeam
            and entry.DataRegistry and entry.DataRegistry:Get("Downed") == true then
            local distance = (entry.Model.PrimaryPart.Position - myPosition).Magnitude
            if distance <= maxRange then
                return entry
            end
        end
    end
    return nil
end

-- calls character.ToolProfile:KeyPhraseUsed directly instead of the broader
-- Character:KeyUsed, which also fans this same "Interact" event out to
-- Camera/Movement/Actions/Animations - none of which have anything to do
-- with reviving or carrying, but any of which could react to a simulated
-- Interact key in unrelated ways. ToolProfile is the only one that owns
-- whichever downed-teammate task actually resolves from pressing it
local function sendInteract(character, down)
    if not character or not character.ToolProfile then return end
    pcall(function() character.ToolProfile:KeyPhraseUsed({ Key = "Interact", Down = down }) end)
end

-- revive and carry both turned out to run through this exact same
-- mechanism: holding Interact on a nearby downed teammate, with the game
-- itself resolving which of the two tasks that actually triggers - no
-- separate carry keybind or remote exists anywhere in the dump. so both
-- "features" below are really the same automation instantiated twice,
-- each with its own toggle, panel, range and hold state, since the two are
-- still meant to be controlled independently even though they do the same
-- thing under the hood
local function createDownedInteractAutomation(panelTitle, defaultRange)
    local automation = {
        Panel = nil,
        Element = nil,
        Active = false,
        Range = defaultRange,
        Holding = false,
        HeldSince = 0,
        SuppressPanelSync = false,
    }

    local function releaseHold()
        if not automation.Holding then return end
        automation.Holding = false
        sendInteract(CharacterService:GetLocalCharacter(), false)
    end
    automation.ReleaseHold = releaseHold

    -- same panel-persistence contract as auto jump: turning the feature off
    -- FROM THE PANEL must never remove the panel, only the main toggle does
    local function setActive(state, fromPanel)
        automation.Active = state
        if not state then releaseHold() end

        if fromPanel then
            if automation.Element then
                automation.SuppressPanelSync = true
                automation.Element:Set(state)
                automation.SuppressPanelSync = false
            end
            return
        end

        if automation.SuppressPanelSync then return end

        if state then
            if automation.Panel then
                automation.Panel.SetActive(true)
            else
                automation.Panel = createFloatingPanel(panelTitle, true, function(panelState)
                    setActive(panelState, true)
                end)
            end
        elseif automation.Panel then
            automation.Panel.Destroy()
            automation.Panel = nil
        end
    end
    automation.SetActive = setActive

    -- acquiring a hold uses the configured range, releasing needs the
    -- target to drift RELEASE_RANGE_MARGIN studs further out than that, and
    -- a hold can't end before MIN_HOLD_TIME regardless - without this, a
    -- teammate sitting right at the edge of the range during ordinary
    -- movement jitter flickered in and out many times a second, meaning
    -- rapid real press/release events reaching the actual task - which is
    -- exactly what spamming the real key that fast would also do
    task.spawn(function()
        while not Unloading do
            pcall(function()
                if automation.Active then
                    local character = CharacterService:GetLocalCharacter()
                    if automation.Holding then
                        local target = character and findDownedTeammate(automation.Range + RELEASE_RANGE_MARGIN)
                        if not target and (os.clock() - automation.HeldSince) >= MIN_HOLD_TIME then
                            releaseHold()
                        end
                    else
                        local target = character and findDownedTeammate(automation.Range)
                        if target then
                            automation.Holding = true
                            automation.HeldSince = os.clock()
                            sendInteract(character, true)
                        end
                    end
                elseif automation.Holding then
                    releaseHold()
                end
            end)
            task.wait(0.2)
        end
    end)

    return automation
end

local AutoRevive = createDownedInteractAutomation('auto revive', 8)
local AutoCarry = createDownedInteractAutomation('auto carry', 8)

local ExtraTab = Window:CreateTab({ Title = 'extra' })
local AutoSection = ExtraTab:CreateSection('automation')

AutoJumpElement = AutoSection:Toggle({
    Title = 'auto jump',
    Description = 'jumps on an interval for as long as this is on. also opens a small draggable pill with its own switch, so it can be stopped without reopening this menu - the two stay in sync either direction',
    Flag = 'evade_auto_jump',
    Default = false,
    Callback = function(state) setAutoJumpActive(state, false) end,
})

AutoSection:Slider({
    Title = 'auto jump interval',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = AutoJumpInterval,
    Suffix = ' s',
    Flag = 'evade_auto_jump_interval',
    Callback = function(value) AutoJumpInterval = value end,
})

AutoRevive.Element = AutoSection:Toggle({
    Title = 'auto revive',
    Description = 'automatically holds interact on the nearest downed teammate in range - the same input path a real keypress uses, just triggered by range instead of a key. also opens a small draggable pill with its own switch, synced with this one either direction',
    Flag = 'evade_auto_revive',
    Default = false,
    Callback = function(state) AutoRevive.SetActive(state, false) end,
})

AutoSection:Slider({
    Title = 'auto revive range',
    Min = 3,
    Max = 20,
    Increment = 1,
    Default = AutoRevive.Range,
    Suffix = ' studs',
    Flag = 'evade_auto_revive_range',
    Callback = function(value) AutoRevive.Range = value end,
})

AutoCarry.Element = AutoSection:Toggle({
    Title = 'auto carry',
    Description = 'checked directly in the game\'s own code: carrying and reviving a downed teammate turned out to go through the exact same interact-on-a-downed-teammate mechanism, with the game itself deciding which one actually happens - so this is functionally the same automation as auto revive above, just controlled separately in case you want one running without the other',
    Flag = 'evade_auto_carry',
    Default = false,
    Callback = function(state) AutoCarry.SetActive(state, false) end,
})

AutoSection:Slider({
    Title = 'auto carry range',
    Min = 3,
    Max = 20,
    Increment = 1,
    Default = AutoCarry.Range,
    Suffix = ' studs',
    Flag = 'evade_auto_carry_range',
    Callback = function(value) AutoCarry.Range = value end,
})

local UtilitySection = ExtraTab:CreateSection('utility')

UtilitySection:Button({
    Title = 'unstuck',
    Description = 'nudges you straight up a few studs and zeroes your velocity - for when movement testing wedges you into geometry',
    Callback = function()
        pcall(function()
            local character = CharacterService:GetLocalCharacter()
            local root = character and character.Model and character.Model.PrimaryPart
            if not root then return end
            root.CFrame = root.CFrame + Vector3.new(0, 6, 0)
            root.AssemblyLinearVelocity = Vector3.new()
            if character.DataRegistry then
                character.DataRegistry:Set("Velocity", Vector3.new())
            end
        end)
    end,
})

local SessionTab = Window:CreateTab({ Title = 'session' })
local SessionSection = SessionTab:CreateSection('session')

-- goes through every flagged element via Onyx:SetFlag rather than holding a
-- reference to each slider/toggle individually - SetFlag both updates the
-- element's own visual state and fires its callback, so this converges to
-- the same end result regardless of what order the flags happen to reset in
local function resetAllOptions()
    local defaults = {
        evade_movement_preset = 'Default',
        evade_base_speed = DEFAULT_SPEED,
        evade_sprint_cap = DEFAULT_SPRINT_CAP,
        evade_jump_height = DEFAULT_JUMP_HEIGHT,
        evade_jump_speed_mult = DEFAULT_JUMP_SPEED_MULT,
        evade_jump_cap = DEFAULT_JUMP_CAP,
        evade_bhop = false,
        evade_grounded_dist = DEFAULT_GROUNDED_DIST,
        evade_jump_trimp_enabled = false,
        evade_jump_trimp_mult = 1,
        evade_object_trimp_enabled = false,
        evade_object_trimp_mult = 1,
        evade_slide_override = false,
        evade_slide_mult = 1,
        evade_slide_max_speed = DEFAULT_SLIDE_MAX_SPEED,
        evade_run_accel = DEFAULT_RUN_ACCEL,
        evade_run_deaccel = DEFAULT_RUN_DEACCEL,
        evade_friction = DEFAULT_FRICTION,
        evade_sprint_accel = DEFAULT_SPRINT_ACCEL,
        evade_walk_speed_mult = DEFAULT_WALK_SPEED_MULT,
        evade_air_accel = DEFAULT_AIR_ACCEL,
        evade_air_strafe_accel = DEFAULT_AIR_STRAFE_ACCEL,

        evade_esp_nextbot = false,
        evade_esp_nextbot_color = Color3.fromRGB(255, 60, 60),
        evade_esp_downed = false,
        evade_esp_downed_color = Color3.fromRGB(255, 210, 60),
        evade_esp_players = false,
        evade_esp_players_color = Color3.fromRGB(80, 170, 255),
        evade_esp_fill_transparency = 0.5,
        evade_esp_max_distance = 250,
        evade_esp_distance_text = false,
        evade_esp_name_text = false,

        evade_nextbot_vignette = nextbotVignetteDefault,
        evade_setting_fov = originalFov,
        evade_setting_low_graphics = originalLowGraphics,
        evade_setting_map_shadows = originalMapShadows,
        evade_setting_viewbob = originalViewbob,
        evade_setting_pov_scroll = originalPovScroll,

        evade_lighting_brightness = OriginalLighting.Brightness,
        evade_lighting_exposure = OriginalLighting.ExposureCompensation,
        evade_lighting_clocktime = OriginalLighting.ClockTime,
        evade_fullbright = false,

        evade_revive_override = false,
        evade_revive_time = 0,

        evade_auto_jump = false,
        evade_auto_jump_interval = 0.15,
        evade_auto_revive = false,
        evade_auto_revive_range = 8,
        evade_auto_carry = false,
        evade_auto_carry_range = 8,
    }

    for flag, value in pairs(defaults) do
        pcall(function() Onyx:SetFlag(flag, value) end)
    end
    clearAllHighlights()
end

SessionSection:Button({
    Title = 'reset all options',
    Description = 'sets every setting on every tab back to its original default - in case testing gets away from you and you just want a clean slate without rejoining',
    Confirm = true,
    Callback = resetAllOptions,
})

SessionSection:Button({
    Title = 'unload',
    Confirm = true,
    Callback = function()
        Unloading = true
        Functions.Slide = originalSlide
        MovementClass.Jump = originalJump
        trimpConnection:Disconnect()
        restoreLighting()
        clearAllHighlights()
        setAutoJumpActive(false, false)
        AutoRevive.SetActive(false, false)
        AutoCarry.SetActive(false, false)
        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Content = 'Restores the slide and jump functions to their original behavior, restores lighting, stops every loop, clears esp, closes the auto jump/revive panels if open, then closes the menu.',
})

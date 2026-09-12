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

    TrimpBoostEnabled = false,
    TrimpBoostMultiplier = 1,
    TrimpOnTouchEnabled = false,

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
    local boost = Tune.TrimpBoostEnabled and self.Character == LocalPlayer.Character
    local a, b = originalJump(self, ...)
    if boost then
        boostHorizontalVelocity(self.DataRegistry, Tune.TrimpBoostMultiplier)
    end
    return a, b
end

-- mirrors the native Slide state's own ground-normal raycast (it whitelists
-- only workspace.Map.Parts, which is why standing on a slanted crate or prop
-- never gets the native ramp treatment) - this one checks any surface, and
-- only fires the boost the instant you leave a surface that was genuinely
-- tilted, not on every touch, so it reads as an actual launch off a slope
-- rather than a flat "bumped into something" speed bump
local SLOPE_MIN_TILT = 0.3
local SLOPE_MAX_TILT = 0.95

local lastGroundNormal = nil
local wasGrounded = false

local trimpConnection = RunService.Heartbeat:Connect(function()
    if not Tune.TrimpOnTouchEnabled then return end
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
            lastGroundNormal = result and result.Normal or nil
        elseif wasGrounded and lastGroundNormal then
            local tilt = lastGroundNormal:Dot(Vector3.new(0, 1, 0))
            if tilt > SLOPE_MIN_TILT and tilt < SLOPE_MAX_TILT then
                boostHorizontalVelocity(character.DataRegistry, Tune.TrimpBoostMultiplier)
            end
            lastGroundNormal = nil
        end

        wasGrounded = grounded
    end)
    if not ok then
        lastGroundNormal = nil
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

JumpSection:Toggle({
    Title = 'trimp off slanted objects',
    Description = 'reads the ground normal the same way the native ramp slide does, but off any surface instead of only workspace.Map.Parts - the instant you leave a surface that was actually tilted (not flat, not a wall), it applies the trimp boost, so slanted crates and props launch you the same way a real ramp does instead of every touch giving a speed bump',
    Flag = 'evade_trimp_on_touch',
    Default = false,
    Callback = function(state) Tune.TrimpOnTouchEnabled = state end,
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
local function createFloatingPanel(title, onToggle)
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

    local active = false
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
        Destroy = function() screenGui:Destroy() end,
    }
end

local AutoJumpPanel
local AutoJumpActive = false
local AutoJumpInterval = 0.15

local function destroyAutoJumpPanel()
    if AutoJumpPanel then
        AutoJumpPanel.Destroy()
        AutoJumpPanel = nil
    end
    AutoJumpActive = false
end

local function buildAutoJumpPanel()
    destroyAutoJumpPanel()
    AutoJumpPanel = createFloatingPanel('auto jump', function(state) AutoJumpActive = state end)
end

task.spawn(function()
    while not Unloading do
        if AutoJumpActive then
            pcall(function()
                local character = CharacterService:GetLocalCharacter()
                local movement = character and character.Movement
                if movement then movement:JumpReact() end
            end)
        end
        task.wait(AutoJumpInterval)
    end
end)

local AutoRevivePanel
local AutoReviveActive = false
local AutoReviveRange = 8
local reviveHolding = false

local function findDownedTeammateInRange()
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
            if distance <= AutoReviveRange then
                return entry
            end
        end
    end
    return nil
end

local function releaseReviveHold()
    if not reviveHolding then return end
    reviveHolding = false
    local character = CharacterService:GetLocalCharacter()
    if character then
        pcall(function() character:KeyUsed({ Key = "Interact", Down = false }) end)
    end
end

local function destroyAutoRevivePanel()
    if AutoRevivePanel then
        AutoRevivePanel.Destroy()
        AutoRevivePanel = nil
    end
    AutoReviveActive = false
    releaseReviveHold()
end

local function buildAutoRevivePanel()
    destroyAutoRevivePanel()
    AutoRevivePanel = createFloatingPanel('auto revive', function(state)
        AutoReviveActive = state
        if not state then releaseReviveHold() end
    end)
end

-- calls the same Character:KeyUsed({Key="Interact", Down=...}) path the
-- game's own input handler calls on a real keypress (confirmed from the
-- dump: KeybindService binds E to the "Interact" action, and Character:
-- KeyUsed forwards it to ToolProfile:KeyPhraseUsed, which resolves and
-- fires the tool's real activation) - not a guessed remote call
task.spawn(function()
    while not Unloading do
        pcall(function()
            if AutoReviveActive then
                local character = CharacterService:GetLocalCharacter()
                local target = character and findDownedTeammateInRange()
                if target and not reviveHolding then
                    reviveHolding = true
                    character:KeyUsed({ Key = "Interact", Down = true })
                elseif not target and reviveHolding then
                    releaseReviveHold()
                end
            elseif reviveHolding then
                releaseReviveHold()
            end
        end)
        task.wait(0.2)
    end
end)

local ExtraTab = Window:CreateTab({ Title = 'extra' })
local AutoSection = ExtraTab:CreateSection('automation')

AutoSection:Toggle({
    Title = 'auto jump panel',
    Description = 'shows a small draggable pill with its own on/off switch, so auto jump can be started or stopped without opening this menu',
    Flag = 'evade_auto_jump_panel',
    Default = false,
    Callback = function(state)
        if state then buildAutoJumpPanel() else destroyAutoJumpPanel() end
    end,
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

AutoSection:Toggle({
    Title = 'auto revive panel',
    Description = 'shows a small draggable pill with its own on/off switch. while active, automatically holds interact on the nearest downed teammate in range - the same input path a real keypress uses, just triggered by range instead of a key',
    Flag = 'evade_auto_revive_panel',
    Default = false,
    Callback = function(state)
        if state then buildAutoRevivePanel() else destroyAutoRevivePanel() end
    end,
})

AutoSection:Slider({
    Title = 'auto revive range',
    Min = 3,
    Max = 20,
    Increment = 1,
    Default = AutoReviveRange,
    Suffix = ' studs',
    Flag = 'evade_auto_revive_range',
    Callback = function(value) AutoReviveRange = value end,
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
        trimpConnection:Disconnect()
        restoreLighting()
        clearAllHighlights()
        destroyAutoJumpPanel()
        destroyAutoRevivePanel()
        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Content = 'Restores the slide and jump functions to their original behavior, restores lighting, stops every loop, clears esp, closes the auto jump/revive panels if open, then closes the menu.',
})

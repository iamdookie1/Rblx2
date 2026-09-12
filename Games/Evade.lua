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
    local count = 0
    for _, gamemodeModule in ipairs(GamemodesFolder:GetChildren()) do
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
    while not Unloading do
        applyReviveOverride()
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

local function isCharacterPart(part)
    local model = part.Parent
    return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local touchDebounce = false
local function onLocalTouched(hit)
    if not Tune.TrimpOnTouchEnabled or touchDebounce then return end
    if not hit:IsA("BasePart") or isCharacterPart(hit) then return end
    local character = CharacterService:GetLocalCharacter()
    if not character then return end
    touchDebounce = true
    boostHorizontalVelocity(character.DataRegistry, Tune.TrimpBoostMultiplier)
    task.delay(0.3, function() touchDebounce = false end)
end

local touchConnection
local function connectTouch(char)
    if touchConnection then touchConnection:Disconnect() end
    local root = char:WaitForChild("HumanoidRootPart", 5)
    if root then
        touchConnection = root.Touched:Connect(onLocalTouched)
    end
end

if LocalPlayer.Character then connectTouch(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(connectTouch)

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

JumpSection:Toggle({
    Title = 'trimp off objects',
    Description = 'applies the same extra boost above when you touch a prop or piece of map geometry while moving fast, not only when you jump - the same tech off crates and terrain, not just ramps',
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

local EspTune = {
    Nextbot = false,
    Downed = false,
    Players = false,
}

local espHighlights = {}

local function setHighlight(model, enabled, color)
    local highlight = espHighlights[model]
    if enabled then
        if not highlight then
            highlight = Instance.new("Highlight")
            highlight.FillTransparency = 0.5
            highlight.OutlineTransparency = 0
            highlight.Parent = model
            espHighlights[model] = highlight
        end
        highlight.FillColor = color
        highlight.OutlineColor = color
    elseif highlight then
        highlight:Destroy()
        espHighlights[model] = nil
    end
end

local function clearAllHighlights()
    for model, highlight in pairs(espHighlights) do
        highlight:Destroy()
        espHighlights[model] = nil
    end
end

task.spawn(function()
    while not Unloading do
        local localCharacter = CharacterService:GetLocalCharacter()
        local tracked = {}

        for _, entry in ipairs(CharacterService:GetCharacters()) do
            local model = entry.Model
            if model and entry ~= localCharacter then
                tracked[model] = true
                local isNextbot = model:GetAttribute("Team") == "Nextbot"
                local isDowned = entry.DataRegistry ~= nil and entry.DataRegistry:Get("Downed") == true
                local wantHighlight, color = false, nil

                if EspTune.Downed and isDowned then
                    wantHighlight, color = true, Color3.fromRGB(255, 210, 60)
                elseif EspTune.Nextbot and isNextbot then
                    wantHighlight, color = true, Color3.fromRGB(255, 60, 60)
                elseif EspTune.Players and not isNextbot then
                    wantHighlight, color = true, Color3.fromRGB(80, 170, 255)
                end

                setHighlight(model, wantHighlight, color)
            end
        end

        for model in pairs(espHighlights) do
            if not tracked[model] then
                setHighlight(model, false)
            end
        end

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

EspSection:Toggle({
    Title = 'downed player esp',
    Description = 'highlights any character currently downed, regardless of team - useful for spotting revive targets',
    Flag = 'evade_esp_downed',
    Default = false,
    Callback = function(state) EspTune.Downed = state end,
})

EspSection:Toggle({
    Title = 'player esp',
    Description = 'highlights every other non-nextbot character',
    Flag = 'evade_esp_players',
    Default = false,
    Callback = function(state) EspTune.Players = state end,
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

local MINI_WINDOW_ACCENT = Color3.fromRGB(210, 45, 45)

local AutoJumpWindow
local AutoJumpActive = false
local AutoJumpInterval = 0.15

local function destroyAutoJumpWindow()
    if AutoJumpWindow then
        AutoJumpWindow:Destroy()
        AutoJumpWindow = nil
    end
    AutoJumpActive = false
end

local function buildAutoJumpWindow()
    destroyAutoJumpWindow()
    AutoJumpWindow = Onyx:CreateWindow({
        Title = 'auto jump',
        Size = UDim2.fromOffset(220, 130),
        MinSize = Vector2.new(160, 100),
        Resizable = true,
        Settings = false,
        ShowUserInfo = false,
        Accent = MINI_WINDOW_ACCENT,
    })
    local tab = AutoJumpWindow:CreateTab({ Title = 'jump' })
    local section = tab:CreateSection('auto jump')
    section:Toggle({
        Title = 'active',
        Callback = function(state) AutoJumpActive = state end,
    })
end

task.spawn(function()
    while not Unloading do
        if AutoJumpActive then
            local character = CharacterService:GetLocalCharacter()
            local movement = character and character.Movement
            if movement then
                pcall(function() movement:JumpReact() end)
            end
        end
        task.wait(AutoJumpInterval)
    end
end)

local AutoReviveWindow
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

local function destroyAutoReviveWindow()
    if AutoReviveWindow then
        AutoReviveWindow:Destroy()
        AutoReviveWindow = nil
    end
    AutoReviveActive = false
    releaseReviveHold()
end

local function buildAutoReviveWindow()
    destroyAutoReviveWindow()
    AutoReviveWindow = Onyx:CreateWindow({
        Title = 'auto revive',
        Size = UDim2.fromOffset(220, 130),
        MinSize = Vector2.new(160, 100),
        Resizable = true,
        Settings = false,
        ShowUserInfo = false,
        Accent = MINI_WINDOW_ACCENT,
    })
    local tab = AutoReviveWindow:CreateTab({ Title = 'revive' })
    local section = tab:CreateSection('auto revive')
    section:Toggle({
        Title = 'active',
        Callback = function(state)
            AutoReviveActive = state
            if not state then releaseReviveHold() end
        end,
    })
end

-- calls the same Character:KeyUsed({Key="Interact", Down=...}) path the
-- game's own input handler calls on a real keypress (confirmed from the
-- dump: KeybindService binds E to the "Interact" action, and Character:
-- KeyUsed forwards it to ToolProfile:KeyPhraseUsed, which resolves and
-- fires the tool's real activation) - not a guessed remote call
task.spawn(function()
    while not Unloading do
        if AutoReviveActive then
            local character = CharacterService:GetLocalCharacter()
            local target = character and findDownedTeammateInRange()
            if target and not reviveHolding then
                reviveHolding = true
                pcall(function() character:KeyUsed({ Key = "Interact", Down = true }) end)
            elseif not target and reviveHolding then
                releaseReviveHold()
            end
        elseif reviveHolding then
            releaseReviveHold()
        end
        task.wait(0.2)
    end
end)

local ExtraTab = Window:CreateTab({ Title = 'extra' })
local AutoSection = ExtraTab:CreateSection('automation')

AutoSection:Toggle({
    Title = 'auto jump panel',
    Description = 'shows a small resizable window with its own on/off switch, so auto jump can be started or stopped without opening this menu',
    Flag = 'evade_auto_jump_panel',
    Default = false,
    Callback = function(state)
        if state then buildAutoJumpWindow() else destroyAutoJumpWindow() end
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
    Description = 'shows a small resizable window with its own on/off switch. while active, automatically holds interact on the nearest downed teammate in range - the same input path a real keypress uses, just triggered by range instead of a key',
    Flag = 'evade_auto_revive_panel',
    Default = false,
    Callback = function(state)
        if state then buildAutoReviveWindow() else destroyAutoReviveWindow() end
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
        if touchConnection then touchConnection:Disconnect() end
        clearAllHighlights()
        destroyAutoJumpWindow()
        destroyAutoReviveWindow()
        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Content = 'Restores the slide and jump functions to their original behavior, stops every loop, clears esp, closes the auto jump/revive panels if open, then closes the menu.',
})

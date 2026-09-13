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
    ObjectTrimpMinSpeed = 20,
    WallrunJumpBoost = 1,
    EdgeTrimpEnabled = false,
    EdgeTrimpMinSpeed = 25,
    EdgeLookahead = 4,
    SpiderHopEnabled = false,
    TrickCooldown = 0.15,

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

local EventLog = { Sink = nil }
local function logEvent(...)
    if EventLog.Sink then pcall(EventLog.Sink, ...) end
end

-- minSpeedStuds gates the boost on how fast you were actually moving, in
-- real studs/s rather than the engine's internal units (x90), so a slider
-- reads in the same terms as the speed stat everywhere else
local function boostHorizontalVelocity(dataRegistry, multiplier, minSpeedStuds)
    local velocity = dataRegistry:Get("Velocity")
    if not velocity then return false end
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    local studs = horizontal.Magnitude / 90
    if studs < (minSpeedStuds or 0.01) then return false end
    local boosted = horizontal * multiplier
    dataRegistry:Set("Velocity", Vector3.new(boosted.X, velocity.Y, boosted.Z))
    return true, studs
end

-- same restore-on-unload contract as Slide; scoped by comparing the live
-- character model rather than a captured reference so it survives respawns.
-- the timestamp is recorded for EVERY local jump, not only boosted ones,
-- because object trimp below needs to know a jump happened at all
local lastJumpAt = -math.huge
local originalJump = MovementClass.Jump
MovementClass.Jump = function(self, ...)
    local isLocal = self.Character == LocalPlayer.Character
    -- read before the call, since the original Jump is what ends the wallrun
    local wallrunState = isLocal and (self.State == "WallrunLeft" or self.State == "WallrunRight")
    local a, b = originalJump(self, ...)
    if isLocal then
        lastJumpAt = os.clock()
        if Tune.JumpTrimpEnabled then
            local fired, studs = boostHorizontalVelocity(self.DataRegistry, Tune.JumpTrimpMultiplier)
            if fired then logEvent(("jump trimp %.2fx at %d studs/s"):format(Tune.JumpTrimpMultiplier, studs)) end
        end
        -- jumping off a wall natively adds WallrunDir * 90 * 30 to velocity;
        -- this tops that same kick up rather than replacing it, so a boost of
        -- 1 leaves the game's own number exactly as it was
        if wallrunState and Tune.WallrunJumpBoost > 1 then
            pcall(function()
                local direction = self.DataRegistry:Get("WallrunDir")
                if not direction then return end
                local extra = direction * 90 * 30 * (Tune.WallrunJumpBoost - 1)
                self.DataRegistry:Set("Velocity", self.DataRegistry:Get("Velocity") + extra)
                logEvent(("wallrun jump %.2fx"):format(Tune.WallrunJumpBoost))
            end)
        end
    end
    return a, b
end

-- the native Slide state only reads slope off workspace.Map.Parts (its own
-- raycast is whitelisted to exactly that), so a crate or prop never gets
-- ramp treatment no matter how it's shaped - that whitelist is what this
-- extends to everything else.
--
-- the catch: leaving the ground is leaving the ground, and a jump is the
-- most common way to do it, so this used to fire on every jump off a prop
-- and was just a worse duplicate of jump trimp. it now ignores any liftoff
-- within JUMP_EXCLUSION_WINDOW of a real jump, leaving only the case it was
-- ever meant for - running or being launched off an object without jumping.
-- the speed gate and cooldown stop the remaining edge cases (stepping off a
-- kerb at walking pace, or one ledge re-firing every few frames)
local MapPartsContainer
do
    local mapFolder = workspace:WaitForChild("Map", 10)
    MapPartsContainer = mapFolder and mapFolder:WaitForChild("Parts", 10)
end

local JUMP_EXCLUSION_WINDOW = 0.25
local OBJECT_TRIMP_COOLDOWN = 0.4

local lastGroundWasObject = false
local wasGrounded = false
local lastObjectTrimpAt = -math.huge

-- the handler below skips its own bookkeeping entirely while the feature is
-- off, so those two flags are whatever they were when it was last turned off.
-- Without clearing them, switching it back on mid-air could see a stale
-- "was grounded on an object" and fire a trimp that nothing actually caused
local function resetObjectTrimpState()
    lastGroundWasObject = false
    wasGrounded = false
    lastObjectTrimpAt = -math.huge
end

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
            local now = os.clock()
            local jumped = (now - lastJumpAt) < JUMP_EXCLUSION_WINDOW
            local cooling = (now - lastObjectTrimpAt) < OBJECT_TRIMP_COOLDOWN
            if not jumped and not cooling then
                local fired, studs = boostHorizontalVelocity(
                    character.DataRegistry, Tune.ObjectTrimpMultiplier, Tune.ObjectTrimpMinSpeed)
                if fired then
                    lastObjectTrimpAt = now
                    logEvent(("object trimp %.2fx at %d studs/s"):format(Tune.ObjectTrimpMultiplier, studs))
                end
            end
            lastGroundWasObject = false
        end

        wasGrounded = grounded
    end)
    if not ok then
        lastGroundWasObject = false
        wasGrounded = false
    end
end)

-- edge trimp and spider hop are both timing tricks rather than new mechanics:
-- neither adds anything the game doesn't already do, they just press jump on
-- the one frame that gets the most out of the game's own Jump. Which is why
-- both go through Movement:AttemptJump() - the exact call a real keypress
-- ends up at - rather than writing velocity directly
local lastTrickJumpAt = -math.huge

local function trickJump(movement, label)
    local now = os.clock()
    if (now - lastTrickJumpAt) < Tune.TrickCooldown then return false end
    lastTrickJumpAt = now
    movement:AttemptJump()
    logEvent(label)
    return true
end

local tricksConnection = RunService.Heartbeat:Connect(function()
    if not (Tune.EdgeTrimpEnabled or Tune.SpiderHopEnabled) then return end
    pcall(function()
        local character = CharacterService:GetLocalCharacter()
        if not character or not character.Movement then return end
        local model = character.Model
        local root = model and model.PrimaryPart
        if not root then return end
        local movement = character.Movement
        local registry = character.DataRegistry

        -- spider hop: a wallrun already ends in a jump that kicks you along
        -- the wall, so re-entering a wallrun and jumping again immediately
        -- chains those kicks up the same wall. Wallrun itself needs you
        -- airborne, uncrouched, not carrying and above 20 relative speed, so
        -- this only ever engages off a real run-up - it cannot make a wall
        -- climbable from a standstill
        if Tune.SpiderHopEnabled then
            local state = movement.State
            if state == "WallrunLeft" or state == "WallrunRight" then
                trickJump(movement, 'spider hop: chained off ' .. state)
                return
            end
        end

        -- edge trimp: the native trimp in Jump converts your run speed into
        -- forward speed, and it pays out most on the last frame you are still
        -- grounded. Rather than guessing that frame by feel, this looks a
        -- short way ahead along the direction you are actually moving and
        -- jumps once there is no longer ground under that point
        if Tune.EdgeTrimpEnabled then
            if registry:Get("Grounded") ~= true then return end
            local velocity = registry:Get("Velocity")
            if not velocity then return end
            local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
            local studs = horizontal.Magnitude / 90
            if studs < Tune.EdgeTrimpMinSpeed then return end

            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { model }
            -- the lookahead scales with how fast you are going, so the jump
            -- lands at the same distance from the edge at any speed
            local ahead = root.Position + horizontal.Unit * (Tune.EdgeLookahead * math.max(studs / 40, 0.5))
            if not workspace:Raycast(ahead, Vector3.new(0, -6, 0), params) then
                trickJump(movement, ('edge trimp at %d studs/s'):format(studs))
            end
        end
    end)
end)

local OriginalLighting = {
    Brightness = Lighting.Brightness,
    ExposureCompensation = Lighting.ExposureCompensation,
    ClockTime = Lighting.ClockTime,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    FogEnd = Lighting.FogEnd,
    FogStart = Lighting.FogStart,
    GlobalShadows = Lighting.GlobalShadows,
}

local function restoreLighting()
    Lighting.Brightness = OriginalLighting.Brightness
    Lighting.ExposureCompensation = OriginalLighting.ExposureCompensation
    Lighting.ClockTime = OriginalLighting.ClockTime
    Lighting.Ambient = OriginalLighting.Ambient
    Lighting.OutdoorAmbient = OriginalLighting.OutdoorAmbient
    Lighting.FogEnd = OriginalLighting.FogEnd
    Lighting.FogStart = OriginalLighting.FogStart
    Lighting.GlobalShadows = OriginalLighting.GlobalShadows
    -- the no-fog toggle stashes each Atmosphere's own density on the instance
    -- itself, so this restores whatever was there rather than a guessed value
    for _, item in ipairs(Lighting:GetChildren()) do
        if item:IsA("Atmosphere") then
            local stored = item:GetAttribute("EvadeDensity")
            if stored then
                item.Density = stored
                item:SetAttribute("EvadeDensity", nil)
            end
        end
    end
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
-- shown at the bottom of the tab in its own collapsed section rather than
-- here: it is a read-once explainer, and sitting between the two stat blocks
-- it pushed everything actually worth watching off the first screen
local ReadingParagraph = {
    Title = 'reading this',
    Content = 'the two "(live)" values read straight from the character\'s real movement table, not from this menu\'s own copy - if a slider below is moved and the matching live value here does not change within about half a second, the setting genuinely is not applying. if it does change and the game still feels the same, the setting is applying but its effect is naturally subtle (air acceleration only changes how fast you reach your air speed cap, not the cap itself, and air strafe acceleration only kicks in when moving purely sideways with no forward/back input at all)',
}

LiveSection:Divider()

LiveSection:Stats({
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

local SpeedSection = MovementTab:CreateSection('speed & sprint')
local BaseSpeedSlider, SprintCapSlider, JumpHeightSlider, JumpMultSlider

SpeedSection:Segmented({
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

SpeedSection:Divider('by hand')

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

local JumpSection = MovementTab:CreateSection('jump')

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
    Description = 'the native trimp - how much of your run/slide speed converts into a jump forward when you jump while looking where you are moving',
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
    Title = 'bunny hop',
    Description = 'off natively - lets jumping repeatedly skip the run-up friction that normally caps your speed',
    Flag = 'evade_bhop',
    Default = false,
    Callback = function(state) Tune.BhopEnabled = state end,
})

local TrimpSection = MovementTab:CreateSection({ Title = 'trimp', Collapsible = true })

TrimpSection:Toggle({
    Title = 'jump trimp',
    Description = 'multiplies the horizontal speed a jump already leaves you with, stacked on top of the native jump speed multiplier',
    Flag = 'evade_jump_trimp_enabled',
    Default = false,
    Mini = true,
    Callback = function(state) Tune.JumpTrimpEnabled = state end,
})

TrimpSection:Toggle({
    Title = 'object trimp',
    Description = 'same boost, but for leaving an object rather than jumping',
    Flag = 'evade_object_trimp_enabled',
    Default = false,
    Mini = true,
    Callback = function(state)
        Tune.ObjectTrimpEnabled = state
        resetObjectTrimpState()
    end,
})

TrimpSection:Divider('jump')

TrimpSection:Slider({
    Title = 'jump trimp multiplier',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_jump_trimp_mult',
    Callback = function(value) Tune.JumpTrimpMultiplier = value end,
})

TrimpSection:Divider('object')

TrimpSection:Slider({
    Title = 'object trimp multiplier',
    Description = 'fires when you leave a surface that is not part of workspace.Map.Parts - the exact whitelist the native ramp slide uses, which is why props and crates never get ramp treatment on their own. jumps are deliberately excluded: leaving the ground by jumping off a crate is what jump trimp above is for, and firing on both made this a worse duplicate of it. what is left is the case it was meant for - running or being launched off an object without jumping',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_object_trimp_mult',
    Callback = function(value) Tune.ObjectTrimpMultiplier = value end,
})

TrimpSection:Slider({
    Title = 'object trimp min speed',
    Description = 'how fast you have to actually be moving for an object trimp to fire at all - stops stepping off a kerb at walking pace from counting',
    Min = 0,
    Max = 80,
    Increment = 1,
    Default = 20,
    Suffix = ' studs/s',
    Flag = 'evade_object_trimp_min_speed',
    Callback = function(value) Tune.ObjectTrimpMinSpeed = value end,
})

-- Character.State.Update applies PrimaryPart.Size = RootSizeGoal * Size every
-- time a state change sets a new RootSizeGoal, where Size is a plain number on
-- the character. Writing that number is therefore the game's own scaling hook
-- rather than a fight with it - setting PrimaryPart.Size directly just gets
-- overwritten on the next state change.
--
-- worth being precise about what this is and is not: BasePart.Size does not
-- replicate from a client, so the server's copy of your hitbox is unchanged.
-- It moves your LOCAL collision box, which is real for movement - your own
-- client simulates your movement, and the resulting CFrame is what replicates
-- - but it does nothing about damage, which the server decides against its
-- own copy.
local RootSizeMultiplier = 1

local function applyRootSize(multiplier)
    RootSizeMultiplier = multiplier
    pcall(function()
        local character = CharacterService:GetLocalCharacter()
        if not character then return end
        -- never write it if the game isn't holding a number there: the
        -- multiply happens inside the game's own Update, so a wrong type
        -- would error in there and take the whole movement step with it
        if type(character.Size) ~= "number" then return end
        character.Size = multiplier
        -- Size is only read when a state change queues a resize, so queue one
        -- rather than waiting for the next jump or slide to apply it
        if character.RootSizeGoal == nil then
            character.RootSizeGoal = Vector3.new(2, 4, 2)
        end
    end)
end

-- reapply after a respawn, since the character object is rebuilt with the
-- game's own default
task.spawn(function()
    while not Unloading do
        pcall(function()
            if RootSizeMultiplier ~= 1 then
                local character = CharacterService:GetLocalCharacter()
                if character and type(character.Size) == "number"
                    and math.abs(character.Size - RootSizeMultiplier) > 0.001 then
                    applyRootSize(RootSizeMultiplier)
                end
            end
        end)
        task.wait(1)
    end
end)

local TricksSection = MovementTab:CreateSection({ Title = 'tricks', Collapsible = true })

TricksSection:Toggle({
    Title = 'edge trimp',
    Description = 'jumps for you on the last frame before you run off a ledge. the game\'s own trimp converts run speed into forward speed on a jump and pays out most right at an edge - this just hits that frame every time instead of by feel. it presses jump through the same call a real keypress does, so nothing here happens that you could not do by hand',
    Flag = 'evade_edge_trimp',
    Default = false,
    Mini = true,
    Callback = function(state) Tune.EdgeTrimpEnabled = state end,
})

TricksSection:Toggle({
    Title = 'spider hop',
    Description = 'jumps the instant you enter a wallrun, which chains the wall kick over and over up the same wall. wallrun needs you airborne, uncrouched, not carrying and over 20 relative speed, so this still needs a real run-up to start - it will not climb a wall from standing',
    Flag = 'evade_spider_hop',
    Default = false,
    Mini = true,
    Callback = function(state) Tune.SpiderHopEnabled = state end,
})

TricksSection:Divider('edge')

TricksSection:Slider({
    Title = 'edge trimp min speed',
    Description = 'below this you are not moving fast enough for a trimp to be worth anything, so it stays out of the way while walking around',
    Min = 0,
    Max = 80,
    Increment = 1,
    Default = 25,
    Suffix = ' studs/s',
    Flag = 'evade_edge_trimp_min_speed',
    Callback = function(value) Tune.EdgeTrimpMinSpeed = value end,
})

TricksSection:Slider({
    Title = 'edge lookahead',
    Description = 'how far ahead of you it checks for missing ground. scaled by your speed so the jump fires the same distance from the edge whether you are running or sliding - raise it if it jumps too late, lower it if it jumps at nothing',
    Min = 1,
    Max = 12,
    Increment = 0.5,
    Default = 4,
    Suffix = ' studs',
    Flag = 'evade_edge_lookahead',
    Callback = function(value) Tune.EdgeLookahead = value end,
})

TricksSection:Divider('hitbox')

TricksSection:Slider({
    Title = 'root size',
    Description = 'scales your own collision box through the game\'s own Character.Size, which its state code multiplies the per-state root size by. This is LOCAL ONLY - part sizes do not replicate from a client, so the server\'s copy of your hitbox is untouched and this does nothing about nextbot damage, which the server decides. What it does change is your own collision against the map, since your client simulates your movement: smaller fits through tighter gaps, larger catches on more. Expect it to feel odd away from 1x',
    Min = 0.3,
    Max = 2,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_root_size',
    Callback = function(value) applyRootSize(value) end,
})

TricksSection:Divider('shared')

TricksSection:Slider({
    Title = 'trick cooldown',
    Description = 'minimum gap between two automatic jumps from either trick, so one ledge or one wall cannot fire a jump every single frame',
    Min = 0.05,
    Max = 1,
    Increment = 0.05,
    Default = 0.15,
    Suffix = ' s',
    Flag = 'evade_trick_cooldown',
    Callback = function(value) Tune.TrickCooldown = value end,
})

local SlideSection = MovementTab:CreateSection({ Title = 'slide', Collapsible = true })

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

local GroundSection = MovementTab:CreateSection({ Title = 'ground control', Collapsible = true, Collapsed = true })

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

local AirSection = MovementTab:CreateSection({ Title = 'air control', Collapsible = true, Collapsed = true })

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

AirSection:Divider('wallrun')

AirSection:Slider({
    Title = 'wallrun jump boost',
    Description = 'jumping off a wallrun natively adds a fixed kick along the wall direction. this scales that kick - 1x is the game\'s own number untouched. wallrunning itself needs you to be airborne, not crouching, not carrying, and moving faster than 20 relative speed, which is why it only ever triggers off a decent run-up',
    Min = 1,
    Max = 4,
    Increment = 0.05,
    Default = 1,
    Suffix = 'x',
    Flag = 'evade_wallrun_jump_boost',
    Callback = function(value) Tune.WallrunJumpBoost = value end,
})

MovementTab:CreateSection({ Title = 'notes', Collapsible = true, Collapsed = true })
    :Paragraph(ReadingParagraph)

local EspTune = {
    Nextbot = false,
    Downed = false,
    Players = false,
    NextbotColor = Color3.fromRGB(255, 60, 60),
    DownedColor = Color3.fromRGB(255, 210, 60),
    PlayersColor = Color3.fromRGB(80, 170, 255),
    FillTransparency = 0.5,
    OutlineTransparency = 0,
    MaxDistance = 250,
    DistanceText = false,
    NameText = false,
    ThroughWalls = true,
    Tracers = false,
    Refresh = 0.5,
}

local espHighlights = {}
local espLabels = {}

local function setHighlight(model, enabled, color)
    local highlight = espHighlights[model]
    if enabled then
        if not highlight then
            highlight = Instance.new("Highlight")
            highlight.Parent = model
            espHighlights[model] = highlight
        end
        -- AlwaysOnTop draws the highlight over whatever is in front of it;
        -- Occluded only draws it when the model is actually visible, which is
        -- what "see through walls: off" should mean
        highlight.DepthMode = EspTune.ThroughWalls
            and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded
        highlight.OutlineTransparency = EspTune.OutlineTransparency
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

-- tracers are the one esp feature that can't be done with a Highlight, since
-- they're a screen-space line rather than something parented to the model.
-- Drawing is an executor extension rather than a Roblox API, so everything
-- here is guarded - if the executor doesn't provide it the tracer toggle just
-- reports that instead of erroring the whole esp loop
local okDrawing, DrawingApi = pcall(function() return Drawing end)
if not okDrawing then DrawingApi = nil end
local espTracers = {}
local espTargets = {}

local function setTracer(model, enabled, color)
    local tracer = espTracers[model]
    if enabled and DrawingApi then
        if not tracer then
            local ok, line = pcall(function() return DrawingApi.new("Line") end)
            if not ok or not line then return end
            line.Thickness = 1
            line.Transparency = 1
            tracer = line
            espTracers[model] = tracer
        end
        tracer.Color = color
    elseif tracer then
        pcall(function() tracer:Remove() end)
        espTracers[model] = nil
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
    for model in pairs(espTracers) do
        setTracer(model, false)
    end
    table.clear(espTargets)
end

-- separate from the scan loop below on purpose: the scan runs a few times a
-- second (plenty for deciding what to highlight) but a tracer has to follow
-- the target every frame or it visibly lags behind it
local tracerConnection = RunService.RenderStepped:Connect(function()
    if not next(espTracers) then return end
    pcall(function()
        local camera = workspace.CurrentCamera
        if not camera then return end
        local origin = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
        for model, tracer in pairs(espTracers) do
            local root = model.PrimaryPart
            if EspTune.Tracers and root and root.Parent then
                local point, onScreen = camera:WorldToViewportPoint(root.Position)
                tracer.Visible = onScreen
                if onScreen then
                    tracer.From = origin
                    tracer.To = Vector2.new(point.X, point.Y)
                end
            else
                tracer.Visible = false
            end
        end
    end)
end)

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
                    setTracer(model, wantHighlight and EspTune.Tracers, color)
                    espTargets[model] = wantHighlight and distance or nil
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
            for model in pairs(espTracers) do
                if not tracked[model] then
                    setTracer(model, false)
                    espTargets[model] = nil
                end
            end
        end)

        task.wait(EspTune.Refresh)
    end
end)

local VisualsTab = Window:CreateTab({ Title = 'visuals' })

-- every one of these is a real setting read straight out of the game's own
-- settings config (Shared.UserData.Settings.Config) and written back through
-- its own hook (ClientHooks.useSettings), which fires the same server remote
-- the in-game settings menu does. Held in one table rather than a local per
-- key so adding another confirmed setting doesn't cost a top-level local
local SettingDefaults = {}

local function getSettingDefault(key, fallback)
    local ok, value = pcall(function() return UseSettings.Get(key) end)
    local resolved = (ok and value ~= nil) and value or fallback
    SettingDefaults[key] = resolved
    return resolved
end

local function setSetting(key, value)
    pcall(function() UseSettings.SetSetting(key, value) end)
end

do
    local EspSection = VisualsTab:CreateSection('esp')

    -- each highlight toggle sits directly beside its own colour rather than
    -- all three toggles then all three colours, so a row reads as one thing
    EspSection:Toggle({
        Title = 'nextbot esp',
        Description = 'highlights every character on the Nextbot team',
        Flag = 'evade_esp_nextbot',
        Default = false,
        Mini = true,
        Callback = function(state) EspTune.Nextbot = state end,
    })

    EspSection:Colorpicker({
        Title = 'nextbot color',
        Default = EspTune.NextbotColor,
        Flag = 'evade_esp_nextbot_color',
        Mini = true,
        Callback = function(color) EspTune.NextbotColor = color end,
    })

    EspSection:Divider()

    EspSection:Toggle({
        Title = 'downed esp',
        Description = 'highlights any character currently downed, regardless of team - useful for spotting revive targets',
        Flag = 'evade_esp_downed',
        Default = false,
        Mini = true,
        Callback = function(state) EspTune.Downed = state end,
    })

    EspSection:Colorpicker({
        Title = 'downed color',
        Default = EspTune.DownedColor,
        Flag = 'evade_esp_downed_color',
        Mini = true,
        Callback = function(color) EspTune.DownedColor = color end,
    })

    EspSection:Divider()

    EspSection:Toggle({
        Title = 'player esp',
        Description = 'highlights every other non-nextbot character',
        Flag = 'evade_esp_players',
        Default = false,
        Mini = true,
        Callback = function(state) EspTune.Players = state end,
    })

    EspSection:Colorpicker({
        Title = 'player color',
        Default = EspTune.PlayersColor,
        Flag = 'evade_esp_players_color',
        Mini = true,
        Callback = function(color) EspTune.PlayersColor = color end,
    })

    local EspSettingsSection = VisualsTab:CreateSection({ Title = 'esp settings', Collapsible = true })

    EspSettingsSection:Toggle({
        Title = 'see through walls',
        Description = 'off makes a highlight only draw when the target is actually in line of sight, which is a far better read of whether something can really see you',
        Flag = 'evade_esp_through_walls',
        Default = EspTune.ThroughWalls,
        Mini = true,
        Callback = function(state) EspTune.ThroughWalls = state end,
    })

    EspSettingsSection:Toggle({
        Title = 'tracers',
        Description = 'draws a line from the bottom of your screen to each highlighted target - needs an executor that provides the Drawing api',
        Flag = 'evade_esp_tracers',
        Default = false,
        Mini = true,
        Callback = function(state)
            EspTune.Tracers = state
            if state and not DrawingApi then
                Onyx:Notify({
                    Title = 'tracers',
                    Content = 'this executor has no Drawing api, so tracers cannot be drawn. Highlights still work.',
                    Type = 'warning',
                    Duration = 6,
                })
            end
        end,
    })

    EspSettingsSection:Toggle({
        Title = 'distance text',
        Description = 'shows the live distance above anything currently highlighted',
        Flag = 'evade_esp_distance_text',
        Default = false,
        Mini = true,
        Callback = function(state) EspTune.DistanceText = state end,
    })

    EspSettingsSection:Toggle({
        Title = 'name text',
        Description = 'shows the player name (or the nextbot model name) above anything currently highlighted',
        Flag = 'evade_esp_name_text',
        Default = false,
        Mini = true,
        Callback = function(state) EspTune.NameText = state end,
    })

    EspSettingsSection:Divider('appearance')

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
        Title = 'outline transparency',
        Min = 0,
        Max = 1,
        Increment = 0.05,
        Default = EspTune.OutlineTransparency,
        Flag = 'evade_esp_outline_transparency',
        Callback = function(value) EspTune.OutlineTransparency = value end,
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

    EspSettingsSection:Slider({
        Title = 'refresh rate',
        Description = 'how often the scan re-decides what to highlight. Lower reacts faster to a nextbot spawning or someone going down, at the cost of running more often',
        Min = 0.1,
        Max = 2,
        Increment = 0.1,
        Default = EspTune.Refresh,
        Suffix = 's',
        Flag = 'evade_esp_refresh',
        Callback = function(value) EspTune.Refresh = value end,
    })
end

local nextbotVignetteDefault = getSettingDefault("NextbotVignette", true)

do
    local ComfortSection = VisualsTab:CreateSection('comfort')

    ComfortSection:Slider({
        Title = 'field of view',
        Min = 70,
        Max = 100,
        Increment = 1,
        Default = getSettingDefault("FOV", 70),
        Flag = 'evade_setting_fov',
        Callback = function(value) setSetting("FOV", value) end,
    })

    ComfortSection:Divider('toggles')

    -- there is no separate camera-shake setting - nextbot camera shake and the
    -- vignette darkening are driven by the same Enabled flag on the same Fear
    -- service, so this one toggle already covers both
    ComfortSection:Toggle({
        Title = 'nextbot vignette',
        Description = 'the game\'s own accessibility setting for the darkened-vision-and-shake effect a nearby nextbot causes',
        Flag = 'evade_nextbot_vignette',
        Default = nextbotVignetteDefault,
        Mini = true,
        Callback = function(state) setSetting("NextbotVignette", state) end,
    })

    ComfortSection:Toggle({
        Title = 'view bob',
        Flag = 'evade_setting_viewbob',
        Default = getSettingDefault("Viewbob", true),
        Mini = true,
        Callback = function(state) setSetting("Viewbob", state) end,
    })

    ComfortSection:Toggle({
        Title = 'low graphics',
        Flag = 'evade_setting_low_graphics',
        Default = getSettingDefault("LowGraphics", false),
        Mini = true,
        Callback = function(state) setSetting("LowGraphics", state) end,
    })

    ComfortSection:Toggle({
        Title = 'map shadows',
        Flag = 'evade_setting_map_shadows',
        Default = getSettingDefault("MapShadows", true),
        Mini = true,
        Callback = function(state) setSetting("MapShadows", state) end,
    })

    ComfortSection:Toggle({
        Title = 'scroll to change pov',
        Flag = 'evade_setting_pov_scroll',
        Default = getSettingDefault("POVScroll", true),
        Mini = true,
        Callback = function(state) setSetting("POVScroll", state) end,
    })

    ComfortSection:Toggle({
        Title = 'sprint viewmodel',
        Description = 'the arms-down sprint pose. Off keeps the normal viewmodel while sprinting, which leaves more of the screen readable',
        Flag = 'evade_setting_sprint_viewmodel',
        Default = getSettingDefault("SprintViewmodel", true),
        Mini = true,
        Callback = function(state) setSetting("SprintViewmodel", state) end,
    })

    ComfortSection:Toggle({
        Title = 'legacy camera',
        Flag = 'evade_setting_legacy_camera',
        Default = getSettingDefault("LegacyCamera", false),
        Mini = true,
        Callback = function(state) setSetting("LegacyCamera", state) end,
    })

    ComfortSection:Toggle({
        Title = 'r15 characters',
        Flag = 'evade_setting_r15',
        Default = getSettingDefault("R15Enabled", true),
        Mini = true,
        Callback = function(state) setSetting("R15Enabled", state) end,
    })

    local GameplaySection = VisualsTab:CreateSection({ Title = 'gameplay settings', Collapsible = true, Collapsed = true })

    GameplaySection:Toggle({
        Title = 'ragdolls',
        Description = 'the ragdoll that plays when someone goes down. Off is noticeably lighter on a busy round',
        Flag = 'evade_setting_ragdolls',
        Default = getSettingDefault("Ragdolls", true),
        Mini = true,
        Callback = function(state) setSetting("Ragdolls", state) end,
    })

    GameplaySection:Toggle({
        Title = 'animated tags',
        Flag = 'evade_setting_animated_tags',
        Default = getSettingDefault("AnimatedTags", true),
        Mini = true,
        Callback = function(state) setSetting("AnimatedTags", state) end,
    })

    GameplaySection:Toggle({
        Title = 'can be carried',
        Description = 'the game\'s own opt-out for other players picking you up when you are down',
        Flag = 'evade_setting_can_be_carried',
        Default = getSettingDefault("CanBeCarried", true),
        Mini = true,
        Callback = function(state) setSetting("CanBeCarried", state) end,
    })

    local AudioSection = VisualsTab:CreateSection({ Title = 'audio', Collapsible = true, Collapsed = true })

    -- all seven volume keys the settings config actually defines, each a
    -- number 0-100 defaulting to 100
    local volumes = {
        { Key = 'GameMusicVolume', Title = 'game music', Flag = 'evade_volume_game_music' },
        { Key = 'LobbyMusicVolume', Title = 'lobby music', Flag = 'evade_volume_lobby_music' },
        { Key = 'NextbotVolume', Title = 'nextbots', Flag = 'evade_volume_nextbot' },
        { Key = 'BoomboxVolume', Title = 'boomboxes', Flag = 'evade_volume_boombox' },
        { Key = 'EmoteVolume', Title = 'emotes', Flag = 'evade_volume_emote' },
        { Key = 'CarryVolume', Title = 'carrying', Flag = 'evade_volume_carry' },
        { Key = 'VoiceChatVolume', Title = 'voice chat', Flag = 'evade_volume_voice_chat' },
    }

    for _, entry in ipairs(volumes) do
        AudioSection:Slider({
            Title = entry.Title,
            Min = 0,
            Max = 100,
            Increment = 1,
            Default = getSettingDefault(entry.Key, 100),
            Suffix = '%',
            Flag = entry.Flag,
            Callback = function(value) setSetting(entry.Key, value) end,
        })
    end
end

local FullbrightEnabled = false
local setFullbright

do
    local LightingSection = VisualsTab:CreateSection('lighting')
    local BrightnessSlider, ExposureSlider, ClockTimeSlider

    -- the two one-click switches first, since those are what actually gets
    -- used mid-round; the by-hand sliders sit under a divider below them
    function setFullbright(state)
        FullbrightEnabled = state
        if state then
            Lighting.Brightness = 5
            Lighting.ExposureCompensation = 1
            Lighting.ClockTime = 14
            Lighting.Ambient = Color3.fromRGB(150, 150, 150)
            Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
            Lighting.GlobalShadows = false
        else
            Lighting.Brightness = BrightnessSlider:Get()
            Lighting.ExposureCompensation = ExposureSlider:Get()
            Lighting.ClockTime = ClockTimeSlider:Get()
            Lighting.Ambient = OriginalLighting.Ambient
            Lighting.OutdoorAmbient = OriginalLighting.OutdoorAmbient
            Lighting.GlobalShadows = OriginalLighting.GlobalShadows
        end
    end

    LightingSection:Toggle({
        Title = 'fullbright',
        Description = 'cranks brightness, exposure and ambient light to a flat maximum, drops shadows and locks the time to midday, overriding the sliders below while on - the fastest way to just see everything regardless of round or map',
        Flag = 'evade_fullbright',
        Default = false,
        Mini = true,
        Callback = function(state) setFullbright(state) end,
    })

    LightingSection:Toggle({
        Title = 'no fog',
        Description = 'pushes the fog wall out past the far end of any map - some maps and special rounds lean on fog hard enough that you cannot see a nextbot until it is already on you',
        Flag = 'evade_no_fog',
        Default = false,
        Mini = true,
        Callback = function(state)
            if state then
                Lighting.FogStart = 0
                Lighting.FogEnd = 100000
            else
                Lighting.FogStart = OriginalLighting.FogStart
                Lighting.FogEnd = OriginalLighting.FogEnd
            end
            for _, item in ipairs(Lighting:GetChildren()) do
                if item:IsA("Atmosphere") then
                    if state then
                        if item:GetAttribute("EvadeDensity") == nil then
                            item:SetAttribute("EvadeDensity", item.Density)
                        end
                        item.Density = 0
                    else
                        local stored = item:GetAttribute("EvadeDensity")
                        if stored then item.Density = stored end
                    end
                end
            end
        end,
    })

    LightingSection:Divider('by hand')

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
end

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

-- the previous version of this was built on a wrong reading of the game and
-- could never have worked. It called ToolProfile:KeyPhraseUsed with
-- Key = "Interact", on the assumption that reviving and carrying a downed
-- teammate both resolve out of a tool task. They do not. Neither one goes
-- through ToolProfile at all:
--
--   Services.Asset.InteractionService.InteractionTypes defines a "Revive"
--   interaction type covering downed players, with Distance = 8 and two
--   separate interactions on it -
--     Revive: Keybind "Interact" (E), Length = "ReviveLength"
--     Carry:  Keybind "Melee"    (Q), Cooldown = 1, no Length
--
-- so carry is Q, not E, and the two are genuinely different actions rather
-- than one mechanism the game resolves between. (Tool.Tasks.Types.Revive is
-- a third thing again - the revive consumable, which checks inventory
-- ownership server-side. That is the one that lives on ToolProfile.)
--
-- the entry point that actually drives both is InteractionService:KeyUsed,
-- which reads .Active / .ActiveChildren - the interactable the service has
-- already picked - and fires the matching interaction. Revive, having a
-- Length, only needs ONE press: KeyUsed records a start time and the
-- service's own Heartbeat calls Activate once ReviveLength has elapsed. So
-- there is no hold to simulate and no release to time, which is the whole
-- press/release/hysteresis machine that used to be here.
local InteractionService = require(waitPath(ReplicatedStorage, "Services", "Asset", "InteractionService"))
local InteractionTypes = require(waitPath(ReplicatedStorage, "Services", "Asset", "InteractionService", "InteractionTypes"))

-- resolves an interaction by NAME against whatever the service currently has
-- active, and hands back the keybind that interaction is really bound to
-- rather than assuming one. ActiveChildren is already filtered by the
-- service for that target's own requirements - CanBeCarried, equipped tool,
-- and so on - so anything it lists is genuinely available right now
local function findActiveInteraction(name)
    local active = InteractionService.Active
    local children = InteractionService.ActiveChildren
    if not (active and children) then return nil end
    local typeInfo = InteractionTypes[active.Type]
    local list = typeInfo and typeInfo.Interactions
    if not list then return nil end
    for _, index in ipairs(children) do
        local entry = list[index]
        if entry and entry.Name == name then
            return entry, active
        end
    end
    return nil
end

local function activeDistance(active)
    local localCharacter = CharacterService:GetLocalCharacter()
    local root = localCharacter and localCharacter.Model and localCharacter.Model.PrimaryPart
    local asset = active and active.Asset
    if not (root and asset and asset.PrimaryPart) then return nil end
    return (asset.PrimaryPart.Position - root.Position).Magnitude
end

-- both automations are the same shape: watch for the named interaction to
-- become available, then press its own key once. Repeats are harmless - a
-- revive already in progress is guarded by the service's own Started flag,
-- and carry carries a 1 second cooldown the service enforces itself
local function createInteractionAutomation(panelTitle, interactionName, defaultRange)
    local automation = {
        Panel = nil,
        Element = nil,
        Active = false,
        Range = defaultRange,
        SuppressPanelSync = false,
    }

    -- same panel-persistence contract as auto jump: turning the feature off
    -- FROM THE PANEL must never remove the panel, only the main toggle does
    local function setActive(state, fromPanel)
        automation.Active = state

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

    task.spawn(function()
        while not Unloading do
            pcall(function()
                if not automation.Active then return end
                local entry, active = findActiveInteraction(interactionName)
                if not entry then return end
                -- the service's own range is 8 studs and this cannot extend
                -- it, only tighten it, so a lower slider just makes the
                -- automation more conservative than pressing the key yourself
                local distance = activeDistance(active)
                if distance and distance > automation.Range then return end
                InteractionService:KeyUsed({ Keybind = entry.Keybind, Down = true })
                logEvent(('%s: pressed %s at %d studs'):format(
                    panelTitle, tostring(entry.KeybindName or entry.Keybind), distance or 0))
            end)
            task.wait(0.15)
        end
    end)

    return automation
end

local AutoRevive = createInteractionAutomation('auto revive', 'Revive', 8)
local AutoCarry = createInteractionAutomation('auto carry', 'Carry', 8)

local ExtraTab = Window:CreateTab({ Title = 'extra' })

local function doUnstuck()
    pcall(function()
        local character = CharacterService:GetLocalCharacter()
        local root = character and character.Model and character.Model.PrimaryPart
        if not root then return end
        root.CFrame = root.CFrame + Vector3.new(0, 6, 0)
        root.AssemblyLinearVelocity = Vector3.new()
        if character.DataRegistry then
            character.DataRegistry:Set("Velocity", Vector3.new())
        end
        logEvent('unstuck')
    end)
end

do
    -- each automation now reads as its own block - the switch, then the range
    -- or interval that switch actually uses, then a rule off to the next one.
    -- Previously all three switches ran together above all three sliders,
    -- which made it easy to drag the wrong slider
    -- this is the readout that makes the two automations below debuggable at
    -- all: they can only ever fire on what InteractionService has already
    -- picked, so if 'offer' stays none while standing over a downed teammate,
    -- the game is not offering the interaction and no amount of retrying will
    -- change that
    local InteractSection = ExtraTab:CreateSection('interact target')

    InteractSection:Stats({
        Columns = 2,
        Items = {
            { Label = 'type', Value = function()
                local active = InteractionService.Active
                return (active and active.Type) and tostring(active.Type) or 'none'
            end },
            { Label = 'distance', Value = function()
                local distance = activeDistance(InteractionService.Active)
                return distance and (('%.1f studs'):format(distance)) or '-'
            end },
            { Label = 'offers', Value = function()
                local active = InteractionService.Active
                local children = InteractionService.ActiveChildren
                if not (active and children) then return 'none' end
                local typeInfo = InteractionTypes[active.Type]
                local list = typeInfo and typeInfo.Interactions
                if not list then return 'none' end
                local names = {}
                for _, index in ipairs(children) do
                    local entry = list[index]
                    if entry then
                        table.insert(names, ('%s (%s)'):format(
                            tostring(entry.Name), tostring(entry.KeybindName or entry.Keybind)))
                    end
                end
                return #names > 0 and table.concat(names, ', ') or 'none'
            end },
        },
    })

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

    AutoSection:Divider()

    AutoRevive.Element = AutoSection:Toggle({
        Title = 'auto revive',
        Description = 'presses E on a downed teammate the moment the game itself offers the revive, through InteractionService:KeyUsed - the exact call a real keypress ends at. Revive has a length, so one press is all it takes: the game finishes it on its own timer. also opens a small draggable pill with its own switch, synced with this one either direction',
        Flag = 'evade_auto_revive',
        Default = false,
        Callback = function(state) AutoRevive.SetActive(state, false) end,
    })

    AutoSection:Slider({
        Title = 'auto revive range',
        Description = 'the game offers the revive within 8 studs and nothing here can extend that - lower this only to make the automation more conservative than pressing E yourself',
        Min = 1,
        Max = 8,
        Increment = 1,
        Default = AutoRevive.Range,
        Suffix = ' studs',
        Flag = 'evade_auto_revive_range',
        Callback = function(value) AutoRevive.Range = value end,
    })

    AutoSection:Divider()

    AutoCarry.Element = AutoSection:Toggle({
        Title = 'auto carry',
        Description = 'carry is a separate interaction bound to Melee (Q), not Interact (E) - that mix-up is why this did nothing before. It presses Q the moment the game offers the carry, which it only does when the target has CanBeCarried on and you are not holding a grapple. The game enforces its own 1 second cooldown on it',
        Flag = 'evade_auto_carry',
        Default = false,
        Callback = function(state) AutoCarry.SetActive(state, false) end,
    })

    AutoSection:Slider({
        Title = 'auto carry range',
        Description = 'same 8 stud ceiling as revive, set by the game - this only tightens it',
        Min = 1,
        Max = 8,
        Increment = 1,
        Default = AutoCarry.Range,
        Suffix = ' studs',
        Flag = 'evade_auto_carry_range',
        Callback = function(value) AutoCarry.Range = value end,
    })
end

do
    -- Mode 'Always' fires the callback once per press rather than tracking its
    -- own on/off, so the real state stays owned by the toggle it drives -
    -- flipping through SetFlag keeps the menu switch, the floating pill and
    -- the key all showing the same thing
    local HotkeySection = ExtraTab:CreateSection({ Title = 'hotkeys', Collapsible = true })

    local function flipFlag(flag)
        return function()
            pcall(function() Onyx:SetFlag(flag, not Onyx:GetFlag(flag)) end)
        end
    end

    -- defaults picked against the game's own keybind list (Jump/Sprint/Crouch/
    -- Interact/Reload/Melee/Emote/Whistle/ThirdPerson/VIPMenu/Special/Menu/
    -- Deployables/Flashlight/Perk1-4/Queue) so none of these steal a real bind
    local binds = {
        { Title = 'toggle auto jump', Default = Enum.KeyCode.J, Flag = 'evade_key_auto_jump',
          Callback = flipFlag('evade_auto_jump') },
        { Title = 'toggle auto revive', Default = Enum.KeyCode.K, Flag = 'evade_key_auto_revive',
          Callback = flipFlag('evade_auto_revive') },
        { Title = 'toggle auto carry', Default = Enum.KeyCode.L, Flag = 'evade_key_auto_carry',
          Callback = flipFlag('evade_auto_carry') },
        { Title = 'toggle fullbright', Default = Enum.KeyCode.I, Flag = 'evade_key_fullbright',
          Callback = flipFlag('evade_fullbright') },
        { Title = 'unstuck', Default = Enum.KeyCode.U, Flag = 'evade_key_unstuck',
          Callback = doUnstuck },
    }

    for _, bind in ipairs(binds) do
        HotkeySection:Keybind({
            Title = bind.Title,
            Mode = 'Always',
            Default = bind.Default,
            Flag = bind.Flag,
            Mini = true,
            Callback = bind.Callback,
        })
    end

    HotkeySection:Divider()

    -- one key for all three highlight toggles at once, since in practice they
    -- get turned on and off together
    HotkeySection:Keybind({
        Title = 'toggle all esp',
        Description = 'flips nextbot, downed and player esp together, using whichever state the nextbot toggle is currently in',
        Mode = 'Always',
        Default = Enum.KeyCode.P,
        Flag = 'evade_key_esp',
        Callback = function()
            pcall(function()
                local target = not Onyx:GetFlag('evade_esp_nextbot')
                Onyx:SetFlag('evade_esp_nextbot', target)
                Onyx:SetFlag('evade_esp_downed', target)
                Onyx:SetFlag('evade_esp_players', target)
            end)
        end,
    })
end

do
    local UtilitySection = ExtraTab:CreateSection('utility')

    UtilitySection:Button({
        Title = 'unstuck',
        Description = 'nudges you straight up a few studs and zeroes your velocity - for when movement testing wedges you into geometry',
        Mini = true,
        Callback = doUnstuck,
    })

    UtilitySection:Button({
        Title = 'kill velocity',
        Description = 'zeroes your velocity in place without moving you - the quickest way to stop dead after a slide or trimp test without waiting out the deceleration',
        Mini = true,
        Callback = function()
            pcall(function()
                local character = CharacterService:GetLocalCharacter()
                if not character then return end
                if character.Model and character.Model.PrimaryPart then
                    character.Model.PrimaryPart.AssemblyLinearVelocity = Vector3.new()
                end
                if character.DataRegistry then
                    character.DataRegistry:Set("Velocity", Vector3.new())
                end
                logEvent('velocity zeroed')
            end)
        end,
    })

    UtilitySection:Button({
        Title = 'copy position',
        Description = 'copies your current position as a Vector3.new(...) line, for noting down where a particular jump or trimp was tested from',
        Mini = true,
        Callback = function()
            local character = CharacterService:GetLocalCharacter()
            local root = character and character.Model and character.Model.PrimaryPart
            if not root then return end
            local text = ('Vector3.new(%.1f, %.1f, %.1f)'):format(
                root.Position.X, root.Position.Y, root.Position.Z)
            if setclipboard then
                setclipboard(text)
                logEvent('copied ' .. text)
            else
                logEvent('no setclipboard in this executor - ' .. text)
            end
        end,
    })

    UtilitySection:Button({
        Title = 'copy job id',
        Description = 'copies this server\'s job id, for getting back into the same server after a rejoin',
        Mini = true,
        Callback = function()
            if setclipboard then
                setclipboard(tostring(game.JobId))
                logEvent('job id copied')
            else
                logEvent('no setclipboard in this executor')
            end
        end,
    })

    UtilitySection:Divider()

    UtilitySection:Button({
        Title = 'rejoin server',
        Description = 'teleports you back into this same place - this drops you out of the current round, so it asks first',
        Confirm = true,
        Callback = function()
            pcall(function()
                game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
            end)
        end,
    })
end

do
    -- a running record of what the script itself actually did, which is the
    -- only way to tell a trimp that fired from one that was skipped by the
    -- min-speed or cooldown gates
    local LogSection = ExtraTab:CreateSection({ Title = 'event log', Collapsible = true })

    local LogConsole = LogSection:Console({
        Title = 'events',
        Height = 130,
        MaxLines = 80,
        Timestamps = true,
    })

    -- the console carries its own COPY and CLEAR actions in its header, so
    -- there's nothing to add here beyond pointing logEvent at it
    EventLog.Sink = function(text)
        LogConsole:Log(tostring(text))
    end

    logEvent('loaded')
end

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
        evade_object_trimp_min_speed = 20,
        evade_wallrun_jump_boost = 1,
        evade_edge_trimp = false,
        evade_edge_trimp_min_speed = 25,
        evade_edge_lookahead = 4,
        evade_spider_hop = false,
        evade_trick_cooldown = 0.15,
        evade_root_size = 1,
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
        evade_esp_outline_transparency = 0,
        evade_esp_max_distance = 250,
        evade_esp_distance_text = false,
        evade_esp_name_text = false,
        evade_esp_through_walls = true,
        evade_esp_tracers = false,
        evade_esp_refresh = 0.5,

        evade_nextbot_vignette = SettingDefaults.NextbotVignette,
        evade_setting_fov = SettingDefaults.FOV,
        evade_setting_low_graphics = SettingDefaults.LowGraphics,
        evade_setting_map_shadows = SettingDefaults.MapShadows,
        evade_setting_viewbob = SettingDefaults.Viewbob,
        evade_setting_pov_scroll = SettingDefaults.POVScroll,
        evade_setting_sprint_viewmodel = SettingDefaults.SprintViewmodel,
        evade_setting_legacy_camera = SettingDefaults.LegacyCamera,
        evade_setting_r15 = SettingDefaults.R15Enabled,
        evade_setting_ragdolls = SettingDefaults.Ragdolls,
        evade_setting_animated_tags = SettingDefaults.AnimatedTags,
        evade_setting_can_be_carried = SettingDefaults.CanBeCarried,

        evade_volume_game_music = SettingDefaults.GameMusicVolume,
        evade_volume_lobby_music = SettingDefaults.LobbyMusicVolume,
        evade_volume_nextbot = SettingDefaults.NextbotVolume,
        evade_volume_boombox = SettingDefaults.BoomboxVolume,
        evade_volume_emote = SettingDefaults.EmoteVolume,
        evade_volume_carry = SettingDefaults.CarryVolume,
        evade_volume_voice_chat = SettingDefaults.VoiceChatVolume,

        evade_lighting_brightness = OriginalLighting.Brightness,
        evade_lighting_exposure = OriginalLighting.ExposureCompensation,
        evade_lighting_clocktime = OriginalLighting.ClockTime,
        evade_fullbright = false,
        evade_no_fog = false,

        evade_revive_override = false,
        evade_revive_time = 0,

        evade_auto_jump = false,
        evade_auto_jump_interval = 0.15,
        evade_auto_revive = false,
        evade_auto_revive_range = 8,
        evade_auto_carry = false,
        evade_auto_carry_range = 8,

        evade_key_auto_jump = Enum.KeyCode.J,
        evade_key_auto_revive = Enum.KeyCode.K,
        evade_key_auto_carry = Enum.KeyCode.L,
        evade_key_fullbright = Enum.KeyCode.I,
        evade_key_unstuck = Enum.KeyCode.U,
        evade_key_esp = Enum.KeyCode.P,
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
        tricksConnection:Disconnect()
        tracerConnection:Disconnect()
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

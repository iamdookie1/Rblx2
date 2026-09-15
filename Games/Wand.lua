--[[
    Wand -- tricks tab (place id 281489669)

    Grounded in a 20260914 script dump. What that dump actually confirms:
      - a Tool named "Wand" sits in every player's Backpack, with a Fire
        RemoteEvent and Ammo/ClipSize/Clips IntValues (25/25/10) - that is
        the game's own weapon, and none of it is touched here: not the
        tool, not Fire, not anything damage related. Everything below is
        local-only cosmetic weather, either built from scratch (rain,
        snow, fog) or by calling the game's own client-only weather
        modules directly (meteor shower, thunderstorm) instead of waiting
        on the server to trigger them for the whole server.
      - ReplicatedStorage.MeteorShowerClient.SpawnMeteor exposes
        :Spawn(data, summonTime, travelSpeed, assets), where data is
        {StartPos, EndPos} and assets is MeteorShowerClient.Assets (the
        Rock/Impact models it clones and animates) - calling it directly
        replays the real visual with a self-picked start/end instead of
        whatever the server would have sent
      - ReplicatedStorage.ThunderstormClient exposes :LightningStrike(p3)
        reading the strike position as p3.p2 - that field name is exactly
        what the decompile shows, not a typo introduced here
      - the rest of the dump is a berezaa's Tycoon Kit game (Potions and
        Staffs sold as tycoon buttons - Wind/Vine/Korblox/Lightning/Snow
        Staff, Wizard/Frost/Grow/Shrink/Chameleon/Ninja Potion, and so
        on). The game's real title was not confirmed anywhere in the
        dump - "wand" here just names the tool every player carries
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

-- both weather modules are plain siblings under ReplicatedStorage in the
-- live game; missing entirely (a future patch, a different build) is
-- handled per-section below instead of failing the whole script
local function tryRequire(instance)
    if not instance then return nil end
    local ok, result = pcall(require, instance)
    if ok then return result end
    return nil
end

local MeteorShowerRoot = ReplicatedStorage:FindFirstChild("MeteorShowerClient")
local SpawnMeteorModule = MeteorShowerRoot and tryRequire(MeteorShowerRoot:FindFirstChild("SpawnMeteor"))
local MeteorAssets = MeteorShowerRoot and MeteorShowerRoot:FindFirstChild("Assets")

local ThunderstormModule = tryRequire(ReplicatedStorage:FindFirstChild("ThunderstormClient"))

local Window = Onyx:CreateWindow({
    Title = 'wand',
    SubTitle = 'tricks',
    Folder = 'WandTricks',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(150, 100, 230),
})

local TricksTab = Window:CreateTab({ Title = 'tricks', Default = true })
local SessionTab = Window:CreateTab({ Title = 'session' })

--// shared weather rig -------------------------------------------------------

local VFXFolder = Instance.new("Folder")
VFXFolder.Name = "WandTricksVFX"
VFXFolder.Parent = workspace

-- Box shape draws its emission volume from the size of the part the
-- emitter's attachment sits on, so making that part wide and flat gives an
-- area of falling particles above whatever it's centered on, rather than a
-- single point
local function createWeatherEmitter(name)
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Size = Vector3.new(40, 1, 40)
    part.Parent = VFXFolder

    local attachment = Instance.new("Attachment")
    attachment.Parent = part

    local emitter = Instance.new("ParticleEmitter")
    emitter.Enabled = false
    emitter.EmissionDirection = Enum.NormalId.Bottom
    emitter.Shape = Enum.ParticleEmitterShape.Box
    emitter.Rotation = NumberRange.new(0)
    emitter.RotSpeed = NumberRange.new(0)
    emitter.LightEmission = 0
    emitter.Parent = attachment

    return { Part = part, Attachment = attachment, Emitter = emitter }
end

local Rain = createWeatherEmitter("Rain")
local Snow = createWeatherEmitter("Snow")

local RainState = {
    Enabled = false,
    Rate = 150,
    Speed = 45,
    Size = 0.3,
    Spread = 2,
    Area = 40,
    Height = 35,
    Color = Color3.fromRGB(160, 190, 255),
}

local SnowState = {
    Enabled = false,
    Rate = 120,
    Speed = 12,
    Size = 0.45,
    Spread = 20,
    Area = 45,
    Height = 30,
    Color = Color3.fromRGB(235, 240, 250),
}

-- lifetime is derived from height/speed rather than exposed as its own
-- slider, so a particle roughly reaches the ground before it despawns no
-- matter how those two are tuned
local function updateRainLifetime()
    Rain.Emitter.Lifetime = NumberRange.new(math.max(RainState.Height / math.max(RainState.Speed, 1), 0.1))
end

local function updateSnowLifetime()
    Snow.Emitter.Lifetime = NumberRange.new(math.max(SnowState.Height / math.max(SnowState.Speed, 1), 0.1))
end

local function applyRainVisuals()
    Rain.Emitter.Rate = RainState.Rate
    Rain.Emitter.Speed = NumberRange.new(RainState.Speed)
    Rain.Emitter.Size = NumberSequence.new(RainState.Size)
    Rain.Emitter.SpreadAngle = Vector2.new(RainState.Spread, RainState.Spread)
    Rain.Emitter.Color = ColorSequence.new(RainState.Color)
    Rain.Part.Size = Vector3.new(RainState.Area, 1, RainState.Area)
    updateRainLifetime()
end

local function applySnowVisuals()
    Snow.Emitter.Rate = SnowState.Rate
    Snow.Emitter.Speed = NumberRange.new(SnowState.Speed)
    Snow.Emitter.Size = NumberSequence.new(SnowState.Size)
    Snow.Emitter.SpreadAngle = Vector2.new(SnowState.Spread, SnowState.Spread)
    Snow.Emitter.Color = ColorSequence.new(SnowState.Color)
    Snow.Part.Size = Vector3.new(SnowState.Area, 1, SnowState.Area)
    updateSnowLifetime()
end

applyRainVisuals()
applySnowVisuals()

-- follows the player's feet on X/Z every frame so the rain/snow area is
-- always centered on wherever you actually are, instead of one fixed spot
local weatherConnection = RunService.Heartbeat:Connect(function()
    pcall(function()
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        if RainState.Enabled then
            Rain.Part.CFrame = CFrame.new(root.Position.X, root.Position.Y + RainState.Height, root.Position.Z)
        end
        if SnowState.Enabled then
            Snow.Part.CFrame = CFrame.new(root.Position.X, root.Position.Y + SnowState.Height, root.Position.Z)
        end
    end)
end)

--// fog ----------------------------------------------------------------------

local OriginalFog = {
    FogStart = Lighting.FogStart,
    FogEnd = Lighting.FogEnd,
    FogColor = Lighting.FogColor,
}

local FogState = {
    Enabled = false,
    Start = 0,
    End = 300,
    Color = Color3.fromRGB(200, 200, 210),
}

local function applyFog()
    if FogState.Enabled then
        Lighting.FogStart = FogState.Start
        Lighting.FogEnd = FogState.End
        Lighting.FogColor = FogState.Color
    else
        Lighting.FogStart = OriginalFog.FogStart
        Lighting.FogEnd = OriginalFog.FogEnd
        Lighting.FogColor = OriginalFog.FogColor
    end
end

--// meteor shower / thunderstorm ---------------------------------------------

local MeteorState = {
    Enabled = false,
    Interval = 10,
    Count = 5,
    Spacing = 1,
    TravelSpeed = 140,
    SummonTime = 1.25,
    Radius = 50,
    Height = 180,
}

local ThunderState = {
    Enabled = false,
    Interval = 5,
    Radius = 30,
}

-- fire-and-forget: the caller (a button or the interval loop below) does not
-- wait on this, so a burst still spans its own Count * Spacing seconds
-- without holding up anything else
local function spawnMeteorBurst()
    if not (SpawnMeteorModule and MeteorAssets) then return end
    task.spawn(function()
        pcall(function()
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root then return end

            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { character }

            for _ = 1, MeteorState.Count do
                if Unloading then break end
                local angle = math.random() * math.pi * 2
                local distance = math.random() * MeteorState.Radius
                local landX = root.Position.X + math.cos(angle) * distance
                local landZ = root.Position.Z + math.sin(angle) * distance
                local startPos = Vector3.new(landX, root.Position.Y + MeteorState.Height, landZ)
                local endPos = Vector3.new(landX, root.Position.Y - 20, landZ)

                -- same ground-snap the real handler does: without it a
                -- meteor's EndPos would float at exactly root.Y - 20
                -- regardless of the actual terrain height underneath it
                local result = workspace:Raycast(startPos, (endPos - startPos) * 2, params)
                local meteorData = { StartPos = startPos, EndPos = result and result.Position or endPos }

                SpawnMeteorModule:Spawn(meteorData, MeteorState.SummonTime, MeteorState.TravelSpeed, MeteorAssets)
                task.wait(MeteorState.Spacing)
            end
        end)
    end)
end

local function strikeLightning()
    if not ThunderstormModule then return end
    task.spawn(function()
        pcall(function()
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root then return end
            local angle = math.random() * math.pi * 2
            local distance = math.random() * ThunderState.Radius
            local strikePos = Vector3.new(
                root.Position.X + math.cos(angle) * distance,
                root.Position.Y,
                root.Position.Z + math.sin(angle) * distance)
            -- the field really is named p2 in the game's own code - see the
            -- header comment
            ThunderstormModule:LightningStrike({ p2 = strikePos })
        end)
    end)
end

task.spawn(function()
    while not Unloading do
        if MeteorState.Enabled then
            spawnMeteorBurst()
        end
        task.wait(MeteorState.Interval)
    end
end)

task.spawn(function()
    while not Unloading do
        if ThunderState.Enabled then
            strikeLightning()
        end
        task.wait(ThunderState.Interval)
    end
end)

--// ui ------------------------------------------------------------------------

TricksTab:Paragraph({
    Title = 'about these',
    Content = 'everything on this tab is local-only cosmetic weather. rain, snow and fog are built from scratch; meteor shower and thunderstorm call the game\'s own client visual modules directly instead of waiting for the server to trigger them for the whole server. none of it fires the Wand tool\'s own remote or touches anything damage related - nothing here sends the server anything at all.',
})

local RainSection = TricksTab:CreateSection('rain')

RainSection:Toggle({
    Title = 'rain',
    Flag = 'wand_rain_enabled',
    Default = false,
    Callback = function(state)
        RainState.Enabled = state
        Rain.Emitter.Enabled = state
    end,
})

RainSection:Slider({
    Title = 'rate',
    Min = 0,
    Max = 400,
    Increment = 5,
    Default = RainState.Rate,
    Suffix = '/s',
    Flag = 'wand_rain_rate',
    Callback = function(value) RainState.Rate = value; applyRainVisuals() end,
})

RainSection:Slider({
    Title = 'fall speed',
    Min = 10,
    Max = 120,
    Increment = 5,
    Default = RainState.Speed,
    Suffix = ' studs/s',
    Flag = 'wand_rain_speed',
    Callback = function(value) RainState.Speed = value; applyRainVisuals() end,
})

RainSection:Slider({
    Title = 'drop size',
    Min = 0.05,
    Max = 1.5,
    Increment = 0.05,
    Default = RainState.Size,
    Flag = 'wand_rain_size',
    Callback = function(value) RainState.Size = value; applyRainVisuals() end,
})

RainSection:Slider({
    Title = 'spread',
    Description = 'angles the fall away from straight down - 0 is a perfectly vertical rain',
    Min = 0,
    Max = 45,
    Increment = 1,
    Default = RainState.Spread,
    Suffix = ' deg',
    Flag = 'wand_rain_spread',
    Callback = function(value) RainState.Spread = value; applyRainVisuals() end,
})

RainSection:Slider({
    Title = 'area',
    Min = 10,
    Max = 120,
    Increment = 5,
    Default = RainState.Area,
    Suffix = ' studs',
    Flag = 'wand_rain_area',
    Callback = function(value) RainState.Area = value; applyRainVisuals() end,
})

RainSection:Slider({
    Title = 'height',
    Description = 'how far above you it spawns - raise this if drops are visibly popping into existence overhead',
    Min = 10,
    Max = 80,
    Increment = 5,
    Default = RainState.Height,
    Suffix = ' studs',
    Flag = 'wand_rain_height',
    Callback = function(value) RainState.Height = value; applyRainVisuals() end,
})

RainSection:Colorpicker({
    Title = 'color',
    Default = RainState.Color,
    Flag = 'wand_rain_color',
    Callback = function(color) RainState.Color = color; applyRainVisuals() end,
})

local SnowSection = TricksTab:CreateSection('snow')

SnowSection:Toggle({
    Title = 'snow',
    Flag = 'wand_snow_enabled',
    Default = false,
    Callback = function(state)
        SnowState.Enabled = state
        Snow.Emitter.Enabled = state
    end,
})

SnowSection:Slider({
    Title = 'rate',
    Min = 0,
    Max = 400,
    Increment = 5,
    Default = SnowState.Rate,
    Suffix = '/s',
    Flag = 'wand_snow_rate',
    Callback = function(value) SnowState.Rate = value; applySnowVisuals() end,
})

SnowSection:Slider({
    Title = 'fall speed',
    Min = 3,
    Max = 40,
    Increment = 1,
    Default = SnowState.Speed,
    Suffix = ' studs/s',
    Flag = 'wand_snow_speed',
    Callback = function(value) SnowState.Speed = value; applySnowVisuals() end,
})

SnowSection:Slider({
    Title = 'flake size',
    Min = 0.05,
    Max = 1.5,
    Increment = 0.05,
    Default = SnowState.Size,
    Flag = 'wand_snow_size',
    Callback = function(value) SnowState.Size = value; applySnowVisuals() end,
})

SnowSection:Slider({
    Title = 'spread',
    Description = 'how much flakes drift off straight-down - higher gives more of a swirling fall',
    Min = 0,
    Max = 60,
    Increment = 1,
    Default = SnowState.Spread,
    Suffix = ' deg',
    Flag = 'wand_snow_spread',
    Callback = function(value) SnowState.Spread = value; applySnowVisuals() end,
})

SnowSection:Slider({
    Title = 'area',
    Min = 10,
    Max = 120,
    Increment = 5,
    Default = SnowState.Area,
    Suffix = ' studs',
    Flag = 'wand_snow_area',
    Callback = function(value) SnowState.Area = value; applySnowVisuals() end,
})

SnowSection:Slider({
    Title = 'height',
    Min = 10,
    Max = 80,
    Increment = 5,
    Default = SnowState.Height,
    Suffix = ' studs',
    Flag = 'wand_snow_height',
    Callback = function(value) SnowState.Height = value; applySnowVisuals() end,
})

SnowSection:Colorpicker({
    Title = 'color',
    Default = SnowState.Color,
    Flag = 'wand_snow_color',
    Callback = function(color) SnowState.Color = color; applySnowVisuals() end,
})

local FogSection = TricksTab:CreateSection('fog')

FogSection:Toggle({
    Title = 'override fog',
    Flag = 'wand_fog_enabled',
    Default = false,
    Callback = function(state) FogState.Enabled = state; applyFog() end,
})

FogSection:Slider({
    Title = 'fog start',
    Min = 0,
    Max = 300,
    Increment = 10,
    Default = FogState.Start,
    Suffix = ' studs',
    Flag = 'wand_fog_start',
    Callback = function(value) FogState.Start = value; applyFog() end,
})

FogSection:Slider({
    Title = 'fog end',
    Min = 50,
    Max = 1500,
    Increment = 25,
    Default = FogState.End,
    Suffix = ' studs',
    Flag = 'wand_fog_end',
    Callback = function(value) FogState.End = value; applyFog() end,
})

FogSection:Colorpicker({
    Title = 'fog color',
    Default = FogState.Color,
    Flag = 'wand_fog_color',
    Callback = function(color) FogState.Color = color; applyFog() end,
})

local MeteorSection = TricksTab:CreateSection({ Title = 'meteor shower', Collapsible = true })

if not (SpawnMeteorModule and MeteorAssets) then
    MeteorSection:Paragraph({
        Title = 'unavailable',
        Content = 'ReplicatedStorage.MeteorShowerClient.SpawnMeteor was not found in this server, so this trick has nothing to call. The controls below are inert.',
    })
end

MeteorSection:Toggle({
    Title = 'continuous',
    Description = 'fires a burst on the interval below for as long as this is on',
    Flag = 'wand_meteor_enabled',
    Default = false,
    Callback = function(state) MeteorState.Enabled = state end,
})

MeteorSection:Button({
    Title = 'trigger burst now',
    Callback = spawnMeteorBurst,
})

MeteorSection:Divider()

MeteorSection:Slider({
    Title = 'burst interval',
    Min = 3,
    Max = 60,
    Increment = 1,
    Default = MeteorState.Interval,
    Suffix = ' s',
    Flag = 'wand_meteor_interval',
    Callback = function(value) MeteorState.Interval = value end,
})

MeteorSection:Slider({
    Title = 'meteors per burst',
    Min = 1,
    Max = 15,
    Increment = 1,
    Default = MeteorState.Count,
    Flag = 'wand_meteor_count',
    Callback = function(value) MeteorState.Count = value end,
})

MeteorSection:Slider({
    Title = 'spacing',
    Description = 'gap between each meteor within one burst - this is the game\'s own SummonSpacing, 1s by default',
    Min = 0.2,
    Max = 3,
    Increment = 0.1,
    Default = MeteorState.Spacing,
    Suffix = ' s',
    Flag = 'wand_meteor_spacing',
    Callback = function(value) MeteorState.Spacing = value end,
})

MeteorSection:Slider({
    Title = 'travel speed',
    Description = 'the game\'s own default is 140',
    Min = 40,
    Max = 400,
    Increment = 10,
    Default = MeteorState.TravelSpeed,
    Flag = 'wand_meteor_travel_speed',
    Callback = function(value) MeteorState.TravelSpeed = value end,
})

MeteorSection:Slider({
    Title = 'summon time',
    Description = 'how long the wind-up animation plays before it launches - the game\'s own default is 1.25s',
    Min = 0.3,
    Max = 3,
    Increment = 0.05,
    Default = MeteorState.SummonTime,
    Suffix = ' s',
    Flag = 'wand_meteor_summon_time',
    Callback = function(value) MeteorState.SummonTime = value end,
})

MeteorSection:Slider({
    Title = 'radius',
    Description = 'how far from you meteors can land',
    Min = 10,
    Max = 150,
    Increment = 5,
    Default = MeteorState.Radius,
    Suffix = ' studs',
    Flag = 'wand_meteor_radius',
    Callback = function(value) MeteorState.Radius = value end,
})

MeteorSection:Slider({
    Title = 'start height',
    Description = 'how far above you each meteor starts falling from',
    Min = 50,
    Max = 400,
    Increment = 10,
    Default = MeteorState.Height,
    Suffix = ' studs',
    Flag = 'wand_meteor_height',
    Callback = function(value) MeteorState.Height = value end,
})

local ThunderSection = TricksTab:CreateSection({ Title = 'thunderstorm', Collapsible = true })

if not ThunderstormModule then
    ThunderSection:Paragraph({
        Title = 'unavailable',
        Content = 'ReplicatedStorage.ThunderstormClient was not found in this server, so this trick has nothing to call. The controls below are inert.',
    })
end

ThunderSection:Toggle({
    Title = 'continuous',
    Description = 'strikes on the interval below for as long as this is on',
    Flag = 'wand_thunder_enabled',
    Default = false,
    Callback = function(state) ThunderState.Enabled = state end,
})

ThunderSection:Button({
    Title = 'strike now',
    Callback = strikeLightning,
})

ThunderSection:Divider()

ThunderSection:Slider({
    Title = 'strike interval',
    Min = 1,
    Max = 30,
    Increment = 1,
    Default = ThunderState.Interval,
    Suffix = ' s',
    Flag = 'wand_thunder_interval',
    Callback = function(value) ThunderState.Interval = value end,
})

ThunderSection:Slider({
    Title = 'radius',
    Min = 5,
    Max = 100,
    Increment = 5,
    Default = ThunderState.Radius,
    Suffix = ' studs',
    Flag = 'wand_thunder_radius',
    Callback = function(value) ThunderState.Radius = value end,
})

--// session --------------------------------------------------------------------

local SessionSection = SessionTab:CreateSection('session')

local function resetAllOptions()
    local defaults = {
        wand_rain_enabled = false,
        wand_rain_rate = 150,
        wand_rain_speed = 45,
        wand_rain_size = 0.3,
        wand_rain_spread = 2,
        wand_rain_area = 40,
        wand_rain_height = 35,
        wand_rain_color = Color3.fromRGB(160, 190, 255),

        wand_snow_enabled = false,
        wand_snow_rate = 120,
        wand_snow_speed = 12,
        wand_snow_size = 0.45,
        wand_snow_spread = 20,
        wand_snow_area = 45,
        wand_snow_height = 30,
        wand_snow_color = Color3.fromRGB(235, 240, 250),

        wand_fog_enabled = false,
        wand_fog_start = 0,
        wand_fog_end = 300,
        wand_fog_color = Color3.fromRGB(200, 200, 210),

        wand_meteor_enabled = false,
        wand_meteor_interval = 10,
        wand_meteor_count = 5,
        wand_meteor_spacing = 1,
        wand_meteor_travel_speed = 140,
        wand_meteor_summon_time = 1.25,
        wand_meteor_radius = 50,
        wand_meteor_height = 180,

        wand_thunder_enabled = false,
        wand_thunder_interval = 5,
        wand_thunder_radius = 30,
    }

    for flag, value in pairs(defaults) do
        pcall(function() Onyx:SetFlag(flag, value) end)
    end
end

SessionSection:Button({
    Title = 'reset all options',
    Description = 'sets every trick back to its default and turns them all off',
    Confirm = true,
    Callback = resetAllOptions,
})

SessionSection:Button({
    Title = 'unload',
    Confirm = true,
    Callback = function()
        Unloading = true
        weatherConnection:Disconnect()
        Rain.Emitter.Enabled = false
        Snow.Emitter.Enabled = false
        VFXFolder:Destroy()
        FogState.Enabled = false
        applyFog()
        Onyx:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Content = 'stops every trick, destroys the rain/snow rig, restores the original fog, then closes the menu.',
})

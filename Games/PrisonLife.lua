local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = workspace.CurrentCamera
end)

local Config = {
    SilentAim = false,
    FOVEnabled = true,
    FOVRadius = 120,
    FOVTransparency = 0.6,

    InfiniteAmmo = false,

    InstaKillPunch = false,
    PunchHits = 10,
}

-- Prison Life's own client scripts (ClientInputHandler, HandcuffsClient) only
-- ever block Guard-vs-Guard interaction - everyone else is fair game to
-- punch/arrest/target. Reused here for consistent targeting.
local function isValidTarget(plr, char)
    if plr == LocalPlayer or not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local guards = Teams:FindFirstChild("Guards")
    if guards and LocalPlayer.Team == guards and plr.Team == guards then
        return false
    end
    return true
end

--// Silent aim ----------------------------------------------------------------
-- The actual per-weapon fire script wasn't present in the dump (only the
-- fists/melee-tool scripts were), so there's no confirmed ShootEvent
-- signature to craft a shot from directly. Camera-locking onto the target
-- instead works regardless of whatever that script does internally, since
-- any mouse-aimed fire logic reads its shot direction from the camera.
-- BindToRenderStep at Camera priority + 1 runs after Roblox's own camera
-- update, so our orientation is what's actually rendered (and what any
-- Mouse.Hit / raycast read that frame sees) without touching the camera
-- module's own stored angles - stop forcing it and the camera snaps back to
-- wherever the mouse naturally has it.
local function findSilentAimTarget()
    local viewport = Camera.ViewportSize
    local centerX, centerY = viewport.X / 2, viewport.Y / 2
    local best, bestDist = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        local char = plr.Character
        if isValidTarget(plr, char) then
            local part = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
            if part then
                local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen then
                    local dx, dy = screenPos.X - centerX, screenPos.Y - centerY
                    local screenDist = math.sqrt(dx * dx + dy * dy)
                    if (not Config.FOVEnabled or screenDist <= Config.FOVRadius) and screenDist < bestDist then
                        best, bestDist = plr, screenDist
                    end
                end
            end
        end
    end

    return best
end

RunService:BindToRenderStep("PrisonLifeSilentAim", Enum.RenderPriority.Camera.Value + 1, function()
    if not Config.SilentAim then return end
    local target = findSilentAimTarget()
    if not target then return end
    local char = target.Character
    local part = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
    if not part then return end
    Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, part.Position)
end)

local fovCircle = nil
if typeof(Drawing) == "table" then
    pcall(function()
        fovCircle = Drawing.new("Circle")
        fovCircle.Thickness = 1.5
        fovCircle.NumSides = 48
        fovCircle.Filled = false
        fovCircle.Color = Color3.fromRGB(255, 255, 255)
        fovCircle.Visible = false
    end)
end

RunService.RenderStepped:Connect(function()
    if not fovCircle then return end
    local show = Config.SilentAim and Config.FOVEnabled
    fovCircle.Visible = show
    if show then
        fovCircle.Radius = Config.FOVRadius
        -- Drawing's Transparency is opacity-flavored (1 = fully opaque), the
        -- opposite of Roblox's own convention, so the slider (Roblox-style,
        -- higher = more see-through) gets inverted here.
        fovCircle.Transparency = 1 - Config.FOVTransparency
        fovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
end)

--// Gun mods -------------------------------------------------------------------
-- Attributes set directly on your own Tool instances - the fire script that
-- would actually read these wasn't in the dump either, so which of these
-- functionally matter vs. get silently re-validated server-side is unverified.
-- Applied to every Tool in both Character and Backpack that already has the
-- attribute, so it covers your whole loadout, not just whatever's equipped.
local GunModStats = {
    { Key = "Damage", Title = "damage", Min = 1, Max = 300, Increment = 1, Default = 19 },
    { Key = "FireRate", Title = "fire rate", Min = 0.02, Max = 1, Increment = 0.01, Default = 0.12, Suffix = "s" },
    { Key = "Range", Title = "range", Min = 100, Max = 5000, Increment = 50, Default = 1500, Suffix = " studs" },
    { Key = "AccurateRange", Title = "accurate range", Min = 10, Max = 500, Increment = 5, Default = 110, Suffix = " studs" },
    { Key = "SpreadRadius", Title = "spread radius", Min = 0, Max = 0.1, Increment = 0.001, Default = 0 },
    { Key = "ReloadTime", Title = "reload time", Min = 0, Max = 5, Increment = 0.1, Default = 2, Suffix = "s" },
    { Key = "MaxAmmo", Title = "max ammo", Min = 1, Max = 999, Increment = 1, Default = 15 },
    { Key = "ProjectileCount", Title = "projectile count", Min = 1, Max = 20, Increment = 1, Default = 5 },
}

local GunModConfig = {}
for _, stat in ipairs(GunModStats) do
    GunModConfig[stat.Key] = { Enabled = false, Value = stat.Default }
end
local AutoFireConfig = { Enabled = false, Value = true }

local function forEachOwnedTool(fn)
    local char = LocalPlayer.Character
    if char then
        for _, inst in ipairs(char:GetChildren()) do
            if inst:IsA("Tool") then fn(inst) end
        end
    end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, inst in ipairs(backpack:GetChildren()) do
            if inst:IsA("Tool") then fn(inst) end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(0.2)
        forEachOwnedTool(function(tool)
            for _, stat in ipairs(GunModStats) do
                local cfg = GunModConfig[stat.Key]
                if cfg.Enabled and tool:GetAttribute(stat.Key) ~= nil then
                    tool:SetAttribute(stat.Key, cfg.Value)
                end
            end
            if AutoFireConfig.Enabled and tool:GetAttribute("AutoFire") ~= nil then
                tool:SetAttribute("AutoFire", AutoFireConfig.Value)
            end
            if Config.InfiniteAmmo then
                local maxAmmo = tool:GetAttribute("MaxAmmo")
                if maxAmmo ~= nil and tool:GetAttribute("CurrentAmmo") ~= nil then
                    tool:SetAttribute("CurrentAmmo", maxAmmo)
                end
            end
        end)
    end
end)

--// Insta kill punch -----------------------------------------------------------
-- Confirmed from the dump: both ClientInputHandler (bare fists) and
-- MeleeToolScript (melee tools) resolve a hit locally, then just call
-- meleeEvent:FireServer(target, arg2, 1) - a per-swing flag stops the client
-- from calling it more than once per swing, but nothing server-visible in
-- either script suggests the server itself rate-limits the remote. Hooking
-- __namecall replays whatever real call the game's own script makes N times
-- instead of reimplementing hit detection - it only ever fires calls the
-- unmodified game logic already decided were legitimate.
local meleeEvent = ReplicatedStorage:WaitForChild("meleeEvent")
local originalNamecall = nil
local instaKillHookAvailable = false

if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local ok = pcall(function()
        originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            if Config.InstaKillPunch and self == meleeEvent and getnamecallmethod() == "FireServer" then
                local args = { ... }
                for _ = 1, Config.PunchHits do
                    originalNamecall(self, table.unpack(args))
                end
                return
            end
            return originalNamecall(self, ...)
        end)
    end)
    instaKillHookAvailable = ok
end

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'prison life',
    SubTitle = 'assist',
    Folder = 'PrisonLifeAssist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(70, 160, 255),
})

local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })

local SilentAimSection = MainTab:Section({ Title = 'silent aim', Side = 'left' })

SilentAimSection:Toggle({
    Title = 'silent aim',
    Flag = 'pl_silent_aim',
    Default = false,
    Callback = function(v) Config.SilentAim = v end,
})

SilentAimSection:Toggle({
    Title = 'fov',
    Flag = 'pl_fov',
    Default = true,
    Callback = function(v) Config.FOVEnabled = v end,
})

local FovSection = MainTab:Section({ Title = 'fov circle', Side = 'right' })

FovSection:Slider({
    Title = 'fov size',
    Flag = 'pl_fov_size',
    Min = 20,
    Max = 400,
    Increment = 5,
    Default = 120,
    Suffix = ' px',
    Callback = function(v) Config.FOVRadius = v end,
})

FovSection:Slider({
    Title = 'fov transparency',
    Flag = 'pl_fov_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.6,
    Callback = function(v) Config.FOVTransparency = v end,
})

FovSection:Paragraph({
    Title = 'targeting',
    Text = 'FOV off targets anyone visible on screen. FOV on restricts targeting (and the drawn circle) to the radius above, centered on screen.',
})

local GunModsTab = Window:Tab({ Title = 'gun mods', Icon = 'wrench' })
local StatsSection = GunModsTab:Section({ Title = 'stat overrides', Side = 'left' })

for _, stat in ipairs(GunModStats) do
    StatsSection:Toggle({
        Title = stat.Title,
        Flag = 'pl_gm_' .. stat.Key .. '_enabled',
        Default = false,
        Callback = function(v) GunModConfig[stat.Key].Enabled = v end,
    })
    StatsSection:Slider({
        Title = stat.Title .. ' value',
        Flag = 'pl_gm_' .. stat.Key .. '_value',
        Min = stat.Min,
        Max = stat.Max,
        Increment = stat.Increment,
        Default = stat.Default,
        Suffix = stat.Suffix,
        Callback = function(v) GunModConfig[stat.Key].Value = v end,
    })
end

local MiscSection = GunModsTab:Section({ Title = 'misc', Side = 'right' })

MiscSection:Toggle({
    Title = 'auto fire (force full-auto)',
    Flag = 'pl_gm_autofire',
    Default = false,
    Callback = function(v) AutoFireConfig.Enabled = v end,
})

MiscSection:Toggle({
    Title = 'infinite ammo',
    Flag = 'pl_gm_infinite_ammo',
    Default = false,
    Callback = function(v) Config.InfiniteAmmo = v end,
})

MiscSection:Paragraph({
    Title = 'what actually works',
    Text = "These write Attributes on your own gun instances - the fire script that reads them wasn't in the dump, so this isn't fully verified. Fire Rate / Spread Radius / Reload Time gate your own client's input timing and are the most likely to matter. Damage is the most likely to be re-checked server-side and stay cosmetic only.",
})

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local PunchSection = PlayerTab:Section({ Title = 'insta kill punch', Side = 'left' })

local InstaKillToggle = PunchSection:Toggle({
    Title = 'insta kill punch',
    Flag = 'pl_instakill',
    Default = false,
    Callback = function(v)
        if v and not instaKillHookAvailable then
            Centrl:Notify({
                Title = 'prison life',
                Content = 'hookmetamethod is not available on this executor - insta kill punch needs it.',
                Type = 'error',
                Duration = 5,
            })
            Config.InstaKillPunch = false
            InstaKillToggle:Set(false, true)
            return
        end
        Config.InstaKillPunch = v
    end,
})

PunchSection:Slider({
    Title = 'hits per punch',
    Flag = 'pl_instakill_hits',
    Min = 1,
    Max = 50,
    Increment = 1,
    Default = 10,
    Callback = function(v) Config.PunchHits = v end,
})

local PunchInfo = PlayerTab:Section({ Title = 'behavior', Side = 'right' })
PunchInfo:Paragraph({
    Title = 'how it works',
    Text = "Every landed punch (fists or a melee tool) still calls the game's real meleeEvent once, same as normal - this just replays that exact same call the number of times set above, so one real hit becomes that many damage instances instead of a bigger single number.",
})

Window:Load()

Centrl:Notify({
    Title = 'prison life',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

--// Murder Mystery 2 -------------------------------------------------------
-- Built against a fresh script dump of the live game. The remotes below are
-- the real ones the game's own client modules use, not guesses - and every
-- one of them is a read, nothing here fires anything back at the server:
--
--   Remotes.Gameplay.GetCurrentPlayerData :InvokeServer()
--       Every player's current round data, keyed by name:
--       { [name] = { Role, Perk, Dead, Knife, Gun } }. This is the exact
--       table ReplicatedStorage.Modules.CurrentRoundClient and the
--       round-end scoreboard both read from, and it is NOT limited to your
--       own entry - it carries everyone's role for the whole round.
--   Remotes.Gameplay.PlayerDataChanged.OnClientEvent(playerData)
--       Pushes that same table the instant it changes - role assignment,
--       deaths, perk swaps - which is what makes the role ESP below live
--       instead of polled from a private per-player signal.
--   Remotes.Inventory.GetProfileData :InvokeServer()
--       Your own save: Coins, Gems, NewXP, Prestige, and
--       Weapons/Pets/Materials.Owned - the exact table
--       ReplicatedStorage.Modules.ProfileData wraps and the retry shape
--       (nil until the server responds) it uses.
--   Remotes.Inventory.ChangeProfileData.OnClientEvent(key, value)
--       Live field updates to the table above.
--   Remotes.Inventory.ChangeInventoryItem.OnClientEvent(type, id, amount)
--       Live inventory updates (new weapon/pet/material, amount changes).
--   Modules.LevelModule
--       Pure XP-to-level math, no side effects - required directly so the
--       dashboard shows the same level/progress numbers the game's own UI
--       computes from NewXP.
--
-- A second dump caught someone actually holding the Sheriff's gun, which is
-- what GunClient below comes from (Workspace.<player>.Gun.GunClient). Its
-- fire path is:
--
--   Tool.Activated:Connect(function()
--       local target = WeaponService:GetMouseTargetCFrame()  -- client raycast
--       local origin = HumanoidRootPart.GunRaycastAttachment.WorldCFrame
--       Tool.Shoot:FireServer(origin, target)
--   end)
--
-- Both arguments are entirely client-computed and sent as-is - origin comes
-- off a fixed attachment on your own torso, target off the same
-- screen-to-world raycast the knife throw uses. There's also a client-only
-- "can't shoot" gate (a raycast from your Head to the gun attachment, to
-- catch a blocked third-person angle) that toggles a CantShoot BindableEvent
-- for the crosshair - but nothing reads that BindableEvent before firing, so
-- it never actually stops Shoot:FireServer from going out.
--
-- Silent aim below hooks Shoot:FireServer itself (game.__namecall) rather
-- than replacing the click handler: it lets the real Activated connection
-- do everything - animation, the origin attachment, whatever cooldown the
-- server enforces - and only ever rewrites the target CFrame argument.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Lifecycle ------------------------------------------------------------------
local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function spawnLoop(fn)
    return task.spawn(fn)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Remotes --------------------------------------------------------------------
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

local RemotesFolder = waitForPath(ReplicatedStorage, { "Remotes" })
local GameplayRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Gameplay")
local InventoryRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Inventory")

local GetCurrentPlayerData = GameplayRemotes and GameplayRemotes:FindFirstChild("GetCurrentPlayerData")
local PlayerDataChangedRemote = GameplayRemotes and GameplayRemotes:FindFirstChild("PlayerDataChanged")

local GetProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("GetProfileData")
local ChangeProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeProfileData")
local ChangeInventoryItem = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeInventoryItem")

local LevelModule = nil
do
    local ModulesFolder = waitForPath(ReplicatedStorage, { "Modules" })
    local mod = ModulesFolder and ModulesFolder:FindFirstChild("LevelModule")
    if mod then
        local ok, result = pcall(require, mod)
        if ok then LevelModule = result end
    end
end

--// Live round data (role/perk/dead, for every player) -------------------------
local RoundData = {}

local function refreshRoundData()
    if not GetCurrentPlayerData then return end
    local ok, data = pcall(function() return GetCurrentPlayerData:InvokeServer() end)
    if ok and typeof(data) == "table" then
        RoundData = data
    end
end

task.spawn(refreshRoundData)

if PlayerDataChangedRemote then
    track(PlayerDataChangedRemote.OnClientEvent:Connect(function(data)
        if typeof(data) == "table" then
            RoundData = data
        end
    end))
end

--// Live profile data (own coins/gems/xp/inventory) -----------------------------
local ProfileData = nil

local function fetchProfileData()
    if not GetProfileData then return end
    task.spawn(function()
        local tries = 0
        while not Unloading and tries < 60 do
            local ok, data = pcall(function() return GetProfileData:InvokeServer() end)
            if ok and typeof(data) == "table" then
                ProfileData = data
                return
            end
            tries = tries + 1
            task.wait(0.25)
        end
    end)
end

fetchProfileData()

if ChangeProfileData then
    track(ChangeProfileData.OnClientEvent:Connect(function(key, value)
        if ProfileData then ProfileData[key] = value end
    end))
end

-- Mirrors ProfileData's own onInventoryItemChanged: Weapons/Pets/Materials are
-- id -> amount dictionaries, everything else (Emotes, Toys, ...) is a plain
-- array of owned ids.
local DICT_INVENTORY_TYPES = { Weapons = true, Pets = true, Materials = true }

if ChangeInventoryItem then
    track(ChangeInventoryItem.OnClientEvent:Connect(function(itemType, id, amount)
        if not ProfileData or not ProfileData[itemType] then return end
        if DICT_INVENTORY_TYPES[itemType] then
            ProfileData[itemType].Owned[id] = amount
        elseif amount ~= nil and amount > 0 then
            table.insert(ProfileData[itemType].Owned, id)
        end
    end))
end

local function countOwned(owned)
    if not owned then return 0 end
    local n = 0
    for _ in pairs(owned) do n = n + 1 end
    return n
end

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'mm2',
    SubTitle = 'assist',
    Folder = 'MM2Assist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(210, 45, 45),
})

--// Tab 1: profile ---------------------------------------------------------------
local ProfileTab = Window:Tab({ Title = 'profile', Icon = 'user' })

local EconomySection = ProfileTab:Section({ Title = 'economy', Side = 'left' })
local CoinsStat = EconomySection:Stat({ Title = 'coins', Value = '-' })
local GemsStat = EconomySection:Stat({ Title = 'gems', Value = '-' })
local PrestigeStat = EconomySection:Stat({ Title = 'prestige', Value = '-' })
EconomySection:Button({ Title = 'refresh', Callback = fetchProfileData })

local LevelSection = ProfileTab:Section({ Title = 'level', Side = 'right' })
local LevelStat = LevelSection:Stat({ Title = 'level', Value = '-' })
local XPBar = LevelSection:Progress({ Title = 'xp to next level', Percent = true })

local InventorySection = ProfileTab:Section({ Title = 'inventory', Side = 'left' })
local WeaponsStat = InventorySection:Stat({ Title = 'weapons owned', Value = '-' })
local PetsStat = InventorySection:Stat({ Title = 'pets owned', Value = '-' })
local MaterialsStat = InventorySection:Stat({ Title = 'materials owned', Value = '-' })

local function refreshDashboard()
    if not ProfileData then return end

    CoinsStat:Set(tostring(ProfileData.Coins or 0))
    GemsStat:Set(tostring(ProfileData.Gems or 0))
    PrestigeStat:Set(tostring(ProfileData.Prestige or 0))

    local xp = ProfileData.NewXP or 0
    if LevelModule then
        local ok, level = pcall(LevelModule.GetLevel, xp)
        if ok then LevelStat:Set(tostring(level)) end

        local ok2, progress = pcall(LevelModule.GetProgressToNextLevel, xp)
        if ok2 and typeof(progress) == "number" then
            XPBar:Set(math.clamp(progress, 0, 1) * 100)
        end
    else
        LevelStat:Set('n/a')
    end

    WeaponsStat:Set(tostring(countOwned(ProfileData.Weapons and ProfileData.Weapons.Owned)))
    PetsStat:Set(tostring(countOwned(ProfileData.Pets and ProfileData.Pets.Owned)))
    MaterialsStat:Set(tostring(countOwned(ProfileData.Materials and ProfileData.Materials.Owned)))
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        refreshDashboard()
    end
end)

--// Tab 2: silent aim -------------------------------------------------------------
local Aim = {
    SilentAim = false,
    WallCheck = true,
    AimPart = "Head",
    MaxRange = 300,          -- WeaponService:GetMouseTargetCFrame caps its own raycast at 300 studs
    FOVEnabled = true,
    FOVRadius = 200,
    FOVFollowMouse = true,
}

local function isAlivePlr(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.IgnoreWater = true

local function isVisible(char, origin)
    if not Aim.WallCheck then return true end
    local part = char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart")
    if not part then return false end
    local params = visionParams
    params.FilterDescendantsInstances = { LocalPlayer.Character, char }
    local direction = part.Position - origin
    local ok, result = pcall(function() return Workspace:Raycast(origin, direction, params) end)
    if not ok then return true end
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

local function screenAnchor()
    if Aim.FOVFollowMouse then
        return UserInputService:GetMouseLocation()
    end
    local viewport = Camera.ViewportSize
    return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

local function getTarget()
    local origin = Camera.CFrame.Position
    local anchor = screenAnchor()
    local best, bestScore

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) then
            local char = plr.Character
            local part = char and (char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart"))
            if part then
                local dist = (part.Position - origin).Magnitude
                if dist <= Aim.MaxRange then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
                    if onScreen then
                        local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - anchor).Magnitude
                        if not Aim.FOVEnabled or screenDist <= Aim.FOVRadius then
                            if isVisible(char, origin) then
                                if not bestScore or screenDist < bestScore then
                                    bestScore = screenDist
                                    best = part
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

-- getTarget scans every player and raycasts per candidate; the namecall hook
-- below runs on every single method call in the entire game, not just shots,
-- so it can't afford to do that scan itself. Recomputed at most 30x/sec and
-- reused for whichever calls land inside that window.
local cachedTarget, cachedTargetAt = nil, 0
local TARGET_CACHE_SECONDS = 1 / 30

local function getCachedTarget()
    local now = os.clock()
    if cachedTarget and cachedTarget.Parent and (now - cachedTargetAt) < TARGET_CACHE_SECONDS then
        return cachedTarget
    end
    cachedTargetAt = now
    local ok, result = pcall(getTarget)
    cachedTarget = ok and result or nil
    return cachedTarget
end

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall
    originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if not Unloading and Aim.SilentAim and typeof(self) == "Instance" and getnamecallmethod() == "FireServer" then
            -- Matched by shape (a RemoteEvent named "Shoot" whose parent is
            -- a Tool named "Gun"), not by a cached instance reference, so
            -- this keeps working across every respawn and every new gun
            -- instance without needing to re-find anything.
            if self.Name == "Shoot" and self.ClassName == "RemoteEvent" then
                local parent = self.Parent
                if parent and parent.ClassName == "Tool" and parent.Name == "Gun" then
                    local target = getCachedTarget()
                    if target and target.Parent then
                        local origin = ...
                        return originalNamecall(self, origin, CFrame.new(target.Position))
                    end
                end
            end
        end
        return originalNamecall(self, ...)
    end)
end

local SilentAimTab = Window:Tab({ Title = 'silent aim', Icon = 'crosshair' })

local AimSection = SilentAimTab:Section({ Title = 'aim', Side = 'left' })

AimSection:Stat({
    Title = 'hook api',
    Value = hasNamecallHook and 'available' or 'missing',
    Color = hasNamecallHook and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
})

AimSection:Toggle({
    Title = 'silent aim',
    Desc = 'redirects the shot you actually fire to the nearest valid target - your click, animation and the origin attachment all stay real, only the aim point changes',
    Flag = 'mm2_silent_aim',
    Callback = function(state)
        if state and not hasNamecallHook then
            Centrl:Notify({
                Title = 'mm2',
                Content = 'hookmetamethod/getnamecallmethod not available on this executor - silent aim cannot hook Shoot:FireServer.',
                Type = 'error',
                Duration = 6,
            })
        end
        Aim.SilentAim = state
    end,
})

AimSection:Dropdown({
    Title = 'aim part',
    Values = { 'Head', 'HumanoidRootPart' },
    Default = 'Head',
    Callback = function(value) Aim.AimPart = value end,
})

AimSection:Toggle({
    Title = 'wall check',
    Desc = 'requires a clear line of sight from your camera to the target before it counts',
    Flag = 'mm2_silent_aim_wallcheck',
    Default = true,
    Callback = function(state) Aim.WallCheck = state end,
})

AimSection:Slider({
    Title = 'max range',
    Min = 25,
    Max = 300,
    Increment = 5,
    Default = 300,
    Suffix = ' studs',
    Flag = 'mm2_silent_aim_range',
    Callback = function(value) Aim.MaxRange = value end,
})

local FovSection = SilentAimTab:Section({ Title = 'fov', Side = 'right' })

FovSection:Toggle({
    Title = 'fov limit',
    Desc = 'only considers targets within the radius below',
    Flag = 'mm2_silent_aim_fov',
    Default = true,
    Callback = function(state) Aim.FOVEnabled = state end,
})

FovSection:Slider({
    Title = 'fov radius',
    Min = 20,
    Max = 600,
    Increment = 10,
    Default = 200,
    Flag = 'mm2_silent_aim_fov_radius',
    Callback = function(value) Aim.FOVRadius = value end,
})

FovSection:Toggle({
    Title = 'follow mouse',
    Desc = 'centers the fov on the mouse instead of the middle of the screen',
    Flag = 'mm2_silent_aim_follow_mouse',
    Default = true,
    Callback = function(state) Aim.FOVFollowMouse = state end,
})

--// Tab 3: visual ------------------------------------------------------------------
local Visual = {
    Enabled = false,
    ColorByRole = false,
    RoleESP = false,
    ShowMurdererPerk = false,
}

-- Straight out of ReplicatedStorage.GUI.MainPC.Game/RoleSelector's own role
-- color table, so the ESP matches the colors the game itself uses for these
-- roles rather than inventing a new palette.
local ROLE_COLORS = {
    Innocent = Color3.fromRGB(0, 255, 0),
    Sheriff = Color3.fromRGB(0, 0, 255),
    Murderer = Color3.fromRGB(255, 0, 0),
    Hero = Color3.fromRGB(0, 0, 255),
    Zombie = Color3.fromRGB(25, 172, 0),
    Survivor = Color3.fromRGB(43, 154, 238),
    Freezer = Color3.fromRGB(150, 220, 250),
    Runner = Color3.fromRGB(0, 200, 100),
}
local DEFAULT_ESP_COLOR = Color3.fromRGB(255, 255, 255)

local function espColorFor(plr)
    if Visual.ColorByRole then
        local entry = RoundData[plr.Name]
        -- entry.Dead was missing from this check, so once ColorByRole had
        -- colored someone in, they stayed that color forever: RoundData
        -- keeps a dead player's Role around (the round-end scoreboard reads
        -- it straight off the same table), so "role -> color" alone never
        -- stopped matching just because they died mid-round.
        if entry and entry.Role and entry.Dead ~= true then
            local color = ROLE_COLORS[entry.Role]
            if color then return color end
        end
    end
    return DEFAULT_ESP_COLOR
end

--// Player ESP (Highlight) ---------------------------------------------------------
local espObjects = {}

local function destroyEsp(plr)
    local obj = espObjects[plr]
    if not obj then return end
    if obj.Highlight then obj.Highlight:Destroy() end
    espObjects[plr] = nil
end

local function buildEsp(plr, char)
    destroyEsp(plr)
    local color = espColorFor(plr)
    local hl = Instance.new("Highlight")
    hl.FillColor = color
    hl.OutlineColor = color
    hl.FillTransparency = 0.5
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = char
    espObjects[plr] = { Char = char, Highlight = hl }
end

--// Role ESP (name-above-head billboard) --------------------------------------------
local roleObjects = {}

local function destroyRoleLabel(plr)
    local obj = roleObjects[plr]
    if not obj then return end
    if obj.Billboard then obj.Billboard:Destroy() end
    roleObjects[plr] = nil
end

local function buildRoleLabel(plr, char)
    destroyRoleLabel(plr)
    local head = char:FindFirstChild("Head")
    if not head then return nil end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "MM2RoleESP"
    billboard.Adornee = head
    billboard.Size = UDim2.fromOffset(200, 36)
    billboard.StudsOffset = Vector3.new(0, 2.2, 0)
    billboard.AlwaysOnTop = true

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextStrokeTransparency = 0.4
    label.Text = ""
    label.Parent = billboard

    billboard.Parent = char
    roleObjects[plr] = { Char = char, Billboard = billboard, Label = label }
    return roleObjects[plr]
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.4)

        if Visual.Enabled then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    local char = plr.Character
                    local obj = espObjects[plr]
                    if not char then
                        if obj then destroyEsp(plr) end
                    elseif not obj or obj.Char ~= char then
                        buildEsp(plr, char)
                    else
                        local color = espColorFor(plr)
                        obj.Highlight.FillColor = color
                        obj.Highlight.OutlineColor = color
                    end
                end
            end
        else
            for plr in pairs(espObjects) do destroyEsp(plr) end
        end

        -- Role ESP: only for a player who currently HAS a role (they're in
        -- this round) and isn't dead, and never for the local player - they
        -- already know their own role from the game's own reveal screen.
        if Visual.RoleESP then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr == LocalPlayer then
                    if roleObjects[plr] then destroyRoleLabel(plr) end
                else
                    local char = plr.Character
                    local entry = RoundData[plr.Name]
                    local hasRole = entry ~= nil and entry.Role ~= nil and entry.Dead ~= true

                    if not char or not hasRole then
                        if roleObjects[plr] then destroyRoleLabel(plr) end
                    else
                        local obj = roleObjects[plr]
                        if not obj or obj.Char ~= char then
                            obj = buildRoleLabel(plr, char)
                        end
                        if obj then
                            local text = entry.Role
                            -- The murderer's perk, and only on the
                            -- murderer's own label - entry is this specific
                            -- player's round data, so this can never leak
                            -- onto anyone else's head.
                            if Visual.ShowMurdererPerk and entry.Role == "Murderer" and entry.Perk then
                                text = text .. " (" .. tostring(entry.Perk) .. ")"
                            end
                            obj.Label.Text = text
                            obj.Label.TextColor3 = ROLE_COLORS[entry.Role] or DEFAULT_ESP_COLOR
                        end
                    end
                end
            end
        else
            for plr in pairs(roleObjects) do destroyRoleLabel(plr) end
        end
    end
end)

track(Players.PlayerRemoving:Connect(function(plr)
    destroyEsp(plr)
    destroyRoleLabel(plr)
end))

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })

local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Desc = 'highlights every other player',
    Flag = 'mm2_esp',
    Callback = function(state) Visual.Enabled = state end,
})

EspSection:Toggle({
    Title = 'color by role',
    Desc = "esp color follows each player's current role (innocent/sheriff/murderer, or infection/freeze tag) instead of a flat color",
    Flag = 'mm2_esp_role_color',
    Callback = function(state) Visual.ColorByRole = state end,
})

local RoleEspSection = VisualTab:Section({ Title = 'role esp', Side = 'right' })

RoleEspSection:Toggle({
    Title = 'role esp',
    Desc = "shows each player's role above their head - only while they're alive and actually have a role this round, never on you",
    Flag = 'mm2_role_esp',
    Callback = function(state) Visual.RoleESP = state end,
})

RoleEspSection:Toggle({
    Title = "show murderer's perk",
    Desc = "appends the murderer's currently active perk to their label only - nobody else's",
    Flag = 'mm2_role_esp_perk',
    Callback = function(state) Visual.ShowMurdererPerk = state end,
})

Window:Load()

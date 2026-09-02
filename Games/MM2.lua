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
-- The Sheriff's gun tool script never showed up in the dump - nobody had it
-- equipped when the dump was taken, and a Tool's LocalScript only exists
-- (and only decompiles) while it's actually held. So the silent aim tab
-- below is deliberately empty for now; there is nothing in this dump to
-- hook a gun raycast onto yet.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

--// Tab 2: silent aim (empty for now - see header) --------------------------------
Window:Tab({ Title = 'silent aim', Icon = 'crosshair' })

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
        local color = entry and entry.Role and ROLE_COLORS[entry.Role]
        if color then return color end
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

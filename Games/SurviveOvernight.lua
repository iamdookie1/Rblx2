--// Velstorm's Survive Overnight -- auto loot, kill aura, resource harvest,
--// crafting, token shop, auto eat/heal/revive, movement, ESP and teleports.
--
-- Built against a script dump of the live game (place 121418861436763, game
-- 7058980030, version 101). How the game works, and why each feature is built
-- the way it is:
--
--  * Remotes live in three groups, all reached by path: ReplicatedStorage
--    .Remotes.* (pickup, interact, weapon, player), .Remotes.Weapon.* and
--    .RemoterRemotes.* (the "Remoter" wrapper just does
--    RemoterRemotes:WaitForChild(name), so RequestCraft/SetBearTrap/etc. are
--    plain instances under that folder).
--
--  * COMBAT is client-authoritative for hit registration. WeaponClient's hit()
--    fires Remotes.Weapon.Damage:FireServer(targetHumanoidOrPart, weaponName,
--    origin) and the server applies the damage from that, so a kill aura is
--    just firing that remote at each enemy Humanoid (in Workspace.Enemies)
--    with the name of the weapon you're holding. The same call against a part
--    tagged DamageableTag breaks it for Wood/Cloth/Metal, which is the resource
--    harvest.
--
--  * TOOLS (food, drinks, medkits, melee) use the stock Tool.Activated flow:
--    ToolClient fires Remotes.Item.Activated when the held Tool is activated.
--    So "use an item" is humanoid:EquipTool(tool) then tool:Activate() -- the
--    real client handler runs and replicates correctly. Each tool carries
--    ToolStats.ItemType (Food/Drink/Candy/Health/Melee/Gun/...), which is how
--    auto-eat/heal pick the right one. Your needs are Character.CharacterData
--    .Energy and .Stamina; health is the Humanoid.
--
--  * CRAFTING is RemoterRemotes.RequestCraft:InvokeServer(itemName, tableOrNil)
--    -- the server checks your Wood/Cloth/Metal. Tier-0 recipes (BasicBackpack,
--    Hatchet, PointyMop, Bandage, CraftingTableT1) take nil; the rest want a
--    placed CraftingTable nearby, so the nearest one is passed when found.
--
--  * PICKUPS: map items (Tools under Workspace.Map.Util.Items, tagged ItemTag)
--    are claimed with Remotes.RequestPickupItem:FireServer(item); tokens
--    (Workspace.Map.Util.Tokens) with Remotes.PickupToken + a touch; presents
--    with their own prompt. Token-shop buys and other prompts are fired
--    through fireproximityprompt.
--
--  * REVIVE is Remotes.Player.RequestRevive:InvokeServer(downedPlayer,
--    "UseItem") while holding a medkit/bandage next to them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__SurviveOvernightStop) == "function" then pcall(Genv.__SurviveOvernightStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(c) Connections[#Connections + 1] = c return c end

--// settings ----------------------------------------------------------------

local S = {
    -- farm
    CollectItems = false,
    CollectTokens = false,
    OpenPresents = false,
    Harvest = false,
    HarvestRange = 80,
    -- combat
    KillAura = false,
    AuraRange = 60,
    AttackDelay = 0.15,
    -- craft / shop
    Craft = false,
    CraftList = {},
    ShopBuy = false,
    ShopList = {},
    -- survival
    AutoEat = false,
    EatAt = 45,
    AutoHeal = false,
    HealAt = 45,
    AutoRevive = false,
    InfStamina = false,
    -- movement
    Speed = false,
    SpeedValue = 40,
    Noclip = false,
    Fly = false,
    FlySpeed = 60,
    InfJump = false,
    AntiAfk = true,
    -- esp
    EspItems = false,
    EspTokens = false,
    EspEnemies = false,
}

local Stats = { Status = "idle", Looted = 0, Hits = 0, Started = os.clock() }
local Library

--// remotes -----------------------------------------------------------------

local function node(parent, ...)
    local current = parent
    for _, name in ipairs({ ... }) do
        if not current then return nil end
        current = current:FindFirstChild(name)
    end
    return current
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
local RemoterRemotes = ReplicatedStorage:WaitForChild("RemoterRemotes", 30)

local R = {
    PickupItem = node(Remotes, "RequestPickupItem"),
    PickupToken = node(Remotes, "PickupToken"),
    RequestPickup = node(Remotes, "RequestPickup"),
    Revive = node(Remotes, "Player", "RequestRevive"),
    Damage = node(Remotes, "Weapon", "Damage"),
    Swing = node(Remotes, "Weapon", "Swing"),
    ItemActivated = node(Remotes, "Item", "Activated"),
    Craft = node(RemoterRemotes, "RequestCraft"),
    OpenPresent = node(RemoterRemotes, "OpenChristmasPresent"),
}

local function fire(remote, ...)
    if not remote then return false end
    return (pcall(remote.FireServer, remote, ...))
end

local function invoke(remote, ...)
    if not remote then return nil end
    local ok, result = pcall(remote.InvokeServer, remote, ...)
    if ok then return result end
    return nil
end

--// helpers -----------------------------------------------------------------

local function myChar()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function characterData(name)
    local char = LocalPlayer.Character
    local data = char and char:FindFirstChild("CharacterData")
    local value = data and data:FindFirstChild(name)
    return value
end

local function statPercent(valueName, maxName)
    local v = characterData(valueName)
    local m = characterData(maxName)
    if v and m and m.Value > 0 then return v.Value / m.Value * 100 end
    return nil
end

local function firstBasePart(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    if inst.PrimaryPart then return inst.PrimaryPart end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function teleportTo(cf)
    local char = LocalPlayer.Character
    if char and cf then pcall(function() char:PivotTo(cf + Vector3.new(0, 4, 0)) end) end
end

--// tools --------------------------------------------------------------------

local function allTools()
    local out = {}
    local char = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    for _, container in ipairs({ char, backpack }) do
        for _, t in ipairs(container and container:GetChildren() or {}) do
            if t:IsA("Tool") then out[#out + 1] = t end
        end
    end
    return out
end

local function toolType(tool)
    local stats = tool:FindFirstChild("ToolStats")
    local it = stats and stats:FindFirstChild("ItemType")
    return it and it.Value or nil
end

local function toolsOfType(types)
    local out = {}
    for _, t in ipairs(allTools()) do
        local tt = toolType(t)
        if tt and types[tt] then out[#out + 1] = t end
    end
    return out
end

local function equipTool(tool)
    local char, _, hum = myChar()
    if not char or not hum or not tool then return false end
    if tool.Parent ~= char then pcall(function() hum:EquipTool(tool) end) end
    return tool.Parent == char
end

local function useTool(tool)
    if equipTool(tool) then
        pcall(function() tool:Activate() end)
        return true
    end
    return false
end

-- the weapon in hand (Gun or Melee), or one equipped on demand.
local function equippedWeapon()
    local char = LocalPlayer.Character
    for _, t in ipairs(char and char:GetChildren() or {}) do
        if t:IsA("Tool") then
            local tt = toolType(t)
            if tt == "Gun" or tt == "Melee" then return t end
        end
    end
    local weapons = toolsOfType({ Melee = true, Gun = true })
    local weapon = weapons[1]
    if weapon and equipTool(weapon) then return weapon end
    return nil
end

--// auto collect -------------------------------------------------------------

local function itemsFolder()
    return node(Workspace, "Map", "Util", "Items")
end

local function tokensFolder()
    return node(Workspace, "Map", "Util", "Tokens")
end

local function collectItems()
    local folder = itemsFolder()
    for _, item in ipairs(folder and folder:GetChildren() or {}) do
        if item:IsA("Tool") and CollectionService:HasTag(item, "ItemTag") then
            if fire(R.PickupItem, item) then Stats.Looted += 1 end
        end
    end
end

local function touch(part)
    local _, root = myChar()
    if not part or not root then return end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, part, 0)
        task.wait()
        pcall(firetouchinterest, root, part, 1)
    end
end

local function collectTokens()
    local folder = tokensFolder()
    for _, token in ipairs(folder and folder:GetChildren() or {}) do
        fire(R.PickupToken, token)
        touch(firstBasePart(token))
    end
end

local function openPresents()
    if typeof(fireproximityprompt) ~= "function" then return end
    for _, present in ipairs(CollectionService:GetTagged("ChristmasPresentTag")) do
        if present:IsDescendantOf(Workspace) then
            local prompt = present:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then pcall(fireproximityprompt, prompt) end
            fire(R.OpenPresent, present)
        end
    end
end

task.spawn(function()
    while not Unloaded do
        if S.CollectItems then pcall(collectItems) end
        if S.CollectTokens then pcall(collectTokens) end
        if S.OpenPresents then pcall(openPresents) end
        task.wait(0.4)
    end
end)

--// kill aura & harvest ------------------------------------------------------

local function enemyHumanoids()
    local folder = Workspace:FindFirstChild("Enemies")
    local out = {}
    for _, model in ipairs(folder and folder:GetChildren() or {}) do
        local hum = model:FindFirstChildOfClass("Humanoid")
        local part = model:FindFirstChild("HumanoidRootPart") or firstBasePart(model)
        if hum and hum.Health > 0 and part then out[#out + 1] = { hum = hum, part = part } end
    end
    return out
end

local function attack(target, weaponName, origin)
    if fire(R.Damage, target, weaponName, origin) then Stats.Hits += 1 end
end

task.spawn(function()
    while not Unloaded do
        if S.KillAura then
            local _, root = myChar()
            local weapon = root and equippedWeapon()
            if root and weapon then
                local origin = root.Position
                for _, e in ipairs(enemyHumanoids()) do
                    if not S.KillAura then break end
                    if (e.part.Position - origin).Magnitude <= S.AuraRange then
                        attack(e.hum, weapon.Name, origin)
                    end
                end
            end
        end
        task.wait(S.AttackDelay)
    end
end)

task.spawn(function()
    while not Unloaded do
        if S.Harvest then
            local _, root = myChar()
            local weapon = root and equippedWeapon()
            if root and weapon then
                local origin = root.Position
                for _, obj in ipairs(CollectionService:GetTagged("DamageableTag")) do
                    if not S.Harvest then break end
                    local part = firstBasePart(obj)
                    if part and part:IsDescendantOf(Workspace) and (part.Position - origin).Magnitude <= S.HarvestRange then
                        attack(part, weapon.Name, origin)
                    end
                end
            end
        end
        task.wait(math.max(S.AttackDelay, 0.2))
    end
end)

--// crafting -----------------------------------------------------------------

local CRAFT_T0 = { "BasicBackpack", "Hatchet", "PointyMop", "Bandage", "CraftingTableT1" }
local CRAFT_T1 = { "Medkit", "SodaGun", "ScrappySMG", "ScrappyShotgun", "AmmoPistolBasic", "AmmoARBasic", "AmmoShotgunBasic", "SpikeBarrier", "BearTrap" }
local CRAFT_ALL = {}
for _, n in ipairs(CRAFT_T0) do CRAFT_ALL[#CRAFT_ALL + 1] = n end
for _, n in ipairs(CRAFT_T1) do CRAFT_ALL[#CRAFT_ALL + 1] = n end
local CRAFT_T1_SET = {}
for _, n in ipairs(CRAFT_T1) do CRAFT_T1_SET[n] = true end

local function nearestCraftingTable()
    local placeables = node(Workspace, "Map", "Util", "Placeables")
    local _, root = myChar()
    if not placeables or not root then return nil end
    local best, bestDist
    for _, p in ipairs(placeables:GetDescendants()) do
        if p:IsA("Model") and p.Name:find("CraftingTable") then
            local part = firstBasePart(p)
            local d = part and (part.Position - root.Position).Magnitude or math.huge
            if not bestDist or d < bestDist then best, bestDist = p, d end
        end
    end
    return best
end

local function craft(name)
    local table2 = CRAFT_T1_SET[name] and nearestCraftingTable() or nil
    return invoke(R.Craft, name, table2)
end

task.spawn(function()
    while not Unloaded do
        if S.Craft then
            for _, name in ipairs(CRAFT_ALL) do
                if not S.Craft then break end
                if S.CraftList[name] then
                    craft(name)
                    task.wait(0.15)
                end
            end
        end
        task.wait(1.5)
    end
end)

--// token shop ---------------------------------------------------------------

local SHOP_ITEMS = { "Medkit", "Pistol", "AR", "AmmoPistolBasic", "AmmoARBasic", "BasicFlashlight_Big" }

local function shopPrompt(name)
    local shop = node(Workspace, "Map", "Util", "TokenShop")
    local item = shop and shop:FindFirstChild(name)
    return item and item:FindFirstChild("PurchasePrompt")
end

local function buyShop(name)
    if typeof(fireproximityprompt) ~= "function" then return end
    local prompt = shopPrompt(name)
    if prompt then pcall(fireproximityprompt, prompt, prompt.HoldDuration or 0) end
end

task.spawn(function()
    while not Unloaded do
        if S.ShopBuy then
            for _, name in ipairs(SHOP_ITEMS) do
                if not S.ShopBuy then break end
                if S.ShopList[name] then
                    buyShop(name)
                    task.wait(0.2)
                end
            end
        end
        task.wait(1)
    end
end)

--// survival -----------------------------------------------------------------

task.spawn(function()
    while not Unloaded do
        if S.AutoEat then
            local energy = statPercent("Energy", "MaxEnergy")
            if energy and energy <= S.EatAt then
                local food = toolsOfType({ Food = true, Drink = true, Candy = true })[1]
                if food then useTool(food) end
            end
        end
        if S.AutoHeal then
            local _, _, hum = myChar()
            if hum and hum.MaxHealth > 0 and hum.Health / hum.MaxHealth * 100 <= S.HealAt then
                local heal = toolsOfType({ Health = true })[1]
                if heal then useTool(heal) end
            end
        end
        task.wait(0.6)
    end
end)

-- auto revive: find a downed teammate (their RevivePP prompt is enabled on
-- their character), hold a medkit/bandage, step over and request the revive.
local function reviveTools()
    return toolsOfType({ Health = true })
end

task.spawn(function()
    while not Unloaded do
        if S.AutoRevive and R.Revive then
            local _, root = myChar()
            if root then
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer and player.Character then
                        local prompt = player.Character:FindFirstChild("RevivePP", true)
                            or player.Character:FindFirstChildWhichIsA("ProximityPrompt", true)
                        local downed = prompt and prompt.Enabled
                        if downed then
                            local tool = reviveTools()[1]
                            if tool and equipTool(tool) then
                                local part = player.Character:FindFirstChild("HumanoidRootPart")
                                if part then teleportTo(part.CFrame) task.wait(0.3) end
                                invoke(R.Revive, player, "UseItem")
                            end
                        end
                    end
                end
            end
        end
        task.wait(1)
    end
end)

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    if S.InfStamina then
        pcall(function()
            local stamina = characterData("Stamina")
            local maxStamina = characterData("MaxStamina")
            if stamina and maxStamina then stamina.Value = maxStamina.Value end
        end)
    end
end))

--// movement -----------------------------------------------------------------

track(RunService.Heartbeat:Connect(function()
    if Unloaded or not S.Speed then return end
    pcall(function()
        local _, _, hum = myChar()
        if hum and hum.WalkSpeed ~= S.SpeedValue then hum.WalkSpeed = S.SpeedValue end
    end)
end))

track(RunService.Stepped:Connect(function()
    if Unloaded or not S.Noclip then return end
    pcall(function()
        local char = LocalPlayer.Character
        for _, part in ipairs(char and char:GetDescendants() or {}) do
            if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
        end
    end)
end))

track(RunService.RenderStepped:Connect(function(dt)
    if Unloaded or not S.Fly then return end
    pcall(function()
        local _, root, hum = myChar()
        if not root then return end
        local look = Camera.CFrame
        local move = hum.MoveDirection
        local dir = Vector3.zero
        if move.Magnitude > 0 then
            local flatLook = Vector3.new(look.LookVector.X, 0, look.LookVector.Z)
            local forward = flatLook.Magnitude > 0 and flatLook.Unit or Vector3.new(0, 0, -1)
            dir = move + Vector3.new(0, look.LookVector.Y * move:Dot(forward), 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0, 1, 0) end
        root.AssemblyLinearVelocity = Vector3.zero
        if dir.Magnitude > 0 then root.CFrame = root.CFrame + dir.Unit * S.FlySpeed * dt end
    end)
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloaded or not S.InfJump then return end
    local _, _, hum = myChar()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

--// esp ----------------------------------------------------------------------

local Highlights = {}

local function clearEsp(kind)
    for key, hl in pairs(Highlights) do
        if not kind or key:sub(1, #kind) == kind then
            pcall(function() hl:Destroy() end)
            Highlights[key] = nil
        end
    end
end

local function espSet(kind, targets, color)
    local seen = {}
    for _, target in ipairs(targets) do
        local key = kind .. tostring(target)
        seen[key] = true
        if not Highlights[key] and target:IsDescendantOf(Workspace) then
            local hl = Instance.new("Highlight")
            hl.FillColor = color
            hl.FillTransparency = 0.6
            hl.OutlineColor = color
            hl.Adornee = target
            hl.Parent = target
            Highlights[key] = hl
        end
    end
    for key, hl in pairs(Highlights) do
        if key:sub(1, #kind) == kind and not seen[key] then
            pcall(function() hl:Destroy() end)
            Highlights[key] = nil
        end
    end
end

task.spawn(function()
    while not Unloaded do
        if S.EspItems then
            local folder = itemsFolder()
            espSet("item_", folder and folder:GetChildren() or {}, Color3.fromRGB(120, 200, 255))
        else
            clearEsp("item_")
        end
        if S.EspTokens then
            local folder = tokensFolder()
            espSet("token_", folder and folder:GetChildren() or {}, Color3.fromRGB(255, 215, 90))
        else
            clearEsp("token_")
        end
        if S.EspEnemies then
            local folder = Workspace:FindFirstChild("Enemies")
            espSet("enemy_", folder and folder:GetChildren() or {}, Color3.fromRGB(255, 90, 90))
        else
            clearEsp("enemy_")
        end
        task.wait(0.5)
    end
end)

--// teleports ----------------------------------------------------------------

local SPOTS = {
    ["Token shop"] = function() return node(Workspace, "Map", "Util", "TokenShop") end,
    ["Cauldron"] = function() return node(Workspace, "Map", "Util", "Cauldron") end,
    ["Start"] = function() return node(Workspace, "Map", "Util", "StartGamePart") end,
    ["Exit"] = function() return node(Workspace, "Map", "Util", "MiscPoints", "ExitGamePart") end,
}

local function spotCFrame(getter)
    local ok, inst = pcall(getter)
    if not ok or not inst then return nil end
    if inst:IsA("BasePart") then return inst.CFrame end
    return inst:GetPivot()
end

--// anti-AFK -----------------------------------------------------------------

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    if on then
        for _, c in ipairs(list) do pcall(function() c:Disable() IdleOff[#IdleOff + 1] = c end) end
    else
        for _, c in ipairs(IdleOff) do pcall(function() c:Enable() end) end
        table.clear(IdleOff)
    end
    return true
end
task.delay(3, function() if S.AntiAfk and not Unloaded then setAntiAfk(true) end end)

--// teardown -----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    pcall(setAntiAfk, false)
    clearEsp(nil)
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)
    pcall(function()
        local _, _, hum = myChar()
        if hum and S.Speed then hum.WalkSpeed = 16 end
    end)
end

Genv.__SurviveOvernightStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui -----------------------------------------------------------------------

local okLib, lib = pcall(function()
    return loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()
end)
if not okLib or type(lib) ~= "table" then return end
Library = lib

local Window = Library:CreateWindow({
    Title = 'Survive Overnight',
    Footer = "Velstorm's",
    Icon = 'moon',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'SurviveOvernight',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

local function toggle(box, id, text, key, tooltip, onChange)
    return box:AddToggle(id, {
        Text = text,
        Tooltip = tooltip,
        Default = S[key],
        Callback = function(v)
            S[key] = v
            if onChange then onChange(v) end
        end,
    })
end

--// Farm tab -----------------------------------------------------------------

do
    local Tab = Window:AddTab('Farm', 'package', 'Looting and resources')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('so_cards', {
        Cards = {
            { Title = 'Health', Value = '-', Icon = 'heart' },
            { Title = 'Energy', Value = '-', Icon = 'battery' },
            { Title = 'Stamina', Value = '-', Icon = 'wind' },
            { Title = 'Enemies', Value = '0', Icon = 'skull' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(0.5, function()
        local _, _, hum = myChar()
        local function pct(name, maxName)
            local p = statPercent(name, maxName)
            return p and (math.floor(p) .. '%') or '-'
        end
        cards:SetValue('Health', hum and hum.MaxHealth > 0 and (math.floor(hum.Health / hum.MaxHealth * 100) .. '%') or '-')
        cards:SetValue('Energy', pct('Energy', 'MaxEnergy'))
        cards:SetValue('Stamina', pct('Stamina', 'MaxStamina'))
        local enemies = Workspace:FindFirstChild("Enemies")
        cards:SetValue('Enemies', tostring(enemies and #enemies:GetChildren() or 0))
        info:SetText(("%s\nlooted: %d   hits sent: %d"):format(Stats.Status, Stats.Looted, Stats.Hits))
    end)

    local loot = Tab:AddLeftGroupbox('Looting', 'hand-coins')
    toggle(loot, 'so_items', 'Auto collect items', 'CollectItems', 'claims every item on the map (flashlights, planks, weapons, food...)')
    toggle(loot, 'so_tokens', 'Auto collect tokens', 'CollectTokens', 'grabs tokens as they spawn')
    toggle(loot, 'so_presents', 'Auto open presents', 'OpenPresents', 'opens every Christmas present in reach')
    loot:AddButton({ Text = 'Collect items now', Func = function() task.spawn(collectItems) end })

    local res = Tab:AddRightGroupbox('Resources', 'axe')
    res:AddLabel('Hold a weapon. This attacks breakable objects (shelves, pallets, crates, pumpkins) for Wood/Cloth/Metal.', true)
    toggle(res, 'so_harvest', 'Auto harvest resources', 'Harvest', 'swings your weapon at every damageable object in range')
    res:AddSlider('so_harvest_range', { Text = 'Range', Min = 20, Max = 200, Default = S.HarvestRange, Rounding = 0, Callback = function(v) S.HarvestRange = v end })
end

--// Combat tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Combat', 'swords', 'Kill aura')

    local aura = Tab:AddLeftGroupbox('Kill aura', 'crosshair')
    aura:AddLabel('Hold a gun or melee weapon. Damage is sent the same way a real hit is, so this works at range on every enemy.', true)
    toggle(aura, 'so_aura', 'Kill aura', 'KillAura', 'hits every enemy in range with your equipped weapon')
        :AddKeyPicker('so_aura_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Kill aura' })
    aura:AddSlider('so_aura_range', { Text = 'Range', Min = 20, Max = 300, Default = S.AuraRange, Rounding = 0, Callback = function(v) S.AuraRange = v end })
    aura:AddSlider('so_aura_delay', { Text = 'Attack delay', Tooltip = 'time between swings; lower hits faster', Min = 0.05, Max = 1, Default = S.AttackDelay, Rounding = 2, Suffix = 's', Callback = function(v) S.AttackDelay = v end })
end

--// Craft & Shop tab ---------------------------------------------------------

do
    local Tab = Window:AddTab('Craft', 'hammer', 'Crafting and token shop')

    local craftBox = Tab:AddLeftGroupbox('Auto craft', 'wrench')
    craftBox:AddLabel('Server checks your resources. Tier-1 recipes need a placed Crafting Table nearby.', true)
    toggle(craftBox, 'so_craft', 'Auto craft ticked', 'Craft', 'keeps trying to craft every ticked recipe')
    for _, name in ipairs(CRAFT_ALL) do
        craftBox:AddToggle('so_craft_' .. name, {
            Text = name .. (CRAFT_T1_SET[name] and ' (T1)' or ''),
            Default = false,
            Callback = function(v) S.CraftList[name] = v end,
        })
    end

    local shop = Tab:AddRightGroupbox('Token shop', 'shopping-cart')
    toggle(shop, 'so_shop', 'Auto buy ticked', 'ShopBuy', 'buys each ticked item when you have the tokens and are near the shop')
    for _, name in ipairs(SHOP_ITEMS) do
        shop:AddToggle('so_shop_' .. name, { Text = name, Default = false, Callback = function(v) S.ShopList[name] = v end })
    end
    shop:AddButton({ Text = 'Teleport to shop', Func = function() teleportTo(spotCFrame(SPOTS['Token shop'])) end })
end

--// Survival tab -------------------------------------------------------------

do
    local Tab = Window:AddTab('Survival', 'heart-pulse', 'Eat, heal, revive')

    local needs = Tab:AddLeftGroupbox('Needs', 'utensils')
    toggle(needs, 'so_eat', 'Auto eat / drink', 'AutoEat', 'uses a food, drink or candy when energy drops')
    needs:AddSlider('so_eat_at', { Text = 'Eat below', Min = 10, Max = 90, Default = S.EatAt, Rounding = 0, Suffix = '%', Callback = function(v) S.EatAt = v end })
    toggle(needs, 'so_heal', 'Auto heal', 'AutoHeal', 'uses a medkit or bandage when health drops')
    needs:AddSlider('so_heal_at', { Text = 'Heal below', Min = 10, Max = 90, Default = S.HealAt, Rounding = 0, Suffix = '%', Callback = function(v) S.HealAt = v end })
    toggle(needs, 'so_stamina', 'Infinite stamina', 'InfStamina', 'keeps stamina topped so you never stop sprinting')

    local team = Tab:AddRightGroupbox('Team', 'users')
    toggle(team, 'so_revive', 'Auto revive teammates', 'AutoRevive', 'holds a medkit/bandage, goes to a downed teammate and revives them')
end

--// Player tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Player', 'user', 'Movement, ESP, teleports')

    local move = Tab:AddLeftGroupbox('Movement', 'footprints')
    toggle(move, 'so_speed', 'Walk speed', 'Speed')
    move:AddSlider('so_speedv', { Text = 'Speed', Min = 16, Max = 150, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'so_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'so_noclip', 'Noclip', 'Noclip')
    toggle(move, 'so_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('so_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('so_flyspeed', { Text = 'Fly speed', Min = 10, Max = 250, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })

    local esp = Tab:AddRightGroupbox('ESP', 'eye')
    toggle(esp, 'so_esp_items', 'Items', 'EspItems')
    toggle(esp, 'so_esp_tokens', 'Tokens', 'EspTokens')
    toggle(esp, 'so_esp_enemies', 'Enemies', 'EspEnemies')

    local tp = Tab:AddRightGroupbox('Teleport', 'map-pin')
    for _, name in ipairs({ "Token shop", "Cauldron", "Start", "Exit" }) do
        tp:AddButton({ Text = name, Func = function() teleportTo(spotCFrame(SPOTS[name])) end })
    end

    local idle = Tab:AddLeftGroupbox('Idle', 'clock')
    idle:AddToggle('so_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the 20 minute idle kick',
        Default = S.AntiAfk,
        Callback = function(v) S.AntiAfk = v setAntiAfk(v) end,
    })
end

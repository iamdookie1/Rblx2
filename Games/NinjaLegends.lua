--// Ninja Legends -- auto swing, customizable auto sell, buy-all, ranks,
--// chests, coins/chi, hoops, souls, crystals, pets, bosses, islands and more.
--
-- Built against a script dump of the live game (place 3956818381, game
-- 1335695570, version 1096). Everything goes through the game's own remotes:
--
--  * Players.<you>.ninjaEvent takes plain commands: "swingKatana" (what the
--    sword's Activated fires), "buySword"/"buyAllSwords" and the same for
--    belts, shurikens, skills, ranks, light/dark skills (the buy-all ones take
--    a shop's areaName, from workspace.shopAreaCircles / skillAreaCircles),
--    "equipSword"/"equipBelt"/..., and "goInvisible".
--  * Selling is touching a sell circle (workspace.sellAreaCircles.*.circleInner).
--    Your bag size is globalFunctions.getBeltCapacity(player), which is how
--    "sell when full" knows you're full.
--  * Chests are touched circles too (workspace.<x>Chest.circleInner) and the
--    claim is rEvents.checkChestRemote:InvokeServer("<X> Chest").
--  * Coins and chi spawn under workspace.spawnedCoins and are picked up by
--    touch; hoops are rEvents.hoopEvent "useHoop"; souls are soulEvent
--    "collectSoul"; crystals are openCrystalRemote "openCrystal"; pets go
--    through autoEvolveRemote, sellPetEvent and equipPetEvent; islands
--    through areaTravelRemote "travelToArea" with an areaCircles entry, and
--    are unlocked by touching workspace.islandUnlockParts.
--  * Bosses (workspace.bossFolder) take damage from sword swings next to
--    them, so the boss farm stands you by one and swings.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__NinjaLegendsStop) == "function" then pcall(Genv.__NinjaLegendsStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(c) Connections[#Connections + 1] = c return c end

local function loop(interval, fn)
    task.spawn(function()
        while not Unloaded do
            pcall(fn)
            task.wait(type(interval) == "function" and interval() or interval)
        end
    end)
end

--// settings ----------------------------------------------------------------

local S = {
    -- farm
    Swing = false,
    SwingDelay = 0.05,
    -- auto sell
    Sell = false,
    SellMode = "When full",   -- When full / At % full / At amount / Every X seconds
    SellPercent = 90,
    SellAmount = 1e6,
    SellEvery = 5,
    SellSpot = "Nearest",     -- Nearest / a circle's name
    SellBack = true,          -- put you back where you were
    PauseSwingToSell = false, -- stop swinging while a sell is going
    -- pickups
    Coins = false,
    Hoops = false,
    Souls = false,
    -- upgrades
    BuySwords = false,
    BuyBelts = false,
    BuyShurikens = false,
    BuySkills = false,
    BuyRanks = false,
    BuyLightDark = false,
    Dojo = false,
    DojoCollect = false,
    Elements = false,
    -- pets
    Crystal = nil,
    OpenCrystals = false,
    AutoEvolve = false,
    -- rewards
    Chests = false,
    Wheel = false,
    Group = false,
    -- islands / bosses
    UnlockIslands = false,
    Boss = false,
    BossName = nil,
    Duels = false,
    -- player
    Invisible = false,
    Speed = false,
    SpeedValue = 60,
    Jump = false,
    JumpValue = 120,
    Noclip = false,
    Fly = false,
    FlySpeed = 80,
    InfJump = false,
    AntiAfk = true,
}

local Stats = { Started = os.clock(), Ninjitsu0 = nil, Coins0 = nil, Sells = 0, Status = "idle" }
local Library

--// the game's remotes -------------------------------------------------------

local rEvents = ReplicatedStorage:WaitForChild("rEvents", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, r = pcall(require, inst)
    return ok and r or nil
end
local GF = safeRequire(ReplicatedStorage:FindFirstChild("globalFunctions"))

local function ninjaEvent()
    return LocalPlayer:FindFirstChild("ninjaEvent")
end

local function fireNinja(...)
    local r = ninjaEvent()
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
end

local function remote(name)
    return rEvents and rEvents:FindFirstChild(name)
end

local function fire(name, ...)
    local r = remote(name)
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
end

local function invoke(name, ...)
    local r = remote(name)
    if not r then return nil end
    local ok, a, b, c = pcall(r.InvokeServer, r, ...)
    if ok then return a, b, c end
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

local function stat(name)
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local v = (ls and ls:FindFirstChild(name)) or LocalPlayer:FindFirstChild(name)
    return v and v.Value or nil
end

local function capacity()
    if GF and GF.getBeltCapacity then
        local ok, cap = pcall(GF.getBeltCapacity, LocalPlayer)
        if ok and tonumber(cap) then return tonumber(cap) end
    end
    return nil
end

local function short(n)
    n = tonumber(n)
    if not n or n ~= n then return "-" end
    if math.abs(n) == math.huge then return "inf" end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n /= 1000 i += 1 end
    if math.abs(n) >= 1000 then return ("%.2e"):format(n * 1000 ^ (i - 1)) end
    return (i == 1 and tostring(math.floor(n)) or ("%.2f"):format(n)) .. units[i]
end

local function touch(part)
    local _, root = myChar()
    if not part or not root then return false end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, part, 0)
        task.wait()
        pcall(firetouchinterest, root, part, 1)
        return true
    end
    -- no firetouchinterest: step onto it and back
    local back = root.CFrame
    pcall(function() root.CFrame = part.CFrame + Vector3.new(0, 3, 0) end)
    task.wait(0.2)
    pcall(function() root.CFrame = back end)
    return true
end

local function teleportTo(cf)
    local char = LocalPlayer.Character
    if char and cf then pcall(function() char:PivotTo(cf + Vector3.new(0, 4, 0)) end) end
end

local function partOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

--// swinging ----------------------------------------------------------------
-- the sword's own script fires "swingKatana" when it's activated, so the
-- sword is kept in hand and the same command is sent.

-- the backpack also holds your shuriken and invisibility, so the sword is
-- found by the name in equippedSword
local function swordTool()
    local equipped = LocalPlayer:FindFirstChild("equippedSword")
    local name = equipped and equipped.Value and equipped.Value.Name
    if not name then return nil end
    local char = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    for _, container in ipairs({ char, backpack }) do
        local t = container and container:FindFirstChild(name)
        if t and t:IsA("Tool") then return t end
    end
    return nil
end

local function holdSword()
    local char, _, hum = myChar()
    local sword = swordTool()
    if char and sword and sword.Parent ~= char then pcall(function() hum:EquipTool(sword) end) end
    return sword
end

local Selling = false

loop(function() return S.SwingDelay end, function()
    if not S.Swing or (Selling and S.PauseSwingToSell) then return end
    if not myChar() then return end
    holdSword()
    fireNinja("swingKatana")
end)

--// auto sell ---------------------------------------------------------------

local function sellCircles()
    local folder = Workspace:FindFirstChild("sellAreaCircles")
    local list = {}
    for _, m in ipairs(folder and folder:GetChildren() or {}) do
        local inner = m:FindFirstChild("circleInner")
        if inner and inner:IsA("BasePart") then list[#list + 1] = { Name = m.Name, Part = inner } end
    end
    table.sort(list, function(a, b) return a.Name < b.Name end)
    return list
end

local function sellPart()
    local list = sellCircles()
    if S.SellSpot ~= "Nearest" then
        for _, c in ipairs(list) do if c.Name == S.SellSpot then return c.Part end end
    end
    local _, root = myChar()
    local best, bestD
    for _, c in ipairs(list) do
        local d = root and (c.Part.Position - root.Position).Magnitude or 0
        if not bestD or d < bestD then best, bestD = c.Part, d end
    end
    return best
end

local function sellNow()
    local part = sellPart()
    local _, root = myChar()
    if not part or not root then return false end
    Selling = true
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, part, 0)
        task.wait(0.1)
        pcall(firetouchinterest, root, part, 1)
    else
        local back = root.CFrame
        pcall(function() root.CFrame = part.CFrame + Vector3.new(0, 3, 0) end)
        task.wait(0.3)
        if S.SellBack then pcall(function() root.CFrame = back end) end
    end
    Selling = false
    Stats.Sells += 1
    return true
end

local function shouldSell()
    local ninjitsu = tonumber(stat("Ninjitsu")) or 0
    if ninjitsu <= 0 then return false end
    local cap = capacity()
    if S.SellMode == "When full" then
        return cap ~= nil and ninjitsu >= cap
    elseif S.SellMode == "At % full" then
        return cap ~= nil and cap > 0 and ninjitsu / cap * 100 >= S.SellPercent
    elseif S.SellMode == "At amount" then
        return ninjitsu >= S.SellAmount
    end
    return false
end

local lastTimedSell = 0
loop(0.2, function()
    if not S.Sell then return end
    if S.SellMode == "Every X seconds" then
        if os.clock() - lastTimedSell >= S.SellEvery then
            lastTimedSell = os.clock()
            sellNow()
        end
    elseif shouldSell() then
        sellNow()
        task.wait(0.3)
    end
end)

--// coins, chi, hoops, souls --------------------------------------------------

loop(0.3, function()
    if not S.Coins then return end
    local folder = Workspace:FindFirstChild("spawnedCoins")
    for _, d in ipairs(folder and folder:GetDescendants() or {}) do
        if not S.Coins then break end
        if d:IsA("BasePart") then touch(d) end
    end
end)

loop(1, function()
    if not S.Hoops then return end
    local hoops = Workspace:FindFirstChild("Hoops")
    for _, hoop in ipairs(hoops and hoops:GetChildren() or {}) do
        if not S.Hoops then break end
        if not hoop:FindFirstChild("wasUsed") then
            fire("hoopEvent", "useHoop", hoop)
            local p = partOf(hoop)
            if p then touch(p) end
        end
    end
end)

loop(0.5, function()
    if not S.Souls then return end
    -- each soul has a "collectSoulGui" billboard in PlayerGui, adorned to it;
    -- the server wants you within reach, so you're stepped over to it
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    for _, d in ipairs(gui and gui:GetChildren() or {}) do
        if not S.Souls then break end
        if d:IsA("BillboardGui") and d.Name == "collectSoulGui" and d.Adornee and not d.Adornee:FindFirstChild("collected") then
            local _, root = myChar()
            if root then
                local back = root.CFrame
                teleportTo(d.Adornee.CFrame)
                task.wait(0.1)
                fire("soulEvent", "collectSoul", d.Adornee)
                task.wait(0.1)
                pcall(function() root.CFrame = back end)
            end
        end
    end
end)

--// buying -------------------------------------------------------------------

local function areaNames(folderName)
    local folder = Workspace:FindFirstChild(folderName)
    local names, seen = {}, {}
    for _, c in ipairs(folder and folder:GetChildren() or {}) do
        local v = c:FindFirstChild("areaName")
        if v and v.Value ~= "" and not seen[v.Value] then
            seen[v.Value] = true
            names[#names + 1] = v.Value
        end
    end
    if #names == 0 then names = { "Ground" } end
    return names
end

loop(3, function()
    if S.BuySwords or S.BuyBelts or S.BuyShurikens then
        for _, area in ipairs(areaNames("shopAreaCircles")) do
            if S.BuySwords then fireNinja("buyAllSwords", area) end
            if S.BuyBelts then fireNinja("buyAllBelts", area) end
            if S.BuyShurikens then fireNinja("buyAllShurikens", area) end
            task.wait(0.1)
        end
    end
    if S.BuySkills then
        for _, area in ipairs(areaNames("skillAreaCircles")) do
            fireNinja("buyAllSkills", area)
            task.wait(0.1)
        end
    end
end)

-- ranks, light and dark skills have no buy-all: each is bought by name, in
-- order, out of the game's own data folders
local function namesIn(folderName)
    local root = ReplicatedStorage:FindFirstChild(folderName)
    local out = {}
    for _, d in ipairs(root and root:GetDescendants() or {}) do
        local order = d:FindFirstChild("whichOrder") or d:FindFirstChild("price")
        if order then out[#out + 1] = { Name = d.Name, Order = tonumber(order.Value) or 0 } end
    end
    table.sort(out, function(a, b) return a.Order < b.Order end)
    return out
end

loop(5, function()
    if S.BuyRanks then
        for _, r in ipairs(namesIn("Ranks")) do fireNinja("buyRank", r.Name) task.wait(0.05) end
    end
    if S.BuyLightDark then
        for _, r in ipairs(namesIn("Light Skills")) do fireNinja("buyLightSkill", r.Name) task.wait(0.05) end
        for _, r in ipairs(namesIn("Dark Skills")) do fireNinja("buyDarkSkill", r.Name) task.wait(0.05) end
    end
end)

--// dojo, elements -------------------------------------------------------------

loop(3, function()
    local circles = Workspace:FindFirstChild("dojoCircles")
    if not circles then return end
    if S.Dojo then
        for _, c in ipairs(circles:GetChildren()) do
            if c.Name ~= "dojoCollectCircle" then invoke("upgradeDojoTrainerRemote", "upgradeTrainer", c.Name) task.wait(0.1) end
        end
    end
    if S.DojoCollect then
        local collect = circles:FindFirstChild("dojoCollectCircle")
        touch(collect and collect:FindFirstChild("circleInner"))
    end
end)

local function elementNames()
    local out, seen = {}, {}
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d.Name == "elementName" and d:IsA("StringValue") and not seen[d.Value] then
            seen[d.Value] = true
            out[#out + 1] = d.Value
        end
    end
    return out
end

loop(10, function()
    if not S.Elements then return end
    for _, name in ipairs(elementNames()) do fire("elementMasteryEvent", name) task.wait(0.2) end
end)

--// pets ---------------------------------------------------------------------

local function crystalNames()
    local folder = Workspace:FindFirstChild("mapCrystalsFolder")
    local out = {}
    for _, c in ipairs(folder and folder:GetChildren() or {}) do out[#out + 1] = c.Name end
    table.sort(out)
    return out
end

loop(0.5, function()
    if S.OpenCrystals and S.Crystal then invoke("openCrystalRemote", "openCrystal", S.Crystal) end
end)

loop(5, function()
    if S.AutoEvolve then invoke("autoEvolveRemote", "autoEvolvePets") end
end)

--// rewards ------------------------------------------------------------------

local function chestList()
    local out = {}
    for _, m in ipairs(Workspace:GetChildren()) do
        if m.Name:match("Chest$") and m:FindFirstChild("circleInner") then
            local display = m.Name:gsub("(%u)", " %1"):gsub("^%l", string.upper)
            out[#out + 1] = { Part = m.circleInner, Name = display }
        end
    end
    return out
end

local function claimChests()
    for _, c in ipairs(chestList()) do
        touch(c.Part)
        invoke("checkChestRemote", c.Name)
        task.wait(0.2)
    end
end

loop(30, function()
    if S.Chests then claimChests() end
end)

loop(15, function()
    if S.Wheel then
        local wheel = Workspace:FindFirstChild("Fortune Wheel")
        if wheel then invoke("openFortuneWheelRemote", "openFortuneWheel", wheel) end
    end
    if S.Group then invoke("groupRemote", "groupRewards") end
end)

local KNOWN_CODES = { "zenmaster15k", "christmasninja500", "dojoninja500", "ninjasensei1k", "legends700m", "epicelements", "skyblades1m", "shadowninja1k" }

local function redeem(code)
    local ok, msg = invoke("codeRemote", code)
    return ok, msg
end

--// islands, bosses, duels -----------------------------------------------------

local function islandAreas()
    local folder = Workspace:FindFirstChild("areaCircles")
    local out = {}
    for _, c in ipairs(folder and folder:GetChildren() or {}) do
        local name = c:FindFirstChild("areaName")
        out[#out + 1] = { Name = name and name.Value or c.Name, Obj = c }
    end
    return out
end

loop(5, function()
    if not S.UnlockIslands then return end
    local parts = Workspace:FindFirstChild("islandUnlockParts")
    for _, p in ipairs(parts and parts:GetChildren() or {}) do
        if p:IsA("BasePart") then touch(p) task.wait(0.1) end
    end
end)

local function bosses()
    local folder = Workspace:FindFirstChild("bossFolder")
    local out = {}
    for _, b in ipairs(folder and folder:GetChildren() or {}) do
        local hum = b:FindFirstChildOfClass("Humanoid")
        local part = b:FindFirstChild("HumanoidRootPart") or partOf(b)
        if part and (not hum or hum.Health > 0) then out[#out + 1] = { Name = b.Name, Part = part } end
    end
    return out
end

loop(0.1, function()
    if not S.Boss then return end
    local target
    for _, b in ipairs(bosses()) do
        if not S.BossName or S.BossName == "Any" or b.Name == S.BossName then target = b break end
    end
    if not target then Stats.Status = "no boss up" return end
    local _, root = myChar()
    if not root then return end
    root.CFrame = target.Part.CFrame * CFrame.new(0, 0, 5)
    root.AssemblyLinearVelocity = Vector3.zero
    holdSword()
    fireNinja("swingKatana")
    Stats.Status = "hitting " .. target.Name
end)

loop(10, function()
    if S.Duels then
        local r = remote("duelEvent")
        if r then pcall(r.FireServer, r, "joinDuel") end
    end
end)

--// player -------------------------------------------------------------------

loop(5, function()
    if S.Invisible then fireNinja("goInvisible") end
end)

track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    local _, _, hum = myChar()
    if not hum then return end
    if S.Speed and hum.WalkSpeed ~= S.SpeedValue then hum.WalkSpeed = S.SpeedValue end
    if S.Jump then
        hum.UseJumpPower = true
        if hum.JumpPower ~= S.JumpValue then hum.JumpPower = S.JumpValue end
    end
end))

track(RunService.Stepped:Connect(function()
    if Unloaded or not S.Noclip then return end
    local char = LocalPlayer.Character
    for _, p in ipairs(char and char:GetDescendants() or {}) do
        if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
    end
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
            local flat = Vector3.new(look.LookVector.X, 0, look.LookVector.Z)
            local fwd = flat.Magnitude > 0 and flat.Unit or Vector3.new(0, 0, -1)
            dir = move + Vector3.new(0, look.LookVector.Y * move:Dot(fwd), 0)
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

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return end
    if on then
        for _, c in ipairs(list) do pcall(function() c:Disable() IdleOff[#IdleOff + 1] = c end) end
    else
        for _, c in ipairs(IdleOff) do pcall(function() c:Enable() end) end
        table.clear(IdleOff)
    end
end
task.delay(3, function() if S.AntiAfk and not Unloaded then setAntiAfk(true) end end)

--// teardown -----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    pcall(setAntiAfk, false)
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)
    pcall(function()
        local _, _, hum = myChar()
        if hum and S.Speed then hum.WalkSpeed = (GF and GF.defaultWalkSpeed) or 21 end
    end)
end

Genv.__NinjaLegendsStop = function()
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
    Title = 'Ninja Legends',
    Footer = 'auto farm',
    Icon = 'swords',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'NinjaLegends',
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

--// Farm tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Farm', 'swords', 'Swinging and selling')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('nl_cards', {
        Cards = {
            { Title = 'Ninjitsu', Value = '-', Icon = 'zap' },
            { Title = 'Coins', Value = '-', Icon = 'coins' },
            { Title = 'Chi', Value = '-', Icon = 'sparkles' },
            { Title = 'Bag', Value = '-', Icon = 'backpack' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(1, function()
        local nin = tonumber(stat("Ninjitsu")) or 0
        local coins = tonumber(stat("Coins")) or 0
        local cap = capacity()
        cards:SetValue('Ninjitsu', short(nin))
        cards:SetValue('Coins', short(coins))
        cards:SetValue('Chi', short(stat("Chi")))
        cards:SetValue('Bag', cap and (("%s / %s"):format(short(nin), short(cap))) or '-')
        info:SetText(("rank: %s   karma: %s   souls: %s\nsells: %d   %s"):format(
            tostring(stat("Rank") or "-"), short(stat("Karma")), short(stat("Souls")), Stats.Sells, Stats.Status))
    end)

    local swing = Tab:AddLeftGroupbox('Swing', 'sword')
    toggle(swing, 'nl_swing', 'Auto swing', 'Swing', 'keeps your sword out and swings it for Ninjitsu')
        :AddKeyPicker('nl_swing_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto swing' })
    swing:AddSlider('nl_swing_delay', { Text = 'Swing delay', Tooltip = 'the server only counts swings as fast as your sword allows', Min = 0, Max = 1, Default = S.SwingDelay, Rounding = 2, Suffix = 's', Callback = function(v) S.SwingDelay = v end })

    local sell = Tab:AddRightGroupbox('Auto sell', 'badge-dollar-sign')
    toggle(sell, 'nl_sell', 'Auto sell', 'Sell', 'sells your Ninjitsu by the rule below')
        :AddKeyPicker('nl_sell_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto sell' })
    sell:AddDropdown('nl_sell_mode', {
        Values = { 'When full', 'At % full', 'At amount', 'Every X seconds' },
        Default = S.SellMode,
        Text = 'Sell',
        Callback = function(v) S.SellMode = v end,
    })
    sell:AddSlider('nl_sell_pct', { Text = '% full (for "At % full")', Min = 1, Max = 100, Default = S.SellPercent, Rounding = 0, Suffix = '%', Callback = function(v) S.SellPercent = v end })
    sell:AddInput('nl_sell_amount', {
        Text = 'Amount (for "At amount")',
        Default = tostring(S.SellAmount),
        Placeholder = 'e.g. 1e9 or 500000',
        Numeric = false,
        Finished = true,
        Callback = function(v) S.SellAmount = tonumber(v) or S.SellAmount end,
    })
    sell:AddSlider('nl_sell_every', { Text = 'Seconds (for "Every X seconds")', Min = 0.5, Max = 60, Default = S.SellEvery, Rounding = 1, Suffix = 's', Callback = function(v) S.SellEvery = v end })
    local spots = { 'Nearest' }
    for _, c in ipairs(sellCircles()) do spots[#spots + 1] = c.Name end
    sell:AddDropdown('nl_sell_spot', { Values = spots, Default = 'Nearest', Text = 'Sell circle', Callback = function(v) S.SellSpot = v end })
    toggle(sell, 'nl_sell_back', 'Go back after selling', 'SellBack', 'only matters when your executor has no firetouchinterest and you get moved to the circle')
    toggle(sell, 'nl_sell_pause', 'Pause swinging while selling', 'PauseSwingToSell')
    sell:AddButton({ Text = 'Sell now', Func = function() task.spawn(sellNow) end })

    local pick = Tab:AddLeftGroupbox('Pickups', 'magnet')
    toggle(pick, 'nl_coins', 'Auto collect coins and chi', 'Coins')
    toggle(pick, 'nl_hoops', 'Auto hoops', 'Hoops')
    toggle(pick, 'nl_souls', 'Auto collect souls', 'Souls')
end

--// Upgrades tab -------------------------------------------------------------

do
    local Tab = Window:AddTab('Upgrades', 'arrow-up', 'Buy-all, ranks, dojo')

    local buy = Tab:AddLeftGroupbox('Buy all', 'shopping-cart')
    buy:AddLabel('Buys everything you can afford in every shop, best first.', true)
    toggle(buy, 'nl_swords', 'Swords', 'BuySwords')
    toggle(buy, 'nl_belts', 'Belts', 'BuyBelts')
    toggle(buy, 'nl_shurikens', 'Shurikens', 'BuyShurikens')
    toggle(buy, 'nl_skills', 'Skills', 'BuySkills')
    toggle(buy, 'nl_ranks', 'Ranks', 'BuyRanks')
    toggle(buy, 'nl_lightdark', 'Light & dark skills', 'BuyLightDark')

    local dojo = Tab:AddRightGroupbox('Dojo & elements', 'landmark')
    toggle(dojo, 'nl_dojo', 'Auto upgrade dojo trainers', 'Dojo')
    toggle(dojo, 'nl_dojo_collect', 'Auto collect dojo Ninjitsu', 'DojoCollect')
    toggle(dojo, 'nl_elements', 'Auto element mastery', 'Elements', 'needs the Master Of Elements skill')

    local zen = Tab:AddRightGroupbox('Zen Master', 'flower')
    zen:AddButton({ Text = 'Convert 10K gems', Func = function() fire("zenMasterEvent", "convertGems", 10000) end })
    zen:AddButton({ Text = 'Convert 1M gems', Func = function() fire("zenMasterEvent", "convertGems", 1000000) end })
    zen:AddButton({ Text = 'Reset karma', Func = function() fire("zenMasterEvent", "resetKarma") end })
end

--// Pets tab -----------------------------------------------------------------

do
    local Tab = Window:AddTab('Pets', 'paw-print', 'Crystals and evolving')

    local box = Tab:AddLeftGroupbox('Crystals', 'gem')
    local names = crystalNames()
    S.Crystal = names[1]
    box:AddDropdown('nl_crystal', { Values = names, Default = names[1], Text = 'Crystal', Callback = function(v) S.Crystal = v end })
    toggle(box, 'nl_open', 'Auto open crystal', 'OpenCrystals')
    box:AddButton({ Text = 'Open once', Func = function() if S.Crystal then invoke("openCrystalRemote", "openCrystal", S.Crystal) end end })

    local evo = Tab:AddRightGroupbox('Evolve', 'sparkle')
    toggle(evo, 'nl_evolve', 'Auto evolve pets', 'AutoEvolve', 'the game\'s own evolve-all')
    evo:AddButton({ Text = 'Evolve now', Func = function() invoke("autoEvolveRemote", "autoEvolvePets") end })
end

--// Rewards tab ----------------------------------------------------------------

do
    local Tab = Window:AddTab('Rewards', 'gift', 'Chests, wheel, codes')

    local chests = Tab:AddLeftGroupbox('Chests', 'package-open')
    toggle(chests, 'nl_chests', 'Auto claim every chest', 'Chests', 'tries each chest every 30s; the server gives what\'s off cooldown', function(v) if v then task.spawn(claimChests) end end)
    chests:AddButton({ Text = 'Claim now', Func = function() task.spawn(claimChests) end })
    toggle(chests, 'nl_wheel', 'Auto spin fortune wheel', 'Wheel')
    toggle(chests, 'nl_group', 'Auto group rewards', 'Group')

    local codes = Tab:AddRightGroupbox('Codes', 'ticket')
    local result = codes:AddLabel('', true)
    codes:AddButton({
        Text = 'Redeem known codes',
        Func = function()
            task.spawn(function()
                local out = {}
                for _, c in ipairs(KNOWN_CODES) do
                    local _, msg = redeem(c)
                    out[#out + 1] = c .. ': ' .. tostring(msg or 'sent')
                end
                result:SetText(table.concat(out, '\n'))
            end)
        end,
    })
    local typed = ''
    codes:AddInput('nl_code', { Text = 'Code', Default = '', Placeholder = 'type a code', Finished = true, Callback = function(v) typed = v end })
    codes:AddButton({ Text = 'Redeem typed code', Func = function() task.spawn(function() local _, msg = redeem(typed) result:SetText(typed .. ': ' .. tostring(msg or 'sent')) end) end })
end

--// World tab ----------------------------------------------------------------

do
    local Tab = Window:AddTab('World', 'map', 'Islands, bosses, duels')

    local isl = Tab:AddLeftGroupbox('Islands', 'mountain')
    toggle(isl, 'nl_unlock', 'Auto unlock islands', 'UnlockIslands', 'touches every island unlock part (the server opens the ones you can afford)')
    local areas = islandAreas()
    local areaNamesList, areaByName = {}, {}
    for _, a in ipairs(areas) do areaNamesList[#areaNamesList + 1] = a.Name areaByName[a.Name] = a.Obj end
    local chosen = areaNamesList[1]
    isl:AddDropdown('nl_island', { Values = areaNamesList, Default = chosen, Text = 'Island', Callback = function(v) chosen = v end })
    isl:AddButton({
        Text = 'Travel there',
        Func = function()
            local obj = areaByName[chosen]
            if obj then
                local ok = invoke("areaTravelRemote", "travelToArea", obj)
                if not ok then teleportTo((partOf(obj) or obj):GetPivot()) end
            end
        end,
    })

    local boss = Tab:AddRightGroupbox('Bosses', 'skull')
    local bossNames = { 'Any' }
    for _, b in ipairs(bosses()) do bossNames[#bossNames + 1] = b.Name end
    boss:AddDropdown('nl_boss', { Values = bossNames, Default = 'Any', Text = 'Boss', Callback = function(v) S.BossName = v end })
    toggle(boss, 'nl_boss_farm', 'Boss farm', 'Boss', 'stands you by the boss and swings')
    toggle(boss, 'nl_duels', 'Auto join duels', 'Duels')
end

--// Player tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Player', 'user', 'Movement and teleports')

    local move = Tab:AddLeftGroupbox('Movement', 'footprints')
    toggle(move, 'nl_speed', 'Walk speed', 'Speed')
    move:AddSlider('nl_speedv', { Text = 'Speed', Min = 16, Max = 300, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'nl_jump', 'Jump power', 'Jump')
    move:AddSlider('nl_jumpv', { Text = 'Jump', Min = 50, Max = 500, Default = S.JumpValue, Rounding = 0, Callback = function(v) S.JumpValue = v end })
    toggle(move, 'nl_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'nl_noclip', 'Noclip', 'Noclip')
    toggle(move, 'nl_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('nl_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('nl_flyspeed', { Text = 'Fly speed', Min = 10, Max = 400, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })
    toggle(move, 'nl_invis', 'Stay invisible', 'Invisible', 'uses the invisibility you own')

    local tp = Tab:AddRightGroupbox('Teleport', 'map-pin')
    tp:AddButton({ Text = 'Nearest sell circle', Func = function() local p = sellPart() if p then teleportTo(p.CFrame) end end })
    tp:AddButton({ Text = 'Dojo', Func = function() local c = Workspace:FindFirstChild("dojoCircles") local p = c and partOf(c:FindFirstChild("dojoCollectCircle")) if p then teleportTo(p.CFrame) end end })
    tp:AddButton({ Text = 'Zen Master', Func = function() local p = partOf(Workspace:FindFirstChild("zenMasterCircle")) if p then teleportTo(p.CFrame) end end })
    tp:AddButton({ Text = 'Fortune wheel', Func = function() local p = partOf(Workspace:FindFirstChild("Fortune Wheel")) if p then teleportTo(p.CFrame) end end })

    local idle = Tab:AddRightGroupbox('Idle', 'clock')
    idle:AddToggle('nl_afk', { Text = 'Anti-AFK', Default = S.AntiAfk, Callback = function(v) S.AntiAfk = v setAntiAfk(v) end })
end

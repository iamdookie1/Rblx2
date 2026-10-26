--// raise a floppa 2 -- auto clicker, rent, petting, unlock buyer, slots,
--// lamp, mail, vault, cooking, planter, teleports and movement.
--
-- Built against a script dump of the live game (place 9772878203, game
-- 3620011279, "raise a floppa 2 [rich roommate]", by FLOPPA#1). What its code
-- shows, and why each feature is built the way it is:
--
--  * Every action is a plain RemoteEvent/RemoteFunction in
--    ReplicatedStorage.Events / .Functions with no caller checks and no client
--    anti-cheat, so money can't be injected -- the server owns every value.
--    The reliable play is to fire the game's own flows exactly as its UI does.
--
--  * CASH. The pet/decor unlocks in workspace.Unlocks (Ms. Floppa, Bingus,
--    Sogga, Baby Floppas, Guard Doge, Jinx, Wawa Cat, Chop, Pop Cat, Gyakko,
--    Floppa Shirts...) each carry a ClickDetector; clicking them is what drops
--    cash. fireclickdetector on every ClickDetector under Unlocks is the auto
--    clicker. Petting Floppa (its "Pet" ProximityPrompt) refills happiness,
--    and workspace.Floppa.HappinessMultiplier scales every drop, so petting is
--    kept topped up alongside the clicker.
--
--  * RENT. Events["Collect Rent"]:FireServer() (no args) when
--    workspace.Unlocks.Roommate["Can Collect"] is true: the server clones
--    ServerStorage.Assets.Rent into workspace as a part you must TOUCH to bank
--    the money (Roommate.CollectRent). So the collector fires the remote then
--    firetouchinterests the spawned part. Events["Raise Rent"]:FireServer()
--    doubles the rent (cap 9.99e17) when "Can Raise" is true. The rich
--    roommate is the same with "Collect Rent 2"/"Raise Rent 2",
--    workspace.Unlocks["Rich Roommate"] and a "Rent 2" part that pays Gold
--    (Amt cap 10000, raise +1).
--
--  * UNLOCKS. Events.Unlock:FireServer(name, "the_interwebs") buys a shop
--    item; the server (Events module) reads Modules.Unlocks[category][name] or
--    falls back to Modules.Unlocks["rebirth unlocks"][name], checks the price
--    and any Requirement.Unlock, so firing the whole ordered list over and
--    over buys everything you can afford as it cascades. Rebirth upgrades are
--    the same remote (they resolve through the rebirth-unlocks fallback).
--
--  * SLOTS. Functions/Events "Slots Spin" take a bet table from Modules.Bets
--    (Money) / "Slots Spin2" from Modules.Super Bets (Gold); the server decides
--    the result, so this is gambling, not a money printer -- off by default.
--
--  * EXTRAS. Events.Save (save now), Events["Magic Lamp"]:FireServer(item)
--    from Modules.LampItems, Events.Mail (claim), Events["Lock Vault"]
--    :FireServer(Host.Value) (toggle the vault lock). Cooking is
--    Events.Cooking:FireServer("Cook"/"Add Ingredient"/...). Planter and the
--    food market are fired through their ProximityPrompts.
--
--  * Rebirth/ascension is a one-way, cinematic money reset driven by the Elder
--    Floppa dialog, so it is NOT automated -- a teleport to the Elder is given
--    so you trigger it yourself. The valuable part, buying rebirth upgrades, is
--    automated above.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__RaiseAFloppa2Stop) == "function" then pcall(Genv.__RaiseAFloppa2Stop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// settings ----------------------------------------------------------------

local S = {
    -- cash
    Click = false,
    ClickDelay = 0.05,
    Pet = false,
    -- rent
    CollectRent = false,
    RaiseRent = false,
    CollectRent2 = false,
    RaiseRent2 = false,
    -- progress
    BuyUnlocks = false,
    BuyRebirth = false,
    AutoSave = false,
    SaveEvery = 60,
    -- extras
    Slots = false,
    SlotsBet = nil,
    SuperSlots = false,
    SuperBet = nil,
    Mail = false,
    Lamp = false,
    LampItem = nil,
    FoodMarket = false,
    Planter = false,
    -- movement
    Speed = false,
    SpeedValue = 40,
    Noclip = false,
    Fly = false,
    FlySpeed = 60,
    InfJump = false,
    AntiAfk = true,
}

local Stats = { Clicks = 0, RentRuns = 0, Started = os.clock(), MoneyStart = nil, Status = "idle" }
local Library

--// the game's remotes -------------------------------------------------------

local Events = ReplicatedStorage:WaitForChild("Events", 30)
local Modules = ReplicatedStorage:WaitForChild("Modules", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    return ok and result or nil
end

local Bets = safeRequire(Modules and Modules:FindFirstChild("Bets")) or {}
local SuperBets = safeRequire(Modules and Modules:FindFirstChild("Super Bets")) or {}
local LampItems = safeRequire(Modules and Modules:FindFirstChild("LampItems")) or {}
local UnlocksData = safeRequire(Modules and Modules:FindFirstChild("Unlocks")) or {}

local function event(name)
    return Events and Events:FindFirstChild(name)
end

local function fire(name, ...)
    local r = event(name)
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
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
    local value = LocalPlayer:FindFirstChild(name)
    return value and value.Value or nil
end

local function multiplier()
    local floppa = Workspace:FindFirstChild("Floppa")
    local m = floppa and floppa:FindFirstChild("HappinessMultiplier")
    return m and m.Value or 1
end

local function hostValue()
    local host = Workspace:FindFirstChild("Host")
    return host and host.Value
end

local function short(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do
        n /= 1000
        i += 1
    end
    return (i == 1 and tostring(math.floor(n)) or ("%.2f"):format(n)) .. units[i]
end

local function teleportTo(cf)
    local char = LocalPlayer.Character
    if char and cf then pcall(function() char:PivotTo(cf + Vector3.new(0, 4, 0)) end) end
end

--// auto clicker -------------------------------------------------------------
-- the pet/decor unlocks each carry a ClickDetector; clicking is what drops
-- cash. fireclickdetector works from any distance and is what the game itself
-- triggers on a click, so the server pays out exactly as a real click would.

local function clickDetectors()
    local unlocks = Workspace:FindFirstChild("Unlocks")
    local list = {}
    for _, child in ipairs(unlocks and unlocks:GetDescendants() or {}) do
        if child:IsA("ClickDetector") then list[#list + 1] = child end
    end
    return list
end

local function clickPass()
    if typeof(fireclickdetector) ~= "function" then
        Stats.Status = "no fireclickdetector in this executor"
        return
    end
    local detectors = clickDetectors()
    if #detectors == 0 then
        Stats.Status = "no clickable floppas yet (buy some pets)"
        return
    end
    for _, detector in ipairs(detectors) do
        if not S.Click or Unloaded then break end
        pcall(fireclickdetector, detector)
        Stats.Clicks += 1
    end
    Stats.Status = ("clicking %d floppas"):format(#detectors)
end

task.spawn(function()
    while not Unloaded do
        if S.Click then clickPass() end
        task.wait(S.ClickDelay)
    end
end)

--// auto pet -----------------------------------------------------------------

local function floppaPetPrompt()
    local floppa = Workspace:FindFirstChild("Floppa")
    local root = floppa and floppa:FindFirstChild("HumanoidRootPart")
    return root and root:FindFirstChildOfClass("ProximityPrompt")
end

task.spawn(function()
    while not Unloaded do
        if S.Pet and typeof(fireproximityprompt) == "function" then
            local prompt = floppaPetPrompt()
            if prompt then pcall(fireproximityprompt, prompt) end
        end
        task.wait(1)
    end
end)

--// rent ---------------------------------------------------------------------
-- fire the collect remote, then touch the part the server spawns so it banks.

local function touchPart(part)
    local _, root = myChar()
    if not part or not root then return end
    if typeof(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, part, 0)
        task.wait()
        pcall(firetouchinterest, root, part, 1)
    else
        -- no touch interest in this executor: step onto it and back.
        local back = root.CFrame
        pcall(function() root.CFrame = part.CFrame + Vector3.new(0, 2, 0) end)
        task.wait(0.15)
        pcall(function() root.CFrame = back end)
    end
end

local function collectRent(node, collectEvent, partName)
    local unlocks = Workspace:FindFirstChild("Unlocks")
    local roommate = unlocks and unlocks:FindFirstChild(node)
    local canCollect = roommate and roommate:FindFirstChild("Can Collect")
    if not (canCollect and canCollect.Value == true) then return false end
    fire(collectEvent)
    -- the server parents the rent part to workspace; grab it and touch it.
    local part
    for _ = 1, 30 do
        part = Workspace:FindFirstChild(partName)
        if part then break end
        task.wait(0.03)
    end
    if part and part:IsA("BasePart") then
        for _ = 1, 3 do
            if not part.Parent then break end
            touchPart(part)
            task.wait(0.05)
        end
    end
    Stats.RentRuns += 1
    return true
end

local function raiseRent(node, raiseEvent, cap)
    local unlocks = Workspace:FindFirstChild("Unlocks")
    local roommate = unlocks and unlocks:FindFirstChild(node)
    local canRaise = roommate and roommate:FindFirstChild("Can Raise")
    local amt = roommate and roommate:FindFirstChild("Amt")
    if canRaise and canRaise.Value == true and amt and amt.Value < cap then
        fire(raiseEvent)
        return true
    end
    return false
end

task.spawn(function()
    while not Unloaded do
        if S.CollectRent then pcall(collectRent, "Roommate", "Collect Rent", "Rent") end
        if S.RaiseRent then pcall(raiseRent, "Roommate", "Raise Rent", 9.99e17) end
        if S.CollectRent2 then pcall(collectRent, "Rich Roommate", "Collect Rent 2", "Rent 2") end
        if S.RaiseRent2 then pcall(raiseRent, "Rich Roommate", "Raise Rent 2", 10000) end
        task.wait(0.5)
    end
end)

--// unlock buyer -------------------------------------------------------------
-- fire the whole ordered list; the server buys what you can afford and meet
-- the requirements for, and refuses the rest, so it cascades as money comes in.

local function orderedUnlocks(category)
    local data = UnlocksData[category]
    local list = {}
    if type(data) == "table" then
        for name, def in pairs(data) do
            if type(def) == "table" and type(name) == "string" then
                list[#list + 1] = { Name = name, Order = tonumber(def.Order) or 9999 }
            end
        end
        table.sort(list, function(a, b) return a.Order < b.Order end)
    end
    return list
end

local INTERWEBS = orderedUnlocks("the_interwebs")
local REBIRTH_UNLOCKS = orderedUnlocks("rebirth unlocks")

local function buyList(list, category)
    for _, item in ipairs(list) do
        if Unloaded then break end
        fire("Unlock", item.Name, category)
        task.wait(0.05)
    end
end

task.spawn(function()
    while not Unloaded do
        if S.BuyUnlocks then buyList(INTERWEBS, "the_interwebs") end
        if S.BuyRebirth then buyList(REBIRTH_UNLOCKS, "the_interwebs") end
        task.wait(2)
    end
end)

--// save ---------------------------------------------------------------------

task.spawn(function()
    while not Unloaded do
        if S.AutoSave then fire("Save") end
        task.wait(S.SaveEvery)
    end
end)

--// slots --------------------------------------------------------------------

local function spinSlots(spinEvent, bet)
    if type(bet) ~= "table" then return end
    fire(spinEvent, bet)
end

task.spawn(function()
    while not Unloaded do
        if S.Slots and S.SlotsBet then spinSlots("Slots Spin", S.SlotsBet) end
        if S.SuperSlots and S.SuperBet then spinSlots("Slots Spin2", S.SuperBet) end
        task.wait(2.5)
    end
end)

--// mail, lamp, food market, planter -----------------------------------------

task.spawn(function()
    while not Unloaded do
        if S.Mail then fire("Mail") end
        if S.Lamp and S.LampItem then fire("Magic Lamp", S.LampItem) end
        task.wait(3)
    end
end)

local function firePromptsUnder(container, actionMatch)
    if typeof(fireproximityprompt) ~= "function" then return end
    for _, child in ipairs(container and container:GetDescendants() or {}) do
        if child:IsA("ProximityPrompt") and child.Enabled then
            if not actionMatch or tostring(child.ActionText):find(actionMatch) then
                pcall(fireproximityprompt, child)
            end
        end
    end
end

task.spawn(function()
    while not Unloaded do
        if S.FoodMarket then
            local village = Workspace:FindFirstChild("Village")
            firePromptsUnder(village and village:FindFirstChild("FoodMarket"), "Purchase")
        end
        if S.Planter then
            local unlocks = Workspace:FindFirstChild("Unlocks")
            firePromptsUnder(unlocks and unlocks:FindFirstChild("Planter"), nil)
            -- Planter is stored as Planter[1..3] models; sweep each.
            for i = 1, 6 do
                firePromptsUnder(unlocks and unlocks:FindFirstChild("Planter[" .. i .. "]"), nil)
            end
        end
        task.wait(1.5)
    end
end)

--// vault --------------------------------------------------------------------

local function toggleVaultLock()
    fire("Lock Vault", hostValue())
end

--// movement ----------------------------------------------------------------

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

--// teleports ----------------------------------------------------------------

local function nodeCFrame(getter)
    local ok, cf = pcall(getter)
    return ok and cf or nil
end

local SPOTS = {
    Floppa = function()
        local floppa = Workspace:FindFirstChild("Floppa")
        return floppa and floppa:GetPivot()
    end,
    Home = function()
        local part = Workspace:FindFirstChild("Key Parts") and Workspace["Key Parts"]:FindFirstChild("Home Teleport")
        return part and part.CFrame
    end,
    ["Interwebs PC"] = function()
        local part = Workspace:FindFirstChild("Key Parts") and Workspace["Key Parts"]:FindFirstChild("PC")
        return part and (part:IsA("BasePart") and part.CFrame or part:GetPivot())
    end,
    ["Food market"] = function()
        local village = Workspace:FindFirstChild("Village")
        local market = village and village:FindFirstChild("FoodMarket")
        return market and market:GetPivot()
    end,
    Altar = function()
        local unlocks = Workspace:FindFirstChild("Unlocks")
        local altar = unlocks and unlocks:FindFirstChild("Altar")
        return altar and altar:GetPivot()
    end,
    Slots = function()
        local unlocks = Workspace:FindFirstChild("Unlocks")
        local slots = unlocks and unlocks:FindFirstChild("Floppa Slots")
        return slots and slots:GetPivot()
    end,
    ["Elder Floppa"] = function()
        local temple = Workspace:FindFirstChild("Temple") or Workspace
        for _, child in ipairs(temple:GetDescendants()) do
            if child.Name == "Elder Floppa" and (child:IsA("Model") or child:IsA("BasePart")) then
                return child:IsA("Model") and child:GetPivot() or child.CFrame
            end
        end
        return nil
    end,
}

--// anti-AFK -----------------------------------------------------------------

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    if on then
        for _, connection in ipairs(list) do
            pcall(function()
                connection:Disable()
                IdleOff[#IdleOff + 1] = connection
            end)
        end
    else
        for _, connection in ipairs(IdleOff) do pcall(function() connection:Enable() end) end
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
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    pcall(function()
        local _, _, hum = myChar()
        if hum and S.Speed then hum.WalkSpeed = 16 end
    end)
end

Genv.__RaiseAFloppa2Stop = function()
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
    Title = 'raise a floppa 2',
    Footer = 'rich roommate',
    Icon = 'cat',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'RaiseAFloppa2',
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

--// Money tab ----------------------------------------------------------------

do
    local Tab = Window:AddTab('Money', 'banknote', 'Clicking, petting and rent')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('raf_cards', {
        Cards = {
            { Title = 'Money', Value = '-', Icon = 'banknote' },
            { Title = 'Gold', Value = '-', Icon = 'coins' },
            { Title = 'Per minute', Value = '-', Icon = 'trending-up' },
            { Title = 'Multiplier', Value = '-', Icon = 'zap' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(1, function()
        local money = tonumber(stat("Money")) or 0
        Stats.MoneyStart = Stats.MoneyStart or money
        local minutes = math.max((os.clock() - Stats.Started) / 60, 1 / 60)
        cards:SetValue('Money', '$' .. short(money))
        cards:SetValue('Gold', short(stat("Gold") or 0))
        cards:SetValue('Per minute', '$' .. short((money - Stats.MoneyStart) / minutes))
        cards:SetValue('Multiplier', ('%sx'):format(multiplier()))
        info:SetText(("%s\nrebirths: %s   year %s, day %s   zone: %s\nclicks sent: %d   rent runs: %d"):format(
            Stats.Status, tostring(stat("Rebirths") or 0), tostring(stat("Year") or "-"),
            tostring(stat("Day") or "-"), tostring(stat("Zone") or "-"), Stats.Clicks, Stats.RentRuns))
    end)

    local cash = Tab:AddLeftGroupbox('Auto cash', 'mouse-pointer-click')
    toggle(cash, 'raf_click', 'Auto click floppas', 'Click', 'clicks every pet/decor click-detector in your house -- that is what drops cash')
        :AddKeyPicker('raf_click_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto click' })
    cash:AddSlider('raf_click_delay', { Text = 'Delay between sweeps', Tooltip = 'lower is faster, higher is lighter on the server', Min = 0, Max = 0.5, Default = S.ClickDelay, Rounding = 2, Suffix = 's', Callback = function(v) S.ClickDelay = v end })
    toggle(cash, 'raf_pet', 'Auto pet Floppa', 'Pet', 'keeps happiness topped up; the happiness multiplier scales every cash drop')

    local rent = Tab:AddRightGroupbox('Rent', 'door-open')
    toggle(rent, 'raf_collect', 'Auto collect rent', 'CollectRent', 'collects the roommate\'s rent and walks onto the payout so it banks')
    toggle(rent, 'raf_raise', 'Auto raise rent', 'RaiseRent', 'doubles the rent whenever the roommate will allow it (cap $999Qi)')
    rent:AddButton({ Text = 'Collect rent now', Func = function() task.spawn(collectRent, "Roommate", "Collect Rent", "Rent") end })
    toggle(rent, 'raf_collect2', 'Auto collect rich rent (Gold)', 'CollectRent2', 'the rich roommate pays Gold; collects and banks it the same way')
    toggle(rent, 'raf_raise2', 'Auto raise rich rent', 'RaiseRent2', 'raises the Gold rent by 1 each time (cap 10,000)')
    rent:AddButton({ Text = 'Collect rich rent now', Func = function() task.spawn(collectRent, "Rich Roommate", "Collect Rent 2", "Rent 2") end })
end

--// Progress tab -------------------------------------------------------------

do
    local Tab = Window:AddTab('Progress', 'trending-up', 'Buying unlocks and saving')

    local buy = Tab:AddLeftGroupbox('Unlock buyer', 'shopping-cart')
    buy:AddLabel(('%d shop items, %d rebirth upgrades. The server only sells what you can afford and have the requirements for, so leave it running.'):format(#INTERWEBS, #REBIRTH_UNLOCKS), true)
    toggle(buy, 'raf_unlocks', 'Auto buy shop unlocks', 'BuyUnlocks', 'fires the whole shop list in order over and over; it buys each item as the money comes in')
    buy:AddButton({ Text = 'Buy all affordable now', Func = function() task.spawn(buyList, INTERWEBS, "the_interwebs") end })
    toggle(buy, 'raf_rebirthbuy', 'Auto buy rebirth upgrades', 'BuyRebirth', 'buys the rebirth-unlock upgrades (needs rebirth currency); does not trigger an ascension itself')
    buy:AddButton({ Text = 'Buy rebirth upgrades now', Func = function() task.spawn(buyList, REBIRTH_UNLOCKS, "the_interwebs") end })

    local save = Tab:AddRightGroupbox('Save', 'save')
    toggle(save, 'raf_save', 'Auto save', 'AutoSave', 'fires the game\'s own save on a timer')
    save:AddSlider('raf_save_every', { Text = 'Save every', Min = 15, Max = 300, Default = S.SaveEvery, Rounding = 0, Suffix = 's', Callback = function(v) S.SaveEvery = v end })
    save:AddButton({ Text = 'Save now', Func = function() fire("Save") end })

    local reb = Tab:AddRightGroupbox('Rebirth', 'refresh-cw')
    reb:AddLabel('Ascending is a one-way money reset driven by the Elder Floppa dialog, so it is left manual. Teleport over and talk to the Elder when you want it.', true)
    reb:AddButton({ Text = 'Teleport to Elder Floppa', Func = function() teleportTo(nodeCFrame(SPOTS['Elder Floppa'])) end })
end

--// Extras tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Extras', 'sparkles', 'Slots, lamp, mail, vault and more')

    local slots = Tab:AddLeftGroupbox('Slots (gamble)', 'dices')
    slots:AddLabel('The server decides the spin, so this can lose money. Off by default.', true)
    local betNames, betByText = {}, {}
    for _, bet in ipairs(Bets) do
        if type(bet) == "table" and bet.Text then
            betNames[#betNames + 1] = bet.Text
            betByText[bet.Text] = bet
        end
    end
    slots:AddDropdown('raf_slots_bet', {
        Values = betNames,
        Default = betNames[1],
        Text = 'Money bet',
        Callback = function(v) S.SlotsBet = betByText[v] end,
    })
    if betNames[1] then S.SlotsBet = betByText[betNames[1]] end
    toggle(slots, 'raf_slots', 'Auto spin (Money)', 'Slots', 'spins the Floppa slots with the selected bet')

    local superNames, superByText = {}, {}
    for _, bet in ipairs(SuperBets) do
        if type(bet) == "table" and bet.Text then
            superNames[#superNames + 1] = bet.Text
            superByText[bet.Text] = bet
        end
    end
    slots:AddDropdown('raf_super_bet', {
        Values = superNames,
        Default = superNames[1],
        Text = 'Gold bet',
        Callback = function(v) S.SuperBet = superByText[v] end,
    })
    if superNames[1] then S.SuperBet = superByText[superNames[1]] end
    toggle(slots, 'raf_superslots', 'Auto spin (Gold)', 'SuperSlots', 'spins the super slots with the selected Gold bet')

    local misc = Tab:AddRightGroupbox('Freebies', 'gift')
    toggle(misc, 'raf_mail', 'Auto claim mail', 'Mail', 'claims the mailbox reward whenever one is waiting')
    misc:AddButton({ Text = 'Claim mail now', Func = function() fire("Mail") end })
    local lampNames = {}
    for name in pairs(LampItems) do lampNames[#lampNames + 1] = name end
    table.sort(lampNames)
    misc:AddDropdown('raf_lamp_item', {
        Values = lampNames,
        Default = lampNames[1],
        Text = 'Magic lamp wish',
        Callback = function(v) S.LampItem = v end,
    })
    if lampNames[1] then S.LampItem = lampNames[1] end
    toggle(misc, 'raf_lamp', 'Auto wish from lamp', 'Lamp', 'keeps asking the lamp for the selected item (the server grants it when a wish is ready)')
    misc:AddButton({ Text = 'Wish now', Func = function() if S.LampItem then fire("Magic Lamp", S.LampItem) end end })

    local vault = Tab:AddRightGroupbox('Vault', 'lock')
    vault:AddButton({ Text = 'Lock / unlock vault', Func = toggleVaultLock })

    local farm = Tab:AddLeftGroupbox('Food & garden', 'sprout')
    toggle(farm, 'raf_food', 'Auto buy food market', 'FoodMarket', 'triggers every food-market stall (ingredients for cooking)')
    toggle(farm, 'raf_planter', 'Auto tend planter', 'Planter', 'fires every planter prompt so seeds get planted/harvested')
    farm:AddButton({ Text = 'Cook current recipe', Func = function() fire("Cooking", "Cook") end })
end

--// Player tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Player', 'user', 'Movement and teleports')

    local move = Tab:AddLeftGroupbox('Movement', 'footprints')
    toggle(move, 'raf_speed', 'Walk speed', 'Speed')
    move:AddSlider('raf_speedv', { Text = 'Speed', Min = 16, Max = 150, Default = S.SpeedValue, Rounding = 0, Callback = function(v) S.SpeedValue = v end })
    toggle(move, 'raf_infjump', 'Infinite jump', 'InfJump')
    toggle(move, 'raf_noclip', 'Noclip', 'Noclip')
    toggle(move, 'raf_fly', 'Fly', 'Fly', 'move with your normal controls, Space up, Ctrl down')
        :AddKeyPicker('raf_fly_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Fly' })
    move:AddSlider('raf_flyspeed', { Text = 'Fly speed', Min = 10, Max = 250, Default = S.FlySpeed, Rounding = 0, Callback = function(v) S.FlySpeed = v end })

    local tp = Tab:AddRightGroupbox('Teleport', 'map-pin')
    for _, name in ipairs({ "Floppa", "Home", "Interwebs PC", "Food market", "Altar", "Slots", "Elder Floppa" }) do
        tp:AddButton({ Text = name, Func = function() teleportTo(nodeCFrame(SPOTS[name])) end })
    end

    local idle = Tab:AddRightGroupbox('Idle', 'clock')
    idle:AddToggle('raf_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the 20 minute idle kick',
        Default = S.AntiAfk,
        Callback = function(v)
            S.AntiAfk = v
            setAntiAfk(v)
        end,
    })
end

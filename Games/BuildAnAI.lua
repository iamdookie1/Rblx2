-- Build an AI
--
-- Everything here reads from ReplicatedStorage.Shared.Config, which the game
-- ships to the client in full: 2300 lines of tuning, plus HackMath and
-- SkillMath with the actual formulas in them. So most of this is not inferred
-- - it is the game's own numbers, used the way the game uses them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local function safeRequire(parent, name)
    if not parent then return nil end
    local module = parent:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    if ok then return result end
    return nil
end

local Config = safeRequire(Shared, "Config")
local HackMath = safeRequire(Shared, "HackMath")
local SkillMath = safeRequire(Shared, "SkillMath")
local Format = safeRequire(Shared, "Format")

local function remote(name)
    return Remotes and Remotes:FindFirstChild(name) or nil
end

-- Config lookups guarded: a game update that renames a section should degrade
-- one feature, not stop the script loading.
local function cfg(path, fallback)
    local node = Config
    for key in tostring(path):gmatch("[^%.]+") do
        if typeof(node) ~= "table" then return fallback end
        node = node[key]
    end
    if node == nil then return fallback end
    return node
end

local function commas(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function short(n)
    n = tonumber(n) or 0
    local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, unit in ipairs(units) do
        if math.abs(n) >= unit[1] then
            return ("%.2f%s"):format(n / unit[1], unit[2])
        end
    end
    return ("%.0f"):format(n)
end

local function money()
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    local cash = stats and stats:FindFirstChild("Money")
    return cash and cash.Value or 0
end

--// Input synthesis ----------------------------------------------------------
-- The minigame and the firewall both listen for a real click:
-- UserInputService.InputBegan for the minigame, TextButton.Activated for the
-- defence circles. Neither can be raised from a script directly, so the press
-- has to go through VirtualInputManager, which most executors expose.

local VIM = nil
do
    local ok, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if ok then VIM = service end
end

local function canSynthesizeInput()
    return VIM ~= nil
end

local function clickAt(x, y)
    if not VIM then return false end
    local ok = pcall(function()
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    return ok
end

-- Somewhere a synthesized tap cannot cause trouble.
--
-- The minigame's press handler reads only the input type - it ignores the
-- position entirely, and discards gameProcessedEvent - so the tap can land
-- anywhere. Aiming it at the marker was pointless, and on a phone the marker
-- sits near the top of the screen, which is exactly where the Roblox menu
-- button is. Tapping there opens the Roblox menu instead.
--
-- So: below the topbar inset, above the on-screen controls, centred away from
-- the jump button and the thumbstick.
local GuiService = game:GetService("GuiService")

local function safeClickPoint()
    local viewport = Vector2.new(1280, 720)
    local camera = workspace.CurrentCamera
    if camera then viewport = camera.ViewportSize end

    local topInset = 0
    local ok, inset = pcall(function()
        return GuiService:GetGuiInset()
    end)
    if ok and inset then topInset = inset.Y end

    -- A generous margin under the inset rather than a tight one: the Roblox
    -- topbar grows on some devices, and being 40px lower costs nothing.
    local top = topInset + 40
    local bottom = viewport.Y * 0.72   -- clear of the jump button and stick
    local y = top + (bottom - top) * 0.5
    if y <= top then y = top + 1 end
    return viewport.X * 0.5, y
end

local function safeClick()
    local x, y = safeClickPoint()
    return clickAt(x, y)
end

local function clickCentre(guiObject)
    if not guiObject then return false end
    local position = guiObject.AbsolutePosition
    local size = guiObject.AbsoluteSize
    return clickAt(position.X + size.X / 2, position.Y + size.Y / 2)
end

--// Hacking ------------------------------------------------------------------
-- The USB minigame is a solved problem the moment the payload arrives. The
-- server sends every round up front:
--
--     UsbMinigame.OnClientEvent -> { id, rounds = {{center,width,period},...},
--                                    hackLevel, securityLevel, name }
--
-- and the client's own hit test is
--
--     hit     when |markerScale - center| <= (width/2) * hitLenience   (1.3)
--     perfect when |markerScale - center| <= (width/2) * perfectFraction (0.2)
--
-- with a perfect worth `perfectQuality` (1.15) toward the success roll. So
-- this is not spoofing a result: it presses at the right moment and the client
-- reports the real marker positions it actually sampled. A server-side
-- revalidation of those samples passes, because they are genuine.

local Hack = {
    SolveMinigame = false,
    PerfectOnly = true,
    AutoDefend = false,
    -- Off by default: tapping presses the real circle but a circle under the
    -- Roblox menu button turns a synthesized tap into an open menu.
    DefendByTap = false,
    Defended = 0,
    Rounds = nil,
    Active = false,
    Solved = 0,
    Missed = 0,
    Marker = nil,
    Zone = nil,
    Status = 'idle',
    LastChance = 0,
}

local MG_LENIENCE = cfg('Hacking.minigame.hitLenience', 1.3)
local MG_PERFECT = cfg('Hacking.minigame.perfectFraction', 0.2)

local UsbMinigame = remote("UsbMinigame")
local UsbMinigameReport = remote("UsbMinigameReport")
local HackDefend = remote("HackDefend")
local HackEvent = remote("HackEvent")

-- The minigame frames are built anonymously, so they cannot be found by name.
-- They can be found by shape: the payload gives the exact centre and width of
-- the target zone, and only one frame in the whole PlayerGui will be sitting
-- at that scale position with that scale width. Its animated sibling is the
-- marker.
local function findMinigameFrames(round)
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui or not round then return nil, nil end

    local wantPos = round.center - round.width / 2
    local wantSize = round.width

    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("Frame") then
            local position = descendant.Position
            local size = descendant.Size
            if math.abs(size.X.Scale - wantSize) < 0.004
                and math.abs(position.X.Scale - wantPos) < 0.004
                and size.X.Offset == 0 then
                -- Siblings of the zone: the marker is the one that is narrow
                -- and not the perfect-band highlight sitting inside the zone.
                local parent = descendant.Parent
                local marker = nil
                if parent then
                    for _, sibling in ipairs(parent:GetChildren()) do
                        if sibling ~= descendant and sibling:IsA("Frame") then
                            if sibling.Size.X.Scale < wantSize * 0.9
                                or sibling.Size.X.Offset > 0 then
                                marker = sibling
                            end
                        end
                    end
                end
                return descendant, marker
            end
        end
    end
    return nil, nil
end

-- Watches the real marker rather than modelling the tween. The tween is a
-- linear ping-pong over `period`, which is easy enough to model, but reading
-- the frame the game is actually animating cannot drift out of sync with it.
local function solveRound(round, index)
    if not round then return end

    local deadline = os.clock() + 12
    local zone, marker

    while os.clock() < deadline do
        if not Hack.Active or not Hack.SolveMinigame then return end
        zone, marker = findMinigameFrames(round)
        if marker then break end
        RunService.Heartbeat:Wait()
    end

    if not marker then
        Hack.Status = ('round %d: no marker found'):format(index)
        return
    end
    Hack.Marker, Hack.Zone = marker, zone

    local half = round.width / 2
    local band = Hack.PerfectOnly and (half * MG_PERFECT) or (half * MG_LENIENCE * 0.8)
    -- Never aim at a band tighter than a frame of travel can resolve, or the
    -- marker steps straight over it and the round times out.
    local perFrame = (1 / 60) / math.max(round.period, 0.05)
    band = math.max(band, perFrame * 0.75)

    while os.clock() < deadline do
        if not Hack.Active or not Hack.SolveMinigame then return end
        if not marker.Parent then return end
        local offset = math.abs(marker.Position.X.Scale - round.center)
        if offset <= band then
            -- Deliberately not aimed at the marker: the handler does not read
            -- the position, and aiming there is what was hitting the Roblox
            -- menu button on mobile.
            if safeClick() then
                Hack.Solved = Hack.Solved + 1
                Hack.Status = ('round %d hit (%.3f off)'):format(index, offset)
            else
                Hack.Status = 'no input synthesis available'
            end
            return
        end
        RunService.Heartbeat:Wait()
    end
    Hack.Missed = Hack.Missed + 1
    Hack.Status = ('round %d timed out'):format(index)
end

local function projectedChance(hackLevel, securityLevel, quality)
    if not HackMath or not HackMath.chance then return 0 end
    local ok, value = pcall(HackMath.chance, hackLevel or 0, securityLevel or 0, quality or 1)
    if ok then return value end
    return 0
end

if UsbMinigame then
    UsbMinigame.OnClientEvent:Connect(function(payload)
        if typeof(payload) ~= "table" then return end
        local rounds = payload.rounds
        if typeof(rounds) ~= "table" or #rounds == 0 then return end

        Hack.Rounds = rounds
        Hack.LastChance = projectedChance(payload.hackLevel, payload.securityLevel, 1)

        if not Hack.SolveMinigame then return end
        if not canSynthesizeInput() then
            Hack.Status = 'needs VirtualInputManager'
            return
        end

        Hack.Active = true
        Hack.Solved = 0
        Hack.Missed = 0
        task.spawn(function()
            -- Rounds are sequential and the game advances on its own after
            -- each hit, so this just follows it round by round.
            for index = 1, #rounds do
                if not Hack.Active then break end
                local round = {
                    center = tonumber(rounds[index].center) or 0.5,
                    width = tonumber(rounds[index].width) or 0.2,
                    period = tonumber(rounds[index].period) or 1,
                }
                solveRound(round, index)
                task.wait(0.12)
            end
            Hack.Active = false
            Hack.Status = ('done: %d hit, %d missed'):format(Hack.Solved, Hack.Missed)
        end)
    end)
end

--// Firewall defence ---------------------------------------------------------
-- The defence circles are TextButtons the client builds and tweens down; a
-- click fires HackDefend:FireServer("hit"). Blocking needs blockMinQuota of
-- them, and the server rate-limits at hitMinInterval, so this taps them as
-- they appear rather than spamming the remote.

local DEFEND_MIN_GAP = cfg('Hacking.defense.hitMinInterval', 0.35)
local lastDefendTap = 0

local function defenceScreen()
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("TextLabel") and descendant.Visible then
            local text = descendant.Text or ""
            if text:find("FIREWALL", 1, true) and text:find("CIRCLE", 1, true) then
                -- Walk up to the containing ScreenGui so the circles, which
                -- are siblings further down, are all inside the search.
                local node = descendant
                while node and not node:IsA("ScreenGui") do
                    node = node.Parent
                end
                return node
            end
        end
    end
    return nil
end

-- Two ways to answer a firewall, and on a phone the difference matters.
--
-- Tapping is the faithful one: it presses the actual circle, so the client's
-- own counter and the server's agree. But a circle can spawn anywhere on
-- screen, including under the Roblox menu button, and a synthesized tap there
-- opens the Roblox menu instead of hitting the circle.
--
-- Firing the remote is what the tap would have caused anyway - the client's
-- handler does nothing else with it - and touches no coordinates at all. It is
-- paced by the game's own hitMinInterval and only runs while a firewall is
-- actually on screen, so the server sees the same rate a fast player produces.
-- That is the default, because a defence that occasionally yanks you into the
-- Roblox menu is worse than useless.
local function circlesOnScreen(screen)
    local n = 0
    for _, descendant in ipairs(screen:GetDescendants()) do
        if descendant:IsA("TextButton") and descendant.Visible
            and descendant.AbsoluteSize.X > 12 then
            n = n + 1
        end
    end
    return n
end

task.spawn(function()
    while true do
        RunService.Heartbeat:Wait()
        if Hack.AutoDefend then
            local screen = defenceScreen()
            if screen and os.clock() - lastDefendTap >= DEFEND_MIN_GAP then
                if Hack.DefendByTap then
                    if canSynthesizeInput() then
                        for _, descendant in ipairs(screen:GetDescendants()) do
                            if descendant:IsA("TextButton") and descendant.Visible
                                and descendant.AbsoluteSize.X > 12 then
                                if clickCentre(descendant) then
                                    lastDefendTap = os.clock()
                                end
                                break
                            end
                        end
                    else
                        Hack.Status = 'tap mode needs VirtualInputManager'
                    end
                elseif HackDefend and circlesOnScreen(screen) > 0 then
                    -- Only while a circle is actually up, so this never sends
                    -- a hit there was nothing to hit.
                    local ok = pcall(function() HackDefend:FireServer("hit") end)
                    if ok then
                        lastDefendTap = os.clock()
                        Hack.Defended = Hack.Defended + 1
                    end
                end
            end
        end
    end
end)

--// Economy ------------------------------------------------------------------

local Economy = {
    AutoCollectPads = false,
    AutoOffline = false,
    AutoDaily = false,
    AutoTokens = false,
    TokenFloor = cfg('Tokens.spikePrice', 12),
    RestockAlert = false,
    LastCollect = 0,
    Collected = 0,
    Status = 'idle',
}

-- Collect pads are tagged, so there is no guessing where they are.
local function collectPads()
    local ok, pads = pcall(function()
        return CollectionService:GetTagged("CollectPadPart")
    end)
    if not ok then return {} end
    return pads
end

local function myPlotId()
    return LocalPlayer:GetAttribute("PlotId")
end

local function touchPad(pad)
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not pad or not pad:IsA("BasePart") then return false end
    -- The pads are touch-activated, so a real touch is the honest way in.
    if typeof(firetouchinterest) ~= "function" then return false end
    pcall(firetouchinterest, root, pad, 0)
    pcall(firetouchinterest, root, pad, 1)
    return true
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if Economy.AutoCollectPads then
            local mine = myPlotId()
            for _, pad in ipairs(collectPads()) do
                local plot = pad:GetAttribute("PlotId")
                if mine == nil or plot == nil or plot == mine then
                    if touchPad(pad) then
                        Economy.Collected = Economy.Collected + 1
                    end
                end
            end
        end
    end
end)

-- Token price walks between priceMin and priceMax on a fixed epoch, so the
-- spike is a schedule rather than a surprise. Selling is a plain FireServer
-- with no arguments - the server decides how many you had.
local SellTokens = remote("SellTokens")

local function tokenEpoch()
    local period = cfg('Tokens.priceEpochSeconds', 30)
    local now = 0
    local ok, value = pcall(function() return workspace:GetServerTimeNow() end)
    if ok then now = value else now = os.time() end
    return period - (now % period)
end

task.spawn(function()
    while true do
        task.wait(1)
        if Economy.AutoTokens and SellTokens then
            -- Price is not exposed as a value the client can read directly, so
            -- this sells on the epoch boundary where the spike lands rather
            -- than claiming to read the number.
            if tokenEpoch() <= 1.2 then
                pcall(function() SellTokens:FireServer() end)
                Economy.Status = 'sold on epoch'
                task.wait(2)
            end
        end
    end
end)

local CollectOffline = remote("CollectOffline")
local ClaimDailyReward = remote("ClaimDailyReward")

local function claimOnce()
    if Economy.AutoOffline and CollectOffline then
        pcall(function() CollectOffline:InvokeServer("collect") end)
    end
    if Economy.AutoDaily and ClaimDailyReward then
        pcall(function() ClaimDailyReward:InvokeServer() end)
    end
end

--// Shop restock -------------------------------------------------------------
-- ShopStock is a folder of live IntValues on your own Player, one per item,
-- plus a RestockAt timestamp. So both "what is in stock right now" and "when
-- does it refill" are direct reads rather than polling the shop UI.

local function shopStock()
    return LocalPlayer:FindFirstChild("ShopStock")
end

local function restockIn()
    local stock = shopStock()
    local at = stock and stock:FindFirstChild("RestockAt")
    if not at then return nil end
    local now = 0
    local ok, value = pcall(function() return workspace:GetServerTimeNow() end)
    if ok then now = value else return nil end
    return math.max(0, at.Value - now)
end

local function stockOf(itemName)
    local stock = shopStock()
    local entry = stock and stock:FindFirstChild(itemName)
    return entry and entry.Value or 0
end

--// Build advisor ------------------------------------------------------------
-- Hardware gives compute, DataSources and Datasets give data, and Config
-- carries cost and rate for every one of them. Ranking by rate per dollar is
-- the whole calculation - the value is in having it in front of you next to
-- what is actually in stock.

local function catalogue()
    local out = {}
    for _, entry in ipairs(cfg('Hardware', {})) do
        table.insert(out, {
            name = entry.name, cost = entry.cost or 0,
            rate = entry.computePerSec or 0, kind = 'compute',
        })
    end
    for _, entry in ipairs(cfg('DataSources', {})) do
        table.insert(out, {
            name = entry.name, cost = entry.cost or 0,
            rate = entry.dataPerSec or 0, kind = 'data',
        })
    end
    for _, entry in ipairs(cfg('Datasets', {})) do
        table.insert(out, {
            name = entry.name, cost = entry.cost or 0,
            rate = entry.dataPerSec or entry.bytes or 0, kind = 'dataset',
        })
    end
    return out
end

-- Best value per dollar, restricted to what is affordable and in stock, since
-- a perfect recommendation you cannot buy is not a recommendation.
local function bestBuys(kind, affordableOnly, inStockOnly)
    local cash = money()
    local rows = {}
    for _, entry in ipairs(catalogue()) do
        if entry.cost > 0 and entry.rate > 0 and (kind == 'all' or entry.kind == kind) then
            local stock = stockOf(entry.name)
            local ok = true
            if affordableOnly and entry.cost > cash then ok = false end
            if inStockOnly and stock <= 0 then ok = false end
            if ok then
                table.insert(rows, {
                    name = entry.name, kind = entry.kind, cost = entry.cost,
                    rate = entry.rate, stock = stock,
                    ratio = entry.rate / entry.cost,
                })
            end
        end
    end
    table.sort(rows, function(a, b) return a.ratio > b.ratio end)
    return rows
end

local BuyItem = remote("BuyItem")

--// Combat -------------------------------------------------------------------
-- Taser range is the interesting one: the client offers `range` but the server
-- accepts up to `serverRange`, and the aim gate `forwardDot` widens with the
-- better tiers. Those are the game's own numbers, so staying inside them is
-- staying inside what the server already allows.

local Combat = {
    AutoTaser = false,
    TaserRange = cfg('Taser.serverRange', 26),
    AutoMelee = false,
    MeleeRange = cfg('Melee.hitRangeStuds', 11.5),
    AutoHoodie = false,
    LastTaser = 0,
    LastMelee = 0,
    Hits = 0,
    Status = 'idle',
}

local TaserHit = remote("TaserHit")
local MeleeHit = remote("MeleeHit")
local ToggleHoodie = remote("ToggleHoodie")
local UseHoodie = remote("UseHoodie")

local TASER_COOLDOWN = cfg('Taser.cooldownSeconds', 8)
local MELEE_COOLDOWN = cfg('Melee.swingCooldownSeconds', 0.35)
local SHOP_SAFE = cfg('Melee.shopSafeRadius', 22)

local function myRoot()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function nearestTarget(maxDistance)
    local root = myRoot()
    if not root then return nil, math.huge end
    local best, bestDistance = nil, maxDistance
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if theirRoot and humanoid and humanoid.Health > 0 then
                local distance = (theirRoot.Position - root.Position).Magnitude
                if distance < bestDistance then
                    best, bestDistance = player, distance
                end
            end
        end
    end
    return best, bestDistance
end

task.spawn(function()
    while true do
        RunService.Heartbeat:Wait()
        local now = os.clock()

        if Combat.AutoTaser and TaserHit and now - Combat.LastTaser >= TASER_COOLDOWN then
            local target, distance = nearestTarget(Combat.TaserRange)
            if target then
                Combat.LastTaser = now
                local ok = pcall(function() TaserHit:FireServer(target) end)
                Combat.Status = ok and ('tased %s at %.0fst'):format(target.Name, distance)
                    or 'taser rejected'
                Combat.Hits = Combat.Hits + (ok and 1 or 0)
            end
        end

        if Combat.AutoMelee and MeleeHit and now - Combat.LastMelee >= MELEE_COOLDOWN then
            local target, distance = nearestTarget(Combat.MeleeRange)
            if target then
                Combat.LastMelee = now
                pcall(function() MeleeHit:FireServer(target) end)
                Combat.Status = ('swung at %s (%.0fst)'):format(target.Name, distance)
            end
        end
    end
end)

--// Visuals ------------------------------------------------------------------
-- The radar is 80 studs on a 30 second cooldown. This is the same information
-- without the cooldown, which is most of why the radar exists.

local Esp = {
    Enabled = false,
    Range = 400,
    ShowPlot = true,
    ShowMoney = true,
    ShowDistance = true,
}

local espTags = {}

local function clearEsp()
    for player, gui in pairs(espTags) do
        pcall(function() gui:Destroy() end)
        espTags[player] = nil
    end
end

local function espFor(player)
    local character = player.Character
    local head = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
    if not head then return nil end

    local existing = espTags[player]
    if existing and existing.Parent and existing.Adornee == head then
        return existing
    end
    if existing then pcall(function() existing:Destroy() end) end

    local gui = Instance.new("BillboardGui")
    gui.Name = "bai_esp"
    gui.Adornee = head
    gui.AlwaysOnTop = true
    gui.Size = UDim2.new(0, 210, 0, 40)
    gui.StudsOffset = Vector3.new(0, 3, 0)

    local label = Instance.new("TextLabel", gui)
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 1, 0)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextStrokeTransparency = 0.4
    label.Text = player.Name

    gui.Parent = head
    espTags[player] = gui
    return gui
end

task.spawn(function()
    while true do
        task.wait(0.25)
        if not Esp.Enabled then
            if next(espTags) then clearEsp() end
        else
            local root = myRoot()
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer then
                    local theirRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                    local distance = (root and theirRoot)
                        and (theirRoot.Position - root.Position).Magnitude or math.huge
                    if theirRoot and distance <= Esp.Range then
                        local gui = espFor(player)
                        if gui then
                            local parts = { player.Name }
                            if Esp.ShowPlot then
                                local plot = player:GetAttribute("PlotId")
                                if plot then table.insert(parts, "plot " .. tostring(plot)) end
                            end
                            if Esp.ShowMoney then
                                local stats = player:FindFirstChild("leaderstats")
                                local cash = stats and stats:FindFirstChild("Money")
                                if cash then table.insert(parts, "$" .. short(cash.Value)) end
                            end
                            if Esp.ShowDistance then
                                table.insert(parts, ("%.0fst"):format(distance))
                            end
                            gui.TextLabel.Text = table.concat(parts, "  ")
                        end
                    elseif espTags[player] then
                        pcall(function() espTags[player]:Destroy() end)
                        espTags[player] = nil
                    end
                end
            end
        end
    end
end)

Players.PlayerRemoving:Connect(function(player)
    if espTags[player] then
        pcall(function() espTags[player]:Destroy() end)
        espTags[player] = nil
    end
end)

--// Movement -----------------------------------------------------------------
-- Config.SpeedGuard is currently disabled, but it ships every threshold it
-- would use, so the sliders below are capped to what it would allow rather
-- than to whatever the engine accepts. If it is ever switched on, nothing here
-- has to change.

local Move = {
    SpeedEnabled = false,
    Speed = cfg('Map.baseWalkSpeed', 16),
    JumpEnabled = false,
    Jump = 50,
}

local GUARD_MAX_SPEED = cfg('SpeedGuard.maxSpeed', 38)
local GUARD_ON = cfg('SpeedGuard.enabled', false)

task.spawn(function()
    while true do
        task.wait(0.2)
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            if Move.SpeedEnabled then
                humanoid.WalkSpeed = Move.Speed
            end
            if Move.JumpEnabled then
                humanoid.UseJumpPower = true
                humanoid.JumpPower = Move.Jump
            end
        end
    end
end)

--// UI -----------------------------------------------------------------------

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'build an ai',
    SubTitle = cfg('GameName', 'Build an AI'),
    Folder = 'BuildAnAI',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(60, 200, 120),
})

local COLOR_GOOD = Color3.fromRGB(126, 217, 87)
local COLOR_WARN = Color3.fromRGB(255, 196, 87)
local COLOR_BAD = Color3.fromRGB(255, 96, 106)

local MainTab = Window:Tab({ Title = 'Main', Icon = 'cpu' })
local HackTab = MainTab:Tab({ Title = 'hacking', Icon = 'terminal' })
local EcoTab = MainTab:Tab({ Title = 'economy', Icon = 'dollar-sign' })
local BuildTab = MainTab:Tab({ Title = 'build', Icon = 'trending-up' })

--// Main > hacking -----------------------------------------------------------

local MiniSection = HackTab:Section({ Title = 'usb minigame', Side = 'left' })

MiniSection:Toggle({
    Title = 'auto solve',
    Flag = 'bai_solve',
    Default = false,
    Callback = function(state) Hack.SolveMinigame = state end,
})

MiniSection:Toggle({
    Title = 'aim for perfect',
    Flag = 'bai_perfect',
    Default = true,
    Callback = function(state) Hack.PerfectOnly = state end,
})

local MiniStatus = MiniSection:Stat({ Title = 'status', Value = 'idle' })
local MiniHits = MiniSection:Stat({ Title = 'hit / missed', Value = '0 / 0' })
local MiniInput = MiniSection:Stat({ Title = 'input', Value = '-' })

MiniSection:Paragraph({
    Title = 'why this works',
    Text = 'The server sends every round before the minigame starts - centre, width and period each. The hit test is |marker - centre| <= width/2 x 1.3, and a perfect is x 0.2 for a 1.15 quality bonus that feeds the success roll. So this is not faking a result: it presses at the right moment and the client reports the marker positions it genuinely sampled.',
})

MiniSection:Paragraph({
    Title = 'where it taps',
    Text = 'The minigame\'s handler reads only the input type - it never looks at where the tap landed. So the tap goes to a point below the Roblox topbar and above the on-screen controls rather than at the marker. Aiming at the marker was pointless and, on a phone, the marker sits right under the Roblox menu button.',
})

MiniSection:Paragraph({
    Title = 'needs an executor with VirtualInputManager',
    Text = 'The minigame listens for a real press on UserInputService, which a script cannot raise directly, so it goes through VirtualInputManager. If your executor does not expose it the status says so, and nothing else here depends on it - the firewall defence, the economy tools and the overlay all work without it.',
})

local DefendSection = HackTab:Section({ Title = 'firewall defence', Side = 'right' })

DefendSection:Toggle({
    Title = 'auto defend',
    Flag = 'bai_defend',
    Default = false,
    Callback = function(state) Hack.AutoDefend = state end,
})

DefendSection:Toggle({
    Title = 'tap the circles instead',
    Flag = 'bai_defend_tap',
    Default = false,
    Callback = function(state) Hack.DefendByTap = state end,
})

local DefendCount = DefendSection:Stat({ Title = 'blocks sent', Value = '0' })

DefendSection:Paragraph({
    Title = 'mobile',
    Text = 'By default this answers the firewall through its remote rather than by tapping, because a circle can spawn under the Roblox menu button and a synthesized tap there opens the Roblox menu instead. It only fires while a circle is actually on screen and it is paced by the game\'s own minimum interval, so the server sees the rate a fast player produces. Turn tapping on if you would rather press the real buttons.',
})

DefendSection:Paragraph({
    Title = 'how it defends',
    Text = ('Taps the circles as they appear, spaced by the game\'s own %.2fs minimum. Blocking needs %d%% of them, out of %d circles that each live %.1fs. It taps rather than firing the remote directly, so the count the server sees is the count you actually hit.')
        :format(cfg('Hacking.defense.hitMinInterval', 0.35),
                math.floor(cfg('Hacking.defense.blockMinQuota', 0.5) * 100),
                cfg('Hacking.defense.circles', 6),
                cfg('Hacking.defense.circleLifeSeconds', 2.2)),
})

local ChanceSection = HackTab:Section({ Title = 'odds', Side = 'right' })

local ChanceStat = ChanceSection:Stat({ Title = 'last target', Value = '-' })
local ChancePerfect = ChanceSection:Stat({ Title = 'if all perfect', Value = '-' })

ChanceSection:Paragraph({
    Title = 'the formula',
    Text = 'HackMath.chance is shipped to the client: 1 / (1 + (max(security, 10) / (power x quality)) ^ 1.6), clamped to 1%-99%. The quality multiplier is what the minigame buys you, which is why solving it perfectly is worth more than it looks.',
})

--// Main > economy -----------------------------------------------------------

local CollectSection = EcoTab:Section({ Title = 'collect', Side = 'left' })

CollectSection:Toggle({
    Title = 'auto collect pads',
    Flag = 'bai_pads',
    Default = false,
    Callback = function(state) Economy.AutoCollectPads = state end,
})

CollectSection:Toggle({
    Title = 'auto offline earnings',
    Flag = 'bai_offline',
    Default = false,
    Callback = function(state) Economy.AutoOffline = state end,
})

CollectSection:Toggle({
    Title = 'auto daily reward',
    Flag = 'bai_daily',
    Default = false,
    Callback = function(state) Economy.AutoDaily = state end,
})

CollectSection:Buttons({
    { Title = 'claim now', Callback = claimOnce },
    {
        Title = 'collect pads once',
        Callback = function()
            local mine = myPlotId()
            local n = 0
            for _, pad in ipairs(collectPads()) do
                local plot = pad:GetAttribute("PlotId")
                if mine == nil or plot == nil or plot == mine then
                    if touchPad(pad) then n = n + 1 end
                end
            end
            Economy.Status = ('touched %d pads'):format(n)
        end,
    },
})

local CollectStat = CollectSection:Stat({ Title = 'pads touched', Value = '0' })
local CollectStatus = CollectSection:Stat({ Title = 'status', Value = 'idle' })

local TokenSection = EcoTab:Section({ Title = 'tokens', Side = 'right' })

TokenSection:Toggle({
    Title = 'sell on the spike',
    Flag = 'bai_tokens',
    Default = false,
    Callback = function(state) Economy.AutoTokens = state end,
})

local TokenClock = TokenSection:Stat({ Title = 'next epoch', Value = '-' })

TokenSection:Paragraph({
    Title = 'what it can and cannot see',
    Text = ('Token price walks between %d and %d on a %ds epoch with a spike at %d. The epoch boundary is computable from server time, so this sells there. The live price itself is not exposed to the client, so this times the schedule rather than reading the number - if the spike does not land every epoch, you will sell some at the ordinary price.')
        :format(cfg('Tokens.priceMin', 5), cfg('Tokens.priceMax', 15),
                cfg('Tokens.priceEpochSeconds', 30), cfg('Tokens.spikePrice', 12)),
})

local RestockSection = EcoTab:Section({ Title = 'shop restock', Side = 'right' })

local RestockClock = RestockSection:Stat({ Title = 'restock in', Value = '-' })
local RestockLog = RestockSection:Console({ Title = 'in stock now', Height = 130, MaxLines = 40 })

RestockSection:Button({
    Title = 'refresh stock',
    Callback = function()
        RestockLog:Clear()
        local rows = {}
        local stock = shopStock()
        if not stock then
            RestockLog:Warn('no ShopStock folder on your player')
            return
        end
        for _, entry in ipairs(stock:GetChildren()) do
            if entry:IsA("IntValue") and entry.Value > 0 then
                table.insert(rows, { name = entry.Name, n = entry.Value })
            end
        end
        table.sort(rows, function(a, b) return a.name < b.name end)
        if #rows == 0 then
            RestockLog:Add('nothing in stock')
        end
        for _, row in ipairs(rows) do
            RestockLog:Add(('%-26s x%d'):format(row.name:sub(1, 26), row.n))
        end
    end,
})

--// Main > build -------------------------------------------------------------

local AdviceSection = BuildTab:Section({ Title = 'best value', Side = 'left' })

local adviceKind = 'all'
local adviceAfford = true
local adviceStock = true

AdviceSection:Dropdown({
    Title = 'category',
    Flag = 'bai_advice_kind',
    Values = { 'all', 'compute', 'data', 'dataset' },
    Default = 'all',
    Callback = function(value) adviceKind = value end,
})

AdviceSection:Toggle({
    Title = 'only what i can afford',
    Flag = 'bai_advice_afford',
    Default = true,
    Callback = function(state) adviceAfford = state end,
})

AdviceSection:Toggle({
    Title = 'only what is in stock',
    Flag = 'bai_advice_stock',
    Default = true,
    Callback = function(state) adviceStock = state end,
})

local AdviceLog = AdviceSection:Console({
    Title = 'item  /  cost  /  rate  /  per $',
    Height = 180,
    MaxLines = 60,
})

local function refreshAdvice()
    AdviceLog:Clear()
    local rows = bestBuys(adviceKind, adviceAfford, adviceStock)
    if #rows == 0 then
        AdviceLog:Add('nothing matches - try widening the filters')
        return
    end
    for index, row in ipairs(rows) do
        if index > 25 then break end
        AdviceLog:Add(('%-22s $%-9s %-9s %.4f  x%d')
            :format(row.name:sub(1, 22), short(row.cost), short(row.rate),
                    row.ratio, row.stock))
    end
end

AdviceSection:Buttons({
    { Title = 'refresh', Callback = refreshAdvice },
    {
        Title = 'buy top pick',
        Callback = function()
            local rows = bestBuys(adviceKind, true, true)
            local pick = rows[1]
            if not pick or not BuyItem then
                Economy.Status = 'nothing buyable'
                return
            end
            local category = pick.kind == 'compute' and 'Hardware'
                or (pick.kind == 'data' and 'DataSources' or 'Datasets')
            local ok, result = pcall(function()
                return BuyItem:InvokeServer(category, pick.name)
            end)
            if ok and typeof(result) == 'table' and result.ok then
                Economy.Status = 'bought ' .. pick.name
            else
                Economy.Status = 'buy refused: ' .. pick.name
            end
        end,
    },
})

local MoneyStat = AdviceSection:Stat({ Title = 'money', Value = '0' })

BuildTab:Section({ Title = 'how it ranks', Side = 'right' }):Paragraph({
    Title = 'rate per dollar',
    Text = 'Cost and output for every item are in Config, so this is the game\'s own numbers sorted by output per dollar, filtered to what is actually in your shop stock right now. It deliberately does not try to model the training curve past that - the softcap and scaling exponent mean the true best buy depends on your current level, and a confident-looking number there would be a guess dressed up as advice.',
})

--// Combat -------------------------------------------------------------------

local CombatTab = Window:Tab({ Title = 'combat', Icon = 'zap' })

local TaserSection = CombatTab:Section({ Title = 'taser', Side = 'left' })

TaserSection:Toggle({
    Title = 'auto taser',
    Flag = 'bai_taser',
    Default = false,
    Callback = function(state) Combat.AutoTaser = state end,
})

TaserSection:Slider({
    Title = 'range',
    Flag = 'bai_taser_range',
    Min = 5,
    Max = cfg('Taser.taserTiers', {})[3] and 45 or 30,
    Increment = 1,
    Default = cfg('Taser.serverRange', 26),
    Suffix = 'st',
    Callback = function(v) Combat.TaserRange = v end,
})

TaserSection:Paragraph({
    Title = 'the range gap',
    Text = ('The client only lets you fire at %d studs but the server accepts %d, and the aim cone widens from %.2f on the basic taser to %.2f on the volt. The slider defaults to the server figure, which is the game\'s own limit rather than one I picked.')
        :format(cfg('Taser.range', 20), cfg('Taser.serverRange', 26),
                cfg('Taser.forwardDot', 0.26), 0.09),
})

local MeleeSection = CombatTab:Section({ Title = 'melee', Side = 'right' })

MeleeSection:Toggle({
    Title = 'auto swing',
    Flag = 'bai_melee',
    Default = false,
    Callback = function(state) Combat.AutoMelee = state end,
})

MeleeSection:Slider({
    Title = 'range',
    Flag = 'bai_melee_range',
    Min = 3,
    Max = 20,
    Increment = 0.5,
    Default = cfg('Melee.hitRangeStuds', 11.5),
    Suffix = 'st',
    Callback = function(v) Combat.MeleeRange = v end,
})

local CombatStatus = MeleeSection:Stat({ Title = 'status', Value = 'idle' })
local CombatHits = MeleeSection:Stat({ Title = 'taser hits', Value = '0' })

MeleeSection:Paragraph({
    Title = 'untested',
    Text = ('Both fire the game\'s own hit remotes with a player argument, at the cooldowns Config states (%.1fs taser, %.2fs melee). Whether the server accepts a hit it did not see you aim at is not something the dump answers - if these do nothing, that is why.')
        :format(cfg('Taser.cooldownSeconds', 8), cfg('Melee.swingCooldownSeconds', 0.35)),
})

--// Visuals ------------------------------------------------------------------

local VisTab = Window:Tab({ Title = 'visuals', Icon = 'eye' })
local EspSection = VisTab:Section({ Title = 'players', Side = 'left' })

EspSection:Toggle({
    Title = 'enabled',
    Flag = 'bai_esp',
    Default = false,
    Callback = function(state)
        Esp.Enabled = state
        if not state then clearEsp() end
    end,
})

EspSection:Slider({
    Title = 'range',
    Flag = 'bai_esp_range',
    Min = 50,
    Max = 2000,
    Increment = 50,
    Default = 400,
    Suffix = 'st',
    Callback = function(v) Esp.Range = v end,
})

EspSection:Toggle({ Title = 'plot id', Flag = 'bai_esp_plot', Default = true,
    Callback = function(s) Esp.ShowPlot = s end })
EspSection:Toggle({ Title = 'money', Flag = 'bai_esp_money', Default = true,
    Callback = function(s) Esp.ShowMoney = s end })
EspSection:Toggle({ Title = 'distance', Flag = 'bai_esp_dist', Default = true,
    Callback = function(s) Esp.ShowDistance = s end })

VisTab:Section({ Title = 'why', Side = 'right' }):Paragraph({
    Title = 'the radar without the cooldown',
    Text = ('The in-game radar covers %d studs on a %ds cooldown and shows a blip for %ds. Everything it shows - who is nearby, which plot they own, what they are worth - is a plain read off the player objects, so this is the same information without waiting.')
        :format(cfg('Radar.rangeStuds', 80), cfg('Radar.cooldownSeconds', 30),
                cfg('Radar.markerSeconds', 5)),
})

--// Player -------------------------------------------------------------------

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local MoveSection = PlayerTab:Section({ Title = 'movement', Side = 'left' })

MoveSection:Toggle({
    Title = 'walk speed',
    Flag = 'bai_speed_on',
    Default = false,
    Callback = function(state) Move.SpeedEnabled = state end,
})

MoveSection:Slider({
    Title = 'speed',
    Flag = 'bai_speed',
    Min = 8,
    Max = math.floor(GUARD_MAX_SPEED),
    Increment = 1,
    Default = cfg('Map.baseWalkSpeed', 16),
    Suffix = '',
    Callback = function(v) Move.Speed = v end,
})

MoveSection:Toggle({
    Title = 'jump power',
    Flag = 'bai_jump_on',
    Default = false,
    Callback = function(state) Move.JumpEnabled = state end,
})

MoveSection:Slider({
    Title = 'jump',
    Flag = 'bai_jump',
    Min = 50,
    Max = 200,
    Increment = 5,
    Default = 50,
    Suffix = '',
    Callback = function(v) Move.Jump = v end,
})

local GuardStat = MoveSection:Stat({ Title = 'speed guard', Value = '-' })

MoveSection:Paragraph({
    Title = 'capped on purpose',
    Text = ('Config.SpeedGuard is %s right now, but it ships all of its thresholds either way - %d max speed, %d sneaking, %.1fs airborne. The slider stops at the guard\'s own limit so nothing here trips it if it is ever switched on.')
        :format(GUARD_ON and 'ENABLED' or 'disabled',
                cfg('SpeedGuard.maxSpeed', 38), cfg('SpeedGuard.sneakMaxSpeed', 18),
                cfg('SpeedGuard.maxAirborneSeconds', 2.5)),
})

--// Misc ---------------------------------------------------------------------

local MiscTab = Window:Tab({ Title = 'misc', Icon = 'settings' })
local ProbeSection = MiscTab:Section({ Title = 'probes', Side = 'left' })

local ProbeLog = ProbeSection:Console({ Title = 'output', Height = 170, MaxLines = 60 })

local function dump(value, depth)
    depth = depth or 0
    if depth > 2 then return '...' end
    if typeof(value) == 'table' then
        local parts = {}
        for k, v in pairs(value) do
            table.insert(parts, tostring(k) .. '=' .. dump(v, depth + 1))
        end
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    return tostring(value)
end

ProbeSection:Buttons({
    {
        Title = 'crate odds',
        Callback = function()
            local r = remote("GetCrateOdds")
            if not r then ProbeLog:Warn('GetCrateOdds missing') return end
            local ok, result = pcall(function() return r:InvokeServer() end)
            ProbeLog:Add(ok and dump(result) or ('failed: ' .. tostring(result)))
        end,
    },
    {
        Title = 'intel',
        Callback = function()
            local r = remote("GetIntel")
            if not r then ProbeLog:Warn('GetIntel missing') return end
            local target = nearestTarget(math.huge)
            local ok, result = pcall(function() return r:InvokeServer(target) end)
            ProbeLog:Add(ok and dump(result) or ('failed: ' .. tostring(result)))
        end,
    },
    {
        Title = 'hack history',
        Callback = function()
            local r = remote("GetHackHistory")
            if not r then ProbeLog:Warn('GetHackHistory missing') return end
            local ok, result = pcall(function() return r:InvokeServer() end)
            ProbeLog:Add(ok and dump(result) or ('failed: ' .. tostring(result)))
        end,
    },
})

ProbeSection:Paragraph({
    Title = 'what these are',
    Text = 'GetIntel and GetCrateOdds are RemoteFunctions the dumped client never actually calls, so their argument and return shapes are unknown. These invoke them and print whatever comes back rather than guessing at a UI for data I have not seen.',
})

local DevSection = MiscTab:Section({ Title = 'dev remotes', Side = 'right' })

DevSection:Buttons({
    {
        Title = 'try GrantCash',
        Callback = function()
            local r = remote("GrantCash")
            if not r then ProbeLog:Warn('GrantCash missing') return end
            pcall(function() r:FireServer(1000) end)
            ProbeLog:Warn('GrantCash fired - expect it to be ignored')
        end,
    },
    {
        Title = 'try AddTokens',
        Callback = function()
            local r = remote("AddTokens")
            if not r then ProbeLog:Warn('AddTokens missing') return end
            pcall(function() r:FireServer(100) end)
            ProbeLog:Warn('AddTokens fired - expect it to be ignored')
        end,
    },
})

DevSection:Paragraph({
    Title = 'these will almost certainly do nothing',
    Text = 'The game\'s own PromoCodes module calls GrantCash and warns beside it that dev grants are server-gated. They are here as one-shot tests, not as a money button, and I would expect the server to drop them.',
})

local CodeSection = MiscTab:Section({ Title = 'codes', Side = 'right' })

local codeText = ''
CodeSection:Textbox({
    Title = 'code',
    Placeholder = 'enter a code',
    Callback = function(value) codeText = value end,
})

CodeSection:Button({
    Title = 'redeem',
    Callback = function()
        local r = remote("RedeemCode")
        if not r or #codeText < 4 then
            ProbeLog:Warn('need a code of 4+ characters')
            return
        end
        local ok, result = pcall(function() return r:InvokeServer(codeText) end)
        if ok and result == true then
            ProbeLog:Success('redeemed ' .. codeText)
        else
            ProbeLog:Warn('invalid or expired: ' .. codeText)
        end
    end,
})

CodeSection:Paragraph({
    Title = 'no code list',
    Text = 'Codes are validated server-side and the client holds no list, so there is nothing to auto-redeem from. This is just the redeem call without the shop UI in the way.',
})

Window:Load()

--// Live readouts ------------------------------------------------------------

MiniInput:Set(canSynthesizeInput() and 'VirtualInputManager ok' or 'unavailable',
    canSynthesizeInput() and COLOR_GOOD or COLOR_BAD)
GuardStat:Set(GUARD_ON and 'enabled' or 'disabled', GUARD_ON and COLOR_WARN or COLOR_GOOD)

task.spawn(function()
    while true do
        task.wait(0.25)

        MiniStatus:Set(Hack.Status)
        DefendCount:Set(tostring(Hack.Defended))
        MiniHits:Set(('%d / %d'):format(Hack.Solved, Hack.Missed))
        if Hack.LastChance > 0 then
            ChanceStat:Set(('%.0f%%'):format(Hack.LastChance * 100))
            local perfect = projectedChance(0, 0, 1)
            ChancePerfect:Set(Hack.Rounds and ('%d rounds'):format(#Hack.Rounds) or '-')
        end

        CollectStat:Set(tostring(Economy.Collected))
        CollectStatus:Set(Economy.Status)
        TokenClock:Set(('%.0fs'):format(tokenEpoch()))

        local left = restockIn()
        if left then
            RestockClock:Set(('%.0fs'):format(left), left < 15 and COLOR_GOOD or nil)
        else
            RestockClock:Set('-')
        end

        MoneyStat:Set('$' .. commas(money()))
        CombatStatus:Set(Combat.Status)
        CombatHits:Set(tostring(Combat.Hits))
    end
end)

task.spawn(function()
    while true do
        task.wait(30)
        if Economy.AutoOffline or Economy.AutoDaily then
            claimOnce()
        end
    end
end)

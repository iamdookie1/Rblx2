--// Throw Food For Baddies -------------------------------------------------------------------
-- place 89727004942007 (game 10773616048). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Throw   Standing in the throw zone (or with auto throw on) runs
--           ThrowClient's throwSequence: Throw.Begin gives a MeterStart, the
--           power meter swings (ThrowConfig.MeterAt: a triangle with a
--           1.6 s period, top at start + 0.8 s), and the tap is sent as
--           Throw.Tap(serverTime, isAuto). PERFECT is 0.95 and up. The
--           server works out your power from that time, so tapping at the
--           top means a max power throw every time.
--   Auto    Throw.SetAuto(true) is a free toggle; on its own it waits two
--           meter cycles and uses a weaker auto meter.
--   Train   Pull-ups at your pen's PullUp station give strength; reps are
--           timed on the server. PullUp.BoostOffer(id) offers a 2x boost,
--           PullUp.BoostClaim(id) takes it.
--   Baddies Player.BaddieInventory holds one child per baddie (BaddieId,
--           Size, Mutation, Favorite, Equipped, InFuser). Sell.Sell({uids}),
--           Fuse.Add(uid, slot) x3 then Fuse.Fuse(), Pen.EquipBest,
--           Upgrade.PenPress, Income.ClaimOffline, GroupReward.Claim.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__TffbUnload then
    pcall(Genv.__TffbUnload)
end
Genv.__TffbRun = (Genv.__TffbRun or 0) + 1
local RUN = Genv.__TffbRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__TffbRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Celestial", "Cosmic", "Divine", "Secret" }

local Settings = {
    -- throw
    PerfectTap = true, TapAt = 0.975, FarmMode = "Off", AlternateMinutes = 5,
    -- train
    BoostClaim = true, BoostDelay = 0.3, TeleportToStation = false,
    -- baddies
    AutoEquipBest = true, AutoSell = false, SellBelow = "Rare", KeepMutated = true, KeepBig = true, SellEvery = 30,
    AutoFuse = false, FuseFrom = "Common", FuseEvery = 20,
    AutoUpgrade = false, UpgradeEvery = 5,
    AutoClaims = true, AntiAfk = true,
    -- tests
    StrengthMult = 10, RaceBurst = 4,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[Baddies] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Throw Food For Baddies", Description = text, Time = seconds or 3 })
end
local function remote(path)
    local inst = ReplicatedStorage
    for name in path:gmatch("[^%.]+") do
        inst = inst and inst:WaitForChild(name, 5)
    end
    return inst
end
local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function charAttr(name)
    local c = LocalPlayer.Character
    return c and c:GetAttribute(name)
end

local R = {
    SetAuto = remote("Throw.SetAuto"), SetStrength = remote("Throw.SetStrength"),
    PullStart = remote("PullUp.Start"), PullStop = remote("PullUp.Stop"),
    BoostOffer = remote("PullUp.BoostOffer"), BoostClaim = remote("PullUp.BoostClaim"),
    Sell = remote("Sell.Sell"), SellAll = remote("Sell.SellAll"),
    FuseAdd = remote("Fuse.Add"), FuseReturn = remote("Fuse.Return"), Fuse = remote("Fuse.Fuse"),
    EquipBest = remote("Pen.EquipBest"), PenPress = remote("Upgrade.PenPress"),
    ClaimOffline = remote("Income.ClaimOffline"), GroupClaim = remote("GroupReward.Claim"),
}
local Catalog, FuseConfig
pcall(function()
    local sys = ReplicatedStorage:WaitForChild("BaddieSystem", 5)
    Catalog = require(sys:WaitForChild("BaddieCatalog"))
    FuseConfig = require(sys:WaitForChild("FuseConfig"))
end)

--// Perfect tap \\--
-- Reads the meter cursor (PlayerGui.ThrowHud.Screen.Meter, the 104x20 frame,
-- Position.Y = 1 - meter) and, the moment it's at the top, hands a tap to
-- ThrowClient's own input handler. ThrowClient then sends Throw.Tap itself
-- with the time right then: a real top-of-meter tap.
local Tap = { info = "waiting for a throw", perfect = 0 }
do
    local tapped = false
    local handlers, foundAt = {}, -math.huge
    local FAKE = { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown,
        UserInputState = Enum.UserInputState.Begin, Position = Vector3.zero }
    local function findHandlers()
        if os.clock() - foundAt < 1 and #handlers > 0 then
            return handlers
        end
        foundAt = os.clock()
        handlers = {}
        if typeof(getconnections) ~= "function" then
            return handlers
        end
        for _, conn in getconnections(UserInputService.InputBegan) do
            local f = conn.Function
            if type(f) == "function" then
                local ok, src = pcall(debug.info, f, "s")
                if ok and type(src) == "string" and src:find("ThrowClient", 1, true) then
                    table.insert(handlers, f)
                end
            end
        end
        return handlers
    end
    local function cursor()
        local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hud = gui and gui:FindFirstChild("ThrowHud")
        local screen = hud and hud.Enabled and hud:FindFirstChild("Screen")
        local meter = screen and screen:FindFirstChild("Meter")
        if not (meter and meter.Visible) then
            return nil
        end
        for _, c in meter:GetChildren() do
            if c:IsA("Frame") and c.Size.X.Offset == 104 and c.Size.Y.Offset == 20 then
                return c
            end
        end
        return nil
    end
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        if LocalPlayer:GetAttribute("ThrowAiming") ~= true then
            tapped = false
            return
        end
        if not Settings.PerfectTap or tapped then
            return
        end
        local c = cursor()
        if not c then
            return
        end
        local m = 1 - c.Position.Y.Scale
        Tap.info = ("meter %.2f"):format(m)
        if m >= Settings.TapAt then
            local list = findHandlers()
            if #list == 0 then
                Tap.info = "tap handler not found (needs getconnections)"
                return
            end
            tapped = true
            for _, f in list do
                task.spawn(pcall, f, FAKE, false)
            end
            Tap.perfect += 1
            Tap.info = ("tapped at %.2f"):format(m)
        end
    end)
end

--// Farm mode: throw, train, or take turns \\--
local Farm = { info = "off" }
do
    local weSetAuto = false
    local turn, turnStarted = "Throw", os.clock()
    local function setAuto(on)
        if (LocalPlayer:GetAttribute("AutoThrow") == true) ~= on then
            pcall(R.SetAuto.FireServer, R.SetAuto, on)
        end
        weSetAuto = on
    end
    local function station()
        local idx = LocalPlayer:GetAttribute("PenIndex")
        local map = Workspace:FindFirstChild("Map")
        local hub = map and map:FindFirstChild("Hub")
        local pens = hub and hub:FindFirstChild("Pens")
        local pen = idx and pens and pens:FindFirstChild("Pen" .. idx)
        local stations = pen and pen:FindFirstChild("Stations")
        return stations and stations:FindFirstChild("PullUp")
    end
    local function goTrain()
        if charAttr("Training") == true then
            Farm.info = "training"
            return
        end
        if charAttr("Throwing") == true or LocalPlayer:GetAttribute("ThrowAiming") == true then
            Farm.info = "finishing the throw first"
            return
        end
        local st = station()
        local centre = st and st:GetAttribute("ZoneCenter")
        local root, hum = rootPart(), humanoid()
        if not (typeof(centre) == "Vector3" and root and hum) then
            Farm.info = "pull-up station not found"
            return
        end
        local flatDist = Vector2.new(root.Position.X - centre.X, root.Position.Z - centre.Z).Magnitude
        if flatDist > (st:GetAttribute("ZoneRadius") or 7) - 1 then
            if Settings.TeleportToStation then
                root.CFrame = CFrame.new(centre + Vector3.new(0, 3, 0))
            else
                hum:MoveTo(centre)
            end
            Farm.info = ("going to the pull-up bar (%d studs)"):format(math.floor(flatDist))
        else
            -- The game starts training when you step in; this is the same call.
            pcall(R.PullStart.FireServer, R.PullStart)
            Farm.info = "starting pull-ups"
        end
    end
    local function goThrow()
        if charAttr("Training") == true then
            pcall(R.PullStop.FireServer, R.PullStop)
        end
        setAuto(true)
        Farm.info = Tap.info
    end
    loop(1, function()
        local mode = Settings.FarmMode
        if mode == "Off" then
            if weSetAuto then
                setAuto(false)
            end
            Farm.info = "off"
            return
        end
        local want = mode
        if mode == "Alternate" then
            if os.clock() - turnStarted > Settings.AlternateMinutes * 60 then
                turn = turn == "Throw" and "Train" or "Throw"
                turnStarted = os.clock()
            end
            want = turn
        end
        if want == "Train" then
            if LocalPlayer:GetAttribute("AutoThrow") == true and charAttr("Throwing") ~= true then
                setAuto(false)
            end
            goTrain()
        else
            goThrow()
        end
        if mode == "Alternate" then
            Farm.info = ("%s (%s for %d more s)"):format(Farm.info, turn,
                math.max(0, math.floor(Settings.AlternateMinutes * 60 - (os.clock() - turnStarted))))
        end
    end)
    table.insert(Cleanups, function()
        if weSetAuto then
            pcall(R.SetAuto.FireServer, R.SetAuto, false)
        end
    end)
end

--// Pull-up boosts \\--
local Boost = { claimed = 0 }
if R.BoostOffer then
    bind(R.BoostOffer.OnClientEvent, function(id)
        if not (alive() and Settings.BoostClaim) then
            return
        end
        task.delay(Settings.BoostDelay, function()
            pcall(R.BoostClaim.FireServer, R.BoostClaim, id)
            Boost.claimed += 1
        end)
    end)
end

--// Baddies: equip best, sell, fuse \\--
local Baddies = { info = "", sold = 0, fused = 0 }
do
    local function rank(name)
        return table.find(RARITIES, name) or 1
    end
    local function entryOf(item)
        local id = item:GetAttribute("BaddieId")
        local def = Catalog and id and Catalog.Get(id)
        if not def then
            return nil
        end
        local rarity = def.Rarity
        if type(rarity) ~= "string" and Catalog.RarityOf and def.OneIn then
            rarity = Catalog.RarityOf(def.OneIn)
        end
        return {
            uid = item.Name, item = item, def = def, rarity = rarity or "Common",
            size = item:GetAttribute("Size") or "Normal", mutation = item:GetAttribute("Mutation") or "None",
            locked = item:GetAttribute("Favorite") == true or item:GetAttribute("Equipped") == true
                or item:GetAttribute("Pending") == true or item:GetAttribute("InFuser") ~= nil,
        }
    end
    function Baddies.list()
        local inv = LocalPlayer:FindFirstChild("BaddieInventory")
        local out = {}
        if inv then
            for _, item in inv:GetChildren() do
                local e = entryOf(item)
                if e then
                    table.insert(out, e)
                end
            end
        end
        return out
    end

    -- Equip best a moment after a new baddie arrives.
    local inv = LocalPlayer:FindFirstChild("BaddieInventory") or LocalPlayer:WaitForChild("BaddieInventory", 10)
    local equipQueued = false
    if inv then
        bind(inv.ChildAdded, function()
            if not (alive() and Settings.AutoEquipBest) or equipQueued then
                return
            end
            equipQueued = true
            task.delay(2, function()
                equipQueued = false
                pcall(R.EquipBest.FireServer, R.EquipBest)
            end)
        end)
    end

    -- Fuse: three copies of the same baddie, size and mutation.
    function Baddies.fuseOnce()
        if not (FuseConfig and R.FuseAdd and R.Fuse) then
            return false
        end
        local groups = {}
        for _, e in Baddies.list() do
            if not e.locked and not e.def.Exclusive and rank(e.rarity) >= rank(Settings.FuseFrom) then
                local problem = FuseConfig.Problem and FuseConfig.Problem(e.def.Id or e.item:GetAttribute("BaddieId"), e.size, e.mutation, e.item)
                if not problem then
                    local key = FuseConfig.KeyOf(e.item)
                    groups[key] = groups[key] or {}
                    table.insert(groups[key], e)
                end
            end
        end
        for _, g in groups do
            if #g >= (FuseConfig.Copies or 3) then
                for slot = 1, FuseConfig.Copies or 3 do
                    local ok = pcall(R.FuseAdd.InvokeServer, R.FuseAdd, g[slot].uid, slot)
                    if not ok then
                        return false
                    end
                end
                local ok = pcall(R.Fuse.InvokeServer, R.Fuse)
                if ok then
                    Baddies.fused += 1
                    Baddies.info = "fused 3 " .. tostring(g[1].def.Name or g[1].uid)
                end
                return ok
            end
        end
        return false
    end
    loop(function()
        return Settings.FuseEvery
    end, function()
        if Settings.AutoFuse then
            -- A few in a row, then wait.
            for _ = 1, 5 do
                if not Baddies.fuseOnce() then
                    break
                end
                task.wait(1)
            end
        end
    end)

    -- Sell everything below a rarity, keeping favourites, pen baddies,
    -- mutated ones and big ones if you want.
    function Baddies.sellNow()
        local uids = {}
        for _, e in Baddies.list() do
            local keep = e.locked or rank(e.rarity) >= rank(Settings.SellBelow)
                or (Settings.KeepMutated and e.mutation ~= "None")
                or (Settings.KeepBig and e.size ~= "Normal")
            if not keep then
                table.insert(uids, e.uid)
            end
        end
        if #uids > 0 then
            local ok = pcall(R.Sell.InvokeServer, R.Sell, uids)
            if ok then
                Baddies.sold += #uids
                Baddies.info = ("sold %d"):format(#uids)
            end
        end
        return #uids
    end
    loop(function()
        return Settings.SellEvery
    end, function()
        if Settings.AutoSell then
            -- Fuse first so copies aren't sold before they can be fused.
            if Settings.AutoFuse then
                Baddies.fuseOnce()
            end
            Baddies.sellNow()
        end
    end)

    -- Pen upgrades.
    loop(function()
        return Settings.UpgradeEvery
    end, function()
        if Settings.AutoUpgrade and R.PenPress then
            pcall(R.PenPress.FireServer, R.PenPress)
        end
    end)
end

--// Claims and anti-AFK \\--
do
    loop(600, function()
        if not Settings.AutoClaims then
            return
        end
        pcall(R.ClaimOffline.FireServer, R.ClaimOffline)
        if LocalPlayer:GetAttribute("GroupRewardClaimed") ~= true and R.GroupClaim then
            pcall(R.GroupClaim.InvokeServer, R.GroupClaim)
        end
    end)
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, conn in getconnections(LocalPlayer.Idled) do
                if not idled[conn] and pcall(conn.Disable, conn) then
                    idled[conn] = true
                end
            end
        elseif next(idled) then
            for conn in idled do
                pcall(conn.Enable, conn)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for conn in idled do
            pcall(conn.Enable, conn)
        end
    end)
end

--// Tests \\--
-- Snapshots every number on your player (attributes and leaderstats) before
-- and after, and shows what changed.
local Tests = { info = "not run" }
do
    local function snapshot()
        local out = {}
        for k, v in LocalPlayer:GetAttributes() do
            if type(v) == "number" then
                out["@" .. k] = v
            end
        end
        for _, folder in { LocalPlayer:FindFirstChild("leaderstats"), LocalPlayer:FindFirstChild("Stats") } do
            if folder then
                for _, v in folder:GetChildren() do
                    if v:IsA("NumberValue") or v:IsA("IntValue") then
                        out[v.Name] = v.Value
                    end
                end
            end
        end
        return out
    end
    local function diff(a, b)
        local lines = {}
        for k, v in b do
            local d = v - (a[k] or 0)
            if d ~= 0 and not k:lower():find("time") then
                table.insert(lines, ("%s %+g"):format(k, d))
            end
        end
        table.sort(lines)
        return #lines > 0 and table.concat(lines, "\n", 1, math.min(#lines, 8)) or "nothing changed"
    end
    function Tests.race(label, fire)
        Tests.info = "running " .. label .. "..."
        task.spawn(function()
            local before = snapshot()
            for _ = 1, Settings.RaceBurst do
                task.spawn(pcall, fire)
            end
            task.wait(3)
            Tests.info = ("%s x%d:\n%s"):format(label, Settings.RaceBurst, diff(before, snapshot()))
        end)
    end
    function Tests.strength(mult)
        local s = LocalPlayer:GetAttribute("Strength") or 0
        local want = math.floor(s * mult)
        pcall(R.SetStrength.FireServer, R.SetStrength, want)
        Tests.info = mult == 1 and ("throw strength back to %d"):format(s)
            or ("asked to throw at %d (you have %d). Throw once: a much longer throw means the server didn't cap it"):format(want, s)
    end
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Throw Food For Baddies",
    Footer = "dookie hub · Ui3",
    Icon = "utensils",
    Size = UDim2.fromOffset(640, 500),
    ConfigFolder = "Ui3/ThrowFoodForBaddies",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function slider(box, key, text, min, max, rounding, suffix, tip)
    return box:AddSlider(key, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end

do
    local Tab = Window:AddTab("Farm", "utensils", "Throws and training")
    local ThrowBox = Tab:AddLeftGroupbox("Perfect throw", "target")
    toggle(ThrowBox, "PerfectTap", "Perfect tap",
        "Taps for you the moment the power meter is at the top, through the game's own tap. Every throw is max power, so it goes further and finds rarer baddies")
    slider(ThrowBox, "TapAt", "Tap at", 0.9, 0.995, 3, "", "PERFECT starts at 0.95. 0.975 leaves room for frame timing")
    local TapLabel = ThrowBox:AddLabel("...", true)

    local FarmBox = Tab:AddRightGroupbox("Farm", "repeat")
    dropdown(FarmBox, "FarmMode", "Mode", { "Off", "Throw", "Train", "Alternate" },
        "Throw: the game's own auto throw with perfect taps. Train: pull-ups at your pen. Alternate: takes turns")
    slider(FarmBox, "AlternateMinutes", "Alternate every", 1, 30, 0, " min")
    toggle(FarmBox, "TeleportToStation", "Teleport to the pull-up bar", "Off: walks there")
    toggle(FarmBox, "BoostClaim", "Claim pull-up boosts", "Takes every 2x speed boost the game offers while you train")
    slider(FarmBox, "BoostDelay", "Boost delay", 0, 2, 1, " s", "How long to wait before claiming (a human takes a moment)")
    local FarmLabel = FarmBox:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                TapLabel:SetText(("Now: %s\nPerfect taps: %d"):format(Tap.info, Tap.perfect))
                FarmLabel:SetText(("Now: %s\nBoosts claimed: %d\nStrength: %s"):format(Farm.info, Boost.claimed,
                    tostring(LocalPlayer:GetAttribute("Strength") or "?")))
            end)
            task.wait(0.4)
        end
    end)
end

do
    local Tab = Window:AddTab("Baddies", "users", "Pen, selling, fusing")
    local Pen = Tab:AddLeftGroupbox("Pen", "home")
    toggle(Pen, "AutoEquipBest", "Auto equip best", "Puts your best baddies in the pen after each new one")
    toggle(Pen, "AutoUpgrade", "Auto upgrade pen", "Presses the pen upgrade whenever it can (the server checks your money)")
    slider(Pen, "UpgradeEvery", "Try every", 2, 60, 0, " s")
    toggle(Pen, "AutoClaims", "Auto claim", "Offline income and the group reward (3 lucky throws, once)")
    toggle(Pen, "AntiAfk", "Anti-AFK")

    local Sell = Tab:AddRightGroupbox("Sell", "dollar-sign")
    toggle(Sell, "AutoSell", "Auto sell", "Never sells favourites or baddies in your pen or the fuser")
    dropdown(Sell, "SellBelow", "Sell below", RARITIES, "Keeps this rarity and anything better")
    toggle(Sell, "KeepMutated", "Keep mutated")
    toggle(Sell, "KeepBig", "Keep bigger sizes")
    slider(Sell, "SellEvery", "Sell every", 5, 300, 0, " s")
    Sell:AddButton({ Text = "Sell now", Func = function()
        task.spawn(function()
            notify(("Sold %d"):format(Baddies.sellNow()))
        end)
    end })

    local Fuse = Tab:AddRightGroupbox("Fuse", "combine")
    toggle(Fuse, "AutoFuse", "Auto fuse", "Fuses any 3 copies of the same baddie, size and mutation (not favourites, pen or egg baddies)")
    dropdown(Fuse, "FuseFrom", "Only from", RARITIES, "Lowest rarity it will fuse")
    slider(Fuse, "FuseEvery", "Check every", 5, 120, 0, " s")
    local BadLabel = Fuse:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                BadLabel:SetText(("Sold %d, fused %d\n%s"):format(Baddies.sold, Baddies.fused, Baddies.info))
            end)
            task.wait(0.5)
        end
    end)
end

do
    local Tab = Window:AddTab("Tests", "flask-conical", "Things the server might not check")
    local Str = Tab:AddLeftGroupbox("Throw strength", "dumbbell")
    Str:AddLabel("The 'throw weaker' slider sends a number. This sends more than you have. If the server caps it, nothing changes.", true)
    slider(Str, "StrengthMult", "Ask for", 2, 1000, 0, "x your strength")
    Str:AddButton({ Text = "Send it", Func = function()
        Tests.strength(Settings.StrengthMult)
    end })
    Str:AddButton({ Text = "Back to normal", Func = function()
        Tests.strength(1)
    end })

    local Race = Tab:AddRightGroupbox("Claim races", "copy")
    Race:AddLabel("Sends a claim several times at once and shows every number that changed.", true)
    slider(Race, "RaceBurst", "Claims at once", 2, 10, 0, "")
    Race:AddButton({ Text = "Offline income", Func = function()
        Tests.race("offline income", function()
            R.ClaimOffline:FireServer()
        end)
    end })
    Race:AddButton({ Text = "Group reward", Func = function()
        Tests.race("group reward", function()
            R.GroupClaim:InvokeServer()
        end)
    end })
    local TestLabel = Tab:AddLeftGroupbox("Result", "info"):AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                TestLabel:SetText(Tests.info)
            end)
            task.wait(0.4)
        end
    end)
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__TffbUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded" .. ((typeof(getconnections) ~= "function") and " (no getconnections: perfect tap off)" or ""), 4)

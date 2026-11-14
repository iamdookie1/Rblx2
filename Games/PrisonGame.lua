--// Prison (Game) -----------------------------------------------------------------------------
-- place 98209195022854 (game 10771327607). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Dig     DigClient casts a ray from the camera (Config.REACH, 7 studs) into
--           workspace.Game; a hit on a part inside a "Voxels" folder becomes a
--           target { i, j, k, axis, su, sv } on Grid (0.25 stud cubes) and its
--           local swing() sends Remotes.Dig:FireServer(i, j, k, axis, su, sv).
--           The time between punches is Config.stat(player, "Speed") seconds,
--           counted on the client. Holding to keep punching is the AutoDig
--           upgrade. Grid.unbreakable(i, j, k) is the rock you can't break.
--   Sell    A full backpack sets the BackpackFull attribute; the crusher's
--           SellPrompt (workspace.Game.Crusher.Base.Body) sells it.
--   Buy     Remotes.Buy:FireServer(upgradeId); Config.UPGRADES, Config.level,
--           Config.cost and Config.unlocked say what you can afford.
--   Other   Remotes.Unstuck and Remotes.GoToExit are the game's own buttons.
--
-- Auto dig calls DigClient's own swing(). The nuker and the buy / sell helpers
-- send the same remotes the game does. The server may still check punch rate
-- and distance: if blocks stop breaking, lower the speed or the reach.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__PrisonUnload then
    pcall(Genv.__PrisonUnload)
end
Genv.__PrisonRun = (Genv.__PrisonRun or 0) + 1
local RUN = Genv.__PrisonRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__PrisonRun == RUN
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

local Settings = {
    -- dig
    AutoDig = false, DigSpeed = 100, ReachOn = false, Reach = 12,
    -- nuker
    Nuker = false, NukeMode = "Where I look", NukeReach = 10, NukeRays = 12, NukeSpread = 35, NukeEvery = 0.25,
    -- money
    AutoSell = false, SellMode = "Teleport", AutoBuy = false, BuyBranch = "All", BuyEvery = 2,
    -- esp / player
    EspExit = false, EspCrusher = false, SpeedOn = false, SpeedMult = 1.4, JumpOn = false, JumpMult = 1.3, AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[Prison] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Prison", Description = text, Time = seconds or 3 })
end
local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

--// The game's modules and remotes \\--
local GameFolder = ReplicatedStorage:WaitForChild("Game", 10)
local function mod(name)
    local ok, m = pcall(function()
        return require(GameFolder:WaitForChild(name, 5))
    end)
    return ok and type(m) == "table" and m or nil
end
local Config, Grid, Shapes = mod("Config"), mod("Grid"), mod("Shapes")
local Remotes = GameFolder and GameFolder:WaitForChild("Remotes", 5)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end
local World = Workspace:FindFirstChild("Game")

local function blocked()
    for _, a in { "MenuOpen", "Escaped", "Cinematic", "LuckyScene", "Carrying" } do
        if LocalPlayer:GetAttribute(a) then
            return true
        end
    end
    return false
end

--// Targets: the same ray and maths DigClient uses \\--
local Voxel = {}
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    function Voxel.cast(from, dir)
        World = World or Workspace:FindFirstChild("Game")
        if not (World and Grid and Shapes) then
            return nil
        end
        params.FilterDescendantsInstances = { World }
        local hit = Workspace:Raycast(from, dir, params)
        if not hit or not hit.Instance.Parent or hit.Instance.Parent.Name ~= "Voxels" then
            return nil
        end
        local i, j, k = Grid.toCell(hit.Position - hit.Normal * (Grid.SIZE / 2))
        local axis = Shapes.axisOf(hit.Normal)
        local ax = Shapes.AXES[axis]
        if not ax then
            return nil
        end
        local off = hit.Position - Grid.center(i, j, k)
        return {
            i = i, j = j, k = k, axis = axis,
            su = off:Dot(ax.u) >= 0 and 1 or -1, sv = off:Dot(ax.v) >= 0 and 1 or -1,
            pos = hit.Position,
        }
    end
    function Voxel.breakable(t)
        local ok, rock = pcall(Grid.unbreakable, t.i, t.j, t.k)
        return not (ok and rock)
    end
end

--// Auto dig and reach \\--
local Dig = { status = "searching", info = "off", swings = 0 }
do
    local swing
    local function find()
        if typeof(getgc) ~= "function" then
            Dig.status = "your executor has no getgc"
            return
        end
        for _, f in getgc() do
            if type(f) == "function" and (typeof(islclosure) ~= "function" or islclosure(f)) then
                local okN, name = pcall(debug.info, f, "n")
                if okN and name == "swing" then
                    local okS, src = pcall(debug.info, f, "s")
                    if okS and type(src) == "string" and src:find("DigClient", 1, true) then
                        swing = f
                        Dig.status = "ready"
                        return
                    end
                end
            end
        end
        Dig.status = "swing not found yet"
    end
    task.spawn(find)
    loop(10, function()
        if not swing then
            find()
        end
    end)

    -- Reach: DigClient reads Config.REACH on every aim.
    local origReach = Config and Config.REACH
    loop(0.3, function()
        if Config and type(origReach) == "number" then
            Config.REACH = Settings.ReachOn and Settings.Reach or origReach
        end
    end)
    table.insert(Cleanups, function()
        if Config and origReach then
            Config.REACH = origReach
        end
    end)

    local function interval()
        local base = 0.4
        if Config and Config.stat then
            local ok, v = pcall(Config.stat, LocalPlayer, "Speed")
            base = ok and type(v) == "number" and v or base
        end
        return math.max(0.05, base * 100 / math.max(Settings.DigSpeed, 10))
    end
    Dig.interval = interval
    loop(interval, function()
        if not Settings.AutoDig then
            Dig.info = "off"
            return
        end
        if not swing then
            Dig.info = Dig.status
            return
        end
        if blocked() then
            Dig.info = "waiting (menu or scene)"
            return
        end
        local cam = Workspace.CurrentCamera
        local reach = Config and Config.REACH or 7
        if cam and Voxel.cast(cam.CFrame.Position, cam.CFrame.LookVector * reach) then
            -- One frame so DigClient's own aim sees the same block.
            task.wait()
            pcall(swing)
            Dig.swings += 1
            Dig.info = LocalPlayer:GetAttribute("BackpackFull") and "backpack full" or "digging"
        else
            Dig.info = "look at a wall"
        end
    end)
end

--// Nuker: Dig for blocks you aren't aiming at \\--
local Nuke = { info = "off", sent = 0 }
do
    local DigRemote = remote("Dig")
    local function directions(root, cam)
        local mode = Settings.NukeMode
        local base
        if mode == "Where I walk" then
            local hum = humanoid()
            local mv = hum and hum.MoveDirection or Vector3.zero
            base = mv.Magnitude > 0.1 and mv.Unit or root.CFrame.LookVector
        elseif mode == "Down" then
            base = Vector3.new(0, -1, 0)
        else
            base = cam.CFrame.LookVector
        end
        local out = {}
        if mode == "All around" then
            local n = Settings.NukeRays
            for a = 0, n - 1 do
                -- A golden-angle sphere of directions.
                local y = 1 - 2 * (a + 0.5) / n
                local r = math.sqrt(1 - y * y)
                local th = a * 2.39996
                table.insert(out, Vector3.new(math.cos(th) * r, y, math.sin(th) * r))
            end
            return out
        end
        local cf = CFrame.lookAt(Vector3.zero, base)
        table.insert(out, base)
        local spread = math.rad(Settings.NukeSpread)
        for a = 1, Settings.NukeRays - 1 do
            local ring = spread * math.sqrt(a / Settings.NukeRays)
            local th = a * 2.39996
            table.insert(out, (cf * CFrame.Angles(math.sin(th) * ring, math.cos(th) * ring, 0)).LookVector)
        end
        return out
    end
    loop(function()
        return Settings.NukeEvery
    end, function()
        if not Settings.Nuker then
            Nuke.info = "off"
            return
        end
        local root, cam = rootPart(), Workspace.CurrentCamera
        if not (DigRemote and root and cam and Grid) then
            Nuke.info = "not ready"
            return
        end
        if blocked() then
            Nuke.info = "waiting (menu or scene)"
            return
        end
        if LocalPlayer:GetAttribute("BackpackFull") then
            Nuke.info = "backpack full"
            return
        end
        local from = root.Position + Vector3.new(0, 1.5, 0)
        local seen, n = {}, 0
        for _, dir in directions(root, cam) do
            local t = Voxel.cast(from, dir * Settings.NukeReach)
            if t and Voxel.breakable(t) then
                local key = t.i .. "," .. t.j .. "," .. t.k
                if not seen[key] then
                    seen[key] = true
                    DigRemote:FireServer(t.i, t.j, t.k, t.axis, t.su, t.sv)
                    n += 1
                end
            end
        end
        Nuke.sent += n
        Nuke.info = n > 0 and ("hit %d blocks"):format(n) or "no breakable block in reach"
    end)
end

--// Auto sell \\--
local Sell = { info = "off", count = 0 }
do
    local function prompt()
        World = World or Workspace:FindFirstChild("Game")
        local crusher = World and World:FindFirstChild("Crusher")
        local base = crusher and crusher:FindFirstChild("Base")
        local body = base and base:FindFirstChild("Body")
        local att = body and body:FindFirstChild("PromptAttachment")
        return att and att:FindFirstChild("SellPrompt"), att
    end
    Sell.prompt = prompt
    local busy = false
    loop(1, function()
        if not Settings.AutoSell then
            Sell.info = "off"
            return
        end
        if busy or not LocalPlayer:GetAttribute("BackpackFull") then
            Sell.info = busy and Sell.info or "waiting for a full backpack"
            return
        end
        local p, att = prompt()
        local root, hum = rootPart(), humanoid()
        if not (p and att and root and hum) then
            Sell.info = "crusher not found"
            return
        end
        if typeof(fireproximityprompt) ~= "function" then
            Sell.info = "your executor has no fireproximityprompt"
            return
        end
        busy = true
        local back = root.CFrame
        local spot = att.WorldPosition
        if Settings.SellMode == "Teleport" then
            root.CFrame = CFrame.new(spot + Vector3.new(0, 3, 0))
        else
            Sell.info = "walking to the crusher"
            local t0 = os.clock()
            while alive() and (root.Position - spot).Magnitude > p.MaxActivationDistance - 1 and os.clock() - t0 < 25 do
                hum:MoveTo(spot)
                task.wait(0.3)
            end
        end
        task.wait(0.3)
        local t0 = os.clock()
        while alive() and LocalPlayer:GetAttribute("BackpackFull") and os.clock() - t0 < 6 do
            local hold = p.HoldDuration
            p.HoldDuration = 0
            pcall(fireproximityprompt, p)
            p.HoldDuration = hold
            task.wait(0.5)
        end
        if not LocalPlayer:GetAttribute("BackpackFull") then
            Sell.count += 1
            Sell.info = "sold"
        else
            Sell.info = "couldn't sell (too far, or the prompt is off)"
        end
        if Settings.SellMode == "Teleport" then
            root.CFrame = back
        else
            local t1 = os.clock()
            while alive() and (root.Position - back.Position).Magnitude > 3 and os.clock() - t1 < 25 do
                hum:MoveTo(back.Position)
                task.wait(0.3)
            end
        end
        busy = false
    end)
end

--// Auto buy \\--
local Buy = { info = "off", bought = 0, branches = { "All" } }
do
    local BuyRemote = remote("Buy")
    if Config and type(Config.UPGRADES) == "table" then
        local seen = {}
        for _, u in Config.UPGRADES do
            if type(u.branch) == "string" and not seen[u.branch] then
                seen[u.branch] = true
                table.insert(Buy.branches, u.branch)
            end
        end
    end
    loop(function()
        return Settings.BuyEvery
    end, function()
        if not Settings.AutoBuy then
            Buy.info = "off"
            return
        end
        if not (BuyRemote and Config and Config.UPGRADES) then
            Buy.info = "shop data not found"
            return
        end
        local money = LocalPlayer:GetAttribute("Money") or 0
        local best, bestCost
        for _, u in Config.UPGRADES do
            if Settings.BuyBranch == "All" or u.branch == Settings.BuyBranch then
                pcall(function()
                    local level = Config.level(LocalPlayer, u.id)
                    if level >= #u.values or not Config.unlocked(LocalPlayer, u) then
                        return
                    end
                    if u.ping and Config.pingDone() then
                        return
                    end
                    local cost = Config.cost(u, level)
                    if type(cost) == "number" and cost <= money and (not bestCost or cost < bestCost) then
                        best, bestCost = u, cost
                    end
                end)
            end
        end
        if best then
            BuyRemote:FireServer(best.id)
            Buy.bought += 1
            Buy.info = ("bought %s for %d"):format(tostring(best.name or best.id), bestCost)
        else
            Buy.info = "nothing affordable"
        end
    end)
end

--// ESP: the exit and the crusher \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "PrisonEsp"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local marks = {}
    local function mark(key, target, color, text)
        local m = marks[key]
        if not target then
            if m then
                m.hl:Destroy()
                m.bb:Destroy()
                marks[key] = nil
            end
            return
        end
        if m and m.hl.Adornee == target then
            return
        end
        if m then
            m.hl:Destroy()
            m.bb:Destroy()
        end
        local hl = Instance.new("Highlight")
        hl.FillColor, hl.OutlineColor = color, color
        hl.FillTransparency = 0.6
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = target
        hl.Parent = folder
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(160, 30)
        bb.AlwaysOnTop = true
        bb.Adornee = target
        bb.Parent = folder
        local t = Instance.new("TextLabel")
        t.BackgroundTransparency = 1
        t.Size = UDim2.fromScale(1, 1)
        t.Font = Enum.Font.GothamBold
        t.TextSize = 14
        t.TextColor3 = color
        t.TextStrokeTransparency = 0.3
        t.Text = text
        t.Parent = bb
        marks[key] = { hl = hl, bb = bb }
    end
    loop(1, function()
        World = World or Workspace:FindFirstChild("Game")
        mark("exit", Settings.EspExit and World and World:FindFirstChild("Exit") or nil, Color3.fromRGB(90, 255, 120), "EXIT")
        mark("crusher", Settings.EspCrusher and World and World:FindFirstChild("Crusher") or nil, Color3.fromRGB(255, 200, 60), "CRUSHER")
    end)
end

--// Speed, jump, anti-AFK \\--
local Move = { info = "" }
do
    local base = {}
    loop(0.3, function()
        local hum = humanoid()
        if not hum then
            return
        end
        if base.hum ~= hum then
            base = { hum = hum, speed = nil, jump = nil, setSpeed = nil, setJump = nil }
        end
        -- Whatever the game last set is the base; ours is base x multiplier.
        if base.setSpeed == nil or math.abs(hum.WalkSpeed - base.setSpeed) > 0.01 then
            base.speed = hum.WalkSpeed
        end
        if Settings.SpeedOn and base.speed and base.speed > 0 then
            base.setSpeed = base.speed * Settings.SpeedMult
            hum.WalkSpeed = base.setSpeed
        elseif base.setSpeed and base.speed then
            hum.WalkSpeed = base.speed
            base.setSpeed = nil
        end
        local prop = hum.UseJumpPower and "JumpPower" or "JumpHeight"
        if base.setJump == nil or math.abs(hum[prop] - base.setJump) > 0.01 then
            base.jump = hum[prop]
        end
        if Settings.JumpOn and base.jump and base.jump > 0 then
            base.setJump = base.jump * Settings.JumpMult
            hum[prop] = base.setJump
        elseif base.setJump and base.jump then
            hum[prop] = base.jump
            base.setJump = nil
        end
    end)
    table.insert(Cleanups, function()
        local hum = humanoid()
        if hum and base.hum == hum then
            if base.setSpeed and base.speed then
                hum.WalkSpeed = base.speed
            end
            if base.setJump and base.jump then
                hum[hum.UseJumpPower and "JumpPower" or "JumpHeight"] = base.jump
            end
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

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Prison",
    Footer = "dookie hub · Ui3",
    Icon = "pickaxe",
    Size = UDim2.fromOffset(640, 500),
    ConfigFolder = "Ui3/PrisonGame",
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
local function live(label, fn)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.4)
        end
    end)
end

do
    local Tab = Window:AddTab("Dig", "pickaxe", "Digging")
    local Box = Tab:AddLeftGroupbox("Auto dig", "pickaxe")
    toggle(Box, "AutoDig", "Auto dig", "Keeps punching the block you look at, through the game's own swing. No AutoDig upgrade needed")
    slider(Box, "DigSpeed", "Punch speed", 50, 500, 0, "%", "100% is your real Speed stat. Higher punches faster: if blocks stop breaking, the server is limiting it")
    toggle(Box, "ReachOn", "Longer reach", "How far away you can aim at a block (the game's is 7 studs)")
    slider(Box, "Reach", "Reach", 7, 40, 0, " studs")
    live(Box:AddLabel("...", true), function()
        return ("Swing: %s\nNow: %s\nPunches: %d (every %.2fs)"):format(Dig.status, Dig.info, Dig.swings, Dig.interval())
    end)

    local Nk = Tab:AddRightGroupbox("Nuker", "bomb")
    toggle(Nk, "Nuker", "Nuker", "Breaks blocks around you without aiming, by sending the dig for each one. The most likely thing here to be checked by the server: start small")
    dropdown(Nk, "NukeMode", "Direction", { "Where I look", "Where I walk", "Down", "All around" })
    slider(Nk, "NukeReach", "Reach", 3, 30, 0, " studs")
    slider(Nk, "NukeRays", "Blocks per burst", 1, 40, 0, "")
    slider(Nk, "NukeSpread", "Spread", 5, 80, 0, "°", "How wide the burst fans out around the direction")
    slider(Nk, "NukeEvery", "Burst every", 0.05, 2, 2, " s")
    live(Nk:AddLabel("...", true), function()
        return ("Now: %s\nDigs sent: %d"):format(Nuke.info, Nuke.sent)
    end)
end

do
    local Tab = Window:AddTab("Money", "dollar-sign", "Sell and buy")
    local S = Tab:AddLeftGroupbox("Auto sell", "dollar-sign")
    toggle(S, "AutoSell", "Auto sell", "When your backpack is full: goes to the crusher, sells, and comes back")
    dropdown(S, "SellMode", "How", { "Teleport", "Walk" }, "Walk goes in a straight line, so it can get stuck deep in a tunnel")
    live(S:AddLabel("...", true), function()
        return ("Now: %s\nSold %d times"):format(Sell.info, Sell.count)
    end)
    local B = Tab:AddRightGroupbox("Auto buy", "shopping-cart")
    toggle(B, "AutoBuy", "Auto buy upgrades", "Buys the cheapest upgrade you can afford")
    dropdown(B, "BuyBranch", "Only", Buy.branches)
    slider(B, "BuyEvery", "Check every", 0.5, 30, 1, " s")
    live(B:AddLabel("...", true), function()
        return ("Now: %s\nBought: %d\nMoney: %s"):format(Buy.info, Buy.bought, tostring(LocalPlayer:GetAttribute("Money") or "?"))
    end)
end

do
    local Tab = Window:AddTab("Player", "user", "Movement and helpers")
    local M = Tab:AddLeftGroupbox("Movement", "move")
    toggle(M, "SpeedOn", "Speed boost")
    slider(M, "SpeedMult", "Speed", 1, 3, 2, "x")
    toggle(M, "JumpOn", "Jump boost")
    slider(M, "JumpMult", "Jump", 1, 3, 2, "x")
    toggle(M, "AntiAfk", "Anti-AFK")
    local H = Tab:AddRightGroupbox("Helpers", "map")
    toggle(H, "EspExit", "Show the exit", "Highlights the exit through walls once it exists")
    toggle(H, "EspCrusher", "Show the crusher")
    H:AddButton({ Text = "Unstuck", Func = function()
        local r = remote("Unstuck")
        if r then
            r:FireServer()
        end
    end, Tooltip = "The game's own Unstuck button" })
    H:AddButton({ Text = "Go to exit", Func = function()
        local r = remote("GoToExit")
        if r then
            r:FireServer()
        end
    end, Tooltip = "The game's own Go to exit button (only works when the game allows it)" })
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
Genv.__PrisonUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

local missing = {}
for name, m in { Config = Config, Grid = Grid, Shapes = Shapes, Remotes = Remotes } do
    if not m then
        table.insert(missing, name)
    end
end
notify("Loaded" .. (#missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or ""), 4)

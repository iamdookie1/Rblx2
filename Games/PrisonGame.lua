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
--   Tunnel  The exit is a hidden tunnel {side, l0, l1, depth} the server keeps to
--           itself until someone digs into it (then Wall "Hit" sends it). Before
--           that the only clue the client gets is DuelMap.W "TunnelHeat" (0..1),
--           the cold / warm / hot bar. The tunnel finder pokes each wall and
--           watches that number to point at the right spot.
--   Speed   The server times punches on its side, so punching faster than your
--           Speed stat just gets ignored. Auto tune listens for the Wall "Hit"
--           that answers each punch and settles on the fastest rate that lands.
--   Drill   Remotes.UseDrill(i, j, k, axis) once DrillReadyAt has passed.
--   Gems    Remotes.Nugget "Show" sends each gem's cell box {i0,j0,k0,i1,j1,k1}.
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
    AutoDig = false, DigSpeed = 100, DigAutoTune = true, ReachOn = false, Reach = 12,
    -- escape
    HeatTrail = true, ProbeSpots = 6, AutoDrill = false, DrillAt = "Where I look", EspGems = false,
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
local DuelMap, WallView = mod("DuelMap"), mod("WallView")
-- Match attributes (TunnelHeat, DrillReadyAt...) live on DuelMap.W, which is
-- workspace outside duels.
local function wattr(name)
    local w = DuelMap and DuelMap.W
    local ok, v = pcall(function()
        return w and w:GetAttribute(name)
    end)
    if ok and w then
        return v
    end
    return Workspace:GetAttribute(name)
end
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

    local function baseSpeed()
        local base = 0.4
        if Config and Config.stat then
            local ok, v = pcall(Config.stat, LocalPlayer, "Speed")
            base = ok and type(v) == "number" and v or base
        end
        return base
    end

    -- Auto tune. Every punch that lands comes back as Wall "Hit" with the cells it
    -- broke or damaged. A punch with no Hit near its cell was thrown away by the
    -- server (too soon), so slow down; a run of landed punches, speed up a bit.
    Dig.tuned, Dig.landed, Dig.missed = nil, 0, 0
    local pending = {} -- punches waiting for their Hit: { i, j, k, t }
    local okRun = 0
    local function owner(idx)
        if not (Grid and Grid.coords) then
            return nil
        end
        local ok, i, j, k = pcall(Grid.coords, idx)
        if not ok then
            return nil
        end
        -- The oldest punch near this cell (a punch breaks a small shape, not one cube).
        for n, p in pending do
            if not p.landed and math.abs(i - p.i) <= 8 and math.abs(j - p.j) <= 8 and math.abs(k - p.k) <= 8 then
                return n
            end
        end
        return nil
    end
    local function claim(buf, dmg)
        if typeof(buf) ~= "buffer" then
            return false
        end
        local bits = dmg and (Grid.DMG_BITS or 2097152) or nil
        for o = 0, buffer.len(buf) - 4, 4 do
            local v = buffer.readu32(buf, o)
            local n = owner(bits and v % bits or v)
            if n then
                pending[n].landed = true
                return true
            end
        end
        return false
    end
    local WallRemote = remote("Wall")
    if WallRemote then
        table.insert(Connections, WallRemote.OnClientEvent:Connect(function(kind, broken, damaged)
            if kind == "Hit" and #pending > 0 then
                local _ = claim(broken, false) or claim(damaged, true)
            end
        end))
    end
    -- Score punches once they've had time to come back (0.6 s covers normal ping).
    loop(0.1, function()
        local base = baseSpeed()
        while pending[1] and (pending[1].landed or os.clock() - pending[1].t > 0.6) do
            local p = table.remove(pending, 1)
            Dig.tuned = Dig.tuned or base
            if p.landed then
                Dig.landed += 1
                okRun += 1
                if okRun >= 4 then
                    okRun = 0
                    Dig.tuned = math.max(0.05, Dig.tuned * 0.95)
                end
            else
                Dig.missed += 1
                okRun = 0
                Dig.tuned = math.min(base * 1.5, Dig.tuned * 1.1)
            end
        end
    end)
    Dig.reset = function()
        Dig.tuned, Dig.landed, Dig.missed, okRun = nil, 0, 0, 0
        table.clear(pending)
    end

    local function interval()
        if Settings.DigAutoTune then
            return math.max(0.05, Dig.tuned or baseSpeed())
        end
        return math.max(0.05, baseSpeed() * 100 / math.max(Settings.DigSpeed, 10))
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
        local t = cam and Voxel.cast(cam.CFrame.Position, cam.CFrame.LookVector * reach)
        if t then
            -- One frame so DigClient's own aim sees the same block.
            task.wait()
            local full = LocalPlayer:GetAttribute("BackpackFull")
            pcall(swing)
            Dig.swings += 1
            if not full and Settings.DigAutoTune and Voxel.breakable(t) then
                table.insert(pending, { i = t.i, j = t.j, k = t.k, t = os.clock() })
            end
            Dig.lastHit = { pos = t.pos, t = os.clock() }
            Dig.info = full and "backpack full" or "digging"
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

--// Markers: a floating label in the world \\--
local Marks = {}
do
    local folder = Instance.new("Folder")
    folder.Name = "PrisonMarks"
    folder.Parent = Workspace
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    Marks.folder = folder
    function Marks.new(pos, color, text)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
        p.Transparency = 1
        p.Size = Vector3.new(0.4, 0.4, 0.4)
        p.Position = pos
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.fromOffset(150, 34)
        bb.AlwaysOnTop = true
        bb.MaxDistance = math.huge
        bb.Parent = p
        local t = Instance.new("TextLabel")
        t.BackgroundTransparency = 1
        t.Size = UDim2.fromScale(1, 1)
        t.Font = Enum.Font.GothamBold
        t.TextSize = 13
        t.TextColor3 = color
        t.TextStrokeTransparency = 0.3
        t.Text = text
        t.Parent = bb
        p.Parent = folder
        return p, t
    end
end

--// Tunnel finder: follow TunnelHeat to the hidden exit \\--
local SIDES = { "-Z wall", "+Z wall", "-X wall", "+X wall" }
local Tunnel = { info = "", heat = nil, best = nil, probes = {}, scanning = false }
do
    local DigRemote = remote("Dig")
    local function heat()
        local v = wattr("TunnelHeat")
        return type(v) == "number" and v or nil
    end
    Tunnel.heat = heat
    local function word(h)
        if not h then
            return "no reading yet"
        end
        return ("%d%% %s"):format(math.floor(h * 100 + 0.5), h >= 0.7 and "HOT" or h >= 0.25 and "warm" or "cold")
    end
    Tunnel.word = word
    local function isCell()
        if WallView and WallView.layout then
            local ok, l = pcall(WallView.layout)
            return ok and l == "Cell"
        end
        return true
    end
    -- Which wall a world point is in, and how far along it.
    local function sideOf(pos)
        local half = Grid.ROOM * Grid.SIZE / 2
        local d = pos - Grid.ORIGIN
        if math.abs(d.X) > math.abs(d.Z) then
            return d.X < 0 and 3 or 4, d.Z, half
        end
        return d.Z < 0 and 1 or 2, d.X, half
    end

    local trail = {}
    local function clearTrail()
        for _, m in trail do
            m:Destroy()
        end
        table.clear(trail)
    end
    Tunnel.clear = function()
        clearTrail()
        for _, p in Tunnel.probes do
            if p.mark then
                p.mark:Destroy()
            end
        end
        table.clear(Tunnel.probes)
        Tunnel.best = nil
    end
    table.insert(Cleanups, Tunnel.clear)

    local function setBest(pos, h, side, stand)
        Tunnel.best = { pos = pos, heat = h, side = side, stand = stand }
    end

    -- Heat trail: whenever the heat goes up, drop a mark where we last dug.
    local last = heat()
    loop(0.15, function()
        local h = heat()
        if h and last and h > last + 0.001 and Settings.HeatTrail and not Tunnel.scanning then
            local hit = Dig.lastHit
            local pos = hit and os.clock() - hit.t < 3 and hit.pos
            if not pos then
                local cam = Workspace.CurrentCamera
                local t = cam and Voxel.cast(cam.CFrame.Position, cam.CFrame.LookVector * ((Config and Config.REACH) or 7) * 2)
                pos = t and t.pos
            end
            if pos then
                local color = h >= 0.7 and Color3.fromRGB(255, 80, 60) or h >= 0.25 and Color3.fromRGB(255, 190, 60) or Color3.fromRGB(110, 190, 255)
                local m = Marks.new(pos, color, ("%s (+%d%%)"):format(word(h), math.floor((h - last) * 100 + 0.5)))
                table.insert(trail, m)
                if #trail > 25 then
                    table.remove(trail, 1):Destroy()
                end
                if not Tunnel.best or h >= Tunnel.best.heat then
                    setBest(pos, h, (sideOf(pos)))
                end
            end
        end
        last = h or last
        local hint = wattr("TunnelHint")
        local map = wattr("TunnelMapAt")
        if World and World:FindFirstChild("Exit") then
            Tunnel.info = "The exit is open (turn on Show the exit)"
        elseif typeof(map) == "Vector3" then
            Tunnel.info = "Tunnel map bought: the game marks it"
        elseif type(hint) == "number" and SIDES[hint] then
            Tunnel.info = "Mastermind chalk: it's behind the " .. SIDES[hint]
        elseif Tunnel.best then
            Tunnel.info = ("Hottest so far: %s, %s"):format(SIDES[Tunnel.best.side] or "?", word(Tunnel.best.heat))
        else
            Tunnel.info = "Dig or scan the walls to get a reading"
        end
    end)

    -- Scan: stand in front of each wall at a few spots, punch once, read the heat.
    local function waitHeat(before, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            local h = heat()
            if h and (not before or math.abs(h - before) > 0.0005) then
                return h
            end
            task.wait(0.05)
        end
        return heat()
    end
    function Tunnel.scan()
        if Tunnel.scanning then
            return
        end
        local root = rootPart()
        if not (root and DigRemote and Grid and Grid.OUTWARD) then
            notify("Not ready yet")
            return
        end
        if not isCell() then
            notify("The scan only works inside the cell (chapter 1 walls)")
            return
        end
        if World and World:FindFirstChild("Exit") then
            notify("The exit is already open")
            return
        end
        Tunnel.scanning = true
        local back = root.CFrame
        local half = Grid.ROOM * Grid.SIZE / 2
        local spots = math.max(1, Settings.ProbeSpots)
        local margin = 1.6
        local gap = math.max(0.25, Dig.interval and Dig.interval() or 0.4)
        local done = 0
        for side = 1, 4 do
            local out = Grid.OUTWARD[side]
            local lat = Vector3.new(-out.Z, 0, out.X)
            for n = 1, spots do
                if not alive() or not Tunnel.scanning then
                    break
                end
                if LocalPlayer:GetAttribute("BackpackFull") then
                    Tunnel.info = "Scan paused: backpack full"
                    break
                end
                local off = -half + margin + (n - 0.5) * (2 * (half - margin)) / spots
                local stand = Grid.ORIGIN + out * (half - 2.2) + lat * off
                stand = Vector3.new(stand.X, back.Position.Y, stand.Z)
                root = rootPart()
                if not root then
                    break
                end
                root.CFrame = CFrame.lookAt(stand, stand + out)
                root.AssemblyLinearVelocity = Vector3.zero
                task.wait(0.15)
                local t = Voxel.cast(stand + Vector3.new(0, 1.5, 0), out * 9)
                if t and Voxel.breakable(t) then
                    local before = heat()
                    DigRemote:FireServer(t.i, t.j, t.k, t.axis, t.su, t.sv)
                    local after = waitHeat(before, 1.2) or 0
                    local rose = after > (before or 0) + 0.0005
                    local probe = { pos = t.pos, side = side, heat = after, rose = rose, stand = CFrame.lookAt(stand, stand + out) }
                    probe.mark = Marks.new(t.pos, rose and Color3.fromRGB(255, 120, 60) or Color3.fromRGB(150, 160, 180),
                        (rose and "▲ " or "") .. word(after))
                    table.insert(Tunnel.probes, probe)
                    if rose or not Tunnel.best or after > Tunnel.best.heat then
                        setBest(t.pos, after, side, probe.stand)
                    end
                    done += 1
                    Tunnel.info = ("Scanning %s (%d/%d)"):format(SIDES[side], (side - 1) * spots + n, 4 * spots)
                    task.wait(gap)
                end
            end
        end
        root = rootPart()
        if root then
            root.CFrame = back
        end
        Tunnel.scanning = false
        if Tunnel.best then
            notify(("Scanned %d spots. Hottest: %s, %s"):format(done, SIDES[Tunnel.best.side] or "?", word(Tunnel.best.heat)), 6)
        else
            notify("Scan got no readings (the game may only send heat once you're deeper)", 6)
        end
    end
    function Tunnel.goBest()
        local b = Tunnel.best
        local root = rootPart()
        if not (b and root) then
            notify("No hot spot yet: scan or dig first")
            return
        end
        if b.stand then
            root.CFrame = b.stand
        else
            local cam = Workspace.CurrentCamera
            local dir = (b.pos - root.Position) * Vector3.new(1, 0, 1)
            local stand = b.pos - (dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)) * 2.5
            root.CFrame = CFrame.lookAt(Vector3.new(stand.X, root.Position.Y, stand.Z), Vector3.new(b.pos.X, root.Position.Y, b.pos.Z))
            if cam then
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, b.pos)
            end
        end
    end
end

--// Auto drill \\--
local Drill = { info = "off", used = 0 }
do
    local DrillRemote = remote("UseDrill")
    loop(0.5, function()
        if not Settings.AutoDrill then
            Drill.info = "off"
            return
        end
        local level = 0
        if Config and Config.stat then
            local ok, v = pcall(Config.stat, LocalPlayer, "Drill")
            level = ok and type(v) == "number" and v or 0
        end
        if not DrillRemote or level <= 0 then
            Drill.info = "buy the Drill upgrade first"
            return
        end
        if wattr("DrillActive") then
            Drill.info = "drilling..."
            return
        end
        local wait = (wattr("DrillReadyAt") or 0) - Workspace:GetServerTimeNow()
        if wait > 0 then
            Drill.info = ("ready in %ds"):format(math.ceil(wait))
            return
        end
        if blocked() then
            Drill.info = "waiting (menu or scene)"
            return
        end
        local t, back
        if Settings.DrillAt == "Hottest spot" and Tunnel.best and Tunnel.best.stand then
            local root = rootPart()
            if root then
                back = root.CFrame
                root.CFrame = Tunnel.best.stand
                task.wait(0.15)
                t = Voxel.cast(Tunnel.best.stand.Position + Vector3.new(0, 1.5, 0), Tunnel.best.stand.LookVector * 9)
            end
        else
            local cam = Workspace.CurrentCamera
            t = cam and Voxel.cast(cam.CFrame.Position, cam.CFrame.LookVector * ((Config and Config.REACH) or 7))
        end
        if t and t.axis ~= 3 and t.axis ~= 4 then
            DrillRemote:FireServer(t.i, t.j, t.k, t.axis)
            Drill.used += 1
            Drill.info = "drill placed"
            task.wait(0.4)
        else
            Drill.info = back and "hottest spot has no wall in front" or "ready: look at a wall"
        end
        local root = rootPart()
        if back and root then
            root.CFrame = back
        end
        task.wait(0.6)
    end)
end

--// Gem ESP \\--
local Gems = { info = "off", count = 0 }
do
    local NuggetRemote = remote("Nugget")
    local own = {}
    -- NuggetClient keeps every gem the server told it about in one table; borrow it
    -- so gems sent before we loaded show too.
    local theirs
    local function findTheirs()
        if theirs or not NuggetRemote or typeof(getconnections) ~= "function" or not (debug and debug.getupvalue) then
            return
        end
        for _, c in getconnections(NuggetRemote.OnClientEvent) do
            local f = c.Function
            if type(f) == "function" then
                for n = 1, 8 do
                    local ok, v = pcall(debug.getupvalue, f, n)
                    if ok and type(v) == "table" then
                        local _, g = next(v)
                        if type(g) == "table" and type(g.box) == "table" then
                            theirs = v
                            return
                        end
                    end
                end
            end
        end
    end
    if NuggetRemote then
        table.insert(Connections, NuggetRemote.OnClientEvent:Connect(function(kind, list)
            if kind == "Show" and type(list) == "table" then
                for _, g in list do
                    if type(g) == "table" and type(g.id) == "number" and type(g.box) == "table" then
                        own[g.id] = { box = g.box, value = tonumber(g.value) or 2 }
                    end
                end
            elseif kind == "Take" and type(list) == "table" then
                for _, id in list do
                    own[type(id) == "table" and id.id or id] = nil
                end
            elseif kind == "Clear" then
                table.clear(own)
            end
        end))
    end
    local holder = Instance.new("Part")
    holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch = true, false, false, false
    holder.Transparency = 1
    holder.Size = Vector3.new(0.1, 0.1, 0.1)
    holder.CFrame = CFrame.new()
    holder.Parent = Marks.folder
    local boxes = {}
    local function clear()
        for id, b in boxes do
            b:Destroy()
            boxes[id] = nil
        end
    end
    table.insert(Cleanups, clear)
    loop(1, function()
        if not Settings.EspGems or not Grid then
            clear()
            Gems.info = "off"
            return
        end
        findTheirs()
        local src = theirs or own
        local seen, n = {}, 0
        for id, g in src do
            local b = type(g) == "table" and g.box
            if type(b) == "table" and #b >= 6 then
                seen[id] = true
                n += 1
                if not boxes[id] then
                    local a, z = Grid.center(b[1], b[2], b[3]), Grid.center(b[4], b[5], b[6])
                    local v = tonumber(g.value) or 2
                    local box = Instance.new("BoxHandleAdornment")
                    box.Adornee = holder
                    box.AlwaysOnTop = true
                    box.ZIndex = 5
                    box.Transparency = 0.35
                    box.Color3 = v >= 5 and Color3.fromRGB(255, 210, 60) or v >= 3 and Color3.fromRGB(190, 110, 255) or Color3.fromRGB(70, 180, 255)
                    box.CFrame = CFrame.new((a + z) / 2)
                    box.Size = Vector3.new(b[4] - b[1] + 1, b[5] - b[2] + 1, b[6] - b[3] + 1) * Grid.SIZE
                    box.Parent = holder
                    boxes[id] = box
                end
            end
        end
        for id, b in boxes do
            if not seen[id] then
                b:Destroy()
                boxes[id] = nil
            end
        end
        Gems.count = n
        Gems.info = (theirs and "reading the game's list" or "listening for gems") .. (n == 0 and " (none sent yet)" or "")
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
    Box:AddToggle("DigAutoTune", {
        Text = "Auto tune speed", Default = Settings.DigAutoTune,
        Tooltip = "Finds the fastest punch rate the server still accepts (it ignores punches that come too soon). Turn off to use the slider",
        Callback = function(v)
            Settings.DigAutoTune = v
            Dig.reset()
        end,
    })
    slider(Box, "DigSpeed", "Punch speed (tune off)", 50, 500, 0, "%", "100% is your real Speed stat. Past what the server allows, the extra punches are thrown away")
    toggle(Box, "ReachOn", "Longer reach", "How far away you can aim at a block (the game's is 7 studs)")
    slider(Box, "Reach", "Reach", 7, 40, 0, " studs")
    live(Box:AddLabel("...", true), function()
        local landed = Dig.landed + Dig.missed > 0 and ("\nLanded: %d / %d"):format(Dig.landed, Dig.landed + Dig.missed) or ""
        return ("Swing: %s\nNow: %s\nPunches: %d (every %.2fs)%s"):format(Dig.status, Dig.info, Dig.swings, Dig.interval(), landed)
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
    local Tab = Window:AddTab("Escape", "key", "Find the tunnel")
    local F = Tab:AddLeftGroupbox("Tunnel finder", "compass")
    F:AddButton({ Text = "Scan the walls", Func = function()
        task.spawn(Tunnel.scan)
    end, Tooltip = "Teleports to a few spots on each wall, punches once and reads the hot / cold meter. Comes back when done" })
    F:AddButton({ Text = "Stop scan", Func = function()
        Tunnel.scanning = false
    end })
    slider(F, "ProbeSpots", "Spots per wall", 2, 12, 0, "", "More spots = more exact, slower scan")
    F:AddButton({ Text = "Go to hottest spot", Func = Tunnel.goBest, Tooltip = "Puts you in front of the hottest wall spot found so far" })
    toggle(F, "HeatTrail", "Heat trail", "Every time the meter goes up while you dig, leaves a mark there")
    F:AddButton({ Text = "Clear marks", Func = Tunnel.clear })
    live(F:AddLabel("...", true), function()
        return ("Heat: %s\n%s"):format(Tunnel.word(Tunnel.heat()), Tunnel.info)
    end)

    local D = Tab:AddRightGroupbox("Drill and gems", "zap")
    toggle(D, "AutoDrill", "Auto drill", "Places the team drill the moment its cooldown ends (needs the Drill upgrade)")
    dropdown(D, "DrillAt", "Drill at", { "Where I look", "Hottest spot" }, "Hottest spot teleports to the tunnel finder's best spot, drills, and comes back")
    live(D:AddLabel("...", true), function()
        return ("Drill: %s (used %d)"):format(Drill.info, Drill.used)
    end)
    toggle(D, "EspGems", "Show gems", "Boxes every gem the server has told the game about, through walls")
    live(D:AddLabel("...", true), function()
        return ("Gems: %s, %d shown"):format(Gems.info, Gems.count)
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

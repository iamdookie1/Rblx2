--// Welcome to Bloxburg -- job farm, auto needs, teleports, vehicle speed,
--// player info, anti-AFK.
--
-- Built against a script dump of the live game (place 185655149, game
-- 88070565, version 1383). What the game's own scripts show:
--  * Every request goes through ReplicatedStorage.Modules.DataService
--    (net:FireServer / net:InvokeServer with a { Type = ... } table). The
--    remote names are encrypted, and the module watches who calls it: a call
--    from anything outside PlayerScripts.Modules / ReplicatedStorage.Modules
--    is reported and the client is flooded, and replacing FireServer or
--    InvokeServer is caught every frame. Any script error anywhere is also
--    reported with its script's path.
--  * So nothing here sends a request of its own or hooks anything. Every
--    action runs the game's own code, which makes the request itself:
--      - jobs start and stop through JobHandler (GoToWork, StartWorking,
--        StopWorking);
--      - job objects (trash, desks, mine blocks, crates, shelves, scanned
--        groceries, pizza ingredients) carry their own menu callbacks in
--        InteractionHandler's interaction table, the same callbacks a click
--        runs; the screens' Done buttons run their own click handler;
--      - tools (fishing rod, hatchet, food) are used through
--        HotbarUI.EquipData's Function, the same thing a tap on the hotbar runs;
--      - furniture (bed, shower, TV, fridge) through InteractionHandler's own
--        menu, built in the background and its button clicked; the fridge's
--        quick meal list through the list's own pick;
--      - travel through FastTravelShared, HouseHandler and JobHandler.
--    And every loop is guarded, so no error ever escapes to be reported.
--  * Pay is decided by the server for each finished task; the client never
--    sends an amount. Shifts end if you leave the job's area, so the farm
--    keeps you in it.
--  * 25 RemoteEvents sit right under DataService that the game never uses:
--    likely traps. Nothing here touches them.
--
-- Plots are Folders and the furniture on them are Parts tagged PlotObject;
-- what an item is (bed, shower, fridge) comes from the game's TypeService,
-- the same check its own menus make.
--
-- Jobs it can run: School Janitor, High School Teacher (discipline and hall
-- pass tasks), Cave Miner, Hut Fisherman, Lumber Woodcutter, Supermarket
-- Stocker, Supermarket Cashier, and Pizza Baker (when the order can be read
-- off the workstation; the Jobs tab can capture one if not).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__BloxburgStop) == "function" then pcall(Genv.__BloxburgStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

-- every background loop runs through this: an error never escapes, since the
-- game reports any script error to its server
local function loop(interval, fn)
    task.spawn(function()
        while not Unloaded do
            pcall(fn)
            task.wait(type(interval) == "function" and interval() or interval)
        end
    end)
end

-- runs one of the game's functions on a thread of its own: some of them put
-- up a prompt and wait for a click, which must not stall the farm
local function callFor(timeout, fn, ...)
    local args = table.pack(...)
    local done, results = false, nil
    task.spawn(function()
        results = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < timeout do task.wait(0.1) end
    if not done or not results[1] then return false end
    return true, table.unpack(results, 2, results.n)
end

--// settings ----------------------------------------------------------------

local JOBS = {
    { Id = "SchoolJanitor", Name = "School Janitor" },
    { Id = "HighSchoolTeacher", Name = "High School Teacher" },
    { Id = "CaveMiner", Name = "Cave Miner" },
    { Id = "HutFisherman", Name = "Hut Fisherman" },
    { Id = "LumberWoodcutter", Name = "Lumber Woodcutter" },
    { Id = "SupermarketStocker", Name = "Supermarket Stocker" },
    { Id = "SupermarketCashier", Name = "Supermarket Cashier" },
    { Id = "PizzaPlanetBaker", Name = "Pizza Baker" },
}

local Farm = {
    Enabled = false,
    Job = "SchoolJanitor",
    Pace = 1,             -- delay multiplier between actions; higher is slower and safer
    Walk = true,          -- walk to things (off: step straight to them)
    Status = "off",
    Tasks = 0,
    StartMoney = nil,
    Busy = false,         -- inside a task right now
}

local Needs = {
    Enabled = false,
    Threshold = 35,       -- refill a need once it drops under this
    FillTo = 95,
    Energy = true,
    Hygiene = true,
    Fun = true,
    Hunger = true,
    Status = "off",
    Now = false,          -- refill the lowest one now, whatever its level
}

local Vehicle = { Enabled = false, Multiplier = 1.5 }
local Misc = { AntiAfk = true }

local Library -- the Ui3 menu, loaded last

--// the game's modules ------------------------------------------------------

local Mods = {}

local function playerModules()
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts") or LocalPlayer:WaitForChild("PlayerScripts", 30)
    return scripts and scripts:WaitForChild("Modules", 30)
end

local function find(root, path)
    local node = root
    for part in path:gmatch("[^/]+") do
        node = node and node:WaitForChild(part, 20)
    end
    return node
end

local function load(name, root, path)
    local inst = root and find(root, path)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    if ok and type(result) == "table" then
        Mods[name] = result
        return result
    end
    return nil
end

local Stats -- ReplicatedStorage.Stats.<you>

task.spawn(function()
    local modules = playerModules()
    local shared = ReplicatedStorage:WaitForChild("Modules", 30)
    load("JobHandler", modules, "JobHandler")
    load("InteractionHandler", modules, "InteractionHandler")
    load("CharacterHandler", modules, "CharacterHandler")
    load("HouseHandler", modules, "HouseHandler")
    load("TranslationHandler", modules, "_Utilities/TranslationHandler")
    load("ListFrameHandler", modules, "_Utilities/ListFrameHandler")
    load("HotbarUI", modules, "_UI/HUDHandler/HotbarUI")
    load("FastTravel", shared, "FastTravelShared")
    load("Equipment", shared, "EquipmentService")
    load("TypeService", shared, "TypeService")
    local statsFolder = ReplicatedStorage:WaitForChild("Stats", 30)
    Stats = statsFolder and statsFolder:WaitForChild(LocalPlayer.Name, 30)
end)

local function stat(path)
    local node = Stats
    for part in path:gmatch("[^/]+") do
        node = node and node:FindFirstChild(part)
    end
    return node and node.Value
end

local function myRoot()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return root, hum
end

local function equipped()
    local eq = Mods.Equipment
    if not eq then return nil end
    local ok, item = pcall(eq.GetEquipped, eq, LocalPlayer)
    return ok and item and tostring(item) or nil
end

local function wait(seconds)
    task.wait(seconds * (0.85 + math.random() * 0.3))
end

local function pace(base)
    wait(base * Farm.Pace)
end

local NeedsBusy = false

-- a task in progress gives way when the farm is switched off or needs take over
local function bail()
    return Unloaded or not Farm.Enabled or NeedsBusy
end

--// interactions ------------------------------------------------------------
-- InteractionHandler keeps every custom interaction (job objects mostly) in
-- one table, [object] = { menu functions, ... }. It is an upvalue of its
-- AddInteraction, shared with RemoveInteraction.

local Interactions = nil

local function interactionTable()
    if Interactions then return Interactions end
    local ih = Mods.InteractionHandler
    local getUpvalues = (typeof(debug) == "table" and debug.getupvalues) or getupvalues
    if not ih or type(getUpvalues) ~= "function" then return nil end
    local okA, addUps = pcall(getUpvalues, ih.AddInteraction)
    local okR, removeUps = pcall(getUpvalues, ih.RemoveInteraction)
    if not okA or not okR then return nil end
    local inRemove = {}
    for _, v in pairs(removeUps) do
        if type(v) == "table" then inRemove[v] = true end
    end
    for _, v in pairs(addUps) do
        if type(v) == "table" and v ~= ih and inRemove[v] then
            Interactions = v
            return v
        end
    end
    return nil
end

local function translate(key)
    local tr = Mods.TranslationHandler
    if not tr then return nil end
    local ok, text = pcall(tr.CheckFormat, tr, key)
    return ok and type(text) == "string" and text or nil
end

-- InteractionHandler's own menu for `obj`, built in the background (nothing
-- shows), and its button for the first of `keys` it offers clicked. A button
-- that opens a submenu ("…") is opened and that submenu's first entry clicked.
-- Like a real click it only works within the game's reach of the object.
local SUBMENU = "…"

local function useFurniture(obj, keys)
    local ih = Mods.InteractionHandler
    if not ih or not obj then return false end
    pcall(ih.CloseMenu, ih)
    local ok, menu = pcall(ih.ShowMenu, ih, obj, nil, nil, nil, true)
    if not ok or type(menu) ~= "table" or type(menu.Buttons) ~= "table" or #menu.Buttons == 0 then return false end
    local rank = {}
    for i, key in ipairs(keys) do
        local text = translate(key) or key
        rank[text] = rank[text] or i
        rank[text .. SUBMENU] = rank[text .. SUBMENU] or i
    end
    local best, bestRank = nil, math.huge
    for _, button in ipairs(menu.Buttons) do
        local r = type(button) == "table" and (#keys == 0 and 1 or rank[button.Text])
        if r and r < bestRank then best, bestRank = button, r end
    end
    if not best then
        pcall(menu.Close, menu)
        return false
    end
    local opensMore = type(best.Text) == "string" and best.Text:sub(-#SUBMENU) == SUBMENU
    if not pcall(menu.ClickData, menu, best) then
        pcall(menu.Close, menu)
        return false
    end
    if not opensMore then return true end
    local more = translate("B_More")
    for _, button in ipairs(menu.Buttons) do
        if type(button) == "table" and button ~= best and button.Text ~= more then
            local clicked = pcall(menu.ClickData, menu, button)
            pcall(menu.Close, menu)
            return clicked
        end
    end
    pcall(menu.Close, menu)
    return false
end

-- Runs an object's own menu option, the same callback a click runs. `want`
-- is a label ("I_CleanUp") or nil for the first option it offers right now.
-- Without the interaction table it clicks the same option through the menu.
local function runMenu(obj, want)
    local list = interactionTable()
    if not list then return useFurniture(obj, want and { want } or {}) end
    local entry = obj and list[obj]
    local menu = type(entry) == "table" and entry[1]
    if type(menu) ~= "table" then return false end
    for _, option in ipairs(menu) do
        if type(option) == "function" then
            local ok, label, _, callback = pcall(option, obj)
            if ok and label and type(callback) == "function" and (want == nil or label == want) then
                local done = pcall(callback)
                return done, label
            end
        end
    end
    return false
end

-- one option by its place in the object's menu (for menus whose labels are
-- already translated sentences, like the pizza ingredients)
local function runOption(obj, index, fallbackLabel)
    local list = interactionTable()
    if not list then return fallbackLabel and useFurniture(obj, { fallbackLabel }) or false end
    local entry = obj and list[obj]
    local option = type(entry) == "table" and type(entry[1]) == "table" and entry[1][index]
    if type(option) ~= "function" then return false end
    local ok, label, _, callback = pcall(option, obj)
    if ok and label and type(callback) == "function" then
        return (pcall(callback)), label
    end
    return false
end

local function hasMenu(obj)
    local list = interactionTable()
    if list then return list[obj] ~= nil end
    return obj ~= nil and obj:GetAttribute("InteractionType") == "CustomInteraction"
end

-- a GUI button's own click handlers (the screens' Done buttons)
local function pressButton(button)
    if typeof(button) ~= "Instance" then return false end
    if typeof(getconnections) == "function" then
        local ok, list = pcall(getconnections, button.Activated)
        if ok and type(list) == "table" then
            local fired = false
            for _, connection in ipairs(list) do
                local fn = connection.Function
                if type(fn) == "function" then
                    task.spawn(pcall, fn)
                    fired = true
                end
            end
            if fired then return true end
        end
    end
    if typeof(firesignal) == "function" then
        return (pcall(firesignal, button.Activated))
    end
    return false
end

local function detach()
    local ch = Mods.CharacterHandler
    if ch then pcall(ch.Detach, ch) end
end

--// moving ------------------------------------------------------------------

-- works for parts, models and folders that carry a GroundPosition (plots)
local function position(obj)
    if typeof(obj) ~= "Instance" then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("PVInstance") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok and typeof(pivot) == "CFrame" then return pivot.Position end
    end
    local ground = obj:GetAttribute("GroundPosition")
    if typeof(ground) == "CFrame" then return ground.Position end
    return nil
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function overlapParams()
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    return params
end

-- a clear spot beside `target` with floor under it, the closest to us
local function standSpot(target, distance)
    local root = myRoot()
    if not root then return nil end
    local params = overlapParams()
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { LocalPlayer.Character }
    local best, bestDist = nil, math.huge
    for i = 0, 11 do
        local a = i / 12 * math.pi * 2
        local spot = target + Vector3.new(math.cos(a), 0, math.sin(a)) * (distance or 3)
        local floor = Workspace:Raycast(spot + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), rayParams)
        if floor then
            local stand = floor.Position + Vector3.new(0, 3, 0)
            local blocking = false
            for _, part in ipairs(Workspace:GetPartBoundsInBox(CFrame.new(stand + Vector3.new(0, 0.5, 0)), Vector3.new(1.6, 4, 1.6), params)) do
                if part.CanCollide then
                    blocking = true
                    break
                end
            end
            local d = (stand - root.Position).Magnitude
            if not blocking and d < bestDist then best, bestDist = stand, d end
        end
    end
    return best
end

-- follows a computed path; false when there is none or it stalls
local function walkPath(target, close, limit)
    local root = myRoot()
    if not root then return false end
    local pathObj = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 5 })
    local ok = pcall(function() pathObj:ComputeAsync(root.Position, target) end)
    if not ok or pathObj.Status ~= Enum.PathStatus.Success then return false end
    local started = os.clock()
    for _, waypoint in ipairs(pathObj:GetWaypoints()) do
        local r, hum = myRoot()
        if not r or Unloaded or os.clock() - started > limit then return false end
        if waypoint.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        hum:MoveTo(waypoint.Position)
        local legStart, lastPos = os.clock(), r.Position
        while os.clock() - legStart < 2.5 do
            task.wait(0.1)
            if close() then return true end
            r = myRoot()
            if not r then return false end
            if flat(r.Position - waypoint.Position).Magnitude < 1.5 then break end
            if os.clock() - legStart > 1 and (r.Position - lastPos).Magnitude < 0.05 then return false end
            lastPos = r.Position
        end
    end
    return close()
end

-- Gets within `radius` of a point. Walks there (straight, then by a computed
-- path round walls), or steps there directly when walking is off or nothing
-- gets through. opts.flat measures across the ground only (trunks, walls);
-- opts.spot (a distance) aims for a clear spot that far beside the point
-- instead of the point itself (furniture).
local function goTo(target, radius, timeout, opts)
    opts = opts or {}
    local root, hum = myRoot()
    if not root or not target then return false end
    radius = radius or 5
    local spotDist = type(opts.spot) == "number" and opts.spot or math.max(radius - 2, 2)
    local function close()
        local r = myRoot()
        if not r then return false end
        local offset = r.Position - target
        if opts.flat then return flat(offset).Magnitude <= radius and math.abs(offset.Y) <= 10 end
        return offset.Magnitude <= radius
    end
    if close() then return true end
    local limit = timeout or math.clamp((root.Position - target).Magnitude / math.max(hum.WalkSpeed, 8) + 3, 3, 25)
    if Farm.Walk then
        local started = os.clock()
        local lastPos, stuckFor = root.Position, 0
        while os.clock() - started < limit and not Unloaded do
            root, hum = myRoot()
            if not root then return false end
            hum:MoveTo(target)
            task.wait(0.3)
            if close() then return true end
            if (root.Position - lastPos).Magnitude < 0.4 then
                stuckFor += 0.3
                if stuckFor >= 1.2 then break end
            else
                stuckFor = 0
            end
            lastPos = root.Position
        end
        if close() then return true end
        local goal = opts.spot and standSpot(target, spotDist) or target
        if goal and walkPath(goal, close, limit) then return true end
    end
    root = myRoot()
    if not root then return false end
    detach()
    local stand = opts.spot and standSpot(target, spotDist)
    if not stand then
        local dir = flat(root.Position - target)
        dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(1, 0, 0)
        stand = target + dir * math.max(radius - 1.5, 1.5) + Vector3.new(0, 2.5, 0)
    end
    root.CFrame = CFrame.lookAt(stand, Vector3.new(target.X, stand.Y, target.Z))
    root.AssemblyLinearVelocity = Vector3.zero
    task.wait(0.25)
    return close()
end

local function face(target)
    local root = myRoot()
    if not root or not target then return end
    local look = Vector3.new(target.X, root.Position.Y, target.Z)
    if (look - root.Position).Magnitude < 0.2 then return end
    root.CFrame = CFrame.lookAt(root.Position, look)
end

local function nearest(list, from)
    local root = myRoot()
    local origin = from or (root and root.Position)
    if not origin then return nil end
    local best, bestDist = nil, math.huge
    for _, obj in ipairs(list) do
        local pos = position(obj)
        if pos then
            local d = (pos - origin).Magnitude
            if d < bestDist then best, bestDist = obj, d end
        end
    end
    return best, bestDist
end

local function locations()
    local env = Workspace:FindFirstChild("Environment")
    return env and env:FindFirstChild("Locations")
end

local function path(root, p)
    local node = root
    for part in p:gmatch("[^/]+") do
        node = node and node:FindFirstChild(part)
    end
    return node
end

--// jobs --------------------------------------------------------------------

local function onShift(job)
    return stat("Job") == job
end

local function jobModule(job)
    local jh = Mods.JobHandler
    if not jh then return nil end
    local ok, m = pcall(jh.GetJobModule, jh, job)
    return ok and m or nil
end

-- the job's building: JobHandler tracks it on the module (tagged JobLocation),
-- or the path the job module itself waits for
local function jobPlace(job, fallback)
    local m = jobModule(job)
    local model = m and m.Model
    if typeof(model) == "Instance" and model.Parent then return model end
    return path(locations(), fallback)
end

local function waitFor(seconds, check)
    local started = os.clock()
    while os.clock() - started < seconds and not Unloaded do
        if check() then return true end
        task.wait(0.2)
    end
    return check()
end

local LastStartTry = 0

-- On shift for the chosen job. Going to work drops you in the job's area,
-- and touching the area starts the shift by itself; StartWorking is only
-- asked when it didn't, since asking during a shift puts up the game's
-- "end your shift first" box.
local function ensureShift(job)
    if onShift(job) then return true end
    local jh = Mods.JobHandler
    if not jh or os.clock() - LastStartTry < 8 then return false end
    LastStartTry = os.clock()
    local current = stat("Job")
    if current and current ~= "" then
        Farm.Status = "ending the other shift"
        callFor(5, jh.StopWorking, jh)
        waitFor(4, function() return stat("Job") == "" end)
        task.wait(5.2) -- the game refuses a new shift within 5s of the last start
    end
    Farm.Status = "going to work"
    callFor(15, jh.GoToWork, jh, job)
    if waitFor(3, function() return onShift(job) end) then return true end
    Farm.Status = "starting the shift"
    callFor(10, jh.StartWorking, jh, job)
    if waitFor(3, function() return onShift(job) end) then return true end
    -- walk into the job's area, which starts it the way a player does
    local m = jobModule(job)
    local pos = position(m and m.AreaBlock)
    if pos then
        goTo(pos, 3, 15)
        if waitFor(3, function() return onShift(job) end) then return true end
    end
    Farm.Status = "couldn't start the shift, retrying"
    return onShift(job)
end

local Steps = {}

-- trash spawned around the school; clean the nearest
function Steps.SchoolJanitor()
    local school = jobPlace("SchoolJanitor", "SchoolArea/School")
    local spawns = school and school:FindFirstChild("JanitorSpawns")
    if not spawns then
        Farm.Status = "school not loaded yet"
        return 1
    end
    local trash = {}
    for _, d in ipairs(spawns:GetDescendants()) do
        if d.Name == "Object" and d.Parent and d.Parent.Parent == spawns and hasMenu(d) then trash[#trash + 1] = d end
    end
    local target = nearest(trash)
    if not target then
        Farm.Status = "no trash right now"
        return 2
    end
    Farm.Status = "cleaning"
    local spot = position(target.Parent) or position(target)
    if not goTo(spot, 5, nil, { flat = true }) then return 0.5 end
    face(spot)
    pace(0.35)
    if runMenu(target, "I_CleanUp") then
        waitFor(3, function() return target.Parent == nil end)
        if not target.Parent then Farm.Tasks += 1 end
    end
    return 0.6
end

-- desks ask for discipline (1) or a hall pass (2); lectures (3) need the
-- board's drawing minigame and are left
function Steps.HighSchoolTeacher()
    local gameplay = path(locations(), "SchoolArea/School/Interior/Floor2/Teacher1/Interior/Gameplay")
    local desks = gameplay and gameplay:FindFirstChild("Desks")
    local stations = gameplay and gameplay:FindFirstChild("Hall Pass Stations")
    if not desks then
        Farm.Status = "classroom not loaded yet"
        return 1
    end
    local wanting = {}
    for _, desk in ipairs(desks:GetChildren()) do
        local id = desk:GetAttribute("TaskID")
        if id == 1 or id == 2 then wanting[#wanting + 1] = desk end
    end
    local desk = nearest(wanting)
    if not desk then
        Farm.Status = "no tasks right now"
        return 1
    end
    local kind = desk:GetAttribute("TaskID")
    -- a hall pass has to be in hand first
    if kind == 2 and equipped() ~= "Hall Pass" then
        local station = stations and nearest(stations:GetChildren())
        if not station then
            Farm.Status = "no hall pass station"
            return 1
        end
        Farm.Status = "fetching a hall pass"
        if not goTo(position(station), 5, nil, { flat = true }) then return 0.5 end
        face(position(station))
        pace(0.3)
        runMenu(station, "I_Take")
        if not waitFor(4, function() return equipped() == "Hall Pass" end) then return 0.5 end
    end
    Farm.Status = kind == 1 and "disciplining" or "giving the hall pass"
    if not goTo(position(desk), 5, nil, { flat = true }) then return 0.5 end
    face(position(desk))
    pace(0.35)
    if runMenu(desk, kind == 1 and "I_Scold" or "I_Give") then
        waitFor(3, function() return desk:GetAttribute("TaskID") ~= 0 end)
        if desk:GetAttribute("TaskID") == -1 then Farm.Tasks += 1 end
    end
    return 0.8
end

-- Mine blocks are named "x:depth:z". One with nothing above it is open and
-- can be stood on; the nearest open one is mined.
local MineFailed = {}

local function mineBlocks()
    local list = interactionTable()
    local blocks, byName = {}, {}
    local function consider(obj)
        if typeof(obj) == "Instance" and obj.Parent and obj:IsA("Model") and obj.Name:match("^%-?%d+:%-?%d+:%-?%d+$") then
            blocks[#blocks + 1] = obj
            byName[obj.Name] = obj
        end
    end
    if list then
        for obj in pairs(list) do consider(obj) end
    else
        local gameFolder = Workspace:FindFirstChild("_game")
        for _, folder in ipairs(gameFolder and gameFolder:GetChildren() or {}) do
            if folder:IsA("Folder") then
                for _, child in ipairs(folder:GetChildren()) do consider(child) end
            end
        end
    end
    return blocks, byName
end

function Steps.CaveMiner()
    if equipped() ~= "Pickaxe" then
        Farm.Status = "waiting for the pickaxe"
        return 1
    end
    local blocks, byName = mineBlocks()
    local open = {}
    for _, block in ipairs(blocks) do
        local x, depth, z = block.Name:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
        local above = ("%d:%d:%d"):format(tonumber(x), tonumber(depth) - 1, tonumber(z))
        if not byName[above] and not (MineFailed[block] and os.clock() - MineFailed[block] < 20) then
            open[#open + 1] = block
        end
    end
    local block = nearest(open)
    if not block then
        Farm.Status = #blocks == 0 and "no blocks yet" or "no open blocks"
        return 1.5
    end
    Farm.Status = "mining"
    local pos = position(block)
    local size = block.PrimaryPart and block.PrimaryPart.Size.Y or 6
    local top = pos + Vector3.new(0, size / 2 + 3, 0)
    if not goTo(top, 6) then return 0.5 end
    face(pos)
    if runMenu(block, "I_Mine") then
        if waitFor(5, function() return block.Parent == nil end) then
            Farm.Tasks += 1
        else
            MineFailed[block] = os.clock()
        end
    else
        MineFailed[block] = os.clock()
    end
    pace(0.25)
    return 0.2
end

-- the equipped tool's own action (what a tap on the hotbar runs)
local function toolTitle()
    local hb = Mods.HotbarUI
    local data = hb and hb.EquipData
    return type(data) == "table" and data.Title or nil
end

local function useTool(title)
    local hb = Mods.HotbarUI
    local data = hb and hb.EquipData
    if type(data) ~= "table" or type(data.Function) ~= "function" then return false end
    if title and data.Title ~= title then return false end
    return (pcall(data.Function))
end

-- the rod's own check: 12 studs ahead of you, 20 down, must be water
local function castsIntoWater(from, dir)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local hit = Workspace:Raycast(from + dir * 12, Vector3.new(0, -20, 0), params)
    return hit ~= nil and hit.Instance == Workspace.Terrain and hit.Material == Enum.Material.Water
end

-- dry ground near us with water in casting range, the closest first
local FishSpot = nil

local function findFishingSpot(root)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    for r = 0, 96, 8 do
        local steps = r == 0 and 1 or 16
        for i = 0, steps - 1 do
            local a = i / steps * math.pi * 2
            local probe = root.Position + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
            local ground = Workspace:Raycast(probe + Vector3.new(0, 15, 0), Vector3.new(0, -40, 0), params)
            if ground and not (ground.Instance == Workspace.Terrain and ground.Material == Enum.Material.Water) then
                local stand = ground.Position + Vector3.new(0, 3, 0)
                for j = 0, 15 do
                    local b = j / 16 * math.pi * 2
                    local dir = Vector3.new(math.cos(b), 0, math.sin(b))
                    if castsIntoWater(stand, dir) then return { Stand = stand, Dir = dir } end
                end
            end
        end
    end
    return nil
end

-- cast; the rod pulls in on its own once the bite wait is over
function Steps.HutFisherman()
    local root = myRoot()
    if not root then return 1 end
    if equipped() ~= "Fishing Rod" then
        Farm.Status = "waiting for the fishing rod"
        return 1
    end
    if toolTitle() ~= "I_Cast" then
        Farm.Status = "waiting for a bite"
        return 0.5
    end
    if not castsIntoWater(root.Position, flat(root.CFrame.LookVector).Unit) then
        if not FishSpot or not castsIntoWater(FishSpot.Stand, FishSpot.Dir) then
            Farm.Status = "looking for water"
            FishSpot = findFishingSpot(root)
        end
        if not FishSpot then
            Farm.Status = "no water within reach of here"
            return 3
        end
        if not goTo(FishSpot.Stand, 2) then return 0.5 end
        root = myRoot()
        if not root then return 1 end
        root.CFrame = CFrame.lookAt(root.Position, root.Position + FishSpot.Dir)
        task.wait(0.2)
    end
    pace(0.4)
    if useTool("I_Cast") then
        Farm.Status = "fishing"
        Farm.Tasks += 1
        pace(1.2)
    end
    return 0.8
end

local function lumberArea()
    local m = jobModule("LumberWoodcutter")
    local area = m and m.ShiftArea
    if typeof(area) == "Instance" then return area end
    if type(area) == "string" then
        local part = path(Workspace, area)
        if part then return part end
    end
    return path(locations(), "Mountains/LumberMill/LumberCollision")
end

local function inside(part, pos)
    local rel = part.CFrame:PointToObjectSpace(pos)
    local half = part.Size / 2
    return math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z
end

-- a choppable tree, the way the hatchet sees one: a "Body" or "CollisionPart"
-- whose model also has "Leaves"
local function treeBody(tree)
    if not tree:IsA("Model") or not tree:FindFirstChild("Leaves") then return nil end
    local body = tree:FindFirstChild("Body") or tree:FindFirstChild("CollisionPart")
    return body and body:IsA("BasePart") and body or nil
end

local Felled = {}
local LumberTrees = { List = {}, At = -math.huge }

-- the lumber trees inside the work area (the folder holds every tree on the
-- map, so the search is kept for a few seconds)
local function lumberTrees()
    if os.clock() - LumberTrees.At < 8 then return LumberTrees.List end
    local trees = path(Workspace, "Environment/Foliage/Trees")
    local area = lumberArea()
    local list = {}
    for _, tree in ipairs(trees and trees:GetDescendants() or {}) do
        local body = tree:IsA("Model") and treeBody(tree)
        if body and (not area or inside(area, body.Position)) then list[#list + 1] = tree end
    end
    LumberTrees.List, LumberTrees.At = list, os.clock()
    return list
end

-- chop the nearest standing tree inside the lumber area
function Steps.LumberWoodcutter()
    if equipped() ~= "Hatchet" then
        Farm.Status = "waiting for the hatchet"
        return 1
    end
    local list = {}
    for _, tree in ipairs(lumberTrees()) do
        local body = tree.Parent and treeBody(tree)
        if body and not (Felled[tree] and os.clock() - Felled[tree] < 45) then list[#list + 1] = body end
    end
    local body = nearest(list)
    if not body then
        Farm.Status = "no trees standing"
        return 2
    end
    Farm.Status = "chopping"
    local root = myRoot()
    if not root then return 1 end
    local trunk = math.max(body.Size.X, body.Size.Z) / 2
    local base = Vector3.new(body.Position.X, root.Position.Y, body.Position.Z)
    if not goTo(base, trunk + 2.2, nil, { flat = true }) then return 0.5 end
    local tree = body.Parent
    local home = body.Position
    local started = os.clock()
    while tree and tree.Parent and os.clock() - started < 30 and not bail() do
        if (body.Position - home).Magnitude > 2 or not body.Parent then break end
        face(body.Position)
        if useTool("I_Chop") then pace(0.15) end
        task.wait(0.25)
    end
    if tree and ((body.Position - home).Magnitude > 2 or not body.Parent) then
        Felled[tree] = os.clock()
        Farm.Tasks += 1
    elseif tree and os.clock() - started >= 30 then
        Felled[tree] = os.clock() -- not coming down from here; try another
    end
    return 0.5
end

-- crate from the warehouse, onto an empty shelf
function Steps.SupermarketStocker()
    local market = jobPlace("SupermarketStocker", "City/Supermarket")
    if not market then
        Farm.Status = "supermarket not loaded yet"
        return 1
    end
    local held = equipped()
    if held == "Food Crate" then
        local shelves = path(market, "Interior/Shelves")
        local empty = {}
        for _, shelf in ipairs(shelves and shelves:GetChildren() or {}) do
            local isEmpty = shelf:FindFirstChild("IsEmpty")
            if isEmpty and isEmpty.Value == true then empty[#empty + 1] = shelf end
        end
        local shelf = nearest(empty)
        if not shelf then
            Farm.Status = "no empty shelves"
            return 1.5
        end
        Farm.Status = "restocking"
        if not goTo(position(shelf), 5, nil, { flat = true }) then return 0.5 end
        face(position(shelf))
        pace(0.3)
        if runMenu(shelf, "I_Restock") then
            waitFor(2, function() return equipped() ~= "Food Crate" end)
            Farm.Tasks += 1
        end
        return 0.8
    end
    if held then
        Farm.Status = "hands full (" .. held .. "): put it away to take a crate"
        return 2
    end
    local crates = path(market, "Geometry/Crates")
    local list = {}
    for _, crate in ipairs(crates and crates:GetChildren() or {}) do
        if crate.Name ~= "BagCrate" then list[#list + 1] = crate end
    end
    local crate = nearest(list)
    if not crate then
        Farm.Status = "no crates"
        return 1.5
    end
    Farm.Status = "taking a crate"
    if not goTo(position(crate), 4, nil, { flat = true }) then return 0.5 end
    face(position(crate))
    pace(0.3)
    runMenu(crate, "I_Take")
    waitFor(2, function() return equipped() == "Food Crate" end)
    return 0.5
end

-- a workstation to work: ours first, then a free one with someone waiting,
-- then any free one
local function pickStation(list, wanted)
    local mine, waiting, free = {}, {}, {}
    for _, ws in ipairs(list) do
        local inUse = ws:FindFirstChild("InUse")
        local user = inUse and inUse.Value
        if user == LocalPlayer then
            mine[#mine + 1] = ws
        elseif user == nil then
            if wanted(ws) then waiting[#waiting + 1] = ws end
            free[#free + 1] = ws
        end
    end
    return nearest(mine) or nearest(waiting) or nearest(free)
end

-- Groceries the customer drops on the belt are scanned into the bag; when
-- they're all placed and scanned the screen's Done finishes the order. Bags
-- come off the holder, and a new pack from the warehouse when it's empty.
function Steps.SupermarketCashier()
    local market = jobPlace("SupermarketCashier", "City/Supermarket")
    local stations = market and path(market, "Interior/CashierWorkstations")
    if not stations then
        Farm.Status = "supermarket not loaded yet"
        return 1
    end
    local ws = pickStation(stations:GetChildren(), function(s)
        local occupied = s:FindFirstChild("Occupied")
        return occupied ~= nil and occupied.Value ~= nil
    end)
    if not ws then
        Farm.Status = "every till is taken"
        return 2
    end
    local scanner = ws:FindFirstChild("Scanner")
    local customerSide = ws:FindFirstChild("CustomerTarget_1") or ws:FindFirstChild("CustomerTarget")
    local holder = ws:FindFirstChild("BagHolder")
    local bagsLeft = ws:FindFirstChild("BagsLeft")
    if not scanner or not holder then
        Farm.Status = "till not loaded yet"
        return 1
    end
    -- stand behind the till, across from the customers
    local stand = scanner.Position
    if customerSide then
        local away = flat(scanner.Position - customerSide.Position)
        if away.Magnitude > 0.1 then stand = scanner.Position + away.Unit * 3.5 end
    end
    -- a bag to pack into: a showing one with room
    local function bagReady()
        local bags = ws:FindFirstChild("Bags")
        for _, bag in ipairs(bags and bags:GetChildren() or {}) do
            if bag:IsA("BasePart") and bag.Transparency == 0 and #bag:GetChildren() <= 3 then return true end
        end
        return false
    end
    if not bagReady() then
        if bagsLeft and bagsLeft.Value < 1 then
            if equipped() == "BFF Bags" then
                Farm.Status = "restocking bags"
                if not goTo(position(holder), 5, nil, { flat = true }) then return 0.5 end
                pace(0.3)
                runMenu(holder, "I_Restock")
                waitFor(2, function() return bagsLeft.Value >= 1 end)
                return 0.5
            end
            local crate = path(market, "Geometry/Crates/BagCrate")
            if not crate then
                Farm.Status = "out of bags and no bag crate"
                return 2
            end
            Farm.Status = "fetching bags"
            if not goTo(position(crate), 4, nil, { flat = true }) then return 0.5 end
            pace(0.3)
            runMenu(crate, "I_Take")
            waitFor(2, function() return equipped() == "BFF Bags" end)
            return 0.3
        end
        Farm.Status = "taking a bag"
        if not goTo(stand, 3) then return 0.5 end
        pace(0.3)
        runMenu(holder, "I_Take")
        waitFor(2, bagReady)
        return 0.3
    end
    if not goTo(stand, 3) then return 0.5 end
    local occupied = ws:FindFirstChild("Occupied")
    local customer = occupied and occupied.Value
    if not customer then
        Farm.Status = "waiting for a customer"
        return 1
    end
    Farm.Status = "scanning"
    local dropped = ws:FindFirstChild("DroppedFood")
    for _, item in ipairs(dropped and dropped:GetChildren() or {}) do
        if bail() then return 0.2 end
        if item.Parent and hasMenu(item) then
            face(position(item))
            pace(0.35)
            runMenu(item, "I_Scan")
            waitFor(1.5, function() return item.Parent ~= dropped end)
        end
    end
    local status = customer:FindFirstChild("Status")
    local placed = status and status:FindFirstChild("PlacedObjects")
    local scanned = status and status:FindFirstChild("ScannedObjects")
    if status and status.Value == "placed" and placed and scanned and scanned.Value >= placed.Value and #(dropped and dropped:GetChildren() or {}) == 0 then
        Farm.Status = "finishing the order"
        pace(0.4)
        local screen = path(ws, "Display/Screen")
        local done = screen and path(screen, "CashierGUI/Frame/Done")
        if not runMenu(screen, "B_Done") then pressButton(done) end
        if waitFor(4, function() return status.Value == "true" or status.Value == "false" or occupied.Value ~= customer end) then
            if status.Value == "true" then Farm.Tasks += 1 end
        end
        return 1
    end
    Farm.Status = "waiting for the groceries"
    return 0.4
end

-- The pizza order on a baker's workstation: the topping, as the workstation's
-- ingredient menu numbers it (ham 4, pepperoni 5, vegetables 6).
local TOPPINGS = { { "ham", "Ham", 4 }, { "pepperoni", "Pepperoni", 5 }, { "veg", "Vegetable", 6 } }

local function toppingIn(text)
    text = tostring(text or ""):lower()
    for _, t in ipairs(TOPPINGS) do
        if text:find(t[1], 1, true) then return t[2], t[3] end
    end
    return nil
end

local function bakerOrder(ws)
    local order = ws:FindFirstChild("Order")
    local value = order and order.Value
    if value == nil or value == "" or value == "true" or value == "false" then return nil end
    local name, index = toppingIn(value)
    if name then return name, index end
    -- the order card the server hangs on the workstation's display
    local logo = path(ws, "OrderDisplay/DisplayMain/BakerGUI/Frame/Logo")
    local roots = { ws:FindFirstChild(" "), logo }
    for _, root in ipairs(roots) do
        for _, d in ipairs(root and root:GetDescendants() or {}) do
            name, index = toppingIn(d.Name)
            if not name and (d:IsA("TextLabel") or d:IsA("TextButton")) then name, index = toppingIn(d.Text) end
            if name then return name, index end
        end
    end
    return nil, nil, value
end

-- Dough, sauce, cheese, the order's topping, then the display's Done. The
-- workstation's pizza model shows what's on it so far.
function Steps.PizzaPlanetBaker()
    local place = jobPlace("PizzaPlanetBaker", "City/PizzaPlanet")
    local stations = place and path(place, "Interior/BakerWorkstations")
    if not stations then
        Farm.Status = "pizza place not loaded yet"
        return 1
    end
    local ws = pickStation(stations:GetChildren(), function(s) return bakerOrder(s) ~= nil end)
    if not ws then
        Farm.Status = "every workstation is taken"
        return 2
    end
    local ingredients = ws:FindFirstChild("Ingredients")
    local order = ws:FindFirstChild("Order")
    local left = order and order:FindFirstChild("IngredientsLeft")
    if not ingredients or not order then
        Farm.Status = "workstation not loaded yet"
        return 1
    end
    local spot = position(ws:IsA("Model") and ws.PrimaryPart or ingredients)
    if left and left.Value < 1 then
        if equipped() == "Ingredient Crate" then
            Farm.Status = "restocking ingredients"
            if not goTo(position(ingredients), 5, nil, { flat = true }) then return 0.5 end
            pace(0.3)
            runOption(ingredients, 7, "I_Restock")
            waitFor(2, function() return left.Value >= 1 end)
            return 0.5
        end
        local crates = path(place, "Interior/IngredientCrates")
        local crate = crates and nearest(crates:GetChildren())
        if not crate then
            Farm.Status = "out of ingredients and no crate"
            return 2
        end
        Farm.Status = "fetching ingredients"
        if not goTo(position(crate), 4, nil, { flat = true }) then return 0.5 end
        pace(0.3)
        runMenu(crate, "I_Take")
        waitFor(2, function() return equipped() == "Ingredient Crate" end)
        return 0.3
    end
    local topping, index, raw = bakerOrder(ws)
    if not topping then
        Farm.Status = raw and ("can't read this order (%s): capture it from the Jobs tab"):format(tostring(raw)) or "waiting for an order"
        if not goTo(spot, 5, nil, { flat = true }) then return 0.5 end
        return 1
    end
    if not goTo(spot, 5, nil, { flat = true }) then return 0.5 end
    Farm.Status = "making a " .. topping:lower() .. " pizza"
    local pizza = ws:FindFirstChild("Pizza")
    local function on(name)
        local part = pizza and pizza:FindFirstChild(name)
        return part ~= nil and part.Transparency == 0
    end
    local function add(i, name)
        local tr = Mods.TranslationHandler
        local label
        if tr then
            local ok, text = pcall(tr.Format, tr, "T_Add", { name == "Sauce" and "Tomato Sauce" or name })
            label = ok and text or nil
        end
        runOption(ingredients, i, label)
        pace(0.45)
    end
    -- wrong topping already on: dough again throws the pizza out
    for _, t in ipairs(TOPPINGS) do
        if t[2] ~= topping and on(t[2]) then
            add(1, "Dough")
            break
        end
    end
    if not on("Dough") then add(1, "Dough") end
    if on("Dough") and not on("Sauce") then add(2, "Sauce") end
    if on("Sauce") and not on("Cheese") then add(3, "Cheese") end
    if on("Cheese") and not on(topping) then add(index, topping == "Vegetable" and "Vegetables" or topping) end
    if not (on("Dough") and on("Sauce") and on("Cheese") and on(topping)) then return 0.3 end
    Farm.Status = "sending the pizza"
    pace(0.3)
    local before = order.Value
    local display = ws:FindFirstChild("OrderDisplay")
    local done = path(ws, "OrderDisplay/DisplayMain/BakerGUI/Frame/Done")
    if not runMenu(display, "B_Done") then pressButton(done) end
    if waitFor(4, function() return order.Value ~= before end) and order.Value == "true" then
        Farm.Tasks += 1
    end
    return 1
end

loop(function() return Farm.NextWait or 0.5 end, function()
    Farm.NextWait = 0.5
    if not Farm.Enabled then
        Farm.Status = "off"
        return
    end
    if NeedsBusy then
        Farm.Status = "paused for needs"
        return
    end
    if not Mods.JobHandler or not Stats then
        Farm.Status = "loading the game"
        return
    end
    if not myRoot() then
        Farm.Status = "no character"
        return
    end
    if not ensureShift(Farm.Job) then
        Farm.NextWait = 2
        return
    end
    Farm.StartMoney = Farm.StartMoney or stat("Money")
    local step = Steps[Farm.Job]
    if step then
        Farm.Busy = true
        local ok, nextWait = pcall(step)
        Farm.Busy = false
        Farm.NextWait = ok and tonumber(nextWait) or 1
    end
end)

-- what a live order looks like, for adding the order jobs
local function captureOrders()
    local lines = {}
    local function describe(inst, depth)
        if depth > 9 or #lines > 1500 then return end
        local extra = ""
        pcall(function()
            if inst:IsA("ValueBase") then extra = " = " .. tostring(inst.Value) end
            if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then extra = " image=" .. tostring(inst.Image) end
            if inst:IsA("TextLabel") or inst:IsA("TextButton") then extra = " text=" .. tostring(inst.Text) end
            if inst:IsA("GuiObject") then extra = extra .. " visible=" .. tostring(inst.Visible) end
            if inst:IsA("BasePart") then extra = extra .. " color=" .. tostring(inst.BrickColor) .. " transparency=" .. tostring(inst.Transparency) end
        end)
        local attrs = {}
        for k, v in pairs(inst:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
        lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " (" .. inst.ClassName .. ")" .. extra
            .. (#attrs > 0 and ("  {" .. table.concat(attrs, ", ") .. "}") or "")
        for _, child in ipairs(inst:GetChildren()) do describe(child, depth + 1) end
    end
    local roots = locations()
    local seen = {}
    for _, d in ipairs(roots and roots:GetDescendants() or {}) do
        local station = nil
        if d.Name == "Occupied" and d:IsA("ObjectValue") and d.Value then station = d.Parent end
        if d.Name == "Order" and d:IsA("StringValue") and d.Value ~= "" and d.Parent and d.Parent:FindFirstChild("InUse") then station = d.Parent end
        if station and not seen[station] then
            seen[station] = true
            lines[#lines + 1] = "== " .. station:GetFullName()
            describe(station, 0)
            local occupied = station:FindFirstChild("Occupied")
            if occupied and occupied.Value then describe(occupied.Value, 1) end
        end
    end
    local text = table.concat(lines, "\n")
    if text == "" then return 0, nil end
    local file = "Bloxburg_orders.txt"
    if typeof(writefile) == "function" then pcall(writefile, file, text) end
    if typeof(setclipboard) == "function" then pcall(setclipboard, text) end
    return #lines, file
end

--// needs -------------------------------------------------------------------
-- What each need uses, by the item types the game's own menus check
-- (TypeService), and the menu options to click, in order of preference.
-- Name words are only a fallback for when TypeService can't be reached.

local NEED_ITEMS = {
    Energy = { Types = { "Beds", "CanSleep" }, Words = { " bed", "bed " }, Keys = { "I_Sleep", "I_Rest" } },
    Hygiene = { Types = { "Shower", "TubShowerCombo", "Bathtub" }, Words = { "shower", "bathtub", " tub" }, Keys = { "I_UseShower", "I_Use", "I_UseBathtub" } },
    Fun = { Types = { "TV", "KidsTV", "Computer", "Laptop" }, Words = { " tv", "television", "computer", "laptop" }, Keys = { "I_Watch", "B_Play", "I_WatchYouBlock" }, First = { "I_TurnOn" } },
    Hunger = { Types = { "Fridge", "MiniFridge", "QuickMealContainer" }, Words = { "fridge", "icebox", "refrigerator" }, Keys = { "I_TakeQuickMeal" }, Meal = true },
}

local function myPlot()
    local plots = Workspace:FindFirstChild("Plots")
    return plots and plots:FindFirstChild("Plot_" .. LocalPlayer.Name)
end

local function atHome(plot)
    local root = myRoot()
    local ground = plot:GetAttribute("GroundPosition")
    local size = plot:GetAttribute("GroundSize")
    if not root or typeof(ground) ~= "CFrame" then return false end
    local rel = ground:PointToObjectSpace(root.Position)
    local half = typeof(size) == "Vector3" and size / 2 or Vector3.new(125, 0, 125)
    return math.abs(rel.X) <= half.X + 15 and math.abs(rel.Z) <= half.Z + 15
end

local function plotItems(info)
    local plot = myPlot()
    local list = {}
    if not plot then return list end
    local ts = Mods.TypeService
    for _, d in ipairs(plot:GetDescendants()) do
        if (d:IsA("BasePart") or d:IsA("Model")) and CollectionService:HasTag(d, "PlotObject") then
            local match = false
            if ts then
                local ok, kind = pcall(ts.ObjectIsAnyType, ts, d, table.unpack(info.Types))
                match = ok and kind ~= nil and kind ~= false
            else
                local name = " " .. d.Name:lower() .. " "
                for _, word in ipairs(info.Words) do
                    if name:find(word, 1, true) then
                        match = true
                        break
                    end
                end
            end
            if match then list[#list + 1] = d end
        end
    end
    return list
end

local function need(name)
    local value = stat("MoodData/" .. name)
    return type(value) == "number" and value or 100
end

local function needRate(name)
    local value = stat("MoodData/" .. name .. "/Rate")
    return type(value) == "number" and value or 0
end

-- the fridge's quick meal list: the cheapest meal we can afford, picked the
-- way a click on it picks it
local function pickQuickMeal(timeout)
    local lf = Mods.ListFrameHandler
    if not lf then return false end
    local started = os.clock()
    while os.clock() - started < timeout and not Unloaded do
        local frames = lf.FrameData
        for _, data in pairs(type(frames) == "table" and frames or {}) do
            if type(data) == "table" and data.Title == "T_QuickMeals" and type(data.ListData) == "table" then
                local money = stat("Money") or 0
                for _, entry in ipairs(data.ListData) do
                    if type(entry) == "table" and not entry.Error and type(entry.Return) == "function" and (entry.Price or 0) <= money then
                        return (pcall(entry.Return))
                    end
                end
                -- nothing affordable: close the list
                if typeof(data.Event) == "Instance" then pcall(function() data.Event:Fire() end) end
                return false
            end
        end
        task.wait(0.2)
    end
    return false
end

-- eats what's in hand, bite by bite, through its hotbar action
local function eatHeld()
    local started, lastBite = os.clock(), os.clock()
    local ate = false
    while os.clock() - started < 120 and need("Hunger") < Needs.FillTo and Needs.Enabled and not Unloaded do
        local title = toolTitle()
        if title == "I_Eat" then
            if useTool("I_Eat") then
                ate = true
                lastBite = os.clock()
            end
            task.wait(1.5)
        elseif title == nil and equipped() ~= nil and os.clock() - lastBite < 10 then
            task.wait(0.5) -- mid-bite
        else
            break -- eaten up (an empty plate has no eat action)
        end
        if equipped() == nil then break end
    end
    return ate
end

local function fillNeed(name)
    local info = NEED_ITEMS[name]
    local plot = myPlot()
    if not plot then
        Needs.Status = "no plot"
        return false
    end
    if not myRoot() then return false end
    if not atHome(plot) and Mods.HouseHandler then
        Needs.Status = "going home"
        callFor(20, Mods.HouseHandler.ToPlot, Mods.HouseHandler, LocalPlayer)
        waitFor(6, function() return atHome(plot) end)
        task.wait(1.5)
    end
    local options = plotItems(info)
    if #options == 0 then
        Needs.Status = ("%s: nothing on your plot for it"):format(name:lower())
        return false
    end
    while #options > 0 and not Unloaded do
        local obj = nearest(options)
        for i, o in ipairs(options) do
            if o == obj then
                table.remove(options, i)
                break
            end
        end
        Needs.Status = ("%s: using %s"):format(name:lower(), obj.Name)
        local pos = position(obj)
        -- beside it, within the game's reach of it (10 studs)
        local reach = (obj:IsA("BasePart") and math.max(obj.Size.X, obj.Size.Z) / 2 or 2) + 1.5
        if pos and goTo(pos, math.min(reach + 1.5, 9), 20, { spot = math.min(reach, 7.5) }) then
            face(pos)
            wait(0.4)
            local before = need(name)
            local used = useFurniture(obj, info.Keys)
            if not used and info.First and useFurniture(obj, info.First) then
                -- a TV has to be switched on before it can be watched
                wait(0.8)
                used = useFurniture(obj, info.Keys)
            end
            if used and info.Meal then
                if pickQuickMeal(6) and waitFor(10, function() return toolTitle() == "I_Eat" end) then
                    Needs.Status = "hunger: eating"
                    eatHeld()
                    local eq = Mods.Equipment
                    if eq and equipped() then pcall(eq.UnequipItem, eq, LocalPlayer) end
                    return true
                end
            elseif used then
                -- it took if the need starts going up
                if waitFor(10, function() return needRate(name) > 0 or need(name) > before + 0.05 end) then
                    local started = os.clock()
                    while need(name) < Needs.FillTo and os.clock() - started < 300 and Needs.Enabled and Needs[name] and not Unloaded do
                        task.wait(1)
                    end
                    detach()
                    return true
                end
                detach()
            end
        end
    end
    Needs.Status = ("%s: couldn't use anything on your plot"):format(name:lower())
    return false
end

loop(3, function()
    if not Needs.Enabled or not Stats or not Mods.InteractionHandler then
        Needs.Status = Needs.Enabled and "loading the game" or "off"
        Needs.Now = false
        return
    end
    local lowest, lowestValue = nil, Needs.Now and math.huge or Needs.Threshold
    for _, name in ipairs({ "Energy", "Hygiene", "Hunger", "Fun" }) do
        if Needs[name] then
            local value = need(name)
            if value < lowestValue and value < Needs.FillTo then lowest, lowestValue = name, value end
        end
    end
    Needs.Now = false
    if not lowest then
        Needs.Status = "all good"
        return
    end
    -- the farm finishes the task it's on first
    NeedsBusy = true
    waitFor(30, function() return not Farm.Busy end)
    -- leaving work ends the shift; the farm starts it again afterwards
    pcall(fillNeed, lowest)
    NeedsBusy = false
end)

--// teleports ---------------------------------------------------------------

local LOCATIONS = {
    "Bloxburg Central", "Bloxy Acres", "Billygoat High", "Cape Beacon", "Lakeview Heights", "Ocean Avenue",
    "Peak Mountain", "Riverside Estates", "Riverside Park", "Starlight Observatory", "Sunset Pointe",
}

local function fastTravel(name)
    local ft = Mods.FastTravel
    if not ft then return false end
    local ok, result = pcall(ft.FastTravelTo, ft, nil, name)
    return ok and result
end

--// vehicle -----------------------------------------------------------------

-- the speed multiplier the game reads off the vehicle you drive
track(RunService.Heartbeat:Connect(function()
    if Unloaded then return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        for _, child in ipairs(char:GetChildren()) do
            local modifier = child:FindFirstChild("VehicleSpeedModifier")
            if modifier and modifier:IsA("NumberValue") then
                local want = Vehicle.Enabled and Vehicle.Multiplier or 1
                if modifier.Value ~= want then modifier.Value = want end
            end
        end
    end)
end))

--// anti-AFK ----------------------------------------------------------------
-- The idle handlers are switched off: Roblox's 20 minute kick and the game's
-- own AFK report both hang off Players.LocalPlayer.Idled.

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    for _, connection in ipairs(list) do
        pcall(function()
            if on then
                connection:Disable()
                IdleOff[#IdleOff + 1] = connection
            end
        end)
    end
    if not on then
        for _, connection in ipairs(IdleOff) do pcall(function() connection:Enable() end) end
        table.clear(IdleOff)
    end
    return true
end
task.delay(5, function() if Misc.AntiAfk and not Unloaded then setAntiAfk(true) end end)

--// teardown ----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Farm.Enabled, Needs.Enabled, Vehicle.Enabled = false, false, false
    pcall(setAntiAfk, false)
    pcall(function()
        local char = LocalPlayer.Character
        for _, child in ipairs(char and char:GetChildren() or {}) do
            local modifier = child:FindFirstChild("VehicleSpeedModifier")
            if modifier then modifier.Value = 1 end
        end
    end)
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
end

Genv.__BloxburgStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui ----------------------------------------------------------------------

local okLib, lib = pcall(function()
    return loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()
end)
if not okLib or type(lib) ~= "table" then return end
Library = lib

local Window = Library:CreateWindow({
    Title = 'Bloxburg',
    Footer = 'jobs + needs',
    Icon = 'house',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'Bloxburg',
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

local function money(n)
    return n and ("$" .. tostring(math.floor(n))) or "-"
end

do
    local Tab = Window:AddTab('Jobs', 'briefcase', 'Work shifts for you')

    local overview = Tab:AddBigGroupbox('Shift', 'gauge')
    local cards = overview:AddStatCards('bb_cards', {
        Cards = {
            { Title = 'Tasks', Value = '0', Icon = 'check' },
            { Title = 'Shift pay', Value = '-', Icon = 'wallet' },
            { Title = 'Earned', Value = '-', Icon = 'trending-up' },
            { Title = 'Money', Value = '-', Icon = 'banknote' },
        },
    })
    local status = overview:AddLabel('status: off', true)
    every(0.5, function()
        cards:SetValue('Tasks', tostring(Farm.Tasks))
        cards:SetValue('Shift pay', money(stat("Job/ShiftEarnings")))
        local now = stat("Money")
        cards:SetValue('Earned', (Farm.StartMoney and now) and money(now - Farm.StartMoney) or '-')
        cards:SetValue('Money', money(now))
        status:SetText(("status: %s\njob now: %s"):format(Farm.Status, (stat("Job") ~= "" and stat("Job")) or "none"))
    end)

    local farm = Tab:AddLeftGroupbox('Job farm', 'hammer')
    local names = {}
    for _, job in ipairs(JOBS) do names[#names + 1] = job.Name end
    farm:AddDropdown('bb_job', {
        Text = 'Job',
        Values = names,
        Default = JOBS[1].Name,
        Callback = function(value)
            for _, job in ipairs(JOBS) do
                if job.Name == value then Farm.Job = job.Id end
            end
        end,
    })
    farm:AddToggle('bb_farm', {
        Text = 'Work the shift',
        Tooltip = 'goes to work, starts the shift and does the tasks with the game\'s own actions, staying inside the work area so the shift keeps going',
        Default = false,
        Callback = function(v)
            Farm.Enabled = v
            if v then Farm.StartMoney, Farm.Tasks = nil, 0 end
        end,
    }):AddKeyPicker('bb_farm_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Job farm' })
    farm:AddSlider('bb_pace', {
        Text = 'Pace',
        Tooltip = 'how long it waits between actions. 1 is about a quick player; higher is slower and looks more human',
        Min = 0.5, Max = 3, Default = Farm.Pace, Rounding = 1, Suffix = 'x',
        Callback = function(v) Farm.Pace = v end,
    })
    farm:AddToggle('bb_walk', {
        Text = 'Walk to things',
        Tooltip = 'walks to each task like a player, round walls where it has to. off: steps straight to it (faster, more noticeable)',
        Default = Farm.Walk,
        Callback = function(v) Farm.Walk = v end,
    })
    farm:AddButton({
        Text = 'End shift',
        Func = function()
            Farm.Enabled = false
            if Mods.JobHandler then task.spawn(pcall, Mods.JobHandler.StopWorking, Mods.JobHandler) end
        end,
    })

    local info = Tab:AddRightGroupbox('Notes', 'info')
    info:AddLabel('Janitor, Stocker and Cashier are the steadiest. Teacher does discipline and hall pass tasks (lectures are a drawing minigame and are skipped). Miner digs the nearest open block. Fisherman finds dry ground by the water on its own.', true)
    info:AddLabel('Pizza Baker makes the pizza the workstation asks for when it can read the order. If its status says it can\'t, press the button below during the shift and send the file.', true)
    local capture = info:AddLabel('', true)
    info:AddButton({
        Text = 'Capture live orders',
        Func = function()
            local count, file = captureOrders()
            capture:SetText(count > 0 and ("captured %d lines into %s (also copied)"):format(count, file) or "no orders nearby")
        end,
    })
end

do
    local Tab = Window:AddTab('Needs', 'heart', 'Keeps your mood up')
    local box = Tab:AddLeftGroupbox('Auto needs', 'heart')
    box:AddToggle('bb_needs', {
        Text = 'Auto needs',
        Tooltip = 'when a need drops low it goes home and uses your own bed, shower, TV/computer or fridge (a quick meal), the normal way. the job farm pauses meanwhile',
        Default = false,
        Callback = function(v) Needs.Enabled = v end,
    })
    box:AddSlider('bb_need_low', {
        Text = 'Refill below',
        Min = 5, Max = 80, Default = Needs.Threshold, Rounding = 0, Suffix = '%',
        Callback = function(v) Needs.Threshold = v end,
    })
    box:AddSlider('bb_need_full', {
        Text = 'Fill up to',
        Min = 50, Max = 100, Default = Needs.FillTo, Rounding = 0, Suffix = '%',
        Callback = function(v) Needs.FillTo = v end,
    })
    for _, name in ipairs({ "Energy", "Hygiene", "Fun", "Hunger" }) do
        box:AddToggle('bb_need_' .. name:lower(), {
            Text = name,
            Tooltip = name == "Hunger" and 'takes the cheapest quick meal from your fridge and eats it (costs what the game charges for it)'
                or name == "Fun" and 'needs a TV or computer on your plot; the starter house has neither' or nil,
            Default = Needs[name],
            Callback = function(v) Needs[name] = v end,
        })
    end
    box:AddButton({
        Text = 'Refill lowest now',
        Func = function() Needs.Now = true end,
    })
    local mood = Tab:AddRightGroupbox('Mood', 'smile')
    local label = mood:AddLabel('-', true)
    every(1, function()
        label:SetText(("energy %.0f   hygiene %.0f\nhunger %.0f   fun %.0f\n%s"):format(
            need("Energy"), need("Hygiene"), need("Hunger"), need("Fun"), Needs.Status))
    end)
end

do
    local Tab = Window:AddTab('Teleport', 'map-pin', 'Fast travel')
    local box = Tab:AddLeftGroupbox('Places', 'map')
    local chosen = LOCATIONS[1]
    box:AddDropdown('bb_tp_place', {
        Text = 'Place',
        Values = LOCATIONS,
        Default = LOCATIONS[1],
        Callback = function(v) chosen = v or chosen end,
    })
    box:AddButton({ Text = 'Travel there', Func = function() task.spawn(fastTravel, chosen) end })
    local home = Tab:AddRightGroupbox('Shortcuts', 'house')
    home:AddButton({
        Text = 'My plot',
        Func = function()
            task.spawn(function()
                if Mods.HouseHandler then pcall(Mods.HouseHandler.ToPlot, Mods.HouseHandler, LocalPlayer) end
            end)
        end,
    })
    home:AddButton({
        Text = 'My job (the farm\'s job)',
        Func = function()
            task.spawn(function()
                if Mods.JobHandler then pcall(Mods.JobHandler.GoToWork, Mods.JobHandler, Farm.Job) end
            end)
        end,
    })
    home:AddLabel('These use the game\'s own fast travel, plot and work teleports.', true)
end

do
    local Tab = Window:AddTab('Vehicle', 'car', 'Driving')
    local box = Tab:AddLeftGroupbox('Speed', 'gauge')
    box:AddToggle('bb_vehicle', {
        Text = 'Faster vehicles',
        Tooltip = 'raises the speed multiplier the game reads off the vehicle you drive (your client drives it)',
        Default = false,
        Callback = function(v) Vehicle.Enabled = v end,
    })
    box:AddSlider('bb_vehicle_mult', {
        Text = 'Multiplier',
        Min = 1, Max = 4, Default = Vehicle.Multiplier, Rounding = 2, Suffix = 'x',
        Callback = function(v) Vehicle.Multiplier = v end,
    })
    box:AddLabel('The game\'s normal multiplier is 1.2. Stay modest: very fast driving is easy for anyone to notice.', true)
end

do
    local Tab = Window:AddTab('Players', 'users', 'What everyone is doing')
    local box = Tab:AddBigGroupbox('In this server', 'users')
    local label = box:AddLabel('-', true)
    every(2, function()
        local folder = ReplicatedStorage:FindFirstChild("Stats")
        local lines = {}
        for _, player in ipairs(Players:GetPlayers()) do
            local s = folder and folder:FindFirstChild(player.Name)
            if s then
                local function v(p)
                    local node = s
                    for part in p:gmatch("[^/]+") do node = node and node:FindFirstChild(part) end
                    return node and node.Value
                end
                local job = v("Job")
                lines[#lines + 1] = ("%s  -  %s   %s   %s%s"):format(
                    player.DisplayName,
                    (job and job ~= "") and (job .. " (" .. money(v("Job/ShiftEarnings")) .. " this shift)") or "not working",
                    money(v("Money")),
                    tostring(v("MoodData") or "-"),
                    v("Activity") and ("   " .. tostring(v("Activity"))) or "")
            end
        end
        label:SetText(#lines > 0 and table.concat(lines, "\n") or "no stats yet")
    end)
end

do
    local Tab = Window:AddTab('Misc', 'settings', 'Other')
    local box = Tab:AddLeftGroupbox('Idle', 'clock')
    box:AddToggle('bb_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'switches off the idle handlers: no 20 minute kick, and the game\'s own AFK report never fires',
        Default = Misc.AntiAfk,
        Callback = function(v)
            Misc.AntiAfk = v
            setAntiAfk(v)
        end,
    })
end

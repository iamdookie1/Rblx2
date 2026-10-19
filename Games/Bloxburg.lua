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
--      - job objects (trash, desks, mine blocks, crates, shelves) carry their
--        own menu callbacks in InteractionHandler's interaction table, the
--        same callbacks a click runs;
--      - tools (fishing rod, hatchet) are used through HotbarUI.EquipData's
--        Function, the same thing a tap on the hotbar runs;
--      - furniture (bed, shower, TV, food) through InteractionHandler's own
--        menu, built in the background and its button clicked;
--      - travel through FastTravelShared, HouseHandler and JobHandler.
--    And every loop is guarded, so no error ever escapes to be reported.
--  * Pay is decided by the server for each finished task; the client never
--    sends an amount. Shifts end if you leave the job's area, so the farm
--    keeps you in it.
--  * 25 RemoteEvents sit right under DataService that the game never uses:
--    likely traps. Nothing here touches them.
--
-- Jobs it can run (the ones whose result doesn't depend on reading a
-- customer's order): School Janitor, High School Teacher (discipline and hall
-- pass tasks), Cave Miner, Hut Fisherman, Lumber Woodcutter, Supermarket
-- Stocker. For the order jobs (hairdresser, baker, ice cream, mechanic,
-- cashiers) the Jobs tab can capture what a live order looks like, so they can
-- be added next.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

--// settings ----------------------------------------------------------------

local JOBS = {
    { Id = "SchoolJanitor", Name = "School Janitor" },
    { Id = "HighSchoolTeacher", Name = "High School Teacher" },
    { Id = "CaveMiner", Name = "Cave Miner" },
    { Id = "HutFisherman", Name = "Hut Fisherman" },
    { Id = "LumberWoodcutter", Name = "Lumber Woodcutter" },
    { Id = "SupermarketStocker", Name = "Supermarket Stocker" },
}

local Farm = {
    Enabled = false,
    Job = "SchoolJanitor",
    Pace = 1,             -- delay multiplier between actions; higher is slower and safer
    Walk = true,          -- walk to things (off: step straight to them)
    Status = "off",
    Tasks = 0,
    StartMoney = nil,
}

local Needs = {
    Enabled = false,
    Threshold = 30,       -- refill a need once it drops under this
    FillTo = 95,
    Energy = true,
    Hygiene = true,
    Fun = true,
    Hunger = true,
    Status = "off",
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
    load("HotbarUI", modules, "_UI/HUDHandler/HotbarUI")
    load("FastTravel", shared, "FastTravelShared")
    load("Equipment", shared, "EquipmentService")
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

-- Runs an object's own menu option, the same callback a click runs. `want`
-- is a label ("I_CleanUp") or nil for the first option it offers right now.
local function runMenu(obj, want)
    local list = interactionTable()
    local entry = list and obj and list[obj]
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

local function hasMenu(obj)
    local list = interactionTable()
    return list ~= nil and list[obj] ~= nil
end

-- the furniture menu, built in the background (nothing shows), and its
-- button for one of `keys` clicked
local function useFurniture(obj, keys)
    local ih, tr = Mods.InteractionHandler, Mods.TranslationHandler
    if not ih or not tr then return false end
    local ok, menu = pcall(ih.ShowMenu, ih, obj, nil, nil, nil, true)
    if not ok or type(menu) ~= "table" or type(menu.Buttons) ~= "table" then return false end
    local wanted = {}
    for _, key in ipairs(keys) do
        local okText, text = pcall(tr.CheckFormat, tr, key)
        if okText and text then wanted[text] = true end
    end
    local clicked = false
    for _, button in pairs(menu.Buttons) do
        if type(button) == "table" and button.Text and wanted[button.Text] then
            clicked = pcall(menu.ClickData, menu, button)
            break
        end
    end
    pcall(function() if not clicked then menu:Close() end end)
    return clicked
end

local function detach()
    local ch = Mods.CharacterHandler
    if ch then pcall(ch.Detach, ch) end
end

--// moving ------------------------------------------------------------------

local function position(obj)
    if typeof(obj) ~= "Instance" then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    local ok, pivot = pcall(obj.GetPivot, obj)
    return ok and pivot.Position or nil
end

-- gets within `radius` of a point: walks there (re-issuing the walk, which
-- Roblox drops after a few seconds), or steps there directly when walking is
-- off or it gets stuck
local function goTo(target, radius, timeout)
    local root, hum = myRoot()
    if not root or not target then return false end
    radius = radius or 5
    local function close()
        local r = myRoot()
        return r ~= nil and (r.Position - target).Magnitude <= radius
    end
    if close() then return true end
    if Farm.Walk then
        local started = os.clock()
        local limit = timeout or math.clamp((root.Position - target).Magnitude / math.max(hum.WalkSpeed, 8) + 3, 3, 25)
        local lastPos, stuckFor = root.Position, 0
        while os.clock() - started < limit and not Unloaded do
            root, hum = myRoot()
            if not root then return false end
            hum:MoveTo(target)
            task.wait(0.4)
            if close() then return true end
            if (root.Position - lastPos).Magnitude < 0.5 then
                stuckFor += 0.4
                if stuckFor >= 1.6 then break end
            else
                stuckFor = 0
            end
            lastPos = root.Position
        end
        if close() then return true end
    end
    root = myRoot()
    if not root then return false end
    detach()
    local dir = root.Position - target
    dir = Vector3.new(dir.X, 0, dir.Z)
    dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(1, 0, 0)
    local stand = target + dir * math.max(radius - 1.5, 1.5) + Vector3.new(0, 2.5, 0)
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

local function nearest(list)
    local root = myRoot()
    if not root then return nil end
    local best, bestDist = nil, math.huge
    for _, obj in ipairs(list) do
        local pos = position(obj)
        if pos then
            local d = (pos - root.Position).Magnitude
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

local LastStartTry = 0

-- on shift for the chosen job, going to work first if needed
local function ensureShift(job)
    if onShift(job) then return true end
    local jh = Mods.JobHandler
    if not jh or os.clock() - LastStartTry < 7 then return false end
    LastStartTry = os.clock()
    if stat("Job") ~= "" and stat("Job") ~= nil then
        Farm.Status = "ending the other shift"
        pcall(jh.StopWorking, jh)
        task.wait(1.5)
    end
    Farm.Status = "going to work"
    pcall(jh.GoToWork, jh, job)
    task.wait(2.5)
    Farm.Status = "starting the shift"
    local ok, started = pcall(jh.StartWorking, jh, job)
    if ok and started then
        task.wait(1)
        return onShift(job)
    end
    -- some jobs start by walking into their area
    local m = jobModule(job)
    local block = m and m.AreaBlock
    local pos = position(block)
    if pos then
        goTo(pos, 3, 12)
        task.wait(1)
        if not onShift(job) then pcall(jh.StartWorking, jh, job) end
    end
    task.wait(1)
    return onShift(job)
end

local Steps = {}

-- trash spawned around the school; clean the nearest
function Steps.SchoolJanitor()
    local school = path(locations(), "SchoolArea/School")
    local spawns = school and school:FindFirstChild("JanitorSpawns")
    if not spawns then
        Farm.Status = "school not loaded yet"
        return 1
    end
    local trash = {}
    for _, d in ipairs(spawns:GetDescendants()) do
        if d.Name == "Object" and hasMenu(d) then trash[#trash + 1] = d end
    end
    local target = nearest(trash)
    if not target then
        Farm.Status = "no trash right now"
        return 2
    end
    Farm.Status = "cleaning"
    if not goTo(position(target), 6) then return 0.5 end
    face(position(target))
    pace(0.35)
    if runMenu(target, "I_CleanUp") then
        local started = os.clock()
        while target.Parent and os.clock() - started < 3 do task.wait(0.1) end
        if not target.Parent then Farm.Tasks += 1 end
    end
    return 0.6
end

-- desks ask for discipline (1) or a hall pass (2); lectures (3) are left
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
    Farm.Status = kind == 1 and "disciplining" or "hall pass"
    if not goTo(position(desk), 6) then return 0.5 end
    face(position(desk))
    pace(0.35)
    if runMenu(desk) then
        Farm.Tasks += 1
        return 0.8
    end
    -- a hall pass has to be fetched first
    if kind == 2 and stations then
        local station = nearest(stations:GetChildren())
        if station and goTo(position(station), 6) then
            pace(0.3)
            runMenu(station, "I_Take")
            task.wait(1)
            if goTo(position(desk), 6) then
                pace(0.3)
                if runMenu(desk) then Farm.Tasks += 1 end
            end
        end
    end
    return 0.8
end

-- the nearest mine block ("x:depth:z")
function Steps.CaveMiner()
    local list = interactionTable()
    if not list then
        Farm.Status = "interaction table not found (needs debug.getupvalues)"
        return 2
    end
    local blocks = {}
    for obj in pairs(list) do
        if typeof(obj) == "Instance" and obj.Parent and obj.Name:match("^%-?%d+:%-?%d+:%-?%d+$") then
            blocks[#blocks + 1] = obj
        end
    end
    local block = nearest(blocks)
    if not block then
        Farm.Status = "no blocks yet"
        return 1.5
    end
    Farm.Status = "mining"
    if not goTo(position(block), 7) then return 0.5 end
    face(position(block))
    if runMenu(block, "I_Mine") then
        local started = os.clock()
        while block.Parent and os.clock() - started < 4 do task.wait(0.1) end
        if not block.Parent then Farm.Tasks += 1 end
    end
    pace(0.25)
    return 0.2
end

-- the equipped tool's own action (what a tap on the hotbar runs)
local function useTool(title)
    local hb = Mods.HotbarUI
    local data = hb and hb.EquipData
    if type(data) ~= "table" or type(data.Function) ~= "function" then return false end
    if title and data.Title ~= title then return false end
    return (pcall(data.Function))
end

local function waterAhead(root)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local from = (root.CFrame * CFrame.new(0, 0, -12)).Position
    local hit = Workspace:Raycast(from, Vector3.new(0, -20, 0), params)
    return hit and hit.Instance == Workspace.Terrain and hit.Material == Enum.Material.Water
end

-- cast; the rod pulls in on its own after the bite wait
function Steps.HutFisherman()
    local root = myRoot()
    if not root then return 1 end
    if equipped() ~= "Fishing Rod" then
        Farm.Status = "waiting for the fishing rod"
        return 1
    end
    if not waterAhead(root) then
        -- turn until the cast lands in water
        local base = root.CFrame
        local found = false
        for i = 1, 16 do
            root.CFrame = base * CFrame.Angles(0, i * math.pi / 8, 0)
            if waterAhead(root) then
                found = true
                break
            end
        end
        if not found then
            root.CFrame = base
            Farm.Status = "no water in front: stand at the edge of the dock"
            return 2
        end
    end
    if useTool("I_Cast") then
        Farm.Status = "fishing"
        Farm.Tasks += 1
        pace(1.2)
    else
        Farm.Status = "waiting for a bite"
    end
    return 0.8
end

local function lumberArea()
    local m = jobModule("LumberWoodcutter")
    local area = m and m.ShiftArea
    if typeof(area) == "Instance" then return area end
    return Workspace:FindFirstChild("LumberCollision", true)
end

local function inside(part, pos)
    local rel = part.CFrame:PointToObjectSpace(pos)
    local half = part.Size / 2
    return math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z
end

-- chop the nearest tree inside the lumber area
function Steps.LumberWoodcutter()
    if equipped() ~= "Hatchet" then
        Farm.Status = "waiting for the hatchet"
        return 1
    end
    local trees = path(Workspace, "Environment/Foliage/Trees")
    local area = lumberArea()
    if not trees then
        Farm.Status = "trees not loaded yet"
        return 1
    end
    local list = {}
    for _, tree in ipairs(trees:GetChildren()) do
        local body = tree:FindFirstChild("Body") or tree:FindFirstChild("CollisionPart")
        if body and tree:FindFirstChild("Leaves") and (not area or inside(area, body.Position)) then
            list[#list + 1] = body
        end
    end
    local body = nearest(list)
    if not body then
        Farm.Status = "no trees standing"
        return 2
    end
    Farm.Status = "chopping"
    if not goTo(body.Position, 4) then return 0.5 end
    face(body.Position)
    local tree = body.Parent
    local started = os.clock()
    while tree and tree.Parent and tree:FindFirstChild("Leaves") and os.clock() - started < 25 and Farm.Enabled and not Unloaded do
        face(body.Position)
        if useTool("I_Chop") then pace(0.15) end
        task.wait(0.25)
    end
    if not (tree and tree.Parent and tree:FindFirstChild("Leaves")) then Farm.Tasks += 1 end
    return 0.5
end

-- crate from the warehouse, onto an empty shelf
function Steps.SupermarketStocker()
    local market = path(locations(), "City/Supermarket")
    if not market then
        Farm.Status = "supermarket not loaded yet"
        return 1
    end
    if equipped() == "Food Crate" then
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
        if not goTo(position(shelf), 5) then return 0.5 end
        face(position(shelf))
        pace(0.3)
        if runMenu(shelf, "I_Restock") then Farm.Tasks += 1 end
        return 0.8
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
    if not goTo(position(crate), 5) then return 0.5 end
    face(position(crate))
    pace(0.3)
    runMenu(crate, "I_Take")
    return 1
end

local NeedsBusy = false

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
        local ok, nextWait = pcall(step)
        Farm.NextWait = ok and tonumber(nextWait) or 1
    end
end)

-- what a live order looks like, for adding the order jobs
local function captureOrders()
    local lines = {}
    local function describe(inst, depth)
        if depth > 6 or #lines > 600 then return end
        local extra = ""
        pcall(function()
            if inst:IsA("ValueBase") then extra = " = " .. tostring(inst.Value) end
            if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then extra = " image=" .. tostring(inst.Image) end
            if inst:IsA("TextLabel") then extra = " text=" .. tostring(inst.Text) end
            if inst:IsA("GuiObject") then extra = extra .. " bg=" .. tostring(inst.BackgroundColor3) end
            if inst:IsA("BasePart") then extra = extra .. " color=" .. tostring(inst.BrickColor) end
        end)
        local attrs = {}
        for k, v in pairs(inst:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
        lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " (" .. inst.ClassName .. ")" .. extra
            .. (#attrs > 0 and ("  {" .. table.concat(attrs, ", ") .. "}") or "")
        for _, child in ipairs(inst:GetChildren()) do describe(child, depth + 1) end
    end
    local roots = locations()
    for _, d in ipairs(roots and roots:GetDescendants() or {}) do
        if d.Name == "Occupied" and d:IsA("ObjectValue") and d.Value then
            lines[#lines + 1] = "== " .. d.Parent:GetFullName()
            describe(d.Parent, 0)
            describe(d.Value, 1)
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

local NEED_KEYS = {
    Energy = { Keys = { "I_Sleep", "I_Rest" }, Words = { "bed" }, Stay = true },
    Hygiene = { Keys = { "I_UseShower", "I_UseBathtub" }, Words = { "shower", "bath" }, Stay = true },
    Fun = { Keys = { "I_Watch", "I_Play", "I_PlayAlone" }, Words = { "tv", "television", "computer", "arcade", "console" }, Stay = true },
    Hunger = { Keys = { "I_Eat", "I_EatQuick" }, Words = { "plate", "bowl", "pizza", "burger", "food", "meal" }, Stay = false },
}

local function myPlot()
    local plots = Workspace:FindFirstChild("Plots")
    return plots and plots:FindFirstChild("Plot_" .. LocalPlayer.Name)
end

local function candidates(words)
    local plot = myPlot()
    local list = {}
    if not plot then return list end
    for _, d in ipairs(plot:GetDescendants()) do
        if d:IsA("Model") then
            local name = d.Name:lower()
            for _, word in ipairs(words) do
                if name:find(word, 1, true) then
                    list[#list + 1] = d
                    break
                end
            end
        end
    end
    return list
end

local function need(name)
    local value = stat("MoodData/" .. name)
    return type(value) == "number" and value or 100
end

local function fillNeed(name)
    local info = NEED_KEYS[name]
    local plot = myPlot()
    if not plot then
        Needs.Status = "no plot"
        return false
    end
    local root = myRoot()
    if not root then return false end
    -- at home first
    if (position(plot) and (position(plot) - root.Position).Magnitude > 150) and Mods.HouseHandler then
        Needs.Status = "going home"
        pcall(Mods.HouseHandler.ToPlot, Mods.HouseHandler, LocalPlayer)
        task.wait(3)
    end
    local options = candidates(info.Words)
    while #options > 0 and not Unloaded do
        local obj, index = nearest(options), nil
        for i, o in ipairs(options) do if o == obj then index = i end end
        table.remove(options, index)
        Needs.Status = ("%s: using %s"):format(name:lower(), obj.Name)
        if goTo(position(obj), 6, 15) then
            face(position(obj))
            wait(0.4)
            if useFurniture(obj, info.Keys) then
                if not info.Stay then
                    task.wait(4)
                    return true
                end
                -- stay until it is full (or the need setting goes off)
                local started = os.clock()
                while need(name) < Needs.FillTo and os.clock() - started < 300 and Needs.Enabled and Needs[name] and not Unloaded do
                    task.wait(1)
                end
                detach()
                return true
            end
        end
    end
    Needs.Status = ("%s: nothing on your plot to use"):format(name:lower())
    return false
end

loop(3, function()
    if not Needs.Enabled or not Stats or not Mods.InteractionHandler then
        Needs.Status = Needs.Enabled and "loading the game" or "off"
        return
    end
    local lowest, lowestValue = nil, Needs.Threshold
    for _, name in ipairs({ "Energy", "Hygiene", "Hunger", "Fun" }) do
        if Needs[name] then
            local value = need(name)
            if value < lowestValue then lowest, lowestValue = name, value end
        end
    end
    if not lowest then
        Needs.Status = "all good"
        return
    end
    NeedsBusy = true
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
        Tooltip = 'walks to each task like a player. off: steps straight to it (faster, more noticeable)',
        Default = Farm.Walk,
        Callback = function(v) Farm.Walk = v end,
    })
    farm:AddButton({
        Text = 'End shift',
        Func = function()
            Farm.Enabled = false
            if Mods.JobHandler then pcall(Mods.JobHandler.StopWorking, Mods.JobHandler) end
        end,
    })

    local info = Tab:AddRightGroupbox('Notes', 'info')
    info:AddLabel('Janitor and Supermarket Stocker are the steadiest. Teacher does discipline and hall pass tasks (not lectures). Miner mines the nearest block. Fisherman: stand at the dock edge facing the water.', true)
    info:AddLabel('Hairdresser, Pizza Baker, Ice Cream, Mechanic and the cashiers need the order read off the customer. Work one of those shifts with a customer waiting, press the button below, and send the file: those jobs can be added from it.', true)
    local capture = info:AddLabel('', true)
    info:AddButton({
        Text = 'Capture live orders',
        Func = function()
            local count, file = captureOrders()
            capture:SetText(count > 0 and ("captured %d lines into %s (also copied)"):format(count, file) or "no customers being served nearby")
        end,
    })
end

do
    local Tab = Window:AddTab('Needs', 'heart', 'Keeps your mood up')
    local box = Tab:AddLeftGroupbox('Auto needs', 'heart')
    box:AddToggle('bb_needs', {
        Text = 'Auto needs',
        Tooltip = 'when a need drops low it goes home and uses your own bed, shower, TV or food, the normal way. the job farm pauses meanwhile',
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
            Tooltip = name == "Hunger" and 'eats food that is already made (on a plate, in a bowl) on your plot' or nil,
            Default = Needs[name],
            Callback = function(v) Needs[name] = v end,
        })
    end
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

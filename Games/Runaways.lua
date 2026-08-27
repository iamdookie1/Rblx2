local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Connections = {}
local function track(conn)
    Connections[#Connections + 1] = conn
    return conn
end

local function getChar()
    return LocalPlayer.Character
end
local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local char = getChar()
    return char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
end
local function isAlive()
    local hum = getHumanoid()
    return hum ~= nil and hum.Health > 0
end

local FlowClient = nil
local FlowLoot = nil
local flowStatus = "not checked"

local function probeFlowClient()
    local mod = ReplicatedStorage:FindFirstChild("FlowClient")
    if not mod then
        flowStatus = "ReplicatedStorage.FlowClient not found"
        return
    end
    local ok, result = pcall(require, mod)
    if not ok then
        flowStatus = "require failed: " .. tostring(result)
        return
    end
    if typeof(result) ~= "table" or not result.Loot then
        flowStatus = "loaded but empty - loot/cash features will no-op"
        FlowClient = result
        return
    end
    FlowClient = result
    FlowLoot = result.Loot
    flowStatus = "loaded - loot/cash features are live"
end
probeFlowClient()

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'heist',
    SubTitle = flowStatus,
    Folder = 'UgcHeist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 170, 40),
})

local function notify(title, content, kind, duration)
    Centrl:Notify({ Title = title, Content = content, Type = kind or 'info', Duration = duration or 4 })
end

--// player -------------------------------------------------------------------

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local Body = PlayerTab:Section({ Title = 'survival', Side = 'left' })
local Move = PlayerTab:Section({ Title = 'movement', Side = 'right' })

local godModeOn = false
Body:Toggle({
    Title = 'god mode (health refill, not true invincibility)',
    Flag = 'heist_god',
    Callback = function(v) godModeOn = v end,
})

local speedValue = 16
local speedOn = false
Move:Slider({
    Title = 'walkspeed',
    Min = 16, Max = 200, Default = 16,
    Flag = 'heist_speed',
    Callback = function(v)
        speedValue = v
        local hum = getHumanoid()
        if hum and speedOn then hum.WalkSpeed = speedValue end
    end,
})
Move:Toggle({
    Title = 'speed boost',
    Flag = 'heist_speed_on',
    Callback = function(v)
        speedOn = v
        local hum = getHumanoid()
        if hum then hum.WalkSpeed = v and speedValue or 16 end
    end,
})

local noclipOn = false
Move:Toggle({
    Title = 'noclip',
    Flag = 'heist_noclip',
    Callback = function(v) noclipOn = v end,
})

local fovValue = 70
local fovOn = false
Move:Slider({
    Title = 'fov',
    Min = 30, Max = 120, Default = 70,
    Flag = 'heist_fov_value',
    Callback = function(v) fovValue = v end,
})
Move:Toggle({
    Title = 'change fov',
    Flag = 'heist_fov_on',
    Callback = function(v)
        fovOn = v
        if not v then Camera.FieldOfView = 70 end
    end,
})

local Teleport = PlayerTab:Section({ Title = 'teleport', Side = 'left' })

local function pivotOf(inst)
    local ok, cf = pcall(function() return inst:GetPivot() end)
    if ok then return cf end
    return nil
end

local function collectLocations()
    local list = {}
    local map = Workspace:FindFirstChild("Map")
    if map then
        local buildings = map:FindFirstChild("Buildings")
        if buildings then
            for _, child in ipairs(buildings:GetChildren()) do
                list[#list + 1] = { Name = child.Name, Target = child }
            end
        end
        local startArea = map:FindFirstChild("StartArea")
        if startArea then
            list[#list + 1] = { Name = "Start Area", Target = startArea }
        end
    end
    local vehicles = Workspace:FindFirstChild("Vehicles")
    if vehicles then
        for _, v in ipairs(vehicles:GetChildren()) do
            list[#list + 1] = { Name = "Vehicle: " .. v.Name, Target = v }
        end
    end
    table.sort(list, function(a, b) return a.Name < b.Name end)
    return list
end

local locations = collectLocations()
local locationNames = {}
for i, entry in ipairs(locations) do locationNames[i] = entry.Name end

local teleportChoice = locationNames[1]
Teleport:Dropdown({
    Title = 'location',
    Values = locationNames,
    Default = teleportChoice,
    Flag = 'heist_tp_choice',
    Callback = function(v) teleportChoice = v end,
})

Teleport:Button({
    Title = 'teleport',
    Callback = function()
        local root = getRoot()
        if not root then
            notify('heist', 'no character', 'error')
            return
        end
        for _, entry in ipairs(locations) do
            if entry.Name == teleportChoice then
                local cf = pivotOf(entry.Target)
                if cf then
                    root.CFrame = cf + Vector3.new(0, 5, 0)
                    notify('heist', 'teleported to ' .. entry.Name, 'success', 2)
                else
                    notify('heist', 'could not read a pivot for ' .. entry.Name, 'error')
                end
                return
            end
        end
    end,
})

Teleport:Button({
    Title = 'refresh location list',
    Callback = function()
        notify('heist', 'reload the script to refresh the dropdown (Lib2 dropdowns are built once)', 'info', 5)
    end,
})

--// combat -------------------------------------------------------------------

local CombatTab = Window:Tab({ Title = 'combat', Icon = 'sword' })
local Aura = CombatTab:Section({ Title = 'kill aura', Side = 'left' })
local AimSec = CombatTab:Section({ Title = 'silent aim', Side = 'right' })

Aura:Paragraph({
    Title = 'kill aura / kill all npc',
    Text = 'Auto-faces and swings/fires whatever tool you have equipped at the nearest live NPC in range. Left running it clears anything that wanders into range, which is the same thing as "kill all" for anything currently nearby. Damage is server-validated so this only speeds up landing real hits, it does not one-shot anything by itself.',
})

local killAuraRadius = 20
Aura:Slider({
    Title = 'range (studs)',
    Min = 5, Max = 80, Default = 20,
    Flag = 'heist_kill_radius',
    Callback = function(v) killAuraRadius = v end,
})

local killAuraInterval = 0.2
Aura:Slider({
    Title = 'attack interval',
    Min = 0.05, Max = 1, Default = 0.2, Increment = 0.05,
    Flag = 'heist_kill_interval',
    Callback = function(v) killAuraInterval = v end,
})

local killAuraOn = false
Aura:Toggle({
    Title = 'kill aura',
    Flag = 'heist_kill_on',
    Callback = function(v) killAuraOn = v end,
})

local function nearestNpc(radius)
    local root = getRoot()
    if not root then return nil, nil end
    local best, bestDist = nil, radius
    for _, npc in ipairs(CollectionService:GetTagged("NPC")) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        local hrp = npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart
        if hum and hum.Health > 0 and hrp then
            local dist = (hrp.Position - root.Position).Magnitude
            if dist < bestDist then
                best, bestDist = npc, dist
            end
        end
    end
    return best, bestDist
end

local function activateTool(tool)
    if not tool then return end
    local ok = pcall(function() tool:Activate() end)
    if not ok and typeof(firesignal) == "function" then
        pcall(firesignal, tool.Activated)
    end
end

local lastAttack = 0
track(RunService.Heartbeat:Connect(function()
    if not killAuraOn or not isAlive() then return end
    local root = getRoot()
    if not root then return end
    local target, _ = nearestNpc(killAuraRadius)
    if not target then return end
    local hrp = target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
    if not hrp then return end
    local look = Vector3.new(hrp.Position.X, root.Position.Y, hrp.Position.Z)
    root.CFrame = CFrame.lookAt(root.Position, look)
    if os.clock() - lastAttack >= killAuraInterval then
        lastAttack = os.clock()
        local char = getChar()
        local tool = char and char:FindFirstChildOfClass("Tool")
        activateTool(tool)
    end
end))

AimSec:Paragraph({
    Title = 'silent aim',
    Text = 'Best-effort camera assist: while enabled and left mouse is held, the camera is nudged toward the nearest visible player/NPC in a small cone in front of you. This only helps on weapons that trust the client-reported aim direction - it will not affect games that raycast purely server-side.',
})

local silentAimOn = false
local silentAimRange = 250
AimSec:Slider({
    Title = 'range (studs)',
    Min = 20, Max = 1000, Default = 250,
    Flag = 'heist_aim_range',
    Callback = function(v) silentAimRange = v end,
})
AimSec:Toggle({
    Title = 'silent aim',
    Flag = 'heist_aim_on',
    Callback = function(v) silentAimOn = v end,
})

local function bestAimTarget(range)
    local root = getRoot()
    if not root then return nil end
    local origin = Camera.CFrame.Position
    local forward = Camera.CFrame.LookVector
    local best, bestScore = nil, -1

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getChar() }

    local function consider(model)
        local hum = model:FindFirstChildOfClass("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        if not hum or hum.Health <= 0 or not hrp then return end
        local toTarget = (hrp.Position - origin)
        local dist = toTarget.Magnitude
        if dist > range then return end
        local dir = toTarget.Unit
        local score = forward:Dot(dir)
        if score < 0.85 then return end
        local hit = Workspace:Raycast(origin, toTarget, params)
        if hit and hit.Instance and not hit.Instance:IsDescendantOf(model) then return end
        if score > bestScore then
            best, bestScore = hrp, score
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then consider(plr.Character) end
    end
    for _, npc in ipairs(CollectionService:GetTagged("NPC")) do
        consider(npc)
    end
    return best
end

track(RunService.RenderStepped:Connect(function()
    if fovOn then
        Camera.FieldOfView = fovValue
    end
    if not silentAimOn then return end
    if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return end
    local target = bestAimTarget(silentAimRange)
    if target then
        Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, target.Position)
    end
end))

--// loot ---------------------------------------------------------------------

local LootTab = Window:Tab({ Title = 'loot', Icon = 'gem' })
local LootSec = LootTab:Section({ Title = 'auto loot', Side = 'left' })
local CashSec = LootTab:Section({ Title = 'cash', Side = 'right' })

LootSec:Paragraph({
    Title = 'auto loot / loot aura / bring items',
    Text = 'Calls the game client\'s own pickup function (ReplicatedStorage.FlowClient.Loot) for anything tagged Draggable + Equippable in range - the same call the real pickup key makes, not a fake remote. "Bring items" instead walks you to large non-equippable loot in sequence, since those need to be physically carried and there is no safe way to fake that from a script. Status: ' .. flowStatus,
})

local lootRadius = 25
LootSec:Slider({
    Title = 'range (studs)',
    Min = 5, Max = 100, Default = 25,
    Flag = 'heist_loot_radius',
    Callback = function(v) lootRadius = v end,
})

local function nearbyDraggables(radius)
    local root = getRoot()
    if not root then return {} end
    local items = {}
    for _, model in ipairs(CollectionService:GetTagged("Draggable")) do
        if model:IsA("Model") then
            local ref = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
            if ref then
                local dist = (ref.Position - root.Position).Magnitude
                if dist <= radius then
                    items[#items + 1] = { model = model, part = ref, dist = dist }
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.dist < b.dist end)
    return items
end

local function tryLootItem(item)
    if not FlowLoot then return false end
    local model, part = item.model, item.part
    if model:HasTag("BuyableLoot") then return false end
    local ok, result
    if model:HasTag("Equippable") then
        ok, result = pcall(FlowLoot.LootEquip, part)
        return ok and result == "Success"
    else
        ok, result = pcall(FlowLoot.OwnNetworkRequestAsync, model, true)
        return ok and result ~= false
    end
end

LootSec:Button({
    Title = 'auto loot (one sweep)',
    Callback = function()
        if not FlowLoot then
            notify('heist', 'loot module unavailable: ' .. flowStatus, 'error')
            return
        end
        local grabbed = 0
        for _, item in ipairs(nearbyDraggables(lootRadius)) do
            if tryLootItem(item) then grabbed = grabbed + 1 end
        end
        notify('heist', ('grabbed %d item(s)'):format(grabbed), 'success', 3)
    end,
})

local lootAuraOn = false
LootSec:Toggle({
    Title = 'loot aura',
    Flag = 'heist_loot_on',
    Callback = function(v) lootAuraOn = v end,
})

LootSec:Button({
    Title = 'bring items (teleport-to sweep, one shot)',
    Callback = function()
        local root = getRoot()
        if not root or not FlowLoot then
            notify('heist', 'no character or loot module unavailable', 'error')
            return
        end
        local origin = root.CFrame
        local items = {}
        for _, model in ipairs(CollectionService:GetTagged("Draggable")) do
            if model:IsA("Model") and not model:HasTag("Equippable") and not model:HasTag("BuyableLoot") then
                local ref = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                if ref then
                    local dist = (ref.Position - root.Position).Magnitude
                    if dist <= lootRadius * 2 then
                        items[#items + 1] = { model = model, part = ref, dist = dist }
                    end
                end
            end
        end
        table.sort(items, function(a, b) return a.dist < b.dist end)
        local touched = 0
        for _, item in ipairs(items) do
            root.CFrame = item.part.CFrame + Vector3.new(0, 3, 0)
            task.wait(0.15)
            if tryLootItem(item) then touched = touched + 1 end
        end
        root.CFrame = origin
        notify('heist', ('visited %d large item(s)'):format(touched), 'success', 3)
    end,
})

CashSec:Paragraph({
    Title = 'auto collect cash / cash aura',
    Text = 'Reuses the same loot call, filtered to anything whose name looks like a cash pickup. If this game does not spawn cash as a physical Draggable object, this will find nothing to do.',
})

local function isCashName(name)
    local lower = name:lower()
    return lower:find("cash") ~= nil or lower:find("money") ~= nil
end

CashSec:Button({
    Title = 'collect cash nearby (one sweep)',
    Callback = function()
        if not FlowLoot then
            notify('heist', 'loot module unavailable: ' .. flowStatus, 'error')
            return
        end
        local grabbed = 0
        for _, item in ipairs(nearbyDraggables(lootRadius)) do
            if isCashName(item.model.Name) and tryLootItem(item) then
                grabbed = grabbed + 1
            end
        end
        notify('heist', ('collected %d cash pickup(s)'):format(grabbed), 'success', 3)
    end,
})

local cashAuraOn = false
CashSec:Toggle({
    Title = 'cash aura',
    Flag = 'heist_cash_on',
    Callback = function(v) cashAuraOn = v end,
})

local lastLootSweep = 0
track(RunService.Heartbeat:Connect(function()
    if not (lootAuraOn or cashAuraOn) then return end
    if not FlowLoot then return end
    if os.clock() - lastLootSweep < 0.5 then return end
    lastLootSweep = os.clock()
    for _, item in ipairs(nearbyDraggables(lootRadius)) do
        if lootAuraOn and not isCashName(item.model.Name) then
            tryLootItem(item)
        elseif cashAuraOn and isCashName(item.model.Name) then
            tryLootItem(item)
        end
    end
end))

--// shop & prompts ------------------------------------------------------------

local ShopTab = Window:Tab({ Title = 'shop', Icon = 'shopping-cart' })
local PromptSec = ShopTab:Section({ Title = 'instant prompt', Side = 'left' })
local BuySec = ShopTab:Section({ Title = 'remote buy', Side = 'right' })

PromptSec:Paragraph({
    Title = 'instant prompt',
    Text = 'Sets every ProximityPrompt currently in the game to zero hold time, so any prompt you actually walk up and hold triggers instantly. Pure property write, no executor function required.',
})

local originalHold = setmetatable({}, { __mode = 'k' })
local instantPromptOn = false

local function applyInstant(prompt, on)
    if on then
        if originalHold[prompt] == nil then
            originalHold[prompt] = prompt.HoldDuration
        end
        prompt.HoldDuration = 0
    else
        if originalHold[prompt] ~= nil then
            prompt.HoldDuration = originalHold[prompt]
            originalHold[prompt] = nil
        end
    end
end

PromptSec:Toggle({
    Title = 'instant prompt',
    Flag = 'heist_instant_prompt',
    Callback = function(v)
        instantPromptOn = v
        for _, prompt in ipairs(Workspace:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") then
                applyInstant(prompt, v)
            end
        end
    end,
})

track(Workspace.DescendantAdded:Connect(function(inst)
    if instantPromptOn and inst:IsA("ProximityPrompt") then
        applyInstant(inst, true)
    end
end))

BuySec:Paragraph({
    Title = 'remote buy in shop',
    Text = 'Fires every "BuyPrompt" in the pawn shop with fireproximityprompt, regardless of how far you are standing. Needs an executor with fireproximityprompt support; the server may still reject purchases from too far away, in which case walk in first and use instant prompt instead.',
})

BuySec:Button({
    Title = 'buy everything in reach now',
    Callback = function()
        if typeof(fireproximityprompt) ~= "function" then
            notify('heist', 'fireproximityprompt not supported by this executor', 'error')
            return
        end
        local root = getRoot()
        local fired = 0
        for _, prompt in ipairs(Workspace:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") and prompt.Name == "BuyPrompt" and prompt.Enabled then
                local ok = pcall(fireproximityprompt, prompt)
                if ok then fired = fired + 1 end
            end
        end
        notify('heist', ('fired %d buy prompt(s)'):format(fired), 'success', 3)
    end,
})

--// vehicle ------------------------------------------------------------------

local VehicleTab = Window:Tab({ Title = 'vehicle', Icon = 'car' })
local FuelSec = VehicleTab:Section({ Title = 'refuel', Side = 'left' })
local RepairSec = VehicleTab:Section({ Title = 'repair', Side = 'right' })

FuelSec:Paragraph({
    Title = 'auto refuel vehicle',
    Text = 'Clicks the gas pump payment detector and opens the gas tank prompt for the nearest vehicle. The pump\'s own RemoteEvent is also fired as a best-effort extra try - if that part does nothing, the click + prompt above are the reliable half.',
})

FuelSec:Button({
    Title = 'refuel nearest vehicle',
    Callback = function()
        local root = getRoot()
        if not root then
            notify('heist', 'no character', 'error')
            return
        end

        local fired = 0
        for _, detector in ipairs(Workspace:GetDescendants()) do
            if detector:IsA("ClickDetector") and detector.Parent and detector.Parent.Name == "PayGas" then
                local ok = pcall(function()
                    if typeof(fireclickdetector) == "function" then
                        fireclickdetector(detector)
                    else
                        detector.MouseClick:Fire(LocalPlayer)
                    end
                end)
                if ok then fired = fired + 1 end
            end
        end

        for _, prompt in ipairs(Workspace:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") and prompt.ObjectText == "Gas tank" then
                pcall(function()
                    if typeof(fireproximityprompt) == "function" then
                        fireproximityprompt(prompt)
                    end
                end)
            end
        end

        for _, remote in ipairs(Workspace:GetDescendants()) do
            if remote:IsA("RemoteEvent") and remote.Name == "RemoteEvent" and remote.Parent and remote.Parent.Name == "RefuelSystem" then
                pcall(function() remote:FireServer() end)
            end
        end

        notify('heist', ('triggered %d gas pump(s) - experimental'):format(fired), 'info', 4)
    end,
})

RepairSec:Paragraph({
    Title = 'auto repair vehicle',
    Text = 'This game repairs vehicles with an equippable "Repair" tool, not a remote. If you have one in your backpack, this equips it and swings it at the nearest vehicle for a few seconds. Nothing happens if you do not own a repair tool.',
})

RepairSec:Button({
    Title = 'auto repair (5s)',
    Callback = function()
        local char = getChar()
        if not char then return end
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        local tool = char:FindFirstChildOfClass("Tool")
        if not tool or not tool:HasTag("Repair") then
            tool = nil
            if backpack then
                for _, item in ipairs(backpack:GetChildren()) do
                    if item:IsA("Tool") and item:HasTag("Repair") then
                        tool = item
                        break
                    end
                end
            end
            if tool then
                local humanoid = getHumanoid()
                if humanoid then humanoid:EquipTool(tool) end
            end
        end

        if not tool then
            notify('heist', 'no repair tool found in backpack or hand', 'error')
            return
        end

        local root = getRoot()
        local nearestVehicle, nearestDist = nil, math.huge
        local vehicles = Workspace:FindFirstChild("Vehicles")
        if vehicles and root then
            for _, v in ipairs(vehicles:GetChildren()) do
                local ref = v.PrimaryPart or v:FindFirstChildWhichIsA("BasePart", true)
                if ref then
                    local dist = (ref.Position - root.Position).Magnitude
                    if dist < nearestDist then
                        nearestVehicle, nearestDist = v, dist
                    end
                end
            end
        end
        if nearestVehicle and root then
            local pivot = pivotOf(nearestVehicle)
            if pivot then root.CFrame = pivot + Vector3.new(3, 3, 0) end
        end

        local stop = os.clock() + 5
        while os.clock() < stop do
            activateTool(tool)
            task.wait(0.3)
        end
        notify('heist', 'repair attempt finished', 'success', 3)
    end,
})

--// visual & farm --------------------------------------------------------------

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSec = VisualTab:Section({ Title = 'esp', Side = 'left' })
local FarmSec = VisualTab:Section({ Title = 'auto farm', Side = 'right' })

local espOn = false
local espHighlights = {}

local function clearEsp()
    for _, h in pairs(espHighlights) do
        if h and h.Parent then h:Destroy() end
    end
    espHighlights = {}
end

local function applyHighlight(model, color)
    if espHighlights[model] then return end
    local h = Instance.new("Highlight")
    h.FillColor = color
    h.OutlineColor = color
    h.FillTransparency = 0.6
    h.OutlineTransparency = 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent = model
    espHighlights[model] = h
end

EspSec:Toggle({
    Title = 'esp (players blue, npcs red)',
    Flag = 'heist_esp',
    Callback = function(v)
        espOn = v
        if not v then clearEsp() end
    end,
})

local lastEspSweep = 0
track(RunService.Heartbeat:Connect(function()
    if not espOn then return end
    if os.clock() - lastEspSweep < 1 then return end
    lastEspSweep = os.clock()

    for model in pairs(espHighlights) do
        if not model.Parent then
            espHighlights[model]:Destroy()
            espHighlights[model] = nil
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            applyHighlight(plr.Character, Color3.fromRGB(80, 160, 255))
        end
    end
    for _, npc in ipairs(CollectionService:GetTagged("NPC")) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            applyHighlight(npc, Color3.fromRGB(255, 80, 80))
        end
    end
end))

FarmSec:Paragraph({
    Title = 'auto farm',
    Text = 'One switch for kill aura + loot aura + cash aura together, using the range set on their own tabs.',
})

local autoFarmOn = false
FarmSec:Toggle({
    Title = 'auto farm',
    Flag = 'heist_autofarm',
    Callback = function(v)
        autoFarmOn = v
        killAuraOn = v
        lootAuraOn = v
        cashAuraOn = v
    end,
})

--// noclip & god mode loop -----------------------------------------------------

track(RunService.Stepped:Connect(function()
    if not noclipOn then return end
    local char = getChar()
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end
end))

track(RunService.Heartbeat:Connect(function()
    if not godModeOn then return end
    local hum = getHumanoid()
    if hum and hum.Health > 0 and hum.Health < hum.MaxHealth then
        hum.Health = hum.MaxHealth
    end
end))

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    local hum = getHumanoid()
    if hum and speedOn then
        hum.WalkSpeed = speedValue
    end
end)

--// status ---------------------------------------------------------------------

local StatusTab = Window:Tab({ Title = 'status', Icon = 'info' })
local StatusSec = StatusTab:Section({ Title = 'flow module', Side = 'left' })
StatusSec:Label({ Text = 'FlowClient: ' .. flowStatus })
StatusSec:Button({
    Title = 're-check flow module',
    Callback = function()
        probeFlowClient()
        notify('heist', flowStatus, FlowLoot and 'success' or 'error', 5)
    end,
})

local ControlSec = StatusTab:Section({ Title = 'control', Side = 'right' })
ControlSec:Button({
    Title = 'unload',
    Callback = function()
        godModeOn = false
        speedOn = false
        noclipOn = false
        fovOn = false
        killAuraOn = false
        silentAimOn = false
        lootAuraOn = false
        cashAuraOn = false
        autoFarmOn = false
        espOn = false

        local hum = getHumanoid()
        if hum then hum.WalkSpeed = 16 end
        Camera.FieldOfView = 70

        local char = getChar()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = true
                end
            end
        end

        if instantPromptOn then
            for prompt in pairs(originalHold) do
                applyInstant(prompt, false)
            end
        end
        instantPromptOn = false

        clearEsp()

        for _, conn in ipairs(Connections) do
            pcall(function() conn:Disconnect() end)
        end

        Window:Destroy()
    end,
})

Window:Load()
notify('heist', flowStatus, FlowLoot and 'success' or 'error', 6)

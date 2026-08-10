local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Config = {
    Enabled = false,
    InArenaCheck = true,
    MaxDistance = 0,

    ApproachSpeed = 28,
    HugDistance = 3,

    StickyTarget = true,
    StickyThreshold = 8,
}

local function getChar()
    return LocalPlayer.Character
end

local function getHRP()
    local char = getChar()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getData(plr)
    return plr:FindFirstChild("Data")
end

local function hasBomb(char)
    if not char then return false end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return false end
    return tool:FindFirstChild("BombHandle") ~= nil or tool.Name == "Bomb"
end

local function iHaveBomb()
    return hasBomb(getChar())
end

local function isAlive(plr)
    local data = getData(plr)
    if not data then return false end
    if data:GetAttribute("Alive") == true then return true end
    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local function isInArena()
    local data = getData(LocalPlayer)
    local arena = data and data:FindFirstChild("ActiveArena")
    return arena ~= nil and arena.Value ~= nil
end

-- Teammates share a side (Left/Right) of the same arena's duel. Slot.Value
-- points at each player's own numbered slot instance under
-- Arena.Slots.Left.<n> / Right.<n> - every player has a distinct slot
-- instance, even teammates - so compare the slot's parent, not the slot
-- itself.
local function isTeammate(plr)
    local myData = getData(LocalPlayer)
    local theirData = getData(plr)
    if not myData or not theirData then return true end

    local myArena = myData:FindFirstChild("ActiveArena")
    local theirArena = theirData:FindFirstChild("ActiveArena")
    if not myArena or not theirArena then return true end
    if myArena.Value == nil or theirArena.Value ~= myArena.Value then return true end

    local mySlot = myData:FindFirstChild("Slot")
    local theirSlot = theirData:FindFirstChild("Slot")
    if not mySlot or not theirSlot then return true end
    if mySlot.Value == nil or theirSlot.Value == nil then return false end

    local mySide = mySlot.Value.Parent
    local theirSide = theirSlot.Value.Parent
    return mySide ~= nil and mySide == theirSide
end

local function findBestTarget(myHRP)
    local best, bestDist = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 and isAlive(plr) and not isTeammate(plr) and not hasBomb(char) then
                local dist = (hrp.Position - myHRP.Position).Magnitude
                if Config.MaxDistance <= 0 or dist <= Config.MaxDistance then
                    if dist < bestDist then
                        best, bestDist = plr, dist
                    end
                end
            end
        end
    end
    return best
end

local lockedTarget = nil
local chasing = false
local originalWalkSpeed = nil

local function startChasing(humanoid)
    if chasing then return end
    chasing = true
    originalWalkSpeed = humanoid.WalkSpeed
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = Config.ApproachSpeed
end

local function stopChasing(humanoid)
    if not chasing then return end
    chasing = false
    lockedTarget = nil
    if humanoid then
        humanoid.AutoRotate = true
        if originalWalkSpeed then
            humanoid.WalkSpeed = originalWalkSpeed
        end
    end
    originalWalkSpeed = nil
end

local lastMoveTo = 0
local MOVE_TO_INTERVAL = 0.15

-- BombHandle carries a TouchInterest (i.e. the transfer is a real physical
-- Touched collision, not a remote call), so "auto rotate" has to do two
-- separate jobs: face the target's *current* position exactly every frame
-- (rotation only, never fights whatever is driving position), and actually
-- close the distance to them (position), snapping the last few studs so the
-- bomb's hitbox genuinely overlaps theirs instead of stopping just short.
RunService.Heartbeat:Connect(function(dt)
    local humanoid = getHumanoid()

    if not Config.Enabled or (Config.InArenaCheck and not isInArena()) or not iHaveBomb() then
        stopChasing(humanoid)
        return
    end

    local myHRP = getHRP()
    if not myHRP or not humanoid then
        stopChasing(humanoid)
        return
    end

    local target = findBestTarget(myHRP)

    if Config.StickyTarget and lockedTarget then
        local lc = lockedTarget.Character
        local lh = lc and lc:FindFirstChild("HumanoidRootPart")
        local lhum = lc and lc:FindFirstChildOfClass("Humanoid")
        local stillValid = lh and lhum and lhum.Health > 0
            and isAlive(lockedTarget) and not isTeammate(lockedTarget) and not hasBomb(lc)
            and (Config.MaxDistance <= 0 or (lh.Position - myHRP.Position).Magnitude <= Config.MaxDistance)

        if not stillValid then
            lockedTarget = nil
        elseif target and target ~= lockedTarget then
            local newDist = (target.Character.HumanoidRootPart.Position - myHRP.Position).Magnitude
            local lockedDist = (lh.Position - myHRP.Position).Magnitude
            if lockedDist - newDist < Config.StickyThreshold then
                target = lockedTarget
            end
        elseif not target then
            target = lockedTarget
        end
    end

    if not target then
        stopChasing(humanoid)
        return
    end
    lockedTarget = target
    startChasing(humanoid)

    local tHRP = target.Character.HumanoidRootPart
    local toTarget = tHRP.Position - myHRP.Position
    local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
    local dist = flatToTarget.Magnitude

    if dist > 0.05 then
        myHRP.CFrame = CFrame.lookAt(myHRP.Position, myHRP.Position + flatToTarget)
    end

    if dist <= Config.HugDistance then
        local step = math.min(dist, Config.ApproachSpeed * dt)
        if flatToTarget.Magnitude > 0.05 then
            myHRP.CFrame = myHRP.CFrame + flatToTarget.Unit * step
        end
    elseif os.clock() - lastMoveTo > MOVE_TO_INTERVAL then
        lastMoveTo = os.clock()
        humanoid:MoveTo(tHRP.Position)
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    chasing = false
    lockedTarget = nil
    originalWalkSpeed = nil
end)

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui/main/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'timebomb',
    SubTitle = 'auto rotate',
    Folder = 'TimebombAutoRotate',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 90, 60),
})

local RotateTab = Window:Tab({ Title = 'auto rotate', Icon = 'crosshair' })

local Main = RotateTab:Section({ Title = 'main', Side = 'left' })

Main:Toggle({
    Title = 'auto rotate',
    Flag = 'tb_enabled',
    Default = false,
    Callback = function(v) Config.Enabled = v end,
})

Main:Toggle({
    Title = 'in arena check',
    Flag = 'tb_arena_check',
    Default = true,
    Callback = function(v) Config.InArenaCheck = v end,
})

Main:Slider({
    Title = 'max distance (0 = no limit)',
    Flag = 'tb_max_distance',
    Min = 0,
    Max = 50,
    Increment = 1,
    Default = 0,
    Suffix = ' studs',
    Callback = function(v) Config.MaxDistance = v end,
})

local Movement = RotateTab:Section({ Title = 'movement', Side = 'right' })

Movement:Slider({
    Title = 'approach speed',
    Flag = 'tb_approach_speed',
    Min = 10,
    Max = 50,
    Increment = 1,
    Default = 28,
    Suffix = ' studs/s',
    Callback = function(v)
        Config.ApproachSpeed = v
        if chasing then
            local humanoid = getHumanoid()
            if humanoid then humanoid.WalkSpeed = v end
        end
    end,
})

Movement:Slider({
    Title = 'hug distance',
    Flag = 'tb_hug_distance',
    Min = 1,
    Max = 8,
    Increment = 0.5,
    Default = 3,
    Suffix = ' studs',
    Callback = function(v) Config.HugDistance = v end,
})

local Targeting = RotateTab:Section({ Title = 'targeting', Side = 'left' })

Targeting:Toggle({
    Title = 'sticky target',
    Flag = 'tb_sticky',
    Default = true,
    Callback = function(v) Config.StickyTarget = v end,
})

Targeting:Slider({
    Title = 'sticky threshold',
    Flag = 'tb_sticky_threshold',
    Min = 0,
    Max = 30,
    Increment = 1,
    Default = 8,
    Suffix = ' studs',
    Callback = function(v) Config.StickyThreshold = v end,
})

local Live = RotateTab:Section({ Title = 'live state', Side = 'right' })
local HasBombLabel = Live:Label({ Title = 'has bomb: no' })
local InArenaLabel = Live:Label({ Title = 'in arena: no' })
local TargetLabel = Live:Label({ Title = 'target: none' })

task.spawn(function()
    while true do
        task.wait(0.2)
        HasBombLabel:Set('has bomb: ' .. (iHaveBomb() and 'yes' or 'no'))
        InArenaLabel:Set('in arena: ' .. (isInArena() and 'yes' or 'no'))
        if lockedTarget then
            local lc = lockedTarget.Character
            local lh = lc and lc:FindFirstChild("HumanoidRootPart")
            local myHRP = getHRP()
            if lh and myHRP then
                TargetLabel:Set(('target: %s (%d studs)'):format(lockedTarget.Name, math.floor((lh.Position - myHRP.Position).Magnitude)))
            else
                TargetLabel:Set('target: ' .. lockedTarget.Name)
            end
        else
            TargetLabel:Set('target: none')
        end
    end
end)

Window:Load()

Centrl:Notify({
    Title = 'timebomb',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

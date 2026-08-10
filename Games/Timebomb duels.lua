local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Config = {
    AutoPlay = false,
    InArenaCheck = true,
    MaxDistance = 0,

    UseHug = true,
    ApproachSpeed = 28,
    HugDistance = 3,

    StickyTarget = true,
    StickyThreshold = 8,

    HitboxEnabled = false,
    HitboxMultiplier = 3,

    AutoTPEnabled = false,
    AutoTPThreshold = 3,
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

-- The bomb's remaining-time display is driven by a server script we can't
-- read (marked unreadable in the dump), so there's no attribute name to
-- trust. The TimeLeft label itself is real and live though, so read the
-- number straight out of its Text instead of guessing at the attribute.
local function parseTimeLeft(text)
    if not text or text == "" then return nil end
    local mins, secs = text:match("^(%d+):(%d+)$")
    if mins then
        return tonumber(mins) * 60 + tonumber(secs)
    end
    local n = text:match("(%d+%.?%d*)")
    return n and tonumber(n) or nil
end

local function getBombTimeLeft()
    local char = getChar()
    local tool = char and char:FindFirstChildOfClass("Tool")
    local handle = tool and tool:FindFirstChild("BombHandle")
    local ui = handle and handle:FindFirstChild("UIAttachment") and handle.UIAttachment:FindFirstChild("UI")
    local label = ui and ui:FindFirstChild("TimeLeft")
    return label and parseTimeLeft(label.Text)
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

-- Lands just short of the target rather than exactly on top of them, from
-- whichever side we're already approaching from, matching their height
-- exactly so the landing spot is guaranteed to overlap their hitbox instead
-- of leaving a vertical gap on stairs/platforms.
local TP_LAND_DISTANCE = 1.5

local function teleportNear(myHRP, targetHRP)
    local away = myHRP.Position - targetHRP.Position
    local flatAway = Vector3.new(away.X, 0, away.Z)
    if flatAway.Magnitude < 0.1 then
        flatAway = Vector3.new(1, 0, 0)
    end
    local landPos = targetHRP.Position + flatAway.Unit * TP_LAND_DISTANCE
    landPos = Vector3.new(landPos.X, targetHRP.Position.Y, landPos.Z)
    myHRP.CFrame = CFrame.lookAt(landPos, targetHRP.Position)
end

local lastMoveTo = 0
local MOVE_TO_INTERVAL = 0.15

-- BombHandle carries a TouchInterest (i.e. the transfer is a real physical
-- Touched collision, not a remote call), so auto play has to do two separate
-- jobs: face the target's *current* position exactly every frame (rotation
-- only, never fights whatever is driving position), and actually close the
-- distance to them (position), snapping the last few studs so the bomb's
-- hitbox genuinely overlaps theirs instead of stopping just short. When the
-- timer's critical, auto tp skips the walk entirely and lands next to them.
RunService.Heartbeat:Connect(function(dt)
    local humanoid = getHumanoid()

    if not Config.AutoPlay or (Config.InArenaCheck and not isInArena()) or not iHaveBomb() then
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

    if Config.AutoTPEnabled then
        local timeLeft = getBombTimeLeft()
        if timeLeft and timeLeft <= Config.AutoTPThreshold then
            teleportNear(myHRP, tHRP)
            return
        end
    end

    local toTarget = tHRP.Position - myHRP.Position
    local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
    local dist3D = toTarget.Magnitude

    if flatToTarget.Magnitude > 0.05 then
        myHRP.CFrame = CFrame.lookAt(myHRP.Position, myHRP.Position + flatToTarget)
    end

    if Config.UseHug and dist3D <= Config.HugDistance then
        local step = math.min(dist3D, Config.ApproachSpeed * dt)
        if toTarget.Magnitude > 0.05 then
            myHRP.CFrame = myHRP.CFrame + toTarget.Unit * step
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

-- Hitbox expander: R6 characters here, so "Torso" is the one part that's
-- both large and actually collidable/touchable (arms/legs are thin and
-- HumanoidRootPart doesn't collide) - enlarging it makes it far easier for
-- either side's BombHandle to land a touch. Runs independently of auto play
-- so it's usable on its own.
local hitboxOriginalSizes = {}

local function applyHitboxSize(plr)
    local char = plr.Character
    local torso = char and char:FindFirstChild("Torso")
    if not torso then return end
    if not hitboxOriginalSizes[torso] then
        hitboxOriginalSizes[torso] = torso.Size
    end
    local desired = hitboxOriginalSizes[torso] * Config.HitboxMultiplier
    if (torso.Size - desired).Magnitude > 0.05 then
        torso.Size = desired
    end
end

local function restoreAllHitboxSizes()
    for torso, size in pairs(hitboxOriginalSizes) do
        if torso and torso.Parent then
            torso.Size = size
        end
    end
    hitboxOriginalSizes = {}
end

task.spawn(function()
    while true do
        task.wait(0.3)
        if Config.HitboxEnabled then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    applyHitboxSize(plr)
                end
            end
        end
    end
end)

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'timebomb',
    SubTitle = 'auto play',
    Folder = 'TimebombAutoRotate',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 90, 60),
})

local PlayTab = Window:Tab({ Title = 'auto play', Icon = 'crosshair' })

local Main = PlayTab:Section({ Title = 'main', Side = 'left' })

Main:Toggle({
    Title = 'auto play',
    Flag = 'tb_autoplay',
    Default = false,
    Callback = function(v) Config.AutoPlay = v end,
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

local Movement = PlayTab:Section({ Title = 'movement', Side = 'right' })

Movement:Toggle({
    Title = 'use hug with auto play',
    Flag = 'tb_use_hug',
    Default = true,
    Callback = function(v) Config.UseHug = v end,
})

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
    Max = 20,
    Increment = 0.5,
    Default = 3,
    Suffix = ' studs',
    Callback = function(v) Config.HugDistance = v end,
})

local Targeting = PlayTab:Section({ Title = 'targeting', Side = 'left' })

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

local AutoTP = PlayTab:Section({ Title = 'auto tp', Side = 'right' })

AutoTP:Toggle({
    Title = 'auto tp',
    Flag = 'tb_auto_tp',
    Default = false,
    Callback = function(v) Config.AutoTPEnabled = v end,
})

AutoTP:Slider({
    Title = 'tp when bomb timer at',
    Flag = 'tb_auto_tp_threshold',
    Min = 1,
    Max = 5,
    Increment = 1,
    Default = 3,
    Suffix = 's',
    Callback = function(v) Config.AutoTPThreshold = v end,
})

local Live = PlayTab:Section({ Title = 'live state', Side = 'left' })
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

local HitboxTab = Window:Tab({ Title = 'hitbox', Icon = 'maximize' })
local Hitbox = HitboxTab:Section({ Title = 'hitbox expander', Side = 'left' })

Hitbox:Toggle({
    Title = 'hitbox expander',
    Flag = 'tb_hitbox_enabled',
    Default = false,
    Callback = function(v)
        Config.HitboxEnabled = v
        if not v then restoreAllHitboxSizes() end
    end,
})

Hitbox:Slider({
    Title = 'size multiplier',
    Flag = 'tb_hitbox_multiplier',
    Min = 1,
    Max = 8,
    Increment = 0.5,
    Default = 3,
    Suffix = 'x',
    Callback = function(v) Config.HitboxMultiplier = v end,
})

local HitboxInfo = HitboxTab:Section({ Title = 'behavior', Side = 'right' })
HitboxInfo:Paragraph({
    Title = 'other players only',
    Text = "Enlarges every other player's Torso (the actual collidable part on this R6 rig) so it's easier for the bomb to land a touch, either direction.",
})

Window:Load()

Centrl:Notify({
    Title = 'timebomb',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

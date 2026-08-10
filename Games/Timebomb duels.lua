local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Config = {
    AutoPlay = false,
    AutoRotate = false,
    RotateSpeed = 24,
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

    SpeedEnabled = false,
    WalkSpeed = 16,
    JumpEnabled = false,
    JumpPower = 50,
    InfiniteJump = false,
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

--// Auto rotate / auto play movement -----------------------------------------
-- Two separate toggles sharing one target lock: AutoRotate alone only drives
-- facing (for someone who wants to keep manually walking with WASD but
-- always face whoever they'd hand the bomb to); AutoPlay additionally drives
-- position. Either one disables the Humanoid's own AutoRotate property so
-- Roblox's built-in movement-direction facing doesn't fight our manual
-- CFrame rotation the moment the player presses a movement key.

local lockedTarget = nil
local engaged = false
local originalWalkSpeed = nil
local originalHumanoidAutoRotate = nil
local platformStandOn = false

-- Humanoid's own ground-state logic re-corrects HumanoidRootPart.CFrame's Y
-- every physics step to keep the character grounded, which silently undid
-- the hug nudge's vertical component no matter what we set it to.
-- PlatformStand fully hands position control to us for as long as it's on,
-- so the Y write actually sticks - it's only toggled on for the brief final
-- few studs, not the whole approach.
local function setPlatformStand(humanoid, state)
    if not humanoid or platformStandOn == state then return end
    platformStandOn = state
    humanoid.PlatformStand = state
end

local function disengage(humanoid)
    if not engaged then return end
    engaged = false
    lockedTarget = nil
    if humanoid then
        if originalHumanoidAutoRotate ~= nil then
            humanoid.AutoRotate = originalHumanoidAutoRotate
        end
        if originalWalkSpeed then
            humanoid.WalkSpeed = originalWalkSpeed
        end
        setPlatformStand(humanoid, false)
    end
    originalHumanoidAutoRotate = nil
    originalWalkSpeed = nil
end

local lastMoveTo = 0
local MOVE_TO_INTERVAL = 0.15

-- BombHandle carries a TouchInterest (i.e. the transfer is a real physical
-- Touched collision, not a remote call), so auto play has to do two separate
-- jobs: face the target's *current* position exactly every frame (rotation
-- only, never fights whatever is driving position), and actually close the
-- distance to them (position), snapping the last few studs so the bomb's
-- hitbox genuinely overlaps theirs instead of stopping just short.
RunService.Heartbeat:Connect(function(dt)
    local humanoid = getHumanoid()
    local wantActive = (Config.AutoPlay or Config.AutoRotate)
        and iHaveBomb()
        and not (Config.InArenaCheck and not isInArena())

    if not wantActive or not humanoid then
        disengage(humanoid)
        return
    end

    local myHRP = getHRP()
    if not myHRP then
        disengage(humanoid)
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
        disengage(humanoid)
        return
    end
    lockedTarget = target

    if not engaged then
        engaged = true
        originalHumanoidAutoRotate = humanoid.AutoRotate
    end
    humanoid.AutoRotate = false

    local tHRP = target.Character.HumanoidRootPart
    local toTarget = tHRP.Position - myHRP.Position
    local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
    local dist3D = toTarget.Magnitude

    if flatToTarget.Magnitude > 0.05 then
        local lookCF = CFrame.lookAt(myHRP.Position, myHRP.Position + flatToTarget)
        myHRP.CFrame = myHRP.CFrame:Lerp(lookCF, math.min(Config.RotateSpeed * dt, 1))
    end

    if not Config.AutoPlay then
        -- Rotate-only mode: leave position entirely to the player.
        if originalWalkSpeed then
            humanoid.WalkSpeed = originalWalkSpeed
            originalWalkSpeed = nil
        end
        setPlatformStand(humanoid, false)
        return
    end

    if not originalWalkSpeed then
        originalWalkSpeed = humanoid.WalkSpeed
    end
    humanoid.WalkSpeed = Config.ApproachSpeed

    if Config.UseHug and dist3D <= Config.HugDistance then
        setPlatformStand(humanoid, true)
        local step = math.min(dist3D, Config.ApproachSpeed * dt)
        if toTarget.Magnitude > 0.05 then
            myHRP.CFrame = myHRP.CFrame + toTarget.Unit * step
        end
    else
        setPlatformStand(humanoid, false)
        if os.clock() - lastMoveTo > MOVE_TO_INTERVAL then
            lastMoveTo = os.clock()
            humanoid:MoveTo(tHRP.Position)
        end
    end
end)

--// Auto tp -------------------------------------------------------------------
-- Deliberately outside the AutoPlay/AutoRotate gate above - this is its own
-- feature with its own toggle, and needs to work even with both of those
-- off. Lands just short of the target (matching their height exactly, same
-- as the hug fix) rather than exactly on top of them, then waits for the
-- bomb to actually be gone before returning to where it teleported from, so
-- it never yanks the player back while they're still the one holding it.
local TP_LAND_DISTANCE = 1.5
local TP_RETURN_TIMEOUT = 8

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

local tpInProgress = false

task.spawn(function()
    while true do
        task.wait(0.1)
        if not tpInProgress and Config.AutoTPEnabled and iHaveBomb()
            and not (Config.InArenaCheck and not isInArena()) then
            local timeLeft = getBombTimeLeft()
            if timeLeft and timeLeft <= Config.AutoTPThreshold then
                local myHRP = getHRP()
                local target = myHRP and findBestTarget(myHRP)
                local tHRP = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
                if myHRP and tHRP then
                    tpInProgress = true
                    local originalChar = getChar()
                    local originalCFrame = myHRP.CFrame
                    teleportNear(myHRP, tHRP)

                    task.spawn(function()
                        local deadline = os.clock() + TP_RETURN_TIMEOUT
                        while iHaveBomb() and os.clock() < deadline do
                            task.wait(0.05)
                        end
                        if not iHaveBomb() and getChar() == originalChar then
                            local backHRP = getHRP()
                            if backHRP then
                                backHRP.CFrame = originalCFrame
                            end
                        end
                        tpInProgress = false
                    end)
                end
            end
        end
    end
end)

--// Hitbox expander -----------------------------------------------------------
-- Client-side Size changes never replicate anywhere - not to the server, not
-- to other clients - regardless of which part gets resized. Resizing other
-- players' Torso only ever changed what this client sees; the server's own
-- copy (the one that decides whether a touch actually counts) never moved.
-- BombHandle is network-owned by whoever's holding it, so while we hold the
-- bomb, we ARE the one simulating that part's physics - resizing it here is
-- a change the server actually receives back through the TouchTransmitter,
-- unlike resizing anyone else's anything.
local hitboxBaseSize = nil

local function getMyBombHandle()
    local char = getChar()
    local tool = char and char:FindFirstChildOfClass("Tool")
    return tool and tool:FindFirstChild("BombHandle")
end

local function restoreHitboxSize()
    local handle = getMyBombHandle()
    if handle and hitboxBaseSize then
        handle.Size = hitboxBaseSize
    end
end

task.spawn(function()
    while true do
        task.wait(0.05)
        if Config.HitboxEnabled then
            local handle = getMyBombHandle()
            if handle then
                if not hitboxBaseSize then
                    hitboxBaseSize = handle.Size
                end
                local desired = hitboxBaseSize * Config.HitboxMultiplier
                if (handle.Size - desired).Magnitude > 0.01 then
                    handle.Size = desired
                end
            end
        end
    end
end)

--// Player tab (speed / jump) -------------------------------------------------
-- Yields to the auto-play chase while it's actively driving WalkSpeed, so
-- the two don't fight over the same property every frame.
local function walkSpeedOwnedByChase()
    return engaged and Config.AutoPlay
end

local function setupCharacter(char)
    local humanoid = char:WaitForChild("Humanoid", 5)
    if not humanoid then return end
    humanoid.StateChanged:Connect(function(_, new)
        if Config.InfiniteJump and new == Enum.HumanoidStateType.Landed then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)
end

setupCharacter(getChar() or LocalPlayer.CharacterAdded:Wait())

LocalPlayer.CharacterAdded:Connect(function(char)
    engaged = false
    lockedTarget = nil
    originalWalkSpeed = nil
    originalHumanoidAutoRotate = nil
    platformStandOn = false
    setupCharacter(char)
end)

task.spawn(function()
    while true do
        task.wait(0.1)
        local humanoid = getHumanoid()
        if humanoid and not walkSpeedOwnedByChase() then
            if Config.SpeedEnabled then
                humanoid.WalkSpeed = Config.WalkSpeed
            end
            if Config.JumpEnabled then
                humanoid.JumpPower = Config.JumpPower
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
    Title = 'auto rotate',
    Flag = 'tb_autorotate',
    Default = false,
    Callback = function(v) Config.AutoRotate = v end,
})

Main:Slider({
    Title = 'rotate speed',
    Flag = 'tb_rotate_speed',
    Min = 2,
    Max = 60,
    Increment = 1,
    Default = 24,
    Callback = function(v) Config.RotateSpeed = v end,
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
        if engaged and Config.AutoPlay then
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

AutoTP:Paragraph({
    Title = 'works standalone',
    Text = "Fires off its own toggle and the bomb timer alone - doesn't need auto play or auto rotate on. Teleports back once the bomb is confirmed gone.",
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

local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local PlayerMovement = PlayerTab:Section({ Title = 'movement', Side = 'left' })

PlayerMovement:Toggle({
    Title = 'speed',
    Flag = 'tb_speed_enabled',
    Default = false,
    Callback = function(v) Config.SpeedEnabled = v end,
})

PlayerMovement:Slider({
    Title = 'walkspeed',
    Flag = 'tb_walkspeed',
    Min = 16,
    Max = 200,
    Increment = 1,
    Default = 16,
    Callback = function(v) Config.WalkSpeed = v end,
})

PlayerMovement:Toggle({
    Title = 'jump',
    Flag = 'tb_jump_enabled',
    Default = false,
    Callback = function(v) Config.JumpEnabled = v end,
})

PlayerMovement:Slider({
    Title = 'jump power',
    Flag = 'tb_jumppower',
    Min = 50,
    Max = 300,
    Increment = 5,
    Default = 50,
    Callback = function(v) Config.JumpPower = v end,
})

PlayerMovement:Toggle({
    Title = 'infinite jump',
    Flag = 'tb_infinite_jump',
    Default = false,
    Callback = function(v) Config.InfiniteJump = v end,
})

local HitboxTab = Window:Tab({ Title = 'hitbox', Icon = 'maximize' })
local Hitbox = HitboxTab:Section({ Title = 'hitbox expander', Side = 'left' })

Hitbox:Toggle({
    Title = 'hitbox expander',
    Flag = 'tb_hitbox_enabled',
    Default = false,
    Callback = function(v)
        Config.HitboxEnabled = v
        if not v then restoreHitboxSize() end
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
    Title = 'your bomb only, not their body',
    Text = "Resizing another player's body only ever changes what this client sees - the server's own copy never moves, so it can't affect a real touch. BombHandle is network-owned by whoever's holding it, so enlarging it while you hold the bomb is a change the server actually simulates.",
})

Window:Load()

Centrl:Notify({
    Title = 'timebomb',
    Content = 'Loaded. RightShift toggles the menu.',
    Type = 'success',
    Duration = 5,
})

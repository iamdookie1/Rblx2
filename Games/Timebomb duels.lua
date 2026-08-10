local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Config = {
    Enabled = false,
    RotateSpeed = 8,
    Prediction = true,
    InArenaCheck = true,
    RotateCamera = false,
    MaxDistance = 0,

    HorizontalOnly = true,
    PingCompensation = true,
    LeadForApproach = true,
    AssumedApproachSpeed = 20,
    MaxLeadTime = 1.5,

    PreferApproaching = true,
    ApproachBias = 1.5,

    StickyTarget = true,
    StickyThreshold = 8,

    SnapWhenClose = true,
    SnapDistance = 12,
}

local Camera = workspace.CurrentCamera
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = workspace.CurrentCamera
end)

local function getChar()
    return LocalPlayer.Character
end

local function getHRP()
    local char = getChar()
    return char and char:FindFirstChild("HumanoidRootPart")
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

local function iTeammate(plr)
    local myData = getData(LocalPlayer)
    local theirData = getData(plr)
    if not myData or not theirData then return true end

    local myArena = myData:FindFirstChild("ActiveArena")
    local theirArena = theirData:FindFirstChild("ActiveArena")
    if not myArena or not theirArena then return true end

    if myArena.Value == nil then return true end
    if theirArena.Value ~= myArena.Value then return true end

    local mySlot = myData:FindFirstChild("Slot")
    local theirSlot = theirData:FindFirstChild("Slot")
    if not mySlot or not theirSlot then return true end

    if mySlot.Value == nil or theirSlot.Value == nil then
        return false
    end

    return mySlot.Value == theirSlot.Value
end

local function isAlive(plr)
    local data = getData(plr)
    if not data then return false end
    local aliveAttr = data:GetAttribute("Alive")
    if aliveAttr == true then return true end
    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 then return true end
    return false
end

local function isInArena()
    local data = getData(LocalPlayer)
    if not data then return false end
    local activeArena = data:FindFirstChild("ActiveArena")
    return activeArena ~= nil and activeArena.Value ~= nil
end

local function iHaveBomb()
    return hasBomb(getChar())
end

local velocityHistory = {}
local HISTORY_SIZE = 6

local function updateVelocityHistory(plr, hrp)
    local hist = velocityHistory[plr]
    if not hist then
        hist = { samples = {}, index = 0 }
        velocityHistory[plr] = hist
    end
    hist.index = (hist.index % HISTORY_SIZE) + 1
    hist.samples[hist.index] = hrp.AssemblyLinearVelocity
    return hist
end

local function getSmoothedVelocity(plr, hrp)
    local hist = updateVelocityHistory(plr, hrp)
    local sum = Vector3.new(0, 0, 0)
    local count = 0
    for _, v in pairs(hist.samples) do
        sum = sum + v
        count = count + 1
    end
    if count == 0 then return hrp.AssemblyLinearVelocity end
    return sum / count
end

local function getPing()
    local ok, ping = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and ping then return ping end
    return 0.05
end

local function getTargetPosition(plr)
    local char = plr.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    if not Config.Prediction then
        return hrp.Position
    end

    local myHRP = getHRP()
    if not myHRP then return hrp.Position end

    local vel = getSmoothedVelocity(plr, hrp)

    if Config.HorizontalOnly then
        vel = Vector3.new(vel.X, 0, vel.Z)
    end

    local dist = (hrp.Position - myHRP.Position).Magnitude

    local rotationTime = 1 / math.max(Config.RotateSpeed, 0.1)
    local pingTime = Config.PingCompensation and getPing() or 0
    local closingTime = dist / math.max(Config.AssumedApproachSpeed, 1)

    local leadTime = rotationTime + pingTime
    if Config.LeadForApproach then
        leadTime = leadTime + closingTime
    end

    leadTime = math.min(leadTime, Config.MaxLeadTime)

    return hrp.Position + vel * leadTime
end

local function findBestTarget()
    local myHRP = getHRP()
    if not myHRP then return nil end
    local best, bestScore = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                if isAlive(plr) and not iTeammate(plr) and not hasBomb(char) then
                    local dist = (hrp.Position - myHRP.Position).Magnitude
                    local tooFar = Config.MaxDistance > 0 and dist > Config.MaxDistance
                    if not tooFar then
                        local score = dist
                        if Config.PreferApproaching then
                            local vel = getSmoothedVelocity(plr, hrp)
                            local toMe = (myHRP.Position - hrp.Position)
                            if toMe.Magnitude > 0.01 then
                                local closingSpeed = vel:Dot(toMe.Unit)
                                score = dist - (closingSpeed * Config.ApproachBias)
                            end
                        end
                        if score < bestScore then
                            best, bestScore = plr, score
                        end
                    end
                end
            end
        end
    end
    return best
end

local lockedTarget = nil

RunService.Heartbeat:Connect(function(dt)
    if not Config.Enabled then
        lockedTarget = nil
        return
    end
    if Config.InArenaCheck and not isInArena() then return end
    if not iHaveBomb() then
        lockedTarget = nil
        return
    end

    local myHRP = getHRP()
    if not myHRP then return end

    local target = findBestTarget()

    if Config.StickyTarget and lockedTarget then
        local lc = lockedTarget.Character
        local lh = lc and lc:FindFirstChild("HumanoidRootPart")
        local lhum = lc and lc:FindFirstChildOfClass("Humanoid")
        local stillValid = lh and lhum and lhum.Health > 0
            and isAlive(lockedTarget) and not iTeammate(lockedTarget)
            and not hasBomb(lc)

        if stillValid then
            local lockedDist = (lh.Position - myHRP.Position).Magnitude
            if Config.MaxDistance > 0 and lockedDist > Config.MaxDistance then
                stillValid = false
            end
        end

        if not stillValid then
            lockedTarget = nil
        elseif target and target ~= lockedTarget then
            local lockedDist = (lh.Position - myHRP.Position).Magnitude
            local newChar = target.Character
            local newHRP = newChar and newChar:FindFirstChild("HumanoidRootPart")
            if newHRP then
                local newDist = (newHRP.Position - myHRP.Position).Magnitude
                if lockedDist - newDist < Config.StickyThreshold then
                    target = lockedTarget
                end
            end
        elseif not target then
            target = lockedTarget
        end
    end

    if not target then
        lockedTarget = nil
        return
    end
    lockedTarget = target

    local targetPos = getTargetPosition(target)
    if not targetPos then return end

    local tChar = target.Character
    local tHRP = tChar and tChar:FindFirstChild("HumanoidRootPart")
    local rawDist = tHRP and (tHRP.Position - myHRP.Position).Magnitude or math.huge

    local alpha = math.min(Config.RotateSpeed * dt, 1)
    if Config.SnapWhenClose and rawDist <= Config.SnapDistance then
        alpha = 1
        if tHRP then
            targetPos = tHRP.Position
        end
    end

    local flatTarget = Vector3.new(targetPos.X, myHRP.Position.Y, targetPos.Z)

    if Config.RotateCamera then
        local camCF = Camera.CFrame
        local camPos = camCF.Position
        local toTarget = (Vector3.new(targetPos.X, camPos.Y, targetPos.Z) - camPos)
        if toTarget.Magnitude > 0.01 then
            local currentLook = camCF.LookVector
            local newLook = currentLook:Lerp(toTarget.Unit, alpha)
            if newLook.Magnitude > 0.01 then
                Camera.CFrame = CFrame.lookAt(camPos, camPos + newLook.Unit, Vector3.new(0, 1, 0))
            end
        end
    else
        local targetCF = CFrame.lookAt(myHRP.Position, flatTarget)
        myHRP.CFrame = myHRP.CFrame:Lerp(targetCF, alpha)
    end
end)

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local Window = Rayfield:CreateWindow({
    name = "Timebomb Auto Rotate",
    subtitle = "Rotate toward enemies when holding bomb",
    theme = "cobalt",
    configuration = {
        autoSave = true,
        autoLoad = true,
        fileName = "TimebombAutoRotate",
    },
})

local tab = Window:CreateTab({ name = "Rotate", icon = 93364949241311 })

tab:CreateSection({ name = "Main" })
tab:CreateToggle({
    name = "Auto Rotate",
    flag = "Enabled",
    value = false,
    callback = function(v) Config.Enabled = v end,
})
tab:CreateToggle({
    name = "In Arena Check",
    flag = "InArenaCheck",
    value = true,
    callback = function(v) Config.InArenaCheck = v end,
})
tab:CreateToggle({
    name = "Rotate Camera (instead of character)",
    flag = "RotateCamera",
    value = false,
    callback = function(v) Config.RotateCamera = v end,
})

tab:CreateSection({ name = "Rotation" })
tab:CreateSlider({
    name = "Rotate Speed",
    range = { 1, 20 },
    increment = 0.5,
    value = 8,
    flag = "RotateSpeed",
    callback = function(v) Config.RotateSpeed = v end,
})

tab:CreateSection({ name = "Target" })
tab:CreateSlider({
    name = "Max Distance (0 = no limit)",
    range = { 0, 50 },
    increment = 1,
    value = 0,
    suffix = " studs",
    flag = "MaxDistance",
    callback = function(v) Config.MaxDistance = v end,
})

tab:CreateSection({ name = "Prediction (auto)" })
tab:CreateToggle({
    name = "Prediction",
    flag = "Prediction",
    value = true,
    callback = function(v) Config.Prediction = v end,
})
tab:CreateToggle({
    name = "Horizontal Only (ignore jump velocity)",
    flag = "HorizontalOnly",
    value = true,
    callback = function(v) Config.HorizontalOnly = v end,
})
tab:CreateToggle({
    name = "Ping Compensation",
    flag = "PingCompensation",
    value = true,
    callback = function(v) Config.PingCompensation = v end,
})
tab:CreateToggle({
    name = "Lead For Approach Time",
    flag = "LeadForApproach",
    value = true,
    callback = function(v) Config.LeadForApproach = v end,
})
tab:CreateSlider({
    name = "Assumed Approach Speed",
    range = { 5, 60 },
    increment = 1,
    value = 20,
    suffix = " studs/s",
    flag = "AssumedApproachSpeed",
    callback = function(v) Config.AssumedApproachSpeed = v end,
})
tab:CreateSlider({
    name = "Max Lead Time (cap)",
    range = { 0.1, 3 },
    increment = 0.1,
    value = 1.5,
    suffix = "s",
    flag = "MaxLeadTime",
    callback = function(v) Config.MaxLeadTime = v end,
})

tab:CreateSection({ name = "Target Selection" })
tab:CreateToggle({
    name = "Prefer Approaching Enemies",
    flag = "PreferApproaching",
    value = true,
    callback = function(v) Config.PreferApproaching = v end,
})
tab:CreateSlider({
    name = "Approach Bias",
    range = { 0, 5 },
    increment = 0.25,
    value = 1.5,
    flag = "ApproachBias",
    callback = function(v) Config.ApproachBias = v end,
})
tab:CreateToggle({
    name = "Sticky Target",
    flag = "StickyTarget",
    value = true,
    callback = function(v) Config.StickyTarget = v end,
})
tab:CreateSlider({
    name = "Sticky Threshold",
    range = { 0, 30 },
    increment = 1,
    value = 8,
    suffix = " studs",
    flag = "StickyThreshold",
    callback = function(v) Config.StickyThreshold = v end,
})

tab:CreateSection({ name = "Close Range" })
tab:CreateToggle({
    name = "Snap When Close",
    flag = "SnapWhenClose",
    value = true,
    callback = function(v) Config.SnapWhenClose = v end,
})
tab:CreateSlider({
    name = "Snap Distance",
    range = { 0, 30 },
    increment = 1,
    value = 12,
    suffix = " studs",
    flag = "SnapDistance",
    callback = function(v) Config.SnapDistance = v end,
})

tab:CreateSection({ name = "Live State" })
local statHasBomb = tab:CreateStat({ name = "Has Bomb", value = 0 })
local statInArena = tab:CreateStat({ name = "In Arena", value = 0 })
local statTarget  = tab:CreateStat({ name = "Target Dist", value = 0 })

task.spawn(function()
    while true do
        task.wait(0.2)
        statHasBomb:Set(iHaveBomb() and 1 or 0)
        statInArena:Set(isInArena() and 1 or 0)

        if Config.Enabled and iHaveBomb() then
            local t = findBestTarget()
            local myHRP = getHRP()
            if t and t.Character and t.Character:FindFirstChild("HumanoidRootPart") and myHRP then
                local d = (t.Character.HumanoidRootPart.Position - myHRP.Position).Magnitude
                statTarget:Set(math.floor(d))
            else
                statTarget:Set(0)
            end
        else
            statTarget:Set(0)
        end
    end
end)

Window:Toast({
    title = "Loaded",
    content = "Auto-rotates toward nearest enemy when you hold the bomb.",
    duration = 4,
})

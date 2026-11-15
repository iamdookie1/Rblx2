local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Stats = game:GetService("Stats")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__CustomMM2Unload then
    pcall(Genv.__CustomMM2Unload)
end

local Unloaded = false
local Connections = {}
local function track(c)
    table.insert(Connections, c)
    return c
end

local LumeUI = loadstring(game:HttpGet("https://github.com/SSHRKs/LumeUI/releases/latest/download/main.lua"))()

local Settings = {
    GunAim = false,
    KnifeAim = false,
    Esp = false,
    AntiFling = false,
}

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local Gameplay = Remotes and Remotes:WaitForChild("Gameplay", 10)
local GetCurrentPlayerData = Gameplay and Gameplay:FindFirstChild("GetCurrentPlayerData")
local PlayerDataChanged = Gameplay and Gameplay:FindFirstChild("PlayerDataChanged")

local RoundData = {}
local function refreshRound()
    if not GetCurrentPlayerData then
        return
    end
    local ok, data = pcall(GetCurrentPlayerData.InvokeServer, GetCurrentPlayerData)
    if ok and type(data) == "table" then
        RoundData = data
    end
end
task.spawn(refreshRound)
if PlayerDataChanged then
    track(PlayerDataChanged.OnClientEvent:Connect(function(data)
        if type(data) == "table" then
            RoundData = data
        end
    end))
end
task.spawn(function()
    while not Unloaded do
        task.wait(3)
        refreshRound()
    end
end)

local function isGun(item)
    if not item:IsA("Tool") then
        return false
    end
    local tagged = false
    pcall(function()
        tagged = CollectionService:HasTag(item, "Weapon_Gun")
    end)
    return item.Name == "Gun" or tagged or item:FindFirstChild("IsGun") ~= nil
end

local function isKnife(item)
    return item:IsA("Tool") and (item.Name == "Knife" or item:FindFirstChild("KnifeClient") ~= nil)
end

local function carried(plr)
    local found
    for _, holder in { plr.Character, plr:FindFirstChildOfClass("Backpack") } do
        if holder then
            for _, item in holder:GetChildren() do
                if isKnife(item) then
                    return "Knife"
                elseif isGun(item) then
                    found = "Gun"
                end
            end
        end
    end
    return found
end

local function roleOf(plr)
    local entry = RoundData[plr.Name]
    local role = type(entry) == "table" and entry.Role or nil
    local dead = type(entry) == "table" and (entry.Dead == true or entry.Killed == true)
    local held = carried(plr)
    if held == "Knife" then
        role = "Murderer"
    elseif held == "Gun" and role ~= "Sheriff" then
        role = role == "Murderer" and role or "Hero"
    end
    return role, dead
end

local function aliveRoot(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 then
        return root, hum, char
    end
    return nil
end

local function ignoreList(extra)
    local list = { LocalPlayer.Character }
    if extra then
        table.insert(list, extra)
    end
    for _, inst in CollectionService:GetTagged("WeaponPassthrough") do
        table.insert(list, inst)
    end
    return list
end

local function clearLine(from, to, targetChar)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local list = ignoreList(targetChar)
    params.FilterDescendantsInstances = list
    local dir = to - from
    for _ = 1, 8 do
        local hit = Workspace:Raycast(from, dir, params)
        if not hit then
            return true
        end
        if hit.Instance.Transparency < 1 then
            return false
        end
        table.insert(list, hit.Instance)
        params.FilterDescendantsInstances = list
    end
    return false
end

local lastTap, lastTapAt = nil, 0
track(UserInputService.TouchTapInWorld:Connect(function(pos, processed)
    if not processed then
        lastTap, lastTapAt = pos, os.clock()
    end
end))

local function mouseLocked()
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    local ml = ps and ps:FindFirstChild("MouseLock")
    return ml and ml:GetAttribute("Enabled") == true
end

local function aimPoint()
    local cam = Workspace.CurrentCamera
    local vp = cam.ViewportSize
    if UserInputService.TouchEnabled and lastTap and os.clock() - lastTapAt < 0.35 then
        return Vector2.new(lastTap.X, lastTap.Y)
    end
    if mouseLocked() or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return vp / 2
    end
    if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
        return vp / 2
    end
    return UserInputService:GetMouseLocation()
end

local Predict = {
    WINDOW = 2.0,
    SPAN = 0.034,
    GRAVITY = 196.2,
    INTERP = 0.06,
    PROCESS = 0.01,
    FUTURES = 64,
    STEP = 1 / 30,
    MOVING = 4,
    TURN = 0.7,
    PRIOR_DURATION = 1.5,
    PRIOR_WEIGHT = 1.5,
    GUN_RADIUS = 1.0,
    KNIFE_RADIUS = 1.2,
    ACCEL_LEAD = 0.05,
    TURN_LAG = 0.035,
    ACCEL_TAU = 0.05,
    TRUST_AT = 3,
    TRUST = 0.9,
    JITTER = 0.2,
    GUN_HOLD = 0.2,
    GUN_SURE = 0.85,
    KNIFE_HOLD = 0,
    KNIFE_SURE = 0.7,
    GUN_RAISE = 1.0,
    KNIFE_RAISE = 1.5,
    OFFSET_MIN = -0.04,
    OFFSET_MAX = 0.4,
    OFFSET_STEP = 0.005,
    OFFSET_PRIOR = 0.07,
    OFFSET_SPREAD = 0.08,
    LEARN_AFTER = 2,
}

function Predict.new()
    return { list = {}, groundY = nil, grounded = true }
end

function Predict.push(rec, now, pos, grounded)
    local list = rec.list
    local n = #list
    if n > 0 and now <= list[n].t then
        return
    end
    list[n + 1] = { t = now, p = pos }
    n += 1
    if grounded then
        rec.groundY = pos.Y
    end
    rec.grounded = grounded
    local cut = now - Predict.WINDOW - 0.2
    local drop = 0
    while drop < n - 2 and list[drop + 1].t < cut do
        drop += 1
    end
    if drop > 0 then
        table.move(list, drop + 1, n, 1)
        for i = n - drop + 1, n do
            list[i] = nil
        end
    end
end

function Predict.at(rec, t)
    local list = rec.list
    local n = #list
    if t >= list[n].t then
        return list[n].p
    end
    if t <= list[1].t then
        return list[1].p
    end
    local lo, hi = 1, n
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if list[mid].t <= t then
            lo = mid
        else
            hi = mid
        end
    end
    local a, b = list[lo], list[hi]
    return a.p + (b.p - a.p) * ((t - a.t) / math.max(b.t - a.t, 1e-6))
end

function Predict.velocity(rec, t, span)
    return (Predict.at(rec, t) - Predict.at(rec, t - span)) / span
end

local function wrap(a)
    a = (a + math.pi) % (2 * math.pi)
    return a - math.pi
end

function Predict.turns(rec)
    local list = rec.list
    local now = list[#list].t
    local first = math.max(list[1].t + Predict.SPAN, now - Predict.WINDOW)
    local events = {}
    local ref, refX, refZ
    local since = {}
    local t = first
    while t <= now + 1e-6 do
        local v = Predict.velocity(rec, t, Predict.SPAN)
        local moving = v.X * v.X + v.Z * v.Z > Predict.MOVING * Predict.MOVING
        if ref then
            table.insert(since, { t = t, x = v.X, z = v.Z })
        end
        if moving then
            local h = math.atan2(v.Z, v.X)
            if not ref then
                ref = h
                refX, refZ = math.cos(h), math.sin(h)
            else
                local d = wrap(h - ref)
                if math.abs(d) > Predict.TURN then
                    local half = math.abs(d) / 2
                    local at = t
                    for _, smp in since do
                        local proj = smp.x * refX + smp.z * refZ
                        local perp = math.abs(smp.x * refZ - smp.z * refX)
                        if math.atan2(perp, proj) >= half then
                            at = smp.t
                            break
                        end
                    end
                    table.insert(events, { t = at - Predict.TURN_LAG - Predict.SPAN / 2, a = d })
                    ref = h
                    refX, refZ = math.cos(h), math.sin(h)
                    since = {}
                end
            end
        end
        t += 1 / 60
    end
    local durations = {}
    for i = 2, #events do
        table.insert(durations, events[i].t - events[i - 1].t)
    end
    local elapsed = #events > 0 and now - events[#events].t or now - first
    return events, durations, elapsed, ref
end

local function trust(k)
    if k >= Predict.TRUST_AT then
        return Predict.TRUST
    end
    return k / (k + Predict.PRIOR_WEIGHT)
end

local function drawDuration(durations)
    local k = #durations
    if k > 0 and math.random() < trust(k) then
        local g = math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
        return durations[math.random(1, k)] * math.exp(Predict.JITTER * g)
    end
    return 0.25 - Predict.PRIOR_DURATION * math.log(1 - math.random())
end

local function drawAngle(events)
    local k = #events
    if k > 0 and math.random() < trust(k) then
        local a = events[math.random(1, k)].a
        return math.random() < 0.5 and a or -a
    end
    return (math.random() * 2 - 1) * math.pi
end

local function residual(durations, elapsed)
    for _ = 1, 24 do
        local d = drawDuration(durations)
        if d > elapsed then
            return d - elapsed
        end
    end
    return -Predict.PRIOR_DURATION * math.log(1 - math.random()) * 0.5
end

local function modePoint(points, radius)
    local r2 = radius * radius
    local best, bestCount = 1, -1
    for i, a in points do
        local c = 0
        for _, b in points do
            local dx, dz = a[1] - b[1], a[2] - b[2]
            if dx * dx + dz * dz <= r2 then
                c += 1
            end
        end
        if c > bestCount then
            best, bestCount = i, c
        end
    end
    local a = points[best]
    local sx, sz, n = 0, 0, 0
    for _, b in points do
        local dx, dz = a[1] - b[1], a[2] - b[2]
        if dx * dx + dz * dz <= r2 then
            sx += b[1]
            sz += b[2]
            n += 1
        end
    end
    return sx / n, sz / n, bestCount / #points
end

local function modeAngle(points, origin, radius)
    local n = #points
    local ang, half, dist = {}, {}, {}
    for i, p in points do
        local dx, dz = p[1] - origin.X, p[2] - origin.Z
        local d = math.max(math.sqrt(dx * dx + dz * dz), radius * 1.01)
        ang[i] = math.atan2(dz, dx)
        half[i] = math.asin(radius / d)
        dist[i] = d
    end
    local bestA, bestCount = ang[1], -1
    for i = 1, n do
        local c = 0
        local a = ang[i]
        for j = 1, n do
            if math.abs(wrap(a - ang[j])) <= half[j] then
                c += 1
            end
        end
        if c > bestCount then
            bestA, bestCount = a, c
        end
    end
    local lo, hi = -math.huge, math.huge
    local sd, m = 0, 0
    for j = 1, n do
        local off = wrap(ang[j] - bestA)
        if math.abs(off) <= half[j] then
            lo = math.max(lo, off - half[j])
            hi = math.min(hi, off + half[j])
            sd += dist[j]
            m += 1
        end
    end
    local center = bestA
    if lo <= hi then
        center = bestA + (lo + hi) / 2
    end
    local d = sd / math.max(m, 1)
    return origin.X + math.cos(center) * d, origin.Z + math.sin(center) * d, bestCount / n
end

function Predict.aim(rec, origin, speed, net)
    local list = rec.list
    local n = #list
    if n == 0 then
        return nil
    end
    local now = list[n].t
    local p0 = list[n].p
    local v = Predict.velocity(rec, now, Predict.SPAN)
    local vy = Predict.velocity(rec, now, 0.035).Y
    local airborne = math.abs(vy) > 6 or (not rec.grounded and rec.groundY ~= nil and p0.Y > rec.groundY + 0.5)
    local g = Predict.GRAVITY
    local floor = rec.groundY
    local raise = speed and Predict.KNIFE_RAISE or Predict.GUN_RAISE
    local function height(T)
        if not airborne then
            return p0.Y + raise
        end
        local y = p0.Y + vy * T - 0.5 * g * T * T
        if floor and y < floor then
            y = floor
        end
        return y + raise * 0.5
    end
    local base = net + Predict.INTERP + Predict.PROCESS
    local flatSpeed = math.sqrt(v.X * v.X + v.Z * v.Z)
    local heading0 = math.atan2(v.Z, v.X)
    local cruise, lastMoving = flatSpeed, nil
    do
        local t = now
        while t > now - 0.6 and t > list[1].t + Predict.SPAN do
            local u = Predict.velocity(rec, t, Predict.SPAN)
            local s2 = math.sqrt(u.X * u.X + u.Z * u.Z)
            if s2 > cruise then
                cruise = s2
            end
            if not lastMoving and s2 > Predict.MOVING then
                lastMoving = { t = t, h = math.atan2(u.Z, u.X) }
            end
            t -= 1 / 30
        end
    end
    local turning
    do
        local vPrev = Predict.velocity(rec, now - Predict.SPAN, Predict.SPAN)
        local ax, az = (v.X - vPrev.X) / Predict.SPAN, (v.Z - vPrev.Z) / Predict.SPAN
        local lead = Predict.ACCEL_LEAD
        local wx, wz = v.X + ax * lead, v.Z + az * lead
        local wm = math.sqrt(wx * wx + wz * wz)
        if wm > Predict.MOVING and math.sqrt(ax * ax + az * az) > 40 then
            local h = math.atan2(wz, wx)
            local d = flatSpeed > 1 and math.abs(wrap(h - heading0)) or math.pi
            heading0 = h
            flatSpeed = math.max(flatSpeed, math.min(wm, cruise))
            if d > Predict.TURN then
                turning = d
            end
        end
    end
    local stopped = flatSpeed < Predict.MOVING and (not lastMoving or now - lastMoving.t > 0.25)
    if flatSpeed < Predict.MOVING and not stopped then
        heading0 = lastMoving.h + math.pi
        flatSpeed = cruise
    elseif flatSpeed < cruise * 0.85 and flatSpeed >= Predict.MOVING then
        flatSpeed = math.max(flatSpeed, cruise * 0.9)
    end
    if n < 4 or stopped then
        local T = base
        if speed then
            T = base + (p0 - origin).Magnitude / speed
        end
        return Vector3.new(p0.X + v.X * T, height(T), p0.Z + v.Z * T), T, 1
    end
    local events, durations, elapsed, ref = Predict.turns(rec)
    if (turning or (flatSpeed >= Predict.MOVING and ref and math.abs(wrap(heading0 - ref)) > Predict.TURN)) and elapsed > Predict.TURN_LAG + Predict.SPAN then
        local d = turning or wrap(heading0 - ref)
        if #events > 0 then
            table.insert(durations, (now - Predict.TURN_LAG - Predict.SPAN / 2) - events[#events].t)
        end
        table.insert(events, { t = now - Predict.TURN_LAG - Predict.SPAN / 2, a = d })
        elapsed = Predict.TURN_LAG + Predict.SPAN / 2
    end
    local step = Predict.STEP
    local horizon = speed and base + 1.6 or base + step
    local points = {}
    local times = {}
    local tau = Predict.ACCEL_TAU
    for f = 1, Predict.FUTURES do
        local x, z = p0.X, p0.Z
        local vx, vz = v.X, v.Z
        local heading = heading0
        local nextTurn = residual(durations, elapsed)
        local t = 0
        local hit
        local function advance(span)
            local dx, dz = math.cos(heading) * flatSpeed, math.sin(heading) * flatSpeed
            local e = math.exp(-span / tau)
            local k = tau * (1 - e)
            x += dx * span + (vx - dx) * k
            z += dz * span + (vz - dz) * k
            vx = dx + (vx - dx) * e
            vz = dz + (vz - dz) * e
        end
        while t < horizon do
            local dt = math.min(step, horizon - t)
            if not speed and t + dt > base then
                dt = base - t
            end
            local left = dt
            while nextTurn < left do
                advance(nextTurn)
                left -= nextTurn
                heading += drawAngle(events)
                nextTurn = drawDuration(durations)
            end
            advance(left)
            nextTurn -= left
            t += dt
            if speed then
                if t >= base then
                    local dx, dz = x - origin.X, z - origin.Z
                    if math.sqrt(dx * dx + dz * dz) <= speed * (t - base) then
                        hit = { x, z }
                        times[f] = t
                        break
                    end
                end
            elseif t >= base - 1e-9 then
                hit = { x, z }
                times[f] = t
                break
            end
        end
        points[f] = hit or { x, z }
        times[f] = times[f] or t
    end
    local ax, az, confidence
    if speed then
        ax, az, confidence = modeAngle(points, origin, Predict.KNIFE_RADIUS)
    else
        ax, az, confidence = modePoint(points, Predict.GUN_RADIUS)
    end
    local T = base
    if speed then
        local sum, c = 0, 0
        for f = 1, #points do
            local dx, dz = points[f][1] - ax, points[f][2] - az
            if dx * dx + dz * dz <= Predict.KNIFE_RADIUS ^ 2 then
                sum += times[f]
                c += 1
            end
        end
        T = c > 0 and sum / c or base
    end
    return Vector3.new(ax, height(T), az), T, confidence
end

function Predict.ready(knife, confidence, waited)
    if knife then
        return confidence >= Predict.KNIFE_SURE or waited >= Predict.KNIFE_HOLD
    end
    return confidence >= Predict.GUN_SURE or waited >= Predict.GUN_HOLD
end

function Predict.newCalibration()
    local cal = { score = {}, shots = 0 }
    local i = 0
    local o = Predict.OFFSET_MIN
    while o <= Predict.OFFSET_MAX + 1e-9 do
        i += 1
        local z = (o - Predict.OFFSET_PRIOR) / Predict.OFFSET_SPREAD
        cal.score[i] = -0.5 * z * z
        o += Predict.OFFSET_STEP
    end
    return cal
end

function Predict.observeThrow(cal, rec, firedAt, rtt, origin, toward, speed, hit)
    local list = rec.list
    if #list < 2 then
        return false
    end
    local last = list[#list].t
    local dir = toward - origin
    local fx, fz = dir.X, dir.Z
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 0.5 then
        return false
    end
    fx, fz = fx / len, fz / len
    local reach = Predict.KNIFE_RADIUS + 0.2
    local likes = {}
    local i = 0
    local o = Predict.OFFSET_MIN
    while o <= Predict.OFFSET_MAX + 1e-9 do
        i += 1
        local would = false
        local covered = false
        local f = 0
        while f <= 1.2 do
            local c = firedAt + rtt + o + f
            if c > last then
                break
            end
            covered = true
            local p = Predict.at(rec, c)
            local kx, kz = origin.X + fx * speed * f, origin.Z + fz * speed * f
            local dx, dz = p.X - kx, p.Z - kz
            if dx * dx + dz * dz <= reach * reach then
                would = true
                break
            end
            f += 1 / 60
        end
        if not covered then
            likes[i] = 0.5
        elseif hit then
            likes[i] = would and 0.9 or 0.15
        else
            likes[i] = would and 0.2 or 0.85
        end
        o += Predict.OFFSET_STEP
    end
    local lo, hi = math.huge, -math.huge
    for _, l in likes do
        lo = math.min(lo, l)
        hi = math.max(hi, l)
    end
    if hi - lo < 0.3 then
        return false
    end
    for k, l in likes do
        cal.score[k] += math.log(l)
    end
    cal.shots += 1
    return true
end

function Predict.observeShot(cal, rec, firedAt, rtt, origin, finish, hit)
    local list = rec.list
    if #list < 2 then
        return false
    end
    local last = list[#list].t
    local dir = finish - origin
    local fx, fz = dir.X, dir.Z
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 0.5 then
        return false
    end
    fx, fz = fx / len, fz / len
    local informative = false
    local likes = {}
    local i = 0
    local o = Predict.OFFSET_MIN
    while o <= Predict.OFFSET_MAX + 1e-9 do
        i += 1
        local c = firedAt + rtt + o
        local p = Predict.at(rec, c)
        local like
        if c > last then
            like = 0.5
        elseif hit then
            local dx, dz = p.X - finish.X, p.Z - finish.Z
            local d = math.sqrt(dx * dx + dz * dz)
            local over = math.max(0, d - 1.3)
            like = 0.08 + 0.92 * math.exp(-over * over / 0.32)
        else
            local rx, rz = p.X - origin.X, p.Z - origin.Z
            local along = rx * fx + rz * fz
            local across = math.abs(rx * fz - rz * fx)
            if along > 0 and along < len + 2 and across < 1.0 then
                like = 0.25
            else
                like = 0.85
            end
        end
        likes[i] = like
        o += Predict.OFFSET_STEP
    end
    local lo, hi = math.huge, -math.huge
    for _, l in likes do
        lo = math.min(lo, l)
        hi = math.max(hi, l)
    end
    informative = hi - lo > 0.3
    if not informative then
        return false
    end
    for k, l in likes do
        cal.score[k] += math.log(l)
    end
    cal.shots += 1
    return true
end

function Predict.offset(cal)
    if cal.shots < Predict.LEARN_AFTER then
        return nil
    end
    local best, bestScore = 1, -math.huge
    for k, v in cal.score do
        if v > bestScore then
            best, bestScore = k, v
        end
    end
    return Predict.OFFSET_MIN + (best - 1) * Predict.OFFSET_STEP
end

local KNIFE_SPEED = 96
track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(function(k)
    local s = k:GetAttribute("ThrowSpeed")
    if type(s) == "number" and s > 0 then
        KNIFE_SPEED = s
    end
end))

local RTT = 0.12
local function readPing()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" and v > 0 then
        return v / 1000
    end
    local ok2, p = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    if ok2 and type(p) == "number" and p > 0 then
        return p * 2
    end
    return nil
end
task.spawn(function()
    while not Unloaded do
        local p = readPing()
        if p then
            RTT += (math.clamp(p, 0, 0.6) - RTT) * 0.35
        end
        Predict.GRAVITY = Workspace.Gravity
        task.wait(0.5)
    end
end)

local Raycast = Workspace.Raycast
local WorldParams = RaycastParams.new()
WorldParams.FilterType = Enum.RaycastFilterType.Exclude
local function refreshWorldParams()
    local list = {}
    for _, plr in Players:GetPlayers() do
        if plr.Character then
            table.insert(list, plr.Character)
        end
    end
    for _, inst in CollectionService:GetTagged("WeaponPassthrough") do
        table.insert(list, inst)
    end
    WorldParams.FilterDescendantsInstances = list
end
refreshWorldParams()

local Records = {}
local Weapon = { kind = nil, tool = nil, remote = nil, attachment = nil }
local Target
local Candidates = {}
local Pending
local LastShot

local CAL_VERSION = 2
local Cal = Genv.__MM2Cal
if type(Cal) ~= "table" or Genv.__MM2CalJob ~= game.JobId or Genv.__MM2CalVersion ~= CAL_VERSION then
    Cal = Predict.newCalibration()
    Genv.__MM2Cal, Genv.__MM2CalJob, Genv.__MM2CalVersion = Cal, game.JobId, CAL_VERSION
end
local function applyCalibration()
    local o = Predict.offset(Cal)
    if o then
        Predict.INTERP = math.clamp(o - Predict.PROCESS, 0, 0.35)
    end
end
applyCalibration()

local function enabledFor(kind)
    return (kind == "Gun" and Settings.GunAim) or (kind == "Knife" and Settings.KnifeAim)
end

local function refreshWeapon()
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if tool == Weapon.tool and (not tool or Weapon.remote and Weapon.remote.Parent) then
        return
    end
    Weapon.tool, Weapon.kind, Weapon.remote = tool, nil, nil
    if tool then
        if isKnife(tool) then
            local events = tool:FindFirstChild("Events")
            Weapon.kind = "Knife"
            Weapon.remote = events and events:FindFirstChild("KnifeThrown")
        elseif isGun(tool) then
            Weapon.kind = "Gun"
            Weapon.remote = tool:FindFirstChild("Shoot")
        end
    end
    local root = char and char:FindFirstChild("HumanoidRootPart")
    Weapon.attachment = root and root:FindFirstChild("GunRaycastAttachment")
end

local function visible(eye, char)
    for _, name in { "HumanoidRootPart", "Head", "UpperTorso", "Torso" } do
        local part = char:FindFirstChild(name)
        if part then
            local hit = Raycast(Workspace, eye, part.Position - eye, WorldParams)
            if not hit then
                return true
            end
            if hit.Instance.Transparency >= 1 and clearLine(eye, part.Position, char) then
                return true
            end
        end
    end
    return false
end

local function chooseTarget(kind)
    table.clear(Candidates)
    local me = aliveRoot(LocalPlayer)
    if not me then
        return nil
    end
    local cam = Workspace.CurrentCamera
    local center = aimPoint()
    local fov = math.max(cam.ViewportSize.Y * 0.45, 220)
    local head = LocalPlayer.Character:FindFirstChild("Head")
    local eye = head and head.Position or me.Position
    local murdererKnown, murderer, best, bestScore = false, nil, nil, nil
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local root, _, char = aliveRoot(plr)
            local role, dead = roleOf(plr)
            if root and not dead then
                if role == "Murderer" then
                    murdererKnown = true
                end
                local sp, onScreen = cam:WorldToViewportPoint(root.Position)
                if onScreen and sp.Z > 0 then
                    local dist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if dist <= fov and visible(eye, char) then
                        local priority = role == "Sheriff" or role == "Hero"
                        local entry = { plr = plr, root = root, char = char, off = dist / fov, priority = priority }
                        if role == "Murderer" then
                            murderer = entry
                        end
                        table.insert(Candidates, entry)
                        local score = dist
                        if kind == "Knife" and priority then
                            score -= 40
                        end
                        if Target and Target.plr == plr then
                            score -= 25
                        end
                        if not bestScore or score < bestScore then
                            best, bestScore = entry, score
                        end
                    end
                end
            end
        end
    end
    if kind == "Gun" and murdererKnown then
        table.clear(Candidates)
        if murderer then
            table.insert(Candidates, murderer)
        end
        return murderer
    end
    return best
end

local function solveFor(entry, kind, origin)
    if not entry or not entry.root.Parent then
        return nil
    end
    local rec = Records[entry.plr]
    if not rec or rec.root ~= entry.root or #rec.list < 2 then
        return nil
    end
    local pos, _, confidence = Predict.aim(rec, origin, kind == "Knife" and KNIFE_SPEED or nil, RTT)
    if not pos then
        return nil
    end
    local from = rec.list[#rec.list].p
    local move = pos - from
    if move.Magnitude > 0.5 then
        local hit = Raycast(Workspace, from, move, WorldParams)
        if hit and hit.Instance.CanCollide then
            pos = hit.Position - move.Unit * 1.5
        end
    end
    return pos, confidence
end

local function solve(kind, origin)
    if kind == "Knife" and #Candidates > 1 then
        local best, bestPos, bestConf, bestScore
        for _, c in Candidates do
            local pos, confidence = solveFor(c, kind, origin)
            if pos then
                local score = confidence - 0.25 * c.off + (c.priority and 0.08 or 0)
                if not bestScore or score > bestScore then
                    best, bestPos, bestConf, bestScore = c, pos, confidence, score
                end
            end
        end
        if best then
            return bestPos, bestConf, best
        end
    end
    local pos, confidence = solveFor(Target, kind, origin)
    return pos, confidence, Target
end

local function aimFrame(kind, origin, pos)
    if kind == "Gun" then
        local dir = pos - origin
        if dir.Magnitude > 0.1 then
            return CFrame.new(pos + dir.Unit * 4)
        end
    end
    return CFrame.new(pos)
end

local function originOf(kind, sent)
    if typeof(sent) == "CFrame" then
        return sent.Position
    end
    if kind == "Gun" and Weapon.attachment then
        return Weapon.attachment.WorldPosition
    end
    local handle = Weapon.tool and Weapon.tool:FindFirstChild("Handle")
    return handle and handle.Position
end

local function send(remote, args)
    local fire = remote.FireServer
    return fire(remote, table.unpack(args, 1, args.n))
end

local function noteShot(kind, entry, origin, aimPos)
    local rec = entry and Records[entry.plr]
    if not rec then
        return
    end
    local shot = { kind = kind, t = os.clock(), rtt = RTT, origin = origin, aim = aimPos, rec = rec, char = entry.char, tool = Weapon.tool }
    if kind == "Gun" then
        LastShot = shot
        return
    end
    task.delay(1.9, function()
        if Unloaded then
            return
        end
        local died = rec.deadAt
        local hit = died ~= nil and died >= shot.t and died <= shot.t + 1.7
        if Predict.observeThrow(Cal, rec, shot.t, shot.rtt, shot.origin, shot.aim, KNIFE_SPEED, hit) then
            applyCalibration()
        end
    end)
end

local function onGunFired(tool, start, finish, hitPart)
    local shot = LastShot
    if not shot or tool ~= shot.tool or typeof(finish) ~= "Vector3" or os.clock() - shot.t > 1.5 then
        return
    end
    LastShot = nil
    local from = shot.origin
    if typeof(start) == "Vector3" then
        from = start
    elseif typeof(start) == "Instance" then
        if start:IsA("Attachment") then
            from = start.WorldPosition
        elseif start:IsA("BasePart") then
            from = start.Position
        end
    end
    local hit = typeof(hitPart) == "Instance" and shot.char ~= nil and hitPart:IsDescendantOf(shot.char)
    task.delay(1.1, function()
        if Unloaded then
            return
        end
        if Predict.observeShot(Cal, shot.rec, shot.t, shot.rtt, from, finish, hit) then
            applyCalibration()
        end
    end)
end
task.spawn(function()
    local services = ReplicatedStorage:WaitForChild("ClientServices", 10)
    local ws = services and services:WaitForChild("WeaponService", 10)
    local fired = ws and ws:WaitForChild("GunFired", 10)
    if fired and not Unloaded then
        track(fired.OnClientEvent:Connect(function(...)
            pcall(onGunFired, ...)
        end))
    end
end)

local function flush(p)
    Pending = nil
    local args = p.args
    if p.kind == "Gun" and Weapon.attachment and typeof(args[1]) == "CFrame" then
        args[1] = Weapon.attachment.WorldCFrame
    end
    local origin = originOf(p.kind, args[1]) or p.origin
    local pos, _, entry = solve(p.kind, origin)
    if pos then
        args[2] = aimFrame(p.kind, origin, pos)
    elseif p.aim then
        args[2] = p.aim
    end
    if pcall(send, p.remote, args) and typeof(args[2]) == "CFrame" then
        noteShot(p.kind, entry or p.entry, origin, args[2].Position)
    end
end

local HoldStep = 0
track(RunService.PreSimulation:Connect(function()
    if Unloaded then
        return
    end
    if not (Settings.GunAim or Settings.KnifeAim) then
        if next(Records) then
            table.clear(Records)
        end
        Target = nil
        table.clear(Candidates)
        if Pending then
            flush(Pending)
        end
        return
    end
    local now = os.clock()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if root and hum then
                local rec = Records[plr]
                if not rec or rec.root ~= root then
                    rec = Predict.new()
                    rec.root = root
                    Records[plr] = rec
                end
                if hum.Health <= 0 then
                    rec.deadAt = rec.deadAt or now
                end
                if not rec.deadAt or now - rec.deadAt < 0.6 then
                    local state = hum:GetState()
                    local grounded = hum.FloorMaterial ~= Enum.Material.Air
                        or (state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Jumping)
                    Predict.push(rec, now, root.Position, grounded)
                end
            else
                Records[plr] = nil
            end
        end
    end
    HoldStep += 1
    if HoldStep % 60 == 0 then
        refreshWorldParams()
    end
    refreshWeapon()
    if Weapon.kind and enabledFor(Weapon.kind) then
        Target = chooseTarget(Weapon.kind)
    else
        Target = nil
        table.clear(Candidates)
    end
    local p = Pending
    if p then
        if p.remote ~= Weapon.remote or not Target then
            flush(p)
        else
            local origin = originOf(p.kind, Weapon.attachment and Weapon.attachment.WorldCFrame) or p.origin
            local _, confidence = solve(p.kind, origin)
            if not confidence or Predict.ready(p.kind == "Knife", confidence, now - p.start) then
                flush(p)
            end
        end
    end
end))
track(Players.PlayerRemoving:Connect(function(plr)
    Records[plr] = nil
end))

local function redirectCall(remote, args)
    local kind = Weapon.kind
    local origin = originOf(kind, args[1])
    if not origin then
        return false
    end
    local pos, confidence, entry = solve(kind, origin)
    if not pos then
        return false
    end
    local frame = aimFrame(kind, origin, pos)
    if not Predict.ready(kind == "Knife", confidence, 0) then
        if Pending then
            flush(Pending)
        end
        Pending = { remote = remote, args = args, kind = kind, origin = origin, aim = frame, entry = entry, start = os.clock() }
        return true
    end
    args[2] = frame
    send(remote, args)
    noteShot(kind, entry, origin, frame.Position)
    return true
end

local hooked = false
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    local original
    local isOurs = typeof(checkcaller) == "function" and checkcaller or function()
        return false
    end
    local function onNamecall(self, ...)
        if Unloaded or self ~= Weapon.remote then
            return original(self, ...)
        end
        if getnamecallmethod() ~= "FireServer" or isOurs() or not enabledFor(Weapon.kind) then
            return original(self, ...)
        end
        local args = table.pack(...)
        local ok, handled = pcall(redirectCall, self, table.pack(...))
        if ok and handled then
            return nil
        end
        return send(self, args)
    end
    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end
    original = hookmetamethod(game, "__namecall", onNamecall)
    hooked = true
end

local WeaponService
pcall(function()
    WeaponService = require(ReplicatedStorage:WaitForChild("ClientServices", 5):WaitForChild("WeaponService", 5))
end)
local origMouse, origTarget
if not hooked and type(WeaponService) == "table" then
    origMouse, origTarget = WeaponService.GetMouseTargetCFrame, WeaponService.GetTargetPosition
    local function override()
        local kind = Weapon.kind
        if Unloaded or not kind or not enabledFor(kind) then
            return nil
        end
        local origin = originOf(kind)
        local pos = origin and solve(kind, origin)
        return pos and aimFrame(kind, origin, pos)
    end
    WeaponService.GetMouseTargetCFrame = function(self, ...)
        local ok, cf = pcall(override)
        if ok and cf then
            return cf
        end
        return origMouse(self, ...)
    end
    WeaponService.GetTargetPosition = function(self, x, y, ...)
        lastTap, lastTapAt = Vector2.new(x, y), os.clock()
        local ok, cf = pcall(override)
        if ok and cf then
            return cf
        end
        return origTarget(self, x, y, ...)
    end
end

local EspFolder = Instance.new("Folder")
EspFolder.Name = "\0"
EspFolder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local Marks = {}
local COLORS = {
    Murderer = Color3.fromRGB(255, 50, 50),
    Sheriff = Color3.fromRGB(50, 140, 255),
    Hero = Color3.fromRGB(50, 140, 255),
    Innocent = Color3.fromRGB(60, 230, 90),
}
local function dropMark(plr)
    local m = Marks[plr]
    if m then
        m.hl:Destroy()
        m.bb:Destroy()
        Marks[plr] = nil
    end
end
track(Players.PlayerRemoving:Connect(dropMark))
local function espStep()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local root, _, char = aliveRoot(plr)
            local role, dead = roleOf(plr)
            if Settings.Esp and root and not dead then
                local color = COLORS[role] or COLORS.Innocent
                local m = Marks[plr]
                if not m or m.char ~= char then
                    dropMark(plr)
                    local hl = Instance.new("Highlight")
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillTransparency = 0.55
                    hl.OutlineTransparency = 0
                    hl.Adornee = char
                    hl.Parent = EspFolder
                    local bb = Instance.new("BillboardGui")
                    bb.AlwaysOnTop = true
                    bb.Size = UDim2.fromOffset(160, 22)
                    bb.StudsOffset = Vector3.new(0, 3.4, 0)
                    bb.Adornee = root
                    bb.Parent = EspFolder
                    local label = Instance.new("TextLabel")
                    label.BackgroundTransparency = 1
                    label.Size = UDim2.fromScale(1, 1)
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 13
                    label.TextStrokeTransparency = 0.4
                    label.Text = plr.DisplayName
                    label.Parent = bb
                    m = { hl = hl, bb = bb, label = label, char = char }
                    Marks[plr] = m
                end
                if m.color ~= color then
                    m.color = color
                    m.hl.FillColor = color
                    m.hl.OutlineColor = color
                    m.label.TextColor3 = color
                end
            else
                dropMark(plr)
            end
        end
    end
end
task.spawn(function()
    while not Unloaded do
        pcall(espStep)
        task.wait(0.25)
    end
end)

local Flagged = {}
local PartCache = {}
local safeCFrame
local function partsOf(char)
    local cached = PartCache[char]
    if cached then
        return cached
    end
    local out = {}
    for _, d in char:GetDescendants() do
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end
    PartCache[char] = out
    local conn
    conn = char.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end)
    char.AncestryChanged:Once(function()
        PartCache[char] = nil
        conn:Disconnect()
    end)
    return out
end
track(RunService.PreSimulation:Connect(function()
    if not Settings.AntiFling then
        safeCFrame = nil
        return
    end
    local me, myHum = aliveRoot(LocalPlayer)
    local now = os.clock()
    for _, plr in Players:GetPlayers() do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root and me then
                local offset = root.Position - me.Position
                if offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z < 3600 then
                    local spin = root.AssemblyAngularVelocity
                    local speed = root.AssemblyLinearVelocity
                    if spin:Dot(spin) > 625 or speed:Dot(speed) > 14400 then
                        Flagged[plr] = now + 3
                    end
                end
            end
            local until_ = Flagged[plr]
            if until_ then
                if now > until_ or not char then
                    Flagged[plr] = nil
                else
                    for _, part in partsOf(char) do
                        if part.CanCollide then
                            part.CanCollide = false
                        end
                    end
                end
            end
        end
    end
    if not me then
        safeCFrame = nil
        return
    end
    local v = me.AssemblyLinearVelocity
    local flat = math.sqrt(v.X * v.X + v.Z * v.Z)
    local spin = me.AssemblyAngularVelocity.Magnitude
    local walk = myHum.WalkSpeed
    if (flat > math.max(walk * 5, 90) or v.Y > 140 or spin > 35) and safeCFrame then
        me.AssemblyLinearVelocity = Vector3.zero
        me.AssemblyAngularVelocity = Vector3.zero
        me.CFrame = safeCFrame
    elseif flat < walk * 2 + 4 and spin < 8 and math.abs(v.Y) < 60 then
        safeCFrame = me.CFrame
    end
end))

local Window = LumeUI:CreateWindow({
    Name = "MM2",
    Author = "ily",
    Icon = "swords",
    SideBarWidth = 130,
    ToggleKey = Enum.KeyCode.K,
    Size = UDim2.fromOffset(460, 300),
    Elements = {
        Minimized = false,
        Close = false,
    },
})

local MARKER = "\u{200B}\u{200C}\u{200B}"
pcall(function()
    Window:EditOpenButton({
        Title = MARKER,
        Icon = "",
        Transparency = 1,
        StrokeThickness = 0,
    })
end)
local Hidden = {}
local function hideOpenButton()
    local roots = { game:GetService("CoreGui") }
    if typeof(gethui) == "function" then
        table.insert(roots, gethui())
    end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        table.insert(roots, pg)
    end
    local found = false
    for _, r in roots do
        local ok, list = pcall(r.GetDescendants, r)
        if ok then
            for _, d in list do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == MARKER then
                    local top = d
                    local p = d.Parent
                    while p and p:IsA("GuiObject") and p.AbsoluteSize.X * p.AbsoluteSize.Y < 320 * 160 do
                        top = p
                        p = p.Parent
                    end
                    if top:IsA("GuiObject") and not Hidden[top] then
                        Hidden[top] = true
                        top.Visible = false
                        track(top:GetPropertyChangedSignal("Visible"):Connect(function()
                            if top.Visible then
                                top.Visible = false
                            end
                        end))
                    end
                    found = true
                end
            end
        end
    end
    return found
end
task.spawn(function()
    for _, delay in { 0.2, 0.5, 1, 2, 4, 8 } do
        task.wait(delay)
        if Unloaded then
            return
        end
        local ok, found = pcall(hideOpenButton)
        if ok and found then
            return
        end
    end
end)
local ToggleKey = Enum.KeyCode.K
track(UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == ToggleKey then
        task.delay(0.15, pcall, hideOpenButton)
        task.delay(0.6, pcall, hideOpenButton)
    end
end))

local Main = Window:Tab({ Title = "Main", Icon = "crosshair" })
Main:Section({ Title = "Silent Aim" })
Main:Toggle({
    Title = "Gun Silent Aim",
    Default = false,
    Callback = function(state)
        Settings.GunAim = state
    end,
})
Main:Toggle({
    Title = "Murderer Silent Aim",
    Default = false,
    Callback = function(state)
        Settings.KnifeAim = state
    end,
})
Main:Section({ Title = "Other" })
Main:Toggle({
    Title = "ESP",
    Default = false,
    Callback = function(state)
        Settings.Esp = state
    end,
})
Main:Toggle({
    Title = "Anti Fling",
    Default = false,
    Callback = function(state)
        Settings.AntiFling = state
        if not state then
            table.clear(Flagged)
        end
    end,
})

local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })
local Bind = SettingsTab:Keybind({
    Title = "Toggle UI",
    Callback = function(key)
        local code = typeof(key) == "EnumItem" and key or Enum.KeyCode[tostring(key)]
        if code then
            ToggleKey = code
            pcall(Window.SetToggleKey, Window, code)
        end
    end,
})
pcall(function()
    Bind:SetValue("K")
end)

Genv.__CustomMM2Unload = function()
    Unloaded = true
    if Pending then
        pcall(flush, Pending)
    end
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for plr in Marks do
        dropMark(plr)
    end
    EspFolder:Destroy()
    if origMouse and WeaponService then
        WeaponService.GetMouseTargetCFrame = origMouse
        WeaponService.GetTargetPosition = origTarget
    end
    pcall(Window.Close, Window)
end

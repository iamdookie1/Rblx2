--// Murder Mystery 2 -------------------------------------------------------
-- Built against a fresh script dump of the live game. The remotes below are
-- the real ones the game's own client modules use, not guesses - and every
-- one of them is a read, nothing here fires anything back at the server:
--
--   Remotes.Gameplay.GetCurrentPlayerData :InvokeServer()
--       Every player's current round data, keyed by name:
--       { [name] = { Role, Perk, Dead, Knife, Gun } }. This is the exact
--       table ReplicatedStorage.Modules.CurrentRoundClient and the
--       round-end scoreboard both read from, and it is NOT limited to your
--       own entry - it carries everyone's role for the whole round.
--   Remotes.Gameplay.PlayerDataChanged.OnClientEvent(playerData)
--       Pushes that same table the instant it changes - role assignment,
--       deaths, perk swaps - which is what makes the role ESP below live
--       instead of polled from a private per-player signal.
--   Remotes.Inventory.GetProfileData :InvokeServer()
--       Your own save: Coins, Gems, NewXP, Prestige, and
--       Weapons/Pets/Materials.Owned - the exact table
--       ReplicatedStorage.Modules.ProfileData wraps and the retry shape
--       (nil until the server responds) it uses.
--   Remotes.Inventory.ChangeProfileData.OnClientEvent(key, value)
--       Live field updates to the table above.
--   Remotes.Inventory.ChangeInventoryItem.OnClientEvent(type, id, amount)
--       Live inventory updates (new weapon/pet/material, amount changes).
--   Modules.LevelModule
--       Pure XP-to-level math, no side effects - required directly so the
--       dashboard shows the same level/progress numbers the game's own UI
--       computes from NewXP.
--
-- A second dump caught someone actually holding the Sheriff's gun, which is
-- what GunClient below comes from (Workspace.<player>.Gun.GunClient). Its
-- fire path is:
--
--   Tool.Activated:Connect(function()
--       local target = WeaponService:GetMouseTargetCFrame()  -- client raycast
--       local origin = HumanoidRootPart.GunRaycastAttachment.WorldCFrame
--       Tool.Shoot:FireServer(origin, target)
--   end)
--
-- Both arguments are entirely client-computed and sent as-is - origin comes
-- off a fixed attachment on your own torso, target off the same
-- screen-to-world raycast the knife throw uses. There's also a client-only
-- "can't shoot" gate (a raycast from your Head to the gun attachment, to
-- catch a blocked third-person angle) that toggles a CantShoot BindableEvent
-- for the crosshair - but nothing reads that BindableEvent before firing, so
-- it never actually stops Shoot:FireServer from going out.
--
-- Silent aim below hooks Shoot:FireServer itself (game.__namecall) rather
-- than replacing the click handler: it lets the real Activated connection
-- do everything - animation, the origin attachment, whatever cooldown the
-- server enforces - and only ever rewrites the target CFrame argument.
--
-- The knife's real flight speed also turned out to be readable after all -
-- just not off the Tool. PlayerScripts.WeaponVisuals.ThrowingKnifeVisuals
-- (the script that renders every OTHER player's flying knife, tagged
-- "ThrowingKnife" via CollectionService) steps the visual forward every
-- frame with `position += Direction * ThrowSpeed * dt`, reading ThrowSpeed
-- straight off that flying instance - `GetAttribute("ThrowSpeed") or 96`.
-- That's a real, direct studs/sec constant (96 by default), completely
-- unrelated to the same-named charge-duration attribute on the Knife Tool.
-- Silent aim listens for the same CollectionService tag the game's own
-- script does and reads it live off the first knife it ever sees thrown -
-- by anyone, not just you - so the knife-speed slider below starts at the
-- real default and self-corrects the moment it has real data instead of
-- running on a guess.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Lifecycle ------------------------------------------------------------------
local Connections = {}
local Unloading = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function spawnLoop(fn)
    return task.spawn(fn)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Remotes --------------------------------------------------------------------
local function waitForPath(root, path, timeout)
    local current = root
    for _, name in ipairs(path) do
        if not current then return nil end
        local ok, child = pcall(function() return current:WaitForChild(name, timeout or 10) end)
        if not ok then return nil end
        current = child
    end
    return current
end

local RemotesFolder = waitForPath(ReplicatedStorage, { "Remotes" })
local GameplayRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Gameplay")
local InventoryRemotes = RemotesFolder and RemotesFolder:FindFirstChild("Inventory")

local GetCurrentPlayerData = GameplayRemotes and GameplayRemotes:FindFirstChild("GetCurrentPlayerData")
local PlayerDataChangedRemote = GameplayRemotes and GameplayRemotes:FindFirstChild("PlayerDataChanged")

local GetProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("GetProfileData")
local ChangeProfileData = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeProfileData")
local ChangeInventoryItem = InventoryRemotes and InventoryRemotes:FindFirstChild("ChangeInventoryItem")

local LevelModule = nil
do
    local ModulesFolder = waitForPath(ReplicatedStorage, { "Modules" })
    local mod = ModulesFolder and ModulesFolder:FindFirstChild("LevelModule")
    if mod then
        local ok, result = pcall(require, mod)
        if ok then LevelModule = result end
    end
end

--// Live round data (role/perk/dead, for every player) -------------------------
local RoundData = {}

local function refreshRoundData()
    if not GetCurrentPlayerData then return end
    local ok, data = pcall(function() return GetCurrentPlayerData:InvokeServer() end)
    if ok and typeof(data) == "table" then
        RoundData = data
    end
end

task.spawn(refreshRoundData)

if PlayerDataChangedRemote then
    track(PlayerDataChangedRemote.OnClientEvent:Connect(function(data)
        if typeof(data) == "table" then
            RoundData = data
        end
    end))
end

--// Live profile data (own coins/gems/xp/inventory) -----------------------------
local ProfileData = nil

local function fetchProfileData()
    if not GetProfileData then return end
    task.spawn(function()
        local tries = 0
        while not Unloading and tries < 60 do
            local ok, data = pcall(function() return GetProfileData:InvokeServer() end)
            if ok and typeof(data) == "table" then
                ProfileData = data
                return
            end
            tries = tries + 1
            task.wait(0.25)
        end
    end)
end

fetchProfileData()

if ChangeProfileData then
    track(ChangeProfileData.OnClientEvent:Connect(function(key, value)
        if ProfileData then ProfileData[key] = value end
    end))
end

-- Mirrors ProfileData's own onInventoryItemChanged: Weapons/Pets/Materials are
-- id -> amount dictionaries, everything else (Emotes, Toys, ...) is a plain
-- array of owned ids.
local DICT_INVENTORY_TYPES = { Weapons = true, Pets = true, Materials = true }

if ChangeInventoryItem then
    track(ChangeInventoryItem.OnClientEvent:Connect(function(itemType, id, amount)
        if not ProfileData or not ProfileData[itemType] then return end
        if DICT_INVENTORY_TYPES[itemType] then
            ProfileData[itemType].Owned[id] = amount
        elseif amount ~= nil and amount > 0 then
            table.insert(ProfileData[itemType].Owned, id)
        end
    end))
end

local function countOwned(owned)
    if not owned then return 0 end
    local n = 0
    for _ in pairs(owned) do n = n + 1 end
    return n
end

--// UI ---------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = 'mm2',
    SubTitle = 'assist',
    Folder = 'MM2Assist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(210, 45, 45),
})

--// Tab 1: profile ---------------------------------------------------------------
local ProfileTab = Window:Tab({ Title = 'profile', Icon = 'user' })

local EconomySection = ProfileTab:Section({ Title = 'economy', Side = 'left' })
local CoinsStat = EconomySection:Stat({ Title = 'coins', Value = '-' })
local GemsStat = EconomySection:Stat({ Title = 'gems', Value = '-' })
local PrestigeStat = EconomySection:Stat({ Title = 'prestige', Value = '-' })
EconomySection:Button({ Title = 'refresh', Callback = fetchProfileData })

local LevelSection = ProfileTab:Section({ Title = 'level', Side = 'right' })
local LevelStat = LevelSection:Stat({ Title = 'level', Value = '-' })
local XPBar = LevelSection:Progress({ Title = 'xp to next level', Percent = true })

local InventorySection = ProfileTab:Section({ Title = 'inventory', Side = 'left' })
local WeaponsStat = InventorySection:Stat({ Title = 'weapons owned', Value = '-' })
local PetsStat = InventorySection:Stat({ Title = 'pets owned', Value = '-' })
local MaterialsStat = InventorySection:Stat({ Title = 'materials owned', Value = '-' })

local function refreshDashboard()
    if not ProfileData then return end

    CoinsStat:Set(tostring(ProfileData.Coins or 0))
    GemsStat:Set(tostring(ProfileData.Gems or 0))
    PrestigeStat:Set(tostring(ProfileData.Prestige or 0))

    local xp = ProfileData.NewXP or 0
    if LevelModule then
        local ok, level = pcall(LevelModule.GetLevel, xp)
        if ok then LevelStat:Set(tostring(level)) end

        local ok2, progress = pcall(LevelModule.GetProgressToNextLevel, xp)
        if ok2 and typeof(progress) == "number" then
            XPBar:Set(math.clamp(progress, 0, 1) * 100)
        end
    else
        LevelStat:Set('n/a')
    end

    WeaponsStat:Set(tostring(countOwned(ProfileData.Weapons and ProfileData.Weapons.Owned)))
    PetsStat:Set(tostring(countOwned(ProfileData.Pets and ProfileData.Pets.Owned)))
    MaterialsStat:Set(tostring(countOwned(ProfileData.Materials and ProfileData.Materials.Owned)))
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        refreshDashboard()
    end
end)

--// Tab 2: silent aim -------------------------------------------------------------
-- Two weapons, two very different aim problems:
--
--   Gun (hitscan) - Shoot:FireServer(origin, target). The server gets told
--   the answer directly, no travel time modeled anywhere in the client
--   code, so the only thing worth leading for is the ONE-WAY trip to the
--   server, not a physical bullet flight - see getPing() below for why
--   that's half of ping, not all of it.
--
--   Knife (thrown) - KnifeThrown:FireServer(handleCFrame, target). This one
--   really is a physical projectile with travel time, and unlike the gun
--   its real flight speed IS readable - see the header note on
--   ThrowingKnifeVisuals for where 96 studs/sec and the live calibration
--   below actually come from.
--
-- Both weapons lead using velocity measured from the target's own position
-- across our scan ticks, not part.AssemblyLinearVelocity - a remote
-- player's parts are replication-driven, not fully simulated on your
-- client, so that property can read stale or flat-zero for exactly the
-- kind of slight, subtle movement (strafing, small corrections) leading
-- most needs to get right. Measuring it ourselves from how far the part
-- actually moved on screen tracks whatever the target visibly does, at the
-- same rate the scan itself runs.
--
-- The sheriff's gun exists to kill the murderer, and only the murderer -
-- RoundData (see the header) names them by role, so the gun redirect is
-- restricted to whichever player currently has Role == "Murderer" rather
-- than "nearest player". The knife has no such restriction: the murderer
-- can legally kill anyone, so it keeps the general nearest-target scan.
--
-- Both weapons also get a second, late check right before the redirect:
-- the scan below picks a candidate using a camera-based sightline (cheap,
-- runs first), but the shot itself is re-validated with a fresh raycast
-- from the REAL origin the game just handed this hook - the gun's actual
-- muzzle attachment, the knife's actual Handle position - not the camera.
-- Camera and muzzle are not the same point, especially off-center or in a
-- tight corner, so a target that reads as clear from the camera can still
-- be wall-blocked from where the shot truly leaves. A blocked shot is left
-- un-redirected rather than forced, so it just goes out as originally aimed.
--
-- Prediction has two independent on/off switches and a five-way dial:
-- "predict movement" is the master switch (off = aim at exactly where the
-- target is right now, nothing else below matters); "use ping" controls
-- whether adaptive mode's lead time includes the one-way-latency estimate
-- at all, for whenever that estimate is doing more harm than good on a
-- given connection; and "adaptive" chooses between the velocity/
-- acceleration model (see adaptiveVelocityAndAccel, tuned by the "adaptive
-- amount" dropdown - lesser/normal/extra/advanced/best, each a genuinely
-- different model, not a relabeled slider) and a flat manual lead time per
-- weapon when it's off.
local Aim = {
    SilentAim = false,
    WallCheck = true,
    AimPart = "Head",
    MaxRange = 300,          -- WeaponService:GetMouseTargetCFrame caps its own raycast at 300 studs
    FOVEnabled = true,
    FOVRadius = 200,
    FOVFollowMouse = true,
    Predict = true,
    UsePing = true,          -- adds the one-way-latency component to adaptive lead; off = lead purely on measured motion
    Adaptive = true,
    AdaptiveLevel = 'Normal', -- 'Lesser' | 'Normal' | 'Extra' | 'Advanced' | 'Best' - see adaptiveVelocityAndAccel below
    ManualLeadTimeGun = 0.05,   -- seconds - used INSTEAD of the adaptive model when Adaptive is off
    ManualLeadTimeKnife = 0.15,
    KnifeSpeed = 96,         -- the real default (ThrowingKnifeVisuals) - overwritten live once any knife is seen thrown, see below
}

local function isAlivePlr(plr)
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.IgnoreWater = true

-- Coarse, camera-based - used only to pick a candidate during the scan.
local function isVisible(char, origin)
    if not Aim.WallCheck then return true end
    local part = char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart")
    if not part then return false end
    local params = visionParams
    params.FilterDescendantsInstances = { LocalPlayer.Character, char }
    local direction = part.Position - origin
    local ok, result = pcall(function() return Workspace:Raycast(origin, direction, params) end)
    if not ok then return true end
    if not result then return true end
    return (result.Position - origin).Magnitude >= direction.Magnitude - 2
end

-- Precise, real-origin-based - the final gate right before a shot is
-- actually redirected. See the header note on why this has to be separate
-- from isVisible above rather than reusing it.
local function clearFromOrigin(originPos, targetPos, char)
    if not Aim.WallCheck then return true end
    local params = visionParams
    params.FilterDescendantsInstances = { LocalPlayer.Character, char }
    local direction = targetPos - originPos
    local ok, result = pcall(function() return Workspace:Raycast(originPos, direction, params) end)
    if not ok then return true end
    if not result then return true end
    return (result.Position - originPos).Magnitude >= direction.Magnitude - 2
end

local function screenAnchor()
    if Aim.FOVFollowMouse then
        return UserInputService:GetMouseLocation()
    end
    local viewport = Camera.ViewportSize
    return Vector2.new(viewport.X / 2, viewport.Y / 2)
end

-- Cheap: distance and a screen projection, no raycast.
local function candidateScreenDist(part, anchor, origin)
    if (part.Position - origin).Magnitude > Aim.MaxRange then return nil end
    local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
    if not onScreen then return nil end
    local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - anchor).Magnitude
    if Aim.FOVEnabled and screenDist > Aim.FOVRadius then return nil end
    return screenDist
end

-- filterFn narrows the candidate pool before ranking - the gun passes
-- isMurderer, the knife passes nil (anyone alive and in view is fair game).
--
-- isVisible does a real raycast, and used to run once per candidate before
-- picking the nearest-to-crosshair one that passed - on an unrestricted
-- (knife) scan against a full lobby, that's a raycast per player in the
-- server, every single tick, for as long as you're holding a knife. Since
-- only the single best candidate ever actually matters, candidates are
-- sorted by screen distance first (cheap - no raycast) and the raycast
-- only runs, nearest-to-crosshair first, until one of them actually passes
-- it. The common case - the closest thing to your aim isn't hiding behind
-- a wall - costs exactly one raycast a tick instead of one per player.
local function scanTarget(filterFn)
    local origin = Camera.CFrame.Position
    local anchor = screenAnchor()

    local candidates = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlivePlr(plr) and (not filterFn or filterFn(plr)) then
            local char = plr.Character
            local part = char and (char:FindFirstChild(Aim.AimPart) or char:FindFirstChild("HumanoidRootPart"))
            if part then
                local screenDist = candidateScreenDist(part, anchor, origin)
                if screenDist then
                    candidates[#candidates + 1] = { plr = plr, char = char, part = part, screenDist = screenDist }
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.screenDist < b.screenDist end)

    for _, candidate in ipairs(candidates) do
        if isVisible(candidate.char, origin) then
            return candidate.plr, candidate.part
        end
    end

    return nil, nil
end

local function isMurderer(plr)
    local data = RoundData[plr.Name]
    return data ~= nil and data.Role == "Murderer" and data.Dead ~= true
end

-- GetNetworkPing() is a round trip. Only half of that is the part that
-- matters for a hitscan lead - the time for YOUR shot to reach the server -
-- the other half is the server's reply coming back, which has no bearing
-- on where the target already was when the server received the shot.
-- Leading on the full round trip (what this used to do) overcorrects by
-- roughly 2x, which is exactly what "doesn't detect slight movements"
-- looks like from outside: a small, real motion gets doubled into an aim
-- point that sails past it instead of landing on it.
local function getPing()
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and typeof(ping) == "number" and ping > 0 then return ping end
    return 0.08
end

-- part.AssemblyLinearVelocity is driven by physics replication for every
-- character but your own, which updates in coarse steps and can sit flat
-- at the wrong value between them - it is not a reliable source for
-- "slight movements". Measuring how far a part actually moved between two
-- of our own scan ticks sidesteps that: it reflects exactly what showed up
-- on screen, at the scan's own tick rate, with no dependency on how well
-- the target's physics happens to be replicating right now. Falls back to
-- AssemblyLinearVelocity only for a target's very first tick, when there
-- is no prior sample yet to measure from.
--
-- Every sample also feeds a short rolling history per player, which is
-- what the "adaptive amount" levels below actually differ on - raw,
-- averaged, or exponentially-smoothed velocity, with or without an
-- acceleration term. None of this replaces the ping-based lead-time work
-- above; it decides WHAT velocity gets multiplied by that time, not the
-- time itself.
local lastSample = {} -- [player name] = { Position = Vector3, Time = number }
local velocityHistory = {} -- [player name] = { {v=Vector3, t=number}, ... } newest last
local ADAPTIVE_HISTORY = 6

track(Players.PlayerRemoving:Connect(function(plr)
    lastSample[plr.Name] = nil
    velocityHistory[plr.Name] = nil
end))

local function trackedVelocity(plr, part)
    local now = os.clock()
    local prev = lastSample[plr.Name]
    lastSample[plr.Name] = { Position = part.Position, Time = now }

    local raw
    if prev then
        local dt = now - prev.Time
        if dt > 0 and dt < 0.5 then
            raw = (part.Position - prev.Position) / dt
        end
    end
    if not raw then
        local ok, velocity = pcall(function() return part.AssemblyLinearVelocity end)
        raw = (ok and velocity) or Vector3.zero
    end

    local hist = velocityHistory[plr.Name]
    if not hist then
        hist = {}
        velocityHistory[plr.Name] = hist
    end
    hist[#hist + 1] = { v = raw, t = now }
    while #hist > ADAPTIVE_HISTORY do
        table.remove(hist, 1)
    end

    return raw, hist
end

local function averageVelocity(hist, count)
    count = math.min(count, #hist)
    if count <= 0 then return Vector3.zero end
    local sum = Vector3.zero
    for i = #hist - count + 1, #hist do
        sum = sum + hist[i].v
    end
    return sum / count
end

-- Weighted toward the most recent samples rather than a flat average, so a
-- genuine direction change shows up faster while single-frame noise still
-- gets smoothed out. alpha closer to 1 trusts the newest sample more.
local function exponentialVelocity(hist, alpha)
    if #hist == 0 then return Vector3.zero end
    local result = hist[1].v
    for i = 2, #hist do
        result = result:Lerp(hist[i].v, alpha)
    end
    return result
end

local function accelerationOf(hist)
    if #hist < 2 then return Vector3.zero end
    local newer, older = hist[#hist], hist[#hist - 1]
    local dt = newer.t - older.t
    if dt <= 0 then return Vector3.zero end
    return (newer.v - older.v) / dt
end

-- The five "adaptive amount" levels, each a genuinely different model, not
-- just a relabeled slider:
--   Lesser   - the single most recent raw sample. Reacts instantly, jitters
--              with it too.
--   Normal   - a flat average of the last 2 samples. Removes the worst of
--              that jitter at a small cost in reaction time.
--   Extra    - a flat average of the last 4 samples, plus an acceleration
--              term (velocity += acceleration * time), so a target actively
--              speeding up or turning is led further than one holding
--              steady.
--   Advanced - the same acceleration term, but velocity is exponentially
--              smoothed instead of flat-averaged - noise gets filtered
--              without lagging behind a real, sustained direction change
--              the way a flat average does.
--   Best     - Advanced's smoothing and acceleration, plus (for the knife
--              only, see knifeLeadBest below) iterating the travel-time
--              calculation against the predicted point itself, since
--              leading changes the distance the knife actually has to
--              cross.
local function adaptiveVelocityAndAccel(hist, level)
    if level == 'Lesser' then
        return (hist[#hist] and hist[#hist].v) or Vector3.zero, Vector3.zero
    elseif level == 'Normal' then
        return averageVelocity(hist, 2), Vector3.zero
    elseif level == 'Extra' then
        return averageVelocity(hist, 4), accelerationOf(hist)
    elseif level == 'Advanced' then
        return exponentialVelocity(hist, 0.6), accelerationOf(hist)
    else -- 'Best'
        return exponentialVelocity(hist, 0.75), accelerationOf(hist)
    end
end

-- Where the target will actually be once the shot lands, not where they
-- were when the scan ran a moment earlier. Capped so one stray velocity
-- reading - a teleport, a knockback, a fresh respawn - can't fling the aim
-- point somewhere the target was never actually headed.
local MAX_LEAD_OFFSET = 15 -- studs

local function leadPosition(part, velocity, acceleration, travelTime)
    if not travelTime or travelTime <= 0 then
        return part.Position
    end
    local offset = velocity * travelTime + acceleration * (0.5 * travelTime * travelTime)
    if offset.Magnitude > MAX_LEAD_OFFSET then
        offset = offset.Unit * MAX_LEAD_OFFSET
    end
    return part.Position + offset
end

-- Best-level knife lead only: travel time depends on distance, and leading
-- moves the aim point, which changes the distance - a target moving
-- straight toward or away from you makes one pass slightly under-correct.
-- Re-deriving travel time from the predicted point and re-predicting from
-- that converges in a couple of passes at these speeds and ranges.
local function knifeLeadBest(origin, part, velocity, acceleration, pingComponent)
    local aimPos = part.Position
    for _ = 1, 2 do
        local dist = (aimPos - origin).Magnitude
        local travelTime = pingComponent + dist / math.max(Aim.KnifeSpeed, 1)
        aimPos = leadPosition(part, velocity, acceleration, travelTime)
    end
    return aimPos
end

-- Self-calibrating knife speed - see the header note on ThrowingKnifeVisuals.
-- Listens for the exact same CollectionService tag that script watches and
-- reads ThrowSpeed straight off the flying knife itself, from anyone's
-- throw, not just yours. ">1" guards against a momentarily-unset attribute
-- reading back as 0 or a bool default rather than a real speed.
local knifeSpeedSlider = nil -- assigned once the settings UI below builds it

local function onThrowingKnifeAdded(instance)
    local ok, speed = pcall(function() return instance:GetAttribute("ThrowSpeed") end)
    if ok and typeof(speed) == "number" and speed > 1 and speed ~= Aim.KnifeSpeed then
        Aim.KnifeSpeed = speed
        if knifeSpeedSlider then
            pcall(function() knifeSpeedSlider:Set(speed) end)
        end
    end
end

track(CollectionService:GetInstanceAddedSignal("ThrowingKnife"):Connect(onThrowingKnifeAdded))
-- Catch one that's already flying when this script loads - the signal
-- above only fires for instances tagged AFTER the connection is made.
for _, instance in ipairs(CollectionService:GetTagged("ThrowingKnife")) do
    task.spawn(onThrowingKnifeAdded, instance)
end

-- Wrapping the hook in newcclosure and cutting it down to one raycast
-- (both tried in an earlier pass at this) were not enough - the error kept
-- happening. The actual problem is more fundamental than "too many
-- reentrant calls": on this executor, ANY namecall made from inside the
-- hook, between it receiving the FireServer call and it finally calling
-- originalNamecall, can corrupt which method/self that originalNamecall
-- call actually resolves to - which is exactly what "Raycast is not a
-- valid member of RemoteEvent" is: the *final* originalNamecall(self, ...)
-- call, meant to dispatch FireServer on the Shoot/KnifeThrown remote,
-- instead replayed the METHOD of the last thing that happened to run
-- in between (a Raycast) against the ORIGINAL self (the remote).
--
-- So nothing that triggers a namecall can run inside the hook at all
-- anymore, not even the one hit-check raycast, not even GetNetworkPing.
-- Every part of the decision - the target scan, the lead calculation, AND
-- the real-origin wall-check raycast - now happens entirely in this
-- background loop, using the gun/knife's actual origin attachment read
-- fresh each tick (the same GunRaycastAttachment / Knife Handle the game's
-- own client code reads from). That origin is up to 1/30s old rather than
-- the exact instant of the click, an imperceptible difference for a
-- torso-mounted attachment, and it means the hook itself only ever reads
-- already-decided values and makes the one namecall it can't avoid making:
-- the actual FireServer redirect, once, at the very end.
local cachedGunRedirect = nil
local cachedKnifeRedirect = nil
local cachedPing = 0.08

local function findGunOrigin()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local attachment = root and root:FindFirstChild("GunRaycastAttachment")
    return attachment and attachment.WorldPosition
end

local function findKnifeOrigin()
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChild("Knife")
    local handle = tool and tool:FindFirstChild("Handle")
    return handle and handle.Position
end

-- Computes where a candidate should actually be aimed at, per the current
-- Predict/Adaptive settings. `sampled` memoizes trackedVelocity per player
-- for this tick only - the gun (murderer-only) and knife (anyone) scans
-- can land on the same player, and sampling them twice in the same instant
-- would measure ~0 elapsed time on the second call instead of a real
-- velocity, corrupting the reading.
local function computeAimPoint(plr, part, sampled, travelTimeFn)
    if not Aim.Predict then return part.Position end

    local s = sampled[plr.Name]
    if not s then
        local raw, hist = trackedVelocity(plr, part)
        s = { raw = raw, hist = hist }
        sampled[plr.Name] = s
    end

    if not Aim.Adaptive then
        return leadPosition(part, s.raw, Vector3.zero, travelTimeFn(false, s.raw, Vector3.zero))
    end

    local velocity, acceleration = adaptiveVelocityAndAccel(s.hist, Aim.AdaptiveLevel)
    return leadPosition(part, velocity, acceleration, travelTimeFn(true, velocity, acceleration))
end

-- 60Hz rather than 30: this loop no longer runs inside the hook (nothing
-- about reentrancy limits it anymore), and a tighter tick means a smaller
-- worst-case gap between "the target moved" and "the cached redirect
-- reflects it" - the other half of what made slight movements hard to
-- track, on top of the velocity source and the ping fix above.
--
-- The whole tick body runs inside a pcall: a background loop with no
-- protection dies silently and permanently the moment anything in it
-- throws once (a nil Camera mid-respawn, a destroyed part, whatever) -
-- task.spawn just lets the error end that coroutine, and there is nothing
-- left to restart it. One bad tick should cost one tick, not silent aim
-- for the rest of the session.
spawnLoop(function()
    while not Unloading do
        task.wait(1 / 60)

        local ok = pcall(function()
            if not Aim.SilentAim then
                cachedGunRedirect, cachedKnifeRedirect = nil, nil
                return
            end

            -- findGunOrigin/findKnifeOrigin are a couple of FindFirstChild
            -- calls - cheap. scanTarget is not: unrestricted, it raycasts
            -- and projects every alive player in the server, every tick.
            -- The previous version ran BOTH scans unconditionally, every
            -- single tick, at 60/sec, regardless of whether the local
            -- player was even holding the corresponding weapon - which for
            -- most of a round is neither (only the murderer holds a knife,
            -- only the sheriff a gun). That's a large, constant, entirely
            -- wasted background cost, and it's exactly what a throw's own
            -- extra frame work (the knife visual spawning, its trail,
            -- everything ThrowingKnifeVisuals does) would tip over into a
            -- visible stutter. Checking the origin first and skipping the
            -- scan whenever it's nil - not holding that weapon - cuts this
            -- down to only the two players in the server who can ever
            -- benefit from it.
            cachedPing = getPing()
            local sampled = {}

            local gOrigin = findGunOrigin()
            if not gOrigin then
                cachedGunRedirect = nil
            else
                local gPlr, gPart = scanTarget(isMurderer)
                if gPlr and gPart then
                    local aimPos = computeAimPoint(gPlr, gPart, sampled, function(adaptive)
                        if not adaptive then return Aim.ManualLeadTimeGun end
                        return Aim.UsePing and (cachedPing / 2) or 0
                    end)
                    cachedGunRedirect = clearFromOrigin(gOrigin, aimPos, gPlr.Character) and CFrame.new(aimPos) or nil
                else
                    cachedGunRedirect = nil
                end
            end

            local kOrigin = findKnifeOrigin()
            if not kOrigin then
                cachedKnifeRedirect = nil
            else
                local kPlr, kPart = scanTarget(nil)
                if kPlr and kPart then
                    local aimPos
                    if Aim.Predict and Aim.Adaptive and Aim.AdaptiveLevel == 'Best' then
                        local s = sampled[kPlr.Name]
                        if not s then
                            local raw, hist = trackedVelocity(kPlr, kPart)
                            s = { raw = raw, hist = hist }
                            sampled[kPlr.Name] = s
                        end
                        local velocity, acceleration = adaptiveVelocityAndAccel(s.hist, Aim.AdaptiveLevel)
                        local pingComponent = Aim.UsePing and (cachedPing / 2) or 0
                        aimPos = knifeLeadBest(kOrigin, kPart, velocity, acceleration, pingComponent)
                    else
                        aimPos = computeAimPoint(kPlr, kPart, sampled, function(adaptive)
                            if not adaptive then return Aim.ManualLeadTimeKnife end
                            local pingComponent = Aim.UsePing and (cachedPing / 2) or 0
                            local dist = (kPart.Position - kOrigin).Magnitude
                            return pingComponent + dist / math.max(Aim.KnifeSpeed, 1)
                        end)
                    end
                    cachedKnifeRedirect = clearFromOrigin(kOrigin, aimPos, kPlr.Character) and CFrame.new(aimPos) or nil
                else
                    cachedKnifeRedirect = nil
                end
            end
        end)

        if not ok then
            cachedGunRedirect, cachedKnifeRedirect = nil, nil
        end
    end
end)

local hasNamecallHook = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if hasNamecallHook then
    local originalNamecall

    local function onNamecall(self, ...)
        if Unloading or not Aim.SilentAim or typeof(self) ~= "Instance" or getnamecallmethod() ~= "FireServer" then
            return originalNamecall(self, ...)
        end

        -- Matched by shape, not a cached instance reference, so both
        -- branches keep working across every respawn and every new tool
        -- instance without needing to re-find anything. Everything from
        -- here down is property/vararg reads and table lookups - no
        -- namecall of any kind - right up to the single redirect call.
        if self.Name == "Shoot" and self.ClassName == "RemoteEvent" and cachedGunRedirect then
            local parent = self.Parent
            if parent and parent.ClassName == "Tool" and parent.Name == "Gun" then
                local origin = ...
                if typeof(origin) == "CFrame" then
                    return originalNamecall(self, origin, cachedGunRedirect)
                end
            end
        elseif self.Name == "KnifeThrown" and cachedKnifeRedirect then
            local eventsFolder = self.Parent
            local tool = eventsFolder and eventsFolder.Parent
            if eventsFolder and eventsFolder.Name == "Events" and tool and tool.ClassName == "Tool" and tool.Name == "Knife" then
                local handleCFrame = ...
                if typeof(handleCFrame) == "CFrame" then
                    return originalNamecall(self, handleCFrame, cachedKnifeRedirect)
                end
            end
        end

        return originalNamecall(self, ...)
    end

    if typeof(newcclosure) == "function" then
        onNamecall = newcclosure(onNamecall)
    end

    originalNamecall = hookmetamethod(game, "__namecall", onNamecall)
end

local SilentAimTab = Window:Tab({ Title = 'silent aim', Icon = 'crosshair' })

local AimSection = SilentAimTab:Section({ Title = 'aim', Side = 'left' })

AimSection:Stat({
    Title = 'hook api',
    Value = hasNamecallHook and 'available' or 'missing',
    Color = hasNamecallHook and Color3.fromRGB(126, 217, 87) or Color3.fromRGB(255, 96, 106),
})

AimSection:Toggle({
    Title = 'silent aim',
    Desc = 'gun: redirects only to the murderer. knife: redirects to the nearest valid target. either way your click, animation and the real origin stay exactly as fired - only the aim point changes, and only when the shot is actually clear from where it truly leaves',
    Flag = 'mm2_silent_aim',
    Callback = function(state)
        if state and not hasNamecallHook then
            Centrl:Notify({
                Title = 'mm2',
                Content = 'hookmetamethod/getnamecallmethod not available on this executor - silent aim cannot hook Shoot/KnifeThrown:FireServer.',
                Type = 'error',
                Duration = 6,
            })
        end
        Aim.SilentAim = state
    end,
})

AimSection:Dropdown({
    Title = 'aim part',
    Values = { 'Head', 'HumanoidRootPart' },
    Default = 'Head',
    Flag = 'mm2_silent_aim_part',
    Callback = function(value) Aim.AimPart = value end,
})

AimSection:Toggle({
    Title = 'wall check',
    Desc = 'requires a clear line of sight both to pick the target and, separately, from the real muzzle/handle position right before the shot is redirected',
    Flag = 'mm2_silent_aim_wallcheck',
    Default = true,
    Callback = function(state) Aim.WallCheck = state end,
})

AimSection:Slider({
    Title = 'max range',
    Min = 25,
    Max = 300,
    Increment = 5,
    Default = 300,
    Suffix = ' studs',
    Flag = 'mm2_silent_aim_range',
    Callback = function(value) Aim.MaxRange = value end,
})

AimSection:Toggle({
    Title = 'predict movement',
    Desc = "leads the target's velocity, measured from how they actually moved on your last few scans rather than trusted off their replicated physics - half of ping for the gun's one-way trip, that plus flight time for the thrown knife",
    Flag = 'mm2_silent_aim_predict',
    Default = true,
    Callback = function(state) Aim.Predict = state end,
})

knifeSpeedSlider = AimSection:Slider({
    Title = 'knife speed',
    Desc = "starts at the real default (96 studs/s, read straight off ThrowingKnifeVisuals) and self-corrects the moment any knife - yours or anyone's - is actually seen flying. Only matters as a manual override before that happens",
    Min = 40,
    Max = 300,
    Increment = 5,
    Default = Aim.KnifeSpeed,
    Suffix = ' studs/s',
    Flag = 'mm2_silent_aim_knife_speed',
    Callback = function(value) Aim.KnifeSpeed = value end,
})

local FovSection = SilentAimTab:Section({ Title = 'fov', Side = 'right' })

FovSection:Toggle({
    Title = 'fov limit',
    Desc = 'only considers targets within the radius below',
    Flag = 'mm2_silent_aim_fov',
    Default = true,
    Callback = function(state) Aim.FOVEnabled = state end,
})

FovSection:Slider({
    Title = 'fov radius',
    Min = 20,
    Max = 600,
    Increment = 10,
    Default = 200,
    Flag = 'mm2_silent_aim_fov_radius',
    Callback = function(value) Aim.FOVRadius = value end,
})

FovSection:Toggle({
    Title = 'follow mouse',
    Desc = 'centers the fov on the mouse instead of the middle of the screen',
    Flag = 'mm2_silent_aim_follow_mouse',
    Default = true,
    Callback = function(state) Aim.FOVFollowMouse = state end,
})

local PredictionSection = SilentAimTab:Section({ Title = 'prediction', Side = 'right' })

PredictionSection:Toggle({
    Title = 'use ping',
    Desc = 'adds the one-way-latency estimate to adaptive lead. off = lead purely on measured motion, nothing added for how long the shot takes to reach the server',
    Flag = 'mm2_silent_aim_use_ping',
    Default = true,
    Callback = function(state) Aim.UsePing = state end,
})

PredictionSection:Toggle({
    Title = 'adaptive',
    Desc = 'on: velocity/acceleration model below, tuned by the amount dropdown. off: a flat manual lead time per weapon instead - see the sliders under that',
    Flag = 'mm2_silent_aim_adaptive',
    Default = true,
    Callback = function(state) Aim.Adaptive = state end,
})

PredictionSection:Dropdown({
    Title = 'adaptive amount',
    Desc = 'lesser: raw last sample. normal: 2-sample average. extra: 4-sample average + acceleration. advanced: exponential smoothing + acceleration. best: advanced, plus the knife re-derives its travel time against its own predicted point',
    Values = { 'Lesser', 'Normal', 'Extra', 'Advanced', 'Best' },
    Default = 'Normal',
    Flag = 'mm2_silent_aim_adaptive_level',
    Callback = function(value) Aim.AdaptiveLevel = value end,
})

PredictionSection:Slider({
    Title = 'manual gun lead time',
    Desc = 'only used while adaptive is off - a flat lead time for the hitscan gun instead of the ping-based one-way estimate',
    Min = 0,
    Max = 0.5,
    Increment = 0.01,
    Default = Aim.ManualLeadTimeGun,
    Suffix = 's',
    Flag = 'mm2_silent_aim_manual_gun',
    Callback = function(value) Aim.ManualLeadTimeGun = value end,
})

PredictionSection:Slider({
    Title = 'manual knife lead time',
    Desc = 'only used while adaptive is off - a flat lead time for the thrown knife instead of ping + distance/speed',
    Min = 0,
    Max = 1,
    Increment = 0.01,
    Default = Aim.ManualLeadTimeKnife,
    Suffix = 's',
    Flag = 'mm2_silent_aim_manual_knife',
    Callback = function(value) Aim.ManualLeadTimeKnife = value end,
})

--// Tab 3: visual ------------------------------------------------------------------
local Visual = {
    Enabled = false,
    ColorByRole = false,
    RoleESP = false,
    ShowMurdererPerk = false,
}

-- Straight out of ReplicatedStorage.GUI.MainPC.Game/RoleSelector's own role
-- color table, so the ESP matches the colors the game itself uses for these
-- roles rather than inventing a new palette.
local ROLE_COLORS = {
    Innocent = Color3.fromRGB(0, 255, 0),
    Sheriff = Color3.fromRGB(0, 0, 255),
    Murderer = Color3.fromRGB(255, 0, 0),
    Hero = Color3.fromRGB(0, 0, 255),
    Zombie = Color3.fromRGB(25, 172, 0),
    Survivor = Color3.fromRGB(43, 154, 238),
    Freezer = Color3.fromRGB(150, 220, 250),
    Runner = Color3.fromRGB(0, 200, 100),
}
local DEFAULT_ESP_COLOR = Color3.fromRGB(255, 255, 255)

local function espColorFor(plr)
    if Visual.ColorByRole then
        local entry = RoundData[plr.Name]
        -- entry.Dead was missing from this check, so once ColorByRole had
        -- colored someone in, they stayed that color forever: RoundData
        -- keeps a dead player's Role around (the round-end scoreboard reads
        -- it straight off the same table), so "role -> color" alone never
        -- stopped matching just because they died mid-round.
        if entry and entry.Role and entry.Dead ~= true then
            local color = ROLE_COLORS[entry.Role]
            if color then return color end
        end
    end
    return DEFAULT_ESP_COLOR
end

--// Player ESP (Highlight) ---------------------------------------------------------
local espObjects = {}

local function destroyEsp(plr)
    local obj = espObjects[plr]
    if not obj then return end
    if obj.Highlight then obj.Highlight:Destroy() end
    espObjects[plr] = nil
end

local function buildEsp(plr, char)
    destroyEsp(plr)
    local color = espColorFor(plr)
    local hl = Instance.new("Highlight")
    hl.FillColor = color
    hl.OutlineColor = color
    hl.FillTransparency = 0.5
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = char
    espObjects[plr] = { Char = char, Highlight = hl }
end

--// Role ESP (name-above-head billboard) --------------------------------------------
local roleObjects = {}

local function destroyRoleLabel(plr)
    local obj = roleObjects[plr]
    if not obj then return end
    if obj.Billboard then obj.Billboard:Destroy() end
    roleObjects[plr] = nil
end

local function buildRoleLabel(plr, char)
    destroyRoleLabel(plr)
    local head = char:FindFirstChild("Head")
    if not head then return nil end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "MM2RoleESP"
    billboard.Adornee = head
    billboard.Size = UDim2.fromOffset(200, 36)
    billboard.StudsOffset = Vector3.new(0, 2.2, 0)
    billboard.AlwaysOnTop = true

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextStrokeTransparency = 0.4
    label.Text = ""
    label.Parent = billboard

    billboard.Parent = char
    roleObjects[plr] = { Char = char, Billboard = billboard, Label = label }
    return roleObjects[plr]
end

-- Wrapped in pcall for the same reason the silent-aim loop is: an
-- unprotected background loop dies silently and permanently the first
-- time anything in it throws, and there's nothing left afterward to
-- restart it.
spawnLoop(function()
    while not Unloading do
        task.wait(0.4)

        local ok = pcall(function()
            if Visual.Enabled then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer then
                        local char = plr.Character
                        local obj = espObjects[plr]
                        if not char then
                            if obj then destroyEsp(plr) end
                        elseif not obj or obj.Char ~= char then
                            buildEsp(plr, char)
                        else
                            local color = espColorFor(plr)
                            obj.Highlight.FillColor = color
                            obj.Highlight.OutlineColor = color
                        end
                    end
                end
            else
                for plr in pairs(espObjects) do destroyEsp(plr) end
            end

            -- Role ESP: only for a player who currently HAS a role (they're
            -- in this round) and isn't dead, and never for the local
            -- player - they already know their own role from the game's
            -- own reveal screen.
            if Visual.RoleESP then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr == LocalPlayer then
                        if roleObjects[plr] then destroyRoleLabel(plr) end
                    else
                        local char = plr.Character
                        local entry = RoundData[plr.Name]
                        local hasRole = entry ~= nil and entry.Role ~= nil and entry.Dead ~= true

                        if not char or not hasRole then
                            if roleObjects[plr] then destroyRoleLabel(plr) end
                        else
                            local obj = roleObjects[plr]
                            if not obj or obj.Char ~= char then
                                obj = buildRoleLabel(plr, char)
                            end
                            if obj then
                                local text = entry.Role
                                -- The murderer's perk, and only on the
                                -- murderer's own label - entry is this
                                -- specific player's round data, so this can
                                -- never leak onto anyone else's head.
                                if Visual.ShowMurdererPerk and entry.Role == "Murderer" and entry.Perk then
                                    text = text .. " (" .. tostring(entry.Perk) .. ")"
                                end
                                obj.Label.Text = text
                                obj.Label.TextColor3 = ROLE_COLORS[entry.Role] or DEFAULT_ESP_COLOR
                            end
                        end
                    end
                end
            else
                for plr in pairs(roleObjects) do destroyRoleLabel(plr) end
            end
        end)

        if not ok then
            for plr in pairs(espObjects) do destroyEsp(plr) end
            for plr in pairs(roleObjects) do destroyRoleLabel(plr) end
        end
    end
end)

track(Players.PlayerRemoving:Connect(function(plr)
    destroyEsp(plr)
    destroyRoleLabel(plr)
end))

--// X-ray ----------------------------------------------------------------------
-- Every BasePart within range of the local player gets pinned to the
-- slider's transparency - EXCEPT one that was already at least partly
-- see-through before x-ray ever touched it (glass, effects, windows: left
-- exactly as they were, never tracked, never overwritten) - and every part
-- x-ray HAS touched is tracked with its real, original transparency so it
-- can go back to looking normal the instant it leaves range or x-ray turns
-- off. Player characters are excluded from the sweep entirely; this is a
-- see-through-walls tool, not a way to make people invisible, and doing
-- that would fight visually with the player ESP above.
local Xray = {
    Enabled = false,
    Transparency = 0.5,
    Range = 100,
}

local xrayObjects = {} -- [part] = original transparency (always 0 - see above)

local xrayOverlapParams = OverlapParams.new()
xrayOverlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function xrayRestore(part, original)
    if part and part.Parent then
        pcall(function() part.Transparency = original end)
    end
end

local function xrayRestoreAll()
    for part, original in pairs(xrayObjects) do
        xrayRestore(part, original)
    end
    table.clear(xrayObjects)
end

local function xrayFilterList()
    local list = {}
    local char = LocalPlayer.Character
    if char then list[#list + 1] = char end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then list[#list + 1] = plr.Character end
    end
    return list
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)

        if not Xray.Enabled then
            if next(xrayObjects) then xrayRestoreAll() end
        else
            local ok = pcall(function()
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not root then
                    xrayRestoreAll()
                    return
                end

                xrayOverlapParams.FilterDescendantsInstances = xrayFilterList()
                local parts = Workspace:GetPartBoundsInRadius(root.Position, Xray.Range, xrayOverlapParams)

                local seen = {}
                for _, part in ipairs(parts) do
                    if part:IsA("BasePart") and part.Parent then
                        seen[part] = true
                        if xrayObjects[part] == nil then
                            -- entering range for the first time - only take
                            -- it over if it started fully opaque
                            if part.Transparency == 0 then
                                xrayObjects[part] = 0
                                part.Transparency = Xray.Transparency
                            end
                        elseif part.Transparency ~= Xray.Transparency then
                            -- already tracked - keep it pinned to whatever
                            -- the slider currently says
                            part.Transparency = Xray.Transparency
                        end
                    end
                end

                for part, original in pairs(xrayObjects) do
                    if not seen[part] then
                        xrayRestore(part, original)
                        xrayObjects[part] = nil
                    end
                end
            end)

            if not ok then xrayRestoreAll() end
        end
    end
end)

--// Trap ESP ---------------------------------------------------------------------
-- TrapScriptClient (see the dump) parents every placed trap's visual as a
-- part literally named "TrapVisual" - `p2.TrapVisual.CFrame`,
-- `.Transparency`, both read and written by the game's own trap-hit and
-- trap-placed handlers. Watching for anything with that exact name is
-- exactly what the game's own trap code keys off, not a guess at a naming
-- convention.
local TrapEsp = { Enabled = false }
local trapObjects = {} -- [TrapVisual part] = Highlight

local function isTrapVisual(inst)
    return typeof(inst) == "Instance" and inst.Name == "TrapVisual" and inst:IsA("BasePart")
end

local function destroyTrapEsp(part)
    local hl = trapObjects[part]
    if hl then hl:Destroy() end
    trapObjects[part] = nil
end

local function buildTrapEsp(part)
    if trapObjects[part] then return end
    local hl = Instance.new("Highlight")
    hl.FillColor = Color3.fromRGB(255, 170, 0)
    hl.OutlineColor = Color3.fromRGB(255, 170, 0)
    hl.FillTransparency = 0.3
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = part
    trapObjects[part] = hl
end

local function trapEspRefreshAll()
    for part in pairs(trapObjects) do destroyTrapEsp(part) end
    if not TrapEsp.Enabled then return end
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if isTrapVisual(inst) then buildTrapEsp(inst) end
    end
end

track(Workspace.DescendantAdded:Connect(function(inst)
    if TrapEsp.Enabled and isTrapVisual(inst) then
        buildTrapEsp(inst)
    end
end))

track(Workspace.DescendantRemoving:Connect(function(inst)
    if trapObjects[inst] then destroyTrapEsp(inst) end
end))

local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })

local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'esp',
    Desc = 'highlights every other player',
    Flag = 'mm2_esp',
    Callback = function(state) Visual.Enabled = state end,
})

EspSection:Toggle({
    Title = 'color by role',
    Desc = "esp color follows each player's current role (innocent/sheriff/murderer, or infection/freeze tag) instead of a flat color",
    Flag = 'mm2_esp_role_color',
    Callback = function(state) Visual.ColorByRole = state end,
})

local RoleEspSection = VisualTab:Section({ Title = 'role esp', Side = 'right' })

RoleEspSection:Toggle({
    Title = 'role esp',
    Desc = "shows each player's role above their head - only while they're alive and actually have a role this round, never on you",
    Flag = 'mm2_role_esp',
    Callback = function(state) Visual.RoleESP = state end,
})

RoleEspSection:Toggle({
    Title = "show murderer's perk",
    Desc = "appends the murderer's currently active perk to their label only - nobody else's",
    Flag = 'mm2_role_esp_perk',
    Callback = function(state) Visual.ShowMurdererPerk = state end,
})

local XraySection = VisualTab:Section({ Title = 'xray', Side = 'left' })

XraySection:Toggle({
    Title = 'xray',
    Desc = 'fades every opaque part within range so you can see through them - anything already partly see-through (glass, effects) is left alone entirely',
    Flag = 'mm2_xray',
    Callback = function(state)
        Xray.Enabled = state
        if not state then xrayRestoreAll() end
    end,
})

XraySection:Slider({
    Title = 'xray transparency',
    Desc = 'what every affected part gets set to - 1 makes them fully invisible, lower keeps a faint outline of the geometry',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = Xray.Transparency,
    Flag = 'mm2_xray_transparency',
    Callback = function(value)
        Xray.Transparency = value
        for part in pairs(xrayObjects) do
            if part and part.Parent then
                pcall(function() part.Transparency = value end)
            end
        end
    end,
})

XraySection:Slider({
    Title = 'xray range',
    Desc = 'radius around you that gets swept for opaque parts',
    Min = 20,
    Max = 300,
    Increment = 10,
    Default = Xray.Range,
    Suffix = ' studs',
    Flag = 'mm2_xray_range',
    Callback = function(value) Xray.Range = value end,
})

local TrapSection = VisualTab:Section({ Title = 'traps', Side = 'right' })

TrapSection:Toggle({
    Title = 'trap esp',
    Desc = 'highlights every placed trap (TrapVisual, the same part name the game\'s own trap scripts read and write) so you can see and avoid them',
    Flag = 'mm2_trap_esp',
    Callback = function(state)
        TrapEsp.Enabled = state
        trapEspRefreshAll()
    end,
})

local SessionSection = VisualTab:Section({ Title = 'session', Side = 'right' })

SessionSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end

        for plr in pairs(espObjects) do destroyEsp(plr) end
        for plr in pairs(roleObjects) do destroyRoleLabel(plr) end
        for part in pairs(trapObjects) do destroyTrapEsp(part) end
        xrayRestoreAll()

        Centrl:Unload()
    end,
})

SessionSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every hook and loop, restores every part xray touched, clears all esp, then closes the menu. The Shoot/KnifeThrown namecall hook cannot be reversed without rejoining.',
})

Window:Load()

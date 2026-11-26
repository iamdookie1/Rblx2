--// OPERATION ONE ------------------------------------------------------------------------------
-- place 72920620366355 (game 8307114974), built against version 2045. Built on Ui3.
-- Works with mouse and touch: nothing here needs a mouse, the shoot button or a key.
--
-- How the game works (as the client shows it, from the dump):
--   Bodies     Every player is a Model in Workspace tagged "Character" with attributes Team
--              ("Red" / "Blue"), UserId, ID, Revealed. It keeps a Humanoid (real Health) and a
--              HumanoidRootPart, but the visible body is ten anchored parts (head, torso, leg1,
--              leg2, arm1, arm2, shoulder1, shoulder2, hip1, hip2) that setup_viewmodels moves
--              into Workspace.Viewmodels.Viewmodel[n]. Yours is LocalViewmodel. Dead players'
--              models go to ReplicatedStorage.Garbage.
--   Players    Found in the world, not in the game's modules: models tagged "Character" in
--              Workspace, each with a "Character" Configuration holding equipped (ObjectValue,
--              the gun model, which sits inside that player's Viewmodel), look (Vector3Value),
--              class_name (StringValue).
--   State      The game's code runs inside an Actor (PlayerScripts.Folder, holding the Loader), which
--              is its own Luau VM: getgc from the executor's VM never sees its tables, `shared` is
--              empty there while the game uses shared.extras, and require() from outside gives a
--              fresh copy whose StateObject.classes is empty (the dump shows {} there). So the
--              live module (a table with get_all, class and a non-empty classes) is found by an
--              agent run inside the Actor with run_on_actor, which does everything that touches
--              your own gun and reports back over comm channels (see AGENT). Inside it:
--                get_all("Character")[yourModel].values.equipped   your gun's item object
--                                                                  (.states, .instance, .shoot_hold)
--   Camera     CameraType stays Custom: Roblox's own camera module turns the view from mouse or
--              touch, then Character.render_camera layers lean / recoil / bobbing on top and takes
--              the same offset off again next frame. Rotating Camera.CFrame after all of that
--              (late render step) is what the game's own input does too, on every device.
--   Shots      Gun.send_shoot calls item:get_shoot_look() for the muzzle CFrame. Because guns are
--              client_sided_hitscan it traces the rays itself from that CFrame (spread included)
--              and fires states.shoot:fire_instant(look, hits). Whatever get_shoot_look returns is
--              both where the rays go and the look that is sent. That is the one place silent aim
--              needs: this script wraps get_shoot_look on the gun in your hand.
--   Bullets    send_shoot casts the rays itself with ray_damage. A bullet starts at the muzzle (kept
--              within 3 studs of the camera by validate_position) and points along item.shot (the
--              barrel's Shoot part) blended toward the front sight by item.accuracy.Value. It passes
--              anything you can't collide with and "Soft" parts (two at most), and stops at solid,
--              "Hard" and invisible-but-collidable parts. Targets.clear ports those rules, so
--              "visible" here means a bullet can reach the point, not that a plain raycast can: a
--              plain raycast also stops at trails, triggers and other parts bullets fly through.
--              Spread is added around the look after get_shoot_look, so a redirected shot still
--              scatters unless the gun's spread is zero (silent aim zeroes it for that shot).
--   Firing     item:input_shoot(down) is what the fire button, the mouse and the mobile joystick
--              all call; item.shoot_hold is true while a shot is held; item.states.sights is ADS.
--   Gun states Numbers in item.states[x].value: recoil_up, recoil_side, spread, firerate, ads
--              (seconds to aim), reload_speed (higher is faster). The game reads .value locally.
--   Speed      Humanoid.WalkSpeed = states.speed x held item speed x states.speed_multiplier.
--   Teams      Player and Character attribute Team, colours in game.Teams[team]:GetAttribute("Color").
--              Workspace attributes Gamemode, CurrentMap, Round, BestOf, DefuserAvailable.
--   Tags       Claymore, NeedleMine, ProximityAlarm, RemoteC4, ThermiteCharge, BreachCharge,
--              HardBreachCharge, IncendiaryCanister, ToxicCharge, ShockBattery, SignalDisruptor,
--              BarbedWire, StickyCamera, BulletproofCamera, Drone, DeployableShield, the grenades
--              (Frag, Smoke, Stun, EMP, Impact, Incendiary, Launched) and Bomb (Root part).
--   Smoke      Smoke grenades clone their script.SmokePart into Workspace.
--   Bomb       The defuser is tagged Defuser (Root part). A player carrying it has the attribute
--              HasDefuser on their Player; once planted, the instance has Planted = true and the game
--              counts down 40 seconds on the client (paused while Workspace has frozen_time).
--   Players    Each player's Character config also replicates walk_state ("stand", "crouch", "prone"),
--              running, walking, look (where they face), vault, climbing and spotted: what the route
--              planner reads to guess who can see or hear you.
--   Movement   Speed is the base (about 7.9) x 1.5 running, x 0.9 walking, x 0.5 crouched, x 0.3 prone,
--              halved again when walking quietly. Vaulting uses the game's own checks (RespectCanCollide
--              raycasts in the "weak" collision group), which the planner copies.
--   Hits       The game raises its own hit marker from your local rays; the extra hit feedback here
--              watches enemies' health instead and credits drops that follow one of your shots.
--
-- No remote is fired. The ESP and circles are Drawing objects, the aimbot only turns your camera,
-- the gun changes are local values the game's own client reads. Silent aim changes the look and
-- hit list your client reports with each shot: what the server does with a look that is not where
-- your camera points is the one thing the dump cannot show, so test it before a match that matters.
-- The game has player reports ("cheating") and a ranked queue.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__OperationOneUnload then
    pcall(Genv.__OperationOneUnload)
end
Genv.__OperationOneRun = (Genv.__OperationOneRun or 0) + 1
local RUN = Genv.__OperationOneRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__OperationOneRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local Settings = {
    -- aimbot (turns the camera)
    Aimbot = false, AimWhen = IsTouch and "While shooting" or "Aiming down sights", AimPart = "Head",
    AimFOV = 140, ShowFOV = true, Smoothness = 4, AimMaxDistance = 250, VisibleOnly = true,
    StickyTarget = true, AimTeammates = false, RecoilAware = true,
    -- silent aim (the shot goes to the target, the camera stays)
    SilentAim = false, SilentPart = "Head", SilentFOV = 200, SilentShowFOV = true, SilentHitChance = 100,
    SilentMaxDistance = 250, SilentVisible = true, SilentLook = false, SilentNoSpread = true,
    -- targeting (aimbot, silent aim)
    PartlyVisible = true, AnyBodyPart = true, AimThroughWalls = false, GunRange = false, RangeScale = 2,
    -- triggerbot
    Triggerbot = false, TriggerDelay = 60, TriggerHeadOnly = false, TriggerOnlyAiming = not IsTouch,
    TriggerMaxDistance = 250,
    -- gun
    NoRecoil = false, NoSpread = false, RapidFire = false, RapidScale = 1.5, FastAds = false,
    FastReload = false, ReloadScale = 1.6, AutoReload = false,
    -- player
    SpeedHack = false, SpeedScale = 1.2,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspHealth = true, EspDistance = true, EspWeapon = true,
    EspClass = false, EspSkeleton = false, EspLook = false, EspTracer = false, EspTeammates = false,
    EspChams = false, EspMax = 600,
    UtilTraps = false, UtilCameras = false, UtilGrenades = false, BombEsp = false, UtilMax = 250,
    -- world
    Fullbright = false, NoFlash = false, NoSmoke = false, FovChanger = false, FovValue = 80,
    -- esp extras
    EspReachable = true, ReachVisible = Color3.fromRGB(80, 255, 110), ReachWall = Color3.fromRGB(255, 210, 60),
    ReachHidden = Color3.fromRGB(255, 70, 70),
    EspArrows = true, ArrowAlways = false, ArrowRadius = 0.42, ArrowSize = 16, ArrowMax = 600, ArrowDistance = true,
    WallEsp = false, WallSoft = true, WallBreakable = true, WallHard = false, WallMax = 60, WallCount = 40,
    WallAlpha = 0.7, WallSoftColor = Color3.fromRGB(90, 255, 140), WallBreakColor = Color3.fromRGB(255, 160, 50),
    WallHardColor = Color3.fromRGB(255, 80, 80),
    BombTimer = true, BombCarrier = true,
    HitMarkers = true, HitNumbers = true, HitSounds = true, HitSize = 9, HitTime = 0.3, HitVolume = 0.6,
    KillSound = true, HitSoundId = "", KillSoundId = "",
    -- route planner (Help tab)
    Nav = false, NavGoal = "Defuser", NavStyle = "Balanced", NavTarget = "", NavMoveStyle = "Run", NavAlt = false,
    NavBaseSpeed = 7.9, NavVault = true, NavJump = true, NavDrop = true, NavCrouch = true, NavProne = false,
    NavBreach = false, NavVaultMax = 4, NavVaultMin = 1.3, NavVaultDepth = 3.5, NavStep = 1.4, NavJumpMax = 3.2,
    NavDropMax = 10, NavBodyW = 1.9, NavStandH = 5.2, NavCrouchH = 3.3, NavProneH = 1.6, NavVaultTime = 0.9,
    NavJumpTime = 0.5, NavBreachTime = 3,
    NavSight = 120, NavFov = 110, NavBehind = 0.25, NavUseLook = true, NavWallbang = true, NavWallbangW = 0.4,
    NavHear = 45, NavMuffle = 0.5,
    NavTimeW = 1, NavSightW = 6, NavNoiseW = 3, NavDwell = 3, NavTeamCover = 0.3, NavHighGround = 0.5,
    NavFirstStrike = 1, NavEngageMin = 10, NavEngageMax = 28, NavArrive = 4,
    NavCell = 3, NavRadius = 140, NavMaxNodes = 4000, NavGreed = 1.4, NavDetour = 2, NavBudget = 3, NavReplan = 1.5, NavDeviate = 6, NavSmooth = true,
    NavDraw = true, NavLabels = true, NavHud = true, NavThickness = 2, NavHeight = 0.5,
    -- misc
    AntiAfk = true, GunData = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "OPERATION ONE", Description = text, Time = seconds or 3 })
end
local function camera()
    return Workspace.CurrentCamera
end

--// The game's world \\--
-- Players are read from the world itself: characters are tagged "Character"; each has a
-- "Character" config with equipped / look / class_name values; the bodies sit in
-- Workspace.Viewmodels.
--
-- Your own gun (recoil, silent aim, reload...) needs the game's live state objects, and those are
-- not reachable from this VM. The game's code runs inside an Actor (PlayerScripts.Folder, holding
-- the obfuscated Loader) and an Actor is a separate Luau VM: getgc from here never sees its
-- tables, `shared` is empty here while the game itself uses shared.extras, and require() gives a
-- fresh copy whose StateObject.classes is empty (the dump shows exactly that). So a small agent
-- (AGENT, below) is run inside the Actor with run_on_actor. It finds the live module there,
-- applies the gun mods, hooks the shot, and talks to this script over two comm channels. If the
-- game isn't in an Actor (or the executor can't run code in one) the same agent runs in this VM.
-- What this script sees of your gun is a plain table the agent keeps sending: Game.gun().
local AGENT = [==[
-- AGENT. Runs where the game's own code runs: inside its Actor (a separate Luau VM, which is why
-- the script's own getgc can't see the game), or in the script's VM if the game isn't in an Actor.
-- It finds the game's live StateObject module, applies the gun mods, hooks get_shoot_look for
-- silent aim and reports the gun in your hand to the script. Arguments: up channel (or its id),
-- down channel (or its id), max scans, beacon key, up and down BindableEvent names, run number.
-- Messages go both ways over every route that works (the executor's comm channels and plain
-- BindableEvents the script left in a hidden container), each tagged with a sequence number so the
-- copy that arrives second is dropped. Progress is also written to an attribute (the beacon),
-- which needs no channel at all, so the script can see how far the agent got even if nothing
-- else gets through.
local upArg, downArg, maxTries, beaconKey, upName, downName, runId = ...
maxTries = tonumber(maxTries)

local beaconLines = 0
local function beacon(text)
    if not beaconKey then
        return
    end
    pcall(function()
        local inst = game:GetService("Lighting")
        local cur = inst:GetAttribute(beaconKey)
        cur = type(cur) == "string" and cur or ""
        local last = tonumber(cur:match("(%d+)|[^\n]*$")) or 0
        beaconLines = math.max(beaconLines, last) + 1
        cur = cur .. (cur == "" and "" or "\n") .. beaconLines .. "|" .. text
        if #cur > 1500 then
            cur = cur:sub(-1500):gsub("^[^\n]*\n", "")
        end
        inst:SetAttribute(beaconKey, cur)
    end)
end
local function kind(f)
    return type(f) == "function" and "yes" or "NO"
end
local hasExtras = false
pcall(function()
    hasExtras = shared.extras ~= nil
end)
beacon(("agent running; getgc=%s filtergc=%s get_comm_channel=%s gethui=%s shared.extras=%s"):format(
    kind(getgc), kind(filtergc), kind(get_comm_channel), kind(gethui), tostring(hasExtras)))

local ups, downs = {}, {}
local function addChannel(list, x, what)
    if type(x) == "string" then
        if type(get_comm_channel) ~= "function" then
            beacon(what .. ": get_comm_channel is not available here")
            return
        end
        local ok, ev = pcall(get_comm_channel, x)
        if ok and ev then
            table.insert(list, ev)
            beacon(what .. ": comm channel ok")
        else
            beacon(what .. ": get_comm_channel failed (" .. tostring(ev) .. ")")
        end
    elseif x ~= nil then
        table.insert(list, x)
    end
end
local function addBindable(list, name, what)
    if type(name) ~= "string" then
        return
    end
    local ok, ev = pcall(function()
        local box = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
        return box:FindFirstChild(name)
    end)
    if ok and ev then
        table.insert(list, ev)
        beacon(what .. ": BindableEvent ok")
    else
        beacon(what .. ": BindableEvent not found (" .. tostring(ev) .. ")")
    end
end
addChannel(ups, upArg, "up")
addChannel(downs, downArg, "down")
addBindable(ups, upName, "up")
addBindable(downs, downName, "down")
if #ups == 0 or #downs == 0 then
    beacon(("no way to talk to the script (up routes %d, down routes %d)"):format(#ups, #downs))
end
local upSeq = 0
local function say(...)
    upSeq += 1
    for _, ev in ups do
        pcall(ev.Fire, ev, upSeq, ...)
    end
end
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local LocalPlayer = Players.LocalPlayer
local Workspace = workspace

local alive = true
local conns = {}
local S = {} -- the script's settings, as last sent
local Aim = nil -- the silent aim target: { pos, part, name, at }
local SO = nil -- the game's live StateObject module
local rescan = false

--// Finding the game's live StateObject \\--
-- The live module is a table with get_all, class and a non-empty classes. It is found by scanning
-- this VM's memory. (require() is not used: it would run the game's modules a second time.)
local function live(m)
    if type(m) ~= "table" then
        return false
    end
    local classes = rawget(m, "classes")
    return type(classes) == "table" and type(rawget(m, "get_all")) == "function"
        and type(rawget(m, "class")) == "function" and next(classes) ~= nil
end
local function find()
    if type(filtergc) == "function" then
        local ok, res = pcall(filtergc, "table", { Keys = { "get_all", "class", "classes" } }, true)
        if ok then
            if live(res) then
                return res
            end
            if type(res) == "table" then
                for _, v in res do
                    if live(v) then
                        return v
                    end
                end
            end
        end
    end
    if type(getgc) ~= "function" then
        return nil, "this executor has no getgc"
    end
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then
        return nil, "getgc failed"
    end
    local empty = 0
    for i, v in list do
        if type(v) == "table" then
            if live(v) then
                return v
            end
            if type(rawget(v, "get_all")) == "function" and type(rawget(v, "class")) == "function"
                and type(rawget(v, "classes")) == "table" then
                empty += 1
            end
        end
        if i % 3000 == 0 then
            task.wait()
        end
    end
    return nil, ("scanned %d objects, %d StateObject-like table(s) with no classes yet"):format(#list, empty)
end

--// Your character and your gun \\--
local function me()
    local char = LocalPlayer.Character
    if not (SO and char) then
        return nil
    end
    local ok, all = pcall(SO.get_all, "Character")
    return ok and type(all) == "table" and all[char] or nil
end
local function gunOf(m)
    local item = m and m.values and m.values.equipped
    if type(item) == "table" and type(item.states) == "table" and item.states.recoil_up then
        return item
    end
    return nil
end
-- Where the next bullet would go, as a CFrame at the muzzle: the game's own get_shoot_look worked
-- out without calling it (it also resets some game state).
local function shotLook(item)
    local ok, cf = pcall(function()
        local shot = item.shot
        if typeof(shot) ~= "Instance" then
            return nil
        end
        local base = shot:IsA("Attachment") and shot.WorldCFrame or shot.CFrame
        local sight = item.reticule
        if typeof(sight) ~= "Instance" then
            local root = item.instance and item.instance:FindFirstChild("Root")
            sight = root and root:FindFirstChild("FrontSight", true)
        end
        local acc = item.accuracy and item.accuracy.Value
        if typeof(sight) == "Instance" and sight:IsA("Attachment") and type(acc) == "number" then
            return base:Lerp(sight.WorldCFrame, math.clamp(acc, 0, 1))
        end
        return base
    end)
    if ok and typeof(cf) == "CFrame" then
        return cf
    end
    return nil
end
local function gunRange(item)
    local st = type(item.states) == "table" and item.states.range
    local v = type(st) == "table" and st.value
    if type(v) ~= "number" then
        v = type(item.stats) == "table" and item.stats.range
    end
    return type(v) == "number" and v > 0 and v or nil
end
-- Where the game really starts a shot: the muzzle, but never more than 3 studs sideways from the
-- camera (its own validate_position).
local function shotOrigin(camPos, muzzle)
    local flat = Vector3.new(muzzle.X - camPos.X, 0, muzzle.Z - camPos.Z)
    if flat.Magnitude > 3 then
        local f = flat.Unit * 3
        return Vector3.new(camPos.X + f.X, muzzle.Y, camPos.Z + f.Z)
    end
    return muzzle
end

--// Gun mods (local values the game's own client reads) \\--
local Scaled = setmetatable({}, { __mode = "k" })
-- Multiplies a State's .value by `mult`, remembering what the game itself set so that a change the
-- game makes (equip, attachment, effect) becomes the new base.
local function scale(state, mult)
    if type(state) ~= "table" or type(state.value) ~= "number" then
        return
    end
    local rec = Scaled[state]
    if not rec then
        if mult == 1 then
            return
        end
        rec = { base = state.value, last = state.value }
        Scaled[state] = rec
    end
    if math.abs(state.value - rec.last) > 1e-4 then
        rec.base = state.value
    end
    rec.last = rec.base * mult
    state.value = rec.last
end
local function restore()
    for state, rec in Scaled do
        if type(state.value) == "number" and math.abs(state.value - rec.last) < 1e-4 then
            state.value = rec.base
        end
    end
end
local function mods(item, m)
    if item then
        local s = item.states
        scale(s.recoil_up, S.NoRecoil and 0 or 1)
        scale(s.recoil_side, S.NoRecoil and 0 or 1)
        scale(s.spread, S.NoSpread and 0 or 1)
        scale(s.firerate, S.RapidFire and (S.RapidScale or 1.5) or 1)
        scale(s.ads, S.FastAds and 0.15 or 1)
        scale(s.reload_speed, S.FastReload and (S.ReloadScale or 1.6) or 1)
    end
    if m then
        scale(m.states.speed_multiplier, S.SpeedHack and (S.SpeedScale or 1.2) or 1)
    end
end
-- Reloads on its own when the magazine is empty (the game's own reload, so it still takes the
-- normal time and its own checks apply).
local lastReload = 0
local function autoReload(item)
    if not (S.AutoReload and item) then
        return
    end
    if not (item.states.mag and item.states.bullets and type(item.prepare_reload) == "function") then
        return
    end
    if item.states.mag:get() <= 0 and item.states.bullets:get() > 0 and os.clock() - lastReload > 0.6 then
        lastReload = os.clock()
        pcall(item.prepare_reload, item)
    end
end
-- Zeroes the gun's spread for the shot being fired right now and puts it back straight after (the
-- game reads it in the same call, right after get_shoot_look).
local function noSpreadOnce(item)
    local st = item.states and item.states.spread
    if type(st) ~= "table" or type(st.value) ~= "number" or st.value == 0 then
        return
    end
    local prev = st.value
    st.value = 0
    task.defer(function()
        if st.value == 0 then
            st.value = prev
        end
    end)
end

--// Silent aim \\--
-- The script works out the target each frame and sends it; the shot is redirected here, in the
-- game's own call, so the rays and the look that is sent both go at the target.
local hooked = setmetatable({}, { __mode = "k" })
local function redirect(cf, item)
    if S.SilentHitChance and S.SilentHitChance < 100 and math.random() * 100 >= S.SilentHitChance then
        return cf
    end
    local a = Aim
    if not a or os.clock() - a.at > 0.4 then
        return cf
    end
    local cam = Workspace.CurrentCamera
    local origin = shotOrigin(cam.CFrame.Position, cf.Position)
    local dir = a.pos - origin
    if dir.Magnitude < 0.5 then
        return cf
    end
    if S.SilentLook then
        local m = me()
        if m and m.states.look then
            pcall(m.states.look.set, m.states.look, dir.Unit)
        end
    end
    if S.SilentNoSpread then
        noSpreadOnce(item)
    end
    say("redirect", a.name, a.part)
    return CFrame.lookAt(cf.Position, cf.Position + dir.Unit)
end
-- Only here while silent aim is on: the game guards get_shoot_look (it calls shared.extras.ResetEnv()
-- inside it), so it is left alone otherwise. If the game's own function objects to being called through
-- the hook, the same maths is used instead, so a shot is never lost; the problem is reported.
local hookError = nil
local function attach(item)
    if hooked[item] then
        return
    end
    local orig = item.get_shoot_look
    if type(orig) ~= "function" then
        return
    end
    hooked[item] = true
    rawset(item, "get_shoot_look", function(self, ...)
        local ok, cf = pcall(orig, self, ...)
        if not ok then
            local err = cf
            if not hookError then
                hookError = tostring(err)
                say("log", "get_shoot_look failed under the shot hook: " .. hookError)
                beacon("get_shoot_look failed under the shot hook: " .. hookError)
            end
            cf = shotLook(self)
            if typeof(cf) ~= "CFrame" then
                error(err, 0)
            end
        end
        if not (alive and S.SilentAim) then
            return cf
        end
        local ok2, res = pcall(redirect, cf, self)
        if ok2 and typeof(res) == "CFrame" then
            return res
        end
        return cf
    end)
end
local function detach()
    for item in hooked do
        pcall(rawset, item, "get_shoot_look", nil)
    end
    table.clear(hooked)
end
-- Shots are told from the gun's own last_shot time, which the game sets on every shot: no hook needed.
local lastSeen = setmetatable({}, { __mode = "k" })
local function watchShots(item)
    local t = item.last_shot
    if type(t) ~= "number" then
        return
    end
    local prev = lastSeen[item]
    lastSeen[item] = t
    if prev ~= nil and t ~= prev then
        say("shot")
    end
end

--// Trigger: one tap of the game's own shoot \\--
local function fire()
    local item = gunOf(me())
    if not (item and type(item.input_shoot) == "function") then
        return
    end
    -- input_shoot also puts the sights up on a press and down on a release when the game's own
    -- "auto ADS" setting is on, which would drop your aim after every shot. Put them back if they
    -- were up.
    local sights = item.states.sights
    local wasUp = sights ~= nil and sights:get() == true
    pcall(item.input_shoot, item, true)
    task.delay(0.04, function()
        pcall(item.input_shoot, item, false)
        if wasUp and sights:get() ~= true and type(item.input_ads) == "function" then
            pcall(item.input_ads, item, true, true)
        end
    end)
end

--// What the script sees of your gun \\--
local function snapshot(item)
    local s = item.states
    local function num(st)
        return type(st) == "table" and type(st.value) == "number" and st.value or nil
    end
    return {
        name = item.instance and item.instance.Name or "gun",
        sights = s.sights ~= nil and s.sights:get() == true,
        shoot = item.shoot_hold == true,
        shot = shotLook(item),
        range = gunRange(item),
        recoil_up = num(s.recoil_up),
        recoil_side = num(s.recoil_side),
        spread = num(s.spread),
        firerate = num(s.firerate),
        hooked = hooked[item] == true,
        hookError = hookError,
    }
end

local stepError = false
local function step()
    local m = me()
    local item = gunOf(m)
    mods(item, m)
    autoReload(item)
    if item then
        if S.SilentAim then
            attach(item)
        end
        watchShots(item)
    end
    if not S.SilentAim and next(hooked) ~= nil then
        detach()
    end
    say("state", item and snapshot(item) or false)
end

local function shutdown()
    if not alive then
        return
    end
    alive = false
    for _, c in conns do
        pcall(c.Disconnect, c)
    end
    pcall(restore)
    detach()
    say("stopped")
end
-- An older agent in this VM (the script was run again) is stopped first.
-- An agent left in this VM by an earlier run of the script (not one of this run's own) is stopped.
pcall(function()
    local prev = shared.__OperationOneAgent
    if type(prev) == "table" and prev.run ~= runId and type(prev.stop) == "function" then
        prev.stop()
    end
    shared.__OperationOneAgent = { stop = shutdown, run = runId }
end)

local function onFrame()
    if not alive or not SO then
        return
    end
    local ok, err = pcall(step)
    if not ok and not stepError then
        stepError = true
        say("log", "step: " .. tostring(err))
        beacon("step error: " .. tostring(err))
    end
end
local okFrame, frameConn = pcall(function()
    return RunService.RenderStepped:Connect(onFrame)
end)
if not okFrame then
    say("log", "RenderStepped not available here, using Heartbeat")
    frameConn = RunService.Heartbeat:Connect(onFrame)
end
conns[#conns + 1] = frameConn
local seenDown = {}
local function onDown(seq, what, a, b, c)
    if seenDown[seq] then
        return
    end
    seenDown[seq] = true
    seenDown[seq - 300] = nil
    if what == "cfg" then
        if type(a) == "table" then
            S = a
        end
    elseif what == "aim" then
        if typeof(a) == "Vector3" then
            Aim = { pos = a, part = b, name = c, at = os.clock() }
        else
            Aim = nil
        end
    elseif what == "fire" then
        pcall(fire)
    elseif what == "rescan" then
        rescan = true
    elseif what == "stop" then
        shutdown()
    end
end
for _, ev in downs do
    conns[#conns + 1] = ev.Event:Connect(onDown)
end

-- Does the live module still describe the game? It goes stale if the game rebuilds its modules, or
-- if you have a tagged character that it no longer knows.
local staleSince = nil
local function stale()
    local char = LocalPlayer.Character
    if not (char and CollectionService:HasTag(char, "Character")) or me() then
        staleSince = nil
        return false
    end
    staleSince = staleSince or os.clock()
    return os.clock() - staleSince > 5
end

say("hello")
beacon(("hello sent; listening on %d route(s), reporting on %d"):format(#downs, #ups))
task.spawn(function()
    local delay, tries = 1, 0
    while alive do
        if SO == nil then
            tries += 1
            local m, why = find()
            if m then
                SO = m
                delay = 1
                say("found", tries)
                beacon(("found the live StateObject on scan %d"):format(tries))
            else
                say("miss", tries, why)
                if tries == 1 or tries % 4 == 0 then
                    beacon(("scan %d: %s"):format(tries, tostring(why)))
                end
                if maxTries and maxTries > 0 and tries >= maxTries then
                    say("gaveup", tries)
                    return
                end
                local waited = 0
                while alive and waited < delay and not rescan do
                    task.wait(0.25)
                    waited += 0.25
                end
                rescan = false
                delay = math.min(delay * 2, 15)
            end
        else
            task.wait(1)
            if not live(SO) or stale() then
                SO = nil
                pcall(restore)
                tries, delay = 0, 1
                say("lost")
                beacon("the live StateObject went stale, searching again")
            end
        end
    end
end)
]==]

-- What is run inside an Actor: a tiny plain-Lua bootstrap that reports (through the beacon) that it
-- ran, whether the agent compiled there, and whether it crashed, then starts the agent. Nothing
-- depends on run_on_actor passing arguments: the values are written into the source.
local BOOT_HEAD = [==[
local function beacon(text)
    pcall(function()
        local inst = game:GetService("Lighting")
        local cur = inst:GetAttribute(KEY)
        cur = type(cur) == "string" and cur or ""
        local n = (tonumber(cur:match("(%d+)|[^\n]*$")) or 0) + 1
        inst:SetAttribute(KEY, cur .. (cur == "" and "" or "\n") .. n .. "|" .. text)
    end)
end
beacon("bootstrap ran")
local compile = loadstring or load
if not compile then
    beacon("this VM has no loadstring or load")
    return
end
local fn, compileError = compile(SRC, "=OperationOneAgent")
if not fn then
    beacon("the agent did not compile here: " .. tostring(compileError))
    return
end
local ok, err = pcall(fn, UPID, DOWNID, TRIES, KEY, UPNAME, DOWNNAME, RUNID)
if not ok then
    beacon("the agent crashed: " .. tostring(err))
end
]==]
local function lit(x)
    return x ~= nil and ("%q"):format(x) or "nil"
end
local function bootSource(key, upId, downId, tries, upName, downName)
    return table.concat({
        "local KEY, UPID, DOWNID, TRIES, UPNAME, DOWNNAME, RUNID = ", lit(key), ", ", lit(upId), ", ", lit(downId), ", ",
        tostring(tries), ", ", lit(upName), ", ", lit(downName), ", ", tostring(RUN), "\n",
        "local SRC = [=====[\n", AGENT, "\n]=====]\n",
        BOOT_HEAD,
    })
end

local Game = {
    found = false, mode = nil, active = nil, searching = false,
    state = nil, stateAt = 0, heard = 0, detail = nil,
    onFound = nil, onRedirect = nil, onShot = nil, lastShot = -10,
}
do
    local agents, lines = {}, {}
    local clock0, lastStart, cfgAt, beaconAt, onUp = os.clock(), -10, 0, 0, nil
    local cfgLast = {}
    -- The settings the agent needs, sent whenever one changes.
    local CFG = {
        "NoRecoil", "NoSpread", "RapidFire", "RapidScale", "FastAds", "FastReload", "ReloadScale", "AutoReload",
        "SpeedHack", "SpeedScale", "SilentAim", "SilentHitChance", "SilentLook", "SilentNoSpread",
    }

    local function log(text)
        table.insert(lines, ("[%5.1fs] %s"):format(os.clock() - clock0, text))
        if #lines > 80 then
            table.remove(lines, 1)
        end
    end
    Game.log = log
    -- Messages go over every route the agent was given, tagged with a number so the copy that
    -- arrives second is dropped.
    local function send(agent, ...)
        agent.seq = (agent.seq or 0) + 1
        for _, ev in agent.downs do
            pcall(ev.Fire, ev, agent.seq, ...)
        end
    end
    local function stopAgent(agent)
        if agent.dead then
            return
        end
        agent.dead = true
        send(agent, "stop")
        for _, c in agent.conns do
            pcall(c.Disconnect, c)
        end
        -- Left in place a moment so the stop message gets through.
        task.delay(2, function()
            for _, inst in agent.owned do
                pcall(inst.Destroy, inst)
            end
            if agent.key then
                pcall(function()
                    game:GetService("Lighting"):SetAttribute(agent.key, nil)
                end)
            end
        end)
    end
    local function listen(agent, ev)
        local ok, conn = pcall(function()
            return ev.Event:Connect(function(...)
                onUp(agent, ...)
            end)
        end)
        if ok and conn then
            table.insert(agent.conns, conn)
        end
        return ok
    end

    function Game.pushCfg(force)
        local agent = Game.active
        if not agent then
            return
        end
        local changed = force
        for _, k in CFG do
            if cfgLast[k] ~= Settings[k] then
                changed = true
                break
            end
        end
        if not changed then
            return
        end
        local t = {}
        for _, k in CFG do
            t[k] = Settings[k]
            cfgLast[k] = Settings[k]
        end
        send(agent, "cfg", t)
    end

    -- Everything an agent says arrives here.
    function onUp(agent, seq, kind, a, b)
        if agent.dead or type(seq) ~= "number" or agent.seen[seq] then
            return
        end
        agent.seen[seq] = true
        agent.seen[seq - 300] = nil
        if kind == "state" then
            if agent == Game.active then
                Game.state, Game.stateAt, Game.heard = a or nil, os.clock(), os.clock()
            end
        elseif kind == "redirect" then
            if agent == Game.active and Game.onRedirect then
                Game.onRedirect(a, b)
            end
        elseif kind == "shot" then
            Game.lastShot = os.clock()
            if agent == Game.active and Game.onShot then
                Game.onShot()
            end
        elseif kind == "found" then
            if Game.active == nil then
                Game.active, Game.found, Game.mode, Game.searching = agent, true, agent.kind, false
                Game.heard = os.clock()
                log(("%s: found the game's live data (scan %s), using it"):format(agent.label, tostring(a)))
                for _, other in agents do
                    if other ~= agent then
                        stopAgent(other)
                    end
                end
                table.clear(cfgLast)
                Game.pushCfg(true)
                if Game.onFound then
                    task.spawn(Game.onFound)
                end
            end
        elseif kind == "miss" then
            Game.detail = ("%s, scan %s: %s"):format(agent.label, tostring(a), tostring(b))
            if a == 1 or a % 4 == 0 then
                log(Game.detail)
            end
        elseif kind == "lost" then
            if agent == Game.active then
                log(agent.label .. ": the game's data went stale, searching again")
                Game.found, Game.active, Game.state = false, nil, nil
                lastStart = -10
                task.defer(Game.start)
            end
        elseif kind == "hello" then
            agent.hello = true
            log(agent.label .. ": agent is running")
        elseif kind == "gaveup" then
            log(agent.label .. ": gave up after " .. tostring(a) .. " scans")
        elseif kind == "log" then
            log(agent.label .. ": " .. tostring(a))
        end
    end

    local function launchLocal(maxTries)
        local agent = { kind = "local", label = "this VM", conns = {}, downs = {}, owned = {}, seen = {} }
        local fn, compileError = loadstring(AGENT)
        if type(fn) ~= "function" then
            log("the agent didn't compile here: " .. tostring(compileError))
            return
        end
        local up, down = Instance.new("BindableEvent"), Instance.new("BindableEvent")
        listen(agent, up)
        table.insert(agent.downs, down)
        table.insert(agents, agent)
        task.spawn(function()
            local ran, err = pcall(fn, up, down, maxTries, nil, nil, nil, RUN)
            if not ran then
                log("the agent crashed in this VM: " .. tostring(err))
            end
        end)
    end
    local actorCount = 0
    local function launchActor(actor)
        actorCount += 1
        local agent = { kind = "actor", conns = {}, downs = {}, owned = {}, seen = {} }
        agent.label = "actor " .. (actor.Parent and actor.Parent.Name .. "/" or "") .. actor.Name
        agent.key = ("oo%d_%d"):format(actorCount, math.random(100000, 999999))
        -- Two ways to reach the agent, both given to it: the executor's comm channels, and plain
        -- BindableEvents in a hidden container (these work between VMs without any executor help).
        local upId, downId, upName, downName
        if type(create_comm_channel) == "function" then
            local okA, idA, evA = pcall(create_comm_channel)
            local okB, idB, evB = pcall(create_comm_channel)
            if okA and okB and evA and evB and listen(agent, evA) then
                upId, downId = idA, idB
                table.insert(agent.downs, evB)
            else
                log(agent.label .. ": couldn't set up comm channels (" .. tostring(idA) .. ")")
            end
        end
        local okC, errC = pcall(function()
            local box = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
            local upB, downB = Instance.new("BindableEvent"), Instance.new("BindableEvent")
            upName, downName = agent.key .. "u", agent.key .. "d"
            upB.Name, downB.Name = upName, downName
            upB.Parent, downB.Parent = box, box
            table.insert(agent.owned, upB)
            table.insert(agent.owned, downB)
            listen(agent, upB)
            table.insert(agent.downs, downB)
        end)
        if not okC then
            log(agent.label .. ": couldn't make the hidden BindableEvents (" .. tostring(errC) .. ")")
        end
        if #agent.downs == 0 then
            log(agent.label .. ": no way to reach it, skipped")
            return
        end
        agent.launchedAt = os.clock()
        table.insert(agents, agent)
        local source = bootSource(agent.key, upId, downId, 0, upName, downName)
        local ran, err = pcall(run_on_actor, actor, source, upId, downId, 0, agent.key, upName, downName, RUN)
        if ran then
            log(("%s: sent the agent (%d routes: %s)"):format(agent.label, #agent.downs,
                (upId and "comm channel" or "no comm channel") .. (upName and " + BindableEvents" or "")))
        else
            log(agent.label .. ": run_on_actor failed (" .. tostring(err) .. ")")
            stopAgent(agent)
        end
    end

    -- Starts (or restarts) the search: an agent in every Actor, plus one in this VM.
    function Game.start(onFound)
        if onFound then
            Game.onFound = onFound
        end
        if not Settings.GunData then
            return
        end
        if os.clock() - lastStart < 2 then
            return
        end
        lastStart = os.clock()
        for _, a in agents do
            stopAgent(a)
        end
        table.clear(agents)
        Game.found, Game.active, Game.state, Game.mode, Game.detail = false, nil, nil, nil, nil
        Game.searching = true
        local canActor = type(getactors) == "function" and type(run_on_actor) == "function"
        local actors = {}
        if canActor then
            local ok, list = pcall(getactors)
            if ok and type(list) == "table" then
                actors = list
            else
                log("getactors failed: " .. tostring(list))
            end
        end
        log(("searching: %d actor(s); running code in actors is %s"):format(
            #actors, canActor and "supported" or "NOT supported by this executor"))
        -- This VM first (a couple of scans when there are Actors to try, otherwise for as long as
        -- it takes), then every Actor.
        launchLocal(#actors > 0 and 2 or 0)
        for _, actor in actors do
            launchActor(actor)
        end
    end

    -- Every frame: settings to the agent, and a search restart if the agent has gone quiet.
    function Game.pump()
        local now = os.clock()
        if not Settings.GunData then
            -- switched off: nothing of ours is running inside the game
            if #agents > 0 or Game.found then
                Game.stop()
            end
            return
        elseif #agents == 0 and not Game.found then
            lastStart = -10
            Game.start()
            return
        end
        if Game.found and now - Game.heard > 4 then
            log("lost contact with the agent, searching again")
            Game.found, Game.active, Game.state = false, nil, nil
            lastStart = -10
            Game.start()
            return
        end
        if Game.active and now - cfgAt > 0.2 then
            cfgAt = now
            Game.pushCfg(false)
        end
        -- The beacons: what each Actor agent wrote to its attribute, readable even when no channel
        -- works. Every new line goes in the report.
        if now - beaconAt > 0.4 then
            beaconAt = now
            for _, a in agents do
                if a.key and not a.dead then
                    local ok, text = pcall(function()
                        return game:GetService("Lighting"):GetAttribute(a.key)
                    end)
                    if ok and type(text) == "string" then
                        for line in text:gmatch("[^\n]+") do
                            local n, msg = line:match("^(%d+)|(.*)$")
                            n = tonumber(n)
                            if n and n > (a.beaconN or 0) then
                                a.beaconN = n
                                log(a.label .. " [beacon]: " .. msg)
                            end
                        end
                    end
                end
            end
        end
        -- An Actor agent that never says hello.
        for _, a in agents do
            if a.launchedAt and not a.hello and not a.warned and not a.dead and now - a.launchedAt > 6 then
                a.warned = true
                if (a.beaconN or 0) == 0 then
                    log(a.label .. ": nothing from the agent after 6s, not even a beacon: the code was never run there")
                else
                    log(a.label .. ": the agent ran (see its beacon lines) but nothing it sent reached this script")
                end
            end
        end
    end

    function Game.live()
        return Game.found and os.clock() - Game.heard < 3
    end
    -- The gun in your hand as the agent last saw it (a plain table: name, sights, shoot, shot, range,
    -- recoil_up, recoil_side, spread, firerate), or nil.
    function Game.gun()
        local st = Game.state
        if st and os.clock() - Game.stateAt < 0.5 then
            return st
        end
        return nil
    end
    -- Where your gun's next bullet would go (a CFrame at the muzzle), or nil.
    function Game.shotLook(item)
        return item and item.shot or nil
    end
    function Game.gunRange(item)
        return item and item.range or nil
    end
    function Game.fire()
        if Game.active then
            send(Game.active, "fire")
        end
    end
    function Game.aim(pos, part, name)
        if Game.active then
            send(Game.active, "aim", pos or false, part or "", name or "")
        end
    end
    function Game.stop()
        for _, a in agents do
            stopAgent(a)
        end
        table.clear(agents)
        Game.found, Game.active, Game.state = false, nil, nil
    end

    -- One line for the status labels.
    function Game.statusText()
        if not Settings.GunData then
            return "Gun data: switched off (nothing of this script runs inside the game)"
        end
        if Game.live() then
            return Game.mode == "actor" and "Gun data: found (inside the game's Actor)" or "Gun data: found"
        end
        if Game.found then
            return "Gun data: lost, searching again..."
        end
        if #agents == 0 then
            return "Gun data: not found. Tap Search again; Copy report shows why"
        end
        return "Gun data: searching... " .. (Game.detail and ("(" .. Game.detail .. ")") or "")
    end
    -- Everything useful for working out why the search failed, for the clipboard.
    function Game.report()
        local function has(f)
            return type(f) == "function" and "yes" or "NO"
        end
        local out = {
            "Operation One gun-data report",
            ("executor functions: getgc %s, filtergc %s, getactors %s, run_on_actor %s, create_comm_channel %s, gethui %s, loadstring %s"):format(
                has(getgc), has(filtergc), has(getactors), has(run_on_actor), has(create_comm_channel), has(gethui), has(loadstring)),
            ("state: found=%s mode=%s live=%s agents=%d"):format(
                tostring(Game.found), tostring(Game.mode), tostring(Game.live()), #agents),
        }
        for _, l in lines do
            table.insert(out, l)
        end
        return table.concat(out, "\n")
    end

    function Game.teamColor(name)
        local t = name and game:GetService("Teams"):FindFirstChild(name)
        local c = t and t:GetAttribute("Color")
        if typeof(c) == "Color3" then
            return c
        end
        if t and typeof(t.TeamColor) == "BrickColor" then
            return t.TeamColor.Color
        end
        return nil
    end
    table.insert(Cleanups, Game.stop)
end

--// Who is a target \\--
local Targets = {}
do
    local ENEMY, TEAM = Color3.fromRGB(255, 70, 70), Color3.fromRGB(90, 170, 255)
    local cache, cacheAt = nil, 0
    local owners = {} -- body (viewmodel) -> its entry in the cached list
    Targets.owners = owners

    -- A value from a player's "Character" config (equipped, look, class_name, ...).
    function Targets.charValue(model, name)
        local c = model:FindFirstChild("Character")
        local v = c and c:FindFirstChild(name)
        return v and v.Value
    end
    function Targets.teammate(model)
        local mine, theirs = LocalPlayer:GetAttribute("Team"), model:GetAttribute("Team")
        return mine ~= nil and mine ~= "" and mine == theirs
    end
    function Targets.color(model, team)
        return Game.teamColor(model:GetAttribute("Team")) or (team and TEAM or ENEMY)
    end

    -- Every other living player in the world: model, humanoid, root, body (vm) and team flag.
    -- The body is the Viewmodel their equipped gun sits in, or else the one nearest their root.
    function Targets.all()
        local now = os.clock()
        if cache and now - cacheAt < 0.03 then
            return cache
        end
        local out = {}
        table.clear(owners)
        local mine = LocalPlayer.Character
        local folder = Workspace:FindFirstChild("Viewmodels")
        local bodies = {}
        if folder then
            for _, vm in folder:GetChildren() do
                local torso = vm:IsA("Model") and vm.Name ~= "LocalViewmodel" and vm:FindFirstChild("torso")
                if torso then
                    table.insert(bodies, { vm = vm, pos = torso.Position })
                end
            end
        end
        for _, model in CollectionService:GetTagged("Character") do
            if model ~= mine and model.Parent == Workspace then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local root = model:FindFirstChild("HumanoidRootPart")
                if hum and root and hum.Health > 0 then
                    local vm
                    local eq = Targets.charValue(model, "equipped")
                    if folder and typeof(eq) == "Instance" and eq.Parent and eq.Parent.Parent == folder then
                        vm = eq.Parent
                    end
                    if not vm then
                        local bestD = 12
                        for _, b in bodies do
                            local d = (b.pos - root.Position).Magnitude
                            if d < bestD then
                                vm, bestD = b.vm, d
                            end
                        end
                    end
                    local entry = { model = model, hum = hum, root = root, vm = vm, team = Targets.teammate(model) }
                    table.insert(out, entry)
                    if vm then
                        owners[vm] = entry
                    end
                end
            end
        end
        cache, cacheAt = out, now
        return out
    end
    function Targets.list(includeTeam)
        local out = {}
        for _, t in Targets.all() do
            if includeTeam or not t.team then
                table.insert(out, t)
            end
        end
        return out
    end
    -- The middle of a player's head or torso part, or a guess from the root if the body isn't
    -- found.
    function Targets.aimPos(t, choice)
        if choice == "Random" then
            choice = math.random() < 0.5 and "Head" or "Torso"
        end
        local p = t.vm and t.vm:FindFirstChild(choice == "Head" and "head" or "torso")
        if p then
            return p.Position
        end
        return t.root.Position + Vector3.new(0, choice == "Head" and 1.6 or 0.3, 0)
    end

    -- The furthest a target can be: your slider, or (with "Limit to gun range") also the gun's
    -- range stat times the scale.
    function Targets.limit(setting)
        if Settings.GunRange then
            local item = Game.gun()
            local r = item and Game.gunRange(item)
            if r then
                return math.min(setting, r * Settings.RangeScale)
            end
        end
        return setting
    end
    -- Where the game really starts a shot: the muzzle, but never more than 3 studs sideways from
    -- the camera (its own validate_position).
    function Targets.shotOrigin(camPos, muzzle)
        local flat = Vector3.new(muzzle.X - camPos.X, 0, muzzle.Z - camPos.Z)
        if flat.Magnitude > 3 then
            local f = flat.Unit * 3
            return Vector3.new(camPos.X + f.X, muzzle.Y, camPos.Z + f.Z)
        end
        return muzzle
    end

    --// What a bullet can pass \\--
    -- Ported from the game's ray_damage: bullets go through anything you can't collide with, and
    -- through "Soft" parts (twice at most), and stop at solid parts, "Hard" ones and invisible walls
    -- you can collide with. The old check used a plain raycast, which also stopped at trails,
    -- triggers and other parts the bullet flies straight through, so players looked hidden when
    -- they weren't.
    -- "Soft" parts are the walls bullets can go through. Whether a target behind one counts as
    -- reachable is the "Aim through shootable walls" setting (`through`): off, a visible soft part
    -- blocks like any other wall; on, it is passed like the bullet would.
    -- Returns whether the bullet stops at part p, and how many soft/breakable parts it has gone
    -- through so far.
    local function stops(p, passed, through)
        if p.CollisionGroup == "char_block" then
            return false, passed
        end
        local par = p.Parent
        local softSelf = p:GetAttribute("Soft")
        local soft = softSelf or (par and par:GetAttribute("Soft"))
        local hard = p:GetAttribute("Hard") or (par and par:GetAttribute("Hard"))
        local breakable = (p:HasTag("Breakable") or (par and par:HasTag("Breakable"))) and p.CanCollide and p.CanQuery
        if breakable and not p:GetAttribute("BulletImmune") then
            passed += 1
        elseif (p.CanCollide or softSelf) and p.Transparency < 1 then
            if p.CollisionGroup == "prop" then
                return false, passed
            end
            if not soft or not through then
                return true, passed
            end
            passed += 1
        end
        if passed > 1 or hard then
            return true, passed
        end
        if p.CanQuery and p.CanCollide and (not soft or (not through and p.Transparency < 1)) then
            return true, passed
        end
        return false, passed
    end

    -- What every wall check ignores: the camera, every body and every player model (their own
    -- bodies are what we are looking for, and their models hold no solid parts).
    local ignoreList, ignoreAt = {}, 0
    local function ignores()
        local now = os.clock()
        if now - ignoreAt > 0.05 then
            ignoreAt = now
            table.clear(ignoreList)
            local cam = camera()
            if cam then
                table.insert(ignoreList, cam)
            end
            local folder = Workspace:FindFirstChild("Viewmodels")
            if folder then
                table.insert(ignoreList, folder)
            end
            for _, model in CollectionService:GetTagged("Character") do
                table.insert(ignoreList, model)
            end
        end
        return ignoreList
    end
    Targets.ignores = ignores
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local STEPS = 12

    -- Would a bullet fired from `from` reach `to`? `through` says whether soft walls count as passable
    -- (nil: the "Aim through shootable walls" setting).
    function Targets.clear(from, to, through)
        local vec = to - from
        if vec.Magnitude < 0.05 then
            return true
        end
        params.FilterDescendantsInstances = ignores()
        local passed = 0
        if through == nil then
            through = Settings.AimThroughWalls
        end
        for _ = 1, STEPS do
            local hit = Workspace:Raycast(from, vec, params)
            if not hit then
                return true
            end
            -- Something right at the target (a wall it stands against) doesn't hide it.
            if (hit.Position - to).Magnitude <= 0.3 then
                return true
            end
            local stop
            stop, passed = stops(hit.Instance, passed, through)
            if stop then
                return false
            end
            params:AddToFilter(hit.Instance)
        end
        return false
    end
    -- Can a bullet from the camera (or `from`) reach this point.
    function Targets.visible(pos, from)
        local cam = camera()
        if not cam then
            return false
        end
        return Targets.clear(from or cam.CFrame.Position, pos)
    end

    -- The first enemy or teammate body a bullet along `vec` from `from` would hit, walking through
    -- whatever bullets pass. Returns the part and its entry, or nil if a wall comes first.
    local bodyParams = RaycastParams.new()
    bodyParams.FilterType = Enum.RaycastFilterType.Exclude
    function Targets.firstBody(from, vec)
        Targets.all() -- keeps the body -> player lookup fresh
        local ignore = {}
        local cam = camera()
        if cam then
            table.insert(ignore, cam)
        end
        if LocalPlayer.Character then
            table.insert(ignore, LocalPlayer.Character)
        end
        local folder = Workspace:FindFirstChild("Viewmodels")
        local mine = folder and folder:FindFirstChild("LocalViewmodel")
        if mine then
            table.insert(ignore, mine)
        end
        bodyParams.FilterDescendantsInstances = ignore
        local passed, through = 0, Settings.AimThroughWalls
        for _ = 1, STEPS do
            local hit = Workspace:Raycast(from, vec, bodyParams)
            if not hit then
                return nil
            end
            local p = hit.Instance
            local owner = owners[p.Parent]
            if owner then
                return p, owner
            end
            local stop
            stop, passed = stops(p, passed, through)
            if stop then
                return nil
            end
            bodyParams:AddToFilter(p)
        end
        return nil
    end

    --// Aim points \\--
    -- Body parts to try, best first: the one you chose, then (if allowed) the rest of the body.
    local PART_ORDER = { "head", "torso", "shoulder1", "shoulder2", "arm1", "arm2", "hip1", "hip2", "leg1", "leg2" }
    local ONLY, WITH_REST = {}, {}
    for _, first in { "head", "torso" } do
        ONLY[first] = { first }
        local list = { first }
        for _, name in PART_ORDER do
            if name ~= first then
                table.insert(list, name)
            end
        end
        WITH_REST[first] = list
    end
    -- Spots on a part, as fractions of its size: the middle first, then the top, bottom and sides,
    -- so a player whose middle is behind cover but whose edge shows is still a target.
    local OFFSETS = {
        Vector3.new(0, 0, 0), Vector3.new(0, 0.35, 0), Vector3.new(0, -0.35, 0),
        Vector3.new(0.35, 0, 0), Vector3.new(-0.35, 0, 0),
    }
    local function pointOf(part, idx)
        return part.CFrame:PointToWorldSpace(OFFSETS[idx] * part.Size)
    end

    -- The point to aim at on a player: the first spot a bullet from `from` can reach, trying the
    -- chosen part's spots, then (opts.fallback) the other parts. Without opts.visible it is just
    -- the middle of the chosen part. Returns position, part name and spot number, or nil.
    -- opts: visible, multi, fallback
    function Targets.resolve(t, choice, opts, from)
        local first = choice == "Head" and "head" or "torso"
        if not opts.visible then
            return Targets.aimPos(t, choice), first, 1
        end
        local vm = t.vm
        if not vm then
            local pos = Targets.aimPos(t, choice)
            if Targets.clear(from, pos) then
                return pos, nil, 1
            end
            return nil
        end
        for _, name in (opts.fallback and WITH_REST or ONLY)[first] do
            local part = vm:FindFirstChild(name)
            if part and part:IsA("BasePart") then
                local n = 1
                if opts.multi then
                    n = name == first and #OFFSETS or ((name == "head" or name == "torso") and 3 or 1)
                end
                for idx = 1, n do
                    local pos = pointOf(part, idx)
                    if Targets.clear(from, pos) then
                        return pos, name, idx
                    end
                end
            end
        end
        return nil
    end

    function Targets.screen(pos)
        local sp = camera():WorldToViewportPoint(pos)
        return Vector2.new(sp.X, sp.Y), sp.Z > 0
    end
    -- The player closest to the middle of the screen inside a FOV (px) that a bullet can reach,
    -- or nil. Also returns how many players were inside the FOV and the distance limit.
    -- opts: fov, maxDist, visible, part, teammates, multi, fallback, from
    function Targets.pick(opts)
        local cam = camera()
        local camPos = cam.CFrame.Position
        local from = opts.from or camPos
        local centre = cam.ViewportSize / 2
        local choice = opts.part
        if choice == "Random" then
            choice = math.random() < 0.5 and "Head" or "Torso"
        end
        local cands = {}
        for _, t in Targets.list(opts.teammates) do
            local pos = Targets.aimPos(t, choice)
            local sp, front = Targets.screen(pos)
            if front then
                local d = (sp - centre).Magnitude
                if d <= opts.fov and (pos - camPos).Magnitude <= opts.maxDist then
                    table.insert(cands, { t = t, d = d })
                end
            end
        end
        table.sort(cands, function(a, b)
            return a.d < b.d
        end)
        for _, c in cands do
            local pos, part, idx = Targets.resolve(c.t, choice, opts, from)
            if pos then
                return { t = c.t, pos = pos, d = c.d, part = part, idx = idx, choice = choice }, #cands
            end
        end
        return nil, #cands
    end
    -- Is an earlier pick still good (alive, still near the middle, still reachable)? Returns the
    -- pick with a fresh aim point, or nil.
    function Targets.recheck(a, opts)
        local t = a.t
        if not (t.model.Parent == Workspace and t.hum.Health > 0) then
            return nil
        end
        local cam = camera()
        local pos = Targets.aimPos(t, a.choice)
        local sp, front = Targets.screen(pos)
        if not front or (sp - cam.ViewportSize / 2).Magnitude > opts.fov * 1.5 then
            return nil
        end
        if (pos - cam.CFrame.Position).Magnitude > opts.maxDist * 1.1 then
            return nil
        end
        local p, part, idx = Targets.resolve(t, a.choice, opts, opts.from or cam.CFrame.Position)
        if not p then
            return nil
        end
        return { t = t, pos = p, d = (sp - cam.ViewportSize / 2).Magnitude, part = part, idx = idx, choice = a.choice }
    end
end

--// Silent aim \\--
-- The gun mods (recoil, spread, fire rate, aim and reload speed, speed boost, auto reload) and the
-- shot hook itself run in the agent, next to the game's own code; Game.pump sends it the settings.
-- What stays here is choosing who a shot goes at: every frame the best target a bullet from your
-- muzzle can reach is worked out and sent to the agent, which redirects the shot when the game
-- asks where it goes (the rays and the look that is sent both follow).
local Silent = { last = nil, sent = false }
do
    local OPTS = {}
    Game.onRedirect = function(name, part)
        Silent.last = { name = name, part = (part ~= "" and part) or nil, at = os.clock() }
    end

    function Silent.step()
        local gun = Game.gun()
        if not (Settings.SilentAim and gun) then
            if Silent.sent then
                Silent.sent = false
                Game.aim(nil)
            end
            return
        end
        local cam = camera()
        local muzzle = Game.shotLook(gun)
        local origin = Targets.shotOrigin(cam.CFrame.Position, muzzle and muzzle.Position or cam.CFrame.Position)
        OPTS.fov, OPTS.maxDist = Settings.SilentFOV, Targets.limit(Settings.SilentMaxDistance)
        OPTS.visible, OPTS.part, OPTS.teammates = Settings.SilentVisible, Settings.SilentPart, false
        OPTS.multi, OPTS.fallback, OPTS.from = Settings.PartlyVisible, Settings.AnyBodyPart, origin
        local pick = Targets.pick(OPTS)
        if pick then
            Silent.sent = true
            Game.aim(pick.pos, pick.part, pick.t.model.Name)
        elseif Silent.sent then
            Silent.sent = false
            Game.aim(nil)
        end
    end
end

--// Pressing the game's fire button \\--
-- The triggerbot's way to shoot when the gun data isn't found (and the only one that makes sense on
-- a phone: mouse1click does nothing there). The game's on-screen fire buttons (ShootLeftButton and
-- the ShootJoystickFrame) listen on InputBegan for a Touch or MouseButton1 and call the gun's own
-- input_shoot, so a virtual click on one fires like a thumb would: the left button shoots on press,
-- the joystick shoots on press for automatic guns and on release for the rest, which a press and
-- release at the same spot covers.
local Press = { busy = false, method = nil }
do
    local NAMES = { "ShootLeftButton", "ShootJoystickFrame" }
    local TAP = 0.06
    local vim, gui, held
    local function service(name)
        local ok, svc = pcall(function()
            return game:GetService(name)
        end)
        return ok and svc or nil
    end
    -- On screen, enabled and big enough to hit, all the way up.
    local function shown(g)
        local o = g
        while o and o:IsA("GuiObject") do
            if not o.Visible then
                return false
            end
            o = o.Parent
        end
        local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
        return sg ~= nil and sg.Enabled and g.AbsoluteSize.X > 4 and g.AbsoluteSize.Y > 4
    end
    -- The first fire button that is showing right now, or nil.
    function Press.find()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not pg then
            return nil
        end
        for _, name in NAMES do
            local b = pg:FindFirstChild(name, true)
            if b and b:IsA("GuiObject") and shown(b) then
                return b
            end
        end
        return nil
    end
    local function send(down, x, y, how)
        if how == "touch" then
            vim:SendTouchEvent(1, down and 0 or 2, x, y)
        else
            vim:SendMouseButtonEvent(x, y, 0, down, game, 1)
        end
    end
    -- Presses and releases the fire button. False if there is nothing to press with or on.
    function Press.tap()
        if Press.busy then
            return true
        end
        vim = vim or service("VirtualInputManager")
        if not vim then
            return false
        end
        local b = Press.find()
        if not b then
            return false
        end
        -- Virtual input is in screen pixels, which include the top bar unless the gui ignores it.
        local inset = Vector2.new(0, 0)
        local sg = b:FindFirstAncestorWhichIsA("ScreenGui")
        gui = gui or service("GuiService")
        if gui and not (sg and sg.IgnoreGuiInset) then
            local ok, v = pcall(gui.GetGuiInset, gui)
            if ok and typeof(v) == "Vector2" then
                inset = v
            end
        end
        local c = b.AbsolutePosition + b.AbsoluteSize / 2 + inset
        local how = "mouse"
        if not pcall(send, true, c.X, c.Y, how) then
            how = "touch"
            if not pcall(send, true, c.X, c.Y, how) then
                return false
            end
        end
        Press.busy, Press.method = true, ("%s (%s)"):format(b.Name, how)
        held = { x = c.X, y = c.Y, how = how }
        task.delay(TAP, function()
            pcall(send, false, c.X, c.Y, how)
            Press.busy, held = false, nil
        end)
        return true
    end
    -- Unloading in the middle of a press lets go of the button.
    table.insert(Cleanups, function()
        if held and vim then
            pcall(send, false, held.x, held.y, held.how)
            Press.busy, held = false, nil
        end
    end)
end

--// Aimbot + triggerbot \\--
local Aim = { target = nil }
local FovCircle, SilentCircle
do
    local OPTS = {}
    -- Is the aim key down? Sights and shooting come from your gun's own state when it is found
    -- (so they work on touch); otherwise they fall back to the mouse buttons, or always on touch.
    local function holding(item)
        local when = Settings.AimWhen
        if when == "Always" then
            return true
        elseif when == "Left mouse" then
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        elseif when == "Right mouse" then
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        end
        if item then
            if when == "Aiming down sights" then
                return item.sights == true
            end
            return item.shoot == true
        end
        if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
            return true
        end
        return UserInputService:IsMouseButtonPressed(
            when == "Aiming down sights" and Enum.UserInputType.MouseButton2 or Enum.UserInputType.MouseButton1)
    end

    -- What the status line says: why the aimbot is or isn't locked on.
    Aim.status = "Off"

    -- Turns the camera by a fraction of the angle needed to put the *bullet* on `to`. When the gun's
    -- parts are found it measures from where the gun really points (muzzle and barrel direction), so
    -- recoil and sway are corrected too; otherwise from the camera. Keeps the camera's roll and
    -- position untouched.
    local function turn(cam, to, alpha, item)
        local cf = cam.CFrame
        local origin, look = cf.Position, cf.LookVector
        if item and Settings.RecoilAware then
            local shot = Game.shotLook(item)
            if shot and shot.LookVector:Dot(look) > 0.5 then
                origin, look = Targets.shotOrigin(cf.Position, shot.Position), shot.LookVector
                -- The gun follows the camera a moment late (and its position reaches here a frame
                -- late), so don't correct all of it at once.
                alpha = math.min(alpha, 0.4)
            end
        end
        local dir = to - origin
        if dir.Magnitude < 0.05 then
            return
        end
        dir = dir.Unit
        local axis = look:Cross(dir)
        if axis.Magnitude < 1e-4 then
            return
        end
        local angle = math.acos(math.clamp(look:Dot(dir), -1, 1)) * alpha
        cam.CFrame = CFrame.new(cf.Position) * CFrame.fromAxisAngle(axis.Unit, angle) * (cf - cf.Position)
    end

    function Aim.step(dt)
        if not Settings.Aimbot then
            Aim.target, Aim.status = nil, "Off"
            return
        end
        if camera().CameraType == Enum.CameraType.Scriptable then
            Aim.target, Aim.status = nil, "The game controls the camera right now"
            return
        end
        local item = Game.gun()
        if not holding(item) then
            Aim.target, Aim.status = nil, "Waiting for: " .. tostring(Settings.AimWhen)
            return
        end
        OPTS.fov, OPTS.maxDist = Settings.AimFOV, Targets.limit(Settings.AimMaxDistance)
        OPTS.visible, OPTS.part, OPTS.teammates = Settings.VisibleOnly, Settings.AimPart, Settings.AimTeammates
        OPTS.multi, OPTS.fallback, OPTS.from = Settings.PartlyVisible, Settings.AnyBodyPart, nil
        local a, inView = nil, 0
        if Aim.target and Settings.StickyTarget then
            a = Targets.recheck(Aim.target, OPTS)
        end
        if not a then
            a, inView = Targets.pick(OPTS)
        end
        Aim.target = a
        if not a then
            Aim.status = inView > 0 and ("%d in the circle, none reachable"):format(inView) or "No player in the circle"
            return
        end
        Aim.status = ("Locked: %s (%s)"):format(a.t.model.Name, a.part or "body")
        local k = math.max(Settings.Smoothness, 1)
        local alpha = 1 - (1 - 1 / k) ^ (math.clamp(dt, 0, 0.1) * 60)
        turn(camera(), a.pos, alpha, item)
    end

    -- Trigger: when a bullet from your gun would hit an enemy body, fires. First choice is the gun
    -- data: the game's own input_shoot, tapped by the agent (which also keeps your sights up
    -- afterwards). Without it, a tap on the game's on-screen fire button, which is what works on a
    -- phone, and last a mouse click.
    local lastShot, armedAt = 0, nil
    Aim.fireMethod = nil
    local function fire(item)
        if item and Game.live() then
            Aim.fireMethod = "the gun's own shoot (gun data)"
            Game.fire()
        elseif Press.tap() then
            -- No gun data, or it sees no gun: the on-screen button only shows when one is equipped.
            Aim.fireMethod = "tap on the " .. tostring(Press.method)
        elseif not IsTouch and typeof(mouse1click) == "function" then
            Aim.fireMethod = "mouse click"
            mouse1click()
        else
            Aim.fireMethod = "no way to fire found"
        end
    end
    function Aim.trigger()
        if not Settings.Triggerbot then
            armedAt = nil
            return
        end
        local item = Game.gun()
        if Settings.TriggerOnlyAiming then
            local aiming
            if item then
                aiming = item.sights == true
            elseif IsTouch then
                aiming = true -- can't tell without the gun data, and there is no right mouse button
            else
                aiming = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
            end
            if not aiming then
                armedAt = nil
                return
            end
        end
        -- Where the next bullet really goes: your gun's own direction when it can be worked out,
        -- else the camera's.
        local cam = camera()
        local from, dir = cam.CFrame.Position, cam.CFrame.LookVector
        local shot = item and Game.shotLook(item)
        if shot and shot.LookVector:Dot(dir) > 0.5 then
            from, dir = Targets.shotOrigin(from, shot.Position), shot.LookVector
        end
        local part, owner = Targets.firstBody(from, dir * Targets.limit(Settings.TriggerMaxDistance))
        local onEnemy = part ~= nil and not owner.team and (not Settings.TriggerHeadOnly or part.Name == "head")
        if not onEnemy then
            armedAt = nil
            return
        end
        local now = os.clock()
        armedAt = armedAt or now
        if now - armedAt >= Settings.TriggerDelay / 1000 and now - lastShot >= (Game.live() and 0.08 or 0.14) then
            lastShot = now
            fire(item)
        end
    end

    local function circle(color)
        local ok, c = pcall(Drawing.new, "Circle")
        if not ok then
            return nil
        end
        c.Thickness, c.NumSides, c.Filled, c.Color, c.Transparency, c.Visible = 1, 64, false, color, 0.9, false
        return c
    end
    FovCircle = circle(Color3.new(1, 1, 1))
    SilentCircle = circle(Color3.fromRGB(255, 120, 200))
    table.insert(Cleanups, function()
        for _, c in { FovCircle, SilentCircle } do
            pcall(c.Remove, c)
        end
    end)
end

--// ESP \\--
local Esp = { drawings = {}, chams = {}, util = {}, utilList = {}, utilAt = 0 }
do
    local SKELETON = {
        { "head", "torso" }, { "torso", "shoulder1" }, { "shoulder1", "arm1" }, { "torso", "shoulder2" },
        { "shoulder2", "arm2" }, { "torso", "hip1" }, { "hip1", "leg1" }, { "torso", "hip2" }, { "hip2", "leg2" },
    }
    local UTIL = {
        { group = "UtilTraps", label = "Claymore", tag = "Claymore" },
        { group = "UtilTraps", label = "Needle mine", tag = "NeedleMine" },
        { group = "UtilTraps", label = "Proximity alarm", tag = "ProximityAlarm" },
        { group = "UtilTraps", label = "Remote C4", tag = "RemoteC4" },
        { group = "UtilTraps", label = "Thermite", tag = "ThermiteCharge" },
        { group = "UtilTraps", label = "Breach charge", tag = "BreachCharge" },
        { group = "UtilTraps", label = "Hard breach", tag = "HardBreachCharge" },
        { group = "UtilTraps", label = "Incendiary", tag = "IncendiaryCanister" },
        { group = "UtilTraps", label = "Toxic charge", tag = "ToxicCharge" },
        { group = "UtilTraps", label = "Shock battery", tag = "ShockBattery" },
        { group = "UtilTraps", label = "Signal disruptor", tag = "SignalDisruptor" },
        { group = "UtilTraps", label = "Barbed wire", tag = "BarbedWire" },
        { group = "UtilCameras", label = "Sticky camera", tag = "StickyCamera" },
        { group = "UtilCameras", label = "Bulletproof camera", tag = "BulletproofCamera" },
        { group = "UtilCameras", label = "Drone", tag = "Drone" },
        { group = "UtilGrenades", label = "Frag", tag = "FragGrenade" },
        { group = "UtilGrenades", label = "Smoke", tag = "SmokeGrenade" },
        { group = "UtilGrenades", label = "Stun", tag = "StunGrenade" },
        { group = "UtilGrenades", label = "EMP", tag = "EMPGrenade" },
        { group = "UtilGrenades", label = "Impact", tag = "ImpactGrenade" },
        { group = "UtilGrenades", label = "Incendiary", tag = "IncendiaryGrenade" },
        { group = "UtilGrenades", label = "Launched", tag = "LaunchedGrenade" },
        { group = "BombEsp", label = "BOMB", tag = "Bomb" },
    }

    local function make(class, props)
        local ok, d = pcall(Drawing.new, class)
        if not ok then
            return nil
        end
        for k, v in props do
            d[k] = v
        end
        return d
    end
    local function newEntry()
        local e = {
            box = make("Square", { Thickness = 1, Filled = false, Visible = false }),
            outline = make("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0), Visible = false }),
            name = make("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            info = make("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
            hpBack = make("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
            hp = make("Line", { Thickness = 2, Visible = false }),
            tracer = make("Line", { Thickness = 1, Visible = false }),
            look = make("Line", { Thickness = 1, Visible = false }),
            bones = {},
        }
        for i = 1, #SKELETON do
            e.bones[i] = make("Line", { Thickness = 1, Visible = false })
        end
        return e
    end
    local function each(e, fn)
        for k, d in e do
            if k == "bones" then
                for _, b in d do
                    fn(b)
                end
            else
                fn(d)
            end
        end
    end
    local function hide(e)
        each(e, function(d)
            d.Visible = false
        end)
    end
    local function kill(e)
        each(e, function(d)
            pcall(d.Remove, d)
        end)
    end
    local function chamsParent()
        return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    end

    -- How a bullet from your camera stands with a player, as a word: "visible" (it reaches them),
    -- "wall" (only through soft walls) or "hidden". Worked out a few times a second.
    local reachCache = {}
    function Esp.reach(t)
        local c = reachCache[t.model]
        local now = os.clock()
        if c and now - c.at < 0.12 then
            return c.state
        end
        local from = camera().CFrame.Position
        local head, torso = Targets.aimPos(t, "Head"), Targets.aimPos(t, "Torso")
        local state = "hidden"
        if Targets.clear(from, head, false) or Targets.clear(from, torso, false) then
            state = "visible"
        elseif Targets.clear(from, head, true) or Targets.clear(from, torso, true) then
            state = "wall"
        end
        reachCache[t.model] = { state = state, at = now }
        return state
    end

    local function bounds(t)
        local cam = camera()
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local any = false
        local function add(pos)
            local sp = cam:WorldToViewportPoint(pos)
            if sp.Z > 0 then
                any = true
                minX, maxX = math.min(minX, sp.X), math.max(maxX, sp.X)
                minY, maxY = math.min(minY, sp.Y), math.max(maxY, sp.Y)
            end
        end
        if t.vm then
            for _, p in t.vm:GetChildren() do
                if p:IsA("BasePart") then
                    add(p.Position)
                    if p.Name == "head" then
                        add(p.Position + Vector3.new(0, p.Size.Y * 0.7, 0))
                    end
                end
            end
        else
            add(t.root.Position + Vector3.new(0, 2.8, 0))
            add(t.root.Position - Vector3.new(0, 3, 0))
        end
        if not any then
            return nil
        end
        return minX - 8, minY - 6, maxX + 8, maxY + 6
    end

    local function equippedName(model)
        local inst = Targets.charValue(model, "equipped")
        if typeof(inst) == "Instance" then
            return inst.Name
        end
    end
    local function className(model)
        local v = Targets.charValue(model, "class_name")
        return type(v) == "string" and v ~= "" and v or nil
    end
    local function line(d, a, b, color)
        local sa, fa = Targets.screen(a)
        local sb, fb = Targets.screen(b)
        if fa and fb then
            d.From, d.To, d.Color, d.Visible = sa, sb, color, true
        else
            d.Visible = false
        end
    end

    local function players()
        local seen = {}
        if Settings.Esp then
            local cam = camera()
            local viewport = cam.ViewportSize
            for _, t in Targets.list(Settings.EspTeammates) do
                local dist = (t.root.Position - cam.CFrame.Position).Magnitude
                if dist <= Settings.EspMax then
                    seen[t.model] = true
                    local e = Esp.drawings[t.model]
                    if not e then
                        e = newEntry()
                        Esp.drawings[t.model] = e
                    end
                    local x1, y1, x2, y2 = bounds(t)
                    if not x1 then
                        hide(e)
                    else
                        local color = Targets.color(t.model, t.team)
                        -- the box and the lines take the "can I hit them" colour, the name keeps the team's
                        local boxColor, reachTag = color, nil
                        if Settings.EspReachable and not t.team then
                            local st = Esp.reach(t)
                            boxColor = (st == "visible" and Settings.ReachVisible) or (st == "wall" and Settings.ReachWall)
                                or Settings.ReachHidden
                            reachTag = st == "wall" and "through wall" or nil
                        end
                        local w, h = x2 - x1, y2 - y1
                        local mid = (x1 + x2) / 2
                        if Settings.EspBox and e.box then
                            e.outline.Position, e.outline.Size, e.outline.Visible = Vector2.new(x1, y1), Vector2.new(w, h), true
                            e.box.Position, e.box.Size, e.box.Color, e.box.Visible = Vector2.new(x1, y1), Vector2.new(w, h), boxColor, true
                        else
                            e.box.Visible, e.outline.Visible = false, false
                        end
                        if Settings.EspName and e.name then
                            local owner = Players:GetPlayerFromCharacter(t.model)
                            e.name.Text = owner and owner.DisplayName or t.model.Name
                            e.name.Position, e.name.Color, e.name.Visible = Vector2.new(mid, y1 - 16), color, true
                        else
                            e.name.Visible = false
                        end
                        if Settings.EspHealth and e.hp then
                            local frac = math.clamp(t.hum.Health / math.max(t.hum.MaxHealth, 1), 0, 1)
                            e.hpBack.From, e.hpBack.To, e.hpBack.Visible = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y1), true
                            e.hp.From, e.hp.To = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y2 - h * frac)
                            e.hp.Color, e.hp.Visible = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(80, 255, 110), frac), true
                        else
                            e.hp.Visible, e.hpBack.Visible = false, false
                        end
                        local bits = {}
                        if Settings.EspWeapon then
                            bits[#bits + 1] = equippedName(t.model)
                        end
                        if Settings.EspClass then
                            bits[#bits + 1] = className(t.model)
                        end
                        if Settings.EspDistance then
                            bits[#bits + 1] = ("%dm"):format(math.floor(dist))
                        end
                        if reachTag then
                            bits[#bits + 1] = reachTag
                        end
                        if #bits > 0 and e.info then
                            e.info.Text = table.concat(bits, "  ")
                            e.info.Position, e.info.Color, e.info.Visible = Vector2.new(mid, y2 + 2), Color3.new(1, 1, 1), true
                        else
                            e.info.Visible = false
                        end
                        if Settings.EspTracer and e.tracer then
                            e.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                            e.tracer.To, e.tracer.Color, e.tracer.Visible = Vector2.new(mid, y2), boxColor, true
                        else
                            e.tracer.Visible = false
                        end
                        local vm = t.vm
                        for i, pair in SKELETON do
                            local a = Settings.EspSkeleton and vm and vm:FindFirstChild(pair[1])
                            local b = a and vm:FindFirstChild(pair[2])
                            if a and b and e.bones[i] then
                                line(e.bones[i], a.Position, b.Position, boxColor)
                            elseif e.bones[i] then
                                e.bones[i].Visible = false
                            end
                        end
                        local head = vm and vm:FindFirstChild("head")
                        local dir = Targets.charValue(t.model, "look")
                        if Settings.EspLook and head and typeof(dir) == "Vector3" and dir.Magnitude > 0.01 and e.look then
                            line(e.look, head.Position, head.Position + dir.Unit * 8, Color3.fromRGB(255, 220, 80))
                        elseif e.look then
                            e.look.Visible = false
                        end
                    end
                end
            end
        end
        for model, e in Esp.drawings do
            if not seen[model] then
                kill(e)
                Esp.drawings[model] = nil
                reachCache[model] = nil
            end
        end

        -- Chams: a highlight over the visible body, through walls.
        local chamSeen = {}
        if Settings.Esp and Settings.EspChams then
            for _, t in Targets.list(Settings.EspTeammates) do
                if t.vm then
                    chamSeen[t.model] = true
                    local h = Esp.chams[t.model]
                    if not h or h.Adornee ~= t.vm then
                        if h then
                            h:Destroy()
                        end
                        h = Instance.new("Highlight")
                        h.Adornee = t.vm
                        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        h.FillTransparency = 0.6
                        h.OutlineTransparency = 0
                        h.Parent = chamsParent()
                        Esp.chams[t.model] = h
                    end
                    local color = Targets.color(t.model, t.team)
                    h.FillColor, h.OutlineColor = color, color
                end
            end
        end
        for model, h in Esp.chams do
            if not chamSeen[model] then
                pcall(h.Destroy, h)
                Esp.chams[model] = nil
            end
        end
    end

    -- Placed gear, grenades and the bomb, found by their tags (refreshed twice a second).
    local function gear()
        local now = os.clock()
        if now - Esp.utilAt > 0.5 then
            Esp.utilAt = now
            table.clear(Esp.utilList)
            local vms = Workspace:FindFirstChild("Viewmodels")
            for _, def in UTIL do
                if Settings[def.group] then
                    for _, inst in CollectionService:GetTagged(def.tag) do
                        if inst:IsDescendantOf(Workspace) and not (vms and inst:IsDescendantOf(vms)) then
                            table.insert(Esp.utilList, { inst = inst, label = def.label })
                        end
                    end
                end
            end
        end
        local cam = camera()
        local seen = {}
        for _, item in Esp.utilList do
            local inst = item.inst
            if inst.Parent then
                local pos
                if inst:IsA("Model") then
                    pos = inst:GetPivot().Position
                elseif inst:IsA("BasePart") then
                    pos = inst.Position
                end
                if pos then
                    local dist = (pos - cam.CFrame.Position).Magnitude
                    local sp, front = Targets.screen(pos)
                    if front and dist <= Settings.UtilMax then
                        seen[inst] = true
                        local d = Esp.util[inst]
                        if not d then
                            d = make("Text", { Size = 13, Center = true, Outline = true, Color = Color3.fromRGB(255, 200, 60) })
                            Esp.util[inst] = d
                        end
                        if d then
                            d.Text = ("%s %dm"):format(item.label, math.floor(dist))
                            d.Position, d.Visible = sp, true
                        end
                    end
                end
            end
        end
        for inst, d in Esp.util do
            if not seen[inst] then
                pcall(d.Remove, d)
                Esp.util[inst] = nil
            end
        end
    end

    function Esp.step()
        players()
        gear()
    end
    function Esp.clear()
        for model, e in Esp.drawings do
            kill(e)
            Esp.drawings[model] = nil
        end
        for model, h in Esp.chams do
            pcall(h.Destroy, h)
            Esp.chams[model] = nil
        end
        for inst, d in Esp.util do
            pcall(d.Remove, d)
            Esp.util[inst] = nil
        end
    end
    table.insert(Cleanups, Esp.clear)
end

--// World \\--
local World = {}
do
    local saved
    function World.fullbright(on)
        if on then
            saved = saved or {
                Brightness = Lighting.Brightness, FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            }
            Lighting.Brightness = 2
            Lighting.FogEnd = 1e6
            Lighting.GlobalShadows = false
            Lighting.Ambient = Color3.fromRGB(190, 190, 190)
            Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190)
        elseif saved then
            for k, v in saved do
                Lighting[k] = v
            end
            saved = nil
        end
    end
    table.insert(Cleanups, function()
        World.fullbright(false)
    end)

    -- The game restores the camera to its own OriginalFOV attribute after every zoom, so that
    -- is the value to change. Scoped views are left alone.
    local originalFov
    function World.fov()
        local cam = camera()
        if not cam then
            return
        end
        if Settings.FovChanger then
            local current = cam:GetAttribute("OriginalFOV")
            if originalFov == nil then
                originalFov = current
            end
            if current ~= Settings.FovValue then
                local zoomed = cam.FieldOfView < (current or 70) - 1
                cam:SetAttribute("OriginalFOV", Settings.FovValue)
                if not zoomed then
                    cam.FieldOfView = Settings.FovValue
                end
            end
        elseif originalFov ~= nil then
            cam:SetAttribute("OriginalFOV", originalFov)
            originalFov = nil
        end
    end
    table.insert(Cleanups, function()
        Settings.FovChanger = false
        pcall(World.fov)
    end)

    -- Flashbangs paint a full-screen frame called Flash; keep it invisible.
    local flash
    function World.noFlash()
        if not Settings.NoFlash then
            if flash and flash.Parent then
                flash.Visible = true
            end
            return
        end
        if not (flash and flash.Parent) then
            local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local found = gui and gui:FindFirstChild("Flash", true)
            flash = found and found:FindFirstChild("Frame") or nil
        end
        if flash then
            flash.Visible = false
        end
    end

    -- Smoke clouds are parts called SmokePart dropped into Workspace. Hide them (and their
    -- particles) the moment they appear.
    local function hideSmoke(part)
        if part.Name ~= "SmokePart" or not Settings.NoSmoke then
            return
        end
        task.defer(function()
            if part:IsA("BasePart") then
                part.Transparency = 1
            end
            for _, d in part:GetDescendants() do
                if d:IsA("ParticleEmitter") then
                    d.Enabled = false
                elseif d:IsA("BasePart") then
                    d.Transparency = 1
                end
            end
        end)
    end
    bind(Workspace.DescendantAdded, function(d)
        if d.Name == "SmokePart" then
            hideSmoke(d)
        end
    end)
end

--// Extra visuals \\--
-- Off-screen arrows, wall ESP (which walls bullets pass or break), the bomb timer and carrier, and
-- hit feedback. Each part keeps its own Drawing objects and is cleaned up on unload.
local Extras = {}
local Walls, Hits = { parts = {}, adorn = {}, counts = { soft = 0, breakable = 0, hard = 0 }, scanned = nil }, {}
do
    local sqrt, floor, clamp = math.sqrt, math.floor, math.clamp
    local S = Settings
    local function mk(class, props)
        local ok, d = pcall(Drawing.new, class)
        if not ok then
            return nil
        end
        for k, v in props do
            d[k] = v
        end
        return d
    end
    local function container()
        return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    end

    --// Arrows to players who are not on screen \\--
    local arrows = {}
    local function arrowFor(model)
        local a = arrows[model]
        if not a then
            a = {
                tri = mk("Triangle", { Filled = true, Visible = false, Thickness = 1 }),
                text = mk("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
            }
            arrows[model] = a
        end
        return a
    end
    local function dropArrow(model, a)
        for _, d in a do
            pcall(d.Remove, d)
        end
        arrows[model] = nil
    end
    -- Points at each player who is off screen, around an oval the size of ArrowRadius, the way they lie
    -- on the ground relative to where you look.
    local function stepArrows(cam)
        local seen = {}
        if S.EspArrows then
            local vp = cam.ViewportSize
            local centre = vp / 2
            local rx, ry = vp.X * S.ArrowRadius, vp.Y * S.ArrowRadius
            for _, t in Targets.list(S.EspTeammates) do
                local pos = t.root.Position
                local dist = (pos - cam.CFrame.Position).Magnitude
                if dist <= S.ArrowMax then
                    local sp, on = cam:WorldToViewportPoint(pos)
                    local inside = on and sp.X >= 0 and sp.X <= vp.X and sp.Y >= 0 and sp.Y <= vp.Y
                    if S.ArrowAlways or not inside then
                        seen[t.model] = true
                        local a = arrowFor(t.model)
                        local rel = cam.CFrame:PointToObjectSpace(pos)
                        local dir = Vector2.new(rel.X, rel.Z) -- right, and forward is up the screen
                        local m = dir.Magnitude
                        dir = m > 1e-3 and dir / m or Vector2.new(0, -1)
                        local p = centre + Vector2.new(dir.X * rx, dir.Y * ry)
                        local size = S.ArrowSize
                        local perp = Vector2.new(-dir.Y, dir.X)
                        local base = p - dir * size * 0.5
                        local color = Targets.color(t.model, t.team)
                        if S.EspReachable and not t.team then
                            local st = Esp.reach(t)
                            color = (st == "visible" and S.ReachVisible) or (st == "wall" and S.ReachWall) or S.ReachHidden
                        end
                        if a.tri then
                            a.tri.PointA, a.tri.PointB, a.tri.PointC = p + dir * size, base + perp * size * 0.6, base - perp * size * 0.6
                            a.tri.Color, a.tri.Visible = color, true
                        end
                        if a.text then
                            if S.ArrowDistance then
                                a.text.Text = ("%dm"):format(floor(dist))
                                a.text.Position, a.text.Color, a.text.Visible = p - dir * (size + 8), color, true
                            else
                                a.text.Visible = false
                            end
                        end
                    end
                end
            end
        end
        for model, a in arrows do
            if not seen[model] then
                if a.tri then
                    a.tri.Visible = false
                end
                if a.text then
                    a.text.Visible = false
                end
                if not model.Parent then
                    dropArrow(model, a)
                end
            end
        end
    end

    --// Walls: soft (bullets pass), breakable (they break it), hard (nothing passes) \\--
    -- Found once per map by looking through the world in small slices, then drawn as see-through
    -- boxes around the ones near you.
    local scanning = false
    local function isBody(d)
        local vm = Workspace:FindFirstChild("Viewmodels")
        if vm and d:IsDescendantOf(vm) then
            return true
        end
        local m = d:FindFirstAncestorWhichIsA("Model")
        return m ~= nil and CollectionService:HasTag(m, "Character")
    end
    function Walls.rescan()
        if scanning then
            return
        end
        scanning = true
        task.spawn(function()
            local out = {}
            local counts = { soft = 0, breakable = 0, hard = 0 }
            local all = Workspace:GetDescendants()
            for i, d in all do
                if d:IsA("BasePart") then
                    local par = d.Parent
                    local brk = d:HasTag("Breakable") or (par and par:HasTag("Breakable"))
                    local hard = d:GetAttribute("Hard") or (par and par:GetAttribute("Hard"))
                    local soft = d:GetAttribute("Soft") or (par and par:GetAttribute("Soft"))
                    if (brk or hard or soft) and not isBody(d) then
                        local kind = brk and "breakable" or (hard and "hard" or "soft")
                        counts[kind] += 1
                        table.insert(out, { part = d, kind = kind })
                    end
                end
                if i % 1500 == 0 then
                    task.wait()
                end
            end
            Walls.parts, Walls.counts = out, counts
            Walls.scanned = Workspace:GetAttribute("CurrentMap") or true
            scanning = false
        end)
    end
    local function wallColor(kind)
        return kind == "soft" and S.WallSoftColor or (kind == "breakable" and S.WallBreakColor or S.WallHardColor)
    end
    local wallAt = 0
    local function stepWalls(cam)
        local on = S.WallEsp
        if on and Walls.scanned ~= (Workspace:GetAttribute("CurrentMap") or true) then
            Walls.rescan()
        end
        local now = os.clock()
        if not on then
            for part, a in Walls.adorn do
                pcall(a.Destroy, a)
                Walls.adorn[part] = nil
            end
            return
        end
        if now - wallAt < 0.3 then
            return
        end
        wallAt = now
        local camPos = cam.CFrame.Position
        local cands = {}
        for _, w in Walls.parts do
            local p = w.part
            if p.Parent and ((w.kind == "soft" and S.WallSoft) or (w.kind == "breakable" and S.WallBreakable)
                or (w.kind == "hard" and S.WallHard)) then
                local d = (p.Position - camPos).Magnitude
                if d <= S.WallMax then
                    table.insert(cands, { w = w, d = d })
                end
            end
        end
        table.sort(cands, function(a, b)
            return a.d < b.d
        end)
        local keep = {}
        for i = 1, math.min(#cands, S.WallCount) do
            local w = cands[i].w
            local part = w.part
            keep[part] = true
            local a = Walls.adorn[part]
            if not a then
                local ok, adorn = pcall(Instance.new, "BoxHandleAdornment")
                if ok then
                    adorn.AlwaysOnTop, adorn.ZIndex, adorn.Adornee, adorn.Parent = true, 5, part, container()
                    a = adorn
                    Walls.adorn[part] = a
                end
            end
            if a then
                a.Size, a.Color3, a.Transparency = part.Size, wallColor(w.kind), S.WallAlpha
            end
        end
        for part, a in Walls.adorn do
            if not keep[part] then
                pcall(a.Destroy, a)
                Walls.adorn[part] = nil
            end
        end
    end

    --// The bomb: who carries the defuser, where it is, how long is left \\--
    -- The carrier has the HasDefuser attribute on their player. The defuser itself is tagged Defuser;
    -- once it is planted (its Planted attribute) the game counts down 40 seconds, paused while the
    -- Workspace has a frozen_time attribute. The countdown is kept here from when the plant is first
    -- seen, so it is only exact if you saw it happen.
    local PLANT_TIME = 40
    local timers, markers = {}, {}
    local hudText, firstScan = nil, true
    local lastBomb = nil
    local function bombMarker(i)
        local m = markers[i]
        if m == nil then
            m = mk("Text", { Size = 13, Center = true, Outline = true, Visible = false }) or false
            markers[i] = m
        end
        return m
    end
    local function side(cam, pos)
        local rel = cam.CFrame:PointToObjectSpace(pos)
        if math.abs(rel.X) > math.abs(rel.Z) then
            return rel.X > 0 and "to your right" or "to your left"
        end
        return rel.Z < 0 and "ahead" or "behind you"
    end
    local function clockText(sec)
        sec = math.max(0, sec)
        return ("%d:%02d"):format(floor(sec / 60), floor(sec % 60))
    end
    local function stepBomb(cam, dt)
        local show = S.BombTimer or S.BombCarrier
        local now = os.clock()
        local mi = 0
        local lines = {}
        if show then
            local frozen = Workspace:GetAttribute("frozen_time") ~= nil
            -- the defuser out in the world
            local seenDef = {}
            for _, inst in CollectionService:GetTagged("Defuser") do
                if inst:IsDescendantOf(Workspace) then
                    local root = inst:FindFirstChild("Root") or inst
                    local pos = root:IsA("BasePart") and root.Position or (inst:IsA("Model") and inst:GetPivot().Position)
                    if pos then
                        seenDef[inst] = true
                        local planted = inst:GetAttribute("Planted") == true
                        local tm = timers[inst]
                        if planted and not tm then
                            tm = { at = now, paused = 0, left = PLANT_TIME, late = firstScan }
                            timers[inst] = tm
                        elseif not planted then
                            timers[inst] = nil
                            tm = nil
                        end
                        if tm then
                            -- wall-clock time since the plant, with the time spent frozen added back
                            if frozen then
                                tm.paused += dt
                            end
                            tm.left = PLANT_TIME - (now - tm.at) + tm.paused
                        end
                        local dist = (pos - cam.CFrame.Position).Magnitude
                        local label
                        if planted then
                            label = "DEFUSER PLANTED"
                            if S.BombTimer then
                                label = ("%s %s%s%s"):format(label, tm.late and "~" or "", clockText(tm.left),
                                    frozen and " (paused)" or "")
                            end
                            table.insert(lines, { text = label, color = Color3.fromRGB(255, 80, 80), pos = pos, dist = dist })
                        elseif S.BombCarrier then
                            label = "DEFUSER (dropped)"
                            table.insert(lines, { text = label, color = Color3.fromRGB(255, 220, 80), pos = pos, dist = dist })
                        end
                        if label then
                            local sp, onScreen = cam:WorldToViewportPoint(pos + Vector3.new(0, 2, 0))
                            if onScreen and mi < 6 then
                                mi += 1
                                local m = bombMarker(mi)
                                if m then
                                    m.Text, m.Position, m.Color, m.Visible = ("%s %dm"):format(label, floor(dist)), Vector2.new(sp.X, sp.Y),
                                        planted and Color3.fromRGB(255, 80, 80) or Color3.fromRGB(255, 220, 80), true
                                end
                            end
                        end
                    end
                end
            end
            for inst in timers do
                if not seenDef[inst] then
                    timers[inst] = nil
                end
            end
            -- the carrier
            if S.BombCarrier then
                for _, plr in Players:GetPlayers() do
                    if plr:GetAttribute("HasDefuser") then
                        if plr == LocalPlayer then
                            table.insert(lines, { text = "You carry the defuser", color = Color3.fromRGB(255, 160, 40) })
                        else
                            local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                            if root then
                                local dist = (root.Position - cam.CFrame.Position).Magnitude
                                table.insert(lines, {
                                    text = "DEFUSER: " .. plr.DisplayName, color = Color3.fromRGB(255, 160, 40), pos = root.Position, dist = dist,
                                })
                                local sp, onScreen = cam:WorldToViewportPoint(root.Position + Vector3.new(0, 3.2, 0))
                                if onScreen and mi < 6 then
                                    mi += 1
                                    local m = bombMarker(mi)
                                    if m then
                                        m.Text, m.Position, m.Color, m.Visible = ("DEFUSER %dm"):format(floor(dist)), Vector2.new(sp.X, sp.Y),
                                            Color3.fromRGB(255, 160, 40), true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        firstScan = false
        for i = mi + 1, #markers do
            if markers[i] then
                markers[i].Visible = false
            end
        end
        if #lines > 0 then
            hudText = hudText or mk("Text", { Size = 15, Center = true, Outline = true, Visible = false })
            if hudText then
                local out = {}
                for _, l in lines do
                    table.insert(out, l.pos and ("%s  %dm %s"):format(l.text, floor(l.dist), side(cam, l.pos)) or l.text)
                end
                hudText.Text, hudText.Color = table.concat(out, "\n"), lines[1].color
                hudText.Position, hudText.Visible = Vector2.new(cam.ViewportSize.X / 2, 38), true
            end
        elseif hudText then
            hudText.Visible = false
        end
    end

    --// Hit feedback \\--
    -- Your hits are told from the enemies' health: a drop within a moment of one of your shots (the agent
    -- reports each shot) counts as your hit; a drop to nothing as your kill. Without the gun data it is
    -- a guess from who is near your crosshair.
    local watch, marks = {}, {}
    local hlines, htexts = {}, {}
    Game.onShot = function()
        Hits.lastShot = os.clock()
    end
    Hits.lastShot = -10
    local function soundFor(kill)
        local id = kill and S.KillSoundId or S.HitSoundId
        local snd
        if id ~= "" then
            snd = Instance.new("Sound")
            snd.SoundId = id:match("^%d+$") and ("rbxassetid://" .. id) or id
        else
            local ok, tpl = pcall(function()
                return game:GetService("ReplicatedStorage").Modules.Game.Feed.Sounds.KillConfirm
            end)
            if not (ok and tpl) then
                return
            end
            snd = tpl:Clone()
            snd.PlaybackSpeed = kill and 1 or 1.8
        end
        snd.Volume = clamp(S.HitVolume * (kill and 1.2 or 0.8), 0, 10)
        snd.Parent = game:GetService("SoundService")
        snd:Play()
        game:GetService("Debris"):AddItem(snd, 4)
    end
    local lastSound = 0
    local function credit(w, cam)
        if Game.live() then
            return os.clock() - Hits.lastShot <= 0.6
        end
        -- no gun data: close to where you are aiming and in the open
        local sp, on = cam:WorldToViewportPoint(w.root.Position + Vector3.new(0, 1.5, 0))
        if not on then
            return false
        end
        return (Vector2.new(sp.X, sp.Y) - cam.ViewportSize / 2).Magnitude <= 160
    end
    local function stepHits(cam)
        for _, t in Targets.list(false) do
            if not watch[t.model] then
                watch[t.model] = { hum = t.hum, hp = t.hum.Health, root = t.root, model = t.model }
            end
        end
        for model, w in watch do
            local hp = w.hum.Health
            if hp < w.hp - 0.5 and credit(w, cam) then
                local dmg = w.hp - hp
                local kill = hp <= 0
                table.insert(marks, { at = os.clock(), kill = kill, dmg = dmg })
                local now = os.clock()
                if now - lastSound > 0.05 then
                    lastSound = now
                    if (kill and S.KillSound) or (not kill and S.HitSounds) then
                        pcall(soundFor, kill)
                    end
                end
            end
            w.hp = hp
            if hp <= 0 or not model.Parent then
                watch[model] = nil
            end
        end
        -- draw the marks that are still fading
        local li, ti = 0, 0
        local centre = cam.ViewportSize / 2
        local i = 1
        while i <= #marks do
            local m = marks[i]
            local age = os.clock() - m.at
            if age > S.HitTime then
                table.remove(marks, i)
            else
                i += 1
                if S.HitMarkers then
                    local fade = 1 - age / S.HitTime
                    local gap, len = (m.kill and 7 or 5) + age * 8, S.HitSize * (m.kill and 1.6 or 1)
                    local color = m.kill and Color3.fromRGB(255, 70, 70) or Color3.new(1, 1, 1)
                    for _, d in { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } } do
                        li += 1
                        local l = hlines[li]
                        if l == nil then
                            l = mk("Line", { Visible = false, Thickness = 2 }) or false
                            hlines[li] = l
                        end
                        if l then
                            local dir = Vector2.new(d[1], d[2]).Unit
                            l.From, l.To = centre + dir * gap, centre + dir * (gap + len)
                            l.Color, l.Transparency, l.Visible = color, fade, true
                        end
                    end
                end
                if S.HitNumbers and ti < 3 then
                    ti += 1
                    local t = htexts[ti]
                    if t == nil then
                        t = mk("Text", { Visible = false, Size = 16, Center = true, Outline = true }) or false
                        htexts[ti] = t
                    end
                    if t then
                        t.Text = m.kill and "KILL" or ("-%d"):format(floor(m.dmg + 0.5))
                        t.Position = centre + Vector2.new(0, -40 - age * 60)
                        t.Color, t.Transparency, t.Visible = m.kill and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(255, 220, 80), 1 - age / S.HitTime, true
                    end
                end
            end
        end
        for j = li + 1, #hlines do
            if hlines[j] then
                hlines[j].Visible = false
            end
        end
        for j = ti + 1, #htexts do
            if htexts[j] then
                htexts[j].Visible = false
            end
        end
    end

    function Extras.step()
        local cam = camera()
        if not cam then
            return
        end
        local now = os.clock()
        local dt = lastBomb and now - lastBomb or 0
        lastBomb = now
        stepArrows(cam)
        stepWalls(cam)
        stepBomb(cam, dt)
        stepHits(cam)
    end
    function Extras.clear()
        for model, a in arrows do
            dropArrow(model, a)
        end
        for part, a in Walls.adorn do
            pcall(a.Destroy, a)
            Walls.adorn[part] = nil
        end
        for _, list in { markers, hlines, htexts } do
            for _, d in list do
                if d then
                    pcall(d.Remove, d)
                end
            end
        end
        if hudText then
            pcall(hudText.Remove, hudText)
        end
        Game.onShot = nil
    end
    table.insert(Cleanups, Extras.clear)
    Extras._internal = { stepHits = stepHits, watch = watch, marks = marks, timers = timers }
end

--// Route planner \\--
-- Suggests a route (it never moves you): from where you stand to a goal, weighing how long it takes
-- against how likely the enemies are to see or hear you on the way. It is a custom planner on
-- purpose: the game's own movement (vaulting over low cover, crouching under beams, jumping up
-- ledges, dropping down, breaching barricades) is not something Roblox's PathfindingService knows.
--
--  World    The map is sampled with raycasts and swept boxes, using the same collision rules as the
--           game's own vault checks (RespectCanCollide, the "weak" collision group), into a grid of
--           standable spots (cells, any number of floors). A spot's links to its eight neighbours
--           are worked out once and cached, because the map doesn't change: walking, jumping up a
--           ledge, mantling a higher one, dropping, crouching or going prone where there is little
--           headroom, vaulting over an obstacle low and thin enough (the game's limits, adjustable),
--           and breaching a barricade.
--  Enemies  Every other player's position, which way they are looking (their look value), and
--           whether they are crouched or prone. A spot is exposed to an enemy that has a clear line
--           to your chest at your posture (low cover hides a crouched player), is in range and has
--           you in their field of view; one that could only shoot you through a soft wall counts
--           for less; one behind you counts for little. Footsteps are heard through walls at a
--           range that grows with your speed, so sneaking and crouching are quieter than running.
--  Search   A* over that grid, time-sliced over frames so the game doesn't hitch. Cost is seconds of
--           travel plus seconds spent exposed times a weight plus noise times a weight. Goals that
--           are an enemy end at a firing position instead: a spot with a clear line to them at a
--           chosen range, scored for how badly the enemies see it, whether the target is looking
--           at it (a flank scores best) and height over them.
local Nav = { path = nil, alt = nil, status = "Off", summary = nil, marked = nil }
do
    local sqrt, abs, floor, max, min, huge, clamp = math.sqrt, math.abs, math.floor, math.max, math.min, math.huge, math.clamp
    local S = Settings
    local LEVEL = 1.4 -- floors closer than this in height share a spot
    local DIRS = {
        { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
        { 1, 1, 1.4142 }, { 1, -1, 1.4142 }, { -1, 1, 1.4142 }, { -1, -1, 1.4142 },
    }

    --// Collision queries, like the game's own \\--
    local P
    local function newParams(extra)
        local p = RaycastParams.new()
        p.FilterType = Enum.RaycastFilterType.Exclude
        local list = {}
        for _, v in Targets.ignores() do
            table.insert(list, v)
        end
        for _, v in extra or {} do
            table.insert(list, v)
        end
        p.FilterDescendantsInstances = list
        pcall(function()
            p.RespectCanCollide = true
        end)
        pcall(function()
            p.CollisionGroup = "weak"
        end)
        return p
    end
    local function ray(o, d, params)
        return Workspace:Raycast(o, d, params or P)
    end
    local function stanceH(s)
        return s == 0 and S.NavStandH or (s == 1 and S.NavCrouchH or S.NavProneH)
    end

    --// The grid \\--
    local cache = { nodes = {}, count = 0, cs = nil, map = nil }
    local function resetCache()
        cache.nodes, cache.count = {}, 0
    end
    function Nav.rebuild()
        resetCache()
        Nav.force = true
    end
    local function nodeKey(ix, iz, lv)
        return ((ix + 4096) * 8192 + (iz + 4096)) * 512 + (lv + 256)
    end

    -- The standable surface below (x, ?, z), looking from yRef up as far as a vault reaches: its
    -- height and steepness, or nil. A ceiling above is respected, so a room upstairs isn't mistaken
    -- for this floor.
    local function surfaceAt(x, yRef, z)
        local up = max(S.NavVaultMax, S.NavJumpMax) + 0.4
        local top = yRef + up
        local c = ray(Vector3.new(x, yRef + 0.4, z), Vector3.new(0, up - 0.4, 0))
        if c then
            top = c.Position.Y - 0.15
        end
        local reach = top - (yRef - S.NavDropMax - 0.5)
        local d = ray(Vector3.new(x, top, z), Vector3.new(0, -reach, 0))
        if d then
            return d.Position.Y, d.Normal.Y
        end
        return nil
    end
    -- Free height above a floor spot, and the lowest posture that fits under it (3: none).
    local function headroom(x, y, z)
        local len = S.NavStandH + 0.3
        local h = ray(Vector3.new(x, y + 0.08, z), Vector3.new(0, len, 0))
        return h and (h.Position.Y - y) or len
    end
    local function reqStance(clear)
        if clear >= S.NavStandH then
            return 0
        elseif S.NavCrouch and clear >= S.NavCrouchH then
            return 1
        elseif S.NavProne and clear >= S.NavProneH then
            return 2
        end
        return 3
    end
    local function nodeAt(ix, iz, y)
        local cs = cache.cs
        local lv = floor(y / LEVEL + 0.5)
        local key = nodeKey(ix, iz, lv)
        local n = cache.nodes[key]
        if n then
            return n
        end
        local x, z = ix * cs, iz * cs
        local clear = headroom(x, y, z)
        n = { x = x, y = y, z = z, ix = ix, iz = iz, key = key, clear = clear, req = reqStance(clear) }
        cache.nodes[key] = n
        cache.count += 1
        return n
    end
    local function nearestNode(pos)
        local cs = cache.cs
        local ix0, iz0 = floor(pos.X / cs + 0.5), floor(pos.Z / cs + 0.5)
        local best, bestD
        for r = 0, 2 do
            for ix = ix0 - r, ix0 + r do
                for iz = iz0 - r, iz0 + r do
                    if r == 0 or ix == ix0 - r or ix == ix0 + r or iz == iz0 - r or iz == iz0 + r then
                        local y, ny = surfaceAt(ix * cs, pos.Y + 0.5, iz * cs)
                        if y and ny >= 0.55 then
                            local n = nodeAt(ix, iz, y)
                            if n.req < 3 then
                                local d = (n.x - pos.X) ^ 2 + (n.z - pos.Z) ^ 2 + (n.y - pos.Y) ^ 2
                                if not bestD or d < bestD then
                                    best, bestD = n, d
                                end
                            end
                        end
                    end
                end
            end
            if best then
                return best
            end
        end
        return nil
    end

    --// Links between spots \\--
    -- Is the body clear when swept (hx, hz) from (x, z) over a floor at `level`? Steps and curbs up
    -- to the step height are stepped over, so the swept box starts above them.
    local function sweep(x, level, z, hx, hz, s, params)
        local h = stanceH(s)
        local lift = min(S.NavStep + 0.1, h - 0.6)
        local bh = h - lift
        local hit = Workspace:Blockcast(
            CFrame.new(Vector3.new(x, level + lift + bh / 2, z)), Vector3.new(S.NavBodyW, bh, S.NavBodyW),
            Vector3.new(hx, 0, hz), params or P)
        return hit == nil, hit
    end
    local function breakable(inst)
        return inst and (CollectionService:HasTag(inst, "Breakable")
            or (inst.Parent and CollectionService:HasTag(inst.Parent, "Breakable")))
    end
    -- Is there a low obstacle ahead that can be vaulted, and how thick is it? The game's own check
    -- looks a few studs ahead for a wall-like face, a top to go over, clear air above it and ground
    -- beyond. The same here, scanning forward in half-stud steps: what is in the way, whether its top
    -- is low enough (and not so low that it is just a step), where the ground comes back, and room
    -- over the top.
    local function vaultOver(node, ux, uz, len)
        local top0 = S.NavVaultMax + 0.3
        local function topAt(f)
            local h = ray(Vector3.new(node.x + ux * f, node.y + top0, node.z + uz * f), Vector3.new(0, -(top0 + 0.4), 0))
            return h and h.Position.Y or nil
        end
        local limit = len + S.NavBodyW * 0.75
        local f1, t1
        local f = S.NavBodyW * 0.5 + 0.3
        while f <= limit do
            local ty = topAt(f)
            if ty then
                local h = ty - node.y
                if h > S.NavVaultMax then
                    return nil -- too tall to go over
                elseif h >= S.NavVaultMin then
                    f1, t1 = f, ty
                    break
                end
            end
            f += 0.5
        end
        if not f1 then
            return nil
        end
        local landing
        local g = f1
        while g < f1 + S.NavVaultDepth + 0.01 do
            g += 0.5
            local ty = topAt(g)
            if ty and ty - node.y <= S.NavStep then
                landing = g
                break
            end
        end
        if not landing or landing > limit + 0.01 then
            return nil
        end
        if ray(Vector3.new(node.x + ux * f1, t1 + 0.1, node.z + uz * f1), Vector3.new(0, S.NavCrouchH, 0)) then
            return nil -- no room over the top
        end
        return landing - f1
    end

    local function buildEdges(node)
        local edges = {}
        local cs = cache.cs
        local maxS = S.NavProne and 2 or (S.NavCrouch and 1 or 0)
        for _, d in DIRS do
            local dx, dz, mul = d[1], d[2], d[3]
            local hx, hz = dx * cs, dz * cs
            local ty, ny = surfaceAt(node.x + hx, node.y, node.z + hz)
            if ty and ny >= 0.55 then
                local dy = ty - node.y
                local to = nodeAt(node.ix + dx, node.iz + dz, ty)
                local len = cs * mul
                if to.req <= maxS then
                    local e
                    if dy >= -S.NavStep and dy <= S.NavStep then
                        local firstHit
                        for s = max(node.req, to.req), maxS do
                            local ok, hit = sweep(node.x, max(node.y, ty), node.z, hx, hz, s)
                            if ok then
                                e = { to = to, kind = "walk", stance = s, len = len, extra = 0, loud = 1 }
                                break
                            end
                            firstHit = firstHit or hit
                        end
                        if not e and firstHit and S.NavBreach and node.req == 0 and breakable(firstHit.Instance) then
                            local inst = breakable(firstHit.Instance) and firstHit.Instance
                            local p2 = newParams({ inst, inst.Parent })
                            if sweep(node.x, max(node.y, ty), node.z, hx, hz, 0, p2) then
                                e = { to = to, kind = "breach", stance = 0, len = len, extra = S.NavBreachTime, loud = 3 }
                            end
                        end
                        if not e and S.NavVault and node.req == 0 and to.req == 0 then
                            local depth = vaultOver(node, dx / mul, dz / mul, len)
                            if depth then
                                e = { to = to, kind = "vault", stance = 0, len = len, extra = S.NavVaultTime + depth * 0.1, loud = 1.4 }
                            end
                        end
                    elseif dy > S.NavStep and dy <= S.NavVaultMax and node.req == 0 and to.req == 0 then
                        local jump = dy <= S.NavJumpMax
                        if jump and S.NavJump or (not jump and S.NavVault) then
                            if sweep(node.x, ty, node.z, hx, hz, 0) then
                                e = {
                                    to = to, kind = jump and "jump" or "mantle", stance = 0, len = len,
                                    extra = jump and S.NavJumpTime or S.NavVaultTime, loud = 1.4,
                                }
                            end
                        end
                    elseif dy < -S.NavStep and dy >= -S.NavDropMax and S.NavDrop then
                        for s = max(node.req, to.req), maxS do
                            if sweep(node.x, node.y, node.z, hx, hz, s) then
                                e = { to = to, kind = "drop", stance = s, len = len, extra = 0.2 + 0.08 * -dy, loud = 1.6 }
                                break
                            end
                        end
                    end
                    if e then
                        table.insert(edges, e)
                    end
                end
            end
        end
        return edges
    end
    local function edgesOf(node)
        if not node.edges then
            node.edges = buildEdges(node)
        end
        return node.edges
    end

    --// What the enemies can see and hear \\--
    local function styleMult()
        local st = S.NavStyle
        if st == "Fastest" then
            return 0.1, 0.1
        elseif st == "Stealth" then
            return 2.5, 2.5
        end
        return 1, 1
    end
    local function speedFor(s)
        local base = S.NavBaseSpeed
        local ms = S.NavMoveStyle
        local v
        if s == 2 then
            v = base * 0.3
        elseif s == 1 then
            v = base * 0.5
        elseif ms == "Run" then
            v = base * 1.5
        elseif ms == "Walk" then
            v = base * 0.9
        else
            v = base * 0.45
        end
        if s > 0 and ms == "Sneak" then
            v *= 0.5
        end
        return v
    end
    local function hearRadius(speed, loud)
        return S.NavHear * speed / (S.NavBaseSpeed * 1.5) * loud
    end
    -- How much an enemy is looking toward a spot (1 inside their field of view, down to NavBehind
    -- directly behind them).
    local function facingFactor(e, dx, dz)
        if not (S.NavUseLook and e.look) then
            return 1
        end
        local m = sqrt(dx * dx + dz * dz)
        if m < 0.01 then
            return 1
        end
        local cosT = (e.look.X * dx + e.look.Z * dz) / m
        local cosHalf = math.cos(math.rad(S.NavFov / 2))
        if cosT >= cosHalf then
            return 1
        end
        return S.NavBehind + (1 - S.NavBehind) * clamp((cosT + 1) / (cosHalf + 1), 0, 1)
    end
    local function chestAt(node, s)
        return Vector3.new(node.x, node.y + stanceH(s) * 0.65, node.z)
    end
    -- Exposure of a spot at a posture: how badly it is seen (summed over enemies) plus who is near
    -- enough to hear it. Cached for the plan.
    local function exposure(plan, node, s)
        local k = node.key * 4 + s
        local c = plan.expo[k]
        if c then
            return c[1], c[2]
        end
        local chest = chestAt(node, s)
        local risk, near = 0, {}
        for _, e in plan.enemies do
            local dx, dy, dz = chest.X - e.head.X, chest.Y - e.head.Y, chest.Z - e.head.Z
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d <= S.NavSight or d <= S.NavHear * 1.6 then
                local seen = false
                if d <= S.NavSight then
                    local facing = facingFactor(e, dx, dz)
                    local f = 0
                    if Targets.clear(e.head, chest, false) then
                        f, seen = 1, true
                    elseif S.NavWallbang and Targets.clear(e.head, chest, true) then
                        f = S.NavWallbangW
                    end
                    risk += f * facing * (1 - 0.65 * d / S.NavSight)
                end
                table.insert(near, { dist = d, seen = seen })
            end
        end
        plan.expo[k] = { risk, near }
        return risk, near
    end
    local function teamCover(plan, node)
        local best = huge
        for _, p in plan.team do
            local d = sqrt((p.X - node.x) ^ 2 + (p.Z - node.z) ^ 2)
            if d < best then
                best = d
            end
        end
        return best < 15 and S.NavTeamCover * (1 - best / 15) or 0
    end
    local function edgeCost(plan, e)
        local to = e.to
        local speed = speedFor(e.stance)
        local time = e.len / speed + e.extra
        local sm, nm = styleMult()
        local risk, near = exposure(plan, to, e.stance)
        risk *= 1 - teamCover(plan, to)
        local cost = S.NavTimeW * time + S.NavSightW * sm * risk * time
        local hr = hearRadius(speed, e.loud)
        local noise = 0
        for _, n in near do
            if n.dist < hr then
                noise += (1 - n.dist / hr) * (n.seen and 1 or S.NavMuffle)
            end
        end
        cost += S.NavNoiseW * nm * noise * time
        if plan.avoid and plan.avoid[to.key] then
            cost += plan.avoidCost
        end
        return cost, time, risk
    end

    --// Goals \\--
    local function hdist(node, pos)
        return sqrt((node.x - pos.X) ^ 2 + (node.z - pos.Z) ^ 2)
    end
    -- A goal that is a place: arrive within a few studs; the cost of standing there a while goes in.
    local function pointGoal(pos, label)
        local maxSpeed = S.NavBaseSpeed * 1.5
        return {
            label = label, pos = pos,
            test = function(node)
                return hdist(node, pos) <= S.NavArrive and abs(node.y - pos.Y) <= 5
            end,
            h = function(node)
                return max(0, hdist(node, pos) - S.NavArrive) / maxSpeed * S.NavTimeW
            end,
            terminal = function(plan, node)
                local sm = styleMult()
                return S.NavSightW * sm * (exposure(plan, node, 0)) * S.NavDwell
            end,
        }
    end
    -- A goal that is an enemy: a firing position at the chosen range with a clear line to them.
    local function enemyGoal(tgt, label)
        local maxSpeed = S.NavBaseSpeed * 1.5
        local ideal = (S.NavEngageMin + S.NavEngageMax) / 2
        return {
            label = label, pos = tgt.pos, enemy = true,
            test = function(node)
                local d = hdist(node, tgt.pos)
                if d < S.NavEngageMin or d > S.NavEngageMax or abs(node.y - tgt.pos.Y) > 12 or node.req > 0 then
                    return false
                end
                return Targets.clear(chestAt(node, 0), tgt.head, S.AimThroughWalls)
            end,
            h = function(node)
                return max(0, hdist(node, tgt.pos) - S.NavEngageMax) / maxSpeed * S.NavTimeW
            end,
            terminal = function(plan, node)
                local sm = styleMult()
                local risk = exposure(plan, node, 0)
                local d = hdist(node, tgt.pos)
                local first = facingFactor(tgt, node.x - tgt.pos.X, node.z - tgt.pos.Z) * S.NavFirstStrike
                local high = clamp((node.y - tgt.pos.Y) / 6, -1, 1) * S.NavHighGround
                local rangePen = abs(d - ideal) / max(1, S.NavEngageMax - S.NavEngageMin) * 1.5
                return max(0, S.NavSightW * sm * risk * S.NavDwell + first * 4 + rangePen - high * 2 + 3)
            end,
        }
    end

    --// The search \\--
    local function hpush(h, item, f)
        local n = #h.items + 1
        h.items[n], h.fs[n] = item, f
        while n > 1 do
            local p = n // 2
            if h.fs[p] <= h.fs[n] then
                break
            end
            h.items[p], h.items[n], h.fs[p], h.fs[n] = h.items[n], h.items[p], h.fs[n], h.fs[p]
            n = p
        end
    end
    local function hpop(h)
        local n = #h.items
        if n == 0 then
            return nil
        end
        local top, topF = h.items[1], h.fs[1]
        h.items[1], h.fs[1] = h.items[n], h.fs[n]
        h.items[n], h.fs[n] = nil, nil
        n -= 1
        local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= n and h.fs[l] < h.fs[m] then
                m = l
            end
            if r <= n and h.fs[r] < h.fs[m] then
                m = r
            end
            if m == i then
                break
            end
            h.items[m], h.items[i], h.fs[m], h.fs[i] = h.items[i], h.items[m], h.fs[i], h.fs[m]
            i = m
        end
        return top, topF
    end

    local function newPlan(startNode, goal, enemies, team, avoid)
        local plan = {
            start = startNode, goal = goal, enemies = enemies, team = team, avoid = avoid, avoidCost = 8,
            heap = { items = {}, fs = {} }, g = { [startNode.key] = 0 }, parent = {}, via = {}, closed = {},
            expo = {}, exp = 0, nodes = { [startNode.key] = startNode }, done = false,
            -- greed > 1 searches far fewer spots (weighted A*) for a route that may be a little longer
            hw = max(1, S.NavGreed) * (S.NavStyle == "Stealth" and 1.4 or 1),
        }
        hpush(plan.heap, { node = startNode }, goal.h(startNode) * plan.hw)
        return plan
    end
    -- Works on the search until the deadline. Sets plan.done, and plan.final when a route was found.
    local function planStep(plan, deadline)
        local goal, heap = plan.goal, plan.heap
        local limit = plan.limit
        local sx, sz = plan.start.x, plan.start.z
        local gx, gz = goal.pos.X, goal.pos.Z
        local ellipse = plan.ellipse
        while os.clock() < deadline do
            local item, f = hpop(heap)
            if not item then
                plan.done = true
                return
            end
            if item.goal then
                plan.done, plan.final, plan.total = true, item.from, f
                return
            end
            local node = item.node
            if not plan.closed[node.key] then
                plan.closed[node.key] = true
                plan.exp += 1
                if goal.test(node) then
                    hpush(heap, { goal = true, from = node }, plan.g[node.key] + goal.terminal(plan, node))
                end
                if plan.exp >= S.NavMaxNodes then
                    -- out of budget: settle for the closest the search got to the goal
                    plan.done, plan.capped = true, true
                    local bestN, bestH
                    for key in plan.closed do
                        local n = plan.nodes[key]
                        local h = goal.h(n)
                        if not bestH or h < bestH then
                            bestN, bestH = n, h
                        end
                    end
                    if bestN and bestN ~= plan.start then
                        plan.final, plan.partial, plan.total = bestN, true, plan.g[bestN.key]
                    end
                    return
                end
                local gHere = plan.g[node.key]
                for _, e in edgesOf(node) do
                    local to = e.to
                    -- only places a sensible detour could pass through: not too far from where you are, and
                    -- start -> here -> goal not much longer than start -> goal
                    local fromStart = sqrt((to.x - sx) ^ 2 + (to.z - sz) ^ 2)
                    if not plan.closed[to.key] and fromStart <= limit
                        and fromStart + sqrt((to.x - gx) ^ 2 + (to.z - gz) ^ 2) <= ellipse then
                        local c, time, risk = edgeCost(plan, e)
                        local ng = gHere + c
                        if ng < (plan.g[to.key] or huge) then
                            plan.g[to.key], plan.parent[to.key] = ng, node
                            plan.via[to.key] = { edge = e, time = time, risk = risk }
                            plan.nodes[to.key] = to
                            hpush(heap, { node = to }, ng + goal.h(to) * plan.hw)
                        end
                    end
                end
            end
        end
    end

    -- The route found, as points from your position on: where, how you get there, at what posture,
    -- how exposed. Straight runs are merged into one segment; nothing that matters is dropped.
    local function buildPath(plan, startPos)
        local chain = {}
        local n = plan.final
        while n and n ~= plan.start do
            table.insert(chain, 1, n)
            n = plan.parent[n.key]
        end
        local pts = { { pos = startPos, kind = "start", stance = plan.start.req, risk = 0, time = 0 } }
        local length, time, vaults, jumps, drops, breaches = 0, 0, 0, 0, 0, 0
        local riskSum, riskMax, exposed = 0, 0, 0
        for _, node in chain do
            local v = plan.via[node.key]
            local e = v.edge
            table.insert(pts, {
                pos = Vector3.new(node.x, node.y, node.z), kind = e.kind, stance = e.stance, risk = v.risk, time = v.time,
            })
            length += e.len
            time += v.time
            riskSum += v.risk * v.time
            riskMax = max(riskMax, v.risk)
            if v.risk > 0.2 then
                exposed += v.time
            end
            if e.kind == "vault" or e.kind == "mantle" then
                vaults += 1
            elseif e.kind == "jump" then
                jumps += 1
            elseif e.kind == "drop" then
                drops += 1
            elseif e.kind == "breach" then
                breaches += 1
            end
        end
        if S.NavSmooth then
            -- merge points that lie on one straight run (same posture, plain walking, flat)
            local out = { pts[1] }
            local i = 2
            while i <= #pts do
                local a, b = out[#out], pts[i]
                local c = pts[i + 1]
                if c and b.kind == "walk" and c.kind == "walk" and b.stance == c.stance and abs(b.pos.Y - c.pos.Y) < 0.3
                    and abs(b.pos.Y - a.pos.Y) < 0.3 then
                    local ab = Vector3.new(b.pos.X - a.pos.X, 0, b.pos.Z - a.pos.Z)
                    local bc = Vector3.new(c.pos.X - b.pos.X, 0, c.pos.Z - b.pos.Z)
                    local cross = abs(ab.X * bc.Z - ab.Z * bc.X)
                    if cross < 0.01 * ab.Magnitude * bc.Magnitude + 0.001 then
                        b = nil
                    end
                end
                if b then
                    table.insert(out, b)
                end
                i += 1
            end
            pts = out
        end
        return {
            points = pts, length = length, time = time, vaults = vaults, jumps = jumps, drops = drops, breaches = breaches,
            risk = time > 0 and riskSum / time or 0, riskMax = riskMax, exposed = exposed, cost = plan.total, nodes = plan.exp,
        }
    end

    --// Reading the game \\--
    local function myRoot()
        local c = LocalPlayer.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end
    local function lookOf(t)
        local v = Targets.charValue(t.model, "look")
        if typeof(v) == "Vector3" then
            local m = sqrt(v.X * v.X + v.Z * v.Z)
            if m > 0.05 then
                return Vector3.new(v.X / m, 0, v.Z / m)
            end
        end
        return nil
    end
    local function snapshot()
        local enemies, team = {}, {}
        for _, t in Targets.all() do
            if t.team then
                table.insert(team, t.root.Position)
            else
                table.insert(enemies, {
                    head = Targets.aimPos(t, "Head"), pos = t.root.Position, look = lookOf(t), t = t,
                    name = t.model.Name,
                })
            end
        end
        return enemies, team
    end
    local function findByName(list, text)
        text = (text or ""):lower()
        if text == "" then
            return nil
        end
        for _, e in list do
            local plr = Players:GetPlayerFromCharacter(e.t.model)
            local names = (e.name .. " " .. (plr and plr.DisplayName or "")):lower()
            if names:find(text, 1, true) then
                return e
            end
        end
        return nil
    end
    local function nearest(list, from)
        local best, bestD
        for _, e in list do
            local d = (e.pos - from).Magnitude
            if not bestD or d < bestD then
                best, bestD = e, d
            end
        end
        return best
    end
    -- Where the defuser is and what is going on with it: carried (by whom), dropped or planted.
    local function defuserState()
        for _, plr in Players:GetPlayers() do
            if plr:GetAttribute("HasDefuser") then
                return "carried", plr
            end
        end
        for _, inst in CollectionService:GetTagged("Defuser") do
            if inst:IsDescendantOf(Workspace) then
                local root = inst:FindFirstChild("Root") or inst
                local pos = root:IsA("BasePart") and root.Position or (inst:IsA("Model") and inst:GetPivot().Position)
                if pos then
                    return inst:GetAttribute("Planted") and "planted" or "dropped", pos
                end
            end
        end
        return nil
    end
    local function zonePos(text)
        text = (text or ""):lower()
        if text == "" then
            return nil
        end
        local best
        for _, f in CollectionService:GetTagged("Zone") do
            local cfg = f:FindFirstChild("Zone")
            local nm = cfg and cfg:FindFirstChild("name")
            if (f.Name:lower():find(text, 1, true) or (nm and tostring(nm.Value):lower() == text))
                and not f:FindFirstAncestor("LoadoutCubicle") then
                local sum, n = Vector3.new(0, 0, 0), 0
                for _, d in f:GetDescendants() do
                    if d:IsA("BasePart") then
                        sum += d.Position
                        n += 1
                    end
                end
                if n > 0 then
                    best = best or { pos = sum / n, name = f.Name }
                end
            end
        end
        return best
    end
    -- The goal to plan for, or nil and why.
    local function resolveGoal(enemies, team, from)
        local g = S.NavGoal
        if g == "Defuser" then
            local state, what = defuserState()
            if not state then
                return nil, "no defuser around"
            end
            if state == "carried" then
                if what == LocalPlayer then
                    return nil, "you carry the defuser: pick a zone or mark a point"
                end
                local char = what.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not root then
                    return nil, "the defuser carrier isn't in the world"
                end
                return pointGoal(root.Position, "the defuser carrier (" .. what.Name .. ")")
            end
            return pointGoal(what, "the " .. state .. " defuser")
        elseif g == "Enemy (nearest)" or g == "Enemy (by name)" then
            local e = g == "Enemy (nearest)" and nearest(enemies, from) or findByName(enemies, S.NavTarget)
            if not e then
                return nil, g == "Enemy (nearest)" and "no enemies" or "no enemy matches that name"
            end
            return enemyGoal(e, "enemy " .. e.name)
        elseif g == "Enemy cluster" then
            if #enemies == 0 then
                return nil, "no enemies"
            end
            local sum = Vector3.new(0, 0, 0)
            for _, e in enemies do
                sum += e.pos
            end
            local c = sum / #enemies
            local tgt = nearest(enemies, c)
            return enemyGoal({ pos = c, head = c + Vector3.new(0, 1.6, 0), look = tgt.look }, "the enemy group")
        elseif g == "Teammate" then
            if #team == 0 then
                return nil, "no teammates"
            end
            local best, bd
            for _, p in team do
                local d = (p - from).Magnitude
                if not bd or d < bd then
                    best, bd = p, d
                end
            end
            return pointGoal(best, "your nearest teammate")
        elseif g == "Zone (by name)" then
            local z = zonePos(S.NavTarget)
            if not z then
                return nil, "no zone matches that name"
            end
            return pointGoal(z.pos, "zone " .. z.name)
        elseif g == "Crosshair point" then
            local cam = camera()
            local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 400, newParams())
            if not hit then
                return nil, "nothing under the crosshair"
            end
            return pointGoal(hit.Position, "the crosshair point")
        elseif g == "Marked point" then
            if not Nav.marked then
                return nil, "no point marked yet"
            end
            return pointGoal(Nav.marked, "the marked point")
        end
        return nil, "unknown goal"
    end
    -- Remembers where the crosshair points as the "Marked point" goal.
    function Nav.mark()
        local cam = camera()
        local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 400, newParams())
        Nav.marked = hit and hit.Position or nil
        return Nav.marked ~= nil
    end

    --// Planning, replanning \\--
    local current, lastPlan, altPlan = nil, -10, nil
    -- What the cached links depend on: change any of it and they are worked out again.
    local MOVE_KEYS = {
        "NavVault", "NavJump", "NavDrop", "NavCrouch", "NavProne", "NavBreach", "NavVaultMax", "NavVaultMin",
        "NavVaultDepth", "NavStep", "NavJumpMax", "NavDropMax", "NavBodyW", "NavStandH", "NavCrouchH", "NavProneH",
        "NavCell", "NavVaultTime", "NavJumpTime", "NavBreachTime",
    }
    local function moveSignature()
        local t = {}
        for i, k in MOVE_KEYS do
            t[i] = tostring(S[k])
        end
        return table.concat(t, ",")
    end
    local function describe(path)
        local bits = { ("%dm"):format(floor(path.length + 0.5)), ("%ds"):format(floor(path.time + 0.5)) }
        if path.vaults > 0 then
            table.insert(bits, path.vaults .. " vault")
        end
        if path.jumps > 0 then
            table.insert(bits, path.jumps .. " jump")
        end
        if path.drops > 0 then
            table.insert(bits, path.drops .. " drop")
        end
        if path.breaches > 0 then
            table.insert(bits, path.breaches .. " breach")
        end
        local rating = path.risk < 0.1 and "hidden" or (path.risk < 0.4 and "low" or (path.risk < 0.9 and "medium" or "high"))
        table.insert(bits, "exposure " .. rating)
        if path.exposed > 0.5 then
            table.insert(bits, ("%ds in view"):format(floor(path.exposed + 0.5)))
        end
        return table.concat(bits, ", ")
    end
    local function startPlan(avoid, quiet)
        local root = myRoot()
        if not root then
            if not quiet then
                Nav.status = "Waiting for your character"
            end
            return false
        end
        local cs = clamp(S.NavCell, 1.5, 6)
        if cache.cs ~= cs or cache.count > 60000 then
            cache.cs = cs
            resetCache()
        end
        P = newParams()
        local from = root.Position
        local enemies, team = snapshot()
        local goal, why = resolveGoal(enemies, team, from)
        if not goal then
            if not quiet then
                Nav.status, Nav.path, Nav.alt = "No route: " .. tostring(why), nil, nil
            end
            return false
        end
        local startNode = nearestNode(from - Vector3.new(0, 2.8, 0)) or nearestNode(from)
        if not startNode then
            if not quiet then
                Nav.status = "No route: nowhere to stand here"
            end
            return false
        end
        local plan = newPlan(startNode, goal, enemies, team, avoid)
        local straight = sqrt((goal.pos.X - from.X) ^ 2 + (goal.pos.Z - from.Z) ^ 2)
        plan.limit = max(S.NavRadius, straight * 1.6)
        plan.ellipse = S.NavDetour * straight + 24
        plan.startPos = Vector3.new(from.X, startNode.y, from.Z)
        plan.begun = os.clock()
        return plan
    end
    local function finish(plan, isAlt)
        if not plan.final then
            if not isAlt then
                Nav.path, Nav.alt = nil, nil
                Nav.status = plan.capped and "No route found within the node limit (raise it, or the goal is far)"
                    or ("No route to " .. plan.goal.label .. " (blocked, or too far for the search radius)")
            end
            return
        end
        local path = buildPath(plan, plan.startPos)
        path.goal, path.partial = plan.goal, plan.partial
        if isAlt then
            Nav.alt = path
        else
            Nav.path = path
            Nav.summary = (plan.partial and "Partial route toward " or "Route to ") .. plan.goal.label .. ": " .. describe(path)
                .. (plan.partial and " (search limit reached: raise Max spots or Search greed)" or "")
            Nav.status = Nav.summary
        end
    end
    -- Keys of the spots near the route, to push a second route away from it.
    local function nearPath(path)
        local avoid = {}
        for _, p in path.points do
            local n = nearestNode(p.pos)
            if n then
                for ix = -1, 1 do
                    for iz = -1, 1 do
                        avoid[nodeKey(n.ix + ix, n.iz + iz, floor(n.y / LEVEL + 0.5))] = true
                    end
                end
            end
        end
        return avoid
    end

    -- Called every frame: advances whatever is being planned, starts replans, and drops the path
    -- if the planner is off. Returns nothing.
    function Nav.update()
        if not S.Nav then
            if Nav.path or current then
                Nav.path, Nav.alt, current, altPlan = nil, nil, nil, nil
            end
            Nav.status = "Off"
            return
        end
        local now = os.clock()
        local map = Workspace:GetAttribute("CurrentMap")
        local sig = moveSignature()
        if cache.map ~= map or cache.sig ~= sig then
            cache.map, cache.sig = map, sig
            resetCache()
        end
        if not current and not altPlan then
            local stale = now - lastPlan >= S.NavReplan
            if Nav.path and not stale and not Nav.force then
                -- off the route? plan again now
                local root = myRoot()
                if root then
                    local best = huge
                    for _, p in Nav.path.points do
                        best = min(best, sqrt((p.pos.X - root.Position.X) ^ 2 + (p.pos.Z - root.Position.Z) ^ 2))
                    end
                    stale = best > S.NavDeviate
                end
            end
            if stale or Nav.force or not Nav.path then
                Nav.force = false
                local plan = startPlan(nil)
                if plan then
                    current = plan
                end
            end
        end
        local budget = S.NavBudget / 1000
        if current then
            planStep(current, os.clock() + budget)
            if current.done then
                local plan = current
                current, lastPlan = nil, os.clock()
                finish(plan, false)
                if plan.final and S.NavAlt then
                    local alt = startPlan(nearPath(Nav.path), true)
                    if alt then
                        altPlan = alt
                    end
                elseif not S.NavAlt then
                    Nav.alt = nil
                end
            else
                Nav.status = ("Planning... %d spots looked at"):format(current.exp)
            end
        elseif altPlan then
            planStep(altPlan, os.clock() + budget)
            if altPlan.done then
                local plan = altPlan
                altPlan = nil
                finish(plan, true)
            end
        end
    end

    --// Drawing the route \\--
    -- World-space lines on screen. A segment half behind the camera is cut at the camera's near plane
    -- so the part in front still shows.
    local lines, texts = {}, {}
    local GREEN, YELLOW, RED = Color3.fromRGB(80, 255, 110), Color3.fromRGB(255, 210, 60), Color3.fromRGB(255, 70, 70)
    local ALT = Color3.fromRGB(90, 170, 255)
    local function mk(class, props)
        local ok, d = pcall(Drawing.new, class)
        if not ok then
            return nil
        end
        for k, v in props do
            d[k] = v
        end
        return d
    end
    local function line(i)
        local l = lines[i]
        if l == nil then
            l = mk("Line", { Visible = false, Thickness = 2 }) or false
            lines[i] = l
        end
        return l
    end
    local function text(i)
        local t = texts[i]
        if t == nil then
            t = mk("Text", { Visible = false, Size = 13, Center = true, Outline = true }) or false
            texts[i] = t
        end
        return t
    end
    local function riskColor(r)
        local t = clamp(r / 1.2, 0, 1)
        if t < 0.5 then
            return GREEN:Lerp(YELLOW, t * 2)
        end
        return YELLOW:Lerp(RED, (t - 0.5) * 2)
    end
    local NEAR = -0.5
    local function segment(cam, a, b)
        local cf = cam.CFrame
        local la, lb = cf:PointToObjectSpace(a), cf:PointToObjectSpace(b)
        if la.Z > NEAR and lb.Z > NEAR then
            return nil
        end
        if la.Z > NEAR then
            a = a + (b - a) * ((NEAR - la.Z) / (lb.Z - la.Z))
        elseif lb.Z > NEAR then
            b = b + (a - b) * ((NEAR - lb.Z) / (la.Z - lb.Z))
        end
        local sa, sb = cam:WorldToViewportPoint(a), cam:WorldToViewportPoint(b)
        return Vector2.new(sa.X, sa.Y), Vector2.new(sb.X, sb.Y)
    end
    local LABEL = { vault = "VAULT", mantle = "CLIMB UP", jump = "JUMP", drop = "DROP", breach = "BREACH" }
    local STANCE = { [1] = "CROUCH", [2] = "PRONE" }
    local hud
    local function hide(from)
        for i = from, #lines do
            if lines[i] then
                lines[i].Visible = false
            end
        end
    end
    local function hideTexts(from)
        for i = from, #texts do
            if texts[i] then
                texts[i].Visible = false
            end
        end
    end

    function Nav.draw()
        local path = Nav.path
        if not (S.Nav and S.NavDraw and path) or #path.points < 2 then
            hide(1)
            hideTexts(1)
            if hud then
                hud.Visible = false
            end
            return
        end
        local cam = camera()
        local root = myRoot()
        local lift = Vector3.new(0, S.NavHeight, 0)
        -- the part of the route still ahead of you
        local first = 1
        if root then
            local best = huge
            for i, p in path.points do
                local d = (p.pos.X - root.Position.X) ^ 2 + (p.pos.Z - root.Position.Z) ^ 2
                if d < best then
                    best, first = d, i
                end
            end
        end
        local li, ti = 0, 0
        local function drawRun(points, from, colorOf)
            -- from your own position (at the route's height) to the next point, then on along it
            local prev = root and Vector3.new(root.Position.X, points[from].pos.Y, root.Position.Z) or points[from].pos
            for i = root and from or from + 1, #points do
                local p = points[i]
                local a, b = segment(cam, prev + lift, p.pos + lift)
                if a and li < 160 then
                    li += 1
                    local l = line(li)
                    if l then
                        l.From, l.To, l.Color, l.Thickness, l.Visible = a, b, colorOf(p), S.NavThickness, true
                    end
                end
                prev = p.pos
            end
        end
        drawRun(path.points, first, function(p)
            return riskColor(p.risk)
        end)
        if Nav.alt and #Nav.alt.points > 1 then
            drawRun(Nav.alt.points, 1, function()
                return ALT
            end)
        end
        hide(li + 1)
        local nextAction
        if S.NavLabels then
            local lastStance = path.points[first].stance
            for i = first + 1, #path.points do
                local p = path.points[i]
                local label = LABEL[p.kind] or (p.stance ~= lastStance and STANCE[p.stance]) or nil
                lastStance = p.stance
                if label then
                    if not nextAction and root then
                        nextAction = { label = label, dist = (p.pos - root.Position).Magnitude }
                    end
                    local sp, on = cam:WorldToViewportPoint(p.pos + lift * 3)
                    if on and ti < 12 then
                        ti += 1
                        local t = text(ti)
                        if t then
                            t.Text, t.Position, t.Color, t.Visible = label, Vector2.new(sp.X, sp.Y), Color3.new(1, 1, 1), true
                        end
                    end
                end
            end
            local goalP = path.points[#path.points]
            local gp, on = cam:WorldToViewportPoint(goalP.pos + lift * 3)
            if on and ti < 12 then
                ti += 1
                local t = text(ti)
                if t then
                    t.Text, t.Position, t.Color, t.Visible = "GOAL", Vector2.new(gp.X, gp.Y), Color3.fromRGB(255, 255, 255), true
                end
            end
        end
        hideTexts(ti + 1)
        if S.NavHud then
            hud = hud or mk("Text", { Size = 14, Center = true, Outline = true, Visible = false })
            if hud then
                local msg = Nav.summary or ""
                if nextAction then
                    msg = ("%s\nNext: %s in %dm"):format(msg, nextAction.label, floor(nextAction.dist + 0.5))
                end
                hud.Text, hud.Color = msg, Color3.new(1, 1, 1)
                hud.Position = Vector2.new(cam.ViewportSize.X / 2, 96)
                hud.Visible = true
            end
        elseif hud then
            hud.Visible = false
        end
    end
    function Nav.clear()
        for _, l in lines do
            if l then
                pcall(l.Remove, l)
            end
        end
        for _, t in texts do
            if t then
                pcall(t.Remove, t)
            end
        end
        if hud then
            pcall(hud.Remove, hud)
        end
        lines, texts, hud = {}, {}, nil
    end
    table.insert(Cleanups, Nav.clear)

    Nav.describe = describe
    Nav.speedFor = speedFor
    Nav._internal = { surfaceAt = surfaceAt, nearestNode = nearestNode, edgesOf = edgesOf, resetCache = resetCache,
        newParams = function() P = newParams() return P end, setCs = function(cs) cache.cs = cs end, cache = cache,
        exposure = exposure, newPlan = newPlan, planStep = planStep, buildPath = buildPath, pointGoal = pointGoal,
        enemyGoal = enemyGoal, startPlan = startPlan, snapshot = snapshot }
end

--// Anti-AFK \\--
bind(LocalPlayer.Idled, function()
    if Settings.AntiAfk and alive() then
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end
end)

--// Main loop \\--
-- The camera step runs after everything else bound to the render step, so the game's own
-- offsets are already on the frame it turns.
local Reported = {}
local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not Reported[name] then
        Reported[name] = true
        warn(("[OperationOne] %s: %s"):format(name, tostring(err)))
    end
end
local BIND = "OperationOneAim"
pcall(RunService.UnbindFromRenderStep, RunService, BIND)
RunService:BindToRenderStep(BIND, Enum.RenderPriority.Last.Value + 10, function(dt)
    if alive() then
        guard("aimbot", Aim.step, dt)
    end
end)
table.insert(Cleanups, function()
    pcall(RunService.UnbindFromRenderStep, RunService, BIND)
end)

bind(RunService.RenderStepped, function()
    if not alive() then
        return
    end
    guard("circles", function()
        local centre = camera().ViewportSize / 2
        if FovCircle then
            FovCircle.Visible = Settings.Aimbot and Settings.ShowFOV
            FovCircle.Radius, FovCircle.Position = Settings.AimFOV, centre
        end
        if SilentCircle then
            SilentCircle.Visible = Settings.SilentAim and Settings.SilentShowFOV
            SilentCircle.Radius, SilentCircle.Position = Settings.SilentFOV, centre
        end
    end)
    guard("esp", Esp.step)
    guard("triggerbot", Aim.trigger)
    guard("gun data", Game.pump)
    guard("extras", Extras.step)
    guard("route planner", Nav.update)
    guard("route drawing", Nav.draw)
    guard("silent aim", Silent.step)
    guard("fov", World.fov)
    guard("no flash", World.noFlash)
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "OPERATION ONE",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = IsTouch and UDim2.fromOffset(520, 340) or UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/OperationOne",
})
local function toggle(box, key, text, tip, after)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
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
local function color(box, key, text)
    local label = box:AddLabel(text)
    pcall(function()
        label:AddColorPicker(key .. "Pick", {
            Default = Settings[key], Title = text,
            Callback = function(c)
                Settings[key] = c
            end,
        })
    end)
end
local function input(box, key, text, placeholder, tip)
    return box:AddInput(key, {
        Text = text, Placeholder = placeholder or "", Default = Settings[key] or "", Finished = true, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.5)
        end
    end)
end

do
    local Tab = Window:AddTab("Aim", "crosshair", "Aimbot, silent aim, trigger")
    local A = Tab:AddLeftGroupbox("Aimbot", "crosshair")
    toggle(A, "Aimbot", "Aimbot", "Turns your camera toward the enemy closest to your crosshair. Works with touch")
    dropdown(A, "AimWhen", "Aim when", { "Aiming down sights", "While shooting", "Always", "Right mouse", "Left mouse" },
        "Sights and shooting come from the gun itself, so they work on mobile")
    dropdown(A, "AimPart", "Aim at", { "Head", "Torso" })
    slider(A, "AimFOV", "FOV", 30, 600, 0, " px")
    slider(A, "Smoothness", "Smoothness", 1, 30, 0, "", "1 snaps to the target, higher is slower and smoother")
    slider(A, "AimMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(A, "VisibleOnly", "Visible only", "Skips enemies a bullet can't reach. Uses the game's own bullet rules, so thin walls and soft cover that bullets pass don't count as hiding")
    toggle(A, "StickyTarget", "Sticky target")
    toggle(A, "AimTeammates", "Include teammates")
    toggle(A, "RecoilAware", "Aim with the gun", "Measures from where your gun really points, so recoil and sway are corrected too. Turn off if the view shakes")
    toggle(A, "ShowFOV", "Show FOV circle")
    status(A, function()
        return Aim.status
    end)

    local G = Tab:AddLeftGroupbox("Targeting", "target")
    toggle(G, "PartlyVisible", "Partly visible counts", "Checks the middle, top, bottom and sides of the part, so a player with only an edge showing is still a target")
    toggle(G, "AnyBodyPart", "Fall back to other parts", "If the part you chose is hidden, aims at any other part of the body a bullet can reach")
    toggle(G, "AimThroughWalls", "Aim through shootable walls", "Off: players behind soft or thin walls (the ones bullets pass through) count as hidden. On: they are targets too. Applies to the triggerbot, and to the aimbot and silent aim while their Visible only is on")
    toggle(G, "GunRange", "Limit to gun range", "Caps distances at the gun's range stat times the scale below (the stat is a 0-100 score, so the scale is a guess to tune)")
    slider(G, "RangeScale", "Range scale", 1, 5, 1, " studs/pt")

    local S = Tab:AddRightGroupbox("Silent aim", "ghost")
    toggle(S, "SilentAim", "Silent aim", "The shot goes at the target; your camera doesn't move")
    dropdown(S, "SilentPart", "Aim at", { "Head", "Torso", "Random" })
    slider(S, "SilentFOV", "FOV", 30, 800, 0, " px", "Measured from the middle of the screen")
    slider(S, "SilentHitChance", "Hit chance", 1, 100, 0, "%", "Chance per shot that it is redirected")
    slider(S, "SilentMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(S, "SilentVisible", "Visible only", "Skips players a bullet can't reach (the game's own bullet rules, from your muzzle), so shots don't just hit a wall")
    toggle(S, "SilentNoSpread", "Cancel spread on redirect", "Zeroes the gun's spread for the shot it redirects, so hip-fired shots don't scatter around the target")
    toggle(S, "SilentLook", "Face target on shot", "Also sets your replicated look direction. Try it if shots don't register")
    toggle(S, "SilentShowFOV", "Show FOV circle")
    status(S, function()
        local l = Silent.last
        if l and os.clock() - l.at < 3 then
            return "Last redirect: " .. l.name .. (l.part and (" (" .. l.part .. ")") or "")
        end
        if not Game.live() then
            return Game.statusText() .. "\nSilent aim is off until it is found"
        end
        local gun = Game.gun()
        if gun and gun.hookError then
            return "Shot hook problem (shots still fire): " .. tostring(gun.hookError):sub(1, 90)
        end
        if gun and Settings.SilentAim and not gun.hooked then
            return "Hooking the shot..."
        end
        return gun and "Waiting for a shot" or "No gun in hand"
    end)

    local T = Tab:AddRightGroupbox("Triggerbot", "mouse-pointer-click")
    toggle(T, "Triggerbot", "Triggerbot", "Fires the game's own shoot when a bullet from your gun would hit an enemy (never a teammate). Works with touch")
    slider(T, "TriggerDelay", "Delay", 0, 300, 0, " ms")
    slider(T, "TriggerMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(T, "TriggerHeadOnly", "Head only")
    toggle(T, "TriggerOnlyAiming", "Only while aiming", "Needs the sights up. Without the gun data on a phone it can't tell, so it doesn't hold anything back")
    status(T, function()
        local method
        if Game.live() and Game.gun() then
            method = "the gun's own shoot"
        else
            local b = Press.find()
            method = b and ("a tap on " .. b.Name) or (IsTouch and "no fire button on screen" or "mouse click")
        end
        return "Fires with: " .. method .. (Aim.fireMethod and ("\nLast shot: " .. Aim.fireMethod) or "")
    end)
end

do
    local Tab = Window:AddTab("Gun", "target", "Recoil, fire rate, reload")
    local G = Tab:AddLeftGroupbox("Gun", "target")
    toggle(G, "NoRecoil", "No recoil")
    toggle(G, "NoSpread", "No spread")
    toggle(G, "FastAds", "Fast aim", "Brings the sights up almost instantly")
    toggle(G, "FastReload", "Fast reload", "Raises reload_speed. The server may still make you wait")
    slider(G, "ReloadScale", "Reload speed", 1, 3, 1, "x")
    toggle(G, "RapidFire", "Rapid fire", "Raises the fire rate your client allows. Risky: the server may cap it")
    slider(G, "RapidScale", "Fire rate", 1, 3, 1, "x")
    toggle(G, "AutoReload", "Auto reload", "Reloads when the magazine is empty")
    status(G, function()
        if not Game.live() then
            return Game.statusText() .. "\nGun mods are off until it is found"
        end
        local item = Game.gun()
        if not item then
            return "No gun in hand"
        end
        return ("%s\nrecoil %.1f/%.1f  spread %.2f  rate %d"):format(
            item.name or "gun", item.recoil_up or 0, item.recoil_side or 0, item.spread or 0,
            math.floor(item.firerate or 0))
    end)
    local P = Tab:AddRightGroupbox("Player", "user")
    toggle(P, "SpeedHack", "Speed boost", "Multiplies your speed_multiplier. Risky: the server may pull you back")
    slider(P, "SpeedScale", "Speed", 1, 2, 2, "x")
end

do
    local Tab = Window:AddTab("ESP", "eye", "Players, gear, bomb")
    local E = Tab:AddLeftGroupbox("Players", "eye")
    toggle(E, "Esp", "ESP")
    toggle(E, "EspBox", "Boxes")
    toggle(E, "EspName", "Names")
    toggle(E, "EspHealth", "Health bar")
    toggle(E, "EspDistance", "Distance")
    toggle(E, "EspWeapon", "Weapon")
    toggle(E, "EspClass", "Class")
    toggle(E, "EspSkeleton", "Skeleton")
    toggle(E, "EspLook", "Look direction", "A line along where each player is aiming")
    toggle(E, "EspTracer", "Tracers")
    toggle(E, "EspChams", "Chams", "A see-through-walls highlight on each body")
    toggle(E, "EspTeammates", "Teammates too")
    slider(E, "EspMax", "Max distance", 50, 1500, 0, " studs")
    local B = Tab:AddRightGroupbox("Gear", "map")
    toggle(B, "UtilTraps", "Traps and charges", "Claymores, mines, alarms, C4, breach charges, thermite, barbed wire...")
    toggle(B, "UtilCameras", "Cameras and drones")
    toggle(B, "UtilGrenades", "Grenades", "Thrown and launched ones")
    toggle(B, "BombEsp", "Bomb", "Where the bomb is, in the Bomb gamemode")
    slider(B, "UtilMax", "Max distance", 50, 600, 0, " studs")
    status(B, function()
        local ws = Workspace
        return ("Players found: %d\n%s on %s\nRound %s / %s\nYou: %s"):format(#Targets.all(),
            tostring(ws:GetAttribute("Gamemode") or "?"), tostring(ws:GetAttribute("CurrentMap") or "?"),
            tostring(ws:GetAttribute("Round") or "?"), tostring(ws:GetAttribute("BestOf") or "?"),
            tostring(LocalPlayer:GetAttribute("Team") or "no team"))
    end)

    local R = Tab:AddLeftGroupbox("Reachable", "crosshair")
    toggle(R, "EspReachable", "Colour by reach", "Boxes, lines and arrows take a colour for whether a bullet from you can reach the player: reachable, only through soft walls, or hidden")
    color(R, "ReachVisible", "Reachable")
    color(R, "ReachWall", "Through soft walls only")
    color(R, "ReachHidden", "Hidden")

    local A = Tab:AddLeftGroupbox("Off-screen arrows", "navigation")
    toggle(A, "EspArrows", "Arrows", "Points at players who are off screen (behind you, to the side), around an oval, the way they lie on the ground")
    toggle(A, "ArrowAlways", "Even when on screen")
    toggle(A, "ArrowDistance", "Show distance")
    slider(A, "ArrowRadius", "Oval size", 0.2, 0.48, 2, "", "How far from the middle of the screen the arrows sit")
    slider(A, "ArrowSize", "Arrow size", 8, 40, 0, " px")
    slider(A, "ArrowMax", "Max distance", 50, 1500, 0, " studs")

    local Wl = Tab:AddRightGroupbox("Walls", "brick-wall")
    toggle(Wl, "WallEsp", "Wall ESP", "Highlights walls through walls: green ones bullets pass through, orange ones they break, red ones nothing passes")
    toggle(Wl, "WallSoft", "Soft (bullets pass)")
    toggle(Wl, "WallBreakable", "Breakable")
    toggle(Wl, "WallHard", "Hard (nothing passes)")
    slider(Wl, "WallMax", "Max distance", 10, 200, 0, " studs")
    slider(Wl, "WallCount", "Most shown", 5, 120, 0, "", "The nearest ones are drawn; each one is a see-through box, so keep it low on a phone")
    slider(Wl, "WallAlpha", "Transparency", 0.3, 0.95, 2, "")
    color(Wl, "WallSoftColor", "Soft colour")
    color(Wl, "WallBreakColor", "Breakable colour")
    color(Wl, "WallHardColor", "Hard colour")
    Wl:AddButton({ Text = "Rescan walls", Func = function()
        Walls.rescan()
    end, Tooltip = "Looks through the map again (it is done once per map)" })
    status(Wl, function()
        return ("Found: %d soft, %d breakable, %d hard"):format(Walls.counts.soft, Walls.counts.breakable, Walls.counts.hard)
    end)

    local Bm = Tab:AddRightGroupbox("Bomb", "bomb")
    toggle(Bm, "BombTimer", "Timer", "When the defuser is planted, counts down the 40 seconds from when you saw it planted (a ~ means you joined after it was planted)")
    toggle(Bm, "BombCarrier", "Carrier and drop", "Marks who carries the defuser, where it was dropped, and says how far and which way")

    local Ht = Tab:AddRightGroupbox("Hit feedback", "zap")
    toggle(Ht, "HitMarkers", "Hit markers", "An X around the crosshair when you hit someone, red and bigger for a kill. Worked out from their health dropping right after one of your shots")
    toggle(Ht, "HitNumbers", "Damage numbers")
    toggle(Ht, "HitSounds", "Hit sound")
    toggle(Ht, "KillSound", "Kill sound")
    slider(Ht, "HitSize", "Marker size", 4, 24, 0, " px")
    slider(Ht, "HitTime", "Marker time", 0.1, 1, 2, " s")
    slider(Ht, "HitVolume", "Volume", 0.1, 3, 1, "")
    input(Ht, "HitSoundId", "Hit sound id", "asset id (blank: the game's own)", "A Roblox asset id for the hit sound")
    input(Ht, "KillSoundId", "Kill sound id", "asset id (blank: the game's own)", "A Roblox asset id for the kill sound")
end

do
    local Tab = Window:AddTab("Help", "compass", "Route planner")
    local N = Tab:AddLeftGroupbox("Route planner", "route")
    toggle(N, "Nav", "Show best route", "Draws a suggested way to your goal, weighing speed against being seen and heard, using every player's position and facing. It only draws: it never moves you")
    dropdown(N, "NavGoal", "Goal", { "Defuser", "Enemy (nearest)", "Enemy cluster", "Enemy (by name)", "Teammate", "Zone (by name)", "Crosshair point", "Marked point" },
        "Defuser: where it was dropped or planted, or its carrier. Enemy goals end at a firing position at your chosen range instead of on top of them")
    input(N, "NavTarget", "Name", "player or zone name", "Used by the goals that say (by name): part of a player's name or of a room's name")
    N:AddButton({ Text = "Mark crosshair point", Func = function()
        notify(Nav.mark() and "Marked. Set the goal to Marked point" or "Nothing under the crosshair", 3)
    end, Tooltip = "Remembers where you are looking, for the Marked point goal" })
    dropdown(N, "NavStyle", "Style", { "Fastest", "Balanced", "Stealth" }, "How much being seen or heard counts against time: barely, normally, a lot")
    dropdown(N, "NavMoveStyle", "How you move", { "Run", "Walk", "Sneak" }, "Sets your speed and how far your footsteps carry. Crouching and going prone are slower and quieter still")
    toggle(N, "NavAlt", "Also show another route", "A second route that keeps away from the first (blue)")
    status(N, function()
        return Nav.status
    end)
    N:AddButton({ Text = "Plan again now", Func = function()
        Nav.force = true
    end })
    N:AddButton({ Text = "Forget the map cache", Func = function()
        Nav.rebuild()
    end, Tooltip = "The map is sampled once and remembered; use this if doors or walls changed" })

    local M = Tab:AddRightGroupbox("Movement", "footprints")
    toggle(M, "NavVault", "Vault and climb up", "Go over obstacles low and thin enough, like the game's own vault")
    toggle(M, "NavJump", "Jump up ledges")
    toggle(M, "NavDrop", "Drop down")
    toggle(M, "NavCrouch", "Crouch under things")
    toggle(M, "NavProne", "Go prone under things")
    toggle(M, "NavBreach", "Breach barricades", "Counts a breakable barricade as passable, slowly and loudly")
    slider(M, "NavBaseSpeed", "Base speed", 4, 14, 1, " studs/s", "Your walking speed: running is 1.5x, crouching 0.5x, prone 0.3x")
    slider(M, "NavVaultMax", "Vault up to", 2, 6, 1, " studs")
    slider(M, "NavVaultMin", "Vault from", 0.6, 3, 1, " studs", "Lower than this is just a step")
    slider(M, "NavVaultDepth", "Vault depth", 1, 6, 1, " studs", "How thick an obstacle can be")
    slider(M, "NavStep", "Step height", 0.5, 2.5, 1, " studs", "Steps and curbs this low are walked over")
    slider(M, "NavJumpMax", "Jump up to", 1.5, 6, 1, " studs")
    slider(M, "NavDropMax", "Drop down up to", 3, 25, 0, " studs")
    slider(M, "NavBodyW", "Body width", 1, 3, 1, " studs")
    slider(M, "NavStandH", "Standing height", 3.5, 7, 1, " studs")
    slider(M, "NavCrouchH", "Crouching height", 2, 5, 1, " studs")
    slider(M, "NavProneH", "Prone height", 0.8, 3, 1, " studs")
    slider(M, "NavVaultTime", "Vault time", 0.2, 2.5, 1, " s")
    slider(M, "NavJumpTime", "Jump time", 0.1, 2, 1, " s")
    slider(M, "NavBreachTime", "Breach time", 0.5, 8, 1, " s")

    local Pc = Tab:AddLeftGroupbox("What enemies notice", "eye")
    toggle(Pc, "NavUseLook", "Use which way they face", "Off: every enemy is assumed to be looking at you")
    toggle(Pc, "NavWallbang", "Count shots through soft walls", "A spot an enemy could only hit through a soft wall is still risky, but less")
    slider(Pc, "NavSight", "Sight range", 30, 300, 0, " studs")
    slider(Pc, "NavFov", "Field of view", 40, 180, 0, " deg")
    slider(Pc, "NavBehind", "Noticed from behind", 0, 1, 2, "", "How much an enemy notices you directly behind them: 0 never, 1 as if facing you")
    slider(Pc, "NavWallbangW", "Through-wall weight", 0, 1, 2, "")
    slider(Pc, "NavHear", "Hearing range (running)", 10, 120, 0, " studs", "How far a running player's footsteps carry; walking, crouching and sneaking scale down from it")
    slider(Pc, "NavMuffle", "Walls muffle sound", 0, 1, 2, "", "How much of the noise gets through when there is no line to the enemy")

    local Wg = Tab:AddRightGroupbox("What matters", "sliders-horizontal")
    slider(Wg, "NavTimeW", "Time", 0, 3, 1, "x", "Weight of seconds spent travelling")
    slider(Wg, "NavSightW", "Being seen", 0, 20, 1, "x", "Seconds of detour you will take to avoid one second in an enemy's view")
    slider(Wg, "NavNoiseW", "Being heard", 0, 20, 1, "x")
    slider(Wg, "NavDwell", "Time spent at the goal", 0, 15, 1, " s", "How long you will stand there, which makes exposed spots at the goal cost more (planting takes 5 s)")
    slider(Wg, "NavTeamCover", "Teammates nearby", 0, 1, 2, "", "How much a teammate close by lowers the risk")
    slider(Wg, "NavHighGround", "High ground", 0, 3, 1, "x", "Bonus for a firing position above the target")
    slider(Wg, "NavFirstStrike", "Being in their sights", 0, 3, 1, "x", "Penalty for a firing position the target is looking at (they shoot first): flanks score best")
    slider(Wg, "NavEngageMin", "Closest firing position", 3, 40, 0, " studs")
    slider(Wg, "NavEngageMax", "Furthest firing position", 8, 80, 0, " studs")
    slider(Wg, "NavArrive", "Arrive within", 1.5, 10, 1, " studs", "For goals that are a place")

    local Sr = Tab:AddLeftGroupbox("Search", "cpu")
    slider(Sr, "NavCell", "Grid cell", 2, 5, 1, " studs", "Smaller finds tighter gaps but searches more")
    slider(Sr, "NavRadius", "Search radius", 40, 300, 0, " studs")
    slider(Sr, "NavDetour", "Detour allowed", 1.1, 4, 1, "x", "How much longer than a straight line a route may be")
    slider(Sr, "NavMaxNodes", "Most spots looked at", 500, 15000, 0, "", "If a plan says it hit the limit, raise this or Search greed")
    slider(Sr, "NavGreed", "Search greed", 1, 4, 1, "x", "1 finds the best route; higher looks at far fewer spots and may pick a slightly worse one")
    slider(Sr, "NavBudget", "Time per frame", 1, 12, 0, " ms", "How much work the planner may do each frame; lower keeps the game smooth")
    slider(Sr, "NavReplan", "Plan again every", 0.5, 10, 1, " s")
    slider(Sr, "NavDeviate", "Plan again if off by", 2, 20, 0, " studs")
    toggle(Sr, "NavSmooth", "Merge straight runs")

    local D = Tab:AddRightGroupbox("Display", "paintbrush")
    toggle(D, "NavDraw", "Draw the route", "Green is safe, yellow exposed, red badly exposed")
    toggle(D, "NavLabels", "Labels", "VAULT, JUMP, CROUCH and so on where they happen")
    toggle(D, "NavHud", "Summary text")
    slider(D, "NavThickness", "Line thickness", 1, 5, 0, " px")
    slider(D, "NavHeight", "Draw height", 0, 4, 1, " studs")
end

do
    local Tab = Window:AddTab("Misc", "settings", "World and script")
    local W = Tab:AddLeftGroupbox("World", "sun")
    toggle(W, "Fullbright", "Fullbright", nil, World.fullbright)
    toggle(W, "NoFlash", "No flashbang", "Hides the white-out frame (the ringing still plays)")
    toggle(W, "NoSmoke", "No smoke", "Hides smoke clouds as they appear")
    toggle(W, "FovChanger", "FOV changer", "Changes the game's own base FOV; scopes still zoom")
    slider(W, "FovValue", "FOV", 60, 120, 0, "")
    local M = Tab:AddRightGroupbox("Script", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
    toggle(M, "GunData", "Use the gun data", "Needed for the gun mods, silent aim and the trigger's precise shot. Turn it off to stop everything this script runs inside the game: if your guns misbehave, try that first")
    status(M, function()
        return Game.statusText()
    end)
    M:AddButton({ Text = "Search for gun data again", Func = function()
        Game.start(function()
            notify("Found the game's gun data", 3)
        end)
        notify("Searching for the game's gun data...", 2)
    end, Tooltip = "Needed only for silent aim and the gun options; ESP and aimbot don't use it" })
    M:AddButton({ Text = "Copy gun data report", Func = function()
        local text = Game.report()
        if typeof(setclipboard) == "function" then
            pcall(setclipboard, text)
            notify("Copied the gun data report", 3)
        else
            print(text)
            notify("No clipboard here: the report is in the console", 4)
        end
    end, Tooltip = "Copies what the search tried and found, to work out why gun data isn't found" })
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__OperationOneUnload then
            Genv.__OperationOneUnload()
        end
    end })
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
Genv.__OperationOneUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

Game.start(function()
    notify("Found the game's gun data: gun mods and silent aim are ready", 4)
end)
notify("Loaded. ESP and aimbot read players from the world; gun features wait for the game's data", 5)

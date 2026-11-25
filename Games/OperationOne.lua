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
    -- misc
    AntiAfk = true,
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
        local cf = orig(self, ...)
        if not (alive and S.SilentAim) then
            return cf
        end
        local ok, res = pcall(redirect, cf, self)
        if ok and typeof(res) == "CFrame" then
            return res
        end
        return cf
    end)
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
    }
end

local stepError = false
local function step()
    local m = me()
    local item = gunOf(m)
    mods(item, m)
    autoReload(item)
    if item then
        attach(item)
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
    for item in hooked do
        pcall(rawset, item, "get_shoot_look", nil)
    end
    table.clear(hooked)
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
    onFound = nil, onRedirect = nil,
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
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local STEPS = 12

    -- Would a bullet fired from `from` reach `to`?
    function Targets.clear(from, to)
        local vec = to - from
        if vec.Magnitude < 0.05 then
            return true
        end
        params.FilterDescendantsInstances = ignores()
        local passed, through = 0, Settings.AimThroughWalls
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

    -- Trigger: when a bullet from your gun would hit an enemy body, taps the game's own
    -- input_shoot (done by the agent, which also keeps your sights up afterwards) or, without the
    -- gun found, a mouse click.
    local lastShot, armedAt = 0, nil
    local function fire(item)
        if item and Game.active then
            Game.fire()
        elseif typeof(mouse1click) == "function" then
            mouse1click()
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
        if now - armedAt >= Settings.TriggerDelay / 1000 and now - lastShot >= 0.08 then
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
                        local w, h = x2 - x1, y2 - y1
                        local mid = (x1 + x2) / 2
                        if Settings.EspBox and e.box then
                            e.outline.Position, e.outline.Size, e.outline.Visible = Vector2.new(x1, y1), Vector2.new(w, h), true
                            e.box.Position, e.box.Size, e.box.Color, e.box.Visible = Vector2.new(x1, y1), Vector2.new(w, h), color, true
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
                        if #bits > 0 and e.info then
                            e.info.Text = table.concat(bits, "  ")
                            e.info.Position, e.info.Color, e.info.Visible = Vector2.new(mid, y2 + 2), Color3.new(1, 1, 1), true
                        else
                            e.info.Visible = false
                        end
                        if Settings.EspTracer and e.tracer then
                            e.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                            e.tracer.To, e.tracer.Color, e.tracer.Visible = Vector2.new(mid, y2), color, true
                        else
                            e.tracer.Visible = false
                        end
                        local vm = t.vm
                        for i, pair in SKELETON do
                            local a = Settings.EspSkeleton and vm and vm:FindFirstChild(pair[1])
                            local b = a and vm:FindFirstChild(pair[2])
                            if a and b and e.bones[i] then
                                line(e.bones[i], a.Position, b.Position, color)
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
        return Game.gun() and "Waiting for a shot" or "No gun in hand"
    end)

    local T = Tab:AddRightGroupbox("Triggerbot", "mouse-pointer-click")
    toggle(T, "Triggerbot", "Triggerbot", "Fires the game's own shoot when a bullet from your gun would hit an enemy (never a teammate). Works with touch")
    slider(T, "TriggerDelay", "Delay", 0, 300, 0, " ms")
    slider(T, "TriggerMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(T, "TriggerHeadOnly", "Head only")
    toggle(T, "TriggerOnlyAiming", "Only while aiming", "Needs the sights up")
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

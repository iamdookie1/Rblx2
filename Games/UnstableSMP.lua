--// UNSTABLE SMP FFA -----------------------------------------------------------------------------
-- place 76870565041704 (game 10772281976), built against version 477. Built on Ui3.
-- A Minecraft PvP recreation. Works with mouse, touch and gamepad: nothing here moves your cursor,
-- touches the screen or holds a movement key.
--
-- How the game works (as the client shows it, from the dump):
--   Units      The world is in blocks of 3 studs (Config.BLOCK). 20 ticks a second. A swing reaches 3
--              blocks (the larger of Config.REACH and the CreatorReach value on your player), a player
--              is 0.6 wide and 1.8 tall (1.5 sneaking), eyes at 1.62.
--   Players    Players, mobs and dummies are Models in Workspace (or Workspace.MCWorld.Dummies) with an
--              EntityId attribute, plus Alive, Mode, Gamemode, Sneaking, Gliding, Spinning, SizeScale,
--              BoxHeight, BoxWidth, LookSlot. Kit, Kills and Mode are also on each Player. The game's
--              own World module reads them (World.models / feet / height / width / pick) and its
--              Controller holds your own yaw, pitch, state (pos, fallDistance, onGround...) and tick.
--   Looking    The camera is driven from Controller.yaw and Controller.pitch (not Roblox's camera
--              module); an attack takes its origin and direction from Controller.eye() / look(), so
--              steering the view is just writing those two numbers, like the game's own updateLook.
--   Attacking  Input.onPressed("attack") queues an attack for the next 20 Hz tick; the attack then picks a
--              target with World.pick(eye, look, reach) and sends it. Hands.strength(0) is the weapon's
--              charge (0..1) and Hands.heldDef() the weapon (kind, damage, speed). The game sorts a swing
--              as weak, strong (charge over 0.9), crit (strong, falling, not sprinting), knockback
--              (strong, sprinting), sweep (strong sword on the ground) or smash (a mace falling over
--              1.5 blocks); the HUD here reads it the same way.
--   Pressing   Input.setVirtual(action, down) is how the on-screen touch buttons press things: it runs
--              the game's handlers in a new thread, so it needs no cursor, touch or key and leaves your
--              movement alone. The auto attack uses it and nothing else.
--   Net        Net.send marks an action q = 1 when anything outside the game's own scripts is on the
--              call stack, stamps every action with a tick, and the server checks an attack's state
--              snapshot against its own simulation. This script never calls Net or the remotes, never
--              changes reach, speed or fall, and does nothing to influence or hide that flag: the game
--              records whatever it records, and the game also has an ACBanned attribute, so scripted
--              play here can be detected and acted on.
--
-- Everything that is read is read with the game's own functions where it has them, and falls back to
-- the Models themselves where it doesn't.

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
if Genv.__UnstableSmpUnload then
    pcall(Genv.__UnstableSmpUnload)
end
Genv.__UnstableSmpRun = (Genv.__UnstableSmpRun or 0) + 1
local RUN = Genv.__UnstableSmpRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__UnstableSmpRun == RUN
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
    -- aim assist
    AimAssist = false, AimWhen = "While attacking", AimFOV = 45, AimRange = 5, AimPoint = 0.65, AimSmooth = 5,
    AimYaw = true, AimPitch = true, AimPlayersOnly = false, AimMaxTurn = 0, AimVisible = true,
    -- auto attack
    AutoAttack = false, AutoCharge = 1, AutoMargin = 0.15, AutoDelay = 0, AutoPlayersOnly = false,
    AutoSword = true, AutoAxe = true, AutoMace = true,
    -- combat hud
    HudReach = true, HudCharge = true, HudTarget = true, HudCrit = true, HudReachSegments = 40,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspKit = true, EspKills = true, EspDist = true, EspFlags = true,
    EspHealth = true, EspTracer = false, EspLook = false, EspReach = true, EspMobs = true, EspOtherModes = false,
    EspMax = 120, EspInReach = Color3.fromRGB(80, 255, 110), EspNear = Color3.fromRGB(255, 210, 60),
    EspFar = Color3.fromRGB(255, 255, 255), EspBlocked = Color3.fromRGB(255, 80, 80),
    EspArrows = true, ArrowAlways = false, ArrowRadius = 0.42, ArrowSize = 16, ArrowMax = 120, ArrowDistance = true,
    -- hit feedback
    HitMarkers = true, KillMarkers = true, HitSize = 9, HitTime = 0.3, HitVolume = 0.6, HitSoundId = "", KillSoundId = "",
    -- world
    FovChanger = false, FovValue = 90, Fullbright = false, NoRain = false,
    -- route planner (Help tab). Distances are studs; a block is 3 studs.
    Nav = false, NavGoal = "Enemy (nearest)", NavStyle = "Balanced", NavTarget = "", NavMoveStyle = "Run", NavAlt = false,
    NavMobs = false, NavBaseSpeed = 12.9, NavVault = true, NavJump = true, NavDrop = true, NavCrouch = true, NavProne = false,
    NavVaultMax = 3.6, NavVaultMin = 1.9, NavVaultDepth = 3.5, NavStep = 1.8, NavJumpMax = 3.6,
    NavDropMax = 9, NavBodyW = 1.8, NavStandH = 5.4, NavCrouchH = 4.5, NavProneH = 1.8, NavVaultTime = 0.5,
    NavJumpTime = 0.45,
    NavSight = 150, NavFov = 110, NavBehind = 0.25, NavUseLook = true,
    NavHear = 48, NavMuffle = 0.5,
    NavTimeW = 1, NavSightW = 6, NavNoiseW = 2, NavDwell = 3, NavHighGround = 0.5,
    NavFirstStrike = 1, NavEngageMin = 4.5, NavEngageMax = 8.5, NavArrive = 3,
    NavCell = 3, NavRadius = 140, NavMaxNodes = 4000, NavGreed = 1.4, NavDetour = 2, NavBudget = 3, NavReplan = 1.5,
    NavDeviate = 6, NavSmooth = true,
    NavDraw = true, NavLabels = true, NavHud = true, NavThickness = 2, NavHeight = 0.5,
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
    pcall(Library.Notify, Library, { Title = "UNSTABLE SMP", Description = text, Time = seconds or 3 })
end
local function camera()
    return Workspace.CurrentCamera
end
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
local function hideAll(list, from)
    for i = from or 1, #list do
        if list[i] then
            list[i].Visible = false
        end
    end
end

--// The game's own modules \\--
-- Required from the game's scripts (they run in this same VM, so require returns the very tables the game
-- uses). Each is looked for again every few seconds until it is found. If an executor won't let require
-- reach them, one pass over the live tables finds them by the names of their functions instead.
local Game = { mods = {}, at = {}, fails = 0, scanAt = -100, defaults = { BLOCK = 3, REACH = 3, ROOT_OFFSET = 3.1, TICK = 0.05, SMASH_MIN_FALL = 1.5 } }
do
    local SIGNATURES = {
        ["client.World"] = { "pick", "blockRay", "models", "feet" },
        ["client.Controller"] = { "beforeTick", "onTick", "tickCount", "eye", "look" },
        ["client.Hands"] = { "attackReset", "heldDef", "strength", "cooldowns" },
        ["client.Input"] = { "setVirtual", "isDown", "onPressed", "onReleased" },
        ["client.Settings"] = { "options", "onChanged" },
        ["shared.Config"] = { "BLOCK", "REACH", "TICK", "ROOT_OFFSET" },
        ["shared.Combat"] = { "maceBonus", "sharpness", "strength", "SMASH_MIN_FALL" },
        ["shared.Items"] = { "def", "Types", "FIST" },
    }
    local function find(root, name)
        return root and root:FindFirstChild(name)
    end
    local function scan()
        if typeof(getgc) ~= "function" or os.clock() - Game.scanAt < 20 then
            return
        end
        Game.scanAt = os.clock()
        local ok, list = pcall(getgc, true)
        if not ok or type(list) ~= "table" then
            return
        end
        for _, v in list do
            if type(v) == "table" then
                for key, sig in SIGNATURES do
                    if not Game.mods[key] then
                        local good = true
                        for _, k in sig do
                            if rawget(v, k) == nil then
                                good = false
                                break
                            end
                        end
                        if good then
                            Game.mods[key] = v
                        end
                    end
                end
            end
        end
    end
    local function load(where, name)
        local key = where .. "." .. name
        local have = Game.mods[key]
        if have then
            return have
        end
        local now = os.clock()
        if Game.at[key] and now - Game.at[key] < 3 then
            return nil
        end
        Game.at[key] = now
        local folder
        if where == "client" then
            local ps = LocalPlayer:FindFirstChild("PlayerScripts")
            folder = find(ps, "MC")
        else
            folder = find(ReplicatedStorage, "MC")
        end
        local m = find(folder, name)
        if m and m:IsA("ModuleScript") then
            local ok, res = pcall(require, m)
            if ok and type(res) == "table" then
                Game.mods[key] = res
                return res
            end
            Game.fails += 1
        end
        if Game.fails >= 2 and SIGNATURES[key] then
            scan()
            return Game.mods[key]
        end
        return nil
    end
    function Game.client(name)
        return load("client", name)
    end
    function Game.shared(name)
        return load("shared", name)
    end
    function Game.world()
        return Game.client("World")
    end
    function Game.controller()
        return Game.client("Controller")
    end
    function Game.hands()
        return Game.client("Hands")
    end
    function Game.input()
        return Game.client("Input")
    end
    function Game.config()
        return Game.shared("Config")
    end
    function Game.const(name, fallback)
        local cfg = Game.config()
        local v = cfg and cfg[name]
        if v == nil then
            v = Game.defaults[name]
        end
        if v == nil then
            v = fallback
        end
        return v
    end
    -- How far a melee swing reaches, in blocks: the game's own rule is the larger of Config.REACH and the
    -- CreatorReach value on your player.
    function Game.reach()
        local extra = LocalPlayer:GetAttribute("CreatorReach")
        return math.max(Game.const("REACH", 3), type(extra) == "number" and extra or 0)
    end
    function Game.block()
        return Game.const("BLOCK")
    end
    -- Everything the combat features need, or nil with the name of what is missing.
    function Game.ready()
        for _, name in { "World", "Controller", "Hands", "Input" } do
            if not Game.client(name) then
                return nil, name
            end
        end
        local c = Game.controller()
        if not (c.state and c.state.pos and type(c.eye) == "function" and type(c.look) == "function") then
            return nil, "Controller state"
        end
        return true
    end
    -- Your own attacks are allowed right now: a living body, a mode where you can fight, not in a menu.
    function Game.canFight()
        local input, ctl = Game.input(), Game.controller()
        if not (input and ctl) then
            return false
        end
        local char = LocalPlayer.Character
        if not (input.enabled and char and char:GetAttribute("Alive")) then
            return false
        end
        if ctl.frozen or ctl.locked or ctl.state == nil then
            return false
        end
        if Workspace:GetAttribute("JugHold") == true then
            return false
        end
        local mode = LocalPlayer:GetAttribute("Gamemode") or "survival"
        return mode ~= "spectator"
    end
end

--// Players, mobs and dummies \\--
local Ent = {}
do
    local cache, cacheAt = {}, -1
    local function name(model)
        local plr = Players:GetPlayerFromCharacter(model) or Players:FindFirstChild(model.Name)
        if plr and plr:IsA("Player") then
            return plr.DisplayName ~= "" and plr.DisplayName or plr.Name, plr
        end
        return model:GetAttribute("Nick") or model:GetAttribute("DisplayName") or model.Name, nil
    end
    -- Every other body the game would let you fight, as plain tables in studs: model, id, name, player, feet
    -- (position), height, width, flags and attributes. A body in another mode is left out unless asked for.
    function Ent.all(includeOthers)
        local now = os.clock()
        if includeOthers == nil then
            includeOthers = Settings.EspOtherModes
        end
        if cache.other == includeOthers and now - cacheAt < 0.03 then
            return cache.list
        end
        local block = Game.block()
        local rootOffset = Game.const("ROOT_OFFSET")
        local world = Game.world()
        local models
        if world and type(world.models) == "function" then
            local ok, list = pcall(world.models)
            models = ok and list or nil
        end
        if not models then
            models = {}
            for _, m in Workspace:GetChildren() do
                if m:IsA("Model") and m:GetAttribute("EntityId") then
                    table.insert(models, m)
                end
            end
            local mcWorld = Workspace:FindFirstChild("MCWorld")
            local dummies = mcWorld and mcWorld:FindFirstChild("Dummies")
            for _, m in dummies and dummies:GetChildren() or {} do
                if m:GetAttribute("EntityId") then
                    table.insert(models, m)
                end
            end
        end
        local mine = LocalPlayer.Character
        local myMode = LocalPlayer:GetAttribute("Mode")
        local out = {}
        for _, model in models do
            if model ~= mine and model.Parent and model:GetAttribute("Alive") and model:GetAttribute("Gamemode") ~= "spectator"
                and (includeOthers or model:GetAttribute("Mode") == myMode) then
                local root = model.PrimaryPart
                if root then
                    local scale = model:GetAttribute("SizeScale") or 1
                    local height = (model:GetAttribute("BoxHeight") or (model:GetAttribute("Sneaking") and 1.5 or 1.8)) * scale
                    if model:GetAttribute("Gliding") or model:GetAttribute("Spinning") then
                        height = 0.6 * scale
                    end
                    local width = (model:GetAttribute("BoxWidth") or 0.6) * scale
                    local nm, plr = name(model)
                    table.insert(out, {
                        model = model, id = model:GetAttribute("EntityId"), name = nm, player = plr,
                        mob = model:GetAttribute("Mob") ~= nil or plr == nil,
                        feet = root.Position - Vector3.new(0, rootOffset, 0), height = height * block, width = width * block,
                        sneaking = model:GetAttribute("Sneaking") == true, gliding = model:GetAttribute("Gliding") == true,
                        spinning = model:GetAttribute("Spinning") == true,
                        kit = plr and plr:GetAttribute("Kit") or model:GetAttribute("Kit"),
                        kills = plr and plr:GetAttribute("Kills") or nil,
                        health = model:GetAttribute("Health") or (plr and plr:GetAttribute("Health")),
                        sameMode = model:GetAttribute("Mode") == myMode, root = root,
                    })
                end
            end
        end
        cache, cacheAt = { list = out, other = includeOthers }, now
        return out
    end
    -- Where an entity's eyes are, in studs (feet plus about 90% of its height).
    function Ent.eye(e)
        return e.feet + Vector3.new(0, e.height * 0.9, 0)
    end
    -- The way it looks: its body's facing, and (when the game has told us) how far up or down.
    function Ent.look(e)
        local cf = e.root.CFrame
        local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
        if flat.Magnitude < 0.01 then
            return Vector3.new(0, 0, -1)
        end
        flat = flat.Unit
        local pitch = 0
        local world = Game.world()
        local slot = e.model:GetAttribute("LookSlot")
        if world and type(world.pitchOf) == "function" and slot then
            local ok, p = pcall(world.pitchOf, slot, 0)
            pitch = ok and type(p) == "number" and p or 0
        end
        return Vector3.new(flat.X * math.cos(pitch), math.sin(pitch), flat.Z * math.cos(pitch))
    end
    -- Your own feet, eye and look, in studs, from the game's controller.
    function Ent.me()
        local ctl = Game.controller()
        local block = Game.block()
        if ctl and ctl.state and ctl.state.pos and type(ctl.eye) == "function" then
            local ok, eye = pcall(ctl.eye)
            if ok and typeof(eye) == "Vector3" then
                local ok2, look = pcall(ctl.look)
                return ctl.state.pos * block, eye * block, ok2 and look or camera().CFrame.LookVector
            end
        end
        local cam = camera()
        return cam.CFrame.Position - Vector3.new(0, 4.8, 0), cam.CFrame.Position, cam.CFrame.LookVector
    end
    -- Is there solid block between two points (in studs)? Uses the game's own block ray when it has one.
    function Ent.blocked(from, to)
        local world = Game.world()
        local block = Game.block()
        local d = to - from
        local dist = d.Magnitude
        if dist < 0.01 then
            return false
        end
        if world and type(world.blockRay) == "function" then
            local ok, hit = pcall(world.blockRay, from / block, d.Unit, dist / block, { "Solid" })
            if ok then
                return hit ~= nil and hit.dist * block < dist - 0.2
            end
        end
        return false
    end
end

--// Steering the view \\--
-- Look = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector = (-cos p sin y, sin p, -cos p cos y), so
-- the angles for a direction d are yaw = atan2(-dx, -dz) and pitch = asin(dy).
local Look = {}
do
    local pi = math.pi
    function Look.angles(d)
        return math.atan2(-d.X, -d.Z), math.asin(math.clamp(d.Y, -1, 1))
    end
    function Look.vector(pitch, yaw)
        local cp = math.cos(pitch)
        return Vector3.new(-cp * math.sin(yaw), math.sin(pitch), -cp * math.cos(yaw))
    end
    function Look.wrap(a)
        while a > pi do
            a -= 2 * pi
        end
        while a < -pi do
            a += 2 * pi
        end
        return a
    end
    -- The angle between two directions, in degrees.
    function Look.between(a, b)
        return math.deg(math.acos(math.clamp(a:Dot(b), -1, 1)))
    end
end

--// Combat numbers \\--
local Fight = {}
do
    -- Weapons the auto attack may swing: by kind, and the Settings that allow them.
    local KINDS = { sword = "AutoSword", axe = "AutoAxe", mace = "AutoMace" }
    function Fight.held()
        local hands = Game.hands()
        if not hands then
            return nil
        end
        local ok, def = pcall(hands.heldDef)
        return ok and def or nil, hands
    end
    -- Is the held item one the auto attack will swing? Not the size-changing "op" items, which the game
    -- turns into a different action on attack.
    function Fight.kindAllowed(def, stack)
        if stack and stack.op ~= nil then
            return false
        end
        local key = def and KINDS[def.kind]
        return key ~= nil and Settings[key] == true
    end
    -- How charged your weapon is, 0 to 1, by the game's own count.
    function Fight.charge()
        local hands = Game.hands()
        if not hands then
            return 0
        end
        local ok, s = pcall(hands.strength, 0)
        return ok and type(s) == "number" and s or 0
    end
    local function enchant(stack, name)
        local e = stack and stack.ench
        local v = type(e) == "table" and e[name]
        return type(v) == "number" and v or 0
    end
    local function stateOf()
        local ctl = Game.controller()
        return ctl and ctl.state
    end
    -- In the air and coming down.
    function Fight.falling()
        local st = stateOf()
        return st ~= nil and (st.fallDistance or 0) > 0 and not (st.onGround or st.inWater)
    end
    -- What the game itself calls a swing right now (its attack sound goes by this): "strong" needs a
    -- charge over 0.9; a critical is a strong swing while falling and not sprinting; sprinting with a
    -- strong swing is a knockback hit; a mace falling more than SMASH_MIN_FALL smashes.
    function Fight.kind()
        local st, def = stateOf(), Fight.held()
        if not (st and def) then
            return "weak"
        end
        local strong = Fight.charge() > 0.9
        local fall = st.fallDistance or 0
        local combat = Game.shared("Combat")
        if def.kind == "mace" and fall > (combat and combat.SMASH_MIN_FALL or Game.const("SMASH_MIN_FALL")) and not st.gliding then
            return "smash"
        end
        if strong and Fight.falling() and not st.sprinting then
            return "crit"
        end
        if st.sprinting and strong then
            return "knockback"
        end
        if strong and st.onGround and def.kind == "sword" then
            return "sweep"
        end
        return strong and "strong" or "weak"
    end
    -- About how much the swing does before armour: the weapon's damage scaled by charge (a fifth of it
    -- uncharged), a critical's 1.5x, and sharpness scaled by charge. The server has the last word.
    function Fight.damage()
        local def, hands = Fight.held()
        if not (def and def.damage and hands) then
            return nil
        end
        local s = Fight.charge()
        local base = def.damage * (0.2 + s * s * 0.8)
        local kind = Fight.kind()
        if kind == "crit" then
            base *= 1.5
        end
        local sharp = enchant(hands.held(), "sharpness")
        local combat = Game.shared("Combat")
        if sharp > 0 and combat then
            base += combat.sharpness(sharp) * s
        end
        return base, kind
    end
    -- What a mace smash adds, from how far you have fallen (the game's own maceBonus).
    function Fight.smash()
        local def, hands = Fight.held()
        local st = stateOf()
        local combat = Game.shared("Combat")
        if not (def and def.kind == "mace" and st and combat and hands) then
            return nil
        end
        local fall = st.fallDistance or 0
        if fall <= (combat.SMASH_MIN_FALL or Game.const("SMASH_MIN_FALL")) or st.gliding then
            return nil
        end
        local ok, bonus = pcall(combat.maceBonus, fall, enchant(hands.held(), "density"))
        return ok and bonus or nil, fall
    end
end

--// Aim assist \\--
local Aim = { target = nil, status = "Off" }
do
    local lastWhen = 0
    local function wantsAssist()
        local when = Settings.AimWhen
        if when == "Always" then
            return true
        end
        local input = Game.input()
        if when == "While attacking" then
            local ok, down = pcall(input.isDown, "attack")
            return ok and down == true
        end
        return true -- "Target in reach": decided by the target itself
    end
    -- The best entity to steer toward: inside the cone, within range, not behind blocks, nearest the
    -- crosshair. Returns it with the point to aim at and the direction from the eye.
    local function pick(eye, look)
        local best, bestAngle
        local block = Game.block()
        local rangeStuds = Settings.AimRange * block
        for _, e in Ent.all(false) do
            if not (Settings.AimPlayersOnly and e.mob) then
                local point = e.feet + Vector3.new(0, e.height * Settings.AimPoint, 0)
                local d = point - eye
                if d.Magnitude <= rangeStuds and d.Magnitude > 0.2 then
                    local angle = Look.between(look, d.Unit)
                    if angle <= Settings.AimFOV and (not bestAngle or angle < bestAngle)
                        and not (Settings.AimVisible and Ent.blocked(eye, point)) then
                        best, bestAngle = { e = e, point = point, dir = d.Unit, angle = angle, dist = d.Magnitude / block }, angle
                    end
                end
            end
        end
        return best
    end
    function Aim.step(dt)
        if not Settings.AimAssist then
            Aim.target, Aim.status = nil, "Off"
            return
        end
        local ready, missing = Game.ready()
        if not ready then
            Aim.target, Aim.status = nil, "Waiting for the game's " .. tostring(missing)
            return
        end
        if not Game.canFight() then
            Aim.target, Aim.status = nil, "Not in a fight right now"
            return
        end
        if not wantsAssist() then
            Aim.target, Aim.status = nil, "Waiting for: " .. tostring(Settings.AimWhen)
            return
        end
        local _, eye, look = Ent.me()
        local t = pick(eye, look)
        Aim.target = t
        if not t then
            Aim.status = "No one in the cone"
            return
        end
        if Settings.AimWhen == "Target in reach" and t.dist > Game.reach() + 0.5 then
            Aim.status = "Nearest is out of reach"
            return
        end
        Aim.status = ("Steering to %s (%.1f blocks, %d deg)"):format(t.e.name, t.dist, math.floor(t.angle + 0.5))
        local ctl = Game.controller()
        local ty, tp = Look.angles(t.dir)
        local k = math.max(Settings.AimSmooth, 1)
        local alpha = 1 - (1 - 1 / k) ^ (math.clamp(dt, 0, 0.1) * 60)
        local dyaw = Look.wrap(ty - ctl.yaw) * alpha
        local dpitch = (tp - ctl.pitch) * alpha
        if Settings.AimMaxTurn > 0 then
            local cap = math.rad(Settings.AimMaxTurn) * math.clamp(dt, 0, 0.1)
            dyaw, dpitch = math.clamp(dyaw, -cap, cap), math.clamp(dpitch, -cap, cap)
        end
        if Settings.AimYaw then
            ctl.yaw += dyaw
        end
        if Settings.AimPitch then
            ctl.pitch = math.clamp(ctl.pitch + dpitch, -math.pi / 2, math.pi / 2)
        end
    end
end

--// Auto attack \\--
-- Presses the game's virtual "attack" (the same call its touch button makes) for one frame when a
-- charged weapon has someone in reach, and only then. It never touches the cursor, the screen or any
-- movement key, so it behaves the same on every device; if you are already holding attack it stays out
-- of the way, and it lets go of exactly what it pressed.
local Auto = { status = "Off", pressed = false, lastPress = -10, since = nil }
do
    local function release()
        if Auto.pressed then
            Auto.pressed = false
            local input = Game.input()
            if input then
                pcall(input.setVirtual, "attack", false)
            end
        end
    end
    Auto.release = release
    function Auto.step()
        if Auto.pressed then
            release() -- one frame is all the press needs: the game queues the attack the moment it is pressed
        end
        if not Settings.AutoAttack then
            Auto.status, Auto.since = "Off", nil
            return
        end
        local ready, missing = Game.ready()
        if not ready then
            Auto.status = "Waiting for the game's " .. tostring(missing)
            return
        end
        local input = Game.input()
        if type(input.setVirtual) ~= "function" then
            Auto.status = "This game version has no virtual press"
            return
        end
        if not Game.canFight() then
            Auto.status, Auto.since = "Not in a fight right now", nil
            return
        end
        local hands = Game.hands()
        local def = Fight.held()
        local okh, stack = pcall(hands.held)
        if not Fight.kindAllowed(def, okh and stack or nil) then
            Auto.status, Auto.since = "Holding something it won't swing", nil
            return
        end
        if hands.using then
            Auto.status, Auto.since = "Using an item", nil
            return
        end
        local charge = Fight.charge()
        if charge < Settings.AutoCharge then
            Auto.status = ("Charging %d%%"):format(math.floor(charge * 100))
            return
        end
        local ctl, world = Game.controller(), Game.world()
        local ok, eye = pcall(ctl.eye)
        local ok2, look = pcall(ctl.look)
        if not (ok and ok2 and eye and look) then
            return
        end
        local reach = math.max(0.5, Game.reach() - Settings.AutoMargin)
        local okp, target = pcall(world.pick, eye, look, reach, 0)
        if not (okp and target) or (Settings.AutoPlayersOnly and target.model:GetAttribute("Mob") ~= nil) then
            Auto.status, Auto.since = "No one in reach", nil
            return
        end
        local now = os.clock()
        if Auto.targetId ~= target.id or not Auto.since then
            -- someone new under the crosshair: the wait starts over
            Auto.targetId, Auto.since = target.id, now
        end
        if now - Auto.since < Settings.AutoDelay / 1000 then
            Auto.status = "On target"
            return
        end
        if now - Auto.lastPress < 0.12 then
            return
        end
        -- Someone holding attack by hand keeps it: pressing and then letting go would cut their hold short.
        local okd, down = pcall(input.isDown, "attack")
        if okd and down then
            Auto.status = "You are pressing attack"
            return
        end
        Auto.lastPress = now
        if pcall(input.setVirtual, "attack", true) then
            Auto.pressed = true
            Auto.status = "Swung at " .. tostring(target.model.Name)
        end
    end
    Cleanups[#Cleanups + 1] = release
end

--// What you see: ESP, arrows \\--
local Esp = { pool = {}, arrows = {}, reach = {} }
do
    local OUTLINE = Color3.new(0, 0, 0)
    local function entry(model)
        local d = Esp.pool[model]
        if not d then
            d = {
                box = mk("Square", { Thickness = 1, Filled = false, Visible = false }),
                outline = mk("Square", { Thickness = 3, Filled = false, Color = OUTLINE, Visible = false }),
                name = mk("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
                info = mk("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
                tracer = mk("Line", { Thickness = 1, Visible = false }),
                look = mk("Line", { Thickness = 1, Visible = false }),
                hpBack = mk("Line", { Thickness = 4, Color = OUTLINE, Visible = false }),
                hp = mk("Line", { Thickness = 2, Visible = false }),
            }
            Esp.pool[model] = d
        end
        return d
    end
    local function hide(d)
        for _, x in d do
            x.Visible = false
        end
    end
    local function kill(d)
        for _, x in d do
            pcall(x.Remove, x)
        end
    end
    -- How a target stands with your reach: in reach and clear, near, far, or behind blocks. Looked up a
    -- few times a second.
    function Esp.reachOf(e, eye)
        local c = Esp.reach[e.model]
        local now = os.clock()
        if c and now - c.at < 0.1 then
            return c.state
        end
        local block = Game.block()
        local point = e.feet + Vector3.new(0, e.height * 0.6, 0)
        local dist = (point - eye).Magnitude / block
        local state
        if Ent.blocked(eye, point) then
            state = "blocked"
        elseif dist <= Game.reach() then
            state = "reach"
        elseif dist <= Game.reach() * 2 then
            state = "near"
        else
            state = "far"
        end
        Esp.reach[e.model] = { state = state, at = now }
        return state
    end
    local function colorFor(state)
        return state == "reach" and Settings.EspInReach or (state == "near" and Settings.EspNear)
            or (state == "blocked" and Settings.EspBlocked) or Settings.EspFar
    end
    local function box(cam, e)
        local hw = e.width / 2
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for _, dx in { -hw, hw } do
            for _, dz in { -hw, hw } do
                for _, y in { 0, e.height } do
                    local sp = cam:WorldToViewportPoint(e.feet + Vector3.new(dx, y, dz))
                    if sp.Z <= 0 then
                        return nil
                    end
                    minX, maxX = math.min(minX, sp.X), math.max(maxX, sp.X)
                    minY, maxY = math.min(minY, sp.Y), math.max(maxY, sp.Y)
                end
            end
        end
        return minX, minY, maxX, maxY
    end
    function Esp.step(cam)
        local seen = {}
        if Settings.Esp then
            local block = Game.block()
            local _, eye = Ent.me()
            local vp = cam.ViewportSize
            for _, e in Ent.all() do
                local dist = (e.feet - eye).Magnitude / block
                if dist <= Settings.EspMax and not (e.mob and not Settings.EspMobs) then
                    seen[e.model] = true
                    local d = entry(e.model)
                    local x1, y1, x2, y2 = box(cam, e)
                    if not x1 then
                        hide(d)
                    else
                        local state = Settings.EspReach and e.sameMode and Esp.reachOf(e, eye) or "far"
                        local color = colorFor(state)
                        local w, h = x2 - x1, y2 - y1
                        local mid = (x1 + x2) / 2
                        if Settings.EspBox and d.box then
                            d.outline.Position, d.outline.Size, d.outline.Visible = Vector2.new(x1, y1), Vector2.new(w, h), true
                            d.box.Position, d.box.Size, d.box.Color, d.box.Visible = Vector2.new(x1, y1), Vector2.new(w, h), color, true
                        else
                            d.box.Visible, d.outline.Visible = false, false
                        end
                        local label = e.name
                        if Settings.EspKit and e.kit and e.kit ~= "" then
                            label ..= "  [" .. tostring(e.kit) .. "]"
                        end
                        if Settings.EspName and d.name then
                            d.name.Text, d.name.Position, d.name.Color, d.name.Visible = label, Vector2.new(mid, y1 - 16), color, true
                        else
                            d.name.Visible = false
                        end
                        local bits = {}
                        if Settings.EspDist then
                            bits[#bits + 1] = ("%.1f"):format(dist)
                        end
                        if Settings.EspKills and e.kills then
                            bits[#bits + 1] = tostring(e.kills) .. " kills"
                        end
                        if Settings.EspFlags then
                            if e.sneaking then
                                bits[#bits + 1] = "sneak"
                            end
                            if e.gliding then
                                bits[#bits + 1] = "glide"
                            end
                            if e.spinning then
                                bits[#bits + 1] = "spin"
                            end
                        end
                        if #bits > 0 and d.info then
                            d.info.Text, d.info.Position, d.info.Color, d.info.Visible = table.concat(bits, "  "), Vector2.new(mid, y2 + 2), Color3.new(1, 1, 1), true
                        else
                            d.info.Visible = false
                        end
                        if Settings.EspHealth and type(e.health) == "number" and d.hp then
                            local frac = math.clamp(e.health / 20, 0, 1)
                            d.hpBack.From, d.hpBack.To, d.hpBack.Visible = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y1), true
                            d.hp.From, d.hp.To = Vector2.new(x1 - 5, y2), Vector2.new(x1 - 5, y2 - h * frac)
                            d.hp.Color, d.hp.Visible = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(80, 255, 110), frac), true
                        else
                            d.hp.Visible, d.hpBack.Visible = false, false
                        end
                        if Settings.EspTracer and d.tracer then
                            d.tracer.From, d.tracer.To, d.tracer.Color, d.tracer.Visible = Vector2.new(vp.X / 2, vp.Y), Vector2.new(mid, y2), color, true
                        else
                            d.tracer.Visible = false
                        end
                        if Settings.EspLook and d.look then
                            local head = Ent.eye(e)
                            local a, b = cam:WorldToViewportPoint(head), cam:WorldToViewportPoint(head + Ent.look(e) * 6)
                            if a.Z > 0 and b.Z > 0 then
                                d.look.From, d.look.To, d.look.Color, d.look.Visible = Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y), Color3.fromRGB(255, 220, 80), true
                            else
                                d.look.Visible = false
                            end
                        else
                            d.look.Visible = false
                        end
                    end
                end
            end
        end
        for model, d in Esp.pool do
            if not seen[model] then
                kill(d)
                Esp.pool[model] = nil
                Esp.reach[model] = nil
            end
        end
    end
    -- Arrows around an oval to bodies that are off screen, the way they lie on the ground relative to where you look.
    local function arrowFor(model)
        local a = Esp.arrows[model]
        if not a then
            a = {
                tri = mk("Triangle", { Filled = true, Visible = false, Thickness = 1 }),
                text = mk("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
            }
            Esp.arrows[model] = a
        end
        return a
    end
    function Esp.arrowStep(cam)
        local seen = {}
        if Settings.EspArrows then
            local block = Game.block()
            local _, eye = Ent.me()
            local vp = cam.ViewportSize
            local centre = vp / 2
            local rx, ry = vp.X * Settings.ArrowRadius, vp.Y * Settings.ArrowRadius
            for _, e in Ent.all() do
                local dist = (e.feet - eye).Magnitude / block
                if dist <= Settings.ArrowMax and not (e.mob and not Settings.EspMobs) then
                    local sp, on = cam:WorldToViewportPoint(e.feet + Vector3.new(0, e.height / 2, 0))
                    local inside = on and sp.X >= 0 and sp.X <= vp.X and sp.Y >= 0 and sp.Y <= vp.Y
                    if Settings.ArrowAlways or not inside then
                        seen[e.model] = true
                        local a = arrowFor(e.model)
                        local rel = cam.CFrame:PointToObjectSpace(e.feet)
                        local dir = Vector2.new(rel.X, rel.Z)
                        local m = dir.Magnitude
                        dir = m > 1e-3 and dir / m or Vector2.new(0, -1)
                        local p = centre + Vector2.new(dir.X * rx, dir.Y * ry)
                        local size = Settings.ArrowSize
                        local perp = Vector2.new(-dir.Y, dir.X)
                        local base = p - dir * size * 0.5
                        local color = colorFor(Settings.EspReach and e.sameMode and Esp.reachOf(e, eye) or "far")
                        if a.tri then
                            a.tri.PointA, a.tri.PointB, a.tri.PointC = p + dir * size, base + perp * size * 0.6, base - perp * size * 0.6
                            a.tri.Color, a.tri.Visible = color, true
                        end
                        if a.text then
                            if Settings.ArrowDistance then
                                a.text.Text, a.text.Position, a.text.Color, a.text.Visible = ("%.0f"):format(dist), p - dir * (size + 8), color, true
                            else
                                a.text.Visible = false
                            end
                        end
                    end
                end
            end
        end
        for model, a in Esp.arrows do
            if not seen[model] then
                if a.tri then
                    a.tri.Visible = false
                end
                if a.text then
                    a.text.Visible = false
                end
                if not model.Parent then
                    for _, x in a do
                        pcall(x.Remove, x)
                    end
                    Esp.arrows[model] = nil
                end
            end
        end
    end
    function Esp.clear()
        for _, d in Esp.pool do
            kill(d)
        end
        for _, a in Esp.arrows do
            for _, x in a do
                pcall(x.Remove, x)
            end
        end
        Esp.pool, Esp.arrows, Esp.reach = {}, {}, {}
    end
    Cleanups[#Cleanups + 1] = Esp.clear
end

--// What you see: reach ring, charge bar, target card \\--
local Hud = { ring = {}, text = {}, bar = {}, status = "" }
do
    local function ringLine(i)
        local l = Hud.ring[i]
        if l == nil then
            l = mk("Line", { Visible = false, Thickness = 1 }) or false
            Hud.ring[i] = l
        end
        return l
    end
    local function textAt(i)
        local t = Hud.text[i]
        if t == nil then
            t = mk("Text", { Visible = false, Size = 14, Center = true, Outline = true }) or false
            Hud.text[i] = t
        end
        return t
    end
    local function barPart(i, class, props)
        local b = Hud.bar[i]
        if b == nil then
            b = mk(class, props) or false
            Hud.bar[i] = b
        end
        return b
    end
    local GREEN, YELLOW, RED = Color3.fromRGB(80, 255, 110), Color3.fromRGB(255, 210, 60), Color3.fromRGB(255, 80, 80)
    function Hud.step(cam)
        local ready = Game.ready()
        local vp = cam.ViewportSize
        local centre = vp / 2
        local feet, eye, look
        if ready then
            feet, eye, look = Ent.me()
        end
        -- reach ring on the ground around your feet
        local segs = math.clamp(math.floor(Settings.HudReachSegments), 12, 80)
        if Settings.HudReach and feet then
            local radius = Game.reach() * Game.block()
            local inReach = false
            for _, e in Ent.all(false) do
                if (e.feet - feet).Magnitude <= radius then
                    inReach = true
                    break
                end
            end
            local color = inReach and GREEN or Color3.new(1, 1, 1)
            local prev
            for i = 0, segs do
                local a = i / segs * math.pi * 2
                local p = feet + Vector3.new(math.cos(a) * radius, 0.1, math.sin(a) * radius)
                local sp, on = cam:WorldToViewportPoint(p)
                local cur = on and sp.Z > 0 and Vector2.new(sp.X, sp.Y) or nil
                if prev and cur then
                    local l = ringLine(i)
                    if l then
                        l.From, l.To, l.Color, l.Transparency, l.Visible = prev, cur, color, 0.6, true
                    end
                elseif ringLine(i) then
                    ringLine(i).Visible = false
                end
                prev = cur
            end
            hideAll(Hud.ring, segs + 2)
        else
            hideAll(Hud.ring)
        end
        -- charge bar and critical / smash tags under the crosshair
        local ti = 0
        if ready and Settings.HudCharge then
            local s = Fight.charge()
            local w, h = 70, 5
            local x, y = centre.X - w / 2, centre.Y + 38
            local back = barPart(1, "Square", { Filled = true, Color = Color3.new(0, 0, 0), Transparency = 0.5, Visible = false })
            local fill = barPart(2, "Square", { Filled = true, Visible = false })
            if back and fill then
                back.Position, back.Size, back.Visible = Vector2.new(x - 1, y - 1), Vector2.new(w + 2, h + 2), true
                fill.Position, fill.Size = Vector2.new(x, y), Vector2.new(w * s, h)
                fill.Color = s >= 1 and GREEN or (s >= 0.6 and YELLOW or RED)
                fill.Visible = true
            end
        else
            if Hud.bar[1] then
                Hud.bar[1].Visible = false
            end
            if Hud.bar[2] then
                Hud.bar[2].Visible = false
            end
        end
        if ready and Settings.HudCrit then
            local tag, color
            local kind = Fight.kind()
            local st = Game.controller().state
            if kind == "smash" then
                local bonus = Fight.smash()
                tag, color = bonus and ("SMASH +%.0f"):format(bonus) or "SMASH", Color3.fromRGB(255, 160, 40)
            elseif kind == "crit" then
                tag, color = "CRIT", GREEN
            elseif Fight.falling() then
                if Fight.charge() <= 0.9 then
                    tag, color = "CRIT: wait for charge", YELLOW
                elseif st.sprinting then
                    tag, color = "CRIT: stop sprinting", YELLOW
                end
            end
            if tag then
                ti += 1
                local t = textAt(ti)
                if t then
                    t.Text, t.Position, t.Color, t.Visible = tag, Vector2.new(centre.X, centre.Y + 54), color, true
                end
            end
        end
        -- who your next swing would hit, how far, and roughly what it does
        if ready and Settings.HudTarget then
            local world = Game.world()
            local reach = Game.reach()
            local ok, target, dist = pcall(world.pick, Game.controller().eye(), look, reach + 3, 0)
            if ok and target then
                local dmg, kind = Fight.damage()
                local nm = target.model:GetAttribute("Nick") or target.model.Name
                local line = ("%s  %.1f blocks%s"):format(nm, dist or 0, (dist or 99) <= reach and "  IN REACH" or "")
                if dmg then
                    line ..= ("\n~%.1f damage before armour%s"):format(dmg, kind == "crit" and " (crit)" or (kind == "smash" and " (smash)" or ""))
                end
                ti += 1
                local t = textAt(ti)
                if t then
                    t.Text, t.Position = line, Vector2.new(centre.X, centre.Y - 70)
                    t.Color = (dist or 99) <= reach and GREEN or Color3.new(1, 1, 1)
                    t.Visible = true
                end
            end
        end
        hideAll(Hud.text, ti + 1)
    end
    function Hud.clear()
        for _, list in { Hud.ring, Hud.text, Hud.bar } do
            for _, d in list do
                if d then
                    pcall(d.Remove, d)
                end
            end
        end
        Hud.ring, Hud.text, Hud.bar = {}, {}, {}
    end
    Cleanups[#Cleanups + 1] = Hud.clear
end

--// Hit and kill feedback \\--
-- The game does not tell you the result of your own swing, so it is worked out the way the game works
-- it out: each time Hands.attackReset moves (an attack went out) the target World.pick finds is the one
-- you swung at; if that body stops being Alive within a moment, it was your kill.
local Hits = { marks = {}, lines = {}, texts = {}, last = nil, seenReset = nil }
do
    local function play(kill)
        local id = kill and Settings.KillSoundId or Settings.HitSoundId
        if id == "" then
            return
        end
        local snd = Instance.new("Sound")
        snd.SoundId = id:match("^%d+$") and ("rbxassetid://" .. id) or id
        snd.Volume = math.clamp(Settings.HitVolume * (kill and 1.2 or 0.8), 0, 10)
        snd.Parent = game:GetService("SoundService")
        snd:Play()
        game:GetService("Debris"):AddItem(snd, 4)
    end
    function Hits.step(cam)
        local hands, ctl, world = Game.hands(), Game.controller(), Game.world()
        local watching = Hits.watch or {}
        Hits.watch = watching
        if hands and ctl and world and type(hands.attackReset) == "number" then
            local reset = hands.attackReset
            if Hits.seenReset ~= nil and reset ~= Hits.seenReset then
                -- an attack just went out: whoever was in reach and in view is who it was aimed at
                local okE, eye = pcall(ctl.eye)
                local okL, look = pcall(ctl.look)
                if okE and okL then
                    local ok, target = pcall(world.pick, eye, look, Game.reach() + Game.const("REACH_LENIENCY", 0), 0)
                    if not ok then
                        target = nil
                    end
                    if target then
                        Hits.last = { id = target.id, model = target.model, at = os.clock() }
                        if Settings.HitMarkers then
                            table.insert(Hits.marks, { at = os.clock(), kill = false })
                            play(false)
                        end
                    end
                end
            end
            Hits.seenReset = reset
        end
        -- the body you swung at stopped being alive: your kill
        local last = Hits.last
        if last then
            local gone = not last.model.Parent or not last.model:GetAttribute("Alive")
            if gone and os.clock() - last.at < 2 then
                if Settings.KillMarkers then
                    table.insert(Hits.marks, { at = os.clock(), kill = true })
                    play(true)
                end
                Hits.last = nil
            elseif os.clock() - last.at >= 2 then
                Hits.last = nil
            end
        end
        local li, ti = 0, 0
        local centre = cam.ViewportSize / 2
        local i = 1
        while i <= #Hits.marks do
            local m = Hits.marks[i]
            local age = os.clock() - m.at
            if age > Settings.HitTime then
                table.remove(Hits.marks, i)
            else
                i += 1
                local fade = 1 - age / Settings.HitTime
                local gap, len = (m.kill and 7 or 5) + age * 8, Settings.HitSize * (m.kill and 1.6 or 1)
                local color = m.kill and Color3.fromRGB(255, 70, 70) or Color3.new(1, 1, 1)
                for _, d in { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } } do
                    li += 1
                    local l = Hits.lines[li]
                    if l == nil then
                        l = mk("Line", { Visible = false, Thickness = 2 }) or false
                        Hits.lines[li] = l
                    end
                    if l then
                        local dir = Vector2.new(d[1], d[2]).Unit
                        l.From, l.To, l.Color, l.Transparency, l.Visible = centre + dir * gap, centre + dir * (gap + len), color, fade, true
                    end
                end
                if m.kill and ti < 2 then
                    ti += 1
                    local t = Hits.texts[ti]
                    if t == nil then
                        t = mk("Text", { Visible = false, Size = 16, Center = true, Outline = true }) or false
                        Hits.texts[ti] = t
                    end
                    if t then
                        t.Text, t.Position, t.Color, t.Transparency, t.Visible = "KILL", centre + Vector2.new(0, -40 - age * 60), Color3.fromRGB(255, 70, 70), fade, true
                    end
                end
            end
        end
        hideAll(Hits.lines, li + 1)
        hideAll(Hits.texts, ti + 1)
    end
    function Hits.clear()
        for _, list in { Hits.lines, Hits.texts } do
            for _, d in list do
                if d then
                    pcall(d.Remove, d)
                end
            end
        end
        Hits.lines, Hits.texts, Hits.marks = {}, {}, {}
    end
    Cleanups[#Cleanups + 1] = Hits.clear
end

--// The world: FOV, brightness, rain \\--
local World = {}
do
    local saved = {}
    -- The game applies its own FOV option to the camera every frame, so the option is what changes.
    function World.fov()
        local settings = Game.client("Settings")
        local opts = settings and settings.options
        if type(opts) ~= "table" then
            return
        end
        if Settings.FovChanger then
            if saved.fov == nil then
                saved.fov = opts.fov
            end
            opts.fov = Settings.FovValue
        elseif saved.fov ~= nil then
            opts.fov = saved.fov
            saved.fov = nil
        end
    end
    function World.light()
        if not Settings.Fullbright and not saved.light then
            return
        end
        local cam = camera()
        local cc = cam and cam:FindFirstChild("MCBrightness")
        if Settings.Fullbright then
            saved.light = saved.light or {
                brightness = Lighting.Brightness, ambient = Lighting.Ambient, outdoor = Lighting.OutdoorAmbient,
                shadows = Lighting.GlobalShadows, cc = cc and cc.Brightness,
            }
            Lighting.Brightness, Lighting.GlobalShadows = 2, false
            Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(200, 200, 200), Color3.fromRGB(200, 200, 200)
            if cc then
                cc.Brightness = math.max(cc.Brightness, 0.25)
            end
        elseif saved.light then
            local s = saved.light
            Lighting.Brightness, Lighting.Ambient, Lighting.OutdoorAmbient, Lighting.GlobalShadows = s.brightness, s.ambient, s.outdoor, s.shadows
            if cc and s.cc then
                cc.Brightness = s.cc
            end
            saved.light = nil
        end
    end
    function World.rain()
        local cam = camera()
        local rain = cam and cam:FindFirstChild("MCRain")
        if not rain then
            return
        end
        for _, d in rain:GetDescendants() do
            if d:IsA("ParticleEmitter") then
                if Settings.NoRain then
                    if saved.rain == nil then
                        saved.rain = {}
                    end
                    if saved.rain[d] == nil then
                        saved.rain[d] = d.Enabled
                    end
                    d.Enabled = false
                elseif saved.rain and saved.rain[d] ~= nil then
                    d.Enabled = saved.rain[d]
                end
            end
        end
        if not Settings.NoRain then
            saved.rain = nil
        end
    end
    local at = 0
    function World.step()
        -- the game's weather and dimension scripts also touch the lighting, so fullbright is held every frame
        pcall(World.light)
        local now = os.clock()
        if now - at < 0.5 then
            return
        end
        at = now
        pcall(World.fov)
        pcall(World.rain)
    end
    Cleanups[#Cleanups + 1] = function()
        Settings.FovChanger, Settings.Fullbright, Settings.NoRain = false, false, false
        pcall(World.fov)
        pcall(World.light)
        pcall(World.rain)
    end
end

--// Route planner \\--
-- Suggests a route (it never moves you): from where you stand to a goal, weighing how long it takes
-- against how likely the other players are to see or hear you on the way. It is a custom planner on
-- purpose: this game's movement (a step of 0.6 blocks, a jump that clears one block, drops, crouching
-- under things, hopping a one-block wall) is not something Roblox's PathfindingService knows.
--
--  World    The map is sampled with raycasts and swept boxes against the game's own Solid folder (the
--           one its block ray sees) into a grid of standable spots, any number of floors. A spot's
--           links to its eight neighbours are worked out once and cached; a block that is placed or
--           broken makes the planner forget just the spots near it. Links: walking (a step up or
--           down), jumping up a ledge, hopping over a one-block wall, dropping, and sneaking under a
--           low ceiling.
--  Players  Every other player's position and which way they look (their body's facing and the
--           pitch the game sends). A spot is exposed to a player that has a clear line to your chest
--           at your posture, is in range and has you in their field of view; one behind them counts
--           for little. Footsteps are heard through walls at a range that grows with your speed, so
--           sneaking is quieter than sprinting.
--  Search   A* over that grid, time-sliced over frames so the game doesn't hitch. Cost is seconds of
--           travel plus seconds spent exposed times a weight plus noise times a weight. A goal that
--           is a player ends at a spot inside your reach with a clear line to them, scored for how
--           badly the others see it, whether the target is looking at it (a flank scores best) and
--           height over them.
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
    -- The game's own block ray (World.blockRay) is a raycast that only sees the Solid folder of
    -- Workspace.MCWorld, so the planner looks at exactly what the game's movement and attacks look at.
    local P
    local solidFolder
    local function solid()
        if solidFolder and solidFolder.Parent then
            return solidFolder
        end
        local w = Workspace:FindFirstChild("MCWorld")
        solidFolder = w and w:FindFirstChild("Solid")
        return solidFolder
    end
    local function newParams()
        local p = RaycastParams.new()
        p.FilterType = Enum.RaycastFilterType.Include
        local s = solid()
        p.FilterDescendantsInstances = s and { s } or {}
        return p
    end
    local function ray(o, d, params)
        return Workspace:Raycast(o, d, params or P)
    end
    -- Is the straight line between two points free of blocks?
    local function lineClear(a, b)
        return Workspace:Raycast(a, b - a, P) == nil
    end
    local function stanceH(s)
        return s == 0 and S.NavStandH or (s == 1 and S.NavCrouchH or S.NavProneH)
    end

    --// The grid \\--
    local cache = { nodes = {}, cols = {}, count = 0, cs = nil, map = nil }
    local function resetCache()
        cache.nodes, cache.cols, cache.count = {}, {}, 0
    end
    local function colKey(ix, iz)
        return (ix + 4096) * 8192 + (iz + 4096)
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
        local ck = colKey(ix, iz)
        local col = cache.cols[ck]
        if not col then
            col = {}
            cache.cols[ck] = col
        end
        col[#col + 1] = n
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

    -- A block was placed or broken near `pos` (radius: half its size): forget the spots around it and
    -- the links of the spots next to them, so the next plan sees the new shape of the map.
    function Nav.dirty(pos, radius)
        local cs = cache.cs
        if not cs then
            return
        end
        local drop, edge = radius + cs * 1.5, radius + cs * 3.5
        local span = floor(edge / cs) + 1
        local cx, cz = floor(pos.X / cs + 0.5), floor(pos.Z / cs + 0.5)
        for ix = cx - span, cx + span do
            for iz = cz - span, cz + span do
                local k = colKey(ix, iz)
                local col = cache.cols[k]
                if col then
                    local dx, dz = abs(ix * cs - pos.X), abs(iz * cs - pos.Z)
                    if dx <= drop and dz <= drop then
                        for _, n in col do
                            if cache.nodes[n.key] == n then
                                cache.nodes[n.key] = nil
                                cache.count -= 1
                            end
                        end
                        cache.cols[k] = nil
                    elseif dx <= edge and dz <= edge then
                        for _, n in col do
                            n.edges = nil
                        end
                    end
                end
            end
        end
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
                        for s = max(node.req, to.req), maxS do
                            if sweep(node.x, max(node.y, ty), node.z, hx, hz, s) then
                                e = { to = to, kind = "walk", stance = s, len = len, extra = 0, loud = 1 }
                                break
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
    -- Studs a second: this game's walking is about 4.3 blocks a second, sprinting 5.6, sneaking 1.3,
    -- and a block is 3 studs. NavBaseSpeed is the walking speed.
    local function topSpeed()
        return S.NavBaseSpeed * 1.3
    end
    local function speedFor(s)
        local base = S.NavBaseSpeed
        if s == 2 then
            return base * 0.2
        elseif s == 1 then
            return base * 0.3
        end
        local ms = S.NavMoveStyle
        if ms == "Run" then
            return base * 1.3
        elseif ms == "Walk" then
            return base
        end
        return base * 0.3
    end
    local function hearRadius(speed, loud)
        return S.NavHear * speed / topSpeed() * loud
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
                    if lineClear(e.head, chest) then
                        f, seen = 1, true
                    end
                    risk += f * facing * (1 - 0.65 * d / S.NavSight)
                end
                table.insert(near, { dist = d, seen = seen })
            end
        end
        plan.expo[k] = { risk, near }
        return risk, near
    end
    local function edgeCost(plan, e)
        local to = e.to
        local speed = speedFor(e.stance)
        local time = e.len / speed + e.extra
        local sm, nm = styleMult()
        local risk, near = exposure(plan, to, e.stance)
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
        local maxSpeed = topSpeed()
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
        local maxSpeed = topSpeed()
        local ideal = (S.NavEngageMin + S.NavEngageMax) / 2
        return {
            label = label, pos = tgt.pos, enemy = true,
            test = function(node)
                local d = hdist(node, tgt.pos)
                if d < S.NavEngageMin or d > S.NavEngageMax or abs(node.y - tgt.pos.Y) > 12 or node.req > 0 then
                    return false
                end
                return lineClear(chestAt(node, 0), tgt.head)
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
        local length, time, vaults, jumps, drops = 0, 0, 0, 0, 0
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
            points = pts, length = length, time = time, vaults = vaults, jumps = jumps, drops = drops,
            risk = time > 0 and riskSum / time or 0, riskMax = riskMax, exposed = exposed, cost = plan.total, nodes = plan.exp,
        }
    end

    --// Reading the game \\--
    -- Your feet, in studs, from the game's own controller (or a guess from the camera).
    local function myRoot()
        local feet = Ent.me()
        return feet and { Position = feet }
    end
    local function lookOf(e)
        local v = Ent.look(e)
        local m = sqrt(v.X * v.X + v.Z * v.Z)
        if m > 0.05 then
            return Vector3.new(v.X / m, 0, v.Z / m)
        end
        return nil
    end
    local function snapshot()
        local enemies = {}
        for _, e in Ent.all(false) do
            if not (e.mob and not S.NavMobs) then
                table.insert(enemies, { head = Ent.eye(e), pos = e.feet, look = lookOf(e), t = e, name = e.name, kills = e.kills or 0 })
            end
        end
        return enemies, {}
    end
    local function findByName(list, text)
        text = (text or ""):lower()
        if text == "" then
            return nil
        end
        for _, e in list do
            if (e.name .. " " .. e.t.model.Name):lower():find(text, 1, true) then
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
    local function crosshairHit()
        local cam = camera()
        return Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 400, P or newParams())
    end
    -- The goal to plan for, or nil and why.
    local function resolveGoal(enemies, from)
        local g = S.NavGoal
        if g == "Enemy (nearest)" or g == "Enemy (by name)" then
            local e = g == "Enemy (nearest)" and nearest(enemies, from) or findByName(enemies, S.NavTarget)
            if not e then
                return nil, g == "Enemy (nearest)" and "no one else is in this mode" or "no player matches that name"
            end
            return enemyGoal(e, e.name)
        elseif g == "Enemy (most kills)" then
            local best
            for _, e in enemies do
                if not best or e.kills > best.kills then
                    best = e
                end
            end
            if not best then
                return nil, "no one else is in this mode"
            end
            return enemyGoal(best, best.name .. " (" .. best.kills .. " kills)")
        elseif g == "Enemy cluster" then
            if #enemies == 0 then
                return nil, "no one else is in this mode"
            end
            local sum = Vector3.new(0, 0, 0)
            for _, e in enemies do
                sum += e.pos
            end
            local c = sum / #enemies
            local tgt = nearest(enemies, c)
            return enemyGoal({ pos = c, head = c + Vector3.new(0, 4.8, 0), look = tgt.look }, "the group")
        elseif g == "Crosshair point" then
            local hit = crosshairHit()
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
        P = newParams()
        local hit = crosshairHit()
        Nav.marked = hit and hit.Position or nil
        return Nav.marked ~= nil
    end

    --// Planning, replanning \\--
    local current, lastPlan, altPlan = nil, -10, nil
    -- What the cached links depend on: change any of it and they are worked out again.
    local MOVE_KEYS = {
        "NavVault", "NavJump", "NavDrop", "NavCrouch", "NavProne", "NavVaultMax", "NavVaultMin",
        "NavVaultDepth", "NavStep", "NavJumpMax", "NavDropMax", "NavBodyW", "NavStandH", "NavCrouchH", "NavProneH",
        "NavCell", "NavVaultTime", "NavJumpTime",
    }
    local function moveSignature()
        local t = {}
        for i, k in MOVE_KEYS do
            t[i] = tostring(S[k])
        end
        return table.concat(t, ",")
    end
    local function describe(path)
        local bits = { ("%d blocks"):format(floor(path.length / Game.block() + 0.5)), ("%ds"):format(floor(path.time + 0.5)) }
        if path.vaults > 0 then
            table.insert(bits, path.vaults .. " vault")
        end
        if path.jumps > 0 then
            table.insert(bits, path.jumps .. " jump")
        end
        if path.drops > 0 then
            table.insert(bits, path.drops .. " drop")
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
        local goal, why = resolveGoal(enemies, from)
        if not goal then
            if not quiet then
                Nav.status, Nav.path, Nav.alt = "No route: " .. tostring(why), nil, nil
            end
            return false
        end
        local startNode = nearestNode(from) or nearestNode(from + Vector3.new(0, 1.5, 0))
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
    -- Blocks placed or broken in the Solid folder: remember where, and forget the spots around them
    -- the next time the planner runs (a whole map loading at once just empties the cache).
    local watching, pending, pendingN = nil, {}, 0
    -- The part itself is remembered and read when the planner next runs: its size and position may not be
    -- set yet at the moment it is added.
    local function onPart(part)
        if part:IsA("BasePart") then
            pendingN += 1
            if pendingN <= 150 then
                pending[pendingN] = part
            end
        end
    end
    local function watchBlocks()
        local folder = solid()
        if folder == watching then
            return
        end
        watching = folder
        if folder then
            bind(folder.DescendantAdded, onPart)
            bind(folder.DescendantRemoving, onPart)
        end
    end
    local function drainBlocks()
        local n = pendingN
        if n == 0 then
            return
        end
        pendingN = 0
        if n > 150 or not S.Nav then
            pending = {}
            resetCache()
            return
        end
        for i = 1, n do
            local part = pending[i]
            pending[i] = nil
            local ok, pos, r = pcall(function()
                return part.Position, max(part.Size.X, part.Size.Z) / 2 + 0.2
            end)
            if ok and pos then
                Nav.dirty(pos, r)
            end
        end
    end

    function Nav.update()
        watchBlocks()
        drainBlocks()
        if not S.Nav then
            if Nav.path or current then
                Nav.path, Nav.alt, current, altPlan = nil, nil, nil, nil
            end
            Nav.status = "Off"
            return
        end
        local now = os.clock()
        local map = Workspace:GetAttribute("Arena")
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
    local LABEL = { vault = "HOP", mantle = "JUMP UP", jump = "JUMP", drop = "DROP" }
    local STANCE = { [1] = "SNEAK", [2] = "CRAWL" }
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
        enemyGoal = enemyGoal, startPlan = startPlan, snapshot = snapshot, lineClear = lineClear, colKey = colKey }
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
local Reported = {}
local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not Reported[name] then
        Reported[name] = true
        warn(("[UnstableSMP] %s: %s"):format(name, tostring(err)))
    end
end
bind(RunService.RenderStepped, function(dt)
    if not alive() then
        return
    end
    local cam = camera()
    if not cam then
        return
    end
    guard("aim assist", Aim.step, dt)
    guard("esp", Esp.step, cam)
    guard("arrows", Esp.arrowStep, cam)
    guard("hud", Hud.step, cam)
    guard("hits", Hits.step, cam)
    guard("world", World.step)
    guard("route planner", Nav.update)
    guard("route drawing", Nav.draw)
end)
-- The auto attack runs on the physics-side beat so it never sits in the middle of the view update.
bind(RunService.Heartbeat, function()
    if alive() then
        guard("auto attack", Auto.step)
    end
end)

--// Inspect: what the game exposes, for finding out what else is there \\--
local function inspect()
    local out = {}
    local function attrs(label, inst)
        out[#out + 1] = "== " .. label
        for k, v in inst:GetAttributes() do
            out[#out + 1] = ("  %s = %s"):format(k, tostring(v))
        end
    end
    attrs("Player", LocalPlayer)
    if LocalPlayer.Character then
        attrs("My body", LocalPlayer.Character)
    end
    local ctl = Game.controller()
    out[#out + 1] = "== Modules: " .. table.concat((function()
        local names = {}
        for _, n in { "World", "Controller", "Hands", "Input", "Settings" } do
            names[#names + 1] = n .. "=" .. (Game.client(n) and "yes" or "NO")
        end
        return names
    end)(), " ")
    if ctl and ctl.state then
        out[#out + 1] = "== Controller.state"
        for k, v in ctl.state do
            out[#out + 1] = ("  %s: %s"):format(tostring(k), typeof(v))
        end
    end
    local feet = Ent.me()
    local nearest, bd
    for _, e in Ent.all(true) do
        local d = (e.feet - feet).Magnitude
        if not bd or d < bd then
            nearest, bd = e, d
        end
    end
    if nearest then
        attrs("Nearest body: " .. nearest.name, nearest.model)
        if nearest.player then
            attrs("Its Player", nearest.player)
        end
        local kids = {}
        for _, c in nearest.model:GetChildren() do
            kids[#kids + 1] = c.Name .. ":" .. c.ClassName
        end
        out[#out + 1] = "  children: " .. table.concat(kids, ", ")
    else
        out[#out + 1] = "== no other bodies found"
    end
    return table.concat(out, "\n")
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "UNSTABLE SMP",
    Footer = "dookie hub · Ui3",
    Icon = "swords",
    Size = IsTouch and UDim2.fromOffset(520, 340) or UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/UnstableSMP",
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
    local Tab = Window:AddTab("Combat", "swords", "Aim assist, auto attack, info")
    local A = Tab:AddLeftGroupbox("Aim assist", "crosshair")
    toggle(A, "AimAssist", "Aim assist", "Turns your view toward the nearest player inside the cone. It only writes your yaw and pitch, the same numbers your own look input changes")
    dropdown(A, "AimWhen", "Steer when", { "While attacking", "Target in reach", "Always" }, "While attacking: while your attack input is held (the button on touch, left click on a mouse)")
    slider(A, "AimFOV", "Cone", 5, 120, 0, " deg", "Only players this close to where you already look")
    slider(A, "AimRange", "Range", 1.5, 12, 1, " blocks")
    slider(A, "AimPoint", "Aim height", 0.1, 1, 2, "", "Where on the body: 0 feet, 1 top of the head")
    slider(A, "AimSmooth", "Smoothness", 1, 30, 0, "", "1 snaps, higher is slower and smoother")
    slider(A, "AimMaxTurn", "Fastest turn", 0, 720, 0, " deg/s", "0 is no limit")
    toggle(A, "AimYaw", "Turn left and right", "Off keeps your forward direction where it is, so it never bends your movement")
    toggle(A, "AimPitch", "Tilt up and down")
    toggle(A, "AimVisible", "Skip players behind blocks")
    toggle(A, "AimPlayersOnly", "Players only (not mobs)")
    status(A, function()
        return Aim.status
    end)

    local T = Tab:AddRightGroupbox("Auto attack", "zap")
    toggle(T, "AutoAttack", "Auto attack", "Swings when your weapon is charged and someone is in reach, by pressing the game's own virtual attack input for a single frame. Works on every device, never touches the cursor, screen or movement, and stays out of the way while you hold attack yourself")
    slider(T, "AutoCharge", "Swing at charge", 0.2, 1, 2, "", "1 waits for a full charge, which is also what a critical needs")
    slider(T, "AutoMargin", "Reach margin", 0, 1, 2, " blocks", "Stays this far inside your reach, so a swing is never at the very edge")
    slider(T, "AutoDelay", "Wait before swinging", 0, 500, 0, " ms", "After someone comes into reach")
    toggle(T, "AutoSword", "Swords")
    toggle(T, "AutoAxe", "Axes")
    toggle(T, "AutoMace", "Maces")
    toggle(T, "AutoPlayersOnly", "Players only (not mobs)")
    status(T, function()
        return Auto.status
    end)

    local H = Tab:AddLeftGroupbox("On screen", "gauge")
    toggle(H, "HudCharge", "Charge bar", "How charged your weapon is, under the crosshair")
    toggle(H, "HudCrit", "Crit and smash", "Says when a critical is ready, and what a mace smash would add from how far you have fallen")
    toggle(H, "HudTarget", "Target card", "Who your next swing would hit, how far, and about what it does before armour")
    toggle(H, "HudReach", "Reach ring", "A circle on the ground at your reach, green when someone is inside it")
    slider(H, "HudReachSegments", "Ring detail", 12, 80, 0, "", "Fewer segments is lighter on a phone")

    local K = Tab:AddRightGroupbox("Hit feedback", "target")
    toggle(K, "HitMarkers", "Hit markers", "An X around the crosshair when a swing has someone in reach")
    toggle(K, "KillMarkers", "Kill markers", "Red and bigger, when the body you swung at stops being alive")
    slider(K, "HitSize", "Marker size", 4, 24, 0, " px")
    slider(K, "HitTime", "Marker time", 0.1, 1, 2, " s")
    slider(K, "HitVolume", "Volume", 0.1, 3, 1, "")
    input(K, "HitSoundId", "Hit sound id", "asset id (blank: silent)", "A Roblox asset id")
    input(K, "KillSoundId", "Kill sound id", "asset id (blank: silent)", "A Roblox asset id")
end

do
    local Tab = Window:AddTab("ESP", "eye", "Players, arrows")
    local E = Tab:AddLeftGroupbox("Players", "eye")
    toggle(E, "Esp", "ESP")
    toggle(E, "EspBox", "Boxes")
    toggle(E, "EspName", "Names")
    toggle(E, "EspKit", "Kit", "The kit shown on their player entry")
    toggle(E, "EspKills", "Kills")
    toggle(E, "EspDist", "Distance (blocks)")
    toggle(E, "EspFlags", "Sneaking, gliding, spinning")
    toggle(E, "EspHealth", "Health bar", "Only if the game gives bodies a Health value: use Inspect on the Misc tab to see")
    toggle(E, "EspTracer", "Tracers")
    toggle(E, "EspLook", "Look direction", "A line along where each player faces, with the pitch the game sends")
    toggle(E, "EspMobs", "Mobs and dummies too")
    toggle(E, "EspOtherModes", "Other modes too", "Players in the menu or practice, who you can't fight")
    slider(E, "EspMax", "Max distance", 10, 300, 0, " blocks")

    local R = Tab:AddRightGroupbox("Reach colours", "ruler")
    toggle(R, "EspReach", "Colour by reach", "Green inside your reach with nothing in between, yellow within twice that, red behind blocks")
    color(R, "EspInReach", "In reach")
    color(R, "EspNear", "Close")
    color(R, "EspFar", "Far")
    color(R, "EspBlocked", "Behind blocks")

    local Ar = Tab:AddLeftGroupbox("Off-screen arrows", "navigation")
    toggle(Ar, "EspArrows", "Arrows", "Points at players who are off screen, around an oval")
    toggle(Ar, "ArrowAlways", "Even when on screen")
    toggle(Ar, "ArrowDistance", "Show distance")
    slider(Ar, "ArrowRadius", "Oval size", 0.2, 0.48, 2, "")
    slider(Ar, "ArrowSize", "Arrow size", 8, 40, 0, " px")
    slider(Ar, "ArrowMax", "Max distance", 10, 300, 0, " blocks")
end

do
    local Tab = Window:AddTab("Help", "compass", "Route planner")
    local N = Tab:AddLeftGroupbox("Route planner", "route")
    toggle(N, "Nav", "Show best route", "Draws a suggested way to your goal, weighing speed against being seen and heard, using every player's position and facing. It only draws: it never moves you")
    dropdown(N, "NavGoal", "Goal", { "Enemy (nearest)", "Enemy (most kills)", "Enemy cluster", "Enemy (by name)", "Crosshair point", "Marked point" },
        "Player goals end inside your reach with a clear line to them, at the spot that scores best for not being seen, flanking and height")
    input(N, "NavTarget", "Name", "player name", "Used by Enemy (by name): part of a player's name")
    N:AddButton({ Text = "Mark crosshair point", Func = function()
        notify(Nav.mark() and "Marked. Set the goal to Marked point" or "Nothing under the crosshair", 3)
    end, Tooltip = "Remembers where you are looking, for the Marked point goal" })
    dropdown(N, "NavStyle", "Style", { "Fastest", "Balanced", "Stealth" }, "How much being seen or heard counts against time: barely, normally, a lot")
    dropdown(N, "NavMoveStyle", "How you move", { "Run", "Walk", "Sneak" }, "Sets your speed and how far your footsteps carry. Sneaking under something low is slower and quieter still")
    toggle(N, "NavAlt", "Also show another route", "A second route that keeps away from the first (blue)")
    toggle(N, "NavMobs", "Count mobs and dummies as enemies")
    status(N, function()
        return Nav.status
    end)
    N:AddButton({ Text = "Plan again now", Func = function()
        Nav.force = true
    end })
    N:AddButton({ Text = "Forget the map cache", Func = function()
        Nav.rebuild()
    end, Tooltip = "Placed and broken blocks are noticed on their own; this makes the planner look at the whole map again" })

    local M = Tab:AddRightGroupbox("Movement", "footprints")
    toggle(M, "NavVault", "Hop over walls", "Go over a one-block wall that is thin enough, by jumping")
    toggle(M, "NavJump", "Jump up ledges", "A ledge up to one block high")
    toggle(M, "NavDrop", "Drop down")
    toggle(M, "NavCrouch", "Sneak under low ceilings", "Needs 1.5 blocks of room")
    toggle(M, "NavProne", "Crawl under things", "Needs 0.6 blocks of room")
    slider(M, "NavBaseSpeed", "Walking speed", 6, 20, 1, " studs/s", "4.3 blocks a second is 12.9. Sprinting is 1.3x, sneaking 0.3x, crawling 0.2x")
    slider(M, "NavVaultMax", "Hop up to", 2, 6, 1, " studs", "Walls up to this high (a block is 3 studs)")
    slider(M, "NavVaultMin", "Hop from", 0.6, 3, 1, " studs", "Lower than this is just a step")
    slider(M, "NavVaultDepth", "Hop depth", 1, 6, 1, " studs", "How thick a wall can be")
    slider(M, "NavStep", "Step height", 0.5, 2.5, 1, " studs", "0.6 blocks: slabs and stairs are walked over")
    slider(M, "NavJumpMax", "Jump up to", 1.5, 6, 1, " studs")
    slider(M, "NavDropMax", "Drop down up to", 3, 25, 0, " studs", "Falling more than 3 blocks (9 studs) hurts")
    slider(M, "NavBodyW", "Body width", 1, 3, 1, " studs", "0.6 blocks is 1.8")
    slider(M, "NavStandH", "Standing height", 3.5, 7, 1, " studs", "1.8 blocks is 5.4")
    slider(M, "NavCrouchH", "Sneaking height", 2, 5, 1, " studs", "1.5 blocks is 4.5")
    slider(M, "NavProneH", "Crawling height", 0.8, 3, 1, " studs")
    slider(M, "NavVaultTime", "Hop time", 0.2, 2.5, 1, " s")
    slider(M, "NavJumpTime", "Jump time", 0.1, 2, 1, " s")

    local Pc = Tab:AddLeftGroupbox("What others notice", "eye")
    toggle(Pc, "NavUseLook", "Use which way they face", "Off: every player is assumed to be looking at you")
    slider(Pc, "NavSight", "Sight range", 30, 300, 0, " studs")
    slider(Pc, "NavFov", "Field of view", 40, 180, 0, " deg")
    slider(Pc, "NavBehind", "Noticed from behind", 0, 1, 2, "", "How much a player notices you directly behind them: 0 never, 1 as if facing you")
    slider(Pc, "NavHear", "Hearing range (sprinting)", 10, 120, 0, " studs", "How far a sprinting player's footsteps carry (16 blocks is 48); walking and sneaking scale down from it")
    slider(Pc, "NavMuffle", "Blocks muffle sound", 0, 1, 2, "", "How much of the noise gets through when there is no line to the player")

    local Wg = Tab:AddRightGroupbox("What matters", "sliders-horizontal")
    slider(Wg, "NavTimeW", "Time", 0, 3, 1, "x", "Weight of seconds spent travelling")
    slider(Wg, "NavSightW", "Being seen", 0, 20, 1, "x", "Seconds of detour you will take to avoid one second in a player's view")
    slider(Wg, "NavNoiseW", "Being heard", 0, 20, 1, "x")
    slider(Wg, "NavDwell", "Time spent at the goal", 0, 15, 1, " s", "How long you will stand there, which makes exposed spots at the goal cost more")
    slider(Wg, "NavHighGround", "High ground", 0, 3, 1, "x", "Bonus for a spot above the target")
    slider(Wg, "NavFirstStrike", "Being in their sights", 0, 3, 1, "x", "Penalty for a spot the target is looking at (they hit first): flanks score best")
    slider(Wg, "NavEngageMin", "Closest fighting spot", 2, 20, 1, " studs", "Your reach is 9 studs")
    slider(Wg, "NavEngageMax", "Furthest fighting spot", 4, 30, 1, " studs", "Staying just inside your reach lets you hit first")
    slider(Wg, "NavArrive", "Arrive within", 1.5, 10, 1, " studs", "For goals that are a place")

    local Sr = Tab:AddLeftGroupbox("Search", "cpu")
    slider(Sr, "NavCell", "Grid cell", 2, 5, 1, " studs", "3 is one block; smaller finds tighter gaps but searches more")
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
    toggle(D, "NavLabels", "Labels", "HOP, JUMP, SNEAK and so on where they happen")
    toggle(D, "NavHud", "Summary text")
    slider(D, "NavThickness", "Line thickness", 1, 5, 0, " px")
    slider(D, "NavHeight", "Draw height", 0, 4, 1, " studs")
end

do
    local Tab = Window:AddTab("Misc", "settings", "World and script")
    local W = Tab:AddLeftGroupbox("World", "sun")
    toggle(W, "FovChanger", "FOV changer", "Changes the game's own FOV option in memory (it is not saved)")
    slider(W, "FovValue", "FOV", 50, 130, 0, "")
    toggle(W, "Fullbright", "Fullbright")
    toggle(W, "NoRain", "No rain")
    local M = Tab:AddRightGroupbox("Script", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
    status(M, function()
        local ready, missing = Game.ready()
        return ready and "Game modules: found" or ("Game modules: missing " .. tostring(missing))
    end)
    M:AddButton({ Text = "Copy inspect report", Func = function()
        local ok, text = pcall(inspect)
        if not ok then
            notify("Inspect failed: " .. tostring(text), 4)
            return
        end
        if typeof(setclipboard) == "function" then
            pcall(setclipboard, text)
            notify("Copied the inspect report", 3)
        else
            print(text)
            notify("No clipboard here: the report is in the console", 4)
        end
    end, Tooltip = "Lists the attributes the game puts on you and the nearest body, and which game modules were found: use it to see what else can be shown" })
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__UnstableSmpUnload then
            Genv.__UnstableSmpUnload()
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
Genv.__UnstableSmpUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded. Combat has aim assist and auto attack; ESP shows who is where", 5)

--// [DUELS] Murderers VS Sheriffs ----------------------------------------------------------------
-- place 135856908115931 (game 7219654364). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Guns    every gun runs the same LocalScript. On Tool.Activated it raycasts
--           from your HumanoidRootPart toward the mouse with
--           workspace:Raycast and, if that hits an enemy, reports the kill
--           itself: Net "GunKill":FireServer(key, victim, direction, origin,
--           hitPos). The 2.5s between shots is a task.wait in that script.
--   Knives  every knife runs the same LocalScript. A throw picks its target
--           with workspace:FindPartOnRayWithIgnoreList, tells the server
--           (Net "ThrowEvent"), and the flying knife is simulated on your side
--           by ThrowingKinfeHandlerScript, which steps it with
--           FindPartOnRayWithIgnoreList every Heartbeat (about 78 studs/s, no
--           drop) and reports the kill: Net "KnifeKill":FireServer(key,
--           victim, hitPos). Slashes (Net "SlashEvent") are decided by the
--           server. The wait between throws / slashes is a flag in the script.
--   Teams   ReplicatedStorage.Client.Modules.MatchState: sameGame, sameTeam,
--           isDead, getGame.
--
-- This script redirects those same raycasts (hookmetamethod __namecall, only
-- for calls coming from the game's weapon scripts), so every kill still goes
-- through the game's own code and remotes.
--
-- Watch out: the game has a recorder (ReplicatedStorage.UserGenerated.
-- Observability) the server can switch on to record your input, camera,
-- movement and animations for review. Silent aim keeps your camera still, the
-- camlock doesn't. The server's own kill checks can't be read from a dump.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__MvsUnload then
    pcall(Genv.__MvsUnload)
end
Genv.__MvsRun = (Genv.__MvsRun or 0) + 1
local RUN = Genv.__MvsRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__MvsRun == RUN
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
    -- gun
    GunSilent = false, GunTrigger = false, GunTriggerDelay = 60, FastGun = false, GunCooldown = 0.6, Wallbang = false,
    GunLead = 0,
    -- knife
    KnifeSilent = false, KnifeHitbox = 0, FastKnife = false, KnifeCooldown = 0.25,
    AutoThrow = false, AutoThrowRange = 120, AutoSlash = false, SlashRange = 7, KnifeDodge = false, DodgeDistance = 6,
    -- targeting
    Pick = IsTouch and "Closest to you" or "Closest to aim", FOV = 260, ShowFOV = true, MaxDistance = 600,
    AimPart = "Torso", VisibleOnly = true, Prediction = true, Sticky = true,
    CamLock = false, CamSmooth = 5,
    -- esp
    Esp = false, EspNames = true, EspBoxes = true, EspDistance = true, EspWeapon = true, EspTeam = false, EspTracers = false,
    KnifeTracers = false,
    EnemyColor = Color3.fromRGB(255, 70, 70), TeamColor = Color3.fromRGB(90, 170, 255), FOVColor = Color3.fromRGB(255, 255, 255),
    -- movement
    Speed = false, SpeedAmount = 10, JumpBoost = false, JumpPower = 70, InfJump = false, Noclip = false, Fly = false, FlySpeed = 50,
    -- misc
    AutoRematch = false, AutoCollect = false, AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "MvS Duels", Description = text, Time = seconds or 3 })
end
local function loop(rate, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[MvS] " .. tostring(err))
            end
            task.wait(rate)
        end
    end)
end
local function myChar()
    return LocalPlayer.Character
end
local function myRoot()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function camera()
    return Workspace.CurrentCamera
end

--// Drawing helpers \\--
local Draw = {}
do
    Draw.ok = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
    local all = {}
    function Draw.new(kind, props)
        if not Draw.ok then
            return nil
        end
        local ok, d = pcall(Drawing.new, kind)
        if not ok then
            return nil
        end
        for k, v in props or {} do
            pcall(function()
                d[k] = v
            end)
        end
        table.insert(all, d)
        return d
    end
    function Draw.remove(d)
        if d then
            pcall(d.Remove, d)
            local i = table.find(all, d)
            if i then
                table.remove(all, i)
            end
        end
    end
    table.insert(Cleanups, function()
        for _, d in all do
            pcall(d.Remove, d)
        end
        table.clear(all)
    end)
end

--// The game \\--
local Game = {}
do
    local ok, ms = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Client", 10):WaitForChild("Modules", 10):WaitForChild("MatchState", 10))
    end)
    Game.Match = ok and type(ms) == "table" and ms or nil
    local okR, remotes = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("Remotes", 10))
    end)
    Game.Remotes = okR and type(remotes) == "table" and remotes or nil
    local okC, codes = pcall(function()
        return require(ReplicatedStorage.Shared:WaitForChild("Codes", 5))
    end)
    Game.Codes = okC and type(codes) == "table" and codes or {}

    local function call(name, ...)
        local M = Game.Match
        local f = M and M[name]
        if type(f) ~= "function" then
            return nil
        end
        local ok2, r = pcall(f, ...)
        if ok2 then
            return r
        end
        return nil
    end
    -- Someone you can (and should) kill: same duel, other team, alive.
    function Game.enemy(p)
        if p == LocalPlayer then
            return false
        end
        if not Game.Match then
            return true
        end
        return call("sameGame", p, LocalPlayer) == true and call("sameTeam", p, LocalPlayer) ~= true and call("isDead", p) ~= true
    end
    function Game.teammate(p)
        if p == LocalPlayer or not Game.Match then
            return false
        end
        return call("sameGame", p, LocalPlayer) == true and call("sameTeam", p, LocalPlayer) == true
    end
    function Game.inMatch(p)
        if not Game.Match then
            return true
        end
        return call("sameGame", p, LocalPlayer) == true
    end
    -- The game's own "a round is running" check from its weapon scripts.
    function Game.roundLive()
        local g = call("getGame", LocalPlayer)
        if type(g) ~= "table" then
            return Game.Match == nil
        end
        return g.RoundStarted == false and g.CurrentRoundEnded == false
    end
    function Game.tool()
        local c = myChar()
        return c and c:FindFirstChildOfClass("Tool")
    end
    function Game.isGun(t)
        return t ~= nil and t:IsA("Tool") and (t:FindFirstChild("showBeam") ~= nil or CollectionService:HasTag(t, "Gun"))
    end
    function Game.isKnife(t)
        return t ~= nil and t:IsA("Tool") and t:FindFirstChild("ActivateThrowing") ~= nil
    end
end

--// Targets \\--
local Targets = {}
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    function Targets.list(includeTeam)
        local out = {}
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and (Game.enemy(p) or (includeTeam and Game.teammate(p))) then
                local c = p.Character
                local root = c and c:FindFirstChild("HumanoidRootPart")
                local hum = c and c:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    table.insert(out, { player = p, char = c, root = root, hum = hum })
                end
            end
        end
        return out
    end
    function Targets.part(char)
        if Settings.AimPart == "Head" then
            return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
        end
        return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
    end
    -- Clear line from `from` to the part, ignoring characters and see-through
    -- parts (the game's own gun ignores fully transparent map parts too).
    function Targets.clear(from, part, char)
        local ignore = { myChar(), char }
        for _, p in Players:GetPlayers() do
            if p.Character then
                table.insert(ignore, p.Character)
            end
        end
        params.FilterDescendantsInstances = ignore
        local dir = part.Position - from
        for _ = 1, 6 do
            local hit = Workspace:Raycast(from, dir, params)
            if not hit then
                return true
            end
            if hit.Instance.Transparency < 1 and hit.Instance.CanQuery then
                return false
            end
            table.insert(ignore, hit.Instance)
            params.FilterDescendantsInstances = ignore
        end
        return false
    end
    function Targets.aimCentre()
        local cam = camera()
        if IsTouch or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
            return cam.ViewportSize / 2
        end
        return UserInputService:GetMouseLocation()
    end
end

--// Picking a target \\--
local Aim = { target = nil, info = "off" }
do
    local fov = Draw.new("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Transparency = 0.8, Visible = false })
    function Aim.pick()
        local cam = camera()
        local root = myRoot()
        if not (cam and root) then
            return nil
        end
        local centre = Targets.aimCentre()
        local best, bestScore
        for _, t in Targets.list(false) do
            local part = Targets.part(t.char)
            local dist = (t.root.Position - root.Position).Magnitude
            if part and dist <= Settings.MaxDistance and (not Settings.VisibleOnly or Targets.clear(root.Position, part, t.char)) then
                local score
                if Settings.Pick == "Closest to aim" then
                    local sp, on = cam:WorldToViewportPoint(part.Position)
                    if on then
                        local d = (Vector2.new(sp.X, sp.Y) - centre).Magnitude
                        if d <= Settings.FOV then
                            score = d
                        end
                    end
                else
                    score = dist
                end
                if score and Settings.Sticky and Aim.target and Aim.target.player == t.player then
                    score -= 30
                end
                if score and (not bestScore or score < bestScore) then
                    t.part = part
                    best, bestScore = t, score
                end
            end
        end
        return best
    end
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local using = alive() and (Settings.GunSilent or Settings.KnifeSilent or Settings.CamLock or Settings.GunTrigger
            or Settings.AutoThrow)
        if fov then
            fov.Visible = using and Settings.ShowFOV and Settings.Pick == "Closest to aim" and cam ~= nil
            if fov.Visible then
                fov.Radius = Settings.FOV
                fov.Position = Targets.aimCentre()
                fov.Color = Aim.target and Settings.EnemyColor or Settings.FOVColor
            end
        end
        if not using then
            Aim.target, Aim.info = nil, "off"
            return
        end
        Aim.target = Aim.pick()
        Aim.info = Aim.target and ("on %s"):format(Aim.target.player.DisplayName) or "no target"
        if Settings.CamLock and Aim.target and cam then
            local cf = cam.CFrame
            local goal = CFrame.lookAt(cf.Position, Aim.target.part.Position)
            cam.CFrame = cf:Lerp(goal, 1 / math.max(1, Settings.CamSmooth))
        end
    end)
end

--// Where to hit \\--
local KNIFE_SPEED = 78 -- 1.3 studs per 1/60 s, straight, no drop
local Lead = {}
function Lead.gun(t)
    local p = t.part.Position
    if Settings.Prediction and Settings.GunLead > 0 then
        local v = t.root.AssemblyLinearVelocity
        p += Vector3.new(v.X, 0, v.Z) * (Settings.GunLead / 1000)
    end
    return p
end
-- Where a knife thrown from `from` meets the target (what you see on your
-- screen is what the knife is checked against, so no ping lead).
function Lead.knife(t, from)
    local p = t.part.Position
    if not Settings.Prediction then
        return p
    end
    local v = t.root.AssemblyLinearVelocity
    v = Vector3.new(v.X, math.clamp(v.Y, -30, 30) * 0.3, v.Z)
    local hit = p
    for _ = 1, 4 do
        local time = (hit - from).Magnitude / KNIFE_SPEED
        hit = p + v * time
    end
    return hit
end

--// The hook: redirect the game's own weapon raycasts \\--
-- Important: inside a __namecall hook, any other method call on an Instance
-- (IsA, FindFirstChild...) changes which method the original call runs. So
-- before the real call is made, this only does table lookups and property
-- reads; anything heavier happens after it.
local Hook = { gunShots = 0, wallbangs = 0, throws = 0, knifeHits = 0, status = "not installed", force = nil, forceUntil = 0,
    lastGunShot = 0 }
local Held = { tool = nil, kind = nil }
local Scripts = {}
do
    -- Which of your tools' scripts is which, rebuilt outside the hook.
    local function scan()
        local map = {}
        local c = myChar()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local held, kind = nil, nil
        for _, holder in { c, bp } do
            for _, t in holder and holder:GetChildren() or {} do
                if t:IsA("Tool") then
                    local ls = t:FindFirstChild("LocalScript")
                    if ls then
                        if Game.isGun(t) then
                            map[ls] = "gun"
                            if holder == c then
                                held, kind = t, "gun"
                            end
                        elseif Game.isKnife(t) then
                            map[ls] = "knife"
                            local fl = ls:FindFirstChild("ThrowingKinfeHandlerScript")
                            if fl then
                                map[fl] = "flight"
                            end
                            if holder == c then
                                held, kind = t, "knife"
                            end
                        end
                    end
                end
            end
        end
        Scripts, Held.tool, Held.kind = map, held, kind
    end
    loop(0.25, scan)

    local function kindOf(scr)
        if scr == nil then
            return nil
        end
        local k = Scripts[scr]
        if k then
            return k
        end
        -- Fallbacks using property reads only.
        local name = scr.Name
        if name == "ThrowingKinfeHandlerScript" then
            return "flight"
        end
        if name == "LocalScript" and Held.tool and scr.Parent == Held.tool then
            return Held.kind
        end
        return nil
    end
    local fakeMeta = {}
    local function fakeResult(inst, pos, normal)
        return setmetatable({ Instance = inst, Position = pos, Normal = normal, Material = Enum.Material.Plastic, Distance = 0 }, fakeMeta)
    end
    local function closest(a, b, p)
        local ab = b - a
        local len2 = ab:Dot(ab)
        if len2 < 1e-6 then
            return a, 0
        end
        local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
        return a + ab * t, t
    end
    local function visiblePart(t, ignore)
        local part = t.part
        if part and part.Transparency >= 1 then
            part = nil
            for _, n in { "UpperTorso", "Torso", "Head", "LowerTorso" } do
                local x = t.char:FindFirstChild(n)
                if x and x:IsA("BasePart") and x.Transparency < 1 then
                    part = x
                    break
                end
            end
        end
        if part and type(ignore) == "table" and table.find(ignore, part) then
            return nil
        end
        return part
    end

    if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        local getCaller = typeof(getcallingscript) == "function" and getcallingscript or nil
        local isOurs = typeof(checkcaller) == "function" and checkcaller or function()
            return false
        end
        local old
        local handler = function(self, ...)
            if Unloaded or self ~= Workspace then
                return old(self, ...)
            end
            local method = getnamecallmethod()
            if method ~= "Raycast" and method ~= "FindPartOnRayWithIgnoreList" then
                return old(self, ...)
            end
            local kind
            if isOurs() then
                -- Our own calls pass straight through, except the game's
                -- weapon code that this script runs itself (fast shots,
                -- auto throws).
                if Hook.force and os.clock() < Hook.forceUntil then
                    kind = Hook.force
                else
                    return old(self, ...)
                end
            else
                kind = kindOf(getCaller and getCaller() or nil)
            end
            if not kind then
                return old(self, ...)
            end

            if method == "Raycast" then
                if kind ~= "gun" then
                    return old(self, ...)
                end
                Hook.lastGunShot = os.clock()
                local t = Aim.target
                local origin, _, rp = ...
                if not ((Settings.GunSilent or Settings.Wallbang) and t and t.part and typeof(origin) == "Vector3") then
                    return old(self, ...)
                end
                local at = Lead.gun(t)
                local dir = (at - origin).Unit * 10000
                local real = old(self, origin, dir, rp)
                -- From here on other calls are safe.
                if real and real.Instance and real.Instance:IsDescendantOf(t.char) then
                    Hook.gunShots += 1
                    return real
                end
                if Settings.Wallbang and t.part.Parent then
                    Hook.wallbangs += 1
                    return fakeResult(t.part, at, -dir.Unit)
                end
                return real
            end

            -- FindPartOnRayWithIgnoreList: do the real call first.
            local ray, ignore = ...
            local r = table.pack(old(self, ...))
            if typeof(ray) ~= "Ray" then
                return table.unpack(r, 1, r.n)
            end
            if kind == "knife" and Settings.KnifeSilent then
                -- Picking where to throw.
                local t = Aim.target
                local tool = Held.tool
                local handle = tool and tool:FindFirstChild("Handle")
                local part = t and visiblePart(t, ignore)
                if part and part.Parent and handle then
                    Hook.throws += 1
                    local at = Lead.knife(t, handle.Position)
                    return part, at, -(at - handle.Position).Unit
                end
            elseif kind == "flight" and Settings.KnifeHitbox > 0 then
                -- Stepping your flying knife: a bigger hitbox around enemies.
                local hit, pos = r[1], r[2]
                local a = ray.Origin
                local b = ray.Origin + ray.Direction
                local wallT = (hit and typeof(pos) == "Vector3") and ((pos - a).Magnitude / math.max(ray.Direction.Magnitude, 1e-6)) or 2
                local bestPart, bestPos, bestT
                for _, t in Targets.list(false) do
                    local part = Targets.part(t.char) or t.root
                    local c, along = closest(a, b, part.Position)
                    if (c - part.Position).Magnitude <= Settings.KnifeHitbox and along <= wallT and (not bestT or along < bestT) then
                        bestPart, bestPos, bestT = part, c, along
                    end
                end
                if bestPart and not (hit and hit:IsDescendantOf(bestPart.Parent)) then
                    Hook.knifeHits += 1
                    return bestPart, bestPos, -(ray.Direction.Unit), Enum.Material.Plastic
                end
            end
            return table.unpack(r, 1, r.n)
        end
        if typeof(newcclosure) == "function" then
            handler = newcclosure(handler)
        end
        old = hookmetamethod(game, "__namecall", handler)
        Hook.status = getCaller and "hooked" or "hooked (no getcallingscript: silent aim off)"
    else
        Hook.status = "your executor has no hookmetamethod"
    end
end

--// Fire / throw rate \\--
-- Gun: the game's own shoot function (from its Activated handler) is called for
-- extra shots while the gun's 2.5s wait is running. The gun's own state is never
-- changed, so it can't get stuck.
-- Knife: the flag shared by slash and throw is cleared sooner (only on your side).
local Rate = { status = "", fast = 0 }
do
    local function handlerOf(tool)
        if typeof(getconnections) ~= "function" then
            return nil
        end
        local scr = tool:FindFirstChild("LocalScript")
        for _, c in getconnections(tool.Activated) do
            local f = c.Function
            if type(f) == "function" then
                local okEnv, env = pcall(getfenv, f)
                if okEnv and type(env) == "table" and rawget(env, "script") == scr then
                    local ok, ups = pcall(debug.getupvalues, f)
                    if ok and type(ups) == "table" then
                        return f, ups
                    end
                end
            end
        end
        return nil
    end
    Rate.handlerOf = handlerOf

    -- Gun: its Activated handler's upvalues are (player, MatchState, busy, Shoot).
    local hooked = setmetatable({}, { __mode = "k" })
    local lastFast = 0
    local function onActivated(tool)
        if not (alive() and Settings.FastGun) then
            return
        end
        task.defer(function()
            local f, ups = handlerOf(tool)
            if not f then
                Rate.status = "gun handler not found"
                return
            end
            local busy, shoot = ups[3], ups[4]
            if type(busy) ~= "boolean" or type(shoot) ~= "function" then
                Rate.status = "gun shoot function not found"
                return
            end
            local now = os.clock()
            -- The game just shot on this click itself, or isn't busy: leave it.
            if not busy or now - Hook.lastGunShot < 0.08 then
                return
            end
            if now - math.max(lastFast, Hook.lastGunShot) < Settings.GunCooldown or not Game.roundLive() then
                return
            end
            local c = myChar()
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 or tool.Parent ~= c then
                return
            end
            lastFast = now
            Rate.fast += 1
            Hook.force, Hook.forceUntil = "gun", os.clock() + 0.25
            pcall(shoot)
            Hook.force = nil
            Rate.status = "gun: extra shot"
        end)
    end
    loop(0.5, function()
        local c = myChar()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        for _, holder in { c, bp } do
            for _, t in holder and holder:GetChildren() or {} do
                if Game.isGun(t) and not hooked[t] then
                    hooked[t] = true
                    bind(t.Activated, function()
                        onActivated(t)
                    end)
                end
            end
        end
    end)

    -- Knife: the Activated handler's 5th upvalue is the busy flag.
    local KNIFE_SLOT = 5
    local knifeSince = nil
    bind(RunService.Heartbeat, function()
        if not alive() or type(debug.setupvalue) ~= "function" then
            return
        end
        local tool = Held.tool
        if Settings.FastKnife and Held.kind == "knife" and tool then
            local f, ups = handlerOf(tool)
            local v = ups and ups[KNIFE_SLOT]
            if not f or type(v) ~= "boolean" then
                Rate.status = "knife flag not found"
                return
            end
            local now = os.clock()
            if v then
                knifeSince = knifeSince or now
                if now - knifeSince >= Settings.KnifeCooldown then
                    pcall(debug.setupvalue, f, KNIFE_SLOT, false)
                    knifeSince = nil
                end
            else
                knifeSince = nil
            end
            Rate.status = "knife: on"
        elseif not Settings.FastGun then
            Rate.status = "off"
            knifeSince = nil
        end
    end)
end

--// Gun triggerbot \\--
local Trigger = { shots = 0, info = "off" }
do
    local seenAt, last = nil, 0
    bind(RunService.Heartbeat, function()
        if not (alive() and Settings.GunTrigger) then
            Trigger.info, seenAt = "off", nil
            return
        end
        local tool = Game.tool()
        if not Game.isGun(tool) then
            Trigger.info, seenAt = "no gun out", nil
            return
        end
        if not Game.roundLive() then
            Trigger.info = "round not running"
            return
        end
        local t = Aim.target
        if not t then
            Trigger.info, seenAt = "waiting", nil
            return
        end
        local now = os.clock()
        seenAt = seenAt or now
        if now - seenAt < Settings.GunTriggerDelay / 1000 or now - last < 0.15 then
            return
        end
        last = now
        Trigger.shots += 1
        Trigger.info = "shooting " .. t.player.DisplayName
        pcall(tool.Activate, tool)
    end)
end

--// Knife: auto throw, auto slash \\--
local KnifeAuto = { throws = 0, slashes = 0, info = "off" }
do
    -- The knife script's own throw input handler (E / L2), called with a
    -- stand-in input so the game plays the throw exactly as if you pressed it.
    local function throwHandler(tool)
        if typeof(getconnections) ~= "function" then
            return nil
        end
        local scr = tool:FindFirstChild("LocalScript")
        for _, c in getconnections(UserInputService.InputBegan) do
            local f = c.Function
            if type(f) == "function" then
                local ok, env = pcall(getfenv, f)
                if ok and type(env) == "table" and rawget(env, "script") == scr then
                    return f
                end
            end
        end
        return nil
    end
    local cache = { tool = nil, fn = nil }
    local lastThrow, lastSlash = 0, 0
    bind(RunService.Heartbeat, function()
        if not alive() or not (Settings.AutoThrow or Settings.AutoSlash) then
            KnifeAuto.info = "off"
            return
        end
        local tool = Game.tool()
        if not Game.isKnife(tool) then
            KnifeAuto.info = "no knife out"
            return
        end
        if not Game.roundLive() then
            KnifeAuto.info = "round not running"
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        local now = os.clock()
        if Settings.AutoSlash and now - lastSlash > 0.25 then
            for _, t in Targets.list(false) do
                if (t.root.Position - root.Position).Magnitude <= Settings.SlashRange then
                    lastSlash = now
                    KnifeAuto.slashes += 1
                    KnifeAuto.info = "slashing " .. t.player.DisplayName
                    pcall(tool.Activate, tool)
                    return
                end
            end
        end
        if Settings.AutoThrow and now - lastThrow > 0.3 then
            local t = Aim.target
            if t and (t.root.Position - root.Position).Magnitude <= Settings.AutoThrowRange then
                if cache.tool ~= tool then
                    cache.tool, cache.fn = tool, throwHandler(tool)
                end
                if cache.fn then
                    lastThrow = now
                    KnifeAuto.throws += 1
                    KnifeAuto.info = "throwing at " .. t.player.DisplayName
                    Hook.force, Hook.forceUntil = "knife", os.clock() + 0.6
                    task.spawn(cache.fn, { UserInputState = Enum.UserInputState.Begin, KeyCode = Enum.KeyCode.E,
                        UserInputType = Enum.UserInputType.Keyboard }, false)
                else
                    KnifeAuto.info = "throw handler not found"
                end
            end
        end
    end)
end

--// Incoming knives: tracers and dodge \\--
local Knives = { dodges = 0 }
do
    local seen = {}
    local function isEnemyKnife(k)
        if k.Name ~= "ThrowingServerKnife" and k.Name ~= "ThrowingKnifeServer" then
            return false
        end
        local cr = k:FindFirstChild("Creator")
        local p = cr and cr:IsA("ObjectValue") and cr.Value
        return p and p:IsA("Player") and p ~= LocalPlayer and Game.enemy(p)
    end
    local lines = {}
    local lastDodge = 0
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        local want = Settings.KnifeDodge or Settings.KnifeTracers
        local cam = camera()
        local root = myRoot()
        local used = 0
        if want and root then
            for _, k in CollectionService:GetTagged("ThrowingKnife") do
                if k:IsA("BasePart") and k.Parent and isEnemyKnife(k) then
                    local s = seen[k]
                    local pos = k.Position
                    if s and dt > 0 then
                        local vel = (pos - s.pos) / math.max(os.clock() - s.at, 1 / 240)
                        s.vel = s.vel and s.vel:Lerp(vel, 0.5) or vel
                    end
                    seen[k] = { pos = pos, at = os.clock(), vel = s and s.vel }
                    local vel = seen[k].vel
                    if vel and vel.Magnitude > 20 then
                        local rel = root.Position - pos
                        local tHit = rel:Dot(vel) / vel:Dot(vel)
                        if Settings.KnifeTracers and Draw.ok and cam then
                            used += 1
                            local l = lines[used]
                            if not l then
                                l = Draw.new("Line", { Thickness = 2, Color = Color3.fromRGB(255, 160, 40) })
                                lines[used] = l
                            end
                            if l then
                                local a, onA = cam:WorldToViewportPoint(pos)
                                local b, onB = cam:WorldToViewportPoint(pos + vel * 0.6)
                                l.Visible = (onA or onB) and a.Z > 0 and b.Z > 0
                                l.From = Vector2.new(a.X, a.Y)
                                l.To = Vector2.new(b.X, b.Y)
                            end
                        end
                        if Settings.KnifeDodge and tHit > 0 and tHit < 0.5 and os.clock() - lastDodge > 0.4 then
                            local pass = pos + vel * tHit
                            local miss = root.Position - pass
                            local flat = Vector3.new(miss.X, 0, miss.Z)
                            if flat.Magnitude < 3.5 then
                                local side = Vector3.new(-vel.Z, 0, vel.X)
                                side = side.Magnitude > 0 and side.Unit or Vector3.new(1, 0, 0)
                                if flat.Magnitude > 0.2 and flat:Dot(side) < 0 then
                                    side = -side
                                end
                                root.CFrame += side * Settings.DodgeDistance
                                lastDodge = os.clock()
                                Knives.dodges += 1
                            end
                        end
                    end
                end
            end
        end
        for k in seen do
            if not k.Parent then
                seen[k] = nil
            end
        end
        for i = used + 1, #lines do
            if lines[i] then
                lines[i].Visible = false
            end
        end
    end)
end

--// ESP \\--
do
    local pool = {}
    local function make()
        return {
            box = Draw.new("Square", { Thickness = 1.5, Filled = false, Visible = false }),
            name = Draw.new("Text", { Size = 14, Center = true, Outline = true, Visible = false }),
            info = Draw.new("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            tracer = Draw.new("Line", { Thickness = 1, Visible = false }),
        }
    end
    local function hide(e)
        for _, d in e do
            if d then
                d.Visible = false
            end
        end
    end
    bind(Players.PlayerRemoving, function(p)
        if pool[p] then
            for _, d in pool[p] do
                Draw.remove(d)
            end
            pool[p] = nil
        end
    end)
    local function weaponOf(p)
        local c = p.Character
        local t = c and c:FindFirstChildOfClass("Tool")
        if t then
            return (Game.isGun(t) and "gun: " or Game.isKnife(t) and "knife: " or "") .. t.Name
        end
        return nil
    end
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local root = myRoot()
        local seen = {}
        if alive() and Settings.Esp and Draw.ok and cam then
            for _, t in Targets.list(Settings.EspTeam) do
                local p = t.player
                seen[p] = true
                local e = pool[p]
                if not e then
                    e = make()
                    pool[p] = e
                end
                local cf = t.root.CFrame
                local top, onTop = cam:WorldToViewportPoint((cf * CFrame.new(0, 3, 0)).Position)
                local bot, onBot = cam:WorldToViewportPoint((cf * CFrame.new(0, -3.5, 0)).Position)
                if not (onTop or onBot) or top.Z < 0 then
                    hide(e)
                    continue
                end
                local colour = Game.teammate(p) and Settings.TeamColor or Settings.EnemyColor
                local h = math.abs(bot.Y - top.Y)
                local w = h * 0.55
                if e.box then
                    e.box.Visible = Settings.EspBoxes
                    e.box.Position = Vector2.new(top.X - w / 2, top.Y)
                    e.box.Size = Vector2.new(w, h)
                    e.box.Color = colour
                end
                if e.name then
                    e.name.Visible = Settings.EspNames
                    e.name.Text = p.DisplayName
                    e.name.Position = Vector2.new(top.X, top.Y - 16)
                    e.name.Color = colour
                end
                if e.info then
                    local bits = {}
                    if Settings.EspDistance and root then
                        table.insert(bits, ("%dm"):format((t.root.Position - root.Position).Magnitude))
                    end
                    if Settings.EspWeapon then
                        local wpn = weaponOf(p)
                        if wpn then
                            table.insert(bits, wpn)
                        end
                    end
                    e.info.Visible = #bits > 0
                    e.info.Text = table.concat(bits, " · ")
                    e.info.Position = Vector2.new(top.X, top.Y + h + 2)
                    e.info.Color = Color3.new(1, 1, 1)
                end
                if e.tracer then
                    e.tracer.Visible = Settings.EspTracers
                    e.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                    e.tracer.To = Vector2.new(bot.X, bot.Y)
                    e.tracer.Color = colour
                end
            end
        end
        for p, e in pool do
            if not seen[p] then
                hide(e)
            end
        end
    end)
end

--// Movement \\--
do
    local flyUp = 0
    bind(UserInputService.InputBegan, function(i, gpe)
        if gpe then
            return
        end
        if i.KeyCode == Enum.KeyCode.Space then
            flyUp = 1
        elseif i.KeyCode == Enum.KeyCode.LeftControl then
            flyUp = -1
        end
    end)
    bind(UserInputService.InputEnded, function(i)
        if i.KeyCode == Enum.KeyCode.Space or i.KeyCode == Enum.KeyCode.LeftControl then
            flyUp = 0
        end
    end)
    local jumpBefore = nil
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        local c = myChar()
        local root = c and c:FindFirstChild("HumanoidRootPart")
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not (root and hum) or hum.Health <= 0 then
            return
        end
        if Settings.JumpBoost then
            if jumpBefore == nil then
                jumpBefore = { hum.UseJumpPower, hum.JumpPower }
            end
            hum.UseJumpPower = true
            hum.JumpPower = Settings.JumpPower
        elseif jumpBefore then
            hum.UseJumpPower, hum.JumpPower = jumpBefore[1], jumpBefore[2]
            jumpBefore = nil
        end
        local move = hum.MoveDirection
        if Settings.Fly then
            local cam = camera()
            local dir = Vector3.zero
            if move.Magnitude > 0 then
                local look = cam.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                local along = flat.Magnitude > 0 and move:Dot(flat.Unit) or 0
                dir = move + Vector3.new(0, look.Y * along, 0)
            end
            dir += Vector3.new(0, flyUp, 0)
            if hum.Jump then
                dir += Vector3.new(0, 1, 0)
            end
            root.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * Settings.FlySpeed or Vector3.zero
            return
        end
        if Settings.Speed and move.Magnitude > 0 then
            root.CFrame += move * Settings.SpeedAmount * dt
        end
    end)
    local cleared = {}
    bind(RunService.Stepped, function()
        if not (alive() and Settings.Noclip) then
            for p in cleared do
                if p.Parent then
                    p.CanCollide = true
                end
            end
            table.clear(cleared)
            return
        end
        local c = myChar()
        for _, p in c and c:GetDescendants() or {} do
            if p:IsA("BasePart") and p.CanCollide then
                p.CanCollide = false
                cleared[p] = true
            end
        end
    end)
    bind(UserInputService.JumpRequest, function()
        if alive() and Settings.InfJump then
            local c = myChar()
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end)
end

--// Rewards and automation \\--
local Misc = { info = "" }
do
    function Misc.redeemAll()
        local R = Game.Remotes
        local remote = R and R.Code
        if not remote then
            notify("Code remote not found")
            return
        end
        local got, tried = 0, 0
        for code in Game.Codes do
            tried += 1
            local ok, res = pcall(remote.InvokeServer, remote, code)
            if ok and res == true then
                got += 1
            end
            task.wait(0.4)
        end
        notify(("Codes: %d of %d redeemed (the rest were already used or expired)"):format(got, tried), 4)
    end
    function Misc.claimDaily()
        local R = Game.Remotes
        local remote = R and R.ClaimDailyReward
        if remote then
            pcall(remote.FireServer, remote)
            notify("Daily reward claimed (if it was ready)", 2)
        end
    end
    -- Rematch vote when the game shows the match results.
    do
        local R = Game.Remotes
        local results = R and R.MatchResults
        if results and results.OnClientEvent then
            bind(results.OnClientEvent, function()
                if not Settings.AutoRematch then
                    return
                end
                task.delay(1.5, function()
                    local vote = Game.Remotes and Game.Remotes.RematchVote
                    if alive() and vote then
                        pcall(vote.FireServer, vote)
                    end
                end)
            end)
        end
    end
    -- Event pickups (touched to collect).
    loop(0.5, function()
        if not Settings.AutoCollect or typeof(firetouchinterest) ~= "function" then
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        for _, tag in { "Sombrero" } do
            for _, part in CollectionService:GetTagged(tag) do
                local p = part:IsA("Model") and part.PrimaryPart or part
                if p and p:IsA("BasePart") and p:IsDescendantOf(Workspace) then
                    pcall(firetouchinterest, root, p, 0)
                    pcall(firetouchinterest, root, p, 1)
                end
            end
        end
    end)
    local ok, vu = pcall(game.GetService, game, "VirtualUser")
    bind(LocalPlayer.Idled, function()
        if Settings.AntiAfk and ok and vu then
            pcall(function()
                vu:CaptureController()
                vu:ClickButton2(Vector2.new())
            end)
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "MvS Duels",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/MvsDuels",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
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
local function color(t, key, title)
    if t and t.AddColorPicker then
        pcall(function()
            t:AddColorPicker(key .. "Pick", {
                Default = Settings[key], Title = title,
                Callback = function(c)
                    Settings[key] = c
                end,
            })
        end)
    end
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.3)
        end
    end)
end

do
    local Tab = Window:AddTab("Gun", "crosshair", "Silent aim, triggerbot, fire rate")
    local Box = Tab:AddLeftGroupbox("Gun", "crosshair")
    toggle(Box, "GunSilent", "Silent aim",
        "Your gun's own raycast goes at the target, so a normal shot (click or tap anywhere) hits them. Walls still block it")
    toggle(Box, "Wallbang", "Wallbang (risky)",
        "When a wall is in the way, the shot is handed to the game as a hit anyway. Only works if the server doesn't check line of sight")
    slider(Box, "GunLead", "Lead", 0, 300, 0, " ms", "Shoot ahead of moving targets. Usually 0: the hit is decided on your screen")
    toggle(Box, "GunTrigger", "Triggerbot", "Shoots (the game's own trigger) as soon as there's a target")
    slider(Box, "GunTriggerDelay", "Trigger reaction", 0, 500, 0, " ms")
    toggle(Box, "FastGun", "Faster shooting",
        "Extra shots through the game's own shoot function while its 2.5s wait runs. The gun itself is never changed. If shots stop counting, the server enforces the 2.5s")
    slider(Box, "GunCooldown", "Time between shots", 0.1, 2.5, 2, " s")
    status(Box, function()
        return ("Target: %s\nHook: %s\nSilent hits: %d  Wallbangs: %d\nTrigger: %s (%d)\nRate: %s (extra shots %d)"):format(
            Aim.info, Hook.status, Hook.gunShots, Hook.wallbangs, Trigger.info, Trigger.shots, Rate.status, Rate.fast)
    end)

    local Pick = Tab:AddRightGroupbox("Targeting", "users")
    dropdown(Pick, "Pick", "Pick", { "Closest to aim", "Closest to you" }, "Closest to you ignores where you aim (best on phone)")
    slider(Pick, "FOV", "Circle size", 30, 900, 0, " px")
    color(toggle(Pick, "ShowFOV", "Show circle"), "FOVColor", "Circle colour")
    dropdown(Pick, "AimPart", "Aim at", { "Torso", "Head" })
    slider(Pick, "MaxDistance", "Max distance", 20, 2000, 0, " studs")
    toggle(Pick, "VisibleOnly", "Only visible", "Skips anyone behind a wall (turn off with wallbang)")
    toggle(Pick, "Prediction", "Prediction", "Leads moving targets (knife: where the knife meets them)")
    toggle(Pick, "Sticky", "Stick to target")
    toggle(Pick, "CamLock", "Camlock", "Turns your real camera onto the target. Shows in the game's recorder: silent aim doesn't")
    slider(Pick, "CamSmooth", "Camlock smoothness", 1, 30, 0, "")
end

do
    local Tab = Window:AddTab("Knife", "swords", "Throws, hitbox, auto")
    local Box = Tab:AddLeftGroupbox("Throwing", "swords")
    toggle(Box, "KnifeSilent", "Throw silent aim", "Your throw goes where the target will be when the knife (78 studs/s) gets there")
    slider(Box, "KnifeHitbox", "Knife hitbox", 0, 12, 1, " studs",
        "0 = normal. Your flying knife counts as a hit when it passes this close to an enemy (never through walls)")
    toggle(Box, "FastKnife", "Faster throws / slashes", "The wait after a throw or slash is only on your side")
    slider(Box, "KnifeCooldown", "Wait", 0.05, 1, 2, " s")
    toggle(Box, "AutoThrow", "Auto throw", "Throws (the game's own throw) whenever there's a target in range")
    slider(Box, "AutoThrowRange", "Auto throw range", 10, 400, 0, " studs")
    toggle(Box, "AutoSlash", "Auto slash", "Slashes when an enemy is right next to you")
    slider(Box, "SlashRange", "Slash range", 3, 15, 0, " studs")
    status(Box, function()
        return ("Throws aimed: %d\nKnife hitbox hits: %d\nAuto: %s (throws %d, slashes %d)"):format(
            Hook.throws, Hook.knifeHits, KnifeAuto.info, KnifeAuto.throws, KnifeAuto.slashes)
    end)
    local Def = Tab:AddRightGroupbox("Incoming knives", "shield")
    toggle(Def, "KnifeDodge", "Dodge knives", "Steps aside when an enemy's thrown knife is about to hit you")
    slider(Def, "DodgeDistance", "Dodge step", 2, 15, 0, " studs")
    toggle(Def, "KnifeTracers", "Knife tracers", "Draws where enemy knives are flying")
    status(Def, function()
        return ("Dodges: %d"):format(Knives.dodges)
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "See everyone in your match")
    local Box = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(Box, "Esp", "ESP", "Players in your duel")
    toggle(Box, "EspBoxes", "Boxes")
    toggle(Box, "EspNames", "Names")
    toggle(Box, "EspDistance", "Distance")
    toggle(Box, "EspWeapon", "Weapon")
    toggle(Box, "EspTracers", "Tracers")
    color(toggle(Box, "EspTeam", "Show teammates"), "TeamColor", "Team colour")
    Box:AddLabel("Enemy colour", false)
    color(Box, "EnemyColor", "Enemy colour")
end

do
    local Tab = Window:AddTab("Movement", "move", "Speed, jump, fly")
    local Box = Tab:AddLeftGroupbox("Movement", "move")
    toggle(Box, "Speed", "Speed")
    slider(Box, "SpeedAmount", "Extra speed", 1, 80, 0, " studs/s")
    toggle(Box, "JumpBoost", "Jump boost")
    slider(Box, "JumpPower", "Jump power", 50, 200, 0, "")
    toggle(Box, "InfJump", "Infinite jump")
    toggle(Box, "Noclip", "Noclip")
    toggle(Box, "Fly", "Fly", "Move to fly where the camera looks, Space / Ctrl or jump for up / down")
    slider(Box, "FlySpeed", "Fly speed", 10, 200, 0, " studs/s")
end

do
    local Tab = Window:AddTab("Misc", "gift", "Codes, rewards, server")
    local Box = Tab:AddLeftGroupbox("Rewards", "gift")
    Box:AddButton({ Text = "Redeem every code", Func = function()
        task.spawn(Misc.redeemAll)
    end })
    local list = {}
    for code in Game.Codes do
        table.insert(list, code)
    end
    table.sort(list)
    Box:AddLabel("Codes in the game: " .. (#list > 0 and table.concat(list, ", ") or "none found"), true)
    Box:AddButton({ Text = "Claim daily reward", Func = Misc.claimDaily })
    toggle(Box, "AutoCollect", "Auto collect event pickups", "Picks up event items (e.g. sombreros) on the map")
    toggle(Box, "AutoRematch", "Auto rematch", "Votes rematch when a match ends")
    local Srv = Tab:AddRightGroupbox("Server", "server")
    toggle(Srv, "AntiAfk", "Anti AFK")
    Srv:AddButton({ Text = "Rejoin", Func = function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end })
    Srv:AddButton({ Text = "Unload", Func = function()
        if Genv.__MvsUnload then
            Genv.__MvsUnload()
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
Genv.__MvsUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(("Loaded%s%s"):format(Game.Match and "" or " (MatchState not found: everyone counts as an enemy)",
    Hook.status == "hooked" and "" or (" (" .. Hook.status .. ")")), 4)

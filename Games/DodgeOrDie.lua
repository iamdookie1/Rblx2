--// Dodge or Die -- auto dodge, ball esp, anti blind and staff alerts.
--
-- A ball is a part in workspace.Balls pulled along by an AlignPosition whose
-- Attachment1 is the RootAttachment of whoever it is chasing, so who a ball is
-- after and how soon it gets to you both read straight off the part. Hits are
-- judged on your own client: every frame the game checks whether a ball's
-- sphere overlaps one of your limbs and, if it does, tells the server. A dodge
-- only has to clear the ball as your own screen shows it.
--
-- Dashes go through the game's own DashHandler. Its InputBegan handler is
-- called with your dash key, so the cooldowns, the animation and the
-- MovementGrace message the server expects before a burst of speed all happen
-- exactly as if you had pressed the key yourself.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function resolveEvent(modern, legacy)
    local ok, event = pcall(function() return RunService[modern] end)
    if ok and event then return event end
    return RunService[legacy]
end

-- The dodge runs before physics, so a dash's velocity already moves you in
-- this frame's step, ahead of the game's own hit check on Heartbeat.
local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PreRender = resolveEvent("PreRender", "RenderStepped")

track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end))

local Onyx
do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Onyx] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/Ui.lua'):format(ref)
    Onyx = loadstring(game:HttpGet(url))()
end

local function addStat(section, cfg)
    local title = cfg.Title
    local label = section:Label({ Title = title .. ': ' .. tostring(cfg.Value), Color = cfg.Color })
    local api = {}
    function api.Set(value, color)
        label:SetText(title .. ': ' .. tostring(value))
        if color then label:SetColor(color) end
    end
    return api
end

local function notify(title, content, kind, duration)
    Onyx:Notify({ Title = title, Content = content, Type = kind or 'info', Duration = duration or 4 })
end

local function guiRoot()
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local GuiRoot = guiRoot()
local HasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"

--// state --------------------------------------------------------------------

local Dodge = {
    Enabled = false,
    AutoTiming = true,
    At = 150,
    Jitter = 20,
    Turn = true,
    Forward = true,
    Stray = true,
    IgnoreFake = true,

    ping = 0.12,
    pingAt = -math.huge,
    holdUntil = -math.huge,
    refusals = 0,
    dashes = 0,
    status = "off",
    action = nil,
}

local Esp = {
    Enabled = false,
    Info = true,
    Lines = true,
    Warning = true,
}

local Blind = {
    Enabled = true,
    Notify = true,
    blocked = 0,
}

local Staff = {
    Enabled = true,
    Leaves = true,
    here = {},
}

local JITTER = { ['none'] = 0, ['10 ms'] = 10, ['20 ms'] = 20, ['40 ms'] = 40 }

--// helpers ------------------------------------------------------------------

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function myCharacter()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then return nil end
    return char, root, humanoid
end

-- Full round trip. GetNetworkPing is one way; the Data Ping stat, when it can
-- be read, is the server's own round trip and wins if it is the larger.
local PingItem
local function roundTrip()
    local rtt = 0
    local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(ping) == "number" and ping > 0 then rtt = ping * 2 end
    if PingItem == nil then
        local found, item = pcall(function() return game:GetService("Stats").Network.ServerStatsItem["Data Ping"] end)
        PingItem = found and item or false
    end
    if PingItem then
        local okData, ms = pcall(function() return PingItem:GetValue() end)
        if okData and type(ms) == "number" and ms / 1000 > rtt then rtt = ms / 1000 end
    end
    if rtt <= 0 then return 0.12 end
    return math.min(rtt, 1)
end

--// balls ---------------------------------------------------------------------

-- [part] = what the last scan worked out about that ball
local Balls = {}
local Watched = {}

local function addBall(part)
    if Balls[part] or not part:IsA("BasePart") then return end
    Balls[part] = {
        last = part.Position,
        lastAt = os.clock(),
        onMe = false,
        -- a practice ball lives on your own client, so it reacts to you the
        -- instant you move; a round's ball only once the server has seen it
        practice = part.Parent ~= nil and part.Parent.Name == "PracticeBalls",
    }
end

local function dropBall(part)
    Balls[part] = nil
end

local function watchFolder(folder)
    if Watched[folder] then return end
    Watched[folder] = true
    for _, child in ipairs(folder:GetChildren()) do addBall(child) end
    track(folder.ChildAdded:Connect(addBall))
    track(folder.ChildRemoved:Connect(dropBall))
end

-- Rounds use workspace.Balls. The practice area in the lobby spawns its own
-- balls on your client that chase you the same way, so those are watched too.
local function findBallFolders()
    for folder in pairs(Watched) do
        if folder.Parent == nil then Watched[folder] = nil end
    end
    local live = Workspace:FindFirstChild("Balls")
    if live then watchFolder(live) end
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == "Lobby" then
            local area = child:FindFirstChild("PracticeArea")
            local practice = area and area:FindFirstChild("PracticeBalls")
            if practice then watchFolder(practice) end
        end
    end
end

-- the game's own hit sphere: half the ball's largest side less 0.15, at least 0.3
local function ballReach(part)
    local size = part.Size
    return math.max(math.max(size.X, size.Y, size.Z) * 0.5 - 0.15, 0.3)
end

local function ballTarget(part)
    local align = part:FindFirstChild("AlignPosition")
    if not align then return nil end
    local ok, attachment = pcall(function() return align.Attachment1 end)
    if ok then return attachment end
    return nil
end

-- Replicated velocity is right for a ball moved by physics. The measured one
-- only stands in when a ball is being moved some other way.
local function ballVelocity(part, state, now)
    local vel = part.AssemblyLinearVelocity
    local dt = now - state.lastAt
    if dt > 1e-3 then
        local pos = part.Position
        local measured = (pos - state.last) / dt
        state.last = pos
        state.lastAt = now
        state.measured = (vel.Magnitude < 1 and measured.Magnitude > 4) and measured or nil
    end
    return state.measured or vel
end

--// body ----------------------------------------------------------------------

-- Your hitbox as a capsule around the root: an axis from lo to hi studs above
-- the root, radius studs thick. The game's hit check counts every part in
-- your character (accessories and held tool models too), so this does as
-- well, re-measured every couple of seconds so a shrink watch is covered.
local Body = { char = nil, at = -math.huge, lo = -1, hi = 0.5, radius = 2 }

function Body.measure(char, root, now)
    Body.char = char
    Body.at = now
    local rootPos = root.Position
    local lo, hi, radius = math.huge, -math.huge, 0
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "VFXPart" then
            local offset = part.Position - rootPos
            local size = part.Size
            lo = math.min(lo, offset.Y - size.Y * 0.5)
            hi = math.max(hi, offset.Y + size.Y * 0.5)
            local out = math.sqrt(offset.X * offset.X + offset.Z * offset.Z) + math.max(size.X, size.Z) * 0.5
            radius = math.max(radius, out)
        end
    end
    if lo >= hi then return end
    radius = math.clamp(radius, 0.6, 2.5)
    -- the capsule's rounded ends already reach radius past each end of the axis
    Body.radius = radius
    Body.lo = math.min(lo + radius, 0)
    Body.hi = math.max(hi - radius, 0)
end

-- how far outside your body a point (relative to the root) sits
local function bodyGap(rel)
    local y = rel.Y
    if y > Body.hi then
        y = y - Body.hi
    elseif y < Body.lo then
        y = y - Body.lo
    else
        y = 0
    end
    return math.sqrt(rel.X * rel.X + y * y + rel.Z * rel.Z) - Body.radius
end

--// prediction ----------------------------------------------------------------

local HORIZON = 0.7
local FRAME = 1 / 60
-- how long a ball can stay on you before auto dodge stops dashing at it
local STUCK_AFTER = 0.06

-- How a dash carries you: the game sets you off at its dash speed, then your
-- humanoid drags you back down to walking pace, roughly exponentially.
local DASH_TAU = 0.08

local function slideAt(speed, t)
    return speed * DASH_TAU * (1 - math.exp(-t / DASH_TAU))
end

-- How hard a ball has been seen to change its velocity (studs a second, per
-- second) and how fast it has gone: a smoothed value with a slowly fading
-- peak, so one noisy frame does not stick. A ball not watched yet counts as a
-- strong one.
local STRONG = 600
-- the most a single frame's change is believed: replicated velocities jump
local STRONGEST = 4000

local function updateMotion(state, vel, now)
    local prev, prevAt = state.prevVel, state.prevAt
    state.prevVel, state.prevAt = vel, now
    if not prev then
        state.top = vel.Magnitude
        return
    end
    local dt = now - prevAt
    if dt <= 1e-3 then return end
    state.top = math.max(vel.Magnitude, (state.top or 0) - 10 * dt)
    local accel = math.min((vel - prev).Magnitude / dt, STRONGEST)
    state.accEma = (state.accEma or 0) + (accel - (state.accEma or 0)) * 0.3
    state.accPeak = math.max(state.accEma, (state.accPeak or STRONG) - 300 * dt)
end

-- Where you will be, relative to where you are: you keep walking the way you
-- are, and any speed on top of that (a dash, a knock) dies away.
local function yourPath(humanoid, velocity)
    local walk = Vector3.zero
    local ok, dir = pcall(function() return humanoid.MoveDirection end)
    if ok and typeof(dir) == "Vector3" then walk = flat(dir) * (humanoid.WalkSpeed or 16) end
    local extra = flat(velocity) - walk
    return function(t)
        return walk * t + extra * (DASH_TAU * (1 - math.exp(-t / DASH_TAU)))
    end
end

-- Flies a ball forward against where you will be and returns the closest it
-- comes to your body and when it first touches you. It keeps flying the way
-- it is going until it can react to you (never, for a ball chasing someone
-- else; once the server has seen you move, for a round's ball; at once, for a
-- practice ball), then steers at where it sees you as hard as it has been seen
-- to steer. With later set, how close it gets counts for less the further off
-- it is, since there will be another dash by then.
local function flyBall(ball, path, horizon, stopAtTouch, later)
    local pos, vel = ball.rel, ball.vel
    if pos.Magnitude > (math.max(ball.top, vel.Magnitude) + 20) * horizon + 10 then
        return math.huge, nil
    end
    local steer = ball.accel * FRAME
    local closest, touch = math.huge, nil
    local t = 0
    while t <= horizon do
        local gap = bodyGap(pos - path(t)) - ball.reach
        local counted = gap + (later or 0) * t
        if counted < closest then closest = counted end
        if gap <= 0 and not touch then
            touch = t
            if stopAtTouch then break end
        end
        if t >= ball.lag then
            local want = path(t - ball.lag) - pos
            local dist = want.Magnitude
            if dist > 1e-3 then
                local change = want * (ball.top / dist) - vel
                local size = change.Magnitude
                if size > steer then change = change * (steer / size) end
                vel = vel + change
            end
        end
        pos = pos + vel * FRAME
        t = t + FRAME
    end
    return closest, touch
end

-- Works out, for every ball, who it is after and how soon it would reach you.
-- The most urgent one worth dodging comes back as ctx.threat.
local function scan(now)
    local ctx = { count = 0, onMe = 0 }
    local char, root, humanoid = myCharacter()
    if not char then
        for _, state in pairs(Balls) do
            state.tti = nil
            state.onMe = false
            state.fly = nil
        end
        return ctx
    end
    if Body.char ~= char or now - Body.at > 2 then Body.measure(char, root, now) end

    ctx.char, ctx.root, ctx.humanoid, ctx.pos = char, root, humanoid, root.Position
    local mine = root:FindFirstChild("RootAttachment")
    local v = root.AssemblyLinearVelocity
    local path = yourPath(humanoid, v)

    for part, state in pairs(Balls) do
        if part.Parent == nil then
            Balls[part] = nil
        else
            state.vel = ballVelocity(part, state, now)
            updateMotion(state, state.vel, now)
            state.fake = part.Name == "Fake Ball"
            state.target = ballTarget(part)
            state.onMe = mine ~= nil and state.target == mine
            state.lag = state.practice and 0 or Dodge.reactTime()
            local rel = part.Position - ctx.pos
            local reach = ballReach(part)
            state.fly = {
                rel = rel,
                vel = state.vel,
                reach = reach,
                -- only a ball chasing you bends after you
                lag = state.onMe and state.lag or math.huge,
                -- a practice ball starts from rest, so it gets some speed in hand
                top = math.max(state.top or 0, state.vel.Magnitude, state.practice and 50 or 0),
                accel = state.accPeak or STRONG,
            }

            -- Once a ball has landed on you it has already hit. If you are still
            -- here it cannot hurt you (an orb, a shield, the practice ball,
            -- which just rides along on you), and dashing at it would only spin
            -- you round and round, so it is left alone until it has moved well
            -- off you.
            local gap = bodyGap(rel) - reach
            if gap <= 0 then
                state.touching = state.touching or now
                if now - state.touching > STUCK_AFTER then state.stuck = true end
            else
                state.touching = nil
                if state.stuck and gap > 4 then
                    state.stuck = false
                    -- riding on you it only ever copied your own moves
                    state.accEma, state.accPeak = nil, nil
                end
            end
            if state.stuck and state.onMe then ctx.stuck = (ctx.stuck or 0) + 1 end

            local _, tti = flyBall(state.fly, path, HORIZON, true)
            state.tti = tti
            if state.onMe then ctx.onMe = ctx.onMe + 1 end
            ctx.count = ctx.count + 1
            -- a new chase gets a fresh timing roll
            if state.onMe ~= state.wasOnMe then state.jitter = nil end
            state.wasOnMe = state.onMe
            local counts = (state.onMe or Dodge.Stray) and not state.stuck
                and not (state.fake and Dodge.IgnoreFake)
            if tti and counts and (not ctx.tti or tti < ctx.tti) then
                ctx.threat, ctx.tti = part, tti
            end
        end
    end
    return ctx
end

--// dash ----------------------------------------------------------------------

local SIDES = { "Left", "Right", "Forward" }
local ACTIONS = { Left = "DodgeLeft", Right = "DodgeRight", Forward = "DodgeFront" }
local DEFAULT_KEYS = { DodgeLeft = "Q", DodgeRight = "E", DodgeFront = "R" }

local readUpvalues = (typeof(getupvalues) == "function" and getupvalues)
    or (debug and typeof(debug.getupvalues) == "function" and debug.getupvalues)
    or nil

local Dash = {
    handler = nil,
    -- DashHandler's own record of when each dash was last used, once found;
    -- until then dashes are counted here
    times = nil,
    own = { Left = -math.huge, Right = -math.huge, Forward = -math.huge },
    base = { Left = 0.75, Right = 0.75, Forward = 2 },
    via = "not looked for yet",
    searchedAt = -math.huge,
}

-- your key for a dash, from the game's own Keybinds folder
function Dash.key(side)
    local action = ACTIONS[side]
    local name = DEFAULT_KEYS[action]
    local binds = LocalPlayer:FindFirstChild("Keybinds")
    local pc = binds and binds:FindFirstChild("PC")
    local value = pc and pc:FindFirstChild(action)
    if value and type(value.Value) == "string" and value.Value ~= "" then name = value.Value end
    local ok, code = pcall(function() return Enum.KeyCode[name] end)
    if ok then return code end
    return nil
end

local function sourceOf(fn)
    local ok, source = pcall(function() return debug.info(fn, "s") end)
    if ok and type(source) == "string" and source ~= "" then return source end
    local okEnv, script = pcall(function() return getfenv(fn).script end)
    if okEnv and typeof(script) == "Instance" then return script:GetFullName() end
    return ""
end

-- A {Left, Right, Forward} table of numbers inside DashHandler is either its
-- base cooldowns (0.75 / 0.75 / 2) or its record of when each dash was last
-- used (-inf until used, os.clock() after).
local function cooldownKind(t)
    if type(t) ~= "table" then return nil end
    local l, r, f = rawget(t, "Left"), rawget(t, "Right"), rawget(t, "Forward")
    if type(l) ~= "number" or type(r) ~= "number" or type(f) ~= "number" then return nil end
    if l > 0 and l <= 10 and r > 0 and r <= 10 and f > 0 and f <= 10 then return "base" end
    return "times"
end

-- the handler's only function upvalue is doDash, which holds both tables
function Dash.readCooldowns(handler)
    if not readUpvalues then return end
    local ok, ups = pcall(readUpvalues, handler)
    if not ok or type(ups) ~= "table" then return end
    for _, up in pairs(ups) do
        if type(up) == "function" then
            local okInner, inner = pcall(readUpvalues, up)
            if okInner and type(inner) == "table" then
                for _, value in pairs(inner) do
                    local kind = cooldownKind(value)
                    if kind == "times" then
                        Dash.times = value
                    elseif kind == "base" then
                        Dash.base = value
                    end
                end
            end
        end
    end
end

function Dash.find()
    Dash.searchedAt = os.clock()
    if typeof(getconnections) ~= "function" then
        Dash.via = "key press (no getconnections)"
        return false
    end
    local ok, list = pcall(getconnections, UserInputService.InputBegan)
    if not ok or type(list) ~= "table" then
        Dash.via = "key press (input connections unreadable)"
        return false
    end
    for _, connection in ipairs(list) do
        local okFn, fn = pcall(function() return connection.Function end)
        if okFn and type(fn) == "function" and sourceOf(fn):find("DashHandler", 1, true) then
            Dash.handler = fn
            Dash.times = nil
            Dash.readCooldowns(fn)
            Dash.via = Dash.times and "game dash handler" or "game dash handler (own cooldown count)"
            return true
        end
    end
    Dash.via = "key press (dash handler not found)"
    return false
end

-- the same sum as the game's ToolsSharedModule.GetDashCooldown
function Dash.cooldown(side)
    local base = Dash.base[side] or 0
    local equipped = LocalPlayer:FindFirstChild("EquippedTool")
    local accelerator = equipped and equipped:FindFirstChild("DashAccelerator")
    if accelerator and accelerator:IsA("BoolValue") and accelerator.Value == true then
        local tools = LocalPlayer:FindFirstChild("Tools")
        local owned = tools and tools:FindFirstChild("DashAccelerator")
        local level = (owned and owned:IsA("IntValue")) and owned.Value or 0
        level = math.clamp(level, 0, 3)
        return base * (1 - (0.2 + level * 0.05))
    end
    return base
end

function Dash.ready(side, char)
    -- Glitch lifts every cooldown for as long as it lasts
    if char and CollectionService:HasTag(char, "Glitch") then return true end
    local times = Dash.times or Dash.own
    local last = times[side] or -math.huge
    return os.clock() - last >= Dash.cooldown(side) + 0.02
end

function Dash.fire(side, root)
    local key = Dash.key(side)
    if not key then return false, "no key bound to " .. ACTIONS[side] end
    if not Dash.handler and os.clock() - Dash.searchedAt > 3 then Dash.find() end

    if Dash.handler then
        local before = root.AssemblyLinearVelocity
        local ok = pcall(Dash.handler, { KeyCode = key, UserInputType = Enum.UserInputType.Keyboard }, false)
        if not ok then
            -- stale handler; it gets looked for again on the next dash
            Dash.handler = nil
            return false, "dash handler errored"
        end
        -- a dash throws you sideways at 50+ studs a second at once, so a jump
        -- in velocity is how you can tell the game really dashed
        if (root.AssemblyLinearVelocity - before).Magnitude > 20 then
            Dash.own[side] = os.clock()
            return true
        end
        return false, "the game refused the dash"
    end

    local ok = pcall(function()
        local input = game:GetService("VirtualInputManager")
        input:SendKeyEvent(true, key, false, game)
        task.delay(0.05, function()
            pcall(function() input:SendKeyEvent(false, key, false, game) end)
        end)
    end)
    if not ok then return false, "no way to press the dash key" end
    Dash.own[side] = os.clock()
    return true
end

-- Without the game's own record, your own presses are counted so auto dodge
-- does not pick a dash you just used.
track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or Dash.times then return end
    local char = LocalPlayer.Character
    for _, side in ipairs(SIDES) do
        if input.KeyCode == Dash.key(side) and Dash.ready(side, char) then
            Dash.own[side] = os.clock()
        end
    end
end))

--// where to dash -------------------------------------------------------------

local PLAN_HORIZON = 0.35
local DIRECTIONS = 16

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function() rayParams.RespectCanCollide = true end)

-- characters and balls never count as walls
local function refreshRayFilter()
    local ignore = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then ignore[#ignore + 1] = plr.Character end
    end
    for folder in pairs(Watched) do ignore[#ignore + 1] = folder end
    rayParams.FilterDescendantsInstances = ignore
end

-- the dash speed the game gives you right now (DashHandler.dashHorizontalLocal)
function Dash.speed(char, humanoid)
    local upgrades = LocalPlayer:FindFirstChild("Upgrades")
    local owned = upgrades and upgrades:FindFirstChild("Dashes")
    local n = (owned and type(owned.Value) == "number") and owned.Value or 0
    n = math.min(n, 60) + math.max(n - 60, 0) * 0.5
    local airborne = humanoid ~= nil and humanoid.FloorMaterial == Enum.Material.Air
    local speed = airborne and (n + 50) or (n + 120)
    if not airborne and CollectionService:HasTag(char, "Shrunk") then speed = speed * 0.6 end
    if CollectionService:HasTag(char, "Glitch") then speed = speed * 1.5 end
    return speed
end

-- every ball worth planning around: stuck ones and ignored fakes are not
local function nearbyBalls()
    local list = {}
    for part, state in pairs(Balls) do
        if part.Parent and state.fly and not state.stuck and not (state.fake and Dodge.IgnoreFake) then
            list[#list + 1] = state.fly
        end
    end
    return list
end

-- The closest any of those balls gets to your body over the next moment if
-- you dash along dir now: you slide out and slow down, stopping short of a
-- wall, while each ball flies on and steers after you the way flyBall has it.
-- The next split second counts most; a catch further off gets another dash.
local LATER = 4

local function clearance(dir, speed, limit, balls)
    local path = function(t) return dir * math.min(slideAt(speed, t), limit) end
    local worst = math.huge
    for _, ball in ipairs(balls) do
        local closest = flyBall(ball, path, PLAN_HORIZON, false, LATER)
        if closest < worst then worst = closest end
    end
    return worst
end

local function arenaCentre()
    local map = Workspace:FindFirstChild("CurrentMap")
    local floor = map and map:FindFirstChild("Baseplate")
    if floor and floor:IsA("BasePart") then return floor.Position end
    return nil
end

-- The facing that sends a dash along dir. RightVector is LookVector crossed
-- with up, so facing (x, 0, z) puts your right at (-z, 0, x).
local function facingFor(side, dir)
    if side == "Forward" then return dir end
    if side == "Right" then return Vector3.new(dir.Z, 0, -dir.X) end
    return Vector3.new(-dir.Z, 0, dir.X)
end

-- Room from every ball comes first (past a comfortable few studs more makes
-- no difference), then having floor to land on, then a lean toward the
-- middle of the arena.
local function scoreDirection(dir, ctx, speed, balls, toCentre)
    local reach = speed * DASH_TAU + 1
    local limit = math.huge
    local wall = Workspace:Raycast(ctx.pos, dir * reach, rayParams)
    if wall then limit = math.max((wall.Position - ctx.pos).Magnitude - Body.radius, 0) end
    local s = math.min(clearance(dir, speed, limit, balls), 6)
    local land = ctx.pos + dir * math.min(reach * 0.8, limit)
    if not Workspace:Raycast(land + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), rayParams) then
        s = s - 8
    end
    if toCentre then s = s + dir:Dot(toCentre) * 0.5 end
    return s
end

-- Picks where to go and which dash takes you there.
local function planDash(ctx)
    local ready, any = {}, false
    for _, side in ipairs(SIDES) do
        if (side ~= "Forward" or Dodge.Forward) and Dash.ready(side, ctx.char) then
            ready[side] = true
            any = true
        end
    end
    if not any then return nil, "every dash is cooling down" end

    refreshRayFilter()
    local root = ctx.root
    local look = flat(root.CFrame.LookVector)
    look = look.Magnitude > 1e-3 and look.Unit or Vector3.new(0, 0, -1)
    local speed = Dash.speed(ctx.char, ctx.humanoid)
    local balls = nearbyBalls()
    local centre = arenaCentre()
    local toCentre = centre and flat(centre - ctx.pos)
    toCentre = (toCentre and toCentre.Magnitude > 8) and toCentre.Unit or nil

    if Dodge.Turn then
        -- turning first can point a dash anywhere, so every way is a candidate
        local best, bestScore
        for i = 0, DIRECTIONS - 1 do
            local angle = i / DIRECTIONS * math.pi * 2
            local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
            local s = scoreDirection(dir, ctx, speed, balls, toCentre)
            if not bestScore or s > bestScore then best, bestScore = dir, s end
        end
        -- the side dashes cool down fastest, so forward only goes when both
        -- are out; of the two, the one needing the smaller turn
        local choice, facing
        for _, side in ipairs({ "Left", "Right" }) do
            if ready[side] then
                local f = facingFor(side, best)
                if not facing or f:Dot(look) > facing:Dot(look) then choice, facing = side, f end
            end
        end
        if not choice then choice, facing = "Forward", best end
        return { side = choice, facing = facing, dir = best, score = bestScore }
    end

    local cf = root.CFrame
    local dirs = {
        Left = flat(-cf.RightVector),
        Right = flat(cf.RightVector),
        Forward = look,
    }
    local choice, bestScore
    for _, side in ipairs(SIDES) do
        if ready[side] and dirs[side].Magnitude > 1e-3 then
            local s = scoreDirection(dirs[side].Unit, ctx, speed, balls, toCentre)
            if not bestScore or s > bestScore then choice, bestScore = side, s end
        end
    end
    if not choice then return nil, "no ready dash goes anywhere useful" end
    return { side = choice, dir = dirs[choice].Unit, score = bestScore }
end

--// dodge ---------------------------------------------------------------------

-- Auto dodge keeps its hands off whenever the game's own dash would refuse,
-- and whenever turning you round could fling a limp body about.
local BLOCKING_TAGS = { Downed = "downed", HumanShield = "held as a shield", FreezeTagFrozen = "frozen" }

local LIMP_STATES = {}
for _, name in ipairs({ "Dead", "Physics", "Ragdoll", "Seated", "PlatformStanding", "FallingDown", "GettingUp" }) do
    local ok, item = pcall(function() return Enum.HumanoidStateType[name] end)
    if ok and item then LIMP_STATES[item] = true end
end

local function dashBlocked(ctx)
    local char = ctx.char
    for tag, why in pairs(BLOCKING_TAGS) do
        if CollectionService:HasTag(char, tag) then return why end
    end
    -- DashHandler only dashes in a round or in the lobby
    if not CollectionService:HasTag(char, "Playing") and not CollectionService:HasTag(char, "Lobby") then
        return "not in a round"
    end
    if char:GetAttribute("Ragdolled") == true or ctx.root.Anchored then return "ragdolled" end
    local ok, state = pcall(function() return ctx.humanoid:GetState() end)
    if ok and LIMP_STATES[state] then return "knocked over" end
    return nil
end

-- A chasing ball steers at where the server last saw you, and you see it a
-- little late on top of that: about one round trip passes before anything you
-- do can bend its path on your screen.
function Dodge.reactTime()
    return math.clamp(Dodge.ping + 0.05, 0.1, 0.4)
end

-- How long a dash takes to carry you clear of a ball: past its reach and your
-- own width, with a little to spare. Any earlier than that only gives a
-- chasing ball longer to turn after you, so auto timing dashes right then;
-- a slow dash (in the air, shrunk) has to go earlier to get as far.
function Dodge.clearTime(reach, speed)
    local need = reach + Body.radius + 0.5
    local full = speed * DASH_TAU
    if need >= full * 0.95 then return 0.3 end
    return -DASH_TAU * math.log(1 - need / full)
end

-- When to dash, as time before impact. If the ball cannot react before you
-- are clear, as late as that allows. If it can (a practice ball reacts at
-- once), the moment that leaves the most room once its bending after you is
-- counted: earlier gives it longer to bend, later gives your dash less time.
function Dodge.lead(state, reach, speed)
    local clear = Dodge.clearTime(reach, speed)
    local lag = state.lag or 0
    if lag >= clear + 0.04 then return clear + 0.04 end
    local accel = state.accPeak or STRONG
    local best, bestRoom = clear, -math.huge
    for i = 2, 30 do
        local lead = i / 100
        local bend = math.max(lead - lag, 0)
        local room = slideAt(speed, lead) - 0.5 * accel * bend * bend
        if room > bestRoom + 0.05 then best, bestRoom = lead, room end
    end
    return best
end

function Dodge.window(ctx)
    if Dodge.AutoTiming and ctx and ctx.threat then
        return Dodge.lead(Balls[ctx.threat], ballReach(ctx.threat), Dash.speed(ctx.char, ctx.humanoid))
    end
    return Dodge.At / 1000
end

local function dodge(ctx, now, dt)
    if not ctx.char then
        Dodge.status = "no character"
        return
    end
    if not ctx.threat then
        if ctx.stuck then
            Dodge.status = "a ball is on you, waiting for it to move off"
        elseif ctx.count > 0 then
            Dodge.status = ("watching %d ball%s"):format(ctx.count, ctx.count == 1 and "" or "s")
        else
            Dodge.status = "no balls"
        end
        return
    end

    local state = Balls[ctx.threat]
    local blocked = dashBlocked(ctx)
    Dodge.status = ("%s · %.2fs"):format(state.onMe and "ball on you" or "stray ball", ctx.tti)
    if blocked then
        Dodge.status = Dodge.status .. " · can't dash (" .. blocked .. ")"
        return
    end
    if not state.jitter then
        state.jitter = (math.random() * 2 - 1) * Dodge.Jitter / 1000
    end
    local window = math.max(Dodge.window(ctx) + state.jitter, 0.03) + dt
    Dodge.lastWindow = window
    if ctx.tti > window then return end
    -- one dash has to land before the next is judged
    if now < Dodge.holdUntil then return end

    -- with every dash cooling down this comes straight back, so it is asked
    -- again each frame and a dash is used the moment one is ready
    local plan, why = planDash(ctx)
    if not plan then
        Dodge.status = why
        return
    end
    local root = ctx.root
    local facingBefore = root.CFrame
    if plan.facing then
        local pos = root.Position
        root.CFrame = CFrame.lookAt(pos, pos + plan.facing)
    end
    local ok, err = Dash.fire(plan.side, root)
    if not ok then
        -- no dash went out, so the turn is undone, and each refusal in a row
        -- waits twice as long before the next try
        if plan.facing then root.CFrame = facingBefore end
        Dodge.refusals = Dodge.refusals + 1
        Dodge.holdUntil = now + math.min(0.05 * 2 ^ Dodge.refusals, 1)
        Dodge.status = err or "dash failed"
        return
    end
    Dodge.refusals = 0
    Dodge.holdUntil = now + 0.08
    Dodge.dashes = Dodge.dashes + 1
    state.jitter = nil
    Dodge.action = ("dashed %s %d ms before impact"):format(plan.side:lower(), math.floor(ctx.tti * 1000 + 0.5))
end

--// anti blind ------------------------------------------------------------------

-- A blind (the darkness staff) takes every Atmosphere out of Lighting, drops in
-- a thick BlindedAtmosphere and covers the screen with GameUI.BlindedFrame, all
-- on your own client. Undoing it is putting those three back.
local Atmospheres = {}

function Blind.remember(inst)
    if not inst:IsA("Atmosphere") or inst.Name == "BlindedAtmosphere" then return end
    for _, known in ipairs(Atmospheres) do
        if known == inst then return end
    end
    Atmospheres[#Atmospheres + 1] = inst
end

function Blind.clear()
    for _, child in ipairs(Lighting:GetChildren()) do
        if child.Name == "BlindedAtmosphere" and child:IsA("Atmosphere") then
            pcall(function() child:Destroy() end)
        end
    end
    for _, atmosphere in ipairs(Atmospheres) do
        if atmosphere.Parent == nil then
            pcall(function() atmosphere.Parent = Lighting end)
        end
    end
    local frame = Blind.frame
    if frame and frame.Visible then frame.Visible = false end
end

function Blind.hook()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local gameUi = gui and gui:FindFirstChild("GameUI")
    local frame = gameUi and gameUi:FindFirstChild("BlindedFrame")
    if not frame or frame == Blind.frame then return end
    Blind.frame = frame
    track(frame:GetPropertyChangedSignal("Visible"):Connect(function()
        if not Blind.Enabled or not frame.Visible then return end
        frame.Visible = false
        -- the game fills in who did it right after showing the frame
        task.defer(function()
            Blind.blocked = Blind.blocked + 1
            if Blind.ui then Blind.ui.Set(Blind.blocked) end
            if not Blind.Notify then return end
            local label = frame:FindFirstChild("TextLabel")
            local by = label and tostring(label.Text):match("Blinded By (.+)!")
            notify('anti blind', by and ('blocked a blind from ' .. by) or 'blocked a blind', 'success', 3)
        end)
    end))
end

for _, child in ipairs(Lighting:GetChildren()) do Blind.remember(child) end

track(Lighting.ChildAdded:Connect(function(child)
    if child.Name == "BlindedAtmosphere" then
        if Blind.Enabled then task.defer(Blind.clear) end
    else
        Blind.remember(child)
    end
end))

--// esp -------------------------------------------------------------------------

local COLORS = {
    you = Color3.fromRGB(255, 70, 70),
    danger = Color3.fromRGB(255, 170, 60),
    fake = Color3.fromRGB(175, 120, 255),
    other = Color3.fromRGB(235, 235, 235),
}

local EspObjects = {}

local function newLine()
    if not HasDrawing then return nil end
    local ok, line = pcall(function() return Drawing.new("Line") end)
    if not ok or not line then return nil end
    line.Thickness = 1.5
    line.Transparency = 1
    line.Visible = false
    return line
end

function Esp.make(part)
    local gui = Instance.new("BillboardGui")
    gui.Name = "ball"
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.ResetOnSpawn = false
    gui.Size = UDim2.fromOffset(180, 34)
    gui.StudsOffsetWorldSpace = Vector3.new(0, ballReach(part) + 2, 0)
    gui.Adornee = part

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextStrokeTransparency = 0.35
    label.TextColor3 = COLORS.other
    label.Text = ""
    label.Parent = gui
    gui.Parent = GuiRoot

    local obj = { gui = gui, label = label, line = newLine() }
    EspObjects[part] = obj
    return obj
end

function Esp.drop(part)
    local obj = EspObjects[part]
    if not obj then return end
    EspObjects[part] = nil
    pcall(function() obj.gui:Destroy() end)
    if obj.line then pcall(function() obj.line:Remove() end) end
end

function Esp.targetName(attachment)
    local root = attachment and attachment.Parent
    local model = root and root.Parent
    if not model then return "no target" end
    if model == LocalPlayer.Character then return "YOU" end
    local plr = Players:GetPlayerFromCharacter(model)
    if plr then return plr.DisplayName end
    -- a decoy or anything else the game points a ball at
    return model.Name
end

function Esp.paint(part, state, obj, from)
    local color = COLORS.other
    if state.fake then
        color = COLORS.fake
    elseif state.onMe then
        color = COLORS.you
    elseif state.tti then
        color = COLORS.danger
    end

    local text = state.fake and "fake ball" or Esp.targetName(state.target)
    if Esp.Info then
        local dist = from and (part.Position - from).Magnitude or 0
        local speed = state.vel and state.vel.Magnitude or 0
        text = ("%s\n%d st · %d st/s"):format(text, math.floor(dist + 0.5), math.floor(speed + 0.5))
        if state.stuck then
            text = text .. " · stuck"
        elseif state.tti and state.tti < 3 then
            text = text .. (" · %.2fs"):format(state.tti)
        end
    end
    obj.label.Text = text
    obj.label.TextColor3 = color

    local line = obj.line
    if not line then return end
    local target = state.target and state.target.Parent
    local cam = Camera
    if Esp.Lines and cam and not state.fake and target and target:IsA("BasePart") then
        local a = cam:WorldToViewportPoint(part.Position)
        local b = cam:WorldToViewportPoint(target.Position)
        if a.Z > 0 and b.Z > 0 then
            line.From = Vector2.new(a.X, a.Y)
            line.To = Vector2.new(b.X, b.Y)
            line.Color = color
            line.Visible = true
            return
        end
    end
    line.Visible = false
end

local WarningGui = Instance.new("ScreenGui")
WarningGui.Name = "warning"
WarningGui.IgnoreGuiInset = true
WarningGui.ResetOnSpawn = false
WarningGui.DisplayOrder = 50

local WarningLabel = Instance.new("TextLabel")
WarningLabel.AnchorPoint = Vector2.new(0.5, 0)
WarningLabel.Position = UDim2.new(0.5, 0, 0.16, 0)
WarningLabel.Size = UDim2.fromOffset(340, 30)
WarningLabel.BackgroundTransparency = 1
WarningLabel.Font = Enum.Font.GothamBlack
WarningLabel.TextSize = 22
WarningLabel.TextStrokeTransparency = 0.3
WarningLabel.TextColor3 = COLORS.you
WarningLabel.Text = ""
WarningLabel.Visible = false
WarningLabel.Parent = WarningGui
WarningGui.Parent = GuiRoot

--// staff -------------------------------------------------------------------------

-- Who the game's admin panel lets in, copied from its AdminConfig module for
-- when the live one cannot be read: two user ids at full access, and ranks in
-- the game's group (150 and up is level 1, 230 level 2, 245 level 3).
local ADMIN_FALLBACK = {
    UserIds = { [3] = { 2282826523, 10976195300 } },
    Groups = {
        { GroupId = 803410087, MinRank = 245, Level = 3 },
        { GroupId = 803410087, MinRank = 230, Level = 2 },
        { GroupId = 803410087, MinRank = 150, Level = 1 },
    },
}

function Staff.config()
    if Staff.cfg then return Staff.cfg end
    local ok, cfg = pcall(function()
        local panel = ReplicatedStorage:WaitForChild("AdminPanel", 5)
        local module = panel and panel:WaitForChild("AdminConfig", 5)
        return module and require(module)
    end)
    if ok and type(cfg) == "table" and (type(cfg.UserIds) == "table" or type(cfg.Groups) == "table") then
        Staff.cfg, Staff.source = cfg, "the game's admin config"
    else
        Staff.cfg, Staff.source = ADMIN_FALLBACK, "built-in copy"
    end
    return Staff.cfg
end

-- the highest admin level a player has, and what to call them
function Staff.level(plr)
    local cfg = Staff.config()
    local level, role = 0, nil
    if type(cfg.UserIds) == "table" then
        for lvl, ids in pairs(cfg.UserIds) do
            if type(lvl) == "number" and type(ids) == "table" then
                for _, id in ipairs(ids) do
                    if id == plr.UserId and id > 0 and lvl > level then
                        level, role = lvl, "listed admin"
                    end
                end
            end
        end
    end
    if type(cfg.Groups) == "table" then
        for _, entry in ipairs(cfg.Groups) do
            local lvl = type(entry) == "table" and tonumber(entry.Level) or nil
            if lvl and lvl > level and entry.GroupId and entry.MinRank then
                local ok, rank = pcall(plr.GetRankInGroup, plr, entry.GroupId)
                if ok and type(rank) == "number" and rank >= entry.MinRank then
                    local okRole, name = pcall(plr.GetRoleInGroup, plr, entry.GroupId)
                    level = lvl
                    role = (okRole and type(name) == "string" and name ~= "") and name or ("rank " .. rank)
                end
            end
        end
    end
    if cfg.CreatorIsOwner and game.CreatorType == Enum.CreatorType.User and plr.UserId == game.CreatorId then
        level, role = 3, "game owner"
    end
    return level, role
end

function Staff.describe(plr, info)
    return ("%s (@%s) · %s · admin level %d"):format(plr.DisplayName, plr.Name, info.role or "staff", info.level)
end

function Staff.refresh()
    if not Staff.ui then return end
    local names = {}
    for plr in pairs(Staff.here) do names[#names + 1] = plr.Name end
    table.sort(names)
    if #names > 0 then
        Staff.ui.here.Set(table.concat(names, ", "), Color3.fromRGB(255, 170, 60))
    else
        Staff.ui.here.Set("none", Color3.fromRGB(126, 217, 87))
    end
    Staff.ui.source.Set(Staff.source or "-")
end

function Staff.check(plr, joined)
    if plr == LocalPlayer then return end
    task.spawn(function()
        local level, role = Staff.level(plr)
        if Unloaded or level <= 0 or plr.Parent ~= Players then return end
        local info = { level = level, role = role }
        Staff.here[plr] = info
        Staff.refresh()
        if Staff.Enabled then
            notify(joined and 'staff joined' or 'staff in this server', Staff.describe(plr, info), 'warning', 12)
        end
    end)
end

function Staff.scanAll()
    task.spawn(function()
        -- the config read can wait on AdminPanel for a few seconds
        Staff.config()
        table.clear(Staff.here)
        Staff.refresh()
        for _, plr in ipairs(Players:GetPlayers()) do Staff.check(plr, false) end
    end)
end

track(Players.PlayerAdded:Connect(function(plr) Staff.check(plr, true) end))

track(Players.PlayerRemoving:Connect(function(plr)
    local info = Staff.here[plr]
    if not info then return end
    Staff.here[plr] = nil
    Staff.refresh()
    if Staff.Enabled and Staff.Leaves then
        notify('staff left', Staff.describe(plr, info), 'info', 6)
    end
end))

--// loops -------------------------------------------------------------------------

local lastStep = os.clock()
local nextChores = 0
local lastError

track(PreSimulation:Connect(function()
    local now = os.clock()
    local dt = math.min(now - lastStep, 0.1)
    lastStep = now
    if Unloaded then return end

    if now >= nextChores then
        nextChores = now + 2
        findBallFolders()
        Blind.hook()
    end

    if not (Dodge.Enabled or Esp.Enabled) then return end
    local ok, err = pcall(function()
        local ctx = scan(now)
        if Dodge.Enabled then dodge(ctx, now, dt) end
    end)
    if not ok and err ~= lastError then
        lastError = err
        warn('[dodge or die] ' .. tostring(err))
    end
end))

local nextReadout = 0

track(PreRender:Connect(function()
    if Unloaded then return end
    local now = os.clock()
    local _, root = myCharacter()
    local from = (root and root.Position) or (Camera and Camera.CFrame.Position)

    local onMe, soonest = 0, nil
    for part, state in pairs(Balls) do
        if part.Parent and state.vel then
            if state.onMe and not state.stuck then
                onMe = onMe + 1
                if state.tti and (not soonest or state.tti < soonest) then soonest = state.tti end
            end
            if Esp.Enabled then
                Esp.paint(part, state, EspObjects[part] or Esp.make(part), from)
            end
        end
    end
    for part in pairs(EspObjects) do
        if not Esp.Enabled or not Balls[part] or part.Parent == nil then Esp.drop(part) end
    end

    if Esp.Enabled and Esp.Warning and onMe > 0 then
        local head = onMe > 1 and (onMe .. " BALLS ON YOU") or "BALL ON YOU"
        WarningLabel.Text = soonest and ("%s · %.2fs"):format(head, soonest) or head
        WarningLabel.Visible = true
    else
        WarningLabel.Visible = false
    end

    if now >= nextReadout then
        nextReadout = now + 0.25
        if now - Dodge.pingAt > 0.5 then
            Dodge.pingAt = now
            Dodge.ping = roundTrip()
        end
        if Dodge.ui then
            Dodge.ui.status.Set(Dodge.Enabled and Dodge.status or "off")
            Dodge.ui.last.Set(Dodge.action or "-")
            if Dodge.AutoTiming then
                Dodge.ui.timing.Set(Dodge.lastWindow and ("auto, last %d ms before impact"):format(
                    math.floor(Dodge.lastWindow * 1000 + 0.5)) or "auto")
            else
                Dodge.ui.timing.Set(("%d ms before impact"):format(math.floor(Dodge.At + 0.5)))
            end
            Dodge.ui.via.Set(Dash.via)
            Dodge.ui.count.Set(Dodge.dashes)
        end
    end
end))

local function unload()
    if Unloaded then return end
    Unloaded = true
    Dodge.Enabled = false
    Esp.Enabled = false
    for _, connection in ipairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    for part in pairs(EspObjects) do Esp.drop(part) end
    pcall(function() WarningGui:Destroy() end)
end

--// ui ----------------------------------------------------------------------------

local Window = Onyx:CreateWindow({
    Title = 'dodge or die',
    SubTitle = 'assist',
    Folder = 'DodgeOrDie',
    Keybind = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 120, 40),
})

-- closing the menu from its own settings tears the script down too
Onyx.OnUnload = unload

do
    local DodgeTab = Window:CreateTab({ Title = 'dodge', Default = true })
    local section = DodgeTab:CreateSection('auto dodge')

    section:Toggle({
        Title = 'auto dodge',
        Description = 'dashes out of the way of a ball about to hit you, through your own dash, so the cooldowns and animation are the real ones',
        Flag = 'dod_dodge',
        Default = false,
        Callback = function(state) Dodge.Enabled = state end,
    })

    section:Toggle({
        Title = 'turn to dash',
        Description = 'turns you first so the dash can go whichever way keeps you furthest from every ball, with walls and the arena edge counted. off only chooses between the ways your dashes already point',
        Flag = 'dod_turn',
        Default = true,
        Callback = function(state) Dodge.Turn = state end,
    })

    section:Toggle({
        Title = 'use forward dash',
        Description = 'spends the forward dash (2s cooldown) when both side dashes are cooling down',
        Flag = 'dod_forward',
        Default = true,
        Callback = function(state) Dodge.Forward = state end,
    })

    section:Toggle({
        Title = 'stray balls',
        Description = 'also dodges a ball chasing someone else when it is about to go through you',
        Flag = 'dod_stray',
        Default = true,
        Callback = function(state) Dodge.Stray = state end,
    })

    section:Toggle({
        Title = 'ignore fake balls',
        Description = 'a fake ball is a decoy another player spawned, so no dash is spent on one',
        Flag = 'dod_ignore_fake',
        Default = true,
        Callback = function(state) Dodge.IgnoreFake = state end,
    })

    section = DodgeTab:CreateSection('timing')

    section:Toggle({
        Title = 'auto timing',
        Description = 'dashes as late as your dash can still carry you clear, which leaves a chasing ball the least time to turn after you. works out your dash speed and the ball size each time',
        Flag = 'dod_auto_timing',
        Default = true,
        Callback = function(state) Dodge.AutoTiming = state end,
    })

    section:Slider({
        Title = 'dodge at',
        Description = 'how long before impact the dash goes out when auto timing is off',
        Min = 60,
        Max = 400,
        Increment = 10,
        Suffix = ' ms',
        Default = Dodge.At,
        Flag = 'dod_at',
        Callback = function(value) Dodge.At = tonumber(value) or Dodge.At end,
    })

    section:Dropdown({
        Title = 'timing variance',
        Description = 'each dodge lands randomly up to this far either side, so it is not frame perfect every time',
        Values = { 'none', '10 ms', '20 ms', '40 ms' },
        Default = '20 ms',
        Flag = 'dod_jitter',
        Callback = function(value) Dodge.Jitter = JITTER[value] or Dodge.Jitter end,
    })

    section = DodgeTab:CreateSection('readout')

    Dodge.ui = {
        status = addStat(section, { Title = 'status', Value = 'off' }),
        last = addStat(section, { Title = 'last dodge', Value = '-' }),
        timing = addStat(section, { Title = 'dashing', Value = '-' }),
        via = addStat(section, { Title = 'dash through', Value = Dash.via }),
        count = addStat(section, { Title = 'dashes', Value = 0 }),
    }

    section:Label({
        Title = 'The practice area in the lobby spawns balls that chase you the same way as a round, so it is a safe place to try this out.',
    })
end

do
    local VisualTab = Window:CreateTab({ Title = 'visual' })
    local section = VisualTab:CreateSection('ball esp')

    section:Toggle({
        Title = 'ball esp',
        Description = 'labels every ball with who it is chasing. red is after you, orange is about to go through you, purple is a fake',
        Flag = 'dod_esp',
        Default = false,
        Callback = function(state) Esp.Enabled = state end,
    })

    section:Toggle({
        Title = 'distance, speed and time',
        Description = 'adds how far away each ball is, how fast it is going and how long until it reaches you',
        Flag = 'dod_esp_info',
        Default = true,
        Callback = function(state) Esp.Info = state end,
    })

    section:Toggle({
        Title = 'lines to target',
        Description = HasDrawing and 'draws a line from each ball to whoever it is chasing'
            or 'draws a line from each ball to whoever it is chasing (needs Drawing, which this executor does not have)',
        Flag = 'dod_esp_lines',
        Default = true,
        Callback = function(state) Esp.Lines = state end,
    })

    section:Toggle({
        Title = 'on-you warning',
        Description = 'big warning at the top of the screen while a ball is chasing you, with the time until it arrives',
        Flag = 'dod_esp_warning',
        Default = true,
        Callback = function(state) Esp.Warning = state end,
    })

    section = VisualTab:CreateSection('anti blind')

    section:Toggle({
        Title = 'anti blind',
        Description = 'undoes the darkness staff blind the moment it lands. the blind only ever happens on your own screen',
        Flag = 'dod_anti_blind',
        Default = true,
        Callback = function(state)
            Blind.Enabled = state
            if state then Blind.clear() end
        end,
    })

    section:Toggle({
        Title = 'notify when blocked',
        Description = 'says who tried to blind you',
        Flag = 'dod_blind_notify',
        Default = true,
        Callback = function(state) Blind.Notify = state end,
    })

    Blind.ui = addStat(section, { Title = 'blinds blocked', Value = 0 })
end

do
    local StaffTab = Window:CreateTab({ Title = 'staff' })
    local section = StaffTab:CreateSection('staff alert')

    section:Toggle({
        Title = 'staff alert',
        Description = 'notifies you when anyone who can open the game\'s admin panel is in or joins the server',
        Flag = 'dod_staff',
        Default = true,
        Callback = function(state) Staff.Enabled = state end,
    })

    section:Toggle({
        Title = 'notify when they leave',
        Flag = 'dod_staff_leave',
        Default = true,
        Callback = function(state) Staff.Leaves = state end,
    })

    Staff.ui = {
        here = addStat(section, { Title = 'staff here', Value = 'checking...' }),
        source = addStat(section, { Title = 'staff list from', Value = '-' }),
    }

    section:Button({
        Title = 'check again',
        Callback = function() Staff.scanAll() end,
    })

    section:Label({
        Title = 'Staff means the admin panel\'s own list: two user ids with full access, and rank 150 or higher in the game\'s group.',
    })
end

do
    local SessionTab = Window:CreateTab({ Title = 'session' })
    local section = SessionTab:CreateSection('session')

    section:Button({
        Title = 'unload',
        Callback = function()
            unload()
            Onyx:Unload()
        end,
    })

    section:Paragraph({
        Title = 'unload',
        Text = 'Stops auto dodge, clears the esp and the warning, and disconnects everything before closing the menu.',
    })
end

--// start ---------------------------------------------------------------------------

findBallFolders()
Blind.hook()
Dash.find()
Staff.scanAll()

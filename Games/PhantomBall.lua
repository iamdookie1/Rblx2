--// Phantom Ball -- auto parry, auto clash + spam, ball aim, visuals.
--
-- Built against a script dump of the live game (place 12979690461, game
-- 4538598064, version 6785). What the game's own scripts show:
--  * The ball is the server's. Clients get snapshots (BallSnapshot) that
--    ReplicatedStorage.TS.BallReplicator.BallReplicator keeps in .history,
--    with the server time, position, direction, speed, acceleration (7/s),
--    max speed (600), curve, grace and the target's UserId, and it replays
--    them with the server's own movement (SimulateFrom / SampleHistory).
--  * A parry is DeflectAbility:Deflect(): it fires _G.did2 (the per player
--    "pu_<UserId>" remote, renamed to "") with a 25 byte buffer: a byte that
--    says the clicks are under Workspace.CPS_LIMIT (25 a second), then the
--    camera position and look direction.
--  * The server then opens a parry window: 850ms at base speed (16) down to
--    200ms at max speed (600); in a clash at least 220-320ms. The ball is
--    parried if it comes within your DeflectRange (8.5, up to 16 with
--    Resilience) while the window is open, or during the grace it gives once
--    the ball reaches you (ping * 2 - 50ms, at most 350ms). A press while the
--    ball is more than 30% of the window away is flagged as early. The block
--    cooldown is 1.45s (0.6s down to 0.38s in a clash), reset by a parry.
--  * A clash is two players within 35 studs with a parry in the last second
--    (Workspace LastParryAt / LastParryBy / LastParryTarget).
--  * Where the ball goes next: the alive player whose root is closest to the
--    look direction of your camera, as the server last heard it. The camera
--    is sent by CameraSync through Network:CSendEvent(2.4544348798342524E+76,
--    cframe, move) about 30 times a second and kept as the CamCFrame
--    attribute. The server only checks the position (within 64 studs of
--    you), never the direction, so aiming is the camera sync with the look
--    turned to the chosen player.
--  * Remotes.ReqDef, ":)", "__" and the numbered ones are never used by the
--    client: likely traps, so this never touches them.
--
-- Auto parry: every frame the ball is played forward to the moment the
-- server would get a press (now + your ping) with the server's own replay,
-- and the time it needs to reach your range is worked out the way the server
-- works out "early" (speed and acceleration). It presses inside the safe part
-- of the window, so the server never flags it and the cooldown is never spent
-- on a miss.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__PhantomBallStop) == "function" then pcall(Genv.__PhantomBallStop) end

--// lifecycle ---------------------------------------------------------------

local Connections = {}
local Unloaded = false
local Restore = {} -- functions that undo a hook

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

--// settings ----------------------------------------------------------------

local Parry = {
    Enabled = false,
    Timing = 0.25,        -- press once the ball is this share of the window away (the server flags past 0.3)
    PingComp = true,      -- play the ball forward by your ping
    PingScale = 1,
    Clash = true,         -- in a clash, press as soon as the ball is yours
    Spam = false,         -- held / toggled by its key
    SpamCps = 15,
    Method = "Game",      -- Game: the game's own Deflect / Direct: fire the parry remote
}

local Aim = {
    Enabled = false,
    Mode = "Farthest",    -- Farthest / Closest / Random / Player
    Player = nil,         -- the name, for Player mode
    Packet = true,        -- also turn the camera inside the parry packet
}

local Visual = {
    Ball = true,
    BallColor = Color3.fromRGB(255, 255, 255),
    MineColor = Color3.fromRGB(255, 70, 70),
    Path = true,
    PathColor = Color3.fromRGB(120, 200, 255),
    Tracer = true,
    TracerColor = Color3.fromRGB(255, 200, 80),
    Hud = true,
    Range = true,
    RangeColor = Color3.fromRGB(120, 255, 160),
    Ranges = false,       -- everyone's parry range above their head
}

local Stats = { Presses = 0, Parries = 0, Misses = 0, Status = "loading", LastEta = nil, LastWindow = nil }

local Library -- the Ui3 menu, loaded last

--// the game's modules ------------------------------------------------------

local CAM_SYNC = 2.4544348798342524E+76
local Game = {} -- BR, GameBall, Network, DeflectClass, GameInfo, Deflect (the live ability)

local function req(...)
    local node = ReplicatedStorage
    for _, name in ipairs({ ... }) do
        node = node and node:WaitForChild(name, 15)
    end
    if not node then return nil end
    local ok, result = pcall(require, node)
    return ok and result or nil
end

local function myRoot()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return root, hum, char
end

local function rootOf(player)
    local char = player and player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function alive(player)
    local lives = player:GetAttribute("Lives")
    return type(lives) == "number" and lives > 0
end

local function ballPart()
    local info = Game.GameInfo
    local ball = info and info.BallModel
    if typeof(ball) == "Instance" and ball.Parent then return ball end
    return Workspace:FindFirstChild("GameBall")
end

--// where the ball really is ------------------------------------------------

local function ping()
    local ok, value = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
    return ok and type(value) == "number" and math.clamp(value, 0, 0.5) or 0.05
end

-- The ball at the moment the server would get a press sent now: the latest
-- snapshot replayed forward with the game's own movement.
local function ballState()
    local br = Game.BR
    if not br or not br.hasState then return nil end
    local history = br.history
    if type(history) ~= "table" or #history == 0 then return nil end
    local now = Workspace:GetServerTimeNow()
    local lead = Parry.PingComp and ping() * Parry.PingScale or 0
    local at = now + lead
    local a, b = history[1], history[2]
    for i = #history, 1, -1 do
        if at >= history[i].serverTime then
            a, b = history[i], history[i + 1]
            break
        end
    end
    local ok, pos = pcall(br.SampleHistory, br, a, b, at)
    if not ok or typeof(pos) ~= "Vector3" then
        local ball = ballPart()
        pos = ball and ball.Position
    end
    if not pos then return nil end
    local last = history[#history]
    local accel = tonumber(last.accel) or 0
    local top = math.max(tonumber(last.maxSpeed) or 0, tonumber(last.speed) or 0)
    local speed = math.min((tonumber(last.speed) or 0) + accel * math.max(at - last.serverTime, 0), top)
    return {
        Pos = pos, Speed = speed, Accel = accel, Target = last.targetId,
        Grace = last.grace == true, Locked = last.locked == true, Snap = last, Lead = lead,
    }
end

-- seconds for the ball to cover `gap`, the way the server judges "early"
local function eta(gap, speed, accel)
    if gap <= 0 then return 0 end
    if accel > 1e-4 then return (-speed + math.sqrt(speed * speed + 2 * accel * gap)) / accel end
    if speed > 1e-4 then return gap / speed end
    return math.huge
end

local function inClash()
    local gb = Game.GameBall
    if not gb then return false end
    local ok, result = pcall(gb.IsInClash, gb, LocalPlayer)
    return ok and result == true
end

-- the server's parry window for this speed
local function window(speed, clash)
    local t = math.clamp((speed - 16) / (600 - 16), 0, 1)
    local w = 0.85 + (0.2 - 0.85) * t
    if clash then
        w = math.max(w, 0.22 + 0.1 * math.clamp((speed - 16) / 250, 0, 1))
    end
    return w
end

local function myRange()
    local range = LocalPlayer:GetAttribute("DeflectRange")
    return type(range) == "number" and range or 8.5
end

--// pressing ----------------------------------------------------------------

local AimTarget = nil -- the player the ball is being sent to (ball aim, below)
local aimCFrame       -- the camera the server is told about (ball aim, below)

local OwnCooldown = 0 -- when the Deflect ability can't be found

local function deflect()
    local d = Game.Deflect
    if d and os.clock() - (Game.DeflectSeen or 0) < 1 then return d end
    return nil
end

local function ready()
    local d = deflect()
    if d then return (tonumber(d.Cooldown) or 0) <= 0 end
    return os.clock() >= OwnCooldown
end

local function parryRemote()
    local ok, renv = pcall(function() return getrenv and getrenv() end)
    local g = ok and type(renv) == "table" and rawget(renv, "_G")
    local remote = type(g) == "table" and rawget(g, "did2")
    if typeof(remote) == "Instance" then return remote end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    return remotes and (remotes:FindFirstChild("pu_" .. LocalPlayer.UserId) or remotes:FindFirstChild(""))
end

local function typing()
    local focused = UserInputService:GetFocusedTextBox()
    return focused ~= nil
end

local function press()
    if typing() then return false end
    Stats.Presses += 1
    local d = deflect()
    if Parry.Method == "Game" and d then
        local ok = pcall(d.Deflect, d)
        if ok then return true end
    end
    -- the same packet the game sends
    local remote = parryRemote()
    if not remote then return false end
    local cam = Workspace.CurrentCamera
    local cf = cam and cam.CFrame or CFrame.identity
    if Aim.Enabled and Aim.Packet and AimTarget then cf = aimCFrame(cf) end
    local packet = buffer.create(25)
    buffer.writeu8(packet, 0, 1)
    buffer.writef32(packet, 1, cf.Position.X)
    buffer.writef32(packet, 5, cf.Position.Y)
    buffer.writef32(packet, 9, cf.Position.Z)
    buffer.writef32(packet, 13, cf.LookVector.X)
    buffer.writef32(packet, 17, cf.LookVector.Y)
    buffer.writef32(packet, 21, cf.LookVector.Z)
    local ok = pcall(remote.FireServer, remote, packet)
    if ok and not d then OwnCooldown = os.clock() + (inClash() and 0.6 or 1.45) end
    return ok
end

--// ball aim ----------------------------------------------------------------

local RandomPick = nil

local function sameTeam(player)
    local mine = LocalPlayer:GetAttribute("PlayerTeam")
    if mine == nil or mine == "" then return false end
    return player:GetAttribute("PlayerTeam") == mine
end

local function candidates()
    local list = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and alive(player) and player:GetAttribute("IsCloaked") ~= true and not sameTeam(player) then
            local root = rootOf(player)
            local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
            if root and hum and hum.Health > 0 then list[#list + 1] = { Player = player, Root = root } end
        end
    end
    return list
end

-- Random re-rolls after every parry (RandomPick is cleared then)
local function chooseTarget()
    local me = myRoot()
    local list = candidates()
    if not me or #list == 0 then return nil end
    -- a dark sealed player always gets it, whatever the camera says
    for _, c in ipairs(list) do
        if c.Player:GetAttribute("DarkSealed") == true then return c.Player end
    end
    if Aim.Mode == "Player" then
        for _, c in ipairs(list) do
            if c.Player.Name == Aim.Player then return c.Player end
        end
    elseif Aim.Mode == "Random" then
        for _, c in ipairs(list) do
            if c.Player == RandomPick then return RandomPick end
        end
        RandomPick = list[math.random(1, #list)].Player
        return RandomPick
    end
    local best, bestScore = nil, nil
    for _, c in ipairs(list) do
        local d = (c.Root.Position - me.Position).Magnitude
        local score = Aim.Mode == "Closest" and -d or d
        if not bestScore or score > bestScore then best, bestScore = c.Player, score end
    end
    return best
end

-- the camera the server is told about: your own, looking at the target
function aimCFrame(real)
    local me = myRoot()
    local target = AimTarget and rootOf(AimTarget)
    if not Aim.Enabled or not me or not target then return real end
    local pos = typeof(real) == "CFrame" and real.Position or me.Position
    -- the server ignores a camera more than 64 studs from you
    if (pos - me.Position).Magnitude > 60 then pos = me.Position + Vector3.new(0, 4, 0) end
    if (target.Position - pos).Magnitude < 0.5 then return real end
    return CFrame.lookAt(pos, target.Position)
end

local OriginalSend = nil

local function installAim()
    local net = Game.Network
    if not net or OriginalSend then return end
    local original = net.CSendEvent
    if type(original) ~= "function" then return end
    OriginalSend = original
    net.CSendEvent = function(self, id, ...)
        if id == CAM_SYNC and Aim.Enabled and AimTarget then
            local cf, move = ...
            return original(self, id, aimCFrame(cf), move)
        end
        return original(self, id, ...)
    end
    Restore[#Restore + 1] = function()
        if net.CSendEvent ~= original then net.CSendEvent = original end
    end
end

local function sendCamera(cf)
    if not OriginalSend or not Game.Network then return end
    local root, hum = myRoot()
    if not root then return end
    local move = root.CFrame:VectorToObjectSpace(hum.MoveDirection)
    pcall(OriginalSend, Game.Network, CAM_SYNC, cf, move)
end

-- The parry packet carries a camera too. One namecall hook for the whole
-- session (they can't be removed), which only acts while this script runs.
local function installPacketHook()
    if Genv.__PhantomBallHooked or typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then return end
    Genv.__PhantomBallHooked = true
    local original
    local function onNamecall(self, ...)
        local rewrite = Genv.__PhantomBallPacket
        if rewrite and getnamecallmethod() == "FireServer" then
            local packet = ...
            if typeof(packet) == "buffer" and buffer.len(packet) == 25 then
                pcall(rewrite, self, packet)
            end
        end
        return original(self, ...)
    end
    if typeof(newcclosure) == "function" then onNamecall = newcclosure(onNamecall) end
    original = hookmetamethod(game, "__namecall", onNamecall)
end

Genv.__PhantomBallPacket = function(remote, packet)
    if not Aim.Enabled or not Aim.Packet or not AimTarget then return end
    if remote ~= parryRemote() then return end
    local real = CFrame.new(buffer.readf32(packet, 1), buffer.readf32(packet, 5), buffer.readf32(packet, 9))
    local cf = aimCFrame(real)
    buffer.writef32(packet, 1, cf.Position.X)
    buffer.writef32(packet, 5, cf.Position.Y)
    buffer.writef32(packet, 9, cf.Position.Z)
    buffer.writef32(packet, 13, cf.LookVector.X)
    buffer.writef32(packet, 17, cf.LookVector.Y)
    buffer.writef32(packet, 21, cf.LookVector.Z)
end

--// loading the game's modules ------------------------------------------------

task.spawn(function()
    Game.BR = (req("TS", "BallReplicator", "BallReplicator") or {}).BallReplicator
    Game.GameBall = (req("TS", "Gameplay", "GameBall") or {}).GameBall
    Game.Network = (req("TS", "Network", "Network") or {}).Network
    Game.GameInfo = (req("TS", "GameInfo") or {}).GameInfo
    Game.DeflectClass = (req("TS", "Abilities", "DeflectAbility") or {}).DeflectAbility
    if Unloaded then return end
    -- the live Deflect ability is caught on its per frame tick, so a re-made
    -- one (they are rebuilt whenever abilities sync) is picked up at once
    local class = Game.DeflectClass
    if type(class) == "table" and type(class.OnClientTick) == "function" then
        local originalTick = class.OnClientTick
        class.OnClientTick = function(self, dt, ...)
            if type(self) == "table" and self.Owner == LocalPlayer then
                Game.Deflect, Game.DeflectSeen = self, os.clock()
            end
            return originalTick(self, dt, ...)
        end
        Restore[#Restore + 1] = function()
            if class.OnClientTick ~= originalTick then class.OnClientTick = originalTick end
        end
    end
    installAim()
    installPacketHook()
    Stats.Status = Game.BR and "ready" or "ball replicator not found"
end)

--// every frame ---------------------------------------------------------------

local LastTarget = nil
local LastSpam = 0
local LastCamSend = 0
local LastLives = LocalPlayer:GetAttribute("Lives")

track(LocalPlayer:GetAttributeChangedSignal("Lives"):Connect(function()
    local lives = LocalPlayer:GetAttribute("Lives")
    if type(lives) == "number" and type(LastLives) == "number" and lives < LastLives then Stats.Misses += 1 end
    LastLives = lives
end))

local function step()
    local root = myRoot()
    local state = ballState()
    local mine = state and state.Target == LocalPlayer.UserId

    -- a parry that worked: the ball was yours and went to someone else
    if state then
        if LastTarget == LocalPlayer.UserId and state.Target ~= LocalPlayer.UserId and alive(LocalPlayer) then
            Stats.Parries += 1
            RandomPick = nil
        end
        LastTarget = state.Target
    end

    -- aim: who the ball goes to next, told to the server ahead of the parry
    if Aim.Enabled and root then
        local target = chooseTarget()
        local changed = target ~= AimTarget
        AimTarget = target
        if target and (changed or os.clock() - LastCamSend > 1 / 30) then
            LastCamSend = os.clock()
            local cam = Workspace.CurrentCamera
            sendCamera(aimCFrame(cam and cam.CFrame or root.CFrame))
        end
    elseif AimTarget then
        AimTarget = nil
        local cam = Workspace.CurrentCamera
        if cam then sendCamera(cam.CFrame) end
    end

    -- spam, while its key is held or toggled
    if Parry.Spam and root then
        local gap = 1 / math.clamp(Parry.SpamCps, 1, 24)
        if os.clock() - LastSpam >= gap then
            LastSpam = os.clock()
            press()
        end
    end

    if not state or not root then
        Stats.Status = not Game.BR and "loading the game" or (not root and "no character" or "no ball")
        Stats.LastEta, Stats.LastWindow = nil, nil
        return
    end

    local dist = (state.Pos - root.Position).Magnitude
    local clash = inClash()
    local w = window(state.Speed, clash)
    local t = eta(dist - myRange(), state.Speed, state.Accel)
    Stats.LastEta, Stats.LastWindow, Stats.Clash, Stats.Speed, Stats.Distance = t, w, clash, state.Speed, dist

    if not mine then
        Stats.Status = "ball on someone else"
        return
    end
    if not Parry.Enabled then
        Stats.Status = "ball on you"
        return
    end
    if not ready() then
        Stats.Status = "block recharging"
        return
    end
    local limit = (clash and Parry.Clash) and w or w * Parry.Timing
    if state.Grace or t <= limit then
        if press() then
            Stats.Status = ("parried at %.0fms (window %.0fms%s)"):format(t * 1000, w * 1000, clash and ", clash" or "")
        end
    else
        Stats.Status = ("ball on you, %.0fms out (presses at %.0fms)"):format(t * 1000, limit * 1000)
    end
end

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    local ok, err = pcall(step)
    if not ok then Stats.Status = "error: " .. tostring(err) end
end))

--// visuals --------------------------------------------------------------------

local Holder = Instance.new("Folder")
Holder.Name = "PB_" .. HttpService:GenerateGUID(false):sub(1, 6)
do
    local ok, hui = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    Holder.Parent = ok and hui or LocalPlayer:WaitForChild("PlayerGui")
end

local BallHighlight = Instance.new("Highlight")
BallHighlight.FillTransparency = 0.6
BallHighlight.OutlineTransparency = 0
BallHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
BallHighlight.Parent = Holder

local RangeSphere = Instance.new("SphereHandleAdornment")
RangeSphere.Transparency = 0.85
RangeSphere.AlwaysOnTop = false
RangeSphere.ZIndex = 1
RangeSphere.Parent = Holder

local HasDrawing = typeof(Drawing) == "table" and type(Drawing.new) == "function"
local Drawings = {}
local function draw(kind, props)
    if not HasDrawing then return nil end
    local ok, obj = pcall(Drawing.new, kind)
    if not ok then return nil end
    for k, v in pairs(props) do pcall(function() obj[k] = v end) end
    obj.Visible = false
    Drawings[#Drawings + 1] = obj
    return obj
end

local PATH_STEPS = 10
local PathLines = {}
for i = 1, PATH_STEPS do PathLines[i] = draw("Line", { Thickness = 2, Transparency = 1 }) end
local TracerLine = draw("Line", { Thickness = 1.5, Transparency = 1 })
local TracerText = draw("Text", { Size = 15, Center = true, Outline = true, Transparency = 1 })
local HudText = draw("Text", { Size = 16, Center = true, Outline = true, Transparency = 1, Color = Color3.new(1, 1, 1) })
local BarBack = draw("Square", { Filled = true, Transparency = 0.6, Color = Color3.fromRGB(20, 20, 26) })
local BarSafe = draw("Square", { Filled = true, Transparency = 0.5, Color = Color3.fromRGB(110, 230, 140) })
local BarBall = draw("Square", { Filled = true, Transparency = 1, Color = Color3.fromRGB(255, 255, 255) })

local function hide(obj) if obj then obj.Visible = false end end

local function screen(pos)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local point, onScreen = cam:WorldToViewportPoint(pos)
    if not onScreen or point.Z <= 0 then return nil end
    return Vector2.new(point.X, point.Y)
end

local RangeTags = setmetatable({}, { __mode = "k" })
local function rangeTag(player)
    local tag = RangeTags[player]
    if tag and tag.Parent then return tag end
    tag = Instance.new("BillboardGui")
    tag.Size = UDim2.fromOffset(80, 18)
    tag.StudsOffset = Vector3.new(0, 3.2, 0)
    tag.AlwaysOnTop = true
    tag.Parent = Holder
    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextStrokeTransparency = 0.4
    label.Parent = tag
    RangeTags[player] = tag
    return tag
end

local function drawStep()
    local root = myRoot()
    local ball = ballPart()
    local br = Game.BR
    local last = br and br.history and br.history[#br.history]
    local mine = last and last.targetId == LocalPlayer.UserId

    -- the ball
    BallHighlight.Adornee = (Visual.Ball and ball) or nil
    BallHighlight.Enabled = Visual.Ball and ball ~= nil
    local color = mine and Visual.MineColor or Visual.BallColor
    BallHighlight.FillColor, BallHighlight.OutlineColor = color, color

    -- your range
    RangeSphere.Adornee = (Visual.Range and root) or nil
    RangeSphere.Visible = Visual.Range and root ~= nil
    RangeSphere.Radius = myRange()
    RangeSphere.Color3 = Visual.RangeColor

    -- where it is going, with the game's own replay
    local target = last and type(last.targetId) == "number" and Players:GetPlayerByUserId(last.targetId)
    local targetRoot = target and rootOf(target)
    if Visual.Path and br and last and ball and targetRoot then
        local prev = ball.Position
        for i = 1, PATH_STEPS do
            local line = PathLines[i]
            local ok, pos = pcall(br.SimulateFrom, br, last, math.max(Workspace:GetServerTimeNow() - last.serverTime, 0) + i * 0.08, targetRoot.Position, 1)
            local a, b = screen(prev), ok and typeof(pos) == "Vector3" and screen(pos)
            if line and a and b then
                line.From, line.To, line.Color = a, b, Visual.PathColor
                line.Transparency = 1 - (i - 1) / PATH_STEPS * 0.7
                line.Visible = true
            else
                hide(line)
            end
            if ok and typeof(pos) == "Vector3" then prev = pos end
        end
    else
        for _, line in ipairs(PathLines) do hide(line) end
    end

    -- who it is after
    if Visual.Tracer and ball and targetRoot and TracerLine then
        local a, b = screen(ball.Position), screen(targetRoot.Position)
        if a and b then
            TracerLine.From, TracerLine.To, TracerLine.Color, TracerLine.Visible = a, b, Visual.TracerColor, true
            TracerText.Position = b - Vector2.new(0, 28)
            TracerText.Text = target == LocalPlayer and "YOU" or target.DisplayName
            TracerText.Color = target == LocalPlayer and Visual.MineColor or Visual.TracerColor
            TracerText.Visible = true
        else
            hide(TracerLine)
            hide(TracerText)
        end
    else
        hide(TracerLine)
        hide(TracerText)
    end

    -- the timing bar: the ball's time to reach you against the window, with
    -- the safe part (where it presses) in green
    local cam = Workspace.CurrentCamera
    if Visual.Hud and HudText and cam and Stats.LastWindow then
        local size = cam.ViewportSize
        local w, h = 260, 8
        local x, y = size.X / 2 - w / 2, size.Y - 150
        local shown = math.min(Stats.LastEta or math.huge, Stats.LastWindow * 2)
        BarBack.Position, BarBack.Size, BarBack.Visible = Vector2.new(x, y), Vector2.new(w, h), true
        local safe = (Stats.Clash and Parry.Clash) and 1 or Parry.Timing
        BarSafe.Position, BarSafe.Size, BarSafe.Visible = Vector2.new(x, y), Vector2.new(w * math.clamp(safe / 2, 0, 1), h), true
        BarBall.Position = Vector2.new(x + w * math.clamp(shown / (Stats.LastWindow * 2), 0, 1) - 1, y - 3)
        BarBall.Size, BarBall.Visible = Vector2.new(3, h + 6), mine == true
        HudText.Position = Vector2.new(size.X / 2, y - 22)
        HudText.Text = ("%s   %.0f studs/s   %s   window %.0fms%s%s"):format(
            mine and "ON YOU" or (target and target.DisplayName or "-"),
            Stats.Speed or 0,
            Stats.LastEta and Stats.LastEta < 10 and ("%.0fms out"):format(Stats.LastEta * 1000) or "-",
            Stats.LastWindow * 1000,
            Stats.Clash and "   CLASH" or "",
            AimTarget and ("   aim: " .. AimTarget.DisplayName) or "")
        HudText.Color = mine and Visual.MineColor or Color3.new(1, 1, 1)
        HudText.Visible = true
    else
        hide(HudText)
        hide(BarBack)
        hide(BarSafe)
        hide(BarBall)
    end

    -- everyone's range
    for _, player in ipairs(Players:GetPlayers()) do
        local proot = rootOf(player)
        if Visual.Ranges and proot and alive(player) then
            local tag = rangeTag(player)
            tag.Adornee = proot
            local range = player:GetAttribute("DeflectRange")
            range = type(range) == "number" and range or 8.5
            tag.Text.Text = ("%.1f"):format(range)
            tag.Text.TextColor3 = range > 8.6 and Color3.fromRGB(255, 160, 90) or Color3.fromRGB(220, 220, 220)
            tag.Enabled = true
        elseif RangeTags[player] then
            RangeTags[player].Enabled = false
        end
    end
end

track(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    pcall(drawStep)
end))

--// teardown -----------------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    Parry.Enabled, Parry.Spam, Aim.Enabled = false, false, false
    -- the server hears your real camera again
    local cam = Workspace.CurrentCamera
    if cam then pcall(sendCamera, cam.CFrame) end
    Genv.__PhantomBallPacket = nil
    for _, undo in ipairs(Restore) do pcall(undo) end
    for _, connection in ipairs(Connections) do pcall(function() connection:Disconnect() end) end
    table.clear(Connections)
    for _, obj in ipairs(Drawings) do pcall(function() obj:Remove() end) end
    pcall(function() Holder:Destroy() end)
end

Genv.__PhantomBallStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui -------------------------------------------------------------------------------

Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()

local Window = Library:CreateWindow({
    Title = 'Phantom Ball',
    Footer = 'auto parry',
    Icon = 'swords',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'PhantomBall',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

do
    local Tab = Window:AddTab('Parry', 'shield', 'Auto parry, clash and spam')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('pb_stats', {
        Cards = {
            { Title = 'Parries', Value = '0', Icon = 'shield-check' },
            { Title = 'Presses', Value = '0', Icon = 'mouse-pointer-click' },
            { Title = 'Lives lost', Value = '0', Icon = 'heart-crack' },
            { Title = 'Ball speed', Value = '-', Icon = 'gauge' },
        },
    })
    local status = overview:AddLabel('status: loading', true)
    every(0.15, function()
        cards:SetValue('Parries', tostring(Stats.Parries))
        cards:SetValue('Presses', tostring(Stats.Presses))
        cards:SetValue('Lives lost', tostring(Stats.Misses))
        cards:SetValue('Ball speed', Stats.Speed and ("%.0f"):format(Stats.Speed) or '-')
        status:SetText(("status: %s\nping %.0fms   %s"):format(Stats.Status, ping() * 1000,
            deflect() and "using the game's block" or "block ability not found yet (direct packet)"))
    end)

    local parry = Tab:AddLeftGroupbox('Auto parry', 'shield')
    parry:AddToggle('pb_parry', {
        Text = 'Auto parry',
        Default = Parry.Enabled,
        Callback = function(v) Parry.Enabled = v end,
    }):AddKeyPicker('pb_parry_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Auto parry' })
    parry:AddSlider('pb_timing', {
        Text = 'Press at (share of the window)',
        Tooltip = 'how far away the ball may be when it presses, as a share of the server\'s parry window. the server flags a press past 30% as early, so 0.15 - 0.28 is the safe range. lower is later',
        Min = 0.05, Max = 0.6, Default = Parry.Timing, Rounding = 2,
        Callback = function(v) Parry.Timing = v end,
    })
    parry:AddToggle('pb_pingcomp', {
        Text = 'Ping compensation',
        Tooltip = 'plays the ball forward by your ping, to where it is when the server gets the press',
        Default = Parry.PingComp,
        Callback = function(v) Parry.PingComp = v end,
    })
    parry:AddSlider('pb_pingscale', {
        Text = 'Ping scale',
        Min = 0, Max = 2, Default = Parry.PingScale, Rounding = 2, Suffix = 'x',
        Callback = function(v) Parry.PingScale = v end,
    })
    parry:AddDropdown('pb_method', {
        Text = 'Press with',
        Tooltip = 'game: the game\'s own block (animation, sound, cooldown on screen). direct: sends the same packet straight to the parry remote',
        Values = { 'Game', 'Direct' },
        Default = Parry.Method,
        Callback = function(v) Parry.Method = v or "Game" end,
    })

    local clash = Tab:AddRightGroupbox('Clash + spam', 'zap')
    clash:AddToggle('pb_clash', {
        Text = 'Auto clash',
        Tooltip = 'in a clash (a parry back and forth within 35 studs) it presses as soon as the ball is yours and the short clash cooldown is up',
        Default = Parry.Clash,
        Callback = function(v) Parry.Clash = v end,
    })
    clash:AddToggle('pb_spam', {
        Text = 'Spam',
        Tooltip = 'presses the block over and over while on (hold the key by default). kept under the game\'s 25 clicks a second limit',
        Default = false,
        Callback = function(v) Parry.Spam = v end,
    }):AddKeyPicker('pb_spam_key', { Default = 'None', Mode = 'Hold', SyncToggleState = true, Text = 'Spam' })
    clash:AddSlider('pb_cps', {
        Text = 'Spam clicks a second',
        Min = 2, Max = 24, Default = Parry.SpamCps, Rounding = 0,
        Callback = function(v) Parry.SpamCps = v end,
    })
end

do
    local Tab = Window:AddTab('Aim', 'crosshair', 'Choose who gets the ball')

    local aim = Tab:AddLeftGroupbox('Ball aim', 'crosshair')
    aim:AddToggle('pb_aim', {
        Text = 'Aim the ball',
        Tooltip = 'the server sends the ball to whoever your camera faces, as it last heard it. this tells it your camera faces the chosen player; your real camera does not move',
        Default = Aim.Enabled,
        Callback = function(v) Aim.Enabled = v end,
    }):AddKeyPicker('pb_aim_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Aim' })
    aim:AddDropdown('pb_aim_mode', {
        Text = 'Send it to',
        Values = { 'Farthest', 'Closest', 'Random', 'Player' },
        Default = Aim.Mode,
        Callback = function(v) Aim.Mode = v or "Farthest" end,
    })
    local names = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then names[#names + 1] = player.Name end
    end
    local playerDrop = aim:AddDropdown('pb_aim_player', {
        Text = 'Player',
        Values = names,
        Tooltip = 'for "Player": who gets it (falls back to the farthest if they are out)',
        Callback = function(v) Aim.Player = v end,
    })
    local function refresh()
        local list = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then list[#list + 1] = player.Name end
        end
        table.sort(list)
        pcall(function() playerDrop:SetValues(list) end)
    end
    track(Players.PlayerAdded:Connect(refresh))
    track(Players.PlayerRemoving:Connect(function() task.defer(refresh) end))
    aim:AddToggle('pb_aim_packet', {
        Text = 'Aim the parry packet too',
        Tooltip = 'the parry itself also carries a camera; this turns it the same way (needs hookmetamethod)',
        Default = Aim.Packet,
        Callback = function(v) Aim.Packet = v end,
    })
    local aimStatus = aim:AddLabel('aim: off', true)
    every(0.25, function()
        aimStatus:SetText(not Aim.Enabled and "aim: off"
            or (AimTarget and ("aim: sending it to " .. AimTarget.DisplayName .. " (@" .. AimTarget.Name .. ")"))
            or "aim: nobody to send it to")
    end)
    aim:AddLabel('Teammates, cloaked players and players out of lives are never picked. A Dark Sealed player always gets it, that is the game\'s rule.', true)
end

do
    local Tab = Window:AddTab('Visuals', 'eye', 'Ball, path, target and timing')

    local look = Tab:AddLeftGroupbox('Ball', 'circle')
    look:AddToggle('pb_v_ball', { Text = 'Highlight the ball', Default = Visual.Ball, Callback = function(v) Visual.Ball = v end })
        :AddColorPicker('pb_v_ball_c', { Default = Visual.BallColor, Title = 'Ball', Callback = function(c) Visual.BallColor = c end })
    look:AddLabel('On you'):AddColorPicker('pb_v_mine_c', { Default = Visual.MineColor, Title = 'On you', Callback = function(c) Visual.MineColor = c end })
    look:AddToggle('pb_v_path', { Text = 'Predicted path', Tooltip = 'where the ball goes over the next 0.8s, from the game\'s own movement', Default = Visual.Path, Callback = function(v) Visual.Path = v end })
        :AddColorPicker('pb_v_path_c', { Default = Visual.PathColor, Title = 'Path', Callback = function(c) Visual.PathColor = c end })
    look:AddToggle('pb_v_tracer', { Text = 'Target tracer', Default = Visual.Tracer, Callback = function(v) Visual.Tracer = v end })
        :AddColorPicker('pb_v_tracer_c', { Default = Visual.TracerColor, Title = 'Tracer', Callback = function(c) Visual.TracerColor = c end })

    local hud = Tab:AddRightGroupbox('You', 'user')
    hud:AddToggle('pb_v_hud', { Text = 'Timing bar', Tooltip = 'the ball\'s time to reach you against the parry window; green is where auto parry presses', Default = Visual.Hud, Callback = function(v) Visual.Hud = v end })
    hud:AddToggle('pb_v_range', { Text = 'My parry range', Default = Visual.Range, Callback = function(v) Visual.Range = v end })
        :AddColorPicker('pb_v_range_c', { Default = Visual.RangeColor, Title = 'Range', Callback = function(c) Visual.RangeColor = c end })
    hud:AddToggle('pb_v_ranges', { Text = 'Everyone\'s range', Tooltip = 'parry range over each player; orange is grown by Resilience', Default = Visual.Ranges, Callback = function(v) Visual.Ranges = v end })
    if not HasDrawing then hud:AddLabel('This executor has no Drawing library: the path, tracer and timing bar can\'t show.', true) end
end

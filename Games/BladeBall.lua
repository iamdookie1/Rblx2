-- Blade Ball
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).

task.spawn(function()

-- Bumped on every change, shown in the window footer and the Status tab, so
-- you always know which build you're testing.
local SCRIPT_VERSION = "2026.10.06-4"

-- Only one copy runs. Executing the script again shuts the previous copy down
-- first (otherwise both keep auto parrying, and every pass gets two parries
-- that no fix inside one copy can stop). Every parry also goes through
-- is_live(), so a copy that's been replaced can never send one even if
-- something of it lingers.
local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
genv.__BladeBallInstance = INSTANCE
local function is_live() return genv.__BladeBallInstance == INSTANCE end

-- Parry log: every parry this copy sends, where it came from, which pass at you
-- it was for. Spam sources are only counted (they fire hundreds a second).
local ParryLog = {entries = {}, source = nil, spam = 0, total = 0, doubles = 0, describe = nil}
local SPAM_SOURCES = {["manual spam"] = true, ["auto spam"] = true, ["slashes of fury"] = true}
local function log_send(how)
    local src = ParryLog.source or "unknown"
    if SPAM_SOURCES[src] then ParryLog.spam = ParryLog.spam + 1; return end
    ParryLog.total = ParryLog.total + 1
    local info = ParryLog.describe and ParryLog.describe() or {}
    local entry = {t = os.clock(), src = src, how = how, pass = info.pass, dist = info.dist, heading = info.heading}
    local last = ParryLog.entries[#ParryLog.entries]
    if entry.pass and last and last.pass == entry.pass then
        entry.double = true
        ParryLog.doubles = ParryLog.doubles + 1
    end
    table.insert(ParryLog.entries, entry)
    if #ParryLog.entries > 8 then table.remove(ParryLog.entries, 1) end
end

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options = Library.Options
local Toggles = Library.Toggles

-- Ui3 autoloads the saved config as each element is created, which runs that
-- element's callback. So the window goes up first (for notifications), and
-- every tab and element is added at the bottom of this file, once everything
-- the callbacks touch exists.
local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "auto parry  |  v" .. SCRIPT_VERSION,
    Icon = "swords",
    ToggleKeybind = Enum.KeyCode.LeftControl,
    ConfigFolder = "BladeBall",
})

local isMobile = Library.IsMobile
-- Set once the UI is built, so autoloaded toggles don't each fire a notification.
local UIReady = false

local function Notify(t, c, d)
    pcall(function()
        Library:Notify({Title = t or "Blade Ball", Description = c or "", Time = d or 2})
    end)
end

local function NotifyToggle(name, v)
    if UIReady then Notify(name, v and "ON" or "OFF", 1.5) end
end

-- ============================================================
-- CORE SERVICES
-- ============================================================
repeat task.wait(0.5) until game:IsLoaded()

local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService('Players'))
local ReplicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local UserInputService = cloneref(game:GetService('UserInputService'))
local RunService = cloneref(game:GetService('RunService'))
local Stats = cloneref(game:GetService('Stats'))
local Debris = cloneref(game:GetService('Debris'))
local CoreGui = cloneref(game:GetService('CoreGui'))
local HttpService = cloneref(game:GetService('HttpService'))
local Workspace = cloneref(game:GetService('Workspace'))
local VirtualInputManager = cloneref(game:GetService('VirtualInputManager'))

local LocalPlayer = Players.LocalPlayer

if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end

local Alive = Workspace:FindFirstChild("Alive") or Workspace:WaitForChild("Alive")
local Runtime = Workspace:FindFirstChild("Runtime") or Workspace:WaitForChild("Runtime")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Every file this script writes goes under one folder.
local SAVE_FOLDER = "BladeBall"
local function ensureSaveFolder()
    pcall(function()
        if isfolder and makefolder and not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
    end)
end

local function getPing()
    local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
    return ok and ping or 0
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char.PrimaryPart
end

-- ============================================================
-- PARRY REMOTE
-- ============================================================
-- The game's real, curve-carrying parry is its block ACTION, not a remote we can
-- fire by hand. Pressing block runs the game's own handler, which reads
-- Workspace.CurrentCamera.CFrame and sends it to the server as the parry's aim --
-- that camera CFrame *is* the curve. The game pairs it with the screen points and
-- a signed token and fires its own remote. (The game also has a bare argless
-- Remotes.ParryAttempt:FireServer() that carries no aim and so can't curve --
-- which is why firing it directly felt flat.)
--
-- So we parry the way the game does: aim the camera, then trigger the block
-- action with a real input event. The game signs and fires its own remote with
-- the camera we aimed -- no getgc, no hooks, no forged token, so it's the game's
-- own send (valid and silent), and curve works because the server reads our aim.
-- The cost is the game's normal parry cooldown, which is also the legitimate
-- ceiling, so this stays indistinguishable from a real player.

local function remoteReady()
    return VirtualInputManager ~= nil -- the block action is always available while alive
end

-- No-op kept for existing call sites (parries just trigger the block action now);
-- defined further down, once System exists. Declared here so earlier code can
-- reference it.
local prime_remote

-- "A place where they can parry" — mirrors the game's own client parry gate. A
-- block is allowed when the character isn't Stunned and doesn't carry DoNotParry
-- (server-set attributes the game toggles whenever you can't block) AND it's in a
-- spot where parrying happens: a live round (under Workspace.Alive), a lobby
-- parry (LobbyParry attribute), or training (under Workspace.Dead with the
-- LobbyTraining attribute). The old version only accepted Alive, so it never
-- armed during lobby / training parrying.
local function canParryNow()
    local char = LocalPlayer.Character
    if not char then return false end
    if char:GetAttribute("Stunned") then return false end
    if char:GetAttribute("DoNotParry") then return false end
    if char.Parent == Alive then return true end
    if LocalPlayer:GetAttribute("LobbyParry") then return true end
    if LocalPlayer:GetAttribute("LobbyTraining") then
        local Dead = Workspace:FindFirstChild("Dead")
        if Dead and char.Parent == Dead then return true end
    end
    return false
end

if not remoteReady() then
    Notify("Blade Ball", "VirtualInputManager unavailable -- this executor can't trigger parries.", 6)
end

-- The one real input primitive: tap the block key. This is what drives the
-- game's own parry handler (InputBegan "Block" -> the handler that reads the
-- camera and fires the signed remote). F is the game's default block bind.
local function sendBlockInput()
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)
end

-- Plain block press (keypress mode / fallback): the game's parry toward your
-- current aim, no curve override.
local function pressBlockKey()
    if not is_live() then return end
    log_send("block key")
    sendBlockInput()
end

-- Fallback for when the parry remote can't be found: press block the normal way
-- (the game's own parry, with its cooldown).
local function press_block()
    pressBlockKey()
end

local CollectionService = cloneref(game:GetService('CollectionService'))

-- Frame-rate cap shared with the curve cache below.
local PACKET_TTL = 1 / 240

-- Parry with curve. The game's block handler reads Workspace.CurrentCamera.CFrame
-- and sends it as the parry's aim, so we point the camera at the curve target for
-- the instant the parry is read, then trigger the block action with a real input
-- event -- the game signs and fires its own remote with our aim. For "Camera"
-- curve mode, curveCF is just the current camera, so the set is a harmless no-op;
-- other modes bend the shot. The default camera script recenters next frame.
-- Always returns true (callers shouldn't fall back to a second press).
local function fireParryRemote(curveCF)
    if not is_live() then return true end -- replaced copy: send nothing
    if not remoteReady() then return false end
    if curveCF then pcall(function() Workspace.CurrentCamera.CFrame = curveCF end) end
    log_send("remote")
    sendBlockInput()
    return true
end

-- ============================================================
-- SYSTEM
-- ============================================================
local System = {
    __properties = {
        __autoparry_enabled = false, __triggerbot_enabled = false,
        __manual_spam_enabled = false, __play_animation = false,
        __curve_mode = 1, __accuracy = 50, __accuracy_base = 50, __divisor_multiplier = 1.1,
        __random_accuracy = false, __random_accuracy_amount = 10, __frame_dt = 1/60,
        __auto_spam_enabled = false,
        __parried = false, __training_parried = false, __parries = 0,
        __grab_animation = nil, __tornado_time = tick(),
        __connections = {}, __infinity_active = false,
        __deathslash_active = false, __timehole_active = false,
        __slashesoffury_active = false, __slashesoffury_count = 0,
        __is_mobile = isMobile,
        __mobile_guis = {}, __headless_enabled = false, __korblox_enabled = false,
        __ball_velocity_gui = nil, __ball_velocity_enabled = false,
        __peak_velocity = 0, __last_ball_id = nil, __show_ping = false,
        __auto_ability_enabled = false, __cooldown_protection = false,
        __total_parries = 0, __ping_compensation = true, __extra_distance = 0,
        __curve_hotkeys = true
    },
    __config = {
        __curve_names = {'Camera', 'Random', 'Accelerated', 'Backwards', 'Slow', 'High', 'Normal', 'Speed', 'Down', 'Left', 'Right'},
        __detections = {__infinity = false, __deathslash = false, __timehole = false, __slashesoffury = false, __phantom = false}
    },
    __triggerbot = {__enabled = false, __is_parrying = false, __parries = 0, __max_parries = 10000}
}

local function update_divisor()
    System.__properties.__divisor_multiplier = 0.7 + (System.__properties.__accuracy - 1) * (0.9/99)
end
update_divisor()

-- Effective accuracy is the slider value, optionally jittered by a random amount
-- centred on that value. Re-rolled each frame while randomize is on, so the
-- parry window wanders around the chosen accuracy instead of being fixed.
local function roll_accuracy()
    local props = System.__properties
    local acc = props.__accuracy_base
    if props.__random_accuracy and props.__random_accuracy_amount > 0 then
        acc = acc + math.random(-props.__random_accuracy_amount, props.__random_accuracy_amount)
    end
    props.__accuracy = math.clamp(acc, 1, 100)
    update_divisor()
end

-- Animation
System.animation = {}
local SwordAPI = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwordAPI")
local LastPlayedd = 0
local Sword_CP = false
local Sword_Spped = 1
local Grab_Parry = nil
local AnimFix_Cache = {}

local function GetParryAnimation(swordName)
    if not swordName or swordName == "" then return SwordAPI.Collection.Default:FindFirstChild("GrabParry") end
    if AnimFix_Cache[swordName] then return AnimFix_Cache[swordName] end
    local ok, swordData = pcall(function()
        return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(swordName)
    end)
    if not ok or not swordData or type(swordData) ~= "table" or not swordData.AnimationType then
        AnimFix_Cache[swordName] = SwordAPI.Collection.Default:FindFirstChild("GrabParry")
        return AnimFix_Cache[swordName]
    end
    for _, obj in pairs(SwordAPI.Collection:GetChildren()) do
        if obj.Name == swordData.AnimationType then
            local anim = obj:FindFirstChild("GrabParry") or obj:FindFirstChild("Grab")
            if anim then AnimFix_Cache[swordName] = anim; return anim end
        end
    end
    AnimFix_Cache[swordName] = SwordAPI.Collection.Default:FindFirstChild("GrabParry")
    return AnimFix_Cache[swordName]
end

local function GrabParryPlay(track)
    if not track then return end
    pcall(function()
        track:Play(track:GetAttribute("PlayFadeTime") or 0, track:GetAttribute("PlayWeight") or 1, track:GetAttribute("PlaySpeed") or 1)
    end)
end

local function GrabParryStop(track)
    if not track then return end
    pcall(function() track:Stop(track:GetAttribute("StopFadeTime") or 0.1) end)
end

function System.animation.play_grab_parry()
    if not System.__properties.__play_animation then return end
    if not ((os.clock() - LastPlayedd) >= (Sword_Spped - 0.8) or Sword_CP) then return end
    LastPlayedd = os.clock()
    Sword_CP = false
    local char = LocalPlayer.Character
    if not char then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    local currentSword
    if getgenv().skinChangerEnabled then
        currentSword = (getgenv().swordAnimations ~= "" and getgenv().swordAnimations)
                    or (getgenv().swordModel ~= "" and getgenv().swordModel)
                    or char:GetAttribute("CurrentlyEquippedSword")
    else
        currentSword = char:GetAttribute("CurrentlyEquippedSword")
    end
    local animation = GetParryAnimation(currentSword)
    if not animation then return end
    for _, track in pairs(humanoid.Animator:GetPlayingAnimationTracks()) do
        if track.Name == "GrabParry" or track.Name == "Grab" then
            track.TimePosition = 0
            GrabParryStop(track)
        elseif track.Name == "SuccessParry" or track.Name == "Success" then
            GrabParryStop(track)
        end
    end
    Grab_Parry = humanoid.Animator:LoadAnimation(animation)
    GrabParryPlay(Grab_Parry)
end

-- A swing that plays to the end: only starts a new grab once the last one has
-- finished (or a parry landed, which the game follows with its own success
-- animation), so a held spam looks like real swings instead of a stuttering
-- grab start.
function System.animation.play_grab_parry_full()
    if Grab_Parry and not Sword_CP then
        local ok, playing = pcall(function() return Grab_Parry.IsPlaying end)
        if ok and playing then return end
    end
    System.animation.play_grab_parry()
end

pcall(function()
    Remotes.ParrySuccessAll.OnClientEvent:Connect(function()
        Sword_CP = true
        local char = LocalPlayer.Character
        if not char then return end
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if not humanoid then return end
        for _, track in pairs(humanoid.Animator:GetPlayingAnimationTracks()) do
            if track.Name == "GrabParry" or track.Name == "Grab" then GrabParryStop(track) end
        end
    end)
end)

-- Ball
System.ball = {}
function System.ball.get()
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return nil end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then ball.CanCollide = false; return ball end
    end; return nil
end
function System.ball.get_all()
    local balls_table = {}; local balls = Workspace:FindFirstChild('Balls')
    if not balls then return balls_table end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then ball.CanCollide = false; table.insert(balls_table, ball) end
    end; return balls_table
end

System.player = {}
local Closest_Entity = nil; local last_closest_check = 0
function System.player.get_closest()
    local now = tick()
    if now - last_closest_check < 0.1 then return Closest_Entity end
    last_closest_check = now
    local max_distance = math.huge; local closest_entity = nil
    if not Alive then return nil end
    for _, entity in pairs(Alive:GetChildren()) do
        if entity ~= LocalPlayer.Character and entity.PrimaryPart then
            local distance = LocalPlayer:DistanceFromCharacter(entity.PrimaryPart.Position)
            if distance < max_distance then max_distance = distance; closest_entity = entity end
        end
    end
    Closest_Entity = closest_entity; return closest_entity
end

System.curve = {}
function System.curve.get_cframe()
    local Camera = Workspace.CurrentCamera
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local root_pos = root and root.Position or Camera.CFrame.Position
    local targetPart
    do
        local bestDist = math.huge
        local mouseLoc = not isMobile and UserInputService:GetMouseLocation() or nil
        if Alive then
            for _, v in pairs(Alive:GetChildren()) do
                if v ~= LocalPlayer.Character and v.PrimaryPart then
                    local screenPos, onScreen = Camera:WorldToScreenPoint(v.PrimaryPart.Position)
                    if onScreen then
                        local dist
                        if mouseLoc then dist = (Vector2.new(screenPos.X, screenPos.Y) - mouseLoc).Magnitude
                        else local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2); dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude end
                        if dist < bestDist then bestDist = dist; targetPart = v.PrimaryPart end
                    end
                end
            end
        end
    end
    local target_pos = targetPart and targetPart.Position or (root_pos + Camera.CFrame.LookVector * 100)
    local Parry_Type = System.__config.__curve_names[System.__properties.__curve_mode]
    local cf
    if Parry_Type == "Camera" then cf = Camera.CFrame
    elseif Parry_Type == "Random" then
        local direction = (target_pos - root_pos).Unit
        local random_offset; local attempts = 0
        repeat
            random_offset = Vector3.new(math.random(-4000,4000), math.random(-4000,4000), math.random(-4000,4000))
            local curve_dir = (target_pos + random_offset - root_pos).Unit
            local dot = direction:Dot(curve_dir); attempts = attempts + 1
        until dot < 0.95 or attempts > 10
        cf = CFrame.new(root_pos, target_pos + random_offset)
    elseif Parry_Type == "Accelerated" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, 5, 0))
    elseif Parry_Type == "Backwards" then
        local direction = (root_pos - target_pos).Unit
        local backwards_pos = root_pos + direction * 10000 + Vector3.new(0, 1000, 0)
        cf = CFrame.new(Camera.CFrame.Position, backwards_pos)
    elseif Parry_Type == "Slow" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, -9e18, 0))
    elseif Parry_Type == "High" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, 9e18, 0))
    elseif Parry_Type == "Normal" then cf = CFrame.new(root_pos, root_pos + (root and root.CFrame.LookVector or Camera.CFrame.LookVector))
    elseif Parry_Type == "Speed" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.UpVector * 5)
    elseif Parry_Type == "Down" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.UpVector * -9e9)
    elseif Parry_Type == "Left" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position - Camera.CFrame.RightVector * 9e9)
    elseif Parry_Type == "Right" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.RightVector * 9e9)
    else cf = Camera.CFrame end
    return cf
end

-- Same curve for every parry fired in one frame (spam), so the per-player screen
-- projection in get_cframe runs once per frame, not once per parry.
local curve_cache = {at = -1, mode = nil, cf = nil}
function System.curve.get_cframe_fast()
    local now, mode = os.clock(), System.__properties.__curve_mode
    if now - curve_cache.at > PACKET_TTL or curve_cache.mode ~= mode then
        curve_cache.cf = System.curve.get_cframe()
        curve_cache.at, curve_cache.mode = now, mode
    end
    return curve_cache.cf
end

System.parry = {}
-- "Remote" fires the parry remote with the chosen curve. "Keypress" presses the
-- block key. Remote mode falls back to the key until the remote is captured.
function System.parry.execute()
    if System.__properties.__parries > 10000 or not LocalPlayer.Character then return end
    if not fireParryRemote(System.curve.get_cframe()) then press_block() end
    System.__properties.__parries = System.__properties.__parries + 1
    System.__properties.__total_parries = System.__properties.__total_parries + 1
    task.delay(0.5, function()
        if System.__properties.__parries > 0 then System.__properties.__parries = System.__properties.__parries - 1 end
    end)
end
function System.parry.keypress()
    if not LocalPlayer.Character then return end
    press_block()
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end
-- Light parry for spam: same remote and curve as execute, but reuses the frame's
-- curve/packet and leaves no cleanup thread behind (execute schedules a
-- task.delay per call, which piles up into thousands at spam rates).
function System.parry.fast()
    if not LocalPlayer.Character then return end
    if not fireParryRemote(System.curve.get_cframe_fast()) then press_block() end
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end

-- Nothing to prime anymore -- parries just trigger the game's block action, which
-- is always available. Kept as a no-op so existing call sites stay valid.
prime_remote = function() end
function System.parry.execute_action() System.animation.play_grab_parry(); System.parry.execute() end
function System.parry.by_mode(mode)
    if mode == "Keypress" then System.parry.keypress() else System.parry.execute_action() end
end

-- ============================================================
-- DETECTION EVENTS
-- ============================================================
local function isLocal(player)
    return player == LocalPlayer or player == LocalPlayer.Name or (typeof(player) == 'Instance' and player.Name == LocalPlayer.Name)
end

pcall(function()
    Remotes.DeathBall.OnClientEvent:Connect(function(c, d) System.__properties.__deathslash_active = d or false end)
end)
pcall(function()
    Remotes.InfinityBall.OnClientEvent:Connect(function(a, b) System.__properties.__infinity_active = b or false end)
end)

local net
pcall(function() net = ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"].net end)
local function onNet(name, fn)
    pcall(function() net[name].OnClientEvent:Connect(fn) end)
end

onNet("RE/TimeHoleActivate", function(player)
    if isLocal(player) then System.__properties.__timehole_active = true end
end)
onNet("RE/TimeHoleDeactivate", function()
    System.__properties.__timehole_active = false
end)

local maxParryCount = 36; local parryDelay = 0.05
-- One loop at a time, driven locally so it works even if the server is slow to
-- echo SlashesOfFuryParry back. The old loop only started on Catch (which can
-- race ahead of Activate) and relied entirely on the server count, so it often
-- never ran or stopped early. This one starts on either event and keeps its own
-- count as a safety cap.
local slashesLoopRunning = false
local function runSlashesLoop()
    if slashesLoopRunning then return end
    if not System.__config.__detections.__slashesoffury then return end
    if not System.__properties.__slashesoffury_active then return end
    slashesLoopRunning = true
    task.spawn(function()
        local sent = 0
        while System.__properties.__slashesoffury_active
            and System.__config.__detections.__slashesoffury
            and sent < maxParryCount
            and System.__properties.__slashesoffury_count < maxParryCount
            and LocalPlayer.Character do
            ParryLog.source = "slashes of fury"; System.parry.execute(); ParryLog.source = nil
            if System.__properties.__play_animation then
                pcall(System.animation.play_grab_parry)
            end
            sent = sent + 1
            task.wait(parryDelay)
        end
        slashesLoopRunning = false
    end)
end
onNet("RE/SlashesOfFuryActivate", function(player)
    if isLocal(player) then
        System.__properties.__slashesoffury_active = true
        System.__properties.__slashesoffury_count = 0
        runSlashesLoop()
    end
end)
onNet("RE/SlashesOfFuryEnd", function()
    System.__properties.__slashesoffury_active = false
    System.__properties.__slashesoffury_count = 0
    slashesLoopRunning = false
end)
onNet("RE/SlashesOfFuryParry", function()
    System.__properties.__slashesoffury_count = System.__properties.__slashesoffury_count + 1
end)
onNet("RE/SlashesOfFuryCatch", function()
    runSlashesLoop()
end)

Runtime.ChildAdded:Connect(function(Object)
    if not System.__config.__detections.__phantom then return end
    if Object.Name ~= "maxTransmission" and Object.Name ~= "transmissionpart" then return end
    local Weld = Object:FindFirstChildWhichIsA("WeldConstraint")
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not Weld or not root or Weld.Part1 ~= root then return end
    local CurrentBall = System.ball.get(); Weld:Destroy()
    if not CurrentBall then return end
    local FocusConnection
    FocusConnection = RunService.RenderStepped:Connect(function()
        local Highlighted = CurrentBall:GetAttribute("highlighted")
        if Highlighted == true then
            Remotes.AbilityButtonPress:Fire()
            System.__properties.__parried = true
            task.delay(1, function() System.__properties.__parried = false end)
        elseif Highlighted == false then FocusConnection:Disconnect() end
    end)
    task.delay(3, function() if FocusConnection and FocusConnection.Connected then FocusConnection:Disconnect() end end)
end)

Remotes.ParrySuccess.OnClientEvent:Connect(function()
    if not LocalPlayer.Character or LocalPlayer.Character.Parent ~= Alive then return end
    if System.__properties.__grab_animation then System.__properties.__grab_animation:Stop() end
end)

-- ============================================================
-- TRIGGERBOT
-- ============================================================
System.triggerbot = {}

-- One parry per pass, the moment the ball targets you: re-armed only when the
-- ball goes to someone else and comes back. (It used to re-arm every 0.02s, so
-- it kept parrying for as long as the ball stayed on you.)
function System.triggerbot.trigger(ball)
    local state = System.ball_state and System.ball_state(ball)
    if not state or state.pass_parried then return end
    state.pass_parried = true
    System.__triggerbot.__parries = System.__triggerbot.__parries + 1
    ParryLog.source = "triggerbot"
    System.parry.execute()
    ParryLog.source = nil
    if System.__properties.__play_animation then System.animation.play_grab_parry() end
end

function System.triggerbot.loop()
    if not System.__triggerbot.__enabled then return end
    local root = getRoot()
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return end
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return end
    for _, ball in ipairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') and ball:GetAttribute('target') == LocalPlayer.Name then
            System.triggerbot.trigger(ball)
        end
    end
end

function System.triggerbot.enable(enabled)
    System.__triggerbot.__enabled = enabled
    if enabled then
        if not System.__properties.__connections.__triggerbot then
            System.__properties.__connections.__triggerbot = RunService.PreSimulation:Connect(System.triggerbot.loop)
        end
    else
        if System.__properties.__connections.__triggerbot then
            System.__properties.__connections.__triggerbot:Disconnect()
            System.__properties.__connections.__triggerbot = nil
        end
        System.__triggerbot.__is_parrying = false
        System.__triggerbot.__parries = 0
    end
end

-- ============================================================
-- AUTO PARRY
-- ============================================================
System.autoparry = {}

-- How far away (studs) a ball moving at `speed` gets parried.
function System.parry_distance(speed)
    local props = System.__properties
    -- Capped so a lag spike can't blow the window up to the whole map.
    local ping_ms = math.min(getPing(), 400)
    local ping_threshold = math.clamp(ping_ms / 100, 5, 17)
    -- Old code capped the speed term at 650, so past ~660 studs/s the window
    -- stopped growing and very fast balls were parried too late (or skipped).
    -- Growth now continues for any speed, just tapering off so it stays sane.
    local speed_diff = math.max(speed - 9.5, 0)
    local speed_divisor = (2.4 + speed_diff * 0.0016) * props.__divisor_multiplier
    local distance = ping_threshold + math.max(speed / speed_divisor, 9.5)
    if props.__ping_compensation then
        -- The parry reaches the server about half a round trip later, and the
        -- ball keeps closing in the meantime.
        distance = distance + speed * (ping_ms / 1000) * 0.5
        -- Never later than the parry can reach the server in time: the server
        -- sees the ball half a ping ahead and gets our parry half a ping late,
        -- so the ball has to be at least a full ping (plus a couple of frames)
        -- out when we fire, whatever the accuracy setting.
        local min_lead = speed * (ping_ms / 1000 + props.__frame_dt * 2)
        if distance < min_lead then distance = min_lead end
    end
    -- High-speed safety: a ball moving fast enough can jump the whole window in
    -- a single frame. Guarantee the window is at least a few frames of travel so
    -- the distance check catches it no matter the frame rate.
    local frame_travel = speed * math.clamp(props.__frame_dt * 3, 1/120, 0.12)
    if frame_travel > distance then distance = frame_travel end
    return distance + props.__extra_distance
end

-- Close range is where a reactive parry loses: the ball comes back from a
-- player next to you faster than a round trip, so by the time "ball is on me"
-- replicates it's already too late. The game's parry stays up for ~0.5s though,
-- so up close auto parry (a) parries the instant the ball retargets you instead
-- of waiting a frame, (b) retries a parry that didn't take after about one round
-- trip instead of a full second, and (c) pre-parries while the ball is on a
-- player standing right next to you, so the parry is already up when it returns.
local APCfg = {
    close_range = 20,       -- studs; instant retarget and pre-parry work inside this
    instant = true,         -- run the decision straight from the target change
    preparry = false,       -- opt-in: parry ahead when a player next to you is about to hit it back
    curve = 0.5,            -- anti curve: how straight a ball must head at you (dot) before parrying
    hit_zone = 4,           -- studs: a ball whose line passes this close to us is coming at us
    hit_radius = 3,         -- studs: the ball has reached us
    parry_window = 0.45,    -- parry once the ball lands within this (+ ping); a bit under the real window
    parry_lasts = 0.5,      -- how long the game keeps a parry up
    landed_hold = 0.75,     -- max wait for the ball to leave us after a parry lands
}

-- One parry at a time, shared by every auto parry path (frame loop, instant
-- retarget, pre-parry, parry-back), mirroring the game's own client rule that
-- you can't parry while one is still up:
--   * nothing fires while our last parry is still up. In our own (client)
--     time that's the game's window plus a full ping: it starts half a ping
--     late on the server, and the server sees the ball half a ping ahead;
--     If the ball was due to land late in that window, we also hold until the
--     success has had time to come back from that landing;
--   * once it lands (ParrySuccess) we stay locked until the ball actually
--     leaves us. The success event usually arrives a moment before the
--     target flips, and that gap used to get a second parry;
--   * the ball leaving us frees the next parry at once.
local ParryCover = {at = 0, busy_until = 0, landed = false, landed_at = 0}
local function parry_up_for()
    return APCfg.parry_lasts + getPing() / 1000 + 0.03
end
local function parry_busy()
    local now = tick()
    if ParryCover.at > 0 and now < ParryCover.busy_until then return true end
    return ParryCover.landed and now - ParryCover.landed_at < APCfg.landed_hold
end
-- eta: when the ball we're parrying is due to land (nil for a pre-parry).
local function mark_parry(eta)
    local now = tick()
    ParryCover.at, ParryCover.landed = now, false
    ParryCover.busy_until = now + math.max(parry_up_for(), (eta or 0) + getPing() / 2000 + 0.05)
end
local function parry_landed()
    ParryCover.landed, ParryCover.landed_at = true, tick()
end
local function parry_released()
    ParryCover.at, ParryCover.landed = 0, false
end

-- ------------------------------------------------------------
-- Ball tracking (shared by auto parry and auto spam)
-- ------------------------------------------------------------
-- One record per ball. Its target listener is made once, keeps a short history
-- of who the ball went from/to (what clash detection reads), resets the parry
-- lockout, and hands a retarget onto us straight to auto parry.
local BALL_HISTORY = 16
local ball_state = setmetatable({}, {__mode = 'k'})
local pass_counter = 0
-- A pass starts when the ball comes onto us after being on someone else (or is
-- first seen on us); it ends when someone else gets it. Each gets an id so the
-- parry log can show which pass a parry was for.
local function open_pass(state)
    if state.pass_open then return end
    pass_counter = pass_counter + 1
    state.pass_id, state.pass_open = pass_counter, true
    -- A pre-parry fired while the ball was on its last holder was this pass's parry.
    if state.preparried then state.pass_parried = true end
    state.preparried = false
end
local function get_ball_state(ball)
    local state = ball_state[ball]
    if state then return state end
    state = {parried = false, at = 0, target = ball:GetAttribute('target'), swaps = {}}
    ball_state[ball] = state
    if state.target == LocalPlayer.Name then open_pass(state) end
    ball:GetAttributeChangedSignal('target'):Connect(function()
        local new = ball:GetAttribute('target')
        local swaps = state.swaps
        swaps[#swaps + 1] = {t = os.clock(), from = state.target, to = new}
        if #swaps > BALL_HISTORY then table.remove(swaps, 1) end
        -- The ball left us: our parry landed, so it's used up.
        if state.target == LocalPlayer.Name and new ~= LocalPlayer.Name then parry_released() end
        -- One parry per pass: the lock lifts only when someone else gets the
        -- ball, so the next time it's on us is a new pass. A blank target in
        -- between (me -> "" -> me) is the same pass, not a new one.
        if type(new) == 'string' and new ~= '' and new ~= LocalPlayer.Name then
            state.pass_parried, state.pass_open, state.preparried = false, false, false
        end
        if new == LocalPlayer.Name then open_pass(state) end
        state.target = new
        state.parried = false
        if new == LocalPlayer.Name then
            -- A fresh pass at us.
            state.reached_at = nil
            -- Randomized accuracy: one roll per ball coming at you. Re-rolling
            -- every frame meant the ball crossed whichever frame rolled lowest,
            -- so it always parried early instead of around your setting.
            if System.__properties.__random_accuracy then roll_accuracy() end
        end
        if new == LocalPlayer.Name and System.autoparry.on_retarget then
            System.autoparry.on_retarget(ball)
        end
    end)
    return state
end
-- For code defined above this (triggerbot) that needs the same per-ball pass lock.
System.ball_state = get_ball_state

-- Match balls plus lobby training balls.
local function get_live_balls()
    local balls = System.ball.get_all()
    local training = Workspace:FindFirstChild("TrainingBalls")
    if training then
        for _, ball in ipairs(training:GetChildren()) do
            if ball:GetAttribute("realBall") then table.insert(balls, ball) end
        end
    end
    return balls
end

-- A player's root by character name, from Alive (round) or Dead (training).
local function character_root(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local char = Alive:FindFirstChild(name)
    if not char then
        local dead = Workspace:FindFirstChild('Dead')
        char = dead and dead:FindFirstChild(name)
    end
    return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
end

local ABILITY_PARRY = {"Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash"}
local ABILITY_PROTECT = {"Raging Deflection", "Rapture", "Calming Deflection"}

local function ability_ready()
    local ok, ready = pcall(function()
        return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5
    end)
    return ok and ready
end

local function has_ability(list)
    local abilities = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Abilities")
    if not abilities then return false end
    for _, name in ipairs(list) do
        local ability = abilities:FindFirstChild(name)
        if ability then
            local ok, enabled = pcall(function() return ability.Enabled end)
            if ok and enabled then return true end
        end
    end
    return false
end

-- Uses the equipped ability in place of a parry when the options allow it.
local function try_ability()
    local props = System.__properties
    if props.__auto_ability_enabled and ability_ready() and has_ability(ABILITY_PARRY) then
        Remotes.AbilityButtonPress:Fire()
        task.delay(2.432, function()
            local ds = Remotes:FindFirstChild("DeathSlashShootActivation")
            if ds then pcall(function() ds:FireServer(true) end) end
        end)
        return true
    end
    if props.__cooldown_protection and ability_ready() and has_ability(ABILITY_PROTECT) then
        Remotes.AbilityButtonPress:Fire()
        return true
    end
    return false
end

local function blocked_by_detection()
    local det, props = System.__config.__detections, System.__properties
    return (det.__infinity and props.__infinity_active)
        or (det.__deathslash and props.__deathslash_active)
        or (det.__timehole and props.__timehole_active)
        or (det.__slashesoffury and props.__slashesoffury_active)
end

local function autoparry_can_run()
    local props = System.__properties
    if not props.__autoparry_enabled or System.__triggerbot.__enabled then return nil end
    local root = getRoot()
    -- canParryNow: alive in the round (or training), not Stunned, no DoNotParry.
    -- Checking only the flags let it keep parrying after you'd been hit and died.
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
    return root
end

-- ------------------------------------------------------------
-- Parry decision
-- ------------------------------------------------------------
-- Reads the ball as it is right now, without guessing its future path (the
-- turn rate a path guess needs arrives in jumps over the network, so a guess
-- built on it parried early or held until too late):
--   * heading: where it's flying relative to us (1 = straight at us, 0 =
--     sideways, -1 = straight away), and how close its current line passes us;
--   * the accuracy window (parry_distance) for when to parry.
-- Inside the window it parries once the ball is really coming: its line runs
-- through us, or it's heading in at least as straight as the anti curve setting
-- asks. A ball being curved round (bait) is held until it turns in. Never while
-- it's flying away (curving back, or already past us), never once it has
-- already reached us, never a parry that would run out before it gets here.
local function ball_velocity(ball)
    local zoomies = ball:FindFirstChild('zoomies')
    return zoomies and zoomies.VectorVelocity or ball.AssemblyLinearVelocity
end

-- heading, miss (closest its straight line passes us), speed, distance
local function read_ball(ball, root)
    local velocity = ball_velocity(ball)
    local speed = velocity.Magnitude
    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    if speed < 1 or distance < 0.01 then return 0, math.huge, speed, distance end
    local heading = (velocity / speed):Dot(offset / distance)
    local miss = heading > 0 and distance * math.sqrt(math.max(0, 1 - heading * heading)) or math.huge
    return heading, miss, speed, distance
end

-- Higher ping reads the ball sooner, so it's a little more lenient.
local function curve_threshold()
    return math.clamp(APCfg.curve - math.min(getPing(), 400) / 1000 * 0.75, -1, 0.95)
end

-- Parry one ball if it's on us and really coming. Leaves the reason in
-- state.why for the Status tab.
local function try_parry_ball(ball, root, now, via)
    local props = System.__properties
    local state = get_ball_state(ball)
    if ball:GetAttribute('target') ~= LocalPlayer.Name then return false end
    local function hold(why) state.why = why; return false end

    -- One parry per pass: already parried this one, locked until the ball goes
    -- to someone else and comes back. Only spam and manual parry more.
    if state.pass_parried then return hold("parried this pass, waiting for next") end
    if props.__parried then return hold("phantom") end
    if parry_busy() then return hold("parry already up") end
    local tornado = Runtime:FindFirstChild('Tornado')
    if tornado and (now - props.__tornado_time) < (tornado:GetAttribute('TornadoTime') or 1) + 0.314159 then return hold("tornado") end
    if ball:FindFirstChild('ComboCounter') then return hold("combo") end
    if blocked_by_detection() then return hold("ability detected") end

    local heading, miss, speed, distance = read_ball(ball, root)
    if speed < 1 then return hold("ball not moving") end
    local ping_s = math.min(getPing(), 400) / 1000

    -- Instant retarget (inside close range, straight off the target change).
    -- The ball's velocity still points at its last holder at that moment, so
    -- heading can't be read yet; it parries if the ball is close enough to
    -- land within a parry's window. One parry per pass, so it can't double;
    -- further out it's left to the normal checks a frame later.
    if via == "instant retarget" then
        local eta = distance / speed
        if eta > APCfg.parry_window + ping_s then return hold("too far for instant") end
        state.parried, state.at = true, now
        state.pass_parried = true
        mark_parry(eta)
        ParryLog.source = via
        if try_ability() then log_send("ability") else System.parry.by_mode(getgenv().AutoParryMode) end
        ParryLog.source = nil
        state.why = "parried (instant)"
        return true
    end

    -- Already reached us this pass: it hit, or a parry is landing. Nothing left
    -- to parry; firing here was the "parried after getting hit".
    if distance <= APCfg.hit_radius then state.reached_at = now end
    if state.reached_at and now - state.reached_at < ping_s + 0.3 then return hold("already reached you") end

    if heading < 0 then return hold("flying away") end
    -- A ball that isn't heading straight in still has to bend round to reach us,
    -- so it travels further than the straight line: about the arc tangent to
    -- its heading that ends on us (d * angle / sin(angle)). Timing uses that, so
    -- a curving ball isn't parried early and left to land after the parry ends.
    -- Straight in (angle 0) it's just the distance, same as always.
    local angle = math.acos(math.clamp(heading, -1, 1))
    local path = angle < 0.01 and distance or distance * angle / math.sin(angle)
    if path > System.parry_distance(speed) then return hold("outside window") end
    -- A parry that would run out before the ball gets here is a wasted one.
    local eta = path / speed
    if eta > APCfg.parry_window + ping_s then return hold("too early") end
    -- Anti curve: how straight it has to be heading in, unless its line already
    -- runs through us. The further out it still is, the straighter: half a
    -- second out a ball aimed well off can still go anywhere (that's what bait
    -- is), so committing the parry then wastes it. Close in, the setting itself.
    local need = curve_threshold()
    local far = math.clamp((eta - ping_s - 0.15) / 0.3, 0, 1)
    need = need + (math.max(need, 0.85) - need) * far
    if miss > APCfg.hit_zone and heading < need then return hold("curving, waiting") end

    state.parried, state.at = true, now
    state.pass_parried = true
    mark_parry(eta)
    ParryLog.source = via or "auto parry"
    if try_ability() then log_send("ability") else System.parry.by_mode(getgenv().AutoParryMode) end
    ParryLog.source = nil
    state.why = "parried"
    return true
end

-- What the parry log records about the ball on us when a parry goes out.
ParryLog.describe = function()
    local root = getRoot()
    if not root then return {} end
    for _, ball in ipairs(get_live_balls()) do
        if ball:GetAttribute('target') == LocalPlayer.Name then
            local state = get_ball_state(ball)
            local heading, _, _, distance = read_ball(ball, root)
            return {pass = state.pass_id, dist = distance, heading = heading}
        end
    end
    return {}
end

-- Whether a return from a player `gap` studs away is too fast to react to: it
-- covers the gap in under a round trip (plus a couple of frames), so only a
-- parry that's already up can catch it. Slower returns, or ones they curve,
-- are left to the normal timing, which sees the real path; pre-parrying those
-- just runs out before the ball arrives and costs a second parry.
local function return_too_fast(gap, speed)
    local budget = getPing() / 1000 + System.__properties.__frame_dt * 2 + 0.02
    -- Each hit speeds the ball up a little.
    return gap / math.max(speed * 1.1, 1) <= budget
end

local function preparry_now()
    -- Remote only: a block-key press puts the game's own ~1.3s parry cooldown on
    -- you, so pre-parrying by key would burn it right before the ball arrives.
    if getgenv().AutoParryMode == "Keypress" or not remoteReady() then return false end
    if parry_busy() then return false end
    mark_parry()
    ParryLog.source = "pre-parry"
    System.parry.by_mode(getgenv().AutoParryMode)
    ParryLog.source = nil
    return true
end

-- Ball is on a player standing next to us and about to reach them, and their
-- return would be too fast to react to: put our parry up first. Only when
-- they're about to hit it, and only when reacting can't work, so one return
-- gets one parry.
local function try_preparry(ball, root)
    if not APCfg.preparry then return false end
    local target = ball:GetAttribute('target')
    if not target or target == '' or target == LocalPlayer.Name then return false end
    local their_root = character_root(target)
    if not their_root or (their_root.Position - root.Position).Magnitude > APCfg.close_range then return false end
    if (ball.Position - root.Position).Magnitude > APCfg.close_range * 1.5 then return false end
    local zoomies = ball:FindFirstChild('zoomies')
    local speed = zoomies and zoomies.VectorVelocity.Magnitude or 0
    local their_eta = (ball.Position - their_root.Position).Magnitude / math.max(speed, 1)
    if their_eta > 0.12 + getPing() / 1000 then return false end
    if not return_too_fast((their_root.Position - root.Position).Magnitude, speed) then return false end
    if blocked_by_detection() then return false end
    if not preparry_now() then return false end
    -- Counts as the parry for this ball's next pass at us, so the real pass
    -- doesn't get a second one on top.
    get_ball_state(ball).preparried = true
    return true
end

function System.autoparry.step()
    local props = System.__properties
    local root = autoparry_can_run()
    if not root then return end

    local now = tick()
    for _, ball in ipairs(get_live_balls()) do
        if ball:FindFirstChild('AeroDynamicSlashVFX') then
            ball.AeroDynamicSlashVFX:Destroy(); props.__tornado_time = now
        end
        if not try_parry_ball(ball, root, now) then
            try_preparry(ball, root)
        end
    end
end

-- Straight from the ball's target change: runs the same decision a frame
-- sooner, inside close range where that frame matters. It's the same heading-
-- aware check as the frame loop, so a ball still flying to its last holder is
-- left alone instead of getting an early parry that runs out.
function System.autoparry.on_retarget(ball)
    if not APCfg.instant then return end
    local root = autoparry_can_run()
    if not root or (root.Position - ball.Position).Magnitude > APCfg.close_range then return end
    pcall(try_parry_ball, ball, root, tick(), "instant retarget")
end

-- Our own parry landed: stay locked until the ball actually leaves us.
Remotes.ParrySuccess.OnClientEvent:Connect(parry_landed)

Remotes.ParrySuccessAll.OnClientEvent:Connect(function()
    if System.__properties.__grab_animation then pcall(function() System.__properties.__grab_animation:Stop() end) end
end)

function System.autoparry.start()
    if System.__properties.__connections.__autoparry then return end
    local last_error
    System.__properties.__connections.__autoparry = RunService.PreSimulation:Connect(function(dt)
        if dt then System.__properties.__frame_dt = dt end
        local ok, err = pcall(System.autoparry.step)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] auto parry: " .. tostring(err))
        end
    end)
end

function System.autoparry.stop()
    if System.__properties.__connections.__autoparry then
        System.__properties.__connections.__autoparry:Disconnect()
        System.__properties.__connections.__autoparry = nil
    end
end

-- ============================================================
-- SPAM ENGINE (MANUAL + AUTO)
-- ============================================================
-- One engine drives both. It ticks at three points of every frame
-- (PreSimulation, Heartbeat, PreRender) so parries are spread through the frame
-- instead of dumped at one point, starts a burst on the very first tick, and
-- uses System.parry.fast, which reuses the frame's curve/packet/token.
System.manual_spam = {}
System.auto_spam = {}
local macroAnimFix = false
local ManualSpam = {rate = 300}     -- parries per second
-- Auto spam fires only while it detects a clash: the ball bouncing between you
-- and one other player who's close, read from the ball's recent target swaps
-- (plus close-range parries by that player). Optionally also at point blank.
local AutoSpam = {
    rate = 250,
    clash_range = 20,       -- max studs between you and them
    clash_swaps = 2,        -- hand-offs between you and them in one run
    clash_window = 0.5,     -- max seconds between hand-offs
    react_margin = 0.03,    -- seconds on top of ping (a couple of frames) a reactive parry needs
    point_blank = false,
    point_blank_range = 14, -- studs
    linger = 0.2,           -- keep going this long after the last detection
    active_until = 0,
    reason = nil,
}
local SPAM_MAX_PER_TICK = 40

function System.manual_spam.start() System.__properties.__manual_spam_enabled = true end
function System.manual_spam.stop() System.__properties.__manual_spam_enabled = false end

local function spam_fire(manual)
    if getgenv().ManualSpamMode == "Keypress" then
        System.parry.keypress()
    else
        System.parry.fast()
        if getgenv().ManualSpamAnimationFix and macroAnimFix then
            -- Manual spam is held for a while: restarting the grab every few
            -- frames meant you only ever saw the start of it. Each swing now
            -- plays out before the next. Auto spam bursts are short, so it keeps
            -- the snappier one.
            pcall(manual and System.animation.play_grab_parry_full or System.animation.play_grab_parry)
        end
    end
end

-- The ball's recent owners, newest first: one entry per change of hands, with
-- blank targets dropped (the game can clear the target between owners) and
-- repeats collapsed. t is when that player got the ball.
local function ball_owners(state)
    local owners = {}
    for i = #state.swaps, 1, -1 do
        local s = state.swaps[i]
        if type(s.to) == 'string' and s.to ~= '' then
            local last = owners[#owners]
            if last and last.name == s.to then
                last.t = s.t
            else
                owners[#owners + 1] = {name = s.to, t = s.t}
            end
        end
    end
    return owners
end

-- A clash is the ball going back and forth between you and one player standing
-- close. Counts the hand-offs between the two of you in one unbroken run and
-- engages once that reaches the "clash hits" slider. Each hand-off has to come
-- within the clash window of the previous one; a long hold (the ball flying in
-- from someone far away) can start a run but nothing before it counts. Only
-- real hand-offs count: one parry is one hit, never two.
-- How fast a return has to be before one reactive parry can't keep up.
local function reaction_budget()
    return math.min(getPing(), 400) / 1000 + AutoSpam.react_margin
end

local function detect_clash(ball, root, now)
    local owners = ball_owners(get_ball_state(ball))
    local newest, second = owners[1], owners[2]
    -- In a real clash every hand-off is quick too, not just the distance: each
    -- has to come within a couple of reaction times (capped by the window).
    local quick = math.min(AutoSpam.clash_window, reaction_budget() * 2.5)
    if not second or now - newest.t > quick then return nil end
    local me = LocalPlayer.Name
    local opponent
    if newest.name == me then opponent = second.name
    elseif second.name == me then opponent = newest.name
    else return nil end -- ball isn't with you or them right now

    local hits = 0
    for i = 1, #owners - 1 do
        local cur, prev = owners[i], owners[i + 1]
        local alternates = (cur.name == me and prev.name == opponent) or (cur.name == opponent and prev.name == me)
        if not alternates then break end
        if cur.t - prev.t > quick then break end
        hits = hits + 1
    end
    if hits < AutoSpam.clash_swaps then return nil end

    local their_root = character_root(opponent)
    if not their_root then return nil end
    local gap = (their_root.Position - root.Position).Magnitude
    if gap > AutoSpam.clash_range then return nil end
    if (ball.Position - root.Position).Magnitude > AutoSpam.clash_range * 1.5 then return nil end
    -- Only a real clash: the ball crosses the gap between you faster than a
    -- reactive parry can answer (ping + a little). A normal rally with someone
    -- nearby is slower than that, auto parry handles each pass with one
    -- parry, and spamming it was the "spam for no reason".
    local speed = ball_velocity(ball).Magnitude
    if gap / math.max(speed, 1) > reaction_budget() then return nil end
    return ("clash vs %s (%d hits)"):format(opponent, hits)
end

-- Ball on you, right on top of you, and actually coming at you.
local function detect_point_blank(ball, root)
    if not AutoSpam.point_blank or ball:GetAttribute('target') ~= LocalPlayer.Name then return nil end
    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    if distance > AutoSpam.point_blank_range then return nil end
    local zoomies = ball:FindFirstChild('zoomies')
    local velocity = zoomies and zoomies.VectorVelocity or ball.AssemblyLinearVelocity
    if distance > 1 and velocity:Dot(offset.Unit) <= 0 then return nil end
    -- Same rule as clashes: only when it's on you faster than you could react.
    if distance / math.max(velocity.Magnitude, 1) > reaction_budget() then return nil end
    return "point blank"
end

-- Lobby training or lobby parry: auto spam never runs there.
local function in_training()
    if LocalPlayer:GetAttribute("LobbyTraining") or LocalPlayer:GetAttribute("LobbyParry") then return true end
    local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
    return char ~= nil and dead ~= nil and char.Parent == dead
end

-- Once per frame: decide whether auto spam should be firing.
local function auto_spam_evaluate()
    if not System.__properties.__auto_spam_enabled then
        AutoSpam.active_until, AutoSpam.reason = 0, nil
        return
    end
    local now = os.clock()
    local root = getRoot()
    if root and not root:FindFirstChild('SingularityCape') and canParryNow() and not blocked_by_detection()
        and not in_training() then
        for _, ball in ipairs(get_live_balls()) do
            local reason = detect_clash(ball, root, now) or detect_point_blank(ball, root)
            if reason then
                AutoSpam.active_until = now + AutoSpam.linger
                AutoSpam.reason = reason
                return
            end
        end
    end
    if now >= AutoSpam.active_until then AutoSpam.reason = nil end
end

function System.auto_spam.status()
    if not System.__properties.__auto_spam_enabled then return "off" end
    if os.clock() < AutoSpam.active_until then return "SPAMMING (" .. tostring(AutoSpam.reason or "clash") .. ")" end
    return "watching for clashes"
end

local spam_acc, spam_last, spam_active = 0, os.clock(), false
local function spam_tick()
    local now = os.clock()
    local elapsed = math.min(now - spam_last, 0.1)
    spam_last = now
    local props = System.__properties
    local rate, source
    if props.__manual_spam_enabled then
        rate, source = ManualSpam.rate, "manual spam"
    elseif props.__auto_spam_enabled and now < AutoSpam.active_until then
        rate, source = AutoSpam.rate, "auto spam"
    end
    if not rate or not LocalPlayer.Character then
        spam_acc, spam_active = 0, false
        return
    end
    local interval = 1 / math.max(rate, 1)
    if spam_active then
        spam_acc = spam_acc + elapsed
    else
        -- First tick of a burst fires right away instead of waiting an interval.
        spam_acc, spam_active = interval, true
    end
    local fires = math.min(math.floor(spam_acc / interval), SPAM_MAX_PER_TICK)
    if fires > 0 then
        spam_acc = spam_acc - fires * interval
        ParryLog.source = source
        local manual = source == "manual spam"
        for _ = 1, fires do spam_fire(manual) end
        ParryLog.source = nil
    end
    if spam_acc > interval * 4 then spam_acc = 0 end
end

do
    local last_error
    local function run(fn)
        local ok, err = pcall(fn)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] spam: " .. tostring(err))
        end
    end
    local conns = System.__properties.__connections
    conns.__spam_pre = RunService.PreSimulation:Connect(function()
        run(auto_spam_evaluate)
        run(spam_tick)
    end)
    conns.__spam_heartbeat = RunService.Heartbeat:Connect(function() run(spam_tick) end)
    pcall(function()
        conns.__spam_render = RunService.PreRender:Connect(function() run(spam_tick) end)
    end)
end

-- ============================================================
-- HEADLESS & KORBLOX
-- ============================================================
local Byte_Library = {}
function Byte_Library.Korblox(char)
    if not char then return end
    local leg = char:FindFirstChild("Right Leg"); if not leg then return end
    if not leg:FindFirstChild("KorbloxMesh") then
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
        local m = Instance.new("SpecialMesh"); m.Name = "KorbloxMesh"
        m.MeshId = "rbxassetid://902942096"; m.TextureId = "rbxassetid://902843398"
        m.Offset = Vector3.new(0, 0.7, 0); m.Parent = leg
    end
end
function Byte_Library.Restore_Leg(char)
    if not char then return end
    local leg = char:FindFirstChild("Right Leg"); if not leg then return end
    for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
end
function Byte_Library.Headless(char)
    if not char then return end
    local head = char:FindFirstChild("Head"); if not head then return end
    head.Transparency = 1
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = 1
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            if not child:GetAttribute("OriginalScale") then
                child:SetAttribute("OriginalScale", child.Scale); child.Scale = Vector3.new(0, 0, 0)
            end
        end
    end
end
function Byte_Library.Restore_Head(char)
    if not char then return end
    local head = char:FindFirstChild("Head"); if not head then return end
    head.Transparency = 0
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = 0
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            local orig = child:GetAttribute("OriginalScale")
            if orig then child.Scale = orig; child:SetAttribute("OriginalScale", nil) end
        end
    end
end
local function ApplyHeadlessKorblox()
    local char = LocalPlayer.Character; if not char then return end
    if System.__properties.__headless_enabled then Byte_Library.Headless(char) end
    if System.__properties.__korblox_enabled then Byte_Library.Korblox(char) end
end
LocalPlayer.CharacterAdded:Connect(function(char) task.wait(0.5); ApplyHeadlessKorblox() end)


-- ============================================================
-- MOBILE BUTTONS
-- ============================================================
local function create_mobile_button(name, position_y, color, x_pos)
    local gui = Instance.new('ScreenGui')
    gui.Name = 'BladeBall_' .. name .. '_Mobile'; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 9998; gui.Parent = CoreGui
    local button = Instance.new('TextButton')
    button.Size = UDim2.new(0, 130, 0, 55)
    button.Position = UDim2.new(x_pos or 0.15, 0, position_y, 0)
    button.BackgroundTransparency = 1; button.AnchorPoint = Vector2.new(0.5, 0)
    button.Draggable = true; button.AutoButtonColor = false; button.ZIndex = 2
    local bg = Instance.new('Frame'); bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(40, 40, 40); bg.Parent = button
    Instance.new('UICorner', bg).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new('UIStroke', bg); stroke.Color = color
    stroke.Thickness = 2; stroke.Transparency = 0.3
    local text = Instance.new('TextLabel')
    text.Size = UDim2.new(1, 0, 1, 0); text.BackgroundTransparency = 1; text.Text = name
    text.Font = Enum.Font.GothamBold; text.TextSize = 17
    text.TextColor3 = Color3.fromRGB(255, 255, 255); text.ZIndex = 3; text.Parent = button
    button.Parent = gui
    return {gui = gui, button = button, text = text, bg = bg}
end

local function destroy_mobile_gui(gui_data) if gui_data and gui_data.gui then gui_data.gui:Destroy() end end


-- ============================================================
-- SKIN CHANGER
-- ============================================================
local SKIN_SAVE_FILE = SAVE_FOLDER .. "/skin.json"

local function loadSkinSave()
    local data = {}
    pcall(function()
        if isfile and isfile(SKIN_SAVE_FILE) then
            local decoded = HttpService:JSONDecode(readfile(SKIN_SAVE_FILE))
            if type(decoded) == "table" then data = decoded end
        end
    end)
    return data
end

local function saveSkinData()
    ensureSaveFolder()
    pcall(function()
        if writefile then
            writefile(SKIN_SAVE_FILE, HttpService:JSONEncode({swordModel = getgenv().swordModel or ""}))
        end
    end)
end

getgenv().saveLastEquippedSword = saveSkinData
local savedSkin = loadSkinSave()
getgenv().skinChanger = false
getgenv().skinChangerEnabled = false
getgenv().swordModel = savedSkin.swordModel or ""
getgenv().swordAnimations = savedSkin.swordModel or ""
getgenv().swordFX = savedSkin.swordModel or ""
getgenv().slashName = "SlashEffect"

task.spawn(function()
    -- Wait until the user actually enables skin changer before doing any
    -- getconnections calls — those loops were causing kicks while standing still.
    while not getgenv().skinChangerEnabled do task.wait(1) end

    local rs = game:GetService("ReplicatedStorage")
    local swordInstancesInstance = rs:WaitForChild("Shared", 9e9):WaitForChild("ReplicatedInstances", 9e9):WaitForChild("Swords", 9e9)
    local swordInstances = require(swordInstancesInstance)
    local swordsController
    task.spawn(function()
        while task.wait(0.25) and not swordsController do
            local ok, conns = pcall(getconnections, rs.Remotes.FireSwordInfo.OnClientEvent)
            if ok and conns then
                for _, v in ipairs(conns) do
                    if v.Function and islclosure and islclosure(v.Function) then
                        local ok2, up = pcall(getupvalues, v.Function)
                        if ok2 and #up == 1 and type(up[1]) == "table" then swordsController = up[1]; break end
                    end
                end
            end
        end
    end)
    local function getSlashName(swordName)
        local ok, sln = pcall(function() return swordInstances:GetSword(swordName) end)
        return (ok and sln and sln.SlashName) or "SlashEffect"
    end
    local function refreshSlashName()
        local fxName = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
        if fxName ~= "" then getgenv().slashName = getSlashName(fxName)
        else getgenv().slashName = "SlashEffect" end
    end
    refreshSlashName()
    local function setSword()
        if not getgenv().skinChanger then return end
        if not LocalPlayer.Character then return end
        pcall(function()
            local f = rawget(swordInstances, "EquipSwordTo")
            if type(f) == "function" then
                local ups = getupvalues(f)
                for i = 1, #ups do if type(ups[i]) == "boolean" then setupvalue(f, i, false); break end end
            end
        end)
        pcall(function() swordInstances:EquipSwordTo(LocalPlayer.Character, getgenv().swordModel) end)
        task.spawn(function()
            local attempts = 0
            while not swordsController and attempts < 20 do task.wait(0.5); attempts = attempts + 1 end
            if not swordsController then return end
            pcall(function()
                if swordsController.SetSword then
                    swordsController:SetSword(getgenv().swordAnimations ~= "" and getgenv().swordAnimations or getgenv().swordModel)
                end
            end)
            pcall(function()
                local targetSword = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
                if rs.Remotes:FindFirstChild("FireSwordInfo") then rs.Remotes.FireSwordInfo:FireServer(targetSword) end
                if swordsController.currentSword ~= nil then pcall(function() swordsController.currentSword = targetSword end) end
                if swordsController.SwordFX ~= nil then pcall(function() swordsController.SwordFX = targetSword end) end
            end)
        end)
    end
    -- ========================================================================
    -- SKIN RENDERING -- resolver remap (completely different: no handler hooks)
    -- ========================================================================
    -- The old approach caught the game's five visual-effect handlers
    -- (ParrySuccessAll, ParryAttempt, ParrySuccess, PlaySound, PlayVisuals) with
    -- getconnections and replaced each one -- the loops that were causing kicks.
    -- This touches none of that. Every effect the game plays turns a sword *name*
    -- into its visual data through one shared resolver, Swords:GetSword (the same
    -- one this script already uses at load). We make that resolver hand back the
    -- chosen skin's data whenever it is asked for the sword we actually have
    -- equipped; the game's own, untouched effect code then renders the skin by
    -- itself. No getconnections on the effect remotes, nothing disabled, nothing
    -- added -- and it is a plain field write on a module table we legitimately
    -- require, not a closure hook, so there is no C/Lua-closure tell and nothing
    -- for a hook scan to find. The connection list stays a clean client's.

    -- The server fires our effects under the sword we really have equipped, so
    -- remap only that name; every other player's sword resolves untouched.
    local function isOurEquippedSword(name)
        if type(name) ~= "string" or name == "" then return false end
        return name == LocalPlayer:GetAttribute("CurrentlyEquippedSword")
            or name == getgenv().swordModel
    end

    -- Swap the resolver in place on the required module table. require() hands
    -- every script the same cached table, so the game's effect code reads this
    -- raw field too. We call the original for the real lookup -- and crucially
    -- recurse the real one under the SKIN'S name, so the returned data is a
    -- genuine game sword-data table (right SlashName / AnimationType / fields),
    -- never a hand-built one that would read as foreign.
    pcall(function()
        local realGetSword = swordInstances.GetSword
        if type(realGetSword) == "function" then
            rawset(swordInstances, "GetSword", function(self, name, ...)
                if getgenv().skinChanger then
                    local fx = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
                    if fx ~= "" and fx ~= name and isOurEquippedSword(name) then
                        local ok, skinData = pcall(realGetSword, self, fx, ...)
                        if ok and type(skinData) == "table" then return skinData end
                    end
                end
                return realGetSword(self, name, ...)
            end)
        end
    end)
    getgenv().updateSword = function()
        refreshSlashName()
        if getgenv().skinChanger and getgenv().swordModel ~= "" then saveSkinData() end
        setSword()
    end
    task.spawn(function()
        while task.wait(1) do
            if getgenv().skinChanger and getgenv().swordModel ~= "" then
                local char = LocalPlayer.Character
                if char then
                    if LocalPlayer:GetAttribute("CurrentlyEquippedSword") ~= getgenv().swordModel then setSword() end
                    if not char:FindFirstChild(getgenv().swordModel) then setSword() end
                    for _, v in pairs(char:GetChildren()) do
                        if v:IsA("Model") and v.Name ~= getgenv().swordModel then v:Destroy() end
                        task.wait()
                    end
                end
            end
        end
    end)
    -- Re-equip the chosen sword after a respawn, once the game has given back the real one.
    LocalPlayer.CharacterAdded:Connect(function()
        if not getgenv().skinChanger then return end
        task.wait(2.5)
        if getgenv().skinChanger then pcall(function() getgenv().updateSword() end) end
    end)
end)

-- ============================================================
-- AVATAR CHANGER
-- ============================================================
local __players = cloneref(game:GetService('Players'))
local __localplayer = __players.LocalPlayer

local function saveOriginalAppearance()
    if _G.OriginalAppearance then return end
    local char = __localplayer.Character; if not char then return end
    _G.OriginalAppearance = {Face = nil, Shirt = nil, Pants = nil, BodyColors = nil, HeadMesh = nil, Accessories = {}, CharacterMeshes = {}}
    local head = char:FindFirstChild("Head")
    if head then
        local face = head:FindFirstChildOfClass("Decal"); if face then _G.OriginalAppearance.Face = face.Texture end
        local headMesh = head:FindFirstChildOfClass("SpecialMesh"); if headMesh then _G.OriginalAppearance.HeadMesh = headMesh:Clone() end
    end
    local shirt = char:FindFirstChildOfClass("Shirt"); if shirt then _G.OriginalAppearance.Shirt = shirt.ShirtTemplate end
    local pants = char:FindFirstChildOfClass("Pants"); if pants then _G.OriginalAppearance.Pants = pants.PantsTemplate end
    local bc = char:FindFirstChildOfClass("BodyColors")
    if bc then
        _G.OriginalAppearance.BodyColors = {HeadColor3 = bc.HeadColor3, LeftArmColor3 = bc.LeftArmColor3, RightArmColor3 = bc.RightArmColor3, LeftLegColor3 = bc.LeftLegColor3, RightLegColor3 = bc.RightLegColor3, TorsoColor3 = bc.TorsoColor3}
    end
    for _, obj in ipairs(char:GetChildren()) do
        if obj:IsA("Accessory") or obj:IsA("Accoutrement") then table.insert(_G.OriginalAppearance.Accessories, obj:Clone())
        elseif obj:IsA("CharacterMesh") then table.insert(_G.OriginalAppearance.CharacterMeshes, obj:Clone()) end
    end
end

local function restoreOriginalAppearance()
    local char = __localplayer.Character; if not char or not _G.OriginalAppearance then return end
    pcall(function()
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
        local head = char:FindFirstChild("Head")
        if head then
            local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
            if _G.OriginalAppearance.Face then
                local newFace = Instance.new("Decal"); newFace.Name = "face"; newFace.Texture = _G.OriginalAppearance.Face; newFace.Parent = head
            end
            local headMesh = head:FindFirstChildOfClass("SpecialMesh"); if headMesh then headMesh:Destroy() end
            if _G.OriginalAppearance.HeadMesh then _G.OriginalAppearance.HeadMesh:Clone().Parent = head end
        end
        if _G.OriginalAppearance.Shirt then
            local shirt = Instance.new("Shirt"); shirt.Name = "Shirt"; shirt.ShirtTemplate = _G.OriginalAppearance.Shirt; shirt.Parent = char
        end
        if _G.OriginalAppearance.Pants then
            local pants = Instance.new("Pants"); pants.Name = "Pants"; pants.PantsTemplate = _G.OriginalAppearance.Pants; pants.Parent = char
        end
        if _G.OriginalAppearance.BodyColors then
            local bc = Instance.new("BodyColors")
            for k, v in pairs(_G.OriginalAppearance.BodyColors) do bc[k] = v end
            bc.Parent = char
        end
        for _, mesh in ipairs(_G.OriginalAppearance.CharacterMeshes) do mesh:Clone().Parent = char end
        for _, acc in ipairs(_G.OriginalAppearance.Accessories) do acc:Clone().Parent = char end
    end)
end

local function attachAccessoryManually(char, acc)
    local handle = acc:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return end
    local accAttachment = handle:FindFirstChildOfClass("Attachment")
    local charAttachment
    if accAttachment then
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") then
                charAttachment = part:FindFirstChild(accAttachment.Name)
                if charAttachment then break end
            end
        end
    end
    if charAttachment then
        acc.Parent = char; handle.CanCollide = false; handle.Anchored = false
        local part = charAttachment.Parent
        if charAttachment:IsA("Attachment") and accAttachment then
            handle.CFrame = part.CFrame * charAttachment.CFrame * accAttachment.CFrame:Inverse()
        else handle.CFrame = part.CFrame * CFrame.new(0, 0, 0) end
        local weld = Instance.new("Weld"); weld.Name = "AccessoryWeld"; weld.Part0 = handle; weld.Part1 = part
        weld.C0 = accAttachment and accAttachment.CFrame or CFrame.new(0, 0.6, 0)
        weld.C1 = charAttachment:IsA("Attachment") and charAttachment.CFrame or CFrame.new()
        weld.Parent = handle
    else
        local part = char:FindFirstChild("Head")
        if part then
            acc.Parent = char; handle.CanCollide = false; handle.Anchored = false
            handle.CFrame = part.CFrame * CFrame.new(0, 0.6, 0)
            local weld = Instance.new("Weld"); weld.Name = "AccessoryWeld"; weld.Part0 = handle; weld.Part1 = part
            weld.C0 = CFrame.new(0, 0.6, 0); weld.C1 = CFrame.new(); weld.Parent = handle
        else acc.Parent = char end
    end
end

local function applyAvatarLocally(userId)
    local char = __localplayer.Character; if not char then return end
    local success, model = pcall(function() return __players:CreateHumanoidModelFromUserId(userId) end)
    if not success or not model then return end
    pcall(function()
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
        local head = char:FindFirstChild("Head")
        local modelHead = model:FindFirstChild("Head")
        if head and modelHead then
            local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
            local modelFace = modelHead:FindFirstChildOfClass("Decal"); if modelFace then modelFace:Clone().Parent = head end
            local headMesh = head:FindFirstChildOfClass("SpecialMesh")
            local modelMesh = modelHead:FindFirstChildOfClass("SpecialMesh")
            if modelMesh then if headMesh then headMesh:Destroy() end; modelMesh:Clone().Parent = head
            elseif headMesh then headMesh:Destroy() end
            head.Size = modelHead.Size; head.Color = modelHead.Color
        end
        for _, obj in ipairs(model:GetChildren()) do
            if obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("ShirtGraphic") or obj:IsA("CharacterMesh") then obj:Clone().Parent = char
            elseif obj:IsA("Accessory") or obj:IsA("Accoutrement") then pcall(function() attachAccessoryManually(char, obj:Clone()) end) end
        end
        model:Destroy()
    end)
end

local __avatar_changer_target = ""
local __avatar_changer_enabled = false

local function __resolveTargetId(value)
    if value == nil or value == "" then return nil end
    local id = tonumber(value); if id then return id end
    local ok, resolved = pcall(function() return __players:GetUserIdFromNameAsync(value) end)
    if ok and resolved then return resolved end
    return nil
end

-- ============================================================
-- ABILITY ESP
-- ============================================================
local abilityEspBillboards = {}
local abilityEspConnections = {}
local abilityEspPlayerAddedConnection = nil

-- Live-editable Ability ESP settings. The per-player update loop reads these
-- every frame, so changing any of them from the menu takes effect instantly.
local AbilityESPConfig = {
    Color = Color3.fromRGB(255, 255, 255),
    TextSize = 14,
    Height = 3.5,          -- studs above the head
    ShowName = true,       -- show the player's display name
    ShowDistance = false,  -- append distance in studs
    OnlyWithAbility = false, -- only show players who have an ability equipped
    MaxDistance = 0,       -- 0 = unlimited; otherwise hide beyond this many studs
}

local function create_ability_esp_for_player(player)
    task.spawn(function()
        local character = player.Character
        while not character or not character.Parent do task.wait(0.5); character = player.Character end
        local head = character:WaitForChild('Head', 10)
        if not head or not getgenv().AbilityESP then return end
        local existing = head:FindFirstChild('AbilityESPGui'); if existing then existing:Destroy() end
        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'AbilityESPGui'; billboard.Adornee = head
        billboard.Size = UDim2.new(0, 220, 0, 60)
        billboard.StudsOffset = Vector3.new(0, AbilityESPConfig.Height, 0); billboard.AlwaysOnTop = true
        billboard.Parent = head
        local label = Instance.new('TextLabel')
        label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1
        label.TextColor3 = AbilityESPConfig.Color; label.TextSize = AbilityESPConfig.TextSize
        label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
        label.RichText = true; label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center; label.Parent = billboard
        label.Visible = false
        abilityEspBillboards[player] = label
        local humanoid = character:FindFirstChild('Humanoid')
        if humanoid then humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
        local heartbeatConnection
        heartbeatConnection = RunService.Heartbeat:Connect(function()
            if not (character and character.Parent) then
                if heartbeatConnection then heartbeatConnection:Disconnect() end
                pcall(function() billboard:Destroy() end)
                abilityEspBillboards[player] = nil; return
            end
            if not getgenv().AbilityESP then label.Visible = false; return end

            local ability = player:GetAttribute('EquippedAbility')

            -- Distance / visibility filters.
            local myRoot = getRoot()
            local dist
            if myRoot then dist = (myRoot.Position - head.Position).Magnitude end
            if AbilityESPConfig.MaxDistance > 0 and dist and dist > AbilityESPConfig.MaxDistance then
                label.Visible = false; return
            end
            if AbilityESPConfig.OnlyWithAbility and not ability then
                label.Visible = false; return
            end

            -- Live-apply appearance.
            label.TextColor3 = AbilityESPConfig.Color
            label.TextSize = AbilityESPConfig.TextSize
            billboard.StudsOffset = Vector3.new(0, AbilityESPConfig.Height, 0)
            label.Visible = true

            local parts = {}
            if AbilityESPConfig.ShowName then table.insert(parts, player.DisplayName) end
            if ability then table.insert(parts, '[' .. ability .. ']') end
            if AbilityESPConfig.ShowDistance and dist then table.insert(parts, string.format('%.0fm', dist)) end
            if #parts == 0 then table.insert(parts, player.DisplayName) end
            label.Text = '<b>' .. table.concat(parts, ' ') .. '</b>'
        end)
        abilityEspConnections[player] = heartbeatConnection
    end)
end

local function add_ability_esp_player(player)
    if player == LocalPlayer then return end
    if abilityEspConnections[player] then
        pcall(function() abilityEspConnections[player]:Disconnect() end)
        abilityEspConnections[player] = nil
    end
    player.CharacterAdded:Connect(function() create_ability_esp_for_player(player) end)
    if player.Character then task.spawn(function() create_ability_esp_for_player(player) end) end
end

function start_ability_esp()
    if abilityEspPlayerAddedConnection and next(abilityEspConnections) then return end
    getgenv().AbilityESP = true
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then add_ability_esp_player(player) end
    end
    if not abilityEspPlayerAddedConnection then
        abilityEspPlayerAddedConnection = Players.PlayerAdded:Connect(function(player)
            if getgenv().AbilityESP then add_ability_esp_player(player) end
        end)
    end
end

function stop_ability_esp()
    if not getgenv().AbilityESP then return end
    getgenv().AbilityESP = false
    if abilityEspPlayerAddedConnection then
        pcall(function() abilityEspPlayerAddedConnection:Disconnect() end)
        abilityEspPlayerAddedConnection = nil
    end
    for _, connection in pairs(abilityEspConnections) do pcall(function() connection:Disconnect() end) end
    abilityEspConnections = {}
    for _, label in pairs(abilityEspBillboards) do
        pcall(function() if label and label.Parent then label.Parent:Destroy() end end)
    end
    abilityEspBillboards = {}
end

-- ============================================================
-- BALL VELOCITY GUI
-- ============================================================
function System.create_ball_velocity_gui()
    if System.__properties.__ball_velocity_gui then System.__properties.__ball_velocity_gui.gui:Destroy() end
    local gui = Instance.new("ScreenGui"); gui.Name = "BallVelocityGUI"; gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    local frame = Instance.new("Frame"); frame.Size = UDim2.new(0, 200, 0, 75)
    frame.Position = UDim2.new(0, 10, 0.80, 0); frame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    frame.BackgroundTransparency = 0.4; frame.BorderSizePixel = 0; frame.Active = true; frame.Draggable = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(255,255,255); stroke.Thickness = 2
    local title = Instance.new("TextLabel", frame); title.Size = UDim2.new(1,0,0,18); title.Position = UDim2.new(0,0,0,5)
    title.BackgroundTransparency = 1; title.Text = "Ball Status"; title.TextColor3 = Color3.fromRGB(255,255,255)
    title.Font = Enum.Font.GothamBold; title.TextSize = 13
    local cl = Instance.new("TextLabel", frame); cl.Size = UDim2.new(1,-10,0,22); cl.Position = UDim2.new(0,5,0,24)
    cl.BackgroundTransparency = 1; cl.Text = "Current: 0"; cl.TextColor3 = Color3.fromRGB(255,255,255)
    cl.Font = Enum.Font.GothamBold; cl.TextSize = 15; cl.TextXAlignment = Enum.TextXAlignment.Left
    local pl = Instance.new("TextLabel", frame); pl.Size = UDim2.new(1,-10,0,22); pl.Position = UDim2.new(0,5,0,46)
    pl.BackgroundTransparency = 1; pl.Text = "Peak: 0"; pl.TextColor3 = Color3.fromRGB(255,255,255)
    pl.Font = Enum.Font.GothamBold; pl.TextSize = 15; pl.TextXAlignment = Enum.TextXAlignment.Left
    frame.Parent = gui; gui.Parent = CoreGui
    System.__properties.__ball_velocity_gui = {gui=gui, frame=frame, currentSpeedLabel=cl, peakSpeedLabel=pl}
end

function System.update_ball_velocity()
    if not System.__properties.__ball_velocity_enabled or not System.__properties.__ball_velocity_gui then return end
    local ball = System.ball.get()
    if not ball then System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = "Current: 0"; return end
    local ballId = ball:GetFullName()
    if ballId ~= System.__properties.__last_ball_id then System.__properties.__peak_velocity = 0; System.__properties.__last_ball_id = ballId end
    local zoomies = ball:FindFirstChild('zoomies')
    if not zoomies then System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = "Current: 0"; return end
    local speed = zoomies.VectorVelocity.Magnitude
    if speed > System.__properties.__peak_velocity then System.__properties.__peak_velocity = speed end
    local color = Color3.fromRGB(255, 255, 0)
    if speed > 2000 then color = Color3.fromRGB(255, 0, 0)
    elseif speed > 1500 then color = Color3.fromRGB(255, 165, 0)
    elseif speed > 1000 then color = Color3.fromRGB(255, 215, 0) end
    local peakColor = Color3.fromRGB(255, 255, 0)
    if System.__properties.__peak_velocity > 2000 then peakColor = Color3.fromRGB(255, 0, 0)
    elseif System.__properties.__peak_velocity > 1500 then peakColor = Color3.fromRGB(255, 165, 0)
    elseif System.__properties.__peak_velocity > 1000 then peakColor = Color3.fromRGB(255, 215, 0) end
    System.__properties.__ball_velocity_gui.currentSpeedLabel.RichText = true
    System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = string.format("Current: <font color='#%02x%02x%02x'>%.1f</font>", math.floor(color.R*255), math.floor(color.G*255), math.floor(color.B*255), speed)
    System.__properties.__ball_velocity_gui.peakSpeedLabel.RichText = true
    System.__properties.__ball_velocity_gui.peakSpeedLabel.Text = string.format("Peak: <font color='#%02x%02x%02x'>%.1f</font>", math.floor(peakColor.R*255), math.floor(peakColor.G*255), math.floor(peakColor.B*255), System.__properties.__peak_velocity)
end


-- ============================================================
-- PING GUI
-- ============================================================
local PingGui = Instance.new("ScreenGui")
PingGui.Name = "BladeBallPing"; PingGui.ResetOnSpawn = false
PingGui.IgnoreGuiInset = true; PingGui.DisplayOrder = 999; PingGui.Enabled = false
local PingFrame = Instance.new("Frame", PingGui)
PingFrame.Size = UDim2.new(0, 110, 0, 35); PingFrame.Position = UDim2.new(0, 15, 0.88, 0)
PingFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 10); PingFrame.BackgroundTransparency = 0.3
PingFrame.BorderSizePixel = 0; PingFrame.Active = true; PingFrame.Draggable = true
Instance.new("UICorner", PingFrame).CornerRadius = UDim.new(0, 8)
Instance.new("UIStroke", PingFrame).Color = Color3.fromRGB(60, 60, 60)
local PingLabel = Instance.new("TextLabel", PingFrame)
PingLabel.Size = UDim2.new(1, 0, 1, 0); PingLabel.Text = "Ping: 0ms"
PingLabel.TextColor3 = Color3.fromRGB(255, 255, 255); PingLabel.BackgroundTransparency = 1
PingLabel.Font = Enum.Font.GothamBold; PingLabel.TextSize = 14; PingLabel.RichText = true
PingLabel.TextXAlignment = Enum.TextXAlignment.Center
PingGui.Parent = CoreGui

task.spawn(function()
    while task.wait(0.5) do
        if Library.Unloaded then break end
        if System.__properties.__show_ping then
            local ping = getPing()
            local color = Color3.fromRGB(0, 255, 0)
            if ping > 300 then color = Color3.fromRGB(255, 0, 0)
            elseif ping > 150 then color = Color3.fromRGB(255, 165, 0) end
            PingLabel.Text = string.format("Ping: <font color='#%s'>%dms</font>", color:ToHex(), ping)
        end
    end
end)

-- ============================================================
-- UI
-- ============================================================
local Tabs = {
    Status = Window:AddTab("Status", "gauge", "Live ball and parry info"),
    Parry = Window:AddTab("Auto Parry", "swords", "Auto parry, triggerbot and abilities"),
    Detection = Window:AddTab("Detection", "shield-alert", "Pause parrying during enemy abilities"),
    Spam = Window:AddTab("Spam", "zap", "Manual spam"),
    Player = Window:AddTab("Player", "user", "Avatar, cosmetics and movement"),
    Visuals = Window:AddTab("Visuals", "eye", "Overlays and ESP"),
    Misc = Window:AddTab("Misc", "wrench", "Skin changer and extras"),
}

-- STATUS TAB
local Overview = Tabs.Status:AddBigGroupbox({Name = "Overview", Description = "Updates while the menu is open", IconName = "gauge"})
local StatCards = Overview:AddStatCards("StatusCards", {
    Cards = {
        {Title = "Ball speed", Value = 0, Icon = "wind"},
        {Title = "Peak speed", Value = 0, Icon = "trending-up"},
        {Title = "Distance", Value = "-", Icon = "ruler"},
        {Title = "Parry range", Value = "-", Icon = "crosshair"},
        {Title = "Ping", Value = "0 ms", Icon = "wifi"},
        {Title = "Parries", Value = 0, Icon = "shield"},
    },
})
Overview:AddLabel("Version: " .. SCRIPT_VERSION, true)
local RemoteLabel = Overview:AddLabel("Remote: checking...", true)
local TargetLabel = Overview:AddLabel("Ball target: -", true)

local LogBox = Tabs.Status:AddLeftGroupbox("Parry log", "list")
LogBox:AddLabel("Every parry this copy sends: where it came from and which pass at you it was for. Two for the same pass are marked DOUBLE. Spam is only counted.", true)
local LogCounts = LogBox:AddLabel("Parries: 0  |  doubles: 0  |  spam: 0", true)
local LogLines = LogBox:AddLabel("(nothing yet)", true)
LogBox:AddButton({Text = "Clear log", Func = function()
    ParryLog.entries, ParryLog.total, ParryLog.doubles, ParryLog.spam = {}, 0, 0, 0
end})
local function parry_log_text()
    if #ParryLog.entries == 0 then return "(nothing yet)" end
    local now, lines = os.clock(), {}
    for i = #ParryLog.entries, 1, -1 do
        local e = ParryLog.entries[i]
        local where = e.pass and string.format("pass %d, %.0f studs, heading %.2f", e.pass, e.dist or 0, e.heading or 0)
            or "no ball on you"
        lines[#lines + 1] = string.format("%s%.1fs ago  %s (%s)  %s", e.double and "DOUBLE  " or "", now - e.t, e.src, e.how, where)
    end
    return table.concat(lines, "\n")
end
task.spawn(function()
    while task.wait(0.25) do
        if Library.Unloaded then break end
        if Library.Toggled then
            LogCounts:SetText(string.format("Parries: %d  |  doubles: %d  |  spam: %d", ParryLog.total, ParryLog.doubles, ParryLog.spam))
            LogLines:SetText(parry_log_text())
        end
    end
end)

local function remoteStatusText()
    if remoteReady() then return "Remote: ready, parries trigger the game's block action with camera-aimed curve" end
    return "Remote: no VirtualInputManager, can't trigger parries"
end

local status_peak, status_ball = 0, nil
task.spawn(function()
    while task.wait(0.1) do
        if Library.Unloaded then break end
        if Library.Toggled then
            local ball = System.ball.get()
            local root = getRoot()
            local speed = 0
            if ball ~= status_ball then status_ball = ball; status_peak = 0 end
            local zoomies = ball and ball:FindFirstChild('zoomies')
            if zoomies then speed = zoomies.VectorVelocity.Magnitude end
            if speed > status_peak then status_peak = speed end
            StatCards:SetValue("Ball speed", string.format("%.0f", speed))
            StatCards:SetValue("Peak speed", string.format("%.0f", status_peak))
            if ball and root then
                StatCards:SetValue("Distance", string.format("%.0f", (root.Position - ball.Position).Magnitude))
                StatCards:SetValue("Parry range", string.format("%.0f", System.parry_distance(speed)))
            else
                StatCards:SetValue("Distance", "-")
                StatCards:SetValue("Parry range", "-")
            end
            StatCards:SetValue("Ping", string.format("%d ms", getPing()))
            StatCards:SetValue("Parries", System.__properties.__total_parries)
            RemoteLabel:SetText(remoteStatusText())
            local target = ball and ball:GetAttribute('target')
            local text = "Ball target: " .. ((target == nil or target == "") and "-" or tostring(target))
            -- Live read of the ball: how straight it's heading at you (1 = dead
            -- on), how close its line passes you, and while it's on you what
            -- auto parry is doing with it and why.
            if ball and root and speed > 1 then
                local heading, miss = read_ball(ball, root)
                text = text .. string.format("  |  heading %.2f", heading)
                if miss < math.huge then text = text .. string.format("  |  line passes %.0f studs", miss) end
                local st = ball_state[ball]
                if target == LocalPlayer.Name and st and st.why then text = text .. "  |  auto parry: " .. st.why end
            end
            TargetLabel:SetText(text)
        end
    end
end)

-- AUTO PARRY TAB
local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {Text = "Auto parry", Default = false, Callback = function(v)
    System.__properties.__autoparry_enabled = v
    System.__properties.__play_animation = v
    if v then System.autoparry.start(); prime_remote() else System.autoparry.stop() end
    NotifyToggle("Auto Parry", v)
end}):AddKeyPicker("AutoParryKey", {Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry"})
AP:AddDropdown("ParryMode", {Text = "Parry mode", Values = {"Remote", "Keypress"}, Default = "Remote",
    Tooltip = "Remote fires the parry remote with your curve. Keypress presses the block key (F).",
    Callback = function(v) getgenv().AutoParryMode = v end})
AP:AddDropdown("CurveMode", {Text = "Curve mode", Values = System.__config.__curve_names, Default = "Camera",
    Callback = function(v)
        for i, n in ipairs(System.__config.__curve_names) do if n == v then System.__properties.__curve_mode = i; break end end
    end})
AP:AddSlider("Accuracy", {Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "Higher parries later (closer). Lower parries earlier (further away).",
    Callback = function(v) System.__properties.__accuracy_base = v; roll_accuracy() end})
AP:AddToggle("RandomAccuracy", {Text = "Randomize accuracy", Default = false,
    Tooltip = "Jitters accuracy around your current Accuracy setting each parry, to look less robotic.",
    Callback = function(v)
        System.__properties.__random_accuracy = v
        roll_accuracy() -- snaps back to the base value when turned off
        NotifyToggle("Randomize Accuracy", v)
    end})
AP:AddSlider("RandomAccuracyAmount", {Text = "Randomize amount", Default = 10, Min = 0, Max = 50, Rounding = 0, Suffix = " ±",
    Tooltip = "How far accuracy can swing above/below your setting, based on the current Accuracy value.",
    Callback = function(v) System.__properties.__random_accuracy_amount = v; roll_accuracy() end})
AP:AddToggle("PingCompensation", {Text = "Ping compensation", Default = true,
    Tooltip = "Parries earlier the higher your ping, by how far the ball moves in half a round trip.",
    Callback = function(v) System.__properties.__ping_compensation = v end})
AP:AddSlider("ExtraDistance", {Text = "Extra distance", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Callback = function(v) System.__properties.__extra_distance = v end})
AP:AddSlider("AntiCurve", {Text = "Anti curve", Default = 50, Min = 0, Max = 95, Rounding = 0, Suffix = "%",
    Tooltip = "How straight the ball has to be heading at you before it's parried (unless its line already runs through you). Higher waits out curves and bait longer; lower parries sooner. 0 only waits while it's flying away.",
    Callback = function(v) APCfg.curve = v / 100 end})
AP:AddSlider("CloseRange", {Text = "Close range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Tooltip = "Instant parry on retarget and pre-parry only work inside this distance.",
    Callback = function(v) APCfg.close_range = v end})
AP:AddToggle("InstantRetarget", {Text = "Instant parry on retarget", Default = true,
    Tooltip = "Inside close range, parries the moment the ball switches to you if it's close enough to land within a parry. Still one parry per pass.",
    Callback = function(v) APCfg.instant = v end})
AP:AddToggle("ClosePreParry", {Text = "Close-range pre-parry", Default = false,
    Tooltip = "Off by default. Parries ahead when a player next to you is about to hit the ball and a return would be too fast to react to. It's a guess: if they send it elsewhere or curve it, it was wasted. Auto spam is the better tool for clashes.",
    Callback = function(v) APCfg.preparry = v end})
AP:AddToggle("RandomCurve", {Text = "Random curve", Default = false, Callback = function(s)
    if s then
        if not System.__properties.__connections.__rc then
            System.__properties.__connections.__rc = RunService.PreSimulation:Connect(function()
                System.__properties.__curve_mode = math.random(1, #System.__config.__curve_names)
            end)
        end
    else
        if System.__properties.__connections.__rc then
            System.__properties.__connections.__rc:Disconnect()
            System.__properties.__connections.__rc = nil
        end
        -- Back to whatever the dropdown says.
        if Options.CurveMode then Options.CurveMode:SetValue(Options.CurveMode.Value) end
    end
end})
AP:AddToggle("CurveHotkeys", {Text = "Curve hotkeys (1-9)", Default = true,
    Tooltip = "Number keys 1-9 pick the curve mode.",
    Callback = function(v) System.__properties.__curve_hotkeys = v end})

local TB = Tabs.Parry:AddRightGroupbox("Triggerbot", "crosshair")
local function setTriggerbot(v)
    System.__properties.__triggerbot_enabled = v
    System.triggerbot.enable(v)
    if v then prime_remote() end
end
TB:AddToggle("Triggerbot", {Text = "Triggerbot", Default = false,
    Tooltip = "Parries the moment the ball targets you, at any distance. Overrides auto parry while on.",
    Callback = function(v)
        setTriggerbot(v)
        NotifyToggle("Triggerbot", v)
        if not isMobile then return end
        if v then
            if not System.__properties.__mobile_guis.triggerbot then
                local tb = create_mobile_button('Trigger', 0.20, Color3.fromRGB(255, 100, 0), 0.15)
                System.__properties.__mobile_guis.triggerbot = tb
                tb.button.MouseButton1Click:Connect(function()
                    setTriggerbot(not System.__properties.__triggerbot_enabled)
                    local on = System.__properties.__triggerbot_enabled
                    tb.text.Text = on and "ON" or "Trigger"
                    tb.text.TextColor3 = on and Color3.fromRGB(0, 255, 100) or Color3.fromRGB(255, 255, 255)
                    Notify("Triggerbot", on and "ON" or "OFF", 1.5)
                end)
            end
        else
            destroy_mobile_gui(System.__properties.__mobile_guis.triggerbot)
            System.__properties.__mobile_guis.triggerbot = nil
        end
    end}):AddKeyPicker("TriggerbotKey", {Default = "R", Mode = "Toggle", SyncToggleState = true, Text = "Triggerbot"})

local AB = Tabs.Parry:AddRightGroupbox("Abilities", "sparkles")
AB:AddToggle("AutoAbility", {Text = "Auto ability", Default = false,
    Tooltip = "Uses a ready deflect or slash ability instead of parrying.",
    Callback = function(v) System.__properties.__auto_ability_enabled = v end})
AB:AddToggle("CooldownProtection", {Text = "Cooldown protection", Default = false,
    Tooltip = "Uses a ready deflection ability (Raging, Rapture, Calming) instead of parrying.",
    Callback = function(v) System.__properties.__cooldown_protection = v end})

-- DETECTION TAB
local DL = Tabs.Detection:AddLeftGroupbox("Abilities", "shield-alert")
DL:AddToggle("DetInfinity", {Text = "Infinity detection", Default = false, Callback = function(v) System.__config.__detections.__infinity = v end})
DL:AddToggle("DetDeathSlash", {Text = "Death Slash detection", Default = false, Callback = function(v) System.__config.__detections.__deathslash = v end})
DL:AddToggle("DetTimeHole", {Text = "Time Hole detection", Default = false, Callback = function(v) System.__config.__detections.__timehole = v end})
DL:AddToggle("DetPhantom", {Text = "Anti-Phantom [BETA]", Default = false, Callback = function(v) System.__config.__detections.__phantom = v end})

local DR = Tabs.Detection:AddRightGroupbox("Slashes Of Fury", "swords")
DR:AddToggle("DetSlashes", {Text = "Slashes detection", Default = false, Callback = function(v) System.__config.__detections.__slashesoffury = v end})
DR:AddSlider("SlashesDelay", {Text = "Parry delay", Default = 0.05, Min = 0.05, Max = 0.25, Rounding = 2, Suffix = "s", Callback = function(v) parryDelay = v end})
DR:AddSlider("SlashesMax", {Text = "Max parry count", Default = 36, Min = 1, Max = 100, Rounding = 0, Callback = function(v) maxParryCount = v end})

-- SPAM TAB
local SP = Tabs.Spam:AddLeftGroupbox("Manual Spam", "zap")
SP:AddToggle("ManualSpam", {Text = "Manual spam", Default = false, Callback = function(v)
    if isMobile then
        -- On mobile the on-screen button is the real control. Arming the toggle
        -- only shows that button (OFF by default), so enabling the feature no
        -- longer starts spamming the moment you flip it — you tap the button to
        -- turn it on, and tap again to turn it off.
        if v then
            System.__properties.__manual_spam_enabled = false
            if not System.__properties.__mobile_guis.manual_spam then
                local sm = create_mobile_button('Spam', 0.35, Color3.fromRGB(255, 255, 255), 0.15)
                System.__properties.__mobile_guis.manual_spam = sm
                sm.button.MouseButton1Click:Connect(function()
                    System.__properties.__manual_spam_enabled = not System.__properties.__manual_spam_enabled
                    local on = System.__properties.__manual_spam_enabled
                    sm.text.Text = on and "ON" or "Spam"
                    sm.text.TextColor3 = on and Color3.fromRGB(0, 255, 100) or Color3.fromRGB(255, 255, 255)
                    Notify("Manual Spam", on and "ON" or "OFF", 1.5)
                end)
            end
        else
            System.__properties.__manual_spam_enabled = false
            destroy_mobile_gui(System.__properties.__mobile_guis.manual_spam)
            System.__properties.__mobile_guis.manual_spam = nil
        end
    else
        System.__properties.__manual_spam_enabled = v
        if v then prime_remote() end
    end
    NotifyToggle("Manual Spam", v)
end}):AddKeyPicker("ManualSpamKey", {Default = "E", Mode = "Hold", SyncToggleState = true, Text = "Manual spam"})
SP:AddDropdown("SpamMode", {Text = "Mode", Values = {"Remote", "Keypress"}, Default = "Remote", Callback = function(v) getgenv().ManualSpamMode = v end})
SP:AddSlider("SpamRate", {Text = "Spam rate", Default = 300, Min = 20, Max = 1000, Rounding = 0, Suffix = " /s",
    Tooltip = "Parries per second while spamming.",
    Callback = function(v) ManualSpam.rate = v end})
SP:AddToggle("SpamAnimFix", {Text = "Animation fix", Default = false, Callback = function(v)
    getgenv().ManualSpamAnimationFix = v
    macroAnimFix = v
end})

local AS = Tabs.Spam:AddRightGroupbox("Auto Spam", "activity")
AS:AddToggle("AutoSpam", {Text = "Auto spam", Default = false,
    Tooltip = "Spams only during a real clash: the ball going back and forth with a nearby player faster than one parry can react to. Normal rallies are left to auto parry. Never runs in training.",
    Callback = function(v)
        System.__properties.__auto_spam_enabled = v
        if v then prime_remote() else AutoSpam.active_until, AutoSpam.reason = 0, nil end
        NotifyToggle("Auto Spam", v)
    end})
local AutoSpamLabel = AS:AddLabel("Status: off", true)
AS:AddSlider("AutoSpamRate", {Text = "Spam rate", Default = 250, Min = 20, Max = 1000, Rounding = 0, Suffix = " /s",
    Tooltip = "Parries per second while a clash is detected.",
    Callback = function(v) AutoSpam.rate = v end})
AS:AddSlider("ClashRange", {Text = "Clash range", Default = 20, Min = 8, Max = 60, Rounding = 0, Suffix = " studs",
    Tooltip = "How close the other player has to be for the exchange to count as a clash.",
    Callback = function(v) AutoSpam.clash_range = v end})
AS:AddSlider("ClashSwaps", {Text = "Clash hits", Default = 2, Min = 1, Max = 6, Rounding = 0, Suffix = " hits",
    Tooltip = "Hand-offs between you and the same nearby player before spamming. 1 = as soon as you send it to them, 2 = once they send it back, and so on.",
    Callback = function(v) AutoSpam.clash_swaps = v end})
AS:AddSlider("ClashWindow", {Text = "Clash window", Default = 0.5, Min = 0.2, Max = 2, Rounding = 2, Suffix = "s",
    Tooltip = "Max time between hand-offs for them to count as one exchange. Raise it if slower clashes aren't picked up.",
    Callback = function(v) AutoSpam.clash_window = v end})
AS:AddToggle("PointBlankSpam", {Text = "Point-blank spam", Default = false,
    Tooltip = "Also spams when the ball is on you, inside point-blank range and coming at you, even without a clash. Ignores Clash hits.",
    Callback = function(v) AutoSpam.point_blank = v end})
AS:AddSlider("PointBlankRange", {Text = "Point-blank range", Default = 14, Min = 4, Max = 35, Rounding = 0, Suffix = " studs",
    Callback = function(v) AutoSpam.point_blank_range = v end})
AS:AddSlider("AutoSpamLinger", {Text = "Keep spamming for", Default = 0.2, Min = 0, Max = 1, Rounding = 2, Suffix = "s",
    Tooltip = "How long to keep spamming after the clash stops being detected.",
    Callback = function(v) AutoSpam.linger = v end})

task.spawn(function()
    while task.wait(0.1) do
        if Library.Unloaded then break end
        if Library.Toggled then AutoSpamLabel:SetText("Status: " .. System.auto_spam.status()) end
    end
end)

-- PLAYER TAB
local AVC = Tabs.Player:AddLeftGroupbox("Avatar Changer", "user")
AVC:AddInput("AvatarTarget", {Text = "Target", Placeholder = "Username or user id", Default = "", Finished = true, Callback = function(t)
    __avatar_changer_target = t
end})
AVC:AddToggle("AvatarChanger", {Text = "Avatar changer", Default = false, Callback = function(v)
    __avatar_changer_enabled = v
    if v then
        task.spawn(function()
            local userId = __resolveTargetId(__avatar_changer_target)
            if userId then
                saveOriginalAppearance(); applyAvatarLocally(userId)
                Notify("Avatar Changer", "Appearance changed", 3)
            else Notify("Avatar Changer", "Invalid username or id", 3) end
        end)
    else
        restoreOriginalAppearance()
        if UIReady then Notify("Avatar Changer", "Appearance restored", 2) end
    end
end})

local HK = Tabs.Player:AddRightGroupbox("Cosmetics", "shirt")
HK:AddToggle("Headless", {Text = "Headless", Default = false, Callback = function(v)
    System.__properties.__headless_enabled = v
    local c = LocalPlayer.Character
    if c then if v then Byte_Library.Headless(c) else Byte_Library.Restore_Head(c) end end
end})
HK:AddToggle("Korblox", {Text = "Korblox", Default = false, Callback = function(v)
    System.__properties.__korblox_enabled = v
    local c = LocalPlayer.Character
    if c then if v then Byte_Library.Korblox(c) else Byte_Library.Restore_Leg(c) end end
end})

local AutoJump = false
local ajLastOnGround = false
local MV = Tabs.Player:AddRightGroupbox("Movement", "footprints")
MV:AddToggle("AutoJump", {Text = "Auto jump", Default = false, Callback = function(v)
    AutoJump = v
    if not v then ajLastOnGround = false end
    NotifyToggle("Auto Jump", v)
end}):AddKeyPicker("AutoJumpKey", {Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump"})

RunService.Heartbeat:Connect(function()
    if AutoJump then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            local onGround = hum.FloorMaterial ~= Enum.Material.Air
            if onGround and not ajLastOnGround then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            ajLastOnGround = onGround
        end
    else ajLastOnGround = false end
end)

-- VISUALS TAB
local VS = Tabs.Visuals:AddLeftGroupbox("Overlays", "monitor")
VS:AddToggle("BallVelocity", {Text = "Ball velocity overlay", Default = false, Callback = function(v)
    System.__properties.__ball_velocity_enabled = v
    if v then
        System.create_ball_velocity_gui()
        if not System.__properties.__connections.__ball_velocity then
            System.__properties.__connections.__ball_velocity = RunService.RenderStepped:Connect(function() System.update_ball_velocity() end)
        end
    else
        if System.__properties.__ball_velocity_gui then System.__properties.__ball_velocity_gui.gui:Destroy(); System.__properties.__ball_velocity_gui = nil end
        if System.__properties.__connections.__ball_velocity then System.__properties.__connections.__ball_velocity:Disconnect(); System.__properties.__connections.__ball_velocity = nil end
    end
end})
VS:AddToggle("ShowPing", {Text = "Ping overlay", Default = false, Callback = function(v)
    System.__properties.__show_ping = v
    PingGui.Enabled = v
end})

local AE = Tabs.Visuals:AddRightGroupbox("Ability ESP", "eye")
AE:AddToggle("AbilityESP", {Text = "Ability ESP", Default = false, Callback = function(s)
    if s then start_ability_esp() else stop_ability_esp() end
    NotifyToggle("Ability ESP", s)
end})
AE:AddToggle("AbilityESPName", {Text = "Show name", Default = true,
    Callback = function(v) AbilityESPConfig.ShowName = v end})
AE:AddToggle("AbilityESPDistance", {Text = "Show distance", Default = false,
    Callback = function(v) AbilityESPConfig.ShowDistance = v end})
AE:AddToggle("AbilityESPOnlyWith", {Text = "Only players with an ability", Default = false,
    Callback = function(v) AbilityESPConfig.OnlyWithAbility = v end})
AE:AddSlider("AbilityESPTextSize", {Text = "Text size", Default = 14, Min = 8, Max = 30, Rounding = 0,
    Callback = function(v) AbilityESPConfig.TextSize = v end})
AE:AddSlider("AbilityESPHeight", {Text = "Height offset", Default = 3.5, Min = 0, Max = 15, Rounding = 1, Suffix = " studs",
    Tooltip = "How far above the head the label sits.",
    Callback = function(v) AbilityESPConfig.Height = v end})
AE:AddSlider("AbilityESPMaxDistance", {Text = "Max distance", Default = 0, Min = 0, Max = 2000, Rounding = 0, Suffix = " studs",
    Tooltip = "Hide labels beyond this distance. 0 = unlimited.",
    Callback = function(v) AbilityESPConfig.MaxDistance = v end})
AE:AddLabel("Text color"):AddColorPicker("AbilityESPColor", {
    Default = Color3.fromRGB(255, 255, 255), Title = "Ability ESP color",
    Callback = function(v) AbilityESPConfig.Color = v end})

-- MISC TAB
local SC = Tabs.Misc:AddLeftGroupbox("Skin Changer", "palette")
SC:AddInput("SkinName", {Text = "Sword name", Placeholder = "e.g. DualPrince", Default = getgenv().swordModel or "", Finished = true, Callback = function(t)
    getgenv().swordModel = t
    getgenv().swordAnimations = t
    getgenv().swordFX = t
    if getgenv().skinChangerEnabled and t ~= "" then
        if getgenv().updateSword then pcall(getgenv().updateSword) end
    end
    if getgenv().saveLastEquippedSword then pcall(getgenv().saveLastEquippedSword) end
end})
SC:AddToggle("SkinChanger", {Text = "Skin changer", Default = false, Callback = function(v)
    getgenv().skinChanger = v
    getgenv().skinChangerEnabled = v
    if v and getgenv().swordModel ~= "" then
        if getgenv().updateSword then pcall(getgenv().updateSword) end
    end
    NotifyToggle("Skin Changer", v)
end})

local NR = Tabs.Misc:AddRightGroupbox("Performance", "cpu")
local Connections_Manager = {}
NR:AddToggle("NoRender", {Text = "No render", Default = false,
    Tooltip = "Turns off ability and parry effects.",
    Callback = function(state)
        local effectScripts = LocalPlayer.PlayerScripts:FindFirstChild("EffectScripts")
        local clientFX = effectScripts and effectScripts:FindFirstChild("ClientFX")
        if clientFX then clientFX.Disabled = state end
        if state then
            if not Connections_Manager['No Render'] then
                Connections_Manager['No Render'] = Runtime.ChildAdded:Connect(function(Value) Debris:AddItem(Value, 0) end)
            end
        elseif Connections_Manager['No Render'] then
            Connections_Manager['No Render']:Disconnect()
            Connections_Manager['No Render'] = nil
        end
    end})

local UA = Tabs.Misc:AddRightGroupbox("Unlock All", "unlock")
UA:AddButton({Text = "Load unlock all", Risky = true, DoubleClick = true,
    Tooltip = "Runs a third-party script from flowauth.net. Its code is not part of this repo.",
    Func = function()
        Notify("Unlock All", "Loading script...", 3)
        local success, err = pcall(function()
            loadstring(game:HttpGet("https://flowauth.net/v1/loaders/5d423493a8f0aa8432cda8455a5f8906.lua"))()
        end)
        if success then Notify("Unlock All", "Script loaded", 3)
        else Notify("Unlock All", "Error: " .. tostring(err), 5) end
    end})
UA:AddButton({Text = "Remove unlock UI", Func = function()
    task.spawn(function()
        local destroyed_count = 0
        local keywords = {"unlock", "unlocksuite", "flowauth", "flow", "authui", "hubui", "keyui", "keysystem", "key", "loader"}
        local function shouldDestroy(gui)
            local name = tostring(gui.Name):lower()
            for _, kw in ipairs(keywords) do
                if name:find(kw, 1, true) then return true end
            end
            return false
        end
        local function sweep(parent)
            if not parent then return end
            for _, gui in ipairs(parent:GetChildren()) do
                if gui:IsA("ScreenGui") and shouldDestroy(gui) then
                    if pcall(function() gui:Destroy() end) then destroyed_count = destroyed_count + 1 end
                end
            end
        end
        sweep(LocalPlayer:FindFirstChildOfClass("PlayerGui"))
        pcall(sweep, CoreGui)
        pcall(function() if gethui then sweep(gethui()) end end)
        pcall(function()
            for _, key in ipairs({"UnlockGui", "UnlockSuiteGui", "_usStandaloneUnlockGui", "unlockGui", "flowAuthGui", "FlowAuthUI", "FlowAuthUI_Standalone", "UnlockAllUI"}) do
                local gui = getgenv()[key]
                if typeof(gui) == "Instance" then
                    pcall(function() gui:Destroy() end)
                    destroyed_count = destroyed_count + 1
                    getgenv()[key] = nil
                end
            end
        end)
        if destroyed_count > 0 then
            Notify("Unlock All", "Removed " .. destroyed_count .. " UI", 2)
        else
            Notify("Unlock All", "No UI found", 3)
        end
    end)
end})

-- ============================================================
-- HOTKEYS
-- ============================================================
-- Spam, triggerbot and auto jump keys are key pickers on their toggles, and
-- the menu key is in Ui3's settings. Only the curve number keys live here.
local curveKeys = {
    [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
    [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
    [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
}
Library:GiveSignal(UserInputService.InputBegan:Connect(function(inp, gp)
    if gp or not System.__properties.__curve_hotkeys then return end
    local index = curveKeys[inp.KeyCode]
    local name = index and System.__config.__curve_names[index]
    if name then
        Options.CurveMode:SetValue(name)
        Notify("Curve Mode", name, 1)
    end
end))

-- ============================================================
-- UNLOAD
-- ============================================================
Library:OnUnload(function()
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
    System.autoparry.stop()
    setTriggerbot(false)
    System.__properties.__autoparry_enabled = false
    System.__properties.__manual_spam_enabled = false
    System.__properties.__auto_spam_enabled = false
    System.__properties.__show_ping = false
    AutoJump = false
    for _, conn in pairs(System.__properties.__connections) do pcall(function() conn:Disconnect() end) end
    for _, conn in pairs(Connections_Manager) do pcall(function() conn:Disconnect() end) end
    for _, gui in pairs(System.__properties.__mobile_guis) do destroy_mobile_gui(gui) end
    if System.__properties.__ball_velocity_gui then pcall(function() System.__properties.__ball_velocity_gui.gui:Destroy() end) end
    pcall(function() PingGui:Destroy() end)
    pcall(stop_ability_esp)
    getgenv().skinChanger = false
    getgenv().skinChangerEnabled = false
end)

-- The next copy calls this before it starts.
genv.__BladeBallShutdown = function()
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

UIReady = true
Notify("Blade Ball", "Loaded. " .. (isMobile and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)

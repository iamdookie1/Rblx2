-- Blade Ball
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).

task.spawn(function()

-- Bumped on every change, shown in the window footer and the Status tab, so
-- you always know which build you're testing.
local SCRIPT_VERSION = "2026.10.07-53"

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

-- Flight recorder: a timestamped timeline of what this copy did, written to
-- BladeBall/flight.txt as it happens (a fresh file each run). When a kick comes,
-- its message lands in the same file, so the lines right above it show exactly
-- what ran before it. Writing a file is executor-side only; the game can't see it.
local flight
do
    local PATH, t0, started, buf = "BladeBall/flight.txt", os.clock(), false, {}
    flight = function(msg)
        -- getgenv().BladeBallNoLog = true: no file is touched at all.
        if genv.BladeBallNoLog then return end
        pcall(function()
            local line = ("[%9.3f] %s\n"):format(os.clock() - t0, tostring(msg))
            if not started then
                started = true
                if isfolder and makefolder and not isfolder("BladeBall") then makefolder("BladeBall") end
                writefile(PATH, line)
            elseif appendfile then
                appendfile(PATH, line)
            else
                table.insert(buf, line)
                if #buf > 400 then table.remove(buf, 1) end
                writefile(PATH, table.concat(buf))
            end
        end)
    end
end

-- Parry log: every parry this copy sends, where it came from, which pass at you
-- it was for. Spam sources are only counted (they fire hundreds a second).
local ParryLog = {entries = {}, source = nil, spam = 0, total = 0, doubles = 0, describe = nil}
local SPAM_SOURCES = {["manual spam"] = true, ["auto spam"] = true, ["slashes of fury"] = true}
local function log_send(how)
    local src = ParryLog.source or "unknown"
    if SPAM_SOURCES[src] then ParryLog.spam = ParryLog.spam + 1; return end
    ParryLog.total = ParryLog.total + 1
    flight(("send #%d (%s via %s)"):format(ParryLog.total, src, tostring(how)))
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
-- Every GUI we make goes in the executor's hidden container, never anywhere the
-- game's own scripts can look (Workspace, characters, PlayerGui).
local HUI = CoreGui
pcall(function() local h = gethui and gethui(); if typeof(h) == 'Instance' then HUI = h end end)

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

-- Ping barely moves between frames, but the parry maths reads it several times
-- per ball per frame. Cache it so the hot path does one cheap read instead of a
-- pcall into Stats every time -- keeps the per-frame decision tight.
local ping_cache = {at = -1, ms = 0}
local function pingMs()
    local now = os.clock()
    if now - ping_cache.at > 0.05 then
        ping_cache.ms = getPing()
        ping_cache.at = now
    end
    return ping_cache.ms
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char.PrimaryPart
end

-- The parry core's shared state (see "PARRY CORE" further down). Declared here
-- so the animation code and the UI, defined before the core, can reach it.
local Core = {cap = nil, info = "not armed yet", told = false, interp = 0.14,
    cfg = {close_range = 20, instant = true, preparry = false, hp_close = true, hit_zone = 4, instant_range = 8, sim_dt = 1 / 120}}
local function remoteReady() return Core.cap ~= nil end
-- Arms Remote mode by auto pressing block; defined in the parry core.
local prime_remote

-- "A place where they can parry" — mirrors the game's own client parry gate. A
-- Mirrors the game's OWN parry gate (SwordsController, dump line 225837): the
-- exact conditions under which a block press actually makes the game send a
-- parry. Matching it matters for the capture burst -- we install the hook and
-- press only when a press truly fires the sender, so the hook is never left up
-- for a press the game would swallow. A send is allowed when:
--   * not DoNotParry, and not Stunned (server-set when you can't block), and
--   * not (charging adrenaline with Qi-Charge < 2) -- the game blocks it then,
--   * AND you're somewhere parrying happens: a live round (Workspace.Alive), a
--     lobby parry (LobbyParry attr, but NOT while InLobbyParryCooldown -- a press
--     then sends nothing), or training (Workspace.Dead with LobbyTraining).
local function canParryNow()
    local char = LocalPlayer.Character
    if not char then return false end
    if char:GetAttribute("Stunned") then return false end
    if char:GetAttribute("DoNotParry") then return false end
    if char:GetAttribute("ChargingAdrenaline") then
        local ok, qi = pcall(function() return LocalPlayer.Upgrades["Qi-Charge"].Value end)
        if ok and type(qi) == "number" and qi < 2 then return false end
    end
    if char.Parent == Alive then return true end
    if LocalPlayer:GetAttribute("LobbyParry") then
        -- lobby parry's own cooldown: a press during it is a no-op send
        return not LocalPlayer:GetAttribute("InLobbyParryCooldown")
    end
    if LocalPlayer:GetAttribute("LobbyTraining") then
        local Dead = Workspace:FindFirstChild("Dead")
        if Dead and char.Parent == Dead then return true end
    end
    return false
end

-- Presses the block key via VirtualInputManager, which makes the game run its
-- own PRY sender (and thus send a real parry). Used by Keypress mode every
-- parry, and by the fast capture burst to force the one parry we read the packet
-- from. It can't curve and pays the game's parry cooldown, so Remote mode uses
-- it only to arm, never to parry.
local CollectionService = cloneref(game:GetService('CollectionService'))
local GuiService = cloneref(game:GetService('GuiService'))

-- The press is the F key on every device.
local function pressBlockKey()
    if not is_live() then return false end
    log_send("block key")
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)
    return true
end

-- Screen points sent with a parry, built the way the game's own parry handler
-- builds them: everyone under Alive, or in lobby training the other trainees
-- under Workspace.Dead plus the LobbyTrainingTarget dummies.
-- Also returns `others`: everyone in that list except us, with world and screen
-- position, which is what target mode picks from.
local function build_screen_points(cam)
    local points, others = {}, {}
    local char = LocalPlayer.Character
    local function add(name, pos)
        local screen = cam:WorldToScreenPoint(pos)
        points[name] = screen
        if not (char and name == char.Name) then
            others[#others + 1] = {name = name, pos = pos, screen = screen}
        end
    end
    local dead = Workspace:FindFirstChild('Dead')
    if dead and char and char.Parent == dead and LocalPlayer:GetAttribute('LobbyTraining') then
        for _, other in ipairs(dead:GetChildren()) do
            local plr = Players:GetPlayerFromCharacter(other)
            local hrp = other:FindFirstChild('HumanoidRootPart')
            if plr and hrp and plr:GetAttribute('LobbyTraining') then add(other.Name, hrp.Position) end
        end
        for _, dummy in ipairs(CollectionService:GetTagged('LobbyTrainingTarget')) do
            if dummy:IsA('BasePart') then add(dummy.Name, dummy.Position) end
        end
    else
        local mode = Workspace:GetAttribute("CurrentlySelectedMode")
        if mode == "Hovergoal" or mode == "Soccer" then
            -- Like the game in these modes: the other team's goal, plus any
            -- Rising Zombie -- not every player.
            pcall(function()
                local helper = require(ReplicatedStorage.Shared.ThreadSafeTargetingHelper)
                local team = helper.GetPlayerTeam(LocalPlayer)
                local want = ("Goal%s"):format(tostring(team == 1 and 2 or 1))
                for _, goal in ipairs(CollectionService:GetTagged("HovergoalGoal")) do
                    if goal.Name == want and goal:FindFirstChild("Target") then
                        add(goal.Name, goal.Target.Position)
                        break
                    end
                end
            end)
            for _, entity in ipairs(Alive:GetChildren()) do
                local hrp = entity:FindFirstChild('HumanoidRootPart')
                if hrp and entity:GetAttribute("IsTheRisingZombie") then add(entity.Name, hrp.Position) end
            end
        else
            for _, entity in ipairs(Alive:GetChildren()) do
                local hrp = entity:FindFirstChild('HumanoidRootPart')
                if hrp then add(entity.Name, hrp.Position) end
            end
        end
    end
    return points, others
end

-- The game sends the mouse position every time (its keyboard/mouse check is
-- always true), so this does too.
local function aim_point(cam)
    local ok, mouse = pcall(UserInputService.GetMouseLocation, UserInputService)
    if ok and mouse then return {mouse.X, mouse.Y} end
    local vp = cam.ViewportSize
    return {vp.X / 2, vp.Y / 2}
end

-- Screen points and aim only change frame to frame, so parries fired in the
-- same frame (spam) share one copy instead of re-projecting every player.
local PACKET_TTL = 1 / 240
local packet_cache = {at = -1, points = nil, aim = nil, others = nil}
local function packet_parts(cam)
    local now = os.clock()
    if now - packet_cache.at > PACKET_TTL then
        packet_cache.points, packet_cache.others = build_screen_points(cam)
        packet_cache.aim = aim_point(cam)
        packet_cache.at = now
    end
    return packet_cache.points, packet_cache.aim, packet_cache.others
end

-- Who the ball gets sent to. Defined further down, once System exists.
local choose_target

-- The target aim point, built once per frame per target (spam sends many
-- parries a frame).
local target_aim = {at = -1, name = nil, aim = nil}

-- ============================================================
-- PARRY WINDOW (packet arg 4) -- computed exactly like the game
-- ============================================================
-- The window is NOT a constant. SwordsController computes it per account on
-- every parry (dump, SwordsController parry handler):
--   n6 = 0.5; timesParried 0/1/2/3/4 -> 1.5/1.25/1.0/0.75/0.625
--   if the noob boost is on (normal servers + FFlag NoobParryEnabled):
--     TotalStats.Kills >= 20 -> boost switches off for good
--     otherwise            -> n6 = kills/20 * n6
-- The server knows your timesParried and kills too, so it knows exactly what
-- window your client is allowed to send. Every hookless build before this sent
-- a hard-coded 0.5 -- on a low-kill account that's claiming a far bigger window
-- than the game would ever send for you. We read the same replicated stats the
-- game reads (Replion "Data", via the same plain require the game's own modules
-- use -- no getgc, no hook) and reproduce its arithmetic exactly.
local Win = {data = nil, noob = false}
task.spawn(function()
    local function srv(info, name)
        local ok, r = pcall(function() return info[name]() end)
        return ok and r == true
    end
    local info, utils
    pcall(function() info = require(ReplicatedStorage:WaitForChild("ServerInfo", 10)) end)
    pcall(function() utils = require(ReplicatedStorage:WaitForChild("Common", 10):WaitForChild("Utils", 10)) end)
    local flag_on = true
    pcall(function() flag_on = utils.FFlag.GetInstantFFlag("NoobParryEnabled", true) end)
    if info then
        Win.noob = flag_on and not srv(info, "isDungeonsMatchServer") and not srv(info, "isRankedMatchServer")
            and not srv(info, "isMedalServer") and not srv(info, "isClanWarServer")
            and not srv(info, "isTournamentMatchServer") and true or false
    end
    task.spawn(function()
        pcall(function()
            local Replion = require(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Replion", 10))
            Win.data = Replion.Client:WaitReplion("Data")
        end)
        Win.done = true
    end)
    -- Never block Remote forever: if the stats can't be read within 10s, give
    -- up waiting and let the parry sender use its fallback.
    task.delay(10, function() Win.done = true end)
end)

local function parry_window()
    local data = Win.data
    if not data then return nil end
    local ok_tp, tp = pcall(data.Get, data, "timesParried")
    if not ok_tp or type(tp) ~= 'number' then tp = 0 end
    -- n6 = the window, n2 = the press lockout, fresh = the game's u120 (it plays
    -- the parry swing faster for its first five parries).
    local n6, n2, fresh = 0.5, 1.3, false
    if tp == 0 then n6, n2, fresh = 1.5, 1.5, true
    elseif tp == 1 then n6, n2, fresh = 1.25, 1.3, true
    elseif tp == 2 then n6, n2, fresh = 1, 1.3, true
    elseif tp == 3 then n6, fresh = 0.75, true
    elseif tp == 4 then n6, fresh = 0.625, true end
    if Win.noob then
        local ok_k, kills = pcall(data.Get, data, "TotalStats.Kills")
        if not ok_k or type(kills) ~= 'number' then kills = 0 end
        if kills >= 20 then
            Win.noob = false -- the game turns the boost off for good at 20 kills
        else
            n2 = kills / 20 * n2
            n6 = kills / 20 * n6
        end
    end
    return n6, n2, fresh, tp
end

-- ============================================================
-- SYSTEM
-- ============================================================
local System = {
    __properties = {
        __autoparry_enabled = false, __triggerbot_enabled = false,
        __manual_spam_enabled = false, __play_animation = false,
        __curve_mode = 1, __accuracy = 50, __accuracy_base = 50, __divisor_multiplier = 1.1, __timing_mult = 1,
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
        __curve_hotkeys = true, __target_mode = 1
    },
    __config = {
        __curve_names = {'Camera', 'Random', 'Accelerated', 'Backwards', 'Slow', 'High', 'Normal', 'Speed', 'Down', 'Left', 'Right'},
        __target_names = {'Cursor', 'Camera', 'Closest', 'Farthest', 'Random'},
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
-- Mirrors the game's own block action (its parry controller, read from the game
-- source) so remote parries and spam look like real ones:
--   * which tracks: every animation in the sword's animation set tagged Parry or
--     GrabParry, picked by attribute through the game's SwordAPI:GetAnimations
--     (not by child name, which missed sets like Scissors that only have Parry);
--   * how they load: through the game's AnimationController, which copies the
--     Animation's attributes (GrabParry, PlaySpeed, PlayFadeTime, StopFadeTime...)
--     onto the track and keeps one track per animation. The game's own success
--     handler finds what to stop by those attributes, so tracks loaded straight
--     from the Animator were never stopped and the block and success swings played
--     on top of each other (and a fresh track was created on every play);
--   * how they play: stop playing Parry / SuccessParry tracks, then Play with the
--     track's own fade/weight/speed, and record ParryTime on the character;
--   * when: like the game, a new block only starts once the last one landed (our
--     ParrySuccess) or its 1.3s cooldown ran out. Held spam then reads as block,
--     success swing, block, success swing -- what spamming the key in a clash
--     looks like. The success swing itself is played by the game when it lands.
System.animation = {}
do
local SwordAPIFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwordAPI")
local BLOCK_COOLDOWN = 1.3   -- the game's block lockout when a block doesn't land
local game_api, game_anim, modules_tried
local sword_info_cache = {}  -- sword name -> {collection, sword_type}
local own_tracks = setmetatable({}, {__mode = 'k'}) -- animator -> {[Animation] = track}
local r15_clones = {}        -- Animation -> Animation using its R15Id
local gate = {last = -math.huge, landed = true, landed_at = -math.huge}
local SWING_SHOW = 0.08      -- minimum success swing shown before the next block

-- Any match or training ball currently targeting us. (System.ball is defined
-- further down; this runs at call time, after it exists.)
local function ball_on_us()
    local me = LocalPlayer.Name
    for _, ball in ipairs(System.ball.get_all()) do
        if ball:GetAttribute('target') == me then return true end
    end
    local training = Workspace:FindFirstChild("TrainingBalls")
    if training then
        for _, ball in ipairs(training:GetChildren()) do
            if ball:GetAttribute("realBall") and ball:GetAttribute('target') == me then return true end
        end
    end
    return false
end

local function modules()
    if not modules_tried then
        modules_tried = true
        pcall(function() game_api = require(SwordAPIFolder) end)
        pcall(function() game_anim = require(ReplicatedStorage.Controllers.AnimationController) end)
        if type(game_api) ~= 'table' or type(game_api.GetAnimations) ~= 'function' then game_api = nil end
        if type(game_anim) ~= 'table' or type(game_anim.LoadAnimation) ~= 'function' then game_anim = nil end
    end
    return game_api, game_anim
end

local function current_sword(char)
    if getgenv().skinChangerEnabled then
        return (getgenv().swordAnimations ~= "" and getgenv().swordAnimations)
            or (getgenv().swordModel ~= "" and getgenv().swordModel)
            or char:GetAttribute("CurrentlyEquippedSword")
    end
    return char:GetAttribute("CurrentlyEquippedSword")
end

local function sword_info(name)
    name = name or ""
    local info = sword_info_cache[name]
    if info then return info end
    info = {collection = "Default", sword_type = "Single"}
    if name ~= "" then
        local ok, data = pcall(function()
            return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(name)
        end)
        if ok and type(data) == "table" then
            info.collection = data.AnimationType or info.collection
            info.sword_type = data.SwordType or info.sword_type
        end
    end
    sword_info_cache[name] = info
    return info
end

local function find_animations(char, names, info)
    local api = modules()
    if api then
        local ok, list = pcall(api.GetAnimations, api, char, names, info.collection, info.sword_type)
        if ok and type(list) == "table" and #list > 0 then return list end
    end
    -- Fallback: the same pick by attribute from the set's folder (or Default).
    local collection = SwordAPIFolder:FindFirstChild("Collection")
    local folder = collection and (collection:FindFirstChild(info.collection) or collection:FindFirstChild("Default"))
    local list = {}
    if folder then
        for _, anim in ipairs(folder:GetChildren()) do
            if anim:IsA("Animation") then
                for _, n in ipairs(names) do
                    if anim:GetAttribute(n) then list[#list + 1] = anim; break end
                end
            end
        end
    end
    return list
end

local function load_track(animator, humanoid, anim)
    local _, ctrl = modules()
    if ctrl then
        local ok, track = pcall(ctrl.LoadAnimation, ctrl, animator, anim, true)
        if ok and track then return track end
    end
    -- Fallback, same as the game's loader: one track per animation per
    -- animator, with the Animation's attributes copied onto it.
    local per = own_tracks[animator]
    if not per then per = {}; own_tracks[animator] = per end
    local track = per[anim]
    if track then return track end
    local source = anim
    local r15 = anim:GetAttribute("R15Id")
    if r15 and humanoid.RigType == Enum.HumanoidRigType.R15 then
        source = r15_clones[anim]
        if not source then
            source = Instance.new("Animation")
            source.AnimationId = r15
            r15_clones[anim] = source
        end
    end
    track = animator:LoadAnimation(source)
    for k, v in pairs(anim:GetAttributes()) do pcall(track.SetAttribute, track, k, v) end
    per[anim] = track
    return track
end

-- The game's own presses (your block button, tap to block, the capture press)
-- start its parry swing; seeing that swing start is how we know the server's
-- lockout started without us. Our own swings are told apart by when we played
-- them. No hooks: Animator.AnimationPlayed.
local own_swing = setmetatable({}, {__mode = 'k'}) -- track -> when we played it
local function watch_presses(char)
    task.spawn(function()
        local humanoid = char:WaitForChild("Humanoid", 10)
        local animator = humanoid and humanoid:WaitForChild("Animator", 10)
        if not animator then return end
        animator.AnimationPlayed:Connect(function(track)
            if track:GetAttribute("SuccessParry") then return end -- a landed parry's swing, not a press
            if not (track:GetAttribute("Parry") or track:GetAttribute("GrabParry")) then return end
            local at = own_swing[track]
            if at and os.clock() - at < 0.25 then return end
            if Core.gate_start then Core.gate_start() end
        end)
    end)
end
if LocalPlayer.Character then watch_presses(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(watch_presses)

local function play_block()
    local char = LocalPlayer.Character
    if not char or char:GetAttribute("InOverdriveMech") then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end
    local now = os.clock()
    if not gate.landed and now - gate.last < BLOCK_COOLDOWN then return end
    -- Let the swing show the way it does in the real game. When our parry lands the
    -- game plays its success swing, and the swing lasts until the next block press
    -- cuts it (the game's block stops success swings) -- there's no fixed delay.
    -- In a clash you press as the ball comes back, so the swing runs while the ball
    -- is with the other player and the next block starts when it's on you again.
    -- Spam fires every few ms, so mirror that: after a landed parry, hold the next
    -- block until a ball is back on us (with a tiny floor so a near-instant return
    -- still shows the strike).
    if gate.landed and gate.landed_at > gate.last then
        if now - gate.landed_at < SWING_SHOW then return end
        -- (If the ball never comes back, give up waiting after the game's lockout.)
        if not ball_on_us() and now - gate.landed_at < BLOCK_COOLDOWN then return end
    end
    local playing = animator:GetPlayingAnimationTracks()
    gate.last, gate.landed = now, false
    for _, track in ipairs(playing) do
        if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then
            track:Stop(track:GetAttribute("StopFadeTime"))
        end
    end
    local parry_time = char:GetAttribute("ParryTime") or 0
    for _, anim in ipairs(find_animations(char, {"Parry", "GrabParry"}, sword_info(current_sword(char)))) do
        local ok, track = pcall(load_track, animator, humanoid, anim)
        if ok and track then
            local speed = track:GetAttribute("PlaySpeed") or 1
            own_swing[track] = os.clock()
            track:Play(track:GetAttribute("PlayFadeTime"), track:GetAttribute("PlayWeight"), speed)
            System.__properties.__grab_animation = track
            local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
            if left > parry_time then parry_time = left end
        end
    end
    pcall(char.SetAttribute, char, "ParryTime", parry_time)
end

-- Our own block landed: the next block can start straight away (the game plays
-- the success swing itself).
pcall(function()
    Remotes.ParrySuccess.OnClientEvent:Connect(function()
        gate.landed, gate.landed_at = true, os.clock()
    end)
end)
LocalPlayer.CharacterAdded:Connect(function()
    gate.last, gate.landed, gate.landed_at = -math.huge, true, -math.huge
end)

-- The block swing that goes with our parries, through play_block's gate (the
-- fix from 54757b6 / a7882af / 760eaa1): it never cuts the game's success swing
-- short. After a landed parry the next block waits until the swing has shown and
-- the ball is back on us, and a block that didn't land isn't replayed inside the
-- game's 1.3s lockout. (v26-v31 stopped the success swing and replayed the grab on
-- every send, spam included -- the grab overriding the swing.)
Core.swing = function() pcall(play_block) end
-- Auto parry / triggerbot / slashes: the parry core's sender plays the swing itself.
function System.animation.play_grab_parry() end
-- Spam with "Animation fix" on: gated like a real held key.
function System.animation.play_block() pcall(play_block) end
System.animation.play_grab_parry_full = System.animation.play_block
end -- animation scope

-- Ball
System.ball = {}
function System.ball.get()
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return nil end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then return ball end
    end; return nil
end
function System.ball.get_all()
    local balls_table = {}; local balls = Workspace:FindFirstChild('Balls')
    if not balls then return balls_table end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then table.insert(balls_table, ball) end
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

-- Who the ball gets sent to (Target mode). Picks from the same player list the
-- parry packet sends, so it also works in lobby training against bots:
--   Cursor   -> nearest the mouse on screen (the game's normal behaviour)
--   Camera   -> nearest the middle of the screen
--   Closest  -> physically nearest you
--   Farthest -> physically farthest from you
--   Random   -> a random player
-- Cursor/Camera fall back to the nearest player when nobody's on screen.
-- Returns name, world position, mode. The pick is held for 0.1s so the curve and
-- the packet built for the same parry agree (Random would otherwise differ).
local target_hold = {at = -1, mode = nil, name = nil, pos = nil}
choose_target = function(cam)
    cam = cam or Workspace.CurrentCamera
    local mode = System.__config.__target_names[System.__properties.__target_mode] or "Cursor"
    local now = os.clock()
    if target_hold.mode == mode and now - target_hold.at < 0.1 then
        return target_hold.name, target_hold.pos, mode
    end
    local _, _, others = packet_parts(cam)
    local root = getRoot()
    local origin = root and root.Position or cam.CFrame.Position
    local name, pos
    if others and #others > 0 then
        if mode == "Random" then
            local t = others[math.random(1, #others)]
            name, pos = t.name, t.pos
        elseif mode == "Closest" or mode == "Farthest" then
            local best = (mode == "Closest") and math.huge or -1
            for _, t in ipairs(others) do
                local d = (t.pos - origin).Magnitude
                if (mode == "Closest" and d < best) or (mode == "Farthest" and d > best) then
                    best, name, pos = d, t.name, t.pos
                end
            end
        else
            local vp = cam.ViewportSize
            local anchor = Vector2.new(vp.X / 2, vp.Y / 2)
            if mode == "Cursor" and not isMobile then
                local ok, m = pcall(UserInputService.GetMouseLocation, UserInputService)
                if ok and m then anchor = m end
            end
            local best = math.huge
            for _, t in ipairs(others) do
                local s = t.screen
                if s.Z > 0 and s.X >= 0 and s.Y >= 0 and s.X <= vp.X and s.Y <= vp.Y then
                    local d = (Vector2.new(s.X, s.Y) - anchor).Magnitude
                    if d < best then best, name, pos = d, t.name, t.pos end
                end
            end
            if not name then
                best = math.huge
                for _, t in ipairs(others) do
                    local d = (t.pos - origin).Magnitude
                    if d < best then best, name, pos = d, t.name, t.pos end
                end
            end
        end
    end
    target_hold.at, target_hold.mode, target_hold.name, target_hold.pos = now, mode, name, pos
    return name, pos, mode
end

System.curve = {}
function System.curve.get_cframe()
    local Camera = Workspace.CurrentCamera
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local root_pos = root and root.Position or Camera.CFrame.Position
    local _, chosen_pos = choose_target(Camera)
    local target_pos = chosen_pos or (root_pos + Camera.CFrame.LookVector * 100)
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
            -- many parries in a row: the spam path, not held by the press gate
            ParryLog.source = "slashes of fury"; System.parry.fast(); ParryLog.source = nil
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
-- PARRY CORE (rewritten): capture, gate, sender, ball tracking, timing,
-- auto parry, retarget, triggerbot, pre-parry
-- ============================================================
-- One block owns everything a parry needs, in the order a parry happens:
--   1. CAPTURE  one real parry packet, with hooks that exist only for one press
--   2. GATE     the game's own press state (window / lockout), fed by every
--               parry the server sees -- ours, spam's and the game's own
--   3. SENDER   fires the captured remote with the exact packet the game sends
--   4. TRACKER  one record per ball: who has it, passes, how it moves
--   5. TIMING   when a parry has to go out for the server to see it land
--   6. AUTO PARRY / RETARGET / PRE-PARRY / TRIGGERBOT on top of 1-5
-- The rest of the script reaches in only through System.parry, System.autoparry,
-- System.triggerbot, Core, prime_remote and the few helpers exported below.
System.autoparry, System.triggerbot, System.parry = {}, {}, {}
local get_ball_state, get_live_balls, character_root, ball_velocity, read_ball, blocked_by_detection
do
local props = System.__properties
local cfg = Core.cfg
local me = LocalPlayer.Name
local clock_ = os.clock

local function ping_s() return math.min(pingMs(), 400) / 1000 end
local function frame_dt() return math.clamp(props.__frame_dt or 1 / 60, 1 / 240, 0.1) end

-- ------------------------------------------------------------
-- 1. CAPTURE
-- ------------------------------------------------------------
-- The game's sender picks one of two shapes at random for every parry:
--   remote:FireServer(...)                       -> __namecall
--   local f = remote.FireServer; f(remote, ...)  -> the FireServer function
-- Which one is hooked is the "Capture hook" setting (Namecall by default,
-- FireServer, or Both). Each alone sees about half the sends, so capture can take
-- two presses (1.4s apart); Both arms in one. Either way the hook exists only
-- while a capture press is in flight (0.35s at most), comes off inside the very
-- call that delivers the packet, and puts the original back exactly. Once per
-- server; after it nothing is hooked. While it's up:
--   * our own calls are waved through before anything else (checkcaller);
--   * every other call goes straight to the original;
--   * nothing is altered or dropped -- the packet reaches the server untouched;
--   * the decoy report remotes (JobId first) are never learned from.
-- Nothing is read from the game's memory: the token key comes from the packet
-- itself, token[i] = bxor((time[i] + i) % 256, key[i]), time = floor(now * 100).
local hookfunction_, restore_ = hookfunction, restorefunction
local hookmetamethod_, getnamecallmethod_ = hookmetamethod, getnamecallmethod
local getrawmetatable_, setreadonly_ = getrawmetatable, setreadonly or make_writeable
local checkcaller_ = checkcaller or function() return false end
local newcclosure_ = newcclosure or function(f) return f end
local select_, type_, typeof_, tostring_, floor_, byte_, bxor_, pcall_ =
    select, type, typeof, tostring, math.floor, string.byte, bit32.bxor, pcall
local JOB_ID = game.JobId
-- The shared FireServer function, read off a remote the game already has
-- (every RemoteEvent hands back the same one) -- no instance is created for it.
local FIRE_FN
pcall(function() FIRE_FN = Remotes.ParrySuccess.FireServer end)
if type(FIRE_FN) ~= 'function' then pcall(function() FIRE_FN = Instance.new("RemoteEvent").FireServer end) end
local H = {fire = nil, nc = nil, want = false, until_t = 0}

-- Which hook(s) a capture press uses (Parry tab -> "Capture hook"):
--   "Namecall"  -- __namecall only (catches remote:FireServer sends)
--   "FireServer"-- the FireServer function only (catches f(remote, ...) sends)
--   "Both"      -- both, so every press captures
-- Each alone sees about half the game's sends, so it can take two presses.
local function capture_method() return getgenv().CaptureHook or "Namecall" end
Core.capture_method = capture_method

-- __namecall goes back exactly: the original function object written straight
-- into the metatable (hookmetamethod can re-wrap it on some executors).
local function restore_namecall(original)
    local ok = pcall_(function()
        local mt = getrawmetatable_(game)
        local was_ro = isreadonly and isreadonly(mt)
        setreadonly_(mt, false)
        rawset(mt, "__namecall", original)
        if was_ro ~= false then setreadonly_(mt, true) end
    end)
    if not ok then pcall_(hookmetamethod_, game, "__namecall", original) end
end

-- Builds the capture from a send, on OUR thread (never inside the game's call).
-- t is the server time the hook read at the moment of the send.
local function learn(remote, hash, uid, token, a4, t)
    local text = tostring_(floor_(t * 100))
    if #token ~= #text then return end
    local key = {}
    for i = 1, #text do key[i] = bxor_(byte_(token, i), (byte_(text, i) + i) % 256) end
    local prev = Core.cap
    Core.cap = {remote = remote, hash = hash, uid = uid, key = key, len = #text, ball2 = typeof_(a4) == "CFrame"}
    Core.misses, Core.pending = 0, nil
    Core.new_capture = {prev = prev}
end

-- A real parry: (hash, id, token, window, cameraCF, points, aim, flag), or on
-- UseBall2 servers (hash, id, token, cameraCF, mouseCF, flag). Decoy reports
-- (JobId first) never match.
local function inspect(entry)
    local self, a = entry[1], entry[3]
    local a1, a2, a3, a4, a5 = a[1], a[2], a[3], a[4], a[5]
    if typeof_(self) == 'Instance' and self.ClassName == 'RemoteEvent'
        and type_(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type_(a2) == 'string' and type_(a3) == 'string'
        and ((type_(a4) == 'number' and typeof_(a5) == 'CFrame') or (typeof_(a4) == 'CFrame' and typeof_(a5) == 'CFrame')) then
        learn(self, a1, a2, a3, a4, entry[4])
        return true
    end
    return false
end

-- ISOLATED HOOK BODIES. While a hook is running it sits on the game's call
-- stack, where the game can look at it (getfenv / debug.info -- its press
-- handler's namecall probe errors on purpose with our namecall hook on the
-- stack). So the body is:
--   * compiled with loadstring under the chunk name of the game's own Net
--     module, so debug.info shows a game path, not our script;
--   * run in a clean game environment (getrenv's globals, no writefile, nothing
--     of ours), so getfenv on its frame shows nothing of ours;
--   * cut off from us: it calls none of our functions -- it drops the send into
--     `box` (a plain table) and passes the call straight on. Our own thread
--     picks the box up a frame later, works out the key and takes the hook down.
--   * free of namecalls: it reads the server time with a dot-call
--     (GetServerTimeNow(ws)), because a namecall inside a __namecall hook
--     overwrites the method the game's call is waiting on -- the old body did
--     that (Workspace:GetServerTimeNow() via learn), which could turn the
--     game's FireServer into GetServerTimeNow on the remote mid-send.
local box = {want = false, nc = nil, fire = nil, list = {}, ws = Workspace, now = Workspace.GetServerTimeNow}
local HOOK_NAME = "=ReplicatedStorage.Packages._Index.sleitnick_net@0.1.0.net"
local NC_SRC = [[
local box, getncm, sel = ...
return function(self, ...)
    local l = box.list
    if box.want and #l < 4 and getncm() == "FireServer" and sel("#", ...) >= 6 then
        l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)}
    end
    return box.nc(self, ...)
end]]
local FIRE_SRC = [[
local box, sel = ...
return function(self, ...)
    local l = box.list
    if box.want and #l < 4 and sel("#", ...) >= 6 then
        l[#l + 1] = {self, sel("#", ...), {...}, box.now(box.ws)}
    end
    return box.fire(self, ...)
end]]
local CLEAN_ENV
do
    local ok, renv = pcall(function() return getrenv and getrenv() end)
    CLEAN_ENV = (ok and type(renv) == 'table' and renv.writefile == nil) and setmetatable({}, {__index = renv}) or {}
end
local function build_body(src, ...)
    local args = table.pack(...)
    local ok, fn = pcall(function()
        local factory = loadstring(src, HOOK_NAME)
        if setfenv then setfenv(factory, CLEAN_ENV) end
        return factory(table.unpack(args, 1, args.n))
    end)
    return ok and type(fn) == 'function' and fn or nil
end
local NC_BODY = build_body(NC_SRC, box, getnamecallmethod_ or function() return nil end, select)
local FIRE_BODY = build_body(FIRE_SRC, box, select)
Core.isolated = NC_BODY ~= nil and FIRE_BODY ~= nil
-- No loadstring on this executor: same bodies, just not disguised.
if not NC_BODY then
    NC_BODY = function(self, ...)
        local l = box.list
        if box.want and #l < 4 and getnamecallmethod_() == "FireServer" and select_("#", ...) >= 6 then
            l[#l + 1] = {self, select_("#", ...), {...}, box.now(box.ws)}
        end
        return box.nc(self, ...)
    end
end
if not FIRE_BODY then
    FIRE_BODY = function(self, ...)
        local l = box.list
        if box.want and #l < 4 and select_("#", ...) >= 6 then
            l[#l + 1] = {self, select_("#", ...), {...}, box.now(box.ws)}
        end
        return box.fire(self, ...)
    end
end

local function unhook()
    local fire, nc = H.fire, H.nc
    H.fire, H.nc, H.want, box.want = nil, nil, false, false
    if fire and not (restore_ and pcall_(restore_, FIRE_FN)) then pcall_(hookfunction_, FIRE_FN, fire) end
    if nc then restore_namecall(nc) end
    box.nc, box.fire = nil, nil
end
Core.unhook = unhook

-- Up for one capture press (0.35s at most). Our thread watches the box every
-- frame: the first real parry in it becomes the capture and the hook comes off.
local function arm()
    if Core.cap or not is_live() then return false end
    H.want, H.until_t = true, clock_() + 0.35
    if H.fire or H.nc then return true end
    box.list = {}
    local method = capture_method()
    if method ~= "Namecall" and hookfunction_ and FIRE_FN then
        local ok, old = pcall(hookfunction_, FIRE_FN, newcclosure_(FIRE_BODY))
        if ok and type(old) == 'function' then H.fire, box.fire = old, old end
    end
    if method ~= "FireServer" and hookmetamethod_ and getnamecallmethod_ then
        local ok, old = pcall(hookmetamethod_, game, "__namecall", newcclosure_(NC_BODY))
        if ok and type(old) == 'function' then H.nc, box.nc = old, old end
    end
    if not (H.fire or H.nc) then H.want = false; return false end
    box.want = true
    task.spawn(function()
        while (H.fire or H.nc) and clock_() < H.until_t do
            task.wait()
            local l = box.list
            for i = 1, #l do
                if pcall_(inspect, l[i]) and Core.cap then break end
            end
            if Core.cap then break end
        end
        unhook()
        box.list = {}
    end)
    return true
end

local function keypress_only()
    return getgenv().AutoParryMode == "Keypress" and getgenv().ManualSpamMode == "Keypress"
end
local function remote_features_on()
    return props.__autoparry_enabled or props.__auto_spam_enabled or props.__manual_spam_enabled
        or System.__triggerbot.__enabled
end

-- Auto press to capture: whenever you can parry and something that parries by
-- remote is on. Presses are 1.4s apart, so each one clears the game's 1.3s
-- lockout and really sends. The press is a real parry, so it's never wasted.
local last_press = -100
prime_remote = function()
    if Core.cap or not is_live() or keypress_only() or not remote_features_on() then return end
    if not canParryNow() then return end
    local now = clock_()
    -- F, 1s after you became able to parry (so it never lands the instant a
    -- round or respawn starts), then every 1.4s until it's armed
    if not Core.can_since or now - Core.can_since < 1 then return end
    if now - last_press < 1.4 then return end
    last_press = now
    if arm() then pressBlockKey() end
end

-- Your own block press arms it too -- only a real block press, not any input:
-- the F key, a left click, a gamepad button, or a touch on the game's block
-- button. (Arming on every touch/key put the hooks up for moving the camera and
-- walking.) The mobile button fires when your finger lifts, so a touch on it
-- arms when it starts and again when it ends, covering however long you hold.
local function on_block_button(pos)
    local ok, hit = pcall(function()
        local inset = GuiService:GetGuiInset()
        for _, b in ipairs(CollectionService:GetTagged("BlockButton")) do
            if b:IsA("GuiObject") and b.Visible and b.AbsoluteSize.X > 1 then
                local gui = b:FindFirstAncestorWhichIsA("ScreenGui")
                local p = Vector2.new(pos.X, pos.Y)
                if not (gui and gui.IgnoreGuiInset) then p = p - inset end
                local a, size = b.AbsolutePosition, b.AbsoluteSize
                if p.X >= a.X and p.Y >= a.Y and p.X <= a.X + size.X and p.Y <= a.Y + size.Y then return true end
            end
        end
        return false
    end)
    return ok and hit
end
local function is_block_press(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.Keyboard then return input.KeyCode == Enum.KeyCode.F end
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Gamepad1 then return true end
    if t == Enum.UserInputType.Touch then return on_block_button(input.Position) end
    return false
end
local function own_input(input)
    if Core.cap or not is_live() or keypress_only() then return end
    if is_block_press(input) and canParryNow() then arm() end
end
UserInputService.InputBegan:Connect(own_input)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then own_input(input) end
end)

-- ------------------------------------------------------------
-- 2. GATE
-- ------------------------------------------------------------
-- The game's press handler, copied: a press opens the parry window (u40) and a
-- lockout (u38); while either is up a press does nothing. A landed parry clears
-- both at once, NoobParryHappened clears everything, M1Stop blocks pressing.
-- Every parry the server sees starts it: ours, spam's, and the game's own
-- presses (block button, tap to block, the capture press -- seen through the
-- parry swing starting, no hook). Inside the lockout a press starts nothing.
-- Plain timestamps, so it can never stick: the lockout always ends on time.
-- (The copy of the game's flag logic could stay shut for good -- if a parry
-- went out within 1.3s of a landed one and nothing landed after, the lockout
-- never cleared, and auto parry sat on "game lockout" while spam, which skips
-- the gate, kept working.)
local G = {until_t = 0, m1 = false, m1_at = 0}
local function gate_start()
    local now = clock_()
    if now < G.until_t then return end -- inside the lockout a press starts nothing
    local n6, n2 = parry_window()
    n6, n2 = n6 or 0.5, n2 or 1.3
    G.until_t = now + math.max(n6 + 0.1, n2)
end
local function gate_open()
    -- M1Stop blocks pressing while the game holds it; never longer than 3s
    if G.m1 and clock_() - G.m1_at < 3 then return false end
    return clock_() >= G.until_t
end
Core.gate_start, Core.gate_open = gate_start, gate_open

-- ------------------------------------------------------------
-- 4. TRACKER (before the sender, which marks passes as landed)
-- ------------------------------------------------------------
local tracked = setmetatable({}, {__mode = 'k'})
local pass_counter = 0
local on_retarget -- set in section 6

ball_velocity = function(ball)
    local zoomies = ball:FindFirstChild('zoomies')
    return zoomies and zoomies.VectorVelocity or ball.AssemblyLinearVelocity
end

character_root = function(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local char = Alive:FindFirstChild(name)
    if not char then
        local dead = Workspace:FindFirstChild('Dead')
        char = dead and dead:FindFirstChild(name)
    end
    return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
end

-- Match balls plus lobby training balls, built once per frame and shared.
local live_cache = {at = -1, list = {}}
get_live_balls = function()
    local now = clock_()
    if now - live_cache.at < 1 / 240 then return live_cache.list end
    local list = {}
    for _, name in ipairs({"Balls", "TrainingBalls"}) do
        local folder = Workspace:FindFirstChild(name)
        if folder then
            for _, ball in ipairs(folder:GetChildren()) do
                if ball:GetAttribute('realBall') then list[#list + 1] = ball end
            end
        end
    end
    live_cache.list, live_cache.at = list, now
    return list
end

-- A pass is one stretch of the ball being on us. It opens when the ball comes
-- to us from someone else (a blank target in between is the same pass) and
-- closes when someone else gets it.
local function open_pass(st, now)
    pass_counter = pass_counter + 1
    st.pass_id, st.pass_open = pass_counter, true
    st.parried, st.landed, st.parry_until, st.why = false, false, 0, nil
    st.reached_at, st.trn, st.spd = nil, nil, nil
    -- a pre-parry fired while the ball was on its last holder is this pass's parry
    if st.preparried then
        st.parried, st.parry_until = true, st.preparry_until
        st.preparried = false
    end
    if props.__random_accuracy then roll_accuracy() end
end

get_ball_state = function(ball)
    local st = tracked[ball]
    if st then return st end
    st = {target = ball:GetAttribute('target'), swaps = {}, pass_id = 0, pass_open = false,
        parried = false, landed = false, parry_until = 0, preparried = false, preparry_until = 0}
    tracked[ball] = st
    if st.target == me then open_pass(st, clock_()) end
    ball:GetAttributeChangedSignal('target'):Connect(function()
        local new = ball:GetAttribute('target')
        local now = clock_()
        local swaps = st.swaps
        swaps[#swaps + 1] = {t = now, from = st.target, to = new}
        if #swaps > 16 then table.remove(swaps, 1) end
        st.target = new
        if type(new) == 'string' and new ~= '' and new ~= me then
            st.pass_open, st.parried, st.landed = false, false, false
        end
        if new == me and not st.pass_open then
            open_pass(st, now)
            if on_retarget then pcall(on_retarget, ball, st) end
            if System.spam_on_retarget then System.spam_on_retarget() end
        end
    end)
    return st
end
System.ball_state = get_ball_state
Core.why = function(ball) local st = tracked[ball]; return st and st.why end

-- ------------------------------------------------------------
-- 3. SENDER
-- ------------------------------------------------------------
local function make_token(cap)
    local text = tostring(math.floor(Workspace:GetServerTimeNow() * 100))
    if #text ~= cap.len then return nil end
    local out = table.create(#text)
    for i = 1, #text do out[i] = string.char(bit32.bxor((string.byte(text, i) + i) % 256, cap.key[i])) end
    return table.concat(out)
end

-- "sent", "unarmed" (no capture yet: callers prime it) or "blocked" (this
-- moment can't parry -- callers simply try again, nothing is used up).
-- Spam isn't held by the gate: it keeps sending through the lockout (the
-- server's own cooldown still applies; nothing tries to get round it).
local function send(curveCF, spam)
    if not is_live() then return "blocked" end
    local cap = Core.cap
    if not cap then return "unarmed" end
    if not canParryNow() then return "blocked" end
    if not cap.remote.Parent then Core.cap = nil; return "unarmed" end
    if not spam and not gate_open() then return "blocked" end
    local window = parry_window()
    if window == nil then
        if not Win.done then return "blocked" end -- stats not read yet
        window = 0.5
    end
    local tok = make_token(cap)
    if not tok then Core.cap = nil; return "unarmed" end
    local cam = Workspace.CurrentCamera
    local points, aim = packet_parts(cam)
    -- The server gives the ball to whoever's screen point is nearest the aim
    -- point; for any target mode but Cursor, aim at the chosen target's point.
    if choose_target then
        local name, _, mode = choose_target(cam)
        local screen = name and points[name]
        if screen and mode ~= "Cursor" then
            if target_aim.at ~= packet_cache.at or target_aim.name ~= name then
                target_aim.at, target_aim.name, target_aim.aim = packet_cache.at, name, {screen.X, screen.Y}
            end
            aim = target_aim.aim
        end
    end
    -- The game sends CurrentCamera.CFrame: keep the curve's direction on the camera.
    local cf = cam.CFrame
    if curveCF then
        local origin, look = cf.Position, curveCF.LookVector
        if look == look and look.Magnitude > 0.5 then cf = CFrame.lookAt(origin, origin + look) end
    end
    gate_start()
    log_send("remote")
    local r = cap.remote
    if cap.ball2 then
        local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
        r:FireServer(cap.hash, cap.uid, tok, cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
    else
        r:FireServer(cap.hash, cap.uid, tok, window, cf, points, aim, false)
    end
    if not spam then
        -- answered by a ParrySuccess within the window plus a round trip, or it
        -- counts as unanswered (three in a row -> silent refresh)
        Core.pending = clock_() + window + ping_s() + 0.25
        if Core.swing then Core.swing() end
    end
    return "sent"
end
Core.send = send

-- A landed parry: the gate clears (the game's OnParrySuccess) and the pass on
-- us is done until the ball leaves.
Remotes.ParrySuccess.OnClientEvent:Connect(function()
    local char = LocalPlayer.Character
    if not (char and char:IsDescendantOf(Workspace)) then return end
    G.until_t = 0 -- a landed parry clears the lockout at once (the game's OnParrySuccess)
    local lp = Core.last_parry
    if Core.pending and lp then
        local took = clock_() - lp.t
        -- The success comes back half a round trip after the server saw the ball
        -- touch us, so: server contact came (took - ping/2) after our send, while
        -- we saw it due eta after it. The difference, less half a round trip
        -- (the server sees the ball that much ahead anyway), is the interpolation
        -- delay. Smoothed, clamped to sane bounds.
        local sample = lp.info.eta - took
        if lp.info.eta < 0.9 and took < 1 then
            Core.interp = math.clamp(Core.interp * 0.7 + sample * 0.3, 0.02, 0.3)
        end
        flight(("  -> landed %.3fs after the %s (view lag now %.3fs)"):format(took, lp.via, Core.interp))
    end
    Core.pending, Core.misses = nil, 0
    for _, st in pairs(tracked) do
        if st.target == me and st.pass_open then st.landed = true end
    end
end)
pcall(function()
    Remotes.NoobParryHappened.OnClientEvent:Connect(function()
        task.wait(0.11)
        G.until_t = 0
    end)
end)
pcall(function() Remotes.M1Stop.Event:Connect(function(v) G.m1, G.m1_at = v and true or false, clock_() end) end)
Remotes.ParrySuccessAll.OnClientEvent:Connect(function()
    if props.__grab_animation then pcall(function() props.__grab_animation:Stop() end) end
end)

-- The public parry API (spam, slashes, hotkeys go through these).
local function count() props.__total_parries = props.__total_parries + 1 end
function System.parry.keypress()
    if not LocalPlayer.Character then return false end
    if not pressBlockKey() then return false end
    count()
    return true
end
function System.parry.execute()
    if not LocalPlayer.Character then return false end
    local r = send(System.curve.get_cframe(), false)
    if r == "unarmed" then prime_remote() end
    if r ~= "sent" then return false end
    count()
    return true
end
function System.parry.fast()
    if not LocalPlayer.Character then return false end
    local r = send(System.curve.get_cframe_fast(), true)
    if r == "unarmed" then prime_remote() end
    if r ~= "sent" then return false end
    count()
    return true
end
function System.parry.execute_action() return System.parry.execute() end
-- One parry by the chosen mode. Keypress presses only when the game's gate is
-- open, since a press inside it does nothing.
function System.parry.by_mode(mode)
    if mode == "Keypress" then
        if not gate_open() then return false end
        return System.parry.keypress()
    end
    return System.parry.execute()
end

-- ------------------------------------------------------------
-- 5. TIMING
-- ------------------------------------------------------------
-- heading (1 = straight at us, -1 = straight away), miss (closest its current
-- line passes us), speed, distance, velocity
read_ball = function(ball, root)
    local velocity = ball_velocity(ball)
    local speed = velocity.Magnitude
    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    if speed < 1 or distance < 0.01 then return 0, math.huge, speed, distance, velocity end
    local heading = (velocity / speed):Dot(offset / distance)
    local miss = heading > 0 and distance * math.sqrt(math.max(0, 1 - heading * heading)) or math.huge
    return heading, miss, speed, distance, velocity
end

-- How fast the ball's direction swings round (rad/s), every ~33ms, smoothed
-- but following a sharp turn-in at once. Per pass.
local function turn_rate(st, velocity, now)
    local speed = velocity.Magnitude
    if speed < 1 then return 0 end
    local dir = velocity / speed
    local s = st.trn
    if not s then
        st.trn = {t = now, dir = dir, w = 0, n = 0}
        return 0
    end
    local dt = now - s.t
    if dt >= 0.033 then
        local w = math.acos(math.clamp(s.dir:Dot(dir), -1, 1)) / dt
        s.w = s.n == 0 and w or math.max(s.w * 0.5 + w * 0.5, w * 0.85)
        s.n, s.t, s.dir = s.n + 1, now, dir
    end
    return s.w
end

-- How fast it's gaining speed (studs/s per second), every ~80ms. Per pass.
local function speed_gain(st, speed, now)
    local s = st.spd
    if not s then
        st.spd = {t = now, v = speed, a = 0}
        return 0
    end
    local dt = now - s.t
    if dt >= 0.08 then
        s.a = s.a * 0.5 + ((speed - s.v) / dt) * 0.5
        s.t, s.v = now, speed
    end
    return math.clamp(s.a, 0, speed * 4)
end

-- The ball touches us when its surface reaches us: its radius plus about half
-- a body out from our root.
local function contact_gap(ball)
    local ok, size = pcall(function() return ball.Size end)
    if not ok or not size then return 3 end
    return math.max(size.X, size.Y, size.Z) * 0.5 + 1.5
end

-- Seconds until contact along a straight `path`, from `speed` gaining `accel`.
local function time_to_contact(path, ball, speed, accel)
    local gap = math.max(path - contact_gap(ball), 0)
    if accel > 1 then return (math.sqrt(speed * speed + 2 * accel * gap) - speed) / accel end
    return gap / speed
end

-- Anti curve: fly the ball forward the way it really moves -- swinging toward
-- us at the rate it's been turning, speeding up at the rate it's been gaining --
-- and return the seconds until it touches us, or nil if not within `horizon`.
local function predict_contact(ball_pos, velocity, target, gap, turn, accel, horizon)
    local speed = velocity.Magnitude
    if speed < 1 then return nil end
    local step = cfg.sim_dt
    local pos, dir, t = ball_pos, velocity / speed, 0
    while t < horizon do
        local to = target - pos
        local dist = to.Magnitude
        if dist <= gap then return t end
        local want = to / dist
        local angle = math.acos(math.clamp(dir:Dot(want), -1, 1))
        if angle > 1e-3 and turn > 0 then
            local swing = turn * step
            if swing >= angle then
                dir = want
            else
                local mixed = dir:Lerp(want, swing / angle)
                if mixed.Magnitude < 1e-3 then mixed = dir:Cross(Vector3.yAxis) end
                dir = mixed.Unit
            end
        end
        speed = speed + accel * step
        local move = speed * step
        if dir:Dot(want) > 0 and move >= dist - gap then return t + (dist - gap) / speed end
        pos = pos + dir * move
        t = t + step
    end
    return nil
end

-- TIMING. A parry sent now is up on the server `reach` seconds later in the
-- timeline of the ball we see: the ball on screen trails the server's by half
-- a round trip plus Roblox's interpolation delay (Core.interp, learned from our
-- own landed parries), and the parry takes another half round trip to arrive.
-- It then stays up for the window W (n6). So the parry catches the ball when
--   reach <= eta <= reach + W
-- and we fire at eta = reach + cushion: `cushion` is how far into the window
-- contact lands.
--
-- Lag: ping is sampled 10x a second into an average and a jitter (how far it
-- swings). reach uses the average plus twice the jitter, so a lag spike at the
-- wrong moment still finds the parry up -- at high or unstable ping that's what
-- keeps close-range parries landing.
local Lag = {avg = nil, jit = 0.005, at = -1}
local function sample_lag()
    local now = clock_()
    if now - Lag.at < 0.1 then return end
    Lag.at = now
    local p = ping_s()
    if not Lag.avg then Lag.avg = p; return end
    Lag.jit = Lag.jit + (math.abs(p - Lag.avg) - Lag.jit) * 0.15
    Lag.avg = Lag.avg + (p - Lag.avg) * 0.3
end
Core.lag = Lag
local function jitter() return math.clamp(Lag.jit * 2, 0.005, 0.12) end
-- Seconds from "fire now" until the parry is up, against the ball we see.
local function reach_time()
    sample_lag()
    local ping = math.max(Lag.avg or ping_s(), ping_s())
    local ping_term = props.__ping_compensation and ping or ping * 0.5
    -- half a frame: the packet leaves at the end of the frame we decide in
    return ping_term + jitter() + Core.interp + frame_dt() * 0.5
end
Core.reach_time = reach_time

-- Accuracy (1-100): how tight the parry is to the ball.
--   100 = contact lands just after the parry comes up, with only the measured
--         lag jitter as cushion -- the latest parry that still lands;
--   1   = contact lands 60% into the window, the most room for a lag spike or
--         the ball speeding up.
-- Timing multiplier (0-2): moves that pick. 1 = exactly what Accuracy picks;
-- toward 0 later, down to the very last moment the parry still comes up in
-- time; toward 2 earlier, up to the earliest point that still lands before the
-- parry runs out. Works the same at any Accuracy.
-- Whatever the settings, contact is kept inside the window: never so late the
-- ball lands before the parry is up, never so early the parry runs out first.
-- Slow balls are held earlier in the window -- their pace and path change the
-- most before they arrive.
local function cushion_for(speed, W)
    local a = (math.clamp(props.__accuracy or 50, 1, 100) - 1) / 99
    local latest = 0.01
    -- slow balls: the earliest point is pulled in
    local earliest = math.max(math.min(W - jitter() - 0.03, W * (0.45 + 0.4 * math.clamp((speed - 40) / 120, 0, 1))), latest)
    local tight, loose = jitter(), W * 0.6
    local c = math.clamp(loose + (tight - loose) * a, latest, earliest)
    local m = math.clamp(props.__timing_mult or 1, 0, 2)
    if m <= 1 then c = latest + (c - latest) * m
    else c = c + (earliest - c) * (m - 1) end
    return c
end

local function fire_lead(speed)
    local W = parry_window() or 0.5
    local extra = math.clamp((props.__extra_distance or 0) / math.max(speed, 1), -0.15, 0.15)
    return reach_time() + cushion_for(speed, W) + extra
end
Core.fire_lead = fire_lead
-- Shown on the Status tab: how far out a ball at `speed` gets parried.
function System.parry_distance(speed)
    return speed * fire_lead(speed) + 3
end

-- ------------------------------------------------------------
-- 6. AUTO PARRY / RETARGET / PRE-PARRY / TRIGGERBOT
-- ------------------------------------------------------------
local ABILITY_PARRY = {"Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash"}
local ABILITY_PROTECT = {"Raging Deflection", "Rapture", "Calming Deflection"}
local function ability_ready()
    local ok, ready = pcall(function() return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5 end)
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
local function try_ability()
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

blocked_by_detection = function()
    local det = System.__config.__detections
    return (det.__infinity and props.__infinity_active)
        or (det.__deathslash and props.__deathslash_active)
        or (det.__timehole and props.__timehole_active)
        or (det.__slashesoffury and props.__slashesoffury_active)
end

-- One parry for a pass. The pass stays ours until that parry has had its whole
-- window plus a round trip to land; if it didn't, the pass is live again and
-- the next parry goes the moment the game's lockout lets a press through --
-- exactly what pressing again would do. (The old one-parry-per-pass lock never
-- retried, so one early parry on a slow ball was a death.)
local function mark_parried(st, now)
    st.parried, st.parry_until = true, now + (parry_window() or 0.5) + ping_s() + 0.15
end

local function fire_for(st, now, via, info)
    ParryLog.source = via
    local ok
    if try_ability() then log_send("ability"); ok = true
    else ok = System.parry.by_mode(getgenv().AutoParryMode) end
    ParryLog.source = nil
    if not ok then st.why = "couldn't send yet, retrying"; return false end
    if info then
        Core.last_parry = {t = now, via = via, info = info}
        flight(("%s: eta %.3fs, fires at %.3fs, %.0f st/s, %.1f studs, heading %.2f, line %.1f, ping %.0fms, window %.3f, view lag %.3f"):format(
            via, info.eta, info.lead, info.speed, info.dist, info.heading or 0, math.min(info.miss or 0, 999), pingMs(),
            parry_window() or -1, Core.interp))
    end
    mark_parried(st, now)
    st.why = via == "auto parry" and "parried" or ("parried (" .. via .. ")")
    return true
end

-- Shared by auto parry and triggerbot: is this pass already handled?
local function pass_busy(st, now)
    if st.landed then return "landed, waiting for the ball to leave" end
    if st.parried then
        if now < st.parry_until then return "parry up" end
        st.parried = false -- ran out without landing: live again
    end
    return nil
end

local function autoparry_root()
    if not props.__autoparry_enabled or System.__triggerbot.__enabled then return nil end
    local root = getRoot()
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
    return root
end

-- The decision for a ball on us. via: nil (frame check) or "retarget" (straight
-- off the target change, before the ball has turned toward us).
local function decide(ball, st, root, now, via)
    local function hold(why) st.why = why; return false end
    local busy = pass_busy(st, now)
    if busy then return hold(busy) end
    if props.__parried then return hold("phantom") end
    local tornado = Runtime:FindFirstChild('Tornado')
    if tornado and (tick() - props.__tornado_time) < (tornado:GetAttribute('TornadoTime') or 1) + 0.314159 then return hold("tornado") end
    if ball:FindFirstChild('ComboCounter') then return hold("combo") end
    if blocked_by_detection() then return hold("ability detected") end
    if getgenv().AutoParryMode ~= "Keypress" and Core.cap and not gate_open() then return hold("game lockout, firing when it opens") end

    local heading, miss, speed, distance, velocity = read_ball(ball, root)
    if speed < 1 then return hold("ball not moving") end
    local ping = ping_s()
    local accel = speed_gain(st, speed, now)
    local turn = turn_rate(st, velocity, now)
    local lead = fire_lead(speed)
    local gap = contact_gap(ball)

    -- Gone past us (moving away after reaching us): nothing left to parry.
    if heading < 0 and distance <= gap + 2 then st.reached_at = now end
    if st.reached_at and heading < 0 and now - st.reached_at < ping + 0.3 then return hold("went past") end

    local eta
    if via == "retarget" then
        -- The ball still flies toward its last holder, so there's no heading to
        -- read yet. Go now only if there's no time to look: even its earliest
        -- arrival is inside a round trip and a couple of frames, or it's point
        -- blank. Anything else is timed by the frame checks a moment later.
        -- (reach includes the view lag, so at high ping more of these go at once)
        local earliest = math.max(distance - gap, 0) / speed
        if not (earliest <= reach_time() + frame_dt() * 1.5 + 0.02 or distance <= cfg.instant_range) then
            return hold("just retargeted, timing it")
        end
        eta = earliest
    elseif miss <= cfg.hit_zone then
        eta = time_to_contact(distance, ball, speed, accel)
    else
        eta = predict_contact(ball.Position, velocity, root.Position, gap, turn, accel, lead + 0.1)
        -- a curve wrapped in so tight it's about to touch us
        if not eta and heading > -0.3 and distance <= gap + speed * (ping + frame_dt() * 2) then eta = 0 end
        if not eta then return hold(heading < 0 and "flying away" or "curving, waiting") end
    end
    if eta > lead then return hold(("lands in %.2fs, firing at %.2fs"):format(eta, lead)) end
    return fire_for(st, now, via == "retarget" and "instant retarget" or "auto parry",
        {eta = eta, lead = lead, speed = speed, dist = distance, heading = heading, miss = miss})
end

-- Pre-parry: the ball is on a player right next to us and their return would
-- reach us faster than our reach (ping + view lag) -- a parry sent after the
-- ball turns to us lands too late, so the return is timed as if it were already
-- coming: fired when (ball -> them) + (them -> us) is down to our fire lead.
-- It counts as the parry for the pass that follows.
-- Runs when "Close-range pre-parry" is on, and on its own at high ping (80ms+)
-- with "High ping close range" on -- that's where reacting can't keep up.
local function high_ping() return (Lag.avg or ping_s()) >= 0.08 end
local function try_preparry(ball, st, root, now)
    if st.preparried then return end
    if not (cfg.preparry or (cfg.hp_close and high_ping())) then return end
    local target = st.target
    if type(target) ~= 'string' or target == '' or target == me then return end
    if getgenv().AutoParryMode == "Keypress" or not Core.cap or not gate_open() then return end
    local their_root = character_root(target)
    if not their_root then return end
    local gap = (their_root.Position - root.Position).Magnitude
    if gap > cfg.close_range then return end
    local velocity = ball_velocity(ball)
    local speed = velocity.Magnitude
    if speed < 1 then return end
    local to_them = their_root.Position - ball.Position
    local d_them = to_them.Magnitude
    -- heading into them (or already on them), not flying off
    if d_them > 3 and velocity:Dot(to_them / d_them) < speed * 0.3 then return end
    local back = gap / (speed * 1.1) -- their return speeds the ball up
    local reach = reach_time()
    if back > reach + frame_dt() * 2 then return end -- we'd have time to react to it
    local eta = d_them / speed + back
    local lead = fire_lead(speed)
    if eta > lead then return end
    if blocked_by_detection() then return end
    ParryLog.source = "pre-parry"
    local ok = System.parry.execute()
    ParryLog.source = nil
    if ok then
        st.preparried, st.preparry_until = true, now + (parry_window() or 0.5) + reach + 0.15
        flight(("pre-parry: return in %.3fs (to them %.3f, back %.3f), fires at %.3fs, gap %.1f, ping %.0fms"):format(
            eta, d_them / speed, back, lead, gap, pingMs()))
    end
end

-- Triggerbot: parries the moment the ball is on us, any distance, one per pass
-- (with the same retry once a parry has run out unlanded).
local function trigger(ball, st)
    if not System.__triggerbot.__enabled then return end
    local root = getRoot()
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return end
    local now = clock_()
    if pass_busy(st, now) or blocked_by_detection() then return end
    if getgenv().AutoParryMode ~= "Keypress" and Core.cap and not gate_open() then return end
    if fire_for(st, now, "triggerbot") then
        System.__triggerbot.__parries = System.__triggerbot.__parries + 1
    end
end

on_retarget = function(ball, st)
    if System.__triggerbot.__enabled then return trigger(ball, st) end
    if not cfg.instant then return end
    local root = autoparry_root()
    if root then decide(ball, st, root, clock_(), "retarget") end
end

ParryLog.describe = function()
    local root = getRoot()
    if not root then return {} end
    for _, ball in ipairs(get_live_balls()) do
        local st = get_ball_state(ball)
        if st.target == me then
            local heading, _, _, distance = read_ball(ball, root)
            return {pass = st.pass_id, dist = distance, heading = heading}
        end
    end
    return {}
end

local function autoparry_step()
    local root = autoparry_root()
    if not root then return end
    local now = clock_()
    for _, ball in ipairs(get_live_balls()) do
        if ball:FindFirstChild('AeroDynamicSlashVFX') then
            ball.AeroDynamicSlashVFX:Destroy(); props.__tornado_time = tick()
        end
        local st = get_ball_state(ball)
        if st.target == me then decide(ball, st, root, now) else try_preparry(ball, st, root, now) end
    end
end

local function triggerbot_step()
    if not System.__triggerbot.__enabled then return end
    for _, ball in ipairs(get_live_balls()) do
        local st = get_ball_state(ball)
        if st.target == me then trigger(ball, st) end
    end
end

-- Run at four points of every frame, so the newest ball position is acted on
-- at the first point after it arrives. A pass can't be parried twice, so the
-- extra checks never double up.
local SIGNALS = {"PreSimulation", "Heartbeat", "PreRender", "PreAnimation"}
local function run_every_point(key, fn, label)
    local conns = props.__connections
    if conns[key] then return end
    local last_error
    local function run()
        local ok, err = pcall(fn)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] " .. label .. ": " .. tostring(err))
        end
    end
    local list = {}
    for i, name in ipairs(SIGNALS) do
        pcall(function()
            list[#list + 1] = RunService[name]:Connect(i == 1 and function(dt)
                if dt then props.__frame_dt = dt end
                run()
            end or run)
        end)
    end
    conns[key] = list
end
local function stop_points(key)
    local list = props.__connections[key]
    if not list then return end
    for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
    props.__connections[key] = nil
end

function System.autoparry.start() run_every_point("__autoparry", autoparry_step, "auto parry") end
function System.autoparry.stop() stop_points("__autoparry") end
function System.triggerbot.loop() triggerbot_step() end
function System.triggerbot.enable(enabled)
    System.__triggerbot.__enabled = enabled
    if enabled then
        run_every_point("__triggerbot", triggerbot_step, "triggerbot")
    else
        stop_points("__triggerbot")
        System.__triggerbot.__is_parrying = false
        System.__triggerbot.__parries = 0
    end
end

-- ------------------------------------------------------------
-- HOOK-FREE: learn once from a capture, then build the packet with no hook
-- ------------------------------------------------------------
-- After a hook capture (we then know the true remote, hash, id and key), every
-- piece is looked for in places that need no hook: the game's Net folder, the
-- game's _G, attributes / StringValues under you, your character,
-- ReplicatedStorage and Workspace, the Data replion, and incoming remote events.
-- The key is also tried against simple ways of making it from the id. Whatever
-- is found is written to BladeBall/hookfree.json (the "recipe"). When the
-- recipe has all four pieces, later sessions build the packet from it and never
-- hook or press anything; if those parries go unanswered twice in a row it
-- switches back to the hook capture for that server and re-learns.
local RECIPE_FILE = SAVE_FOLDER .. "/hookfree.json"
local function load_recipe()
    local ok, r = pcall(function() return HttpService:JSONDecode(readfile(RECIPE_FILE)) end)
    return ok and type(r) == 'table' and r or nil
end
local function save_recipe(r)
    pcall(function() ensureSaveFolder(); writefile(RECIPE_FILE, HttpService:JSONEncode(r)) end)
end
Core.recipe = load_recipe()

-- Simple ways the key could be made from the id.
local function bytes_op(a, b, op)
    local out = {}
    for i = 1, #a do
        local x, y = a:byte(i), b:byte((i - 1) % #b + 1)
        out[i] = string.char(op(x, y) % 256)
    end
    return table.concat(out)
end
local KEY_RULES = {
    id = function(uid) return uid end,
    TIME = function() return "TIME" end,
    id_TIME = function(uid) return uid .. "TIME" end,
    TIME_id = function(uid) return "TIME" .. uid end,
    reversed_id = function(uid) return uid:reverse() end,
    id_xor_TIME = function(uid) return bytes_op(uid, "TIME", bit32.bxor) end,
    id_plus_TIME = function(uid) return bytes_op(uid, "TIME", function(x, y) return x + y end) end,
    id_minus_TIME = function(uid) return bytes_op(uid, "TIME", function(x, y) return x - y end) end,
    TIME_xor_id = function(uid) return bytes_op("TIME", uid, bit32.bxor) end,
    upper_id = function(uid) return uid:upper() end,
    lower_id = function(uid) return uid:lower() end,
}
local function key_matches(str, key)
    if type(str) ~= 'string' or #str == 0 or #str > 64 then return false end
    for i = 1, #key do
        if str:byte((i - 1) % #str + 1) ~= key[i] then return false end
    end
    return true
end

-- Locations: {where = "player"|"char"|"rs"|"ws", path = {child names}, attr = name or nil}
--            {where = "G", key = name}, {where = "data", path = {keys}},
--            {where = "event", remote = {path from rs}, arg = i, sub = {keys}}
local ROOTS = {player = function() return LocalPlayer end, char = function() return LocalPlayer.Character end,
    rs = function() return ReplicatedStorage end, ws = function() return Workspace end}
local function resolve(loc)
    if type(loc) ~= 'table' then return nil end
    local ok, v = pcall(function()
        if loc.where == "G" then return getrenv()._G[loc.key] end
        if loc.where == "data" then
            local t = Win.data and Win.data:Get()
            for _, k in ipairs(loc.path) do t = type(t) == 'table' and t[k] or nil end
            return t
        end
        if loc.where == "event" then return Core.event_seen and Core.event_seen[loc.id] end
        local inst = ROOTS[loc.where] and ROOTS[loc.where]()
        for _, name in ipairs(loc.path or {}) do inst = inst and inst:FindFirstChild(name) end
        if not inst then return nil end
        if loc.attr then return inst:GetAttribute(loc.attr) end
        return inst.Value
    end)
    return ok and v or nil
end

-- Every readable string, with where it lives: calls visit(loc, value).
local function each_readable(visit)
    local function walk_inst(where, inst, path, depth)
        pcall(function()
            for k, v in pairs(inst:GetAttributes()) do
                if type(v) == 'string' then visit({where = where, path = table.clone(path), attr = k}, v) end
            end
            if inst:IsA("StringValue") then visit({where = where, path = table.clone(path)}, inst.Value) end
        end)
        if depth <= 0 then return end
        for i, c in ipairs(inst:GetChildren()) do
            path[#path + 1] = c.Name
            walk_inst(where, c, path, depth - 1)
            path[#path] = nil
            if i % 200 == 0 then task.wait() end
        end
    end
    walk_inst("player", LocalPlayer, {}, 6)
    if LocalPlayer.Character then walk_inst("char", LocalPlayer.Character, {}, 3) end
    walk_inst("rs", ReplicatedStorage, {}, 5)
    walk_inst("ws", Workspace, {}, 1)
    pcall(function()
        for k, v in pairs(getrenv()._G) do
            if type(v) == 'string' and type(k) == 'string' then visit({where = "G", key = k}, v) end
        end
    end)
    pcall(function()
        local function walk(t, path, depth)
            if depth > 4 then return end
            for k, v in pairs(t) do
                if type(k) == 'string' then
                    path[#path + 1] = k
                    if type(v) == 'table' then walk(v, path, depth + 1)
                    elseif type(v) == 'string' then visit({where = "data", path = table.clone(path)}, v) end
                    path[#path] = nil
                end
            end
        end
        if Win.data then walk(Win.data:Get(), {}, 0) end
    end)
end

-- The parry remote, found with no hook: the only hashed-name RemoteEvent in Net.
local function net_folder()
    local ok, net = pcall(function() return ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"].net end)
    return ok and net or nil
end
local function hashed_remotes()
    local list, net = {}, net_folder()
    if net then
        for _, r in ipairs(net:GetChildren()) do
            if r:IsA("RemoteEvent") and r.Name:match("^RE/%x+$") and #r.Name >= 36 then list[#list + 1] = r end
        end
    end
    return list
end

-- Watch incoming remote events for a value (id or key), for the rest of the
-- session. found(desc, value) is called the first time it shows up.
local function find_path(v, pred, path, depth)
    if pred(v) then return path end
    if type(v) == 'table' and depth < 3 then
        for k, x in pairs(v) do
            if type(k) == 'string' or type(k) == 'number' then
                path[#path + 1] = k
                local p = find_path(x, pred, path, depth + 1)
                if p then return p end
                path[#path] = nil
            end
        end
    end
    return nil
end
local function watch_events(pred, found)
    task.spawn(function()
        for i, r in ipairs(ReplicatedStorage:GetDescendants()) do
            if r:IsA("RemoteEvent") then
                local rel = {}
                local p = r
                while p and p ~= ReplicatedStorage do table.insert(rel, 1, p.Name); p = p.Parent end
                pcall(function()
                    local conn
                    conn = r.OnClientEvent:Connect(function(...)
                        for j = 1, select('#', ...) do
                            local sub = find_path((select(j, ...)), pred, {}, 0)
                            if sub then
                                pcall(function() conn:Disconnect() end)
                                found({where = "event", id = table.concat(rel, "/") .. "#" .. j, remote = rel, arg = j, sub = table.clone(sub)})
                                return
                            end
                        end
                    end)
                end)
            end
            if i % 300 == 0 then task.wait() end
        end
    end)
end
-- For a recipe whose id/key arrives by event: keep the latest value.
Core.event_seen = {}
local function listen_recipe_event(loc)
    if type(loc) ~= 'table' or loc.where ~= "event" then return end
    pcall(function()
        local r = ReplicatedStorage
        for _, n in ipairs(loc.remote) do r = r:FindFirstChild(n) end
        r.OnClientEvent:Connect(function(...)
            local v = (select(loc.arg, ...))
            for _, k in ipairs(loc.sub or {}) do v = type(v) == 'table' and v[k] or nil end
            if type(v) == 'string' then Core.event_seen[loc.id] = v end
        end)
    end)
end
if Core.recipe then listen_recipe_event(Core.recipe.uid); listen_recipe_event(Core.recipe.key) end

local function recipe_summary(r)
    local function mark(x) return x and "found" or "NOT found" end
    return ("remote %s, hash %s, id %s, key %s"):format(mark(r.remote), mark(r.hash), mark(r.uid), mark(r.key))
end

-- Learn from a hook capture.
local learned = false
local function learn_hookfree(cap)
    if learned or cap.hookfree then return end
    learned = true
    task.spawn(function()
        local r = {version = 1}
        local hr = hashed_remotes()
        if #hr == 1 and hr[1] == cap.remote then r.remote = "net_hashed" end
        pcall(function()
            local g = getrenv()._G
            if g.BAC_HASH == cap.hash then r.hash = "BAC_HASH" else
                for k, v in pairs(g) do if v == cap.hash and type(k) == 'string' then r.hash = k; break end end
            end
        end)
        for name, f in pairs(KEY_RULES) do
            local ok, s = pcall(f, cap.uid)
            if ok and key_matches(s, cap.key) then r.key = {where = "rule", rule = name}; break end
        end
        each_readable(function(loc, v)
            if not r.uid and v == cap.uid then r.uid = loc end
            if not r.key and key_matches(v, cap.key) then r.key = loc end
        end)
        local function finish()
            r.complete = (r.remote and r.hash and r.uid and r.key) and true or false
            Core.recipe = r
            save_recipe(r)
            flight("HOOK-FREE check: " .. recipe_summary(r) .. (r.complete and " -> next sessions need no hook" or " -> still needs the hook"))
            Notify("Hook-free check", recipe_summary(r) .. (r.complete and ". Next sessions need no hook." or ". Still needs the hook."), 8)
        end
        finish()
        -- id / key may arrive by remote event later on: keep watching
        if not r.uid then
            watch_events(function(v) return v == cap.uid end, function(loc)
                r.uid = loc; listen_recipe_event(loc); finish()
            end)
        end
        if not r.key then
            watch_events(function(v) return key_matches(v, cap.key) end, function(loc)
                r.key = loc; listen_recipe_event(loc); finish()
            end)
        end
    end)
end
Core.learn_hookfree = learn_hookfree

-- Build the packet pieces from the recipe -- no hook, nothing pressed.
local function build_hookfree()
    local r = Core.recipe
    if not (r and r.complete) or Core.hookfree_off then return nil end
    local hr = hashed_remotes()
    if #hr ~= 1 then return nil end
    local hash
    pcall(function() hash = getrenv()._G[r.hash] end)
    local uid = resolve(r.uid)
    if type(hash) ~= 'string' or type(uid) ~= 'string' or uid == '' then return nil end
    local keysrc
    if r.key.where == "rule" then
        local f = KEY_RULES[r.key.rule]
        keysrc = f and f(uid)
    else
        keysrc = resolve(r.key)
    end
    if type(keysrc) ~= 'string' or #keysrc == 0 then return nil end
    local text = tostring(math.floor(Workspace:GetServerTimeNow() * 100))
    local key = {}
    for i = 1, #text do key[i] = keysrc:byte((i - 1) % #keysrc + 1) end
    local ball2 = false
    pcall(function() ball2 = require(ReplicatedStorage.Shared.UseBall2)() == true end)
    return {remote = hr[1], hash = hash, uid = uid, key = key, len = #text, ball2 = ball2, hookfree = true}
end

-- Housekeeping, once a frame: auto press while not armed (the only time the
-- block button/key is ever pressed in Remote mode -- once captured, every parry
-- is a remote parry; it presses again only if the game deletes the remote),
-- report the capture, log unanswered parries, and sample ping.
RunService.Heartbeat:Connect(function()
    sample_lag() -- keep the ping average current between balls too
    if not is_live() then return end
    if not Core.cap then
        Core.told = false
        -- the recipe first: no hook, nothing pressed
        if Core.recipe and Core.recipe.complete and not Core.hookfree_off and clock_() - (Core.hf_try or 0) > 1 then
            Core.hf_try = clock_()
            local cap = build_hookfree()
            if cap then
                Core.cap = cap
                Core.misses, Core.pending = 0, nil
                flight(("ARMED HOOK-FREE: remote %s, id %s"):format(cap.remote.Name:sub(1, 12), cap.uid))
                return
            end
        end
        if canParryNow() then
            Core.can_since = Core.can_since or clock_()
            prime_remote()
        else
            Core.can_since = nil
        end
        return
    end
    if not Core.told then
        Core.told = true
        Core.info = (Core.cap.hookfree and "armed with NO hook" or "armed") .. " (" .. (Core.cap.ball2 and "UseBall2" or "normal") .. " server)"
        Notify("Blade Ball", Core.cap.hookfree and "Remote armed with no hook. Auto parry is live." or "Remote armed. Auto parry is live.", 3)
    end
    local nc = Core.new_capture
    if nc then
        Core.new_capture = nil
        local cap, prev = Core.cap, nc.prev
        learn_hookfree(cap)
        local keystr = table.concat(cap.key, ",")
        local changed
        if prev then
            local list = {}
            if prev.remote ~= cap.remote then list[#list + 1] = "REMOTE" end
            if prev.uid ~= cap.uid then list[#list + 1] = "ID" end
            if prev.hash ~= cap.hash then list[#list + 1] = "HASH" end
            if table.concat(prev.key, ",") ~= keystr then list[#list + 1] = "KEY" end
            changed = table.concat(list, " ")
        end
        flight(("CAPTURED (%s hook%s): remote %s, id %s, %s server%s"):format(capture_method(), Core.isolated and ", isolated" or ", NOT isolated", tostring(cap.remote.Name), tostring(cap.uid),
            cap.ball2 and "UseBall2" or "normal",
            prev and (changed ~= "" and (" -- CHANGED since last capture: " .. changed) or " -- same as last capture") or ""))
    end
    if Core.pending and clock_() > Core.pending then
        Core.pending, Core.misses = nil, (Core.misses or 0) + 1
        local lp = Core.last_parry
        flight(("  -> NO answer to the %s (miss %d in a row)"):format(lp and lp.via or "parry", Core.misses))
        if Core.cap.hookfree and Core.misses >= 2 then
            Core.hookfree_off, Core.cap, learned = true, nil, false
            flight("hook-free parries unanswered twice: back to the hook capture for this server (re-learning)")
            Notify("Blade Ball", "No-hook mode didn't work on this server; capturing with the hook instead.", 5)
        end
    end
end)
end -- parry core

-- ============================================================
-- SPAM ENGINE (rewritten)
-- ============================================================
-- Manual and auto spam share one pump. Spam isn't held by the parry gate (the
-- game's cooldown): it keeps sending through it, and the server takes the first
-- one it can. What it is held by is your connection: every parry packet carries
-- every player's screen point, and once upload backs up your movement queues
-- behind it (the "I'm ahead of where I really am" desync). So:
--   * never more than SpamNet.hard_max a second, whatever the slider says
--     (120; 90 if your upload rate can't be read, since then the guard below
--     is blind);
--   * at most per_frame() per frame -- the server counts one parry per frame,
--     the rest only fill upload;
--   * the upload guard eases off while the client's real send rate is over
--     budget and comes back once it's clear;
--   * manual spam with no ball on or near you drops to a keep-alive rate.
System.manual_spam = {}
System.auto_spam = {}
local props = System.__properties
local me = LocalPlayer.Name
local macroAnimFix = false
local ManualSpam = {rate = 300} -- parries per second (slider)
local AutoSpam = {rate = 250, active_until = 0, reason = nil, was_active = false}
local SpamNet = {
    idle_rate = 20,
    hard_max = 120,
    blind_max = 90,
    budget_kbps = 220,
    guard_at = -1,
    factor = 1,
    readable = false,
}

function System.manual_spam.start() System.__properties.__manual_spam_enabled = true end
function System.manual_spam.stop() System.__properties.__manual_spam_enabled = false end

local function spam_fire()
    if getgenv().ManualSpamMode == "Keypress" then
        System.parry.keypress()
        return true
    end
    local sent = System.parry.fast()
    if sent and getgenv().ManualSpamAnimationFix and macroAnimFix then
        -- a block swing per landed parry, the way a held block key plays
        System.animation.play_block()
    end
    return sent
end

-- ---------- auto spam: when does one timed parry stop being enough? ----------
-- reach = how long a parry sent now takes to be up, against the ball we see
-- (ping + view lag + jitter, see TIMING). React = a couple of frames to notice.
local function spam_reach() return Core.reach_time() end
local function react_time() return math.clamp(props.__frame_dt or 1 / 60, 1 / 240, 0.1) * 2 + 0.02 end

-- The ball's recent owners, newest first (blank targets dropped, repeats merged).
local function ball_owners(state)
    local owners = {}
    for i = #state.swaps, 1, -1 do
        local s = state.swaps[i]
        if type(s.to) == 'string' and s.to ~= '' then
            local last = owners[#owners]
            if last and last.name == s.to then last.t = s.t
            else owners[#owners + 1] = {name = s.to, t = s.t} end
        end
    end
    return owners
end

-- Clash range grows with ball speed: a 300 st/s exchange spans more ground.
local function clash_range(speed) return math.clamp(18 + speed * 0.06, 18, 45) end

-- A clash: the ball traded back and forth between you and one player, each
-- hand-off about as quick as the ball crossing plus both reactions. Returns the
-- opponent and how many quick hand-offs in a row.
local function clash_with(st, root, speed, now)
    local owners = ball_owners(st)
    local newest, second = owners[1], owners[2]
    if not second then return nil end
    local opponent
    if newest.name == me then opponent = second.name
    elseif second.name == me then opponent = newest.name
    else return nil end
    local their = character_root(opponent)
    if not their then return nil end
    local gap = (their.Position - root.Position).Magnitude
    if gap > clash_range(speed) then return nil end
    local tempo = math.clamp(gap / speed * 2 + spam_reach() * 2 + 0.15, 0.3, 0.8)
    if now - newest.t > tempo then return nil end
    local hits = 0
    for i = 1, #owners - 1 do
        local cur, prev = owners[i], owners[i + 1]
        local alt = (cur.name == me and prev.name == opponent) or (cur.name == opponent and prev.name == me)
        if not alt or cur.t - prev.t > tempo then break end
        hits = hits + 1
    end
    -- right up close (or the ball crosses faster than you react) one hand-off
    -- is enough; otherwise it has to come back once
    local need = (gap <= 10 or gap / speed <= spam_reach()) and 1 or 2
    if hits < need then return nil end
    return opponent, hits
end

-- Why auto spam should run for this ball right now, or nil.
local function spam_reason(ball, root, now)
    local st = get_ball_state(ball)
    local heading, _, speed, distance, velocity = read_ball(ball, root)
    if speed < 1 then return nil end
    local reach, react = spam_reach(), react_time()

    local opponent, hits = clash_with(st, root, speed, now)
    if opponent and (st.target == me or st.target == opponent) then
        return ("clash vs %s (%d hits)"):format(opponent, hits)
    end

    if st.target == me then
        -- coming in faster than a parry sent now could be up for, and auto parry
        -- hasn't got one up for this pass
        if heading <= 0.3 and distance > 6 then return nil end
        if st.parried and now < (st.parry_until or 0) then return nil end
        if math.max(distance - 3, 0) / speed <= reach + react then return "point blank" end
        return nil
    end

    -- On a player next to you whose return would beat your reach (this is most
    -- of what high ping loses at close range): spam through their hit.
    local target = st.target
    if type(target) ~= 'string' or target == '' then return nil end
    local their = character_root(target)
    if not their then return nil end
    local gap = (their.Position - root.Position).Magnitude
    if gap > clash_range(speed) then return nil end
    local back = gap / (speed * 1.1)
    if back > reach + react then return nil end
    local to = their.Position - ball.Position
    local d = to.Magnitude
    if d > 3 and velocity:Dot(to / d) < speed * 0.3 then return nil end
    if d / speed + back <= reach + react + 0.1 then return "close return from " .. target end
    return nil
end

-- Lobby training or lobby parry: auto spam never runs there.
local function in_training()
    if LocalPlayer:GetAttribute("LobbyTraining") or LocalPlayer:GetAttribute("LobbyParry") then return true end
    local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
    return char ~= nil and dead ~= nil and char.Parent == dead
end

-- Once per frame. Keeps spam on a short tail past the last reason (about a
-- round trip), so it covers the hit it was started for.
local function auto_spam_evaluate()
    if not props.__auto_spam_enabled then
        AutoSpam.active_until, AutoSpam.reason = 0, nil
        return
    end
    local now = os.clock()
    local root = getRoot()
    if root and not root:FindFirstChild('SingularityCape') and canParryNow() and not blocked_by_detection()
        and not in_training() then
        for _, ball in ipairs(get_live_balls()) do
            local reason = spam_reason(ball, root, now)
            if reason then
                AutoSpam.active_until = now + math.clamp(spam_reach() * 1.5 + 0.05, 0.12, 0.45)
                AutoSpam.reason = reason
                return
            end
        end
    end
    if now >= AutoSpam.active_until then AutoSpam.reason = nil end
end

function System.auto_spam.status()
    if not props.__auto_spam_enabled then return "off" end
    if os.clock() < AutoSpam.active_until then return "SPAMMING (" .. tostring(AutoSpam.reason or "clash") .. ")" end
    return "watching"
end

-- ---------- the pump ----------
local SpamMeter = {count = 0, since = os.clock(), rate = 0}
function System.spam_actual_rate() return SpamMeter.rate end

-- A ball on you or able to reach you within about a reach: every parry counts.
local function spam_focus()
    local root = getRoot()
    if not root then return false end
    local horizon = spam_reach() + 0.25
    for _, ball in ipairs(get_live_balls()) do
        get_ball_state(ball) -- makes sure its retarget listener exists (instant fire)
        if ball:GetAttribute('target') == me then return true end
        local speed = ball_velocity(ball).Magnitude
        if speed > 1 and (ball.Position - root.Position).Magnitude / speed <= horizon then return true end
    end
    return false
end

-- Upload guard, checked 10x a second: over budget it cuts the rate hard
-- (down to half per check), under budget it climbs back gently. Spam can run
-- faster because this reacts before upload has time to queue movement.
local function bandwidth_factor(now)
    if now - SpamNet.guard_at < 0.1 then return SpamNet.factor end
    SpamNet.guard_at = now
    local ok, kbps = pcall(function() return Stats.DataSendKbps end)
    SpamNet.readable = ok and type(kbps) == 'number' and kbps > 0
    if SpamNet.readable then
        local step = math.clamp(SpamNet.budget_kbps / kbps, 0.5, 1.1)
        SpamNet.factor = math.clamp(SpamNet.factor * step, 0.2, 1)
    end
    return SpamNet.factor
end

local Pump = {credit = 0, last = os.clock(), on = false, frame = 0, frame_fires = 0, fired_frame = -1}
local function current_source(now)
    if props.__manual_spam_enabled then return ManualSpam.rate, "manual spam" end
    if props.__auto_spam_enabled and now < AutoSpam.active_until then return AutoSpam.rate, "auto spam" end
    return nil
end
local function effective_rate(rate, now)
    local factor = bandwidth_factor(now)
    rate = math.min(rate, SpamNet.readable and SpamNet.hard_max or SpamNet.blind_max)
    if not spam_focus() then rate = math.min(rate, SpamNet.idle_rate) end
    return math.max(rate * factor, 1)
end
local function per_frame(rate)
    return math.max(1, math.ceil(rate * math.clamp(props.__frame_dt or 1 / 60, 1 / 240, 0.1) - 1e-6))
end

local function fire_one(source)
    if Pump.fired_frame ~= Pump.frame then Pump.fired_frame, Pump.frame_fires = Pump.frame, 0 end
    ParryLog.source = source
    local ok = spam_fire()
    ParryLog.source = nil
    Pump.frame_fires = Pump.frame_fires + 1
    SpamMeter.count = SpamMeter.count + 1
    return ok
end

local function spam_tick()
    local now = os.clock()
    local elapsed = math.min(now - Pump.last, 0.1)
    Pump.last = now
    local span = now - SpamMeter.since
    if span >= 0.5 then
        SpamMeter.rate = SpamMeter.count / span
        SpamMeter.count, SpamMeter.since = 0, now
    end
    local rate, source = current_source(now)
    if not rate or not LocalPlayer.Character then
        Pump.credit, Pump.on = 0, false
        return
    end
    rate = effective_rate(rate, now)
    if Pump.on then
        Pump.credit = math.min(Pump.credit + elapsed * rate, 2) -- no backlog after a hitch
    else
        Pump.credit, Pump.on = 1, true -- a burst's first parry goes straight away
    end
    if Pump.credit < 1 - 1e-6 then return end -- (float error would drop one a frame)
    if Pump.fired_frame == Pump.frame and Pump.frame_fires >= per_frame(rate) then return end
    Pump.credit = Pump.credit - 1
    fire_one(source)
end

-- The moments a fresh parry matters most: ours just landed (the ball is on its
-- way back) and the ball has just turned to us. Fire one from the event itself,
-- inside the same caps, rather than waiting for the next tick.
local function spam_instant()
    local now = os.clock()
    local rate, source = current_source(now)
    if not rate or not LocalPlayer.Character then return end
    rate = effective_rate(rate, now)
    if Pump.fired_frame == Pump.frame and Pump.frame_fires >= per_frame(rate) then return end
    Pump.credit = math.max(Pump.credit - 1, -1)
    Pump.on = true
    fire_one(source)
end
Remotes.ParrySuccess.OnClientEvent:Connect(function() pcall(spam_instant) end)
System.spam_on_retarget = function() pcall(spam_instant) end

do
    local last_error
    local function run(fn)
        local ok, err = pcall(fn)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] spam: " .. tostring(err))
        end
    end
    local conns = props.__connections
    conns.__spam_pre = RunService.PreSimulation:Connect(function()
        Pump.frame = Pump.frame + 1
        run(auto_spam_evaluate)
        -- auto spam just switched on: its first parry goes now, not next point
        local active = os.clock() < AutoSpam.active_until
        if active and not AutoSpam.was_active and not props.__manual_spam_enabled then run(spam_instant) end
        AutoSpam.was_active = active
        run(spam_tick)
    end)
    conns.__spam_heartbeat = RunService.Heartbeat:Connect(function() run(spam_tick) end)
    pcall(function() conns.__spam_render = RunService.PreRender:Connect(function() run(spam_tick) end) end)
    pcall(function() conns.__spam_anim = RunService.PreAnimation:Connect(function() run(spam_tick) end) end)
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
    gui.DisplayOrder = 9998; gui.Parent = HUI
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
-- Live-editable Ability ESP settings, read by the update loop.
local AbilityESPConfig = {
    Color = Color3.fromRGB(255, 255, 255),
    TextSize = 14,
    Height = 3.5,          -- studs above the head
    ShowName = true,       -- show the player's display name
    ShowDistance = false,  -- append distance in studs
    OnlyWithAbility = false, -- only show players who have an ability equipped
    MaxDistance = 0,       -- 0 = unlimited; otherwise hide beyond this many studs
    ShowActive = true,     -- "ACTIVE 2.4s" while their ability is running
    ShowCooldown = true,   -- "CD 6.1s" / "READY"
}

-- Scoped so its helpers don't count against the main chunk's 200-local limit;
-- start_ability_esp / stop_ability_esp are globals used by the menu.
do
-- One shared loop (10x a second) updates every label, instead of a Heartbeat
-- connection per player, and only writes a label's text or style when it
-- actually changed.
local abilityEspEntries = {}       -- player -> {billboard, label, character, head, text, color, size, height}
local abilityEspCharConns = {}     -- player -> CharacterAdded connection
local abilityEspPlayerAddedConnection = nil
local abilityEspLoop = nil

local function esp_escape(s)
    return (tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

-- The ability line for one player, from what the game itself replicates:
--   name     player's EquippedAbility (or the character's Ability)
--   version  player.Upgrades.<ability> level: 1 -> "V1", 2 -> "V2" (0 = base)
--   active   player's AbilityDurationStart + AbilityDuration (server time), the
--            same pair the game's own ability duration bar reads; falls back to
--            the character's AbilityActive flag when there's no duration
--   cooldown the character's CooldownExpiration (server time)
local function esp_ability_info(player, character)
    local ability = player:GetAttribute('EquippedAbility') or (character and character:GetAttribute('Ability'))
    if not ability or ability == '' then return nil end
    local name = tostring(ability)
    local upgrades = player:FindFirstChild('Upgrades')
    local level_value = upgrades and upgrades:FindFirstChild(name)
    local level = level_value and level_value.Value
    if type(level) == 'number' and level > 0 then name = name .. ' V' .. level end

    local now = Workspace:GetServerTimeNow()
    local status
    if AbilityESPConfig.ShowActive then
        local start = player:GetAttribute('AbilityDurationStart') or 0
        local duration = player:GetAttribute('AbilityDuration') or 0
        local left = (start > 0 and duration > 0) and (start + duration - now) or 0
        if left > 0 then
            status = ('<font color="#5CFF7A">ACTIVE %.1fs</font>'):format(left)
        elseif character and character:GetAttribute('AbilityActive') then
            status = '<font color="#5CFF7A">ACTIVE</font>'
        end
    end
    if not status and AbilityESPConfig.ShowCooldown then
        local expires = (character and character:GetAttribute('CooldownExpiration')) or player:GetAttribute('CooldownExpiration')
        if type(expires) == 'number' then
            local left = expires - now
            if left > 0 and left < 600 then
                status = ('<font color="#FF6A6A">CD %.1fs</font>'):format(left)
            else
                status = '<font color="#B4B4B4">READY</font>'
            end
        end
    end
    return name, status
end

local function remove_ability_esp_entry(player)
    local e = abilityEspEntries[player]
    if e then pcall(function() e.billboard:Destroy() end) end
    abilityEspEntries[player] = nil
end

local function update_ability_esp()
    local myRoot = getRoot()
    local cfg = AbilityESPConfig
    for player, e in pairs(abilityEspEntries) do
        local character, head = e.character, e.head
        if not (character and character.Parent and head and head.Parent) then
            remove_ability_esp_entry(player)
        else
            local dist = myRoot and (myRoot.Position - head.Position).Magnitude
            local name, status = esp_ability_info(player, character)
            local visible = not (cfg.MaxDistance > 0 and dist and dist > cfg.MaxDistance)
                and not (cfg.OnlyWithAbility and not name)
            if e.label.Visible ~= visible then e.label.Visible = visible end
            if visible then
                if e.color ~= cfg.Color then e.color = cfg.Color; e.label.TextColor3 = cfg.Color end
                if e.size ~= cfg.TextSize then e.size = cfg.TextSize; e.label.TextSize = cfg.TextSize end
                if e.height ~= cfg.Height then e.height = cfg.Height; e.billboard.StudsOffset = Vector3.new(0, cfg.Height, 0) end
                local parts = {}
                if cfg.ShowName then parts[#parts + 1] = esp_escape(player.DisplayName) end
                if name then parts[#parts + 1] = '[' .. esp_escape(name) .. ']' end
                if cfg.ShowDistance and dist then parts[#parts + 1] = ('%.0fm'):format(dist) end
                if #parts == 0 then parts[1] = esp_escape(player.DisplayName) end
                local text = '<b>' .. table.concat(parts, ' ') .. '</b>'
                if status then text = text .. '\n' .. status end
                if text ~= e.text then e.text = text; e.label.Text = text end
            end
        end
    end
end

local function create_ability_esp_for_player(player)
    task.spawn(function()
        local character = player.Character
        while getgenv().AbilityESP and (not character or not character.Parent) do task.wait(0.5); character = player.Character end
        if not character then return end
        local head = character:WaitForChild('Head', 10)
        if not head or not getgenv().AbilityESP then return end
        remove_ability_esp_entry(player)
        -- The billboard lives in our hidden container and only points at the head
        -- (Adornee). Parenting it INTO the head put a foreign BillboardGui in
        -- another player's character in Workspace, where the game can see it.
        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'AbilityESPGui'; billboard.Adornee = head
        billboard.Size = UDim2.new(0, 220, 0, 60)
        billboard.StudsOffset = Vector3.new(0, AbilityESPConfig.Height, 0); billboard.AlwaysOnTop = true
        billboard.Parent = HUI
        local label = Instance.new('TextLabel')
        label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1
        label.TextColor3 = AbilityESPConfig.Color; label.TextSize = AbilityESPConfig.TextSize
        label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
        label.RichText = true; label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center; label.Parent = billboard
        label.Visible = false
        abilityEspEntries[player] = {
            billboard = billboard, label = label, character = character, head = head,
            color = AbilityESPConfig.Color, size = AbilityESPConfig.TextSize, height = AbilityESPConfig.Height,
        }
    end)
end

local function add_ability_esp_player(player)
    if player == LocalPlayer then return end
    if abilityEspCharConns[player] then pcall(function() abilityEspCharConns[player]:Disconnect() end) end
    abilityEspCharConns[player] = player.CharacterAdded:Connect(function() create_ability_esp_for_player(player) end)
    if player.Character then create_ability_esp_for_player(player) end
end

function start_ability_esp()
    if abilityEspLoop then return end
    getgenv().AbilityESP = true
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then add_ability_esp_player(player) end
    end
    abilityEspPlayerAddedConnection = Players.PlayerAdded:Connect(function(player)
        if getgenv().AbilityESP then add_ability_esp_player(player) end
    end)
    local acc = 0
    abilityEspLoop = RunService.Heartbeat:Connect(function(dt)
        acc = acc + dt
        if acc < 0.1 then return end
        acc = 0
        pcall(update_ability_esp)
    end)
end

function stop_ability_esp()
    getgenv().AbilityESP = false
    if abilityEspLoop then pcall(function() abilityEspLoop:Disconnect() end); abilityEspLoop = nil end
    if abilityEspPlayerAddedConnection then
        pcall(function() abilityEspPlayerAddedConnection:Disconnect() end)
        abilityEspPlayerAddedConnection = nil
    end
    for _, connection in pairs(abilityEspCharConns) do pcall(function() connection:Disconnect() end) end
    abilityEspCharConns = {}
    for player in pairs(abilityEspEntries) do remove_ability_esp_entry(player) end
end
end -- ability ESP scope

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
    frame.Parent = gui; gui.Parent = HUI
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
PingGui.Parent = HUI

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
    if getgenv().AutoParryMode == "Keypress" then return "Mode: Keypress (presses the block key)" end
    local w = parry_window()
    local wtxt = w and ("%.3f"):format(w) or (Win.done and "fallback" or "reading stats...")
    if remoteReady() then
        return ("Remote: %s. window=%s. No hook up, no memory reads"):format(tostring(Core.info), wtxt)
    end
    return "Remote: " .. tostring(Core.info) .. " (window=" .. wtxt .. ")"
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
                local why = Core.why(ball)
                if target == LocalPlayer.Name and why then text = text .. "  |  auto parry: " .. why end
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
AP:AddDropdown("CaptureHook", {Text = "Capture hook", Values = {"Namecall", "FireServer", "Both"}, Default = "Namecall",
    Tooltip = "Which hook catches the one parry packet Remote mode needs (up for that press only). Namecall or FireServer alone may take two presses; Both arms in one. The flight log notes which one was on for every capture and kick.",
    Callback = function(v) getgenv().CaptureHook = v end})
AP:AddDropdown("ParryMode", {Text = "Parry mode", Values = {"Remote", "Keypress"}, Default = "Remote",
    Tooltip = "Remote fires the parry remote with your curve (hookless, sends exactly what the game sends). Keypress presses the block key (F).",
    Callback = function(v) getgenv().AutoParryMode = v end})
AP:AddDropdown("CurveMode", {Text = "Curve mode", Values = System.__config.__curve_names, Default = "Camera",
    Callback = function(v)
        for i, n in ipairs(System.__config.__curve_names) do if n == v then System.__properties.__curve_mode = i; break end end
    end})
AP:AddDropdown("TargetMode", {Text = "Target mode", Values = System.__config.__target_names, Default = "Cursor",
    Tooltip = "Who the ball goes to (separate from curve). Cursor: player under your mouse. Camera: player nearest screen centre. Closest/Farthest: by distance to you. Random: a random player. Needs remote parry mode.",
    Callback = function(v)
        for i, n in ipairs(System.__config.__target_names) do if n == v then System.__properties.__target_mode = i; break end end
    end})
AP:AddSlider("Accuracy", {Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "How tight the parry is to the ball. 100: the ball lands just after your parry comes up, with only your measured lag swings as cushion. 1: it lands 60% into your parry, the most room for a lag spike or the ball speeding up. Always kept inside the parry.",
    Callback = function(v) System.__properties.__accuracy_base = v; roll_accuracy() end})
AP:AddSlider("TimingMultiplier", {Text = "Timing multiplier", Default = 1, Min = 0, Max = 2, Rounding = 2, Suffix = "x",
    Tooltip = "Moves the parry from what Accuracy picks. 1 = Accuracy's pick. Higher parries earlier (2 = the earliest that still lands), lower parries later (0 = the last moment that still lands). Never pushed outside your parry window.",
    Callback = function(v) System.__properties.__timing_mult = v end})
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
AP:AddSlider("CloseRange", {Text = "Pre-parry range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Tooltip = "How close the player holding the ball has to be for close-range pre-parry.",
    Callback = function(v) Core.cfg.close_range = v end})
AP:AddToggle("InstantRetarget", {Text = "Instant parry on retarget", Default = true,
    Tooltip = "Parries straight off the ball switching to you when there's no time to wait: it lands within a round trip, or it's point blank. Anything with more time is timed normally.",
    Callback = function(v) Core.cfg.instant = v end})
AP:AddToggle("HighPingClose", {Text = "High ping close range", Default = true,
    Tooltip = "At 80ms+ ping: when a player next to you is about to hit the ball and their return would beat your ping, parries ahead so it's up in time (only then). Timed by Accuracy / Timing multiplier like any parry.",
    Callback = function(v) Core.cfg.hp_close = v end})
AP:AddToggle("ClosePreParry", {Text = "Close-range pre-parry", Default = false,
    Tooltip = "Off by default. Parries ahead when a player next to you is about to hit the ball and a return would be too fast to react to. It's a guess: if they send it elsewhere or curve it, it was wasted. Auto spam is the better tool for clashes.",
    Callback = function(v) Core.cfg.preparry = v end})
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
    Tooltip = "Parries per second while a ball is on or near you (20/s otherwise). Tops out at one per send point (4 per frame) and eases off automatically if your upload gets too high.",
    Callback = function(v) ManualSpam.rate = v end})
local ManualSpamLabel = SP:AddLabel("Actual: 0/s", true)
SP:AddToggle("SpamAnimFix", {Text = "Animation fix", Default = false, Callback = function(v)
    getgenv().ManualSpamAnimationFix = v
    macroAnimFix = v
end})

local AS = Tabs.Spam:AddRightGroupbox("Auto Spam", "activity")
AS:AddToggle("AutoSpam", {Text = "Auto spam", Default = false,
    Tooltip = "Spams only when one timed parry can't keep up: a clash (the ball traded back and forth with a player), a ball on you closer than your ping lets a parry come up in time, or a player next to you about to hit a ball whose return would beat your ping. Worked out from ball speed, your ping and its swings. Capped so it never backs up your upload (no desync). Never runs in training.",
    Callback = function(v)
        System.__properties.__auto_spam_enabled = v
        if v then prime_remote() else AutoSpam.active_until, AutoSpam.reason = 0, nil end
        NotifyToggle("Auto Spam", v)
    end})
local AutoSpamLabel = AS:AddLabel("Status: off", true)
AS:AddSlider("AutoSpamRate", {Text = "Spam rate", Default = 250, Min = 20, Max = 1000, Rounding = 0, Suffix = " /s",
    Tooltip = "Parries per second while a clash is detected. Tops out at one per send point (4 per frame) and eases off automatically if your upload gets too high, so your movement stays in sync.",
    Callback = function(v) AutoSpam.rate = v end})

task.spawn(function()
    while task.wait(0.1) do
        if Library.Unloaded then break end
        if Library.Toggled then
            local actual = System.spam_actual_rate()
            local props = System.__properties
            local auto_text = "Status: " .. System.auto_spam.status()
            if not props.__manual_spam_enabled and actual >= 1 then
                auto_text = auto_text .. ("  |  %d/s"):format(math.floor(actual + 0.5))
            end
            AutoSpamLabel:SetText(auto_text)
            ManualSpamLabel:SetText(("Actual: %d/s"):format(props.__manual_spam_enabled and math.floor(actual + 0.5) or 0))
        end
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
AE:AddToggle("AbilityESPActive", {Text = "Show active time", Default = true,
    Tooltip = "Shows ACTIVE and the seconds left while their ability is running.",
    Callback = function(v) AbilityESPConfig.ShowActive = v end})
AE:AddToggle("AbilityESPCooldown", {Text = "Show cooldown", Default = true,
    Tooltip = "Shows the seconds left on their ability cooldown, or READY.",
    Callback = function(v) AbilityESPConfig.ShowCooldown = v end})
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
    for _, conn in pairs(System.__properties.__connections) do
        if type(conn) == 'table' then
            for _, c in ipairs(conn) do pcall(function() c:Disconnect() end) end
        else
            pcall(function() conn:Disconnect() end)
        end
    end
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
    pcall(function() Core.unhook() end)
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

-- Flight recorder: kick message, a heartbeat, and every toggle change.
do
    local GuiService = cloneref(game:GetService('GuiService'))
    local exec = "?"
    pcall(function() exec = table.concat({identifyexecutor()}, " ") end)
    flight(("==== v%s loaded | executor %s | place %s | userId %s"):format(
        SCRIPT_VERSION, exec, tostring(game.PlaceId), tostring(LocalPlayer.UserId)))
    local conns = {}
    table.insert(conns, GuiService.ErrorMessageChanged:Connect(function(msg)
        local reason = tostring(msg):match("BAC%s+%w-X(%d%d)")
        flight("!!!! KICK / ERROR MESSAGE: " .. tostring(msg) .. (reason and (" [reason " .. reason .. "]") or "")
            .. " [capture hook " .. tostring(getgenv().CaptureHook or "Namecall") .. "]")
    end))
    table.insert(conns, Remotes.ParrySuccess.OnClientEvent:Connect(function() flight("ParrySuccess received") end))
    local function where()
        local char = LocalPlayer.Character
        local alive = char and char.Parent == Alive
        local balls = Workspace:FindFirstChild('Balls')
        return ("%s, %d ball(s)"):format(alive and "in match" or "lobby/dead", balls and #balls:GetChildren() or 0)
    end
    task.spawn(function()
        local on, last_spam, beat = {}, 0, 0
        while is_live() and not Library.Unloaded do
            for name, t in pairs(Toggles) do
                local v = type(t) == 'table' and t.Value == true
                if v ~= (on[name] == true) then
                    on[name] = v
                    flight(("toggle %s = %s"):format(tostring(name), v and "ON" or "OFF"))
                end
            end
            beat = beat + 1
            if beat % 5 == 0 or ParryLog.spam ~= last_spam then
                flight(("beat: %s | heap %dKB | sends %d, spam sends %d | modes parry=%s spam=%s | remote %s"):format(
                    where(), math.floor(gcinfo()), ParryLog.total, ParryLog.spam, tostring(getgenv().AutoParryMode),
                    tostring(getgenv().ManualSpamMode), remoteReady() and "armed" or tostring(Core.info)))
                last_spam = ParryLog.spam
            end
            task.wait(1)
        end
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        flight("==== unloaded")
    end)
end

UIReady = true
Notify("Blade Ball", "Loaded. " .. (isMobile and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)

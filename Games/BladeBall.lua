-- Blade Ball
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).

task.spawn(function()

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options = Library.Options
local Toggles = Library.Toggles

-- Ui3 autoloads the saved config as each element is created, which runs that
-- element's callback. So the window goes up first (for notifications), and
-- every tab and element is added at the bottom of this file, once everything
-- the callbacks touch exists.
local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "auto parry",
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

-- Reading the stat is not free, and the parry loop asks for it every frame.
local ping_cache, ping_at = 0, 0
local function getPing()
    local now = os.clock()
    if now - ping_at > 0.2 then
        local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
        if ok and ping then ping_cache = ping end
        ping_at = now
    end
    return ping_cache
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char.PrimaryPart
end

-- ============================================================
-- AZURE TOKEN SYSTEM
-- ============================================================
local _token
local _tokenFound = false
for _, Function in getgc(true) do
    if type(Function) ~= 'function' or not debug.info(Function, 's'):find('PRY', 1, true) then continue end
    for _, value in debug.getupvalues(Function) do
        if type(value) == 'function' then
            _token = value
            _tokenFound = true
            break
        end
    end
    if _token then break end
end

if not _tokenFound then
    Notify("Blade Ball", "Remote not found!", 5)
    return
end

Notify("Blade Ball", "Parry once to hook the remote (inside the circle works best)", 4)

function _tokenize(_remote_uid)
    local time = tostring(math.floor(workspace:GetServerTimeNow() * 100))
    local key = _token(_remote_uid, 'TIME')
    local characters = table.create(#time)
    for index = 1, #time do
        characters[index] = string.char(bit32.bxor(
            (string.byte(time, index) + index) % 256,
            string.byte(key, (index - 1) % #key + 1)
        ))
    end
    return table.concat(characters)
end

local _capturedRemote = nil
local _capturedArgs = nil

-- Catching the parry remote. The game's parry call has to be seen once to
-- learn which remote it uses and its first two arguments.
--
-- 1. hookfunction on the FireServer / InvokeServer functions themselves.
--    This only runs when a remote is fired, not on every property read like
--    an __index hook, so it can stay on until the remote is caught: a parry
--    anywhere catches it, not just inside the circle.
-- 2. A __namecall hook (remote:FireServer(...) style calls), which runs on
--    every method call in the game, so it's only on while a ball is inside
--    the capture circle and comes off again when it leaves.
-- 3. If the executor has no hookfunction, the old __index metatable hook is
--    used instead, also only while a ball is in the circle.
--
-- Only a packet shaped like a parry (id, uid, token, number, CFrame,
-- {screen points}, {x, y}, ...) is taken, so another remote with 8+
-- arguments can't be mistaken for it. Calls this script makes are ignored.
local _checkcaller = checkcaller or function() return false end
local _newcclosure = newcclosure or function(f) return f end
local _armed = false      -- ball inside the circle: per-call hooks are live
local _unloaded = false
local _destroyConn

local function _isParryPacket(n, args)
    return n >= 8
        and typeof(args[5]) == 'CFrame'
        and type(args[6]) == 'table'
        and type(args[7]) == 'table'
end

local function _isRemote(obj, method)
    if typeof(obj) ~= 'Instance' then return false end
    local ok, class = pcall(function() return obj.ClassName end)
    if not ok then return false end
    return (method == 'FireServer' and class == 'RemoteEvent')
        or (method == 'InvokeServer' and class == 'RemoteFunction')
end

local _unhook

local function _capture(remote, args)
    _capturedRemote, _capturedArgs = remote, args
    task.defer(function()
        _unhook()
        -- If the game swaps the remote out, go back to waiting for the new one.
        if _destroyConn then _destroyConn:Disconnect() end
        _destroyConn = remote.AncestryChanged:Connect(function(_, parent)
            if parent == nil and _capturedRemote == remote then
                _capturedRemote, _capturedArgs = nil, nil
                Notify("Blade Ball", "Parry remote changed. Parry once to catch the new one.", 4)
            end
        end)
        Notify("Blade Ball", "Remote hooked", 3)
    end)
end

-- Called from inside a hook with the game's own arguments. Cheap when there's
-- nothing to do: one flag check, then out.
local function _inspect(self, method, ...)
    if _unloaded or _capturedRemote then return end
    local n = select('#', ...)
    if n < 8 or _checkcaller() then return end
    local args = {...}
    if not _isParryPacket(n, args) or not _isRemote(self, method) then return end
    _capture(self, args)
end

-- 1. hookfunction: on for the whole session, pass-through once caught.
local _fnHooked = false
pcall(function()
    if not hookfunction then return end
    local probes = {
        FireServer = Instance.new('RemoteEvent').FireServer,
        InvokeServer = Instance.new('RemoteFunction').InvokeServer,
    }
    for method, fn in pairs(probes) do
        local old
        old = hookfunction(fn, _newcclosure(function(self, ...)
            _inspect(self, method, ...)
            return old(self, ...)
        end))
        _fnHooked = true
    end
end)

-- 2 / 3. Per-call metamethod hooks, only while a ball is in the circle.
local _getnamecallmethod = getnamecallmethod
local _ncOld, _ncFn = nil, nil
local _meta, _idxOld, _idxFn = nil, nil, nil

local function _hookNamecall()
    if _ncFn or not (hookmetamethod and _getnamecallmethod) then return end
    local old
    local fn = _newcclosure(function(self, ...)
        if _armed and not _capturedRemote then
            local method = _getnamecallmethod()
            if method == 'FireServer' or method == 'InvokeServer' then
                _inspect(self, method, ...)
            end
        end
        return old(self, ...)
    end)
    local ok = pcall(function() old = hookmetamethod(game, '__namecall', fn) end)
    if ok and old then _ncOld, _ncFn = old, fn end
end

local function _unhookNamecall()
    if not _ncFn then return end
    -- Only put the old one back if nothing hooked on top of ours since.
    -- Otherwise leave ours in place; disarmed, it's a plain pass-through.
    local ok, cur = pcall(function() return getrawmetatable(game).__namecall end)
    if ok and cur == _ncFn then
        pcall(hookmetamethod, game, '__namecall', _ncOld)
        _ncOld, _ncFn = nil, nil
    end
end

local function _hookIndex()
    if _idxFn or not getrawmetatable then return end
    _meta = getrawmetatable(game)
    local old = rawget(_meta, '__index')
    _idxOld = old
    _idxFn = function(self, key)
        if not _armed or _capturedRemote or (key ~= 'FireServer' and key ~= 'InvokeServer') or _checkcaller() then
            return old(self, key)
        end
        local method = old(self, key)
        if not _isRemote(self, key) then return method end
        return function(this, ...)
            _inspect(self, key, ...)
            return method(this, ...)
        end
    end
    setreadonly(_meta, false)
    _meta.__index = _idxFn
    setreadonly(_meta, true)
end

local function _unhookIndex()
    if not _idxFn then return end
    if rawget(_meta, '__index') == _idxFn then
        setreadonly(_meta, false)
        _meta.__index = _idxOld
        setreadonly(_meta, true)
        _meta, _idxOld, _idxFn = nil, nil, nil
    end
end

local function _hook()
    if _unloaded then return end
    _armed = true
    _hookNamecall()
    if not _fnHooked then pcall(_hookIndex) end
end

_unhook = function()
    _armed = false
    pcall(_unhookNamecall)
    pcall(_unhookIndex)
end

local function _unhookAll()
    _unloaded = true
    _unhook()
end

task.delay(30, function()
    if not _capturedRemote then
        Notify("Blade Ball", "Remote not caught yet. Parry once, ideally with the ball in the circle.", 5)
    end
end)

-- The screen points and aim spot only change between frames, so spam firing
-- several times in one frame builds them once. The packet itself is unchanged.
local FRAME = 1 / 240
local screen_cache = {at = 0, aim = nil, data = nil}
local function screenData()
    local now = os.clock()
    if screen_cache.data and now - screen_cache.at < FRAME then
        return screen_cache.aim, screen_cache.data
    end
    local cam = workspace.CurrentCamera
    local aim_target
    if isMobile then
        local vp = cam.ViewportSize
        aim_target = {math.floor(vp.X / 2), math.floor(vp.Y / 2)}
    else
        local ok, mouse = pcall(function() return UserInputService:GetMouseLocation() end)
        if ok and mouse then
            aim_target = {math.floor(mouse.X), math.floor(mouse.Y)}
        else
            local vp = cam.ViewportSize
            aim_target = {math.floor(vp.X / 2), math.floor(vp.Y / 2)}
        end
    end
    local event_data = {}
    if Alive then
        for _, entity in pairs(Alive:GetChildren()) do
            if entity.PrimaryPart then
                local ok, sp = pcall(function() return cam:WorldToScreenPoint(entity.PrimaryPart.Position) end)
                if ok then event_data[entity.Name] = sp end
            end
        end
    end
    screen_cache.at, screen_cache.aim, screen_cache.data = now, aim_target, event_data
    return aim_target, event_data
end

local function fireParryRemote(curveCF)
    if not _capturedRemote or not _capturedArgs then return false end
    local cam = workspace.CurrentCamera
    local aim_target, event_data = screenData()
    local packet = {
        _capturedArgs[1], _capturedArgs[2], _tokenize(_capturedArgs[2]),
        0.5, curveCF or cam.CFrame, event_data, aim_target, false
    }
    pcall(function()
        if _capturedRemote:IsA('RemoteEvent') then _capturedRemote:FireServer(unpack(packet))
        elseif _capturedRemote:IsA('RemoteFunction') then _capturedRemote:InvokeServer(unpack(packet)) end
    end)
    return true
end

local function remoteReady()
    return _capturedRemote ~= nil and _capturedArgs ~= nil
end

-- Presses the block key. Only used by the "Keypress" modes.
local function pressBlockKey()
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)
end


-- ============================================================
-- SYSTEM
-- ============================================================
local System = {
    __properties = {
        __autoparry_enabled = false, __triggerbot_enabled = false,
        __manual_spam_enabled = false, __play_animation = false,
        __curve_mode = 1, __accuracy = 50, __divisor_multiplier = 1.1,
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
        __curve_hotkeys = true, __retry_delay = 0.6,
        __spam_rate = 100, __auto_spam_enabled = false, __auto_spam_range = 20
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
-- Everything asks for the balls several times a frame, so the list is built
-- once per frame. Treat the returned table as read-only.
System.ball = {}
local ball_cache = {at = 0, list = {}, training = {}}
local no_collide = setmetatable({}, {__mode = 'k'})
local function collectBalls(folder, into)
    if not folder then return end
    for _, ball in ipairs(folder:GetChildren()) do
        if ball:GetAttribute('realBall') then
            if not no_collide[ball] then no_collide[ball] = true; pcall(function() ball.CanCollide = false end) end
            table.insert(into, ball)
        end
    end
end
local function refreshBalls()
    local now = os.clock()
    if now - ball_cache.at < FRAME then return end
    ball_cache.at = now
    ball_cache.list = {}
    ball_cache.training = {}
    collectBalls(Workspace:FindFirstChild('Balls'), ball_cache.list)
    collectBalls(Workspace:FindFirstChild('TrainingBalls'), ball_cache.training)
end
function System.ball.get()
    refreshBalls()
    return ball_cache.list[1]
end
function System.ball.get_all()
    refreshBalls()
    return ball_cache.list
end
function System.ball.get_training()
    refreshBalls()
    return ball_cache.training
end

-- ============================================================
-- CAPTURE CIRCLE
-- ============================================================
-- Until the parry remote is caught, a ring is drawn around you. The
-- per-call hooks (__namecall, or __index without hookfunction) are only on
-- while a ball is inside it, which is when you'd parry anyway. Once caught,
-- the ring goes away and this loop does nothing.
local CAPTURE_RADIUS = 35
local CaptureRing = Instance.new('Part')
CaptureRing.Name = 'BladeBall_CaptureRing'; CaptureRing.Shape = Enum.PartType.Cylinder
CaptureRing.Size = Vector3.new(0.2, CAPTURE_RADIUS * 2, CAPTURE_RADIUS * 2)
CaptureRing.Anchored = true; CaptureRing.CanCollide = false; CaptureRing.CanQuery = false
CaptureRing.CanTouch = false; CaptureRing.CastShadow = false
CaptureRing.Material = Enum.Material.ForceField; CaptureRing.Transparency = 0.3
local RING_IDLE, RING_HOOKED = Color3.fromRGB(0, 170, 255), Color3.fromRGB(0, 255, 120)
CaptureRing.Color = RING_IDLE
local RING_TILT = CFrame.Angles(0, 0, math.rad(90))

local function ballInRing(root)
    for _, list in ipairs({System.ball.get_all(), System.ball.get_training()}) do
        for _, ball in ipairs(list) do
            if (ball.Position - root.Position).Magnitude <= CAPTURE_RADIUS then return true end
        end
    end
    return false
end

System.__properties.__connections.__capture_ring = RunService.Heartbeat:Connect(function()
    if remoteReady() then
        if CaptureRing.Parent then CaptureRing.Parent = nil end
        return
    end
    local root = getRoot()
    if not root then
        if _armed then _unhook() end
        CaptureRing.Parent = nil
        return
    end
    CaptureRing.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.9, 0)) * RING_TILT
    CaptureRing.Parent = workspace.CurrentCamera
    local inside = ballInRing(root)
    if inside and not _armed then _hook()
    elseif not inside and _armed then _unhook() end
    CaptureRing.Color = inside and RING_HOOKED or RING_IDLE
end)

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

System.parry = {}
-- "Remote" fires the parry remote with the chosen curve. "Keypress" presses the
-- block key.
-- The curve is cached for the frame too, so a spam burst doesn't redo the
-- on-screen target search for every fire.
local curve_cache = {at = 0, cf = nil}
local function curveForFrame()
    local now = os.clock()
    if not curve_cache.cf or now - curve_cache.at >= FRAME then
        curve_cache.cf = System.curve.get_cframe()
        curve_cache.at = now
    end
    return curve_cache.cf
end
function System.parry.execute()
    if not LocalPlayer.Character then return end
    fireParryRemote(curveForFrame())
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end
function System.parry.keypress()
    if not LocalPlayer.Character then return end
    pressBlockKey()
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end
function System.parry.execute_action() System.animation.play_grab_parry(); System.parry.execute() end
function System.parry.by_mode(mode)
    if mode == "Keypress" then System.parry.keypress() else System.parry.execute_action() end
end

local function linear_predict(a,b,t) return a+(b-a)*t end
System.detection = { __ball_properties = {__aerodynamic_time=tick(),__last_warping=tick(),__lerp_radians=0,__curving=tick()} }
function System.detection.is_curved()
    local props = System.detection.__ball_properties
    local ball = System.ball.get(); if not ball then return false end
    local zoomies = ball:FindFirstChild("zoomies"); if not zoomies then return false end
    local velocity = zoomies.VectorVelocity; local speed = velocity.Magnitude
    if speed < 1 then return false end
    local ball_dir = velocity.Unit; local char = LocalPlayer.Character
    if not char or not char.PrimaryPart then return false end
    local pos = char.PrimaryPart.Position; local direction = (pos-ball.Position).Unit
    local dot = direction:Dot(ball_dir)
    local ping = getPing()/1000
    local distance = (pos-ball.Position).Magnitude; local reach_time = distance/speed-ping
    local dot_threshold = math.clamp(0.55-(ping*0.75),-1,0.45)
    local speed_threshold = math.min(speed/100,45)
    local ball_distance_threshold = 15-math.min(distance/1000,15)+speed_threshold
    local clamped_dot = math.clamp(dot,-1,1); local radians = math.asin(clamped_dot)
    props.__lerp_radians = linear_predict(props.__lerp_radians,radians,0.85)
    if props.__lerp_radians < 0.016 then props.__last_warping = tick() end
    if distance < (ball_distance_threshold*0.85) then return false end
    if (tick()-props.__last_warping) < (reach_time/1.4) then return true end
    if (tick()-props.__curving) < (reach_time/1.1) then return true end
    return dot < dot_threshold
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
onNet("RE/SlashesOfFuryActivate", function(player)
    if isLocal(player) then
        System.__properties.__slashesoffury_active = true; System.__properties.__slashesoffury_count = 0
    end
end)
onNet("RE/SlashesOfFuryEnd", function()
    System.__properties.__slashesoffury_active = false; System.__properties.__slashesoffury_count = 0
end)
onNet("RE/SlashesOfFuryParry", function()
    System.__properties.__slashesoffury_count = System.__properties.__slashesoffury_count + 1
end)
onNet("RE/SlashesOfFuryCatch", function()
    task.spawn(function()
        while System.__properties.__slashesoffury_active and System.__properties.__slashesoffury_count < maxParryCount do
            if not System.__config.__detections.__slashesoffury then break end
            System.parry.execute(); task.wait(parryDelay)
        end
    end)
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

Remotes.ParrySuccessAll.OnClientEvent:Connect(function(_, root)
    local myRoot = getRoot()
    if not myRoot or typeof(root) ~= 'Instance' or not root.Parent then return end
    if root.Parent ~= LocalPlayer.Character and root.Parent.Parent ~= Alive then return end
    local closest = System.player.get_closest(); local ball = System.ball.get()
    if not ball or not closest or not closest.PrimaryPart then return end
    local target_distance = (myRoot.Position - closest.PrimaryPart.Position).Magnitude
    local distance = (myRoot.Position - ball.Position).Magnitude
    local velocity = ball.AssemblyLinearVelocity
    if velocity.Magnitude < 1 then return end
    local dot = (myRoot.Position - ball.Position).Unit:Dot(velocity.Unit)
    -- Close-range clash: the opponent parried at point blank, so parry right back.
    if System.__properties.__autoparry_enabled and target_distance < 15 and distance < 15 and dot > -0.25 then
        if System.detection.is_curved() then System.parry.execute_action() end
    end
    if System.__properties.__grab_animation then System.__properties.__grab_animation:Stop() end
end)

Remotes.ParrySuccess.OnClientEvent:Connect(function()
    if not LocalPlayer.Character or LocalPlayer.Character.Parent ~= Alive then return end
    if System.__properties.__grab_animation then System.__properties.__grab_animation:Stop() end
end)

-- ============================================================
-- TRIGGERBOT
-- ============================================================
System.triggerbot = {}
local TRIGGERBOT_COOLDOWN = 0.03
local TRIGGERBOT_PARSE_TIME = 0.02

function System.triggerbot.trigger(ball)
    if System.__triggerbot.__is_parrying or System.__triggerbot.__parries > System.__triggerbot.__max_parries then return end
    if LocalPlayer.Character and LocalPlayer.Character.PrimaryPart and LocalPlayer.Character.PrimaryPart:FindFirstChild('SingularityCape') then return end
    System.__triggerbot.__is_parrying = true
    System.__triggerbot.__parries = System.__triggerbot.__parries + 1
    System.parry.execute()
    if System.__properties.__play_animation then System.animation.play_grab_parry() end
    task.delay(TRIGGERBOT_COOLDOWN, function()
        if System.__triggerbot.__parries > 0 then System.__triggerbot.__parries = System.__triggerbot.__parries - 1 end
    end)
    task.spawn(function()
        local start_time = tick()
        repeat RunService.Heartbeat:Wait()
        until (tick()-start_time >= TRIGGERBOT_PARSE_TIME or not System.__triggerbot.__is_parrying)
        System.__triggerbot.__is_parrying = false
    end)
end

function System.triggerbot.loop()
    if not System.__triggerbot.__enabled then return end
    if LocalPlayer.Character and LocalPlayer.Character.PrimaryPart and LocalPlayer.Character.PrimaryPart:FindFirstChild('SingularityCape') then return end
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:IsA('BasePart') and ball:GetAttribute('target') == LocalPlayer.Name then
            System.triggerbot.trigger(ball)
            break
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
-- MANUAL SPAM / AUTO SPAM
-- ============================================================
System.manual_spam = {}
local macroAnimFix = false
local spam_accumulator = 0
local MAX_FIRES_PER_FRAME = 10

function System.manual_spam.start()
    System.__properties.__manual_spam_enabled = true
end

function System.manual_spam.stop()
    System.__properties.__manual_spam_enabled = false
end

-- Auto spam turns spam on by itself during a close-range clash: the ball is
-- moving, it's on you or the nearest player, and both are within range.
function System.manual_spam.clash()
    local props = System.__properties
    if not props.__auto_spam_enabled then return false end
    local root = getRoot()
    local ball = System.ball.get()
    if not root or not ball then return false end
    local zoomies = ball:FindFirstChild('zoomies')
    if not zoomies or zoomies.VectorVelocity.Magnitude < 5 then return false end
    local target = ball:GetAttribute('target')
    if not target or target == "" then return false end
    local closest = System.player.get_closest()
    if not closest or not closest.PrimaryPart then return false end
    local range = props.__auto_spam_range
    if (root.Position - closest.PrimaryPart.Position).Magnitude > range then return false end
    if (root.Position - ball.Position).Magnitude > range then return false end
    return target == LocalPlayer.Name or target == closest.Name
end

-- Runs before physics each frame, so a fire goes out as early in the frame as
-- possible. The rate is fires per second, spread across frames; a slow frame
-- catches up by up to MAX_FIRES_PER_FRAME instead of bunching hundreds at once.
RunService.PreSimulation:Connect(function(dt)
    local props = System.__properties
    local active = props.__manual_spam_enabled
    if not active then
        local ok, clash = pcall(System.manual_spam.clash)
        active = ok and clash
    end
    if not active or not LocalPlayer.Character then
        spam_accumulator = 0
        return
    end
    local interval = 1 / math.max(props.__spam_rate, 1)
    spam_accumulator = math.min(spam_accumulator + dt, interval * MAX_FIRES_PER_FRAME)
    local keypress = getgenv().ManualSpamMode == "Keypress"
    local fired = 0
    while spam_accumulator >= interval and fired < MAX_FIRES_PER_FRAME do
        spam_accumulator = spam_accumulator - interval
        fired = fired + 1
        if keypress then
            pcall(System.parry.keypress)
        else
            pcall(System.parry.execute)
        end
    end
    -- Once per frame is plenty for the animation; it has its own cooldown.
    if fired > 0 and not keypress and getgenv().ManualSpamAnimationFix and macroAnimFix then
        pcall(System.animation.play_grab_parry)
    end
end)


-- ============================================================
-- AUTO PARRY
-- ============================================================
System.autoparry = {}

-- How far away (studs) a ball moving at `speed` gets parried.
function System.parry_distance(speed)
    local ping_ms = getPing()
    local ping_threshold = math.clamp(ping_ms / 100, 5, 17)
    local capped_speed_diff = math.min(math.max(speed - 9.5, 0), 650)
    local speed_divisor = (2.4 + capped_speed_diff * 0.002) * System.__properties.__divisor_multiplier
    local distance = ping_threshold + math.max(speed / speed_divisor, 9.5)
    if System.__properties.__ping_compensation then
        -- The parry reaches the server about half a round trip later, and the
        -- ball keeps closing in the meantime.
        distance = distance + speed * (ping_ms / 1000) * 0.5
    end
    return distance + System.__properties.__extra_distance
end

-- One state per ball, so with several balls in play parrying one doesn't
-- block the others. The target listener is made once per ball. If the ball is
-- still on us `__retry_delay` seconds after a parry, it parries again.
local ball_state = setmetatable({}, {__mode = 'k'})
local function get_ball_state(ball)
    local state = ball_state[ball]
    if not state then
        state = {parried = false, at = 0}
        ball:GetAttributeChangedSignal('target'):Connect(function() state.parried = false end)
        ball_state[ball] = state
    end
    return state
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

function System.autoparry.step(dt)
    local props = System.__properties
    if not props.__autoparry_enabled or System.__triggerbot.__enabled then return end
    local root = getRoot()
    if not root or root:FindFirstChild('SingularityCape') then return end

    -- Called every frame, not only when a ball is on us: it smooths the curve
    -- angle between calls.
    local curved = System.detection.is_curved()
    local one_ball = System.ball.get()
    local curve_hold = curved and one_ball and one_ball:GetAttribute('target') == LocalPlayer.Name

    local balls = table.clone(System.ball.get_all())
    local training = System.ball.get_training()
    local is_training = {}
    for _, ball in ipairs(training) do
        is_training[ball] = true
        table.insert(balls, ball)
    end

    -- Look one frame ahead: if the ball will be inside the parry range by the
    -- next check, parry now rather than a frame late.
    local frame = math.clamp(dt or 1/60, 0, 0.1)
    local now = tick()
    for _, ball in ipairs(balls) do
        local zoomies = ball:FindFirstChild('zoomies')
        if not zoomies then continue end
        local state = get_ball_state(ball)

        if ball:FindFirstChild('AeroDynamicSlashVFX') then
            ball.AeroDynamicSlashVFX:Destroy(); props.__tornado_time = now
        end

        if state.parried then
            if now - state.at < props.__retry_delay then continue end
            state.parried = false
        end
        if props.__parried then continue end
        if ball:GetAttribute('target') ~= LocalPlayer.Name then continue end

        local tornado = Runtime:FindFirstChild('Tornado')
        if tornado and (now - props.__tornado_time) < (tornado:GetAttribute('TornadoTime') or 1) + 0.314159 then continue end
        if curve_hold and not is_training[ball] then continue end
        if ball:FindFirstChild('ComboCounter') then continue end
        if blocked_by_detection() then return end

        local velocity = zoomies.VectorVelocity
        local speed = velocity.Magnitude
        local offset = root.Position - ball.Position
        local distance = offset.Magnitude
        -- Only the part of the velocity heading at us closes the gap.
        local closing = distance > 0 and math.max(velocity:Dot(offset / distance), 0) or speed
        if distance - closing * frame > System.parry_distance(speed) then continue end

        state.parried = true
        state.at = now
        if not try_ability() then
            System.parry.by_mode(getgenv().AutoParryMode)
        end
    end
end

function System.autoparry.start()
    if System.__properties.__connections.__autoparry then return end
    local last_error
    System.__properties.__connections.__autoparry = RunService.PreSimulation:Connect(function(dt)
        local ok, err = pcall(System.autoparry.step, dt)
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
    local hookedFuncs = {}
    task.spawn(function()
        local remotesToHook = {"ParrySuccessAll", "ParryAttempt", "ParrySuccess", "PlaySound", "PlayVisuals"}
        while task.wait(1) do
            for _, remoteName in ipairs(remotesToHook) do
                local remote = rs.Remotes:FindFirstChild(remoteName)
                if remote and remote:IsA("RemoteEvent") then
                    local ok, conns = pcall(getconnections, remote.OnClientEvent)
                    if ok and type(conns) == "table" then
                        for _, v in ipairs(conns) do
                            local func = v.Function
                            if func and not hookedFuncs[func] then
                                hookedFuncs[func] = true
                                v:Disable()
                                local targetFunc = func
                                local ourFunc
                                ourFunc = function(...)
                                    local args = { ... }
                                    local isLocal = false
                                    for _, arg in ipairs(args) do
                                        if tostring(arg) == LocalPlayer.Name or (typeof(arg) == "Instance" and (arg == LocalPlayer.Character or arg == LocalPlayer)) then
                                            isLocal = true; break
                                        end
                                    end
                                    if isLocal and getgenv().skinChanger then
                                        local fxSword = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
                                        refreshSlashName()
                                        local swordFound = false; local slashFound = false
                                        for i, arg in ipairs(args) do
                                            if type(arg) == "string" then
                                                if fxSword ~= "" and not slashFound and (arg:match("Slash") or arg == "Default" or arg:match("Effect")) then
                                                    args[i] = getgenv().slashName; slashFound = true
                                                elseif fxSword ~= "" and not swordFound then
                                                    local isSword = false
                                                    pcall(function()
                                                        if rs.Shared.ReplicatedInstances.Swords:FindFirstChild(arg) then isSword = true end
                                                    end)
                                                    if isSword or arg == LocalPlayer:GetAttribute("CurrentlyEquippedSword") then
                                                        args[i] = fxSword; swordFound = true
                                                    end
                                                end
                                            end
                                        end
                                        if fxSword ~= "" and not slashFound and type(args[1]) == "string" then args[1] = getgenv().slashName end
                                        if fxSword ~= "" and not swordFound and type(args[3]) == "string" then args[3] = fxSword end
                                    end
                                    if setthreadidentity then pcall(setthreadidentity, 2) end
                                    pcall(targetFunc, unpack(args))
                                end
                                hookedFuncs[ourFunc] = true
                                remote.OnClientEvent:Connect(ourFunc)
                            end
                        end
                    end
                end
            end
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
        billboard.StudsOffset = Vector3.new(0, 3.5, 0); billboard.AlwaysOnTop = true
        billboard.Parent = head
        local label = Instance.new('TextLabel')
        label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1
        label.TextColor3 = Color3.fromRGB(255, 255, 255); label.TextSize = 14
        label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
        label.RichText = true; label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center; label.Parent = billboard
        label.Visible = false
        abilityEspBillboards[player] = label
        local humanoid = character:FindFirstChild('Humanoid')
        if humanoid then humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
        local heartbeatConnection
        -- Text only needs a refresh a few times a second, not every frame.
        local esp_elapsed = 1
        heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
            esp_elapsed = esp_elapsed + dt
            if esp_elapsed < 0.25 then return end
            esp_elapsed = 0
            if not (character and character.Parent) then
                if heartbeatConnection then heartbeatConnection:Disconnect() end
                pcall(function() billboard:Destroy() end)
                abilityEspBillboards[player] = nil; return
            end
            if getgenv().AbilityESP then
                label.Visible = true
                local ability = player:GetAttribute('EquippedAbility')
                if ability then label.Text = '<b>' .. player.DisplayName .. ' [' .. ability .. ']' .. '</b>'
                else label.Text = '<b>' .. player.DisplayName .. '</b>' end
            else label.Visible = false end
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
local RemoteLabel = Overview:AddLabel("Remote: checking...", true)
local TargetLabel = Overview:AddLabel("Ball target: -", true)

local function remoteStatusText()
    if remoteReady() then return "Remote: hooked" end
    return "Remote: waiting. Parry once (inside the circle works best)"
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
            TargetLabel:SetText("Ball target: " .. ((target == nil or target == "") and "-" or tostring(target)))
        end
    end
end)

-- AUTO PARRY TAB
local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {Text = "Auto parry", Default = false, Callback = function(v)
    System.__properties.__autoparry_enabled = v
    System.__properties.__play_animation = v
    if v then System.autoparry.start() else System.autoparry.stop() end
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
    Callback = function(v) System.__properties.__accuracy = v; update_divisor() end})
AP:AddToggle("PingCompensation", {Text = "Ping compensation", Default = true,
    Tooltip = "Parries earlier the higher your ping, by how far the ball moves in half a round trip.",
    Callback = function(v) System.__properties.__ping_compensation = v end})
AP:AddSlider("ExtraDistance", {Text = "Extra distance", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Callback = function(v) System.__properties.__extra_distance = v end})
AP:AddSlider("RetryDelay", {Text = "Retry delay", Default = 0.6, Min = 0.2, Max = 1.5, Rounding = 2, Suffix = "s",
    Tooltip = "If the ball is still on you this long after a parry, parry again.",
    Callback = function(v) System.__properties.__retry_delay = v end})
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
    System.__properties.__manual_spam_enabled = v
    NotifyToggle("Manual Spam", v)
    if not isMobile then return end
    if v then
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
        destroy_mobile_gui(System.__properties.__mobile_guis.manual_spam)
        System.__properties.__mobile_guis.manual_spam = nil
    end
end}):AddKeyPicker("ManualSpamKey", {Default = "E", Mode = "Toggle", SyncToggleState = true, Text = "Manual spam"})
SP:AddSlider("SpamRate", {Text = "Spam speed", Default = 100, Min = 10, Max = 240, Rounding = 0, Suffix = "/s",
    Tooltip = "Parries per second while spamming.",
    Callback = function(v) System.__properties.__spam_rate = v end})
SP:AddDropdown("SpamMode", {Text = "Mode", Values = {"Remote", "Keypress"}, Default = "Remote", Callback = function(v) getgenv().ManualSpamMode = v end})
SP:AddToggle("SpamAnimFix", {Text = "Animation fix", Default = false, Callback = function(v)
    getgenv().ManualSpamAnimationFix = v
    macroAnimFix = v
end})

local AS = Tabs.Spam:AddRightGroupbox("Auto Spam", "swords")
AS:AddToggle("AutoSpam", {Text = "Auto spam", Default = false,
    Tooltip = "Spams by itself during close-range clashes. Uses the spam speed and mode on the left.",
    Callback = function(v)
        System.__properties.__auto_spam_enabled = v
        NotifyToggle("Auto Spam", v)
    end}):AddKeyPicker("AutoSpamKey", {Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto spam"})
AS:AddSlider("AutoSpamRange", {Text = "Clash range", Default = 20, Min = 5, Max = 50, Rounding = 0, Suffix = " studs",
    Tooltip = "Both the ball and the nearest player have to be this close.",
    Callback = function(v) System.__properties.__auto_spam_range = v end})

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
    _unhookAll()
    pcall(function() CaptureRing:Destroy() end)
    if _destroyConn then pcall(function() _destroyConn:Disconnect() end) end
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

UIReady = true
Notify("Blade Ball", "Loaded. " .. (isMobile and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)

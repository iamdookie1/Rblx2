--// OPERATION ONE ------------------------------------------------------------------------------
-- place 72920620366355 (game 8307114974), built against version 2045. Built on Ui3.
--
-- How the game works (as the client shows it, from the dump):
--   Bodies     Every player is a Model in Workspace tagged "Character" with attributes Team
--              ("Red" / "Blue"), UserId, ID, Revealed. It keeps a Humanoid (real Health) and a
--              HumanoidRootPart, but the visible body is built from ten anchored parts
--              (head, torso, leg1, leg2, arm1, arm2, shoulder1, shoulder2, hip1, hip2) that
--              setup_viewmodels moves into Workspace.Viewmodels.Viewmodel[n]. Your own is
--              Workspace.Viewmodels.LocalViewmodel. Dead players' models go to
--              ReplicatedStorage.Garbage.
--   State      ReplicatedStorage.Modules.StateObject.get_all("Character") returns every
--              Character state object keyed by its model: .instance, .states, .values.
--                states.equipped / holding / class_name / look ...   (what they carry)
--                values.viewmodels   the Viewmodel model for that body
--                values.equipped     your gun's item object (.states, .instance, .accuracy)
--   Guns       ReplicatedStorage.Modules.Items.Item.Gun. Its state table has recoil_up,
--              recoil_side, spread, pellets, firerate, accuracy, mag, bullets. recoil_function
--              reads recoil_up / recoil_side every shot and send_shoot reads spread when the
--              gun is client_sided_hitscan, so setting those values locally changes only what
--              your own client does.
--   Teams      Player and Character attribute Team, colours in game.Teams[team]:GetAttribute("Color").
--              Workspace attributes Gamemode, CurrentMap, Round, BestOf, DefuserAvailable.
--   Bomb       The Bomb gamemode keeps one model, Workspace.Bomb (tag "Bomb", Root part,
--              Bomb.enabled BoolValue).
--   Camera     The game drives the camera itself (Character.render_camera), so the aimbot moves
--              the real mouse (mousemoverel) instead of writing the camera CFrame, and the FOV is
--              changed through the camera's OriginalFOV attribute, which the game restores to.
--   Network    ReplicatedStorage.Modules.Net sends everything through one RemoteEvent, one
--              UnreliableRemoteEvent and one RemoteFunction, first argument is the message name;
--              item and character state replicate through each object's StateObject remote.
--
-- Nothing here fires a remote. The ESP and the FOV circle are drawn with the Drawing API, the
-- aimbot only moves your mouse, and the gun changes are local values the game's own client
-- reads, so what the server sees is still your real camera and your real shots. The game has
-- player reports ("cheating") and ranked queues: play like it.

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

local Settings = {
    -- aimbot
    Aimbot = false, AimWhen = "Right mouse", AimPart = "Head", AimFOV = 140, ShowFOV = true,
    Smoothness = 6, AimMaxDistance = 300, VisibleOnly = true, StickyTarget = true, AimTeammates = false,
    -- triggerbot
    Triggerbot = false, TriggerDelay = 60, TriggerHeadOnly = false, TriggerOnlyAiming = true,
    -- gun
    NoRecoil = false, NoSpread = false, RapidFire = false, RapidScale = 1.5,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspHealth = true, EspDistance = true, EspWeapon = true,
    EspClass = false, EspTracer = false, EspTeammates = false, EspMax = 600, EspChams = false,
    BombEsp = false,
    -- world
    Fullbright = false, NoFlash = false, FovChanger = false, FovValue = 80,
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

--// The game's state objects \\--
local Game = {}
do
    local ok, mod = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Modules", 10):WaitForChild("StateObject", 10))
    end)
    Game.SO = ok and type(mod) == "table" and mod or nil

    function Game.characters()
        local so = Game.SO
        if not so then
            return {}
        end
        local ok2, all = pcall(so.get_all, "Character")
        return ok2 and type(all) == "table" and all or {}
    end
    function Game.me()
        local char = LocalPlayer.Character
        return char and Game.characters()[char] or nil
    end
    -- Your gun right now, if you are holding one with states.
    function Game.gun()
        local me = Game.me()
        local item = me and me.values and me.values.equipped
        if type(item) == "table" and type(item.states) == "table" and item.states.recoil_up then
            return item
        end
        return nil
    end
    function Game.teamColor(name)
        local teams = game:GetService("Teams")
        local t = name and teams:FindFirstChild(name)
        local c = t and t:GetAttribute("Color")
        if typeof(c) == "Color3" then
            return c
        end
        if t and typeof(t.TeamColor) == "BrickColor" then
            return t.TeamColor.Color
        end
        return nil
    end
end

--// Who is a target \\--
local Targets = {}
do
    local ENEMY, TEAM = Color3.fromRGB(255, 70, 70), Color3.fromRGB(90, 170, 255)

    function Targets.teammate(model)
        local mine, theirs = LocalPlayer:GetAttribute("Team"), model:GetAttribute("Team")
        return mine ~= nil and mine ~= "" and mine == theirs
    end
    function Targets.color(model, team)
        return Game.teamColor(model:GetAttribute("Team")) or (team and TEAM or ENEMY)
    end
    -- Every other living body that is in the world right now.
    function Targets.list(includeTeam)
        local out = {}
        local mine = LocalPlayer.Character
        for model, obj in Game.characters() do
            if model ~= mine and model.Parent == Workspace then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local root = model:FindFirstChild("HumanoidRootPart")
                if hum and root and hum.Health > 0 then
                    local team = Targets.teammate(model)
                    if includeTeam or not team then
                        local vm = obj.values and obj.values.viewmodels
                        table.insert(out, {
                            model = model, obj = obj, hum = hum, root = root, team = team,
                            vm = (typeof(vm) == "Instance" and vm.Parent) and vm or nil,
                        })
                    end
                end
            end
        end
        return out
    end
    function Targets.part(t, choice)
        local vm = t.vm
        if vm then
            local name = choice == "Head" and "head" or "torso"
            local p = vm:FindFirstChild(name)
            if p then
                return p
            end
        end
        return t.root
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    -- Nothing solid between your camera and the part (bodies don't count).
    function Targets.visible(part)
        local cam = camera()
        if not (cam and part) then
            return false
        end
        local ignore = { cam }
        local vms = Workspace:FindFirstChild("Viewmodels")
        if vms then
            table.insert(ignore, vms)
        end
        for model in Game.characters() do
            table.insert(ignore, model)
        end
        params.FilterDescendantsInstances = ignore
        local from = cam.CFrame.Position
        return Workspace:Raycast(from, part.Position - from, params) == nil
    end
    function Targets.screen(part)
        local cam = camera()
        local sp, on = cam:WorldToViewportPoint(part.Position)
        return Vector2.new(sp.X, sp.Y), on and sp.Z > 0, sp.Z
    end
end

--// Aimbot + triggerbot \\--
local Aim = { target = nil }
local Fov
do
    local function holding()
        local when = Settings.AimWhen
        if when == "Always" then
            return true
        elseif when == "Left mouse" then
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end
    Aim.holding = holding

    local function centre()
        return camera().ViewportSize / 2
    end

    function Aim.pick()
        local best, bestD
        local c = centre()
        for _, t in Targets.list(Settings.AimTeammates) do
            local part = Targets.part(t, Settings.AimPart)
            local sp, on = Targets.screen(part)
            if on then
                local d = (sp - c).Magnitude
                local dist = (part.Position - camera().CFrame.Position).Magnitude
                if d <= Settings.AimFOV and dist <= Settings.AimMaxDistance
                    and (not Settings.VisibleOnly or Targets.visible(part)) and (not bestD or d < bestD) then
                    best, bestD = { t = t, part = part }, d
                end
            end
        end
        return best
    end

    local function stillValid(a)
        if not (a and a.t.model.Parent == Workspace and a.t.hum.Health > 0) then
            return false
        end
        local part = Targets.part(a.t, Settings.AimPart)
        a.part = part
        local sp, on = Targets.screen(part)
        if not on or (sp - centre()).Magnitude > Settings.AimFOV * 1.5 then
            return false
        end
        return not Settings.VisibleOnly or Targets.visible(part)
    end

    function Aim.step()
        if not (Settings.Aimbot and holding()) or typeof(mousemoverel) ~= "function" then
            Aim.target = nil
            return
        end
        if not (Settings.StickyTarget and stillValid(Aim.target)) then
            Aim.target = Aim.pick()
        end
        local a = Aim.target
        if not a then
            return
        end
        local sp = Targets.screen(a.part)
        local d = sp - centre()
        local k = math.max(Settings.Smoothness, 1)
        local dx, dy = d.X / k, d.Y / k
        if math.abs(dx) < 0.4 and math.abs(dy) < 0.4 then
            return
        end
        mousemoverel(math.clamp(dx, -120, 120), math.clamp(dy, -120, 120))
    end

    -- Trigger: fires when your crosshair is on an enemy body.
    local lastShot, armedAt = 0, nil
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    function Aim.trigger()
        if not Settings.Triggerbot or typeof(mouse1click) ~= "function" then
            armedAt = nil
            return
        end
        if Settings.TriggerOnlyAiming and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
            armedAt = nil
            return
        end
        local cam = camera()
        local ignore = { cam }
        local mine = LocalPlayer.Character
        if mine then
            table.insert(ignore, mine)
        end
        local local_vm = Workspace:FindFirstChild("Viewmodels") and Workspace.Viewmodels:FindFirstChild("LocalViewmodel")
        if local_vm then
            table.insert(ignore, local_vm)
        end
        rayParams.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * Settings.AimMaxDistance, rayParams)
        local inst = hit and hit.Instance
        local onEnemy = false
        if inst and inst:GetAttribute("Humanoid") then
            local vm = inst.Parent
            for _, t in Targets.list(Settings.AimTeammates) do
                if t.vm == vm then
                    onEnemy = not Settings.TriggerHeadOnly or inst.Name == "head"
                    break
                end
            end
        end
        if not onEnemy then
            armedAt = nil
            return
        end
        local now = os.clock()
        armedAt = armedAt or now
        if now - armedAt >= Settings.TriggerDelay / 1000 and now - lastShot >= 0.05 then
            lastShot = now
            mouse1click()
        end
    end

    pcall(function()
        Fov = Drawing.new("Circle")
        Fov.Thickness = 1
        Fov.NumSides = 64
        Fov.Filled = false
        Fov.Color = Color3.new(1, 1, 1)
        Fov.Transparency = 0.9
        Fov.Visible = false
    end)
    table.insert(Cleanups, function()
        if Fov then
            pcall(Fov.Remove, Fov)
        end
    end)
end

--// Gun values (local only) \\--
local Gun = { saved = setmetatable({}, { __mode = "k" }) }
do
    local KEYS = { "recoil_up", "recoil_side", "spread", "firerate" }

    local function remember(item)
        local rec = Gun.saved[item]
        if not rec then
            rec = {}
            for _, k in KEYS do
                local st = item.states[k]
                rec[k] = st and st.value
            end
            Gun.saved[item] = rec
        end
        return rec
    end
    local function put(item, key, value)
        local st = item.states[key]
        if st and type(st.value) == "number" then
            st.value = value
        end
    end

    function Gun.step()
        local item = Game.gun()
        if not item then
            return
        end
        local rec = remember(item)
        put(item, "recoil_up", Settings.NoRecoil and 0 or rec.recoil_up)
        put(item, "recoil_side", Settings.NoRecoil and 0 or rec.recoil_side)
        put(item, "spread", Settings.NoSpread and 0 or rec.spread)
        if rec.firerate and rec.firerate > 0 then
            put(item, "firerate", Settings.RapidFire and rec.firerate * Settings.RapidScale or rec.firerate)
        end
    end
    function Gun.restore()
        for item, rec in Gun.saved do
            if type(item) == "table" and type(item.states) == "table" then
                for _, k in KEYS do
                    if rec[k] ~= nil then
                        pcall(put, item, k, rec[k])
                    end
                end
            end
        end
    end
    table.insert(Cleanups, Gun.restore)
end

--// ESP \\--
local Esp = { drawings = {}, chams = {}, bomb = nil }
do
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
        return {
            box = make("Square", { Thickness = 1, Filled = false, Visible = false }),
            outline = make("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0), Visible = false }),
            name = make("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            info = make("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
            hpBack = make("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
            hp = make("Line", { Thickness = 2, Visible = false }),
            tracer = make("Line", { Thickness = 1, Visible = false }),
        }
    end
    local function hide(e)
        for _, d in e do
            d.Visible = false
        end
    end
    local function kill(e)
        for _, d in e do
            pcall(d.Remove, d)
        end
    end
    local function highlightRoot()
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
        local padX, padY = 8, 6
        return minX - padX, minY - padY, maxX + padX, maxY + padY
    end

    local function equippedName(obj)
        local ok, inst = pcall(function()
            return obj.states.equipped:get()
        end)
        if ok and typeof(inst) == "Instance" then
            return inst.Name
        end
        return nil
    end
    local function className(obj)
        local ok, v = pcall(function()
            return obj.states.class_name:get()
        end)
        return ok and v or nil
    end

    function Esp.step()
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
                        if Settings.EspBox and e.box then
                            e.outline.Position, e.outline.Size, e.outline.Visible = Vector2.new(x1, y1), Vector2.new(w, h), true
                            e.box.Position, e.box.Size, e.box.Color, e.box.Visible = Vector2.new(x1, y1), Vector2.new(w, h), color, true
                        else
                            e.box.Visible, e.outline.Visible = false, false
                        end
                        local owner = Players:GetPlayerFromCharacter(t.model)
                        if Settings.EspName and e.name then
                            e.name.Text = owner and owner.DisplayName or t.model.Name
                            e.name.Position, e.name.Color, e.name.Visible = Vector2.new((x1 + x2) / 2, y1 - 16), color, true
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
                            local w2 = equippedName(t.obj)
                            if w2 then
                                table.insert(bits, w2)
                            end
                        end
                        if Settings.EspClass then
                            local c = className(t.obj)
                            if c then
                                table.insert(bits, c)
                            end
                        end
                        if Settings.EspDistance then
                            table.insert(bits, ("%dm"):format(math.floor(dist)))
                        end
                        if #bits > 0 and e.info then
                            e.info.Text = table.concat(bits, "  ")
                            e.info.Position, e.info.Color, e.info.Visible = Vector2.new((x1 + x2) / 2, y2 + 2), Color3.new(1, 1, 1), true
                        else
                            e.info.Visible = false
                        end
                        if Settings.EspTracer and e.tracer then
                            e.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                            e.tracer.To, e.tracer.Color, e.tracer.Visible = Vector2.new((x1 + x2) / 2, y2), color, true
                        else
                            e.tracer.Visible = false
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

        -- Chams: a highlight over the visible body (through walls).
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
                        h.Parent = highlightRoot()
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

        -- The bomb, in the Bomb gamemode.
        local bomb = Settings.BombEsp and CollectionService:GetTagged("Bomb")[1] or nil
        if bomb and bomb.Parent then
            local root = bomb:FindFirstChild("Root") or bomb.PrimaryPart or bomb:FindFirstChildWhichIsA("BasePart")
            local sp, on = root and camera():WorldToViewportPoint(root.Position)
            if root and on and sp.Z > 0 then
                Esp.bomb = Esp.bomb or make("Text", { Size = 14, Center = true, Outline = true, Color = Color3.fromRGB(255, 200, 60) })
                if Esp.bomb then
                    local enabled = bomb:FindFirstChild("enabled", true)
                    Esp.bomb.Text = ("BOMB %dm%s"):format(math.floor((root.Position - camera().CFrame.Position).Magnitude),
                        enabled and enabled.Value == false and " (off)" or "")
                    Esp.bomb.Position, Esp.bomb.Visible = Vector2.new(sp.X, sp.Y), true
                end
            elseif Esp.bomb then
                Esp.bomb.Visible = false
            end
        elseif Esp.bomb then
            Esp.bomb.Visible = false
        end
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
        if Esp.bomb then
            pcall(Esp.bomb.Remove, Esp.bomb)
            Esp.bomb = nil
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
                Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
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

    -- The game restores the camera to its own OriginalFOV attribute after every zoom, so that's
    -- the value to change. Scoped views are left alone.
    local originalFov
    function World.fov()
        local cam = camera()
        if not cam then
            return
        end
        if Settings.FovChanger then
            if originalFov == nil then
                originalFov = cam:GetAttribute("OriginalFOV")
            end
            if cam:GetAttribute("OriginalFOV") ~= Settings.FovValue then
                local zoomed = cam.FieldOfView < (cam:GetAttribute("OriginalFOV") or 70) - 1
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
bind(RunService.RenderStepped, function(dt)
    if not alive() then
        return
    end
    pcall(function()
        if Fov then
            Fov.Visible = Settings.Aimbot and Settings.ShowFOV
            if Fov.Visible then
                Fov.Radius = Settings.AimFOV
                Fov.Position = camera().ViewportSize / 2
            end
        end
        Aim.step()
        Aim.trigger()
        Gun.step()
        Esp.step()
        World.fov()
        World.noFlash()
    end)
end)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "OPERATION ONE",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = UDim2.fromOffset(640, 520),
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
    local Tab = Window:AddTab("Combat", "crosshair", "Aimbot, trigger, gun")
    local A = Tab:AddLeftGroupbox("Aimbot", "crosshair")
    toggle(A, "Aimbot", "Aimbot", "Moves your real mouse toward the closest enemy to your crosshair")
    dropdown(A, "AimWhen", "Aim when", { "Right mouse", "Left mouse", "Always" })
    dropdown(A, "AimPart", "Aim at", { "Head", "Torso" })
    slider(A, "AimFOV", "FOV", 30, 500, 0, " px")
    slider(A, "Smoothness", "Smoothness", 1, 30, 0, "", "Higher is slower and harder to spot")
    slider(A, "AimMaxDistance", "Max distance", 50, 1000, 0, " studs")
    toggle(A, "VisibleOnly", "Visible only", "Ignores enemies behind walls (the game lets bullets pass some thin walls, this doesn't)")
    toggle(A, "StickyTarget", "Sticky target")
    toggle(A, "AimTeammates", "Include teammates")
    toggle(A, "ShowFOV", "Show FOV circle")
    status(A, function()
        local t = Aim.target
        if not t then
            return typeof(mousemoverel) == "function" and "No target" or "mousemoverel missing: the aimbot can't move"
        end
        return "Target: " .. t.t.model.Name
    end)

    local T = Tab:AddRightGroupbox("Triggerbot", "mouse-pointer-click")
    toggle(T, "Triggerbot", "Triggerbot", "Clicks when your crosshair is on an enemy body")
    slider(T, "TriggerDelay", "Delay", 0, 300, 0, " ms")
    toggle(T, "TriggerHeadOnly", "Head only")
    toggle(T, "TriggerOnlyAiming", "Only while aiming", "Only while right mouse is held")

    local G = Tab:AddRightGroupbox("Gun", "target")
    toggle(G, "NoRecoil", "No recoil", "Zeroes recoil_up and recoil_side on your gun, locally")
    toggle(G, "NoSpread", "No spread", "Zeroes the gun's spread value, locally")
    toggle(G, "RapidFire", "Rapid fire", "Raises the fire rate your client allows. Risky: the server may cap it")
    slider(G, "RapidScale", "Rate multiplier", 1, 3, 1, "x")
    status(G, function()
        local item = Game.gun()
        if not item then
            return "No gun in hand"
        end
        local s = item.states
        return ("%s\nrecoil %.2f/%.2f  spread %.2f  rate %d"):format(
            item.instance and item.instance.Name or "gun", s.recoil_up.value or 0, s.recoil_side.value or 0,
            s.spread.value or 0, math.floor(s.firerate.value or 0))
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Players and the bomb")
    local E = Tab:AddLeftGroupbox("Players", "eye")
    toggle(E, "Esp", "ESP")
    toggle(E, "EspBox", "Boxes")
    toggle(E, "EspName", "Names")
    toggle(E, "EspHealth", "Health bar")
    toggle(E, "EspDistance", "Distance")
    toggle(E, "EspWeapon", "Weapon")
    toggle(E, "EspClass", "Class")
    toggle(E, "EspTracer", "Tracers")
    toggle(E, "EspChams", "Chams", "A see-through-walls highlight on each body")
    toggle(E, "EspTeammates", "Teammates too")
    slider(E, "EspMax", "Max distance", 50, 1500, 0, " studs")
    local B = Tab:AddRightGroupbox("World", "map")
    toggle(B, "BombEsp", "Bomb marker", "Where the bomb is, in the Bomb gamemode")
    status(B, function()
        local ws = Workspace
        return ("%s on %s\nRound %s / %s\nYou: %s"):format(
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
    toggle(W, "FovChanger", "FOV changer", "Changes the game's own base FOV; scopes still zoom")
    slider(W, "FovValue", "FOV", 60, 120, 0, "")
    local M = Tab:AddRightGroupbox("Script", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
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

notify(Game.SO and "Loaded" or "Loaded (StateObject module not found: gun and body data won't work)", 4)

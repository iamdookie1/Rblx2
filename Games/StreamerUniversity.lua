--// Fight in a Streamer University --------------------------------------------------------
-- game 7761516673 (Beginner 96711363098766, Main 131145970478334, Pro 116264700690909).
-- Built on Ui3.
--
-- How the game works (as the client sees it):
--   Hits    PlayerScripts.Core.Combat swings, boxes your limb every frame with
--           workspace:GetPartBoundsInBox and, for each enemy it touches that
--           passes Combat.Main.validate (within 10 x combat scale studs,
--           within 120 degrees of your facing, line of sight), sends
--           Net.Fire(combat, "M1Hit", part). Takedown, shove and specials use
--           GetPartBoundsInRadius the same way.
--   Net     ReplicatedStorage.Net.Fire checks WHO called it (debug.info(2,"s"))
--           and tells the server "caller:<script>" when it isn't one of the
--           game's own scripts. So this script never calls or wraps Net.Fire:
--           it calls the combat script's own functions (onM1, onStomp,
--           toggleWeave, ...) and widens the box that script checks, so every
--           remote still comes from the game's own code.
--   Watch   AutoClickWatch reports inhumanly fast clicks, CharacterFx reports
--           a WalkSpeed over 1.3x what's allowed (23 on foot) and a part named
--           FiasuChams in a character, and the server can hand out a delayed
--           24 hour ban. Nothing here clicks, the speed boost stays under that
--           line, and the ESP lives in its own folder, never in characters.

local Players = game:GetService("Players")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__SuUnload then
    pcall(Genv.__SuUnload)
end
Genv.__SuRun = (Genv.__SuRun or 0) + 1
local RUN = Genv.__SuRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__SuRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
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
    -- combat
    Reach = false, ReachExtra = 2, ReachSkills = false, FaceTarget = false, FaceRange = 12, CalmCamera = true,
    AutoM1 = false, AutoM1Range = 8, TargetMode = "Closest", IgnoreParty = true, IgnoreClan = true,
    AutoWeave = false, WeaveRange = 11, WeaveHold = 0.35,
    AutoStomp = false, StompRange = 7, AutoTakedown = false,
    -- esp
    Esp = false, EspHealth = true, EspStyle = true, EspBounty = true, EspStates = true, EspMax = 300,
    BountyOnly = false,
    -- money
    MoneyEsp = false, AutoMoney = false, MoneyRange = 120,
    -- movement / misc
    SpeedOn = false, SpeedMult = 1.25, AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[StreamerU] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Streamer University", Description = text, Time = seconds or 3 })
end
local function character()
    return LocalPlayer.Character
end
local function rootPart()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

--// The combat script's own functions \\--
-- Core.Combat keeps onM1, onStomp and the rest as local functions. They're
-- found by name in the Lua heap and called as they are, exactly like pressing
-- the key, so every remote they send comes from the game's own script.
local Game = { fns = {}, status = "searching" }
do
    local WANT = { onM1 = true, onStomp = true, onTakedown = true, onPush = true, onTackle = true, onSpecial = true,
        toggleWeave = true, watchSwings = true }
    function Game.find()
        if typeof(getgc) ~= "function" then
            Game.status = "your executor has no getgc"
            return
        end
        local found = {}
        for _, f in getgc() do
            if type(f) == "function" and (typeof(islclosure) ~= "function" or islclosure(f)) then
                local okN, name = pcall(debug.info, f, "n")
                if okN and WANT[name] then
                    local okS, src = pcall(debug.info, f, "s")
                    if okS and type(src) == "string" and src:find("Combat", 1, true) and not src:find("Main", 1, true) then
                        found[name] = f
                    end
                end
            end
        end
        Game.fns = found
        local n = 0
        for _ in found do
            n += 1
        end
        Game.status = n > 0 and ("found %d combat functions"):format(n) or "combat functions not found (equip a style once)"
    end
    function Game.call(name, ...)
        local f = Game.fns[name]
        if f then
            task.spawn(pcall, f, ...)
            return true
        end
        return false
    end
    -- The set of swing animation ids, from watchSwings' first upvalue.
    function Game.swingIds()
        local f = Game.fns.watchSwings
        if not f then
            return nil
        end
        local ok, ups = pcall(function()
            return debug.getupvalues(f)
        end)
        if ok and type(ups) == "table" then
            for _, v in ups do
                if type(v) == "table" and next(v) ~= nil then
                    local k = next(v)
                    if type(k) == "string" and k:find("rbxassetid", 1, true) then
                        return v
                    end
                end
            end
        end
        return nil
    end
    task.spawn(Game.find)
    -- Again after respawns and style changes (the script's functions stay the
    -- same, but this also catches them if they weren't loaded yet).
    loop(20, function()
        local need = false
        for name in WANT do
            if not Game.fns[name] then
                need = true
            end
        end
        if need then
            Game.find()
        end
    end)
end

-- Combat.Main.validate uses this: BodyHeightScale / 1.1, at least 1.
local function combatScale(model)
    local hum = model and model:FindFirstChildOfClass("Humanoid")
    local v = hum and hum:FindFirstChild("BodyHeightScale")
    if not v or v.Value <= 0 then
        return 1
    end
    return math.max(v.Value / 1.1, 1)
end

--// Targets \\--
local Target = {}
do
    local function inParty(model)
        local party = _G.IsInParty
        if typeof(party) ~= "Instance" then
            return false
        end
        for _, v in party:GetChildren() do
            if v:IsA("ObjectValue") and v.Value and v.Value.Name == model.Name then
                return true
            end
        end
        return false
    end
    local function sameClan(p)
        local a, b = LocalPlayer:GetAttribute("ClanId") or LocalPlayer:GetAttribute("Clan"), p:GetAttribute("ClanId") or p:GetAttribute("Clan")
        return a ~= nil and a == b
    end
    function Target.info(model)
        local info = model and model:FindFirstChild("CombatInfo")
        return info
    end
    function Target.valid(p)
        local c = p.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local root = c and c:FindFirstChild("HumanoidRootPart")
        if not (c and hum and root and hum.Health > 0 and c:FindFirstChild("CombatInfo")) then
            return false
        end
        if Settings.IgnoreParty and inParty(c) then
            return false
        end
        if Settings.IgnoreClan and sameClan(p) then
            return false
        end
        return true
    end
    -- Best enemy within range: closest, lowest health or highest bounty.
    function Target.pick(range)
        local root = rootPart()
        if not root then
            return nil
        end
        local best, bestScore
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and Target.valid(p) then
                local r = p.Character.HumanoidRootPart
                local d = (r.Position - root.Position).Magnitude
                if d <= range then
                    local score
                    if Settings.TargetMode == "Lowest health" then
                        score = p.Character:FindFirstChildOfClass("Humanoid").Health
                    elseif Settings.TargetMode == "Highest bounty" then
                        local stats = p:FindFirstChild("Stats")
                        local b = stats and stats:FindFirstChild("Bounty")
                        score = -(b and b.Value or 0)
                    else
                        score = d
                    end
                    if not bestScore or score < bestScore then
                        best, bestScore = p, score
                    end
                end
            end
        end
        return best
    end
end

--// Reach: the combat script's own box, grown a little \\--
-- The combat script boxes your arm every frame (GetPartBoundsInBox) and the
-- takedown / shove / special checks use a circle (GetPartBoundsInRadius).
-- Reach keeps the game's own box where it is (on your arm) and only grows it
-- by a few studs, so a hit is still a hit near your arm. The parts it finds
-- are also filtered down to players a hit could really count on (within the
-- server's 10 x combat scale and 120 degrees of your facing): the takedown /
-- shove check gives up on the whole attack at the first part that fails, so
-- extra parts must never reach it. Anything unexpected falls back to the
-- game's own query untouched.
local Reach = { status = "off", hooked = false, grew = 0 }
do
    local function fromCombat()
        if typeof(getcallingscript) ~= "function" then
            return false
        end
        local ok, s = pcall(getcallingscript)
        return ok and typeof(s) == "Instance" and s.Name == "Combat"
    end
    -- Would Combat.Main.validate (client side) accept this model?
    local function hittable(model, me, myPivot)
        local scale = math.max(combatScale(me), combatScale(model))
        local at = model:GetPivot().Position
        local to = at - myPivot.Position
        if to.Magnitude > scale * 10 - 0.5 then
            return false
        end
        if to.Magnitude < 0.01 then
            return true
        end
        return math.deg(math.acos(math.clamp(myPivot.LookVector:Dot(to.Unit), -1, 1))) <= 115
    end
    local function filter(parts)
        local me = character()
        if not me then
            return parts
        end
        local myPivot = me:GetPivot()
        local out, verdict = {}, {}
        for _, part in parts do
            local model = part:FindFirstAncestorWhichIsA("Model")
            local isChar = model and model ~= me and model:FindFirstChildWhichIsA("Humanoid") and model:FindFirstChild("CombatInfo")
            if not isChar then
                table.insert(out, part)
            else
                if verdict[model] == nil then
                    verdict[model] = hittable(model, me, myPivot)
                end
                if verdict[model] then
                    table.insert(out, part)
                end
            end
        end
        return out
    end
    local function grownBox(cf, size)
        local e = math.clamp(Settings.ReachExtra, 0, 5)
        -- The box's Z runs along the arm toward the hand: push it forward by
        -- half the extra and make it e longer and e wider.
        local box = cf * CFrame.new(0, 0, -e / 2)
        return box, size + Vector3.new(e, e, e)
    end
    if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        local old
        local handler = function(self, ...)
            if Settings.Reach and self == Workspace and not (checkcaller and checkcaller()) and alive() then
                local method = getnamecallmethod()
                if method == "GetPartBoundsInBox" or (method == "GetPartBoundsInRadius" and Settings.ReachSkills) then
                    if fromCombat() then
                        local a1, a2, a3 = ...
                        local ok, result = pcall(function()
                            if method == "GetPartBoundsInBox" then
                                -- Only the small arm / tool boxes, not other queries.
                                if typeof(a1) ~= "CFrame" or typeof(a2) ~= "Vector3" or a2.Magnitude > 12 then
                                    return nil
                                end
                                local box, size = grownBox(a1, a2)
                                return filter(old(self, box, size, a3))
                            end
                            if typeof(a1) ~= "Vector3" or type(a2) ~= "number" or a2 > 12 then
                                return nil
                            end
                            return filter(old(self, a1, a2 + math.clamp(Settings.ReachExtra, 0, 5), a3))
                        end)
                        if ok and type(result) == "table" then
                            Reach.grew += 1
                            return result
                        end
                    end
                end
            end
            return old(self, ...)
        end
        local ok = pcall(function()
            old = hookmetamethod(game, "__namecall", (typeof(newcclosure) == "function" and newcclosure(handler)) or handler)
        end)
        if ok and old then
            Reach.hooked = true
            Reach.status = "ready"
            table.insert(Cleanups, function()
                pcall(hookmetamethod, game, "__namecall", old)
            end)
        else
            Reach.status = "couldn't hook namecall"
        end
    else
        Reach.status = "your executor has no hookmetamethod"
    end
end

--// Auto face, auto M1, auto stomp / takedown \\--
local Fight = { info = "off" }
do
    -- Turns you toward them, but only when you're well off (over 50 degrees),
    -- so the camera isn't yanked every tick.
    local function face(r)
        local root = rootPart()
        if not (Settings.FaceTarget and root and r) then
            return
        end
        local to = flat(r.Position - root.Position)
        local look = flat(root.CFrame.LookVector)
        if to.Magnitude < 0.5 or look.Magnitude < 0.1 then
            return
        end
        if look.Unit:Dot(to.Unit) > math.cos(math.rad(50)) then
            return
        end
        local at = r.Position
        root.CFrame = CFrame.lookAt(root.Position, Vector3.new(at.X, root.Position.Y, at.Z))
    end
    local function holdingStyle()
        local c = character()
        return c and c:FindFirstChildOfClass("Tool") ~= nil
    end
    loop(1 / 20, function()
        if not (Settings.FaceTarget or Settings.AutoM1 or Settings.AutoStomp or Settings.AutoTakedown) then
            Fight.info = "off"
            return
        end
        local me = character()
        local myInfo = me and me:FindFirstChild("CombatInfo")
        if myInfo then
            local rag = myInfo:FindFirstChild("Ragdolled")
            if rag and rag.Value then
                return
            end
        end
        local root = rootPart()
        if not root then
            return
        end
        -- Finish off someone who's down.
        if Settings.AutoStomp or Settings.AutoTakedown then
            for _, p in Players:GetPlayers() do
                if p ~= LocalPlayer and Target.valid(p) then
                    local info = p.Character.CombatInfo
                    local rag = info:FindFirstChild("Ragdolled")
                    local r = p.Character.HumanoidRootPart
                    if rag and rag.Value and (r.Position - root.Position).Magnitude <= Settings.StompRange then
                        face(r)
                        if Settings.AutoTakedown and Game.call("onTakedown") then
                            Fight.info = "takedown on " .. p.DisplayName
                        elseif Settings.AutoStomp and Game.call("onStomp") then
                            Fight.info = "stomp on " .. p.DisplayName
                        end
                        return
                    end
                end
            end
        end
        local range = math.max(Settings.FaceTarget and Settings.FaceRange or 0, Settings.AutoM1 and Settings.AutoM1Range or 0)
        local p = Target.pick(range)
        if not p then
            Fight.info = "no one in range"
            return
        end
        local r = p.Character.HumanoidRootPart
        local d = (r.Position - root.Position).Magnitude
        if Settings.FaceTarget and d <= Settings.FaceRange and holdingStyle() then
            face(r)
        end
        if Settings.AutoM1 and d <= Settings.AutoM1Range and holdingStyle() then
            local info = p.Character.CombatInfo
            local rag = info:FindFirstChild("Ragdolled")
            -- M1 doesn't hit someone who's ragdolled (the game skips them).
            if not (rag and rag.Value) then
                if Game.call("onM1") then
                    Fight.info = ("hitting %s (%d studs)"):format(p.DisplayName, math.floor(d))
                else
                    Fight.info = "onM1 not found yet"
                end
            end
        end
    end)
end

--// Calm camera while auto fighting \\--
-- Every punch the game shakes the camera and pulses the FOV
-- (Framework.shakeCam / Framework.zoom). With auto M1 that's nonstop, so
-- while auto M1 is on those are skipped. Hits still show.
do
    local ok, Framework = pcall(function()
        return require(game:GetService("ReplicatedStorage"):WaitForChild("Framework", 5))
    end)
    if ok and type(Framework) == "table" then
        local saved = Genv.__SuFrameworkOriginals
        if saved then
            Framework.shakeCam, Framework.zoom = saved.shake, saved.zoom
        end
        local origShake, origZoom = Framework.shakeCam, Framework.zoom
        if type(origShake) == "function" and type(origZoom) == "function" then
            Genv.__SuFrameworkOriginals = { shake = origShake, zoom = origZoom }
            local function calm()
                return alive() and Settings.CalmCamera and Settings.AutoM1
            end
            Framework.shakeCam = function(kind, ...)
                if calm() and (kind == "Punch" or kind == "Hit") then
                    return
                end
                return origShake(kind, ...)
            end
            Framework.zoom = function(...)
                if calm() then
                    return
                end
                return origZoom(...)
            end
            table.insert(Cleanups, function()
                Framework.shakeCam, Framework.zoom = origShake, origZoom
                Genv.__SuFrameworkOriginals = nil
            end)
        end
    end
end

--// Auto weave (parry) \\--
-- Watches enemies' animators. When one starts a swing animation (the game's
-- own list of swing ids) near you and facing you, you weave for a moment:
-- toggleWeave(true), then toggleWeave(false).
local Weave = { info = "off", count = 0 }
do
    local watched = setmetatable({}, { __mode = "k" })
    local weavingUntil = 0
    local function onSwing(model, track)
        if not (alive() and Settings.AutoWeave) then
            return
        end
        local ids = Weave.ids
        local anim = track and track.Animation
        if not (ids and anim and ids[anim.AnimationId]) then
            return
        end
        local root, r = rootPart(), model:FindFirstChild("HumanoidRootPart")
        if not (root and r) then
            return
        end
        local to = root.Position - r.Position
        if to.Magnitude > Settings.WeaveRange or flat(r.CFrame.LookVector):Dot(flat(to).Unit) < 0.25 then
            return
        end
        local c = character()
        if not (c and c:FindFirstChildOfClass("Tool")) then
            return
        end
        if os.clock() < weavingUntil then
            return
        end
        weavingUntil = os.clock() + Settings.WeaveHold + 0.15
        if Game.call("toggleWeave", true) then
            Weave.count += 1
            Weave.info = "weaved " .. model.Name
            task.delay(Settings.WeaveHold, function()
                Game.call("toggleWeave", false)
            end)
        end
    end
    local function watch(model)
        if watched[model] then
            return
        end
        local hum = model:FindFirstChildOfClass("Humanoid") or model:WaitForChild("Humanoid", 5)
        local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5))
        if not animator then
            return
        end
        watched[model] = true
        bind(animator.AnimationPlayed, function(track)
            onSwing(model, track)
        end)
    end
    local function watchPlayer(p)
        if p == LocalPlayer then
            return
        end
        if p.Character then
            task.spawn(watch, p.Character)
        end
        bind(p.CharacterAdded, function(c)
            task.spawn(watch, c)
        end)
    end
    for _, p in Players:GetPlayers() do
        watchPlayer(p)
    end
    bind(Players.PlayerAdded, watchPlayer)
    loop(3, function()
        Weave.ids = Weave.ids or Game.swingIds()
        if not Settings.AutoWeave then
            Weave.info = "off"
        elseif not Weave.ids then
            Weave.info = "swing list not found yet"
        end
    end)
end

--// ESP \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "SuEsp"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local items = {}
    local function drop(p)
        local e = items[p]
        if e then
            e.hl:Destroy()
            e.bb:Destroy()
            items[p] = nil
        end
    end
    local function flag(info, name)
        local v = info and info:FindFirstChild(name)
        return v and v.Value == true
    end
    loop(0.25, function()
        local root = rootPart()
        for p in items do
            if not (Settings.Esp and p.Parent and p.Character) then
                drop(p)
            end
        end
        if not Settings.Esp then
            return
        end
        for _, p in Players:GetPlayers() do
            local c = p.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local head = c and c:FindFirstChild("Head")
            local stats = p:FindFirstChild("Stats")
            local bountyV = stats and stats:FindFirstChild("Bounty")
            local bounty = bountyV and bountyV.Value or 0
            local dist = (root and head) and (head.Position - root.Position).Magnitude or 0
            local show = p ~= LocalPlayer and hum and head and dist <= Settings.EspMax and (not Settings.BountyOnly or bounty > 0)
            if not show then
                drop(p)
            else
                local e = items[p]
                if not e or e.hl.Adornee ~= c then
                    drop(p)
                    local hl = Instance.new("Highlight")
                    hl.FillTransparency = 0.8
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.Adornee = c
                    hl.Parent = folder
                    local bb = Instance.new("BillboardGui")
                    bb.Size = UDim2.fromOffset(220, 46)
                    bb.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
                    bb.AlwaysOnTop = true
                    bb.Adornee = head
                    bb.Parent = folder
                    local t = Instance.new("TextLabel")
                    t.BackgroundTransparency = 1
                    t.Size = UDim2.fromScale(1, 1)
                    t.Font = Enum.Font.GothamBold
                    t.TextSize = 13
                    t.TextStrokeTransparency = 0.3
                    t.Parent = bb
                    e = { hl = hl, bb = bb, text = t }
                    items[p] = e
                end
                local friendly = not Target.valid(p) and hum.Health > 0
                local color = friendly and Color3.fromRGB(90, 170, 255) or (bounty > 0 and Color3.fromRGB(255, 200, 60) or Color3.fromRGB(255, 80, 80))
                e.hl.FillColor, e.hl.OutlineColor, e.text.TextColor3 = color, color, color
                local lines = { ("%s  [%dm]"):format(p.DisplayName, math.floor(dist)) }
                local second = {}
                if Settings.EspHealth then
                    table.insert(second, ("%d hp"):format(math.floor(hum.Health)))
                end
                if Settings.EspStyle then
                    local ls = p:FindFirstChild("leaderstats")
                    local style = ls and ls:FindFirstChild("Style")
                    if style then
                        table.insert(second, tostring(style.Value))
                    end
                end
                if Settings.EspBounty and bounty > 0 then
                    table.insert(second, ("$%d bounty"):format(bounty))
                end
                if Settings.EspStates then
                    local info = c:FindFirstChild("CombatInfo")
                    local weaving = info and info:FindFirstChild("Weaving")
                    if flag(info, "Ragdolled") then
                        table.insert(second, "DOWN")
                    elseif weaving and weaving.Value then
                        table.insert(second, flag(weaving, "Parrying") and "PARRYING" or "weaving")
                    elseif flag(info, "Blocking") then
                        table.insert(second, "blocking")
                    end
                end
                if #second > 0 then
                    table.insert(lines, table.concat(second, "  "))
                end
                e.text.Text = table.concat(lines, "\n")
            end
        end
    end)
end

--// Money rain \\--
-- Bills fall into workspace.MoneyRain and are picked up within 20 studs
-- (MoneyRainConfig.PickupRange). Auto money walks you to the nearest one.
local Money = { info = "no money rain" }
do
    local folder = Instance.new("Folder")
    folder.Name = "SuMoney"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local marks = {}
    local function bills()
        local rain = Workspace:FindFirstChild("MoneyRain")
        local out = {}
        if rain then
            for _, b in rain:GetChildren() do
                if b:IsA("BasePart") then
                    table.insert(out, b)
                end
            end
        end
        return out
    end
    loop(0.3, function()
        local list = bills()
        local seen = {}
        for _, b in list do
            seen[b] = true
            if Settings.MoneyEsp and not marks[b] then
                local hl = Instance.new("Highlight")
                hl.FillColor = Color3.fromRGB(90, 255, 120)
                hl.OutlineColor = Color3.fromRGB(90, 255, 120)
                hl.FillTransparency = 0.4
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.Adornee = b
                hl.Parent = folder
                marks[b] = hl
            end
        end
        for b, hl in marks do
            if not seen[b] or not Settings.MoneyEsp then
                hl:Destroy()
                marks[b] = nil
            end
        end
        Money.info = #list > 0 and ("%d bills on the ground"):format(#list) or "no money rain"
        if not Settings.AutoMoney or #list == 0 then
            return
        end
        local root, hum = rootPart(), humanoid()
        if not (root and hum and hum.Health > 0) then
            return
        end
        local best, bestD
        for _, b in list do
            local d = (b.Position - root.Position).Magnitude
            if d <= Settings.MoneyRange and (not bestD or d < bestD) then
                best, bestD = b, d
            end
        end
        if best and bestD > 12 then
            hum:MoveTo(best.Position)
            Money.info = ("walking to a bill %d studs away"):format(math.floor(bestD))
        end
    end)
end

--// Speed: under the game's own speed check \\--
-- CharacterFx reports a WalkSpeed over 1.3x what's allowed (23 on foot, the
-- car's speed in a car). The boost multiplies whatever speed the game sets
-- and never goes past 28 on foot.
local Speed = { info = "off" }
do
    local ours = false
    local gameSpeed
    local conn
    local function cap()
        return 28
    end
    local function apply(hum)
        if not (Settings.SpeedOn and gameSpeed and gameSpeed > 0) then
            return
        end
        local want = math.min(gameSpeed * Settings.SpeedMult, cap())
        if math.abs(hum.WalkSpeed - want) > 0.01 then
            ours = true
            hum.WalkSpeed = want
            ours = false
        end
        Speed.info = ("%d -> %d"):format(math.floor(gameSpeed), math.floor(want))
    end
    local function hook(hum)
        if conn then
            conn:Disconnect()
        end
        gameSpeed = hum.WalkSpeed
        conn = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if ours or not alive() then
                return
            end
            gameSpeed = hum.WalkSpeed
            apply(hum)
        end)
        table.insert(Connections, conn)
    end
    loop(0.5, function()
        local hum = humanoid()
        if not hum then
            return
        end
        if not conn or not conn.Connected or hum ~= Speed.hum then
            Speed.hum = hum
            hook(hum)
        end
        -- In a car the game allows more; leave cars alone.
        local seat = hum.SeatPart
        if seat then
            Speed.info = "in a vehicle"
            return
        end
        if Settings.SpeedOn then
            apply(hum)
        elseif gameSpeed and math.abs(hum.WalkSpeed - gameSpeed) > 0.01 then
            ours = true
            hum.WalkSpeed = gameSpeed
            ours = false
            Speed.info = "off"
        end
    end)
    table.insert(Cleanups, function()
        local hum = humanoid()
        if hum and gameSpeed then
            hum.WalkSpeed = gameSpeed
        end
    end)
end

--// Anti-AFK \\--
do
    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, conn in getconnections(LocalPlayer.Idled) do
                if not idled[conn] and pcall(conn.Disable, conn) then
                    idled[conn] = true
                end
            end
        elseif next(idled) then
            for conn in idled do
                pcall(conn.Enable, conn)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for conn in idled do
            pcall(conn.Enable, conn)
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Streamer University",
    Footer = "dookie hub · Ui3",
    Icon = "swords",
    Size = UDim2.fromOffset(640, 500),
    ConfigFolder = "Ui3/StreamerUniversity",
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

do
    local Tab = Window:AddTab("Combat", "swords", "Reach, auto M1, weave")
    local ReachBox = Tab:AddLeftGroupbox("Reach", "expand")
    toggle(ReachBox, "Reach", "Reach expander",
        "Your punches' hit box reaches this far in front of you. The game's own combat script still checks and sends each hit, and the server's limit is 10 studs (more if you're tall), so it never goes past that")
    slider(ReachBox, "ReachExtra", "Extra reach", 0.5, 5, 1, " studs",
        "Added around your arm's own hit box. Start at 2: if hits stop counting, the server is stricter than its shared check, so go lower")
    toggle(ReachBox, "ReachSkills", "Also takedown / shove", "Grows the takedown, shove and special circles by the same amount")
    toggle(ReachBox, "FaceTarget", "Face target", "Turns you toward the nearest enemy while holding a style, only when you're well off to the side (hits must be within 120 degrees of where you face). Off: nothing ever turns you")
    slider(ReachBox, "FaceRange", "Face within", 4, 30, 0, " studs")
    local ReachLabel = ReachBox:AddLabel("...", true)

    local AutoBox = Tab:AddRightGroupbox("Auto", "zap")
    toggle(AutoBox, "AutoM1", "Auto M1",
        "Punches whoever is in range by calling the game's own M1, at your style's real combo speed. No clicks, so the auto clicker check never sees anything")
    slider(AutoBox, "AutoM1Range", "Swing within", 3, 10, 1, " studs")
    AutoBox:AddDropdown("TargetMode", {
        Text = "Target", Values = { "Closest", "Lowest health", "Highest bounty" }, Default = Settings.TargetMode,
        Callback = function(v)
            Settings.TargetMode = v
        end,
    })
    toggle(AutoBox, "CalmCamera", "Calm camera", "While auto M1 is on, skips the camera shake and FOV pulse the game adds to every punch")
    toggle(AutoBox, "IgnoreParty", "Skip party members")
    toggle(AutoBox, "IgnoreClan", "Skip clan members")
    toggle(AutoBox, "AutoStomp", "Auto stomp", "Stomps anyone knocked down near you")
    toggle(AutoBox, "AutoTakedown", "Auto takedown instead", "Uses your takedown on knocked down players instead of a stomp, if your style can")
    slider(AutoBox, "StompRange", "Finish within", 3, 10, 1, " studs")
    local AutoLabel = AutoBox:AddLabel("...", true)

    local WeaveBox = Tab:AddRightGroupbox("Auto weave", "shield")
    toggle(WeaveBox, "AutoWeave", "Auto weave (parry)",
        "When an enemy near you starts a swing while facing you, you weave for a moment, which is how the game parries")
    slider(WeaveBox, "WeaveRange", "React within", 5, 16, 0, " studs")
    slider(WeaveBox, "WeaveHold", "Weave for", 0.15, 0.8, 2, " s")
    local WeaveLabel = WeaveBox:AddLabel("...", true)
    loop(0.3, function()
        ReachLabel:SetText(("Reach: %s (%d hit checks grown)\nServer limit for you: %.1f studs"):format(Reach.status, Reach.grew,
            10 * combatScale(character())))
        AutoLabel:SetText(("Combat functions: %s\nNow: %s"):format(Game.status, Fight.info))
        WeaveLabel:SetText(("%s\nWeaves: %d"):format(Weave.info, Weave.count))
    end)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Players and bounties")
    local Box = Tab:AddLeftGroupbox("Players", "eye")
    toggle(Box, "Esp", "Player ESP", "Red enemies, gold if they have a bounty, blue for party or clan")
    toggle(Box, "BountyOnly", "Only players with a bounty")
    slider(Box, "EspMax", "Max distance", 50, 1500, 0, " studs")
    local Opt = Tab:AddRightGroupbox("Show", "list")
    toggle(Opt, "EspHealth", "Health")
    toggle(Opt, "EspStyle", "Style")
    toggle(Opt, "EspBounty", "Bounty")
    toggle(Opt, "EspStates", "Down / weaving / parrying / blocking")
end

do
    local Tab = Window:AddTab("Money", "banknote", "Money rain")
    local Box = Tab:AddLeftGroupbox("Money rain", "banknote")
    toggle(Box, "MoneyEsp", "Bill ESP", "Highlights the bills on the ground")
    toggle(Box, "AutoMoney", "Walk to bills", "Walks you to the nearest bill. They're picked up within 20 studs. Walking, not teleporting")
    slider(Box, "MoneyRange", "Only within", 20, 400, 0, " studs")
    local MoneyLabel = Box:AddLabel("...", true)
    loop(0.4, function()
        MoneyLabel:SetText(Money.info)
    end)
end

do
    local Tab = Window:AddTab("Player", "user", "Speed and more")
    local Move = Tab:AddLeftGroupbox("Movement", "move")
    toggle(Move, "SpeedOn", "Speed boost", "Multiplies the game's own walk and run speed, never past 28 (the game reports anything over about 30)")
    slider(Move, "SpeedMult", "Speed", 1, 1.6, 2, "x")
    local SpeedLabel = Move:AddLabel("...", true)
    local Misc = Tab:AddRightGroupbox("Other", "settings")
    toggle(Misc, "AntiAfk", "Anti-AFK")
    loop(0.5, function()
        SpeedLabel:SetText("Speed: " .. Speed.info)
    end)
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
Genv.__SuUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify("Loaded. " .. Game.status, 4)

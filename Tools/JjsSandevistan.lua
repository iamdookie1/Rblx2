--// JJS Sandevistan builder ---------------------------------------------------
-- Builds a Sandevistan (David Martinez, Cyberpunk: Edgerunners) for a custom
-- character and puts it on your Character block. Run it in your own private
-- server with build mode on and a Character block placed.
--
-- Two skills:
--   Sandevistan (key 1)   the skill itself is over in under half a second, so
--                         your M1 and other moves work straight away. What it
--                         starts runs on its own timers for the duration:
--                           * slow-motion tint, wider field of view, distortion;
--                           * you move faster and hit harder;
--                           * everyone in range is frozen in place (0 damage);
--                           * a cyan / magenta trail behind you that everyone
--                             sees, plus true afterimages of your pose (see
--                             below).
--   Sandevistan Punch (key 2)  the finisher: a lunge into a heavy punch. It
--                         ends everything, the visuals go, the freeze lifts,
--                         and it costs you a little health.
--   Left alone it all ends by itself after the duration.
--
-- Why two skills: while a skill is running the game won't let you M1, so a
-- skill that lasted 10 seconds locked you out of punching. A skill can't see
-- your M1 either, so the punch that ends it is its own key.
--
-- Afterimages: the builder's Afterimage effect is one snapshot per node, and
-- only a running skill can keep making them. So for the whole duration this
-- script keeps running and draws real afterimages of your pose, every 0.08 s.
-- Those are only on your screen; everyone else sees the particle trail.
--
-- Built only from the builder's own nodes (ReplicatedStorage.Modules.SkillDefault),
-- in the same format its Export button gives. The code is also copied and
-- saved to jjs_movesets/, so you can paste it into the Character block's
-- Import box yourself if applying it doesn't work.

local CONFIG = {
    Key = 1,               -- Sandevistan's slot; the punch goes on Key + 1
    Cooldown = 25,
    PunchCooldown = 4,
    Duration = 10,         -- seconds
    FreezeRange = 40,      -- studs across
    SpeedBoost = 1.8,      -- walk speed multiplier while it runs
    DamageBoost = 1.6,     -- damage multiplier while it runs, M1s included
    PunchDamage = 18,      -- before the boost
    SelfDamage = 3,        -- what the punch costs you
    ColorA = "0, 255, 230",   -- cyan
    ColorB = "255, 40, 200",  -- magenta
    TrailTexture = 0,      -- a decal id for the trail particles, 0 = the default
    LocalAfterimages = true,
    Apply = true,          -- put it on your Character block straight away
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__SandevistanStop then
    pcall(Genv.__SandevistanStop)
end

local function note(text)
    print("[sandevistan] " .. text)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Sandevistan", Text = text, Duration = 8 })
end

local okModule, Base64 = pcall(require, ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Base64"))
if not okModule then
    note("couldn't load the game's Base64 module: " .. tostring(Base64))
    return
end

-- The game's own slow-motion sound (Toji's Flourish), read live.
local function soundId(path)
    local ok, id = pcall(function()
        local s = ReplicatedStorage.Sounds
        for _, name in path do
            s = s[name]
        end
        return s.SoundId
    end)
    return ok and tonumber(tostring(id):match("%d+")) or nil
end

--// The skills \\--
local TAG, FREEZE, TRAIL = "SANDE", "SANDE_FREEZE", "SANDE_TRAIL"

local function append(list, nodes)
    for _, n in nodes do
        table.insert(list, n)
    end
    return list
end

local function afterimage(color)
    return {
        K_NAME = "VISUAL", EFFECT = "Afterimage", COLOR = color, ["ALT COLOR"] = color,
        OPACITY = 0.35, ["ALT OPACITY"] = 1, TIME = 0.5,
    }
end

local function trail(part, color)
    return {
        K_NAME = "PARTICLE", ["BODY PART"] = part, TEXTURE = CONFIG.TrailTexture,
        DURATION = CONFIG.Duration, RATE = 22, LIFETIME = "0.35, 0.45", SPEED = "0, 0",
        SIZE = "4.5, 4", TRANSPARENCY = "0.45, 1", COLOR = color:gsub(" ", "") .. " " .. color:gsub(" ", ""),
        ["LIGHT EMISSION"] = 1, ["LIGHT INFLUENCE"] = 0, ["LOCK TO PART"] = false,
        ["CANCEL TAG"] = TRAIL,
    }
end

-- Everything that has to stop at the end.
local function cleanup()
    return {
        { K_NAME = "VISUAL", EFFECT = "Cancel", ["VISUAL TAG"] = TAG },
        { K_NAME = "PARTICLE", CANCEL = true, ["CANCEL TAG"] = TRAIL },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = TAG },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = FREEZE, ["LAST HIT"] = CONFIG.Duration + 1 },
        { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 1, TIME = 0.3 },
    }
end

-- Sandevistan: everything here starts and the skill is done in about 0.3 s.
local startLine = {}
local slowmo = soundId({ "Toji", "SSK", "Flourish", "SlowMo" })
if slowmo then
    table.insert(startLine, { K_NAME = "SFX", ID = slowmo, VOLUME = 1 })
end
append(startLine, {
    { K_NAME = "VISUAL", EFFECT = "Screen Color", COLOR = "170, 255, 240", AMOUNT = 0.05, OPACITY = -0.4,
        SIZE = 0.2, TIME = CONFIG.Duration, ["VISUAL TAG"] = TAG },
    { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 25, TIME = 0.4, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" },
    { K_NAME = "VISUAL", EFFECT = "Distortion", SIZE = 3, TIME = 0.6 },
    { K_NAME = "STATE", STATE = "SpeedMultiplier", VALUE = CONFIG.SpeedBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    { K_NAME = "STATE", STATE = "DamageMultiplier", VALUE = CONFIG.DamageBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    -- everyone around you frozen: a 0 damage hitbox marks them, then the
    -- stun goes on with its own tag so the punch can lift it
    { K_NAME = "HITBOX", POSITION = "0, 0, 0", SIZE = ("%d, 20, %d"):format(CONFIG.FreezeRange, CONFIG.FreezeRange),
        STUN = -1, DAMAGE = 0, BLOCKABLE = false, ["SINGLE TARGET"] = false, ["CLEAR KNOCKBACK"] = true, ["CAN KILL"] = false },
    { K_NAME = "STATE", STATE = "Stun", TIME = CONFIG.Duration, ["LAST HIT"] = 0.5, ["STATE TAG"] = FREEZE },
    -- the trail everyone sees, behind your torso and your legs
    trail("Torso", CONFIG.ColorA),
    trail("HumanoidRootPart", CONFIG.ColorB),
    afterimage(CONFIG.ColorA),
    { K_NAME = "WAIT", TIME = 0.1 },
    afterimage(CONFIG.ColorB),
    { K_NAME = "WAIT", TIME = 0.1 },
    afterimage(CONFIG.ColorA),
})

-- Sandevistan Punch: lunge, heavy punch, end it all.
local punchLine = {
    afterimage(CONFIG.ColorB),
    { K_NAME = "VELO", FORCE = "0, 0, 70", TIME = 0.15, FADE = true },
    { K_NAME = "WAIT", TIME = 0.1 },
    afterimage(CONFIG.ColorA),
    { K_NAME = "HITBOX", POSITION = "0, 0, 4", SIZE = "6, 6, 7", DAMAGE = CONFIG.PunchDamage, STUN = 1.2,
        ["STUN ANIM"] = true, ["SINGLE TARGET"] = true, DEBREE = 2, ["CLEAR KNOCKBACK"] = true },
    { K_NAME = "VISUAL", EFFECT = "Shake Medium" },
    { K_NAME = "HPGIB", AMOUNT = -CONFIG.SelfDamage },
}
append(punchLine, cleanup())

local function slot(name, key, cooldown, tip, line)
    return {
        K_NAME = "SKILL", NAME = name, KEY = key, COOLDOWN = cooldown, ADD = false, ["TOOL TIP"] = tip,
        DATA = HttpService:JSONEncode({ Line = line, Req = {}, Prop = {} }),
    }
end

local dict = HttpService:JSONEncode({
    slot("Sandevistan", CONFIG.Key, CONFIG.Cooldown, "Freezes everyone around you", startLine),
    slot("Sandevistan Punch", CONFIG.Key + 1, CONFIG.PunchCooldown, "Ends Sandevistan", punchLine),
})

--// Save, copy, apply \\--
local code = Base64.to_base64(dict)
if typeof(makefolder) == "function" and not (typeof(isfolder) == "function" and isfolder("jjs_movesets")) then
    pcall(makefolder, "jjs_movesets")
end
local saved = typeof(writefile) == "function" and pcall(writefile, "jjs_movesets/Sandevistan.txt", code)
if typeof(writefile) == "function" then
    pcall(writefile, "jjs_movesets/Sandevistan.json", dict)
end
local copied = false
for _, fn in { setclipboard, toclipboard } do
    if typeof(fn) == "function" and pcall(fn, code) then
        copied = true
        break
    end
end

local applied = false
if CONFIG.Apply then
    local logic = workspace:FindFirstChild("Logic")
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local build = remotes and remotes:FindFirstChild("BuildEvent")
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local best, bestD
    for _, block in logic and logic:GetChildren() or {} do
        if block.Name == "Character" and block:IsA("BasePart") then
            local d = root and (block.Position - root.Position).Magnitude or 0
            if not bestD or d < bestD then
                best, bestD = block, d
            end
        end
    end
    if best and build then
        applied = pcall(build.FireServer, build, "LogicProp", { best }, "Dict", Base64.to_zstd(dict))
    end
end

note(("Sandevistan built (%d characters).%s%s%s"):format(#code,
    applied and " Put on your nearest Character block." or " No Character block found to put it on.",
    copied and " Code copied." or "",
    saved and " Saved to jjs_movesets/Sandevistan.txt." or ""))
if not applied then
    note("Place a Character block in build mode and run this again, or paste the code into the block's Import box.")
end

--// Afterimages for the whole duration (on your screen) \\--
local running = true
local connections = {}
Genv.__SandevistanStop = function()
    running = false
    for _, c in connections do
        pcall(c.Disconnect, c)
    end
end
if not CONFIG.LocalAfterimages then
    return
end

local activeUntil = 0
local function color3(text)
    local r, g, b = text:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
    return Color3.fromRGB(tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255)
end
local COLORS = { color3(CONFIG.ColorA), color3(CONFIG.ColorB) }

local holder = Instance.new("Folder")
holder.Name = "SandevistanAfterimages"
holder.Parent = workspace.CurrentCamera
table.insert(connections, { Disconnect = function()
    holder:Destroy()
end })

local function snapshot(character, color)
    for _, part in character:GetDescendants() do
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
            local ok, copy = pcall(function()
                local c = part:Clone()
                c:ClearAllChildren()
                return c
            end)
            if ok and copy then
                local mesh = part:FindFirstChildOfClass("SpecialMesh")
                if mesh then
                    mesh:Clone().Parent = copy
                end
                copy.Anchored, copy.CanCollide, copy.CanQuery, copy.CanTouch = true, false, false, false
                copy.CastShadow = false
                copy.Material = Enum.Material.Neon
                copy.Color = color
                copy.Transparency = 0.45
                copy.CFrame = part.CFrame
                if copy:IsA("MeshPart") then
                    pcall(function()
                        copy.TextureID = ""
                    end)
                end
                copy.Parent = holder
                TweenService:Create(copy, TweenInfo.new(0.45, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
                task.delay(0.5, function()
                    copy:Destroy()
                end)
            end
        end
    end
end

-- Your moves carry LastUse, which the game sets the moment you use one.
local function watchMoves(character)
    local moveset = character:WaitForChild("Moveset", 10)
    if not moveset then
        return
    end
    local function hook(move)
        if not move:IsA("NumberValue") then
            return
        end
        table.insert(connections, move:GetAttributeChangedSignal("LastUse"):Connect(function()
            local tag = move:GetAttribute("Tag")
            if tag == "Sandevistan" then
                activeUntil = os.clock() + CONFIG.Duration
            elseif tag == "Sandevistan Punch" then
                activeUntil = os.clock() + 0.25
            end
        end))
    end
    for _, move in moveset:GetChildren() do
        hook(move)
    end
    table.insert(connections, moveset.ChildAdded:Connect(hook))
end
local characters = workspace:FindFirstChild("Characters")
local function current()
    return (characters and characters:FindFirstChild(LocalPlayer.Name)) or LocalPlayer.Character
end
if current() then
    task.spawn(watchMoves, current())
end
table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
    activeUntil = 0
    task.wait(1)
    watchMoves(current())
end))

task.spawn(function()
    local flip = 1
    while running do
        local character = current()
        if os.clock() < activeUntil and character then
            flip = 3 - flip
            snapshot(character, COLORS[flip])
        end
        task.wait(0.08)
    end
end)

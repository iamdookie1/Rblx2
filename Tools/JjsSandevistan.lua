--// JJS Sandevistan builder ---------------------------------------------------
-- Builds a David Martinez (Cyberpunk: Edgerunners) custom character and puts it
-- on your Character block. Run it in your own private server with build mode
-- on and a Character block placed.
--
--   1  Sandevistan        costs 10 HP. A burst of afterimages, slow-motion
--                         look, faster and stronger for the duration,
--                         everyone in range frozen, a trail behind you. The
--                         skill itself is over in under a second, so M1 and
--                         your other moves work while it lasts.
--   2  Sandevistan Punch  a long lunge into a heavy punch. Ends Sandevistan:
--                         visuals go, the freeze lifts. Costs 3 HP.
--   3  Overclock Rush     a burst of punches with afterimages, then a heavy
--                         last hit.
--   4  Cyberskeleton Slam up into the air and down into the ground, hitting
--                         everything around where you land.
--   Front dash            instant, leaves afterimages, costs 6 HP. Custom
--                         characters can only replace the front dash (that's
--                         the game's rule); side and back dashes stay normal.
--
-- Every afterimage here is the builder's own Afterimage effect, which the game
-- shows to everyone. The trail between them is a particle emitter, also seen
-- by everyone.
--
-- Animations are looked up live in the game's own list, so they stay right
-- when the game adds characters. If one can't be found that node is left out.
--
-- Built only from the builder's own nodes (ReplicatedStorage.Modules.SkillDefault),
-- in the same format its Export button gives. The code is also copied and
-- saved to jjs_movesets/, so you can paste it into the Character block's
-- Import box yourself if applying it doesn't work.

local CONFIG = {
    Duration = 10,         -- Sandevistan, seconds
    Cooldown = 25,
    SandeCost = 10,        -- HP every time Sandevistan is used
    FreezeRange = 40,      -- studs across
    SpeedBoost = 1.8,
    DamageBoost = 1.6,     -- M1s included
    PunchDamage = 18,      -- before the boost
    PunchCost = 3,
    PunchCooldown = 4,
    RushCooldown = 12,
    SlamCooldown = 15,
    DashCost = 6,
    DashCooldown = 3,
    ColorA = "0, 255, 230",   -- cyan
    ColorB = "255, 40, 200",  -- magenta
    TrailTexture = 0,      -- a decal id for the trail particles, 0 = the default
    Apply = true,          -- put it on your Character block straight away
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__SandevistanStop then
    -- the older version kept a loop running for local afterimages
    pcall(Genv.__SandevistanStop)
    Genv.__SandevistanStop = nil
end

local function note(text)
    print("[sandevistan] " .. text)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Sandevistan", Text = text, Duration = 8 })
end

local Modules = ReplicatedStorage:WaitForChild("Modules")
local okModule, Base64 = pcall(require, Modules:WaitForChild("Base64"))
if not okModule then
    note("couldn't load the game's Base64 module: " .. tostring(Base64))
    return
end

-- The game's slow-motion sound (Toji's Flourish), read live.
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

-- ANIM nodes name an animation by its place in ListData.AnimList: { group, index }.
local AnimList
do
    local ok, list = pcall(require, Modules:WaitForChild("ListData"))
    AnimList = ok and type(list) == "table" and list.AnimList or {}
end
local function animOf(...)
    local inst = ReplicatedStorage:FindFirstChild("Animations")
    for _, name in { ... } do
        inst = inst and inst:FindFirstChild(name)
    end
    if not inst then
        return nil
    end
    for g, group in AnimList do
        for i, a in group do
            if a == inst then
                return { g, i }
            end
        end
    end
    return nil
end
local ANIMS = {
    Punch = animOf("Itadori", "Variants", "DivergentFist1"),
    Rush = animOf("Gojo", "RapidPunches"),
    RushEnd = animOf("Itadori", "Melee", "Melee4"),
    Slam = animOf("Itadori", "CrushingBlow"),
    Activate = animOf("Gojo", "Teleport"),
}

--// Nodes \\--
local TAG, FREEZE, TRAIL = "SANDE", "SANDE_FREEZE", "SANDE_TRAIL"

-- In order, skipping the nodes left out (nil holes), so not ipairs or pairs.
local function append(list, nodes)
    local last = 0
    for k in nodes do
        if type(k) == "number" and k > last then
            last = k
        end
    end
    for i = 1, last do
        if nodes[i] then
            table.insert(list, nodes[i])
        end
    end
    return list
end
local function anim(which, speed)
    local use = ANIMS[which]
    return use and { K_NAME = "ANIM", ANIM_USE = use, SPEED = speed or 1 } or nil
end
local function afterimage(color, opacity)
    return {
        K_NAME = "VISUAL", EFFECT = "Afterimage", COLOR = color, ["ALT COLOR"] = color,
        OPACITY = opacity or 0.35, ["ALT OPACITY"] = 1, TIME = 0.5,
    }
end
local function wait(t)
    return { K_NAME = "WAIT", TIME = t }
end
local function hurtSelf(amount)
    return { K_NAME = "HPGIB", AMOUNT = -amount }
end
-- A run of afterimages, alternating colours, `gap` seconds apart.
local function burst(count, gap)
    local out = {}
    for i = 1, count do
        table.insert(out, afterimage(i % 2 == 1 and CONFIG.ColorA or CONFIG.ColorB))
        if i < count then
            table.insert(out, wait(gap))
        end
    end
    return out
end
local function trail(part, color)
    local c = color:gsub(" ", "")
    return {
        K_NAME = "PARTICLE", ["BODY PART"] = part, TEXTURE = CONFIG.TrailTexture,
        DURATION = CONFIG.Duration, RATE = 22, LIFETIME = "0.35, 0.45", SPEED = "0, 0",
        SIZE = "4.5, 4", TRANSPARENCY = "0.45, 1", COLOR = c .. " " .. c,
        ["LIGHT EMISSION"] = 1, ["LIGHT INFLUENCE"] = 0, ["LOCK TO PART"] = false,
        ["CANCEL TAG"] = TRAIL,
    }
end
local function cleanup()
    return {
        { K_NAME = "VISUAL", EFFECT = "Cancel", ["VISUAL TAG"] = TAG },
        { K_NAME = "PARTICLE", CANCEL = true, ["CANCEL TAG"] = TRAIL },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = TAG },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = FREEZE, ["LAST HIT"] = CONFIG.Duration + 1 },
        { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 1, TIME = 0.3 },
    }
end
local function hitbox(props)
    local h = { K_NAME = "HITBOX" }
    for k, v in props do
        h[k] = v
    end
    return h
end

--// 1 Sandevistan \\--
local sande = {}
local slowmo = soundId({ "Toji", "SSK", "Flourish", "SlowMo" })
append(sande, {
    slowmo and { K_NAME = "SFX", ID = slowmo, VOLUME = 1 } or nil,
    anim("Activate", 1.5),
    hurtSelf(CONFIG.SandeCost),
    { K_NAME = "VISUAL", EFFECT = "Screen Color", COLOR = "170, 255, 240", AMOUNT = 0.05, OPACITY = -0.4,
        SIZE = 0.2, TIME = CONFIG.Duration, ["VISUAL TAG"] = TAG },
    { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 25, TIME = 0.4, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" },
    { K_NAME = "VISUAL", EFFECT = "Distortion", SIZE = 3, TIME = 0.6 },
    { K_NAME = "STATE", STATE = "SpeedMultiplier", VALUE = CONFIG.SpeedBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    { K_NAME = "STATE", STATE = "DamageMultiplier", VALUE = CONFIG.DamageBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    -- everyone around you frozen: a 0 damage hitbox marks them, then the
    -- stun goes on with its own tag so the punch can lift it
    hitbox({ POSITION = "0, 0, 0", SIZE = ("%d, 20, %d"):format(CONFIG.FreezeRange, CONFIG.FreezeRange),
        STUN = -1, DAMAGE = 0, BLOCKABLE = false, ["SINGLE TARGET"] = false, ["CLEAR KNOCKBACK"] = true, ["CAN KILL"] = false }),
    { K_NAME = "STATE", STATE = "Stun", TIME = CONFIG.Duration, ["LAST HIT"] = 0.5, ["STATE TAG"] = FREEZE },
    trail("Torso", CONFIG.ColorA),
    trail("HumanoidRootPart", CONFIG.ColorB),
})
-- the burst everyone sees, about 0.7 s before you're free to move again
append(sande, burst(8, 0.09))

--// 2 Sandevistan Punch \\--
local punch = {}
append(punch, {
    anim("Punch", 1.2),
    { K_NAME = "LOOK", TIME = 0.35, ["HORIZONTAL ONLY"] = true },
    afterimage(CONFIG.ColorB),
    { K_NAME = "VELO", FORCE = "0, 0, 170", TIME = 0.28, FADE = true, TRACK = true },
    wait(0.07), afterimage(CONFIG.ColorA),
    wait(0.07), afterimage(CONFIG.ColorB),
    wait(0.07), afterimage(CONFIG.ColorA),
    hitbox({ POSITION = "0, 0, 4", SIZE = "7, 7, 8", DAMAGE = CONFIG.PunchDamage, STUN = 1.2,
        ["STUN ANIM"] = true, ["SINGLE TARGET"] = true, DEBREE = 2, ["CLEAR KNOCKBACK"] = true }),
    { K_NAME = "VISUAL", EFFECT = "Shake Medium" },
    { K_NAME = "VISUAL", EFFECT = "Black Flash" },
    hurtSelf(CONFIG.PunchCost),
})
append(punch, cleanup())

--// 3 Overclock Rush \\--
local rush = {}
append(rush, {
    anim("Rush", 1.3),
    { K_NAME = "LOOK", TIME = 1.2, ["HORIZONTAL ONLY"] = true },
    { K_NAME = "VELO", FORCE = "0, 0, 60", TIME = 0.15, FADE = true },
})
for i = 1, 8 do
    append(rush, {
        afterimage(i % 2 == 1 and CONFIG.ColorA or CONFIG.ColorB, 0.5),
        hitbox({ POSITION = "0, 0, 4", SIZE = "7, 7, 7", DAMAGE = 2, STUN = 0.5, ["SINGLE TARGET"] = false }),
        wait(0.11),
    })
end
append(rush, {
    anim("RushEnd", 1.2),
    wait(0.15),
    afterimage(CONFIG.ColorA),
    hitbox({ POSITION = "0, 0, 4", SIZE = "8, 7, 8", DAMAGE = 6, STUN = 1, ["STUN ANIM"] = true,
        ["SINGLE TARGET"] = false, DEBREE = 2 }),
    { K_NAME = "VISUAL", EFFECT = "Shake Light" },
})

--// 4 Cyberskeleton Slam \\--
local slam = {}
append(slam, {
    anim("Slam", 1),
    afterimage(CONFIG.ColorA),
    { K_NAME = "VELO", FORCE = "0, 90, 35", TIME = 0.3, FADE = true },
    wait(0.15), afterimage(CONFIG.ColorB),
    wait(0.25), afterimage(CONFIG.ColorA),
    { K_NAME = "VELO", FORCE = "0, -160, 10", TIME = 0.2 },
    wait(0.2), afterimage(CONFIG.ColorB),
    hitbox({ POSITION = "0, -2, 0", SIZE = "22, 8, 22", DAMAGE = 12, STUN = 1.2, ["STUN ANIM"] = true,
        ["SINGLE TARGET"] = false, DEBREE = 3, BLOCKABLE = true }),
    { K_NAME = "VISUAL", EFFECT = "Shake Heavy" },
    { K_NAME = "VISUAL", EFFECT = "Wind Expand" },
})

--// Front dash \\--
-- Instant: a very short, very strong push, with afterimages along the way.
local dash = {}
append(dash, {
    hurtSelf(CONFIG.DashCost),
    afterimage(CONFIG.ColorA),
    { K_NAME = "VELO", FORCE = "0, 0, 320", TIME = 0.1 },
    wait(0.03), afterimage(CONFIG.ColorB),
    wait(0.03), afterimage(CONFIG.ColorA),
    wait(0.03), afterimage(CONFIG.ColorB),
})

--// The character \\--
local function data(line)
    return HttpService:JSONEncode({ Line = line, Req = {}, Prop = {} })
end
local function slot(name, key, cooldown, tip, line)
    return { K_NAME = "SKILL", NAME = name, KEY = key, COOLDOWN = cooldown, ADD = false, ["TOOL TIP"] = tip, DATA = data(line) }
end
local dict = HttpService:JSONEncode({
    slot("Sandevistan", 1, CONFIG.Cooldown, ("Costs %d HP"):format(CONFIG.SandeCost), sande),
    slot("Sandevistan Punch", 2, CONFIG.PunchCooldown, "Ends Sandevistan", punch),
    slot("Overclock Rush", 3, CONFIG.RushCooldown, "", rush),
    slot("Cyberskeleton Slam", 4, CONFIG.SlamCooldown, "", slam),
    { K_NAME = "CHASE", NAME = "Sandevistan Dash", COOLDOWN = CONFIG.DashCooldown, DATA = data(dash) },
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

local missing = {}
for name, use in { Punch = ANIMS.Punch, Rush = ANIMS.Rush, Slam = ANIMS.Slam } do
    if not use then
        table.insert(missing, name)
    end
end
note(("David built (%d characters).%s%s%s%s"):format(#code,
    applied and " Put on your nearest Character block." or " No Character block found to put it on.",
    copied and " Code copied." or "",
    saved and " Saved to jjs_movesets/Sandevistan.txt." or "",
    #missing > 0 and (" No animation found for: " .. table.concat(missing, ", ")) or ""))
if not applied then
    note("Place a Character block in build mode and run this again, or paste the code into the block's Import box.")
end

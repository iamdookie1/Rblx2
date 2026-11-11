--// JJS David builder -----------------------------------------------------------
-- Builds David Martinez (Cyberpunk: Edgerunners) as a custom character and puts
-- him on a Character block. Run it in a private server you own or have build
-- permission in. If there's no Character block yet, it makes one: invisible,
-- not solid, right where you stand, named David.
--
-- Base (normal David)
--   1  Sandevistan        costs 10 HP. Slow-motion look, faster and stronger
--                         for the duration, everyone in range frozen, a trail
--                         behind you and afterimages (see AFTERIMAGES below).
--   2  Sandevistan Punch  needs a target. Blinks straight to them, whatever
--                         the distance, and lands a heavy punch. Ends
--                         Sandevistan. Costs 3 HP.
--   3  Kiroshi Blitz      needs a target. Four strikes from four sides, each
--                         on its own animation, then a launching kick.
--   4  Overclock Uppercut needs a target. Blinks in and launches them.
-- Awakening: Cyberskeleton (near death, the skeleton takes over)
--   1  Sandevistan        the same, but longer reach, faster, harder. Still
--                         costs 10 HP.
--   2  Cyberskeleton Slam drops onto whoever you face from above (or straight
--                         up and down), a crater that throws everyone up.
--   3  Gorilla Barrage    heavy hooks into a ground pound.
--   4  Overdrive Charge   charges forward, stops on the first person it hits
--                         with a heavy blow that throws them.
-- Front dash (both)       instant, normal dash distance, afterimages, 6 HP. Custom characters
--                         can only replace the front dash (the game's rule).
--
-- AFTERIMAGES: a skill only makes afterimages while it is running, and while a
-- skill is running the game won't take your M1. So with FullAfterimages off
-- (the default) Sandevistan leaves a long burst of afterimages, then a trail
-- for the rest, and every move and dash leaves its own, while M1 stays free.
-- With FullAfterimages on, Sandevistan keeps making afterimages for the whole
-- duration, but you can't M1 or use moves until it ends.
--
-- Animations are looked up live in the game's own list, so updates don't move
-- them. Built only from the builder's own nodes (Modules.SkillDefault), in the
-- format its Export button gives. Also saved to jjs_movesets/David.txt.

local CONFIG = {
    Name = "David",
    FullAfterimages = false,
    Duration = 10,
    Cooldown = 25,
    SandeCost = 10,        -- HP, every time Sandevistan is used
    FreezeRange = 40,
    SpeedBoost = 1.8,
    DamageBoost = 1.6,
    AwakeRange = 60,       -- the awakened Sandevistan
    AwakeSpeed = 2.2,
    AwakeDamage = 1.9,
    PunchDamage = 18,
    PunchCost = 3,
    DashCost = 6,
    DashForce = 160,       -- lower = shorter dash
    DashCooldown = 3,
    AwakeningTime = 60,
    ColorA = "0, 255, 230",   -- cyan
    ColorB = "255, 40, 200",  -- magenta
    SkeletonColor = "255, 60, 60",
    TrailTexture = 0,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__SandevistanStop then
    pcall(Genv.__SandevistanStop)
    Genv.__SandevistanStop = nil
end

local function note(text)
    print("[david] " .. text)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "David", Text = text, Duration = 8 })
end

local Modules = ReplicatedStorage:WaitForChild("Modules")
local okModule, Base64 = pcall(require, Modules:WaitForChild("Base64"))
if not okModule then
    note("couldn't load the game's Base64 module: " .. tostring(Base64))
    return
end

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
local function animOf(path)
    local inst = ReplicatedStorage:FindFirstChild("Animations")
    for name in path:gmatch("[^%.]+") do
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
    Activate = animOf("Gojo.Teleport"),
    Punch = animOf("Itadori.Variants.DivergentFist1"),
    Jab1 = animOf("Gojo.Melee.Melee1"),
    Jab2 = animOf("Gojo.Melee.Melee2"),
    Jab3 = animOf("Gojo.Melee.Melee3"),
    Jab4 = animOf("Gojo.Melee.Melee4"),
    Up = animOf("Gojo.Melee.Up"),
    Kick = animOf("Gojo.TwofoldKick"),
    Slam = animOf("Itadori.CrushingBlow"),
    Hook1 = animOf("Itadori.Melee.Melee1"),
    Hook2 = animOf("Itadori.Melee.Melee2"),
    Hook3 = animOf("Itadori.Melee.Melee3"),
    Charge = animOf("Itadori.Rush"),
}

--// Node helpers \\--
local TAG, FREEZE, TRAIL = "SANDE", "SANDE_FREEZE", "SANDE_TRAIL"

-- Appends in order, skipping nodes left out (nil holes).
local function add(list, nodes)
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
local function node(kind, props)
    local n = { K_NAME = kind }
    for k, v in props or {} do
        n[k] = v
    end
    return n
end
local function anim(which, speed)
    local use = ANIMS[which]
    return use and node("ANIM", { ANIM_USE = use, SPEED = speed or 1 }) or nil
end
local function wait(t)
    return node("WAIT", { TIME = t })
end
local function hurtSelf(amount)
    return node("HPGIB", { AMOUNT = -amount })
end
local function afterimage(color, opacity, tag)
    return node("VISUAL", {
        EFFECT = "Afterimage", COLOR = color, ["ALT COLOR"] = color,
        OPACITY = opacity or 0.35, ["ALT OPACITY"] = 1, TIME = 0.5, ["VISUAL TAG"] = tag,
    })
end
local function colorFor(i, a, b)
    return i % 2 == 1 and (a or CONFIG.ColorA) or (b or CONFIG.ColorB)
end
local function burst(count, gap, a, b)
    local out = {}
    for i = 1, count do
        table.insert(out, afterimage(colorFor(i, a, b)))
        if i < count then
            table.insert(out, wait(gap))
        end
    end
    return out
end
local function hitbox(props)
    return node("HITBOX", props)
end
local function look(time)
    return node("LOOK", { TIME = time, ["HORIZONTAL ONLY"] = true, ["LAST HIT"] = 1, SMOOTHNESS = 200 })
end
-- Puts you right next to whoever you last hit, facing them.
local function blinkTo(distance)
    return {
        node("TELEPORT", { POSITION = ("0, 0, %s"):format(distance), ROTATION = "0, 180, 0", ["LAST HIT"] = 1 }),
        look(0.15),
    }
end
-- Marks whoever is in front of you (0 damage) and goes to `branch` if found.
local function reach(length, branch)
    return hitbox({ POSITION = ("0, 0, %d"):format(length / 2), SIZE = ("8, 10, %d"):format(length),
        DAMAGE = 0, STUN = -1, BLOCKABLE = false, ["SINGLE TARGET"] = true, BRANCH = branch })
end
local function trail(part, color)
    local c = color:gsub(" ", "")
    return node("PARTICLE", {
        ["BODY PART"] = part, TEXTURE = CONFIG.TrailTexture,
        DURATION = CONFIG.Duration, RATE = 22, LIFETIME = "0.35, 0.45", SPEED = "0, 0",
        SIZE = "4.5, 4", TRANSPARENCY = "0.45, 1", COLOR = c .. " " .. c,
        ["LIGHT EMISSION"] = 1, ["LIGHT INFLUENCE"] = 0, ["LOCK TO PART"] = false,
        ["CANCEL TAG"] = TRAIL,
    })
end
local function cleanup()
    return {
        node("VISUAL", { EFFECT = "Cancel", ["VISUAL TAG"] = TAG }),
        node("PARTICLE", { CANCEL = true, ["CANCEL TAG"] = TRAIL }),
        node("STATE", { STATE = "Cancel", ["STATE TAG"] = TAG }),
        node("STATE", { STATE = "Cancel", ["STATE TAG"] = FREEZE, ["LAST HIT"] = CONFIG.Duration + 1 }),
        node("VISUAL", { EFFECT = "Field of View", AMOUNT = 1, TIME = 0.3 }),
    }
end
local function skill(line, extra)
    local d = { Line = line, Req = {}, Prop = {} }
    for k, v in extra or {} do
        d[k] = v
    end
    return d
end

--// Sandevistan (base and awakened) \\--
local slowmo = soundId({ "Toji", "SSK", "Flourish", "SlowMo" })
local function sandevistan(range, speed, damage, tint)
    local line = {}
    add(line, {
        slowmo and node("SFX", { ID = slowmo, VOLUME = 1 }) or nil,
        anim("Activate", 1.5),
        hurtSelf(CONFIG.SandeCost),
        node("VISUAL", { EFFECT = "Screen Color", COLOR = tint, AMOUNT = 0.05, OPACITY = -0.4,
            SIZE = 0.2, TIME = CONFIG.Duration, ["VISUAL TAG"] = TAG }),
        node("VISUAL", { EFFECT = "Field of View", AMOUNT = 25, TIME = 0.4, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" }),
        node("VISUAL", { EFFECT = "Distortion", SIZE = 3, TIME = 0.6 }),
        node("STATE", { STATE = "SpeedMultiplier", VALUE = speed, TIME = CONFIG.Duration, ["STATE TAG"] = TAG }),
        node("STATE", { STATE = "DamageMultiplier", VALUE = damage, TIME = CONFIG.Duration, ["STATE TAG"] = TAG }),
        -- everyone in range frozen: a 0 damage hitbox marks them, then a
        -- tagged stun so the punch can lift it
        hitbox({ POSITION = "0, 0, 0", SIZE = ("%d, 20, %d"):format(range, range),
            STUN = -1, DAMAGE = 0, BLOCKABLE = false, ["SINGLE TARGET"] = false, ["CLEAR KNOCKBACK"] = true, ["CAN KILL"] = false }),
        node("STATE", { STATE = "Stun", TIME = CONFIG.Duration, ["LAST HIT"] = 0.5, ["STATE TAG"] = FREEZE }),
        trail("Torso", CONFIG.ColorA),
        trail("HumanoidRootPart", CONFIG.ColorB),
    })
    if CONFIG.FullAfterimages then
        -- one afterimage every 0.1 s for the whole duration
        add(line, burst(math.floor(CONFIG.Duration / 0.1), 0.1))
        add(line, cleanup())
    else
        -- a long burst (about 1.2 s), then the trail carries on
        add(line, burst(13, 0.09))
    end
    return skill(line)
end

--// 2 Sandevistan Punch \\--
local punch = {}
add(punch, {
    afterimage(CONFIG.ColorB),
    reach(120, "Go"),
    wait(0.05),
    -- nobody in front: a short lunge into the punch anyway
    node("VELO", { FORCE = "0, 0, 120", TIME = 0.2, FADE = true }),
    anim("Punch", 1.2),
    wait(0.18),
    hitbox({ POSITION = "0, 0, 4", SIZE = "7, 7, 8", DAMAGE = CONFIG.PunchDamage, STUN = 1.2,
        ["STUN ANIM"] = true, DEBREE = 2 }),
    hurtSelf(CONFIG.PunchCost),
})
add(punch, cleanup())
local punchGo = {}
add(punchGo, burst(3, 0.03))
add(punchGo, blinkTo(4))
add(punchGo, {
    afterimage(CONFIG.ColorA),
    anim("Punch", 1.2),
    wait(0.18),
    hitbox({ POSITION = "0, 0, 4", SIZE = "7, 7, 8", DAMAGE = CONFIG.PunchDamage, STUN = 1.2,
        ["STUN ANIM"] = true, ["SINGLE TARGET"] = true, DEBREE = 2, ["CLEAR KNOCKBACK"] = true }),
    node("VISUAL", { EFFECT = "Shake Medium" }),
    node("VISUAL", { EFFECT = "Black Flash" }),
    hurtSelf(CONFIG.PunchCost),
    wait(0.35),
})
add(punchGo, cleanup())
local punchSkill = skill(punch, {
    Req = { node("AIM", {}) },      -- HAS TARGET
    Branch = { Go = punchGo },
})

--// 3 Kiroshi Blitz \\--
-- Needs a target. Each strike: blink to a side of them, its animation at full
-- speed, the hit on its contact frame, and time for the swing to finish (a
-- skill's animation stops the moment the skill ends, which is what cut them
-- off before).
local TARGET = { node("AIM", {}) } -- HAS TARGET
local function faceAim()
    return node("LOOK", { TIME = 0.08, ["CAMERA DIRECTION"] = true, ["HORIZONTAL ONLY"] = true, SMOOTHNESS = 200 })
end
local function strike(animName, offset, rotation, damage, stun)
    return {
        afterimage(CONFIG.ColorB, 0.5),
        node("TELEPORT", { POSITION = offset, ROTATION = rotation, ["LAST HIT"] = 2 }),
        look(0.12),
        anim(animName, 1),
        wait(0.15),
        hitbox({ POSITION = "0, 0, 3.5", SIZE = "6, 6, 6", DAMAGE = damage, STUN = stun, ["SINGLE TARGET"] = true }),
        afterimage(CONFIG.ColorA, 0.5),
        wait(0.25),
    }
end
local blitz = {}
add(blitz, {
    faceAim(),
    afterimage(CONFIG.ColorA),
    reach(60, "Combo"),
    wait(0.05),
    -- nobody in reach: a jab where you stand
    anim("Jab1", 1),
    node("VELO", { FORCE = "0, 0, 60", TIME = 0.15, FADE = true }),
    wait(0.15),
    hitbox({ POSITION = "0, 0, 3.5", SIZE = "6, 6, 6", DAMAGE = 3, STUN = 0.8 }),
    wait(0.3),
})
local blitzCombo = {}
add(blitzCombo, strike("Jab1", "0, 0, 3.5", "0, 180, 0", 3, 1))
add(blitzCombo, strike("Jab2", "3.5, 0, 0", "0, 90, 0", 3, 1))
add(blitzCombo, strike("Jab3", "0, 0, -3.5", "0, 0, 0", 3, 1))
add(blitzCombo, strike("Jab4", "-3.5, 0, 0", "0, -90, 0", 3, 1))
add(blitzCombo, {
    afterimage(CONFIG.ColorB),
    node("TELEPORT", { POSITION = "0, 0, 4", ROTATION = "0, 180, 0", ["LAST HIT"] = 2 }),
    look(0.12),
    anim("Kick", 1),
    wait(0.2),
    hitbox({ POSITION = "0, 0, 4", SIZE = "7, 7, 7", DAMAGE = 7, STUN = 1, ["STUN ANIM"] = true,
        ["SINGLE TARGET"] = true, ["BRANCH TARGET"] = "Launched" }),
    node("VISUAL", { EFFECT = "Shake Light" }),
    afterimage(CONFIG.ColorA),
    wait(0.45),
})
local launched = { node("VELO", { FORCE = "0, 30, -70", TIME = 0.3, FADE = true, RAGDOLL = 1.2 }) }
local blitzSkill = skill(blitz, { Req = TARGET, Branch = { Combo = blitzCombo, Launched = launched } })

--// 4 Overclock Uppercut \\--
-- Needs a target: blinks in front of them and launches them.
local function uppercut()
    return {
        anim("Up", 1),
        wait(0.18),
        hitbox({ POSITION = "0, 1, 4", SIZE = "7, 8, 7", DAMAGE = 9, STUN = 1.1, ["STUN ANIM"] = true,
            ["SINGLE TARGET"] = true, ["BRANCH TARGET"] = "Up" }),
        afterimage(CONFIG.ColorB),
        node("VISUAL", { EFFECT = "Shake Light" }),
        wait(0.45),
    }
end
local upper = {}
add(upper, {
    faceAim(),
    afterimage(CONFIG.ColorB),
    reach(40, "Go"),
    wait(0.05),
    node("VELO", { FORCE = "0, 0, 90", TIME = 0.15, FADE = true }),
})
add(upper, uppercut())
local upperGo = {}
add(upperGo, burst(2, 0.03))
add(upperGo, blinkTo(3.5))
add(upperGo, uppercut())
local upSkill = skill(upper, { Req = TARGET, Branch = {
    Go = upperGo,
    Up = { node("VELO", { FORCE = "0, 85, 0", TIME = 0.3, FADE = true, RAGDOLL = 1.4 }) },
} })

--// Awakening moves \\--
local SK = CONFIG.SkeletonColor

-- 2 Cyberskeleton Slam: onto whoever you're facing from above, or straight
-- up and down where you are. A crater that throws everyone up.
local function impact()
    return {
        hitbox({ POSITION = "0, -2, 0", SIZE = "30, 10, 30", DAMAGE = 18, STUN = 1.5, ["STUN ANIM"] = true,
            ["SINGLE TARGET"] = false, DEBREE = 4, BLOCKABLE = false, ["BRANCH TARGET"] = "Crater" }),
        node("VISUAL", { EFFECT = "Shake Heavy" }),
        node("VISUAL", { EFFECT = "Wind Expand", SIZE = 2 }),
        node("VISUAL", { EFFECT = "Ring", COLOR = SK, SIZE = 3, TIME = 0.6 }),
        node("VISUAL", { EFFECT = "Mass Hit" }),
        node("VISUAL", { EFFECT = "Screen Color", COLOR = "255, 120, 120", AMOUNT = 0.15, TIME = 0.4 }),
        afterimage(SK),
        wait(0.5),
    }
end
local slam = {}
add(slam, {
    faceAim(),
    reach(80, "Leap"),
    wait(0.05),
    anim("Slam", 1),
    afterimage(SK),
    node("VELO", { FORCE = "0, 100, 20", TIME = 0.3, FADE = true }),
    wait(0.15), afterimage(CONFIG.ColorA),
    wait(0.25), afterimage(SK),
    node("VELO", { FORCE = "0, -220, 0", TIME = 0.15 }),
    wait(0.15),
})
add(slam, impact())
local slamLeap = {}
add(slamLeap, {
    afterimage(SK),
    node("TELEPORT", { POSITION = "0, 18, 0", ["LAST HIT"] = 1 }),
    anim("Slam", 1),
    afterimage(CONFIG.ColorA),
    wait(0.2),
    afterimage(SK),
    node("VELO", { FORCE = "0, -240, 0", TIME = 0.12 }),
    wait(0.12),
})
add(slamLeap, impact())
local slamSkill = skill(slam, { Branch = {
    Leap = slamLeap,
    Crater = { node("VELO", { FORCE = "0, 70, 0", TIME = 0.3, FADE = true, RAGDOLL = 1.5 }) },
} })

-- 3 Gorilla Barrage
local barrage = {}
local function hook(animName, damage, stun)
    return {
        anim(animName, 1),
        node("VELO", { FORCE = "0, 0, 25", TIME = 0.1, FADE = true }),
        wait(0.16),
        hitbox({ POSITION = "0, 0, 4", SIZE = "8, 7, 8", DAMAGE = damage, STUN = stun, ["SINGLE TARGET"] = false, DEBREE = 1 }),
        afterimage(SK, 0.5),
        node("VISUAL", { EFFECT = "Shake Light" }),
        wait(0.2),
    }
end
add(barrage, hook("Hook1", 5, 1))
add(barrage, hook("Hook2", 5, 1))
add(barrage, hook("Hook3", 6, 1.1))
add(barrage, {
    anim("Slam", 1.2),
    wait(0.25),
    hitbox({ POSITION = "0, -1, 4", SIZE = "12, 8, 12", DAMAGE = 10, STUN = 1.3, ["STUN ANIM"] = true,
        ["SINGLE TARGET"] = false, DEBREE = 3 }),
    node("VISUAL", { EFFECT = "Shake Heavy" }),
    wait(0.45),
})

-- 4 Overdrive Charge: charges forward and stops on the first person it hits,
-- with one heavy blow that throws them.
local charge = {}
add(charge, {
    faceAim(),
    anim("Charge", 1),
    afterimage(SK),
})
for i = 1, 6 do
    add(charge, {
        node("VELO", { FORCE = "0, 0, 130", TIME = 0.08 }),
        hitbox({ POSITION = "0, 0, 3", SIZE = "8, 8, 8", DAMAGE = 0, STUN = -1, BLOCKABLE = false,
            ["SINGLE TARGET"] = true, BRANCH = "Impact" }),
        afterimage(colorFor(i, SK, CONFIG.ColorA), 0.4),
        wait(0.07),
    })
end
add(charge, { wait(0.3) })
local chargeImpact = {
    node("VELO", { FORCE = "0, 0, 0", TIME = 0.05 }),
    look(0.1),
    anim("Hook3", 1),
    wait(0.15),
    hitbox({ POSITION = "0, 0, 4", SIZE = "8, 8, 8", DAMAGE = 16, STUN = 1.3, ["STUN ANIM"] = true,
        ["SINGLE TARGET"] = true, DEBREE = 3, ["BRANCH TARGET"] = "Thrown" }),
    node("VISUAL", { EFFECT = "Shake Heavy" }),
    node("VISUAL", { EFFECT = "Mass Hit" }),
    afterimage(SK),
    wait(0.45),
}
local chargeSkill = skill(charge, { Branch = {
    Impact = chargeImpact,
    Thrown = { node("VELO", { FORCE = "0, 40, -90", TIME = 0.35, FADE = true, RAGDOLL = 1.5 }) },
} })

--// Front dash \\--
-- About the distance of a normal front dash, just instant.
local dash = {}
add(dash, {
    hurtSelf(CONFIG.DashCost),
    afterimage(CONFIG.ColorA),
    node("VELO", { FORCE = ("0, 0, %d"):format(CONFIG.DashForce), TIME = 0.1 }),
    wait(0.03), afterimage(CONFIG.ColorB),
    wait(0.03), afterimage(CONFIG.ColorA),
    wait(0.03), afterimage(CONFIG.ColorB),
})

--// Awakening itself \\--
local awaken = {}
add(awaken, {
    anim("Activate", 1),
    node("STATE", { STATE = "IFrame", TIME = 1.5 }),
    node("VISUAL", { EFFECT = "Screen Color", COLOR = "255, 150, 150", AMOUNT = 0.1, OPACITY = -0.2, SIZE = 0.3, TIME = 1.5 }),
    node("VISUAL", { EFFECT = "Shake Heavy" }),
})
add(awaken, burst(6, 0.1, SK, CONFIG.ColorA))

--// The character \\--
local function encode(d)
    return HttpService:JSONEncode(d)
end
-- Base moves hide in the awakening, awakened ones hide in base.
local function slot(name, key, cooldown, tip, data, awakened)
    data.Prop = data.Prop or {}
    if awakened then
        data.Prop.AWK2 = true
    else
        data.Prop.AWK = true
    end
    return { K_NAME = "SKILL", NAME = name, KEY = key, COOLDOWN = cooldown, ADD = false, ["TOOL TIP"] = tip, DATA = encode(data) }
end
local cost = ("Costs %d HP"):format(CONFIG.SandeCost)
local dict = encode({
    slot("Sandevistan", 1, CONFIG.Cooldown, cost, sandevistan(CONFIG.FreezeRange, CONFIG.SpeedBoost, CONFIG.DamageBoost, "170, 255, 240")),
    slot("Sandevistan Punch", 2, 4, "Needs a target. Ends Sandevistan", punchSkill),
    slot("Kiroshi Blitz", 3, 12, "Needs a target", blitzSkill),
    slot("Overclock Uppercut", 4, 9, "Needs a target", upSkill),
    slot("Sandevistan", 1, CONFIG.Cooldown, cost, sandevistan(CONFIG.AwakeRange, CONFIG.AwakeSpeed, CONFIG.AwakeDamage, "255, 190, 200"), true),
    slot("Cyberskeleton Slam", 2, 14, "", slamSkill, true),
    slot("Gorilla Barrage", 3, 12, "", skill(barrage), true),
    slot("Overdrive Charge", 4, 16, "Stops on the first hit", chargeSkill, true),
    { K_NAME = "AWAKENING", NAME = "Cyberskeleton", DURATION = CONFIG.AwakeningTime, DELAY = 1,
        COLOR = "255,60,60 0,255,230", DATA = encode(skill(awaken)) },
    { K_NAME = "CHASE", NAME = "Sandevistan Dash", COOLDOWN = CONFIG.DashCooldown, DATA = encode(skill(dash)) },
})
local code = Base64.to_base64(dict)

--// Save \\--
if typeof(makefolder) == "function" and not (typeof(isfolder) == "function" and isfolder("jjs_movesets")) then
    pcall(makefolder, "jjs_movesets")
end
local saved = typeof(writefile) == "function" and pcall(writefile, "jjs_movesets/David.txt", code)
if typeof(writefile) == "function" then
    pcall(writefile, "jjs_movesets/David.json", dict)
end

--// Find or make the Character block, then put David on it \\--
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
local build = remotes and remotes:FindFirstChild("BuildEvent")
local logic = workspace:FindFirstChild("Logic")
local canBuild = LocalPlayer:GetAttribute("PS_Owner") or LocalPlayer:GetAttribute("PS_Perms")
    or LocalPlayer:FindFirstChildOfClass("PlayerGui"):FindFirstChild("BuildTools") ~= nil
if not build or not logic then
    note("This server has no builder. Saved the code to jjs_movesets/David.txt.")
    return
end
if not canBuild then
    note("You need to own this server or have build permission. Saved the code to jjs_movesets/David.txt.")
    return
end

local function root()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function fire(...)
    return pcall(build.FireServer, build, ...)
end

-- One already named David first, then the nearest Character block.
local block, made = nil, false
do
    local r, bestD = root(), nil
    for _, b in logic:GetChildren() do
        if b.Name == "Character" and b:IsA("BasePart") then
            if b:GetAttribute("MoveNameFt") == CONFIG.Name then
                block = b
                break
            end
            local d = r and (b.Position - r.Position).Magnitude or 0
            if not bestD or d < bestD then
                block, bestD = b, d
            end
        end
    end
end
if not block then
    local r = root()
    local at = r and r.Position or Vector3.zero
    at = Vector3.new(math.round(at.X), math.round(at.Y), math.round(at.Z))
    local before = {}
    for _, b in logic:GetChildren() do
        before[b] = true
    end
    fire("Create", "Character", at)
    local t0 = os.clock()
    repeat
        task.wait(0.1)
        for _, b in logic:GetChildren() do
            if not before[b] and b.Name == "Character" then
                block = b
            end
        end
    until block or os.clock() - t0 > 5
    if not block then
        note("Couldn't make a Character block (is build mode on?). Saved the code to jjs_movesets/David.txt.")
        return
    end
    made = true
    -- hidden: see-through and not solid
    fire("Transparency", { block }, "1")
    fire("Collide", { block }, nil, false)
    fire("Collide", { block }, true, false)
end

fire("LogicProp", { block }, "MoveNameFt", CONFIG.Name)
local applied = fire("LogicProp", { block }, "Dict", Base64.to_zstd(dict))

local missing = {}
for name, use in ANIMS do
    if not use then
        table.insert(missing, name)
    end
end
note(("David %s (%d characters)%s%s%s"):format(
    applied and "is on your Character block" or "couldn't be put on the block",
    #code,
    made and ", on a new hidden block where you stood" or "",
    saved and ". Saved to jjs_movesets/David.txt" or "",
    #missing > 0 and (". No animation found for: " .. table.concat(missing, ", ")) or ""))

--// JJS David builder -----------------------------------------------------------
-- Builds David Martinez (Cyberpunk: Edgerunners) as a custom character and puts
-- him on a Character block. Run it in a private server you own or have build
-- permission in. It does the whole job by itself:
--   * turns build mode on if it is off (the game's own "Toggle Build Menu"),
--   * finds your David block or makes one (invisible, not solid, where you stand),
--   * puts the moveset on it,
--   * turns build mode back off if it was the one that turned it on.
--
-- Base (normal David)
--   1  Sandevistan        costs HP. Slow-motion look, faster and stronger for
--                         the duration, everyone in range frozen, lightning,
--                         a trail and afterimages.
--   2  Sandevistan Punch  blinks to whoever you face, whatever the distance,
--                         and lands a heavy punch that throws them. Ends
--                         Sandevistan.
--   3  Kiroshi Blitz      six strikes from all sides, then a launching kick.
--   4  Overclock Uppercut launches them, follows them into the air and
--                         spikes them back into the ground.
--   R  Reflex Tuner       a counter. Get hit during it and you slip behind
--                         the attacker and punish them.
-- Awakening: Cyberskeleton
--   1  Sandevistan        longer reach, faster, harder.
--   2  Cyberskeleton Slam drops onto whoever you face, a crater that throws
--                         everyone up.
--   3  Overdrive Charge   charges, grabs the first person it hits, three
--                         heavy hooks and a throw.
--   4  Domain Expansion: Edge of the Moon
--                         a dome under David's moon. Everyone inside is hit
--                         from all sides at once, can't block it, and is left
--                         slowed while you are overclocked.
--   R  Reflex Tuner       the same counter.
-- Front dash (both)       instant, afterimages, costs HP. Custom characters
--                         can only replace the front dash (the game's rule).
--
-- HITBOXES: the builder's axes are +Z forward, +Y up, +X to your left, and a
-- hitbox is a box of SIZE centred on POSITION. Every melee box here sits in
-- front of you and reaches about as far as the swing does. "Finder" boxes
-- (the ones that only pick a target to blink to) deal 1 damage, can't kill
-- and don't interrupt.
--
-- AFTERIMAGES: a skill only makes afterimages while it is running, and while a
-- skill is running the game won't take your M1. So with FullAfterimages off
-- (the default) Sandevistan leaves a long burst of afterimages, then a trail
-- for the rest, and every move leaves its own, while M1 stays free.
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
    DomainSize = 60,       -- studs across (some servers cap effects at 40)
    DomainTime = 9,        -- how long the dome and its slow last
    DomainCost = 15,       -- HP
    DomainCooldown = 45,
    ColorA = "0, 255, 230",   -- cyan
    ColorB = "255, 40, 200",  -- magenta
    SkeletonColor = "255, 60, 60",
    MoonColor = "255, 244, 200",
    TrailTexture = 0,
    LeaveBuildModeOn = false, -- true: don't turn build mode back off
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
    Down = animOf("Gojo.Melee.Down"),
    Kick = animOf("Gojo.TwofoldKick"),
    Slam = animOf("Itadori.CrushingBlow"),
    Hook1 = animOf("Itadori.Melee.Melee1"),
    Hook2 = animOf("Itadori.Melee.Melee2"),
    Hook3 = animOf("Itadori.Melee.Melee3"),
    Charge = animOf("Itadori.Rush"),
    Counter = animOf("Hakari.Counter"),
    Domain = animOf("Gojo.ShortVoid") or animOf("Gojo.InfiniteVoid"),
}

--// Node helpers \\--
local TAG, FREEZE, TRAIL, DOME = "SANDE", "SANDE_FREEZE", "SANDE_TRAIL", "DAVID_DOME"
local A, B, SK = CONFIG.ColorA, CONFIG.ColorB, CONFIG.SkeletonColor

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
local function fx(effect, props)
    local n = node("VISUAL", props)
    n.EFFECT = effect
    return n
end
local function afterimage(color, opacity, tag)
    return fx("Afterimage", { COLOR = color, ["ALT COLOR"] = color,
        OPACITY = opacity or 0.35, ["ALT OPACITY"] = 1, TIME = 0.5, ["VISUAL TAG"] = tag })
end
local function colorFor(i, a, b)
    return i % 2 == 1 and (a or A) or (b or B)
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
-- Lightning and sparks on you, or (onTarget) on whoever you just hit.
local function zap(color, onTarget)
    local hit = onTarget and 1 or nil
    return {
        fx("Weak Lightning", { COLOR = color, SIZE = 1.4, TIME = 0.35, ["LAST HIT"] = hit }),
        fx("Energy Sparks", { COLOR = color, AMOUNT = 8, TIME = 0.4, ["LAST HIT"] = hit }),
    }
end
-- What a landed hit looks like: sparks and a ring on the target, a shake.
local function hitFx(color, heavy)
    return {
        fx("Sparks", { COLOR = color, AMOUNT = heavy and 14 or 8, ["LAST HIT"] = 0.3 }),
        fx("Ring", { COLOR = color, SIZE = heavy and 2.2 or 1.2, TIME = 0.35, ["LAST HIT"] = 0.3 }),
        heavy and fx("Wind Expand", { SIZE = 1.5, ["LAST HIT"] = 0.3 }) or nil,
        fx(heavy and "Shake Medium" or "Shake Light"),
    }
end
local function glow(color, time, tag)
    return fx("Glow", { COLOR = color, SIZE = 1.5, TIME = time, OPACITY = 0.3, ["ALT OPACITY"] = 1, ["VISUAL TAG"] = tag })
end
local function armTrails(color, time, tag)
    return {
        fx("Melee Trail", { COLOR = color, TIME = time, ["BODY PART"] = "Right Arm", ["VISUAL TAG"] = tag }),
        fx("Melee Trail", { COLOR = color, TIME = time, ["BODY PART"] = "Left Arm", ["VISUAL TAG"] = tag }),
    }
end

--// Hitboxes \\--
-- A melee box in front of you: `reach` studs deep, starting at your chest.
local function melee(reach, width, props)
    local n = node("HITBOX", props)
    n.POSITION = ("0, %s, %s"):format(props.UP or 0, 1 + reach / 2)
    n.SIZE = ("%s, %s, %s"):format(width, props.TALL or 7, reach)
    n.UP, n.TALL = nil, nil
    return n
end
-- A box centred on you, for slams and area hits.
local function area(across, tall, props)
    local n = node("HITBOX", props)
    n.POSITION = ("0, %s, 0"):format(props.UP or 0)
    n.SIZE = ("%s, %s, %s"):format(across, tall, across)
    n.UP = nil
    n["SINGLE TARGET"] = false
    return n
end
-- Picks whoever is in front of you (a lane `length` long) and goes to `branch`.
-- 1 damage that can't kill, a blink of stun, and it doesn't interrupt them.
local function reach(length, branch)
    return node("HITBOX", {
        POSITION = ("0, 0, %s"):format(1 + length / 2), SIZE = ("10, 10, %s"):format(length),
        DAMAGE = 1, STUN = 0.4, BLOCKABLE = false, ["CAN KILL"] = false, ["SINGLE TARGET"] = true,
        ["IGNORE WAKEUP"] = true, BRANCH = branch,
    })
end
local function look(time)
    return node("LOOK", { TIME = time, ["HORIZONTAL ONLY"] = true, ["LAST HIT"] = 1, SMOOTHNESS = 200 })
end
local function faceAim()
    return node("LOOK", { TIME = 0.08, ["CAMERA DIRECTION"] = true, ["HORIZONTAL ONLY"] = true, SMOOTHNESS = 200 })
end
-- Puts you `distance` studs in front of whoever you last hit, facing them.
local function blinkTo(distance, seconds)
    return {
        node("TELEPORT", { POSITION = ("0, 0, %s"):format(distance), ROTATION = "0, 180, 0", ["LAST HIT"] = seconds or 1 }),
        look(0.15),
    }
end
local function trail(part, color, duration)
    local c = color:gsub(" ", "")
    return node("PARTICLE", {
        ["BODY PART"] = part, TEXTURE = CONFIG.TrailTexture,
        DURATION = duration, RATE = 22, LIFETIME = "0.35, 0.45", SPEED = "0, 0",
        SIZE = "4.5, 4", TRANSPARENCY = "0.45, 1", COLOR = c .. " " .. c,
        ["LIGHT EMISSION"] = 1, ["LIGHT INFLUENCE"] = 0, ["LOCK TO PART"] = false,
        ["CANCEL TAG"] = TRAIL,
    })
end
-- Ends Sandevistan: the look, the trail, your boosts and everyone's freeze.
local function cleanup()
    return {
        fx("Cancel", { ["VISUAL TAG"] = TAG }),
        node("PARTICLE", { CANCEL = true, ["CANCEL TAG"] = TRAIL }),
        node("STATE", { STATE = "Cancel", ["STATE TAG"] = TAG }),
        node("STATE", { STATE = "Cancel", ["STATE TAG"] = FREEZE, ["LAST HIT"] = CONFIG.Duration + 1 }),
        fx("Field of View", { AMOUNT = 1, TIME = 0.3 }),
    }
end
local function skill(line, extra)
    local d = { Line = line, Req = {}, Prop = {} }
    for k, v in extra or {} do
        d[k] = v
    end
    return d
end
-- What a thrown target does (a BRANCH TARGET).
local function thrown(force, ragdoll)
    return { node("VELO", { FORCE = force, TIME = 0.3, FADE = true, RAGDOLL = ragdoll }) }
end

--// 1 Sandevistan (base and awakened) \\--
local slowmo = soundId({ "Toji", "SSK", "Flourish", "SlowMo" })
local function sandevistan(range, speed, damage, tint, colorA, colorB)
    local D = CONFIG.Duration
    local line = {}
    add(line, {
        slowmo and node("SFX", { ID = slowmo, VOLUME = 1 }) or nil,
        anim("Activate", 1.5),
        hurtSelf(CONFIG.SandeCost),
        fx("Screen Color", { COLOR = tint, AMOUNT = 0.05, OPACITY = -0.4, SIZE = 0.2, TIME = D, ["VISUAL TAG"] = TAG }),
        fx("Field of View", { AMOUNT = 25, TIME = 0.4, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" }),
        fx("Distortion", { SIZE = 3, TIME = 0.6 }),
        fx("Wind Ring", { COLOR = colorA, SIZE = 2.5, TIME = 0.6 }),
        fx("Ring", { COLOR = colorB, SIZE = 4, TIME = 0.8 }),
        fx("Light", { COLOR = colorA, SIZE = 2, TIME = D, ["VISUAL TAG"] = TAG }),
        glow(colorA, D, TAG),
    })
    add(line, zap(colorA))
    add(line, armTrails(colorB, D, TAG))
    add(line, {
        node("STATE", { STATE = "SpeedMultiplier", VALUE = speed, TIME = D, ["STATE TAG"] = TAG }),
        node("STATE", { STATE = "DamageMultiplier", VALUE = damage, TIME = D, ["STATE TAG"] = TAG }),
        -- everyone in range frozen: the box marks them, then a tagged stun
        -- so the punch can lift it early
        area(range, 20, { STUN = D, DAMAGE = 1, BLOCKABLE = false, ["CLEAR KNOCKBACK"] = true,
            ["CAN KILL"] = false, ["IGNORE WAKEUP"] = true }),
        node("STATE", { STATE = "Stun", TIME = D, ["LAST HIT"] = 0.5, ["STATE TAG"] = FREEZE }),
        fx("Weak Lightning", { COLOR = colorB, SIZE = 1.2, TIME = 0.5, ["LAST HIT"] = 0.5 }),
        trail("Torso", colorA, D),
        trail("HumanoidRootPart", colorB, D),
    })
    if CONFIG.FullAfterimages then
        add(line, burst(math.floor(D / 0.1), 0.1, colorA, colorB))
        add(line, cleanup())
    else
        add(line, burst(13, 0.09, colorA, colorB))
    end
    return skill(line)
end

--// 2 Sandevistan Punch \\--
local function punchHit()
    return {
        anim("Punch", 1.2),
        wait(0.18),
        melee(7, 7, { DAMAGE = CONFIG.PunchDamage, STUN = 1.2, ["STUN ANIM"] = true, DEBREE = 2,
            ["CLEAR KNOCKBACK"] = true, ["BRANCH TARGET"] = "Sent" }),
        fx("Black Flash", { ["LAST HIT"] = 0.3 }),
        hurtSelf(CONFIG.PunchCost),
    }
end
local punch = {}
add(punch, {
    faceAim(),
    afterimage(B),
    reach(120, "Go"),
    wait(0.05),
    -- nobody in front: a short lunge into the punch anyway
    node("VELO", { FORCE = "0, 0, 120", TIME = 0.2, FADE = true }),
})
add(punch, punchHit())
add(punch, hitFx(A, true))
add(punch, { wait(0.3) })
add(punch, cleanup())
local punchGo = {}
add(punchGo, burst(3, 0.03))
add(punchGo, blinkTo(4))
add(punchGo, zap(A))
add(punchGo, punchHit())
add(punchGo, hitFx(B, true))
add(punchGo, { afterimage(A), wait(0.35) })
add(punchGo, cleanup())
local punchSkill = skill(punch, { Branch = { Go = punchGo, Sent = thrown("0, 25, -110", 1.3) } })

--// 3 Kiroshi Blitz \\--
-- Each strike: blink to a side of them, the swing at full speed, the hit on
-- its contact frame, and time for the swing to finish (an animation stops the
-- moment its skill ends).
local function strike(animName, offset, rotation, damage, color)
    local out = {
        afterimage(color, 0.5),
        node("TELEPORT", { POSITION = offset, ROTATION = rotation, ["LAST HIT"] = 2 }),
        look(0.1),
        anim(animName, 1.15),
        wait(0.13),
        melee(6, 6, { DAMAGE = damage, STUN = 1, ["CLEAR KNOCKBACK"] = true }),
    }
    add(out, hitFx(color, false))
    add(out, { wait(0.17) })
    return out
end
local blitz = {}
add(blitz, {
    faceAim(),
    afterimage(A),
    reach(60, "Combo"),
    wait(0.05),
    -- nobody in reach: a jab where you stand
    anim("Jab1", 1),
    node("VELO", { FORCE = "0, 0, 60", TIME = 0.15, FADE = true }),
    wait(0.15),
    melee(6, 6, { DAMAGE = 3, STUN = 0.8 }),
    wait(0.3),
})
local blitzCombo = {}
add(blitzCombo, armTrails(A, 2.6))
add(blitzCombo, strike("Jab1", "0, 0, 3.5", "0, 180, 0", 3, A))
add(blitzCombo, strike("Jab2", "3.5, 0, 0", "0, 90, 0", 3, B))
add(blitzCombo, strike("Jab3", "0, 0, -3.5", "0, 0, 0", 3, A))
add(blitzCombo, strike("Jab4", "-3.5, 0, 0", "0, -90, 0", 3, B))
add(blitzCombo, strike("Jab2", "2.5, 0, 2.5", "0, 135, 0", 3, A))
add(blitzCombo, strike("Jab3", "-2.5, 0, 2.5", "0, -135, 0", 3, B))
add(blitzCombo, {
    afterimage(B),
    node("TELEPORT", { POSITION = "0, 0, 4", ROTATION = "0, 180, 0", ["LAST HIT"] = 2 }),
    look(0.12),
    anim("Kick", 1),
    wait(0.2),
    melee(7, 7, { DAMAGE = 8, STUN = 1, ["STUN ANIM"] = true, ["BRANCH TARGET"] = "Launched" }),
})
add(blitzCombo, hitFx(A, true))
add(blitzCombo, { afterimage(A), wait(0.45) })
local blitzSkill = skill(blitz, { Branch = { Combo = blitzCombo, Launched = thrown("0, 30, -80", 1.2) } })

--// 4 Overclock Uppercut \\--
-- Launches them, follows them up, and spikes them into the ground.
local upper = {}
add(upper, {
    faceAim(),
    afterimage(B),
    reach(40, "Go"),
    wait(0.05),
    node("VELO", { FORCE = "0, 0, 90", TIME = 0.15, FADE = true }),
    anim("Up", 1),
    wait(0.18),
    melee(6, 7, { UP = 1, TALL = 9, DAMAGE = 9, STUN = 1.1, ["STUN ANIM"] = true, ["BRANCH TARGET"] = "Up" }),
})
add(upper, hitFx(B, false))
add(upper, { wait(0.45) })
local upperGo = {}
add(upperGo, burst(2, 0.03))
add(upperGo, blinkTo(3.5))
add(upperGo, {
    anim("Up", 1),
    wait(0.18),
    melee(6, 7, { UP = 1, TALL = 9, DAMAGE = 7, STUN = 1.4, ["STUN ANIM"] = true, ["BRANCH TARGET"] = "Up" }),
})
add(upperGo, hitFx(B, false))
add(upperGo, {
    fx("Wind Streak", { COLOR = B, SIZE = 1.5, TIME = 0.4 }),
    wait(0.4),
    -- above them, where the launch has taken them
    afterimage(A),
    node("TELEPORT", { POSITION = "0, 4, 2", ROTATION = "0, 180, 0", ["LAST HIT"] = 2 }),
    node("VELO", { FORCE = "0, 0, 0", TIME = 0.25 }),
    look(0.1),
    anim("Down", 1),
    wait(0.15),
    node("HITBOX", { POSITION = "0, -2, 3", SIZE = "8, 10, 8", DAMAGE = 9, STUN = 1.2, ["STUN ANIM"] = true,
        ["HIT RAGDOLL"] = true, ["CLEAR KNOCKBACK"] = true, ["BRANCH TARGET"] = "Spike" }),
})
add(upperGo, hitFx(A, true))
add(upperGo, zap(A, true))
add(upperGo, { afterimage(B), wait(0.4) })
local upSkill = skill(upper, { Branch = {
    Go = upperGo,
    Up = thrown("0, 85, 0", 0.9),
    Spike = { node("VELO", { FORCE = "0, -200, -20", TIME = 0.25, RAGDOLL = 1.4 }),
        wait(0.25), fx("Mass Hit"), fx("Shake Heavy") },
} })

--// R Reflex Tuner (a counter) \\--
local counter = {}
add(counter, {
    anim("Counter", 1),
    glow(A, 0.8),
    fx("Shine", { COLOR = A, TIME = 0.4 }),
    node("COUNTER", { TIME = 0.8, STUN = 1.2, BRANCH = "Slip" }),
    wait(0.8),
})
local counterSlip = {}
add(counterSlip, burst(3, 0.03))
add(counterSlip, {
    -- behind them, facing their back
    node("TELEPORT", { POSITION = "0, 0, -4", ROTATION = "0, 0, 0", ["LAST HIT"] = 2 }),
    look(0.1),
    fx("Distortion", { SIZE = 2, TIME = 0.3 }),
    anim("Hook3", 1.1),
    wait(0.15),
    melee(7, 7, { DAMAGE = 12, STUN = 1.3, ["STUN ANIM"] = true, BLOCKABLE = false, ["BRANCH TARGET"] = "Sent" }),
})
add(counterSlip, hitFx(B, true))
add(counterSlip, { afterimage(A), wait(0.4) })
local counterSkill = skill(counter, { Branch = { Slip = counterSlip, Sent = thrown("0, 20, -90", 1.2) } })

--// Awakening moves \\--

-- 2 Cyberskeleton Slam
local function impact()
    return {
        area(30, 10, { UP = -2, DAMAGE = 18, STUN = 1.5, ["STUN ANIM"] = true, DEBREE = 4, BLOCKABLE = false,
            ["BRANCH TARGET"] = "Crater" }),
        fx("Shake Heavy"),
        fx("Wind Expand", { SIZE = 2 }),
        fx("Ring", { COLOR = SK, SIZE = 3, TIME = 0.6 }),
        fx("Wind Ring", { COLOR = A, SIZE = 4, TIME = 0.7 }),
        fx("Burst", { COLOR = SK, SIZE = 2 }),
        fx("Mass Hit"),
        fx("Screen Color", { COLOR = "255, 120, 120", AMOUNT = 0.15, TIME = 0.4 }),
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
    wait(0.15), afterimage(A),
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
    afterimage(A),
    fx("Wind Streak", { COLOR = SK, SIZE = 2, TIME = 0.3 }),
    wait(0.2),
    afterimage(SK),
    node("VELO", { FORCE = "0, -240, 0", TIME = 0.12 }),
    wait(0.12),
})
add(slamLeap, impact())
local slamSkill = skill(slam, { Branch = { Leap = slamLeap, Crater = thrown("0, 70, 0", 1.5) } })

-- 3 Overdrive Charge: charges, grabs the first person it reaches, three
-- heavy hooks and a throw.
local charge = {}
add(charge, { faceAim(), anim("Charge", 1), afterimage(SK) })
add(charge, armTrails(SK, 0.9))
for i = 1, 6 do
    add(charge, {
        node("VELO", { FORCE = "0, 0, 130", TIME = 0.08 }),
        melee(7, 8, { DAMAGE = 1, STUN = 0.6, BLOCKABLE = false, ["CAN KILL"] = false, BRANCH = "Impact" }),
        afterimage(colorFor(i, SK, A), 0.4),
        wait(0.07),
    })
end
add(charge, { wait(0.3) })
local chargeImpact = {}
add(chargeImpact, {
    node("VELO", { FORCE = "0, 0, 0", TIME = 0.05 }),
    look(0.1),
    -- held in front of you while the hooks land
    node("GRAB", { POSITION = "0, 0, 3.5", TIME = 1.1, ["LAST HIT"] = 1 }),
})
for i, name in { "Hook1", "Hook2", "Hook3" } do
    add(chargeImpact, {
        anim(name, 1.1),
        wait(0.15),
        melee(7, 8, { DAMAGE = i == 3 and 9 or 6, STUN = 1.2, BLOCKABLE = false, DEBREE = i == 3 and 3 or 0,
            ["BRANCH TARGET"] = i == 3 and "Thrown" or nil }),
    })
    add(chargeImpact, hitFx(SK, i == 3))
    add(chargeImpact, { afterimage(SK, 0.5), wait(0.17) })
end
add(chargeImpact, { fx("Mass Hit"), fx("Shake Heavy"), wait(0.4) })
local chargeSkill = skill(charge, { Branch = { Impact = chargeImpact, Thrown = thrown("0, 40, -110", 1.5) } })

-- 4 Domain Expansion: Edge of the Moon
-- The dome, the night and the moon are effects left standing where you cast
-- (an effect with an ALT POSITION stays put instead of following you). The
-- sure-hit is a row of unblockable boxes the size of the dome.
local function domain()
    local S, T = CONFIG.DomainSize, CONFIG.DomainTime
    local stay = "0, 0.05, 0" -- a nudge of ALT POSITION so the effect is left in place
    local line = {}
    add(line, {
        slowmo and node("SFX", { ID = slowmo, VOLUME = 1, SPEED = 0.8 }) or nil,
        anim("Domain", 1),
        node("STATE", { STATE = "IFrame", TIME = 1.2 }),
        hurtSelf(CONFIG.DomainCost),
        fx("Field of View", { AMOUNT = 30, TIME = 0.5, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" }),
        fx("Distortion", { SIZE = 5, TIME = 0.8 }),
        fx("Wind Ring", { COLOR = B, SIZE = 6, TIME = 0.8 }),
        wait(0.45),
        -- the dome: grows from nothing, dark from the inside
        fx("Sphere", { COLOR = "8, 6, 30", ["ALT COLOR"] = "30, 0, 60", SIZE = 1, ["ALT SIZE"] = S,
            OPACITY = 0.25, ["ALT OPACITY"] = 0.4, ["ALT POSITION"] = stay, TIME = 0.5,
            ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out", ["VISUAL TAG"] = DOME }),
        wait(0.5),
        fx("Sphere", { COLOR = "30, 0, 60", ["ALT COLOR"] = "8, 6, 30", SIZE = S, ["ALT SIZE"] = S,
            OPACITY = 0.4, ["ALT OPACITY"] = 0.55, ["ALT POSITION"] = stay, TIME = T, ["VISUAL TAG"] = DOME }),
        -- David's moon, high in the dome
        fx("Sphere", { COLOR = CONFIG.MoonColor, ["ALT COLOR"] = CONFIG.MoonColor, SIZE = S * 0.16, ["ALT SIZE"] = S * 0.16,
            POSITION = ("0, %s, %s"):format(S * 0.3, S * 0.18), ["ALT POSITION"] = ("0, %s, %s"):format(S * 0.3 + 0.05, S * 0.18),
            OPACITY = 0, ["ALT OPACITY"] = 0, TIME = T, ["VISUAL TAG"] = DOME }),
        fx("Light", { COLOR = CONFIG.MoonColor, SIZE = 4, TIME = T, ["VISUAL TAG"] = DOME }),
        fx("Circle Glow", { COLOR = A, SIZE = S / 10, TIME = T, ["VISUAL TAG"] = DOME }),
        fx("Screen Color", { COLOR = "120, 90, 255", AMOUNT = 0.08, OPACITY = -0.3, SIZE = 0.3, TIME = T, ["VISUAL TAG"] = DOME }),
        fx("Shake Heavy"),
        fx("Field of View", { AMOUNT = 1, TIME = 0.4 }),
        -- you, overclocked
        node("STATE", { STATE = "SpeedMultiplier", VALUE = CONFIG.AwakeSpeed, TIME = T, ["STATE TAG"] = DOME }),
        node("STATE", { STATE = "DamageMultiplier", VALUE = CONFIG.AwakeDamage, TIME = T, ["STATE TAG"] = DOME }),
        glow(CONFIG.MoonColor, T, DOME),
    })
    -- the sure-hit: everyone in the dome, from every side at once
    for i = 1, 7 do
        local color = colorFor(i)
        add(line, {
            afterimage(color, 0.3),
            area(S, S, { DAMAGE = 3, STUN = 0.6, ["ATTACK TYPE"] = "Domain", BLOCKABLE = false,
                ["CLEAR KNOCKBACK"] = true, ["HIT RAGDOLL"] = true, ["CAN KILL"] = i == 7 }),
            fx("Slash", { COLOR = color, SIZE = 1.5, ["LAST HIT"] = 0.3, ROTATION = ("0, %d, %d"):format(i * 51, i * 37) }),
            fx("Afterimage", { COLOR = color, ["ALT COLOR"] = color, OPACITY = 0.3, ["ALT OPACITY"] = 1, TIME = 0.4,
                ["LAST HIT"] = 0.3, POSITION = ("%d, 0, %d"):format(i % 2 == 0 and 3 or -3, i % 3 == 0 and 3 or -3) }),
            fx("Sparks", { COLOR = color, AMOUNT = 6, ["LAST HIT"] = 0.3 }),
            fx("Shake Light"),
            wait(0.2),
        })
    end
    add(line, {
        -- the last one throws them, and leaves them slowed for the rest
        area(S, S, { DAMAGE = 10, STUN = 1.2, ["STUN ANIM"] = true, ["ATTACK TYPE"] = "Domain", BLOCKABLE = false,
            ["HIT RAGDOLL"] = true, DEBREE = 2, ["BRANCH TARGET"] = "Moonstruck" }),
        fx("Black Flash", { ["LAST HIT"] = 0.3 }),
        fx("Weak Lightning", { COLOR = CONFIG.MoonColor, SIZE = 2, TIME = 0.6, ["LAST HIT"] = 0.3 }),
        node("STATE", { STATE = "SpeedMultiplier", VALUE = 0.45, TIME = T, ["LAST HIT"] = 0.5, ["STATE TAG"] = DOME }),
        fx("Shake Heavy"),
        fx("Mass Hit"),
        wait(0.4),
    })
    return skill(line, { Branch = { Moonstruck = thrown("0, 55, 0", 1.3) } })
end

--// Front dash \\--
local dash = {}
add(dash, {
    hurtSelf(CONFIG.DashCost),
    afterimage(A),
    fx("Wind Streak", { COLOR = A, SIZE = 1.2, TIME = 0.25 }),
    node("VELO", { FORCE = ("0, 0, %d"):format(CONFIG.DashForce), TIME = 0.1 }),
    wait(0.03), afterimage(B),
    wait(0.03), afterimage(A),
    wait(0.03), afterimage(B),
})

--// Awakening itself \\--
local awaken = {}
add(awaken, {
    anim("Activate", 1),
    node("STATE", { STATE = "IFrame", TIME = 1.5 }),
    fx("Screen Color", { COLOR = "255, 150, 150", AMOUNT = 0.1, OPACITY = -0.2, SIZE = 0.3, TIME = 1.5 }),
    fx("Shake Heavy"),
    fx("Burst", { COLOR = SK, SIZE = 2.5 }),
    fx("Wind Ring", { COLOR = SK, SIZE = 5, TIME = 0.8 }),
    glow(SK, CONFIG.AwakeningTime),
})
add(awaken, zap(SK))
add(awaken, burst(6, 0.1, SK, A))

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
    slot("Sandevistan", 1, CONFIG.Cooldown, cost, sandevistan(CONFIG.FreezeRange, CONFIG.SpeedBoost, CONFIG.DamageBoost, "170, 255, 240", A, B)),
    slot("Sandevistan Punch", 2, 4, "Blinks to who you face. Ends Sandevistan", punchSkill),
    slot("Kiroshi Blitz", 3, 12, "Six strikes and a kick", blitzSkill),
    slot("Overclock Uppercut", 4, 10, "Launch, follow, spike", upSkill),
    slot("Sandevistan", 1, CONFIG.Cooldown, cost, sandevistan(CONFIG.AwakeRange, CONFIG.AwakeSpeed, CONFIG.AwakeDamage, "255, 190, 200", SK, A), true),
    slot("Cyberskeleton Slam", 2, 14, "", slamSkill, true),
    slot("Overdrive Charge", 3, 14, "Grabs the first one it hits", chargeSkill, true),
    slot("Domain Expansion: Edge of the Moon", 4, CONFIG.DomainCooldown, ("Costs %d HP"):format(CONFIG.DomainCost), domain(), true),
    { K_NAME = "SPECIAL", NAME = "Reflex Tuner", COOLDOWN = 10, DATA = encode(counterSkill) },
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

--// Build mode \\--
-- The game marks build mode with a BuildTag under your player, and flips it
-- with DebugService's Debug event ("Build", you): what its own "Toggle Build
-- Menu" keybind sends.
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
local build = remotes and remotes:FindFirstChild("BuildEvent")
local logic = workspace:FindFirstChild("Logic")
local function buildOn()
    return LocalPlayer:FindFirstChild("BuildTag") ~= nil
end
local function toggleBuild()
    local ok = pcall(function()
        ReplicatedStorage.Knit.Knit.Services.DebugService.RE.Debug:FireServer("Build", LocalPlayer)
    end)
    return ok
end
local function setBuild(want)
    if buildOn() == want then
        return true
    end
    if not toggleBuild() then
        return false
    end
    local t0 = os.clock()
    repeat
        task.wait(0.1)
    until buildOn() == want or os.clock() - t0 > 4
    return buildOn() == want
end

if not build or not logic then
    note("This server has no builder. Saved the code to jjs_movesets/David.txt.")
    return
end
local turnedOn = false
if not buildOn() then
    turnedOn = setBuild(true)
    if not turnedOn then
        note("Couldn't turn build mode on (you need to own this server or have build permission). Saved the code to jjs_movesets/David.txt.")
        return
    end
    task.wait(0.3)
end
-- Whatever happens from here, build mode goes back to how it was.
local function restoreBuild()
    if turnedOn and not CONFIG.LeaveBuildModeOn then
        turnedOn = false
        return setBuild(false)
    end
    return true
end

local function root()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function fire(...)
    return pcall(build.FireServer, build, ...)
end

--// Find or make the Character block, then put David on it \\--
local okRun, err = pcall(function()
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
            note("Couldn't make a Character block. Saved the code to jjs_movesets/David.txt.")
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
    -- give the server a moment to take it before build mode goes off
    local t0 = os.clock()
    repeat
        task.wait(0.15)
    until block:GetAttribute("Dict") == dict or os.clock() - t0 > 3

    local missing = {}
    for name, use in ANIMS do
        if not use then
            table.insert(missing, name)
        end
    end
    local wasOn = turnedOn
    local off = restoreBuild()
    note(("David %s (%d characters)%s%s%s%s"):format(
        applied and "is on your Character block" or "couldn't be put on the block",
        #code,
        made and ", on a new hidden block where you stood" or "",
        saved and ". Saved to jjs_movesets/David.txt" or "",
        wasOn and (off and ". Build mode turned on for this and back off" or ". Build mode is still on: couldn't turn it off")
            or "",
        #missing > 0 and (". No animation found for: " .. table.concat(missing, ", ")) or ""))
end)
if not okRun then
    restoreBuild()
    note("Something went wrong: " .. tostring(err) .. ". Saved the code to jjs_movesets/David.txt.")
elseif turnedOn then
    restoreBuild()
end

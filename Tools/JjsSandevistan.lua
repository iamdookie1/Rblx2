--// JJS Sandevistan builder ---------------------------------------------------
-- Builds a "Sandevistan" skill (David Martinez, Cyberpunk: Edgerunners) for a
-- custom character and puts it on your Character block. Run it in your own
-- private server with build mode on and a Character block placed.
--
-- What the skill does:
--   * a slow-motion tint, wider field of view and a distortion pulse;
--   * you move faster and hit harder for the duration;
--   * everyone within the freeze range is frozen in place (0 damage);
--   * cyan and magenta afterimages of you trail behind you;
--   * the first time you land a hit while it runs, that's the big punch: you
--     take a little damage, everything ends and the visuals disappear;
--   * if you never hit anyone it ends on its own after the duration.
--
-- Built only from the builder's own nodes (ReplicatedStorage.Modules.SkillDefault),
-- in the same format its Export button gives. The code is also copied to your
-- clipboard and saved to jjs_movesets/, so you can paste it into the
-- Character block's Import box yourself if applying it doesn't work.

local CONFIG = {
    Name = "Sandevistan",
    Key = 1,               -- which skill slot it goes on
    Cooldown = 25,
    Duration = 10,         -- seconds
    FreezeRange = 40,      -- studs across
    SpeedBoost = 1.8,      -- your walk speed multiplier while it runs
    DamageBoost = 1.6,     -- your damage multiplier while it runs (the big punch)
    SelfDamage = 3,        -- what the punch costs you
    ColorA = "0, 255, 230",   -- cyan
    ColorB = "255, 40, 200",  -- magenta
    Apply = true,          -- put it on your Character block straight away
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

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
local function soundId()
    local ok, id = pcall(function()
        return ReplicatedStorage.Sounds.Toji.SSK.Flourish.SlowMo.SoundId
    end)
    return ok and tonumber(tostring(id):match("%d+")) or nil
end

--// The skill \\--
local TAG, FREEZE = "SANDE", "SANDE_FREEZE"

local function afterimage(color)
    return {
        K_NAME = "VISUAL", EFFECT = "Afterimage", COLOR = color, ["ALT COLOR"] = color,
        OPACITY = 0.35, ["ALT OPACITY"] = 1, TIME = 0.5, ["VISUAL TAG"] = TAG,
    }
end

-- Everything that has to stop at the end, however it ends.
local function cleanup()
    return {
        { K_NAME = "VISUAL", EFFECT = "Cancel", ["VISUAL TAG"] = TAG },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = TAG },
        { K_NAME = "STATE", STATE = "Cancel", ["STATE TAG"] = FREEZE, ["LAST HIT"] = CONFIG.Duration + 1 },
        { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 1, TIME = 0.3 },
    }
end

local line = {}
local id = soundId()
if id then
    table.insert(line, { K_NAME = "SFX", ID = id, VOLUME = 1 })
end
for _, node in {
    -- the slowed-down look
    { K_NAME = "VISUAL", EFFECT = "Screen Color", COLOR = "170, 255, 240", AMOUNT = 0.05, OPACITY = -0.4,
        SIZE = 0.2, TIME = CONFIG.Duration, ["VISUAL TAG"] = TAG },
    { K_NAME = "VISUAL", EFFECT = "Field of View", AMOUNT = 25, TIME = 0.4, ["EASING STYLE"] = "Quad", ["EASING DIRECTION"] = "Out" },
    { K_NAME = "VISUAL", EFFECT = "Distortion", SIZE = 3, TIME = 0.6 },
    -- you, faster and stronger
    { K_NAME = "STATE", STATE = "SpeedMultiplier", VALUE = CONFIG.SpeedBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    { K_NAME = "STATE", STATE = "DamageMultiplier", VALUE = CONFIG.DamageBoost, TIME = CONFIG.Duration, ["STATE TAG"] = TAG },
    -- everyone around you frozen: a 0 damage hitbox marks them, then the
    -- stun goes on with its own tag so it can be lifted when this ends
    { K_NAME = "HITBOX", POSITION = "0, 0, 0", SIZE = ("%d, 20, %d"):format(CONFIG.FreezeRange, CONFIG.FreezeRange),
        STUN = -1, DAMAGE = 0, BLOCKABLE = false, ["SINGLE TARGET"] = false, ["CLEAR KNOCKBACK"] = true, ["CAN KILL"] = false },
    { K_NAME = "STATE", STATE = "Stun", TIME = CONFIG.Duration, ["LAST HIT"] = 0.5, ["STATE TAG"] = FREEZE },
    -- past the freeze's own hits before watching for the punch
    { K_NAME = "WAIT", TIME = 0.3 },
    -- the trail, checking for a landed hit between afterimages
    afterimage(CONFIG.ColorA),
    { K_NAME = "WAIT", TIME = 0.08 },
    { K_NAME = "HITCNCL", TIME = 0.12, ENDLAG = 0, BRANCH = "Punch" },
    afterimage(CONFIG.ColorB),
    { K_NAME = "WAIT", TIME = 0.08 },
    { K_NAME = "HITCNCL", TIME = 0.12, ENDLAG = 0, BRANCH = "Punch" },
    { K_NAME = "LOOP", ["LOOP BACK"] = 6, ["LOOP AMOUNT"] = math.floor((CONFIG.Duration - 0.3) / 0.16) },
    -- ran out without a punch
    { K_NAME = "BRANCH", BRANCH = "End" },
} do
    table.insert(line, node)
end

local punch = {
    { K_NAME = "HPGIB", AMOUNT = -CONFIG.SelfDamage },
    { K_NAME = "VISUAL", EFFECT = "Shake Medium" },
}
for _, node in cleanup() do
    table.insert(punch, node)
end

local skill = {
    Line = line,
    Req = {},
    Prop = {},
    Branch = { Punch = punch, End = cleanup() },
}

local dict = HttpService:JSONEncode({
    {
        K_NAME = "SKILL", NAME = CONFIG.Name, KEY = CONFIG.Key, COOLDOWN = CONFIG.Cooldown,
        ADD = false, ["TOOL TIP"] = "Freezes everyone around you. Land a hit to end it.",
        DATA = HttpService:JSONEncode(skill),
    },
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
    local root = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
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

note(("%s built (%d characters).%s%s%s"):format(CONFIG.Name, #code,
    applied and " Put on your nearest Character block." or " No Character block found to put it on.",
    copied and " Code copied." or "",
    saved and " Saved to jjs_movesets/Sandevistan.txt." or ""))
if not applied then
    note("Place a Character block in build mode and run this again, or paste the code into the block's Import box.")
end

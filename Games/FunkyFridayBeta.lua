--// [MADNESS] Funky Friday -- beta autoplayer (WindUI).
--
-- Auto play, with how often each judgement comes out (Sick / Good / Ok / Bad /
-- Miss chances, or perfect 0.00ms hits) and how long a key stays down after a
-- hit. It runs on its own, separate from the full script (Games/FunkyFriday.lua):
--
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Games/FunkyFridayBeta.lua'))()
--
-- How it plays (the full script's game mode): hits are judged on the client.
-- Lane:Hit(isKeyDown, timestamp) turns the os.clock() of a press into a song
-- time with the playback sample and the HitboxOffset setting, and anything
-- within 50ms of the note is a Sick, 100ms a Good, 150ms an Ok, and anything
-- inside its 200ms window a Bad. The worker reads the real notes (time,
-- length, type) out of the game and calls Field:HitLane with the timestamp
-- each note is due, moved by the judgement rolled for it, worked out ahead of
-- the frame so frame rate doesn't matter. A rolled Miss leaves the note alone. Hold notes are held their full length; Death, Poison and
-- Mechanic notes are left alone. The game's modules live in
-- PlayerScripts.ClientActor, so the worker runs there through run_on_actor, or
-- here when getgc can see them.
--
-- It links up with the full script (the dev version) across clients through a
-- web relay (an ntfy topic for your server, which sees your UserId): anyone in
-- the lobby running Games/FunkyFriday.lua sees you're on beta, and can send
-- you commands from its Cmds tab (see "link" below).

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- A second run of the script shuts the first one down.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__FunkyFridayBetaStop) == "function" then pcall(Genv.__FunkyFridayBetaStop) end

-- Settings go to the worker (in whichever VM it runs) as attributes on a
-- folder both VMs can see.
local Bridge = Instance.new("Folder")
Bridge.Name = "FFB_" .. HttpService:GenerateGUID(false):sub(1, 8)
do
    local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
    Bridge.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
end
Bridge:SetAttribute("Enabled", false)

local Auto = {
    Enabled = false,
    -- how often each judgement comes out, as weights (they don't need to add
    -- up to 100). all Sick by default.
    Chance = { Sick = 100, Good = 0, Ok = 0, Bad = 0, Miss = 0 },
    Perfect = false,       -- every hit dead on the note: 0.00ms
    -- how long a key stays down after hitting a normal note (hold notes are
    -- always held for their full length)
    PressHold = true,      -- off lets go straight away
    PressHoldMs = 60,
    PressRandom = false,   -- vary it per note
    PressRandomRange = 30, -- % either side of PressHoldMs
}
local GRADE_ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }

-- what the dev script has done to this copy (see the link below): chances
-- swapped out, or auto play held off, until a moment passes
local Prank = { Chance = nil, ChanceUntil = 0, FrozenUntil = 0 }

local function pushSettings()
    local now = os.clock()
    local pranked = Prank.Chance and now < Prank.ChanceUntil
    local chances = pranked and Prank.Chance or Auto.Chance
    Bridge:SetAttribute("Enabled", Auto.Enabled and now >= Prank.FrozenUntil)
    Bridge:SetAttribute("Perfect", Auto.Perfect and not pranked)
    Bridge:SetAttribute("PressHold", Auto.PressHold)
    Bridge:SetAttribute("PressHoldMs", Auto.PressHoldMs)
    Bridge:SetAttribute("PressRandom", Auto.PressRandom)
    Bridge:SetAttribute("PressRandomRange", Auto.PressRandomRange)
    for _, name in ipairs(GRADE_ORDER) do
        Bridge:SetAttribute("Chance" .. name, chances[name] or 0)
    end
end
pushSettings()

local WORKER = [==[
local BRIDGE_NAME = "__BRIDGE__"
local WORKER_ID = "__WORKER__"
local RunService = game:GetService("RunService")

local bridge
for _, getRoot in ipairs({
    function() return gethui and gethui() end,
    function() return game:GetService("CoreGui") end,
    function() return game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui") end,
}) do
    local ok, root = pcall(getRoot)
    if ok and root then
        bridge = root:FindFirstChild(BRIDGE_NAME)
        if bridge then break end
    end
end
if not bridge then return end

local function attr(name, default)
    local value = bridge:GetAttribute(name)
    if value == nil then return default end
    return value
end

-- the game's framework table: VSRG (with the InputHandler that knows your
-- field) and the SettingsHandler
local function findFramework()
    if typeof(getgc) ~= "function" then return nil end
    local ok, objects = pcall(getgc, true)
    if not ok then return nil end
    for _, value in ipairs(objects) do
        if type(value) == "table" then
            local vsrg = rawget(value, "VSRG")
            if type(vsrg) == "table" and type(rawget(value, "SettingsHandler")) == "table"
                and type(rawget(vsrg, "InputHandler")) == "table" then
                return value
            end
        end
    end
    return nil
end

local Framework
local nextSearch = 0
local Lanes = {}   -- lane -> { Down, Hold, ReleaseAt (song time), LastPress }
local Planned = setmetatable({}, { __mode = "k" }) -- note -> true pressed / false left alone
local Offsets = setmetatable({}, { __mode = "k" }) -- note -> timing error, rolled once
local lastField
local rng = Random.new()

-- timing error for each judgement, in ms either side of the note, kept clear
-- of the game's 50 / 100 / 150 / 200ms edges
local GRADES = {
    Sick = { 0, 30 }, Good = { 60, 90 }, Ok = { 110, 140 }, Bad = { 160, 190 },
}
local ORDER = { "Sick", "Good", "Ok", "Bad", "Miss" }

local function chance(name)
    return math.max(tonumber(attr("Chance" .. name, name == "Sick" and 100 or 0)) or 0, 0)
end

-- rolls a judgement by the chances: the timing error in seconds, or nil for
-- a miss (the note is left alone)
local function rollOffset()
    -- perfect: the press is stamped to the note's own time, which Lane:Hit
    -- turns back into exactly that song time, so the game judges it 0.00ms
    if attr("Perfect", false) then return 0 end
    local total = 0
    for _, name in ipairs(ORDER) do total += chance(name) end
    if total <= 0 then return 0 end
    local roll = rng:NextNumber(0, total)
    local pick = "Sick"
    for _, name in ipairs(ORDER) do
        roll -= chance(name)
        if roll <= 0 then
            pick = name
            break
        end
    end
    if pick == "Miss" then return nil end
    local band = GRADES[pick]
    local ms = rng:NextNumber(band[1], band[2])
    if rng:NextNumber() < 0.5 then ms = -ms end
    return ms / 1000
end

-- seconds a key stays down after a normal note, cut short when the next note
-- in the lane comes sooner
local function tapLength()
    if not attr("PressHold", true) then return 0.001 end
    local ms = tonumber(attr("PressHoldMs", 60)) or 60
    local range = attr("PressRandom", false) and (tonumber(attr("PressRandomRange", 0)) or 0) or 0
    if range > 0 then
        local spread = ms * range / 100
        ms = rng:NextNumber(math.max(ms - spread, 1), ms + spread)
    end
    return math.max(ms, 1) / 1000
end

local function ignored(note)
    local kind = type(note.NoteData) == "table" and note.NoteData.Type
    if not kind then return false end
    local configs = Framework.Configs
    local list = configs and configs.VSRG and configs.VSRG.IgnoredNoteTypes or { "Death", "Poison", "Mechanic" }
    return table.find(list, kind) ~= nil
end

local function releaseAll(field)
    for lane, state in pairs(Lanes) do
        if state.Down then pcall(field.HitLane, field, lane, false, os.clock()) end
    end
    table.clear(Lanes)
end

local function hitboxOffset()
    local ok, value = pcall(function() return Framework.SettingsHandler:Get("HitboxOffset") end)
    return ok and tonumber(value) or 0
end

local candidates = {}
local function byTime(a, b) return a.Time < b.Time end

local connection
connection = RunService.Heartbeat:Connect(function(dt)
    if not bridge.Parent or attr("Stop", false) then
        if lastField then pcall(releaseAll, lastField) end
        connection:Disconnect()
        return
    end
    local owner = bridge:GetAttribute("Owner")
    if owner and owner ~= WORKER_ID then
        connection:Disconnect()
        return
    end
    local playing = attr("Enabled", false)
    if not playing then
        if lastField then
            pcall(releaseAll, lastField)
            lastField = nil
        end
        return
    end

    if not Framework then
        if os.clock() < nextSearch then return end
        nextSearch = os.clock() + 3
        Framework = findFramework()
        if not Framework then return end
        if bridge:GetAttribute("Owner") then
            connection:Disconnect()
            return
        end
        bridge:SetAttribute("Owner", WORKER_ID)
        bridge:SetAttribute("Where", WORKER_ID)
    end

    local handler = Framework.VSRG and Framework.VSRG.InputHandler
    local field = handler and handler.Field
    if field ~= lastField then
        if lastField then pcall(releaseAll, lastField) end
        lastField = field
        Planned = setmetatable({}, { __mode = "k" })
        Offsets = setmetatable({}, { __mode = "k" })
    end
    local song = field and field.Game
    if not song or song.Ending or type(field.Lanes) ~= "table" then
        if bridge:GetAttribute("Status") ~= "waiting for a song" then bridge:SetAttribute("Status", "waiting for a song") end
        return
    end
    if bridge:GetAttribute("Status") ~= "playing" then bridge:SetAttribute("Status", "playing") end

    local sample = song.TimePositionSample
    local samplePos = sample and sample.Position or song.TimePosition
    if type(samplePos) ~= "number" then return end
    local sampleClock = sample and sample.Clock or os.clock()
    local playback = song.AdjustedPlayback or 1
    local now = samplePos + (os.clock() - sampleClock) * playback
    local hitbox = hitboxOffset() / 1000
    -- everything due before the next frame goes out now, each press stamped
    -- with its own moment, so the game judges it as if it came exactly then
    local horizon = now + math.max(dt, 1 / 240) * 1.5 * playback

    local function stamp(songTime)
        return sampleClock + (songTime - samplePos - hitbox) / playback
    end

    for lane, laneObject in pairs(field.Lanes) do
        local state = Lanes[lane]
        if not state then
            state = { Down = false, Hold = false, ReleaseAt = 0, LastPress = -math.huge }
            Lanes[lane] = state
        end

        table.clear(candidates)
        if type(laneObject) == "table" and type(laneObject.Notes) == "table" then
            for _, note in pairs(laneObject.Notes) do
                if type(note) == "table" and not note.Hit and not note.Cleaned and type(note.Time) == "number"
                    and Planned[note] == nil and note.Time > now - 0.18 then
                    candidates[#candidates + 1] = note
                end
            end
        end
        table.sort(candidates, byTime)

        local index = 1
        for _ = 1, 256 do
            local note = candidates[index]
            local pressAt
            if note then
                local offset = Offsets[note]
                if offset == nil then
                    if ignored(note) then
                        Planned[note] = false
                        index += 1
                        continue
                    end
                    offset = rollOffset()
                    if not offset then
                        Planned[note] = false
                        index += 1
                        continue
                    end
                    Offsets[note] = offset
                end
                -- presses in a lane never go back in time on tightly packed notes
                pressAt = math.max(note.Time + offset, state.LastPress + 0.001)
            end

            if state.Down then
                local releaseAt = state.ReleaseAt
                if not state.Hold and pressAt and pressAt <= horizon then
                    -- the next note comes before this tap would let go
                    releaseAt = math.min(releaseAt, (state.LastPress + pressAt) / 2)
                end
                if releaseAt <= horizon then
                    pcall(field.HitLane, field, lane, false, stamp(math.max(releaseAt, state.LastPress)))
                    state.Down = false
                else
                    break
                end
            end

            if not note or pressAt > horizon then break end
            pcall(field.HitLane, field, lane, true, stamp(pressAt))
            Planned[note] = true
            state.Down = true
            state.LastPress = pressAt
            local length = tonumber(note.Length) or 0
            state.Hold = length > 0
            state.ReleaseAt = state.Hold and (note.Time + length) or (pressAt + tapLength())
            index += 1
        end
    end
end)
]==]

local Workers = { Here = false, Actor = false }

local function findActor()
    local scripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
    local actor = scripts and scripts:FindFirstChild("ClientActor")
    if not actor and typeof(getactors) == "function" then
        local ok, list = pcall(getactors)
        if ok and type(list) == "table" then
            for _, candidate in ipairs(list) do
                if candidate.Name == "ClientActor" then return candidate end
            end
        end
    end
    return actor
end

-- One worker here, one in the actor when the executor can; whichever finds
-- the game first plays and the other stops. They start when auto play is
-- first turned on, and the actor one is tried again until it's in: run too
-- early (in the loading screen) ClientActor isn't there yet, and the worker
-- here can't see the game's modules on its own, so auto play never started.
local function startWorkers()
    if not Workers.Here and typeof(getgc) == "function" then
        local fn = loadstring(WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "ThisVM"))
        if fn then
            task.spawn(fn)
            Workers.Here = true
        end
    end

    local run = (typeof(run_on_actor) == "function" and run_on_actor)
        or (type(syn) == "table" and typeof(syn.run_on_actor) == "function" and syn.run_on_actor)
    if not Workers.Actor and run then
        local actor = findActor()
        if actor and pcall(run, actor, (WORKER:gsub("__BRIDGE__", Bridge.Name):gsub("__WORKER__", "Actor"))) then
            Workers.Actor = true
        end
    end
    return Workers.Here or Workers.Actor
end

local canPlay = typeof(getgc) == "function" or typeof(run_on_actor) == "function"
    or (type(syn) == "table" and typeof(syn.run_on_actor) == "function")

--// link ----------------------------------------------------------------------
-- Funky Friday (the dev script, Games/FunkyFriday.lua) and Funky Friday beta
-- (Games/FunkyFridayBeta.lua) find each other through a relay on the web, not
-- through the game. Every copy in a server joins the same ntfy topic (named
-- from the server's JobId), listens to it over a WebSocket, and posts small
-- JSON messages to it with the executor's request function. Nothing is played
-- on your character, so it works without one, commands land in a fraction of
-- a second, a command reaches exactly the UserId it is for, and messages can
-- carry real values (any duration, your own text).
--  hi    who you are: role and flags. q = true asks everyone to answer with theirs
--  cmd   a command for one beta user (t = their UserId) or all of them (t = 0)
--  ack   a beta copy ran command s
--  bye   the script was closed
-- Every copy says hi with q when it starts, so the ones already here answer.
-- Each copy has its own id (i) and only skips its own messages, so the dev and
-- beta scripts running on the same client find each other through the relay
-- too, which is how you test it alone: you show up on your own beta list.
-- A peer only counts while that player is in this server, commands are only
-- taken from a dev copy in this server, and the dev copy asks again every two
-- minutes to drop anyone whose script died without a bye. Without a WebSocket
-- it polls the topic every few seconds instead.
--
-- To use your own relay (Server/funky_friday_relay.py, run on your phone in
-- Termux) instead of the public ntfy.sh, fill in LINK_RELAY and LINK_SEED just
-- below with your tunnel URL and one shared seed phrase. The script works out
-- the key, the secret and every request's signature from the seed on its own,
-- so there is nothing to pass in before loadstring -- handy when you obfuscate
-- the script, which keeps the seed out of sight. Set the same seed on the
-- server (FF_SEED). With a seed set, every request is stamped, given a one-time
-- nonce and signed (HMAC-SHA256) so the relay tells your scripts from anyone
-- else and drops forged commands; it then polls (that relay has no WebSocket).
-- (getgenv().FunkyFridayRelay / .FunkyFridayRelaySeed / .FunkyFridayRelayKey /
-- .FunkyFridayRelaySecret still override the constants at load time if you want.)
-- Keep this block the same in both files.

local LINK_RELAY = "https://funkyff.serveousercontent.com"  -- your relay (Server/funky_friday_relay.py)
local LINK_SEED = ""          -- the same seed phrase the relay runs with (FF_SEED)
-- advanced: an exact key/secret instead of deriving them from the seed above
local LINK_RELAY_KEY = "4510b0b9d1028da6"
local LINK_RELAY_SECRET = "e612f27b3aa6a1c51a1f9db4cd833d70af4a296d9670c712630957599fdbdf9a"
local LINK_BETA, LINK_DEV = 1, 2
local LINK_FLAG_AUTO, LINK_FLAG_PLAYING = 1, 2
local LINK_POLL_EVERY = 6   -- seconds, when there's no WebSocket
local LINK_ASK_EVERY = 120  -- seconds, the dev copy's roll call
local LINK_TEXT_MAX = 120

-- index -> seconds, for the duration picker
local LINK_DURATIONS = { [0] = 1, 2, 3, 5, 8, 10, 15, 20, 30, 60 }
local LINK_MESSAGES = {
    [0] = "👀", "skill issue", "the dev is watching you", "you're not him", "nice miss lol",
    "bro is NOT locked in", "turn around", "L + ratio", "do better", "gg ez",
}
local LINK_COMMANDS = {
    AutoOff = 1, AutoOn = 2, Freeze = 3,
    MissStorm = 4, AllBad = 5, Shaky = 6,
    Shake = 7, Blur = 8, Rainbow = 9, FakeKick = 10,
    Jump = 11, Sit = 12, Message = 13,
    Unload = 14, Kick = 15,
    Bless = 16, CoinFlip = 17, OkOnly = 18,
    UpsideDown = 19, SpinCam = 20, Wobble = 21, Zoom = 22,
    BlackWhite = 23, DeepFry = 24, LightsOut = 25, Flash = 26,
    PopupSpam = 27, Confetti = 28,
    Mute = 29, Chipmunk = 30, DeepVoice = 31,
    Dance = 32,
}

local function linkRequestFunction()
    if typeof(request) == "function" then return request end
    if typeof(http_request) == "function" then return http_request end
    if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
    if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
    if typeof(fluxus) == "table" and typeof(fluxus.request) == "function" then return fluxus.request end
    return nil
end

local function linkSocketFunction()
    if typeof(WebSocket) == "table" then
        local connect = WebSocket.connect or WebSocket.Connect
        if typeof(connect) == "function" then return connect end
    end
    if typeof(syn) == "table" and typeof(syn.websocket) == "table" and typeof(syn.websocket.connect) == "function" then
        return syn.websocket.connect
    end
    return nil
end

-- SHA-256 + HMAC in pure Lua (bit32 is in Roblox), for signing relay requests.
-- Only used when you run your own relay with a secret; the public ntfy.sh
-- default sends nothing signed.
local LINK_SHA_K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function linkSha256(msg)
    local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
    local rshift, lshift, rrotate = bit32.rshift, bit32.lshift, bit32.rrotate
    local bor, K = bit32.bor, LINK_SHA_K
    local h0,h1,h2,h3 = 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a
    local h4,h5,h6,h7 = 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    local len = #msg
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    local bits = len * 8
    for i = 7, 0, -1 do msg = msg .. string.char(band(rshift(bits, i * 8), 0xff)) end
    for chunk = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local a,b,c,d = msg:byte(chunk + i*4, chunk + i*4 + 3)
            w[i] = bor(lshift(a,24), lshift(b,16), lshift(c,8), d)
        end
        for i = 16, 63 do
            local s0 = bxor(rrotate(w[i-15],7), rrotate(w[i-15],18), rshift(w[i-15],3))
            local s1 = bxor(rrotate(w[i-2],17), rrotate(w[i-2],19), rshift(w[i-2],10))
            w[i] = band(w[i-16] + s0 + w[i-7] + s1, 0xffffffff)
        end
        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 0, 63 do
            local S1 = bxor(rrotate(e,6), rrotate(e,11), rrotate(e,25))
            local ch = bxor(band(e,f), band(bnot(e),g))
            local t1 = band(h + S1 + ch + K[i+1] + w[i], 0xffffffff)
            local S0 = bxor(rrotate(a,2), rrotate(a,13), rrotate(a,22))
            local maj = bxor(band(a,b), band(a,c), band(b,c))
            local t2 = band(S0 + maj, 0xffffffff)
            h,g,f,e = g,f,e,band(d + t1, 0xffffffff)
            d,c,b,a = c,b,a,band(t1 + t2, 0xffffffff)
        end
        h0=band(h0+a,0xffffffff) h1=band(h1+b,0xffffffff) h2=band(h2+c,0xffffffff) h3=band(h3+d,0xffffffff)
        h4=band(h4+e,0xffffffff) h5=band(h5+f,0xffffffff) h6=band(h6+g,0xffffffff) h7=band(h7+h,0xffffffff)
    end
    return ("%08x%08x%08x%08x%08x%08x%08x%08x"):format(h0,h1,h2,h3,h4,h5,h6,h7)
end

local function linkHexBytes(s)
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function linkHmac(key, message)
    if #key > 64 then key = linkHexBytes(linkSha256(key)) end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local b = key:byte(i)
        ipad[i] = string.char(bit32.bxor(b, 0x36))
        opad[i] = string.char(bit32.bxor(b, 0x5c))
    end
    local inner = linkHexBytes(linkSha256(table.concat(ipad) .. message))
    return linkSha256(table.concat(opad) .. inner)
end

-- role: LINK_BETA or LINK_DEV. onCommand(cmd, seconds, text, fromPlayer) runs
-- on beta copies for every command aimed at them.
local function makeLink(role, onCommand)
    local link = { Role = role, Flags = 0, Seq = 0, Peers = {}, Stopped = false, Mode = "starting" }
    local httpRequest = linkRequestFunction()
    local socketConnect = linkSocketFunction()
    local relay = (tostring(Genv.FunkyFridayRelay or LINK_RELAY):gsub("/+$", ""))
    local jobId = (tostring(game.JobId):gsub("[^%w]", ""):lower())
    local topic = "madness-ff-" .. (jobId ~= "" and jobId or ("solo" .. LocalPlayer.UserId))
    local me = LocalPlayer.UserId
    local instance = HttpService:GenerateGUID(false)
    local seed = tostring(Genv.FunkyFridayRelaySeed or LINK_SEED)
    local relayKey = tostring(Genv.FunkyFridayRelayKey or LINK_RELAY_KEY)
    local relaySecret = tostring(Genv.FunkyFridayRelaySecret or LINK_RELAY_SECRET)
    -- a seed makes the key and secret on its own, so only the seed is set
    if seed ~= "" and relaySecret == "" then
        relayKey = linkSha256("FFKEY:" .. seed):sub(1, 16)
        relaySecret = linkSha256("FFSECRET:" .. seed)
    end
    local signed = relaySecret ~= ""
    -- where to pick up from: the last message we saw, or the relay's last few
    -- seconds (by its own clock) for the first look
    local lastId = nil
    local seen = {}
    local outbox = {}
    local lastHi = 0

    -- the headers for a request: just the content type on public ntfy.sh, plus
    -- a timestamp, a one-time nonce and an HMAC signature on your own relay
    local function authHeaders(body)
        local headers = { ["Content-Type"] = "text/plain" }
        if signed then
            local stamp = tostring(os.time())
            local nonce = HttpService:GenerateGUID(false)
            headers["X-FF-Key"] = relayKey
            headers["X-FF-Time"] = stamp
            headers["X-FF-Nonce"] = nonce
            headers["X-FF-Sign"] = linkHmac(relaySecret,
                table.concat({ relayKey, topic, stamp, nonce, body or "" }, "\n"))
        end
        return headers
    end

    local function post(message)
        message.v, message.f, message.i = 1, me, instance
        outbox[#outbox + 1] = HttpService:JSONEncode(message)
    end

    local function hello(ask)
        lastHi = os.clock()
        post({ k = "hi", r = role, fl = link.Flags, q = ask or nil })
    end

    local function handle(event)
        if type(event) ~= "table" or event.event ~= "message" or type(event.message) ~= "string" then return end
        if event.id then
            if seen[event.id] then return end
            seen[event.id] = true
            lastId = event.id
        end
        local ok, data = pcall(HttpService.JSONDecode, HttpService, event.message)
        if not ok or type(data) ~= "table" or data.v ~= 1 then return end
        local from = tonumber(data.f)
        if not from or data.i == instance then return end
        local player = Players:GetPlayerByUserId(from)
        if not player then return end

        local peer = link.Peers[player]
        if data.k == "hi" then
            if not peer then
                peer = { Player = player, Ack = 0 }
                link.Peers[player] = peer
            end
            peer.Role = tonumber(data.r)
            peer.Flags = tonumber(data.fl) or 0
            peer.Seen = os.clock()
            if data.q then hello(false) end
        elseif data.k == "bye" then
            link.Peers[player] = nil
        elseif data.k == "ack" then
            if peer then peer.Ack = tonumber(data.s) or peer.Ack end
        elseif data.k == "cmd" and role == LINK_BETA and onCommand then
            if not peer or peer.Role ~= LINK_DEV then return end
            local target = tonumber(data.t) or 0
            if target ~= 0 and target ~= me then return end
            post({ k = "ack", s = tonumber(data.s) or 0 })
            local text = type(data.x) == "string" and data.x:sub(1, LINK_TEXT_MAX) or ""
            task.spawn(pcall, onCommand, tonumber(data.c), tonumber(data.d), text, player)
        end
    end

    local function handleText(text)
        local ok, event = pcall(HttpService.JSONDecode, HttpService, text)
        if ok then handle(event) end
    end

    -- posts go out one at a time, in order. a busy relay (429) gets them again
    task.spawn(function()
        while httpRequest do
            if #outbox == 0 then
                if link.Stopped then break end
                task.wait(0.05)
            else
                local ok, response = pcall(httpRequest, {
                    Url = relay .. "/" .. topic,
                    Method = "POST",
                    Headers = authHeaders(outbox[1]),
                    Body = outbox[1],
                })
                if ok and type(response) == "table" and response.StatusCode == 429 and not link.Stopped then
                    task.wait(5)
                else
                    table.remove(outbox, 1)
                end
            end
        end
    end)

    local function since()
        return lastId or "10s"
    end

    local function poll()
        local ok, response = pcall(httpRequest, {
            Url = ("%s/%s/json?poll=1&since=%s"):format(relay, topic, since()),
            Method = "GET",
            Headers = authHeaders(""),
        })
        if not ok or type(response) ~= "table" or type(response.Body) ~= "string" then return false end
        for line in response.Body:gmatch("[^\n]+") do handleText(line) end
        return (response.StatusCode or 200) < 400
    end

    -- a WebSocket while one stays up, polling otherwise
    task.spawn(function()
        if not httpRequest then
            link.Mode = "off"
            return
        end
        hello(true)
        local socketWorks, hadSocket = socketConnect ~= nil and not signed, false
        while not link.Stopped do
            local socket
            if socketWorks then
                local url = ("%s/%s/ws?since=%s"):format(relay:gsub("^http", "ws"), topic, since())
                local ok, result = pcall(socketConnect, url)
                if ok and result then
                    socket, hadSocket = result, true
                elseif not hadSocket then
                    socketWorks = false -- never got one up, so don't keep trying
                end
            end
            if socket then
                link.Mode = "live"
                local closed = false
                local onMessage = socket.OnMessage:Connect(handleText)
                local onClose = socket.OnClose:Connect(function() closed = true end)
                while not closed and not link.Stopped do task.wait(0.25) end
                pcall(function() onMessage:Disconnect() end)
                pcall(function() onClose:Disconnect() end)
                pcall(function() socket:Close() end)
                if not link.Stopped then
                    link.Mode = "reconnecting"
                    task.wait(2)
                end
            else
                link.Mode = poll() and "polling" or "relay unreachable"
                task.wait(LINK_POLL_EVERY)
            end
        end
    end)

    -- flag changes, the dev copy's roll call, and players who left
    task.spawn(function()
        local sentFlags = link.Flags
        local nextAsk = os.clock() + LINK_ASK_EVERY
        local askedAt = nil
        while not link.Stopped do
            local now = os.clock()
            if link.Flags ~= sentFlags and now - lastHi >= 3 then
                sentFlags = link.Flags
                hello(false)
            end
            if role == LINK_DEV and now >= nextAsk then
                nextAsk = now + LINK_ASK_EVERY
                askedAt = now
                hello(true)
            end
            for player, peer in pairs(link.Peers) do
                local silent = askedAt and now - askedAt > 10 and peer.Seen < askedAt
                if not player.Parent or silent then link.Peers[player] = nil end
            end
            if askedAt and now - askedAt > 10 then askedAt = nil end
            task.wait(0.5)
        end
    end)

    -- sends a command to one beta player, or to every one with no target.
    -- returns its sequence number, which the target acks once it has run it
    function link.Send(cmd, seconds, text, target)
        link.Seq = link.Seq % 9999 + 1
        post({
            k = "cmd", c = cmd, d = seconds, s = link.Seq,
            x = text and tostring(text):sub(1, LINK_TEXT_MAX) or nil,
            t = target and target.UserId or 0,
        })
        return link.Seq
    end

    -- peers of a role, sorted by name
    function link.List(wanted)
        local list = {}
        for _, peer in pairs(link.Peers) do
            if not wanted or peer.Role == wanted then list[#list + 1] = peer end
        end
        table.sort(list, function(a, b) return a.Player.Name:lower() < b.Player.Name:lower() end)
        return list
    end

    function link.Status()
        local tag = signed and " (your relay, signed)" or ""
        if link.Mode == "off" then return "off: this executor has no request function" end
        if link.Mode == "live" then return "live over a WebSocket" .. tag end
        if link.Mode == "polling" then return ("on, checking every %ds"):format(LINK_POLL_EVERY) .. tag end
        return link.Mode .. "..." .. tag
    end

    -- says bye so the others drop us straight away, then stops
    function link.Stop()
        if link.Stopped then return end
        post({ k = "bye" })
        link.Stopped = true
    end

    return link
end

--// pranks --------------------------------------------------------------------
-- What a command does when it lands: on beta copies when the dev script sends
-- it, or on the dev copy itself when it targets "Me", to see it first. All of
-- it is on this client only, and all of it wears off. Keep this block the same
-- in Games/FunkyFriday.lua and Games/FunkyFridayBeta.lua.
--
-- hooks: SetAuto(state), Freeze(seconds), Chances(map, seconds), Unload()

local function makePranks(hooks)
    local RunService = game:GetService("RunService")
    local Lighting = game:GetService("Lighting")
    local pranks = { Stopped = false }
    local junk = {} -- guis, effects, connections and render binds, cleaned up on Stop
    local rng = Random.new()

    local function keep(thing)
        junk[#junk + 1] = thing
        return thing
    end

    -- for a while, then back
    local function lasting(seconds, onEnd)
        task.delay(seconds, function()
            if not pranks.Stopped then pcall(onEnd) end
        end)
    end

    local function screen()
        local gui = Instance.new("ScreenGui")
        gui.Name = "FFP_" .. HttpService:GenerateGUID(false):sub(1, 6)
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 1000
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        local ok, holder = pcall(function() return gethui and gethui() or game:GetService("CoreGui") end)
        gui.Parent = ok and holder or LocalPlayer:WaitForChild("PlayerGui")
        return keep(gui)
    end

    local function bigText(parent, text, position, size)
        local label = Instance.new("TextLabel")
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = position or UDim2.fromScale(0.5, 0.3)
        label.Size = size or UDim2.fromScale(0.8, 0.12)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBlack
        label.TextScaled = true
        label.TextColor3 = Color3.new(1, 1, 1)
        label.TextStrokeTransparency = 0
        label.Text = text
        label.Parent = parent
        return label
    end

    local function popup(text, seconds)
        local gui = screen()
        bigText(gui, text)
        lasting(seconds, function() gui:Destroy() end)
    end

    -- a full screen colour over everything
    local function cover(color, transparency)
        local gui = screen()
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundColor3 = color
        frame.BackgroundTransparency = transparency
        frame.BorderSizePixel = 0
        frame.Parent = gui
        return gui, frame
    end

    -- runs after the game's camera every frame, for a while
    local function cameraEffect(seconds, step)
        local name = "FFP_Cam_" .. HttpService:GenerateGUID(false):sub(1, 6)
        local started = os.clock()
        RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, function()
            local camera = workspace.CurrentCamera
            if camera then pcall(step, camera, os.clock() - started) end
        end)
        keep(name)
        lasting(seconds, function() RunService:UnbindFromRenderStep(name) end)
    end

    local function colorEffect(seconds, props, step)
        local color = Instance.new("ColorCorrectionEffect")
        for key, value in pairs(props) do color[key] = value end
        color.Parent = Lighting
        keep(color)
        local connection = step and keep(RunService.RenderStepped:Connect(function() step(color) end))
        lasting(seconds, function()
            if connection then connection:Disconnect() end
            color:Destroy()
        end)
    end

    local function playingSounds()
        local list = {}
        for _, root in ipairs({ workspace, game:GetService("SoundService"), LocalPlayer:FindFirstChildOfClass("PlayerGui") }) do
            for _, sound in ipairs(root and root:GetDescendants() or {}) do
                if sound:IsA("Sound") and sound.Playing then list[#list + 1] = sound end
            end
        end
        return list
    end

    local function pitch(seconds, octave)
        for _, sound in ipairs(playingSounds()) do
            local shift = Instance.new("PitchShiftSoundEffect")
            shift.Octave = octave
            shift.Parent = sound
            keep(shift)
            lasting(seconds, function() shift:Destroy() end)
        end
    end

    local function humanoid()
        local character = LocalPlayer.Character
        return character and character:FindFirstChildOfClass("Humanoid")
    end

    local function fakeKick(seconds)
        local gui, dim = cover(Color3.new(0, 0, 0), 0.35)
        dim.Active = true
        local box = Instance.new("Frame")
        box.AnchorPoint = Vector2.new(0.5, 0.5)
        box.Position = UDim2.fromScale(0.5, 0.5)
        box.Size = UDim2.fromOffset(400, 200)
        box.BackgroundColor3 = Color3.fromRGB(57, 59, 61)
        box.BorderSizePixel = 0
        box.Parent = dim
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
        local function text(content, y, height, size, bold)
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Position = UDim2.new(0, 20, 0, y)
            label.Size = UDim2.new(1, -40, 0, height)
            label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
            label.TextSize = size
            label.TextWrapped = true
            label.TextColor3 = Color3.new(1, 1, 1)
            label.Text = content
            label.Parent = box
            return label
        end
        text("Disconnected", 14, 30, 20, true)
        local body = text("You were kicked from this experience: skill issue\n(Error Code: 267)", 56, 80, 16, false)
        local button = Instance.new("TextLabel")
        button.AnchorPoint = Vector2.new(0.5, 1)
        button.Position = UDim2.new(0.5, 0, 1, -16)
        button.Size = UDim2.fromOffset(180, 36)
        button.BackgroundColor3 = Color3.new(1, 1, 1)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 16
        button.TextColor3 = Color3.fromRGB(57, 59, 61)
        button.Text = "Leave"
        button.Parent = box
        Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
        lasting(seconds, function()
            body.Text = "jk 😭"
            lasting(1.5, function() gui:Destroy() end)
        end)
    end

    local C = LINK_COMMANDS
    local RUN = {
        [C.AutoOff] = function() hooks.SetAuto(false) end,
        [C.AutoOn] = function() hooks.SetAuto(true) end,
        [C.Freeze] = function(seconds) hooks.Freeze(seconds) end,
        [C.MissStorm] = function(seconds) hooks.Chances({ Miss = 100 }, seconds) end,
        [C.AllBad] = function(seconds) hooks.Chances({ Bad = 100 }, seconds) end,
        [C.Shaky] = function(seconds) hooks.Chances({ Good = 30, Ok = 35, Bad = 25, Miss = 10 }, seconds) end,
        [C.Bless] = function(seconds) hooks.Chances({ Sick = 100 }, seconds) end,
        [C.CoinFlip] = function(seconds) hooks.Chances({ Sick = 50, Miss = 50 }, seconds) end,
        [C.OkOnly] = function(seconds) hooks.Chances({ Ok = 100 }, seconds) end,

        [C.Shake] = function(seconds)
            cameraEffect(seconds, function(camera)
                camera.CFrame *= CFrame.new(rng:NextNumber(-0.6, 0.6), rng:NextNumber(-0.6, 0.6), 0)
                    * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-3, 3)))
            end)
        end,
        [C.UpsideDown] = function(seconds)
            cameraEffect(seconds, function(camera) camera.CFrame *= CFrame.Angles(0, 0, math.pi) end)
        end,
        [C.SpinCam] = function(seconds)
            cameraEffect(seconds, function(camera, t) camera.CFrame *= CFrame.Angles(0, 0, t * math.pi) end)
        end,
        [C.Wobble] = function(seconds)
            cameraEffect(seconds, function(camera, t)
                camera.CFrame *= CFrame.new(math.sin(t * 1.7) * 0.8, math.sin(t * 2.3) * 0.4, 0)
                    * CFrame.Angles(0, 0, math.rad(math.sin(t * 1.3) * 12))
            end)
        end,
        [C.Zoom] = function(seconds)
            local camera = workspace.CurrentCamera
            local before = camera and camera.FieldOfView or 70
            cameraEffect(seconds, function(cam) cam.FieldOfView = 120 end)
            lasting(seconds + 0.05, function()
                if workspace.CurrentCamera then workspace.CurrentCamera.FieldOfView = before end
            end)
        end,

        [C.Blur] = function(seconds)
            local blur = Instance.new("BlurEffect")
            blur.Size = 24
            blur.Parent = Lighting
            keep(blur)
            lasting(seconds, function() blur:Destroy() end)
        end,
        [C.Rainbow] = function(seconds)
            colorEffect(seconds, { Saturation = 1 }, function(color)
                color.TintColor = Color3.fromHSV((os.clock() * 0.6) % 1, 0.6, 1)
            end)
        end,
        [C.BlackWhite] = function(seconds) colorEffect(seconds, { Saturation = -1 }) end,
        [C.DeepFry] = function(seconds)
            colorEffect(seconds, { Saturation = 2, Contrast = 1, TintColor = Color3.fromRGB(255, 190, 120) })
        end,
        [C.LightsOut] = function(seconds)
            local gui = cover(Color3.new(0, 0, 0), 0.08)
            lasting(seconds, function() gui:Destroy() end)
        end,
        [C.Flash] = function()
            local gui, frame = cover(Color3.new(1, 1, 1), 0)
            local started = os.clock()
            local connection
            connection = keep(RunService.RenderStepped:Connect(function()
                local t = os.clock() - started
                frame.BackgroundTransparency = math.clamp((t - 0.4) / 1.6, 0, 1)
                if t > 2 then
                    connection:Disconnect()
                    gui:Destroy()
                end
            end))
        end,

        [C.FakeKick] = fakeKick,
        [C.Message] = function(_, text) popup(text ~= "" and text or "👀", 3) end,
        [C.PopupSpam] = function(seconds)
            local gui = screen()
            local ends = os.clock() + seconds
            task.spawn(function()
                while os.clock() < ends and not pranks.Stopped and gui.Parent do
                    local label = bigText(gui, LINK_MESSAGES[rng:NextInteger(0, 9)],
                        UDim2.fromScale(rng:NextNumber(0.15, 0.85), rng:NextNumber(0.15, 0.85)),
                        UDim2.fromScale(0.35, 0.07))
                    label.Rotation = rng:NextNumber(-20, 20)
                    label.TextColor3 = Color3.fromHSV(rng:NextNumber(), 0.7, 1)
                    task.delay(1.2, function() label:Destroy() end)
                    task.wait(0.25)
                end
                gui:Destroy()
            end)
        end,
        [C.Confetti] = function(seconds)
            local gui = screen()
            local pieces = { "🎉", "✨", "🎵", "⭐", "💜", "🎶" }
            local falling = {}
            local ends = os.clock() + seconds
            local nextDrop = 0
            local connection
            connection = keep(RunService.RenderStepped:Connect(function(dt)
                local now = os.clock()
                if now < ends and now >= nextDrop then
                    nextDrop = now + 0.05
                    local label = bigText(gui, pieces[rng:NextInteger(1, #pieces)],
                        UDim2.fromScale(rng:NextNumber(0, 1), -0.05), UDim2.fromOffset(36, 36))
                    falling[label] = rng:NextNumber(0.25, 0.5)
                end
                for label, speed in pairs(falling) do
                    label.Position += UDim2.fromScale(0, speed * dt)
                    label.Rotation += 90 * dt
                    if label.Position.Y.Scale > 1.1 then
                        falling[label] = nil
                        label:Destroy()
                    end
                end
                if now >= ends and next(falling) == nil then
                    connection:Disconnect()
                    gui:Destroy()
                end
            end))
        end,

        [C.Mute] = function(seconds)
            local muted = {}
            for _, sound in ipairs(playingSounds()) do
                muted[sound] = sound.Volume
                sound.Volume = 0
            end
            lasting(seconds, function()
                for sound, volume in pairs(muted) do pcall(function() sound.Volume = volume end) end
            end)
        end,
        [C.Chipmunk] = function(seconds) pitch(seconds, 1.6) end,
        [C.DeepVoice] = function(seconds) pitch(seconds, 0.6) end,

        [C.Jump] = function()
            local h = humanoid()
            if h then
                h.Jump = true
                pcall(h.ChangeState, h, Enum.HumanoidStateType.Jumping)
            end
        end,
        [C.Sit] = function()
            local h = humanoid()
            if h then h.Sit = true end
        end,
        [C.Dance] = function(seconds)
            local h = humanoid()
            local animator = h and h:FindFirstChildOfClass("Animator")
            if not animator then return end
            local animation = Instance.new("Animation")
            animation.AnimationId = "rbxassetid://507771019" -- Roblox's own dance emote
            local track = animator:LoadAnimation(animation)
            track.Priority = Enum.AnimationPriority.Action
            track.Looped = true
            track:Play()
            keep(track)
            lasting(seconds, function() track:Stop() end)
        end,

        [C.Unload] = function() hooks.Unload() end,
        [C.Kick] = function() LocalPlayer:Kick("the dev kicked you lol") end,
    }

    -- seconds for the commands that last a while, text for Message
    function pranks.Run(cmd, seconds, text)
        if pranks.Stopped then return end
        local fn = RUN[cmd]
        if fn then task.spawn(pcall, fn, math.clamp(tonumber(seconds) or 5, 0.5, 120), tostring(text or "")) end
    end

    function pranks.Stop()
        pranks.Stopped = true
        for _, thing in ipairs(junk) do
            pcall(function()
                if type(thing) == "string" then
                    RunService:UnbindFromRenderStep(thing)
                elseif typeof(thing) == "RBXScriptConnection" then
                    thing:Disconnect()
                elseif typeof(thing) == "Instance" and thing:IsA("AnimationTrack") then
                    thing:Stop()
                else
                    thing:Destroy()
                end
            end)
        end
        table.clear(junk)
    end

    return pranks
end

local Unloaded = false
local Window, AutoToggle -- the menu, made below
local Link

local Pranks = makePranks({
    SetAuto = function(state)
        Auto.Enabled = state
        if state then startWorkers() end
        pushSettings()
        if AutoToggle then pcall(function() AutoToggle:Set(state) end) end
    end,
    Freeze = function(seconds)
        Prank.FrozenUntil = os.clock() + seconds
        pushSettings()
        task.delay(seconds + 0.05, pushSettings)
    end,
    Chances = function(map, seconds)
        Prank.Chance = map
        Prank.ChanceUntil = os.clock() + seconds
        pushSettings()
        task.delay(seconds + 0.05, pushSettings)
    end,
    Unload = function()
        if Genv.__FunkyFridayBetaStop then Genv.__FunkyFridayBetaStop() end
    end,
})

local function shutdown()
    if Unloaded then return end
    Unloaded = true
    Auto.Enabled = false
    pcall(function() Bridge:SetAttribute("Enabled", false) end)
    pcall(function() Bridge:SetAttribute("Stop", true) end)
    -- the workers see Stop on their next frame, let go of any held lane, and quit
    task.delay(0.5, function() pcall(function() Bridge:Destroy() end) end)
    if Link then Link.Stop() end
    Pranks.Stop()
    -- the old menu goes too: a second load used to leave it up, and its auto
    -- play toggle then pointed at a bridge that was gone, so it did nothing
    if Window then pcall(function() Window:Destroy() end) end
    if Genv.__FunkyFridayBetaStop == shutdown then Genv.__FunkyFridayBetaStop = nil end
end
Genv.__FunkyFridayBetaStop = shutdown

Link = makeLink(LINK_BETA, function(cmd, seconds, text)
    if not Unloaded then Pranks.Run(cmd, seconds, text) end
end)

-- the link tells the dev script whether auto play is on and in a song
task.spawn(function()
    while not Unloaded do
        local flags = 0
        if Auto.Enabled then flags += LINK_FLAG_AUTO end
        if Bridge:GetAttribute("Status") == "playing" and Bridge:GetAttribute("Enabled") then flags += LINK_FLAG_PLAYING end
        Link.Flags = flags
        -- the actor may turn up after the script ran, so keep trying it
        if Auto.Enabled and not Bridge:GetAttribute("Owner") then startWorkers() end
        task.wait(1)
    end
end)

--// ui ------------------------------------------------------------------------

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
if Unloaded then return end -- loaded again while this one was still fetching the menu

Window = WindUI:CreateWindow({
    Title = "Funky Friday",
    Author = "beta",
    Icon = "music",
    Folder = "FunkyFridayBeta",
    Size = UDim2.fromOffset(480, 300),
})

local Tab = Window:Tab({ Title = "Main", Icon = "music" })

AutoToggle = Tab:Toggle({
    Title = "Auto play",
    Desc = "Hits the notes by the chances below",
    Value = false,
    Callback = function(state)
        if Unloaded then return end
        Auto.Enabled = state == true
        if Auto.Enabled then startWorkers() end
        pushSettings()
        if state and not canPlay then
            WindUI:Notify({
                Title = "Funky Friday",
                Content = "Your executor needs getgc or run_on_actor for auto play.",
                Duration = 6,
            })
        end
    end,
})

local statusText = Tab:Paragraph({ Title = "Status", Desc = "off" })
task.spawn(function()
    local last
    while not Unloaded do
        local text
        if not Auto.Enabled then
            text = "off"
        elseif os.clock() < Prank.FrozenUntil then
            text = "frozen for a moment..."
        elseif not Bridge:GetAttribute("Where") then
            text = (Workers.Here or Workers.Actor) and "looking for the game..." or "waiting for the game's actor..."
        else
            text = tostring(Bridge:GetAttribute("Status") or "waiting for a song")
        end
        if text ~= last then
            last = text
            pcall(function() statusText:SetDesc(text) end)
        end
        task.wait(0.5)
    end
end)

local Judge = Window:Tab({ Title = "Judgements", Icon = "dices" })

local share = Judge:Paragraph({
    Title = "How often each judgement comes out",
    Desc = "",
})

-- the chances work as weights, so this shows what they come to
local function showShare()
    local total = 0
    for _, name in ipairs(GRADE_ORDER) do total += math.max(Auto.Chance[name] or 0, 0) end
    local parts = {}
    for _, name in ipairs(GRADE_ORDER) do
        local pct = total > 0 and (math.max(Auto.Chance[name] or 0, 0) / total * 100) or (name == "Sick" and 100 or 0)
        if pct > 0 then parts[#parts + 1] = ("%s %.0f%%"):format(name, pct) end
    end
    local text = Auto.Perfect and "Perfect: every hit 0.00ms" or ("Weights, they don't have to add up to 100. Now: " .. table.concat(parts, ", "))
    pcall(function() share:SetDesc(text) end)
end

Judge:Toggle({
    Title = "Perfect hits (0.00ms)",
    Desc = "Every note dead on its time, over the chances below",
    Value = Auto.Perfect,
    Callback = function(state)
        Auto.Perfect = state == true
        pushSettings()
        showShare()
    end,
})

for _, name in ipairs(GRADE_ORDER) do
    Judge:Slider({
        Title = name .. " %",
        Step = 1,
        Value = { Min = 0, Max = 100, Default = Auto.Chance[name] },
        Callback = function(value)
            Auto.Chance[name] = tonumber(value) or 0
            pushSettings()
            showShare()
        end,
    })
end
showShare()

local Hold = Window:Tab({ Title = "Key hold", Icon = "hand" })

Hold:Paragraph({
    Title = "Key hold after a hit",
    Desc = "How long the key stays down after hitting a normal note. It always lets go before the next note in the same lane, so fast streams still work. Hold notes are always held for their full length.",
})

Hold:Toggle({
    Title = "Hold the key",
    Desc = "Off lets go straight away",
    Value = Auto.PressHold,
    Callback = function(state)
        Auto.PressHold = state == true
        pushSettings()
    end,
})

Hold:Slider({
    Title = "Hold for (ms)",
    Step = 1,
    Value = { Min = 1, Max = 300, Default = Auto.PressHoldMs },
    Callback = function(value)
        Auto.PressHoldMs = tonumber(value) or Auto.PressHoldMs
        pushSettings()
    end,
})

Hold:Toggle({
    Title = "Randomize",
    Desc = "Each hit holds a different length, within the range below",
    Value = Auto.PressRandom,
    Callback = function(state)
        Auto.PressRandom = state == true
        pushSettings()
    end,
})

Hold:Slider({
    Title = "Random range (%)",
    Desc = "60ms with a 50% range holds each hit between 30ms and 90ms",
    Step = 1,
    Value = { Min = 0, Max = 100, Default = Auto.PressRandomRange },
    Callback = function(value)
        Auto.PressRandomRange = tonumber(value) or Auto.PressRandomRange
        pushSettings()
    end,
})

pcall(function() Window:OnDestroy(shutdown) end)

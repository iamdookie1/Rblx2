--// Word game (PlaceId 91704854174760) ---------------------------------------------
-- Turn-based word game: sit at a two-seat table, the server hands you a prompt
-- with a locked prefix, you type a word that starts with it and press Enter.
--
-- The whole protocol rides one RemoteFunction. ReplicatedStorage.Services.
-- Communication.event exposes remoteFire(name, ...) -> InvokeServer(name, ...),
-- and inbound server messages dispatch by string name to remoteConnect handlers.
-- machine.setup() leaves _G.import as a real global, so we get the game's own
-- live event bus rather than hooking anything - our handlers register alongside
-- its handlers on the same table.
--
--   -> server   keyStroke(char)      one letter, or -1 for backspace
--   -> server   tryAnswer()          submit what has been typed
--   -> server   steal(userId)        take a seat
--   -> server   purchaseTimeBoost()  +7s, the server caps it at 2 per round
--   -> server   teleport("Afk")      hop to an AFK reward server
--   <- client   updateRound(prompt, table, turnPlayer, time, _, strikes, notes)
--   <- client   updateTyping(word)   whoever is typing, live, letter by letter
--   <- client   correct(word, ...)   the answer the server just accepted
--
-- The word bank itself is server side - the ability that builds hints reaches
-- for _G.import("bank"), which resolves nowhere on the client - so nothing here
-- reads the answers. Two inbound messages hand them over anyway: `correct`
-- broadcasts every accepted word, and `updateRound` says which prompt it
-- satisfied, so the learned bank below grows from rounds we merely watch.
--
-- One thing the prompt does not say out loud: RequiredLetter is already typed
-- for you. The client starts the round with its character counter set to the
-- prefix length and the input locked there, so answering "apple" to a prefix of
-- "AP" means sending P, L, E - sending the whole word doubles the prefix and
-- earns a strike.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local function resolveEvent(modern, legacy)
    local ok, ev = pcall(function() return RunService[modern] end)
    if ok and ev then return ev end
    return RunService[legacy]
end
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

local Connections = {}
local BusHandles = {}
local Unloading = false
local function track(c) Connections[#Connections + 1] = c return c end

--// Config ------------------------------------------------------------------------
local Config = {
    AutoType = false,
    SuggestOnly = false,

    -- Every delay below is a span, not a point. A fixed gap between keystrokes
    -- is the single most obvious thing about a typing bot.
    StartDelay = { Min = 0.35, Max = 1.20 },   -- before the first letter
    LetterDelay = { Min = 0.06, Max = 0.16 },  -- between letters
    SubmitDelay = { Min = 0.08, Max = 0.30 },  -- after the last letter

    Randomizer = false,
    RandomAmount = { Min = 0.10, Max = 0.60 },
    RandomChance = 25,

    PanicOnly = false,
    PanicAt = 4,

    Pick = "common",
    WordLength = { Min = 4, Max = 9 },
    AvoidUsed = true,
    Learn = true,

    AutoTimeBoost = false,
    TimeBoostAt = 3,
    AutoSteal = false,
    StealRange = 24,
    AutoSit = false,

    ChairEsp = false,
    PlayerEsp = false,
    EspNames = true,

    WalkSpeed = 16,
    JumpPower = 50,
    InfiniteJump = false,
}

local Stats = {
    Bus = "not connected",
    Dictionary = 0,
    Common = 0,
    Learned = 0,
    Status = "idle",
    Round = "no round",
    Prefix = "",
    Question = "",
    Turn = "-",
    Timer = 0,
    Strikes = 0,
    Typed = 0,
    Answered = 0,
    Missed = 0,
    LastWord = "-",
    LastDelay = 0,
    OpponentTyping = "",
    Candidates = 0,
    Suggestion = "-",
}

--// Game bridge -------------------------------------------------------------------
-- _G.import is set by machine.setup on the client, so it is simply there. The
-- direct require is the fallback for a load that beat the bootstrap.
local Bus
do
    local ok, mod = pcall(function()
        if typeof(_G.import) == "function" then
            return _G.import("event")
        end
        return nil
    end)
    if ok and typeof(mod) == "table" and mod.remoteFire then
        Bus = mod
        Stats.Bus = "via _G.import"
    end
    if not Bus then
        local ok2, mod2 = pcall(function()
            local services = ReplicatedStorage:WaitForChild("Services", 10)
            local comm = services and services:WaitForChild("Communication", 10)
            local ev = comm and comm:WaitForChild("event", 10)
            return ev and require(ev)
        end)
        if ok2 and typeof(mod2) == "table" and mod2.remoteFire then
            Bus = mod2
            Stats.Bus = "via require"
        end
    end
    if not Bus then
        Stats.Bus = "NOT FOUND - wrong game?"
    end
end

local function busConnect(name, fn)
    if not Bus then return end
    local ok, handle = pcall(Bus.remoteConnect, name, function(...)
        if Unloading then return end
        local fine, err = pcall(fn, ...)
        if not fine then
            warn("[wordgame] " .. name .. " handler: " .. tostring(err))
        end
    end)
    if ok and handle then
        BusHandles[#BusHandles + 1] = handle
    end
end

local function busFire(name, ...)
    if not Bus then return end
    pcall(Bus.fire, name, ...)
end

local function busRemote(name, ...)
    if not Bus then return nil end
    local ok, a, b = pcall(Bus.remoteFire, name, ...)
    if ok then return a, b end
    return nil
end

--// Word storage ------------------------------------------------------------------
local RAW_BASE = "https://raw.githubusercontent.com/iamdookie1/Rblx2/main/Data/"
local FOLDER = "CentrlWordGame"
local BANK_FILE = FOLDER .. "/WordBank.txt"
local COMMON_FILE = FOLDER .. "/WordCommon.txt"
local LEARNED_FILE = FOLDER .. "/learned.json"

local HAS_FILES = typeof(readfile) == "function"
    and typeof(writefile) == "function"
    and typeof(isfile) == "function"

local Dictionary = {}     -- sorted array, so a prefix is one binary search away
local CommonSet = {}      -- [word] = true
local Learned = {}        -- [promptKey] = { [word] = true }
local LearnedAll = {}     -- [word] = true, every word the server ever accepted
local learnedDirty = false

local function ensureFolder()
    if not HAS_FILES or typeof(isfolder) ~= "function" then return false end
    if not isfolder(FOLDER) then
        local ok = pcall(makefolder, FOLDER)
        if not ok then return false end
    end
    return true
end

-- Fetching 3.4MB and splitting 350k words would hitch the frame badly in one
-- go, so the split yields whenever it has held the thread for too long. The
-- text is cached to disk on first fetch; later loads never touch the network.
local function fetchText(url, cachePath)
    if HAS_FILES and cachePath and isfile(cachePath) then
        local ok, body = pcall(readfile, cachePath)
        if ok and body and #body > 0 then
            return body, "cache"
        end
    end
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if not ok or not body or #body == 0 then
        return nil, tostring(body)
    end
    if HAS_FILES and cachePath and ensureFolder() then
        pcall(writefile, cachePath, body)
    end
    return body, "network"
end

local function splitLines(text, into, asSet)
    local budget = os.clock()
    local count = 0
    for line in string.gmatch(text, "[^\r\n]+") do
        if asSet then
            into[line] = true
        else
            into[#into + 1] = line
        end
        count = count + 1
        if count % 4096 == 0 and os.clock() - budget > 1 / 90 then
            task.wait()
            budget = os.clock()
        end
    end
    return count
end

local function saveLearned()
    if not HAS_FILES or not learnedDirty or not ensureFolder() then return end
    local flat = {}
    for key, words in pairs(Learned) do
        local list = {}
        for word in pairs(words) do
            list[#list + 1] = word
        end
        if #list > 0 then
            flat[key] = list
        end
    end
    local ok, encoded = pcall(HttpService.JSONEncode, HttpService, flat)
    if ok then
        pcall(writefile, LEARNED_FILE, encoded)
        learnedDirty = false
    end
end

local function loadLearned()
    if not HAS_FILES or not isfile(LEARNED_FILE) then return end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(LEARNED_FILE))
    end)
    if not ok or typeof(decoded) ~= "table" then return end
    local total = 0
    for key, list in pairs(decoded) do
        local set = Learned[key] or {}
        for _, word in ipairs(list) do
            if not set[word] then
                set[word] = true
                total = total + 1
            end
            LearnedAll[word] = true
        end
        Learned[key] = set
    end
    Stats.Learned = total
end

local function loadWords()
    task.spawn(function()
        Stats.Status = "loading dictionary..."
        local body, source = fetchText(RAW_BASE .. "WordBank.txt", BANK_FILE)
        if body then
            Stats.Dictionary = splitLines(body, Dictionary, false)
            Stats.Status = ("dictionary %d words (%s)"):format(Stats.Dictionary, source)
        else
            Stats.Status = "dictionary failed: " .. tostring(source)
        end
        local common = fetchText(RAW_BASE .. "WordCommon.txt", COMMON_FILE)
        if common then
            Stats.Common = splitLines(common, CommonSet, true)
        end
        loadLearned()
        Stats.Status = "ready"
    end)
end

--// Word lookup -------------------------------------------------------------------
-- The bank file ships sorted, so the words sharing a prefix are one contiguous
-- run and the search is a lower bound plus a walk, not a scan of 350k strings.
local function lowerBound(prefix)
    local lo, hi = 1, #Dictionary + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if Dictionary[mid] < prefix then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

local UsedThisMatch = {}

-- Scoring is tiered rather than blended, so a tier never loses to length: a
-- word the server has already accepted beats any dictionary word, a common word
-- beats any obscure one, and the mode only decides the order inside a tier.
local VERIFIED_BONUS = 100000
local COMMON_BONUS = 5000

local function modeScore(word, mode)
    local length = #word
    if mode == "shortest" then
        return (40 - length) * 10
    elseif mode == "longest" then
        return length * 10
    end
    return (40 - length) * 3
end

-- One pass, whole prefix run, running best. The earlier version collected the
-- first 600 matches and ranked those, which sounds harmless until you notice
-- the run is alphabetical: a prefix of "a" filled its 600 slots somewhere
-- inside "ab-" and answered "abc", having never seen "air" or "about". Scanning
-- the entire run costs about 2ms even for "s", which is 36,587 words, and it
-- happens once per turn.
local function chooseWord(prefix)
    if prefix == "" then return nil, 0 end
    local plen = #prefix
    local mode = Config.Pick
    local lo = math.floor(Config.WordLength.Min)
    local hi = math.floor(Config.WordLength.Max)

    local bestWord, bestScore, ties = nil, -math.huge, 0
    local anyWord, anyScore, anyTies = nil, -math.huge, 0
    local pool, seen = 0, {}

    local function offer(word, verified)
        if seen[word] then return end
        seen[word] = true
        if #word <= plen then return end
        if Config.AvoidUsed and UsedThisMatch[word] then return end
        pool = pool + 1

        if mode == "random" then
            -- Reservoir pick: one uniformly random match without ever holding
            -- the list of matches in memory.
            if math.random(1, pool) == 1 then
                anyWord = word
            end
            local length = #word
            if length >= lo and length <= hi then
                ties = ties + 1
                if math.random(1, ties) == 1 then
                    bestWord = word
                end
            end
            return
        end

        local score = modeScore(word, mode)
        if verified then score = score + VERIFIED_BONUS end
        if CommonSet[word] then score = score + COMMON_BONUS end

        if score > anyScore then
            anyWord, anyScore, anyTies = word, score, 1
        elseif score == anyScore then
            anyTies = anyTies + 1
            if math.random(1, anyTies) == 1 then anyWord = word end
        end

        local length = #word
        if length >= lo and length <= hi then
            if score > bestScore then
                bestWord, bestScore, ties = word, score, 1
            elseif score == bestScore then
                ties = ties + 1
                if math.random(1, ties) == 1 then bestWord = word end
            end
        end
    end

    -- Learned words first. A word only proves itself for the prompt it was
    -- accepted under, so the key-specific set is offered before the global one,
    -- but both outrank the dictionary either way.
    local key = Stats.PromptKey
    if key and Learned[key] then
        for word in pairs(Learned[key]) do
            if string.sub(word, 1, plen) == prefix then offer(word, true) end
        end
    end
    for word in pairs(LearnedAll) do
        if string.sub(word, 1, plen) == prefix then offer(word, true) end
    end

    local index = lowerBound(prefix)
    while index <= #Dictionary do
        local word = Dictionary[index]
        if string.sub(word, 1, plen) ~= prefix then break end
        offer(word, false)
        index = index + 1
    end

    -- The length band is a preference, not a rule: a word outside it beats no
    -- word at all when the prefix is a rare one.
    return bestWord or anyWord, pool
end

--// Round state -------------------------------------------------------------------
local Round = {
    token = 0,
    active = false,
    prefix = "",
    label = "",
    choices = nil,
    isTurn = false,
    time = 0,
    startedAt = 0,
}

-- The prompt label carries the prefix inside it, so stripping the prefix and
-- everything that is not a letter leaves a stable per-category key: two rounds
-- of the same category collapse to the same key whatever letters they asked for.
local function promptKey(label, prefix)
    local text = tostring(label or "")
    if prefix and prefix ~= "" then
        -- Escaped because a prefix goes straight into a pattern, and the game
        -- is free to hand out one containing a punctuation key.
        local escaped = string.gsub(prefix, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        text = string.gsub(text, escaped, " ")
        text = string.gsub(text, string.lower(escaped), " ")
    end
    text = string.lower(text)
    text = string.gsub(text, "<[^>]*>", " ")
    text = string.gsub(text, "[^a-z]+", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then text = "default" end
    return text
end

local function remaining()
    if not Round.active or Round.time <= 0 then return 0 end
    return math.max(0, Round.time - (os.clock() - Round.startedAt))
end

--// Delays ------------------------------------------------------------------------
-- "Different from the last one" is the whole point of the letter delay, so it
-- is enforced rather than left to chance: a redraw has to land at least a
-- fraction of the span away from the previous value. A span too narrow for
-- that to ever succeed falls back to reflecting across the midpoint, which
-- still guarantees a different number instead of silently giving up.
local SEPARATION = 0.15

local function nextDelay(range, last)
    local lo = math.min(range.Min, range.Max)
    local hi = math.max(range.Min, range.Max)
    if hi <= lo then
        return lo
    end
    local span = hi - lo
    local gap = span * SEPARATION
    for _ = 1, 12 do
        local value = lo + math.random() * span
        if not last or math.abs(value - last) >= gap then
            return value
        end
    end
    local mid = (lo + hi) / 2
    local reflected = math.clamp(mid + (mid - (last or mid)), lo, hi)
    if last and math.abs(reflected - last) < 1e-4 then
        reflected = (reflected <= mid) and hi or lo
    end
    return reflected
end

local lastLetterDelay = nil
local lastStartDelay = nil

local function withRandomizer(base)
    if not Config.Randomizer then return base end
    if math.random(1, 100) > math.max(1, math.floor(Config.RandomChance)) then
        return base
    end
    return base + nextDelay(Config.RandomAmount, nil)
end

--// Typing ----------------------------------------------------------------------
local typing = false

-- Two calls, exactly what the game's own key handler does: the local fire feeds
-- the on-screen letter boxes so your word appears as it is typed, the remote is
-- the half the server actually reads. Going through the game's tryKeystroke
-- wrapper instead would look tidier, but it silently does nothing when that
-- handler is not connected and there is no way to tell from here - this pair
-- always lands.
local function sendChar(char)
    busFire("keyStroke", char)
    busRemote("keyStroke", char)
end

-- Submitted straight down the wire rather than through the local tryAnswer,
-- which gates on a typed-character counter this script never touches.
local function submitAnswer()
    busRemote("tryAnswer")
end

local function abortedSince(token)
    return Unloading or Round.token ~= token or not Config.AutoType
end

local function typeWord(word, token)
    typing = true
    Stats.Status = "typing " .. word

    local rest = string.sub(word, #Round.prefix + 1)
    if rest == "" then
        typing = false
        return
    end

    local start = withRandomizer(nextDelay(Config.StartDelay, lastStartDelay))
    lastStartDelay = start
    Stats.LastDelay = start
    task.wait(start)
    if abortedSince(token) or not Round.isTurn then
        typing = false
        Stats.Status = "aborted"
        return
    end

    for index = 1, #rest do
        if abortedSince(token) then
            typing = false
            Stats.Status = "aborted mid-word"
            return
        end
        sendChar(string.upper(string.sub(rest, index, index)))
        Stats.Typed = Stats.Typed + 1
        if index < #rest then
            local gap = withRandomizer(nextDelay(Config.LetterDelay, lastLetterDelay))
            lastLetterDelay = gap
            Stats.LastDelay = gap
            task.wait(gap)
        end
    end

    if abortedSince(token) then
        typing = false
        return
    end
    task.wait(withRandomizer(nextDelay(Config.SubmitDelay, nil)))
    if abortedSince(token) then
        typing = false
        return
    end
    submitAnswer()
    UsedThisMatch[word] = true
    Stats.LastWord = word
    Stats.Status = "submitted " .. word
    typing = false
end

local function solveRound()
    if not Round.active or not Round.isTurn then return end
    if Round.choices then return end
    if Round.prefix == "" then return end
    if typing then return end
    if not Config.AutoType and not Config.SuggestOnly then return end

    local word, count = chooseWord(string.lower(Round.prefix))
    Stats.Candidates = count
    Stats.Suggestion = word or "none found"
    if not word then
        Stats.Status = "no word for '" .. Round.prefix .. "'"
        Stats.Missed = Stats.Missed + 1
        return
    end

    if Config.SuggestOnly or not Config.AutoType then
        Stats.Status = "suggest: " .. word
        return
    end

    local token = Round.token
    task.spawn(function()
        typeWord(word, token)
    end)
end

--// Bus handlers ------------------------------------------------------------------
busConnect("updateRound", function(prompt, _, turnPlayer, time, _, strikes)
    Round.token = Round.token + 1
    Round.active = true
    Round.startedAt = os.clock()
    Round.time = tonumber(time) or 0
    Round.isTurn = (turnPlayer == LocalPlayer)
    Stats.Strikes = tonumber(strikes) or 0
    Stats.OpponentTyping = ""

    if typeof(prompt) == "table" then
        Round.prefix = tostring(prompt.RequiredLetter or "")
        Round.label = tostring(prompt.QuestionLabel or "")
        Round.choices = prompt.Choices
    else
        Round.prefix, Round.label, Round.choices = "", "", nil
    end

    Stats.PromptKey = promptKey(Round.label, Round.prefix)
    Stats.Prefix = Round.prefix
    Stats.Question = Round.label ~= "" and Round.label or "(no label)"
    Stats.Turn = Round.isTurn and "you" or (turnPlayer and tostring(turnPlayer.Name) or "-")
    Stats.Round = Round.choices and "choice round" or ("prefix '" .. Round.prefix .. "'")

    if Round.isTurn and not Config.PanicOnly then
        solveRound()
    end
end)

busConnect("correct", function(word)
    if typeof(word) ~= "string" or word == "" then return end
    local clean = string.lower(string.gsub(word, "[^%a]", ""))
    if clean == "" then return end
    UsedThisMatch[clean] = true
    Stats.LastWord = clean
    if Round.isTurn then
        Stats.Answered = Stats.Answered + 1
    end
    if not Config.Learn then return end
    local key = Stats.PromptKey or "default"
    local set = Learned[key]
    if not set then
        set = {}
        Learned[key] = set
    end
    if not set[clean] then
        set[clean] = true
        Stats.Learned = Stats.Learned + 1
        learnedDirty = true
    end
    LearnedAll[clean] = true
end)

busConnect("updateTyping", function(word)
    if typeof(word) == "string" then
        Stats.OpponentTyping = word
    end
end)

busConnect("takeDamage", function(userId)
    if userId == LocalPlayer.UserId then
        Stats.Missed = Stats.Missed + 1
    end
end)

busConnect("endGame", function()
    Round.active = false
    Round.isTurn = false
    Round.prefix = ""
    Round.choices = nil
    Stats.Round = "no round"
    Stats.Turn = "-"
    UsedThisMatch = {}
    saveLearned()
end)

--// Panic mode + auto time boost --------------------------------------------------
local lastBoost = 0
track(PostSimulation:Connect(function()
    if Unloading or not Round.active then return end
    local left = remaining()
    Stats.Timer = left

    if Round.isTurn and Config.PanicOnly and Config.AutoType and not typing then
        if left > 0 and left <= Config.PanicAt then
            solveRound()
        end
    end

    if Round.isTurn and Config.AutoTimeBoost and left > 0 and left <= Config.TimeBoostAt then
        if os.clock() - lastBoost > 1.5 then
            lastBoost = os.clock()
            busRemote("purchaseTimeBoost")
        end
    end
end))

--// Seats -------------------------------------------------------------------------
local function tablesFolder()
    local meta = Workspace:FindFirstChild("Meta")
    return meta and meta:FindFirstChild("Tables") or nil
end

local function allSeats()
    local out = {}
    local folder = tablesFolder()
    if not folder then return out end
    for _, tbl in ipairs(folder:GetChildren()) do
        local chairs = tbl:FindFirstChild("Chairs")
        if chairs then
            for _, seat in ipairs(chairs:GetChildren()) do
                if seat:IsA("Seat") then
                    out[#out + 1] = seat
                end
            end
        end
    end
    return out
end

local function rootPart()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function nearestFreeSeat()
    local root = rootPart()
    if not root then return nil end
    local best, bestDistance = nil, math.huge
    for _, seat in ipairs(allSeats()) do
        if not seat.Occupant then
            local distance = (seat.Position - root.Position).Magnitude
            if distance < bestDistance then
                best, bestDistance = seat, distance
            end
        end
    end
    return best
end

local sitCooldown = 0
task.spawn(function()
    while not Unloading do
        task.wait(0.5)
        if Config.AutoSit and not LocalPlayer:GetAttribute("InGame") then
            local root = rootPart()
            local seat = root and nearestFreeSeat()
            if seat and os.clock() - sitCooldown > 2 then
                sitCooldown = os.clock()
                pcall(function()
                    root.CFrame = seat.CFrame + Vector3.new(0, 3, 0)
                end)
            end
        end
    end
end)

--// Auto steal --------------------------------------------------------------------
local stealCooldown = 0
task.spawn(function()
    while not Unloading do
        task.wait(0.4)
        if Config.AutoSteal and not LocalPlayer:GetAttribute("InGame") then
            local root = rootPart()
            if root and os.clock() - stealCooldown > 3 then
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer then
                        local character = player.Character
                        local theirRoot = character and character:FindFirstChild("HumanoidRootPart")
                        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                        if theirRoot and humanoid and humanoid.SeatPart then
                            if (theirRoot.Position - root.Position).Magnitude <= Config.StealRange then
                                stealCooldown = os.clock()
                                busRemote("steal", player.UserId)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end)

--// Visuals -----------------------------------------------------------------------
local chairHighlights = {}
local playerHighlights = {}

local function clearHighlights(store)
    for key, inst in pairs(store) do
        pcall(function() inst:Destroy() end)
        store[key] = nil
    end
end

local function refreshChairEsp()
    if not Config.ChairEsp then
        clearHighlights(chairHighlights)
        return
    end
    for _, seat in ipairs(allSeats()) do
        local highlight = chairHighlights[seat]
        if not highlight or not highlight.Parent then
            highlight = Instance.new("Highlight")
            highlight.FillTransparency = 0.6
            highlight.OutlineTransparency = 0
            highlight.Adornee = seat.Parent or seat
            highlight.Parent = seat
            chairHighlights[seat] = highlight
        end
        local free = seat.Occupant == nil
        local colour = free and Color3.fromRGB(70, 220, 120) or Color3.fromRGB(230, 70, 70)
        highlight.FillColor = colour
        highlight.OutlineColor = colour
    end
end

local function refreshPlayerEsp()
    if not Config.PlayerEsp then
        clearHighlights(playerHighlights)
        return
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local character = player.Character
            if character then
                local entry = playerHighlights[player]
                if not entry or not entry.Parent then
                    entry = Instance.new("Highlight")
                    entry.FillTransparency = 0.75
                    entry.FillColor = Color3.fromRGB(90, 160, 255)
                    entry.OutlineColor = Color3.fromRGB(150, 200, 255)
                    entry.Parent = character
                    playerHighlights[player] = entry
                end
                entry.Adornee = character

                if Config.EspNames then
                    local head = character:FindFirstChild("Head")
                    local gui = head and head:FindFirstChild("WG_Tag")
                    if head and not gui then
                        gui = Instance.new("BillboardGui")
                        gui.Name = "WG_Tag"
                        gui.Adornee = head
                        gui.Size = UDim2.fromOffset(180, 30)
                        gui.StudsOffset = Vector3.new(0, 2.4, 0)
                        gui.AlwaysOnTop = true
                        local text = Instance.new("TextLabel")
                        text.Name = "T"
                        text.BackgroundTransparency = 1
                        text.Size = UDim2.fromScale(1, 1)
                        text.Font = Enum.Font.GothamBold
                        text.TextSize = 13
                        text.TextStrokeTransparency = 0.4
                        text.TextColor3 = Color3.fromRGB(255, 255, 255)
                        text.Parent = gui
                        gui.Parent = head
                    end
                    if gui then
                        local label = gui:FindFirstChild("T")
                        local stats = player:FindFirstChild("leaderstats")
                        local wins = stats and stats:FindFirstChild("Wins")
                        local streak = stats and stats:FindFirstChild("Streak")
                        if label then
                            label.Text = ("%s  [W %s / S %s]"):format(
                                player.Name,
                                wins and tostring(wins.Value) or "?",
                                streak and tostring(streak.Value) or "?"
                            )
                        end
                    end
                else
                    local head = character:FindFirstChild("Head")
                    local gui = head and head:FindFirstChild("WG_Tag")
                    if gui then gui:Destroy() end
                end
            end
        end
    end
end

task.spawn(function()
    while not Unloading do
        task.wait(0.5)
        pcall(refreshChairEsp)
        pcall(refreshPlayerEsp)
    end
end)

--// Movement ----------------------------------------------------------------------
local function humanoid()
    local character = LocalPlayer.Character
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

track(PostSimulation:Connect(function()
    if Unloading then return end
    local human = humanoid()
    if not human then return end
    if Config.WalkSpeed ~= 16 and human.WalkSpeed ~= Config.WalkSpeed then
        human.WalkSpeed = Config.WalkSpeed
    end
    if Config.JumpPower ~= 50 then
        human.UseJumpPower = true
        if human.JumpPower ~= Config.JumpPower then
            human.JumpPower = Config.JumpPower
        end
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloading or not Config.InfiniteJump then return end
    local human = humanoid()
    if human then
        human:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end))

--// Autosave the learned bank -----------------------------------------------------
task.spawn(function()
    while not Unloading do
        task.wait(20)
        pcall(saveLearned)
    end
end)

loadWords()

--// UI ----------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui/main/Lib2.lua"))()

local Window = Centrl:Window({
    Title = "word game",
    SubTitle = "auto type",
    Folder = "Hub",
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(120, 200, 120),
})

--// Main tab ----------------------------------------------------------------------
local MainTab = Window:Tab({ Title = "type", Icon = "keyboard" })

local TypeSection = MainTab:Section({ Title = "auto type", Side = "left" })

TypeSection:Toggle({
    Title = "auto type",
    Flag = "wg_auto",
    Default = false,
    Callback = function(state)
        Config.AutoType = state
        if state and Round.isTurn and not Config.PanicOnly then
            solveRound()
        end
    end,
})

TypeSection:Toggle({
    Title = "suggest only",
    Flag = "wg_suggest",
    Default = false,
    Callback = function(state) Config.SuggestOnly = state end,
})

TypeSection:RangeSlider({
    Title = "delay before typing",
    Flag = "wg_start_delay",
    Min = 0, Max = 3, Increment = 0.05,
    Default = { 0.35, 1.2 },
    Suffix = "s",
    Callback = function(low, high)
        Config.StartDelay = { Min = low, Max = high }
    end,
})

TypeSection:RangeSlider({
    Title = "delay between letters",
    Flag = "wg_letter_delay",
    Min = 0, Max = 1, Increment = 0.01,
    Default = { 0.06, 0.16 },
    Suffix = "s",
    Callback = function(low, high)
        Config.LetterDelay = { Min = low, Max = high }
    end,
})

TypeSection:RangeSlider({
    Title = "delay before submit",
    Flag = "wg_submit_delay",
    Min = 0, Max = 1, Increment = 0.01,
    Default = { 0.08, 0.3 },
    Suffix = "s",
    Callback = function(low, high)
        Config.SubmitDelay = { Min = low, Max = high }
    end,
})

TypeSection:Paragraph({
    Title = "no two gaps in a row are alike",
    Text = "Each keystroke gap is drawn fresh from the span above, and a draw that lands too close to the previous one is thrown away and redrawn - it has to be at least 15% of the span away to be accepted. A span too narrow for that to ever pass reflects across its own midpoint instead, so the value still changes rather than quietly settling into a constant. A fixed gap between letters is the single most recognisable thing about a typing bot, and it is the one thing this will not produce.",
})

local RandomSection = MainTab:Section({ Title = "randomizer", Side = "right" })

RandomSection:Toggle({
    Title = "randomizer",
    Flag = "wg_randomizer",
    Default = false,
    Callback = function(state) Config.Randomizer = state end,
})

RandomSection:RangeSlider({
    Title = "extra pause",
    Flag = "wg_random_amount",
    Min = 0, Max = 2, Increment = 0.05,
    Default = { 0.1, 0.6 },
    Suffix = "s",
    Callback = function(low, high)
        Config.RandomAmount = { Min = low, Max = high }
    end,
})

RandomSection:Slider({
    Title = "how often",
    Flag = "wg_random_chance",
    Min = 1, Max = 100, Increment = 1, Default = 25,
    Suffix = "%",
    Callback = function(value) Config.RandomChance = value end,
})

RandomSection:Paragraph({
    Title = "what the randomizer adds",
    Text = "On top of the delays above, and only on the share of them set by 'how often', an extra pause of a random length from its own span. The delay spans give you a steady typing rhythm; this is the part that breaks it - the mid-word hesitation of someone who had to stop and think. Leaving it off gives clean, even typing inside your chosen spans, which is faster but reads as more machine-like.",
})

RandomSection:Toggle({
    Title = "only answer when low on time",
    Flag = "wg_panic",
    Default = false,
    Callback = function(state) Config.PanicOnly = state end,
})

RandomSection:Slider({
    Title = "answer at",
    Flag = "wg_panic_at",
    Min = 1, Max = 15, Increment = 0.5, Default = 4,
    Suffix = "s left",
    Callback = function(value) Config.PanicAt = value end,
})

local WordSection = MainTab:Section({ Title = "word choice", Side = "left" })

WordSection:Dropdown({
    Title = "prefer",
    Flag = "wg_pick",
    Options = { "common", "shortest", "longest", "random" },
    Default = "common",
    Callback = function(value) Config.Pick = value end,
})

WordSection:RangeSlider({
    Title = "word length",
    Flag = "wg_length",
    Min = 3, Max = 14, Increment = 1,
    Default = { 4, 9 },
    Callback = function(low, high)
        Config.WordLength = { Min = low, Max = high }
    end,
})

WordSection:Toggle({
    Title = "avoid words already used",
    Flag = "wg_avoid",
    Default = true,
    Callback = function(state) Config.AvoidUsed = state end,
})

WordSection:Paragraph({
    Title = "how a word gets picked",
    Text = "Words the server has already accepted outrank everything, then words from the common list, then the rest of the dictionary. 'shortest' is the fastest to type and the safest on a low clock; 'longest' exists because several pets pay out on words of ten letters or more; 'common' is the middle road and the default. Length here is a preference rather than a rule - if nothing inside the band starts with the prefix, a word outside it beats no word at all.",
})

local StatusSection = MainTab:Section({ Title = "status", Side = "right" })

local busLabel = StatusSection:Label({ Title = "bus: --" })
local bankLabel = StatusSection:Label({ Title = "bank: --" })
local roundLabel = StatusSection:Label({ Title = "round: --" })
local turnLabel = StatusSection:Label({ Title = "turn: --" })
local suggestLabel = StatusSection:Label({ Title = "word: --" })
local statusLabel = StatusSection:Label({ Title = "status: --" })
local countLabel = StatusSection:Label({ Title = "answered 0 / missed 0" })

--// Match tab ---------------------------------------------------------------------
local MatchTab = Window:Tab({ Title = "match", Icon = "swords" })

local RoundSection = MatchTab:Section({ Title = "round", Side = "left" })

local questionLabel = RoundSection:Label({ Title = "question: --" })
local prefixLabel = RoundSection:Label({ Title = "prefix: --" })
local timerLabel = RoundSection:Label({ Title = "time: --" })
local strikeLabel = RoundSection:Label({ Title = "strikes: 0" })
local opponentLabel = RoundSection:Label({ Title = "opponent: --" })

RoundSection:Paragraph({
    Title = "you can see them typing",
    Text = "The server mirrors whoever is at the keyboard to everyone at the table, letter by letter, so the line above is their word as it is being built - not a guess. It clears when the round turns over.",
})

local HelpSection = MatchTab:Section({ Title = "match helpers", Side = "right" })

HelpSection:Toggle({
    Title = "auto time boost",
    Flag = "wg_boost",
    Default = false,
    Callback = function(state) Config.AutoTimeBoost = state end,
})

HelpSection:Slider({
    Title = "boost at",
    Flag = "wg_boost_at",
    Min = 0.5, Max = 8, Increment = 0.5, Default = 3,
    Suffix = "s left",
    Callback = function(value) Config.TimeBoostAt = value end,
})

HelpSection:Toggle({
    Title = "auto sit at a free chair",
    Flag = "wg_sit",
    Default = false,
    Callback = function(state) Config.AutoSit = state end,
})

HelpSection:Toggle({
    Title = "auto steal a seat",
    Flag = "wg_steal",
    Default = false,
    Callback = function(state) Config.AutoSteal = state end,
})

HelpSection:Slider({
    Title = "steal range",
    Flag = "wg_steal_range",
    Min = 5, Max = 100, Increment = 1, Default = 24,
    Suffix = " studs",
    Callback = function(value) Config.StealRange = value end,
})

HelpSection:Button({
    Title = "teleport to afk servers",
    Callback = function()
        busRemote("teleport", "Afk")
        Centrl:Notify({
            Title = "word game",
            Content = "Requested an AFK server.",
            Type = "info",
            Duration = 4,
        })
    end,
})

HelpSection:Paragraph({
    Title = "the time boost is capped server side",
    Text = "Two per round, and the server says so itself with a timeBoostDenied message - firing it faster does nothing but waste calls, so the button here rate limits itself to one attempt every 1.5s. Steals and seats are equally server checked: the calls below are the same ones the game's own buttons make, so anything it refuses from a real click it will refuse from here too.",
})

--// Bank tab ----------------------------------------------------------------------
local BankTab = Window:Tab({ Title = "bank", Icon = "book" })

local BankSection = BankTab:Section({ Title = "word bank", Side = "left" })

local dictLabel = BankSection:Label({ Title = "dictionary: --" })
local learnLabel = BankSection:Label({ Title = "learned: --" })
local keyLabel = BankSection:Label({ Title = "prompt key: --" })

BankSection:Toggle({
    Title = "learn from matches",
    Flag = "wg_learn",
    Default = true,
    Callback = function(state) Config.Learn = state end,
})

BankSection:Button({
    Title = "save learned words now",
    Callback = function()
        learnedDirty = true
        saveLearned()
        Centrl:Notify({
            Title = "word game",
            Content = ("Saved %d learned words."):format(Stats.Learned),
            Type = "success",
            Duration = 4,
        })
    end,
})

BankSection:Button({
    Title = "clear learned words",
    Callback = function()
        Learned = {}
        LearnedAll = {}
        Stats.Learned = 0
        learnedDirty = true
        saveLearned()
    end,
})

BankSection:Button({
    Title = "redownload dictionary",
    Callback = function()
        if HAS_FILES and typeof(delfile) == "function" then
            pcall(delfile, BANK_FILE)
            pcall(delfile, COMMON_FILE)
        end
        Dictionary = {}
        CommonSet = {}
        Stats.Dictionary, Stats.Common = 0, 0
        loadWords()
    end,
})

local AddSection = BankTab:Section({ Title = "add a word", Side = "right" })

AddSection:Textbox({
    Title = "word",
    Flag = "wg_add",
    Placeholder = "type a word, press enter",
    ClearOnFocus = true,
    Callback = function(text)
        local clean = string.lower(string.gsub(tostring(text or ""), "[^%a]", ""))
        if clean == "" then return end
        local key = Stats.PromptKey or "default"
        Learned[key] = Learned[key] or {}
        if not Learned[key][clean] then
            Learned[key][clean] = true
            Stats.Learned = Stats.Learned + 1
        end
        LearnedAll[clean] = true
        learnedDirty = true
        Centrl:Notify({
            Title = "word game",
            Content = "Added '" .. clean .. "' under " .. key,
            Type = "success",
            Duration = 4,
        })
    end,
})

AddSection:Paragraph({
    Title = "where the bank comes from",
    Text = "The dictionary is 349,766 sorted English words fetched once from the hub repo and cached to disk, so it costs one download ever. It ships sorted because the words sharing a prefix are then one contiguous run - a lower-bound search and a short walk, rather than a scan of the whole list every round.\n\nThe learned half is built from the game itself. Every accepted answer is broadcast to the whole table, so each round teaches the bank a word that is known to pass, whether you played it or somebody else did. Those outrank the dictionary when a prefix comes up again, which is why this gets better the longer it runs.",
})

--// Player tab --------------------------------------------------------------------
local PlayerTab = Window:Tab({ Title = "player", Icon = "user" })

local MoveSection = PlayerTab:Section({ Title = "movement", Side = "left" })

MoveSection:Slider({
    Title = "walk speed",
    Flag = "wg_walkspeed",
    Min = 16, Max = 200, Increment = 1, Default = 16,
    Callback = function(value) Config.WalkSpeed = value end,
})

MoveSection:Slider({
    Title = "jump power",
    Flag = "wg_jump",
    Min = 50, Max = 250, Increment = 1, Default = 50,
    Callback = function(value) Config.JumpPower = value end,
})

MoveSection:Toggle({
    Title = "infinite jump",
    Flag = "wg_infjump",
    Default = false,
    Callback = function(state) Config.InfiniteJump = state end,
})

MoveSection:Button({
    Title = "teleport to nearest free chair",
    Callback = function()
        local root = rootPart()
        local seat = root and nearestFreeSeat()
        if root and seat then
            root.CFrame = seat.CFrame + Vector3.new(0, 3, 0)
        end
    end,
})

MoveSection:Paragraph({
    Title = "the map has a floor trap",
    Text = "A client handler snaps you back to the spawn the moment you drop below Y = -10, so falling through the map fixes itself and there is no need for anything here to guard against it.",
})

local VisualSection = PlayerTab:Section({ Title = "visuals", Side = "right" })

VisualSection:Toggle({
    Title = "chair esp",
    Flag = "wg_chair_esp",
    Default = false,
    Callback = function(state)
        Config.ChairEsp = state
        if not state then clearHighlights(chairHighlights) end
    end,
})

VisualSection:Toggle({
    Title = "player esp",
    Flag = "wg_player_esp",
    Default = false,
    Callback = function(state)
        Config.PlayerEsp = state
        if not state then clearHighlights(playerHighlights) end
    end,
})

VisualSection:Toggle({
    Title = "show wins and streak",
    Flag = "wg_esp_names",
    Default = true,
    Callback = function(state) Config.EspNames = state end,
})

VisualSection:Paragraph({
    Title = "green chairs are free",
    Text = "Seats read their own Occupant, so the colour is the seat's actual state rather than a guess from who is standing nearby. Wins and streak come off each player's leaderstats, which the server replicates to everyone anyway.",
})

VisualSection:Button({
    Title = "unload",
    Callback = function()
        Unloading = true
        saveLearned()
        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        if Bus then
            for _, handle in ipairs(BusHandles) do
                pcall(Bus.disconnect, handle)
            end
        end
        clearHighlights(chairHighlights)
        clearHighlights(playerHighlights)
        for _, player in ipairs(Players:GetPlayers()) do
            local head = player.Character and player.Character:FindFirstChild("Head")
            local gui = head and head:FindFirstChild("WG_Tag")
            if gui then pcall(function() gui:Destroy() end) end
        end
        Centrl:Unload()
    end,
})

Window:Load()

--// Status pump -------------------------------------------------------------------
task.spawn(function()
    while not Unloading do
        task.wait(0.2)
        pcall(function()
            busLabel:Set("bus: " .. Stats.Bus)
            bankLabel:Set(("bank: %d words / %d learned"):format(Stats.Dictionary, Stats.Learned))
            roundLabel:Set("round: " .. Stats.Round)
            turnLabel:Set(("turn: %s   (%d candidates)"):format(Stats.Turn, Stats.Candidates))
            suggestLabel:Set("word: " .. tostring(Stats.Suggestion))
            statusLabel:Set("status: " .. Stats.Status)
            countLabel:Set(("answered %d / missed %d / keys %d"):format(Stats.Answered, Stats.Missed, Stats.Typed))

            questionLabel:Set("question: " .. (Stats.Question ~= "" and Stats.Question or "--"))
            prefixLabel:Set("prefix: " .. (Stats.Prefix ~= "" and Stats.Prefix or "--"))
            timerLabel:Set(("time: %.1fs   last gap %.0fms"):format(Stats.Timer, Stats.LastDelay * 1000))
            strikeLabel:Set(("strikes: %d"):format(Stats.Strikes))
            opponentLabel:Set("opponent: " .. (Stats.OpponentTyping ~= "" and Stats.OpponentTyping or "--"))

            dictLabel:Set(("dictionary: %d   common: %d"):format(Stats.Dictionary, Stats.Common))
            learnLabel:Set(("learned: %d   last accepted: %s"):format(Stats.Learned, tostring(Stats.LastWord)))
            keyLabel:Set("prompt key: " .. tostring(Stats.PromptKey or "--"))
        end)
    end
end)

Centrl:Notify({
    Title = "word game",
    Content = Bus and "Loaded. RightShift toggles the menu." or "Loaded, but the game's event bus was not found.",
    Type = Bus and "success" or "warning",
    Duration = 6,
})

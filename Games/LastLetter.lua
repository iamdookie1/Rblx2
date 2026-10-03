--// Last Letter ----------------------------------------------------------------------
-- Built against a script dump of the live game (place 129866685202296, version 7955).
--
-- What the game's own client scripts show:
--  * All networking is one RemoteEvent wrapped by ReplicatedStorage.Modules.Packet,
--    with every packet named in ReplicatedStorage.Constants.Remotes. Packet reads a
--    packet's OnClientInvoke at call time, so wrapping it changes what the game runs.
--  * Your turn: the server sends Rotate(newWord, letters, playerName, seat), then asks
--    your client GetWordFromPlayer(timeToRespond, firstAsk, ...). The game collects
--    key presses (it relays each letter to the table with UpdateWord) and returns the
--    word once you press Enter / Done. The server checks it against its own
--    dictionary and answers AnswerResults(correct, userId, wpm). You get 5 tries a
--    turn and 2 lives; Elimination(userId, livesLeft) is a life lost.
--  * One By One asks GetLetterFromWord(time) for a single letter; the starting letter
--    of a round is GetFirstLetter(options).
--  * Every device has the on-screen keyboard (PlayerGui.Overbar.Frame.Keyboard). Its
--    key buttons call the same handler the game binds for that turn, so pressing them
--    types exactly like a player would, with AutoTypePrefix handled by the game.
--  * MatchSettings: HardModeStartingTurn 50, MaxPrefixLength 4, MinPossibleAnswers 3.
--    The prefix is the end of the last word; how many letters is decided on the
--    server, so the script learns the lengths it sees each match.
--  * There is no client anti cheat. Staff are a Moderator attribute on the player
--    (its value is the rank), a rank in group 35222573 (255 owner, 2 tester), and the
--    manager's UserId. Your WPM is shown to the whole table after every answer.
--  * There is no word list on the client; the dictionary is downloaded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local DICTIONARY_URL = "https://raw.githubusercontent.com/Unknowns-debug/words/refs/heads/main/English-words"
local FOLDER = "LastLetter"
local STAFF_GROUP = 35222573
local MANAGER_ID = 3012508695
local HARD_MODE_TURN = 50

-- A second run of the script retires the first one.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__LastLetterUnload then
    pcall(Genv.__LastLetterUnload)
end
Genv.__LastLetterRun = (Genv.__LastLetterRun or 0) + 1
local RUN = Genv.__LastLetterRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__LastLetterRun == RUN
end

--// Ui3, from the latest commit so a cached main branch never wins \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    else
        warn("[Ui3] could not resolve the latest commit, falling back to main: " .. tostring(sha))
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end

local S = {
    -- last letter
    AutoType = false, WordStyle = "Balanced", TargetLength = 6, MinLength = 4, MaxLength = 12, PickFrom = 5,
    -- typing
    TypeMethod = "Auto", PrefixMode = "Auto", Wpm = 75, WpmJitter = 25, ReactMin = 600, ReactMax = 1400,
    TypoChance = 0, FinishInTime = true, AutoSubmit = true, RetryDelay = 500,
    -- one by one
    AutoOneByOne = false, ObOStrategy = "Win, else safe", ObOMinLength = 3,
    -- first letter
    AutoFirstLetter = false, FirstLetterStyle = "Easiest",
    -- suggestions
    ShowSuggestions = true,
    -- abilities
    AutoAbility = false, AbilityTime = 4, AbilityOnStuck = true, AbilityOthers = false, AbilityOthersDelay = 2,
    -- traps
    UseTraps = false, RespectSeen = true, ResetOnLife = true, TrapLength = 2, TrapMinAnswers = 3,
    TrapMaxAnswers = 15, ShowTraps = true, TrapsUsableOnly = false, TrapMinEnds = 2, HardEndings = true,
    -- staff
    StaffDetect = true, StaffAttribute = true, StaffGroupRank = 2, StaffManager = true,
    StaffActions = { Notify = true, ["Pause auto play"] = true },
    -- word filters
    AvoidLetters = "", AvoidEndings = "", BannedWords = "", FavoriteWords = "", SkipOddWords = true,
    IgnoreFiltersIfStuck = true,
    -- timing
    WaitUntilLeft = 0, ThinkPerLetter = 0, PauseChance = 0, PauseMin = 200, PauseMax = 700,
    SubmitMin = 80, SubmitMax = 250, TypoFixDelay = 250, MaxTries = 5,
    -- lobby
    AutoJoin = false, JoinModes = { ["Last Letter"] = true }, JoinSizes = { ["2"] = true, ["4"] = true, ["8"] = true },
    JoinPreferWaiting = true, JoinEvery = 4, AutoDaily = false, AutoTasks = false, LogAbilities = true, NotifyBlocked = true,
    -- misc
    CacheDictionary = true, LearnBadWords = true, AntiAfk = true,
}

-- "q, x z" -> { q = true, x = true, z = true }
local function wordSet(text)
    local set = {}
    for w in string.gmatch(string.lower(tostring(text or "")), "%l+") do
        set[w] = true
    end
    return set
end
local Filters = { avoidLetters = {}, avoidEndings = {}, banned = {}, favorite = {} }
local function refreshFilters()
    Filters.avoidLetters = {}
    for c in string.gmatch(string.lower(S.AvoidLetters), "%l") do
        Filters.avoidLetters[c] = true
    end
    Filters.avoidEndings = wordSet(S.AvoidEndings)
    Filters.banned = wordSet(S.BannedWords)
    Filters.favorite = wordSet(S.FavoriteWords)
end

--// Plumbing \\--
local Connections = {}
local function bind(signal, fn)
    local ok, c = pcall(signal.Connect, signal, fn)
    if ok and c then
        table.insert(Connections, c)
    end
    return c
end

local function fileOk()
    return typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
end
local function ensureFolder()
    if typeof(isfolder) == "function" and typeof(makefolder) == "function" and not isfolder(FOLDER) then
        pcall(makefolder, FOLDER)
    end
end

local function playerGui()
    return LocalPlayer:FindFirstChild("PlayerGui")
end
local function guiPath(...)
    local node = playerGui()
    for _, name in { ... } do
        node = node and node:FindFirstChild(name)
    end
    return node
end

local function notify(title, text, time)
    pcall(function()
        Library:Notify({ Title = title, Description = text, Time = time or 4 })
    end)
end

--// The game's tables (remote packets and your settings) \\--
-- getgc finds the tables the game itself uses; require is the fallback.
local Game = { remotes = nil, settings = nil, shared = false, styles = nil }
do
    if typeof(getgc) == "function" then
        pcall(function()
            for _, v in getgc(true) do
                if type(v) == "table" then
                    if not Game.remotes and rawget(v, "GetWordFromPlayer") ~= nil and rawget(v, "Rotate") ~= nil and rawget(v, "AnswerResults") ~= nil then
                        Game.remotes = v
                    elseif not Game.settings and rawget(v, "AutoTypePrefix") ~= nil and rawget(v, "KeyboardLayout") ~= nil then
                        Game.settings = v
                    end
                    if Game.remotes and Game.settings then
                        break
                    end
                end
            end
        end)
    end
    if not Game.remotes then
        pcall(function()
            Game.remotes = require(ReplicatedStorage:WaitForChild("Constants"):WaitForChild("Remotes"))
        end)
    end
    if not Game.settings then
        pcall(function()
            Game.settings = require(game:GetService("StarterPlayer").StarterPlayerScripts.Modules.PlayerData).Settings
        end)
    end
    pcall(function()
        Game.styles = require(ReplicatedStorage.Constants.Items.Styles)
    end)
    -- The game's own packets have OnClientInvoke set; a fresh copy would not.
    Game.shared = Game.remotes ~= nil and Game.remotes.GetWordFromPlayer ~= nil
        and rawget(Game.remotes.GetWordFromPlayer, "OnClientInvoke") ~= nil
end

--// Dictionary \\--
local Dict = {
    ready = false, loading = false, progress = 0, total = 445955,
    words = 0, buckets = {}, byFirst = {}, set = {}, start = {}, ends = {},
}
local Bad = {}       -- words the server turned down, kept across runs
local BadCount = 0

local function loadBad()
    if not fileOk() or not isfile(FOLDER .. "/bad_words.txt") then
        return
    end
    local ok, text = pcall(readfile, FOLDER .. "/bad_words.txt")
    if ok and text then
        for w in string.gmatch(text, "%l+") do
            if not Bad[w] then
                Bad[w] = true
                BadCount += 1
            end
        end
    end
end
local function saveBad()
    if not fileOk() or not S.LearnBadWords then
        return
    end
    ensureFolder()
    local list = {}
    for w in Bad do
        table.insert(list, w)
    end
    pcall(writefile, FOLDER .. "/bad_words.txt", table.concat(list, "\n"))
end
-- A rejection can mean "already used", so a word is only remembered as bad
-- once it's been turned down in two different matches.
local Suspect = {}
local MatchId = 0
local function markBad(word)
    if not word or Bad[word] or not S.LearnBadWords then
        return
    end
    local first = Suspect[word]
    if first == nil then
        Suspect[word] = MatchId
    elseif first ~= MatchId then
        Bad[word] = true
        BadCount += 1
        task.spawn(saveBad)
    end
end

local function buildDictionary(text)
    local buckets, byFirst, set, start, ends = {}, {}, {}, {}, {}
    local n = 0
    for w in string.gmatch(text, "%l+") do
        local len = #w
        if len >= 2 then
            n += 1
            set[w] = true
            local key = string.sub(w, 1, 2)
            local bucket = buckets[key]
            if not bucket then
                bucket = {}
                buckets[key] = bucket
                local first = string.sub(w, 1, 1)
                byFirst[first] = byFirst[first] or {}
                table.insert(byFirst[first], bucket)
            end
            bucket[#bucket + 1] = w
            for k = 1, (len < 4 and len or 4) do
                local p = string.sub(w, 1, k)
                start[p] = (start[p] or 0) + 1
                local e = string.sub(w, len - k + 1)
                ends[e] = (ends[e] or 0) + 1
            end
        end
        if n % 15000 == 0 then
            Dict.progress = n
            task.wait()
            if not alive() then
                return
            end
        end
    end
    Dict.buckets, Dict.byFirst, Dict.set, Dict.start, Dict.ends = buckets, byFirst, set, start, ends
    Dict.words, Dict.progress, Dict.total = n, n, n
    Dict.ready = true
end

local function loadDictionary(fresh)
    if Dict.loading then
        return
    end
    Dict.loading, Dict.ready, Dict.progress = true, false, 0
    task.spawn(function()
        local text
        local cache = FOLDER .. "/words.txt"
        if not fresh and S.CacheDictionary and fileOk() and isfile(cache) then
            local ok, cached = pcall(readfile, cache)
            if ok and cached and #cached > 100000 then
                text = cached
            end
        end
        if not text then
            local ok, body = pcall(game.HttpGet, game, DICTIONARY_URL)
            if not ok or not body or #body < 1000 then
                Dict.loading = false
                notify("Dictionary", "Download failed: " .. tostring(body), 6)
                return
            end
            text = string.lower(body)
            if S.CacheDictionary and fileOk() then
                ensureFolder()
                pcall(writefile, cache, text)
            end
        end
        buildDictionary(text)
        Dict.loading = false
    end)
end

-- Every unused, allowed word starting with `prefix` (lowercase).
local function wordsWithPrefix(prefix, used, minLen, maxLen)
    local out = {}
    if not Dict.ready or prefix == "" then
        return out
    end
    local plen = #prefix
    local sources
    if plen >= 2 then
        sources = { Dict.buckets[string.sub(prefix, 1, 2)] }
    else
        sources = Dict.byFirst[prefix] or {}
    end
    for _, bucket in sources do
        for _, w in bucket do
            local len = #w
            if len > plen and len >= minLen and len <= maxLen
                and (plen <= 2 or string.sub(w, 1, plen) == prefix)
                and not (used and used[w]) and not Bad[w] then
                out[#out + 1] = w
            end
        end
    end
    return out
end

--// Match state \\--
local Match = {
    tableName = nil, mode = nil, started = false, turn = 0, prefix = "", player = nil,
    word = "", lastWord = nil, used = {}, usedStart = {}, usedCount = 0,
    seen = { [1] = true }, seenMax = 1, lives = {}, lastPrefixLen = 0,
}

local function resetSeen(reason)
    Match.seen, Match.seenMax = { [1] = true }, 1
    return reason
end

local function resetMatch()
    MatchId += 1
    Match.turn, Match.prefix, Match.player, Match.word, Match.lastWord = 0, "", nil, "", nil
    Match.used, Match.usedStart, Match.usedCount = {}, {}, 0
    Match.lives, Match.lastPrefixLen = {}, 0
    resetSeen()
end

local function currentTable()
    local name = LocalPlayer:GetAttribute("InTable") or Match.tableName
    local tables = Workspace:FindFirstChild("Tables")
    return name and tables and tables:FindFirstChild(tostring(name)), name
end

local function currentMode()
    local tbl = currentTable()
    return (tbl and tbl:GetAttribute("Gamemode")) or Match.mode
end

local function tablePlayers()
    local _, name = currentTable()
    local list = {}
    if not name then
        return list
    end
    for _, p in Players:GetPlayers() do
        if tostring(p:GetAttribute("InTable") or "") == tostring(name) then
            table.insert(list, p)
        end
    end
    return list
end

local function useWord(word)
    word = word and string.lower(word)
    if not word or word == "" or not string.match(word, "^%l+$") or Match.used[word] then
        return
    end
    Match.used[word] = true
    Match.usedCount += 1
    for k = 1, math.min(4, #word) do
        local p = string.sub(word, 1, k)
        Match.usedStart[p] = (Match.usedStart[p] or 0) + 1
    end
    Match.lastWord = word
end

-- Answers left for an ending this match.
local function liveAnswers(ending)
    return (Dict.start[ending] or 0) - (Match.usedStart[ending] or 0)
end

-- Longest trap ending the next player could get from `word`: the longest allowed
-- length whose ending still has enough answers (the server skips endings with too
-- few). Returns the answer count and the ending.
local function trapLengthCap()
    local cap = S.TrapLength
    if S.RespectSeen then
        cap = math.min(cap, Match.seenMax)
    end
    return cap
end
local function trapOf(word)
    for len = math.min(trapLengthCap(), #word - 1), 1, -1 do
        local ending = string.sub(word, -len)
        local n = liveAnswers(ending)
        if n >= S.TrapMinAnswers then
            return n, ending
        end
    end
    return nil
end

--// Word choice \\--
-- Junk in a big list: no vowel at all, a letter three times in a row, or a long
-- run of six consonants usually means an abbreviation or code the game won't take.
local function looksOdd(w)
    if not string.find(w, "[aeiouy]") then
        return true
    end
    if string.find(w, "(%l)%1%1") then
        return true
    end
    return string.find(w, "[^aeiouy][^aeiouy][^aeiouy][^aeiouy][^aeiouy][^aeiouy]") ~= nil
end

local function allowedWord(w)
    if Filters.banned[w] then
        return false
    end
    if S.SkipOddWords and looksOdd(w) then
        return false
    end
    if next(Filters.avoidLetters) then
        for c in string.gmatch(w, "%l") do
            if Filters.avoidLetters[c] then
                return false
            end
        end
    end
    for ending in Filters.avoidEndings do
        if #ending < #w and string.sub(w, -#ending) == ending then
            return false
        end
    end
    return true
end

local function pickWord(prefix)
    prefix = string.lower(prefix or "")
    local all = wordsWithPrefix(prefix, Match.used, S.MinLength, S.MaxLength)
    if #all == 0 then
        -- Nothing fits the length limits: take anything that starts right.
        all = wordsWithPrefix(prefix, Match.used, 2, 99)
    end
    if #all == 0 then
        return nil
    end

    -- Favorites first, when one fits (any length, even outside the dictionary).
    local favorites = {}
    for w in Filters.favorite do
        if #w > #prefix and string.sub(w, 1, #prefix) == prefix and not Match.used[w]
            and not Bad[w] and not Filters.banned[w] then
            favorites[#favorites + 1] = w
        end
    end
    if #favorites > 0 then
        return favorites[math.random(1, #favorites)]
    end

    local list = {}
    for _, w in all do
        if allowedWord(w) then
            list[#list + 1] = w
        end
    end
    if #list == 0 then
        if not S.IgnoreFiltersIfStuck then
            return nil
        end
        list = all
    end

    if S.UseTraps then
        -- Fewest answers for the next player; ties go to the length you aim for,
        -- since the shortest "words" in a big list are often abbreviations.
        local best, bestN, bestFit, hard, hardN, hardFit
        for _, w in list do
            local n = trapOf(w)
            if n then
                local fit = math.abs(#w - S.TargetLength) + math.random() * 0.5
                if n <= S.TrapMaxAnswers and (not bestN or n < bestN or (n == bestN and fit < bestFit)) then
                    best, bestN, bestFit = w, n, fit
                end
                if not hardN or n < hardN or (n == hardN and fit < hardFit) then
                    hard, hardN, hardFit = w, n, fit
                end
            end
        end
        if best then
            return best, bestN
        end
        if S.HardEndings and hard then
            return hard
        end
    end

    local style = S.WordStyle
    local scored = {}
    for _, w in list do
        local score
        if style == "Shortest" then
            score = #w
        elseif style == "Longest" then
            score = -#w
        elseif style == "Random" then
            score = math.random()
        else
            score = math.abs(#w - S.TargetLength) + math.random() * 0.5
        end
        scored[#scored + 1] = { w = w, s = score }
    end
    table.sort(scored, function(a, b)
        return a.s < b.s
    end)
    local top = math.clamp(S.PickFrom, 1, #scored)
    return scored[math.random(1, top)].w
end

-- One By One: a letter that finishes a word, else one that doesn't let the next
-- player finish, else the letter with the most ways to go on.
local function pickLetter(current)
    current = string.lower(current or "")
    if current == "" then
        return nil
    end
    local list = wordsWithPrefix(current, nil, 2, 99)
    local options = {}
    local plen = #current
    for _, w in list do
        local c = string.sub(w, plen + 1, plen + 1)
        local o = options[c]
        if not o then
            o = { letter = c, ways = 0, win = false, danger = false }
            options[c] = o
        end
        o.ways += 1
        if #w == plen + 1 and #w >= S.ObOMinLength then
            o.win = true
        elseif #w == plen + 2 and #w >= S.ObOMinLength then
            o.danger = true
        end
    end
    local best, bestScore
    for _, o in options do
        local score = o.ways
        if S.ObOStrategy ~= "Most options" then
            if o.win then
                score += 1e9
            elseif not o.danger then
                score += 1e6
            end
        end
        if not bestScore or score > bestScore then
            best, bestScore = o, score
        end
    end
    return best and best.letter
end

local function pickFirstLetter(options)
    local list = {}
    for _, l in options do
        if type(l) == "string" and #l == 1 then
            table.insert(list, l)
        end
    end
    if #list == 0 then
        return nil
    end
    if S.FirstLetterStyle == "Random" then
        return list[math.random(1, #list)]
    end
    local best, bestN
    for _, l in list do
        local n = Dict.start[string.lower(l)] or 0
        local better = not bestN or (S.FirstLetterStyle == "Easiest" and n > bestN) or (S.FirstLetterStyle == "Hardest" and n < bestN)
        if better then
            best, bestN = l, n
        end
    end
    return best
end

local Turn = { gen = 0, active = false, prefix = "", s2 = "", word = nil, deadline = 0, tries = 0, autoPrefix = nil }

--// Keys: the on-screen keyboard every device has, or real key events \\--
local function keyboard()
    return guiPath("Overbar", "Frame", "Keyboard")
end

local function keyButton(name)
    local kb = keyboard()
    if not kb then
        return nil
    end
    local direct = kb:FindFirstChild(name)
    if direct and direct:IsA("GuiButton") then
        return direct
    end
    for _, row in kb:GetChildren() do
        local b = row:FindFirstChild(name)
        if b and b:IsA("GuiButton") then
            return b
        end
    end
    return nil
end

local function fireSignal(signal)
    if typeof(firesignal) == "function" then
        return (pcall(firesignal, signal))
    end
    if typeof(getconnections) == "function" then
        local fired = false
        for _, c in getconnections(signal) do
            if c.Function then
                task.spawn(c.Function)
                fired = true
            elseif c.Fire then
                pcall(c.Fire, c)
                fired = true
            end
        end
        return fired
    end
    return false
end

local function useScreenKeys()
    if S.TypeMethod == "Keyboard (PC)" then
        return false
    end
    local canFire = typeof(firesignal) == "function" or typeof(getconnections) == "function"
    return canFire and keyboard() ~= nil
end

local VIM_KEYS = { Done = Enum.KeyCode.Return, Delete = Enum.KeyCode.Backspace }
local function pressKey(key)
    -- key: "A".."Z", "Done" or "Delete"
    if useScreenKeys() then
        local button = keyButton(key)
        if key == "Delete" then
            button = button and button.Visible and button or keyButton("DeleteDVORAK") or button
            if button then
                fireSignal(button.MouseButton1Down)
                task.wait()
                fireSignal(button.MouseButton1Up)
                return true
            end
        elseif button then
            return fireSignal(button.MouseButton1Click)
        end
    end
    local code = VIM_KEYS[key] or Enum.KeyCode[key]
    if not code then
        return false
    end
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, code, false, game)
        task.wait(0.02)
        VirtualInputManager:SendKeyEvent(false, code, false, game)
    end)
    return true
end

-- The word on screen, in typed order (nil when an ability has scrambled it).
local function currentWordFrame()
    return guiPath("InGame", "Frame", "CurrentWord")
end
local function screenWord()
    local frame = currentWordFrame()
    if not frame then
        return nil
    end
    local letters = {}
    for _, child in frame:GetChildren() do
        local index = tonumber(child.Name)
        local label = index and child:IsA("Frame") and child:FindFirstChild("Letter")
        if label and label:IsA("TextLabel") then
            letters[index] = label.Text
        end
    end
    local out = {}
    local i = 1
    while letters[i] do
        local letter = string.lower(letters[i])
        if not string.match(letter, "^%l$") then
            return nil
        end
        out[i] = letter
        i += 1
    end
    return #out > 0 and table.concat(out) or nil
end

-- Whether the game already put the starting letters in your word. When it
-- hasn't, it shows them as grey boxes (Filled = false) you have to type over.
local function prefixOnScreen()
    local frame = currentWordFrame()
    if not frame then
        return nil
    end
    local sawBase = false
    for _, child in frame:GetChildren() do
        if child:IsA("Frame") and child:GetAttribute("BaseLetter") == true then
            sawBase = true
            if child:GetAttribute("Filled") == false then
                return false
            end
        end
    end
    return sawBase and true or nil
end

local function autoTypePrefix()
    if S.PrefixMode == "Game types it" then
        return true
    elseif S.PrefixMode == "I type it" then
        return false
    end
    if Turn.autoPrefix ~= nil then
        return Turn.autoPrefix
    end
    local onScreen = prefixOnScreen()
    if onScreen ~= nil then
        return onScreen
    end
    if Game.settings ~= nil and Game.settings.AutoTypePrefix ~= nil then
        return Game.settings.AutoTypePrefix == true
    end
    return true
end

local function timeLeft()
    local label = guiPath("InGame", "Frame", "Circle", "Timer", "Seconds")
    return label and tonumber(string.match(label.Text or "", "[%d%.]+"))
end

--// Staff \\--
local Staff = { list = {}, present = false, ranks = {} }

local function staffReason(player)
    if S.StaffManager and player.UserId == MANAGER_ID then
        return "Manager"
    end
    if S.StaffAttribute and player:GetAttribute("Moderator") then
        return tostring(player:GetAttribute("Moderator"))
    end
    local rank = Staff.ranks[player.UserId]
    if rank and rank >= S.StaffGroupRank then
        return rank == 255 and "Owner" or rank == 2 and "Tester" or ("group rank " .. rank)
    end
    return nil
end

local function paused()
    return S.StaffDetect and Staff.present and S.StaffActions["Pause auto play"] == true
end

--// Typing a turn \\--
local Log -- set once the UI exists

local function logLine(text, color)
    if Log then
        pcall(Log.Log, Log, text, color)
    end
end

-- Mirrors what the game keeps as your typed word, so retries delete the right count.
local function mirrorKey(letter)
    local prefix = Turn.prefix
    if autoTypePrefix() or #Turn.s2 >= #prefix then
        Turn.s2 ..= letter
    elseif letter == string.sub(prefix, #Turn.s2 + 1, #Turn.s2 + 1) then
        Turn.s2 ..= letter
    end
end

local function charDelay(remaining)
    local base = 60 / (math.max(S.Wpm, 10) * 5)
    local jitter = base * (S.WpmJitter / 100)
    local d = base + (math.random() * 2 - 1) * jitter
    if S.FinishInTime and remaining and remaining > 0 then
        local timeAvailable = Turn.deadline - os.clock() - 0.6
        if timeAvailable > 0 then
            d = math.min(d, timeAvailable / remaining)
        else
            d = 0.01
        end
    end
    return math.max(d, 0.01)
end

local NEIGHBOURS = "qwertyuiopasdfghjklzxcvbnm"
local function typeWord(word, gen)
    word = string.upper(word)
    -- Delete back to what the new word shares with what's typed.
    local common = 0
    for i = 1, math.min(#Turn.s2, #word) do
        if string.sub(Turn.s2, i, i) ~= string.sub(word, i, i) then
            break
        end
        common = i
    end
    local floor = autoTypePrefix() and #Turn.prefix or 0
    while #Turn.s2 > math.max(common, floor) do
        if gen ~= Turn.gen or not alive() then
            return false
        end
        pressKey("Delete")
        Turn.s2 = string.sub(Turn.s2, 1, -2)
        task.wait(charDelay(#word))
    end
    for i = #Turn.s2 + 1, #word do
        if gen ~= Turn.gen or not alive() then
            return false
        end
        local letter = string.sub(word, i, i)
        if S.TypoChance > 0 and math.random(1, 100) <= S.TypoChance and i > #Turn.prefix then
            local r = math.random(1, #NEIGHBOURS)
            local wrong = string.upper(string.sub(NEIGHBOURS, r, r))
            if wrong ~= letter then
                pressKey(wrong)
                mirrorKey(wrong)
                task.wait(math.max(charDelay(#word - i + 2), S.TypoFixDelay / 1000))
                pressKey("Delete")
                Turn.s2 = string.sub(Turn.s2, 1, -2)
                task.wait(charDelay(#word - i + 1))
            end
        end
        pressKey(letter)
        mirrorKey(letter)
        task.wait(charDelay(#word - i))
        -- A short hesitation mid-word now and then, unless time is short.
        if S.PauseChance > 0 and i < #word and math.random(1, 100) <= S.PauseChance
            and Turn.deadline - os.clock() > 3 then
            task.wait((S.PauseMin + math.random() * math.max(S.PauseMax - S.PauseMin, 0)) / 1000)
        end
    end
    if S.AutoSubmit and gen == Turn.gen then
        local pause = (S.SubmitMin + math.random() * math.max(S.SubmitMax - S.SubmitMin, 0)) / 1000
        if S.FinishInTime then
            pause = math.min(pause, math.max(Turn.deadline - os.clock() - 0.4, 0))
        end
        task.wait(pause)
        pressKey("Done")
    end
    return true
end

local function answerTurn(gen, retry)
    if not S.AutoType or paused() or not Dict.ready then
        return
    end
    if retry and Turn.tries >= S.MaxTries then
        logLine("Stopped after " .. Turn.tries .. " tries")
        return
    end
    local react = (S.ReactMin + math.random() * math.max(S.ReactMax - S.ReactMin, 0)) / 1000
    if retry then
        react = S.RetryDelay / 1000
    end
    task.wait(react)
    if gen ~= Turn.gen or not alive() then
        return
    end
    if not retry then
        -- Read the letters now: the ask can land just before Rotate.
        Turn.prefix = string.upper(Match.prefix or "")
        Turn.autoPrefix = nil
        Turn.autoPrefix = autoTypePrefix()
        Turn.s2 = Turn.autoPrefix and Turn.prefix or ""
    end
    local word, trapN = pickWord(Turn.prefix)
    if not word then
        logLine("No word left for " .. Turn.prefix, Color3.fromRGB(255, 120, 90))
        if S.AutoAbility and S.AbilityOnStuck then
            Turn.stuck = true
        end
        return
    end
    Turn.word = word
    if trapN then
        local _, ending = trapOf(word)
        logLine(string.format("Trap: %s (next gets \"%s\", %d answers)", word, ending or "?", trapN), Library.Scheme.AccentColor)
    end

    -- Longer words take a little longer to think of.
    if not retry and S.ThinkPerLetter > 0 then
        task.wait(#word * S.ThinkPerLetter / 1000)
    end
    -- Hold the answer until only this much time is left (when it can still be typed).
    if not retry and S.WaitUntilLeft > 0 then
        local typingTime = (#word + 1) * 60 / (math.max(S.Wpm, 10) * 5) + 0.6
        local holdUntil = Turn.deadline - math.max(S.WaitUntilLeft, typingTime)
        while os.clock() < holdUntil do
            if gen ~= Turn.gen or not alive() then
                return
            end
            task.wait(0.05)
        end
    end
    if gen ~= Turn.gen or not alive() then
        return
    end
    typeWord(word, gen)
end

local function onWordRequest(timeToRespond, firstAsk, extra)
    if currentMode() == "One By One" then
        return
    end
    Turn.gen += 1
    local gen = Turn.gen
    Turn.active = true
    Turn.prefix = string.upper(Match.prefix or "")
    Turn.deadline = os.clock() + (tonumber(timeToRespond) or 15)
    local retry = not (firstAsk and not extra)
    if not retry then
        Turn.autoPrefix = nil
        Turn.s2 = ""
        Turn.tries = 0
        Turn.stuck = false
    end
    task.spawn(answerTurn, gen, retry)
end

local function onLetterRequest(timeToRespond)
    if not S.AutoOneByOne or paused() or not Dict.ready then
        return
    end
    Turn.gen += 1
    local gen = Turn.gen
    Turn.deadline = os.clock() + (tonumber(timeToRespond) or 15)
    task.spawn(function()
        task.wait((S.ReactMin + math.random() * math.max(S.ReactMax - S.ReactMin, 0)) / 1000)
        if gen ~= Turn.gen or not alive() then
            return
        end
        local letter = pickLetter(Match.word)
        if letter then
            pressKey(string.upper(letter))
            logLine("One By One: " .. string.upper(Match.word) .. "+" .. string.upper(letter))
        end
    end)
end

local function onFirstLetterRequest(options)
    if not S.AutoFirstLetter or paused() or not Dict.ready or type(options) ~= "table" then
        return
    end
    task.spawn(function()
        task.wait((S.ReactMin + math.random() * math.max(S.ReactMax - S.ReactMin, 0)) / 1000)
        local letter = pickFirstLetter(options)
        if letter then
            pressKey(string.upper(letter))
        end
    end)
end

-- Wraps the game's answer functions so the script knows the moment it's asked.
local Hooks = {}
local function wrapInvoke(name, handler)
    local packet = Game.shared and Game.remotes[name]
    local original = packet and rawget(packet, "OnClientInvoke")
    if not original then
        return false
    end
    local wrapper = function(...)
        if alive() then
            pcall(handler, ...)
        end
        return original(...)
    end
    packet.OnClientInvoke = wrapper
    Hooks[name] = { packet = packet, original = original, wrapper = wrapper }
    return true
end
local HookedWord = wrapInvoke("GetWordFromPlayer", onWordRequest)
wrapInvoke("GetLetterFromWord", onLetterRequest)
wrapInvoke("GetFirstLetter", onFirstLetterRequest)

--// Abilities \\--
local function abilityButton()
    return guiPath("Overbar", "Frame", "Right", "Ability")
end
local function abilityUsage()
    local style = LocalPlayer:GetAttribute("ImitatedStyle") or LocalPlayer:GetAttribute("CurrentStyle")
    local info = Game.styles and style and Game.styles[style]
    return info and info.Usage, style
end
local lastAbility = 0
local function useAbility(reason)
    local button = abilityButton()
    if not button or not button.Interactable or os.clock() - lastAbility < 2 then
        return
    end
    local uses = tonumber(string.match((button:FindFirstChild("Uses") and button.Uses.Text) or "", "%d+"))
    if uses and uses <= 0 then
        return
    end
    lastAbility = os.clock()
    fireSignal(button.MouseButton1Click)
    logLine("Ability used: " .. reason)
end

--// Events from the game \\--
local Events = {}
local function onEvent(name, fn)
    local packet = Game.remotes and Game.remotes[name]
    local signal = packet and packet.OnClientEvent
    if signal then
        bind(signal, function(...)
            if alive() then
                local ok, err = pcall(fn, ...)
                if not ok then
                    warn("[Last Letter] " .. name .. ": " .. tostring(err))
                end
            end
        end)
        Events[name] = true
    end
end

onEvent("Joined", function(tableName)
    Match.tableName = tostring(tableName)
    local tbl = currentTable()
    Match.mode = tbl and tbl:GetAttribute("Gamemode")
    logLine("Joined table " .. tostring(tableName) .. " (" .. tostring(Match.mode) .. ")")
end)

onEvent("GameStarting", function()
    resetMatch()
    Match.started = true
    Match.mode = currentMode()
    for _, p in tablePlayers() do
        Match.lives[p.UserId] = 2
    end
    logLine("Match started: " .. tostring(Match.mode), Library.Scheme.AccentColor)
end)

onEvent("Rotate", function(newWord, letters, playerName, seat)
    letters = tostring(letters or "")
    if letters == "Picking" then
        Match.player = playerName
        return
    end
    if playerName == "Ended" then
        Match.word = letters
        return
    end
    if newWord then
        -- The last turn's word is done: if it's a real word, it's used now.
        local finished = string.lower(Match.word or "")
        if #finished > #(Match.prefix or "") and Dict.set[finished] then
            useWord(finished)
        end
        Match.word = letters
    else
        Match.word = (Match.word or "") .. letters
    end
    Match.player = playerName
    Match.turn += 1

    if currentMode() ~= "One By One" and letters ~= "" then
        Match.prefix = letters
        local len = #letters
        if not Match.seen[len] then
            Match.seen[len] = true
            if len > Match.seenMax then
                Match.seenMax = len
            end
            logLine(len .. "-letter prefix seen: " .. letters)
        end
        Match.lastPrefixLen = len
        if Match.lastWord and string.sub(Match.lastWord, -len) ~= string.lower(letters) then
            logLine("Prefix " .. letters .. " is not the end of " .. Match.lastWord)
        end
    end

    -- No hook: the turn starts with Rotate instead.
    if not HookedWord and playerName == LocalPlayer.Name and currentMode() ~= "One By One" then
        Match.prefix = letters
        onWordRequest(15, true, nil)
    elseif playerName ~= LocalPlayer.Name then
        Turn.gen += 1
        Turn.active = false
        if S.AutoAbility and S.AbilityOthers and abilityUsage() == "others" and not paused() then
            task.delay(S.AbilityOthersDelay, function()
                if Match.player == playerName then
                    useAbility("on " .. tostring(playerName))
                end
            end)
        end
    end
end)

onEvent("AddLetter", function(letter)
    Match.word = (Match.word or "") .. tostring(letter)
end)
onEvent("RemoveLetter", function()
    Match.word = string.sub(Match.word or "", 1, -2)
end)

onEvent("AnswerResults", function(correct, userId)
    local mine = userId == LocalPlayer.UserId
    if correct then
        local word = mine and Turn.word or screenWord() or Match.word
        if not mine and word and not Dict.set[word] and Dict.set[string.lower(Match.word or "")] then
            word = Match.word
        end
        word = word and string.lower(word)
        useWord(word)
        local who = Players:GetPlayerByUserId(userId)
        logLine((who and who.DisplayName or "?") .. ": " .. string.upper(word or "?"))
        if mine then
            Turn.active = false
            Turn.gen += 1
        end
    elseif mine then
        Turn.tries += 1
        if Turn.word then
            markBad(Turn.word)
            logLine("Rejected: " .. Turn.word, Color3.fromRGB(255, 120, 90))
            useWord(Turn.word) -- never try it again this match
        end
        if not HookedWord and Turn.active and Match.player == LocalPlayer.Name then
            Turn.gen += 1
            local gen = Turn.gen
            task.spawn(answerTurn, gen, true)
        end
    end
end)

onEvent("Elimination", function(userId, livesLeft)
    local before = Match.lives[userId]
    Match.lives[userId] = livesLeft
    local who = Players:GetPlayerByUserId(userId)
    logLine((who and who.DisplayName or "?") .. " lost a life (" .. tostring(livesLeft) .. " left)", Color3.fromRGB(255, 140, 140))
    if S.ResetOnLife and (before == nil or livesLeft < before) then
        resetSeen()
        logLine("Prefix lengths reset")
    end
end)

onEvent("GameEnded", function()
    Match.started = false
    Turn.gen += 1
    Turn.active = false
    logLine("Match ended (" .. Match.usedCount .. " words)", Library.Scheme.AccentColor)
end)


-- Abilities: who used what at your table, and being blocked.
onEvent("AbilityEnabled", function(kind, ...)
    local args = { ... }
    if kind == "AbilityUsed" then
        local style, userId, uses = args[1], args[2], args[3]
        local who = Players:GetPlayerByUserId(userId)
        local _, myTable = currentTable()
        if S.LogAbilities and who and (who == LocalPlayer or tostring(who:GetAttribute("InTable") or "") == tostring(myTable or "")) then
            logLine(string.format("%s used %s (%s left)", who == LocalPlayer and "You" or who.DisplayName, tostring(style), tostring(uses)),
                Color3.fromRGB(150, 200, 255))
        end
    elseif kind == "Blocker" and S.NotifyBlocked then
        notify("Blocked", "You were blocked by " .. tostring(args[1]), 3)
        logLine("Blocked by " .. tostring(args[1]), Color3.fromRGB(255, 140, 140))
    end
end)

--// Traps list \\--
local Traps = { list = {}, page = 1, dirty = true, reach = {}, reachPrefix = nil }

local function rebuildReach()
    local prefix = string.lower(Match.prefix or "")
    Traps.reach, Traps.reachPrefix = {}, prefix
    if prefix == "" then
        return
    end
    for _, w in wordsWithPrefix(prefix, Match.used, 2, 99) do
        for len = 1, math.min(4, #w - 1) do
            local e = string.sub(w, -len)
            local cur = Traps.reach[e]
            if not cur or #w < #cur then
                Traps.reach[e] = w
            end
        end
    end
end

local function rebuildTraps()
    local list = {}
    if not Dict.ready then
        Traps.list = list
        return
    end
    if Traps.reachPrefix ~= string.lower(Match.prefix or "") then
        rebuildReach()
    end
    for e, endCount in Dict.ends do
        if #e <= S.TrapLength and endCount >= S.TrapMinEnds then
            local n = liveAnswers(e)
            if n >= S.TrapMinAnswers and n <= S.TrapMaxAnswers then
                local example = Traps.reach[e]
                if not S.TrapsUsableOnly or example then
                    list[#list + 1] = { e = e, n = n, ends = endCount, example = example }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then
            return a.n < b.n
        end
        return a.ends > b.ends
    end)
    Traps.list = list
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Last Letter",
    Footer = "dookie hub · Ui3",
    Icon = "message-square-text",
    Size = UDim2.fromOffset(760, 580),
    ConfigFolder = "Ui3/LastLetter",
})

local UI = {}

do -- Dashboard
    local Tab = Window:AddTab("Dashboard", "layout-dashboard", "Your match at a glance")
    local MatchBox = Tab:AddBigGroupbox("Match", "swords")
    UI.MatchCards = MatchBox:AddStatCards("MatchCards", {
        Cards = {
            { Title = "Mode", Value = "-", Icon = "gamepad-2" },
            { Title = "Table", Value = "-", Icon = "armchair" },
            { Title = "Turn", Value = "-", Icon = "hash" },
            { Title = "Letters", Value = "-", Icon = "type" },
        },
    })
    UI.MatchCards2 = MatchBox:AddStatCards("MatchCards2", {
        Cards = {
            { Title = "Whose turn", Value = "-", Icon = "user" },
            { Title = "Your lives", Value = "-", Icon = "heart" },
            { Title = "Prefix lengths", Value = "-", Icon = "ruler" },
            { Title = "Hard mode", Value = "-", Icon = "flame" },
        },
    })
    UI.TimeBar = MatchBox:AddProgressBar("TimeBar", { Text = "Time left", Default = 0, Max = 15, Percent = false, Rounding = 1, Suffix = " s" })
    UI.PlayersLabel = MatchBox:AddLabel("Players: -", true)
    UI.Log = MatchBox:AddLog("MatchLog", { Text = "Events", Height = 150, MaxLines = 200 })
    Log = UI.Log

    local DictBox = Tab:AddBigGroupbox("Dictionary", "book-open")
    UI.DictBar = DictBox:AddProgressBar("DictBar", { Text = "Loading dictionary", Default = 0, Max = 445955, Percent = true })
    UI.DictCards = DictBox:AddStatCards("DictCards", {
        Cards = {
            { Title = "Words", Value = "-", Icon = "library" },
            { Title = "Used this match", Value = "0", Icon = "check-check" },
            { Title = "Learned bad words", Value = "0", Icon = "ban" },
            { Title = "Traps found", Value = "-", Icon = "target" },
        },
    })
    UI.HookLabel = DictBox:AddLabel("", true)
end

do -- Main
    local Tab = Window:AddTab("Main", "keyboard", "Auto type and helpers")

    local Auto = Tab:AddLeftGroupbox("Last Letter", "type")
    Auto:AddToggle("AutoType", {
        Text = "Auto type",
        Default = false,
        Tooltip = "Types a word for you on your turn, the same way your keyboard would",
        Callback = function(v)
            S.AutoType = v
        end,
    }):AddKeyPicker("AutoTypeKey", { Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto type" })
    Auto:AddDropdown("WordStyle", {
        Text = "Word choice",
        Values = { "Balanced", "Shortest", "Longest", "Random" },
        Default = S.WordStyle,
        Tooltip = "Balanced aims for the target length. Traps (Traps tab) win over this when one fits",
        Callback = function(v)
            S.WordStyle = v or "Balanced"
        end,
    })
    Auto:AddSlider("TargetLength", { Text = "Target length", Default = S.TargetLength, Min = 3, Max = 15, Callback = function(v)
        S.TargetLength = v
    end })
    Auto:AddSlider("MinLength", { Text = "Min length", Default = S.MinLength, Min = 2, Max = 10, Callback = function(v)
        S.MinLength = v
    end })
    Auto:AddSlider("MaxLength", { Text = "Max length", Default = S.MaxLength, Min = 4, Max = 25, Callback = function(v)
        S.MaxLength = v
    end })
    Auto:AddSlider("PickFrom", {
        Text = "Pick from the best",
        Default = S.PickFrom,
        Min = 1,
        Max = 20,
        Tooltip = "Picks at random among this many best words, so you don't play the same ones every match",
        Callback = function(v)
            S.PickFrom = v
        end,
    })

    local Typing = Tab:AddRightGroupbox("Typing", "keyboard")
    Typing:AddDropdown("TypeMethod", {
        Text = "Key presses",
        Values = { "Auto", "On-screen keys", "Keyboard (PC)" },
        Default = S.TypeMethod,
        Tooltip = "On-screen keys work on every device. Keyboard (PC) sends real key events",
        Callback = function(v)
            S.TypeMethod = v or "Auto"
        end,
    })
    Typing:AddDropdown("PrefixMode", {
        Text = "Starting letters",
        Values = { "Auto", "Game types it", "I type it" },
        Default = S.PrefixMode,
        Tooltip = "Auto follows the game's Auto Type Prefix setting",
        Callback = function(v)
            S.PrefixMode = v or "Auto"
        end,
    })
    Typing:AddSlider("Wpm", { Text = "Typing speed", Default = S.Wpm, Min = 20, Max = 250, Suffix = " WPM", Tooltip = "Everyone at the table sees your WPM after each answer", Callback = function(v)
        S.Wpm = v
    end })
    Typing:AddSlider("WpmJitter", { Text = "Speed variation", Default = S.WpmJitter, Min = 0, Max = 80, Suffix = "%", Callback = function(v)
        S.WpmJitter = v
    end })
    Typing:AddSlider("ReactMin", { Text = "Think time (min)", Default = S.ReactMin, Min = 0, Max = 5000, Suffix = " ms", Callback = function(v)
        S.ReactMin = v
    end })
    Typing:AddSlider("ReactMax", { Text = "Think time (max)", Default = S.ReactMax, Min = 0, Max = 6000, Suffix = " ms", Callback = function(v)
        S.ReactMax = v
    end })
    Typing:AddSlider("TypoChance", { Text = "Typo chance", Default = S.TypoChance, Min = 0, Max = 30, Suffix = "%", Tooltip = "Hits a wrong key now and then and fixes it", Callback = function(v)
        S.TypoChance = v
    end })
    Typing:AddSlider("RetryDelay", { Text = "Delay after a rejected word", Default = S.RetryDelay, Min = 0, Max = 3000, Suffix = " ms", Callback = function(v)
        S.RetryDelay = v
    end })
    Typing:AddToggle("FinishInTime", { Text = "Speed up to beat the timer", Default = S.FinishInTime, Callback = function(v)
        S.FinishInTime = v
    end })
    Typing:AddToggle("AutoSubmit", { Text = "Press enter when done", Default = S.AutoSubmit, Callback = function(v)
        S.AutoSubmit = v
    end })

    local Filter = Tab:AddLeftGroupbox("Word filters", "filter")
    Filter:AddToggle("SkipOddWords", {
        Text = "Skip odd-looking words",
        Default = S.SkipOddWords,
        Tooltip = "No vowels, a letter three times in a row, or six consonants in a row: usually abbreviations the game rejects",
        Callback = function(v)
            S.SkipOddWords = v
        end,
    })
    Filter:AddInput("AvoidLetters", {
        Text = "Never use letters",
        Default = "",
        Placeholder = "e.g. q z",
        Finished = true,
        Callback = function(v)
            S.AvoidLetters = v or ""
            refreshFilters()
        end,
    })
    Filter:AddInput("AvoidEndings", {
        Text = "Never end with",
        Default = "",
        Placeholder = "e.g. s, ing, e",
        Finished = true,
        Callback = function(v)
            S.AvoidEndings = v or ""
            refreshFilters()
        end,
    })
    Filter:AddInput("BannedWords", {
        Text = "Never use these words",
        Default = "",
        Placeholder = "word, word",
        Finished = true,
        Callback = function(v)
            S.BannedWords = v or ""
            refreshFilters()
        end,
    })
    Filter:AddInput("FavoriteWords", {
        Text = "Always use these when they fit",
        Default = "",
        Placeholder = "word, word",
        Finished = true,
        Callback = function(v)
            S.FavoriteWords = v or ""
            refreshFilters()
        end,
    })
    Filter:AddToggle("IgnoreFiltersIfStuck", {
        Text = "Drop the filters if nothing fits",
        Default = S.IgnoreFiltersIfStuck,
        Callback = function(v)
            S.IgnoreFiltersIfStuck = v
        end,
    })

    local Timing = Tab:AddRightGroupbox("Timing", "timer")
    Timing:AddSlider("WaitUntilLeft", {
        Text = "Answer when time left is",
        Default = S.WaitUntilLeft,
        Min = 0,
        Max = 14,
        Suffix = " s",
        Tooltip = "0 answers right away. Otherwise holds the word until this much time is left (never too late to type it)",
        Callback = function(v)
            S.WaitUntilLeft = v
        end,
    })
    Timing:AddSlider("ThinkPerLetter", {
        Text = "Extra think time per letter",
        Default = S.ThinkPerLetter,
        Min = 0,
        Max = 400,
        Suffix = " ms",
        Callback = function(v)
            S.ThinkPerLetter = v
        end,
    })
    Timing:AddSlider("PauseChance", {
        Text = "Pause mid-word chance",
        Default = S.PauseChance,
        Min = 0,
        Max = 40,
        Suffix = "%",
        Callback = function(v)
            S.PauseChance = v
        end,
    })
    Timing:AddSlider("PauseMin", { Text = "Pause length (min)", Default = S.PauseMin, Min = 50, Max = 2000, Suffix = " ms", Callback = function(v)
        S.PauseMin = v
    end })
    Timing:AddSlider("PauseMax", { Text = "Pause length (max)", Default = S.PauseMax, Min = 50, Max = 3000, Suffix = " ms", Callback = function(v)
        S.PauseMax = v
    end })
    Timing:AddSlider("TypoFixDelay", { Text = "Time to notice a typo", Default = S.TypoFixDelay, Min = 50, Max = 1500, Suffix = " ms", Callback = function(v)
        S.TypoFixDelay = v
    end })
    Timing:AddSlider("SubmitMin", { Text = "Wait before enter (min)", Default = S.SubmitMin, Min = 0, Max = 2000, Suffix = " ms", Callback = function(v)
        S.SubmitMin = v
    end })
    Timing:AddSlider("SubmitMax", { Text = "Wait before enter (max)", Default = S.SubmitMax, Min = 0, Max = 3000, Suffix = " ms", Callback = function(v)
        S.SubmitMax = v
    end })
    Timing:AddSlider("MaxTries", {
        Text = "Tries per turn",
        Default = S.MaxTries,
        Min = 1,
        Max = 5,
        Tooltip = "How many words to try before giving up on a turn (the game allows 5)",
        Callback = function(v)
            S.MaxTries = v
        end,
    })

    local Obo = Tab:AddLeftGroupbox("One By One", "list-ordered")
    Obo:AddToggle("AutoOneByOne", { Text = "Auto letter", Default = false, Callback = function(v)
        S.AutoOneByOne = v
    end })
    Obo:AddDropdown("ObOStrategy", {
        Text = "Strategy",
        Values = { "Win, else safe", "Most options" },
        Default = S.ObOStrategy,
        Tooltip = "Win, else safe: finishes a word when it can, otherwise avoids letting the next player finish",
        Callback = function(v)
            S.ObOStrategy = v or "Win, else safe"
        end,
    })
    Obo:AddSlider("ObOMinLength", { Text = "Shortest word that counts", Default = S.ObOMinLength, Min = 2, Max = 6, Callback = function(v)
        S.ObOMinLength = v
    end })

    local First = Tab:AddRightGroupbox("Starting letter", "a-large-small")
    First:AddToggle("AutoFirstLetter", { Text = "Auto pick", Default = false, Callback = function(v)
        S.AutoFirstLetter = v
    end })
    First:AddDropdown("FirstLetterStyle", {
        Text = "Pick",
        Values = { "Easiest", "Hardest", "Random" },
        Default = S.FirstLetterStyle,
        Tooltip = "Easiest has the most words, hardest the fewest",
        Callback = function(v)
            S.FirstLetterStyle = v or "Easiest"
        end,
    })

    local Suggest = Tab:AddLeftGroupbox("Suggestions", "lightbulb")
    Suggest:AddToggle("ShowSuggestions", { Text = "Show suggestions", Default = S.ShowSuggestions, Callback = function(v)
        S.ShowSuggestions = v
    end })
    UI.Suggestions = Suggest:AddLabel("-", true)
    Suggest:AddButton("Type the best one", function()
        if Match.player ~= LocalPlayer.Name then
            notify("Last Letter", "It's not your turn", 2)
            return
        end
        Turn.gen += 1
        local gen = Turn.gen
        Turn.prefix = string.upper(Match.prefix or "")
        if Turn.s2 == "" or not Turn.active then
            Turn.autoPrefix = nil
            Turn.autoPrefix = autoTypePrefix()
            Turn.s2 = Turn.autoPrefix and Turn.prefix or ""
        end
        Turn.deadline = os.clock() + (timeLeft() or 10)
        task.spawn(function()
            local word = pickWord(Turn.prefix)
            if word then
                Turn.word = word
                typeWord(word, gen)
            end
        end)
    end)

    local Ability = Tab:AddRightGroupbox("Ability", "zap")
    Ability:AddToggle("AutoAbility", { Text = "Auto ability", Default = false, Callback = function(v)
        S.AutoAbility = v
    end })
    Ability:AddSlider("AbilityTime", {
        Text = "Use when time left below",
        Default = S.AbilityTime,
        Min = 1,
        Max = 10,
        Suffix = " s",
        Tooltip = "For abilities that help you (+7 seconds, Reset...)",
        Callback = function(v)
            S.AbilityTime = v
        end,
    })
    Ability:AddToggle("AbilityOnStuck", { Text = "Use when no word fits", Default = S.AbilityOnStuck, Callback = function(v)
        S.AbilityOnStuck = v
    end })
    Ability:AddToggle("AbilityOthers", {
        Text = "Use on others' turns",
        Default = false,
        Tooltip = "For abilities aimed at the next player (Mess up, Reverse word...)",
        Callback = function(v)
            S.AbilityOthers = v
        end,
    })
    Ability:AddSlider("AbilityOthersDelay", { Text = "Wait into their turn", Default = S.AbilityOthersDelay, Min = 0, Max = 10, Suffix = " s", Callback = function(v)
        S.AbilityOthersDelay = v
    end })
end

do -- Traps
    local Tab = Window:AddTab("Traps", "target", "Endings that leave the next player few answers")

    local Use = Tab:AddLeftGroupbox("Traps", "target")
    Use:AddToggle("UseTraps", {
        Text = "Use traps when auto typing",
        Default = false,
        Tooltip = "Picks the word whose ending leaves the next player the fewest answers",
        Callback = function(v)
            S.UseTraps = v
        end,
    })
    Use:AddToggle("RespectSeen", {
        Text = "Only lengths seen this match",
        Default = S.RespectSeen,
        Tooltip = "Doesn't use 2-4 letter traps until a prefix that long has shown up",
        Callback = function(v)
            S.RespectSeen = v
            Traps.dirty = true
        end,
    })
    Use:AddToggle("ResetOnLife", {
        Text = "Reset lengths when a life is lost",
        Default = S.ResetOnLife,
        Callback = function(v)
            S.ResetOnLife = v
        end,
    })
    Use:AddSlider("TrapLength", {
        Text = "Trap length",
        Default = S.TrapLength,
        Min = 1,
        Max = 4,
        Suffix = " letters",
        Tooltip = "Longest ending to look at, for using and showing traps",
        Callback = function(v)
            S.TrapLength = v
            Traps.dirty = true
        end,
    })
    Use:AddSlider("TrapMinAnswers", {
        Text = "Fewest answers",
        Default = S.TrapMinAnswers,
        Min = 1,
        Max = 10,
        Tooltip = "The game won't give a prefix with fewer than 3 answers, so 3 is the safe floor",
        Callback = function(v)
            S.TrapMinAnswers = v
            Traps.dirty = true
        end,
    })
    Use:AddSlider("TrapMaxAnswers", { Text = "Most answers", Default = S.TrapMaxAnswers, Min = 1, Max = 100, Callback = function(v)
        S.TrapMaxAnswers = v
        Traps.dirty = true
    end })
    Use:AddSlider("TrapMinEnds", {
        Text = "Words ending in it",
        Default = S.TrapMinEnds,
        Min = 1,
        Max = 50,
        Tooltip = "Only endings with at least this many words that end in them",
        Callback = function(v)
            S.TrapMinEnds = v
            Traps.dirty = true
        end,
    })
    Use:AddToggle("HardEndings", {
        Text = "No trap? Use the hardest ending",
        Default = S.HardEndings,
        Tooltip = "When nothing is under the answer limit, still pick the word that leaves the fewest answers",
        Callback = function(v)
            S.HardEndings = v
        end,
    })
    UI.SeenLabel = Use:AddLabel("Prefix lengths seen: 1", true)

    local List = Tab:AddRightGroupbox("Trap list", "list")
    List:AddToggle("ShowTraps", { Text = "Show traps", Default = S.ShowTraps, Callback = function(v)
        S.ShowTraps = v
    end })
    List:AddToggle("TrapsUsableOnly", {
        Text = "Only ones you can use now",
        Default = false,
        Tooltip = "Endings reachable from the current letters, with a word to get there",
        Callback = function(v)
            S.TrapsUsableOnly = v
            Traps.dirty = true
        end,
    })
    UI.TrapPage = List:AddLabel("Page 1 / 1", false)
    UI.TrapList = List:AddLabel("-", true)
    List:AddButton({
        Text = "Previous",
        Func = function()
            Traps.page = math.max(1, Traps.page - 1)
        end,
    }):AddButton({
        Text = "Next",
        Func = function()
            Traps.page += 1
        end,
    })
end

do -- Lobby
    local Tab = Window:AddTab("Lobby", "armchair", "Tables, rewards and codes")

    local Join = Tab:AddLeftGroupbox("Auto join", "log-in")
    Join:AddToggle("AutoJoin", {
        Text = "Auto join a table",
        Default = false,
        Tooltip = "Walks up to a table that fits and takes a seat, again after every match",
        Callback = function(v)
            S.AutoJoin = v
        end,
    })
    Join:AddDropdown("JoinModes", {
        Text = "Modes",
        Values = { "Last Letter", "One By One" },
        Default = { "Last Letter" },
        Multi = true,
        Callback = function(v)
            S.JoinModes = v
        end,
    })
    Join:AddDropdown("JoinSizes", {
        Text = "Table size",
        Values = { "2", "4", "8" },
        Default = { "2", "4", "8" },
        Multi = true,
        Callback = function(v)
            S.JoinSizes = v
        end,
    })
    Join:AddToggle("JoinPreferWaiting", {
        Text = "Prefer tables with people waiting",
        Default = S.JoinPreferWaiting,
        Callback = function(v)
            S.JoinPreferWaiting = v
        end,
    })
    Join:AddSlider("JoinEvery", { Text = "Try every", Default = S.JoinEvery, Min = 2, Max = 30, Suffix = " s", Callback = function(v)
        S.JoinEvery = v
    end })
    UI.JoinLabel = Join:AddLabel("Not joining", true)

    local Rewards = Tab:AddRightGroupbox("Rewards", "gift")
    Rewards:AddToggle("AutoDaily", { Text = "Auto claim daily reward", Default = false, Callback = function(v)
        S.AutoDaily = v
    end })
    Rewards:AddToggle("AutoTasks", {
        Text = "Auto claim tasks",
        Default = false,
        Tooltip = "Claims finished daily and weekly tasks",
        Callback = function(v)
            S.AutoTasks = v
        end,
    })
    local CodeInput = Rewards:AddInput("Codes", {
        Text = "Codes",
        Default = "",
        Placeholder = "code1, code2",
        ClearTextOnFocus = false,
    })
    Rewards:AddButton("Redeem codes", function()
        local packet = Game.remotes and Game.remotes.Redeem
        if not packet then
            notify("Codes", "Can't reach the game's remotes", 3)
            return
        end
        task.spawn(function()
            for code in string.gmatch(CodeInput.Value or "", "[^,%s]+") do
                local ok, success, message = pcall(packet.Fire, packet, code)
                logLine(string.format("Code %s: %s", code, ok and (success and "redeemed" or tostring(message)) or "failed"))
                task.wait(1)
            end
        end)
    end)

    local Watch = Tab:AddLeftGroupbox("Abilities", "zap")
    Watch:AddToggle("LogAbilities", { Text = "Log abilities used at my table", Default = S.LogAbilities, Callback = function(v)
        S.LogAbilities = v
    end })
    Watch:AddToggle("NotifyBlocked", { Text = "Notify when I'm blocked", Default = S.NotifyBlocked, Callback = function(v)
        S.NotifyBlocked = v
    end })
end

do -- Staff
    local Tab = Window:AddTab("Staff", "shield-alert", "Who's watching")
    local Detect = Tab:AddLeftGroupbox("Detection", "scan-eye")
    Detect:AddToggle("StaffDetect", { Text = "Detect staff", Default = S.StaffDetect, Callback = function(v)
        S.StaffDetect = v
    end })
    Detect:AddToggle("StaffAttribute", { Text = "Moderator tag", Default = S.StaffAttribute, Callback = function(v)
        S.StaffAttribute = v
    end })
    Detect:AddToggle("StaffManager", { Text = "The manager", Default = S.StaffManager, Callback = function(v)
        S.StaffManager = v
    end })
    Detect:AddSlider("StaffGroupRank", {
        Text = "Game group rank at least",
        Default = S.StaffGroupRank,
        Min = 1,
        Max = 255,
        Tooltip = "2 is tester, 255 is the owner",
        Callback = function(v)
            S.StaffGroupRank = v
        end,
    })

    local Act = Tab:AddRightGroupbox("When staff is here", "siren")
    Act:AddDropdown("StaffActions", {
        Text = "Do",
        Values = { "Notify", "Pause auto play", "Leave match", "Leave server" },
        Default = { "Notify", "Pause auto play" },
        Multi = true,
        Callback = function(v)
            S.StaffActions = v
        end,
    })
    UI.StaffLabel = Act:AddLabel("No staff in this server", true)
    Act:AddButton({
        Text = "Leave server",
        DoubleClick = true,
        Func = function()
            pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
        end,
    })
end

do -- Settings
    local Tab = Window:AddTab("Settings", "settings", "Dictionary and the rest")
    local DictSet = Tab:AddLeftGroupbox("Dictionary", "book-open")
    DictSet:AddToggle("CacheDictionary", { Text = "Keep a copy on disk", Default = S.CacheDictionary, Callback = function(v)
        S.CacheDictionary = v
    end })
    DictSet:AddButton("Download again", function()
        loadDictionary(true)
    end)
    DictSet:AddToggle("LearnBadWords", {
        Text = "Remember rejected words",
        Default = S.LearnBadWords,
        Tooltip = "Words the server turned down are never used again, even after rejoining",
        Callback = function(v)
            S.LearnBadWords = v
        end,
    })
    DictSet:AddButton({
        Text = "Forget rejected words",
        DoubleClick = true,
        Func = function()
            Bad, BadCount = {}, 0
            saveBad()
        end,
    })
    local Misc = Tab:AddRightGroupbox("Misc", "wrench")
    Misc:AddToggle("AntiAfk", { Text = "Anti AFK", Default = S.AntiAfk, Callback = function(v)
        S.AntiAfk = v
    end })
end

--// Staff watching \\--
local function checkStaff()
    local found = {}
    for _, p in Players:GetPlayers() do
        if p ~= LocalPlayer then
            local reason = staffReason(p)
            if reason then
                table.insert(found, { player = p, reason = reason })
            end
        end
    end
    local was = Staff.present
    Staff.present = S.StaffDetect and #found > 0
    local names = {}
    for _, f in found do
        table.insert(names, f.player.DisplayName .. " (@" .. f.player.Name .. ") — " .. f.reason)
        if not Staff.list[f.player.UserId] then
            Staff.list[f.player.UserId] = true
            if S.StaffDetect then
                logLine("Staff: " .. f.player.Name .. " (" .. f.reason .. ")", Color3.fromRGB(255, 80, 80))
                if S.StaffActions.Notify then
                    notify("Staff in server", f.player.DisplayName .. " — " .. f.reason, 6)
                end
            end
        end
    end
    for userId in Staff.list do
        if not Players:GetPlayerByUserId(userId) then
            Staff.list[userId] = nil
        end
    end
    UI.StaffLabel:SetText(#names > 0 and table.concat(names, "\n") or "No staff in this server")
    if Staff.present and not was then
        if S.StaffActions["Leave match"] and Game.remotes and Game.remotes.Leave then
            task.spawn(pcall, Game.remotes.Leave.Fire, Game.remotes.Leave)
        end
        if S.StaffActions["Leave server"] then
            pcall(TeleportService.Teleport, TeleportService, game.PlaceId, LocalPlayer)
        end
    end
end

local function lookUpRank(player)
    if player == LocalPlayer or Staff.ranks[player.UserId] ~= nil then
        return
    end
    task.spawn(function()
        local ok, rank = pcall(player.GetRankInGroup, player, STAFF_GROUP)
        Staff.ranks[player.UserId] = ok and rank or 0
    end)
end
for _, p in Players:GetPlayers() do
    lookUpRank(p)
end
bind(Players.PlayerAdded, lookUpRank)

bind(LocalPlayer.Idled, function()
    if alive() and S.AntiAfk then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

--// Loops \\--
task.spawn(function()
    while alive() do
        pcall(checkStaff)
        task.wait(2)
    end
end)

-- Abilities that help you, when time runs low on your turn.
task.spawn(function()
    while alive() do
        if S.AutoAbility and not paused() and Match.player == LocalPlayer.Name and abilityUsage() == "self" then
            local left = timeLeft()
            if Turn.stuck and S.AbilityOnStuck then
                Turn.stuck = false
                useAbility("no word fits")
            elseif left and left <= S.AbilityTime and left > 0 then
                useAbility(string.format("%.1f s left", left))
            end
        end
        task.wait(0.25)
    end
end)

-- Dashboard and the trap list.
local lastPrefixShown, lastTrapKey = nil, nil
task.spawn(function()
    while alive() do
        pcall(function()
            local _, tableName = currentTable()
            local mode = currentMode()
            UI.MatchCards:SetValue("Mode", mode or "-")
            UI.MatchCards:SetValue("Table", tableName and tostring(tableName) or "lobby")
            UI.MatchCards:SetValue("Turn", Match.started and tostring(Match.turn) or "-")
            UI.MatchCards:SetValue("Letters", Match.started and string.upper(mode == "One By One" and Match.word or Match.prefix or "") or "-")
            UI.MatchCards2:SetValue("Whose turn", Match.player == LocalPlayer.Name and "You" or tostring(Match.player or "-"))
            UI.MatchCards2:SetValue("Your lives", tostring(Match.lives[LocalPlayer.UserId] or (Match.started and 2 or "-")))
            local seen = {}
            for len = 1, 6 do
                if Match.seen[len] then
                    table.insert(seen, tostring(len))
                end
            end
            UI.MatchCards2:SetValue("Prefix lengths", table.concat(seen, ","))
            UI.MatchCards2:SetValue("Hard mode", Match.turn >= HARD_MODE_TURN and "On" or ("turn " .. HARD_MODE_TURN))
            UI.SeenLabel:SetText("Prefix lengths seen: " .. table.concat(seen, ", ") .. (S.RespectSeen and ("  ·  traps up to " .. trapLengthCap()) or ""))

            local left = timeLeft()
            if left then
                UI.TimeBar:SetMax(math.max(15, left))
                UI.TimeBar:SetValue(left)
            end

            local names = {}
            for _, p in tablePlayers() do
                local lives = Match.lives[p.UserId]
                table.insert(names, p.DisplayName .. (lives and (" ♥" .. lives) or "") .. (Match.player == p.Name and " ◀" or ""))
            end
            UI.PlayersLabel:SetText(#names > 0 and ("Players: " .. table.concat(names, ",  ")) or "Players: -")

            if Dict.ready then
                UI.DictBar:SetText("Dictionary ready")
                UI.DictBar:SetMax(math.max(Dict.total, 1))
                UI.DictBar:SetValue(Dict.total)
                UI.DictCards:SetValue("Words", tostring(Dict.words))
            else
                UI.DictBar:SetText(Dict.loading and "Loading dictionary" or "Dictionary not loaded")
                UI.DictBar:SetValue(Dict.progress)
            end
            UI.DictCards:SetValue("Used this match", tostring(Match.usedCount))
            UI.DictCards:SetValue("Learned bad words", tostring(BadCount))
            UI.HookLabel:SetText((HookedWord and "Hooked into the game's answer function" or "Following turns from Rotate (no hook)")
                .. (Game.settings and "" or "  ·  game settings not found, set Starting letters by hand")
                .. (paused() and "  ·  PAUSED: staff in server" or ""))

            -- Suggestions and traps follow the current letters.
            local prefix = string.lower(Match.prefix or "")
            local trapKey = table.concat({ prefix, Match.usedCount, Match.seenMax, S.TrapLength, S.TrapMinAnswers,
                S.TrapMaxAnswers, S.TrapMinEnds, tostring(S.TrapsUsableOnly), tostring(Dict.ready) }, "|")
            if trapKey ~= lastTrapKey or Traps.dirty then
                lastTrapKey = trapKey
                Traps.dirty = false
                rebuildTraps()
            end
            UI.DictCards:SetValue("Traps found", Dict.ready and tostring(#Traps.list) or "-")

            if S.ShowSuggestions and Dict.ready and Match.started and mode ~= "One By One" and prefix ~= "" then
                if prefix ~= lastPrefixShown or Match.usedCount ~= UI.lastUsed then
                    lastPrefixShown, UI.lastUsed = prefix, Match.usedCount
                    local list = wordsWithPrefix(prefix, Match.used, S.MinLength, S.MaxLength)
                    local lines = {}
                    table.sort(list, function(a, b)
                        return #a < #b
                    end)
                    for i = 1, math.min(6, #list) do
                        local n, ending = trapOf(list[i])
                        table.insert(lines, string.upper(list[i]) .. (n and n <= S.TrapMaxAnswers and string.format("  (trap \"%s\": %d)", ending, n) or ""))
                    end
                    UI.Suggestions:SetText(#lines > 0 and table.concat(lines, "\n") or "No words left for " .. string.upper(prefix))
                end
            elseif not S.ShowSuggestions then
                UI.Suggestions:SetText("-")
            end

            if S.ShowTraps then
                local perPage = 10
                local pages = math.max(1, math.ceil(#Traps.list / perPage))
                Traps.page = math.clamp(Traps.page, 1, pages)
                local lines = {}
                for i = (Traps.page - 1) * perPage + 1, math.min(#Traps.list, Traps.page * perPage) do
                    local t = Traps.list[i]
                    local locked = S.RespectSeen and #t.e > Match.seenMax
                    table.insert(lines, string.format("%s  ·  %d answers  ·  %d words end in it%s%s",
                        string.upper(t.e), t.n, t.ends, t.example and ("  ·  " .. string.upper(t.example)) or "",
                        locked and "  (locked)" or ""))
                end
                UI.TrapPage:SetText(string.format("Page %d / %d  ·  %d traps", Traps.page, pages, #Traps.list))
                UI.TrapList:SetText(#lines > 0 and table.concat(lines, "\n") or (Dict.ready and "No traps match these settings" or "Waiting for the dictionary"))
            else
                UI.TrapList:SetText("-")
            end
        end)
        task.wait(0.25)
    end
end)

-- Auto join: the best table that fits, by the table's own prompt.
local function joinTable()
    if LocalPlayer:GetAttribute("InTable") then
        UI.JoinLabel:SetText("Seated at table " .. tostring(LocalPlayer:GetAttribute("InTable")))
        return
    end
    local tables = Workspace:FindFirstChild("Tables")
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not tables or not root then
        return
    end
    local seated = {}
    for _, p in Players:GetPlayers() do
        local t = p:GetAttribute("InTable")
        if t then
            seated[tostring(t)] = (seated[tostring(t)] or 0) + 1
        end
    end
    local best, bestScore, bestPrompt
    for _, tbl in tables:GetChildren() do
        local mode, size = tbl:GetAttribute("Gamemode"), tbl:GetAttribute("MaxPlayers")
        local billboard = tbl:FindFirstChild("Billboard")
        local prompt = billboard and billboard:FindFirstChildWhichIsA("ProximityPrompt")
        local count = seated[tbl.Name] or 0
        if prompt and prompt.Enabled and mode and S.JoinModes[mode] and size and S.JoinSizes[tostring(size)]
            and not tbl:GetAttribute("Started") and count < size then
            local pos = billboard:IsA("BasePart") and billboard.Position or tbl:GetPivot().Position
            local score = -(pos - root.Position).Magnitude / 1000
            if S.JoinPreferWaiting then
                score += count
            end
            if not bestScore or score > bestScore then
                best, bestScore, bestPrompt = tbl, score, prompt
            end
        end
    end
    if not best then
        UI.JoinLabel:SetText("No open table fits")
        return
    end
    if typeof(fireproximityprompt) ~= "function" then
        UI.JoinLabel:SetText("Your executor has no fireproximityprompt")
        return
    end
    local anchor = bestPrompt.Parent
    local pos = anchor:IsA("BasePart") and anchor.Position or best:GetPivot().Position
    root.CFrame = CFrame.new(pos + Vector3.new(0, 2, 4), pos)
    task.wait(0.35)
    pcall(fireproximityprompt, bestPrompt)
    UI.JoinLabel:SetText("Joining table " .. best.Name .. " (" .. tostring(best:GetAttribute("Gamemode")) .. ")")
end

task.spawn(function()
    while alive() do
        if S.AutoJoin and not paused() then
            pcall(joinTable)
        elseif not S.AutoJoin then
            UI.JoinLabel:SetText("Not joining")
        end
        task.wait(S.JoinEvery)
    end
end)

-- Daily reward and finished tasks, once a minute.
task.spawn(function()
    task.wait(5)
    while alive() do
        local remotes = Game.remotes
        if remotes and S.AutoDaily and remotes.UpdateDailyRewards and remotes.ClaimReward then
            pcall(function()
                local canClaim, streak = remotes.UpdateDailyRewards:Fire()
                if canClaim and streak then
                    local ok, message = remotes.ClaimReward:Fire(tostring(streak))
                    logLine(ok and ("Daily reward claimed (day " .. tostring(streak) .. ")") or ("Daily reward: " .. tostring(message)))
                end
            end)
        end
        if remotes and S.AutoTasks and remotes.ClaimTask then
            for _, kind in { "Daily", "Weekly" } do
                for index = 1, 5 do
                    local ok, claimed = pcall(remotes.ClaimTask.Fire, remotes.ClaimTask, index, kind)
                    if ok and claimed then
                        logLine(kind .. " task " .. index .. " claimed")
                    end
                    task.wait(0.3)
                end
            end
        end
        task.wait(60)
    end
end)

loadBad()
refreshFilters()
loadDictionary(false)
if not Game.remotes then
    notify("Last Letter", "Couldn't reach the game's remotes, auto play won't work", 8)
end
logLine(string.format("Loaded · remotes %s · %s", Game.remotes and "found" or "missing", HookedWord and "hooked" or "no hook"))

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    Turn.gen += 1
    for _, hook in Hooks do
        if hook.packet.OnClientInvoke == hook.wrapper then
            hook.packet.OnClientInvoke = hook.original
        end
    end
    for _, c in Connections do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(Connections)
end

Library:OnUnload(cleanup)
Genv.__LastLetterUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

--// RoChess! -- engine auto-play vs bots (XP farm), puzzle + sprint solver,
--// best-move arrow, task claims, codes and crates.
--
-- Built against a script dump of the live game (place 139717576471404, game
-- 10768845402, version 152). How the game works, and why this is built the
-- way it is:
--
--  * The game ships its own engine. ReplicatedStorage.Chess.Bot.analyse(fen,
--    ucis, seconds, depth) returns { best = "e2e4", score, mate, depth } --
--    the same call the game's own "hint" button uses in bot games. Squares go
--    through Chess.Engine.algToIndex64, which matches the index space the
--    board's findMove uses.
--
--  * The client app (ChessClient.App) is the table every page drives. Moves
--    are made with App.onBoardMove(from64, to64, promo) -- exactly what a click
--    on the board calls -- which routes to the bot game, puzzle or sprint
--    handler for whatever session is open.
--
--  * BOT GAMES are local: App.startBotGame(botId, color) builds the session,
--    the bot thinks on the client (or on the server for 1600+), and the end of
--    the game sends { type = "botResult", result = "win" }. Wins give 30 XP,
--    and levels pay tokens. So the farm just plays real games with the engine
--    and starts the next one.
--
--  * PUZZLES carry their solution in session.pz.sol; rated ("live") ones get
--    it a step at a time from the server, so the engine fills any gap. Moves
--    still go through onBoardMove, and the server checks each one.
--
--  * ONLINE GAMES are deliberately left alone. They have their own anti-engine
--    checks, and engine help against real players isn't something this hub
--    does. Every assist here turns itself off when a live online game is open.
--
--  * App.debug is never called: the app counts every call to it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(Genv.__RoChessStop) == "function" then pcall(Genv.__RoChessStop) end

local Unloaded = false

--// settings ----------------------------------------------------------------

local S = {
    -- bots
    BotFarm = false,
    Bot = "pebble",
    Color = "random",
    ThinkTime = 0.6,
    MoveDelay = 0.3,
    Requeue = true,
    -- puzzles
    SolvePuzzles = false,
    NextPuzzle = true,
    SolveRush = false,
    PuzzleThink = 1,
    -- assist
    Arrow = false,
    ArrowThink = 0.8,
    -- rewards
    ClaimTasks = false,
    AutoCrate = false,
    Crate = "pieces",
    AntiAfk = true,
}

local Stats = { Games = 0, Wins = 0, Draws = 0, Losses = 0, Puzzles = 0, Status = "idle", Eval = "-" }
local Library

--// the game's modules -------------------------------------------------------

local ChessFolder = ReplicatedStorage:WaitForChild("Chess", 30)

local function safeRequire(inst)
    if not inst then return nil end
    local ok, result = pcall(require, inst)
    return ok and result or nil
end

local Engine = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Engine"))
local Bot = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Bot"))
local Config = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Config"))
local Levels = safeRequire(ChessFolder and ChessFolder:FindFirstChild("Levels"))

-- the running App table. Found in the GC first so the module is never run a
-- second time; require is only the fallback.
local App
local function isApp(t)
    return type(t) == "table" and type(rawget(t, "onBoardMove")) == "function"
        and type(rawget(t, "startBotGame")) == "function"
        and type(rawget(t, "endLocalGame")) == "function"
end

local function findApp()
    if isApp(App) then return App end
    if typeof(getgc) == "function" then
        local ok, list = pcall(getgc, true)
        if ok and type(list) == "table" then
            for _, v in ipairs(list) do
                if isApp(v) then App = v return App end
            end
        end
    end
    local client = ReplicatedStorage:FindFirstChild("ChessClient")
    local t = safeRequire(client and client:FindFirstChild("App"))
    if isApp(t) then App = t end
    return App
end

local function session()
    local app = findApp()
    return app and app.session or nil
end

local function onlineLive(s)
    return s ~= nil and s.kind == "online" and not s.over
end

--// engine -------------------------------------------------------------------

local PROMO = { q = 5, r = 4, b = 3, n = 2 }

local function bestFor(s, seconds)
    if not (Bot and Bot.analyse) or not s or not s.ucis then return nil end
    local moves = table.clone(s.ucis)
    local ok, res = pcall(Bot.analyse, s.startFen, moves, seconds, 30)
    if ok and type(res) == "table" then return res.best, res end
    return nil
end

local function playUci(uci)
    local app = findApp()
    if not app or not Engine or type(uci) ~= "string" or #uci < 4 then return false end
    local from = Engine.algToIndex64(uci:sub(1, 2))
    local to = Engine.algToIndex64(uci:sub(3, 4))
    if not from or not to then return false end
    local promo = PROMO[uci:sub(5, 5)]
    local ok, result = pcall(app.onBoardMove, from, to, promo)
    return ok and result ~= false
end

local function myMoveReady(s)
    return s and not s.over and s.viewPly == #s.ucis and type(s.isMyTurn) == "function" and s:isMyTurn()
end

local function describeScore(res)
    if type(res) ~= "table" then return "-" end
    if res.mate then return ("mate in %d"):format(math.abs(res.mate)) end
    if type(res.score) == "number" then return ("%+.2f"):format(res.score / 100) end
    return "-"
end

--// bot farm -----------------------------------------------------------------

local Counted = setmetatable({}, { __mode = "k" })

local function countResult(s)
    if Counted[s] or not s.over or not s.result then return end
    Counted[s] = true
    Stats.Games += 1
    if s.result == "1/2-1/2" then
        Stats.Draws += 1
    elseif (s.result == "1-0") == (s.myColor == 1) then
        Stats.Wins += 1
    else
        Stats.Losses += 1
    end
end

local function startBotGame()
    local app = findApp()
    if not app then return end
    local s = app.session
    if onlineLive(s) or app.searching then return end
    local color = S.Color ~= "random" and S.Color or nil
    pcall(app.startBotGame, S.Bot, color)
end

task.spawn(function()
    local lastEnd
    while not Unloaded do
        if S.BotFarm then
            local s = session()
            if s and s.kind == "bot" then
                if s.over then
                    countResult(s)
                    lastEnd = lastEnd or os.clock()
                    if S.Requeue and os.clock() - lastEnd > 2 then
                        lastEnd = nil
                        Stats.Status = "starting next game"
                        startBotGame()
                    end
                elseif myMoveReady(s) then
                    Stats.Status = "thinking"
                    local best = bestFor(s, S.ThinkTime)
                    if best and session() == s and myMoveReady(s) then
                        task.wait(S.MoveDelay)
                        if session() == s and myMoveReady(s) then
                            playUci(best)
                            Stats.Status = "played " .. best
                        end
                    end
                else
                    Stats.Status = "bot is thinking"
                end
            elseif not onlineLive(s) then
                Stats.Status = "starting a bot game"
                startBotGame()
                task.wait(1.5)
            else
                Stats.Status = "online game open: farm paused"
            end
        end
        task.wait(0.15)
    end
end)

--// puzzles ------------------------------------------------------------------

local function puzzleMove(s)
    local pz = s.pz
    local known = pz and pz.sol and pz.sol[pz.step]
    if type(known) == "string" and Engine then
        local probe = Engine.new(s.startFen)
        local legal = true
        for _, u in ipairs(s.ucis) do
            local mv = probe:moveFromUci(u)
            if not mv then legal = false break end
            probe:makeMove(mv)
        end
        if legal and probe:moveFromUci(known) then return known end
    end
    return (bestFor(s, S.PuzzleThink))
end

local function nextPuzzle()
    local app = findApp()
    if not app or app.inLiveGame() then return end
    pcall(app.goHome)
    task.wait(0.3)
    pcall(app.openPuzzles)
end

task.spawn(function()
    local solvedAt
    while not Unloaded do
        local s = session()
        local kind = s and s.kind
        if (kind == "puzzle" and S.SolvePuzzles) or (kind == "rush" and S.SolveRush) then
            local pz = s.pz
            if pz and (pz.done or pz.wrong) then
                if not pz.__counted then
                    pz.__counted = true
                    if pz.outcome == "solved" then Stats.Puzzles += 1 end
                end
                if kind == "puzzle" and S.NextPuzzle then
                    solvedAt = solvedAt or os.clock()
                    if os.clock() - solvedAt > 1.2 then
                        solvedAt = nil
                        nextPuzzle()
                    end
                end
            elseif pz and not pz.busy and not pz.wrong and myMoveReady(s) then
                local mv = puzzleMove(s)
                if mv and session() == s and not pz.busy and myMoveReady(s) then
                    playUci(mv)
                end
            end
        elseif kind ~= "puzzle" then
            solvedAt = nil
        end
        task.wait(0.2)
    end
end)

--// best-move arrow ----------------------------------------------------------

local ARROW_KINDS = { bot = true, puzzle = true, rush = true, analysis = true }
local ArrowShown = false

local function clearArrow()
    local app = findApp()
    if ArrowShown and app and app.board then pcall(app.board.setArrow, app.board, "hint", nil) end
    ArrowShown = false
end

task.spawn(function()
    local lastKey
    while not Unloaded do
        local s = session()
        if S.Arrow and s and ARROW_KINDS[s.kind] and not s.over and Engine then
            local key = tostring(s) .. ":" .. #s.ucis
            if key ~= lastKey then
                lastKey = key
                local best, res = bestFor(s, S.ArrowThink)
                local app = findApp()
                if best and app and app.board and session() == s and #s.ucis == tonumber(key:match(":(%d+)$")) then
                    local from = Engine.algToIndex64(best:sub(1, 2))
                    local to = Engine.algToIndex64(best:sub(3, 4))
                    pcall(app.board.setArrow, app.board, "hint", from, to, Color3.fromRGB(90, 170, 255), 0.15)
                    ArrowShown = true
                    Stats.Eval = best .. "  (" .. describeScore(res) .. ")"
                end
            end
        else
            lastKey = nil
            if ArrowShown then clearArrow() end
            if s and s.kind == "online" then Stats.Eval = "off in online games" end
        end
        task.wait(0.25)
    end
end)

--// rewards ------------------------------------------------------------------

local TASK_IDS = { "play", "win", "capture" }
if Config and type(Config.DAILY_TASKS) == "table" then
    TASK_IDS = {}
    for _, t in ipairs(Config.DAILY_TASKS) do TASK_IDS[#TASK_IDS + 1] = t.id end
end

local function request(payload)
    local app = findApp()
    if not app or type(app.request) ~= "function" then return nil end
    local ok, res = pcall(app.request, payload)
    return ok and res or nil
end

local function claimTasks()
    for _, id in ipairs(TASK_IDS) do request({ type = "claimTask", id = id }) end
end

task.spawn(function()
    while not Unloaded do
        if S.ClaimTasks then claimTasks() end
        task.wait(30)
    end
end)

local function codesFromNote()
    local note = ChessFolder and ChessFolder:GetAttribute("CodesNote")
    local found = {}
    if type(note) == "string" then
        -- codes are written in caps, digits allowed ("5000LIKES"); skip plain
        -- numbers and short words like "A".
        for word in note:gmatch("%f[%w][%u%d]+%f[%W]") do
            if #word >= 5 and word:find("%u") then found[#found + 1] = word end
        end
    end
    return found
end

local function redeem(code)
    if type(code) ~= "string" or code == "" then return nil end
    return request({ type = "redeemCode", code = code })
end

local CRATES = { "pieces", "board", "effect", "background", "accessory", "halloween" }

task.spawn(function()
    while not Unloaded do
        if S.AutoCrate then
            local res = request({ type = "openCrate", crate = S.Crate })
            if type(res) ~= "table" or not res.ok then S.AutoCrate = false end
        end
        task.wait(3)
    end
end)

--// anti-AFK -----------------------------------------------------------------

local IdleOff = {}
local function setAntiAfk(on)
    if typeof(getconnections) ~= "function" then return false end
    local ok, list = pcall(getconnections, LocalPlayer.Idled)
    if not ok or type(list) ~= "table" then return false end
    if on then
        for _, c in ipairs(list) do pcall(function() c:Disable() IdleOff[#IdleOff + 1] = c end) end
    else
        for _, c in ipairs(IdleOff) do pcall(function() c:Enable() end) end
        table.clear(IdleOff)
    end
    return true
end
task.delay(3, function() if S.AntiAfk and not Unloaded then setAntiAfk(true) end end)

--// teardown -----------------------------------------------------------------

local function unload()
    if Unloaded then return end
    Unloaded = true
    pcall(setAntiAfk, false)
    pcall(clearArrow)
end

Genv.__RoChessStop = function()
    unload()
    if Library then pcall(function() Library:Unload() end) end
end

--// ui -----------------------------------------------------------------------

local okLib, lib = pcall(function()
    return loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua'))()
end)
if not okLib or type(lib) ~= "table" then return end
Library = lib

local Window = Library:CreateWindow({
    Title = 'RoChess',
    Footer = 'engine vs bots',
    Icon = 'crown',
    ToggleKeybind = Enum.KeyCode.RightShift,
    Theme = 'Ember',
    ConfigFolder = 'RoChess',
})

Library:OnUnload(unload)

local function every(interval, fn)
    task.spawn(function()
        while not Unloaded and not Library.Unloaded do
            pcall(fn)
            task.wait(interval)
        end
    end)
end

local function toggle(box, id, text, key, tooltip, onChange)
    return box:AddToggle(id, {
        Text = text,
        Tooltip = tooltip,
        Default = S[key],
        Callback = function(v)
            S[key] = v
            if onChange then onChange(v) end
        end,
    })
end

local BOT_NAMES, BOT_BY_LABEL, BOT_DEFAULT = {}, {}, nil
for _, b in ipairs(Config and Config.BOTS or {}) do
    local label = ("%s (%d)"):format(b.name or b.id, b.rating or 0)
    BOT_NAMES[#BOT_NAMES + 1] = label
    BOT_BY_LABEL[label] = b.id
    if b.id == S.Bot then BOT_DEFAULT = label end
end

--// Bots tab -----------------------------------------------------------------

do
    local Tab = Window:AddTab('Bots', 'bot', 'Engine plays the bots for XP')

    local overview = Tab:AddBigGroupbox('Overview', 'gauge')
    local cards = overview:AddStatCards('rc_cards', {
        Cards = {
            { Title = 'Level', Value = '-', Icon = 'star' },
            { Title = 'Wins', Value = '0', Icon = 'trophy' },
            { Title = 'Games', Value = '0', Icon = 'swords' },
            { Title = 'Puzzles', Value = '0', Icon = 'puzzle' },
        },
    })
    local info = overview:AddLabel('-', true)
    every(0.5, function()
        local app = findApp()
        local profile = app and app.profile
        local xp = profile and tonumber(profile.xp)
        if xp and Levels and Levels.of then
            local level, into, need = Levels.of(xp)
            cards:SetValue('Level', ("%d  (%d/%d)"):format(level, into, need))
        end
        cards:SetValue('Wins', tostring(Stats.Wins))
        cards:SetValue('Games', ("%d  (%dW %dD %dL)"):format(Stats.Games, Stats.Wins, Stats.Draws, Stats.Losses))
        cards:SetValue('Puzzles', tostring(Stats.Puzzles))
        local s = app and app.session
        info:SetText(("%s\nsession: %s\nengine: %s"):format(
            app and Stats.Status or "waiting for the game to load",
            s and (s.kind .. (s.over and " (over)" or "")) or "none", Stats.Eval))
    end)

    local farm = Tab:AddLeftGroupbox('Bot farm', 'cpu')
    farm:AddLabel('Plays real games against the bot you pick with the game\'s own engine, then starts the next one. Wins pay 30 XP; levels pay tokens. Bots up to 1500 are beaten reliably; 1600+ run on the server engine and are much tougher.', true)
    toggle(farm, 'rc_farm', 'Auto play vs bot', 'BotFarm', 'starts a bot game, plays your moves, and requeues when it ends')
        :AddKeyPicker('rc_farm_key', { Default = 'None', Mode = 'Toggle', SyncToggleState = true, Text = 'Bot farm' })
    farm:AddDropdown('rc_bot', {
        Values = BOT_NAMES,
        Default = BOT_DEFAULT or BOT_NAMES[1],
        Text = 'Opponent',
        Callback = function(v) S.Bot = BOT_BY_LABEL[v] or S.Bot end,
    })
    farm:AddDropdown('rc_color', {
        Values = { 'random', 'white', 'black' },
        Default = S.Color,
        Text = 'Play as',
        Callback = function(v) S.Color = v end,
    })
    toggle(farm, 'rc_requeue', 'Start the next game automatically', 'Requeue')

    local engine = Tab:AddRightGroupbox('Engine', 'brain')
    engine:AddSlider('rc_think', { Text = 'Think time', Tooltip = 'longer is stronger; weak bots need very little', Min = 0.1, Max = 3, Default = S.ThinkTime, Rounding = 1, Suffix = 's', Callback = function(v) S.ThinkTime = v end })
    engine:AddSlider('rc_delay', { Text = 'Extra delay per move', Min = 0, Max = 3, Default = S.MoveDelay, Rounding = 1, Suffix = 's', Callback = function(v) S.MoveDelay = v end })
    engine:AddButton({ Text = 'Start bot game now', Func = function() task.spawn(startBotGame) end })
    engine:AddButton({
        Text = 'Play best move once',
        Func = function()
            task.spawn(function()
                local s = session()
                if s and s.kind ~= "online" and myMoveReady(s) then
                    local best = bestFor(s, S.ThinkTime)
                    if best then playUci(best) end
                end
            end)
        end,
    })
end

--// Puzzles tab --------------------------------------------------------------

do
    local Tab = Window:AddTab('Puzzles', 'puzzle', 'Puzzle and sprint solver')

    local pz = Tab:AddLeftGroupbox('Puzzles', 'puzzle')
    toggle(pz, 'rc_puzzles', 'Auto solve puzzles', 'SolvePuzzles', 'plays the puzzle\'s solution, or the engine\'s move where the server hasn\'t sent it yet')
    toggle(pz, 'rc_nextpz', 'Load the next puzzle', 'NextPuzzle')
    pz:AddButton({ Text = 'Open puzzles', Func = function() local app = findApp() if app then pcall(app.openPuzzles) end end })
    pz:AddSlider('rc_pzthink', { Text = 'Engine time (rated puzzles)', Min = 0.3, Max = 3, Default = S.PuzzleThink, Rounding = 1, Suffix = 's', Callback = function(v) S.PuzzleThink = v end })

    local rush = Tab:AddRightGroupbox('Puzzle sprint', 'zap')
    rush:AddLabel('Open the sprint page and press Start; this solves each puzzle as it appears.', true)
    toggle(rush, 'rc_rush', 'Auto solve sprint', 'SolveRush')
    rush:AddButton({ Text = 'Open sprint', Func = function() local app = findApp() if app then pcall(app.openRush) end end })
end

--// Assist tab ---------------------------------------------------------------

do
    local Tab = Window:AddTab('Assist', 'lightbulb', 'Best-move arrow')

    local box = Tab:AddLeftGroupbox('Best move', 'arrow-up-right')
    box:AddLabel('Draws the engine\'s best move on the board in bot games, puzzles and the analysis board. Off in live online games.', true)
    toggle(box, 'rc_arrow', 'Best-move arrow', 'Arrow', nil, function(v) if not v then clearArrow() end end)
    box:AddSlider('rc_arrowthink', { Text = 'Think time', Min = 0.2, Max = 3, Default = S.ArrowThink, Rounding = 1, Suffix = 's', Callback = function(v) S.ArrowThink = v end })
    local eval = box:AddLabel('-', true)
    every(0.5, function() eval:SetText('best: ' .. Stats.Eval) end)
end

--// Rewards tab --------------------------------------------------------------

do
    local Tab = Window:AddTab('Rewards', 'gift', 'Tasks, codes, crates')

    local tasks = Tab:AddLeftGroupbox('Daily tasks', 'list-checks')
    toggle(tasks, 'rc_tasks', 'Auto claim tasks', 'ClaimTasks', 'claims play / win / capture rewards as they finish (the bot farm completes them)', function(v) if v then task.spawn(claimTasks) end end)
    tasks:AddButton({ Text = 'Claim now', Func = function() task.spawn(claimTasks) end })

    local codes = Tab:AddRightGroupbox('Codes', 'ticket')
    local codeResult = codes:AddLabel('', true)
    codes:AddButton({
        Text = 'Redeem codes from the game',
        Func = function()
            task.spawn(function()
                local list = codesFromNote()
                if #list == 0 then codeResult:SetText('no code in the game\'s note right now') return end
                local out = {}
                for _, c in ipairs(list) do
                    local res = redeem(c)
                    out[#out + 1] = c .. ': ' .. (type(res) == "table" and (res.ok and 'ok' or tostring(res.error or res.msg or 'refused')) or 'no reply')
                end
                codeResult:SetText(table.concat(out, '\n'))
            end)
        end,
    })
    local typed = ''
    codes:AddInput('rc_code', { Text = 'Code', Default = '', Placeholder = 'type a code', Callback = function(v) typed = v end })
    codes:AddButton({
        Text = 'Redeem typed code',
        Func = function()
            task.spawn(function()
                local res = redeem(typed)
                codeResult:SetText(typed .. ': ' .. (type(res) == "table" and (res.ok and 'ok' or tostring(res.error or res.msg or 'refused')) or 'no reply'))
            end)
        end,
    })

    local crates = Tab:AddLeftGroupbox('Crates', 'package')
    crates:AddLabel('Spends tokens (10 per crate). Stops on its own when you run out.', true)
    crates:AddDropdown('rc_crate', { Values = CRATES, Default = S.Crate, Text = 'Crate', Callback = function(v) S.Crate = v end })
    toggle(crates, 'rc_autocrate', 'Auto open crates', 'AutoCrate')

    local idle = Tab:AddRightGroupbox('Idle', 'clock')
    idle:AddToggle('rc_afk', {
        Text = 'Anti-AFK',
        Tooltip = 'stops the 20 minute idle kick while the farm runs',
        Default = S.AntiAfk,
        Callback = function(v) S.AntiAfk = v setAntiAfk(v) end,
    })
end

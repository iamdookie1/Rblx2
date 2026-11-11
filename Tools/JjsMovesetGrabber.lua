--// JJS moveset code grabber ------------------------------------------------
-- Run it in your own private server with build mode on. It saves the data of
-- every Character / Moveset / Special / Awakening block, as a moveset code
-- (the same text the builder's Export button gives) and as readable JSON.
--
-- How the game keeps it (from the build tools' own scripts):
--   * every builder block is a child of workspace.Logic, named after its type;
--   * a block's moves are a JSON string in its "Dict" attribute;
--   * the builder saves edits with
--       Remotes.BuildEvent:FireServer("LogicProp", blocks, "Dict", zstd(json))
--     ("Dict2" sends one skill: { index, zstd(json) });
--   * a moveset code is ReplicatedStorage.Modules.Base64.to_base64(json).
--
-- It keeps watching: anything you build or change while it runs is saved too.
-- Files go to the executor's workspace folder, in jjs_movesets/.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local FOLDER = "jjs_movesets"
local TYPES = { Character = true, Moveset = true, Special = true, Awakening = true }

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__JjsGrabberStop then
    pcall(Genv.__JjsGrabberStop)
end
local running = true
local connections = {}

local function note(text)
    print("[moveset grabber] " .. text)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
        Title = "Moveset grabber", Text = text, Duration = 7,
    })
end

local function copy(text)
    for _, fn in { rawget(Genv, "setclipboard") or setclipboard, rawget(Genv, "toclipboard") or toclipboard } do
        if typeof(fn) == "function" and pcall(fn, text) then
            return true
        end
    end
    return false
end

local okModule, Base64 = pcall(require, ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Base64"))
if not okModule then
    note("couldn't load the game's Base64 module: " .. tostring(Base64))
    return
end

if typeof(makefolder) == "function" and not (typeof(isfolder) == "function" and isfolder(FOLDER)) then
    pcall(makefolder, FOLDER)
end

-- Returns readable JSON from either plain JSON or the builder's compressed form.
local function asJson(data)
    if type(data) ~= "string" or #data < 2 then
        return nil
    end
    if pcall(HttpService.JSONDecode, HttpService, data) then
        return data
    end
    local okRaw, raw = pcall(Base64.from_zstd, data)
    if okRaw and type(raw) == "string" and pcall(HttpService.JSONDecode, HttpService, raw) then
        return raw
    end
    return nil
end

local seen = {}
local count = 0
local function save(kind, label, data)
    local json = asJson(data)
    if not json or json == "[]" or json == "{}" or seen[json] then
        return
    end
    seen[json] = true
    count += 1
    local code = Base64.to_base64(json)
    local base = ("%s/%d_%s_%s"):format(FOLDER, count, kind, (tostring(label):gsub("[^%w]", "")))
    local wrote = typeof(writefile) == "function"
        and pcall(writefile, base .. ".txt", code)
        and pcall(writefile, base .. ".json", json)
    local copied = copy(code)
    note(("%s \"%s\" saved, %d characters.%s%s"):format(kind, tostring(label), #code,
        copied and " Code copied." or "",
        wrote and (" Files: " .. base .. ".txt / .json") or " (no writefile, check the console)"))
    if not wrote then
        print(code)
    end
end

-- Blocks already in the world, and any added or edited later.
local function watchBlock(block)
    if not TYPES[block.Name] then
        return
    end
    local function grab()
        if running then
            save(block.Name, block:GetAttribute("MoveName") or block:GetAttribute("MoveNameFt") or block.Name, block:GetAttribute("Dict"))
        end
    end
    grab()
    table.insert(connections, block:GetAttributeChangedSignal("Dict"):Connect(grab))
end

local logic = workspace:FindFirstChild("Logic")
if logic then
    for _, block in logic:GetChildren() do
        watchBlock(block)
    end
    table.insert(connections, logic.ChildAdded:Connect(function(block)
        task.wait(0.5)
        watchBlock(block)
    end))
end

-- What the builder sends when you edit, in case a block's attribute is late.
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
local buildEvent = remotes and remotes:FindFirstChild("BuildEvent")
if buildEvent and typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" and not Genv.__JjsGrabberHooked then
    Genv.__JjsGrabberHooked = true
    local old
    local function handler(self, ...)
        if self == buildEvent and getnamecallmethod() == "FireServer" then
            local action, _, key, value = ...
            local sink = Genv.__JjsGrabberSink
            if sink and action == "LogicProp" and (key == "Dict" or key == "Dict2") then
                task.spawn(sink, key, value)
            end
        end
        return old(self, ...)
    end
    local wrap = typeof(newcclosure) == "function" and newcclosure or function(f)
        return f
    end
    pcall(function()
        old = hookmetamethod(game, "__namecall", wrap(handler))
    end)
end
Genv.__JjsGrabberSink = function(key, value)
    if not running then
        return
    end
    if key == "Dict2" and type(value) == "table" then
        save("Skill", "slot" .. tostring(value[1]), value[2])
    else
        save("Edit", "sent", value)
    end
end

Genv.__JjsGrabberStop = function()
    running = false
    Genv.__JjsGrabberSink = nil
    for _, c in connections do
        pcall(c.Disconnect, c)
    end
end

if count == 0 then
    note("No moveset blocks yet. In build mode place a Character (or Moveset) block, open it, add a skill and change something: it's saved the moment you do.")
else
    note(("Saved %d block(s). Still watching for more."):format(count))
end

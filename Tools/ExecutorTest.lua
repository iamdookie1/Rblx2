local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")

local SEP = string.rep("=", 80)

--// Decompiler diagnostic -------------------------------------------------------
-- The actual question this section answers: is decompile() missing/erroring, or
-- is it running fine and just giving up on the bytecode it's handed? Those look
-- identical from a script dump (every entry just says "panicked") but point at
-- completely different problems - one is "your executor doesn't have this",
-- the other is "your executor's decompiler is stale for the current Luau
-- bytecode version". Roblox's own PlayerModule is the canary: it ships with
-- every game, unmodified, never developer-obfuscated. If decompile can't
-- produce real Lua from that, the decompiler itself is what's broken, not
-- whatever game you last dumped.
local function findCanaryScript()
    local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
    local candidates = {
        playerScripts and playerScripts:FindFirstChild("PlayerModule", true),
        StarterPlayer:FindFirstChild("StarterPlayerScripts")
            and StarterPlayer.StarterPlayerScripts:FindFirstChild("PlayerModule", true),
    }
    for _, inst in ipairs(candidates) do
        if inst then return inst end
    end
    -- last resort: any LocalScript/ModuleScript at all under StarterPlayerScripts
    local root = StarterPlayer:FindFirstChild("StarterPlayerScripts")
    if root then
        for _, inst in ipairs(root:GetDescendants()) do
            if inst:IsA("LocalScript") or inst:IsA("ModuleScript") then
                return inst
            end
        end
    end
    return nil
end

local function looksLikePanic(text)
    return text:lower():find("panic", 1, true) ~= nil or #text < 20
end

print(SEP)
print("DECOMPILER DIAGNOSTIC")
print(SEP)

local hasDecompile = typeof(decompile) == "function"
local hasBytecode = typeof(getscriptbytecode) == "function"
print(("decompile()          %s"):format(hasDecompile and "present" or "MISSING"))
print(("getscriptbytecode()  %s"):format(hasBytecode and "present" or "missing"))

if not hasDecompile then
    print("\nVERDICT: decompile() doesn't exist on this executor at all - that's the")
    print("whole problem, nothing to do with any specific game.")
else
    local canary = findCanaryScript()
    if not canary then
        print("\nCould not find a canary script (Roblox's own PlayerModule) to test against.")
    else
        print(("\nTarget: %s (%s)"):format(canary:GetFullName(), canary.ClassName))

        if hasBytecode then
            local bcOk, bytecode = pcall(getscriptbytecode, canary)
            if bcOk and typeof(bytecode) == "string" then
                print(("  getscriptbytecode: ok, %d bytes"):format(#bytecode))
            else
                print(("  getscriptbytecode: failed (%s)"):format(tostring(bytecode)))
            end
        end

        local ok, source = pcall(decompile, canary)
        if not ok then
            print(("  decompile: ERRORED - %s"):format(tostring(source)))
            print("\nVERDICT: decompile() throws on Roblox's own unprotected code.")
            print("That's an executor bug, not game protection.")
        elseif typeof(source) ~= "string" then
            print(("  decompile: returned a %s, not a string"):format(typeof(source)))
        elseif looksLikePanic(source) then
            print(("  decompile: ran, but gave up (%d chars back): %s"):format(#source, source:sub(1, 120)))
            print("\nVERDICT: decompile() calls succeed but can't produce real source even on")
            print("Roblox's own unmodified PlayerModule. This is a decompiler/bytecode-version")
            print("problem in your executor (it's not keeping up with a Luau bytecode change),")
            print("not protection on whatever game you dumped - it would fail on ANY game.")
            print("Check your executor's changelog/Discord for a decompiler update, or an")
            print("update to the executor itself.")
        else
            print(("  decompile: ok, %d chars, looks like real source"):format(#source))
            print("\nVERDICT: decompile works fine on unprotected code. If a specific game's")
            print("scripts still all come back panicked, that game is genuinely obfuscating")
            print("its own bytecode - that part's real, this isn't a decompiler bug.")
            print("\n----- first 300 chars -----")
            print(source:sub(1, 300))
            print("----------------------------")
        end
    end
end

--// Full capability list ---------------------------------------------------------
-- "UNC" style checklist: every widely-supported exploit function, grouped the
-- way the community groups them. Each entry is a closure so a missing parent
-- table (crypt, Drawing, WebSocket, cache - none of these are real Roblox
-- globals) doesn't error the check, it's just caught by pcall like everything
-- else.
local function check(name, fn)
    local ok, value = pcall(fn)
    return ok and value ~= nil
end

local Categories = {
    {
        "Cache", {
            { "cache.invalidate", function() return cache.invalidate end },
            { "cache.iscached", function() return cache.iscached end },
            { "cache.replace", function() return cache.replace end },
            { "cloneref", function() return cloneref end },
            { "compareinstances", function() return compareinstances end },
        },
    },
    {
        "Closures", {
            { "checkcaller", function() return checkcaller end },
            { "clonefunction", function() return clonefunction end },
            { "getcallingscript", function() return getcallingscript end },
            { "hookfunction", function() return hookfunction end },
            { "iscclosure", function() return iscclosure end },
            { "isexecutorclosure", function() return isexecutorclosure end },
            { "islclosure", function() return islclosure end },
            { "loadstring", function() return loadstring end },
            { "newcclosure", function() return newcclosure end },
        },
    },
    {
        "Console", {
            { "rconsoleclear/consoleclear", function() return rconsoleclear or consoleclear end },
            { "rconsolecreate/consolecreate", function() return rconsolecreate or consolecreate end },
            { "rconsoledestroy/consoledestroy", function() return rconsoledestroy or consoledestroy end },
            { "rconsoleinput/consoleinput", function() return rconsoleinput or consoleinput end },
            { "rconsoleprint/consoleprint", function() return rconsoleprint or consoleprint end },
            { "rconsolesettitle/consolesettitle", function() return rconsolesettitle or consolesettitle end },
        },
    },
    {
        "Crypt", {
            { "crypt.base64encode", function() return crypt.base64encode or crypt.base64.encode end },
            { "crypt.base64decode", function() return crypt.base64decode or crypt.base64.decode end },
            { "crypt.encrypt", function() return crypt.encrypt end },
            { "crypt.decrypt", function() return crypt.decrypt end },
            { "crypt.generatebytes", function() return crypt.generatebytes end },
            { "crypt.generatekey", function() return crypt.generatekey end },
            { "crypt.hash", function() return crypt.hash end },
        },
    },
    {
        "Debug", {
            { "debug.getconstant", function() return debug.getconstant end },
            { "debug.getconstants", function() return debug.getconstants end },
            { "debug.getinfo", function() return debug.getinfo end },
            { "debug.getproto", function() return debug.getproto end },
            { "debug.getprotos", function() return debug.getprotos end },
            { "debug.getstack", function() return debug.getstack end },
            { "debug.getupvalue", function() return debug.getupvalue end },
            { "debug.getupvalues", function() return debug.getupvalues end },
            { "debug.setconstant", function() return debug.setconstant end },
            { "debug.setstack", function() return debug.setstack end },
            { "debug.setupvalue", function() return debug.setupvalue end },
        },
    },
    {
        "Filesystem", {
            { "appendfile", function() return appendfile end },
            { "delfile", function() return delfile end },
            { "delfolder", function() return delfolder end },
            { "isfile", function() return isfile end },
            { "isfolder", function() return isfolder end },
            { "listfiles", function() return listfiles end },
            { "loadfile", function() return loadfile end },
            { "makefolder", function() return makefolder end },
            { "readfile", function() return readfile end },
            { "writefile", function() return writefile end },
        },
    },
    {
        "Input", {
            { "isrbxactive/isgameactive", function() return isrbxactive or isgameactive end },
            { "keypress", function() return keypress end },
            { "keyrelease", function() return keyrelease end },
            { "mouse1click", function() return mouse1click end },
            { "mouse1press", function() return mouse1press end },
            { "mouse1release", function() return mouse1release end },
            { "mouse2click", function() return mouse2click end },
            { "mouse2press", function() return mouse2press end },
            { "mouse2release", function() return mouse2release end },
            { "mousemoveabs", function() return mousemoveabs end },
            { "mousemoverel", function() return mousemoverel end },
            { "mousescroll", function() return mousescroll end },
        },
    },
    {
        "Instances", {
            { "fireclickdetector", function() return fireclickdetector end },
            { "fireproximityprompt", function() return fireproximityprompt end },
            { "firetouchinterest", function() return firetouchinterest end },
            { "getcallbackvalue", function() return getcallbackvalue end },
            { "getconnections", function() return getconnections end },
            { "getcustomasset", function() return getcustomasset end },
            { "gethiddenproperty", function() return gethiddenproperty end },
            { "gethui", function() return gethui end },
            { "getinstances", function() return getinstances end },
            { "getnilinstances", function() return getnilinstances end },
            { "isscriptable", function() return isscriptable end },
            { "sethiddenproperty", function() return sethiddenproperty end },
            { "setscriptable", function() return setscriptable end },
        },
    },
    {
        "Metatable", {
            { "getnamecallmethod", function() return getnamecallmethod end },
            { "getrawmetatable", function() return getrawmetatable end },
            { "hookmetamethod", function() return hookmetamethod end },
            { "isreadonly", function() return isreadonly end },
            { "setrawmetatable", function() return setrawmetatable end },
            { "setreadonly", function() return setreadonly end },
        },
    },
    {
        "Miscellaneous", {
            { "getthreadidentity/getidentity", function() return getthreadidentity or getidentity end },
            { "setthreadidentity/setidentity", function() return setthreadidentity or setidentity end },
            { "identifyexecutor/getexecutorname", function() return identifyexecutor or getexecutorname end },
            { "gethwid/get_hwid", function() return gethwid or get_hwid end },
            { "lz4compress", function() return lz4compress end },
            { "lz4decompress", function() return lz4decompress end },
            { "messagebox", function() return messagebox end },
            { "queue_on_teleport", function() return queue_on_teleport end },
            { "request/http_request", function() return request or http_request end },
            { "setclipboard", function() return setclipboard end },
            { "setfpscap", function() return setfpscap end },
        },
    },
    {
        "Scripts", {
            { "decompile", function() return decompile end },
            { "getgc", function() return getgc end },
            { "getgenv", function() return getgenv end },
            { "getloadedmodules", function() return getloadedmodules end },
            { "getrenv", function() return getrenv end },
            { "getrunningscripts", function() return getrunningscripts end },
            { "getscriptbytecode/dumpstring", function() return getscriptbytecode or dumpstring end },
            { "getscriptclosure/getscriptfunction", function() return getscriptclosure or getscriptfunction end },
            { "getscripthash", function() return getscripthash end },
            { "getscripts", function() return getscripts end },
            { "getsenv", function() return getsenv end },
        },
    },
    {
        "Drawing", {
            { "Drawing", function() return Drawing end },
            { "Drawing.new", function() return Drawing.new end },
            { "Drawing.Fonts", function() return Drawing.Fonts end },
            { "isrenderobj", function() return isrenderobj end },
            { "cleardrawcache", function() return cleardrawcache end },
            { "getrenderproperty", function() return getrenderproperty end },
            { "setrenderproperty", function() return setrenderproperty end },
        },
    },
    {
        "WebSocket", {
            { "WebSocket.connect", function() return WebSocket.connect end },
        },
    },
}

print("\n" .. SEP)
print("CAPABILITY CHECKLIST")
print(SEP)

local totalPass, totalCount = 0, 0
local reportLines = {}

for _, category in ipairs(Categories) do
    local name, checks = category[1], category[2]
    local pass = 0
    print(("\n-- %s --"):format(name))
    reportLines[#reportLines + 1] = "\n-- " .. name .. " --"
    for _, entry in ipairs(checks) do
        local label, fn = entry[1], entry[2]
        local ok = check(label, fn)
        if ok then pass = pass + 1 end
        local line = ("  [%s] %s"):format(ok and "OK" or "--", label)
        if ok then print(line) else warn(line) end
        reportLines[#reportLines + 1] = line
    end
    totalPass = totalPass + pass
    totalCount = totalCount + #checks
    print(("   %d/%d"):format(pass, #checks))
end

print("\n" .. SEP)
print(("SUMMARY: %d/%d functions present"):format(totalPass, totalCount))
local identifyOk, identity = pcall(function() return (identifyexecutor or getexecutorname or function() return "unknown" end)() end)
print(("Executor: %s"):format(identifyOk and tostring(identity) or "unknown (identifyexecutor/getexecutorname missing)"))
print(("Luau version: %s"):format(_VERSION or "unknown"))
print(SEP)

if typeof(writefile) == "function" then
    local report = table.concat(reportLines, "\n")
    local ok = pcall(writefile, "ExecutorTest_Report.txt", report)
    if ok then print("\nFull report also saved to ExecutorTest_Report.txt") end
end

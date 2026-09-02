local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local Config = {
    AutoDump = true,
}

local function copyToClipboard(text)
    if typeof(setclipboard) == "function" then
        setclipboard(text)
        return true
    elseif typeof(toclipboard) == "function" then
        toclipboard(text)
        return true
    elseif typeof(Clipboard) == "table" and typeof(Clipboard.set) == "function" then
        Clipboard.set(text)
        return true
    end
    return false
end

local function serializeValue(value)
    local t = typeof(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "nil" then
        return "nil"
    elseif t == "Color3" then
        return string.format("Color3.fromRGB(%d, %d, %d)",
            math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255))
    elseif t == "Vector3" then
        return string.format("Vector3.new(%s, %s, %s)", value.X, value.Y, value.Z)
    elseif t == "Vector2" then
        return string.format("Vector2.new(%s, %s)", value.X, value.Y)
    elseif t == "UDim2" then
        return string.format("UDim2.new(%s, %s, %s, %s)", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
    elseif t == "UDim" then
        return string.format("UDim.new(%s, %s)", value.Scale, value.Offset)
    elseif t == "EnumItem" then
        return tostring(value)
    elseif t == "BrickColor" then
        return string.format("BrickColor.new(%q)", value.Name)
    elseif t == "NumberRange" then
        return string.format("NumberRange.new(%s, %s)", value.Min, value.Max)
    elseif t == "Rect" then
        return string.format("Rect.new(%s, %s, %s, %s)", value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
    else
        return string.format("%q", tostring(value))
    end
end

local function getHeldTool()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Tool")
end

-- Dumps the currently held Tool's name + every attribute (sorted, so the
-- output is stable run to run) as a pasteable Lua table, then copies it.
local function dumpHeldItem()
    local tool = getHeldTool()
    if not tool then
        return nil, "not holding anything"
    end

    local attributes = tool:GetAttributes()
    local names = {}
    for name in pairs(attributes) do
        table.insert(names, name)
    end
    table.sort(names)

    local lines = {
        ("-- %s"):format(tool.Name),
        "local Attributes = {",
    }
    for _, name in ipairs(names) do
        table.insert(lines, ('    [%q] = %s,'):format(name, serializeValue(attributes[name])))
    end
    table.insert(lines, "}")

    local text = table.concat(lines, "\n")
    local copied = copyToClipboard(text)
    return text, tool.Name, #names, copied
end

local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib4.lua'))()

local Window = Centrl:Window({
    Title = 'attribute dumper',
    SubTitle = 'held item -> clipboard',
    Folder = 'AttributeDumper',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(90, 200, 140),
})

local Tab = Window:Tab({ Title = 'dumper', Icon = 'clipboard-copy' })
local Main = Tab:Section({ Title = 'main', Side = 'left' })

Main:Toggle({
    Title = 'auto dump on equip',
    Flag = 'ad_auto',
    Default = true,
    Callback = function(v) Config.AutoDump = v end,
})

Main:Keybind({
    Title = 'manual dump key',
    Flag = 'ad_key',
    Default = Enum.KeyCode.P,
    Callback = function()
        local _, name, count, copied = dumpHeldItem()
        if not name then
            Centrl:Notify({ Title = 'attribute dumper', Content = count, Type = 'warning', Duration = 3 })
            return
        end
        Centrl:Notify({
            Title = 'attribute dumper',
            Content = ('%s: %d attribute(s) %s'):format(name, count, copied and 'copied' or '(clipboard unavailable)'),
            Type = copied and 'success' or 'warning',
            Duration = 3,
        })
    end,
})

local Info = Tab:Section({ Title = 'live state', Side = 'right' })
local LastLabel = Info:Label({ Title = 'last dump: none' })

local function handleDump(reason)
    local _, name, count, copied = dumpHeldItem()
    if not name then
        return
    end
    LastLabel:Set(('last dump: %s (%d attrs)'):format(name, count))
    Centrl:Notify({
        Title = 'attribute dumper',
        Content = ('%s: %d attribute(s) %s'):format(name, count, copied and 'copied' or '(clipboard unavailable)'),
        Type = copied and 'success' or 'warning',
        Duration = 3,
    })
end

local function hookCharacter(char)
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") and Config.AutoDump then
            handleDump("equip")
        end
    end)
    local existing = char:FindFirstChildOfClass("Tool")
    if existing and Config.AutoDump then
        handleDump("already-equipped")
    end
end

hookCharacter(LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait())
LocalPlayer.CharacterAdded:Connect(hookCharacter)

Window:Load()

Centrl:Notify({
    Title = 'attribute dumper',
    Content = 'Loaded. Equip an item to auto-copy its attributes, or press the manual dump key.',
    Type = 'success',
    Duration = 5,
})

--[[
    Centrl UI Library — Lib2
    ------------------------
    A from-scratch recreation of the Centrl panel, built entirely in code
    (no rbxassetid model to unpack) so it can be themed, rescaled and driven
    on any device.

    What it recreates from the original:
      - Dark glass window with a drop shadow, accent bar and logo header
      - Left icon tab rail with a sliding accent pin
      - Two scrolling columns of section cards
      - Toggle / slider / dropdown / textbox / keybind / colorpicker /
        button / label / divider elements
      - Colorpicker with SV square, hue bar, HEX + RGB entry, rainbow and
        copy-to-clipboard
      - Notifications with a draining duration bar
      - Per-game config saving plus named config files
      - A built-in settings tab (accent, scale, toggle key, configs)

    What it adds:
      - Real mobile support: touch drag, touch sliders, scroll that doesn't
        fight the window drag, viewport-aware scaling and a floating toggle
        button so a phone can open the panel without a keyboard.

    Usage:
      local Centrl = loadstring(game:HttpGet('.../Lib2.lua'))()
      local Window = Centrl:Window({ Title = 'centrl', Folder = 'centrl' })
      local Tab    = Window:Tab({ Title = 'Legit', Icon = 'rbxassetid://...' })
      local Sec    = Tab:Section({ Title = 'Aimbot', Side = 'left' })
      Sec:Toggle({ Title = 'Enabled', Flag = 'aim_enabled', Callback = f })
      Window:Load()
]]

local cloneref = cloneref or function(object)
    return object
end

local UserInputService = cloneref(game:GetService('UserInputService'))
local TweenService = cloneref(game:GetService('TweenService'))
local HttpService = cloneref(game:GetService('HttpService'))
local RunService = cloneref(game:GetService('RunService'))
local Players = cloneref(game:GetService('Players'))
local CoreGui = cloneref(game:GetService('CoreGui'))
local Stats = cloneref(game:GetService('Stats'))

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local HAS_FILE_API = typeof(writefile) == 'function'
    and typeof(readfile) == 'function'
    and typeof(isfile) == 'function'
    and typeof(isfolder) == 'function'
    and typeof(makefolder) == 'function'

local set_clipboard = setclipboard or toclipboard or (syn and syn.write_clipboard) or nil

--// Constants ---------------------------------------------------------------

local WINDOW_WIDTH, WINDOW_HEIGHT = 640, 424
local TAB_RAIL_WIDTH = 132
local TOPBAR_HEIGHT = 42
local SCREEN_MARGIN = 24

local Library = {
    Flags = {},
    Keybinds = {},
    _windows = {},
    _accent_objects = setmetatable({}, { __mode = 'k' }),
    _scale_objects = setmetatable({}, { __mode = 'k' }),
    _connections = {},
    _unloaded = false,
    Accent = Color3.fromRGB(227, 255, 42),
}

Library.Theme = {
    Background = Color3.fromRGB(16, 16, 16),
    Topbar = Color3.fromRGB(20, 20, 20),
    Rail = Color3.fromRGB(18, 18, 18),
    Section = Color3.fromRGB(23, 23, 23),
    Element = Color3.fromRGB(29, 29, 29),
    ElementHover = Color3.fromRGB(36, 36, 36),
    Stroke = Color3.fromRGB(38, 38, 38),
    StrokeSoft = Color3.fromRGB(30, 30, 30),
    Text = Color3.fromRGB(232, 232, 232),
    SubText = Color3.fromRGB(140, 143, 159),
    Dim = Color3.fromRGB(96, 96, 96),
    Success = Color3.fromRGB(126, 217, 87),
    Warning = Color3.fromRGB(255, 196, 87),
    Error = Color3.fromRGB(255, 96, 106),
    Info = Color3.fromRGB(120, 180, 255),
}

local Theme = Library.Theme

--// Small helpers -----------------------------------------------------------

-- Executors on mobile still report MouseEnabled, so the keyboard is the honest
-- signal for "this is a phone".
local function is_touch()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Reads the first present key out of a settings table, so both `Title` and
-- `title` style option tables work.
local function pick(options, default, ...)
    for index = 1, select('#', ...) do
        local key = select(index, ...)
        local value = options[key]
        if value ~= nil then
            return value
        end
    end
    return default
end

local function font(weight)
    local ok, result = pcall(function()
        return Font.new('rbxasset://fonts/families/GothamSSm.json', weight or Enum.FontWeight.Medium, Enum.FontStyle.Normal)
    end)
    if ok then
        return result
    end
    return nil
end

local FONT_REGULAR = font(Enum.FontWeight.Medium)
local FONT_BOLD = font(Enum.FontWeight.Bold)
local FONT_SEMI = font(Enum.FontWeight.SemiBold)

local function create(class, properties, children)
    local object = Instance.new(class)
    local parent
    if properties then
        for property, value in pairs(properties) do
            if property == 'Parent' then
                parent = value
            elseif property ~= 'FontFace' or value ~= nil then
                object[property] = value
            end
        end
    end
    if children then
        for _, child in pairs(children) do
            child.Parent = object
        end
    end
    if parent then
        object.Parent = parent
    end
    return object
end

local function text_props(size, weight, color)
    local props = {
        BackgroundTransparency = 1,
        TextSize = size or 13,
        TextColor3 = color or Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }
    local face = weight == 'bold' and FONT_BOLD or weight == 'semi' and FONT_SEMI or FONT_REGULAR
    if face then
        props.FontFace = face
    else
        props.Font = weight == 'bold' and Enum.Font.GothamBold or Enum.Font.Gotham
    end
    return props
end

local function label(parent, text, size, weight, color)
    local props = text_props(size, weight, color)
    props.Parent = parent
    props.Text = text or ''
    return create('TextLabel', props)
end

local function corner(parent, radius)
    return create('UICorner', { Parent = parent, CornerRadius = UDim.new(0, radius or 5) })
end

local function stroke(parent, color, transparency, thickness)
    return create('UIStroke', {
        Parent = parent,
        Color = color or Theme.Stroke,
        Transparency = transparency or 0,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function padding(parent, top, bottom, left, right)
    return create('UIPadding', {
        Parent = parent,
        PaddingTop = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or top or 0),
        PaddingLeft = UDim.new(0, left or 0),
        PaddingRight = UDim.new(0, right or left or 0),
    })
end

local function list(parent, gap, direction, alignment)
    return create('UIListLayout', {
        Parent = parent,
        Padding = UDim.new(0, gap or 6),
        FillDirection = direction or Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left,
    })
end

local function tween(object, info, properties)
    local animation = TweenService:Create(object, info, properties)
    animation:Play()
    return animation
end

local QUAD = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUART = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local QUINT = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

--// Connection bookkeeping --------------------------------------------------

local function track(connection)
    table.insert(Library._connections, connection)
    return connection
end

local function disconnect_all()
    for _, connection in pairs(Library._connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(Library._connections)
end

--// Accent + scale registries ----------------------------------------------

local function accent(object, properties)
    Library._accent_objects[object] = properties
    for _, property in pairs(properties) do
        pcall(function()
            object[property] = Library.Accent
        end)
    end
    return object
end

function Library:SetAccent(color)
    if typeof(color) ~= 'Color3' then
        return
    end
    Library.Accent = color
    for object, properties in pairs(Library._accent_objects) do
        if typeof(object) == 'Instance' and object.Parent then
            for _, property in pairs(properties) do
                pcall(function()
                    if property == 'Color' and object:IsA('UIGradient') then
                        object.Color = ColorSequence.new(color)
                    else
                        object[property] = color
                    end
                end)
            end
        end
    end
end

--// Input helpers -----------------------------------------------------------

-- Only one control may own a drag at a time. Without this a finger sliding
-- down the panel picks up every slider it crosses.
local ActiveDrag = nil

local function claim_drag(owner)
    if ActiveDrag ~= nil and ActiveDrag ~= owner then
        return false
    end
    ActiveDrag = owner
    return true
end

local function release_drag(owner)
    if ActiveDrag == owner then
        ActiveDrag = nil
    end
end

local function is_press(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

-- Safety net: a control whose own InputEnded never fired (the finger left its
-- bounds before lifting) must not keep ownership of the drag forever. This is
-- connected first, so it runs before the per-element handlers — which key off
-- their own dragging flag rather than off ownership.
track(UserInputService.InputEnded:Connect(function(input)
    if is_press(input) then
        ActiveDrag = nil
    end
end))

local function is_move(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
end

-- Position of the input itself rather than Mouse.X/Y: on touch the mouse
-- never moves, so reading it pegs every slider to its minimum.
local function input_position(input)
    return Vector2.new(input.Position.X, input.Position.Y)
end

local function hover(object, base, over)
    track(object.MouseEnter:Connect(function()
        tween(object, QUAD, { BackgroundColor3 = over })
    end))
    track(object.MouseLeave:Connect(function()
        tween(object, QUAD, { BackgroundColor3 = base })
    end))
end

--// Color helpers -----------------------------------------------------------

local function to_hex(color)
    return string.format('#%02X%02X%02X',
        math.round(color.R * 255),
        math.round(color.G * 255),
        math.round(color.B * 255))
end

local function to_rgb_string(color)
    return string.format('%d, %d, %d',
        math.round(color.R * 255),
        math.round(color.G * 255),
        math.round(color.B * 255))
end

local function from_hex(text)
    local hex = string.match(text or '', '^#?(%x%x%x%x%x%x)$')
    if not hex then
        return nil
    end
    local ok, color = pcall(Color3.fromHex, hex)
    if ok then
        return color
    end
    return nil
end

local function from_rgb_string(text)
    local r, g, b = string.match(text or '', '^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
    if not r then
        return nil
    end
    return Color3.fromRGB(
        math.clamp(tonumber(r), 0, 255),
        math.clamp(tonumber(g), 0, 255),
        math.clamp(tonumber(b), 0, 255))
end

local function serialize_color(color)
    return { __color = true, R = math.round(color.R * 255), G = math.round(color.G * 255), B = math.round(color.B * 255) }
end

local function deserialize_color(value)
    if typeof(value) == 'table' and value.__color then
        return Color3.fromRGB(value.R or 0, value.G or 0, value.B or 0)
    end
    return nil
end

--// Lucide icons ------------------------------------------------------------

-- Icons come from the Lucide raster API (github.com/iamdookie1/web3). Roblox
-- can't draw SVG, so the service rasterises each icon and returns one coverage
-- byte per pixel; those bytes become an EditableImage here. Unlike the module
-- in that repo there's no RemoteFunction hop — an executor has HTTP on the
-- client, so the fetch, the decode and the image build all happen in place.
--
-- Point BaseUrl at your own deployment. Icons are requested white and tinted
-- with ImageColor3, so one fetch serves every accent.

local AssetService = cloneref(game:GetService('AssetService'))

Library.Icons = {
    BaseUrl = 'https://web3-six-beta.vercel.app',
    Size = 64,
    StrokeWidth = 2,
    Padding = 4,
    Enabled = true,
}

function Library:SetIconSource(url)
    if typeof(url) == 'string' and url ~= '' then
        Library.Icons.BaseUrl = (string.gsub(url, '/+$', ''))
        Library:ClearIconCache()
    end
end

local icon_cache = {}
local icon_warned = false

function Library:ClearIconCache()
    -- Cached values are EditableImage instances (or `false` for a known-bad
    -- lookup) — table.clear alone would drop the references without
    -- destroying the instances themselves, leaking one per cached icon.
    for _, image in pairs(icon_cache) do
        if typeof(image) == 'Instance' then
            image:Destroy()
        end
    end
    table.clear(icon_cache)
    icon_warned = false
end

local http_request = (syn and syn.request)
    or (http and http.request)
    or http_request
    or request

local function http_get(url)
    if typeof(http_request) == 'function' then
        local ok, response = pcall(http_request, { Url = url, Method = 'GET' })
        if ok and typeof(response) == 'table' then
            local status = response.StatusCode or response.Status or 200
            if status < 400 and response.Body then
                return response.Body
            end
            return nil, 'http ' .. tostring(status)
        end
    end
    local ok, body = pcall(function()
        return game:HttpGet(url, true)
    end)
    if ok and typeof(body) == 'string' then
        return body
    end
    return nil, tostring(body)
end

local B64_LOOKUP = {}
do
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    for index = 1, #alphabet do
        B64_LOOKUP[string.byte(alphabet, index)] = index - 1
    end
end

local native_base64 = (crypt and crypt.base64decode)
    or (crypt and crypt.base64 and crypt.base64.decode)
    or base64_decode
    or (base64 and base64.decode)

local function base64_to_bytes(text)
    if typeof(native_base64) == 'function' then
        local ok, decoded = pcall(native_base64, text)
        if ok and typeof(decoded) == 'string' then
            return decoded
        end
    end
    local out = table.create(#text // 4 * 3)
    local accumulator, bits = 0, 0
    for index = 1, #text do
        local value = B64_LOOKUP[string.byte(text, index)]
        if value then
            accumulator = accumulator * 64 + value
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = accumulator // (2 ^ bits)
                accumulator = accumulator - byte * (2 ^ bits)
                table.insert(out, string.char(byte))
            end
        end
    end
    return table.concat(out)
end

-- Expands the coverage bytes into the RGBA buffer EditableImage wants. The
-- colour is left white on purpose; call sites tint with ImageColor3.
local function build_editable_image(width, height, alpha)
    local ok, image = pcall(function()
        return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
    end)
    if not ok or not image then
        ok, image = pcall(function()
            return AssetService:CreateEditableImage(Vector2.new(width, height))
        end)
    end
    if not ok or not image then
        return nil
    end

    local count = width * height
    local written = pcall(function()
        local pixels = buffer.create(count * 4)
        for index = 0, count - 1 do
            local offset = index * 4
            buffer.writeu8(pixels, offset, 255)
            buffer.writeu8(pixels, offset + 1, 255)
            buffer.writeu8(pixels, offset + 2, 255)
            buffer.writeu8(pixels, offset + 3, string.byte(alpha, index + 1) or 0)
        end
        image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), pixels)
    end)

    if not written then
        -- Older EditableImage builds only expose the float-table writer.
        local fallback = pcall(function()
            local pixels = table.create(count * 4)
            for index = 0, count - 1 do
                local offset = index * 4
                pixels[offset + 1] = 1
                pixels[offset + 2] = 1
                pixels[offset + 3] = 1
                pixels[offset + 4] = (string.byte(alpha, index + 1) or 0) / 255
            end
            image:WritePixels(Vector2.zero, Vector2.new(width, height), pixels)
        end)
        if not fallback then
            return nil
        end
    end

    return image
end

local function apply_editable_image(target, image)
    local ok = pcall(function()
        target.ImageContent = Content.fromObject(image)
    end)
    if ok then
        return true
    end
    -- Pre-Content builds attach the EditableImage as a child instead.
    return (pcall(function()
        image.Parent = target
    end))
end

local function icon_url(name, options)
    return string.format('%s/icon?name=%s&size=%d&strokeWidth=%s&padding=%d&format=alpha8',
        Library.Icons.BaseUrl,
        (string.gsub(tostring(name), '[^%w%-_]', '')),
        options.size,
        tostring(options.stroke),
        options.padding)
end

-- Yields. Returns an EditableImage for a Lucide icon name, or nil.
function Library:GetIcon(name, options)
    options = options or {}
    local resolved = {
        size = math.clamp(tonumber(options.Size or options.size) or Library.Icons.Size, 1, 1024),
        stroke = math.clamp(tonumber(options.StrokeWidth or options.stroke) or Library.Icons.StrokeWidth, 0.1, 6),
        padding = math.max(0, tonumber(options.Padding or options.padding) or Library.Icons.Padding),
    }
    local key = string.format('%s|%d|%s|%d', string.lower(tostring(name)), resolved.size, tostring(resolved.stroke), resolved.padding)

    local cached = icon_cache[key]
    if cached ~= nil then
        return cached or nil
    end

    local body, err = http_get(icon_url(name, resolved))
    if not body then
        if not icon_warned then
            icon_warned = true
            warn('[centrl] icon fetch failed (' .. tostring(err) .. '). Set Library.Icons.BaseUrl / Library:SetIconSource(url) to your Lucide API deployment.')
        end
        icon_cache[key] = false
        return nil
    end

    local decoded, payload = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if not decoded or typeof(payload) ~= 'table' or not payload.ok then
        local message = typeof(payload) == 'table' and payload.error or 'malformed response'
        if typeof(payload) == 'table' and payload.suggestions then
            message = message .. ' — did you mean: ' .. table.concat(payload.suggestions, ', ') .. '?'
        end
        warn('[centrl] icon "' .. tostring(name) .. '": ' .. tostring(message))
        icon_cache[key] = false
        return nil
    end

    local alpha = base64_to_bytes(payload.data)
    if #alpha < payload.width * payload.height then
        icon_cache[key] = false
        return nil
    end

    local image = build_editable_image(payload.width, payload.height, alpha)
    icon_cache[key] = image or false
    return image
end

local function is_direct_asset(text)
    return string.match(text, '^rbxassetid://')
        or string.match(text, '^rbxasset://')
        or string.match(text, '^rbxthumb://')
        or string.match(text, '^http')
        or string.match(text, '^%d+$')
end

-- Small UI icons (tabs, the minimise/close controls, the mobile button) are
-- requested at roughly twice their on-screen size rather than the library's
-- 64px default: the panel's own UIScale runs up to 2x, and fetching ahead of
-- that keeps them crisp at max zoom instead of only at 1x. Padding scales
-- down with them — the API's 4-6px suggestion is sized for 64px icons and
-- would eat a visible chunk out of a 16-24px glyph otherwise.
local function ui_icon_options(display_px)
    local size = math.clamp(math.floor(display_px * 2 + 0.5), 16, 128)
    return { Size = size, Padding = math.max(1, math.floor(size / 16)) }
end

-- Accepts a Lucide name ('house', 'ArrowRight'), an asset id, or a full
-- rbxassetid string, and never yields the caller.
function Library:ApplyIcon(target, icon, options)
    if not target or icon == nil or icon == '' then
        return
    end
    local text = tostring(icon)
    if string.match(text, '^%d+$') then
        target.Image = 'rbxassetid://' .. text
        return
    end
    if is_direct_asset(text) then
        target.Image = text
        return
    end
    if not Library.Icons.Enabled then
        return
    end
    task.spawn(function()
        local image = Library:GetIcon(text, options)
        if image and target.Parent then
            apply_editable_image(target, image)
        end
    end)
end

--// Config storage ----------------------------------------------------------

local Config = {
    folder = 'centrl',
    enabled = true,
}
Library.Config = Config

local function ensure_folder(path)
    if not HAS_FILE_API then
        return false
    end
    if not isfolder(path) then
        local ok = pcall(makefolder, path)
        if not ok then
            return false
        end
    end
    return true
end

function Config:paths()
    return self.folder, self.folder .. '/configs'
end

function Config:prepare()
    if not HAS_FILE_API then
        return false
    end
    local root, configs = self:paths()
    return ensure_folder(root) and ensure_folder(configs)
end

function Config:auto_path()
    return self.folder .. '/' .. tostring(game.GameId) .. '.json'
end

function Config:named_path(name)
    return self.folder .. '/configs/' .. tostring(name) .. '.json'
end

-- Flags may hold Color3 and EnumItem values, neither of which survives a JSON
-- round trip, so they are boxed on the way out and rebuilt on the way in.
local function encode_flags()
    local out = {}
    for flag, value in pairs(Library.Flags) do
        local kind = typeof(value)
        if kind == 'Color3' then
            out[flag] = serialize_color(value)
        elseif kind == 'EnumItem' then
            out[flag] = { __enum = true, Name = value.Name }
        elseif kind == 'table' then
            local copy = {}
            for key, entry in pairs(value) do
                copy[key] = entry
            end
            out[flag] = copy
        elseif kind == 'string' or kind == 'number' or kind == 'boolean' then
            out[flag] = value
        end
    end
    return out
end

function Library:SaveConfig(name)
    if not HAS_FILE_API or not Config:prepare() then
        return false, 'no file api'
    end
    local payload = HttpService:JSONEncode({ flags = encode_flags() })
    local path = name and Config:named_path(name) or Config:auto_path()
    local ok, err = pcall(writefile, path, payload)
    return ok, err
end

function Library:ListConfigs()
    local names = {}
    if not HAS_FILE_API or typeof(listfiles) ~= 'function' then
        return names
    end
    local _, configs = Config:paths()
    if not isfolder(configs) then
        return names
    end
    for _, file in pairs(listfiles(configs)) do
        local name = string.match(file, '([^/\\]+)%.json$')
        if name then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local FlagSetters = {}

function Library:LoadConfig(name)
    if not HAS_FILE_API then
        return false, 'no file api'
    end
    local path = name and Config:named_path(name) or Config:auto_path()
    if not isfile(path) then
        return false, 'missing'
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(path))
    end)
    if not ok or typeof(decoded) ~= 'table' then
        return false, 'corrupt'
    end
    for flag, value in pairs(decoded.flags or {}) do
        local color = deserialize_color(value)
        if color then
            value = color
        elseif typeof(value) == 'table' and value.__enum then
            local ok, key = pcall(function()
                return Enum.KeyCode[value.Name]
            end)
            value = ok and key or nil
        end
        local setter = FlagSetters[flag]
        if setter then
            pcall(setter, value)
        else
            Library.Flags[flag] = value
        end
    end
    return true
end

function Library:DeleteConfig(name)
    if not HAS_FILE_API or typeof(delfile) ~= 'function' then
        return false
    end
    local path = Config:named_path(name)
    if isfile(path) then
        return pcall(delfile, path)
    end
    return false
end

local function autosave()
    if Config.enabled and HAS_FILE_API then
        task.spawn(function()
            Library:SaveConfig()
        end)
    end
end

-- Registers a flag so config loads can push a value back through the element's
-- own setter (which repaints it) instead of only touching the flag table.
local function register_flag(flag, value, setter)
    if flag == nil then
        return
    end
    FlagSetters[flag] = setter
    if Library.Flags[flag] == nil then
        Library.Flags[flag] = value
    end
end

--// Screen parent -----------------------------------------------------------

local function gui_parent()
    if typeof(gethui) == 'function' then
        local ok, hidden = pcall(gethui)
        if ok and hidden then
            return hidden
        end
    end
    local ok = pcall(function()
        local probe = Instance.new('Folder')
        probe.Parent = CoreGui
        probe:Destroy()
    end)
    if ok then
        return CoreGui
    end
    return LocalPlayer:WaitForChild('PlayerGui')
end

--// Screen gui --------------------------------------------------------------

local ScreenGui = create('ScreenGui', {
    Name = 'centrl_' .. tostring(math.random(100000, 999999)),
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 9999,
    IgnoreGuiInset = true,
})

if typeof(syn) == 'table' and typeof(syn.protect_gui) == 'function' then
    pcall(syn.protect_gui, ScreenGui)
end
if typeof(protect_gui) == 'function' then
    pcall(protect_gui, ScreenGui)
end
ScreenGui.Parent = gui_parent()

Library.ScreenGui = ScreenGui

--// Scaling ----------------------------------------------------------------

-- Every root object gets a UIScale driven from one place. Touch devices target
-- a smaller share of the viewport than desktop: a phone screen is wide enough
-- in GUI pixels to "fit" the panel at a size that is unusable in the hand.
local function auto_scale(user_scale)
    local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local touch = is_touch()
    local target_x = viewport.X * (touch and 0.94 or 0.90)
    local target_y = viewport.Y * (touch and 0.86 or 0.90)
    local fit = math.min(
        (target_x - SCREEN_MARGIN) / WINDOW_WIDTH,
        (target_y - SCREEN_MARGIN) / WINDOW_HEIGHT,
        1)
    if touch then
        -- Phones report a small viewport; never shrink past readability.
        fit = math.max(fit, math.min(0.62, (viewport.X - 16) / WINDOW_WIDTH))
    end
    return math.clamp(fit * (user_scale or 1), 0.35, 2)
end

Library._user_scale = 1
Library._scale = 1

local function register_scale(ui_scale)
    Library._scale_objects[ui_scale] = true
    ui_scale.Scale = Library._scale
    return ui_scale
end

function Library:ApplyScale()
    Library._scale = auto_scale(Library._user_scale)
    for ui_scale in pairs(Library._scale_objects) do
        if typeof(ui_scale) == 'Instance' and ui_scale.Parent then
            ui_scale.Scale = Library._scale
        end
    end
    -- Scaling changes how much room everything takes; deferred so AbsoluteSize
    -- has caught up before anything is measured against the viewport.
    task.defer(function()
        for _, window in pairs(Library._windows) do
            if window.ClampToScreen and window.Root and window.Root.Parent then
                window:ClampToScreen()
            end
            if window._clamp_mobile_button then
                window:_clamp_mobile_button()
            end
        end
    end)
end

function Library:SetScale(value)
    Library._user_scale = math.clamp(tonumber(value) or 1, 0.25, 2)
    Library:ApplyScale()
end

--// Notifications -----------------------------------------------------------

local NotificationHolder = create('Frame', {
    Name = 'notifications',
    Parent = ScreenGui,
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.new(0, 250, 1, -28),
})
register_scale(create('UIScale', { Parent = NotificationHolder }))
create('UIListLayout', {
    Parent = NotificationHolder,
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Top,
})

local NOTIFY_TINTS = {
    success = Theme.Success,
    error = Theme.Error,
    warning = Theme.Warning,
    info = Theme.Info,
}

function Library:Notify(options)
    options = options or {}
    if typeof(options) == 'string' then
        options = { Title = options }
    end
    local title = pick(options, 'centrl', 'Title', 'title')
    local body = pick(options, '', 'Content', 'Text', 'text', 'content', 'Description')
    local duration = tonumber(pick(options, 4, 'Duration', 'duration', 'Time')) or 4
    local kind = tostring(pick(options, 'info', 'Type', 'type')):lower()
    local tint = NOTIFY_TINTS[kind] or Library.Accent

    local card = create('Frame', {
        Name = 'notification',
        Parent = NotificationHolder,
        BackgroundColor3 = Theme.Section,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    })
    corner(card, 6)
    local card_stroke = stroke(card, Theme.Stroke, 1)
    padding(card, 10, 12, 12, 12)
    list(card, 4)

    local pill = create('Frame', {
        Parent = card,
        BackgroundColor3 = tint,
        Size = UDim2.new(0, 22, 0, 2),
        LayoutOrder = 0,
        BackgroundTransparency = 1,
    })
    corner(pill, 1)

    local title_label = label(card, title, 13, 'bold', tint)
    title_label.Size = UDim2.new(1, 0, 0, 16)
    title_label.LayoutOrder = 1
    title_label.TextTransparency = 1

    local body_label
    if body ~= '' then
        body_label = label(card, body, 12, nil, Theme.SubText)
        body_label.Size = UDim2.new(1, 0, 0, 0)
        body_label.AutomaticSize = Enum.AutomaticSize.Y
        body_label.TextWrapped = true
        body_label.LayoutOrder = 2
        body_label.TextTransparency = 1
    end

    local timer_track = create('Frame', {
        Parent = card,
        BackgroundColor3 = Theme.Stroke,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 2),
        LayoutOrder = 3,
    })
    corner(timer_track, 1)
    local timer_fill = create('Frame', {
        Parent = timer_track,
        BackgroundColor3 = tint,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    corner(timer_fill, 1)

    tween(card, QUART, { BackgroundTransparency = 0 })
    tween(card_stroke, QUART, { Transparency = 0 })
    tween(pill, QUART, { BackgroundTransparency = 0 })
    tween(title_label, QUART, { TextTransparency = 0 })
    tween(timer_track, QUART, { BackgroundTransparency = 0.5 })
    tween(timer_fill, QUART, { BackgroundTransparency = 0 })
    if body_label then
        tween(body_label, QUART, { TextTransparency = 0 })
    end
    tween(timer_fill, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 1, 0) })

    task.delay(duration, function()
        if not card.Parent then
            return
        end
        tween(card, QUAD, { BackgroundTransparency = 1 })
        tween(card_stroke, QUAD, { Transparency = 1 })
        tween(pill, QUAD, { BackgroundTransparency = 1 })
        tween(title_label, QUAD, { TextTransparency = 1 })
        tween(timer_track, QUAD, { BackgroundTransparency = 1 })
        tween(timer_fill, QUAD, { BackgroundTransparency = 1 })
        if body_label then
            tween(body_label, QUAD, { TextTransparency = 1 })
        end
        task.delay(0.22, function()
            card:Destroy()
        end)
    end)

    return card
end

-- Tolerates both Library.SendNotification(t) and Library:SendNotification(t).
Library.SendNotification = function(first, second)
    return Library:Notify(second or first)
end

--// Watermark ---------------------------------------------------------------

function Library:Watermark(options)
    options = options or {}
    local text = pick(options, 'centrl', 'Text', 'text', 'Title')
    local show_stats = pick(options, true, 'ShowStats', 'show_stats')

    local frame = create('Frame', {
        Name = 'watermark',
        Parent = ScreenGui,
        BackgroundColor3 = Theme.Topbar,
        Position = UDim2.new(0, 14, 0, 14),
        Size = UDim2.new(0, 0, 0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
    })
    corner(frame, 5)
    stroke(frame, Theme.Stroke)
    register_scale(create('UIScale', { Parent = frame }))
    padding(frame, 0, 0, 9, 10)
    local layout = list(frame, 7, Enum.FillDirection.Horizontal)
    layout.VerticalAlignment = Enum.VerticalAlignment.Center

    local pill = accent(create('Frame', {
        Parent = frame,
        Size = UDim2.new(0, 2, 0, 12),
        LayoutOrder = 0,
    }), { 'BackgroundColor3' })
    corner(pill, 1)

    local title_label = accent(label(frame, text, 12, 'bold'), { 'TextColor3' })
    title_label.AutomaticSize = Enum.AutomaticSize.X
    title_label.Size = UDim2.new(0, 0, 1, 0)
    title_label.LayoutOrder = 1

    local stats_label
    if show_stats then
        create('Frame', {
            Parent = frame,
            BackgroundColor3 = Theme.Stroke,
            Size = UDim2.new(0, 1, 0, 12),
            LayoutOrder = 2,
        })
        stats_label = label(frame, 'fps 0 | ping 0ms', 12, nil, Theme.SubText)
        stats_label.AutomaticSize = Enum.AutomaticSize.X
        stats_label.Size = UDim2.new(0, 0, 1, 0)
        stats_label.LayoutOrder = 3

        local accumulated, frames = 0, 0
        track(RunService.RenderStepped:Connect(function(delta)
            accumulated = accumulated + delta
            frames = frames + 1
            if accumulated >= 0.5 then
                local ping = 0
                pcall(function()
                    ping = math.round(Stats.Network.ServerStatsItem['Data Ping']:GetValue())
                end)
                stats_label.Text = string.format('fps %d | ping %dms', math.round(frames / accumulated), ping)
                accumulated, frames = 0, 0
            end
        end))
    end

    local api = {}
    function api:SetText(value)
        title_label.Text = tostring(value)
    end
    function api:SetVisible(state)
        frame.Visible = state and true or false
    end
    function api:SetStatsVisible(state)
        if stats_label then
            stats_label.Visible = state and true or false
        end
    end
    api.set_text, api.set_visible, api.set_stats_visible = api.SetText, api.SetVisible, api.SetStatsVisible
    return api
end

--// Window ------------------------------------------------------------------

local Window = {}
Window.__index = Window

local Tab = {}
Tab.__index = Tab

local Section = {}
Section.__index = Section

function Library:Window(options)
    options = options or {}

    local title = pick(options, 'centrl', 'Title', 'title', 'Name')
    local subtitle = pick(options, 'v2', 'SubTitle', 'Subtitle', 'subtitle', 'Version')
    local logo = pick(options, 'rbxassetid://18404006294', 'Logo', 'logo', 'Icon')
    local folder = pick(options, 'centrl', 'Folder', 'folder', 'ConfigFolder')
    local toggle_key = pick(options, Enum.KeyCode.RightShift, 'ToggleKey', 'toggle_key', 'Keybind')
    local accent_color = pick(options, nil, 'Accent', 'accent', 'AccentColor')
    local user_scale = tonumber(pick(options, 1, 'Scale', 'scale')) or 1
    local config_enabled = pick(options, true, 'ConfigEnabled', 'SaveConfig', 'config_enabled')
    local mobile_button = pick(options, true, 'MobileButton', 'mobile_button', 'FloatingButton')
    local settings_tab = pick(options, true, 'SettingsTab', 'settings_tab')
    local icon_api = pick(options, nil, 'IconApi', 'icon_api', 'IconSource', 'LucideApi')

    if icon_api then
        Library:SetIconSource(icon_api)
    end
    Config.folder = tostring(folder)
    Config.enabled = config_enabled and true or false
    if accent_color then
        Library.Accent = accent_color
    end
    Library._user_scale = math.clamp(user_scale, 0.25, 2)
    Library._scale = auto_scale(Library._user_scale)

    local self = setmetatable({}, Window)
    self.Tabs = {}
    self.ToggleKey = toggle_key
    -- Open tracks expanded-vs-minimised and is independent of Visible (whether
    -- the whole panel is shown at all), so hiding and reshowing the panel
    -- restores whichever of those two states it was actually left in.
    self.Open = true
    self.Visible = true

    --// Shell ---------------------------------------------------------------

    -- Anchored top-left, not centered: with a centered anchor every height
    -- change (minimise, restore, the open animation) moves the top edge by half
    -- the difference, so the panel creeps up the screen each time it reopens.
    -- Pinning the top-left means collapsing and expanding leave it exactly
    -- where it was, and clamping is a straight comparison against the viewport.
    local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local root = create('Frame', {
        Name = 'centrl',
        Parent = ScreenGui,
        AnchorPoint = Vector2.new(0, 0),
        Position = UDim2.fromOffset(
            math.max(0, math.round((viewport.X - WINDOW_WIDTH * Library._scale) / 2)),
            math.max(0, math.round((viewport.Y - WINDOW_HEIGHT * Library._scale) / 2))),
        Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT),
        BackgroundColor3 = Theme.Background,
        BackgroundTransparency = 1,
        ClipsDescendants = false,
        Visible = false,
    })
    register_scale(create('UIScale', { Parent = root }))
    corner(root, 8)
    local root_stroke = stroke(root, Theme.Stroke, 1)

    self.Root = root

    local shadow = create('ImageLabel', {
        Name = 'shadow',
        Parent = root,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 60, 1, 60),
        Image = 'rbxassetid://6014261993',
        ImageColor3 = Color3.new(0, 0, 0),
        ImageTransparency = 1,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = Rect.new(49, 49, 450, 450),
        ZIndex = 0,
    })

    local body = create('Frame', {
        Name = 'body',
        Parent = root,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        ClipsDescendants = true,
    })
    corner(body, 8)

    --// Topbar --------------------------------------------------------------

    local topbar = create('Frame', {
        Name = 'topbar',
        Parent = body,
        BackgroundColor3 = Theme.Topbar,
        Size = UDim2.new(1, 0, 0, TOPBAR_HEIGHT),
        BorderSizePixel = 0,
    })
    corner(topbar, 8)
    create('Frame', {
        Parent = topbar,
        BackgroundColor3 = Theme.Topbar,
        Position = UDim2.new(0, 0, 1, -8),
        Size = UDim2.new(1, 0, 0, 8),
        BorderSizePixel = 0,
    })
    local topbar_line = create('Frame', {
        Name = 'bar',
        Parent = topbar,
        BackgroundColor3 = Theme.Stroke,
        Position = UDim2.new(0, 0, 1, -1),
        Size = UDim2.new(1, 0, 0, 1),
        BorderSizePixel = 0,
    })

    local logo_image = accent(create('ImageLabel', {
        Name = 'logo',
        Parent = topbar,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 13, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(16, 16),
        ImageTransparency = 1,
    }), { 'ImageColor3' })
    Library:ApplyIcon(logo_image, logo, ui_icon_options(16))

    local title_label = accent(label(topbar, title, 15, 'bold'), { 'TextColor3' })
    title_label.Name = 'work'
    title_label.Position = UDim2.new(0, 37, 0.5, 0)
    title_label.AnchorPoint = Vector2.new(0, 0.5)
    title_label.Size = UDim2.new(0, 0, 0, 18)
    title_label.AutomaticSize = Enum.AutomaticSize.X
    title_label.TextTransparency = 1

    local subtitle_label = label(topbar, subtitle, 11, nil, Theme.Dim)
    subtitle_label.Name = 'bld'
    subtitle_label.Position = UDim2.new(0, 37, 0.5, 0)
    subtitle_label.AnchorPoint = Vector2.new(0, 0.5)
    subtitle_label.Size = UDim2.new(0, 0, 0, 14)
    subtitle_label.AutomaticSize = Enum.AutomaticSize.X
    subtitle_label.TextTransparency = 1
    track(title_label:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
        subtitle_label.Position = UDim2.new(0, 37 + (title_label.AbsoluteSize.X / math.max(Library._scale, 0.01)) + 7, 0.5, 0)
    end))
    task.defer(function()
        subtitle_label.Position = UDim2.new(0, 37 + (title_label.AbsoluteSize.X / math.max(Library._scale, 0.01)) + 7, 0.5, 0)
    end)

    -- Close / minimise controls, sized for a fingertip on touch.
    local control_size = is_touch() and 26 or 20
    local controls = create('Frame', {
        Name = 'controls',
        Parent = topbar,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.new(0, 0, 0, control_size),
        AutomaticSize = Enum.AutomaticSize.X,
    })
    local controls_layout = list(controls, 6, Enum.FillDirection.Horizontal)
    controls_layout.VerticalAlignment = Enum.VerticalAlignment.Center

    local control_icon_px = math.floor(control_size * 0.55)
    local control_icon_options = ui_icon_options(control_icon_px)

    local function control_button(icon_name, order, callback)
        local button = create('TextButton', {
            Parent = controls,
            BackgroundColor3 = Theme.Element,
            Size = UDim2.fromOffset(control_size, control_size),
            Text = '',
            AutoButtonColor = false,
            LayoutOrder = order,
        })
        corner(button, 4)
        stroke(button, Theme.Stroke)
        local icon_image = create('ImageLabel', {
            Parent = button,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.fromOffset(control_icon_px, control_icon_px),
            ImageColor3 = Theme.SubText,
        })
        Library:ApplyIcon(icon_image, icon_name, control_icon_options)
        hover(button, Theme.Element, Theme.ElementHover)
        track(button.MouseButton1Click:Connect(callback))
        return button, icon_image
    end

    local minimise_button, minimise_icon = control_button('chevron-up', 0, function()
        self:SetOpen(not self.Open)
    end)
    control_button('x', 1, function()
        self:SetVisible(false)
    end)

    -- The minimise icon flips direction with state, so the same button always
    -- shows which way it's about to move rather than a static dash.
    self._minimise_icon = minimise_icon
    self._minimise_icon_options = control_icon_options
    self:_sync_minimise_icon()

    --// Content -------------------------------------------------------------

    local content = create('Frame', {
        Name = 'content',
        Parent = body,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 0, TOPBAR_HEIGHT),
        Size = UDim2.new(1, 0, 1, -TOPBAR_HEIGHT),
        ClipsDescendants = true,
    })

    local rail = create('Frame', {
        Name = 'tabholder',
        Parent = content,
        BackgroundColor3 = Theme.Rail,
        Size = UDim2.new(0, TAB_RAIL_WIDTH, 1, 0),
        BorderSizePixel = 0,
    })
    create('Frame', {
        Parent = rail,
        BackgroundColor3 = Theme.Stroke,
        Position = UDim2.new(1, -1, 0, 0),
        Size = UDim2.new(0, 1, 1, 0),
        BorderSizePixel = 0,
    })

    local tab_scroll = create('ScrollingFrame', {
        Name = 'tabs',
        Parent = rail,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -1, 1, 0),
        BorderSizePixel = 0,
        ScrollBarThickness = 0,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
        Active = true,
        ClipsDescendants = true,
    })
    padding(tab_scroll, 10, 10, 10, 10)
    list(tab_scroll, 4)

    local pages = create('Frame', {
        Name = 'pageholder',
        Parent = content,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, TAB_RAIL_WIDTH, 0, 0),
        Size = UDim2.new(1, -TAB_RAIL_WIDTH, 1, 0),
        ClipsDescendants = true,
    })

    self.TabScroll = tab_scroll
    self.Pages = pages

    --// Dragging ------------------------------------------------------------

    -- The window is dragged from the topbar and the tab rail background only,
    -- so a touch-drag anywhere over the content scrolls that content instead.
    local drag_start, start_position
    local function begin_drag(input)
        if not is_press(input) then
            return
        end
        if not claim_drag('window') then
            return
        end
        drag_start = input_position(input)
        start_position = root.Position
        local changed
        changed = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                changed:Disconnect()
                drag_start = nil
                release_drag('window')
            end
        end)
    end

    track(topbar.InputBegan:Connect(begin_drag))
    track(rail.InputBegan:Connect(begin_drag))
    track(UserInputService.InputChanged:Connect(function(input)
        if not drag_start or not is_move(input) then
            return
        end
        local delta = input_position(input) - drag_start
        root.Position = UDim2.fromOffset(
            start_position.X.Offset + delta.X,
            start_position.Y.Offset + delta.Y)
        -- Clamped every frame of the drag rather than on release, so the panel
        -- stops at the edge instead of snapping back from off-screen.
        self:ClampToScreen()
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if is_press(input) then
            drag_start = nil
            release_drag('window')
        end
    end))

    --// Off-screen protection -------------------------------------------------

    -- Tweens (open/close, minimise/restore) change Size every rendered frame,
    -- and each of those changes also moves AbsoluteSize — so clamping off of
    -- that signal keeps the panel on screen for the full duration of the
    -- animation, not just once it lands. A one-shot clamp after a fixed delay
    -- only catches the *end* of a tween; anything that puts the window
    -- off-screen mid-animation, or moves/resizes it some other way entirely,
    -- would otherwise slip through uncaught. The handler is idempotent (it
    -- only writes Position when it actually needs to move), so reacting to
    -- Position's own changed signal here can't recurse forever.
    track(root:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
        self:ClampToScreen()
    end))
    track(root:GetPropertyChangedSignal('Position'):Connect(function()
        self:ClampToScreen()
    end))

    --// Scale reactions ------------------------------------------------------

    track(Camera:GetPropertyChangedSignal('ViewportSize'):Connect(function()
        Library:ApplyScale()
        self:ClampToScreen()
    end))
    Library:ApplyScale()
    self:ClampToScreen()

    --// Mobile toggle button -------------------------------------------------

    if mobile_button and UserInputService.TouchEnabled then
        local mobile_icon_name = pick(options, 'menu', 'MobileButtonIcon', 'mobile_button_icon', 'FloatingButtonIcon')

        -- The hit target is a plain, invisible square; everything drawn sits
        -- on `visual`, which carries its own UIScale so a press can shrink
        -- the circle+icon for tactile feedback without fighting the outer
        -- UIScale that keeps the button sized to the viewport.
        local button = create('TextButton', {
            Name = 'mobile_toggle',
            Parent = ScreenGui,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0, 0),
            Position = UDim2.new(0, 14, 0, 90),
            Size = UDim2.fromOffset(52, 52),
            Text = '',
            AutoButtonColor = false,
        })
        register_scale(create('UIScale', { Parent = button }))

        create('ImageLabel', {
            Name = 'shadow',
            Parent = button,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 3),
            Size = UDim2.new(1, 30, 1, 30),
            Image = 'rbxassetid://6014261993',
            ImageColor3 = Color3.new(0, 0, 0),
            ImageTransparency = 0.5,
            ScaleType = Enum.ScaleType.Slice,
            SliceCenter = Rect.new(49, 49, 450, 450),
            ZIndex = 0,
        })

        -- Centre-anchored so the press-feedback UIScale below shrinks the
        -- circle toward its own middle rather than toward the button's
        -- top-left corner.
        local visual = create('Frame', {
            Name = 'visual',
            Parent = button,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(1, 0, 1, 0),
        })
        local press_scale = create('UIScale', { Parent = visual, Scale = 1 })

        local circle = create('Frame', {
            Name = 'circle',
            Parent = visual,
            BackgroundColor3 = Theme.Topbar,
            Size = UDim2.new(1, 0, 1, 0),
        })
        corner(circle, 26)
        accent(stroke(circle, Library.Accent, 0.35, 1.5), { 'Color' })

        local icon = accent(create('ImageLabel', {
            Name = 'icon',
            Parent = circle,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.fromOffset(24, 24),
        }), { 'ImageColor3' })
        Library:ApplyIcon(icon, mobile_icon_name, ui_icon_options(24))

        -- Drag the button around; a tap that never moved toggles the window.
        local moved, press_start, button_start
        track(button.InputBegan:Connect(function(input)
            if not is_press(input) then
                return
            end
            if not claim_drag('mobile_button') then
                return
            end
            moved = false
            press_start = input_position(input)
            button_start = button.Position
            tween(press_scale, QUAD, { Scale = 0.88 })
            local changed
            changed = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    changed:Disconnect()
                    press_start = nil
                    release_drag('mobile_button')
                    tween(press_scale, QUART, { Scale = 1 })
                    if not moved then
                        self:SetVisible(not self.Visible)
                    end
                end
            end)
        end))
        function self:_clamp_mobile_button()
            local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
            local size = button.AbsoluteSize
            button.Position = UDim2.fromOffset(
                math.clamp(button.Position.X.Offset, 0, math.max(0, viewport.X - size.X)),
                math.clamp(button.Position.Y.Offset, 0, math.max(0, viewport.Y - size.Y)))
        end

        track(UserInputService.InputChanged:Connect(function(input)
            if not press_start or not is_move(input) then
                return
            end
            local delta = input_position(input) - press_start
            if delta.Magnitude > 6 then
                moved = true
            end
            button.Position = UDim2.fromOffset(
                button_start.X.Offset + delta.X,
                button_start.Y.Offset + delta.Y)
            self:_clamp_mobile_button()
        end))
        -- Continuous protection, same as the window itself: catches a scale
        -- change or a viewport resize shrinking the safe area, not just drags.
        track(button:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
            self:_clamp_mobile_button()
        end))
        track(button:GetPropertyChangedSignal('Position'):Connect(function()
            self:_clamp_mobile_button()
        end))
        self:_clamp_mobile_button()
        self.MobileButton = button
        self.MobileIcon = icon
    end

    --// Toggle key ------------------------------------------------------------

    track(UserInputService.InputBegan:Connect(function(input, processed)
        if processed or Library._unloaded then
            return
        end
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == self.ToggleKey then
            self:SetVisible(not self.Visible)
        end
    end))

    self.Shadow = shadow
    self.RootStroke = root_stroke
    self.Topbar = topbar
    self.TopbarLine = topbar_line
    self.Logo = logo_image
    self.TitleLabel = title_label
    self.SubtitleLabel = subtitle_label
    self.Body = body

    table.insert(Library._windows, self)

    if settings_tab then
        task.defer(function()
            self:_build_settings_tab()
        end)
    end

    return self
end

-- Keeps the panel wholly on screen. Position is read back as a pure offset
-- (Scale is always 0 here) rather than from AbsolutePosition, which carries the
-- GUI inset and would drift the window a little further every call. This is
-- also wired to the root's own AbsoluteSize/Position-changed signals (see
-- above), so it runs continuously through every tween rather than once
-- before and once after — nothing can park the panel off-screen even for a
-- single frame, whether that's a drag, a minimise/restore, a scale change, or
-- anything else that moves or resizes it.
function Window:ClampToScreen()
    local viewport = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local root = self.Root
    local size = root.AbsoluteSize
    local x = math.clamp(root.Position.X.Offset, 0, math.max(0, viewport.X - size.X))
    local y = math.clamp(root.Position.Y.Offset, 0, math.max(0, viewport.Y - size.Y))
    if x ~= root.Position.X.Offset or y ~= root.Position.Y.Offset then
        root.Position = UDim2.fromOffset(x, y)
    end
end

function Window:SetVisible(state)
    self.Visible = state and true or false
    if self.Visible then
        self.Root.Visible = true
        self:_animate_in()
    else
        self:_animate_out()
    end
end

function Window:_sync_minimise_icon()
    if self._minimise_icon then
        Library:ApplyIcon(self._minimise_icon, self.Open and 'chevron-up' or 'chevron-down', self._minimise_icon_options)
    end
end

function Window:SetOpen(state)
    -- Collapse to just the topbar, the original's minimise behaviour. The
    -- top-left anchor means the header stays put through both directions;
    -- the AbsoluteSize-changed connection clamps continuously as it resizes.
    self.Open = state and true or false
    local height = self.Open and WINDOW_HEIGHT or TOPBAR_HEIGHT
    tween(self.Root, QUINT, { Size = UDim2.fromOffset(WINDOW_WIDTH, height) })
    self:_sync_minimise_icon()
end

function Window:_animate_in()
    local root = self.Root
    -- Grows from the topbar back to whatever height it's actually supposed to
    -- be at (self.Open may be true or false — it's whatever it was left at
    -- before the panel was hidden, not forced open every time it's shown).
    local target_height = self.Open and WINDOW_HEIGHT or TOPBAR_HEIGHT
    root.Size = UDim2.fromOffset(WINDOW_WIDTH, TOPBAR_HEIGHT)
    root.BackgroundTransparency = 1
    tween(root, QUINT, { Size = UDim2.fromOffset(WINDOW_WIDTH, target_height), BackgroundTransparency = 0 })
    tween(self.RootStroke, QUART, { Transparency = 0 })
    tween(self.Shadow, QUART, { ImageTransparency = 0.55 })
    tween(self.Logo, QUART, { ImageTransparency = 0 })
    tween(self.TitleLabel, QUART, { TextTransparency = 0 })
    tween(self.SubtitleLabel, QUART, { TextTransparency = 0 })
end

function Window:_animate_out()
    local root = self.Root
    -- Only the topbar itself needs to stay visible while hidden, so the next
    -- _animate_in always grows from the same TOPBAR_HEIGHT starting point
    -- regardless of whether the panel was expanded or minimised when closed.
    tween(root, QUART, { Size = UDim2.fromOffset(WINDOW_WIDTH, TOPBAR_HEIGHT), BackgroundTransparency = 1 })
    tween(self.RootStroke, QUAD, { Transparency = 1 })
    tween(self.Shadow, QUAD, { ImageTransparency = 1 })
    tween(self.Logo, QUAD, { ImageTransparency = 1 })
    tween(self.TitleLabel, QUAD, { TextTransparency = 1 })
    tween(self.SubtitleLabel, QUAD, { TextTransparency = 1 })
    task.delay(0.28, function()
        if not self.Visible then
            root.Visible = false
        end
    end)
end

function Window:Load()
    if Config.enabled and HAS_FILE_API then
        Config:prepare()
        pcall(function()
            Library:LoadConfig()
        end)
    end
    if #self.Tabs > 0 and not self.ActiveTab then
        self.Tabs[1]:Select()
    end
    self:SetVisible(true)
    return self
end

function Window:SetToggleKey(key)
    if typeof(key) == 'EnumItem' then
        self.ToggleKey = key
    end
end

function Window:SetTitle(text)
    self.TitleLabel.Text = tostring(text)
end

function Window:Destroy()
    Library:Unload()
end

function Library:Unload()
    Library._unloaded = true
    disconnect_all()
    pcall(function()
        ScreenGui:Destroy()
    end)
    table.clear(Library._windows)
    Library:ClearIconCache()
end

Library.Destroy = Library.Unload

--// Tabs -------------------------------------------------------------------

local ROW_HEIGHT = 28
local TOUCH_ROW_HEIGHT = 34

local function row_height()
    return is_touch() and TOUCH_ROW_HEIGHT or ROW_HEIGHT
end

-- Marks a scrolling region as the owner of touch input so a drag over it
-- scrolls instead of dragging the window behind it.
local function sink_scroll(frame)
    frame.Active = true
    track(frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            claim_drag(frame)
        end
    end))
    track(frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            release_drag(frame)
        end
    end))
end

local function make_column(parent, name, width_scale, x_scale, x_offset)
    local column = create('ScrollingFrame', {
        Name = name,
        Parent = parent,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(x_scale, x_offset, 0, 0),
        Size = UDim2.new(width_scale, -6, 1, 0),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Theme.Stroke,
        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
        ClipsDescendants = true,
    })
    padding(column, 12, 12, 0, 6)
    list(column, 8)
    sink_scroll(column)
    return column
end

function Window:Tab(options)
    options = options or {}
    local title = pick(options, 'Tab', 'Title', 'title', 'Name')
    local icon = pick(options, nil, 'Icon', 'icon', 'Image')

    local tab = setmetatable({}, Tab)
    tab.Window = self
    tab.Title = title
    tab.Sections = {}

    local button = create('TextButton', {
        Name = 'tb',
        Parent = self.TabScroll,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, is_touch() and 34 or 30),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = #self.Tabs + 1,
    })
    corner(button, 5)

    local indicator = accent(create('Frame', {
        Name = 'indi',
        Parent = button,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(0, 2, 0, 0),
        BorderSizePixel = 0,
    }), { 'BackgroundColor3' })
    corner(indicator, 1)

    local icon_image
    if icon then
        icon_image = create('ImageLabel', {
            Name = 'icon',
            Parent = button,
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 10, 0.5, 0),
            Size = UDim2.fromOffset(16, 16),
            ImageColor3 = Theme.SubText,
        })
        Library:ApplyIcon(icon_image, icon, ui_icon_options(16))
    end

    local title_label = label(button, title, 13, 'semi', Theme.SubText)
    title_label.Name = 'title'
    title_label.AnchorPoint = Vector2.new(0, 0.5)
    title_label.Position = UDim2.new(0, icon and 32 or 12, 0.5, 0)
    title_label.Size = UDim2.new(1, -40, 1, 0)

    local page = create('Frame', {
        Name = 'page',
        Parent = self.Pages,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        Visible = false,
    })
    padding(page, 0, 0, 12, 6)

    local single_column = is_touch()
    local left = make_column(page, 'L', single_column and 1 or 0.5, 0, 0)
    local right
    if single_column then
        left.Size = UDim2.new(1, -6, 1, 0)
    else
        right = make_column(page, 'R', 0.5, 0.5, 6)
    end

    tab.Button = button
    tab.Indicator = indicator
    tab.TitleLabel = title_label
    tab.IconImage = icon_image
    tab.Page = page
    tab.Left = left
    tab.Right = right or left
    tab.SingleColumn = single_column

    track(button.MouseButton1Click:Connect(function()
        tab:Select()
    end))
    hover(button, Theme.Element, Theme.ElementHover)

    table.insert(self.Tabs, tab)
    if #self.Tabs == 1 then
        tab:Select()
    end
    return tab
end

function Tab:Select()
    local window = self.Window
    for _, other in pairs(window.Tabs) do
        if other ~= self then
            other.Page.Visible = false
            tween(other.Button, QUAD, { BackgroundTransparency = 1 })
            tween(other.Indicator, QUART, { Size = UDim2.new(0, 2, 0, 0) })
            tween(other.TitleLabel, QUAD, { TextColor3 = Theme.SubText })
            if other.IconImage then
                tween(other.IconImage, QUAD, { ImageColor3 = Theme.SubText })
            end
        end
    end
    self.Page.Visible = true
    window.ActiveTab = self
    tween(self.Button, QUAD, { BackgroundTransparency = 0 })
    tween(self.Indicator, QUART, { Size = UDim2.new(0, 2, 0, 14) })
    tween(self.TitleLabel, QUAD, { TextColor3 = Theme.Text })
    if self.IconImage then
        tween(self.IconImage, QUAD, { ImageColor3 = Library.Accent })
    end
end

Tab.select = Tab.Select

--// Sections ---------------------------------------------------------------

function Tab:Section(options)
    options = options or {}
    local title = pick(options, 'Section', 'Title', 'title', 'Name')
    local side = tostring(pick(options, 'left', 'Side', 'side', 'section')):lower()
    local parent = (side == 'right' or side == 'r') and self.Right or self.Left

    local section = setmetatable({}, Section)
    section.Tab = self
    section.Order = 0

    local card = create('Frame', {
        Name = 'section',
        Parent = parent,
        BackgroundColor3 = Theme.Section,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = #self.Sections + 1,
    })
    corner(card, 6)
    stroke(card, Theme.StrokeSoft)
    padding(card, 10, 12, 10, 10)
    list(card, 8)

    local header = create('Frame', {
        Name = 'header',
        Parent = card,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 16),
        LayoutOrder = 0,
    })
    local pill = accent(create('Frame', {
        Parent = header,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(0, 2, 0, 11),
    }), { 'BackgroundColor3' })
    corner(pill, 1)
    local header_label = label(header, title, 13, 'bold', Theme.Text)
    header_label.Position = UDim2.new(0, 8, 0, 0)
    header_label.Size = UDim2.new(1, -8, 1, 0)

    local container = create('Frame', {
        Name = 'container',
        Parent = card,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 1,
    })
    list(container, 6)

    section.Card = card
    section.Container = container
    section.HeaderLabel = header_label

    table.insert(self.Sections, section)
    return section
end

Tab.create_section = Tab.Section
Tab.Groupbox = Tab.Section

function Section:_next()
    self.Order = self.Order + 1
    return self.Order
end

function Section:_row(height)
    return create('Frame', {
        Name = 'row',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, height or row_height()),
        LayoutOrder = self:_next(),
    })
end

function Section:SetTitle(text)
    self.HeaderLabel.Text = tostring(text)
end

--// Element: label / paragraph ----------------------------------------------

function Section:Label(options)
    options = options or {}
    if typeof(options) == 'string' then
        options = { Text = options }
    end
    local text = pick(options, '', 'Text', 'text', 'Title')

    local text_label = label(self.Container, text, 12, nil, Theme.SubText)
    text_label.Name = 'label'
    text_label.Size = UDim2.new(1, 0, 0, 0)
    text_label.AutomaticSize = Enum.AutomaticSize.Y
    text_label.TextWrapped = true
    text_label.LayoutOrder = self:_next()

    local api = {}
    function api:Set(value)
        text_label.Text = tostring(value)
    end
    api.SetText, api.set = api.Set, api.Set
    return api
end

function Section:Paragraph(options)
    options = options or {}
    local title = pick(options, '', 'Title', 'title')
    local text = pick(options, '', 'Text', 'text', 'Content')

    local holder = create('Frame', {
        Name = 'paragraph',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
    })
    corner(holder, 5)
    stroke(holder, Theme.Stroke)
    padding(holder, 8, 8, 9, 9)
    list(holder, 3)

    local title_label = label(holder, title, 12, 'bold', Theme.Text)
    title_label.Size = UDim2.new(1, 0, 0, 0)
    title_label.AutomaticSize = Enum.AutomaticSize.Y
    title_label.TextWrapped = true

    local body_label = label(holder, text, 12, nil, Theme.SubText)
    body_label.Size = UDim2.new(1, 0, 0, 0)
    body_label.AutomaticSize = Enum.AutomaticSize.Y
    body_label.TextWrapped = true
    body_label.LayoutOrder = 1

    local api = {}
    function api:Set(values)
        values = values or {}
        if values.Title or values.title then
            title_label.Text = tostring(values.Title or values.title)
        end
        if values.Text or values.text then
            body_label.Text = tostring(values.Text or values.text)
        end
    end
    api.set = api.Set
    return api
end

function Section:Divider(options)
    options = options or {}
    local title = pick(options, nil, 'Title', 'title', 'Text')

    local holder = create('Frame', {
        Name = 'divider',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, title and 16 or 8),
        LayoutOrder = self:_next(),
    })
    local line = create('Frame', {
        Parent = holder,
        BackgroundColor3 = Theme.Stroke,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, 1),
        BorderSizePixel = 0,
    })
    if title then
        local text_label = label(holder, title, 11, 'semi', Theme.Dim)
        text_label.BackgroundColor3 = Theme.Section
        text_label.BackgroundTransparency = 0
        text_label.AnchorPoint = Vector2.new(0, 0.5)
        text_label.Position = UDim2.new(0, 6, 0.5, 0)
        text_label.Size = UDim2.new(0, 0, 1, 0)
        text_label.AutomaticSize = Enum.AutomaticSize.X
        padding(text_label, 0, 0, 4, 4)
        line.ZIndex = 0
    end
    return holder
end

--// Element: button ---------------------------------------------------------

function Section:Button(options)
    options = options or {}
    local title = pick(options, 'Button', 'Title', 'title', 'Text')
    local callback = pick(options, function() end, 'Callback', 'callback', 'Func')

    local button = create('TextButton', {
        Name = 'button',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.new(1, 0, 0, row_height()),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = self:_next(),
    })
    corner(button, 5)
    stroke(button, Theme.Stroke)
    hover(button, Theme.Element, Theme.ElementHover)

    local title_label = label(button, title, 12, 'semi', Theme.Text)
    title_label.Size = UDim2.new(1, 0, 1, 0)
    title_label.TextXAlignment = Enum.TextXAlignment.Center

    track(button.MouseButton1Click:Connect(function()
        -- A flash instead of AutoButtonColor so touch taps read as presses too.
        tween(button, TweenInfo.new(0.08), { BackgroundColor3 = Library.Accent })
        tween(title_label, TweenInfo.new(0.08), { TextColor3 = Theme.Background })
        task.delay(0.12, function()
            tween(button, QUAD, { BackgroundColor3 = Theme.Element })
            tween(title_label, QUAD, { TextColor3 = Theme.Text })
        end)
        task.spawn(function()
            local ok, err = pcall(callback)
            if not ok then
                warn('[centrl] button callback error: ' .. tostring(err))
            end
        end)
    end))

    local api = {}
    function api:SetTitle(text)
        title_label.Text = tostring(text)
    end
    api.set_title = api.SetTitle
    return api
end

--// Element: toggle ---------------------------------------------------------

function Section:Toggle(options)
    options = options or {}
    local title = pick(options, 'Toggle', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local default = pick(options, false, 'Default', 'default', 'Value', 'value', 'State') and true or false
    local callback = pick(options, function() end, 'Callback', 'callback')
    local ignore_saved = pick(options, false, 'IgnoreSaved', 'ignoresaved')

    local box_size = is_touch() and 20 or 17
    local row = self:_row()

    local button = create('TextButton', {
        Name = 'tog',
        Parent = row,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        Text = '',
        AutoButtonColor = false,
    })

    local title_label = label(button, title, 12, nil, Theme.SubText)
    title_label.Name = 'title'
    title_label.Position = UDim2.new(0, 0, 0, 0)
    title_label.Size = UDim2.new(1, -(box_size + 8), 1, 0)

    local box = create('Frame', {
        Name = 'check',
        Parent = button,
        BackgroundColor3 = Theme.Element,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(box_size, box_size),
    })
    corner(box, 4)
    local box_stroke = stroke(box, Theme.Stroke)

    local fill = accent(create('Frame', {
        Name = 'gradfr',
        Parent = box,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
    }), { 'BackgroundColor3' })
    corner(fill, 4)

    local tick = create('ImageLabel', {
        Name = 'tick',
        Parent = box,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0.7, 0, 0.7, 0),
        Image = 'rbxassetid://6031094667',
        ImageColor3 = Theme.Background,
        ImageTransparency = 1,
    })
    local tick_scale = create('UIScale', { Parent = tick, Scale = 0.4 })

    local state = default
    local api = {}

    local function paint(animated)
        local info = animated and QUART or TweenInfo.new(0)
        tween(fill, info, { BackgroundTransparency = state and 0 or 1 })
        tween(tick, info, { ImageTransparency = state and 0 or 1 })
        tween(tick_scale, info, { Scale = state and 1 or 0.4 })
        tween(title_label, info, { TextColor3 = state and Theme.Text or Theme.SubText })
        tween(box_stroke, info, { Color = state and Library.Accent or Theme.Stroke })
    end

    function api:Set(value, silent)
        state = value and true or false
        paint(true)
        if flag then
            Library.Flags[flag] = state
        end
        if not silent then
            task.spawn(function()
                local ok, err = pcall(callback, state)
                if not ok then
                    warn('[centrl] toggle callback error: ' .. tostring(err))
                end
            end)
            if not ignore_saved then
                autosave()
            end
        end
    end

    function api:Get()
        return state
    end

    api.SetState, api.set_state, api.Toggle = api.Set, api.Set, function()
        api:Set(not state)
    end
    api.Value = function()
        return state
    end

    track(button.MouseButton1Click:Connect(function()
        api:Set(not state)
    end))

    if flag and not ignore_saved then
        register_flag(flag, default, function(value)
            api:Set(value, false)
        end)
        if Library.Flags[flag] ~= nil then
            state = Library.Flags[flag] and true or false
        end
    elseif flag then
        Library.Flags[flag] = state
    end

    paint(false)
    task.spawn(function()
        pcall(callback, state)
    end)
    return api
end

Section.Checkbox = Section.Toggle

--// Element: slider ---------------------------------------------------------

function Section:Slider(options)
    options = options or {}
    local title = pick(options, 'Slider', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local minimum = tonumber(pick(options, 0, 'Min', 'min', 'minimum_value', 'Minimum')) or 0
    local maximum = tonumber(pick(options, 100, 'Max', 'max', 'maximum_value', 'Maximum')) or 100
    local increment = tonumber(pick(options, 1, 'Increment', 'increment', 'round_number', 'Step')) or 1
    local default = tonumber(pick(options, minimum, 'Default', 'default', 'Value', 'value', 'startvalue')) or minimum
    local suffix = tostring(pick(options, '', 'Suffix', 'suffix', 'Unit'))
    local callback = pick(options, function() end, 'Callback', 'callback')
    local ignore_saved = pick(options, false, 'IgnoreSaved', 'ignoresaved')

    local bar_height = is_touch() and 8 or 6
    local holder = create('Frame', {
        Name = 'sliderframe',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (is_touch() and 44 or 38)),
        LayoutOrder = self:_next(),
    })

    local title_label = label(holder, title, 12, nil, Theme.SubText)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, -70, 0, 16)

    local value_label = label(holder, '', 12, 'semi', Theme.Text)
    value_label.Name = 'value'
    value_label.AnchorPoint = Vector2.new(1, 0)
    value_label.Position = UDim2.new(1, 0, 0, 0)
    value_label.Size = UDim2.new(0, 70, 0, 16)
    value_label.TextXAlignment = Enum.TextXAlignment.Right

    -- The touch target is taller than the drawn bar so a fingertip can grab it.
    local track_hitbox = create('TextButton', {
        Name = 'hitbox',
        Parent = holder,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 22 or 16),
        Text = '',
        AutoButtonColor = false,
    })

    local bar = create('Frame', {
        Name = 'bar',
        Parent = track_hitbox,
        BackgroundColor3 = Theme.Element,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, bar_height),
    })
    corner(bar, 3)
    stroke(bar, Theme.Stroke)

    local fill = accent(create('Frame', {
        Name = 'slide',
        Parent = bar,
        BackgroundColor3 = Library.Accent,
        Size = UDim2.new(0, 0, 1, 0),
    }), { 'BackgroundColor3' })
    corner(fill, 3)

    local knob = create('Frame', {
        Name = 'knob',
        Parent = bar,
        BackgroundColor3 = Theme.Text,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(is_touch() and 14 or 10, is_touch() and 14 or 10),
        ZIndex = 2,
    })
    corner(knob, 20)

    local value = math.clamp(default, minimum, maximum)
    local api = {}

    local function round(number)
        if increment <= 0 then
            return number
        end
        local rounded = math.floor((number - minimum) / increment + 0.5) * increment + minimum
        -- Kill floating point dust so 0.30000000000000004 never reaches the label.
        return tonumber(string.format('%.6f', rounded))
    end

    local function paint()
        local alpha = maximum == minimum and 0 or (value - minimum) / (maximum - minimum)
        tween(fill, QUAD, { Size = UDim2.new(alpha, 0, 1, 0) })
        tween(knob, QUAD, { Position = UDim2.new(alpha, 0, 0.5, 0) })
        local shown = value
        if increment >= 1 then
            shown = math.round(value)
        end
        value_label.Text = tostring(shown) .. suffix
    end

    function api:Set(new_value, silent)
        value = math.clamp(round(tonumber(new_value) or minimum), minimum, maximum)
        paint()
        if flag then
            Library.Flags[flag] = value
        end
        if not silent then
            task.spawn(function()
                local ok, err = pcall(callback, value)
                if not ok then
                    warn('[centrl] slider callback error: ' .. tostring(err))
                end
            end)
            if not ignore_saved then
                autosave()
            end
        end
    end

    function api:Get()
        return value
    end

    api.SetValue, api.set_value = api.Set, api.Set

    local dragging = false
    local function update_from(input)
        local absolute = bar.AbsolutePosition.X
        local width = math.max(bar.AbsoluteSize.X, 1)
        local alpha = math.clamp((input_position(input).X - absolute) / width, 0, 1)
        api:Set(minimum + alpha * (maximum - minimum))
    end

    track(track_hitbox.InputBegan:Connect(function(input)
        if not is_press(input) then
            return
        end
        if not claim_drag(api) then
            return
        end
        dragging = true
        update_from(input)
        tween(knob, QUAD, { Size = UDim2.fromOffset(is_touch() and 18 or 13, is_touch() and 18 or 13) })
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and is_move(input) then
            update_from(input)
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        if dragging and is_press(input) then
            dragging = false
            release_drag(api)
            tween(knob, QUAD, { Size = UDim2.fromOffset(is_touch() and 14 or 10, is_touch() and 14 or 10) })
        end
    end))

    if flag and not ignore_saved then
        register_flag(flag, value, function(new_value)
            api:Set(new_value, false)
        end)
        if tonumber(Library.Flags[flag]) then
            value = math.clamp(tonumber(Library.Flags[flag]), minimum, maximum)
        end
    elseif flag then
        Library.Flags[flag] = value
    end

    paint()
    task.spawn(function()
        pcall(callback, value)
    end)
    return api
end

--// Element: textbox --------------------------------------------------------

function Section:Textbox(options)
    options = options or {}
    local title = pick(options, 'Textbox', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local placeholder = tostring(pick(options, '...', 'Placeholder', 'placeholder', 'PlaceholderText'))
    local default = tostring(pick(options, '', 'Default', 'default', 'Value', 'value'))
    local clear_on_focus = pick(options, false, 'ClearOnFocus', 'Clearonlost', 'clear_on_focus')
    local callback = pick(options, function() end, 'Callback', 'callback')

    local holder = create('Frame', {
        Name = 'inputbox',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (is_touch() and 50 or 44)),
        LayoutOrder = self:_next(),
    })

    local title_label = label(holder, title, 12, nil, Theme.SubText)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, 0, 0, 15)

    local field = create('Frame', {
        Parent = holder,
        BackgroundColor3 = Theme.Element,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 30 or 25),
    })
    corner(field, 5)
    local field_stroke = stroke(field, Theme.Stroke)
    padding(field, 0, 0, 8, 8)

    local box_props = text_props(12, nil, Theme.Text)
    box_props.Parent = field
    box_props.Size = UDim2.new(1, 0, 1, 0)
    box_props.Text = default
    box_props.PlaceholderText = placeholder
    box_props.PlaceholderColor3 = Theme.Dim
    box_props.ClearTextOnFocus = clear_on_focus and true or false
    box_props.ClipsDescendants = true
    local box = create('TextBox', box_props)
    box.Name = 'TextBox'

    local api = {}
    function api:Set(value, silent)
        box.Text = tostring(value)
        if flag then
            Library.Flags[flag] = box.Text
        end
        if not silent then
            task.spawn(function()
                pcall(callback, box.Text)
            end)
        end
    end
    function api:Get()
        return box.Text
    end
    api.SetValue, api.set_value = api.Set, api.Set

    track(box.Focused:Connect(function()
        tween(field_stroke, QUAD, { Color = Library.Accent })
    end))
    track(box.FocusLost:Connect(function(enter)
        tween(field_stroke, QUAD, { Color = Theme.Stroke })
        if flag then
            Library.Flags[flag] = box.Text
        end
        task.spawn(function()
            local ok, err = pcall(callback, box.Text, enter)
            if not ok then
                warn('[centrl] textbox callback error: ' .. tostring(err))
            end
        end)
        autosave()
    end))

    if flag then
        register_flag(flag, default, function(value)
            api:Set(value, false)
        end)
        if typeof(Library.Flags[flag]) == 'string' then
            box.Text = Library.Flags[flag]
        end
    end

    return api
end

Section.Input = Section.Textbox

--// Element: dropdown -------------------------------------------------------

function Section:Dropdown(options)
    options = options or {}
    local title = pick(options, 'Dropdown', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local choices = pick(options, {}, 'Options', 'options', 'Values', 'List')
    local multi = pick(options, false, 'Multi', 'multi', 'multi_dropdown', 'MultiSelect')
    local default = pick(options, nil, 'Default', 'default', 'Value', 'value', 'currentoption')
    local callback = pick(options, function() end, 'Callback', 'callback')
    local ignore_saved = pick(options, false, 'IgnoreSaved', 'ignoresaved')

    local head_height = is_touch() and 30 or 25
    local option_height = is_touch() and 30 or 25

    local holder = create('Frame', {
        Name = 'dropdown',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
        ClipsDescendants = false,
    })
    list(holder, 5)

    local title_label = label(holder, title, 12, nil, Theme.SubText)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, 0, 0, 15)
    title_label.LayoutOrder = 0

    local head = create('TextButton', {
        Name = 'dropframe',
        Parent = holder,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.new(1, 0, 0, head_height),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = 1,
    })
    corner(head, 5)
    local head_stroke = stroke(head, Theme.Stroke)
    hover(head, Theme.Element, Theme.ElementHover)

    local selected_label = label(head, '...', 12, nil, Theme.Text)
    selected_label.Name = 'selected'
    selected_label.Position = UDim2.new(0, 8, 0, 0)
    selected_label.Size = UDim2.new(1, -28, 1, 0)
    selected_label.TextTruncate = Enum.TextTruncate.AtEnd

    local arrow = create('ImageLabel', {
        Name = 'arrow',
        Parent = head,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -7, 0.5, 0),
        Size = UDim2.fromOffset(12, 12),
        Image = 'rbxassetid://6034818372',
        ImageColor3 = Theme.SubText,
    })

    -- The list expands inline instead of floating: nothing to clip against the
    -- scrolling column, and a phone can scroll the page with it open.
    local container = create('ScrollingFrame', {
        Name = 'containerF',
        Parent = holder,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.new(1, 0, 0, 0),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Visible = false,
        LayoutOrder = 2,
        ClipsDescendants = true,
    })
    corner(container, 5)
    stroke(container, Theme.Stroke)
    padding(container, 4, 4, 4, 4)
    list(container, 3)
    sink_scroll(container)

    local selection = multi and {} or nil
    local option_buttons = {}
    local api = {}
    local open = false

    local function selection_text()
        if multi then
            local names = {}
            for _, name in ipairs(choices) do
                if selection[tostring(name)] then
                    table.insert(names, tostring(name))
                end
            end
            if #names == 0 then
                return '...'
            end
            return table.concat(names, ', ')
        end
        return selection == nil and '...' or tostring(selection)
    end

    local function paint_options()
        for name, entry in pairs(option_buttons) do
            local active = multi and selection[name] or (not multi and selection == name)
            tween(entry.label, QUAD, { TextColor3 = active and Library.Accent or Theme.SubText })
            tween(entry.button, QUAD, { BackgroundTransparency = active and 0 or 1 })
        end
        selected_label.Text = selection_text()
    end

    local function current_value()
        if not multi then
            return selection
        end
        local out = {}
        for _, name in ipairs(choices) do
            if selection[tostring(name)] then
                table.insert(out, tostring(name))
            end
        end
        return out
    end

    local function fire(silent)
        local value = current_value()
        if flag then
            Library.Flags[flag] = value
        end
        if not silent then
            task.spawn(function()
                local ok, err = pcall(callback, value, selection)
                if not ok then
                    warn('[centrl] dropdown callback error: ' .. tostring(err))
                end
            end)
            if not ignore_saved then
                autosave()
            end
        end
    end

    local function set_open(state)
        open = state and true or false
        local target = 0
        if open then
            target = math.min(#choices * (option_height + 3) + 8, is_touch() and 150 or 132)
        end
        container.Visible = true
        tween(container, QUART, { Size = UDim2.new(1, 0, 0, target) })
        tween(arrow, QUART, { Rotation = open and 180 or 0 })
        tween(head_stroke, QUAD, { Color = open and Library.Accent or Theme.Stroke })
        if not open then
            task.delay(0.3, function()
                if not open then
                    container.Visible = false
                end
            end)
        end
    end

    local function build_options()
        for _, entry in pairs(option_buttons) do
            entry.button:Destroy()
        end
        table.clear(option_buttons)
        for index, raw in ipairs(choices) do
            local name = tostring(raw)
            local button = create('TextButton', {
                Name = 'op',
                Parent = container,
                BackgroundColor3 = Theme.ElementHover,
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, option_height),
                Text = '',
                AutoButtonColor = false,
                LayoutOrder = index,
            })
            corner(button, 4)
            local option_label = label(button, name, 12, nil, Theme.SubText)
            option_label.Size = UDim2.new(1, -12, 1, 0)
            option_label.Position = UDim2.new(0, 8, 0, 0)
            option_label.TextTruncate = Enum.TextTruncate.AtEnd

            option_buttons[name] = { button = button, label = option_label }

            track(button.MouseButton1Click:Connect(function()
                if multi then
                    selection[name] = not selection[name] or nil
                else
                    selection = name
                    set_open(false)
                end
                paint_options()
                fire(false)
            end))
        end
        paint_options()
        if open then
            set_open(true)
        end
    end

    function api:Set(value, silent)
        if multi then
            selection = {}
            if typeof(value) == 'table' then
                for key, entry in pairs(value) do
                    if entry == true then
                        selection[tostring(key)] = true
                    else
                        selection[tostring(entry)] = true
                    end
                end
            elseif value ~= nil then
                selection[tostring(value)] = true
            end
        else
            selection = value == nil and nil or tostring(value)
        end
        paint_options()
        fire(silent)
    end

    function api:Get()
        return current_value()
    end

    function api:SetOptions(new_options)
        choices = new_options or {}
        if not multi and selection ~= nil then
            local found = false
            for _, name in ipairs(choices) do
                if tostring(name) == selection then
                    found = true
                end
            end
            if not found then
                selection = nil
            end
        end
        build_options()
        selected_label.Text = selection_text()
    end

    api.SetValue, api.set_value, api.set_options = api.Set, api.Set, api.SetOptions

    track(head.MouseButton1Click:Connect(function()
        set_open(not open)
    end))

    build_options()

    if default ~= nil then
        api:Set(default, true)
    end

    if flag and not ignore_saved then
        register_flag(flag, api:Get(), function(value)
            api:Set(value, false)
        end)
        if Library.Flags[flag] ~= nil then
            api:Set(Library.Flags[flag], true)
        end
    elseif flag then
        fire(true)
    end

    task.spawn(function()
        pcall(callback, api:Get())
    end)
    return api
end

--// Element: keybind --------------------------------------------------------

local KEY_SHORTHAND = {
    LeftControl = 'LCtrl', RightControl = 'RCtrl',
    LeftShift = 'LShift', RightShift = 'RShift',
    LeftAlt = 'LAlt', RightAlt = 'RAlt',
    MouseButton1 = 'MB1', MouseButton2 = 'MB2', MouseButton3 = 'MB3',
}

local function key_name(key)
    if typeof(key) ~= 'EnumItem' then
        return 'None'
    end
    return KEY_SHORTHAND[key.Name] or key.Name
end

function Section:Keybind(options)
    options = options or {}
    local title = pick(options, 'Keybind', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local default = pick(options, nil, 'Default', 'default', 'Key', 'Keybind1')
    local callback = pick(options, function() end, 'Callback', 'callback')
    local changed = pick(options, function() end, 'ChangedCallback', 'changed_callback')

    if typeof(default) == 'string' then
        default = Enum.KeyCode[default]
    end

    local row = self:_row()
    local title_label = label(row, title, 12, nil, Theme.SubText)
    title_label.Size = UDim2.new(1, -90, 1, 0)

    local button = create('TextButton', {
        Name = 'Bind',
        Parent = row,
        BackgroundColor3 = Theme.Element,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(0, 84, 0, is_touch() and 26 or 22),
        Text = '',
        AutoButtonColor = false,
    })
    corner(button, 4)
    local button_stroke = stroke(button, Theme.Stroke)
    hover(button, Theme.Element, Theme.ElementHover)

    local key_label = label(button, key_name(default), 11, 'semi', Theme.Text)
    key_label.Name = 'a'
    key_label.Size = UDim2.new(1, -6, 1, 0)
    key_label.Position = UDim2.new(0, 3, 0, 0)
    key_label.TextXAlignment = Enum.TextXAlignment.Center
    key_label.TextTruncate = Enum.TextTruncate.AtEnd

    local current = default
    local listening = false
    local api = {}

    function api:Set(key, silent)
        if typeof(key) == 'string' then
            key = Enum.KeyCode[key]
        end
        current = typeof(key) == 'EnumItem' and key or nil
        key_label.Text = key_name(current)
        if flag then
            Library.Flags[flag] = current
            Library.Keybinds[flag] = current
        end
        if not silent then
            task.spawn(function()
                pcall(changed, current)
            end)
            autosave()
        end
    end

    function api:Get()
        return current
    end

    api.SetKey, api.set_key = api.Set, api.Set

    track(button.MouseButton1Click:Connect(function()
        if listening then
            return
        end
        listening = true
        key_label.Text = '...'
        tween(button_stroke, QUAD, { Color = Library.Accent })
        local connection
        connection = UserInputService.InputBegan:Connect(function(input, processed)
            if processed then
                return
            end
            if input.UserInputType == Enum.UserInputType.Keyboard then
                connection:Disconnect()
                listening = false
                tween(button_stroke, QUAD, { Color = Theme.Stroke })
                if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Escape then
                    api:Set(nil)
                else
                    api:Set(input.KeyCode)
                end
            end
        end)
        track(connection)
        -- Nothing to listen for without a keyboard; say so instead of hanging.
        if is_touch() and not UserInputService.KeyboardEnabled then
            task.delay(0.05, function()
                if listening then
                    connection:Disconnect()
                    listening = false
                    key_label.Text = key_name(current)
                    tween(button_stroke, QUAD, { Color = Theme.Stroke })
                    Library:Notify({ Title = 'keybind', Content = 'No keyboard attached on this device.', Type = 'warning', Duration = 3 })
                end
            end)
        end
    end))

    track(UserInputService.InputBegan:Connect(function(input, processed)
        if processed or listening or not current then
            return
        end
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == current then
            task.spawn(function()
                local ok, err = pcall(callback, current)
                if not ok then
                    warn('[centrl] keybind callback error: ' .. tostring(err))
                end
            end)
        end
    end))

    if flag then
        register_flag(flag, current, function(value)
            api:Set(value, true)
        end)
        if typeof(Library.Flags[flag]) == 'EnumItem' then
            api:Set(Library.Flags[flag], true)
        else
            Library.Flags[flag] = current
        end
    end

    return api
end

--// Element: colorpicker ----------------------------------------------------

function Section:Colorpicker(options)
    options = options or {}
    local title = pick(options, 'Color', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local default = pick(options, Library.Accent, 'Default', 'default', 'Color', 'Value', 'value')
    local callback = pick(options, function() end, 'Callback', 'callback')
    local ignore_saved = pick(options, false, 'IgnoreSaved', 'ignoresaved')

    if typeof(default) ~= 'Color3' then
        default = Library.Accent
    end

    local holder = create('Frame', {
        Name = 'colorpicker',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
    })
    list(holder, 6)

    local head = create('TextButton', {
        Name = 'head',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, row_height()),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = 0,
    })
    local title_label = label(head, title, 12, nil, Theme.SubText)
    title_label.Size = UDim2.new(1, -50, 1, 0)

    local swatch = create('Frame', {
        Name = 'swatch',
        Parent = head,
        BackgroundColor3 = default,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(is_touch() and 34 or 30, is_touch() and 20 or 17),
    })
    corner(swatch, 4)
    stroke(swatch, Theme.Stroke)

    local container = create('Frame', {
        Name = 'container',
        Parent = holder,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        LayoutOrder = 1,
        ClipsDescendants = true,
    })
    corner(container, 5)
    stroke(container, Theme.Stroke)

    local inner = create('Frame', {
        Parent = container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
    })
    padding(inner, 8, 8, 8, 8)
    list(inner, 6)

    local picker_height = is_touch() and 108 or 92

    local sv_row = create('Frame', {
        Parent = inner,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, picker_height),
        LayoutOrder = 0,
    })

    local sv = create('ImageButton', {
        Name = 'SVPicker',
        Parent = sv_row,
        BackgroundColor3 = Color3.fromHSV(0, 1, 1),
        Size = UDim2.new(1, -(is_touch() and 26 or 22), 1, 0),
        AutoButtonColor = false,
        Image = '',
    })
    corner(sv, 4)

    -- Saturation ramp: opaque white on the left fading to the raw hue on the
    -- right. It has to be its own overlay — a gradient on the square itself
    -- would just make the right half see-through.
    local saturation_shade = create('Frame', {
        Parent = sv,
        BackgroundColor3 = Color3.new(1, 1, 1),
        Size = UDim2.new(1, 0, 1, 0),
        BorderSizePixel = 0,
        ZIndex = 2,
    })
    corner(saturation_shade, 4)
    create('UIGradient', {
        Parent = saturation_shade,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
    })

    local value_shade = create('Frame', {
        Parent = sv,
        BackgroundColor3 = Color3.new(0, 0, 0),
        Size = UDim2.new(1, 0, 1, 0),
        BorderSizePixel = 0,
        ZIndex = 3,
    })
    corner(value_shade, 4)
    create('UIGradient', {
        Parent = value_shade,
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        }),
    })

    local sv_pin = create('Frame', {
        Name = 'Pin',
        Parent = sv,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(10, 10),
        ZIndex = 5,
    })
    corner(sv_pin, 10)
    stroke(sv_pin, Color3.new(1, 1, 1), 0, 2)

    local hue = create('ImageButton', {
        Name = 'Hue',
        Parent = sv_row,
        BackgroundColor3 = Color3.new(1, 1, 1),
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 0),
        Size = UDim2.new(0, is_touch() and 18 or 14, 1, 0),
        AutoButtonColor = false,
        Image = '',
    })
    corner(hue, 4)
    create('UIGradient', {
        Parent = hue,
        Rotation = 90,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
            ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
            ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
            ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
            ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
            ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
            ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
        }),
    })
    local hue_pin = create('Frame', {
        Name = 'Pin',
        Parent = hue,
        BackgroundColor3 = Color3.new(1, 1, 1),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, 0),
        Size = UDim2.new(1, 4, 0, 3),
        ZIndex = 3,
    })
    corner(hue_pin, 2)
    stroke(hue_pin, Color3.new(0, 0, 0), 0.5, 1)

    local entry_row = create('Frame', {
        Parent = inner,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, is_touch() and 28 or 24),
        LayoutOrder = 1,
    })
    local entry_layout = list(entry_row, 6, Enum.FillDirection.Horizontal)
    entry_layout.VerticalAlignment = Enum.VerticalAlignment.Center

    local function entry_box(name, width, placeholder)
        local field = create('Frame', {
            Name = name,
            Parent = entry_row,
            BackgroundColor3 = Theme.Section,
            Size = UDim2.new(width, 0, 1, 0),
        })
        corner(field, 4)
        stroke(field, Theme.Stroke)
        padding(field, 0, 0, 6, 6)
        local props = text_props(11, nil, Theme.Text)
        props.Parent = field
        props.Size = UDim2.new(1, 0, 1, 0)
        props.Text = ''
        props.PlaceholderText = placeholder
        props.PlaceholderColor3 = Theme.Dim
        props.ClearTextOnFocus = false
        props.ClipsDescendants = true
        return create('TextBox', props)
    end

    local hex_box = entry_box('HEX', 0.4, '#FFFFFF')
    hex_box.Name = 'HEXBox'
    local rgb_box = entry_box('RGB', 0.56, '255, 255, 255')
    rgb_box.Name = 'RGBBox'

    local action_row = create('Frame', {
        Parent = inner,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, is_touch() and 26 or 22),
        LayoutOrder = 2,
    })
    local action_layout = list(action_row, 6, Enum.FillDirection.Horizontal)
    action_layout.VerticalAlignment = Enum.VerticalAlignment.Center

    local function small_button(text, width, order)
        local button = create('TextButton', {
            Parent = action_row,
            BackgroundColor3 = Theme.Section,
            Size = UDim2.new(width, 0, 1, 0),
            Text = '',
            AutoButtonColor = false,
            LayoutOrder = order,
        })
        corner(button, 4)
        stroke(button, Theme.Stroke)
        local button_label = label(button, text, 11, 'semi', Theme.SubText)
        button_label.Size = UDim2.new(1, 0, 1, 0)
        button_label.TextXAlignment = Enum.TextXAlignment.Center
        hover(button, Theme.Section, Theme.ElementHover)
        return button, button_label
    end

    local rainbow_button, rainbow_label = small_button('rainbow', 0.48, 0)
    local copy_button, copy_label = small_button('copy hex', 0.48, 1)

    local h, s, v = Color3.toHSV(default)
    local color = default
    local rainbow = false
    local rainbow_connection
    local open = false
    local api = {}

    local function fire(silent)
        if flag then
            Library.Flags[flag] = color
        end
        if not silent then
            task.spawn(function()
                local ok, err = pcall(callback, color)
                if not ok then
                    warn('[centrl] colorpicker callback error: ' .. tostring(err))
                end
            end)
            if not ignore_saved then
                autosave()
            end
        end
    end

    local function paint(update_boxes)
        color = Color3.fromHSV(h, s, v)
        swatch.BackgroundColor3 = color
        sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        sv_pin.Position = UDim2.new(s, 0, 1 - v, 0)
        hue_pin.Position = UDim2.new(0.5, 0, h, 0)
        if update_boxes ~= false then
            hex_box.Text = to_hex(color)
            rgb_box.Text = to_rgb_string(color)
        end
    end

    function api:Set(new_color, silent)
        if typeof(new_color) == 'string' then
            new_color = from_hex(new_color) or from_rgb_string(new_color)
        end
        if typeof(new_color) ~= 'Color3' then
            return
        end
        h, s, v = Color3.toHSV(new_color)
        paint(true)
        fire(silent)
    end

    function api:Get()
        return color
    end

    api.SetColor, api.set_color = api.Set, api.Set

    local function set_open(state)
        open = state and true or false
        container.Visible = true
        local target = open and (inner.AbsoluteSize.Y / math.max(Library._scale, 0.01)) or 0
        if open and target < 10 then
            target = picker_height + (is_touch() and 90 or 76)
        end
        tween(container, QUART, { Size = UDim2.new(1, 0, 0, open and target or 0) })
        if not open then
            task.delay(0.3, function()
                if not open then
                    container.Visible = false
                end
            end)
        end
    end

    track(head.MouseButton1Click:Connect(function()
        set_open(not open)
    end))
    track(inner:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
        if open then
            container.Size = UDim2.new(1, 0, 0, inner.AbsoluteSize.Y / math.max(Library._scale, 0.01))
        end
    end))

    -- SV square and hue bar both track the input's own position so a finger
    -- drags them exactly like a mouse does.
    local sv_dragging, hue_dragging = false, false

    local function update_sv(input)
        local position = input_position(input)
        local origin = sv.AbsolutePosition
        local size = sv.AbsoluteSize
        s = math.clamp((position.X - origin.X) / math.max(size.X, 1), 0, 1)
        v = 1 - math.clamp((position.Y - origin.Y) / math.max(size.Y, 1), 0, 1)
        paint(true)
        fire(false)
    end

    local function update_hue(input)
        local position = input_position(input)
        local origin = hue.AbsolutePosition
        local size = hue.AbsoluteSize
        h = math.clamp((position.Y - origin.Y) / math.max(size.Y, 1), 0, 1)
        paint(true)
        fire(false)
    end

    track(sv.InputBegan:Connect(function(input)
        if not is_press(input) or not claim_drag(api) then
            return
        end
        sv_dragging = true
        update_sv(input)
    end))
    track(hue.InputBegan:Connect(function(input)
        if not is_press(input) or not claim_drag(api) then
            return
        end
        hue_dragging = true
        update_hue(input)
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if not is_move(input) then
            return
        end
        if sv_dragging then
            update_sv(input)
        elseif hue_dragging then
            update_hue(input)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if is_press(input) and (sv_dragging or hue_dragging) then
            sv_dragging, hue_dragging = false, false
            release_drag(api)
        end
    end))

    track(hex_box.FocusLost:Connect(function()
        local parsed = from_hex(hex_box.Text)
        if parsed then
            api:Set(parsed)
        else
            hex_box.Text = to_hex(color)
        end
    end))
    track(rgb_box.FocusLost:Connect(function()
        local parsed = from_rgb_string(rgb_box.Text)
        if parsed then
            api:Set(parsed)
        else
            rgb_box.Text = to_rgb_string(color)
        end
    end))

    track(rainbow_button.MouseButton1Click:Connect(function()
        rainbow = not rainbow
        rainbow_label.TextColor3 = rainbow and Library.Accent or Theme.SubText
        if rainbow_connection then
            rainbow_connection:Disconnect()
            rainbow_connection = nil
        end
        if rainbow then
            rainbow_connection = RunService.RenderStepped:Connect(function(delta)
                h = (h + delta * 0.15) % 1
                paint(true)
                fire(false)
            end)
            track(rainbow_connection)
        end
    end))

    track(copy_button.MouseButton1Click:Connect(function()
        if set_clipboard then
            pcall(set_clipboard, to_hex(color))
            copy_label.Text = 'copied'
        else
            copy_label.Text = to_hex(color)
        end
        task.delay(1.2, function()
            copy_label.Text = 'copy hex'
        end)
    end))

    paint(true)

    if flag and not ignore_saved then
        register_flag(flag, color, function(value)
            api:Set(value, false)
        end)
        if typeof(Library.Flags[flag]) == 'Color3' then
            api:Set(Library.Flags[flag], true)
        end
    elseif flag then
        Library.Flags[flag] = color
    end

    task.spawn(function()
        pcall(callback, color)
    end)
    return api
end

Section.ColorPicker = Section.Colorpicker
Section.Color = Section.Colorpicker

-- lowercase aliases, matching the original library's call style
Section.create_toggle = Section.Toggle
Section.create_checkbox = Section.Toggle
Section.create_slider = Section.Slider
Section.create_dropdown = Section.Dropdown
Section.create_textbox = Section.Textbox
Section.create_button = Section.Button
Section.create_keybind = Section.Keybind
Section.create_colorpicker = Section.Colorpicker
Section.create_label = Section.Label
Section.create_paragraph = Section.Paragraph
Section.create_divider = Section.Divider

--// Built-in settings tab ---------------------------------------------------

function Window:_build_settings_tab()
    if self.SettingsTab then
        return self.SettingsTab
    end

    local tab = self:Tab({ Title = 'settings', Icon = 'settings' })
    self.SettingsTab = tab

    local interface = tab:Section({ Title = 'interface', Side = 'left' })

    interface:Colorpicker({
        Title = 'accent',
        Flag = 'centrl_accent',
        Default = Library.Accent,
        Callback = function(color)
            Library:SetAccent(color)
        end,
    })

    interface:Slider({
        Title = 'ui scale',
        Flag = 'centrl_scale',
        Min = 0.5,
        Max = 2,
        Increment = 0.05,
        Default = Library._user_scale,
        Callback = function(value)
            Library:SetScale(value)
        end,
    })

    interface:Keybind({
        Title = 'toggle key',
        Flag = 'centrl_toggle_key',
        Default = self.ToggleKey,
        ChangedCallback = function(key)
            self:SetToggleKey(key or Enum.KeyCode.RightShift)
        end,
    })

    if self.MobileButton then
        interface:Toggle({
            Title = 'floating button',
            Flag = 'centrl_mobile_button',
            Default = true,
            Callback = function(state)
                self.MobileButton.Visible = state
            end,
        })
    end

    interface:Toggle({
        Title = 'save on change',
        Flag = 'centrl_autosave',
        Default = Config.enabled,
        IgnoreSaved = true,
        Callback = function(state)
            Config.enabled = state
        end,
    })

    local configs = tab:Section({ Title = 'configs', Side = tab.SingleColumn and 'left' or 'right' })

    if not HAS_FILE_API then
        configs:Label({ Text = 'No file API in this environment — configs cannot be saved.' })
        return tab
    end

    local name_box = configs:Textbox({
        Title = 'config name',
        Placeholder = 'default',
    })

    local list_dropdown
    local function refresh()
        if list_dropdown then
            list_dropdown:SetOptions(Library:ListConfigs())
        end
    end

    list_dropdown = configs:Dropdown({
        Title = 'saved configs',
        Options = Library:ListConfigs(),
        IgnoreSaved = true,
    })

    configs:Button({
        Title = 'save',
        Callback = function()
            local name = name_box:Get()
            if name == '' then
                Library:Notify({ Title = 'configs', Content = 'Give the config a name first.', Type = 'warning' })
                return
            end
            local ok = Library:SaveConfig(name)
            refresh()
            Library:Notify({
                Title = 'configs',
                Content = ok and ('Saved "' .. name .. '"') or 'Save failed.',
                Type = ok and 'success' or 'error',
            })
        end,
    })

    configs:Button({
        Title = 'load',
        Callback = function()
            local name = list_dropdown:Get() or name_box:Get()
            if not name or name == '' then
                Library:Notify({ Title = 'configs', Content = 'Pick a config to load.', Type = 'warning' })
                return
            end
            local ok = Library:LoadConfig(name)
            Library:Notify({
                Title = 'configs',
                Content = ok and ('Loaded "' .. name .. '"') or 'Load failed.',
                Type = ok and 'success' or 'error',
            })
        end,
    })

    configs:Button({
        Title = 'delete',
        Callback = function()
            local name = list_dropdown:Get() or name_box:Get()
            if not name or name == '' then
                return
            end
            local ok = Library:DeleteConfig(name)
            refresh()
            Library:Notify({
                Title = 'configs',
                Content = ok and ('Deleted "' .. name .. '"') or 'Delete failed.',
                Type = ok and 'success' or 'error',
            })
        end,
    })

    configs:Button({
        Title = 'refresh list',
        Callback = refresh,
    })

    return tab
end

--// Compatibility aliases ---------------------------------------------------

-- Every alias below accepts either call style, so `Library.new(t)` and
-- `Library:new(t)` both land on the same place.
local function first_of(kind, a, b)
    if typeof(a) == kind then
        return a
    end
    if typeof(b) == kind then
        return b
    end
    return nil
end

Window.create_tab = Window.Tab
Window.AddTab = Window.Tab
Window.set_toggle_key = Window.SetToggleKey
Window.set_scale = function(a, b)
    Library:SetScale(tonumber(b) or tonumber(a) or 1)
end
Window.set_accent = function(a, b)
    Library:SetAccent(first_of('Color3', a, b))
end
Window.UIVisiblity = function(self)
    self:SetVisible(not self.Visible)
end
Window.change_visiblity = Window.SetOpen
Window.load = Window.Load
Window.unload = Window.Destroy

Library.new = function(a, b)
    return Library:Window(first_of('table', b, a) or {})
end
Library.CreateWindow = Library.new
Library.MakeWindow = Library.new
Library.set_accent = function(a, b)
    Library:SetAccent(first_of('Color3', a, b))
end
Library.save_config = function(a, b)
    return Library:SaveConfig(first_of('string', a, b))
end
Library.load_config = function(a, b)
    return Library:LoadConfig(first_of('string', a, b))
end
Library.list_configs = function()
    return Library:ListConfigs()
end

Library.Version = '2.0.0'


--// Top tab strip + topbar menu icon ----------------------------------------
-- Merged in from https://raw.githubusercontent.com/iamdookie1/inf/refs/heads/main/source.txt
-- (a build of Infinite Yield that reflows Centrl's own left tab rail into a
-- horizontal strip across the top of the window instead of building a
-- parallel one) plus a hand-built 3-line menu icon in the topbar. These are
-- the only two changes; everything above this point is Lib2 exactly as
-- published. Both patches use the library's own real internals (create,
-- corner, stroke, accent, hover, Theme, Window, Tab, TOPBAR_HEIGHT, ...)
-- rather than reimplementing them, since this code lives inside the same
-- closure as the rest of the library.

local TOP_TAB_STRIP_HEIGHT = 40
local TOP_TAB_BUTTON_WIDTH = 100

-- tab.Button/.TitleLabel/.Indicator are the library's real instances for
-- this tab (Window:Tab() already exposes them) - only their layout changes,
-- from "full rail width, left-aligned, fixed height" to "fixed width,
-- centered, fills the strip's height".
local function restyle_tab_for_top(tab)
    tab.Button.Size = UDim2.new(0, TOP_TAB_BUTTON_WIDTH, 1, 0)

    tab.TitleLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    tab.TitleLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
    tab.TitleLabel.Size = UDim2.new(1, -8, 1, 0)
    tab.TitleLabel.TextXAlignment = Enum.TextXAlignment.Center

    -- Select() still animates Indicator's Size every time a tab is picked
    -- (hardcoded inside Tab:Select, not something reachable to stop from
    -- here) - Visible = false makes that animation a no-op rather than a
    -- small leftover tick on the left edge of a horizontally laid out
    -- button, since the title color change alone already shows which tab
    -- is active.
    tab.Indicator.Visible = false
end

-- Patched once on the shared class table, so it covers every tab on every
-- window from here on, including the library's own auto-built settings tab
-- (built via self:Tab() inside Window() itself, before this file returns).
local _original_tab = Window.Tab
function Window:Tab(options)
    local tab = _original_tab(self, options)
    restyle_tab_for_top(tab)
    return tab
end
Window.tab = Window.Tab

-- Moves the library's own tab rail (tabholder) from a left-side vertical
-- strip to a horizontal one across the top, then repositions Pages to sit
-- below it instead of beside it. Every tab button keeps the library's real
-- hover state, active-tab styling and click wiring - only the chrome
-- changes.
local function reflow_rail_to_top(win)
    local content = win.Root.body.content
    local rail = content:FindFirstChild('tabholder')
    if not rail then return end

    rail.Size = UDim2.new(1, 0, 0, TOP_TAB_STRIP_HEIGHT)
    rail.Position = UDim2.new(0, 0, 0, 0)

    -- The rail's own divider is a plain unnamed Frame on its right edge (a
    -- vertical line, correct for a left rail) - move it to the bottom edge.
    local divider = rail:FindFirstChildWhichIsA('Frame')
    if divider then
        divider.Position = UDim2.new(0, 0, 1, -1)
        divider.Size = UDim2.new(1, 0, 0, 1)
    end

    local tab_scroll = win.TabScroll
    tab_scroll.Position = UDim2.new(0, 0, 0, 0)
    tab_scroll.Size = UDim2.new(1, 0, 1, -1)
    tab_scroll.ScrollingDirection = Enum.ScrollingDirection.X
    tab_scroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    tab_scroll.CanvasSize = UDim2.new(0, 0, 0, 0)

    local scroll_padding = tab_scroll:FindFirstChildWhichIsA('UIPadding')
    if scroll_padding then
        scroll_padding.PaddingTop = UDim.new(0, 4)
        scroll_padding.PaddingBottom = UDim.new(0, 4)
        scroll_padding.PaddingLeft = UDim.new(0, 10)
        scroll_padding.PaddingRight = UDim.new(0, 10)
    end

    local scroll_list = tab_scroll:FindFirstChildWhichIsA('UIListLayout')
    if scroll_list then
        scroll_list.FillDirection = Enum.FillDirection.Horizontal
        scroll_list.Padding = UDim.new(0, 6)
        scroll_list.VerticalAlignment = Enum.VerticalAlignment.Center
    end

    win.Pages.Position = UDim2.new(0, 0, 0, TOP_TAB_STRIP_HEIGHT)
    win.Pages.Size = UDim2.new(1, 0, 1, -TOP_TAB_STRIP_HEIGHT)
end

-- Hand-built 3-line menu icon, added into the topbar's existing "controls"
-- strip (same row as the minimise/close buttons, left of them via
-- LayoutOrder) rather than a new standalone frame, so it inherits the same
-- AutomaticSize layout for free. The three bars are BackgroundColor3 frames
-- registered through accent() - the same live-recolor mechanism the logo
-- and tab indicators use - so they track Library:SetAccent() like every
-- other accented element, not a static color baked in at build time.
local function add_menu_icon(win)
    local topbar = win.Root.body.topbar
    local controls = topbar and topbar:FindFirstChild('controls')
    if not controls then return end

    local size = is_touch() and 26 or 20
    local button = create('TextButton', {
        Name = 'menu',
        Parent = controls,
        BackgroundColor3 = Theme.Element,
        Size = UDim2.fromOffset(size, size),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = -1,
    })
    corner(button, 4)
    stroke(button, Theme.Stroke)
    hover(button, Theme.Element, Theme.ElementHover)

    local bar_height = 2
    local bar_gap = 4
    local bars = create('Frame', {
        Name = 'bars',
        Parent = button,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(math.floor(size * 0.5), bar_height * 3 + bar_gap * 2),
    })
    list(bars, bar_gap).VerticalAlignment = Enum.VerticalAlignment.Center
    for i = 1, 3 do
        local bar = accent(create('Frame', {
            Name = 'bar' .. i,
            Parent = bars,
            BackgroundColor3 = Library.Accent,
            BorderSizePixel = 0,
            LayoutOrder = i,
            Size = UDim2.new(1, 0, 0, bar_height),
        }), { 'BackgroundColor3' })
        corner(bar, 1)
    end

    track(button.MouseButton1Click:Connect(function()
        win:SetOpen(not win.Open)
    end))
end

local _original_window = Library.Window
function Library:Window(options)
    local win = _original_window(self, options)
    reflow_rail_to_top(win)
    add_menu_icon(win)
    return win
end
Library.window = Library.Window

return Library

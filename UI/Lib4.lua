--[[
    Centrl UI Library — Lib4
    ------------------------
    Lib3 wore Fluent's clothes. This one wears Obsidian's - deividcomsono's
    library (github.com/deividcomsono/Obsidian) - over the same Centrl
    engine, because a flat, sharp, high-contrast tool-window reads better on
    a screen crowded with a dozen other cheat menus than a translucent one
    does. Lib3 is gone; nothing in this repo loads it anymore.

    The API did not move. Every element, every option alias, every returned
    method is identical to Lib2 and Lib3 before it, so pointing a script here
    is still a one-line URL change.

    Kept from Centrl (Obsidian has no answer for these):
      - Two scrolling columns of section cards instead of one long list
      - Icon tab rail with sub-tabs and badges
      - Console, Stat, Progress, Image, RangeSlider and Buttons elements
      - Per-game config saving, named config files, a built-in settings tab
      - Real mobile support: touch drag, touch sliders, a unibar button so a
        phone can open the panel without a keyboard

    Taken from Obsidian:
      - Flat, opaque cards instead of Fluent's translucent acrylic glass -
        no gradient body, no film-grain overlay, nothing to see through
      - A crisp, actually-visible outline around the whole window, the way
        Obsidian's AddOutline does it, instead of a stroke set to invisible
      - Sharp corners (4px on cards, matching Obsidian's own default) in
        place of Fluent's rounded pill look
      - Squared-off toggle and slider chrome instead of a fully round pill
        and a circular grab handle
      - A bigger baseline scale. Obsidian's own scale system
        (Library.DPIScale / Library:SetDPIScale) is a raw, direct multiplier
        with no dampening layered over it - set it and every UIScale it
        drives updates immediately. Centrl's own Library:SetScale used to run
        every request back through a viewport-fit calculation meant only for
        the very first paint, which could visibly blunt a slider drag on a
        smaller screen. It no longer does that - see the scale note below.

    Scale - "bigger without being bigger":
      The window's own on-screen footprint does not change. Its logical grid
      (WINDOW_WIDTH/HEIGHT) shrinks by BASE_SCALE, and the baseline UI scale
      grows by the same factor, so the two cancel out for the outer window -
      same pixels on screen - while everything drawn inside it (text, rows,
      padding, icons, everything) renders BASE_SCALE times bigger, because it
      is all authored in that shrunken logical grid and then scaled back up
      by the one UIScale every root object already carries. Nudging the 'ui
      scale' slider in Settings afterward moves every registered UIScale the
      instant it moves - directly, the way Obsidian's SetDPIScale does it,
      not softened by anything.

    Usage:
      local Centrl = loadstring(game:HttpGet('.../Lib4.lua'))()
      local Window = Centrl:Window({ Title = 'centrl', Folder = 'centrl' })
      local Tab    = Window:Tab({ Title = 'Legit', Icon = 'target' })
      local Sec    = Tab:Section({ Title = 'Aimbot', Side = 'left' })
      Sec:Toggle({ Title = 'Enabled', Desc = 'lock to the closest head',
                   Flag = 'aim_enabled', Callback = f })
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

-- Same on-screen window, bigger-reading everything inside it: see the
-- scale note at the top of the file. The logical grid shrinks by this
-- factor and the baseline UIScale grows by it, which cancel out for the
-- window's own footprint but not for anything drawn inside it.
local BASE_SCALE = 1.15
local WINDOW_WIDTH, WINDOW_HEIGHT = 640 / BASE_SCALE, 424 / BASE_SCALE
local TAB_RAIL_WIDTH = 132
local TOPBAR_HEIGHT = 42
local SCREEN_MARGIN = 24

local Library = {
    Flags = {},
    Keybinds = {},
    _windows = {},
    _accent_objects = setmetatable({}, { __mode = 'k' }),
    _theme_objects = setmetatable({}, { __mode = 'k' }),
    _scale_objects = setmetatable({}, { __mode = 'k' }),
    _connections = {},
    _unloaded = false,
    Accent = Color3.fromRGB(227, 255, 42),
}

-- Obsidian's own Scheme table works the same way it does here: a flat set of
-- colour roles, with properties set by role name (its ThemeManager reads
-- string keys like 'DarkColor' off Library.Scheme) so a theme swap is a
-- repaint rather than a rebuild. `Theme` is the live table, `Themes` holds
-- the presets, and `themed()` further down registers an object against the
-- roles it reads so SetTheme can walk them.
--
-- Backdrop is the body fill and the rail behind it. Every theme has to
-- define the full set - a missing key would leave whatever the previous
-- theme painted, which reads as a bug rather than a theme.
Library.Themes = {
    Dark = {
        Accent = Color3.fromRGB(227, 255, 42),
        Backdrop = Color3.fromRGB(12, 12, 12),
        Border = Color3.fromRGB(58, 58, 58),
        Topbar = Color3.fromRGB(20, 20, 20),
        Rail = Color3.fromRGB(18, 18, 18),
        Section = Color3.fromRGB(19, 19, 19),
        Element = Color3.fromRGB(30, 30, 30),
        ElementHover = Color3.fromRGB(52, 52, 52),
        Stroke = Color3.fromRGB(58, 58, 58),
        StrokeSoft = Color3.fromRGB(40, 40, 40),
        Text = Color3.fromRGB(238, 238, 238),
        SubText = Color3.fromRGB(150, 152, 162),
        Dim = Color3.fromRGB(100, 100, 100),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 96, 106),
        Info = Color3.fromRGB(120, 180, 255),
    },
    Charcoal = {
        Accent = Color3.fromRGB(90, 160, 255),
        Backdrop = Color3.fromRGB(14, 14, 14),
        Border = Color3.fromRGB(66, 66, 66),
        Topbar = Color3.fromRGB(22, 22, 22),
        Rail = Color3.fromRGB(19, 19, 19),
        Section = Color3.fromRGB(21, 21, 21),
        Element = Color3.fromRGB(33, 33, 33),
        ElementHover = Color3.fromRGB(56, 56, 56),
        Stroke = Color3.fromRGB(68, 68, 68),
        StrokeSoft = Color3.fromRGB(44, 44, 44),
        Text = Color3.fromRGB(240, 240, 240),
        SubText = Color3.fromRGB(170, 170, 170),
        Dim = Color3.fromRGB(110, 110, 110),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 96, 106),
        Info = Color3.fromRGB(120, 180, 255),
    },
    ['Deep Violet'] = {
        Accent = Color3.fromRGB(150, 110, 235),
        Backdrop = Color3.fromRGB(14, 10, 20),
        Border = Color3.fromRGB(110, 90, 140),
        Topbar = Color3.fromRGB(26, 19, 38),
        Rail = Color3.fromRGB(22, 16, 32),
        Section = Color3.fromRGB(24, 17, 35),
        Element = Color3.fromRGB(58, 45, 80),
        ElementHover = Color3.fromRGB(86, 68, 116),
        Stroke = Color3.fromRGB(92, 73, 122),
        StrokeSoft = Color3.fromRGB(56, 42, 76),
        Text = Color3.fromRGB(245, 240, 252),
        SubText = Color3.fromRGB(176, 162, 200),
        Dim = Color3.fromRGB(122, 108, 146),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 110, 130),
        Info = Color3.fromRGB(150, 180, 255),
    },
    ['Blood Red'] = {
        Accent = Color3.fromRGB(226, 62, 68),
        Backdrop = Color3.fromRGB(16, 8, 9),
        Border = Color3.fromRGB(120, 58, 62),
        Topbar = Color3.fromRGB(28, 14, 15),
        Rail = Color3.fromRGB(23, 11, 12),
        Section = Color3.fromRGB(25, 12, 14),
        Element = Color3.fromRGB(58, 26, 29),
        ElementHover = Color3.fromRGB(90, 40, 44),
        Stroke = Color3.fromRGB(104, 50, 54),
        StrokeSoft = Color3.fromRGB(60, 30, 33),
        Text = Color3.fromRGB(250, 238, 238),
        SubText = Color3.fromRGB(196, 156, 158),
        Dim = Color3.fromRGB(140, 104, 106),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 120, 128),
        Info = Color3.fromRGB(150, 180, 255),
    },
    ['Neon Purple'] = {
        Accent = Color3.fromRGB(196, 82, 255),
        Backdrop = Color3.fromRGB(12, 8, 18),
        Border = Color3.fromRGB(132, 74, 178),
        Topbar = Color3.fromRGB(24, 14, 34),
        Rail = Color3.fromRGB(20, 12, 29),
        Section = Color3.fromRGB(22, 13, 32),
        Element = Color3.fromRGB(55, 33, 77),
        ElementHover = Color3.fromRGB(84, 50, 116),
        Stroke = Color3.fromRGB(102, 60, 140),
        StrokeSoft = Color3.fromRGB(58, 35, 82),
        Text = Color3.fromRGB(246, 238, 255),
        SubText = Color3.fromRGB(184, 162, 208),
        Dim = Color3.fromRGB(130, 110, 152),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 110, 130),
        Info = Color3.fromRGB(150, 180, 255),
    },
    ['Deep Ocean'] = {
        Accent = Color3.fromRGB(56, 178, 222),
        Backdrop = Color3.fromRGB(8, 14, 20),
        Border = Color3.fromRGB(58, 108, 136),
        Topbar = Color3.fromRGB(14, 26, 36),
        Rail = Color3.fromRGB(11, 21, 30),
        Section = Color3.fromRGB(13, 24, 33),
        Element = Color3.fromRGB(27, 50, 67),
        ElementHover = Color3.fromRGB(42, 78, 104),
        Stroke = Color3.fromRGB(52, 97, 125),
        StrokeSoft = Color3.fromRGB(30, 56, 74),
        Text = Color3.fromRGB(236, 246, 252),
        SubText = Color3.fromRGB(152, 180, 198),
        Dim = Color3.fromRGB(106, 132, 150),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 110, 120),
        Info = Color3.fromRGB(120, 190, 255),
    },
    ['Midnight Blue'] = {
        Accent = Color3.fromRGB(88, 124, 255),
        Backdrop = Color3.fromRGB(9, 11, 20),
        Border = Color3.fromRGB(70, 84, 148),
        Topbar = Color3.fromRGB(16, 20, 38),
        Rail = Color3.fromRGB(13, 16, 31),
        Section = Color3.fromRGB(15, 18, 35),
        Element = Color3.fromRGB(33, 39, 72),
        ElementHover = Color3.fromRGB(52, 62, 110),
        Stroke = Color3.fromRGB(64, 76, 135),
        StrokeSoft = Color3.fromRGB(36, 43, 78),
        Text = Color3.fromRGB(238, 242, 255),
        SubText = Color3.fromRGB(158, 168, 206),
        Dim = Color3.fromRGB(110, 120, 158),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 110, 130),
        Info = Color3.fromRGB(140, 180, 255),
    },
    Rose = {
        Accent = Color3.fromRGB(244, 114, 160),
        Backdrop = Color3.fromRGB(18, 10, 14),
        Border = Color3.fromRGB(128, 68, 92),
        Topbar = Color3.fromRGB(30, 16, 22),
        Rail = Color3.fromRGB(25, 13, 18),
        Section = Color3.fromRGB(27, 14, 20),
        Element = Color3.fromRGB(61, 33, 44),
        ElementHover = Color3.fromRGB(94, 51, 67),
        Stroke = Color3.fromRGB(109, 59, 78),
        StrokeSoft = Color3.fromRGB(62, 34, 45),
        Text = Color3.fromRGB(252, 240, 245),
        SubText = Color3.fromRGB(202, 164, 178),
        Dim = Color3.fromRGB(144, 110, 124),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 120, 130),
        Info = Color3.fromRGB(150, 180, 255),
    },
    AMOLED = {
        Accent = Color3.fromRGB(255, 255, 255),
        Backdrop = Color3.fromRGB(0, 0, 0),
        Border = Color3.fromRGB(52, 52, 52),
        Topbar = Color3.fromRGB(0, 0, 0),
        Rail = Color3.fromRGB(0, 0, 0),
        Section = Color3.fromRGB(6, 6, 6),
        Element = Color3.fromRGB(20, 20, 20),
        ElementHover = Color3.fromRGB(38, 38, 38),
        Stroke = Color3.fromRGB(50, 50, 50),
        StrokeSoft = Color3.fromRGB(30, 30, 30),
        Text = Color3.fromRGB(245, 245, 245),
        SubText = Color3.fromRGB(150, 150, 150),
        Dim = Color3.fromRGB(96, 96, 96),
        Success = Color3.fromRGB(126, 217, 87),
        Warning = Color3.fromRGB(255, 196, 87),
        Error = Color3.fromRGB(255, 96, 106),
        Info = Color3.fromRGB(120, 180, 255),
    },
    ['Pearl White'] = {
        Accent = Color3.fromRGB(58, 110, 220),
        Backdrop = Color3.fromRGB(226, 228, 233),
        Border = Color3.fromRGB(188, 192, 200),
        Topbar = Color3.fromRGB(242, 243, 246),
        Rail = Color3.fromRGB(236, 238, 242),
        Section = Color3.fromRGB(246, 247, 250),
        Element = Color3.fromRGB(255, 255, 255),
        ElementHover = Color3.fromRGB(233, 236, 242),
        Stroke = Color3.fromRGB(190, 194, 204),
        StrokeSoft = Color3.fromRGB(212, 216, 224),
        Text = Color3.fromRGB(26, 28, 34),
        SubText = Color3.fromRGB(104, 110, 124),
        Dim = Color3.fromRGB(146, 152, 164),
        Success = Color3.fromRGB(46, 160, 67),
        Warning = Color3.fromRGB(196, 130, 20),
        Error = Color3.fromRGB(206, 54, 62),
        Info = Color3.fromRGB(48, 118, 214),
    },
}

Library.ThemeNames = {
    'Dark', 'Charcoal', 'Deep Violet', 'Blood Red', 'Neon Purple',
    'Deep Ocean', 'Midnight Blue', 'Rose', 'AMOLED', 'Pearl White',
}

Library.ThemeName = 'Dark'

-- The live table every builder reads. Populated from a preset rather than
-- replaced, so the `Theme` upvalue every element captured stays valid.
Library.Theme = {}
for key, value in pairs(Library.Themes.Dark) do
    Library.Theme[key] = value
end

local Theme = Library.Theme

-- Obsidian's cards are flat and opaque, not glass - low enough that a card
-- still reads as slightly lifted off the body, nowhere near Fluent's 0.86.
local ELEMENT_TRANSPARENCY = 0.08
local ELEMENT_TRANSPARENCY_HOVER = 0
local CARD_CORNER = 4

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

local function desc_of(options)
    return pick(options, nil, 'Desc', 'desc', 'Description', 'description', 'SubText', 'Sub')
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

-- Anything the library puts *outside* its own ScreenGui has to clean itself up
-- explicitly, because destroying ScreenGui will not touch it. The unibar icon
-- lives in CoreGui.TopBarApp, so it registers here.
Library._teardowns = {}

local function on_unload(fn)
    table.insert(Library._teardowns, fn)
    return fn
end

local function run_teardowns()
    for _, fn in pairs(Library._teardowns) do
        pcall(fn)
    end
    table.clear(Library._teardowns)
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

-- `themed(frame, { BackgroundColor3 = 'Element' })` both paints an instance
-- now and records the role it was painted with, so SetTheme can repaint it
-- later without the caller having kept a reference around to do it.
local function themed(object, roles)
    Library._theme_objects[object] = roles
    for property, role in pairs(roles) do
        local value = Theme[role]
        if value ~= nil then
            pcall(function()
                object[property] = value
            end)
        end
    end
    return object
end

function Library:SetTheme(name)
    local preset = self.Themes[name]
    if not preset then return false end
    self.ThemeName = name

    -- Mutated in place: every element captured this exact table as an upvalue
    -- when it was built, so swapping the table itself would leave them all
    -- reading the old one.
    for key, value in pairs(preset) do
        Theme[key] = value
    end

    for object, roles in pairs(self._theme_objects) do
        if typeof(object) == 'Instance' and object.Parent then
            for property, role in pairs(roles) do
                local value = Theme[role]
                if value ~= nil then
                    pcall(function()
                        object[property] = value
                    end)
                end
            end
        end
    end

    -- Themes carry their own accent, but a user who has explicitly picked one
    -- in settings has said what they want and the theme does not get to
    -- overrule it.
    if not self._accent_pinned and preset.Accent then
        self:SetAccent(preset.Accent)
    end
    return true
end

Library.set_theme = Library.SetTheme

-- The single biggest visual difference from Lib2: Lib2 laid elements out as
-- bare rows on the section background; this gives each one its own flat,
-- opaque, bordered card - Obsidian's own look, not Fluent's translucent
-- one. Everything else here is detail; this is the look.
--
-- `inner` is the frame children are positioned against - usually a full-size
-- click target sitting inside the card. The inset goes on that rather than on
-- the card, so the whole card stays clickable right up to its edge instead of
-- losing a 10px dead border.
-- pad_top/pad_bottom are arguments rather than a second padding() call by the
-- caller: Roblox only honours one UIPadding per frame, so adding a second one
-- silently does nothing (or worse, wins over the first) instead of stacking.
local function cardify(frame, inner, pad_top, pad_bottom)
    frame.BackgroundTransparency = ELEMENT_TRANSPARENCY
    themed(frame, { BackgroundColor3 = 'Element' })
    corner(frame, CARD_CORNER)
    local border = create('UIStroke', {
        Parent = frame,
        Color = Theme.Stroke,
        Transparency = 0.18,
        Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
    themed(border, { Color = 'Stroke' })
    padding(inner or frame, pad_top or 0, pad_bottom or pad_top or 0, 10, 10)
    return frame, border
end

-- A card that lights up under the cursor.
local function card_hover(frame)
    track(frame.MouseEnter:Connect(function()
        tween(frame, QUAD, { BackgroundTransparency = ELEMENT_TRANSPARENCY_HOVER })
    end))
    track(frame.MouseLeave:Connect(function()
        tween(frame, QUAD, { BackgroundTransparency = ELEMENT_TRANSPARENCY })
    end))
    return frame
end

-- An optional description line under an element's title. Lib2 had no
-- equivalent, so this adds one without disturbing elements that pass no
-- description: the card only grows when there is something to show.
local function attach_desc(card, title_label, text, extra_height)
    if not text or text == '' then return nil end
    card.Size = UDim2.new(card.Size.X.Scale, card.Size.X.Offset, 0,
        card.Size.Y.Offset + (extra_height or 14))

    title_label.Position = UDim2.new(title_label.Position.X.Scale,
        title_label.Position.X.Offset, 0, 7)
    title_label.Size = UDim2.new(title_label.Size.X.Scale, title_label.Size.X.Offset, 0, 15)
    title_label.TextYAlignment = Enum.TextYAlignment.Center

    local desc = create('TextLabel', {
        Name = 'desc',
        Parent = title_label.Parent,
        BackgroundTransparency = 1,
        Position = UDim2.new(title_label.Position.X.Scale, title_label.Position.X.Offset, 0, 22),
        Size = UDim2.new(title_label.Size.X.Scale, title_label.Size.X.Offset, 0, 13),
        Text = tostring(text),
        TextSize = 11,
        TextColor3 = Theme.SubText,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        FontFace = FONT_REGULAR,
    })
    themed(desc, { TextColor3 = 'SubText' })
    return desc
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
    -- Direct, the way Obsidian's SetDPIScale is direct: whatever the caller
    -- set _user_scale to is what every UIScale gets, full stop. The
    -- viewport-fit maths in auto_scale only ever runs once, to pick where
    -- _user_scale starts out - see Window() below - so it can never again
    -- dampen a scale someone actually asked for.
    Library._scale = math.clamp(Library._user_scale, 0.35, 2)
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

-- Sub-tabs are tabs that live inside another tab rather than on the rail.
-- They share Tab's section builder but need their own Select, because Tab's
-- iterates window.Tabs and a sub-tab is deliberately not in that list.
local SubTab = {}
SubTab.__index = SubTab

function Library:Window(options)
    options = options or {}

    local title = pick(options, 'centrl', 'Title', 'title', 'Name')
    local subtitle = pick(options, 'v2', 'SubTitle', 'Subtitle', 'subtitle', 'Version')
    local logo = pick(options, 'rbxassetid://18404006294', 'Logo', 'logo', 'Icon')
    local folder = pick(options, 'centrl', 'Folder', 'folder', 'ConfigFolder')
    local toggle_key = pick(options, Enum.KeyCode.RightShift, 'ToggleKey', 'toggle_key', 'Keybind')
    local accent_color = pick(options, nil, 'Accent', 'accent', 'AccentColor')
    local theme_name = pick(options, nil, 'Theme', 'theme', 'ThemeName')
    local user_scale = tonumber(pick(options, BASE_SCALE, 'Scale', 'scale')) or BASE_SCALE

    -- Applied before anything is built, so every element picks the right
    -- colours up front rather than being repainted a frame later. An explicit
    -- Accent still wins: it is set after this and pins itself.
    if theme_name and Library.Themes[theme_name] then
        Library:SetTheme(theme_name)
    end
    if accent_color then
        Library._accent_pinned = true
    end
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
    Library._user_scale = auto_scale(user_scale)
    Library._scale = Library._user_scale

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
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 1,
        ClipsDescendants = false,
        Visible = false,
    })
    register_scale(create('UIScale', { Parent = root }))
    corner(root, 8)
    -- Obsidian outlines the whole window in a real, visible line rather than
    -- a stroke set to Transparency = 1 - it is what separates the panel from
    -- whatever game is behind it, now that the body has no acrylic edge of
    -- its own to do that job.
    local root_stroke = stroke(root, Theme.Border, 0.25)
    themed(root_stroke, { Color = 'Border' })

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

    -- Obsidian is flat, not glass: one solid fill, no gradient, no grain, no
    -- DepthOfField pass on the camera to fight every other script that
    -- touches Lighting.
    local fill = create('Frame', {
        Name = 'fill',
        Parent = body,
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0,
        Size = UDim2.new(1, 0, 1, 0),
        BorderSizePixel = 0,
        ZIndex = 0,
    })
    themed(fill, { BackgroundColor3 = 'Backdrop' })
    corner(fill, 8)

    --// Topbar --------------------------------------------------------------

    -- Transparent over the flat body with only a hairline under it - the same
    -- treatment Obsidian's own TopBar uses, and it means there is only ever
    -- one fill colour to keep in sync (the body's), not two.
    local topbar = create('Frame', {
        Name = 'topbar',
        Parent = body,
        BackgroundColor3 = Theme.Topbar,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, TOPBAR_HEIGHT),
        BorderSizePixel = 0,
    })
    local topbar_line = create('Frame', {
        Name = 'bar',
        Parent = topbar,
        BackgroundColor3 = Theme.Border,
        BackgroundTransparency = 0.5,
        Position = UDim2.new(0, 0, 1, -1),
        Size = UDim2.new(1, 0, 0, 1),
        BorderSizePixel = 0,
    })
    themed(topbar_line, { BackgroundColor3 = 'Border' })

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

    local title_label = accent(label(topbar, title, 16, 'bold'), { 'TextColor3' })
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
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.15,
        Size = UDim2.new(0, TAB_RAIL_WIDTH, 1, 0),
        BorderSizePixel = 0,
    })
    themed(rail, { BackgroundColor3 = 'Backdrop' })
    local rail_line = create('Frame', {
        Parent = rail,
        BackgroundColor3 = Theme.Border,
        BackgroundTransparency = 0.2,
        Position = UDim2.new(1, -1, 0, 0),
        Size = UDim2.new(0, 1, 1, 0),
        BorderSizePixel = 0,
    })
    themed(rail_line, { BackgroundColor3 = 'Border' })

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

    -- A resize no longer touches scale - ApplyScale is a direct passthrough
    -- now, so re-running it here would only ever reproduce the same number.
    -- What a resize still needs is the window kept on screen.
    track(Camera:GetPropertyChangedSignal('ViewportSize'):Connect(function()
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

-- Looks a rail tab up by title so a script can jump the menu to a page
-- without keeping a reference to every handle it ever made. Titles are
-- matched exactly; nested pages are reached with tab:GetTab(...).
function Window:GetTab(title)
    for _, tab in pairs(self.Tabs) do
        if tab.Title == title then
            return tab
        end
    end
    return nil
end

function Window:SelectTab(title)
    local tab = self:GetTab(title)
    if tab then
        tab:Select()
    end
    return tab
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
    run_teardowns()
    pcall(function()
        ScreenGui:Destroy()
    end)
    table.clear(Library._windows)
    Library:ClearIconCache()
end

Library.Destroy = Library.Unload

--// Tabs -------------------------------------------------------------------

-- Taller than Lib2's 28: a row is a card now, and a card needs room for the
-- border and the text to not sit against it.
local ROW_HEIGHT = 38
local TOUCH_ROW_HEIGHT = 44

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
    corner(button, 4)

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

    -- Hidden until something calls Tab:SetBadge. It sits in the gap the title
    -- label already leaves on the right, so a badge never pushes text around.
    local badge = accent(create('Frame', {
        Name = 'badge',
        Parent = button,
        BackgroundColor3 = Library.Accent,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.new(0, 0, 0, 15),
        AutomaticSize = Enum.AutomaticSize.X,
        Visible = false,
        ZIndex = 2,
    }), { 'BackgroundColor3' })
    corner(badge, 6)
    padding(badge, 0, 0, 5, 5)
    local badge_label = label(badge, '', 10, 'bold', Theme.Backdrop)
    badge_label.Name = 'count'
    badge_label.Size = UDim2.new(0, 0, 1, 0)
    badge_label.AutomaticSize = Enum.AutomaticSize.X
    badge_label.TextXAlignment = Enum.TextXAlignment.Center
    badge_label.ZIndex = 2

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
    tab.Badge = badge
    tab.BadgeLabel = badge_label
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

--// Sub-tabs (tabs inside tabs) ---------------------------------------------

-- A rail entry can host its own row of tabs instead of one long wall of
-- sections. `tab:Tab({ Title = 'melee' })` puts a horizontal strip at the top
-- of that tab's page and gives each entry a real page underneath, two columns
-- and all, so "combat" can hold melee / ranged / misc without spending three
-- slots on the rail.

local SUB_STRIP_HEIGHT = 30
local TOUCH_SUB_STRIP_HEIGHT = 34

local function sub_strip_height()
    return is_touch() and TOUCH_SUB_STRIP_HEIGHT or SUB_STRIP_HEIGHT
end

-- Built the first time a tab is asked for a sub-tab. Until then a tab looks
-- and behaves exactly as it always has, so nothing already written against
-- the library changes shape.
function Tab:_ensure_sub_host()
    if self.SubHost then
        return
    end

    local strip_height = sub_strip_height()

    local strip = create('ScrollingFrame', {
        Name = 'substrip',
        Parent = self.Page,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(1, 0, 0, strip_height),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
        ScrollBarThickness = 0,
        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
        ZIndex = 2,
    })
    list(strip, 6, Enum.FillDirection.Horizontal)
    sink_scroll(strip)

    -- A hairline under the strip so the row reads as a tab bar and not a
    -- loose cluster of buttons floating above the content.
    create('Frame', {
        Name = 'subline',
        Parent = self.Page,
        BackgroundColor3 = Theme.Stroke,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, strip_height),
        Size = UDim2.new(1, 0, 0, 1),
    })

    local host = create('Frame', {
        Name = 'subpages',
        Parent = self.Page,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 0, 0, strip_height + 7),
        Size = UDim2.new(1, 0, 1, -(strip_height + 7)),
    })

    -- The tab's own columns stop being used the moment it hosts sub-tabs.
    -- Hiding them matters beyond tidiness: sink_scroll marks them Active, and
    -- an active scrolling frame sitting under the sub-pages would eat touch
    -- drags meant for the content on top of it.
    self.Left.Visible = false
    if self.Right and self.Right ~= self.Left then
        self.Right.Visible = false
    end

    self.SubStrip = strip
    self.SubHost = host
    self.SubTabs = {}
end

function Tab:Tab(options)
    options = options or {}
    local title = pick(options, 'Tab', 'Title', 'title', 'Name')
    local icon = pick(options, nil, 'Icon', 'icon', 'Image')

    self:_ensure_sub_host()

    local sub = setmetatable({}, SubTab)
    sub.Window = self.Window
    sub.Parent = self
    sub.ParentTab = self
    sub.Title = title
    sub.Sections = {}

    local strip_height = sub_strip_height()

    -- Each entry is only as wide as its own label, so a strip of short names
    -- doesn't waste half the row. AutomaticSize.X on the button follows
    -- AutomaticSize.X on `content`, which in turn follows its list layout --
    -- the indicator stays a direct child of the button precisely so the
    -- layout never sees it and never reserves a slot for it.
    local button = create('TextButton', {
        Name = 'stb',
        Parent = self.SubStrip,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = 1,
        Size = UDim2.new(0, 0, 0, strip_height - 6),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = #self.SubTabs + 1,
    })
    corner(button, 5)
    padding(button, 0, 0, 12, 12)

    local content = create('Frame', {
        Name = 'content',
        Parent = button,
        BackgroundTransparency = 1,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
    })
    local content_layout = list(content, 6, Enum.FillDirection.Horizontal)
    content_layout.VerticalAlignment = Enum.VerticalAlignment.Center

    local icon_image
    if icon then
        icon_image = create('ImageLabel', {
            Name = 'icon',
            Parent = content,
            BackgroundTransparency = 1,
            Size = UDim2.fromOffset(16, 16),
            ImageColor3 = Theme.SubText,
            LayoutOrder = 0,
        })
        Library:ApplyIcon(icon_image, icon, ui_icon_options(16))
    end

    local title_label = label(content, title, 12, 'semi', Theme.SubText)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(0, 0, 1, 0)
    title_label.AutomaticSize = Enum.AutomaticSize.X
    title_label.TextXAlignment = Enum.TextXAlignment.Center
    title_label.LayoutOrder = 1

    local badge = accent(create('Frame', {
        Name = 'badge',
        Parent = content,
        BackgroundColor3 = Library.Accent,
        Size = UDim2.new(0, 0, 0, 15),
        AutomaticSize = Enum.AutomaticSize.X,
        Visible = false,
        LayoutOrder = 2,
    }), { 'BackgroundColor3' })
    corner(badge, 6)
    padding(badge, 0, 0, 5, 5)
    local badge_label = label(badge, '', 10, 'bold', Theme.Backdrop)
    badge_label.Name = 'count'
    badge_label.Size = UDim2.new(0, 0, 1, 0)
    badge_label.AutomaticSize = Enum.AutomaticSize.X
    badge_label.TextXAlignment = Enum.TextXAlignment.Center

    local indicator = accent(create('Frame', {
        Name = 'indi',
        Parent = button,
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 0),
        Size = UDim2.new(0, 0, 0, 2),
        BorderSizePixel = 0,
    }), { 'BackgroundColor3' })
    corner(indicator, 1)

    local page = create('Frame', {
        Name = 'subpage',
        Parent = self.SubHost,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        Visible = false,
    })

    local single_column = is_touch()
    local left = make_column(page, 'L', single_column and 1 or 0.5, 0, 0)
    local right
    if single_column then
        left.Size = UDim2.new(1, -6, 1, 0)
    else
        right = make_column(page, 'R', 0.5, 0.5, 6)
    end

    sub.Button = button
    sub.Indicator = indicator
    sub.TitleLabel = title_label
    sub.IconImage = icon_image
    sub.Badge = badge
    sub.BadgeLabel = badge_label
    sub.Page = page
    sub.Left = left
    sub.Right = right or left
    sub.SingleColumn = single_column

    track(button.MouseButton1Click:Connect(function()
        sub:Select()
    end))
    hover(button, Theme.Element, Theme.ElementHover)

    table.insert(self.SubTabs, sub)

    if #self.SubTabs == 1 then
        -- Sections added before the first sub-tab existed migrate into it, so
        -- `tab:Section(...)` followed later by `tab:Tab(...)` yields one
        -- coherent page instead of content stranded on the hidden layer.
        if #self.Sections > 0 then
            local has_right = self.Right ~= self.Left
            for _, section in pairs(self.Sections) do
                local on_right = has_right and section.Card.Parent == self.Right
                section.Card.Parent = on_right and sub.Right or sub.Left
                section.Card.LayoutOrder = #sub.Sections + 1
                section.Tab = sub
                table.insert(sub.Sections, section)
            end
            table.clear(self.Sections)
        end
        sub:Select()
    end

    return sub
end

Tab.SubTab = Tab.Tab
Tab.create_tab = Tab.Tab
Tab.AddTab = Tab.Tab

function SubTab:Select()
    local parent = self.Parent
    for _, other in pairs(parent.SubTabs) do
        if other ~= self then
            other.Page.Visible = false
            tween(other.Button, QUAD, { BackgroundTransparency = 1 })
            tween(other.TitleLabel, QUAD, { TextColor3 = Theme.SubText })
            tween(other.Indicator, QUART, { Size = UDim2.new(0, 0, 0, 2) })
            if other.IconImage then
                tween(other.IconImage, QUAD, { ImageColor3 = Theme.SubText })
            end
        end
    end
    self.Page.Visible = true
    parent.ActiveSubTab = self
    tween(self.Button, QUAD, { BackgroundTransparency = 0 })
    tween(self.TitleLabel, QUAD, { TextColor3 = Theme.Text })
    tween(self.Indicator, QUART, { Size = UDim2.new(0.62, 0, 0, 2) })
    if self.IconImage then
        tween(self.IconImage, QUAD, { ImageColor3 = Library.Accent })
    end
end

-- Select() only swaps the sub-page; Focus() also brings the parent tab
-- forward, which is what a caller jumping here from elsewhere in the menu
-- actually wants.
function SubTab:Focus()
    self.Parent:Select()
    self:Select()
end

function SubTab:SetTitle(text)
    self.Title = tostring(text)
    self.TitleLabel.Text = self.Title
end

function SubTab:SetIcon(icon)
    if not self.IconImage or icon == nil then
        return
    end
    Library:ApplyIcon(self.IconImage, icon, ui_icon_options(16))
end

SubTab.select = SubTab.Select
SubTab.focus = SubTab.Focus
SubTab.set_title = SubTab.SetTitle
SubTab.set_icon = SubTab.SetIcon

-- Finds a sub-tab by title, so scripts can jump to one without holding a
-- reference to every handle they ever made.
function Tab:GetTab(title)
    if not self.SubTabs then
        return nil
    end
    for _, sub in pairs(self.SubTabs) do
        if sub.Title == title then
            return sub
        end
    end
    return nil
end

function Tab:SelectTab(title)
    local sub = self:GetTab(title)
    if sub then
        sub:Select()
    end
    return sub
end

--// Tab decoration ----------------------------------------------------------

function Tab:SetTitle(text)
    self.Title = tostring(text)
    self.TitleLabel.Text = self.Title
end

function Tab:SetIcon(icon)
    if not self.IconImage or icon == nil then
        return
    end
    Library:ApplyIcon(self.IconImage, icon, ui_icon_options(16))
end

-- A short accent pill on the tab button: an unread count, a live "3 on", a
-- warning dot. Passing nil or '' hides it again. Rail tabs and sub-tabs both
-- carry one, so this is written once and shared below.
function Tab:SetBadge(text)
    if not self.Badge then
        return
    end
    if text == nil or text == '' or text == false then
        self.Badge.Visible = false
        return
    end
    self.BadgeLabel.Text = tostring(text)
    self.Badge.Visible = true
end

Tab.set_title = Tab.SetTitle
Tab.set_icon = Tab.SetIcon
Tab.set_badge = Tab.SetBadge


--// Sections ---------------------------------------------------------------

function Tab:Section(options)
    options = options or {}
    -- Once a tab hosts sub-tabs its own columns are hidden, so a section asked
    -- for on the parent belongs on whichever sub-page is showing. SubTab has
    -- no .SubTabs field, so reusing this same function for sub-tabs can't
    -- recurse.
    if self.SubTabs and self.SubTabs[1] then
        return (self.ActiveSubTab or self.SubTabs[1]):Section(options)
    end
    local title = pick(options, 'Section', 'Title', 'title', 'Name')
    local side = tostring(pick(options, 'left', 'Side', 'side', 'section')):lower()
    local parent = (side == 'right' or side == 'r') and self.Right or self.Left

    local section = setmetatable({}, Section)
    section.Tab = self
    section.Order = 0

    -- Nearly transparent: with every element inside now carrying its own card,
    -- a solid panel behind them would stack two backgrounds and bury the
    -- acrylic. This is a grouping outline, not a surface.
    local card = create('Frame', {
        Name = 'section',
        Parent = parent,
        BackgroundColor3 = Theme.Section,
        BackgroundTransparency = 0.55,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = #self.Sections + 1,
    })
    themed(card, { BackgroundColor3 = 'Section' })
    corner(card, 8)
    local card_border = stroke(card, Theme.StrokeSoft, 0.35)
    themed(card_border, { Color = 'StrokeSoft' })
    padding(card, 10, 12, 10, 10)
    list(card, 6)

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

-- Identical builder: a sub-tab exposes Left/Right/Sections/SingleColumn under
-- the same names a tab does, so nothing in here has to know the difference.
SubTab.Section = Tab.Section
SubTab.create_section = Tab.Section
SubTab.Groupbox = Tab.Section
SubTab.SetBadge = Tab.SetBadge
SubTab.set_badge = Tab.SetBadge

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
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
    })
    themed(holder, { BackgroundColor3 = 'Element' })
    corner(holder, CARD_CORNER)
    local para_border = stroke(holder, Theme.Stroke, 0.45)
    themed(para_border, { Color = 'Stroke' })
    padding(holder, 9, 10, 10, 10)
    list(holder, 4)

    local title_label = label(holder, title, 13, 'bold', Theme.Text)
    title_label.Size = UDim2.new(1, 0, 0, 0)
    title_label.AutomaticSize = Enum.AutomaticSize.Y
    title_label.TextWrapped = true
    themed(title_label, { TextColor3 = 'Text' })

    local body_label = label(holder, text, 12, nil, Theme.SubText)
    body_label.Size = UDim2.new(1, 0, 0, 0)
    body_label.AutomaticSize = Enum.AutomaticSize.Y
    body_label.TextWrapped = true
    body_label.LayoutOrder = 1
    themed(body_label, { TextColor3 = 'SubText' })

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

    local desc_text = desc_of(options)
    local button = create('TextButton', {
        Name = 'button',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, row_height() + (desc_text and 14 or 0)),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = self:_next(),
    })
    themed(button, { BackgroundColor3 = 'Element' })
    corner(button, CARD_CORNER)
    local btn_border = stroke(button, Theme.Stroke, 0.45)
    themed(btn_border, { Color = 'Stroke' })
    padding(button, 0, 0, 10, 10)
    card_hover(button)

    local title_label = label(button, title, 13, 'semi', Theme.Text)
    title_label.Size = UDim2.new(1, 0, 1, 0)
    title_label.TextXAlignment = desc_text and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
    themed(title_label, { TextColor3 = 'Text' })

    if desc_text then
        title_label.Size = UDim2.new(1, 0, 0, 15)
        title_label.Position = UDim2.new(0, 0, 0, 7)
        local desc = label(button, tostring(desc_text), 11, nil, Theme.SubText)
        desc.Name = 'desc'
        desc.Position = UDim2.new(0, 0, 0, 22)
        desc.Size = UDim2.new(1, 0, 0, 13)
        desc.TextTruncate = Enum.TextTruncate.AtEnd
        themed(desc, { TextColor3 = 'SubText' })
    end

    track(button.MouseButton1Click:Connect(function()
        -- A flash instead of AutoButtonColor so touch taps read as presses too.
        tween(button, TweenInfo.new(0.08), {
            BackgroundColor3 = Library.Accent,
            BackgroundTransparency = 0.2,
        })
        tween(title_label, TweenInfo.new(0.08), { TextColor3 = Theme.Backdrop })
        task.delay(0.12, function()
            tween(button, QUAD, {
                BackgroundColor3 = Theme.Element,
                BackgroundTransparency = ELEMENT_TRANSPARENCY,
            })
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

    -- A 36x18 track with a knob that slides across it, rather than Lib2's
    -- square checkbox - Obsidian's own toggle switch is the same idea, just
    -- squared off rather than a full stadium pill (see the corner() calls
    -- below). Slightly wider on touch so a thumb has something to hit.
    local track_width = is_touch() and 42 or 36
    local track_height = is_touch() and 22 or 18
    local knob_size = track_height - 4

    local row = self:_row()

    local button = create('TextButton', {
        Name = 'tog',
        Parent = row,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        Text = '',
        AutoButtonColor = false,
    })
    cardify(row, button)
    card_hover(row)

    local title_label = label(button, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Position = UDim2.new(0, 0, 0, 0)
    title_label.Size = UDim2.new(1, -(track_width + 10), 1, 0)
    themed(title_label, { TextColor3 = 'Text' })

    attach_desc(row, title_label, desc_of(options))

    local pill = create('Frame', {
        Name = 'check',
        Parent = button,
        BackgroundColor3 = Library.Accent,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(track_width, track_height),
    })
    accent(pill, { 'BackgroundColor3' })
    corner(pill, 6)
    local box_stroke = stroke(pill, Theme.SubText, 0.4)
    themed(box_stroke, { Color = 'SubText' })

    local knob = create('Frame', {
        Name = 'knob',
        Parent = pill,
        BackgroundColor3 = Theme.SubText,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(knob_size, knob_size),
    })
    corner(knob, 4)
    themed(knob, { BackgroundColor3 = 'SubText' })

    local state = default
    local api = {}

    local function paint(animated)
        local info = animated and QUINT or TweenInfo.new(0)
        local on = state
        tween(pill, info, { BackgroundTransparency = on and 0 or 1 })
        tween(knob, info, {
            Position = UDim2.new(0, on and (track_width - knob_size - 2) or 2, 0.5, 0),
            BackgroundColor3 = on and Theme.Backdrop or Theme.SubText,
        })
        tween(title_label, info, { TextColor3 = on and Theme.Text or Theme.SubText })
        tween(box_stroke, info, { Color = on and Library.Accent or Theme.SubText })
        -- Re-tag so a later theme swap repaints these to the *current* state's
        -- role rather than snapping everything back to the off colours.
        Library._theme_objects[knob] = { BackgroundColor3 = on and 'Backdrop' or 'SubText' }
        Library._theme_objects[title_label] = { TextColor3 = on and 'Text' or 'SubText' }
        if not on then
            Library._theme_objects[box_stroke] = { Color = 'SubText' }
        else
            Library._theme_objects[box_stroke] = nil
        end
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

    -- Drawn as a hairline, not a chunky bar, with a small squared-off handle
    -- doing the actual grabbing - the handle is what reads as draggable, so
    -- the rail itself can stay thin.
    local bar_height = is_touch() and 5 or 4
    local knob_size = is_touch() and 16 or 12
    local desc_text = desc_of(options)

    local holder = create('Frame', {
        Name = 'sliderframe',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (is_touch() and 58 or 52) + (desc_text and 12 or 0)),
        LayoutOrder = self:_next(),
    })

    local inner = create('Frame', {
        Name = 'inner',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(holder, inner, 8, 8)

    local title_label = label(inner, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, -70, 0, 15)
    themed(title_label, { TextColor3 = 'Text' })

    local value_label = label(inner, '', 12, 'semi', Theme.Text)
    value_label.Name = 'value'
    value_label.AnchorPoint = Vector2.new(1, 0)
    value_label.Position = UDim2.new(1, 0, 0, 0)
    value_label.Size = UDim2.new(0, 70, 0, 15)
    value_label.TextXAlignment = Enum.TextXAlignment.Right
    themed(value_label, { TextColor3 = 'Text' })

    if desc_text then
        local desc = label(inner, tostring(desc_text), 11, nil, Theme.SubText)
        desc.Name = 'desc'
        desc.Position = UDim2.new(0, 0, 0, 16)
        desc.Size = UDim2.new(1, -70, 0, 13)
        desc.TextTruncate = Enum.TextTruncate.AtEnd
        themed(desc, { TextColor3 = 'SubText' })
    end

    -- The touch target is taller than the drawn rail so a fingertip can grab it.
    local track_hitbox = create('TextButton', {
        Name = 'hitbox',
        Parent = inner,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 24 or 20),
        Text = '',
        AutoButtonColor = false,
    })

    local bar = create('Frame', {
        Name = 'bar',
        Parent = track_hitbox,
        BackgroundColor3 = Theme.SubText,
        BackgroundTransparency = 0.55,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, bar_height),
    })
    corner(bar, 2)
    themed(bar, { BackgroundColor3 = 'SubText' })

    local fill = accent(create('Frame', {
        Name = 'slide',
        Parent = bar,
        BackgroundColor3 = Library.Accent,
        Size = UDim2.new(0, 0, 1, 0),
    }), { 'BackgroundColor3' })
    corner(fill, 2)

    local knob = accent(create('Frame', {
        Name = 'knob',
        Parent = bar,
        BackgroundColor3 = Library.Accent,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(knob_size, knob_size),
        ZIndex = 2,
    }), { 'BackgroundColor3' })
    corner(knob, 4)
    -- A ring in the window colour so the handle reads as sitting on the rail
    -- rather than merging into the fill behind it.
    local knob_ring = stroke(knob, Theme.Backdrop, 0, 2)
    themed(knob_ring, { Color = 'Backdrop' })

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

--// Element: range slider --------------------------------------------------

-- Two knobs on one track, for settings that are a span rather than a point:
-- a delay picked randomly between 0.5s and 0.7s, a distance band an ESP should
-- draw inside, a damage roll. The value is a table, `{ Min = , Max = }`, which
-- survives the config round trip as-is because encode_flags copies tables
-- through untouched.
function Section:RangeSlider(options)
    options = options or {}
    local title = pick(options, 'Range', 'Title', 'title', 'Text')
    local flag = pick(options, nil, 'Flag', 'flag')
    local minimum = tonumber(pick(options, 0, 'Min', 'min', 'minimum_value', 'Minimum')) or 0
    local maximum = tonumber(pick(options, 100, 'Max', 'max', 'maximum_value', 'Maximum')) or 100
    local increment = tonumber(pick(options, 1, 'Increment', 'increment', 'round_number', 'Step')) or 1
    local suffix = tostring(pick(options, '', 'Suffix', 'suffix', 'Unit'))
    local separator = tostring(pick(options, ' - ', 'Separator', 'separator'))
    local callback = pick(options, function() end, 'Callback', 'callback')
    local ignore_saved = pick(options, false, 'IgnoreSaved', 'ignoresaved')

    -- Defaults arrive either as two keys or as one table/pair, since
    -- `Default = { 0.5, 0.7 }` is the shape people reach for first.
    local default_low = pick(options, nil, 'DefaultMin', 'defaultmin', 'LowDefault', 'ValueMin')
    local default_high = pick(options, nil, 'DefaultMax', 'defaultmax', 'HighDefault', 'ValueMax')
    local default_pair = pick(options, nil, 'Default', 'default', 'Value', 'value')
    if typeof(default_pair) == 'table' then
        default_low = default_low or default_pair.Min or default_pair.min or default_pair[1]
        default_high = default_high or default_pair.Max or default_pair.max or default_pair[2]
    end
    default_low = tonumber(default_low) or minimum
    default_high = tonumber(default_high) or maximum

    local bar_height = is_touch() and 5 or 4
    local desc_text = desc_of(options)
    local holder = create('Frame', {
        Name = 'rangeframe',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (is_touch() and 58 or 52) + (desc_text and 12 or 0)),
        LayoutOrder = self:_next(),
    })

    local inner = create('Frame', {
        Name = 'inner',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(holder, inner, 8, 8)

    local title_label = label(inner, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, -110, 0, 15)
    themed(title_label, { TextColor3 = 'Text' })

    -- Wider than the plain slider's readout: this one holds two numbers.
    local value_label = label(inner, '', 12, 'semi', Theme.Text)
    value_label.Name = 'value'
    value_label.AnchorPoint = Vector2.new(1, 0)
    value_label.Position = UDim2.new(1, 0, 0, 0)
    value_label.Size = UDim2.new(0, 110, 0, 15)
    value_label.TextXAlignment = Enum.TextXAlignment.Right
    themed(value_label, { TextColor3 = 'Text' })

    if desc_text then
        local desc = label(inner, tostring(desc_text), 11, nil, Theme.SubText)
        desc.Name = 'desc'
        desc.Position = UDim2.new(0, 0, 0, 16)
        desc.Size = UDim2.new(1, -110, 0, 13)
        desc.TextTruncate = Enum.TextTruncate.AtEnd
        themed(desc, { TextColor3 = 'SubText' })
    end

    local track_hitbox = create('TextButton', {
        Name = 'hitbox',
        Parent = inner,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 24 or 20),
        Text = '',
        AutoButtonColor = false,
    })

    local bar = create('Frame', {
        Name = 'bar',
        Parent = track_hitbox,
        BackgroundColor3 = Theme.SubText,
        BackgroundTransparency = 0.55,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, bar_height),
    })
    themed(bar, { BackgroundColor3 = 'SubText' })
    corner(bar, 2)

    -- The accent sits between the two knobs rather than running from the left
    -- edge, so the bar reads as "this span is selected".
    local fill = accent(create('Frame', {
        Name = 'slide',
        Parent = bar,
        BackgroundColor3 = Library.Accent,
        Size = UDim2.new(0, 0, 1, 0),
    }), { 'BackgroundColor3' })
    corner(fill, 3)

    local knob_size = is_touch() and 16 or 12
    local function make_knob(name)
        local knob = accent(create('Frame', {
            Name = name,
            Parent = bar,
            BackgroundColor3 = Library.Accent,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.fromOffset(knob_size, knob_size),
            ZIndex = 2,
        }), { 'BackgroundColor3' })
        corner(knob, 4)
        local ring = stroke(knob, Theme.Backdrop, 0, 2)
        themed(ring, { Color = 'Backdrop' })
        return knob
    end

    local low_knob = make_knob('knob_min')
    local high_knob = make_knob('knob_max')

    local api = {}

    local function round(number)
        if increment <= 0 then
            return number
        end
        local rounded = math.floor((number - minimum) / increment + 0.5) * increment + minimum
        return tonumber(string.format('%.6f', rounded))
    end

    local low = math.clamp(round(default_low), minimum, maximum)
    local high = math.clamp(round(default_high), minimum, maximum)
    if low > high then
        low, high = high, low
    end

    local function alpha_of(number)
        if maximum == minimum then
            return 0
        end
        return (number - minimum) / (maximum - minimum)
    end

    local function shown(number)
        if increment >= 1 then
            return math.round(number)
        end
        return number
    end

    local function paint()
        local low_alpha = alpha_of(low)
        local high_alpha = alpha_of(high)
        tween(fill, QUAD, {
            Position = UDim2.new(low_alpha, 0, 0, 0),
            Size = UDim2.new(high_alpha - low_alpha, 0, 1, 0),
        })
        tween(low_knob, QUAD, { Position = UDim2.new(low_alpha, 0, 0.5, 0) })
        tween(high_knob, QUAD, { Position = UDim2.new(high_alpha, 0, 0.5, 0) })
        value_label.Text = tostring(shown(low)) .. separator .. tostring(shown(high)) .. suffix
    end

    function api:Set(new_low, new_high, silent)
        -- Also accepts a single table, so :Set(Flags.foo) round-trips.
        if typeof(new_low) == 'table' then
            silent = new_high
            local pair = new_low
            new_low = pair.Min or pair.min or pair[1]
            new_high = pair.Max or pair.max or pair[2]
        end
        local a = math.clamp(round(tonumber(new_low) or minimum), minimum, maximum)
        local b = math.clamp(round(tonumber(new_high) or maximum), minimum, maximum)
        if a > b then
            a, b = b, a
        end
        low, high = a, b
        paint()
        if flag then
            Library.Flags[flag] = { Min = low, Max = high }
        end
        if not silent then
            task.spawn(function()
                local ok, err = pcall(callback, low, high)
                if not ok then
                    warn('[centrl] range slider callback error: ' .. tostring(err))
                end
            end)
            if not ignore_saved then
                autosave()
            end
        end
    end

    function api:SetMin(value, silent)
        api:Set(value, high, silent)
    end

    function api:SetMax(value, silent)
        api:Set(low, value, silent)
    end

    function api:Get()
        return low, high
    end

    function api:GetRange()
        return { Min = low, Max = high }
    end

    -- The reason a range control usually exists: pick a value inside it.
    function api:Random()
        if low == high then
            return low
        end
        return low + math.random() * (high - low)
    end

    api.SetValue, api.set_value = api.Set, api.Set

    local dragging = nil

    local function alpha_from(input)
        local absolute = bar.AbsolutePosition.X
        local width = math.max(bar.AbsoluteSize.X, 1)
        return math.clamp((input_position(input).X - absolute) / width, 0, 1)
    end

    local function update_from(input)
        local value = minimum + alpha_from(input) * (maximum - minimum)
        if dragging == 'low' then
            api:Set(math.min(value, high), high)
        else
            api:Set(low, math.max(value, low))
        end
    end

    -- Which knob the press belongs to. Outside the span the answer is the side
    -- you pressed on; inside it, the nearer knob. Both stacked on one spot is
    -- the case that needs the explicit test, otherwise the pair would be stuck
    -- there forever with no way to pull them apart.
    local function pick_knob(input)
        local alpha = alpha_from(input)
        local low_alpha, high_alpha = alpha_of(low), alpha_of(high)
        if alpha < low_alpha then
            return 'low'
        elseif alpha > high_alpha then
            return 'high'
        elseif math.abs(alpha - low_alpha) <= math.abs(alpha - high_alpha) then
            return 'low'
        end
        return 'high'
    end

    local function grow(knob)
        tween(knob, QUAD, { Size = UDim2.fromOffset(is_touch() and 18 or 13, is_touch() and 18 or 13) })
    end

    local function shrink(knob)
        tween(knob, QUAD, { Size = UDim2.fromOffset(is_touch() and 14 or 10, is_touch() and 14 or 10) })
    end

    track(track_hitbox.InputBegan:Connect(function(input)
        if not is_press(input) then
            return
        end
        if not claim_drag(api) then
            return
        end
        dragging = pick_knob(input)
        grow(dragging == 'low' and low_knob or high_knob)
        update_from(input)
    end))

    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and is_move(input) then
            update_from(input)
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        if dragging and is_press(input) then
            dragging = nil
            release_drag(api)
            shrink(low_knob)
            shrink(high_knob)
        end
    end))

    if flag and not ignore_saved then
        register_flag(flag, { Min = low, Max = high }, function(value)
            api:Set(value, nil, false)
        end)
        local saved = Library.Flags[flag]
        if typeof(saved) == 'table' then
            local a = tonumber(saved.Min or saved.min or saved[1])
            local b = tonumber(saved.Max or saved.max or saved[2])
            if a and b then
                low = math.clamp(round(a), minimum, maximum)
                high = math.clamp(round(b), minimum, maximum)
                if low > high then
                    low, high = high, low
                end
            end
        end
    elseif flag then
        Library.Flags[flag] = { Min = low, Max = high }
    end

    paint()
    task.spawn(function()
        pcall(callback, low, high)
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

    local desc_text = desc_of(options)
    local holder = create('Frame', {
        Name = 'inputbox',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, (is_touch() and 64 or 58) + (desc_text and 12 or 0)),
        LayoutOrder = self:_next(),
    })

    local inner = create('Frame', {
        Name = 'inner',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(holder, inner, 8, 8)

    local title_label = label(inner, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, 0, 0, 15)
    themed(title_label, { TextColor3 = 'Text' })

    if desc_text then
        local desc = label(inner, tostring(desc_text), 11, nil, Theme.SubText)
        desc.Name = 'desc'
        desc.Position = UDim2.new(0, 0, 0, 16)
        desc.Size = UDim2.new(1, 0, 0, 13)
        desc.TextTruncate = Enum.TextTruncate.AtEnd
        themed(desc, { TextColor3 = 'SubText' })
    end

    -- The field sits a shade darker than the card it lives on, which is how
    -- an input separates itself from the element around it.
    local field = create('Frame', {
        Parent = inner,
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.35,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 30 or 25),
    })
    themed(field, { BackgroundColor3 = 'Backdrop' })
    corner(field, 5)
    local field_stroke = stroke(field, Theme.Stroke, 0.35)
    themed(field_stroke, { Color = 'Stroke' })
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

    local desc_text = desc_of(options)
    local holder = create('Frame', {
        Name = 'dropdown',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
        ClipsDescendants = false,
    })
    themed(holder, { BackgroundColor3 = 'Element' })
    corner(holder, CARD_CORNER)
    local drop_border = stroke(holder, Theme.Stroke, 0.45)
    themed(drop_border, { Color = 'Stroke' })
    padding(holder, 8, 9, 10, 10)
    list(holder, 5)

    local title_label = label(holder, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, 0, 0, 15)
    title_label.LayoutOrder = 0
    themed(title_label, { TextColor3 = 'Text' })

    if desc_text then
        local desc = label(holder, tostring(desc_text), 11, nil, Theme.SubText)
        desc.Name = 'desc'
        desc.Size = UDim2.new(1, 0, 0, 13)
        desc.LayoutOrder = 0
        desc.TextTruncate = Enum.TextTruncate.AtEnd
        themed(desc, { TextColor3 = 'SubText' })
    end

    local head = create('TextButton', {
        Name = 'dropframe',
        Parent = holder,
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.35,
        Size = UDim2.new(1, 0, 0, head_height),
        Text = '',
        AutoButtonColor = false,
        LayoutOrder = 1,
    })
    themed(head, { BackgroundColor3 = 'Backdrop' })
    corner(head, 5)
    local head_stroke = stroke(head, Theme.Stroke, 0.35)
    themed(head_stroke, { Color = 'Stroke' })

    local selected_label = label(head, '...', 12, nil, Theme.Text)
    selected_label.Name = 'selected'
    selected_label.Position = UDim2.new(0, 8, 0, 0)
    selected_label.Size = UDim2.new(1, -28, 1, 0)
    selected_label.TextTruncate = Enum.TextTruncate.AtEnd
    themed(selected_label, { TextColor3 = 'Text' })

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
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.25,
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
    themed(container, { BackgroundColor3 = 'Backdrop', ScrollBarImageColor3 = 'Stroke' })
    corner(container, 5)
    local list_border = stroke(container, Theme.Stroke, 0.35)
    themed(list_border, { Color = 'Stroke' })
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
    local inner = create('Frame', {
        Name = 'inner',
        Parent = row,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(row, inner)

    local title_label = label(inner, title, 13, nil, Theme.Text)
    title_label.Size = UDim2.new(1, -90, 1, 0)
    themed(title_label, { TextColor3 = 'Text' })

    attach_desc(row, title_label, desc_of(options))

    local button = create('TextButton', {
        Name = 'Bind',
        Parent = inner,
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.35,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(0, 84, 0, is_touch() and 26 or 22),
        Text = '',
        AutoButtonColor = false,
    })
    themed(button, { BackgroundColor3 = 'Backdrop' })
    corner(button, 4)
    local button_stroke = stroke(button, Theme.Stroke, 0.35)
    themed(button_stroke, { Color = 'Stroke' })

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
    local head_inner = create('Frame', {
        Name = 'inner',
        Parent = head,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(head, head_inner)
    card_hover(head)

    local title_label = label(head_inner, title, 13, nil, Theme.Text)
    title_label.Size = UDim2.new(1, -50, 1, 0)
    themed(title_label, { TextColor3 = 'Text' })

    attach_desc(head, title_label, desc_of(options))

    local swatch = create('Frame', {
        Name = 'swatch',
        Parent = head_inner,
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
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, 0),
        Visible = false,
        LayoutOrder = 1,
        ClipsDescendants = true,
    })
    themed(container, { BackgroundColor3 = 'Element' })
    corner(container, CARD_CORNER)
    local picker_border = stroke(container, Theme.Stroke, 0.45)
    themed(picker_border, { Color = 'Stroke' })

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
Section.create_rangeslider = Section.RangeSlider
Section.create_range_slider = Section.RangeSlider
Section.Range = Section.RangeSlider
Section.create_dropdown = Section.Dropdown
Section.create_textbox = Section.Textbox
Section.create_button = Section.Button
Section.create_keybind = Section.Keybind
Section.create_colorpicker = Section.Colorpicker
Section.create_label = Section.Label
Section.create_paragraph = Section.Paragraph
Section.create_divider = Section.Divider

--// Element: progress meter -------------------------------------------------

-- A read-only bar for things the script measures rather than things the user
-- sets: blocks farmed this minute, ammo left, how far a solver has walked its
-- search. It carries no flag because there is nothing to save.
function Section:Progress(options)
    options = options or {}
    local title = pick(options, 'Progress', 'Title', 'title', 'Text')
    local minimum = tonumber(pick(options, 0, 'Min', 'min', 'Minimum')) or 0
    local maximum = tonumber(pick(options, 100, 'Max', 'max', 'Maximum')) or 100
    local default = tonumber(pick(options, minimum, 'Default', 'default', 'Value', 'value')) or minimum
    local suffix = tostring(pick(options, '', 'Suffix', 'suffix', 'Unit'))
    local as_percent = pick(options, false, 'Percent', 'percent', 'ShowPercent')
    local show_max = pick(options, false, 'ShowMax', 'show_max', 'OutOf')
    local bar_color = pick(options, nil, 'Color', 'color', 'BarColor')
    local formatter = pick(options, nil, 'Format', 'format', 'Formatter')

    local holder = create('Frame', {
        Name = 'progress',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, is_touch() and 54 or 48),
        LayoutOrder = self:_next(),
    })
    local inner = create('Frame', {
        Name = 'inner',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(holder, inner, 8, 8)

    local title_label = label(inner, title, 13, nil, Theme.Text)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(1, -120, 0, 16)
    themed(title_label, { TextColor3 = 'Text' })

    local value_label = label(inner, '', 12, 'semi', Theme.Text)
    value_label.Name = 'value'
    value_label.AnchorPoint = Vector2.new(1, 0)
    value_label.Position = UDim2.new(1, 0, 0, 0)
    value_label.Size = UDim2.new(0, 120, 0, 16)
    value_label.TextXAlignment = Enum.TextXAlignment.Right

    local bar = create('Frame', {
        Name = 'bar',
        Parent = inner,
        BackgroundColor3 = Theme.Backdrop,
        BackgroundTransparency = 0.35,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, is_touch() and 10 or 8),
    })
    themed(bar, { BackgroundColor3 = 'Backdrop' })
    corner(bar, 4)
    local bar_border = stroke(bar, Theme.Stroke, 0.35)
    themed(bar_border, { Color = 'Stroke' })

    local fill = create('Frame', {
        Name = 'fill',
        Parent = bar,
        BackgroundColor3 = bar_color or Library.Accent,
        Size = UDim2.new(0, 0, 1, 0),
        BorderSizePixel = 0,
    })
    corner(fill, 4)
    -- Only follow the theme accent when the caller didn't name a colour: a bar
    -- deliberately painted red shouldn't turn blue because the menu did.
    if not bar_color then
        accent(fill, { 'BackgroundColor3' })
    end

    local value = math.clamp(default, math.min(minimum, maximum), math.max(minimum, maximum))
    local override_text = nil

    local function alpha_of(number)
        if maximum == minimum then
            return 0
        end
        return math.clamp((number - minimum) / (maximum - minimum), 0, 1)
    end

    local function readout()
        if override_text then
            return override_text
        end
        if formatter then
            local ok, text = pcall(formatter, value, minimum, maximum)
            if ok and text ~= nil then
                return tostring(text)
            end
        end
        if as_percent then
            return tostring(math.round(alpha_of(value) * 100)) .. '%'
        end
        local shown = math.abs(value - math.round(value)) < 1e-6 and math.round(value) or value
        if show_max then
            local cap = math.abs(maximum - math.round(maximum)) < 1e-6 and math.round(maximum) or maximum
            return tostring(shown) .. ' / ' .. tostring(cap) .. suffix
        end
        return tostring(shown) .. suffix
    end

    local function paint(animate)
        local target = UDim2.new(alpha_of(value), 0, 1, 0)
        if animate == false then
            fill.Size = target
        else
            tween(fill, QUAD, { Size = target })
        end
        value_label.Text = readout()
    end

    local api = {}

    function api:Set(new_value, animate)
        value = math.clamp(tonumber(new_value) or minimum, math.min(minimum, maximum), math.max(minimum, maximum))
        paint(animate)
    end

    function api:SetMax(new_max)
        maximum = tonumber(new_max) or maximum
        api:Set(value)
    end

    function api:SetMin(new_min)
        minimum = tonumber(new_min) or minimum
        api:Set(value)
    end

    -- Pins the readout to arbitrary text ('idle', 'searching...') without
    -- touching the bar. Pass nil to hand it back to the number.
    function api:SetText(text)
        override_text = text ~= nil and tostring(text) or nil
        value_label.Text = readout()
    end

    function api:SetTitle(text)
        title_label.Text = tostring(text)
    end

    function api:SetColor(color)
        if typeof(color) ~= 'Color3' then
            return
        end
        bar_color = color
        Library._accent_objects[fill] = nil
        tween(fill, QUAD, { BackgroundColor3 = color })
    end

    function api:Get()
        return value
    end

    api.SetValue, api.set_value, api.set = api.Set, api.Set, api.Set
    api.set_text, api.set_title, api.set_color = api.SetText, api.SetTitle, api.SetColor

    paint(false)
    return api
end

--// Element: button row ------------------------------------------------------

-- Two or three related actions that would each waste a full row on their own:
-- `Section:Buttons({ { Title = 'start', Callback = a }, { Title = 'stop',
-- Callback = b } })`. Returns the list of button handles in the order given.
function Section:Buttons(options)
    options = options or {}
    local entries = pick(options, nil, 'Buttons', 'buttons', 'Items', 'items', 'Options')
    if entries == nil then
        -- A bare array in the options table is the shape people reach for
        -- first, so accept that too.
        entries = {}
        for index = 1, #options do
            entries[index] = options[index]
        end
    end
    if #entries == 0 then
        return {}
    end

    local gap = 6
    local count = #entries
    local row = create('Frame', {
        Name = 'buttonrow',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, row_height()),
        LayoutOrder = self:_next(),
    })
    list(row, gap, Enum.FillDirection.Horizontal)

    local width = 1 / count
    local trim = gap * (count - 1) / count
    local apis = {}

    for index = 1, count do
        local entry = entries[index]
        if typeof(entry) == 'string' then
            entry = { Title = entry }
        end
        entry = entry or {}
        local title = pick(entry, 'Button', 'Title', 'title', 'Text')
        local callback = pick(entry, function() end, 'Callback', 'callback', 'Func')

        -- Each button in the row is its own card, matching a standalone
        -- Button - so a row of three reads as three controls, not one strip
        -- chopped into thirds.
        local button = create('TextButton', {
            Name = 'button',
            Parent = row,
            BackgroundColor3 = Theme.Element,
            BackgroundTransparency = ELEMENT_TRANSPARENCY,
            Size = UDim2.new(width, -trim, 1, 0),
            Text = '',
            AutoButtonColor = false,
            LayoutOrder = index,
        })
        themed(button, { BackgroundColor3 = 'Element' })
        corner(button, CARD_CORNER)
        local row_border = stroke(button, Theme.Stroke, 0.45)
        themed(row_border, { Color = 'Stroke' })
        card_hover(button)

        local title_label = label(button, title, 12, 'semi', Theme.Text)
        title_label.Size = UDim2.new(1, -8, 1, 0)
        title_label.Position = UDim2.new(0, 4, 0, 0)
        title_label.TextXAlignment = Enum.TextXAlignment.Center
        title_label.TextTruncate = Enum.TextTruncate.AtEnd

        track(button.MouseButton1Click:Connect(function()
            tween(button, TweenInfo.new(0.08), {
                BackgroundColor3 = Library.Accent,
                BackgroundTransparency = 0.2,
            })
            tween(title_label, TweenInfo.new(0.08), { TextColor3 = Theme.Backdrop })
            task.delay(0.12, function()
                tween(button, QUAD, {
                    BackgroundColor3 = Theme.Element,
                    BackgroundTransparency = ELEMENT_TRANSPARENCY,
                })
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
        function api:SetVisible(state)
            button.Visible = state and true or false
        end
        api.set_title, api.set_visible = api.SetTitle, api.SetVisible
        apis[index] = api
    end

    return apis
end

--// Element: stat readout ---------------------------------------------------

-- Name on the left, live value on the right, no chrome. What a Label with a
-- manually concatenated string was always trying to be.
function Section:Stat(options)
    options = options or {}
    if typeof(options) == 'string' then
        options = { Title = options }
    end
    local title = pick(options, 'Stat', 'Title', 'title', 'Name')
    local value = pick(options, '-', 'Value', 'value', 'Default', 'Text')
    local value_color = pick(options, Theme.Text, 'Color', 'color', 'ValueColor')

    -- Stats are read in groups, so they stay shorter than a control card -
    -- tall enough to be a card, short enough that six of them stacked still
    -- scan as a list rather than six separate panels.
    local row = create('Frame', {
        Name = 'stat',
        Parent = self.Container,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, is_touch() and 30 or 26),
        LayoutOrder = self:_next(),
    })
    local inner = create('Frame', {
        Name = 'inner',
        Parent = row,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
    })
    cardify(row, inner)

    local title_label = label(inner, title, 12, nil, Theme.SubText)
    title_label.Name = 'title'
    title_label.Size = UDim2.new(0.5, -4, 1, 0)
    themed(title_label, { TextColor3 = 'SubText' })

    local value_label = label(inner, tostring(value), 12, 'semi', value_color)
    value_label.Name = 'value'
    value_label.AnchorPoint = Vector2.new(1, 0)
    value_label.Position = UDim2.new(1, 0, 0, 0)
    value_label.Size = UDim2.new(0.5, -4, 1, 0)
    value_label.TextXAlignment = Enum.TextXAlignment.Right
    value_label.TextTruncate = Enum.TextTruncate.AtEnd

    local api = {}
    function api:Set(new_value, color)
        value_label.Text = tostring(new_value)
        if typeof(color) == 'Color3' then
            value_label.TextColor3 = color
        end
    end
    function api:SetTitle(text)
        title_label.Text = tostring(text)
    end
    function api:SetColor(color)
        if typeof(color) == 'Color3' then
            value_label.TextColor3 = color
        end
    end
    function api:Get()
        return value_label.Text
    end
    api.SetValue, api.set_value, api.set = api.Set, api.Set, api.Set
    api.set_title, api.set_color = api.SetTitle, api.SetColor
    return api
end

--// Element: console log -----------------------------------------------------

-- A scrolling line buffer. Scripts that were faking one by rewriting a
-- Paragraph with table.concat get real per-line colouring, a hard cap on how
-- many lines exist as instances, and scrolling that doesn't reflow the page.
function Section:Console(options)
    options = options or {}
    local title = pick(options, nil, 'Title', 'title')
    local height = tonumber(pick(options, 120, 'Height', 'height', 'Lines')) or 120
    local max_lines = math.max(1, tonumber(pick(options, 150, 'MaxLines', 'max_lines', 'Limit')) or 150)
    local monospace = pick(options, true, 'Monospace', 'monospace', 'Code')
    local auto_scroll = pick(options, true, 'AutoScroll', 'auto_scroll', 'Follow')
    local timestamps = pick(options, false, 'Timestamps', 'timestamps', 'Time')
    local text_size = tonumber(pick(options, 11, 'TextSize', 'text_size')) or 11

    -- 12px of padding, plus the 14px title and the 4px list gap when there is
    -- a title, so `Height` means the height of the log itself rather than of
    -- the box that happens to contain it.
    local holder = create('Frame', {
        Name = 'console',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, height + 12 + (title and 18 or 0)),
        LayoutOrder = self:_next(),
    })
    themed(holder, { BackgroundColor3 = 'Element' })
    corner(holder, CARD_CORNER)
    local console_border = stroke(holder, Theme.Stroke, 0.45)
    themed(console_border, { Color = 'Stroke' })
    padding(holder, 8, 8, 10, 8)
    list(holder, 4)

    if title then
        local title_label = label(holder, title, 11, 'bold', Theme.SubText)
        title_label.Size = UDim2.new(1, 0, 0, 14)
        title_label.LayoutOrder = 0
    end

    local view = create('ScrollingFrame', {
        Name = 'view',
        Parent = holder,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Theme.Stroke,
        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
        ClipsDescendants = true,
        LayoutOrder = 1,
    })
    list(view, 2)
    sink_scroll(view)

    local lines = {}
    local counter = 0

    local function scroll_to_end()
        if not auto_scroll then
            return
        end
        -- AutomaticCanvasSize only reports the new height after a layout pass,
        -- so the jump has to wait a frame or it lands on the previous bottom.
        task.defer(function()
            if view.Parent then
                view.CanvasPosition = Vector2.new(0, math.max(0, view.AbsoluteCanvasSize.Y - view.AbsoluteWindowSize.Y))
            end
        end)
    end

    local api = {}

    function api:Add(text, color)
        if text == nil then
            return
        end
        local body = tostring(text)
        if timestamps then
            body = os.date('[%H:%M:%S] ') .. body
        end

        counter = counter + 1
        local props = text_props(text_size, nil, color or Theme.SubText)
        if monospace then
            props.FontFace = nil
            props.Font = Enum.Font.Code
        end
        props.Name = 'line'
        props.Parent = view
        props.Text = body
        props.Size = UDim2.new(1, -4, 0, 0)
        props.AutomaticSize = Enum.AutomaticSize.Y
        props.TextWrapped = true
        props.LayoutOrder = counter
        local line = create('TextLabel', props)

        table.insert(lines, line)
        -- Trimming by destroying the oldest keeps the instance count flat on a
        -- log that runs for an hour, which a plain text buffer would not.
        while #lines > max_lines do
            local oldest = table.remove(lines, 1)
            if oldest then
                oldest:Destroy()
            end
        end

        scroll_to_end()
        return line
    end

    function api:Clear()
        for _, line in pairs(lines) do
            line:Destroy()
        end
        table.clear(lines)
        counter = 0
        view.CanvasPosition = Vector2.new(0, 0)
    end

    function api:Set(list_of_lines)
        api:Clear()
        if typeof(list_of_lines) == 'table' then
            for _, entry in ipairs(list_of_lines) do
                api:Add(entry)
            end
        elseif list_of_lines ~= nil then
            api:Add(list_of_lines)
        end
    end

    function api:Get()
        local out = {}
        for index, line in ipairs(lines) do
            out[index] = line.Text
        end
        return out
    end

    function api:Count()
        return #lines
    end

    function api:SetAutoScroll(state)
        auto_scroll = state and true or false
    end

    -- Convenience colours so callers don't have to reach into Theme.
    function api:Success(text)
        return api:Add(text, Theme.Success)
    end

    function api:Warn(text)
        return api:Add(text, Theme.Warning)
    end

    function api:Error(text)
        return api:Add(text, Theme.Error)
    end

    function api:Info(text)
        return api:Add(text, Theme.Info)
    end

    api.AddLine, api.Push, api.Print, api.add = api.Add, api.Add, api.Add, api.Add
    api.clear, api.set, api.get = api.Clear, api.Set, api.Get
    return api
end

Section.Log = Section.Console
Section.Logbox = Section.Console

--// Element: image -----------------------------------------------------------

function Section:Image(options)
    options = options or {}
    if typeof(options) == 'string' then
        options = { Image = options }
    end
    local image = pick(options, '', 'Image', 'image', 'Icon', 'Asset', 'Id')
    local height = tonumber(pick(options, 120, 'Height', 'height')) or 120
    local rounded = tonumber(pick(options, 5, 'Corner', 'corner', 'Radius')) or 5
    local transparency = tonumber(pick(options, 0, 'Transparency', 'transparency')) or 0
    local scale_type = pick(options, Enum.ScaleType.Fit, 'ScaleType', 'scale_type')

    local holder = create('Frame', {
        Name = 'image',
        Parent = self.Container,
        BackgroundColor3 = Theme.Element,
        BackgroundTransparency = ELEMENT_TRANSPARENCY,
        Size = UDim2.new(1, 0, 0, height),
        ClipsDescendants = true,
        LayoutOrder = self:_next(),
    })
    themed(holder, { BackgroundColor3 = 'Element' })
    corner(holder, rounded)
    local image_border = stroke(holder, Theme.Stroke, 0.45)
    themed(image_border, { Color = 'Stroke' })
    stroke(holder, Theme.Stroke)

    local picture = create('ImageLabel', {
        Name = 'picture',
        Parent = holder,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        ImageTransparency = transparency,
        ScaleType = scale_type,
    })
    -- Routed through ApplyIcon so a Lucide name works here as well as an
    -- asset id, and neither ever yields the caller.
    Library:ApplyIcon(picture, image, ui_icon_options(math.min(height, 128)))

    local api = {}
    function api:Set(new_image)
        Library:ApplyIcon(picture, new_image, ui_icon_options(math.min(height, 128)))
    end
    function api:SetHeight(new_height)
        height = tonumber(new_height) or height
        holder.Size = UDim2.new(1, 0, 0, height)
    end
    function api:SetTransparency(value)
        picture.ImageTransparency = tonumber(value) or 0
    end
    function api:SetColor(color)
        if typeof(color) == 'Color3' then
            picture.ImageColor3 = color
        end
    end
    api.set, api.set_height = api.Set, api.SetHeight
    return api
end

--// Section housekeeping -----------------------------------------------------

function Section:SetVisible(state)
    self.Card.Visible = state and true or false
end

function Section:Destroy()
    local tab = self.Tab
    if tab and tab.Sections then
        for index, other in ipairs(tab.Sections) do
            if other == self then
                table.remove(tab.Sections, index)
                break
            end
        end
    end
    self.Card:Destroy()
end

-- Wipes every element out of a section without losing the section itself, for
-- panels that rebuild their contents from live game state.
function Section:Clear()
    for _, child in pairs(self.Container:GetChildren()) do
        if not child:IsA('UIListLayout') then
            child:Destroy()
        end
    end
    self.Order = 0
end

Section.set_visible = Section.SetVisible
Section.destroy = Section.Destroy
Section.clear = Section.Clear

--// Built-in settings tab ---------------------------------------------------

function Window:_build_settings_tab()
    if self.SettingsTab then
        return self.SettingsTab
    end

    local tab = self:Tab({ Title = 'settings', Icon = 'settings' })
    self.SettingsTab = tab

    local interface = tab:Section({ Title = 'interface', Side = 'left' })

    interface:Dropdown({
        Title = 'theme',
        Desc = 'repaints everything live',
        Flag = 'centrl_theme',
        Values = Library.ThemeNames,
        Default = Library.ThemeName,
        Callback = function(name)
            Library:SetTheme(name)
        end,
    })

    interface:Colorpicker({
        Title = 'accent',
        Desc = 'overrides the theme\'s own accent',
        Flag = 'centrl_accent',
        Default = Library.Accent,
        Callback = function(color)
            -- Picking a colour by hand is a statement of intent, so from here
            -- on theme swaps leave the accent alone.
            Library._accent_pinned = true
            Library:SetAccent(color)
        end,
    })

    interface:Button({
        Title = 'use theme accent',
        Desc = 'undo a hand-picked accent',
        Callback = function()
            Library._accent_pinned = false
            local preset = Library.Themes[Library.ThemeName]
            if preset and preset.Accent then
                Library:SetAccent(preset.Accent)
            end
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
Window.get_tab = Window.GetTab
Window.select_tab = Window.SelectTab
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
-- parallel one) plus a hand-built 3-line menu icon in the topbar. Both
-- patches use the library's own real internals (create, corner, stroke,
-- accent, hover, Theme, Window, Tab, TOPBAR_HEIGHT, ...) rather than
-- reimplementing them, since this code lives inside the same closure as the
-- rest of the library.
--
-- This has to stay at the very bottom: it wraps Window.Tab and
-- Library.Window, so everything it wraps must already be defined. Sub-tabs
-- (Tab:Tab) are unaffected -- their strip is horizontal to begin with.

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

    -- The badge normally sits in the gutter the left-aligned title label
    -- leaves on its right. A centred title has no such gutter, so up here it
    -- becomes a corner marker instead of a trailing pill.
    if tab.Badge then
        tab.Badge.AnchorPoint = Vector2.new(1, 0)
        tab.Badge.Position = UDim2.new(1, -3, 0, 3)
        tab.Badge.Size = UDim2.new(0, 0, 0, 13)
    end
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

-- Native topbar (unibar) show/hide button, next to the chat icon -----------
-- Ported from https://raw.githubusercontent.com/iamdookie1/inf/refs/heads/main/source.txt
-- (search that file for "Interface visibility" / "UnibarLeftFrame"), which
-- reverse-engineers CoreGui.TopBarApp.TopBarApp.UnibarLeftFrame.UnibarMenu:
-- chat and nine_dot are 44x44 Frames sitting edge to edge under a numbered
-- frame ("3") with a hardcoded pixel width, inside a pill background that's
-- sized as a proportion of its parent and therefore tracks automatically.
-- Adding our own icon means widening every literal-pixel-width ancestor up
-- to (and including) UnibarLeftFrame by the icon's width, and re-measuring
-- on a timer since Roblox can add/remove/resize its own icons at any time.
--
-- Unlike inf (mobile-only button, desktop gets a keybind instead), this
-- always shows the icon - it's the library's one and only show/hide entry
-- point now, replacing the floating MobileButton entirely (forced off
-- below) rather than sitting alongside it.
-- Marks our icon so every copy of this closure can recognise every other
-- copy's, not just its own. Two windows in one session (the hub unloading and
-- handing off to a game script) each run this whole function, and without a
-- shared marker each one measures the other's icon as native topbar content
-- and widens the bar to clear it - which the other then measures in turn. That
-- feedback loop is what made the topbar crawl wider every two seconds.
local UNIBAR_TAG = 'centrl_unibar_icon'

local function is_our_icon(instance)
    return instance:GetAttribute(UNIBAR_TAG) == true
end

local function add_unibar_icon(win)
    local ok = pcall(function()
        local ICON_MARGIN = 4

        local icon, icon_row
        local dead = false
        -- Original size per ancestor we widen, so unloading can put the
        -- topbar back the way we found it instead of leaving it stretched.
        local widened = {}

        local function find_icon_row()
            local app = CoreGui:FindFirstChild('TopBarApp')
            local inner = app and app:FindFirstChild('TopBarApp')
            local left_frame = inner and inner:FindFirstChild('UnibarLeftFrame')
            local menu = left_frame and left_frame:FindFirstChild('UnibarMenu')
            if not menu then return nil end
            local sibling = menu:FindFirstChild('chat', true) or menu:FindFirstChild('nine_dot', true)
            if not sibling or not sibling:IsA('GuiObject') or not sibling.Parent then return nil end
            return sibling.Parent, sibling, left_frame
        end

        local function native_content_width(row)
            local edge = 0
            local row_left = row.AbsolutePosition.X
            for _, child in row:GetChildren() do
                if not is_our_icon(child) and child:IsA('GuiObject') and child.Visible and child.AbsoluteSize.X > 0 then
                    local right = (child.AbsolutePosition.X - row_left) + child.AbsoluteSize.X
                    if right > edge then edge = right end
                end
            end
            return edge
        end

        local function widen(frame, target_width)
            if frame.Size.X.Scale ~= 0 then return end
            if frame.AutomaticSize == Enum.AutomaticSize.X or frame.AutomaticSize == Enum.AutomaticSize.XY then
                return
            end
            local size = frame.Size
            if size.X.Offset == target_width then return end
            -- Recorded before the first change only, so a later pass never
            -- captures our own widened value as the original.
            if widened[frame] == nil then
                widened[frame] = size
            end
            frame.Size = UDim2.new(size.X.Scale, target_width, size.Y.Scale, size.Y.Offset)
        end

        local function restore_widths()
            for frame, size in pairs(widened) do
                pcall(function()
                    if frame.Parent then
                        frame.Size = size
                    end
                end)
            end
            table.clear(widened)
        end

        local function fit_icon(row, sibling, left_frame)
            if dead or not icon then return end
            local native_width = native_content_width(row)
            icon.Size = sibling.Size
            icon.Position = UDim2.new(0, math.floor(native_width + 0.5), sibling.Position.Y.Scale, sibling.Position.Y.Offset)
            icon.TextSize = math.clamp(math.floor(sibling.AbsoluteSize.Y * 0.55 + 0.5), 11, 22)

            local target_width = math.floor(native_width + icon.Size.X.Offset + ICON_MARGIN + 0.5)
            local node = row
            while node and node:IsA('GuiObject') do
                widen(node, target_width)
                if node == left_frame then break end
                node = node.Parent
            end
        end

        local function paint_icon()
            if not icon then return end
            tween(icon, QUAD, { TextTransparency = win.Visible and 0 or 0.45 })
        end

        local function build_icon(row, sibling)
            icon = Instance.new('TextButton')
            icon.Name = 'menu'
            icon.AutoButtonColor = false
            icon.BackgroundTransparency = 1
            icon.BorderSizePixel = 0
            icon.Font = Enum.Font.GothamBold
            icon.Text = '\226\137\161' -- "≡"
            icon.TextColor3 = Color3.new(1, 1, 1)
            icon.ZIndex = sibling.ZIndex
            pcall(function() icon.AnchorPoint = sibling.AnchorPoint end)
            pcall(function() icon.AutoLocalize = false end)
            -- Set before parenting, so no sweep or measurement can ever see
            -- this icon in the row untagged.
            icon:SetAttribute(UNIBAR_TAG, true)
            icon.Parent = row

            track(icon.MouseButton1Click:Connect(function()
                win:SetVisible(not win.Visible)
                paint_icon()
            end))
            local function press(down)
                tween(icon, TweenInfo.new(0.08), { TextTransparency = down and 0.6 or (win.Visible and 0 or 0.45) })
            end
            track(icon.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    press(true)
                end
            end))
            track(icon.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    press(false)
                end
            end))
            icon.TextTransparency = win.Visible and 0 or 0.45
        end

        -- Anything of ours already sitting in the row belongs to a previous
        -- window that went away without unloading cleanly. There can only be
        -- one, so clear the rest before adding this one.
        local function sweep_stale(row)
            for _, child in pairs(row:GetChildren()) do
                if child ~= icon and is_our_icon(child) then
                    pcall(function()
                        child:Destroy()
                    end)
                end
            end
        end

        local function refresh_icon()
            if dead then return end
            local row, sibling, left_frame = find_icon_row()
            if not row then return end
            if icon and not icon:IsDescendantOf(game) then
                icon:Destroy()
                icon = nil
            end
            if not icon then
                build_icon(row, sibling)
            elseif icon.Parent ~= row then
                icon.Parent = row
            end
            sweep_stale(row)
            icon_row = row
            fit_icon(row, sibling, left_frame)
        end

        on_unload(function()
            -- Order matters: stop the loop, drop the icon, then hand the
            -- topbar its original widths back. Restoring first would just be
            -- undone by a refresh already in flight.
            dead = true
            if icon then
                pcall(function()
                    icon:Destroy()
                end)
                icon = nil
            end
            restore_widths()
        end)

        refresh_icon()
        task.spawn(function()
            -- `dead` rather than the icon's ancestry: an unloaded library
            -- leaves nothing to test, and the old check kept this running
            -- forever against a topbar it no longer owned.
            while not dead and not Library._unloaded do
                task.wait(2)
                if dead or Library._unloaded then
                    return
                end
                pcall(refresh_icon)
            end
        end)
    end)
    return ok
end

local _original_window = Library.Window
function Library:Window(options)
    options = options or {}
    options.MobileButton = false -- replaced by the unibar icon below, not layered alongside it
    local win = _original_window(self, options)
    reflow_rail_to_top(win)
    add_menu_icon(win)
    add_unibar_icon(win)
    return win
end
Library.window = Library.Window

return Library

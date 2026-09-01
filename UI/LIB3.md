# Centrl UI (`Lib3.lua`)

Lib2's engine wearing [Fluent](https://github.com/StyearX/Fluent-modded)'s clothes.
This is the one every script in this repo loads now. [`Lib2.lua`](LIB2.md) is
unchanged and still works — nothing was removed from it, and both can be loaded
side by side.

The API is identical to Lib2 on purpose: every element, every option alias,
every returned method. Moving a script over is a one-line URL change.

```lua
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib3.lua'))()

local Window = Centrl:Window({
    Title      = 'centrl',
    SubTitle   = 'v3',
    Folder     = 'centrl',
    Theme      = 'Deep Violet',                  -- new: see the theme list below
    ToggleKey  = Enum.KeyCode.RightShift,
    Accent     = Color3.fromRGB(227, 255, 42),   -- optional; overrides the theme's accent
})

local Tab = Window:Tab({ Title = 'legit', Icon = 'crosshair' })
local Sec = Tab:Section({ Title = 'aimbot', Side = 'left' })

Sec:Toggle({
    Title = 'enabled',
    Desc  = 'lock to the closest head',          -- new: description line
    Flag  = 'aim',
    Callback = function(state) end,
})

Window:Load()
```

## What changed from Lib2

Kept from Lib2, because Fluent has no answer for them:

- Two scrolling columns of section cards rather than one long list
- Icon tab rail with sub-tabs and badges
- `Console`, `Stat`, `Progress`, `Image`, `RangeSlider` and `Buttons` elements
- Per-game config saving, named config files, the built-in settings tab
- Mobile: touch drag, touch sliders, viewport scaling, unibar toggle button

Taken from Fluent, because Lib2 looked worse than it:

- Acrylic window — gradient body, noise overlay, hairline border, transparent
  title bar so the gradient runs the full height
- Every control is its own rounded bordered card instead of a bare row
- An optional description line under any element's title
- Pill toggle with a sliding knob on a quint ease
- Slider as a thin rail with a round grab handle
- Ten themes, swappable at runtime

The acrylic is the gradient-and-grain half of Fluent's, not the real one.
Fluent blurs what is behind the window with a `DepthOfField` pass on the camera;
that fights every other script touching `Lighting` and looks wrong the moment
one of them wins, so this does the half that reads as acrylic and skips the half
that breaks.

## Themes

`Dark` · `Charcoal` · `Deep Violet` · `Blood Red` · `Neon Purple` · `Deep Ocean`
· `Midnight Blue` · `Rose` · `AMOLED` · `Pearl White`

| Call | Description |
|---|---|
| `Centrl:SetTheme(name)` | Repaints every built element live |
| `Centrl.ThemeNames` | The list above, for a dropdown |
| `Centrl.ThemeName` | The active theme's name |
| `Centrl.Themes[name]` | The raw colour table |

Each theme carries its own accent. Passing `Accent` to `:Window{}` or picking one
in the settings tab pins it, and theme swaps then leave it alone; the settings
tab's *use theme accent* button unpins it.

Themes repaint rather than rebuild: `themed(object, { BackgroundColor3 = 'Element' })`
registers an instance against the colour roles it reads, which is Fluent's
`ThemeTag` idea spelled as a function.

## Everything else

Identical to Lib2 — see [`LIB2.md`](LIB2.md) for the full element and method
tables. The only additions are `Theme` on `:Window{}`, `Desc` on every element,
and the `SetTheme` calls above.

`Desc` is also accepted as `Description`, `desc`, `description`, `SubText` or
`Sub`, matching how the rest of the library takes option aliases.

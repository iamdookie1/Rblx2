# Centrl UI (`Lib4.lua`)

Centrl's engine wearing [Obsidian](https://github.com/deividcomsono/Obsidian)'s
clothes. This is the one every script in this repo loads now. `Lib3.lua` is
gone — deleted, not deprecated — and nothing here points at it anymore.
[`Lib2.lua`](LIB2.md) is still untouched underneath and still works on its
own if something ever needs it directly.

The API is identical to Lib2 on purpose: every element, every option alias,
every returned method. Moving a script over is a one-line URL change.

```lua
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib4.lua'))()

local Window = Centrl:Window({
    Title      = 'centrl',
    SubTitle   = 'v4',
    Folder     = 'centrl',
    Theme      = 'Deep Violet',                  -- see the theme list below
    ToggleKey  = Enum.KeyCode.RightShift,
    Accent     = Color3.fromRGB(227, 255, 42),   -- optional; overrides the theme's accent
})

local Tab = Window:Tab({ Title = 'legit', Icon = 'crosshair' })
local Sec = Tab:Section({ Title = 'aimbot', Side = 'left' })

Sec:Toggle({
    Title = 'enabled',
    Desc  = 'lock to the closest head',
    Flag  = 'aim',
    Callback = function(state) end,
})

Window:Load()
```

## What changed from Lib3

Kept from Centrl, because Obsidian has no answer for them:

- Two scrolling columns of section cards rather than one long list
- Icon tab rail with sub-tabs and badges
- `Console`, `Stat`, `Progress`, `Image`, `RangeSlider` and `Buttons` elements
- Per-game config saving, named config files, the built-in settings tab
- Mobile: touch drag, touch sliders, viewport scaling, unibar toggle button

Taken from Obsidian, because it reads better than Fluent's glass did:

- Flat, opaque cards — no acrylic gradient body, no film-grain overlay,
  nothing translucent for a dozen other menus to fight for attention with
- A real, visible outline around the whole window, the way Obsidian's own
  `AddOutline` draws it, instead of a hairline stroke set to invisible
- Sharp corners — 4px on every card, matching Obsidian's own default,
  in place of Fluent's rounded pill look
- Squared-off toggle and slider chrome instead of a full stadium pill and a
  circular grab handle
- Ten themes, still swappable at runtime — the palette is Centrl's own, the
  chrome they sit in is Obsidian's

## "Bigger without being bigger" (scale)

The window's on-screen footprint is unchanged from Lib3's default. What
changed is the ratio between that footprint and everything drawn inside it:
the window's logical grid (`WINDOW_WIDTH`/`WINDOW_HEIGHT`) shrinks by
`BASE_SCALE` and the baseline UI scale grows by the same factor, so the two
cancel out for the window itself — same pixels on screen — while every row,
font, padding and icon inside it, all authored against that smaller logical
grid, renders `BASE_SCALE`× bigger once the one `UIScale` every window already
carries scales it back up.

This runs on the same `UIScale` system Obsidian's own `Library.DPIScale` /
`Library:SetDPIScale` use, and now works the same way theirs does: a direct,
unconditional set with nothing softening it. Centrl's `Library:SetScale`
used to run every request — including one the settings-tab slider had just
made on purpose — back through the viewport-fit calculation meant only for
picking a sane size on the very first paint, which could visibly blunt or
swallow a slider drag on a smaller screen. That calculation now only ever
runs once, to choose where the scale starts out; from then on, dragging the
'ui scale' slider in the settings tab updates every registered `UIScale`
immediately, exactly the value you set it to.

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
registers an instance against the colour roles it reads, the same idea
Obsidian's own string-keyed `Library.Scheme` properties use.

## Everything else

Identical to Lib2 — see [`LIB2.md`](LIB2.md) for the full element and method
tables. The only additions are `Theme` on `:Window{}`, `Desc` on every element,
and the `SetTheme` calls above.

`Desc` is also accepted as `Description`, `desc`, `description`, `SubText` or
`Sub`, matching how the rest of the library takes option aliases.
